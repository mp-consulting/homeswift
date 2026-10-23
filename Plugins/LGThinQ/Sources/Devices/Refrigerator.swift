import Foundation
import Homeswift
import HomeswiftPlugin

/// A refrigerator's `refState`.
class RefrigeratorStatus {
    let data: [String: JSONValue]
    let deviceModel: DeviceModel

    required init(data: [String: JSONValue], deviceModel: DeviceModel) {
        self.data = data
        self.deviceModel = deviceModel
    }

    var freezerTemperature: Double {
        if tempUnit == "FAHRENHEIT" {
            return TemperatureConverter.fToC(JS.parseInt(deviceModel.lookupMonitorValue2("freezerTemp_F", JS.string(data["freezerTemp"]), "0")))
        }
        return JS.parseInt(deviceModel.lookupMonitorValue2("freezerTemp_C", JS.string(data["freezerTemp"]), "0"))
    }

    var fridgeTemperature: Double {
        if tempUnit == "FAHRENHEIT" {
            return TemperatureConverter.fToC(JS.parseInt(deviceModel.lookupMonitorValue2("fridgeTemp_F", JS.string(data["fridgeTemp"]), "0")))
        }
        return JS.parseInt(deviceModel.lookupMonitorValue2("fridgeTemp_C", JS.string(data["fridgeTemp"]), "0"))
    }

    var isDoorClosed: Bool { data["atLeastOneDoorOpen"]?.stringValue == "CLOSE" }

    func isOn(_ key: String, model modelKey: String) -> Bool {
        guard let value = data[key]?.stringValue, let on = deviceModel.lookupMonitorName(modelKey, "@CP_ON_EN_W") else { return false }
        return value == on
    }

    var isExpressModeOn: Bool { isOn("expressMode", model: "expressMode") }
    var isExpressFridgeOn: Bool { isOn("expressFridge", model: "expressFridge") }
    var isEcoFriendlyOn: Bool { isOn("ecoFriendly", model: "ecoFriendly") }

    var tempUnit: String { data["tempUnit"].flatMap { JS.truthy($0) ? JS.string($0) : nil } ?? "CELSIUS" }

    /// Remaining water filter life in percent, from `waterFilter1RemainP`, or the months used in
    /// `waterFilter` (`"12_…"`) out of twelve.
    var waterFilterRemain: Double {
        func clamp(_ value: Double) -> Double { max(0, min(100, value.rounded(.toNearestOrAwayFromZero))) }
        if let remaining = data["waterFilter1RemainP"] {
            let number = JS.number(remaining)
            return clamp(number.isNaN ? 0 : number)
        }
        if let filter = data["waterFilter"]?.stringValue {
            guard let match = filter.range(of: #"\d+_"#, options: .regularExpression), let used = Double(filter[match].dropLast()) else { return 0 }
            return clamp((12 - used) / 12 * 100)
        }
        return 0
    }

    /// Whether the model shows the feature in LG's app (a visible item with a control title).
    func hasFeature(_ key: String) -> Bool {
        guard let item = deviceModel.data["Config"]?["visibleItems"]?.arrayValue?.first(where: {
            $0["Feature"]?.stringValue == key || $0["feature"]?.stringValue == key
        }) else { return false }
        return item["ControlTitle"] != nil || item["controlTitle"] != nil
    }
}

/// A refrigerator: a Thermostat for the fridge and one for the freezer (cooling only, the model's
/// temperatures), the door, the Express Freezer, Express Fridge and Eco Friendly switches the options enable,
/// and the water filter.
class Refrigerator: BaseDevice {
    nonisolated static let fridgeDefaultRange = (min: 1.0, max: 7.0)
    nonisolated static let freezerDefaultRange = (min: -23.0, max: -15.0)

    var serviceFridge: Service?
    var serviceFreezer: Service?
    var serviceDoorOpened: Service!
    var serviceExpressMode: Service?
    var serviceExpressFridge: Service?
    var serviceEcoFriendly: Service?
    var serviceWaterFilter: Service?

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        serviceFridge = createThermostat("Fridge", key: "fridgeTemp")
        serviceFridge?.set(.targetTemperature, status.fridgeTemperature)
        serviceFreezer = createThermostat("Freezer", key: "freezerTemp")
        serviceFreezer?.set(.targetTemperature, status.freezerTemperature)

        serviceDoorOpened = addService(.contactSensor, name: "Refrigerator Door Closed")

        if config.flag("ref_express_freezer"), hasRefStateKey("expressMode") {
            serviceExpressMode = addService(.switch, name: "Express Freezer")
            serviceExpressMode?.characteristic(.on).onSet { [weak self] value in try await self?.setExpressMode(value) }
        }
        if config.flag("ref_express_fridge"), hasRefStateKey("expressFridge") {
            serviceExpressFridge = addService(.switch, name: "Express Fridge")
            serviceExpressFridge?.characteristic(.on).onSet { [weak self] value in try await self?.setExpressFridge(value) }
        }
        if config.flag("ref_eco_friendly"), hasRefStateKey("ecoFriendly") {
            serviceEcoFriendly = addService(.switch, name: "Eco Friendly")
            serviceEcoFriendly?.characteristic(.on).onSet { [weak self] value in try await self?.setEcoFriendly(value) }
        }
        if status.hasFeature("waterFilter") {
            serviceWaterFilter = addService(.filterMaintenance, name: "Water Filter Maintenance", optional: [.filterLifeLevel])
        }
    }

    var status: RefrigeratorStatus { RefrigeratorStatus(data: statusData("refState"), deviceModel: device.deviceModel) }

    func hasRefStateKey(_ key: String) -> Bool { device.snapshot["refState"]?.objectValue?[key] != nil }

    /// The model key of a thermostat (ThinQ1 models name them differently).
    func thermostatKey(_ key: String) -> String? { key }

    /// A cooling-only Thermostat over the temperatures the model lists for the key.
    func createThermostat(_ name: String, key requestedKey: String) -> Service? {
        guard let key = thermostatKey(requestedKey) else {
            logger.error("Invalid key for thermostat: \(requestedKey)")
            return nil
        }
        guard status.hasFeature(key) else { return nil }
        let model = device.deviceModel
        let isCelsius = status.tempUnit == "CELSIUS"
        var characteristics: [CharacteristicType] = [
            CharacteristicType.currentHeatingCoolingState.valid([2]), CharacteristicType.targetHeatingCoolingState.valid([2]),
            CharacteristicType.temperatureDisplayUnits.props(min: 0, max: 1),
        ]
        let mapping = model.monitoringValueMapping(key + "_C") ?? model.monitoringValueMapping(key)
        var range: (min: Double, max: Double)?
        if let mapping {
            let values = mapping.values.compactMap { value -> Double? in
                let number = value.objectValue?["label"].map { JS.parseInt($0, fallback: .nan) } ?? JS.parseInt(value, fallback: .nan)
                return number.isNaN ? nil : number
            }
            let fallback = key.lowercased().contains("freezer") ? Self.freezerDefaultRange : Self.fridgeDefaultRange
            range = values.isEmpty ? fallback : (values.min()!, values.max()!)
            characteristics.append(CharacteristicType.targetTemperature.props(min: range!.min, max: range!.max, step: isCelsius ? 1 : 0.1))
        }
        let service = addService(.thermostat, name: name, optional: characteristics)
        service.set(.currentHeatingCoolingState, 2)
        service.set(.targetHeatingCoolingState, 2)
        service.characteristic(.temperatureDisplayUnits).onGet { [weak self] in .int(self?.status.tempUnit == "CELSIUS" ? 0 : 1) }
        guard let range else {
            logger.error("[Refrigerator] [\(device.name)] No value mapping found for \(key)")
            return service
        }
        service.set(.targetTemperature, range.min)
        service.characteristic(.targetTemperature).onSet { [weak self] value in
            guard let self else { return }
            guard let celsius = Normalize.number(value) else { throw HAPStatusError(.invalidValueInRequest) }
            let model = device.deviceModel
            let index: String?
            if status.tempUnit == "FAHRENHEIT" {
                let fahrenheit = JS.format(TemperatureConverter.cToF(celsius))
                index = model.lookupMonitorName(key + "_F", fahrenheit) ?? model.lookupMonitorName(key, fahrenheit)
            } else {
                index = model.lookupMonitorName(key + "_C", JS.format(celsius)) ?? model.lookupMonitorName(key, JS.format(celsius))
            }
            guard let index else { throw HAPStatusError(.invalidValueInRequest) }
            try await setTemperature(key, index)
        }
        return service
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        func between(_ service: Service, _ value: Double) -> Double {
            let type = service[.targetTemperature]?.type
            return min(max(type?.minValue ?? value, value), type?.maxValue ?? value)
        }
        if let freezer = serviceFreezer {
            let temperature = between(freezer, status.freezerTemperature)
            freezer.set(.currentTemperature, temperature)
            freezer.set(.targetTemperature, temperature)
        }
        if let fridge = serviceFridge {
            let temperature = between(fridge, status.fridgeTemperature)
            fridge.set(.currentTemperature, temperature)
            fridge.set(.targetTemperature, temperature)
        }
        serviceDoorOpened.set(.contactSensorState, status.isDoorClosed ? 0 : 1)
        if config.flag("ref_express_freezer"), hasRefStateKey("expressMode") { serviceExpressMode?.set(.on, status.isExpressModeOn) }
        if config.flag("ref_express_fridge"), hasRefStateKey("expressFridge") { serviceExpressFridge?.set(.on, status.isExpressFridgeOn) }
        if config.flag("ref_eco_friendly"), hasRefStateKey("ecoFriendly") { serviceEcoFriendly?.set(.on, status.isEcoFriendlyOn) }
        if status.hasFeature("waterFilter"), let filter = serviceWaterFilter {
            filter.set(.filterLifeLevel, status.waterFilterRemain)
            filter.set(.filterChangeIndication, status.waterFilterRemain < 100 - AirPurifierStatus.filterChangeThreshold ? 1 : 0)
        }
    }

    /// A `refState` command (with the unit), which must be accepted.
    func sendRefStateControl(_ values: [String: JSONValue], label: String) async throws {
        var refState = values
        refState["tempUnit"] = .string(status.tempUnit)
        try await sendAccepted(Self.dataSetList(["refState": .object(refState)]),
            failed: { logger.error("[\(device.name)] Failed to set \(label): \($0)") },
            refused: { logger.warning("[\(device.name)] Device did not accept \(label)") })
    }

    func setRefStateToggle(_ key: String, _ value: HAPValue) async throws {
        let model = device.deviceModel
        let label = Normalize.boolean(value) ? model.lookupMonitorName(key, "@CP_ON_EN_W") : model.lookupMonitorName(key, "@CP_OFF_EN_W")
        try await sendRefStateControl([key: label.map { .string($0) } ?? .null], label: key)
        logger.debug("Set \(key) -> \(value)")
    }

    func setExpressMode(_ value: HAPValue) async throws { try await setRefStateToggle("expressMode", value) }
    func setExpressFridge(_ value: HAPValue) async throws { try await setRefStateToggle("expressFridge", value) }
    func setEcoFriendly(_ value: HAPValue) async throws { try await setRefStateToggle("ecoFriendly", value) }

    func setTemperature(_ key: String, _ index: String) async throws {
        try await sendRefStateControl([key: .number(JS.parseInt(.string(index)))], label: "temperature")
    }
}
