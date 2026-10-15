import DigUpKit
import Foundation

/// `digup search-service`: the app's searcher as a process, for shells that can't link DigUpKit (the Windows and Linux
/// shell). It keeps the index open and the query encoder warm, so a search while typing costs what it costs
/// in the Mac app (tens of milliseconds), not a process start.
///
/// Protocol: one JSON request per line on stdin, one JSON response per line on stdout, carrying the request's `id`.
///   {"op":"search","q":…,"code":bool,"kinds":[…],"limit":n,"meaning":bool,"prefix_last":bool}
///       → {"hits":[…], "strong":n, "meaning":bool, "ms":{"embed":…,"search":…}}
///         `meaning` false: keyword-only (while typing, or while the encoder isn't ready); `strong`: the weaker-matches
///         fold (`Searcher.strongCount`); each hit has the fields of `digup search --json` plus segment_id, modified,
///         size and info.
///   {"op":"embed_ahead","q":…,"code":bool}   → {"ok":true}: embeds and caches the text (the panel sends what's typed so
///                                               far on every keystroke, so the pause's vector is usually ready)
///   {"op":"text","segment":id,"code":bool}    → {"text":…}: the part of a file a hit points at, for the preview
///   {"op":"render","path":…,"kind":"pdf|video|image","loc":n,"pixels":n} → {"image":path}: a JPEG for a preview or a
///                                               thumbnail (a PDF's page `loc`, a video's frame at `loc` seconds, or a
///                                               picture a web view can't show, such as HEIC), made beside the requests
///                                               (typing never waits on one) and kept in <index>/previews until the
///                                               next start
///   {"op":"reload"}                           → {"ok":true,"vectors":n,"code_vectors":n}: after indexing changed the index
///   {"op":"summaries","code":bool}            → {"roots":[{"path","missing","unreadable","files","indexed","pending",
///                                               "failed","skipped","unfinished","kinds":{kind: n}}]}: what's indexed
///                                               under each chosen folder (each code folder, with `code`)
///   {"op":"folders","roots":[…],"skipped":[…],"types":[…],"code_roots":[…],"code_skipped":[…]} → {"ok":true}: each
///                                               optional; no code folders closes the code index
///   {"op":"prewarm"}                          → {"ok":true}: starts the encoder and loads the vectors (the panel opening)
///   {"op":"status"}                           → {"encoder":"stopped|starting|ready|unavailable","vectors":n,"files":n,
///                                               "searchable":n,"pending":n,"unfinished":n,…}
///   {"op":"quit"}                             → {"ok":true}, then exit
/// The encoder exits after `--encoder-idle` seconds without a query and the vectors are released (as in the app);
/// keyword search keeps working and the next query brings both back.
final class SearchService: @unchecked Sendable {   // search/encoder queues own their state; stateLock guards admission
    private let directory: URL
    private var store: IndexStore
    private var searcher: Searcher
    private var codeStore: IndexStore?
    private var codeSearcher: Searcher?
    private var roots: [String], skipped: [String], types: Set<String>, codeRoots: [String], codeSkipped: [String]
    private var searchedRoots: [String] = [], searchedSkipped: [String] = []
    private var searchedCodeRoots: [String] = [], searchedCodeSkipped: [String] = []
    private let idleSeconds: Double
    private let log: URL

    private var encoder: (any Embedder)?
    private var encoderState = "stopped"
    private var vectorCache: [String: Searcher.QueryVector] = [:] // encoderQueue only
    private var retryEncoderAt = Date.distantPast
    private let searchQueue = DispatchQueue(label: "DigUp.search-service.search", qos: .userInitiated)
    private let encoderQueue = DispatchQueue(label: "DigUp.search-service.encoder", qos: .userInitiated)
    private let stateLock = NSLock()
    private var lastQuery = Date()
    private var newest: [String: Int] = [:]
    private var stopping = false
    private let output = NSLock()
    /// Renders for previews: two at a time, beside the request loop, each made once per file version.
    private let previews: URL
    private var rendered: [String: String] = [:]
    private let renderLock = NSLock()
    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "DigUp.search-service.previews"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private var renderRequests = 0

    init(index: URL, roots: [String], skipped: [String], types: Set<String>, codeRoots: [String],
         codeSkipped: [String], idleSeconds: Double) throws {
        directory = index
        store = try IndexStore(directory: index, file: IndexStore.mainFile)
        searcher = try Searcher(store: store, loadVectors: false)
        self.roots = roots
        self.skipped = skipped
        self.types = types
        self.codeRoots = codeRoots
        self.codeSkipped = codeSkipped
        self.idleSeconds = idleSeconds
        log = index.appendingPathComponent("worker-query.log")
        previews = index.appendingPathComponent("previews")
        try? FileManager.default.removeItem(at: previews)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        updateScope()
        try openCode()
    }

    private func updateScope() {
        func spellings(_ paths: [String]) -> [String] {
            Array(Set(paths.flatMap { [$0, FolderSelection.realPath($0)] }))
        }
        searchedRoots = spellings(roots)
        searchedSkipped = spellings(skipped)
        searchedCodeRoots = spellings(codeRoots)
        searchedCodeSkipped = spellings(codeSkipped)
    }

    /// The code index is open while there are code folders: without any, a shell can delete it (Windows won't delete an
    /// open file).
    private func openCode() throws {
        guard !codeRoots.isEmpty else { return }
        let store = try IndexStore(directory: directory, file: IndexStore.codeFile)
        codeStore = store
        codeSearcher = try Searcher(store: store, loadVectors: false)
    }

    func serve() -> Int32 {
        Thread.detachNewThread { [self] in idleWatch() }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let request = UncheckedSendable(fields)
            let op = fields["op"] as? String ?? ""
            if op == "quit" {
                stateLock.withLock { stopping = true }
                renderQueue.cancelAllOperations()
                encoderQueue.sync { stopEncoder() }
                searchQueue.sync {}
                reply(["ok": true], to: fields)
                return 0
            }
            if op == "search" || op == "embed_ahead" || op == "prewarm" {
                stateLock.withLock {
                    lastQuery = Date()
                    if let generation = fields["generation"] as? Int {
                        let client = fields["client"] as? String ?? "default"
                        newest[client] = max(newest[client] ?? generation, generation)
                    }
                }
            }
            if op == "render" {
                // Admission is bounded, but the reader never waits for a renderer or decoder.
                let admitted = stateLock.withLock { () -> Bool in
                    guard renderRequests < 64 else { return false }
                    renderRequests += 1
                    return true
                }
                guard admitted else {
                    reply(["ok": false, "error": "preview queue is full; try again"], to: fields)
                    continue
                }
                renderQueue.addOperation { [self] in
                    defer { stateLock.withLock { renderRequests -= 1 } }
                    do { reply(try render(request.value), to: request.value) }
                    catch { reply(["ok": false, "error": String("\(error)".prefix(500))], to: request.value) }
                }
            } else if op == "embed_ahead" {
                // A reply acknowledges admission; obsolete queued inference is discarded before it starts.
                reply(["ok": true], to: fields)
                encoderQueue.async { [self] in
                    guard current(request.value) else { return }
                    _ = vector(for: request.value["q"] as? String ?? "", code: request.value["code"] as? Bool ?? false)
                }
            } else if op == "prewarm" {
                encoderQueue.async { [self] in
                    retryEncoderAt = .distantPast // a new panel opening/model arrival is a fresh chance
                    _ = runningEncoder()
                }
                searchQueue.async { [self] in
                    do {
                        if !searcher.vectorsLoaded { try searcher.reload() }
                        reply(["ok": true, "encoder": stateLock.withLock { encoderState }, "vectors": searcher.vectorCount],
                              to: request.value)
                    } catch { reply(["ok": false, "error": "\(error)"], to: request.value) }
                }
            } else if op == "search", fields["meaning"] as? Bool ?? true {
                encoderQueue.async { [self] in
                    guard current(request.value) else { cancel(request.value); return }
                    let text = request.value["q"] as? String ?? ""
                    let started = Date()
                    let vector = text.isEmpty ? nil : vector(for: text, code: request.value["code"] as? Bool ?? false)
                    let embedMS = Int(Date().timeIntervalSince(started) * 1000)
                    searchQueue.async { [self] in perform(op, request.value, vector: vector, embedMS: embedMS) }
                }
            } else {
                searchQueue.async { [self] in perform(op, request.value) }
            }
        }
        stateLock.withLock { stopping = true }
        renderQueue.cancelAllOperations()
        encoderQueue.sync { stopEncoder() }
        searchQueue.sync {}
        return 0
    }

    private func current(_ request: [String: Any]) -> Bool {
        stateLock.withLock {
            guard !stopping else { return false }
            guard let generation = request["generation"] as? Int else { return true }
            return newest[request["client"] as? String ?? "default"] == generation
        }
    }

    private func cancel(_ request: [String: Any]) {
        reply(["ok": true, "cancelled": true, "hits": [], "strong": 0, "meaning": false], to: request)
    }

    private func reply(_ fields: [String: Any], to request: [String: Any]) {
        var fields = fields
        fields["id"] = request["id"] ?? NSNull()
        write(fields)
    }

    private func perform(_ op: String, _ request: [String: Any], vector: Searcher.QueryVector? = nil, embedMS: Int = 0) {
        if op == "search", !current(request) { cancel(request); return }
        do { reply(try handle(op, request, vector: vector, embedMS: embedMS), to: request) }
        catch { reply(["ok": false, "error": String("\(error)".prefix(500))], to: request) }
    }

    private func handle(_ op: String, _ request: [String: Any], vector: Searcher.QueryVector?, embedMS: Int) throws -> [String: Any] {
        switch op {
        case "search":
            let text = request["q"] as? String ?? ""
            let code = request["code"] as? Bool ?? false
            let kinds = (request["kinds"] as? [String]).map { Set($0.compactMap(FileKind.init(rawValue:))) }
            let limit = request["limit"] as? Int ?? 40
            let prefixLast = request["prefix_last"] as? Bool ?? false
            let embedded = Date()
            let selected = code ? codeSearcher : searcher
            let eligible: (String, FileKind) -> Bool = { [self] path, _ in
                (code ? FolderSelection.isSearched(path, folders: searchedCodeRoots, skipped: searchedCodeSkipped)
                    : FolderSelection.isSearched(path, folders: searchedRoots, skipped: searchedSkipped)
                        && !types.contains((path as NSString).pathExtension.lowercased()))
            }
            let hits = try selected?.search(text, query: vector, kinds: kinds, limit: limit,
                                             prefixLast: prefixLast, eligible: eligible,
                                             available: { FileManager.default.fileExists(atPath: $0) }) ?? []
            let meaning = selected?.lastQueryUsedMeaning ?? false
            let reply: [String: Any] = [
                "hits": hits.map(hitFields), "strong": Searcher.strongCount(hits), "meaning": meaning,
                "ms": ["embed": embedMS,
                       "search": Int(Date().timeIntervalSince(embedded) * 1000)],
            ]
            return reply
        case "text":
            guard let segment = (request["segment"] as? NSNumber)?.int64Value else { throw CLIError("which segment?") }
            let code = request["code"] as? Bool ?? false
            return ["text": try (code ? codeSearcher : searcher)?.text(ofSegment: segment) ?? NSNull()]
        case "reload":
            try searcher.refresh()
            if let codeSearcher { try codeSearcher.refresh() } else { try openCode() }
            return ["ok": true, "vectors": searcher.vectorCount, "code_vectors": codeSearcher?.vectorCount ?? 0]
        case "summaries":
            let code = request["code"] as? Bool ?? false
            return ["roots": (code ? codeRoots : roots).map { summary(of: $0, in: code ? codeStore : store) }]
        case "folders":
            if let value = request["roots"] as? [String] { roots = value.map { Arguments.folderURL($0).path } }
            if let value = request["skipped"] as? [String] { skipped = value.map { Arguments.folderURL($0).path } }
            if let value = request["types"] as? [String] { types = IndexOptions.extensions(value.joined(separator: ",")) }
            if let value = request["code_roots"] as? [String] { codeRoots = value.map { Arguments.folderURL($0).path } }
            if let value = request["code_skipped"] as? [String] { codeSkipped = value.map { Arguments.folderURL($0).path } }
            updateScope()
            if codeRoots.isEmpty {
                codeSearcher = nil
                codeStore = nil
            } else if codeSearcher == nil {
                try openCode()
            }
            return ["ok": true]
        case "status":
            var reply: [String: Any] = ["encoder": stateLock.withLock { encoderState }, "vectors": searcher.vectorsLoaded ? searcher.vectorCount : 0,
                                        "code_vectors": codeSearcher?.vectorsLoaded == true ? codeSearcher!.vectorCount : 0,
                                        "index": store.file.path]
            // What's in the index, as the index helper counts it: a shell knows it before any indexing runs.
            if let counts = try? store.counts() {
                var files = 0, searchable = 0, pending = 0
                for states in counts.byKindAndState.values {
                    for (state, count) in states {
                        files += count
                        if state == "done" || state == "partial" { searchable += count }
                        if state == "pending" { pending += count }
                    }
                }
                reply.merge(["files": files, "searchable": searchable, "pending": pending, "unfinished": counts.unfinished]) { $1 }
            }
            return reply
        default:
            throw CLIError("unknown op \(op)")
        }
    }

    private func write(_ fields: [String: Any]) {
        output.withLock { emit(fields) }
    }

    /// What's indexed under one folder, as the Mac app's `Engine.rootSummaries` counts it: its files by state and kind.
    private func summary(of root: String, in store: IndexStore?) -> [String: Any] {
        let folder = URL(fileURLWithPath: root)
        let missing = !Arguments.isFolder(folder)
        var fields: [String: Any] = ["path": root, "missing": missing, "unreadable": !missing && !Arguments.isReadable(folder)]
        var states = ["indexed": 0, "pending": 0, "failed": 0, "skipped": 0, "unfinished": 0]
        var kinds: [String: Int] = [:]
        let files = (try? store?.files(under: [root])) ?? []
        for file in files {
            kinds[file.kind.rawValue, default: 0] += 1
            switch file.state {
            case "done": states["indexed", default: 0] += 1
            case "partial":
                states["indexed", default: 0] += 1
                states["unfinished", default: 0] += 1
            case "pending": states["pending", default: 0] += 1
            case "failed": states["failed", default: 0] += 1
            default: states["skipped", default: 0] += 1
            }
        }
        fields.merge(states) { $1 }
        fields["files"] = files.count
        fields["kinds"] = kinds
        return fields
    }

    // MARK: Previews

    private func render(_ request: [String: Any]) throws -> [String: Any] {
        guard let path = request["path"] as? String else { throw CLIError("which file?") }
        let kind = request["kind"] as? String ?? "image"
        let loc = (request["loc"] as? NSNumber)?.doubleValue
        let pixels = min(max(request["pixels"] as? Int ?? 1024, 32), 2048)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(path)|\(modified)|\(kind)|\(loc ?? -1)|\(pixels)"
        if let done = renderLock.withLock({ rendered[key] }), FileManager.default.fileExists(atPath: done) {
            return ["image": done]
        }
        let image = try PreviewImages.make(PreviewImages.Kind(rawValue: kind) ?? .image, of: path, at: loc,
                                           pixels: pixels, in: previews)
        renderLock.withLock { rendered[key] = image }
        return ["image": image]
    }

    // MARK: The query encoder

    /// The query's vector (cached), or nil when the encoder can't run: keyword results still work.
    private func vector(for text: String, code: Bool) -> Searcher.QueryVector? {
        let key = (code ? "code\u{0}" : "") + text
        if let cached = vectorCache[key] { return cached }
        guard let encoder = runningEncoder() else { return nil }
        do {
            let values = try encoder.embedTexts([code ? Prompts.codeQuery(text) : Prompts.query(text)]).first ?? []
            if vectorCache.count > 256 { vectorCache.removeAll() }
            let vector = Searcher.QueryVector(values: values, source: encoder.info.vectorSource)
            vectorCache[key] = vector
            return vector
        } catch {
            FileHandle.standardError.write(Data("encoder: \(error)\n".utf8))
            stopEncoder()   // the next query starts a new one
            return nil
        }
    }

    private func runningEncoder() -> (any Embedder)? {
        if let encoder { return encoder }
        guard Date() >= retryEncoderAt else { return nil }
        stateLock.withLock { encoderState = "starting" }
        do {
            let started = Date()
            let worker = try makeEmbedder(textOnly: true, log: log, qos: .userInitiated)
            encoder = worker
            stateLock.withLock { encoderState = "ready" }
            write(["event": "encoder", "state": "ready", "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
                  "source": worker.info.vectorSource])
            return worker
        } catch {
            retryEncoderAt = Date().addingTimeInterval(5)
            stateLock.withLock { encoderState = "unavailable" }
            write(["event": "encoder", "state": "unavailable", "error": String("\(error)".prefix(300))])
            return nil
        }
    }

    private func stopEncoder() {
        encoder?.close()
        encoder = nil
        vectorCache.removeAll()
        stateLock.withLock { encoderState = "stopped" }
    }

    /// After `idleSeconds` without a query the model and the vectors go (their memory back to the system).
    private func idleWatch() {
        while !stateLock.withLock({ stopping }) {
            Thread.sleep(forTimeInterval: 1)
            guard stateLock.withLock({ Date().timeIntervalSince(lastQuery) > idleSeconds }) else { continue }
            encoderQueue.async { [self] in
                guard stateLock.withLock({ !stopping && Date().timeIntervalSince(lastQuery) > idleSeconds }) else { return }
                let hadEncoder = encoder != nil
                stopEncoder()
                searchQueue.async { [self] in
                    guard stateLock.withLock({ !stopping && Date().timeIntervalSince(lastQuery) > idleSeconds }),
                          hadEncoder || searcher.vectorsLoaded || codeSearcher?.vectorsLoaded == true else { return }
                    searcher.releaseVectors()
                    codeSearcher?.releaseVectors()
                    write(["event": "encoder", "state": "stopped", "reason": "idle"])
                }
            }
        }
    }

}

/// A value handed to another thread that only that thread uses from then on.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A hit as JSON: what `digup search --json` prints, plus what a shell's preview needs.
func hitFields(_ hit: SearchHit) -> [String: Any] {
    var row: [String: Any] = ["path": hit.path, "kind": hit.kind.rawValue, "segment": hit.segment.rawValue,
                              "segment_id": hit.segmentID, "score": hit.score, "modified": hit.modified,
                              "size": hit.size, "info": hit.info]
    if let z = hit.z { row["z"] = z }
    if let cosine = hit.cosine { row["cosine"] = cosine }
    if let rank = hit.keywordRank { row["keyword_rank"] = rank }
    if let loc = hit.loc { row["loc"] = loc }
    if let end = hit.locEnd { row["loc_end"] = end }
    if let focus = hit.focus { row["focus"] = focus }
    if let excerpt = hit.excerpt { row["excerpt"] = excerpt }
    return row
}

func searchService(_ args: Arguments) throws -> Int32 {
    let service = try SearchService(
        index: args.indexFolder,
        roots: args.positional.map { Arguments.folderURL($0).path },
        skipped: (args.lists["--exclude"] ?? []).map { Arguments.folderURL($0).path },
        types: IndexOptions.extensions((args.lists["--exclude-ext"] ?? []).joined(separator: ",")),
        codeRoots: (args.lists["--code-root"] ?? []).map { Arguments.folderURL($0).path },
        codeSkipped: (args.lists["--code-exclude"] ?? []).map { Arguments.folderURL($0).path },
        idleSeconds: args.values["--encoder-idle"].flatMap(Double.init) ?? 300)
    emit(["event": "ready", "index": args.indexFolder.path])
    return service.serve()
}
