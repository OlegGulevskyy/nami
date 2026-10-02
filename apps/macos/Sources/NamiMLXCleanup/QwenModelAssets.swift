import Foundation
import NamiCore

public enum QwenModel: String, CaseIterable, Sendable, Identifiable {
    case qwen06, qwen17, qwen4
    public var id: String { rawValue }
    public var engine: CleanupEngine {
        switch self { case .qwen06: .qwen; case .qwen17: .qwen17; case .qwen4: .qwen4 }
    }
    public var name: String {
        switch self {
        case .qwen06: "Qwen3-0.6B-4bit"
        case .qwen17: "Qwen3-1.7B-4bit"
        case .qwen4: "Qwen3-4B-Instruct-2507-4bit"
        }
    }
    public var repository: String { "mlx-community/\(name)" }
    public var revision: String {
        switch self {
        case .qwen06: "73e3e38d981303bc594367cd910ea6eb48349da8"
        case .qwen17: "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
        case .qwen4: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
        }
    }
    public var downloadBytes: Int64 {
        switch self { case .qwen06: 351_384_491; case .qwen17: 984_014_117; case .qwen4: 2_279_000_000 }
    }
    public var weightBytes: Int64 {
        switch self { case .qwen06: 335_450_584; case .qwen17: 968_080_210; case .qwen4: 2_263_022_417 }
    }
    public var memoryEstimate: String {
        switch self { case .qwen06: "0.7–1.5 GB"; case .qwen17: "1.5–2.5 GB"; case .qwen4: "3–5 GB" }
    }
    public var processorID: String { "\(name.lowercased())-\(revision.prefix(7))-cleanup-v4" }
    public static func model(for engine: CleanupEngine) -> Self? { allCases.first { $0.engine == engine } }
}

public enum QwenModelAssets {
    public static let repository = QwenModel.qwen06.repository
    public static let revision = QwenModel.qwen06.revision
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nami/Models")
    }
    private static let files = ["config.json", "tokenizer_config.json", "tokenizer.json", "special_tokens_map.json",
                               "added_tokens.json", "vocab.json", "merges.txt", "model.safetensors.index.json", "README.md", "model.safetensors"]
    private static func files(for model: QwenModel) -> [String] {
        files + (model == .qwen4 ? ["chat_template.jinja", "generation_config.json"] : [])
    }
    public static var directory: URL { directory(for: .qwen06) }
    public static func directory(for model: QwenModel, root: URL = root) -> URL {
        root.appendingPathComponent("\(model.name)-\(model.revision.prefix(8))")
    }

    public static func isInstalled(_ model: QwenModel = .qwen06, at folder: URL? = nil) -> Bool {
        let folder = folder ?? directory(for: model)
        guard (try? String(contentsOf: folder.appendingPathComponent("revision.txt"), encoding: .utf8)) == model.revision else { return false }
        if model == .qwen4 {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json")),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let template = config["chat_template"] as? String, !template.isEmpty else { return false }
        }
        return files(for: model).allSatisfy {
            let size = (try? folder.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return $0 == "model.safetensors" ? Int64(size) == model.weightBytes : size > 0
        }
    }

    /// Only explicit setup downloads. Staging never counts as an installation.
    public static func download(_ model: QwenModel = .qwen06, to folder: URL? = nil,
                                fetch: @Sendable (URL) async throws -> (URL, URLResponse) = { try await URLSession.shared.download(from: $0) }) async throws {
        let folder = folder ?? directory(for: model)
        if isInstalled(model, at: folder) { return }
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: folder.path) else {
            throw CleanupFailure.unavailable("Incomplete model files found. Delete them in Models, then download again.")
        }
        let staging = parent.appendingPathComponent(".qwen-download-\(UUID())")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for file in files(for: model) {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file)")!
            let (temporary, response) = try await fetch(url)
            defer { try? manager.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw CleanupFailure.unavailable("\(model.engine.title) download failed. Try again.")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, file != "model.safetensors" || Int64(size) == model.weightBytes else {
                throw CleanupFailure.unavailable("The model download was incomplete. Try again.")
            }
            try manager.moveItem(at: temporary, to: staging.appendingPathComponent(file))
        }
        if model == .qwen4 {
            // This checkpoint ships its official template separately. The pinned
            // Swift tokenizer reads it from tokenizer_config.json; without this
            // bridge it silently falls back to unstructured text.
            let url = staging.appendingPathComponent("tokenizer_config.json")
            guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CleanupFailure.unavailable("The tokenizer configuration is invalid.")
            }
            config["chat_template"] = try String(contentsOf: staging.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
            try JSONSerialization.data(withJSONObject: config, options: .sortedKeys).write(to: url)
        }
        try Task.checkCancellation()
        try model.revision.write(to: staging.appendingPathComponent("revision.txt"), atomically: true, encoding: .utf8)
        if isInstalled(model, at: folder) { return }
        try manager.moveItem(at: staging, to: folder)
    }

    /// Remove only this model's known directory, never a parent or external link.
    /// Call after inference and loading stop.
    public static func remove(_ model: QwenModel, root: URL = root) throws {
        let folder = directory(for: model, root: root)
        guard folder.standardizedFileURL.resolvingSymlinksInPath() ==
                root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(folder.lastPathComponent) else {
            throw CleanupFailure.unavailable("This model folder is a link outside Nami's model storage. Manage it in Finder.")
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
