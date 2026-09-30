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

@Test func generationSettingsDecodeLegacyPromptsAndDescribeDefaults() throws {
    let legacy = #"{"overrides":{"qwenSystem":"Custom"}}"#
    let configuration = try JSONDecoder().decode(PromptConfiguration.self, from: Data(legacy.utf8))
    #expect(configuration[.qwenSystem] == "Custom")
    #expect(configuration.qwenGeneration == QwenGenerationSettings())
    #expect(configuration.appleGeneration == AppleGenerationSettings())
    #expect(configuration.qwenGeneration.summary == "Thinking disabled · temperature 0 · maximum 2,048 output tokens")
    #expect(configuration.appleGeneration.summary == "greedy · maximum 2,048 output tokens")
}

@Test func generationSettingsRoundTripAndClampOutOfRangeValues() throws {
    var configuration = PromptConfiguration()
    configuration.qwenGeneration.temperature = 0.7
    configuration.qwenGeneration.topP = 0.9
    configuration.qwenGeneration.seed = 7
    configuration.qwenGeneration.repetitionPenalty = 1.1
    configuration.appleGeneration.sampling = .topK
    configuration.appleGeneration.temperature = 0.5
    let restored = try JSONDecoder().decode(PromptConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(restored == configuration)
    #expect(restored.qwenGeneration.summary
        == "Thinking disabled · temperature 0.7 · top-p 0.9 · seed 7 · repetition penalty 1.1 over 20 tokens · maximum 2,048 output tokens")
    #expect(restored.appleGeneration.summary == "top-k 40 · temperature 0.5 · random seed · maximum 2,048 output tokens")

    let invalid = #"{"temperature":9,"topP":0,"maxOutputTokens":1,"repetitionPenalty":0.2,"repetitionContextSize":0}"#
    let qwen = try JSONDecoder().decode(QwenGenerationSettings.self, from: Data(invalid.utf8))
    #expect(qwen.temperature == 2 && qwen.topP == 0.01 && qwen.maxOutputTokens == 16)
    #expect(qwen.repetitionPenalty == 1 && qwen.repetitionContextSize == 1)
    let apple = try JSONDecoder().decode(AppleGenerationSettings.self, from: Data(#"{"topK":0,"maximumTokens":5}"#.utf8))
    #expect(apple.topK == 1 && apple.maxOutputTokens == 2_048)
}
