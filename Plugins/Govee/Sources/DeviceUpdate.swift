import Foundation
import HomeswiftPlugin

/// A device's status as the handlers take it, whatever transport it came over (`ExternalUpdateParams`).
struct DeviceUpdate: Sendable, Equatable {
    enum Source: String, Sendable { case aws = "AWS", ble = "BLE", lan = "LAN", http = "HTTP" }

    var source: Source?
    var online: Bool?
    /// `on` or `off`.
    var state: String?
    /// Percent.
    var brightness: Int?
    var rgb: RGB?
    var kelvin: Int?
    /// Sensor readings in hundredths (thermo-hygrometers), or as the device reports them.
    var temperature: Double?
    var humidity: Double?
    var setTemperature: Double?
    var pm25: Double?
    var battery: Double?
    var leakDetected: Bool?
    /// Opcode status frames, base64.
    var commands: [String]?
    /// A multi-outlet state bitmask.
    var stateDual: Int?
    var scene: String?

    /// Whether anything besides the source is set: an update with nothing else is not forwarded.
    var hasValues: Bool {
        online != nil || state != nil || brightness != nil || rgb != nil || kelvin != nil || temperature != nil || humidity != nil
            || setTemperature != nil || pm25 != nil || battery != nil || leakDetected != nil || commands != nil || stateDual != nil || scene != nil
    }

    /// The fields that are set, for a log line or the web page.
    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let source { object["source"] = .string(source.rawValue) }
        if let online { object["online"] = .bool(online) }
        if let state { object["state"] = .string(state) }
        if let brightness { object["brightness"] = .number(Double(brightness)) }
        if let rgb { object["rgb"] = TransportCommands.json(rgb) }
        if let kelvin { object["kelvin"] = .number(Double(kelvin)) }
        if let temperature { object["temperature"] = .number(temperature) }
        if let humidity { object["humidity"] = .number(humidity) }
        if let setTemperature { object["setTemperature"] = .number(setTemperature) }
        if let pm25 { object["pm25"] = .number(pm25) }
        if let battery { object["battery"] = .number(battery) }
        if let leakDetected { object["leakDetected"] = .bool(leakDetected) }
        if let commands { object["commands"] = .array(commands.map(JSONValue.string)) }
        if let stateDual { object["stateDual"] = .number(Double(stateDual)) }
        if let scene { object["scene"] = .string(scene) }
        return .object(object)
    }

    /// `normaliseDeviceUpdate`: flattens a raw status from AWS, LAN, BLE or HTTP. AWS and LAN report most
    /// values inside `state` (which wins over top-level keys), AWS reports opcode frames in `op.command`.
    init(raw params: JSONValue, source: Source?, model: String = "") {
        self.source = source
        var src = params.objectValue ?? [:]
        if let nested = params["state"]?.objectValue {
            for (key, value) in nested { src[key] = value }
        }

        if let onOff = src["onOff"] {
            state = Self.onOff(onOff)
        } else if let text = src["state"]?.stringValue, text == "on" || text == "off" {
            state = text
        }

        // Brightness is a percentage, except for models that report on a 0-254 scale.
        if let raw = src["brightness"]?.doubleValue, raw.isFinite {
            let scaled = GoveeConstants.apiBrightnessScale.contains(model.uppercased()) || raw > 100 ? Govee.round(raw / 2.54) : raw
            brightness = Int(min(max(scaled, 0), 100))
        }

        // A colour temperature of 0 means the light is in colour mode.
        if let kelvin = (src["colorTemInKelvin"] ?? src["kelvin"])?.doubleValue, kelvin.isFinite, kelvin > 0 {
            self.kelvin = Int(kelvin)
        }
        if let colour = src["color"] ?? src["rgb"], let r = colour["r"]?.doubleValue, let g = colour["g"]?.doubleValue, let b = colour["b"]?.doubleValue {
            rgb = RGB(Int(r), Int(g), Int(b))
        }

        let opCommand = src["op"]?["command"]
        if let list = (opCommand?.arrayValue != nil ? opCommand : src["commands"])?.arrayValue {
            let strings = list.compactMap(\.stringValue)
            if strings.count == list.count { commands = strings }
        }

        let dual = src["sta"]?.objectValue != nil ? src["sta"]?["stateCode"] : src["stateDual"]
        if let dual = dual?.doubleValue, dual.isFinite { stateDual = Int(dual) }

        if let battery = src["battery"]?.doubleValue, battery.isFinite { self.battery = min(max(battery, 0), 100) }
        if let value = src["temperature"]?.doubleValue, value.isFinite { temperature = value }
        if let value = src["humidity"]?.doubleValue, value.isFinite { humidity = value }
        if let value = src["setTemperature"]?.doubleValue, value.isFinite { setTemperature = value }
        if let value = src["pm25"]?.doubleValue, value.isFinite { pm25 = value }
        if let value = src["leakDetected"]?.boolValue { leakDetected = value }
        if let value = src["online"]?.boolValue { online = value }
        if let scene = src["scene"] {
            if let text = scene.stringValue { self.scene = text } else if let number = scene.doubleValue, number.isFinite { self.scene = Self.format(number) }
        }
    }

    init(source: Source?) { self.source = source }

    /// `onOff` 1 or 17 (the channel-1 code), or true, is on; anything else off.
    static func onOff(_ value: JSONValue) -> String {
        if let bool = value.boolValue { return bool ? "on" : "off" }
        let number = value.doubleValue ?? value.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return number == 1 || number == 17 ? "on" : "off"
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
