import Foundation
import Testing
@testable import DigUpKit

private final class ConsistencyEmbedder: Embedder {
    let info = FakeEmbedder().info
    var mutateText: (() throws -> Void)?
    var failMedia = false
    var failAudioPositions = Set<Int>()
    var largestAudioBatch = 0
    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        if let mutateText { self.mutateText = nil; try mutateText() }
        return texts.map(FakeEmbedder.vector(for:))
    }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { Embedding(vector: failMedia ? nil : FakeEmbedder.vector(for: $0), error: failMedia ? "test failure" : nil) }
    }
    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        largestAudioBatch = max(largestAudioBatch, paths.count)
        return paths.enumerated().map { position, path in
            let failed = failMedia || failAudioPositions.contains(position)
            return Embedding(vector: failed ? nil : FakeEmbedder.vector(for: path), error: failed ? "test failure" : nil)
        }
    }
    func close() {}
}

@Suite final class IndexingConsistencyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpConsistency-" + UUID().uuidString)
    var files: URL { root.appendingPathComponent("files") }
    init() throws { try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func store() throws -> IndexStore { try IndexStore(directory: root.appendingPathComponent("index")) }
    private func make(_ store: IndexStore, _ options: IndexOptions = IndexOptions(), _ worker: ConsistencyEmbedder = ConsistencyEmbedder()) throws -> Indexer {
        try Indexer(store: store, options: options, makeEmbedder: { worker })
    }
    func row(_ store: IndexStore) throws -> FileRecord { try #require(store.files(under: [files.path]).first) }
    func count(_ store: IndexStore, kind: String) throws -> Int {
        var count = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE kind = ?", [.text(kind)]) { count = Int($0.int(0)) }
        return count
    }

    @Test func replacementWithPreservedDateIsRequeued() throws {
        let file = files.appendingPathComponent("notes.txt")
        try "the old notes".write(to: file, atomically: false, encoding: .utf8)
        let store = try store(), indexer = try make(store)
        _ = try indexer.sync([files]); try indexer.run()
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate])
        let replacement = root.appendingPathComponent("replacement.txt")
        try "the new notes".write(to: replacement, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        #expect(try indexer.sync([files]).changed == 1)
        #expect(try count(store, kind: "chunk") == 0)
    }

    @Test func editsDuringEmbeddingNeverCommitOldContent() throws {
        let file = files.appendingPathComponent("notes.txt")
        try "words before the edit".write(to: file, atomically: false, encoding: .utf8)
        let worker = ConsistencyEmbedder()
        worker.mutateText = { try "entirely different words after the edit".write(to: file, atomically: true, encoding: .utf8) }
        let store = try store(), indexer = try make(store, IndexOptions(), worker)
        _ = try indexer.sync([files]); try indexer.run()
        #expect(try row(store).state == "pending")
        #expect(try count(store, kind: "chunk") == 0)
        try indexer.run()
        #expect(try row(store).state == "done")
        #expect(indexer.documentExtractions == 2)
    }

    @Test func longDocumentsAreExtractedOncePerVersion() throws {
        let file = files.appendingPathComponent("book.txt")
        try String(repeating: "A readable book with useful words and complete sentences. ", count: 300).write(to: file, atomically: false, encoding: .utf8)
        var options = IndexOptions(); options.docStep = 1
        let store = try store(), indexer = try make(store, options)
        _ = try indexer.sync([files]); try indexer.run(); try indexer.finishLongFiles()
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "chunk") > 5)
        #expect(indexer.documentExtractions == 1)
    }

    @Test func extractionPolicyRequeuesOnlyAffectedKinds() throws {
        try String(repeating: "A readable book with complete sentences. ", count: 200).write(to: files.appendingPathComponent("book.txt"), atomically: false, encoding: .utf8)
        let store = try store()
        var options = IndexOptions(); options.maxChunks = 1
        let first = try make(store, options)
        _ = try first.sync([files]); try first.run()
        let id = try row(store).id
        #expect(try store.info(of: id)["chunks"] == "1")
        options.maxChunks = 8
        let second = try make(store, options)
        try second.run(); try second.finishLongFiles()
        #expect(try store.info(of: id)["chunks"] != "1")
        #expect(try store.meta("fingerprint") == "\(FakeEmbedder().info.vectorSource) | \(options.fingerprint)")
    }

    @Test func skippedContinuationDoesNotExtractEveryRemainingJob() throws {
        try "A short document whose old length estimate was much too large.".write(to: files.appendingPathComponent("short.txt"), atomically: false, encoding: .utf8)
        let store = try store(), indexer = try make(store)
        _ = try indexer.sync([files])
        let id = try row(store).id
        try store.finish(id, state: "partial", info: ["read_to": "0", "read_end": "5000"])
        try indexer.finishLongFiles()
        #expect(indexer.documentExtractions == 1)
        #expect(try count(store, kind: "chunk") == 1)
    }

    @Test func unreadableSubtreeKeepsItsExistingRows() throws {
        #if !os(Windows)
        let blocked = files.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "keep these notes".write(to: blocked.appendingPathComponent("notes.txt"), atomically: false, encoding: .utf8)
        let store = try store(), indexer = try make(store)
        _ = try indexer.sync([files])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        // A privileged runner may still enumerate it; normal users exercise the failure branch.
        let summary = try indexer.sync([files])
        #expect(summary.removed == 0)
        #expect(try store.files(under: [files.path]).count == 1)
        #endif
    }

    @Test func selectedRootAliasesKeepGitAndDatasetPolicies() throws {
        for index in 0..<300 {
            FileManager.default.createFile(atPath: files.appendingPathComponent(String(format: "clip_%06d.mp3", index)).path, contents: Data())
        }
        #expect(Crawler.crawl([files], options: IndexOptions()).candidates.count == 300)
        guard let git = FileSystem.git else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["init", "--quiet", files.path]
        try process.run(); process.waitUntilExit()
        try "skip.py\n".write(to: files.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try "def keep(): return 42".write(to: files.appendingPathComponent("keep.py"), atomically: false, encoding: .utf8)
        try "def skip(): return 42".write(to: files.appendingPathComponent("skip.py"), atomically: false, encoding: .utf8)
        var options = IndexOptions(); options.code = true
        #expect(Crawler.crawl([files], options: options).candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["keep.py"])
    }

    @Test func discoveryCacheKeepsDistinctFileTitlesAndCanBeInvalidated() throws {
        let cache = CodeExtractor.DiscoveryCache()
        let first = CodeExtractor.place(of: files.appendingPathComponent("first.py").path, discovery: cache)
        let second = CodeExtractor.place(of: files.appendingPathComponent("second.py").path, discovery: cache)
        #expect(first.title.hasSuffix("first.py"))
        #expect(second.title.hasSuffix("second.py"))
        try "{}".write(to: files.appendingPathComponent("package.json"), atomically: false, encoding: .utf8)
        let refreshed = CodeExtractor.place(of: files.appendingPathComponent("first.py").path, discovery: CodeExtractor.DiscoveryCache())
        #expect(refreshed.repo == files.path)
    }

    @Test func audioCheckpointsAreBoundedAndFailedWindowsCanResume() throws {
        let audio = files.appendingPathComponent("recording.wav")
        let samples = [Int16](repeating: 4000, count: 80 * Int(AudioExtractor.sampleRate))
        try AudioExtractor.writeWAV(samples[...], to: audio)
        var options = IndexOptions(); options.mediaWindowsPerStep = 1
        let worker = ConsistencyEmbedder(), store = try store(), indexer = try make(store, options, worker)
        _ = try indexer.sync([files]); try indexer.run()
        let id = try row(store).id
        #expect(try row(store).state == "partial")
        #expect(try store.info(of: id)["read_to"] == "1")
        #expect(try count(store, kind: "audio") == 1)
        worker.failMedia = true
        try indexer.finishLongFiles()
        #expect(try row(store).state == "partial")
        #expect(try count(store, kind: "audio") == 1)
        #expect(try store.info(of: id)["read_to"] == "1")
        worker.failMedia = false
        try indexer.finishLongFiles()
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "audio") == 4)
        #expect(worker.largestAudioBatch == 1)
    }

    @Test func failedPDFImagesStayRetryableInsteadOfReportingDone() throws {
        try TextPDF.write(["short caption"], to: files.appendingPathComponent("slide.pdf"))
        let worker = ConsistencyEmbedder(); worker.failMedia = true
        let store = try store(), indexer = try make(store, IndexOptions(), worker)
        _ = try indexer.sync([files]); try indexer.run()
        #expect(try row(store).state == "partial")
        #expect(try store.info(of: row(store).id)["embedding_retries"] == "1")
        worker.failMedia = false
        try indexer.finishLongFiles()
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "page_image") == 1)
    }

    @Test func mediaRetriesStopAfterThreeAttempts() throws {
        let samples = [Int16](repeating: 4000, count: 3 * Int(AudioExtractor.sampleRate))
        try AudioExtractor.writeWAV(samples[...], to: files.appendingPathComponent("short.wav"))
        let worker = ConsistencyEmbedder(); worker.failMedia = true
        let store = try store(), indexer = try make(store, IndexOptions(), worker)
        _ = try indexer.sync([files]); try indexer.run()
        try indexer.finishLongFiles(); try indexer.finishLongFiles()
        #expect(try row(store).state == "failed")
        #expect(try store.info(of: row(store).id)["embedding_retries"] == "3")
        #expect(try store.unfinishedCount().files == 0)
        #expect(try indexer.finishLongFiles().isEmpty)
    }

    @Test func videoCheckpointsContinueAcrossShots() throws {
        try FileManager.default.copyItem(at: VideoTests.shots, to: files.appendingPathComponent("shots.ts"))
        var options = IndexOptions()
        options.audioHop = 4; options.audioWindow = 5; options.mediaWindowsPerStep = 1
        let store = try store(), indexer = try make(store, options)
        _ = try indexer.sync([files]); try indexer.run()
        #expect(try row(store).state == "partial")
        #expect(try store.info(of: row(store).id)["read_to"] == "1")
        try indexer.finishLongFiles()
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "frame") == 3)
    }

    @Test func retryingOneWindowDoesNotReembedOrEraseSuccessfulWindows() throws {
        let samples = [Int16](repeating: 4000, count: 80 * Int(AudioExtractor.sampleRate))
        try AudioExtractor.writeWAV(samples[...], to: files.appendingPathComponent("recording.wav"))
        var options = IndexOptions(); options.mediaWindowsPerStep = 3
        let worker = ConsistencyEmbedder(); worker.failAudioPositions = [1]
        let store = try store(), indexer = try make(store, options, worker)
        _ = try indexer.sync([files]); try indexer.run()
        #expect(try count(store, kind: "audio") == 2)
        worker.failAudioPositions = []; worker.failMedia = true
        try indexer.finishLongFiles()
        #expect(try count(store, kind: "audio") == 2)
        worker.failMedia = false
        try indexer.finishLongFiles()
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "audio") == 4)
    }

    @Test func legacyCodePolicyIsRebuiltOnceWithoutResettingOtherKinds() throws {
        try "def useful_function(): return 42".write(to: files.appendingPathComponent("source.py"), atomically: false, encoding: .utf8)
        var options = IndexOptions(); options.code = true
        let store = try store(), indexer = try make(store, options)
        _ = try indexer.sync([files]); try indexer.run()
        let id = try row(store).id
        try store.setMeta("extraction_code", nil) // an upstream index has no extraction policy metadata
        try indexer.checkModel()
        #expect(try row(store).state == "pending")
        #expect(try count(store, kind: "lines") == 0)
        try indexer.run()
        try indexer.checkModel()
        #expect(try row(store).id == id)
        #expect(try row(store).state == "done")
        #expect(try count(store, kind: "lines") == 1)
    }
}
