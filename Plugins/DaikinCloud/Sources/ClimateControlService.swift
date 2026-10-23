import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The HeaterCooler of a climateControl management point: power, mode, room temperature, the heating and
/// cooling thresholds, fan speed and swing, with the feature switches and the optional separate Fan tile.
///
/// HomeKit's modes map to Daikin's: Cool is cooling, Heat is heating, Auto is auto (and dry and fan only
/// read back as Auto). Power belongs to Active alone: iOS sends Active=1 with every mode change, so a mode
/// change that also switched the unit on would race a "turn off" scene.
final class ClimateControlService: @unchecked Sendable {
    static let defaultCoolingTemperature = 25.0
    static let defaultRoomTemperature = 20.0
    static let homeKitMinimum = 10.0
    static let coolingClampMax = 35.0
    static let heatingClampMin = 0.0
    static let heatingClampMax = 25.0

    let device: DaikinCloudDevice
    let managementPointID: String
    let name: String
    let context: ServiceContext
    let service: Service
    let features: FeatureSet
    let separateFan: Service?
    let swing: SwingController
    let fanSpeed: FanSpeedController
    let setpoints: SetpointResolver
    let autoSync: AutoSetpointSync
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
        setpoints = SetpointResolver(device: device, managementPointID: managementPointID)
        autoSync = AutoSetpointSync(device: device, managementPointID: managementPointID, logger: context.logger, name: name)
        rotationShape = Self.rotationShape(fanSpeed)

        var extra: [Characteristic] = []
        let cooling = setpoints.read(Daikin.OperationMode.cooling.rawValue)
        let heating = setpoints.read(Daikin.OperationMode.heating.rawValue)
        extra.append(Self.threshold(.coolingThresholdTemperature, cooling, fallback: Self.coolingClampMax, clamp: Self.homeKitMinimum...Self.coolingClampMax))
        extra.append(Self.threshold(.heatingThresholdTemperature, heating, fallback: Self.defaultRoomTemperature, clamp: Self.heatingClampMin...Self.heatingClampMax))
        if rotationShape.present {
            extra.append(Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: FanSpeed.percentStep(rotationShape.maxValue))))
        }
        if swing.isSupported {
            context.logger.debug("[\(name)] Device has SwingMode, add Characteristic")
            extra.append(Characteristic(.swingMode))
        }
        service = Service(.heaterCooler, name: name, extra: extra, isPrimary: true)
        features = FeatureSet(device: device, managementPointID: managementPointID, name: name, context: context, kinds: FeatureSet.climateControl)

        // The separate Fan: only with the option, and only when the unit has a fan speed or a swing.
        let fixed = fanSpeed.fixed()
        let fanShape = separateFanShape ?? SeparateFanShape(hasFanSpeed: fixed.value != nil, fanSpeedMax: fixed.maxValue, hasSwing: swing.isSupported)
        if context.settings.isEnabled(.showSeparateFanControl), fanShape.hasFanSpeed || fanShape.hasSwing {
            context.logger.debug("[\(name)] Adding separate Fan service")
            let fanName = "\(name) Fan"
            var fanExtra = [Characteristic(.configuredName, value: .string(fanName))]
            if fanShape.hasFanSpeed {
                fanExtra.append(Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: FanSpeed.percentStep(fanShape.fanSpeedMax))))
            }
            if fanShape.hasSwing { fanExtra.append(Characteristic(.swingMode)) }
            separateFan = Service(.fanv2, name: fanName, subtype: "separate_fan", extra: fanExtra)
        } else {
            separateFan = nil
        }
        self.separateFanShape = fanShape
        bind()
        refreshValues()
    }

    let separateFanShape: SeparateFanShape

    var services: [Service] { [service] + (separateFan.map { [$0] } ?? []) + features.services }

    static func rotationShape(_ fanSpeed: FanSpeedController) -> RotationShape {
        let fixed = fanSpeed.fixed()
        return RotationShape(present: fixed.value != nil, maxValue: fixed.value != nil ? fixed.maxValue : nil)
    }

    /// A threshold with the setpoint's range as props, and its value inside HomeKit's default range first.
    private static func threshold(_ type: CharacteristicType, _ setpoint: DataPoint, fallback: Double, clamp: ClosedRange<Double>) -> Characteristic {
        let value = min(clamp.upperBound, max(clamp.lowerBound, setpoint.number ?? fallback))
        let characteristic = Characteristic(type.with(minValue: setpoint.minValue, maxValue: setpoint.maxValue, minStep: setpoint.stepValue))
        setClamped(characteristic, value)
        return characteristic
    }

    private func bind() {
        service.characteristic(.active).onWrite { [weak self] value in try await self?.setActive(value.intValue == 1) }
        service.characteristic(.targetHeaterCoolerState).onWrite { [weak self] value in try await self?.setTargetState(value.intValue ?? 0) }
        service.characteristic(.coolingThresholdTemperature).onWrite { [weak self] value in try await self?.setThreshold(.cooling, value.doubleValue ?? 0) }
        service.characteristic(.heatingThresholdTemperature).onWrite { [weak self] value in try await self?.setThreshold(.heating, value.doubleValue ?? 0) }
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
    var needsRebuild: Bool { Self.rotationShape(fanSpeed) != rotationShape }

    /// Pushes the device's state to every characteristic, after each poll, push and write: an accurate cache
    /// lets HomeKit filter redundant scene commands, and changes made in the Onecta app show at once.
    func refreshValues() {
        let mode = operationMode
        let on = isOn
        service.characteristic(.active).value = .int(on ? 1 : 0)
        separateFan?.characteristic(.active).value = .int(on ? 1 : 0)
        let current: Int = !on ? 0 : mode == Daikin.OperationMode.cooling.rawValue ? 3 : mode == Daikin.OperationMode.heating.rawValue ? 2 : 1
        service.characteristic(.currentHeaterCoolerState).value = .int(current)
        service.characteristic(.targetHeaterCoolerState).value = .int(Self.targetState(mode))
        setClamped(service.characteristic(.currentTemperature), currentTemperature)
        if let cooling = setpoints.read(Daikin.OperationMode.cooling.rawValue).value {
            setClamped(service.characteristic(.coolingThresholdTemperature), cooling.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultCoolingTemperature)
        }
        if let heating = setpoints.read(Daikin.OperationMode.heating.rawValue).value {
            setClamped(service.characteristic(.heatingThresholdTemperature), heating.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultRoomTemperature)
        }
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
        features.refreshAll()
    }

    /// The room temperature, or the leaving water temperature an Altherma is controlled by.
    var currentTemperature: Double {
        device.data(managementPointID, "sensoryData", "/" + setpoints.controlMode).number ?? Self.defaultRoomTemperature
    }

    static func targetState(_ mode: String) -> Int {
        switch mode {
        case Daikin.OperationMode.cooling.rawValue: 2
        case Daikin.OperationMode.heating.rawValue: 1
        default: 0
        }
    }

    // MARK: HomeKit to the device

    private func setData(_ dataPoint: String, _ value: JSONValue, path: String? = nil) async throws {
        try await device.setData(managementPointID, dataPoint, value, path: path)
    }

    func setActive(_ desired: Bool) async throws {
        if isOn == desired {
            context.logger.debug("[\(name)] SET ActiveState skipped — already \(desired ? "on" : "off")")
            return
        }
        context.logger.debug("[\(name)] SET ActiveState, state: \(desired ? 1 : 0)")
        try await context.write("[\(name)] ActiveState") { try await setData("onOffMode", .string(desired ? Daikin.on : Daikin.off)) }
        refreshValues()
    }

    func setTargetState(_ state: Int) async throws {
        context.logger.debug("[\(name)] SET TargetHeaterCoolerState, OperationMode to: \(state)")
        let mode = state == 1 ? Daikin.OperationMode.heating : state == 0 ? .auto : .cooling
        // Compared with Daikin's mode, not HomeKit's: Auto while in dry or fan only must still switch to auto.
        if operationMode == mode.rawValue {
            context.logger.debug("[\(name)] SET TargetHeaterCoolerState skipped — already \(mode.rawValue)")
            return
        }
        context.logger.debug("[\(name)] SET TargetHeaterCoolerState, daikinOperationMode to: \(mode.rawValue)")
        try await context.write("[\(name)] TargetHeaterCoolerState") { try await setData("operationMode", .string(mode.rawValue)) }
        refreshValues()
    }

    /// Writes a threshold (rounded to 0.5°), then mirrors the range's middle to the auto setpoint.
    func setThreshold(_ kind: ThresholdKind, _ value: Double) async throws {
        let temperature = jsRound(value * 2) / 2
        let label = kind == .cooling ? "CoolingThresholdTemperature" : "HeatingThresholdTemperature"
        if setpoints.read(kind.operationMode).number == temperature {
            context.logger.debug("[\(name)] SET \(label) skipped — already \(DaikinSettings.jsNumber(temperature))")
            return
        }
        context.logger.debug("[\(name)] SET \(label), temperature to: \(DaikinSettings.jsNumber(temperature))")
        let setpoints = setpoints, device = device, managementPointID = managementPointID
        try await context.write("[\(name)] \(label)") {
            try await autoSync.writeThreshold(kind, temperature) {
                try await device.setData(managementPointID, "temperatureControl", .number(temperature), path: try setpoints.path(kind.operationMode))
            }
        }
        refreshValues()
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
