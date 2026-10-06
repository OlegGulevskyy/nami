import Foundation
import NamiCore
import os

/// A Nami server (apps/server) on the local network. It runs the same speech and
/// cleanup models as this app, so this Mac does not need to download them.
struct NamiServerEndpoint: Sendable, Equatable {
    let url: URL

    /// Accepts an address with or without a scheme, such as `192.168.1.24:8765`.
    init?(address: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false, components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        self.url = url
    }

    var displayName: String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.timeoutInterval = timeout
        return request
    }
}

/// The server address shared by dictation and cleanup. The session updates it as settings change.
final class NamiServerConnection: Sendable {
    private let state = OSAllocatedUnfairLock<NamiServerEndpoint?>(initialState: nil)
    var endpoint: NamiServerEndpoint? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Requests follow the server's OpenAI-shaped API.
struct NamiServerClient: Sendable {
    struct Model: Decodable, Sendable {
        let id: String
        let kind: String?
        let loaded: Bool?
    }

    let endpoint: NamiServerEndpoint
    var transport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    func models() async throws -> [Model] {
        struct List: Decodable { let data: [Model] }
        return try decode(List.self, from: await send(endpoint.request("v1/models", timeout: 5))).data
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let boundary = "Nami-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        var fields = ["response_format": "json"]
        if let language { fields["language"] = language }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        // 16 kHz WAV, which the server decodes without ffmpeg.
        body.append(StudioSession.wavData(samples))
        append("\r\n--\(boundary)--\r\n")
        // Requests queue on the server's GPU, so allow long recordings time to finish.
        var request = endpoint.request("v1/audio/transcriptions", timeout: 60 + Double(samples.count) / AudioChunk.sampleRate)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        struct Transcript: Decodable { let text: String }
        return try decode(Transcript.self, from: await send(request)).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func complete(_ messages: [ModelPromptMessage], maxTokens: Int, temperature: Double) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct Body: Encodable {
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
            let stream = false
        }
        struct Completion: Decodable {
            struct Choice: Decodable { let message: Message }
            let choices: [Choice]
        }
        // CleanupRunner enforces the user's deadline; this only bounds a stalled connection.
        var request = endpoint.request("v1/chat/completions", timeout: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(messages: messages.map { Message(role: $0.role, content: $0.content) },
                                                         max_tokens: maxTokens, temperature: temperature))
        guard let text = try decode(Completion.self, from: await send(request)).choices.first?.message.content else {
            throw StudioError.message("The Nami server returned no cleanup text.")
        }
        return text
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError {
            throw StudioError.message("Cannot reach the Nami server at \(endpoint.displayName): \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw StudioError.message("Invalid response from the Nami server.") }
        guard (200..<300).contains(http.statusCode) else {
            // The server explains its own failures, such as a model that could not load.
            struct Failure: Decodable { let detail: String }
            let detail = (try? JSONDecoder().decode(Failure.self, from: data))?.detail
            throw StudioError.message("The Nami server returned HTTP \(http.statusCode)" + (detail.map { ": \($0)" } ?? "."))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw StudioError.message("The Nami server sent a response Nami cannot read.") }
    }
}

/// Batch transcription on the server: audio is sent once the recording finishes.
@MainActor
final class ServerTranscriptionEngine: TranscriptionEngine {
    static let provider = "Nami server"
    let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: true)
    private let client: NamiServerClient
    private var observer: ModelPromptObserver?
    private var prepared = false
    private var buffer = AudioSessionBuffer()
    private var language: String?

    init(client: NamiServerClient) { self.client = client }

    func setPromptObserver(_ observer: ModelPromptObserver?) async { self.observer = observer }

    func prepare() async throws {
        guard !prepared else { return }
        let models: [NamiServerClient.Model]
        do { models = try await client.models() }
        catch is CancellationError { throw CancellationError() }
        catch { throw EngineError.modelUnavailable(error.localizedDescription) }
        guard models.contains(where: { $0.kind == "transcription" }) else {
            throw EngineError.modelUnavailable("The Nami server at \(client.endpoint.displayName) has no transcription model.")
        }
        prepared = true
    }

    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        try buffer.start(sessionID)
        self.language = language
    }

    func append(_ chunk: AudioChunk, sessionID: UUID) async throws {
        try buffer.append(chunk, sessionID: sessionID)
    }

    func finish(sessionID: UUID) async throws -> String {
        let audio = try buffer.beginFinish(sessionID)
        let record = ModelPromptRecord(requestID: sessionID, provider: Self.provider, messages: [],
            details: "Audio transcription on \(client.endpoint.displayName); Nami sends no text or system prompt. Language: \(language ?? "auto").")
        await observer?(record)
        let started = ContinuousClock.now
        do {
            let text = try await client.transcribe(audio, language: language)
            try Task.checkCancellation()
            try buffer.complete(sessionID)
            await observer?(record.responding(.init(output: text, seconds: started.secondsElapsed)))
            return text
        } catch {
            buffer.cancel(sessionID)
            await observer?(record.responding(.init(output: "", error: error.localizedDescription, seconds: started.secondsElapsed)))
            if error is CancellationError || error as? EngineError == .cancelled { throw EngineError.cancelled }
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func cancel(sessionID: UUID) async { buffer.cancel(sessionID) }
}

/// Cleanup on the server's Qwen 3 4B Instruct, with the prompt the local Qwen models use.
struct ServerTextProcessor: TextProcessor {
    static let identifier = "nami-server"
    var identifier: String { Self.identifier }
    let connection: NamiServerConnection
    var transport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    func prepare() async throws {
        guard connection.endpoint != nil else {
            throw CleanupFailure.unavailable("Enter your Nami server's address in Models to clean up on it.")
        }
    }

    func process(_ request: CleanupRequest) async throws -> String {
        guard let endpoint = connection.endpoint else {
            throw CleanupFailure.unavailable("Enter your Nami server's address in Models to clean up on it.")
        }
        guard request.language == "en" || request.language == "auto" else {
            throw CleanupFailure.unavailable("This cleanup experiment currently supports English dictation.")
        }
        guard request.rawText.utf8.count <= 8_000 else {
            throw CleanupFailure.unavailable("This dictation exceeds Qwen's current cleanup limit. Original text kept.")
        }
        let settings = request.prompts.qwenGeneration.clamped
        let messages = [
            ModelPromptMessage(role: "system", content: request.prompts[.qwenSystem]),
            ModelPromptMessage(role: "user", content: CleanupPrompt.input(request, highlightEdits: true)),
        ]
        let record = ModelPromptRecord(requestID: request.id, provider: identifier, messages: messages,
            details: "\(endpoint.displayName) · temperature \(settings.temperature) · maximum \(settings.maxOutputTokens) output tokens")
        await request.promptObserver?(record)
        let started = ContinuousClock.now
        let output: String
        do {
            output = try await NamiServerClient(endpoint: endpoint, transport: transport)
                .complete(messages, maxTokens: settings.maxOutputTokens, temperature: settings.temperature)
        } catch {
            await request.promptObserver?(record.responding(.init(output: "", error: error.localizedDescription,
                seconds: started.secondsElapsed)))
            if error is CancellationError { throw error }
            throw CleanupFailure.unavailable(error.localizedDescription)
        }
        await request.promptObserver?(record.responding(.init(output: output, seconds: started.secondsElapsed)))
        try Task.checkCancellation()
        return CleanupOutput.removingStringEnvelope(output, original: request.rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
