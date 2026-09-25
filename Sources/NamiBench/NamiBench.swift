import Darwin
import Foundation
import NamiAudio
import NamiCore
import NamiWhisperKit

struct CLIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Arguments {
    let command: String
    var options: [String: String] = [:]
    init(_ args: [String]) throws {
        command = args.first ?? "help"
        let allowed: [String: Set<String>] = [
            "help": [], "download": ["model", "directory", "config"],
            "transcribe": ["engine", "model-folder", "fake-text", "language", "audio", "config"],
            "record": ["engine", "model-folder", "fake-text", "language", "seconds", "save-audio", "config"],
            "benchmark": ["engine", "model-folder", "fake-text", "manifest", "output", "repetitions", "config"],
        ]
        guard let allowed = allowed[command] else { throw CLIError("Unknown command: \(command)") }
        var index = 1
        while index < args.count {
            let key = String(args[index].dropFirst(2))
            guard args[index].hasPrefix("--"), allowed.contains(key), index + 1 < args.count,
                  !args[index + 1].hasPrefix("--"), options[key] == nil else {
                throw CLIError("Invalid, repeated or missing option: \(args[index])")
            }
            options[key] = args[index + 1]
            index += 2
        }
    }
    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else { throw CLIError("Missing --\(key)") }
        return value
    }
}

struct RunResult: Codable {
    let sampleID: String
    let language: String
    let category: String
    let condition: String
    let repetition: Int
    let audioSeconds: Double
    let stopToFinalSeconds: Double
    let transcript: String
    let reference: String
    let wordErrorRate: Double
    // A human fills this during review; automated WER is only a proxy.
    var needsWordCorrections: Bool? = nil
}

struct Summary: Codable {
    let runCount: Int
    let medianSeconds: Double?
    let p95Seconds: Double?
    let normalizedExactMatchFraction: Double
    let meanWordErrorRate: Double
    init(_ rows: [RunResult]) {
        runCount = rows.count
        medianSeconds = EvaluationMetrics.median(rows.map(\.stopToFinalSeconds))
        p95Seconds = EvaluationMetrics.p95(rows.map(\.stopToFinalSeconds))
        normalizedExactMatchFraction = Double(rows.filter { $0.wordErrorRate == 0 }.count) / Double(max(rows.count, 1))
        meanWordErrorRate = rows.map(\.wordErrorRate).reduce(0, +) / Double(max(rows.count, 1))
    }
}

struct BenchmarkReport: Encodable {
    let schemaVersion = 1
    let createdAt = Date()
    let hardwareModel: String
    let chip: String
    let memoryBytes: UInt64
    let osVersion: String
    let engine: String
    let sdkVersion: String
    let modelFolder: String?
    let mode = "batch; audio appended before timer; model retained across warm runs"
    let coldPrepareSeconds: Double
    let firstDecodeSeconds: Double
    let warmupRunsExcluded = 1
    let peakResidentMemoryBytes: Int64
    let memoryDefinition = "getrusage process lifetime maximum RSS; includes loading and warmup"
    let qualityDecision = "Pending manual review of needsWordCorrections; automated exact matches do not establish the 90% gate."
    let overall: Summary
    let byLanguage: [String: Summary]
    let byCategory: [String: Summary]
    let byCondition: [String: Summary]
    let runs: [RunResult]
}

@main
@MainActor
struct NamiBench {
    static func main() async {
        do { try await run(Arguments(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: Arguments) async throws {
        if args.command == "help" {
            print("""
            Nami local recognition harness
              download [--model NAME] [--directory PATH]       Explicit network/model download
              transcribe --audio PATH [--model-folder PATH] [--language en]
              record [--model-folder PATH] [--seconds 10] [--save-audio PATH.wav]
              benchmark --manifest PATH --output PATH [--model-folder PATH] [--repetitions 3]
            Defaults: nami.json in the working directory; --config PATH selects another file.
            CLI options override config. Download saves its model folder to the selected config.
            transcribe/record/benchmark accept --engine fake [--fake-text TEXT] instead of a model.
            Audio stays in memory unless record --save-audio is given. Maximum duration: 60 seconds.
            Benchmark requires 20–30 verified references with 5–30-second audio files.
            See README.md for setup, measurement definitions and limitations.
            """)
            return
        }
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let configURL = ProjectConfiguration.resolvePath(args.options["config"] ?? "nami.json", relativeTo: workingDirectory)
        let project = try ProjectConfiguration.load(from: configURL, required: args.options["config"] != nil)
        if args.command == "download" {
            let root = args.options["directory"].map { ProjectConfiguration.resolvePath($0, relativeTo: workingDirectory) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nami/Models")
            print("Downloading model to \(root.path)…")
            let path = try await WhisperKitEngine.download(model: args.options["model"] ?? WhisperKitEngine.defaultModel, to: root)
            print("Model folder: \(path.path)")
            try ProjectConfiguration.saveModelFolder(path, to: configURL)
            print("Saved model folder to \(configURL.path)")
            return
        }
        var config = EngineConfiguration()
        guard let backend = EngineConfiguration.Backend(rawValue: args.options["engine"] ?? project.engine ?? "whisperkit") else {
            throw CLIError("Engine must be whisperkit or fake.")
        }
        config.backend = backend
        if let override = args.options["model-folder"] {
            config.modelFolder = ProjectConfiguration.resolvePath(override, relativeTo: workingDirectory).path
        } else if let folder = project.modelFolder {
            config.modelFolder = ProjectConfiguration.resolvePath(folder, relativeTo: configURL.deletingLastPathComponent()).path
        }
        let language = args.options["language"] ?? project.language ?? "en"
        config.fakeTranscript = args.options["fake-text"] ?? config.fakeTranscript
        let engine = try EngineFactory.make(config)
        if args.command == "benchmark" { try await benchmark(args, config: config, engine: engine); return }
        if args.command == "transcribe" {
            let audio = try AudioFile.read(URL(fileURLWithPath: args.required("audio")))
            var statistics = AudioStatistics()
            statistics.append(audio)
            printAudioStatistics(statistics, label: "Audio file")
            let start = ContinuousClock.now
            try await engine.prepare()
            print("Prepare: \(seconds(since: start)) s")
            let (text, latency) = try await transcribe(audio, language: language, engine: engine)
            print(text)
            print("Stop-to-final (batch): \(latency) s")
        } else {
            guard let duration = Double(args.options["seconds"] ?? "10"), duration.isFinite, duration >= 1, duration <= 60 else {
                throw CLIError("--seconds must be between 1 and 60.")
            }
            if let path = args.options["save-audio"], FileManager.default.fileExists(atPath: path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try await engine.prepare()
            try await record(seconds: duration, savePath: args.options["save-audio"], language: language, engine: engine)
        }
    }

    static func transcribe(_ samples: [Float], language: String, engine: any TranscriptionEngine) async throws -> (String, Double) {
        let id = UUID()
        try await engine.start(sessionID: id, language: language, onPartial: nil)
        do {
            for start in stride(from: 0, to: samples.count, by: 1600) {
                let chunk = AudioChunk(samples: Array(samples[start..<min(start + 1600, samples.count)]),
                                       timestamp: Double(start) / AudioChunk.sampleRate)
                try await engine.append(chunk, sessionID: id)
            }
            let stop = ContinuousClock.now
            let result = try await engine.finish(sessionID: id)
            return (result, seconds(since: stop))
        } catch { await engine.cancel(sessionID: id); throw error }
    }

    static func record(seconds duration: Double, savePath: String?, language: String, engine: any TranscriptionEngine) async throws {
        let capture = MicrophoneCapture(), id = UUID()
        try await engine.start(sessionID: id, language: language, onPartial: nil)
        defer { capture.stop() }
        do {
            let stream = try await capture.start()
            print("Microphone: \(capture.inputDescription)")
            print("Recording for \(duration) seconds. Speak now…")
            let stopTask = Task { @MainActor in
                try await Task.sleep(for: .seconds(duration))
                let stoppedAt = ContinuousClock.now
                capture.stop()
                return stoppedAt
            }
            defer { stopTask.cancel() }
            var saved: [Float] = []
            var statistics = AudioStatistics()
            for try await chunk in stream {
                try await engine.append(chunk, sessionID: id)
                statistics.append(chunk.samples)
                if savePath != nil { saved += chunk.samples }
            }
            let stop = try await stopTask.value
            printAudioStatistics(statistics, label: "Captured")
            if statistics.duration < duration * 0.9 {
                print("Warning: captured audio is shorter than the requested recording. Check the microphone connection.")
            }
            if statistics.rmsDBFS < -50 {
                print("Warning: audio is very quiet. Check the selected microphone and input level before trusting the transcript.")
            }
            // Preserve explicitly requested diagnostic audio even if inference fails.
            // Saving is part of the end-to-end stop-to-final time for these runs.
            if let savePath {
                try AudioFile.write(saved, to: URL(fileURLWithPath: savePath))
                print("Saved \(savePath)")
            }
            print("Transcribing…")
            let text = try await engine.finish(sessionID: id)
            let latency = seconds(since: stop)
            print(text)
            print("Stop-to-final: \(latency) s")
        } catch { await engine.cancel(sessionID: id); throw error }
    }

    static func printAudioStatistics(_ statistics: AudioStatistics, label: String) {
        print(String(format: "%@: %.2f s (%d samples at 16000 Hz); average %.1f dBFS, peak %.1f dBFS",
                     label, statistics.duration, statistics.sampleCount, statistics.rmsDBFS, statistics.peakDBFS))
    }

    static func benchmark(_ args: Arguments, config: EngineConfiguration, engine: any TranscriptionEngine) async throws {
        let manifest = URL(fileURLWithPath: try args.required("manifest"))
        let output = URL(fileURLWithPath: try args.required("output"))
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        guard let repetitions = Int(args.options["repetitions"] ?? "3"), (1...20).contains(repetitions) else {
            throw CLIError("--repetitions must be between 1 and 20.")
        }
        let samples = try JSONDecoder().decode([EvaluationSample].self, from: Data(contentsOf: manifest))
        guard (20...30).contains(samples.count) else { throw EvaluationError.invalidCount }
        guard Set(samples.map(\.id)).count == samples.count else { throw EvaluationError.duplicateIDs }
        for sample in samples { try sample.validate() }
        // Preflight every file before expensive preparation; disk I/O is excluded from latency.
        let audio = try samples.map { sample in
            let data = try AudioFile.read(URL(fileURLWithPath: sample.audio, relativeTo: manifest.deletingLastPathComponent()))
            guard (5...30).contains(Double(data.count) / AudioChunk.sampleRate) else {
                throw CLIError("Sample \(sample.id) must be 5–30 seconds.")
            }
            return data
        }
        let coldStart = ContinuousClock.now
        try await engine.prepare()
        let cold = seconds(since: coldStart)
        let (_, firstDecode) = try await transcribe(audio[0], language: samples[0].language, engine: engine)
        var rows: [RunResult] = []
        for repetition in 1...repetitions {
            for (index, sample) in samples.enumerated() {
                let (text, latency) = try await transcribe(audio[index], language: sample.language, engine: engine)
                rows.append(RunResult(sampleID: sample.id, language: sample.language, category: sample.category,
                    condition: sample.condition, repetition: repetition,
                    audioSeconds: Double(audio[index].count) / AudioChunk.sampleRate,
                    stopToFinalSeconds: latency, transcript: text, reference: sample.reference,
                    wordErrorRate: EvaluationMetrics.wordErrorRate(reference: sample.reference, hypothesis: text)))
                print("\(sample.id) [\(repetition)/\(repetitions)]: \(String(format: "%.3f", latency)) s")
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report = BenchmarkReport(hardwareModel: sysctlString("hw.model"), chip: sysctlString("machdep.cpu.brand_string"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            engine: config.backend.rawValue, sdkVersion: WhisperKitEngine.sdkVersion, modelFolder: config.modelFolder,
            coldPrepareSeconds: cold, firstDecodeSeconds: firstDecode, peakResidentMemoryBytes: Int64(usage.ru_maxrss),
            overall: Summary(rows), byLanguage: Dictionary(grouping: rows, by: \.language).mapValues(Summary.init),
            byCategory: Dictionary(grouping: rows, by: \.category).mapValues(Summary.init),
            byCondition: Dictionary(grouping: rows, by: \.condition).mapValues(Summary.init), runs: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .withoutOverwriting)
        print("Report: \(output.path). Manual quality review required; fake runs are plumbing checks only.")
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return "unknown" }
        var data = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &data, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: data.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
