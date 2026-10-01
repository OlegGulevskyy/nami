import Foundation
import NamiCore

public struct StudioSettings: Codable, Equatable, Sendable {
    public var engine = "whisperkit"
    public var modelFolder = ""
    public var language = "en"
    public var vocabulary = ""
    public var transcriptFont: TranscriptFont = .sourceSans
    public var appearance: StudioAppearance = .system
    public var saveAudio = false
    public var copyWhenFinished = true
    public var pasteWhenFinished = true
    public var cleanupEnabled = false
    public var cleanupEngine: CleanupEngine = .automatic
    public var cleanupTimeoutSeconds = 1.0
    public var cleanupUseMemory = true
    public var audioDirectory = ""
    /// nil follows the system default; a UID pins Nami to a specific microphone.
    public var microphoneUID: String?
    /// Where agent skills are installed; empty means Claude Code's `~/.claude/skills`.
    public var skillsFolder = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case engine, modelFolder, language, vocabulary, transcriptFont, appearance, saveAudio, copyWhenFinished, pasteWhenFinished, audioDirectory, microphoneUID, skillsFolder
        case cleanupEnabled, cleanupEngine, cleanupTimeoutSeconds, cleanupUseMemory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decodeIfPresent(String.self, forKey: .engine) ?? "whisperkit"
        modelFolder = try values.decodeIfPresent(String.self, forKey: .modelFolder) ?? ""
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en"
        vocabulary = try values.decodeIfPresent(String.self, forKey: .vocabulary) ?? ""
        transcriptFont = (try values.decodeIfPresent(String.self, forKey: .transcriptFont))
            .flatMap(TranscriptFont.init(rawValue:)) ?? .sourceSans
        appearance = (try values.decodeIfPresent(String.self, forKey: .appearance))
            .flatMap(StudioAppearance.init(rawValue:)) ?? .system
        saveAudio = try values.decodeIfPresent(Bool.self, forKey: .saveAudio) ?? false
        copyWhenFinished = try values.decodeIfPresent(Bool.self, forKey: .copyWhenFinished) ?? true
        pasteWhenFinished = try values.decodeIfPresent(Bool.self, forKey: .pasteWhenFinished) ?? true
        cleanupEnabled = try values.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? false
        cleanupEngine = (try values.decodeIfPresent(String.self, forKey: .cleanupEngine)).flatMap(CleanupEngine.init(rawValue:)) ?? .automatic
        let timeout = try values.decodeIfPresent(Double.self, forKey: .cleanupTimeoutSeconds) ?? 1
        cleanupTimeoutSeconds = timeout.isFinite ? min(10, max(0.1, timeout)) : 1
        cleanupUseMemory = try values.decodeIfPresent(Bool.self, forKey: .cleanupUseMemory) ?? true
        audioDirectory = try values.decodeIfPresent(String.self, forKey: .audioDirectory) ?? ""
        microphoneUID = try values.decodeIfPresent(String.self, forKey: .microphoneUID)
        skillsFolder = try values.decodeIfPresent(String.self, forKey: .skillsFolder) ?? ""
    }

    public static func load(project: URL) throws -> Self {
        let url = project.appendingPathComponent("nami.json")
        var result = Self()
        result.audioDirectory = project.appendingPathComponent("evaluation/audio").path
        guard FileManager.default.fileExists(atPath: url.path) else { return result }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw StudioError.message("nami.json must contain a JSON object.")
        }
        if let studio = json["studio"] as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: studio)
            result = try JSONDecoder().decode(Self.self, from: data)
        }
        result.engine = json["engine"] as? String ?? result.engine
        result.language = json["language"] as? String ?? result.language
        result.modelFolder = json["modelFolder"] as? String ?? result.modelFolder
        result.modelFolder = resolve(result.modelFolder, project: project)
        result.audioDirectory = resolve(result.audioDirectory, project: project)
        return result
    }

    public func save(project: URL) throws {
        let url = project.appendingPathComponent("nami.json")
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let original = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw StudioError.message("nami.json is invalid; settings were not overwritten.")
            }
            json = original
        }
        json["engine"] = engine
        json["language"] = language
        json["modelFolder"] = modelFolder
        json["studio"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func resolve(_ path: String, project: URL) -> String {
        guard !path.isEmpty else { return "" }
        let directory = URL(fileURLWithPath: project.path, isDirectory: true)
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL.path
    }
}

public enum StudioAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum StudioError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

public struct ReadingPrompt: Decodable, Identifiable, Sendable {
    public let id: String
    public let reference: String
    public let category: String
}
