import Foundation
import Logging
import Testing

@testable import HomeswiftAI

let testLogger: Logger = {
    var logger = Logger(label: "homeswift.ai")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Answers requests from a queue of canned replies and keeps what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body: String
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [HTTPRequest] = []

    init(_ replies: [Reply] = []) {
        self.replies = replies
    }

    init(json: String...) {
        replies = json.map { Reply(body: $0) }
    }

    func enqueue(_ reply: Reply) {
        lock.withLock { replies.append(reply) }
    }

    private func next(_ request: HTTPRequest) throws -> Reply {
        try lock.withLock {
            requests.append(request)
            guard !replies.isEmpty else { throw FakeError.noReply }
            return replies.removeFirst()
        }
    }

    func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = try next(request)
        return HTTPResponse(status: reply.status, headers: reply.headers, body: Data(reply.body.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let reply = try next(request)
        let lines = reply.body.split(separator: "\n", omittingEmptySubsequences: false).map { Data(($0 + "\n").utf8) }
        return HTTPStream(status: reply.status, headers: reply.headers, body: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    /// The JSON body of the request at `index`.
    func body(_ index: Int = 0) throws -> JSONValue {
        try JSONValue(data: lock.withLock { requests[index].body })
    }

    func headers(_ index: Int = 0) -> [String: String] {
        lock.withLock { requests[index].headers }
    }

    var count: Int { lock.withLock { requests.count } }

    enum FakeError: Error { case noReply, unreachable }
}

/// A provider that returns canned results, for the Assistant and JSON generation tests.
final class FakeProvider: Provider, @unchecked Sendable {
    let name = "fake"
    let model = "fake-1"
    let capabilities: ProviderCapabilities
    private let lock = NSLock()
    private var replies: [String]
    private(set) var requests: [ChatRequest] = []

    init(replies: [String], streaming: Bool = true, contextTokens: Int = 100_000) {
        self.replies = replies
        capabilities = ProviderCapabilities(streaming: streaming, contextTokens: contextTokens)
    }

    private func next(_ request: ChatRequest) -> String {
        lock.withLock {
            requests.append(request)
            return replies.isEmpty ? "" : replies.removeFirst()
        }
    }

    func chat(_ request: ChatRequest) async throws -> ChatResult {
        let text = next(request)
        return ChatResult(model: model, text: text, toolCalls: [], usage: TokenUsage(inputTokens: 10, outputTokens: 5), stopReason: .end)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        let text = next(request)
        return AsyncThrowingStream { continuation in
            for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                continuation.yield(.text(String(word) + " "))
            }
            continuation.yield(.done(ChatResult(model: model, text: text, toolCalls: [], usage: TokenUsage(inputTokens: 10, outputTokens: 5), stopReason: .end)))
            continuation.finish()
        }
    }

    var lastRequest: ChatRequest? { lock.withLock { requests.last } }
}

func anthropic(_ transport: FakeTransport, model: String = "claude-opus-5-5", effort: EffortLevel? = nil, promptCaching: Bool = true) throws -> AnthropicProvider {
    var configuration = AIConfiguration(provider: .anthropic, model: model, apiKey: "sk-ant-test-key-0123456789")
    configuration.effort = effort
    configuration.promptCaching = promptCaching
    return try AnthropicProvider(configuration: configuration, transport: transport)
}

func sse(_ events: [(String, String)]) -> String {
    events.map { "event: \($0.0)\ndata: \($0.1)\n" }.joined(separator: "\n") + "\n"
}
