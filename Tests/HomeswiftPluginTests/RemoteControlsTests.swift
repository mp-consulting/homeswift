import Foundation
import Homeswift
@testable import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

/// A Remote's Controls run by the bridge (`RemoteControls`): from the presses HomeKit gets, or from the moments a plugin
/// reports, with the Remote as the Change Source; kept as a live Accessory Setting and checked before they are saved.
@Suite(.timeLimit(.minutes(1)))
struct RemoteControlsTests {
    static func configuration(_ controls: String, declares: Bool = false) throws -> HomeswiftConfiguration {
        try HomeswiftConfiguration.decode(Data("""
            { "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Home", "lamps": ["lamp"], "remotes": ["remote"],
              "declaresRemotes": \(declares), "brightness": 50, "_accessories": { "remote": { "controls": \(controls) } } }] }
            """.utf8))
    }

    static func lamp(_ host: PluginHost) throws -> Service {
        try #require(host.mainBridge.server.accessories.first { $0.id == "Recording:lamp" }?.services.first { $0.type == .lightbulb })
    }

    @Test func aPressHomeKitGetsRunsItsButtonsControl() async throws {
        let environment = TestEnvironment()
        let host = try PluginHost(configuration: try Self.configuration("""
            [{ "part": "b1", "gesture": "press", "action": "toggle", "targets": ["Recording:lamp"] },
             { "part": "b1", "gesture": "hold", "action": "dim", "direction": "up", "targets": ["Recording:lamp"], "step": 5 }]
            """), registry: environment.registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let lamp = try Self.lamp(host)
        let sources = NIOLockedValueBox<[ChangeSource]>([])
        let observation = host.observeChanges { _, characteristic, _ in
            if characteristic.type.uuid == CharacteristicType.on.uuid { sources.withLockedValue { $0.append(ChangeSource.resolved) } }
        }
        defer { observation.cancel() }
        let plugin = try #require(environment.createdPlugins.first)
        #expect(host.remote(of: "Recording:remote")?.layout.parts.map(\.id) == ["b1", "b2"])
        // A single press toggles the lamp on, the Remote and its Button the change's source.
        await plugin.press("remote", "b1", HAPConstants.ProgrammableSwitchEvent.singlePress)
        #expect(await eventually { lamp[.on]?.value.boolValue == true })
        #expect(sources.withLockedValue { $0 }.contains(.remote("remote · remote b1")))
        // HomeKit's long press, whose end never comes: a timed hold, its steps (`timedHold` / `holdInterval`, 6 of 5 %)
        // brightening from 50 %, then stopping on its own however slowly they come.
        await plugin.press("remote", "b1", HAPConstants.ProgrammableSwitchEvent.longPress)
        let steps = Int(RemoteControls.timedHold / ControlRunner.holdInterval)
        #expect(await eventually { lamp[.brightness]?.value.intValue == 50 + steps * 5 })
        try await Task.sleep(for: ControlRunner.holdInterval * 3)
        #expect(lamp[.brightness]?.value.intValue == 50 + steps * 5)
        // A Button without a Control does nothing.
        await plugin.press("remote", "b2", HAPConstants.ProgrammableSwitchEvent.singlePress)
        await host.stop()
    }

    @Test func aPluginsMomentsRunTheControls() async throws {
        let environment = TestEnvironment()
        let host = try PluginHost(configuration: try Self.configuration("""
            [{ "part": "b1", "gesture": "press", "action": "on", "targets": ["Recording:lamp"] },
             { "part": "b1", "gesture": "hold", "action": "dim", "direction": "down", "targets": ["Recording:lamp"] },
             { "part": "wheel", "gesture": "turn", "action": "step", "targets": ["Recording:lamp"], "step": 10, "reversed": true }]
            """, declares: true), registry: environment.registry, storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let lamp = try Self.lamp(host)
        let plugin = try #require(environment.createdPlugins.first)
        let context = try #require(host.instances.first?.context)
        // Declared as reporting its moments: HomeKit's press is the plugin's to send, not one more moment.
        await plugin.press("remote", "b1", HAPConstants.ProgrammableSwitchEvent.singlePress)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lamp[.on]?.value.boolValue != true)
        context.remoteMoment(.press, part: "b1", of: "Recording:remote")
        #expect(await eventually { lamp[.on]?.value.boolValue == true })
        // The Wheel, reversed: turned up two notches dims 20 %.
        context.remoteMoment(.turned(2), part: "wheel", of: "Recording:remote")
        #expect(await eventually { lamp[.brightness]?.value.intValue == 30 })
        // Held, it dims until let go.
        context.remoteMoment(.holdStart, part: "b1", of: "Recording:remote")
        #expect(await eventually { (lamp[.brightness]?.value.intValue ?? 100) <= 20 })
        context.remoteMoment(.holdEnd, part: "b1", of: "Recording:remote")
        try await Task.sleep(for: ControlRunner.holdInterval * 2)
        let released = lamp[.brightness]?.value.intValue
        try await Task.sleep(for: ControlRunner.holdInterval * 3)
        #expect(lamp[.brightness]?.value.intValue == released)
        await host.stop()
    }

    /// Controls apply without reloading the plugin, and are checked before they are kept.
    @Test func controlsApplyLiveAndAreChecked() async throws {
        let environment = TestEnvironment()
        let host = try PluginHost(configuration: try Self.configuration("[]"), registry: environment.registry, storageDirectory: environment.directory,
                                  options: environment.options)
        try await host.start()
        let report = await host.apply(try Self.configuration(#"[{ "part": "b1", "gesture": "double", "action": "off", "targets": ["Recording:lamp"] }]"#))
        #expect(report == PluginHost.ReloadReport())
        #expect(environment.createdPlugins.count == 1)
        #expect(host.remote(of: "Recording:remote")?.controls == [RemoteControl(part: "b1", gesture: .double, action: .off, targets: ["Recording:lamp"])])
        await host.stop()
        #expect(throws: ConfigurationError.self) { try Self.configuration(#"{ "part": "b1" }"#) }
        // One Control the bridge cannot read is left out; the others run.
        let mixed = try Self.configuration(#"[{ "part": "b1", "gesture": "press", "action": "blink" }, { "part": "b2", "gesture": "press", "action": "on", "targets": ["Recording:lamp"] }]"#)
        #expect(mixed.platforms.first?.accessorySettings["remote"]?.controls.map(\.part) == ["b2"])

        let lamp = RemoteControl(part: "b1", gesture: .press, action: .toggle, targets: ["Recording:lamp"])
        #expect(RemoteControl.problem(in: [lamp]) == nil)
        #expect(RemoteControl.problem(in: [lamp, lamp]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .press, action: .dim, targets: ["x"])]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .press, action: .scene)]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .press, action: .toggle)]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .turn, action: .step, targets: ["x"], step: 40)]) != nil)
        // A long press and a hold are the same press.
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .long, action: .scene, scenes: ["s"]),
                                           RemoteControl(part: "b1", gesture: .hold, action: .dim, targets: ["x"])]) != nil)
    }

    /// A press runs its Scenes beside what it does to its targets; a Control that only runs Scenes drives nothing. A
    /// Control saved before 0.31 named one `scene`.
    @Test func aPressRunsItsScenesBesideItsAction() async throws {
        let bulb = Service(.lightbulb, optional: [.brightness], isPrimary: true)
        bulb[.on]?.value = .bool(false)
        let lamp = Accessory(id: "lamp", name: "Lamp", category: .lightbulb, services: [bulb])
        let ran = NIOLockedValueBox<[String]>([])
        let controls = [
            RemoteControl(part: "b1", gesture: .press, action: .on, targets: ["lamp"], scenes: ["evening", "music"]),
            RemoteControl(part: "b1", gesture: .double, action: .scene, scenes: ["night"]),
        ]
        let state = RemoteState(name: "Remote", layout: RemoteLayout(parts: [RemotePart(id: "b1", kind: .button, name: nil, services: ["b1"])]),
                                isDeclared: true, controls: controls)
        let runner = RemoteControls(find: { $0 == "lamp" ? lamp : nil }, remote: { _ in state },
                                    scenes: { HomeScenes(run: { id in ran.withLockedValue { $0.append(id) } }) }, logger: Logger(label: "test"))
        runner.moment(.press, part: "b1", of: "remote")
        #expect(await eventually { bulb[.on]?.value.boolValue == true && Set(ran.withLockedValue { $0 }) == ["evening", "music"] })
        runner.moment(.doublePress, part: "b1", of: "remote")
        #expect(await eventually { ran.withLockedValue { $0 }.contains("night") })

        // Read as saved before: one scene.
        let old = try #require(RemoteControl.list(from: try JSONValue(data: Data(#"[{"part":"b1","gesture":"long","action":"scene","scene":"s"}]"#.utf8))))
        #expect(old.first?.scenes == ["s"])
        #expect(RemoteControl.json(old) == (try JSONValue(data: Data(#"[{"part":"b1","gesture":"long","action":"scene","scenes":["s"]}]"#.utf8))))
        // Scenes need a press; a scene-only Control drives nothing.
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .hold, action: .dim, targets: ["lamp"], scenes: ["s"])]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .press, action: .scene, targets: ["lamp"], scenes: ["s"])]) != nil)
        #expect(RemoteControl.problem(in: [RemoteControl(part: "b1", gesture: .press, action: .toggle, targets: ["lamp"], scenes: ["s"])]) == nil)
        await runner.stop()
    }

    /// A Control drives lights and shutters, and turns the rest on and off: a lock and a security control too
    /// (docs/adr/0012-a-remote-drives-what-it-is-given.md). Only a switch or an outlet powers lights.
    @Test func drivesWhatItIsGiven() {
        let lock = Accessory(id: "lock", name: "Door", category: .doorLock, services: [Service(.lockMechanism)])
        let blind = Accessory(id: "blind", name: "Blind", category: .windowCovering, services: [Service(.windowCovering)])
        let bulb = Accessory(id: "bulb", name: "Bulb", category: .lightbulb, services: [Service(.lightbulb)])
        #expect(ControlTarget(accessory: lock).kind == .appliance)
        #expect(ControlTarget(accessory: blind).kind == .shutter)
        #expect(ControlTarget(accessory: bulb).kind == .light)
        #expect((ControlTarget(accessory: lock).powerSwitch == nil))
        let strike = Service(.switch)
        strike[.on]?.securityControl()
        #expect((ControlTarget(accessory: Accessory(id: "strike", name: "Door strike", category: .switch, services: [strike])).powerSwitch != nil))
        let secureLight = Service(.lightbulb)
        secureLight[.on]?.securityControl()
        #expect(ControlTarget(accessory: Accessory(id: "gate", name: "Gate light", category: .lightbulb, services: [secureLight])).kind == .light)
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
