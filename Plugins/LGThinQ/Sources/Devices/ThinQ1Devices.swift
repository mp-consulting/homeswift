import Foundation
import Homeswift
import HomeswiftPlugin

// ThinQ v1 devices share the v2 handlers (their monitoring data is turned into v2 snapshots) and send their
// commands through `rti/rtiControl` instead.

/// A ThinQ1 air conditioner: the model's `TempCur` and `TempCfg` ranges, no monitor keep-alive.
final class AirConditionerV1: AirConditioner {
    nonisolated static let defaultCurrentRange = (min: -50.0, max: 100.0)
    nonisolated static let defaultTargetRange = (min: 10.0, max: 38.0)

    /// A model range, or the default when it is missing or empty.
    func range(_ key: String, _ fallback: (min: Double, max: Double)) -> (min: Double, max: Double) {
        guard case .range(let min?, let max?, _)? = device.deviceModel.value(key), min < max else { return fallback }
        return (min, max)
    }

    override func heaterCoolerCharacteristics() -> [CharacteristicType] {
        let current = range("TempCur", Self.defaultCurrentRange)
        let target = range("TempCfg", Self.defaultTargetRange)
        var types = super.heaterCoolerCharacteristics().map { type -> CharacteristicType in
            guard type.uuid == CharacteristicType.coolingThresholdTemperature.uuid || type.uuid == CharacteristicType.heatingThresholdTemperature.uuid else { return type }
            return type.props(min: target.min, max: target.max)
        }
        types.append(CharacteristicType.currentTemperature.props(min: current.min, max: current.max))
        return types
    }

    override func startMonitor() {
        stopMonitor()
    }

    override func setFanState(_ value: HAPValue) async throws {
        guard status.isPowerOn else {
            logger.debug("Power is off, cannot set fan state")
            return
        }
        let isAuto = Normalize.number(value).map { $0 == 1 } ?? Normalize.boolean(value)
        await thinq.thinq1DeviceControl(device, key: "WindStrength", value: .number(Double(isAuto ? ACFan.auto : ACFan.high)))
    }

    override func setJetModeActive(_ value: HAPValue) async throws {
        let jet = Normalize.number(value) ?? (Normalize.boolean(value) ? 1 : 0)
        if status.isPowerOn, status.opMode == ACOpMode.cool {
            await thinq.thinq1DeviceControl(device, key: "Jet", value: .number(jet))
        }
    }

    override func setActive(_ value: HAPValue) async throws {
        let isOn = Normalize.number(value).map { $0 == 1 } ?? Normalize.boolean(value)
        let operation = device.deviceModel.enumValue("Operation", isOn ? ThinQ1.acOperationRightOn : ThinQ1.acOperationOff)
        await thinq.thinq1DeviceControl(device, key: "Operation", value: operation.map { .string($0) } ?? .null)
    }

    override func setTargetTemperature(_ value: HAPValue) async throws {
        guard status.isPowerOn, let temperature = Normalize.number(value) else { return }
        await thinq.thinq1DeviceControl(device, key: "TempCfg", value: .string(JS.format(temperature)))
        setSnapshotValues(["airState.tempState.target": .number(temperature)])
        updateAccessoryCharacteristic(device)
    }

    override func setFanSpeed(_ value: HAPValue) async throws {
        guard status.isPowerOn, let percent = Normalize.number(value) else { return }
        await thinq.thinq1DeviceControl(device, key: "WindStrength", value: .number(Double(ACFan.windStrength(percent: percent))))
    }

    override func setSwingMode(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        let swing: JSONValue = Normalize.boolean(value) ? "100" : "0"
        let mode = config.string("ac_swing_mode")
        if mode == "BOTH" || mode == "VERTICAL" {
            await thinq.thinq1DeviceControl(device, key: "WDirVStep", value: swing)
            setSnapshotValues(["airState.wDir.vStep": swing])
        }
        if mode == "BOTH" || mode == "HORIZONTAL" {
            await thinq.thinq1DeviceControl(device, key: "WDirHStep", value: swing)
            setSnapshotValues(["airState.wDir.hStep": swing])
        }
        updateAccessoryCharacteristic(device)
    }

    override func setOpMode(_ opMode: Double) async throws -> Bool {
        let result = await thinq.thinq1DeviceControl(device, key: "OpMode", value: .number(opMode))
        guard result != nil else { return false }
        setSnapshotValues(["airState.opMode": .number(opMode)])
        updateAccessoryCharacteristic(device)
        return true
    }

    override func setLight(_ value: HAPValue) async throws {
        await thinq.thinq1DeviceControl(device, key: "DisplayControl", value: value.boolValue == true ? "1" : "0")
    }
}

/// A ThinQ1 air purifier.
final class AirPurifierV1: AirPurifier {
    override func setActive(_ value: HAPValue) async throws {
        await thinq.thinq1DeviceControl(device, key: "Operation", value: value.boolValue == true ? "1" : "0")
    }

    override func setTargetAirPurifierState(_ value: HAPValue) async throws {
        let auto = value.boolValue ?? false
        guard status.isPowerOn, auto == status.isNormalMode else { return }
        await thinq.thinq1DeviceControl(device, key: "OpMode", value: auto ? "16" : "14")
    }

    override func setRotationSpeed(_ value: HAPValue) async throws {
        guard status.isPowerOn, status.isNormalMode, let speed = Normalize.number(value) else { return }
        await thinq.thinq1DeviceControl(device, key: "WindStrength", value: .string(JS.format(AirPurifierStatus.windStrength(rotationSpeed: speed))))
    }

    override func setSwingMode(_ value: HAPValue) async throws {
        guard status.isPowerOn, status.isNormalMode else { return }
        await thinq.thinq1DeviceControl(device, key: "CirculateDir", value: value.boolValue == true ? "1" : "0")
    }

    override func setLight(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        await thinq.thinq1DeviceControl(device, key: "SignalLighting", value: value.boolValue == true ? "1" : "0")
    }

    override func setAirFastActive(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        await thinq.thinq1DeviceControl(device, key: "AirFast", value: value.boolValue == true ? "1" : "0")
    }
}

/// A ThinQ1 range hood.
final class RangeHoodV1: RangeHood {
    override func setHoodRotationSpeed(_ value: HAPValue) async throws {
        await thinq.thinq1DeviceControl(device, key: "VentLevel", value: Self.json(value))
    }

    override func setLightBrightness(_ value: HAPValue) async throws {
        await thinq.thinq1DeviceControl(device, key: "LampLevel", value: Self.json(value))
    }
}

/// A ThinQ1 refrigerator's state: v1 models name the temperatures `TempRefrigerator` and `TempFreezer`.
final class RefrigeratorV1Status: RefrigeratorStatus {
    private func temperature(_ key: String, _ value: JSONValue?) -> Double {
        let fallback = JS.string(deviceModel.lookupMonitorValue2(key, JS.string(value), "0"))
        if tempUnit == "FAHRENHEIT" {
            return TemperatureConverter.fToC(JS.parseInt(deviceModel.lookupMonitorValue2(key + "_F", JS.string(value), fallback)))
        }
        return JS.parseInt(deviceModel.lookupMonitorValue2(key + "_C", JS.string(value), fallback))
    }

    override var freezerTemperature: Double { temperature("TempFreezer", data["freezerTemp"]) }
    override var fridgeTemperature: Double { temperature("TempRefrigerator", data["fridgeTemp"]) }
    override var isExpressFridgeOn: Bool { isOn("expressFridge", model: "ExpressFridge") }
    override var isExpressModeOn: Bool { isOn("expressMode", model: "IcePlus") }
    override var isEcoFriendlyOn: Bool { isOn("ecoFriendly", model: "EcoFriendly") }
}

/// A ThinQ1 refrigerator.
final class RefrigeratorV1: Refrigerator {
    override var status: RefrigeratorStatus { RefrigeratorV1Status(data: statusData("refState"), deviceModel: device.deviceModel) }

    override func thermostatKey(_ key: String) -> String? {
        ["fridgeTemp": "TempRefrigerator", "freezerTemp": "TempFreezer"][key]
    }

    override func setTemperature(_ key: String, _ index: String) async throws {
        await thinq.thinq1DeviceControl(device, key: key, value: .string(index))
    }

    /// IcePlus, ExpressFridge, EcoFriendly.
    func setV1Toggle(_ key: String, _ value: HAPValue) async {
        let model = device.deviceModel
        let label = value.boolValue == true ? model.enumValue(key, "@CP_ON_EN_W") : model.enumValue(key, "@CP_OFF_EN_W")
        await thinq.thinq1DeviceControl(device, key: key, value: label.map { .string($0) } ?? .null)
    }

    override func setExpressMode(_ value: HAPValue) async throws { await setV1Toggle("IcePlus", value) }
    override func setExpressFridge(_ value: HAPValue) async throws { await setV1Toggle("ExpressFridge", value) }
    override func setEcoFriendly(_ value: HAPValue) async throws { await setV1Toggle("EcoFriendly", value) }
}

/// A ThinQ1 washer or dryer, which can be switched on and off.
final class WasherV1: WasherDryer {
    override func setActive(_ value: HAPValue) async throws {
        await thinq.thinq1DeviceControl(device, key: "Power", value: value.boolValue == true ? "On" : "Off")
    }
}
