import Foundation
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
        config.json names an entry as vault:<name>, or vault:<name>#<field> for another field than the main one.
        A running bridge reads the vault when it starts and when its config is saved.
        """

    static func run(arguments: [String], storagePath: URL) throws {
        let vault = CredentialVault(storage: storagePath)
        switch arguments.first {
        case "list" where arguments.count == 1:
            let entries = try vault.entries()
            for name in entries.keys.sorted() {
                guard let entry = entries[name] else { continue }
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
            let existing = try vault.entry(named: name)
            let resolvedKind = kind ?? existing?.kind ?? (username != nil ? .login : .secret)
            var fields = existing?.kind == resolvedKind ? existing?.fields ?? [:] : [:]
            fields[field ?? resolvedKind.mainField] = try readValue()
            if let username { fields["username"] = username }
            var entry = VaultEntry(kind: resolvedKind, fields: fields, created: existing?.created ?? Date(), changed: Date())
            entry.expires = existing?.expires
            try vault.set(name, entry)
            say("\(existing == nil ? "Added" : "Changed") \(name); config.json names it as vault:\(name).")
        case "remove" where arguments.count == 2:
            guard try vault.remove(arguments[1]) else { throw CommandError("no entry \(arguments[1]); homeswift vault list shows them") }
            say("Removed \(arguments[1]); a config that names it no longer starts until it is set again.")
        default:
            throw CommandError(usage)
        }
    }

    /// The first line of standard input; a terminal gets a prompt without echo.
    static func readValue() throws -> String {
        if isatty(STDIN_FILENO) != 0 {
            guard let typed = getpass("Value: ") else { throw CommandError("no value") }
            let value = String(cString: typed)
            guard !value.isEmpty else { throw CommandError("no value") }
            return value
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw CommandError("no value on standard input")
        }
        return line
    }
}
