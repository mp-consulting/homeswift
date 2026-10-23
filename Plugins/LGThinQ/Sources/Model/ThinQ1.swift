import Foundation
import HomeswiftPlugin

/// ThinQ v1 devices report raw monitoring data; these turn it into the ThinQ v2 snapshot shape, so one set of
/// device handlers serves both, and build v1 control payloads.
enum ThinQ1 {
    /// The device's snapshot from its monitoring data (`nil`: nothing reported).
    @ThinQActor
    static func transform(_ device: ThinQDevice, monitorData: Data?) {
        let model = device.deviceModel
        let decoded = model.decodeMonitor(monitorData)
        var snapshot: [String: JSONValue]
        switch device.type {
        case "DRYER", "WASHER": snapshot = washerDryer(model, decoded)
        case "AIR_PURIFIER": snapshot = airPurifierState(model, decoded)
        case "AC": snapshot = airState(model, decoded)
        case "REFRIGERATOR": snapshot = refState(model, decoded)
        case "HOOD": snapshot = hoodState(model, decoded)
        default: return
        }
        if monitorData != nil {
            // Online, so the update goes through.
            device.data["online"] = true
            snapshot["online"] = true
        }
        snapshot["raw"] = monitorData == nil ? .null : .object(decoded)
        device.snapshot = snapshot
    }

    /// The `rti/rtiControl` payload: the model's byte template filled from the last monitoring data for binary
    /// devices, `{key: value}` otherwise.
    @ThinQActor
    static func prepareControlData(_ device: ThinQDevice, key: String, value: JSONValue, workID: String = UUID().uuidString.lowercased()) -> JSONValue {
        var data: [String: JSONValue] = ["cmd": "Control", "cmdOpt": "Set", "deviceId": .string(device.id), "workId": .string(workID)]
        let controlWifi = device.deviceModel.data["ControlWifi"]
        if controlWifi?["type"]?.stringValue == "BINARY(BYTE)" {
            var template = controlWifi?["action"]?["SetControl"]?["data"].flatMap { JS.truthy($0) ? JS.string($0) : nil } ?? "[]"
            var monitor = device.snapshot["raw"]?.objectValue ?? [:]
            monitor[key] = value
            for (name, raw) in monitor {
                let text: String = switch raw {
                case .null: "0"
                case .bool(let bool): bool ? "1" : "0"
                default: JS.string(raw)
                }
                let number = JS.number(text)
                template = template.replacingOccurrences(of: "{{\(name)}}", with: JS.format(number.isNaN ? 0 : number))
            }
            let bytes = (try? JSONValue(string: template))?.arrayValue?.map { UInt8(truncatingIfNeeded: Int(JS.number($0).isNaN ? 0 : JS.number($0))) } ?? []
            // Buffer.from(String.fromCharCode(...bytes)): each byte a code point, encoded as UTF-8.
            let text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
            data["value"] = "ControlData"
            data["data"] = .string(Data(text.utf8).base64EncodedString())
            data["format"] = "B64"
        } else {
            data["value"] = .object([key: value])
            data["data"] = ""
        }
        return .object(data)
    }

    // MARK: Transforms

    static let acOperationOff = "@AC_MAIN_OPERATION_OFF_W"
    static let acOperationRightOn = "@AC_MAIN_OPERATION_RIGHT_ON_W"

    /// `loopupEnum`: the label of a monitored key, nil when the key was not reported.
    static func lookupEnum(_ model: DeviceModel, _ decoded: [String: JSONValue], _ key: String) -> JSONValue? {
        guard let value = decoded[key] else { return nil }
        return model.enumName(key, JS.string(value))
    }

    /// `lookupEnumIndex`: the name of the enum case whose value is the label.
    static func lookupEnumIndex(_ cases: [(String, String)], _ label: JSONValue?) -> String? {
        let text = label.map { JS.string($0) } ?? "null"
        return cases.first { $0.1 == text }?.0
    }

    static func airState(_ model: DeviceModel, _ decoded: [String: JSONValue]) -> [String: JSONValue] {
        var state: [String: JSONValue] = [
            "airState.opMode": .number(JS.parseInt(decoded["OpMode"])),
            "airState.operation": .bool(lookupEnum(model, decoded, "Operation")?.stringValue != acOperationOff),
            "airState.tempState.current": .number(JS.parseFloat(decoded["TempCur"])),
            "airState.tempState.target": .number(JS.parseFloat(decoded["TempCfg"])),
            "airState.windStrength": .number(JS.parseInt(decoded["WindStrength"])),
            "airState.wDir.vStep": .number(JS.parseInt(decoded["WDirVStep"])),
            "airState.wDir.hStep": .number(JS.parseInt(decoded["WDirHStep"])),
            "airState.circulate.rotate": .number(JS.parseInt(decoded["CirculateDir"])),
            "airState.lightingState.signal": .number(JS.parseInt(decoded["SignalLighting"])),
            "airState.quality.overall": 0,
            "airState.quality.sensorMon": 0,
            "airState.quality.PM1": 0,
            "airState.energy.onCurrent": 0,
        ]
        // Math.max(value, model minimum): NaN when either is missing.
        for (key, valueKey) in [("TempCur", "airState.tempState.current"), ("TempCfg", "airState.tempState.target")] {
            guard let definition = model.value(key) else { continue }
            let value = JS.number(state[valueKey])
            if case .range(let minimum?, _, _) = definition, !value.isNaN, !minimum.isNaN {
                state[valueKey] = .number(Swift.max(value, minimum))
            } else {
                state[valueKey] = .number(.nan)
            }
        }
        let optional: [(String, String)] = [
            ("TotalAirPolution", "airState.quality.overall"), ("SensorMon", "airState.quality.sensorMon"), ("SensorPM1", "airState.quality.PM1"),
            ("SensorPM2", "airState.quality.PM2"), ("SensorPM10", "airState.quality.PM10"), ("Jet", "airState.wMode.jet"),
            ("SensorHumidity", "airState.humidity.current"),
        ]
        for (source, target) in optional where JS.truthy(decoded[source]) {
            state[target] = .number(JS.parseInt(decoded[source]))
        }
        return state
    }

    static func airPurifierState(_ model: DeviceModel, _ decoded: [String: JSONValue]) -> [String: JSONValue] {
        var state = airState(model, decoded)
        state["airState.operation"] = .bool(JS.parseInt(decoded["Operation"]) != 0)
        state["airState.miscFuncState.airFast"] = .bool(JS.parseInt(decoded["AirFast"]) != 0)
        return state
    }

    static func hoodState(_ model: DeviceModel, _ decoded: [String: JSONValue]) -> [String: JSONValue] {
        let flag = { (key: String, on: String, off: String) -> JSONValue in .string(JS.parseInt(decoded[key]) != 0 ? on : off) }
        var hood: [String: JSONValue] = [
            "ventMode": model.enumName("VentMode", JS.string(decoded["VentMode"])) ?? .null,
            "error": model.enumName("Error", JS.string(decoded["Error"])) ?? .null,
            "ventLevel": .number(JS.parseInt(decoded["VentLevel"])),
            "remainTimeMinute": .number(JS.parseInt(decoded["TimerMin"])),
            "hoodFotaEnable": flag("FOTAEnable", "ENABLE", "DISABLE"),
            "remainTimeSecond": .number(JS.parseInt(decoded["TimerSec"])),
            "childLock": flag("ChildLock", "ENABLE", "DISABLE"),
            "standyMode": flag("StandyMode", "ENABLE", "DISABLE"),
            "lampLevel": .number(JS.parseInt(decoded["LampLevel"])),
            "hoodState": flag("HoodState", "USING", "INIT"),
        ]
        if let lampSet = decoded["LampSet"] { hood["lampSet"] = lampSet }
        if let ventSet = decoded["VentSet"] { hood["ventSet"] = ventSet }
        return ["hoodState": .object(hood)]
    }

    static let doorOpenStates: [(String, String)] = [("OPEN", "OPEN"), ("CLOSE", "CLOSE")]

    static func refState(_ model: DeviceModel, _ decoded: [String: JSONValue]) -> [String: JSONValue] {
        func firstTruthy(_ values: JSONValue?...) -> JSONValue? { values.first { JS.truthy($0) } ?? nil }
        let fridge = firstTruthy(decoded["TempRefrigerator"], model.defaultValue("TempRefrigerator")) ?? "0"
        let freezer = firstTruthy(decoded["TempFreezer"], model.defaultValue("TempFreezer")) ?? "0"
        let door = firstTruthy(lookupEnum(model, decoded, "DoorOpenState"), model.defaultValue("DoorOpenState"))
        let unit = firstTruthy(decoded["TempUnit"], model.defaultValue("TempUnit"))
        var state: [String: JSONValue] = [
            "fridgeTemp": .number(JS.parseInt(fridge)),
            "freezerTemp": .number(JS.parseInt(freezer)),
            "tempUnit": .string(JS.parseInt(unit) != 0 ? "CELSIUS" : "FAHRENHEIT"),
        ]
        if let index = lookupEnumIndex(doorOpenStates, door) { state["atLeastOneDoorOpen"] = .string(index) }
        for (source, target) in [("IcePlus", "expressMode"), ("ExpressFridge", "expressFridge"), ("EcoFriendly", "ecoFriendly")] where decoded[source] != nil {
            state[target] = firstTruthy(decoded[source], model.defaultValue(source)) ?? "0"
        }
        return ["refState": .object(state)]
    }

    static let washerStates: [(String, String)] = [
        ("POWEROFF", "@WM_STATE_POWER_OFF_W"), ("INITIAL", "@WM_STATE_INITIAL_W"), ("PAUSE", "@WM_STATE_PAUSE_W"), ("RESERVED", "@WM_STATE_RESERVE_W"),
        ("DETECTING", "@WM_STATE_DETECTING_W"), ("RUNNING", "@WM_STATE_RUNNING_W"), ("RINSING", "@WM_STATE_RINSING_W"), ("SPINNING", "@WM_STATE_SPINNING_W"),
        ("DRYING", "@WM_STATE_DRYING_W"), ("END", "@WM_STATE_END_W"), ("COOLDOWN", "@WM_STATE_COOLDOWN_W"), ("RINSEHOLD", "@WM_STATE_RINSEHOLD_W"),
        ("WASH_REFRESHING", "@WM_STATE_WASH_REFRESHING_W"), ("STEAMSOFTENING", "@WM_STATE_STEAMSOFTENING_W"), ("ERROR", "@WM_STATE_ERROR_W"),
    ]
    static let remoteStart: [(String, String)] = [("REMOTE_START_OFF", "@CP_OFF_EN_W"), ("REMOTE_START_ON", "@CP_ON_EN_W")]
    static let childLock: [(String, String)] = [("CHILDLOCK_OFF", "@CP_OFF_EN_W"), ("CHILDLOCK_ON", "@CP_ON_EN_W")]
    static let soilWash: [(String, String)] = [
        ("NO_SOILWASH", "-"), ("SOILWASH_TURBO_WASH", "@WM_FL24_TITAN_SOIL_LIGHT_W"), ("SOILWASH_TIMESAVE", "@WM_FL24_TITAN_SOIL_NORMAL_W"),
        ("SOILWASH_NORMAL", "@WM_FL24_TITAN_SOIL_HEAVY_W"),
    ]

    static func washerDryer(_ model: DeviceModel, _ decoded: [String: JSONValue]) -> [String: JSONValue] {
        let washer: [String: JSONValue] = [
            "state": .string(lookupEnumIndex(washerStates, lookupEnum(model, decoded, "State")) ?? "POWEROFF"),
            "preState": .string(lookupEnumIndex(washerStates, lookupEnum(model, decoded, "PreState")) ?? "POWEROFF"),
            "remoteStart": .string(lookupEnumIndex(remoteStart, lookupEnum(model, decoded, "RemoteStart")) ?? "REMOTE_START_OFF"),
            "initialBit": .string(JS.truthy(decoded["InitialBit"]) ? "INITIAL_BIT_ON" : "INITIAL_BIT_OFF"),
            "childLock": .string(lookupEnumIndex(childLock, lookupEnum(model, decoded, "ChildLock")) ?? "CHILDLOCK_OFF"),
            "TCLCount": decoded["TCLCount"].flatMap { JS.truthy($0) ? $0 : nil } ?? 0,
            "reserveTimeHour": .number(JS.parseInt(decoded["Reserve_Time_H"])),
            "reserveTimeMinute": .number(JS.parseInt(decoded["Reserve_Time_M"])),
            "remainTimeHour": .number(JS.parseInt(decoded["Remain_Time_H"])),
            "remainTimeMinute": .number(JS.parseInt(decoded["Remain_Time_M"])),
            "initialTimeHour": .number(JS.parseInt(decoded["Initial_Time_H"])),
            "initialTimeMinute": .number(JS.parseInt(decoded["Initial_Time_M"])),
            "soilWash": .string(lookupEnumIndex(soilWash, lookupEnum(model, decoded, "Soil")) ?? "NO_SOILWASH"),
        ]
        return ["washerDryer": .object(washer)]
    }
}
