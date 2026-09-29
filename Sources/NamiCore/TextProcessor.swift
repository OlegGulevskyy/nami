import Foundation

public struct CleanupRequest: Sendable {
    public var id: UUID
    public var rawText: String
    public var language: String
    public var memory: CleanupMemory
    public var prompts = PromptConfiguration()
    public var promptObserver: ModelPromptObserver?

    public init(id: UUID = UUID(), rawText: String, language: String = "en", memory: CleanupMemory = .init()) {
        self.id = id
        self.rawText = rawText
        self.language = language
        self.memory = memory
    }
}

public protocol TextProcessor: Sendable {
    var identifier: String { get }
    func prepare() async throws
    func process(_ request: CleanupRequest) async throws -> String
    func unload() async
}

public extension TextProcessor {
    func unload() async {}
}

public enum CleanupFailure: Error, LocalizedError, Sendable {
    case unavailable(String), refused(String), invalidOutput, outputLimitReached

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .refused(let reason): reason
        case .invalidOutput: "The model returned incomplete text or an invalid format. Original text kept."
        case .outputLimitReached: "The model reached its output limit before finishing. Original text kept."
        }
    }
}

public struct CleanupResult: Codable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case cleaned, unchanged, unavailable, refused, invalidOutput, timedOut, busy, failed
    }
    public let id: UUID
    public let provider: String
    public let rawText: String
    public let text: String
    public let outcome: Outcome
    /// Total wall time, including preparation, until usable text or fallback.
    public let elapsedSeconds: Double
    public let preparationSeconds: Double?
    public let memoryRevision: Int
    public let reason: String?
    /// Diagnostic only; never selected for copying, pasting, or teaching.
    public var rejectedText: String? = nil

    public init(id: UUID, provider: String, rawText: String, text: String, outcome: Outcome,
                elapsedSeconds: Double, preparationSeconds: Double?, memoryRevision: Int,
                reason: String?, rejectedText: String? = nil) {
        self.id = id; self.provider = provider; self.rawText = rawText; self.text = text; self.outcome = outcome
        self.elapsedSeconds = elapsedSeconds; self.preparationSeconds = preparationSeconds
        self.memoryRevision = memoryRevision; self.reason = reason; self.rejectedText = rejectedText
    }

    public var succeeded: Bool { outcome == .cleaned || outcome == .unchanged }
    public func withElapsedSeconds(_ seconds: Double) -> Self {
        Self(id: id, provider: provider, rawText: rawText, text: text, outcome: outcome,
             elapsedSeconds: seconds, preparationSeconds: preparationSeconds, memoryRevision: memoryRevision, reason: reason,
             rejectedText: rejectedText)
    }
}

public struct VocabularyTextProcessor: TextProcessor {
    public let identifier = "vocabulary-v1"
    public init() {}
    public func prepare() async throws {}
    public func process(_ request: CleanupRequest) async throws -> String {
        try Task.checkCancellation()
        return request.memory.replacingVocabulary(in: request.rawText, language: request.language)
    }
}

/// One outstanding provider operation, even when an SDK ignores cancellation.
/// Unstructured work is intentional: a structured task group would wait for an
/// uncooperative provider before returning the deadline fallback.
public actor CleanupRunner {
    private let processor: any TextProcessor
    private var activeID: UUID?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<CleanupResult, Error>?

    public init(processor: any TextProcessor) { self.processor = processor }

    public var isProcessing: Bool { activeID != nil }

    public func run(_ request: CleanupRequest, timeout: Duration = .seconds(1)) async throws -> CleanupResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        guard !request.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(request, started: started, outcome: .unchanged)
        }
        guard activeID == nil else {
            return result(request, started: started, outcome: .busy, reason: "Previous model work is still stopping.")
        }
        let operationID = UUID()
        activeID = operationID
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                worker = Task { [processor] in
                    var preparation: Double?
                    let completion: Result<String, Error>
                    do {
                        try await processor.prepare()
                        preparation = Self.seconds(since: started)
                        try Task.checkCancellation()
                        let text = try await processor.process(request)
                        try Task.checkCancellation()
                        completion = .success(text)
                    } catch { completion = .failure(error) }
                    self.complete(operationID, request: request, started: started,
                                  deadline: started.advanced(by: timeout), preparation: preparation, completion: completion)
                }
                timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.expire(operationID, request: request, started: started)
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { await self.cancel(operationID) }
        }
    }

    private func complete(_ id: UUID, request: CleanupRequest, started: ContinuousClock.Instant,
                          deadline: ContinuousClock.Instant, preparation: Double?, completion: Result<String, Error>) {
        guard activeID == id else { return }
        defer { activeID = nil; worker = nil; timer?.cancel(); timer = nil; continuation = nil }
        guard let continuation else { return } // Late result after cancellation/deadline.
        // Enforce wall time even if scheduling delayed the watchdog task.
        guard ContinuousClock.now < deadline else {
            continuation.resume(returning: result(request, started: started, preparation: preparation,
                outcome: .timedOut, reason: "Cleanup exceeded its deadline; original text retained."))
            return
        }
        switch completion {
        case .success(let output):
            if let reason = CleanupOutput.rejectionReason(output, original: request.rawText) {
                continuation.resume(returning: result(request, started: started, preparation: preparation,
                    outcome: .invalidOutput, reason: reason, rejectedText: output))
                return
            }
            continuation.resume(returning: result(request, started: started, preparation: preparation,
                text: output, outcome: output == request.rawText ? .unchanged : .cleaned))
        case .failure(let error):
            if error is CancellationError { continuation.resume(throwing: CancellationError()); return }
            let outcome: CleanupResult.Outcome
            switch error {
            case CleanupFailure.unavailable: outcome = .unavailable
            case CleanupFailure.refused: outcome = .refused
            case CleanupFailure.invalidOutput, CleanupFailure.outputLimitReached: outcome = .invalidOutput
            default: outcome = .failed
            }
            continuation.resume(returning: result(request, started: started, preparation: preparation,
                outcome: outcome, reason: error.localizedDescription))
        }
    }

    private func expire(_ id: UUID, request: CleanupRequest, started: ContinuousClock.Instant) {
        guard activeID == id, let continuation else { return }
        self.continuation = nil
        worker?.cancel()
        continuation.resume(returning: result(request, started: started, outcome: .timedOut,
            reason: "Cleanup exceeded its deadline; original text retained."))
    }

    private func cancel(_ id: UUID) {
        guard activeID == id else { return }
        worker?.cancel()
        timer?.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func result(_ request: CleanupRequest, started: ContinuousClock.Instant,
                        preparation: Double? = nil, text: String? = nil,
                        outcome: CleanupResult.Outcome, reason: String? = nil, rejectedText: String? = nil) -> CleanupResult {
        CleanupResult(id: request.id, provider: processor.identifier, rawText: request.rawText,
                      text: text ?? request.rawText, outcome: outcome,
                      elapsedSeconds: Self.seconds(since: started), preparationSeconds: preparation,
                      memoryRevision: request.memory.revision, reason: reason,
                      rejectedText: rejectedText.map { String($0.prefix(8_000)) })
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
