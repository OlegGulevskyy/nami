import Foundation
import Testing
import NamiCore
@testable import NamiStudio

private actor PromptProbeProcessor: TextProcessor {
    nonisolated let identifier: String
    let unavailable: Bool
    var requests: [CleanupRequest] = []
    init(_ identifier: String, unavailable: Bool = false) { self.identifier = identifier; self.unavailable = unavailable }
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String {
        requests.append(request)
        await request.promptObserver?(.init(requestID: request.id, provider: identifier, messages: [
            .init(role: "system", content: request.prompts[identifier == "apple" ? .appleSystem : .qwenSystem]),
            .init(role: "user", content: CleanupPrompt.input(request)),
        ]))
        if unavailable { throw CleanupFailure.unavailable("Try fallback") }
        return request.rawText
    }
}

@Test @MainActor func promptEditsReachCleanupAndAutomaticFallbackAndHistorySurvivesReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let apple = PromptProbeProcessor("apple", unavailable: true)
    let qwen = PromptProbeProcessor("qwen")
    let service = CleanupService(processors: [.apple: apple, .qwen: qwen])
    let lab = DebuggingSession(directory: directory, cleanupService: service)
    let store = lab.promptStore
    var config = store.configuration
    config[.appleSystem] = "Apple custom instruction"
    config[.qwenSystem] = "Qwen custom instruction"
    config[.cleanupUser] = "Custom: {{transcript}}"
    #expect(store.save(configuration: config, playgroundVocabulary: "Nami, MLX"))
    let request = CleanupRequest(rawText: "hello there")
    let result = try await service.run(request, engine: .automatic, timeout: 2, source: "Live dictation")
    #expect(result.succeeded && result.provider == "qwen")
    #expect(await apple.requests.last?.prompts == config)
    #expect(await qwen.requests.last?.prompts == config)
    #expect(store.records.count == 2)
    #expect(store.records.allSatisfy { $0.requestID == request.id && $0.source == "Live dictation" })
    config[.qwenSystem] = "Changed later"
    #expect(store.save(configuration: config, playgroundVocabulary: "Nami"))
    let restored = PromptStore(directory: directory)
    #expect(restored.configuration == config)
    #expect(restored.playgroundVocabulary == "Nami")
    #expect(restored.records.first?.messages.first?.content == "Qwen custom instruction")
    #expect(restored.records.first?.messages.last?.content == "Custom: \"hello there\"")

    lab.cleanupLab.input = "playground sample"
    lab.cleanupLab.compare()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while lab.cleanupLab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!lab.cleanupLab.isBusy)
    #expect(store.records.first?.source == "Playground cleanup")
    #expect(await qwen.requests.last?.prompts[.qwenSystem] == "Changed later")
}

@Test @MainActor func promptStorePreservesCorruptAndConflictingPreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = PromptStore(directory: directory)
    let stale = PromptStore(directory: directory)
    #expect(first.save(configuration: .init(), playgroundVocabulary: "first"))
    #expect(!stale.save(configuration: .init(), playgroundVocabulary: "stale"))
    #expect(PromptStore(directory: directory).playgroundVocabulary == "first")
    let file = directory.appendingPathComponent("prompts.json")
    let corrupt = Data("invalid".utf8)
    try corrupt.write(to: file)
    let broken = PromptStore(directory: directory)
    #expect(broken.loadFailed)
    #expect(!broken.save(configuration: .init(), playgroundVocabulary: ""))
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test @MainActor func unavailableAndVocabularyOnlyCleanupDoNotClaimPromptsWereSent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CleanupService(modelsRoot: directory.appendingPathComponent("MissingModels"))
    let store = PromptStore(directory: directory)
    service.promptStore = store
    _ = try await service.run(.init(rawText: "hello"), engine: .qwen, timeout: 1)
    _ = try await service.run(.init(rawText: "hello"), engine: .vocabulary, timeout: 1)
    #expect(store.records.isEmpty)
}
