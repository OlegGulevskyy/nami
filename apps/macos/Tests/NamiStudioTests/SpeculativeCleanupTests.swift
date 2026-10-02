import Foundation
import Testing
import NamiCore
@testable import NamiStudio

private actor SpeculationProcessor: TextProcessor {
    nonisolated let identifier = "speculation-test"
    var calls: [String] = []
    var active = false
    private var permits = 0
    func release() { permits += 1 }
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String {
        #expect(!active)
        active = true; calls.append(request.rawText)
        defer { active = false }
        let record = ModelPromptRecord(requestID: request.id, provider: identifier,
            messages: [.init(role: "user", content: request.rawText)])
        await request.promptObserver?(record)
        while permits == 0 { try await Task.sleep(for: .milliseconds(1)) }
        permits -= 1
        await request.promptObserver?(record.responding(.init(output: "Clean: " + request.rawText, seconds: 0)))
        return "Clean: " + request.rawText
    }
}

private actor SpeculationRecords {
    var records: [ModelPromptRecord] = []
    func append(_ record: ModelPromptRecord) { records.append(record) }
}

@Test @MainActor func speculativeCleanupReusesOnlyTheExactFinalRequest() async throws {
    let processor = SpeculationProcessor()
    let records = SpeculationRecords()
    var request = CleanupRequest(rawText: "Keep every word.")
    request.promptObserver = { await records.append($0) }
    let speculative = SpeculativeCleanup(processor: processor, request: request, timeout: .seconds(10))
    speculative.offer(request.rawText)
    try await speculationWait { await processor.active }
    #expect(await records.records.isEmpty)
    speculative.offer(request.rawText)
    await processor.release()
    let result = try #require(try await speculative.finish(matching: request))
    #expect(result.rawText == request.rawText && result.text == "Clean: Keep every word.")
    #expect(result.id == request.id)
    #expect(await processor.calls == [request.rawText])
    #expect(await records.records.count == 1)
    #expect(await records.records.first?.response?.output == result.text)
    await speculative.cancel()
}

@Test @MainActor func speculativeCleanupDiscardsRevisionsAndJoinsBeforeFinalCleanup() async throws {
    for mismatch in ["text", "language", "memory", "prompts"] {
        let processor = SpeculationProcessor()
        let initial = CleanupRequest(rawText: "Schedule Monday.")
        let speculative = SpeculativeCleanup(processor: processor, request: initial, timeout: .seconds(10))
        speculative.offer(initial.rawText)
        try await speculationWait { await processor.active }
        var final = initial
        switch mismatch {
        case "text": final.rawText = "Schedule Tuesday."
        case "language": final.language = "auto"
        case "memory": final.memory.revision += 1
        default: final.prompts.qwenGeneration.temperature = 0.2
        }
        #expect(try await speculative.finish(matching: final) == nil)
        #expect(await processor.active == false)
        await processor.release()
        let result = try await CleanupRunner(processor: processor).run(final)
        #expect(result.succeeded && result.text == "Clean: " + final.rawText)
        #expect(await processor.calls == [initial.rawText, final.rawText])
    }
}

@Test @MainActor func speculativeCleanupCoalescesPendingTranscripts() async throws {
    let processor = SpeculationProcessor()
    var request = CleanupRequest(rawText: "First")
    let speculative = SpeculativeCleanup(processor: processor, request: request, timeout: .seconds(10))
    speculative.offer("First")
    try await speculationWait { await processor.active }
    speculative.offer("Second")
    speculative.offer("Third")
    await processor.release()
    try await speculationWait { await processor.calls.count == 2 }
    request.rawText = "Third"
    await processor.release()
    #expect(try await speculative.finish(matching: request)?.text == "Clean: Third")
    #expect(await processor.calls == ["First", "Third"])
}

@Test @MainActor func failedSpeculationNeverReplacesFinalCleanup() async throws {
    let processor = SpeculationProcessor()
    let request = CleanupRequest(rawText: "Complete thought")
    let speculative = SpeculativeCleanup(processor: processor, request: request, timeout: .milliseconds(1))
    speculative.offer(request.rawText)
    try await speculationWait { await processor.calls.count == 1 }
    #expect(try await speculative.finish(matching: request) == nil)
    #expect(await processor.active == false)
}

@Test @MainActor func stoppingRecordingPrioritizesTheLatestPreviewWithoutPublishingAnOlderOne() async throws {
    let processor = SpeculationProcessor()
    var request = CleanupRequest(rawText: "Earlier wording")
    let speculative = SpeculativeCleanup(processor: processor, request: request, timeout: .seconds(10))
    speculative.offer(request.rawText)
    try await speculationWait { await processor.active }
    speculative.offer("The complete final wording")
    #expect(await processor.calls == [request.rawText])
    speculative.recordingEnded()
    try await speculationWait { await processor.calls.count == 2 }
    speculative.offer("The revised final wording")
    try await speculationWait { await processor.calls.count == 3 }
    request.rawText = "The revised final wording"
    await processor.release()
    #expect(try await speculative.finish(matching: request)?.text == "Clean: The revised final wording")
    #expect(await processor.active == false)
}

@MainActor private func speculationWait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var satisfied = await predicate()
    while !satisfied, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
        satisfied = await predicate()
    }
    try #require(satisfied)
}
