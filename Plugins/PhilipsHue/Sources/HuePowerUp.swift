import Foundation
import HomeswiftPlugin

// Power On (GLOSSARY.md, the bridge's `PowerOn.swift`): what a Hue light does when its power comes back, its `powerup`
// (CLIP v2), as the Hue app's Power on sets it: a preset (`safety` the Hue default, `last_on_state`, `powerfail`) or
// `custom`, whose on, dimming and colour each say a value or `previous`. The bridge's Natural Light is `custom` with the
// light as it was and the white it gives.

/// A light's `powerup`, as the Hue Bridge has it.
struct HuePowerUp: Sendable, Equatable {
    enum Preset: String, Sendable {
        case safety, powerfail, lastOnState = "last_on_state", custom
    }

    enum On: Sendable, Equatable { case on, off, previous }

    var preset: Preset
    /// With `custom`: on, off or as it was; its brightness (1-100) and white (mirek), nil for their last.
    var on: On = .on
    var brightness: Double?
    var mirek: Int?

    init(preset: Preset, on: On = .on, brightness: Double? = nil, mirek: Int? = nil) {
        (self.preset, self.on, self.brightness, self.mirek) = (preset, on, brightness, mirek)
    }

    /// The light's, from its resource; nil on one without (older firmware).
    init?(resource: JSONValue) {
        guard let powerup = resource["powerup"], let preset = powerup["preset"]?.stringValue.flatMap(Preset.init(rawValue:)) else { return nil }
        self.preset = preset
        guard preset == .custom else { return }
        switch powerup["on"]?["mode"]?.stringValue {
        case "previous": on = .previous
        case "on": on = powerup["on"]?["on"]?["on"]?.boolValue == false ? .off : .on
        default: on = .on
        }
        if powerup["dimming"]?["mode"]?.stringValue == "dimming" { brightness = powerup["dimming"]?["dimming"]?["brightness"]?.doubleValue }
        if powerup["color"]?["mode"]?.stringValue == "color_temperature" { mirek = powerup["color"]?["color_temperature"]?["mirek"]?.intValue }
    }

    /// What the bridge's Power On asks of `light`.
    init(_ value: PowerOn, for light: HueLight) {
        let mirek = value.mirek.map { mirek in light.mirekRange.map { min($0.upperBound, max($0.lowerBound, mirek)) } ?? mirek }
        switch value.behaviour {
        case .default: self.init(preset: .safety)
        case .lastOn: self.init(preset: .lastOnState)
        case .powerLoss: self.init(preset: .powerfail)
        case .off: self.init(preset: .custom, on: .off)
        case .custom: self.init(preset: .custom, brightness: light.dims ? value.brightness.map(Double.init) : nil, mirek: light.hasColourTemperature ? mirek : nil)
        case .natural: self.init(preset: .custom, on: .previous, mirek: mirek)
        }
    }

    /// As the bridge's Power On reads it.
    var powerOn: PowerOn {
        switch preset {
        case .safety: PowerOn(.default)
        case .lastOnState: PowerOn(.lastOn)
        case .powerfail: PowerOn(.powerLoss)
        case .custom:
            switch on {
            case .off: PowerOn(.off)
            case .previous where brightness == nil && mirek == nil: PowerOn(.powerLoss)
            default: PowerOn(.custom, brightness: brightness.map { Int($0.rounded()) }, temperature: mirek.map(PowerOn.kelvin(mirek:)))
            }
        }
    }

    /// The body of `PUT /clip/v2/resource/light/<id>`. A preset other than `custom` goes alone: the bridge sets the
    /// rest. `custom` says its on, and the dimming and colour the light has (a value, or `previous`).
    func body(for light: HueLight) -> JSONValue {
        guard preset == .custom else { return ["powerup": ["preset": .string(preset.rawValue)]] }
        let onPart: JSONValue = switch on {
        case .on: ["mode": "on", "on": ["on": true]]
        case .off: ["mode": "on", "on": ["on": false]]
        case .previous: ["mode": "previous"]
        }
        var powerup: [String: JSONValue] = ["preset": "custom", "on": onPart]
        if light.dims, on != .off {
            powerup["dimming"] = brightness.map { ["mode": "dimming", "dimming": ["brightness": .number($0)]] } ?? ["mode": "previous"]
        }
        if light.hasColourTemperature || light.hasColour, on != .off {
            powerup["color"] = mirek.map { ["mode": "color_temperature", "color_temperature": ["mirek": .number(Double($0))]] } ?? ["mode": "previous"]
        }
        return ["powerup": .object(powerup)]
    }
}

extension PhilipsHuePlugin {
    /// The light an accessory is, when it keeps a `powerup`.
    private func powerUpLight(_ accessoryID: String) -> HueLight? {
        snapshot.lights.first { Self.accessoryID(lightID: $0.id) == accessoryID && $0.powerUp != nil }
    }

    public func powerOnSupport(of accessoryID: String) async -> PowerOnSupport? {
        guard let light = powerUpLight(accessoryID) else { return nil }
        return PowerOnSupport(behaviours: (light.mirekRange != nil ? [.natural] : []) + [.default, .lastOn, .powerLoss, .off, .custom],
                              brightness: light.dims, mirek: light.mirekRange)
    }

    public func powerOn(of accessoryID: String) async throws -> PowerOn? {
        powerUpLight(accessoryID)?.powerUp?.powerOn
    }

    public func setPowerOn(_ value: PowerOn, of accessoryID: String) async throws {
        guard let light = powerUpLight(accessoryID), let client else { throw PowerOnError("This Hue light has no Power on on the Hue Bridge") }
        let powerUp = HuePowerUp(value, for: light)
        try await client.put("light", id: light.id, powerUp.body(for: light))
        // What the next read will say, kept now so the sheet shows it at once.
        if let index = snapshot.lights.firstIndex(where: { $0.id == light.id }) { snapshot.lights[index].powerUp = powerUp }
    }
}
