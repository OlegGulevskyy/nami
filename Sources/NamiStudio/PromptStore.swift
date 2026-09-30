import Darwin
import Foundation
import NamiCore
import Observation

@MainActor @Observable
final class PromptStore {
    private struct Preferences: Codable {
        var version = 1
        var cleanup = PromptConfiguration()
        var playgroundVocabulary = ""
    }
    var draftConfiguration = PromptConfiguration()
    var draftPlaygroundVocabulary = ""
    var draftLiveVocabulary: String?
    /// Draft of the live cleanup deadline, which is stored in Studio settings.
    var draftCleanupTimeout: Double?
    private(set) var configuration = PromptConfiguration()
    private(set) var playgroundVocabulary = ""
    private(set) var records: [ModelPromptRecord] = []
    private(set) var errorMessage: String?
    private(set) var loadFailed = false
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var loadedPreferences: Data?
    private var preferencesURL: URL { directory.appendingPathComponent("prompts.json") }
    private var historyURL: URL { directory.appendingPathComponent("prompt-history.json") }

    init(directory: URL) {
        self.directory = directory
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                let data = try Data(contentsOf: preferencesURL)
                let preferences = try JSONDecoder().decode(Preferences.self, from: data)
                guard preferences.version == 1 else { throw StudioError.message("Unsupported prompt settings version.") }
                configuration = preferences.cleanup
                playgroundVocabulary = preferences.playgroundVocabulary
                loadedPreferences = data
            }
        } catch {
            loadFailed = true
            errorMessage = "Could not load prompts. Existing file kept: \(error.localizedDescription)"
        }
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                records = Array(try JSONDecoder().decode([ModelPromptRecord].self,
                    from: Data(contentsOf: historyURL)).prefix(200))
            }
        } catch { errorMessage = "Could not load prompt history: \(error.localizedDescription)" }
        draftConfiguration = configuration
        draftPlaygroundVocabulary = playgroundVocabulary
    }

    @discardableResult
    func save(configuration: PromptConfiguration, playgroundVocabulary: String) -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent(".prompts.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw StudioError.message("Cannot lock prompt settings.") }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StudioError.message("Another process is saving prompts. Try again.") }
            defer { flock(descriptor, LOCK_UN) }
            let current = try FileManager.default.fileExists(atPath: preferencesURL.path) ? Data(contentsOf: preferencesURL) : nil
            guard current == loadedPreferences else { throw StudioError.message("Prompts changed in another process. Reopen Nami before saving.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Preferences(cleanup: configuration, playgroundVocabulary: playgroundVocabulary))
            try data.write(to: preferencesURL, options: .atomic)
            loadedPreferences = data
            self.configuration = configuration
            self.playgroundVocabulary = playgroundVocabulary
            errorMessage = nil
            return true
        } catch { errorMessage = "Could not save prompts: \(error.localizedDescription)"; return false }
    }

    func observer(source: String) -> ModelPromptObserver {
        { [weak self] record in
            var record = record
            record.source = source
            await self?.record(record)
        }
    }

    func record(_ record: ModelPromptRecord) {
        records.insert(record, at: 0)
        records = Array(records.prefix(200))
        // Bound local storage without truncating any individual request.
        while records.count > 1 && records.reduce(0, { $0 + $1.messages.reduce(0) { $0 + $1.content.utf8.count } }) > 8_000_000 {
            records.removeLast()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
        } catch { errorMessage = "Prompt history is available this session but could not be saved: \(error.localizedDescription)" }
    }
}
