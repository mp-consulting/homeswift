import Foundation
import HomeswiftPlugin

/// What a device reports, as the plugin keeps it; `MessageCodec.apply(_:to:)` merges each message in. Readings
/// stay in the device's units: temperatures in Kelvin × 10, humidity in percent, PM in µg/m³ (an index on Link
/// models), VOC and NO2 as an index × 10.
struct DeviceState: Sendable, Equatable {
    var connected = false
    var isOn = false
    /// 1-10, -1 in auto mode on models that report `AUTO`, 0 when unknown.
    var fanSpeed = 0
    var oscillation = false
    var autoMode = false
    var nightMode = false
    var oscillationAngleStart: Int?
    var oscillationAngleEnd: Int?
    /// Sensors stay on while the fan is off (`rhtm`).
    var continuousMonitoring: Bool?
    /// Jet focus (`ffoc`).
    var frontAirflow: Bool?
    var temperature: Int?
    var humidity: Int?
    /// The temperature or humidity sensor reports `OFF` (continuous monitoring off and the fan idle): the last
    /// reading is kept, but it is not current.
    var temperatureOff = false
    var humidityOff = false
    var pm25: Int?
    var pm10: Int?
    var vocIndex: Int?
    var no2Index: Int?
    var formaldehydeLevel: Int?
    /// Minutes, 0 when off.
    var sleepTimer: Int?
    /// Percent.
    var hepaFilterLife: Int?
    var carbonFilterLife: Int?
    var heatingEnabled: Bool?
    var heatingActive: Bool?
    var targetTemperature: Int?
    var humidifierEnabled: Bool?
    var humidifierAuto: Bool?
    var targetHumidity: Int?
    var fanState: Bool?
    var airQualityTarget: Int?
    var errorCode: String?
    var warningCode: String?
    var tiltStatus: String?
}

/// The Dyson local protocol: decoding `CURRENT-STATE`, `STATE-CHANGE` and `ENVIRONMENTAL-CURRENT-SENSOR-DATA`,
/// encoding `STATE-SET` values, and the conversions between HomeKit's units and the device's.
enum MessageCodec {
    enum FanSpeed {
        static let min = 1, max = 10, `default` = 4, auto = -1
    }

    enum HeatingTemperature {
        static let minCelsius = 1.0, maxCelsius = 37.0
    }

    enum Humidity {
        static let minPercent = 0, maxPercent = 100, defaultMin = 30, defaultMax = 70
    }

    /// Link models report the HEPA filter's life in hours left out of this many.
    static let filterMaxHours = 4300.0
    static let kelvinOffset = 273.15

    static let on = "ON", off = "OFF", auto = "AUTO", fan = "FAN", heat = "HEAT"

    // MARK: Decoding

    /// A field's value: a string in `CURRENT-STATE`, `[old, new]` in `STATE-CHANGE` (the new one counts).
    static func value(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let string)?: string
        case .array(let pair)?: pair.count > 1 ? pair[1].stringValue : nil
        case .number(let number)?: number.rounded() == number ? String(Int(number)) : String(number)
        default: nil
        }
    }

    /// JavaScript's `parseInt(text, 10)`: leading blanks, a sign, then digits; nil without any digit.
    static func integer(_ text: String) -> Int? {
        var scalars = Substring(text).drop { $0 == " " || $0 == "\t" }
        var sign = 1
        if let first = scalars.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            scalars = scalars.dropFirst()
        }
        let digits = scalars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
        return sign * magnitude
    }

    /// A reading, unless the sensor is warming up (`INIT`) or off.
    private static func reading(_ raw: JSONValue?) -> Int? {
        guard let text = value(raw), text != "INIT", text != off else { return nil }
        return integer(text)
    }

    /// The fields of a `CURRENT-STATE` or `STATE-CHANGE`: `product-state`, else `data`.
    static func stateFields(_ message: [String: JSONValue]) -> [String: JSONValue]? {
        message["product-state"]?.objectValue ?? message["data"]?.objectValue
    }

    /// The power a state message reports: `fmod` (`OFF`, or `AUTO`/`FAN` for on) wins over `fpwr`.
    static func reportedPower(_ raw: [String: JSONValue]) -> Bool? {
        switch value(raw["fmod"]) {
        case off?: false
        case auto?, fan?: true
        default: value(raw["fpwr"]).map { $0 == on }
        }
    }

    /// Merges a state message's fields into `state`.
    static func parseState(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let isOn = reportedPower(raw) { state.isOn = isOn }
        if let fnsp = value(raw["fnsp"]) { state.fanSpeed = decodeFanSpeed(fnsp).speed }
        switch value(raw["fmod"]) {
        case off?, fan?: state.autoMode = false
        case auto?: state.autoMode = true
        default: break
        }
        // Some models send `auto` next to (or instead of) `fmod`.
        if let auto = value(raw["auto"]) { state.autoMode = auto == on }
        if let oson = value(raw["oson"]) { state.oscillation = oson == on }
        if let oscs = value(raw["oscs"]), let angle = integer(oscs) { state.oscillationAngleStart = angle }
        if let osce = value(raw["osce"]), let angle = integer(osce) { state.oscillationAngleEnd = angle }
        if let nmod = value(raw["nmod"]) { state.nightMode = nmod == on }
        if let rhtm = value(raw["rhtm"]) { state.continuousMonitoring = rhtm == on }
        if let ffoc = value(raw["ffoc"]) { state.frontAirflow = ffoc == on }
        parseEnvironment(raw, into: &state)
        parseFilters(raw, into: &state)
        parseHeating(raw, into: &state)
        parseHumidifier(raw, into: &state)
        parseLinkSeries(raw, into: &state)
    }

    /// Sensor readings, from a state message or `ENVIRONMENTAL-CURRENT-SENSOR-DATA`.
    static func parseEnvironment(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let tact = value(raw["tact"]) {
            if tact == off {
                state.temperatureOff = true
            } else if let kelvin = integer(tact) {
                state.temperature = kelvin
                state.temperatureOff = false
            }
        }
        if let hact = value(raw["hact"]) {
            if hact == off {
                state.humidityOff = true
            } else if let humidity = integer(hact) {
                state.humidity = humidity
                state.humidityOff = false
            }
        }
        // Newer models report PM2.5 as `p25r`; Link models a 0-9 index as `pact`, which never overrides a density.
        if let pm25 = reading(raw["p25r"]) ?? reading(raw["pact"]) { state.pm25 = pm25 }
        if let pm10 = reading(raw["p10r"]) { state.pm10 = pm10 }
        if let voc = reading(raw["va10"]) ?? reading(raw["vact"]) { state.vocIndex = voc }
        if let noxl = reading(raw["noxl"]) { state.no2Index = noxl }
        if let hchr = reading(raw["hchr"]) { state.formaldehydeLevel = hchr }
        if let sltm = value(raw["sltm"]) {
            if sltm == off { state.sleepTimer = 0 } else if let minutes = integer(sltm) { state.sleepTimer = minutes }
        }
    }

    /// Filter life as a percentage: Link models give the HEPA filter's hours left (`filf`), newer ones percentages.
    private static func parseFilters(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let filf = value(raw["filf"]), let hours = integer(filf) {
            state.hepaFilterLife = clampPercent(Double(hours) / filterMaxHours * 100)
        }
        if let fltf = value(raw["fltf"]), let percent = integer(fltf) { state.hepaFilterLife = clampPercent(Double(percent)) }
        if let cflr = value(raw["cflr"]), let percent = integer(cflr) { state.carbonFilterLife = clampPercent(Double(percent)) }
    }

    private static func parseHeating(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let hmod = value(raw["hmod"]) { state.heatingEnabled = hmod == heat }
        if let hmax = value(raw["hmax"]), let kelvin = integer(hmax) { state.targetTemperature = kelvin }
        if let hsta = value(raw["hsta"]) { state.heatingActive = hsta == on }
    }

    private static func parseHumidifier(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let hume = value(raw["hume"]) {
            state.humidifierEnabled = hume == on || hume == auto
            state.humidifierAuto = hume == auto
        }
        if let humt = value(raw["humt"]), let percent = integer(humt) { state.targetHumidity = percent }
    }

    private static func parseLinkSeries(_ raw: [String: JSONValue], into state: inout DeviceState) {
        if let fnst = value(raw["fnst"]) { state.fanState = fnst == on }
        if let qtar = value(raw["qtar"]), let target = integer(qtar) { state.airQualityTarget = target }
        if let ercd = value(raw["ercd"]) { state.errorCode = ercd }
        if let wacd = value(raw["wacd"]) { state.warningCode = wacd }
        if let tilt = value(raw["tilt"]) { state.tiltStatus = tilt }
    }

    /// Rounds JavaScript's way (half up) and clamps to 0...100.
    static func clampPercent(_ value: Double) -> Int {
        Swift.max(0, Swift.min(100, Int((value + 0.5).rounded(.down))))
    }

    /// Merges what a message reports into `state`. Returns false for messages that carry no state.
    @discardableResult
    static func apply(_ message: [String: JSONValue], to state: inout DeviceState) -> Bool {
        switch message["msg"]?.stringValue {
        case "CURRENT-STATE", "STATE-CHANGE":
            guard let fields = stateFields(message) else { return false }
            parseState(fields, into: &state)
            return true
        case "ENVIRONMENTAL-CURRENT-SENSOR-DATA":
            parseEnvironment(message["data"]?.objectValue ?? message, into: &state)
            return true
        default:
            return false
        }
    }

    // MARK: Encoding

    /// 1-10 as four digits (`0007`), clamped; `AUTO` for a negative speed.
    static func encodeFanSpeed(_ speed: Int) -> String {
        guard speed >= 0 else { return auto }
        return pad(Swift.max(FanSpeed.min, Swift.min(FanSpeed.max, speed)))
    }

    static func decodeFanSpeed(_ encoded: String) -> (speed: Int, autoMode: Bool) {
        if encoded == auto { return (FanSpeed.auto, true) }
        return (integer(encoded) ?? 0, false)
    }

    static func pad(_ value: Int) -> String {
        let digits = String(value)
        return digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// HomeKit's 0-100% to a speed of 1-10, rounding up (55% is 6).
    static func percentToSpeed(_ percent: Double) -> Int {
        guard percent > 0 else { return FanSpeed.min }
        return Swift.max(FanSpeed.min, Swift.min(FanSpeed.max, Int((percent / 10).rounded(.up))))
    }

    static func speedToPercent(_ speed: Int) -> Int {
        guard speed >= 0 else { return 0 }
        return Swift.max(0, Swift.min(100, speed * 10))
    }

    /// Celsius to Kelvin × 10, as `hmax` takes it (21 °C is `2941`).
    static func encodeTemperature(_ celsius: Double) -> String {
        String(Int(((celsius + kelvinOffset) * 10).rounded(.toNearestOrAwayFromZero)))
    }

    static func decodeTemperature(_ kelvinTimes10: Int) -> Double {
        Double(kelvinTimes10) / 10 - kelvinOffset
    }

    /// Kelvin × 10 to Celsius to 0.1°, or nil without a valid reading.
    static func decodeCelsius(_ kelvinTimes10: Int?) -> Double? {
        guard let kelvinTimes10, kelvinTimes10 > 0 else { return nil }
        return roundTenth(decodeTemperature(kelvinTimes10))
    }

    /// JavaScript's `Math.round(x * 10) / 10`.
    static func roundTenth(_ value: Double) -> Double {
        ((value * 10) + 0.5).rounded(.down) / 10
    }

    /// The JSON of a command: `STATE-SET` with the fields, or `REQUEST-CURRENT-STATE`.
    static func stateSet(_ fields: [String: String], time: Date = Date()) -> Data {
        var data: [String: JSONValue] = [:]
        for (key, value) in fields { data[key] = .string(value) }
        let message: JSONValue = ["msg": "STATE-SET", "time": .string(timestamp(time)), "mode-reason": "LAPP", "data": .object(data)]
        return encodeSorted(message)
    }

    static func requestCurrentState(time: Date = Date()) -> Data {
        encodeSorted(["msg": "REQUEST-CURRENT-STATE", "time": .string(timestamp(time))])
    }

    /// Asks for `ENVIRONMENTAL-CURRENT-SENSOR-DATA`, which Link models (an HP02 at least) never send on their own,
    /// even with continuous monitoring on. Newer models answer it too.
    static func requestEnvironment(time: Date = Date()) -> Data {
        encodeSorted(["msg": "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA", "time": .string(timestamp(time))])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func encodeSorted(_ value: JSONValue) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    /// ISO 8601 in UTC with milliseconds, as `new Date().toISOString()`.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    static func statusTopic(productType: String, serial: String) -> String { "\(productType)/\(serial)/status/current" }
    static func commandTopic(productType: String, serial: String) -> String { "\(productType)/\(serial)/command" }
}
