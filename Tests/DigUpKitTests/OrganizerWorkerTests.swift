import Foundation
import Testing
@testable import DigUpKit

/// Exercises the complete organizer policy with real temporary files and deterministic local vectors.
@Suite struct OrganizerWorkerTests {
    private final class Fixture {
        let home: URL
        let downloads: URL
        let desktop: URL
        let documents: URL
        let atlas: URL
        let loose: URL
        let destination: URL
        let index: IndexStore
        let worker: OrganizerWorker
        let fm = FileManager.default

        init(age: TimeInterval = 3_600, looseAxis: Int = 0) throws {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("DigUpOrganizerWorker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            home = URL(fileURLWithPath: FolderSelection.realPath(temporary.path))
            downloads = home.appendingPathComponent("Downloads")
            desktop = home.appendingPathComponent("Desktop")
            documents = home.appendingPathComponent("Documents")
            atlas = documents.appendingPathComponent("Atlas")
            loose = downloads.appendingPathComponent("new-research.md")
            destination = atlas.appendingPathComponent(loose.lastPathComponent)
            for folder in [downloads, desktop, atlas] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            index = try IndexStore(directory: home.appendingPathComponent("index.noindex"))
            worker = OrganizerWorker(directory: index.directory)
            try index.setMeta("vector_source", "local-integration-fixture")
            try add(atlas.appendingPathComponent("research-notes.md"), contents: "Atlas research", axis: 0, age: age)
            try add(atlas.appendingPathComponent("project-budget.md"), contents: "Atlas budget", axis: 0, age: age)
            try add(loose, contents: "New research for Atlas", axis: looseAxis, age: age)
        }

        deinit { try? FileManager.default.removeItem(at: home) }
        var roots: [URL] { [downloads, desktop, documents] }
        func exists(_ file: URL) -> Bool { fm.fileExists(atPath: file.path) }
        func contents(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

        func config(automatic: Bool = false, enabled: Bool = true, roots: [URL]? = nil,
                    excluded: [URL] = [], types: Set<String> = [], revision: UInt64? = nil) -> OrganizerConfiguration {
            OrganizerConfiguration(roots: roots ?? self.roots, excluded: excluded, excludedTypes: types,
                                   enabled: enabled, automatic: automatic, revision: revision ?? worker.revision)
        }

        func grouped() throws -> OrganizerWorker.Output { try worker.perform(.refresh, config: config()) }

        func add(_ file: URL, contents: String, axis: Int, age: TimeInterval) throws {
            try contents.write(to: file, atomically: false, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
            let info = try #require(FileSystem.info(of: file.path))
            let candidate = Candidate(path: file.path, kind: .doc, size: info.size, mtime: info.mtime,
                                      inode: info.inode, device: info.device)
            let id = try index.insert(candidate)
            var vector = [Float](repeating: 0, count: 768)
            vector[axis] = 1
            try index.addSegment(file: id, kind: .chunk, modality: .text, vector: vector)
            try index.finish(id, state: "done")
        }
    }

    @Test func strongLocalMatchFilesAcrossRootsAndPersistentUndoPreventsRefiling() throws {
        let fixture = try Fixture()
        let grouped = try fixture.grouped()
        let assignment = try #require(grouped.snapshot.assignments.first { $0.path == fixture.loose.path })
        let project = try #require(grouped.snapshot.projects.first { $0.id == assignment.projectID })
        #expect(assignment.reason == .semantic)
        #expect(assignment.canMoveAutomatically)
        #expect(project.destinationPath == fixture.atlas.path)
        #expect(!grouped.moved)
        #expect(fixture.exists(fixture.loose))

        let filed = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(filed.moved)
        #expect(filed.problem == nil)
        #expect(!fixture.exists(fixture.loose))
        #expect(try fixture.contents(fixture.destination) == "New research for Atlas")
        let record = try #require(filed.history.first)
        #expect(record.state == .moved)

        // Reopening the worker exercises the durable journal rather than in-memory undo state.
        let reopened = OrganizerWorker(directory: fixture.index.directory)
        let configuration = OrganizerConfiguration(roots: fixture.roots, automatic: true, revision: reopened.revision)
        let undone = try reopened.perform(.undo(record.id), config: configuration)
        #expect(undone.moved)
        #expect(undone.history.first?.state == .undone)
        #expect(try fixture.contents(fixture.loose) == "New research for Atlas")
        #expect(!fixture.exists(fixture.destination))
        let after = try reopened.perform(.refresh, config: configuration)
        #expect(!after.moved)
        #expect(after.history.count == 1)
        #expect(fixture.exists(fixture.loose))
        #expect(!fixture.exists(fixture.destination))
    }

    @Test func groupingAndAutomaticFilingCanBeDisabledIndependently() throws {
        let fixture = try Fixture()
        let disabled = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true, enabled: false))
        #expect(!disabled.moved)
        #expect(disabled.history.isEmpty)
        #expect(fixture.exists(fixture.loose))
        let virtual = try fixture.grouped()
        #expect(virtual.snapshot.assignments.contains { $0.path == fixture.loose.path && $0.canMoveAutomatically })
        #expect(!virtual.moved)
        #expect(virtual.history.isEmpty)
        #expect(fixture.exists(fixture.loose))
        #expect(!fixture.exists(fixture.destination))
    }

    @Test func newlyWrittenFilesWaitBeforeAutomaticFiling() throws {
        let fixture = try Fixture(age: 0)
        let output = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(output.snapshot.assignments.contains { $0.path == fixture.loose.path && $0.canMoveAutomatically })
        #expect(!output.moved)
        #expect(output.history.isEmpty)
        #expect(fixture.exists(fixture.loose))
    }

    @Test func editedSourceCannotBeFiledFromAnOldIndexedVersion() throws {
        let fixture = try Fixture()
        _ = try fixture.grouped()
        try "Newer edited contents that have not been indexed yet".write(to: fixture.loose,
                                                                         atomically: false, encoding: .utf8)
        let output = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(!output.moved)
        #expect(output.problem != nil)
        #expect(output.history.isEmpty)
        #expect(try fixture.contents(fixture.loose) == "Newer edited contents that have not been indexed yet")
        #expect(!fixture.exists(fixture.destination))
    }

    @Test func atomicallyReplacedSourceWithTheSameSizeAndDateCannotBeFiled() throws {
        let fixture = try Fixture()
        _ = try fixture.grouped()
        let before = try #require(FileSystem.info(of: fixture.loose.path))
        let replacement = fixture.downloads.appendingPathComponent("replacement.tmp")
        let replacementContents = String(repeating: "X", count: Int(before.size))
        try replacementContents.write(to: replacement, atomically: false, encoding: .utf8)
        try fixture.fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.mtime)],
                                     ofItemAtPath: replacement.path)
        try fixture.fm.removeItem(at: fixture.loose)
        try fixture.fm.moveItem(at: replacement, to: fixture.loose)
        let after = try #require(FileSystem.info(of: fixture.loose.path))
        #expect(after.inode != before.inode)
        #expect(after.size == before.size)
        #expect(after.mtime == before.mtime)
        let output = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(!output.moved)
        #expect(output.problem != nil)
        #expect(output.history.isEmpty)
        #expect(try fixture.contents(fixture.loose) == replacementContents)
        #expect(!fixture.exists(fixture.destination))
    }

    @Test func currentPolicyRejectsExplicitMovesOutsideRootsOrIntoExclusions() throws {
        let fixture = try Fixture()
        let assignment = try #require(try fixture.grouped().snapshot.assignments.first { $0.path == fixture.loose.path })
        let policies = [
            ("disabled", fixture.config(enabled: false)),
            ("source root revoked", fixture.config(roots: [fixture.documents])),
            ("destination root revoked", fixture.config(roots: [fixture.downloads])),
            ("source folder excluded", fixture.config(excluded: [fixture.downloads])),
            ("destination folder excluded", fixture.config(excluded: [fixture.atlas])),
            ("file type excluded", fixture.config(types: ["md"])),
        ]
        for (name, policy) in policies {
            #expect(throws: OrganizerMoveJournal.Failure.self, "Policy: \(name)") {
                try fixture.worker.perform(.move(assignment), config: policy)
            }
            #expect(fixture.exists(fixture.loose))
            #expect(!fixture.exists(fixture.destination))
        }
        let output = try fixture.grouped()
        #expect(output.history.isEmpty)
    }

    @Test func automaticFilingHonorsRootAndTypePolicyChanges() throws {
        let fixture = try Fixture()
        _ = try fixture.grouped()
        let policies = [
            fixture.config(automatic: true, roots: [fixture.downloads]),
            fixture.config(automatic: true, roots: [fixture.documents]),
            fixture.config(automatic: true, excluded: [fixture.atlas]),
            fixture.config(automatic: true, excluded: [fixture.downloads]),
            fixture.config(automatic: true, types: ["md"]),
        ]
        for policy in policies {
            let output = try fixture.worker.perform(.refresh, config: policy)
            #expect(!output.moved)
            #expect(output.history.isEmpty)
            #expect(fixture.exists(fixture.loose))
            #expect(!fixture.exists(fixture.destination))
        }
    }

    @Test func cancelledQueuedJobsCannotUseAStalePolicy() throws {
        let fixture = try Fixture()
        let assignment = try #require(try fixture.grouped().snapshot.assignments.first { $0.path == fixture.loose.path })
        let stale = fixture.config(automatic: true)
        fixture.worker.invalidate()
        for action in [OrganizerWorker.Action.refresh, .move(assignment)] {
            let output = try fixture.worker.perform(action, config: stale)
            #expect(!output.moved)
            #expect(output.history.isEmpty)
            #expect(fixture.exists(fixture.loose))
            #expect(!fixture.exists(fixture.destination))
        }
        let current = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(current.moved)
        #expect(fixture.exists(fixture.destination))
    }

    @Test func collidingAutomaticDestinationsPreserveBothFilesWithoutRepeatedJournalEntries() throws {
        let fixture = try Fixture()
        try "Existing project file".write(to: fixture.destination, atomically: false, encoding: .utf8)
        for _ in 0..<2 {
            let output = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
            #expect(!output.moved)
            #expect(output.problem == nil)
            #expect(output.history.isEmpty)
        }
        #expect(try fixture.contents(fixture.loose) == "New research for Atlas")
        #expect(try fixture.contents(fixture.destination) == "Existing project file")
    }

    @Test func moreThanTenCollisionsDoNotStarveAnEligibleAutomaticMove() throws {
        let fixture = try Fixture()
        for n in 0..<12 {
            let filename = String(format: "aaa-collision-%02d.md", n)
            try fixture.add(fixture.downloads.appendingPathComponent(filename), contents: "Incoming \(n)", axis: 0,
                            age: 3_600)
            try "Existing \(n)".write(to: fixture.atlas.appendingPathComponent(filename), atomically: false,
                                     encoding: .utf8)
        }
        let output = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(output.moved)
        #expect(output.problem == nil)
        #expect(output.history.count == 1)
        #expect(!fixture.exists(fixture.loose))
        #expect(try fixture.contents(fixture.destination) == "New research for Atlas")
        #expect(try fixture.contents(fixture.downloads.appendingPathComponent("aaa-collision-00.md")) == "Incoming 0")
        #expect(try fixture.contents(fixture.atlas.appendingPathComponent("aaa-collision-00.md")) == "Existing 0")
    }

    @Test func browsingHistoryDoesNotTriggerAutomaticFiling() throws {
        let fixture = try Fixture()
        _ = try fixture.grouped()
        let output = try fixture.worker.perform(.history(50), config: fixture.config(automatic: true))
        #expect(!output.moved)
        #expect(output.history.isEmpty)
        #expect(output.historyOffset == 50)
        #expect(!output.hasOlderHistory)
        #expect(fixture.exists(fixture.loose))
        #expect(!fixture.exists(fixture.destination))
    }

    @Test func uncertainFileCanBeAssignedThenExplicitlyFiled() throws {
        let fixture = try Fixture(looseAxis: 1)
        let before = try fixture.grouped()
        #expect(before.snapshot.reviewItems.contains { $0.path == fixture.loose.path })
        let project = try #require(before.snapshot.projects.first { $0.name == "Atlas" })
        let assigned = try fixture.worker.perform(.assign(fixture.loose.path, project.id), config: fixture.config())
        let assignment = try #require(assigned.snapshot.assignments.first { $0.path == fixture.loose.path })
        #expect(assignment.reason == .manual)
        #expect(!assignment.canMoveAutomatically)
        #expect(!assigned.moved)
        #expect(fixture.exists(fixture.loose))
        let filed = try fixture.worker.perform(.move(assignment), config: fixture.config())
        #expect(filed.moved)
        #expect(!fixture.exists(fixture.loose))
        #expect(try fixture.contents(fixture.destination) == "New research for Atlas")
    }

    @Test func successfulMoveRemainsUndoableWhenGroupingRefreshFails() throws {
        let fixture = try Fixture()
        let assignment = try #require(try fixture.grouped().snapshot.assignments.first { $0.path == fixture.loose.path })
        // Simulate an unavailable index after a valid plan was produced; the independent move journal must survive.
        try fixture.index.db.execute("DROP TABLE search_state")
        let filed = try fixture.worker.perform(.move(assignment), config: fixture.config())
        #expect(filed.moved)
        #expect(filed.problem != nil)
        #expect(!fixture.exists(fixture.loose))
        #expect(try fixture.contents(fixture.destination) == "New research for Atlas")
        let record = try #require(filed.history.first)
        #expect(record.state == .moved)
        #expect(record.canUndo)
        let undone = try fixture.worker.perform(.undo(record.id), config: fixture.config())
        #expect(undone.moved)
        #expect(undone.history.first?.state == .undone)
        #expect(try fixture.contents(fixture.loose) == "New research for Atlas")
        #expect(!fixture.exists(fixture.destination))
    }
}
