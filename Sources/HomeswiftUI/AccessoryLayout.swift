import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The Accessories page's wall, for every user of the bridge: the accessories' order, the size each one was given,
/// the size of each kind of widget by default, and whether the page groups them by plugin (one wall by default).
/// In `ui-layout.json` next to config.json; what the page sends is checked and trimmed to that before it is kept.
///
///     { "order": ["Govee:…", …], "sizes": { "Govee:…": "small" }, "defaults": { "climate": "large" }, "grouping": "none" }
final class AccessoryLayout: Sendable {
    static let sizes: Set<String> = ["small", "medium", "large", "xlarge"]
    static let groupings: Set<String> = ["plugin", "room", "none"]
    /// Far more than a bridge has: what keeps a page from filling the disk.
    static let maximumAccessories = 5000

    let url: URL
    private let lock = NIOLock()

    init(url: URL) { self.url = url }

    /// The layout kept, or an empty one.
    func load() -> JSONValue {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), let stored = try? JSONValue(data: data), let layout = try? Self.checked(stored) else { return Self.empty }
            return layout
        }
    }

    /// Keeps `body` once checked; answers what was kept.
    func save(_ body: JSONValue) throws -> JSONValue {
        let layout = try Self.checked(body)
        try lock.withLock { try OwnerOnlyFile.write(Data(layout.text(pretty: true).utf8), to: url) }
        return layout
    }

    static let empty: JSONValue = ["order": [], "sizes": [:], "defaults": [:], "grouping": "none"]

    struct Invalid: Error, CustomStringConvertible { let description: String }

    /// The layout in `body` with nothing else: accessory ids as strings of a sane length, one of the four sizes, kinds
    /// as short lower-case names. Each part may be left out (it is then empty).
    static func checked(_ body: JSONValue) throws -> JSONValue {
        guard let object = body.objectValue else { throw Invalid(description: "the layout must be a JSON object") }
        let isID = { (id: String) in !id.isEmpty && id.utf8.count <= 512 }
        var order: [JSONValue] = [], seen = Set<String>()
        for entry in object["order"]?.arrayValue ?? [] {
            guard let id = entry.stringValue, isID(id) else { throw Invalid(description: "order lists accessory ids") }
            if seen.insert(id).inserted { order.append(.string(id)) }
        }
        let sizes = try (object["sizes"]?.objectValue ?? [:]).mapValues { value -> JSONValue in
            guard let size = value.stringValue, Self.sizes.contains(size) else { throw Invalid(description: "a size is small, medium, large or xlarge") }
            return .string(size)
        }
        guard sizes.keys.allSatisfy(isID) else { throw Invalid(description: "sizes are by accessory id") }
        let defaults = try (object["defaults"]?.objectValue ?? [:]).mapValues { value -> JSONValue in
            guard let size = value.stringValue, Self.sizes.contains(size) else { throw Invalid(description: "a size is small, medium, large or xlarge") }
            return .string(size)
        }
        guard defaults.keys.allSatisfy({ !$0.isEmpty && $0.count <= 40 && $0.allSatisfy { $0.isLowercase || $0 == "-" } }) else {
            throw Invalid(description: "defaults are by kind of widget (climate, light…)")
        }
        guard order.count <= maximumAccessories, sizes.count <= maximumAccessories else { throw Invalid(description: "too many accessories") }
        let grouping = object["grouping"]?.stringValue ?? "none"
        guard groupings.contains(grouping) else { throw Invalid(description: "grouping is plugin, room or none") }
        var groups: [JSONValue] = [], groupIDs = Set<String>(), members = Set<String>()
        if let value = object["groups"], value.arrayValue == nil { throw Invalid(description: "groups must be an array") }
        for group in object["groups"]?.arrayValue ?? [] {
            guard let id = group["id"]?.stringValue, id.hasPrefix("group:"), isID(id), groupIDs.insert(id).inserted,
                  let name = group["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
                  let ids = group["members"]?.arrayValue, ids.count >= 2, ids.count <= 100 else { throw Invalid(description: "invalid accessory group") }
            var checkedMembers: [JSONValue] = []
            for value in ids {
                guard let member = value.stringValue, isID(member), !member.hasPrefix("group:"), members.insert(member).inserted else { throw Invalid(description: "an accessory belongs to only one group") }
                checkedMembers.append(.string(member))
            }
            groups.append(["id": .string(id), "name": .string(name), "members": .array(checkedMembers)])
        }
        guard groups.count <= 100 else { throw Invalid(description: "too many groups") }
        var result: [String: JSONValue] = ["order": .array(order), "sizes": .object(sizes), "defaults": .object(defaults), "grouping": .string(grouping)]
        if object["groups"] != nil { result["groups"] = .array(groups) }
        return .object(result)
    }
}
