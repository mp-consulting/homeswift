import Foundation
import Logging

/// What the Assistant answers with.
public struct AssistantReply: Sendable {
    public var text: String
    public var usage: TokenUsage
    public var model: String
}

/// A configuration block the Assistant wrote.
public struct ConfigurationSuggestion: Sendable {
    public var config: JSONValue
    public var explanation: String
    public var usage: TokenUsage
}

/// The AI features plugins and the CLI use. Every input is redacted before it reaches a provider and
/// trimmed to fit its context window.
public protocol Assistant: Sendable {
    var providerName: String { get }
    var model: String { get }
    /// Answers a free-form question. `history` holds the earlier turns of a conversation.
    func ask(_ prompt: String, context: String?, history: [ChatMessage], onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply
    /// Explains a device error to the person who owns the device.
    func explain(error: String, context: String?, device: JSONValue?, pluginName: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply
    /// Diagnoses log lines: grouped issues with causes and fixes.
    func diagnose(logs: String, focus: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply
    /// Writes a platform block from a plugin's config.schema.json and a request in plain language. Secrets
    /// in `current` are redacted before sending and restored after.
    func generateConfiguration(request: String, schema: JSONValue, current: JSONValue?, pluginName: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> ConfigurationSuggestion
}

extension Assistant {
    public func ask(_ prompt: String, context: String? = nil) async throws -> AssistantReply {
        try await ask(prompt, context: context, history: [], onChunk: nil)
    }

    public func explain(error: String, context: String? = nil, device: JSONValue? = nil, pluginName: String? = nil) async throws -> AssistantReply {
        try await explain(error: error, context: context, device: device, pluginName: pluginName, onChunk: nil)
    }

    public func diagnose(logs: String, focus: String? = nil) async throws -> AssistantReply {
        try await diagnose(logs: logs, focus: focus, onChunk: nil)
    }

    public func generateConfiguration(request: String, schema: JSONValue, current: JSONValue? = nil, pluginName: String? = nil) async throws -> ConfigurationSuggestion {
        try await generateConfiguration(request: request, schema: schema, current: current, pluginName: pluginName, onChunk: nil)
    }
}

/// The Assistant on one provider, with usage accounting.
public final class AssistantService: Assistant, Sendable {
    public let provider: any Provider
    public let usage: UsageTracker
    public let maxOutputTokens: Int
    /// Extra instructions appended to every system prompt, e.g. which plugin is asking.
    public let systemContext: String?
    let logger: Logger

    public init(
        provider: any Provider, maxOutputTokens: Int = AIConfiguration.defaultMaxOutputTokens, systemContext: String? = nil,
        usage: UsageTracker = UsageTracker(), logger: Logger = Logger(label: "homeswift.ai")
    ) {
        self.provider = provider
        self.maxOutputTokens = maxOutputTokens
        self.systemContext = systemContext
        self.usage = usage
        self.logger = logger
    }

    public convenience init(configuration: AIConfiguration, transport: any HTTPTransport = URLSessionTransport(), logger: Logger = Logger(label: "homeswift.ai")) throws {
        self.init(provider: try configuration.makeProvider(transport: transport), maxOutputTokens: configuration.maxOutputTokens, logger: logger)
    }

    /// The same Assistant (same provider, same usage totals) with instructions about who is asking.
    public func withContext(_ context: String) -> AssistantService {
        AssistantService(provider: provider, maxOutputTokens: maxOutputTokens, systemContext: context, usage: usage, logger: logger)
    }

    public var providerName: String { provider.name }
    public var model: String { provider.model }

    private func system(_ base: String) -> String {
        systemContext.map { "\(base)\n\n\($0)" } ?? base
    }

    /// Tokens available for one variable input (logs, a changelog), capped.
    private func budget(_ cap: Int) -> Int {
        Tokens.inputBudget(contextTokens: provider.capabilities.contextTokens, maxOutputTokens: maxOutputTokens, cap: cap)
    }

    /// A redacted JSON value as text, trimmed to `maxTokens` when it does not fit.
    private func boundedJSON(_ value: JSONValue, _ maxTokens: Int) -> JSONValue {
        let redacted = Redaction.redactSecrets(value)
        let text = redacted.text()
        return Tokens.estimate(text) <= maxTokens ? redacted : .string(Tokens.trim(text, to: maxTokens, keep: .head))
    }

    private func reply(system: String, messages: [ChatMessage], onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply {
        let result = try await complete(provider, ChatRequest(system: self.system(system), messages: messages, maxOutputTokens: maxOutputTokens), onChunk: onChunk)
        await usage.record(model: result.model, usage: result.usage)
        logger.debug("Assistant reply", metadata: ["model": "\(result.model)", "input": "\(result.usage.inputTokens)", "output": "\(result.usage.outputTokens)", "stop": "\(result.stopReason)"])
        return AssistantReply(text: result.text, usage: result.usage, model: result.model)
    }

    public func ask(_ prompt: String, context: String?, history: [ChatMessage], onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply {
        let cap = budget(16_000)
        let user = Prompts.Ask.user(prompt: Redaction.redactText(prompt), context: context.map { Tokens.trim(Redaction.redactText($0), to: cap) })
        return try await reply(system: Prompts.Ask.system, messages: history + [.user(user)], onChunk: onChunk)
    }

    public func explain(error: String, context: String?, device: JSONValue?, pluginName: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply {
        let cap = budget(8_000)
        let user = Prompts.ExplainDeviceError.user(
            error: Tokens.trim(Redaction.redactText(error), to: cap / 2),
            context: context.map { Tokens.trim(Redaction.redactText($0), to: cap / 4) },
            device: device.map { boundedJSON($0, cap / 4) },
            pluginName: pluginName)
        return try await reply(system: Prompts.ExplainDeviceError.system, messages: [.user(user)], onChunk: onChunk)
    }

    public func diagnose(logs: String, focus: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> AssistantReply {
        let trimmed = Tokens.trim(Redaction.redactText(ANSI.strip(logs)), to: budget(24_000))
        return try await reply(system: Prompts.DiagnoseLogs.system, messages: [.user(Prompts.DiagnoseLogs.user(logs: trimmed, focus: focus))], onChunk: onChunk)
    }

    public func generateConfiguration(request: String, schema: JSONValue, current: JSONValue?, pluginName: String?, onChunk: (@Sendable (String) -> Void)?) async throws -> ConfigurationSuggestion {
        let pluginSchema = schema["schema"] ?? schema
        var configSchema = JSONGeneration.normalizePluginSchema(pluginSchema).objectValue ?? [:]
        configSchema["type"] = "object"
        let replySchema: JSONValue = [
            "type": "object",
            "required": ["config", "explanation"],
            "properties": ["config": .object(configSchema), "explanation": ["type": "string"]],
        ]
        let redactedCurrent = current.map { Redaction.redactSecrets($0) }
        let generated = try await JSONGeneration.generate(
            provider: provider, schema: replySchema,
            prompt: Prompts.GeneratePluginConfig.user(request: Redaction.redactText(request), schema: pluginSchema, current: redactedCurrent, pluginName: pluginName),
            system: system(Prompts.GeneratePluginConfig.system), maxOutputTokens: maxOutputTokens, onChunk: onChunk)
        await usage.record(model: provider.model, usage: generated.usage)
        var config = generated.data["config"] ?? .object([:])
        if let current, Redaction.containsRedacted(config) {
            // A new secret field with no current value keeps the placeholder for the user to fill in.
            config = (try? Redaction.restoreSecrets(config, from: current)) ?? config
        }
        return ConfigurationSuggestion(config: config, explanation: generated.data["explanation"]?.stringValue ?? "", usage: generated.usage)
    }
}
