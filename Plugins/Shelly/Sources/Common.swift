import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The Power Meter service both Homebridge plugins add to metering devices, with Eve's power characteristics: the Eve
/// app shows them, the Home app ignores them.
enum PowerMeter {
    static let consumption = CharacteristicType(
        name: "Consumption", uuid: HAPUUID("E863F10D-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 12000, minStep: 0.1)
    static let totalConsumption = CharacteristicType(
        name: "Total Consumption", uuid: HAPUUID("E863F10C-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 1_000_000, minStep: 0.1)
    static let voltage = CharacteristicType(
        name: "Voltage", uuid: HAPUUID("E863F10A-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: -1000, maxValue: 1000, minStep: 0.1)
    static let electricCurrent = CharacteristicType(
        name: "Electric Current", uuid: HAPUUID("E863F126-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 48, minStep: 0.1)
    static let service = ServiceType(
        name: "Power Meter", uuid: HAPUUID("DEDBEA44-11ED-429C-BD75-9A2286AA8707"), required: [consumption],
        optional: [voltage, electricCurrent, totalConsumption])

    /// Gen 1's Consumption goes to 65535 W.
    static let gen1Consumption = consumption.with(maxValue: 65535)
}

/// The Tilt Sensor service of the Gen 1 plugin (Door/Window), with the standard Current Tilt Angle from 0 to 180.
enum TiltSensor {
    static let angle = CharacteristicType.currentTiltAngle.with(minValue: 0, maxValue: 180)
    static let service = ServiceType(name: "Tilt Sensor", uuid: HAPUUID("DA2354B4-3C77-4EAF-BD37-AA0838B59513"), required: [angle])
}

extension Characteristic {
    /// Sets the value when it differs: an unchanged report reaches no observer (the history, scenes), as no controller.
    func update(_ value: HAPValue) {
        if self.value != value { self.value = value }
    }

    /// A number within the characteristic's bounds.
    func update(clamping number: Double) {
        var number = number.isFinite ? number : 0
        if let minValue = type.minValue { number = max(number, minValue) }
        if let maxValue = type.maxValue { number = min(number, maxValue) }
        switch type.format {
        case .float: update(.double((number * 1000).rounded() / 1000))
        default: update(.int(Int(saturating: number.rounded()) ?? 0))
        }
    }
}

/// Colour conversions in the integer rounding of the `color-convert` package both plugins rely on: hue 0 to 360,
/// saturation and value 0 to 100, red, green and blue 0 to 255.
enum ShellyColor {
    static func hsv(red: Double, green: Double, blue: Double) -> (hue: Int, saturation: Int, value: Int) {
        let r = min(max(red, 0), 255) / 255, g = min(max(green, 0), 255) / 255, b = min(max(blue, 0), 255) / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        var hue = 0.0
        if delta > 0 {
            switch high {
            case r: hue = (g - b) / delta
            case g: hue = 2 + (b - r) / delta
            default: hue = 4 + (r - g) / delta
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let saturation = high == 0 ? 0 : delta / high
        return (Int(hue.rounded()), Int((saturation * 100).rounded()), Int((high * 100).rounded()))
    }

    static func rgb(hue: Double, saturation: Double, value: Double = 100) -> (red: Int, green: Int, blue: Int) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 100) / 100, v = min(max(value, 0), 100) / 100
        let sector = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = 255 * v * (1 - s), q = 255 * v * (1 - s * f), t = 255 * v * (1 - s * (1 - f)), w = 255 * v
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (w, t, p)
        case 1: (q, w, p)
        case 2: (p, w, t)
        case 3: (p, q, w)
        case 4: (t, p, w)
        default: (w, p, q)
        }
        return (Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
    }

    /// Kelvin to mireds and back, rounded.
    static func mireds(kelvin: Double) -> Int { kelvin > 0 ? Int(saturating: (1_000_000 / kelvin).rounded(), in: 0...1_000_000) ?? 0 : 0 }
}

extension JSONValue {
    /// A number, or a boolean as 0 and 1 (Gen 1 and Gen 2 devices send either).
    var number: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .bool(let value): value ? 1 : 0
        case .string(let text): Double(text)
        default: nil
        }
    }

    /// JavaScript's truthiness, as the Homebridge plugins read a device's values.
    var isTruthy: Bool {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let text): !text.isEmpty
        case .null: false
        case .array, .object: true
        }
    }

    /// A number written as the device sent it: an integer without a decimal point.
    var decimalText: String? {
        switch self {
        case .number(let value) where value == value.rounded() && abs(value) < 1e15: String(Int64(value))
        case .number(let value): String(value)
        case .string(let text): text
        default: nil
        }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What a light's writes asked and HomeKit has not stored yet: a write handler runs before its value is stored, and the
/// one request that takes On, Brightness and a colour together reads them here.
final class PendingWrites: Sendable {
    private let box = NIOLockedValueBox<[HAPUUID: HAPValue]>([:])

    /// Each write of these characteristics is kept, then `send` runs; it waits for the last of quick writes
    /// (`LatestCallGuard`) and takes what they asked with `take()`.
    func register(_ service: Service, _ types: [CharacteristicType], _ send: @escaping @Sendable () async throws -> Void) {
        for type in types {
            service.characteristic(type).onWrite(changesOnly: true) { [box] value in
                box.withLockedValue { $0[type.uuid] = value }
                try await send()
            }
        }
    }

    /// The values asked since the last take, by characteristic; `service`'s own for the others.
    func take(_ service: Service) -> @Sendable (CharacteristicType) -> HAPValue {
        let written = box.withLockedValue { box in defer { box.removeAll() }; return box }
        return { type in written[type.uuid] ?? service.characteristic(type).value }
    }
}
