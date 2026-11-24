import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The HeaterCooler of a climateControl management point: power, mode, room temperature, the heating and
/// cooling thresholds, fan speed and swing, with the feature switches and the optional separate Fan tile.
///
/// The Heater Cooler is the shared `ClimateController`'s (docs/adr/0013-climate-is-mapped-once.md): Daikin's
/// heating, cooling and auto are its Climate Modes, dry and fan only are Other Modes, and its setpoints are Separate,
/// the heating and cooling ones kept apart with the auto one at their middle when the unit has one. Power belongs to
/// Active alone.
final class ClimateControlService: @unchecked Sendable {
    let device: DaikinCloudDevice
    let managementPointID: String
    let name: String
    let context: ServiceContext
    let climate: ClimateController
    var service: Service { climate.service }
    let features: FeatureSet
    let separateFan: Service?
    let swing: SwingController
    let fanSpeed: FanSpeedController
    let setpoints: SetpointResolver
    /// The swing axes the service was built with: an axis the current mode adds needs a rebuild, one it lacks does not
    /// (its writes fail), so switching modes back and forth never rebuilds the service.
    let swingAxes: [ClimateSwing]
    /// The fan speed range the RotationSpeed characteristic was built for; another one needs a rebuild.
    let rotationShape: RotationShape

    /// RotationSpeed exists for the current mode's fixed speed, with a step of one unit step.
    struct RotationShape: Equatable, Sendable {
        var present: Bool
        var maxValue: Double?
    }

    /// The separate Fan tile's capabilities, decided when it was first built, as the Homebridge plugin does.
    struct SeparateFanShape: Equatable, Sendable {
        var hasFanSpeed: Bool
        var fanSpeedMax: Double?
        var hasSwing: Bool
    }

    init(device: DaikinCloudDevice, managementPointID: String, name: String, context: ServiceContext, separateFanShape: SeparateFanShape? = nil) {
        self.device = device
        self.managementPointID = managementPointID
        self.name = name
        self.context = context
        swing = SwingController(device: device, managementPointID: managementPointID)
        fanSpeed = FanSpeedController(device: device, managementPointID: managementPointID)
        let setpoints = SetpointResolver(device: device, managementPointID: managementPointID)
        self.setpoints = setpoints
        rotationShape = Self.rotationShape(fanSpeed)
        swingAxes = swing.supportedAxes

        var extra: [Characteristic] = []
        if rotationShape.present {
            extra.append(Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: FanSpeed.percentStep(rotationShape.maxValue))))
        }
        if swing.isSupported {
            context.logger.debug("[\(name)] Device has SwingMode, add Characteristic")
            extra.append(Characteristic(.swingMode))
        }
        extra += swingAxes.map { Characteristic($0.characteristic) }
        let link = WeakLink<ClimateControlService>()
        climate = ClimateController(.heaterCooler, name: name, isPrimary: true, capabilities: Self.capabilities(device, managementPointID, setpoints),
                                    extra: extra) { command in try await link.value?.apply(command) }
        features = FeatureSet(device: device, managementPointID: managementPointID, name: name, context: context, kinds: FeatureSet.climateControl)

        // The separate Fan: only with the option, and only when the unit has a fan speed or a swing.
        let fixed = fanSpeed.fixed()
        let fanShape = separateFanShape ?? SeparateFanShape(hasFanSpeed: fixed.value != nil, fanSpeedMax: fixed.maxValue, hasSwing: swing.isSupported)
        if context.isEnabled(.showSeparateFanControl), fanShape.hasFanSpeed || fanShape.hasSwing {
            context.logger.debug("[\(name)] Adding separate Fan service")
            let fanName = "\(name) Fan"
            var fanExtra = [Characteristic(.configuredName, value: .string(fanName))]
            if fanShape.hasFanSpeed {
                fanExtra.append(Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: FanSpeed.percentStep(fanShape.fanSpeedMax))))
            }
            if fanShape.hasSwing { fanExtra.append(Characteristic(.swingMode)) }
            fanExtra += swingAxes.map { Characteristic($0.characteristic) }
            separateFan = Service(.fanv2, name: fanName, subtype: "separate_fan", extra: fanExtra)
        } else {
            separateFan = nil
        }
        self.separateFanShape = fanShape
        link.value = self
        bind()
        refreshValues()
    }

    let separateFanShape: SeparateFanShape

    var services: [Service] { [service] + (separateFan.map { [$0] } ?? []) + features.services }

    static func rotationShape(_ fanSpeed: FanSpeedController) -> RotationShape {
        let fixed = fanSpeed.fixed()
        return RotationShape(present: fixed.value != nil, maxValue: fixed.value != nil ? fixed.maxValue : nil)
    }

    private func bind() {
        for axis in swingAxes {
            for target in [service, separateFan].compactMap({ $0 }) {
                target[axis.characteristic]?.onWrite { [weak self] value in
                    guard let self else { return }
                    try await context.write("[\(name)] \(axis.rawValue) swing") {
                        try await self.swing.set(value.boolValue == true, axis: axis.fanAxis)
                    }
                    refreshValues()
                }
            }
        }
        service[.rotationSpeed]?.onWrite { [weak self] value in try await self?.setRotationSpeed(value.doubleValue ?? 0) }
        service[.swingMode]?.onWrite { [weak self] value in try await self?.setSwing(value.intValue == 1) }
        if let separateFan {
            separateFan.characteristic(.active).onWrite { [weak self] value in try await self?.setActive(value.intValue == 1) }
            separateFan[.rotationSpeed]?.onWrite { [weak self] value in try await self?.setRotationSpeed(value.doubleValue ?? 0) }
            separateFan[.swingMode]?.onWrite { [weak self] value in try await self?.setSwing(value.intValue == 1) }
        }
    }

    // MARK: State to HomeKit

    var operationMode: String { device.operationMode(managementPointID, default: "") }
    var isOn: Bool { device.data(managementPointID, "onOffMode").string == Daikin.on }

    /// Whether the current mode needs RotationSpeed built differently (present, absent, another step).
    var needsRebuild: Bool { Self.rotationShape(fanSpeed) != rotationShape || !Set(swing.supportedAxes).isSubset(of: swingAxes) }

    /// Pushes the device's state to every characteristic, after each poll, push and write: an accurate cache
    /// lets HomeKit filter redundant scene commands, and changes made in the Onecta app show at once.
    func refreshValues() {
        let mode = operationMode
        climate.update(report)
        separateFan?.characteristic(.active).value = .int(isOn ? 1 : 0)
        // Only in fixed fan mode: in auto or quiet the stored speed is not the actual one, and HomeKit may
        // replay a cached value as a write when another characteristic changes, leaving auto or quiet.
        if let percent = fanSpeed.percentIfFixed(mode) {
            service[.rotationSpeed]?.value = .double(percent)
            separateFan?[.rotationSpeed]?.value = .double(percent)
        }
        if service[.swingMode] != nil || separateFan?[.swingMode] != nil, swing.isSupported {
            let swinging = swing.isSwinging ? 1 : 0
            service[.swingMode]?.value = .int(swinging)
            separateFan?[.swingMode]?.value = .int(swinging)
        }
        for axis in swingAxes {
            let on = swing.axisValue(axis.fanAxis).map { $0 != Daikin.stop } ?? false
            service[axis.characteristic]?.value = .bool(on)
            separateFan?[axis.characteristic]?.value = .bool(on)
        }
        features.refreshAll()
    }

    /// The room temperature, or the leaving water temperature an Altherma is controlled by.
    var currentTemperature: Double? {
        device.data(managementPointID, "sensoryData", "/" + setpoints.controlMode).number
    }

    static let climateModes: [String: ClimateMode] = [
        Daikin.OperationMode.heating.rawValue: .heat, Daikin.OperationMode.cooling.rawValue: .cool, Daikin.OperationMode.auto.rawValue: .auto,
    ]

    /// What the unit can do: the Climate Modes among its operation modes (an Altherma may only heat), the heating and
    /// cooling setpoints' ranges (room temperature, or leaving water offset or temperature), and an auto setpoint
    /// when it has one. Steps of at least 0.5°, as the thresholds always were rounded.
    static func capabilities(_ device: DaikinCloudDevice, _ managementPointID: String, _ setpoints: SetpointResolver) -> ClimateCapabilities {
        let values = device.data(managementPointID, "operationMode").values ?? []
        let modes = Set(values.compactMap { climateModes[$0] })
        let heating = setpoints.read(Daikin.OperationMode.heating.rawValue)
        let cooling = setpoints.read(Daikin.OperationMode.cooling.rawValue)
        let hasAuto = setpoints.read(Daikin.OperationMode.auto.rawValue).value != nil
        func range(_ setpoint: DataPoint, _ fallback: ClosedRange<Double>) -> ClosedRange<Double> {
            guard let low = setpoint.minValue, let high = setpoint.maxValue, low <= high else { return fallback }
            return low...high
        }
        let step = ([0.5] + [heating.stepValue, cooling.stepValue].compactMap { $0 }).max() ?? 0.5
        return ClimateCapabilities(modes: modes.isEmpty ? [.heat, .cool, .auto] : modes, setpoints: .separate(autoSetpoint: hasAuto),
                                   heatingRange: range(heating, 0...25), coolingRange: range(cooling, 10...35), step: step)
    }

    /// The unit's state for the controller: dry and fan only are Other Modes.
    var report: ClimateReport {
        ClimateReport(power: isOn, mode: Self.climateModes[operationMode], current: currentTemperature,
                      target: setpoints.read(Daikin.OperationMode.auto.rawValue).number,
                      heating: setpoints.read(Daikin.OperationMode.heating.rawValue).number,
                      cooling: setpoints.read(Daikin.OperationMode.cooling.rawValue).number)
    }

    // MARK: HomeKit to the device

    private func setData(_ dataPoint: String, _ value: JSONValue, path: String? = nil) async throws {
        try await device.setData(managementPointID, dataPoint, value, path: path)
    }

    /// The separate Fan's Active: the unit's power.
    func setActive(_ desired: Bool) async throws {
        if isOn == desired {
            context.logger.debug("[\(name)] SET ActiveState skipped — already \(desired ? "on" : "off")")
            return
        }
        try await apply(ClimateCommand(power: desired))
    }

    /// Sends what HomeKit asked: the power, then the operation mode, then the heating and cooling setpoints, then the
    /// auto setpoint at their middle (best effort: a missed one only leaves the Daikin app with a stale auto setpoint).
    func apply(_ command: ClimateCommand) async throws {
        if let power = command.power {
            context.logger.debug("[\(name)] SET ActiveState, state: \(power ? 1 : 0)")
            try await context.write("[\(name)] ActiveState") { try await setData("onOffMode", .string(power ? Daikin.on : Daikin.off)) }
        }
        if let mode = command.mode {
            let operationMode = mode == .heat ? Daikin.OperationMode.heating : mode == .cool ? .cooling : .auto
            context.logger.debug("[\(name)] SET TargetHeaterCoolerState, daikinOperationMode to: \(operationMode.rawValue)")
            try await context.write("[\(name)] TargetHeaterCoolerState") { try await setData("operationMode", .string(operationMode.rawValue)) }
        }
        for (kind, value) in [(ThresholdKind.heating, command.heating), (.cooling, command.cooling)] {
            guard let temperature = value else { continue }
            let label = kind == .cooling ? "CoolingThresholdTemperature" : "HeatingThresholdTemperature"
            context.logger.debug("[\(name)] SET \(label), temperature to: \(DaikinSettings.jsNumber(temperature))")
            let path = try setpoints.path(kind.operationMode)
            try await context.write("[\(name)] \(label)") { try await setData("temperatureControl", .number(temperature), path: path) }
        }
        // The auto setpoint follows a threshold sent, not a middle recomputed for a threshold that was already there.
        if let target = command.target, command.heating != nil || command.cooling != nil { await setAutoSetpoint(target) }
        refreshValues()
    }

    private func setAutoSetpoint(_ temperature: Double) async {
        do {
            let path = try setpoints.path(Daikin.OperationMode.auto.rawValue)
            let auto = device.data(managementPointID, "temperatureControl", path)
            guard auto.value != nil else { return }
            var value = temperature
            if let min = auto.minValue { value = max(min, value) }
            if let max = auto.maxValue { value = min(max, value) }
            if let current = auto.number, abs(current - value) < 0.01 { return }
            context.logger.debug("[\(name)] SYNC AutoSetpoint → auto=\(DaikinSettings.jsNumber(value))")
            try await setData("temperatureControl", .number(value), path: path)
        } catch {
            context.logger.debug("[\(name)] AutoSetpoint sync skipped: \(message(of: error))")
        }
    }

    func setRotationSpeed(_ percent: Double) async throws {
        switch fanSpeed.plan(percent: percent) {
        case .skip(let reason):
            context.logger.debug("[\(name)] SET RotationSpeed skipped — \(reason)")
        case .write(let speed, let writes):
            context.logger.debug("[\(name)] SET RotationSpeed, \(DaikinSettings.jsNumber(percent))% → device speed \(DaikinSettings.jsNumber(speed))")
            try await context.write("[\(name)] RotationSpeed") {
                for write in writes { try await setData("fanControl", write.value, path: write.path) }
            }
            // The slider sets the fan to fixed: Auto fan mode and Indoor silent are off now.
            refreshValues()
        }
    }

    func setSwing(_ enabled: Bool) async throws {
        if swing.axesToWrite(enabled).isEmpty {
            context.logger.debug("[\(name)] SET SwingMode skipped — already \(enabled ? "swinging" : "stopped")")
            return
        }
        context.logger.debug("[\(name)] SET SwingMode, swingmode to: \(enabled ? 1 : 0)")
        let swing = swing
        try await context.write("[\(name)] SwingMode") { try await swing.set(enabled) }
        refreshValues()
    }
}

/// A weak reference that a closure made before its owner is initialized can hold.
final class WeakLink<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
}
