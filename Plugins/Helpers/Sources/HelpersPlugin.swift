import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Helpers (GLOSSARY.md, "Helper"): accessories whose state the bridge derives from other accessories, with no device
/// behind them. A Threshold is on while a reading is past a value, with hysteresis; a Combine is the lowest, highest or
/// average of several sensors of one measure; a Stays is on once something has been in a state for a while.
///
/// Each Helper is an entry of the block's `_accessories`, by a Device Id Setup gives it (Add a Helper…), holding its rule
/// (`rule`, its Device Kind) and its sources, each `<accessory id>#<iid>`: ids and iids stay the same across restarts. The
/// plugin reads the sources on the host's servers and follows their changes; a source missing or No Response makes the
/// Helper No Response. A change of its settings reloads the plugin.
public actor HelpersPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
    }

    /// What tests shorten: how long a minute is (a Stays' duration), and how a new Helper's Device Id is made.
    struct Dependencies: Sendable {
        var minute: Duration = .seconds(60)
        var newID: @Sendable () -> String = { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }
    }

    public static let platform = "Helpers"
    public static let name = "Helpers"
    public static let icon: String? = "sensor"
    public static let summary: String? = "Sensors the bridge works out from your other accessories"
    public static let addsDevicesByAddress = true
    public static let newDeviceLabel: String? = "Add a Helper…"

    /// A running Helper: its rule, what it shows, and where its rule stands.
    struct Running {
        var rule: HelperRule
        let accessory: Accessory
        /// Occupancy Detected for a Threshold or a Stays, the measure for a Combine.
        let output: Characteristic
        /// A Combine of power's Eve Current Consumption, beside the light level that carries the watts.
        let watts: Characteristic?
        var isOn = false
        /// A Stays: since when its source has been in the state, and the wake-up at the end of its duration.
        var since: ContinuousClock.Instant?
        var timer: Task<Void, Never>?
    }

    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var helpers: [String: Running] = [:]
    /// The Helpers reading each accessory, by its id.
    private var readers: [String: Set<String>] = [:]
    private var observations: [Observation] = []
    /// Which Helpers to look at again: an accessory's id, or nil for every one (accessories added or removed).
    private var wake: AsyncStream<String?>.Continuation?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(context: context, dependencies: Dependencies())
    }

    init(context: PluginContext, dependencies: Dependencies) {
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    public func start() async throws {
        // A Helper whose settings do not work (an off value set past its on value) keeps its accessory, No Response, so
        // HomeKit keeps its room and automations until the settings are put right.
        var broken: Set<String> = []
        for (deviceID, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key }) where !settings.excluded {
            do {
                let rule = try HelperRule(settings: settings.plugin)
                try add(deviceID: deviceID, name: settings.name ?? "Helper", rule: rule)
            } catch {
                logger.error("The Helper \(settings.name ?? deviceID) \(error)")
                if settings.plugin["rule"] != nil {
                    broken.insert(Self.accessoryID(deviceID: deviceID))
                    context.accessory(id: Self.accessoryID(deviceID: deviceID))?.isUnreachable = true
                }
            }
        }
        await context.removeAccessories(keeping: Set(helpers.keys.map(Self.accessoryID)).union(broken), message: "Removing a Helper no longer set up")

        // Only the sources' changes reach the actor: the rest of the bridge's never wait on it, nor push one out.
        let (stream, continuation) = AsyncStream<String?>.makeStream()
        wake = continuation
        let watched = Set(readers.keys)
        if let changes = context.observeHostChanges({ accessory, _, _ in if watched.contains(accessory.id) { continuation.yield(accessory.id) } }) {
            observations.append(changes)
        }
        if let structure = context.observeHostStructure({ continuation.yield(nil) }) { observations.append(structure) }
        tasks.add { [weak self] in
            for await id in stream {
                await self?.sourceChanged(id)
            }
        }
        for id in helpers.keys { evaluate(id) }
    }

    public func stop() async {
        for observation in observations { observation.cancel() }
        observations = []
        wake?.finish()
        wake = nil
        for id in helpers.keys { helpers[id]?.timer?.cancel() }
        tasks.cancelAll()
    }

    /// A change on one accessory, or (nil) accessories added or removed: the Helpers it concerns look again.
    func sourceChanged(_ accessoryID: String?) {
        guard let accessoryID else {
            for id in helpers.keys { evaluate(id) }
            return
        }
        for id in readers[accessoryID] ?? [] { evaluate(id) }
    }

    // MARK: Accessories

    private func add(deviceID: String, name: String, rule: HelperRule) throws {
        let output: Characteristic
        var watts: Characteristic?
        let service: Service
        switch rule {
        case .threshold, .stays:
            service = Service(.occupancySensor, name: name, isPrimary: true)
            output = service.characteristic(.occupancyDetected)
            output.value = .int(0)
        case .combine(let measure, _, _):
            if measure == .power {
                let consumption = Characteristic(EveCharacteristic.currentConsumption, value: .int(0))
                service = Service(measure.service, name: name, extra: [consumption], isPrimary: true)
                watts = consumption
            } else {
                service = Service(measure.service, name: name, isPrimary: true)
            }
            output = service.characteristic(measure.service == .lightSensor ? .currentAmbientLightLevel : measure.characteristic)
        }
        let accessory = Accessory(
            id: Self.accessoryID(deviceID: deviceID), name: name, manufacturer: "Homeswift", model: "\(rule.kind.title) Helper",
            serialNumber: deviceID.uppercased(), category: .sensor, services: [service])
        // No Response until its sources have been read.
        accessory.isUnreachable = true
        try context.add(accessory)
        helpers[deviceID] = Running(rule: rule, accessory: accessory, output: output, watts: watts)
        for source in rule.sources { readers[source.accessoryID, default: []].insert(deviceID) }
    }

    /// A source's reading now; nil when its accessory is gone, No Response, or has no such characteristic or number.
    private func read(_ source: SourceRef) -> Double? {
        guard let accessory = context.hostAccessory(id: source.accessoryID), !accessory.showsNoResponse else { return nil }
        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.iid == source.iid }) { return characteristic.value.doubleValue }
        }
        return nil
    }

    /// Works out a Helper's state from its sources' readings and shows it.
    func evaluate(_ id: String) {
        guard var helper = helpers[id] else { return }
        defer { helpers[id] = helper }
        let readings = helper.rule.sources.map(read)
        let values = readings.compactMap { $0 }
        guard values.count == readings.count else {
            // A source missing or No Response: so is the Helper, and a Stays counts again once it is back.
            helper.accessory.isUnreachable = true
            helper.since = nil
            helper.timer?.cancel()
            helper.timer = nil
            return
        }
        switch helper.rule {
        case .threshold(_, let above, let on, let off):
            helper.isOn = HelperRule.threshold(was: helper.isOn, value: values[0], above: above, on: on, off: off)
            helper.output.value = .int(helper.isOn ? 1 : 0)
        case .combine(let measure, let function, _):
            guard let value = function.apply(values) else { return }
            helper.output.value = .double(Self.clamped(value, to: helper.output.type))
            if measure == .power { helper.watts?.value = .int(Int(Self.clamped(value.rounded(), to: EveCharacteristic.currentConsumption))) }
        case .stays(_, let state, let minutes):
            if abs(values[0] - state) < 0.000_1 {
                let now = ContinuousClock.now
                let since = helper.since ?? now
                helper.since = since
                let left = dependencies.minute * minutes - (now - since)
                helper.isOn = left <= .zero
                if !helper.isOn, helper.timer == nil {
                    helper.timer = Task { [weak self] in
                        try? await Task.sleep(for: left)
                        guard !Task.isCancelled else { return }
                        await self?.timerFired(id)
                    }
                }
            } else {
                helper.isOn = false
                helper.since = nil
                helper.timer?.cancel()
                helper.timer = nil
            }
            helper.output.value = .int(helper.isOn ? 1 : 0)
        }
        helper.accessory.isUnreachable = false
    }

    private func timerFired(_ id: String) {
        helpers[id]?.timer = nil
        evaluate(id)
    }

    /// A value within what the characteristic takes: a light level is at least 0.0001 lux, a temperature at most 100 °C.
    static func clamped(_ value: Double, to type: CharacteristicType) -> Double {
        min(max(value, type.minValue ?? -.infinity), type.maxValue ?? .infinity)
    }

    // MARK: For Setup and the settings

    /// A running Helper's name now, which a rename changes without a reload.
    func helperName(_ deviceID: String) -> String? { helpers[deviceID]?.accessory.name }

    /// Whether a Helper answers: none of its sources missing or No Response.
    func isReachable(_ deviceID: String) -> Bool? {
        helpers[deviceID].map { !$0.accessory.isUnreachable }
    }
}
