import Foundation
import HomeswiftAI

/// What needs attention in the vault (docs/vault-design.md, "Health"), for the Vault page, the Status page, the daily
/// digest and `list_vault`: references config.json makes that do not resolve, and entries past or near their expiry.
/// It reads the vault's listing, never a value.
public struct VaultHealth: Sendable, Equatable {
    /// Most pressing first.
    public enum State: String, Sendable, Codable, CaseIterable, Comparable {
        /// config.json names an entry the vault does not have: the bridge does not start.
        case missing
        /// The entry is there, but a reference cannot read it: a field it does not have, or a plugin's own entry named
        /// from another block.
        case failing
        case expired
        /// It expires within `soon`.
        case expiring

        public static func < (lhs: State, rhs: State) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public struct Problem: Sendable, Equatable {
        public var entry: String
        public var state: State
        /// The config values concerned, `<platform>/<name>:<path>`: those that fail, else all that name the entry.
        public var usedBy: [String]
        public var expires: Date?
        /// Why, in English, for the log and the digest; nil for an expiry.
        public var reason: String?

        public var json: JSONValue {
            [
                "entry": .string(entry), "state": .string(state.rawValue), "usedBy": .array(usedBy.map(JSONValue.string)),
                "expires": expires.map { .string(Timestamp.iso8601($0)) } ?? .null, "reason": reason.map(JSONValue.string) ?? .null,
            ]
        }
    }

    /// How far ahead an expiry is reported, as the Vault page warns.
    public static let soon: TimeInterval = 30 * 86_400

    /// Most pressing first, then by entry.
    public var problems: [Problem]

    public init(problems: [Problem] = []) {
        self.problems = problems
    }

    /// The worst state of each entry that has a problem.
    public var states: [String: State] {
        Dictionary(problems.map { ($0.entry, $0.state) }, uniquingKeysWith: min)
    }

    public var json: JSONValue { .array(problems.map(\.json)) }

    /// `config` is config.json as written, `entries` the vault's listing (`CredentialVault.listing`: fields' names are
    /// enough).
    public static func check(config: JSONValue, entries: [String: VaultEntry], now: Date = Date(), soon: TimeInterval = soon) -> VaultHealth {
        let uses = VaultMigration.uses(in: config)
        var problems: [Problem] = []
        for (name, group) in Dictionary(grouping: uses, by: \.entry) {
            guard let entry = entries[name] else {
                problems.append(Problem(entry: name, state: .missing, usedBy: group.map(\.id), reason: "no such entry in the vault"))
                continue
            }
            var failing: [String] = []
            var reasons: Set<String> = []
            for use in group {
                if let owner = entry.owner, owner != use.block {
                    failing.append(use.id)
                    reasons.insert("the entry belongs to \(owner)")
                } else if entry.value(field: use.field) == nil {
                    failing.append(use.id)
                    reasons.insert(use.field.map { "the entry has no field \($0)" } ?? "the entry has no \(entry.kind.mainField) field")
                }
            }
            if !failing.isEmpty {
                problems.append(Problem(entry: name, state: .failing, usedBy: failing, reason: reasons.sorted().joined(separator: "; ")))
            }
        }
        let users = Dictionary(grouping: uses, by: \.entry).mapValues { $0.map(\.id) }
        for (name, entry) in entries {
            guard let expires = entry.expires, expires < now.addingTimeInterval(soon) else { continue }
            problems.append(Problem(entry: name, state: expires <= now ? .expired : .expiring, usedBy: users[name] ?? [], expires: expires))
        }
        problems.sort { ($0.state, $0.entry) < ($1.state, $1.entry) }
        return VaultHealth(problems: problems)
    }
}
