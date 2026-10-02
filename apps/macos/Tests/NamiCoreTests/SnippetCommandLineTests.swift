import Foundation
import Testing
@testable import NamiCore

private func temporaryStore() -> SnippetStore {
    SnippetStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("nami-snippets-cli-" + UUID().uuidString).appendingPathComponent("snippets.json"))
}

@Test func cliAddsListsUpdatesAndRemovesSnippets() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String { try SnippetCommandLine.run(arguments, store: store, readInput: { "Line one\nLine {{two}}\n" }) }

    #expect(try run("list") == "Trigger word: snippet\nNo snippets.")
    #expect(try run("add", "--phrases", "free env, free environment,", "--text", "Deploy {{apps}}").hasPrefix("Added "))
    let snippet = try #require(try store.load().snippets.first)
    #expect(snippet.spokenPhrases == ["free env", "free environment"])
    #expect(try run("try", "free env snippet for Excel add-in, Users API") == "Deploy Excel add-in, Users API")

    // Phrases or ID prefixes identify a snippet; text can come from standard input.
    #expect(try run("update", "Free Environment", "--text", "-").hasPrefix("Updated "))
    #expect(try store.load().snippets.first?.template == "Line one\nLine {{two}}")
    _ = try run("update", String(snippet.id.uuidString.prefix(6)), "--phrases", "env please")
    #expect(try store.load().snippets.first?.spokenPhrases == ["env please"])

    let listed = try JSONSerialization.jsonObject(with: Data(try run("list", "--json").utf8)) as? [String: Any]
    #expect(listed?["triggerWord"] as? String == "snippet")
    #expect((listed?["snippets"] as? [[String: Any]])?.first?["id"] as? String == snippet.id.uuidString)

    #expect(try run("remove", "env please").hasPrefix("Removed "))
    #expect(try store.load().snippets.isEmpty)
}

@Test func cliRejectsAmbiguousOrIncompleteChanges() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String { try SnippetCommandLine.run(arguments, store: store) }
    _ = try run("add", "--phrases", "my email", "--text", "me@example.com")
    #expect(throws: SnippetError.self) { _ = try run("add", "--phrases", "My email?", "--text", "x") }
    #expect(throws: SnippetError.self) { _ = try run("add", "--phrases", " , ", "--text", "x") }
    #expect(throws: SnippetError.self) { _ = try run("add", "--phrases", "other") }
    #expect(throws: SnippetError.self) { _ = try run("update", "missing", "--text", "x") }
    #expect(throws: SnippetError.self) { _ = try run("update", "my email") }
    #expect(throws: SnippetError.self) { _ = try run("add", "--phrase", "typo") }
    #expect(throws: SnippetError.self) { _ = try run("try", "my email please") }
    #expect(try store.load().snippets.count == 1)
}

@Test func cliSetsTriggerWordAndReportsTryAsJSON() throws {
    let store = temporaryStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    func run(_ arguments: String...) throws -> String { try SnippetCommandLine.run(arguments, store: store) }
    _ = try run("add", "--phrases", "sign off", "--text", "Thanks, {{name}}")
    #expect(try run("trigger", "quick text") == "Trigger word: quick text")
    #expect(try run("trigger") == "quick text")
    let result = try JSONSerialization.jsonObject(with: Data(try run("try", "quick text sign off for Oleg", "--json").utf8)) as? [String: Any]
    #expect(result?["matched"] as? Bool == true && result?["text"] as? String == "Thanks, Oleg")
    #expect(try run("trigger", "snippet,  сниппет ,") == "Trigger words: snippet, сниппет")
    #expect(try run("trigger") == "snippet, сниппет")
    #expect(try run("try", "Сниппет sign off для Олега") == "Thanks, Олега")
    #expect(try run("list").hasPrefix("Trigger words: snippet, сниппет\n"))
    #expect(try run("trigger", "") == "Snippets are off.")
    #expect(try run("trigger") == "(off)")
}
