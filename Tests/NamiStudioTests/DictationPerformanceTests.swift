import Foundation
import AppKit
import Testing
import NamiAudio
import NamiCore
import NamiWhisperKit
import NamiMLXCleanup
@testable import NamiStudio

private final class PerformanceBundleMarker: NSObject {}

/// Replays real microphone timing through the production controller, ASR, cleanup,
/// history writes and publication callback. All writes stay in an isolated folder.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_TEST_DICTATION_FILES"] != nil))
@MainActor func savedDictationEndToEndPerformance() async throws {
    _ = Bundle(for: PerformanceBundleMarker.self)
    let env = ProcessInfo.processInfo.environment
    let paths = try #require(env["NAMI_TEST_DICTATION_FILES"]).split(separator: "\n").map(String.init)
    let expectations = try env["NAMI_TEST_DICTATION_EXPECTATIONS"].map {
        try JSONDecoder().decode([String: DictationExpectation].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    } ?? [:]
    let source = URL(fileURLWithPath: try #require(env["NAMI_TEST_PROJECT"]))
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("nami-performance-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: project) }
    let history = project.appendingPathComponent("history")
    let debug = history.appendingPathComponent("InternalDebugging")
    try FileManager.default.createDirectory(at: debug.appendingPathComponent("Cleanup"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source.appendingPathComponent("nami.json"), to: project.appendingPathComponent("nami.json"))
    if let settingsDirectory = env["NAMI_TEST_DEBUG_SETTINGS"] {
        for file in ["prompts.json", "Cleanup/workspace.json"] {
            let input = URL(fileURLWithPath: settingsDirectory).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: input.path) {
                try FileManager.default.copyItem(at: input, to: debug.appendingPathComponent(file))
            }
        }
    }
    let capture = TimedRecordingReplay()
    let permissions = StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
        accessibilityStatus: { true }, requestAccessibility: { false }, requestMicrophone: { false },
        requestInputMonitoring: { false }, openSettings: { _ in false })
    var published: (text: String, seconds: Double)?
    let pasteboard = NSPasteboard(name: .init("nami-performance-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    let paster = TranscriptPaster(accessibilityGranted: { true },
        focusedTarget: { .init(pid: 1234, element: nil) }, modifiers: { [] },
        postPaste: { _ in
            published = (pasteboard.string(forType: .string) ?? "", capture.stopInstant.map(performanceSeconds) ?? -1)
            return true
        }, pasteboard: pasteboard)
    let session = StudioSession(project: project, historyDirectory: history, permissions: permissions,
        pastePreparer: { paster.prepare() }, engineBuilder: { options in
            let whisper = WhisperKitEngine(modelFolder: options.modelFolder)
            if let folder = env["NAMI_TEST_FAST_MODEL_FOLDER"] { return FastTranscriptionEngine(modelFolder: folder, verifier: whisper) }
            return whisper
        }, cleanupProcessors: Dictionary(uniqueKeysWithValues: QwenModel.allCases.map {
            ($0.engine, QwenTextProcessor(model: $0, speculativeDecoding: env["NAMI_TEST_BASELINE"] != "1") as any TextProcessor)
        }), captureBuilder: { _ in capture },
        clipboardWriter: { _ in Issue.record("Benchmark must not change clipboard"); return false })
    if let value = env["NAMI_TEST_CLEANUP_TEMPERATURE"], let temperature = Double(value) {
        var configuration = session.debugging.promptStore.configuration
        configuration.qwenGeneration.temperature = temperature
        #expect(session.debugging.promptStore.save(configuration: configuration, playgroundVocabulary: ""))
    }
    session.settings.engine = env["NAMI_TEST_FAST_MODEL_FOLDER"] != nil ? "fast" : "whisperkit"
    if let value = env["NAMI_TEST_CLEANUP_ENGINE"], let engine = CleanupEngine(rawValue: value) { session.settings.cleanupEngine = engine }
    session.settings.copyWhenFinished = false
    session.settings.pasteWhenFinished = true
    session.settings.saveAudio = false
    session.prepareForRecording()
    try await performanceWait { session.modelLoaded && !session.cleanupService.warming }
    var report: [[String: Any]] = []
    for path in paths {
        published = nil
        capture.samples = try AudioFile.read(URL(fileURLWithPath: path))
        session.startRecording()
        try await performanceWait { !session.phase.busy }
        #expect(session.phase == .idle, "\(session.errorMessage ?? session.status)")
        let run = try #require(session.runs.first)
        let publication = try #require(published)
        if let value = env["NAMI_TEST_MAX_STOP_SECONDS"], let maximum = Double(value) {
            #expect(publication.seconds <= maximum, "Stop-to-publication exceeded \(maximum)s: \(publication.seconds)s")
        }
        let key = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let qualityPassed = expectations[key]?.check(publication.text) ?? true
        let row: [String: Any] = [
            "audio": path, "audioSeconds": run.audioSeconds,
            "fastModel": env["NAMI_TEST_FAST_MODEL_FOLDER"] ?? "",
            "cleanupTemperature": session.debugging.promptStore.configuration.qwenGeneration.temperature,
            "speculativeCleanup": env["NAMI_TEST_BASELINE"] != "1",
            "stopToPublicationSeconds": publication.seconds, "recordedLatency": run.latency,
            "rawTranscript": run.rawTranscript ?? run.transcript, "transcript": run.transcript,
            "qualityChecksPassed": qualityPassed, "qualityChecksApplied": expectations[key] != nil,
            "cleanup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(run.cleanupResult)),
            "decodes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.debugging.promptStore.records.filter { $0.requestID == run.id }))
        ]
        report.append(row)
        print("Dictation replay: \(URL(fileURLWithPath: path).lastPathComponent) \(publication.seconds)s, cleanup \(run.cleanupResult?.elapsedSeconds ?? 0)s")
        if let output = env["NAMI_TEST_DICTATION_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
    }
}

private struct DictationExpectation: Decodable {
    let mustContain: [String]
    let mustNotContain: [String]
    let requiredWordCounts: [String: Int]
    let forbiddenWords: [String]
    let exactCompact: String?
    let minimumWords: Int

    func check(_ text: String) -> Bool {
        func compact(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let actual = compact(text)
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        var passed = true
        func check(_ condition: Bool, _ message: String) {
            #expect(condition, Comment(rawValue: message))
            passed = passed && condition
        }
        if let exactCompact { check(actual == compact(exactCompact), "The complete transcript changed: \(text)") }
        for phrase in mustContain { check(actual.contains(compact(phrase)), "Missing content: \(phrase)") }
        for phrase in mustNotContain { check(!actual.contains(compact(phrase)), "Unexpected content: \(phrase)") }
        for word in forbiddenWords { check(!words.contains(word), "Unremoved hesitation: \(word)") }
        for (word, count) in requiredWordCounts { check(words.filter { $0 == word }.count == count, "Changed deliberate repetition: \(word)") }
        check(words.count >= minimumWords, "Too much content removed")
        return passed
    }
}

@MainActor private final class TimedRecordingReplay: AudioCapturing {
    let inputDescription = "Saved recording performance replay"
    var samples: [Float] = []
    var stopInstant: ContinuousClock.Instant?
    private var replay: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        continuation = pair.continuation
        stopInstant = nil
        let samples = samples
        replay = Task {
            let start = ContinuousClock.now
            do {
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    let end = min(samples.count, offset + 1600)
                    try await ContinuousClock().sleep(until: start.advanced(by: .seconds(Double(end) / AudioChunk.sampleRate)))
                    pair.continuation.yield(AudioChunk(samples: Array(samples[offset..<end]), timestamp: Double(offset) / AudioChunk.sampleRate))
                }
                self.stopInstant = .now
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        return pair.stream
    }
    func stop() { continuation?.finish(); continuation = nil }
}

@MainActor private func performanceWait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(predicate(), "Performance replay timed out")
}

private func performanceSeconds(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now).components
    return Double(d.seconds) + Double(d.attoseconds) / 1e18
}
