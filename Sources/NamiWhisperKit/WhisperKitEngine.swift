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
    public let capabilities = EngineCapabilities(incrementalProcessing: true, requiresNetwork: false)
    private let runtime: WhisperRuntime
    private var prepared = false
    private var buffer = AudioSessionBuffer()
    private var language: String?
    private var vocabulary = ""
    private var inference: Task<String, Error>?
    private var inferenceSession: UUID?
    private var streaming: StreamingTranscription?
    private var streamingID: UUID?

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

    public func setPromptObserver(_ observer: ModelPromptObserver?) async {
        await runtime.setPromptObserver(observer)
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
        guard inference == nil, inferenceSession == nil, streaming == nil else { throw EngineError.invalidState }
        try buffer.start(sessionID)
        self.language = language
        self.vocabulary = vocabulary
        await runtime.setRequestID(sessionID)
    }

    public func startLive(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        try await start(sessionID: sessionID, language: language, vocabulary: vocabulary, onPartial: onPartial)
        streamingID = sessionID
        streaming = StreamingTranscription(onPartial: onPartial) { [runtime] audio in
            try await runtime.decode(audio, language: language, vocabulary: vocabulary)
        }
    }

    public func append(_ chunk: NamiCore.AudioChunk, sessionID: UUID) async throws {
        if let streaming {
            guard streamingID == sessionID else { throw EngineError.invalidState }
            try streaming.append(chunk)
            return
        }
        try buffer.append(chunk, sessionID: sessionID)
    }

    public func finish(sessionID: UUID) async throws -> String {
        guard prepared else { throw EngineError.notPrepared }
        if let streaming {
            guard streamingID == sessionID, inferenceSession == nil else { throw EngineError.invalidState }
            inferenceSession = sessionID
            defer {
                if streamingID == sessionID { self.streaming = nil; streamingID = nil }
                inferenceSession = nil
                buffer.cancel(sessionID)
            }
            do { return try await streaming.finish() }
            catch {
                await streaming.cancel()
                if error is CancellationError || error as? EngineError == .cancelled { throw EngineError.cancelled }
                throw EngineError.transcriptionFailed(error.localizedDescription)
            }
        }
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
        if streamingID == sessionID, let streaming {
            await streaming.cancel()
            if streamingID == sessionID { self.streaming = nil; streamingID = nil }
        }
        if inferenceSession == sessionID { inference?.cancel() }
    }
}

/// Keep SDK initialization, tokenizer parsing and inference off the main actor
/// so a cold load cannot block shortcuts, the recording timer or audio draining.
private actor WhisperRuntime {
    private let modelFolder: String
    private var pipeline: WhisperKit?
    private var promptObserver: ModelPromptObserver?
    private var requestID = UUID()
    func setPromptObserver(_ observer: ModelPromptObserver?) { promptObserver = observer }
    func setRequestID(_ id: UUID) { requestID = id }

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
        try await decode(audio, language: language, vocabulary: vocabulary).text
    }

    func decode(_ audio: [Float], language: String?, vocabulary: String) async throws -> DecodedAudio {
        guard let pipeline else { throw EngineError.notPrepared }
        // Keep segment timestamps for long-form seeking; skipSpecialTokens still
        // returns plain text. Disabling timestamps can end prompted windows early.
        var options = DecodingOptions(language: language, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: false)
        // Clear per-session filters when vocabulary is removed or changed.
        pipeline.textDecoder.logitsFilters = nil
        let prompt = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            guard let tokenizer = pipeline.tokenizer else { throw EngineError.notPrepared }
            let tokens = Array(tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .suffix((Constants.maxTokenContext / 2) - 1))
            if !tokens.isEmpty {
                // WhisperKit bounds the conditioning context, retaining its final tokens.
                options.promptTokens = tokens
                options.usePrefillPrompt = true
                if pipeline.textDecoder.isModelMultilingual {
                    // WhisperKit 1.1.0 only searches the first three prompt tokens
                    // for the task token, so vocabulary disables its timestamp rules.
                    // Supply the actual boundary: startofprev + vocabulary + SOT,
                    // language, task, timestamp. `false` bypasses that faulty search;
                    // it does not change the model or language being decoded.
                    pipeline.textDecoder.logitsFilters = [TimestampRulesFilter(
                        specialTokens: tokenizer.specialTokens, sampleBegin: tokens.count + 5,
                        maxInitialTimestampIndex: nil, isModelMultilingual: false)]
                }
            }
        }
        let tokens = options.promptTokens ?? []
        let record = ModelPromptRecord(requestID: requestID, provider: "Whisper · " + URL(fileURLWithPath: modelFolder).lastPathComponent,
            messages: [.init(role: "vocabulary · effective prompt", content: pipeline.tokenizer?.decode(tokens: tokens) ?? "")],
            details: "Language: \(language ?? "auto") · vocabulary token IDs: \(tokens). Whisper keeps the final \((Constants.maxTokenContext / 2) - 1) vocabulary tokens. No system prompt. Each entry is one decode call; the SDK manages audio windows internally.")
        await promptObserver?(record)
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let results: [TranscriptionResult]
        do { results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options) } catch {
            await promptObserver?(record.responding(.init(output: "", error: error.localizedDescription, seconds: started.secondsElapsed)))
            throw error
        }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments)
        let audioSeconds = Double(audio.count) / Double(WhisperKit.sampleRate)
        let seconds = started.secondsElapsed
        await promptObserver?(record.responding(.init(output: text,
            error: Task.isCancelled ? "Cancelled before the transcript was used." : nil, seconds: seconds,
            outputTokens: segments.reduce(0) { $0 + $1.tokens.count },
            generationSeconds: results.reduce(0) { $0 + $1.timings.decodingLoop },
            details: String(format: "Audio %.1f s · %.1f× real time · %d segments · %d windows · language %@",
                audioSeconds, seconds > 0 ? audioSeconds / seconds : 0, segments.count,
                Int(results.reduce(0) { $0 + $1.timings.totalDecodingWindows }), results.first?.language ?? language ?? "auto"))))
        try Task.checkCancellation()
        return DecodedAudio(
            text: text,
            segments: segments.map {
                DecodedSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
            })
    }
}
