import AppKit
import AVFoundation
import Foundation
import Observation
import NamiAudio
import NamiCore
import NamiWhisperKit

/// An isolated test bench: it never changes dictation settings or writes to the
/// clipboard. Every model sees the same saved audio and reference snapshot.
@MainActor @Observable
public final class DebuggingSession {
    private(set) var workspace = DebugWorkspace()
    var selectedSampleID: UUID?
    private(set) var isBusy = false
    private(set) var recording = false
    private(set) var cancelling = false
    private(set) var elapsed = 0.0
    private(set) var level = 0.0
    private(set) var status = "Create a sample to get started."
    var errorMessage: String?
    private(set) var loadFailed = false
    private(set) var unsaved = false
    private(set) var availableModels: [String] = []
    private(set) var playing = false

    @ObservationIgnored private let store: DebuggingStore
    @ObservationIgnored private let engineBuilder: @MainActor (String) throws -> any TranscriptionEngine
    @ObservationIgnored private let captureBuilder: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var capture: (any AudioCapturing)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    init(directory: URL,
         engineBuilder: @escaping @MainActor (String) throws -> any TranscriptionEngine = { WhisperKitEngine(modelFolder: $0) },
         captureBuilder: @escaping @MainActor (String?) -> any AudioCapturing = { MicrophoneCapture(deviceUID: $0) }) {
        store = DebuggingStore(directory: directory)
        self.engineBuilder = engineBuilder
        self.captureBuilder = captureBuilder
        do {
            workspace = try store.load()
            selectedSampleID = workspace.samples.first?.id
        } catch {
            loadFailed = true
            errorMessage = "Could not load internal debugging: \(error.localizedDescription)"
        }
    }

    var directory: URL { store.directory }
    var selectedSample: DebugSample? { workspace.samples.first { $0.id == selectedSampleID } }
    var selectedResults: [DebugResult] { workspace.results.filter { $0.sampleID == selectedSampleID }.reversed() }
    var canRun: Bool { !isBusy && !loadFailed && workspace.models.contains(where: \.enabled) && selectedSample != nil }

    func save() {
        guard !loadFailed else { return }
        do { try store.save(workspace); unsaved = false }
        catch { unsaved = true; errorMessage = "Changes are in memory but could not be saved: \(error.localizedDescription)" }
    }

    func updateSample(_ id: UUID, title: String? = nil, expectedText: String? = nil, language: String? = nil) {
        guard !isBusy, !loadFailed, let index = workspace.samples.firstIndex(where: { $0.id == id }) else { return }
        if let title { workspace.samples[index].title = String(title.prefix(160)) }
        if let expectedText { workspace.samples[index].expectedText = String(expectedText.prefix(20_000)) }
        if let language { workspace.samples[index].language = language }
        save()
    }

    func addModel(folder: URL) {
        guard !loadFailed else { return }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard !workspace.models.contains(where: { $0.folder == path }) else { return }
        workspace.models.append(DebugModel(name: folder.lastPathComponent, folder: path))
        save()
    }

    func setModelEnabled(_ id: String, enabled: Bool) {
        guard !isBusy, let index = workspace.models.firstIndex(where: { $0.id == id }) else { return }
        workspace.models[index].enabled = enabled
        save()
    }

    func removeModel(_ id: String) {
        guard !isBusy, !loadFailed else { return }
        workspace.models.removeAll { $0.id == id }
        save() // Removing a candidate never deletes downloaded model assets or prior results.
    }

    func startRecording(microphoneUID: String?, language: String) {
        guard begin("Starting microphone…") else { return }
        elapsed = 0
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            var audio: [Float] = []
            do {
                let capture = self.captureBuilder(microphoneUID)
                self.capture = capture
                let stream = try await capture.start()
                try Task.checkCancellation()
                self.recording = true
                self.status = "Listening · stops at 60 seconds"
                let started = ContinuousClock.now
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard let self, self.recording else { return }
                        self.elapsed = Self.seconds(since: started)
                        if self.elapsed >= 60 { self.stopRecording(); return }
                    }
                }
                for try await chunk in stream {
                    try Task.checkCancellation()
                    let remaining = 60 * Int(AudioChunk.sampleRate) - audio.count
                    audio.append(contentsOf: chunk.samples.prefix(max(0, remaining)))
                    var stats = AudioStatistics(); stats.append(chunk.samples)
                    self.level = max(0, min(1, (stats.rmsDBFS + 60) / 60))
                    if audio.count >= 60 * Int(AudioChunk.sampleRate) { self.stopRecording(); break }
                }
                try Task.checkCancellation()
                try self.addSample(audio: audio, title: "Recording \(self.workspace.samples.count + 1)",
                                   source: capture.inputDescription, language: language)
            } catch { self.report(error) }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false; ticker?.cancel(); capture?.stop()
        status = "Saving recording…"
    }

    func importAudio(_ url: URL, title: String? = nil, language: String = "en") {
        guard begin("Importing audio…") else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            do {
                let audio = try await Task.detached { try AudioFile.read(url) }.value
                try Task.checkCancellation()
                try self.addSample(audio: audio, title: title ?? url.deletingPathExtension().lastPathComponent,
                                   source: url.lastPathComponent, language: language)
            } catch { self.report(error) }
        }
    }

    func useHistory(_ run: RecordingRun, language: String) {
        guard !isBusy, !loadFailed else { return }
        if !run.samples.isEmpty {
            do { try addSample(audio: run.samples, title: "History · \(run.date.formatted())", source: "Recording history", language: language) }
            catch { report(error) }
        } else if let url = run.savedURL {
            importAudio(url, title: "History · \(run.date.formatted())", language: language)
        } else { errorMessage = "This history entry has no saved audio." }
    }

    private func addSample(audio: [Float], title: String, source: String, language: String) throws {
        guard !audio.isEmpty, audio.count <= 60 * Int(AudioChunk.sampleRate), audio.allSatisfy(\.isFinite) else {
            throw EngineError.invalidAudio
        }
        let sample = DebugSample(title: title, language: language,
                                 audioSeconds: Double(audio.count) / AudioChunk.sampleRate, source: source)
        try store.saveAudio(audio, id: sample.id)
        workspace.samples.insert(sample, at: 0)
        selectedSampleID = sample.id
        save()
        status = "Sample saved. Add the expected transcript, then run a comparison."
    }

    func runComparison(allSamples: Bool = false) {
        let samples = allSamples ? workspace.samples : workspace.samples.filter { $0.id == selectedSampleID }
        let models = workspace.models.filter(\.enabled)
        guard !samples.isEmpty, !models.isEmpty, begin("Preparing comparison…") else { return }
        let batchID = UUID()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            do {
                // One model at a time; retain it across samples within this batch.
                for model in models {
                    try Task.checkCancellation()
                    try await self.compare(model: model, samples: samples, batchID: batchID)
                }
                self.status = "Comparison complete. Results saved locally."
            } catch { self.report(error) }
        }
    }

    private func compare(model: DebugModel, samples: [DebugSample], batchID: UUID) async throws {
        let prepareStart = ContinuousClock.now
        status = "Loading \(model.name)…"
        let engine: any TranscriptionEngine
        do {
            engine = try engineBuilder(model.folder)
            try await engine.prepare()
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            for sample in samples {
                appendResult(sample: sample, model: model, batchID: batchID, text: "",
                             preparation: Self.seconds(since: prepareStart), transcription: 0, error: error.localizedDescription)
            }
            return
        }
        let preparation = Self.seconds(since: prepareStart)
        for (index, sample) in samples.enumerated() {
            try Task.checkCancellation()
            status = "\(model.name) · sample \(index + 1) of \(samples.count)"
            let id = UUID()
            var started: ContinuousClock.Instant?
            do {
                let url = store.audioURL(sample.id)
                let audio = try await Task.detached { try AudioFile.read(url) }.value
                try Task.checkCancellation()
                started = .now
                try await engine.start(sessionID: id, language: sample.language == "auto" ? nil : sample.language, onPartial: nil)
                for offset in stride(from: 0, to: audio.count, by: 1600) {
                    try Task.checkCancellation()
                    try await engine.append(AudioChunk(samples: Array(audio[offset..<min(audio.count, offset + 1600)]),
                        timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: id)
                }
                let text = try await engine.finish(sessionID: id)
                try Task.checkCancellation()
                appendResult(sample: sample, model: model, batchID: batchID, text: text,
                             preparation: preparation, transcription: Self.seconds(since: started!), error: nil)
            } catch {
                await engine.cancel(sessionID: id)
                try Task.checkCancellation()
                appendResult(sample: sample, model: model, batchID: batchID, text: "", preparation: preparation,
                             transcription: started.map { Self.seconds(since: $0) } ?? 0, error: error.localizedDescription)
            }
        }
    }

    private func appendResult(sample: DebugSample, model: DebugModel, batchID: UUID, text: String,
                              preparation: Double, transcription: Double, error: String?) {
        workspace.results.append(DebugResult(batchID: batchID, sampleID: sample.id, model: model,
            expectedText: sample.expectedText, language: sample.language, transcript: text,
            preparationSeconds: preparation, transcriptionSeconds: transcription, error: error))
        save()
    }

    func fetchModels() {
        guard begin("Fetching model catalog…") else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            do {
                let models = try await WhisperKitEngine.availableModels()
                try Task.checkCancellation()
                self.availableModels = models.sorted()
                self.status = "Choose a model to download."
            } catch { self.report(error) }
        }
    }

    func downloadModel(_ name: String) {
        guard availableModels.contains(name), begin("Downloading and preparing \(name)…") else { return }
        let directory = store.directory.appendingPathComponent("Models", isDirectory: true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            do {
                let folder = try await WhisperKitEngine.download(model: name, to: directory)
                try Task.checkCancellation()
                self.addModel(folder: folder)
                self.status = "Model downloaded and added to the comparison."
            } catch { self.report(error) }
        }
    }

    public func cancel() {
        guard isBusy, !cancelling else { return }
        cancelling = true; status = "Cancelling…"; ticker?.cancel(); capture?.stop(); operation?.cancel()
    }

    private func begin(_ message: String) -> Bool {
        guard !isBusy, !loadFailed else { return false }
        stopPlayback()
        isBusy = true; cancelling = false; errorMessage = nil; status = message
        return true
    }

    private func finish() {
        ticker?.cancel(); ticker = nil; capture?.stop(); capture = nil
        isBusy = false; recording = false; cancelling = false; level = 0; operation = nil
    }

    private func report(_ error: Error) {
        if Task.isCancelled || error is CancellationError || error as? EngineError == .cancelled {
            status = "Cancelled. Previously saved samples and results were kept."
        } else { errorMessage = error.localizedDescription; status = "Could not finish. You can try again." }
    }

    func togglePlayback() {
        if playing { stopPlayback(); return }
        guard !isBusy, let sample = selectedSample else { return }
        do {
            player = try AVAudioPlayer(contentsOf: store.audioURL(sample.id))
            guard player?.play() == true else { throw StudioError.message("Could not play this sample.") }
            playing = true
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self else { return }
                    if self.player?.isPlaying != true { self.stopPlayback(); return }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    public func stopPlayback() { playbackTask?.cancel(); player?.stop(); player = nil; playing = false }
    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

#if DEBUG
extension DebuggingSession {
    public func loadDesignPreview() {
        guard CommandLine.arguments.contains("--snapshot") else { return }
        let sample = DebugSample(title: "A correction in the middle of a thought",
            expectedText: "We need one, sorry, two instances for the deployment.",
            audioSeconds: 8.4, source: "Design preview")
        let models = [DebugModel(name: "whisper-large-v3-turbo", folder: "/preview/turbo"),
                      DebugModel(name: "whisper-small.en", folder: "/preview/small")]
        let batch = UUID()
        workspace = DebugWorkspace(samples: [sample], models: models, results: [
            DebugResult(batchID: batch, sampleID: sample.id, model: models[1], expectedText: sample.expectedText,
                language: "en", transcript: "We need one, sorry, two instance for the deployment.",
                preparationSeconds: 1.2, transcriptionSeconds: 0.45),
            DebugResult(batchID: batch, sampleID: sample.id, model: models[0], expectedText: sample.expectedText,
                language: "en", transcript: sample.expectedText, preparationSeconds: 3.1, transcriptionSeconds: 0.82)
        ])
        selectedSampleID = sample.id
        status = "Comparison complete. Results saved locally."
    }
}
#endif
