import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import Testing
import NamiCore
import NamiAudio
@testable import NamiStudio

@MainActor private final class TestInputDevices {
    var available: [AudioInputDevice] = []
}

@MainActor private final class TestPermissionState {
    var microphone: AVAuthorizationStatus = .authorized
    var inputMonitoring = true
}

@MainActor private final class TestCapture: AudioCapturing {
    var inputDescription = "Synthetic test input"
    var starts = 0
    var stops = 0
    var startDelay: Duration = .zero
    var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        starts += 1
        try await Task.sleep(for: startDelay)
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        continuation = pair.continuation
        return pair.stream
    }
    func emit(seconds: Double) {
        continuation?.yield(AudioChunk(samples: Array(repeating: 0.1, count: Int(seconds * 16000)), timestamp: 0))
    }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}

@MainActor private final class TestEngine: TranscriptionEngine {
    let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: false)
    var prepares = 0
    var prepareDelay: Duration = .zero
    var releasePrepare = true
    var prepareFailure = false
    var ignorePrepareCancellation = false
    var prepared = false
    var finishDelay: Duration = .zero
    var waitingForFinish = false
    var releaseFinish = true
    var transcript = "The whole thought, from beginning to end."
    var fail = false
    var sampleCount = 0
    var receivedSamples: [Float] = []
    var receivedVocabularies: [String] = []
    func prepare() async throws {
        prepares += 1
        // The uncooperative fake must also ignore cancellation during its first
        // suspension, before the release gate (which CI can reach later).
        if ignorePrepareCancellation { try? await Task.sleep(for: prepareDelay) }
        else { try await Task.sleep(for: prepareDelay) }
        while !releasePrepare {
            if ignorePrepareCancellation {
                // Complete even after invalidation, like an uncooperative SDK load.
                await Task.yield()
            } else { try await Task.sleep(for: .milliseconds(5)) }
        }
        if prepareFailure { throw EngineError.modelUnavailable("Test preparation failure") }
        prepared = true
    }
    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        #expect(prepared)
        receivedVocabularies.append(vocabulary)
        sampleCount = 0; receivedSamples = []
    }
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws {
        #expect(chunk.timestamp == Double(sampleCount) / AudioChunk.sampleRate)
        sampleCount += chunk.samples.count
        receivedSamples += chunk.samples
    }
    func finish(sessionID: UUID) async throws -> String {
        waitingForFinish = true
        while !releaseFinish { try await Task.sleep(for: .milliseconds(5)) }
        // Intentionally uncooperative to ensure the controller rejects a late result.
        try? await Task.sleep(for: finishDelay)
        if fail { throw EngineError.transcriptionFailed("Test failure") }
        return transcript
    }
    func cancel(sessionID: UUID) async {}
}

@Suite(.serialized) @MainActor struct RecordingIndicatorTests {
    @Test func remainsVisibleUntilFinalTranscriptAndClipboardHandoff() async throws {
        _ = NSApplication.shared
        let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
        let engine = TestEngine(), capture = TestCapture()
        engine.releaseFinish = false
        defer { engine.releaseFinish = true }
        var indicator: RecordingIndicatorController?
        var copied = false
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
            clipboardWriter: { _ in
                #expect(indicator?.panel?.isVisible == true)
                copied = true
                return true
            })
        indicator = RecordingIndicatorController(session: session)
        defer { indicator?.panel?.orderOut(nil); indicator = nil }
        #expect(indicator?.panel == nil)
        session.toggleRecording()
        try await waitUntil { session.phase == .recording && indicator?.panel?.isVisible == true }
        let panel = try #require(indicator?.panel)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isKeyWindow && !panel.isMainWindow)
        #expect(!panel.hidesOnDeactivate && !panel.canHide)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        capture.emit(seconds: 1)
        try await waitUntil { session.capturedSeconds == 1 }
        session.toggleRecording()
        try await waitUntil { engine.waitingForFinish }
        #expect(session.phase == .processing)
        #expect(panel.isVisible)
        #expect(!copied && session.runs.isEmpty)
        engine.releaseFinish = true
        try await waitUntil { session.phase == .idle && !panel.isVisible }
        #expect(copied)
        #expect(session.selectedRun?.transcript == engine.transcript)

        // A second run reuses the panel and cancellation hides it after cleanup.
        session.toggleRecording()
        try await waitUntil { session.phase == .recording && panel.isVisible }
        #expect(indicator?.panel === panel)
        session.cancel()
        try await waitUntil { session.phase == .idle && !panel.isVisible }
    }

    @Test func microphoneStartupCancellationAndFailureDismissIndicator() async throws {
        _ = NSApplication.shared
        let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
        let engine = TestEngine(), capture = TestCapture()
        capture.startDelay = .seconds(1)
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                    clipboardWriter: { _ in true })
        let indicator = RecordingIndicatorController(session: session)
        defer { indicator.panel?.orderOut(nil) }
        session.startRecording()
        try await waitUntil { indicator.panel?.isVisible == true }
        #expect(session.phase == .preparing)
        session.cancel()
        try await waitUntil { session.phase == .idle && indicator.panel?.isVisible == false }
        #expect(capture.continuation == nil)

        capture.startDelay = .zero
        engine.fail = true
        session.startRecording()
        try await waitUntil { session.phase == .recording && indicator.panel?.isVisible == true }
        capture.emit(seconds: 1)
        try await waitUntil { session.capturedSeconds == 1 }
        session.stopRecording()
        try await waitUntil { session.phase == .failed && indicator.panel?.isVisible == false }
    }

    @Test func centersAboveDockOnDisplaysWithNegativeCoordinates() {
        let visible = NSRect(x: -1920, y: -500, width: 1920, height: 1000)
        let origin = RecordingIndicatorController.origin(in: visible)
        #expect(origin.x + RecordingIndicatorView.windowSize.width / 2 == visible.midX)
        #expect(origin.y == visible.minY + 16)
    }
}

private func projectDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nami-studio-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@Test @MainActor func stopPublishesTranscriptAndReusesPreparedModel() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    for _ in 0..<2 {
        session.startRecording()
        try await waitUntil { session.phase == .recording }
        capture.emit(seconds: 1)
        try await waitUntil { session.capturedSeconds == 1 }
        session.stopRecording()
        try await waitUntil { !session.phase.busy }
    }
    #expect(engine.prepares == 1)
    #expect(session.runs.count == 2)
    #expect(session.runs.first?.audioSeconds == 1)
    #expect(session.runs.first?.transcript == "The whole thought, from beginning to end.")
    #expect(try RecordingHistoryStore(directory: session.historyDirectory).load().runs.count == 2)
}

@Test @MainActor func cancelledProcessingCannotPublishLateResult() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.finishDelay = .seconds(1)
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { Issue.record("This run must not paste"); return .sent } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { copies.append($0); return true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await Task.sleep(for: .milliseconds(20))
    session.cancel()
    session.startRecording() // Must not start a new session while cancellation unwinds.
    try await waitUntil { !session.phase.busy }
    #expect(session.runs.count == 1)
    #expect(session.runs.first?.outcome == .cancelled)
    #expect(session.runs.first?.transcript.isEmpty == true)
    #expect(copies.isEmpty)
    #expect(capture.starts == 1)
    #expect(session.phase == .idle)
}

@Test @MainActor func cancellingPreparationDoesNotOpenMicrophone() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.prepareDelay = .seconds(1)
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.startRecording()
    session.cancel()
    try await waitUntil { !session.phase.busy }
    #expect(capture.starts == 0)
    #expect(session.runs.isEmpty)
}

@Test @MainActor func savedAudioSurvivesInferenceFailure() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.fail = true
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.saveAudio = true
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 5)
    try await waitUntil { session.capturedSeconds == 5 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(engine.sampleCount == 80_000)
    #expect(session.phase == .failed)
    #expect(session.runs.count == 1)
    #expect(session.runs.first?.outcome == .failed)
    let folder = project.appendingPathComponent("evaluation/audio")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(try AudioFile.read(#require(files.first)).count == 80_000)
}

@Test @MainActor func silentMicrophoneReportsMissingAudio() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.saveAudio = true
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(session.phase == .failed)
    #expect(session.errorMessage == AudioInputError.noAudioReceived.localizedDescription)
    #expect(session.runs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("evaluation/audio").path))
}

@Test func settingsPreserveOtherProjectKeysAndResolveHome() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let config = project.appendingPathComponent("nami.json")
    try Data(#"{"engine":"fake","language":"en","modelFolder":"~/My model","otherSetting":42}"#.utf8).write(to: config)
    var settings = try StudioSettings.load(project: project)
    #expect(settings.modelFolder == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("My model").path)
    #expect(settings.vocabulary.isEmpty)
    settings.vocabulary = "Nami"
    try settings.save(project: project)
    #expect(try StudioSettings.load(project: project).vocabulary == "Nami")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
    #expect(json?["otherSetting"] as? Int == 42)
}

@Test @MainActor func firstLaunchCreatesSettingsDirectoryAndPersistsChanges() throws {
    let root = try projectDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Application Support/Nami", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: project.path))
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { [] }, clipboardWriter: { _ in true })
    #expect(session.errorMessage == nil)
    session.settings.language = "fr"
    #expect(try StudioSettings.load(project: project).language == "fr")
    #expect(session.errorMessage == nil)
}

@Test @MainActor func settingsSaveImmediatelyAndRestoreIntoNewSession() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let microphones = [AudioInputDevice(id: "usb-mic-uid", name: "USB microphone")]
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { microphones }, clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.settings.modelFolder = project.appendingPathComponent("model").path
    session.settings.language = "fr"
    session.settings.saveAudio = true
    session.settings.audioDirectory = project.appendingPathComponent("recordings").path
    session.settings.microphoneUID = "usb-mic-uid"
    session.settings.vocabulary = "Nami, Oleg\nPostHog, Élodie, Київ"

    // No SwiftUI view or explicit save call: even quitting immediately must work.
    let reopened = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { microphones }, clipboardWriter: { _ in true })
    #expect(reopened.settings == session.settings)
    #expect(reopened.inputName == "USB microphone")
    #expect(!reopened.selectedMicrophoneUnavailable)
    #expect(reopened.errorMessage == nil)

    reopened.settings.microphoneUID = nil
    reopened.settings.vocabulary = ""
    let followingDefault = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { microphones }, clipboardWriter: { _ in true })
    #expect(followingDefault.settings.microphoneUID == nil)
    #expect(followingDefault.settings.language == "fr")
    #expect(followingDefault.settings.vocabulary.isEmpty)
}

@Test @MainActor func vocabularyAppliesPerRecordingAndImportWithoutReloadingModel() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in Issue.record("Test must not copy"); return false })
    session.settings.engine = "fake"
    session.settings.copyWhenFinished = false
    session.settings.vocabulary = "Nami, Oleg"
    session.prepareForRecording()
    try await waitUntil { session.modelLoaded }

    session.startRecording()
    try await waitUntil { session.phase == .recording }
    // Changes made after capture starts belong to the following transcription.
    session.settings.vocabulary = "PostHog, TypeScript"
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(session.phase == .idle)
    #expect(engine.receivedVocabularies == ["Nami, Oleg"])

    let audio = project.appendingPathComponent("sample.wav")
    try AudioFile.write(Array(repeating: 0.1, count: 1600), to: audio)
    session.transcribeFile(audio)
    try await waitUntil { !session.phase.busy }
    #expect(session.phase == .idle)
    #expect(engine.receivedVocabularies == ["Nami, Oleg", "PostHog, TypeScript"])

    session.settings.vocabulary = ""
    session.transcribeFile(audio)
    try await waitUntil { !session.phase.busy }
    #expect(session.phase == .idle)
    #expect(engine.receivedVocabularies == ["Nami, Oleg", "PostHog, TypeScript", ""])
    #expect(engine.prepares == 1)
}

@Test func legacySettingsWithoutMicrophoneStillRestore() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    try Data(#"{"studio":{"engine":"fake","modelFolder":"model","language":"fr","duration":40,"timed":false,"saveAudio":true,"audioDirectory":"recordings"}}"#.utf8)
        .write(to: project.appendingPathComponent("nami.json"))
    let restored = try StudioSettings.load(project: project)
    #expect(restored.microphoneUID == nil)
    #expect(restored.vocabulary.isEmpty)
    #expect(restored.engine == "fake")
    #expect(restored.language == "fr")
    #expect(restored.saveAudio)
    #expect(restored.audioDirectory == project.appendingPathComponent("recordings").path)
}

@Test @MainActor func disconnectedMicrophoneIsRememberedAndUsedAfterReconnect() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let devices = TestInputDevices()
    var requestedUID: String?
    let first = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { devices.available }, clipboardWriter: { _ in true })
    first.settings.microphoneUID = "remembered-mic"
    let reopened = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine },
        captureBuilder: { requestedUID = $0; return capture },
        inputDevicesProvider: { devices.available }, clipboardWriter: { _ in true })
    #expect(reopened.selectedMicrophoneUnavailable)
    #expect(reopened.settings.microphoneUID == "remembered-mic")
    reopened.refreshInput()
    #expect(try StudioSettings.load(project: project).microphoneUID == "remembered-mic")

    devices.available = [AudioInputDevice(id: "remembered-mic", name: "Reconnected microphone")]
    reopened.refreshInput()
    #expect(!reopened.selectedMicrophoneUnavailable)
    #expect(reopened.inputName == "Reconnected microphone")
    reopened.startRecording()
    try await waitUntil { reopened.phase == .recording }
    #expect(requestedUID == "remembered-mic")
    reopened.cancel()
    try await waitUntil { !reopened.phase.busy }
}

@Test @MainActor func failedSettingsSaveReportsErrorWithoutOverwritingConfig() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    let config = project.appendingPathComponent("nami.json")
    let invalid = Data("invalid JSON".utf8)
    try invalid.write(to: config)
    session.settings.language = "de"
    #expect(session.errorMessage != nil)
    #expect(try Data(contentsOf: config) == invalid)
}

@Test @MainActor func playbackWaveKeepsDurationWithoutImplicitFiles() throws {
    let samples = Array(repeating: Float(0.25), count: 16_000)
    let data = StudioSession.wavData(samples)
    #expect(data.count == 44 + 32_000)
    #expect(String(data: data.prefix(4), encoding: .utf8) == "RIFF")
    #expect(String(data: data[8..<12], encoding: .utf8) == "WAVE")
}

@Test @MainActor func recordingShortcutCopiesFinalTextAndIgnoresBusyPhases() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.finishDelay = .milliseconds(50)
    var clipboard = "Previous clipboard"
    var writes = 0
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { clipboard = $0; writes += 1; return true })
    session.toggleRecording()
    session.toggleRecording() // Preparation must not start another run.
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    #expect(clipboard == "Previous clipboard")
    session.toggleRecording()
    session.toggleRecording() // Processing must not restart or cancel the run.
    try await waitUntil { !session.phase.busy }
    #expect(capture.starts == 1)
    #expect(writes == 1)
    #expect(clipboard == engine.transcript)
    #expect(session.status.contains("copied"))
}

@Test @MainActor func recordingContinuesUntilStoppedPastOneMinute() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { copies.append($0); return true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 90)
    try await waitUntil { session.capturedSeconds == 90 }
    #expect(session.phase == .recording)
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(engine.sampleCount == 90 * 16000)
    #expect(copies == [engine.transcript])
}

@Test @MainActor func emptyOrFailedTranscriptionsPreserveClipboard() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    for fail in [false, true] {
        let engine = TestEngine(), capture = TestCapture()
        engine.transcript = " \n\t"; engine.fail = fail
        var writes = 0
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { Issue.record("This run must not paste"); return .sent } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                    clipboardWriter: { _ in writes += 1; return true })
        session.startRecording()
        try await waitUntil { session.phase == .recording }
        capture.emit(seconds: 1)
        try await waitUntil { session.capturedSeconds == 1 }
        session.stopRecording()
        try await waitUntil { !session.phase.busy }
        #expect(writes == 0)
        #expect(!session.copyTranscript())
        #expect(writes == 0)
    }
}

@Test @MainActor func clipboardFailureKeepsTranscriptAvailableForRetry() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var canWrite = false
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { Issue.record("This run must not paste"); return .sent } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { _ in canWrite })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(session.selectedRun?.transcript == engine.transcript)
    #expect(session.errorMessage?.contains("copying failed") == true)
    #expect(!session.copyTranscript())
    canWrite = true
    #expect(session.copyTranscript())
}

@Test @MainActor func modifierEventsStartStopAndCopyThroughSession() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { copies.append($0); return true })
    let monitor = session.modifierShortcut
    func tap(at time: Double) {
        monitor.handle(type: .flagsChanged, flags: .maskAlternate, time: time, session: session)
        monitor.handle(type: .flagsChanged, flags: [.maskAlternate, .maskCommand], time: time + 0.01, session: session)
        monitor.handle(type: .flagsChanged, flags: .maskCommand, time: time + 0.02, session: session)
        monitor.handle(type: .flagsChanged, flags: [], time: time + 0.03, session: session)
    }
    tap(at: 0)
    #expect(session.phase == .idle)
    tap(at: 0.2)
    #expect(session.phase == .preparing)
    tap(at: 0.3) // Extra taps cannot cancel preparation or start a second capture.
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    tap(at: 1)
    #expect(session.phase == .processing)
    try await waitUntil { !session.phase.busy }
    #expect(capture.starts == 1)
    #expect(copies == [engine.transcript])
}

@Test @MainActor func disablingAutomaticCopyPreservesClipboardAndAllowsManualCopy() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { Issue.record("This run must not paste"); return .sent } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { copies.append($0); return true })
    session.settings.copyWhenFinished = false
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(session.runs.first?.transcript == engine.transcript)
    #expect(copies.isEmpty)
    #expect(try StudioSettings.load(project: project).copyWhenFinished == false)
    #expect(session.copyTranscript())
    #expect(copies == [engine.transcript])
}

@Test func existingSettingsKeepAutomaticCopyEnabled() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    try Data(#"{"studio":{"engine":"fake","modelFolder":"","language":"en","duration":60,"timed":true,"saveAudio":false,"audioDirectory":"audio"}}"#.utf8)
        .write(to: project.appendingPathComponent("nami.json"))
    #expect(try StudioSettings.load(project: project).copyWhenFinished)
    #expect(try StudioSettings.load(project: project).pasteWhenFinished)
}

@Test @MainActor func stopsCopyThenPasteExactlyOnce() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var events: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: {
        events.append("capture focus")
        return { events.append("paste"); return .sent }
    }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: {
        #expect($0 == engine.transcript)
        events.append("copy")
        return true
    })
    session.startRecording()
    #expect(events == ["capture focus"])
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    session.stopRecording() // Duplicate stops must not schedule a second paste.
    try await waitUntil { !session.phase.busy }
    #expect(events == ["capture focus", "copy", "paste"])
    #expect(session.status == TranscriptPasteResult.sent.status)
    #expect(session.copyTranscript())
    #expect(events == ["capture focus", "copy", "paste", "copy"])
}

@Test @MainActor func disablingPasteKeepsAutomaticCopyAndPersists() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var copies = 0
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: {
        Issue.record("Disabled paste must not inspect focus")
        return { .sent }
    }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in copies += 1; return true })
    session.settings.pasteWhenFinished = false
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(copies == 1)
    #expect(!((try StudioSettings.load(project: project)).pasteWhenFinished))
}

@Test @MainActor func importsCopyWithoutInspectingFocusOrPasting() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let url = project.appendingPathComponent("import.wav")
    try AudioFile.write(Array(repeating: 0.1, count: 16_000), to: url)
    let engine = TestEngine()
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: {
        Issue.record("File imports must not prepare a paste")
        return { .sent }
    }, engineBuilder: { _ in engine }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { copies.append($0); return true })
    session.transcribeFile(url)
    try await waitUntil { !session.phase.busy }
    #expect(copies == [engine.transcript])
}

@Test @MainActor func pasteFallbackKeepsTranscriptAndExplainsRecovery() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    for result: TranscriptPasteResult in [.accessibilityRequired, .targetUnavailable, .targetChanged, .modifiersPressed, .failed] {
        let engine = TestEngine(), capture = TestCapture()
        var clipboard = ""
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: allowedPermissions(), pastePreparer: { { result } },
            engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { clipboard = $0; return true })
        session.startRecording()
        try await waitUntil { session.phase == .recording }
        capture.emit(seconds: 1)
        try await waitUntil { session.capturedSeconds == 1 }
        session.stopRecording()
        try await waitUntil { !session.phase.busy }
        #expect(clipboard == engine.transcript)
        #expect(session.selectedRun?.transcript == engine.transcript)
        #expect(session.status == result.status)
        #expect(session.phase == .idle)
    }
}


@MainActor private func allowedPermissions() -> StudioPermissions {
    StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
                      requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false })
}

@Test @MainActor func missingPermissionsBlockRecordingShortcutsAndImportBeforeModelPreparation() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    for microphone: AVAuthorizationStatus in [.notDetermined, .denied, .restricted, .authorized] {
        for inputMonitoring in [false, true] where microphone != .authorized || !inputMonitoring {
            let engine = TestEngine(), capture = TestCapture()
            let permissions = StudioPermissions(microphoneStatus: { microphone }, inputMonitoringStatus: { inputMonitoring },
                requestMicrophone: { Issue.record("Recording must not request permission implicitly"); return false },
                requestInputMonitoring: { Issue.record("Recording must not request permission implicitly"); return false },
                openSettings: { _ in Issue.record("Recording must not open settings implicitly"); return false })
            let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: permissions,
                pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
            session.startRecording()
            session.toggleRecording()
            session.transcribeFile(project.appendingPathComponent("does-not-exist.wav"))
            await Task.yield()
            #expect(session.phase == .idle)
            #expect(permissions.needsSetup)
            #expect(engine.prepares == 0 && capture.starts == 0)
            #expect(session.runs.isEmpty && session.errorMessage == nil)
        }
    }
}

@Test @MainActor func permissionRecoveryAllowsExplicitRetryAndRevocationCancelsCapture() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let state = TestPermissionState()
    state.microphone = .denied
    let permissions = StudioPermissions(microphoneStatus: { state.microphone }, inputMonitoringStatus: { true },
        requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false })
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: permissions,
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.startRecording()
    #expect(engine.prepares == 0)
    state.microphone = .authorized
    session.refreshPermissions()
    #expect(!permissions.needsSetup)
    #expect(capture.starts == 0) // Permission approval alone must never start recording.
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    state.microphone = .denied
    session.refreshPermissions()
    try await waitUntil { !session.phase.busy }
    #expect(permissions.needsSetup)
    #expect(capture.stops > 0)
    #expect(session.runs.isEmpty)
}

@Test @MainActor func permissionRevokedDuringBackgroundWarmupNeverOpensMicrophone() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.prepareDelay = .milliseconds(50)
    let state = TestPermissionState()
    let permissions = StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { state.inputMonitoring },
        requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false })
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"), permissions: permissions,
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    try await waitUntil { engine.prepares == 1 }
    state.inputMonitoring = false
    session.refreshPermissions()
    session.startRecording()
    #expect(capture.starts == 0)
    #expect(permissions.needsSetup)
}

@Test @MainActor func unlimitedHistorySurvivesReopeningFromAnotherProject() async throws {
    let root = try projectDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("Application Support/Nami/History")
    let project = root.appendingPathComponent("checkout")
    let engine = TestEngine(), capture = TestCapture()
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.copyWhenFinished = false
    #expect(!session.settings.saveAudio)
    for index in 0..<15 {
        engine.transcript = "Thought \(index) — café 日本語"
        session.startRecording()
        try await waitUntil { session.phase == .recording }
        capture.emit(seconds: 0.1)
        try await waitUntil { session.capturedSeconds > 0 }
        session.stopRecording()
        try await waitUntil { !session.phase.busy }
    }
    #expect(session.errorMessage == nil)
    #expect(session.runs.count == 15)
    let ids = session.runs.map(\.id)
    // Replacing the checkout/build cannot remove the independent history.
    try FileManager.default.removeItem(at: project)
    let reopened = StudioSession(project: root.appendingPathComponent("new-checkout"), historyDirectory: history,
                                 permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, inputDevicesProvider: { [] }, clipboardWriter: { _ in true })
    #expect(reopened.errorMessage == nil)
    #expect(reopened.runs.map(\.id) == ids)
    #expect(reopened.selectedRunID == ids.first)
    #expect(reopened.runs.map(\.transcript) == session.runs.map(\.transcript))
    for run in reopened.runs {
        #expect(run.samples.isEmpty)
        #expect(run.outcome == .completed)
        #expect(run.input == capture.inputDescription)
        let audio = try #require(run.savedURL)
        #expect(try AudioFile.read(audio).count == 1600)
        #expect(try AVAudioPlayer(contentsOf: audio).duration > 0)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: history.path).count == 30)
}

@Test @MainActor func importedAudioSurvivesDeletingOriginalAndSilentStatisticsRoundTrip() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let source = project.appendingPathComponent("original.wav")
    try AudioFile.write(Array(repeating: 0, count: 1600), to: source)
    let engine = TestEngine()
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
                                pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    session.transcribeFile(source)
    try await waitUntil { !session.phase.busy }
    #expect(session.errorMessage == nil)
    let run = try #require(session.selectedRun)
    #expect(run.savedURL != source)
    try FileManager.default.removeItem(at: source)
    let reopened = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    let restored = try #require(reopened.selectedRun)
    #expect(restored.id == run.id)
    #expect(restored.transcript == engine.transcript)
    #expect(restored.averageDB == -.infinity && restored.peakDB == -.infinity)
    #expect(try AudioFile.read(#require(restored.savedURL)).count == 1600)
}

@Test @MainActor func captureIsDurableBeforeInferenceFinishesAndCancellationKeepsIt() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let engine = TestEngine(), capture = TestCapture()
    engine.releaseFinish = false
    defer { engine.releaseFinish = true }
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in Issue.record("Unfinished transcription must not copy"); return true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await waitUntil { engine.waitingForFinish }
    let recovered = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    let pending = try #require(recovered.selectedRun)
    #expect(pending.outcome == .interrupted)
    #expect(pending.transcript.isEmpty)
    #expect(try AudioFile.read(#require(pending.savedURL)).count == 16000)
    session.cancel()
    try await waitUntil { !session.phase.busy }
    let stored = try RecordingHistoryStore(directory: history).load().runs
    #expect(stored.count == 1)
    #expect(stored.first?.id == pending.id)
    #expect(stored.first?.outcome == .cancelled)
}

@Test @MainActor func cancellingActiveCaptureKeepsReceivedAudio() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let engine = TestEngine(), capture = TestCapture()
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.2)
    try await waitUntil { session.capturedSeconds == 0.2 }
    session.cancel()
    try await waitUntil { !session.phase.busy }
    let stored = try RecordingHistoryStore(directory: history).load().runs
    #expect(stored.count == 1)
    #expect(stored.first?.outcome == .cancelled)
    #expect(try AudioFile.read(#require(stored.first?.savedURL)).count == 3200)
}

@Test @MainActor func damagedHistoryDoesNotHideHealthyRecordsOrEraseTextWithMissingAudio() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let source = project.appendingPathComponent("source.wav")
    try AudioFile.write(Array(repeating: 0.1, count: 1600), to: source)
    let engine = TestEngine()
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
                                pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    session.transcribeFile(source)
    try await waitUntil { !session.phase.busy }
    let run = try #require(session.selectedRun)
    let broken = history.appendingPathComponent(UUID().uuidString + ".json")
    let invalid = Data("invalid JSON".utf8)
    try invalid.write(to: broken)
    try FileManager.default.removeItem(at: #require(run.savedURL))
    let reopened = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    #expect(reopened.runs.count == 1)
    #expect(reopened.selectedRun?.transcript == engine.transcript)
    #expect(reopened.errorMessage?.contains("Could not load") == true)
    #expect(reopened.errorMessage?.contains("Audio is missing") == true)
    #expect(try Data(contentsOf: broken) == invalid)
    // A new recording must not overwrite the damaged file or the older metadata.
    session.transcribeFile(source)
    try await waitUntil { !session.phase.busy }
    #expect(try RecordingHistoryStore(directory: history).load().runs.count == 2)
    #expect(try Data(contentsOf: broken) == invalid)
}

@Test @MainActor func unwritableHistoryReportsFailureAndRetainsTranscriptAndPlaybackInMemory() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("not-a-directory")
    try Data("block directory creation".utf8).write(to: history)
    let engine = TestEngine(), capture = TestCapture()
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
        pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { copies.append($0); return true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.1)
    try await waitUntil { session.capturedSeconds > 0 }
    session.stopRecording()
    try await waitUntil { !session.phase.busy }
    #expect(session.phase == .idle)
    #expect(session.errorMessage?.contains("Could not save this recording") == true)
    #expect(session.selectedRun?.transcript == engine.transcript)
    #expect(session.selectedRun?.samples.count == 1600)
    #expect(copies == [engine.transcript])
}

// Deterministic capture-start measurement; the synthetic microphone opens immediately.
@Test @MainActor func captureStartLatencyDiagnostic() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    for _ in 0..<3 {
        let engine = TestEngine(), capture = TestCapture()
        engine.prepareDelay = .seconds(1)
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
            permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
            clipboardWriter: { _ in true })
        let start = ContinuousClock.now
        session.startRecording()
        try await waitUntil { session.phase == .recording }
        print("Capture-start diagnostic (1s model preparation): \(start.duration(to: .now))")
        session.cancel()
        try await waitUntil { !session.phase.busy }
    }
}

@Test @MainActor func startupWarmsOnceWithoutOpeningMicrophoneAndRetainsModel() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.releasePrepare = false
    defer { engine.releasePrepare = true }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    session.prepareForRecording()
    session.refreshPermissions()
    try await waitUntil { engine.prepares == 1 }
    #expect(session.phase == .idle && session.modelPreparing && !session.modelLoaded)
    #expect(capture.starts == 0)
    engine.releasePrepare = true
    try await waitUntil { session.modelLoaded }
    session.settings.language = "fr"
    session.settings.vocabulary = "Nami"
    session.refreshPermissions()
    #expect(!session.modelPreparing && engine.prepares == 1)
    #expect(capture.starts == 0)
    #expect(session.modelPreparationSeconds != nil)
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    session.cancel()
    try await waitUntil { !session.phase.busy }
    #expect(session.modelLoaded && engine.prepares == 1)
}

@Test @MainActor func coldModelCannotDelayCaptureOrLoseFirstSamples() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.releasePrepare = false
    defer { engine.releasePrepare = true }
    var copies: [String] = []
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { copies.append($0); return true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    #expect(!engine.prepared && engine.prepares == 1)
    let first = Array(repeating: Float(0.2), count: 1600)
    let last = Array(repeating: Float(-0.3), count: 3200)
    capture.continuation?.yield(AudioChunk(samples: first, timestamp: 0))
    try await waitUntil { session.capturedSeconds == 0.1 }
    capture.continuation?.yield(AudioChunk(samples: last, timestamp: 0.1))
    session.toggleRecording() // Stopping must work before model preparation finishes.
    try await waitUntil { capture.continuation == nil && session.status.contains("Waiting for the model") }
    #expect(session.phase == .processing && copies.isEmpty)
    let saved = try RecordingHistoryStore(directory: session.historyDirectory).load().runs
    #expect(saved.count == 1)
    #expect(try AudioFile.read(#require(saved.first?.savedURL)).count == 4800)
    #expect(session.firstAudioSeconds != nil && session.captureStartSeconds != nil)
    engine.releasePrepare = true
    try await waitUntil { !session.phase.busy }
    #expect(engine.prepares == 1)
    #expect(engine.receivedSamples == first + last)
    #expect(session.runs.first?.audioSeconds == 0.3)
    #expect(copies == [engine.transcript])
}

@Test @MainActor func cancellingModelWaitKeepsAudioAndNextCaptureCanStartDuringSameLoad() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.releasePrepare = false
    defer { engine.releasePrepare = true }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.1)
    try await waitUntil { session.capturedSeconds > 0 }
    session.stopRecording()
    try await waitUntil { session.status.contains("Waiting for the model") }
    session.cancel()
    try await waitUntil { session.phase == .idle }
    #expect(!engine.prepared && session.modelPreparing)
    #expect(session.runs.first?.outcome == .cancelled)
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.2)
    try await waitUntil { session.capturedSeconds == 0.2 }
    engine.releasePrepare = true
    try await waitUntil { session.modelLoaded }
    session.stopRecording()
    try await waitUntil { session.phase == .idle }
    #expect(engine.prepares == 1 && capture.starts == 2)
    #expect(session.runs.count == 2 && session.runs.first?.outcome == .completed)
    #expect(engine.sampleCount == 3200)
}

@Test @MainActor func failedWarmupPreservesCapturedAudioAndExplicitRetryRecovers() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.releasePrepare = false; engine.prepareFailure = true
    defer { engine.releasePrepare = true }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.1)
    try await waitUntil { session.capturedSeconds > 0 }
    session.stopRecording()
    engine.releasePrepare = true
    try await waitUntil { session.phase == .failed }
    #expect(session.runs.first?.outcome == .failed)
    #expect(try AudioFile.read(#require(session.runs.first?.savedURL)).count == 1600)
    #expect(session.modelPreparationError != nil && !session.modelLoaded)
    session.refreshPermissions(); session.prepareForRecording()
    #expect(engine.prepares == 1) // Background refresh must not loop on failures.
    engine.prepareFailure = false
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 0.1)
    try await waitUntil { session.capturedSeconds > 0 }
    session.stopRecording()
    try await waitUntil { session.phase == .idle }
    #expect(engine.prepares == 2 && session.modelLoaded)
    #expect(session.modelPreparationError == nil)
}

@Test @MainActor func changingModelWarmsReplacementAndIgnoresLateOldCompletion() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let old = TestEngine(), next = TestEngine(), capture = TestCapture()
    old.releasePrepare = false; old.ignorePrepareCancellation = true
    next.releasePrepare = false
    defer { old.releasePrepare = true; next.releasePrepare = true }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { $0.modelFolder == "next" ? next : old },
        captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    try await waitUntil { old.prepares == 1 }
    session.settings.modelFolder = "next"
    try await waitUntil { next.prepares == 1 }
    old.releasePrepare = true
    try await waitUntil { old.prepared }
    #expect(!session.modelLoaded && session.modelPreparing && session.modelPreparationError == nil)
    next.releasePrepare = true
    try await waitUntil { session.modelLoaded }
    #expect(capture.starts == 0)
    #expect(next.prepares == 1 && old.prepares == 1)
}

@Test @MainActor func startupWaitsForPermissionsThenWarmsAutomatically() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(), state = TestPermissionState()
    state.microphone = .denied
    let permissions = StudioPermissions(microphoneStatus: { state.microphone }, inputMonitoringStatus: { true },
        requestMicrophone: { Issue.record("Warmup must not request microphone access"); return false },
        requestInputMonitoring: { false }, openSettings: { _ in false })
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: permissions, pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in true })
    session.settings.engine = "fake"
    session.prepareForRecording()
    await Task.yield()
    #expect(engine.prepares == 0 && capture.starts == 0)
    state.microphone = .authorized
    session.refreshPermissions()
    try await waitUntil { session.modelLoaded }
    #expect(engine.prepares == 1 && capture.starts == 0 && session.phase == .idle)
}

@Test @MainActor func slowPreparationDoesNotOverflowBoundedAudioStream() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    engine.releasePrepare = false
    defer { engine.releasePrepare = true }
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    // Send more chunks than the capture stream can hold. It must be drained
    // throughout preparation, not only after the model becomes available.
    for batch in 0..<25 {
        for _ in 0..<8 { capture.emit(seconds: 0.1) }
        try await waitUntil { session.capturedSeconds == Double((batch + 1) * 12800) / 16000 }
    }
    #expect(!engine.prepared && session.capturedSeconds == 20)
    session.stopRecording()
    engine.releasePrepare = true
    try await waitUntil { session.phase == .idle }
    #expect(engine.sampleCount == 320000)
    #expect(session.runs.first?.audioSeconds == 20)
}

@Test @MainActor func deletingARunRemovesItsTranscriptAndAudio() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let source = project.appendingPathComponent("original.wav")
    try AudioFile.write(Array(repeating: 0, count: 1600), to: source)
    let engine = TestEngine()
    let session = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(),
                                pastePreparer: { { .targetUnavailable } }, engineBuilder: { _ in engine }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    session.transcribeFile(source)
    try await waitUntil { !session.phase.busy }
    session.transcribeFile(source)
    try await waitUntil { !session.phase.busy && session.runs.count == 2 }
    let deleted = try #require(session.selectedRun)
    let kept = session.runs[1]
    let audio = try #require(deleted.savedURL)
    session.deleteRun(deleted.id)
    #expect(session.errorMessage == nil)
    #expect(session.runs.map(\.id) == [kept.id])
    #expect(session.selectedRunID == kept.id)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(!FileManager.default.fileExists(atPath: history.appendingPathComponent(deleted.id.uuidString + ".json").path))
    let reopened = StudioSession(project: project, historyDirectory: history, permissions: allowedPermissions(), pastePreparer: { { .targetUnavailable } }, captureBuilder: { _ in TestCapture() }, clipboardWriter: { _ in true })
    #expect(reopened.runs.map(\.id) == [kept.id])
    #expect(reopened.errorMessage == nil)
}
