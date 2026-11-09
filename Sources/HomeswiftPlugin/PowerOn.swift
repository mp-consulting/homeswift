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

    /// One whose whites a device gives in mirek (Hue, Matter, Zigbee): the warmest is the most mirek.
    public init(behaviours: [PowerOn.Behaviour], brightness: Bool, mirek: ClosedRange<Int>?) {
        self.init(behaviours: behaviours, brightness: brightness, white: mirek.map { PowerOn.kelvin(mirek: $0.upperBound)...PowerOn.kelvin(mirek: $0.lowerBound) })
    }

    /// `kelvin` within its whites; nil for a light without them.
    public func white(_ kelvin: Int) -> Int? {
        white.map { min($0.upperBound, max($0.lowerBound, kelvin)) }
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
        // The solar day whose evening or morning `date` is in: `Solar.times` takes the day by its UTC date, which west of
        // Greenwich is already tomorrow's by the evening (and east, still yesterday's in the early morning).
        let days = location.map { location in
            [-1, 0, 1].map { offset in Solar.times(on: date.addingTimeInterval(Double(offset) * 86400), latitude: location.latitude, longitude: location.longitude) }
        }
        let sun = days?.first { day in
            guard let sunrise = day.sunrise, let sunset = day.sunset else { return false }
            return date >= sunrise.addingTimeInterval(-3600) && date <= sunset.addingTimeInterval(2 * 3600)
        } ?? days?[1]
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
/// white moved by `step` mirek or more since it was written; a light whose setting changed at once (`refresh`). Each
/// plugin's lights one after another, the plugins side by side. Before writing again, it reads what the light keeps: a
/// light whose power-on was changed elsewhere since (its maker's app) is the person's choice, and leaves Natural Light
/// (`takenOver`). What the lights are and how to reach their plugins is the host's (`lights`).
final class NaturalLightRunner: Sendable {
    /// A light that may have Natural Light: its accessory, the plugin that has it, and whether its setting wants it.
    struct Light: Sendable {
        var accessoryID: String
        var name: String
        var plugin: any HomeswiftPlugin
        var wantsNatural: Bool
    }

    static let interval: Duration = .seconds(600)
    /// The first round, once the plugins had time to read their devices.
    static let firstRound: Duration = .seconds(30)
    /// The least change worth a write: about 50 a day for each light, over the curve.
    static let step = 10

    private let lights: @Sendable () -> [Light]
    private let location: @Sendable () -> Location?
    private let takenOver: @Sendable (_ accessoryID: String) async -> Void
    /// The time, which tests move.
    private let now: @Sendable () -> Date
    private let logger: Logger
    /// The white each light was given (Kelvin, within its whites) and the white for now it was asked for when it was
    /// (unclamped): a light whose asked-for white did not move by `step` is not asked about at all.
    private let state = NIOLockedValueBox<(written: [String: (white: Int, asked: Int)], busy: Set<String>, failed: Set<String>, task: Task<Void, Never>?)>(([:], [], [], nil))

    init(lights: @escaping @Sendable () -> [Light], location: @escaping @Sendable () -> Location?,
         takenOver: @escaping @Sendable (_ accessoryID: String) async -> Void, now: @escaping @Sendable () -> Date = Date.init, logger: Logger) {
        (self.lights, self.location, self.takenOver, self.now, self.logger) = (lights, location, takenOver, now, logger)
    }

    func start() {
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.firstRound)
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

    private static func close(_ a: Int, _ b: Int, within mirek: Int) -> Bool {
        abs(PowerOn.mirek(kelvin: a) - PowerOn.mirek(kelvin: b)) < mirek
    }

    /// Writes the white to the lights that want it and are behind; `only`, to one light (its setting just changed),
    /// whatever it was given before. A light that no longer wants it is forgotten, so it is written again when it does.
    func refresh(only accessoryID: String? = nil) async {
        let kelvin = NaturalLight.temperature(at: now(), location: location())
        let due = lights().filter { light in
            guard accessoryID == nil || light.accessoryID == accessoryID else { return false }
            return state.withLockedValue { state in
                if accessoryID != nil || !light.wantsNatural { state.written[light.accessoryID] = nil }
                guard light.wantsNatural, !state.busy.contains(light.accessoryID) else { return false }
                if let written = state.written[light.accessoryID], Self.close(written.asked, kelvin, within: Self.step) { return false }
                state.busy.insert(light.accessoryID)
                return true
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for lights in Dictionary(grouping: due, by: { ObjectIdentifier($0.plugin as AnyObject) }).values {
                group.addTask { for light in lights { await self.write(light, kelvin: kelvin) } }
            }
        }
    }

    private func write(_ light: Light, kelvin: Int) async {
        defer { state.withLockedValue { _ = $0.busy.remove(light.accessoryID) } }
        guard let support = await light.plugin.powerOnSupport(of: light.accessoryID), support.behaviours.contains(.natural),
              let white = support.white(kelvin) else { return }
        let written = state.withLockedValue { $0.written[light.accessoryID] }
        // Changed since it was given its white: the person's own choice now, read from the light.
        if let written, let kept = try? await light.plugin.powerOn(of: light.accessoryID),
           kept.temperature.map({ !Self.close($0, written.white, within: 3) }) ?? true {
            state.withLockedValue { $0.written[light.accessoryID] = nil }
            logger.info("Natural Light: \(light.name)'s power-on was changed elsewhere, so it keeps that one", metadata: ["accessory": "\(light.accessoryID)"])
            await takenOver(light.accessoryID)
            return
        }
        guard written.map({ !Self.close($0.white, white, within: Self.step) }) ?? true else {
            state.withLockedValue { $0.written[light.accessoryID]?.asked = kelvin }
            return
        }
        do {
            try await light.plugin.setPowerOn(PowerOn(.natural, temperature: white), of: light.accessoryID)
            state.withLockedValue { state in
                state.written[light.accessoryID] = (white, kelvin)
                state.failed.remove(light.accessoryID)
            }
            if written == nil { logger.info("Natural Light: \(light.name) comes back in the white for the time of day", metadata: ["accessory": "\(light.accessoryID)", "kelvin": "\(white)"]) }
        } catch {
            if state.withLockedValue({ $0.failed.insert(light.accessoryID).inserted }) {
                logger.warning("Natural Light: could not give \(light.name) its white: \(error)", metadata: ["accessory": "\(light.accessoryID)"])
            }
        }
    }
}

extension NaturalLight {
    /// The white at `date` within a light's whites.
    public static func temperature(at date: Date, location: Location?, for support: PowerOnSupport) -> Int? {
        support.white(temperature(at: date, location: location))
    }
}
