import Foundation
import Testing
@testable import DigUpKit

@Suite struct OrganizerProjectTests {
    private func withStores(_ body: (IndexStore, OrganizerProjectStore, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpOrganizerProjects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try IndexStore(directory: home.appendingPathComponent("index"))
        try index.setMeta("vector_source", "local-model-A")
        try body(index, OrganizerProjectStore(directory: index.directory), root)
    }
    private func vector(_ axis: Int, _ second: (Int, Float)? = nil) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        vector[axis] = 1
        if let second { vector[second.0] = second.1 }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return vector.map { $0 / norm }
    }
    @discardableResult
    private func add(_ index: IndexStore, _ root: URL, _ name: String, values: [Float]? = nil,
                     state: String = "done", kind: FileKind = .doc) throws -> Int64 {
        let path = root.appendingPathComponent(name).path
        let id = try index.insert(Candidate(path: path, kind: kind, size: 10, mtime: 1, inode: UInt64(path.count), device: 1))
        if let values { try index.addSegment(file: id, kind: .chunk, modality: .text, vector: values) }
        try index.finish(id, state: state)
        return id
    }

    @Test func existingFoldersSeedConfidentLooseAssignments() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/research.md", values: vector(0))
            try add(index, root, "Atlas/budget.pdf", values: vector(0), kind: .pdf)
            try add(index, root, "Borealis/report.md", values: vector(1))
            try add(index, root, "Borealis/slides.pdf", values: vector(1), kind: .pdf)
            let loose = try add(index, root, "unrelated-filename.txt", values: vector(0))
            let snapshot = try organizer.refresh(index: index, roots: [root])
            let match = try #require(snapshot.assignments.first { $0.fileID == loose })
            let project = try #require(snapshot.projects.first { $0.id == match.projectID })
            #expect(project.name == "Atlas")
            #expect(project.memberCount == 3)
            #expect(match.reason == .semantic)
            #expect(match.canMoveAutomatically)
            #expect(snapshot.assignments.filter { $0.reason == .existingFolder }.allSatisfy { !$0.canMoveAutomatically })
            #expect(snapshot.reviewItems.isEmpty)
            #expect(try organizer.refresh(index: index, roots: [root]) == snapshot)
        }
    }

    @Test func ambiguousOrSingleSeedMatchNeverAuthorizesAMove() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            let loose = try add(index, root, "loose.md", values: vector(0))
            var snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(snapshot.assignments.first { $0.fileID == loose }?.canMoveAutomatically == false)
            try add(index, root, "Borealis/one.md", values: vector(0))
            snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(!snapshot.assignments.contains { $0.fileID == loose })
            #expect(snapshot.reviewItems.first { $0.fileID == loose }?.suggestedProjectID != nil)
        }
    }

    @Test func semanticCollectionsAreDeterministicVirtualAndStable() throws {
        try withStores { index, organizer, root in
            let first = try add(index, root, "Mars research overview.md", values: vector(0))
            try add(index, root, "Mars mission budget.pdf", values: vector(0), kind: .pdf)
            try add(index, root, "isolated.txt", values: vector(1))
            let before = try organizer.refresh(index: index, roots: [root])
            let project = try #require(before.projects.first)
            #expect(project.memberCount == 2)
            #expect(!project.isExistingFolder)
            #expect(project.destinationPath.contains("/Redig Organized/"))
            #expect(before.assignments.allSatisfy { !$0.canMoveAutomatically })
            #expect(before.reviewItems.count == 1)
            try organizer.rename(projectID: project.id, name: "Mars Mission")
            try add(index, root, "a-new-brief.txt", values: vector(0))
            let after = try organizer.refresh(index: index, roots: [root])
            #expect(after.projects.first { $0.id == project.id }?.name == "Mars Mission")
            #expect(after.projects.first { $0.id == project.id }?.memberCount == 3)
            #expect(after.assignments.first { $0.fileID == first }?.projectID == project.id)
            #expect(after.assignments.allSatisfy { !$0.canMoveAutomatically })
        }
    }

    @Test func managedFolderFilesKeepTheirProjectAndAreNeverMovedAgain() throws {
        try withStores { index, organizer, root in
            let a = try add(index, root, "Mars research.md", values: vector(0))
            let b = try add(index, root, "Mars budget.md", values: vector(0))
            let before = try organizer.refresh(index: index, roots: [root])
            let project = try #require(before.projects.first)
            try index.move(a, to: project.destinationPath + "/Mars research.md")
            try index.move(b, to: project.destinationPath + "/Mars budget.md")
            let after = try organizer.refresh(index: index, roots: [root])
            #expect(after.projects.count == 1)
            #expect(after.projects.first?.id == project.id)
            #expect(after.projects.first?.name == project.name)
            #expect(after.assignments.allSatisfy { $0.reason == .existingFolder && !$0.canMoveAutomatically })
        }
    }

    @Test(arguments: ["DigUp Organized", "Redig Organized"])
    func managedFoldersExposeTheirContainedProjects(folder: String) throws {
        try withStores { index, organizer, root in
            try add(index, root, "\(folder)/Atlas/research.md", values: vector(0))
            try add(index, root, "\(folder)/Borealis/budget.md", values: vector(1))
            let snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(snapshot.projects.map(\.name) == ["Atlas", "Borealis"])
            let expectedRoot = FolderSelection.realPath(root.path) + "/" + folder
            #expect(snapshot.projects.map(\.destinationPath) == [expectedRoot + "/Atlas", expectedRoot + "/Borealis"])
            #expect(snapshot.assignments.allSatisfy { $0.reason == .existingFolder && !$0.canMoveAutomatically })
        }
    }

    @Test(arguments: [true, false])
    func rebrandingKeepsPreviouslyChosenDestinations(semantic: Bool) throws {
        try withStores { index, organizer, root in
            try add(index, root, "Mars mission budget.md", values: semantic ? vector(0) : nil)
            try add(index, root, "Mars mission research.md", values: semantic ? vector(0) : nil)
            let before = try organizer.refresh(index: index, roots: [root])
            let project = try #require(before.projects.first)
            #expect(project.destinationPath.contains("/Redig Organized/"))
            let legacyDestination = project.destinationPath.replacingOccurrences(of: "/Redig Organized/", with: "/DigUp Organized/")
            let cache = try Database(path: index.directory.appendingPathComponent("organizer.sqlite").path)
            // Simulate a collection persisted by the previous product, then force a refresh with a new file.
            for table in ["organizer_projects", "organizer_meta"] {
                let column = table == "organizer_projects" ? "payload" : "value"
                try cache.run("UPDATE \(table) SET \(column) = replace(\(column), ?, ?)",
                              [.text("Redig Organized"), .text("DigUp Organized")])
            }
            try add(index, root, "Mars mission plan.md", values: semantic ? vector(0) : nil)
            let after = try organizer.refresh(index: index, roots: [root])
            let current = try #require(after.projects.first { $0.id == project.id })
            #expect(current.destinationPath == legacyDestination)
            #expect(current.memberCount == 3)
        }
    }

    @Test func deletedExcludedPendingAndHiddenFilesLeaveNoStaleAssignments() throws {
        try withStores { index, organizer, root in
            let deleted = try add(index, root, "Atlas/delete.md", values: vector(0))
            try add(index, root, "Atlas/keep.md", values: vector(0))
            try add(index, root, "Atlas/.hidden.md", values: vector(0))
            try add(index, root, "node_modules/leak.md", values: vector(0))
            try add(index, root, "Library.app/leak.md", values: vector(0))
            try add(index, root, "Borealis/private.pdf", values: vector(0), kind: .pdf)
            try add(index, root, "pending.md", values: vector(0), state: "pending")
            try add(index, root, "failed.md", values: vector(0), state: "failed")
            let before = try organizer.refresh(index: index, roots: [root])
            #expect(before.assignments.count == 3)
            try index.delete(deleted)
            let after = try organizer.refresh(index: index, roots: [root], excluded: [root.appendingPathComponent("Borealis")],
                                              excludedExtensions: ["pdf"])
            #expect(after.assignments.count == 1)
            #expect(after.projects.map(\.name) == ["Atlas"])
            #expect(after.reviewItems.isEmpty)
            let empty = try organizer.refresh(index: index, roots: [])
            #expect(empty.projects.isEmpty && empty.assignments.isEmpty && empty.reviewItems.isEmpty)
        }
    }

    @Test func changedVectorSourceRefreshesRepresentativesInsteadOfReusingOldCenters() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            try add(index, root, "Atlas/two.md", values: vector(0))
            try add(index, root, "Borealis/one.md", values: vector(1))
            try add(index, root, "Borealis/two.md", values: vector(1))
            let loose = try add(index, root, "loose.md", values: vector(0))
            let before = try organizer.refresh(index: index, roots: [root])
            let atlas = try #require(before.projects.first { $0.name == "Atlas" })
            #expect(before.assignments.first { $0.fileID == loose }?.projectID == atlas.id)
            try index.setMeta("vector_source", "local-model-B")
            try index.deleteSegments(of: loose)
            try index.addSegment(file: loose, kind: .chunk, modality: .text, vector: vector(1))
            let after = try organizer.refresh(index: index, roots: [root])
            let borealis = try #require(after.projects.first { $0.name == "Borealis" })
            #expect(after.vectorSource == "local-model-B")
            #expect(after.assignments.first { $0.fileID == loose }?.projectID == borealis.id)
        }
    }

    @Test func manualChoiceSurvivesModelChangeMoveAndTemporaryExclusion() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            let loose = try add(index, root, "loose.md", values: vector(1))
            let before = try organizer.refresh(index: index, roots: [root])
            let project = try #require(before.projects.first)
            try organizer.rename(projectID: project.id, name: "My Research")
            try organizer.assign(filePath: root.appendingPathComponent("loose.md").path, to: project.id)
            var current = try organizer.refresh(index: index, roots: [root])
            #expect(current.assignments.first { $0.fileID == loose }?.reason == .manual)
            try index.setMeta("vector_source", "model-B")
            try index.move(loose, to: root.appendingPathComponent("renamed.md").path)
            current = try organizer.refresh(index: index, roots: [root], excluded: [root.appendingPathComponent("Atlas")])
            #expect(current.projects.first?.name == "My Research")
            #expect(current.assignments.first { $0.fileID == loose }?.projectID == project.id)
            #expect(current.assignments.first { $0.fileID == loose }?.reason == .manual)
            #expect(current.assignments.first { $0.fileID == loose }?.canMoveAutomatically == false)
        }
    }

    @Test func missingOrInvalidVectorsUseExplicitFilenameFallback() throws {
        try withStores { index, organizer, root in
            try index.setMeta("vector_source", nil)
            try add(index, root, "Atlas mission budget.pdf", kind: .pdf)
            try add(index, root, "Atlas mission research.md")
            let single = try add(index, root, "unrelated.txt")
            let snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(snapshot.projects.count == 1)
            #expect(snapshot.assignments.count == 2)
            #expect(snapshot.assignments.allSatisfy { $0.reason == .filename && !$0.canMoveAutomatically })
            #expect(snapshot.reviewItems.map(\.fileID) == [single])
            #expect(snapshot.vectorSource == nil)
        }
    }

    @Test func malformedAndNonfiniteVectorsCannotMakeConfidentAssignments() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            try add(index, root, "Atlas/two.md", values: vector(0))
            try add(index, root, "bad-a.md", values: [Float](repeating: .nan, count: 768))
            try add(index, root, "bad-b.md", values: [1, 0])
            let snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(snapshot.assignments.count == 2)
            #expect(snapshot.reviewItems.count == 2)
        }
    }

    @Test func partialContentCanGroupWithoutReadingTheOriginalFile() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.pdf", values: vector(0), state: "partial", kind: .pdf)
            try add(index, root, "Atlas/two.pdf", values: vector(0), state: "partial", kind: .pdf)
            let loose = try add(index, root, "offline-placeholder.pdf", values: vector(0), state: "partial", kind: .pdf)
            let snapshot = try organizer.refresh(index: index, roots: [root])
            #expect(snapshot.assignments.first { $0.fileID == loose }?.reason == .semantic)
            #expect(snapshot.reviewItems.isEmpty)
        }
    }

    @Test func downloadsMatchAProjectInDocuments() throws {
        try withStores { index, organizer, documents in
            let downloads = documents.deletingLastPathComponent().appendingPathComponent("Downloads")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try add(index, documents, "Atlas/one.md", values: vector(0))
            try add(index, documents, "Atlas/two.md", values: vector(0))
            let incoming = try add(index, downloads, "downloaded-attachment.pdf", values: vector(0), kind: .pdf)
            let snapshot = try organizer.refresh(index: index, roots: [downloads, documents])
            let assignment = try #require(snapshot.assignments.first { $0.fileID == incoming })
            let project = try #require(snapshot.projects.first { $0.id == assignment.projectID })
            #expect(project.destinationPath.hasSuffix("/Documents/Atlas"))
            #expect(assignment.reason == .semantic)
            #expect(assignment.canMoveAutomatically)
        }
    }

    @Test func unchangedAndMetadataOnlyRefreshesReadNoVectorBlobs() throws {
        try withStores { index, organizer, root in
            let a = try add(index, root, "Atlas/one.md", values: vector(0))
            try add(index, root, "Atlas/two.md", values: vector(0))
            _ = try organizer.refresh(index: index, roots: [root])
            #expect(organizer.representativeReads == 2)
            _ = try organizer.refresh(index: index, roots: [root])
            #expect(organizer.representativeReads == 0)
            try index.finish(a, state: "done", info: ["chars": "100"])
            _ = try organizer.refresh(index: index, roots: [root])
            #expect(organizer.representativeReads == 0)
            try index.deleteSegments(of: a)
            try index.addSegment(file: a, kind: .chunk, modality: .text, vector: vector(1))
            _ = try organizer.refresh(index: index, roots: [root])
            #expect(organizer.representativeReads == 1)
            try index.setMeta("vector_source", "model-B")
            _ = try organizer.refresh(index: index, roots: [root])
            #expect(organizer.representativeReads == 2)
        }
    }


    @Test func manualOverrideCannotAttachToAnUnrelatedReusedIDInAnotherIndex() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            try add(index, root, "Borealis/one.md", values: vector(1))
            let original = try add(index, root, "original.md", values: vector(2))
            let first = try organizer.refresh(index: index, roots: [root])
            let atlas = try #require(first.projects.first { $0.name == "Atlas" })
            try organizer.assign(filePath: root.appendingPathComponent("original.md").path, to: atlas.id)
            _ = try organizer.refresh(index: index, roots: [root])
            let other = try IndexStore(directory: index.directory, file: "replacement.sqlite")
            try other.setMeta("vector_source", "local-model-A")
            try add(other, root, "Atlas/new.md", values: vector(0))
            try add(other, root, "Borealis/new.md", values: vector(1))
            let unrelated = try add(other, root, "unrelated.md", values: vector(2))
            #expect(original == unrelated)
            let second = try organizer.refresh(index: other, roots: [root])
            #expect(!second.assignments.contains { $0.fileID == unrelated && $0.reason == .manual })
            #expect(second.reviewItems.contains { $0.fileID == unrelated })
        }
    }

    @Test func recreatedIndexWithSameGenerationCannotReturnAnOldSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpRebuiltIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexFolder = folder.appendingPathComponent("index")
        let organizer = try OrganizerProjectStore(directory: folder.appendingPathComponent("organizer"))
        var oldGeneration: Int64 = -1
        do {
            let index = try IndexStore(directory: indexFolder)
            try index.setMeta("vector_source", "local-model-A")
            try add(index, root, "Old Project/one.md", values: vector(0))
            oldGeneration = try organizer.refresh(index: index, roots: [root]).generation
        }
        try FileManager.default.removeItem(at: indexFolder)
        let replacement = try IndexStore(directory: indexFolder)
        try replacement.setMeta("vector_source", "local-model-A")
        try add(replacement, root, "New Project/one.md", values: vector(1))
        let current = try organizer.refresh(index: replacement, roots: [root])
        #expect(current.generation == oldGeneration)
        #expect(current.projects.map(\.name) == ["New Project"])
    }


    @Test func theNewestManualChoiceWinsAfterAFileRename() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            try add(index, root, "Borealis/one.md", values: vector(1))
            let file = try add(index, root, "zulu.md", values: vector(2))
            let first = try organizer.refresh(index: index, roots: [root])
            let atlas = try #require(first.projects.first { $0.name == "Atlas" })
            let borealis = try #require(first.projects.first { $0.name == "Borealis" })
            try organizer.assign(filePath: root.appendingPathComponent("zulu.md").path, to: atlas.id)
            _ = try organizer.refresh(index: index, roots: [root])
            try index.move(file, to: root.appendingPathComponent("alpha.md").path)
            _ = try organizer.refresh(index: index, roots: [root])
            try organizer.assign(filePath: root.appendingPathComponent("alpha.md").path, to: borealis.id)
            let after = try organizer.refresh(index: index, roots: [root])
            #expect(after.assignments.first { $0.fileID == file }?.projectID == borealis.id)
            #expect(after.assignments.first { $0.fileID == file }?.reason == .manual)
        }
    }


    @Test func assignmentsCarryTheIdentityOfTheIndexedContent() throws {
        try withStores { index, organizer, root in
            let path = root.appendingPathComponent("Atlas/identity.md").path
            let inode = UInt64.max - 17, device = UInt64.max - 29
            let id = try index.insert(Candidate(path: path, kind: .doc, size: 42, mtime: 123,
                                                inode: inode, device: device))
            try index.finish(id, state: "done")
            let snapshot = try organizer.refresh(index: index, roots: [root])
            let assignment = try #require(snapshot.assignments.first { $0.fileID == id })
            #expect(assignment.inode == inode)
            #expect(assignment.device == device)
            #expect(assignment.size == 42)
            #expect(assignment.modified == 123)
            #expect(try organizer.snapshot().assignments.first == assignment)
        }
    }

    @Test func anObsoleteGroupingSnapshotIsRebuiltWithoutDiscardingManualChoices() throws {
        try withStores { index, organizer, root in
            try add(index, root, "Atlas/one.md", values: vector(0))
            let loose = try add(index, root, "loose.md", values: vector(1))
            let before = try organizer.refresh(index: index, roots: [root])
            let atlas = try #require(before.projects.first)
            try organizer.rename(projectID: atlas.id, name: "My Research")
            try organizer.assign(filePath: root.appendingPathComponent("loose.md").path, to: atlas.id)
            let chosen = try organizer.refresh(index: index, roots: [root])
            let data = try JSONEncoder().encode(chosen)
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var assignments = try #require(json["assignments"] as? [[String: Any]])
            for n in assignments.indices { assignments[n].removeValue(forKey: "inode"); assignments[n].removeValue(forKey: "device") }
            json["assignments"] = assignments
            let obsolete = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            let cache = try Database(path: index.directory.appendingPathComponent("organizer.sqlite").path)
            try cache.run("UPDATE organizer_meta SET value = ? WHERE key = 'snapshot'", [.text(obsolete)])
            #expect(try organizer.snapshot() == .empty)
            let rebuilt = try organizer.refresh(index: index, roots: [root])
            #expect(rebuilt.projects.first?.name == "My Research")
            #expect(rebuilt.assignments.first { $0.fileID == loose }?.reason == .manual)
            #expect(rebuilt.assignments.first { $0.fileID == loose }?.projectID == atlas.id)
            #expect(rebuilt.assignments.allSatisfy { $0.inode > 0 && $0.device == 1 })
        }
    }

}
