import Foundation
import Testing
@testable import NamiCore

private func temporaryStore() -> ActionStore {
    ActionStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("nami-actions-cli-" + UUID().uuidString).appendingPathComponent("actions.json"))
}

@Test func cliAddsListsUpdatesAndRemovesActions() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String {
        try ActionCommandLine.run(arguments, store: store, readInput: { "echo \"$HOME\" | pbcopy\n" })
    }

    #expect(try run("list") == "No actions.")
    #expect(try run("add", "--phrases", "open Excel repo, open Excel repository,",
                    "--open-url", "https://github.com/acme/excel-addin", "--with", "Google Chrome",
                    "--shortcut", "Focus").hasPrefix("Added "))
    let action = try #require(try store.load().actions.first)
    #expect(action.spokenPhrases == ["open Excel repo", "open Excel repository"])
    #expect(action.steps.map(\.kind) == [.openURL, .runShortcut])
    #expect(action.steps.first?.application == "Google Chrome")
    #expect(try run("try", "Open Excel repo.") == """
        Runs \(action.id.uuidString.prefix(8)): open Excel repo
          Open https://github.com/acme/excel-addin in Google Chrome
          Run shortcut Focus
        """)

    // Phrases or ID prefixes identify an action; new steps replace the old ones, and a command can come from standard input.
    #expect(try run("update", "Open Excel Repository", "--command", "-").hasPrefix("Updated "))
    #expect(try store.load().actions.first?.steps == [ActionStep(id: try #require(try store.load().actions.first?.steps.first?.id),
                                                                 kind: .runCommand, target: "echo \"$HOME\" | pbcopy")])
    _ = try run("update", String(action.id.uuidString.prefix(6)), "--phrases", "excel repo")
    #expect(try store.load().actions.first?.spokenPhrases == ["excel repo"])
    #expect(try store.load().actions.first?.steps.first?.kind == .runCommand)

    let listed = try JSONSerialization.jsonObject(with: Data(try run("list", "--json").utf8)) as? [[String: Any]]
    #expect(listed?.first?["id"] as? String == action.id.uuidString)
    #expect((listed?.first?["steps"] as? [[String: Any]])?.first?["kind"] as? String == "runCommand")

    #expect(try run("remove", "excel repo").hasPrefix("Removed "))
    #expect(try store.load().actions.isEmpty)
}

@Test func cliRejectsAmbiguousOrIncompleteActions() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String { try ActionCommandLine.run(arguments, store: store) }
    _ = try run("add", "--phrases", "open mail", "--open-app", "Mail")
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", "Open Mail!", "--open-app", "Mail") }
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", "open notes") }
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", " , ", "--open-app", "Notes") }
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", "open notes", "--open-app", " ") }
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", "open notes", "--open-app", "Notes", "--with", "Finder") }
    #expect(throws: ActionError.self) { _ = try run("add", "--phrases", "open notes", "--open-ur", "x") }
    #expect(throws: ActionError.self) { _ = try run("update", "missing", "--open-app", "Notes") }
    #expect(throws: ActionError.self) { _ = try run("update", "open mail") }
    #expect(throws: ActionError.self) { _ = try run("try", "open mail please") }
    #expect(try store.load().actions.count == 1)
}

@Test func cliTryFillsPlaceholdersAndReportsJSON() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String { try ActionCommandLine.run(arguments, store: store) }
    _ = try run("add", "--phrases", "search GitHub", "--open-url", "github.com/search?q={{query}}")
    let result = try JSONSerialization.jsonObject(with: Data(try run("try", "search GitHub for snippet store", "--json").utf8)) as? [String: Any]
    #expect(result?["matched"] as? Bool == true && result?["details"] as? String == "snippet store")
    #expect((result?["steps"] as? [[String: Any]])?.first?["target"] as? String == "https://github.com/search?q=snippet%20store")
    let missed = try JSONSerialization.jsonObject(with: Data(try run("try", "open the docs", "--json").utf8)) as? [String: Any]
    #expect(missed?["matched"] as? Bool == false)
}
