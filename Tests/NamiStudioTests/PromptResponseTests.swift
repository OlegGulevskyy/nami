import Foundation
import Testing
import NamiCore
@testable import NamiStudio

private struct RespondingProcessor: TextProcessor {
    let identifier = "qwen"
    var output = "Hello there."
    var delay: Duration = .zero
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String {
        let record = ModelPromptRecord(requestID: request.id, provider: identifier, messages: [.init(role: "user", content: request.rawText)])
        await request.promptObserver?(record)
        // Ignore cancellation, like an SDK that finishes after the deadline.
        if delay > .zero { try? await Task.sleep(for: delay) }
        await request.promptObserver?(record.responding(.init(output: output, seconds: 0.25, inputTokens: 40, outputTokens: 5,
            promptSeconds: 0.05, generationSeconds: 0.2)))
        return output
    }
}

@Test @MainActor func responseAndOutcomeAreAttachedToTheSentRequest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CleanupService(processors: [.qwen: RespondingProcessor()])
    let store = PromptStore(directory: directory)
    service.promptStore = store
    let result = try await service.run(CleanupRequest(rawText: "hello there"), engine: .qwen, timeout: 2)
    #expect(result.outcome == .cleaned)
    #expect(store.records.count == 1)
    let record = try #require(store.records.first)
    #expect(record.response?.output == "Hello there.")
    #expect(record.response?.outputTokensPerSecond == 25)
    #expect(record.outcome?.outcome == "cleaned" && record.outcome?.text == "Hello there.")
    #expect(PromptsView.status(record).hasPrefix("cleaned · "))
    #expect(PromptsView.stats(record).contains { $0 == ("Output speed", "25.0 tok/s") })

    let restored = PromptStore(directory: directory)
    #expect(restored.records.first?.response == record.response)
    #expect(restored.records.first?.outcome == record.outcome)
}

@Test @MainActor func lateResponseKeepsTheDeadlineOutcome() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CleanupService(processors: [.qwen: RespondingProcessor(delay: .milliseconds(300))])
    let store = PromptStore(directory: directory)
    service.promptStore = store
    let result = try await service.run(CleanupRequest(rawText: "hello there"), engine: .qwen, timeout: 0.05)
    #expect(result.outcome == .timedOut)
    #expect(store.records.first?.outcome?.outcome == "timedOut")
    #expect(store.records.first?.response == nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while store.records.first?.response == nil && .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.records.count == 1)
    #expect(store.records.first?.response?.output == "Hello there.")
    #expect(store.records.first?.outcome?.outcome == "timedOut")
}

@Test @MainActor func historyWithoutResponsesStillLoads() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = """
    [{"id":"\(UUID().uuidString)","date":0,"requestID":"\(UUID().uuidString)","source":"Live dictation",
      "provider":"qwen","messages":[{"role":"user","content":"hi"}],"details":""}]
    """
    try Data(legacy.utf8).write(to: directory.appendingPathComponent("prompt-history.json"))
    let store = PromptStore(directory: directory)
    #expect(store.records.count == 1)
    #expect(store.records.first?.response == nil)
    #expect(PromptsView.status(store.records[0]) == "no response")
}
