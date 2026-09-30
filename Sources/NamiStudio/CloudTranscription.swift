import Foundation
import NamiCore

struct CloudTranscript: Codable, Sendable {
    struct Word: Codable, Sendable {
        var text: String
        var start: Double?
        var end: Double?
        var type: String?
    }
    var text: String
    var language_code: String?
    var words: [Word]?
}

struct CloudTranscriber: Sendable {
    static let modelID = "scribe_v2"
    static let model = DebugModel(name: "ElevenLabs · Scribe v2", folder: "cloud:elevenlabs:scribe_v2")
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    func transcribe(audio: Data, language: String, apiKey: String, promptObserver: ModelPromptObserver? = nil) async throws -> CloudTranscript {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StudioError.message("Enter an ElevenLabs API key or set ELEVENLABS_API_KEY.") }
        let boundary = "Nami-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        var fields = ["model_id": Self.modelID, "tag_audio_events": "false", "diarize": "false",
                      "timestamps_granularity": "word", "no_verbatim": "false", "temperature": "0"]
        if language != "auto" { fields["language_code"] = language }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let record = ModelPromptRecord(requestID: UUID(), provider: "ElevenLabs · Scribe v2", messages: [],
            details: "Audio transcription; Nami sends no text or system prompt. Language: \(language).")
        await promptObserver?(record)
        let started = ContinuousClock.now
        func respond(_ output: String = "", error: Error? = nil, details: String = "") async {
            await promptObserver?(record.responding(.init(output: output, error: error?.localizedDescription,
                seconds: started.secondsElapsed, details: details)))
        }
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw StudioError.message("Invalid cloud response.") }
            guard (200..<300).contains(http.statusCode) else {
                // Do not persist provider bodies: they may echo request contents or credentials.
                throw StudioError.message("ElevenLabs returned HTTP \(http.statusCode). Check the key, quota and service status. No automatic retry was made.")
            }
            let transcript = try JSONDecoder().decode(CloudTranscript.self, from: data)
            await respond(transcript.text, details: "HTTP \(http.statusCode) · \(data.count) bytes · \(transcript.words?.count ?? 0) words · language \(transcript.language_code ?? "unknown")")
            return transcript
        } catch {
            await respond(error: error)
            throw error
        }
    }
}
