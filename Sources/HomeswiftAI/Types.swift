import Foundation

// The provider-neutral chat model: what the Assistant sends to a model and gets back.

public enum ChatRole: String, Sendable, Codable {
    case user, assistant
}

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum ContentPart: Sendable, Hashable, Codable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(toolCallID: String, name: String, content: String, isError: Bool)
}

public struct ChatMessage: Sendable, Hashable, Codable {
    public var role: ChatRole
    public var content: [ContentPart]
    /// The provider's own rendering of an assistant turn (Claude thinking blocks with signatures, OpenAI
    /// reasoning items): sent back verbatim to the provider that produced it, ignored by the others.
    public var providerContent: ProviderContent?

    public struct ProviderContent: Sendable, Hashable, Codable {
        public var provider: String
        public var content: JSONValue
        public init(provider: String, content: JSONValue) {
            self.provider = provider
            self.content = content
        }
    }

    public init(role: ChatRole, content: [ContentPart], providerContent: ProviderContent? = nil) {
        self.role = role
        self.content = content
        self.providerContent = providerContent
    }

    public init(role: ChatRole, text: String) {
        self.init(role: role, content: [.text(text)])
    }

    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }

    /// The text parts joined.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }
}

public struct ToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments (an object schema).
    public var inputSchema: JSONValue

    public init(name: String, description: String = "", inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// How much the model thinks: Claude `output_config.effort`, OpenAI `reasoning.effort`.
public enum EffortLevel: String, Sendable, Codable, CaseIterable {
    case low, medium, high, xhigh, max
}

public struct ChatRequest: Sendable {
    public var system: String?
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var maxOutputTokens: Int?
    /// Overrides the provider's effort for this request.
    public var effort: EffortLevel?

    public init(system: String? = nil, messages: [ChatMessage], tools: [ToolDefinition] = [], maxOutputTokens: Int? = nil, effort: EffortLevel? = nil) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
    }
}

public enum StopReason: String, Sendable, Codable {
    case end, toolCalls, maxTokens, refusal, other
}

public struct TokenUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// The part of `inputTokens` read from a prompt cache.
    public var cacheReadTokens: Int?
    /// The part of `inputTokens` written to a prompt cache (Claude).
    public var cacheWriteTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static let zero = TokenUsage()

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        var sum = TokenUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
        if a.cacheReadTokens != nil || b.cacheReadTokens != nil {
            sum.cacheReadTokens = (a.cacheReadTokens ?? 0) + (b.cacheReadTokens ?? 0)
        }
        if a.cacheWriteTokens != nil || b.cacheWriteTokens != nil {
            sum.cacheWriteTokens = (a.cacheWriteTokens ?? 0) + (b.cacheWriteTokens ?? 0)
        }
        return sum
    }

    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

public struct ChatResult: Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var usage: TokenUsage
    public var stopReason: StopReason
    public var model: String
    /// The assistant turn to append to the conversation to continue it.
    public var message: ChatMessage

    public init(text: String, toolCalls: [ToolCall], usage: TokenUsage, stopReason: StopReason, model: String, message: ChatMessage) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
        self.model = model
        self.message = message
    }

    /// Builds the result and its assistant message from the parts every provider has.
    public init(model: String, text: String, toolCalls: [ToolCall], usage: TokenUsage, stopReason: StopReason, providerContent: ChatMessage.ProviderContent? = nil) {
        var content: [ContentPart] = []
        if !text.isEmpty { content.append(.text(text)) }
        content += toolCalls.map(ContentPart.toolCall)
        self.init(
            text: text, toolCalls: toolCalls, usage: usage,
            stopReason: toolCalls.isEmpty ? stopReason : .toolCalls, model: model,
            message: ChatMessage(role: .assistant, content: content, providerContent: providerContent))
    }
}

public enum ChatChunk: Sendable {
    case text(String)
    case toolCall(ToolCall)
    case done(ChatResult)
}

public struct ProviderCapabilities: Sendable, Hashable {
    public var streaming: Bool
    public var contextTokens: Int

    public init(streaming: Bool, contextTokens: Int) {
        self.streaming = streaming
        self.contextTokens = contextTokens
    }
}

/// A model behind a chat API.
public protocol Provider: Sendable {
    /// `anthropic`, `openai`, `gemini`, `openai-compatible`, `apple`.
    var name: String { get }
    var model: String { get }
    var capabilities: ProviderCapabilities { get }
    func chat(_ request: ChatRequest) async throws -> ChatResult
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error>
}

/// An HTTP or protocol error from a provider. The message never contains the API key.
public struct ProviderError: Error, CustomStringConvertible, Sendable {
    public let provider: String
    public let message: String
    public let status: Int?

    public init(provider: String, message: String, status: Int? = nil) {
        self.provider = provider
        self.message = Redaction.redactText(message)
        self.status = status
    }

    public var description: String { "\(provider): \(message)" }
}

/// One call that streams text to `onChunk` when the provider can stream and a callback is given, and
/// returns the final result either way.
public func complete(_ provider: any Provider, _ request: ChatRequest, onChunk: (@Sendable (String) -> Void)? = nil) async throws -> ChatResult {
    guard let onChunk, provider.capabilities.streaming else {
        let result = try await provider.chat(request)
        if let onChunk, !result.text.isEmpty { onChunk(result.text) }
        return result
    }
    var done: ChatResult?
    for try await chunk in provider.stream(request) {
        switch chunk {
        case .text(let delta): onChunk(delta)
        case .toolCall: break
        case .done(let result): done = result
        }
    }
    guard let done else { throw ProviderError(provider: provider.name, message: "the stream ended without a result") }
    return done
}
