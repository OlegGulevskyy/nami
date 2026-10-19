import Foundation
import Testing
import NamiCore
@testable import NamiStudio

private func config(_ provider: DictationProvider, region: DictationCloudRegion = .eu, key: String = "test-secret") -> DictationCloudConfiguration {
    .init(provider: provider, model: provider.models[0].id, region: region, apiKey: key)
}

private final class CloudRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func add(_ request: URLRequest) { lock.withLock { values.append(request) } }
    var all: [URLRequest] { lock.withLock { values } }
}

@MainActor private final class ScriptedSocket: DictationSocket {
    var sent: [URLSessionWebSocketTask.Message] = []
    var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var queue: [URLSessionWebSocketTask.Message] = []
    var closed = false
    var finishEvent: String? = #"{"tokens":[{"text":" Bonjour.","is_final":true}],"finished":true}"#
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !closed else { throw URLError(.cancelled) }
        sent.append(message)
        if case .string("") = message, let finishEvent { emit(finishEvent) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queue.isEmpty { return queue.removeFirst() }
        guard !closed else { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func emit(_ json: String) {
        if let pending { self.pending = nil; pending.resume(returning: .string(json)) }
        else { queue.append(.string(json)) }
    }
    func close() {
        closed = true
        let waiter = pending; pending = nil
        waiter?.resume(throwing: URLError(.cancelled))
    }
}

@Suite(.serialized) @MainActor struct DictationCloudTests {
    @Test func legacySettingsRemainLocalAndCloudSelectionRoundTripsWithoutSecrets() throws {
        let old = try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"engine":"whisperkit","language":"fr"}"#.utf8))
        #expect(old.engine == "whisperkit")
        #expect(old.cloudModel(for: .groq) == "whisper-large-v3-turbo")
        var settings = old
        settings.engine = DictationProvider.soniox.engineID
        settings.cloudModels["groq"] = "whisper-large-v3"
        settings.cloudRegions["soniox"] = .us
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(StudioSettings.self, from: encoded) == settings)
        #expect(!String(decoding: encoded, as: UTF8.self).localizedCaseInsensitiveContains("apikey"))
    }

    @Test func providerCatalogRejectsMissingKeysAndWrongModelBeforeNetworking() throws {
        for provider in DictationProvider.allCases {
            #expect(throws: DictationCloudError.self) { try config(provider, key: " ").validate() }
            #expect(throws: DictationCloudError.self) { try config(provider, key: "key\ninjected").validate() }
            #expect(throws: DictationCloudError.self) {
                try DictationCloudConfiguration(provider: provider, model: "wrong-model", region: .eu, apiKey: "key").validate()
            }
            try config(provider).validate()
        }
    }

    @Test func groqUsesMultipartBearerFrenchAndWAV() throws {
        let client = DictationFileClient(configuration: config(.groq))
        let request = try client.request(samples: Array(repeating: 0.1, count: 1600), language: "fr", vocabulary: "Nami, Oleg")
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        #expect(body.contains("name=\"language\"\r\n\r\nfr"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nNami, Oleg"))
        #expect(body.contains("filename=\"recording.wav\""))
        #expect(request.httpBody?.range(of: Data("RIFF".utf8)) != nil)
        #expect(!body.contains("test-secret"))
        let auto = try client.request(samples: [0.1], language: nil, vocabulary: "")
        #expect(!String(decoding: auto.httpBody!, as: UTF8.self).contains("name=\"language\""))
    }

    @Test func mistralPinsTranscriptionModelAndRepeatsVocabularyFields() throws {
        let request = try DictationFileClient(configuration: config(.mistral))
            .request(samples: [0.1, -0.1], language: "fr", vocabulary: "Nami, Château\nOleg")
        #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/audio/transcriptions")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("voxtral-mini-2602"))
        #expect(body.components(separatedBy: "name=\"context_bias\"").count == 4)
        #expect(body.contains("\r\n\r\nChâteau\r\n"))
        #expect(!body.contains("name=\"prompt\""))
    }

    @Test func assemblyUsesRawAuthModelHeaderAudioPartAndBilingualJSON() throws {
        let request = try DictationFileClient(configuration: config(.assemblyai))
            .request(samples: Array(repeating: 0.1, count: 1600), language: nil, vocabulary: "Nami, Oleg")
        #expect(request.url?.absoluteString == "https://sync.eu.assemblyai.com/v1/transcribe")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "test-secret")
        #expect(request.value(forHTTPHeaderField: "X-AAI-Model") == "universal-3-5-pro")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"audio\""))
        #expect(body.contains("Content-Type: application/json\r\n\r\n"))
        #expect(body.contains(#""language_codes":["en","fr"]"#))
        #expect(body.contains(#""keyterms_prompt":["Nami","Oleg"]"#))
        #expect(!body.contains("speech_models"))
        let french = try DictationFileClient(configuration: config(.assemblyai, region: .us))
            .request(samples: Array(repeating: 0, count: 1280), language: "fr", vocabulary: "")
        #expect(french.url?.host() == "sync.us.assemblyai.com")
        #expect(String(decoding: french.httpBody!, as: UTF8.self).contains(#""language_codes":["fr"]"#))
    }

    @Test func assemblyRejectsUnsupportedClipLengthsBeforeUpload() throws {
        let client = DictationFileClient(configuration: config(.assemblyai))
        for count in [1279, 120 * 16000 + 1] {
            #expect(throws: DictationCloudError.self) {
                try client.request(samples: Array(repeating: 0.1, count: count), language: "en", vocabulary: "")
            }
        }
        _ = try client.request(samples: Array(repeating: 0, count: 120 * 16000), language: "en", vocabulary: "")
    }

    @Test func fileEnginesOnlyUploadOnFinishAndReturnOneResult() async throws {
        for provider in [DictationProvider.groq, .assemblyai, .mistral] {
            let requests = CloudRequests()
            let client = DictationFileClient(configuration: config(provider), transport: { request in
                requests.add(request)
                return (Data(#"{"text":" Bonjour à tous. "}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let engine = DictationFileEngine(client: client)
            try await engine.prepare()
            #expect(requests.all.isEmpty)
            let id = UUID()
            try await engine.startLive(sessionID: id, language: "fr", vocabulary: "", onPartial: nil)
            try await engine.append(AudioChunk(samples: Array(repeating: 0.1, count: 1600), timestamp: 0), sessionID: id)
            #expect(requests.all.filter { $0.httpMethod == "POST" }.isEmpty)
            #expect(try await engine.finish(sessionID: id) == "Bonjour à tous.")
            #expect(requests.all.filter { $0.httpMethod == "POST" }.count == 1)
            await #expect(throws: EngineError.self) { try await engine.finish(sessionID: id) }
        }
    }

    @Test func httpErrorsDoNotExposeProviderBodiesAndAreNeverRetried() async throws {
        for status in [401, 403, 429, 500] {
            let requests = CloudRequests()
            let client = DictationFileClient(configuration: config(.groq), transport: { request in
                requests.add(request)
                return (Data(#"{"error":{"message":"echoed test-secret and private transcript"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            let request = try client.request(samples: [0.1], language: nil, vocabulary: "")
            do { _ = try await client.send(request); Issue.record("Expected HTTP failure") }
            catch {
                #expect(error.localizedDescription.contains("HTTP \(status)"))
                #expect(!error.localizedDescription.contains("test-secret"))
                #expect(!error.localizedDescription.contains("private transcript"))
            }
            #expect(requests.all.count == 1)
        }
    }

    @Test func malformedAndNetworkErrorsAreSafe() async throws {
        let client = DictationFileClient(configuration: config(.mistral), transport: { request in
            (Data(#"{"unexpected":"private text"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: DictationCloudError.self) {
            try await client.send(client.request(samples: [0.1], language: nil, vocabulary: ""))
        }
        let error = URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "test-secret"])
        #expect(!DictationCloudError.safe(error, provider: .groq).localizedDescription.contains("test-secret"))
    }

    @Test func cancellingFileRequestRejectsLateResultAndNextRecordingWorks() async throws {
        let gate = CloudResponseGate()
        let client = DictationFileClient(configuration: config(.groq), transport: { request in
            await gate.wait()
            return (Data(#"{"text":"late result"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let engine = DictationFileEngine(client: client)
        try await engine.prepare()
        let first = UUID()
        try await engine.start(sessionID: first, language: nil, vocabulary: "", onPartial: nil)
        try await engine.append(AudioChunk(samples: [0.1], timestamp: 0), sessionID: first)
        let finishing = Task { try await engine.finish(sessionID: first) }
        while !(await gate.started) { await Task.yield() }
        await engine.cancel(sessionID: first)
        let next = UUID()
        try await engine.start(sessionID: next, language: "fr", vocabulary: "", onPartial: nil)
        await gate.release()
        await #expect(throws: EngineError.cancelled) { try await finishing.value }
        try await engine.append(AudioChunk(samples: [0.2], timestamp: 0), sessionID: next)
        #expect(try await engine.finish(sessionID: next) == "late result")
    }

    @Test func sonioxReplacesPartialSuffixAndExcludesControlTokens() throws {
        var text = SonioxTranscript()
        try text.receive(Data(#"{"tokens":[{"text":"Bon","is_final":false}]}"#.utf8))
        #expect(text.preview == "Bon")
        try text.receive(Data(#"{"tokens":[{"text":"Bonjour","is_final":true},{"text":" le","is_final":false}]}"#.utf8))
        #expect(text.preview == "Bonjour le")
        try text.receive(Data(#"{"tokens":[{"text":" monde.","is_final":true},{"text":"<end>","is_final":true},{"text":"<fin>","is_final":true}],"finished":true}"#.utf8))
        #expect(text.final == "Bonjour monde.")
        #expect(text.finished)
    }

    @Test func sonioxStreamsBeforeStopAndFlushesUsingEmptyText() async throws {
        let socket = ScriptedSocket()
        var upgrade: URLRequest?
        let engine = SonioxDictationEngine(configuration: config(.soniox), makeSocket: { upgrade = $0; return socket })
        try await engine.prepare()
        #expect(upgrade == nil)
        let id = UUID()
        try await engine.startLive(sessionID: id, language: nil, vocabulary: "Nami, Château", onPartial: nil)
        #expect(upgrade?.url?.host() == "stt-rt.eu.soniox.com")
        #expect(upgrade?.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        guard case .string(let json) = socket.sent[0] else { Issue.record("Expected JSON config"); return }
        let data = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(data["model"] as? String == "stt-rt-v5")
        #expect(data["audio_format"] as? String == "pcm_s16le")
        #expect(data["language_hints"] as? [String] == ["en", "fr"])
        #expect(data["api_key"] == nil)
        try await engine.append(AudioChunk(samples: [-1, 0, 1], timestamp: 0), sessionID: id)
        guard case .data(let bytes) = socket.sent[1] else { Issue.record("Expected PCM audio before Stop"); return }
        #expect(bytes == Data([1, 128, 0, 0, 255, 127]))
        #expect(try await engine.finish(sessionID: id) == "Bonjour.")
        guard case .string("") = socket.sent.last else { Issue.record("Expected empty text terminator"); return }
        #expect(socket.closed)
        await #expect(throws: EngineError.self) { try await engine.finish(sessionID: id) }
    }

    @Test func sonioxCancellationClosesSocketAndAllowsFreshSession() async throws {
        var sockets: [ScriptedSocket] = []
        let engine = SonioxDictationEngine(configuration: config(.soniox), makeSocket: { _ in
            let socket = ScriptedSocket(); sockets.append(socket); return socket
        })
        try await engine.prepare()
        let first = UUID()
        try await engine.start(sessionID: first, language: "fr", vocabulary: "", onPartial: nil)
        await engine.cancel(sessionID: first)
        #expect(sockets[0].closed)
        let next = UUID()
        try await engine.start(sessionID: next, language: "en", vocabulary: "", onPartial: nil)
        // A late cancellation from the first session must not close the second socket.
        await engine.cancel(sessionID: first)
        #expect(!sockets[1].closed)
        try await engine.append(AudioChunk(samples: [0.1], timestamp: 0), sessionID: next)
        #expect(try await engine.finish(sessionID: next) == "Bonjour.")
    }

    @Test func sonioxMissingFinishedEventTimesOutAndClosesConnection() async throws {
        let socket = ScriptedSocket(); socket.finishEvent = nil
        let engine = SonioxDictationEngine(configuration: config(.soniox), timeout: .milliseconds(25), makeSocket: { _ in socket })
        try await engine.prepare()
        let id = UUID()
        try await engine.start(sessionID: id, language: "fr", vocabulary: "", onPartial: nil)
        try await engine.append(AudioChunk(samples: [0.1], timestamp: 0), sessionID: id)
        do { _ = try await engine.finish(sessionID: id); Issue.record("Expected timeout") }
        catch { #expect(error.localizedDescription.contains("timed out")) }
        #expect(socket.closed)
    }

    @Test func sonioxProviderErrorCannotLeakItsMessage() async throws {
        let socket = ScriptedSocket()
        socket.finishEvent = #"{"error_code":401,"error_message":"test-secret private transcript"}"#
        let engine = SonioxDictationEngine(configuration: config(.soniox), makeSocket: { _ in socket })
        try await engine.prepare()
        let id = UUID()
        try await engine.start(sessionID: id, language: nil, vocabulary: "", onPartial: nil)
        try await engine.append(AudioChunk(samples: [0.1], timestamp: 0), sessionID: id)
        do { _ = try await engine.finish(sessionID: id); Issue.record("Expected auth failure") }
        catch {
            #expect(error.localizedDescription.contains("401"))
            #expect(!error.localizedDescription.contains("test-secret"))
        }
        #expect(socket.closed)
    }

    @Test func sessionKeyStorageAndCloudModelLabelDoNotRequireLocalModels() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        var keys: [DictationProvider: String] = [:]
        let store = DictationAPIKeyStore(load: { keys[$0] }, save: { keys[$0] = $1 })
        let session = StudioSession(project: project, historyDirectory: project.appendingPathComponent("History"),
            pastePreparer: { { _, _ in .targetUnavailable } }, dictationKeyStore: store,
            captureBuilder: StudioSession.systemCapture, clipboardWriter: { _ in false })
        try session.saveDictationKey("  private-key  ", provider: .groq)
        #expect(keys[.groq] == "private-key")
        #expect(try session.hasDictationKey(.groq))
        session.settings.engine = "cloud-groq"
        #expect(session.modelName == "Groq · whisper-large-v3-turbo")
        session.settings.cloudModels["groq"] = "whisper-large-v3"
        #expect(session.modelName == "Groq · whisper-large-v3")
        let persisted = try String(contentsOf: project.appendingPathComponent("nami.json"), encoding: .utf8)
        #expect(!persisted.contains("private-key"))
        try session.saveDictationKey("", provider: .groq)
        #expect(try !session.hasDictationKey(.groq))
    }
}

private actor CloudResponseGate {
    var started = false
    var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
