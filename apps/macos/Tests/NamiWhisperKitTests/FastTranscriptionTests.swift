import Foundation
import Testing
import NamiCore
@testable import NamiWhisperKit

@Test func uncertainNamesUseAcousticVerificationInsteadOfTextReplacement() {
    let phrase = FastDecodedAudio(text: "Use the post hoc report.", words: [], confidence: 0.98)
    #expect(RecognitionReview.reason(for: phrase, vocabulary: "Posthog") != nil)
    #expect(RecognitionReview.reason(for: phrase, vocabulary: "") == nil)
    let acronym = FastDecodedAudio(text: "Check APIX.", words: [.init(text: "APIX.", confidence: 0.7)], confidence: 0.99)
    #expect(RecognitionReview.reason(for: acronym, vocabulary: "") != nil)
    let ordinary = FastDecodedAudio(text: "The controls stay in the window.", words: [.init(text: "controls", confidence: 0.8)], confidence: 0.98)
    #expect(RecognitionReview.reason(for: ordinary, vocabulary: "Posthog, Theoria, GPT for Sheets,") == nil)
    #expect(RecognitionReview.canonicalCase("Use gpt for sheets and theoria. Not theorians.", vocabulary: "GPT for Sheets, Theoria,") == "Use GPT for Sheets and Theoria. Not theorians.")
}

@MainActor private final class RecordingVerifier: TranscriptionEngine {
    let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: false)
    var starts = 0
    var samples: [Float] = []
    var language: String?
    var vocabulary = ""
    var transcript = "The verified complete utterance."
    func prepare() async throws {}
    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        starts += 1; self.language = language; self.vocabulary = vocabulary; samples = []
    }
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws { samples += chunk.samples }
    func finish(sessionID: UUID) async throws -> String { transcript }
    func cancel(sessionID: UUID) async {}
}

@Test @MainActor func fastRecognitionKeepsCompleteAudioAndUsesVerifierOnlyWhenNeeded() async throws {
    let verifier = RecordingVerifier()
    let engine = FastTranscriptionEngine(verifier: verifier, prepare: {}, decode: { audio, _ in
        #expect(audio == [0.1, 0.2, 0.3])
        return .init(text: "Use the post hoc report.", words: [], confidence: 0.99)
    })
    try await engine.prepare()
    for vocabulary in ["", "Posthog"] {
        let id = UUID()
        try await engine.start(sessionID: id, language: "en", vocabulary: vocabulary, onPartial: nil)
        try await engine.append(.init(samples: [0.1, 0.2], timestamp: 0), sessionID: id)
        try await engine.append(.init(samples: [0.3], timestamp: 2 / AudioChunk.sampleRate), sessionID: id)
        let result = try await engine.finish(sessionID: id)
        #expect(result == (vocabulary.isEmpty ? "Use the post hoc report." : verifier.transcript))
    }
    #expect(verifier.starts == 1 && verifier.samples == [0.1, 0.2, 0.3])
    #expect(verifier.language == "en" && verifier.vocabulary == "Posthog")
}

@Test @MainActor func unsupportedExplicitLanguageKeepsWhisperCoverage() async throws {
    let verifier = RecordingVerifier()
    let engine = FastTranscriptionEngine(verifier: verifier, prepare: {}, decode: { _, _ in
        Issue.record("Unsupported language must not use Parakeet")
        return .init(text: "", words: [], confidence: 0)
    })
    try await engine.prepare()
    let id = UUID()
    try await engine.start(sessionID: id, language: "ja", vocabulary: "", onPartial: nil)
    try await engine.append(.init(samples: [0.1], timestamp: 0), sessionID: id)
    #expect(try await engine.finish(sessionID: id) == verifier.transcript)
    #expect(verifier.language == "ja")
}

@Test @MainActor func cancelledFastRecognitionCannotPublishALateResult() async throws {
    let engine = FastTranscriptionEngine(verifier: RecordingVerifier(), prepare: {}, decode: { _, _ in
        try? await Task.sleep(for: .milliseconds(60))
        return .init(text: "Late result", words: [], confidence: 1)
    })
    try await engine.prepare()
    let id = UUID()
    try await engine.start(sessionID: id, language: nil, vocabulary: "", onPartial: nil)
    try await engine.append(.init(samples: [0.1], timestamp: 0), sessionID: id)
    let finish = Task { try await engine.finish(sessionID: id) }
    try await Task.sleep(for: .milliseconds(10))
    await engine.cancel(sessionID: id)
    await #expect(throws: EngineError.cancelled) { try await finish.value }
    let next = UUID()
    try await engine.start(sessionID: next, language: nil, vocabulary: "", onPartial: nil)
    await engine.cancel(sessionID: next)
}

private actor PreviewDecodes {
    var lengths: [Int] = []
    func decode(_ audio: [Float]) -> FastDecodedAudio {
        lengths.append(audio.count)
        return .init(text: audio.count == 4_800 ? "Schedule Monday." : "Schedule Tuesday.", words: [], confidence: 1)
    }
}

@Test @MainActor func livePreviewNeverCommitsRevisedSpeechOrDropsTheAudioTail() async throws {
    let decodes = PreviewDecodes()
    let engine = FastTranscriptionEngine(verifier: RecordingVerifier(), prepare: {}, decode: { audio, _ in
        await decodes.decode(audio)
    })
    try await engine.prepare()
    let id = UUID()
    try await engine.startLive(sessionID: id, language: "en", vocabulary: "", onPartial: { _ in })
    try await engine.append(.init(samples: Array(repeating: 0.1, count: 4_800), timestamp: 0), sessionID: id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await decodes.lengths.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await decodes.lengths == [4_800])
    try await engine.append(.init(samples: Array(repeating: 0.2, count: 900), timestamp: 0.3), sessionID: id)
    #expect(try await engine.finish(sessionID: id) == "Schedule Tuesday.")
    #expect(await decodes.lengths == [4_800, 5_700])
}
