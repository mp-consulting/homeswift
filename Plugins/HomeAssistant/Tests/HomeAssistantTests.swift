import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftHomeAssistant

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A host with one block whose plugin talks to `server`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-HomeAssistant-tests-\(UUID().uuidString)")
    let server = FakeHomeAssistant()
    private let plugins = NIOLockedValueBox<[HomeAssistantPlugin]>([])
    private let hostBox = NIOLockedValueBox<PluginHost?>(nil)

    var plugin: HomeAssistantPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: HomeAssistantPlugin.Dependencies {
        var dependencies = HomeAssistantPlugin.Dependencies()
        let server = self.server
        dependencies.connect = { url, _ in server.connect(url) }
        dependencies.browse = { _ in [HomeAssistantPlugin.Announcement(name: "Home", uuid: "abc123", url: "http://192.0.2.10:8123", version: "2026.12.0")] }
        dependencies.backoff = Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
        dependencies.momentaryReset = .milliseconds(100)
        dependencies.resyncDelay = .milliseconds(30)
        dependencies.notRunningRetry = .milliseconds(200)
        return dependencies
    }

    func start(_ settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: HomeAssistantPlugin.platform, name: HomeAssistantPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(HomeAssistantPlugin.Configuration.self, from: json)
            let plugin = HomeAssistantPlugin(configuration: configuration, context: context, dependencies: self.dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        var all: [String: Any] = ["url": "http://192.0.2.10:8123", "accessToken": "good-token"]
        all.merge(settings) { $1 }
        let block = try HomeswiftConfiguration.Platform(platform: HomeAssistantPlugin.platform, name: HomeAssistantPlugin.name, settings: all)
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry,
                                  storageDirectory: directory, options: options)
        try await host.start()
        hostBox.withLockedValue { $0 = host }
        return host
    }

    func accessory(_ id: String, in host: PluginHost) -> Accessory? {
        host.mainBridge.server.accessories.first { $0.id == HomeAssistantPlugin.accessoryID(deviceID: id) }
    }

    /// Waits for the accessory of a Device Id.
    func waitFor(_ id: String, in host: PluginHost) async throws -> Accessory {
        #expect(await eventually { self.accessory(id, in: host) != nil }, "no accessory \(id)")
        return try #require(accessory(id, in: host))
    }
}

/// The Function of an entity on its accessory, by its registry id.
func service(_ accessory: Accessory, _ type: ServiceType, _ key: String) -> Service? {
    accessory.service(type, subtype: key)
}

@Suite(.timeLimit(.minutes(1)))
struct HomeAssistantTests {
    let environment = TestEnvironment()
    var server: FakeHomeAssistant { environment.server }

    // MARK: Configuration and addresses

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(HomeAssistantPlugin.Configuration.self, from: Data(#"{"platform":"HomeAssistant"}"#.utf8))
        let settings = Settings(configuration.block)
        #expect(settings.url == nil)
        #expect(settings.domains == EntityFunctions.domains)
        #expect(settings.verifyTLS)
        let mirrored = Settings(["mirror": "all", "domains": ["light", "nonsense"], "lockPasscode": "1234"])
        #expect(mirrored.mirrorAll)
        #expect(mirrored.domains == ["light"])
        #expect(mirrored.lockCode == "1234")
        #expect(Settings(["mirror": ["light.*"]]).isMirrored("light.kitchen"))
        #expect(!Settings(["mirror": ["light.*"]]).isMirrored("switch.kitchen"))
    }

    @Test func addressesBecomeWebSocketURLs() {
        #expect(HomeAssistantURL.webSocket("http://homeassistant.local:8123")?.absoluteString == "ws://homeassistant.local:8123/api/websocket")
        #expect(HomeAssistantURL.webSocket("https://ha.example.com/")?.absoluteString == "wss://ha.example.com/api/websocket")
        #expect(HomeAssistantURL.webSocket("192.0.2.10")?.absoluteString == "ws://192.0.2.10:8123/api/websocket")
        #expect(HomeAssistantURL.webSocket("ftp://nope") == nil)
    }

    @Test func globsMatchEntityIDs() {
        #expect(Glob.matches("sensor.*_battery", "sensor.door_battery"))
        #expect(Glob.matches("light.k?tchen", "light.kitchen"))
        #expect(!Glob.matches("sensor.*_battery", "sensor.door_power"))
    }

    // MARK: The session

    @Test func authenticatesAndReadsEverything() async throws {
        server.addDevice("dev-light", name: "Kitchen light", mac: "aa:bb:cc:dd:ee:ff", area: "kitchen")
        server.addArea("kitchen", name: "Kitchen")
        server.add("light.kitchen", state: "on", attributes: ["friendly_name": "Kitchen", "supported_color_modes": ["brightness"], "brightness": 255],
                   registryID: "reg-light", device: "dev-light")
        let host = try await environment.start()
        let accessory = try await environment.waitFor("dev-light", in: host)
        #expect(accessory.information[.serialNumber]?.value == .string("AABBCCDDEEFF"))
        #expect(accessory.information[.manufacturer]?.value == .string("Acme"))
        #expect(accessory.information[.firmwareRevision]?.value == .string("1.2.3"))
        #expect(accessory.suggestedRoom == "Kitchen")
        let light = try #require(service(accessory, .lightbulb, "demo.reg-light"))
        #expect(light.isPrimary)
        #expect(light[.brightness]?.value == .int(100))
        let sent = try #require(server.socket).sentText
        #expect(sent.first?.contains(#""access_token":"good-token""#) == true)
        #expect(sent.contains { $0.contains(#""type":"subscribe_events""#) && $0.contains("state_changed") })
        await host.stop()
    }

    @Test func aRefusedTokenIsNotRetried() async throws {
        server.setToken("other")
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.context.accountRefusal != nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connections == 1)
        await host.stop()
    }

    @Test func aDroppedConnectionShowsNoResponseThenReconnects() async throws {
        server.add("switch.fan", state: "on", attributes: ["friendly_name": "Fan"], registryID: "reg-sw")
        let host = try await environment.start()
        let accessory = try await environment.waitFor("entity:reg-sw", in: host)
        #expect(!accessory.isUnavailable)
        server.socket?.drop()
        #expect(await eventually { accessory.isUnavailable || self.server.connections > 1 })
        #expect(await eventually { self.server.connections == 2 })
        #expect(await eventually { !(self.environment.accessory("entity:reg-sw", in: host)?.isUnavailable ?? true) })
        await host.stop()
    }

    @Test func coalescedFramesAreRead() async throws {
        server.add("switch.a", state: "off", attributes: ["friendly_name": "A"], registryID: "reg-a")
        server.add("switch.b", state: "off", attributes: ["friendly_name": "B"], registryID: "reg-b")
        let host = try await environment.start()
        let a = try await environment.waitFor("entity:reg-a", in: host)
        let b = try await environment.waitFor("entity:reg-b", in: host)
        let socket = try #require(server.socket)
        let subscription = try #require(socket.sentText.compactMap { try? JSONValue(string: $0) }.first { $0["event_type"] == "state_changed" }?["id"]?.intValue)
        func event(_ id: String, _ name: String) -> String {
            #"{"id":\#(subscription),"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"\#(id)","new_state":{"entity_id":"\#(id)","state":"on","attributes":{"friendly_name":"\#(name)"},"last_updated":"2026-11-07T11:00:00+00:00"}}}}"#
        }
        socket.receive(text: "[" + event("switch.a", "A") + "," + event("switch.b", "B") + "]")
        #expect(await eventually { a.service(.switch)?[.on]?.value == .bool(true) && b.service(.switch)?[.on]?.value == .bool(true) })
        await host.stop()
    }

    // MARK: Mapping and conversions (section 7, vectors of section 10)

    @Test func lightsConvertBrightnessAndColorTemperature() async throws {
        server.add("light.desk", state: "on", attributes: [
            "friendly_name": "Desk", "supported_color_modes": ["color_temp", "hs"], "color_mode": "color_temp", "brightness": 128, "color_temp_kelvin": 2700,
        ], registryID: "reg-desk")
        let host = try await environment.start()
        let accessory = try await environment.waitFor("entity:reg-desk", in: host)
        let light = try #require(service(accessory, .lightbulb, "demo.reg-desk"))
        #expect(light[.brightness]?.value == .int(50))
        #expect(light[.colorTemperature]?.value == .int(370))
        #expect(light[.colorTemperature]?.type.minValue == 153)
        #expect(light[.colorTemperature]?.type.maxValue == 500)
        #expect(light[.hue] != nil)
        #expect(light.adaptiveLighting != nil)
        server.change("light.desk", state: "on", attributes: ["friendly_name": "Desk", "supported_color_modes": ["color_temp", "hs"], "color_mode": "color_temp", "brightness": 1, "color_temp_kelvin": 2700])
        #expect(await eventually { light[.brightness]?.value == .int(1) })

        // One call for a batch of writes (section 6).
        async let brightness: Void = light.characteristic(.brightness).write(.int(30))
        async let on: Void = light.characteristic(.on).write(.bool(true))
        _ = try await (brightness, on)
        #expect(server.calls == [.init(domain: "light", service: "turn_on", data: ["brightness_pct": 30], entityID: "light.desk")])
        try await light.characteristic(.colorTemperature).write(.int(370))
        #expect(server.calls.last == .init(domain: "light", service: "turn_on", data: ["color_temp_kelvin": 2702], entityID: "light.desk"))
        try await light.characteristic(.on).write(.bool(false))
        #expect(server.calls.last == .init(domain: "light", service: "turn_off", data: [:], entityID: "light.desk"))
        await host.stop()
    }

    @Test func aStateChangeReachesHomeKit() async throws {
        server.add("light.hall", state: "off", attributes: ["friendly_name": "Hall", "supported_color_modes": ["onoff"]], registryID: "reg-hall")
        let host = try await environment.start()
        let accessory = try await environment.waitFor("entity:reg-hall", in: host)
        let on = try #require(service(accessory, .lightbulb, "demo.reg-hall")?[.on])
        #expect(on.value == .bool(false))
        server.change("light.hall", state: "on", attributes: ["friendly_name": "Hall", "supported_color_modes": ["onoff"]])
        #expect(await eventually { on.value == .bool(true) })
        // unavailable: No Response, values kept.
        server.change("light.hall", state: "unavailable", attributes: ["friendly_name": "Hall", "supported_color_modes": ["onoff"]])
        #expect(await eventually { accessory.isUnavailable })
        #expect(on.value == .bool(true))
        await host.stop()
    }

    @Test func coversMapPositionTiltAndGarageDoors() async throws {
        server.add("cover.blind", state: "open", attributes: [
            "friendly_name": "Blind", "supported_features": 140, "current_position": 40, "current_tilt_position": 50,
        ], registryID: "reg-blind")
        server.add("cover.garage", state: "closed", attributes: ["friendly_name": "Garage", "device_class": "garage", "supported_features": 3], registryID: "reg-garage")
        let host = try await environment.start()
        let blind = try #require(service(try await environment.waitFor("entity:reg-blind", in: host), .windowCovering, "demo.reg-blind"))
        #expect(await eventually { blind[.currentPosition]?.value == .int(40) && blind[.targetPosition]?.value == .int(40) })
        #expect(blind[.currentHorizontalTiltAngle]?.value == .int(0))
        #expect(blind[.holdPosition] != nil)
        try await blind.characteristic(.targetHorizontalTiltAngle).write(.int(45))
        #expect(server.calls.last == .init(domain: "cover", service: "set_cover_tilt_position", data: ["tilt_position": 75], entityID: "cover.blind"))
        try await blind.characteristic(.targetPosition).write(.int(80))
        #expect(server.calls.last == .init(domain: "cover", service: "set_cover_position", data: ["position": 80], entityID: "cover.blind"))
        server.change("cover.blind", state: "closing", attributes: ["friendly_name": "Blind", "supported_features": 140, "current_position": 30, "current_tilt_position": 0])
        #expect(await eventually { blind[.positionState]?.value == .int(0) && blind[.currentHorizontalTiltAngle]?.value == .int(-90) })

        let garage = try #require(service(try await environment.waitFor("entity:reg-garage", in: host), .garageDoorOpener, "demo.reg-garage"))
        #expect(garage[.currentDoorState]?.value == .int(1))
        #expect(garage[.targetDoorState]?.isSecurityControl == true)
        try await garage.characteristic(.targetDoorState).write(.int(0))
        #expect(server.calls.last == .init(domain: "cover", service: "open_cover", data: [:], entityID: "cover.garage"))
        #expect(garage[.currentDoorState]?.value == .int(2))
        await host.stop()
    }

    @Test func climateConvertsFahrenheitAndModes() async throws {
        server.setFahrenheit()
        server.add("climate.living", state: "heat", attributes: [
            "friendly_name": "Living", "hvac_modes": ["off", "heat", "cool", "heat_cool"], "hvac_action": "heating", "current_temperature": 70,
            "temperature": 68, "min_temp": 45, "max_temp": 95, "supported_features": 1,
        ], registryID: "reg-climate")
        let host = try await environment.start()
        let thermostat = try #require(service(try await environment.waitFor("entity:reg-climate", in: host), .thermostat, "demo.reg-climate"))
        #expect(thermostat[.currentTemperature]?.value == .double(21.1))
        #expect(thermostat[.targetTemperature]?.value == .double(20))
        #expect(thermostat[.temperatureDisplayUnits]?.value == .int(1))
        #expect(thermostat[.targetHeatingCoolingState]?.value == .int(1))
        #expect(thermostat[.currentHeatingCoolingState]?.value == .int(1))
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1, 2, 3])
        try await thermostat.characteristic(.targetHeatingCoolingState).write(.int(3))
        #expect(server.calls.last == .init(domain: "climate", service: "set_hvac_mode", data: ["hvac_mode": "heat_cool"], entityID: "climate.living"))
        try await thermostat.characteristic(.targetTemperature).write(.double(22))
        #expect(server.calls.last == .init(domain: "climate", service: "set_temperature", data: ["temperature": 71.6], entityID: "climate.living"))
        #expect(ClimateFunction.modes(["off", "heat", "auto", "heat_cool", "dry", "cool"]) == [0: "off", 1: "heat", 3: "heat_cool", 2: "cool"])
        await host.stop()
    }

    @Test func locksAndAlarmsAreSecurityControls() async throws {
        server.add("lock.front", state: "jammed", attributes: ["friendly_name": "Front"], registryID: "reg-lock")
        server.add("alarm_control_panel.home", state: "armed_vacation", attributes: ["friendly_name": "Alarm", "supported_features": 34], registryID: "reg-alarm")
        let host = try await environment.start(["lockPasscode": "4321"])
        let lock = try #require(service(try await environment.waitFor("entity:reg-lock", in: host), .lockMechanism, "demo.reg-lock"))
        #expect(lock[.lockCurrentState]?.value == .int(2))
        #expect(lock[.lockTargetState]?.isSecurityControl == true)
        try await lock.characteristic(.lockTargetState).write(.int(1))
        #expect(server.calls.last == .init(domain: "lock", service: "lock", data: ["code": "4321"], entityID: "lock.front"))
        let alarm = try #require(service(try await environment.waitFor("entity:reg-alarm", in: host), .securitySystem, "demo.reg-alarm"))
        #expect(alarm[.securitySystemCurrentState]?.value == .int(1))
        #expect(alarm[.securitySystemTargetState]?.value == .int(1))
        #expect(alarm[.securitySystemTargetState]?.type.validValues == [1, 3])
        #expect(alarm[.securitySystemTargetState]?.isSecurityControl == true)
        try await alarm.characteristic(.securitySystemTargetState).write(.int(3))
        #expect(server.calls.last == .init(domain: "alarm_control_panel", service: "alarm_disarm", data: [:], entityID: "alarm_control_panel.home"))
        await host.stop()
    }

    @Test func sensorsAndBinarySensorsAndBattery() async throws {
        server.addDevice("dev-air", name: "Air monitor")
        server.add("sensor.air_pm25", state: "12", attributes: ["friendly_name": "PM2.5", "device_class": "pm25", "unit_of_measurement": "µg/m³"], registryID: "reg-pm", device: "dev-air")
        server.add("sensor.air_co2", state: "1001", attributes: ["friendly_name": "CO2", "device_class": "carbon_dioxide", "unit_of_measurement": "ppm"], registryID: "reg-co2", device: "dev-air")
        server.add("sensor.air_temperature", state: "70", attributes: ["friendly_name": "Temperature", "device_class": "temperature", "unit_of_measurement": "°F"], registryID: "reg-t", device: "dev-air")
        server.add("sensor.air_battery", state: "15", attributes: ["friendly_name": "Battery", "device_class": "battery", "unit_of_measurement": "%"],
                   registryID: "reg-bat", device: "dev-air", category: "diagnostic")
        server.add("sensor.air_signal", state: "-60", attributes: ["friendly_name": "Signal", "device_class": "signal_strength"], registryID: "reg-sig", device: "dev-air", category: "diagnostic")
        server.add("binary_sensor.door", state: "on", attributes: ["friendly_name": "Door", "device_class": "door"], registryID: "reg-door")
        server.add("binary_sensor.online", state: "on", attributes: ["friendly_name": "Online", "device_class": "connectivity"], registryID: "reg-online")
        let host = try await environment.start()
        let air = try await environment.waitFor("dev-air", in: host)
        let pm = try #require(service(air, .airQualitySensor, "demo.reg-pm"))
        #expect(pm[.pm2_5Density]?.value == .double(12))
        #expect(pm[.airQuality]?.value == .int(2))
        let co2 = try #require(service(air, .carbonDioxideSensor, "demo.reg-co2"))
        #expect(co2[.carbonDioxideDetected]?.value == .int(1))
        #expect(service(air, .temperatureSensor, "demo.reg-t")?[.currentTemperature]?.value == .double(21.1))
        let battery = try #require(air.service(.battery))
        #expect(battery[.batteryLevel]?.value == .int(15))
        #expect(battery[.statusLowBattery]?.value == .int(1))
        #expect(air.services.count == 5)   // information, three sensors, battery
        let door = try #require(service(try await environment.waitFor("entity:reg-door", in: host), .contactSensor, "demo.reg-door"))
        #expect(door[.contactSensorState]?.value == .int(1))
        #expect(environment.accessory("entity:reg-online", in: host) == nil)
        await host.stop()
    }

    @Test func switchesScenesScriptsAndFans() async throws {
        server.add("switch.plug", state: "on", attributes: ["friendly_name": "Plug", "device_class": "outlet"], registryID: "reg-plug")
        server.add("scene.movie", state: "2026-11-07T10:00:00+00:00", attributes: ["friendly_name": "Movie"], registryID: "reg-scene")
        server.add("script.good_night", state: "off", attributes: ["friendly_name": "Good night"], registryID: "reg-script")
        server.add("fan.ceiling", state: "on", attributes: ["friendly_name": "Ceiling", "supported_features": 3, "percentage": 0, "percentage_step": 25, "oscillating": true], registryID: "reg-fan")
        server.add("media_player.tv", state: "playing", attributes: ["friendly_name": "TV", "supported_features": 384], registryID: "reg-tv")
        server.add("weather.home", state: "sunny", attributes: ["friendly_name": "Weather"], registryID: "reg-weather")
        let host = try await environment.start()
        let plug = try #require(service(try await environment.waitFor("entity:reg-plug", in: host), .outlet, "demo.reg-plug"))
        #expect(plug[.on]?.value == .bool(true))
        try await plug.characteristic(.on).write(.bool(false))
        #expect(server.calls.last == .init(domain: "switch", service: "turn_off", data: [:], entityID: "switch.plug"))

        let scene = try #require(service(try await environment.waitFor("entity:reg-scene", in: host), .switch, "demo.reg-scene"))
        try await scene.characteristic(.on).write(.bool(true))
        #expect(server.calls.last == .init(domain: "scene", service: "turn_on", data: [:], entityID: "scene.movie"))
        #expect(await eventually { scene[.on]?.value == .bool(false) })

        let script = try #require(service(try await environment.waitFor("entity:reg-script", in: host), .switch, "demo.reg-script"))
        try await script.characteristic(.on).write(.bool(true))
        #expect(server.calls.last == .init(domain: "script", service: "good_night", data: [:], entityID: nil))

        let fan = try #require(service(try await environment.waitFor("entity:reg-fan", in: host), .fanv2, "demo.reg-fan"))
        #expect(fan[.active]?.value == .int(1))
        #expect(fan[.rotationSpeed]?.value == .double(25))
        #expect(fan[.swingMode]?.value == .int(1))
        async let speed: Void = fan.characteristic(.rotationSpeed).write(.double(50))
        async let active: Void = fan.characteristic(.active).write(.int(1))
        _ = try await (speed, active)
        #expect(server.calls.last == .init(domain: "fan", service: "set_percentage", data: ["percentage": 50], entityID: "fan.ceiling"))

        let tv = try #require(service(try await environment.waitFor("entity:reg-tv", in: host), .switch, "demo.reg-tv"))
        #expect(tv[.on]?.value == .bool(true))
        #expect(environment.accessory("entity:reg-weather", in: host) == nil)
        await host.stop()
    }

    // MARK: Identity

    @Test func aRenamedEntityKeepsItsAccessoryAndIids() async throws {
        server.addDevice("dev-lamp", name: "Lamp")
        server.add("light.lamp", state: "on", attributes: ["friendly_name": "Lamp", "supported_color_modes": ["onoff"]], registryID: "reg-lamp", device: "dev-lamp")
        let host = try await environment.start()
        let before = try await environment.waitFor("dev-lamp", in: host)
        let aid = before.aid
        let iid = try #require(service(before, .lightbulb, "demo.reg-lamp")).iid
        let onIID = try #require(service(before, .lightbulb, "demo.reg-lamp")?[.on]).iid
        server.rename("light.lamp", to: "light.reading_lamp")
        // Rebuilt, with the same ids, and writes go to the new entity id.
        #expect(await eventually { (try? await self.writeTargets("dev-lamp", host)) == "light.reading_lamp" })
        let after = try #require(environment.accessory("dev-lamp", in: host))
        #expect(after.aid == aid)
        #expect(service(after, .lightbulb, "demo.reg-lamp")?.iid == iid)
        #expect(service(after, .lightbulb, "demo.reg-lamp")?[.on]?.iid == onIID)
        await host.stop()
    }

    /// Writes On and answers the entity id the call targeted.
    func writeTargets(_ deviceID: String, _ host: PluginHost) async throws -> String? {
        guard let on = environment.accessory(deviceID, in: host).flatMap({ service($0, .lightbulb, "demo.reg-lamp")?[.on] }) else { return nil }
        try await on.write(.bool(false))
        return server.calls.last?.entityID
    }

    @Test func withoutRegistriesEachEntityIsItsOwnAccessory() async throws {
        server.denyRegistries()
        server.add("switch.porch", state: "off", attributes: ["friendly_name": "Porch"])
        let host = try await environment.start()
        let accessory = try await environment.waitFor("state:switch.porch", in: host)
        #expect(service(accessory, .switch, "switch.porch") != nil)
        await host.stop()
    }

    @Test func hiddenAndDiagnosticEntitiesAreLeftOutUnlessIncluded() async throws {
        server.add("switch.hidden", state: "on", attributes: ["friendly_name": "Hidden"], registryID: "reg-hidden", hidden: "user")
        server.add("switch.config", state: "on", attributes: ["friendly_name": "Config"], registryID: "reg-config", category: "config")
        server.add("switch.excluded", state: "on", attributes: ["friendly_name": "Excluded"], registryID: "reg-excluded")
        server.add("switch.visible", state: "on", attributes: ["friendly_name": "Visible"], registryID: "reg-visible")
        let host = try await environment.start(["includeEntities": ["switch.config"], "excludeEntities": ["switch.excl*"]])
        _ = try await environment.waitFor("entity:reg-visible", in: host)
        _ = try await environment.waitFor("entity:reg-config", in: host)
        #expect(environment.accessory("entity:reg-hidden", in: host) == nil)
        #expect(environment.accessory("entity:reg-excluded", in: host) == nil)
        await host.stop()
    }

    // MARK: Loops and mirrors (section 9)

    @Test func thisBridgesOwnAccessoriesComingBackAreSkipped() async throws {
        server.add("switch.first", state: "on", attributes: ["friendly_name": "First"], registryID: "reg-first")
        let host = try await environment.start()
        _ = try await environment.waitFor("entity:reg-first", in: host)
        let ownID = host.mainBridge.server.deviceID
        server.add("light.echo", state: "on", attributes: ["friendly_name": "Echo", "supported_color_modes": ["onoff"]],
                   registryID: "reg-echo", uniqueID: "\(ownID.lowercased())_2_10", platform: "homekit_controller")
        server.add("light.ecobee", state: "on", attributes: ["friendly_name": "Ecobee", "supported_color_modes": ["onoff"]],
                   registryID: "reg-ecobee", uniqueID: "11:22:33:44:55:66_1_10", platform: "homekit_controller")
        server.registryChanged()
        _ = try await environment.waitFor("entity:reg-ecobee", in: host)
        #expect(environment.accessory("entity:reg-echo", in: host) == nil)
        await host.stop()
    }

    @Test func mirroredEntitiesStayOutOfHomeKit() async throws {
        server.addDevice("dev-room", name: "Room")
        server.add("light.room", state: "on", attributes: ["friendly_name": "Room light", "supported_color_modes": ["onoff"]], registryID: "reg-room-light", device: "dev-room")
        server.add("switch.room", state: "on", attributes: ["friendly_name": "Room switch"], registryID: "reg-room-switch", device: "dev-room")
        server.add("switch.other", state: "on", attributes: ["friendly_name": "Other"], registryID: "reg-other")
        let host = try await environment.start(["mirror": ["light.room", "switch.other"]])
        let published = try await environment.waitFor("dev-room", in: host)
        #expect(published.mirroredFrom == nil)
        #expect(service(published, .switch, "demo.reg-room-switch") != nil)
        let mirroredPart = try await environment.waitFor("dev-room:mirrored", in: host)
        #expect(mirroredPart.mirroredFrom == "Home Assistant")
        #expect(service(mirroredPart, .lightbulb, "demo.reg-room-light") != nil)
        let other = try await environment.waitFor("entity:reg-other", in: host)
        #expect(other.mirroredFrom == "Home Assistant")
        await host.stop()
    }

    // MARK: Setup

    @Test func setupChecksTheTokenAndKeepsItInTheVault() async throws {
        let host = try await environment.start(["url": NSNull(), "accessToken": NSNull()])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, let state) = first else { Issue.record("expected a prompt"); return }
        #expect(prompt.fields.map(\.key) == ["server", "url", "accessToken"])
        await #expect(throws: SetupError.self) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["server": "http://192.0.2.10:8123", "accessToken": "wrong"], state: state))
        }
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["server": "http://192.0.2.10:8123", "accessToken": "good-token"], state: state))
        guard case .done(let outcome) = done else { Issue.record("expected done"); return }
        #expect(outcome.credentials?["accessToken"] == "good-token")
        #expect(outcome.settings["url"] == "http://192.0.2.10:8123")
        #expect(outcome.settings["serverId"] == "abc123")
        await host.stop()
    }

    @Test func discoveryListsDevicesWithTheirEntitiesAsParts() async throws {
        server.addDevice("dev-multi", name: "Multi")
        server.add("switch.multi_one", state: "on", attributes: ["friendly_name": "One"], registryID: "reg-one", device: "dev-multi")
        server.add("switch.multi_two", state: "on", attributes: ["friendly_name": "Two"], registryID: "reg-two", device: "dev-multi", category: "config")
        let host = try await environment.start()
        _ = try await environment.waitFor("dev-multi", in: host)
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        let multi = try #require(found.first { $0.deviceID == "dev-multi" })
        #expect(multi.parts.map(\.id).sorted() == ["demo.reg-one", "demo.reg-two"])
        #expect(multi.parts.first { $0.id == "demo.reg-two" }?.included == false)
        await host.stop()
    }

    // MARK: The schema

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(HomeAssistantPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/HomeAssistant HomeAssistantPlugin")
        let schema = try JSONValue(string: try #require(HomeAssistantPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "HomeAssistant")
    }
}
