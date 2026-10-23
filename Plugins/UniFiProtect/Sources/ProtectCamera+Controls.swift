import Foundation
import Homeswift
import HomeswiftPlugin

/// The controls of a camera (`ProtectCameraControls`): the status light and night vision on the camera's
/// operating mode, a night vision dimmer, the controller's recording mode switches, and the UniFi Access lock.
extension ProtectCamera {
    /// Night vision modes as dimmer levels; `custom` covers 20 to 90 through `icrCustomValue`.
    nonisolated static let nightVisionLevels: [String: Int] = ["off": 0, "autoFilterOnly": 5, "auto": 10, "on": 100]
    nonisolated static let nightVisionModes: [Int: String] = [0: "off", 5: "autoFilterOnly", 10: "auto", 100: "on"]
    nonisolated static let recordingSwitches = [ProtectReservedNames.switchUFPRecordingAlways, ProtectReservedNames.switchUFPRecordingDetections, ProtectReservedNames.switchUFPRecordingNever]

    func configureControls() {
        configureCameraDetails()
        configureNvrRecordingSwitch()
        configureNightVisionDimmer()
        configureAccessFeatures()
    }

    func updateControls() {
        let operatingMode = accessory.firstService(.cameraOperatingMode)
        if hints.ledStatus { operatingMode?[.cameraOperatingModeIndicator]?.value = .bool(statusLed) }
        if hints.nightVision { operatingMode?[.nightVision]?.value = .bool(nightVision) }
        if hints.nightVisionDimmer, let dimmer = accessory.service(.lightbulb, subtype: ProtectReservedNames.lightbulbNightVision) {
            dimmer[.on]?.value = .bool(nightVision)
            dimmer[.brightness]?.value = .int(nightVisionBrightness)
        }
        if hints.statusLedSwitch { accessory.service(.switch, subtype: ProtectReservedNames.switchStatusLed)?[.on]?.value = .bool(statusLed) }
        if hints.nvrRecordingSwitch {
            let mode = ufp.json.string("recordingSettings.mode")
            for type in Self.recordingSwitches {
                accessory.service(.switch, subtype: type)?[.on]?.value = .bool(Self.recordingSetting(type) == mode)
            }
        }
    }

    /// `always`, `detections` or `never`, from a recording switch's subtype.
    nonisolated static func recordingSetting(_ subtype: String) -> String {
        String(subtype.split(separator: ".").last ?? "")
    }

    /// The status light and night vision characteristics of the camera operating mode service, which the
    /// camera controller adds for HomeKit Secure Video.
    private func configureCameraDetails() {
        guard var service = accessory.firstService(.cameraOperatingMode) else { return }
        if !isHksvCapable || !hints.ledStatus {
            service = accessory.reshape(service, removing: [.cameraOperatingModeIndicator])
        } else {
            service = accessory.reshape(service, adding: [.cameraOperatingModeIndicator])
            service[.cameraOperatingModeIndicator]?.onRead { [weak self] in .bool(await self?.statusLed ?? false) }
            service[.cameraOperatingModeIndicator]?.onWrite { @ProtectActor [weak self] value in try await self?.writeStatusLed(value.boolValue ?? false) }
            service[.cameraOperatingModeIndicator]?.value = .bool(statusLed)
        }
        if !isHksvCapable || !hints.nightVision {
            accessory.reshape(service, removing: [.nightVision])
        } else {
            service = accessory.reshape(service, adding: [.nightVision])
            service[.nightVision]?.onRead { [weak self] in .bool(await self?.nightVision ?? false) }
            service[.nightVision]?.onWrite { @ProtectActor [weak self] value in
                let mode = value.boolValue == true ? "auto" : "off"
                try await self?.writeDevice(["ispSettings": ["irLedMode": .string(mode)]],
                    "Unable to set night vision to \(mode). Please ensure this username has the Administrator role in UniFi Protect.")
            }
            service[.nightVision]?.value = .bool(nightVision)
        }
    }

    /// A dimmer for night vision (`Device.NightVision.Dimmer`): off, filter only (5%), auto (10%), custom
    /// sensitivity (20–90%), always on (100%).
    @discardableResult
    private func configureNightVisionDimmer() -> Bool {
        guard accessory.valid(.lightbulb, hints.nightVisionDimmer, subtype: ProtectReservedNames.lightbulbNightVision) else { return false }
        let service = accessory.acquire(.lightbulb, name: accessoryName + " Night Vision", subtype: ProtectReservedNames.lightbulbNightVision, optional: [.brightness])
        service[.on]?.onRead { [weak self] in .bool(await self?.nightVision ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if self.nightVision != on { self.log.info("Night vision \(on ? "enabled" : "disabled").") }
            let mode = self.nightVisionMode(forBrightness: service[.brightness]?.value.intValue ?? 0)
            try await self.writeDevice(["ispSettings": ["irLedMode": .string(on ? mode : "off")]],
                "Unable to set night vision to \(on ? mode : "off"). Please ensure this username has the Administrator role in UniFi Protect.")
        }
        service[.brightness]?.onRead { [weak self] in .int(await self?.nightVisionBrightness ?? 0) }
        service[.brightness]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let (payload, level) = self.nightVisionPayload(forBrightness: value.intValue ?? 0)
            try await self.writeDevice(payload, "Unable to adjust night vision settings. Please ensure this username has the Administrator role in UniFi Protect.")
            self.timers.after(ProtectSettings.homeKitUpdateDelay) { service[.brightness]?.value = .int(level) }
        }
        service[.on]?.value = .bool(nightVision)
        service[.brightness]?.value = .int(nightVisionBrightness)
        log.info("Enabling night vision dimmer.")
        return true
    }

    /// The mode for turning night vision on at a dimmer level.
    func nightVisionMode(forBrightness brightness: Int) -> String {
        switch brightness {
        case 5: "autoFilterOnly"
        case 10: "auto"
        default: isFilterOnlyMode ? "customFilterOnly" : "custom"
        }
    }

    private var isFilterOnlyMode: Bool {
        ["autoFilterOnly", "customFilterOnly"].contains(ufp.json.string("ispSettings.irLedMode") ?? "")
    }

    /// The payload for a dimmer level, snapped to the fixed levels or the custom range, and the level it
    /// settles on.
    func nightVisionPayload(forBrightness value: Int) -> (JSONValue, Int) {
        var level = value
        if level < 5 { level = 0 } else if level < 10 { level = 5 } else if level < 20 { level = 10 } else if level > 90 { level = 100 }
        if let mode = Self.nightVisionModes[level] {
            return (["ispSettings": ["irLedMode": .string(mode)]], level)
        }
        let custom = Int((Double(level - 20) / 7).rounded(.toNearestOrAwayFromZero))
        return (["ispSettings": ["icrCustomValue": .number(Double(custom)), "irLedMode": .string(isFilterOnlyMode ? "customFilterOnly" : "custom")]], custom * 7 + 20)
    }

    /// Switches for the controller's recording modes (`Nvr.Recording.Switch`): always, detections, never.
    private func configureNvrRecordingSwitch() {
        var enabled: [String] = []
        for type in Self.recordingSwitches {
            let setting = Self.recordingSetting(type)
            guard accessory.valid(.switch, hints.nvrRecordingSwitch, subtype: type) else { continue }
            let service = accessory.acquire(.switch, name: accessoryName + " UFP Recording " + toCamelCase(setting), subtype: type)
            service[.on]?.onRead { [weak self] in .bool(await self?.ufp.json.string("recordingSettings.mode") == setting) }
            service[.on]?.onWrite { @ProtectActor [weak self] value in
                guard let self else { return }
                // Turning one off would leave the mode undefined: put the switches back as Protect has them.
                guard value.boolValue == true else {
                    self.timers.after(ProtectSettings.homeKitUpdateDelay) { [weak self] in self?.updateDevice() }
                    return
                }
                let settings = (self.ufp.json.at("recordingSettings") ?? .object([:])).setting("mode", .string(setting))
                try await self.writeDevice(["recordingSettings": settings], "Unable to set the UniFi Protect recording mode to \(setting).")
                for other in Self.recordingSwitches where other != type {
                    self.accessory.service(.switch, subtype: other)?[.on]?.value = .bool(false)
                }
                self.log.info("UniFi Protect recording mode set to \(setting).")
            }
            service[.on]?.value = .bool(ufp.json.string("recordingSettings.mode") == setting)
            enabled.append(setting)
        }
        if !enabled.isEmpty { log.info("Enabling UniFi Protect recording switches: \(enabled.joined(separator: ", ")).") }
    }

    /// A lock that opens a UniFi Access reader with this camera (`UniFi.Access.Lock`). Protect can only
    /// unlock; the lock goes back to secured a moment later.
    @discardableResult
    private func configureAccessFeatures() -> Bool {
        guard ufp.json.bool("accessDeviceMetadata.featureFlags.supportUnlock") else { return false }
        guard accessory.valid(.lockMechanism, hasFeature("UniFi.Access.Lock"), subtype: ProtectReservedNames.lockAccess) else { return false }
        let service = accessory.acquire(.lockMechanism, name: accessoryName, subtype: ProtectReservedNames.lockAccess)
        service[.lockTargetState]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            if value.intValue == HAPConstants.LockTargetState.secured {
                self.timers.after(ProtectSettings.homeKitUpdateDelay) {
                    service[.lockTargetState]?.value = .int(HAPConstants.LockTargetState.unsecured)
                    service[.lockCurrentState]?.value = .int(HAPConstants.LockCurrentState.unsecured)
                }
                return
            }
            let url = await self.api.endpoint(modelKey: self.ufp.modelKey) + "/" + self.ufp.id + "/unlock"
            guard let response = await self.api.retrieve(url, method: "POST"), response.isSuccess else {
                self.log.error("Unable to unlock. Please ensure this username has the Administrator role in UniFi Protect.")
                throw HAPStatusError(.serviceCommunicationFailure)
            }
        }
        service[.lockTargetState]?.value = .int(HAPConstants.LockTargetState.secured)
        service[.lockCurrentState]?.value = .int(HAPConstants.LockCurrentState.secured)
        return true
    }

    var nightVision: Bool { ufp.json.string("ispSettings.irLedMode") != "off" }

    var nightVisionBrightness: Int {
        let mode = ufp.json.string("ispSettings.irLedMode") ?? ""
        if let level = Self.nightVisionLevels[mode] { return level }
        if mode == "custom" || mode == "customFilterOnly" { return (ufp.json.int("ispSettings.icrCustomValue") ?? 0) * 7 + 20 }
        log.error("Unknown night vision value detected: \(mode).")
        return 0
    }
}
