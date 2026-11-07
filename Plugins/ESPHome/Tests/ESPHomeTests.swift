import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftESPHome

/// A host with one ESPHome block whose plugin reaches the fake devices of `transport`.
final class ESPHomeTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-esphome-tests-\(UUID().uuidString)")
    let transport = FakeTransport()
    let announcements = NIOLockedValueBox<[Announcement]>([])
    private let plugins = NIOLockedValueBox<[ESPHomePlugin]>([])
    private let storage = MemoryStorage()

    var plugin: ESPHomePlugin? { plugins.withLockedValue { $0.last } }
    /// How long a Bluetooth sensor stays reachable unheard; the plugin's own (30 minutes) when nil.
    var bluetoothTimeout: Duration?

    /// The delays a hundred times shorter: a minute's retry is 0.6 s. The timeouts are ceilings, not waits, and stay
    /// long: scaled to 0.3 s, a busy CI runner (every test target at once) missed a HelloResponse and reconnected, and
    /// with 2 s of silence allowed, a runner that stalled the tests that long reconnected a device answering its pings.
    static let timing: ESPHomeTiming = {
        var timing = ESPHomeTiming().scaled(by: 0.01)
        timing.connectTimeout = .seconds(10)
        timing.handshakeTimeout = .seconds(10)
        timing.responseTimeout = .seconds(10)
        timing.liveness = .seconds(10)
        // The real window: the writes of one change, made at once, can be further apart than 1 ms on a busy runner.
        timing.lightCoalescing = ESPHomeTiming().lightCoalescing
        return timing
    }()

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let transport = transport, announcements = announcements
        registry.register(
            platform: ESPHomePlugin.platform, name: ESPHomePlugin.name, deviceIDOfAccessory: { ESPHomePlugin.deviceID(ofAccessory: $0) }
        ) { json, context in
            let configuration = try JSONDecoder().decode(ESPHomePlugin.Configuration.self, from: json)
            let plugin = ESPHomePlugin(
                configuration: configuration, context: context,
                dependencies: .init(
                    transport: transport, browse: { _, _ in announcements.withLockedValue { $0 } }, timing: Self.timing,
                    setupDiscoveryWindow: .milliseconds(10), bluetoothCheckInterval: .milliseconds(20), bluetoothTimeout: self.bluetoothTimeout))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: ESPHomePlugin.platform, name: "ESPHome", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in self.storage }
        return try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
    }

    func start(settings: [String: Any]) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes: a ceiling, not a wait.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == id }
    }
}

private let key = "QRTIErOb/fcE9Ukd/5qA3RGYMn0Y+p06U58SCtOXvPc="

struct ESPHomePluginTests {
    @Test func aSwitchFollowsTheDeviceAndWritesReachIt() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [switchEntity("Relay", key: 0x1234_5678)], states: [switchState(key: 0x1234_5678, on: true)]))
        environment.transport.add(device, at: "kitchen.local")
        let host = try await environment.start(settings: ["devices": [["host": "kitchen.local"]]])
        defer { Task { await host.stop() } }

        #expect(await eventually { host.accessory("esphome:Relay")?.service(.switch)?.characteristic(.on).value == .bool(true) })
        let accessory = try #require(host.accessory("esphome:Relay"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("AC:BC:32:89:0E:A9"))
        #expect(accessory.information.characteristic(.firmwareRevision).value == .string("2025.1.0"))
        #expect(!accessory.isUnavailable)
        let on = try #require(accessory.service(.switch)?.characteristic(.on))
        try await on.writeHandler(for: .bool(false))?(.bool(false))
        #expect(device.commands == [ESPHomeRequest.switch(key: 0x1234_5678, on: false)])
        // The device's echo comes back as a state.
        #expect(await eventually { on.value == .bool(false) })
        // A switch already in the state written sends nothing.
        #expect(on.writeHandler(for: .bool(false)) == nil)

        device.push(switchState(key: 0x1234_5678, on: true))
        #expect(await eventually { on.value == .bool(true) })
    }

    @Test func sensorsAndBinarySensors() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(
            entities: [
                sensorEntity("Outside", key: 1, unit: "°F"), sensorEntity("Kitchen Humidity", key: 2, unit: "%", icon: "mdi:water-percent"),
                sensorEntity("Light Level", key: 3, unit: "lx"), sensorEntity("Voltage", key: 4, unit: "V"),
                binarySensorEntity("Front Door", key: 5, deviceClass: "door"), binarySensorEntity("Mystery", key: 6, deviceClass: ""),
                binarySensorEntity("Hall Motion", key: 7, deviceClass: "motion"), sensorEntity("Bathroom Humidity", key: 8, unit: "%", deviceClass: "humidity"),
            ],
            states: [
                sensorState(key: 1, 21.5), sensorState(key: 2, 45), sensorState(key: 3, 250_000), binarySensorState(key: 5, true),
                binarySensorState(key: 7, true), sensorState(key: 8, .nan, missing: true),
            ]))
        environment.transport.add(device, at: "sensors.local")
        let host = try await environment.start(settings: ["devices": [["host": "sensors.local"]]])
        defer { Task { await host.stop() } }

        #expect(await eventually { host.accessory("esphome:Hall Motion")?.service(.motionSensor)?.characteristic(.motionDetected).value == .bool(true) })
        let outside = try #require(host.accessory("esphome:Outside")?.service(.temperatureSensor)?.characteristic(.currentTemperature).value.doubleValue)
        #expect(abs(outside - (21.5 - 32) * 5 / 9) < 0.1)
        #expect(host.accessory("esphome:Kitchen Humidity")?.service(.humiditySensor)?.characteristic(.currentRelativeHumidity).value == .double(45))
        #expect(host.accessory("esphome:Light Level")?.service(.lightSensor)?.characteristic(.currentAmbientLightLevel).value == .double(100_000))
        #expect(host.accessory("esphome:Front Door")?.service(.contactSensor)?.characteristic(.contactSensorState).value == .int(1))
        #expect(host.accessory("esphome:Voltage") == nil)
        #expect(host.accessory("esphome:Mystery") == nil)
        // No value yet: the NaN never reached HomeKit.
        #expect(host.accessory("esphome:Bathroom Humidity")?.service(.humiditySensor) != nil)
        #expect(host.accessory("esphome:Bathroom Humidity")?.service(.humiditySensor)?.characteristic(.currentRelativeHumidity).value.doubleValue?.isNaN != true)
    }

    @Test func rgbLightWithEffects() async throws {
        let environment = ESPHomeTestEnvironment()
        let lamp = lightEntity("Lamp", key: 0x0102_0304, modes: [35], effects: ["None", "Strobe", "Flicker"])
        let state = frame(24) {
            $0.fixed32(1, 0x0102_0304)
            $0.bool(2, true)
            $0.float(3, 0.5)
            $0.float(4, 1)
            $0.enumeration(11, 35)
            $0.string(9, "None")
        }
        let device = FakeDevice(.init(entities: [lamp], states: [state]))
        environment.transport.add(device, at: "lamp.local")
        let host = try await environment.start(settings: ["devices": [["host": "lamp.local"]]])
        defer { Task { await host.stop() } }

        #expect(await eventually { host.accessory("esphome:Lamp")?.service(.lightbulb)?.characteristic(.brightness).value == .int(50) })
        let accessory = try #require(host.accessory("esphome:Lamp"))
        let lightbulb = try #require(accessory.service(.lightbulb))
        // The colour comes with the same state, written after the brightness: waited for too.
        #expect(await eventually { lightbulb.characteristic(.saturation).value.doubleValue == 100 })
        #expect(lightbulb.characteristic(.hue).value.doubleValue == 0)
        #expect(lightbulb.adaptiveLighting == nil)
        let effects = accessory.services.filter { $0.type == .switch }
        #expect(effects.map(\.subtype) == ["Strobe Switch", "Flicker Switch"])
        #expect(effects.allSatisfy { $0.characteristic(.on).value == .bool(false) })

        // On and Brightness of one change become one command.
        async let on: Void = lightbulb.characteristic(.on).writeHandler(for: .bool(true))!(.bool(true))
        async let level: Void = lightbulb.characteristic(.brightness).writeHandler(for: .int(80))!(.int(80))
        _ = try await (on, level)
        #expect(device.commands.count == 1)
        let command = try #require(ProtobufMessage(device.commands[0].body))
        #expect(command.bool(3) && command.bool(4) && command.float(5) == 0.8)

        try await lightbulb.characteristic(.hue).writeHandler(for: .int(120))!(.int(120))
        let color = try #require(device.lastMessage)
        #expect(color.bool(6) && color.float(7) == 0 && color.float(8) == 1 && color.float(9) == 0 && color.enumeration(23) == 35)

        try await effects[0].characteristic(.on).writeHandler(for: .bool(true))!(.bool(true))
        #expect(device.lastMessage?.string(19) == "Strobe")
        try await effects[0].characteristic(.on).writeHandler(for: .bool(false))!(.bool(false))
        #expect(device.lastMessage?.string(19) == "None")

        device.push(frame(24) {
            $0.fixed32(1, 0x0102_0304)
            $0.bool(2, true)
            $0.string(9, "Flicker")
        })
        #expect(await eventually { effects[1].characteristic(.on).value == .bool(true) })
    }

    @Test func whiteLightHasAdaptiveLighting() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [lightEntity("Desk", key: 9, modes: [11])], states: [frame(24) {
            $0.fixed32(1, 9)
            $0.bool(2, true)
            $0.float(3, 1)
            $0.float(8, 300)
            $0.enumeration(11, 11)
        }]))
        environment.transport.add(device, at: "desk.local")
        let host = try await environment.start(settings: ["devices": [["host": "desk.local"]]])
        defer { Task { await host.stop() } }

        #expect(await eventually { host.accessory("esphome:Desk")?.service(.lightbulb)?.characteristic(.colorTemperature).value == .int(300) })
        let lightbulb = try #require(host.accessory("esphome:Desk")?.service(.lightbulb))
        let controller = try #require(lightbulb.adaptiveLighting)
        try await lightbulb.characteristic(.colorTemperature).writeHandler(for: .int(250))!(.int(250))
        let command = try #require(device.lastMessage)
        #expect(command.bool(12) && command.float(13) == 250 && command.enumeration(23) == 11)

        try controller.activateForTesting(mireds: 250)
        #expect(controller.isAdaptiveLightingActive)
        // A white set elsewhere turns it off.
        device.push(frame(24) {
            $0.fixed32(1, 9)
            $0.bool(2, true)
            $0.float(3, 1)
            $0.float(8, 400)
            $0.enumeration(11, 11)
        })
        #expect(await eventually { !controller.isAdaptiveLightingActive })
    }

    @Test func coverFanLockAndButton() async throws {
        let environment = ESPHomeTestEnvironment()
        let cover = frame(13) {
            $0.string(1, "blind")
            $0.fixed32(2, 20)
            $0.string(3, "Blind")
            $0.bool(6, true)
            $0.bool(12, true)
        }
        let fan = frame(14) {
            $0.fixed32(2, 21)
            $0.string(3, "Fan")
            $0.bool(6, true)
            $0.int32(8, 3)
        }
        let lock = frame(58) {
            $0.fixed32(2, 22)
            $0.string(3, "Door Lock")
        }
        let button = frame(61) {
            $0.fixed32(2, 23)
            $0.string(3, "Restart")
        }
        let device = FakeDevice(.init(entities: [cover, fan, lock, button], states: [
            frame(22) {
                $0.fixed32(1, 20)
                $0.float(3, 0.4)
            },
            frame(23) {
                $0.fixed32(1, 21)
                $0.bool(2, true)
                $0.int32(6, 2)
            },
            frame(59) {
                $0.fixed32(1, 22)
                $0.enumeration(2, 1)
            },
        ]))
        environment.transport.add(device, at: "misc.local")
        let host = try await environment.start(settings: ["devices": [["host": "misc.local"]]])
        defer { Task { await host.stop() } }

        #expect(await eventually { host.accessory("esphome:Door Lock")?.service(.lockMechanism)?.characteristic(.lockCurrentState).value == .int(1) })
        let blind = try #require(host.accessory("esphome:Blind")?.service(.windowCovering))
        #expect(blind.characteristic(.currentPosition).value == .int(40))
        #expect(blind.characteristic(.positionState).value == .int(2))
        try await blind.characteristic(.targetPosition).writeHandler(for: .int(75))!(.int(75))
        #expect(device.lastMessage?.float(5) == 0.75)

        let fanService = try #require(host.accessory("esphome:Fan")?.service(.fanv2))
        let speed = try #require(fanService.characteristic(.rotationSpeed).value.doubleValue)
        #expect(abs(speed - 66.67) < 0.1)
        try await fanService.characteristic(.rotationSpeed).writeHandler(for: .int(100))!(.int(100))
        #expect(device.lastMessage?.int32(11) == 3)

        let lockService = try #require(host.accessory("esphome:Door Lock")?.service(.lockMechanism))
        #expect(lockService.characteristic(.lockTargetState).type == .lockTargetState)
        try await lockService.characteristic(.lockTargetState).writeHandler(for: .int(0))!(.int(0))
        let unlock = try #require(device.commands.last)
        #expect(unlock.type == MessageType.lockCommand && ProtobufMessage(unlock.body)?.enumeration(2) == 0)

        let restart = try #require(host.accessory("esphome:Restart")?.service(.switch)?.characteristic(.on))
        try await restart.writeHandler(for: .bool(true))!(.bool(true))
        #expect(device.commands.last?.type == MessageType.buttonCommand)
        #expect(await eventually { restart.value == .bool(false) })
    }

    @Test func encryptedDeviceAndAWrongKey() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(encryptionKey: key, entities: [switchEntity("Secure Relay", key: 1)], states: [switchState(key: 1, on: true)]))
        environment.transport.add(device, at: "secure.local")
        let host = try await environment.start(settings: ["devices": [["host": "secure.local", "encryptionKey": key]]])
        #expect(await eventually { host.accessory("esphome:Secure Relay")?.service(.switch)?.characteristic(.on).value == .bool(true) })
        try await host.accessory("esphome:Secure Relay")?.service(.switch)?.characteristic(.on).writeHandler(for: .bool(false))?(.bool(false))
        #expect(device.commands == [ESPHomeRequest.switch(key: 1, on: false)])
        await host.stop()

        // Another key: refused, and not tried again.
        let wrong = ESPHomeTestEnvironment()
        let other = FakeDevice(.init(encryptionKey: key, entities: [switchEntity("Secure Relay", key: 1)]))
        wrong.transport.add(other, at: "secure.local")
        let second = try await wrong.start(settings: ["devices": [["host": "secure.local", "encryptionKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]]])
        defer { Task { await second.stop() } }
        let failed = await eventually {
            guard let device = await wrong.plugin?.devices.values.first else { return false }
            if case .failed = await device.status { return true }
            return false
        }
        #expect(failed)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(other.connections == 1)

        // A plaintext client to an encrypted device is told to set the key.
        let plaintext = ESPHomeTestEnvironment()
        plaintext.transport.add(FakeDevice(.init(encryptionKey: key)), at: "secure.local")
        let third = try await plaintext.start(settings: ["devices": [["host": "secure.local"]]])
        defer { Task { await third.stop() } }
        #expect(await eventually { await plaintext.plugin?.devices.values.first?.status == .unreachable })
    }

    @Test func aRejectedPasswordStopsTheRetries() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(password: "secret", entities: [switchEntity("Old Relay", key: 1)]))
        environment.transport.add(device, at: "old.local")
        let host = try await environment.start(settings: ["devices": [["host": "old.local", "password": "wrong"]]])
        defer { Task { await host.stop() } }
        let failed = await eventually {
            guard let device = await environment.plugin?.devices.values.first else { return false }
            if case .failed = await device.status { return true }
            return false
        }
        #expect(failed)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(device.connections == 1)
    }

    @Test func offlineLostAndBack() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [switchEntity("Relay", key: 1)], states: [switchState(key: 1, on: true)]))
        device.reachable = false
        environment.transport.add(device, at: "flaky.local")
        let host = try await environment.start(settings: ["devices": [["host": "flaky.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.devices.values.first?.status == .unreachable })
        #expect(host.accessory("esphome:Relay") == nil)

        device.reachable = true
        // Connected, and its state shown: the write below changes the value.
        #expect(await eventually { host.accessory("esphome:Relay")?.service(.switch)?.characteristic(.on).value == .bool(true) })
        let accessory = try #require(host.accessory("esphome:Relay"))
        device.reachable = false
        device.drop()
        #expect(await eventually { accessory.isUnavailable })
        // A write while it is away answers No Response.
        await #expect(throws: HAPStatusError.self) {
            try await accessory.service(.switch)?.characteristic(.on).writeHandler(for: .bool(false))?(.bool(false))
        }
        device.reachable = true
        #expect(await eventually { !accessory.isUnavailable })
    }

    @Test func pingsTheDeviceAndGivesUpOnSilence() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [switchEntity("Relay", key: 1)]))
        environment.transport.add(device, at: "quiet.local")
        let host = try await environment.start(settings: ["devices": [["host": "quiet.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Relay")?.isUnavailable == false })
        // A ping every 0.2 s, each answered: the connection it started with stays up.
        #expect(await eventually { device.pings >= 5 })
        #expect(device.connections == 1)
        #expect(host.accessory("esphome:Relay")?.isUnavailable == false)
    }

    @Test func sameNamesOnTwoDevicesGetTheirOwnAccessories() async throws {
        let environment = ESPHomeTestEnvironment()
        let first = FakeDevice(.init(name: "one", mac: "AA:AA:AA:AA:AA:01", entities: [sensorEntity("Temperature", key: 1, unit: "°C")]))
        environment.transport.add(first, at: "one.local")
        let host = try await environment.start(settings: ["devices": [["host": "one.local"]]])
        #expect(await eventually { host.accessory("esphome:Temperature") != nil })
        await host.stop()

        // The second device comes later; the first keeps its id however the two answer next time.
        let second = FakeDevice(.init(name: "two", mac: "AA:AA:AA:AA:AA:02", entities: [sensorEntity("Temperature", key: 1, unit: "°C")]))
        environment.transport.add(second, at: "two.local")
        let again = try await environment.start(settings: ["devices": [["host": "two.local"], ["host": "one.local"]]])
        defer { Task { await again.stop() } }
        #expect(await eventually { again.accessory("esphome:Temperature@AA:AA:AA:AA:AA:02") != nil })
        #expect(again.accessory("esphome:Temperature")?.information.characteristic(.serialNumber).value == .string("AA:AA:AA:AA:AA:01"))
    }

    @Test func blacklistAndDiscovery() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [switchEntity("Relay", key: 1), switchEntity("Hidden", key: 2)]))
        environment.transport.add(device, at: "192.168.1.40")
        environment.announcements.withLockedValue {
            $0 = [Announcement(name: "kitchen", hostName: "kitchen.local", port: 6053, addresses: ["169.254.1.1", "192.168.1.40"], mac: "AC:BC:32:89:0E:A9", encrypted: false)]
        }
        let host = try await environment.start(settings: ["discover": true, "discoveryTimeout": 10, "blacklist": ["Hidden"]])
        #expect(await eventually { host.accessory("esphome:Relay") != nil })
        #expect(host.accessory("esphome:Hidden") == nil)
        await host.stop()

        // A name blacklisted later takes its cached accessory away.
        let again = try await environment.start(settings: ["blacklist": ["Relay"], "devices": [] as [Any]])
        defer { Task { await again.stop() } }
        #expect(await eventually { again.accessory("esphome:Relay") == nil })
    }

    @Test func setupAsksForTheKeyOfAnEncryptedDevice() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(encryptionKey: key, entities: [switchEntity("Relay", key: 1)]))
        environment.transport.add(device, at: "192.168.1.41")
        environment.announcements.withLockedValue {
            $0 = [Announcement(name: "kitchen", hostName: "kitchen.local", port: 6053, addresses: ["192.168.1.41"], mac: "AC:BC:32:89:0E:A9", encrypted: true)]
        }
        let host = try environment.host(settings: [:])
        try await host.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        let kitchen = try #require(found.first)
        #expect(kitchen.deviceID == "AC:BC:32:89:0E:A9" && kitchen.authorization == .apiKey && kitchen.address == "192.168.1.41" && !kitchen.isSetUp)

        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(kitchen))) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["encryptionKey"] && prompt.fields[0].kind == .secret)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(kitchen), answers: ["encryptionKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="], state: ["asked": true]))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(kitchen), answers: ["encryptionKey": key], state: ["asked": true])) else {
            Issue.record("not done")
            return
        }
        #expect(outcome.deviceID == "AC:BC:32:89:0E:A9")
        #expect(outcome.credentials?["encryptionKey"]?.stringValue == key)
        #expect(outcome.settings["host"]?.stringValue == "192.168.1.41")
    }

    @Test func setUpDevicesConnectWithTheVaultsKey() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(encryptionKey: key, entities: [switchEntity("Vault Relay", key: 1)]))
        environment.transport.add(device, at: "192.168.1.42")
        let first = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        let context = try #require(first.context(platform: ESPHomePlugin.platform, name: "ESPHome"))
        try context.saveCredentials(ESPHomeCredentials(encryptionKey: key), for: "AC:BC:32:89:0E:A9")
        _ = plugin
        await first.stop()

        let host = try await environment.start(settings: ["_accessories": ["AC:BC:32:89:0E:A9": ["host": "192.168.1.42"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Vault Relay") != nil })
    }

    @Test func canonicalSettingsMoveLearnedDevices() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [switchEntity("Relay", key: 1)]))
        environment.transport.add(device, at: "kitchen.local")
        let host = try await environment.start(settings: ["devices": [["host": "kitchen.local", "port": 6053, "retryAfter": 120_000], ["host": "away.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Relay") != nil })
        let plugin = try #require(environment.plugin)
        let block: JSONValue = [
            "platform": "esphome", "devices": [["host": "kitchen.local", "port": 6053, "retryAfter": 120_000, "password": "pw"], ["host": "away.local"]],
        ]
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["devices"]?.arrayValue?.count == 1)
        #expect(canonical["_accessories"]?["AC:BC:32:89:0E:A9"]?["host"]?.stringValue == "kitchen.local")
        #expect(canonical["_accessories"]?["AC:BC:32:89:0E:A9"]?["retryAfter"]?.intValue == 120_000)
        #expect(canonical["_accessories"]?["AC:BC:32:89:0E:A9"]?["password"] == nil)
        #expect(ESPHomePlugin.canonical(["devices": [["host": "x"]]], learned: [:]).0 == ["devices": [["host": "x"]]])
    }

    @Test func thePasswordGoesOnlyToTheDeviceWithItsMAC() async throws {
        let environment = ESPHomeTestEnvironment()
        let impostor = FakeDevice(.init(mac: "11:22:33:44:55:66", password: "secret", entities: [switchEntity("Old Relay", key: 1)]))
        environment.transport.add(impostor, at: "10.0.0.5")
        let real = FakeDevice(.init(password: "secret", entities: [switchEntity("Real Relay", key: 2)]))
        environment.transport.add(real, at: "10.0.0.6")
        let setup = try await environment.start(settings: [:])
        let context = try #require(setup.context(platform: ESPHomePlugin.platform, name: "ESPHome"))
        try context.saveCredentials(ESPHomeCredentials(password: "secret"), for: "AC:BC:32:89:0E:A9")
        try context.saveCredentials(ESPHomeCredentials(password: "secret"), for: "AC:BC:32:89:0E:AA")
        await setup.stop()

        real.config.mac = "AC:BC:32:89:0E:AA"
        let host = try await environment.start(settings: [
            "_accessories": ["AC:BC:32:89:0E:A9": ["host": "10.0.0.5"], "AC:BC:32:89:0E:AA": ["host": "10.0.0.6"]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Real Relay") != nil })
        #expect(real.authentications >= 1)
        #expect(await eventually { impostor.connections >= 1 && !impostor.isConnected })
        #expect(impostor.authentications == 0)
        #expect(host.accessory("esphome:Old Relay") == nil)
    }

    @Test func anAnnouncementDoesNotMoveAPasswordDevice() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(password: "secret", entities: [switchEntity("Old Relay", key: 1)]))
        environment.transport.add(device, at: "old.local")
        let impostor = FakeDevice(.init(password: "secret"))
        environment.transport.add(impostor, at: "10.0.0.66")
        environment.announcements.withLockedValue {
            $0 = [Announcement(name: "old", hostName: "old.local", port: 6053, addresses: ["10.0.0.66"], mac: "AC:BC:32:89:0E:A9", encrypted: false)]
        }
        let host = try await environment.start(settings: ["discover": true, "discoveryTimeout": 10, "devices": [["host": "old.local", "password": "secret"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Old Relay") != nil })
        #expect(impostor.connections == 0)
    }

    @Test func setupRefusesPlaintextWithAKeyAndAnotherDevice() async throws {
        let environment = ESPHomeTestEnvironment()
        environment.transport.add(FakeDevice(.init()), at: "192.168.1.43")
        environment.transport.add(FakeDevice(.init(mac: "11:22:33:44:55:66")), at: "192.168.1.44")
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let plaintext = DiscoveredDevice(deviceID: "AC:BC:32:89:0E:A9", name: "kitchen", address: "192.168.1.43", authorization: .apiKey)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(plaintext), answers: ["encryptionKey": key], state: ["asked": true]))
        }
        let other = DiscoveredDevice(deviceID: "AC:BC:32:89:0E:A9", name: "kitchen", address: "192.168.1.44")
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .device(other))) }
        let right = DiscoveredDevice(deviceID: "AC:BC:32:89:0E:A9", name: "kitchen", address: "192.168.1.43")
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(right))) else {
            Issue.record("not done")
            return
        }
        #expect(outcome.credentials == nil && outcome.deviceID == "AC:BC:32:89:0E:A9")
    }

    @Test func hueAndSaturationOfOneChangeMakeOneColour() async throws {
        let environment = ESPHomeTestEnvironment()
        let device = FakeDevice(.init(entities: [lightEntity("Lamp", key: 3, modes: [35])], states: [frame(24) {
            $0.fixed32(1, 3)
            $0.bool(2, true)
            $0.float(4, 1)
            $0.enumeration(11, 35)
        }]))
        environment.transport.add(device, at: "lamp.local")
        let host = try await environment.start(settings: ["devices": [["host": "lamp.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory("esphome:Lamp")?.service(.lightbulb)?.characteristic(.saturation).value.doubleValue == 100 })
        let lightbulb = try #require(host.accessory("esphome:Lamp")?.service(.lightbulb))
        async let hue: Void = lightbulb.characteristic(.hue).writeHandler(for: .int(240))!(.int(240))
        async let saturation: Void = lightbulb.characteristic(.saturation).writeHandler(for: .int(50))!(.int(50))
        _ = try await (hue, saturation)
        #expect(device.commands.count == 1)
        let color = try #require(device.lastMessage)
        #expect(color.float(7) == 0.5 && color.float(8) == 0.5 && color.float(9) == 1)
    }

    @Test func subDevicesAndRenamedEntities() async throws {
        let environment = ESPHomeTestEnvironment()
        func relay(_ name: String, subDevice: UInt32) -> ESPHomeFrame {
            frame(17) {
                $0.fixed32(2, 5)
                $0.string(3, name)
                $0.uint32(10, subDevice)
            }
        }
        let device = FakeDevice(.init(entities: [relay("Relay A", subDevice: 1), relay("Relay B", subDevice: 2)]))
        device.echoesSwitches = false
        environment.transport.add(device, at: "hub.local")
        let host = try await environment.start(settings: ["devices": [["host": "hub.local"]]])
        #expect(await eventually { host.accessory("esphome:Relay B") != nil && host.accessory("esphome:Relay A") != nil })
        device.push(frame(26) {
            $0.fixed32(1, 5)
            $0.bool(2, true)
            $0.uint32(3, 2)
        })
        #expect(await eventually { host.accessory("esphome:Relay B")?.service(.switch)?.characteristic(.on).value == .bool(true) })
        #expect(host.accessory("esphome:Relay A")?.service(.switch)?.characteristic(.on).value == .bool(false))
        try await host.accessory("esphome:Relay A")?.service(.switch)?.characteristic(.on).writeHandler(for: .bool(true))?(.bool(true))
        #expect(device.lastMessage?.uint32(3) == 1)
        await host.stop()

        // Renamed in the device's configuration: the old accessory goes.
        device.config.entities = [relay("Pump", subDevice: 1), relay("Relay B", subDevice: 2)]
        let again = try await environment.start(settings: ["devices": [["host": "hub.local"]]])
        defer { Task { await again.stop() } }
        #expect(await eventually { again.accessory("esphome:Pump") != nil && again.accessory("esphome:Relay A") == nil })
        #expect(again.accessory("esphome:Relay B") != nil)
    }

    @Test func schemaIsCurrentAndDeclaresNoSecret() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.schema.json")
        #expect(try JSONValue(string: String(contentsOf: file, encoding: .utf8)) == JSONValue(string: try #require(ESPHomePlugin.configurationSchemaJSON)))
        #expect(ESPHomePlugin.configurationSchemaJSON?.contains("encryptionKey") == false)
        #expect(ESPHomePlugin.configurationSchemaJSON?.contains("\"password\"") == false)
    }
}
