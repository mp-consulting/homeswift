import Foundation

// The Assistant acting through tools: a conversation where the model calls tools (read the setup, find a
// device, write its configuration) until it can answer.

/// A tool the Assistant may call in a conversation.
public struct AgentTool: Sendable {
    public var definition: ToolDefinition
    /// For people: "Find TVs", shown while it runs.
    public var title: String
    /// Changes nothing: it may run at the same time as the step's other read-only calls.
    public var readOnly: Bool
    public var run: @Sendable (_ arguments: JSONValue) async -> AgentToolOutput

    public init(definition: ToolDefinition, title: String, readOnly: Bool = false, run: @escaping @Sendable (_ arguments: JSONValue) async -> AgentToolOutput) {
        self.definition = definition
        self.title = title
        self.readOnly = readOnly
        self.run = run
    }
}

/// What a tool answered: text for the model, and the same as JSON when it has a structure.
public struct AgentToolOutput: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool
    /// The user was asked and said no: nothing ran.
    public var declined: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false, declined: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
        self.declined = declined
    }
}

/// What happens during a turn, as it happens.
public enum AgentEvent: Sendable {
    public enum Outcome: String, Sendable {
        case done, failed, declined
    }

    /// A piece of the answer.
    case text(String)
    case toolStarted(id: String, name: String, title: String)
    /// `summary` is the first line of a text result or of an error; nil for a JSON result.
    case toolFinished(id: String, outcome: Outcome, summary: String?)
}

/// A turn of a conversation: the messages it added (the model's and the tool results, redacted), its answer
/// and what it cost.
public struct AgentTurn: Sendable {
    public var messages: [ChatMessage]
    public var text: String
    public var usage: TokenUsage
    public var model: String
    /// The turn stopped at the step limit before the model answered.
    public var truncated: Bool
}

/// Keeps the secrets of a conversation away from the model while letting it move them: a secret in a tool
/// result (the password a TV hands out when it pairs) becomes a handle such as `__SECRET_5f3a91c2__`, and the
/// handle in a later tool's arguments becomes the secret again. Both happen only under secret-named keys, as
/// `Redaction` decides, so a secret cannot be moved into a field that would show it. Handles are random:
/// one from another conversation is not this one's, and the MCP server refuses it.
public final class SecretVault: @unchecked Sendable {
    private let lock = NSLock()
    private var byHandle: [String: JSONValue] = [:]
    private var byValue: [JSONValue: String] = [:]

    public init() {}

    static let handlePattern = try! NSRegularExpression(pattern: #"^__SECRET_[0-9a-f]+__$"#)

    public static func isHandle(_ string: String) -> Bool {
        string.hasPrefix("__SECRET_") && handlePattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// Whether `value` holds a handle anywhere, under any key.
    public static func containsHandle(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string): isHandle(string)
        case .array(let items): items.contains(where: containsHandle)
        case .object(let object): object.values.contains(where: containsHandle)
        default: false
        }
    }

    /// `value` with each secret as a handle.
    public func conceal(_ value: JSONValue) -> JSONValue {
        Redaction.redactSecrets(value) { .string(handle(for: $0)) }
    }

    /// `value` with each handle this vault issued, under a secret-named key, as its secret. Any other handle
    /// stays as it is: `containsHandle` finds it.
    public func reveal(_ value: JSONValue, underSecretKey: Bool = false) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { reveal($0, underSecretKey: underSecretKey) })
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                result[entry.key] = reveal(entry.value, underSecretKey: underSecretKey || Redaction.isSecretKey(entry.key))
            })
        case .string(let string) where underSecretKey && Self.isHandle(string):
            return lock.withLock { byHandle[string] } ?? value
        default:
            return value
        }
    }

    private func handle(for secret: JSONValue) -> String {
        lock.withLock {
            if let handle = byValue[secret] { return handle }
            var handle: String
            repeat { handle = "__SECRET_\(String(UInt32.random(in: .min ... .max), radix: 16))__" } while byHandle[handle] != nil
            byHandle[handle] = secret
            byValue[secret] = handle
            return handle
        }
    }
}

extension AssistantService {
    /// Continues a conversation with tools: the model answers or calls tools, whose results go back to it,
    /// until it answers or `maxSteps` model calls have been made. `history` ends with the user's new
    /// message; it is redacted once, and each tool result as it comes, so a step sends what is kept. Tool
    /// results pass through `vault` (secrets become handles) and tool arguments come back through it.
    public func converse(
        history: [ChatMessage], tools: [AgentTool], vault: SecretVault, context: String? = nil, maxSteps: Int = 16,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> AgentTurn {
        let definitions = tools.map(\.definition)
        let byName = Dictionary(tools.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        let instructions = system([Prompts.Chat.system, context].compactMap { $0 }.joined(separator: "\n\n"))
        var messages = Redaction.redactMessages(history)
        let start = messages.count
        var usage = TokenUsage.zero
        var model = provider.model
        for _ in 0..<maxSteps {
            try Task.checkCancellation()
            try await self.usage.checkBudget()
            let request = ChatRequest(system: instructions, messages: messages, tools: definitions, maxOutputTokens: maxOutputTokens)
            let result = try await complete(provider, request) { onEvent(.text($0)) }
            await record(model: result.model, usage: result.usage)
            usage += result.usage
            model = result.model
            messages.append(result.message)
            logger.debug("Assistant step", metadata: ["model": "\(result.model)", "tools": "\(result.toolCalls.map(\.name))", "stop": "\(result.stopReason)"])
            guard !result.toolCalls.isEmpty else {
                return AgentTurn(messages: Array(messages[start...]), text: result.text, usage: usage, model: model, truncated: false)
            }
            try Task.checkCancellation()
            // Reads run at the same time (finding TVs and reading a schema need not wait for each other); a step
            // with a change in it runs in order, so a confirmation is never asked beside another call.
            let calls = result.toolCalls.map { call in (call, byName[call.name]) }
            for (call, tool) in calls { onEvent(.toolStarted(id: call.id, name: call.name, title: tool?.title ?? call.name)) }
            let run: @Sendable (HomeswiftAI.ToolCall, AgentTool?) async -> ContentPart = { call, tool in
                let output = await tool?.run(vault.reveal(call.arguments)) ?? AgentToolOutput(text: "There is no tool named \(call.name).", isError: true)
                // Compact: every later step sends it again.
                let content = output.structured.map { vault.conceal($0).text() } ?? Redaction.redactText(output.text)
                let outcome: AgentEvent.Outcome = output.declined ? .declined : output.isError ? .failed : .done
                onEvent(.toolFinished(id: call.id, outcome: outcome, summary: outcome == .failed || output.structured == nil ? Self.summary(of: output.text) : nil))
                return .toolResult(toolCallID: call.id, name: call.name, content: Tokens.trim(content, to: 12_000), isError: output.isError)
            }
            var results: [ContentPart] = []
            if calls.count > 1, calls.allSatisfy({ $0.1?.readOnly == true }) {
                results = await withTaskGroup(of: (Int, ContentPart).self) { group in
                    for (index, (call, tool)) in calls.enumerated() { group.addTask { (index, await run(call, tool)) } }
                    var ordered = [ContentPart?](repeating: nil, count: calls.count)
                    for await (index, part) in group { ordered[index] = part }
                    return ordered.compactMap { $0 }
                }
            } else {
                for (call, tool) in calls {
                    try Task.checkCancellation()
                    results.append(await run(call, tool))
                }
            }
            messages.append(ChatMessage(role: .user, content: results))
        }
        return AgentTurn(messages: Array(messages[start...]), text: "", usage: usage, model: model, truncated: true)
    }

    /// The first line of a tool's text, short, for the page under a finished step; nil for JSON, whose first
    /// line says nothing. The untrusted-data fence is not part of it.
    static func summary(of text: String) -> String? {
        let line = text.split(separator: "\n").first { !$0.hasPrefix("<untrusted-data") && !$0.hasPrefix("</untrusted-data") }.map(String.init) ?? ""
        guard let first = line.first, first != "{", first != "[" else { return nil }
        let shown = Redaction.redactText(line)
        return shown.count > 160 ? String(shown.prefix(159)) + "…" : shown
    }
}
