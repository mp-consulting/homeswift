import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

// Moods: a room's lights set to an ambiance (candlelight, cinema) or played as a light show (fireplace, disco,
// police siren). A mood is a list of steps, each a palette of colours spread over the lights or picked at random
// for each; it plays once or loops for a while, and an animated one puts every light back as it was when it ends
// or is stopped; one that sets the lights once can be undone for 12 hours, which puts them back as they were.
// The collection is `MoodLibrary`; the Assistant writes new ones from a description
// (`AssistantService.designMood`); an MCP client may pass its own plan.
//
// Only lightbulbs are touched, never a security control. Every light of a step is written at the same time; many
// lights fade from one colour to the next, so a step lasts at least a quarter of a second; a light that fails three
// writes in a row leaves the show (a lamp switched off at the wall).

/// What one light is set to. Brightness 0 or `on: false` turns it off.
public struct MoodColor: Codable, Sendable, Equatable {
    public var on: Bool?
    public var brightness: Double?
    public var hue: Double?
    public var saturation: Double?
    /// In mired: 140 (cool daylight) to 500 (candle).
    public var colorTemperature: Double?

    public init(on: Bool? = nil, brightness: Double? = nil, hue: Double? = nil, saturation: Double? = nil, colorTemperature: Double? = nil) {
        self.on = on
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.colorTemperature = colorTemperature
    }

    var isOff: Bool { on == false || brightness == 0 }
}

public struct MoodStep: Codable, Sendable, Equatable {
    /// `spread`: light n takes colour n (round the palette); `random`: each light picks one.
    public enum Assign: String, Codable, Sendable { case spread, random }

    public var colors: [MoodColor]
    public var assign: Assign?
    /// How long the step holds before the next.
    public var seconds: Double
    /// Each light's brightness varies by up to this much either way (a candle's flicker).
    public var jitter: Double?

    public init(_ colors: [MoodColor], assign: Assign? = nil, seconds: Double, jitter: Double? = nil) {
        self.colors = colors
        self.assign = assign
        self.seconds = seconds
        self.jitter = jitter
    }
}

public struct Mood: Codable, Sendable, Equatable {
    /// The collection's id; nil for one the Assistant or a client wrote.
    public var id: String?
    public var name: String
    public var description: String?
    /// The collection's sections: calm, animated, party, signal.
    public var category: String?
    public var steps: [MoodStep]
    /// Plays the steps again and again until `durationSeconds` is up or it is stopped.
    public var loop: Bool?
    public var durationSeconds: Double?
    /// Puts the lights back as they were at the end: by default when it loops.
    public var restore: Bool?

    public init(id: String? = nil, name: String, description: String? = nil, category: String? = nil, steps: [MoodStep], loop: Bool? = nil, durationSeconds: Double? = nil, restore: Bool? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.steps = steps
        self.loop = loop
        self.durationSeconds = durationSeconds
        self.restore = restore
    }

    /// A single step played once sets the lights and is done; anything else runs in the background.
    public var isAnimated: Bool { steps.count > 1 || loop == true }
    public var restoresAtEnd: Bool { restore ?? (loop == true) }
}

enum MoodRules {
    static let maxSteps = 60
    static let maxColors = 12
    static let minSeconds = 0.25
    static let maxSeconds = 3600.0
    static let maxDuration = 3600.0
    static let defaultDuration = 60.0
    static let maxJitter = 50.0
    /// Lights one mood changes at most, as `set_accessories` refuses more than 25 by default.
    static let maxLights = 25
    /// Failed writes in a row that take a light out of a running mood.
    static let maxFailures = 3
    /// How long a mood that set the lights once can be undone (stop_mood puts the lights back).
    static let undoSeconds: TimeInterval = 12 * 3600

    /// A mood from a request body or the Assistant's reply, checked: every value in range, the steps long enough
    /// for lights that fade.
    static func mood(from value: JSONValue) throws -> Mood {
        guard value.objectValue != nil else { throw CatalogError("A mood is an object with name and steps") }
        let mood: Mood
        do {
            mood = try JSONDecoder().decode(Mood.self, from: Data(value.text().utf8))
        } catch {
            throw CatalogError("Not a mood: name, and steps with colors and seconds, are needed (\(Self.decodingProblem(error)))")
        }
        try check(mood)
        return mood
    }

    static func check(_ mood: Mood) throws {
        let name = mood.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw CatalogError("The mood's name must be 1 to 64 characters") }
        guard (1...maxSteps).contains(mood.steps.count) else { throw CatalogError("A mood has 1 to \(maxSteps) steps") }
        if let duration = mood.durationSeconds, !(1...maxDuration).contains(duration) { throw CatalogError("durationSeconds is 1 to \(Int(maxDuration))") }
        for (index, step) in mood.steps.enumerated() {
            let label = "Step \(index + 1)"
            guard (1...maxColors).contains(step.colors.count) else { throw CatalogError("\(label): 1 to \(maxColors) colors") }
            guard step.seconds.isFinite, (minSeconds...maxSeconds).contains(step.seconds) else {
                throw CatalogError("\(label): seconds is \(minSeconds) to \(Int(maxSeconds)) (lights fade between colours; shorter steps blur)")
            }
            if let jitter = step.jitter, !(0...maxJitter).contains(jitter) { throw CatalogError("\(label): jitter is 0 to \(Int(maxJitter))") }
            for color in step.colors {
                guard color.on != nil || color.brightness != nil || color.hue != nil || color.saturation != nil || color.colorTemperature != nil else {
                    throw CatalogError("\(label): a colour sets at least one of on, brightness, hue, saturation, colorTemperature")
                }
                try range(color.brightness, 0...100, "brightness", label)
                try range(color.hue, 0...360, "hue", label)
                try range(color.saturation, 0...100, "saturation", label)
                try range(color.colorTemperature, 140...500, "colorTemperature", label)
            }
        }
    }

    private static func range(_ value: Double?, _ bounds: ClosedRange<Double>, _ key: String, _ label: String) throws {
        guard let value else { return }
        guard value.isFinite, bounds.contains(value) else { throw CatalogError("\(label): \(key) is \(Int(bounds.lowerBound)) to \(Int(bounds.upperBound))") }
    }

    private static func decodingProblem(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context): "\((context.codingPath + [key]).map(\.stringValue).joined(separator: ".")) is missing"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        default: "\(error)"
        }
    }

    /// The value written for `value`: within the characteristic's range, on its step, in its format.
    static func hapNumber(_ value: Double, for characteristic: Characteristic) -> HAPValue {
        let type = characteristic.type
        var number = value
        if let minimum = type.minValue { number = max(minimum, number) }
        if let maximum = type.maxValue { number = min(maximum, number) }
        if let step = type.minStep, step > 0 { number = ((number - (type.minValue ?? 0)) / step).rounded() * step + (type.minValue ?? 0) }
        switch type.format {
        case .float: return .double(number)
        default: return .int(Int(number.rounded()))
        }
    }

    static func newID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

// MARK: - The collection

/// The moods anyone can pick. Their names and descriptions are translated in the web UI (home.js, by id).
public enum MoodLibrary {
    private static func white(_ mired: Double, _ brightness: Double) -> MoodColor { MoodColor(brightness: brightness, colorTemperature: mired) }
    private static func colour(_ hue: Double, _ saturation: Double, _ brightness: Double) -> MoodColor { MoodColor(brightness: brightness, hue: hue, saturation: saturation) }

    static let red = colour(0, 100, 100)
    static let blue = colour(235, 100, 100)
    static let green = colour(120, 100, 85)

    public static let all: [Mood] = [
        // Calm: set once.
        Mood(id: "candlelight", name: "Candlelight", description: "Very warm, dim light for dinner.", category: "calm",
             steps: [MoodStep([white(454, 30), white(454, 22)], seconds: 1)]),
        Mood(id: "relax", name: "Relax", description: "Soft warm white for the evening.", category: "calm",
             steps: [MoodStep([white(370, 45)], seconds: 1)]),
        Mood(id: "golden-hour", name: "Golden hour", description: "Amber and soft orange, a little different on each light.", category: "calm",
             steps: [MoodStep([colour(38, 80, 62), colour(28, 88, 55), colour(45, 70, 66)], seconds: 1)]),
        Mood(id: "cinema", name: "Cinema", description: "Almost dark, with a touch of blue behind the screen.", category: "calm",
             steps: [MoodStep([white(400, 6), colour(230, 90, 8)], seconds: 1)]),
        Mood(id: "romantic", name: "Romantic", description: "Deep pink and soft red, dimmed.", category: "calm",
             steps: [MoodStep([colour(340, 70, 30), colour(355, 85, 24)], seconds: 1)]),
        Mood(id: "focus", name: "Focus", description: "Bright, cool white for work.", category: "calm",
             steps: [MoodStep([white(200, 100)], seconds: 1)]),
        Mood(id: "night-light", name: "Night light", description: "A faint amber glow to find your way.", category: "calm",
             steps: [MoodStep([colour(25, 100, 3)], seconds: 1)]),

        // Animated: slow, for a long while.
        Mood(id: "candle-flicker", name: "Candle flicker", description: "Warm amber, each light flickering on its own.", category: "animated",
             steps: [MoodStep([white(480, 34), colour(30, 85, 30), white(454, 38)], assign: .random, seconds: 0.8, jitter: 10)],
             loop: true, durationSeconds: 3600),
        Mood(id: "fireplace", name: "Fireplace", description: "Reds, oranges and amber dancing unevenly.", category: "animated",
             steps: [MoodStep([colour(12, 100, 42), colour(24, 95, 55), colour(34, 90, 40), colour(6, 100, 28)], assign: .random, seconds: 1.2, jitter: 12)],
             loop: true, durationSeconds: 3600),
        Mood(id: "ocean", name: "Ocean", description: "Blues and teals rolling from light to light like waves.", category: "animated",
             steps: rotations([colour(190, 80, 60), colour(205, 90, 48), colour(220, 85, 42), colour(178, 70, 55)], seconds: 3),
             loop: true, durationSeconds: 1800),
        Mood(id: "northern-lights", name: "Northern lights", description: "Green, teal and violet drifting slowly.", category: "animated",
             steps: [MoodStep([colour(140, 80, 45), colour(165, 75, 40), colour(280, 60, 35), colour(190, 70, 40)], assign: .random, seconds: 4)],
             loop: true, durationSeconds: 1800),
        Mood(id: "breathing", name: "Breathing", description: "Soft light rising and falling in a six-second rhythm, to calm down.", category: "animated",
             steps: [MoodStep([white(370, 12)], seconds: 3), MoodStep([white(370, 55)], seconds: 3)],
             loop: true, durationSeconds: 900),
        Mood(id: "sunset", name: "Sunset", description: "Ten minutes from golden yellow through orange and pink to a dim red.", category: "animated",
             steps: [MoodStep([colour(45, 80, 80)], seconds: 120), MoodStep([colour(30, 90, 60)], seconds: 120), MoodStep([colour(345, 60, 40)], seconds: 120),
                     MoodStep([colour(5, 100, 15)], seconds: 120), MoodStep([colour(5, 100, 5)], seconds: 120)],
             restore: false),
        Mood(id: "sunrise", name: "Sunrise", description: "Fifteen minutes from a dim red glow to bright warm white, to wake up.", category: "animated",
             steps: [MoodStep([colour(5, 100, 2)], seconds: 180), MoodStep([colour(22, 95, 15)], seconds: 240), MoodStep([white(454, 40)], seconds: 240),
                     MoodStep([white(300, 80)], seconds: 240), MoodStep([white(250, 100)], seconds: 1)],
             restore: false),

        // Party: fast.
        Mood(id: "disco", name: "Disco", description: "Every light jumps to a vivid colour on each beat.", category: "party",
             steps: [MoodStep([0, 30, 55, 120, 180, 220, 265, 300, 330].map { colour($0, 100, 100) } + [colour(280, 100, 40), colour(160, 100, 40)], assign: .random, seconds: 0.5)],
             loop: true, durationSeconds: 120),
        Mood(id: "police", name: "Police siren", description: "Red and blue swapping from light to light.", category: "party",
             steps: [MoodStep([red, blue], seconds: 0.5), MoodStep([blue, red], seconds: 0.5)],
             loop: true, durationSeconds: 30),
        Mood(id: "rainbow-wave", name: "Rainbow wave", description: "The colour wheel passing from light to light.", category: "party",
             steps: (0..<18).map { turn in MoodStep((0..<6).map { colour(Double((turn * 20 + $0 * 60) % 360), 100, 100) }, seconds: 0.6) },
             loop: true, durationSeconds: 120),
        Mood(id: "lightning", name: "Lightning storm", description: "Dim stormy blue, with sudden white flashes.", category: "party",
             steps: [MoodStep(Array(repeating: colour(225, 60, 10), count: 9) + [white(153, 100)], assign: .random, seconds: 0.6)],
             loop: true, durationSeconds: 300),
        Mood(id: "halloween", name: "Halloween", description: "Purple and orange with an eerie flicker.", category: "party",
             steps: [MoodStep([colour(275, 100, 50), colour(30, 100, 60), colour(275, 100, 20), colour(120, 100, 15)], assign: .random, seconds: 1.5, jitter: 15)],
             loop: true, durationSeconds: 1800),
        Mood(id: "christmas", name: "Christmas", description: "Red and green taking turns, with a warm white twinkle now and then.", category: "party",
             steps: [MoodStep([red, green], seconds: 3), MoodStep([red, green, red, green, white(370, 100)], assign: .random, seconds: 0.6),
                     MoodStep([green, red], seconds: 3), MoodStep([green, red, green, red, white(370, 100)], assign: .random, seconds: 0.6)],
             loop: true, durationSeconds: 1800),

        // Signals: short, then back to how things were.
        Mood(id: "alert", name: "Alert flash", description: "Two red pulses, then the lights go back to how they were.", category: "signal",
             steps: [MoodStep([red], seconds: 0.7), MoodStep([colour(0, 100, 10)], seconds: 0.7), MoodStep([red], seconds: 0.7), MoodStep([colour(0, 100, 10)], seconds: 0.7)],
             restore: true),
        Mood(id: "bedtime", name: "Bedtime", description: "A slow fade to a dim red over fifteen minutes.", category: "signal",
             steps: [MoodStep([white(454, 45)], seconds: 300), MoodStep([colour(20, 90, 20)], seconds: 300), MoodStep([colour(5, 100, 6)], seconds: 300),
                     MoodStep([colour(5, 100, 2)], seconds: 1)],
             restore: false),
    ]

    /// The same palette moved one light along at each step: a wave.
    private static func rotations(_ palette: [MoodColor], seconds: Double) -> [MoodStep] {
        (0..<palette.count).map { shift in MoodStep((0..<palette.count).map { palette[($0 + shift) % palette.count] }, seconds: seconds) }
    }

    /// Up to five CSS colours a mood shows, in order: what a page draws it with.
    public static func swatch(_ mood: Mood) -> [String] {
        var colours: [String] = []
        for color in mood.steps.prefix(8).flatMap(\.colors) where !color.isOff {
            let css: String
            if let hue = color.hue {
                css = "hsl(\(Int(hue)) \(Int(color.saturation ?? 100))% \(Int(28 + (color.brightness ?? 100) * 0.27))%)"
            } else if let mired = color.colorTemperature {
                let white = ColorUtils.colorTemperatureToHueAndSaturation(mired)
                css = "hsl(\(Int(white.hue)) \(Int(min(70, white.saturation * 1.8)))% \(Int(50 + (color.brightness ?? 100) * 0.35))%)"
            } else {
                css = "hsl(40 40% 70%)"
            }
            if !colours.contains(css) { colours.append(css) }
            if colours.count == 5 { break }
        }
        return colours
    }

    /// By id, or by name case aside.
    public static func find(_ reference: String) -> Mood? {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == wanted } ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

// MARK: - Lights and runs

/// A lightbulb service a mood can change: On, and whichever of Brightness, Hue, Saturation and Color Temperature it has.
struct MoodLight: Sendable {
    let located: HomeswiftCatalog.Located
    let service: Service
    /// The accessory id and the service's position among its lightbulbs.
    let key: String
    let on: Characteristic
    let brightness: Characteristic?
    let hue: Characteristic?
    let saturation: Characteristic?
    let colorTemperature: Characteristic?

    var name: String {
        let accessory = located.layout?.name ?? located.accessory.name
        guard let own = service[.name]?.value.stringValue, !own.isEmpty, own != located.accessory.name else { return accessory }
        return "\(accessory) – \(own)"
    }

    var hasColour: Bool { hue != nil && saturation != nil }

    func snapshot() -> MoodSnapshot {
        MoodSnapshot(on: on.value, brightness: brightness?.value, hue: hue?.value, saturation: saturation?.value, colorTemperature: colorTemperature?.value,
                     adaptive: service.adaptiveLighting?.isAdaptiveLightingActive == true)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(located.accessory.id), "name": .string(name)]
        object["color"] = .bool(hasColour)
        if colorTemperature != nil { object["colorTemperature"] = true }
        return .object(object)
    }
}

/// A light's values before a mood changed it, to put back.
struct MoodSnapshot: Sendable {
    var on: HAPValue
    var brightness: HAPValue?
    var hue: HAPValue?
    var saturation: HAPValue?
    var colorTemperature: HAPValue?
    /// Adaptive Lighting ran: it resumes afterwards.
    var adaptive: Bool
}

/// A mood playing in the background, or one that set the lights and can still be undone (`isHeld`).
final class MoodRun: Sendable {
    let id: String
    let mood: Mood
    let lights: [MoodLight]
    let startedAt: Date
    let endsAt: Date?
    let by: String
    /// The room it was started for, when it was.
    let room: String?
    let task = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// The lights it puts back when it ends, with their values; a mood that takes a light over takes its snapshot.
    let snapshots: NIOLockedValueBox<[String: MoodSnapshot]>

    init(id: String, mood: Mood, lights: [MoodLight], startedAt: Date, endsAt: Date?, by: String, room: String?, snapshots: [String: MoodSnapshot]) {
        self.id = id
        self.mood = mood
        self.lights = lights
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.by = by
        self.room = room
        self.snapshots = NIOLockedValueBox(snapshots)
    }

    /// It set the lights once; stopping it undoes that.
    var isHeld: Bool { !mood.isAnimated }

    var json: JSONValue {
        // A held mood lists the lights it would still put back (another mood may have taken some).
        let kept = snapshots.withLockedValue { Set($0.keys) }
        var object: [String: JSONValue] = [
            "id": .string(id), "name": .string(mood.name), "startedAt": .string(Timestamp.iso8601(startedAt)), "by": .string(by),
            "lights": .array(lights.filter { !isHeld || kept.contains($0.key) }.map(\.json)), "swatch": .array(MoodLibrary.swatch(mood).map(JSONValue.string)),
        ]
        if isHeld {
            object["held"] = true
            object["undoUntil"] = .string(Timestamp.iso8601(startedAt.addingTimeInterval(MoodRules.undoSeconds)))
        }
        if let moodID = mood.id { object["mood"] = .string(moodID) }
        if let room { object["room"] = .string(room) }
        if let endsAt { object["endsAt"] = .string(Timestamp.iso8601(endsAt)) }
        return .object(object)
    }
}

extension HomeswiftCatalog {
    // MARK: Picking the lights

    /// The lightbulbs of these accessories (`ids`) or of those `filter` picks (a room…), at most `MoodRules.maxLights`.
    func moodLights(ids: [String]?, filter: AccessoryFilter?) throws -> [MoodLight] {
        var accessories: [Located]
        if let ids, !ids.isEmpty {
            accessories = []
            var seen: Set<String> = []
            for id in ids where seen.insert(id).inserted {
                guard let found = find(id: id) else { throw CatalogError("No accessory with id \(id)") }
                accessories.append(found)
            }
        } else if let filter, !filter.isEmpty {
            if let error = unknownRoom(filter) { throw CatalogError(error) }
            accessories = located(matching: filter)
        } else {
            throw CatalogError("Name the lights: a room, ids or a filter")
        }
        let lights = accessories.flatMap { located in
            located.accessory.services.filter { $0.type.uuid == ServiceType.lightbulb.uuid }.enumerated().compactMap { index, service -> MoodLight? in
                guard let on = service[.on], !on.isSecurityControl, on.type.permissions.contains(.pairedWrite) else { return nil }
                func writable(_ type: CharacteristicType) -> Characteristic? {
                    service[type].flatMap { $0.type.permissions.contains(.pairedWrite) && !$0.isSecurityControl ? $0 : nil }
                }
                return MoodLight(located: located, service: service, key: "\(located.accessory.id)#\(index)", on: on, brightness: writable(.brightness),
                                 hue: writable(.hue), saturation: writable(.saturation), colorTemperature: writable(.colorTemperature))
            }
        }
        guard !lights.isEmpty else { throw CatalogError("No light there: moods change lightbulbs only") }
        guard lights.count <= MoodRules.maxLights else { throw CatalogError("That is \(lights.count) lights; a mood changes at most \(MoodRules.maxLights). Pick a room or fewer lights.") }
        return lights
    }

    // MARK: Starting and stopping

    /// start_mood and the web UI: `mood` (from the collection), `plan` (a mood written by the caller) or `description`
    /// (the Assistant writes it), on the lights of `room`, `ids` or `filter`. `durationSeconds` overrides how long a
    /// looping mood plays. A dry run says what would play where.
    public func startMood(_ arguments: JSONValue, by: String, language: String? = nil, dryRun: Bool = false) async throws -> JSONValue {
        let sources = ["mood", "plan", "description"].filter { arguments[$0] != nil && arguments[$0]?.isNull != true }
        guard sources.count == 1 else { throw CatalogError("Pass one of mood (from list_moods), plan or description") }
        var filter = AccessoryFilter(arguments["filter"])
        if let room = arguments["room"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty { filter.room = room }
        let lights = try moodLights(ids: arguments["ids"]?.arrayValue?.compactMap(\.stringValue), filter: filter)
        var mood: Mood
        var designed = false
        switch sources[0] {
        case "mood":
            let reference = arguments["mood"]?.stringValue ?? ""
            guard let found = MoodLibrary.find(reference) else {
                throw CatalogError("No mood \"\(reference)\". Moods: \(MoodLibrary.all.compactMap(\.id).joined(separator: ", ")).")
            }
            mood = found
        case "plan":
            mood = try MoodRules.mood(from: arguments["plan"] ?? .null)
            mood.id = nil
        default:
            let description = arguments["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !description.isEmpty, description.count <= 500 else { throw CatalogError("The description must be 1 to 500 characters") }
            mood = try await designMood(description, lights: lights, language: language)
            designed = true
        }
        if let duration = arguments["durationSeconds"]?.doubleValue {
            guard (1...MoodRules.maxDuration).contains(duration) else { throw CatalogError("durationSeconds is 1 to \(Int(MoodRules.maxDuration))") }
            mood.durationSeconds = duration
        }
        var answer: [String: JSONValue] = ["mood": (try? JSONValue(encoding: mood)) ?? .null, "lights": .array(lights.map(\.json))]
        if designed { answer["designed"] = true }
        if dryRun {
            answer["dryRun"] = true
            return .object(answer)
        }
        guard mood.isAnimated else {
            // Moods playing there stop without putting these lights back; what the lights were before (before the
            // mood it replaces, if any) is kept, so stop_mood can undo this one.
            let inherited = await takeOver(lights)
            var snapshots: [String: MoodSnapshot] = [:]
            for light in lights { snapshots[light.key] = inherited[light.key] ?? light.snapshot() }
            let failures = await applyOnce(mood.steps[0], to: lights)
            let run = hold(mood, on: lights, snapshots: snapshots, by: by, room: filter.room)
            logger.info("Mood \"\(mood.name)\" set on \(lights.count) light(s)", metadata: ["by": "\(by)", "run": "\(run.id)"])
            answer["run"] = run.json
            answer["failed"] = .array(failures.map { ["name": .string($0.key), "error": .string($0.value)] })
            answer["ok"] = .bool(failures.isEmpty)
            return .object(answer)
        }
        let run = await play(mood, on: lights, by: by, room: filter.room)
        answer["run"] = run.json
        answer["ok"] = true
        return .object(answer)
    }

    /// Stops the running mood `id`, or every one, and undoes those that set the lights once: each puts its lights back.
    public func stopMoods(id: String? = nil) async throws -> JSONValue {
        let runs = home.runningMoods.withLockedValue { running -> [MoodRun] in
            if let id { return running[id].map { [$0] } ?? [] }
            return Array(running.values)
        }
        if let id, runs.isEmpty { throw CatalogError("No mood \(id) is playing") }
        for run in runs {
            let task = run.task.withLockedValue { $0 }
            task?.cancel()
            await task?.value
        }
        return ["stopped": .array(runs.map(\.json))]
    }

    /// The collection (each mood with a few CSS colours to draw it), what plays now, and whether the Assistant can
    /// write one from a description.
    public func moodsJSON() -> JSONValue {
        let running = home.runningMoods.withLockedValue { Array($0.values) }.sorted { $0.startedAt < $1.startedAt }
        return [
            "moods": .array(MoodLibrary.all.map { mood in
                var object: [String: JSONValue] = [
                    "id": .string(mood.id ?? ""), "name": .string(mood.name), "animated": .bool(mood.isAnimated),
                    "swatch": .array(MoodLibrary.swatch(mood).map(JSONValue.string)),
                ]
                if let description = mood.description { object["description"] = .string(description) }
                if let category = mood.category { object["category"] = .string(category) }
                return .object(object)
            }),
            "running": .array(running.map(\.json)),
            "assistant": .bool(host.assistant != nil),
        ]
    }

    /// A scene that sets these lights as the mood's first step does: for a mood that does not move.
    public func saveMoodAsScene(_ arguments: JSONValue) throws -> JSONValue {
        let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mood: Mood
        if let reference = arguments["mood"]?.stringValue {
            guard let found = MoodLibrary.find(reference) else { throw CatalogError("No mood \"\(reference)\"") }
            mood = found
        } else {
            mood = try MoodRules.mood(from: arguments["plan"] ?? .null)
        }
        guard !mood.isAnimated else { throw CatalogError("\(mood.name) moves: only a mood that sets the lights once can be a scene") }
        var filter = AccessoryFilter(arguments["filter"])
        if let room = arguments["room"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty { filter.room = room }
        let lights = try moodLights(ids: arguments["ids"]?.arrayValue?.compactMap(\.stringValue), filter: filter)
        var actions: [JSONValue] = []
        for (index, light) in lights.enumerated() {
            let step = mood.steps[0]
            let color = step.colors[index % step.colors.count]
            let lightbulbs = light.located.accessory.services.filter { $0.type.uuid == ServiceType.lightbulb.uuid }.count
            let service: JSONValue = lightbulbs > 1 ? .string(light.service.subtype ?? light.service[.name]?.value.stringValue ?? light.service.type.name) : .null
            func action(_ characteristic: Characteristic, _ value: JSONValue) {
                var object: [String: JSONValue] = ["id": .string(light.located.accessory.id), "characteristic": .string(characteristic.type.name), "value": value]
                if !service.isNull { object["service"] = service }
                actions.append(.object(object))
            }
            if color.isOff {
                action(light.on, false)
                continue
            }
            for (characteristic, value) in paintValues(light, color, jitter: 0) { action(characteristic, Self.json(value)) }
            action(light.on, true)
        }
        return try createScene(["name": .string(name.isEmpty ? mood.name : name), "actions": .array(actions)])
    }

    // MARK: Playing

    /// Starts an animated mood in the background; lights another mood was playing on change hands without a flash
    /// back to their old values.
    private func play(_ mood: Mood, on lights: [MoodLight], by: String, room: String?) async -> MoodRun {
        let inherited = await takeOver(lights)
        var snapshots: [String: MoodSnapshot] = [:]
        for light in lights { snapshots[light.key] = inherited[light.key] ?? light.snapshot() }
        let now = Date()
        let total = mood.loop == true ? (mood.durationSeconds ?? MoodRules.defaultDuration) : mood.steps.reduce(0) { $0 + $1.seconds }
        let run = MoodRun(id: MoodRules.newID(), mood: mood, lights: lights, startedAt: now, endsAt: now.addingTimeInterval(total), by: by, room: room, snapshots: snapshots)
        let catalog = self
        // Registered with its task before anything else can stop it.
        home.runningMoods.withLockedValue { running in
            running[run.id] = run
            run.task.withLockedValue { $0 = Task { await catalog.perform(run) } }
        }
        logger.info("Mood \"\(mood.name)\" playing on \(lights.count) light(s) for \(Int(total)) s", metadata: ["by": "\(by)", "run": "\(run.id)"])
        return run
    }

    /// Stops the moods playing on any of these lights; their snapshots of those lights come back, to restore when
    /// the new mood ends or is undone. A held mood only gives up those lights: its others stay as it set them, still
    /// to undo; it ends when it has none left.
    private func takeOver(_ lights: [MoodLight]) async -> [String: MoodSnapshot] {
        let keys = Set(lights.map(\.key))
        let runs = home.runningMoods.withLockedValue { running in running.values.filter { !keys.isDisjoint(with: $0.lights.map(\.key)) } }
        var inherited: [String: MoodSnapshot] = [:]
        for run in runs {
            let left = run.snapshots.withLockedValue { snapshots -> Int in
                for key in keys { if let snapshot = snapshots.removeValue(forKey: key) { inherited[key] = snapshot } }
                return snapshots.count
            }
            if run.isHeld, left > 0 { continue }
            let task = run.task.withLockedValue { $0 }
            task?.cancel()
            await task?.value
        }
        return inherited
    }

    /// Keeps a mood that set the lights once, for `MoodRules.undoSeconds`: stopping it in that time puts the lights
    /// back; after it, the chance to undo ends and the lights stay.
    private func hold(_ mood: Mood, on lights: [MoodLight], snapshots: [String: MoodSnapshot], by: String, room: String?) -> MoodRun {
        let run = MoodRun(id: MoodRules.newID(), mood: mood, lights: lights, startedAt: Date(), endsAt: nil, by: by, room: room, snapshots: snapshots)
        let catalog = self
        home.runningMoods.withLockedValue { running in
            running[run.id] = run
            run.task.withLockedValue { task in
                task = Task {
                    let undone = (try? await Task.sleep(for: .seconds(MoodRules.undoSeconds))) == nil
                    if undone { await catalog.restoreAll(run) }
                    catalog.home.runningMoods.withLockedValue { running in
                        if running[run.id] === run { running[run.id] = nil }
                    }
                }
            }
        }
        return run
    }

    /// Puts back every light a run still holds a snapshot of, all at the same time.
    private func restoreAll(_ run: MoodRun) async {
        let snapshots = run.snapshots.withLockedValue { $0 }
        await withTaskGroup(of: Void.self) { group in
            for light in run.lights {
                guard let snapshot = snapshots[light.key] else { continue }
                group.addTask { await self.restore(light, snapshot) }
            }
        }
    }

    private func perform(_ run: MoodRun) async {
        let mood = run.mood
        var active = run.lights
        var failures: [String: Int] = [:]
        var lastOn: [String: Bool] = [:]
        let deadline = mood.loop == true ? run.endsAt : nil
        outer: repeat {
            for (index, step) in mood.steps.enumerated() {
                if Task.isCancelled { break outer }
                let stepStart = Date()
                let lightsByKey = Dictionary(active.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                for (key, outcome) in await paintAll(step, on: active, lastOn: lastOn) {
                    switch outcome {
                    case .success(let on):
                        lastOn[key] = on
                        failures[key] = 0
                    case .failure(let error):
                        failures[key, default: 0] += 1
                        if failures[key, default: 0] >= MoodRules.maxFailures, let light = lightsByKey[key] {
                            logger.warning("Mood \"\(mood.name)\": \(light.name) left the show after \(MoodRules.maxFailures) failed writes: \(error)")
                        }
                    }
                }
                active.removeAll { failures[$0.key, default: 0] >= MoodRules.maxFailures }
                if active.isEmpty { break outer }
                let last = mood.loop != true && index == mood.steps.count - 1
                if last, !mood.restoresAtEnd { break outer }
                // The step lasts its seconds from when it began: the writes are part of it.
                var wait = step.seconds - Date().timeIntervalSince(stepStart)
                if let deadline { wait = min(wait, deadline.timeIntervalSinceNow) }
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { break outer }
                }
                if let deadline, Date() >= deadline { break outer }
            }
        } while mood.loop == true && !Task.isCancelled
        if mood.restoresAtEnd || Task.isCancelled { await restoreAll(run) }
        home.runningMoods.withLockedValue { running in
            if running[run.id] === run { running[run.id] = nil }
        }
        logger.info("Mood \"\(mood.name)\" ended", metadata: ["run": "\(run.id)"])
    }

    /// Sets the lights once (a mood that does not move); the failures by light.
    private func applyOnce(_ step: MoodStep, to lights: [MoodLight]) async -> [String: String] {
        var failures: [String: String] = [:]
        let names = Dictionary(lights.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        for (key, outcome) in await paintAll(step, on: lights, lastOn: [:]) {
            if case .failure(let error) = outcome { failures[names[key] ?? key] = "\(error)" }
        }
        return failures
    }

    /// Paints a step on every light at the same time, so a fast step flashes the room at once rather than light by
    /// light. By light: the On it now has (`lastOn` after), or why it failed.
    private func paintAll(_ step: MoodStep, on lights: [MoodLight], lastOn: [String: Bool]) async -> [String: Result<Bool?, any Error>] {
        // What each light is to be given: its colour writes, or its Off when it is to go off (only when it was on).
        let plans = lights.enumerated().map { position, light -> PaintPlan in
            let color = Self.pick(step, for: position)
            let wasOn = lastOn[light.key]
            let writes: [(Characteristic, HAPValue)]
            if color.isOff {
                writes = wasOn != false ? [(light.on, .bool(false))] : []
            } else {
                writes = paintValues(light, color, jitter: step.jitter ?? 0)
            }
            return PaintPlan(light: light, color: color, wasOn: wasOn, writes: writes)
        }
        // First every colour write of every light, in one group, so a fast step flashes the room at once.
        var failures: [String: any Error] = [:]
        await withTaskGroup(of: (String, (any Error)?).self) { group in
            for plan in plans {
                for (characteristic, value) in plan.writes {
                    group.addTask {
                        do {
                            try await self.write(plan.light, characteristic, value)
                            return (plan.light.key, nil)
                        } catch {
                            return (plan.light.key, error)
                        }
                    }
                }
            }
            for await (key, error) in group where failures[key] == nil {
                if let error { failures[key] = error }
            }
        }
        // Then On, for the lights that are to be on, were not on, and had no failed write; one group again.
        let turningOn = plans.filter { plan in
            !plan.color.isOff && failures[plan.light.key] == nil && plan.wasOn != true && plan.light.on.value.boolValue != true
        }
        await withTaskGroup(of: (String, (any Error)?).self) { group in
            for plan in turningOn {
                group.addTask {
                    do {
                        try await self.write(plan.light, plan.light.on, .bool(true))
                        return (plan.light.key, nil)
                    } catch {
                        return (plan.light.key, error)
                    }
                }
            }
            for await (key, error) in group where failures[key] == nil {
                if let error { failures[key] = error }
            }
        }
        var outcomes: [String: Result<Bool?, any Error>] = [:]
        for plan in plans {
            if let error = failures[plan.light.key] {
                outcomes[plan.light.key] = .failure(error)
            } else {
                outcomes[plan.light.key] = .success(plan.color.isOff ? false : true)
            }
        }
        return outcomes
    }

    /// One light's part of a step: the writes that paint it, and whether it is to be on.
    private struct PaintPlan {
        let light: MoodLight
        let color: MoodColor
        let wasOn: Bool?
        let writes: [(Characteristic, HAPValue)]
    }

    static func pick(_ step: MoodStep, for position: Int) -> MoodColor {
        step.assign == .random ? step.colors.randomElement()! : step.colors[position % step.colors.count]
    }

    /// The values a colour gives a light: brightness, then the colour (saturation and hue, or a white as colour
    /// temperature, or that white as saturation and hue on a light with no colour temperature). They are written at
    /// the same time, as the Home app writes them, so their order does not matter.
    func paintValues(_ light: MoodLight, _ color: MoodColor, jitter: Double) -> [(Characteristic, HAPValue)] {
        var values: [(Characteristic, HAPValue)] = []
        if let brightness = light.brightness, let level = color.brightness {
            let shaken = jitter > 0 ? level + Double.random(in: -jitter...jitter) : level
            values.append((brightness, MoodRules.hapNumber(max(1, min(100, shaken)), for: brightness)))
        }
        if let hue = light.hue, let saturation = light.saturation, color.hue != nil || color.saturation != nil {
            if let value = color.saturation { values.append((saturation, MoodRules.hapNumber(value, for: saturation))) }
            if let value = color.hue { values.append((hue, MoodRules.hapNumber(value, for: hue))) }
        } else if let mired = color.colorTemperature {
            if let temperature = light.colorTemperature {
                values.append((temperature, MoodRules.hapNumber(mired, for: temperature)))
            } else if let hue = light.hue, let saturation = light.saturation {
                let converted = ColorUtils.colorTemperatureToHueAndSaturation(mired)
                values.append((saturation, MoodRules.hapNumber(converted.saturation, for: saturation)))
                values.append((hue, MoodRules.hapNumber(converted.hue, for: hue)))
            }
        }
        return values
    }

    /// Writes a colour to a light, turning it on last so it lights up in the new colour. Its values go at the same
    /// time, as the Home app sends them, so a plugin that gathers a moment's changes sends them as one command.
    /// `lastOn` is what this mood last set, so On is written only when it changes; answers what it is now.
    private func write(_ light: MoodLight, _ characteristic: Characteristic, _ value: HAPValue) async throws {
        do {
            try await characteristic.write(value)
        } catch let error as HAPStatusError {
            throw Self.failure(error, of: light.located)
        }
    }

    /// Puts a light back: every value it had, brightness and colour, then On. A light with both kinds of colour shows
    /// the one written last, so that is the one it showed: colour temperature when the hue and saturation were only
    /// that white's, else the hue and saturation. Adaptive Lighting resumes when it ran.
    private func restore(_ light: MoodLight, _ snapshot: MoodSnapshot) async {
        var values: [(Characteristic, HAPValue)] = []
        if let brightness = light.brightness, let value = snapshot.brightness { values.append((brightness, value)) }
        let hueAndSaturation: [(Characteristic, HAPValue)] = [(light.hue, snapshot.hue), (light.saturation, snapshot.saturation)].compactMap { pair in
            guard let characteristic = pair.0, let value = pair.1 else { return nil }
            return (characteristic, value)
        }
        if let temperature = light.colorTemperature, let mired = snapshot.colorTemperature {
            if let hue = snapshot.hue?.doubleValue, let saturation = snapshot.saturation?.doubleValue, let value = mired.doubleValue {
                let white = ColorUtils.colorTemperatureToHueAndSaturation(value)
                let wasWhite = abs(white.hue - hue) <= 3 && abs(white.saturation - saturation) <= 3
                values += wasWhite ? hueAndSaturation + [(temperature, mired)] : [(temperature, mired)] + hueAndSaturation
            } else {
                values.append((temperature, mired))
            }
        } else {
            values += hueAndSaturation
        }
        values.append((light.on, snapshot.on))
        for (characteristic, value) in values where characteristic.value != value {
            do { try await characteristic.write(value) } catch { logger.debug("Mood: could not restore \(characteristic.type.name) of \(light.name): \(error)") }
        }
        if snapshot.adaptive, let controller = light.service.adaptiveLighting, !controller.isAdaptiveLightingActive {
            _ = controller.resumeAdaptiveLighting()
        }
    }

    // MARK: The Assistant

    /// A mood the Assistant writes from a description, for these lights (how many, which take colours or whites;
    /// never their names).
    func designMood(_ description: String, lights: [MoodLight], language: String?) async throws -> Mood {
        guard let assistant = host.assistant?.speaking(language) else { throw CatalogError("the Assistant is off: add a HomeswiftAiKit block, or pick a mood from the list") }
        let summary: JSONValue = [
            "lights": .number(Double(lights.count)),
            "colour": .number(Double(lights.filter(\.hasColour).count)),
            "whiteOnly": .number(Double(lights.filter { !$0.hasColour && $0.colorTemperature != nil }.count)),
            "dimmableOnly": .number(Double(lights.filter { !$0.hasColour && $0.colorTemperature == nil && $0.brightness != nil }.count)),
        ]
        let reply: JSONGenerationResult
        do {
            reply = try await assistant.designMood(description, lights: summary)
        } catch let error as JSONGenerationError {
            throw CatalogError("The Assistant could not write a mood: \(error.message)")
        }
        var mood = try MoodRules.mood(from: reply.data)
        mood.id = nil
        mood.category = nil
        return mood
    }

    // MARK: Tools

    var moodTools: [MCPTool] {
        let catalog = self
        let targets: [String: JSONValue] = [
            "room": ["type": "string", "description": "The lights of this room (the web UI's rooms, get_accessory_layout)"],
            "ids": ["type": "array", "minItems": 1, "maxItems": 50, "items": ["type": "string"], "description": "These accessories' lights, from list_accessories"],
            "filter": ["type": "object", "properties": .object(Self.filterProperties), "additionalProperties": false, "description": "Pick the accessories like list_accessories"],
        ]
        return [
            MCPTool(
                name: "list_moods", title: "List moods",
                description: "The collection of moods for the lights (calm ambiances set once, slow animations such as candle flicker or fireplace, party effects such as disco "
                    + "or a police siren, signals such as an alert flash), the moods playing now, and those that set the lights and can still be undone (held: true).",
                outputSchema: Output.object(["moods": ["type": "array"], "running": ["type": "array"]], required: ["moods", "running"]),
                scope: .read, idempotent: true
            ) { _ in .json(catalog.moodsJSON()) },
            MCPTool(
                name: "start_mood", title: "Play a mood on the lights",
                description: "Sets the lights of a room (or of ids or a filter) to a mood: one from list_moods (mood), one described in words that the bridge's Assistant writes "
                    + "(description, e.g. \"a jazz bar\"), or your own plan. A plan is {name, steps: [{colors: [{on, brightness 0-100, hue 0-360, saturation 0-100, "
                    + "colorTemperature 140-500 mired}], assign: spread|random, seconds >= 0.25, jitter 0-50}], loop, durationSeconds, restore}: light n takes colour n of a "
                    + "step (spread) or a random one; lights may fade, so flashes use 0.25 to 0.5 s steps, fast effects up to 1 s. "
                    + "A mood with one step that does not loop sets the lights, and "
                    + "stop_mood undoes it for 12 hours; others play in the background (stop_mood) and put the lights back at the end when they loop or restore is true. "
                    + "Only lightbulbs change. dryRun shows the plan.",
                inputSchema: [
                    "type": "object",
                    "properties": .object(targets.merging([
                        "mood": ["type": "string", "description": "A mood id or name from list_moods"],
                        "description": ["type": "string", "minLength": 1, "maxLength": 500, "description": "The mood in words, for the bridge's Assistant to write"],
                        "plan": ["type": "object", "description": "A mood of your own: name, steps, loop, durationSeconds, restore"],
                        "durationSeconds": ["type": "number", "minimum": 1, "maximum": 3600, "description": "How long a looping mood plays (its own default otherwise)"],
                    ]) { a, _ in a }),
                ],
                scope: .control, supportsDryRun: true
            ) { call in
                .json(try await catalog.startMood(call.arguments, by: "MCP \(call.session.principal.name)", dryRun: call.isDryRun))
            },
            MCPTool(
                name: "stop_mood", title: "Stop a mood",
                description: "Stops a mood playing (run, from list_moods or start_mood), or every one, and undoes a mood that set the lights (held: true, for 12 hours): "
                    + "the lights go back to how they were before it.",
                inputSchema: ["type": "object", "properties": ["run": ["type": "string", "description": "The run id; every mood when left out"]]],
                scope: .control, idempotent: true
            ) { call in
                .json(try await catalog.stopMoods(id: call.optionalString("run")))
            },
        ]
    }
}
