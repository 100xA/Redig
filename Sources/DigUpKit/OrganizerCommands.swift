import Foundation

/// Commands entered in Redig's search field. Parsing never runs a shell or performs an action.
public enum OrganizerCommand: Sendable, Equatable {
    case help
    case organize
    case sort
    case preview
    case automaticFiling(Bool)
    case createProjectFolders(Bool)
    case projects(query: String?)
    case review
    case history
    case undo(id: Int64?)
    case file(project: String)
    case pause
    case resume
    case settings

    /// A nil result leaves ordinary queries, including absolute paths, to file search.
    /// Project names can contain spaces, and quotes preserve spaces inside a name.
    public static func parse(_ input: String) -> Result<Self, OrganizerCommandError>? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix(">") else { return nil }
        let words: [String]
        do { words = try tokenize(String(input.dropFirst())) }
        catch let error as OrganizerCommandError { return .failure(error) }
        catch { return .failure(.init(message: "Could not read this command. Type >help for commands.")) }
        guard let first = words.first else { return .success(.help) }
        let verb = first.lowercased()
        let arguments = Array(words.dropFirst())

        func noArguments(_ command: Self) -> Result<Self, OrganizerCommandError> {
            guard arguments.isEmpty else {
                return .failure(.init(message: ">\(verb) does not take arguments. Type >help for commands."))
            }
            return .success(command)
        }

        func toggle(_ makeCommand: (Bool) -> Self) -> Result<Self, OrganizerCommandError> {
            guard arguments.count == 1 else {
                return .failure(.init(message: "Use >\(verb) on or >\(verb) off."))
            }
            switch arguments[0].lowercased() {
            case "on": return .success(makeCommand(true))
            case "off": return .success(makeCommand(false))
            default: return .failure(.init(message: "Use >\(verb) on or >\(verb) off."))
            }
        }

        switch verb {
        case "help": return noArguments(.help)
        case "organize": return noArguments(.organize)
        case "sort": return noArguments(.sort)
        case "preview": return noArguments(.preview)
        case "auto": return toggle { .automaticFiling($0) }
        case "folders": return toggle { .createProjectFolders($0) }
        case "projects":
            let query = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.projects(query: query.isEmpty ? nil : query))
        case "review": return noArguments(.review)
        case "history": return noArguments(.history)
        case "undo":
            guard !arguments.isEmpty else { return .success(.undo(id: nil)) }
            guard arguments.count == 1, !arguments[0].isEmpty,
                  arguments[0].utf8.allSatisfy({ (48...57).contains($0) }),
                  let id = Int64(arguments[0]), id > 0 else {
                return .failure(.init(message: "Use >undo for the latest move, or >undo followed by a positive move ID."))
            }
            return .success(.undo(id: id))
        case "file":
            let project = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !project.isEmpty else {
                return .failure(.init(message: "Add a project name or ID, for example >file \"Client Alpha\"."))
            }
            return .success(.file(project: project))
        case "pause": return noArguments(.pause)
        case "resume": return noArguments(.resume)
        case "settings": return noArguments(.settings)
        default:
            return .failure(.init(message: "Unknown command >\(String(first.prefix(40))). Type >help for commands."))
        }
    }

    public static let catalog: [OrganizerCommandDescriptor] = [
        .init(id: "organize", title: "Open Organizer", subtitle: "Manage watched folders and local project grouping.", query: ">organize", systemSymbol: "folder.badge.gearshape"),
        .init(id: "preview", title: "Preview project groups", subtitle: "Refresh project groups without moving files.", query: ">preview", systemSymbol: "eye"),
        .init(id: "sort", title: "Sort now", subtitle: "File ready strong matches once; automatic filing stays unchanged.", query: ">sort", systemSymbol: "tray.and.arrow.down"),
        .init(id: "projects", title: "Browse projects", subtitle: "List projects; add words to filter their names.", query: ">projects", systemSymbol: "folder"),
        .init(id: "review", title: "Review suggestions", subtitle: "Open files that need a project assignment or approval.", query: ">review", systemSymbol: "checklist"),
        .init(id: "history", title: "View move history", subtitle: "See recorded moves and their Undo controls.", query: ">history", systemSymbol: "clock.arrow.circlepath"),
        .init(id: "undo", title: "Undo the latest move", subtitle: "Restore the latest move, or add a specific move ID.", query: ">undo", systemSymbol: "arrow.uturn.backward"),
        .init(id: "file", title: "File a project", subtitle: "Add a project name or ID to file its ready items.", query: ">file", systemSymbol: "folder.badge.plus"),
        .init(id: "auto-on", title: "Turn automatic filing on", subtitle: "Allow strong matches to move within enabled folders.", query: ">auto on", systemSymbol: "sparkles"),
        .init(id: "auto-off", title: "Turn automatic filing off", subtitle: "Keep project suggestions and stop automatic file moves.", query: ">auto off", systemSymbol: "pause.circle"),
        .init(id: "folders-on", title: "Create project folders automatically", subtitle: "Allow new project folders when filing confident groups.", query: ">folders on", systemSymbol: "folder.badge.plus"),
        .init(id: "folders-off", title: "Stop creating project folders", subtitle: "File into existing project folders only.", query: ">folders off", systemSymbol: "folder.badge.minus"),
        .init(id: "pause", title: "Pause indexing", subtitle: "Pause background file indexing.", query: ">pause", systemSymbol: "pause"),
        .init(id: "resume", title: "Resume indexing", subtitle: "Resume background file indexing.", query: ">resume", systemSymbol: "play"),
        .init(id: "settings", title: "Open Settings", subtitle: "Adjust Redig preferences.", query: ">settings", systemSymbol: "gearshape"),
        .init(id: "help", title: "Show commands", subtitle: "Browse available commands in the search field.", query: ">help", systemSymbol: "questionmark.circle"),
    ]

    /// Completes command names and fixed arguments. Free-form project names are resolved by the app.
    public static func suggestions(for input: String) -> [OrganizerCommandDescriptor] {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix(">") else { return [] }
        let body = input.dropFirst().split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        guard !body.isEmpty else { return catalog }
        return catalog.filter { String($0.query.dropFirst()).hasPrefix(body) }
    }

    private static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)
            if character == "\\", next < input.endIndex {
                let following = input[next]
                // Do not interpret shell escapes or consume ordinary backslashes in project names.
                if following == "\\" || following == "\"" || following == "'" || (quote == nil && following.isWhitespace) {
                    current.append(following)
                    started = true
                    index = input.index(after: next)
                    continue
                }
            }
            if let delimiter = quote {
                if character == delimiter { quote = nil }
                else { current.append(character) }
            } else if character.isWhitespace {
                if started { tokens.append(current); current = ""; started = false }
            } else if (character == "\"" || character == "'") && !started {
                quote = character
                started = true
            } else {
                current.append(character)
                started = true
            }
            index = next
        }
        guard quote == nil else {
            throw OrganizerCommandError(message: "Close the quoted project name, for example >file \"Client Alpha\".")
        }
        if started { tokens.append(current) }
        return tokens
    }
}

public struct OrganizerCommandError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) { self.message = message }
}

public struct OrganizerCommandDescriptor: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let query: String
    public let systemSymbol: String

    public init(id: String, title: String, subtitle: String, query: String, systemSymbol: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.query = query
        self.systemSymbol = systemSymbol
    }
}
