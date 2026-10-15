import AppKit
import DigUpKit
import Observation

nonisolated struct OrganizerSettings: Sendable {
    var enabled = false
    var automaticMoves = false
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
                    automaticMoves: defaults.bool(forKey: "organizerAutomaticMoves"), roots: roots)
    }

    func save() {
        let defaults = AppSettings.defaults
        defaults.set(enabled, forKey: "organizerEnabled")
        defaults.set(automaticMoves, forKey: "organizerAutomaticMoves")
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
    @ObservationIgnored private unowned let app: AppController
    @ObservationIgnored private let worker: OrganizerWorker
    @ObservationIgnored private let queue = DispatchQueue(label: "DigUp.organizer", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var refreshWanted = false
    @ObservationIgnored private var securityScopes: [URL] = []
    @ObservationIgnored private var movePolicyHeld = false

    var enabled: Bool { app.model.settings.organizer.enabled }
    var automaticMoves: Bool { app.model.settings.organizer.automaticMoves }
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

    init(app: AppController) {
        self.app = app
        worker = OrganizerWorker(directory: app.model.settings.indexDirectory)
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

    func chooseFolders() {
        app.pickFolders(for: nil, prompt: "Organize") { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.configure(roots: self.roots + urls)
        }
    }

    private func configure(roots: [URL]) {
        let selection = FolderSelection(chosen: roots.map(\.path), skipped: [])
        app.model.settings.organizer.roots = selection.folders.map(AppSettings.folderURL)
        app.model.settings.organizer.enabled = true
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

    private func enqueue(_ action: OrganizerWorker.Action) {
        if busy { refreshWanted = true; return }
        busy = true
        problem = nil
        let settings = app.model.settings
        let status = app.model.status
        let config = OrganizerConfiguration(settings: settings, status: status, revision: worker.revision)
        queue.async { [worker, weak self] in
            let result: Result<OrganizerWorker.Output, Error> = Result { try worker.perform(action, config: config) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                if self.worker.revision == config.revision {
                    switch result {
                    case .success(let output):
                        self.snapshot = output.snapshot
                        self.history = output.history
                        self.historyOffset = output.historyOffset
                        self.hasOlderHistory = output.hasOlderHistory
                        self.problem = output.problem
                        self.lastUpdated = Date()
                        if output.moved { self.app.engine.filesOrganized() }
                    case .failure(let error): self.problem = error.localizedDescription
                    }
                } else {
                    // An in-flight atomic move may have finished before a settings change; always resync its paths.
                    if case .success(let output) = result, output.moved { self.app.engine.filesOrganized() }
                    self.refreshWanted = true
                }
                if self.refreshWanted { self.refreshWanted = false; self.refresh() }
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
                  enabled: settings.organizer.enabled, automatic: automatic, revision: revision)
    }
}
