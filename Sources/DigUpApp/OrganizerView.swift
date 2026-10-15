import AppKit
import DigUpKit
import SwiftUI

/// Project collections are virtual until the user enables filing or files an individual match.
struct OrganizerView: View {
    let organizer: OrganizerController
    @State private var expanded: Set<String> = []
    @State private var renaming: OrganizerProject?
    @State private var name = ""

    private var members: [String: [OrganizerAssignment]] {
        Dictionary(grouping: organizer.snapshot.assignments, by: \.projectID)
    }

    var body: some View {
        Form {
            introduction
            if !organizer.roots.isEmpty {
                controls
                folders
                progress
                if !organizer.snapshot.projects.isEmpty { projects }
                if !organizer.snapshot.reviewItems.isEmpty { review }
            }
            if !organizer.history.isEmpty { history }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { shown in
            if !shown { renaming = nil }
        })) {
            TextField("Project name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { organizer.rename(projectID: renaming.id, name: name) }
                renaming = nil
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name for this project collection.")
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let your files find their projects")
                    .font(.system(size: 13, weight: .semibold))
                Text("Redig connects related files on this Mac. Project collections keep files where they are; "
                     + "filing moves them into a project folder and keeps an undo history.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if organizer.roots.isEmpty {
                Button("Organize Downloads Automatically") { organizer.startDownloadsAutomation() }
                    .disabled(organizer.busy)
                Text("Drop related files into Downloads. Redig creates project folders for clear groups and keeps Undo for every move.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use Downloads, Desktop & Documents") { organizer.enableSuggestedFolders() }
                    .disabled(organizer.busy)
                Button("Choose Folders…") { organizer.chooseFolders() }
                    .disabled(organizer.busy)
                Text("Choose which folders Redig may read. File contents and project matching stay local.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = organizer.problem { problemText(problem) }
            }
        }
    }

    private var controls: some View {
        Section {
            Toggle(isOn: Binding(get: { organizer.enabled }, set: { organizer.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group files into projects")
                    Text("Collections update as Redig indexes new and changed files.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { organizer.automaticMoves }, set: { organizer.setAutomaticMoves($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File strong matches automatically")
                    Text("Only settled, loose files with a clear project match are moved. "
                         + "Uncertain files stay for review. Each move is recorded for undo below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!organizer.enabled)
            Toggle(isOn: Binding(get: { organizer.createProjectFolders }, set: { organizer.setCreateProjectFolders($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create project folders automatically")
                    Text("Strong groups of related files get their own folder in Redig Organized. No existing project folder is needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!organizer.enabled || !organizer.automaticMoves)
            Text("Press ⇧⌘Space and type > for commands, preview, projects and Undo.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var folders: some View {
        Section {
            ForEach(organizer.roots, id: \.path) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.lastPathComponent)
                        Text(tildePath(folder.path))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button { organizer.removeRoot(folder) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(organizer.busy)
                    .help("Stop organizing this folder")
                    .accessibilityLabel("Stop organizing \(folder.lastPathComponent)")
                }
            }
        } header: {
            Text("Folders to organize")
        } footer: {
            HStack {
                Button { organizer.chooseFolders() } label: {
                    Label("Add Folders…", systemImage: "plus")
                }
                .disabled(organizer.busy)
                Spacer()
            }
        }
    }

    private var progress: some View {
        Section {
            HStack(spacing: 10) {
                if organizer.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(organizer.statusText)
                        .font(.system(size: 12, weight: .medium))
                    if let updated = organizer.lastUpdated {
                        Text("Updated \(updated, style: .relative) ago")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh") { organizer.refresh() }
                    .disabled(organizer.busy || !organizer.enabled)
            }
            if let problem = organizer.problem { problemText(problem) }
            if organizer.snapshot.projects.isEmpty && !organizer.busy {
                Text("Projects appear when related files have been indexed. You can keep searching while Redig works.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var projects: some View {
        let grouped = members
        return Section {
            ForEach(organizer.snapshot.projects.prefix(50)) { project in
                DisclosureGroup(isExpanded: expansion(project.id)) {
                    if expanded.contains(project.id) {
                        projectContents(project, assignments: grouped[project.id] ?? [])
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: project.isExistingFolder ? "folder" : "square.stack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.system(size: 12, weight: .medium))
                            Text("\(project.memberCount.formatted()) files · \((project.rootPath as NSString).lastPathComponent)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Menu {
                            Button("Rename…") { name = project.name; renaming = project }
                            Button("Show Folder in Finder") {
                                organizer.reveal(URL(fileURLWithPath: project.isExistingFolder
                                                     ? project.destinationPath : project.rootPath))
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(organizer.busy)
                        .accessibilityLabel("Actions for \(project.name)")
                    }
                }
            }
            if organizer.snapshot.projects.count > 50 {
                Text("Showing 50 of \(organizer.snapshot.projects.count.formatted()) projects.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Collections combine related files without changing your folders. "
                 + "File a match to move it into the project folder shown inside its collection.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func projectContents(_ project: OrganizerProject, assignments: [OrganizerAssignment]) -> some View {
        Text(tildePath(project.destinationPath))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 4)
        ForEach(assignments.prefix(50)) { assignment in
            HStack(alignment: .top, spacing: 8) {
                fileLabel(path: assignment.path, detail: assignmentDetail(assignment))
                Spacer(minLength: 8)
                if !isFiled(assignment, in: project) {
                    Button("File") { organizer.move(assignment) }
                        .controlSize(.small)
                        .disabled(organizer.busy || !organizer.enabled)
                        .help("Move to \(tildePath(project.destinationPath))")
                }
                projectMenu(path: assignment.path)
            }
            .padding(.vertical, 3)
        }
        if assignments.count > 50 {
            Text("Showing 50 of \(assignments.count.formatted()) files.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var review: some View {
        Section {
            ForEach(organizer.snapshot.reviewItems.prefix(50)) { item in
                HStack(alignment: .top, spacing: 8) {
                    fileLabel(path: item.path, detail: item.reason)
                    Spacer(minLength: 8)
                    projectMenu(path: item.path, label: "Assign…")
                }
                .padding(.vertical, 2)
            }
            if organizer.snapshot.reviewItems.count > 50 {
                Text("Showing 50 of \(organizer.snapshot.reviewItems.count.formatted()) files to review.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Needs a project")
        } footer: {
            Text("Assign a project when a match is unclear. The file stays in place.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var history: some View {
        Section {
            ForEach(organizer.history.prefix(50)) { record in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.source.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(moveState(record.state)) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("From \(tildePath(record.source.path))\nTo \(tildePath(record.destination.path))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                        if let error = record.error { problemText(error) }
                    }
                    Spacer(minLength: 8)
                    if record.canUndo {
                        Button("Undo") { organizer.undo(record) }
                            .controlSize(.small)
                            .disabled(organizer.busy)
                            .help("Return this file to its original location")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Move history")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if organizer.historyOffset > 0 || organizer.hasOlderHistory {
                    HStack {
                        Button("Newer") { organizer.newerHistory() }
                            .disabled(organizer.busy || organizer.historyOffset == 0)
                        Spacer()
                        Button("Older") { organizer.olderHistory() }
                            .disabled(organizer.busy || !organizer.hasOlderHistory)
                    }
                }
                Text("Undo returns a file only when it is unchanged and its original location is free.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fileLabel(path: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { organizer.reveal(URL(fileURLWithPath: path)) } label: {
                Text((path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help(tildePath(path))
            Text(detail)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func projectMenu(path: String, label: String? = nil) -> some View {
        Menu {
            Button("Show in Finder") { organizer.reveal(URL(fileURLWithPath: path)) }
            if !organizer.snapshot.projects.isEmpty {
                Divider()
                ForEach(organizer.snapshot.projects.prefix(50)) { project in
                    Button("\(project.name) · \((project.rootPath as NSString).lastPathComponent)") {
                        organizer.assign(filePath: path, projectID: project.id)
                    }
                }
            }
        } label: {
            if let label { Text(label) }
            else { Image(systemName: "ellipsis.circle") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(organizer.busy || !organizer.enabled)
        .accessibilityLabel("Choose project for \((path as NSString).lastPathComponent)")
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in
            if on { expanded.insert(id) } else { expanded.remove(id) }
        })
    }

    private func assignmentDetail(_ assignment: OrganizerAssignment) -> String {
        switch assignment.reason {
        case .existingFolder: "Existing project folder"
        case .semantic: "Related content · \(Int((assignment.score * 100).rounded()))% similarity"
        case .filename: "Related filenames"
        case .manual: "Assigned by you"
        }
    }

    private func isFiled(_ assignment: OrganizerAssignment, in project: OrganizerProject) -> Bool {
        assignment.path.hasPrefix(project.destinationPath + "/")
    }

    private func moveState(_ state: OrganizerMoveJournal.State) -> String {
        switch state {
        case .planned: "Pending"
        case .moved: "Filed"
        case .undone: "Undone"
        case .failed: "Could not move"
        }
    }

    private func problemText(_ problem: String) -> some View {
        Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
