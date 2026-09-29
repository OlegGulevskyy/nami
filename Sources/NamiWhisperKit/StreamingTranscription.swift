import Foundation
import NamiCore

/// Provider-independent snapshots keep the streaming scheduler testable without loading Core ML.
struct DecodedSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct DecodedAudio: Sendable {
    let text: String
    let segments: [DecodedSegment]
}

/// One worker coalesces arriving audio instead of queuing an inference for every mic buffer.
/// Like WhisperKit's streaming example, retain the last two segments for revision.
@MainActor
final class StreamingTranscription {
    typealias Decode = @Sendable ([Float]) async throws -> DecodedAudio
    private let decode: Decode
    private let onPartial: (@Sendable (String) -> Void)?
    private let intervalSamples: Int
    private var pending: [Float] = []
    private var receivedSamples = 0
    private var decodedSamples = 0
    private var inFlightSamples: Int?
    private var confirmedText: [String] = []
    private var latestText = ""
    private var worker: Task<Void, Never>?
    private var finalWork: Task<String, Error>?
    private var finishing = false
    private var cancelled = false
    private var backgroundFailed = false

    init(intervalSamples: Int = 16_000, onPartial: (@Sendable (String) -> Void)?, decode: @escaping Decode) {
        self.intervalSamples = intervalSamples
        self.onPartial = onPartial
        self.decode = decode
    }

    func append(_ chunk: AudioChunk) throws {
        guard !finishing, !cancelled else { throw EngineError.invalidState }
        guard chunk.timestamp.isFinite,
              abs(chunk.timestamp - Double(receivedSamples) / AudioChunk.sampleRate) < 1 / AudioChunk.sampleRate,
              chunk.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw EngineError.invalidAudio }
        pending.append(contentsOf: chunk.samples)
        receivedSamples += chunk.samples.count
        guard worker == nil, !backgroundFailed, receivedSamples - decodedSamples >= intervalSamples else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !self.finishing, !self.cancelled,
                  self.receivedSamples - self.decodedSamples >= self.intervalSamples {
                do { try await self.decodePending() }
                catch {
                    // Keep all unconfirmed audio and retry it once at Stop. A speculative
                    // decode failure must neither terminate capture nor lose the recording.
                    self.backgroundFailed = true
                    return
                }
            }
        }
    }

    func finish() async throws -> String {
        guard !finishing, !cancelled else { throw EngineError.invalidState }
        guard receivedSamples > 0 else { throw EngineError.noAudio }
        finishing = true
        // A stale decode cannot produce the final text. Stop it at the provider's
        // next cancellation point instead of paying for it and then decoding again.
        if inFlightSamples != receivedSamples { worker?.cancel() }
        let work = Task {
            await self.worker?.value
            try self.checkCancellation()
            // Reuse an in-flight result if it already includes the final mic buffer.
            if self.decodedSamples != self.receivedSamples { try await self.decodePending() }
            try self.checkCancellation()
            return self.latestText
        }
        finalWork = work
        defer { finalWork = nil }
        return try await withTaskCancellationHandler {
            let text = try await work.value
            try checkCancellation()
            return text
        } onCancel: { work.cancel(); Task { @MainActor in self.worker?.cancel() } }
    }

    func cancel() async {
        cancelled = true
        let work = worker
        let final = finalWork
        work?.cancel()
        final?.cancel()
        await work?.value
        _ = await final?.result
        pending = []
        confirmedText = []
        latestText = ""
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw EngineError.cancelled }
    }

    private func decodePending() async throws {
        try checkCancellation()
        let count = receivedSamples
        let audio = pending
        inFlightSamples = count
        defer { inFlightSamples = nil }
        let result = try await decode(audio)
        try checkCancellation()
        latestText = (confirmedText + [result.text]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        decodedSamples = count
        if !finishing {
            // Never trim on malformed/out-of-order timestamps or right at the audio edge.
            let safeEnd = Double(audio.count) / AudioChunk.sampleRate - 1
            var end = 0.0
            var confirmed: [String] = []
            for segment in result.segments.dropLast(2) {
                guard segment.start.isFinite, segment.end.isFinite,
                      segment.start >= end, segment.end > segment.start,
                      segment.end <= safeEnd else { break }
                confirmed.append(segment.text)
                end = segment.end
            }
            let trim = Int((end * AudioChunk.sampleRate).rounded())
            if trim > 0 {
                confirmedText += confirmed
                pending.removeFirst(trim)
            }
            onPartial?(latestText)
        }
    }
}
