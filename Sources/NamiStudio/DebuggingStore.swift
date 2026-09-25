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
}

@MainActor struct DebuggingStore {
    let directory: URL
    var metadataURL: URL { directory.appendingPathComponent("workspace.json") }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("Audio/\(id.uuidString).wav") }

    func load() throws -> DebugWorkspace {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return DebugWorkspace() }
        let workspace = try JSONDecoder().decode(DebugWorkspace.self, from: Data(contentsOf: metadataURL))
        guard workspace.version == 1,
              Set(workspace.samples.map(\.id)).count == workspace.samples.count,
              Set(workspace.models.map(\.id)).count == workspace.models.count else {
            throw StudioError.message("Unsupported or invalid debugging workspace. Your files have been kept.")
        }
        return workspace
    }

    func save(_ workspace: DebugWorkspace) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: metadataURL, options: .atomic)
    }

    func saveAudio(_ samples: [Float], id: UUID) throws {
        guard !samples.isEmpty else { throw EngineError.noAudio }
        let url = audioURL(id)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StudioSession.wavData(samples).write(to: url, options: .atomic)
    }
}
