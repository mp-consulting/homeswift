import Foundation
import Homeswift
@testable import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

/// How a Remote's Controls drive their targets (`DimmerWriter`, `ControlRunner`): one write at a time, steps from what was
/// set rather than a late report, several lights together, their Power Switches, shutters, and a hold.
@Suite(.timeLimit(.minutes(1)))
struct RemoteDimmerTests {
    @Test func dimsWithinTheLightsRange() {
        #expect(DimmerWriter.target(current: 50, change: 10, isOn: true) == 60)
        #expect(DimmerWriter.target(current: 95, change: 10, isOn: true) == 100)
        #expect(DimmerWriter.target(current: 30, change: -50, isOn: true) == 1)
        #expect(DimmerWriter.target(current: 1, change: -5, isOn: true) == 0)
        #expect(DimmerWriter.target(current: 80, change: 15, isOn: false) == 15)
        #expect(DimmerWriter.target(current: 80, change: -5, isOn: false) == 0)
    }

    @Test func writesTheLightThroughItsCharacteristics() async throws {
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(true)
        bulb[.brightness]?.value = .int(40)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.step(3), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.step(-20), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 1 && bulb[.on]?.value.boolValue == true)
        await writer.apply(.step(-1), step: 5)
        #expect(bulb[.on]?.value.boolValue == false)
        // The button turns it back on at the level it had before the wheel took it to the floor, not at 1 %.
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == false && bulb[.brightness]?.value.intValue == 55)
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 55)
    }

    @Test func stepsFromWhatItSetNotFromALateReport() async throws {
        // Govee's cloud reports a level from before the last writes, late: the next notch steps from what the wheel set.
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(true)
        bulb[.brightness]?.value = .int(40)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.step(1), step: 5)
        bulb[.brightness]?.value = .int(20)   // the late report
        await writer.apply(.step(1), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 50)
        // Once the moment has passed, the light's own value counts again (another app may have changed it).
        let later = DimmerWriter(lightID: lamp.id, trustLastSet: .zero) { $0 == lamp.id ? lamp : nil }
        await later.apply(.step(1), step: 5)
        bulb[.brightness]?.value = .int(20)
        await later.apply(.step(1), step: 5)
        #expect(bulb[.brightness]?.value.intValue == 25)
    }

    static func lamp(_ id: String, on: Bool, level: Int) -> Accessory {
        let bulb = Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(on)
        bulb[.brightness]?.value = .int(level)
        return Accessory(id: id, name: id, category: .lightbulb, services: [bulb])
    }

    static func bulb(_ accessory: Accessory) -> Service { accessory.services.first { $0.type == .lightbulb }! }

    static func channel(_ accessories: [Accessory], power: [String] = []) -> ControlRunner {
        let byID = Dictionary(uniqueKeysWithValues: accessories.map { ($0.id, $0) })
        let find: @Sendable (String) -> Accessory? = { byID[$0] }
        let lights = accessories.filter { [.lightbulb, .windowCovering].contains($0.category) }.map(\.id)
        return ControlRunner(targets: ControlTargets(lights: lights, power: power, powerDelay: .milliseconds(20)),
                             writers: lights.map { DimmerWriter(lightID: $0, find: find) }, find: find)
    }

    @Test func aChannelDimsItsLightsTogetherAndSwitchesThemTheSameWay() async throws {
        let a = Self.lamp("A", on: true, level: 40), b = Self.lamp("B", on: false, level: 70)
        let channel = Self.channel([a, b])
        await channel.apply(.step(2), step: 5)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 50)
        #expect(Self.bulb(b)[.on]?.value.boolValue == true && Self.bulb(b)[.brightness]?.value.intValue == 10)
        // Both on: the button switches both off; then both on.
        await channel.apply(.toggle, step: 5)
        #expect(Self.bulb(a)[.on]?.value.boolValue == false && Self.bulb(b)[.on]?.value.boolValue == false)
        await channel.apply(.toggle, step: 5)
        #expect(Self.bulb(a)[.on]?.value.boolValue == true && Self.bulb(b)[.on]?.value.boolValue == true)
    }

    @Test func aChannelSwitchesThePowerOfItsLights() async throws {
        let relay = Service(.switch, name: "Relay", isPrimary: true)
        relay.characteristic(.on).value = .bool(false)
        let power = Accessory(id: "EWeLink:relay", name: "Relay", category: .switch, services: [relay])
        // A second relay, an outlet, switched with it.
        let socket = Service(.outlet, name: "Socket", isPrimary: true)
        socket.characteristic(.on).value = .bool(false)
        let second = Accessory(id: "EWeLink:socket", name: "Socket", category: .outlet, services: [socket])
        let a = Self.lamp("A", on: true, level: 30), b = Self.lamp("B", on: true, level: 30)
        let channel = Self.channel([power, second, a, b], power: [power.id, second.id])
        // Turning up with the power off: on first, then, once the lights are back, the notches.
        await channel.apply(.step(2), step: 5)
        #expect(relay[.on]?.value.boolValue == true && socket[.on]?.value.boolValue == true)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 40 && Self.bulb(b)[.on]?.value.boolValue == true)
        // Down past the floor: the power goes off, the lights stay on (they come back with it).
        await channel.apply(.step(-20), step: 5)
        #expect(Self.bulb(a)[.brightness]?.value.intValue == 1 && relay[.on]?.value.boolValue == true)
        await channel.apply(.step(-1), step: 5)
        #expect(relay[.on]?.value.boolValue == false && socket[.on]?.value.boolValue == false && Self.bulb(a)[.on]?.value.boolValue == true)
        // Turning down with the power off does nothing; the button switches it on, the lights back at their level.
        await channel.apply(.step(-1), step: 5)
        #expect(relay[.on]?.value.boolValue == false)
        await channel.apply(.toggle, step: 5)
        #expect(relay[.on]?.value.boolValue == true && Self.bulb(a)[.brightness]?.value.intValue == 40)
        await channel.apply(.toggle, step: 5)
        #expect(relay[.on]?.value.boolValue == false)
    }

    /// A shutter on a channel: a notch moves its Target Position a step from where the wheel last sent it; the button
    /// stops it while it moves, else opens it, or closes it when more than half open.
    @Test func aChannelMovesItsShuttersPrecisely() async throws {
        let covering = Service(.windowCovering, name: "Shutter", optional: [.holdPosition], isPrimary: true)
        covering[.targetPosition]?.value = .int(40)
        covering[.currentPosition]?.value = .int(40)
        covering[.positionState]?.value = .int(2)
        let shutter = Accessory(id: "Somfy:1", name: "Shutter", category: .windowCovering, services: [covering])
        let channel = Self.channel([shutter])
        await channel.apply(.step(3), step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 55)
        await channel.apply(.step(-20), step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 0)
        // Still, closed: the button opens it; moving, it stops.
        await channel.apply(.toggle, step: 5)
        #expect(covering[.targetPosition]?.value.intValue == 100)
        covering[.positionState]?.value = .int(1)
        await channel.apply(.toggle, step: 5)
        #expect(covering[.holdPosition]?.value.boolValue == true && covering[.targetPosition]?.value.intValue == 100)
    }

    /// A held button dims a step at a time until it is let go: up or down as set, or each hold the other way.
    @Test func aHeldButtonDimsUntilLetGo() async throws {
        let lamp = Self.lamp("A", on: true, level: 30)
        let channel = Self.channel([lamp])
        let level: @Sendable () -> Int = { Self.bulb(lamp)[.brightness]?.value.intValue ?? 0 }
        await channel.hold(step: 5, direction: .up)
        #expect(await eventually { level() >= 40 })
        await channel.release()
        let stopped = level()
        try await Task.sleep(for: .milliseconds(700))
        #expect(level() == stopped)
        await channel.hold(step: 5, direction: .down)
        #expect(await eventually { level() < stopped })
        await channel.release()
        // Alternating: the hold after a hold goes the other way (the last was down: up now), however long after.
        let before = level()
        await channel.hold(step: 5, direction: .alternate)
        #expect(await eventually { level() > before })
        await channel.release()
        // Never against a limit: at full, the next hold dims although the last one brightened.
        try await Task.sleep(for: .seconds(3.1))   // past the writer's trust in its own last level
        Self.bulb(lamp)[.brightness]?.value = .int(100)
        await channel.hold(step: 5, direction: .alternate)
        #expect(await eventually { level() < 100 })
        await channel.release()
    }

    @Test func turnsOnAtFullALightLeftAtTheFloor() async throws {
        // Dimmed to 1 % by something else: the writer knows no level before, so full.
        let bulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        bulb.characteristic(.on).value = .bool(false)
        bulb[.brightness]?.value = .int(1)
        let lamp = Accessory(id: "Other:lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let writer = DimmerWriter(lightID: lamp.id) { $0 == lamp.id ? lamp : nil }
        await writer.apply(.toggle, step: 5)
        #expect(bulb[.on]?.value.boolValue == true && bulb[.brightness]?.value.intValue == 100)
    }
}

/// A ceiling, not a wait: it returns as soon as the condition holds.
private func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
