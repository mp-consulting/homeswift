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
        let excluded = Set((configuration.excludeSensors ?? []).map { $0.lowercased() })
        return excluded.contains(sensor.name.lowercased()) || excluded.contains(sensor.id.lowercased())
    }

    static func shape(of sensor: HueSensorDevice) -> String {
        [sensor.motion != nil ? "m" : "", sensor.temperature != nil ? "t" : "", sensor.lightLevel != nil ? "l" : "",
         sensor.contact != nil ? "c" : "", sensor.battery != nil ? "b" : "", sensor.buttons.map { "\($0.id)=\($0.controlID)" }.joined(separator: ",")]
            .joined(separator: "|")
    }

    /// Shows a sensor device from a read: its values, and a button press the event stream did not report (it was down).
    func show(_ sensor: HueSensorDevice) {
        let shape = Self.shape(of: sensor)
        if let services = sensorAccessories[sensor.id], services.shape == shape {
            services.accessory.isUnavailable = !sensor.reachable
            Self.showValues(sensor, on: services)
            for button in sensor.buttons { noteButton(button, on: services, fire: !streaming) }
            return
        }
        do {
            let services = try addSensor(sensor, shape: shape)
            sensorAccessories[sensor.id] = services
            // What the buttons last reported is where presses start from, not a press.
            for button in sensor.buttons { noteButton(button, on: services, fire: false) }
        } catch {
            logger.error("Could not add \(sensor.name): \(error)")
        }
    }

    /// Fires a button's switch when its report is newer than the last one seen; remembers it either way.
    func noteButton(_ button: HueSensorDevice.Button, on services: SensorServices, fire: Bool) {
        guard let updated = button.updated, buttonReports[button.id] != updated else { return }
        let seenBefore = buttonReports[button.id] != nil
        buttonReports[button.id] = updated
        guard fire, seenBefore, let event = button.event.flatMap(HueSensorDevice.switchEvent) else { return }
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
            service.characteristic(.contactSensorState).value = .int(contact.closed ? 0 : 1)
            service[.statusActive]?.value = .bool(contact.enabled)
        }
        if let battery = sensor.battery, let service = services.battery {
            if let level = battery.level { service[.batteryLevel]?.value = .int(min(max(level, 0), 100)) }
            service.characteristic(.statusLowBattery).value = .int(battery.low ? 1 : 0)
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
            label.characteristic(.serviceLabelNamespace).value = .int(1)
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
            service[.chargingState]?.value = .int(2)
            battery = service
            services.append(service)
        }
        let accessory = Accessory(
            id: Self.sensorAccessoryID(deviceID: sensor.id), name: sensor.name, manufacturer: sensor.manufacturer, model: sensor.model,
            serialNumber: sensor.id, firmwareRevision: sensor.firmware.isEmpty ? "1.0.0" : sensor.firmware,
            category: motion == nil && contact == nil && !buttons.isEmpty ? .programmableSwitch : .sensor, services: services,
            onIdentify: { [client, deviceID = sensor.id] in _ = try? await client?.put("device", id: deviceID, ["identify": ["action": "identify"]]) })
        let built = SensorServices(
            accessory: accessory, motion: motion, temperature: temperature, lightLevel: lightLevel, contact: contact, battery: battery,
            buttons: buttons, shape: shape)
        Self.showValues(sensor, on: built)
        accessory.isUnavailable = !sensor.reachable
        try context.add(accessory)
        return built
    }

    // MARK: The event stream

    /// Follows the bridge's event stream while the plugin runs: a button press fires its switch at once, a sensor's
    /// change shows at once, and any other change (a light, a scene, a device added) reads the bridge again soon. Polls
    /// go on beside it, so a dropped stream only slows things down; it is opened again after a pause.
    func listen() async {
        var pause = Duration.seconds(1)
        while !Task.isCancelled {
            guard let client, stored.applicationKey != nil else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            do {
                let events = try await client.events()
                streaming = true
                pause = .seconds(1)
                for try await event in events { await handle(eventData: event.data) }
            } catch is CancellationError {
                break
            } catch {
                logger.debug("The Hue Bridge's event stream: \(error)")
            }
            streaming = false
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(60))
        }
        streaming = false
    }

    /// One event's data: a JSON array of changes.
    func handle(eventData: String) async {
        guard let changes = try? JSONValue(data: Data(eventData.utf8)).arrayValue else { return }
        var readAgain = false
        for change in changes {
            guard change["type"]?.stringValue == "update" else { readAgain = true; continue }
            for resource in change["data"]?.arrayValue ?? [] {
                if !apply(sensorChange: resource) { readAgain = true }
            }
        }
        if readAgain { scheduleRefresh() }
    }

    /// Takes in a changed part of a sensor's resource; false when it is not a sensor's, for a read of the bridge to show.
    func apply(sensorChange resource: JSONValue) -> Bool {
        guard let rid = resource["id"]?.stringValue,
              let index = snapshot.sensors.firstIndex(where: { sensor in sensor.owns(rid) }) else { return false }
        var sensors = snapshot.sensors
        sensors[index].apply(resource)
        snapshot.sensors = sensors
        let sensor = sensors[index]
        guard let services = sensorAccessories[sensor.id] else { return true }
        if resource["type"]?.stringValue == "button", let button = sensor.buttons.first(where: { $0.id == rid }) {
            noteButton(button, on: services, fire: true)
        } else {
            Self.showValues(sensor, on: services)
        }
        return true
    }

    /// Reads the bridge a moment after a change it reported, once for a burst of them (a scene changes many lights).
    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.runScheduledRefresh()
        }
    }

    private func runScheduledRefresh() async {
        pendingRefresh = nil
        await refresh()
    }
}

extension HueSensorDevice {
    /// Whether the resource `id` is one of this device's services.
    func owns(_ id: String) -> Bool {
        motion?.id == id || temperature?.id == id || lightLevel?.id == id || contact?.id == id || battery?.id == id
            || buttons.contains { $0.id == id }
    }
}
