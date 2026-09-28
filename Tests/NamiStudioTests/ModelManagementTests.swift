import Foundation
import AppKit
import SwiftUI
import Testing
import NamiCore
import NamiAudio
import NamiMLXCleanup
import NamiWhisperKit
@testable import NamiStudio

private func modelTestRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("nami-model-ui-\(UUID())") }
private func fakeWhisper(at folder: URL) throws {
    for name in ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin",
                 "MelSpectrogram.mlmodelc/model.mil", "tokenizer.json", "tokenizer_config.json"] {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
}
@MainActor private final class ModelTestCapture: AudioCapturing {
    let inputDescription = "Model fixture"
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> { throw EngineError.noAudio }
    func stop() {}
}
@MainActor private func modelSession(_ root: URL, processors: [CleanupEngine: any TextProcessor] = [:]) -> StudioSession {
    StudioSession(project: root, historyDirectory: root.appendingPathComponent("History"),
        permissions: StudioPermissions(microphoneStatus: { .authorized }, inputMonitoringStatus: { true },
            requestMicrophone: { false }, requestInputMonitoring: { false }, openSettings: { _ in false }),
        pastePreparer: { { .targetUnavailable } }, cleanupProcessors: processors,
        modelDirectory: root.appendingPathComponent("Models"), captureBuilder: { _ in ModelTestCapture() }, clipboardWriter: { _ in true })
}

@Test @MainActor func modelInventoryAndWhisperDeletionClearSelectionButKeepHistory() async throws {
    let root = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = modelSession(root)
    let folder = root.appendingPathComponent("Models/models/argmaxinc/whisperkit-coreml/\(WhisperKitEngine.defaultModel)")
    try fakeWhisper(at: folder)
    session.settings.modelFolder = folder.path
    session.debugging.addModel(folder: folder)
    let recording = root.appendingPathComponent("History/keep.wav")
    try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("recording".utf8).write(to: recording)
    session.refreshModels()
    let model = try #require(session.modelLibrary.transcription.first { $0.id == folder.path })
    #expect(model.installed && model.managed && model.bytes > 0)
    try await session.deleteTranscriptionModel(model)
    #expect(session.settings.modelFolder.isEmpty)
    #expect(try StudioSettings.load(project: root).modelFolder.isEmpty)
    #expect(session.debugging.workspace.models.first?.enabled == false)
    #expect(session.modelLibrary.transcription.first?.installed == false)
    #expect(FileManager.default.fileExists(atPath: recording.path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@Test @MainActor func modelLibraryFindsDebugDownloadsAndRefusesExternalOrParentDeletion() throws {
    let root = modelTestRoot(), external = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
    let debugRoot = root.appendingPathComponent("InternalDebugging/Models")
    let managed = debugRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
    let outside = external.appendingPathComponent("openai_whisper-other")
    try fakeWhisper(at: managed)
    try fakeWhisper(at: outside)
    let library = ModelLibrary(roots: [root.appendingPathComponent("Models"), debugRoot])
    library.refresh(knownFolders: [outside.path])
    #expect(library.transcription.contains { $0.folder.path == managed.path && $0.installed && $0.managed })
    let externalModel = try #require(library.transcription.first { $0.folder.path == outside.path })
    #expect(!externalModel.managed)
    #expect(throws: (any Error).self) { try library.delete(externalModel) }
    let link = managed.deletingLastPathComponent().appendingPathComponent("openai_whisper-linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(!library.isManaged(link))
    #expect(!library.isManaged(root))
    #expect(ModelFiles.whisperInstalled(at: outside))
    library.refresh(knownFolders: [], catalog: ["distil-whisper_distil-large-v3_594MB", "../../whisper-outside"])
    #expect(library.transcription.contains { $0.name == "distil-whisper_distil-large-v3_594MB" && !$0.installed })
    #expect(!library.transcription.contains { $0.name == "whisper-outside" })
}

private actor ManagedCleanupProbe: TextProcessor {
    nonisolated let identifier: String
    private(set) var unloaded = false
    private(set) var requests: [CleanupRequest] = []
    var blocked = false
    private var continuation: CheckedContinuation<String, Never>?
    init(_ identifier: String, blocked: Bool = false) { self.identifier = identifier; self.blocked = blocked }
    func prepare() async throws {}
    func unload() async { unloaded = true }
    func process(_ request: CleanupRequest) async throws -> String {
        requests.append(request)
        if blocked { return await withCheckedContinuation { continuation = $0 } }
        return request.rawText
    }
    func release() { continuation?.resume(returning: "Late text"); continuation = nil }
}

@Test @MainActor func deletingQwenUnloadsItAndNeverDeletesAnotherModelOrCorrections() async throws {
    let root = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ManagedCleanupProbe(QwenModel.qwen17.processorID)
    let session = modelSession(root, processors: [.qwen17: probe])
    let target = session.cleanupService.folder(for: .qwen17)
    let other = session.cleanupService.folder(for: .qwen06)
    for folder in [target, other] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
    }
    session.settings.cleanupEngine = .qwen17
    session.settings.cleanupEnabled = true
    session.debugging.cleanupLab.compareQwen17 = true
    session.debugging.cleanupLab.addVocabulary(heard: "name me", replacement: "Nami")
    try await session.deleteCleanupModel(.qwen17)
    #expect(await probe.unloaded)
    #expect(!session.settings.cleanupEnabled && session.settings.cleanupEngine == .automatic)
    #expect(!session.debugging.cleanupLab.compareQwen17)
    #expect(session.debugging.cleanupLab.memory.vocabulary.count == 1)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
}

@Test @MainActor func cannotDeleteQwenWhileTimedOutWorkerIsStillRunning() async throws {
    let root = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ManagedCleanupProbe(QwenModel.qwen17.processorID, blocked: true)
    let service = CleanupService(processors: [.qwen17: probe], modelsRoot: root)
    let folder = service.folder(for: .qwen17)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let result = try await service.run(.init(rawText: "Original text."), engine: .qwen17, timeout: 0.05)
    #expect(result.outcome == .timedOut)
    await #expect(throws: (any Error).self) { try await service.deleteQwen(.qwen17) }
    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(await !probe.unloaded)
    await probe.release()
}

@Test @MainActor func qwen17ComparisonPersistsAndLiveEngineUsesItsOwnProvider() async throws {
    let root = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let small = ManagedCleanupProbe(QwenModel.qwen06.processorID)
    let large = ManagedCleanupProbe(QwenModel.qwen17.processorID)
    let service = CleanupService(processors: [.qwen: small, .qwen17: large], modelsRoot: root.appendingPathComponent("Models"))
    let lab = CleanupLabSession(directory: root, service: service)
    lab.compareApple = false; lab.compareQwen = true; lab.compareQwen17 = true
    lab.input = "Keep two instances."
    lab.compare()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while lab.isBusy && .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(lab.latestRun?.results.map(\.provider) == ["vocabulary-v1", small.identifier, large.identifier])
    let restored = CleanupLabSession(directory: root, service: service)
    #expect(restored.compareQwen17 && restored.compareQwen && !restored.compareApple)
    let result = try await service.run(.init(rawText: "A live request."), engine: .qwen17, timeout: 1)
    #expect(result.provider == large.identifier)
    #expect(await large.requests.count == 2)
    #expect(await small.requests.count == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMI_MODELS_SNAPSHOT_DIR"] != nil))
@MainActor func modelsPageRendersInstalledAndUninstalledModels() async throws {
    let root = modelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = modelSession(root, processors: [.qwen: ManagedCleanupProbe(QwenModel.qwen06.processorID)])
    try FileManager.default.createDirectory(at: session.cleanupService.folder(for: .qwen06), withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("Models/models/argmaxinc/whisperkit-coreml/\(WhisperKitEngine.defaultModel)")
    try fakeWhisper(at: folder)
    session.settings.modelFolder = folder.path
    session.refreshModels()
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NAMI_MODELS_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for size in [NSSize(width: 760, height: 850), NSSize(width: 1100, height: 1000)] {
        let view = NSHostingView(rootView: StudioView(session: session, page: .constant(.model)).frame(width: size.width, height: size.height))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("models-\(Int(size.width)).png"))
    }
}
