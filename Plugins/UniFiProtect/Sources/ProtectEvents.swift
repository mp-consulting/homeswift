import Foundation
import Homeswift
import HomeswiftPlugin

/// The realtime events of a controller (`ProtectEvents`): keeps each device's JSON current, adds and
/// removes adopted devices, routes packets to the devices that subscribed (`updateEvent.<id>`,
/// `addEvent.<cameraId>`, …), and delivers motion, smart detection, occupancy and doorbell rings to HomeKit
/// and MQTT with their reset timers.
@ProtectActor
final class ProtectEvents {
    typealias Handler = @ProtectActor (ProtectEventPacket) async -> Void

    private unowned let nvr: ProtectNVR
    private var listeners: [String: [(token: Int, handler: Handler)]] = [:]
    private var nextToken = 0
    private let publishTelemetry: Bool
    /// What the controller told us of each device since the last bootstrap, for adoptions.
    private var deviceState: [String: JSONValue] = [:]

    /// A smart detection: an object type, with what the thumbnail adds for vehicles.
    struct SmartEvent: Sendable {
        var type: String
        var name: String?
        var confidence: Double?
        var payload: JSONValue?
    }

    init(nvr: ProtectNVR) {
        self.nvr = nvr
        publishTelemetry = nvr.featureOptions.test("Nvr.Publish.Telemetry", device: nil, controllers: [nvr.config.address])
        if publishTelemetry { nvr.log.info("Protect controller telemetry enabled.") }
    }

    private var timers: ProtectTimers { nvr.timers }

    // MARK: Subscriptions

    @discardableResult
    func on(_ event: String, _ handler: @escaping Handler) -> Int {
        nextToken += 1
        listeners[event, default: []].append((nextToken, handler))
        return nextToken
    }

    func off(_ event: String, token: Int) {
        listeners[event]?.removeAll { $0.token == token }
        if listeners[event]?.isEmpty == true { listeners[event] = nil }
    }

    private func emit(_ event: String, _ packet: ProtectEventPacket) async {
        for (_, handler) in listeners[event] ?? [] { await handler(packet) }
    }

    /// Routes a packet: our own bookkeeping first, then the subscribers.
    func handle(_ packet: ProtectEventPacket) async {
        switch packet.action {
        case "add":
            await manageDevices(packet)
            await emit("addEvent", packet)
            if let cameraID = packet.payload.string("camera") ?? packet.payload.string("cameraId") { await emit("addEvent." + cameraID, packet) }
            await emit("addEvent." + packet.modelKey, packet)
        case "remove":
            await emit("removeEvent", packet)
            await emit("removeEvent." + packet.id, packet)
            await emit("removeEvent." + packet.modelKey, packet)
        case "update":
            ufpUpdates(packet)
            await emit("updateEvent", packet)
            await emit("updateEvent." + packet.id, packet)
            await emit("updateEvent." + packet.modelKey, packet)
            if let recordID = packet.header.string("recordId") { await emit("updateEvent." + recordID, packet) }
        default:
            break
        }
        if publishTelemetry, let text = String(data: JSONValue.object(["header": packet.header, "payload": packet.payload]).encoded(), encoding: .utf8) {
            nvr.publish(nvr.mac, "telemetry", text)
        }
    }

    /// Merges an update into the JSON of the NVR or the device; a bootstrap refresh replaces it whole.
    func ufpUpdates(_ packet: ProtectEventPacket) {
        let payload = packet.payload
        switch packet.modelKey {
        case "nvr":
            nvr.ufp = nvr.ufp.merging(payload)
        default:
            guard let device = nvr.getDevice(id: packet.id) else { break }
            let isBootstrap = packet.header.bool("hbupBootstrap")
            device.ufp = ProtectDeviceConfig(isBootstrap ? payload : device.ufp.json.merging(payload))
            if payload.has("isConnected") {
                for service in device.accessory.services {
                    service[.statusActive]?.value = .bool(device.isOnline)
                }
            }
            guard !isBootstrap else { break }
            if payload.string("name") != nil, device.hints.syncName {
                device.log.info("Name change detected. A restart of Homeswift may be needed in order to complete name synchronization with HomeKit.")
                device.configureInfo()
                Task { await device.accessory.publish() }
            }
        }
        if ProtectNVR.deviceCategories.contains(packet.modelKey) {
            deviceState[packet.id] = (deviceState[packet.id] ?? .object([:])).shallowMerged(payload)
        }
    }

    /// Adoptions and unadoptions announced by the events list.
    private func manageDevices(_ packet: ProtectEventPacket) async {
        let payload = packet.payload
        guard packet.modelKey == "event", let type = payload.string("type"), type == "deviceAdopted" || type == "deviceUnadopted" else { return }
        guard let deviceID = payload.string("metadata.deviceId.text") else { return }
        let device = nvr.getDevice(id: deviceID)
        let state = deviceState.removeValue(forKey: deviceID)
        if type == "deviceAdopted" {
            guard device == nil, let state else { return }
            await nvr.addHomeKitDevice(state)
            return
        }
        guard let device else { return }
        await nvr.removeHomeKitDevice(id: device.accessory.id)
    }

    // MARK: Motion

    /// A motion event of a device, with the smart detections that caused it.
    func motionEventHandler(_ device: ProtectDevice, detectedObjects: [String] = [], metadata: JSONValue? = nil) {
        guard let motionService = device.accessory.firstService(.motionSensor) else { return }
        guard device.context.detectMotion != false else { return }
        handleMotionEvent(device, motionService)
        var smartEvents: [SmartEvent] = []
        if device.hints.smartDetect {
            smartEvents += detectedObjects.map { SmartEvent(type: $0) }
            for thumbnail in metadata?.array("detectedThumbnails") ?? [] {
                guard let type = thumbnail.string("type"), !type.isEmpty else { continue }
                smartEvents.append(SmartEvent(type: type, name: thumbnail.string("name"), confidence: thumbnail.double("confidence"), payload: thumbnail))
            }
        }
        handleSmartDetection(device, smartEvents)
        handleOccupancy(device, detectedObjects)
    }

    private func handleMotionEvent(_ device: ProtectDevice, _ motionService: Service) {
        let key = device.id
        if !timers.has(key) {
            motionService[.motionDetected]?.value = .bool(true)
            device.accessory.service(.switch, subtype: ProtectReservedNames.switchMotionTrigger)?[.on]?.value = .bool(true)
            nvr.publish(device.ufp.mac, "motion", "true")
            if device.hints.logMotion { device.log.info("Motion detected.") }
        }
        timers.reset(key, after: device.hints.motionDuration * 1000) { [weak self, weak device] in
            guard let self, let device else { return }
            motionService[.motionDetected]?.value = .bool(false)
            device.accessory.service(.switch, subtype: ProtectReservedNames.switchMotionTrigger)?[.on]?.value = .bool(false)
            device.log.debug("Resetting motion event.")
            self.nvr.publish(device.ufp.mac, "motion", "false")
        }
    }

    private func handleSmartDetection(_ device: ProtectDevice, _ smartEvents: [SmartEvent]) {
        for event in smartEvents {
            let key = device.id + ".Motion.SmartDetect.ObjectSensors." + event.type
            let subtype = ProtectReservedNames.contactMotionSmartDetect + "." + event.type
            if !timers.has(key) {
                device.accessory.service(.contactSensor, subtype: subtype)?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactNotDetected)
                nvr.publish(device.ufp.mac, "motion/smart/" + event.type, "true")
                if device.hints.logMotion, event.type != "vehicle" { device.log.info("Smart motion detected: \(event.type).") }
            }
            timers.reset(key, after: device.hints.motionDuration * 1000) { [weak self, weak device] in
                guard let self, let device else { return }
                device.accessory.service(.contactSensor, subtype: subtype)?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
                self.nvr.publish(device.ufp.mac, "motion/smart/" + event.type, "false")
                device.log.debug("Resetting smart object motion event.")
            }
            if event.type == "vehicle" { handleLicensePlate(device, event, key: key) }
        }
    }

    private func handleLicensePlate(_ device: ProtectDevice, _ event: SmartEvent, key: String) {
        if let name = event.name, !name.isEmpty {
            let plate = name.uppercased()
            let plateKey = key + "." + plate
            let subtype = ProtectReservedNames.contactMotionSmartDetectLicense + "." + plate
            if !timers.has(plateKey) {
                device.accessory.service(.contactSensor, subtype: subtype)?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactNotDetected)
            }
            timers.reset(plateKey, after: device.hints.motionDuration * 1000) { [weak device] in
                device?.accessory.service(.contactSensor, subtype: subtype)?[.contactSensorState]?.value = .int(HAPConstants.ContactSensorState.contactDetected)
            }
        }
        guard device.hints.logMotion else { return }
        var attributes: [String] = []
        func percent(_ value: Double?) -> String {
            guard let value else { return "undefined" }
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
        if let name = event.name, !name.isEmpty { attributes.append("license plate: \(name) [\(percent(event.confidence))% confidence]") }
        for attribute in ["color", "vehicleType"] {
            if let detail = event.payload?.at("attributes.\(attribute)"), detail.isTruthy {
                attributes.append("\(attribute): \(detail.at("val").map { $0.stringValue ?? $0.text() } ?? "") [\(percent(detail.double("confidence")))% confidence]")
            }
        }
        if !attributes.isEmpty {
            var metadata: [String: JSONValue] = ["type": .string(event.type)]
            if let confidence = event.confidence, confidence.isFinite { metadata["confidence"] = .number(confidence) }
            if let name = event.name, !name.isEmpty { metadata["name"] = .string(name) }
            if let color = event.payload?.at("attributes.color"), color.isTruthy { metadata["color"] = color }
            if let vehicleType = event.payload?.at("attributes.vehicleType"), vehicleType.isTruthy { metadata["vehicleType"] = vehicleType }
            nvr.publish(device.ufp.mac, "motion/smart/\(event.type)/metadata", JSONValue.object(metadata).text())
        }
        device.log.info("Smart motion detected: \(event.type)\(attributes.isEmpty ? "" : " (" + attributes.joined(separator: ", ") + ")").")
    }

    private func handleOccupancy(_ device: ProtectDevice, _ detectedObjects: [String]) {
        guard !device.hints.smartDetect || detectedObjects.contains(where: { device.hints.smartOccupancy.contains($0) }) else { return }
        guard let occupancy = device.accessory.firstService(.occupancySensor) else { return }
        let key = device.id + ".Motion.OccupancySensor"
        if occupancy[.occupancyDetected]?.value.intValue != HAPConstants.OccupancyDetected.occupancyDetected {
            occupancy[.occupancyDetected]?.value = .int(HAPConstants.OccupancyDetected.occupancyDetected)
            nvr.publish(device.ufp.mac, "occupancy", "true")
            if device.hints.logMotion {
                device.log.info("Occupancy detected\(device.hints.smartDetect ? ": " + device.hints.smartOccupancy.filter { detectedObjects.contains($0) }.joined(separator: ", ") : "").")
            }
        }
        timers.reset(key, after: device.hints.occupancyDuration * 1000) { [weak self, weak device] in
            guard let self, let device else { return }
            occupancy[.occupancyDetected]?.value = .int(HAPConstants.OccupancyDetected.occupancyNotDetected)
            self.nvr.publish(device.ufp.mac, "occupancy", "false")
            if device.hints.logMotion { device.log.info("Occupancy no longer detected.") }
        }
    }

    // MARK: Doorbell

    /// A ring: the doorbell's programmable switch (unless muted), the trigger switch, MQTT, and the ring delay.
    func doorbellEventHandler(_ camera: ProtectCamera, lastRing: Double?) {
        guard let lastRing, lastRing != 0 else { return }
        guard !timers.has(camera.id + ".Doorbell.Ring") else { return }
        guard let doorbell = camera.accessory.firstService(.doorbell) else { return }
        if camera.context.doorbellMuted != true {
            doorbell[.programmableSwitchEvent]?.sendEvent(.int(HAPConstants.ProgrammableSwitchEvent.singlePress))
        }
        if let trigger = camera.accessory.service(.switch, subtype: ProtectReservedNames.switchDoorbellTrigger) {
            camera.isRinging = true
            trigger[.on]?.value = .bool(true)
            timers.reset(camera.id + ".Doorbell.Ring.Trigger", after: ProtectSettings.doorbellTriggerDuration) { [weak self, weak camera] in
                camera?.isRinging = false
                trigger[.on]?.value = .bool(false)
                self?.nvr.log.debug("Resetting doorbell ring trigger.")
            }
        }
        nvr.publish(camera.ufp.mac, "doorbell", "true")
        if camera.hints.logDoorbell { camera.log.info("Doorbell ring detected.") }
        timers.reset(camera.id + ".Doorbell.Ring.MQTT", after: ProtectSettings.doorbellTriggerDuration) { [weak self, weak camera] in
            guard let camera else { return }
            self?.nvr.publish(camera.ufp.mac, "doorbell", "false")
        }
        let ringDelay = nvr.platform.configuration.ringDelay
        guard ringDelay > 0 else { return }
        timers.reset(camera.id + ".Doorbell.Ring", after: ringDelay * 1000) {}
    }
}

extension JSONValue {
    /// `Object.assign`: the keys of `other` replace ours, one level only.
    func shallowMerged(_ other: JSONValue) -> JSONValue {
        guard case .object(var result) = self else { return other }
        for (key, value) in other.objectValue ?? [:] { result[key] = value }
        return .object(result)
    }
}
