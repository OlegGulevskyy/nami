import Foundation
import Testing
import NamiAudio
import NamiCore
import NamiWhisperKit

/// Replays private, local fixtures without committing audio or sending it anywhere.
/// Expected phrases should cover the beginning, middle, and end of the recording.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_LONG_AUDIO_FILE"] != nil))
@MainActor func longTranscriptionPreservesSpeechWithVocabularyAndWarmReuse() async throws {
    let environment = ProcessInfo.processInfo.environment
    let model = try #require(environment["NAMI_TEST_MODEL_FOLDER"])
    let audioPath = try #require(environment["NAMI_TEST_LONG_AUDIO_FILE"])
    let phrasesPath = try #require(environment["NAMI_TEST_EXPECTED_PHRASES_FILE"])
    let phrases = try String(contentsOfFile: phrasesPath, encoding: .utf8)
        .split(separator: "\n").map { String($0).lowercased() }
    try #require(phrases.count >= 3, "Supply phrases covering the beginning, middle, and end.")
    let vocabulary = try #require(environment["NAMI_TEST_VOCABULARY"])
    try #require(!vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    let audio = try AudioFile.read(URL(fileURLWithPath: audioPath))
    try #require(Double(audio.count) / AudioChunk.sampleRate > 30)
    let engine = WhisperKitEngine(modelFolder: model)
    try await engine.prepare()
    for hints in [vocabulary, "", vocabulary, vocabulary, ""] {
        let id = UUID()
        try await engine.start(sessionID: id, language: "en", vocabulary: hints, onPartial: nil)
        for offset in stride(from: 0, to: audio.count, by: 1600) {
            try await engine.append(AudioChunk(samples: Array(audio[offset..<min(audio.count, offset + 1600)]),
                timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: id)
        }
        let transcript = try await engine.finish(sessionID: id)
        print("Long recording (vocabulary: \(hints)): \(transcript)")
        for phrase in phrases {
            #expect(transcript.lowercased().contains(phrase), "Missing expected speech: \(phrase)")
        }
    }
}
