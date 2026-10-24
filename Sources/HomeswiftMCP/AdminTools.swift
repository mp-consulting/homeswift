import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// The catalog's administration of the instance: config.json backups, whole-instance backups and their restore,
// the audit log, the bridge block. The web UI's Settings pages call these, and the MCP server lists them as tools.

extension HomeswiftCatalog {
    /// The web UI's block, where the backup schedule's settings live (`scheduledBackupPath`, …): read raw, since this
    /// module does not know the UI's types.
    var uiBlock: JSONValue? { try? host.configuration.block(for: "HomeswiftUI") }

    /// Whether this process can restart itself (the `homeswift` binary can; a library or a test cannot).
    public var canRestart: Bool { restart != nil }

    // MARK: config.json backups

    /// `config-2026-10-23T08-20-31Z[-2].json` → its date; the file's own date when the name does not say.
    static func configBackupDate(_ name: String, at url: URL) -> Date? {
        var stamp = name.dropFirst("config-".count).dropLast(".json".count)
        if let zone = stamp.firstIndex(of: "Z") { stamp = stamp[...zone] }
        if let t = stamp.firstIndex(of: "T") {
            let time = stamp[stamp.index(after: t)...].replacingOccurrences(of: "-", with: ":")
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: "\(stamp[..<t])T\(time)") { return date }
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `{"backups": [{name, date, bytes}]}`, newest first: what each save of config.json kept of the file before it.
    public func configBackupsJSON() -> JSONValue {
        let entries = backups().reversed().map { name -> JSONValue in
            let url = backupsDirectory.appendingPathComponent(name)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            return ["name": .string(name), "date": Self.configBackupDate(name, at: url).map { .string(Timestamp.iso8601($0)) } ?? .null, "bytes": .number(Double(bytes))]
        }
        return ["backups": .array(Array(entries)), "kept": 20, "folder": .string(backupsDirectory.path)]
    }

    /// A config.json backup's text, as it was saved.
    public func configBackupText(named name: String) throws -> String {
        guard backups().contains(name) else { throw CatalogError("No config backup \(name)") }
        return try String(contentsOf: backupsDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Puts a backup back as config.json (the current file is backed up first) and applies it like a save.
    public func restoreConfigBackup(_ name: String, dryRun: Bool = false) async throws -> JSONValue {
        let config = try JSONValue(data: Data(configBackupText(named: name).utf8))
        // The file as it was: its settings were saved once, whatever the plugins' schemas say now.
        return try await applyConfig(config, dryRun: dryRun, checkSchemas: false)
    }

    // MARK: Instance backups

    /// The instance's backups: in `scheduledBackupPath` when the web UI's block names one, else `instance-backups/`
    /// next to config.json.
    public var instanceBackups: InstanceBackups {
        let path = uiBlock?["scheduledBackupPath"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        return InstanceBackups(
            storage: configURL.deletingLastPathComponent(), folder: path.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            instanceID: host.configuration.bridge.username ?? host.mainBridge.server.deviceID, logger: logger)
    }

    /// How many days scheduled backups are kept (`scheduledBackupDays`, 7 by default).
    public var backupRetentionDays: Int { max(1, uiBlock?["scheduledBackupDays"]?.intValue ?? InstanceBackups.defaultRetentionDays) }

    /// Whether the daily backup runs: the web UI runs it, unless its block says `scheduledBackupDisable`.
    public var scheduledBackupsEnabled: Bool { uiBlock != nil && uiBlock?["scheduledBackupDisable"]?.boolValue != true }

    public static func backupJSON(_ backup: InstanceBackups.Backup) -> JSONValue {
        ["id": .string(backup.id), "instance": .string(backup.instanceID), "date": .string(Timestamp.iso8601(backup.date)), "fileName": .string(backup.fileName), "bytes": .number(Double(backup.bytes))]
    }

    /// What `info.json` says beside the format: the bridge and the plugins this homeswift has, for whoever opens it.
    var backupInfo: [String: JSONValue] {
        [
            "bridge": .string(host.mainBridge.name), "deviceId": .string(host.mainBridge.server.deviceID), "hostname": .string(Self.machineName()),
            "plugins": .array(host.registry.entries.map { ["platform": .string($0.platform), "name": .string($0.name)] }),
        ]
    }

    /// `{"backups": [...], "folder", "retentionDays", "scheduled", "pendingRestore"}`, newest first.
    public func instanceBackupsJSON() throws -> JSONValue {
        let backups = instanceBackups
        return [
            "backups": .array(try backups.list().map(Self.backupJSON)), "folder": .string(backups.folder.path), "retentionDays": .number(Double(backupRetentionDays)),
            "scheduled": .bool(scheduledBackupsEnabled), "pendingRestore": .bool(backups.hasPendingRestore), "maxRestoreBytes": .number(Double(InstanceBackups.maxArchiveSize)),
        ]
    }

    /// Makes a backup in the folder, off the concurrency pool (it reads every file of the storage directory).
    public func createInstanceBackup() async throws -> JSONValue {
        let backups = instanceBackups
        let info = backupInfo
        let backup = try await Self.offPool { try backups.create(info: info) }
        logger.info("Instance backup created", metadata: ["file": "\(backup.fileName)", "bytes": "\(backup.bytes)"])
        return ["created": true, "backup": Self.backupJSON(backup)]
    }

    /// A fresh archive to download, and its file name; nothing is kept.
    public func makeInstanceBackupArchive() async throws -> (data: Data, fileName: String) {
        let backups = instanceBackups
        let info = backupInfo
        let data = try await Self.offPool { try backups.makeArchive(info: info).data }
        return (data, backups.downloadName())
    }

    /// Checks an archive, stages it for the next start, and restarts homeswift to apply it.
    public func restoreInstanceBackup(archive: Data, requestedBy who: String) async throws -> JSONValue {
        let backups = instanceBackups
        let staged = try await Self.offPool { try backups.stageRestore(archive) }
        logger.warning("Instance backup staged for restore", metadata: ["by": "\(who)", "files": "\(staged.files)", "created": "\(staged.created ?? "?")"])
        let restarting = scheduleRestart(requestedBy: "\(who): restoring a backup")
        return [
            "staged": true, "files": .number(Double(staged.files)), "created": staged.created.map(JSONValue.string) ?? .null,
            "version": staged.version.map(JSONValue.string) ?? .null, "bridge": staged.bridge.map(JSONValue.string) ?? .null,
            "skipped": .array(staged.skipped.map(JSONValue.string)), "restarting": .bool(restarting),
            "note": .string(restarting ? "homeswift restarts now and starts on the restored files." : "Restart homeswift to apply the restore: it is applied before anything else at the next start."),
        ]
    }

    /// Restores one of the folder's backups.
    public func restoreInstanceBackup(id: String, requestedBy who: String) async throws -> JSONValue {
        let backup = try instanceBackups.backup(id: id)
        return try await restoreInstanceBackup(archive: try Data(contentsOf: backup.url), requestedBy: who)
    }

    static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: The audit log

    /// The audit log the MCP block asks for, which the MCP server and the web UI's chat write: nil with `auditLog: false`.
    public func auditLog() -> AuditLog? {
        let block: JSONValue? = try? host.configuration.block(for: AIConfiguration.platform)
        let mcp = block.flatMap { try? MCPConfiguration(block: $0) } ?? MCPConfiguration()
        return mcp.makeAuditLog(configDirectory: configURL.deletingLastPathComponent(), logger: logger)
    }

    public struct AuditQuery: Sendable {
        /// Part of the tool's name.
        public var tool: String?
        /// Part of the client's or the principal's name.
        public var client: String?
        /// `ok`, `failed` or `notConfirmed`.
        public var outcome: String?
        public var since: Date?
        public var limit = 200

        public init(tool: String? = nil, client: String? = nil, outcome: String? = nil, since: Date? = nil, limit: Int = 200) {
            self.tool = tool
            self.client = client
            self.outcome = outcome
            self.since = since
            self.limit = limit
        }
    }

    /// The audit log's entries, newest first, from the current file and its rotated ones: `{"enabled", "path",
    /// "total", "entries"}`. Arguments were redacted when written.
    public func auditEntriesJSON(_ query: AuditQuery) -> JSONValue {
        guard let log = auditLog() else { return ["enabled": false, "entries": [], "total": 0] }
        let files = [log.url] + (1...log.keep).map { log.url.appendingPathExtension("\($0)") }
        let formatter = ISO8601DateFormatter()
        var matched: [JSONValue] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let entry = try? JSONValue(string: String(line)), entry.objectValue != nil else { continue }
                if let tool = query.tool, !TextSearch.contains(entry["tool"]?.stringValue ?? "", caseless: tool) { continue }
                if let client = query.client, !TextSearch.contains("\(entry["client"]?.stringValue ?? "") \(entry["principal"]?.stringValue ?? "")", caseless: client) { continue }
                switch query.outcome {
                case "ok": if entry["ok"]?.boolValue != true { continue }
                case "failed": if entry["ok"]?.boolValue != false || entry["notConfirmed"]?.boolValue == true { continue }
                case "notConfirmed": if entry["notConfirmed"]?.boolValue != true { continue }
                default: break
                }
                if let since = query.since, let date = entry["ts"]?.stringValue.flatMap(formatter.date(from:)), date < since { continue }
                matched.append(entry)
            }
        }
        let limit = min(max(query.limit, 1), 2000)
        return ["enabled": true, "path": .string(log.url.path), "total": .number(Double(matched.count)), "entries": .array(Array(matched.prefix(limit)))]
    }

    // MARK: The bridge block

    /// The keys of config.json's `bridge` block a form may change. `username`, the HomeKit identity, is not one:
    /// a new one is a new bridge to the Home app.
    public static let bridgeSettingKeys = ["name", "port", "pin", "manufacturer", "model", "firmwareRevision"]

    /// The bridge block as config.json has it, with what runs: the port the server listens on and how it advertises.
    public func bridgeSettingsJSON() throws -> JSONValue {
        let bridge = try readConfig()["bridge"] ?? [:]
        #if os(macOS)
        let advertiser = "Bonjour (dns_sd)"
        #else
        let advertiser = "Avahi (its dns_sd compatibility layer)"
        #endif
        let addresses = NetworkInterfaces.ipv4().filter { $0.address >> 24 != 127 }.map { entry -> JSONValue in
            let octets = [24, 16, 8, 0].map { String((entry.address >> UInt32($0)) & 0xff) }.joined(separator: ".")
            return .string("\(octets)/\(entry.netmask.nonzeroBitCount)")
        }
        return [
            "bridge": bridge, "deviceId": .string(host.mainBridge.server.deviceID), "listeningPort": host.mainBridge.server.port.map { .number(Double($0)) } ?? .null,
            "advertiser": .string(advertiser), "addresses": .array(addresses),
        ]
    }

    /// Merges settings into the bridge block (null removes a key: an automatic port) and applies config.json, which
    /// restarts homeswift: the bridge block is its HomeKit identity.
    public func updateBridgeSettings(_ settings: [String: JSONValue], dryRun: Bool) async throws -> JSONValue {
        let unknown = settings.keys.filter { !Self.bridgeSettingKeys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw CatalogError("Not a bridge setting here: \(unknown.joined(separator: ", ")) (the device ID stays; reset_pairings starts the pairing over)") }
        if let name = settings["name"], name.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false { throw CatalogError("The bridge needs a name") }
        if let port = settings["port"], !port.isNull, port.portValue == nil { throw CatalogError("port must be a port number, or null for an automatic one") }
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        var bridge = root["bridge"]?.objectValue ?? [:]
        for (key, value) in settings {
            if value.isNull || value.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty == true { bridge.removeValue(forKey: key) } else { bridge[key] = value }
        }
        root["bridge"] = .object(bridge)
        return try await applyConfig(.object(root), dryRun: dryRun, current: current)
    }

    // MARK: Tools

    var adminTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "list_backups", title: "List instance backups",
                description: "The whole-instance backups (config.json, the bridges' pairings, accessory caches, plugin files) in the backup folder, made by the daily schedule or create_backup, newest first. "
                    + "The web UI downloads and restores them.",
                outputSchema: Output.list("backups", of: Output.object(["id": Output.string, "date": Output.string, "bytes": Output.number], required: ["id", "date"])),
                scope: .read, idempotent: true
            ) { _ in .json(try catalog.instanceBackupsJSON()) },
            MCPTool(
                name: "create_backup", title: "Create instance backup",
                description: "Makes a whole-instance backup (config.json, the bridges' HomeKit identity and pairings, accessory caches, plugin files, the web UI's users) in the backup folder, "
                    + "e.g. before a risky change. It appears in list_backups and can be downloaded or restored from the web UI.",
                scope: .admin, readOnly: false, destructive: false, idempotent: false
            ) { _ in .json(try await catalog.createInstanceBackup()) },
            MCPTool(
                name: "get_audit_log", title: "Read the audit log",
                description: "The audit log's entries, newest first: every write tool call of MCP clients and the web UI's chat, and the web UI's own changes (client \"web UI\"), "
                    + "with redacted arguments, the outcome and who made it. Filter by tool, client (or principal), outcome (ok, failed, notConfirmed) and since (ISO time or 30m, 1h, 2d).",
                inputSchema: ["type": "object", "properties": [
                    "tool": ["type": "string", "maxLength": 100], "client": ["type": "string", "maxLength": 100],
                    "outcome": ["type": "string", "enum": ["ok", "failed", "notConfirmed"]], "since": ["type": "string", "maxLength": 40],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Entries returned (default 50)"],
                ]],
                scope: .admin, readOnly: true, idempotent: true
            ) { call in
                var query = AuditQuery(tool: call.optionalString("tool"), client: call.optionalString("client"), outcome: call.optionalString("outcome"), limit: call.int("limit", default: 50))
                if let since = call.optionalString("since") {
                    guard let date = Self.parseTimeBound(since) else { return .error("since: use an ISO time or a duration such as 30m, 1h, 2d") }
                    query.since = date
                }
                let found = catalog.auditEntriesJSON(query)
                // Arguments and client names came from clients: data, never instructions.
                return ToolResult(text: "<untrusted-data source=\"audit-log\">\n\(found.text(pretty: true))\n</untrusted-data>", structured: found)
            },
            MCPTool(
                name: "update_bridge_settings", title: "Change the bridge settings",
                description: "Changes config.json's bridge block: name, port (null for an automatic one), pin (the setup code, XXX-XX-XXX), manufacturer, model, firmwareRevision. "
                    + "The device ID stays. homeswift restarts to apply it; every connection drops for a few seconds. dryRun previews.",
                inputSchema: ["type": "object", "required": ["settings"], "properties": [
                    "settings": ["type": "object", "additionalProperties": false, "properties": [
                        "name": ["type": "string", "minLength": 1], "port": ["type": ["integer", "null"], "minimum": 1, "maximum": 65535],
                        "pin": ["type": "string", "pattern": "^\\d{3}-\\d{2}-\\d{3}$"], "manufacturer": ["type": "string"], "model": ["type": "string"], "firmwareRevision": ["type": "string"],
                    ]],
                ]],
                scope: .admin, destructive: true, supportsDryRun: true
            ) { call in
                .json(try await catalog.updateBridgeSettings(call.arguments["settings"]?.objectValue ?? [:], dryRun: call.isDryRun))
            },
        ]
    }
}
