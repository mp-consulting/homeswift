import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The weather where the home is, from Open-Meteo (no account, no key), for the Location the person set under Settings,
/// Bridge (`context.location`). One accessory: a Temperature sensor (primary) with Eve's weather characteristics (air
/// pressure, condition, wind speed, rain in the last hour, UV index), a Humidity sensor, and an Occupancy sensor,
/// "Is raining", for automations on the rain. It asks every 15 minutes, as often as Open-Meteo's current conditions
/// change, and at once when the Location moves.
///
/// Not a port: homebridge-weather-plus does more (forecasts, several services), with other option names.
public actor WeatherPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
    }

    /// What the plugin uses, and its timings; tests swap in a fake and shorter ones.
    struct Dependencies: Sendable {
        var api: any WeatherAPI = OpenMeteo()
        /// Between two reports.
        var interval: Duration = .seconds(15 * 60)
        /// After a report that did not come: Open-Meteo or the network is down.
        var retry: Duration = .seconds(5 * 60)
        /// How often the plugin looks whether a report is due or the Location moved.
        var tick: Duration = .seconds(60)
    }

    /// The accessory's services.
    struct WeatherServices {
        let accessory: Accessory
        let temperature: Service
        let humidity: Service
        let raining: Service
    }

    public static let platform = "Weather"
    public static let name = "Weather"
    public static let icon: String? = "cloud"
    public static let summary: String? = "The weather where the home is, from Open-Meteo: temperature, humidity, rain, wind and UV"

    /// The one device: the weather at the Location.
    static let deviceID = "home"
    static let deviceKind = "weather"
    static var accessoryID: String { "\(platform):\(deviceID)" }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var services: WeatherServices?
    /// Where and when the last report came from, or when to try again.
    private var reportedAt: (location: Location, at: ContinuousClock.Instant)?
    /// After a failure: where it failed and when to ask again (at once for another Location).
    private var retry: (location: Location, at: ContinuousClock.Instant)?
    /// The last report, for Setup's and the log's words.
    private(set) var lastReport: WeatherReport?
    /// What the log said last, so an outage or a missing Location is said once.
    private var lastProblem: String?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        let tick = dependencies.tick
        tasks.add { [weak self] in
            while !Task.isCancelled {
                await self?.update()
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    // MARK: Setup

    /// The weather at the Location: set up once there is a Location.
    public func discover() async throws -> [DiscoveredDevice] {
        let location = context.location
        var device = DiscoveredDevice(
            deviceID: Self.deviceID, name: Self.accessoryName, model: "Open-Meteo", isSetUp: location != nil, kind: Self.deviceKind)
        device.isReachable = location == nil || lastProblem == nil
        return [device]
    }

    /// Nothing to sign in to: the step waits for the Location, which the person sets under Settings, Bridge.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard context.location != nil else {
            return .ask(SetupPrompt(message: "The weather is for where the home is: set the Location under Settings, Bridge. This step goes on by itself once it is set.", waitSeconds: 900, retryAfter: 5))
        }
        return .done(SetupOutcome())
    }

    public func deviceKind(of deviceID: String) async -> String? { Self.deviceKind }

    // MARK: Updates

    static let accessoryName = "Weather"

    /// Asks for a report when one is due or the Location moved; without a Location, the accessory answers No Response.
    func update(now: ContinuousClock.Instant = .now) async {
        guard let location = context.location else {
            say("No Location: set it under Settings, Bridge, for the weather to show", level: .warning)
            context.accessory(id: Self.accessoryID)?.isUnavailable = true
            reportedAt = nil
            return
        }
        guard !context.isExcluded(Self.deviceID) else { return }
        if let reportedAt, reportedAt.location == location, now < reportedAt.at + dependencies.interval { return }
        if let retry, retry.location == location, now < retry.at { return }
        do {
            let report = try await dependencies.api.current(at: location)
            try show(report)
            reportedAt = (location, now)
            retry = nil
            lastReport = report
            if lastProblem != nil { logger.info("The weather answers again") }
            lastProblem = nil
        } catch {
            retry = (location, now + dependencies.retry)
            say("Could not get the weather: \(error)", level: .warning)
            context.accessory(id: Self.accessoryID)?.isUnavailable = true
        }
    }

    /// Logs a problem once, until it changes or goes.
    private func say(_ problem: String, level: Logger.Level) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        logger.log(level: level, "\(problem)")
    }

    /// Sets the characteristics from a report, adding the accessory the first time; HomeKit hears of what changed.
    func show(_ report: WeatherReport) throws {
        let services = try self.services ?? add()
        services.accessory.isUnavailable = false
        services.temperature.characteristic(.currentTemperature).value = .double(Self.clamped(report.temperature, -270, 100, step: 0.1))
        services.temperature.characteristic(Eve.airPressure).value = .double(Self.clamped(report.pressure, 700, 1100, step: 0.1))
        services.temperature.characteristic(Eve.condition).value = .string(report.condition)
        services.temperature.characteristic(Eve.windSpeed).value = .double(Self.clamped(report.windSpeed, 0, 150, step: 0.1))
        services.temperature.characteristic(Eve.rainLastHour).value = .int(Int(Self.clamped(report.rainLastHour, 0, 200, step: 1)))
        services.temperature.characteristic(Eve.uvIndex).value = .int(Int(Self.clamped(report.uvIndex, 0, 16, step: 1)))
        services.humidity.characteristic(.currentRelativeHumidity).value = .double(Self.clamped(report.humidity, 0, 100, step: 1))
        services.raining.characteristic(.occupancyDetected).value = .int(report.isRaining ? 1 : 0)
    }

    static func clamped(_ value: Double, _ low: Double, _ high: Double, step: Double) -> Double {
        guard value.isFinite else { return low }
        let scale = 1 / step
        return min(high, max(low, (value * scale).rounded() / scale))
    }

    private func add() throws -> WeatherServices {
        let humidity = Service(.humiditySensor, name: "Humidity", subtype: "humidity")
        let raining = Service(.occupancySensor, name: "Is raining", subtype: "raining")
        let temperature = Service(
            .temperatureSensor, name: Self.accessoryName,
            optional: [Eve.airPressure, Eve.condition, Eve.windSpeed, Eve.rainLastHour, Eve.uvIndex],
            linked: [humidity, raining], isPrimary: true)
        // Without a MAC or a serial of its own, the serial is the device's id (CLAUDE.md).
        let accessory = Accessory(
            id: Self.accessoryID, name: Self.accessoryName, manufacturer: "Open-Meteo", model: "Weather",
            serialNumber: Self.deviceID, firmwareRevision: PluginHost.version, category: .sensor, services: [temperature, humidity, raining])
        try context.add(accessory)
        // The accessory the bridge publishes: the one added, or the cached one it keeps for its aids and iids.
        let published = context.accessory(id: Self.accessoryID) ?? accessory
        let shown = WeatherServices(
            accessory: published, temperature: published.service(.temperatureSensor) ?? temperature,
            humidity: published.service(.humiditySensor) ?? humidity, raining: published.service(.occupancySensor) ?? raining)
        services = shown
        return shown
    }
}

/// Eve's weather characteristics, as Eve and homebridge-lib name them (the UUIDs MQTTThing's weather station uses).
enum Eve {
    static let readEvents: Set<CharacteristicPermission> = [.pairedRead, .events]
    static let airPressure = CharacteristicType(
        name: "Air Pressure", uuid: HAPUUID("E863F10F-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: readEvents, minValue: 700, maxValue: 1100, minStep: 0.1)
    static let condition = CharacteristicType(name: "Condition", uuid: HAPUUID("CD65A9AB-85AD-494A-B2BD-2F380084134D"), format: .string, permissions: readEvents)
    static let windSpeed = CharacteristicType(
        name: "Wind Speed", uuid: HAPUUID("49C8AE5A-A3A5-41AB-BF1F-12D5654F9F41"), format: .float, permissions: readEvents, minValue: 0, maxValue: 150, minStep: 0.1)
    static let rainLastHour = CharacteristicType(
        name: "Rain Last Hour", uuid: HAPUUID("10C88F40-7EC4-478C-8D5A-BD0C3CCE14B7"), format: .uint16, permissions: readEvents, minValue: 0, maxValue: 200, minStep: 1)
    static let uvIndex = CharacteristicType(
        name: "UV Index", uuid: HAPUUID("05BA0FE0-B848-4226-906D-5B64272E05CE"), format: .uint8, permissions: readEvents, minValue: 0, maxValue: 16, minStep: 1)
}
