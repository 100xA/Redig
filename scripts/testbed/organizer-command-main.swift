import AppKit
import DigUpKit
import Foundation
import Observation
import SwiftUI

// These stubs record only app-shell effects. Production settings, commands, palette, organizer controller,
// project grouping and journal code are compiled unchanged by test-organizer-commands.sh.
nonisolated struct EngineStatus: Sendable, Equatable {
    var paused = false
    var heldUntil: Date?
    var waitingForModel = false
    var unreadableRoots: [String] = []
    var missingRoots: [String] = []
}

@Observable final class AppModel {
    var settings: AppSettings
    var status = EngineStatus()
    init(settings: AppSettings) { self.settings = settings }
}

final class ProbeDownload {
    var isReady = true
    var starts = 0
    func start() { starts += 1 }
}

final class ProbeEngine {
    private let model: AppModel
    var fileChanges = 0
    var pauses: [Bool] = []
    init(model: AppModel) { self.model = model }
    func filesOrganized() { fileChanges += 1 }
    func setPaused(_ value: Bool) { pauses.append(value); model.status.paused = value }
}

enum SettingsTab { case general, organizer }
final class ProbeOnboarding { var closes = 0; func close() { closes += 1 } }

final class AppController {
    let model: AppModel
    let download = ProbeDownload()
    let engine: ProbeEngine
    let downloads: URL
    var onboarding: ProbeOnboarding? = ProbeOnboarding()
    var settingsShown: [SettingsTab] = []
    var folderSelections = 0
    var folderApplications: [[URL]] = []
    lazy var organizer = OrganizerController(app: self, downloadsDirectory: downloads)

    init(settings: AppSettings, downloads: URL) {
        model = AppModel(settings: settings)
        engine = ProbeEngine(model: model)
        self.downloads = downloads
    }
    func showSettings(_ tab: SettingsTab = .general) { settingsShown.append(tab) }
    func pickFolders(for window: NSWindow?, prompt: String, then: @escaping ([URL]) -> Void) {
        folderSelections += 1
    }
    func applyFolders(_ roots: [URL]) {
        folderApplications.append(roots)
        model.settings.roots = roots
        AppSettings.save(roots: roots)
    }
    func setIndexingPaused(_ value: Bool) {
        model.status.paused = value
        engine.setPaused(value)
        organizer.configurationChanged()
    }
}

enum Brand {
    static let leaf = Color.green
    static let gradient = LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom)
}

struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeFailure(message: message) }
}

/// Unstructured tasks let a timeout throw even if the code being tested loses its continuation.
private final class TimeoutRace<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    var operation: Task<Void, Never>?
    var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operation?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

private func withTimeout<T: Sendable>(_ label: String, seconds: Double = 15,
                                      operation: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation)
        race.operation = Task { @MainActor in
            do { race.finish(.success(try await operation())) }
            catch { race.finish(.failure(error)) }
        }
        race.timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            race.finish(.failure(ProbeFailure(message: "Timed out: \(label)")))
        }
    }
}

private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    while !predicate() { try await Task.sleep(for: .milliseconds(10)) }
}

private final class Fixture {
    let home: URL
    let downloads: URL
    let app: AppController
    let files: [URL]

    init(configured: Bool = true, enabled: Bool? = nil, automatic: Bool = false, count: Int = 3) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("RedigCommandProbe-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: OrganizerConfiguration.canonicalPath(folder))
        downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        var settings = AppSettings.load()
        settings.roots = configured ? [downloads] : []
        settings.excludedFolders = []
        settings.excludedTypes = []
        settings.indexDirectory = home.appendingPathComponent("index.noindex")
        settings.modelsDirectory = home.appendingPathComponent("models.noindex")
        settings.onboarded = configured
        settings.organizer = OrganizerSettings(enabled: enabled ?? configured, automaticMoves: automatic,
                                              createProjectFolders: true, roots: configured ? [downloads] : [])
        settings.organizer.save()
        app = AppController(settings: settings, downloads: downloads)
        let fixtureDownloads = downloads
        files = Array(["Atlas research.md", "Atlas budget.md", "Atlas mission.md"].prefix(count))
            .map { fixtureDownloads.appendingPathComponent($0) }
        for file in files {
            try String(repeating: "Local Atlas mission research notes. ", count: 20)
                .write(to: file, atomically: false, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: file.path)
        }
        let index = try IndexStore(directory: settings.indexDirectory)
        try index.setMeta("vector_source", "local-command-fixture")
        let candidates = Crawler.crawl([downloads], options: IndexOptions()).candidates
        try check(candidates.count == files.count, "Fixture files were not crawled")
        for candidate in candidates {
            let id = try index.insert(candidate)
            var vector = [Float](repeating: 0, count: 768)
            vector[0] = 1
            try index.addSegment(file: id, kind: .chunk, modality: .text, vector: vector)
            try index.finish(id, state: "done")
        }
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func originalsExist() -> Bool { files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
    func settle() async throws { try await waitUntil { !self.app.organizer.busy } }
    func send(_ query: String) async throws -> String {
        guard case .success(let command) = OrganizerCommand.parse(query) else {
            throw ProbeFailure(message: "Invalid probe command: \(query)")
        }
        return await app.runOrganizerCommand(command)
    }
}

@main private struct OrganizerCommandProbe {
    static func main() async {
        guard let suite = UserDefaults.standard.string(forKey: "defaultsSuite"),
              suite.hasPrefix("com.redig.command-regression.") else {
            fatalError("Pass a temporary -defaultsSuite; this probe never uses real app preferences")
        }
        AppSettings.defaults.removePersistentDomain(forName: suite)
        defer { AppSettings.defaults.removePersistentDomain(forName: suite) }
        do {
            let scenarios: [(String, @MainActor () async throws -> Void)] = [
                ("typing and completion have no side effects", typingIsReadOnly),
                ("first-run command uses only injected Downloads", firstRunConfiguration),
                ("preview never files with automatic filing on", previewIsReadOnly),
                ("disabled automation stays off for preview and one-shot sort", disabledAutomationStaysDisabled),
                ("fresh preview prepares roots without enabling automation", freshPreviewIsReadOnly),
                ("one-shot sort creates folders and Undo restores files", oneShotAndUndo),
                ("folder policy persists and can be changed independently", folderPolicy),
                ("pause and unavailable roots block command filing", pauseAndAvailability),
                ("project commands and errors reach the palette", projectCommandsAndFeedback),
            ]
            for (name, scenario) in scenarios {
                AppSettings.defaults.removePersistentDomain(forName: suite)
                try await withTimeout(name, operation: scenario)
                print("PASS \(name)")
            }
            print("PASS \(scenarios.count) native organizer command scenarios (no model or personal folders)")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func typingIsReadOnly() async throws {
        let f = try Fixture()
        let palette = CommandPaletteController(app: f.app)
        let settings = f.app.model.settings.organizer
        for query in [">", ">auto on", ">folders off", ">sort", ">undo", ">file \"Atlas\""] {
            palette.update(query)
            palette.move(by: 1)
            palette.move(by: -1)
            _ = palette.completion()
        }
        try await Task.sleep(for: .milliseconds(50))
        try check(f.originalsExist(), "Typing or completion moved a file")
        try check(f.app.organizer.history.isEmpty && f.app.engine.fileChanges == 0, "Typing invoked organizer work")
        try check(f.app.model.settings.organizer.automaticMoves == settings.automaticMoves, "Typing changed automatic filing")
        try check(f.app.model.settings.organizer.createProjectFolders == settings.createProjectFolders, "Typing changed folder policy")
        try check(f.app.organizer.lastUpdated == nil && f.app.folderApplications.isEmpty, "Typing refreshed or configured folders")
        try check(!palette.running && palette.feedback == nil, "Typing executed a command")
        palette.update(">not-a-command")
        _ = palette.execute()
        try check(palette.feedback?.contains("Unknown command") == true, "Invalid command did not show its parser error")
        try check(f.originalsExist(), "Invalid command moved files")
    }

    private static func firstRunConfiguration() async throws {
        let f = try Fixture(configured: false, count: 0)
        f.app.download.isReady = false
        let palette = CommandPaletteController(app: f.app)
        palette.update(">auto on")
        _ = palette.execute()
        try await waitUntil { !palette.running && !f.app.organizer.busy }
        try check(f.app.organizer.enabled && f.app.organizer.automaticMoves, "Explicit >auto on did not enable automation")
        try check(f.app.organizer.roots.map { OrganizerConfiguration.canonicalPath($0) } == [f.downloads.path], "First-run command chose a personal folder")
        try check(f.app.model.settings.roots.contains { OrganizerConfiguration.canonicalPath($0) == f.downloads.path }, "Organizer folder did not enter indexing scope")
        try check(f.app.download.starts > 0 && f.app.model.settings.onboarded, "First-run command did not initialize indexing")
        try check(OrganizerSettings.load().automaticMoves, "Automatic filing preference was not saved")
        try check(palette.feedback?.contains("Automatic filing is on") == true, "Command result did not reach search palette")
    }

    private static func previewIsReadOnly() async throws {
        let f = try Fixture(automatic: true)
        let result = try await f.send(">preview")
        try check(!f.app.organizer.snapshot.projects.isEmpty, "Preview did not group fixture files")
        try check(result.contains("moved no files"), "Preview feedback did not describe its behavior")
        try check(f.originalsExist() && f.app.organizer.history.isEmpty, "Preview filed files with automatic policy on")
        try check(f.app.organizer.automaticMoves, "Preview changed the saved automatic policy")
    }

    private static func disabledAutomationStaysDisabled() async throws {
        let f = try Fixture(enabled: false, automatic: true)
        _ = try await f.send(">preview")
        try await f.settle()
        try check(!f.app.organizer.snapshot.projects.isEmpty, "Disabled preview did not group its explicit scope")
        try check(f.originalsExist() && f.app.organizer.history.isEmpty, "Preview reactivated a saved automatic move policy")
        try check(!f.app.organizer.enabled && !OrganizerSettings.load().enabled, "Preview enabled ongoing grouping")
        try check(f.app.organizer.automaticMoves && OrganizerSettings.load().automaticMoves, "Preview changed the saved automatic filing preference")
        let result = try await f.send(">sort")
        try await f.settle()
        try check(result.contains("Sorted") && !f.app.organizer.history.isEmpty, "Disabled grouping blocked the explicit one-shot sort")
        try check(!f.app.organizer.enabled && !OrganizerSettings.load().enabled, "One-shot sort enabled ongoing grouping")
        try check(f.app.organizer.automaticMoves && OrganizerSettings.load().automaticMoves, "One-shot sort changed the saved automatic policy")
        let project = try require(f.app.organizer.snapshot.projects.first, "Missing disabled project")
        for _ in f.files { _ = try await f.send(">undo") }
        let filed = try await f.send(CommandPaletteController.fileQuery(project.id))
        try check(filed.contains("Filed") && f.app.organizer.history.filter(\.canUndo).count == f.files.count, "Disabled grouping blocked explicit project filing")
        try check(!f.app.organizer.enabled && !OrganizerSettings.load().enabled, "Explicit project filing enabled ongoing grouping")
        try check(f.app.organizer.automaticMoves && OrganizerSettings.load().automaticMoves, "Explicit project filing changed the saved automatic policy")
    }

    private static func freshPreviewIsReadOnly() async throws {
        let f = try Fixture(configured: false, automatic: true)
        _ = try await f.send(">preview")
        try await f.settle()
        try check(f.app.organizer.roots.map { OrganizerConfiguration.canonicalPath($0) } == [f.downloads.path], "Fresh preview did not prepare only the injected Downloads")
        try check(!f.app.organizer.snapshot.projects.isEmpty, "Fresh preview did not group fixture files")
        try check(f.originalsExist() && f.app.organizer.history.isEmpty, "Fresh preview triggered automatic moves")
        try check(!f.app.organizer.enabled && !OrganizerSettings.load().enabled, "Fresh preview enabled ongoing grouping")
        try check(f.app.organizer.automaticMoves && OrganizerSettings.load().automaticMoves, "Fresh preview changed the automatic filing preference")
    }

    private static func oneShotAndUndo() async throws {
        let f = try Fixture()
        let result = try await f.send(">sort")
        try check(!f.app.organizer.automaticMoves && !OrganizerSettings.load().automaticMoves, "One-shot sort changed automatic filing")
        try check(f.app.organizer.history.filter(\.canUndo).count == f.files.count, "One-shot sort did not journal every file")
        try check(!f.originalsExist(), "One-shot sort left all source files in Downloads")
        try check(f.app.organizer.snapshot.projects.count == 1, "Related downloads were not made into one project")
        let project = try require(f.app.organizer.snapshot.projects.first, "Missing project")
        try check(FileManager.default.fileExists(atPath: project.destinationPath), "Automatic project folder was not created")
        try check(result.contains("Sorted"), "Sort did not return filing feedback")
        for _ in f.files { _ = try await f.send(">undo") }
        try check(f.originalsExist(), "Undo did not restore all source files")
        try check(f.app.organizer.history.allSatisfy { $0.state == .undone }, "Undo was not recorded durably")
        _ = try await f.send(">sort")
        try check(f.originalsExist(), "A subsequent sort immediately refiled undone files")
    }

    private static func folderPolicy() async throws {
        let f = try Fixture()
        _ = try await f.send(">folders off")
        try await f.settle()
        try check(!OrganizerSettings.load().createProjectFolders, "Folder-creation setting was not persisted")
        _ = try await f.send(">sort")
        try check(f.originalsExist() && f.app.organizer.history.isEmpty, "Sort created a project folder despite >folders off")
        _ = try await f.send(">folders on")
        try await f.settle()
        try check(OrganizerSettings.load().createProjectFolders, "Folder creation did not turn back on")
        try check(!f.app.organizer.automaticMoves, "Folder setting implicitly enabled automatic filing")
        _ = try await f.send(">sort")
        try check(!f.app.organizer.history.isEmpty, "Re-enabled folder creation did not permit explicit filing")
        _ = try await f.send(">auto off")
        try await f.settle()
        try check(!OrganizerSettings.load().automaticMoves, "Automatic filing off was not saved")
    }

    private static func pauseAndAvailability() async throws {
        let f = try Fixture()
        _ = try await f.send(">pause")
        try check(f.app.model.status.paused && f.app.engine.pauses == [true], "Pause did not reach the engine")
        let paused = try await f.send(">sort")
        try check(paused.contains(">resume"), "Paused sort did not explain how to resume")
        try check(f.originalsExist() && f.app.organizer.history.isEmpty, "Sort bypassed pause")
        _ = try await f.send(">resume")
        try check(!f.app.model.status.paused && f.app.engine.pauses == [true, false], "Resume did not reach the engine")
        f.app.model.status.missingRoots = [f.downloads.path]
        let unavailable = try await f.send(">sort")
        try check(unavailable.contains("unavailable"), "Unavailable root error was not returned")
        f.app.model.status.missingRoots = []
        f.app.model.status.heldUntil = Date(timeIntervalSinceNow: 100)
        let scheduled = try await f.send(">sort")
        try check(scheduled.contains("indexing hours"), "Index schedule did not gate sorting")
        try check(f.originalsExist(), "Blocked commands moved files")
        try await f.settle()
    }

    private static func projectCommandsAndFeedback() async throws {
        let f = try Fixture()
        _ = try await f.send(">projects Atlas")
        try check(f.originalsExist(), "Browsing projects moved files")
        let project = try require(f.app.organizer.snapshot.projects.first, "Missing project after preview")
        let palette = CommandPaletteController(app: f.app)
        palette.update(">file")
        try check(palette.suggestions.count == 1, "Project command did not offer its live project")
        palette.update(CommandPaletteController.fileQuery(project.name))
        _ = palette.execute()
        try await waitUntil { !palette.running && !f.app.organizer.busy }
        try check(f.app.organizer.history.count == f.files.count, "Explicit project command did not file its members")
        try check(palette.feedback?.contains("Filed") == true, "File result was not shown in palette")
        palette.update(">undo 9223372036854775807")
        _ = palette.execute()
        try await waitUntil { !palette.running && !f.app.organizer.busy }
        try check(f.app.organizer.problem != nil && palette.feedback == f.app.organizer.problem, "Journal error was not shown in palette")
        _ = try await f.send(">organize")
        _ = try await f.send(">settings")
        try check(f.app.settingsShown == [.organizer, .general], "Navigation commands opened the wrong settings pane")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(message: message) }
        return value
    }
}
