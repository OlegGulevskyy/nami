import Foundation
import AppKit
import CoreGraphics
import Testing
import NamiCore
import NamiAudio
@testable import NamiStudio

@MainActor private final class TestInputDevices {
    var available: [AudioInputDevice] = []
}

@MainActor private final class TestCapture: AudioCapturing {
    var inputDescription = "Synthetic test input"
    var starts = 0
    var stops = 0
    var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        starts += 1
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
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
    var finishDelay: Duration = .zero
    var waitingForFinish = false
    var releaseFinish = true
    var transcript = "The whole thought, from beginning to end."
    var fail = false
    var sampleCount = 0
    func prepare() async throws { prepares += 1; try await Task.sleep(for: prepareDelay) }
    func start(sessionID: UUID, language: String?, onPartial: (@Sendable (String) -> Void)?) async throws { sampleCount = 0 }
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws { sampleCount += chunk.samples.count }
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
        let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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

    @Test func preparationCancellationAndFailureDismissIndicator() async throws {
        _ = NSApplication.shared
        let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
        let engine = TestEngine(), capture = TestCapture()
        engine.prepareDelay = .seconds(1)
        let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                    clipboardWriter: { _ in true })
        let indicator = RecordingIndicatorController(session: session)
        defer { indicator.panel?.orderOut(nil) }
        session.startRecording()
        try await waitUntil { indicator.panel?.isVisible == true }
        #expect(session.phase == .preparing)
        session.cancel()
        try await waitUntil { session.phase == .idle && indicator.panel?.isVisible == false }
        #expect(capture.starts == 0)

        engine.prepareDelay = .zero
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
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
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
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
}

@Test @MainActor func cancelledProcessingCannotPublishLateResult() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.finishDelay = .seconds(1)
    var copies: [String] = []
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { copies.append($0); return true })
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 1)
    try await waitUntil { session.capturedSeconds == 1 }
    session.stopRecording()
    try await Task.sleep(for: .milliseconds(20))
    session.cancel()
    session.startRecording() // Must not start a new session while cancellation unwinds.
    try await waitUntil { !session.phase.busy }
    #expect(session.runs.isEmpty)
    #expect(copies.isEmpty)
    #expect(capture.starts == 1)
    #expect(session.phase == .idle)
}

@Test @MainActor func cancellingPreparationDoesNotOpenMicrophone() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.prepareDelay = .seconds(1)
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.startRecording()
    session.cancel()
    try await waitUntil { !session.phase.busy }
    #expect(capture.starts == 0)
    #expect(session.runs.isEmpty)
}

@Test @MainActor func frameLimitStopsAndSavedAudioSurvivesInferenceFailure() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture(); engine.fail = true
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture }, clipboardWriter: { _ in true })
    session.settings.duration = 5
    session.settings.saveAudio = true
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 5.1)
    try await waitUntil { !session.phase.busy }
    #expect(engine.sampleCount == 80_000)
    #expect(session.phase == .failed)
    #expect(session.runs.isEmpty)
    let folder = project.appendingPathComponent("evaluation/audio")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(try AudioFile.read(#require(files.first)).count == 80_000)
}

@Test func settingsPreserveOtherProjectKeysAndResolveHome() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let config = project.appendingPathComponent("nami.json")
    try Data(#"{"engine":"fake","language":"en","modelFolder":"~/My model","otherSetting":42}"#.utf8).write(to: config)
    var settings = try StudioSettings.load(project: project)
    #expect(settings.modelFolder == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("My model").path)
    settings.duration = 25
    try settings.save(project: project)
    #expect(try StudioSettings.load(project: project).duration == 25)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
    #expect(json?["otherSetting"] as? Int == 42)
}

@Test @MainActor func settingsSaveImmediatelyAndRestoreIntoNewSession() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let microphones = [AudioInputDevice(id: "usb-mic-uid", name: "USB microphone")]
    let session = StudioSession(project: project, inputDevicesProvider: { microphones })
    session.settings.engine = "fake"
    session.settings.modelFolder = project.appendingPathComponent("model").path
    session.settings.language = "fr"
    session.settings.duration = 35
    session.settings.timed = false
    session.settings.saveAudio = true
    session.settings.audioDirectory = project.appendingPathComponent("recordings").path
    session.settings.microphoneUID = "usb-mic-uid"

    // No SwiftUI view or explicit save call: even quitting immediately must work.
    let reopened = StudioSession(project: project, inputDevicesProvider: { microphones })
    #expect(reopened.settings == session.settings)
    #expect(reopened.inputName == "USB microphone")
    #expect(!reopened.selectedMicrophoneUnavailable)
    #expect(reopened.errorMessage == nil)

    reopened.settings.microphoneUID = nil
    let followingDefault = StudioSession(project: project, inputDevicesProvider: { microphones })
    #expect(followingDefault.settings.microphoneUID == nil)
    #expect(followingDefault.settings.language == "fr")
}

@Test func legacySettingsWithoutMicrophoneStillRestore() throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    try Data(#"{"studio":{"engine":"fake","modelFolder":"model","language":"fr","duration":40,"timed":false,"saveAudio":true,"audioDirectory":"recordings"}}"#.utf8)
        .write(to: project.appendingPathComponent("nami.json"))
    let restored = try StudioSettings.load(project: project)
    #expect(restored.microphoneUID == nil)
    #expect(restored.engine == "fake")
    #expect(restored.language == "fr")
    #expect(restored.duration == 40)
    #expect(!restored.timed)
    #expect(restored.saveAudio)
    #expect(restored.audioDirectory == project.appendingPathComponent("recordings").path)
}

@Test @MainActor func disconnectedMicrophoneIsRememberedAndUsedAfterReconnect() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    let devices = TestInputDevices()
    var requestedUID: String?
    let first = StudioSession(project: project, inputDevicesProvider: { devices.available })
    first.settings.microphoneUID = "remembered-mic"
    let reopened = StudioSession(project: project, engineBuilder: { _ in engine },
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
    let session = StudioSession(project: project)
    let config = project.appendingPathComponent("nami.json")
    let invalid = Data("invalid JSON".utf8)
    try invalid.write(to: config)
    session.settings.duration = 30
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
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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

@Test @MainActor func automaticStopCopiesFinalText() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    let engine = TestEngine(), capture = TestCapture()
    var copies: [String] = []
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
                                clipboardWriter: { copies.append($0); return true })
    session.settings.duration = 5
    session.startRecording()
    try await waitUntil { session.phase == .recording }
    capture.emit(seconds: 5.1)
    try await waitUntil { !session.phase.busy }
    #expect(copies == [engine.transcript])
}

@Test @MainActor func emptyOrFailedTranscriptionsPreserveClipboard() async throws {
    let project = try projectDirectory(); defer { try? FileManager.default.removeItem(at: project) }
    for fail in [false, true] {
        let engine = TestEngine(), capture = TestCapture()
        engine.transcript = " \n\t"; engine.fail = fail
        var writes = 0
        let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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
    let session = StudioSession(project: project, engineBuilder: { _ in engine }, captureBuilder: { _ in capture },
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
}
