import Foundation

// Speech to text for the chat's mic: the page records the microphone and the bridge sends it to an OpenAI-compatible
// `/audio/transcriptions` (OpenAI's, or a local Whisper server that speaks the same API), as the Claude app sends its
// voice to a speech service before the model reads the words. Claude reads text and images, not audio.

/// The HomeswiftAiKit block's `transcription` object:
///
///     "transcription": { "enabled": true, "baseUrl": "https://api.openai.com/v1", "apiKey": "sk-…", "model": "whisper-1" }
///
/// Without a key of its own it uses the block's key when the Assistant is OpenAI, else OPENAI_API_KEY, on OpenAI's
/// address only: a key is never sent to a server it was not given for.
public struct TranscriptionConfiguration: Sendable, Equatable {
    public static let openAIBaseURL = AIConfiguration.ProviderKind.openai.defaultBaseURL!
    public static let defaultModel = "whisper-1"

    public var baseURL: String
    /// Secret: redaction treats it as one.
    public var apiKey: String?
    public var model: String
    public var maxRetries: Int

    public init(baseURL: String = Self.openAIBaseURL, apiKey: String? = nil, model: String = Self.defaultModel, maxRetries: Int = 2) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxRetries = maxRetries
    }

    /// The block's `transcription`; nil when there is none or it is off.
    init?(block: JSONValue?, assistant: AIConfiguration, environment: [String: String]) {
        guard let object = block?.objectValue, object["enabled"] != .bool(false) else { return nil }
        func string(_ key: String) -> String? { object[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
        baseURL = (string("baseUrl") ?? Self.openAIBaseURL).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let atOpenAI = baseURL == Self.openAIBaseURL
        apiKey = string("apiKey")
            ?? (atOpenAI && assistant.provider == .openai ? assistant.apiKey : nil)
            ?? (atOpenAI ? AIConfiguration.ProviderKind.openai.apiKeyEnvironmentVariable.flatMap { environment[$0]?.nonEmpty } : nil)
        model = string("model") ?? Self.defaultModel
        maxRetries = assistant.maxRetries
    }
}

/// Turns a recording into text through the configured server.
public struct Transcriber: Sendable {
    /// The longest recording sent, in seconds: a minute of 16 kHz speech is 1.9 MB.
    public static let maxSeconds = 90

    public let configuration: TranscriptionConfiguration
    private let transport: any HTTPTransport

    public init(configuration: TranscriptionConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// The words in `pcm` (signed 16-bit little-endian mono at `sampleRate`). `language` is a BCP 47 tag (`fr-FR`)
    /// or nil for the server to tell; the server takes its first part.
    public func transcribe(pcm: Data, sampleRate: Int, language: String?) async throws -> String {
        guard let url = URL(string: configuration.baseURL + "/audio/transcriptions") else {
            throw ProviderError(provider: "transcription", message: "the address \(configuration.baseURL) is not a URL")
        }
        let boundary = "homeswift-" + UUID().uuidString
        var fields = [("model", configuration.model), ("response_format", "json")]
        if let code = language?.split(separator: "-").first.map(String.init)?.lowercased(), !code.isEmpty { fields.append(("language", code)) }
        let body = Self.multipart(boundary: boundary, fields: fields, wavOf: pcm, sampleRate: sampleRate)
        var headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        if let key = configuration.apiKey { headers["Authorization"] = "Bearer \(key)" }
        let response = try await HTTPClient.post("transcription", transport: transport, request: HTTPRequest(url: url, headers: headers, body: body),
                                                 retry: RetryOptions(maxRetries: configuration.maxRetries))
        guard let json = try? JSONValue(data: response.body), let text = json["text"]?.stringValue else {
            throw ProviderError(provider: "transcription", message: "the response has no text")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A WAV file around 16-bit mono PCM.
    static func wav(pcm: Data, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        appendWAV(pcm, sampleRate: sampleRate, to: &data)
        return data
    }

    private static func appendWAV(_ pcm: Data, sampleRate: Int, to data: inout Data) {
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)   // PCM
        append16(1)   // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(UInt32(pcm.count))
        data.append(pcm)
    }

    /// The request's form: `fields`, then the recording as `file`, a WAV, written once.
    static func multipart(boundary: String, fields: [(String, String)], wavOf pcm: Data, sampleRate: Int) -> Data {
        var body = Data(capacity: pcm.count + 512)
        for (name, value) in fields {
            body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        appendWAV(pcm, sampleRate: sampleRate, to: &body)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }
}
