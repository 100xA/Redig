import Foundation

/// The selected folder boundary and the current, already-resolved app policy for one organizer operation.
public struct OrganizerConfiguration: Sendable {
    public let roots: [URL]
    public let excluded: [URL]
    public let excludedTypes: Set<String>
    public let enabled: Bool
    public let automatic: Bool
    public let revision: UInt64

    public init(roots: [URL], excluded: [URL] = [], excludedTypes: Set<String> = [],
                enabled: Bool = true, automatic: Bool = false, revision: UInt64) {
        self.roots = roots.map { URL(fileURLWithPath: Self.canonicalPath($0)) }
        self.excluded = excluded.map { URL(fileURLWithPath: Self.canonicalPath($0)) }
        self.excludedTypes = Set(excludedTypes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
        self.enabled = enabled && !roots.isEmpty
        self.automatic = automatic && self.enabled
        self.revision = revision
    }

    public static func contains(_ root: URL, _ file: URL) -> Bool {
        let root = canonicalPath(root), file = canonicalPath(file)
        return file == root || file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// realpath preserves macOS's /private/var spelling; Foundation standardization alone changes it back to /var.
    /// Destinations may not exist yet, so resolve their nearest existing ancestor and append the remaining names.
    public static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let base = FolderSelection.realPath(ancestor.path)
        guard !tail.isEmpty else { return base }
        return (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
    }
}

/// Serial-queue facade for grouping, filing and undo. Configuration revisions revoke queued automation.
/// Connections and operations are confined to the caller's one serial queue; only invalidate/revision are thread-safe.
public final class OrganizerWorker: @unchecked Sendable {
    public enum Action: Sendable {
        case refresh, move(OrganizerAssignment), undo(Int64), rename(String, String), assign(String, String)
        case history(Int)
    }
    public struct Output: Sendable {
        public let snapshot: OrganizerProjectSnapshot
        public let history: [OrganizerMoveJournal.MoveRecord]
        public let moved: Bool
        public let problem: String?
        public let historyOffset: Int
        public let hasOlderHistory: Bool
    }

    private let directory: URL
    private var projects: OrganizerProjectStore?
    private var journal: OrganizerMoveJournal?
    private var index: IndexStore?
    private var historyOffset = 0
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    public var revision: UInt64 { lock.withLock { epoch } }
    public func invalidate() { lock.withLock { epoch &+= 1 } }

    public init(directory: URL) { self.directory = directory }

    public func perform(_ action: Action, config: OrganizerConfiguration) throws -> Output {
        let storage = directory.appendingPathComponent("organizer.noindex", isDirectory: true)
        if projects == nil { projects = try OrganizerProjectStore(directory: storage) }
        if journal == nil { journal = try OrganizerMoveJournal(directory: storage) }
        guard let projects, let journal else { preconditionFailure("Organizer storage did not open") }
        var moved = false
        var problem: String?
        guard revision == config.revision else {
            return Output(snapshot: .empty, history: [], moved: false, problem: nil,
                          historyOffset: historyOffset, hasOlderHistory: false)
        }
        switch action {
        case .refresh: break
        case .history(let offset):
            historyOffset = max(0, offset)
            return try output(snapshot: projects.snapshot(), journal: journal, moved: false, problem: nil)
        case .move(let assignment):
            guard config.enabled else { throw OrganizerMoveJournal.Failure(message: "Enable this folder in Organizer first.") }
            let snapshot = try projects.snapshot()
            guard let current = snapshot.assignments.first(where: { $0.path == assignment.path }), current == assignment,
                  let project = snapshot.projects.first(where: { $0.id == assignment.projectID }) else {
                throw OrganizerMoveJournal.Failure(message: "This project changed. Refresh and try again.")
            }
            try move(assignment, into: project, journal: journal, config: config)
            moved = true
        case .undo(let id):
            try journal.undo(id: id, allowedRoots: config.roots)
            moved = true
        case .rename(let id, let name): try projects.rename(projectID: id, name: name)
        case .assign(let path, let id): try projects.assign(filePath: path, to: id)
        }

        var snapshot = try projects.snapshot()
        var groupingReady = false
        if config.enabled {
            do {
                if index == nil { index = try IndexStore(directory: directory) }
                if let index {
                    snapshot = try projects.refresh(index: index, roots: config.roots, excluded: config.excluded,
                                                    excludedExtensions: config.excludedTypes)
                    groupingReady = true
                }
            } catch {
                // A successful file operation must remain visible and undoable if the index is temporarily busy.
                problem = error.localizedDescription
            }
        }
        if groupingReady, config.automatic, case .refresh = action {
            let suppressed = Set(try journal.automaticallySuppressedPaths().map {
                OrganizerConfiguration.canonicalPath(URL(fileURLWithPath: $0))
            })
            let projectsByID = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
            let cutoff = Date().timeIntervalSince1970 - 60
            // Keep the app responsive and leave room for new index commits between small filing batches.
            let candidates = snapshot.assignments.filter { file in
                file.canMoveAutomatically && file.modified < cutoff
                    && !suppressed.contains(OrganizerConfiguration.canonicalPath(URL(fileURLWithPath: file.path)))
                    && config.roots.contains {
                        $0.path == OrganizerConfiguration.canonicalPath(URL(fileURLWithPath: file.path).deletingLastPathComponent())
                    }
            }
            var attempts = 0
            for file in candidates {
                guard revision == config.revision, attempts < 10 else { break }
                guard let project = projectsByID[file.projectID] else { continue }
                let target = URL(fileURLWithPath: project.destinationPath).appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent)
                // A collision stays for review; do not create a new failed journal record every timer tick.
                if FileManager.default.fileExists(atPath: target.path)
                    || (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil { continue }
                attempts += 1
                do {
                    try move(file, into: project, journal: journal, config: config)
                    moved = true
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
        if moved { historyOffset = 0 }
        return try output(snapshot: snapshot, journal: journal, moved: moved, problem: problem)
    }

    private func output(snapshot: OrganizerProjectSnapshot, journal: OrganizerMoveJournal,
                        moved: Bool, problem: String?) throws -> Output {
        let page = try journal.history(limit: 51, offset: historyOffset)
        return Output(snapshot: snapshot, history: Array(page.prefix(50)), moved: moved, problem: problem,
                      historyOffset: historyOffset, hasOlderHistory: page.count > 50)
    }

    private func move(_ file: OrganizerAssignment, into project: OrganizerProject,
                      journal: OrganizerMoveJournal, config: OrganizerConfiguration) throws {
        let source = URL(fileURLWithPath: file.path)
        let destination = URL(fileURLWithPath: project.destinationPath, isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        guard revision == config.revision,
              !config.excluded.contains(where: { OrganizerConfiguration.contains($0, source) || OrganizerConfiguration.contains($0, destination) }),
              !config.excludedTypes.contains(source.pathExtension.lowercased()) else {
            throw OrganizerMoveJournal.Failure(message: "This file is outside the current organizer policy.")
        }
        try journal.move(source: source, to: destination, allowedRoots: config.roots,
                         expectedSize: file.size, expectedModified: file.modified,
                         expectedInode: file.inode, expectedDevice: file.device)
    }
}
