import Foundation
import Homeswift
import HomeswiftPlugin

/// What HomeKit asks a light to change.
enum HueChange: Sendable, Equatable {
    case on(Bool)
    case brightness(Double)
    case hue(Double)
    case saturation(Double)
    case mirek(Int)
}

/// Gathers a light's changes for a moment and sends them in one PUT: the Home app writes brightness, hue and
/// saturation of one change together, and the bridge takes them, with the transition, in one command. Hue needs
/// saturation to make a colour, so a hue or saturation alone takes the other from the lightbulb.
actor HueLightWriter {
    struct Pending: Equatable {
        var on: Bool?
        var brightness: Double?
        var hue: Double?
        var saturation: Double?
        var mirek: Int?
        var isEmpty: Bool { self == Pending() }
    }

    static let window = Duration.milliseconds(30)

    let lightID: String
    private let send: @Sendable (JSONValue) async throws -> Void
    /// The lightbulb's current hue and saturation, for a change that has only one of them.
    private let currentColour: @Sendable () -> (hue: Double, saturation: Double)
    private let gamut: HueGamut
    private let transitionMs: Int
    private var pending = Pending()
    private var batch: Task<Void, any Error>?
    /// When the last command went: a poll right after it may still read the old values.
    private(set) var lastSent: ContinuousClock.Instant?
    /// The last colour sent, and the hue and saturation it came from: the gamut moves a colour a little (pure red is
    /// about 9° on gamut C), so while the light reports that colour HomeKit keeps the values it asked for.
    private(set) var lastColour: (xy: HueXY, hue: Double, saturation: Double)?

    init(
        lightID: String, gamut: HueGamut, transitionMs: Int, currentColour: @escaping @Sendable () -> (hue: Double, saturation: Double),
        send: @escaping @Sendable (JSONValue) async throws -> Void
    ) {
        self.lightID = lightID
        self.gamut = gamut
        self.transitionMs = transitionMs
        self.currentColour = currentColour
        self.send = send
    }

    /// Adds a change to the next command and waits for it to be sent.
    func set(_ change: HueChange) async throws {
        try await queue(change).value
    }

    /// Adds a change to the next command without waiting: a saturation, whose hue usually follows.
    func enqueue(_ change: HueChange) {
        _ = queue(change)
    }

    private func queue(_ change: HueChange) -> Task<Void, any Error> {
        switch change {
        case .on(let value): pending.on = value
        case .brightness(let value): pending.brightness = value
        case .hue(let value): pending.hue = value; pending.mirek = nil
        case .saturation(let value): pending.saturation = value; pending.mirek = nil
        case .mirek(let value): pending.mirek = value; pending.hue = nil; pending.saturation = nil
        }
        if let batch { return batch }
        let task = Task<Void, any Error> {
            try await Task.sleep(for: Self.window)
            try await self.flush()
        }
        batch = task
        return task
    }

    private func flush() async throws {
        let changes = pending
        pending = Pending()
        batch = nil
        guard !changes.isEmpty else { return }
        lastSent = .now
        try await send(body(for: changes))
    }

    /// The PUT body: on, dimming, the colour or the white, and the transition.
    func body(for changes: Pending) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let on = changes.on { body["on"] = ["on": .bool(on)] }
        if let brightness = changes.brightness { body["dimming"] = ["brightness": .number(min(max(brightness, 0), 100))] }
        if changes.hue != nil || changes.saturation != nil {
            let current = currentColour()
            let (hue, saturation) = (changes.hue ?? current.hue, changes.saturation ?? current.saturation)
            let point = HueColor.xy(hue: hue, saturation: saturation, gamut: gamut)
            lastColour = (HueXY(x: Self.round(point.x), y: Self.round(point.y)), hue, saturation)
            body["color"] = ["xy": ["x": .number(Self.round(point.x)), "y": .number(Self.round(point.y))]]
        } else if let mirek = changes.mirek {
            body["color_temperature"] = ["mirek": .number(Double(mirek))]
        }
        // A light switched off goes off at once; everything else takes the transition.
        if changes.on != false || body.count > 1 { body["dynamics"] = ["duration": .number(Double(transitionMs))] }
        return .object(body)
    }

    static func round(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
}
