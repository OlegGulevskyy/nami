import Foundation

/// Portable capture format: mono Float32 PCM, 16,000 Hz, normalized to [-1, 1].
/// Timestamp is the first sample's offset in seconds from the session start.
/// Adapters own any additional provider-specific conversion and buffering.
public struct AudioChunk: Sendable {
    public static let sampleRate = 16_000.0
    public let samples: [Float]
    public let timestamp: TimeInterval

    public init(samples: [Float], timestamp: TimeInterval) {
        self.samples = samples
        self.timestamp = timestamp
    }
}

public struct EngineCapabilities: Sendable {
    public let incrementalProcessing: Bool
    public let requiresNetwork: Bool
    public init(incrementalProcessing: Bool, requiresNetwork: Bool) {
        self.incrementalProcessing = incrementalProcessing
        self.requiresNetwork = requiresNetwork
    }
}

public enum EngineError: Error, Equatable, Sendable, LocalizedError {
    case notPrepared, invalidState, invalidAudio, noAudio, cancelled
    case modelUnavailable(String), transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared: "Prepare the engine before starting a session."
        case .invalidState: "The engine cannot perform this operation in its current state."
        case .invalidAudio: "Audio must be finite, contiguous mono 16 kHz PCM, at most 60 seconds."
        case .noAudio: "The session contains no audio."
        case .cancelled: "Transcription was cancelled."
        case .modelUnavailable(let message): "Model unavailable: \(message)"
        case .transcriptionFailed(let message): "Transcription failed: \(message)"
        }
    }
}

/// Partial results are optional. Exactly one final result is returned by finish.
/// A cancelled session must never return a final result, even if inference completes late.
/// Model preparation may download only when explicitly enabled by configuration.
@MainActor
public protocol TranscriptionEngine: AnyObject {
    var capabilities: EngineCapabilities { get }
    func prepare() async throws
    /// Vocabulary provides optional recognition hints, snapshotted for this session.
    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws
    func finish(sessionID: UUID) async throws -> String
    func cancel(sessionID: UUID) async
}

public extension TranscriptionEngine {
    func start(sessionID: UUID, language: String?, onPartial: (@Sendable (String) -> Void)?) async throws {
        try await start(sessionID: sessionID, language: language, vocabulary: "", onPartial: onPartial)
    }
}

/// Shared lifecycle validation for batch adapters; guards against duplicate final results
/// and late completion from a cancelled or superseded session.
public struct AudioSessionBuffer {
    private var sessionID: UUID?
    private var finishing = false
    private var samples: [Float] = []
    public init() {}

    public mutating func start(_ id: UUID) throws {
        guard sessionID == nil else { throw EngineError.invalidState }
        sessionID = id
        finishing = false
        samples = []
    }

    public mutating func append(_ chunk: AudioChunk, sessionID id: UUID) throws {
        guard sessionID == id, !finishing else { throw EngineError.invalidState }
        guard chunk.timestamp.isFinite,
              abs(chunk.timestamp - Double(samples.count) / AudioChunk.sampleRate) < 1 / AudioChunk.sampleRate,
              chunk.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              samples.count + chunk.samples.count <= 60 * Int(AudioChunk.sampleRate)
        else { throw EngineError.invalidAudio }
        samples.append(contentsOf: chunk.samples)
    }

    public mutating func beginFinish(_ id: UUID) throws -> [Float] {
        guard sessionID == id, !finishing else { throw EngineError.invalidState }
        guard !samples.isEmpty else { throw EngineError.noAudio }
        finishing = true
        let audio = samples
        samples = []
        return audio
    }

    public mutating func complete(_ id: UUID) throws {
        guard sessionID == id, finishing else { throw EngineError.cancelled }
        sessionID = nil
        finishing = false
    }

    public mutating func cancel(_ id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        finishing = false
        samples = []
    }
}

@MainActor
public final class FakeTranscriptionEngine: TranscriptionEngine {
    public let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: false)
    private let transcript: String
    private let delay: Duration
    private var prepared = false
    private var buffer = AudioSessionBuffer()

    public init(transcript: String = "This is a fake transcript.", delay: Duration = .zero) {
        self.transcript = transcript
        self.delay = delay
    }
    public func prepare() async throws { prepared = true }
    public func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        try buffer.start(sessionID)
    }
    public func append(_ chunk: AudioChunk, sessionID: UUID) async throws {
        try buffer.append(chunk, sessionID: sessionID)
    }
    public func finish(sessionID: UUID) async throws -> String {
        _ = try buffer.beginFinish(sessionID)
        do {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            try buffer.complete(sessionID)
            return transcript
        } catch {
            buffer.cancel(sessionID)
            throw EngineError.cancelled
        }
    }
    public func cancel(sessionID: UUID) async { buffer.cancel(sessionID) }
}
