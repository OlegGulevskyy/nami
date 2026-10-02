import Foundation

/// Defaults come from nami.json in the working directory. Explicit CLI options win.
struct ProjectConfiguration: Decodable {
    var engine: String?
    var language: String?
    var modelFolder: String?

    static func load(from url: URL, required: Bool) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if required { throw CLIError("Configuration file not found: \(url.path)") }
            return Self()
        }
        do {
            let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            for value in [config.engine, config.language, config.modelFolder].compactMap({ $0 }) {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError("Configuration values must not be empty.")
                }
            }
            return config
        } catch {
            throw CLIError("Cannot read configuration at \(url.path): \(error.localizedDescription)")
        }
    }

    static func resolvePath(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
    }

    /// Preserve other settings, including unrecognized keys, when selecting a download.
    static func saveModelFolder(_ folder: URL, to url: URL) throws {
        var values: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError("Configuration must be a JSON object: \(url.path)")
            }
            values = existing
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        values["modelFolder"] = folder.path.hasPrefix(home)
            ? "~/" + folder.path.dropFirst(home.count) : folder.path
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
