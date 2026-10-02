import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog
import NamiAudio
import NamiCore
import NamiWhisperKit
import NamiMLXCleanup

public enum StudioPhase: String, Sendable {
    case idle, preparing, recording, processing, cancelling, failed
    /// The microphone could not start; the indicator asks for another one.
    case choosingMicrophone
    public var busy: Bool { self != .idle && self != .failed }
    /// The indicator's close button and Escape cancel these phases.
    public var cancellableFromIndicator: Bool { self == .recording || self == .choosingMicrophone }
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
    public var rawTranscript: String?
    public var cleanupResult: CleanupResult?
    /// Set when the transcript was replaced by this snippet; `rawTranscript` keeps what was said.
    public var snippetName: String?
    /// Set when the recording ran this action instead of being pasted.
    public var actionName: String?
    /// Wait from the end of the recording until speech recognition returned text, before cleanup.
    public var transcriptionSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case id, date, transcript, audioSeconds, latency, averageDB, peakDB
        case input, savedURL, engine, model, prompt, outcome
        case rawTranscript, cleanupResult, snippetName, actionName, transcriptionSeconds
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
    public var busyForUpdate: Bool { phase.busy || debugging.isBusy || debugging.cleanupLab.isBusy || cleanupService.managingModels || modelMaintenance }
    private(set) var modelMaintenance = false
    @ObservationIgnored lazy var modelLibrary = ModelLibrary(roots: [cleanupService.modelsRoot, debugging.directory.appendingPathComponent("Models")])
    public let permissions: StudioPermissions
    public let modifierShortcut = ModifierRecordingShortcut()
    public var settings: StudioSettings {
        didSet {
            if settings != oldValue { settingsChanged() }
        }
    }
    public let project: URL
    public private(set) var phase: StudioPhase = .idle
    public private(set) var isCleaningUp = false
    public private(set) var isPasting = false
    public private(set) var retranscribingRunID: UUID?
    public private(set) var status = "Your next thought starts here."
    public private(set) var errorMessage: String?
    public private(set) var modelLoaded = false
    public private(set) var modelPreparing = false
    public private(set) var modelPreparationError: String?
    public private(set) var modelPreparationSeconds: Double?
    public private(set) var captureStartSeconds: Double?
    public private(set) var firstAudioSeconds: Double?
    public private(set) var elapsed = 0.0
    /// The microphone is open but has only sent digital silence, as Bluetooth
    /// headsets do for a second or more while they switch to their microphone.
    public private(set) var awaitingMicrophone = false
    /// How long an open microphone may stay silent before Nami asks for another.
    var microphoneWarmupTimeout: Duration = .seconds(6)
    public private(set) var level = 0.0
    public private(set) var meterHistory = Array(repeating: 0.0, count: 64)
    public private(set) var inputName = "System default microphone"
    public private(set) var inputDevices: [AudioInputDevice] = []
    /// Why the indicator is asking for a microphone; set only while choosing one.
    public private(set) var microphoneIssue: String?
    /// nil when the selected microphone has no settable hardware volume.
    public private(set) var inputVolume: Double?
    public private(set) var capturedSeconds = 0.0
    public private(set) var averageDB = -Double.infinity
    public private(set) var runs: [RecordingRun] = []
    public var selectedRunID: UUID?
    public var selectedPromptID = ""
    public private(set) var prompts: [ReadingPrompt] = []
    public private(set) var playing = false
    /// Used by the next finished recording only, from whichever app is in front.
    public private(set) var pinnedDestination: PinnedTranscriptDestination?
    public private(set) var pinNotice: String?
    public let debugging: DebuggingSession
    public var snippets = SnippetLibrary() {
        didSet {
            guard snippets != oldValue, !snippetsLoadFailed, !applyingStoredSnippets else { return }
            do { try snippetStore.save(snippets); snippetsModified = snippetStore.modificationDate() }
            catch { errorMessage = "Could not save snippets: \(error.localizedDescription)" }
        }
    }
    /// A damaged snippets file is kept as is; edits stay in memory until it is fixed.
    public private(set) var snippetsLoadFailed = false
    public var actions = ActionLibrary() {
        didSet {
            guard actions != oldValue, !actionsLoadFailed, !applyingStoredActions else { return }
            do { try actionStore.save(actions); actionsModified = actionStore.modificationDate() }
            catch { errorMessage = "Could not save actions: \(error.localizedDescription)" }
        }
    }
    /// A damaged actions file is kept as is; edits stay in memory until it is fixed.
    public private(set) var actionsLoadFailed = false
    var cleanupService: CleanupService { debugging.cleanupLab.service }

    @ObservationIgnored private let historyStore: RecordingHistoryStore
    @ObservationIgnored private let snippetStore: SnippetStore
    @ObservationIgnored private var snippetsModified: Date?
    @ObservationIgnored private var applyingStoredSnippets = false
    @ObservationIgnored private let actionStore: ActionStore
    @ObservationIgnored private var actionsModified: Date?
    @ObservationIgnored private var applyingStoredActions = false
    @ObservationIgnored private let actionRunner: ActionStepRunner
    @ObservationIgnored private let engineBuilder: @MainActor (StudioSettings) throws -> any TranscriptionEngine
    @ObservationIgnored private let captureBuilder: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private let inputDevicesProvider: @MainActor () -> [AudioInputDevice]
    @ObservationIgnored private let inputVolumeControl: InputVolumeControl
    @ObservationIgnored private let clipboardWriter: @MainActor (String) -> Bool
    @ObservationIgnored private let pastePreparer: @MainActor () -> PreparedTranscriptPaste
    @ObservationIgnored private let destinationPinner: @MainActor () async -> TranscriptPinAttempt
    @ObservationIgnored private let selectionReading: SelectionReading
    @ObservationIgnored private var highlightWatch: Task<Void, Never>?
    @ObservationIgnored private var highlightTracker = HighlightTracker()
    /// Words in the latest live preview, which places highlights in the speech.
    @ObservationIgnored private var liveWords: Int?
    @ObservationIgnored private var pinning: Task<Void, Never>?
    @ObservationIgnored private var pinNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var engine: (any TranscriptionEngine)?
    @ObservationIgnored private var engineKey = ""
    @ObservationIgnored private var preparation: EnginePreparation?
    @ObservationIgnored private var retiredPreparations: [EnginePreparation] = []
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var automaticPreparationEnabled = false
    private static let startupLog = Logger(subsystem: "local.nami.studio", category: "Startup")
    @ObservationIgnored private var capture: (any AudioCapturing)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var microphoneWatch: Task<Void, Never>?
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
                destinationPinner: @escaping @MainActor () async -> TranscriptPinAttempt = { .failed("Pinning is unavailable.") },
                // Unavailable by default: the live reader copies in Google editors.
                selectionReading: SelectionReading = .unavailable,
                engineBuilder: (@MainActor (StudioSettings) throws -> any TranscriptionEngine)? = nil,
                cleanupProcessors: [CleanupEngine: any TextProcessor] = [:],
                modelDirectory: URL? = nil,
                captureBuilder: @escaping @MainActor (String?) -> any AudioCapturing,
                inputDevicesProvider: @escaping @MainActor () -> [AudioInputDevice] = { AudioInputDevice.available() },
                // Unavailable by default: the live control changes the level for every app.
                inputVolumeControl: InputVolumeControl = .unavailable,
                // Unavailable by default: the live runner opens apps and runs commands.
                actionRunner: @escaping ActionStepRunner = { _ in throw StudioError.message("Actions are unavailable.") },
                clipboardWriter: @escaping @MainActor (String) -> Bool) {
        self.project = project
        self.historyStore = RecordingHistoryStore(directory: historyDirectory ?? RecordingHistoryStore.defaultDirectory)
        self.snippetStore = SnippetStore(url: historyDirectory?.appendingPathComponent("Snippets/snippets.json") ?? SnippetStore.defaultURL)
        self.actionStore = ActionStore(url: historyDirectory?.appendingPathComponent("Actions/actions.json") ?? ActionStore.defaultURL)
        self.actionRunner = actionRunner
        let debuggingDirectory = historyDirectory?.appendingPathComponent("InternalDebugging")
            ?? RecordingHistoryStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("InternalDebugging")
        self.debugging = DebuggingSession(directory: debuggingDirectory,
            cleanupService: CleanupService(processors: cleanupProcessors, modelsRoot: modelDirectory ?? QwenModelAssets.root),
            apiKeyStore: CommandLine.arguments.contains("--snapshot") ? nil
                : .keychain(account: debuggingDirectory.standardizedFileURL.path))
        self.permissions = permissions ?? StudioPermissions()
        self.pastePreparer = pastePreparer
        self.destinationPinner = destinationPinner
        self.selectionReading = selectionReading
        self.engineBuilder = engineBuilder ?? { settings in
            var config = EngineConfiguration()
            guard let backend = EngineConfiguration.Backend(rawValue: settings.engine) else {
                throw StudioError.message("Choose fast dictation, WhisperKit, or the demo engine.")
            }
            config.backend = backend
            config.modelFolder = settings.modelFolder
            config.fakeTranscript = "This is a demo transcript. Switch to WhisperKit to recognize your speech."
            return try EngineFactory.make(config)
        }
        self.captureBuilder = captureBuilder
        self.inputDevicesProvider = inputDevicesProvider
        self.inputVolumeControl = inputVolumeControl
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
        snippetsModified = snippetStore.modificationDate()
        do { snippets = try snippetStore.load() }
        catch {
            snippetsLoadFailed = true
            errorMessage = "Could not load snippets. The file was kept unchanged: \(error.localizedDescription)"
        }
        actionsModified = actionStore.modificationDate()
        do { actions = try actionStore.load() }
        catch {
            actionsLoadFailed = true
            errorMessage = "Could not load actions. The file was kept unchanged: \(error.localizedDescription)"
        }
        refreshInput()
    }

    /// Live integrations for the app only; tests must never pass these.
    public static func systemPastePreparer() -> PreparedTranscriptPaste { TranscriptPaster().prepare() }
    public static func systemDestinationPinner() async -> TranscriptPinAttempt { await TranscriptPaster().pin() }
    public static func systemCapture(deviceUID: String?) -> any AudioCapturing { MicrophoneCapture(deviceUID: deviceUID) }
    public static func systemActionRunner(_ step: ActionStep) async throws { try await SystemActionRunner.run(step) }
    public static func systemClipboardWriter(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    public var historyDirectory: URL { historyStore.directory }

    /// Picks up edits made outside the app, such as by the `nami-snippets` CLI. Cheap when nothing changed.
    public func refreshSnippetsIfChanged() {
        let modified = snippetStore.modificationDate()
        guard modified != snippetsModified else { return }
        snippetsModified = modified
        do {
            let stored = try snippetStore.load()
            applyingStoredSnippets = true
            defer { applyingStoredSnippets = false }
            snippets = stored
            snippetsLoadFailed = false
        } catch {
            snippetsLoadFailed = true
            errorMessage = "Could not load snippets. The file was kept unchanged: \(error.localizedDescription)"
        }
    }

    /// Picks up edits made outside the app. Cheap when nothing changed.
    public func refreshActionsIfChanged() {
        let modified = actionStore.modificationDate()
        guard modified != actionsModified else { return }
        actionsModified = modified
        do {
            let stored = try actionStore.load()
            applyingStoredActions = true
            defer { applyingStoredActions = false }
            actions = stored
            actionsLoadFailed = false
        } catch {
            actionsLoadFailed = true
            errorMessage = "Could not load actions. The file was kept unchanged: \(error.localizedDescription)"
        }
    }
    public var selectedRun: RecordingRun? { runs.first { $0.id == selectedRunID } ?? runs.first }
    public var selectedPrompt: ReadingPrompt? { prompts.first { $0.id == selectedPromptID } }
    public var modelName: String {
        settings.engine == "fake" ? "Demo engine" : settings.engine == "fast" ? "Parakeet Ultra · Whisper verification" : (settings.modelFolder.isEmpty ? "Choose a model folder" : URL(fileURLWithPath: settings.modelFolder).lastPathComponent)
    }
    public var selectedMicrophoneUnavailable: Bool {
        guard let uid = settings.microphoneUID else { return false }
        return !inputDevices.contains { $0.id == uid }
    }
    /// The system default is only worth offering when a specific microphone failed.
    public var offersSystemDefaultMicrophone: Bool { settings.microphoneUID != nil && !inputDevices.isEmpty }

    public func refreshInput() {
        guard !phase.busy else { return }
        inputDevices = inputDevicesProvider()
        if let uid = settings.microphoneUID {
            inputName = inputDevices.first { $0.id == uid }?.name ?? "Selected microphone unavailable"
        } else {
            inputName = MicrophoneCapture.defaultDeviceName()
        }
        inputVolume = selectedMicrophoneUnavailable ? nil : inputVolumeControl.read(settings.microphoneUID)
    }

    /// Hardware volume is safe to change mid-recording, so this is not gated on the phase.
    public func setInputVolume(_ volume: Double) {
        guard inputVolume != nil else { return }
        let volume = min(1, max(0, volume))
        inputVolumeControl.write(volume, settings.microphoneUID)
        inputVolume = volume
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
        if settings.cleanupEnabled { cleanupService.prewarm(settings.cleanupEngine) }
    }

    private func prepareInBackground() {
        guard !modelMaintenance else { return }
        guard settings.engine == "fake" || !settings.modelFolder.isEmpty else { return }
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
        if settings.cleanupEnabled { cleanupService.prewarm(settings.cleanupEngine) }
        if !phase.busy {
            if engineKey != key(settings) {
                retainUnfinishedPreparation()
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
        guard !modelMaintenance, !phase.busy, !debugging.isBusy, !debugging.cleanupLab.isBusy, permissionsReady() else { return }
        debugging.stopPlayback()
        let id = begin(), date = Date()
        status = "Starting microphone…"
        let options = settings
        let paste = options.pasteWhenFinished ? pastePreparer() : nil
        let prompt = selectedPrompt?.reference ?? ""
        operation = Task { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            var stats = AudioStatistics()
            var rawText: String?
            let speculative = options.cleanupEnabled && options.engine == "fast" ? self.cleanupService.speculation(
                id: id, language: options.language,
                memory: options.cleanupUseMemory ? self.debugging.cleanupLab.memory : CleanupMemory(),
                engine: options.cleanupEngine, timeout: options.cleanupTimeoutSeconds) : nil
            let liveAudio = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            var feeding: Task<Void, Error>?
            var warmup: Task<Void, Never>?
            var captureStarted = false
            defer { liveAudio.continuation.finish(); feeding?.cancel(); warmup?.cancel() }
            do {
                try self.check(id)
                self.refreshPermissions()
                try self.check(id)
                let capture = self.captureBuilder(options.microphoneUID)
                self.capture = capture
                let stream = try await capture.start()
                captureStarted = true
                try self.check(id)
                self.captureStartSeconds = Self.seconds(since: requestedAt)
                Self.startupLog.info("Microphone started after \(self.captureStartSeconds!, privacy: .public) seconds")
                self.inputName = capture.inputDescription
                self.phase = .recording
                if options.quoteHighlights { self.watchHighlights(id) }
                self.awaitingMicrophone = true
                self.status = "Waiting for the microphone…"
                if options.cleanupEnabled { self.cleanupService.prewarm(options.cleanupEngine) }
                let timeout = self.microphoneWarmupTimeout
                warmup = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self, self.activeID == id, self.awaitingMicrophone else { return }
                    // Ending the stream without audio offers another microphone.
                    capture.stop()
                }
                // Capture must never wait for the model. Drain the stream into
                // our recording buffer while preparation runs separately.
                let preparation = try self.preparationFor(options, retryFailure: true)
                let feed = Task {
                    let engine = try await preparation.value()
                    try self.check(id)
                    await engine.setPromptObserver(self.debugging.promptStore.observer(source: "Live dictation"))
                    let onPartial: (@Sendable (String) -> Void)?
                    if speculative != nil || options.quoteHighlights {
                        onPartial = { text in Task { @MainActor in
                            if options.quoteHighlights, self.activeID == id {
                                self.liveWords = text.split(whereSeparator: \.isWhitespace).count
                            }
                            speculative?.offer(text)
                        } }
                    } else { onPartial = nil }
                    try await engine.startLive(sessionID: id, language: options.language == "auto" ? nil : options.language,
                                               vocabulary: options.vocabulary, onPartial: onPartial)
                    for try await chunk in liveAudio.stream {
                        try self.check(id)
                        try await engine.append(chunk, sessionID: id)
                    }
                    try self.check(id)
                }
                feeding = feed
                for try await chunk in stream {
                    try self.check(id)
                    var audio = chunk.samples
                    if self.awaitingMicrophone {
                        // Exact zeros are a device that is not ready yet, never a quiet room,
                        // so "Listening" and the take begin with the first real sound.
                        guard let first = audio.firstIndex(where: { $0 != 0 }) else { continue }
                        audio.removeFirst(first)
                        self.awaitingMicrophone = false
                        warmup?.cancel()
                        if self.phase == .recording { self.status = "Listening. Speak naturally." }
                        self.firstAudioSeconds = Self.seconds(since: requestedAt)
                        Self.startupLog.info("First audio received after \(self.firstAudioSeconds!, privacy: .public) seconds")
                        let startedAt = ContinuousClock.now
                        self.ticker = Task { [weak self] in
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .milliseconds(50))
                                guard !Task.isCancelled, let self, self.phase == .recording else { return }
                                self.elapsed = Self.seconds(since: startedAt)
                            }
                        }
                    }
                    let timestamp = Double(samples.count) / AudioChunk.sampleRate
                    samples += audio
                    liveAudio.continuation.yield(AudioChunk(samples: audio, timestamp: timestamp))
                    stats.append(audio)
                    var instant = AudioStatistics(); instant.append(audio)
                    self.level = max(0, min(1, (instant.rmsDBFS + 60) / 60))
                    self.meterHistory.removeFirst(); self.meterHistory.append(self.level)
                    self.capturedSeconds = stats.duration
                    self.averageDB = stats.rmsDBFS
                }
                self.ticker?.cancel()
                self.highlightWatch?.cancel()
                if options.quoteHighlights { self.selectionReading.end() }
                self.highlightTracker.finish(seconds: stats.duration)
                let highlights = options.quoteHighlights ? self.highlightTracker.highlights : []
                self.awaitingMicrophone = false
                speculative?.recordingEnded()
                liveAudio.continuation.finish()
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
                try await withTaskCancellationHandler {
                    try await feed.value
                } onCancel: { feed.cancel() }
                let engine = preparation.engine
                try self.check(id)
                self.refreshPermissions()
                try self.check(id)
                self.status = "Turning your audio into text…"
                let text = try await engine.finish(sessionID: id)
                try self.check(id)
                rawText = text
                try await self.complete(id: id, date: date, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: self.inputName,
                              options: options, prompt: prompt, paste: paste, allowsPin: true, runsActions: true,
                              speculative: speculative, highlights: highlights)
                await speculative?.cancel()
            } catch {
                await speculative?.cancel()
                liveAudio.continuation.finish()
                feeding?.cancel()
                _ = await feeding?.result
                let issue = samples.isEmpty ? Self.microphoneIssue(for: error, beforeCapture: !captureStarted) : nil
                if let issue, await self.offerMicrophoneChoice(issue, id: id) {
                    // Nothing was recorded, so there is no take to keep.
                } else {
                    self.keepUnfinished(id: id, date: date, samples: samples, statistics: stats,
                                        input: self.inputName, options: options, prompt: prompt, error: error, rawText: rawText)
                    await self.failed(error, id: id)
                }
            }
            self.cleanup(id)
        }
    }

    /// Picks the microphone the indicator asked for, then starts the recording
    /// that could not begin. A nil UID follows the system default.
    public func chooseMicrophone(_ uid: String?) {
        guard phase == .choosingMicrophone else { return }
        endMicrophoneChoice()
        phase = .idle
        settings.microphoneUID = uid
        startRecording()
    }

    /// Only failures that another microphone could fix ask for one.
    static func microphoneIssue(for error: Error, beforeCapture: Bool) -> String? {
        switch error as? AudioInputError {
        case .deviceUnavailable: return "Your microphone isn’t connected."
        case .noAudioReceived: return "No sound came from your microphone."
        case .permissionDenied: return nil
        default: return beforeCapture && !(error is CancellationError) ? "Your microphone couldn’t start." : nil
        }
    }

    private func offerMicrophoneChoice(_ issue: String, id: UUID) async -> Bool {
        capture?.stop(); capture = nil; ticker?.cancel()
        await engine?.cancel(sessionID: id)
        guard activeID == id, phase != .cancelling else { return false }
        inputDevices = inputDevicesProvider()
        microphoneIssue = issue
        phase = .choosingMicrophone
        status = "Choose a microphone to start recording."
        // Polling keeps the choices current when a microphone is plugged in.
        microphoneWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.phase == .choosingMicrophone else { return }
                let devices = self.inputDevicesProvider()
                if devices != self.inputDevices { self.inputDevices = devices }
            }
        }
        return true
    }

    private func endMicrophoneChoice() {
        microphoneWatch?.cancel(); microphoneWatch = nil
        microphoneIssue = nil
    }

    public func transcribeFile(_ url: URL) {
        transcribeAudio(url, replacing: nil)
    }

    /// Reuse the saved take with today's model, vocabulary, and cleanup settings.
    public func retranscribeRun(_ id: UUID) {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        transcribeAudio(run.savedURL, replacing: run)
    }

    private func transcribeAudio(_ url: URL?, replacing previous: RecordingRun?) {
        guard !busyForUpdate, permissionsReady() else { return }
        debugging.stopPlayback()
        let id = begin(id: previous?.id), date = previous?.date ?? Date()
        let input = previous?.input ?? url?.lastPathComponent ?? "Saved recording"
        let prompt = previous?.prompt ?? ""
        var options = settings
        if previous != nil {
            retranscribingRunID = id
            selectedRunID = id
            options.copyWhenFinished = false
            status = "Re-transcribing your recording…"
        }
        operation = Task { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            var stats = AudioStatistics()
            var rawText: String?
            do {
                if let previous, !previous.samples.isEmpty { samples = previous.samples }
                else if let url { samples = try AudioFile.read(url) }
                else { throw StudioError.message("The saved audio for this recording is unavailable.") }
                guard !samples.isEmpty else { throw EngineError.noAudio }
                stats.append(samples)
                if previous == nil {
                    _ = self.archive(id: id, date: date, text: "", samples: samples, statistics: stats,
                                     input: input, options: options, prompt: prompt, outcome: .interrupted)
                }
                let engine = try await self.preparedEngine(options)
                try self.check(id)
                await engine.setPromptObserver(self.debugging.promptStore.observer(source: previous == nil ? "Audio import" : "History retry"))
                // Files are fed faster than real time, so recognition starts with the first chunk.
                let stop = ContinuousClock.now
                try await engine.start(sessionID: id, language: options.language == "auto" ? nil : options.language,
                                       vocabulary: options.vocabulary, onPartial: nil)
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    try self.check(id)
                    try await engine.append(AudioChunk(samples: Array(samples[offset..<min(samples.count, offset + 1600)]), timestamp: Double(offset) / AudioChunk.sampleRate), sessionID: id)
                }
                self.phase = .processing
                self.status = previous == nil ? "Transcribing \(input)…" : "Re-transcribing your recording…"
                self.capturedSeconds = stats.duration
                self.elapsed = stats.duration
                self.averageDB = stats.rmsDBFS
                let text = try await engine.finish(sessionID: id)
                try self.check(id)
                rawText = text
                try await self.complete(id: id, date: date, text: text, samples: samples, statistics: stats,
                              latency: Self.seconds(since: stop), input: input,
                              options: options, prompt: prompt, replacing: previous)
            } catch {
                if previous == nil {
                    self.keepUnfinished(id: id, date: date, samples: samples, statistics: stats,
                                        input: input, options: options, prompt: prompt, error: error, rawText: rawText)
                }
                await self.failed(error, id: id)
            }
            self.cleanup(id)
        }
    }

    /// Polls the frontmost app's selection while recording. Reading never changes it.
    private func watchHighlights(_ id: UUID) {
        highlightTracker = HighlightTracker()
        selectionReading.begin()
        highlightWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeID == id, self.phase == .recording else { return }
                let selection = await self.selectionReading.read()
                guard !Task.isCancelled, self.activeID == id, self.phase == .recording else { return }
                self.highlightTracker.observe(selection, spokenWords: self.liveWords, seconds: self.capturedSeconds)
                try? await Task.sleep(for: .milliseconds(250))
            }
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
        guard !modelMaintenance, !phase.busy, !debugging.isBusy, permissionsReady() else { return }
        stopPlayback()
        debugging.startRecording(microphoneUID: settings.microphoneUID, language: settings.language)
    }

    public func toggleRecording() {
        switch phase {
        case .idle, .failed: startRecording()
        case .recording: stopRecording()
        case .choosingMicrophone: cancel()
        case .preparing, .processing, .cancelling: break
        }
    }

    /// Pins the focused field for the next transcript, or clears an existing pin.
    /// Works before or during a recording; the paste target captured at start is skipped.
    public func togglePinnedDestination() {
        if let pinned = pinnedDestination {
            pinnedDestination = nil
            showPinNotice("Unpinned \(pinned.appName).")
            return
        }
        guard pinning == nil else { return }
        pinning = Task { [weak self] in
            guard let self else { return }
            let attempt = await self.destinationPinner()
            self.pinning = nil
            switch attempt {
            case .pinned(let destination):
                self.pinnedDestination = destination
                self.pinNoticeTask?.cancel()
                self.pinNotice = nil
                if !self.phase.busy { self.status = "Your next transcript goes to \(destination.appName)." }
            case .failed(let message):
                self.showPinNotice(message)
            }
        }
    }

    private func showPinNotice(_ message: String) {
        pinNoticeTask?.cancel()
        pinNotice = message
        if !phase.busy { status = message }
        pinNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.pinNotice = nil
        }
    }

    public func cancel() {
        if phase == .choosingMicrophone {
            endMicrophoneChoice()
            phase = .idle
            status = "Recording cancelled. Ready when you are."
            refreshInput()
            return
        }
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

    @discardableResult public func copyOriginalTranscript(_ run: RecordingRun) -> Bool {
        let text = run.rawTranscript ?? run.transcript
        guard !text.isEmpty else { return false }
        return copyToClipboard(text)
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
        guard retranscribingRunID != id else { return }
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

    private func begin(id: UUID? = nil) -> UUID {
        stopPlayback()
        errorMessage = nil; phase = .preparing; isCleaningUp = false; isPasting = false; status = "Preparing the local model…"
        elapsed = 0; capturedSeconds = 0; level = 0; averageDB = -.infinity; awaitingMicrophone = false
        captureStartSeconds = nil; firstAudioSeconds = nil
        meterHistory = Array(repeating: 0, count: 64)
        let id = id ?? UUID(); activeID = id; stoppedAt = nil
        liveWords = nil
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
        retainUnfinishedPreparation()
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
                         outcome: RecordingOutcome, rawText: String? = nil, cleanupResult: CleanupResult? = nil,
                         snippetName: String? = nil, actionName: String? = nil,
                         transcriptionSeconds: Double? = nil) -> RecordingRun {
        let run = RecordingRun(id: id, date: date, transcript: text, audioSeconds: statistics.duration,
            latency: latency, averageDB: statistics.rmsDBFS, peakDB: statistics.peakDBFS,
            input: input, savedURL: nil, engine: options.engine,
            model: options.engine == "fast" ? "Parakeet Ultra · Whisper verification" : URL(fileURLWithPath: options.modelFolder).lastPathComponent, prompt: prompt,
            samples: samples, outcome: outcome, rawTranscript: rawText, cleanupResult: cleanupResult, snippetName: snippetName,
            actionName: actionName, transcriptionSeconds: transcriptionSeconds)
        do { return try historyStore.save(run) }
        catch {
            errorMessage = "Could not save this recording to history. Keep Nami open to retain its audio and text. \(error.localizedDescription)"
            return run
        }
    }

    private func keepUnfinished(id: UUID, date: Date, samples: [Float], statistics: AudioStatistics,
                                input: String, options: StudioSettings, prompt: String, error: Error, rawText: String? = nil) {
        guard !samples.isEmpty else { return }
        let cancelled = error is CancellationError || error as? EngineError == .cancelled || phase == .cancelling
        let run = archive(id: id, date: date, text: rawText ?? "", samples: samples, statistics: statistics,
                          input: input, options: options, prompt: prompt, outcome: cancelled ? .cancelled : .failed, rawText: rawText)
        runs.insert(run, at: 0)
        selectedRunID = id
    }

    /// An action replaces pasting: nothing is copied, cleaned up, or typed, and history keeps what was said.
    private func perform(_ match: ActionMatch, id: UUID, date: Date, text: String, samples: [Float], statistics: AudioStatistics,
                         latency: Double, transcriptionSeconds: Double, input: String, options: StudioSettings, prompt: String) async {
        let title = match.action.title
        status = "Running “\(title)”…"
        var failure: String?
        for step in match.steps {
            do { try await actionRunner(step) }
            catch { failure = error.localizedDescription; break }
        }
        let run = archive(id: id, date: date, text: text, samples: samples, statistics: statistics, latency: latency,
                          input: input, options: options, prompt: prompt, outcome: .completed, actionName: title,
                          transcriptionSeconds: transcriptionSeconds)
        runs.insert(run, at: 0)
        selectedRunID = id
        if let failure {
            status = "Action “\(title)” failed."
            errorMessage = "Action “\(title)” failed: \(failure)"
        } else {
            status = "Ran action “\(title)”."
        }
        phase = .idle
    }

    private func complete(id: UUID, date: Date, text: String, samples: [Float], statistics: AudioStatistics,
                          latency: Double, input: String, options: StudioSettings, prompt: String,
                          paste: PreparedTranscriptPaste? = nil, allowsPin: Bool = false, runsActions: Bool = false,
                          replacing previous: RecordingRun? = nil, speculative: SpeculativeCleanup? = nil,
                          highlights: [CapturedHighlight] = []) async throws {
        let started = ContinuousClock.now
        // Only live dictation runs actions; imports and retries just transcribe.
        refreshActionsIfChanged()
        if runsActions, let match = actions.match(text) {
            await perform(match, id: id, date: date, text: text, samples: samples, statistics: statistics,
                          latency: latency + Self.seconds(since: started), transcriptionSeconds: latency,
                          input: input, options: options, prompt: prompt)
            return
        }
        let original = text
        var text = text
        var processing: CleanupResult?
        // A snippet replaces the dictation with the user's own text, so cleanup must not rewrite it.
        refreshSnippetsIfChanged()
        let snippet = snippets.expand(original)
        if let snippet { text = snippet.text }
        else if options.cleanupEnabled, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isCleaningUp = true
            status = "Cleaning up your dictation…"
            // Persist ASR before awaiting another model, including when the app is interrupted.
            if previous == nil {
                _ = archive(id: id, date: date, text: original, samples: samples, statistics: statistics,
                            latency: latency, input: input, options: options, prompt: prompt,
                            outcome: .interrupted, rawText: original, transcriptionSeconds: latency)
            }
            let memory = options.cleanupUseMemory ? debugging.cleanupLab.memory : CleanupMemory()
            var request = CleanupRequest(id: id, rawText: original, language: options.language, memory: memory)
            request.prompts = debugging.promptStore.configuration
            processing = try await speculative?.finish(matching: request)
            if let processing { debugging.promptStore.record(processing) }
            else {
                processing = try await cleanupService.run(request, engine: options.cleanupEngine,
                    timeout: options.cleanupTimeoutSeconds, source: previous == nil ? "Dictation cleanup" : "History retry cleanup")
            }
            try check(id)
            text = processing?.text ?? original
            isCleaningUp = false
        }
        try check(id)
        var quoting: HighlightQuotes.Result?
        if snippet == nil, !highlights.isEmpty {
            let result = HighlightQuotes.apply(highlights, spoken: original, edited: text, audioSeconds: statistics.duration)
            quoting = result
            text = result.text
        }
        if let previous {
            // Replace metadata only after the entire retry succeeds. A failed save
            // leaves the old transcript in memory and on disk, and audio is immutable.
            let run = RecordingRun(id: id, date: previous.date, transcript: text,
                audioSeconds: previous.audioSeconds, latency: latency + Self.seconds(since: started),
                averageDB: previous.averageDB, peakDB: previous.peakDB, input: previous.input,
                savedURL: previous.savedURL, engine: options.engine,
                model: options.engine == "fast" ? "Parakeet Ultra · Whisper verification" : URL(fileURLWithPath: options.modelFolder).lastPathComponent, prompt: previous.prompt,
                samples: samples, outcome: .completed, rawTranscript: options.cleanupEnabled || snippet != nil ? original : nil,
                cleanupResult: processing, snippetName: snippet?.snippet.title, transcriptionSeconds: latency)
            let stored = try historyStore.save(run)
            if let index = runs.firstIndex(where: { $0.id == id }) { runs[index] = stored }
        } else {
            let run = archive(id: id, date: date, text: text, samples: samples, statistics: statistics,
                          latency: latency + Self.seconds(since: started), input: input, options: options, prompt: prompt,
                          outcome: .completed, rawText: options.cleanupEnabled || snippet != nil ? original : nil,
                          cleanupResult: processing, snippetName: snippet?.snippet.title, transcriptionSeconds: latency)
            runs.insert(run, at: 0)
        }
        selectedRunID = id
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "No speech recognized. Listen back to check the recording."
        } else if allowsPin, let destination = pinnedDestination {
            // A pin is an explicit request, so it applies even with automatic paste off.
            pinnedDestination = nil
            let copied = options.copyWhenFinished && copyToClipboard(text)
            isPasting = true
            status = await destination.insert(text).status(app: destination.appName, copied: copied)
        } else {
            // Pasting replaces the selection, which may be a highlight in the same field.
            let keepsHighlight = paste != nil && quoting != nil ? await highlightStillSelected(highlights) : false
            let copied = (options.copyWhenFinished || keepsHighlight) && copyToClipboard(text)
            if keepsHighlight {
                status = copied ? "Transcript copied. Paste skipped so your highlighted text isn’t replaced."
                    : "Paste skipped so your highlighted text isn’t replaced. Copy it from your history."
            } else if let paste {
                isPasting = true
                status = await paste(text, !copied).status(copied: copied)
            } else if copied {
                status = "Transcript copied. Paste it wherever you need it."
            } else {
                status = "Your transcript is ready. Copy it whenever you need it."
            }
        }
        if let processing, !processing.succeeded { status += " Cleanup skipped; original text kept." }
        if let quoting { status += Self.quotingStatus(quoting) }
        if let snippet { status += " Used snippet “\(snippet.snippet.title)”." }
        else if snippets.mentionsTrigger(original) { status += " No snippet matched, so your words were kept as said." }
        isPasting = false
        // Keep the indicator processing until publication and the paste handoff finish.
        phase = .idle
    }

    private func highlightStillSelected(_ highlights: [CapturedHighlight]) async -> Bool {
        guard let current = await selectionReading.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty
        else { return false }
        return highlights.contains { $0.text == current }
    }

    static func quotingStatus(_ result: HighlightQuotes.Result) -> String {
        func count(_ n: Int) -> String { n == 1 ? "1 highlight" : "\(n) highlights" }
        var parts: [String] = []
        if result.quoted > 0 { parts.append("Quoted \(count(result.quoted)).") }
        if result.unmatched > 0 {
            parts.append("\(count(result.unmatched)) had no “this” or “that” nearby, so \(result.unmatched == 1 ? "it was" : "they were") left out.")
        }
        if result.usedOriginal { parts.append("Cleanup reworded them, so your original wording was kept.") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
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
        activeID = nil; operation = nil; ticker?.cancel(); ticker = nil; level = 0; isCleaningUp = false; isPasting = false
        if highlightWatch != nil { selectionReading.end() }
        highlightWatch?.cancel(); highlightWatch = nil
        awaitingMicrophone = false
        retranscribingRunID = nil
        if automaticPreparationEnabled && !permissions.needsSetup { prepareInBackground() }
    }
    private func key(_ options: StudioSettings) -> String { options.engine + "|" + options.modelFolder }

    private func retainUnfinishedPreparation() {
        retiredPreparations.removeAll { $0.result != nil }
        if let preparation, preparation.result == nil { retiredPreparations.append(preparation) }
    }

    func refreshModels() {
        modelLibrary.refresh(knownFolders: [settings.modelFolder] + debugging.workspace.models.map(\.folder),
                             catalog: debugging.availableModels)
        cleanupService.refreshAvailability()
    }

    func deleteTranscriptionModel(_ model: TranscriptionModel) async throws {
        guard !busyForUpdate else { throw StudioError.message("Finish the current task before deleting a model.") }
        guard modelLibrary.isManaged(model.folder) else { throw StudioError.message("Manage this external model folder in Finder.") }
        modelMaintenance = true
        defer { modelMaintenance = false; refreshModels() }
        for old in retiredPreparations { await old.cancelAndWait() }
        retiredPreparations.removeAll()
        let selected = URL(fileURLWithPath: settings.modelFolder).standardizedFileURL.resolvingSymlinksInPath() == model.folder.resolvingSymlinksInPath()
        if selected {
            await preparation?.cancelAndWait()
            preparation = nil; preparationID = UUID(); engine = nil; engineKey = ""
            modelLoaded = false; modelPreparing = false; modelPreparationError = nil
            // Persist the cleared selection before deleting files. A failed save
            // must not leave the next launch pointing at a deleted model.
            var updated = settings
            updated.modelFolder = ""
            try updated.save(project: project)
            settings = updated
        }
        try modelLibrary.delete(model)
        debugging.setModelEnabled(model.id, enabled: false)
    }

    func deleteFastModel() async throws {
        guard !busyForUpdate else { throw StudioError.message("Finish the current task before deleting a model.") }
        let folder = FastTranscriptionEngine.modelDirectory
        guard folder.resolvingSymlinksInPath() == folder.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(folder.lastPathComponent) else {
            throw StudioError.message("Manage this linked model folder in Finder.")
        }
        modelMaintenance = true
        defer { modelMaintenance = false; refreshModels() }
        for old in retiredPreparations { await old.cancelAndWait() }
        retiredPreparations.removeAll()
        if settings.engine == "fast" {
            await preparation?.cancelAndWait()
            preparation = nil; preparationID = UUID(); engine = nil; engineKey = ""
            modelLoaded = false; modelPreparing = false; modelPreparationError = nil
            var updated = settings; updated.engine = "whisperkit"
            try updated.save(project: project)
            settings = updated
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func deleteCleanupModel(_ model: QwenModel) async throws {
        guard !busyForUpdate else { throw StudioError.message("Finish the current task before deleting a model.") }
        modelMaintenance = true
        defer { modelMaintenance = false; refreshModels() }
        try await cleanupService.deleteQwen(model)
        if settings.cleanupEngine == model.engine {
            var updated = settings
            updated.cleanupEnabled = false
            updated.cleanupEngine = .automatic
            settings = updated
        }
        if model == .qwen06 { debugging.cleanupLab.compareQwen = false }
        else if model == .qwen17 { debugging.cleanupLab.compareQwen17 = false }
        debugging.cleanupLab.savePreferences()
    }
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
    public func loadDesignPreviewHistory(includeIssues: Bool = false) {
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
        if includeIssues {
            let issues: [(RecordingOutcome, String)] = [
                (.failed, ""),
                (.completed, "Remember to send the revised proposal before lunch."),
                (.interrupted, "We should move the meeting to Thursday afternoon."),
                (.cancelled, ""),
                (.completed, "")
            ]
            runs = issues.enumerated().map { index, example in
                RecordingRun(id: UUID(), date: calendar.date(bySettingHour: 11, minute: 59 - index,
                    second: 0, of: today)!, transcript: example.1, audioSeconds: 30, latency: 0,
                    averageDB: -21, peakDB: 0.023, input: "Design preview", savedURL: nil,
                    engine: "whisperkit", model: "Preview", prompt: "", outcome: example.0)
            } + runs
        }
        status = "Press your shortcut or click to record"
    }
}
#endif

/// Reads and writes the selected microphone's hardware volume; a nil UID is the system default.
public struct InputVolumeControl {
    public var read: @MainActor (String?) -> Double?
    public var write: @MainActor (Double, String?) -> Void

    public init(read: @escaping @MainActor (String?) -> Double?, write: @escaping @MainActor (Double, String?) -> Void) {
        self.read = read
        self.write = write
    }

    public static var unavailable: Self { InputVolumeControl(read: { _ in nil }, write: { _, _ in }) }
    /// Live hardware access for the app only; tests must never pass this.
    public static var system: Self {
        InputVolumeControl(read: { AudioInputVolume.volume(deviceUID: $0) },
                           write: { AudioInputVolume.setVolume($0, deviceUID: $1) })
    }
}
