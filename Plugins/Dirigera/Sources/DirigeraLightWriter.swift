import Foundation
import HomeswiftPlugin

enum DirigeraChange: Sendable, Equatable {
    case on(Bool)
    case brightness(Int)
    case hue(Double)
    case saturation(Double)
    case mirek(Int)
}

/// Gathers a light's changes for a moment, then sends them in the order the hub wants, one PATCH each: On first when
/// it turns on, the level, then the colour (hue and saturation together) or the white, with the transition; Off alone.
/// Every library for the hub sends them apart, and openHAB found a light fading ignores the next command, so they go
/// one after the other.
actor DirigeraLightWriter {
    struct Pending: Equatable {
        var on: Bool?
        var brightness: Int?
        var hue: Double?
        var saturation: Double?
        var mirek: Int?
        var isEmpty: Bool { self == Pending() }
    }

    static let window = Duration.milliseconds(30)
    /// How long the hub's events about a light just written are left alone: they may still carry the old values.
    static let settleTime = Duration.seconds(1)

    private let transitionMs: Int
    private let currentColour: @Sendable () -> (hue: Double, saturation: Double)
    private let send: @Sendable (JSONValue, Int?) async throws -> Void
    private var pending = Pending()
    private var batch: Task<Void, any Error>?
    private var lastSent: ContinuousClock.Instant?

    init(transitionMs: Int, currentColour: @escaping @Sendable () -> (hue: Double, saturation: Double), send: @escaping @Sendable (JSONValue, Int?) async throws -> Void) {
        self.transitionMs = transitionMs
        self.currentColour = currentColour
        self.send = send
    }

    var isSettling: Bool { lastSent.map { ContinuousClock.now - $0 < Self.settleTime } ?? false }

    func set(_ change: DirigeraChange) async throws {
        try await queue(change).value
    }

    func enqueue(_ change: DirigeraChange) {
        _ = queue(change)
    }

    private func queue(_ change: DirigeraChange) -> Task<Void, any Error> {
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
        for (attributes, transition) in commands(for: changes) { try await send(attributes, transition) }
    }

    /// The PATCHes, in order, each with its transition (nil for On).
    func commands(for changes: Pending) -> [(JSONValue, Int?)] {
        if changes.on == false { return [(["isOn": false], nil)] }
        var commands: [(JSONValue, Int?)] = []
        if changes.on == true { commands.append((["isOn": true], nil)) }
        if let level = changes.brightness { commands.append((["lightLevel": .number(Double(min(max(level, 1), 100)))], transitionMs)) }
        if changes.hue != nil || changes.saturation != nil {
            let current = currentColour()
            let hue = changes.hue ?? current.hue, saturation = changes.saturation ?? current.saturation
            commands.append((["colorHue": .number(min(max(hue, 0), 360)), "colorSaturation": .number(min(max(saturation, 0), 100) / 100)], transitionMs))
        } else if let mirek = changes.mirek, mirek > 0 {
            commands.append((["colorTemperature": .number((1_000_000 / Double(mirek)).rounded())], transitionMs))
        }
        return commands
    }
}
