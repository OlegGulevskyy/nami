import AppKit
import AVFoundation
import Foundation
import Observation
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

    @ObservationIgnored private let historyStore: RecordingHistoryStore
    @ObservationIgnored private let engineBuilder: @MainActor (StudioSettings) throws -> any TranscriptionEngine
    @ObservationIgnored private let captureBuilder: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private let inputDevicesProvider: @MainActor () -> [AudioInputDevice]
    @ObservationIgnored private let clipboardWriter: @MainActor (String) -> Bool
    @ObservationIgnored private let pastePreparer: @MainActor () -> PreparedTranscriptPaste
    @ObservationIgnored private var engine: (any TranscriptionEngine)?
    @ObservationIgnored private var engineKey = ""
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
                pastePreparer: (@MainActor () -> PreparedTranscriptPaste)? = nil,
                engineBuilder: (@MainActor (StudioSettings) throws -> any TranscriptionEngine)? = nil,
                captureBuilder: (@MainActor (String?) -> any AudioCapturing)? = nil,
                inputDevicesProvider: @escaping @MainActor () -> [AudioInputDevice] = { AudioInputDevice.available() },
                clipboardWriter: (@MainActor (String) -> Bool)? = nil) {
        self.project = project
        self.historyStore = RecordingHistoryStore(directory: historyDirectory ?? RecordingHistoryStore.defaultDirectory)
        self.permissions = permissions ?? StudioPermissions()
        self.pastePreparer = pastePreparer ?? { TranscriptPaster().prepare() }
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
        self.captureBuilder = captureBuilder ?? { MicrophoneCapture(deviceUID: $0) }
        self.inputDevicesProvider = inputDevicesProvider
        self.clipboardWriter = clipboardWriter ?? { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
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

    public var historyDirectory: URL { historyStore.directory }
    public var selectedRun: RecordingRun? { runs.first { $0.id == selectedRunID } ?? runs.first }
    public var selectedPrompt: ReadingPrompt? { prompts.first { $0.id == selectedPromptID } }
    public var modelName: String {
        settings.engine == "fake" ? "Demo engine" : (settings.modelFolder.isEmpty ? "Choose a model folder" : URL(fileURLWithPath: settings.modelFolder).lastPathComponent)
    }
    public var limit: Double { settings.timed ? min(60, max(5, settings.duration)) : 60 }

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
            stopPlayback()
        }
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
            if engineKey != key(settings) { engine = nil; modelLoaded = false }
            refreshInput()
        }
        do { try settings.save(project: project) }
        catch { errorMessage = error.localizedDescription }
    }

    public func startRecording() {
        guard !phase.busy, permissionsReady() else { return }
        let id = begin(), date = Date()
        let options = settings
        let paste = options.copyWhenFinished && options.pasteWhenFinished ? pastePreparer() : nil
        let prompt = selectedPrompt?.reference ?? ""
        operation = Task { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            var stats = AudioStatistics()
            do {
                let engine = try await self.preparedEngine(options)
                try self.check(id)
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language, onPartial: nil)
                try self.check(id)
                self.refreshPermissions()
                try self.check(id)
                let capture = self.captureBuilder(options.microphoneUID)
                self.capture = capture
                self.status = "Requesting microphone access…"
                let stream = try await capture.start()
                try self.check(id)
                self.inputName = capture.inputDescription
                self.phase = .recording
                self.status = "Listening. Speak naturally."
                let startedAt = ContinuousClock.now
                let maximum = options.timed ? min(60, max(5, options.duration)) : 60
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self, self.phase == .recording else { return }
                        self.elapsed = Self.seconds(since: startedAt)
                        if self.elapsed >= maximum { self.stopRecording(); return }
                    }
                }
                for try await chunk in stream {
                    try self.check(id)
                    // Bound audio by frames too: hardware buffers can arrive just after the timer.
                    let remaining = Int(maximum * AudioChunk.sampleRate) - samples.count
                    guard remaining > 0 else { self.stopRecording(); break }
                    let values = Array(chunk.samples.prefix(remaining))
                    let timestamp = Double(samples.count) / AudioChunk.sampleRate
                    samples += values
                    stats.append(values)
                    try await engine.append(AudioChunk(samples: values, timestamp: timestamp), sessionID: id)
                    var instant = AudioStatistics(); instant.append(values)
                    self.level = max(0, min(1, (instant.rmsDBFS + 60) / 60))
                    self.meterHistory.removeFirst(); self.meterHistory.append(self.level)
                    self.capturedSeconds = stats.duration
                    self.averageDB = stats.rmsDBFS
                    if samples.count >= Int(maximum * AudioChunk.sampleRate) { self.stopRecording() }
                }
                self.ticker?.cancel()
                capture.stop()
                self.capture = nil
                try self.check(id)
                let stop = self.stoppedAt ?? .now
                self.elapsed = stats.duration
                self.phase = .processing
                self.level = 0
                self.status = "Turning your audio into text…"
                _ = self.archive(id: id, date: date, text: "", samples: samples, statistics: stats,
                                 input: self.inputName, options: options, prompt: prompt, outcome: .interrupted)
                self.saveExtraAudioIfRequested(samples, options: options, id: id)
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
        guard !phase.busy, permissionsReady() else { return }
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
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language, onPartial: nil)
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
        guard !phase.busy, let run = selectedRun else { return }
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

    public func stopPlayback() { playbackTask?.cancel(); player?.stop(); player = nil; playing = false }
    public func dismissError() { errorMessage = nil; if phase == .failed { phase = .idle } }

    private func begin() -> UUID {
        stopPlayback()
        errorMessage = nil; phase = .preparing; status = "Preparing the local model…"
        elapsed = 0; capturedSeconds = 0; level = 0; averageDB = -.infinity
        meterHistory = Array(repeating: 0, count: 64)
        let id = UUID(); activeID = id; stoppedAt = nil
        return id
    }

    private func preparedEngine(_ options: StudioSettings) async throws -> any TranscriptionEngine {
        let nextKey = key(options)
        if engine == nil || engineKey != nextKey {
            engine = try engineBuilder(options); engineKey = nextKey; modelLoaded = false
        }
        guard let engine else { throw EngineError.notPrepared }
        if !modelLoaded {
            status = "Loading the model. The first run can take a few minutes…"
            try await engine.prepare()
            modelLoaded = true
        }
        return engine
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
