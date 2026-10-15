import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchConsistencyTests {
    private func withStore(_ body: (IndexStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpSearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(IndexStore(directory: folder))
    }

    private func vector(_ axis: Int, _ value: Float = 1) -> [Float] {
        var values = [Float](repeating: 0, count: 768)
        values[axis] = value
        return values
    }

    @discardableResult
    private func add(_ store: IndexStore, _ path: String, text: String? = nil, values: [Float]? = nil,
                     kind: FileKind = .doc) throws -> Int64 {
        let file = try store.insert(Candidate(path: path, kind: kind, size: 10, mtime: 1, inode: UInt64(path.count), device: 1))
        if text != nil || values != nil {
            try store.addSegment(file: file, kind: .chunk, modality: .text, loc: 1, text: text, vector: values)
        }
        return file
    }

    @Test func sourceValidationUsesTheLoadedSnapshotAndKeepsKeywordFallback() throws {
        try withStore { store in
            try store.setMeta("vector_source", "source-A")
            for n in 0..<30 { try add(store, "/background/\(n).txt", values: vector(1)) }
            try add(store, "/notes/quasar.txt", text: "quasar", values: vector(0))
            let searcher = try Searcher(store: store, loadVectors: false)
            try store.setMeta("vector_source", "source-B")
            let wrong = try searcher.search("quasar", query: .init(values: vector(0), source: "source-A"))
            #expect(searcher.vectorSource == "source-B")
            #expect(!searcher.lastQueryUsedMeaning)
            #expect(!searcher.vectorsLoaded)
            #expect(searcher.refreshedVectorRows == 0)
            #expect(wrong.map(\.path) == ["/notes/quasar.txt"])
            #expect(wrong.first?.cosine == nil)
            let right = try searcher.search("", query: .init(values: vector(0), source: "source-B"))
            #expect(searcher.lastQueryUsedMeaning)
            #expect(right.first?.path == "/notes/quasar.txt")
        }
    }

    @Test func keywordMetadataRefreshesWithoutLoadingVectors() throws {
        try withStore { store in
            let searcher = try Searcher(store: store, loadVectors: false)
            try add(store, "/notes/quasar.png", text: "quasar", kind: .image)
            let hits = try searcher.search("quasar", queryVector: nil, kinds: [.image])
            #expect(hits.map(\.path) == ["/notes/quasar.png"])
            #expect(!searcher.vectorsLoaded)
            #expect(searcher.refreshedVectorRows == 0)
        }
    }

    @Test func identitiesAreNotReusedAndReplacementCannotBorrowDeletedVectors() throws {
        try withStore { store in
            for n in 0..<30 { try add(store, "/background/\(n).txt", values: vector(1)) }
            let old = try add(store, "/notes/old.txt", values: vector(0))
            let searcher = try Searcher(store: store)
            var oldSegment: Int64 = 0
            try store.db.query("SELECT MAX(id) FROM segments") { oldSegment = $0.int(0) }
            try store.delete(old)
            let replacement = try add(store, "/notes/replacement.txt", values: vector(0, -1))
            var newSegment: Int64 = 0
            try store.db.query("SELECT MAX(id) FROM segments") { newSegment = $0.int(0) }
            #expect(replacement > old)
            #expect(newSegment > oldSegment)
            #expect(try searcher.search("", queryVector: vector(0)).isEmpty)
            #expect(!searcher.refreshWasFull)
            #expect(searcher.refreshedVectorRows == 1)
        }
    }

    @Test func readersShareOneDeferredSnapshotWhileAnotherConnectionCommits() throws {
        try withStore { store in
            try add(store, "/notes/initial.txt", values: vector(0))
            let writer = try IndexStore(directory: store.directory)
            var searcher: Searcher?
            try store.db.readTransaction {
                // Pin the snapshot before the writer commits; a deferred reader must not reserve its write lock.
                _ = try store.searchGeneration()
                try add(writer, "/notes/later.txt", values: vector(1))
                searcher = try Searcher(store: store)
                #expect(searcher?.vectorCount == 1)
            }
            try searcher?.refresh()
            #expect(searcher?.vectorCount == 2)
            #expect(searcher?.refreshedVectorRows == 1)
            #expect(searcher?.refreshWasFull == false)
        }
    }

    @Test func incrementalReplacementMatchesACompleteSnapshot() throws {
        try withStore { store in
            for n in 0..<50 { try add(store, "/background/\(n).txt", values: vector(1)) }
            let target = try add(store, "/notes/target.txt", values: vector(0, -1))
            let searcher = try Searcher(store: store)
            try searcher.refresh()
            #expect(searcher.refreshedVectorRows == 0)
            try store.finish(target, state: "done", info: ["pages": "1"])
            try searcher.refresh()
            #expect(searcher.refreshedVectorRows == 0)
            try store.db.transaction {
                try store.deleteSegments(of: target)
                try store.addSegment(file: target, kind: .chunk, modality: .text, loc: 1, vector: vector(0))
                try store.move(target, to: "/notes/moved.txt")
            }
            let incremental = try searcher.search("", queryVector: vector(0))
            #expect(searcher.refreshedVectorRows == 1)
            #expect(!searcher.refreshWasFull)
            let complete = try Searcher(store: store).search("", queryVector: vector(0))
            #expect(incremental.map(\.path) == complete.map(\.path))
            #expect(incremental.first?.path == "/notes/moved.txt")
            #expect(abs((incremental.first?.score ?? 0) - (complete.first?.score ?? 0)) < 0.00001)
        }
    }

    @Test func missingJournalHistoryFallsBackToAFullSnapshot() throws {
        try withStore { store in
            try add(store, "/notes/first.txt", values: vector(0))
            let searcher = try Searcher(store: store)
            try add(store, "/notes/second.txt", values: vector(1))
            try store.db.execute("UPDATE search_state SET floor = generation")
            try searcher.refresh()
            #expect(searcher.vectorCount == 2)
            #expect(searcher.refreshWasFull)
            #expect(searcher.refreshedVectorRows == 2)
        }
    }

    @Test func aLongFileCannotHideOtherKeywordMatches() throws {
        try withStore { store in
            let long = try add(store, "/notes/long.txt")
            try store.db.transaction {
                for place in 1...1100 {
                    try store.addSegment(file: long, kind: .chunk, modality: .text, loc: Double(place), text: "quasar")
                }
                try add(store, "/notes/other.txt", text: "quasar with additional context")
            }
            let hits = try Searcher(store: store, loadVectors: false).search("quasar", queryVector: nil)
            #expect(Set(hits.map(\.path)) == Set(["/notes/long.txt", "/notes/other.txt"]))
        }
    }

    @Test func scopeAndKindAreAppliedBeforeTheDistinctFileBudgetAndLimit() throws {
        try withStore { store in
            try store.db.transaction {
                for n in 0..<120 { try add(store, "/excluded/\(n).txt", text: "quasar") }
                try add(store, "/included/wanted.png", text: "quasar other context", kind: .image)
            }
            let searcher = try Searcher(store: store, loadVectors: false)
            let scoped = try searcher.search("quasar", queryVector: nil, limit: 1,
                                             eligible: { path, _ in path.hasPrefix("/included/") })
            let typed = try searcher.search("quasar", queryVector: nil, kinds: [.image], limit: 1)
            #expect(scoped.map(\.path) == ["/included/wanted.png"])
            #expect(typed.map(\.path) == scoped.map(\.path))
        }
    }

    @Test func lexicalTiesPreserveBM25Relevance() throws {
        try withStore { store in
            try add(store, "/notes/random.txt", text: "quasar incidental context with unrelated explanations")
            try add(store, "/notes/quasar.txt")
            let hits = try Searcher(store: store, loadVectors: false).search("quasar", queryVector: nil)
            #expect(hits.first?.path == "/notes/quasar.txt")
            #expect(hits.first?.keywordRank == 1)
        }
    }

    @Test func compoundWritesAndJournalRollbackTogether() throws {
        try withStore { store in
            enum Stop: Error { case expected }
            let before = try store.searchGeneration().current
            do {
                try store.db.transaction {
                    try add(store, "/notes/rolled-back.txt", text: "quasar", values: vector(0))
                    throw Stop.expected
                }
            } catch Stop.expected {}
            #expect(try store.searchGeneration().current == before)
            #expect(try store.files(under: ["/notes"]).isEmpty)
            #expect(try Searcher(store: store).search("quasar", queryVector: nil).isEmpty)
        }
    }

    @Test func schemaFivePreservesContentAndMigratesToNonReusedIdentities() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Database(path: folder.appendingPathComponent("index.sqlite").path)
        try db.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                size INTEGER NOT NULL, mtime REAL NOT NULL, inode INTEGER NOT NULL, device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', detail TEXT, info TEXT, indexed_at REAL);
            CREATE INDEX files_inode ON files(device,inode);
            CREATE INDEX files_state ON files(state,kind);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, modality TEXT NOT NULL, loc REAL, loc_end REAL, excerpt TEXT, vec BLOB);
            CREATE INDEX segments_file ON segments(file);
            CREATE VIRTUAL TABLE fts USING fts5(\(IndexStore.ftsColumns));
            INSERT INTO files VALUES(7,'/notes/retained.txt','doc',10,1,1,1,'done',NULL,NULL,1);
            INSERT INTO segments VALUES(11,7,'chunk','text',1,NULL,'retained',zeroblob(1536));
            INSERT INTO fts(rowid,name,body) VALUES(11,'','quasar retained');
            PRAGMA user_version = 5;
            """)
        let store = try IndexStore(directory: folder)
        let hits = try Searcher(store: store, loadVectors: false).search("quasar", queryVector: nil)
        #expect(hits.map(\.path) == ["/notes/retained.txt"])
        #expect(hits.first?.segmentID == 11)
        var brokenReferences = 0
        try store.db.query("PRAGMA foreign_key_check") { _ in brokenReferences += 1 }
        #expect(brokenReferences == 0)
        try store.delete(7)
        let replacement = try add(store, "/notes/new.txt", text: "quasar")
        #expect(replacement > 7)
        var newSegment: Int64 = 0
        try store.db.query("SELECT MAX(id) FROM segments") { newSegment = $0.int(0) }
        #expect(newSegment > 11)
    }

    @Test func removingAMatrixRowKeepsTheSwappedFilesVectorAndLocation() throws {
        try withStore { store in
            let removed = try add(store, "/notes/remove-first.txt", values: vector(0, -1))
            for n in 0..<30 { try add(store, "/background/\(n).txt", values: vector(1)) }
            let target = try add(store, "/notes/target.txt")
            try store.addSegment(file: target, kind: .page, modality: .text, loc: 9, vector: vector(0))
            try store.addSegment(file: target, kind: .page, modality: .text, loc: 10, vector: vector(0))
            let searcher = try Searcher(store: store)
            try store.delete(removed)
            let hits = try searcher.search("", queryVector: vector(0))
            #expect(hits.first?.path == "/notes/target.txt")
            #expect(hits.first?.loc == 9)
            #expect(searcher.refreshedVectorRows == 0)
            #expect(searcher.vectorCount == 32)
        }
    }

    @Test func unavailableWinnersAreReplacedBeforeApplyingTheResultLimit() throws {
        try withStore { store in
            try store.db.transaction {
                for n in 0..<120 { try add(store, "/missing/\(n).txt", text: "quasar") }
                try add(store, "/available/wanted.txt", text: "quasar other context")
            }
            let searcher = try Searcher(store: store, loadVectors: false)
            let hits = try searcher.search("quasar", queryVector: nil, limit: 1,
                                           available: { $0.hasPrefix("/available/") })
            #expect(hits.map(\.path) == ["/available/wanted.txt"])
        }
    }

    @Test func semanticAvailabilityChecksOnlyRankedCandidatesAndRefillsTheLimit() throws {
        try withStore { store in
            try store.db.transaction {
                for n in 0..<40 { try add(store, "/missing/\(n).txt", values: vector(0)) }
                try add(store, "/available/wanted.txt", values: vector(0))
                for n in 0..<250 { try add(store, "/background/\(n).txt", values: vector(1)) }
            }
            let searcher = try Searcher(store: store)
            var checks = 0
            let hits = try searcher.search("", queryVector: vector(0), limit: 1, available: {
                checks += 1
                return $0.hasPrefix("/available/")
            })
            #expect(hits.map(\.path) == ["/available/wanted.txt"])
            #expect(checks == 41)
        }
    }

}
