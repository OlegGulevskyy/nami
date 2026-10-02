import Foundation
import NamiCore
import FluidAudio

struct FastDecodedAudio: Sendable {
    struct Word: Sendable { let text: String; let confidence: Float }
    let text: String
    let words: [Word]
    let confidence: Float
}

/// Full-context fast recognition, with the existing recognizer available for
/// uncertain acronyms and near-matches to the user's vocabulary. No audio or
/// partial text is committed before the complete utterance has been recognized.
@MainActor public final class FastTranscriptionEngine: TranscriptionEngine {
    public let capabilities = EngineCapabilities(incrementalProcessing: true, requiresNetwork: false)
    public static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nami/Models/parakeet-ultra")
    }
    private let preparePrimary: @Sendable () async throws -> Void
    private let decodePrimary: @Sendable ([Float], String?) async throws -> FastDecodedAudio
    private let verifier: any TranscriptionEngine
    private var prepared = false
    private var buffer = AudioSessionBuffer()
    private var language: String?
    private var vocabulary = ""
    private var observer: ModelPromptObserver?
    private var inference: Task<String, Error>?
    private var activeID: UUID?
    private var live = false
    private var liveAudio: [Float] = []
    private var partial: (@Sendable (String) -> Void)?
    private var partialWorker: Task<Void, Never>?
    private var latest: (count: Int, result: FastDecodedAudio)?
    private var partialFailed = false
    // A coalesced full-context preview every 300 ms; no unbounded decode queue.
    private let previewSamples = 4_800

    public convenience init(modelFolder: String = FastTranscriptionEngine.modelDirectory.path, verifier: any TranscriptionEngine) {
        let runtime = ParakeetRuntime(folder: URL(fileURLWithPath: modelFolder))
        self.init(verifier: verifier, prepare: { try await runtime.prepare() }, decode: { audio, language in
            try await runtime.decode(audio, language: language)
        })
    }

    init(verifier: any TranscriptionEngine, prepare: @escaping @Sendable () async throws -> Void,
         decode: @escaping @Sendable ([Float], String?) async throws -> FastDecodedAudio) {
        self.verifier = verifier; self.preparePrimary = prepare; self.decodePrimary = decode
    }

    public static var installed: Bool { AsrModels.modelsExist(at: modelDirectory, version: .ultra) }
    public static func download() async throws {
        _ = try await AsrModels.download(to: modelDirectory, version: .ultra)
    }

    public func setPromptObserver(_ observer: ModelPromptObserver?) async {
        self.observer = observer
        await verifier.setPromptObserver(observer)
    }

    public func prepare() async throws {
        guard !prepared else { return }
        try await preparePrimary()
        try await verifier.prepare()
        try Task.checkCancellation()
        prepared = true
    }

    public func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        guard inference == nil else { throw EngineError.invalidState }
        try buffer.start(sessionID)
        activeID = sessionID
        live = false; liveAudio = []; latest = nil; partialFailed = false
        self.language = language; self.vocabulary = vocabulary
    }

    public func startLive(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        try await start(sessionID: sessionID, language: language, vocabulary: vocabulary, onPartial: onPartial)
        live = onPartial != nil && (language.map(RecognitionReview.supportedLanguages.contains) ?? true)
        partial = onPartial
    }

    public func append(_ chunk: AudioChunk, sessionID: UUID) async throws {
        try buffer.append(chunk, sessionID: sessionID)
        guard live else { return }
        liveAudio += chunk.samples
        guard partialWorker == nil, !partialFailed, liveAudio.count - (latest?.count ?? 0) >= self.previewSamples else { return }
        partialWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.partialWorker = nil }
            while self.live, self.liveAudio.count - (self.latest?.count ?? 0) >= self.previewSamples {
                let audio = self.liveAudio
                do {
                    let result = try await self.decodePrimary(audio, self.language)
                    try Task.checkCancellation()
                    self.latest = (audio.count, result)
                    if RecognitionReview.reason(for: result, vocabulary: self.vocabulary) == nil {
                        self.partial?(RecognitionReview.canonicalCase(result.text, vocabulary: self.vocabulary))
                    }
                } catch { self.partialFailed = true; return }
            }
        }
    }

    public func finish(sessionID: UUID) async throws -> String {
        guard prepared else { throw EngineError.notPrepared }
        let audio = try buffer.beginFinish(sessionID)
        live = false
        // Core ML work already in flight must finish before another decode can
        // run. Keep its preview usable for overlapping cleanup while the final
        // full-audio decode verifies it, instead of throwing that work away.
        let partialWorker = self.partialWorker
        let work = Task { [decodePrimary, language, vocabulary, verifier, observer] in
            await partialWorker?.value
            try Task.checkCancellation()
            let text: String
            if let language, !RecognitionReview.supportedLanguages.contains(language) {
                try await verifier.start(sessionID: sessionID, language: language, vocabulary: vocabulary, onPartial: nil)
                try await verifier.append(AudioChunk(samples: audio, timestamp: 0), sessionID: sessionID)
                text = try await verifier.finish(sessionID: sessionID)
            } else {
                let record = ModelPromptRecord(requestID: sessionID, provider: "Parakeet Ultra",
                    messages: [.init(role: "vocabulary", content: vocabulary)],
                    details: "Complete utterance · on-device · uncertain vocabulary and acronyms checked with Whisper")
                await observer?(record)
                let start = ContinuousClock.now
                let result: FastDecodedAudio
                do {
                    if let latest = self.latest, latest.count == audio.count { result = latest.result }
                    else { result = try await decodePrimary(audio, language) }
                }
                catch {
                    await observer?(record.responding(.init(output: "", error: error.localizedDescription, seconds: start.secondsElapsed)))
                    throw error
                }
                try Task.checkCancellation()
                let review = RecognitionReview.reason(for: result, vocabulary: vocabulary)
                await observer?(record.responding(.init(output: result.text, seconds: start.secondsElapsed,
                    details: review.map { "Whisper verification: " + $0 } ?? "Full utterance recognized")))
                if review != nil {
                    try await verifier.start(sessionID: sessionID, language: language, vocabulary: vocabulary, onPartial: nil)
                    try await verifier.append(AudioChunk(samples: audio, timestamp: 0), sessionID: sessionID)
                    text = try await verifier.finish(sessionID: sessionID)
                } else { text = RecognitionReview.canonicalCase(result.text, vocabulary: vocabulary) }
            }
            try Task.checkCancellation()
            return text
        }
        inference = work
        defer { inference = nil; activeID = nil; liveAudio = []; latest = nil; partial = nil }
        do {
            let text = try await withTaskCancellationHandler { try await work.value } onCancel: {
                partialWorker?.cancel(); work.cancel()
            }
            try Task.checkCancellation()
            try buffer.complete(sessionID)
            return text
        } catch {
            buffer.cancel(sessionID)
            await verifier.cancel(sessionID: sessionID)
            if error is CancellationError { throw EngineError.cancelled }
            throw error
        }
    }

    public func cancel(sessionID: UUID) async {
        guard activeID == sessionID else { return }
        buffer.cancel(sessionID)
        live = false
        partialWorker?.cancel()
        inference?.cancel()
        await partialWorker?.value
        liveAudio = []; latest = nil; partial = nil
        await verifier.cancel(sessionID: sessionID)
        _ = await inference?.result
    }
}

private actor ParakeetRuntime {
    let folder: URL
    private var manager: AsrManager?
    init(folder: URL) { self.folder = folder }
    func prepare() async throws {
        guard manager == nil else { return }
        // loadLocal never downloads, even for absent/corrupt components.
        let models = try AsrModels.loadLocal(from: folder, version: .ultra)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }
    func decode(_ audio: [Float], language: String?) async throws -> FastDecodedAudio {
        guard let manager else { throw EngineError.notPrepared }
        try Task.checkCancellation()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        try Task.checkCancellation()
        var words: [FastDecodedAudio.Word] = []
        var text = "", confidence: Float = 1
        func flush() {
            if !text.isEmpty { words.append(.init(text: text, confidence: confidence)) }
            text = ""; confidence = 1
        }
        for token in result.tokenTimings ?? [] {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if piece.first?.isWhitespace == true { flush() }
            text += piece.trimmingCharacters(in: .whitespaces)
            if piece.contains(where: \.isLetter) { confidence = min(confidence, token.confidence) }
        }
        flush()
        return FastDecodedAudio(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), words: words, confidence: result.confidence)
    }
}
