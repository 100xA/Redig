import Foundation

/// A local, virtual project. No file is moved by the grouping store.
public struct OrganizerProject: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var memberCount: Int
    public let rootPath: String
    public let destinationPath: String
    public let isExistingFolder: Bool
    public var isUserNamed: Bool
}

public struct OrganizerAssignment: Codable, Sendable, Identifiable, Equatable {
    public enum Reason: String, Codable, Sendable { case existingFolder, semantic, filename, manual }
    public var id: String { path }
    public let path: String
    public let fileID: Int64
    public let kind: FileKind
    public let modified: Double
    public let size: Int64
    /// Identity captured when the indexed content was read. Filing must reject an atomic replacement at this path.
    public let inode: UInt64
    public let device: UInt64
    public let projectID: String
    /// Cosine for semantic matches; 1 for an existing folder/manual choice; filename overlap otherwise.
    public let score: Double
    public let reason: Reason
    /// Only strong, unambiguous semantic matches of loose files qualify. The move policy must still validate them.
    public let canMoveAutomatically: Bool
}

public struct OrganizerReviewItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let fileID: Int64
    public let suggestedProjectID: String?
    public let score: Double?
    public let reason: String
}

public struct OrganizerProjectSnapshot: Codable, Sendable, Equatable {
    public let projects: [OrganizerProject]
    public let assignments: [OrganizerAssignment]
    public let reviewItems: [OrganizerReviewItem]
    public let generation: Int64
    public let vectorSource: String?
    public static let empty = OrganizerProjectSnapshot(projects: [], assignments: [], reviewItems: [], generation: -1,
                                                       vectorSource: nil)
}

/// Uses only committed index metadata/vectors. Use this store and its IndexStore from the same serial queue.
/// Its tables share organizer.sqlite with the move journal, without changing that database's user_version.
public final class OrganizerProjectStore {
    public static let managedFolderName = "Redig Organized"
    // Existing installations retain their filing paths and move history after the product rename.
    private static let managedFolderNames: Set<String> = [managedFolderName, "DigUp Organized"]
    private let db: Database
    /// Diagnostics for the bounded incremental refresh; not part of the UI contract.
    private(set) var representativeReads = 0
    // One pooled representative per indexed file; at most 16 segment blobs are read when that file changes.
    private static let representativeSegments = 16
    private static let matchThreshold = 0.86
    private static let moveThreshold = 0.90
    private static let ambiguityMargin = 0.08
    private static let cacheVersion = "projects-v3"
    private static let maximumClusterCandidates = 256

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("organizer.sqlite").path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS organizer_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS organizer_projects(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS organizer_assignments(path TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS organizer_overrides(path TEXT PRIMARY KEY, file_id INTEGER, project_id TEXT NOT NULL,
                                                       index_identity TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS organizer_file_cache(
                file_id INTEGER PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL,
                vector_generation INTEGER NOT NULL, vector BLOB);
            """)
    }

    public func snapshot() throws -> OrganizerProjectSnapshot {
        guard let json = try meta("snapshot"), let data = json.data(using: .utf8) else { return .empty }
        // Grouping is a disposable projection of the index. An older payload (or interrupted/corrupt cache) can
        // safely be regenerated; the separate move journal and explicit overrides are never discarded here.
        return (try? JSONDecoder().decode(OrganizerProjectSnapshot.self, from: data)) ?? .empty
    }

    /// Refreshes virtual groups. An unchanged index/configuration returns the persisted snapshot without reading vectors.
    public func refresh(index: IndexStore, roots: [URL], excluded: [URL] = [],
                        excludedExtensions: Set<String> = []) throws -> OrganizerProjectSnapshot {
        representativeReads = 0
        let rootSpellings = Array(Set(roots.flatMap { Self.spellings($0.path) })).sorted()
        let canonicalRoots = Dictionary(uniqueKeysWithValues: rootSpellings.map { ($0, Self.canonical($0)) })
        let roots = Array(Set(canonicalRoots.values)).sorted()
        let excluded = Array(Set(excluded.map { Self.canonical($0.path) })).sorted()
        let extensions = Set(excludedExtensions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
        let indexIdentity = try Self.indexIdentity(index.file)
        let configuration = try Self.json([Self.cacheVersion, indexIdentity,
                                           roots.joined(separator: "\n"), excluded.joined(separator: "\n"),
                                           extensions.sorted().joined(separator: "\n"), try meta("revision") ?? "0"])
        let previous = try snapshot()
        return try index.db.readTransaction {
            let generation = try index.searchGeneration()
            let source = try index.meta("vector_source")
            if try meta("configuration") == configuration, previous.generation == generation.current,
               previous.vectorSource == source { return previous }
            let sameIndex = try meta("index") == indexIdentity
            let sameSource = sameIndex && previous.vectorSource == source
            let oldCache = sameIndex ? try loadCache() : [:]
            var files: [Item] = []
            for record in try index.files(under: rootSpellings) where record.state == "done" || record.state == "partial" {
                // Crawlers do not descend symlinks. Resolve the selected root once, rather than stat every indexed
                // file (which may be an offline placeholder, or temporarily absent while the watcher catches up).
                let spelling = rootSpellings.filter { FolderSelection.isInside(record.path, $0) }.max { $0.count < $1.count }
                let path = spelling.map { canonicalRoots[$0]! + record.path.dropFirst($0.count) } ?? record.path
                guard let root = roots.filter({ FolderSelection.isInside(path, $0) }).max(by: { $0.count < $1.count }),
                      FolderSelection.isSearched(path, folders: roots, skipped: excluded),
                      !extensions.contains((path as NSString).pathExtension.lowercased()),
                      !Self.isIgnored(path: path, root: root), record.kind != .code else { continue }
                files.append(Item(record: record, path: path, root: root, vector: nil,
                                  tokens: Self.terms((path as NSString).lastPathComponent), vectorGeneration: 0))
            }
            files.sort { $0.path < $1.path }
            // One small metadata scan, followed by bounded blob reads only for files whose vectors changed.
            var changes: [Int64: Int64] = [:]
            try index.db.query("SELECT file, vector_generation FROM search_changes") { changes[$0.int(0)] = $0.int(1) }
            for n in files.indices {
                let old = oldCache[files[n].record.id]
                let change = changes[files[n].record.id] ?? 0
                files[n].vectorGeneration = change
                guard let source, !source.isEmpty else { continue }
                if sameSource, let old, old.size == files[n].record.size, old.modified == files[n].record.mtime,
                   (previous.generation >= generation.floor && change <= previous.generation) {
                    files[n].vector = old.vector
                } else {
                    representativeReads += 1
                    files[n].vector = try Self.representative(index: index, file: files[n].record.id)
                }
            }
            let result = try group(files, previous: sameIndex ? previous : .empty,
                                   sourceUnchanged: sameSource, generation: generation.current, source: source,
                                   indexIdentity: indexIdentity)
            try db.transaction {
                try db.execute("DELETE FROM organizer_assignments;")
                if !sameIndex { try db.execute("DELETE FROM organizer_file_cache") }
                let currentIDs = Set(files.map { $0.record.id })
                for id in oldCache.keys where !currentIDs.contains(id) {
                    try db.run("DELETE FROM organizer_file_cache WHERE file_id = ?", [.int(id)])
                }
                for item in files {
                    let old = oldCache[item.record.id]
                    if sameSource, let old, old.path == item.path, old.size == item.record.size,
                       old.modified == item.record.mtime, old.vectorGeneration == item.vectorGeneration,
                       previous.generation >= generation.floor { continue }
                    try db.run("INSERT INTO organizer_file_cache VALUES(?, ?, ?, ?, ?, ?) " +
                               "ON CONFLICT(file_id) DO UPDATE SET path = excluded.path, size = excluded.size, " +
                               "modified = excluded.modified, vector_generation = excluded.vector_generation, vector = excluded.vector",
                               [.int(item.record.id), .text(item.path), .int(item.record.size), .double(item.record.mtime),
                                .int(item.vectorGeneration), item.vector.map { .blob(Vectors.half($0)) } ?? .null])
                }
                for project in result.projects {
                    try db.run("INSERT INTO organizer_projects VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                               [.text(project.id), .text(try Self.json(project))])
                }
                for assignment in result.assignments {
                    try db.run("INSERT INTO organizer_assignments VALUES(?, ?)", [.text(assignment.path), .text(try Self.json(assignment))])
                }
                try setMeta("configuration", configuration)
                try setMeta("index", indexIdentity)
                try setMeta("snapshot", Self.json(result))
            }
            return result
        }
    }

    /// A user choice takes precedence over every automatic grouping, including after model changes.
    public func assign(filePath: String, to projectID: String) throws {
        let current = try snapshot(), path = Self.canonical(filePath)
        guard current.projects.contains(where: { $0.id == projectID }) else {
            throw Database.Failure(message: "That project no longer exists.")
        }
        let fileID = current.assignments.first(where: { Self.canonical($0.path) == path })?.fileID
            ?? current.reviewItems.first(where: { Self.canonical($0.path) == path })?.fileID
        try db.transaction {
            let identity = try meta("index") ?? ""
            if let fileID {
                try db.run("DELETE FROM organizer_overrides WHERE file_id = ? AND index_identity = ? AND path != ?",
                           [.int(fileID), .text(identity), .text(path)])
            }
            try db.run("INSERT INTO organizer_overrides(path, file_id, project_id, index_identity) VALUES(?, ?, ?, ?) " +
                       "ON CONFLICT(path) DO UPDATE SET file_id = excluded.file_id, project_id = excluded.project_id, " +
                       "index_identity = excluded.index_identity",
                       [.text(path), fileID.map(SQLValue.int) ?? .null, .text(projectID), .text(identity)])
            try invalidate()
        }
    }

    public func rename(projectID: String, name: String) throws {
        var current = try snapshot()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100, let n = current.projects.firstIndex(where: { $0.id == projectID }) else {
            throw Database.Failure(message: "Choose a project name between 1 and 100 characters.")
        }
        current = OrganizerProjectSnapshot(projects: current.projects.enumerated().map { index, project in
            var project = project
            if index == n { project.name = clean; project.isUserNamed = true }
            return project
        }, assignments: current.assignments, reviewItems: current.reviewItems,
           generation: current.generation, vectorSource: current.vectorSource)
        try db.transaction {
            let project = current.projects[n]
            try db.run("INSERT INTO organizer_projects VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                       [.text(project.id), .text(try Self.json(project))])
            try setMeta("snapshot", Self.json(current))
            try invalidate()
        }
    }

    private struct Item {
        let record: FileRecord
        let path: String
        let root: String
        var vector: [Float]?
        let tokens: Set<String>
        var vectorGeneration: Int64
    }
    private struct Cached {
        let path: String
        let size: Int64
        let modified: Double
        let vectorGeneration: Int64
        let vector: [Float]?
    }
    private struct Group {
        var project: OrganizerProject
        var members: [Int]
        var center: [Float]?
        var terms: Set<String>
    }
    private struct Override { let path: String; let fileID: Int64?; let projectID: String; let indexIdentity: String }

    private func group(_ files: [Item], previous: OrganizerProjectSnapshot, sourceUnchanged: Bool,
                       generation: Int64, source: String?, indexIdentity: String) throws -> OrganizerProjectSnapshot {
        var oldProjects: [String: OrganizerProject] = [:]
        try db.query("SELECT payload FROM organizer_projects") {
            guard let data = $0.text(0)?.data(using: .utf8), let project = try? JSONDecoder().decode(OrganizerProject.self, from: data) else { return }
            oldProjects[project.id] = project
        }
        for project in previous.projects { oldProjects[project.id] = project }
        let oldByDestination = Dictionary(oldProjects.values.map { ($0.destinationPath, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [String: Group] = [:], assigned: [Int: OrganizerAssignment] = [:]
        var overrides: [Override] = []
        try db.query("SELECT path, file_id, project_id, index_identity FROM organizer_overrides ORDER BY path") {
            overrides.append(Override(path: $0.text(0) ?? "", fileID: $0.isNull(1) ? nil : $0.int(1),
                                      projectID: $0.text(2) ?? "", indexIdentity: $0.text(3) ?? ""))
        }
        var overridesByID: [Int64: Override] = [:], overridesByPath: [String: Override] = [:]
        for override in overrides {
            overridesByPath[override.path] = override
            if override.indexIdentity == indexIdentity, let id = override.fileID { overridesByID[id] = override }
        }
        func assignment(_ n: Int, _ project: String, _ reason: OrganizerAssignment.Reason, _ score: Double,
                        _ automatic: Bool = false) -> OrganizerAssignment {
            let file = files[n]
            return OrganizerAssignment(path: file.record.path, fileID: file.record.id, kind: file.record.kind,
                                       modified: file.record.mtime, size: file.record.size,
                                       inode: file.record.inode, device: file.record.device, projectID: project,
                                       score: score, reason: reason, canMoveAutomatically: automatic)
        }
        func add(_ n: Int, to id: String, reason: OrganizerAssignment.Reason, score: Double, automatic: Bool = false) {
            groups[id]?.members.append(n)
            assigned[n] = assignment(n, id, reason, score, automatic)
        }
        // Existing top-level folders are strong user-provided seeds. Managed destinations keep their original IDs.
        for n in files.indices {
            let item = files[n]
            let components = item.path.dropFirst(item.root.count).split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            let depth = Self.managedFolderNames.contains(components[0]) && components.count > 2 ? 2 : 1
            let folder = item.root + "/" + components.prefix(depth).joined(separator: "/")
            let prior = oldByDestination[folder]
            let id = prior?.id ?? "folder-" + Self.stableID(folder)
            if groups[id] == nil {
                let name = (prior?.isUserNamed == true || depth == 2) ? (prior?.name ?? components[depth - 1]) : components[depth - 1]
                let project = OrganizerProject(id: id, name: name, memberCount: 0, rootPath: item.root,
                                               destinationPath: folder, isExistingFolder: true,
                                               isUserNamed: prior?.isUserNamed ?? false)
                groups[id] = Group(project: project, members: [], center: nil, terms: Self.terms(name))
            }
            add(n, to: id, reason: .existingFolder, score: 1)
        }
        // Manual assignment survives a move/rename because index file IDs do, and also matches the original path.
        for n in files.indices {
            let choice = overridesByID[files[n].record.id] ?? overridesByPath[files[n].path]
            guard let choice, let project = oldProjects[choice.projectID] else { continue }
            if let prior = assigned[n] { groups[prior.projectID]?.members.removeAll { $0 == n } }
            if groups[project.id] == nil { groups[project.id] = Group(project: project, members: [], center: nil, terms: Self.terms(project.name)) }
            add(n, to: project.id, reason: .manual, score: 1)
        }
        // Keep coherent automatic collections stable as new files arrive; model changes never reuse old centroids.
        if sourceUnchanged {
            let previousIDs = Dictionary(uniqueKeysWithValues: previous.assignments.map { ($0.fileID, $0.projectID) })
            for prior in previous.projects where !prior.isExistingFolder && groups[prior.id] == nil {
                let members = files.indices.filter { assigned[$0] == nil && previousIDs[files[$0].record.id] == prior.id }
                guard members.count >= 2, let center = Self.center(members.compactMap { files[$0].vector }),
                      members.allSatisfy({ files[$0].vector.map { Self.dot($0, center) >= Self.matchThreshold } ?? false }) else { continue }
                groups[prior.id] = Group(project: prior, members: [], center: center, terms: Self.terms(prior.name))
                for n in members { add(n, to: prior.id, reason: .semantic, score: Self.dot(files[n].vector!, center)) }
            }
        }
        for id in Array(groups.keys) {
            var group = groups[id]!
            group.center = Self.center(group.members.compactMap { files[$0].vector })
            group.terms.formUnion(group.members.reduce(into: Set<String>()) { $0.formUnion(files[$1].tokens) })
            groups[id] = group
        }
        let seedSupport = groups.mapValues { group in group.members.filter { files[$0].vector != nil }.count }
        var reviews: [Int: OrganizerReviewItem] = [:]
        // Compare loose files against frozen seed centroids, so assignment order cannot create a semantic snowball.
        for n in files.indices where assigned[n] == nil {
            guard let vector = files[n].vector else { continue }
            let scored = groups.values.compactMap { group -> (String, Double)? in
                guard let center = group.center else { return nil }
                return (group.project.id, Self.dot(vector, center))
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            guard let best = scored.first else { continue }
            let margin = best.1 - (scored.dropFirst().first?.1 ?? -1)
            if best.1 >= Self.matchThreshold && margin >= Self.ambiguityMargin {
                let supporting = seedSupport[best.0] ?? 0
                add(n, to: best.0, reason: .semantic, score: best.1,
                    automatic: best.1 >= Self.moveThreshold && supporting >= 2 && groups[best.0]!.project.isExistingFolder
                        && files[n].record.state == "done")
            } else if best.1 >= 0.65 {
                reviews[n] = OrganizerReviewItem(path: files[n].record.path, fileID: files[n].record.id,
                                                 suggestedProjectID: best.0, score: best.1,
                                                 reason: "Related content needs review: the match is weak or ambiguous.")
            }
        }
        // Deterministic bounded leader clustering for new loose files. Every member must match the fixed anchor and
        // final centroid; unlike single-link clustering a chain of distant topics cannot collapse into one project.
        let remaining = files.indices.filter { assigned[$0] == nil && files[$0].vector != nil }
        var available = Set(remaining)
        var bins: [String: [Int]] = [:], signatures: [Int: [UInt16]] = [:]
        for n in remaining {
            let keys = Self.signatures(files[n].vector!)
            signatures[n] = keys
            for (table, signature) in keys.enumerated() {
                bins["\(table)|\(signature)", default: []].append(n)
            }
        }
        var clusters: [[Int]] = []
        for anchor in remaining where available.remove(anchor) != nil {
            let vector = files[anchor].vector!
            // Four deterministic sparse-projection hash tables shortlist candidates. This deliberately bounds an
            // initial cleanup's work: grouping can miss a weak neighbor, but never invents a cosine match.
            var candidateSet = Set<Int>()
            for (table, signature) in signatures[anchor]!.enumerated() {
                let keys = [signature] + (0..<10).map { signature ^ (1 << $0) }
                for key in keys {
                    for n in bins["\(table)|\(key)"] ?? [] where available.contains(n) {
                        candidateSet.insert(n)
                        if candidateSet.count >= Self.maximumClusterCandidates { break }
                    }
                    if candidateSet.count >= Self.maximumClusterCandidates { break }
                }
                if candidateSet.count >= Self.maximumClusterCandidates { break }
            }
            let peers = candidateSet.sorted().filter { Self.dot(vector, files[$0].vector!) >= Self.moveThreshold }
            guard !peers.isEmpty else { continue }
            let candidate = [anchor] + peers
            let center = Self.center(candidate.compactMap { files[$0].vector })!
            let members = candidate.filter { Self.dot(files[$0].vector!, center) >= Self.moveThreshold }
            guard members.count >= 2, members.contains(anchor) else { continue }
            let memberSet = Set(members)
            available.subtract(memberSet)
            clusters.append(members)
        }
        let previousProjectByFile = Dictionary(uniqueKeysWithValues: previous.assignments.map { ($0.fileID, $0.projectID) })
        for members in clusters {
            let root = files[members[0]].root
            let name = Self.projectName(members.map { files[$0].tokens })
            var priorCounts: [String: Int] = [:]
            for n in members {
                if let id = previousProjectByFile[files[n].record.id], oldProjects[id]?.isExistingFolder == false {
                    priorCounts[id, default: 0] += 1
                }
            }
            let stable = priorCounts.keys.filter { priorCounts[$0]! >= 2 && groups[$0] == nil }.sorted {
                priorCounts[$0] == priorCounts[$1] ? $0 < $1 : priorCounts[$0]! > priorCounts[$1]!
            }.first
            let id = stable ?? "project-" + Self.stableID(root + "\n" + String(files[members[0]].record.id))
            let prior = oldProjects[id]
            let display = prior?.isUserNamed == true ? prior!.name : name
            let destination = root + "/" + Self.managedFolderName + "/" + Self.safeFolder(display) + "-" + String(id.suffix(6))
            let center = Self.center(members.compactMap { files[$0].vector })!
            let project = OrganizerProject(id: id, name: display, memberCount: members.count, rootPath: root,
                                           destinationPath: prior?.destinationPath ?? destination, isExistingFolder: false,
                                           isUserNamed: prior?.isUserNamed ?? false)
            groups[id] = Group(project: project, members: [], center: center, terms: Self.terms(display))
            for n in members {
                reviews.removeValue(forKey: n)
                // New collections remain virtual until the user approves a destination; their names are metadata.
                add(n, to: id, reason: .semantic, score: Self.dot(files[n].vector!, center))
            }
        }
        // Filename overlap is deliberately labelled and never authorizes a physical move.
        for n in files.indices where assigned[n] == nil && reviews[n] == nil {
            let scored = groups.values.compactMap { group -> (String, Double)? in
                let overlap = files[n].tokens.intersection(group.terms).count
                guard overlap >= 2 else { return nil }
                return (group.project.id, Double(overlap) / Double(max(1, files[n].tokens.count)))
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            if let best = scored.first, best.1 >= 0.6, best.1 - (scored.dropFirst().first?.1 ?? -1) >= 0.2 {
                add(n, to: best.0, reason: .filename, score: best.1)
            }
        }
        // No vectors: repeated, informative filename terms can still form explicitly named metadata collections.
        let metadata = files.indices.filter { assigned[$0] == nil && reviews[$0] == nil && files[$0].vector == nil }
        var buckets: [String: [Int]] = [:]
        var frequency: [String: Int] = [:]
        for n in metadata {
            for token in files[n].tokens { frequency[files[n].root + "\n" + token, default: 0] += 1 }
        }
        for n in metadata {
            let informative = files[n].tokens.sorted {
                let a = frequency[files[n].root + "\n" + $0] ?? 0
                let b = frequency[files[n].root + "\n" + $1] ?? 0
                return a == b ? $0 < $1 : a > b
            }.prefix(2).sorted()
            let key = informative.joined(separator: " ")
            if informative.count == 2 { buckets[files[n].root + "\n" + key, default: []].append(n) }
        }
        for key in buckets.keys.sorted() {
            let members = buckets[key]!
            guard members.count >= 2 else { continue }
            let id = "metadata-" + Self.stableID(key), root = files[members[0]].root
            let name = oldProjects[id]?.isUserNamed == true ? oldProjects[id]!.name : Self.projectName(members.map { files[$0].tokens })
            let project = OrganizerProject(id: id, name: name, memberCount: members.count, rootPath: root,
                                           destinationPath: oldProjects[id]?.destinationPath ??
                                               root + "/" + Self.managedFolderName + "/" + Self.safeFolder(name) + "-" + String(id.suffix(6)),
                                           isExistingFolder: false, isUserNamed: oldProjects[id]?.isUserNamed ?? false)
            groups[id] = Group(project: project, members: [], center: nil, terms: Self.terms(name))
            for n in members { add(n, to: id, reason: .filename, score: 1) }
        }
        for n in files.indices where assigned[n] == nil && reviews[n] == nil {
            reviews[n] = OrganizerReviewItem(path: files[n].record.path, fileID: files[n].record.id,
                                             suggestedProjectID: nil, score: nil,
                                             reason: files[n].vector == nil ? "No content embedding or clear filename match yet." : "No confident project match yet.")
        }
        var projects: [OrganizerProject] = []
        for group in groups.values where !group.members.isEmpty {
            var project = group.project
            project.memberCount = group.members.count
            projects.append(project)
        }
        projects.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return OrganizerProjectSnapshot(projects: projects, assignments: assigned.values.sorted { $0.path < $1.path },
                                        reviewItems: reviews.values.sorted { $0.path < $1.path },
                                        generation: generation, vectorSource: source)
    }

    private func loadCache() throws -> [Int64: Cached] {
        var cache: [Int64: Cached] = [:]
        try db.query("SELECT file_id, path, size, modified, vector_generation, vector FROM organizer_file_cache") {
            cache[$0.int(0)] = Cached(path: $0.text(1) ?? "", size: $0.int(2), modified: $0.double(3),
                                      vectorGeneration: $0.int(4), vector: Self.decode($0.blob(5)).flatMap(Self.normalized))
        }
        return cache
    }

    private static func representative(index: IndexStore, file: Int64) throws -> [Float]? {
        var vectors: [[Float]] = []
        try index.db.query("SELECT vec FROM segments WHERE file = ? AND vec IS NOT NULL AND kind != 'name' ORDER BY id LIMIT ?",
                           [.int(file), .int(Int64(representativeSegments))]) {
            if let vector = decode($0.blob(0)), let unit = normalized(vector) { vectors.append(unit) }
        }
        return center(vectors)
    }
    private static func decode(_ data: Data?) -> [Float]? {
        guard let data, data.count == Vectors.dimension * MemoryLayout<Float16>.stride else { return nil }
        return data.withUnsafeBytes { bytes in
            (0..<Vectors.dimension).map { Float(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self)) }
        }
    }
    private static func normalized(_ values: [Float]) -> [Float]? {
        guard values.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude > 0.000001, magnitude.isFinite else { return nil }
        return values.map { Float(Double($0) / magnitude) }
    }
    private static func center(_ vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: Vectors.dimension)
        for vector in vectors { for n in sum.indices { sum[n] += vector[n] } }
        return normalized(sum)
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        let value = a.withUnsafeBytes { left in
            b.withUnsafeBytes { right in
                var sum = SIMD8<Float>.zero
                for offset in stride(from: 0, to: a.count * 4, by: 32) {
                    sum += left.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                        * right.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                }
                return Double(sum.sum())
            }
        }
        return max(-1, min(1, value))
    }
    private static func signatures(_ vector: [Float]) -> [UInt16] {
        var random: UInt64 = 0xD16_0A9_2026
        var result: [UInt16] = []
        for _ in 0..<4 {
            var signature: UInt16 = 0
            for bit in 0..<10 {
                var projection: Float = 0
                for _ in 0..<16 {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    let index = Int((random >> 32) % UInt64(Vectors.dimension))
                    projection += (random & 1 == 0 ? 1 : -1) * vector[index]
                }
                if projection >= 0 { signature |= 1 << bit }
            }
            result.append(signature)
        }
        return result
    }
    private static func indexIdentity(_ file: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let birth = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return canonical(file.path) + "|" + device + "|" + (inode ?? "") + "|" + String(birth)
    }
    private static func spellings(_ path: String) -> [String] {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let real = canonical(path)
        var result = [standard, real]
        #if os(macOS)
        if real.hasPrefix("/private/var/") || real.hasPrefix("/private/tmp/") { result.append(String(real.dropFirst(8))) }
        #endif
        return result
    }
    private static func canonical(_ path: String) -> String {
        FolderSelection.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
    }
    private static func isIgnored(path: String, root: String) -> Bool {
        let parts = path.dropFirst(root.count).split(separator: "/").map(String.init)
        let bundles: Set<String> = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary",
                                    "xcodeproj", "xcworkspace", "noindex", "band", "logicx"]
        return parts.contains { $0.hasPrefix(".") || Rules.skippedFolderNames.contains($0)
            || bundles.contains(($0 as NSString).pathExtension.lowercased()) } || Rules.isSecret(parts.last ?? "")
    }
    private static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "file", "copy", "final",
        "draft", "document", "documents", "download", "downloads", "desktop", "screenshot", "screen", "shot", "untitled", "img", "image", "photo", "video", "audio", "notes", "note", "pdf", "txt", "doc", "docx", "png", "jpg", "jpeg", "heic", "mp3", "mp4"]
    private static func terms(_ name: String) -> Set<String> {
        let stem = (name as NSString).deletingPathExtension
        return Set(stem.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !stopWords.contains($0) })
    }
    private static func projectName(_ sets: [Set<String>]) -> String {
        var counts: [String: Int] = [:]
        for terms in sets { for term in terms { counts[term, default: 0] += 1 } }
        let words = counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0]! > counts[$1]! }.prefix(3)
        return words.isEmpty ? "Related Files" : words.map { $0.capitalized }.joined(separator: " ")
    }
    private static func safeFolder(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "Related Files" : String(safe.prefix(80))
    }
    private static func stableID(_ text: String) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM organizer_meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }
    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO organizer_meta VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }
    private func invalidate() throws { try setMeta("revision", String((Int(try meta("revision") ?? "0") ?? 0) + 1)) }
}
