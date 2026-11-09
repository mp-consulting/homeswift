import Foundation
import HomeswiftPlugin

// Power on (README.md, "Power on"): what a light does when its power comes back, from a wall switch or after a power cut,
// as the Hue app's Power on sets it (the light's `powerup`, CLIP v2). A light's Plugin Accessory Setting `powerOn`
// (`default`, `lastOn`, `powerLoss`, `custom`), with `powerOnBrightness` and `powerOnTemperature` for `custom`; empty
// leaves the light as the bridge has it. The plugin writes it when a read of the bridge finds the light different: once
// a run, and again when the setting changes, so what the Hue app changes in between stays until then.

/// A light's `powerup`, as the bridge has it or as a setting wants it.
struct HuePowerUp: Sendable, Equatable {
    enum Preset: String, Sendable {
        /// Default: warm white, full brightness.
        case safety
        /// Power loss recovery: as it was before the power went, off or on.
        case powerfail
        /// Last on: on, in its last colour and brightness.
        case lastOnState = "last_on_state"
        /// On, in the brightness and colour temperature given (nil: its last).
        case custom
    }

    var preset: Preset
    /// With `custom`: 1 to 100, and mirek; nil keeps the light's last.
    var brightness: Double?
    var mirek: Int?

    init(preset: Preset, brightness: Double? = nil, mirek: Int? = nil) {
        (self.preset, self.brightness, self.mirek) = (preset, brightness, mirek)
    }

    /// The light's, from its resource; nil on one without (an older light, or firmware).
    init?(resource: JSONValue) {
        guard let powerup = resource["powerup"], let preset = powerup["preset"]?.stringValue.flatMap(Preset.init(rawValue:)) else { return nil }
        self.preset = preset
        guard preset == .custom else { return }
        if powerup["dimming"]?["mode"]?.stringValue == "dimming" { brightness = powerup["dimming"]?["dimming"]?["brightness"]?.doubleValue }
        if powerup["color"]?["mode"]?.stringValue == "color_temperature" { mirek = powerup["color"]?["color_temperature"]?["mirek"]?.intValue }
    }

    /// The setting's (`powerOn` and the custom ones) for this light, its values brought into its range; nil when the
    /// setting is empty or names nothing it knows.
    init?(setting: String?, brightness: Int?, temperature: Int?, for light: HueLight) {
        switch setting {
        case "default": self.init(preset: .safety)
        case "lastOn": self.init(preset: .lastOnState)
        case "powerLoss": self.init(preset: .powerfail)
        case "custom":
            let level = light.dims ? brightness.map { Double(min(100, max(1, $0))) } : nil
            let mirek = temperature.flatMap { kelvin -> Int? in
                guard kelvin > 0, let range = light.mirekRange else { return nil }
                return min(range.upperBound, max(range.lowerBound, Int((1_000_000 / Double(kelvin)).rounded())))
            }
            self.init(preset: .custom, brightness: level, mirek: mirek)
        default: return nil
        }
    }

    /// Whether `current`, the light's, already does this: the same preset, and for `custom` the same values (to the
    /// percent and the mirek the bridge rounds them to).
    func isMet(by current: HuePowerUp?) -> Bool {
        guard let current, current.preset == preset else { return false }
        guard preset == .custom else { return true }
        let sameLevel = switch (brightness, current.brightness) {
        case (nil, nil): true
        case let (wanted?, has?): abs(wanted - has) < 1
        default: false
        }
        let sameWhite = switch (mirek, current.mirek) {
        case (nil, nil): true
        case let (wanted?, has?): abs(wanted - has) <= 1
        default: false
        }
        return sameLevel && sameWhite
    }

    /// The body of `PUT /clip/v2/resource/light/<id>`. A preset other than `custom` goes alone: the bridge sets the
    /// rest, and takes nothing else with it. `custom` turns the light on, at its brightness and white, or its last.
    func body(for light: HueLight) -> JSONValue {
        guard preset == .custom else { return ["powerup": ["preset": .string(preset.rawValue)]] }
        var powerup: [String: JSONValue] = ["preset": "custom", "on": ["mode": "on", "on": ["on": true]]]
        if light.dims {
            powerup["dimming"] = brightness.map { ["mode": "dimming", "dimming": ["brightness": .number($0)]] } ?? ["mode": "previous"]
        }
        if light.hasColourTemperature || light.hasColour {
            powerup["color"] = mirek.map { ["mode": "color_temperature", "color_temperature": ["mirek": .number(Double($0))]] } ?? ["mode": "previous"]
        }
        return ["powerup": .object(powerup)]
    }

    /// For the log: "custom 80 % 366 mirek".
    var summary: String {
        ([preset.rawValue] + [brightness.map { "\(Int($0)) %" }, mirek.map { "\($0) mirek" }].compactMap { $0 }).joined(separator: " ")
    }
}

extension PhilipsHuePlugin {
    /// What a light's Power on setting wants of it; nil when it is empty.
    func wantedPowerUp(_ light: HueLight) -> HuePowerUp? {
        let own = lightOptions(light.id)
        return HuePowerUp(setting: own.powerOn, brightness: own.powerOnBrightness, temperature: own.powerOnTemperature, for: light)
    }

    /// Writes each light's Power on setting where the bridge has it otherwise: once for each value the setting takes
    /// in a run, so a change made in the Hue app since stays until the setting changes or the plugin starts again. A
    /// light without `powerup` is told once in the log; a write that fails is tried again at the next read, told once.
    func applyPowerUps(_ snapshot: HueSnapshot) async {
        guard let client else { return }
        for light in snapshot.lights where !isExcluded(light) {
            guard let wanted = wantedPowerUp(light) else {
                powerUpsApplied[light.id] = nil
                continue
            }
            guard powerUpsApplied[light.id] != wanted else { continue }
            guard light.powerUp != nil else {
                powerUpsApplied[light.id] = wanted
                logger.notice("\(light.name) has no Power on setting on the Hue Bridge (its firmware may be too old)", metadata: ["light": "\(light.id)"])
                continue
            }
            guard !wanted.isMet(by: light.powerUp) else {
                powerUpsApplied[light.id] = wanted
                continue
            }
            do {
                try await client.put("light", id: light.id, wanted.body(for: light))
                powerUpsApplied[light.id] = wanted
                powerUpFailures.remove(light.id)
                logger.info("Set what \(light.name) does when its power comes on", metadata: ["light": "\(light.id)", "powerOn": "\(wanted.summary)"])
            } catch {
                if powerUpFailures.insert(light.id).inserted {
                    logger.warning("Could not set what \(light.name) does when its power comes on: \(error)", metadata: ["light": "\(light.id)"])
                }
            }
        }
    }
}
