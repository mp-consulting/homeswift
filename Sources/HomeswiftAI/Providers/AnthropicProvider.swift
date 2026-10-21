import Foundation

/// Claude through the Anthropic Messages API (`POST /v1/messages`), over plain HTTP.
public final class AnthropicProvider: Provider {
    public static let apiVersion = "2023-06-01"
    /// The `fallbacks: "default"` form, which routes a declined request by refusal category.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let name = "anthropic"
    public let model: String
    public let capabilities: ProviderCapabilities
    let url: URL
    let apiKey: String
    let maxOutputTokens: Int
    let effort: EffortLevel?
    let promptCaching: Bool
    let fallbacks: Bool
    let retry: RetryOptions
    let transport: any HTTPTransport

    public init(configuration: AIConfiguration, transport: any HTTPTransport = URLSessionTransport()) throws {
        guard let apiKey = configuration.apiKey else {
            throw AIConfigurationError.missingAPIKey(provider: "anthropic", environmentVariable: "ANTHROPIC_API_KEY")
        }
        guard let url = URL(string: "\(configuration.baseURL ?? AIConfiguration.ProviderKind.anthropic.defaultBaseURL!)/v1/messages") else {
            throw AIConfigurationError.invalid(key: "baseUrl", expected: "a URL")
        }
        model = configuration.model
        self.apiKey = apiKey
        self.url = url
        maxOutputTokens = configuration.maxOutputTokens
        effort = configuration.effort
        promptCaching = configuration.promptCaching
        fallbacks = configuration.fallbacks ?? Self.supportsFallbacks(model: configuration.model)
        retry = RetryOptions(maxRetries: configuration.maxRetries)
        self.transport = transport
        capabilities = ProviderCapabilities(
            tools: true, streaming: true,
            contextTokens: configuration.contextTokens ?? Self.contextTokens(model: configuration.model), jsonMode: false)
    }

    /// 200K for Haiku 4.5, 1M for the current generations.
    public static func contextTokens(model: String) -> Int {
        model.hasPrefix("claude-haiku-4") ? 200_000 : 1_000_000
    }

    /// The models that take `fallbacks: "default"`.
    static func supportsFallbacks(model: String) -> Bool {
        ["claude-fable-5", "claude-opus-5", "claude-sonnet-5-5"].contains { model.hasPrefix($0) }
    }

    // MARK: Request

    static let ephemeral: JSONValue = ["type": "ephemeral"]

    func body(_ request: ChatRequest, stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxOutputTokens ?? maxOutputTokens)),
            "messages": .array(request.messages.map(Self.apiMessage)),
        ]
        if let system = request.system {
            body["system"] = promptCaching ? [["type": "text", "text": .string(system), "cache_control": Self.ephemeral]] : .string(system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.enumerated().map { index, tool in
                var definition: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema]
                if promptCaching, index == request.tools.count - 1 { definition["cache_control"] = Self.ephemeral }
                return .object(definition)
            })
        }
        // Top-level automatic caching covers the growing conversation of an agent loop.
        if promptCaching { body["cache_control"] = Self.ephemeral }
        if let effort = request.effort ?? effort { body["output_config"] = ["effort": .string(effort.rawValue)] }
        if fallbacks { body["fallbacks"] = "default" }
        if stream { body["stream"] = true }
        return .object(body)
    }

    func httpRequest(_ request: ChatRequest, stream: Bool) -> HTTPRequest {
        var headers = ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
        if fallbacks { headers["anthropic-beta"] = Self.fallbackBeta }
        return HTTPRequest(url: url, headers: headers, body: body(request, stream: stream).encoded())
    }

    static func apiMessage(_ message: ChatMessage) -> JSONValue {
        if message.role == .assistant, let provided = message.providerContent, provided.provider == "anthropic" {
            return ["role": "assistant", "content": provided.content]
        }
        let content: [JSONValue] = message.content.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .toolCall(let call): ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": call.arguments]
            case .toolResult(let id, _, let result, let isError):
                isError
                    ? ["type": "tool_result", "tool_use_id": .string(id), "content": .string(result), "is_error": true]
                    : ["type": "tool_result", "tool_use_id": .string(id), "content": .string(result)]
            }
        }
        return ["role": .string(message.role.rawValue), "content": .array(content)]
    }

    // MARK: Response

    static let stopReasons: [String: StopReason] = [
        "end_turn": .end, "stop_sequence": .end, "tool_use": .toolCalls, "max_tokens": .maxTokens, "refusal": .refusal,
    ]

    /// Claude reports uncached, cache-written and cache-read input separately; `inputTokens` is their sum.
    static func usage(_ value: JSONValue?) -> TokenUsage {
        let read = value?["cache_read_input_tokens"]?.intValue
        let write = value?["cache_creation_input_tokens"]?.intValue
        return TokenUsage(
            inputTokens: (value?["input_tokens"]?.intValue ?? 0) + (write ?? 0) + (read ?? 0),
            outputTokens: value?["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: read, cacheWriteTokens: write)
    }

    func result(content: [JSONValue], stopReason: String?, usage: JSONValue?, model: String?) -> ChatResult {
        let text = content.compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined()
        let toolCalls = content.compactMap { block -> ToolCall? in
            guard block["type"] == "tool_use" else { return nil }
            return ToolCall(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", arguments: block["input"] ?? .object([:]))
        }
        return ChatResult(
            model: model ?? self.model, text: text, toolCalls: toolCalls, usage: Self.usage(usage),
            stopReason: stopReason.flatMap { Self.stopReasons[$0] } ?? .other,
            providerContent: .init(provider: "anthropic", content: .array(content)))
    }

    public func chat(_ request: ChatRequest) async throws -> ChatResult {
        let response = try await HTTPClient.post(name, transport: transport, request: httpRequest(request, stream: false), retry: retry)
        let json: JSONValue
        do {
            json = try JSONValue(data: response.body)
        } catch {
            throw ProviderError(provider: name, message: "the response is not JSON")
        }
        return result(content: json["content"]?.arrayValue ?? [], stopReason: json["stop_reason"]?.stringValue, usage: json["usage"], model: json["model"]?.stringValue)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try await HTTPClient.stream(name, transport: transport, request: httpRequest(request, stream: true), retry: retry)
                    var blocks: [Int: [String: JSONValue]] = [:]
                    var partialJSON: [Int: String] = [:]
                    var usage: JSONValue = .object([:])
                    var stopReason: String?
                    var model: String?
                    for try await event in SSE.events(http.body) {
                        let data = try SSE.parse(name, event.data)
                        let index = data["index"]?.intValue ?? 0
                        switch data["type"]?.stringValue {
                        case "message_start":
                            usage = data["message"]?["usage"] ?? usage
                            model = data["message"]?["model"]?.stringValue
                        case "content_block_start":
                            var block = data["content_block"]?.objectValue ?? [:]
                            if block["type"] == "tool_use" { block["input"] = .object([:]) }
                            blocks[index] = block
                            partialJSON[index] = ""
                        case "content_block_delta":
                            guard var block = blocks[index], let delta = data["delta"] else { break }
                            switch delta["type"]?.stringValue {
                            case "text_delta":
                                let text = delta["text"]?.stringValue ?? ""
                                block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                                continuation.yield(.text(text))
                            case "input_json_delta":
                                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
                            case "thinking_delta":
                                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
                            case "signature_delta":
                                block["signature"] = delta["signature"] ?? .null
                            default:
                                break
                            }
                            blocks[index] = block
                        case "content_block_stop":
                            if var block = blocks[index], block["type"] == "tool_use" {
                                let arguments = try parseArguments(name, partialJSON[index])
                                block["input"] = arguments
                                blocks[index] = block
                                continuation.yield(.toolCall(ToolCall(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", arguments: arguments)))
                            }
                        case "message_delta":
                            stopReason = data["delta"]?["stop_reason"]?.stringValue ?? stopReason
                            if let more = data["usage"]?.objectValue {
                                usage = .object((usage.objectValue ?? [:]).merging(more) { $1 })
                            }
                        case "error":
                            throw ProviderError(provider: name, message: data["error"]?["message"]?.stringValue ?? "stream error")
                        default:
                            break
                        }
                    }
                    let content = blocks.keys.sorted().map { JSONValue.object(blocks[$0]!) }
                    continuation.yield(.done(result(content: content, stopReason: stopReason, usage: usage, model: model)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
