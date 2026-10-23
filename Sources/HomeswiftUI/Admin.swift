import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import NIOHTTP1

/// The scheduled restart and daily backup of a running web UI, and when they next run.
struct ScheduleState: Sendable {
    var tasks: [Task<Void, Never>] = []
    var nextBackup: Date?
    var nextRestart: Date?
}

// The Settings pages' API, after the Homebridge UI's server, child-bridges, config-editor and backup modules:
// the bridge block, pairings and accessory caches, child bridges, config.json backups, whole-instance backups and
// their restore, the audit log, and an accessory's recorded history. Each calls the catalog, as the MCP tools do.
// Everything but the history is for administrators; every change is in the audit log as client "web UI".

extension UIServer {
    /// Whether this user may administer the bridge. Every account of the web UI is an administrator for now
    /// (docs/ui.md); the Settings routes ask here, so a role that is not one is refused in one place.
    func isAdmin(_ username: String) -> Bool { true }

    /// The restore route takes the archive itself, not JSON.
    static func acceptsArchive(_ request: Request) -> Bool {
        let type = (request.headers["content-type"] ?? "").lowercased()
        return request.path == "/api/backups/restore" && (type.hasPrefix("application/x-tar") || type.hasPrefix("application/octet-stream"))
    }

    /// The Settings routes, or nil for another route.
    func adminAPI(_ route: [String], _ request: Request, username: String) async throws -> Reply? {
        let method = request.method
        // An accessory's history is anyone's to read: the accessory is on the page already.
        if method == .GET, route.count == 3, route[0] == "accessories", route[2] == "history" {
            let hours = request.query["hours"].flatMap(Double.init) ?? 24
            guard hours > 0, hours <= 8760 else { return .error(400, "hours must be between 0 and 8760") }
            let points = min(max(request.query["points"].flatMap(Int.init) ?? 240, 2), 1000)
            do {
                return .json(try catalog.accessoryHistoryJSON(id: route[1], hours: hours, maxPoints: points))
            } catch let error as CatalogError {
                return .error(404, error.description)
            }
        }
        let routes: Set<String> = ["settings", "pairings", "cached-accessories", "child-bridges", "backups", "audit"]
        let isConfigBackups = route.count >= 2 && route[0] == "config" && route[1] == "backups"
        guard let first = route.first, routes.contains(first) || isConfigBackups else { return nil }
        guard isAdmin(username) else { return .error(403, "only an administrator can do this") }
        if request.truncated { return .error(413, "the upload is larger than \(InstanceBackups.maxArchiveSize / 1_048_576) MB") }
        // Everything but the archive upload is JSON.
        let body: JSONValue = request.body.isEmpty || Self.acceptsArchive(request) ? .null : try JSONValue(data: request.body)
        let confirmed = body["confirm"]?.boolValue == true
        do {
            switch (method, route) {
            // The bridge block, and what this machine runs it with.
            case (.GET, ["settings", "bridge"]):
                return .json(try catalog.bridgeSettingsJSON())
            case (.PUT, ["settings", "bridge"]):
                guard let settings = body["settings"]?.objectValue else { return .error(400, "settings are required") }
                return .json(try await catalog.updateBridgeSettings(settings, dryRun: body["dryRun"]?.boolValue == true))

            // Pairings and accessory caches.
            case (.GET, ["pairings"]):
                return .json(catalog.pairingJSON())
            case (.POST, ["pairings", "reset"]):
                guard confirmed else { return .error(400, "resetting pairings needs confirm: true") }
                let result = try catalog.resetPairings(bridge: body["bridge"]?.stringValue)
                logger.warning("Web UI reset a bridge's pairings", metadata: ["user": "\(username)", "bridge": "\(result["bridge"]?.stringValue ?? "?")"])
                return .json(result)
            case (.GET, ["cached-accessories"]):
                return .json(catalog.cachedAccessoriesJSON())
            case (.POST, ["cached-accessories", "remove"]):
                guard let id = body["id"]?.stringValue else { return .error(400, "id is required") }
                return .json(try await catalog.removeCachedAccessory(id: id, cacheFile: body["cacheFile"]?.stringValue))
            case (.POST, ["cached-accessories", "reset"]):
                guard confirmed else { return .error(400, "resetting the caches needs confirm: true") }
                logger.warning("Web UI reset every accessory cache", metadata: ["user": "\(username)"])
                return .json(await catalog.resetCachedAccessories())

            // Child bridges: their health, and the pairing code of one not yet in the Home app, as the Status page shows.
            case (.GET, ["child-bridges"]):
                return .json(childBridgesJSON())
            case let (.POST, path) where path.count == 3 && path[0] == "child-bridges":
                guard let action = HomeswiftCatalog.ChildBridgeAction(rawValue: path[2]) else { return .error(404, "no action \(path[2]): stop, start or restart") }
                return .json(try await catalog.controlChildBridge(action, id: path[1]))

            // config.json's backups.
            case (.GET, ["config", "backups"]):
                return .json(catalog.configBackupsJSON())
            case let (.GET, path) where path.count == 3 && path[0] == "config":
                return .text(try catalog.configBackupText(named: path[2]), contentType: "application/json")
            case let (.POST, path) where path.count == 4 && path[0] == "config" && path[3] == "restore":
                let result = try await catalog.restoreConfigBackup(path[2])
                logger.info("Web UI restored a config.json backup", metadata: ["user": "\(username)", "backup": "\(path[2])"])
                return .json(result)

            // Instance backups.
            case (.GET, ["backups"]):
                var answer = try catalog.instanceBackupsJSON().objectValue ?? [:]
                let state = schedules.withLockedValue { $0 }
                answer["nextBackup"] = state.nextBackup.map { .string(Timestamp.iso8601($0)) } ?? .null
                answer["nextRestart"] = state.nextRestart.map { .string(Timestamp.iso8601($0)) } ?? .null
                answer["restartCron"] = configuration.scheduledRestart.map { .string($0.expression) } ?? .null
                answer["canRestart"] = .bool(catalog.canRestart)
                return .json(.object(answer))
            case (.POST, ["backups"]):
                return .json(try await catalog.createInstanceBackup(), status: 201)
            case (.GET, ["backups", "download"]):
                let archive = try await catalog.makeInstanceBackupArchive()
                logger.info("Web UI downloaded a backup", metadata: ["user": "\(username)", "bytes": "\(archive.data.count)"])
                return Self.download(archive.data, name: archive.fileName)
            case let (.GET, path) where path.count == 3 && path[0] == "backups" && path[2] == "download":
                let backup = try catalog.instanceBackups.backup(id: path[1])
                return Self.download(try Data(contentsOf: backup.url), name: backup.fileName)
            case let (.DELETE, path) where path.count == 2 && path[0] == "backups":
                try catalog.instanceBackups.delete(id: path[1])
                return .json(["deleted": .string(path[1])])
            case (.POST, ["backups", "restore"]):
                guard !request.body.isEmpty else { return .error(400, "send the archive (Content-Type: application/x-tar)") }
                return .json(try await catalog.restoreInstanceBackup(archive: request.body, requestedBy: "web UI user \(username)"))
            case let (.POST, path) where path.count == 3 && path[0] == "backups" && path[2] == "restore":
                return .json(try await catalog.restoreInstanceBackup(id: path[1], requestedBy: "web UI user \(username)"))

            // The audit log.
            case (.GET, ["audit"]):
                var query = HomeswiftCatalog.AuditQuery(
                    tool: request.query["tool"]?.nonEmpty, client: request.query["client"]?.nonEmpty, outcome: request.query["outcome"]?.nonEmpty,
                    limit: request.query["limit"].flatMap(Int.init) ?? 500)
                if let since = request.query["since"]?.nonEmpty {
                    guard let date = Self.date(iso: since) ?? HomeswiftCatalog.parseTimeBound(since) else { return .error(400, "since: an ISO time, or 1h, 24h, 7d") }
                    query.since = date
                }
                return .json(catalog.auditEntriesJSON(query))
            default:
                return .error(404, "unknown API route")
            }
        } catch let error as InstanceBackups.BackupError {
            return .error(400, error.description)
        } catch let error as CatalogError {
            return .error(400, error.description)
        }
    }

    static func download(_ data: Data, name: String) -> Reply {
        .data(status: 200, contentType: "application/x-tar", body: data, headers: ["Content-Disposition": "attachment; filename=\"\(name)\""])
    }

    /// The child bridges with their health, and, for one not paired yet, its setup code and the index of its QR code
    /// (`/api/qr/<index>.svg`), as the Status page gives the main bridge's.
    func childBridgesJSON() -> JSONValue {
        let health = (try? catalog.childBridgeHealthJSON())?["bridges"]?.arrayValue ?? []
        let status = catalog.statusJSON(includePairing: true)["bridges"]?.arrayValue ?? []
        return ["childBridges": .array(health.map { bridge in
            guard var object = bridge.objectValue else { return bridge }
            if let index = status.firstIndex(where: { $0["deviceId"] == bridge["id"] }) {
                object["qrIndex"] = .number(Double(index))
                if let code = status[index]["setupCode"] { object["setupCode"] = code }
            }
            return .object(object)
        })]
    }

    // MARK: The audit log

    /// Records a change made from the UI in the MCP audit log, as client "web UI" with the user as principal: the
    /// route, the outcome and a small JSON body with its secrets masked. The Assistant's chat is recorded by its own
    /// tool calls; a password change without its body.
    func audit(_ route: [String], _ request: Request, username: String, reply: Reply) {
        // The Assistant's requests and each user's own preferences change nothing of the bridge.
        guard let auditLog, route.first != "assistant", route.first != "preferences" else { return }
        var status = 200
        var error: String?
        if case .data(let code, _, let body, _) = reply {
            status = code
            if code >= 400 { error = (try? JSONValue(data: body))?["error"]?.stringValue }
        }
        var arguments: JSONValue = [:]
        if route != ["account", "password"], !request.body.isEmpty {
            if request.body.count <= 2048, !Self.acceptsArchive(request), let json = try? JSONValue(data: request.body) {
                arguments = Redaction.redactSecrets(json)
            } else {
                arguments = ["bytes": .number(Double(request.body.count))]
            }
        }
        auditLog.record(AuditLog.Entry(
            tool: "\(request.method.rawValue) /api/\(route.joined(separator: "/"))", arguments: arguments, ok: status < 400, error: error,
            session: "web-ui", client: "web UI", principal: username, scope: .admin))
    }

    // MARK: Schedules

    /// Starts the scheduled restart (`scheduledRestartCron`) and the daily backup (unless `scheduledBackupDisable`),
    /// at a random time between midnight and 7:00, as upstream picks it, kept `scheduledBackupDays` days.
    func startSchedules() {
        var tasks: [Task<Void, Never>] = []
        if let cron = configuration.scheduledRestart {
            tasks.append(Task { [self] in
                while !Task.isCancelled {
                    guard let next = cron.next(after: Date()) else { return }
                    schedules.withLockedValue { $0.nextRestart = next }
                    guard await Self.sleep(until: next) else { return }
                    logger.warning("Scheduled restart", metadata: ["cron": "\(cron.expression)"])
                    if !catalog.scheduleRestart(requestedBy: "the scheduled restart (\(cron.expression))") {
                        logger.warning("The scheduled restart cannot run: this process cannot restart itself")
                    }
                    try? await Task.sleep(for: .seconds(61))
                }
            })
        }
        if !configuration.scheduledBackupDisable, let daily = try? CronSchedule("\(Int.random(in: 0...59)) \(Int.random(in: 0...6)) * * *") {
            tasks.append(Task { [self] in
                while !Task.isCancelled {
                    guard let next = daily.next(after: Date()) else { return }
                    schedules.withLockedValue { $0.nextBackup = next }
                    guard await Self.sleep(until: next) else { return }
                    await runScheduledBackup()
                }
            })
        }
        schedules.withLockedValue { $0.tasks = tasks }
    }

    func stopSchedules() {
        schedules.withLockedValue { state in
            state.tasks.forEach { $0.cancel() }
            state = ScheduleState()
        }
    }

    /// The daily backup: a new archive in the folder, then this bridge's archives older than the retention removed.
    func runScheduledBackup() async {
        do {
            let result = try await catalog.createInstanceBackup()
            let removed = catalog.instanceBackups.prune(keepingDays: configuration.scheduledBackupDays)
            let file = result["backup"]?["fileName"]?.stringValue ?? "?"
            logger.info("Scheduled backup done", metadata: ["file": "\(file)", "removed": "\(removed.count)"])
            await catalog.notify(.backupSucceeded, title: "Scheduled backup done", message: "The scheduled instance backup \(file) was saved.", path: "/settings/backups", subject: file)
        } catch {
            logger.warning("Scheduled backup failed", metadata: ["error": "\(error)"])
            await catalog.notify(.backupFailed, title: "Scheduled backup failed", message: "The scheduled instance backup failed: \(Redaction.redactText("\(error)"))", urgent: true, path: "/settings/backups")
        }
    }

    /// Sleeps until `date` in steps of five minutes at most, so a clock that changes or a machine that slept does not
    /// push it far past; false when cancelled.
    static func sleep(until date: Date) async -> Bool {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return !Task.isCancelled }
            do { try await Task.sleep(for: .seconds(min(remaining, 300))) } catch { return false }
        }
    }
}
