import Foundation
import HomeswiftAI
import HomeswiftPlugin

// The vault's migration (docs/vault-design.md, "Migration"): the Vault page, `homeswift vault migrate` and the
// `migrate_to_vault` tool share it.
extension HomeswiftCatalog {
    public var vault: CredentialVault { CredentialVault(storage: storageDirectory) }

    /// What moving config.json's secrets into the vault would do, as it is now (`VaultMigration.plan`). Nothing is
    /// written.
    public func vaultMigrationPlan(_ choices: VaultMigration.Choices = .init()) throws -> VaultMigration {
        try Self.vaultMigrationPlan(configURL: configURL, choices)
    }

    public static func vaultMigrationPlan(configURL: URL, _ choices: VaultMigration.Choices = .init()) throws -> VaultMigration {
        let storage = configURL.deletingLastPathComponent()
        let stored = try JSONValue(data: Data(contentsOf: configURL))
        return try VaultMigration.plan(
            stored: stored, opened: SecretBox.revealed(stored, storage: storage), existing: CredentialVault(storage: storage).entries(), choices: choices)
    }

    /// Moves config.json's secrets into the vault: adds the plan's entries, then saves and applies the config with the
    /// references (a backup of the file first, as every save). The entries it added go again when the save fails.
    /// `dryRun` answers the plan only.
    public func migrateToVault(_ choices: VaultMigration.Choices = .init(), dryRun: Bool) async throws -> JSONValue {
        let plan = try vaultMigrationPlan(choices)
        var answer = plan.json.objectValue ?? [:]
        answer["dryRun"] = .bool(dryRun)
        guard !dryRun, !plan.moving.isEmpty else { return .object(answer) }
        let current = try readConfig()
        answer["applied"] = try await vault.adding(plan.newEntries) {
            try await applyConfig(plan.config, dryRun: false, current: current, checkSchemas: false, expecting: current)
        }
        logger.info("Moved config.json's secrets into the vault", metadata: ["secrets": "\(plan.moving.count)", "entries": "\(plan.newEntries.count)"])
        return .object(answer)
    }

    /// The command line's migration, with no bridge to apply it to: the plan's entries, then config.json with the
    /// references, written only when it opens and validates (a backup first, as every save). Answers the backup's name.
    public static func writeMigration(_ plan: VaultMigration, configURL: URL) throws -> String {
        let storage = configURL.deletingLastPathComponent()
        return try CredentialVault(storage: storage).adding(plan.newEntries) {
            try ConfigurationSecrets.opening(HomeswiftConfiguration.decode(plan.config.encoded()), storage: storage).validate()
            return try writeConfigFile(plan.config, to: configURL)
        }
    }

    /// `config` with its new plain secrets moved into the vault: an entry that already holds a value takes it, a new
    /// value gets an entry of its own. A secret the file already has, sealed or plain, stays: the migration was told to
    /// leave it.
    func movingNewSecretsToVault(_ config: JSONValue) throws -> JSONValue {
        // Without the vault first: most saves bring no new secret, and then neither the file nor the vault is read.
        guard !(try VaultMigration.plan(stored: config, opened: config, existing: [:], onlyPlain: true)).moving.isEmpty else { return config }
        let current = (try? readConfig()) ?? [:]
        let kept = Set(try VaultMigration.plan(stored: current, opened: current, existing: [:], onlyPlain: true).items.map(\.id))
        let plan = try VaultMigration.plan(stored: config, opened: config, existing: vault.entries(), choices: .init(excluded: kept), onlyPlain: true)
        guard !plan.moving.isEmpty else { return config }
        try vault.set(plan.newEntries)
        return plan.config
    }

    // MARK: Entries

    /// The vault as the Vault page shows it: each entry's name, kind, field names, dates, owner and the config values
    /// that name it (`usedBy`), never a value; the references to entries that are gone; the kinds and the name rule.
    public func vaultJSON() throws -> JSONValue {
        let users = VaultMigration.references(in: try readConfig())
        let entries = try vault.listing()
        let iso = { (date: Date?) in date.map { JSONValue.string(Timestamp.iso8601($0)) } ?? .null }
        return [
            "entries": .array(entries.sorted { $0.key < $1.key }.map { name, entry in
                [
                    "name": .string(name), "kind": .string(entry.kind.rawValue), "fields": .array(entry.fields.keys.sorted().map(JSONValue.string)),
                    "created": iso(entry.created), "changed": iso(entry.changed), "expires": iso(entry.expires),
                    "owner": entry.owner.map(JSONValue.string) ?? .null, "usedBy": .array((users[name] ?? []).map(JSONValue.string)),
                ]
            }),
            // References to entries that are gone: the bridge does not start with them.
            "missing": .array(users.keys.filter { entries[$0] == nil }.sorted().map { name in ["name": .string(name), "usedBy": .array((users[name] ?? []).map(JSONValue.string))] }),
            "kinds": .array(VaultEntry.Kind.allCases.map { ["kind": .string($0.rawValue), "mainField": .string($0.mainField)] }),
            "namePattern": .string(Redaction.vaultNamePattern),
        ]
    }

    /// Adds or changes the entry `name` (`CredentialVault.update`), `expires` replacing its date. The running bridge
    /// applies config.json again when it names the entry, so its plugins reload with the new value.
    public func setVaultEntry(_ name: String, kind: VaultEntry.Kind, fields: [String: String], expires: Date?) async throws -> JSONValue {
        guard CredentialVault.isValidName(name) else { throw CatalogError(CredentialVaultError.invalidName(name).description) }
        let added: Bool
        do {
            added = try vault.update(name, kind: kind, fields: fields, expires: .some(expires))
        } catch let error as CredentialVaultError {
            throw CatalogError(error.description)
        }
        logger.info("Vault entry \(added ? "added" : "changed")", metadata: ["entry": "\(name)"])
        var answer: [String: JSONValue] = ["name": .string(name), "added": .bool(added)]
        let current = try readConfig()
        if !(VaultMigration.references(in: current)[name] ?? []).isEmpty {
            answer["applied"] = await run(try ConfigurationSecrets.opening(HomeswiftConfiguration.decode(current.encoded()), storage: storageDirectory))
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
                .json(try await catalog.migrateToVault(VaultMigration.Choices(json: call.arguments), dryRun: call.isDryRun))
            },
        ]
    }
}
