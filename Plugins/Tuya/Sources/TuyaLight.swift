import Foundation
import Homeswift
import HomeswiftAI

/// A light's kind, from the DPs it has (in this order).
enum TuyaLightType: String, Sendable {
    case rgbcw = "RGBCW", rgbc = "RGBC", rgb = "RGB", cw = "CW", c = "C", normal = "Normal", unknown = "Unknown"
}

/// A colour DP's `{"h","s","v"}`.
struct TuyaHSV: Sendable, Equatable {
    var h: Double, s: Double, v: Double

    init(h: Double, s: Double, v: Double) {
        self.h = h
        self.s = s
        self.v = v
    }

    /// A colour status: a JSON string (or object); empty, `{}` or missing reads as zeros.
    init(_ status: JSONValue?) {
        var object = status
        if case .string(let text)? = status { object = try? JSONValue(string: text) }
        h = object?["h"]?.doubleValue ?? 0
        s = object?["s"]?.doubleValue ?? 0
        v = object?["v"]?.doubleValue ?? 0
    }

    /// The compact string Tuya takes, keys in the order h, s, v, integers.
    var json: JSONValue {
        func int(_ value: Double) -> String { String(Int(saturating: value.rounded()) ?? 0) }
        return .string("{\"h\":\(int(h)),\"s\":\(int(s)),\"v\":\(int(v))}")
    }
}

extension TuyaAccessoryBuilder {
    /// Kelvin at the DP's minimum and maximum: colour temperature maps linearly in kelvin.
    static let warmestKelvin = 2000.0
    static let coolestKelvin = 1_000_000.0 / 140

    static func lightType(on: Bool, brightness: Bool, temperature: Bool, hsv: Bool, modes: [String]) -> TuyaLightType {
        let bothModes = modes.contains("colour") && modes.contains("white")
        if on, brightness, temperature, hsv, bothModes { return .rgbcw }
        if on, brightness, !temperature, hsv, bothModes { return .rgbc }
        if on, !temperature, hsv { return .rgb }
        if on, brightness, temperature { return .cw }
        if on, brightness { return .c }
        if on { return .normal }
        return .unknown
    }

    /// The generic light on a Lightbulb draft (the accessory's own when nil, or a new one named "<name> Light").
    @discardableResult
    func light(
        _ given: TuyaServiceDraft? = nil, on: TuyaSchemaItem?, brightness: TuyaSchemaItem? = nil, temperature: TuyaSchemaItem? = nil,
        colour: TuyaSchemaItem? = nil, mode: TuyaSchemaItem? = nil, colourDefaults: Bool = false
    ) -> TuyaLightType {
        let draft = given ?? drafts.first { $0.type.uuid == ServiceType.lightbulb.uuid } ?? service(.lightbulb, name: "\(device.name) Light")
        let hsvItems: (h: TuyaSchemaItem, s: TuyaSchemaItem, v: TuyaSchemaItem)? = {
            guard let colour else { return nil }
            if let h = colour.component("h"), let s = colour.component("s"), let v = colour.component("v") { return (h, s, v) }
            guard colourDefaults else { return nil }
            func item(_ key: String, _ max: Double) -> TuyaSchemaItem {
                TuyaSchemaItem(code: "\(colour.code).\(key)", mode: colour.mode, type: "Integer", property: .object(["min": 0, "max": .number(max), "scale": 0, "step": 1]))
            }
            return (item("h", 360), item("s", 1000), item("v", 1000))
        }()
        let type = Self.lightType(on: on != nil, brightness: brightness != nil, temperature: temperature != nil, hsv: hsvItems != nil, modes: mode?.range ?? [])
        logger.info("\(device.name) is a light of type \(type.rawValue)")
        guard let on else { return type }
        guard type != .normal else {
            self.on(draft, on)
            return type
        }
        let device = device, link = link
        let modeCode = mode?.code
        @Sendable func isWhite() -> Bool {
            switch type {
            case .c, .cw: true
            case .rgbc, .rgbcw: modeCode.flatMap { device.string(device.find($0)) } == "white"
            default: false
            }
        }
        @Sendable func isColour() -> Bool {
            switch type {
            case .rgb: true
            case .rgbc, .rgbcw: modeCode.flatMap { device.string(device.find($0)) } == "colour"
            default: false
            }
        }
        let colourCode = colour?.code
        @Sendable func hsv() -> TuyaHSV { TuyaHSV(colourCode.flatMap { device.status($0) }) }

        // On: a light turned on gets its brightness again in the same command.
        draft.add(.on, onlineCheck: true, get: { device.bool(on).map(HAPValue.bool) }) { value in
            let isOn = value.boolValue ?? false
            var commands = [TuyaCommand(code: on.code, value: .bool(isOn))]
            if isOn, let brightness, let current = device.status(brightness.code) { commands.append(TuyaCommand(code: brightness.code, value: current)) }
            try await link.send(commands, debounced: true)
        }

        // Brightness: the colour's v in colour mode, the brightness DP in white mode, 100 otherwise.
        if brightness != nil || hsvItems != nil {
            let logger = logger
            draft.add(.brightness, get: {
                if isColour(), let v = hsvItems?.v {
                    return Self.int(Self.clamp((100 * hsv().v / v.max).rounded(), 0, 100))
                }
                if isWhite(), let brightness {
                    guard let raw = device.number(brightness) else { return nil }
                    return Self.int(Self.clamp((100 * raw / brightness.max).rounded(), 0, 100))
                }
                return .int(100)
            }) { value in
                let percent = value.doubleValue ?? 0
                if isColour(), let v = hsvItems?.v, let colourCode {
                    var colour = hsv()
                    colour.v = Self.clamp((percent * v.max / 100).rounded(), v.min, v.max)
                    try await link.send(colourCode, colour.json)
                } else if isWhite(), let brightness {
                    try await link.send(brightness.code, Self.json(Self.clamp((percent * brightness.max / 100).rounded(), brightness.min, brightness.max)))
                } else {
                    logger.warning("\(device.name) is in neither white nor colour mode: brightness not sent")
                }
            }
        }

        // Colour temperature: kelvin linear over the DP's range; RGBC lights show 6500 K and send only the mode.
        if [.cw, .rgbc, .rgbcw].contains(type) {
            let fixed = type == .rgbc
            let ctType = fixed ? CharacteristicType.colorTemperature.with(minValue: 154, maxValue: 154, minStep: 1)
                : CharacteristicType.colorTemperature.with(minValue: 140, maxValue: 500, minStep: 1)
            draft.add(ctType, get: {
                if fixed { return .int(154) }
                guard let temperature, let raw = device.number(temperature) else { return nil }
                return Self.mireds(raw: raw, item: temperature).map { .int($0) }
            }) { value in
                var commands: [TuyaCommand] = []
                if let modeCode { commands.append(TuyaCommand(code: modeCode, value: .string("white"))) }
                if !fixed, let temperature, let mireds = value.doubleValue, mireds > 0 {
                    let raw = Self.remap(1_000_000 / mireds, Self.warmestKelvin, Self.coolestKelvin, temperature.min, temperature.max)
                    commands.append(TuyaCommand(code: temperature.code, value: Self.json(Self.clamp(raw.rounded(), temperature.min, temperature.max))))
                }
                try await link.send(commands, debounced: true)
            }
            if let temperature, brightness != nil, type != .rgbc {
                if adaptiveLightingAllowed {
                    adaptiveLights.append(TuyaAdaptiveLight(
                        draft: draft, temperatureCode: temperature.code,
                        colourCodes: Set([colourCode, modeCode].compactMap { $0 }),
                        mireds: { device.number(temperature).flatMap { Self.mireds(raw: $0, item: temperature) } }, isColour: isColour))
                    logger.info("Adaptive Lighting enabled for \(device.name)")
                } else {
                    logger.info("Adaptive Lighting disabled for \(device.name) by its override")
                }
            }
        }

        // Hue and saturation: the colour's, scaled; in white mode those of 6500 K.
        if let hsvItems, let colourCode {
            for (characteristic, component, scale, white) in [(CharacteristicType.hue, "h", 360.0, 48), (.saturation, "s", 100.0, 2)] {
                let item = component == "h" ? hsvItems.h : hsvItems.s
                draft.add(characteristic, get: {
                    if isWhite() { return .double(Double(white)) }
                    let current = component == "h" ? hsv().h : hsv().s
                    return .double(Self.clamp((scale * current / item.max).rounded(), 0, scale))
                }) { value in
                    var colour = hsv()
                    let raw = Self.clamp(((value.doubleValue ?? 0) * item.max / scale).rounded(), item.min, item.max)
                    if component == "h" { colour.h = raw } else { colour.s = raw }
                    var commands = [TuyaCommand(code: colourCode, value: colour.json)]
                    if let modeCode { commands.append(TuyaCommand(code: modeCode, value: .string("colour"))) }
                    try await link.send(commands, debounced: true)
                }
            }
        }
        return type
    }

    /// A temperature DP's value in mireds, 140 to 500.
    static func mireds(raw: Double, item: TuyaSchemaItem) -> Int? {
        let kelvin = remap(raw, item.min, item.max, warmestKelvin, coolestKelvin)
        guard kelvin > 0, kelvin.isFinite else { return nil }
        return Int(clamp((1_000_000 / kelvin).rounded(), 140, 500))
    }
}
