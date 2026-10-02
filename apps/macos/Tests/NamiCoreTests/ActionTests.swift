import Foundation
import Testing
@testable import NamiCore

private let excelRepo = VoiceAction(phrases: "Open Excel repository, open Excel repo",
                                    steps: [ActionStep(kind: .openURL, target: "https://github.com/acme/excel-addin", application: "Google Chrome")])
private let searchGitHub = VoiceAction(phrases: "search GitHub",
                                       steps: [ActionStep(kind: .openURL, target: "github.com/search?q={{query}}&type=code")])

@Test(arguments: ["Open Excel repo.", "open excel repository", "Open, Excel Repo!", "Ópen Excel repo"])
func actionRunsWhenTheRecordingIsItsPhrase(transcript: String) throws {
    let match = try #require(ActionLibrary(actions: [excelRepo]).match(transcript))
    #expect(match.action == excelRepo && match.details.isEmpty)
    #expect(match.steps == excelRepo.steps)
}

@Test func dictationThatOnlyMentionsThePhraseIsPastedAsUsual() {
    let library = ActionLibrary(actions: [excelRepo])
    #expect(library.match("Open Excel repo and check the failing tests") == nil)
    #expect(library.match("Please open Excel repo") == nil)
    #expect(library.match("Open Excel") == nil)
    #expect(library.match("") == nil)
}

@Test func detailsFillPlaceholdersEscapedForTheStep() throws {
    let command = VoiceAction(phrases: "note", steps: [ActionStep(kind: .runCommand, target: "echo {{text}} >> ~/notes.txt")])
    let library = ActionLibrary(actions: [searchGitHub, command])
    let search = try #require(library.match("Search GitHub for snippet store & locks."))
    #expect(search.details == "snippet store & locks")
    #expect(search.steps.first?.target == "https://github.com/search?q=snippet%20store%20%26%20locks&type=code")
    // Placeholder actions also run without details.
    #expect(try #require(library.match("search github")).steps.first?.target == "https://github.com/search?q=&type=code")
    let note = try #require(library.match("Note: it's done"))
    #expect(note.steps.first?.target == "echo 'it'\\''s done' >> ~/notes.txt")
}

@Test func longestPhraseWinsAndIncompleteActionsNeverRun() throws {
    let repo = VoiceAction(phrases: "open repo, open Excel repo", steps: [ActionStep(kind: .openApp, target: "GitHub Desktop")])
    let library = ActionLibrary(actions: [repo, excelRepo])
    #expect(try #require(library.match("open excel repository")).action == excelRepo)
    #expect(try #require(library.match("open repo")).action == repo)
    #expect(try #require(library.match("open excel repo")).action == repo)
    let empty = VoiceAction(phrases: "open mail", steps: [ActionStep(kind: .openApp, target: " ")])
    #expect(!empty.isValid && ActionLibrary(actions: [empty]).match("open mail") == nil)
}

@Test func actionStoreRoundTripsAndNeverOverwritesADamagedFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nami-actions-\(UUID().uuidString)/actions.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ActionStore(url: url)
    #expect(try store.load() == ActionLibrary())
    let library = ActionLibrary(actions: [excelRepo, searchGitHub])
    try store.save(library)
    #expect(try store.load() == library)
    try Data("not json".utf8).write(to: url)
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func actionsMatchPhrasesInEachLanguage() throws {
    let repo = VoiceAction(phrases: "open Excel repo, открой репозиторий Excel, открой репозиторий эксель",
                           steps: [ActionStep(kind: .openURL, target: "https://github.com/acme/excel-addin")])
    let search = VoiceAction(phrases: "search GitHub, поищи на GitHub",
                             steps: [ActionStep(kind: .openURL, target: "github.com/search?q={{query}}")])
    let library = ActionLibrary(actions: [repo, search])
    #expect(try #require(library.match("Открой репозиторий Excel.")).action == repo)
    #expect(try #require(library.match("открой репозиторий Эксель")).action == repo)
    #expect(library.match("Открой репозиторий Excel и запусти тесты") == nil)
    let found = try #require(library.match("Поищи на GitHub про сниппеты."))
    #expect(found.details == "сниппеты")
    #expect(found.steps.first?.target == "https://github.com/search?q=%D1%81%D0%BD%D0%B8%D0%BF%D0%BF%D0%B5%D1%82%D1%8B")
}
