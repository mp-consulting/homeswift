import Foundation
import HomeswiftAI
import HomeswiftPlugin

// The vault's migration (docs/vault-design.md, "Migration"): the Vault page, `homeswift vault migrate` and the
// `migrate_to_vault` tool share it.
extension HomeswiftCatalog {
    public var vault: CredentialVault { CredentialVault(storage: storageDirectory) }

    /// What moving config.json's secrets into the vault would do, as it is now; `names`, `excluded` and `separate` by
    /// item id (`VaultMigration.plan`). Nothing is written.
    public func vaultMigrationPlan(names: [String: String] = [:], excluded: Set<String> = [], separate: Set<String> = []) throws -> VaultMigration {
        try Self.vaultMigrationPlan(configURL: configURL, names: names, excluded: excluded, separate: separate)
    }

    public static func vaultMigrationPlan(configURL: URL, names: [String: String] = [:], excluded: Set<String> = [], separate: Set<String> = []) throws -> VaultMigration {
        let storage = configURL.deletingLastPathComponent()
        let stored = try JSONValue(data: Data(contentsOf: configURL))
        return try VaultMigration.plan(
            stored: stored, opened: SecretBox.revealed(stored, storage: storage), existing: CredentialVault(storage: storage).entries(),
            names: names, excluded: excluded, separate: separate)
    }

    /// Moves config.json's secrets into the vault: adds the plan's entries, then saves and applies the config with the
    /// references (a backup of the file first, as every save). The entries it added go again when the save fails.
    /// `dryRun` answers the plan only.
    public func migrateToVault(names: [String: String] = [:], excluded: Set<String> = [], separate: Set<String> = [], dryRun: Bool) async throws -> JSONValue {
        let plan = try vaultMigrationPlan(names: names, excluded: excluded, separate: separate)
        var answer = plan.json.objectValue ?? [:]
        answer["dryRun"] = .bool(dryRun)
        guard !dryRun, !plan.newEntries.isEmpty || plan.items.contains(where: { !$0.excluded }) else { return .object(answer) }
        let added = try Self.addEntries(plan.newEntries, to: vault)
        do {
            let current = try readConfig()
            let applied = try await applyConfig(plan.config, dryRun: false, current: current, checkSchemas: false, expecting: current)
            answer["applied"] = applied
            logger.info("Moved config.json's secrets into the vault", metadata: ["secrets": "\(plan.items.filter { !$0.excluded }.count)", "entries": "\(added.count)"])
            return .object(answer)
        } catch {
            for name in added { _ = try? vault.remove(name) }
            throw error
        }
    }

    /// Adds `entries` to `vault`, none of which it has (the plan made the names unique); returns their names. When one
    /// cannot be written, those written are removed again.
    public static func addEntries(_ entries: [String: VaultEntry], to vault: CredentialVault) throws -> [String] {
        var added: [String] = []
        do {
            for name in entries.keys.sorted() {
                guard let entry = entries[name] else { continue }
                try vault.set(name, entry)
                added.append(name)
            }
        } catch {
            for name in added { _ = try? vault.remove(name) }
            throw error
        }
        return added
    }

    /// `config` with its new plain secrets moved into the vault: an entry that already holds a value takes it, a new
    /// value gets an entry of its own. A secret the file already has, sealed or plain, stays: the migration was told to
    /// leave it.
    func movingNewSecretsToVault(_ config: JSONValue) throws -> JSONValue {
        let current = (try? readConfig()) ?? [:]
        let kept = Set(try VaultMigration.plan(stored: current, opened: current, existing: [:], onlyPlain: true).items.map(\.id))
        let plan = try VaultMigration.plan(stored: config, opened: config, existing: vault.entries(), excluded: kept, onlyPlain: true)
        guard plan.items.contains(where: { !$0.excluded }) else { return config }
        _ = try Self.addEntries(plan.newEntries, to: vault)
        return plan.config
    }

    // MARK: Entries

    /// The vault as the Vault page shows it: each entry's name, kind, field names, dates, owner and the config values
    /// that name it (`usedBy`), never a value; and how many of config.json's secrets are still outside it.
    public func vaultJSON() throws -> JSONValue {
        let config = try readConfig()
        let users = VaultMigration.references(in: config)
        let entries = try vault.entries()
        let iso = { (date: Date?) in date.map { JSONValue.string(Timestamp.iso8601($0)) } ?? .null }
        let left = try vaultMigrationPlan().items.count
        return [
            "entries": .array(entries.keys.sorted().map { name in
                let entry = entries[name]!
                return [
                    "name": .string(name), "kind": .string(entry.kind.rawValue), "fields": .array(entry.fields.keys.sorted().map(JSONValue.string)),
                    "created": iso(entry.created), "changed": iso(entry.changed), "lastUsed": iso(entry.lastUsed), "expires": iso(entry.expires),
                    "owner": entry.owner.map(JSONValue.string) ?? .null, "usedBy": .array((users[name] ?? []).map(JSONValue.string)),
                ]
            }),
            // References to entries that are gone: the bridge does not start with them.
            "missing": .array(users.keys.filter { entries[$0] == nil }.sorted().map { name in ["name": .string(name), "usedBy": .array((users[name] ?? []).map(JSONValue.string))] }),
            "notMoved": .number(Double(left)),
            "migrated": .bool(VaultMigration.isMigrated(config)),
            "kinds": .array(VaultEntry.Kind.allCases.map { ["kind": .string($0.rawValue), "mainField": .string($0.mainField)] }),
        ]
    }

    /// Adds or changes the entry `name`: `fields` replace those of the same name (the others stay, unless the kind
    /// changes), `expires` replaces the date (nil clears it). A plugin's own entry keeps its owner. The running bridge
    /// applies config.json again, so the plugins that name the entry reload with its new value.
    public func setVaultEntry(_ name: String, kind: VaultEntry.Kind, fields: [String: String], expires: Date?) async throws -> JSONValue {
        guard CredentialVault.isValidName(name) else { throw CatalogError(CredentialVaultError.invalidName(name).description) }
        guard !fields.isEmpty, fields.values.allSatisfy({ !$0.isEmpty }), fields.keys.allSatisfy({ !$0.isEmpty && !$0.contains("#") }) else {
            throw CatalogError("an entry needs at least one field, each with a name and a value")
        }
        let existing = try vault.entry(named: name)
        var merged = existing?.kind == kind ? existing?.fields ?? [:] : [:]
        merged.merge(fields) { $1 }
        guard merged[kind.mainField] != nil || merged.count == 1 else { throw CatalogError("a \(kind.rawValue) needs its \(kind.mainField) field") }
        try vault.set(name, VaultEntry(kind: kind, fields: merged, created: existing?.created ?? Date(), changed: Date(), lastUsed: existing?.lastUsed, expires: expires, owner: existing?.owner))
        Redaction.rememberSecrets(fields.values)
        logger.info("Vault entry \(existing == nil ? "added" : "changed")", metadata: ["entry": "\(name)"])
        var answer: [String: JSONValue] = ["name": .string(name), "added": .bool(existing == nil)]
        if !(VaultMigration.references(in: try readConfig())[name] ?? []).isEmpty {
            answer["applied"] = try await reapplyConfig()
        }
        return .object(answer)
    }

    /// Removes the entry `name`. One that config.json names is refused unless `force`: the bridge would not start.
    public func removeVaultEntry(_ name: String, force: Bool = false) throws -> JSONValue {
        let users = VaultMigration.references(in: try readConfig())[name] ?? []
        guard force || users.isEmpty else {
            throw CatalogError("config.json names \(name) in \(users.joined(separator: ", ")): change those values first")
        }
        guard try vault.remove(name) else { throw CatalogError("No vault entry \(name)") }
        logger.info("Vault entry removed", metadata: ["entry": "\(name)"])
        return ["removed": .string(name)]
    }

    /// config.json applied again as it is, its references resolved anew: what a changed entry needs.
    func reapplyConfig() async throws -> JSONValue {
        let current = try readConfig()
        let configuration = try ConfigurationSecrets.opening(HomeswiftConfiguration.decode(current.encoded()), storage: storageDirectory)
        let report = await host.apply(configuration)
        // The Assistant's key: its service swaps, as after a save.
        let services = report.systemBlocksChanged.filter { $0 == AIConfiguration.platform }
        if let reloadServices, !services.isEmpty {
            // After this reply, as a save does: the server answering it may be one that reloads.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await reloadServices(configuration, services)
            }
        }
        return ["reloaded": .array(report.reloaded.map(JSONValue.string)), "restartNeeded": .array(report.needsRestart.map(JSONValue.string))]
    }

    // MARK: Tools

    var vaultTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "migrate_to_vault", title: "Move config.json's secrets into the vault",
                description: "Moves every secret of the plugin blocks (and the Assistant's key) into the vault: each becomes an entry, identical values "
                    + "share one, and config.json names it as vault:<entry>. dryRun answers the plan (each secret's id, platform, path and entry; "
                    + "never a value). names maps an id to the entry name to use, exclude lists ids to leave in config.json, separate lists ids "
                    + "that keep their own entry. A config backup is made first; restore_config undoes it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "names": ["type": "object", "additionalProperties": ["type": "string"]],
                        "exclude": ["type": "array", "items": ["type": "string"]],
                        "separate": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
                scope: .admin, destructive: true, supportsDryRun: true
            ) { call in
                let names = (call.arguments["names"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
                let excluded = Set((call.arguments["exclude"]?.arrayValue ?? []).compactMap(\.stringValue))
                let separate = Set((call.arguments["separate"]?.arrayValue ?? []).compactMap(\.stringValue))
                return .json(try await catalog.migrateToVault(names: names, excluded: excluded, separate: separate, dryRun: call.isDryRun))
            },
        ]
    }
}
