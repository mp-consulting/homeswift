import Foundation
import HomeswiftMCP
import HomeswiftPlugin

/// `homeswift vault`: the local vault's entries (`vault.json`, docs/vault-design.md), from a shell. Values are read from
/// standard input, never from the arguments, which other users of the machine can see, and never printed.
enum VaultCommands {
    static let usage = """
        usage: homeswift vault list
               homeswift vault set <name> [--kind login|apiKey|token|secret] [--username <username>] [--field <field>]
                                                     the value on standard input; a login's password unless --field
                                                     names another field; a new entry is a secret unless --kind says
               homeswift vault remove <name>
               homeswift vault migrate [--dry-run] [--exclude <id>]… [--separate <id>]… [--name <id>=<entry>]…
                                                     moves config.json's secrets into the vault (a backup first);
                                                     --dry-run lists each secret's id and the entry it would become
        config.json names an entry as vault:<name>, or vault:<name>#<field> for another field than the main one.
        A running bridge reads the vault when it starts and when its config is saved: restart it after a migrate.
        """

    static func run(arguments: [String], storagePath: URL) throws {
        let vault = CredentialVault(storage: storagePath)
        switch arguments.first {
        case "list" where arguments.count == 1:
            for (name, entry) in try vault.listing().sorted(by: { $0.key < $1.key }) {
                let fields = entry.fields.keys.sorted().joined(separator: ", ")
                say("\(name)  \(entry.kind.rawValue)  \(fields)" + (entry.owner.map { "  (\($0))" } ?? ""))
            }
        case "set" where arguments.count >= 2:
            let name = arguments[1]
            var kind: VaultEntry.Kind?
            var username: String?
            var field: String?
            var options = arguments.dropFirst(2).makeIterator()
            while let option = options.next() {
                switch option {
                case "--kind":
                    guard let value = options.next(), let parsed = VaultEntry.Kind(rawValue: value) else { throw CommandError(usage) }
                    kind = parsed
                case "--username":
                    guard let value = options.next() else { throw CommandError(usage) }
                    username = value
                case "--field":
                    guard let value = options.next(), !value.isEmpty else { throw CommandError(usage) }
                    field = value
                default:
                    throw CommandError(usage)
                }
            }
            guard CredentialVault.isValidName(name) else { throw CredentialVaultError.invalidName(name) }
            let resolvedKind = try kind ?? vault.listing()[name]?.kind ?? (username != nil ? .login : .secret)
            var fields = [field ?? resolvedKind.mainField: try readSecret(prompt: "Value: ", what: "value")]
            if let username { fields["username"] = username }
            let added = try vault.update(name, kind: resolvedKind, fields: fields)
            say("\(added ? "Added" : "Changed") \(name); config.json names it as vault:\(name).")
        case "migrate":
            try migrate(arguments: Array(arguments.dropFirst()), storagePath: storagePath)
        case "remove" where arguments.count == 2:
            guard try vault.remove(arguments[1]) else { throw CommandError("no entry \(arguments[1]); homeswift vault list shows them") }
            say("Removed \(arguments[1]); a config that names it no longer starts until it is set again.")
        default:
            throw CommandError(usage)
        }
    }

    /// `homeswift vault migrate`: the plan, then (without `--dry-run`) the entries, then config.json with the references,
    /// checked to resolve before it is written.
    static func migrate(arguments: [String], storagePath: URL) throws {
        var dryRun = false
        var choices = VaultMigration.Choices()
        var options = arguments.makeIterator()
        while let option = options.next() {
            switch option {
            case "--dry-run": dryRun = true
            case "--exclude":
                guard let id = options.next() else { throw CommandError(usage) }
                choices.excluded.insert(id)
            case "--separate":
                guard let id = options.next() else { throw CommandError(usage) }
                choices.separate.insert(id)
            case "--name":
                // The id holds `:` and `/`, an entry name neither: the last `=` splits them.
                guard let pair = options.next(), let equals = pair.lastIndex(of: "=") else { throw CommandError(usage) }
                choices.names[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            default:
                throw CommandError(usage)
            }
        }
        let configURL = storagePath.appendingPathComponent("config.json")
        let plan = try HomeswiftCatalog.vaultMigrationPlan(configURL: configURL, choices)
        for item in plan.items {
            let what = item.excluded ? "left in config.json" : "vault:\(item.entry)" + (item.shared ? " (shared)" : "")
            say("\(item.id)  →  \(what)")
        }
        guard !plan.moving.isEmpty else { return say("No secret to move.") }
        if dryRun { return say("\(plan.moving.count) secrets into \(plan.newEntries.count) new entries; nothing written (--dry-run).") }
        let backup = try HomeswiftCatalog.writeMigration(plan, configURL: configURL)
        say("Moved \(plan.moving.count) secrets into \(plan.newEntries.count) new entries; config.json was backed up as backups/\(backup). Restart the bridge.")
    }
}
