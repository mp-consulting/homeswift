import Foundation
import Homeswift
@testable import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

/// A Control's Appliances and Functions (GLOSSARY.md, "Appliance"; docs/adr/0011-a-control-names-a-function.md): what an
/// Appliance is, which of an accessory's switches a target turns on and off, a Function named `<id>#<key>`, and an
/// Appliance beside lights in one Control: on and off with them, never dimmed.
@Suite(.timeLimit(.minutes(1)))
struct RemoteApplianceTests {
    static func relay(_ id: String = "EWeLink:relay") -> Accessory {
        let channels = (1...2).map { number in
            let channel = Service(.switch, name: "Channel \(number)", subtype: "channel\(number)", isPrimary: number == 1)
            channel.characteristic(.on).value = .bool(false)
            return channel
        }
        return Accessory(id: id, name: "Relay", category: .switch, services: channels)
    }

    static func purifier() -> Accessory {
        let purifier = Service(.airPurifier, name: "Purifier", isPrimary: true)
        purifier.characteristic(.active).value = .int(0)
        let childLock = Service(.switch, name: "Child Lock", subtype: "lock")
        childLock.characteristic(.on).value = .bool(false)
        return Accessory(id: "Dyson:purifier", name: "Purifier", category: .airPurifier, services: [purifier, childLock])
    }

    static func lamp(_ id: String, on: Bool, level: Int) -> Accessory {
        let bulb = Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(on)
        bulb[.brightness]?.value = .int(level)
        return Accessory(id: id, name: id, category: .lightbulb, services: [bulb])
    }

    static func find(_ accessories: [Accessory]) -> @Sendable (String) -> Accessory? {
        let byID = Dictionary(uniqueKeysWithValues: accessories.map { ($0.id, $0) })
        return { byID[$0] }
    }

    /// An accessory's own services, without its Accessory Information.
    static func own(_ accessory: Accessory) -> [Service] {
        accessory.services.filter { $0.type != .accessoryInformation }
    }

    static func runner(_ driven: [String], power: [String] = [], find: @escaping @Sendable (String) -> Accessory?) -> ControlRunner {
        ControlRunner(targets: ControlTargets(driven: driven, power: power, powerDelay: .milliseconds(20)),
                      writers: driven.map { DimmerWriter(lightID: $0, trustLastSet: .zero, find: find) }, find: find)
    }

    @Test func whatIsAnAppliance() {
        #expect(ControlTarget(accessory: Self.relay()).kind == .appliance)
        #expect(ControlTarget(accessory: Self.purifier()).kind == .appliance)
        let fan = Accessory(id: "fan", name: "Fan", category: .fan, services: [Service(.fanv2)])
        #expect(ControlTarget(accessory: fan).kind == .appliance)
        let valve = Accessory(id: "valve", name: "Garden", category: .sprinkler, services: [Service(.valve)])
        #expect(ControlTarget(accessory: valve).kind == .appliance)
        // A sensor, a thermostat: nothing to turn on and off.
        #expect(ControlTarget(accessory: Accessory(id: "t", name: "T", category: .thermostat, services: [Service(.thermostat)])).kind == nil)
        #expect(ControlTarget(accessory: Accessory(id: "m", name: "M", category: .sensor, services: [Service(.motionSensor)])).kind == nil)
        // A remote drives what it is given (docs/adr/0012-a-remote-drives-what-it-is-given.md): a door strike, a lock (not its
        // auto-lock switch), a garage door, an alarm; a door moves as a shutter does.
        let strike = Service(.switch)
        strike[.on]?.securityControl()
        let strikeTarget = ControlTarget(accessory: Accessory(id: "strike", name: "Strike", category: .switch, services: [strike]))
        #expect(strikeTarget.kind == .appliance && strikeTarget.isSecurity && !strikeTarget.opens)
        let lock = ControlTarget(accessory: Accessory(id: "lock", name: "Door", category: .doorLock, services: [Service(.switch, subtype: "auto"), Service(.lockMechanism)]))
        #expect(lock.kind == .appliance && lock.isSecurity && lock.opens && lock.applianceSwitches.map(\.characteristic.type.uuid) == [CharacteristicType.lockTargetState.uuid])
        let garage = ControlTarget(accessory: Accessory(id: "garage", name: "Garage", category: .garageDoorOpener, services: [Service(.garageDoorOpener)]))
        #expect(garage.kind == .appliance && garage.isSecurity && garage.opens)
        let alarm = ControlTarget(accessory: Accessory(id: "alarm", name: "Alarm", category: .securitySystem, services: [Service(.securitySystem)]))
        #expect(alarm.kind == .appliance && alarm.isSecurity && !alarm.opens)
        #expect(ControlTarget(accessory: Accessory(id: "door", name: "Door", category: .door, services: [Service(.door)])).kind == .shutter)
        #expect(!Self.relay().services.contains { ControlTarget(accessory: Self.relay(), services: [$0]).isSecurity })
        // A fan with a light is a light, which it dims.
        let fanLight = Accessory(id: "fanlight", name: "Ceiling Fan", category: .fan, services: [Service(.fanv2, isPrimary: true), Service(.lightbulb)])
        #expect(ControlTarget(accessory: fanLight).kind == .light)
    }

    @Test func aFunctionIsNamedByItsSeparateFunctionsKey() throws {
        let relay = Self.relay()
        #expect(Separation.functions(of: relay).map(\.key) == ["channel1", "channel2"])
        // The others' keys are their separated accessories'.
        #expect(try #require(Separation.of(relay)).parts.map(\.id) == ["EWeLink:relay:channel2"])
        let find = Self.find([relay])
        let second = try #require(ControlTarget.resolve("EWeLink:relay#channel2", find: find))
        #expect(second.function == "channel2" && second.applianceSwitches.count == 1 && second.kind == .appliance)
        #expect(ControlTarget.resolve("EWeLink:relay", find: find)?.applianceSwitches.count == 2)
        // A separated Function's id still names it once the relay is joined again (Separate Functions turned off in
        // config.json, say, where the Controls are not renamed).
        #expect(ControlTarget.resolve("EWeLink:relay:channel2", find: find)?.function == "channel2")
        #expect(ControlTarget.resolve("EWeLink:relay:channel3", find: find) == nil)
        // A key it has no Function of, or an accessory not on the bridge: nothing (the Control skips it).
        #expect(ControlTarget.resolve("EWeLink:relay#channel3", find: find) == nil)
        #expect(ControlTarget.resolve("EWeLink:gone#channel1", find: find) == nil)
        // An id with a # of its own is found whole first.
        let odd = Self.relay("Shelly:SHSW-1#A1#1")
        #expect(ControlTarget.resolve("Shelly:SHSW-1#A1#1", find: Self.find([odd]))?.function == nil)
        // The main Function's key takes -main when another has it.
        let twins = Accessory(id: "twins", name: "Twins", category: .switch, services: [
            Service(.switch, name: "One", isPrimary: true), Service(.switch, name: "Two", subtype: "Switch"),
        ])
        #expect(Separation.functions(of: twins).map(\.key) == ["switch-main", "switch"])
    }

    @Test func aWholeAccessoryTurnsItsMainFunctionOrAllItsSwitches() async throws {
        let relay = Self.relay(), purifier = Self.purifier()
        let find = Self.find([relay, purifier])
        // A relay made only of switches: both channels.
        let channels = Self.runner([relay.id], find: find)
        await channels.switchTo(true, step: 5)
        #expect(Self.own(relay).allSatisfy { $0[.on]?.value.boolValue == true })
        await channels.apply(.toggle, step: 5)
        #expect(Self.own(relay).allSatisfy { $0[.on]?.value.boolValue == false })
        // An air purifier: its Active, not its child lock.
        let air = Self.runner([purifier.id], find: find)
        await air.apply(.toggle, step: 5)
        #expect(Self.own(purifier)[0][.active]?.value.intValue == 1)
        #expect(Self.own(purifier)[1][.on]?.value.boolValue == false)
        // A Function: only that channel.
        let second = Self.runner(["EWeLink:relay#channel2"], find: find)
        await second.switchTo(true, step: 5)
        #expect(Self.own(relay)[0][.on]?.value.boolValue == false && Self.own(relay)[1][.on]?.value.boolValue == true)
    }

    @Test func anApplianceBesideLightsTurnsWithThemButIsNeverDimmed() async throws {
        let relay = Self.relay(), lamp = Self.lamp("Lamp", on: false, level: 50)
        let find = Self.find([relay, lamp])
        let runner = Self.runner([lamp.id, "EWeLink:relay#channel1"], find: find)
        let bulb = Self.own(lamp)[0], channel = Self.own(relay)[0]
        // All the same way: both on, then both off.
        await runner.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && channel[.on]?.value.boolValue == true)
        await runner.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == false && channel[.on]?.value.boolValue == false)
        // A Wheel's notches brighten the lamp; the channel stays as it is.
        await runner.apply(.step(2), step: 5)
        #expect(bulb[.on]?.value.boolValue == true && channel[.on]?.value.boolValue == false)
        // A hold starts from the lamp's level, not the channel's.
        await runner.hold(step: 5, direction: .alternate, for: ControlRunner.holdInterval)
        try await Task.sleep(for: ControlRunner.holdInterval * 2)
        #expect(channel[.on]?.value.boolValue == false)
    }

    @Test func aRemoteOpensTheGarageUnlocksAndArms() async throws {
        let opener = Service(.garageDoorOpener, isPrimary: true)
        opener[.targetDoorState]?.value = .int(1)
        opener[.currentDoorState]?.value = .int(1)
        let garage = Accessory(id: "garage", name: "Garage", category: .garageDoorOpener, services: [opener])
        let lockService = Service(.lockMechanism, isPrimary: true)
        lockService[.lockTargetState]?.value = .int(1)
        lockService[.lockCurrentState]?.value = .int(1)
        let lock = Accessory(id: "lock", name: "Front Door", category: .doorLock, services: [lockService])
        let alarmService = Service(.securitySystem, isPrimary: true)
        alarmService[.securitySystemTargetState]?.value = .int(3)
        alarmService[.securitySystemCurrentState]?.value = .int(3)
        let alarm = Accessory(id: "alarm", name: "Alarm", category: .securitySystem, services: [alarmService])
        let find = Self.find([garage, lock, alarm])
        // A press opens a closed garage door, and once it is open the next closes it.
        let door = Self.runner([garage.id], find: find)
        await door.apply(.toggle, step: 5)
        #expect(opener[.targetDoorState]?.value.intValue == 0)
        opener[.currentDoorState]?.value = .int(0)
        let later = Self.runner([garage.id], find: find)
        await later.apply(.toggle, step: 5)
        #expect(opener[.targetDoorState]?.value.intValue == 1)
        // Opened by its wall button, the plugin telling only its current state: a press closes it, by what it is.
        opener[.currentDoorState]?.value = .int(0)
        let wrote = NIOLockedValueBox<[Int]>([])
        opener[.targetDoorState]?.onWrite { value in wrote.withLockedValue { $0.append(value.intValue ?? -1) } }
        await Self.runner([garage.id], find: find).apply(.toggle, step: 5)
        #expect(wrote.withLockedValue { $0 } == [1])
        // On is unlocked, as on is open.
        await Self.runner([lock.id], find: find).switchTo(true, step: 5)
        #expect(lockService[.lockTargetState]?.value.intValue == 0)
        // An alarm arms Away and disarms.
        let arming = Self.runner([alarm.id], find: find)
        await arming.apply(.toggle, step: 5)
        #expect(alarmService[.securitySystemTargetState]?.value.intValue == 1)
        alarmService[.securitySystemCurrentState]?.value = .int(1)
        await arming.apply(.toggle, step: 5)
        #expect(alarmService[.securitySystemTargetState]?.value.intValue == 3)
    }

    @Test func anApplianceGoesTheWayOfThePower() async throws {
        let relay = Self.relay(), lamp = Self.lamp("Lamp", on: true, level: 50)
        let fan = Service(.fanv2, name: "Fan", isPrimary: true)
        fan.characteristic(.active).value = .int(0)
        let fanAccessory = Accessory(id: "Fan", name: "Fan", category: .fan, services: [fan])
        let find = Self.find([relay, lamp, fanAccessory])
        // Channel 1 powers the lamp; the fan is a target beside it.
        let runner = Self.runner([lamp.id, fanAccessory.id], power: ["EWeLink:relay#channel1"], find: find)
        await runner.apply(.toggle, step: 5)
        #expect(Self.own(relay)[0][.on]?.value.boolValue == true && fan[.active]?.value.intValue == 1)
        #expect(Self.own(relay)[1][.on]?.value.boolValue == false)
        await runner.switchTo(false, step: 5)
        #expect(Self.own(relay)[0][.on]?.value.boolValue == false && fan[.active]?.value.intValue == 0)
    }

    @Test func controlsAreCheckedAndRenamedWithSeparateFunctions() {
        // A target is never also its Control's power.
        let both = RemoteControl(part: "b1", gesture: .press, action: .toggle, targets: ["EWeLink:relay#channel1"], power: ["EWeLink:relay#channel1"])
        #expect(RemoteControl.problem(in: [both]) != nil)
        let apart = RemoteControl(part: "b1", gesture: .press, action: .toggle, targets: ["EWeLink:relay#channel2"], power: ["EWeLink:relay#channel1"])
        #expect(RemoteControl.problem(in: [apart]) == nil)
        // Separated, channel 2 is an accessory of its own; joined, a Function again. Channel 1 stays on the device.
        let separated = RemoteControl.rewritten([apart], device: "EWeLink:relay", keys: ["channel2"], separated: true)
        #expect(separated[0].targets == ["EWeLink:relay:channel2"] && separated[0].power == ["EWeLink:relay#channel1"])
        #expect(RemoteControl.rewritten(separated, device: "EWeLink:relay", keys: ["channel2"], separated: false) == [apart])
    }
}
