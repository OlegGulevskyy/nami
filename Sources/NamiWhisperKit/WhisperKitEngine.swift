import Foundation
import NamiCore
@preconcurrency import WhisperKit

public struct EngineConfiguration: Sendable {
    public enum Backend: String, Sendable { case whisperkit, fake }
    public var backend: Backend = .whisperkit
    public var modelFolder: String?
    public var fakeTranscript = "This is a fake transcript."
    public init() {}
}

@MainActor
public enum EngineFactory {
    public static func make(_ configuration: EngineConfiguration) throws -> any TranscriptionEngine {
        switch configuration.backend {
        case .fake: return FakeTranscriptionEngine(transcript: configuration.fakeTranscript)
        case .whisperkit:
            guard let folder = configuration.modelFolder else {
                throw EngineError.modelUnavailable("Run download to configure a model, set modelFolder in nami.json, or pass --model-folder.")
            }
            return WhisperKitEngine(modelFolder: folder)
        }
    }
}

@MainActor
public final class WhisperKitEngine: TranscriptionEngine {
    public static let sdkVersion = "1.1.0"
    public static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"
    // Baseline is deliberately batch-only. Measure before adding speculative decoding.
    public let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: false)
    private let runtime: WhisperRuntime
    private var prepared = false
    private var buffer = AudioSessionBuffer()
    private var language: String?
    private var vocabulary = ""
    private var inference: Task<String, Error>?
    private var inferenceSession: UUID?

    public init(modelFolder: String) { runtime = WhisperRuntime(modelFolder: modelFolder) }

    public nonisolated static func availableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    public nonisolated static func download(model: String, to directory: URL) async throws -> URL {
        let folder = try await WhisperKit.download(variant: model, downloadBase: directory)
        // WhisperKit's model download does not include tokenizer assets. Fetch them
        // during this explicitly online setup command, and bundle them with the model.
        let setup = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path,
            tokenizerFolder: directory, verbose: false, logLevel: .error,
            prewarm: true, load: true, download: false))
        let tokenizerRepo = "openai/whisper-" + setup.modelVariant.description
        let tokenizerDirectory = HubApiWrapper(downloadBase: directory).localRepoLocation(.init(id: tokenizerRepo))
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            let destination = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: tokenizerDirectory.appendingPathComponent(name), to: destination)
            }
        }
        await setup.unloadModels()
        return folder
    }

    public func prepare() async throws {
        guard !prepared else { return }
        do {
            try await runtime.prepare()
            try Task.checkCancellation()
            prepared = true
        } catch {
            throw EngineError.modelUnavailable(error.localizedDescription)
        }
    }

    public func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        // Do not reuse the underlying pipeline until cancelled inference has unwound.
        guard inference == nil else { throw EngineError.invalidState }
        try buffer.start(sessionID)
        self.language = language
        self.vocabulary = vocabulary
    }

    public func append(_ chunk: NamiCore.AudioChunk, sessionID: UUID) async throws {
        try buffer.append(chunk, sessionID: sessionID)
    }

    public func finish(sessionID: UUID) async throws -> String {
        guard prepared else { throw EngineError.notPrepared }
        let audio = try buffer.beginFinish(sessionID)
        let work = Task { [runtime, language, vocabulary] in
            try await runtime.transcribe(audio, language: language, vocabulary: vocabulary)
        }
        inference = work
        inferenceSession = sessionID
        defer { inference = nil; inferenceSession = nil }
        do {
            let text = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            try buffer.complete(sessionID)
            return text
        } catch {
            buffer.cancel(sessionID)
            if error is CancellationError || work.isCancelled || error as? EngineError == .cancelled {
                throw EngineError.cancelled
            }
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    public func cancel(sessionID: UUID) async {
        buffer.cancel(sessionID)
        if inferenceSession == sessionID { inference?.cancel() }
    }
}

/// Keep SDK initialization, tokenizer parsing and inference off the main actor
/// so a cold load cannot block shortcuts, the recording timer or audio draining.
private actor WhisperRuntime {
    private let modelFolder: String
    private var pipeline: WhisperKit?

    init(modelFolder: String) { self.modelFolder = modelFolder }

    func prepare() async throws {
        guard pipeline == nil else { return }
        // The SDK otherwise falls back to a network tokenizer fetch even with
        // download:false. Reject missing/corrupt tokenizer assets first.
        _ = try await AutoTokenizerWrapper.from(modelFolder: URL(fileURLWithPath: modelFolder))
        try Task.checkCancellation()
        pipeline = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder,
            tokenizerFolder: URL(fileURLWithPath: modelFolder),
            verbose: false, logLevel: .error, prewarm: true, load: true, download: false
        ))
    }

    func transcribe(_ audio: [Float], language: String?, vocabulary: String) async throws -> String {
        guard let pipeline else { throw EngineError.notPrepared }
        var options = DecodingOptions(language: language, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let prompt = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            guard let tokenizer = pipeline.tokenizer else { throw EngineError.notPrepared }
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                // WhisperKit bounds the conditioning context, retaining its final tokens.
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }
        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
