import Foundation

/// The `HomeswiftAiKit` platform block in config.json: which provider the Assistant uses, and how.
///
/// ```json
/// { "platform": "HomeswiftAiKit", "provider": "anthropic", "model": "claude-opus-5-5", "apiKey": "sk-ant-…" }
/// { "platform": "HomeswiftAiKit", "provider": "apple" }
/// ```
///
/// The key names are those of `@mp-consulting/homebridge-ai-kit`, so a Homebridge block works unchanged.
/// An API key missing from the block is read from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GEMINI_API_KEY`.
public struct AIConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftAiKit"

    public enum ProviderKind: String, Sendable, Codable, CaseIterable {
        case anthropic, openai, gemini
        case openaiCompatible = "openai-compatible"
        /// Apple's on-device model (Foundation Models, macOS 26 or later with Apple Intelligence).
        case apple

        public var defaultModel: String {
            switch self {
            case .anthropic: "claude-opus-5-5"
            case .openai: "gpt-6.1-sol"
            case .gemini: "gemini-3.8-flash"
            case .openaiCompatible: "llama3.1"
            case .apple: "system"
            }
        }

        public var defaultBaseURL: String? {
            switch self {
            case .anthropic: "https://api.anthropic.com"
            case .openai: "https://api.openai.com/v1"
            case .gemini: "https://generativelanguage.googleapis.com/v1beta"
            case .openaiCompatible: "http://127.0.0.1:11434/v1"
            case .apple: nil
            }
        }

        var apiKeyEnvironmentVariable: String? {
            switch self {
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            case .gemini: "GEMINI_API_KEY"
            case .openaiCompatible, .apple: nil
            }
        }
    }

    /// OpenAI APIs: the Responses API, or Chat Completions for servers that only speak it.
    public enum OpenAIAPI: String, Sendable, Codable {
        case responses, chat
    }

    public static let defaultMaxOutputTokens = 2048

    /// The block's settings form, in the shape of a plugin's config.schema.json: the web UI's Settings uses it.
    /// It covers the MCP server's part of the block (`mcp.http`) too.
    public static let schemaJSON = #"""
        {
          "pluginAlias": "HomeswiftAiKit",
          "schema": {
            "type": "object",
            "properties": {
              "provider": { "title": "Provider", "type": "string", "default": "anthropic", "required": true, "oneOf": [
                { "title": "Anthropic (Claude)", "enum": ["anthropic"] },
                { "title": "OpenAI", "enum": ["openai"] },
                { "title": "Google Gemini", "enum": ["gemini"] },
                { "title": "OpenAI-compatible (Ollama, LM Studio, a proxy)", "enum": ["openai-compatible"] },
                { "title": "Apple on-device model (macOS 26)", "enum": ["apple"] }
              ], "description": "Who answers. Apple's on-device model is free and private but too small for the chat's tools." },
              "model": { "title": "Model", "type": "string", "placeholder": "claude-opus-5-5", "description": "Empty uses the provider's default: claude-opus-5-5, gpt-6.1-sol, gemini-3.8-flash." },
              "apiKey": { "title": "API key", "type": "string", "x-schema-form": { "type": "password" }, "description": "Empty reads ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY from the environment. Never sent anywhere but the provider." },
              "baseUrl": { "title": "Base URL", "type": "string", "placeholder": "http://127.0.0.1:11434/v1", "description": "For an OpenAI-compatible server or a proxy." },
              "effort": { "title": "Effort", "type": "string", "enum": ["low", "medium", "high", "xhigh", "max"], "description": "How much the model thinks before answering (Claude, OpenAI reasoning models)." },
              "maxOutputTokens": { "title": "Longest answer (tokens)", "type": "integer", "default": 2048, "minimum": 1 },
              "contextTokens": { "title": "Context window (tokens)", "type": "integer", "minimum": 1, "description": "The model's window, for a local model the bridge cannot know." },
              "openaiApi": { "title": "OpenAI API", "type": "string", "enum": ["responses", "chat"], "description": "Chat Completions for servers that only speak it; OpenAI uses the Responses API." },
              "maxRetries": { "title": "Retries", "type": "integer", "default": 2, "minimum": 0, "maximum": 10 },
              "promptCaching": { "title": "Prompt caching", "type": "boolean", "default": true, "description": "Claude: cache the system prompt and tools. Off for proxies that reject it." },
              "fallbacks": { "title": "Fallback model", "type": "boolean", "description": "Claude: let the API retry a declined request on a fallback model." },
              "enabled": { "title": "Enabled", "type": "boolean", "default": true },
              "mcp": { "title": "MCP server", "type": "object", "properties": {
                "http": { "title": "Over HTTP", "type": "object", "properties": {
                  "enabled": { "title": "Run the MCP server", "type": "boolean", "default": false, "description": "Lets Claude Desktop and other MCP clients read and control the bridge with a token." },
                  "host": { "title": "Listen on", "type": "string", "placeholder": "127.0.0.1" },
                  "port": { "title": "Port", "type": "integer", "default": 8582, "minimum": 1, "maximum": 65535 },
                  "token": { "title": "Admin token", "type": "string", "x-schema-form": { "type": "password" }, "description": "homeswift mcp --generate-token makes one." },
                  "readOnly": { "title": "Read only", "type": "boolean", "description": "Caps every token at read access." },
                  "allowedOrigins": { "title": "Allowed browser origins", "type": "array", "items": { "type": "string" } },
                  "auditLog": { "title": "Audit log", "type": "boolean", "default": true, "description": "Every write, with who asked, in homeswift-mcp-audit.jsonl." },
                  "auditLogPath": { "title": "Audit log file", "type": "string" },
                  "clients": { "title": "Clients", "type": "array", "items": { "type": "object", "properties": {
                    "name": { "title": "Name", "type": "string" },
                    "token": { "title": "Token", "type": "string", "x-schema-form": { "type": "password" } },
                    "scope": { "title": "Scope", "type": "string", "enum": ["read", "control", "admin"] }
                  } } }
                } }
              } }
            }
          }
        }
        """#

    public var name: String
    public var enabled: Bool
    public var provider: ProviderKind
    public var model: String
    /// Secret: redaction treats it as one.
    public var apiKey: String?
    public var baseURL: String?
    public var maxOutputTokens: Int
    /// Overrides the provider's context window, e.g. for a local model.
    public var contextTokens: Int?
    public var effort: EffortLevel?
    public var openaiAPI: OpenAIAPI?
    /// Retries of a failed provider request; default 2, 0 disables.
    public var maxRetries: Int
    /// Claude: cache breakpoints on the system prompt and tools (default true; off for proxies that reject them).
    public var promptCaching: Bool
    /// Claude Opus 5.5, Opus 5, Sonnet 5.5 and Fable: let the API re-run a declined request on a fallback
    /// model (default true for those models).
    public var fallbacks: Bool?
    /// Whether the block (or the environment) names a provider or a key at all. A block that only turns
    /// on the MCP server has neither, and then no Assistant is set up.
    public var hasProviderSettings = true

    public init(provider: ProviderKind, model: String? = nil, apiKey: String? = nil, name: String = "AI Kit", enabled: Bool = true) {
        self.name = name
        self.enabled = enabled
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.apiKey = apiKey
        maxOutputTokens = Self.defaultMaxOutputTokens
        maxRetries = 2
        promptCaching = true
    }

    /// Reads a block, applying defaults. Unknown providers, efforts and APIs, and bad numbers, throw.
    public init(block: JSONValue, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let object = block.objectValue ?? [:]
        func string(_ key: String) -> String? {
            object[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        }
        func positiveInt(_ key: String) throws -> Int? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let int = value.intValue ?? value.stringValue.flatMap(Int.init), int > 0 else {
                throw AIConfigurationError.invalid(key: key, expected: "a positive integer")
            }
            return int
        }
        let providerName = string("provider") ?? ProviderKind.anthropic.rawValue
        guard let provider = ProviderKind(rawValue: providerName) else {
            throw AIConfigurationError.invalid(key: "provider", expected: "one of \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.provider = provider
        name = string("name") ?? "AI Kit"
        enabled = object["enabled"] != .bool(false)
        model = string("model") ?? provider.defaultModel
        apiKey = string("apiKey") ?? provider.apiKeyEnvironmentVariable.flatMap { environment[$0]?.nonEmpty }
        baseURL = string("baseUrl").map { $0.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
        maxOutputTokens = try positiveInt("maxOutputTokens") ?? Self.defaultMaxOutputTokens
        contextTokens = try positiveInt("contextTokens")
        if let effort = string("effort") {
            guard let level = EffortLevel(rawValue: effort) else {
                throw AIConfigurationError.invalid(key: "effort", expected: "one of \(EffortLevel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self.effort = level
        }
        if let api = string("openaiApi") {
            guard let value = OpenAIAPI(rawValue: api) else { throw AIConfigurationError.invalid(key: "openaiApi", expected: "responses or chat") }
            openaiAPI = value
        }
        if let retries = object["maxRetries"], !retries.isNull {
            guard let int = retries.intValue, int >= 0 else { throw AIConfigurationError.invalid(key: "maxRetries", expected: "a non-negative integer") }
            maxRetries = int
        } else {
            maxRetries = 2
        }
        promptCaching = object["promptCaching"] != .bool(false)
        fallbacks = object["fallbacks"]?.boolValue
        hasProviderSettings = object["provider"] != nil || object["model"] != nil || apiKey != nil
    }

    /// The provider adapter this configuration selects.
    public func makeProvider(transport: any HTTPTransport = URLSessionTransport()) throws -> any Provider {
        switch provider {
        case .anthropic:
            return try AnthropicProvider(configuration: self, transport: transport)
        case .openai, .openaiCompatible:
            return try OpenAIProvider(configuration: self, transport: transport)
        case .gemini:
            return try GeminiProvider(configuration: self, transport: transport)
        case .apple:
            return try AppleProvider.make(configuration: self)
        }
    }
}

public enum AIConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(key: String, expected: String)
    case missingAPIKey(provider: String, environmentVariable: String?)
    case unavailable(String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftAiKit: \"\(key)\" must be \(expected)"
        case .missingAPIKey(let provider, let variable):
            "HomeswiftAiKit: \(provider) needs an API key: set \"apiKey\" in the block\(variable.map { " or \($0) in the environment" } ?? "")"
        case .unavailable(let reason): "HomeswiftAiKit: \(reason)"
        }
    }
}

extension String {
    public var nonEmpty: String? { isEmpty ? nil : self }
}

extension JSONValue {
    /// A port from a number or a numeric string, 1 to 65535.
    public var portValue: Int? {
        guard let value = intValue ?? stringValue.flatMap(Int.init), (1...65535).contains(value) else { return nil }
        return value
    }
}
