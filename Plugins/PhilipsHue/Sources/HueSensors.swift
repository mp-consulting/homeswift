import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// A sensor device's services on its accessory.
    struct SensorServices {
        let accessory: Accessory
        let motion: Service?
        let temperature: Service?
        let lightLevel: Service?
        let contact: Service?
        let battery: Service?
        /// By the button resource's id.
        let buttons: [String: Service]
        /// The services it was built for: a device that gains or loses one is rebuilt.
        let shape: String
    }

    static func sensorAccessoryID(deviceID: String) -> String { "\(platform):device:\(deviceID)" }

    func isExcluded(_ sensor: HueSensorDevice) -> Bool {
        excludedSensors.contains(sensor.name.lowercased()) || excludedSensors.contains(sensor.id.lowercased())
    }

    static func shape(of sensor: HueSensorDevice) -> String {
        [sensor.motion != nil ? "m" : "", sensor.temperature != nil ? "t" : "", sensor.lightLevel != nil ? "l" : "",
         sensor.contact != nil ? "c" : "", sensor.battery != nil ? "b" : "", sensor.buttons.map { "\($0.id)=\($0.controlID)" }.joined(separator: ",")]
            .joined(separator: "|")
    }

    /// Shows a sensor device from a read: its values, and a button press the event stream did not report.
    func show(_ sensor: HueSensorDevice) {
        let shape = Self.shape(of: sensor)
        if let services = sensorAccessories[sensor.id], services.shape == shape {
            services.accessory.isUnavailable = !sensor.reachable
            Self.showValues(sensor, on: services)
            for button in sensor.buttons { noteButton(button, on: services) }
            return
        }
        do {
            sensorAccessories[sensor.id] = try addSensor(sensor, shape: shape)
            // What the buttons last reported is where presses start from, not a press.
            for button in sensor.buttons where buttonReports[button.id] == nil { buttonReports[button.id] = button.updated ?? "" }
        } catch {
            logger.error("Could not add \(sensor.name): \(error)")
        }
    }

    /// Fires a button's switch for a report newer than the last one seen, from the stream or a read, whichever sees it
    /// first; a read that started before a press and lands after it carries the older report, which fires nothing. The
    /// bridge's ISO 8601 times sort as text.
    func noteButton(_ button: HueSensorDevice.Button, on services: SensorServices) {
        guard let updated = button.updated, let last = buttonReports[button.id], updated > last else { return }
        buttonReports[button.id] = updated
        guard let event = button.event.flatMap(HueSensorDevice.switchEvent) else { return }
        services.buttons[button.id]?.characteristic(.programmableSwitchEvent).sendEvent(.int(event))
    }

    static func showValues(_ sensor: HueSensorDevice, on services: SensorServices) {
        if let motion = sensor.motion, let service = services.motion {
            service.characteristic(.motionDetected).value = .bool(motion.detected)
            service[.statusActive]?.value = .bool(motion.enabled)
        }
        if let temperature = sensor.temperature, let service = services.temperature {
            service.characteristic(.currentTemperature).value = .double((temperature.celsius * 10).rounded() / 10)
            service[.statusActive]?.value = .bool(temperature.enabled)
        }
        if let level = sensor.lightLevel, let service = services.lightLevel {
            service.characteristic(.currentAmbientLightLevel).value = .double(level.lux)
            service[.statusActive]?.value = .bool(level.enabled)
        }
        if let contact = sensor.contact, let service = services.contact {
            service.characteristic(.contactSensorState).value = .int(contact.closed ? HAPConstants.ContactSensorState.contactDetected : HAPConstants.ContactSensorState.contactNotDetected)
            service[.statusActive]?.value = .bool(contact.enabled)
        }
        if let battery = sensor.battery, let service = services.battery {
            if let level = battery.level { service[.batteryLevel]?.value = .int(min(max(level, 0), 100)) }
            service.characteristic(.statusLowBattery).value = .int(battery.low ? HAPConstants.StatusLowBattery.batteryLevelLow : HAPConstants.StatusLowBattery.batteryLevelNormal)
        }
    }

    /// A sensor service with its name shown in the Home app, and whether the sensor is enabled on the bridge.
    static func sensorService(_ type: ServiceType, _ name: String, subtype: String, optional: [CharacteristicType] = [], isPrimary: Bool) -> Service {
        let service = Service(type, name: name, subtype: subtype, optional: optional + [.statusActive, .configuredName], isPrimary: isPrimary)
        service[.configuredName]?.value = .string(name)
        return service
    }

    private func addSensor(_ sensor: HueSensorDevice, shape: String) throws -> SensorServices {
        let motion = sensor.motion.map { _ in Self.sensorService(.motionSensor, sensor.name, subtype: "motion", isPrimary: true) }
        let contact = sensor.contact.map { _ in Self.sensorService(.contactSensor, sensor.name, subtype: "contact", isPrimary: motion == nil) }
        let leading = motion == nil && contact == nil
        // An outdoor sensor reads below zero, which HomeKit's default range for the characteristic leaves out.
        let temperature = sensor.temperature.map { _ in
            Self.sensorService(
                .temperatureSensor, "\(sensor.name) Temperature", subtype: "temperature",
                optional: [.currentTemperature.with(minValue: -50, maxValue: 100)], isPrimary: leading && sensor.buttons.isEmpty)
        }
        let lightLevel = sensor.lightLevel.map { _ in
            Self.sensorService(.lightSensor, "\(sensor.name) Light", subtype: "light", isPrimary: leading && sensor.buttons.isEmpty && temperature == nil)
        }
        var services = [motion, contact, temperature, lightLevel].compactMap { $0 }
        var buttons: [String: Service] = [:]
        if !sensor.buttons.isEmpty {
            // The label service says how the buttons are numbered: 1, 2, 3… as the Home app lists them.
            let label = Service(.serviceLabel, subtype: "buttons")
            label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
            for button in sensor.buttons {
                let name = sensor.buttons.count == 1 ? sensor.name : "Button \(button.controlID)"
                let service = Service(
                    .statelessProgrammableSwitch, name: name, subtype: "button:\(button.controlID)",
                    optional: [.serviceLabelIndex, .configuredName], isPrimary: leading && button.controlID == sensor.buttons.first?.controlID)
                service[.serviceLabelIndex]?.value = .int(min(max(button.controlID, 1), 255))
                service[.configuredName]?.value = .string(name)
                buttons[button.id] = service
                services.append(service)
            }
            services.append(label)
        }
        var battery: Service?
        if sensor.battery != nil {
            let service = Service(.battery, subtype: "battery", optional: [.batteryLevel, .chargingState])
            service[.chargingState]?.value = .int(HAPConstants.ChargingState.notChargeable)
            battery = service
            services.append(service)
        }
        let accessory = Accessory(
            id: Self.sensorAccessoryID(deviceID: sensor.id), name: sensor.name, manufacturer: sensor.manufacturer, model: sensor.model,
            serialNumber: sensor.id, firmwareRevision: sensor.firmware.isEmpty ? "1.0.0" : sensor.firmware,
            category: motion == nil && contact == nil && !buttons.isEmpty ? .programmableSwitch : .sensor, services: services,
            onIdentify: { [client, deviceID = sensor.id] in try? await client?.identify(deviceID: deviceID) })
        let built = SensorServices(
            accessory: accessory, motion: motion, temperature: temperature, lightLevel: lightLevel, contact: contact, battery: battery,
            buttons: buttons, shape: shape)
        Self.showValues(sensor, on: built)
        accessory.isUnavailable = !sensor.reachable
        try context.add(accessory)
        return built
    }

    // MARK: The event stream

    /// Follows the bridge's event stream while the plugin runs: a button press fires its switch, a sensor's or a light's
    /// change shows at once, and what an event does not carry whole (a scene's status, a device added or removed) reads
    /// the bridge again soon. While it is open, polls slow to a safety net; it is opened again after a pause.
    func listen() async {
        let backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: .proportional(0.2))
        var failures = 0
        while !Task.isCancelled {
            guard let client, stored.applicationKey != nil else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            do {
                let events = try await client.events()
                streaming = true
                failures = 0
                for try await event in events { handle(eventData: event.data) }
            } catch is CancellationError {
                break
            } catch {
                logger.debug("The Hue Bridge's event stream: \(error)")
            }
            streaming = false
            try? await Task.sleep(for: backoff.delay(attempt: failures))
            failures += 1
        }
        streaming = false
    }

    /// One event's data: a JSON array of changes.
    func handle(eventData: String) {
        guard let changes = try? JSONValue(data: Data(eventData.utf8)).arrayValue else { return }
        var readAgain = false
        for change in changes {
            guard change["type"]?.stringValue == "update" else { readAgain = true; continue }
            for resource in change["data"]?.arrayValue ?? [] where !apply(change: resource) { readAgain = true }
        }
        if readAgain { scheduleRefresh() }
    }

    /// Takes in a changed part of a sensor's, a light's or a room's resource and shows it; false for any other, which a
    /// read of the bridge shows.
    func apply(change resource: JSONValue) -> Bool {
        guard let rid = resource["id"]?.stringValue else { return false }
        switch resource["type"]?.stringValue {
        case "light":
            guard let index = snapshot.lights.firstIndex(where: { $0.id == rid }) else { return false }
            snapshot.lights[index].apply(resource)
            let light = snapshot.lights[index]
            Task { await show(light) }
            return true
        case "grouped_light":
            guard let index = snapshot.groups.firstIndex(where: { $0.groupedLightID == rid }) else { return false }
            if let on = resource["on"]?["on"]?.boolValue { snapshot.groups[index].on = on }
            if let level = resource["dimming"]?["brightness"]?.doubleValue { snapshot.groups[index].brightness = level }
            // A room switched on or off changes which of its scenes is on: the read shows those.
            if resource["on"] != nil { return false }
            showRoomLight(snapshot.groups[index])
            return true
        default:
            guard let index = snapshot.sensorOfService[rid], snapshot.sensors.indices.contains(index) else { return false }
            snapshot.sensors[index].apply(resource)
            let sensor = snapshot.sensors[index]
            guard let services = sensorAccessories[sensor.id] else { return true }
            if resource["type"]?.stringValue == "button", let button = sensor.buttons.first(where: { $0.id == rid }) {
                noteButton(button, on: services)
            } else {
                Self.showValues(sensor, on: services)
            }
            return true
        }
    }

    /// Reads the bridge a moment after a change it reported, once for a burst of them (a scene changes many lights):
    /// events during the read join it rather than start another.
    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.runScheduledRefresh()
        }
    }

    private func runScheduledRefresh() async {
        await refresh()
        pendingRefresh = nil
    }
}
