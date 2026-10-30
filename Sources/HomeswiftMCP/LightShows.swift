import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

// Light shows: what scenes play on lights (docs/scenes-design.md). A show is a list of steps, each a palette of
// colours spread over the lights or picked at random for each; it plays once or loops for a while (an animated
// scene's sequence, or Homeswift's version of an effect on lights no plugin animates), and puts every light back as
// it was when it is stopped. A held show is no show at all: it keeps what lights were before a scene, a plan or a
// hub's scene changed them, so `stop_scene` can put them back for 12 hours. `SceneTemplateLibrary` is the templates
// (ambiances, effects, sequences and the gallery's palettes); the Assistant writes a scene from a description as a
// show (`AssistantService.designScene`).
//
// Only lightbulbs are touched, never a security control. Every light of a step is written at the same time; many
// lights fade from one colour to the next, so a step lasts at least a quarter of a second; a light that fails three
// writes in a row leaves the show (a lamp switched off at the wall).

/// What one light is set to. Brightness 0 or `on: false` turns it off.
public struct LightColor: Codable, Sendable, Equatable {
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

public struct LightStep: Codable, Sendable, Equatable {
    /// `spread`: light n takes colour n (round the palette); `random`: each light picks one.
    public enum Assign: String, Codable, Sendable { case spread, random }

    public var colors: [LightColor]
    public var assign: Assign?
    /// How long the step holds before the next.
    public var seconds: Double
    /// Each light's brightness varies by up to this much either way (a candle's flicker).
    public var jitter: Double?

    public init(_ colors: [LightColor], assign: Assign? = nil, seconds: Double, jitter: Double? = nil) {
        self.colors = colors
        self.assign = assign
        self.seconds = seconds
        self.jitter = jitter
    }
}

public struct LightShow: Codable, Sendable, Equatable {
    /// The collection's id; nil for one the Assistant or a client wrote.
    public var id: String?
    public var name: String
    public var description: String?
    /// The collection's sections: calm, animated, party, signal.
    public var category: String?
    public var steps: [LightStep]
    /// Plays the steps again and again until `durationSeconds` is up or it is stopped.
    public var loop: Bool?
    public var durationSeconds: Double?
    /// Puts the lights back as they were at the end: by default when it loops.
    public var restore: Bool?

    public init(id: String? = nil, name: String, description: String? = nil, category: String? = nil, steps: [LightStep], loop: Bool? = nil, durationSeconds: Double? = nil, restore: Bool? = nil) {
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

enum LightShowRules {
    static let maxSteps = 60
    static let maxColors = 12
    static let minSeconds = 0.25
    static let maxSeconds = 3600.0
    static let maxDuration = 3600.0
    static let defaultDuration = 60.0
    static let maxJitter = 50.0
    /// Lights one show changes at most, as `set_accessories` refuses more than 25 by default.
    static let maxLights = 25
    /// Failed writes in a row that take a light out of a running show.
    static let maxFailures = 3
    /// How long a show that set the lights once can be undone (stop_scene puts the lights back).
    static let undoSeconds: TimeInterval = 12 * 3600
    /// How long a plugin action's light changes may take to arrive and settle before what changed is held for undo.
    static let pluginSettle = Duration.seconds(4)

    /// A show from a request body or the Assistant's reply, checked: every value in range, the steps long enough
    /// for lights that fade.
    static func show(from value: JSONValue) throws -> LightShow {
        guard value.objectValue != nil else { throw CatalogError("A show is an object with name and steps") }
        let show: LightShow
        do {
            show = try JSONDecoder().decode(LightShow.self, from: Data(value.text().utf8))
        } catch {
            throw CatalogError("Not a show: name, and steps with colors and seconds, are needed (\(Self.decodingProblem(error)))")
        }
        try check(show)
        return show
    }

    static func check(_ show: LightShow) throws {
        let name = show.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw CatalogError("The show's name must be 1 to 64 characters") }
        guard (1...maxSteps).contains(show.steps.count) else { throw CatalogError("A show has 1 to \(maxSteps) steps") }
        if let duration = show.durationSeconds, !(1...maxDuration).contains(duration) { throw CatalogError("durationSeconds is 1 to \(Int(maxDuration))") }
        for (index, step) in show.steps.enumerated() {
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

/// The shows anyone can pick. Their names and descriptions are translated in the web UI (home.js, by id).
public enum SceneTemplateLibrary {
    private static func white(_ mired: Double, _ brightness: Double) -> LightColor { LightColor(brightness: brightness, colorTemperature: mired) }
    private static func colour(_ hue: Double, _ saturation: Double, _ brightness: Double) -> LightColor { LightColor(brightness: brightness, hue: hue, saturation: saturation) }

    static let red = colour(0, 100, 100)
    static let blue = colour(235, 100, 100)
    static let green = colour(120, 100, 85)

    public static let all: [LightShow] = [
        // Calm: set once.
        LightShow(id: "candlelight", name: "Candlelight", description: "Very warm, dim light for dinner.", category: "calm",
             steps: [LightStep([white(454, 30), white(454, 22)], seconds: 1)]),
        LightShow(id: "relax", name: "Relax", description: "Soft warm white for the evening.", category: "calm",
             steps: [LightStep([white(370, 45)], seconds: 1)]),
        LightShow(id: "golden-hour", name: "Golden hour", description: "Amber and soft orange, a little different on each light.", category: "calm",
             steps: [LightStep([colour(38, 80, 62), colour(28, 88, 55), colour(45, 70, 66)], seconds: 1)]),
        LightShow(id: "cinema", name: "Cinema", description: "Almost dark, with a touch of blue behind the screen.", category: "calm",
             steps: [LightStep([white(400, 6), colour(230, 90, 8)], seconds: 1)]),
        LightShow(id: "romantic", name: "Romantic", description: "Deep pink and soft red, dimmed.", category: "calm",
             steps: [LightStep([colour(340, 70, 30), colour(355, 85, 24)], seconds: 1)]),
        LightShow(id: "focus", name: "Focus", description: "Bright, cool white for work.", category: "calm",
             steps: [LightStep([white(200, 100)], seconds: 1)]),
        LightShow(id: "night-light", name: "Night light", description: "A faint amber glow to find your way.", category: "calm",
             steps: [LightStep([colour(25, 100, 3)], seconds: 1)]),

        // Animated: slow, for a long while.
        LightShow(id: "candle-flicker", name: "Candle flicker", description: "Warm amber, each light flickering on its own.", category: "animated",
             steps: [LightStep([white(480, 34), colour(30, 85, 30), white(454, 38)], assign: .random, seconds: 0.8, jitter: 10)],
             loop: true, durationSeconds: 3600),
        LightShow(id: "fireplace", name: "Fireplace", description: "Reds, oranges and amber dancing unevenly.", category: "animated",
             steps: [LightStep([colour(12, 100, 42), colour(24, 95, 55), colour(34, 90, 40), colour(6, 100, 28)], assign: .random, seconds: 1.2, jitter: 12)],
             loop: true, durationSeconds: 3600),
        LightShow(id: "ocean", name: "Ocean", description: "Blues and teals rolling from light to light like waves.", category: "animated",
             steps: rotations([colour(190, 80, 60), colour(205, 90, 48), colour(220, 85, 42), colour(178, 70, 55)], seconds: 3),
             loop: true, durationSeconds: 1800),
        LightShow(id: "northern-lights", name: "Northern lights", description: "Green, teal and violet drifting slowly.", category: "animated",
             steps: [LightStep([colour(140, 80, 45), colour(165, 75, 40), colour(280, 60, 35), colour(190, 70, 40)], assign: .random, seconds: 4)],
             loop: true, durationSeconds: 1800),
        LightShow(id: "breathing", name: "Breathing", description: "Soft light rising and falling in a six-second rhythm, to calm down.", category: "animated",
             steps: [LightStep([white(370, 12)], seconds: 3), LightStep([white(370, 55)], seconds: 3)],
             loop: true, durationSeconds: 900),
        LightShow(id: "sunset", name: "Sunset", description: "Ten minutes from golden yellow through orange and pink to a dim red.", category: "animated",
             steps: [LightStep([colour(45, 80, 80)], seconds: 120), LightStep([colour(30, 90, 60)], seconds: 120), LightStep([colour(345, 60, 40)], seconds: 120),
                     LightStep([colour(5, 100, 15)], seconds: 120), LightStep([colour(5, 100, 5)], seconds: 120)],
             restore: false),
        LightShow(id: "sunrise", name: "Sunrise", description: "Fifteen minutes from a dim red glow to bright warm white, to wake up.", category: "animated",
             steps: [LightStep([colour(5, 100, 2)], seconds: 180), LightStep([colour(22, 95, 15)], seconds: 240), LightStep([white(454, 40)], seconds: 240),
                     LightStep([white(300, 80)], seconds: 240), LightStep([white(250, 100)], seconds: 1)],
             restore: false),

        // Party: fast.
        LightShow(id: "disco", name: "Disco", description: "Every light jumps to a vivid colour on each beat.", category: "party",
             steps: [LightStep([0, 30, 55, 120, 180, 220, 265, 300, 330].map { colour($0, 100, 100) } + [colour(280, 100, 40), colour(160, 100, 40)], assign: .random, seconds: 0.5)],
             loop: true, durationSeconds: 120),
        LightShow(id: "police", name: "Police siren", description: "Red and blue swapping from light to light.", category: "party",
             steps: [LightStep([red, blue], seconds: 0.5), LightStep([blue, red], seconds: 0.5)],
             loop: true, durationSeconds: 30),
        LightShow(id: "rainbow-wave", name: "Rainbow wave", description: "The colour wheel passing from light to light.", category: "party",
             steps: (0..<18).map { turn in LightStep((0..<6).map { colour(Double((turn * 20 + $0 * 60) % 360), 100, 100) }, seconds: 0.6) },
             loop: true, durationSeconds: 120),
        LightShow(id: "lightning", name: "Lightning storm", description: "Dim stormy blue, with sudden white flashes.", category: "party",
             steps: [LightStep(Array(repeating: colour(225, 60, 10), count: 9) + [white(153, 100)], assign: .random, seconds: 0.6)],
             loop: true, durationSeconds: 300),
        LightShow(id: "halloween", name: "Halloween", description: "Purple and orange with an eerie flicker.", category: "party",
             steps: [LightStep([colour(275, 100, 50), colour(30, 100, 60), colour(275, 100, 20), colour(120, 100, 15)], assign: .random, seconds: 1.5, jitter: 15)],
             loop: true, durationSeconds: 1800),
        LightShow(id: "christmas", name: "Christmas", description: "Red and green taking turns, with a warm white twinkle now and then.", category: "party",
             steps: [LightStep([red, green], seconds: 3), LightStep([red, green, red, green, white(370, 100)], assign: .random, seconds: 0.6),
                     LightStep([green, red], seconds: 3), LightStep([green, red, green, red, white(370, 100)], assign: .random, seconds: 0.6)],
             loop: true, durationSeconds: 1800),

        // Signals: short, then back to how things were.
        LightShow(id: "alert", name: "Alert flash", description: "Two red pulses, then the lights go back to how they were.", category: "signal",
             steps: [LightStep([red], seconds: 0.7), LightStep([colour(0, 100, 10)], seconds: 0.7), LightStep([red], seconds: 0.7), LightStep([colour(0, 100, 10)], seconds: 0.7)],
             restore: true),
        LightShow(id: "bedtime", name: "Bedtime", description: "A slow fade to a dim red over fifteen minutes.", category: "signal",
             steps: [LightStep([white(454, 45)], seconds: 300), LightStep([colour(20, 90, 20)], seconds: 300), LightStep([colour(5, 100, 6)], seconds: 300),
                     LightStep([colour(5, 100, 2)], seconds: 1)],
             restore: false),
    ] + SceneArtwork.all.map(\.template)

    /// The same palette moved one light along at each step: a wave.
    static func rotations(_ palette: [LightColor], seconds: Double) -> [LightStep] {
        (0..<palette.count).map { shift in LightStep((0..<palette.count).map { palette[($0 + shift) % palette.count] }, seconds: seconds) }
    }

    /// Up to five CSS colours a show shows, in order: what a page draws it with.
    public static func swatch(_ show: LightShow) -> [String] {
        var colours: [String] = []
        for color in show.steps.prefix(8).flatMap(\.colors) where !color.isOff {
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
    public static func find(_ reference: String) -> LightShow? {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == wanted } ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

// MARK: - Lights and runs

/// A lightbulb service a show can change: On, and whichever of Brightness, Hue, Saturation and Color Temperature it has.
struct SceneLight: Sendable {
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

    /// A light's key: its accessory's id and its place among the accessory's lightbulbs.
    static func key(accessoryID: String, index: Int) -> String { "\(accessoryID)#\(index)" }

    static func accessoryID(ofKey key: String) -> String? { key.lastIndex(of: "#").map { String(key[..<$0]) } }

    /// What it shows now, for a held change's swatch.
    var color: LightColor {
        var color = LightColor(on: on.value.boolValue, brightness: brightness?.value.doubleValue)
        if let hue = hue?.value.doubleValue, let saturation = saturation?.value.doubleValue {
            color.hue = hue
            color.saturation = saturation
        } else {
            color.colorTemperature = colorTemperature?.value.doubleValue
        }
        return color
    }

    func snapshot() -> LightSnapshot {
        LightSnapshot(on: on.value, brightness: brightness?.value, hue: hue?.value, saturation: saturation?.value, colorTemperature: colorTemperature?.value,
                     adaptive: service.adaptiveLighting?.isAdaptiveLightingActive == true)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(located.accessory.id), "name": .string(name)]
        object["color"] = .bool(hasColour)
        if colorTemperature != nil { object["colorTemperature"] = true }
        return .object(object)
    }
}

/// A light's values before a show changed it, to put back.
struct LightSnapshot: Sendable, Codable {
    var on: HAPValue
    var brightness: HAPValue?
    var hue: HAPValue?
    var saturation: HAPValue?
    var colorTemperature: HAPValue?
    /// Adaptive Lighting ran: it resumes afterwards.
    var adaptive: Bool

    /// Whether a light's values moved from these (Adaptive Lighting aside).
    func differs(from other: LightSnapshot) -> Bool {
        on != other.on || brightness != other.brightness || hue != other.hue || saturation != other.saturation || colorTemperature != other.colorTemperature
    }
}

/// A run that can still be undone, as `held-lights.json` keeps it across restarts: what its lights were, by key.
struct SavedHeldLights: Codable, Sendable {
    var id: String
    var show: LightShow
    var startedAt: Date
    var by: String
    var snapshots: [String: LightSnapshot]
}

/// A show playing in the background, or one that set the lights and can still be undone (`isHeld`).
final class LightRun: Sendable {
    let id: String
    let show: LightShow
    let lights: [SceneLight]
    let startedAt: Date
    let endsAt: Date?
    let by: String
    let task = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// The lights it puts back when it ends, with their values; a show that takes a light over takes its snapshot.
    let snapshots: NIOLockedValueBox<[String: LightSnapshot]>

    init(id: String, show: LightShow, lights: [SceneLight], startedAt: Date, endsAt: Date?, by: String, snapshots: [String: LightSnapshot]) {
        self.id = id
        self.show = show
        self.lights = lights
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.by = by
        self.snapshots = NIOLockedValueBox(snapshots)
    }

    /// It set the lights once; stopping it undoes that.
    var isHeld: Bool { !show.isAnimated }

    var json: JSONValue {
        // A held show lists the lights it would still put back (another show may have taken some).
        let kept = snapshots.withLockedValue { Set($0.keys) }
        var object: [String: JSONValue] = [
            "id": .string(id), "name": .string(show.name), "startedAt": .string(Timestamp.iso8601(startedAt)), "by": .string(by),
            "lights": .array(lights.filter { !isHeld || kept.contains($0.key) }.map(\.json)), "swatch": .array(SceneTemplateLibrary.swatch(show).map(JSONValue.string)),
        ]
        if isHeld {
            object["held"] = true
            object["undoUntil"] = .string(Timestamp.iso8601(startedAt.addingTimeInterval(LightShowRules.undoSeconds)))
        }
        if let showID = show.id { object["show"] = .string(showID) }
        if let endsAt { object["endsAt"] = .string(Timestamp.iso8601(endsAt)) }
        return .object(object)
    }
}

extension HomeswiftCatalog {
    // MARK: Picking the lights

    /// The lightbulbs of these accessories (`ids`) or of those `filter` picks (a room…), at most `LightShowRules.maxLights`.
    func sceneLights(ids: [String]?, filter: AccessoryFilter?) throws -> [SceneLight] {
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
        let lights = Self.lights(of: accessories)
        guard !lights.isEmpty else { throw CatalogError("No light there: shows change lightbulbs only") }
        guard lights.count <= LightShowRules.maxLights else { throw CatalogError("That is \(lights.count) lights; a show changes at most \(LightShowRules.maxLights). Pick a room or fewer lights.") }
        return lights
    }

    /// The lightbulbs of these accessories that a show can write.
    static func lights(of accessories: [Located]) -> [SceneLight] {
        accessories.flatMap { located in
            located.accessory.services.filter { $0.type.uuid == ServiceType.lightbulb.uuid }.enumerated().compactMap { index, service -> SceneLight? in
                guard let on = service[.on], !on.isSecurityControl, on.type.permissions.contains(.pairedWrite) else { return nil }
                func writable(_ type: CharacteristicType) -> Characteristic? {
                    service[type].flatMap { $0.type.permissions.contains(.pairedWrite) && !$0.isSecurityControl ? $0 : nil }
                }
                return SceneLight(located: located, service: service, key: SceneLight.key(accessoryID: located.accessory.id, index: index), on: on, brightness: writable(.brightness),
                                 hue: writable(.hue), saturation: writable(.saturation), colorTemperature: writable(.colorTemperature))
            }
        }
    }

    // MARK: Held shows on disk

    /// Writes the runs that can still be undone to `held-lights.json`, with what their lights were, after every change:
    /// a restart brings them back (`restoreHeldLights`).
    func saveHeldLights() {
        let saved = home.lightRuns.withLockedValue { Array($0.values) }.filter(\.isHeld).sorted { $0.startedAt < $1.startedAt }.compactMap { run in
            let snapshots = run.snapshots.withLockedValue { $0 }
            return snapshots.isEmpty ? nil : SavedHeldLights(id: run.id, show: run.show, startedAt: run.startedAt, by: run.by, snapshots: snapshots)
        }
        do { try home.heldLights.update { $0 = saved } } catch { logger.warning("Could not save the shows that can be undone: \(error)") }
    }

    /// Holds again the runs a restart interrupted, for what is left of their time, on those of their lights the bridge
    /// has now; what the others were stays in the file until the run ends, for a later start that has them.
    func restoreHeldLights() {
        let now = Date()
        for saved in home.heldLights.value where now.timeIntervalSince(saved.startedAt) < LightShowRules.undoSeconds {
            guard home.lightRuns.withLockedValue({ $0[saved.id] == nil }) else { continue }
            let keys = saved.snapshots.keys.sorted()
            let found = currentLights(keys: keys)
            let lights = keys.compactMap { found[$0] }
            guard !lights.isEmpty else { continue }
            _ = hold(saved.show, on: lights, snapshots: saved.snapshots, by: saved.by,
                     id: saved.id, startedAt: saved.startedAt, save: false)
            logger.info("LightShow \"\(saved.show.name)\" can still be undone after the restart", metadata: ["run": "\(saved.id)"])
        }
        saveHeldLights()
    }

    /// The lights with these keys, as their accessories are now (each accessory looked up once).
    func currentLights(keys: [String]) -> [String: SceneLight] {
        let wanted = Set(keys)
        let accessories = Set(keys.compactMap(SceneLight.accessoryID(ofKey:))).compactMap { find(id: $0) }
        return Dictionary(uniqueKeysWithValues: Self.lights(of: accessories).filter { wanted.contains($0.key) }.map { ($0.key, $0) })
    }

    // MARK: Undoing a plugin's change

    /// Runs a plugin action that changes lights (`AssistantAction.changesLights`: a scene recalled on the device's own
    /// hub) so that it can be undone like a show. The plugin's lights are read before; their changes are followed until
    /// they stop for a moment (`LightShowRules.pluginSettle` at most), and the lights that changed are held as a run that
    /// stop_scene undoes, by the id `holdLightChanges` was given. `action` answers whether it went through; nil when it did not or no light changed.
    func holdLightChanges(_ name: String, id: String? = nil, platform: PluginHost.PlatformInstance, by: String, during action: () async throws -> Bool) async rethrows -> LightRun? {
        let lights = Self.lights(of: located().filter { $0.platform?.name == platform.name && $0.platform?.platform == platform.platform })
        guard !lights.isEmpty else { _ = try await action(); return nil }
        let before = Dictionary(uniqueKeysWithValues: lights.map { ($0.key, $0.snapshot()) })
        let ids = Set(lights.map(\.located.accessory.id))
        let lastChange = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
        let observation = host.observeChanges { accessory, _, _ in
            if ids.contains(accessory.id) { lastChange.withLockedValue { $0 = .now } }
        }
        defer { observation.cancel() }
        guard try await action() else { return nil }
        // The hub reports the new values over a moment: wait until they have been quiet for a while.
        let deadline = ContinuousClock.now + LightShowRules.pluginSettle
        while ContinuousClock.now < deadline {
            if let last = lastChange.withLockedValue({ $0 }), ContinuousClock.now - last >= .milliseconds(750) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let changed = lights.filter { before[$0.key].map($0.snapshot().differs) ?? false }
        guard !changed.isEmpty else { return nil }
        let snapshots = await takeOver(changed, before: before)
        let show = LightShow(id: id, name: name, steps: [LightStep(changed.map(\.color), seconds: LightShowRules.minSeconds)])
        let run = hold(show, on: changed, snapshots: snapshots, by: by)
        logger.info("\(name) changed \(changed.count) light(s); stop_scene undoes it", metadata: ["by": "\(by)", "run": "\(run.id)"])
        return run
    }

    // MARK: Starting and stopping

    /// Stops the running show `id`, or every one, and undoes those that set the lights once: each puts its lights back.
    public func stopLightRuns(id: String? = nil) async throws -> JSONValue {
        let runs = home.lightRuns.withLockedValue { running -> [LightRun] in
            if let id { return running[id].map { [$0] } ?? [] }
            return Array(running.values)
        }
        if let id, runs.isEmpty { throw CatalogError("No show \(id) is playing") }
        for run in runs {
            let task = run.task.withLockedValue { $0 }
            task?.cancel()
            await task?.value
        }
        return ["stopped": .array(runs.map(\.json))]
    }

    /// A scene's actions that set these lights as a step does: each light its colour of the step, then On.
    func staticActions(_ step: LightStep, on lights: [SceneLight]) -> [JSONValue] {
        var actions: [JSONValue] = []
        for (index, light) in lights.enumerated() {
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
        return actions
    }

    // MARK: Playing

    /// Starts an animated show in the background; lights another show was playing on change hands without a flash
    /// back to their old values.
    func play(_ show: LightShow, on lights: [SceneLight], by: String) async -> LightRun {
        let snapshots = await takeOver(lights)
        let now = Date()
        let total = show.loop == true ? (show.durationSeconds ?? LightShowRules.defaultDuration) : show.steps.reduce(0) { $0 + $1.seconds }
        let run = LightRun(id: LightShowRules.newID(), show: show, lights: lights, startedAt: now, endsAt: now.addingTimeInterval(total), by: by, snapshots: snapshots)
        let catalog = self
        // Registered with its task before anything else can stop it.
        home.lightRuns.withLockedValue { running in
            running[run.id] = run
            run.task.withLockedValue { $0 = Task { await catalog.perform(run) } }
        }
        logger.info("LightShow \"\(show.name)\" playing on \(lights.count) light(s) for \(Int(total)) s", metadata: ["by": "\(by)", "run": "\(run.id)"])
        return run
    }

    /// Stops the shows playing on any of these lights and answers what each light was before: a show's snapshot of it,
    /// else `before`'s, else what it shows now; to restore when the new change ends or is undone. A held show only
    /// gives up those lights: its others stay as it set them, still to undo; it ends when it has none left.
    func takeOver(_ lights: [SceneLight], before: [String: LightSnapshot] = [:]) async -> [String: LightSnapshot] {
        let keys = Set(lights.map(\.key))
        let runs = home.lightRuns.withLockedValue { running in running.values.filter { !keys.isDisjoint(with: $0.lights.map(\.key)) } }
        var inherited: [String: LightSnapshot] = [:]
        var heldShrank = false
        for run in runs {
            // What it still holds of lights the bridge has: a restored run may keep others it cannot reach now.
            let runKeys = Set(run.lights.map(\.key))
            let left = run.snapshots.withLockedValue { snapshots -> Int in
                for key in keys { if let snapshot = snapshots.removeValue(forKey: key) { inherited[key] = snapshot } }
                return snapshots.keys.filter(runKeys.contains).count
            }
            if run.isHeld, left > 0 {
                heldShrank = true
                continue
            }
            let task = run.task.withLockedValue { $0 }
            task?.cancel()
            await task?.value
        }
        // A held show that gave up some lights keeps fewer to put back; one that gave up all saves as it ends.
        if heldShrank { saveHeldLights() }
        return Dictionary(uniqueKeysWithValues: lights.map { ($0.key, inherited[$0.key] ?? before[$0.key] ?? $0.snapshot()) })
    }

    /// Keeps a show that set the lights once, for `LightShowRules.undoSeconds`: stopping it in that time puts the lights
    /// back; after it, the chance to undo ends and the lights stay.
    /// A run brought back after a restart keeps its id and start, so its chance to undo ends when it would have.
    func hold(_ show: LightShow, on lights: [SceneLight], snapshots: [String: LightSnapshot], by: String,
                      id: String = LightShowRules.newID(), startedAt: Date = Date(), save: Bool = true) -> LightRun {
        let run = LightRun(id: id, show: show, lights: lights, startedAt: startedAt, endsAt: nil, by: by, snapshots: snapshots)
        let catalog = self
        let left = max(0, LightShowRules.undoSeconds - Date().timeIntervalSince(startedAt))
        home.lightRuns.withLockedValue { running in
            running[run.id] = run
            run.task.withLockedValue { task in
                task = Task {
                    let undone = (try? await Task.sleep(for: .seconds(left))) == nil
                    if undone { await catalog.restoreAll(run) }
                    let removed = catalog.home.lightRuns.withLockedValue { running -> Bool in
                        guard running[run.id] === run else { return false }
                        running[run.id] = nil
                        return true
                    }
                    if removed { catalog.saveHeldLights() }
                }
            }
        }
        if save { saveHeldLights() }
        return run
    }

    /// Puts back every light a run still holds a snapshot of, all at the same time.
    private func restoreAll(_ run: LightRun) async {
        let snapshots = run.snapshots.withLockedValue { $0 }
        // The accessories as they are now: a plugin that added one again since gave it new characteristics.
        let current = currentLights(keys: run.lights.map(\.key))
        await withTaskGroup(of: Void.self) { group in
            for light in run.lights {
                guard let snapshot = snapshots[light.key] else { continue }
                let light = current[light.key] ?? light
                group.addTask { await self.restore(light, snapshot) }
            }
        }
    }

    private func perform(_ run: LightRun) async {
        let show = run.show
        var active = run.lights
        var failures: [String: Int] = [:]
        var lastOn: [String: Bool] = [:]
        let deadline = show.loop == true ? run.endsAt : nil
        outer: repeat {
            for (index, step) in show.steps.enumerated() {
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
                        if failures[key, default: 0] >= LightShowRules.maxFailures, let light = lightsByKey[key] {
                            logger.warning("LightShow \"\(show.name)\": \(light.name) left the show after \(LightShowRules.maxFailures) failed writes: \(error)")
                        }
                    }
                }
                active.removeAll { failures[$0.key, default: 0] >= LightShowRules.maxFailures }
                if active.isEmpty { break outer }
                let last = show.loop != true && index == show.steps.count - 1
                if last, !show.restoresAtEnd { break outer }
                // The step lasts its seconds from when it began: the writes are part of it.
                var wait = step.seconds - Date().timeIntervalSince(stepStart)
                if let deadline { wait = min(wait, deadline.timeIntervalSinceNow) }
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { break outer }
                }
                if let deadline, Date() >= deadline { break outer }
            }
        } while show.loop == true && !Task.isCancelled
        if show.restoresAtEnd || Task.isCancelled { await restoreAll(run) }
        home.lightRuns.withLockedValue { running in
            if running[run.id] === run { running[run.id] = nil }
        }
        logger.info("LightShow \"\(show.name)\" ended", metadata: ["run": "\(run.id)"])
    }

    /// Paints a step on every light at the same time, so a fast step flashes the room at once rather than light by
    /// light. By light: the On it now has (`lastOn` after), or why it failed.
    private func paintAll(_ step: LightStep, on lights: [SceneLight], lastOn: [String: Bool]) async -> [String: Result<Bool?, any Error>] {
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
        let light: SceneLight
        let color: LightColor
        let wasOn: Bool?
        let writes: [(Characteristic, HAPValue)]
    }

    static func pick(_ step: LightStep, for position: Int) -> LightColor {
        step.assign == .random ? step.colors.randomElement()! : step.colors[position % step.colors.count]
    }

    /// The values a colour gives a light: brightness, then the colour (saturation and hue, or a white as colour
    /// temperature, or that white as saturation and hue on a light with no colour temperature). They are written at
    /// the same time, as the Home app writes them, so their order does not matter.
    func paintValues(_ light: SceneLight, _ color: LightColor, jitter: Double) -> [(Characteristic, HAPValue)] {
        var values: [(Characteristic, HAPValue)] = []
        if let brightness = light.brightness, let level = color.brightness {
            let shaken = jitter > 0 ? level + Double.random(in: -jitter...jitter) : level
            values.append((brightness, LightShowRules.hapNumber(max(1, min(100, shaken)), for: brightness)))
        }
        if let hue = light.hue, let saturation = light.saturation, color.hue != nil || color.saturation != nil {
            if let value = color.saturation { values.append((saturation, LightShowRules.hapNumber(value, for: saturation))) }
            if let value = color.hue { values.append((hue, LightShowRules.hapNumber(value, for: hue))) }
        } else if let mired = color.colorTemperature {
            if let temperature = light.colorTemperature {
                values.append((temperature, LightShowRules.hapNumber(mired, for: temperature)))
            } else if let hue = light.hue, let saturation = light.saturation {
                let converted = ColorUtils.colorTemperatureToHueAndSaturation(mired)
                values.append((saturation, LightShowRules.hapNumber(converted.saturation, for: saturation)))
                values.append((hue, LightShowRules.hapNumber(converted.hue, for: hue)))
            }
        }
        return values
    }

    /// Writes a colour to a light, turning it on last so it lights up in the new colour. Its values go at the same
    /// time, as the Home app sends them, so a plugin that gathers a moment's changes sends them as one command.
    /// `lastOn` is what this show last set, so On is written only when it changes; answers what it is now.
    private func write(_ light: SceneLight, _ characteristic: Characteristic, _ value: HAPValue) async throws {
        do {
            try await characteristic.write(value)
        } catch let error as HAPStatusError {
            throw Self.failure(error, of: light.located)
        }
    }

    /// Puts a light back: every value it had, brightness and colour, then On. A light with both kinds of colour shows
    /// the one written last, so that is the one it showed: colour temperature when the hue and saturation were only
    /// that white's, else the hue and saturation. Adaptive Lighting resumes when it ran.
    private func restore(_ light: SceneLight, _ snapshot: LightSnapshot) async {
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
            do { try await characteristic.write(value) } catch { logger.debug("LightShow: could not restore \(characteristic.type.name) of \(light.name): \(error)") }
        }
        if snapshot.adaptive, let controller = light.service.adaptiveLighting, !controller.isAdaptiveLightingActive {
            _ = controller.resumeAdaptiveLighting()
        }
    }

    // MARK: The Assistant

    /// A show the Assistant writes from a description, for these lights (how many, which take colours or whites;
    /// never their names).
    func designScene(_ description: String, lights: [SceneLight], language: String?) async throws -> LightShow {
        guard let assistant = host.assistant?.speaking(language) else { throw CatalogError("the Assistant is off: add a HomeswiftAiKit block, or pick a show from the list") }
        let summary: JSONValue = [
            "lights": .number(Double(lights.count)),
            "colour": .number(Double(lights.filter(\.hasColour).count)),
            "whiteOnly": .number(Double(lights.filter { !$0.hasColour && $0.colorTemperature != nil }.count)),
            "dimmableOnly": .number(Double(lights.filter { !$0.hasColour && $0.colorTemperature == nil && $0.brightness != nil }.count)),
        ]
        let reply: JSONGenerationResult
        do {
            reply = try await assistant.designScene(description, lights: summary)
        } catch let error as JSONGenerationError {
            throw CatalogError("The Assistant could not write a show: \(error.message)")
        }
        var show = try LightShowRules.show(from: reply.data)
        show.id = nil
        show.category = nil
        return show
    }
}
