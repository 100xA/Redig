import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The organizer's durable, append-only move history. Use one instance from a dedicated serial queue.
/// Opening the journal reconciles interrupted operations but never moves or deletes files during recovery.
public final class OrganizerMoveJournal {
    public enum State: String, Codable, Sendable { case planned, moved, undone, failed }

    public struct MoveRecord: Identifiable, Sendable {
        public let id: Int64
        public let source: URL
        public let destination: URL
        public let state: State
        public let createdAt: Date
        public let updatedAt: Date
        public let error: String?
        public var canUndo: Bool { state == .moved }
    }

    public struct Failure: Error, LocalizedError, CustomStringConvertible {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
        public var description: String { message }
    }

    struct Stamp: Codable, Equatable {
        let inode: UInt64
        let device: UInt64
        let size: Int64
        let modified: Double

        init(_ info: FileInfo) {
            inode = info.inode; device = info.device; size = info.size; modified = info.mtime
        }
        func sameContents(as other: Stamp) -> Bool { size == other.size && modified == other.modified }
    }

    private struct Entry {
        let record: MoveRecord
        let original: Stamp
        let destination: Stamp?
        let target: Stamp?
        let operation: String
    }

    let db: Database
    private let fm = FileManager.default
    private let columns = "id, source, destination, state, created_at, updated_at, error, source_stamp, destination_stamp, target_stamp, operation"

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("organizer.sqlite").path)
        // Persist the intent before changing a file, including across a sudden process or machine shutdown.
        try db.execute("""
            PRAGMA synchronous = FULL;
            CREATE TABLE IF NOT EXISTS organizer_moves (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                destination TEXT NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('planned', 'moved', 'undone', 'failed')),
                operation TEXT NOT NULL DEFAULT 'move' CHECK (operation IN ('move', 'undo')),
                source_stamp TEXT NOT NULL,
                destination_stamp TEXT,
                target_stamp TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                error TEXT
            );
            CREATE INDEX IF NOT EXISTS organizer_moves_recent ON organizer_moves(updated_at DESC, id DESC);
            """)
        try reconcileInterruptedOperations()
    }

    public func history(limit: Int = 100, offset: Int = 0) throws -> [MoveRecord] {
        var records: [MoveRecord] = []
        try db.query("SELECT \(columns) FROM organizer_moves ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?",
                     [.int(Int64(max(0, min(limit, 10_000)))), .int(Int64(max(0, offset)))]) { records.append(try entry($0).record) }
        return records
    }

    /// Undo is a persistent instruction to stop automatically filing this original path. It survives restarts and
    /// does not depend on the activity UI's history limit. Manual moves remain available.
    public func automaticallySuppressedPaths() throws -> Set<String> {
        var paths = Set<String>()
        try db.query("SELECT DISTINCT source FROM organizer_moves WHERE state = 'undone'") {
            if let path = $0.text(0) { paths.insert(path) }
        }
        return paths
    }

    /// Moves a fully downloaded, regular file between explicitly selected roots. Existing items are never replaced.
    /// Parent folders may be created inside a selected root. Symlinks, cloud placeholders and bundle contents are refused.
    @discardableResult
    public func move(source: URL, to destination: URL, allowedRoots: [URL],
                     expectedSize: Int64? = nil, expectedModified: Double? = nil,
                     expectedInode: UInt64? = nil, expectedDevice: UInt64? = nil) throws -> MoveRecord {
        let paths = try validatedPaths(source: source, destination: destination, allowedRoots: allowedRoots)
        let original = try stamp(paths.source)
        guard expectedSize.map({ $0 == original.size }) ?? true,
              expectedModified.map({ $0 == original.modified }) ?? true,
              expectedInode.map({ $0 == original.inode }) ?? true,
              expectedDevice.map({ $0 == original.device }) ?? true else {
            throw failure("The file changed since it was indexed. Wait for the organizer to refresh before moving it.")
        }
        let now = Date().timeIntervalSince1970
        try db.run("""
            INSERT INTO organizer_moves(source, destination, state, source_stamp, created_at, updated_at)
            VALUES (?, ?, 'planned', ?, ?, ?)
            """, [.text(paths.source.path), .text(paths.destination.path), .text(try encode(original)), .double(now), .double(now)])
        let id = db.lastInsertID
        do {
            let moved = try coordinatedMove(from: paths.source, to: paths.destination) { from, to in
                guard self.canonicalFile(from) == paths.source, self.canonicalFile(to) == paths.destination else {
                    throw self.failure("A file location changed while preparing the move. Refresh and try again.")
                }
                _ = try self.validatedPaths(source: from, destination: to, allowedRoots: allowedRoots)
                try self.requireUnchanged(from, original)
                try self.createParents(of: to, allowedRoots: allowedRoots)
                return try self.transfer(from: from, to: to, expected: original, id: id)
            }
            try db.run("UPDATE organizer_moves SET state = 'moved', destination_stamp = ?, target_stamp = NULL, updated_at = ?, error = NULL WHERE id = ?",
                       [.text(try encode(moved)), .double(Date().timeIntervalSince1970), .int(id)])
            return try record(id)
        } catch {
            try? setState(id, .failed, error: String(describing: error))
            throw error
        }
    }

    /// Restores the exact file moved by this record. A changed file or a newly occupied original path is never replaced.
    @discardableResult
    public func undo(id: Int64, allowedRoots: [URL]) throws -> MoveRecord {
        let current = try load(id)
        guard current.record.state == .moved, let expected = current.destination else {
            throw failure("This move is no longer available to undo.")
        }
        let paths = try validatedPaths(source: current.record.destination, destination: current.record.source,
                                       allowedRoots: allowedRoots)
        try requireUnchanged(paths.source, expected)
        try db.run("UPDATE organizer_moves SET state = 'planned', operation = 'undo', target_stamp = NULL, updated_at = ?, error = NULL WHERE id = ?",
                   [.double(Date().timeIntervalSince1970), .int(id)])
        do {
            _ = try coordinatedMove(from: paths.source, to: paths.destination) { from, to in
                guard self.canonicalFile(from) == paths.source, self.canonicalFile(to) == paths.destination else {
                    throw self.failure("A file location changed while preparing undo. Refresh and try again.")
                }
                _ = try self.validatedPaths(source: from, destination: to, allowedRoots: allowedRoots)
                try self.requireUnchanged(from, expected)
                try self.createParents(of: to, allowedRoots: allowedRoots)
                return try self.transfer(from: from, to: to, expected: expected, id: id)
            }
            try setState(id, .undone)
            return try record(id)
        } catch {
            // A failed attempt before the transfer leaves a valid, retryable undo. Anything ambiguous needs inspection.
            let unchanged = (try? stamp(paths.source)) == expected && !present(paths.destination)
            try? setState(id, unchanged ? .moved : .failed, error: String(describing: error))
            throw error
        }
    }

    private func transfer(from: URL, to: URL, expected: Stamp, id: Int64) throws -> Stamp {
        guard !present(to) else { throw failure("A file already exists at \(to.path).") }
        try requireUnchanged(from, expected)
        #if canImport(Darwin)
        // RENAME_EXCL closes the race between the existence check and publishing the destination.
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 {
            let result = try stamp(to)
            guard result == expected else { throw failure("The file changed during its move. Inspect both locations before continuing.") }
            guard !present(from) else { throw failure("The original location was occupied again during the move.") }
            return result
        }
        let renameError = errno
        guard renameError == EXDEV else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError),
                          userInfo: [NSLocalizedDescriptionKey: "Could not move \(from.lastPathComponent): \(String(cString: strerror(renameError)))"])
        }
        #endif
        // Across volumes, copy exclusively, verify the bytes and both versions, journal the copy's identity, then
        // remove the original. A crash with two copies is reported for inspection rather than deleting either one.
        let digest = try ModelFiles.sha256(of: from)
        try requireUnchanged(from, expected)
        try fm.copyItem(at: from, to: to)
        let copied = try stamp(to)
        guard copied.sameContents(as: expected), try ModelFiles.sha256(of: to) == digest else {
            throw failure("The copied file could not be verified. Both locations have been retained.")
        }
        try requireUnchanged(from, expected)
        guard try ModelFiles.sha256(of: from) == digest else {
            throw failure("The original changed while copying. Both locations have been retained.")
        }
        try requireUnchanged(to, copied)
        try db.run("UPDATE organizer_moves SET target_stamp = ?, updated_at = ? WHERE id = ?",
                   [.text(try encode(copied)), .double(Date().timeIntervalSince1970), .int(id)])
        try requireUnchanged(from, expected)
        try fm.removeItem(at: from)
        try requireUnchanged(to, copied)
        return copied
    }

    private func coordinatedMove<T>(from: URL, to: URL, body: (URL, URL) throws -> T) throws -> T {
        #if os(macOS)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing,
                               error: &coordinationError) { source, destination in
            result = Result {
                coordinator.item(at: source, willMoveTo: destination)
                let value = try body(source, destination)
                coordinator.item(at: source, didMoveTo: destination)
                return value
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? failure("The file could not be coordinated with other applications.") as NSError
        #else
        return try body(from, to)
        #endif
    }

    private func validatedPaths(source: URL, destination: URL, allowedRoots: [URL]) throws -> (source: URL, destination: URL) {
        guard source.isFileURL, destination.isFileURL, !source.lastPathComponent.isEmpty, !destination.lastPathComponent.isEmpty else {
            throw failure("Choose local file paths for this move.")
        }
        // Check the file itself before resolving its parents: resolving the whole URL would hide a source symlink.
        _ = try stamp(source)
        // Reject links below a selected root before canonicalization can hide the traversal. A symlink used as
        // the explicitly selected root itself is allowed, as are OS aliases above it (for example /var on macOS).
        for path in [source.standardizedFileURL, destination.standardizedFileURL] {
            for root in allowedRoots where root.isFileURL {
                let logicalRoot = root.standardizedFileURL
                if contains(path, in: logicalRoot) { try checkAncestors(of: path, root: logicalRoot) }
            }
        }
        let from = canonicalFile(source), to = canonicalFile(destination)
        guard from != to else { throw failure("The source and destination are the same file.") }
        let roots = try allowedRoots.map { root -> URL in
            guard root.isFileURL else { throw failure("Organizer folders must be local folders.") }
            let canonical = URL(fileURLWithPath: FolderSelection.realPath(root.path))
            let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true, !FileSystem.isPackage(canonical, values) else { throw failure("An organizer folder is unavailable or is a bundle.") }
            return canonical
        }
        guard let fromRoot = roots.first(where: { contains(from, in: $0) }),
              let toRoot = roots.first(where: { contains(to, in: $0) }) else {
            throw failure("Both locations must be inside the selected organizer folders.")
        }
        try checkAncestors(of: from, root: fromRoot)
        try checkAncestors(of: to, root: toRoot)
        guard !present(to) else { throw failure("A file already exists at \(to.path).") }
        return (from, to)
    }

    private func createParents(of destination: URL, allowedRoots: [URL]) throws {
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Recheck after creation; an existing parent may have been replaced by a symlink while coordinating.
        guard canonicalFile(destination) == destination else { throw failure("The destination folder changed during the move.") }
        let roots = allowedRoots.map { URL(fileURLWithPath: FolderSelection.realPath($0.path)) }
        guard let root = roots.first(where: { contains(destination, in: $0) }) else {
            throw failure("The destination is outside the selected organizer folders.")
        }
        try checkAncestors(of: destination, root: root)
    }

    private func checkAncestors(of file: URL, root: URL) throws {
        var parent = file.deletingLastPathComponent()
        while parent != root {
            guard contains(parent, in: root) else { throw failure("A file location escaped its selected folder.") }
            if present(parent) {
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true, !FileSystem.isPackage(parent, values) else {
                    throw failure("The move would traverse a symlink, bundle, or non-folder item.")
                }
            }
            parent.deleteLastPathComponent()
        }
    }

    private func canonicalFile(_ url: URL) -> URL {
        // Foundation resolves existing /var aliases, but can drop /private when the destination's parents do
        // not exist yet. Resolve the nearest existing ancestor with realpath, then append the untouched tail.
        // Ancestor symlinks below a selected root were already rejected before this canonicalization.
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let base = FolderSelection.realPath(ancestor.path)
        let path = tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
        return URL(fileURLWithPath: path)
    }

    private func contains(_ item: URL, in root: URL) -> Bool {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return item.path.hasPrefix(prefix)
    }

    private func present(_ url: URL) -> Bool {
        // fileExists follows links and returns false for a dangling symlink; attributes also catches that collision.
        fm.fileExists(atPath: url.path) || (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func stamp(_ url: URL) throws -> Stamp {
        guard let info = FileSystem.info(of: url.path), info.isRegular, !info.dataless else {
            throw failure("Only fully downloaded, regular files can be moved. Symlinks and folders are excluded.")
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard !FileSystem.isInCloud(values) else { throw failure("Download this cloud file before organizing it.") }
        return Stamp(info)
    }

    private func requireUnchanged(_ url: URL, _ expected: Stamp) throws {
        guard try stamp(url) == expected else {
            throw failure("The file changed since it was recorded. It has been left untouched.")
        }
    }

    private func record(_ id: Int64) throws -> MoveRecord { try load(id).record }
    private func load(_ id: Int64) throws -> Entry {
        var found: Entry?
        try db.query("SELECT \(columns) FROM organizer_moves WHERE id = ?", [.int(id)]) { found = try entry($0) }
        guard let found else { throw failure("The move was not found in this organizer's history.") }
        return found
    }

    private func entry(_ row: Statement) throws -> Entry {
        guard let source = row.text(1), let destination = row.text(2), let state = State(rawValue: row.text(3) ?? ""),
              let encoded = row.text(7) else { throw failure("The organizer move history is damaged.") }
        let record = MoveRecord(id: row.int(0), source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: destination),
                                state: state, createdAt: Date(timeIntervalSince1970: row.double(4)),
                                updatedAt: Date(timeIntervalSince1970: row.double(5)), error: row.text(6))
        return Entry(record: record, original: try decode(encoded), destination: try row.text(8).map(decode),
                     target: try row.text(9).map(decode), operation: row.text(10) ?? "move")
    }

    private func reconcileInterruptedOperations() throws {
        var pending: [Entry] = []
        try db.query("SELECT \(columns) FROM organizer_moves WHERE state = 'planned'") { pending.append(try entry($0)) }
        for entry in pending {
            let undo = entry.operation == "undo"
            let from = undo ? entry.record.destination : entry.record.source
            let to = undo ? entry.record.source : entry.record.destination
            guard canonicalFile(from) == from, canonicalFile(to) == to else {
                try setState(entry.record.id, .failed, error: "A folder changed during an interrupted operation. Inspect both locations.")
                continue
            }
            let expected = undo ? entry.destination : entry.original
            let actualFrom = try? stamp(from), actualTo = try? stamp(to)
            if !present(from), let expectedTarget = entry.target ?? expected, actualTo == expectedTarget {
                if undo {
                    try setState(entry.record.id, .undone)
                } else {
                    try db.run("UPDATE organizer_moves SET state = 'moved', destination_stamp = ?, target_stamp = NULL, updated_at = ?, error = NULL WHERE id = ?",
                               [.text(try encode(expectedTarget)), .double(Date().timeIntervalSince1970), .int(entry.record.id)])
                }
            } else if actualFrom == expected, !present(to) {
                try setState(entry.record.id, undo ? .moved : .failed,
                             error: "The operation was interrupted before the file moved. The file remains at its previous location.")
            } else {
                try setState(entry.record.id, .failed, error: "The operation was interrupted. Inspect both locations; no files were changed during recovery.")
            }
        }
    }

    private func setState(_ id: Int64, _ state: State, error: String? = nil) throws {
        try db.run("UPDATE organizer_moves SET state = ?, target_stamp = NULL, updated_at = ?, error = ? WHERE id = ?",
                   [.text(state.rawValue), .double(Date().timeIntervalSince1970), .optional(error), .int(id)])
    }
    private func encode(_ stamp: Stamp) throws -> String { String(decoding: try JSONEncoder().encode(stamp), as: UTF8.self) }
    private func decode(_ text: String) throws -> Stamp { try JSONDecoder().decode(Stamp.self, from: Data(text.utf8)) }
    private func failure(_ message: String) -> Failure { Failure(message: message) }
}
