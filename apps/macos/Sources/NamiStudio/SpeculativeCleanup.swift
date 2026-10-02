import Foundation
import NamiCore

/// Work ahead on complete provisional transcripts. A result can be reused only
/// when the final raw text, language, memory and prompts are exactly unchanged.
/// No partial result is published, concatenated or treated as committed speech.
@MainActor final class SpeculativeCleanup {
    private let runner: CleanupRunner
    private let request: CleanupRequest
    private let timeout: Duration
    private var pending = ""
    private var current = ""
    private var cached: CleanupResult?
    private var work: Task<Void, Never>?
    private var attempt: Task<CleanupResult, Error>?
    private var finishing = false
    private var recordingFinished = false
    private var recordGeneration = UUID()
    private var records: [ModelPromptRecord] = []

    init(processor: any TextProcessor, request: CleanupRequest, timeout: Duration) {
        runner = CleanupRunner(processor: processor)
        self.request = request; self.timeout = timeout
    }

    func offer(_ text: String) {
        guard !finishing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != pending else { return }
        pending = text
        if recordingFinished, current != pending { attempt?.cancel() }
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.work = nil; self.attempt = nil }
            while !self.finishing, !Task.isCancelled, self.current != self.pending {
                self.current = self.pending
                var request = self.request; request.rawText = self.current
                // Discarded previews must not continually rewrite the user's
                // prompt history or evict useful final-request diagnostics.
                let generation = UUID()
                self.recordGeneration = generation; self.records = []
                request.promptObserver = { [weak self] record in
                    await self?.capture(record, generation: generation)
                }
                let runner = self.runner, timeout = self.timeout
                let attempt = Task { try await runner.run(request, timeout: timeout) }
                self.attempt = attempt
                do {
                    self.cached = try await withTaskCancellationHandler { try await attempt.value }
                        onCancel: { attempt.cancel() }
                } catch {
                    await runner.cancelAndWait()
                    if Task.isCancelled || !self.recordingFinished { return }
                }
                self.attempt = nil
            }
        }
    }

    /// Once capture stops, an obsolete preview must not queue ahead of the last
    /// one. Join its cancelled model work while final recognition runs in parallel.
    func recordingEnded() {
        recordingFinished = true
        if current != pending { attempt?.cancel() }
    }

    func finish(matching final: CleanupRequest) async throws -> CleanupResult? {
        finishing = true
        let sameContext = final.language == request.language && final.memory == request.memory && final.prompts == request.prompts
        if sameContext, current == final.rawText {
            let work = work
            await withTaskCancellationHandler { await work?.value } onCancel: { work?.cancel() }
            try Task.checkCancellation()
            if let cached, cached.rawText == final.rawText, cached.succeeded {
                for record in records { await request.promptObserver?(record) }
                return cached
            }
        }
        await cancel()
        try Task.checkCancellation()
        return nil
    }

    func cancel() async {
        finishing = true
        work?.cancel()
        attempt?.cancel()
        await work?.value
        await runner.cancelAndWait()
        cached = nil; pending = ""; current = ""; records = []
    }

    private func capture(_ record: ModelPromptRecord, generation: UUID) {
        guard generation == recordGeneration else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }

}
