import Foundation

/// The values the Onecta API uses.
enum Daikin {
    enum OperationMode: String, Sendable, CaseIterable {
        case fanOnly, heating, cooling, auto, dry
    }

    enum FanSpeedMode: String, Sendable {
        case auto, quiet, fixed
    }

    enum ControlMode: String, Sendable {
        case roomTemperature, leavingWaterTemperature, externalRoomTemperature
    }

    enum SetpointMode: String, Sendable {
        case fixed, weatherDependentHeatingFixedCooling, weatherDependent
    }

    enum Setpoint: String, Sendable {
        case roomTemperature, leavingWaterOffset, leavingWaterTemperature
    }

    static let on = "on"
    static let off = "off"
    static let swing = "swing"
    static let stop = "stop"
}

/// The `/operationModes/<mode>/...` paths of `getData`/`setData`.
enum DataPaths {
    enum FanAxis: String, Sendable, CaseIterable { case horizontal, vertical }

    /// The active fan speed mode (`auto`, `quiet` or `fixed`) of an operation mode.
    static func fanSpeedCurrentMode(_ operationMode: String) -> String { "/operationModes/\(operationMode)/fanSpeed/currentMode" }
    /// The fixed fan speed (1 to maxValue) of an operation mode.
    static func fanSpeedFixed(_ operationMode: String) -> String { "/operationModes/\(operationMode)/fanSpeed/modes/fixed" }
    /// The swing of one fan axis of an operation mode.
    static func fanDirection(_ operationMode: String, _ axis: FanAxis) -> String { "/operationModes/\(operationMode)/fanDirection/\(axis.rawValue)/currentMode" }
    /// A setpoint of an operation mode.
    static func setpoint(_ operationMode: String, _ setpoint: String) -> String { "/operationModes/\(operationMode)/setpoints/\(setpoint)" }
}

/// What a management point can do, detected once from its data.
struct DeviceCapabilities: Sendable, Equatable {
    var hasPowerfulMode = false
    var hasEconoMode = false
    var hasStreamerMode = false
    var hasOutdoorSilentMode = false
    var hasIndoorSilentMode = false
    var hasAutoFanMode = false
    var hasSwingModeVertical = false
    var hasSwingModeHorizontal = false
    var hasFanControl = false
    var hasHolidayMode = false

    var supportedOperationModes: [String] = []
    var hasDryOperationMode = false
    var hasFanOnlyOperationMode = false

    /// A short list for the log: `powerful, econo, fan-speed, swing`, or `basic`.
    var summary: String {
        var features: [String] = []
        if hasPowerfulMode { features.append("powerful") }
        if hasEconoMode { features.append("econo") }
        if hasStreamerMode { features.append("streamer") }
        if hasOutdoorSilentMode { features.append("outdoor-silent") }
        if hasIndoorSilentMode { features.append("indoor-silent") }
        if hasAutoFanMode { features.append("auto-fan") }
        if hasFanControl { features.append("fan-speed") }
        if hasSwingModeVertical || hasSwingModeHorizontal { features.append("swing") }
        if hasDryOperationMode { features.append("dry-mode") }
        if hasFanOnlyOperationMode { features.append("fan-only") }
        if hasHolidayMode { features.append("holiday") }
        return features.isEmpty ? "basic" : features.joined(separator: ", ")
    }
}

/// Detects what a management point of a device supports from its data.
struct CapabilityDetector {
    let device: DaikinCloudDevice
    let managementPointID: String

    func capabilities() -> DeviceCapabilities {
        let modes = device.data(managementPointID, "operationMode").values ?? []
        var capabilities = DeviceCapabilities()
        capabilities.hasPowerfulMode = hasValue("powerfulMode")
        capabilities.hasEconoMode = hasValue("econoMode")
        capabilities.hasStreamerMode = hasValue("streamerMode")
        capabilities.hasOutdoorSilentMode = hasValue("outdoorSilentMode")
        let fanModes = device.data(managementPointID, "fanControl", DataPaths.fanSpeedCurrentMode(currentOperationMode)).values ?? []
        capabilities.hasIndoorSilentMode = fanModes.contains(Daikin.FanSpeedMode.quiet.rawValue)
        // Only meaningful when the unit can go between auto and a manual (fixed) speed.
        capabilities.hasAutoFanMode = fanModes.contains(Daikin.FanSpeedMode.auto.rawValue) && fanModes.contains(Daikin.FanSpeedMode.fixed.rawValue)
        capabilities.hasSwingModeVertical = hasValue("fanControl", DataPaths.fanDirection(currentOperationMode, .vertical))
        capabilities.hasSwingModeHorizontal = hasValue("fanControl", DataPaths.fanDirection(currentOperationMode, .horizontal))
        capabilities.hasFanControl = hasValue("fanControl", DataPaths.fanSpeedFixed(currentOperationMode))
        capabilities.hasHolidayMode = device.data(managementPointID, "holidayMode").value?["enabled"] != nil
        capabilities.supportedOperationModes = modes
        capabilities.hasDryOperationMode = modes.contains(Daikin.OperationMode.dry.rawValue)
        capabilities.hasFanOnlyOperationMode = modes.contains(Daikin.OperationMode.fanOnly.rawValue)
        return capabilities
    }

    /// Support means the inner value is set, not that the wrapper exists.
    private func hasValue(_ dataPoint: String, _ path: String? = nil) -> Bool {
        device.data(managementPointID, dataPoint, path).value != nil
    }

    private var currentOperationMode: String { device.operationMode(managementPointID) }
}

/// The kinds of device the plugin knows.
enum DeviceProfile: String, Sendable {
    case airConditioning = "air_conditioning"
    case altherma
    case unknown

    var displayName: String {
        switch self {
        case .airConditioning: "Daikin Air Conditioning"
        case .altherma: "Daikin Altherma Heat Pump"
        case .unknown: "Daikin Device"
        }
    }

    static func match(_ device: DaikinCloudDevice) -> DeviceProfile {
        if device.deviceModel == "Altherma" { return .altherma }
        if device.hasManagementPoint(type: "climateControl") { return .airConditioning }
        return .unknown
    }
}
