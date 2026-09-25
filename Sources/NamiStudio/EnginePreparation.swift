import Foundation
import NamiCore

/// One shared preparation per model. Cancelling a recording removes only its
/// waiter; loading continues so the next recording can use the warmed engine.
@MainActor
final class EnginePreparation {
    let engine: any TranscriptionEngine
    private(set) var result: Result<Void, Error>?
    private var work: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(engine: any TranscriptionEngine, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        self.engine = engine
        work = Task { [weak self, engine] in
            let result: Result<Void, Error>
            do {
                try await engine.prepare()
                try Task.checkCancellation()
                result = .success(())
            } catch { result = .failure(error) }
            guard let self else { return }
            self.result = result
            self.work = nil
            let pending = self.waiters
            self.waiters.removeAll()
            completion(result)
            for waiter in pending.values { waiter.resume(with: result) }
        }
    }

    var failed: Bool {
        if case .failure = result { return true }
        return false
    }

    func value() async throws -> any TranscriptionEngine {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let result { continuation.resume(with: result) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        return engine
    }

    func cancel() { work?.cancel() }
    deinit { work?.cancel() }
}
