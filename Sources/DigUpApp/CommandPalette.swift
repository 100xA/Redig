import AppKit
import DigUpKit
import Observation
import SwiftUI

/// Command text stays on the main thread and never enters the file-search or embedding pipeline. Merely editing
/// a command updates its local preview; a command runs only after Return or a labeled action button.
@Observable
final class CommandPaletteController {
    private(set) var query = ""
    private(set) var selection: String?
    private(set) var feedback: String?
    private(set) var running = false
    @ObservationIgnored private unowned let app: AppController
    @ObservationIgnored private var navigated = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var completedProjectID: String?
    @ObservationIgnored private var completedProjectQuery: String?

    init(app: AppController) { self.app = app }

    static func recognizes(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">")
    }

    var organizer: OrganizerController { app.organizer }
    var suggestions: [OrganizerCommandDescriptor] {
        if isFileCommand {
            return projects.prefix(30).map { project in
                OrganizerCommandDescriptor(id: "project:\(project.id)", title: project.name,
                    subtitle: "\(project.memberCount) files · \(project.destinationPath)",
                    query: Self.fileQuery(project.name), systemSymbol: "folder")
            }
        }
        if parsed == .help { return OrganizerCommand.catalog }
        return OrganizerCommand.suggestions(for: query)
    }
    static func fileQuery(_ name: String) -> String {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ">file \"\(quoted)\""
    }
    var selectedSuggestion: OrganizerCommandDescriptor? {
        suggestions.first { $0.id == selection } ?? suggestions.first
    }
    var parsed: OrganizerCommand? {
        guard case .success(let command) = OrganizerCommand.parse(query) else { return nil }
        return command
    }
    var argument: String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
        return text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init) ?? ""
    }
    var projects: [OrganizerProject] {
        let filter: String
        switch parsed {
        case .projects(let query): filter = query ?? ""
        case .file(let project): filter = project
        default: filter = ""
        }
        let needle = filter.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        return organizer.snapshot.projects.filter { needle.isEmpty || $0.name.lowercased().contains(needle) || $0.id.lowercased() == needle }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var isFileCommand: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(whereSeparator: { $0.isWhitespace })
            .first?.lowercased() == "file"
    }

    func update(_ text: String) {
        guard text != query else { return }
        query = text
        revision += 1
        if completedProjectQuery != text { completedProjectID = nil; completedProjectQuery = nil }
        selection = completedProjectID.map { "project:\($0)" } ?? (parsed == .help ? nil : suggestions.first?.id)
        navigated = false
        feedback = nil
    }

    func select(_ suggestion: OrganizerCommandDescriptor) { selection = suggestion.id; navigated = true }

    func move(by delta: Int) {
        let items = suggestions
        guard !items.isEmpty else { return }
        let index = selection.flatMap { selected in items.firstIndex { $0.id == selected } } ?? -1
        selection = items[max(0, min(items.count - 1, index + delta))].id
        navigated = true
    }

    func completion() -> String? {
        guard let selectedSuggestion else { return nil }
        if selectedSuggestion.id.hasPrefix("project:") {
            completedProjectID = String(selectedSuggestion.id.dropFirst("project:".count))
            completedProjectQuery = selectedSuggestion.query
        }
        return selectedSuggestion.query
    }

    @discardableResult func execute() -> String? {
        if !navigated, completedProjectQuery == query, let completedProjectID {
            run(.file(project: completedProjectID)); return nil
        }
        // A complete typed command wins over a prefix completion, unless the arrows explicitly chose another row.
        if !navigated, case .success(let command) = OrganizerCommand.parse(query) { run(command); return nil }
        if let suggestion = selectedSuggestion { return execute(suggestion) }
        if case .failure(let error) = OrganizerCommand.parse(query) { feedback = error.message }
        return nil
    }

    @discardableResult func execute(_ suggestion: OrganizerCommandDescriptor) -> String? {
        if suggestion.id.hasPrefix("project:") {
            run(.file(project: String(suggestion.id.dropFirst("project:".count))))
            return nil
        }
        switch OrganizerCommand.parse(suggestion.query) {
        case .success(let command): run(command)
        case .failure: return suggestion.query + " "
        case nil: break
        }
        return nil
    }

    func run(_ command: OrganizerCommand) {
        guard !running else { return }
        running = true
        let current = revision
        Task { [weak self] in
            guard let self else { return }
            let message = await app.runOrganizerCommand(command)
            if current == revision { feedback = message }
            running = false
        }
    }

    /// Returns true only for palette keys; cursor movement and text editing retain their normal AppKit behavior.
    func handle(_ event: NSEvent, replaceQuery: (String) -> Void) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126: move(by: event.keyCode == 125 ? 1 : -1)
        case 48:
            if let completion = completion() { replaceQuery(completion) }
        case 36, 76:
            if let completion = execute() { replaceQuery(completion) }
        case 53: replaceQuery("")
        default: return false
        }
        return true
    }
}

/// The same palette appears in the hotkey panel and the full search window.
struct CommandPaletteView: View {
    @Bindable var controller: CommandPaletteController
    let replaceQuery: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overview
                    if let feedback = controller.feedback {
                        Text(feedback)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.leaf.opacity(0.10)))
                            .accessibilityLabel("Command result: \(feedback)")
                    }
                    if let problem = controller.organizer.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    context
                    if !controller.isFileCommand && (!hasContext || !controller.suggestions.isEmpty) {
                        commandList
                    }
                }
                .padding(16)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 19, weight: .medium)).foregroundStyle(Brand.gradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("Redig commands").font(.system(size: 14, weight: .semibold))
                Text(controller.organizer.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if controller.running || controller.organizer.busy {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(controller.organizer.automaticMoves ? "Automatic filing on" : "Automatic filing off")
                    Text(controller.organizer.createProjectFolders ? "Project folders on" : "Project folders off")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var hasContext: Bool {
        switch controller.parsed {
        case .projects, .review, .history, .preview, .file: true
        default: controller.isFileCommand
        }
    }

    @ViewBuilder private var context: some View {
        switch controller.parsed {
        case .projects, .file:
            projectList
        case .review:
            reviewList
        case .history:
            historyList
        case .preview:
            previewList
        default:
            if controller.isFileCommand { projectList }
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if controller.suggestions.isEmpty {
                Text("No command matches. Type >help to see every command.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                Text("Choose a command · Tab completes · Return runs")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(controller.suggestions) { suggestion in
                    commandRow(suggestion)
                }
            }
        }
    }

    private func commandRow(_ suggestion: OrganizerCommandDescriptor) -> some View {
        HStack(spacing: 10) {
            Button { controller.select(suggestion); replaceQuery(suggestion.query) } label: {
                HStack(spacing: 10) {
                    Image(systemName: suggestion.systemSymbol)
                        .font(.system(size: 15)).frame(width: 22).foregroundStyle(Brand.gradient)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Text(suggestion.title).font(.system(size: 12, weight: .medium))
                            Text(suggestion.query).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(suggestion.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Complete \(suggestion.query); press Return to run")
            Button {
                if let completion = controller.execute(suggestion) { replaceQuery(completion) }
            } label: { Image(systemName: "return") }
                .buttonStyle(.borderless)
                .disabled(controller.running)
                .help("Run \(suggestion.title)")
                .accessibilityLabel("Run \(suggestion.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(controller.selection == suggestion.id ? Color.accentColor.opacity(0.12) : Color.clear))
        .id(suggestion.id)
        .accessibilityAddTraits(controller.selection == suggestion.id ? .isSelected : [])
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.isFileCommand ? "File into a project" : "Projects")
                .font(.system(size: 12, weight: .semibold))
            if controller.projects.isEmpty {
                Text("Projects appear after related files finish indexing. Drop files into Downloads and run >organize to start.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(controller.projects.prefix(30))) { project in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Brand.gradient).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name).font(.system(size: 12, weight: .medium))
                        Text("\(project.memberCount) files · \(displayPath(project.destinationPath))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("File") { controller.run(.file(project: project.id)) }
                        .disabled(controller.running || controller.organizer.busy)
                        .help("File ready matches into \(displayPath(project.destinationPath))")
                    if !controller.isFileCommand {
                        if FileManager.default.fileExists(atPath: project.destinationPath) {
                            Button("Reveal") { reveal(project.destinationPath) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(controller.isFileCommand && controller.selection == "project:\(project.id)"
                          ? Color.accentColor.opacity(0.12) : Color.clear))
                .id("project:\(project.id)")
            }
            if controller.projects.count > 30 {
                Text("Showing 30 projects. Add a name after >projects to filter.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if controller.isFileCommand {
                Text("Return files this project's eligible matches. Every move is recorded in >history.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Needs review · \(controller.organizer.snapshot.reviewItems.count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") { controller.run(.review) }.buttonStyle(.borderless)
            }
            if controller.organizer.snapshot.reviewItems.isEmpty {
                Text("No files need a project decision.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(controller.organizer.snapshot.reviewItems.prefix(20))) { item in
                HStack(spacing: 10) {
                    Image(systemName: "doc.questionmark").frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((item.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(item.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Menu("Assign…") {
                        ForEach(Array(controller.organizer.snapshot.projects.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }.prefix(100))) { project in
                            Button("\(project.name) · \(displayPath(project.destinationPath))") {
                                controller.organizer.assign(filePath: item.path, projectID: project.id)
                            }
                        }
                        if controller.organizer.snapshot.projects.count > 100 {
                            Button("More in Organizer…") { controller.run(.organize) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(controller.running || controller.organizer.busy || !controller.organizer.enabled
                              || controller.organizer.snapshot.projects.isEmpty)
                    .help("Choose a project for this file")
                    .accessibilityLabel("Assign \((item.path as NSString).lastPathComponent) to a project")
                    Button("Reveal") { reveal(item.path) }.buttonStyle(.borderless)
                }.padding(.vertical, 5)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Move history").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") { controller.run(.history) }.buttonStyle(.borderless)
            }
            if controller.organizer.history.isEmpty {
                Text("Moves appear here with Undo after the first file is filed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(controller.organizer.history.prefix(20))) { record in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: record.canUndo ? "arrow.right.doc.on.clipboard" : "clock.arrow.circlepath")
                        .frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(record.source.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("#\(record.id)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text("\(displayPath(record.destination.path)) · \(record.state.rawValue)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let error = record.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    if record.canUndo {
                        Button("Undo") { controller.run(.undo(id: record.id)) }
                            .disabled(controller.running || controller.organizer.busy)
                            .accessibilityLabel("Undo move of \(record.source.lastPathComponent)")
                    }
                }.padding(.vertical, 5)
            }
        }.buttonStyle(.borderless)
    }

    private var previewList: some View {
        let assignments = controller.organizer.snapshot.assignments.filter(\.canMoveAutomatically)
        let projects = Dictionary(uniqueKeysWithValues: controller.organizer.snapshot.projects.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Strong project matches · \(assignments.count)").font(.system(size: 12, weight: .semibold))
            Text("This preview does not move files. Filing also checks that files have finished downloading and are unchanged.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if assignments.isEmpty {
                Text("No strong matches are ready yet. Related files are grouped after indexing.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(assignments.prefix(20))) { item in
                HStack(spacing: 10) {
                    Image(systemName: "doc").frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((item.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("→ \(projects[item.projectID]?.name ?? "Project")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal") { reveal(item.path) }.buttonStyle(.borderless)
                }.padding(.vertical, 5)
            }
        }
    }

    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func displayPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
