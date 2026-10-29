import Foundation
import HomeswiftAI

/// Moving config.json's secrets into the vault (docs/vault-design.md, "Migration"): every plain or sealed value under a
/// secret-named key of a platform block becomes an entry, and the block names it as `vault:<name>`. Identical values
/// share one entry, and a value an entry already holds goes to that entry. The plan names entries and paths, never
/// values, so it can be shown anywhere.
///
/// Left as they are: the web UI's block, the MCP server's tokens and a child bridge's `_bridge` (the runtime reads those
/// before references are resolved), and values that are already references.
public struct VaultMigration: Sendable {
    /// One secret found.
    public struct Item: Codable, Sendable, Equatable {
        /// `<platform>/<name>:<path>`: what `names` and `excluded` refer to.
        public var id: String
        public var platform: String
        public var name: String
        /// `password`, `devices[0].localKey`.
        public var path: String
        /// The entry it becomes.
        public var entry: String
        /// The entry existed before, or another item made it first.
        public var shared: Bool
        public var excluded: Bool
    }

    /// What a person chose in the plan, by item id: an entry's name, the items to leave, the items to keep apart.
    public struct Choices: Sendable {
        public var names: [String: String] = [:]
        public var excluded: Set<String> = []
        public var separate: Set<String> = []

        public init(names: [String: String] = [:], excluded: Set<String> = [], separate: Set<String> = []) {
            self.names = names
            self.excluded = excluded
            self.separate = separate
        }

        /// `{ "names": {id: entry}, "exclude": [id], "separate": [id] }`, as the page and the MCP tool send them.
        public init(json: JSONValue) {
            names = (json["names"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            excluded = Set((json["exclude"]?.arrayValue ?? []).compactMap(\.stringValue))
            separate = Set((json["separate"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
    }

    public var items: [Item]
    /// The entries to add, by name.
    public var newEntries: [String: VaultEntry]
    /// config.json with the references in place of the secrets of the items not excluded.
    public var config: JSONValue

    /// The items that move.
    public var moving: [Item] { items.filter { !$0.excluded } }

    public var json: JSONValue {
        [
            "items": (try? JSONValue(encoding: items)) ?? [],
            "newEntries": .array(newEntries.keys.sorted().map { name in ["name": .string(name), "kind": .string(newEntries[name]?.kind.rawValue ?? "")] }),
            "moved": .number(Double(moving.count)),
        ]
    }

    /// Blocks the migration never touches: the runtime reads them before it resolves references.
    static let skippedPlatforms: Set<String> = ["HomeswiftUI"]
    /// Keys whose subtree is left alone: a child bridge's identity, the MCP server's client tokens.
    static let skippedKeys: Set<String> = ["_bridge", "mcp"]

    /// The plan for `stored` (config.json as written) and `opened` (the same with its sealed secrets opened).
    /// `existing` are the vault's entries. With `onlyPlain`, a sealed value is left as it is: a save after the migration
    /// moves the new plain secrets, not those the migration left.
    public static func plan(
        stored: JSONValue, opened: JSONValue, existing: [String: VaultEntry], choices: Choices = Choices(), onlyPlain: Bool = false
    ) throws -> VaultMigration {
        guard var root = stored.objectValue, var platforms = root["platforms"]?.arrayValue else {
            return VaultMigration(items: [], newEntries: [:], config: stored)
        }
        var items: [Item] = []
        var newEntries: [String: VaultEntry] = [:]
        // The entry that already holds a value: a value two items share, or one the vault has.
        var byValue: [String: String] = [:]
        for (name, entry) in existing.sorted(by: { $0.key < $1.key }) {
            if let value = entry.value(field: nil), byValue[value] == nil { byValue[value] = name }
        }
        let openedPlatforms = opened["platforms"]?.arrayValue ?? []
        let counts = Dictionary(platforms.map { ($0["platform"]?.stringValue ?? "", 1) }, uniquingKeysWith: +)

        // Every secret first, so the names of merged entries can be made from all of their users.
        struct Found { var index: Int; var path: [SecretWalk.Part]; var value: String; var key: String; var suggested: String; var item: Item }
        var found: [Found] = []
        for (index, block) in platforms.enumerated() {
            let platform = block["platform"]?.stringValue ?? ""
            guard !skippedPlatforms.contains(platform), index < openedPlatforms.count else { continue }
            let name = block["name"]?.stringValue ?? platform
            let prefix = (counts[platform, default: 0] > 1 ? [platform, name] : [platform]).map(Slug.make)
            SecretWalk.forEach(block, skipping: skippedKeys) { path, key, secret in
                let value: String
                switch (secret, SecretWalk.value(at: path, in: openedPlatforms[index])) {
                case (.string(let text), .string(let plain)?):
                    guard !text.isEmpty, !Redaction.isConcealed(text), !(onlyPlain && SecretBox.isSealed(text)) else { return }
                    value = plain
                case (.number, _):
                    value = secret.text()
                default:
                    return
                }
                let id = "\(platform)/\(name):\(SecretWalk.text(path))"
                let suggested = (prefix + labels(of: path, in: block).map(Slug.make)).filter { !$0.isEmpty }.joined(separator: "-")
                found.append(Found(index: index, path: path, value: value, key: key, suggested: suggested,
                                   item: Item(id: id, platform: platform, name: name, path: SecretWalk.text(path), entry: "", shared: false, excluded: choices.excluded.contains(id))))
            }
        }

        // Values that several items share, for the merged entries' names.
        var sharers: [String: [String]] = [:]
        for item in found where !item.item.excluded && !choices.separate.contains(item.item.id) { sharers[item.value, default: []].append(item.suggested) }
        let isTaken = { (name: String) in existing[name] != nil || newEntries[name] != nil }

        for var current in found {
            defer { items.append(current.item) }
            guard !current.item.excluded else { continue }
            let mergeable = !choices.separate.contains(current.item.id)
            if let chosen = choices.names[current.item.id] {
                guard CredentialVault.isValidName(chosen) else { throw CredentialVaultError.invalidName(chosen) }
                current.item.entry = chosen
                if let entry = existing[chosen] ?? newEntries[chosen] {
                    // An entry chosen by name: it takes this value only when it holds the same one.
                    guard entry.value(field: nil) == current.value else { throw VaultMigrationError.nameTaken(chosen) }
                    current.item.shared = true
                } else {
                    newEntries[chosen] = entry(for: current.key, value: current.value)
                    if mergeable, byValue[current.value] == nil { byValue[current.value] = chosen }
                }
            } else if mergeable, let entry = byValue[current.value] {
                current.item.entry = entry
                current.item.shared = true
            } else {
                let group = sharers[current.value] ?? []
                let base = mergeable && group.count > 1 ? sharedName(group) : current.suggested
                let name = unique(base.isEmpty ? "secret" : base, isTaken: isTaken)
                newEntries[name] = entry(for: current.key, value: current.value)
                current.item.entry = name
                if mergeable { byValue[current.value] = name }
            }
            platforms[current.index] = SecretWalk.replacing(platforms[current.index], at: current.path, with: .string("vault:\(current.item.entry)"))
        }
        root["platforms"] = .array(platforms)
        return VaultMigration(items: items, newEntries: newEntries, config: .object(root))
    }

    /// Whether config.json names an entry of the vault: from then on, a plain secret a save brings goes to the vault too.
    public static func isMigrated(_ config: JSONValue) -> Bool {
        !references(in: config).isEmpty
    }

    /// Who names each entry in config.json: entry name to the ids (`<platform>/<name>:<path>`) of the values that are
    /// `vault:<entry>` references, under secret-named keys of the platform blocks.
    public static func references(in config: JSONValue) -> [String: [String]] {
        var users: [String: [String]] = [:]
        for block in config["platforms"]?.arrayValue ?? [] {
            let platform = block["platform"]?.stringValue ?? ""
            let name = block["name"]?.stringValue ?? platform
            SecretWalk.forEach(block) { path, _, value in
                guard let text = value.stringValue, case .vault(let entry, _) = SecretReference(text) else { return }
                users[entry, default: []].append("\(platform)/\(name):\(SecretWalk.text(path))")
            }
        }
        return users
    }

    // MARK: Names and kinds

    /// What a secret's suggested name is made of: each key of its path, and for a list item its `name`, `label` or `id`,
    /// else its position from 1.
    static func labels(of path: [SecretWalk.Part], in block: JSONValue) -> [String] {
        path.indices.map { index in
            switch path[index] {
            case .key(let key): key
            case .index(let position):
                SecretWalk.value(at: Array(path[...index]), in: block).flatMap { item in
                    ["name", "label", "id"].lazy.compactMap { item[$0]?.stringValue }.first
                } ?? "\(position + 1)"
            }
        }
    }

    static func entry(for key: String, value: String) -> VaultEntry {
        let lowered = key.lowercased()
        let kind: VaultEntry.Kind = lowered.range(of: #"api[-_]?key"#, options: .regularExpression) != nil ? .apiKey : lowered.contains("token") ? .token : .secret
        return VaultEntry(kind: kind, fields: [kind.mainField: value])
    }

    /// The name of an entry several items share: the parts their names begin with, and the last part when they all end
    /// with it (`unifi-protect-password` and `unifi-access-password` share `unifi-password`).
    static func sharedName(_ names: [String]) -> String {
        let parts = names.map { $0.split(separator: "-").map(String.init) }
        guard let first = parts.first else { return "secret" }
        var common = first
        for other in parts.dropFirst() {
            common = Array(zip(common, other).prefix { $0 == $1 }.map(\.0))
        }
        let last = first.last.flatMap { last in parts.allSatisfy { $0.last == last } ? last : nil }
        if common.isEmpty || (common.count == 1 && common.first == last) {
            // `unifiprotect` and `unifiaccess` share no part, but begin alike: `unifi`, when three letters or more.
            let starts = parts.compactMap(\.first)
            let shared = starts.dropFirst().reduce(starts.first ?? "") { prefix, other in String(zip(prefix, other).prefix { $0 == $1 }.map(\.0)) }
            if shared.count >= 3 { common = [shared] }
        }
        if let last, common.last != last { common.append(last) }
        let name = common.joined(separator: "-")
        return name.isEmpty ? first.joined(separator: "-") : name
    }

    /// `base`, else `base-2`, `base-3`… the first that is not taken.
    static func unique(_ base: String, isTaken: (String) -> Bool) -> String {
        let trimmed = String(base.prefix(CredentialVault.maximumNameLength - 4))
        guard isTaken(trimmed) else { return trimmed }
        var suffix = 2
        while isTaken("\(trimmed)-\(suffix)") { suffix += 1 }
        return "\(trimmed)-\(suffix)"
    }
}

public enum VaultMigrationError: Error, CustomStringConvertible, Equatable, Sendable {
    case nameTaken(String)

    public var description: String {
        switch self {
        case .nameTaken(let name): "the vault already has an entry \(name) with another value: choose another name"
        }
    }
}
