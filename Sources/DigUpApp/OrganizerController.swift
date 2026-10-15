import AppKit
import DigUpKit
import Observation

nonisolated struct OrganizerSettings: Sendable {
    var enabled = false
    var automaticMoves = false
    var createProjectFolders = true
    var roots: [URL] = []

    static func load() -> Self {
        let defaults = AppSettings.defaults
        let bookmarks = defaults.dictionary(forKey: "organizerBookmarks") as? [String: Data] ?? [:]
        let roots = (defaults.stringArray(forKey: "organizerRoots") ?? []).map { path -> URL in
            if let data = bookmarks[path] {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
            }
            return AppSettings.folderURL(path)
        }
        return Self(enabled: defaults.bool(forKey: "organizerEnabled"),
                    automaticMoves: defaults.bool(forKey: "organizerAutomaticMoves"),
                    createProjectFolders: defaults.object(forKey: "organizerCreateProjectFolders") == nil
                        || defaults.bool(forKey: "organizerCreateProjectFolders"), roots: roots)
    }

    func save() {
        let defaults = AppSettings.defaults
        defaults.set(enabled, forKey: "organizerEnabled")
        defaults.set(automaticMoves, forKey: "organizerAutomaticMoves")
        defaults.set(createProjectFolders, forKey: "organizerCreateProjectFolders")
        defaults.set(roots.map(\.path), forKey: "organizerRoots")
        var bookmarks: [String: Data] = [:]
        for root in roots {
            if let data = (try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                relativeTo: nil))
                ?? (try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                          relativeTo: nil)) { bookmarks[root.path] = data }
        }
        defaults.set(bookmarks, forKey: "organizerBookmarks")
    }
}

/// UI state stays on the main actor; SQLite, vector grouping and file coordination have their own serial queue.
@Observable final class OrganizerController {
    private(set) var snapshot = OrganizerProjectSnapshot.empty
    private(set) var history: [OrganizerMoveJournal.MoveRecord] = []
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var lastUpdated: Date?
    private(set) var historyOffset = 0
    private(set) var hasOlderHistory = false
    private(set) var lastActionMessage: String?
    @ObservationIgnored private unowned let app: AppController
    @ObservationIgnored private let worker: OrganizerWorker
    @ObservationIgnored private let downloadsDirectory: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "DigUp.organizer", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var refreshWanted = false
    @ObservationIgnored private var securityScopes: [URL] = []
    @ObservationIgnored private var movePolicyHeld = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var enabled: Bool { app.model.settings.organizer.enabled }
    var automaticMoves: Bool { app.model.settings.organizer.automaticMoves }
    var createProjectFolders: Bool { app.model.settings.organizer.createProjectFolders }
    var roots: [URL] { app.model.settings.organizer.roots }
    var statusText: String {
        if busy { return "Updating local projects…" }
        if !enabled { return "Project grouping is off." }
        if app.model.status.paused { return "Paused with indexing." }
        if app.model.status.heldUntil != nil { return "Waiting for your indexing hours." }
        if !app.model.status.unreadableRoots.isEmpty { return "Allow folder access in macOS Privacy & Security → Files and Folders." }
        if !app.model.status.missingRoots.isEmpty { return "Waiting for an unavailable folder or drive." }
        if snapshot.assignments.isEmpty {
            return app.model.status.waitingForModel
                ? "Waiting for the local model and your first indexed files."
                : "Projects appear as your files finish indexing."
        }
        return "\(snapshot.projects.count) projects · \(snapshot.assignments.count) grouped files · \(snapshot.reviewItems.count) to review"
    }

    init(app: AppController, downloadsDirectory: URL? = nil) {
        self.app = app
        worker = OrganizerWorker(directory: app.model.settings.indexDirectory)
        self.downloadsDirectory = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func start() {
        updateSecurityScopes()
        observeIndex()
        refresh()
        // Also catches a completed download that became old enough to file without another index commit.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.enabled == true { self?.refresh() } }
        }
    }

    private func observeIndex() {
        let status = app.model.status
        let held = status.paused || status.heldUntil != nil || !status.unreadableRoots.isEmpty || !status.missingRoots.isEmpty
        if held != movePolicyHeld {
            movePolicyHeld = held
            worker.invalidate()
        }
        withObservationTracking { _ = app.model.status } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeIndex()
                if self.enabled { self.scheduleRefresh() }
            }
        }
    }

    private func scheduleRefresh() {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            self.refresh()
        }
    }

    func enableSuggestedFolders() {
        let fm = FileManager.default
        let folders = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        configure(roots: folders)
    }

    /// A single first-run action: watch Downloads and let coherent local groups become project folders.
    func startDownloadsAutomation() {
        app.model.settings.organizer.automaticMoves = true
        app.model.settings.organizer.createProjectFolders = true
        ensureConfiguredForCommand()
        app.model.settings.organizer.save()
        configurationChanged()
    }

    func ensureConfiguredForCommand(activate: Bool = true) {
        if roots.isEmpty {
            configure(roots: [downloadsDirectory], enabled: activate || enabled)
        } else if activate, !enabled {
            setEnabled(true)
        }
    }

    func chooseFolders() {
        app.pickFolders(for: nil, prompt: "Organize") { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.configure(roots: self.roots + urls)
        }
    }

    private func configure(roots: [URL], enabled: Bool = true) {
        let selection = FolderSelection(chosen: roots.map(\.path), skipped: [])
        app.model.settings.organizer.roots = selection.folders.map(AppSettings.folderURL)
        app.model.settings.organizer.enabled = enabled
        app.model.settings.organizer.save()
        updateSecurityScopes()
        app.applyFolders(app.model.settings.roots + self.roots)
        if !app.model.settings.onboarded {
            AppSettings.saveOnboarded()
            app.model.settings.onboarded = true
            app.onboarding?.close()
        }
        if !app.download.isReady { app.download.start() }
        configurationChanged()
    }

    func setEnabled(_ value: Bool) {
        if value, roots.isEmpty { enableSuggestedFolders(); return }
        app.model.settings.organizer.enabled = value
        app.model.settings.organizer.save()
        if value { app.applyFolders(app.model.settings.roots + roots) }
        updateSecurityScopes()
        configurationChanged()
    }

    func setAutomaticMoves(_ value: Bool) {
        app.model.settings.organizer.automaticMoves = value
        app.model.settings.organizer.save()
        configurationChanged()
    }

    func setCreateProjectFolders(_ value: Bool) {
        app.model.settings.organizer.createProjectFolders = value
        app.model.settings.organizer.save()
        configurationChanged()
    }

    func removeRoot(_ root: URL) {
        app.model.settings.organizer.roots.removeAll { $0.path == root.path }
        if roots.isEmpty { app.model.settings.organizer.enabled = false }
        app.model.settings.organizer.save()
        updateSecurityScopes()
        configurationChanged()
    }

    private func updateSecurityScopes() {
        for url in securityScopes { url.stopAccessingSecurityScopedResource() }
        securityScopes = roots.filter { $0.startAccessingSecurityScopedResource() }
    }

    func configurationChanged() {
        worker.invalidate()
        scheduled?.cancel()
        scheduled = nil
        refresh()
    }

    func refresh() { enqueue(.refresh) }

    /// Explicit commands wait for a pending refresh rather than disappearing when the queue is busy.
    func performCommand(_ action: OrganizerWorker.Action) async -> String {
        if busy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        return await withCheckedContinuation { continuation in
            enqueue(action) { result in
                switch result {
                case .success(let output):
                    if let problem = output.problem {
                        let prefix = output.movedCount > 0 ? "Filed \(output.movedCount) files. " : ""
                        continuation.resume(returning: prefix + problem)
                    } else if let message = output.message {
                        continuation.resume(returning: message)
                    } else if output.moved {
                        continuation.resume(returning: "Updated files. Every completed move is in history.")
                    } else {
                        continuation.resume(returning: "\(output.snapshot.projects.count) projects · \(output.snapshot.reviewItems.count) files to review.")
                    }
                case .failure(let error): continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    func olderHistory() { if !busy { enqueue(.history(historyOffset + 50)) } }
    func newerHistory() { if !busy { enqueue(.history(max(0, historyOffset - 50))) } }

    func move(_ assignment: OrganizerAssignment) {
        guard enabled, !busy else { return }
        enqueue(.move(assignment))
    }

    func undo(_ record: OrganizerMoveJournal.MoveRecord) {
        guard !busy, record.canUndo else { return }
        enqueue(.undo(record.id))
    }

    func rename(projectID: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !name.isEmpty else { return }
        enqueue(.rename(projectID, name))
    }

    func assign(filePath: String, projectID: String) {
        guard enabled, !busy else { return }
        enqueue(.assign(filePath, projectID))
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func enqueue(_ action: OrganizerWorker.Action,
                         completion: (@MainActor @Sendable (Result<OrganizerWorker.Output, Error>) -> Void)? = nil) {
        if busy {
            if completion == nil { refreshWanted = true }
            completion?(.failure(OrganizerMoveJournal.Failure(message: "Another organizer action is running. Try again when it finishes.")))
            return
        }
        busy = true
        problem = nil
        let settings = app.model.settings
        let status = app.model.status
        var operationSettings = settings
        switch action {
        case .preview, .sort, .fileProject:
            // Explicit reads/filing can use selected scopes without turning ongoing automation back on.
            operationSettings.organizer.enabled = true
        default: break
        }
        let config = OrganizerConfiguration(settings: operationSettings, status: status, revision: worker.revision)
        queue.async { [worker, weak self] in
            let result: Result<OrganizerWorker.Output, Error> = Result { try worker.perform(action, config: config) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                var delivered = result
                if self.worker.revision == config.revision {
                    switch result {
                    case .success(let output):
                        self.snapshot = output.snapshot
                        self.history = output.history
                        self.historyOffset = output.historyOffset
                        self.hasOlderHistory = output.hasOlderHistory
                        self.problem = output.problem
                        self.lastUpdated = Date()
                        self.lastActionMessage = output.message
                        if output.moved { self.app.engine.filesOrganized() }
                    case .failure(let error): self.problem = error.localizedDescription
                    }
                } else {
                    // An in-flight atomic move may have finished before a settings change; always resync its paths.
                    if case .success(let output) = result, output.moved { self.app.engine.filesOrganized() }
                    self.refreshWanted = true
                    delivered = .failure(OrganizerMoveJournal.Failure(message: "Folder settings changed during this action. Completed moves are in history; refresh and try again."))
                }
                completion?(delivered)
                if self.refreshWanted { self.refreshWanted = false; self.refresh() }
                if !self.busy {
                    let waiters = self.idleWaiters
                    self.idleWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
        }
    }
}

extension OrganizerConfiguration {
    nonisolated init(settings: AppSettings, status: EngineStatus, revision: UInt64) {
        // Removing a search root immediately revokes it for grouping and future moves too.
        let roots = settings.organizer.roots.filter { candidate in
            settings.roots.contains { Self.contains($0, candidate) }
                && !settings.excludedFolders.contains { Self.contains($0, candidate) }
        }
        let automatic = settings.organizer.automaticMoves && !status.paused && status.heldUntil == nil
            && status.unreadableRoots.isEmpty && status.missingRoots.isEmpty
        self.init(roots: roots, excluded: settings.excludedFolders, excludedTypes: Set(settings.excludedTypes),
                  enabled: settings.organizer.enabled, automatic: automatic,
                  createProjectFolders: settings.organizer.createProjectFolders, revision: revision)
    }
}
