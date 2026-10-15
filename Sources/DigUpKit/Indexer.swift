import Foundation

public enum IndexerError: Error, CustomStringConvertible {
    case fingerprintMismatch(index: String, now: String)

    public var description: String {
        switch self {
        case .fingerprintMismatch(let index, let now):
            "this index was built with different settings or model:\n  index: \(index)\n  now:   \(now)\n"
                + "re-run with --reindex (vectors from different settings can't be compared)"
        }
    }
}

/// Keeps the index in step with the chosen folders, then extracts and embeds whatever is pending.
///
/// Model work goes to an `Embedder` (made on first use, freed by `closeWorker`). Extraction (ImageIO, Vision, PDFKit,
/// AVFoundation) runs on a second thread one batch ahead, so reading files and embedding them overlap (see `run`).
public final class Indexer {
    public struct SyncSummary: Sendable {
        public var added = 0, changed = 0, moved = 0, removed = 0, unchanged = 0
        public var crawl: CrawlReport
        /// Files this sync queued for embedding (new or changed), so a watcher can index exactly those first.
        public var queued: [Int64] = []
    }

    public struct Event: Sendable {
        public let done: Int
        public let total: Int
        public let path: String
        public let kind: FileKind
        public let state: String
        public let seconds: Double
        public let note: String?
    }

    let store: IndexStore
    let options: IndexOptions
    private let makeEmbedder: () throws -> any Embedder
    private var worker: (any Embedder)?
    private let scratch: URL

    /// When set, an index built with another model or other settings is emptied and embedded again (the app: a new
    /// version may bring a new model), and this hears about it. When nil, indexing stops with `fingerprintMismatch`.
    public var resetOnModelChange: ((_ indexed: String, _ now: String) -> Void)?

    /// The vector source of the embedders `makeEmbedder` makes, when it's known without starting one (llama.cpp's is):
    /// then `checkModel()` can notice a new model before anything needs embedding.
    public var embedderSource: String?
    /// The index folder, where what indexing costs on this Mac is kept (`MeasuredCosts`) for estimates. Unset: nothing
    /// is kept.
    public var costsFolder: URL?
    private var measured = MeasuredCosts()

    public init(store: IndexStore, options: IndexOptions, makeEmbedder: @escaping () throws -> any Embedder) throws {
        self.store = store
        self.options = options
        self.makeEmbedder = makeEmbedder
        // One folder per process ($TMPDIR/DigUp-<pid>, which the helper clears up after a process that died), and one
        // in it per indexer: the helper runs two (the main index and the code index), and each clears its own away.
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        preparationCache.documentFolder = scratch.appendingPathComponent("documents")
    }

    deinit {
        worker?.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Frees the embedding model (about 1 GB) until the next file needs it.
    public func closeWorker() {
        worker?.close()
        worker = nil
    }

    /// Stops the worker and removes the scratch folder, for a process that's about to exit (deinit won't run then).
    public func finish() {
        closeWorker()
        try? FileManager.default.removeItem(at: scratch)
    }

    public var workerIsRunning: Bool { worker != nil }

    // MARK: Sync

    /// Crawls `roots` and reconciles the index: new files are queued, changed ones re-queued, moved ones re-pathed
    /// (no re-embedding), and files that are gone or newly excluded are removed.
    public func sync(_ roots: [URL]) throws -> SyncSummary {
        let spellings = roots.map { ($0.path, FolderSelection.realPath($0.path)) }
        let crawl = Crawler.crawl(roots, options: options)
        preparing.sync { preparationCache.discovery = CodeExtractor.DiscoveryCache() }
        let existing = try store.files(under: roots.map { $0.standardizedFileURL.path })
        var byPath: [String: FileRecord] = [:]
        var byInode: [String: FileRecord] = [:]
        for file in existing {
            byPath[file.path] = file
            if file.inode != 0 { byInode["\(file.device):\(file.inode)"] = file }
        }
        let seen = Set(crawl.candidates.map(\.path))
        var movedFrom = Set<String>()
        var summary = SyncSummary(crawl: crawl)
        try store.db.transaction {
            for file in crawl.candidates {
                if let row = byPath[file.path] {
                    if row.size != file.size || abs(row.mtime - file.mtime) > 0.000001 || row.kind != file.kind
                        || (row.inode != 0 && file.inode != 0 && (row.inode != file.inode || row.device != file.device))
                        || row.state == "unavailable" {
                        try store.requeue(row.id, as: file)
                        summary.changed += 1
                        summary.queued.append(row.id)
                    } else {
                        summary.unchanged += 1
                    }
                } else if let row = byInode["\(file.device):\(file.inode)"], !seen.contains(row.path),
                          !movedFrom.contains(row.path), row.kind == file.kind, row.size == file.size,
                          abs(row.mtime - file.mtime) < 0.000001 {
                    try store.move(row.id, to: file.path)
                    movedFrom.insert(row.path)
                    summary.moved += 1
                } else {
                    summary.queued.append(try store.insert(file))
                    summary.added += 1
                }
            }
            // A root that went away while it was being walked (a drive ejected mid-crawl) looked emptier than it is:
            // keep its rows rather than take that for "deleted".
            let unavailable = crawl.unavailable + spellings.filter { !FileManager.default.fileExists(atPath: $0.0) }
                .flatMap { [$0.0, $0.1] }
            for row in existing where !seen.contains(row.path) && !movedFrom.contains(row.path)
                && !unavailable.contains(where: { row.path == $0 || FolderSelection.isInside(row.path, $0) }) {
                try store.delete(row.id)
                summary.removed += 1
            }
        }
        return summary
    }

    // MARK: Run

    /// Processes pending files, screenshots first, newest first (`only`: just these files). Long PDFs and documents get
    /// their first step (`IndexOptions.pdfStep` pages, `docStep` chunks) and stay `partial` for `finishLongFiles`.
    /// Per-file problems are recorded on the file; a dead worker or a settings mismatch stops the run (pending files stay
    /// pending, so the next run resumes). `shouldStop` is asked between batches: pausing, or new files that should go
    /// first.
    @discardableResult
    public func run(limit: Int? = nil, only ids: Set<Int64>? = nil, shouldStop: () -> Bool = { false },
                    onEvent: (Event) -> Void = { _ in }) throws -> [String: Int] {
        try checkModel()
        let queue = try store.pending(limit: limit, only: ids)
        var states: [String: Int] = [:]
        var done = 0
        try process(Self.batches(queue).map { Job(files: $0) }, shouldStop: shouldStop) { _, job, results, seconds in
            for (offset, file) in job.files.enumerated() {
                let (state, note) = results[offset]
                states[state, default: 0] += 1
                onEvent(Event(done: done + offset + 1, total: queue.count, path: file.path, kind: file.kind,
                              state: state, seconds: seconds, note: note))
            }
            done += job.files.count
        }
        return states
    }

    /// One step of the later pass: how far it has got (`done` of the `total` pages and chunks it set out to read, in
    /// `files` files), and the file it just read more of.
    public struct Step: Sendable {
        public let done: Int
        public let total: Int
        public let files: Int        // long files not finished yet, this one included until its last step
        public let path: String
        public let kind: FileKind
        public let state: String     // "partial" until the file's last step, then "done"
        public let seconds: Double
        public let note: String?
    }

    /// The later pass: reads the rest of long PDFs and documents (`partial` after their first step), in indexing order,
    /// a step at a time. Each step is saved as one transaction, so stopping between steps (pausing, new files going
    /// first) loses nothing, and the next pass goes on from there. It runs once nothing is pending: a book's last
    /// pages matter less than everything else's first ones, and they take a while (0.04–0.2 s a page, 2026-10-09).
    @discardableResult
    public func finishLongFiles(shouldStop: () -> Bool = { false }, onStep: (Step) -> Void = { _ in }) throws
        -> [String: Int] {
        try checkModel()
        var jobs: [Job] = []
        for file in try store.unfinished() {
            let info = try store.info(of: file.id)
            let size: Int
            switch file.kind {
            case .pdf: size = options.pdfStep
            case .audio, .video: size = options.mediaWindowsPerStep
            default: size = options.docStep
            }
            // Where it stopped (after the last page or chunk stored, should its info not say; nothing stored: the start).
            var start = try info["read_to"].flatMap(Int.init) ?? store.lastPlace(of: file.id) ?? 0
            // At least one step, which settles a file whose length was only guessed (documents cut before schema 5).
            let end = max(info["read_end"].flatMap(Int.init) ?? 0, start + 1)
            while start < end {
                jobs.append(Job(files: [file], step: start..<min(start + max(1, size), end)))
                start += max(1, size)
            }
        }
        // Progress counts pages and chunks: what's read once each job is through.
        var through: [Int] = []
        for job in jobs { through.append((through.last ?? 0) + (job.step?.count ?? 0)) }
        var files = Set(jobs.map { $0.files[0].id }).count
        var states: [String: Int] = [:]
        var finished = Set<Int64>()
        try process(jobs, shouldStop: shouldStop) { index, job, results, seconds in
            let file = job.files[0]
            let (state, note) = results[0]
            if state != "partial", finished.insert(file.id).inserted {
                states[state, default: 0] += 1
                files -= 1
            }
            onStep(Step(done: through[index], total: through.last ?? 0, files: files, path: file.path, kind: file.kind,
                        state: state, seconds: seconds, note: note))
        } skip: { job in
            // Finished sooner than its steps said: a document whose length was guessed, or a file that went unreadable.
            finished.contains(job.files[0].id)
        }
        return states
    }

    /// Runs `jobs` in order until `shouldStop` (asked between jobs), passing each one's results to `committed` (with
    /// its place in `jobs`). Jobs that `skip` turns down when their turn comes are left out.
    ///
    /// Two stages overlap: while the model embeds one job, the next one is read and decoded on another thread
    /// (images scaled, screenshots OCR'd, PDF pages rendered, audio and video decoded). OCR alone is ~0.24 s per Retina
    /// screenshot, about as long as embedding it.
    private func process(_ jobs: [Job], shouldStop: () -> Bool,
                         committed: (Int, Job, [(String, String?)], Double) -> Void,
                         skip: (Job) -> Bool = { _ in false }) throws {
        var ahead: (index: Int, batch: PendingBatch)?
        defer {
            // A job prepared for a run that stopped early: throw its files away.
            if let ahead { try? FileManager.default.removeItem(at: ahead.batch.wait().folder) }
            if let costsFolder, !measured.tallies.isEmpty {
                MeasuredCosts.merge(measured, into: costsFolder)
                measured = MeasuredCosts()
            }
        }
        for (index, job) in jobs.enumerated() {
            guard !shouldStop() else { break }
            if skip(job) {
                if let pending = ahead, pending.index == index {
                    try? FileManager.default.removeItem(at: pending.batch.wait().folder)
                    ahead = nil
                }
                continue
            }
            let started = Date()
            let prepared = (ahead?.batch ?? prepare(job)).wait()
            ahead = nil
            // A file can have finished sooner than its preplanned steps. Do not read the skipped jobs at all.
            if let next = jobs.indices.dropFirst(index + 1).first(where: { !skip(jobs[$0]) }) {
                ahead = (next, prepare(jobs[next]))
            }
            defer { try? FileManager.default.removeItem(at: prepared.folder) }
            // The helper's and the CLI's main thread has no run loop to drain what Foundation autoreleases while a job
            // commits: without a pool per job it all stayed until the process exited (~30 KB a text chunk).
            let modelWasRunning = worker != nil
            let results: [(String, String?)]
            do {
                results = try autoreleasepool { try commit(prepared) }
            } catch is SourceChanged {
                for file in job.files { try refreshChanged(file) }
                results = job.files.map { _ in ("pending", "source changed; queued again") }
            }
            let seconds = Date().timeIntervalSince(started)
            if modelWasRunning { measure(prepared, seconds: seconds) }   // else it's seconds of the model starting
            committed(index, job, results, seconds / Double(job.files.count))
        }
    }

    /// What a job read and how long it took (its reading and its model's work, which overlap), for `MeasuredCosts`.
    private func measure(_ prepared: Prepared, seconds: Double) {
        switch prepared.payload {
        case .images(let screenshot, let ready):
            measured.add(screenshot ? "screenshot" : "image", units: Double(ready.count), seconds: seconds)
        case .pdf(let pages, _, _, _): measured.add("pdfPage", units: Double(pages.count), seconds: seconds)
        case .doc(let chunks, _, _, _):
            // Chunks with a vector: a data dump's go to keyword search only and take next to nothing, which isn't
            // what a chunk of prose costs (the estimate can't tell them apart from a file's size).
            let worded = chunks.filter(SearchText.hasWords).count
            if worded > 0 { measured.add("docChunk", units: Double(worded), seconds: seconds) }
        case .audio(_, let duration, let read): measured.add("audioSecond", units: min(Double(read.count) * options.audioHop, max(0, duration - Double(read.lowerBound) * options.audioHop)), seconds: seconds)
        case .video(_, _, let duration, let read): measured.add("videoSecond", units: min(Double(read.count) * options.audioHop, max(0, duration - Double(read.lowerBound) * options.audioHop)), seconds: seconds)
        case .code(let file): measured.add("codeStretch", units: Double(file.pieces.count), seconds: seconds)
        case .nothing: break
        }
    }

    /// Files read and embedded together (images 8 at a time, other files one by one), or one step of a long file
    /// (`step`: the pages of a PDF or the chunks of a document to read, from 0). The first step comes with the file.
    struct Job: Sendable {
        let files: [FileRecord]
        var step: Range<Int>?
    }

    /// Images and screenshots go to the model 8 at a time; other files one by one.
    static func batches(_ queue: [FileRecord]) -> [[FileRecord]] {
        var batches: [[FileRecord]] = []
        var index = 0
        while index < queue.count {
            var batch = [queue[index]]
            if batch[0].kind == .image || batch[0].kind == .screenshot {
                while index + batch.count < queue.count, batch.count < 8,
                      queue[index + batch.count].kind == batch[0].kind {
                    batch.append(queue[index + batch.count])
                }
            }
            batches.append(batch)
            index += batch.count
        }
        return batches
    }

    /// Compares the index with the current model and settings (`embedderSource`), without starting the model; a
    /// change empties the index (see `resetOnModelChange`) or throws `fingerprintMismatch`. Without a known source the
    /// check waits for the first file to embed.
    public func checkModel() throws {
        if let embedderSource { try adopt("\(embedderSource) | \(options.fingerprint)") }
        var legacy = IndexOptions()
        legacy.code = options.code
        for (kind, policy) in options.extractionPolicies {
            let key = "extraction_\(kind)"
            // Old indexes predate policy metadata. Code discovery/eligibility changed in this fork: revisit it once.
            let predecessor = kind == "code" ? "code1" : legacy.extractionPolicies[kind]
            let previous = try store.meta(key) ?? predecessor
            if previous != policy, let fileKind = FileKind(rawValue: kind) {
                _ = try store.requeue(kinds: [fileKind])
            }
            try store.setMeta(key, policy)
        }
    }

    private func adopt(_ fingerprint: String) throws {
        guard let indexed = try store.meta("fingerprint"), indexed != fingerprint else { return }
        guard let resetOnModelChange else { throw IndexerError.fingerprintMismatch(index: indexed, now: fingerprint) }
        // Everything is queued again: a run that's under way goes on with its batch, and later runs take the rest.
        try store.resetAll()
        resetOnModelChange(indexed, fingerprint)
    }

    private func fullWorker() throws -> any Embedder {
        if let worker { return worker }
        let started = try makeEmbedder()
        let fingerprint = "\(started.info.vectorSource) | \(options.fingerprint)"
        do {
            try adopt(fingerprint)
        } catch {
            started.close()
            throw error
        }
        try store.setMeta("fingerprint", fingerprint)
        try store.setMeta("vector_source", started.info.vectorSource)
        worker = started
        return started
    }

    // MARK: Prepare (any thread: files only, no database, no model)

    /// A job read from disk and decoded, ready for the model. Its scratch files live in `folder`.
    struct Prepared: Sendable {
        let batch: [FileRecord]
        let step: Range<Int>?                // a long file's later step (`Job.step`)
        let folder: URL
        var outcomes: [Int: Outcome] = [:]   // files already settled (skipped or failed while reading)
        var payload = Payload.nothing
    }

    struct Outcome: Sendable {
        let state: String
        let detail: String?
    }

    private struct SourceChanged: Error {}

    private static func isCurrent(_ file: FileRecord) -> Bool {
        guard let now = FileSystem.info(of: file.path), now.isRegular, !now.dataless else { return false }
        let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: Set(FileSystem.crawlKeys))
        return !FileSystem.isInCloud(values) && now.size == file.size && abs(now.mtime - file.mtime) < 0.000001
            && (file.inode == 0 || now.inode == 0 || (file.inode == now.inode && file.device == now.device))
    }

    private func validate(_ files: [FileRecord]) throws {
        guard files.allSatisfy(Self.isCurrent) else { throw SourceChanged() }
    }

    private func commitTransaction(_ files: [FileRecord], _ body: () throws -> Void) throws {
        try store.db.transaction {
            try validate(files)
            try body()
        }
    }

    private func refreshChanged(_ file: FileRecord) throws {
        guard let now = FileSystem.info(of: file.path), now.isRegular, !now.dataless else {
            try store.finish(file.id, state: "unavailable", detail: "source unavailable; waiting for the next sync")
            return
        }
        let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: Set(FileSystem.crawlKeys))
        guard !FileSystem.isInCloud(values) else {
            try store.finish(file.id, state: "unavailable", detail: "source is not downloaded")
            return
        }
        try store.requeue(file.id, as: Candidate(path: file.path, kind: file.kind, size: now.size, mtime: now.mtime,
                                                inode: now.inode, device: now.device))
    }

    enum Payload: Sendable {
        case nothing
        case images(screenshot: Bool, ready: [ReadyImage])
        /// `read`: the pages read (from 0) of the PDF's `total`.
        case pdf(pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?)
        /// `chunks`: the ones in `read` (from 0) of the document's `total` (counted up to `IndexOptions.maxChunks` + 1).
        case doc(chunks: [String], read: Range<Int>, total: Int, characters: Int)
        case audio(pieces: [MediaPiece], duration: Double, read: Range<Int>)
        case video(frames: [MediaPiece], sound: [MediaPiece], duration: Double, read: Range<Int>)
        case code(CodeExtractor.File)
    }

    struct ReadyImage: Sendable {
        let slot: Int
        let image: ImageExtractor.Prepared
        let ocr: String
    }

    /// A batch being prepared on the preparation queue.
    final class PendingBatch: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private var value: Prepared?

        fileprivate func fulfill(_ prepared: Prepared) {
            value = prepared
            ready.signal()
        }

        /// Blocks until it's ready. Call once.
        func wait() -> Prepared {
            ready.wait()
            return value!
        }
    }

    private let preparing = DispatchQueue(label: "DigUp.prepare", qos: .utility)
    private var jobsPrepared = 0   // names the scratch folders
    private let preparationCache = PreparationCache()

    /// Only the latest document stays in memory, and only on the serial preparation queue.
    final class PreparationCache: @unchecked Sendable {
        var discovery = CodeExtractor.DiscoveryCache()
        var document: (key: String, chunks: [String], characters: Int)?
        var documentReads = 0
        var documentFolder: URL?
        private var saved: [(key: String, url: URL, bytes: Int)] = []
        private var savedBytes = 0

        private struct Document: Codable { let chunks: [String]; let characters: Int }

        func chunks(of url: URL, key: String, limit: Int) throws -> (chunks: [String], characters: Int) {
            if document?.key != key {
                if let cached = saved.first(where: { $0.key == key }),
                   let data = try? Data(contentsOf: cached.url), let decoded = try? JSONDecoder().decode(Document.self, from: data) {
                    document = (key, decoded.chunks, decoded.characters)
                } else {
                    let text = try DocExtractor.text(of: url)
                    let extracted = Document(chunks: DocExtractor.chunks(text, limit: limit), characters: text.count)
                    document = (key, extracted.chunks, extracted.characters)
                    documentReads += 1
                    // Keep only one decoded document, plus a bounded scratch cache for the first/later passes.
                    if let documentFolder, let data = try? JSONEncoder().encode(extracted), data.count <= 64 << 20 {
                        try? FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
                        let destination = documentFolder.appendingPathComponent(UUID().uuidString + ".json")
                        if (try? data.write(to: destination)) != nil {
                            saved.append((key, destination, data.count)); savedBytes += data.count
                            while savedBytes > 64 << 20, let oldest = saved.first {
                                try? FileManager.default.removeItem(at: oldest.url)
                                savedBytes -= oldest.bytes; saved.removeFirst()
                            }
                        }
                    }
                }
            }
            return (document!.chunks, document!.characters)
        }
    }

    var documentExtractions: Int { preparing.sync { preparationCache.documentReads } }

    /// The file being read (extracted) right now, and since when: for a watchdog. Apple's frameworks have run away on
    /// some files (PDF text extraction growing by gigabytes a minute, never returning), and nothing stops them from
    /// outside but ending the process, so it has to know which file that was. One value for the whole process, since
    /// files are read one at a time.
    public static var nowReading: (path: String, since: Date)? { readingLock.withLock { reading } }
    nonisolated(unsafe) private static var reading: (path: String, since: Date)?
    private static let readingLock = NSLock()

    private static func startReading(_ path: String) {
        readingLock.withLock { reading = (path, Date()) }
    }

    private func prepare(_ job: Job) -> PendingBatch {
        let pending = PendingBatch()
        jobsPrepared += 1
        let (options, folder, cache) = (options, scratch.appendingPathComponent("batch-\(jobsPrepared)"), preparationCache)
        preparing.async {
            pending.fulfill(Self.prepare(job, options: options, into: folder, cache: cache))
        }
        return pending
    }

    static func prepare(_ job: Job, options: IndexOptions, into folder: URL,
                        cache: PreparationCache = PreparationCache()) -> Prepared {
        let batch = job.files
        var prepared = Prepared(batch: batch, step: job.step, folder: folder)
        let url = URL(fileURLWithPath: batch[0].path)
        startReading(batch[0].path)
        defer { readingLock.withLock { reading = nil } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if batch[0].kind != .image, batch[0].kind != .screenshot, !isCurrent(batch[0]) {
                prepared.outcomes[0] = Outcome(state: "changed", detail: "source changed or became unavailable")
                return prepared
            }
            switch batch[0].kind {
            case .image, .screenshot:
                let screenshot = batch[0].kind == .screenshot
                var ready: [ReadyImage] = []
                for (slot, file) in batch.enumerated() {
                    guard isCurrent(file) else {
                        prepared.outcomes[slot] = Outcome(state: "changed", detail: "source changed or became unavailable")
                        continue
                    }
                    let url = URL(fileURLWithPath: file.path)
                    startReading(file.path)
                    do {
                        let image = try ImageExtractor.prepare(url, maxPixel: screenshot ? 1536 : 1024,
                                                               minSide: options.minImageSide, to: folder,
                                                               png: screenshot)
                        let ocr = screenshot ? OCR.text(ofImageAt: url) : ""
                        ready.append(ReadyImage(slot: slot, image: image, ocr: ocr))
                    } catch let error as ExtractError {
                        if case .tooSmall = error {
                            prepared.outcomes[slot] = Outcome(state: "skipped", detail: "\(error)")
                        } else {
                            prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                        }
                    }
                }
                prepared.payload = .images(screenshot: screenshot, ready: ready)
            case .pdf:
                // Long PDFs (books) get their first pages now and the rest after everything else.
                var wanted = 0..<0
                let read = try PDFExtractor.pages(of: url, range: { total in
                    wanted = (job.step ?? (total > options.bigPDFPages ? 0..<options.pdfStep : 0..<options.maxPages))
                        .clamped(to: 0..<min(total, options.maxPages))
                    return wanted
                }, minText: options.minPageText, renderPixels: 1400, to: folder)
                prepared.payload = .pdf(pages: read.pages, read: wanted, total: read.total, title: read.title)
            case .doc:
                let file = batch[0]
                let key = "\(file.path)|\(file.device):\(file.inode)|\(file.size)|\(file.mtime)|\(options.maxChunks)"
                let document = try cache.chunks(of: url, key: key, limit: options.maxChunks + 1)
                let chunks = document.chunks
                let read = (job.step ?? 0..<options.docStep).clamped(to: 0..<min(chunks.count, options.maxChunks))
                prepared.payload = .doc(chunks: Array(chunks[read]), read: read, total: chunks.count,
                                        characters: document.characters)
            case .audio:
                let (window, hop) = (options.audioWindow, options.audioHop)
                let read = job.step ?? 0..<max(1, options.mediaWindowsPerStep)
                let range = Double(read.lowerBound) * hop..<Double(read.upperBound) * hop
                let (pieces, duration) = try runBlocking {
                    try await AudioExtractor.windows(of: url, window: window, hop: hop, range: range, to: folder)
                }
                prepared.payload = .audio(pieces: pieces, duration: duration, read: read)
            case .video:
                let (interval, window, hop) = (options.frameInterval, options.audioWindow, options.audioHop)
                let read = job.step ?? 0..<max(1, options.mediaWindowsPerStep)
                let range = Double(read.lowerBound) * hop..<Double(read.upperBound) * hop
                let (frames, duration, hasAudio) = try runBlocking {
                    try await VideoExtractor.keyframes(of: url, every: interval, maxPixel: 1024, range: range, to: folder)
                }
                let sound = hasAudio
                    ? try runBlocking { try await AudioExtractor.windows(of: url, window: window, hop: hop, range: range, to: folder) }
                        .pieces
                    : []
                prepared.payload = .video(frames: frames, sound: sound, duration: duration, read: read)
            case .code:
                prepared.payload = .code(try CodeExtractor.read(url, options: options, discovery: cache.discovery))
            }
        } catch let error as ExtractError {
            if case .leftOut = error {
                prepared.outcomes[0] = Outcome(state: "skipped", detail: "\(error)")
            } else {
                for slot in batch.indices where prepared.outcomes[slot] == nil {
                    prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                }
            }
            prepared.payload = .nothing
        } catch {
            for slot in batch.indices where prepared.outcomes[slot] == nil {
                prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
            }
            prepared.payload = .nothing
        }
        return prepared
    }

    // MARK: Commit (the indexing thread: the model and the database)

    private func commit(_ prepared: Prepared) throws -> [(String, String?)] {
        let batch = prepared.batch
        try validate(batch)
        let later = prepared.step != nil
        if let step = prepared.step, let outcome = prepared.outcomes[0] {
            return [try stopReading(batch[0], at: step.lowerBound, because: outcome.detail ?? outcome.state)]
        }
        var results = [(String, String?)](repeating: ("failed", nil), count: batch.count)
        for (slot, outcome) in prepared.outcomes {
            try store.finish(batch[slot].id, state: outcome.state, detail: outcome.detail)
            results[slot] = (outcome.state, outcome.detail)
        }
        do {
            switch prepared.payload {
            case .nothing:
                break
            case .images(let screenshot, let ready):
                try images(batch, screenshot: screenshot, ready: ready, results: &results)
            case .pdf(let pages, let read, let total, let title):
                results[0] = try pdf(batch[0], pages: pages, read: read, total: total, title: title, later: later)
            case .doc(let chunks, let read, let total, let characters):
                results[0] = try doc(batch[0], chunks: chunks, read: read, total: total, characters: characters,
                                     later: later)
            case .audio(let pieces, let duration, let read):
                results[0] = try audio(batch[0], pieces: pieces, duration: duration, read: read)
            case .video(let frames, let sound, let duration, let read):
                results[0] = try video(batch[0], frames: frames, sound: sound, duration: duration, read: read)
            case .code(let code):
                results[0] = try self.code(batch[0], code)
            }
        } catch let error as WorkerError {
            throw error
        } catch let error as IndexerError {
            throw error
        } catch let error as SourceChanged {
            throw error
        } catch {
            if let step = prepared.step { return [try stopReading(batch[0], at: step.lowerBound, because: "\(error)")] }
            for (slot, file) in batch.enumerated() where prepared.outcomes[slot] == nil {
                try store.finish(file.id, state: "failed", detail: "\(error)")
                results[slot] = ("failed", "\(error)")
            }
        }
        return results
    }

    /// A long file that can't be read any further keeps its searchable segments and reports a visible failure.
    private func stopReading(_ file: FileRecord, at place: Int, because problem: String) throws -> (String, String?) {
        var info = try store.info(of: file.id)
        info["read_to"] = nil
        info["read_end"] = nil
        let unit = file.kind == .pdf ? "page" : "chunk"
        try store.finish(file.id, state: "failed", detail: "read to \(unit) \(place), not after: \(problem)", info: info)
        return ("failed", "stopped before \(unit) \(place + 1): \(problem)")
    }

    private func images(_ batch: [FileRecord], screenshot: Bool, ready: [ReadyImage],
                        results: inout [(String, String?)]) throws {
        guard !ready.isEmpty else { return }
        let worker = try fullWorker()
        let vectors = try worker.embedImages(ready.map(\.image.path),
                                             budget: screenshot ? options.screenshotBudget : options.photoBudget)
        guard vectors.count == ready.count else { throw WorkerError.failed("image result count mismatch") }
        try commitTransaction(batch) {
            for (position, item) in ready.enumerated() {
                let file = batch[item.slot]
                guard let vector = vectors[position].vector else {
                    try store.finish(file.id, state: "failed", detail: vectors[position].error)
                    results[item.slot] = ("failed", vectors[position].error)
                    continue
                }
                try store.addSegment(file: file.id, kind: .image, modality: .image, vector: vector)
                // The words on screen are for keyword search: codes, names and errors typed exactly. Meaning comes from
                // the picture alone; a vector of the words made screenshots outrank better matches (2026-10-08).
                if !item.ocr.isEmpty {
                    try store.addSegment(file: file.id, kind: .ocr, modality: .text, excerpt: excerpt(item.ocr),
                                         text: item.ocr)
                }
                var info = ["width": "\(item.image.width)", "height": "\(item.image.height)"]
                if let taken = item.image.taken { info["taken"] = taken }
                if screenshot { info["ocr_chars"] = "\(item.ocr.count)" }
                try store.finish(file.id, state: "done", info: info)
                results[item.slot] = ("done", screenshot ? "ocr \(item.ocr.count) chars" : nil)
            }
        }
    }

    /// Pages `read` of a PDF (all of a short one, a step of a long one). A long one stays `partial` with `read_to` and
    /// `read_end` (pages, from 0) in its info until its last step.
    private func pdf(_ file: FileRecord, pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?,
                     later: Bool) throws -> (String, String?) {
        let end = min(total, options.maxPages)
        let unread = read.upperBound < end
        guard !pages.isEmpty || later || unread else {
            try store.finish(file.id, state: "skipped", detail: "no pages")
            return ("skipped", "no pages")
        }
        let title = title ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        let textPages = pages.filter { $0.imagePath == nil }
        // A page that's mostly digits (a table, a data listing) gets keyword search only.
        let wordPages = textPages.filter { SearchText.hasWords($0.text) }
        let imagePages = pages.filter { $0.imagePath != nil }
        let savedImages = try vectorPlaces(file: file.id, kind: .pageImage,
                                          from: Double(read.lowerBound + 1), to: Double(read.upperBound + 1))
        let missingImages = imagePages.filter { !savedImages.contains(Double($0.number)) }
        let garbledPages = pages.filter { $0.garbled != nil }   // rendered too: among `imagePages`
        var textVectors: [Int: [Float]] = [:]   // by page number
        var imageVectors: [Embedding] = []
        var garbledVectors: [[Float]] = []
        if !wordPages.isEmpty || !missingImages.isEmpty || !garbledPages.isEmpty {
            let worker = try fullWorker()
            let vectors = try worker.embedTexts(wordPages.map {
                Prompts.document(title: title, text: String($0.text.prefix(4000)))
            })
            textVectors = Dictionary(uniqueKeysWithValues: zip(wordPages.map(\.number), vectors))
            imageVectors = try worker.embedImages(missingImages.compactMap(\.imagePath), budget: options.pageBudget)
            guard vectors.count == wordPages.count, imageVectors.count == missingImages.count else {
                throw WorkerError.failed("PDF result count mismatch")
            }
            garbledVectors = try worker.embedTexts(garbledPages.map {
                Prompts.document(title: title, text: String($0.garbled!.prefix(4000)))
            })
        }
        var result = (unread ? "partial" : "done", Optional<String>.none)
        try commitTransaction([file]) {
            try store.deleteSegments(of: file.id, kind: .page, from: Double(read.lowerBound + 1), through: Double(read.upperBound))
            // Meaning only: the garbled words are never shown or matched against what you type.
            for (page, vector) in zip(garbledPages, garbledVectors) {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number), vector: vector)
            }
            for page in textPages {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number),
                                     excerpt: excerpt(page.text), text: page.text, vector: textVectors[page.number])
            }
            for (page, embedding) in zip(missingImages, imageVectors) {
                try store.deleteSegments(of: file.id, kind: .pageImage, from: Double(page.number), through: Double(page.number))
                try store.addSegment(file: file.id, kind: .pageImage, modality: .image, loc: Double(page.number),
                                     excerpt: page.text.isEmpty ? nil : excerpt(page.text), text: page.text,
                                     vector: embedding.vector)
            }
            var info = later ? try store.info(of: file.id) : [:]
            info["pages"] = "\(total)"
            var scanned = 0
            try store.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND kind = 'page_image'", [.int(file.id)]) {
                scanned = Int($0.int(0))
            }
            info["scanned_pages"] = String(scanned)
            result = try finishStep(file, read: read, end: end, info: info,
                                    failures: imageVectors.compactMap { $0.vector == nil ? ($0.error ?? "missing page vector") : nil },
                                    detail: unread ? "read to page \(read.upperBound) of \(total)"
                                        : end < total ? "the first \(end) of \(total) pages" : nil)
        }
        let ocr = pages.filter(\.ocr).count
        let span = later ? "pages \(read.lowerBound + 1)–\(read.upperBound) of \(total)" : "\(pages.count)/\(total) pages"
        return (result.0, result.1 ?? "\(span), \(imagePages.count) as images" + (ocr > 0 ? ", \(ocr) read by OCR" : ""))
    }

    /// Chunks `read` of a document (all of a short one, a step of a long one), the way `pdf` reads pages.
    private func doc(_ file: FileRecord, chunks: [String], read: Range<Int>, total: Int, characters: Int, later: Bool)
        throws -> (String, String?) {
        guard total > 0 else {
            try store.finish(file.id, state: "skipped", detail: "no text")
            return ("skipped", "no text")
        }
        let title = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        // Text that's mostly digits (a data dump saved as .txt) gets keyword search only.
        let worded = chunks.indices.filter { SearchText.hasWords(chunks[$0]) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: title, text: chunks[$0])
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        let end = min(total, options.maxChunks)
        let unread = read.upperBound < end
        try commitTransaction([file]) {
            for (offset, chunk) in chunks.enumerated() {
                try store.addSegment(file: file.id, kind: .chunk, modality: .text,
                                     loc: Double(read.lowerBound + offset + 1), excerpt: excerpt(chunk), text: chunk,
                                     vector: vector[offset])
            }
            var info = ["chunks": "\(end)", "chars": "\(characters)"]
            info["read_to"] = unread ? "\(read.upperBound)" : nil
            info["read_end"] = unread ? "\(end)" : nil
            let detail = unread ? "read to chunk \(read.upperBound) of \(end)" : end < total ? "the first \(end) chunks" : nil
            try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        }
        let span = later ? "chunks \(read.lowerBound + 1)–\(read.upperBound) of \(end)"
            : unread ? "\(chunks.count) of \(end) chunks" : "\(chunks.count) chunks"
        return (unread ? "partial" : "done",
                span + (worded.count < chunks.count ? ", \(chunks.count - worded.count) for keywords only" : ""))
    }

    /// A code file's stretches of lines (a notebook's of cells), each embedded with the file's path in its repo as its
    /// title, and kept with its lines for keyword search and for opening at the place.
    private func code(_ file: FileRecord, _ code: CodeExtractor.File) throws -> (String, String?) {
        guard !code.pieces.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "no code")
            return ("skipped", "no code")
        }
        // Lines that are mostly numbers and symbols (a table of constants) get keyword search only.
        let worded = code.pieces.indices.filter { SearchText.hasWords(code.pieces[$0].text) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: code.title, text: code.pieces[$0].text)
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        try commitTransaction([file]) {
            for (offset, piece) in code.pieces.enumerated() {
                try store.addSegment(file: file.id, kind: code.cells == nil ? .lines : .cells, modality: .text,
                                     loc: Double(piece.first), locEnd: Double(piece.last),
                                     excerpt: CodeExtractor.summary(piece.text), text: piece.text, vector: vector[offset])
            }
            var info = ["lines": "\(code.lines)"]
            info["cells"] = code.cells.map(String.init)
            info["repo"] = code.repo
            try store.finish(file.id, state: "done", info: info)
        }
        return ("done", "\(code.pieces.count) stretches, \(code.cells.map { "\($0) cells" } ?? "\(code.lines) lines")"
                + (worded.count < code.pieces.count ? ", \(code.pieces.count - worded.count) for keywords only" : ""))
    }

    /// A failed batch keeps successful segments and its starting checkpoint. Retries are bounded, so a bad
    /// input cannot keep the helper busy forever. A later explicit reindex can retry a terminal failure.
    private func finishStep(_ file: FileRecord, read: Range<Int>, end: Int, info initial: [String: String],
                            failures: [String], detail: String? = nil) throws -> (String, String?) {
        var info = initial
        if !failures.isEmpty {
            let previous = try store.info(of: file.id)
            let retries = (previous["embedding_retries"].flatMap(Int.init) ?? 0) + 1
            info["embedding_retries"] = String(retries)
            info["read_to"] = String(read.lowerBound)
            info["read_end"] = String(end)
            let detail = "embedding failed (attempt \(retries)/3): " + failures.prefix(3).joined(separator: "; ")
            try store.finish(file.id, state: retries < 3 ? "partial" : "failed", detail: detail, info: info)
            return ("failed", detail)
        }
        let unread = read.upperBound < end
        info["embedding_retries"] = nil
        info["read_to"] = unread ? String(read.upperBound) : nil
        info["read_end"] = unread ? String(end) : nil
        try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        return (unread ? "partial" : "done", nil)
    }

    private func vectorPlaces(file: Int64, kind: SegmentKind, from: Double, to: Double) throws -> Set<Double> {
        var places = Set<Double>()
        try store.db.query("SELECT loc FROM segments WHERE file = ? AND kind = ? AND vec IS NOT NULL AND loc >= ? AND loc < ?",
                           [.int(file), .text(kind.rawValue), .double(from - 0.00001), .double(to)]) {
            places.insert($0.double(0))
        }
        return places
    }

    private func audio(_ file: FileRecord, pieces: [MediaPiece], duration: Double, read: Range<Int>) throws
        -> (String, String?) {
        let saved = try vectorPlaces(file: file.id, kind: .audio, from: Double(read.lowerBound) * options.audioHop,
                                     to: Double(read.upperBound) * options.audioHop)
        let missing = pieces.filter { !saved.contains($0.start) }
        let vectors = missing.isEmpty ? [] : try fullWorker().embedAudio(missing.map(\.path))
        guard vectors.count == missing.count else { throw WorkerError.failed("audio result count mismatch") }
        let end = Int(ceil(duration / options.audioHop))
        var result = ("done", Optional<String>.none)
        try commitTransaction([file]) {
            for (piece, embedding) in zip(missing, vectors) where embedding.vector != nil {
                try store.deleteSegments(of: file.id, kind: .audio, from: piece.start, through: piece.start)
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start, locEnd: piece.end,
                                     vector: embedding.vector)
            }
            result = try finishStep(file, read: read, end: end, info: ["duration": String(format: "%.1f", duration)],
                                    failures: vectors.compactMap { $0.vector == nil ? ($0.error ?? "missing audio vector") : nil })
        }
        return (result.0, result.1 ?? "\(pieces.count) windows, \(Int(duration)) s")
    }

    private func video(_ file: FileRecord, frames: [MediaPiece], sound: [MediaPiece], duration: Double,
                       read: Range<Int>) throws -> (String, String?) {
        let start = Double(read.lowerBound) * options.audioHop, end = Double(read.upperBound) * options.audioHop
        let savedFrames = try vectorPlaces(file: file.id, kind: .frame, from: start, to: end)
        let savedAudio = try vectorPlaces(file: file.id, kind: .audio, from: start, to: end)
        let missingFrames = frames.filter { !savedFrames.contains($0.start) }
        let missingSound = sound.filter { !savedAudio.contains($0.start) }
        let worker = missingFrames.isEmpty && missingSound.isEmpty ? nil : try fullWorker()
        let frameVectors = try worker?.embedImages(missingFrames.map(\.path), budget: options.frameBudget) ?? []
        let soundVectors = try worker?.embedAudio(missingSound.map(\.path)) ?? []
        guard frameVectors.count == missingFrames.count, soundVectors.count == missingSound.count else {
            throw WorkerError.failed("video result count mismatch")
        }
        var result = ("done", Optional<String>.none)
        try commitTransaction([file]) {
            for (frame, embedding) in zip(missingFrames, frameVectors) where embedding.vector != nil {
                try store.deleteSegments(of: file.id, kind: .frame, from: frame.start, through: frame.start)
                try store.addSegment(file: file.id, kind: .frame, modality: .image, loc: frame.start,
                                     locEnd: frame.end, vector: embedding.vector)
            }
            for (piece, embedding) in zip(missingSound, soundVectors) where embedding.vector != nil {
                try store.deleteSegments(of: file.id, kind: .audio, from: piece.start, through: piece.start)
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start,
                                     locEnd: piece.end, vector: embedding.vector)
            }
            var counts: [String: String] = [:]
            try store.db.query("SELECT kind, COUNT(*) FROM segments WHERE file = ? GROUP BY kind", [.int(file.id)]) {
                counts[$0.text(0) ?? ""] = String($0.int(1))
            }
            let failures = (frameVectors + soundVectors).compactMap { $0.vector == nil ? ($0.error ?? "missing media vector") : nil }
            result = try finishStep(file, read: read, end: Int(ceil(duration / options.audioHop)),
                                    info: ["duration": String(format: "%.1f", duration),
                                           "frames": counts["frame"] ?? "0", "sound_windows": counts["audio"] ?? "0"],
                                    failures: failures)
        }
        return (result.0, result.1 ?? "\(frames.count) frames, \(sound.count) sound windows, \(Int(duration)) s")
    }
}
