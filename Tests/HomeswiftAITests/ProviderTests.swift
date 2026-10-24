import Foundation
import Testing

@testable import HomeswiftAI

@Suite(.timeLimit(.minutes(1)))
struct AnthropicProviderTests {
    static let reply = """
        {"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_1","name":"get_state","input":{"id":"lamp"}}],"usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":100,"cache_read_input_tokens":50}}
        """

    @Test func buildsTheRequest() async throws {
        let transport = FakeTransport(json: Self.reply)
        let provider = try anthropic(transport, effort: .high)
        let tool = ToolDefinition(name: "get_state", description: "Reads", inputSchema: ["type": "object", "properties": ["id": ["type": "string"]]])
        let request = ChatRequest(system: "Be brief", messages: [.user("Is the lamp on?")], tools: [tool], maxOutputTokens: 500)
        let result = try await provider.chat(request)

        let body = try transport.body()
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["max_tokens"] == 500)
        #expect(body["system"]?[0]?["text"] == "Be brief")
        #expect(body["system"]?[0]?["cache_control"] == ["type": "ephemeral"])
        #expect(body["tools"]?[0]?["name"] == "get_state")
        #expect(body["tools"]?[0]?["cache_control"] == ["type": "ephemeral"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["output_config"] == ["effort": "high"])
        #expect(body["fallbacks"] == "default")
        #expect(body["thinking"] == nil)
        #expect(body["messages"] == [["role": "user", "content": [["type": "text", "text": "Is the lamp on?"]]]])
        let headers = transport.headers()
        #expect(headers["x-api-key"] == "sk-ant-test-key-0123456789")
        #expect(headers["anthropic-version"] == "2023-06-01")
        #expect(headers["anthropic-beta"] == "server-side-fallback-2026-07-01")

        #expect(result.text == "Checking.")
        #expect(result.toolCalls == [ToolCall(id: "toolu_1", name: "get_state", arguments: ["id": "lamp"])])
        #expect(result.stopReason == .toolCalls)
        #expect(result.usage == TokenUsage(inputTokens: 160, outputTokens: 4, cacheReadTokens: 50, cacheWriteTokens: 100))
        #expect(result.message.providerContent?.provider == "anthropic")
        #expect(result.message.providerContent?.content[1]?["type"] == "tool_use")
    }

    @Test func replaysProviderContentAndToolResults() async throws {
        let transport = FakeTransport(json: #"{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"On."}],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        let provider = try anthropic(transport, model: "claude-haiku-5-5", promptCaching: false)
        let turn = ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "t1", name: "f", arguments: [:]))],
                               providerContent: .init(provider: "anthropic", content: [["type": "thinking", "thinking": "hm", "signature": "sig"], ["type": "tool_use", "id": "t1", "name": "f", "input": [:]]]))
        let result = try await provider.chat(ChatRequest(messages: [
            .user("q"), turn, ChatMessage(role: .user, content: [.toolResult(toolCallID: "t1", name: "f", content: "boom", isError: true)]),
        ]))
        let body = try transport.body()
        #expect(body["messages"]?[1]?["content"]?[0]?["type"] == "thinking")
        #expect(body["messages"]?[2]?["content"]?[0] == ["type": "tool_result", "tool_use_id": "t1", "content": "boom", "is_error": true])
        #expect(body["system"] == nil)
        #expect(body["cache_control"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(transport.headers()["anthropic-beta"] == nil)
        #expect(result.stopReason == .end)
        #expect(result.text == "On.")
    }

    @Test func streams() async throws {
        let events = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"f","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"1}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let transport = FakeTransport([.init(body: events)])
        let provider = try anthropic(transport)
        var deltas: [String] = []
        var calls: [ToolCall] = []
        var done: ChatResult?
        for try await chunk in provider.stream(ChatRequest(messages: [.user("hi")])) {
            switch chunk {
            case .text(let delta): deltas.append(delta)
            case .toolCall(let call): calls.append(call)
            case .done(let result): done = result
            }
        }
        #expect(try transport.body()["stream"] == true)
        #expect(deltas == ["Hel", "lo"])
        #expect(calls == [ToolCall(id: "t1", name: "f", arguments: ["a": 1])])
        #expect(done?.text == "Hello")
        #expect(done?.stopReason == .toolCalls)
        #expect(done?.usage == TokenUsage(inputTokens: 12, outputTokens: 9))
        #expect(done?.model == "claude-opus-5-5")
    }

    @Test func mapsErrorsAndRetries() async throws {
        let transport = FakeTransport([
            .init(status: 529, headers: ["retry-after-ms": "10"], body: #"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            .init(status: 200, body: #"{"model":"m","stop_reason":"refusal","content":[],"usage":{"input_tokens":1,"output_tokens":0}}"#),
        ])
        let provider = try anthropic(transport)
        let result = try await provider.chat(ChatRequest(messages: [.user("x")]))
        #expect(result.stopReason == .refusal)
        #expect(transport.count == 2)

        let unauthorized = FakeTransport([.init(status: 401, body: #"{"error":{"message":"invalid x-api-key sk-ant-abcdefghijklmnopqrstu"}}"#)])
        do {
            _ = try await anthropic(unauthorized).chat(ChatRequest(messages: [.user("x")]))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 401)
            #expect(error.message.contains("HTTP 401"))
            #expect(!error.message.contains("abcdefghijklmnopqrstu"))
        }
        #expect(unauthorized.count == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OpenAIProviderTests {
    func provider(_ transport: FakeTransport, api: AIConfiguration.OpenAIAPI? = nil, compatible: Bool = false) throws -> OpenAIProvider {
        var configuration = AIConfiguration(provider: compatible ? .openaiCompatible : .openai, apiKey: compatible ? nil : "sk-test")
        configuration.openaiAPI = api
        configuration.effort = .low
        return try OpenAIProvider(configuration: configuration, transport: transport)
    }

    @Test func responsesAPI() async throws {
        let transport = FakeTransport(json: """
            {"status":"completed","model":"gpt-6.1-sol","output":[{"type":"reasoning","id":"rs","encrypted_content":"x"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]},{"type":"function_call","call_id":"c1","name":"f","arguments":"{\\"a\\":1}"}],"usage":{"input_tokens":5,"output_tokens":2,"input_tokens_details":{"cached_tokens":3}}}
            """)
        let p = try provider(transport)
        let result = try await p.chat(ChatRequest(system: "sys", messages: [.user("q")], tools: [ToolDefinition(name: "f", inputSchema: ["type": "object"])]))
        let body = try transport.body()
        #expect(transport.headers()["Authorization"] == "Bearer sk-test")
        #expect(body["instructions"] == "sys")
        #expect(body["store"] == false)
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["reasoning"] == ["effort": "low"])
        #expect(body["tools"]?[0] == ["type": "function", "name": "f", "description": "", "parameters": ["type": "object"]])
        #expect(body["input"] == [["role": "user", "content": "q"]])
        #expect(result.text == "Hi")
        #expect(result.toolCalls == [ToolCall(id: "c1", name: "f", arguments: ["a": 1])])
        #expect(result.usage == TokenUsage(inputTokens: 5, outputTokens: 2, cacheReadTokens: 3))
        #expect(result.message.providerContent?.content.arrayValue?.count == 3)

        // The next turn replays the reasoning item and sends the tool result.
        let replay = FakeTransport(json: #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"long"}]}]}"#)
        let next = try await provider(replay).chat(ChatRequest(messages: [.user("q"), result.message, ChatMessage(role: .user, content: [.toolResult(toolCallID: "c1", name: "f", content: "42", isError: false)])]))
        let input = try replay.body()["input"]?.arrayValue ?? []
        #expect(input[1]["type"] == "reasoning")
        #expect(input[4] == ["type": "function_call_output", "call_id": "c1", "output": "42"])
        #expect(next.stopReason == .maxTokens)
    }

    @Test func chatCompletions() async throws {
        let transport = FakeTransport(json: """
            {"model":"llama3.1","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":3}}
            """)
        let p = try provider(transport, compatible: true)
        #expect(p.api == .chat)
        let result = try await p.chat(ChatRequest(system: "sys", messages: [
            .user("q"), ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "c0", name: "g", arguments: ["x": 1]))]),
            ChatMessage(role: .user, content: [.toolResult(toolCallID: "c0", name: "g", content: "ok", isError: false)]),
        ]))
        let body = try transport.body()
        #expect(transport.headers()["Authorization"] == nil)
        #expect(body["max_tokens"] == 2048)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["reasoning_effort"] == nil)
        let messages = body["messages"]?.arrayValue ?? []
        #expect(messages[0] == ["role": "system", "content": "sys"])
        #expect(messages[2]["tool_calls"]?[0]?["function"]?["arguments"] == "{\"x\":1}")
        #expect(messages[3] == ["role": "tool", "tool_call_id": "c0", "content": "ok"])
        #expect(result.toolCalls == [ToolCall(id: "c1", name: "f", arguments: [:])])
        #expect(result.usage == TokenUsage(inputTokens: 7, outputTokens: 3))
        #expect(result.model == "llama3.1")
    }

    @Test func streamsBothAPIs() async throws {
        let responses = sse([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6.1-sol"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","output_index":0,"delta":"He"}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","output_index":0,"delta":"y"}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"f","arguments":""}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"a\":"}"#),
            ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"a\":2}"}"#),
            ("response.completed", #"{"type":"response.completed","response":{"status":"completed","model":"gpt-6.1-sol","output":[{"type":"message","content":[{"type":"output_text","text":"Hey"}]},{"type":"function_call","call_id":"c1","name":"f","arguments":"{\"a\":2}"}],"usage":{"input_tokens":1,"output_tokens":2}}}"#),
        ]) + "data: [DONE]\n\n"
        var deltas: [String] = []
        var done: ChatResult?
        for try await chunk in try provider(FakeTransport([.init(body: responses)])).stream(ChatRequest(messages: [.user("q")])) {
            if case .text(let delta) = chunk { deltas.append(delta) }
            if case .done(let result) = chunk { done = result }
        }
        #expect(deltas == ["He", "y"])
        #expect(done?.text == "Hey")
        #expect(done?.toolCalls == [ToolCall(id: "c1", name: "f", arguments: ["a": 2])])
        #expect(done?.usage.outputTokens == 2)

        let completions = [
            #"{"model":"llama3.1","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{\"a\""}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":3}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":6}}"#,
        ].map { "data: \($0)\n" }.joined(separator: "\n") + "\ndata: [DONE]\n"
        var chatDone: ChatResult?
        for try await chunk in try provider(FakeTransport([.init(body: completions)]), compatible: true).stream(ChatRequest(messages: [.user("q")])) {
            if case .done(let result) = chunk { chatDone = result }
        }
        #expect(chatDone?.text == "Hi")
        #expect(chatDone?.toolCalls == [ToolCall(id: "c1", name: "f", arguments: ["a": 3])])
        #expect(chatDone?.usage == TokenUsage(inputTokens: 4, outputTokens: 6))
        #expect(chatDone?.stopReason == .toolCalls)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GeminiProviderTests {
    @Test func buildsAndParses() async throws {
        let transport = FakeTransport(json: """
            {"modelVersion":"gemini-3.8-flash","candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"Sure"},{"functionCall":{"name":"f","args":{"a":1}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":2,"thoughtsTokenCount":5,"cachedContentTokenCount":1}}
            """)
        let provider = try GeminiProvider(configuration: AIConfiguration(provider: .gemini, apiKey: "g-key"), transport: transport)
        let tool = ToolDefinition(name: "f", description: "d", inputSchema: ["type": "object", "additionalProperties": false, "properties": ["x": ["type": ["string", "null"], "default": 1]]])
        let result = try await provider.chat(ChatRequest(system: "sys", messages: [.user("q")], tools: [tool]))
        let request = transport.requests[0]
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(request.headers["x-goog-api-key"] == "g-key")
        let body = try transport.body()
        #expect(body["systemInstruction"] == ["parts": [["text": "sys"]]])
        #expect(body["tools"]?[0]?["functionDeclarations"]?[0]?["parameters"] == ["type": "object", "properties": ["x": ["type": "string", "nullable": true]]])
        #expect(body["generationConfig"] == ["maxOutputTokens": 2048])
        #expect(result.text == "Sure")
        #expect(result.toolCalls == [ToolCall(id: "call_2", name: "f", arguments: ["a": 1])])
        #expect(result.usage == TokenUsage(inputTokens: 8, outputTokens: 7, cacheReadTokens: 1))
        #expect(result.stopReason == .toolCalls)
    }

    @Test func streams() async throws {
        let events = [
            #"{"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"lo"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}"#,
        ].map { "data: \($0)\n" }.joined(separator: "\n") + "\n"
        let transport = FakeTransport([.init(body: events)])
        let provider = try GeminiProvider(configuration: AIConfiguration(provider: .gemini, apiKey: "g"), transport: transport)
        var text = ""
        var done: ChatResult?
        for try await chunk in provider.stream(ChatRequest(messages: [.user("q")])) {
            if case .text(let delta) = chunk { text += delta }
            if case .done(let result) = chunk { done = result }
        }
        #expect(transport.requests[0].url.absoluteString.hasSuffix(":streamGenerateContent?alt=sse"))
        #expect(text == "Hello")
        #expect(done?.text == "Hello")
        #expect(done?.stopReason == .end)
        #expect(done?.usage == TokenUsage(inputTokens: 3, outputTokens: 2))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AssistantServiceTests {
    @Test func asksWithRedactionAndStreaming() async throws {
        let provider = FakeProvider(replies: ["Turn it off and on"])
        let assistant = AssistantService(provider: provider, logger: testLogger).withContext("Plugin X is asking")
        let chunks = ChunkCollector()
        let reply = try await assistant.ask("My token=abc123 light is dead", context: "password: hunter2", history: [.user("earlier"), .assistant("ok")]) { chunks.add($0) }
        #expect(reply.text == "Turn it off and on")
        #expect(reply.model == "fake-1")
        #expect(chunks.text.trimmingCharacters(in: .whitespaces) == "Turn it off and on")
        let request = try #require(provider.lastRequest)
        #expect(request.system?.hasPrefix(Prompts.Ask.system) == true)
        #expect(request.system?.hasSuffix("Plugin X is asking") == true)
        #expect(request.messages.count == 3)
        let user = request.messages[2].text
        #expect(user.contains("token=__REDACTED__"))
        #expect(user.contains("password: __REDACTED__"))
        #expect(!user.contains("hunter2"))
        #expect(user.contains("<untrusted-data>"))
        #expect(await assistant.usage.total.requests == 1)
    }

    @Test func explainsAndDiagnoses() async throws {
        let provider = FakeProvider(replies: ["It is offline", "Summary: fine"], streaming: false)
        let assistant = AssistantService(provider: provider, logger: testLogger)
        let explained = try await assistant.explain(error: "ECONNREFUSED 192.168.1.5", context: nil, device: ["mac": "AA", "apiKey": "secret"], pluginName: "Elgato Key Lights")
        #expect(explained.text == "It is offline")
        let request = try #require(provider.lastRequest)
        #expect(request.messages[0].text.contains("from the Homeswift plugin Elgato Key Lights"))
        #expect(request.messages[0].text.contains("__REDACTED__"))
        #expect(!request.messages[0].text.contains("secret"))

        let diagnosed = try await assistant.diagnose(logs: "\u{1B}[31m[Elgato] error token=abc\u{1B}[0m\nfine", focus: "Elgato")
        #expect(diagnosed.text == "Summary: fine")
        let logs = try #require(provider.lastRequest).messages[0].text
        #expect(logs.contains("Focus on: Elgato."))
        #expect(logs.contains("[Elgato] error token=__REDACTED__"))
        #expect(!logs.contains("\u{1B}"))
    }

    @Test func generatesConfigurationAndRestoresSecrets() async throws {
        let provider = FakeProvider(replies: [
            "{\"config\": {\"platform\": \"Govee\"}}",
            "```json\n{\"config\": {\"platform\": \"Govee\", \"name\": \"Govee\", \"apiKey\": \"__REDACTED__\", \"refresh\": 30}, \"explanation\": \"Set refresh.\"}\n```",
        ])
        let assistant = AssistantService(provider: provider, logger: testLogger)
        let schema: JSONValue = [
            "pluginAlias": "Govee",
            "schema": ["type": "object", "properties": ["name": ["type": "string", "required": true], "apiKey": ["type": "string"], "refresh": ["type": "integer"]]],
        ]
        let current: JSONValue = ["platform": "Govee", "name": "Govee", "apiKey": "real-key", "refresh": 10]
        let suggestion = try await assistant.generateConfiguration(request: "poll every 30 s", schema: schema, current: current, pluginName: "Govee")
        #expect(suggestion.config["apiKey"] == "real-key")
        #expect(suggestion.config["refresh"] == 30)
        #expect(suggestion.explanation == "Set refresh.")
        #expect(provider.requests.count == 2)
        let first = provider.requests[0]
        #expect(first.system?.contains("\"required\":[\"config\",\"explanation\"]") == true)
        #expect(first.messages[0].text.contains("__REDACTED__"))
        #expect(!first.messages[0].text.contains("real-key"))
        #expect(provider.requests[1].messages.last?.text.contains("explanation is required") == true)
    }
}

final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = ""
    var text: String { lock.withLock { collected } }
    func add(_ delta: String) { lock.withLock { collected += delta } }
}

@Suite struct AppleProviderTests {
    @Test func reportsAvailability() async throws {
        let reason = AppleProvider.unavailabilityReason()
        #if os(macOS)
        if reason == nil {
            // Apple Intelligence is on: a real answer from the on-device model.
            let assistant = try AssistantService(configuration: AIConfiguration(provider: .apple), logger: testLogger)
            #expect(assistant.providerName == "apple")
            let reply = try await assistant.ask("Reply with the single word: ready")
            #expect(!reply.text.isEmpty)
        }
        #else
        #expect(reason != nil)
        #endif
    }
}
