import Foundation
import NamiCore
import NamiMLXCleanup
import Observation

@MainActor @Observable
final class CleanupService {
    private(set) var installed: Set<CleanupEngine> = []
    private(set) var downloadingEngine: CleanupEngine?
    private(set) var removingEngine: CleanupEngine?
    private(set) var downloadError: String?
    private(set) var warming = false
    var qwenInstalled: Bool { installed.contains(.qwen) }
    var downloading: Bool { downloadingEngine != nil }
    var managingModels: Bool { downloading || removingEngine != nil }
    var promptStore: PromptStore?
    let modelsRoot: URL
    @ObservationIgnored private let processors: [CleanupEngine: any TextProcessor]
    @ObservationIgnored private let runners: [CleanupEngine: CleanupRunner]
    @ObservationIgnored private let injected: Set<CleanupEngine>
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    init(processors overrides: [CleanupEngine: any TextProcessor] = [:], modelsRoot: URL = QwenModelAssets.root) {
        self.modelsRoot = modelsRoot
        var processors: [CleanupEngine: any TextProcessor] = [.vocabulary: VocabularyTextProcessor()]
        for model in QwenModel.allCases {
            processors[model.engine] = QwenTextProcessor(model: model, directory: QwenModelAssets.directory(for: model, root: modelsRoot))
        }
        processors.merge(overrides) { _, override in override }
        self.processors = processors
        runners = processors.mapValues { CleanupRunner(processor: $0) }
        injected = Set(overrides.keys)
        refreshAvailability()
    }

    func refreshAvailability() {
        installed = Set(QwenModel.allCases.filter {
            injected.contains($0.engine) || QwenModelAssets.isInstalled($0, at: folder(for: $0))
        }.map(\.engine))
    }

    func folder(for model: QwenModel) -> URL { QwenModelAssets.directory(for: model, root: modelsRoot) }
    func isInstalled(_ engine: CleanupEngine) -> Bool { installed.contains(engine) }
    var automaticEngine: CleanupEngine {
        installed.contains(.qwen) ? .qwen : (installed.contains(.qwen17) ? .qwen17 : (installed.contains(.qwen4) ? .qwen4 : .vocabulary))
    }

    func downloadQwen(_ engine: CleanupEngine = .qwen) {
        guard !managingModels, let model = QwenModel.model(for: engine) else { return }
        downloadingEngine = engine
        downloadError = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadingEngine = nil; self.downloadTask = nil; self.refreshAvailability() }
            do { try await QwenModelAssets.download(model, to: self.folder(for: model)) }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self.downloadError = error.localizedDescription } }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }

    func deleteQwen(_ model: QwenModel) async throws {
        guard !managingModels else { throw StudioError.message("Wait for the current model operation to finish.") }
        removingEngine = model.engine
        defer { removingEngine = nil; refreshAvailability() }
        // The maintenance flag closes the run/prewarm gate before any await.
        warmTask?.cancel()
        await warmTask?.value
        guard await runners[model.engine]?.isProcessing == false else {
            throw StudioError.message("This model is still processing. Wait for it to stop, then delete it.")
        }
        await processors[model.engine]?.unload()
        try QwenModelAssets.remove(model, root: modelsRoot)
    }

    /// Warm independently of microphone startup. Missing assets never download.
    func prewarm(_ engine: CleanupEngine) {
        refreshAvailability()
        guard warmTask == nil, removingEngine == nil else { return }
        let selected = engine == .automatic ? automaticEngine : engine
        guard let processor = processors[selected],
              QwenModel.model(for: selected) == nil || installed.contains(selected) else { return }
        warming = true
        warmTask = Task { [weak self] in
            defer { self?.warming = false; self?.warmTask = nil }
            try? await processor.prepare()
        }
    }

    func speculation(id: UUID, language: String, memory: CleanupMemory, engine: CleanupEngine, timeout: Double) -> SpeculativeCleanup? {
        let selected = engine == .automatic ? automaticEngine : engine
        let prompts = promptStore?.configuration ?? .init()
        // Only the validated, cooperative local model participates. Deterministic
        // sampling makes moving work earlier independent of other random draws.
        guard (selected == .qwen17 || selected == .qwen4), prompts.qwenGeneration.temperature == 0,
              !prompts.qwenGeneration.thinking, let processor = processors[selected] else { return nil }
        var request = CleanupRequest(id: id, rawText: "", language: language, memory: memory)
        request.prompts = prompts
        request.promptObserver = promptStore?.observer(source: "Speculative dictation cleanup")
        return SpeculativeCleanup(processor: processor, request: request,
            timeout: .seconds(min(30, max(0.05, timeout.isFinite ? timeout : 1))))
    }

    func run(_ request: CleanupRequest, engine: CleanupEngine, timeout: Double, source: String = "Cleanup") async throws -> CleanupResult {
        var request = request
        if let promptStore {
            request.prompts = promptStore.configuration
            request.promptObserver = promptStore.observer(source: source)
        }
        refreshAvailability()
        let selected = engine == .automatic ? automaticEngine : engine
        if removingEngine == selected {
            return CleanupResult(id: request.id, provider: processors[selected]!.identifier,
                rawText: request.rawText, text: request.rawText, outcome: .unavailable, elapsedSeconds: 0,
                preparationSeconds: nil, memoryRevision: request.memory.revision, reason: "Model deletion is in progress. Original text kept.")
        }
        let started = ContinuousClock.now
        let budget = min(30, max(0.05, timeout.isFinite ? timeout : 1))
        var result = try await runners[selected]!.run(request, timeout: .seconds(budget))
        promptStore?.record(result)
        if engine == .automatic, result.outcome == .unavailable {
            let order: [CleanupEngine] = [.qwen, .qwen17, .vocabulary]
            for fallback in order.drop(while: { $0 != selected }).dropFirst() {
                guard result.outcome == .unavailable else { break }
                if QwenModel.model(for: fallback) != nil && !installed.contains(fallback) { continue }
                if removingEngine == fallback { continue }
                let remaining = budget - Self.seconds(since: started)
                guard remaining > 0 else { break }
                result = try await runners[fallback]!.run(request, timeout: .seconds(remaining))
                promptStore?.record(result)
            }
        }
        try Task.checkCancellation()
        return result.withElapsedSeconds(Self.seconds(since: started))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
