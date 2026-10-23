import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The optional switches of a management point: Powerful, Econo, Streamer, Outdoor and Indoor silent, Auto
/// fan, Oscillation, Dry, Fan only, Holiday and Firmware Update. A switch exists when the unit supports the
/// feature and its `show*` option is on.
///
/// Switch subtypes carry the management point (`climateControl:powerful_mode`), so the features of an
/// Altherma's climate control and of its hot water tank, which both know a Powerful mode, never meet.
final class FeatureSet: @unchecked Sendable {
    enum Kind: Sendable, CaseIterable {
        case powerful, econo, streamer, outdoorSilent, indoorSilent, autoFan, oscillation, dry, fanOnly, holiday, firmwareUpdate
    }

    static let climateControl: [Kind] = [.powerful, .econo, .streamer, .outdoorSilent, .indoorSilent, .autoFan, .oscillation, .dry, .fanOnly, .holiday, .firmwareUpdate]
    static let hotWaterTank: [Kind] = [.powerful]

    let capabilities: DeviceCapabilities
    let features: [Feature]

    init(device: DaikinCloudDevice, managementPointID: String, name: String, context: ServiceContext, kinds: [Kind]) {
        capabilities = CapabilityDetector(device: device, managementPointID: managementPointID).capabilities()
        let capabilities = capabilities
        features = kinds.map { Feature(kind: $0, device: device, managementPointID: managementPointID, accessoryName: name, context: context, capabilities: capabilities) }
        for feature in features { feature.setUp() }
    }

    var services: [Service] { features.compactMap(\.service) }

    func feature(_ kind: Kind) -> Feature? { features.first { $0.kind == kind } }

    /// Pushes every switch's state, so a mode changed in the Onecta app reaches HomeKit.
    func refreshAll() { for feature in features { feature.refresh() } }
}

extension FeatureSet.Kind {
    /// A feature: its switch's name and subtype, the option that shows it, what the unit needs for it, and for
    /// the plain on/off ones the data point (at a path built from the current mode) and its two values.
    struct Spec: Sendable {
        struct OnOff: Sendable {
            var dataPoint: String
            var path: (@Sendable (_ operationMode: String) -> String)?
            var on = Daikin.on
            var off = Daikin.off
        }

        var name: String
        var subtype: String
        var configKey: FeatureKey
        /// Nil for the firmware switch, which goes by the gateway.
        var isSupported: (@Sendable (DeviceCapabilities) -> Bool)?
        var onOff: OnOff?
    }

    var spec: Spec {
        let fanMode: @Sendable (String) -> String = { DataPaths.fanSpeedCurrentMode($0) }
        return switch self {
        case .powerful: Spec(name: "Powerful mode", subtype: "powerful_mode", configKey: .showPowerfulMode, isSupported: { $0.hasPowerfulMode }, onOff: .init(dataPoint: "powerfulMode"))
        case .econo: Spec(name: "Econo mode", subtype: "econo_mode", configKey: .showEconoMode, isSupported: { $0.hasEconoMode }, onOff: .init(dataPoint: "econoMode"))
        case .streamer: Spec(name: "Streamer mode", subtype: "streamer_mode", configKey: .showStreamerMode, isSupported: { $0.hasStreamerMode }, onOff: .init(dataPoint: "streamerMode"))
        case .outdoorSilent:
            Spec(name: "Outdoor silent mode", subtype: "outdoor_silent_mode", configKey: .showOutdoorSilentMode, isSupported: { $0.hasOutdoorSilentMode }, onOff: .init(dataPoint: "outdoorSilentMode"))
        case .indoorSilent:
            Spec(name: "Indoor silent mode", subtype: "indoor_silent_mode", configKey: .showIndoorSilentMode, isSupported: { $0.hasIndoorSilentMode },
                onOff: .init(dataPoint: "fanControl", path: fanMode, on: Daikin.FanSpeedMode.quiet.rawValue, off: Daikin.FanSpeedMode.fixed.rawValue))
        // Auto fan: off goes back to manual speed; the RotationSpeed slider switches it off too.
        case .autoFan:
            Spec(name: "Auto fan mode", subtype: "auto_fan_mode", configKey: .showAutoFanMode, isSupported: { $0.hasAutoFanMode },
                onOff: .init(dataPoint: "fanControl", path: fanMode, on: Daikin.FanSpeedMode.auto.rawValue, off: Daikin.FanSpeedMode.fixed.rawValue))
        case .oscillation:
            Spec(name: "Oscillation", subtype: "oscillation", configKey: .showOscillationSwitch, isSupported: { $0.hasSwingModeVertical || $0.hasSwingModeHorizontal })
        // Dry and Fan only: off goes back to auto.
        case .dry:
            Spec(name: "Dry operation mode", subtype: "dry_operation_mode", configKey: .showDryMode, isSupported: { $0.hasDryOperationMode },
                onOff: .init(dataPoint: "operationMode", on: Daikin.OperationMode.dry.rawValue, off: Daikin.OperationMode.auto.rawValue))
        case .fanOnly:
            Spec(name: "Fan only operation mode", subtype: "fan_only_operation_mode", configKey: .showFanOnlyMode, isSupported: { $0.hasFanOnlyOperationMode },
                onOff: .init(dataPoint: "operationMode", on: Daikin.OperationMode.fanOnly.rawValue, off: Daikin.OperationMode.auto.rawValue))
        case .holiday: Spec(name: "Holiday mode", subtype: "holiday_mode", configKey: .showHolidayMode, isSupported: { $0.hasHolidayMode })
        case .firmwareUpdate: Spec(name: "Firmware Update", subtype: "firmware_update", configKey: .showFirmwareUpdateSwitch)
        }
    }
}

/// One feature switch.
final class Feature: @unchecked Sendable {
    let kind: FeatureSet.Kind
    let device: DaikinCloudDevice
    let managementPointID: String
    let accessoryName: String
    let context: ServiceContext
    let capabilities: DeviceCapabilities
    let spec: FeatureSet.Kind.Spec
    private(set) var service: Service?
    private let announced = NIOLockedValueBox<(version: String?, status: String?)>((nil, nil))
    /// How long a switch that changed nothing waits before showing its real state again.
    var revertDelay: Duration = .seconds(1)

    init(kind: FeatureSet.Kind, device: DaikinCloudDevice, managementPointID: String, accessoryName: String, context: ServiceContext, capabilities: DeviceCapabilities) {
        self.kind = kind
        self.device = device
        self.managementPointID = managementPointID
        self.accessoryName = accessoryName
        self.context = context
        self.capabilities = capabilities
        spec = kind.spec
    }

    var isSupported: Bool {
        // Firmware is the gateway's, not a capability of the management point.
        guard let supported = spec.isSupported else { return gatewayID.map(device.isFirmwareUpdateSupported) ?? false }
        return supported(capabilities)
    }

    // MARK: The switch

    /// Builds the switch when the unit supports the feature and the configuration shows it.
    func setUp() {
        guard isSupported, context.settings.isEnabled(spec.configKey) else { return }
        context.logger.debug("[\(accessoryName)] Device has \(spec.name), add Switch Service")
        let service = Service(.switch, name: spec.name, subtype: "\(managementPointID):\(spec.subtype)", extra: [Characteristic(.configuredName, value: .string(spec.name))])
        service.characteristic(.on).onWrite { [weak self] value in try await self?.set(value.boolValue ?? false) }
        self.service = service
    }

    /// Pushes the device's state to the switch (and, for firmware, logs what changed).
    func refresh() {
        if kind == .firmwareUpdate {
            announceAvailability()
            announceOutcome()
        }
        service?.characteristic(.on).value = .bool(isOn)
    }

    private var swing: SwingController { SwingController(device: device, managementPointID: managementPointID) }

    private var currentMode: String { device.operationMode(managementPointID) }

    var isOn: Bool {
        if let onOff = spec.onOff {
            return device.data(managementPointID, onOff.dataPoint, onOff.path?(currentMode)).string == onOff.on
        }
        switch kind {
        case .oscillation: return swing.isSwinging
        case .holiday: return device.data(managementPointID, "holidayMode").value?["enabled"] == .bool(true)
        case .firmwareUpdate: return updateStatus == "in-progress"
        default: return false
        }
    }

    func set(_ on: Bool) async throws {
        let label = "[\(accessoryName)]"
        if let onOff = spec.onOff {
            context.logger.debug("\(label) SET \(spec.name) to: \(on)")
            let device = device, managementPointID = managementPointID, path = onOff.path?(currentMode)
            try await context.write("\(label) \(onOff.dataPoint)") {
                try await device.setData(managementPointID, onOff.dataPoint, .string(on ? onOff.on : onOff.off), path: path)
            }
            return
        }
        switch kind {
        case .oscillation:
            if swing.axesToWrite(on).isEmpty {
                context.logger.debug("\(label) SET Oscillation skipped — already \(on ? "on" : "off")")
                return
            }
            context.logger.debug("\(label) SET Oscillation to: \(on)")
            let swing = swing
            try await context.write("\(label) Oscillation") { try await swing.set(on) }
        case .holiday:
            context.logger.debug("\(label) SET HolidayMode to: \(on)")
            let device = device, managementPointID = managementPointID
            try await context.write("\(label) holidayMode") { try await device.setHolidayMode(managementPointID, enabled: on) }
        case .firmwareUpdate:
            try await setFirmwareUpdate(on)
        default:
            break
        }
    }

    // MARK: Firmware updates

    /// Firmware lives on the gateway management point, not the one the other features use.
    private var gatewayID: String? { device.managementPointID(type: "gateway") }
    private var updateStatus: String? { gatewayID.flatMap(device.firmwareUpdateStatus) }

    /// On installs the update Daikin staged; it stays on while it runs. A running update cannot be cancelled.
    private func setFirmwareUpdate(_ on: Bool) async throws {
        let label = "[\(accessoryName)]"
        guard on else {
            if updateStatus == "in-progress" {
                context.logger.info("\(label) A running firmware update cannot be cancelled")
                revert(to: true)
            }
            return
        }
        if updateStatus == "in-progress" {
            context.logger.info("\(label) Firmware update already in progress")
            return
        }
        guard let gatewayID, let staged = device.firmwareUpdateInfo(gatewayID) else {
            context.logger.info("\(label) Firmware is up to date — no update staged by Daikin")
            revert(to: false)
            return
        }
        // No forced poll: the update runs for minutes and the polls follow it.
        let device = device
        let info = try await context.write("\(label) firmware update", refresh: false) { try await device.triggerFirmwareUpdate(gatewayID) }
        context.logger.info("\(label) Installing firmware update \(info.version ?? staged.version ?? "") — the unit will be unavailable until it finishes")
    }

    /// HomeKit takes a write that does not throw as done: when it changed nothing, the real state goes back
    /// shortly after so the switch does not stay in the wrong position.
    private func revert(to value: Bool) {
        service?.characteristic(.on).revert(to: .bool(value), after: revertDelay)
    }

    private func announceAvailability() {
        guard let gatewayID, let info = device.firmwareUpdateInfo(gatewayID) else { return }
        let isNew = announced.withLockedValue { state -> Bool in
            guard info.version != state.version else { return false }
            state.version = info.version
            return true
        }
        guard isNew else { return }
        let detail = info.description.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        context.logger.info("[\(accessoryName)] Firmware update available: \(info.version ?? "unknown version")\(detail) — turn on the \"Firmware Update\" switch to install")
    }

    private func announceOutcome() {
        let status = updateStatus
        let changed = announced.withLockedValue { state -> Bool in
            guard state.status != status else { return false }
            state.status = status
            return true
        }
        if changed, status == "succeeded" || status == "failed" {
            context.logger.info("[\(accessoryName)] Firmware update \(status ?? "")")
        }
    }
}
