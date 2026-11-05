import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The states of every device of the last listing, by deviceURL, as events change them. Mappers read their device's,
/// their attached sensors' and their parent's states here.
final class StateStore: Sendable {
    private let states = NIOLockedValueBox<[String: [String: JSONValue]]>([:])

    func replaceAll(_ devices: [OverkizDevice]) {
        states.withLockedValue { states in
            states = Dictionary(devices.map { ($0.deviceURL, $0.states) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func value(_ deviceURL: String, _ name: String) -> JSONValue? {
        states.withLockedValue { $0[deviceURL]?[name] }
    }

    func states(of deviceURL: String) -> [String: JSONValue] {
        states.withLockedValue { $0[deviceURL] ?? [:] }
    }

    /// Applies new values to a known device and answers those that changed or are new, compared as JSON (an object
    /// state changes too, docs/clean-room/Tahoma.md 10.8). An unknown device changes nothing.
    func apply(_ deviceURL: String, _ new: [String: JSONValue]) -> [String: JSONValue] {
        states.withLockedValue { states in
            guard var current = states[deviceURL] else { return [:] }
            var changed: [String: JSONValue] = [:]
            for (name, value) in new where current[name] != value {
                current[name] = value
                changed[name] = value
            }
            states[deviceURL] = current
            return changed
        }
    }
}

/// A device's options (docs/clean-room/Tahoma.md 2.4), merged from `devicesConfig` and its Accessory Settings. Numbers
/// that are 0 or absent take their default, as the Homebridge plugin's did.
struct DeviceOptions: Sendable, Equatable {
    var reverse = false
    var defaultPosition = 0.0
    var initPosition: Double?
    var movementDuration = 0.0
    var offsetMovementDuration = 0.0
    var blindMode = false
    var blindsOnRollerShutter = false
    /// `true`, or a daily window `HH:MM-HH:MM`.
    var lowSpeed: JSONValue = false
    var cyclic = false
    var cycleDuration = 5.0
    var pedestrianDuration = 0.0
    var stayZones = "A"
    var nightZones = "B"
    var derogationDuration = 1.0
    var comfort = 19.0
    var eco = 17.0

    init() {}

    init(_ fields: [String: JSONValue]) {
        func flag(_ key: String) -> Bool { fields[key]?.boolValue ?? (fields[key]?.number.map { $0 != 0 } ?? false) }
        // At most a day (durations in seconds, temperatures): an option is written through the UI and MCP too.
        func number(_ key: String) -> Double? { fields[key]?.number.flatMap { $0 != 0 && $0.isFinite ? min(max($0, -86400), 86400) : nil } }
        func text(_ key: String) -> String? { fields[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        reverse = flag("reverse")
        defaultPosition = min(100, max(0, number("defaultPosition") ?? 0))
        initPosition = number("initPosition")
        movementDuration = max(0, number("movementDuration") ?? 0)
        offsetMovementDuration = number("offsetMovementDuration") ?? 0
        blindMode = flag("blindMode")
        blindsOnRollerShutter = flag("blindsOnRollerShutter")
        lowSpeed = fields["lowSpeed"] ?? false
        cyclic = flag("cyclic")
        cycleDuration = max(0, number("cycleDuration") ?? 5)
        pedestrianDuration = max(0, number("pedestrianDuration") ?? 0)
        stayZones = text("stayZones") ?? "A"
        nightZones = text("nightZones") ?? "B"
        derogationDuration = number("derogationDuration") ?? 1
        comfort = number("comfort") ?? 19
        eco = number("eco") ?? 17
    }

    /// The keys a device's options have, in `devicesConfig` and in `_accessories`.
    static let keys = [
        "reverse", "defaultPosition", "initPosition", "movementDuration", "offsetMovementDuration", "blindMode", "blindsOnRollerShutter",
        "lowSpeed", "cyclic", "cycleDuration", "pedestrianDuration", "stayZones", "nightZones", "derogationDuration", "comfort", "eco",
    ]
}

/// What a mapper reaches outside its device.
struct MapperEnvironment: Sendable {
    var executions: Executions
    var store: StateStore
    var logger: Logger
    /// Multiplies every delay a mapper waits (debounce, timed stops, cycles): 1 for real devices.
    var timeScale: Double = 1
    /// Asks the gateway for a device's states again.
    var refreshDevice: @Sendable (String) async -> Void = { _ in }
    var now: @Sendable () -> Date = { Date() }
    var calendar = Calendar.current
}

/// The HomeKit side of one exposed device (docs/clean-room/Tahoma.md 5), chosen from its uiClass and widget: it builds the
/// services, turns the device's states into characteristic values, and HomeKit's writes into commands.
///
/// A subclass overrides `build()`, `apply(_:from:)` and, for those that read several states together, `computeStates()`.
/// Mutable state lives in characteristics and in a lock; handlers capture the mapper weakly.
class Mapper: @unchecked Sendable {
    let device: OverkizDevice
    /// The sub-devices attached as its sensors (5.2), whose states it reads too.
    let sensors: [OverkizDevice]
    /// The main device of its group, for a sub-device exposed on its own.
    let parent: OverkizDevice?
    let options: DeviceOptions
    let environment: MapperEnvironment
    /// No usable states: the device is never fed any, and HomeKit follows its executions' outcomes instead.
    private(set) var stateless = false
    private let lock = NIOLockedValueBox(Mutable())
    private let debounce: LatestCallGuard

    private struct Mutable {
        var inFlight: Set<String> = []
        var timers: [String: Task<Void, Never>] = [:]
    }

    /// The states whose absence makes the device stateless (5.2, step 2); none for most mappers.
    class var expectedStates: [String] { [] }

    /// The HomeKit category of its accessory.
    class var category: AccessoryCategory { .other }

    /// Its Device Kind, for the Accessory Settings that apply to it.
    class var kind: String { "other" }

    required init(device: OverkizDevice, sensors: [OverkizDevice], parent: OverkizDevice?, options: DeviceOptions, environment: MapperEnvironment) {
        self.device = device
        self.sensors = sensors
        self.parent = parent
        self.options = options
        self.environment = environment
        debounce = LatestCallGuard(delay: .milliseconds(Int(500 * environment.timeScale)))
        let expected = Self.expectedStates
        stateless = !device.hasStates || (!expected.isEmpty && !expected.contains { device.states[$0] != nil })
    }

    var label: String { device.label }
    var logger: Logger { environment.logger }

    /// The services: the main one first, named with the device's label. Throws for a device the mapper cannot show.
    func build() throws -> [Service] { [] }

    /// New or changed values of the device's (or an attached sensor's) states.
    func apply(_ states: [String: JSONValue], from deviceURL: String) {}

    /// Recomputes what several states decide together, after a batch of changes.
    func computeStates() {}

    // MARK: States

    /// A state of the device, as it is now.
    func state(_ name: String) -> JSONValue? { environment.store.value(device.deviceURL, name) }

    func hasState(_ name: String) -> Bool { state(name) != nil || device.states[name] != nil }

    func string(_ name: String) -> String? { state(name)?.scalarText }

    func number(_ name: String) -> Double? { state(name)?.number }

    /// The parent's state (a zone reading its heat pump's operating mode).
    func parentState(_ name: String) -> JSONValue? { parent.flatMap { environment.store.value($0.deviceURL, name) } }

    /// Feeds states to the mapper unless it is stateless; `log` logs each at debug.
    func receive(_ states: [String: JSONValue], from deviceURL: String, log: Bool) {
        guard !stateless, !states.isEmpty else { return }
        if log {
            for (name, value) in states.sorted(by: { $0.key < $1.key }) { logger.debug("[\(label)] \(name) => \(value.text())") }
        }
        apply(states, from: deviceURL)
        computeStates()
    }

    /// Everything the device and its sensors report now, once, without logging.
    func receiveCurrentStates() {
        guard !stateless else { return }
        for url in [device.deviceURL] + sensors.map(\.deviceURL) {
            let states = environment.store.states(of: url)
            if !states.isEmpty { apply(states, from: url) }
        }
        computeStates()
    }

    // MARK: Executions

    /// Whether none of the mapper's executions is in flight: a target follows the device only then (6.4).
    var isIdle: Bool { lock.withLockedValue { $0.inFlight.isEmpty } }

    /// Waits 500 ms and says whether this is still the latest write for `key` (a slider sends one command, not thirty).
    func debounced(_ key: String) async -> Bool { await debounce(key) }

    func scaled(_ seconds: Double) -> Duration { scaledDuration(seconds, by: environment.timeScale) }

    /// Sends commands for the device (6.4); `feedback` hears each state of its action. An empty list is "No target
    /// command" (HAP's resource does not exist); a failed post is a communication failure.
    @discardableResult
    func execute(_ commands: [OverkizCommand], standalone: Bool = false, feedback: @escaping @Sendable (ExecutionUpdate) -> Void = { _ in }) async throws -> String {
        guard !commands.isEmpty else {
            logger.error("No target command for \(label)")
            throw HAPStatusError(.resourceDoesNotExist)
        }
        for command in commands { logger.info("[\(label)] \(command)") }
        let token = UUID().uuidString
        lock.withLockedValue { _ = $0.inFlight.insert(token) }
        let names = commands.map(\.name).joined(separator: ", ")
        let label = label, logger = logger
        let observer: ExecutionObserver = { [weak self] update in
            switch update.state {
            case .failed: logger.error("[\(label)] \(names) \(update.failureType ?? "FAILED")")
            case .completed: logger.info("[\(label)] \(names) COMPLETED")
            default: logger.debug("[\(label)] \(names) \(update.state.rawValue)")
            }
            if update.state.isFinal { self?.lock.withLockedValue { _ = $0.inFlight.remove(token) } }
            feedback(update)
        }
        do {
            return try await environment.executions.submit(
                deviceURL: device.deviceURL, label: label, commands: commands, highPriority: hasState("io:PriorityLockLevelState"),
                standalone: standalone, observer: observer)
        } catch {
            lock.withLockedValue { _ = $0.inFlight.remove(token) }
            logger.error("[\(label)] \(names) \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// `on` or `off`.
    func writeOnOff(_ on: Bool) async throws {
        try await execute([OverkizCommand(on ? "on" : "off")])
    }

    /// Runs `body` after `delay` unless another timer of the same key replaces it first.
    func schedule(_ key: String, after delay: Duration, _ body: @escaping @Sendable () async -> Void) {
        let task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await body()
        }
        let previous = lock.withLockedValue { state -> Task<Void, Never>? in
            let previous = state.timers[key]
            state.timers[key] = task
            return previous
        }
        previous?.cancel()
    }

    /// The end of a timed move: `stop` once the move's execution ended, else that execution cancelled.
    func stopMovement(execID: String) async {
        if isIdle {
            _ = try? await execute([OverkizCommand("stop")], standalone: true)
        } else {
            try? await environment.executions.cancel(execID)
        }
    }

    func cancelTimer(_ key: String) {
        lock.withLockedValue { $0.timers.removeValue(forKey: key) }?.cancel()
    }

    /// Stops the mapper's timers (the plugin stops, or the accessory is rebuilt).
    func stop() {
        let timers = lock.withLockedValue { state -> [Task<Void, Never>] in
            defer { state.timers = [:] }
            return Array(state.timers.values)
        }
        timers.forEach { $0.cancel() }
    }
}

/// `seconds` times a test's time scale.
func scaledDuration(_ seconds: Double, by timeScale: Double) -> Duration {
    let milliseconds = (seconds * 1000 * timeScale).rounded()
    guard milliseconds.isFinite, milliseconds > 0 else { return .zero }
    return .milliseconds(Int(min(milliseconds, 1e15)))
}

extension Characteristic {
    /// Sets a number within the characteristic's bounds: a device may report what HomeKit would refuse.
    func setClamped(_ value: Double?) {
        guard let value, value.isFinite else { return }
        var clamped = value
        if let minimum = type.minValue { clamped = Swift.max(minimum, clamped) }
        if let maximum = type.maxValue { clamped = Swift.min(maximum, clamped) }
        switch type.format {
        case .float: self.value = .double(clamped)
        default: self.value = .int(Int(clamped.rounded()))
        }
    }
}

extension Service {
    /// A characteristic's value as a number.
    func number(_ type: CharacteristicType) -> Double? { self[type]?.value.doubleValue }
}

/// The HAP values (5.2).
enum HAP {
    static let decreasing = 0, increasing = 1, stopped = 2
    static let doorOpen = 0, doorClosed = 1, doorOpening = 2, doorClosing = 3, doorStopped = 4
    static let unsecured = 0, secured = 1, lockUnknown = 3
    static let stay = 0, away = 1, night = 2, disarm = 3, triggered = 4
    static let off = 0, heat = 1, cool = 2, auto = 3
    static let allModes = [off, heat, cool, auto]
}
