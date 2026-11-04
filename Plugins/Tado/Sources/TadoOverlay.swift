import Foundation
import HomeswiftPlugin

// What tado answers and what the plugin sends (docs/clean-room/Tado.md, sections 5 and 7.5): a zone's state read from
// `zoneStates`, the overlay bodies, the AC's fan levels. Pure functions, tested against the spec's vectors.

/// A zone's state in `zoneStates`, temperatures in °C (tado gives both units; HomeKit's are °C).
struct ZoneState: Sendable, Equatable {
    /// The `setting` object as tado gave it, copied into the overlays the plugin makes.
    var setting: JSONValue
    var settingType: String?
    var power: Bool
    var target: Double?
    var acMode: String?
    var fanLevel: String?
    /// No overlay: the schedule runs.
    var onSchedule: Bool
    var hasTermination: Bool
    var current: Double?
    var humidity: Double?
    var windowOpen: Bool

    init?(_ json: JSONValue) {
        guard let setting = json["setting"], setting.objectValue != nil else { return nil }
        self.setting = setting
        settingType = setting["type"]?.stringValue
        power = setting["power"]?.stringValue == "ON"
        target = setting["temperature"]?["celsius"]?.doubleValue?.finite
        acMode = setting["mode"]?.stringValue
        fanLevel = setting["fanLevel"]?.stringValue ?? setting["fanSpeed"]?.stringValue
        onSchedule = json["overlayType"]?.stringValue == nil
        hasTermination = json["overlay"]?["termination"]?.objectValue != nil
        current = json["sensorDataPoints"]?["insideTemperature"]?["celsius"]?.doubleValue?.finite
        humidity = json["sensorDataPoints"]?["humidity"]?["percentage"]?.doubleValue?.finite
        windowOpen = (json["openWindow"].map { !$0.isNull } ?? false) || json["openWindowDetected"]?.boolValue == true
    }

    /// `zoneStates`' answer by zone id.
    static func all(_ json: JSONValue) -> [Int: ZoneState] {
        var states: [Int: ZoneState] = [:]
        for (key, value) in json["zoneStates"]?.objectValue ?? [:] {
            if let id = Int(key), let state = ZoneState(value) { states[id] = state }
        }
        return states
    }
}

enum TadoOverlay {
    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// How an overlay of a zone of this mode ends (section 5.7): `forceManual` for CUSTOM's off.
    static func termination(mode: ZoneMode, modeTimer: Int, forceManual: Bool = false) -> JSONValue {
        if forceManual { return ["type": "MANUAL"] }
        switch mode {
        case .timer: return ["type": "TIMER", "durationInSeconds": .number(Double(modeTimer * 60))]
        case .auto: return ["type": "TADO_MODE"]
        case .manual, .custom: return ["type": "MANUAL"]
        }
    }

    /// A heating or hot water overlay: the current setting with its type, power and temperature replaced.
    static func zone(type: ZoneType, power: Bool, celsius: Double?, termination: JSONValue, current: JSONValue?) -> JSONValue {
        var setting = current?.objectValue ?? [:]
        setting["type"] = .string(type.rawValue)
        setting["power"] = power ? "ON" : "OFF"
        if power, let celsius, celsius != 0 {
            setting["temperature"] = ["celsius": .number(rounded(celsius))]
        } else {
            setting["temperature"] = .null
        }
        return ["setting": .object(setting), "termination": termination]
    }

    /// An air conditioner's overlay (section 5.8). `capabilities` is the zone's, by mode; `fanLevel` the level asked
    /// for (with `acFanSpeed`), `timer` the minutes of a TIMER zone.
    static func airConditioner(power: Bool, mode: String, celsius: Double?, fanLevel: String?, current: JSONValue?, capabilities: JSONValue?, timer: Int?) -> JSONValue {
        var termination: [String: JSONValue] = ["typeSkillBasedApp": "MANUAL"]
        if let timer { termination["durationInSeconds"] = .number(Double(timer * 60)) }
        var setting: [String: JSONValue] = ["type": "AIR_CONDITIONING", "power": power ? "ON" : "OFF"]
        guard power else {
            if let mode = current?["mode"]?.stringValue { setting["mode"] = .string(mode) }
            return ["setting": .object(setting), "termination": .object(termination)]
        }
        setting["mode"] = .string(mode)
        let modeCapabilities = capabilities?[mode]
        if modeCapabilities == nil || modeCapabilities?["temperatures"] != nil {
            if let celsius {
                setting["temperature"] = ["celsius": .number(rounded(celsius))]
            } else if let currentTemperature = current?["temperature"]?["celsius"]?.doubleValue {
                setting["temperature"] = ["celsius": .number(currentTemperature)]
            }
        }
        if let fan = fanLevels(modeCapabilities) {
            let supported = Set(fan.levels)
            let chosen = [fanLevel, current?[fan.key]?.stringValue].compactMap { $0 }.first(where: supported.contains)
                ?? ((mode == "FAN" || mode == "DRY") && supported.contains("AUTO") ? "AUTO" : fan.levels.first { $0 != "AUTO" } ?? fan.levels.first)
            if let chosen { setting[fan.key] = .string(chosen) }
        }
        for (key, list) in [("swing", "swings"), ("verticalSwing", "verticalSwing"), ("horizontalSwing", "horizontalSwing"), ("light", "light")] {
            if let value = current?[key]?.stringValue, (modeCapabilities?[list]?.arrayValue ?? []).contains(.string(value)) { setting[key] = .string(value) }
        }
        return ["setting": .object(setting), "termination": .object(termination)]
    }

    /// The central switch's overlay of several zones (section 5.10), with two of the Homebridge plugin's bugs fixed: a
    /// TIMER zone's duration is its minutes times 60 (not 3600), and an AUTO zone's overlay ends at the next time block
    /// (`NEXT_TIME_BLOCK`; the Homebridge plugin sent `AUTO`, which tado does not list).
    static func central(_ zones: [(id: Int, type: ZoneType, mode: ZoneMode, modeTimer: Int)], power: Bool, celsius: Double?) -> JSONValue {
        .object(["overlays": .array(zones.map { zone in
            var setting: [String: JSONValue] = ["power": power ? "ON" : "OFF", "type": .string(zone.type.rawValue)]
            if power, let celsius, celsius != 0 {
                setting["temperature"] = ["celsius": .number(celsius), "fahrenheit": .number(rounded(celsius * 9 / 5 + 32))]
            }
            var termination: [String: JSONValue]
            switch zone.mode {
            case .timer: termination = ["typeSkillBasedApp": "TIMER", "durationInSeconds": .number(Double(zone.modeTimer * 60))]
            case .auto: termination = ["typeSkillBasedApp": "NEXT_TIME_BLOCK"]
            case .manual, .custom: termination = ["typeSkillBasedApp": "MANUAL"]
            }
            return ["room": .number(Double(zone.id)), "overlay": ["setting": .object(setting)], "termination": .object(termination)]
        })])
    }

    // MARK: Fan levels (section 7.5)

    static let fanRank = ["SILENT", "LOW", "LEVEL1", "MIDDLE", "LEVEL2", "LEVEL3", "HIGH", "LEVEL4", "LEVEL5"]

    /// A mode's fan levels in order, AUTO last, and the setting's key for them; nil when the mode has none.
    static func fanLevels(_ modeCapabilities: JSONValue?) -> (key: String, levels: [String])? {
        let key: String, list: [String]
        if let levels = modeCapabilities?["fanLevel"]?.arrayValue {
            key = "fanLevel"
            list = levels.compactMap(\.stringValue)
        } else if let speeds = modeCapabilities?["fanSpeeds"]?.arrayValue {
            key = "fanSpeed"
            list = speeds.compactMap(\.stringValue)
        } else {
            return nil
        }
        let manual = list.filter { $0 != "AUTO" }
        let known = fanRank.filter(manual.contains)
        let ordered = known + manual.filter { !fanRank.contains($0) } + (list.contains("AUTO") ? ["AUTO"] : [])
        return ordered.isEmpty ? nil : (key, ordered)
    }

    /// Rotation Speed of step `index` (0-based) of `count`.
    static func percent(step index: Int, of count: Int) -> Double { (Double(index + 1) * 100 / Double(count)).rounded() }

    /// The level a Rotation Speed above 0 stands for.
    static func level(percent: Double, levels: [String]) -> String {
        let step = min(max(Int((percent * Double(levels.count) / 100).rounded()), 1), levels.count)
        return levels[step - 1]
    }

    // MARK: Running time (section 7.7)

    /// `from` (and `to`) of the day's, the month's and the year's running time, as `yyyy-MM-dd` in the local calendar.
    static func runningTimeRanges(today: Date, calendar: Calendar = .current) -> [(aggregate: String, from: String, to: String?)] {
        func text(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let monthStart = calendar.date(byAdding: .month, value: -1, to: yesterday) ?? yesterday
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? today
        let yearStart = calendar.date(byAdding: .year, value: -1, to: nextMonth) ?? today
        return [("day", text(today), nil), ("month", text(monthStart), nil), ("year", text(yearStart), text(today))]
    }
}
