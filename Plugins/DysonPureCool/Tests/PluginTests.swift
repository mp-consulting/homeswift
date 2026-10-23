import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftDysonPureCool

let serial = "ABC-AB-12345678"
let accessoryID = "DysonPureCool:ABC-AB-12345678"

func deviceBlock(_ productType: String = "438", ip: String? = "192.168.1.50", extra: [String: Any] = [:]) -> [String: Any] {
    var device: [String: Any] = ["serial": serial, "name": "Living Room", "productType": productType, "localCredentials": "secret"]
    if let ip { device["ipAddress"] = ip }
    device.merge(extra) { _, new in new }
    return device
}

/// The Homebridge plugin's platform, platformAccessory, dysonLinkAccessory and service tests, end to end on a
/// bridge with the in-memory device.
@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    func accessory(_ host: PluginHost) throws -> Accessory {
        try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
    }

    func subtypes(_ accessory: Accessory) -> [String] {
        accessory.services.compactMap(\.subtype).sorted()
    }

    @Test func aPureCool() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.tp04)
        let host = try await environment.start(settings: ["devices": [deviceBlock()], "enableFilterStatus": true])
        defer { Task { await host.stop() } }
        let accessory = try accessory(host)
        #expect(accessory.name == "Living Room")
        #expect(accessory.category == .airPurifier)
        #expect(accessory.information[.manufacturer]?.value == .string("Dyson"))
        #expect(accessory.information[.model]?.value == .string("Dyson Pure Cool Tower (TP04)"))
        #expect(accessory.information[.serialNumber]?.value == .string(serial))
        #expect(subtypes(accessory) == ["air-purifier", "air-quality-sensor", "filter-maintenance", "humidity-sensor", "jet-focus", "night-mode", "temperature-sensor"])
        let purifier = try #require(accessory.service(.airPurifier))
        #expect(purifier.isPrimary)
        #expect(purifier.linked.count == 6)

        #expect(await eventually { purifier[.active]?.value == .int(1) })
        #expect(purifier[.currentAirPurifierState]?.value == .int(2))
        #expect(purifier[.targetAirPurifierState]?.value == .int(0))
        #expect(purifier[.rotationSpeed]?.value == .double(50))
        #expect(purifier[.swingMode]?.value == .int(1))
        #expect(accessory.service(.temperatureSensor)?[.currentTemperature]?.value == .double(22))
        #expect(accessory.service(.humiditySensor)?[.currentRelativeHumidity]?.value == .double(55))
        let air = try #require(accessory.service(.airQualitySensor))
        #expect(air[.airQuality]?.value == .int(1))
        #expect(air[.pm2_5Density]?.value == .double(3))
        #expect(air[.pm10Density]?.value == .double(5))
        #expect(air[.vocDensity]?.value == .double(2))
        #expect(air[.nitrogenDioxideDensity] == nil)
        let filter = try #require(accessory.service(.filterMaintenance))
        #expect(filter[.filterLifeLevel]?.value == .double(56))
        #expect(filter[.filterChangeIndication]?.value == .int(0))
        #expect(accessory.service(.switch, subtype: "jet-focus")?[.on]?.value == .bool(false))
        #expect(accessory.service(.switch, subtype: "night-mode")?[.configuredName]?.value == .string("Night Mode"))

        // HomeKit writes reach the device; its STATE-CHANGE comes back as values.
        environment.dyson.clearPublished()
        try await purifier.characteristic(.targetAirPurifierState).write(.int(1))
        #expect(environment.dyson.commands.last == ["fmod": "AUTO"])
        try await purifier.characteristic(.rotationSpeed).write(.double(70))
        #expect(environment.dyson.commands.last == ["fmod": "FAN", "fnsp": "0007"])
        #expect(await eventually { purifier[.rotationSpeed]?.value == .double(70) })
        try await accessory.service(.switch, subtype: "night-mode")!.characteristic(.on).write(.bool(true))
        #expect(environment.dyson.commands.last == ["nmod": "ON"])
        try await purifier.characteristic(.swingMode).write(.int(0))
        #expect(environment.dyson.commands.last == ["oson": "OFF"])
        try await purifier.characteristic(.active).write(.int(0))
        #expect(environment.dyson.commands.last == ["fmod": "OFF"])
        #expect(await eventually { purifier[.currentAirPurifierState]?.value == .int(0) })

        environment.dyson.sendEnvironment(["tact": "2981", "hact": "0060", "p25r": "0040", "p10r": "0010", "va10": "0030"])
        #expect(await eventually { accessory.service(.temperatureSensor)?[.currentTemperature]?.value == .double(25) })
        #expect(air[.airQuality]?.value == .int(3))
        #expect(accessory.service(.humiditySensor)?[.currentRelativeHumidity]?.value == .double(60))
        #expect(accessory.service(.temperatureSensor)?[.statusActive]?.value == .bool(true))

        // Continuous monitoring off with the fan idle: the sensors report OFF. The last readings stay, marked
        // inactive, until a reading comes back.
        environment.dyson.sendEnvironment(["tact": "OFF", "hact": "OFF", "pact": "0000", "vact": "0005"])
        #expect(await eventually { accessory.service(.temperatureSensor)?[.statusActive]?.value == .bool(false) })
        #expect(accessory.service(.humiditySensor)?[.statusActive]?.value == .bool(false))
        #expect(accessory.service(.temperatureSensor)?[.currentTemperature]?.value == .double(25))
        #expect(accessory.service(.humiditySensor)?[.currentRelativeHumidity]?.value == .double(60))
        environment.dyson.sendEnvironment(["tact": "2971", "hact": "0058"])
        #expect(await eventually { accessory.service(.temperatureSensor)?[.statusActive]?.value == .bool(true) })
        #expect(accessory.service(.humiditySensor)?[.statusActive]?.value == .bool(true))
        #expect(accessory.service(.temperatureSensor)?[.currentTemperature]?.value == .double(24))
    }

    @Test func readsFailWhileDisconnected() async throws {
        let environment = DysonTestEnvironment()
        environment.dyson.set(reachableHosts: [])
        let host = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await host.stop() } }
        let purifier = try #require(try accessory(host).service(.airPurifier))
        let read = try #require(purifier.characteristic(.active).readHandler)
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { _ = try await read() }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await purifier.characteristic(.active).write(.int(1)) }
    }

    @Test func aHotCoolWithBothHeatingServices() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.hp04)
        let host = try await environment.start(settings: ["devices": [deviceBlock("527", extra: ["heatingServiceType": "both", "temperatureOffset": -2])]])
        defer { Task { await host.stop() } }
        let accessory = try accessory(host)
        let thermostat = try #require(accessory.service(.thermostat))
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1])
        #expect(thermostat[.targetTemperature]?.type.minValue == 1)
        #expect(thermostat[.targetTemperature]?.type.maxValue == 37)
        #expect(heater[.targetHeaterCoolerState]?.type.validValues == [1])
        #expect(heater[.heatingThresholdTemperature]?.type.maxValue == 38)
        #expect(await eventually { thermostat[.targetHeatingCoolingState]?.value == .int(1) })
        #expect(thermostat[.targetTemperature]?.value == .double(22))
        #expect(thermostat[.currentTemperature]?.value == .double(17))
        #expect(thermostat[.temperatureDisplayUnits]?.value == .int(0))
        // The temperature sensor carries the offset; the thermostat shows the raw reading.
        #expect(accessory.service(.temperatureSensor)?[.currentTemperature]?.value == .double(15))
        #expect(heater[.active]?.value == .int(1))
        #expect(heater[.currentHeaterCoolerState]?.value == .int(2))
        #expect(heater[.heatingThresholdTemperature]?.value == .double(22))
        #expect(heater[.targetHeaterCoolerState]?.value == .int(1))

        environment.dyson.clearPublished()
        try await thermostat.characteristic(.targetTemperature).write(.double(24))
        #expect(environment.dyson.commands.last == ["hmax": "2972"])
        try await heater.characteristic(.active).write(.int(0))
        #expect(environment.dyson.commands.last == ["hmod": "OFF"])
        try await accessory.service(.airPurifier)!.characteristic(.active).write(.int(0))
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.state.isOn == false })
        // Heater on from off: heating and the fan in one command.
        try await Task.sleep(for: DysonDevice.offGuard)
        try await heater.characteristic(.active).write(.int(1))
        #expect(environment.dyson.commands.last == ["hmod": "HEAT", "fmod": "FAN"])
    }

    @Test func heatingServiceChoices() async throws {
        let thermostatOnly = DysonTestEnvironment(productState: FakeStates.hp04)
        var host = try await thermostatOnly.start(settings: ["devices": [deviceBlock("527")]])
        #expect(try accessory(host).service(.thermostat) != nil)
        #expect(try accessory(host).service(.heaterCooler) == nil)
        await host.stop()
        let heaterOnly = DysonTestEnvironment(productState: FakeStates.hp04)
        host = try await heaterOnly.start(settings: ["devices": [deviceBlock("527", extra: ["heatingServiceType": "heater-cooler"])]])
        #expect(try accessory(host).service(.thermostat) == nil)
        #expect(try accessory(host).service(.heaterCooler) != nil)
        await host.stop()
        let disabled = DysonTestEnvironment(productState: FakeStates.hp04)
        host = try await disabled.start(settings: ["devices": [deviceBlock("527")], "enableHeater": false])
        #expect(try accessory(host).service(.thermostat) == nil)
        await host.stop()
    }

    @Test func aHumidifier() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.ph03)
        let host = try await environment.start(settings: ["devices": [deviceBlock("358H")]])
        defer { Task { await host.stop() } }
        let humidifier = try #require(try accessory(host).service(.humidifierDehumidifier))
        #expect(humidifier[.relativeHumidityHumidifierThreshold]?.type.minValue == 30)
        #expect(humidifier[.relativeHumidityHumidifierThreshold]?.type.maxValue == 70)
        #expect(humidifier[.targetHumidifierDehumidifierState]?.type.validValues == [0, 1])
        #expect(await eventually { humidifier[.active]?.value == .int(1) })
        #expect(humidifier[.relativeHumidityHumidifierThreshold]?.value == .double(50))
        #expect(humidifier[.currentHumidifierDehumidifierState]?.value == .int(2))
        #expect(humidifier[.targetHumidifierDehumidifierState]?.value == .int(1))
        #expect(humidifier[.waterLevel]?.value == .double(100))
        environment.dyson.clearPublished()
        try await humidifier.characteristic(.targetHumidifierDehumidifierState).write(.int(0))
        #expect(environment.dyson.commands.last == ["hume": "AUTO"])
        try await humidifier.characteristic(.relativeHumidityHumidifierThreshold).write(.double(60))
        #expect(environment.dyson.commands.last == ["humt": "0060"])
        try await humidifier.characteristic(.active).write(.int(0))
        #expect(environment.dyson.commands.last == ["hume": "OFF"])
        #expect(await eventually { humidifier[.currentHumidifierDehumidifierState]?.value == .int(0) })

        let full = DysonTestEnvironment(productState: FakeStates.ph03)
        let fullHost = try await full.start(settings: ["devices": [deviceBlock("358H", extra: ["fullRangeHumidity": true])], "enableHumidifier": true])
        defer { Task { await fullHost.stop() } }
        let range = try #require(try accessory(fullHost).service(.humidifierDehumidifier)?[.relativeHumidityHumidifierThreshold]?.type)
        #expect(range.minValue == 0 && range.maxValue == 100)
    }

    @Test func aLinkModelAndAPlainFan() async throws {
        let link = DysonTestEnvironment(productState: ["fpwr": "ON", "fmod": "FAN", "pact": "0003", "vact": "0040", "fnsp": "0002"])
        let host = try await link.start(settings: ["devices": [deviceBlock("475")]])
        defer { Task { await host.stop() } }
        let air = try #require(try accessory(host).service(.airQualitySensor))
        #expect(air[.pm2_5Density] == nil && air[.pm10Density] == nil)
        // pact 3 is Good, vact 40 × 0.125 = 5 is Good.
        #expect(await eventually { air[.airQuality]?.value == .int(2) })
        #expect(try accessory(host).service(.switch, subtype: "jet-focus") == nil)

        let fan = DysonTestEnvironment(productState: ["fpwr": "ON", "fnsp": "0004", "auto": "OFF", "oson": "OFF"])
        let fanHost = try await fan.start(settings: ["devices": [deviceBlock("739")]])
        defer { Task { await fanHost.stop() } }
        let accessory = try accessory(fanHost)
        #expect(subtypes(accessory) == ["air-purifier", "night-mode"])
        #expect(accessory.service(.airPurifier)?[.targetAirPurifierState]?.type.validValues == [0])
    }

    @Test func optionsTakeServicesAway() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.tp09)
        let host = try await environment.start(settings: [
            "devices": [deviceBlock("438K", extra: ["isNightModeEnabled": false, "isContinuousMonitoringEnabled": true, "isTemperatureIgnored": true])],
            "enableHumidity": false, "enableJetFocus": false, "enableFilterStatus": false,
        ])
        defer { Task { await host.stop() } }
        let accessory = try accessory(host)
        #expect(subtypes(accessory) == ["air-purifier", "air-quality-sensor", "continuous-monitoring"])
        let air = try #require(accessory.service(.airQualitySensor))
        #expect(await eventually { air[.nitrogenDioxideDensity]?.value == .double(1) })
        environment.dyson.clearPublished()
        try await accessory.service(.switch, subtype: "continuous-monitoring")!.characteristic(.on).write(.bool(false))
        #expect(environment.dyson.commands.last == ["rhtm": "OFF"])
    }

    @Test func invalidEntriesAreSkipped() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: ["devices": [
            ["name": "No serial", "productType": "438", "localCredentials": "x"],
            ["serial": "AAA-AA-00000001", "productType": "438"],
            ["serial": "AAA-AA-00000002", "productType": "999", "localCredentials": "x", "ipAddress": "192.168.1.9"],
            ["serial": "AAA-AA-00000003", "productType": "438", "credentials": "legacy", "ipAddress": "192.168.1.9"],
        ]])
        defer { Task { await host.stop() } }
        let ids = host.mainBridge.server.accessories.map(\.id)
        #expect(ids.contains("DysonPureCool:AAA-AA-00000003"))
        #expect(!ids.contains("DysonPureCool:AAA-AA-00000001"))
        #expect(!ids.contains("DysonPureCool:AAA-AA-00000002"))
        #expect(environment.dyson.connects.first?.password == "legacy")
    }

    @Test func discoveryFindsTheAddress() async throws {
        let environment = DysonTestEnvironment()
        environment.set(discovered: [serial: "192.168.1.77"])
        let host = try await environment.start(settings: ["devices": [deviceBlock(ip: nil)]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.isConnected == true })
        #expect(environment.dyson.connects.first?.host == "192.168.1.77")
    }

    @Test func aMovedDeviceIsFoundAndRemembered() async throws {
        let environment = DysonTestEnvironment()
        environment.dyson.set(reachableHosts: ["192.168.1.88"])
        environment.set(discovered: [serial: "192.168.1.88"])
        let host = try await environment.start(settings: ["devices": [deviceBlock()]])
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.isConnected == true })
        #expect(environment.dyson.connects.map(\.host).first == "192.168.1.50")
        #expect(await environment.plugin?.device(serial: serial)?.ipAddress == "192.168.1.88")
        await host.stop()

        // The next launch goes to the new address directly, while config.json still says the old one.
        environment.set(discovered: [:])
        let before = environment.dyson.connects.count
        let next = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await next.stop() } }
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.isConnected == true })
        #expect(environment.dyson.connects[before].host == "192.168.1.88")
        let overrides = await environment.plugin?.loadIPOverrides()
        #expect(overrides?[serial] == .init(from: "192.168.1.50", to: "192.168.1.88"))
    }

    @Test func anOfflineDeviceIsRetried() async throws {
        let environment = DysonTestEnvironment()
        environment.offlineRetry = .milliseconds(100)
        environment.dyson.set(reachableHosts: [])
        let host = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.scanCount >= 1 })
        environment.dyson.set(reachableHosts: nil)
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.isConnected == true })

        // A device that drops off and never answers again: the MQTT client gives up, the plugin retries.
        environment.dyson.set(reachableHosts: [])
        environment.dyson.dropConnections()
        #expect(await eventually { await environment.plugin?.device(serial: serial)?.isConnected == false })
        environment.dyson.set(reachableHosts: nil)
        #expect(await eventually(timeout: .seconds(10)) { await environment.plugin?.device(serial: serial)?.isConnected == true })
    }

    @Test func unconfiguredAccessoriesLeave() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: ["devices": [deviceBlock(), ["serial": "XYZ-AB-87654321", "productType": "438", "localCredentials": "s", "ipAddress": "192.168.1.51"]]])
        #expect(host.mainBridge.server.accessories.contains { $0.id == "DysonPureCool:XYZ-AB-87654321" })
        await host.stop()
        let next = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await next.stop() } }
        #expect(!next.mainBridge.server.accessories.contains { $0.id == "DysonPureCool:XYZ-AB-87654321" })
        #expect(next.mainBridge.server.accessories.contains { $0.id == accessoryID })
    }

    @Test func airQualityRatings() {
        var state = DeviceState()
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 0)
        state.pm25 = 12
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 1)
        state.pm25 = 36
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 3)
        state.pm10 = 400
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 5)
        state = DeviceState()
        state.vocIndex = 70
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 4)
        state.no2Index = 90
        #expect(DysonAccessory.airQuality(state, basic: false, no2: false) == 4)
        #expect(DysonAccessory.airQuality(state, basic: false, no2: true) == 5)
        state = DeviceState()
        state.vocIndex = 72
        #expect(DysonAccessory.airQuality(state, basic: true, no2: false) == 0)
        state.pm25 = 1
        #expect(DysonAccessory.airQuality(state, basic: true, no2: false) == 4)
        state.hepaFilterLife = 8
        state.carbonFilterLife = 50
        #expect(DysonAccessory.filterLife(state) == 8)
        state.isOn = true
        state.heatingEnabled = true
        #expect(DysonAccessory.heaterCoolerState(state) == 2)
        state.temperature = 2951
        state.targetTemperature = 2951
        #expect(DysonAccessory.heaterCoolerState(state) == 1)
    }
}

/// The settings page's requests, as the Homebridge UI server's tests.
@Suite(.timeLimit(.minutes(1)))
struct WebRequestTests {
    func request(_ plugin: DysonPureCoolPlugin, _ path: String, _ body: JSONValue = .null) async throws -> PluginWebResponse {
        try await plugin.handleWebRequest(PluginWebRequest(method: body == .null ? "GET" : "POST", path: path, body: body, user: "admin"))
    }

    @Test func signInAndListDevices() async throws {
        let environment = DysonTestEnvironment()
        let credentials = try DysonCloud.encrypt(apPasswordHash: "local-hash")
        environment.cloud.set(manifest: [
            ["serialNumber": .string(serial), "name": "Living Room", "type": "527", "connectedConfiguration": ["mqtt": ["localBrokerCredentials": .string(credentials)]]],
        ])
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)

        #expect(try await request(plugin, "verify-otp", ["otpCode": "123456"]) == .error(400, "No pending authentication"))
        #expect(try await request(plugin, "authenticate", ["email": "bad", "password": "x"]) == .error(400, "A valid email address is required"))
        let started = try await request(plugin, "authenticate", ["email": "user@example.com", "password": "secret", "countryCode": "gb"])
        #expect(started == PluginWebResponse(["success": true, "requires2FA": true]))
        #expect(environment.cloud.requests[1].url.query == "country=GB")
        // A mistyped code can be tried again.
        #expect(try await request(plugin, "verify-otp", ["otpCode": "000000"]) == .error(401, "Invalid verification code"))
        let verified = try await request(plugin, "verify-otp", ["otpCode": "123456"])
        #expect(verified == PluginWebResponse(["success": true, "token": "token-1"]))
        #expect(try await request(plugin, "verify-otp", ["otpCode": "123456"]) == .error(400, "No pending authentication"))

        let listed = try await request(plugin, "get-devices", ["token": "token-1"])
        let device = try #require(listed.json["devices"]?[0])
        #expect(device["serial"] == .string(serial))
        #expect(device["localCredentials"] == "local-hash")
        #expect(device["productName"] == "HP04 - Dyson Pure Hot+Cool")
        #expect(device["hasHeating"] == true)
        #expect(device["hasJetFocus"] == true)
        #expect(device["hasHumidifier"] == false)
        environment.cloud.expire(token: "token-1")
        #expect(try await request(plugin, "get-devices", ["token": "token-1"]) == .error(401, "Session expired"))
        #expect(try await request(plugin, "get-devices", [:]) == .error(400, "Token is required"))
    }

    @Test func aWrongPasswordEndsTheSignIn() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        _ = try await request(plugin, "authenticate", ["email": "user@example.com", "password": "wrong"])
        #expect(try await request(plugin, "verify-otp", ["otpCode": "123456"]) == .error(401, "Unable to authenticate user."))
        #expect(try await request(plugin, "verify-otp", ["otpCode": "123456"]) == .error(400, "No pending authentication"))
        #expect(try await request(plugin, "authenticate", ["email": "nobody@example.com", "password": "x"]) == .error(401, "Account not active or not found"))
    }

    @Test func productTypes() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let answer = try await request(try #require(environment.plugin), "get-product-types")
        #expect(answer.json["productTypes"]?["438"] == "TP04 - Dyson Pure Cool Tower")
        #expect(answer.json["heatingProductTypes"]?.arrayValue?.contains("455") == true)
        #expect(answer.json["jetFocusProductTypes"]?.arrayValue?.contains("438M") == false)
    }

    @Test func deviceStateOverAOneOffConnection() async throws {
        let environment = DysonTestEnvironment(productState: ["rhtm": "OFF"])
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let device: [String: JSONValue] = ["serial": .string(serial), "productType": "438", "localCredentials": "secret"]

        #expect(try await request(plugin, "get-device-state", ["serial": .string(serial)]) == .error(400, "Missing device info (serial, productType, localCredentials)"))
        #expect(try await request(plugin, "get-device-state", .object(device.merging(["ipAddress": "example.com"]) { $1 })) == .error(400, "ipAddress must be a valid IPv4 address"))
        #expect(try await request(plugin, "get-device-state", .object(device)) == .error(404, "Device \(serial) not found on network"))

        environment.set(discovered: [serial: "192.168.1.60"])
        let state = try await request(plugin, "get-device-state", .object(device))
        #expect(state == PluginWebResponse(["success": true, "continuousMonitoring": false, "discoveredIp": "192.168.1.60"]))
        #expect(environment.dyson.openConnections.isEmpty)

        // The saved address no longer answers: mDNS finds the device, and the page saves the new address.
        environment.dyson.set(reachableHosts: ["192.168.1.60"])
        let moved = try await request(plugin, "set-continuous-monitoring", .object(device.merging(["ipAddress": "192.168.1.10", "enabled": true]) { $1 }))
        #expect(moved == PluginWebResponse(["success": true, "continuousMonitoring": true, "discoveredIp": "192.168.1.60"]))
        #expect(environment.dyson.commands.last == ["rhtm": "ON"])
        #expect(try await request(plugin, "set-continuous-monitoring", .object(device.merging(["ipAddress": "192.168.1.60"]) { $1 })) == .error(400, "enabled must be a boolean"))

        // A public address from mDNS is never trusted with the credentials.
        environment.set(discovered: [serial: "8.8.8.8"])
        environment.dyson.set(reachableHosts: nil)
        #expect(try await request(plugin, "get-device-state", .object(device)) == .error(404, "Device \(serial) not found on network"))
    }

    @Test func theRunningConnectionIsUsed() async throws {
        let environment = DysonTestEnvironment(productState: FakeStates.tp04)
        let host = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.device(serial: serial)?.state.temperature != nil })
        let connects = environment.dyson.connects.count
        let device: JSONValue = ["serial": .string(serial), "productType": "438", "localCredentials": "secret", "ipAddress": "192.168.1.50"]
        #expect(try await request(plugin, "get-device-state", device) == PluginWebResponse(["success": true, "continuousMonitoring": true]))
        #expect(environment.dyson.connects.count == connects)
        let devices = try await request(plugin, "devices")
        #expect(devices.json["devices"]?[0]?["connected"] == true)
        #expect(devices.json["devices"]?[0]?["temperature"] == .number(22))
        #expect(devices.json["devices"]?[0]?["ipAddress"] == "192.168.1.50")
    }
}

/// The embedded copies of config.schema.json and Web/ match the files.
struct EmbeddedFilesTests {
    static let pluginDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.pluginDirectory.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(DysonPureCoolPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/DysonPureCool DysonPureCoolPlugin")
        #expect(try JSONValue(string: DysonPureCoolPlugin.configurationSchemaJSON!)["pluginAlias"] == "DysonPureCool")
    }

    @Test func webFilesAreCurrent() throws {
        let directory = Self.pluginDirectory.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names) == Set(DysonPureCoolPlugin.webFiles.keys))
        for name in names {
            let file = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(DysonPureCoolPlugin.webFiles[name]?.body == file,
                    "run: swift Scripts/embed-assets.swift web Plugins/DysonPureCool/Web Plugins/DysonPureCool/Sources/WebFiles.swift DysonPureCoolPlugin (\(name))")
        }
    }
}
