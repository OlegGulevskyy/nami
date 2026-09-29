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
        return try await container.perform { context in
            try Task.checkCancellation()
            let messages = [
                ModelPromptMessage(role: "system", content: request.prompts[.qwenSystem]),
                ModelPromptMessage(role: "user", content: CleanupPrompt.input(request, highlightEdits: true)),
            ]
            let input = try await context.processor.prepare(input: UserInput(
                messages: messages.map { ["role": $0.role, "content": $0.content] },
                additionalContext: ["enable_thinking": false]))
            await request.promptObserver?(.init(requestID: request.id, provider: identifier,
                messages: messages, details: "Thinking disabled · temperature 0 · maximum 2,048 output tokens"))
            try Task.checkCancellation()
            // Keep iteration inside this operation until MLX really stops. This
            // lets CleanupRunner bound outstanding GPU work even after a timeout;
            // the stream convenience API finishes its consumer before its task joins.
            let result = try MLXLMCommon.generate(input: input,
                parameters: GenerateParameters(maxTokens: 2_048, temperature: 0), context: context) { (_: [Int]) in
                    Task.isCancelled ? .stop : .more
                }
            try Task.checkCancellation()
            guard result.tokens.count < 2_048 else { throw CleanupFailure.outputLimitReached }
            return CleanupOutput.removingStringEnvelope(result.output, original: request.rawText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
