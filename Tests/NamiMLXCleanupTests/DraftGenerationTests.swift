import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import NamiCore
@testable import NamiMLXCleanup

private final class DraftBundleMarker: NSObject {}

@Test func draftLookupCanRejoinAfterAnEdit() {
    #expect(DraftGeneration.continuation(after: [9, 3, 4], in: [1, 2, 3, 4, 5, 6], limit: 2) == [5, 6])
    #expect(DraftGeneration.continuation(after: [9], in: [1, 2, 3], limit: 4).isEmpty)
    #expect(DraftGeneration.continuation(after: [1, 2], in: [1, 2, 3], limit: 0).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_DRAFT_GENERATION"] == "1"))
func draftGenerationMatchesOrdinaryCleanup() async throws {
    _ = Bundle(for: DraftBundleMarker.self)
    let env = ProcessInfo.processInfo.environment
    let model = QwenModel.qwen17
    let folder = env["NAMI_TEST_DRAFT_MODEL_FOLDER"].map { URL(fileURLWithPath: $0) } ?? QwenModelAssets.directory(for: model)
    let container = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: folder))
    let fixture = try Data(contentsOf: URL(fileURLWithPath: try #require(env["NAMI_TEST_DRAFT_FIXTURE"])))
    let rows = try #require(JSONSerialization.jsonObject(with: fixture) as? [[String: Any]])
    let texts = rows.compactMap { $0["rawTranscript"] as? String }
    let system = try env["NAMI_TEST_DRAFT_SYSTEM_FILE"].map { try String(contentsOfFile: $0, encoding: .utf8) }
    let blockSize = Int(env["NAMI_TEST_DRAFT_BLOCK"] ?? "4") ?? 4
    let temperatures: [Float] = env["NAMI_TEST_DRAFT_GREEDY_ONLY"] == "1" ? [0] : [0, 2]
    let report = try await container.perform { context in
        var report: [[String: Any]] = []
        let promptCache = env["NAMI_TEST_DRAFT_PREFIX_CACHE"] == "1" ? DraftGeneration.PromptCache() : nil
        for raw in texts {
            var request = CleanupRequest(rawText: raw)
            if let system { request.prompts[.qwenSystem] = system }
            let input = try await context.processor.prepare(input: UserInput(messages: [
                ["role": "system", "content": request.prompts[.qwenSystem]],
                ["role": "user", "content": CleanupPrompt.input(request, highlightEdits: true)]
            ], additionalContext: ["enable_thinking": false]))
            for temperature in temperatures {
                for iteration in 0..<2 {
                    let parameters = GenerateParameters(maxTokens: 512, temperature: temperature)
                    let start = ContinuousClock.now
                    let iterator = try TokenIterator(input: input, model: context.model, processor: parameters.processor(), sampler: RepeatableSampler(temperature: temperature, seed: UInt64(42 + iteration)), maxTokens: 512)
                    let baseline = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (_: [Int]) in .more }
                    let baseTime = start.duration(to: .now)
                    let draftStart = ContinuousClock.now
                    let result = try DraftGeneration.generate(input: input, draft: context.tokenizer.encode(text: raw), parameters: parameters, context: context,
                        sampler: RepeatableSampler(temperature: temperature, seed: UInt64(42 + iteration)), blockSize: blockSize, promptCache: promptCache)
                    let draftTime = draftStart.duration(to: .now)
                    #expect(result.tokens == baseline.tokens, "Draft decoding changed seeded output: \(result.output)")
                    func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
                    report.append(["raw": raw, "temperature": temperature, "iteration": iteration, "baselineSeconds": seconds(baseTime), "draftSeconds": seconds(draftTime), "baseline": baseline.output, "draft": result.output])
                    print("Draft \(temperature): \(seconds(baseTime)) → \(seconds(draftTime)), equal \(result.output == baseline.output)")
                }
            }
        }
        return report
    }
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: try #require(env["NAMI_TEST_DRAFT_REPORT"])))
}

private struct RepeatableSampler: LogitSampler {
    let temperature: Float
    let state: MLXRandom.RandomState
    init(temperature: Float, seed: UInt64) { self.temperature = temperature; self.state = .init(seed: seed) }
    func sample(logits: MLXArray) -> MLXArray {
        temperature == 0 ? argMax(logits, axis: -1) : MLXRandom.categorical(logits / temperature, key: state)
    }
}
