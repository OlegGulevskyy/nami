import Foundation
import os
import Testing
import NamiAudio
import NamiCore
import NamiWhisperKit

/// Opt-in local benchmark. Replays saved audio at microphone speed, without using
/// the microphone, clipboard, network, or changing the user's recording history.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_STREAM_AUDIO_FILES"] != nil))
@MainActor func streamingReplayMeasuresStopLatencyAgainstBatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let model = try #require(environment["NAMI_TEST_MODEL_FOLDER"])
    let paths = try #require(environment["NAMI_TEST_STREAM_AUDIO_FILES"]).split(separator: "\n")
    let engine = WhisperKitEngine(modelFolder: model)
    try await engine.prepare()
    var report: [[String: Any]] = []
    for path in paths {
        let samples = try AudioFile.read(URL(fileURLWithPath: String(path)))
        try #require(!samples.isEmpty)
        let vocabulary = environment["NAMI_TEST_VOCABULARY"] ?? ""
        // Warm the decoder before timing either path.
        do {
            let id = UUID()
            try await engine.start(sessionID: id, language: "en", vocabulary: vocabulary, onPartial: nil)
            try await engine.append(AudioChunk(samples: Array(samples.prefix(32_000)), timestamp: 0), sessionID: id)
            _ = try await engine.finish(sessionID: id)
        }
        let batchID = UUID()
        try await engine.start(sessionID: batchID, language: "en", vocabulary: vocabulary, onPartial: nil)
        try await engine.append(AudioChunk(samples: samples, timestamp: 0), sessionID: batchID)
        let batchStart = ContinuousClock.now
        let batch = try await engine.finish(sessionID: batchID)
        let batchSeconds = seconds(since: batchStart)

        let partials = OSAllocatedUnfairLock(initialState: (count: 0, firstSeconds: 0.0))
        let liveID = UUID(), replayStart = ContinuousClock.now
        try await engine.startLive(sessionID: liveID, language: "en", vocabulary: vocabulary) { _ in
            partials.withLock {
                if $0.count == 0 { $0.firstSeconds = seconds(since: replayStart) }
                $0.count += 1
            }
        }
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let end = min(samples.count, offset + 1600)
            try await ContinuousClock().sleep(until: replayStart.advanced(by: .seconds(Double(end) / AudioChunk.sampleRate)))
            try await engine.append(AudioChunk(samples: Array(samples[offset..<end]),
                timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: liveID)
        }
        let stop = ContinuousClock.now
        let live = try await engine.finish(sessionID: liveID)
        let stopSeconds = seconds(since: stop)
        let updates = partials.withLock { $0 }
        #expect(!live.isEmpty)
        if samples.count > 5 * 16_000 { #expect(updates.count > 0) }
        let row: [String: Any] = [
            "audio": String(path), "audioSeconds": Double(samples.count) / AudioChunk.sampleRate,
            "batchSeconds": batchSeconds, "streamingStopSeconds": stopSeconds,
            "partialCount": updates.count, "firstPartialSeconds": updates.firstSeconds,
            "batchTranscript": batch, "streamingTranscript": live
        ]
        report.append(row)
        print("Streaming replay: audio=\(Double(samples.count) / AudioChunk.sampleRate)s batch=\(batchSeconds)s stop=\(stopSeconds)s partials=\(updates.count)")
    }
    if let output = environment["NAMI_TEST_STREAM_REPORT"] {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}
