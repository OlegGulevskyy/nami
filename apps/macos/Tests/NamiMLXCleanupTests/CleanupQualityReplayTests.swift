import Foundation
import Testing
import NamiCore
import MLXLLM
import MLXLMCommon
@testable import NamiMLXCleanup

private final class CleanupReplayBundleMarker: NSObject {}

/// Local-only prompt evaluation against saved raw transcripts and held-out
/// correction examples. The fixture and reports remain outside source control.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_CLEANUP_REPLAY"] != nil))
func cleanupQualityReplay() async throws {
    _ = Bundle(for: CleanupReplayBundleMarker.self)
    let env = ProcessInfo.processInfo.environment
    let fixture = try Data(contentsOf: URL(fileURLWithPath: try #require(env["NAMI_TEST_CLEANUP_REPLAY"])))
    let rows = try #require(JSONSerialization.jsonObject(with: fixture) as? [[String: Any]])
    let settings = URL(fileURLWithPath: try #require(env["NAMI_TEST_DEBUG_SETTINGS"]))
    let config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings.appendingPathComponent("prompts.json"))) as? [String: Any])
    var prompts = try JSONDecoder().decode(PromptConfiguration.self, from: JSONSerialization.data(withJSONObject: try #require(config["cleanup"])))
    prompts.qwenGeneration.temperature = 0
    let workspace = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings.appendingPathComponent("Cleanup/workspace.json"))) as? [String: Any])
    let memory = try JSONDecoder().decode(CleanupMemory.self, from: JSONSerialization.data(withJSONObject: try #require(workspace["memory"])))
    let variantsPath = try #require(env["NAMI_TEST_CLEANUP_VARIANTS"])
    let variants = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: variantsPath))) as? [String])
    let processor: any TextProcessor
    if let path = env["NAMI_TEST_CLEANUP_MODEL_FOLDER"] {
        processor = CleanupReplayProcessor(folder: URL(fileURLWithPath: path), draft: env["NAMI_TEST_CLEANUP_DRAFT"] == "1",
            blockSize: Int(env["NAMI_TEST_CLEANUP_BLOCK"] ?? "4") ?? 4)
    } else { processor = QwenTextProcessor(model: .qwen17) }
    try await processor.prepare()
    let runner = CleanupRunner(processor: processor)
    var report: [[String: Any]] = []
    for (index, system) in variants.enumerated() {
        for row in rows {
            let raw = try #require(row["rawTranscript"] as? String)
            var request = CleanupRequest(rawText: raw, language: "auto", memory: memory)
            request.prompts = prompts
            if !system.isEmpty { request.prompts[.qwenSystem] = system }
            let result = try await runner.run(request, timeout: .seconds(10))
            await runner.cancelAndWait()
            report.append(["variant": index, "raw": raw, "text": result.text, "outcome": result.outcome.rawValue, "seconds": result.elapsedSeconds,
                           "rejected": result.rejectedText ?? "", "reason": result.reason ?? ""])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: try #require(env["NAMI_TEST_CLEANUP_REPORT"])), options: .atomic)
            print("Cleanup variant \(index): \(result.text)")
        }
    }
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: try #require(env["NAMI_TEST_CLEANUP_REPORT"])))
}

private actor CleanupReplayProcessor: TextProcessor {
    nonisolated let identifier = "local-cleanup-probe"
    let folder: URL
    let draft: Bool
    let blockSize: Int
    private let promptCache = DraftGeneration.PromptCache()
    private var container: ModelContainer?
    init(folder: URL, draft: Bool, blockSize: Int) { self.folder = folder; self.draft = draft; self.blockSize = blockSize }
    func prepare() async throws {
        if container == nil { container = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: folder)) }
    }
    func process(_ request: CleanupRequest) async throws -> String {
        try await prepare()
        let container = try #require(container)
        let draft = draft
        let promptCache = promptCache, blockSize = blockSize
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(messages: [
                ["role": "system", "content": request.prompts[.qwenSystem]],
                ["role": "user", "content": CleanupPrompt.input(request, highlightEdits: true)],
            ], additionalContext: ["enable_thinking": false]))
            let parameters = GenerateParameters(maxTokens: 512, temperature: 0)
            let result: GenerateResult
            if draft {
                result = try DraftGeneration.generate(input: input, draft: context.tokenizer.encode(text: request.rawText), parameters: parameters, context: context,
                    blockSize: blockSize, promptCache: promptCache)
            } else {
                result = try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { (_: [Int]) in Task.isCancelled ? .stop : .more }
            }
            try Task.checkCancellation()
            guard result.tokens.count < 512 else { throw CleanupFailure.outputLimitReached }
            return CleanupOutput.removingStringEnvelope(result.output, original: request.rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
