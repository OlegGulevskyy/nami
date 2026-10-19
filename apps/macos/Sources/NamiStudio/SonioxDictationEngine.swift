import Foundation
import NamiCore

@MainActor protocol DictationSocket: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

@MainActor final class SonioxSocket: DictationSocket {
    private let task: URLSessionWebSocketTask
    init(request: URLRequest) {
        task = DictationNetwork.session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Soniox sends final tokens once; provisional suffixes replace each other, never accumulate.
struct SonioxTranscript {
    private(set) var final = ""
    private(set) var partial = ""
    private(set) var finished = false

    mutating func receive(_ data: Data) throws {
        struct Event: Decodable {
            struct Token: Decodable { let text: String; let is_final: Bool }
            let tokens: [Token]?
            let finished: Bool?
            let error_code: Int?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
            throw DictationCloudError.message("Soniox returned an unreadable response. Your recording is kept.")
        }
        if let code = event.error_code { throw DictationCloudError.http(code, provider: .soniox) }
        partial = ""
        for token in event.tokens ?? [] {
            guard !["<end>", "<fin>"].contains(token.text) else { continue }
            if token.is_final { final += token.text } else { partial += token.text }
        }
        finished = event.finished == true
    }
    var preview: String { final + partial }
}

@MainActor final class SonioxDictationEngine: TranscriptionEngine {
    let capabilities = EngineCapabilities(incrementalProcessing: true, requiresNetwork: true)
    private let configuration: DictationCloudConfiguration
    private let makeSocket: @MainActor (URLRequest) -> any DictationSocket
    private let timeout: Duration
    private var prepared = false
    private var active: UUID?
    private var socket: (any DictationSocket)?
    private var receiver: Task<String, Error>?
    private var failure: Error?
    private var samplesSent = 0
    private var finishing = false

    init(configuration: DictationCloudConfiguration, timeout: Duration = .seconds(30),
         makeSocket: @escaping @MainActor (URLRequest) -> any DictationSocket = { SonioxSocket(request: $0) }) {
        self.configuration = configuration; self.timeout = timeout; self.makeSocket = makeSocket
    }

    func prepare() async throws { try configuration.validate(); prepared = true }

    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        guard active == nil else { throw EngineError.invalidState }
        active = sessionID; samplesSent = 0; finishing = false; failure = nil
        let host = configuration.region == .eu ? "stt-rt.eu.soniox.com" : "stt-rt.soniox.com"
        var request = URLRequest(url: URL(string: "wss://\(host)/transcribe-websocket")!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
        let connection = makeSocket(request)
        socket = connection
        do {
            var config: [String: Any] = ["model": configuration.model, "audio_format": "pcm_s16le",
                "sample_rate": 16000, "num_channels": 1, "enable_language_identification": true,
                "language_hints": language.map { [$0] } ?? ["en", "fr"]]
            let terms = DictationFileClient.terms(vocabulary)
            if !terms.isEmpty { config["context"] = ["terms": terms] }
            let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            try await send(.string(String(decoding: data, as: UTF8.self)), connection: connection, id: sessionID)
            receiver = Task { [weak self] in
                var transcript = SonioxTranscript()
                do {
                    while true {
                        let message = try await connection.receive()
                        try Task.checkCancellation()
                        guard self?.active == sessionID else { throw EngineError.cancelled }
                        let data: Data
                        switch message {
                        case .data(let bytes): data = bytes
                        case .string(let text): data = Data(text.utf8)
                        @unknown default: throw EngineError.invalidState
                        }
                        try transcript.receive(data)
                        if transcript.finished {
                            guard self?.finishing == true else {
                                throw DictationCloudError.message("Soniox ended before the recording stopped. Your audio is kept for retry.")
                            }
                            return transcript.final.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        onPartial?(transcript.preview)
                    }
                } catch {
                    let safe = DictationCloudError.safe(error, provider: .soniox)
                    if self?.active == sessionID, self?.failure == nil { self?.failure = safe }
                    connection.close()
                    throw safe
                }
            }
        } catch {
            await cancel(sessionID: sessionID)
            throw DictationCloudError.safe(error, provider: .soniox)
        }
    }

    func append(_ chunk: AudioChunk, sessionID: UUID) async throws {
        try check(sessionID)
        guard !finishing, let socket else { throw EngineError.invalidState }
        guard chunk.timestamp.isFinite,
              abs(chunk.timestamp - Double(samplesSent) / AudioChunk.sampleRate) < 1 / AudioChunk.sampleRate,
              chunk.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw EngineError.invalidAudio }
        // Cap a stream before the provider's 300-minute limit, never silently lose the remainder.
        guard samplesSent + chunk.samples.count <= 300 * 60 * 16000 else {
            throw DictationCloudError.message("Soniox's 300-minute streaming limit was reached. Your recording is kept.")
        }
        if !chunk.samples.isEmpty {
            var pcm = Data(capacity: chunk.samples.count * 2)
            for sample in chunk.samples {
                var value = Int16(max(-32768, min(32767, (Double(sample) * 32767).rounded()))).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            try await send(.data(pcm), connection: socket, id: sessionID)
        }
        samplesSent += chunk.samples.count
    }

    func finish(sessionID: UUID) async throws -> String {
        try check(sessionID)
        guard !finishing, let socket, let receiver else { throw EngineError.invalidState }
        guard samplesSent > 0 else { await cancel(sessionID: sessionID); throw EngineError.noAudio }
        finishing = true
        let watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.active == sessionID else { return }
            self?.failure = DictationCloudError.message("Soniox timed out while finalizing. Your recording is kept.")
            socket.close(); receiver.cancel()
        }
        defer { watchdog.cancel() }
        do {
            // Empty TEXT closes the audio input and flushes pending tokens. Binary empty data does not.
            try await send(.string(""), connection: socket, id: sessionID)
            let text = try await withTaskCancellationHandler { try await receiver.value } onCancel: {
                Task { @MainActor in socket.close(); receiver.cancel() }
            }
            try Task.checkCancellation()
            try check(sessionID)
            socket.close(); self.socket = nil; self.receiver = nil; active = nil
            return text
        } catch {
            let result = failure ?? DictationCloudError.safe(error, provider: .soniox)
            await cancel(sessionID: sessionID)
            throw result
        }
    }

    func cancel(sessionID: UUID) async {
        guard active == sessionID else { return }
        active = nil
        socket?.close(); socket = nil
        receiver?.cancel(); receiver = nil
        finishing = false; samplesSent = 0; failure = nil
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard active == id else { throw EngineError.cancelled }
        if let failure { throw failure }
    }

    private func send(_ message: URLSessionWebSocketTask.Message, connection: any DictationSocket, id: UUID) async throws {
        let watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.active == id else { return }
            self?.failure = DictationCloudError.message("Soniox's connection timed out. Your recording is kept.")
            connection.close()
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler { try await connection.send(message) } onCancel: {
                Task { @MainActor in connection.close() }
            }
            try check(id)
        } catch {
            throw failure ?? DictationCloudError.safe(error, provider: .soniox)
        }
    }
}
