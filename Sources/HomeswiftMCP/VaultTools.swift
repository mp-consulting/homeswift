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
