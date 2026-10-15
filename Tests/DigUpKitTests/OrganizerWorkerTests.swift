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

        init(age: TimeInterval = 3_600, looseAxis: Int = 0, seedExisting: Bool = true) throws {
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
            if seedExisting {
                try add(atlas.appendingPathComponent("research-notes.md"), contents: "Atlas research", axis: 0, age: age)
                try add(atlas.appendingPathComponent("project-budget.md"), contents: "Atlas budget", axis: 0, age: age)
            }
            try add(loose, contents: "New research for Atlas", axis: looseAxis, age: age)
        }

        deinit { try? FileManager.default.removeItem(at: home) }
        var roots: [URL] { [downloads, desktop, documents] }
        func exists(_ file: URL) -> Bool { fm.fileExists(atPath: file.path) }
        func contents(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

        func config(automatic: Bool = false, enabled: Bool = true, roots: [URL]? = nil,
                    excluded: [URL] = [], types: Set<String> = [], createFolders: Bool = true,
                    revision: UInt64? = nil) -> OrganizerConfiguration {
            OrganizerConfiguration(roots: roots ?? self.roots, excluded: excluded, excludedTypes: types,
                                   enabled: enabled, automatic: automatic, createProjectFolders: createFolders, revision: revision ?? worker.revision)
        }

        func grouped() throws -> OrganizerWorker.Output { try worker.perform(.refresh, config: config()) }

        func add(_ file: URL, contents: String, axis: Int, age: TimeInterval, state: String = "done") throws {
            try contents.write(to: file, atomically: false, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
            let info = try #require(FileSystem.info(of: file.path))
            let candidate = Candidate(path: file.path, kind: .doc, size: info.size, mtime: info.mtime,
                                      inode: info.inode, device: info.device)
            let id = try index.insert(candidate)
            var vector = [Float](repeating: 0, count: 768)
            vector[axis] = 1
            try index.addSegment(file: id, kind: .chunk, modality: .text, vector: vector)
            try index.finish(id, state: state)
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
    @Test func previewThenSortCreatesAProjectWithoutManuallySeededFoldersAndAcceptsFutureDownloads() throws {
        let fixture = try Fixture(seedExisting: false)
        let sibling = fixture.downloads.appendingPathComponent("research-budget.md")
        try fixture.add(sibling, contents: "Research budget", axis: 0, age: 3_600)
        let preview = try fixture.worker.perform(.preview, config: fixture.config(automatic: true))
        let project = try #require(preview.snapshot.projects.first)
        #expect(!project.isExistingFolder)
        #expect(project.destinationPath.hasPrefix(fixture.downloads.path + "/Redig Organized/"))
        #expect(preview.snapshot.assignments.allSatisfy { $0.canMoveAutomatically })
        #expect(!preview.moved && preview.movedCount == 0)
        #expect(preview.history.isEmpty)
        #expect(!fixture.exists(URL(fileURLWithPath: project.destinationPath)))

        // A one-shot command works without changing the user's persistent automatic filing preference.
        let sorted = try fixture.worker.perform(.sort, config: fixture.config())
        #expect(sorted.movedCount == 2)
        #expect(sorted.message == "Sorted 2 files.")
        #expect(sorted.problem == nil)
        #expect(sorted.history.count == 2)
        #expect(sorted.history.allSatisfy { $0.state == .moved && $0.canUndo })
        for assignment in preview.snapshot.assignments {
            let target = URL(fileURLWithPath: project.destinationPath).appendingPathComponent(URL(fileURLWithPath: assignment.path).lastPathComponent)
            #expect(fixture.exists(target))
            #expect(!fixture.exists(URL(fileURLWithPath: assignment.path)))
            try fixture.index.move(assignment.fileID, to: target.path)
        }
        let incoming = fixture.desktop.appendingPathComponent("another-attachment.md")
        try fixture.add(incoming, contents: "More research", axis: 0, age: 3_600)
        let reopened = OrganizerWorker(directory: fixture.index.directory)
        let policy = OrganizerConfiguration(roots: fixture.roots, automatic: true, revision: reopened.revision)
        let next = try reopened.perform(.refresh, config: policy)
        #expect(next.movedCount == 1)
        #expect(next.snapshot.projects.first?.id == project.id)
        let record = try #require(next.history.first)
        #expect(record.source.path == incoming.path)
        #expect(record.destination.path == project.destinationPath + "/" + incoming.lastPathComponent)
        let undone = try reopened.perform(.undoLatest, config: policy)
        #expect(undone.movedCount == 1)
        #expect(undone.history.first?.id == record.id)
        #expect(undone.history.first?.state == .undone)
        #expect(fixture.exists(incoming))
        let again = try reopened.perform(.refresh, config: policy)
        #expect(!again.moved)
        #expect(again.history.count == 3)
        #expect(fixture.exists(incoming))
    }

    @Test func creationPolicyCanKeepNewGroupsVirtualButExplicitProjectFilingApprovesTheDestination() throws {
        let fixture = try Fixture(seedExisting: false)
        try fixture.add(fixture.downloads.appendingPathComponent("research-budget.md"), contents: "Research budget",
                        axis: 0, age: 3_600)
        let policy = fixture.config(automatic: true, createFolders: false)
        let automatic = try fixture.worker.perform(.refresh, config: policy)
        let project = try #require(automatic.snapshot.projects.first)
        #expect(!automatic.moved)
        #expect(!fixture.exists(URL(fileURLWithPath: project.destinationPath)))
        let sorted = try fixture.worker.perform(.sort, config: policy)
        #expect(!sorted.moved)
        #expect(sorted.message == "No stable, confident files are ready to sort yet.")
        let explicit = try fixture.worker.perform(.fileProject(project.id), config: policy)
        #expect(explicit.movedCount == 2)
        #expect(explicit.problem == nil)
        #expect(explicit.message?.contains("Filed 2 files") == true)
        #expect(fixture.exists(URL(fileURLWithPath: project.destinationPath)))
    }

    @Test func noNewFolderIsCreatedForPartialContentOrFilenameOnlyGroups() throws {
        let partial = try Fixture(seedExisting: false)
        try partial.add(partial.downloads.appendingPathComponent("research-budget.md"), contents: "Partial research budget",
                        axis: 0, age: 3_600, state: "partial")
        let incomplete = try partial.worker.perform(.refresh, config: partial.config(automatic: true))
        #expect(incomplete.snapshot.assignments.count == 2)
        #expect(incomplete.snapshot.assignments.allSatisfy { !$0.canMoveAutomatically })
        #expect(!incomplete.moved)
        #expect(!partial.exists(partial.downloads.appendingPathComponent("Redig Organized")))

        let metadata = try Fixture(seedExisting: false)
        try metadata.index.setMeta("vector_source", nil)
        try metadata.add(metadata.downloads.appendingPathComponent("research-budget.md"), contents: "Research budget",
                         axis: 0, age: 3_600)
        let fallback = try metadata.worker.perform(.refresh, config: metadata.config(automatic: true))
        #expect(fallback.snapshot.assignments.allSatisfy { !$0.canMoveAutomatically })
        #expect(!fallback.moved)
        #expect(!metadata.exists(metadata.downloads.appendingPathComponent("Redig Organized")))
    }

    @Test func fileProjectRefreshesPolicyAndReturnsPartialSuccessWithoutOverwritingCollisions() throws {
        let fixture = try Fixture(seedExisting: false)
        let sibling = fixture.downloads.appendingPathComponent("research-budget.md")
        try fixture.add(sibling, contents: "Research budget", axis: 0, age: 3_600)
        let project = try #require(try fixture.grouped().snapshot.projects.first)
        let destination = URL(fileURLWithPath: project.destinationPath)
        try fixture.fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let collision = destination.appendingPathComponent(sibling.lastPathComponent)
        try "Do not overwrite".write(to: collision, atomically: false, encoding: .utf8)
        let filed = try fixture.worker.perform(.fileProject(project.id), config: fixture.config())
        #expect(filed.movedCount == 1)
        #expect(filed.problem != nil)
        #expect(filed.message?.contains("1 file needs review") == true)
        #expect(filed.history.filter { $0.canUndo }.count == 1)
        #expect(try fixture.contents(collision) == "Do not overwrite")
        #expect(try fixture.contents(sibling) == "Research budget")
        #expect(!fixture.exists(fixture.loose))
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try fixture.worker.perform(.fileProject(project.id), config: fixture.config(roots: [fixture.desktop]))
        }
        #expect(fixture.exists(sibling))
    }

    @Test func fileProjectBatchesTenAndUndoLatestDoesNotDependOnTheVisibleHistoryPage() throws {
        let fixture = try Fixture()
        for n in 0..<11 {
            try fixture.add(fixture.downloads.appendingPathComponent("incoming-\(n).md"), contents: "Incoming \(n)",
                            axis: 0, age: 3_600)
        }
        let project = try #require(try fixture.grouped().snapshot.projects.first { $0.name == "Atlas" })
        let first = try fixture.worker.perform(.fileProject(project.id), config: fixture.config())
        #expect(first.movedCount == 10)
        #expect(first.message?.contains("Run the command again") == true)
        let second = try fixture.worker.perform(.fileProject(project.id), config: fixture.config())
        #expect(second.movedCount == 2)
        let latest = try #require(second.history.first)
        _ = try fixture.worker.perform(.history(50), config: fixture.config())
        let undo = try fixture.worker.perform(.undoLatest, config: fixture.config())
        #expect(undo.movedCount == 1)
        #expect(undo.history.first?.id == latest.id)
        #expect(undo.history.first?.state == .undone)
        #expect(undo.historyOffset == 0)
        #expect(fixture.exists(URL(fileURLWithPath: latest.source.path)))
    }

    @Test func newAutomaticDestinationsRespectExcludedFoldersAndRejectEscapingSymlinks() throws {
        let fixture = try Fixture(seedExisting: false)
        try fixture.add(fixture.downloads.appendingPathComponent("research-budget.md"), contents: "Research budget",
                        axis: 0, age: 3_600)
        let managed = fixture.downloads.appendingPathComponent("Redig Organized")
        let excluded = try fixture.worker.perform(.refresh,
            config: fixture.config(automatic: true, excluded: [managed]))
        #expect(!excluded.moved)
        #expect(!fixture.exists(managed))
        #expect(fixture.exists(fixture.loose))
        let outside = fixture.home.appendingPathComponent("outside")
        try fixture.fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.fm.createSymbolicLink(at: managed, withDestinationURL: outside)
        let symlink = try fixture.worker.perform(.refresh, config: fixture.config(automatic: true))
        #expect(!symlink.moved)
        #expect(symlink.problem != nil)
        #expect(symlink.history.isEmpty)
        #expect(try fixture.fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(fixture.exists(fixture.loose))
    }

    @Test(arguments: [true, false])
    func manualBatchSkipsMoreThanTenReviewableFilesWithoutStarvingEligibleMembers(collisions: Bool) throws {
        let fixture = try Fixture()
        for n in 0..<12 {
            let filename = String(format: "aaa-review-%02d.md", n)
            let source = fixture.downloads.appendingPathComponent(filename)
            try fixture.add(source, contents: "Indexed \(n)", axis: 0, age: 3_600)
            if collisions {
                try "Existing \(n)".write(to: fixture.atlas.appendingPathComponent(filename), atomically: false,
                                         encoding: .utf8)
            } else {
                try "New content that is not indexed yet \(n)".write(to: source, atomically: false, encoding: .utf8)
            }
        }
        let project = try #require(try fixture.grouped().snapshot.projects.first { $0.name == "Atlas" })
        let filed = try fixture.worker.perform(.fileProject(project.id), config: fixture.config())
        #expect(filed.movedCount == 1)
        #expect(filed.problem != nil)
        #expect(filed.message?.contains("12 files need review") == true)
        #expect(filed.message?.contains("Run the command again") == false)
        #expect(filed.history.count == 1)
        #expect(filed.history.first?.canUndo == true)
        #expect(!fixture.exists(fixture.loose))
        #expect(try fixture.contents(fixture.destination) == "New research for Atlas")
        let unchanged = fixture.downloads.appendingPathComponent("aaa-review-00.md")
        #expect(try fixture.contents(unchanged) == (collisions ? "Indexed 0" : "New content that is not indexed yet 0"))
        if collisions {
            #expect(try fixture.contents(fixture.atlas.appendingPathComponent("aaa-review-00.md")) == "Existing 0")
        }
        let repeated = try fixture.worker.perform(.fileProject(project.id), config: fixture.config())
        #expect(!repeated.moved)
        #expect(repeated.history.count == 1)
        #expect(fixture.exists(unchanged))
    }

}
