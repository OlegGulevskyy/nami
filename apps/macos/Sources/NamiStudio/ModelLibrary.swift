import Foundation
import NamiWhisperKit
import Observation

struct TranscriptionModel: Identifiable, Equatable {
    var id: String { folder.path }
    let name: String
    let folder: URL
    let installed: Bool
    let hasFiles: Bool
    let managed: Bool
    let bytes: Int64
}

enum ModelFiles {
    static func isWhisperVariant(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".") && name.localizedCaseInsensitiveContains("whisper")
    }
    static func size(at folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                         options: [.skipsHiddenFiles]) else { return 0 }
        return files.reduce(Int64(0)) { total, item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
    static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
    static func whisperInstalled(at folder: URL) -> Bool {
        ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin",
         "MelSpectrogram.mlmodelc/model.mil", "tokenizer.json", "tokenizer_config.json"].allSatisfy {
            ((try? folder.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
    }
}

/// Inventory of model files, independent of which model is selected for a run.
@MainActor @Observable
final class ModelLibrary {
    let roots: [URL]
    private(set) var transcription: [TranscriptionModel] = []
    init(roots: [URL]) { self.roots = roots }

    func refresh(knownFolders: [String], catalog: [String] = []) {
        var folders = Set(knownFolders.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for root in roots {
            let repository = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            let children = (try? FileManager.default.contentsOfDirectory(at: repository, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            folders.formUnion(children.filter { ModelFiles.isWhisperVariant($0.lastPathComponent) }.map { $0.standardizedFileURL.path })
        }
        let names = Set(folders.map { URL(fileURLWithPath: $0).lastPathComponent })
        for name in Set(catalog + [WhisperKitEngine.defaultModel]) where !names.contains(name) {
            // Catalog entries are model identifiers, never arbitrary paths.
            guard ModelFiles.isWhisperVariant(name), let root = roots.first else { continue }
            folders.insert(root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)").standardizedFileURL.path)
        }
        transcription = folders.map { URL(fileURLWithPath: $0) }.map {
            TranscriptionModel(name: $0.lastPathComponent, folder: $0, installed: ModelFiles.whisperInstalled(at: $0),
                hasFiles: FileManager.default.fileExists(atPath: $0.path), managed: isManaged($0), bytes: ModelFiles.size(at: $0))
        }.sorted { a, b in
            if a.installed != b.installed { return a.installed }
            return a.name == b.name ? a.id < b.id : a.name < b.name
        }
    }

    func isManaged(_ folder: URL) -> Bool {
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard ModelFiles.isWhisperVariant(canonical.lastPathComponent) else { return false }
        return roots.contains { root in
            let repository = root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            return canonical.deletingLastPathComponent().path == repository.path &&
                folder.standardizedFileURL.path == root.standardizedFileURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(folder.lastPathComponent)").path
        }
    }

    func installRoot(for model: TranscriptionModel) -> URL? {
        roots.first { $0.standardizedFileURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.name)").path == model.folder.standardizedFileURL.path }
    }

    func delete(_ model: TranscriptionModel) throws {
        // Revalidate at the action boundary, including after a user confirms.
        guard isManaged(model.folder) else {
            throw StudioError.message("This folder is managed outside Nami. Open it in Finder to manage its files.")
        }
        if FileManager.default.fileExists(atPath: model.folder.path) {
            try FileManager.default.removeItem(at: model.folder)
        }
    }
}
