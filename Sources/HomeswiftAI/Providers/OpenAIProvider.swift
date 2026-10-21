import Foundation

/// OpenAI over plain HTTP: the Responses API (`POST /responses`, the default for OpenAI, which newer
/// models need for tool calling) or Chat Completions (`POST /chat/completions`, the default for
/// OpenAI-compatible servers such as Ollama, LM Studio and vLLM, reached through `baseUrl`).
public final class OpenAIProvider: Provider {
    public let name: String
    public let model: String
    public let capabilities: ProviderCapabilities
    public let api: AIConfiguration.OpenAIAPI
    let url: URL
    let apiKey: String?
    let maxOutputTokens: Int
    let effort: EffortLevel?
    let retry: RetryOptions
    let transport: any HTTPTransport
    var isOpenAI: Bool { name == "openai" }

    public init(configuration: AIConfiguration, transport: any HTTPTransport = URLSessionTransport()) throws {
        let kind = configuration.provider == .openai ? AIConfiguration.ProviderKind.openai : .openaiCompatible
        name = kind.rawValue
        if kind == .openai, configuration.apiKey == nil {
            throw AIConfigurationError.missingAPIKey(provider: "openai", environmentVariable: "OPENAI_API_KEY")
        }
        model = configuration.model
        apiKey = configuration.apiKey
        api = configuration.openaiAPI ?? (kind == .openai ? .responses : .chat)
        let base = configuration.baseURL ?? kind.defaultBaseURL!
        guard let url = URL(string: "\(base)/\(api == .responses ? "responses" : "chat/completions")") else {
            throw AIConfigurationError.invalid(key: "baseUrl", expected: "a URL")
        }
        self.url = url
        maxOutputTokens = configuration.maxOutputTokens
        effort = configuration.effort
        retry = RetryOptions(maxRetries: configuration.maxRetries)
        self.transport = transport
        capabilities = ProviderCapabilities(
            tools: true, streaming: true,
            contextTokens: configuration.contextTokens ?? (kind == .openai ? 128_000 : 8192),
            jsonMode: kind == .openai)
    }

    // MARK: Messages

    static func chatMessages(system: String?, messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        if let system { out.append(["role": "system", "content": .string(system)]) }
        for message in messages {
            let text = message.text
            if message.role == .assistant {
                var item: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
                let calls = message.toolCalls
                if !calls.isEmpty {
                    item["tool_calls"] = .array(calls.map {
                        ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments.text())]]
                    })
                }
                out.append(.object(item))
                continue
            }
            for part in message.content {
                if case .toolResult(let id, _, let content, let isError) = part {
                    out.append(["role": "tool", "tool_call_id": .string(id), "content": .string(isError ? "Error: \(content)" : content)])
                }
            }
            if !text.isEmpty { out.append(["role": "user", "content": .string(text)]) }
        }
        return out
    }

    /// The conversation as Responses API input items. An assistant turn this provider produced is replayed
    /// verbatim: its reasoning items carry the encrypted reasoning that `store: false` needs for a tool loop.
    func responsesInput(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages {
            if message.role == .assistant, let provided = message.providerContent, provided.provider == name, let items = provided.content.arrayValue {
                out += items
                continue
            }
            let text = message.text
            if message.role == .assistant {
                if !text.isEmpty { out.append(["role": "assistant", "content": .string(text)]) }
                for call in message.toolCalls {
                    out.append(["type": "function_call", "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments.text())])
                }
                continue
            }
            for part in message.content {
                if case .toolResult(let id, _, let content, let isError) = part {
                    out.append(["type": "function_call_output", "call_id": .string(id), "output": .string(isError ? "Error: \(content)" : content)])
                }
            }
            if !text.isEmpty { out.append(["role": "user", "content": .string(text)]) }
        }
        return out
    }

    // MARK: Request bodies

    func body(_ request: ChatRequest, stream: Bool) -> JSONValue {
        api == .responses ? responsesBody(request, stream: stream) : chatBody(request, stream: stream)
    }

    private func responsesBody(_ request: ChatRequest, stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(responsesInput(request.messages)),
            "max_output_tokens": .number(Double(request.maxOutputTokens ?? maxOutputTokens)),
            // Nothing is kept on OpenAI's side; each request carries the whole conversation.
            "store": false,
        ]
        if let system = request.system { body["instructions"] = .string(system) }
        // Reasoning models: get the reasoning back encrypted so a tool loop can replay it without `store`.
        if isOpenAI { body["include"] = ["reasoning.encrypted_content"] }
        if let effort = request.effort ?? effort { body["reasoning"] = ["effort": .string(effort.rawValue)] }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema]
            })
        }
        if stream { body["stream"] = true }
        return .object(body)
    }

    private func chatBody(_ request: ChatRequest, stream: Bool) -> JSONValue {
        let maxTokens = JSONValue.number(Double(request.maxOutputTokens ?? maxOutputTokens))
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(Self.chatMessages(system: request.system, messages: request.messages)),
        ]
        // OpenAI deprecated max_tokens for newer models; compatible servers mostly only know max_tokens.
        body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
        if isOpenAI, let effort = request.effort ?? effort { body["reasoning_effort"] = .string(effort.rawValue) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema]]
            })
        }
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        return .object(body)
    }

    func httpRequest(_ request: ChatRequest, stream: Bool) -> HTTPRequest {
        HTTPRequest(url: url, headers: apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:], body: body(request, stream: stream).encoded())
    }

    // MARK: Responses API

    static let incompleteReasons: [String: StopReason] = ["max_output_tokens": .maxTokens, "content_filter": .refusal]

    func fromResponse(_ response: JSONValue) throws -> ChatResult {
        let output = response["output"]?.arrayValue ?? []
        var text = ""
        var refusal = ""
        var toolCalls: [ToolCall] = []
        for (index, item) in output.enumerated() {
            switch item["type"]?.stringValue {
            case "message":
                for part in item["content"]?.arrayValue ?? [] {
                    if part["type"] == "output_text" { text += part["text"]?.stringValue ?? "" }
                    if part["type"] == "refusal" { refusal += part["refusal"]?.stringValue ?? "" }
                }
            case "function_call":
                toolCalls.append(ToolCall(
                    id: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "call_\(index)",
                    name: item["name"]?.stringValue ?? "",
                    arguments: try parseArguments(name, item["arguments"]?.stringValue)))
            default:
                break
            }
        }
        let status = response["status"]?.stringValue
        let stopReason: StopReason
        if !toolCalls.isEmpty {
            stopReason = .toolCalls
        } else if status == "incomplete" {
            stopReason = Self.incompleteReasons[response["incomplete_details"]?["reason"]?.stringValue ?? ""] ?? .other
        } else if !refusal.isEmpty, text.isEmpty {
            stopReason = .refusal
        } else {
            stopReason = status == "completed" ? .end : .other
        }
        let usage = response["usage"]
        return ChatResult(
            model: response["model"]?.stringValue ?? model, text: text.isEmpty ? refusal : text, toolCalls: toolCalls,
            usage: TokenUsage(
                inputTokens: usage?["input_tokens"]?.intValue ?? 0, outputTokens: usage?["output_tokens"]?.intValue ?? 0,
                cacheReadTokens: usage?["input_tokens_details"]?["cached_tokens"]?.intValue),
            stopReason: stopReason, providerContent: .init(provider: name, content: .array(output)))
    }

    private func failure(_ response: JSONValue?, _ fallback: String) -> ProviderError {
        ProviderError(provider: name, message: response?["error"]?["message"]?.stringValue ?? fallback)
    }

    // MARK: Chat Completions

    static let chatStopReasons: [String: StopReason] = [
        "stop": .end, "tool_calls": .toolCalls, "function_call": .toolCalls, "length": .maxTokens, "content_filter": .refusal,
    ]

    func fromCompletion(model: String?, text: String, toolCalls: [ToolCall], finish: String?, usage: JSONValue?) -> ChatResult {
        ChatResult(
            model: model ?? self.model, text: text, toolCalls: toolCalls,
            usage: TokenUsage(
                inputTokens: usage?["prompt_tokens"]?.intValue ?? 0, outputTokens: usage?["completion_tokens"]?.intValue ?? 0,
                cacheReadTokens: usage?["prompt_tokens_details"]?["cached_tokens"]?.intValue),
            stopReason: finish.flatMap { Self.chatStopReasons[$0] } ?? .other)
    }

    // MARK: Calls

    public func chat(_ request: ChatRequest) async throws -> ChatResult {
        let response = try await HTTPClient.post(name, transport: transport, request: httpRequest(request, stream: false), retry: retry)
        guard let json = try? JSONValue(data: response.body) else { throw ProviderError(provider: name, message: "the response is not JSON") }
        if api == .responses {
            if json["status"] == "failed" || json["error"] != nil, json["error"]?.isNull != true { throw failure(json, "response failed") }
            guard json["output"]?.arrayValue != nil else { throw ProviderError(provider: name, message: "response has no output") }
            return try fromResponse(json)
        }
        guard let choice = json["choices"]?[0], let message = choice["message"] else {
            throw ProviderError(provider: name, message: "response has no choices")
        }
        let toolCalls = try (message["tool_calls"]?.arrayValue ?? []).enumerated().map { index, call in
            ToolCall(id: call["id"]?.stringValue ?? "call_\(index)", name: call["function"]?["name"]?.stringValue ?? "",
                     arguments: try parseArguments(name, call["function"]?["arguments"]?.stringValue))
        }
        return fromCompletion(model: json["model"]?.stringValue, text: message["content"]?.stringValue ?? "", toolCalls: toolCalls,
                              finish: choice["finish_reason"]?.stringValue, usage: json["usage"])
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try await HTTPClient.stream(name, transport: transport, request: httpRequest(request, stream: true), retry: retry)
                    let result = api == .responses ? try await streamResponses(http, continuation) : try await streamCompletions(http, continuation)
                    for call in result.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamResponses(_ http: HTTPStream, _ continuation: AsyncThrowingStream<ChatChunk, any Error>.Continuation) async throws -> ChatResult {
        var text = ""
        var model = self.model
        var final: JSONValue?
        var calls: [Int: [String: JSONValue]] = [:]
        for try await event in SSE.events(http.body) {
            if event.data == "[DONE]" { break }
            let data = try SSE.parse(name, event.data)
            let index = data["output_index"]?.intValue ?? -1
            switch data["type"]?.stringValue {
            case "response.created", "response.in_progress":
                model = data["response"]?["model"]?.stringValue ?? model
            case "response.output_text.delta":
                if let delta = data["delta"]?.stringValue, !delta.isEmpty {
                    text += delta
                    continuation.yield(.text(delta))
                }
            case "response.output_item.added", "response.output_item.done":
                if let item = data["item"]?.objectValue, item["type"] == "function_call" {
                    calls[index] = (calls[index] ?? ["arguments": ""]).merging(item) { $1 }
                }
            case "response.function_call_arguments.delta":
                if var call = calls[index] {
                    call["arguments"] = .string((call["arguments"]?.stringValue ?? "") + (data["delta"]?.stringValue ?? ""))
                    calls[index] = call
                }
            case "response.function_call_arguments.done":
                if var call = calls[index], let arguments = data["arguments"]?.stringValue {
                    call["arguments"] = .string(arguments)
                    calls[index] = call
                }
            case "response.completed", "response.incomplete":
                final = data["response"]
            case "response.failed":
                throw failure(data["response"], "response failed")
            case "error":
                throw ProviderError(provider: name, message: data["message"]?.stringValue ?? data["error"]?["message"]?.stringValue ?? "stream error")
            default:
                break
            }
        }
        // A stream cut short of `response.completed` still yields what arrived.
        var arrived: [JSONValue] = []
        if !text.isEmpty { arrived.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": .string(text)]]]) }
        arrived += calls.keys.sorted().map { .object(calls[$0]!) }
        var response = final?.objectValue ?? [:]
        if response["output"]?.arrayValue == nil {
            response["output"] = .array(arrived)
            response["model"] = response["model"] ?? .string(model)
        }
        return try fromResponse(.object(response))
    }

    private func streamCompletions(_ http: HTTPStream, _ continuation: AsyncThrowingStream<ChatChunk, any Error>.Continuation) async throws -> ChatResult {
        var text = ""
        var finish: String?
        var usage: JSONValue?
        var model: String?
        var pending: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await event in SSE.events(http.body) {
            if event.data == "[DONE]" { break }
            let data = try SSE.parse(name, event.data)
            if let error = data["error"], !error.isNull {
                throw ProviderError(provider: name, message: error["message"]?.stringValue ?? "stream error")
            }
            model = data["model"]?.stringValue ?? model
            if let used = data["usage"], !used.isNull { usage = used }
            guard let choice = data["choices"]?[0] else { continue }
            finish = choice["finish_reason"]?.stringValue ?? finish
            if let delta = choice["delta"]?["content"]?.stringValue, !delta.isEmpty {
                text += delta
                continuation.yield(.text(delta))
            }
            for call in choice["delta"]?["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? pending.count
                var entry = pending[index] ?? (id: call["id"]?.stringValue ?? "call_\(index)", name: "", arguments: "")
                if let id = call["id"]?.stringValue { entry.id = id }
                entry.name += call["function"]?["name"]?.stringValue ?? ""
                entry.arguments += call["function"]?["arguments"]?.stringValue ?? ""
                pending[index] = entry
            }
        }
        let toolCalls = try pending.keys.sorted().map { index in
            let entry = pending[index]!
            return ToolCall(id: entry.id, name: entry.name, arguments: try parseArguments(name, entry.arguments))
        }
        return fromCompletion(model: model, text: text, toolCalls: toolCalls, finish: finish, usage: usage)
    }
}
