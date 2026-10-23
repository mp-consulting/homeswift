import Foundation
import Homeswift
import HomeswiftPlugin

/// The sensors of a camera (`ProtectCameraSensors`): a contact sensor per smart detection type and per
/// licence plate, tamper detection on the motion sensor, and the ambient light sensor.
extension ProtectCamera {
    func configureSensors() {
        configureSmartSensors()
        configureTamperDetection()
    }

    /// The plates of `Motion.SmartDetect.ObjectSensors.LicensePlate`, separated by hyphens, upper-cased.
    nonisolated static func parseLicensePlates(_ value: String?) -> [String] {
        (value ?? "").split(separator: "-", omittingEmptySubsequences: true).map { $0.uppercased() }.filter { !$0.isEmpty }
    }

    /// The ambient light sensor of cameras with a lux sensor, polled every minute.
    @discardableResult
    func configureAmbientLight() async -> Bool {
        guard ufp.feature("hasLuxCheck") else { return false }
        let service = accessory.acquire(.lightSensor, name: accessoryName, optional: [.statusActive])
        service[.statusActive]?.onRead { [weak self] in .bool(await self?.isOnline ?? false) }
        ambientLightTimer?.cancel()
        let interval = timers.duration(milliseconds: ProtectSettings.ambientLightPollInterval)
        ambientLightTimer = Task { @ProtectActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.pollLux()
            }
        }
        ambientLight = await getLux()
        if ambientLight == -1 { ambientLight = ProtectSettings.homeKitAmbientLightMinimum }
        service[.currentAmbientLightLevel]?.onRead { [weak self] in .double(await self?.ambientLight ?? ProtectSettings.homeKitAmbientLightMinimum) }
        service[.currentAmbientLightLevel]?.value = .double(ambientLight)
        service[.statusActive]?.value = .bool(isOnline)
        return true
    }

    /// The camera's illuminance, at least HomeKit's minimum; -1 when it cannot be read.
    func getLux() async -> Double {
        guard isOnline else { return -1 }
        let url = await api.endpoint(modelKey: ufp.modelKey) + "/" + ufp.id + "/lux"
        guard let response = await api.retrieve(url), response.isSuccess else { return -1 }
        guard let json = try? JSONValue(data: response.body) else { return -1 }
        let lux = json.double("illuminance") ?? 0
        return lux == 0 ? ProtectSettings.homeKitAmbientLightMinimum : lux
    }

    private func pollLux() async {
        let lux = await getLux()
        guard lux != ambientLight, lux != -1 else { return }
        ambientLight = lux
        accessory.firstService(.lightSensor)?[.currentAmbientLightLevel]?.value = .double(lux)
        publish("ambientlight", Self.number(lux))
    }

    nonisolated static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// Contact sensors for each smart detection type (`Motion.SmartDetect.ObjectSensors`) and for each
    /// configured licence plate.
    private func configureSmartSensors() {
        detectLicensePlate = Self.parseLicensePlates(getFeatureValue("Motion.SmartDetect.ObjectSensors.LicensePlate"))
        let platePrefix = ProtectReservedNames.contactMotionSmartDetectLicense + "."
        for service in accessory.services where service.subtype?.hasPrefix(platePrefix) == true {
            let plate = String(service.subtype!.dropFirst(platePrefix.count))
            if ufp.feature("hasSmartDetect"), ufp.smartDetectTypes.contains("licensePlate"), detectLicensePlate.contains(plate) { continue }
            accessory.remove(service)
            log.info("Disabling smart motion license plate contact sensor: \(plate).")
        }
        if !hints.smartDetectSensors {
            let prefix = ProtectReservedNames.contactMotionSmartDetect + "."
            for service in accessory.services where service.subtype?.hasPrefix(prefix) == true {
                accessory.remove(service)
                log.info("Disabling smart motion contact sensor: \(service.subtype!.dropFirst(prefix.count)).")
            }
        }
        guard ufp.feature("hasSmartDetect") else { return }
        let addSensor: (String, String) -> Bool = { name, subtype in
            let service = self.accessory.acquire(.contactSensor, name: name, subtype: subtype)
            service[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
            return true
        }
        if hints.smartDetectSensors {
            var enabled: [String] = []
            for type in (ufp.smartDetectAudioTypes + ufp.smartDetectTypes).sorted()
            where addSensor(accessoryName + " " + toCamelCase(type), ProtectReservedNames.contactMotionSmartDetect + "." + type) {
                enabled.append(type)
            }
            log.info("Smart motion contact sensor\(enabled.count > 1 ? "s" : "") enabled: \(enabled.joined(separator: ", ")).")
        }
        if ufp.smartDetectTypes.contains("licensePlate") {
            var enabled: [String] = []
            for plate in detectLicensePlate where addSensor(accessoryName + " License Plate " + plate, platePrefix + plate) {
                enabled.append(plate)
            }
            if !enabled.isEmpty {
                log.info("Smart motion license plate contact sensor\(enabled.count > 1 ? "s" : "") enabled: \(enabled.joined(separator: ", ")).")
            }
        }
    }

    /// Tamper detection shows on the motion sensor when the camera has it and it is on.
    @discardableResult
    func configureTamperDetection() -> Bool {
        guard let motion = accessory.firstService(.motionSensor) else {
            if !hasTamperDetection { isTampered = false }
            return hasTamperDetection
        }
        guard hasTamperDetection else {
            accessory.reshape(motion, removing: [.statusTampered])
            isTampered = false
            return false
        }
        let service = accessory.reshape(motion, adding: [.statusTampered])
        service[.statusTampered]?.onRead { [weak self] in .int(await self?.isTampered == true ? 1 : 0) }
        return true
    }

    func updateSensors() {
        let motion = accessory.firstService(.motionSensor)
        motion?[.statusActive]?.value = .bool(isOnline)
        motion?[.statusTampered]?.value = .int(isTampered ? 1 : 0)
        accessory.firstService(.lightSensor)?[.statusActive]?.value = .bool(isOnline)
    }

    func cleanupSensors() {
        ambientLightTimer?.cancel()
        ambientLightTimer = nil
    }
}
