import Foundation

/// Google Gemini through `generateContent` and `streamGenerateContent`, over plain HTTP.
public final class GeminiProvider: Provider {
    public let name = "gemini"
    public let model: String
    public let capabilities: ProviderCapabilities
    let baseURL: String
    let apiKey: String
    let maxOutputTokens: Int
    let retry: RetryOptions
    let transport: any HTTPTransport

    public init(configuration: AIConfiguration, transport: any HTTPTransport = URLSessionTransport()) throws {
        guard let apiKey = configuration.apiKey else {
            throw AIConfigurationError.missingAPIKey(provider: "gemini", environmentVariable: "GEMINI_API_KEY")
        }
        model = configuration.model
        self.apiKey = apiKey
        baseURL = configuration.baseURL ?? AIConfiguration.ProviderKind.gemini.defaultBaseURL!
        maxOutputTokens = configuration.maxOutputTokens
        retry = RetryOptions(maxRetries: configuration.maxRetries)
        self.transport = transport
        capabilities = ProviderCapabilities(tools: true, streaming: true, contextTokens: configuration.contextTokens ?? 1_048_576, jsonMode: true)
    }

    static let stopReasons: [String: StopReason] = [
        "STOP": .end, "MAX_TOKENS": .maxTokens, "SAFETY": .refusal, "RECITATION": .refusal, "PROHIBITED_CONTENT": .refusal, "BLOCKLIST": .refusal,
    ]

    /// Schema keywords Gemini's OpenAPI-subset `parameters` accepts.
    static let schemaKeys: Set<String> = [
        "type", "format", "description", "nullable", "enum", "properties", "required", "items",
        "minimum", "maximum", "minItems", "maxItems", "minLength", "maxLength", "pattern", "anyOf", "title",
    ]

    /// Reduces a JSON Schema to the subset Gemini function declarations accept.
    public static func geminiSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .array(let items): return .array(items.map(geminiSchema))
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, value) in object where schemaKeys.contains(key) {
                switch key {
                case "type":
                    if let types = value.arrayValue?.compactMap(\.stringValue) {
                        let concrete = types.filter { $0 != "null" }
                        out["type"] = .string(concrete.first ?? "string")
                        if concrete.count < types.count { out["nullable"] = true }
                    } else {
                        out["type"] = value
                    }
                case "properties":
                    out["properties"] = .object((value.objectValue ?? [:]).mapValues(geminiSchema))
                case "items", "anyOf":
                    out[key] = geminiSchema(value)
                default:
                    out[key] = value
                }
            }
            return .object(out)
        default:
            return schema
        }
    }

    static func contents(_ messages: [ChatMessage]) -> [JSONValue] {
        messages.map { message in
            if message.role == .assistant, let provided = message.providerContent, provided.provider == "gemini" {
                return ["role": "model", "parts": provided.content]
            }
            let parts: [JSONValue] = message.content.map { part in
                switch part {
                case .text(let text): ["text": .string(text)]
                case .toolCall(let call): ["functionCall": ["name": .string(call.name), "args": call.arguments]]
                case .toolResult(_, let name, let content, let isError):
                    ["functionResponse": ["name": .string(name), "response": isError ? ["error": .string(content)] : ["content": .string(content)]]]
                }
            }
            return ["role": .string(message.role == .assistant ? "model" : "user"), "parts": .array(parts)]
        }
    }

    func body(_ request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "contents": .array(Self.contents(request.messages)),
            "generationConfig": ["maxOutputTokens": .number(Double(request.maxOutputTokens ?? maxOutputTokens))],
        ]
        if let system = request.system { body["systemInstruction"] = ["parts": [["text": .string(system)]]] }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": .array(request.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "parameters": Self.geminiSchema($0.inputSchema)]
            })]]
        }
        return .object(body)
    }

    func httpRequest(_ request: ChatRequest, stream: Bool) throws -> HTTPRequest {
        let method = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "\(baseURL)/models/\(encodedModel):\(method)") else {
            throw AIConfigurationError.invalid(key: "baseUrl", expected: "a URL")
        }
        return HTTPRequest(url: url, headers: ["x-goog-api-key": apiKey], body: body(request).encoded())
    }

    func result(model: String?, parts: [JSONValue], finish: String?, meta: JSONValue?) -> ChatResult {
        let text = parts.compactMap { $0["thought"] == .bool(true) ? nil : $0["text"]?.stringValue }.joined()
        let toolCalls = parts.enumerated().compactMap { index, part -> ToolCall? in
            guard let call = part["functionCall"] else { return nil }
            return ToolCall(id: call["id"]?.stringValue ?? "call_\(index)", name: call["name"]?.stringValue ?? "", arguments: call["args"] ?? .object([:]))
        }
        return ChatResult(
            model: model ?? self.model, text: text, toolCalls: toolCalls,
            usage: TokenUsage(
                inputTokens: meta?["promptTokenCount"]?.intValue ?? 0,
                outputTokens: (meta?["candidatesTokenCount"]?.intValue ?? 0) + (meta?["thoughtsTokenCount"]?.intValue ?? 0),
                cacheReadTokens: meta?["cachedContentTokenCount"]?.intValue),
            stopReason: finish.flatMap { Self.stopReasons[$0] } ?? .other,
            providerContent: .init(provider: "gemini", content: .array(parts)))
    }

    public func chat(_ request: ChatRequest) async throws -> ChatResult {
        let response = try await HTTPClient.post(name, transport: transport, request: try httpRequest(request, stream: false), retry: retry)
        guard let json = try? JSONValue(data: response.body) else { throw ProviderError(provider: name, message: "the response is not JSON") }
        let candidate = json["candidates"]?[0]
        return result(model: json["modelVersion"]?.stringValue, parts: candidate?["content"]?["parts"]?.arrayValue ?? [],
                      finish: candidate?["finishReason"]?.stringValue, meta: json["usageMetadata"])
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try await HTTPClient.stream(name, transport: transport, request: try httpRequest(request, stream: true), retry: retry)
                    var parts: [JSONValue] = []
                    var finish: String?
                    var meta: JSONValue?
                    var model: String?
                    var calls = 0
                    for try await event in SSE.events(http.body) {
                        let data = try SSE.parse(name, event.data)
                        if let error = data["error"], !error.isNull {
                            throw ProviderError(provider: name, message: error["message"]?.stringValue ?? "stream error")
                        }
                        model = data["modelVersion"]?.stringValue ?? model
                        if let used = data["usageMetadata"] { meta = used }
                        let candidate = data["candidates"]?[0]
                        finish = candidate?["finishReason"]?.stringValue ?? finish
                        for part in candidate?["content"]?["parts"]?.arrayValue ?? [] {
                            parts.append(part)
                            if let text = part["text"]?.stringValue, !text.isEmpty, part["thought"] != .bool(true) {
                                continuation.yield(.text(text))
                            }
                            if let call = part["functionCall"] {
                                let id = call["id"]?.stringValue ?? "call_\(calls)"
                                calls += 1
                                continuation.yield(.toolCall(ToolCall(id: id, name: call["name"]?.stringValue ?? "", arguments: call["args"] ?? .object([:]))))
                            }
                        }
                    }
                    continuation.yield(.done(result(model: model, parts: parts, finish: finish, meta: meta)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
