import Foundation
import Testing

@testable import HomeswiftAI

@Suite struct TranscriptionTests {
    /// A key goes only where it was given: the Assistant's OpenAI key and OPENAI_API_KEY to OpenAI's address alone.
    @Test func keysFollowTheirServer() throws {
        let environment = ["OPENAI_API_KEY": "sk-env"]
        func transcription(_ block: String) throws -> TranscriptionConfiguration? {
            try AIConfiguration(block: try JSONValue(string: block), environment: environment).transcription
        }
        #expect(try transcription(#"{ "provider": "anthropic", "apiKey": "sk-ant" }"#) == nil)
        #expect(try transcription(#"{ "provider": "openai", "apiKey": "sk-a", "transcription": { "enabled": false } }"#) == nil)
        let openai = try #require(try transcription(#"{ "provider": "openai", "apiKey": "sk-a", "transcription": {} }"#))
        #expect(openai.baseURL == TranscriptionConfiguration.openAIBaseURL)
        #expect(openai.apiKey == "sk-a")
        #expect(openai.model == "whisper-1")
        #expect(try transcription(#"{ "provider": "anthropic", "apiKey": "sk-ant", "transcription": {} }"#)?.apiKey == "sk-env")
        let local = try #require(try transcription(#"{ "provider": "openai", "apiKey": "sk-a", "transcription": { "baseUrl": "http://10.0.0.5:8000/v1/" } }"#))
        #expect(local.baseURL == "http://10.0.0.5:8000/v1")
        #expect(local.apiKey == nil)
        #expect(try transcription(#"{ "provider": "anthropic", "apiKey": "x", "transcription": { "baseUrl": "http://10.0.0.5:8000/v1", "apiKey": "own", "model": "large-v3" } }"#)
            == TranscriptionConfiguration(baseURL: "http://10.0.0.5:8000/v1", apiKey: "own", model: "large-v3"))
    }

    /// `engine: apple` is Apple's speech recognition, on a Mac with macOS 26 only; an engine it does not know is refused.
    @Test func theAppleEngineRunsOnlyWhereItCan() throws {
        let apple = try #require(try AIConfiguration(block: try JSONValue(string: #"{ "provider": "anthropic", "apiKey": "x", "transcription": { "engine": "apple" } }"#)).transcription)
        #expect(apple.engine == .apple)
        #expect(apple.apiKey == nil)
        #expect(apple.isAvailable == AppleTranscriber.isAvailable)
        #expect((apple.makeTranscriber(transport: FakeTransport()) != nil) == AppleTranscriber.isAvailable)
        #if os(Linux)
        #expect(!AppleTranscriber.isAvailable)
        #endif
        #expect(throws: AIConfigurationError.self) {
            try AIConfiguration(block: try JSONValue(string: #"{ "provider": "anthropic", "apiKey": "x", "transcription": { "engine": "siri" } }"#))
        }
        // The server engine is the default.
        #expect(try AIConfiguration(block: try JSONValue(string: #"{ "provider": "anthropic", "apiKey": "x", "transcription": {} }"#)).transcription?.engine == .server)
    }

    /// One multipart request: the model, the language's first part, and the recording as a WAV file.
    @Test func sendsTheRecordingAsAWAV() async throws {
        let transport = FakeTransport(json: #"{"text":"Bonjour."}"#)
        let transcriber = Transcriber(configuration: TranscriptionConfiguration(apiKey: "sk-a"), transport: transport)
        let pcm = Data([1, 0, 255, 255])
        #expect(try await transcriber.transcribe(pcm: pcm, sampleRate: 16000, language: "fr-FR") == "Bonjour.")
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.headers["Authorization"] == "Bearer sk-a")
        let type = try #require(request.headers["Content-Type"])
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nfr\r\n"))
        #expect(body.contains("filename=\"speech.wav\"\r\nContent-Type: audio/wav"))
        #expect(request.body.range(of: Transcriber.wav(pcm: pcm, sampleRate: 16000)) != nil)
    }

    @Test func aWAVHeaderDescribes16BitMono() {
        let wav = Transcriber.wav(pcm: Data(repeating: 0, count: 10), sampleRate: 16000)
        #expect(wav.count == 54)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        func uint32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func uint16(_ at: Int) -> UInt16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        #expect(uint32(4) == 46)
        #expect(uint16(22) == 1)        // mono
        #expect(uint32(24) == 16000)
        #expect(uint32(28) == 32000)    // bytes per second
        #expect(uint16(34) == 16)       // bits per sample
        #expect(uint32(40) == 10)
    }

    @Test func aFailedRequestSaysWhy() async throws {
        let transport = FakeTransport([.init(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#)])
        let transcriber = Transcriber(configuration: TranscriptionConfiguration(apiKey: "sk-a", maxRetries: 0), transport: transport)
        await #expect(throws: ProviderError.self) { try await transcriber.transcribe(pcm: Data([0, 0]), sampleRate: 16000, language: nil) }
        #expect(!String(decoding: transport.requests[0].body, as: UTF8.self).contains("name=\"language\""))
    }
}
