import Foundation
import Testing
import NamiCore
@testable import NamiWhisperKit

@MainActor private final class Decoder {
    var inputs: [[Float]] = []
    var responses: [DecodedAudio] = []
    var blocked = false
    var failures = 0
    var active = 0
    var maximumActive = 0
    var honorCancellation = false
    var cancellations = 0

    func run(_ audio: [Float]) async throws -> DecodedAudio {
        inputs.append(audio)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        // Deliberately ignores cancellation, like a provider finishing a Core ML call.
        while blocked {
            if honorCancellation {
                do { try await Task.sleep(for: .milliseconds(1)) }
                catch { cancellations += 1; blocked = false; throw error }
            } else { await Task.yield() }
        }
        if failures > 0 { failures -= 1; throw EngineError.transcriptionFailed("retry") }
        return responses.isEmpty ? DecodedAudio(text: "Final words.", segments: []) : responses.removeFirst()
    }

    func session() -> StreamingTranscription {
        StreamingTranscription(onPartial: nil) { [self] audio in try await run(audio) }
    }
}

@MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
        if .now >= deadline { throw EngineError.transcriptionFailed("Test timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func chunk(_ seconds: Double, at timestamp: Double = 0, value: Float = 0.1) -> AudioChunk {
    AudioChunk(samples: Array(repeating: value, count: Int(seconds * 16000)), timestamp: timestamp)
}

@Test @MainActor func decodesBeforeStopAndReusesCompletedResult() async throws {
    let decoder = Decoder(), session = decoder.session()
    try session.append(chunk(2))
    try await waitFor { decoder.inputs.count == 1 && decoder.active == 0 }
    #expect(try await session.finish() == "Final words.")
    #expect(decoder.inputs.count == 1)
}

@Test @MainActor func stopIncludesLastSubsecondAudioAndConfirmedWordsOnlyOnce() async throws {
    let decoder = Decoder()
    decoder.responses = [
        DecodedAudio(text: "First. Middle. Unfinished", segments: [
            .init(start: 0, end: 2, text: "First."),
            .init(start: 2, end: 3, text: "Middle."),
            .init(start: 3, end: 4, text: "Unfinished")]),
        DecodedAudio(text: "Middle. Finished sentence.", segments: [])
    ]
    let session = decoder.session()
    try session.append(chunk(4))
    try await waitFor { decoder.inputs.count == 1 && decoder.active == 0 }
    try session.append(chunk(0.2, at: 4, value: 0.3))
    #expect(try await session.finish() == "First. Middle. Finished sentence.")
    #expect(decoder.inputs.map(\.count) == [64_000, 35_200])
    #expect(decoder.inputs.last?.suffix(3200).allSatisfy { $0 == 0.3 } == true)
}

@Test @MainActor func slowInferenceCoalescesAudioAndStopAwaitsTheInFlightDecode() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.blocked = true
    defer { decoder.blocked = false }
    try session.append(chunk(1))
    try await waitFor { decoder.active == 1 }
    for second in 1..<5 { try session.append(chunk(1, at: Double(second))) }
    var finished = false
    let result = Task { let text = try await session.finish(); finished = true; return text }
    await Task.yield()
    #expect(!finished && decoder.inputs.count == 1)
    decoder.blocked = false
    #expect(try await result.value == "Final words.")
    #expect(decoder.inputs.map(\.count) == [16_000, 80_000])
    #expect(decoder.maximumActive == 1)
}

@Test @MainActor func speculativeFailureRetainsAudioForFinalRetry() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.failures = 1
    try session.append(chunk(1))
    try await waitFor { decoder.inputs.count == 1 && decoder.active == 0 }
    try session.append(chunk(0.1, at: 1))
    #expect(try await session.finish() == "Final words.")
    #expect(decoder.inputs.map(\.count) == [16_000, 17_600])
}

@Test @MainActor func shortRecordingsFlushWithoutWaitingForStreamingInterval() async throws {
    let decoder = Decoder(), session = decoder.session()
    try session.append(chunk(0.1))
    #expect(decoder.inputs.isEmpty)
    #expect(try await session.finish() == "Final words.")
    #expect(decoder.inputs.first?.count == 1600)
}

@Test @MainActor func cancellationWaitsForLateDecoderAndRejectsItsResult() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.blocked = true
    defer { decoder.blocked = false }
    try session.append(chunk(0.1))
    let finishing = Task { try await session.finish() }
    try await waitFor { decoder.active == 1 }
    var cancelled = false
    let cancellation = Task { await session.cancel(); cancelled = true }
    await Task.yield()
    #expect(!cancelled)
    decoder.blocked = false
    await cancellation.value
    do { _ = try await finishing.value; Issue.record("Cancelled inference returned a transcript") }
    catch { #expect(error is CancellationError || error as? EngineError == .cancelled) }
    #expect(decoder.active == 0)
    #expect(throws: EngineError.invalidState) { try session.append(chunk(1, at: 0.1)) }
}

@Test @MainActor func invalidAudioAndDuplicateFinishAreRejected() async throws {
    let decoder = Decoder(), session = decoder.session()
    #expect(throws: EngineError.invalidAudio) { try session.append(chunk(0.1, at: 1)) }
    #expect(throws: EngineError.invalidAudio) { try session.append(chunk(0.1, value: .nan)) }
    try session.append(chunk(0.1))
    _ = try await session.finish()
    await #expect(throws: EngineError.invalidState) { try await session.finish() }
}

@Test @MainActor func invalidTimestampsDoNotDiscardUnconfirmedSpeech() async throws {
    let decoder = Decoder()
    decoder.responses = [DecodedAudio(text: "All speech.", segments: [
        .init(start: 0, end: 99, text: "Bad boundary"),
        .init(start: 1, end: 2, text: "Tail"),
        .init(start: 2, end: 3, text: "Tail")])]
    let session = decoder.session()
    try session.append(chunk(4))
    try await waitFor { decoder.inputs.count == 1 && decoder.active == 0 }
    try session.append(chunk(0.1, at: 4))
    _ = try await session.finish()
    #expect(decoder.inputs.last?.count == 65_600)
}

@Test @MainActor func consecutiveConfirmationsUseRelativeTimestampsWithoutRepeatingWords() async throws {
    let decoder = Decoder()
    decoder.responses = [
        DecodedAudio(text: "One. Two. Three.", segments: [
            .init(start: 0, end: 1, text: "One."), .init(start: 1, end: 2, text: "Two."),
            .init(start: 2, end: 3, text: "Three.")]),
        DecodedAudio(text: "Two. Three. Four.", segments: [
            .init(start: 0, end: 1, text: "Two."), .init(start: 1, end: 2, text: "Three."),
            .init(start: 2, end: 3, text: "Four.")]),
        DecodedAudio(text: "Three. Four. Five.", segments: [])
    ]
    let session = decoder.session()
    try session.append(chunk(3))
    try await waitFor { decoder.inputs.count == 1 && decoder.active == 0 }
    try session.append(chunk(1, at: 3))
    try await waitFor { decoder.inputs.count == 2 && decoder.active == 0 }
    try session.append(chunk(0.1, at: 4))
    #expect(try await session.finish() == "One. Two. Three. Four. Five.")
    #expect(decoder.inputs.map(\.count) == [48_000, 48_000, 33_600])
}

@Test @MainActor func cancellingFinishTaskWaitsForBackgroundInferenceWithoutPublishing() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.blocked = true
    defer { decoder.blocked = false }
    try session.append(chunk(1))
    try await waitFor { decoder.active == 1 }
    let finishing = Task { try await session.finish() }
    await Task.yield()
    finishing.cancel()
    decoder.blocked = false
    do { _ = try await finishing.value; Issue.record("Cancelled finish returned a transcript") }
    catch { #expect(error is CancellationError || error as? EngineError == .cancelled) }
    #expect(decoder.active == 0)
}

@Test @MainActor func stopCancelsAnOutdatedDecodeBeforeFlushingTheNewestAudio() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.blocked = true; decoder.honorCancellation = true
    defer { decoder.blocked = false }
    try session.append(chunk(1))
    try await waitFor { decoder.active == 1 }
    try session.append(chunk(0.1, at: 1))
    #expect(try await session.finish() == "Final words.")
    #expect(decoder.cancellations == 1)
    #expect(decoder.inputs.map(\.count) == [16_000, 17_600])
    #expect(decoder.maximumActive == 1)
}

@Test @MainActor func stopReusesAnInFlightDecodeThatAlreadyHasAllTheAudio() async throws {
    let decoder = Decoder(), session = decoder.session()
    decoder.blocked = true
    defer { decoder.blocked = false }
    try session.append(chunk(1))
    try await waitFor { decoder.active == 1 }
    let finish = Task { try await session.finish() }
    await Task.yield()
    decoder.blocked = false
    #expect(try await finish.value == "Final words.")
    #expect(decoder.inputs.count == 1 && decoder.cancellations == 0)
}
