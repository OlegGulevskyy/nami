import Foundation
import NamiCore
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleCleanup {
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings, or choose Qwen."
            case .unavailable(.deviceNotEligible): return "Apple Intelligence is not supported on this Mac. Choose Qwen."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still preparing its model."
            @unknown default: return "Apple Intelligence is unavailable. Choose Qwen."
            }
        }
        #endif
        return "Requires macOS 26 and Apple Intelligence. Qwen runs independently."
    }
    public static func makeProcessor() -> any TextProcessor {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleTextProcessor() }
        #endif
        return UnavailableAppleProcessor()
    }
}

private struct UnavailableAppleProcessor: TextProcessor {
    let identifier = "apple-system-cleanup-v2"
    func prepare() async throws {
        throw CleanupFailure.unavailable("Apple text cleanup requires macOS 26 or later and Apple Intelligence.")
    }
    func process(_ request: CleanupRequest) async throws -> String { try await prepare(); return request.rawText }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private actor AppleTextProcessor: TextProcessor {
    nonisolated let identifier = "apple-system-cleanup-v2"
    private let model = SystemLanguageModel.default
    private var preparedSession: LanguageModelSession?

    func prepare() async throws {
        switch model.availability {
        case .available: break
        case .unavailable(let reason):
            throw CleanupFailure.unavailable("Apple's on-device model is unavailable: \(reason).")
        }
        try Task.checkCancellation()
        if preparedSession != nil { return }
        let session = LanguageModelSession(model: model, instructions: CleanupPrompt.instructions)
        session.prewarm()
        preparedSession = session
    }

    func process(_ request: CleanupRequest) async throws -> String {
        // This is an English feasibility probe; other languages need their own evaluation.
        guard request.language == "en" || request.language == "auto", model.supportsLocale(Locale(identifier: "en")) else {
            throw CleanupFailure.unavailable("This cleanup experiment currently supports English only.")
        }
        guard request.rawText.utf8.count <= 2_000 else {
            throw CleanupFailure.unavailable("This experiment is limited to 2,000 UTF-8 bytes of input.")
        }
        try Task.checkCancellation()
        let instructions = request.prompts[.appleSystem]
        let session = (instructions == CleanupPrompt.instructions ? preparedSession : nil)
            ?? LanguageModelSession(model: model, instructions: instructions)
        preparedSession = nil // Never accumulate conversations or other dictations in model context.
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 2_048)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 2_048)
        #endif
        do {
            let input = CleanupPrompt.input(request)
            let guide = request.prompts[.appleOutput]
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "EditedTranscript", properties: [
                .init(name: "text", description: guide, schema: .init(type: String.self)),
            ]), dependencies: [])
            await request.promptObserver?(.init(requestID: request.id, provider: identifier, messages: [
                .init(role: "system", content: instructions), .init(role: "user", content: input),
                .init(role: "schema · text field", content: guide),
            ], details: "EditedTranscript { text: String } · greedy · maximum 2,048 output tokens. Apple manages its internal system instructions."))
            try Task.checkCancellation()
            let response = try await session.respond(to: input, schema: schema, options: options)
            try Task.checkCancellation()
            return try response.content.value(String.self, forProperty: "text")
        } catch {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *), let modelError = error as? LanguageModelError {
                switch modelError {
                case .refusal, .guardrailViolation: throw CleanupFailure.refused(error.localizedDescription)
                default: break
                }
            }
            #endif
            if let legacyError = error as? LanguageModelSession.GenerationError {
                switch legacyError {
                case .refusal, .guardrailViolation: throw CleanupFailure.refused(error.localizedDescription)
                default: break
                }
            }
            throw error
        }
    }
}
#endif
