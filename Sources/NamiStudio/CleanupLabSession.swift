import Darwin
import Foundation
import NamiCore
import Observation

struct CleanupLabRun: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var language: String
    var deadlineSeconds: Double
    var usedMemory: Bool
    var results: [CleanupResult]
}

private struct CleanupLabWorkspace: Codable {
    var version = 1
    var memory = CleanupMemory()
    var runs: [CleanupLabRun] = []
    var comparisonEngines: [CleanupEngine]?
    var useMemory: Bool?
    var deadlineSeconds: Double?
}

@MainActor @Observable
final class CleanupLabSession {
    var input = ""
    var language = "en"
    var useMemory = true
    var deadlineSeconds = 10.0
    var correctedText = ""
    var compareApple = true
    var compareQwen = true
    var compareQwen17 = false
    var teachingProvider: String?
    var showingCorrectionEditor = false
    private(set) var memory = CleanupMemory()
    private(set) var runs: [CleanupLabRun] = []
    private(set) var isBusy = false
    private(set) var loadFailed = false
    var errorMessage: String?
    private(set) var status = ""
    let service: CleanupService

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var loadedData: Data?
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(directory: URL, processor: (any TextProcessor)? = nil, service: CleanupService? = nil) {
        self.directory = directory
        self.service = service ?? CleanupService(processors: processor.map { [.apple: $0] } ?? [:])
        if processor != nil { compareQwen = false }
        do {
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let data = try Data(contentsOf: metadataURL)
                let workspace = try JSONDecoder().decode(CleanupLabWorkspace.self, from: data)
                guard workspace.version == 1, workspace.memory.version == 1 else {
                    throw StudioError.message("Unsupported cleanup workspace version.")
                }
                memory = workspace.memory
                runs = workspace.runs
                if let engines = workspace.comparisonEngines {
                    compareApple = engines.contains(.apple)
                    compareQwen = engines.contains(.qwen)
                    compareQwen17 = engines.contains(.qwen17)
                }
                useMemory = workspace.useMemory ?? true
                deadlineSeconds = workspace.deadlineSeconds ?? 10
                loadedData = data
                correctedText = teachingResult?.text ?? ""
            }
        } catch {
            loadFailed = true
            errorMessage = "Could not load cleanup experiments. Existing files have been kept: \(error.localizedDescription)"
        }
    }

    private var metadataURL: URL { directory.appendingPathComponent("workspace.json") }
    var latestRun: CleanupLabRun? { runs.last }
    var teachingResult: CleanupResult? {
        latestRun?.results.last {
            (teachingProvider == nil || $0.provider == teachingProvider) && $0.succeeded
                && !CleanupOutput.isFormatLeak($0.text, original: $0.rawText)
        }
    }
    var canTeach: Bool {
        guard let result = teachingResult else { return false }
        return !isBusy && !loadFailed && !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && correctedText != result.text && correctedText.utf8.count <= 2_000
            && !CleanupOutput.isFormatLeak(correctedText, original: result.rawText)
    }

    func compare() {
        guard !isBusy, !loadFailed, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.utf8.count <= 20_000 else { return }
        let request = CleanupRequest(rawText: input, language: language, memory: useMemory ? memory : .init())
        let deadline = deadlineSeconds
        let usedMemory = useMemory
        let engines: [CleanupEngine] = [.vocabulary] + (compareApple ? [.apple] : []) + (compareQwen ? [.qwen] : []) + (compareQwen17 ? [.qwen17] : [])
        isBusy = true
        errorMessage = nil
        status = "Comparing local text processors…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.operation = nil }
            do {
                var results: [CleanupResult] = []
                for engine in engines {
                    try Task.checkCancellation()
                    self.status = "Running \(engine.title)…"
                    results.append(try await self.service.run(request, engine: engine, timeout: deadline, source: "Playground cleanup"))
                }
                try Task.checkCancellation()
                var updatedRuns = self.runs
                updatedRuns.append(CleanupLabRun(language: request.language, deadlineSeconds: deadline,
                                                 usedMemory: usedMemory, results: results))
                try self.persist(memory: self.memory, runs: Array(updatedRuns.suffix(50)))
                self.teachingProvider = nil
                self.correctedText = self.teachingResult?.text ?? ""
                self.showingCorrectionEditor = false
                self.status = ""
            } catch is CancellationError {
                self.status = "Comparison cancelled."
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancel() { operation?.cancel() }

    func editCorrection(for result: CleanupResult) {
        guard !isBusy, result.succeeded, !CleanupOutput.isFormatLeak(result.text, original: result.rawText) else { return }
        teachingProvider = result.provider
        correctedText = result.text
        showingCorrectionEditor = true
    }

    func savePreferences() {
        guard !isBusy, !loadFailed else { return }
        do { try persist(memory: memory, runs: runs) }
        catch { errorMessage = error.localizedDescription }
    }

    func addVocabulary(heard: String, replacement: String) {
        guard !isBusy, !loadFailed else { return }
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !replacement.isEmpty, heard != replacement,
              heard.utf8.count <= 160, replacement.utf8.count <= 160 else {
            errorMessage = "Enter two different, nonempty phrases of at most 160 UTF-8 bytes each."
            return
        }
        guard memory.vocabulary.count < 200,
              !memory.vocabulary.contains(where: { $0.language == language && $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) else {
            errorMessage = "That phrase already has a rule, or the experiment's 200-rule limit was reached. Remove a rule first."
            return
        }
        updateMemory { $0.vocabulary.append(.init(heard: heard, replacement: replacement, language: language)) }
    }

    func teachCorrection() {
        guard canTeach, let result = teachingResult, let run = latestRun else { return }
        guard memory.examples.count < 200 else {
            errorMessage = "The experiment's 200-example limit was reached. Remove an example first."
            return
        }
        guard !memory.examples.contains(where: {
            $0.language == run.language && $0.rawText == result.rawText && $0.correctedText == correctedText
        }) else { status = "This correction is already saved."; return }
        let example = CleanupExample(rawText: result.rawText, generatedText: result.text,
                                     correctedText: correctedText, language: run.language,
                                     sourceRunID: run.id, processorID: result.provider,
                                     memoryRevision: result.memoryRevision, feedbackSource: "cleanup-lab-explicit")
        updateMemory { $0.examples.append(example) }
        if errorMessage == nil { showingCorrectionEditor = false }
    }

    func removeVocabulary(_ id: UUID) { updateMemory { $0.vocabulary.removeAll { $0.id == id } } }
    func removeExample(_ id: UUID) { updateMemory { $0.examples.removeAll { $0.id == id } } }

    private func updateMemory(_ change: (inout CleanupMemory) -> Void) {
        guard !isBusy, !loadFailed else { return }
        var updated = memory
        change(&updated)
        updated.revision += 1
        do {
            try persist(memory: updated, runs: runs)
            errorMessage = nil
            status = "Saved."
        } catch { errorMessage = error.localizedDescription }
    }

    /// Separate from ASR evaluation/history; conflicting writers cannot overwrite each other.
    private func persist(memory: CleanupMemory, runs: [CleanupLabRun]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StudioError.message("Cannot lock cleanup workspace.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw StudioError.message("Another process is saving cleanup experiments. Try again shortly.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let current = try FileManager.default.fileExists(atPath: metadataURL.path) ? Data(contentsOf: metadataURL) : nil
        guard current == loadedData else {
            throw StudioError.message("Cleanup experiments changed in another process. Reopen Nami before saving.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let engines: [CleanupEngine] = (compareApple ? [.apple] : []) + (compareQwen ? [.qwen] : []) + (compareQwen17 ? [.qwen17] : [])
        let data = try encoder.encode(CleanupLabWorkspace(memory: memory, runs: runs,
            comparisonEngines: engines, useMemory: useMemory, deadlineSeconds: deadlineSeconds))
        try data.write(to: metadataURL, options: .atomic)
        loadedData = data
        self.memory = memory
        self.runs = runs
    }
}
