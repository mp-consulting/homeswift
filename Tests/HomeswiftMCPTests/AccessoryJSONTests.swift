import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// The accessory JSON written once for both builders is the JSON the tree-building version made: the same value,
/// and bytes the same as that value encodes to.
@Suite struct AccessoryJSONTests {
    /// The version before the builders, kept as the reference.
    static func reference(_ located: HomeswiftCatalog.Located, detailed: Bool) -> JSONValue {
        let accessory = located.accessory
        let information = accessory.information
        // Each dictionary is made at the size it ends up: growing them key by key was most of building the list.
        var object = [String: JSONValue](minimumCapacity: 12)
        object["id"] = .string(accessory.id)
        object["aid"] = .number(Double(accessory.aid))
        object["name"] = .string(accessory.name)
        object["supportsIdentify"] = .bool(accessory.supportsIdentify)
        object["category"] = .string("\(accessory.category)")
        object["bridge"] = .string(located.bridge.name)
        object["manufacturer"] = HomeswiftCatalog.json(information[.manufacturer]?.value ?? .null)
        object["model"] = HomeswiftCatalog.json(information[.model]?.value ?? .null)
        object["serialNumber"] = HomeswiftCatalog.json(information[.serialNumber]?.value ?? .null)
        if let platform = located.platform {
            object["platform"] = .string(platform.platform)
            object["platformName"] = .string(platform.name)
            // Its plugin does not run: the accessory answers No Response until it is resumed.
            if platform.paused { object["paused"] = true }
        }
        if let camera = accessory.cameraController {
            // The web UI gives it a camera card: live video or snapshots, from /api/cameras/<id>/…
            object["camera"] = true
            if camera is DoorbellController || accessory.services.contains(where: { $0.type.uuid == ServiceType.doorbell.uuid }) { object["doorbell"] = true }
        }
        object["services"] = .array(accessory.services.filter { $0.type.uuid != ServiceType.accessoryInformation.uuid }.map { service in
            var entry = [String: JSONValue](minimumCapacity: 6)
            entry["type"] = .string(service.type.name)
            if let subtype = service.subtype { entry["subtype"] = .string(subtype) }
            if let name = service[.name]?.value.stringValue { entry["name"] = .string(name) }
            if service.isPrimary { entry["primary"] = true }
            if HomeswiftCatalog.isInternal(service) { entry["internal"] = true }
            if let controller = service.adaptiveLighting { entry["adaptiveLighting"] = HomeswiftCatalog.adaptiveLightingJSON(controller) }
            if detailed {
                entry["characteristics"] = .array(service.characteristics.map { characteristic in
                    let type = characteristic.type
                    var detail = [String: JSONValue](minimumCapacity: 12)
                    detail["type"] = .string(type.name)
                    detail["value"] = HomeswiftCatalog.isOpaque(characteristic) ? .null : HomeswiftCatalog.value(of: characteristic)
                    detail["format"] = .string(type.format.rawValue)
                    detail["permissions"] = .array(type.permissions.map(\.rawValue).sorted().map(JSONValue.string))
                    if characteristic.isSecurityControl { detail["security"] = true }
                    if HomeswiftCatalog.groupTargets(located.accessory).contains(where: { $0 === characteristic }) { detail["group"] = true }
                    if characteristic.isConfidential { detail["confidential"] = true }
                    if HomeswiftCatalog.isInternal(characteristic) { detail["internal"] = true }
                    if HomeswiftCatalog.isOpaque(characteristic), !characteristic.isConfidential, let base64 = characteristic.value.stringValue {
                        // The size says whether HomeKit configured it; the bytes mean nothing as text.
                        detail["bytes"] = .number(Double(Data(base64Encoded: base64)?.count ?? 0))
                    }
                    if let unit = type.unit { detail["unit"] = .string(unit.rawValue) }
                    if let minimum = type.minValue { detail["minValue"] = .number(minimum) }
                    if let maximum = type.maxValue { detail["maxValue"] = .number(maximum) }
                    if let step = type.minStep { detail["minStep"] = .number(step) }
                    if let values = type.validValues { detail["validValues"] = .array(values.map { .number(Double($0)) }) }
                    return .object(detail)
                })
            } else {
                entry["values"] = .object(service.characteristics
                    .filter { $0.type.permissions.contains(.pairedRead) && $0.type.uuid != CharacteristicType.name.uuid && !$0.isConfidential && !HomeswiftCatalog.isOpaque($0) }
                    .reduce(into: [:]) { $0[$1.type.name] = HomeswiftCatalog.json($1.value) })
            }
            return .object(entry)
        })
        return .object(object)
    }

    /// Accessories of many shapes: ranges, steps, valid values, units, subtypes, linked names, opaque and
    /// confidential values, security controls.
    static func shapes() -> [Accessory] {
        let thermostat = Service(.thermostat, name: "Climate", optional: [.currentRelativeHumidity, .coolingThresholdTemperature], isPrimary: true)
        let sensor = Service(.temperatureSensor, name: "Temperature", subtype: "t\"1\"")
        let purifier = Service(.airPurifier, name: "Purifier", optional: [.rotationSpeed, .lockPhysicalControls])
        let filter = Service(.filterMaintenance, optional: [.filterLifeLevel])
        let opaque = Service(.switch, name: "Trigger é", subtype: "trigger", extra: [Characteristic(.setupEndpoints, value: "c3J0cC1tYXN0ZXIta2V5"), Characteristic(.selectedRTPStreamConfiguration, value: "AQID")])
        let blind = Service(.windowCovering, name: "Blind", optional: [.obstructionDetected, .holdPosition])
        let lock = Service(.lockMechanism, name: "Door", isPrimary: true)
        return [
            Accessory(id: "Shapes:climate", name: "Climate", manufacturer: "Bench \\ Co", model: "T/1", category: .thermostat, services: [thermostat, sensor]),
            Accessory(id: "Shapes:purifier", name: "Purifier", category: .airPurifier, services: [purifier, filter]),
            Accessory(id: "Shapes:opaque", name: "Opaque", category: .switch, services: [opaque]),
            Accessory(id: "Shapes:blind", name: "Blind\nNew", category: .windowCovering, services: [blind, lock]),
            Accessory(id: "Shapes:empty", name: "", category: .other, services: []),
        ]
    }

    @Test func bothBuildersMakeTheTreeVersionsJSON() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let bridge = environment.host.mainBridge
        let located = environment.catalog.located() + Self.shapes().map { HomeswiftCatalog.Located(accessory: $0, bridge: bridge, platform: environment.host.platforms.first) }
        #expect(located.count >= 7)
        for detailed in [true, false] {
            for found in located {
                let reference = Self.reference(found, detailed: detailed)
                #expect(HomeswiftCatalog.accessoryJSON(found, detailed: detailed) == reference, "\(found.accessory.id)")
                var bytes = JSONBytesWriter()
                HomeswiftCatalog.writeAccessory(found, detailed: detailed, to: &bytes)
                #expect(Data(bytes.bytes) == reference.encoded(), "\(found.accessory.id)")
                // With the web UI's last ring, as it added it to the value.
                guard var object = reference.objectValue else { continue }
                object["lastRing"] = "2026-10-23T18:00:00Z"
                var ringed = JSONBytesWriter()
                HomeswiftCatalog.writeAccessory(found, detailed: detailed, lastRing: "2026-10-23T18:00:00Z", to: &ringed)
                #expect(Data(ringed.bytes) == JSONValue.object(object).encoded())
            }
            // A whole list, as the web UI writes it.
            var list = JSONBytesWriter()
            list.array { json in for found in located { HomeswiftCatalog.writeAccessory(found, detailed: detailed, to: &json) } }
            #expect(Data(list.bytes) == JSONValue.array(located.map { Self.reference($0, detailed: detailed) }).encoded())
        }
    }
}
