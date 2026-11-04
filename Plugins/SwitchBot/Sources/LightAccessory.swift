import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Colour conversions of §6.8.
enum ColorConversion {
    /// The hue (degrees) and saturation (percent) of an `r:g:b` colour.
    static func hueSaturation(rgb text: String) -> (hue: Int, saturation: Int)? {
        let parts = text.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, parts.allSatisfy({ $0.isFinite }) else { return nil }
        let (r, g, b) = (min(max(parts[0], 0), 255) / 255, min(max(parts[1], 0), 255) / 255, min(max(parts[2], 0), 255) / 255)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = 60 * ((b - r) / delta + 2) }
            else { hue = 60 * ((r - g) / delta + 4) }
        }
        if hue < 0 { hue += 360 }
        let saturation = high == 0 ? 0 : delta / high * 100
        return (Int(hue.rounded()) % 361, Int(saturation.rounded()))
    }

    /// The `r:g:b` colour of a hue and saturation at full value, with 4.x's correction of reds (green and blue × 0.8,
    /// both 0 when they end at 25 or less).
    static func rgb(hue: Double, saturation: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 100) / 100
        let c = s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = 1 - c
        let (r1, g1, b1): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        var r = ((r1 + m) * 255).rounded(), g = ((g1 + m) * 255).rounded(), b = ((b1 + m) * 255).rounded()
        if r == 255 {
            g = (g * 0.8).rounded()
            b = (b * 0.8).rounded()
            if g <= 25 && b <= 25 { g = 0; b = 0 }
        }
        r = min(max(r, 0), 255)
        return "\(Int(r)):\(Int(g)):\(Int(b))"
    }

    static func mireds(kelvin: Double) -> Int { Int((1_000_000 / max(kelvin, 1)).rounded()) }
    static func kelvin(mireds: Double) -> Int { Int((1_000_000 / max(mireds, 1)).rounded()) }
}

/// Color Bulb, Strip Light and the Ceiling Lights: a Lightbulb, with colour temperature (Color Bulb, Ceiling Lights;
/// Adaptive Lighting) and colour (Color Bulb, Strip Light) as each has them.
final class LightAccessory: DeviceAccessory, @unchecked Sendable {
    /// The range of the API's `setColorTemperature`, 2700 to 6500 K.
    static let mireds = 154...370

    let lightbulb: Service
    let hasTemperature: Bool
    let hasColor: Bool
    /// Kept here: the lightbulb holds it weakly.
    var adaptiveLighting: AdaptiveLightingController?

    private struct Values: Equatable {
        var on = false
        var brightness = 100
        var mireds = 250
        var hue = 0
        var saturation = 0
    }

    private var target = Values()
    private var reported = Values()
    private var colorChanged = false
    private var temperatureChanged = false
    /// The colour temperature the device last reported, so only its own changes turn Adaptive Lighting off.
    private var lastReportedMireds: Int?

    override var category: AccessoryCategory { .lightbulb }

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        hasTemperature = info.type != "Strip Light"
        hasColor = info.type == "Color Bulb" || info.type == "Strip Light"
        let step = max(info.options.number("set_minStep") ?? 1, 1)
        var optional: [CharacteristicType] = [CharacteristicType.brightness.with(minValue: 0, maxValue: 100, minStep: step)]
        if hasTemperature { optional.append(CharacteristicType.colorTemperature.with(minValue: Double(Self.mireds.lowerBound), maxValue: Double(Self.mireds.upperBound))) }
        if hasColor { optional += [.hue, .saturation] }
        lightbulb = Service(.lightbulb, name: info.name, optional: optional, isPrimary: true)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([lightbulb])
        lightbulb[.colorTemperature]?.value = .int(250)
        lightbulb.characteristic(.on).onWrite { [weak self] value in
            try await self?.write { self?.target.on = value.boolValue ?? false }
        }
        lightbulb.characteristic(.brightness).onWrite { [weak self] value in
            try await self?.write { self?.target.brightness = value.intValue ?? 100 }
        }
        lightbulb[.colorTemperature]?.onWrite { [weak self] value in
            try await self?.write {
                self?.target.mireds = min(max(value.intValue ?? 250, LightAccessory.mireds.lowerBound), LightAccessory.mireds.upperBound)
                self?.temperatureChanged = true
            }
        }
        lightbulb[.hue]?.onWrite { [weak self] value in
            try await self?.write {
                self?.target.hue = value.intValue ?? 0
                self?.colorChanged = true
            }
        }
        lightbulb[.saturation]?.onWrite { [weak self] value in
            try await self?.write {
                self?.target.saturation = value.intValue ?? 0
                self?.colorChanged = true
            }
        }
    }

    /// Whether Adaptive Lighting goes on this light: its colour temperature, unless `adaptiveLightingShift` is -1.
    var wantsAdaptiveLighting: Bool { hasTemperature && (options.number("adaptiveLightingShift") ?? 0) >= 0 }
    var adaptiveLightingShift: Int { Int(saturating: max(options.number("adaptiveLightingShift") ?? 0, 0)) ?? 0 }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        var values = lock.withLock { reported }
        // The Ceiling Light's power is a string (4.x showed the string itself).
        if let power = (status["power"] ?? status["powerState"])?.stringValue { values.on = power.lowercased() == "on" }
        if let brightness = status["brightness"].flatMap(number) { values.brightness = Int(saturating: brightness, in: 0...100) ?? values.brightness }
        var reportedMireds: Int?
        if hasTemperature, let kelvin = status["colorTemperature"].flatMap(number), kelvin > 0 {
            let mireds = min(max(ColorConversion.mireds(kelvin: kelvin), Self.mireds.lowerBound), Self.mireds.upperBound)
            values.mireds = mireds
            reportedMireds = mireds
        }
        if hasColor, let color = status["color"]?.stringValue, let (hue, saturation) = ColorConversion.hueSaturation(rgb: color) {
            values.hue = hue
            values.saturation = saturation
        }
        let writing = isWriting
        let previous = lock.withLock { () -> Int? in
            reported = values
            target = values
            defer { if let reportedMireds { lastReportedMireds = reportedMireds } }
            return lastReportedMireds
        }
        // A white set elsewhere (in the SwitchBot app) turns Adaptive Lighting off, before it is shown; not the echo of its own writes.
        if let reportedMireds, let previous, reportedMireds != previous, !writing {
            _ = adaptiveLighting?.disableIfChangedElsewhere(mireds: reportedMireds)
        }
        lightbulb.characteristic(.on).value = .bool(values.on)
        lightbulb.characteristic(.brightness).value = .int(values.brightness)
        lightbulb[.colorTemperature]?.value = .int(values.mireds)
        lightbulb[.hue]?.value = .int(values.hue)
        lightbulb[.saturation]?.value = .int(values.saturation)
    }

    override func showOffline() { lightbulb.characteristic(.on).value = .bool(false) }

    override func push() async throws {
        let (target, reported, temperatureChanged, colorChanged) = lock.withLock { () -> (Values, Values, Bool, Bool) in
            defer {
                self.temperatureChanged = false
                self.colorChanged = false
            }
            return (self.target, self.reported, self.temperatureChanged, self.colorChanged)
        }
        var commands: [Command] = []
        if target.on != reported.on { commands.append(Command(command: target.on ? "turnOn" : "turnOff")) }
        if target.on {
            if target.brightness != reported.brightness, target.brightness > 0 {
                commands.append(Command(command: "setBrightness", parameter: "\(min(max(target.brightness, 1), 100))"))
            }
            if hasTemperature, temperatureChanged,
               ColorConversion.kelvin(mireds: Double(target.mireds)) / 100 != ColorConversion.kelvin(mireds: Double(reported.mireds)) / 100 {
                let kelvin = min(max(ColorConversion.kelvin(mireds: Double(target.mireds)), 2700), 6500)
                commands.append(Command(command: "setColorTemperature", parameter: "\(kelvin)"))
            }
            if hasColor, colorChanged, target.hue != reported.hue || target.saturation != reported.saturation {
                commands.append(Command(command: "setColor", parameter: ColorConversion.rgb(hue: Double(target.hue), saturation: Double(target.saturation))))
            }
        }
        guard !commands.isEmpty else { return }
        if try await send(commands) {
            lock.withLock {
                self.reported = target
                lastReportedMireds = target.mireds
            }
        }
    }
}
