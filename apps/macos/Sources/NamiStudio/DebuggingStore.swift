import Darwin
import Foundation
import NamiCore

struct DebugSample: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var expectedText = ""
    var language = "en"
    var createdAt = Date()
    var audioSeconds: Double
    var source: String
    var referenceVerified: Bool?
    var category: String?
}

struct DebugModel: Codable, Identifiable, Sendable {
    var id: String { folder }
    var name: String
    var folder: String
    var enabled = true
}

struct DebugResult: Codable, Identifiable, Sendable {
    var id = UUID()
    var batchID: UUID
    var sampleID: UUID
    var model: DebugModel
    var date = Date()
    var expectedText: String
    var language: String
    var transcript: String
    var preparationSeconds: Double
    var transcriptionSeconds: Double
    var error: String?
    var referenceVerified: Bool?
    var cloudResponse: CloudTranscript?
    var audioSHA256: String?

    var wordErrorRate: Double? {
        guard error == nil, !EvaluationMetrics.words(expectedText).isEmpty else { return nil }
        return EvaluationMetrics.wordErrorRate(reference: expectedText, hypothesis: transcript)
    }
}

struct DebugWorkspace: Codable, Sendable {
    var version = 1
    var samples: [DebugSample] = []
    var models: [DebugModel] = []
    var results: [DebugResult] = []
    var comparisonModelID: String?
}

@MainActor final class DebuggingStore {
    private var loadedData: Data?
    init(directory: URL) { self.directory = directory }
    let directory: URL
    var metadataURL: URL { directory.appendingPathComponent("workspace.json") }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("Audio/\(id.uuidString).wav") }

    func load() throws -> DebugWorkspace {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return DebugWorkspace() }
        let data = try Data(contentsOf: metadataURL)
        let workspace = try JSONDecoder().decode(DebugWorkspace.self, from: data)
        guard workspace.version == 1,
              Set(workspace.samples.map(\.id)).count == workspace.samples.count,
              Set(workspace.models.map(\.id)).count == workspace.models.count else {
            throw StudioError.message("Unsupported or invalid debugging workspace. Your files have been kept.")
        }
        loadedData = data
        return workspace
    }

    func save(_ workspace: DebugWorkspace) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".workspace.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StudioError.message("Cannot lock debugging workspace.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StudioError.message("Another process is writing this workspace. Retry after it finishes.") }
        defer { flock(descriptor, LOCK_UN) }
        let currentData = try FileManager.default.fileExists(atPath: metadataURL.path) ? Data(contentsOf: metadataURL) : nil
        guard currentData == loadedData else { throw StudioError.message("Workspace changed in another process. Reopen Nami or rerun the CLI to reload it before saving.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: metadataURL, options: .atomic)
        loadedData = data
    }

    func saveAudio(_ samples: [Float], id: UUID) throws {
        guard !samples.isEmpty else { throw EngineError.noAudio }
        let url = audioURL(id)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StudioSession.wavData(samples).write(to: url, options: .atomic)
    }
}
