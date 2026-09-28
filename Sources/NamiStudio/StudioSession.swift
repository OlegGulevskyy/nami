import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog
import NamiAudio
import NamiCore
import NamiWhisperKit

public enum StudioPhase: String, Sendable {
    case idle, preparing, recording, processing, cancelling, failed
    public var busy: Bool { self != .idle && self != .failed }
}

public enum RecordingOutcome: String, Codable, Sendable {
    case completed, interrupted, cancelled, failed
}

public struct RecordingRun: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let transcript: String
    public let audioSeconds: Double
    public let latency: Double
    public let averageDB: Double
    public let peakDB: Double
    public let input: String
    public var savedURL: URL?
    public let engine: String
    public let model: String
    public let prompt: String
    // Only unsaved runs and design previews hold audio in memory. Playback of
    // archived runs opens the WAV on demand, even with an unlimited history.
    public var samples: [Float] = []
    public var outcome: RecordingOutcome = .completed

    private enum CodingKeys: String, CodingKey {
        case id, date, transcript, audioSeconds, latency, averageDB, peakDB
        case input, savedURL, engine, model, prompt, outcome
    }

    public var displayText: String {
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return transcript }
        switch outcome {
        case .completed: return "No speech recognized."
        case .interrupted: return "Transcription interrupted. Recording kept."
        case .cancelled: return "Transcription cancelled. Recording kept."
        case .failed: return "Transcription failed. Recording kept."
        }
    }
}

@MainActor @Observable
public final class StudioSession {
    public var updates: AppUpdates?
    public var busyForUpdate: Bool { phase.busy || debugging.isBusy }
    public let permissions: StudioPermissions
    public let modifierShortcut = ModifierRecordingShortcut()
    public var settings: StudioSettings {
        didSet {
            if settings != oldValue { settingsChanged() }
        }
    }
    public let project: URL
    public private(set) var phase: StudioPhase = .idle
    public private(set) var status = "Your next thought starts here."
    public private(set) var errorMessage: String?
    public private(set) var modelLoaded = false
    public private(set) var modelPreparing = false
    public private(set) var modelPreparationError: String?
    public private(set) var modelPreparationSeconds: Double?
    public private(set) var captureStartSeconds: Double?
    public private(set) var firstAudioSeconds: Double?
    public private(set) var elapsed = 0.0
    public private(set) var level = 0.0
    public private(set) var meterHistory = Array(repeating: 0.0, count: 64)
    public private(set) var inputName = "System default microphone"
    public private(set) var inputDevices: [AudioInputDevice] = []
    public private(set) var capturedSeconds = 0.0
    public private(set) var averageDB = -Double.infinity
    public private(set) var runs: [RecordingRun] = []
    public var selectedRunID: UUID?
    public var selectedPromptID = ""
    public private(set) var prompts: [ReadingPrompt] = []
    public private(set) var playing = false
    public let debugging: DebuggingSession

    @ObservationIgnored private let historyStore: RecordingHistoryStore
    @ObservationIgnored private let engineBuilder: @MainActor (StudioSettings) throws -> any TranscriptionEngine
    @ObservationIgnored private let captureBuilder: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private let inputDevicesProvider: @MainActor () -> [AudioInputDevice]
    @ObservationIgnored private let clipboardWriter: @MainActor (String) -> Bool
    @ObservationIgnored private let pastePreparer: @MainActor () -> PreparedTranscriptPaste
    @ObservationIgnored private var engine: (any TranscriptionEngine)?
    @ObservationIgnored private var engineKey = ""
    @ObservationIgnored private var preparation: EnginePreparation?
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var automaticPreparationEnabled = false
    private static let startupLog = Logger(subsystem: "local.nami.studio", category: "Startup")
    @ObservationIgnored private var capture: (any AudioCapturing)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var stoppedAt: ContinuousClock.Instant?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    public init(project: URL,
                historyDirectory: URL? = nil,
                permissions: StudioPermissions? = nil,
                // No defaults: the live versions paste into the frontmost app, open the
                // microphone and overwrite the clipboard. Tests must inject fakes so a
                // background test run can never disturb someone using the Mac.
                pastePreparer: @escaping @MainActor () -> PreparedTranscriptPaste,
                engineBuilder: (@MainActor (StudioSettings) throws -> any TranscriptionEngine)? = nil,
                captureBuilder: @escaping @MainActor (String?) -> any AudioCapturing,
                inputDevicesProvider: @escaping @MainActor () -> [AudioInputDevice] = { AudioInputDevice.available() },
                clipboardWriter: @escaping @MainActor (String) -> Bool) {
        self.project = project
        self.historyStore = RecordingHistoryStore(directory: historyDirectory ?? RecordingHistoryStore.defaultDirectory)
        let debuggingDirectory = historyDirectory?.appendingPathComponent("InternalDebugging")
            ?? RecordingHistoryStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("InternalDebugging")
        self.debugging = DebuggingSession(directory: debuggingDirectory,
            apiKeyStore: CommandLine.arguments.contains("--snapshot") ? nil
                : .keychain(account: debuggingDirectory.standardizedFileURL.path))
        self.permissions = permissions ?? StudioPermissions()
        self.pastePreparer = pastePreparer
        self.engineBuilder = engineBuilder ?? { settings in
            var config = EngineConfiguration()
            guard let backend = EngineConfiguration.Backend(rawValue: settings.engine) else {
                throw StudioError.message("Choose WhisperKit or the demo engine.")
            }
            config.backend = backend
            config.modelFolder = settings.modelFolder
            config.fakeTranscript = "This is a demo transcript. Switch to WhisperKit to recognize your speech."
            return try EngineFactory.make(config)
        }
        self.captureBuilder = captureBuilder
        self.inputDevicesProvider = inputDevicesProvider
        self.clipboardWriter = clipboardWriter
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            settings = try StudioSettings.load(project: project)
        }
        catch { settings = StudioSettings(); errorMessage = error.localizedDescription }
        let promptURL = project.appendingPathComponent("evaluation/samples.template.json")
        if let data = try? Data(contentsOf: promptURL) {
            prompts = (try? JSONDecoder().decode([ReadingPrompt].self, from: data)) ?? []
        }
        do {
            let history = try historyStore.load()
            runs = history.runs
            selectedRunID = runs.first?.id
            if !history.warnings.isEmpty {
                errorMessage = "Some history could not be loaded. Existing files were kept. " + history.warnings.joined(separator: "\n")
            }
        } catch { errorMessage = "Could not load recording history: \(error.localizedDescription)" }
        refreshInput()
    }

    /// Live integrations for the app only; tests must never pass these.
    public static func systemPastePreparer() -> PreparedTranscriptPaste { TranscriptPaster().prepare() }
    public static func systemCapture(deviceUID: String?) -> any AudioCapturing { MicrophoneCapture(deviceUID: deviceUID) }
    public static func systemClipboardWriter(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    public var historyDirectory: URL { historyStore.directory }
    public var selectedRun: RecordingRun? { runs.first { $0.id == selectedRunID } ?? runs.first }
    public var selectedPrompt: ReadingPrompt? { prompts.first { $0.id == selectedPromptID } }
    public var modelName: String {
        settings.engine == "fake" ? "Demo engine" : (settings.modelFolder.isEmpty ? "Choose a model folder" : URL(fileURLWithPath: settings.modelFolder).lastPathComponent)
    }
    public var selectedMicrophoneUnavailable: Bool {
        guard let uid = settings.microphoneUID else { return false }
        return !inputDevices.contains { $0.id == uid }
    }

    public func refreshInput() {
        guard !phase.busy else { return }
        inputDevices = inputDevicesProvider()
        if let uid = settings.microphoneUID {
            inputName = inputDevices.first { $0.id == uid }?.name ?? "Selected microphone unavailable"
        } else {
            inputName = MicrophoneCapture.defaultDeviceName()
        }
    }

    public func refreshPermissions() {
        permissions.refresh()
        if permissions.needsSetup {
            cancel()
            if debugging.recording { debugging.cancel() }
            stopPlayback()
        } else if automaticPreparationEnabled && !phase.busy {
            prepareInBackground()
        }
    }

    /// Called once by the app at launch. Permission recovery and model changes
    /// also warm the model automatically; this never opens the microphone.
    public func prepareForRecording() {
        automaticPreparationEnabled = true
        refreshPermissions()
    }

    private func prepareInBackground() {
        guard settings.engine != "whisperkit" || !settings.modelFolder.isEmpty else { return }
        do { _ = try preparationFor(settings) }
        catch { modelPreparationError = error.localizedDescription }
    }

    /// All recording entry points (including global shortcuts) pass this gate
    /// before model preparation or microphone capture can begin.
    private func permissionsReady() -> Bool {
        refreshPermissions()
        guard !permissions.needsSetup else {
            status = "Allow Microphone and Input Monitoring to use Nami."
            NSApp?.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }

    private func settingsChanged() {
        if !phase.busy {
            if engineKey != key(settings) {
                preparation?.cancel()
                preparation = nil; preparationID = UUID()
                engine = nil; modelLoaded = false; modelPreparing = false
                modelPreparationError = nil; modelPreparationSeconds = nil
            }
            refreshInput()
            if automaticPreparationEnabled && !permissions.needsSetup { prepareInBackground() }
        }
        do { try settings.save(project: project) }
        catch { errorMessage = error.localizedDescription }
    }

    public func startRecording() {
        let requestedAt = ContinuousClock.now
        guard !phase.busy, !debugging.isBusy, permissionsReady() else { return }
        debugging.stopPlayback()
        let id = begin(), date = Date()
        status = "Starting microphone…"
        let options = settings
        let paste = options.copyWhenFinished && options.pasteWhenFinished ? pastePreparer() : nil
        let prompt = selectedPrompt?.reference ?? ""
        operation = Task { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            var stats = AudioStatistics()
            do {
                try self.check(id)
                self.refreshPermissions()
                try self.check(id)
                let capture = self.captureBuilder(options.microphoneUID)
                self.capture = capture
                let stream = try await capture.start()
                try self.check(id)
                self.captureStartSeconds = Self.seconds(since: requestedAt)
                Self.startupLog.info("Microphone started after \(self.captureStartSeconds!, privacy: .public) seconds")
                self.inputName = capture.inputDescription
                self.phase = .recording
                self.status = "Listening. Speak naturally."
                let startedAt = ContinuousClock.now
                // Capture must never wait for the model. Drain the stream into
                // our recording buffer while preparation runs separately.
                let preparation = try self.preparationFor(options, retryFailure: true)
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self, self.phase == .recording else { return }
                        self.elapsed = Self.seconds(since: startedAt)
                    }
                }
                for try await chunk in stream {
                    try self.check(id)
                    if self.firstAudioSeconds == nil {
                        self.firstAudioSeconds = Self.seconds(since: requestedAt)
                        Self.startupLog.info("First audio received after \(self.firstAudioSeconds!, privacy: .public) seconds")
                    }
                    samples += chunk.samples
                    stats.append(chunk.samples)
                    var instant = AudioStatistics(); instant.append(chunk.samples)
                    self.level = max(0, min(1, (instant.rmsDBFS + 60) / 60))
                    self.meterHistory.removeFirst(); self.meterHistory.append(self.level)
                    self.capturedSeconds = stats.duration
                    self.averageDB = stats.rmsDBFS
                }
                self.ticker?.cancel()
                capture.stop()
                self.capture = nil
                try self.check(id)
                // A silent device must not look like a history or extra-copy failure.
                guard !samples.isEmpty else { throw AudioInputError.noAudioReceived }
                let stop = self.stoppedAt ?? .now
                self.elapsed = stats.duration
                self.phase = .processing
                self.level = 0
                self.status = "Turning your audio into text…"
                _ = self.archive(id: id, date: date, text: "", samples: samples, statistics: stats,
                                 input: self.inputName, options: options, prompt: prompt, outcome: .interrupted)
                self.saveExtraAudioIfRequested(samples, options: options, id: id)
                if !self.modelLoaded { self.status = "Waiting for the model. Your audio is kept." }
                let engine = try await preparation.value()
                try self.check(id)
                self.refreshPermissions()
                try self.check(id)
                self.status = "Turning your audio into text…"
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language,
                                       vocabulary: options.vocabulary, onPartial: nil)
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    try self.check(id)
                    try await engine.append(AudioChunk(samples: Array(samples[offset..<min(samples.count, offset + 1600)]),
                        timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: id)
                }
                let text = try await engine.finish(sessionID: id)
                try self.check(id)
                self.complete(id: id, date: date, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: self.inputName,
                              options: options, prompt: prompt, paste: paste)
            } catch {
                self.keepUnfinished(id: id, date: date, samples: samples, statistics: stats,
                                    input: self.inputName, options: options, prompt: prompt, error: error)
                await self.failed(error, id: id)
            }
            self.cleanup(id)
        }
    }

    public func transcribeFile(_ url: URL) {
        guard !phase.busy, !debugging.isBusy, permissionsReady() else { return }
        debugging.stopPlayback()
        let id = begin(), date = Date(), options = settings
        operation = Task { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            var stats = AudioStatistics()
            do {
                samples = try AudioFile.read(url)
                stats.append(samples)
                _ = self.archive(id: id, date: date, text: "", samples: samples, statistics: stats,
                                 input: url.lastPathComponent, options: options, prompt: "", outcome: .interrupted)
                let engine = try await self.preparedEngine(options)
                try self.check(id)
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language,
                                       vocabulary: options.vocabulary, onPartial: nil)
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    try self.check(id)
                    try await engine.append(AudioChunk(samples: Array(samples[offset..<min(samples.count, offset + 1600)]), timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: id)
                }
                self.phase = .processing
                self.status = "Transcribing \(url.lastPathComponent)…"
                self.capturedSeconds = stats.duration
                self.elapsed = stats.duration
                self.averageDB = stats.rmsDBFS
                let stop = ContinuousClock.now
                let text = try await engine.finish(sessionID: id)
                try self.check(id)
                self.complete(id: id, date: date, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: url.lastPathComponent,
                              options: options, prompt: "")
            } catch {
                self.keepUnfinished(id: id, date: date, samples: samples, statistics: stats,
                                    input: url.lastPathComponent, options: options, prompt: "", error: error)
                await self.failed(error, id: id)
            }
            self.cleanup(id)
        }
    }

    public func stopRecording() {
        guard phase == .recording else { return }
        stoppedAt = .now
        ticker?.cancel()
        phase = .processing
        status = "Finishing the recording…"
        capture?.stop()
    }

    func startDebugRecording() {
        guard !phase.busy, !debugging.isBusy, permissionsReady() else { return }
        stopPlayback()
        debugging.startRecording(microphoneUID: settings.microphoneUID, language: settings.language)
    }

    public func toggleRecording() {
        switch phase {
        case .idle, .failed: startRecording()
        case .recording: stopRecording()
        case .preparing, .processing, .cancelling: break
        }
    }

    public func cancel() {
        guard phase.busy, phase != .cancelling else { return }
        phase = .cancelling
        status = "Cancelling…"
        ticker?.cancel()
        capture?.stop()
        operation?.cancel()
        // Keep controls disabled until the engine has unwound. Each suspension
        // also checks the session ID so cancelled work cannot publish a result.
    }

    @discardableResult public func copyTranscript() -> Bool {
        guard let run = selectedRun, !run.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return copyToClipboard(run.transcript)
    }

    private func copyToClipboard(_ text: String) -> Bool {
        guard clipboardWriter(text) else {
            errorMessage = "The transcript is ready, but copying failed. Use Copy to try again."
            return false
        }
        return true
    }

    public func togglePlayback() {
        if playing { stopPlayback(); return }
        guard !phase.busy, !debugging.isBusy, let run = selectedRun else { return }
        debugging.stopPlayback()
        do {
            if run.samples.isEmpty, let url = run.savedURL {
                player = try AVAudioPlayer(contentsOf: url)
            } else {
                player = try AVAudioPlayer(data: Self.wavData(run.samples))
            }
            guard player?.play() == true else { throw StudioError.message("Audio playback could not start.") }
            playing = true
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    if self.player?.isPlaying != true { self.stopPlayback(); return }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Deletes the transcript and its audio from history. Extra audio copies the
    /// user chose to keep in their own folder are left untouched.
    public func deleteRun(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if selectedRunID == id { stopPlayback() }
        do { try historyStore.delete(id) }
        catch {
            errorMessage = "Could not delete this recording: \(error.localizedDescription)"
            return
        }
        runs.remove(at: index)
        if selectedRunID == id { selectedRunID = runs.indices.contains(index) ? runs[index].id : runs.last?.id }
    }

    public func stopPlayback() { playbackTask?.cancel(); player?.stop(); player = nil; playing = false }
    public func dismissError() { errorMessage = nil; if phase == .failed { phase = .idle } }

    private func begin() -> UUID {
        stopPlayback()
        errorMessage = nil; phase = .preparing; status = "Preparing the local model…"
        elapsed = 0; capturedSeconds = 0; level = 0; averageDB = -.infinity
        captureStartSeconds = nil; firstAudioSeconds = nil
        meterHistory = Array(repeating: 0, count: 64)
        let id = UUID(); activeID = id; stoppedAt = nil
        return id
    }

    private func preparedEngine(_ options: StudioSettings) async throws -> any TranscriptionEngine {
        try await preparationFor(options, retryFailure: true).value()
    }

    private func preparationFor(_ options: StudioSettings, retryFailure: Bool = false) throws -> EnginePreparation {
        let nextKey = key(options)
        if let preparation, engineKey == nextKey, !(retryFailure && preparation.failed) {
            return preparation
        }
        let nextEngine = try engineBuilder(options)
        preparation?.cancel()
        engine = nextEngine; engineKey = nextKey
        modelLoaded = false; modelPreparing = true; modelPreparationError = nil
        modelPreparationSeconds = nil
        let id = UUID(), startedAt = ContinuousClock.now
        preparationID = id
        let next = EnginePreparation(engine: nextEngine) { [weak self] result in
            guard let self, self.preparationID == id else { return }
            self.modelPreparing = false
            self.modelPreparationSeconds = Self.seconds(since: startedAt)
            switch result {
            case .success:
                self.modelLoaded = true
                Self.startupLog.info("Model prepared in \(self.modelPreparationSeconds!, privacy: .public) seconds")
            case .failure(let error):
                self.modelPreparationError = error.localizedDescription
                Self.startupLog.error("Model preparation failed")
            }
        }
        preparation = next
        return next
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id, phase != .cancelling else { throw CancellationError() }
    }

    private func saveExtraAudioIfRequested(_ samples: [Float], options: StudioSettings, id: UUID) {
        guard options.saveAudio else { return }
        do {
            guard !options.audioDirectory.isEmpty else { throw StudioError.message("Choose a folder for extra audio copies.") }
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = URL(fileURLWithPath: options.audioDirectory).appendingPathComponent("nami-\(timestamp)-\(id.uuidString).wav")
            try AudioFile.write(samples, to: url)
        } catch { errorMessage = "Could not save the extra audio copy: \(error.localizedDescription)" }
    }

    private func archive(id: UUID, date: Date, text: String, samples: [Float], statistics: AudioStatistics,
                         latency: Double = 0, input: String, options: StudioSettings, prompt: String,
                         outcome: RecordingOutcome) -> RecordingRun {
        let run = RecordingRun(id: id, date: date, transcript: text, audioSeconds: statistics.duration,
            latency: latency, averageDB: statistics.rmsDBFS, peakDB: statistics.peakDBFS,
            input: input, savedURL: nil, engine: options.engine,
            model: URL(fileURLWithPath: options.modelFolder).lastPathComponent, prompt: prompt,
            samples: samples, outcome: outcome)
        do { return try historyStore.save(run) }
        catch {
            errorMessage = "Could not save this recording to history. Keep Nami open to retain its audio and text. \(error.localizedDescription)"
            return run
        }
    }

    private func keepUnfinished(id: UUID, date: Date, samples: [Float], statistics: AudioStatistics,
                                input: String, options: StudioSettings, prompt: String, error: Error) {
        guard !samples.isEmpty else { return }
        let cancelled = error is CancellationError || error as? EngineError == .cancelled || phase == .cancelling
        let run = archive(id: id, date: date, text: "", samples: samples, statistics: statistics,
                          input: input, options: options, prompt: prompt, outcome: cancelled ? .cancelled : .failed)
        runs.insert(run, at: 0)
        selectedRunID = id
    }

    private func complete(id: UUID, date: Date, text: String, samples: [Float], statistics: AudioStatistics,
                          latency: Double, input: String, options: StudioSettings, prompt: String,
                          paste: PreparedTranscriptPaste? = nil) {
        let run = archive(id: id, date: date, text: text, samples: samples, statistics: statistics,
                          latency: latency, input: input, options: options, prompt: prompt, outcome: .completed)
        runs.insert(run, at: 0)
        selectedRunID = id
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "No speech recognized. Listen back to check the recording."
        } else {
            if options.copyWhenFinished {
                if copyToClipboard(text) {
                    status = paste?().status ?? "Transcript copied. Paste it wherever you need it."
                } else {
                    status = "Your transcript is ready."
                }
            } else {
                status = "Your transcript is ready. Copy it whenever you need it."
            }
        }
        // Keep the indicator processing until publication and the paste handoff finish.
        phase = .idle
    }

    private func failed(_ error: Error, id: UUID) async {
        permissions.refresh()
        capture?.stop(); capture = nil; ticker?.cancel()
        await engine?.cancel(sessionID: id)
        guard activeID == id else { return }
        if error is CancellationError || error as? EngineError == .cancelled || phase == .cancelling {
            phase = .idle; status = "Run cancelled. Ready for another take."
        } else {
            phase = .failed
            errorMessage = [errorMessage, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            status = "This run could not finish."
        }
    }

    private func cleanup(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil; operation = nil; ticker?.cancel(); ticker = nil; level = 0
        if automaticPreparationEnabled && !permissions.needsSetup { prepareInBackground() }
    }
    private func key(_ options: StudioSettings) -> String { options.engine + "|" + options.modelFolder }
    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    /// Normalized PCM16 WAV for durable history and unsaved playback.
    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000))
        number(UInt32(32000)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(samples.count * 2))
        for value in samples { number(Int16(max(-1, min(1, value)) * 32767)) }
        return data
    }
}

#if DEBUG
extension StudioSession {
    /// Reference content is confined to explicit screenshot runs, never normal launches.
    public func loadDesignPreviewHistory() {
        guard CommandLine.arguments.contains("--snapshot") else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let examples: [(Date, Int, Int, Double, String)] = [
            (today, 10, 42, 24, "Let’s keep the first version simple. One shortcut to record, your words pasted where you need them, and everything stays on your Mac."),
            (today, 9, 18, 12, "Hey Alex, I’ve had a look at the latest designs. The new direction feels much clearer. Let’s go with it."),
            (yesterday, 16, 36, 18, "An idea for the weekend: take the train out of the city, find a quiet place for lunch, and leave the laptop at home."),
            (yesterday, 11, 5, 8, "Remember to book a table for Friday. Somewhere small, preferably with a terrace.")
        ]
        runs = examples.map { day, hour, minute, duration, text in
            RecordingRun(id: UUID(), date: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!,
                         transcript: text, audioSeconds: duration, latency: 0.8, averageDB: -20, peakDB: -6,
                         input: "Design preview", savedURL: nil, engine: "whisperkit", model: "Preview",
                         prompt: "", samples: [])
        }
        status = "Press your shortcut or click to record"
    }
}
#endif
