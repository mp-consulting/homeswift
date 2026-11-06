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
        let platforms = try readConfig()["platforms"]?.arrayValue ?? []
        let platform: String, instance: String
        var accessories: [Located]
        var deviceKeys: [String]?
        switch target {
        case .plugin(let wanted, let name):
            let found = try Self.uniqueBlock(platform: wanted, instance: name, in: platforms)
            platform = wanted
            instance = found.block["name"]?.stringValue ?? wanted
            accessories = located().filter { $0.platform?.platform == platform && $0.platform?.name == instance }
        case .accessory(let id):
            let settings = try settingsTarget(id, platforms: platforms)
            platform = settings.platform
            instance = settings.instance
            accessories = settings.located.map { [$0] } ?? []
            deviceKeys = Array(Set([settings.key, settings.deviceKey])).sorted()
        }
        let block = platforms.first { $0["platform"]?.stringValue == platform && ($0["name"]?.stringValue ?? platform) == instance } ?? [:]
        accessories.sort { $0.accessory.id < $1.accessory.id }

        var answer: [String: JSONValue] = [
            "diagnostics": 1,
            "generated": .string(Timestamp.iso8601(now)),
            "about": .string(target.isPlugin ? "plugin" : "accessory"),
            "note": "Secrets are masked and the log is redacted; names are kept. Read it before sharing it.",
            "homeswift": Self.diagnosticsSystem(),
            "plugin": await diagnosticsPlugin(platform: platform, instance: instance),
            "pluginSettings": Self.diagnosticsPluginSettings(block),
            "accessorySettings": Self.diagnosticsAccessorySettings(block, keys: deviceKeys),
            "accessories": .array(accessories.map { Self.redactingSecrets(Self.accessoryJSON($0, detailed: true)) }),
        ]
        if case .accessory(let id) = target { answer["accessory"] = .string(id) }
        let (log, counts) = diagnosticsLog(instance: instance, now: now)
        answer["log"] = log
        answer["errors"] = counts
        return .object(answer)
    }

    /// The versions and the platform; not the machine's name, which says nothing about a fault.
    static func diagnosticsSystem() -> JSONValue {
        let process = ProcessInfo.processInfo
        #if os(macOS)
        let platform = "macOS"
        #elseif os(Linux)
        let platform = "Linux"
        #else
        let platform = "other"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "other"
        #endif
        return [
            "version": .string(PluginHost.version), "mcpProtocol": .string(MCPServer.protocolVersion), "platform": .string(platform),
            "os": .string(process.operatingSystemVersionString), "architecture": .string(architecture),
            "cpus": .number(Double(process.processorCount)), "memoryBytes": .number(Double(process.physicalMemory)),
        ]
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

    /// The Plugin Settings: the block without its Accessory Settings, every secret masked (secret-named keys, sealed
    /// values, the MCP tokens of the Assistant's block).
    static func diagnosticsPluginSettings(_ block: JSONValue) -> JSONValue {
        var settings = block.objectValue ?? [:]
        settings.removeValue(forKey: "_accessories")
        return redactingSecrets(redactingMCPTokens(inSettings: ["settings": .object(settings)])["settings"] ?? .object(settings))
    }

    /// The Accessory Settings by Device Id, every secret masked; only `keys` when given (one accessory's).
    static func diagnosticsAccessorySettings(_ block: JSONValue, keys: [String]?) -> JSONValue {
        var entries = block["_accessories"]?.objectValue ?? [:]
        if let keys { entries = entries.filter { keys.contains($0.key) } }
        return redactingSecrets(.object(entries))
    }

    /// Masks what a secret-named key holds (`Redaction`'s, and for Diagnostics any key ending in "key", such as a hub's
    /// `applicationKey` or a device's `localKey`: masking too much is the safe side), and any value that is a secret on
    /// its own (a sealed `enc:` value, a credential in a URL), wherever it is.
    static func redactingSecrets(_ value: JSONValue) -> JSONValue {
        func walk(_ value: JSONValue, secret: Bool) -> JSONValue {
            switch value {
            case .object(let object):
                return .object(object.reduce(into: [:]) { result, entry in
                    result[entry.key] = walk(entry.value, secret: secret || isDiagnosticsSecret(key: entry.key, value: entry.value))
                })
            case .array(let items):
                return .array(items.map { walk($0, secret: secret) })
            case .string(let text):
                return secret || text.hasPrefix(SecretBox.prefix) || Redaction.isCredentialURL(text) ? .string(Redaction.placeholder) : value
            case .number, .bool:
                return secret ? .string(Redaction.placeholder) : value
            default:
                return value
            }
        }
        return walk(value, secret: false)
    }

    static func isDiagnosticsSecret(key: String, value: JSONValue) -> Bool {
        Redaction.isSecret(key: key, value: value) || key.range(of: #"keys?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The instance's last lines (`diagnosticsLogLines`, oldest first, each redacted) and its errors and warnings over
    /// the last week of the log the bridge keeps.
    func diagnosticsLog(instance: String, now: Date) -> (log: JSONValue, counts: JSONValue) {
        let mine = { (line: LogBuffer.Line) in line.label == instance }
        let lines = logs.lines(from: .distantPast, to: now, limit: Self.diagnosticsLogLines, matching: mine)
        let since = now.addingTimeInterval(-Self.diagnosticsErrorWindow)
        let serious = logs.lines(from: since, to: now, limit: 100_000, matching: { mine($0) && $0.level >= .warning })
        let errors = serious.filter { $0.level >= .error }
        let log: JSONValue = [
            "lines": .array(lines.map { .string(Redaction.redactText($0.formattedWithDetails)) }),
            "count": .number(Double(lines.count)), "limit": .number(Double(Self.diagnosticsLogLines)),
            "from": lines.first.map { .string(Timestamp.iso8601($0.date)) } ?? .null,
        ]
        let counts: JSONValue = [
            "since": .string(Timestamp.iso8601(since)),
            "errors": .number(Double(errors.count)), "warnings": .number(Double(serious.count - errors.count)),
            "lastError": errors.last.map { .object(["date": .string(Timestamp.iso8601($0.date)), "text": .string(Redaction.redactText($0.text))]) } ?? .null,
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

extension HomeswiftCatalog.DiagnosticsTarget {
    var isPlugin: Bool { if case .plugin = self { true } else { false } }
}
