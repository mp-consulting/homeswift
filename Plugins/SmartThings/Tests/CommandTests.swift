import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

/// HomeKit writes and the bodies they send (docs/clean-room/SmartThings.md, 15.8).
@Suite(.timeLimit(.minutes(1)))
struct CommandTests {
    let environment = TestEnvironment()

    func lastBody(_ deviceID: String) -> JSONValue? { environment.cloud.sent("POST", "/v1/devices/\(deviceID)/commands").last?.body }

    func commands(_ list: [(String, String, String, [JSONValue])]) -> JSONValue {
        ["commands": .array(list.map { ["component": .string($0.0), "capability": .string($0.1), "command": .string($0.2), "arguments": .array($0.3)] })]
    }

    @Test func writesSendTheSpecsBodies() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory(Fixture.strip) != nil && host.accessory(Fixture.lamp) != nil })
        let lamp = try #require(host.accessory(Fixture.lamp)?.service(.lightbulb))

        try await write(lamp[.brightness], .int(40))
        #expect(lastBody(Fixture.lamp) == commands([("main", "switchLevel", "setLevel", [40])]))
        // Hue and saturation together: one setColor (section 7.3.2).
        async let hue: Void = write(lamp[.hue], .double(120))
        async let saturation: Void = write(lamp[.saturation], .double(50))
        _ = try await (hue, saturation)
        #expect(lastBody(Fixture.lamp) == commands([("main", "colorControl", "setColor", [["hue": 33, "saturation": 50]])]))
        try await write(lamp[.colorTemperature], .int(250))
        #expect(lastBody(Fixture.lamp) == commands([("main", "colorTemperature", "setColorTemperature", [4000])]))
        // Brightness 0 is an off.
        try await write(lamp[.brightness], .int(0))
        #expect(lastBody(Fixture.lamp) == commands([("main", "switch", "off", [])]))

        let ac = try #require(host.accessory(Fixture.airConditioner)?.service(subtype: "main/thermostat"))
        try await write(ac[.targetHeatingCoolingState], .int(2))
        #expect(lastBody(Fixture.airConditioner) == commands([("main", "switch", "on", []), ("main", "airConditionerMode", "setAirConditionerMode", ["cool"])]))
        try await write(ac[.targetTemperature], .double(23))
        #expect(lastBody(Fixture.airConditioner) == commands([("main", "thermostatCoolingSetpoint", "setCoolingSetpoint", [23])]))

        let blind = try #require(host.accessory(Fixture.shade)?.service(.windowCovering))
        try await write(blind[.targetPosition], .int(100))
        #expect(lastBody(Fixture.shade) == commands([("main", "windowShade", "open", [])]))
        try await write(blind[.targetPosition], .int(35))
        #expect(lastBody(Fixture.shade) == commands([("main", "windowShadeLevel", "setShadeLevel", [35])]))

        let lock = try #require(host.accessory(Fixture.lock)?.service(.lockMechanism))
        try await write(lock[.lockTargetState], .int(1))
        #expect(lastBody(Fixture.lock) == commands([("main", "lock", "lock", [])]))

        let alarm = try #require(host.accessory(Fixture.security)?.service(.securitySystem))
        try await write(alarm[.securitySystemTargetState], .int(1))
        #expect(lastBody(Fixture.security) == commands([("main", "securitySystem", "armAway", [false])]))
        #expect(alarm[.securitySystemCurrentState]?.value.intValue == 1)

        let outlet = try #require(host.accessory(Fixture.strip)?.service(subtype: "outlet2/switch"))
        try await write(outlet[.on], .bool(true))
        #expect(lastBody(Fixture.strip) == commands([("outlet2", "switch", "on", [])]))
    }

    @Test func aWasherStartsWithSetMachineState() async throws {
        let status = DeviceStatus(status: Fixture.json(#"{ "components": { "main": { "remoteControlStatus": { "remoteControlEnabled": { "value": "true" } }, "washerOperatingState": { "machineState": { "value": "stop" }, "supportedMachineStates": { "value": ["stop", "run", "pause"] } } } } }"#))
        let device = try #require(SmartThingsDevice(Fixture.item("w", "Washer", components: [("main", [("remoteControlStatus", .null), ("washerOperatingState", .null)])])))
        let sent = SentCommands()
        let binding = try #require(TestBuild.binding(device, status: status, sent: sent))
        let start = try #require(binding.accessory.service(subtype: "main/switch.start"))
        try await write(start[.on], .bool(true))
        #expect(sent.all.last == [DeviceCommand("main", "washerOperatingState", "setMachineState", ["run"])])
        #expect(binding.accessory.service(subtype: "main/occupancy.running")?[.occupancyDetected]?.value.intValue == 1)
        // Remote control off: the write is refused, nothing sent.
        binding.box.setOptimistic([("main", "remoteControlStatus", "remoteControlEnabled", "false")], at: Date())
        await #expect(throws: HAPStatusError.self) { try await write(start[.on], .bool(false)) }
        #expect(sent.all.count == 1)
    }

    @Test func aReadOnlyDeviceRefusesWrites() async throws {
        var item = Fixture.item("ro", "Shared Plug", components: [("main", [("switch", Fixture.json(#"{ "switch": { "value": "off" } }"#))])])
        item = .object((item.objectValue ?? [:]).merging(["allowed": ["w:devices"]]) { $1 })
        let device = try #require(SmartThingsDevice(item))
        #expect(!device.isControllable)
        let box = StatusBox(DeviceStatus(listed: item))
        let timing = SmartThingsTiming(scale: 0.001)
        let env = BindingEnvironment(deviceID: "ro", timing: timing, logger: testLogger, now: Date.init, send: { _, _ in }, controllable: false,
                                     sliders: LatestCallGuard(delay: timing.seconds(0.3)))
        let writer = Writer(box: box, env: env)
        await #expect(throws: HAPStatusError(.insufficientPrivileges)) { try await writer.send([DeviceCommand("main", "switch", "on")]) }
    }


    /// A slider's drag sends where it ends, not every step: a device has 12 requests a minute (section 6.1).
    @Test func aSliderDragSendsOnlyWhereItEnds() async throws {
        let device = try #require(SmartThingsDevice(Fixture.item("l", "Lamp", components: [("main", [("switch", .null), ("switchLevel", .null)])])))
        let sent = SentCommands()
        let binding = try #require(TestBuild.binding(device, status: DeviceStatus(), sent: sent))
        let light = try #require(binding.accessory.service(.lightbulb))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for level in [10, 20, 30, 40, 50] { group.addTask { try await write(light[.brightness], .int(level)) } }
            try await group.waitForAll()
        }
        #expect(sent.all.count == 1)
        #expect(sent.all.first?.first?.command == "setLevel")
    }
    /// At most ten commands a request (section 4.3).
    @Test func commandsGoTenARequest() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("POST", "/v1/devices/d/commands", ["results": []])
        let api = try await TestAPI.make(cloud)
        let list = (0..<15).map { DeviceCommand("main", "switch", $0.isMultiple(of: 2) ? "on" : "off") }
        try await api.commands(deviceID: "d", list)
        let sent = cloud.sent("POST", "/v1/devices/d/commands")
        #expect(sent.map { $0.body?["commands"]?.arrayValue?.count ?? 0 } == [10, 5])
        #expect(sent.allSatisfy { $0.authorization == "Bearer access" && $0.userAgent?.hasPrefix("Homeswift/") == true })
    }
}

enum TestAPI {
    /// An API client on `cloud` with an access token that is good for a day.
    /// `ahead`: the API's clock stands still, this far past the moment it was made, until the test moves it on.
    static func make(_ cloud: FakeSmartThings, limiter: RateLimiter? = nil, refresh: TokenStore.Refresh? = nil,
                     ahead: NIOLockedValueBox<Duration>? = nil) async throws -> SmartThingsAPI {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-SmartThings-api-\(UUID().uuidString)")
        let file = SecretFile<StoredTokens>(vault: CredentialVault(storage: directory), entryName: "plugin.test.smartthings_tokens.json", owner: "HomeBridgeSmartThings/test")
        let tokens = TokenStore(file: file, refresh: refresh, now: Date.init, logger: testLogger, onRefused: { _ in })
        try await tokens.seed(StoredTokens(accessToken: "access", refreshToken: "refresh", expiresIn: 86400, now: Date()))
        var timing = SmartThingsTiming(scale: 0.001)
        if let ahead {
            let start = ContinuousClock.now
            timing.now = { start + ahead.withLockedValue { $0 } }
        }
        return SmartThingsAPI(base: SmartThingsSettings.defaultBaseURL, http: cloud, streaming: cloud, tokens: tokens, timing: timing,
                              logger: testLogger, deviceLimiter: limiter)
    }
}
