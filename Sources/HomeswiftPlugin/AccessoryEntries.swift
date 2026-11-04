import Foundation
import HomeswiftAI

/// A block's `_accessories` as a plugin's `canonicalSettings` moves its Homebridge shapes into them (docs/plugins.md,
/// "Settings"): what an entry has already wins, a list's values that name no device stay in the list, and the block
/// gets `_accessories` back only when there are some.
///
/// ```swift
/// var fields = block.objectValue ?? [:]
/// var entries = AccessoryEntries(fields)
/// entries.excludeList("excludeLights", in: &fields) { name in lights.filter { $0.name == name }.map(\.id) }
/// entries.write(into: &fields)
/// ```
public struct AccessoryEntries: Sendable, Equatable {
    /// The entries by Device Id.
    public var entries: [String: JSONValue]

    /// The block's `_accessories`.
    public init(_ fields: [String: JSONValue]) {
        entries = fields["_accessories"]?.objectValue ?? [:]
    }

    /// Sets `key` on the device's entry, unless it has one already.
    public mutating func setIfAbsent(_ key: String, _ value: JSONValue, on deviceID: String) {
        var entry = entries[deviceID]?.objectValue ?? [:]
        if entry[key] == nil { entry[key] = value }
        entries[deviceID] = .object(entry)
    }

    /// Excludes the device, unless its entry says whether it is.
    public mutating func exclude(_ deviceID: String) {
        setIfAbsent("excluded", true, on: deviceID)
    }

    /// Moves the list `key` of `fields` (a Homebridge exclude list): each text value `resolve` finds devices for excludes
    /// them; the others stay, and the list goes once none does.
    public mutating func excludeList(_ key: String, in fields: inout [String: JSONValue], resolve: (String) -> [String]) {
        guard let list = fields[key]?.arrayValue else { return }
        var left: [JSONValue] = []
        for value in list {
            let found = value.stringValue.map(resolve) ?? []
            if found.isEmpty { left.append(value) } else { found.forEach { exclude($0) } }
        }
        if left.isEmpty { fields.removeValue(forKey: key) } else { fields[key] = .array(left) }
    }

    /// Puts the entries back in `fields` as `_accessories`, when there are any.
    public func write(into fields: inout [String: JSONValue]) {
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
    }
}
