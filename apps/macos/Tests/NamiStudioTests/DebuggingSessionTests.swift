import Foundation
import Testing
import NamiAudio
import NamiCore
@testable import NamiStudio

@MainActor private func debugHistoryRun() -> RecordingRun {
    RecordingRun(id: UUID(), date: .now, transcript: "Unverified ASR text", audioSeconds: 0.1,
        latency: 0.1, averageDB: -20, peakDB: -10, input: "Fixture", savedURL: nil,
        engine: "fake", model: "fixture", prompt: "", samples: Array(repeating: 0.1, count: 1600))
}

@MainActor private func waitForDebugging(_ lab: DebuggingSession) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(!lab.isBusy)
}

private func debugDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nami-debug-test-" + UUID().uuidString)
}

@Test @MainActor func debuggingPersistsAudioReferencesAndResults() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = DebuggingSession(directory: directory, engineBuilder: { folder in
        FakeTranscriptionEngine(transcript: folder.hasSuffix("good") ? "We need two instances." : "We need one instance.")
    })
    lab.useHistory(debugHistoryRun(), language: "en")
    let sample = try #require(lab.selectedSample)
    #expect(sample.expectedText.isEmpty) // ASR output is not a verified reference.
    #expect(try AudioFile.read(DebuggingStore(directory: directory).audioURL(sample.id)).count == 1600)
    lab.updateSample(sample.id, title: "A correction", expectedText: "We need two instances.")
    lab.addModel(folder: URL(fileURLWithPath: "/models/good"))
    lab.addModel(folder: URL(fileURLWithPath: "/models/other"))
    lab.runComparison()
    try await waitForDebugging(lab)
    #expect(lab.workspace.results.count == 2)
    #expect(lab.workspace.results.first?.wordErrorRate == 0)
    #expect(lab.workspace.results.last?.wordErrorRate == 0.5)
    lab.updateSample(sample.id, expectedText: "A different expectation")
    let restored = DebuggingSession(directory: directory)
    #expect(restored.selectedSample?.expectedText == "A different expectation")
    #expect(restored.workspace.results.first?.expectedText == "We need two instances.")
    #expect(restored.workspace.results.first?.wordErrorRate == 0)
    #expect(restored.workspace.samples.first?.title == "A correction")
    #expect(restored.workspace.models.count == 2)
}

@Test @MainActor func debuggingBatchReusesEachModelAndHonorsSelection() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var builds: [String] = []
    let lab = DebuggingSession(directory: directory, engineBuilder: { folder in
        builds.append(folder)
        return FakeTranscriptionEngine(transcript: "Hello")
    })
    for _ in 0..<2 { lab.useHistory(debugHistoryRun(), language: "en") }
    lab.addModel(folder: URL(fileURLWithPath: "/models/selected"))
    lab.addModel(folder: URL(fileURLWithPath: "/models/disabled"))
    lab.setModelEnabled("/models/disabled", enabled: false)
    lab.runComparison(allSamples: true)
    try await waitForDebugging(lab)
    #expect(builds == ["/models/selected"])
    #expect(lab.workspace.results.count == 2)
    #expect(Set(lab.workspace.results.map(\.batchID)).count == 1)
    #expect(lab.workspace.results.allSatisfy { $0.wordErrorRate == nil })
}

@Test @MainActor func debuggingModelFailureDoesNotPreventNextModel() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = DebuggingSession(directory: directory, engineBuilder: { folder in
        if folder.hasSuffix("broken") { throw EngineError.modelUnavailable("Missing files") }
        return FakeTranscriptionEngine(transcript: "Hello")
    })
    lab.useHistory(debugHistoryRun(), language: "en")
    lab.addModel(folder: URL(fileURLWithPath: "/models/broken"))
    lab.addModel(folder: URL(fileURLWithPath: "/models/working"))
    lab.runComparison()
    try await waitForDebugging(lab)
    #expect(lab.workspace.results.count == 2)
    #expect(lab.workspace.results.first?.error != nil)
    #expect(lab.workspace.results.first?.wordErrorRate == nil)
    #expect(lab.workspace.results.last?.transcript == "Hello")
}

@MainActor private final class DebugLateEngine: TranscriptionEngine {
    let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: false)
    var started = false
    var cancelled = false
    func prepare() async throws {}
    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {}
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws {}
    func finish(sessionID: UUID) async throws -> String {
        started = true
        try? await Task.sleep(for: .milliseconds(100))
        return "A late response"
    }
    func cancel(sessionID: UUID) async { cancelled = true }
}

@Test @MainActor func debuggingCancellationRejectsLateResults() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = DebugLateEngine()
    let lab = DebuggingSession(directory: directory, engineBuilder: { _ in engine })
    lab.useHistory(debugHistoryRun(), language: "en")
    lab.addModel(folder: URL(fileURLWithPath: "/models/slow"))
    lab.runComparison()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !engine.started && .now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(engine.started)
    lab.cancel()
    try await waitForDebugging(lab)
    #expect(engine.cancelled)
    #expect(lab.workspace.results.isEmpty)
    #expect(lab.workspace.samples.count == 1)
}

@Test @MainActor func debuggingImportKeepsIndependentAudio() async throws {
    let directory = debugDirectory(), input = debugDirectory().appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: input) }
    try AudioFile.write(Array(repeating: 0.1, count: 1600), to: input)
    let lab = DebuggingSession(directory: directory)
    lab.importAudio(input)
    try await waitForDebugging(lab)
    try FileManager.default.removeItem(at: input)
    let id = try #require(lab.selectedSampleID)
    #expect(try AudioFile.read(DebuggingStore(directory: directory).audioURL(id)).count == 1600)
}

@Test @MainActor func debuggingCorruptWorkspaceIsNotOverwritten() throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = DebuggingStore(directory: directory)
    let broken = Data("invalid metadata".utf8)
    try broken.write(to: store.metadataURL)
    let lab = DebuggingSession(directory: directory)
    #expect(lab.loadFailed)
    lab.useHistory(debugHistoryRun(), language: "en")
    lab.addModel(folder: URL(fileURLWithPath: "/models/ignored"))
    lab.save()
    #expect(try Data(contentsOf: store.metadataURL) == broken)
    #expect(lab.workspace.samples.isEmpty)
}

@MainActor private final class DebugCapture: AudioCapturing {
    let inputDescription = "Fixture microphone"
    var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    var stopped = false
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        continuation = pair.continuation
        continuation?.yield(AudioChunk(samples: Array(repeating: 0.1, count: 1600), timestamp: 0))
        return pair.stream
    }
    func stop() { stopped = true; continuation?.finish() }
}

@Test @MainActor func debuggingRecordingSavesWithoutLoadingAnyModel() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = DebugCapture()
    let lab = DebuggingSession(directory: directory, engineBuilder: { _ in
        Issue.record("Recording must not load a model")
        return FakeTranscriptionEngine()
    }, captureBuilder: { _ in capture })
    lab.startRecording(microphoneUID: nil, language: "en")
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !lab.recording && .now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(lab.recording)
    lab.stopRecording()
    try await waitForDebugging(lab)
    #expect(capture.stopped)
    #expect(lab.workspace.samples.count == 1)
    #expect(lab.workspace.samples.first?.audioSeconds == 0.1)
    #expect(lab.workspace.results.isEmpty)
}

@Test @MainActor func debuggingMissingAudioIsReportedPerResult() async throws {
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = DebuggingSession(directory: directory, engineBuilder: { _ in FakeTranscriptionEngine() })
    lab.useHistory(debugHistoryRun(), language: "en")
    let id = try #require(lab.selectedSampleID)
    try FileManager.default.removeItem(at: DebuggingStore(directory: directory).audioURL(id))
    lab.addModel(folder: URL(fileURLWithPath: "/models/test"))
    lab.runComparison()
    try await waitForDebugging(lab)
    #expect(lab.workspace.results.count == 1)
    #expect(lab.workspace.results.first?.error != nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_MODEL_FOLDER"] != nil))
@MainActor func debuggingRealModelComparison() async throws {
    let environment = ProcessInfo.processInfo.environment
    let folder = try #require(environment["NAMI_TEST_MODEL_FOLDER"])
    let audio = URL(fileURLWithPath: try #require(environment["NAMI_TEST_AUDIO_FILE"]))
    let directory = debugDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = DebuggingSession(directory: directory)
    lab.importAudio(audio)
    try await waitForDebugging(lab)
    let sample = try #require(lab.selectedSample)
    lab.updateSample(sample.id, expectedText: "And so my fellow Americans ask not what your country can do for you ask what you can do for your country.")
    lab.addModel(folder: URL(fileURLWithPath: folder))
    lab.runComparison()
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    #expect(!lab.isBusy)
    let result = try #require(lab.workspace.results.first)
    #expect(result.error == nil)
    #expect(!result.transcript.isEmpty)
    #expect(result.wordErrorRate != nil)
    let restored = DebuggingSession(directory: directory)
    #expect(restored.workspace.results.first?.transcript == result.transcript)
    print("Debugging real-model comparison: \(result.transcript) | prepare \(result.preparationSeconds)s | transcribe \(result.transcriptionSeconds)s | WER \(result.wordErrorRate ?? -1)")
}
