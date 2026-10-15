import Foundation
import Testing
@testable import DigUpKit

@Suite final class OrganizerMoveTests {
    let root: URL
    let files: URL
    let other: URL
    let journalDirectory: URL
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpMoves-" + UUID().uuidString)
        files = root.appendingPathComponent("files")
        other = root.appendingPathComponent("other")
        journalDirectory = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var allowed: [URL] { [files, other] }
    func make(_ name: String = "notes.txt", text: String = "Project research notes") throws -> URL {
        let file = files.appendingPathComponent(name)
        try text.write(to: file, atomically: false, encoding: .utf8)
        return file
    }
    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    func journal() throws -> OrganizerMoveJournal { try OrganizerMoveJournal(directory: journalDirectory) }

    @Test func movesAndUndoPersistAcrossReopening() throws {
        let source = try make(), destination = other.appendingPathComponent("Project/notes.txt")
        let record = try journal().move(source: source, to: destination, allowedRoots: allowed)
        #expect(record.state == .moved)
        #expect(!exists(source))
        #expect(try contents(destination) == "Project research notes")
        let reopened = try journal()
        #expect(try reopened.history().first?.id == record.id)
        #expect(try reopened.history().first?.canUndo == true)
        let undone = try reopened.undo(id: record.id, allowedRoots: allowed)
        #expect(undone.state == .undone)
        #expect(try contents(source) == "Project research notes")
        #expect(!exists(destination))
        #expect(throws: OrganizerMoveJournal.Failure.self) { try reopened.undo(id: record.id, allowedRoots: allowed) }
        #expect(try journal().automaticallySuppressedPaths() == [FolderSelection.realPath(source.path)])
    }

    @Test func newNestedParentsKeepTheSameCanonicalRootSpelling() throws {
        let source = try make()
        let selected = [files, other].map { URL(fileURLWithPath: FolderSelection.realPath($0.path)) }
        let destination = selected[1].appendingPathComponent("Redig Organized/New Project/notes.txt")
        let journal = try journal()
        let record = try journal.move(source: source, to: destination, allowedRoots: selected)
        #expect(record.source.path == FolderSelection.realPath(source.deletingLastPathComponent().path) + "/notes.txt")
        #expect(record.destination.path == destination.path)
        #expect(try contents(destination) == "Project research notes")
        #expect(!exists(source))
        let undo = try journal.undo(id: record.id, allowedRoots: selected)
        #expect(undo.state == .undone)
        #expect(try contents(source) == "Project research notes")
        #expect(!exists(destination))
    }

    @Test func historyPagesRemainStableAndDoNotOverlap() throws {
        let journal = try journal()
        for number in 0..<5 {
            let source = try make("notes-\(number).txt")
            _ = try journal.move(source: source, to: other.appendingPathComponent(source.lastPathComponent), allowedRoots: allowed)
        }
        let first = try journal.history(limit: 2)
        let second = try journal.history(limit: 2, offset: 2)
        let third = try journal.history(limit: 2, offset: 4)
        #expect(first.map(\.id) == (try journal.history(limit: 2)).map(\.id))
        #expect(first.count == 2 && second.count == 2 && third.count == 1)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        #expect((first + second + third).map(\.id) == (try journal.history()).map(\.id))
        #expect(try journal.history(limit: 2, offset: -1).map(\.id) == first.map(\.id))
        #expect(try journal.history(limit: 2, offset: 100).isEmpty)
    }

    @Test func destinationCollisionNeverReplacesEitherFile() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt")
        try "Existing contents".write(to: destination, atomically: false, encoding: .utf8)
        let journal = try journal()
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal.move(source: source, to: destination, allowedRoots: allowed) }
        #expect(try contents(source) == "Project research notes")
        #expect(try contents(destination) == "Existing contents")
        #expect(try journal.history().isEmpty)
    }

    @Test func danglingSymlinkIsAlsoADestinationCollision() throws {
        #if !os(Windows)
        let source = try make(), destination = other.appendingPathComponent("notes.txt")
        try fm.createSymbolicLink(at: destination, withDestinationURL: other.appendingPathComponent("missing.txt"))
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal().move(source: source, to: destination, allowedRoots: allowed) }
        #expect(exists(source))
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.path).hasSuffix("missing.txt"))
        #endif
    }

    @Test func sourceLinksAndDirectoriesAreRefused() throws {
        #if !os(Windows)
        let original = try make(), link = files.appendingPathComponent("alias.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal().move(source: link, to: other.appendingPathComponent("alias.txt"), allowedRoots: allowed) }
        #expect(exists(original))
        #endif
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal().move(source: files, to: other.appendingPathComponent("folder"), allowedRoots: allowed) }
    }

    @Test func symlinkTraversalCannotEscapeSelectedRoots() throws {
        #if !os(Windows)
        let source = try make(), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = other.appendingPathComponent("project")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: link.appendingPathComponent("notes.txt"), allowedRoots: allowed)
        }
        #expect(exists(source))
        #expect(!exists(outside.appendingPathComponent("notes.txt")))
        #endif
    }

    @Test func symlinkTraversalInsideSelectedRootsIsAlsoRefused() throws {
        #if !os(Windows)
        let source = try make(), real = other.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = other.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: link.appendingPathComponent("notes.txt"), allowedRoots: allowed)
        }
        #expect(exists(source))
        #expect(!exists(real.appendingPathComponent("notes.txt")))
        #endif
    }

    @Test func siblingsWithCommonPrefixAreOutsideTheRoots() throws {
        let source = try make(), sibling = root.appendingPathComponent("files-sibling")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: sibling.appendingPathComponent("notes.txt"), allowedRoots: allowed)
        }
        #expect(exists(source))
    }

    @Test func bundleContentsAreNeverExtractedByMoves() throws {
        let bundle = files.appendingPathComponent("Example.app", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = bundle.appendingPathComponent("notes.txt")
        try "Bundle contents".write(to: source, atomically: false, encoding: .utf8)
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: other.appendingPathComponent("notes.txt"), allowedRoots: allowed)
        }
        #expect(exists(source))
    }

    @Test func staleIndexedVersionCannotMoveAFile() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt")
        let info = try #require(FileSystem.info(of: source.path))
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: destination, allowedRoots: allowed, expectedSize: info.size + 1, expectedModified: info.mtime)
        }
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal().move(source: source, to: destination, allowedRoots: allowed, expectedSize: info.size, expectedModified: info.mtime - 1)
        }
        #expect(exists(source))
        #expect(!exists(destination))
    }

    @Test func replacedFileWithPreservedSizeAndModificationDateCannotMove() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let indexed = try #require(FileSystem.info(of: source.path))
        let replacement = files.appendingPathComponent("replacement.txt")
        try String(repeating: "X", count: Int(indexed.size)).write(to: replacement, atomically: false, encoding: .utf8)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
        try fm.removeItem(at: source)
        try fm.moveItem(at: replacement, to: source)
        let current = try #require(FileSystem.info(of: source.path))
        #expect(current.inode != indexed.inode)
        #expect(current.size == indexed.size && current.mtime == indexed.mtime)
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal.move(source: source, to: destination, allowedRoots: allowed,
                             expectedSize: indexed.size, expectedModified: indexed.mtime,
                             expectedInode: indexed.inode, expectedDevice: indexed.device)
        }
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal.move(source: source, to: destination, allowedRoots: allowed,
                             expectedInode: current.inode, expectedDevice: current.device &+ 1)
        }
        #expect(try journal.history().isEmpty)
        #expect(try contents(source) == String(repeating: "X", count: Int(indexed.size)))
        #expect(!exists(destination))
    }

    @Test func undoDoesNotOverwriteAnOccupiedOriginalLocation() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        try "New file".write(to: source, atomically: false, encoding: .utf8)
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal.undo(id: moved.id, allowedRoots: allowed) }
        #expect(try contents(source) == "New file")
        #expect(try contents(destination) == "Project research notes")
        #expect(try journal.history().first?.state == .moved)
    }

    @Test func undoRefusesEditedOrReplacedDestinations() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        let original = try fm.attributesOfItem(atPath: destination.path)
        let replacement = other.appendingPathComponent("replacement.txt")
        try String(repeating: "X", count: "Project research notes".utf8.count).write(to: replacement, atomically: false, encoding: .utf8)
        try fm.setAttributes([.modificationDate: try #require(original[.modificationDate])], ofItemAtPath: replacement.path)
        try fm.removeItem(at: destination)
        try fm.moveItem(at: replacement, to: destination)
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal.undo(id: moved.id, allowedRoots: allowed) }
        #expect(!exists(source))
        #expect(try contents(destination).hasPrefix("XXX"))
    }

    @Test func undoRequiresBothLocationsStillSelected() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        #expect(throws: OrganizerMoveJournal.Failure.self) { try journal.undo(id: moved.id, allowedRoots: [other]) }
        #expect(exists(destination))
        #expect(try journal.undo(id: moved.id, allowedRoots: allowed).state == .undone)
    }

    @Test func interruptedMoveIsReconciledWithoutRepeatingTheMove() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        // Simulate termination after the exclusive rename but before recording completion.
        try journal.db.run("UPDATE organizer_moves SET state = 'planned', destination_stamp = NULL WHERE id = ?", [.int(moved.id)])
        let reopened = try self.journal()
        #expect(try reopened.history().first?.state == .moved)
        #expect(!exists(source))
        #expect(try reopened.undo(id: moved.id, allowedRoots: allowed).state == .undone)
    }

    @Test func interruptedUndoIsReconciledWithoutRepeatingIt() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        _ = try journal.undo(id: moved.id, allowedRoots: allowed)
        // Simulate termination after the reverse rename but before committing its state.
        try journal.db.run("UPDATE organizer_moves SET state = 'planned', operation = 'undo' WHERE id = ?", [.int(moved.id)])
        #expect(try self.journal().history().first?.state == .undone)
        #expect(exists(source))
        #expect(!exists(destination))
    }

    @Test func interruptedBeforeMoveLeavesTheOriginalUntouched() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        _ = try journal.undo(id: moved.id, allowedRoots: allowed)
        try journal.db.run("UPDATE organizer_moves SET state = 'planned', operation = 'move', destination_stamp = NULL WHERE id = ?", [.int(moved.id)])
        #expect(try self.journal().history().first?.state == .failed)
        #expect(try contents(source) == "Project research notes")
        #expect(!exists(destination))
    }

    @Test func failedFilesystemMoveRetainsDurableFailureHistory() throws {
        #if !os(Windows)
        let source = try make(), destination = other.appendingPathComponent(String(repeating: "x", count: 300)), journal = try journal()
        #expect(throws: (any Error).self) { try journal.move(source: source, to: destination, allowedRoots: allowed) }
        #expect(try journal.history().first?.state == .failed)
        #expect(try journal.history().first?.error != nil)
        #expect(try contents(source) == "Project research notes")
        #endif
    }

    @Test func ambiguousCrashRecoveryRetainsBothCopies() throws {
        let source = try make(), destination = other.appendingPathComponent("notes.txt"), journal = try journal()
        let moved = try journal.move(source: source, to: destination, allowedRoots: allowed)
        try fm.copyItem(at: destination, to: source)
        try journal.db.run("UPDATE organizer_moves SET state = 'planned' WHERE id = ?", [.int(moved.id)])
        let reopened = try self.journal()
        #expect(try reopened.history().first?.state == .failed)
        #expect(exists(source))
        #expect(exists(destination))
        #expect(try contents(source) == contents(destination))
    }

    @Test func invalidDestinationParentDoesNotTouchTheSource() throws {
        let source = try make(), blocker = other.appendingPathComponent("project"), journal = try journal()
        try "Not a directory".write(to: blocker, atomically: false, encoding: .utf8)
        // A file occupying a destination parent is rejected before the intent is recorded.
        #expect(throws: OrganizerMoveJournal.Failure.self) {
            try journal.move(source: source, to: blocker.appendingPathComponent("notes.txt"), allowedRoots: allowed)
        }
        #expect(exists(source))
        #expect(try contents(blocker) == "Not a directory")
        #expect(try journal.history().isEmpty)
    }
}
