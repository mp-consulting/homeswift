import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// An Altherma's domestic hot water tank as a Thermostat: on or off, its temperature, its setpoint and its
/// mode, with the tank's own Powerful mode switch.
///
/// The Thermostat is the shared `ClimateController`'s (docs/adr/0013-climate-is-mapped-once.md), with one setpoint:
/// Off switches the tank off and any other mode switches it back on. A tank whose mode nobody may set (most tanks only
/// heat) offers that mode alone, and a setpoint the unit does not let anyone set refuses writes.
final class HotWaterTankService: @unchecked Sendable {
    static let name = "Hot water tank"
    static let targetTemperaturePath = DataPaths.setpoint(Daikin.OperationMode.heating.rawValue, "domesticHotWaterTemperature")

    let device: DaikinCloudDevice
    let managementPointID: String
    let context: ServiceContext
    let climate: ClimateController
    var service: Service { climate.service }
    let features: FeatureSet

    init(device: DaikinCloudDevice, managementPointID: String, accessoryName: String, context: ServiceContext) {
        self.device = device
        self.managementPointID = managementPointID
        self.context = context
        let operationMode = device.data(managementPointID, "operationMode")
        context.logger.debug("OperationMode \(operationMode.value?.text(pretty: true) ?? "undefined")")
        let link = WeakLink<HotWaterTankService>()
        climate = ClimateController(.thermostat, name: Self.name, subtype: "hot_water_tank",
                                    capabilities: Self.capabilities(device, managementPointID),
                                    extra: [Characteristic(.configuredName, value: .string(Self.name))]) { command in
            try await link.value?.apply(command)
        }
        features = FeatureSet(device: device, managementPointID: managementPointID, name: accessoryName, context: context, kinds: FeatureSet.hotWaterTank)
        link.value = self
        refreshValues()
    }

    var services: [Service] { [service] + features.services }

    static let climateModes: [String: ClimateMode] = [
        Daikin.OperationMode.heating.rawValue: .heat, Daikin.OperationMode.cooling.rawValue: .cool, Daikin.OperationMode.auto.rawValue: .auto,
    ]

    /// What the tank can do: its one mode when nobody may change it, heat, cool and auto otherwise; its setpoint's range
    /// (10-38 °C when the unit gives none) in steps of at least 0.5°.
    static func capabilities(_ device: DaikinCloudDevice, _ managementPointID: String) -> ClimateCapabilities {
        let operationMode = device.data(managementPointID, "operationMode")
        let target = device.data(managementPointID, "temperatureControl", targetTemperaturePath)
        var modes: Set<ClimateMode> = [.heat, .cool, .auto]
        if operationMode.settable == false, let fixed = operationMode.string.flatMap({ climateModes[$0] }) { modes = [fixed] }
        let range = target.minValue.flatMap { low in target.maxValue.flatMap { high in low <= high ? low...high : nil } } ?? 10...38
        return ClimateCapabilities(modes: modes, setpoints: .single, range: range, step: max(0.5, target.stepValue ?? 0.5))
    }

    private var isOff: Bool { device.data(managementPointID, "onOffMode").string == Daikin.off }

    var currentTemperature: Double? { device.data(managementPointID, "sensoryData", "/tankTemperature").number }

    /// The tank's state for the controller: a mode other than heating, cooling or auto is an Other Mode.
    var report: ClimateReport {
        ClimateReport(power: !isOff, mode: device.data(managementPointID, "operationMode").string.flatMap { Self.climateModes[$0] },
                      current: currentTemperature,
                      target: device.data(managementPointID, "temperatureControl", Self.targetTemperaturePath).number)
    }

    func refreshValues() {
        climate.update(report)
        features.refreshAll()
    }

    /// Sends what HomeKit asked: on or off, then the mode when the unit lets anyone set it, then the setpoint.
    func apply(_ command: ClimateCommand) async throws {
        let device = device, managementPointID = managementPointID
        let control = device.data(managementPointID, "temperatureControl", Self.targetTemperaturePath)
        if command.target != nil, control.settable == false {
            context.logger.warning("[\(Self.name)] SET HeatingTargetTemperature domesticHotWaterTank is not possible because temperatureControl isn't settable")
            throw HAPStatusError(.readOnlyCharacteristic)
        }
        if let power = command.power {
            context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState, onOffMode to: \(power ? Daikin.on : Daikin.off)")
            try await context.write("[\(Self.name)] TargetHeatingCoolingState") {
                try await device.setData(managementPointID, "onOffMode", .string(power ? Daikin.on : Daikin.off))
            }
        }
        if let mode = command.mode {
            let operationMode = mode == .heat ? Daikin.OperationMode.heating : mode == .cool ? .cooling : .auto
            if device.data(managementPointID, "operationMode").settable == false {
                context.logger.warning("[\(Self.name)] SET TargetHeatingCoolingState is not possible because operationMode isn't settable")
            } else {
                context.logger.debug("[\(Self.name)] SET TargetHeatingCoolingState, daikinOperationMode to: \(operationMode.rawValue)")
                try await context.write("[\(Self.name)] TargetHeatingCoolingState") {
                    try await device.setData(managementPointID, "operationMode", .string(operationMode.rawValue))
                }
            }
        }
        if let temperature = command.target {
            context.logger.debug("[\(Self.name)] SET HeatingTargetTemperature domesticHotWaterTank, temperature to: \(DaikinSettings.jsNumber(temperature))")
            try await context.write("[\(Self.name)] HeatingTargetTemperature") {
                try await device.setData(managementPointID, "temperatureControl", .number(temperature), path: Self.targetTemperaturePath)
            }
        }
        refreshValues()
    }
}
