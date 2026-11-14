import Foundation
import HomeswiftAI
import NIOConcurrencyHelpers
import Testing

/// A speech-to-text server: `/audio/transcriptions` answers what was said, anything else as the chat model.
final class SpeechServer: HTTPTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private var sent: [HTTPRequest] = []
    let chat = CannedModel()

    var requests: [HTTPRequest] { lock.withLock { sent } }

    func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.path.hasSuffix("/audio/transcriptions") else { return try await chat.post(request) }
        lock.withLock { sent.append(request) }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"text":" Turn on the lamp. "}"#.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream { try await chat.stream(request) }
}

@Suite(.timeLimit(.minutes(1)))
struct TranscriptionRouteTests {
    /// The chat's recording goes to the block's speech server as a WAV, in the page's language, and its words come back.
    @Test func writesDownWhatWasSaid() async throws {
        let speech = SpeechServer()
        let environment = try UITestEnvironment(auth: .none, model: speech, aiSettings: #""transcription": { "baseUrl": "http://127.0.0.1:9/v1/", "model": "whisper-local" }"#)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/assistant").json?["transcription"] == true)

        let pcm = Data(repeating: 0, count: 16000)   // half a second at 16 kHz
        let reply = try await browser.post("/api/assistant/transcribe", ["audio": .string(pcm.base64EncodedString()), "sampleRate": 16000, "language": "fr-FR"])
        #expect(reply.json?["text"] == "Turn on the lamp.")
        let request = try #require(speech.requests.first)
        #expect(request.url.absoluteString == "http://127.0.0.1:9/v1/audio/transcriptions")
        #expect(request.headers["Authorization"] == nil)   // no key was given for this server
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("whisper-local"))
        #expect(body.contains("name=\"language\"\r\n\r\nfr\r\n"))
        #expect(body.contains("RIFF"))

        #expect(try await browser.post("/api/assistant/transcribe", ["audio": "not base64!"]).status == 400)
        let tooLong = Data(repeating: 0, count: 16000 * 2 * (Transcriber.maxSeconds + 1)).base64EncodedString()
        #expect(try await browser.post("/api/assistant/transcribe", ["audio": .string(tooLong), "sampleRate": 16000]).status == 413)
    }

    /// Without a transcription the page keeps the browser's dictation, and the route says why it is off.
    @Test func isOffWithoutATranscription() async throws {
        let environment = try UITestEnvironment(auth: .none, model: CannedModel())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/assistant").json?["transcription"] == false)
        #expect(try await browser.post("/api/assistant/transcribe", ["audio": "AAAA"]).status == 404)
    }
}
