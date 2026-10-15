import Testing
@testable import DigUpKit

@Suite struct OrganizerCommandTests {
    @Test func ordinarySearchQueriesAndPathsAreNotCommands() {
        for query in ["", "invoice", "project > 2025", "/Users/me/Downloads", "/sort", "／sort", "＞sort", "find >sort"] {
            #expect(OrganizerCommand.parse(query) == nil)
            #expect(OrganizerCommand.suggestions(for: query).isEmpty)
        }
    }

    @Test func prefixShowsHelpAndCommandWhitespaceIsFlexible() throws {
        #expect(try parsed(">") == .help)
        #expect(try parsed(" \t > \n") == .help)
        #expect(try parsed(" > \tHeLP \n") == .help)
        #expect(try parsed(">  AUTO\ton") == .automaticFiling(true))
        #expect(try parsed(">folders OFF") == .createProjectFolders(false))
        #expect(try parsed(">projects") == .projects(query: nil))
        #expect(try parsed(">projects \"\"") == .projects(query: nil))
    }

    @Test func completeCommandsResolveToTypedActions() throws {
        let examples: [(String, OrganizerCommand)] = [
            (">organize", .organize), (">sort", .sort), (">preview", .preview),
            (">review", .review), (">history", .history), (">undo", .undo(id: nil)),
            (">auto off", .automaticFiling(false)), (">folders on", .createProjectFolders(true)),
            (">pause", .pause), (">resume", .resume), (">settings", .settings),
        ]
        for (query, expected) in examples { #expect(try parsed(query) == expected) }
    }

    @Test func projectNamesPreserveUnicodeAndQuotedSpaces() throws {
        #expect(try parsed(">file Client Alpha") == .file(project: "Client Alpha"))
        #expect(try parsed(">file \"Client  Alpha\"") == .file(project: "Client  Alpha"))
        #expect(try parsed(">file 'Client Alpha'") == .file(project: "Client Alpha"))
        #expect(try parsed(">projects \"Żółć — 東京 🐈\"") == .projects(query: "Żółć — 東京 🐈"))
        #expect(try parsed(">file O'Reilly Notes") == .file(project: "O'Reilly Notes"))
        #expect(try parsed(#">file "Client \"Alpha\"""#) == .file(project: "Client \"Alpha\""))
        #expect(try parsed(#">file Client\ Alpha"#) == .file(project: "Client Alpha"))
        #expect(try parsed(#">file Plans\2026"#) == .file(project: #"Plans\2026"#))
        #expect(try parsed(">file 1234-abcd") == .file(project: "1234-abcd"))
    }

    @Test func undoAcceptsOnlyOnePositiveDecimalMoveID() throws {
        #expect(try parsed(">undo 1") == .undo(id: 1))
        #expect(try parsed(">undo 00021") == .undo(id: 21))
        #expect(try parsed(">undo 9223372036854775807") == .undo(id: Int64.max))
        for query in [">undo 0", ">undo -1", ">undo +1", ">undo 1.5", ">undo 1 2", ">undo latest", ">undo 9223372036854775808", ">undo ١", ">undo \"\""] {
            #expect(error(query)?.message.contains("positive move ID") == true)
        }
    }

    @Test func invalidArgumentsHaveActionableErrors() {
        for query in [">auto", ">auto yes", ">auto on now", ">folders", ">folders yes", ">folders on off"] {
            #expect(error(query)?.message.contains(" on or ") == true)
        }
        for query in [">sort now", ">help file", ">organize please", ">preview yes", ">pause 1", ">resume now", ">history 1", ">review Client", ">settings general"] {
            #expect(error(query)?.message.contains("does not take arguments") == true)
        }
        for query in [">file", ">file \"\"", ">file \"   \""] {
            #expect(error(query)?.message.contains("Add a project name or ID") == true)
        }
        #expect(error(">frobnicate")?.message.contains(">help") == true)
        #expect(error(">file \"Client Alpha")?.message.contains("Close the quoted") == true)
        #expect(error(">projects 'Client Alpha")?.message.contains("Close the quoted") == true)
    }

    @Test func shellCharactersRemainProjectTextOrInvalidCommands() throws {
        #expect(try parsed(">file $(touch /tmp/nope)") == .file(project: "$(touch /tmp/nope)"))
        #expect(try parsed(">file Client; rm -rf /tmp/nope") == .file(project: "Client; rm -rf /tmp/nope"))
        #expect(error(">sort; echo hi") != nil)
        #expect(error(">sort && pause") != nil)
        #expect(error(">sort\n>undo") != nil)
    }

    @Test func completionsFollowTheCommandAndFixedArgumentPrefix() {
        #expect(OrganizerCommand.suggestions(for: ">").map(\.id) == OrganizerCommand.catalog.map(\.id))
        #expect(OrganizerCommand.suggestions(for: ">p").map(\.id) == ["preview", "projects", "pause"])
        #expect(OrganizerCommand.suggestions(for: " > Au ").map(\.id) == ["auto-on", "auto-off"])
        #expect(OrganizerCommand.suggestions(for: ">auto o").map(\.query) == [">auto on", ">auto off"])
        #expect(OrganizerCommand.suggestions(for: ">folders of").map(\.id) == ["folders-off"])
        #expect(OrganizerCommand.suggestions(for: ">file Client").isEmpty)
        #expect(OrganizerCommand.suggestions(for: ">unknown").isEmpty)
    }

    @Test func catalogIsStableAndEveryExampleIsRecognized() {
        #expect(Set(OrganizerCommand.catalog.map(\.id)).count == OrganizerCommand.catalog.count)
        for item in OrganizerCommand.catalog {
            #expect(!item.title.isEmpty && !item.subtitle.isEmpty && !item.systemSymbol.isEmpty)
            if item.id == "file" {
                #expect(error(item.query)?.message.contains("project name") == true)
            } else {
                guard case .success? = OrganizerCommand.parse(item.query) else {
                    Issue.record("Catalog command did not parse: \(item.query)")
                    continue
                }
            }
        }
    }

    private func parsed(_ text: String) throws -> OrganizerCommand {
        guard let result = OrganizerCommand.parse(text) else {
            throw OrganizerCommandError(message: "Expected a command: \(text)")
        }
        return try result.get()
    }

    private func error(_ text: String) -> OrganizerCommandError? {
        guard case .failure(let error)? = OrganizerCommand.parse(text) else { return nil }
        return error
    }
}
