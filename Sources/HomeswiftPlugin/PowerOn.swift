import Foundation
import Logging
import NIOConcurrencyHelpers

// Power On (GLOSSARY.md): what a light does when its power comes back, from a wall switch or after a power cut. The
// device keeps it (a Hue light's `powerup`, a Matter light's StartUp attributes, a Zigbee light's power-on behaviour),
// read and written through its plugin (`HomeswiftPlugin.powerOn`, `setPowerOn`), so a change made in the maker's app
// shows here. Natural Light is the bridge's own: the light comes back as it was, on or off, in the white for the time
// of day, which the bridge keeps writing to the device as the day goes (`NaturalLight`). It is every light's that can
// have it, until a person gives the light one of its device's own (the Core Accessory Setting `naturalLight`, false).

/// What a light does when its power comes back.
public struct PowerOn: Sendable, Equatable {
    public enum Behaviour: String, Sendable, CaseIterable {
        /// As it was, on or off, in the white for the time of day (the bridge's Natural Light).
        case natural
        /// The device's own default (a Hue light's: on, warm white, full brightness).
        case `default`
        /// On, in its last colour and brightness.
        case lastOn
        /// As it was before the power went, on or off, in its last colour and brightness.
        case powerLoss
        /// Stays off.
        case off
        /// On, at `brightness` and `temperature` (each nil: its last).
        case custom
    }

    public var behaviour: Behaviour
    /// 1 to 100 %, with `custom`.
    public var brightness: Int?
    /// Kelvin: `custom`'s white, or Natural Light's for now.
    public var temperature: Int?

    public init(_ behaviour: Behaviour, brightness: Int? = nil, temperature: Int? = nil) {
        (self.behaviour, self.brightness, self.temperature) = (behaviour, brightness, temperature)
    }

    /// The white in mirek, as Hue, Matter and Zigbee keep it.
    public var mirek: Int? { temperature.map(Self.mirek(kelvin:)) }

    public static func mirek(kelvin: Int) -> Int { Int((1_000_000 / Double(max(1, kelvin))).rounded()) }
    public static func kelvin(mirek: Int) -> Int { Int((1_000_000 / Double(max(1, mirek))).rounded()) }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["behaviour": .string(behaviour.rawValue)]
        if let brightness { object["brightness"] = .number(Double(brightness)) }
        if let temperature { object["temperature"] = .number(Double(temperature)) }
        return .object(object)
    }

    /// One from a request: `behaviour`, and with `custom` its `brightness` (1-100) and `temperature` (Kelvin).
    public init(json: JSONValue) throws {
        guard let name = json["behaviour"]?.stringValue, let behaviour = Behaviour(rawValue: name) else {
            throw PowerOnError("behaviour is one of \(Behaviour.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.behaviour = behaviour
        guard behaviour == .custom else { return }
        if let value = json["brightness"], !value.isNull {
            guard let level = value.intValue, (1...100).contains(level) else { throw PowerOnError("brightness is 1 to 100 %") }
            brightness = level
        }
        if let value = json["temperature"], !value.isNull {
            guard let kelvin = value.intValue, (1000...10000).contains(kelvin) else { throw PowerOnError("temperature is in Kelvin, 2000 to 6500 for most lights") }
            temperature = kelvin
        }
    }
}

/// What a light's device can do when its power comes back.
public struct PowerOnSupport: Sendable, Equatable {
    /// The behaviours it keeps; `natural` when it can come back as it was in a white the bridge gives it.
    public var behaviours: [PowerOn.Behaviour]
    /// Whether `custom` takes a brightness.
    public var brightness: Bool
    /// The whites it takes, in Kelvin; nil for a light without colour temperature.
    public var white: ClosedRange<Int>?

    public init(behaviours: [PowerOn.Behaviour], brightness: Bool, white: ClosedRange<Int>?) {
        (self.behaviours, self.brightness, self.white) = (behaviours, brightness, white)
    }

    public var json: JSONValue {
        ["behaviours": .array(behaviours.map { .string($0.rawValue) }), "brightness": .bool(brightness),
         "white": white.map { [.number(Double($0.lowerBound)), .number(Double($0.upperBound))] } ?? .null]
    }
}

public struct PowerOnError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The white for the time of day (Natural Light): warm at night, rising after sunrise to its coolest at midday, warm
/// again through the evening. By the sun at the Location, else by a 7:00 sunrise and a 19:00 sunset.
public enum NaturalLight {
    public static let night = 2200, morning = 4000, midday = 5000, evening = 2700

    /// The white at `date`, in Kelvin.
    public static func temperature(at date: Date, location: Location?, calendar: Calendar = .current) -> Int {
        let sun = location.map { Solar.times(on: date, latitude: $0.latitude, longitude: $0.longitude) }
        let dayStart = calendar.startOfDay(for: date)
        let sunrise = sun?.sunrise ?? dayStart.addingTimeInterval(7 * 3600)
        let sunset = sun?.sunset ?? dayStart.addingTimeInterval(19 * 3600)
        guard sunset > sunrise else { return night }
        let noon = sunrise.addingTimeInterval(sunset.timeIntervalSince(sunrise) / 2)
        let hour: TimeInterval = 3600
        // The curve's points, from before sunrise to after sunset.
        let points: [(Date, Int)] = [
            (sunrise.addingTimeInterval(-hour), night), (sunrise.addingTimeInterval(hour), morning), (noon, midday),
            (sunset.addingTimeInterval(-2 * hour), morning), (sunset, evening), (sunset.addingTimeInterval(2 * hour), night),
        ]
        guard let first = points.first, let last = points.last, date > first.0, date < last.0 else { return night }
        for (from, to) in zip(points, points.dropFirst()) where date <= to.0 {
            let share = date.timeIntervalSince(from.0) / max(1, to.0.timeIntervalSince(from.0))
            return Int((Double(from.1) + (Double(to.1) - Double(from.1)) * share).rounded())
        }
        return night
    }
}

/// Keeps every Natural Light light's power-on white the time of day's: at start, then every ten minutes, a light whose
/// white moved by `step` mirek or more since it was written; a light whose setting changed at once (`refresh`). What
/// the lights are and how to reach their plugins is the host's (`lights`).
final class NaturalLightRunner: Sendable {
    /// A light that may have Natural Light: its accessory, the plugin that has it, and whether its setting wants it.
    struct Light: Sendable {
        var accessoryID: String
        var name: String
        var plugin: any HomeswiftPlugin
        var wantsNatural: Bool
    }

    static let interval: Duration = .seconds(600)
    /// The least change worth a write: about 50 a day for each light, over the curve.
    static let step = 10

    private let lights: @Sendable () -> [Light]
    private let location: @Sendable () -> Location?
    private let now: @Sendable () -> Date
    private let logger: Logger
    private let state = NIOLockedValueBox<(written: [String: Int], failed: Set<String>, task: Task<Void, Never>?)>(([:], [], nil))

    init(lights: @escaping @Sendable () -> [Light], location: @escaping @Sendable () -> Location?, now: @escaping @Sendable () -> Date = Date.init,
         logger: Logger) {
        (self.lights, self.location, self.now, self.logger) = (lights, location, now, logger)
    }

    /// Starts the rounds, the first `after` the plugins had time to read their devices.
    func start(after delay: Duration = .seconds(30)) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
        state.withLockedValue { $0.task = task }
    }

    func stop() {
        state.withLockedValue { $0.task?.cancel(); $0.task = nil }
    }

    /// Writes the white to the lights that want it and are behind; `only`, to one light (its setting just changed),
    /// whatever it was given before. A light that no longer wants it is forgotten, so it is written again when it does.
    func refresh(only accessoryID: String? = nil) async {
        let kelvin = NaturalLight.temperature(at: now(), location: location())
        for light in lights() where accessoryID == nil || light.accessoryID == accessoryID {
            guard light.wantsNatural else {
                state.withLockedValue { $0.written[light.accessoryID] = nil }
                continue
            }
            if accessoryID != nil { state.withLockedValue { $0.written[light.accessoryID] = nil } }
            guard let support = await light.plugin.powerOnSupport(of: light.accessoryID), support.behaviours.contains(.natural),
                  let range = support.white else { continue }
            let white = min(range.upperBound, max(range.lowerBound, kelvin))
            let behind = state.withLockedValue { state in
                state.written[light.accessoryID].map { abs(PowerOn.mirek(kelvin: $0) - PowerOn.mirek(kelvin: white)) >= Self.step } ?? true
            }
            guard behind else { continue }
            do {
                try await light.plugin.setPowerOn(PowerOn(.natural, temperature: white), of: light.accessoryID)
                let first = state.withLockedValue { state in
                    defer { state.written[light.accessoryID] = white; state.failed.remove(light.accessoryID) }
                    return state.written[light.accessoryID] == nil
                }
                if first { logger.info("Natural Light: \(light.name) comes back in the white for the time of day", metadata: ["accessory": "\(light.accessoryID)", "kelvin": "\(white)"]) }
            } catch {
                if state.withLockedValue({ $0.failed.insert(light.accessoryID).inserted }) {
                    logger.warning("Natural Light: could not give \(light.name) its white: \(error)", metadata: ["accessory": "\(light.accessoryID)"])
                }
            }
        }
    }
}
