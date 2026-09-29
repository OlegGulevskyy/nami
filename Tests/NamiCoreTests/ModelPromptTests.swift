import Foundation
import Testing
import NamiCore

@Test func defaultPromptRenderingPreservesExistingCleanup() {
    let request = CleanupRequest(rawText: "um hello")
    #expect(CleanupPrompt.input(request) == "Edit this transcript only:\n\"um hello\"\nReturn the corrected sentence as plain text.")
    #expect(CleanupPrompt.input(request, highlightEdits: true) == CleanupPrompt.input(request))
}

@Test func promptTemplatesDoNotInterpretTokensInsideTranscriptData() {
    var request = CleanupRequest(rawText: "😀 {{context}} {{language}} \"hello\"")
    request.prompts[.cleanupUser] = "{{language}}: {{transcript}} {{context}}"
    #expect(CleanupPrompt.input(request) == "en: \"😀 {{context}} {{language}} \\\"hello\\\"\" ")
    #expect(PromptConfiguration.render("{{raw}} {{corrected}}", values: ["raw": "{{corrected}}", "corrected": "done"]) == "{{corrected}} done")
}

@Test func promptConfigurationRoundTripsEmptyOverridesAndResets() throws {
    var configuration = PromptConfiguration()
    configuration[.qwenSystem] = ""
    configuration[.cleanupUser] = "{{transcript}}"
    let restored = try JSONDecoder().decode(PromptConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(restored[.qwenSystem].isEmpty)
    #expect(restored[.appleSystem] == CleanupPrompt.instructions)
    configuration[.qwenSystem] = PromptField.qwenSystem.defaultText
    #expect(configuration[.qwenSystem] == PromptField.qwenSystem.defaultText)
}

@Test func savedCorrectionPromptComponentsAreEditable() {
    var memory = CleanupMemory()
    memory.examples = [.init(rawText: "Update the POM file", generatedText: "Update the POM file", correctedText: "Update the pom.xml file")]
    var request = CleanupRequest(rawText: "Update the POM file", memory: memory)
    request.prompts[.example] = "BEFORE {{raw}} AFTER {{corrected}}"
    request.prompts[.editsHeading] = "Saved edits:"
    request.prompts[.savedEdit] = "{{source}} → {{replacement}}"
    #expect(CleanupPrompt.input(request).contains("BEFORE \"Update the POM file\" AFTER \"Update the pom.xml file\""))
    let qwen = CleanupPrompt.input(request, highlightEdits: true)
    #expect(qwen.contains("Saved edits:\n\"POM\" → \"pom.xml\""))
    #expect(!qwen.contains("BEFORE"))
}
