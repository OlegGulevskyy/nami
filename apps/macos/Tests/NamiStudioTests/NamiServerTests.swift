import Foundation
import Testing
import NamiCore
@testable import NamiStudio

/// Answers like apps/server; never touches the network.
private func fakeServer(status: Int = 200, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> HTTPTransport {
    { request in
        onRequest(request)
        let body: String
        switch (status, request.url?.path) {
        case (200, "/v1/models"):
            body = #"{"object":"list","data":[{"id":"parakeet","kind":"transcription","loaded":true},{"id":"qwen","kind":"chat","loaded":true}]}"#
        case (200, "/v1/audio/transcriptions"): body = #"{"text":" hello from the server "}"#
        case (200, "/v1/chat/completions"):
            body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello from the server."},"finish_reason":"stop"}]}"#
        default: body = #"{"detail":"Model not loaded."}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    var all: [URLRequest] { lock.withLock { stored } }
}

@Test func serverAddressesAreNormalized() throws {
    #expect(NamiServerEndpoint(address: " 192.168.1.24:8765/ ")?.url.absoluteString == "http://192.168.1.24:8765")
    #expect(NamiServerEndpoint(address: "https://nami.local/inference")?.url.absoluteString == "https://nami.local/inference")
    #expect(NamiServerEndpoint(address: "http://192.168.1.24:8765")?.displayName == "192.168.1.24:8765")
    for invalid in ["", "   ", "http://", "ftp://host", "http://host?x=1"] {
        #expect(NamiServerEndpoint(address: invalid) == nil, "\(invalid)")
    }
    let request = try #require(NamiServerEndpoint(address: "host:8765")).request("v1/models", timeout: 5)
    #expect(request.url?.absoluteString == "http://host:8765/v1/models")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test @MainActor func serverTranscriptionUploadsTheRecordingAsWAV() async throws {
    let requests = Requests()
    let endpoint = try #require(NamiServerEndpoint(address: "host:8765"))
    let engine = ServerTranscriptionEngine(client: NamiServerClient(endpoint: endpoint, transport: fakeServer(onRequest: requests.append)))
    try await engine.prepare()
    let id = UUID()
    try await engine.startLive(sessionID: id, language: "en", vocabulary: "", onPartial: nil)
    try await engine.append(AudioChunk(samples: Array(repeating: 0.1, count: 1600), timestamp: 0), sessionID: id)
    try await engine.append(AudioChunk(samples: Array(repeating: 0.1, count: 1600), timestamp: 0.1), sessionID: id)
    #expect(try await engine.finish(sessionID: id) == "hello from the server")

    let upload = try #require(requests.all.last)
    #expect(upload.url?.path == "/v1/audio/transcriptions")
    #expect(upload.httpMethod == "POST")
    let body = try #require(upload.httpBody)
    #expect(body.range(of: Data("RIFF".utf8)) != nil)
    #expect(body.count > 3200 * 2)
    #expect(String(decoding: body.prefix(400), as: UTF8.self).contains("name=\"language\"\r\n\r\nen"))
    // A finished session never returns a second result.
    await #expect(throws: EngineError.self) { try await engine.finish(sessionID: id) }
}

@Test @MainActor func unreachableServerFailsPreparation() async throws {
    let engine = ServerTranscriptionEngine(client: NamiServerClient(endpoint: NamiServerEndpoint(address: "host:8765")!,
        transport: { _ in throw URLError(.cannotConnectToHost) }))
    do {
        try await engine.prepare()
        Issue.record("Preparation should fail")
    } catch {
        #expect(error.localizedDescription.contains("Cannot reach the Nami server at host:8765"))
    }
    await #expect(throws: EngineError.notPrepared) {
        try await engine.start(sessionID: UUID(), language: nil, vocabulary: "", onPartial: nil)
    }
}

@Test func serverTranscriptionShowsTheServersOwnFailure() async throws {
    let client = NamiServerClient(endpoint: NamiServerEndpoint(address: "host")!, transport: fakeServer(status: 503))
    do {
        _ = try await client.transcribe([0.1], language: nil)
        Issue.record("Transcription should fail")
    } catch {
        #expect(error.localizedDescription == "The Nami server returned HTTP 503: Model not loaded.")
    }
}

@Test func serverCleanupSendsTheQwenPrompt() async throws {
    let requests = Requests()
    let connection = NamiServerConnection()
    connection.endpoint = NamiServerEndpoint(address: "host:8765")
    let runner = CleanupRunner(processor: ServerTextProcessor(connection: connection, transport: fakeServer(onRequest: requests.append)))
    let result = try await runner.run(CleanupRequest(rawText: "um hello from the server"), timeout: .seconds(5))
    #expect(result.outcome == .cleaned)
    #expect(result.text == "Hello from the server.")
    #expect(CleanupEngine.title(for: result.provider) == "Nami server")

    let request = try #require(requests.all.last)
    #expect(request.url?.path == "/v1/chat/completions")
    let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages.map { $0["role"] } == ["system", "user"])
    #expect(messages[0]["content"] == PromptConfiguration()[.qwenSystem])
    #expect(messages[1]["content"]?.contains("um hello from the server") == true)
    #expect(json["stream"] as? Bool == false)
    #expect(json["max_tokens"] as? Int == PromptConfiguration().qwenGeneration.clamped.maxOutputTokens)
}

@Test func serverCleanupWithoutAnAddressKeepsTheOriginal() async throws {
    let runner = CleanupRunner(processor: ServerTextProcessor(connection: NamiServerConnection(), transport: fakeServer()))
    let result = try await runner.run(CleanupRequest(rawText: "um hello"), timeout: .seconds(5))
    #expect(result.outcome == .unavailable)
    #expect(result.text == "um hello")
}

@Test func legacyServerAddressIsRetainedWhileDictationMigratesLocally() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("nami-server-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    var settings = try StudioSettings.load(project: project)
    #expect(settings.serverURL == "")
    settings.serverURL = "http://192.168.1.24:8765"
    settings.engine = "server"
    settings.cleanupEngine = .server
    try settings.save(project: project)
    let loaded = try StudioSettings.load(project: project)
    #expect(loaded.serverURL == "http://192.168.1.24:8765")
    #expect(loaded.engine == "fast")
    #expect(loaded.cleanupEngine == .automatic)
}
