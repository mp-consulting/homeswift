import Foundation
import Homeswift
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
        /// A self-hosted Open-Meteo (it is open source), such as `http://192.168.1.5:8080`; open-meteo.com's own when
        /// left out.
        public var server: String?

        /// The server's forecast endpoint, or nil for open-meteo.com's; anything but an http or https address is refused.
        func validated() throws -> String? {
            guard let server = server?.trimmingCharacters(in: .whitespaces), !server.isEmpty else { return nil }
            guard let url = URL(string: server), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw OpenMeteo.Failure(description: "server must be an http or https address, such as http://192.168.1.5:8080")
            }
            return OpenMeteo.forecast(at: url)
        }
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
    /// The accessory, once added.
    private var accessory: Accessory?
    /// When to ask next, and for where: after a report the interval, after a failure the retry; nil asks at once.
    private var next: (location: Location, at: ContinuousClock.Instant)?
    /// What the log said last, so an outage or a missing Location is said once.
    private var lastProblem: String?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) throws {
        var dependencies = Dependencies()
        if let base = try configuration.validated() { dependencies.api = OpenMeteo(base: base) }
        self.init(configuration: configuration, context: context, dependencies: dependencies)
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        let tick = dependencies.tick
        tasks.add { [weak self] in
            // Ends with the plugin, stopped or gone.
            while !Task.isCancelled, let plugin = self {
                await plugin.update()
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
        // Without a Location it Needs setup: its step points at the Location under Settings and waits for it.
        var device = DiscoveredDevice(
            deviceID: Self.deviceID, name: Self.accessoryName, model: "Open-Meteo", authorization: location == nil ? .bridgeSetting : .none,
            isSetUp: location != nil, kind: Self.deviceKind)
        device.isReachable = location == nil || lastProblem == nil
        return [device]
    }

    /// Nothing to sign in to: the step waits for the Location, which the person sets under Settings, Bridge.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard context.location != nil else {
            return .ask(SetupPrompt(
                message: "The weather is for where the home is: set the Location under Settings, Bridge. This step goes on by itself once it is set.",
                page: "/settings#location", waitSeconds: 900, retryAfter: 5))
        }
        return .done(SetupOutcome())
    }

    public func deviceKind(of deviceID: String) async -> String? { Self.deviceKind }

    // MARK: Updates

    static let accessoryName = "Weather"

    /// Asks for a report when one is due or the Location moved (noticed within a `tick`); without a Location, the
    /// accessory answers No Response.
    func update(now: ContinuousClock.Instant = .now) async {
        guard let location = context.location else {
            say("No Location: set it under Settings, Bridge, for the weather to show", level: .warning)
            context.accessory(id: Self.accessoryID)?.isUnavailable = true
            next = nil
            return
        }
        guard !context.isExcluded(Self.deviceID) else { return }
        // The same place, whatever its name: a renamed Location asks nothing.
        if let next, next.location.latitude == location.latitude, next.location.longitude == location.longitude, now < next.at { return }
        do {
            try show(try await dependencies.api.current(at: location))
            next = (location, now + dependencies.interval)
            if lastProblem != nil { logger.info("The weather answers again") }
            lastProblem = nil
        } catch {
            next = (location, now + dependencies.retry)
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
        if let accessory {
            apply(report, to: accessory)
            return
        }
        // The first report fills the accessory before it is published: HomeKit (and every reader) never sees it
        // without its values.
        let made = Self.makeAccessory()
        apply(report, to: made)
        try context.add(made)
        let published = context.accessory(id: Self.accessoryID) ?? made
        if published !== made { apply(report, to: published) }
        accessory = published
    }

    private func apply(_ report: WeatherReport, to accessory: Accessory) {
        accessory.isUnavailable = false
        let temperature = accessory.service(.temperatureSensor)
        set(temperature, .currentTemperature, report.temperature)
        set(temperature, EveCharacteristic.airPressure, report.pressure)
        temperature?.characteristic(EveCharacteristic.weatherCondition).value = .string(report.condition)
        set(temperature, EveCharacteristic.windSpeed, report.windSpeed)
        set(temperature, EveCharacteristic.rainLastHour, report.rainLastHour)
        set(temperature, EveCharacteristic.uvIndex, report.uvIndex)
        set(accessory.service(.humiditySensor), .currentRelativeHumidity, report.humidity)
        accessory.service(.occupancySensor)?.characteristic(.occupancyDetected).value = .int(report.isRaining ? 1 : 0)
    }

    /// A reading within its characteristic's bounds (a value off the scale is the end of it, one not a number the
    /// least) and to its step, in its format.
    func set(_ service: Service?, _ type: CharacteristicType, _ value: Double) {
        guard let service else { return }
        let low = type.minValue ?? -.greatestFiniteMagnitude, high = type.maxValue ?? .greatestFiniteMagnitude
        var fitted = value.isFinite ? min(high, max(low, value)) : low
        // To the nearest step (a whole number for an integer format), as people round: 9.95 °C is 10.
        let step = type.format == .float ? (type.minStep ?? 0) : 1
        if step > 0 { let scale = 1 / step; fitted = (fitted * scale).rounded() / scale }
        if let coerced = type.coerce(.double(fitted)) { service.characteristic(type).value = coerced }
    }

    private static func makeAccessory() -> Accessory {
        let humidity = Service(.humiditySensor, name: "Humidity", subtype: "humidity")
        let raining = Service(.occupancySensor, name: "Is raining", subtype: "raining")
        let temperature = Service(
            .temperatureSensor, name: accessoryName,
            optional: [EveCharacteristic.airPressure, EveCharacteristic.weatherCondition, EveCharacteristic.windSpeed, EveCharacteristic.rainLastHour, EveCharacteristic.uvIndex],
            linked: [humidity, raining], isPrimary: true)
        // Without a MAC or a serial of its own, the serial is the device's id (CLAUDE.md).
        return Accessory(
            id: accessoryID, name: accessoryName, manufacturer: "Open-Meteo", model: "Weather",
            serialNumber: deviceID, firmwareRevision: PluginHost.version, category: .sensor, services: [temperature, humidity, raining])
    }
}

// Split-cache benchmark: independent follow-up project revision.
