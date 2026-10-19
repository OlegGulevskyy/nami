import Foundation
import NamiCore
import Security

/// Explicit, versioned choices: selecting a provider never silently selects a different model.
public enum DictationProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case groq, soniox, assemblyai, mistral
    public var id: String { rawValue }
    var title: String {
        switch self { case .groq: "Groq"; case .soniox: "Soniox"; case .assemblyai: "AssemblyAI"; case .mistral: "Mistral" }
    }
    var engineID: String { "cloud-" + rawValue }
    init?(engineID: String) {
        guard let value = Self.allCases.first(where: { $0.engineID == engineID }) else { return nil }
        self = value
    }
    var models: [(id: String, title: String)] {
        switch self {
        case .groq: [("whisper-large-v3-turbo", "Whisper Large V3 Turbo"), ("whisper-large-v3", "Whisper Large V3")]
        case .soniox: [("stt-rt-v5", "Realtime v5")]
        case .assemblyai: [("universal-3-5-pro", "Universal-3.5 Pro · Sync")]
        case .mistral: [("voxtral-mini-2602", "Voxtral Mini Transcribe 2")]
        }
    }
    var detail: String {
        switch self {
        case .groq: "Uploads after Stop. Multilingual Whisper; Turbo is the lowest-cost choice. Up to 25 MB per recording."
        case .soniox: "Streams while you speak. Supports English, French and mixed-language speech. Choose the region that matches your API key."
        case .assemblyai: "Uploads after Stop for a direct response. Recordings must be 0.08–120 seconds. Auto-detect is guided toward English and French."
        case .mistral: "Uploads after Stop. Multilingual transcription with vocabulary hints, including English and French."
        }
    }
    var keyURL: URL {
        let address = switch self {
        case .groq: "https://console.groq.com/keys"
        case .soniox: "https://console.soniox.com"
        case .assemblyai: "https://www.assemblyai.com/dashboard/"
        case .mistral: "https://console.mistral.ai/api-keys"
        }
        return URL(string: address)!
    }
}

public enum DictationCloudRegion: String, Codable, CaseIterable, Sendable {
    case us, eu
    var title: String { self == .eu ? "European Union" : "United States" }
}

/// Never serialized alongside settings. In tests this can be replaced without accessing Keychain.
@MainActor public struct DictationAPIKeyStore {
    public var load: (DictationProvider) throws -> String?
    public var save: (DictationProvider, String) throws -> Void

    public init(load: @escaping (DictationProvider) throws -> String?, save: @escaping (DictationProvider, String) throws -> Void) {
        self.load = load; self.save = save
    }

    static let unavailable = Self(load: { _ in nil }, save: { _, _ in throw StudioError.message("API keys are unavailable in this preview.") })

    static func keychain() -> Self {
        func query(_ provider: DictationProvider) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "local.nami.dictation",
             kSecAttrAccount as String: provider.rawValue]
        }
        func check(_ status: OSStatus) throws {
            guard status == errSecSuccess else { throw StudioError.message("Could not access the dictation API key in Keychain (\(status)).") }
        }
        return Self(load: { provider in
            var request = query(provider)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw StudioError.message("The saved \(provider.title) key could not be read.")
            }
            return key
        }, save: { provider, value in
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = query(provider)
            if key.isEmpty {
                let status = SecItemDelete(request as CFDictionary)
                if status != errSecItemNotFound { try check(status) }
                return
            }
            let attributes = [kSecValueData as String: Data(key.utf8)]
            let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = request
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(status) }
        })
    }
}

enum DictationCloudError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }

    static func http(_ code: Int, provider: DictationProvider) -> Self {
        let advice: String
        switch code {
        case 401, 403: advice = "Check your API key, account access and selected region."
        case 402: advice = "Check your provider's billing balance."
        case 429: advice = "Your rate limit or quota was reached. Wait or check your plan."
        case 413: advice = "This recording exceeds the provider's upload limit."
        case 400, 422: advice = "The provider rejected this model, language or recording. Check your selection."
        default: advice = "Check your connection and the provider's service status."
        }
        return .message("\(provider.title) returned HTTP \(code). \(advice) Your recording is kept; no automatic retry was made.")
    }

    /// Never show provider response bodies or underlying URLs: they can contain credentials or echoed audio/text.
    static func safe(_ error: Error, provider: DictationProvider) -> Error {
        if error is CancellationError || error as? EngineError == .cancelled || (error as? URLError)?.code == .cancelled { return EngineError.cancelled }
        if error is DictationCloudError || error is EngineError { return error }
        if let url = error as? URLError, url.code == .timedOut {
            return Self.message("\(provider.title) timed out. Your recording is kept; try again from History.")
        }
        return Self.message("Could not complete transcription with \(provider.title). Check your connection, API key and region. Your recording is kept.")
    }
}

struct DictationCloudConfiguration: Sendable {
    let provider: DictationProvider
    let model: String
    let region: DictationCloudRegion
    let apiKey: String

    func validate() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationCloudError.message("Add your \(provider.title) API key in Settings → Models → Cloud dictation.")
        }
        guard !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw DictationCloudError.message("The \(provider.title) API key contains whitespace. Paste the key again.")
        }
        guard provider.models.contains(where: { $0.id == model }) else {
            throw DictationCloudError.message("Choose a supported \(provider.title) model in Settings → Models.")
        }
    }
}

struct DictationMultipart {
    let boundary = "Nami-" + UUID().uuidString
    private(set) var data = Data()
    mutating func add(_ name: String, _ value: String, contentType: String? = nil) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n")
        if let contentType { append("Content-Type: \(contentType)\r\n") }
        append("\r\n\(value)\r\n")
    }
    mutating func audio(_ name: String, wav: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        data.append(wav); append("\r\n")
    }
    mutating func finish() { append("--\(boundary)--\r\n") }
    private mutating func append(_ text: String) { data.append(Data(text.utf8)) }
}

/// Ephemeral networking avoids disk caches; redirects never forward keys or audio to a new host.
final class DictationNetwork: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = DictationNetwork()
    static let session = URLSession(configuration: .ephemeral, delegate: shared, delegateQueue: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DictationFileClient: Sendable {
    let configuration: DictationCloudConfiguration
    var transport: HTTPTransport = { try await DictationNetwork.session.data(for: $0) }

    static func terms(_ vocabulary: String) -> [String] {
        Array(vocabulary.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(100))
    }

    @MainActor func request(samples: [Float], language: String?, vocabulary: String) throws -> URLRequest {
        try configuration.validate()
        guard !samples.isEmpty else { throw EngineError.noAudio }
        let seconds = Double(samples.count) / AudioChunk.sampleRate
        let provider = configuration.provider
        if provider == .assemblyai, !(0.08...120).contains(seconds) {
            throw DictationCloudError.message("AssemblyAI Sync accepts 0.08–120 seconds per recording. This take is \(String(format: "%.2f", seconds)) seconds. Your audio is kept; select another provider and retry from History.")
        }
        if provider == .groq, samples.count * 2 + 44 > 25_000_000 {
            throw DictationCloudError.message("This recording exceeds Groq's 25 MB direct-upload limit. Your audio is kept.")
        }
        var multipart = DictationMultipart()
        let endpoint: String
        switch provider {
        case .groq:
            endpoint = "https://api.groq.com/openai/v1/audio/transcriptions"
            multipart.add("model", configuration.model)
            multipart.add("response_format", "json")
            multipart.add("temperature", "0")
            if let language { multipart.add("language", language) }
            if !vocabulary.isEmpty { multipart.add("prompt", String(vocabulary.suffix(800))) }
        case .mistral:
            endpoint = "https://api.mistral.ai/v1/audio/transcriptions"
            multipart.add("model", configuration.model)
            if let language { multipart.add("language", language) }
            // Repeated multipart fields are the Mistral SDK's array encoding.
            for term in Self.terms(vocabulary) { multipart.add("context_bias", term) }
        case .assemblyai:
            endpoint = "https://sync.\(configuration.region == .eu ? "eu" : "us").assemblyai.com/v1/transcribe"
            var config: [String: Any] = ["language_codes": language.map { [$0] } ?? ["en", "fr"]]
            let terms = Self.terms(vocabulary)
            if !terms.isEmpty { config["keyterms_prompt"] = terms }
            let json = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            multipart.add("config", String(decoding: json, as: UTF8.self), contentType: "application/json")
        case .soniox: throw EngineError.invalidState
        }
        multipart.audio(provider == .assemblyai ? "audio" : "file", wav: StudioSession.wavData(samples))
        multipart.finish()
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = provider == .assemblyai ? 40 : 120
        request.setValue(provider == .assemblyai ? configuration.apiKey : "Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
        if provider == .assemblyai { request.setValue(configuration.model, forHTTPHeaderField: "X-AAI-Model") }
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.data
        return request
    }

    func send(_ request: URLRequest) async throws -> String {
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DictationCloudError.message("Invalid response from \(configuration.provider.title).") }
            guard (200..<300).contains(http.statusCode) else { throw DictationCloudError.http(http.statusCode, provider: configuration.provider) }
            struct Transcript: Decodable { let text: String }
            guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
                throw DictationCloudError.message("\(configuration.provider.title) returned an unreadable transcript. Your recording is kept.")
            }
            return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { throw DictationCloudError.safe(error, provider: configuration.provider) }
    }

    /// A free connection warm-up while the microphone runs, using the same URLSession/host.
    func warm() async {
        guard configuration.provider == .assemblyai else { return }
        var request = URLRequest(url: URL(string: "https://sync.\(configuration.region == .eu ? "eu" : "us").assemblyai.com/v1/warm")!)
        request.timeoutInterval = 5
        _ = try? await transport(request)
    }
}

@MainActor final class DictationFileEngine: TranscriptionEngine {
    let capabilities = EngineCapabilities(incrementalProcessing: false, requiresNetwork: true)
    private let client: DictationFileClient
    private var prepared = false
    private var buffer = AudioSessionBuffer()
    private var language: String?
    private var vocabulary = ""
    private var active: UUID?
    private var requestTask: Task<String, Error>?
    private var warmup: Task<Void, Never>?

    init(client: DictationFileClient) { self.client = client }
    func prepare() async throws { try client.configuration.validate(); prepared = true }
    func start(sessionID: UUID, language: String?, vocabulary: String, onPartial: (@Sendable (String) -> Void)?) async throws {
        guard prepared else { throw EngineError.notPrepared }
        try buffer.start(sessionID)
        active = sessionID; self.language = language; self.vocabulary = vocabulary
        if client.configuration.provider == .assemblyai { warmup = Task { await client.warm() } }
    }
    func append(_ chunk: AudioChunk, sessionID: UUID) async throws { try buffer.append(chunk, sessionID: sessionID) }
    func finish(sessionID: UUID) async throws -> String {
        let samples = try buffer.beginFinish(sessionID)
        defer { if active == nil || active == sessionID { warmup?.cancel(); warmup = nil } }
        do {
            let request = try client.request(samples: samples, language: language, vocabulary: vocabulary)
            let task = Task { try await client.send(request) }
            requestTask = task
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            try buffer.complete(sessionID)
            if active == sessionID { active = nil; requestTask = nil }
            return text
        } catch {
            buffer.cancel(sessionID)
            if active == sessionID { active = nil; requestTask = nil }
            throw DictationCloudError.safe(error, provider: client.configuration.provider)
        }
    }
    func cancel(sessionID: UUID) async {
        guard active == sessionID else { return }
        requestTask?.cancel(); requestTask = nil
        warmup?.cancel(); warmup = nil
        buffer.cancel(sessionID); active = nil
    }
}
