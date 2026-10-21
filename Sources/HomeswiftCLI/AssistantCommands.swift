import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Logging

/// `homeswift ask`, `explain` and `diagnose`: the Assistant from the command line, without starting the bridge.
enum AssistantCommands {
    /// The Assistant of config.json's `HomeswiftAiKit` block, or Apple's on-device model when there is no
    /// block and the Mac has Apple Intelligence.
    static func makeAssistant(configuration: HomeswiftConfiguration, logger: Logger) throws -> AssistantService {
        if let block = try configuration.block(for: AIConfiguration.platform) {
            let ai = try AIConfiguration(block: block)
            guard ai.enabled else { throw CommandError("the HomeswiftAiKit block in config.json is disabled") }
            return try AssistantService(configuration: ai, logger: logger)
        }
        guard let reason = AppleProvider.unavailabilityReason() else {
            return try AssistantService(configuration: AIConfiguration(provider: .apple), logger: logger)
        }
        throw CommandError("""
            no HomeswiftAiKit block in config.json, and Apple's on-device model cannot be used: \(reason).
            Add a block to pick a provider, for example:
              { "platform": "HomeswiftAiKit", "provider": "anthropic", "apiKey": "sk-ant-..." }
              { "platform": "HomeswiftAiKit", "provider": "apple" }   (macOS 26 with Apple Intelligence)
            An API key can also come from ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY.
            """)
    }

    static func run(_ command: String, arguments: [String], configuration: HomeswiftConfiguration, logger: Logger) async throws {
        let assistant = try makeAssistant(configuration: configuration, logger: logger)
        let stream: @Sendable (String) -> Void = { delta in FileHandle.standardOutput.write(Data(delta.utf8)) }
        let reply: AssistantReply
        switch command {
        case "ask":
            let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !prompt.isEmpty else { throw CommandError("usage: homeswift ask <question>") }
            reply = try await assistant.ask(prompt, context: nil, history: [], onChunk: stream)
        case "explain":
            let error = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !error.isEmpty else { throw CommandError("usage: homeswift explain <error message>") }
            reply = try await assistant.explain(error: error, context: nil, device: nil, pluginName: nil, onChunk: stream)
        case "diagnose":
            let logs: String
            if arguments.isEmpty || arguments == ["-"] {
                logs = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else {
                logs = try String(contentsOfFile: NSString(string: arguments[0]).expandingTildeInPath, encoding: .utf8)
            }
            guard !logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandError("usage: homeswift diagnose <log file>   (or pipe the log into homeswift diagnose)")
            }
            reply = try await assistant.diagnose(logs: logs, focus: nil, onChunk: stream)
        default:
            throw CommandError("unknown command \(command)")
        }
        var footer = "\n\n[\(assistant.providerName) \(reply.model): \(reply.usage.inputTokens) tokens in, \(reply.usage.outputTokens) out"
        if let cost = Pricing.cost(of: reply.model, usage: reply.usage) {
            footer += String(format: ", $%.4f", cost)
        }
        FileHandle.standardError.write(Data((footer + "]\n").utf8))
    }
}

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
