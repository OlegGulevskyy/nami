import Foundation
import Testing
import NamiCore
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
    let qwen = RecordingCleanupProcessor(identifier: "qwen-wiring-test", output: raw)
    let large = RecordingCleanupProcessor(identifier: "qwen17-wiring-test", output: "Update the minor version in the POM file without committing.")
    let service = CleanupService(processors: [.qwen: qwen, .qwen17: large])
    let lab = CleanupLabSession(directory: directory, service: service)
    lab.compareQwen17 = true
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
    let largeRequest = try #require(await large.requests.last)
    #expect(qwenRequest.memory.examples == [example])
    #expect(largeRequest.memory.examples == [example])
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

@Test @MainActor func cleanupLabLoadsWorkspaceSavedWithRemovedAppleEngine() throws {
    let directory = cleanupTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lab = CleanupLabSession(directory: directory)
    lab.addVocabulary(heard: "name me", replacement: "Nami")
    let file = directory.appendingPathComponent("workspace.json")
    var workspace = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    workspace["comparisonEngines"] = ["apple", "qwen17"]
    try JSONSerialization.data(withJSONObject: workspace).write(to: file)
    let restored = CleanupLabSession(directory: directory)
    #expect(!restored.loadFailed)
    #expect(!restored.compareQwen && restored.compareQwen17)
    #expect(restored.memory.vocabulary.first?.replacement == "Nami")
    let settings = try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"cleanupEngine":"apple"}"#.utf8))
    #expect(settings.cleanupEngine == .automatic)
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
