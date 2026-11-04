import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftTado

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// tado's cloud in memory: canned answers by method and path, every request recorded.
final class FakeTado: HTTPSending, Sendable {
    struct Sent: Sendable {
        var method: String
        var path: String
        var query: String?
        var body: JSONValue?
        var authorization: String?
    }

    private let state = NIOLockedValueBox<(routes: [String: [HomeswiftNetwork.HTTPResponse]], sent: [Sent])>(([:], []))

    /// Answers `method path` with `json` (the last one set stays).
    func answer(_ method: String, _ path: String, status: Int = 200, _ json: JSONValue = .null) {
        let body = json.isNull ? Data() : json.encoded()
        state.withLockedValue { $0.routes["\(method) \(path)", default: []].append(HomeswiftNetwork.HTTPResponse(status: status, body: body)) }
    }

    func reset(_ method: String, _ path: String) { state.withLockedValue { $0.routes["\(method) \(path)"] = nil } }

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    func sent(_ method: String, _ path: String) -> [Sent] { sent.filter { $0.method == method && $0.path == path } }
    func clear() { state.withLockedValue { $0.sent.removeAll() } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let body = request.body.flatMap { try? JSONValue(data: $0) } ?? request.body.map { .string(String(decoding: $0, as: UTF8.self)) }
        let response: HomeswiftNetwork.HTTPResponse? = state.withLockedValue { state in
            state.sent.append(Sent(method: request.method, path: path, query: request.url.query, body: body, authorization: request.header("Authorization")))
            let key = "\(request.method) \(path)"
            guard var list = state.routes[key], !list.isEmpty else { return nil }
            let first = list.count > 1 ? list.removeFirst() : list[0]
            state.routes[key] = list
            return first
        }
        guard let response else { throw Unanswered(route: "\(request.method) \(path)") }
        return response
    }
}

/// A request the fake has no answer for.
struct Unanswered: Error, CustomStringConvertible { var route: String; var description: String { "no answer for \(route)" } }

/// The spec's zone states (docs/clean-room/Tado.md, 10.1).
let zoneStatesJSON: JSONValue = try! JSONValue(string: """
    { "zoneStates": {
      "1": { "tadoMode": "HOME", "overlayType": null, "overlay": null, "openWindow": null, "openWindowDetected": false,
             "setting": { "type": "HEATING", "power": "ON", "temperature": { "celsius": 21.0, "fahrenheit": 69.8 } },
             "sensorDataPoints": { "insideTemperature": { "celsius": 19.6, "fahrenheit": 67.28 },
                                   "humidity": { "type": "PERCENTAGE", "percentage": 48.2 } } },
      "2": { "overlayType": "MANUAL",
             "overlay": { "type": "MANUAL", "setting": { "type": "HEATING", "power": "OFF", "temperature": null },
                          "termination": { "type": "MANUAL", "typeSkillBasedApp": "MANUAL" } },
             "openWindow": null, "openWindowDetected": true,
             "setting": { "type": "HEATING", "power": "OFF", "temperature": null },
             "sensorDataPoints": { "insideTemperature": { "celsius": 17.0, "fahrenheit": 62.6 }, "humidity": { "percentage": 55.0 } } },
      "0": { "overlayType": null, "setting": { "type": "HOT_WATER", "power": "ON", "temperature": { "celsius": 55.0, "fahrenheit": 131.0 } },
             "sensorDataPoints": {} },
      "5": { "overlayType": "MANUAL", "overlay": { "termination": { "type": "MANUAL" } },
             "setting": { "type": "AIR_CONDITIONING", "power": "ON", "mode": "COOL",
                          "temperature": { "celsius": 22.0, "fahrenheit": 71.6 }, "fanLevel": "LEVEL2",
                          "verticalSwing": "OFF", "horizontalSwing": "OFF", "light": "ON" },
             "sensorDataPoints": { "insideTemperature": { "celsius": 25.3, "fahrenheit": 77.54 }, "humidity": { "percentage": 60.1 } } }
    } }
    """)

let acCapabilities: JSONValue = try! JSONValue(string: """
    { "type": "AIR_CONDITIONING",
      "COOL": { "temperatures": { "celsius": { "min": 18, "max": 30 } }, "fanLevel": ["LEVEL1", "LEVEL2", "LEVEL3", "AUTO"],
                "verticalSwing": ["OFF", "ON"], "horizontalSwing": ["OFF", "ON"], "light": ["OFF", "ON"] },
      "FAN": { "fanLevel": ["LEVEL1", "LEVEL2", "LEVEL3", "AUTO"] } }
    """)

let zonesJSON: JSONValue = [
    ["id": 1, "name": "Living Room", "type": "HEATING", "openWindowDetection": ["enabled": true],
     "devices": [["deviceType": "VA02", "shortSerialNo": "VA0000000001", "batteryState": "LOW", "duties": ["ZONE_LEADER"]]]],
    ["id": 2, "name": "Kitchen", "type": "HEATING", "devices": [["batteryState": "NORMAL", "duties": ["ZONE_LEADER"]]]],
    ["id": 0, "name": "Bathroom", "type": "HOT_WATER", "devices": []],
    ["id": 5, "name": "Office", "type": "AIR_CONDITIONING", "devices": []],
]

/// A host with the plugin on the fake cloud, its token already in the vault.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Tado-tests-\(UUID().uuidString)")
    let tado = FakeTado()
    private let plugins = NIOLockedValueBox<[TadoPlugin]>([])

    var plugin: TadoPlugin? { plugins.withLockedValue { $0.last } }

    init(signedIn: Bool = true) {
        tado.answer("POST", "/oauth2/token", ["access_token": "AT2", "refresh_token": "RT2", "expires_in": 599])
        tado.answer("GET", "/api/v2/homes/123456", ["id": 123456, "name": "My Home", "temperatureUnit": "CELSIUS"])
        tado.answer("GET", "/api/v2/homes/123456/zones", zonesJSON)
        tado.answer("GET", "/api/v2/homes/123456/zoneStates", zoneStatesJSON)
        tado.answer("GET", "/api/v2/homes/123456/zones/5/capabilities", acCapabilities)
        tado.answer("PUT", "/api/v2/homes/123456/zones/1/overlay", ["setting": [:]])
        tado.answer("PUT", "/api/v2/homes/123456/zones/0/overlay", ["setting": [:]])
        tado.answer("PUT", "/api/v2/homes/123456/zones/5/overlay", ["setting": [:]])
        tado.answer("DELETE", "/api/v2/homes/123456/zones/1/overlay")
        tado.answer("POST", "/api/v2/homes/123456/overlay")
        tado.answer("DELETE", "/api/v2/homes/123456/overlay")
        tado.answer("GET", "/api/v2/homes/123456/mobileDevices", [["id": 1, "name": "Buddy 1", "location": ["atHome": true]]])
        tado.answer("GET", "/api/v2/homes/123456/weather", ["outsideTemperature": ["celsius": 7.5], "solarIntensity": ["percentage": 42.3]])
        tado.answer("GET", "/api/v2/homes/123456/state", ["presence": "AWAY", "presenceLocked": true])
        tado.answer("PUT", "/api/v2/homes/123456/presenceLock")
        tado.answer("DELETE", "/api/v2/homes/123456/presenceLock")
        if signedIn {
            // The instance's folder: its platform and name, slugged ("tado°" loses its °).
            let storage = directory.appendingPathComponent("plugins/TadoPlatform-tado")
            try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            // A token file copied from Homebridge: it moves into the vault.
            try? Data(#"{"access_token":"AT1","refresh_token":"RT1"}"#.utf8).write(to: storage.appendingPathComponent(".tado-token-1mjwh6c.json"))
        }
    }

    static func home(zones: [JSONValue], extras: [String: JSONValue] = [:]) -> [String: Any] {
        var home: [String: JSONValue] = ["id": 123456, "name": "My Home", "username": "mail@example.com", "zones": .array(zones)]
        for (key, value) in extras { home[key] = value }
        return ["homes": try! JSONValue.array([.object(home)]).anyValue()]
    }

    func start(settings: [String: Any], dailyLimit: Int? = nil) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: TadoPlugin.platform, name: TadoPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(TadoPlugin.Configuration.self, from: json)
            // Retries go at once; the next poll never comes.
            var dependencies = TadoPlugin.Dependencies(transport: self.tado, sleep: { delay in
                if delay > .seconds(30) { try await Task.sleep(for: .seconds(3600)) }
            })
            dependencies.home.writeDelay = .milliseconds(20)
            dependencies.home.resetDelay = .milliseconds(10)
            dependencies.home.delayUnit = .milliseconds(10)
            let plugin = TadoPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        var settings = settings
        if let dailyLimit { settings["dailyRequestLimit"] = dailyLimit }
        let block = try HomeswiftConfiguration.Platform(platform: TadoPlugin.platform, name: TadoPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

extension JSONValue {
    func anyValue() throws -> Any { try JSONSerialization.jsonObject(with: encoded(), options: .fragmentsAllowed) }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// `eventually`, expected (awaited outside `#expect`, which Swift Testing on Linux requires).
func expectEventually(_ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let held = await eventually(condition)
    #expect(held, sourceLocation: sourceLocation)
}

/// Writes a value as a controller would, through the characteristic's handler.
func write(_ characteristic: Characteristic, _ value: HAPValue) async throws {
    let handler = try #require(characteristic.writeHandler(for: value))
    try await handler(value)
}

func accessory(_ host: PluginHost, _ name: String) -> Accessory? {
    host.mainBridge.server.accessories.first { $0.id == "TadoPlatform:\(name)" }
}

let livingRoom: JSONValue = ["active": true, "id": 1, "name": "Living Room", "type": "HEATING", "mode": "MANUAL", "openWindowSensor": true, "openWindowSwitch": true]
let kitchen: JSONValue = ["active": true, "id": 2, "name": "Kitchen", "type": "HEATING", "mode": "TIMER", "modeTimer": 30]
let bathroom: JSONValue = ["active": true, "id": 0, "name": "Bathroom", "type": "HOT_WATER", "mode": "AUTO"]
let office: JSONValue = ["active": true, "id": 5, "name": "Office", "type": "AIR_CONDITIONING", "mode": "TIMER", "modeTimer": 60,
                         "acFanSpeed": true, "acFanModeSwitch": true, "acDryModeSwitch": true]

@Suite(.timeLimit(.minutes(1)))
struct TadoIdentityTests {
    @Test func hashesAreTheHomebridgePlugins() {
        #expect(TadoHash.username("mail@example.com") == "1mjwh6c")
        #expect(TadoHash.username("user@example.org") == "0hxh36z")
        #expect(TadoHash.serial("My Home Living Room Heater") == "1357935336")
        #expect(TadoHash.serial("Living Room") == "981103630")
        #expect(TadoHash.serial("My Home Central Switch") == "71916180")
        #expect(TadoAccount.fileName(username: "mail@example.com") == ".tado-token-1mjwh6c.json")
    }

    @Test func zoneKindsAndLimits() throws {
        let heating = try #require(ZoneSettings(["name": "A", "type": "HEATING", "easyMode": true, "boilerTempSupport": true]))
        // boilerTempSupport is for hot water only.
        #expect(heating.kind == .heaterCooler)
        #expect(ZoneSettings(["name": "B", "type": "HOT_WATER", "boilerTempSupport": true])?.kind == .boiler)
        #expect(ZoneSettings(["name": "C", "type": "HOT_WATER", "accTypeBoiler": "FAUCET"])?.kind == .faucet)
        #expect(ZoneSettings(["name": "D", "type": "BOGUS"])?.type == .heating)
        #expect(ZoneSettings(["type": "HEATING"]) == nil)
        #expect(ZoneSettings(["name": "E"])?.modeTimer == 1)
        // Fahrenheit limits become HomeKit's Celsius.
        let fahrenheit = try #require(ZoneSettings(["name": "F", "minValue": 41, "maxValue": 77, "minStep": 0.5]))
        let limits = fahrenheit.limits(unit: .fahrenheit, heaterCoolerRule: false)
        #expect(limits.min == 5 && limits.max == 25 && limits.step == 0.5)
        #expect(ZoneSettings(["name": "G", "type": "HOT_WATER"])?.limits(unit: .celsius, heaterCoolerRule: true).max == 65)
    }

    @Test func aNamelessZoneSkipsOnlyItself() throws {
        let home = try HomeSettings(["name": "My Home", "username": "a@b.c", "zones": [["active": true, "type": "HEATING"], livingRoom]])
        #expect(home.activeZones.map(\.name) == ["Living Room"])
        #expect(home.warnings.count == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TadoOverlayTests {
    let current: JSONValue = ["type": "HEATING", "power": "ON", "temperature": ["celsius": 21.0]]

    @Test func heatingOverlays() {
        let manual = TadoOverlay.zone(type: .heating, power: true, celsius: 22.5, termination: TadoOverlay.termination(mode: .manual, modeTimer: 1), current: current)
        #expect(manual == ["setting": ["type": "HEATING", "power": "ON", "temperature": ["celsius": 22.5]], "termination": ["type": "MANUAL"]])
        #expect(TadoOverlay.termination(mode: .auto, modeTimer: 1) == ["type": "TADO_MODE"])
        #expect(TadoOverlay.termination(mode: .timer, modeTimer: 30) == ["type": "TIMER", "durationInSeconds": 1800])
        let off = TadoOverlay.zone(type: .heating, power: false, celsius: 21, termination: ["type": "MANUAL"], current: current)
        #expect(off == ["setting": ["type": "HEATING", "power": "OFF", "temperature": nil], "termination": ["type": "MANUAL"]])
        let water = TadoOverlay.zone(type: .hotWater, power: true, celsius: nil, termination: TadoOverlay.termination(mode: .auto, modeTimer: 1), current: nil)
        #expect(water == ["setting": ["type": "HOT_WATER", "power": "ON", "temperature": nil], "termination": ["type": "TADO_MODE"]])
    }

    @Test func airConditionerOverlays() throws {
        let setting = try #require(ZoneState.all(zoneStatesJSON)[5]?.setting)
        let cool = TadoOverlay.airConditioner(power: true, mode: "COOL", celsius: 21, fanLevel: nil, current: setting, capabilities: acCapabilities, timer: 60)
        #expect(cool == ["setting": ["type": "AIR_CONDITIONING", "power": "ON", "mode": "COOL", "temperature": ["celsius": 21], "fanLevel": "LEVEL2",
                                     "verticalSwing": "OFF", "horizontalSwing": "OFF", "light": "ON"],
                         "termination": ["durationInSeconds": 3600, "typeSkillBasedApp": "MANUAL"]])
        let off = TadoOverlay.airConditioner(power: false, mode: "COOL", celsius: nil, fanLevel: nil, current: setting, capabilities: acCapabilities, timer: 60)
        #expect(off == ["setting": ["type": "AIR_CONDITIONING", "power": "OFF", "mode": "COOL"], "termination": ["durationInSeconds": 3600, "typeSkillBasedApp": "MANUAL"]])
        let fan = TadoOverlay.airConditioner(power: true, mode: "FAN", celsius: nil, fanLevel: nil, current: setting, capabilities: acCapabilities, timer: nil)
        #expect(fan["setting"] == ["type": "AIR_CONDITIONING", "power": "ON", "mode": "FAN", "fanLevel": "LEVEL2"])
        let auto = TadoOverlay.airConditioner(power: true, mode: "FAN", celsius: nil, fanLevel: nil, current: nil, capabilities: acCapabilities, timer: nil)
        #expect(auto["setting"]?["fanLevel"] == "AUTO")
        let full = TadoOverlay.airConditioner(power: true, mode: "COOL", celsius: 21, fanLevel: "AUTO", current: setting, capabilities: acCapabilities, timer: 60)
        #expect(full["setting"]?["fanLevel"] == "AUTO")
    }

    @Test func fanLevels() throws {
        let fan = try #require(TadoOverlay.fanLevels(["fanLevel": ["HIGH", "AUTO", "LOW", "MIDDLE"]]))
        #expect(fan.levels == ["LOW", "MIDDLE", "HIGH", "AUTO"])
        #expect((0..<4).map { TadoOverlay.percent(step: $0, of: 4) } == [25, 50, 75, 100])
        #expect(TadoOverlay.level(percent: 60, levels: fan.levels) == "MIDDLE")
        #expect(TadoOverlay.level(percent: 10, levels: fan.levels) == "LOW")
        #expect(TadoOverlay.fanLevels(["fanSpeeds": ["LOW"]])?.key == "fanSpeed")
    }

    @Test func centralOverlaysFixTheTimerAndAuto() {
        let zones: [(id: Int, type: ZoneType, mode: ZoneMode, modeTimer: Int)] = [(1, .heating, .manual, 1), (2, .heating, .timer, 30), (3, .heating, .auto, 1)]
        let boost = TadoOverlay.central(zones, power: true, celsius: 25)
        let expected: JSONValue = ["overlays": [
            ["room": 1, "overlay": ["setting": ["power": "ON", "type": "HEATING", "temperature": ["celsius": 25, "fahrenheit": 77]]], "termination": ["typeSkillBasedApp": "MANUAL"]],
            ["room": 2, "overlay": ["setting": ["power": "ON", "type": "HEATING", "temperature": ["celsius": 25, "fahrenheit": 77]]],
             "termination": ["typeSkillBasedApp": "TIMER", "durationInSeconds": 1800]],
            ["room": 3, "overlay": ["setting": ["power": "ON", "type": "HEATING", "temperature": ["celsius": 25, "fahrenheit": 77]]], "termination": ["typeSkillBasedApp": "NEXT_TIME_BLOCK"]],
        ]]
        #expect(boost == expected)
        #expect(TadoOverlay.central(zones, power: false, celsius: nil)["overlays"]?[0]?["overlay"]?["setting"] == ["power": "OFF", "type": "HEATING"])
    }

    @Test func zoneStatesDecode() throws {
        let states = ZoneState.all(zoneStatesJSON)
        #expect(states.count == 4)
        let zone2 = try #require(states[2])
        #expect(!zone2.power && !zone2.onSchedule && zone2.windowOpen && zone2.hasTermination)
        #expect(states[1]?.target == 21 && states[1]?.current == 19.6 && states[1]?.onSchedule == true)
    }

    @Test func budget() {
        // One request a poll: 100 a day leave 76 for polls once 4 zone lists are made.
        #expect(TadoBudget.interval(requestsPerPoll: 1, slowRequestsPerDay: 4, dailyLimit: 100) == 1137)
        #expect(TadoBudget.interval(requestsPerPoll: 1, slowRequestsPerDay: 4, dailyLimit: 20000) == 300)
        #expect(TadoBudget.requestsPerDay(requestsPerPoll: 1, slowRequestsPerDay: 4, interval: 1137) <= 100)
        #expect(TadoHTTP.retryAfter("3") == .seconds(3))
        #expect(TadoHTTP.retryAfter("-1") == .zero)
    }

    @Test func runningTimeRanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))
        let ranges = TadoOverlay.runningTimeRanges(today: today, calendar: calendar)
        #expect(ranges[0].from == "2026-03-31")
        #expect(ranges[1].from == "2026-02-28")
        #expect(ranges[2].from == "2025-04-01" && ranges[2].to == "2026-03-31")
    }

    @Test func counterResetsAtBerlinMidnight() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = RequestCounter(file: nil) { clock.withLockedValue { $0 } }
        await counter.count(login: false)
        await counter.count(login: true)
        let first = await counter.today()
        #expect(first.api == 1 && first.login == 1)
        clock.withLockedValue { $0 = $0.addingTimeInterval(86400) }
        let next = await counter.today()
        #expect(next.api == 0 && next.login == 0)
    }
}

@Suite(.timeLimit(.minutes(1)), .serialized)
struct TadoPluginTests {
    @Test func zonesBecomeAccessoriesWithTheSpecsStates() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom, kitchen, bathroom, office]))
        await expectEventually({ accessory(host, "My Home Office AC")?.service(.heaterCooler)?[.active]?.value.intValue == 1 })
        let living = try #require(accessory(host, "My Home Living Room Heater"))
        let thermostat = try #require(living.service(.thermostat))
        #expect(thermostat.subtype == "zone-thermostat" && thermostat.isPrimary)
        #expect(living.information[.serialNumber]?.value == .string("1357935336"))
        #expect(thermostat[.currentTemperature]?.value.doubleValue == 19.6)
        #expect(thermostat[.targetTemperature]?.value.doubleValue == 21)
        #expect(thermostat[.currentHeatingCoolingState]?.value.intValue == 1)
        #expect(thermostat[.targetHeatingCoolingState]?.value.intValue == 3)
        #expect(thermostat[.currentRelativeHumidity]?.value.doubleValue?.rounded() == 48)
        let battery = try #require(living.service(.battery))
        #expect(battery[.batteryLevel]?.value.intValue == 10)
        #expect(battery[.statusLowBattery]?.value.intValue == 1)
        let kitchenThermostat = try #require(accessory(host, "My Home Kitchen Heater")?.service(.thermostat))
        #expect(kitchenThermostat[.targetHeatingCoolingState]?.value.intValue == 0)
        let window = try #require(accessory(host, "My Home Living Room Window")?.service(.contactSensor))
        #expect(window.subtype == "zone-window-contact" && window[.contactSensorState]?.value.intValue == 0)
        let windowSwitch = try #require(accessory(host, "My Home Open Window")?.service(.switch, subtype: "Living Room Window"))
        #expect(windowSwitch[.on]?.value.boolValue == true)
        let boiler = try #require(accessory(host, "My Home Bathroom Boiler")?.service(.switch))
        #expect(boiler.subtype == "zone-switch" && boiler[.on]?.value.boolValue == true)
        let ac = try #require(accessory(host, "My Home Office AC"))
        let heaterCooler = try #require(ac.service(.heaterCooler))
        #expect(heaterCooler[.targetHeaterCoolerState]?.value.intValue == 2)
        #expect(heaterCooler[.currentHeaterCoolerState]?.value.intValue == 3)
        #expect(heaterCooler[.coolingThresholdTemperature]?.value.doubleValue == 22)
        #expect(ac.service(.battery) == nil)
        #expect(ac.service(.switch, subtype: "FanModeSwitch") != nil && ac.service(.switch, subtype: "DryModeSwitch") != nil)
        // One zoneStates request for every zone; the refresh token from Homebridge's file was used and rotated.
        #expect(environment.tado.sent("GET", "/api/v2/homes/123456/zoneStates").count == 1)
        #expect(environment.tado.sent("GET", "/api/v2/homes/123456/zones/1/state").isEmpty)
        #expect(environment.tado.sent("POST", "/oauth2/token").first?.body == .string("client_id=1bb50063-6b0c-4d11-bd99-387f4a91cc46&grant_type=refresh_token&refresh_token=RT1"))
        #expect(environment.tado.sent("GET", "/api/v2/homes/123456/zoneStates").first?.authorization == "Bearer AT2")
        await host.stop()
    }

    @Test func temperatureWritesAreCoalescedAndSendTheirOverlay() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom]))
        await expectEventually({ accessory(host, "My Home Living Room Heater")?.service(.thermostat)?[.currentTemperature]?.value.doubleValue == 19.6 })
        let thermostat = try #require(accessory(host, "My Home Living Room Heater")?.service(.thermostat))
        let target = try #require(thermostat[.targetTemperature])
        for value in [20.0, 21.5, 22.5] { try await write(target, .double(value)) }
        await expectEventually({ environment.tado.sent("PUT", "/api/v2/homes/123456/zones/1/overlay").count == 1 })
        let body = environment.tado.sent("PUT", "/api/v2/homes/123456/zones/1/overlay").first?.body
        #expect(body == ["setting": ["type": "HEATING", "power": "ON", "temperature": ["celsius": 22.5]], "termination": ["type": "MANUAL"]])
        // Back to the schedule.
        let state = try #require(thermostat[.targetHeatingCoolingState])
        try await write(state, .int(3))
        await expectEventually({ environment.tado.sent("DELETE", "/api/v2/homes/123456/zones/1/overlay").count == 1 })
        await host.stop()
    }

    @Test func aModeOnlyWriteOfTheAirConditionerSendsItsOverlay() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: TestEnvironment.home(zones: [office]))
        await expectEventually({ accessory(host, "My Home Office AC")?.service(.heaterCooler)?[.active]?.value.intValue == 1 })
        let heaterCooler = try #require(accessory(host, "My Home Office AC")?.service(.heaterCooler))
        let mode = try #require(heaterCooler[.targetHeaterCoolerState])
        try await write(mode, .int(1))
        await expectEventually({ !environment.tado.sent("PUT", "/api/v2/homes/123456/zones/5/overlay").isEmpty })
        #expect(environment.tado.sent("PUT", "/api/v2/homes/123456/zones/5/overlay").first?.body?["setting"]?["mode"] == "HEAT")
        await host.stop()
    }

    @Test func customModeTurnsOnToTheSchedule() async throws {
        let environment = TestEnvironment()
        var zone = livingRoom.objectValue!
        zone["mode"] = "CUSTOM"
        zone["easyMode"] = true
        let host = try await environment.start(settings: TestEnvironment.home(zones: [.object(zone)]))
        await expectEventually({ accessory(host, "My Home Living Room Heater")?.service(.heaterCooler)?[.active]?.value.intValue == 1 })
        let active = try #require(accessory(host, "My Home Living Room Heater")?.service(.heaterCooler)?[.active])
        try await write(active, .int(1))
        await expectEventually({ environment.tado.sent("DELETE", "/api/v2/homes/123456/zones/1/overlay").count == 1 })
        try await write(active, .int(0))
        await expectEventually({ environment.tado.sent("PUT", "/api/v2/homes/123456/zones/1/overlay").count == 1 })
        #expect(environment.tado.sent("PUT", "/api/v2/homes/123456/zones/1/overlay").first?.body?["termination"] == ["type": "MANUAL"])
        await host.stop()
    }

    @Test func centralSwitchCoversActiveHeatingZonesOnly() async throws {
        let environment = TestEnvironment()
        var inactive = kitchen.objectValue!
        inactive["active"] = false
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom, .object(inactive), bathroom], extras: [
            "extras": ["centralSwitch": true, "boostSwitch": true, "presenceLock": true, "accTypePresenceLock": "ALARM"],
            "presence": ["anyone": true, "user": [["active": true, "name": "Buddy 1", "accType": "OCCUPANCY"]]],
            "weather": ["temperatureSensor": true, "solarIntensity": true],
        ]))
        await expectEventually({ accessory(host, "My Home Buddy 1")?.service(.occupancySensor)?[.occupancyDetected]?.value.intValue == 1 })
        #expect(accessory(host, "My Home Kitchen Heater") == nil)
        #expect(accessory(host, "My Home Anyone")?.service(.occupancySensor)?[.occupancyDetected]?.value.intValue == 1)
        #expect(accessory(host, "My Home Weather")?.service(.temperatureSensor)?[.currentTemperature]?.value.doubleValue == 7.5)
        #expect(accessory(host, "My Home Solar Intensity")?.service(.lightbulb)?[.brightness]?.value.intValue == 42)
        let lock = try #require(accessory(host, "My Home Presence Lock")?.service(.securitySystem))
        #expect(lock[.securitySystemCurrentState]?.value.intValue == 1)
        let central = try #require(accessory(host, "My Home Central Switch"))
        let boost = try #require(central.service(.switch, subtype: "CentralBoost")?[.on])
        try await write(boost, .bool(true))
        await expectEventually({ environment.tado.sent("POST", "/api/v2/homes/123456/overlay").count == 1 })
        let rooms = environment.tado.sent("POST", "/api/v2/homes/123456/overlay").first?.body?["overlays"]?.arrayValue?.compactMap { $0["room"]?.intValue }
        #expect(rooms == [1])
        let main = try #require(central.service(.switch, subtype: "Central")?[.on])
        try await write(main, .bool(true))
        await expectEventually({ environment.tado.sent("DELETE", "/api/v2/homes/123456/overlay").first?.query == "rooms=1" })
        // Disarming the presence lock sends AUTO.
        try await write(try #require(lock[.securitySystemTargetState]), .int(3))
        #expect(environment.tado.sent("DELETE", "/api/v2/homes/123456/presenceLock").first?.body == ["homePresence": "AUTO"])
        await host.stop()
    }

    @Test func withoutATokenTheAccountNeedsSigningIn() async throws {
        let environment = TestEnvironment(signedIn: false)
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom]))
        await expectEventually({ accessory(host, "My Home Living Room Heater") != nil })
        let plugin = try #require(environment.plugin)
        let authorized = await plugin.accountAuthorized()
        #expect(authorized == false)
        // No request reached the API without a token.
        #expect(environment.tado.sent.isEmpty)
        await host.stop()
    }

    @Test func aHomeWithoutAUsernameIsSkipped() async throws {
        let environment = TestEnvironment()
        var settings = TestEnvironment.home(zones: [livingRoom])
        settings["homes"] = [["name": "Holiday Home"]] + (settings["homes"] as? [Any] ?? [])
        let host = try await environment.start(settings: settings)
        let plugin = try #require(environment.plugin)
        await expectEventually({ await plugin.homes.count == 1 })
        let names = await plugin.homeSettings().map(\.name)
        #expect(names == ["My Home"])
        await host.stop()
    }

    @Test func pollingFitsTheDailyLimit() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom]))
        let plugin = try #require(environment.plugin)
        await expectEventually({ await !plugin.homes.isEmpty })
        let interval = await plugin.homes[0].pollingInterval(homesOnAccount: 1)
        #expect(interval == 1137)
        await host.stop()
    }

    @Test func setupSignsInWithTheDeviceCode() async throws {
        let environment = TestEnvironment(signedIn: false)
        environment.tado.answer("POST", "/oauth2/device_authorize", [
            "device_code": "DC", "user_code": "ABC123", "verification_uri_complete": "https://login.tado.com/oauth2/device?user_code=ABC123", "expires_in": 300, "interval": 5,
        ])
        let host = try await environment.start(settings: TestEnvironment.home(zones: [livingRoom]))
        let plugin = try #require(environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, _) = first else { Issue.record("expected a prompt"); return }
        #expect(prompt.fields.first?.value == "mail@example.com")
        let started = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "mail@example.com"]))
        guard case .ask(let open, let state) = started else { Issue.record("expected the page"); return }
        #expect(open.url == "https://login.tado.com/oauth2/device?user_code=ABC123")
        #expect(open.values["code"] == "ABC123")
        // Pending first, then the tokens; /me must be the same account.
        environment.tado.reset("POST", "/oauth2/token")
        environment.tado.answer("POST", "/oauth2/token", status: 400, ["error": "authorization_pending"])
        environment.tado.answer("POST", "/oauth2/token", ["access_token": "AT9", "refresh_token": "RT9", "expires_in": 599])
        environment.tado.answer("GET", "/api/v2/me", ["email": "Mail@Example.com", "homes": [["id": 123456, "name": "My Home"]]])
        guard case .ask = try await plugin.authorize(SetupRequest(target: .account, state: state)) else { Issue.record("expected a wait"); return }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, state: state)) else { Issue.record("expected done"); return }
        // The block has the account's home already: nothing to add.
        #expect(outcome.settings.isEmpty)
        let authorized = await plugin.accountAuthorized()
        #expect(authorized == true)
        #expect(environment.tado.sent("POST", "/oauth2/token").last?.body?.stringValue?.contains("device_code=DC") == true)
        await host.stop()
    }

    @Test func canonicalSettingsMovesZoneOptions() throws {
        let block: JSONValue = ["platform": "TadoPlatform", "homes": [["name": "My Home", "username": "a@b.c", "password": "old", "zones": [
            ["active": true, "id": 1, "name": "Living Room", "type": "HEATING", "mode": "TIMER", "modeTimer": 30, "easyMode": false],
            ["active": false, "id": 2, "name": "Kitchen", "type": "HEATING"],
            ["active": true, "type": "HEATING"],
        ]]]]
        let canonical = TadoPlugin.canonical(block)
        #expect(canonical["_accessories"]?["My Home Living Room Heater"] == ["mode": "TIMER", "modeTimer": 30, "easyMode": false])
        #expect(canonical["_accessories"]?["My Home Kitchen Heater"]?["excluded"] == true)
        #expect(canonical["homes"]?[0]?["zones"]?[0] == ["active": true, "id": 1, "name": "Living Room", "type": "HEATING"])
        #expect(canonical["homes"]?[0]?["zones"]?[1]?["active"] == true)
        #expect(canonical["homes"]?[0]?["zones"]?[2] == ["active": true, "type": "HEATING"])
        #expect(canonical["homes"]?[0]?["password"] == nil)
        #expect(TadoPlugin.canonical(canonical) == canonical)
    }

    @Test func telegramTokenLeavesTheBlockForTheVault() throws {
        let block: JSONValue = ["homes": [["name": "My Home", "telegram": ["active": true, "token": "123:abc", "chatID": "42"]]]]
        #expect(TadoPlugin.withoutTelegramToken(block)["homes"]?[0]?["telegram"] == ["active": true, "chatID": "42"])
        let fromVault = try #require(TelegramSettings(["active": true, "chatID": "42"], vaultToken: "123:abc"))
        #expect(fromVault.token == "123:abc")
        #expect(TelegramSettings(["active": true, "chatID": "42"]) == nil)
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(TadoPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Tado TadoPlugin")
        let schema = try JSONValue(string: try #require(TadoPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "TadoPlatform")
    }
}
