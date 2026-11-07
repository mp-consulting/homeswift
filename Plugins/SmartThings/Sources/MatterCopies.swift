import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin

/// SmartThings devices that are Homeswift's own accessories, brought back through Homeswift's Matter bridge
/// (docs/clean-room/SmartThings.md, 12.3): never Discovered Devices, never polled, their events ignored.
enum MatterCopies {
    /// The Matter test vendor and product swift-matter gives Homeswift's bridge (and other software bridges).
    static let vendorID = 65521
    static let productID = 32768

    /// A Matter UniqueID as swift-matter makes it from an Accessory Id: the id itself up to 32 bytes, else the first 32
    /// hex digits of its SHA-256.
    static func uniqueID(of accessoryID: String) -> String {
        if accessoryID.utf8.count <= 32 { return accessoryID.lowercased() }
        return String(Secrets.hex(SHA256.hash(data: Data(accessoryID.utf8))).prefix(32))
    }

    struct Match: Sendable, Equatable {
        /// `bridge` (Homeswift's bridge itself), or the rules of 12.3 that matched (`a`, `b`, `c`).
        var rules: [String]
        var isBridge: Bool { rules == ["bridge"] }
    }

    static func hasTestIDs(_ device: SmartThingsDevice) -> Bool {
        device.matter?["vendorId"]?.saturatingIntValue == vendorID && device.matter?["productId"]?.saturatingIntValue == productID
    }

    /// Rule 1: Homeswift's bridge, by its test ids and its names; another bridge on the test vendor is not (rule 4).
    static func isHomeswiftBridge(_ device: SmartThingsDevice) -> Bool {
        guard hasTestIDs(device) else { return false }
        let manufacturer = device.manufacturerName?.trimmingCharacters(in: .whitespaces) ?? ""
        if manufacturer.isEmpty || manufacturer.caseInsensitiveCompare("Homeswift") == .orderedSame { return true }
        let names = [device.name, device.label, device.ocf?["modelNumber"]?.stringValue].compactMap { $0 }
        return names.contains { $0.range(of: "Homeswift Bridge", options: .caseInsensitive) != nil }
    }

    /// Which devices of the list are copies or Homeswift's bridge, by Device Id; `homeswiftIDs` gives the bridge's own
    /// Accessory Ids (every plugin's), asked only when a device has the test ids.
    static func find(in devices: [SmartThingsDevice], homeswiftIDs: () -> [String]) -> [String: Match] {
        let byID = Dictionary(devices.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
        let bridges = devices.filter(isHomeswiftBridge)
        let bridgeIDs = Swift.Set(bridges.map(\.deviceID))
        let bridgeNetworks = Swift.Set(bridges.compactMap { $0.matter?["networkId"]?.stringValue?.lowercased() })
        let unique = devices.contains(where: hasTestIDs) ? Swift.Set(homeswiftIDs().map(uniqueID)) : []
        var found: [String: Match] = [:]
        for device in devices {
            if bridgeIDs.contains(device.deviceID) {
                found[device.deviceID] = Match(rules: ["bridge"])
                continue
            }
            var rules: [String] = []
            // a: a parent, up to four levels, is Homeswift's bridge (the child's own manufacturer is passed through).
            var parent = device.parentDeviceID
            for _ in 0..<4 {
                guard let id = parent else { break }
                if bridgeIDs.contains(id) { rules.append("a"); break }
                parent = byID[id]?.parentDeviceID
            }
            // b: the same Matter node as Homeswift's bridge.
            if device.isMatter, let network = device.matter?["networkId"]?.stringValue?.lowercased(), bridgeNetworks.contains(network) { rules.append("b") }
            // c: the test ids and a UniqueID of one of the bridge's accessories.
            if hasTestIDs(device), let id = device.matter?["uniqueId"]?.stringValue?.lowercased(), unique.contains(id) { rules.append("c") }
            if !rules.isEmpty { found[device.deviceID] = Match(rules: rules) }
        }
        return found
    }
}
