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
    private let modelFolder: String
    private var pipeline: WhisperKit?
    private var buffer = AudioSessionBuffer()
    private var language: String?
    private var inference: Task<String, Error>?
    private var inferenceSession: UUID?

    public init(modelFolder: String) { self.modelFolder = modelFolder }

    public static func download(model: String, to directory: URL) async throws -> URL {
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
        guard pipeline == nil else { return }
        do {
            // The SDK otherwise falls back to a network tokenizer fetch even with
            // download:false. Reject missing/corrupt tokenizer assets before entering it.
            _ = try await AutoTokenizerWrapper.from(modelFolder: URL(fileURLWithPath: modelFolder))
            pipeline = try await WhisperKit(WhisperKitConfig(
                modelFolder: modelFolder,
                tokenizerFolder: URL(fileURLWithPath: modelFolder),
                verbose: false, logLevel: .error, prewarm: true, load: true, download: false
            ))
        } catch {
            throw EngineError.modelUnavailable(error.localizedDescription)
        }
    }

    public func start(sessionID: UUID, language: String?, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard pipeline != nil else { throw EngineError.notPrepared }
        // Do not reuse the underlying pipeline until cancelled inference has unwound.
        guard inference == nil else { throw EngineError.invalidState }
        try buffer.start(sessionID)
        self.language = language
    }

    public func append(_ chunk: NamiCore.AudioChunk, sessionID: UUID) async throws {
        try buffer.append(chunk, sessionID: sessionID)
    }

    public func finish(sessionID: UUID) async throws -> String {
        guard let pipeline else { throw EngineError.notPrepared }
        let audio = try buffer.beginFinish(sessionID)
        let options = DecodingOptions(language: language, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let work = Task { @MainActor in
            let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
            try Task.checkCancellation()
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
