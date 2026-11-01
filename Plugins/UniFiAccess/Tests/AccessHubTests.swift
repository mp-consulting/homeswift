import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiAccess

let hubID = "UniFi Access:AABBCCDDEEFF"
let gateID = "UniFi Access:112233445566"
let ultraID = "UniFi Access:AA0000000001"

extension Accessory {
    func service(_ type: ServiceType, _ subtype: String?) -> Service? {
        services.first { $0.type.uuid == type.uuid && $0.subtype == subtype }
    }
}

func value(_ host: PluginHost, _ id: String, _ type: ServiceType, _ subtype: String? = nil, _ characteristic: CharacteristicType) -> Int? {
    accessory(host, id)?.service(type, subtype)?[characteristic]?.value.intValue
}

/// Records every integer value a characteristic takes from now on: a state that lasts a scaled moment is seen even
/// by a runner that stalls through it.
func record(_ host: PluginHost, _ id: String, _ type: ServiceType, _ subtype: String? = nil, _ characteristic: CharacteristicType) -> NIOLockedValueBox<[Int]> {
    let values = NIOLockedValueBox<[Int]>([])
    accessory(host, id)?.service(type, subtype)?.characteristic(characteristic).observe { change in
        if let value = change.newValue.intValue { values.withLockedValue { $0.append(value) } }
    }
    return values
}

/// Whether `values` took `states` in that order, other values before, between or after.
func went(_ values: NIOLockedValueBox<[Int]>, through states: [Int]) -> Bool {
    var rest = states[...]
    for value in values.withLockedValue({ $0 }) where value == rest.first { rest = rest.dropFirst() }
    return rest.isEmpty
}

func flag(_ host: PluginHost, _ id: String, _ type: ServiceType, _ subtype: String? = nil, _ characteristic: CharacteristicType = .on) -> Bool? {
    accessory(host, id)?.service(type, subtype)?[characteristic]?.value.boolValue
}

/// `access-hub.test.ts`, `access-controller.test.ts`, `access-events.test.ts`: hubs and readers end to end, from
/// the controller's JSON to HomeKit services, through events, writes and MQTT.
@Suite(.timeLimit(.minutes(1)))
struct AccessHubTests {
    let environment = AccessTestEnvironment()

    // MARK: Accessories

    @Test func hubServices() async throws {
        let host = try await environment.start(devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off"), ("input_state_dps", "on"), ("wiring_state_dps-neg", "on"), ("wiring_state_dps-pos", "on"), ("tamper_event", "false")]), "capabilities": ["is_hub", "door_bell", "tamper_proofing"]])])
        defer { Task { await host.stop() } }
        let hub = try #require(accessory(host, hubID))
        #expect(hub.name == "Test Device")
        #expect(hub.information[.manufacturer]?.value == .string("Ubiquiti Inc."))
        #expect(hub.information[.model]?.value == .string("UA Hub"))
        #expect(hub.information[.serialNumber]?.value == .string("AABBCCDDEEFF"))
        #expect(hub.information[.firmwareRevision]?.value == .string("3.0.0"))

        let lock = try #require(hub.service(.lockMechanism, nil))
        #expect(!lock.isPrimary)
        #expect(lock[.lockCurrentState]?.value.intValue == 1)
        #expect(lock[.configuredName]?.value == .string("Test Device"))
        let doorbell = try #require(hub.service(.doorbell, nil))
        #expect(doorbell.isPrimary)
        // DPS is wired here.
        let dps = try #require(hub.service(.contactSensor, "ContactSensor.DPS"))
        #expect(dps[.contactSensorState]?.value.intValue == 0)
        #expect(dps[.statusActive]?.value == .bool(true))
        #expect(dps[.statusTampered]?.value.intValue == 0)
        #expect(dps[.configuredName]?.value == .string("Test Device Door Position Sensor"))
        // REX is not wired: the sensor is there, as in Homebridge, and reads closed.
        #expect(hub.service(.contactSensor, "ContactSensor.REX")?[.contactSensorState]?.value.intValue == 0)
        #expect(hub.service(.switch, "LockTrigger") == nil)
        #expect(environment.log.contains("The door lock relay will lock five seconds after unlocking in HomeKit."))
        #expect(environment.log.contains("Discovered UA Hub: Test Device [UA Hub] (address: 192.168.1.100 mac: AABBCCDDEEFF)."))
    }

    @Test func allTerminalInputs() async throws {
        let host = try await environment.start(devices: [uah()])
        defer { Task { await host.stop() } }
        let hub = try #require(accessory(host, hubID))
        for subtype in ["ContactSensor.DPS", "ContactSensor.REL", "ContactSensor.REN", "ContactSensor.REX"] {
            #expect(hub.service(.contactSensor, subtype) != nil, "\(subtype)")
        }
        // `close` and `off` are not `on`: open.
        #expect(hub.service(.contactSensor, "ContactSensor.REX")?[.contactSensorState]?.value.intValue == 1)
    }

    @Test func featureOptionsShapeTheAccessory() async throws {
        let host = try await environment.start(
            devices: [uah()], options: ["Disable.Hub.REL", "Disable.Hub.Doorbell", "Enable.Hub.Lock.Trigger", "Enable.Hub.Doorbell.Trigger", "Enable.Hub.Door.UseGarageOpener"])
        defer { Task { await host.stop() } }
        let hub = try #require(accessory(host, hubID))
        #expect(hub.service(.contactSensor, "ContactSensor.REL") == nil)
        #expect(hub.service(.doorbell, nil) == nil)
        #expect(hub.service(.lockMechanism, nil) == nil)
        let garage = try #require(hub.service(.garageDoorOpener, nil))
        #expect(garage.isPrimary)
        #expect(hub.service(.switch, "LockTrigger")?[.configuredName]?.value == .string("Test Device Lock Trigger"))
        #expect(hub.service(.switch, "DoorbellTrigger")?[.configuredName]?.value == .string("Test Device Doorbell Trigger"))
    }

    @Test func disabledDevicesStayOut() async throws {
        let host = try await environment.start(devices: [uah(), ugt()], options: ["Disable.Device.AABBCCDDEEFF"], expecting: 1)
        defer { Task { await host.stop() } }
        #expect(accessory(host, hubID) == nil)
        #expect(accessory(host, gateID) != nil)
    }

    @Test func unsupportedDevicesAreNamedOnce() async throws {
        let host = try await environment.start(devices: [uah(), deviceJSON(["capabilities": ["is_camera"], "mac": "CC:CC:CC:CC:CC:CC", "device_type": "UVC", "display_model": "G4"])], expecting: 1)
        defer { Task { await host.stop() } }
        _ = await environment.controllerActor()?.api.getBootstrap()
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.log.messages(.info).filter { $0.contains("UniFi Access device type 'UVC' is not currently supported") }.count == 1)
    }

    // MARK: Readers

    @Test func accessMethods() async throws {
        let host = try await environment.start(devices: [ultra()])
        defer { Task { await host.stop() } }
        let reader = try #require(accessory(host, ultraID))
        #expect(flag(host, ultraID, .switch, "AccessMethod.Face") == true)
        #expect(flag(host, ultraID, .switch, "AccessMethod.NFC") == true)
        #expect(flag(host, ultraID, .switch, "AccessMethod.PIN") == false)
        #expect(reader.service(.switch, "AccessMethod.TouchPass")?[.configuredName]?.value == .string("Ultra TouchPass"))
        // UA Ultra in REX mode: the request to exit sensor, no DPS.
        #expect(reader.service(.contactSensor, "ContactSensor.REX") != nil)
        #expect(reader.service(.contactSensor, "ContactSensor.DPS") == nil)

        let pin = try #require(reader.service(.switch, "AccessMethod.PIN")?[.on])
        try await pin.write(.bool(true))
        let put = try #require(environment.controller.requests(matching: "/device/ultra-1/settings").last)
        #expect(put.method == "PUT")
        #expect(put.body == #"[{"key":"pin_code","tag":"open_door_mode","value":"yes"}]"#)

        // The controller refuses: the switch goes back.
        environment.controller.override("/settings") { _ in HTTPResponse(status: 500) }
        let nfc = try #require(reader.service(.switch, "AccessMethod.NFC")?[.on])
        try await nfc.write(.bool(false))
        #expect(await eventually { nfc.value == .bool(true) })
        #expect(environment.log.contains("Unable to deactivate the NFC access method.", level: .error))

        // A method without a config entry cannot be set.
        let hand = try #require(reader.service(.switch, "AccessMethod.Hand")?[.on])
        try await hand.write(.bool(true))
        #expect(await eventually { hand.value == .bool(false) })

        // The controller changes a method.
        environment.send(AccessEventType.deviceUpdateV2, "ultra-1", data: ["access_method": ["face": "no", "pin_code": "garbage"]])
        #expect(await eventually { flag(host, ultraID, .switch, "AccessMethod.Face") == false })
    }

    @Test func accessMethodsOnTheirOwnAccessory() async throws {
        let host = try await environment.start(devices: [ultra()], options: ["Enable.AccessMethod.SeparateAccessory"], expecting: 2)
        defer { Task { await host.stop() } }
        let methods = try #require(accessory(host, "\(ultraID).AccessMethods"))
        #expect(methods.name == "Ultra Access Methods")
        #expect(methods.information[.serialNumber]?.value == .string("AA0000000001-AccessMethods"))
        #expect(methods.service(.switch, "AccessMethod.Face") != nil)
        #expect(accessory(host, ultraID)?.service(.switch, "AccessMethod.Face") == nil)
    }

    @Test func ultraInputModeFollowsTheHub() async throws {
        let host = try await environment.start(devices: [ultra()])
        defer { Task { await host.stop() } }
        var changed = ultra(mode: "dps")
        changed["configs"] = configs([("input_d1_button", "off"), ("input_d1_dps", "on"), ("output_d1_lock_relay", "off")])
        environment.send(AccessEventType.deviceUpdate, "ultra-1", data: .object(changed))
        #expect(await eventually { accessory(host, ultraID)?.service(.contactSensor, "ContactSensor.DPS") != nil })
        #expect(accessory(host, ultraID)?.service(.contactSensor, "ContactSensor.REX") == nil)
        #expect(value(host, ultraID, .contactSensor, "ContactSensor.DPS", .contactSensorState) == 0)
    }

    // MARK: Locks

    @Test func unlockingFromHomeKit() async throws {
        let host = try await environment.start(devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off")])])])
        defer { Task { await host.stop() } }
        let lock = try #require(accessory(host, hubID)?.service(.lockMechanism, nil))
        try await lock.characteristic(.lockTargetState).write(.int(0))
        #expect(environment.controller.requests(matching: "/location/loc-1/unlock").count == 1)

        // Relocking needs a lock delay: refused, and the target goes back.
        environment.send(AccessEventType.deviceRemoteUnlock, "test-device-unique-id")
        #expect(await eventually { lock[.lockCurrentState]?.value.intValue == 0 })
        try await lock.characteristic(.lockTargetState).write(.int(1))
        #expect(environment.log.contains("Unable to manually relock the door when the lock relay is configured to the default settings.", level: .error))
        #expect(await eventually { lock[.lockTargetState]?.value.intValue == 0 })
    }

    @Test func lockDelayInterval() async throws {
        let host = try await environment.start(
            devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off")])])], options: ["Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5", "Enable.Hub.Lock.Trigger"])
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("The door lock relay will remain unlocked for 5 minutes after unlocking in HomeKit."))
        let hub = try #require(accessory(host, hubID))
        try await hub.service(.lockMechanism, nil)!.characteristic(.lockTargetState).write(.int(0))
        #expect(environment.controller.requests(matching: "/lock_rule").last?.body == #"{"interval":5,"type":"custom"}"#)

        // The trigger switch: on unlocks, off locks.
        environment.send(AccessEventType.deviceRemoteUnlock, "test-device-unique-id")
        #expect(await eventually { flag(host, hubID, .switch, "LockTrigger") == true })
        try await hub.service(.switch, "LockTrigger")!.characteristic(.on).write(.bool(false))
        #expect(environment.controller.requests(matching: "/lock_rule").last?.body == #"{"type":"reset"}"#)
    }

    @Test func indefiniteUnlock() async throws {
        let host = try await environment.start(devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off")])])], options: ["Enable.Hub.LockDelayInterval.AABBCCDDEEFF.0"])
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("will remain unlocked indefinitely"))
        try await accessory(host, hubID)!.service(.lockMechanism, nil)!.characteristic(.lockTargetState).write(.int(0))
        #expect(environment.controller.requests(matching: "/lock_rule").last?.body == #"{"type":"keep_unlock"}"#)
    }

    @Test func offlineHubsRefuse() async throws {
        let host = try await environment.start(devices: [uah(["is_online": false, "configs": configs([("input_state_rly-lock_dry", "off")])])])
        defer { Task { await host.stop() } }
        let target = try #require(accessory(host, hubID)?.service(.lockMechanism, nil)?[.lockTargetState])
        try await target.write(.int(0))
        #expect(environment.log.contains("Unable to unlock the door. Device is offline.", level: .error))
        #expect(await eventually { target.value.intValue == 1 })
        #expect(environment.controller.requests(matching: "/unlock").isEmpty)
    }

    @Test func remoteUnlockAndDeviceUpdates() async throws {
        let host = try await environment.start(
            devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off"), ("input_state_dps", "on")] + Self.wiring)])], extra: ["mqttUrl": "mqtt://user:pw@broker"])
        defer { Task { await host.stop() } }
        environment.send(AccessEventType.deviceRemoteUnlock, "test-device-unique-id")
        #expect(await eventually { value(host, hubID, .lockMechanism, nil, .lockCurrentState) == 0 })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/AABBCCDDEEFF/lock") == ["false"] })
        #expect(environment.log.contains("Unlocked."))

        // The relay locks, the door opens, the REX is pressed.
        let update = uah(["configs": configs([("input_state_rly-lock_dry", "off"), ("input_state_dps", "off"), ("input_state_rex", "on")] + Self.wiring)])
        environment.send(AccessEventType.deviceUpdate, "test-device-unique-id", data: .object(update))
        #expect(await eventually { value(host, hubID, .lockMechanism, nil, .lockCurrentState) == 1 })
        #expect(await eventually { value(host, hubID, .contactSensor, "ContactSensor.DPS", .contactSensorState) == 1 })
        #expect(await eventually { value(host, hubID, .contactSensor, "ContactSensor.REX", .contactSensorState) == 0 })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/AABBCCDDEEFF/dps") == ["true"] })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/AABBCCDDEEFF/rex") == ["false"] })
        #expect(environment.log.contains("Door position sensor open."))
        #expect(environment.log.contains("Request to Exit Sensor closed."))

        // Offline: the sensors say so.
        var offline = update
        offline["is_online"] = false
        environment.send(AccessEventType.deviceUpdate, "test-device-unique-id", data: .object(offline))
        #expect(await eventually { flag(host, hubID, .contactSensor, "ContactSensor.DPS", .statusActive) == false })
    }

    static let wiring: [(String, String)] = [
        ("wiring_state_dps-neg", "on"), ("wiring_state_dps-pos", "on"), ("wiring_state_rex-neg", "on"), ("wiring_state_rex-pos", "on"),
    ]

    // MARK: Doorbells

    @Test func doorbell() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Enable.Hub.Doorbell.Trigger"], extra: ["mqttUrl": "mqtt://broker", "ringDelay": 100])
        defer { Task { await host.stop() } }
        let ring: (String) -> Void = { id in
            self.environment.send(AccessEventType.doorbellRing, "x", data: ["connected_uah_id": "test-device-unique-id", "request_id": .string(id)])
        }
        ring("ring-1")
        #expect(await eventually { flag(host, hubID, .switch, "DoorbellTrigger") == true })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/AABBCCDDEEFF/doorbell") == ["true"] })
        #expect(environment.log.contains("Doorbell ring detected."))

        // Another hub's ring, and a cancel for another ring, change nothing.
        environment.send(AccessEventType.doorbellRing, "x", data: ["connected_uah_id": "other", "request_id": "ring-x"])
        environment.send(AccessEventType.doorbellCancel, "x", data: ["remote_call_request_id": "ring-x"])
        try await Task.sleep(for: .milliseconds(80))
        #expect(flag(host, hubID, .switch, "DoorbellTrigger") == true)

        environment.send(AccessEventType.doorbellCancel, "x", data: ["remote_call_request_id": "ring-1"])
        #expect(await eventually { flag(host, hubID, .switch, "DoorbellTrigger") == false })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/AABBCCDDEEFF/doorbell") == ["true", "false"] })
        #expect(environment.log.contains("Doorbell ring cancelled."))

        // Within the ring delay (a hundred units, 3 s, so a slow runner stays inside it), the next ring is not passed on.
        ring("ring-2")
        #expect(await eventually { self.environment.log.contains("Doorbell ring suppressed") })

        // The trigger cannot be switched from HomeKit.
        let trigger = try #require(accessory(host, hubID)?.service(.switch, "DoorbellTrigger")?[.on])
        try await trigger.write(.bool(true))
        #expect(await eventually { trigger.value == .bool(true) })
    }

    @Test func doorbellOnItsOwnAccessory() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Enable.Hub.Doorbell.Trigger", "Enable.Hub.Doorbell.SeparateAccessory"], expecting: 2)
        defer { Task { await host.stop() } }
        let doorbell = try #require(accessory(host, "\(hubID).Doorbell"))
        #expect(doorbell.name == "Test Device Doorbell")
        #expect(doorbell.service(.doorbell, nil)?.isPrimary == true)
        #expect(doorbell.service(.switch, "DoorbellTrigger") != nil)
        let hub = try #require(accessory(host, hubID))
        #expect(hub.service(.doorbell, nil) == nil)
        #expect(hub.service(.lockMechanism, nil)?.isPrimary == true)
    }

    // MARK: Separate sensors, and back

    @Test func sensorsOnTheirOwnAccessories() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Enable.Hub.Sensors.SeparateAccessory"], expecting: 5)
        let dps = try #require(accessory(host, "\(hubID).ContactSensor.DPS"))
        #expect(dps.name == "Test Device Door Position Sensor")
        #expect(dps.information[.serialNumber]?.value == .string("AABBCCDDEEFF-ContactSensor.DPS"))
        #expect(dps.service(.contactSensor, "ContactSensor.DPS") != nil)
        #expect(accessory(host, hubID)?.service(.contactSensor, "ContactSensor.DPS") == nil)
        #expect(environment.log.contains("Adding Test Device Door Position Sensor to HomeKit as a separate accessory."))
        await host.stop()

        // Without the option the sensors come back to the hub and the separate accessories leave.
        let again = try await environment.start(devices: [uah()], options: [], expecting: 1)
        defer { Task { await again.stop() } }
        #expect(await eventually { again.mainBridge.server.accessories.count == 2 })
        #expect(accessory(again, "\(hubID).ContactSensor.DPS") == nil)
        #expect(accessory(again, hubID)?.service(.contactSensor, "ContactSensor.DPS") != nil)
    }

    // MARK: Names

    @Test func namesFollowTheController() async throws {
        let host = try await environment.start(devices: [uah()])
        defer { Task { await host.stop() } }
        var renamed = uah()
        renamed["alias"] = "Back Door"
        environment.send(AccessEventType.deviceUpdate, "test-device-unique-id", data: .object(renamed))
        #expect(await eventually { accessory(host, hubID)?.name == "Back Door" })
        let hub = try #require(accessory(host, hubID))
        #expect(hub.service(.lockMechanism, nil)?[.configuredName]?.value == .string("Back Door"))
        #expect(hub.service(.contactSensor, "ContactSensor.REX")?[.configuredName]?.value == .string("Back Door Request to Exit Sensor"))
        #expect(environment.log.contains("Name change detected."))
    }

    @Test func namesStayWhenSyncIsOff() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Disable.Device.SyncName"])
        defer { Task { await host.stop() } }
        var renamed = uah()
        renamed["alias"] = "Back Door"
        environment.send(AccessEventType.deviceUpdate, "test-device-unique-id", data: .object(renamed))
        try await Task.sleep(for: .milliseconds(100))
        #expect(accessory(host, hubID)?.name == "Test Device")
        #expect(environment.log.contains("Device name synchronization with HomeKit is disabled."))
    }

    // MARK: UA Gate

    static let gateDoors: [JSONValue] = [
        ["unique_id": "door-1", "name": "Main Gate", "door_position_status": "close", "door_lock_relay_status": "lock"],
        ["unique_id": "door-2", "name": "Portillon", "door_position_status": "close", "door_lock_relay_status": "lock"],
    ]

    @Test func gateServicesAndDoors() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.SideDoor.Lock.Trigger"])
        defer { Task { await host.stop() } }
        #expect(await eventually { accessory(host, gateID)?.name == "Main Gate" })
        let gate = try #require(accessory(host, gateID))
        let garage = try #require(gate.service(.garageDoorOpener, nil))
        #expect(garage[.currentDoorState]?.value.intValue == 1)
        #expect(gate.service(.lockMechanism, "Lock.Door.Side")?[.configuredName]?.value == .string("Portillon"))
        #expect(gate.service(.contactSensor, "ContactSensor.DPS.Side")?[.configuredName]?.value == .string("Portillon Door Position Sensor"))
        #expect(gate.service(.switch, "Switch.Lock.Door.Side.Trigger")?[.configuredName]?.value == .string("Portillon Lock Trigger"))
        #expect(environment.log.contains("Discovered main door: Main Gate (id=door-1), side door: Portillon (id=door-2)."))
        let hub = try #require(await environment.hub(id: gateID))
        #expect(await hub.mainDoorLocationId == "door-1")
        #expect(await hub.sideDoorLocationId == "door-2")
    }

    /// The side door on a tile of its own: its lock (primary), its trigger and its position sensor leave the gate's
    /// accessory, which keeps the gate; without the option they come back.
    @Test func gateSideDoorOnItsOwnAccessory() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.SideDoor.SeparateAccessory", "Enable.Hub.SideDoor.Lock.Trigger"])
        #expect(await eventually { accessory(host, "\(gateID).SideDoor")?.name == "Portillon" })
        let side = try #require(accessory(host, "\(gateID).SideDoor"))
        #expect(side.category == .doorLock)
        #expect(side.service(.lockMechanism, "Lock.Door.Side")?.isPrimary == true)
        #expect(side.service(.contactSensor, "ContactSensor.DPS.Side") != nil)
        #expect(side.service(.switch, "Switch.Lock.Door.Side.Trigger") != nil)
        let gate = try #require(accessory(host, gateID))
        #expect(gate.service(.garageDoorOpener, nil) != nil && gate.service(.lockMechanism, "Lock.Door.Side") == nil)
        await host.stop()

        let again = try await environment.start(devices: [ugt()], doors: Self.gateDoors)
        defer { Task { await again.stop() } }
        #expect(await eventually { accessory(again, gateID)?.service(.lockMechanism, "Lock.Door.Side") != nil })
        #expect(accessory(again, "\(gateID).SideDoor") == nil)
    }

    @Test func gateDoorsByName() async throws {
        // No port settings: the door names decide.
        let doors: [JSONValue] = [
            ["unique_id": "d-a", "name": "Side entrance", "device_groups": [[["mac": "11:22:33:44:55:66"]]]],
            ["unique_id": "d-b", "name": "Front gate", "device_groups": [[["mac": "11:22:33:44:55:66"]]]],
            ["unique_id": "d-c", "name": "Elsewhere"],
        ]
        let host = try await environment.start(devices: [ugt(["extensions": []])], doors: doors)
        defer { Task { await host.stop() } }
        let hub = try #require(await environment.hub(id: gateID))
        #expect(await hub.mainDoorLocationId == "d-b")
        #expect(await hub.sideDoorLocationId == "d-a")
    }

    @Test func gateRemoteUnlockRelocksItself() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.Door.UseLock"], extra: ["mqttUrl": "mqtt://broker"])
        defer { Task { await host.stop() } }
        let side = record(host, gateID, .lockMechanism, "Lock.Door.Side", .lockCurrentState)
        environment.send(AccessEventType.deviceRemoteUnlock, "door-2")
        #expect(await eventually { went(side, through: [0, 1]) })
        #expect(await eventually { self.environment.mqtt.connection.published(on: "unifi/access/112233445566/sidedoor/lock") == ["false", "true"] })
        #expect(environment.log.contains("Portillon unlocked."))

        let main = record(host, gateID, .lockMechanism, nil, .lockCurrentState)
        environment.send(AccessEventType.deviceRemoteUnlock, "door-1")
        #expect(await eventually { went(main, through: [0, 1]) })
    }

    @Test func gateCycle() async throws {
        // A thirty-unit cycle: 300 ms per phase, longer than the 150 ms during which events after a command are ignored.
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.GateDirectionDuration.112233445566.30"])
        defer { Task { await host.stop() } }
        let garage = try #require(accessory(host, gateID)?.service(.garageDoorOpener, nil))
        // Open lasts one phase (300 ms) before the timer moves to closing: the states are recorded as they change, so a
        // runner that stalls through the whole phase still sees it.
        let states = NIOLockedValueBox<[Int]>([])
        garage.characteristic(.currentDoorState).observe { change in
            if let state = change.newValue.intValue { states.withLockedValue { $0.append(state) } }
        }
        try await garage.characteristic(.targetDoorState).write(.int(0))
        #expect(environment.controller.requests(matching: "/location/door-1/unlock").count == 1)
        #expect(garage[.currentDoorState]?.value.intValue == 2)
        #expect(await eventually { states.withLockedValue { $0.contains(0) } })
        // The gate is open; the timer moves it to closing; the DPS confirms closed.
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "open", "lock": "locked"]])
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 3 })
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "close", "lock": "locked"]])
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 1 })
    }

    @Test func gateClosingEndsOnAClosedDPSThatIsNoChange() async throws {
        // An open that comes once closing has begun is taken for a bounce, and the DPS stays closed: the closed that
        // follows is no change, yet it ends the cycle. Long phases (1.5 s) keep the event inside closing.
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.GateDirectionDuration.112233445566.150"])
        defer { Task { await host.stop() } }
        let garage = try #require(accessory(host, gateID)?.service(.garageDoorOpener, nil))
        try await garage.characteristic(.targetDoorState).write(.int(0))
        try await garage.characteristic(.targetDoorState).write(.int(1))
        #expect(garage[.currentDoorState]?.value.intValue == 3)
        // Past the cooldown during which events after a command are ignored (later still ends it).
        try await Task.sleep(for: .milliseconds(200))
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "close", "lock": "locked"]])
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 1 })
    }

    @Test func gateCommandFailureReverts() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors)
        defer { Task { await host.stop() } }
        environment.controller.override("/location/door-1/unlock") { _ in HTTPResponse(status: 500) }
        let garage = try #require(accessory(host, gateID)?.service(.garageDoorOpener, nil))
        try await garage.characteristic(.targetDoorState).write(.int(0))
        #expect(await eventually { garage[.targetDoorState]?.value.intValue == 1 })
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 1 })
        #expect(environment.log.contains("Unable to unlock the gate.", level: .error))
    }

    @Test func gateOpenedElsewhere() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.GateDirectionDuration.6"])
        defer { Task { await host.stop() } }
        let garage = try #require(accessory(host, gateID)?.service(.garageDoorOpener, nil))
        let states = record(host, gateID, .garageDoorOpener, nil, .currentDoorState)
        // The controller's refreshes agree: the gate is open.
        environment.controller.setDevices([ugt()], doors: [
            ["unique_id": "door-1", "name": "Main Gate", "door_position_status": "open", "door_lock_relay_status": "lock"], Self.gateDoors[1],
        ])
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "open", "lock": "locked"]])
        // Opening lasts one phase (60 ms), then open.
        #expect(await eventually { went(states, through: [2, 0]) })
        try await Task.sleep(for: .milliseconds(150))
        // No timer closes it: the DPS does.
        #expect(garage[.currentDoorState]?.value.intValue == 0)
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "close", "lock": "locked"]])
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 1 })
    }

    @Test func gateLocationStatesAndRenames() async throws {
        let host = try await environment.start(devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.Door.UseLock"])
        defer { Task { await host.stop() } }
        environment.send(
            AccessEventType.deviceUpdateV2, "gate-1",
            data: ["location_states": [["location_id": "door-2", "lock": "unlocked", "dps": "open"], ["location_id": "door-1", "lock": "unlocked", "dps": "close"]]])
        #expect(await eventually { value(host, gateID, .lockMechanism, "Lock.Door.Side", .lockCurrentState) == 0 })
        #expect(await eventually { value(host, gateID, .contactSensor, "ContactSensor.DPS.Side", .contactSensorState) == 1 })
        #expect(value(host, gateID, .lockMechanism, nil, .lockCurrentState) == 0)

        environment.send(AccessEventType.locationUpdate, "door-2", data: ["id": "door-2", "name": "Wicket", "state": ["dps": "open", "lock": "unlocked"]])
        #expect(await eventually { accessory(host, gateID)?.service(.lockMechanism, "Lock.Door.Side")?[.configuredName]?.value == .string("Wicket") })
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Portail", "state": ["dps": "close", "lock": "unlocked"]])
        #expect(await eventually { accessory(host, gateID)?.name == "Portail" })
    }

    // MARK: MQTT

    @Test func mqttTopics() async throws {
        let host = try await environment.start(
            devices: [uah(["configs": configs([("input_state_rly-lock_dry", "off")] + Self.wiring)])], options: ["Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5", "Enable.Controller.Publish.Telemetry"],
            extra: ["mqttUrl": "mqtt://broker", "mqttTopic": "doors"])
        defer { Task { await host.stop() } }
        let configuration = try #require(environment.mqtt.configurations.first)
        guard case .tcp(let broker, let port) = configuration.transport else { Issue.record("not plain MQTT: \(configuration.transport)"); return }
        #expect(broker == "broker" && port == 1883 && configuration.reconnect?.firstConnection == true)
        #expect(await eventually { Set(self.environment.mqtt.connection.subscriptions.keys).isSuperset(of: ["doors/AABBCCDDEEFF/doorbell/get", "doors/AABBCCDDEEFF/dps/get", "doors/AABBCCDDEEFF/lock/get", "doors/AABBCCDDEEFF/lock/set"]) })
        environment.mqtt.connection.receive("doors/AABBCCDDEEFF/lock/get", string: "true")
        #expect(await eventually { self.environment.mqtt.connection.published(on: "doors/AABBCCDDEEFF/lock") == ["true"] })
        environment.mqtt.connection.receive("doors/AABBCCDDEEFF/dps/get", string: "TRUE")
        // Wired, but the controller reports no state: open.
        #expect(await eventually { self.environment.mqtt.connection.published(on: "doors/AABBCCDDEEFF/dps") == ["true"] })
        environment.mqtt.connection.receive("doors/AABBCCDDEEFF/lock/set", string: "false")
        #expect(await eventually { self.environment.controller.requests(matching: "/lock_rule").last?.body == #"{"interval":5,"type":"custom"}"# })
        environment.mqtt.connection.receive("doors/AABBCCDDEEFF/lock/set", string: "maybe")
        #expect(await eventually { self.environment.log.contains("MQTT: Unknown lock set message received: maybe.", level: .error) })

        environment.send(AccessEventType.deviceUpdateV2, "abc", data: ["secret": "data"], meta: ["id": "abc", "object_type": "device"])
        #expect(await eventually { self.environment.mqtt.connection.published(on: "doors/001122334455/telemetry").contains(#"{"event":"access.data.v2.device.update","event_object_id":"abc","meta":{"id":"abc","object_type":"device"}}"#) })
    }

    @Test func unsupportedBrokerScheme() async throws {
        let host = try await environment.start(devices: [uah()], extra: ["mqttUrl": "ws://user:pw@broker"])
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("Unsupported protocol: ws:. Only mqtt://, mqtts://, tcp://, and ssl:// broker URLs are supported: ws://REDACTED@broker.", level: .error))
        #expect(environment.mqtt.configurations.isEmpty)
    }

    // MARK: Removal

    @Test func devicesThatLeaveAreRemovedAfterTheDelay() async throws {
        let host = try await environment.start(devices: [uah(), ugt()], options: ["Enable.Controller.DelayDeviceRemoval.2"])
        defer { Task { await host.stop() } }
        environment.controller.setDevices([ugt()])
        _ = await environment.controllerActor()?.api.getBootstrap()
        #expect(await eventually { self.environment.log.contains("Delaying device removal for at least 2 seconds.") })
        #expect(accessory(host, hubID) != nil)
        try await Task.sleep(for: .milliseconds(100))
        _ = await environment.controllerActor()?.api.getBootstrap()
        #expect(await eventually { accessory(host, hubID) == nil })
        #expect(environment.log.contains("Removing UA Hub from HomeKit."))
        #expect(accessory(host, gateID) != nil)
    }

    /// A device back before its removal leaves the queue, however long it was gone.
    @Test func devicesThatComeBackStay() async throws {
        let host = try await environment.start(devices: [uah(), ugt()], options: ["Enable.Controller.DelayDeviceRemoval.2"])
        defer { Task { await host.stop() } }
        environment.controller.setDevices([ugt()])
        _ = await environment.controllerActor()?.api.getBootstrap()
        #expect(await eventually { self.environment.log.contains("Delaying device removal for at least 2 seconds.") })
        try await Task.sleep(for: .milliseconds(100))
        environment.controller.setDevices([uah(), ugt()])
        _ = await environment.controllerActor()?.api.getBootstrap()
        try await Task.sleep(for: .milliseconds(300))
        _ = await environment.controllerActor()?.api.getBootstrap()
        try await Task.sleep(for: .milliseconds(300))
        #expect(accessory(host, hubID) != nil)
        #expect(!environment.log.contains("Removing UA Hub from HomeKit."))
    }

    @Test func deletedDevicesLeave() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Disable.Controller.DelayDeviceRemoval"])
        defer { Task { await host.stop() } }
        environment.send(AccessEventType.deviceDelete, "test-device-unique-id")
        #expect(await eventually { accessory(host, hubID) == nil })
    }

    @Test func disabledControllers() async throws {
        let host = try await environment.start(devices: [uah()], options: ["Disable.Device.001122334455"], expecting: 0)
        defer { Task { await host.stop() } }
        #expect(await eventually { self.environment.log.contains("Disabling this UniFi Access controller in HomeKit.") })
        #expect(accessory(host, hubID) == nil)
    }

    @Test func controllersWithoutDetails() async throws {
        let host = try environment.host(settings: ["controllers": [["address": "", "username": "u", "password": "p"], ["address": "10.0.0.1"], ["address": "127.0.0.1", "username": "u", "password": "p"]]])
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("No host or IP address has been configured."))
        #expect(environment.log.contains("No UniFi Access login credentials have been configured."))
        #expect(await eventually { self.environment.log.contains("Invalid controller address: 127.0.0.1. Please provide a valid network address.", level: .error) })

        let empty = try AccessTestEnvironment().host(settings: [:])
        try await empty.start()
        await empty.stop()
    }

    // MARK: The page

    @Test func pageRequests() async throws {
        environment.discovered = [DiscoveredConsole(ip: "10.0.0.1", mac: "aa:bb:cc:00:00:01", name: "udm", model: "UDMP")]
        let host = try await environment.start(devices: [uah(), ugt()])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)

        let options = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "options", user: "admin"))
        #expect(options.json["categories"]?.arrayValue?.count == 5)

        let devices = try await plugin.handleWebRequest(
            PluginWebRequest(method: "POST", path: "devices", body: ["address": "10.0.0.1", "username": "u", "password": "p"], user: "admin"))
        let list = try #require(devices.json["devices"]?.arrayValue)
        #expect(list.count == 3)
        #expect(list[0]["host"]?["mac"] == "00:11:22:33:44:55")
        #expect(list.dropFirst().compactMap { $0["featureId"]?.stringValue } == ["112233445566", "AABBCCDDEEFF"])

        let bad = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices", body: ["address": "localhost"], user: "admin"))
        #expect(bad.json["devices"] == [])
        environment.controller.override("/api/auth/login") { _ in HTTPResponse(status: 403) }
        let refused = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices", body: ["address": "10.0.0.2", "username": "u", "password": "p"], user: "admin"))
        #expect(refused.json["error"]?.stringValue?.contains("Insufficient privileges") == true)
        // A console without UniFi Access answers its proxy's paths with its own web page.
        environment.controller.removeOverride("/api/auth/login")
        for path in ["access/info", "devices/topology4"] {
            environment.controller.override(path) { _ in HTTPResponse(status: 200, headers: [("Content-Type", "text/html")], body: Data("<!doctype html>".utf8)) }
        }
        let elsewhere = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices", body: ["address": "10.0.0.3", "username": "u", "password": "p"], user: "admin"))
        #expect(elsewhere.json["error"]?.stringValue?.contains("UniFi Access does not run on this console") == true)

        let status = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "status", body: ["address": "10.0.0.1"], user: "admin"))
        #expect(status.json["online"] == true)
        let unreachable = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "status", body: ["address": "10.0.0.9"], user: "admin"))
        #expect(unreachable.json["online"] == false)

        let discover = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "discover", user: "admin"))
        #expect(discover.json["devices"]?[0]?["ip"] == "10.0.0.1")

        let controllers = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "controllers", user: "admin"))
        #expect(controllers.json["controllers"]?[0]?["connected"] == true)
        #expect(controllers.json["controllers"]?[0]?["devices"]?.arrayValue?.count == 2)

        let missing = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "nope", user: "admin"))
        #expect(missing.status == 404)
    }

    // MARK: Fix phase B

    /// A UA Gate's location endpoint only toggles: a lock, close or off command for a door already there sends nothing.
    @Test func gateCommandsForASecuredDoorSendNothing() async throws {
        let host = try await environment.start(
            devices: [ugt()], doors: Self.gateDoors, options: ["Enable.Hub.Lock.Trigger", "Enable.Hub.SideDoor.Lock.Trigger"], extra: ["mqttUrl": "mqtt://broker"])
        defer { Task { await host.stop() } }
        let gate = try #require(accessory(host, gateID))
        let garage = try #require(gate.service(.garageDoorOpener, nil))
        let trigger = try #require(gate.service(.switch, "LockTrigger")?[.on])
        let sideTrigger = try #require(gate.service(.switch, "Switch.Lock.Door.Side.Trigger")?[.on])
        #expect(trigger.isSecurityControl && sideTrigger.isSecurityControl)
        #expect(garage[.currentDoorState]?.value.intValue == 1)
        #expect(await eventually { Set(self.environment.mqtt.connection.subscriptions.keys).contains("unifi/access/112233445566/sidedoor/lock/set") })

        try await garage.characteristic(.targetDoorState).write(.int(1))
        try await trigger.write(.bool(false))
        try await sideTrigger.write(.bool(false))
        environment.mqtt.connection.receive("unifi/access/112233445566/lock/set", string: "true")
        environment.mqtt.connection.receive("unifi/access/112233445566/sidedoor/lock/set", string: "true")
        #expect(await eventually { self.environment.log.messages(.debug).filter { $0.contains("is already locked: not triggering it.") }.count == 4 })
        #expect(environment.controller.requests(matching: "/unlock").isEmpty)
        #expect(garage[.currentDoorState]?.value.intValue == 1)
        #expect(garage[.targetDoorState]?.value.intValue == 1)

        // The gate opens elsewhere: closing it now does trigger it.
        environment.send(AccessEventType.locationUpdate, "door-1", data: ["id": "door-1", "name": "Main Gate", "state": ["dps": "open", "lock": "locked"]])
        #expect(await eventually { garage[.currentDoorState]?.value.intValue == 2 })
        try await garage.characteristic(.targetDoorState).write(.int(1))
        #expect(environment.controller.requests(matching: "/location/door-1/unlock").count == 1)
        // Unlocking still goes through.
        try await sideTrigger.write(.bool(true))
        #expect(environment.controller.requests(matching: "/location/door-2/unlock").count == 1)
    }

    /// The live test: one failed refresh (a dropped connection) ended the sync for good. It retries now.
    @Test func refreshRetriesAfterAFailure() async throws {
        environment.refreshInterval = .milliseconds(100)
        let host = try await environment.start(devices: [uah()])
        defer { Task { await host.stop() } }
        environment.controller.fail("devices/topology4", with: HTTPClientError.connectionClosed)
        #expect(await eventually { self.environment.log.contains("Unable to refresh the controller configuration. Retrying.", level: .error) })
        let failed = environment.controller.requests(matching: "devices/topology4").count
        #expect(await eventually { self.environment.controller.requests(matching: "devices/topology4").count > failed + 2 })
        environment.controller.fail("devices/topology4", with: nil)
        environment.controller.setDevices([uah(), ugt()])
        #expect(await eventually { accessory(host, gateID) != nil })
        #expect(environment.log.messages(.error).filter { $0.contains("Unable to refresh the controller configuration") }.count == 1)
        // And the refreshes go on.
        let after = environment.controller.requests(matching: "devices/topology4").count
        #expect(await eventually { self.environment.controller.requests(matching: "devices/topology4").count > after })
    }

    /// The access method switches follow the device at every refresh, not only its events.
    @Test func accessMethodsFollowRefreshes() async throws {
        let host = try await environment.start(devices: [ultra()])
        defer { Task { await host.stop() } }
        #expect(flag(host, ultraID, .switch, "AccessMethod.Face") == true)
        #expect(flag(host, ultraID, .switch, "AccessMethod.PIN") == false)
        environment.controller.setDevices([
            ultra(["configs": configs([("input_d1_button", "off"), ("input_d1_dps", "close"), ("output_d1_lock_relay", "off"), ("nfc", "yes"), ("pin_code", "yes"), ("face", "no")])])
        ])
        _ = await environment.controllerActor()?.api.getBootstrap()
        #expect(await eventually { flag(host, ultraID, .switch, "AccessMethod.Face") == false && flag(host, ultraID, .switch, "AccessMethod.PIN") == true })
    }

    /// Option values and config numbers of any size saturate instead of trapping.
    @Test func hugeNumbersSaturate() async throws {
        let huge = "99999999999999999999999"
        let host = try await environment.start(
            devices: [uah(), ugt()], options: ["Enable.Hub.LockDelayInterval.AABBCCDDEEFF.\(huge)", "Enable.Hub.GateDirectionDuration.\(huge)", "Enable.Controller.DelayDeviceRemoval.\(huge)"],
            extra: ["ringDelay": 1e300])
        defer { Task { await host.stop() } }
        let hub = try #require(await environment.hub(id: hubID))
        #expect(await hub.lockDelayInterval == AccessSettings.maximumOptionValue)
        #expect(await environment.plugin?.configuration.ringDelay == Int.max)
        environment.controller.setDevices([ugt()])
        _ = await environment.controllerActor()?.api.getBootstrap()
        #expect(await eventually { self.environment.log.contains("Delaying device removal for at least \(AccessSettings.maximumOptionValue) seconds.") })
        // Device configs with numbers: JavaScript's spelling, no trap beyond Int64.
        #expect(AccessDevice.text(.number(1e20)) == "1e+20")
        #expect(AccessDevice.text(.number(-0.0)) == "0")
    }
}
