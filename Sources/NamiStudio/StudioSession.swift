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

public struct RecordingRun: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let transcript: String
    public let audioSeconds: Double
    public let latency: Double
    public let averageDB: Double
    public let peakDB: Double
    public let input: String
    public let savedURL: URL?
    public let engine: String
    public let model: String
    public let prompt: String
    public let samples: [Float]
}

@MainActor @Observable
public final class StudioSession {
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

    @ObservationIgnored private let engineBuilder: @MainActor (StudioSettings) throws -> any TranscriptionEngine
    @ObservationIgnored private let captureBuilder: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private let inputDevicesProvider: @MainActor () -> [AudioInputDevice]
    @ObservationIgnored private let clipboardWriter: @MainActor (String) -> Bool
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
                engineBuilder: (@MainActor (StudioSettings) throws -> any TranscriptionEngine)? = nil,
                captureBuilder: (@MainActor (String?) -> any AudioCapturing)? = nil,
                inputDevicesProvider: @escaping @MainActor () -> [AudioInputDevice] = { AudioInputDevice.available() },
                clipboardWriter: (@MainActor (String) -> Bool)? = nil) {
        self.project = project
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
        do { settings = try StudioSettings.load(project: project) }
        catch { settings = StudioSettings(); errorMessage = error.localizedDescription }
        let promptURL = project.appendingPathComponent("evaluation/samples.template.json")
        if let data = try? Data(contentsOf: promptURL) {
            prompts = (try? JSONDecoder().decode([ReadingPrompt].self, from: data)) ?? []
        }
        refreshInput()
    }

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

    private func settingsChanged() {
        if !phase.busy {
            if engineKey != key(settings) { engine = nil; modelLoaded = false }
            refreshInput()
        }
        do { try settings.save(project: project) }
        catch { errorMessage = error.localizedDescription }
    }

    public func startRecording() {
        guard !phase.busy else { return }
        let id = begin()
        let options = settings
        let prompt = selectedPrompt?.reference ?? ""
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.preparedEngine(options)
                try self.check(id)
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language, onPartial: nil)
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
                var samples: [Float] = []
                var stats = AudioStatistics()
                for try await chunk in stream {
                    try self.check(id)
                    // Bound audio by frames too: hardware buffers can arrive just after the timer.
                    let remaining = Int(maximum * AudioChunk.sampleRate) - samples.count
                    guard remaining > 0 else { self.stopRecording(); break }
                    let values = Array(chunk.samples.prefix(remaining))
                    try await engine.append(AudioChunk(samples: values, timestamp: Double(samples.count) / AudioChunk.sampleRate), sessionID: id)
                    samples += values
                    stats.append(values)
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
                let saved = try self.saveAudioIfRequested(samples, options: options, id: id)
                let text = try await engine.finish(sessionID: id)
                try self.check(id)
                self.complete(id: id, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: self.inputName, saved: saved,
                              options: options, prompt: prompt)
            } catch { await self.failed(error, id: id) }
            self.cleanup(id)
        }
    }

    public func transcribeFile(_ url: URL) {
        guard !phase.busy else { return }
        let id = begin(), options = settings
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try AudioFile.read(url)
                let engine = try await self.preparedEngine(options)
                try self.check(id)
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language, onPartial: nil)
                var stats = AudioStatistics(); stats.append(samples)
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
                self.complete(id: id, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: url.lastPathComponent,
                              saved: url, options: options, prompt: "")
            } catch { await self.failed(error, id: id) }
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
            player = try AVAudioPlayer(data: Self.wavData(run.samples))
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

    private func saveAudioIfRequested(_ samples: [Float], options: StudioSettings, id: UUID) throws -> URL? {
        guard options.saveAudio else { return nil }
        guard !options.audioDirectory.isEmpty else { throw StudioError.message("Choose a folder for saved recordings.") }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = URL(fileURLWithPath: options.audioDirectory).appendingPathComponent("nami-\(timestamp)-\(id.uuidString.prefix(8)).wav")
        try AudioFile.write(samples, to: url)
        return url
    }

    private func complete(id: UUID, text: String, samples: [Float], statistics: AudioStatistics,
                          latency: Double, input: String, saved: URL?, options: StudioSettings, prompt: String) {
        let run = RecordingRun(id: id, date: .now, transcript: text, audioSeconds: statistics.duration,
            latency: latency, averageDB: statistics.rmsDBFS, peakDB: statistics.peakDBFS,
            input: input, savedURL: saved, engine: options.engine,
            model: URL(fileURLWithPath: options.modelFolder).lastPathComponent, prompt: prompt, samples: samples)
        runs.insert(run, at: 0)
        if runs.count > 12 { runs.removeLast() }
        selectedRunID = id
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "No speech recognized. Listen back to check the recording."
        } else {
            if options.copyWhenFinished {
                status = copyToClipboard(text) ? "Transcript copied. Paste it wherever you need it." : "Your transcript is ready."
            } else {
                status = "Your transcript is ready. Copy it whenever you need it."
            }
        }
        // Keep the indicator processing until publication and clipboard handoff finish.
        phase = .idle
    }

    private func failed(_ error: Error, id: UUID) async {
        capture?.stop(); capture = nil; ticker?.cancel()
        await engine?.cancel(sessionID: id)
        guard activeID == id else { return }
        if error is CancellationError || error as? EngineError == .cancelled || phase == .cancelling {
            phase = .idle; status = "Run cancelled. Ready for another take."
        } else {
            phase = .failed; errorMessage = error.localizedDescription; status = "This run could not finish."
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

    /// PCM16 WAV in memory, so listening back never creates an implicit audio file.
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
