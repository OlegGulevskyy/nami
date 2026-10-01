import Foundation
import Testing
@testable import NamiCore

private let freeEnvironment = Snippet(phrases: "Free environment, free env, request a free environment",
                                      template: "Hey @gptqa, is there a free environment to deploy {{app1, app2, app3}}")

@Test(arguments: [
    ("free env snippet for excel addin, users api", "excel addin, users api"),
    ("Find a free environment snippet for Excel add-in.", "Excel add-in"),
    ("Snippet: free environment for Excel add-in and Users API.", "Excel add-in, Users API"),
    ("Free env for Excel add-in, Users API snippet", "Excel add-in, Users API"),
    ("Request a free environment snippet with the Excel add-in, the Users API, and Billing.", "the Excel add-in, the Users API, Billing"),
])
func snippetFillsPlaceholderWithEverySpokenValue(transcript: String, apps: String) throws {
    let library = SnippetLibrary(snippets: [freeEnvironment])
    let expansion = try #require(library.expand(transcript))
    #expect(expansion.snippet == freeEnvironment)
    #expect(expansion.text == "Hey @gptqa, is there a free environment to deploy \(apps)")
}

@Test func snippetsNeedTheTriggerWordAndAMatchingPhrase() {
    let library = SnippetLibrary(snippets: [freeEnvironment])
    #expect(library.expand("Is there a free environment for the Excel add-in?") == nil)
    #expect(!library.mentionsTrigger("Is there a free environment for the Excel add-in?"))
    #expect(library.expand("Snippet for the standup notes") == nil)
    #expect(library.mentionsTrigger("Snippet for the standup notes"))
    // Whole words only.
    #expect(library.expand("free env snippets for excel") == nil)
    #expect(SnippetLibrary(triggerWord: "  ", snippets: [freeEnvironment]).expand("free env snippet for excel") == nil)
}

@Test func customTriggerPhraseIsMatchedIgnoringCaseAndPunctuation() throws {
    let library = SnippetLibrary(triggerWord: "Quick Text", snippets: [freeEnvironment])
    #expect(library.expand("free env snippet for excel") == nil)
    let expansion = try #require(library.expand("Quick, text: free env for Excel."))
    #expect(expansion.values == ["Excel"])
}

@Test func longestPhraseWinsAcrossSnippets() throws {
    let deploy = Snippet(phrases: "deploy, free env deploy", template: "Deploying {{apps}} now")
    let library = SnippetLibrary(snippets: [freeEnvironment, deploy])
    #expect(try #require(library.expand("free env deploy snippet for billing")).text == "Deploying billing now")
    #expect(try #require(library.expand("free env snippet for billing")).snippet == freeEnvironment)
}

@Test func missingDetailsLeavePlaceholdersVisible() throws {
    let library = SnippetLibrary(snippets: [freeEnvironment])
    let expansion = try #require(library.expand("Free env snippet."))
    #expect(expansion.values.isEmpty)
    #expect(expansion.text == freeEnvironment.template)
}

@Test func severalPlaceholdersFillInOrderAndLastTakesTheRest() {
    let template = "Deploy {{app}} to {{env}}, then ping {{app}}'s owners about {{notes}}."
    #expect(SnippetLibrary.fill(template, with: ["Billing", "staging", "cache", "retries"])
        == "Deploy Billing to staging, then ping Billing's owners about cache, retries.")
    #expect(SnippetLibrary.fill(template, with: ["Billing"]) == "Deploy Billing to {{env}}, then ping Billing's owners about {{notes}}.")
    #expect(SnippetLibrary.fill("No placeholders", with: ["ignored"]) == "No placeholders")
}

@Test func libraryRoundTripsThroughJSON() throws {
    let library = SnippetLibrary(triggerWord: "shortcut", snippets: [freeEnvironment])
    let decoded = try JSONDecoder().decode(SnippetLibrary.self, from: JSONEncoder().encode(library))
    #expect(decoded == library)
}

@Test(arguments: [
    ("Free env snippet for Excel add-in and Users API.", "Excel add-in, Users API"),
    ("Сниппет свободное окружение для Excel и Users API.", "Excel, Users API"),
    ("Свободное окружение, сниппет: биллинг плюс отчёты", "биллинг, отчёты"),
    // Mixed: Whisper often keeps English names in a Russian sentence.
    ("Сниппет free env для Excel add-in", "Excel add-in"),
])
func snippetsWorkInEachLanguageWithOneTriggerWordPerLanguage(transcript: String, apps: String) throws {
    let library = SnippetLibrary(triggerWord: "snippet, сниппет",
                                 snippets: [Snippet(phrases: "free env, свободное окружение", template: "Deploy {{apps}}")])
    #expect(library.triggerWords == ["snippet", "сниппет"])
    #expect(try #require(library.expand(transcript)).text == "Deploy \(apps)")
}

@Test func russianMatchingIgnoresCaseAndTheDotsOnYo() throws {
    let library = SnippetLibrary(triggerWord: "сниппет", snippets: [Snippet(phrases: "ещё раз", template: "Again")])
    #expect(try #require(library.expand("СНИППЕТ еще раз")).text == "Again")
    #expect(library.mentionsTrigger("Сниппет для стендапа") && library.expand("Сниппет для стендапа") == nil)
    #expect(SnippetLibrary(triggerWord: "сниппет").mentionsTrigger("snippet") == false)
}
