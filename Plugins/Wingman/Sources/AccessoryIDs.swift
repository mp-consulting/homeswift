import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// Homeswift's Device Ids for one Wingman's Apple Home accessories. A Device Id is the HomeKit id the accessory had when
/// Homeswift first saw it, and it stays when Apple Home gives the same accessory a new one: HomeKit's ids are the Mac's
/// own and can all change at once (docs/adr/0014-mirrors-keep-their-device-id.md). Only the ids that differ are kept.
struct AccessoryIDs: Sendable, Equatable {
    /// Device Id by current HomeKit id, where they differ.
    private(set) var deviceIDs: [String: String] = [:]
    /// Current HomeKit id by Device Id, where they differ.
    private(set) var homeKitIDs: [String: String] = [:]

    init(_ deviceIDs: [String: String] = [:]) {
        self.deviceIDs = deviceIDs
        homeKitIDs = Dictionary(deviceIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    func deviceID(of homeKitID: String) -> String { deviceIDs[homeKitID] ?? homeKitID }

    /// The HomeKit id Wingman knows the accessory by now; a Device Id handed on to a new accessory is no longer the old one's.
    func homeKitID(of deviceID: String) -> String? {
        if let current = homeKitIDs[deviceID] { return current }
        return deviceIDs[deviceID] == nil ? deviceID : nil
    }
}

/// What the plugin remembers of each Apple Home accessory a Wingman lets it mirror, in `accessory-ids.json`, to know it
/// again under a new HomeKit id: by its Serial Number with its manufacturer and model, else by its name, room, home,
/// manufacturer and model. Only one accessory that went and one that came in the same Wingman's reads, each the only one
/// of that identity on its side, are taken for the same; a tie keeps the new id, as before.
final class AccessoryIdentities: Sendable {
    struct Record: Codable, Sendable, Equatable {
        /// The id Wingman knows it by now.
        var homeKitID: String
        var name: String
        var room: String?
        var home: String
        var manufacturer: String?
        var model: String?
        var serialNumber: String?
        /// When a read of the homes last missed it; nil while Apple Home has it.
        var missingSince: Date?
    }

    /// Records by Device Id, by Wingman id: each Mac gives HomeKit ids of its own.
    typealias Store = [String: [String: Record]]

    /// How long an accessory Apple Home no longer lists may come back under a new id and keep its Device Id.
    static let keptFor: TimeInterval = 30 * 24 * 3600

    private let file: JSONFile<Store>
    private let records: NIOLockedValueBox<Store>

    init(file: JSONFile<Store>) {
        self.file = file
        records = NIOLockedValueBox(file.load() ?? [:])
    }

    /// The Device Ids of a read of a Wingman's homes. `accessories` are those Homeswift may mirror (Excluded ones
    /// included), each with its home's name; `present` every HomeKit id the read gave. Answers the accessories that were
    /// known again under a new id, by their Device Id, beside the ids.
    func resolve(
        wingman: String, accessories: [(accessory: WingmanAPI.Accessory, home: String)], present: Set<String>, now: Date = Date()
    ) -> (ids: AccessoryIDs, renamed: [(deviceID: String, from: String, to: String, name: String)]) {
        var renamed: [(deviceID: String, from: String, to: String, name: String)] = []
        let ids = records.withLockedValue { (store: inout Store) -> AccessoryIDs in
            var known = store[wingman] ?? [:]
            let before = known
            var byHomeKitID: [String: String] = [:]
            for (deviceID, record) in known { byHomeKitID[record.homeKitID] = deviceID }
            // Still there: what it is now, and no longer missing.
            var arrivals: [(accessory: WingmanAPI.Accessory, home: String)] = []
            for (accessory, home) in accessories {
                if let deviceID = byHomeKitID[accessory.id] {
                    known[deviceID] = Self.record(accessory, home: home, keeping: known[deviceID])
                } else {
                    arrivals.append((accessory, home))
                }
            }
            for (deviceID, record) in known where !present.contains(record.homeKitID) {
                if let since = record.missingSince {
                    if now.timeIntervalSince(since) > Self.keptFor { known.removeValue(forKey: deviceID) }
                } else {
                    known[deviceID]?.missingSince = now
                }
            }
            // Known again: the only one of its identity among those that went and among those that came.
            let missing = known.filter { $0.value.missingSince != nil }
            let came = arrivals.map { Self.record($0.accessory, home: $0.home, keeping: nil) }
            var matchedDevices: Set<String> = [], matchedArrivals: Set<Int> = []
            for key in [Self.serialKey, Self.placeKey] {
                var wentBy: [String: [String]] = [:]
                for (deviceID, record) in missing where !matchedDevices.contains(deviceID) {
                    if let identity = key(record) { wentBy[identity, default: []].append(deviceID) }
                }
                var cameBy: [String: [Int]] = [:]
                for (index, record) in came.enumerated() where !matchedArrivals.contains(index) {
                    if let identity = key(record) { cameBy[identity, default: []].append(index) }
                }
                for (identity, deviceIDs) in wentBy {
                    guard deviceIDs.count == 1, let indices = cameBy[identity], indices.count == 1 else { continue }
                    let deviceID = deviceIDs[0], index = indices[0]
                    guard let old = known[deviceID], !Self.differ(old.serialNumber, came[index].serialNumber) else { continue }
                    known[deviceID] = came[index]
                    matchedDevices.insert(deviceID)
                    matchedArrivals.insert(index)
                    renamed.append((deviceID, old.homeKitID, came[index].homeKitID, came[index].name))
                }
            }
            // New: its HomeKit id is its Device Id, unless another accessory goes by that one (HomeKit gave an id again).
            for (index, record) in came.enumerated() where !matchedArrivals.contains(index) {
                let taken = known[record.homeKitID].map { $0.homeKitID != record.homeKitID } ?? false
                known[taken ? UUID().uuidString : record.homeKitID] = record
            }
            store[wingman] = known
            if known != before { save(store) }
            let aliases = known.compactMapValues { $0.homeKitID }.filter { $0.key != $0.value }
            return AccessoryIDs(Dictionary(aliases.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first }))
        }
        return (ids, renamed)
    }

    /// The Device Ids as they are, without a read: before a Wingman's first one.
    func ids(wingman: String) -> AccessoryIDs {
        records.withLockedValue { store in
            let aliases = (store[wingman] ?? [:]).filter { $0.key != $0.value.homeKitID }
            return AccessoryIDs(Dictionary(aliases.map { ($0.value.homeKitID, $0.key) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// Called with the lock held: two Wingmen's reads never leave an older store on disk than the one in memory.
    private func save(_ store: Store) {
        try? file.save(store)
    }

    private static func record(_ accessory: WingmanAPI.Accessory, home: String, keeping old: Record?) -> Record {
        // A Serial Number HomeKit has not read yet is not a new one.
        let serial = accessory.serialNumber.flatMap { $0.isEmpty ? nil : $0 } ?? old?.serialNumber
        return Record(
            homeKitID: accessory.id, name: accessory.name, room: accessory.room, home: home, manufacturer: accessory.manufacturer,
            model: accessory.model, serialNumber: serial, missingSince: nil)
    }

    /// Two Serial Numbers that are both known and not the same: two devices, wherever they are.
    private static func differ(_ one: String?, _ other: String?) -> Bool {
        guard let one, !one.isEmpty, let other, !other.isEmpty else { return false }
        return one.uppercased() != other.uppercased()
    }

    /// Its Serial Number, with its manufacturer and model: two brands may number alike.
    private static func serialKey(_ record: Record) -> String? {
        guard let serial = record.serialNumber?.uppercased(), !serial.isEmpty else { return nil }
        return [serial, record.manufacturer ?? "", record.model ?? ""].joined(separator: "\u{1F}")
    }

    /// Where it is and what it is, when it has no Serial Number to go by.
    private static func placeKey(_ record: Record) -> String? {
        [record.home, record.room ?? "", record.name, record.manufacturer ?? "", record.model ?? ""].joined(separator: "\u{1F}")
    }
}
