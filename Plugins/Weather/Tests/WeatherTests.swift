import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftWeather

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Open-Meteo in memory: the report it gives, whether it is down, and where it was asked about.
actor FakeWeather: WeatherAPI {
    var report = WeatherReport(temperature: 18.4, humidity: 71, pressure: 1013.2, windSpeed: 12.6, rainLastHour: 0, uvIndex: 3.2, weatherCode: 2, isRaining: false)
    var down = false
    private(set) var asked: [Location] = []

    func current(at location: Location) throws -> WeatherReport {
        asked.append(location)
        if down { throw OpenMeteo.Failure(description: "Open-Meteo answered 503") }
        return report
    }

    func set(_ change: @Sendable (inout WeatherReport) -> Void) { change(&report) }
    func setDown(_ down: Bool) { self.down = down }
}

/// An HTTP server in memory that answers every request with `body` and keeps the requests.
final class CannedHTTP: HTTPSending, @unchecked Sendable {
    let status: Int
    let body: String
    let requests = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        requests.withLockedValue { $0.append(request) }
        return HomeswiftNetwork.HTTPResponse(status: status, body: Data(body.utf8))
    }
}

/// A host with one Weather block on a fake Open-Meteo, its timings short.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Weather-tests-\(UUID().uuidString)")
    let api = FakeWeather()
    private let plugins = NIOLockedValueBox<[WeatherPlugin]>([])

    var plugin: WeatherPlugin? { plugins.withLockedValue { $0.last } }

    var registry: PluginRegistry {
        var registry = PluginRegistry()
        registry.register(platform: WeatherPlugin.platform, name: WeatherPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(WeatherPlugin.Configuration.self, from: json)
            let dependencies = WeatherPlugin.Dependencies(api: self.api, interval: .seconds(3600), retry: .seconds(3600), tick: .milliseconds(20))
            let plugin = WeatherPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        return registry
    }

    func configuration(location: Location?) throws -> HomeswiftConfiguration {
        var configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [try HomeswiftConfiguration.Platform(platform: WeatherPlugin.platform, settings: [:])])
        configuration.location = location
        return configuration
    }

    func start(location: Location? = paris) async throws -> PluginHost {
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: try configuration(location: location), registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

let paris = Location(latitude: 48.856_613, longitude: 2.352_222, name: "Flat")

/// Polls `condition` until it holds: a ceiling, not a wait, for a loaded machine.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct OpenMeteoTests {
    /// An answer as Open-Meteo gives it, trimmed to the fields asked for.
    static let answer = """
    {"latitude":48.86,"longitude":2.3399997,"generationtime_ms":0.05,"utc_offset_seconds":0,"timezone":"GMT","elevation":43.0,
     "current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","relative_humidity_2m":"%","rain":"mm","showers":"mm",
       "weather_code":"wmo code","pressure_msl":"hPa","wind_speed_10m":"km/h","uv_index":""},
     "current":{"time":"2026-11-06T16:45","interval":900,"temperature_2m":11.3,"relative_humidity_2m":87,"rain":0.4,"showers":0.0,
       "weather_code":61,"pressure_msl":1004.6,"wind_speed_10m":19.8,"uv_index":0.35},
     "minutely_15_units":{"time":"iso8601","precipitation":"mm"},
     "minutely_15":{"time":["2026-11-06T15:45","2026-11-06T16:00","2026-11-06T16:15","2026-11-06T16:30"],"precipitation":[0.2,0.5,null,0.4]}}
    """

    @Test func asksForTheRoundedCoordinatesOnly() throws {
        let url = try #require(OpenMeteo(http: CannedHTTP(body: "{}")).url(for: paris))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in query.first { $0.name == name }?.value }
        #expect(url.host == "api.open-meteo.com")
        #expect(value("latitude") == "48.86")
        #expect(value("longitude") == "2.35")
        #expect(value("current")?.contains("uv_index") == true)
        #expect(value("past_minutely_15") == "4")
        #expect(value("wind_speed_unit") == "kmh")
        // The Location's name never leaves the bridge.
        #expect(!url.absoluteString.contains("Flat"))
    }

    @Test func readsTheCurrentWeather() async throws {
        let http = CannedHTTP(body: Self.answer)
        let report = try await OpenMeteo(http: http).current(at: paris)
        #expect(report.temperature == 11.3)
        #expect(report.humidity == 87)
        #expect(report.pressure == 1004.6)
        #expect(report.windSpeed == 19.8)
        #expect(abs(report.rainLastHour - 1.1) < 0.000_1)
        #expect(report.uvIndex == 0.35)
        #expect(report.condition == "Rain")
        #expect(report.isRaining)
        #expect(http.requests.withLockedValue { $0.count } == 1)
    }

    @Test func toldWhetherItRains() throws {
        let dry = try OpenMeteo.report(from: Data(#"{"current":{"temperature_2m":20,"rain":0,"showers":0,"weather_code":3}}"#.utf8))
        #expect(!dry.isRaining)
        #expect(dry.condition == "Overcast")
        let showers = try OpenMeteo.report(from: Data(#"{"current":{"temperature_2m":20,"rain":0,"showers":0.3,"weather_code":2}}"#.utf8))
        #expect(showers.isRaining)
        let storm = try OpenMeteo.report(from: Data(#"{"current":{"temperature_2m":20,"weather_code":95}}"#.utf8))
        #expect(storm.isRaining)
        #expect(storm.condition == "Thunderstorm")
        let snow = try OpenMeteo.report(from: Data(#"{"current":{"temperature_2m":-2,"weather_code":73}}"#.utf8))
        #expect(!snow.isRaining)
    }

    @Test func aRefusalSaysWhy() async throws {
        let http = CannedHTTP(status: 400, body: #"{"error":true,"reason":"Latitude must be in range of -90 to 90°."}"#)
        await #expect(throws: OpenMeteo.Failure.self) { try await OpenMeteo(http: http).current(at: paris) }
        do { _ = try await OpenMeteo(http: http).current(at: paris) } catch { #expect("\(error)".contains("Latitude must be in range")) }
        #expect(throws: OpenMeteo.Failure.self) { try OpenMeteo.report(from: Data(#"{"current":{}}"#.utf8)) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WeatherTests {
    let environment = TestEnvironment()
    let accessoryID = WeatherPlugin.accessoryID

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(WeatherPlugin.Configuration.self, from: Data(#"{"platform":"Weather"}"#.utf8))
        #expect(configuration.name == nil)
    }

    @Test func theWeatherBecomesOneAccessory() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == "Weather:home" } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(accessory.information.characteristic(.serialNumber).value == .string("home"))
        #expect(accessory.information.characteristic(.manufacturer).value == .string("Open-Meteo"))
        let temperature = try #require(accessory.service(.temperatureSensor))
        #expect(temperature.isPrimary)
        #expect(temperature[.currentTemperature]?.value.doubleValue == 18.4)
        #expect(temperature[Eve.airPressure]?.value.doubleValue == 1013.2)
        #expect(temperature[Eve.condition]?.value == .string("Partly cloudy"))
        #expect(temperature[Eve.windSpeed]?.value.doubleValue == 12.6)
        #expect(temperature[Eve.rainLastHour]?.value.intValue == 0)
        #expect(temperature[Eve.uvIndex]?.value.intValue == 3)
        #expect(accessory.service(.humiditySensor)?[.currentRelativeHumidity]?.value.doubleValue == 71)
        let raining = try #require(accessory.service(.occupancySensor))
        #expect(raining[.name]?.value == .string("Is raining"))
        #expect(raining[.occupancyDetected]?.value.intValue == 0)
        #expect(temperature.linked.count == 2)
        #expect(await environment.api.asked == [paris])
    }

    @Test func rainReachesHomeKitAtTheNextReport() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        let plugin = try #require(environment.plugin)

        await environment.api.set { $0 = WeatherReport(temperature: 9.95, humidity: 96, pressure: 998, windSpeed: 31.2, rainLastHour: 4.6, uvIndex: 0, weatherCode: 63, isRaining: true) }
        // A report 15 minutes later: the clock moves rather than the test waiting.
        await plugin.update(now: .now + .seconds(3601))
        #expect(accessory.service(.occupancySensor)?[.occupancyDetected]?.value.intValue == 1)
        #expect(accessory.service(.temperatureSensor)?[Eve.condition]?.value == .string("Rain"))
        #expect(accessory.service(.temperatureSensor)?[Eve.rainLastHour]?.value.intValue == 5)
        #expect(accessory.service(.temperatureSensor)?[.currentTemperature]?.value.doubleValue == 10)
    }

    @Test func asksAtMostOnceAnIntervalAndAtOnceWhenTheLocationMoves() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.api.asked.count == 1 })
        // Ticks every 20 ms; the interval is an hour.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await environment.api.asked.count == 1)

        let lyon = Location(latitude: 45.764, longitude: 4.8357)
        await host.apply(try environment.configuration(location: lyon))
        #expect(await eventually { await environment.api.asked.last == lyon })
    }

    @Test func withoutALocationItWaitsForOne() async throws {
        let host = try await environment.start(location: nil)
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!host.mainBridge.server.accessories.contains { $0.id == accessoryID })
        #expect(await environment.api.asked.isEmpty)

        // Setup waits for the Location, and goes on once it is set.
        let device = try #require(try await plugin.discover().first)
        #expect(device.deviceID == "home" && !device.isSetUp)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(device))) else { Issue.record("Setup did not wait"); return }
        #expect(prompt.waitSeconds != nil && prompt.message.contains("Settings, Bridge"))

        await host.apply(try environment.configuration(location: paris))
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        #expect(try await plugin.discover().first?.isSetUp == true)
        guard case .done = try await plugin.authorize(SetupRequest(target: .device(device))) else { Issue.record("Setup did not end"); return }
    }

    @Test func anOutageGivesNoResponseThenRecovers() async throws {
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        let plugin = try #require(environment.plugin)

        await environment.api.setDown(true)
        let later = ContinuousClock.now + .seconds(3601)
        await plugin.update(now: later)
        #expect(accessory.isUnavailable)
        #expect(try await plugin.discover().first?.isReachable == false)
        // Within the retry delay nothing is asked again.
        let asked = await environment.api.asked.count
        await plugin.update(now: later + .seconds(60))
        #expect(await environment.api.asked.count == asked)

        await environment.api.setDown(false)
        await plugin.update(now: later + .seconds(3601))
        #expect(!accessory.isUnavailable)
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(WeatherPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Weather WeatherPlugin")
        let schema = try JSONValue(string: try #require(WeatherPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Weather")
    }
}
