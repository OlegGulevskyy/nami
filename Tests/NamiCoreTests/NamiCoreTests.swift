import AVFoundation
import Foundation
import Testing
@testable import NamiCore
@testable import NamiAudio

@Test func metricsHandleEditsAndPercentiles() {
    #expect(EvaluationMetrics.wordErrorRate(reference: "Hello, WORLD!", hypothesis: "hello world") == 0)
    #expect(EvaluationMetrics.wordErrorRate(reference: "one two three", hypothesis: "one four three") == 1.0 / 3)
    #expect(EvaluationMetrics.wordErrorRate(reference: "one two", hypothesis: "one") == 0.5)
    #expect(EvaluationMetrics.wordErrorRate(reference: "one two", hypothesis: "one new two") == 0.5)
    #expect(EvaluationMetrics.median([4, 1, 3, 2]) == 2.5)
    #expect(EvaluationMetrics.p95(Array(1...20).map(Double.init)) == 19)
    #expect(EvaluationMetrics.median([]) == nil)
    #expect(EvaluationMetrics.p95([]) == nil)
}

@Test func rejectsDiscontinuousOrNonfiniteAudio() throws {
    var buffer = AudioSessionBuffer()
    let id = UUID()
    try buffer.start(id)
    #expect(throws: EngineError.invalidAudio) {
        try buffer.append(AudioChunk(samples: [0], timestamp: 1), sessionID: id)
    }
    #expect(throws: EngineError.invalidAudio) {
        try buffer.append(AudioChunk(samples: [.nan], timestamp: 0), sessionID: id)
    }
    try buffer.append(AudioChunk(samples: [0, 0.1], timestamp: 0), sessionID: id)
    #expect(try buffer.beginFinish(id) == [0, 0.1])
    #expect(throws: EngineError.invalidState) { try buffer.beginFinish(id) }
    try buffer.complete(id)
    #expect(throws: EngineError.cancelled) { try buffer.complete(id) }
}

@Test func staleCompletionCannotClearNewSession() throws {
    var buffer = AudioSessionBuffer()
    let old = UUID(), new = UUID()
    try buffer.start(old)
    try buffer.append(AudioChunk(samples: [0], timestamp: 0), sessionID: old)
    _ = try buffer.beginFinish(old)
    buffer.cancel(old)
    try buffer.start(new)
    buffer.cancel(old)
    #expect(throws: EngineError.cancelled) { try buffer.complete(old) }
    try buffer.append(AudioChunk(samples: [0.5], timestamp: 0), sessionID: new)
    #expect(try buffer.beginFinish(new) == [0.5])
    try buffer.complete(new)
}

@Test @MainActor func fakeEngineContractAndCancellation() async throws {
    let engine: any TranscriptionEngine = FakeTranscriptionEngine(transcript: "hello", delay: .milliseconds(50))
    let id = UUID()
    await #expect(throws: EngineError.notPrepared) {
        try await engine.start(sessionID: id, language: "en", onPartial: nil)
    }
    try await engine.prepare()
    try await engine.start(sessionID: id, language: "en", onPartial: nil)
    await #expect(throws: EngineError.noAudio) { try await engine.finish(sessionID: id) }
    try await engine.append(AudioChunk(samples: [0.1], timestamp: 0), sessionID: id)
    #expect(try await engine.finish(sessionID: id) == "hello")
    await #expect(throws: EngineError.invalidState) { try await engine.finish(sessionID: id) }

    let cancelled = UUID()
    try await engine.start(sessionID: cancelled, language: "en", onPartial: nil)
    try await engine.append(AudioChunk(samples: [0], timestamp: 0), sessionID: cancelled)
    let work = Task { try await engine.finish(sessionID: cancelled) }
    // Let finish reach its suspension point, then cancel while it is processing.
    await Task.yield()
    await engine.cancel(sessionID: cancelled)
    do { _ = try await work.value; Issue.record("Cancelled engine emitted a result") }
    catch { #expect(error as? EngineError == .cancelled || error as? EngineError == .invalidState) }
    let next = UUID()
    try await engine.start(sessionID: next, language: "en", onPartial: nil)
    try await engine.append(AudioChunk(samples: [0.2], timestamp: 0), sessionID: next)
    #expect(try await engine.finish(sessionID: next) == "hello")
}

@Test func convertsStereo48kToMono16k() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            let value = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = value
        }
        try file.write(from: buffer)
    }
    let samples = try AudioFile.read(url)
    #expect(abs(samples.count - 16_000) <= 1)
    #expect(samples.allSatisfy { $0.isFinite })
    let rms = sqrt(samples.map { Double($0 * $0) }.reduce(0, +) / Double(samples.count))
    #expect(rms > 0.13 && rms < 0.15)
}

@Test func rejectsUnverifiedReferences() throws {
    let data = Data("""
    {"id":"1","audio":"a.wav","reference":"hello","language":"en","category":"command","condition":"quiet","referenceVerified":false}
    """.utf8)
    let sample = try JSONDecoder().decode(EvaluationSample.self, from: data)
    #expect(throws: EvaluationError.self) { try sample.validate() }
}

// Mirrors Objective-C AVAudioEngine calling a non-Sendable block on its own queue.
// Only the background queue accesses the supplied buffer during invocation.
private struct BackgroundAudioCallback: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock
    func invoke() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<4800 {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2
        }
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        callback(buffer, AVAudioTime(sampleTime: 4800, atRate: 48_000))
    }

    func invokeTenSeconds(sampleRate: Double) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let total = Int(sampleRate * 10)
        for start in stride(from: 0, to: total, by: 2048) {
            let count = min(2048, total - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<count {
                buffer.floatChannelData![0][index] = Float(sin(Double(start + index) * 2 * .pi * 440 / sampleRate)) * 0.2
            }
            callback(buffer, AVAudioTime(sampleTime: AVAudioFramePosition(start), atRate: sampleRate))
        }
    }
}

/// Capture the block at the same Objective-C registration boundary as a real tap.
/// Registration/read happen on the test's main actor before background invocation.
private final class CapturingAudioNode: AVAudioMixerNode {
    var registeredTap: AVAudioNodeTapBlock?
    override func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                             format: AVAudioFormat?, block tapBlock: @escaping AVAudioNodeTapBlock) {
        registeredTap = tapBlock
    }
}

@Test @MainActor func audioTapRunsOnBackgroundQueue() async throws {
    let capture = MicrophoneCapture()
    let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                               channels: 1, interleaved: false)!
    let node = CapturingAudioNode()
    try capture.installTap(on: node, format: format, continuation: pair.continuation)
    let callback = BackgroundAudioCallback(callback: try #require(node.registeredTap))
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue(label: "nami.test.audio-callback").async {
            callback.invoke()
            done.resume()
        }
    }
    pair.continuation.finish()
    var chunks: [AudioChunk] = []
    for try await chunk in pair.stream { chunks.append(chunk) }
    #expect(chunks.count == 2)
    #expect(chunks.first?.timestamp == 0)
    if chunks.count == 2 {
        #expect(chunks[1].timestamp == Double(chunks[0].samples.count) / AudioChunk.sampleRate)
    }
    #expect(chunks.flatMap(\.samples).contains { abs($0) > 0.1 })
}

@Test(arguments: [16_000.0, 24_000.0, 44_100.0, 48_000.0, 96_000.0])
@MainActor func audioTapPreservesTenSeconds(sampleRate: Double) async throws {
    let capture = MicrophoneCapture()
    let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    let node = CapturingAudioNode()
    try capture.installTap(on: node, format: format, continuation: pair.continuation)
    let callback = BackgroundAudioCallback(callback: try #require(node.registeredTap))
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue(label: "nami.test.sustained-audio").async {
            callback.invokeTenSeconds(sampleRate: sampleRate)
            done.resume()
        }
    }
    capture.stop() // Includes draining the actual tap converter before EOF.
    var buffer = AudioSessionBuffer()
    let id = UUID()
    try buffer.start(id)
    for try await chunk in pair.stream { try buffer.append(chunk, sessionID: id) }
    let samples = try buffer.beginFinish(id)
    #expect(abs(samples.count - 160_000) <= 1)
    // Verify signal survived near both ends, not just that padding kept the length.
    for window in [Array(samples.prefix(16_000)), Array(samples.suffix(16_000))] {
        var statistics = AudioStatistics()
        statistics.append(window)
        #expect(statistics.rmsDBFS > -18 && statistics.rmsDBFS < -16)
    }
}

@Test func audioStatisticsMeasureLevelAndDuration() {
    var statistics = AudioStatistics()
    #expect(statistics.rmsDBFS == -.infinity)
    statistics.append(Array(repeating: 0.5, count: 8000))
    statistics.append(Array(repeating: -0.5, count: 8000))
    #expect(statistics.duration == 1)
    #expect(abs(statistics.rmsDBFS + 6.0206) < 0.001)
    #expect(abs(statistics.peakDBFS + 6.0206) < 0.001)
}
