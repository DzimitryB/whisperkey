import Foundation

/// A cloud speech-to-text provider. OpenAI-compatible ones use /audio/transcriptions
/// with multipart upload; Gemini takes base64 audio inside a generateContent JSON request.
struct CloudProvider {
    enum Kind {
        case openAICompatible
        case gemini
        case elevenLabs
    }

    let id: String
    let title: String
    let endpoint: URL
    let kind: Kind
    let keyPlaceholder: String

    static let openAI = CloudProvider(
        id: "openai",
        title: "OpenAI",
        endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        kind: .openAICompatible,
        keyPlaceholder: "sk-…"
    )
    static let groq = CloudProvider(
        id: "groq",
        title: "Groq",
        endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
        kind: .openAICompatible,
        keyPlaceholder: "gsk_…"
    )
    static let google = CloudProvider(
        id: "google",
        title: "Google Gemini",
        endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
        kind: .gemini,
        keyPlaceholder: "AIza…"
    )
    static let elevenLabs = CloudProvider(
        id: "elevenlabs",
        title: "ElevenLabs",
        endpoint: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        kind: .elevenLabs,
        keyPlaceholder: "sk_…"
    )
    static let mistral = CloudProvider(
        id: "mistral",
        title: "Mistral",
        endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
        kind: .openAICompatible,
        keyPlaceholder: "ключ из console.mistral.ai"
    )

    static let all: [CloudProvider] = [.openAI, .groq, .google, .elevenLabs, .mistral]

    static func by(id: String) -> CloudProvider? {
        all.first { $0.id == id }
    }
}

/// A selectable recognition engine: local whisper.cpp (provider == nil) or a cloud model.
struct EngineOption {
    let title: String
    let provider: CloudProvider?
    let model: String?

    static let all: [EngineOption] = [
        EngineOption(title: "Локально (whisper.cpp)", provider: nil, model: nil),
        EngineOption(title: "OpenAI — gpt-4o-mini-transcribe (быстро)", provider: .openAI, model: "gpt-4o-mini-transcribe"),
        EngineOption(title: "OpenAI — gpt-4o-transcribe (точнее)", provider: .openAI, model: "gpt-4o-transcribe"),
        EngineOption(title: "OpenAI — whisper-1", provider: .openAI, model: "whisper-1"),
        EngineOption(title: "Groq — whisper-large-v3-turbo (очень быстро)", provider: .groq, model: "whisper-large-v3-turbo"),
        EngineOption(title: "Google — gemini-2.5-flash (быстро и точно)", provider: .google, model: "gemini-2.5-flash"),
        EngineOption(title: "Google — gemini-2.5-flash-lite (быстрее)", provider: .google, model: "gemini-2.5-flash-lite"),
        EngineOption(title: "ElevenLabs — Scribe v2 (топ точности)", provider: .elevenLabs, model: "scribe_v2"),
        EngineOption(title: "Mistral — Voxtral Mini Transcribe 2 (дёшево)", provider: .mistral, model: "voxtral-mini-latest"),
    ]
}

/// API keys live in a user-only file (~/Library/Application Support/WhisperKey/keys.json,
/// chmod 600). Unlike the Keychain, this never re-prompts when the app's ad-hoc
/// signature changes after a rebuild.
enum KeyStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keys.json")
    }()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func set(_ value: String, account: String) {
        var dict = load()
        dict[account] = value
        save(dict)
    }

    static func get(account: String) -> String? {
        load()[account]
    }

    static func has(account: String) -> Bool {
        load()[account] != nil
    }
}

enum CloudTranscriber {
    enum CloudError: LocalizedError {
        case http(Int, String)
        case network(Error)
        case emptyResponse
        case audioTooLarge

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Сервис ответил ошибкой \(code): \(body)"
            case .network(let error):
                return "Сеть недоступна: \(error.localizedDescription)"
            case .emptyResponse:
                return "Сервис вернул пустой ответ."
            case .audioTooLarge:
                return "Запись слишком длинная для Gemini (лимит ~7 минут)."
            }
        }
    }

    /// Blocking; call from a background queue.
    static func transcribe(
        wav: URL, provider: CloudProvider, model: String, language: String, apiKey: String
    ) throws -> String {
        switch provider.kind {
        case .openAICompatible:
            return try transcribeOpenAICompatible(
                wav: wav, provider: provider, model: model, language: language, apiKey: apiKey
            )
        case .gemini:
            return try transcribeGemini(
                wav: wav, provider: provider, model: model, language: language, apiKey: apiKey
            )
        case .elevenLabs:
            return try transcribeElevenLabs(
                wav: wav, provider: provider, model: model, language: language, apiKey: apiKey
            )
        }
    }

    private static func transcribeOpenAICompatible(
        wav: URL, provider: CloudProvider, model: String, language: String, apiKey: String
    ) throws -> String {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "WhisperKey-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        addField("model", model)
        if language != "auto" {
            addField("language", language)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: wav))
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        // OpenAI, Groq and Mistral all default to JSON with a "text" field.
        let raw = try send(request)
        return try normalize(extractTextField(raw) ?? raw)
    }

    /// ElevenLabs Scribe: multipart with model_id/language_code, xi-api-key header.
    private static func transcribeElevenLabs(
        wav: URL, provider: CloudProvider, model: String, language: String, apiKey: String
    ) throws -> String {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let boundary = "WhisperKey-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        addField("model_id", model)
        if language != "auto" {
            addField("language_code", language)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: wav))
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let raw = try send(request)
        guard let text = extractTextField(raw) else {
            throw CloudError.http(0, "неожиданный формат ответа ElevenLabs: \(String(raw.prefix(200)))")
        }
        return try normalize(text)
    }

    private static func extractTextField(_ raw: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let text = obj["text"] as? String else { return nil }
        return text
    }

    /// Gemini: base64 WAV inside a generateContent request, transcription via instruction.
    private static func transcribeGemini(
        wav: URL, provider: CloudProvider, model: String, language: String, apiKey: String
    ) throws -> String {
        let audioData = try Data(contentsOf: wav)
        // Inline request limit is ~20 MB; base64 inflates by 4/3.
        guard audioData.count < 14_000_000 else { throw CloudError.audioTooLarge }

        var instruction = "Transcribe this audio recording verbatim. Output ONLY the transcribed text, "
            + "without any comments, labels, translations or quotation marks. "
            + "If there is no intelligible speech, output nothing."
        switch language {
        case "ru": instruction += " The audio is in Russian."
        case "en": instruction += " The audio is in English."
        default: break
        }

        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": instruction],
                    ["inline_data": ["mime_type": "audio/wav", "data": audioData.base64EncodedString()]],
                ],
            ]],
            "generationConfig": ["temperature": 0],
        ]

        guard let url = URL(string: "\(provider.endpoint.absoluteString)/\(model):generateContent") else {
            throw CloudError.http(0, "неверный URL модели")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let raw = try send(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw CloudError.http(0, "неожиданный формат ответа Gemini: \(String(raw.prefix(200)))")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        return try normalize(text)
    }

    /// Executes the request synchronously, returns the body; throws on network/HTTP errors.
    private static func send(_ request: URLRequest) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: HTTPURLResponse?
        var resultError: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response as? HTTPURLResponse
            resultError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let resultError {
            throw CloudError.network(resultError)
        }
        let raw = String(data: resultData ?? Data(), encoding: .utf8) ?? ""
        guard let status = resultResponse?.statusCode, (200..<300).contains(status) else {
            throw CloudError.http(resultResponse?.statusCode ?? 0, String(raw.prefix(300)))
        }
        return raw
    }

    private static func normalize(_ raw: String) throws -> String {
        let text = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { throw CloudError.emptyResponse }
        return text
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
