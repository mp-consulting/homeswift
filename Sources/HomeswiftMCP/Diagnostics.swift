import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

// Diagnostics (GLOSSARY.md): one JSON file a person downloads for a plugin instance or an accessory, reviews, and
// attaches to an issue. It holds what someone helping needs: the versions and the platform, the Plugin Settings and
// Accessory Settings with their secrets masked, the accessories' services and current values, the plugin's last
// 1,000 log lines redacted, and how many errors and warnings it logged. Names stay: the person reads the file before
// sharing it. The web UI's ⋯ menus download it; MCP clients get it from get_diagnostics (administrators only).

extension HomeswiftCatalog {
    /// What a Diagnostics file is for: a plugin instance, or one accessory and its instance.
    public enum DiagnosticsTarget: Sendable, Equatable {
        case plugin(platform: String, name: String?)
        case accessory(id: String)
    }

    /// The most log lines a file carries.
    public static let diagnosticsLogLines = 1_000
    /// How far back the error counts look.
    static let diagnosticsErrorWindow: TimeInterval = 7 * 86_400

    /// The Diagnostics of a plugin instance or an accessory, as one JSON object.
    public func diagnosticsJSON(_ target: DiagnosticsTarget, now: Date = Date()) async throws -> JSONValue {
        // The blocks as the settings tools read them: an accessory plugin's `accessories` blocks too.
        let platforms = AccessoryAdoption.platformBlocks(of: try readConfig())
        let platform: String, instance: String, block: JSONValue
        var accessories: [Located]
        var deviceKeys: Set<String>?
        var subject: [String: JSONValue]
        switch target {
        case .plugin(let wanted, let name):
            let found = try Self.uniqueBlock(platform: wanted, instance: name, in: platforms)
            (platform, block) = (wanted, found.block)
            instance = found.block["name"]?.stringValue ?? wanted
            accessories = located().filter { $0.platform?.platform == platform && $0.platform?.name == instance }
            subject = ["about": "plugin"]
        case .accessory(let id):
            let settings = try settingsTarget(id, platforms: platforms)
            (platform, instance) = (settings.platform, settings.instance)
            block = Self.blockIndex(of: settings, in: platforms).map { platforms[$0] } ?? [:]
            accessories = settings.located.map { [$0] } ?? []
            deviceKeys = [settings.key, settings.deviceKey]
            subject = ["about": "accessory", "accessory": .string(id)]
        }
        accessories.sort { $0.accessory.id < $1.accessory.id }

        var answer: [String: JSONValue] = subject.merging([
            "diagnostics": 1,
            "generated": .string(Timestamp.iso8601(now)),
            "note": "Secrets are masked and the log is redacted; names are kept. Read it before sharing it.",
            "homeswift": Self.diagnosticsSystem(),
            "plugin": await diagnosticsPlugin(platform: platform, instance: instance),
            "pluginSettings": Self.diagnosticsPluginSettings(block),
            "accessorySettings": Self.diagnosticsAccessorySettings(block, keys: deviceKeys),
            "accessories": .array(accessories.map { Self.redactingSecrets(Self.accessoryJSON($0, detailed: true)) }),
        ]) { $1 }
        // The archive is read off the concurrency pool, as the log routes read it.
        let logs = logs
        let (log, counts) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: Self.diagnosticsLog(logs, instance: instance, now: now)) }
        }
        answer["log"] = log
        answer["errors"] = counts
        return .object(answer)
    }

    /// The versions and the platform (`get_system_info`'s facts), with the architecture and the MCP protocol; not the
    /// machine's name, which says nothing about a fault.
    static func diagnosticsSystem() -> JSONValue {
        var info = systemJSON().objectValue ?? [:]
        info.removeValue(forKey: "hostname")
        info.removeValue(forKey: "systemUptimeSeconds")
        #if arch(arm64)
        info["architecture"] = "arm64"
        #elseif arch(x86_64)
        info["architecture"] = "x86_64"
        #else
        info["architecture"] = "other"
        #endif
        info["version"] = info.removeValue(forKey: "homeswift") ?? .string(PluginHost.version)
        info["mcpProtocol"] = .string(MCPServer.protocolVersion)
        return .object(info)
    }

    /// The instance as it runs: its plugin, bridge, whether it is paused or started, why it did not start, its account.
    func diagnosticsPlugin(platform: String, instance: String) async -> JSONValue {
        let entry = host.registry.entry(for: platform)
        let running = host.platforms.first { $0.platform == platform && $0.name == instance }
        let accounts = await host.accountStates()
        var answer: [String: JSONValue] = [
            "platform": .string(platform), "name": .string(instance), "plugin": entry.map { .string($0.name) } ?? .null,
            "compiledIn": .bool(entry != nil), "running": .bool(running != nil), "paused": .bool(running?.paused ?? false),
            "bridge": running.map { .string($0.bridge.name) } ?? .null, "accessories": .number(Double(running?.accessoryIDs.count ?? 0)),
            "startFailure": host.startFailure(platform: platform, name: instance).map { .string(Redaction.redactText($0)) } ?? .null,
        ]
        if let entry {
            answer["accountAuthorization"] = .string(entry.accountAuthorization.rawValue)
            answer["accountState"] = .string((accounts["\(platform)/\(instance)"] ?? AccountState.none).rawValue)
        }
        return .object(answer)
    }

    /// The Plugin Settings: the block without its Accessory Settings, every secret masked.
    static func diagnosticsPluginSettings(_ block: JSONValue) -> JSONValue {
        var settings = block.objectValue ?? [:]
        settings.removeValue(forKey: "_accessories")
        return redactingSecrets(.object(settings))
    }

    /// The Accessory Settings by Device Id, every secret masked; only `keys` when given (one accessory's).
    static func diagnosticsAccessorySettings(_ block: JSONValue, keys: Set<String>?) -> JSONValue {
        var entries = block["_accessories"]?.objectValue ?? [:]
        if let keys { entries = entries.filter { keys.contains($0.key) } }
        return redactingSecrets(.object(entries))
    }

    /// `Redaction.redactSecrets` (what secret-named keys hold; a reference keeps its name), then every other text as the
    /// log's: free text redacted, sealed values hidden, and each URL's credentials masked (`Redaction.maskingURLCredentials`).
    static func redactingSecrets(_ value: JSONValue) -> JSONValue {
        func text(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object): return .object(object.mapValues(text))
            case .array(let items): return .array(items.map(text))
            case .string(let string) where string != Redaction.placeholder:
                if string.hasPrefix(Redaction.sealedPrefix) { return .string(Redaction.placeholder) }
                return .string(Redaction.maskingURLCredentials(Redaction.redactText(string)))
            default: return value
            }
        }
        return text(Redaction.redactSecrets(value))
    }

    /// The instance's last lines (`diagnosticsLogLines`, oldest first) and its errors and warnings over the week the log
    /// keeps, in one pass; each line as get_recent_logs gives it (`logText`: redacted, confirmation codes hidden, long
    /// payloads cut) with its URLs' credentials masked.
    static func diagnosticsLog(_ logs: LogBuffer, instance: String, now: Date) -> (log: JSONValue, counts: JSONValue) {
        let since = now.addingTimeInterval(-diagnosticsErrorWindow)
        let week = logs.lines(from: since, to: now, limit: 100_000, matching: { $0.label == instance })
        let lines = week.suffix(diagnosticsLogLines)
        let errors = week.filter { $0.level >= .error }
        let warnings = week.lazy.filter { $0.level == .warning }.count
        let shown = { (text: String) in JSONValue.string(Redaction.maskingURLCredentials(text)) }
        let log: JSONValue = [
            "lines": .array(lines.map { shown(logText($0, details: true)) }),
            "count": .number(Double(lines.count)), "limit": .number(Double(diagnosticsLogLines)),
            "from": lines.first.map { .string(Timestamp.iso8601($0.date)) } ?? .null,
        ]
        let counts: JSONValue = [
            "since": .string(Timestamp.iso8601(since)),
            "errors": .number(Double(errors.count)), "warnings": .number(Double(warnings)),
            "lastError": errors.last.map { .object(["date": .string(Timestamp.iso8601($0.date)), "text": shown(safe($0.text))]) } ?? .null,
        ]
        return (log, counts)
    }

    /// The file's name: `homeswift-diagnostics-<slug>-<date>.json`.
    public static func diagnosticsFileName(_ target: DiagnosticsTarget, now: Date = Date()) -> String {
        let what: String
        switch target {
        case .plugin(let platform, let name): what = Slug.make(name ?? platform)
        case .accessory(let id): what = Slug.make(id)
        }
        let day = Timestamp.iso8601(now).prefix(10)
        return "homeswift-diagnostics-\(what.isEmpty ? "bridge" : what)-\(day).json"
    }

    // MARK: Tool

    var diagnosticsTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_diagnostics", title: "Get diagnostics",
                description: "The Diagnostics of a plugin instance (plugin: platform, and name when there are several) or of an accessory (accessory: its Accessory Id), "
                    + "the file the web UI's ⋯ menus download: homeswift's version and platform, the plugin's state, its Plugin Settings and Accessory Settings with secrets masked, "
                    + "the accessories' services and current values, its last 1,000 log lines redacted, and its errors and warnings over the last week. Names are kept.",
                inputSchema: ["type": "object", "properties": [
                    "accessory": ["type": "string", "description": "An Accessory Id (list_accessories' id)"],
                    "plugin": ["type": "object", "required": ["platform"], "additionalProperties": false, "properties": [
                        "platform": ["type": "string", "description": "The plugin's platform, as list_plugins gives it"],
                        "name": ["type": "string", "description": "The plugin instance's (block's) name, when the platform has several"],
                    ]],
                ]],
                // config.json's values and the log: hidden from a user who is not an administrator (`administratorOnly`).
                scope: .read, idempotent: true
            ) { call in
                let target: DiagnosticsTarget
                if let id = call.optionalString("accessory") {
                    target = .accessory(id: id)
                } else if let plugin = Self.pluginArgument(call) {
                    target = .plugin(platform: plugin.platform, name: plugin.name)
                } else {
                    return .error("Pass accessory or plugin")
                }
                let bundle = call.session.vault.conceal(try await catalog.diagnosticsJSON(target))
                // Names, values and log lines came from devices, plugins and config.json: data, never instructions.
                return ToolResult(text: "<untrusted-data source=\"diagnostics\">\n\(bundle.text(pretty: true))\n</untrusted-data>", structured: bundle)
            },
        ]
    }
}
