import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

/// `homeswift ask`, `explain`, `diagnose`, `digest`, `organize`, `test-ai` and `usage`: the Assistant from the
/// command line, without starting the bridge. Requests count in the usage file (`ai-usage.json`) and its budgets.
enum AssistantCommands {
    static let commands = ["ask", "explain", "diagnose", "digest", "organize", "test-ai", "usage"]

    static func usageStore(storage: URL) -> FileUsageStore {
        FileUsageStore(url: storage.appendingPathComponent(UsageTracker.fileName), write: OwnerOnlyFile.write)
    }

    /// The HomeswiftAiKit block, or nil when config.json has none.
    static func aiConfiguration(_ configuration: HomeswiftConfiguration) throws -> AIConfiguration? {
        try configuration.block(for: AIConfiguration.platform).map { try AIConfiguration(block: $0) }
    }

    static let noBlockHelp = """
        Add a block to pick a provider, for example:
          { "platform": "HomeswiftAiKit", "provider": "anthropic", "apiKey": "sk-ant-..." }
          { "platform": "HomeswiftAiKit", "provider": "apple" }   (macOS 26 with Apple Intelligence)
        An API key can also come from ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY.
        """

    /// The Assistant of config.json's `HomeswiftAiKit` block, or Apple's on-device model when there is no
    /// block and the Mac has Apple Intelligence.
    static func makeAssistant(configuration: HomeswiftConfiguration, storage: URL, logger: Logger) throws -> AssistantService {
        if let ai = try aiConfiguration(configuration) {
            guard ai.enabled else { throw CommandError("the HomeswiftAiKit block in config.json is disabled") }
            return try AssistantService(configuration: ai, usageStore: usageStore(storage: storage), logger: logger)
        }
        guard let reason = AppleProvider.unavailabilityReason() else {
            return try AssistantService(configuration: AIConfiguration(provider: .apple), usageStore: usageStore(storage: storage), logger: logger)
        }
        throw CommandError("no HomeswiftAiKit block in config.json, and Apple's on-device model cannot be used: \(reason).\n\(noBlockHelp)")
    }

    static func run(_ command: String, arguments: [String], configuration: HomeswiftConfiguration, storage: URL, logger: Logger) async throws {
        switch command {
        case "test-ai": return try await testConnection(configuration: configuration, storage: storage, logger: logger)
        case "usage": return try await printUsage(arguments: arguments, configuration: configuration, storage: storage, logger: logger)
        case "organize": return try await organize(arguments: arguments, configuration: configuration, storage: storage, logger: logger)
        default: break
        }
        let assistant = try makeAssistant(configuration: configuration, storage: storage, logger: logger)
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
        case "digest":
            reply = try await assistant.dailyDigest(digestInput(arguments: arguments, configuration: configuration, storage: storage), onChunk: stream)
        default:
            throw CommandError("unknown command \(command)")
        }
        printFooter(assistant: assistant, model: reply.model, usage: reply.usage)
    }

    static func printFooter(assistant: AssistantService, model: String, usage: TokenUsage) {
        var footer = "\n\n[\(assistant.providerName) \(model): \(usage.inputTokens) tokens in, \(usage.outputTokens) out"
        if let cost = Pricing.cost(of: model, usage: usage) {
            footer += String(format: ", $%.4f", cost)
        }
        FileHandle.standardError.write(Data((footer + "]\n").utf8))
    }

    // MARK: test-ai

    /// A one-word request with the block, enabled or not; exits 1 when it fails.
    static func testConnection(configuration: HomeswiftConfiguration, storage: URL, logger: Logger) async throws {
        let ai = try aiConfiguration(configuration)
        let tracker = UsageTracker(budget: ai?.budget ?? UsageBudget(), store: usageStore(storage: storage), logger: logger)
        let result: ConnectionTestResult
        if let block = try configuration.block(for: AIConfiguration.platform) {
            result = await AssistantService.testConnection(block: block, usage: tracker)
        } else if AppleProvider.unavailabilityReason() == nil {
            result = await AssistantService.testConnection(provider: try AIConfiguration(provider: .apple).makeProvider(), usage: tracker)
        } else {
            throw CommandError("no HomeswiftAiKit block in config.json to test.\n\(noBlockHelp)")
        }
        guard result.ok else { throw CommandError("the Assistant could not be reached: \(result.message ?? "unknown error")") }
        say("OK: \(result.provider ?? "?") \(result.model ?? "?") answered in \(result.latencyMs ?? 0) ms: \(result.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }

    // MARK: usage

    static func printUsage(arguments: [String], configuration: HomeswiftConfiguration, storage: URL, logger: Logger) async throws {
        let tracker = UsageTracker(budget: try aiConfiguration(configuration)?.budget ?? UsageBudget(), store: usageStore(storage: storage), logger: logger)
        let report = await tracker.report()
        if arguments.contains("--json") {
            say(report.json.text(pretty: true))
            return
        }
        func line(_ title: String, _ summary: UsageTracker.Summary, tokens: Int?, usd: Double?) -> String {
            var text = "\(title): \(summary.requests) requests, \(summary.usage.inputTokens) tokens in, \(summary.usage.outputTokens) out"
            text += summary.cost.map { String(format: ", $%.4f", $0) } ?? ", cost unknown (unpriced models)"
            if let tokens { text += "; budget \(tokens) tokens" }
            if let usd { text += String(format: "; budget $%.2f", usd) }
            return text
        }
        say(line("Today (\(report.day))", report.today, tokens: report.budget.dailyTokens, usd: report.budget.dailyUsd))
        say(line("This month (\(report.month))", report.thisMonth, tokens: report.budget.monthlyTokens, usd: report.budget.monthlyUsd))
        for (model, summary) in report.monthByModel.sorted(by: { $0.key < $1.key }) {
            say(line("  \(model)", summary, tokens: nil, usd: nil))
        }
        if let exceeded = report.exceeded { say(exceeded.description) }
    }

    // MARK: digest and organize

    /// The accessories the bridge last cached (`accessories/*.json`), as plain JSON: id, name, plugin, category,
    /// maker and services, with the characteristics' last values when `states` is set.
    static func cachedAccessories(storage: URL, states: Bool) -> [JSONValue] {
        let directory = storage.appendingPathComponent("accessories")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var accessories: [JSONValue] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let cache = try? JSONValue(data: data) else { continue }
            let plugin = file.deletingPathExtension().lastPathComponent
            for accessory in cache["accessories"]?.arrayValue ?? [] {
                guard let id = accessory["id"]?.stringValue else { continue }
                var object: [String: JSONValue] = ["uniqueId": .string(id), "name": accessory["name"] ?? .null, "plugin": .string(plugin)]
                if let category = accessory["category"]?.intValue.flatMap(AccessoryCategory.init(rawValue:)) { object["category"] = .string("\(category)") }
                for key in ["manufacturer", "model"] { if let value = accessory[key]?.stringValue, !value.isEmpty { object[key] = .string(value) } }
                object["services"] = .array((accessory["services"]?.arrayValue ?? []).filter { $0["isHidden"] != .bool(true) }.map { service -> JSONValue in
                    guard states else { return service["name"] ?? .null }
                    var values: [String: JSONValue] = [:]
                    for characteristic in service["characteristics"]?.arrayValue ?? [] {
                        guard let name = characteristic["name"]?.stringValue, let value = characteristic["value"], !value.isNull, value.objectValue == nil, value.arrayValue == nil else { continue }
                        values[name] = value
                    }
                    return ["service": service["name"] ?? .null, "values": .object(values)]
                })
                accessories.append(.object(object))
            }
        }
        return accessories
    }

    /// The last day's warnings and errors from the log on disk, the cached accessories and their last values,
    /// and the bridge's version and plugins. `--hours N` changes the period.
    static func digestInput(arguments: [String], configuration: HomeswiftConfiguration, storage: URL) throws -> DailyDigestInput {
        var hours = 24.0
        if let index = arguments.firstIndex(of: "--hours") {
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else { throw CommandError("usage: homeswift digest [--hours <hours>]") }
            hours = value
        }
        let now = Date()
        let lines = LogArchive(directory: storage.appendingPathComponent("logs")).lines(from: now.addingTimeInterval(-hours * 3600), to: now, limit: 20_000)
        let problems = lines.filter { $0.level >= .warning || !DailyDigestInput.problemLines([$0.text]).isEmpty }.suffix(150).map(\.formatted)
        let platforms = configuration.platforms.map { $0.paused ? "\($0.platform) (paused)" : $0.platform }
        var status: [String: JSONValue] = [
            "homeswiftVersion": .string(PluginHost.version), "period": .string("the last \(hours == hours.rounded() ? String(Int(hours)) : String(hours)) hours"),
            "platforms": .array(platforms.map(JSONValue.string)),
        ]
        // The vault's problems, from config.json as written (its references, not what they resolve to).
        if let config = try? JSONValue(data: Data(contentsOf: storage.appendingPathComponent("config.json"))),
           let entries = try? CredentialVault(storage: storage).listing(), case let vault = VaultHealth.check(config: config, entries: entries), !vault.problems.isEmpty {
            status["vault"] = vault.json
        }
        let accessories = cachedAccessories(storage: storage, states: true)
        return DailyDigestInput(status: .object(status), logs: Array(problems), accessories: accessories.isEmpty ? nil : .array(accessories))
    }

    /// Rooms and names for the cached accessories; `--json` prints upstream's JSON.
    static func organize(arguments: [String], configuration: HomeswiftConfiguration, storage: URL, logger: Logger) async throws {
        let accessories = cachedAccessories(storage: storage, states: false)
        guard !accessories.isEmpty else {
            throw CommandError("no cached accessories in \(storage.appendingPathComponent("accessories").path): run the bridge once first")
        }
        let assistant = try makeAssistant(configuration: configuration, storage: storage, logger: logger)
        let suggestion = try await assistant.suggestOrganization(accessories: accessories) { done, total in
            if total > 1 { FileHandle.standardError.write(Data("\r\(done) of \(total) batches".utf8)) }
        }
        if arguments.contains("--json") {
            say(suggestion.json.text(pretty: true))
        } else {
            let names = Dictionary(accessories.compactMap { a in a["uniqueId"]?.stringValue.map { ($0, a["name"]?.stringValue ?? $0) } }, uniquingKeysWith: { first, _ in first })
            say("Rooms")
            for room in suggestion.rooms { say("  \(room.name): \(room.accessories.map { names[$0] ?? $0 }.joined(separator: ", "))") }
            if !suggestion.renames.isEmpty { say("\nRenames") }
            for rename in suggestion.renames { say("  \(names[rename.uniqueId] ?? rename.uniqueId) → \(rename.name)\(rename.reason.map { " (\($0))" } ?? "")") }
            if !suggestion.orphans.isEmpty { say("\nOrphans") }
            for orphan in suggestion.orphans { say("  \(names[orphan.uniqueId] ?? orphan.uniqueId): \(orphan.reason)") }
        }
        printFooter(assistant: assistant, model: assistant.model, usage: suggestion.usage)
    }
}

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
