import Foundation
import Testing
import NamiAudio
import NamiCore
@testable import NamiStudio

/// Opt-in real-model check. Replays a supplied fixture, never opens a microphone,
/// writes to an isolated history, and never touches the clipboard or focused app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_MODEL_FOLDER"] != nil))
@MainActor func realModelStartupCapturesBeforeLoadAndReusesWarmModel() async throws {
    let environment = ProcessInfo.processInfo.environment
    let model = try #require(environment["NAMI_TEST_MODEL_FOLDER"])
    let audioURL = URL(fileURLWithPath: try #require(environment["NAMI_TEST_AUDIO_FILE"]))
    let audio = try AudioFile.read(audioURL)
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("nami-startup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: project) }
    let capture = FixtureCapture(samples: audio)
    let permissions = StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
        accessibilityStatus: { false }, requestAccessibility: { false },
        requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false })
    let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("history"),
        permissions: permissions, pastePreparer: { { _, _ in .targetUnavailable } }, captureBuilder: { _ in capture },
        clipboardWriter: { _ in Issue.record("Diagnostic must not copy"); return false })
    session.settings.modelFolder = model
    session.settings.copyWhenFinished = false
    session.prepareForRecording()
    #expect(session.modelPreparing && session.phase == .idle)
    #expect(capture.starts == 0)
    var preparationSeconds: Double?
    for run in 0..<2 {
        session.startRecording()
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while session.phase.busy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.phase == .idle, "\(session.errorMessage ?? session.status)")
        #expect(session.modelLoaded)
        let firstAudio = try #require(session.firstAudioSeconds)
        let prepared = try #require(session.modelPreparationSeconds)
        if run == 0 {
            #expect(firstAudio < prepared)
            preparationSeconds = prepared
        } else { #expect(prepared == preparationSeconds) }
        let result = try #require(session.runs.first)
        #expect(!result.transcript.isEmpty)
        #expect(result.audioSeconds == Double(audio.count) / AudioChunk.sampleRate)
        #expect(try AudioFile.read(#require(result.savedURL)).count == audio.count)
        print("Startup run \(run): capture=\(session.captureStartSeconds ?? -1)s, first audio=\(firstAudio)s, model prepare=\(prepared)s, stop-to-final=\(result.latency)s")
    }
    #expect(capture.starts == 2 && session.runs.count == 2)
    #expect(session.runs[0].transcript == session.runs[1].transcript)
}

@MainActor private final class FixtureCapture: AudioCapturing {
    let inputDescription = "Startup test fixture"
    let samples: [Float]
    private(set) var starts = 0

    init(samples: [Float]) { self.samples = samples }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        starts += 1
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        for offset in stride(from: 0, to: samples.count, by: 2048) {
            pair.continuation.yield(AudioChunk(samples: Array(samples[offset..<min(samples.count, offset + 2048)]),
                timestamp: Double(offset) / AudioChunk.sampleRate))
        }
        pair.continuation.finish()
        return pair.stream
    }

    func stop() {}
}
