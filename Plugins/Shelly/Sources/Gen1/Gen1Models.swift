import Foundation
import HomeswiftAI

/// A CoIoT property of a Gen 1 model: its name, the ids it has in CoIoT v1 and v2, how its value reads, and the device
/// mode it belongs to (`relay`/`roller`, `color`/`white`), nil for every mode.
struct Gen1Property: Sendable {
    enum Kind: Sendable { case bool, number, string }

    var name: String
    var ids: [Int]
    var kind: Kind
    var mode: String?
    /// The value of a device not heard yet: false, 0, or the property's own.
    var initial: JSONValue

    /// A value from a status tuple, coerced as the Homebridge plugin's library does.
    func coerce(_ value: JSONValue) -> JSONValue {
        switch kind {
        case .bool: .bool(value.isTruthy)
        case .number: value.number.map(JSONValue.number) ?? .null
        case .string: value.stringValue.map(JSONValue.string) ?? value.decimalText.map(JSONValue.string) ?? .string("")
        }
    }
}

/// A Gen 1 model: its id (the CoIoT type), the name its accessories' ids start with, its properties and what it is.
struct Gen1Model: Sendable {
    enum Family: Sendable, Equatable {
        /// Relays, each a switch (or another type), metered by the first `meters` power properties.
        case relays(Int, meters: Int)
        /// Shelly 2 and 2.5: relays in relay mode, one roller in roller mode.
        case relaysOrRoller(meters: Int)
        /// Dimmers: one white light.
        case whiteLight
        /// The Duo: one light with a colour temperature.
        case colorTemperatureLight
        /// Bulbs: one colour light.
        case colorLight
        /// The RGBW2: one colour light in colour mode, four white lights in white mode.
        case colorOrWhiteLights
        /// Button1 (one) and i3 (three).
        case buttons(Int)
        case sensor
    }

    var id: String
    var name: String
    var family: Family
    var properties: [Gen1Property]
    /// The mode a device starts in, for models that have modes.
    var defaultMode: String?

    func properties(mode: String?) -> [Int: Gen1Property] {
        var byID: [Int: Gen1Property] = [:]
        for property in properties where property.mode == nil || property.mode == mode {
            for id in property.ids { byID[id] = property }
        }
        return byID
    }

    /// Every property's starting value in a mode.
    func initialValues(mode: String?) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for property in properties where values[property.name] == nil { values[property.name] = property.initial }
        if let mode { values["mode"] = .string(mode) }
        return values
    }

    var hasModes: Bool { defaultMode != nil && properties.contains { $0.name == "mode" } }
}

enum Gen1Models {
    private static func b(_ name: String, _ ids: Int..., mode: String? = nil) -> Gen1Property {
        Gen1Property(name: name, ids: ids, kind: .bool, mode: mode, initial: false)
    }
    private static func n(_ name: String, _ ids: Int..., mode: String? = nil, initial: JSONValue = 0) -> Gen1Property {
        Gen1Property(name: name, ids: ids, kind: .number, mode: mode, initial: initial)
    }
    private static func s(_ name: String, _ ids: Int..., mode: String? = nil, initial: String = "") -> Gen1Property {
        Gen1Property(name: name, ids: ids, kind: .string, mode: mode, initial: .string(initial))
    }

    /// Shelly 1's: the relay, its input and the add-on's sensors.
    private static let shelly1: [Gen1Property] = [
        b("relay0", 112, 1101), n("input0", 118, 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103),
        n("externalTemperature0", 119, 3101, initial: .null), n("externalTemperature1", 3201, initial: .null),
        n("externalTemperature2", 3301, initial: .null), n("externalHumidity", 3103, initial: .null), n("externalInput0", 3117),
    ]

    private static let shelly2: [Gen1Property] = [
        b("relay0", 112, 1101), b("relay1", 122, 1201), n("input0", 118, 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103),
        n("input1", 128, 2201), s("inputEvent1", 2202), n("inputEventCounter1", 2203), n("power0", 111, 4101, 4102),
        n("energyCounter0", 4103, 4104), s("mode", 9101, initial: "relay"),
        b("overPower0", 6102, mode: "relay"), b("overPower1", 6202, mode: "relay"), n("overPowerValue", 6109, mode: "relay"),
        s("rollerState", 1102, mode: "roller", initial: "stop"), n("rollerPosition", 113, 1103, mode: "roller"),
        s("rollerStopReason", 6103, mode: "roller"),
    ]

    private static let plug: [Gen1Property] = [
        b("relay0", 112, 1101), n("power0", 111, 4101), n("energyCounter0", 4103), b("overPower", 6102), n("overPowerValue", 6109),
    ]

    private static let bulb: [Gen1Property] = [
        b("switch", 181, 1101), n("red", 111, 5105), n("green", 121, 5106), n("blue", 131, 5107), n("white", 141, 5108),
        n("gain", 151, 5102), n("brightness", 171, 5101), n("colorTemperature", 161, 5103), s("mode", 9101, initial: "color"),
    ]

    private static let dimmer: [Gen1Property] = [
        b("switch", 121, 1101), n("brightness", 111, 5101), n("input0", 131, 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103),
        n("input1", 141, 2201), s("inputEvent1", 2202), n("inputEventCounter1", 2203), n("power0", 4101), n("energyCounter0", 4103),
        b("overPower", 6102), b("loadError", 6104), n("deviceTemperature", 3104), b("overTemperature", 6101), s("mode", 9101, initial: "white"),
    ]

    private static let doorWindow: [Gen1Property] = [
        n("state", 55, 3108), n("tilt", 3109), n("vibration", 6110), n("illuminance", 66, 3106), s("illuminanceLevel", 3110, initial: "unknown"),
        b("sensorError", 3115), n("battery", 77, 3111), s("wakeUpEvent", 9102, initial: "unknown"),
    ]

    private static func em3() -> [Gen1Property] {
        var properties: [Gen1Property] = [b("relay0", 112, 1101), b("overPower", 6102)]
        for phase in 0..<3 {
            let p = 111 + 10 * phase, q = 4105 + 100 * phase
            properties += [
                n("power\(phase)", p, q), n("energyCounter\(phase)", q + 1), n("energyReturned\(phase)", q + 2), n("voltage\(phase)", p + 5, q + 3),
                n("current\(phase)", p + 4, q + 4), n("powerFactor\(phase)", p + 3, q + 5),
            ]
        }
        return properties
    }

    static let all: [String: Gen1Model] = {
        var models: [String: Gen1Model] = [:]
        func add(_ id: String, _ name: String, _ family: Gen1Model.Family, _ properties: [Gen1Property], mode: String? = nil) {
            models[id] = Gen1Model(id: id, name: name, family: family, properties: properties, defaultMode: mode)
        }
        let temperature = [n("deviceTemperature", 113, 3104), b("overTemperature", 115, 6101)]
        add("SHSW-1", "Shelly 1", .relays(1, meters: 0), shelly1)
        add("SHSW-PM", "Shelly 1PM", .relays(1, meters: 1), shelly1 + [
            n("power0", 111, 4101), n("energyCounter0", 4103), b("overPower", 6102), n("overPowerValue", 6109),
        ] + temperature)
        add("SHSW-L", "Shelly 1L", .relays(1, meters: 1), shelly1 + [
            n("input1", 2201), s("inputEvent1", 2202), n("inputEventCounter1", 2203), n("power0", 4101), n("energyCounter0", 4103),
            n("deviceTemperature", 3104), b("overTemperature", 6101),
        ])
        add("SHSW-21", "Shelly 2", .relaysOrRoller(meters: 1), shelly2, mode: "relay")
        add("SHSW-25", "Shelly 2.5", .relaysOrRoller(meters: 2), shelly2 + [
            n("power1", 121, 4201, mode: "relay"), n("energyCounter1", 4203, mode: "relay"), n("deviceTemperature", 115, 3104),
            b("overTemperature", 117, 6101),
        ], mode: "relay")
        add("SHSW-44", "Shelly 4Pro", .relays(4, meters: 4), [
            n("power0", 111), b("relay0", 112), n("power1", 121), b("relay1", 122), n("power2", 131), b("relay2", 132), n("power3", 141), b("relay3", 142),
        ])
        add("SHSW-22", "Shelly HD", .relays(2, meters: 2), [n("power0", 111), b("relay0", 112), n("power1", 121), b("relay1", 122)])
        add("SHUNI-1", "Shelly Uni", .relays(2, meters: 0), [
            b("relay0", 1101), b("relay1", 1201), n("input0", 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103), n("input1", 2201),
            s("inputEvent1", 2202), n("inputEventCounter1", 2203), n("externalTemperature0", 3101, initial: .null),
            n("externalTemperature1", 3201, initial: .null), n("externalTemperature2", 3301, initial: .null),
            n("externalTemperature3", 3401, initial: .null), n("externalTemperature4", 3501, initial: .null), n("voltage0", 3118),
            n("externalHumidity", 3103, initial: .null),
        ])
        add("SHPLG-1", "Shelly Plug", .relays(1, meters: 1), plug)
        add("SHPLG2-1", "Shelly Plug", .relays(1, meters: 1), plug)
        add("SHPLG-U1", "Shelly Plug US", .relays(1, meters: 1), plug)
        add("SHPLG-S", "Shelly Plug S", .relays(1, meters: 1), plug + temperature)
        add("SHAIR-1", "Shelly Air", .relays(1, meters: 1), [
            b("relay0", 112, 1101), n("totalWorkTime", 121, 1104), n("input0", 118, 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103),
            n("power0", 111, 4101), n("energyCounter0", 211, 4103), b("overPower", 6102), n("overPowerValue", 6109),
            n("externalTemperature0", 119, 3101, initial: .null), n("externalTemperature1", 3201, initial: .null),
            n("externalTemperature2", 3301, initial: .null), n("externalHumidity", 3103, initial: .null),
        ] + temperature)
        add("SHEM", "Shelly EM", .relays(1, meters: 1), [
            b("relay0", 112, 1101), n("power0", 111, 4105), n("energyCounter0", 4106), n("energyReturned0", 4107), n("voltage0", 116, 4108),
            n("power1", 121, 4205), n("energyCounter1", 4206), n("energyReturned1", 4207), n("voltage1", 126, 4208), b("overPower", 6102),
        ])
        add("SHEM-3", "Shelly 3EM", .relays(1, meters: 1), em3())
        add("SHBLB-1", "Shelly Bulb", .colorLight, bulb)
        add("SHCB-1", "Shelly Bulb RGBW", .colorLight, bulb)
        add("SHRGBW2", "Shelly RGBW2", .colorOrWhiteLights, [
            b("switch", 161, 1101, mode: "color"), n("red", 111, 5105, mode: "color"), n("green", 121, 5106, mode: "color"),
            n("blue", 131, 5107, mode: "color"), n("white", 141, 5108, mode: "color"), n("gain", 151, 5102, mode: "color"),
            b("switch0", 151, 1101, mode: "white"), n("brightness0", 111, 5101, mode: "white"), b("switch1", 161, 1201, mode: "white"),
            n("brightness1", 121, 5201, mode: "white"), b("switch2", 171, 1301, mode: "white"), n("brightness2", 131, 5301, mode: "white"),
            b("switch3", 181, 1401, mode: "white"), n("brightness3", 141, 5401, mode: "white"), n("power0", 4101), n("energyCounter0", 4103),
            n("power1", 4201, mode: "white"), n("power2", 4301, mode: "white"), n("power3", 4401, mode: "white"),
            n("energyCounter1", 4203, mode: "white"), n("energyCounter2", 4303, mode: "white"), n("energyCounter3", 4403, mode: "white"),
            b("overPower", 6102), n("input0", 118, 2101), s("inputEvent0", 2102), n("inputEventCounter0", 2103), s("mode", 9101, initial: "color"),
        ], mode: "color")
        add("SHBDUO-1", "Shelly Duo", .colorTemperatureLight, [
            b("switch", 121, 1101), n("brightness", 111, 5101), n("colorTemperature", 131, 5103), n("whiteLevel", 5104), n("power0", 141, 4101),
            n("energyCounter0", 211, 4103),
        ])
        add("SHVIN-1", "Shelly Vintage", .whiteLight, [
            b("switch", 121, 1101), n("brightness", 111, 5101), n("power0", 141, 4101), n("energyCounter0", 211, 4103),
        ])
        add("SHDM-1", "Shelly Dimmer", .whiteLight, dimmer)
        add("SHDM-2", "Shelly Dimmer 2", .whiteLight, dimmer)
        let button: [Gen1Property] = [
            n("input0", 118), s("inputEvent0", 119, 2102), n("inputEventCounter0", 120, 2103), b("sensorError", 3115), b("charging", 3112),
            n("battery", 77, 3111), s("wakeUpEvent", 9102, initial: "unknown"),
        ]
        add("SHBTN-1", "Shelly Button1", .buttons(1), button)
        add("SHBTN-2", "Shelly Button1", .buttons(1), button)
        var i3: [Gen1Property] = []
        for k in 0..<3 {
            i3 += [n("input\(k)", 118 + 10 * k, 2101 + 100 * k), s("inputEvent\(k)", 119 + 10 * k, 2102 + 100 * k),
                   n("inputEventCounter\(k)", 120 + 10 * k, 2103 + 100 * k)]
        }
        add("SHIX3-1", "Shelly i3", .buttons(3), i3)
        add("SHDW-1", "Shelly Door/Window", .sensor, doorWindow)
        add("SHDW-2", "Shelly Door/Window 2", .sensor, doorWindow + [n("temperature", 3101)])
        add("SHWT-1", "Shelly Flood", .sensor, [
            n("temperature", 33, 3101), b("flood", 23, 6106), b("sensorError", 3115), n("battery", 3111), s("wakeUpEvent", 9102, initial: "unknown"),
        ])
        add("SHHT-1", "Shelly H&T", .sensor, [
            n("temperature", 33, 3101), n("humidity", 44, 3103), b("sensorError", 3115), n("battery", 77, 3111), s("wakeUpEvent", 9102, initial: "unknown"),
        ])
        add("SHGS-1", "Shelly Gas", .sensor, [
            s("sensorOperation", 118, 3113), s("selfTest", 120, 3114), s("gas", 119, 6108, initial: "unknown"), n("concentration", 122, 3107),
            s("valve", 1105),
        ])
        add("SHSEN-1", "Shelly Sense", .sensor, [
            n("temperature", 33, 3101), n("humidity", 44, 3103), b("motion", 11, 6107), n("illuminance", 66, 3106), b("charging", 22, 3112),
            n("battery", 77, 3111),
        ])
        add("SHMOS-01", "Shelly Motion", .sensor, [b("motion", 6107), b("vibration", 6110), n("illuminance", 3106), n("battery", 3111)])
        return models
    }()

    /// Models the library knows that get no accessories.
    static let unsupportedNames: [String: String] = [
        "SHCL-255": "Shelly Color", "SHRGBWW-01": "Shelly RGBW", "SHDIMW-1": "Shelly Dimmer W1", "SH2LED-1": "Shelly 2LED",
        "SHSM-01": "Shelly Smoke", "SHSM-02": "Shelly Smoke 2", "SHMOS-02": "Shelly Motion 2", "SHTRV-01": "Shelly TRV",
    ]
}
