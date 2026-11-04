import Foundation
import HomeswiftPlugin

/// What `system.get_sysinfo` says of a plug, a strip or a bulb: the fields the accessories show, nothing else
/// (docs/clean-room/TPLinkSmarthome.md, sections 4.1 and 9.3).
struct KasaSysinfo: Sendable, Equatable {
    enum Kind: String, Sendable { case plug, bulb }

    struct Child: Sendable, Equatable {
        /// The full id (`deviceId` and two digits), whatever the firmware reported.
        var id: String
        var alias: String
        var state: Int
    }

    var kind: Kind
    var alias: String
    var deviceID: String
    var model: String
    var softwareVersion: String
    var hardwareVersion: String
    /// As reported (`mac`, `mic_mac` or `ethernet_mac`): with colons on plugs, without on bulbs.
    var mac: String
    var feature: String = ""
    var relayState: Int?
    /// Dimmers (HS220) only.
    var brightness: Int?
    var ledOff: Int?
    var children: [Child]?
    var lightState: KasaLightState?
    var isDimmable = false
    var isColor = false
    var isVariableColorTemperature = false
    /// A light strip's (KL400, KL430): its commands go to another module.
    var length: Int?

    var supportsEnergy: Bool { kind == .bulb || feature.contains("ENE") }
    var isDimmerPlug: Bool { kind == .plug && brightness != nil }
    var isLightStrip: Bool { (length ?? 0) > 0 }

    /// The sysinfo of a reply, or nil for one that is neither a plug's nor a bulb's (section 4.1).
    init?(_ json: JSONValue) {
        guard json.objectValue != nil,
              let alias = json["alias"]?.stringValue, let deviceID = json["deviceId"]?.stringValue,
              let model = json["model"]?.stringValue, let software = json["sw_ver"]?.stringValue, let hardware = json["hw_ver"]?.stringValue
        else { return nil }
        let type = json["type"]?.stringValue ?? json["mic_type"]?.stringValue ?? ""
        let mac = json["mac"]?.stringValue ?? json["mic_mac"]?.stringValue ?? json["ethernet_mac"]?.stringValue ?? ""
        self.alias = alias
        self.deviceID = deviceID
        self.model = model
        self.softwareVersion = software
        self.hardwareVersion = hardware
        self.mac = mac
        let lowered = type.lowercased()
        if lowered.contains("plug") {
            guard !type.isEmpty, json["mac"] != nil || json["ethernet_mac"] != nil, let feature = json["feature"]?.stringValue,
                  json["relay_state"] != nil || json["children"] != nil
            else { return nil }
            // `children: null` is a reply to discard.
            if let children = json["children"], children.arrayValue == nil { return nil }
            kind = .plug
            self.feature = feature
            relayState = json["relay_state"]?.intValue
            brightness = json["brightness"]?.intValue
            ledOff = json["led_off"]?.intValue
            if let list = json["children"]?.arrayValue, !list.isEmpty {
                children = list.compactMap { child in
                    guard let id = child["id"]?.stringValue, !id.isEmpty else { return nil }
                    return Child(id: Self.childID(id, deviceID: deviceID), alias: child["alias"]?.stringValue ?? id, state: child["state"]?.intValue ?? 0)
                }
            }
        } else if lowered.contains("bulb") {
            guard json["mic_type"] != nil, json["mic_mac"] != nil, json["description"] != nil, let light = json["light_state"],
                  json["is_dimmable"] != nil, json["is_color"] != nil, json["is_variable_color_temp"] != nil
            else { return nil }
            kind = .bulb
            lightState = KasaLightState(light)
            isDimmable = json["is_dimmable"]?.intValue == 1
            isColor = json["is_color"]?.intValue == 1
            isVariableColorTemperature = json["is_variable_color_temp"]?.intValue == 1
            length = json["length"]?.intValue
        } else {
            return nil
        }
    }

    /// A strip's outlet id: the device id and two digits, built when the firmware gave only the digits (section 4.2).
    static func childID(_ id: String, deviceID: String) -> String {
        switch id.count {
        case 2: deviceID + id
        case 1: deviceID + "0" + id
        default: id
        }
    }

    /// The sysinfo of a datagram (`{"system":{"get_sysinfo":{…}}}`, encrypted), or nil for anything else.
    static func discoveryReply(_ data: Data) -> KasaSysinfo? {
        let text = String(decoding: KasaCipher.decrypt(data), as: UTF8.self)
        guard let json = try? JSONValue(string: text), let sysinfo = json["system"]?["get_sysinfo"] else { return nil }
        return KasaSysinfo(sysinfo)
    }
}

/// A bulb's light: what it shows, or with `on_off: 0`, `dft_on_state` (what it comes back on with).
struct KasaLightState: Sendable, Equatable {
    var onOff: Int?
    var mode: String?
    var hue: Int?
    var saturation: Int?
    /// Kelvin; 0 is a colour.
    var colorTemperature: Int?
    var brightness: Int?
    var transitionPeriod: Int?
    var defaultOn: Defaults?

    struct Defaults: Sendable, Equatable {
        var mode: String?
        var hue: Int?
        var saturation: Int?
        var colorTemperature: Int?
        var brightness: Int?
    }

    init(onOff: Int? = nil, mode: String? = nil, hue: Int? = nil, saturation: Int? = nil, colorTemperature: Int? = nil, brightness: Int? = nil) {
        self.onOff = onOff
        self.mode = mode
        self.hue = hue
        self.saturation = saturation
        self.colorTemperature = colorTemperature
        self.brightness = brightness
    }

    init(_ json: JSONValue) {
        onOff = json["on_off"]?.intValue
        mode = json["mode"]?.stringValue
        hue = json["hue"]?.intValue
        saturation = json["saturation"]?.intValue
        colorTemperature = json["color_temp"]?.intValue
        brightness = json["brightness"]?.intValue
        transitionPeriod = json["transition_period"]?.intValue
        if let defaults = json["dft_on_state"], defaults.objectValue != nil {
            defaultOn = Defaults(
                mode: defaults["mode"]?.stringValue, hue: defaults["hue"]?.intValue, saturation: defaults["saturation"]?.intValue,
                colorTemperature: defaults["color_temp"]?.intValue, brightness: defaults["brightness"]?.intValue)
        }
    }

    /// A set command's reply merged onto what was known: the keys it carries win (section 4.7).
    func merging(_ reply: KasaLightState) -> KasaLightState {
        var merged = self
        if let value = reply.onOff { merged.onOff = value }
        if let value = reply.mode { merged.mode = value }
        if let value = reply.hue { merged.hue = value }
        if let value = reply.saturation { merged.saturation = value }
        if let value = reply.colorTemperature { merged.colorTemperature = value }
        if let value = reply.brightness { merged.brightness = value }
        if let value = reply.defaultOn { merged.defaultOn = value }
        return merged
    }
}

/// An energy reading in SI units, from either firmware's fields (section 5.7).
struct KasaEnergyReading: Sendable, Equatable {
    var volts: Double?
    var amperes: Double?
    var watts: Double?
    var kilowattHours: Double?

    var voltAmperes: Double? {
        guard let volts, let amperes else { return nil }
        return volts * amperes
    }

    init(volts: Double? = nil, amperes: Double? = nil, watts: Double? = nil, kilowattHours: Double? = nil) {
        self.volts = volts
        self.amperes = amperes
        self.watts = watts
        self.kilowattHours = kilowattHours
    }

    /// `current`, `voltage`, `power`, `total` (V1), else `current_ma`, `voltage_mv`, `power_mw`, `total_wh` (V2) / 1000.
    init(_ json: JSONValue) {
        func value(_ v1: String, _ v2: String) -> Double? {
            json[v1]?.doubleValue ?? json[v2]?.doubleValue.map { $0 / 1000 }
        }
        volts = value("voltage", "voltage_mv")
        amperes = value("current", "current_ma")
        watts = value("power", "power_mw")
        kilowattHours = value("total", "total_wh")
    }
}
