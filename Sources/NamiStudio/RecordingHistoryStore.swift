import Foundation

/// One independently replaceable metadata file and WAV per recording. There is
/// deliberately no retention limit or cleanup tied to app versions/builds.
@MainActor
struct RecordingHistoryStore {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nami/History", isDirectory: true)
    }

    let directory: URL

    private struct Record: Codable {
        let version: Int
        let run: RecordingRun
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    func save(_ run: RecordingRun) throws -> RecordingRun {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = run
        let audioURL = directory.appendingPathComponent(run.id.uuidString + ".wav")
        // Audio is immutable once capture ends. Finishing transcription only
        // replaces this recording's metadata, never the rest of the history.
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            try StudioSession.wavData(run.samples).write(to: audioURL, options: .atomic)
        }
        stored.savedURL = audioURL
        stored.samples = []
        try encoder.encode(Record(version: 1, run: stored))
            .write(to: directory.appendingPathComponent(run.id.uuidString + ".json"), options: .atomic)
        return stored
    }

    func load() throws -> (runs: [RecordingRun], warnings: [String]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        var runs: [RecordingRun] = []
        var warnings: [String] = []
        for file in files where file.pathExtension == "json" {
            do {
                let record = try decoder.decode(Record.self, from: Data(contentsOf: file))
                guard record.version == 1, file.deletingPathExtension().lastPathComponent == record.run.id.uuidString else {
                    throw StudioError.message("Unsupported recording metadata.")
                }
                var run = record.run
                // Resolve within the store so moving/restoring the history folder works.
                run.savedURL = directory.appendingPathComponent(run.id.uuidString + ".wav")
                if !FileManager.default.fileExists(atPath: run.savedURL!.path) {
                    warnings.append("Audio is missing for the recording from \(run.date.formatted()).")
                }
                runs.append(run)
            } catch {
                warnings.append("Could not load \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (runs.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }, warnings)
    }
}
