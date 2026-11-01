import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftGovee

/// A handler on its own: the commands it sends are recorded, and fail when asked to.
final class DeviceHarness: @unchecked Sendable {
    let sent = Collector<DeviceCommand>()
    private let lock = NIOLock()
    private var _failing = false
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    let store: DeviceStore
    var device: GoveeDevice!

    @GoveeActor
    init(
        model: String, settings: JSONValue = [:], platform: JSONValue = [:], transports: TransportFlags = TransportFlags(hasLAN: true, useLAN: true),
        adaptiveLighting: AdaptiveLightingFactory? = nil, store: DeviceStore = memoryStore(), logger: Logger = testLogger,
        stateDelay: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        var environment = DeviceEnvironment(
            info: DeviceInfo(id: "AA:BB:CC:DD:EE:FF:00:11", model: model, name: "Test"), settings: DeviceSettings(raw: settings),
            platform: GoveePlugin.Configuration(platform), transports: transports,
            send: { [sent, lock = self.lock] command in
                let fail = lock.withLock { self._failing }
                if fail { throw GoveeAPIError.message("offline") }
                sent.append(command)
            },
            logger: logger, deviceLogging: true, debugLogging: false, cached: nil, store: store, historyDirectory: nil, adaptiveLighting: adaptiveLighting)
        environment.temperatureSourceFirstRead = .milliseconds(50)
        environment.stateDelay = stateDelay ?? {}
        device = GoveeDevice.make(model: model, environment: environment)
        device.configure()
    }

    @GoveeActor var services: [Service] { device.services }

    @GoveeActor func service(_ type: ServiceType, subtype: String? = nil) -> Service? {
        device.services.first { $0.type.uuid == type.uuid && (subtype == nil || $0.subtype == subtype) }
    }

    @GoveeActor func update(_ update: DeviceUpdate) async { await device.externalUpdate(update) }

    /// Writes as HomeKit would: the handler, then the value.
    func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
        try await #require(characteristic).write(value)
    }
}

/// Holds whoever waits until it opens, and says how many are waiting.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isOpen = false
    private var arrived = 0

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            arrived += 1
            let ready = watchers.filter { $0.count <= arrived }
            watchers.removeAll { $0.count <= arrived }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForWaiters(_ count: Int) async {
        guard arrived < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A device store in a temporary file, written only when a handler flushes it.
func memoryStore() -> DeviceStore {
    DeviceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("govee-test-\(UUID().uuidString).json"), autosave: nil)
}

func update(_ fields: (inout DeviceUpdate) -> Void) -> DeviceUpdate {
    var update = DeviceUpdate(source: .aws)
    fields(&update)
    return update
}

@Suite struct LightTests {
    @Test func saturationOnlyChanges() async throws {
        let harness = await DeviceHarness(model: "H6008")
        let light = try #require(await harness.service(.lightbulb))
        await harness.update(update { $0.rgb = RGB(255, 0, 0) })
        #expect(light[.saturation]?.value == .double(100))
        await harness.update(update { $0.rgb = RGB(255, 128, 128) })
        #expect(light[.hue]?.value == .double(0))
        #expect(light[.saturation]?.value == .double(50))
    }

    @Test func colourTemperaturesAreClampedToHomeKitsRange() async throws {
        let harness = await DeviceHarness(model: "H6008")
        let light = try #require(await harness.service(.lightbulb))
        await harness.update(update { $0.kelvin = 9000 })
        #expect(light[.colorTemperature]?.value.intValue == 140)
        await harness.update(update { $0.kelvin = 1800 })
        #expect(light[.colorTemperature]?.value.intValue == 500)
    }

    @Test func powerAndBrightness() async throws {
        let harness = await DeviceHarness(model: "H6008")
        let light = try #require(await harness.service(.lightbulb))
        await harness.update(update {
            $0.state = "on"
            $0.brightness = 42
        })
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.brightness]?.value == .int(42))
    }

    @Test func aSingleOnRequest() async throws {
        let harness = await DeviceHarness(model: "H6008")
        let light = try #require(await harness.service(.lightbulb))
        try await harness.write(light[.on], true)
        #expect(harness.sent.items == [.state(true)])
    }

    @Test func theLastOfTwoQuickTapsWins() async throws {
        // Each write waits at the gate until both have arrived, On first.
        let gate = Gate()
        let harness = await DeviceHarness(model: "H6008", stateDelay: { await gate.wait() })
        let light = try #require(await harness.service(.lightbulb))
        async let on: Void = harness.write(light[.on], true)
        await gate.waitForWaiters(1)
        async let off: Void = harness.write(light[.on], false)
        await gate.waitForWaiters(2)
        await gate.open()
        _ = try await (on, off)
        // The light was off already, so the superseded On is not sent.
        #expect(harness.sent.items.isEmpty)
    }

    @Test func aFailedCommandReportsNoResponse() async throws {
        let harness = await DeviceHarness(model: "H6008")
        harness.failing = true
        let light = try #require(await harness.service(.lightbulb))
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await harness.write(light[.on], true) }
    }

    @Test func colourAndTemperatureCommands() async throws {
        let harness = await DeviceHarness(model: "H6008")
        let light = try #require(await harness.service(.lightbulb))
        await harness.update(update { $0.state = "on" })
        try await harness.write(light[.saturation], 100)
        try await harness.write(light[.hue], 120)
        try await harness.write(light[.colorTemperature], 250)
        #expect(harness.sent.items == [.color(RGB(0, 255, 0)), .colorTem(4000)])
        // BLE-only lights take the temperature as a colour.
        let ble = await DeviceHarness(model: "H6008", transports: TransportFlags(hasBLE: true, useBLE: true))
        let bulb = try #require(await ble.service(.lightbulb))
        await ble.update(update { $0.state = "on" })
        try await ble.write(bulb[.colorTemperature], 250)
        #expect(ble.sent.items == [.color(Colour.k2rgb(4000))])
    }

    @Test func scenesBecomeSwitchesAndLegacySlotsEveCharacteristics() async throws {
        let settings: JSONValue = [
            "scenes": [["name": "Forest", "sceneCode": "AAA,BBB", "sceneId": 130, "kind": "scene"], ["name": "Mine", "sceneCode": "CCC", "sceneId": 130, "kind": "diy"]],
            "scene": ["sceneCode": "DDD"], "diyModeTwo": ["sceneCode": "EEE", "showAs": "switch"],
            "musicModeLive": ["enabled": true, "effect": "spectrum", "sensitivity": 60, "autoColour": false],
        ]
        let harness = await DeviceHarness(model: "H6008", settings: settings)
        let light = try #require(await harness.service(.lightbulb))
        #expect(light[GoveeCharacteristic.scene] != nil)
        #expect(light[GoveeCharacteristic.colourMode] != nil)
        #expect(light[GoveeCharacteristic.diyModeTwo] == nil)
        let switches = await harness.services.filter { $0.type.uuid == ServiceType.switch.uuid }.compactMap(\.subtype)
        #expect(switches == ["DiyModeTwo", "gv-scene-scene-130", "gv-scene-diy-130"])
        let forest = try #require(await harness.service(.switch, subtype: "gv-scene-scene-130"))
        #expect(forest[.configuredName]?.value == "Forest")
        try await harness.write(forest[.on], true)
        try await harness.write(light[GoveeCharacteristic.scene], true)
        #expect(harness.sent.items == [.rgbScene(code: "AAA,BBB", bleCode: nil), .rgbScene(code: "DDD", bleCode: nil)])

        let music = try #require(await harness.service(.lightbulb, subtype: "gv-music"))
        #expect(music[.brightness]?.value == .int(60))
        #expect(music[.hue] != nil)
        try await harness.write(music[.on], true)
        #expect(harness.sent.items.last == .musicMode(.init(effect: .spectrum, sensitivity: 60, autoColour: false, colour: Colour.hs2rgb(0, 0))))
    }

    @Test func colourSafeModeDropsColourTemperature() async throws {
        let harness = await DeviceHarness(model: "H6008", platform: ["colourSafeMode": true])
        #expect(try #require(await harness.service(.lightbulb))[.colorTemperature] == nil)
        let plain = await DeviceHarness(model: "H6008", settings: ["showAs": "switch"])
        #expect(await plain.service(.switch) != nil)
        #expect(await plain.service(.lightbulb) == nil)
    }
}

/// Homeswift's Adaptive Lighting on the light, in manual mode so no schedule runs, on until the light turns it off.
final class AdaptiveLightingProbe: @unchecked Sendable {
    private let lock = NIOLock()
    private var controller: AdaptiveLightingController?

    var shift: Int? { lock.withLock { controller?.customTemperatureAdjustment } }
    var isActive: Bool { lock.withLock { controller?.isAdaptiveLightingActive ?? false } }

    /// A schedule HomeKit set up (the one Homeswift's own tests use).
    func activate() {
        let schedule = #"{"activeTransition":{"iid":11,"transitionStartMillis":1699999400000,"timeMillisOffset":600000,"transitionId":"0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b","transitionStartBuffer":"400c3508a8000000","id3":"aabb","brightnessCharacteristicIID":10,"brightnessAdjustmentRange":{"minBrightnessValue":10,"maxBrightnessValue":100},"transitionCurve":[{"temperature":150,"brightnessAdjustmentFactor":0.5,"transitionTime":0,"duration":0},{"temperature":350,"brightnessAdjustmentFactor":-0.25,"transitionTime":7200000}],"updateInterval":60000,"notifyIntervalThreshold":600000}}"#
        try? lock.withLock { controller }?.deserialize(Data(schedule.utf8))
    }

    var factory: AdaptiveLightingFactory {
        { [self] lightbulb, shift, _ in
            let controller = AdaptiveLightingController(lightbulb, mode: .manual, customTemperatureAdjustment: shift, logger: testLogger)
            lock.withLock { self.controller = controller }
            activate()
            return controller
        }
    }
}

@Suite struct AdaptiveLightingTests {
    @Test func usesTheShiftAndStaysOffWhenDisabled() async {
        let probe = AdaptiveLightingProbe()
        _ = await DeviceHarness(model: "H6008", settings: ["adaptiveLightingShift": 150], adaptiveLighting: probe.factory)
        #expect(probe.shift == 150)
        let off = AdaptiveLightingProbe()
        _ = await DeviceHarness(model: "H6008", settings: ["adaptiveLightingShift": -1], adaptiveLighting: off.factory)
        _ = await DeviceHarness(model: "H6008", platform: ["colourSafeMode": true], adaptiveLighting: off.factory)
        #expect(off.shift == nil)
    }

    @Test func aSignificantColourChangeElsewhereTurnsItOff() async {
        let fake = AdaptiveLightingProbe()
        let harness = await DeviceHarness(model: "H6008", adaptiveLighting: fake.factory)
        #expect(fake.isActive)
        // The first report after launch fills the cache: not a change made elsewhere, however far from its empty 0 K.
        await harness.update(update { $0.kelvin = 2700 })
        #expect(fake.isActive)
        await harness.update(update { $0.kelvin = 4000 })
        #expect(!fake.isActive)
        fake.activate()
        // Within 100 K: Adaptive Lighting's own step, not a change by hand.
        await harness.update(update { $0.kelvin = 4050 })
        #expect(fake.isActive)
        await harness.update(update { $0.rgb = RGB(255, 0, 0) })
        #expect(!fake.isActive)
    }

    @Test func aSceneTurnsItOff() async throws {
        let fake = AdaptiveLightingProbe()
        let harness = await DeviceHarness(model: "H6008", settings: ["scenes": [["name": "Forest", "sceneCode": "AAA", "sceneId": 1]]], adaptiveLighting: fake.factory)
        #expect(fake.isActive)
        try await harness.write(try #require(await harness.service(.switch))[.on], true)
        #expect(!fake.isActive)
    }

    @Test func theControllerDrivesTheColourTemperature() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start(["username": "user@example.com", "password": "pw", "lightDevices": [["deviceId": lightID, "adaptiveLightingShift": 120]]])
        defer { Task { await host.stop() } }
        let lightbulb = try #require(host.accessory(lightID)?.service(.lightbulb))
        #expect(lightbulb[.characteristicValueTransitionControl] != nil)
        #expect(lightbulb[.supportedCharacteristicValueTransitionConfiguration] != nil)
        let device = try #require(await environment.plugin?.devices[lightID]?.handler as? LightDevice)
        let controller = try #require(await device.adaptiveLighting)
        #expect(controller.customTemperatureAdjustment == 120)
        #expect(!controller.isAdaptiveLightingActive)
    }
}

@Suite struct HeaterTests {
    @Test func heater1aIsAFanWithSpeedSwingAndLock() async throws {
        let harness = await DeviceHarness(model: "H7130")
        let fan = try #require(await harness.service(.fanv2))
        try await harness.write(fan[.active], 1)
        try await harness.write(fan[.rotationSpeed], 66)
        try await harness.write(fan[.swingMode], 1)
        try await harness.write(fan[.lockPhysicalControls], 1)
        #expect(harness.sent.items == [
            .ptReal(Catalog.deviceStateCodes["on"]!), .ptReal(Catalog.heaterH7130SpeedCodes[66]!), .ptReal(Catalog.heaterSwingCodes["on"]!), .ptReal(Catalog.lockCodes["on"]!),
        ])
        #expect(await harness.service(.heaterCooler) == nil)
    }

    @Test func heater1aAppliesReports() async throws {
        let harness = await DeviceHarness(model: "H7130")
        let fan = try #require(await harness.service(.fanv2))
        await harness.update(update {
            $0.state = "on"
            $0.commands = [frame("aa0503"), frame("aa1801"), frame("aa1001")]
        })
        #expect(fan[.active]?.value == .int(1))
        #expect(fan[.rotationSpeed]?.value.intValue == 99)
        #expect(fan[.swingMode]?.value == .int(1))
        #expect(fan[.lockPhysicalControls]?.value == .int(1))
    }

    @Test func heater1bHasAThermostatAndAFan() async throws {
        let harness = await DeviceHarness(model: "H7130", settings: ["tempReporting": true])
        let heater = try #require(await harness.service(.heaterCooler))
        let fan = try #require(await harness.service(.fan))
        try await harness.write(fan[.rotationSpeed], 33)
        try await harness.write(heater[.targetHeaterCoolerState], 1)
        try await harness.write(heater[.heatingThresholdTemperature], 22)
        #expect(harness.sent.items == [
            .ptReal(Catalog.heaterH7130SpeedCodes[33]!), .ptReal(Catalog.heaterH7130TempCodesHeat[20]!), .ptReal(Catalog.heaterH7130TempCodesHeat[22]!),
        ])
        #expect(await harness.service(.fanv2) == nil)
        try await harness.write(heater[.active], 1)
        #expect(fan[.on]?.value == .bool(true))
    }

    @Test func heater1bAppliesTemperaturesInFahrenheitHundredths() async throws {
        let harness = await DeviceHarness(model: "H7130", settings: ["tempReporting": true])
        let heater = try #require(await harness.service(.heaterCooler))
        let fan = try #require(await harness.service(.fan))
        await harness.update(update {
            $0.state = "on"
            $0.temperature = 7000
            $0.setTemperature = 7700
            $0.commands = [frame("aa1a00"), frame("aa0502")]
        })
        #expect(heater[.currentTemperature]?.value.doubleValue == 21)
        #expect(heater[.heatingThresholdTemperature]?.value.doubleValue == 25)
        #expect(heater[.targetHeaterCoolerState]?.value == .int(1))
        #expect(fan[.on]?.value == .bool(true))
        #expect(fan[.rotationSpeed]?.value.intValue == 66)
    }

    @Test func heater2SendsMultiSync() async throws {
        let harness = await DeviceHarness(model: "H7131")
        let heater = try #require(await harness.service(.heaterCooler))
        let light = try #require(await harness.service(.lightbulb))
        try await harness.write(heater[.active], 1)
        try await harness.write(heater[.swingMode], 1)
        try await harness.write(light[.on], true)
        #expect(harness.sent.items == [.stateHeat(true), .multiSync(Catalog.heater2SwingCodes["on"]!), .multiSync(Govee.code([0x3A, 0x1B, 0x01, 0x01, 0x01]))])
    }

    @Test func plugAsHeaterReadsItsSourceSensor() async throws {
        let harness = await DeviceHarness(model: "H5080", settings: ["showAs": "heater", "temperatureSource": "11:22:33:44:55:66:77:88"])
        let heater = try #require(await harness.service(.heaterCooler))
        harness.store.setTemperature(17, of: "11:22:33:44:55:66:77:88")
        try await harness.write(heater[.heatingThresholdTemperature], 21)
        try await harness.write(heater[.active], 1)
        // At 20°C until the sensor reports: below the target, so the plug runs.
        #expect(harness.sent.items == [.stateOutlet(true)])
        #expect(await eventually(.seconds(8)) { heater[.currentTemperature]?.value.doubleValue == 17 })
        try await harness.write(heater[.heatingThresholdTemperature], 16)
        #expect(harness.sent.items == [.stateOutlet(true), .stateOutlet(false)])
    }
}

@Suite struct HumidifierTests {
    @Test(arguments: ["H7160", "H7142"]) func speedsAndNightLight(model: String) async throws {
        let harness = await DeviceHarness(model: model)
        let fan = try #require(await harness.service(.fan))
        let light = try #require(await harness.service(.lightbulb))
        try await harness.write(fan[.rotationSpeed], 40)
        #expect(harness.sent.items.first == .ptReal(Catalog.humidifierH7142SpeedCodes[4]!))
        try await harness.write(light[.on], true)
        guard case .ptReal(let code)? = harness.sent.items.last else { Issue.record("no light command"); return }
        #expect(Govee.base64ToHex(code).hasPrefix("331b01"))
    }

    @Test(arguments: ["H7160", "H7142"]) func reports(model: String) async throws {
        let harness = await DeviceHarness(model: model)
        let fan = try #require(await harness.service(.fan))
        let light = try #require(await harness.service(.lightbulb))
        await harness.update(update {
            $0.state = "on"
            $0.commands = [frame("aa050107"), frame("aa1b0132ff0000")]
        })
        #expect(fan[.on]?.value == .bool(true))
        #expect(fan[.rotationSpeed]?.value.intValue == 70)
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.brightness]?.value == .int(50))
        #expect(light[.hue]?.value.intValue == 0)
        #expect(light[.saturation]?.value.intValue == 100)
        // The night light goes off with the humidifier.
        try await harness.write(fan[.on], false)
        #expect(light[.on]?.value == .bool(false))
    }

    @Test func h7142ReportsHumidityAndSwitchesTheUVLightOn() async throws {
        let harness = await DeviceHarness(model: "H7142")
        await harness.update(update { $0.commands = [frame("aa1001" + "0001c2")] })
        #expect(try #require(await harness.service(.humiditySensor))[.currentRelativeHumidity]?.value.doubleValue == 45)
        try await harness.write(try #require(await harness.service(.fan))[.on], true)
        #expect(harness.sent.items == [.stateHumi(true), .ptReal(Catalog.humidifierH7142UvOn)])
        #expect(await DeviceHarness(model: "H7160").service(.humiditySensor) == nil)
    }
}

@Suite struct PurifierTests {
    @Test(arguments: ["H7122", "H7123"]) func speedPowerAndLock(model: String) async throws {
        let harness = await DeviceHarness(model: model)
        let purifier = try #require(await harness.service(.airPurifier))
        try await harness.write(purifier[.rotationSpeed], 60)
        try await harness.write(purifier[.active], 1)
        try await harness.write(purifier[.lockPhysicalControls], 1)
        #expect(harness.sent.items == [.ptReal(Catalog.purifierH7122SpeedCodes[3]!), .statePuri(true), .ptReal(Catalog.lockCodes["on"]!)])
        #expect(purifier[.currentAirPurifierState]?.value == .int(2))
    }

    @Test(arguments: ["H7122", "H7123"]) func reports(model: String) async throws {
        let harness = await DeviceHarness(model: model)
        let purifier = try #require(await harness.service(.airPurifier))
        await harness.update(update {
            $0.state = "on"
            $0.commands = [frame("aa050103"), frame("aa1001"), frame("aa1601")]
        })
        #expect(purifier[.active]?.value == .int(1))
        #expect(purifier[.rotationSpeed]?.value.intValue == 80)
        #expect(purifier[.lockPhysicalControls]?.value == .int(1))
        #expect(purifier[GoveeCharacteristic.displayLight]?.value == .bool(true))
    }

    @Test func airQuality() async throws {
        let h7122 = await DeviceHarness(model: "H7122")
        await h7122.update(update { $0.commands = [frame("aa1c000023")] })
        let air = try #require(await h7122.service(.airQualitySensor))
        #expect(air[.pm2_5Density]?.value.intValue == 35)
        #expect((air[.airQuality]?.value.intValue ?? 0) > 1)
        let h7123 = await DeviceHarness(model: "H7123")
        await h7123.update(update { $0.commands = [frame("aa19000004")] })
        let level = try #require(await h7123.service(.airQualitySensor))
        #expect(level[.pm2_5Density] == nil)
        #expect(level[.airQuality]?.value == .int(5))
        #expect(try #require(await h7123.service(.airPurifier))[GoveeCharacteristic.nightLight] != nil)
    }
}

@Suite struct SensorTests {
    @Test func thermoReadingsInHundredths() async throws {
        let harness = await DeviceHarness(model: "H5179")
        await harness.update(update {
            $0.source = .http
            $0.temperature = 2213
            $0.humidity = 5170
            $0.battery = 15
        })
        #expect(try #require(await harness.service(.temperatureSensor))[.currentTemperature]?.value.doubleValue == 22.1)
        #expect(try #require(await harness.service(.humiditySensor))[.currentRelativeHumidity]?.value.doubleValue == 52)
        let battery = try #require(await harness.service(.battery))
        #expect(battery[.batteryLevel]?.value.intValue == 15)
        #expect(battery[.statusLowBattery]?.value == .int(1))
        #expect(harness.store.temperature(of: "AA:BB:CC:DD:EE:FF:00:11") == 22.13)
        #expect(await harness.services.first?.isPrimary == true)
    }

    @Test func bleReadingsWinOverHTTP() async throws {
        let harness = await DeviceHarness(model: "H5179")
        await harness.update(update {
            $0.source = .ble
            $0.temperature = 2000
        })
        await harness.update(update {
            $0.source = .http
            $0.temperature = 2500
        })
        #expect(try #require(await harness.service(.temperatureSensor))[.currentTemperature]?.value.doubleValue == 20)
    }

    @Test func monitorReadings() async throws {
        let harness = await DeviceHarness(model: "H5106")
        await harness.update(update {
            $0.source = .http
            $0.temperature = 2410
            $0.humidity = 4870
            $0.pm25 = 6
            $0.online = true
        })
        #expect(try #require(await harness.service(.temperatureSensor))[.currentTemperature]?.value.doubleValue == 24.1)
        #expect(try #require(await harness.service(.humiditySensor))[.currentRelativeHumidity]?.value.doubleValue == 49)
        let air = try #require(await harness.service(.airQualitySensor))
        #expect(air[.pm2_5Density]?.value.intValue == 6)
        #expect(air[.airQuality]?.value == .int(1))
    }

    @Test func leakAndPresence() async throws {
        let leak = await DeviceHarness(model: "H5054")
        await leak.update(update {
            $0.leakDetected = true
            $0.battery = 80
        })
        #expect(try #require(await leak.service(.leakSensor))[.leakDetected]?.value == .int(1))
        let presence = await DeviceHarness(model: "H5127")
        await presence.update(update { $0.commands = [frame("aa0101")] })
        #expect(try #require(await presence.service(.occupancySensor))[.occupancyDetected]?.value == .int(1))
    }
}

@Suite struct PlugTests {
    @Test func channelsAreServices() async throws {
        let triple = await DeviceHarness(model: "H5160")
        #expect(await triple.services.filter { $0.type.uuid == ServiceType.switch.uuid }.compactMap(\.subtype) == ["switch1", "switch2", "switch3"])
        let double = await DeviceHarness(model: "H5082", settings: ["showAs": "outlet"])
        try await double.write(try #require(await double.service(.outlet, subtype: "outlet2"))[.on], true)
        #expect(double.sent.items == [.stateDual(34)])
        await double.update(update { $0.stateDual = 51 })
        #expect(try #require(await double.service(.outlet, subtype: "outlet1"))[.on]?.value == .bool(true))
    }

    @Test func showAsPicksThePresentation() async throws {
        #expect(await DeviceHarness(model: "H5080", settings: ["showAs": "tap"]).service(.valve)?[.valveType]?.value == .int(3))
        #expect(await DeviceHarness(model: "H5080", settings: ["showAs": "valve"]).service(.valve)?[.setDuration]?.value == .int(120))
        #expect(await DeviceHarness(model: "H5080", settings: ["showAs": "purifier"]).service(.airPurifier) != nil)
        #expect(await DeviceHarness(model: "H5080", settings: ["showAs": "audio"]).device.category == .audioReceiver)
        let outlet = await DeviceHarness(model: "H5086", settings: ["showAs": "outlet"])
        let service = try #require(await outlet.service(.outlet))
        await outlet.update(update { $0.commands = [frame("aa19" + "000000000000" + "5a00" + "0064" + "001388")] })
        #expect(service[EveCharacteristic.voltage]?.value.doubleValue == 230)
        #expect(service[EveCharacteristic.electricCurrent]?.value.doubleValue == 1)
        #expect(service[EveCharacteristic.currentConsumption]?.value.intValue == 50)
    }

    @Test func kettleModesBoil() async throws {
        let harness = await DeviceHarness(model: "H7170", settings: ["hideModeCoffee": true, "showCustomMode1": true])
        let names = await harness.services.compactMap(\.subtype)
        #expect(names == ["greenTea", "oolongTea", "blackTeaBoil", "customMode1"])
        try await harness.write(try #require(await harness.service(.switch, subtype: "greenTea"))[.on], true)
        #expect(harness.sent.items == [.ptReal(Catalog.kettleModeCodes["greenTea"]!), .ptReal(Catalog.kettleModeCodes["boil"]!)])
    }

    @Test func unknownModelsHaveNoHandler() async {
        let environment = DeviceEnvironment(
            info: DeviceInfo(id: "X", model: "HZZZZ", name: "X"), settings: DeviceSettings(), platform: GoveePlugin.Configuration([:]), transports: TransportFlags(),
            send: { _ in }, logger: testLogger, deviceLogging: false, debugLogging: false, cached: nil, store: memoryStore(), historyDirectory: nil,
            adaptiveLighting: nil)
        #expect(await GoveeDevice.make(model: "HZZZZ", environment: environment) == nil)
        #expect(await GoveeDevice.make(model: "H1162", environment: environment) is TemplateDevice)
    }
}

@Suite struct DeviceStorageTests {
    /// A thermo-hygrometer's temperature, which heaters and coolers follow, is saved at once; a failure is logged
    /// as the Homebridge plugin's `storageWriteErr`.
    @Test func aTemperatureThatCannotBeSavedIsLogged() async throws {
        let recorder = LogRecorder()
        let store = DeviceStore(url: URL(fileURLWithPath: "/dev/null/device-state.json"), autosave: nil)
        let harness = await DeviceHarness(model: "H5179", store: store, logger: recorder.logger)
        await harness.update(update { $0.temperature = 2213 })
        #expect(recorder.contains("[Test] could not save accessory to file as"))
    }

    @Test func aTemperatureIsSavedAtOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("govee-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = await DeviceHarness(model: "H5179", store: DeviceStore(url: url, autosave: nil))
        await harness.update(update { $0.temperature = 2213 })
        #expect(DeviceStore(url: url, autosave: nil).temperature(of: "AA:BB:CC:DD:EE:FF:00:11") == 22.13)
    }
}
