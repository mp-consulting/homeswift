import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// An Altherma's domestic hot water tank as a Thermostat: on or off, its temperature, its setpoint and its
/// mode, with the tank's own Powerful mode switch.
///
/// A Thermostat has no Active characteristic, so Off switches the tank off and any other mode switches it
/// back on; a mode the unit does not let anyone set (most tanks only heat) is never written.
final class HotWaterTankService: @unchecked Sendable {
    static let name = "Hot water tank"
    static let targetTemperaturePath = DataPaths.setpoint(Daikin.OperationMode.heating.rawValue, "domesticHotWaterTemperature")
    static let defaultTemperature = 40.0
    static let defaultTargetTemperature = 50.0

    let device: DaikinCloudDevice
    let managementPointID: String
    let context: ServiceContext
    let service: Service
    let features: FeatureSet

    init(device: DaikinCloudDevice, managementPointID: String, accessoryName: String, context: ServiceContext) {
        self.device = device
        self.managementPointID = managementPointID
        self.context = context
        let target = device.data(managementPointID, "temperatureControl", Self.targetTemperaturePath)
        let targetType = CharacteristicType.targetTemperature.with(minValue: target.minValue, maxValue: target.maxValue, minStep: target.stepValue)
        let operationMode = device.data(managementPointID, "operationMode")
        context.logger.debug("OperationMode \(operationMode.value?.text(pretty: true) ?? "undefined")")
        let modes = Self.targetStateProps(operationMode)
        let targetState = CharacteristicType.targetHeatingCoolingState.with(minValue: modes.minValue, maxValue: modes.maxValue, minStep: modes.minStep, validValues: modes.validValues)
        // The extras replace the Thermostat's own TargetTemperature and TargetHeatingCoolingState: their props are the unit's.
        service = Service(.thermostat, name: Self.name, subtype: "hot_water_tank", extra: [
            Characteristic(targetType, value: .double(min(38, max(10, target.number ?? Self.defaultTargetTemperature)))),
            Characteristic(targetState),
            Characteristic(.configuredName, value: .string(Self.name)),
        ])
        features = FeatureSet(device: device, managementPointID: managementPointID, name: accessoryName, context: context, kinds: FeatureSet.hotWaterTank)
        // The setpoint takes writes only when the unit lets anyone set it.
        if target.settable != false {
            service.characteristic(.targetTemperature).onWrite { [weak self] value in try await self?.setTargetTemperature(value.doubleValue ?? 0) }
        }
        service.characteristic(.targetHeatingCoolingState).onWrite { [weak self] value in try await self?.setTargetState(value.intValue ?? 0) }
        refreshValues()
    }

    var services: [Service] { [service] + features.services }

    /// The modes HomeKit offers: Off and the one fixed mode when the unit does not let anyone change it, all
    /// four otherwise.
    static func targetStateProps(_ operationMode: DataPoint) -> (minValue: Double?, maxValue: Double?, minStep: Double?, validValues: [Int]?) {
        let fixed: Int? = switch operationMode.string {
        case Daikin.OperationMode.heating.rawValue: 1
        case Daikin.OperationMode.cooling.rawValue: 2
        case Daikin.OperationMode.auto.rawValue: 3
        default: nil
        }
        if operationMode.settable == false, let fixed { return (nil, nil, nil, [0, fixed]) }
        return (0, 3, 1, nil)
    }

    private var isOff: Bool { device.data(managementPointID, "onOffMode").string == Daikin.off }

    var targetState: Int {
        if isOff { return 0 }
        switch device.data(managementPointID, "operationMode").string {
        case Daikin.OperationMode.cooling.rawValue: return 2
        case Daikin.OperationMode.heating.rawValue: return 1
        default: return 3
        }
    }

    var currentTemperature: Double { device.data(managementPointID, "sensoryData", "/tankTemperature").number ?? Self.defaultTemperature }

    func refreshValues() {
        service.characteristic(.currentHeatingCoolingState).value = .int(isOff ? 0 : 1)
        service.characteristic(.targetHeatingCoolingState).value = .int(targetState)
        setClamped(service.characteristic(.currentTemperature), currentTemperature)
        let target = device.data(managementPointID, "temperatureControl", Self.targetTemperaturePath)
        if let value = target.value {
            setClamped(service.characteristic(.targetTemperature), value.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultTargetTemperature)
        }
        features.refreshAll()
    }

    func setTargetTemperature(_ value: Double) async throws {
        let temperature = jsRound(value * 2) / 2
        let control = device.data(managementPointID, "temperatureControl", Self.targetTemperaturePath)
        if control.number == temperature {
            context.logger.debug("[\(Self.name)] SET HeatingTargetTemperature skipped — already \(DaikinSettings.jsNumber(temperature))")
            return
        }
        context.logger.debug("[\(Self.name)] SET HeatingTargetTemperature domesticHotWaterTank, temperature to: \(DaikinSettings.jsNumber(temperature))")
        if control.settable == false {
            context.logger.warning("[\(Self.name)] SET HeatingTargetTemperature domesticHotWaterTank is not possible because temperatureControl isn't settable")
        }
        let device = device, managementPointID = managementPointID
        try await context.write("[\(Self.name)] HeatingTargetTemperature") {
            try await device.setData(managementPointID, "temperatureControl", .number(temperature), path: Self.targetTemperaturePath)
        }
        refreshValues()
    }

    /// Off switches the tank off. Heat, Cool and Auto switch it on when it is off, then change the mode when
    /// it differs and can be set. Each write is skipped when the tank is already there.
    func setTargetState(_ state: Int) async throws {
        context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState, OperationMode to: \(state)")
        let off = isOff
        let device = device, managementPointID = managementPointID
        if state == 0 {
            if off {
                context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState skipped — already off")
                return
            }
            try await context.write("[\(Self.name)] TargetHeatingCoolingState") { try await device.setData(managementPointID, "onOffMode", .string(Daikin.off)) }
            refreshValues()
            return
        }
        let mode = state == 1 ? Daikin.OperationMode.heating : state == 3 ? .auto : .cooling
        let operationMode = device.data(managementPointID, "operationMode")
        let changeMode = operationMode.string != mode.rawValue
        if changeMode, operationMode.settable == false {
            context.logger.warning("[\(Self.name)] SET TargetHeatingCoolingState is not possible because operationMode isn't settable")
        }
        let writeMode = changeMode && operationMode.settable != false
        if !off, !writeMode {
            context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState skipped — already \(mode.rawValue)")
            return
        }
        context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState, daikinOperationMode to: \(mode.rawValue)")
        try await context.write("[\(Self.name)] TargetHeatingCoolingState") {
            if off { try await device.setData(managementPointID, "onOffMode", .string(Daikin.on)) }
            if writeMode { try await device.setData(managementPointID, "operationMode", .string(mode.rawValue)) }
        }
        refreshValues()
    }
}
