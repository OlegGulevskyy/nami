import Foundation
import AppKit
import SwiftUI
import Testing
import NamiCore
import NamiAudio
@testable import NamiStudio

private func cleanupTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nami-cleanup-test-\(UUID())")
}

@MainActor private func awaitCleanup(_ lab: CleanupLabSession) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(!lab.isBusy)
}

private actor RecordingCleanupProcessor: TextProcessor {
    nonisolated let identifier: String
    let output: String
    private(set) var requests: [CleanupRequest] = []
    init(identifier: String, output: String) { self.identifier = identifier; self.output = output }
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String { requests.append(request); return output }
}

@Test @MainActor func cleanupLabQwenCorrectionReachesBothModelsAfterReopening() async throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let raw = "Please update the minor version in the POM file, without committing."
    let apple = RecordingCleanupProcessor(identifier: "apple-wiring-test", output: "Update the minor version in the POM file without committing.")
    let qwen = RecordingCleanupProcessor(identifier: "qwen-wiring-test", output: raw)
    let service = CleanupService(processors: [.apple: apple, .qwen: qwen])
    let lab = CleanupLabSession(directory: directory, service: service)
    lab.input = raw
    lab.compare()
    try await awaitCleanup(lab)
    let qwenResult = try #require(lab.latestRun?.results.first { $0.provider == qwen.identifier })
    lab.editCorrection(for: qwenResult)
    lab.correctedText = raw.replacingOccurrences(of: "POM", with: "“pom.xml”")
    lab.teachCorrection()
    let example = try #require(lab.memory.examples.first)
    #expect(example.processorID == qwen.identifier && example.generatedText == raw)
    #expect(lab.memory.vocabulary.isEmpty)
    let reopened = CleanupLabSession(directory: directory, service: service)
    reopened.input = raw
    reopened.compare()
    try await awaitCleanup(reopened)
    let qwenRequest = try #require(await qwen.requests.last)
    let appleRequest = try #require(await apple.requests.last)
    #expect(qwenRequest.memory.examples == [example])
    #expect(appleRequest.memory.examples == [example])
    #expect(CleanupPrompt.input(qwenRequest, highlightEdits: true).contains("Replace \"POM\" with \"“pom.xml”\" in the transcript."))
    reopened.useMemory = false
    reopened.compare()
    try await awaitCleanup(reopened)
    #expect(await qwen.requests.last?.memory.examples.isEmpty == true)
    #expect(reopened.memory.examples == [example])
}

@Test @MainActor func cleanupLabPersistsExplicitRulesExamplesAndComparisonSnapshots() async throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = CleanupLabSession(directory: directory, processor: VocabularyTextProcessor())
    lab.addVocabulary(heard: "name me", replacement: "Nami")
    lab.input = "please check name me"
    lab.compare()
    try await awaitCleanup(lab)
    #expect(lab.latestRun?.results.last?.text == "please check Nami")
    lab.correctedText = "Please check Nami."
    #expect(lab.memory.examples.isEmpty)
    lab.teachCorrection()
    lab.teachCorrection()
    #expect(lab.memory.examples.count == 1)
    #expect(lab.memory.examples.first?.generatedText == "please check Nami")
    #expect(lab.memory.examples.first?.rawText == "please check name me")
    #expect(lab.memory.examples.first?.sourceRunID == lab.latestRun?.id)
    #expect(lab.memory.examples.first?.processorID == "vocabulary-v1")
    #expect(lab.memory.examples.first?.memoryRevision == 1)
    #expect(lab.memory.examples.first?.feedbackSource == "cleanup-lab-explicit")
    #expect(lab.memory.vocabulary.count == 1)
    let restored = CleanupLabSession(directory: directory, processor: VocabularyTextProcessor())
    #expect(restored.memory == lab.memory)
    #expect(restored.runs.count == 1)
    #expect(restored.latestRun?.results.last?.memoryRevision == 1)
    restored.useMemory = false
    restored.input = lab.input
    restored.compare()
    try await awaitCleanup(restored)
    #expect(restored.latestRun?.results.last?.text == lab.input)
    #expect(restored.memory.examples.count == 1)
    restored.removeExample(try #require(restored.memory.examples.first?.id))
    restored.removeVocabulary(try #require(restored.memory.vocabulary.first?.id))
    let empty = CleanupLabSession(directory: directory)
    #expect(empty.memory.examples.isEmpty)
    #expect(empty.memory.vocabulary.isEmpty)
    #expect(empty.runs.count == 2)
}

@Test @MainActor func cleanupLabRefusesConflictingRulesAndDoesNotOverwriteConcurrentChanges() throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = CleanupLabSession(directory: directory)
    let stale = CleanupLabSession(directory: directory)
    first.addVocabulary(heard: "name me", replacement: "Nami")
    first.addVocabulary(heard: "NAME ME", replacement: "Conflict")
    #expect(first.memory.vocabulary.count == 1)
    stale.addVocabulary(heard: "other", replacement: "value")
    #expect(stale.errorMessage != nil)
    #expect(stale.memory.vocabulary.isEmpty)
    #expect(CleanupLabSession(directory: directory).memory.vocabulary.first?.replacement == "Nami")
}

@Test @MainActor func cleanupLabPreservesCorruptData() throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("workspace.json")
    let data = Data("broken".utf8)
    try data.write(to: file)
    let lab = CleanupLabSession(directory: directory)
    #expect(lab.loadFailed)
    lab.addVocabulary(heard: "name me", replacement: "Nami")
    lab.input = "Original"
    lab.compare()
    #expect(!lab.isBusy)
    #expect(try Data(contentsOf: file) == data)
}

private struct PreviewCleanupProcessor: TextProcessor {
    var identifier = "apple-system-cleanup-v2"
    func prepare() async throws {}
    func process(_ request: CleanupRequest) async throws -> String { "Can you check the Nami deployment? We need two instances." }
}

/// Renders only the new view with synthetic data; does not capture the desktop.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_CLEANUP_SNAPSHOT_DIR"] != nil))
@MainActor func cleanupLabRenderPreview() async throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NAMI_CLEANUP_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let studio = StudioSession(project: directory, historyDirectory: directory.appendingPathComponent("History"),
        permissions: StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
            requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false }),
        pastePreparer: { { _, _ in .targetUnavailable } },
        cleanupProcessors: [.apple: PreviewCleanupProcessor(), .qwen: PreviewCleanupProcessor(identifier: "qwen3-preview"),
                            .qwen17: PreviewCleanupProcessor(identifier: "qwen3-1.7b-preview")],
        captureBuilder: { _ in PreviewAudioCapture() }, clipboardWriter: { _ in true })
    let lab = studio.debugging.cleanupLab
    studio.debugging.page = .cleanup
    lab.compareQwen17 = true
    lab.input = "um can you check the name me deployment I think I think we need two instances"
    lab.addVocabulary(heard: "name me", replacement: "Nami")
    lab.compare()
    try await awaitCleanup(lab)
    for size in [NSSize(width: 760, height: 760), NSSize(width: 1300, height: 1100)] {
        let view = NSHostingView(rootView: InternalDebuggingView(session: studio, lab: studio.debugging)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("cleanup-\(Int(size.width)).png"))
    }
}

@MainActor private final class PreviewAudioCapture: AudioCapturing {
    let inputDescription = "Preview"
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> { throw EngineError.noAudio }
    func stop() {}
}
