import Foundation
import Testing
import NamiCore

@Test func cleanupStringEnvelopePreservesDictatedQuotesAndNeverExtractsJSONFields() {
    #expect(CleanupOutput.removingStringEnvelope(#""We need two instances.""#, original: "we need two instances") == "We need two instances.")
    #expect(CleanupOutput.removingStringEnvelope(#""He said \"hello\".""#, original: "he said hello") == #"He said "hello"."#)
    let quoted = #""A quoted sentence.""#
    #expect(CleanupOutput.removingStringEnvelope(quoted, original: quoted) == quoted)
    let object = #"{"before":"raw","after":"cleaned"}"#
    #expect(CleanupOutput.removingStringEnvelope(object, original: "raw") == object)
    #expect(CleanupOutput.isFormatLeak(object, original: "raw"))
}
private struct FixedCleanupProcessor: TextProcessor {
    var identifier = "test"
    var output: String
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String { output }
}

@Test func cleanupRejectsSevereTruncationButAllowsNormalSelfCorrection() async throws {
    let original = "um can you check the Nami deployment I think I think we need two instances"
    let result = try await CleanupRunner(processor: FixedCleanupProcessor(output: "two instances"))
        .run(.init(rawText: original))
    #expect(result.outcome == .invalidOutput && result.text == original)
    #expect(result.reason?.contains("dropping too much text") == true)
    #expect(result.rejectedText == "two instances")
    #expect(result.withElapsedSeconds(1).rejectedText == "two instances")
    let correction = try await CleanupRunner(processor: FixedCleanupProcessor(output: "We need two instances."))
        .run(.init(rawText: "We need one, sorry, two instances."))
    #expect(correction.succeeded && correction.text == "We need two instances.")
}

@Test func cleanupRejectsLeakedExampleJSON() async throws {
    let original = "um can you check the name me deployment I think I think we need two instances"
    let leaked = #"{"before":"um can you check the name me deployment I think I think we need two instances","after":"Can you check the Nami deployment? I think we need two instances."}"#
    let result = try await CleanupRunner(processor: FixedCleanupProcessor(output: leaked))
        .run(.init(rawText: original))
    #expect(result.outcome == .invalidOutput)
    #expect(result.text == original)
    #expect(result.reason?.contains("response wrapper") == true)
    #expect(result.rejectedText == leaked)
}

@Test func cleanupRejectedResponsePersistsWithoutBreakingLegacyResults() async throws {
    let result = try await CleanupRunner(processor: FixedCleanupProcessor(output: "```text\nHello\n```"))
        .run(.init(rawText: "hello"))
    let data = try JSONEncoder().encode(result)
    let restored = try JSONDecoder().decode(CleanupResult.self, from: data)
    #expect(restored.rejectedText == result.rejectedText && restored.text == "hello")
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "rejectedText")
    let older = try JSONDecoder().decode(CleanupResult.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(older.rejectedText == nil && older.text == "hello")
}

@Test func cleanupAllowsOriginalJSONButExcludesContaminatedExamples() {
    #expect(!CleanupOutput.isFormatLeak(#"{"value":2}"#, original: #"{"value":1}"#))
    #expect(CleanupOutput.isFormatLeak("```json\n{}\n```", original: "Hello"))
    #expect(CleanupOutput.isFormatLeak("<think>Reasoning</think>Hello", original: "Hello"))
    var memory = CleanupMemory()
    memory.examples = [.init(rawText: "deployment example", generatedText: "deployment example",
        correctedText: #"{"before":"deployment example","after":"Deployment example."}"#)]
    let prompt = CleanupPrompt.input(.init(rawText: "deployment today", memory: memory))
    #expect(!prompt.contains("before"))
    #expect(!prompt.contains("after"))
    #expect(prompt.contains("deployment today"))
}

private actor SuspendedCleanupProcessor: TextProcessor {
    nonisolated let identifier = "uncooperative-test"
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var calls = 0
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String {
        calls += 1
        if calls > 1 { return "Recovered." }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: "Late response."); continuation = nil }
}

@Test func cleanupVocabularyUsesWholePhrasesLongestMatchAndSinglePass() {
    var memory = CleanupMemory()
    memory.vocabulary = [
        .init(heard: "name me", replacement: "Nami"),
        .init(heard: "name", replacement: "title"),
        .init(heard: "Nami", replacement: "Not cascaded"),
        .init(heard: "cafe", replacement: "café"),
        .init(heard: "dollar", replacement: "$1\\value"),
    ]
    #expect(memory.replacingVocabulary(in: "NAME ME, name, renamed, cafe, cafeteria, dollar.", language: "en")
        == "Nami, title, renamed, café, cafeteria, $1\\value.")
    #expect(memory.replacingVocabulary(in: "name me", language: "fr") == "name me")
    #expect(memory.replacingVocabulary(in: "écafe cafe\u{301} cafe_name", language: "en") == "écafe cafe\u{301} cafe_name")
}

@Test func cleanupMemoryRetrievalIsRelevantBoundedAndRemovable() {
    var memory = CleanupMemory()
    for index in 0..<5 {
        memory.examples.append(.init(rawText: "deployment project \(index)", generatedText: "generated",
                                     correctedText: "Deployment project \(index)."))
    }
    memory.examples.append(.init(rawText: "deployment", generatedText: "", correctedText: "Déploiement", language: "fr"))
    #expect(memory.relevantExamples(for: "the and you", language: "en").isEmpty)
    #expect(memory.relevantExamples(for: "lunch tomorrow", language: "en").isEmpty)
    let selected = memory.relevantExamples(for: "deployment project", language: "en")
    #expect(selected.count == 3)
    #expect(selected.allSatisfy { $0.language == "en" })
    #expect(memory.relevantExamples(for: "deployment", language: "en", maximumBytes: 1).isEmpty)
    let excluded = Set(selected.map(\.id))
    #expect(memory.relevantExamples(for: "deployment", language: "en", excluding: excluded).count == 2)
    memory.examples.removeAll { excluded.contains($0.id) }
    #expect(memory.relevantExamples(for: "deployment", language: "en").count == 2)
    #expect(memory.vocabulary.isEmpty) // Sentence feedback never creates replacement rules.
}

@Test func cleanupMemoryDoesNotRecallAnUnrelatedExampleFromGenericDictationWords() {
    var memory = CleanupMemory()
    let example = CleanupExample(
        rawText: "um can you check the name me deployment I think I think we need two instances",
        generatedText: "Can you check the deployment?",
        correctedText: "Can you check the Nami deployment? I think we need two instances.")
    memory.examples = [example]
    for transcript in [
        "I need the text model to learn how I record messages and improve grammar.",
        "I think we need to record messages and improve punctuation.",
    ] {
        #expect(memory.relevantExamples(for: transcript, language: "en").isEmpty)
        #expect(!CleanupPrompt.input(.init(rawText: transcript, memory: memory)).contains("Nami deployment"))
    }
    #expect(memory.relevantExamples(for: "can you check the name me deployment again", language: "en").map(\.id) == [example.id])
    #expect(memory.relevantExamples(for: example.rawText, language: "en").map(\.id) == [example.id])
}

@Test func cleanupPromptHighlightsTheUsersEditWithoutMakingAReplacementRule() {
    var memory = CleanupMemory()
    let raw = "um please update the minor version in the POM file"
    let generated = "Please update the minor version in the POM file."
    let corrected = "Please update the minor version in the “pom.xml” file."
    memory.examples = [.init(rawText: raw, generatedText: generated, correctedText: corrected)]
    let prompt = CleanupPrompt.input(.init(rawText: raw, memory: memory), highlightEdits: true)
    #expect(prompt.contains("Replace \"POM\" with \"“pom.xml”\" in the transcript."))
    #expect(!prompt.contains("Replace \"um")) // Do not learn edits the model made itself.
    #expect(!prompt.contains("Example dictation:"))
    #expect(CleanupPrompt.input(.init(rawText: raw, memory: memory)).contains("Example dictation:"))
    #expect(memory.vocabulary.isEmpty)
    for term in ["pom.xml", "POM.xml", "POM-file", "POMPOM", "other.POM"] {
        let request = CleanupRequest(rawText: "Please update the minor version in the \(term) file.", memory: memory)
        #expect(!memory.relevantExamples(for: request.rawText, language: "en").isEmpty)
        #expect(!CleanupPrompt.input(request, highlightEdits: true).contains("user-approved wording changes"))
    }
    for term in ["pom", "POM.", "“POM”"] {
        let request = CleanupRequest(rawText: "Please update the minor version in the file \(term)", memory: memory)
        #expect(CleanupPrompt.input(request, highlightEdits: true).contains(" with \"“pom.xml”\" in the transcript."))
    }
    let unrelated = CleanupPrompt.input(.init(rawText: "We need to record a new message today.", memory: memory), highlightEdits: true)
    #expect(!unrelated.contains("pom.xml"))
    memory.examples[0].correctedText = generated
    #expect(!CleanupPrompt.input(.init(rawText: raw, memory: memory), highlightEdits: true).contains("user-approved wording changes"))
    memory.examples[0].correctedText = "An entirely rewritten sentence with a different structure and several new words."
    #expect(!CleanupPrompt.input(.init(rawText: raw, memory: memory), highlightEdits: true).contains("user-approved wording changes"))
}

@Test func cleanupRunnerRejectsInvalidOutputAndRetainsOriginal() async throws {
    for output in ["", "   ", String(repeating: "x", count: 1_000)] {
        let runner = CleanupRunner(processor: FixedCleanupProcessor(output: output))
        let result = try await runner.run(.init(rawText: "Do not deploy."))
        #expect(result.outcome == .invalidOutput)
        #expect(result.text == "Do not deploy.")
        #expect(result.reason != nil)
    }
    let runner = CleanupRunner(processor: FixedCleanupProcessor(output: "Unexpected speech"))
    #expect(try await runner.run(.init(rawText: "  ")).text == "  ")
}

@Test func cleanupRunnerReportsCompletedOutputAndProfileRevision() async throws {
    var memory = CleanupMemory()
    memory.revision = 9
    let result = try await CleanupRunner(processor: FixedCleanupProcessor(output: "Hello."))
        .run(.init(rawText: "hello", memory: memory))
    #expect(result.outcome == .cleaned)
    #expect(result.rawText == "hello")
    #expect(result.text == "Hello.")
    #expect(result.memoryRevision == 9)
    #expect(result.preparationSeconds != nil)
}

@Test func cleanupDeadlineDoesNotWaitForUncooperativeProviderOrAccumulateWork() async throws {
    let processor = SuspendedCleanupProcessor()
    let runner = CleanupRunner(processor: processor)
    let request = CleanupRequest(rawText: "Original.")
    let result = try await runner.run(request, timeout: .milliseconds(30))
    #expect(result.outcome == .timedOut)
    #expect(result.text == request.rawText)
    #expect(result.elapsedSeconds < 1)
    #expect(try await runner.run(request).outcome == .busy)
    #expect(await processor.calls == 1)
    await processor.release()
    var recovered: CleanupResult?
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    repeat {
        try await Task.sleep(for: .milliseconds(5))
        recovered = try await runner.run(request)
    } while recovered?.outcome == .busy && .now < limit
    #expect(recovered?.text == "Recovered.")
    #expect(await processor.calls == 2)
}

@Test func cleanupCancellationReturnsWithoutWaitingAndRejectsLateResponse() async throws {
    let processor = SuspendedCleanupProcessor()
    let runner = CleanupRunner(processor: processor)
    let task = Task { try await runner.run(.init(rawText: "Original."), timeout: .seconds(10)) }
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while await processor.calls == 0 && .now < limit { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await processor.calls == 1)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await runner.run(.init(rawText: "Next.")).outcome == .busy)
    await processor.release()
}

private struct UnavailableCleanupProcessor: TextProcessor {
    let identifier = "unavailable-test"
    func prepare() async throws { throw CleanupFailure.unavailable("Not installed") }
    func process(_ request: CleanupRequest) async throws -> String { "Must not run" }
}

@Test func cleanupUnavailableFallsBackLocally() async throws {
    let result = try await CleanupRunner(processor: UnavailableCleanupProcessor()).run(.init(rawText: "Original."))
    #expect(result.outcome == .unavailable)
    #expect(result.text == "Original.")
    #expect(result.reason == "Not installed")
}
