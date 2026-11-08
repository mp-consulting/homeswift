import Foundation
import Homeswift
import HomeswiftPlugin

/// The block's settings (docs/clean-room/HomeAssistant.md, section 8). Every key optional; defaults in code.
struct Settings: Sendable, Equatable {
    /// The base URL, `http://homeassistant.local:8123`.
    var url: String?
    /// The long-lived access token, when the block holds it (sealed or a `vault:` reference); Setup keeps it in the vault.
    var accessToken: String?
    /// The mDNS `uuid` of the server Setup found.
    var serverID: String?
    /// The domains taken; all of the first release by default.
    var domains: Set<String>
    /// Entity ids or globs (`sensor.*_battery`) included even when hidden or a configuration or diagnostic entity.
    var includeEntities: [String]
    /// Entity ids or globs left out.
    var excludeEntities: [String]
    /// Entities shown in the web UI but never published to HomeKit (`Accessory.mirroredFrom`): `"all"` or entity ids/globs.
    var mirrorAll: Bool
    var mirror: [String]
    /// Codes sent with `lock.*` and `alarm_*` (secret-named keys: the runtime seals and masks them).
    var lockCode: String?
    var alarmCode: String?
    /// For `wss://` with a self-signed certificate: false trusts the first certificate seen, then pins it.
    var verifyTLS: Bool

    init(_ block: JSONValue) {
        func strings(_ key: String) -> [String] {
            if let single = block[key]?.stringValue { return single.isEmpty ? [] : [single] }
            return block[key]?.arrayValue?.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        }
        url = block["url"]?.stringValue?.nonEmpty
        accessToken = block["accessToken"]?.stringValue?.nonEmpty
        serverID = block["serverId"]?.stringValue?.nonEmpty
        let listed = Set(strings("domains")).intersection(EntityFunctions.domains)
        domains = listed.isEmpty ? EntityFunctions.domains : listed
        includeEntities = strings("includeEntities")
        excludeEntities = strings("excludeEntities")
        let mirror = strings("mirror")
        mirrorAll = mirror.contains { $0.lowercased() == "all" }
        self.mirror = mirror.filter { $0.lowercased() != "all" }
        lockCode = block["lockPasscode"]?.stringValue?.nonEmpty
        alarmCode = block["alarmPasscode"]?.stringValue?.nonEmpty
        verifyTLS = block["verifyTLS"]?.boolValue ?? true
    }

    func isMirrored(_ entityID: String) -> Bool { mirrorAll || Glob.matches(any: mirror, entityID) }
}


/// An entity as one accessory shows it.
struct EntityPlan: Sendable, Equatable {
    var entityID: String
    /// Its service's subtype: `<platform>.<unique_id>`, else the entity registry id, else the entity id.
    var key: String
    var name: String
    /// Named by `includeEntities` or included in its device's parts: a binary sensor of a misleading class is shown too.
    var explicitlyIncluded: Bool
    /// Feeds the device's Battery service.
    var feedsBattery: Bool
    /// A battery sensor: the Battery service only, no service of its own.
    var batteryOnly: Bool
    var shape: String
}

/// One accessory of a device: its published entities, or its mirrored ones.
struct AccessoryPlan: Sendable, Equatable {
    var accessoryID: String
    var mirrored: Bool
    var entities: [EntityPlan]
    /// What decides its objects: a change rebuilds it under the same aid and iids.
    var signature: String
}

/// A Home Assistant device as the plugin makes it (a Device Id, 4.4).
struct DevicePlan: Sendable, Equatable {
    var deviceID: String
    var name: String
    var manufacturer: String
    var model: String
    var serialNumber: String
    var firmware: String
    var room: String?
    var kind: String
    var accessories: [AccessoryPlan]
    /// Every supported entity of the device, included or not: its Parts in Setup.
    var parts: [DevicePart]
}

struct Plan: Sendable {
    var devices: [DevicePlan]
    /// Domains seen that the first release does not map.
    var unsupported: Set<String>
    /// Entities that are this bridge's own accessories coming back through HA's homekit_controller (9.2).
    var loops: Set<String>
    /// Entities that feed a device's Battery.
    var batterySources: Set<String>
}

extension HomeAssistantPlugin {
    /// The Device Id of an entity (4.4): its HA device, else its registry entry, else its entity id.
    static func deviceID(entityID: String, entry: EntityEntry?) -> String {
        if let device = entry?.deviceID { return device }
        if let entry { return "entity:\(entry.id)" }
        return "state:\(entityID)"
    }

    /// A firmware revision HomeKit accepts (`x[.y[.z]]`), from the start of a version string; nil when it has none.
    static func firmware(_ version: String?) -> String? {
        guard let version, let range = version.range(of: #"^[0-9]+(\.[0-9]+){0,2}"#, options: .regularExpression) else { return nil }
        return String(version[range])
    }

    /// What the bridge would make of the server's view now.
    func makePlan() -> Plan {
        let loops = loopEntities()
        var unsupported = Set<String>()
        var batterySources = Set<String>()
        struct Group { var entities: [(EntityState, EntityEntry?, EntityPlan, Bool)] = [] }
        var groups: [String: Group] = [:]
        var allParts: [String: [DevicePart]] = [:]
        for state in states.values.sorted(by: { $0.entityID < $1.entityID }) {
            let domain = state.domain
            guard EntityFunctions.domains.contains(domain) else {
                unsupported.insert(domain)
                continue
            }
            guard settings.domains.contains(domain) else { continue }
            if loops.contains(state.entityID) { continue }
            let entry = entities[state.entityID]
            if entry?.disabledBy != nil { continue }
            if let deviceID = entry?.deviceID, devices[deviceID]?.disabledBy != nil { continue }
            let deviceID = Self.deviceID(entityID: state.entityID, entry: entry)
            // `<platform>.<unique_id>`: it survives a renamed entity id and an entity removed and added again (the registry
            // id does not); else the registry id, else the entity id (docs/parity.md section 4).
            let key = entry.flatMap { entry in entry.uniqueID.map { "\(entry.platform ?? "").\($0)" } } ?? entry?.id ?? state.entityID
            let parts = context.accessorySettings(for: deviceID).parts
            let batteryOnly = (domain == "sensor" || domain == "binary_sensor") && state.deviceClass == "battery"
            let excluded = parts[key] == false || Glob.matches(any: settings.excludeEntities, state.entityID)
            let explicitlyIncluded = !excluded && (parts[key] == true || Glob.matches(any: settings.includeEntities, state.entityID))
            // Hidden, configuration and diagnostic entities are left out unless included (4.5); a battery sensor, often
            // diagnostic, still feeds its device's Battery.
            let byDefault = entry?.entityCategory == nil && entry?.hiddenBy == nil
            let included = !excluded && (explicitlyIncluded || byDefault || batteryOnly)
            let name = state.friendlyName ?? entry?.name ?? entry?.originalName ?? state.entityID
            // Parts list what a person can switch: everything that would show something.
            if batteryOnly || Self.wouldShow(state, included: true) {
                allParts[deviceID, default: []].append(DevicePart(key, name: name, icon: Self.icon(of: domain), included: included))
            }
            guard included else { continue }
            let feedsBattery = BatteryFunction.feeds(state)
            if feedsBattery { batterySources.insert(state.entityID) }
            let plan = EntityPlan(entityID: state.entityID, key: key, name: name, explicitlyIncluded: explicitlyIncluded, feedsBattery: feedsBattery,
                                  batteryOnly: batteryOnly, shape: EntityFunctions.shape(of: state))
            groups[deviceID, default: Group()].entities.append((state, entry, plan, settings.isMirrored(state.entityID)))
        }
        var plans: [DevicePlan] = []
        for (deviceID, group) in groups.sorted(by: { $0.key < $1.key }) {
            // The primary domain first, so the accessory's primary service is its main Function.
            let ranked = group.entities.sorted { a, b in
                let ra = EntityFunctions.primaryOrder.firstIndex(of: a.0.domain) ?? 99, rb = EntityFunctions.primaryOrder.firstIndex(of: b.0.domain) ?? 99
                return ra != rb ? ra < rb : a.0.entityID < b.0.entityID
            }
            // Only battery sensors: nothing to show but a Battery when something else on the device shows.
            guard ranked.contains(where: { !$0.2.batteryOnly && Self.wouldShow($0.0, included: $0.2.explicitlyIncluded) }) else { continue }
            let first = ranked[0]
            let device = first.1?.deviceID.flatMap { devices[$0] }
            let name = device?.displayName ?? first.0.friendlyName ?? first.0.entityID
            let manufacturer = device?.manufacturer?.nonEmpty ?? "Home Assistant"
            let model = device?.model?.nonEmpty ?? first.0.domain
            let serial = device?.macSerial ?? device?.serialNumber?.nonEmpty ?? deviceID
            let firmware = Self.firmware(device?.swVersion) ?? "1.0.0"
            let areaID = device?.areaID ?? first.1?.areaID
            let room = areaID.flatMap { areas[$0] }
            let published = ranked.filter { !$0.3 }, mirrored = ranked.filter { $0.3 }
            var accessories: [AccessoryPlan] = []
            let info = "\(name)|\(manufacturer)|\(model)|\(serial)|\(firmware)|\(room ?? "")"
            func accessory(_ id: String, _ list: [(EntityState, EntityEntry?, EntityPlan, Bool)], mirrored: Bool) -> AccessoryPlan {
                let entities = list.map(\.2)
                let signature = ([id, "\(mirrored)", info] + entities.map { "\($0.key)|\($0.entityID)|\($0.shape)|\($0.explicitlyIncluded)|\($0.batteryOnly)" })
                    .joined(separator: "\n")
                return AccessoryPlan(accessoryID: id, mirrored: mirrored, entities: entities, signature: signature)
            }
            let mainID = Self.accessoryID(deviceID: deviceID)
            let hasShown: ([(EntityState, EntityEntry?, EntityPlan, Bool)]) -> Bool = { list in list.contains { !$0.2.batteryOnly } }
            if hasShown(published) || mirrored.isEmpty {
                // The battery goes with the published Functions.
                accessories.append(accessory(mainID, published + mirrored.filter { $0.2.batteryOnly }, mirrored: false))
                if hasShown(mirrored) { accessories.append(accessory("\(mainID):mirrored", mirrored.filter { !$0.2.batteryOnly }, mirrored: true)) }
            } else {
                accessories.append(accessory(mainID, mirrored, mirrored: true))
            }
            plans.append(DevicePlan(
                deviceID: deviceID, name: Self.sanitized(name), manufacturer: Self.sanitized(manufacturer), model: Self.sanitized(model), serialNumber: serial,
                firmware: firmware, room: room, kind: first.0.domain, accessories: accessories,
                parts: (allParts[deviceID] ?? []).sorted { $0.name < $1.name }))
        }
        return Plan(devices: plans, unsupported: unsupported, loops: loops, batterySources: batterySources)
    }

    /// Whether an entity would make a service of its own.
    static func wouldShow(_ state: EntityState, included: Bool) -> Bool {
        switch state.domain {
        case "sensor": SensorFunction.kind(of: state) != nil
        case "binary_sensor":
            state.deviceClass != "battery" && (included || !BinarySensorFunction.misleading.contains(state.deviceClass ?? ""))
        case "cover": CoverFunction.kind(of: state) != nil
        case "media_player": state.supports(MediaPowerFunction.turnOn) || state.supports(MediaPowerFunction.turnOff)
        default: EntityFunctions.domains.contains(state.domain)
        }
    }

    static func icon(of domain: String) -> String {
        switch domain {
        case "light": "bulb"
        case "lock": "lock"
        case "sensor", "binary_sensor": "sensor"
        case "climate": "thermostat"
        case "fan": "fan"
        default: "switch"
        }
    }

    /// Names reach HomeKit: control characters out, 64 characters at most.
    static func sanitized(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        return String(clean.prefix(64)).trimmingCharacters(in: .whitespaces).nonEmpty ?? "Home Assistant"
    }

    // MARK: Loops (9.2)

    /// Entities that are this bridge's own accessories coming back from HA's `homekit_controller`: its unique id starts
    /// with one of Homeswift's HAP ids, its device names one by its identifiers, or the device has the manufacturer and
    /// serial number of an accessory Homeswift publishes; devices behind such a device too.
    func loopEntities() -> Set<String> {
        let ownIDs = Set(context.homeswiftBridgeSerialNumbers.map { $0.uppercased() })
        var published = Set<String>()
        for accessory in context.hostAccessories where accessory.mirroredFrom == nil {
            guard let serial = accessory.information[.serialNumber]?.value.stringValue else { continue }
            published.insert("\(accessory.information[.manufacturer]?.value.stringValue ?? "")|\(serial)")
        }
        let controllerEntities = entities.values.filter { $0.platform == "homekit_controller" }
        guard !controllerEntities.isEmpty else { return [] }
        func isOwn(_ pairingID: Substring) -> Bool { ownIDs.contains(pairingID.uppercased()) }
        var loopDevices = Set<String>()
        for device in devices.values {
            let fromController = device.identifiers.contains { $0[0].hasPrefix("homekit_controller") }
            let byIdentifier = device.identifiers.contains { pair in
                pair[0] == "homekit_controller:accessory-id" && pair[1].range(of: ":aid:").map { isOwn(pair[1][..<$0.lowerBound]) } == true
            }
            let bySerial = fromController && published.contains("\(device.manufacturer ?? "")|\(device.serialNumber ?? "")")
            if byIdentifier || bySerial { loopDevices.insert(device.id) }
        }
        // Devices whose via_device leads to one of them.
        var changed = true
        while changed {
            changed = false
            for device in devices.values where !loopDevices.contains(device.id) {
                if let via = device.viaDeviceID, loopDevices.contains(via) {
                    loopDevices.insert(device.id)
                    changed = true
                }
            }
        }
        var loops = Set<String>()
        for entry in controllerEntities {
            let pairingID = entry.uniqueID?.split(separator: "_", maxSplits: 1).first
            if let pairingID, isOwn(pairingID) { loops.insert(entry.entityID); continue }
            if let device = entry.deviceID, loopDevices.contains(device) { loops.insert(entry.entityID) }
        }
        return loops
    }
}
