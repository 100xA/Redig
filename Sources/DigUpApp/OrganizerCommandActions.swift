import DigUpKit
import Foundation

extension AppController {
    /// Called only when a command is explicitly submitted. Typing and completions never invoke this dispatcher.
    func runOrganizerCommand(_ command: OrganizerCommand) async -> String {
        switch command {
        case .help:
            return "Choose a command with ↑ ↓, complete it with Tab, and press Return to run it."
        case .organize:
            showSettings(.organizer)
            return "Opened Organizer settings."
        case .settings:
            showSettings()
            return "Opened Settings."
        case .automaticFiling(let on):
            if on { organizer.ensureConfiguredForCommand() }
            organizer.setAutomaticMoves(on)
            if on {
                return organizer.createProjectFolders
                    ? "Automatic filing is on. Clear groups can create their own project folders."
                    : "Automatic filing is on for existing project folders. Use >folders on to allow new folders."
            }
            return "Automatic filing is off. Project suggestions and Undo remain available."
        case .createProjectFolders(let on):
            organizer.setCreateProjectFolders(on)
            return on ? "New project folders are allowed for confident groups."
                : "New project folders are off. Existing projects can still receive strong matches."
        case .sort:
            organizer.ensureConfiguredForCommand(activate: false)
            if model.status.paused { return "Indexing is paused. Run >resume before sorting." }
            if model.status.heldUntil != nil { return "Sorting is waiting for your indexing hours. Adjust them in Settings." }
            if !model.status.unreadableRoots.isEmpty { return "Allow folder access in macOS Privacy & Security → Files and Folders, then try again." }
            if !model.status.missingRoots.isEmpty { return "A watched folder is unavailable. Reconnect it before sorting." }
            let feedback = await organizer.performCommand(.sort)
            if organizer.problem == nil, !download.isReady {
                return "The local model is not ready yet. Once indexing finishes, run >sort again or use >auto on."
            }
            return feedback
        case .preview:
            organizer.ensureConfiguredForCommand(activate: false)
            let feedback = await organizer.performCommand(.preview)
            if organizer.problem != nil { return feedback }
            return "Preview: \(organizer.snapshot.projects.count) projects, \(organizer.snapshot.assignments.count) grouped files, \(organizer.snapshot.reviewItems.count) to review. This command moved no files."
        case .projects(let query):
            if organizer.enabled {
                let feedback = await organizer.performCommand(.preview)
                if organizer.problem != nil { return feedback }
            }
            let projects = organizer.snapshot.projects.filter { project in
                query.map { project.name.localizedCaseInsensitiveContains($0) } ?? true
            }
            if projects.isEmpty {
                return organizer.enabled ? "No matching projects yet. Drop related files into a watched folder and let indexing finish."
                    : "Use >auto on to start watching Downloads, or >organize to choose folders."
            }
            return "\(projects.count) \(projects.count == 1 ? "project" : "projects"). Choose one to inspect its files or file it."
        case .review:
            if organizer.enabled {
                let feedback = await organizer.performCommand(.preview)
                if organizer.problem != nil { return feedback }
            }
            let count = organizer.snapshot.reviewItems.count
            return count == 0 ? "No uncertain files to review right now."
                : "\(count) \(count == 1 ? "file needs" : "files need") a project. Choose Assign to correct a match."
        case .history:
            let feedback = await organizer.performCommand(.history(0))
            if organizer.problem != nil { return feedback }
            return organizer.history.isEmpty ? "No moves recorded yet."
                : "Move history is ready. Choose Undo to restore a recorded file."
        case .undo(let id):
            return await organizer.performCommand(id.map(OrganizerWorker.Action.undo) ?? .undoLatest)
        case .file(let name):
            organizer.ensureConfiguredForCommand(activate: false)
            let preview = await organizer.performCommand(.preview)
            if organizer.problem != nil { return preview }
            let exactID = organizer.snapshot.projects.first { $0.id == name }
            let named = organizer.snapshot.projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard let project = exactID ?? (named.count == 1 ? named[0] : nil) else {
                return named.count > 1 ? "Several projects share that name. Choose the project in >projects."
                    : "No project called \(name). Use >projects to find its name."
            }
            return await organizer.performCommand(.fileProject(project.id))
        case .pause:
            setIndexingPaused(true)
            return "Indexing and automatic filing are paused. Run >resume to continue."
        case .resume:
            setIndexingPaused(false)
            return "Indexing resumed. Automatic filing follows your saved settings."
        }
    }
}
