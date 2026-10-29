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
    public struct Item: Sendable, Equatable {
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

        public var json: JSONValue {
            ["id": .string(id), "platform": .string(platform), "name": .string(name), "path": .string(path), "entry": .string(entry), "shared": .bool(shared), "excluded": .bool(excluded)]
        }
    }

    public var items: [Item]
    /// The entries to add, by name.
    public var newEntries: [String: VaultEntry]
    /// config.json with the references in place of the secrets of the items not excluded.
    public var config: JSONValue

    public var json: JSONValue {
        [
            "items": .array(items.map(\.json)),
            "newEntries": .array(newEntries.keys.sorted().map { name in ["name": .string(name), "kind": .string(newEntries[name]?.kind.rawValue ?? "")] }),
            "moved": .number(Double(items.filter { !$0.excluded }.count)),
        ]
    }

    /// Blocks the migration never touches: the runtime reads them before it resolves references.
    static let skippedPlatforms: Set<String> = ["HomeswiftUI"]
    /// Keys whose subtree is left alone: a child bridge's identity, the MCP server's client tokens.
    static let skippedKeys: Set<String> = ["_bridge", "mcp"]

    /// The plan for `stored` (config.json as written) and `opened` (the same with its sealed secrets opened).
    /// `existing` are the vault's entries, `names` the entry chosen for an item id, `excluded` the item ids to leave,
    /// `separate` the item ids that get their own entry even when another holds the same value. With `onlyPlain`, a sealed
    /// value is left as it is: a save after the migration moves the new plain secrets, not those the migration left.
    public static func plan(
        stored: JSONValue, opened: JSONValue, existing: [String: VaultEntry], names: [String: String] = [:],
        excluded: Set<String> = [], separate: Set<String> = [], onlyPlain: Bool = false
    ) throws -> VaultMigration {
        var items: [Item] = []
        var newEntries: [String: VaultEntry] = [:]
        // The entry that already holds a value: a value two items share, or one the vault has.
        var byValue: [String: String] = [:]
        for (name, entry) in existing.sorted(by: { $0.key < $1.key }) {
            if let value = entry.value(field: nil), byValue[value] == nil { byValue[value] = name }
        }
        var taken = Set(existing.keys)
        var config = stored
        guard var root = stored.objectValue, var platforms = root["platforms"]?.arrayValue else {
            return VaultMigration(items: [], newEntries: [:], config: stored)
        }
        let openedPlatforms = opened["platforms"]?.arrayValue ?? []
        let counts = Dictionary(platforms.map { ($0["platform"]?.stringValue ?? "", 1) }, uniquingKeysWith: +)

        // Every secret first, so the names of merged entries can be made from all of their users.
        struct Found { var index: Int; var path: [PathPart]; var value: String; var key: String; var suggested: String; var item: Item }
        var found: [Found] = []
        for (index, block) in platforms.enumerated() {
            let platform = block["platform"]?.stringValue ?? ""
            guard !skippedPlatforms.contains(platform), index < openedPlatforms.count else { continue }
            let name = block["name"]?.stringValue ?? platform
            let prefix = counts[platform, default: 0] > 1 ? [slug(platform), slug(name)] : [slug(platform)]
            secrets(in: block, opened: openedPlatforms[index], path: [], onlyPlain: onlyPlain) { path, key, value, labels in
                let id = "\(platform)/\(name):\(pathText(path))"
                let suggested = ([prefix.joined(separator: "-")] + labels.map(slug)).filter { !$0.isEmpty }.joined(separator: "-")
                found.append(Found(index: index, path: path, value: value, key: key, suggested: suggested,
                                   item: Item(id: id, platform: platform, name: name, path: pathText(path), entry: "", shared: false, excluded: excluded.contains(id))))
            }
        }

        // Values that several items share, for the merged entries' names.
        var sharers: [String: [String]] = [:]
        for item in found where !item.item.excluded && !separate.contains(item.item.id) { sharers[item.value, default: []].append(item.suggested) }

        for var current in found {
            defer { items.append(current.item) }
            guard !current.item.excluded else { continue }
            let mergeable = !separate.contains(current.item.id)
            if let chosen = names[current.item.id] {
                guard CredentialVault.isValidName(chosen) else { throw CredentialVaultError.invalidName(chosen) }
                current.item.entry = chosen
                if let entry = existing[chosen] ?? newEntries[chosen] {
                    // An entry chosen by name: it takes this value only when it holds the same one.
                    guard entry.value(field: nil) == current.value else { throw VaultMigrationError.nameTaken(chosen) }
                    current.item.shared = true
                } else {
                    newEntries[chosen] = entry(for: current.key, value: current.value)
                    taken.insert(chosen)
                    if mergeable, byValue[current.value] == nil { byValue[current.value] = chosen }
                }
            } else if mergeable, let entry = byValue[current.value] {
                current.item.entry = entry
                current.item.shared = true
            } else {
                let group = sharers[current.value] ?? []
                let base = mergeable && group.count > 1 ? sharedName(group) : current.suggested
                let name = unique(base.isEmpty ? "secret" : base, taken: taken)
                taken.insert(name)
                newEntries[name] = entry(for: current.key, value: current.value)
                current.item.entry = name
                if mergeable { byValue[current.value] = name }
            }
            platforms[current.index] = replacing(platforms[current.index], at: current.path, with: .string("vault:\(current.item.entry)"))
        }
        root["platforms"] = .array(platforms)
        config = .object(root)
        return VaultMigration(items: items, newEntries: newEntries, config: config)
    }

    /// Whether config.json names an entry of the vault: from then on, a plain secret a save brings goes to the vault too.
    public static func isMigrated(_ config: JSONValue) -> Bool {
        switch config {
        case .string(let text): text.hasPrefix("vault:") && Redaction.isSecretReference(text)
        case .array(let items): items.contains(where: isMigrated)
        case .object(let object): object.values.contains(where: isMigrated)
        default: false
        }
    }

    // MARK: Walking

    enum PathPart: Equatable {
        case key(String)
        case index(Int)
    }

    static func pathText(_ path: [PathPart]) -> String {
        path.reduce(into: "") { text, part in
            switch part {
            case .key(let key): text += text.isEmpty ? key : ".\(key)"
            case .index(let index): text += "[\(index)]"
            }
        }
    }

    /// Calls `found` with each secret's path, key, opened value and the labels its name is made of (each key, and for a
    /// list item its `name`, `label` or `id`, else its position from 1).
    static func secrets(in value: JSONValue, opened: JSONValue, path: [PathPart], labels: [String] = [], underSecret: Bool = false, key: String = "",
                        onlyPlain: Bool = false, found: (_ path: [PathPart], _ key: String, _ value: String, _ labels: [String]) -> Void) {
        switch (value, opened) {
        case (.string(let text), .string(let plain)) where underSecret && !text.isEmpty && !Redaction.isConcealed(text) && !(onlyPlain && SecretBox.isSealed(text)):
            found(path, key, plain, labels)
        case (.number, _) where underSecret:
            found(path, key, value.text(), labels)
        case (.array(let items), .array(let openedItems)):
            for (index, item) in items.enumerated() where index < openedItems.count {
                let label = ["name", "label", "id"].lazy.compactMap { item[$0]?.stringValue }.first ?? "\(index + 1)"
                secrets(in: item, opened: openedItems[index], path: path + [.index(index)], labels: labels + [label], underSecret: underSecret, key: key,
                        onlyPlain: onlyPlain, found: found)
            }
        case (.object(let object), .object(let openedObject)):
            for (entryKey, item) in object.sorted(by: { $0.key < $1.key }) where !skippedKeys.contains(entryKey) {
                guard let openedItem = openedObject[entryKey] else { continue }
                let secret = underSecret || Redaction.isSecretKey(entryKey)
                secrets(in: item, opened: openedItem, path: path + [.key(entryKey)], labels: labels + [entryKey], underSecret: secret,
                        key: secret && !underSecret ? entryKey : key, onlyPlain: onlyPlain, found: found)
            }
        default:
            break
        }
    }

    static func replacing(_ value: JSONValue, at path: [PathPart], with new: JSONValue) -> JSONValue {
        guard let first = path.first else { return new }
        let rest = Array(path.dropFirst())
        switch (first, value) {
        case (.key(let key), .object(var object)):
            object[key] = replacing(object[key] ?? .null, at: rest, with: new)
            return .object(object)
        case (.index(let index), .array(var items)) where index < items.count:
            items[index] = replacing(items[index], at: rest, with: new)
            return .array(items)
        default:
            return value
        }
    }

    // MARK: Names and kinds

    static func entry(for key: String, value: String) -> VaultEntry {
        let lowered = key.lowercased()
        let kind: VaultEntry.Kind = lowered.range(of: #"api[-_]?key"#, options: .regularExpression) != nil ? .apiKey : lowered.contains("token") ? .token : .secret
        return VaultEntry(kind: kind, fields: [kind.mainField: value])
    }

    /// Lowercase letters, digits and `-`.
    static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
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

    static func unique(_ base: String, taken: Set<String>) -> String {
        let trimmed = String(base.prefix(CredentialVault.maximumNameLength - 4))
        guard taken.contains(trimmed) else { return trimmed }
        var suffix = 2
        while taken.contains("\(trimmed)-\(suffix)") { suffix += 1 }
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
