import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each device is a device whose Device Id is its MAC, of the Device Kind `light` or
// `switch`, found by the scan (or at an address of `addresses`) and asking nothing before the bridge talks to it: every
// device found is added, as the Homebridge plugin did, and one is left out by its Accessory Settings (Excluded) or the
// Homebridge plugin's lists.
//
// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the Homebridge plugin's keys as they are, with
// `addresses` beside them. Accessory Settings are the Core ones only. A `blacklist` of MACs moves into `_accessories` as
// Excluded; a `whitelist` cannot (it leaves out the devices not listed, those not found yet too) and stays.
extension MagicHomePlugin {
    enum ListMode { case none, blacklist, whitelist }

    /// How `blacklistedUniqueIDs` is read: only when both keys are there (section 2).
    var listMode: ListMode {
        guard let management = configuration.deviceManagement, management.blacklistedUniqueIDs != nil, let mode = management.blacklistOrWhitelist else { return .none }
        if mode.contains("blacklist") { return .blacklist }
        if mode.contains("whitelist") { return .whitelist }
        return .none
    }

    /// The listed MACs, as Device Ids.
    var listedIDs: Set<String> {
        Set((configuration.deviceManagement?.blacklistedUniqueIDs ?? []).map { MagicHomeDiscovery.bareMAC($0) ?? $0.uppercased() })
    }

    /// Whether the lists let the device in: not blacklisted, or whitelisted.
    func isAllowed(_ id: String) -> Bool {
        switch listMode {
        case .none: true
        case .blacklist: !listedIDs.contains(id)
        case .whitelist: listedIDs.contains(id)
        }
    }

    // MARK: Setup

    /// The devices a scan heard and those the plugin runs: a running plugin answers from what it has heard; an instance
    /// made only for Setup scans first (two seconds).
    public func discover() async throws -> [DiscoveredDevice] {
        if !isStarted || seen.isEmpty { await scan() }
        var found = seen
        for (id, record) in records.values {
            let device = devices[id]
            let profile = await device?.profile
            var entry = found[id] ?? DiscoveredDevice(
                deviceID: id, name: context.accessory(id: MagicHomeAccessory.accessoryID(id))?.name ?? profile?.description ?? id,
                model: record.module, address: record.host, isSetUp: isAllowed(id), excludedBySettings: !isAllowed(id))
            entry.kind = profile?.deviceKind ?? entry.kind
            if let device { entry.isReachable = await device.isReachable }
            found[id] = entry
        }
        // Set up: on the bridge, not only heard (a device that did not answer, or of a model the plugin does not know, is not).
        for (id, entry) in found where entry.isSetUp {
            found[id]?.isSetUp = devices[id] != nil || context.accessory(id: MagicHomeAccessory.accessoryID(id)) != nil
        }
        return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if let device = devices[deviceID] { return await device.profile.deviceKind }
        return seen[deviceID]?.kind
    }

    // MARK: Settings

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue { Self.canonical(block) }

    /// The block with a `blacklist` moved into `_accessories` (each MAC Excluded, unless its entry says otherwise) and the
    /// two keys dropped; an entry that is not a MAC stays in the list.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue, var management = fields["deviceManagement"]?.objectValue,
              let mode = management["blacklistOrWhitelist"]?.stringValue, mode.contains("blacklist"),
              let list = management["blacklistedUniqueIDs"]?.arrayValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        var left: [JSONValue] = []
        for item in list {
            guard let text = item.stringValue, let id = MagicHomeDiscovery.bareMAC(text) else {
                left.append(item)
                continue
            }
            var entry = entries[id]?.objectValue ?? [:]
            if entry["excluded"] == nil { entry["excluded"] = true }
            entries[id] = .object(entry)
        }
        if left.isEmpty {
            management.removeValue(forKey: "blacklistedUniqueIDs")
            management.removeValue(forKey: "blacklistOrWhitelist")
        } else {
            management["blacklistedUniqueIDs"] = .array(left)
        }
        if management.isEmpty { fields.removeValue(forKey: "deviceManagement") } else { fields["deviceManagement"] = .object(management) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
