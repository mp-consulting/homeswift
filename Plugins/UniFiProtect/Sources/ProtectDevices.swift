import Foundation
import Homeswift
import HomeswiftPlugin

/// A Protect chime (`ProtectChime`): a switch for the buzzer and one per ringtone of the controller, each
/// staying on while the chime plays; MQTT `tone/set` with `chime` or `buzzer`.
@ProtectActor
final class ProtectChime: ProtectDevice {
    override init(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) {
        super.init(nvr: nvr, device: device, accessory: accessory)
        configureHints()
        configureDevice()
    }

    private func configureDevice() {
        context = ProtectAccessoryContext(mac: ufp.mac, nvr: nvr.mac)
        configureInfo()
        // Protect 5 moved the volume to the doorbell: an old volume dimmer goes.
        if let legacy = accessory.firstService(.lightbulb) { accessory.remove(legacy) }
        configureChimeSwitch(name: "buzzer", endpoint: "play-buzzer", subtype: ProtectReservedNames.switchDoorbellChimeBuzzer)
        if let legacy = accessory.service(.switch, subtype: ProtectReservedNames.switchDoorbellChimeSpeaker) { accessory.remove(legacy) }
        Task { @ProtectActor [weak self] in await self?.configureRingtoneSwitches() }
        configureMqtt()
    }

    override func cleanup() {
        for endpoint in ["play-buzzer", "play-speaker"] { timers.cancel(id + ".Chime." + endpoint) }
        super.cleanup()
    }

    /// A switch per ringtone of this controller; ringtones that are gone lose theirs.
    func configureRingtoneSwitches() async {
        let ringtones = (await api.bootstrap)?.array("ringtones").filter { $0.string("nvrMac") == nvr.mac } ?? []
        let prefix = ProtectReservedNames.switchDoorbellChimeSpeaker + "."
        for track in ringtones {
            guard let trackID = track.string("id") else { continue }
            configureChimeSwitch(name: track.string("name") ?? trackID, endpoint: "play-speaker", subtype: prefix + trackID)
        }
        for service in accessory.services where service.subtype?.hasPrefix(prefix) == true {
            let toneID = String(service.subtype!.dropFirst(prefix.count))
            if !ringtones.contains(where: { $0.string("id") == toneID }) { accessory.remove(service) }
        }
        await accessory.publish()
    }

    @discardableResult
    private func configureChimeSwitch(name: String, endpoint: String, subtype: String) -> Bool {
        let service = accessory.acquire(.switch, name: accessoryName + " " + toCamelCase(name), subtype: subtype)
        let key = id + ".Chime." + endpoint
        service[.on]?.onRead { [weak self] in .bool(await self?.timers.has(key) ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            // Playing cannot be undone: turning the switch off only puts it back as it is.
            guard value.boolValue == true else {
                self.timers.after(ProtectSettings.homeKitUpdateDelay) { [weak self] in service[.on]?.value = .bool(self?.timers.has(key) ?? false) }
                return
            }
            let prefix = ProtectReservedNames.switchDoorbellChimeSpeaker + "."
            let tone = subtype.hasPrefix(prefix) ? String(subtype.dropFirst(prefix.count)) : nil
            guard await self.playTone(name: name, endpoint: endpoint, tone: tone) else {
                self.log.error("Unable to play \(name).")
                throw HAPStatusError(.serviceCommunicationFailure)
            }
            self.timers.reset(key, after: ProtectSettings.doorbellChimeSpeakerDuration) {
                service[.on]?.value = .bool(false)
            }
            self.log.info("Playing \(name).")
        }
        service[.on]?.value = .bool(false)
        return true
    }

    /// Plays the buzzer, or a ringtone at the volume and repeats it has on this chime.
    func playTone(name: String, endpoint: String, tone: String? = nil) async -> Bool {
        guard !endpoint.isEmpty else { return false }
        var payload: JSONValue = .object([:])
        if let tone {
            let ringSettings = ufp.json.array("ringSettings")
            guard let settings = ringSettings.first(where: { $0.string("ringtoneId") == tone }) ?? ringSettings.first else { return false }
            payload = ["repeatTimes": settings.at("repeatTimes") ?? .null, "ringtoneId": .string(tone), "volume": settings.at("volume") ?? .null]
        }
        let url = await api.endpoint(modelKey: ufp.modelKey) + "/" + ufp.id + "/" + endpoint
        guard let response = await api.retrieve(url, method: "POST", body: payload.encoded()), response.isSuccess else { return false }
        publish("tone", name)
        return true
    }

    private func configureMqtt() {
        subscribeSet("tone", "chime tone") { [weak self] value, _ in
            guard let self else { return }
            switch value {
            case "chime": _ = await self.playTone(name: "chime", endpoint: "play-speaker")
            case "buzzer": _ = await self.playTone(name: "buzzer", endpoint: "play-buzzer")
            default: self.log.error("Unknown chime tone.")
            }
        }
    }

    /// The controller refreshed: ringtones may have changed.
    func updateDevice() async {
        await configureRingtoneSwitches()
    }
}

/// A Protect light (`ProtectLight`): the lightbulb with Protect's six brightness levels, its motion and
/// occupancy sensors, the status light switch, MQTT `light` and `light/brightness`.
@ProtectActor
final class ProtectLight: ProtectDevice {
    /// Protect's LED level 1 to 6 as a HomeKit percentage, 20% a step.
    nonisolated static func ledToPercent(_ level: Int) -> Int { (level - 1) * 20 }
    nonisolated static func percentToLed(_ percent: Int) -> Int { Int((Double(percent) / 20).rounded(.toNearestOrAwayFromZero)) + 1 }

    override init(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) {
        super.init(nvr: nvr, device: device, accessory: accessory)
        configureHints()
        configureDevice()
    }

    private func configureDevice() {
        context = ProtectAccessoryContext(detectMotion: context.detectMotion, mac: ufp.mac, nvr: nvr.mac)
        configureInfo()
        configureLightbulb()
        configureMotionSensor()
        configureOccupancySensor()
        configureStatusLedSwitch()
        configureMqtt()
        subscribe("updateEvent." + ufp.id) { [weak self] packet in self?.eventHandler(packet) }
    }

    private var brightness: Int { Self.ledToPercent(ufp.json.int("lightDeviceSettings.ledLevel") ?? 1) }

    private func configureLightbulb() {
        let service = accessory.acquire(.lightbulb, name: accessoryName, optional: [.brightness])
        service[.on]?.onRead { [weak self] in .bool(await self?.ufp.json.at("isLightOn")?.boolValue == true) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue == true
            try await self.writeDevice(["lightOnSettings": ["isLedForceOn": .bool(on)]],
                "Unable to turn the light \(on ? "on" : "off"). Please ensure this username has the Administrator role in UniFi Protect.")
            self.publish("light", on ? "true" : "false")
        }
        service[.brightness]?.onRead { [weak self] in .int(await self?.brightness ?? 0) }
        service[.brightness]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let level = Self.percentToLed(value.intValue ?? 0)
            try await self.writeDevice(["lightDeviceSettings": ["ledLevel": .number(Double(level))]],
                "Unable to adjust the brightness to \(value.intValue ?? 0)%. Please ensure this username has the Administrator role in UniFi Protect.")
            self.timers.after(ProtectSettings.homeKitUpdateDelay) { service[.brightness]?.value = .int(Self.ledToPercent(level)) }
            self.publish("light/brightness", String(Self.ledToPercent(level)))
        }
        service[.on]?.value = .bool(ufp.json.bool("isLightOn"))
        service[.brightness]?.value = .int(brightness)
    }

    private func configureMqtt() {
        subscribeGet("light", "light status") { [weak self] in String(self?.ufp.json.at("isLightOn")?.boolValue == true) }
        subscribeGet("light/brightness", "light brightness") { [weak self] in String(self?.brightness ?? 0) }
        subscribeSet("light", "light") { [weak self] value, _ in
            try await self?.accessory.firstService(.lightbulb)?[.on]?.write(.bool(value == "true"))
        }
        subscribeSet("light/brightness", "light brightness") { [weak self] value, _ in
            guard let level = Int(value.trimmingCharacters(in: .whitespaces)), (0...100).contains(level) else { return }
            try await self?.accessory.firstService(.lightbulb)?[.brightness]?.write(.int(level))
        }
    }

    private func eventHandler(_ packet: ProtectEventPacket) {
        let payload = packet.payload
        if payload.at("lastMotion")?.isTruthy == true { nvr.events.motionEventHandler(self) }
        if payload.has("isLightOn") { accessory.firstService(.lightbulb)?[.on]?.value = .bool(payload.bool("isLightOn")) }
        if let settings = payload.at("lightDeviceSettings"), settings.isTruthy {
            if let level = settings.int("ledLevel") { accessory.firstService(.lightbulb)?[.brightness]?.value = .int(Self.ledToPercent(level)) }
            if settings.has("isIndicatorEnabled") {
                accessory.service(.switch, subtype: ProtectReservedNames.switchStatusLed)?[.on]?.value = .bool(settings.bool("isIndicatorEnabled"))
            }
        }
    }

    override func statusLedCommand(_ value: Bool) -> JSONValue {
        ["lightDeviceSettings": ["isIndicatorEnabled": .bool(value)]]
    }

    override var statusLed: Bool { ufp.json.bool("lightDeviceSettings.isIndicatorEnabled") }
}

/// A Protect sensor (`ProtectSensor`, the UP Sense and SuperLink sensors): battery, and whichever of the
/// alarm sound, ambient light, contact, humidity, leak (or moisture), motion, occupancy and temperature
/// sensors the device has turned on; each with its connection and tamper state, and MQTT.
@ProtectActor
final class ProtectSensor: ProtectDevice {
    private var enabledSensors: [String] = []
    private var lastAlarm: Bool?
    private var lastLeak: [String: Bool] = [:]

    override init(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) {
        super.init(nvr: nvr, device: device, accessory: accessory)
        configureHints()
        configureDevice()
    }

    private func configureDevice() {
        context = ProtectAccessoryContext(detectMotion: context.detectMotion, mac: ufp.mac, nvr: nvr.mac)
        configureInfo()
        accessory.acquire(.battery, name: accessoryName, optional: [.batteryLevel])
        updateBatteryStatus()
        updateDevice(isInitialized: false)
        configureStatusLedSwitch()
        configureMqtt()
        subscribe("updateEvent." + ufp.id) { [weak self] packet in await self?.eventHandler(packet) }
    }

    /// One of the single-characteristic sensors: kept or removed, its value, state and MQTT topic.
    private struct SimpleSensor {
        var type: ServiceType
        var characteristic: CharacteristicType
        var isEnabled: Bool
        var mqtt: String
        var mqttValue: () -> String
        var name: String?
        var publishIf = true
        var subtype: String?
        var value: () -> HAPValue
    }

    func updateDevice(isInitialized: Bool = true) {
        var current: [String] = []
        updateBatteryStatus()
        if configureSimpleSensor(SimpleSensor(type: .contactSensor, characteristic: .contactSensorState, isEnabled: ufp.json.bool("alarmSettings.isEnabled"),
            mqtt: "alarm", mqttValue: { String(self.alarmDetected) }, name: accessoryName + " Alarm Sound", subtype: ProtectReservedNames.contactSensorAlarmSound,
            value: { .int(self.alarmDetected ? 1 : 0) })) {
            current.append("alarm sound")
        }
        if configureSimpleSensor(SimpleSensor(type: .lightSensor, characteristic: .currentAmbientLightLevel, isEnabled: ufp.json.bool("lightSettings.isEnabled"),
            mqtt: "ambientlight", mqttValue: { ProtectCamera.number(self.ambientLight) },
            value: { .double(max(self.ambientLight, ProtectSettings.homeKitAmbientLightMinimum)) })) {
            current.append("ambient light")
        }
        let mount = ufp.json.string("mountType") ?? ""
        if configureSimpleSensor(SimpleSensor(type: .contactSensor, characteristic: .contactSensorState, isEnabled: !mount.isEmpty && mount != "leak" && mount != "none",
            mqtt: "contact", mqttValue: { String(self.contact) }, subtype: ProtectReservedNames.contactSensor, value: { .int(self.contact ? 1 : 0) })) {
            current.append("contact")
        }
        if configureSimpleSensor(SimpleSensor(type: .humiditySensor, characteristic: .currentRelativeHumidity, isEnabled: ufp.json.bool("humiditySettings.isEnabled"),
            mqtt: "humidity", mqttValue: { ProtectCamera.number(self.humidity) }, value: { .double(self.humidity < 0 ? 0 : self.humidity) })) {
            current.append("humidity")
        }
        if configureLeakSensor() {
            let type = hasFeature("Sensor.MoistureSensor") ? "moisture" : "leak"
            if ufp.json.bool("leakSettings.isInternalEnabled") { current.append(type) }
            if ufp.json.bool("leakSettings.isExternalEnabled") { current.append(type + " (external)") }
        }
        let motionEnabled = ufp.json.bool("motionSettings.isEnabled")
        if configureMotionSensor(isEnabled: motionEnabled, isInitialized: isInitialized, optional: Self.sensorStatus) {
            if let motion = accessory.firstService(.motionSensor) { configureStateCharacteristics(motion) }
            current.append("motion sensor")
        }
        configureOccupancySensor(isEnabled: motionEnabled, isInitialized: isInitialized)
        if configureSimpleSensor(SimpleSensor(type: .temperatureSensor, characteristic: .currentTemperature, isEnabled: ufp.json.bool("temperatureSettings.isEnabled"),
            mqtt: "temperature", mqttValue: { ProtectCamera.number(self.temperature) }, value: { .double(self.temperature) })) {
            current.append("temperature")
        }
        accessory.service(.switch, subtype: ProtectReservedNames.switchStatusLed)?[.on]?.value = .bool(statusLed)
        if enabledSensors != current {
            enabledSensors = current
            if current.isEmpty {
                log.info("No sensors enabled.")
            } else {
                log.info("Enabled sensor\(current.count > 1 ? "s" : ""): \(current.joined(separator: ", ")).")
            }
        }
    }

    private func configureSimpleSensor(_ sensor: SimpleSensor) -> Bool {
        guard accessory.valid(sensor.type, sensor.isEnabled, subtype: sensor.subtype) else { return false }
        let service = accessory.acquire(sensor.type, name: sensor.name, subtype: sensor.subtype, optional: Self.sensorStatus)
        let characteristic = sensor.characteristic
        let subtype = sensor.subtype, type = sensor.type
        service[characteristic]?.onRead { [weak self] in
            guard let self else { return .null }
            return await self.currentValue(type: type, subtype: subtype, characteristic: characteristic)
        }
        service[characteristic]?.value = sensor.value()
        configureStateCharacteristics(service)
        if sensor.publishIf { publish(sensor.mqtt, sensor.mqttValue()) }
        return true
    }

    /// The value a sensor's characteristic reads, from the device's current state.
    private func currentValue(type: ServiceType, subtype: String?, characteristic: CharacteristicType) -> HAPValue {
        switch (type.uuid, subtype) {
        case (ServiceType.lightSensor.uuid, _): .double(max(ambientLight, ProtectSettings.homeKitAmbientLightMinimum))
        case (ServiceType.humiditySensor.uuid, _): .double(humidity < 0 ? 0 : humidity)
        case (ServiceType.temperatureSensor.uuid, _): .double(temperature)
        case (_, ProtectReservedNames.contactSensorAlarmSound): .int(alarmDetected ? 1 : 0)
        case (_, ProtectReservedNames.contactSensor): .int(contact ? 1 : 0)
        case (_, ProtectReservedNames.leakSensorExternal): .int(leakDetected("externalLeakDetectedAt") ? 1 : 0)
        case (_, ProtectReservedNames.leakSensorInternal): .int(leakDetected("leakDetectedAt") ? 1 : 0)
        default: accessory.service(type, subtype: subtype)?[characteristic]?.value ?? .null
        }
    }

    /// Leak sensors, internal and external, or contact sensors with `Sensor.MoistureSensor`.
    private func configureLeakSensor() -> Bool {
        let moisture = hasFeature("Sensor.MoistureSensor")
        let type: ServiceType = moisture ? .contactSensor : .leakSensor
        let other: ServiceType = moisture ? .leakSensor : .contactSensor
        let characteristic: CharacteristicType = moisture ? .contactSensorState : .leakDetected
        var count = 0
        let sensors: [(detected: String, enabled: Bool, mqtt: String, name: String?, subtype: String)] = [
            ("externalLeakDetectedAt", ufp.json.bool("leakSettings.isExternalEnabled"), "leak-external",
             " External " + (moisture ? "Moisture" : "Leak") + " Sensor", ProtectReservedNames.leakSensorExternal),
            ("leakDetectedAt", ufp.json.bool("leakSettings.isInternalEnabled"), "leak", nil, ProtectReservedNames.leakSensorInternal),
        ]
        for sensor in sensors {
            if let old = accessory.service(other, subtype: sensor.subtype) { accessory.remove(old) }
            if configureSimpleSensor(SimpleSensor(type: type, characteristic: characteristic, isEnabled: sensor.enabled, mqtt: sensor.mqtt,
                mqttValue: { String(self.leakDetected(sensor.detected)) }, name: accessoryName + (sensor.name ?? ""), publishIf: ufp.isConnected,
                subtype: sensor.subtype, value: { .int(self.leakDetected(sensor.detected) ? 1 : 0) })) {
                count += 1
            }
        }
        return count > 0
    }

    private func updateBatteryStatus() {
        let battery = accessory.firstService(.battery)
        battery?[.batteryLevel]?.value = .int(ufp.json.int("batteryStatus.percentage") ?? 0)
        battery?[.statusLowBattery]?.value = .int(ufp.json.bool("batteryStatus.isLow") ? 1 : 0)
    }

    private func configureStateCharacteristics(_ service: Service) {
        service[.statusActive]?.onRead { [weak self] in .bool(await self?.isOnline ?? false) }
        service[.statusActive]?.value = .bool(isOnline)
        service[.statusTampered]?.onRead { [weak self] in .int(await self?.isTampered == true ? 1 : 0) }
        service[.statusTampered]?.value = .int(isTampered ? 1 : 0)
    }

    private var isTampered: Bool { ufp.json.isSet("tamperingDetectedAt") }
    var alarmDetected: Bool { ufp.json.isSet("alarmTriggeredAt") }
    var ambientLight: Double { ufp.json.double("stats.light.value") ?? -1 }
    var contact: Bool { ufp.json.bool("isOpened") }
    var humidity: Double { ufp.json.double("stats.humidity.value") ?? -1 }
    var temperature: Double { ufp.json.double("stats.temperature.value") ?? -1 }

    /// Whether a leak is detected, logging changes after the first reading (and a leak at the first).
    func leakDetected(_ key: String = "leakDetectedAt") -> Bool {
        let value = ufp.json.isSet(key)
        if lastLeak[key] == nil, !value {
            lastLeak[key] = value
            return value
        }
        if lastLeak[key] != value {
            lastLeak[key] = value
            log.info("\(hasFeature("Sensor.MoistureSensor") ? "Moisture" : "Leak") \(value ? "" : "no longer ")detected.")
        }
        return value
    }

    private func updateAlarmState() {
        let value = alarmDetected
        guard value != lastAlarm else { return }
        lastAlarm = value
        log.info("Alarm \(value ? "" : "no longer ")detected.")
    }

    private func configureMqtt() {
        subscribeGet("alarm", "alarm detected") { [weak self] in String(self?.alarmDetected ?? false) }
        subscribeGet("ambientlight", "ambient light") { [weak self] in ProtectCamera.number(self?.ambientLight ?? -1) }
        subscribeGet("contact", "contact sensor") { [weak self] in String(self?.contact ?? false) }
        subscribeGet("humidity", "humidity") { [weak self] in ProtectCamera.number(self?.humidity ?? -1) }
        subscribeGet("leak", "leak detected") { [weak self] in String(self?.leakDetected() ?? false) }
        subscribeGet("leak-external", "leak detected") { [weak self] in String(self?.leakDetected("externalLeakDetectedAt") ?? false) }
        subscribeGet("temperature", "temperature") { [weak self] in ProtectCamera.number(self?.temperature ?? -1) }
    }

    private func eventHandler(_ packet: ProtectEventPacket) async {
        if packet.payload.at("motionDetectedAt")?.isTruthy == true { nvr.events.motionEventHandler(self) }
        updateAlarmState()
        updateDevice()
        await accessory.publish()
    }
}

/// A Protect viewport (`ProtectViewer`): a switch per liveview of the controller, the one on screen on.
@ProtectActor
final class ProtectViewer: ProtectDevice {
    static func make(nvr: ProtectNVR, device: JSONValue, accessory: ProtectAccessory) async -> ProtectViewer {
        let viewer = ProtectViewer(nvr: nvr, device: device, accessory: accessory)
        viewer.configureHints()
        await viewer.configureDevice()
        return viewer
    }

    private func configureDevice() async {
        context = ProtectAccessoryContext(mac: ufp.mac, nvr: nvr.mac)
        configureInfo()
        let liveviews = await updateDevice()
        configureMqtt()
        subscribe("updateEvent." + ufp.id) { [weak self] packet in
            if packet.payload.at("liveview")?.isTruthy == true { _ = await self?.updateDevice() }
        }
        if liveviews.isEmpty {
            log.info("No liveviews configured.")
        } else {
            log.info("Configured liveview\(liveviews.count > 1 ? "s" : ""): \(liveviews.joined(separator: ", ")).")
        }
    }

    /// Adds and removes liveview switches to match the controller, and shows which one is on. Returns the
    /// liveviews it has switches for.
    @discardableResult
    func updateDevice() async -> [String] {
        let liveviews = ((await api.bootstrap)?.array("liveviews") ?? []).map(ProtectLiveview.init)
        cachedLiveviews = liveviews
        let ids = liveviews.map(\.id)
        for service in accessory.services(.switch) where service.subtype != nil && !ids.contains(service.subtype!) {
            accessory.remove(service)
        }
        for liveview in liveviews where !liveview.id.isEmpty && accessory.service(.switch, subtype: liveview.id) == nil {
            let service = accessory.acquire(.switch, name: liveview.name, subtype: liveview.id)
            let id = liveview.id, name = service[.name]?.value.stringValue ?? liveview.name
            service[.on]?.onRead { [weak self] in .bool(await self?.currentLiveview == id) }
            service[.on]?.onWrite { @ProtectActor [weak self] value in
                guard let self else { return }
                let target: String? = value.boolValue == true ? id : nil
                try await self.setViewer(target, errorMessage: target != nil ? "Unable to set the liveview to: \(name)." : "Unable to clear the liveview.")
                self.updateSwitchStates()
            }
        }
        updateSwitchStates()
        await accessory.publish()
        return accessory.services(.switch).compactMap { $0.subtype != nil ? $0[.name]?.value.stringValue : nil }
    }

    private var currentLiveview: String? { ufp.json.string("liveview") }

    private func updateSwitchStates() {
        for service in accessory.services(.switch) where service.subtype != nil {
            service[.on]?.value = .bool(service.subtype == currentLiveview)
        }
    }

    /// Shows a liveview on the viewport, or clears it; publishes its name on MQTT.
    func setViewer(_ liveview: String?, errorMessage: String) async throws {
        try await writeDevice(["liveview": liveview.map { .string($0) } ?? .null], errorMessage)
        if let name = (await api.bootstrap)?.array("liveviews").map(ProtectLiveview.init).first(where: { $0.id == liveview })?.name {
            publish("liveview", name)
        }
    }

    private func configureMqtt() {
        subscribeGet("liveview", "liveview") { [weak self] in
            self?.liveviewName ?? "None"
        }
        subscribeSet("liveview", "liveview") { [weak self] value, _ in
            guard let self else { return }
            let liveviews = ((await self.api.bootstrap)?.array("liveviews") ?? []).map(ProtectLiveview.init)
            guard let liveview = liveviews.first(where: { $0.name.lowercased() == value }) else {
                self.log.error("Unable to locate a liveview named \(value).")
                return
            }
            do {
                try await self.setViewer(liveview.id, errorMessage: "Unable to set liveview via MQTT to \(value).")
            } catch {
                return
            }
            self.log.info("Liveview set via MQTT to \(liveview.name).")
        }
    }

    private var cachedLiveviews: [ProtectLiveview] = []

    private var liveviewName: String? {
        cachedLiveviews.first { $0.id == currentLiveview }?.name
    }
}
