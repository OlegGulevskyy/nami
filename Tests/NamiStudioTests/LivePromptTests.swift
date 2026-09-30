import Foundation
import Testing
import NamiCore
import NamiMLXCleanup
@testable import NamiStudio

private final class LivePromptBundleMarker: NSObject {}

/// Uses only installed local models, synthetic text, and temporary settings.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_LIVE_PROMPTS"] == "1"))
@MainActor func installedModelsUseEditedPromptsAndRecordActualMessages() async throws {
    _ = Bundle(for: LivePromptBundleMarker.self)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CleanupService()
    let store = PromptStore(directory: directory)
    service.promptStore = store
    let engines: [CleanupEngine] = QwenModel.allCases.filter { QwenModelAssets.isInstalled($0) }.map(\.engine)
    try #require(!engines.isEmpty, "No installed local models available for prompt verification")
    var config = PromptConfiguration()
    config[.qwenSystem] = "Fix capitalization and punctuation. Return only the edited sentence."
    config[.cleanupUser] = "Please edit: {{transcript}}"
    #expect(store.save(configuration: config, playgroundVocabulary: ""))
    for engine in engines {
        service.prewarm(engine)
        let request = CleanupRequest(rawText: "please check the deployment")
        let result = try await service.run(request, engine: engine, timeout: 30, source: "Synthetic prompt verification")
        print("LIVE PROMPTS \(engine.title): \(result.outcome) — \(result.text) \(result.reason ?? "")")
        #expect(result.succeeded)
        let record = try #require(store.records.first { $0.requestID == request.id })
        #expect(record.messages.first?.content == config[.qwenSystem])
        #expect(record.messages[1].content == "Please edit: \"please check the deployment\"")
    }
}
