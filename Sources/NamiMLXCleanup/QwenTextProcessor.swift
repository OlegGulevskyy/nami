import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import NamiCore

public actor QwenTextProcessor: TextProcessor {
    public nonisolated let identifier: String
    private let model: QwenModel
    private let directory: URL
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?

    public init(model: QwenModel = .qwen06, directory: URL? = nil) {
        self.model = model
        self.identifier = model.processorID
        self.directory = directory ?? QwenModelAssets.directory(for: model)
    }

    public func prepare() async throws {
        guard QwenModelAssets.isInstalled(model, at: directory) else {
            container = nil
            throw CleanupFailure.unavailable("Download \(model.engine.title) in Models first.")
        }
        if container != nil { return }
        if loading == nil {
            let folder = directory
            loading = Task {
                try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: folder))
            }
        }
        do {
            container = try await loading!.value
            loading = nil
        } catch { loading = nil; throw error }
        try Task.checkCancellation()
    }

    public func unload() async {
        loading?.cancel()
        if let loading { _ = try? await loading.value }
        loading = nil
        container = nil
        GPU.clearCache()
    }

    public func process(_ request: CleanupRequest) async throws -> String {
        guard request.language == "en" || request.language == "auto" else {
            throw CleanupFailure.unavailable("This cleanup experiment currently supports English dictation.")
        }
        guard request.rawText.utf8.count <= 8_000 else {
            throw CleanupFailure.unavailable("This dictation exceeds Qwen's current cleanup limit. Original text kept.")
        }
        try await prepare()
        guard let container else { throw CleanupFailure.unavailable("Qwen could not load.") }
        let identifier = self.identifier
        let settings = request.prompts.qwenGeneration.clamped
        return try await container.perform { context in
            try Task.checkCancellation()
            let messages = [
                ModelPromptMessage(role: "system", content: request.prompts[.qwenSystem]),
                ModelPromptMessage(role: "user", content: CleanupPrompt.input(request, highlightEdits: true)),
            ]
            let input = try await context.processor.prepare(input: UserInput(
                messages: messages.map { ["role": $0.role, "content": $0.content] },
                additionalContext: ["enable_thinking": settings.thinking]))
            let record = ModelPromptRecord(requestID: request.id, provider: identifier, messages: messages, details: settings.summary)
            await request.promptObserver?(record)
            try Task.checkCancellation()
            if settings.temperature > 0, let seed = settings.seed { MLXRandom.seed(seed) }
            // Keep iteration inside this operation until MLX really stops. This
            // lets CleanupRunner bound outstanding GPU work even after a timeout;
            // the stream convenience API finishes its consumer before its task joins.
            let parameters = GenerateParameters(maxTokens: settings.maxOutputTokens, temperature: Float(settings.temperature),
                topP: Float(settings.topP), repetitionPenalty: settings.repetitionPenalty.map(Float.init),
                repetitionContextSize: settings.repetitionContextSize)
            let started = ContinuousClock.now
            let result: GenerateResult
            do {
                result = try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { (_: [Int]) in
                    Task.isCancelled ? .stop : .more
                }
            } catch {
                await request.promptObserver?(record.responding(.init(output: "", error: error.localizedDescription,
                    seconds: started.secondsElapsed)))
                throw error
            }
            let limitReached = result.tokens.count >= settings.maxOutputTokens
            await request.promptObserver?(record.responding(.init(output: result.output,
                error: Task.isCancelled ? "Stopped early: cancelled or past the cleanup deadline."
                    : limitReached ? CleanupFailure.outputLimitReached.localizedDescription : nil,
                seconds: started.secondsElapsed, inputTokens: result.promptTokenCount, outputTokens: result.tokens.count,
                promptSeconds: result.promptTime, generationSeconds: result.generateTime)))
            try Task.checkCancellation()
            guard !limitReached else { throw CleanupFailure.outputLimitReached }
            let output = settings.thinking ? Self.removingReasoning(result.output) : result.output
            return CleanupOutput.removingStringEnvelope(output, original: request.rawText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Thinking output starts with a reasoning block. Drop only a complete one;
    /// an unfinished block stays so the format check rejects it.
    static func removingReasoning(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<think>"), let end = text.range(of: "</think>") else { return output }
        return String(text[end.upperBound...])
    }
}
