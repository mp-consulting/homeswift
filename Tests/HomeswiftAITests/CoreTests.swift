import Foundation
import Testing

@testable import HomeswiftAI

@Suite struct JSONValueTests {
    @Test func roundTripsNumbersAndStructure() throws {
        let value = try JSONValue(string: #"{"a": 1, "b": 1.5, "c": [true, null, "x"], "d": {"e": -3}}"#)
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.doubleValue == 1.5)
        #expect(value["b"]?.intValue == nil)
        #expect(value["c"]?[0]?.boolValue == true)
        #expect(value["c"]?[1]?.isNull == true)
        #expect(value["d"]?["e"]?.intValue == -3)
        #expect(value.text() == #"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{"e":-3}}"#)
        #expect(try JSONValue(any: try JSONSerialization.jsonObject(with: Data(#"{"flag": true, "n": 2}"#.utf8))) == ["flag": true, "n": 2])
        struct Point: Codable { var x: Int }
        #expect(try JSONValue(encoding: Point(x: 4)) == ["x": 4])
        #expect(try (["x": 4] as JSONValue).decode(Point.self).x == 4)
    }
}

@Suite struct RedactionTests {
    @Test func scrubsAddressesForTheProvider() {
        let text = "connect ECONNREFUSED 192.168.1.5:9123 from 3C:7A:AA:F3:D5:B0, [fe80::1], studio-light.local"
        #expect(Redaction.scrubAddresses(text) == "connect ECONNREFUSED <IP>:9123 from <MAC>, <IP>, <hostname>.local")
        #expect(Redaction.scrubAddresses(["model": "Key Light", "ip": "10.0.0.2"]) == ["model": "Key Light", "ip": "<IP>"])
        #expect(Redaction.scrubAddresses("login failed for jane.doe+home@mail.example.co.uk (user@studio.local)") == "login failed for <email> (<email>)")
    }

    @Test func redactsSecretKeysAndRestoresThem() throws {
        let config: JSONValue = [
            "platform": "Govee", "apiKey": "abc", "password": "p", "pin": "031-45-154", "maxOutputTokens": 2048,
            "nested": ["clientSecret": 42, "list": [["token": "t"]]], "empty": "",
        ]
        let redacted = Redaction.redactSecrets(config)
        #expect(redacted["apiKey"] == "__REDACTED__")
        #expect(redacted["password"] == "__REDACTED__")
        #expect(redacted["pin"] == "__REDACTED__")
        #expect(redacted["maxOutputTokens"] == 2048)
        #expect(redacted["nested"]?["clientSecret"] == "__REDACTED__")
        #expect(redacted["nested"]?["list"]?[0]?["token"] == "__REDACTED__")
        #expect(Redaction.containsRedacted(redacted))
        #expect(!Redaction.containsRedacted(config))

        var edited = redacted
        edited = .object(edited.objectValue!.merging(["platform": "Govee", "newKey": "v"]) { $1 })
        let restored = try Redaction.restoreSecrets(edited, from: config)
        #expect(restored["apiKey"] == "abc")
        #expect(restored["nested"]?["clientSecret"] == 42)
        #expect(restored["nested"]?["list"]?[0]?["token"] == "t")
    }

    @Test func restoresByIdentityNotPosition() throws {
        let current: JSONValue = ["platforms": [["platform": "A", "name": "one", "token": "ta"], ["platform": "B", "name": "two", "token": "tb"]]]
        let reordered: JSONValue = ["platforms": [["platform": "B", "name": "two", "token": "__REDACTED__"], ["platform": "A", "name": "one", "token": "__REDACTED__"]]]
        let restored = try Redaction.restoreSecrets(reordered, from: current)
        #expect(restored["platforms"]?[0]?["token"] == "tb")
        #expect(restored["platforms"]?[1]?["token"] == "ta")

        let unknown: JSONValue = ["platforms": [["platform": "C", "name": "three", "token": "__REDACTED__"]]]
        #expect(throws: Redaction.RestoreError.self) { try Redaction.restoreSecrets(unknown, from: current) }
    }

    @Test func redactsFreeText() {
        let text = """
            password=hunter2 apiKey: "sk-ant-abcdefghijklmnop" Authorization: Bearer abcdefghijklmnopqrstuvwxyz
            token=abc maxOutputTokens=2048 key AIzaSyA1234567890abcdefghijklmnopqrstuv end
            """
        let redacted = Redaction.redactText(text)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("sk-ant-abcdefghijklmnop"))
        #expect(redacted.contains("Bearer __REDACTED__"))
        #expect(redacted.contains("maxOutputTokens=2048"))
        #expect(!redacted.contains("AIzaSyA1234567890"))
        #expect(redacted.contains("token=__REDACTED__"))

        let banner = "Setup code: 8518-2617\nSetup URI:  X-HM://0024VNBFDNEMH\npin=031-45-154 pass: hunter3 on 2026-10-21"
        let masked = Redaction.redactText(banner)
        #expect(!masked.contains("8518-2617"))
        #expect(!masked.contains("X-HM://0024VNBFDNEMH"))
        #expect(!masked.contains("031-45-154"))
        #expect(!masked.contains("hunter3"))
        #expect(masked.contains("2026-10-21"))
    }

    @Test func redactsConversationHistory() {
        let history: [ChatMessage] = [
            .user("my apiKey=abc"), .assistant("noted apiKey=abc"),
            ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "1", name: "f", arguments: ["token": "t"]))]),
            ChatMessage(role: .user, content: [.toolResult(toolCallID: "1", name: "f", content: "password=p", isError: false)]),
        ]
        let redacted = Redaction.redactMessages(history)
        #expect(redacted[0].text == "my apiKey=__REDACTED__")
        #expect(redacted[1].text == "noted apiKey=abc")
        #expect(redacted[2].toolCalls[0].arguments == ["token": "__REDACTED__"])
        #expect(redacted[3].content == [.toolResult(toolCallID: "1", name: "f", content: "password=__REDACTED__", isError: false)])
    }

    @Test func redactsPairing() {
        let status: JSONValue = ["name": "Homeswift", "pin": "031-45-154", "setupUri": "X-HM://1", "port": 51826, "bridges": [["name": "Child", "pin": "1"]]]
        let redacted = Redaction.redactPairing(status)
        #expect(redacted["pin"] == nil)
        #expect(redacted["setupUri"] == nil)
        #expect(redacted["port"] == 51826)
        #expect(redacted["bridges"]?[0] == ["name": "Child"])
    }
}

@Suite struct TokenTests {
    @Test func estimatesAndTrims() {
        #expect(Tokens.estimate("abcdefgh") == 2)
        #expect(Tokens.estimate("") == 0)
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let tail = Tokens.trim(lines, to: 20)
        #expect(tail.hasPrefix("[… "))
        #expect(tail.hasSuffix("line 100"))
        #expect(!tail.contains("line 1\n"))
        let head = Tokens.trim(lines, to: 20, keep: .head)
        #expect(head.hasPrefix("line 1\n"))
        #expect(head.hasSuffix("later characters trimmed]"))
        #expect(Tokens.trim("short", to: 100) == "short")
        #expect(Tokens.inputBudget(contextTokens: 1000, maxOutputTokens: 900) == 256)
        #expect(Tokens.inputBudget(contextTokens: 100_000, maxOutputTokens: 2048, cap: 8000) == 8000)
    }

    @Test func stripsANSI() {
        #expect(ANSI.strip("\u{1B}[31mred\u{1B}[0m \u{1B}[2K") == "red ")
        #expect(ANSI.tailLines("a\n\n\u{1B}[31mb\u{1B}[0m\nc\n", maxLines: 2) == ["b", "c"])
    }
}

@Suite struct SSETests {
    @Test func parsesEvents() async throws {
        let text = "event: one\ndata: {\"a\":1}\n\nevent: two\r\ndata: line1\r\ndata: line2\r\n\r\ndata: tail"
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in [text.prefix(12), text.dropFirst(12)] { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
        var events: [SSEEvent] = []
        for try await event in SSE.events(stream) { events.append(event) }
        #expect(events == [
            SSEEvent(event: "one", data: #"{"a":1}"#),
            SSEEvent(event: "two", data: "line1\nline2"),
            SSEEvent(event: nil, data: "tail"),
        ])
    }

    @Test func retryAfterHeaders() {
        #expect(RetryOptions.retryAfter(["retry-after": "2"]) == .seconds(2))
        #expect(RetryOptions.retryAfter(["retry-after-ms": "250"]) == .milliseconds(250))
        #expect(RetryOptions.retryAfter([:]) == nil)
        #expect(RetryOptions.retryAfter(["retry-after": "soon"]) == nil)
        #expect(RetryOptions.retryAfter(["retry-after-ms": "1e400"]) == nil)
        #expect(RetryOptions.retryAfter(["retry-after": "99999999999"]) == .milliseconds(86_400_000))
        #expect(RetryOptions.retryAfter(["retry-after": "-5"]) == nil)
        #expect(RetryOptions.isRetryable(status: 529))
        #expect(!RetryOptions.isRetryable(status: 400))
    }
}

@Suite struct JSONGenerationTests {
    @Test func extractsJSONFromReplies() throws {
        #expect(try JSONGeneration.extract("```json\n{\"a\": 1}\n```") == ["a": 1])
        #expect(try JSONGeneration.extract("Sure! {\"a\": [1, 2]} hope this helps") == ["a": [1, 2]])
        #expect(try JSONGeneration.extract("[1,2]") == [1, 2])
        #expect(throws: JSONGenerationError.self) { try JSONGeneration.extract("no json here") }
    }

    @Test func validatesAgainstSchemas() {
        let schema: JSONValue = [
            "type": "object", "required": ["risk", "items"], "additionalProperties": false,
            "properties": [
                "risk": ["enum": ["low", "high"]],
                "items": ["type": "array", "items": ["type": "string"], "maxItems": 2],
                "count": ["type": "integer", "minimum": 1],
            ],
        ]
        #expect(JSONSchema.validate(["risk": "low", "items": ["a"], "count": 2], against: schema).isEmpty)
        let errors = JSONSchema.validate(["risk": "medium", "items": ["a", 1, "c"], "count": 0.5, "extra": true], against: schema)
        #expect(errors.contains("risk must be one of \"low\", \"high\""))
        #expect(errors.contains("items[1] must be string"))
        #expect(errors.contains("items must have at most 2 items"))
        #expect(errors.contains("count must be integer"))
        #expect(errors.contains("(root) must not have additional property 'extra'"))
        #expect(JSONSchema.validate(["items": []], against: schema) == ["(root) must have required property 'risk'"])
    }

    @Test func normalizesPluginSchemas() {
        let schema: JSONValue = [
            "type": "object", "layout": ["name"],
            "properties": ["name": ["type": "string", "required": true, "placeholder": "x"], "port": ["type": "integer"]],
        ]
        let normalized = JSONGeneration.normalizePluginSchema(schema)
        #expect(normalized["required"] == ["name"])
        #expect(normalized["layout"] == nil)
        #expect(normalized["properties"]?["name"] == ["type": "string"])
    }

    @Test func repairsInvalidJSONOnce() async throws {
        let provider = FakeProvider(replies: ["{\"risk\": \"medium\"}", "{\"risk\": \"low\"}"])
        let result = try await JSONGeneration.generate(provider: provider, schema: ["type": "object", "properties": ["risk": ["enum": ["low"]]]], prompt: "rate")
        #expect(result.data == ["risk": "low"])
        #expect(result.usage.inputTokens == 20)
        #expect(provider.requests.count == 2)
        let repair = provider.lastRequest?.messages.last?.text ?? ""
        #expect(repair.contains("Problems: risk must be one of \"low\""))
        #expect(provider.lastRequest?.messages.count == 3)

        let hopeless = FakeProvider(replies: ["nope", "still nope"])
        await #expect(throws: JSONGenerationError.self) {
            try await JSONGeneration.generate(provider: hopeless, schema: ["type": "object"], prompt: "x")
        }
    }
}

@Suite struct UsageTests {
    @Test func pricesKnownModels() async {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 500_000)
        // Half the input is uncached at $4, half read from the cache at $0.20, the output at $20.
        let expected: Double = (500_000.0 * 4.0 + 500_000.0 * 0.2 + 100_000.0 * 20.0) / 1_000_000.0
        #expect(Pricing.cost(of: "claude-opus-5-5", usage: usage) == expected)
        #expect(Pricing.cost(of: "claude-opus-5-5-20270101", usage: usage) == Pricing.cost(of: "claude-opus-5-5", usage: usage))
        #expect(Pricing.cost(of: "gpt-6.1-sol", usage: usage) == nil)
        let tracker = UsageTracker()
        await tracker.record(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 100, outputTokens: 10))
        await tracker.record(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 100, outputTokens: 10))
        let total = await tracker.total
        #expect(total.requests == 2)
        #expect(total.usage == TokenUsage(inputTokens: 200, outputTokens: 20))
        #expect(total.cost != nil)
        await tracker.record(model: "llama3.1", usage: TokenUsage(inputTokens: 1, outputTokens: 1))
        #expect(await tracker.total.cost == nil)
    }

    @Test func addsUsage() {
        let sum = TokenUsage(inputTokens: 1, outputTokens: 2) + TokenUsage(inputTokens: 3, outputTokens: 4, cacheReadTokens: 5)
        #expect(sum == TokenUsage(inputTokens: 4, outputTokens: 6, cacheReadTokens: 5))
    }
}

@Suite struct ConfigurationTests {
    /// The web UI's form for the block: valid JSON naming every key the block reads, the API key as a password.
    @Test func describesTheBlockForTheSettingsForm() throws {
        let properties = try JSONValue(string: AIConfiguration.schemaJSON)["schema"]?["properties"]
        for key in ["provider", "model", "apiKey", "baseUrl", "effort", "maxOutputTokens", "contextTokens", "openaiApi", "maxRetries", "promptCaching", "fallbacks", "enabled", "mcp"] {
            #expect(properties?[key] != nil, "\(key)")
        }
        #expect(properties?["apiKey"]?["x-schema-form"]?["type"] == "password")
        let providers = properties?["provider"]?["oneOf"]?.arrayValue?.compactMap { $0["enum"]?[0]?.stringValue } ?? []
        #expect(Set(providers) == Set(AIConfiguration.ProviderKind.allCases.map(\.rawValue)))
    }

    @Test func appliesDefaults() throws {
        let anthropic = try AIConfiguration(block: ["platform": "HomeswiftAiKit", "apiKey": "k"], environment: [:])
        #expect(anthropic.provider == .anthropic)
        #expect(anthropic.model == "claude-opus-5-5")
        #expect(anthropic.maxOutputTokens == 2048)
        #expect(anthropic.maxRetries == 2)
        #expect(anthropic.enabled)
        #expect(anthropic.promptCaching)

        let local = try AIConfiguration(block: ["provider": "openai-compatible", "baseUrl": "http://host:1234/v1/", "contextTokens": 32768, "effort": "low", "openaiApi": "chat", "maxRetries": 0, "enabled": false], environment: [:])
        #expect(local.model == "llama3.1")
        #expect(local.baseURL == "http://host:1234/v1")
        #expect(local.contextTokens == 32768)
        #expect(local.effort == .low)
        #expect(local.openaiAPI == .chat)
        #expect(local.maxRetries == 0)
        #expect(!local.enabled)

        let fromEnvironment = try AIConfiguration(block: ["provider": "gemini"], environment: ["GEMINI_API_KEY": "g"])
        #expect(fromEnvironment.apiKey == "g")
        #expect(fromEnvironment.model == "gemini-3.8-flash")
        #expect(try AIConfiguration(block: ["provider": "apple"], environment: [:]).model == "system")
    }

    @Test func rejectsBadValues() {
        #expect(throws: AIConfigurationError.invalid(key: "provider", expected: "one of anthropic, openai, gemini, openai-compatible, apple")) {
            try AIConfiguration(block: ["provider": "nope"], environment: [:])
        }
        #expect(throws: AIConfigurationError.self) { try AIConfiguration(block: ["effort": "huge"], environment: [:]) }
        #expect(throws: AIConfigurationError.self) { try AIConfiguration(block: ["maxOutputTokens": 0], environment: [:]) }
        #expect(throws: AIConfigurationError.missingAPIKey(provider: "anthropic", environmentVariable: "ANTHROPIC_API_KEY")) {
            try AIConfiguration(block: [:], environment: [:]).makeProvider(transport: FakeTransport())
        }
    }
}
