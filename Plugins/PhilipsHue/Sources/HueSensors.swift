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
        /// A Tap dial's ring: a switch per direction.
        let clockwise: Service?
        let anticlockwise: Service?
        /// Eve's history of the motion, temperature and light level (fakegato's custom kind), on a sensor that has one.
        let history: EveHistory?
        /// The services it was built for: a device that gains or loses one is rebuilt.
        let shape: String
    }

    static func sensorAccessoryID(deviceID: String) -> String { "\(platform):device:\(deviceID)" }

    /// Excluded by its Accessory Settings (`device:<id>`), or left out by `excludeSensors`.
    func isExcluded(_ sensor: HueSensorDevice) -> Bool {
        context.isExcluded(Self.sensorDeviceID(sensor.id)) || isListed(sensor)
    }

    /// Left out by the Homebridge-shaped `excludeSensors`, by name or device id.
    func isListed(_ sensor: HueSensorDevice) -> Bool {
        excludedSensors.contains(sensor.name.lowercased()) || excludedSensors.contains(sensor.id.lowercased())
    }

    static func shape(of sensor: HueSensorDevice) -> String {
        [sensor.motion != nil ? "m" : "", sensor.temperature != nil ? "t" : "", sensor.lightLevel != nil ? "l" : "",
         sensor.contact != nil ? "c" : "", sensor.battery != nil ? "b" : "", sensor.buttons.map { "\($0.id)=\($0.controlID)" }.joined(separator: ","), sensor.rotary != nil ? "r" : ""]
            .joined(separator: "|")
    }

    /// Shows a sensor device from a read: its values, and a button press the event stream did not report.
    func show(_ sensor: HueSensorDevice) {
        let shape = Self.shape(of: sensor)
        if let services = sensorAccessories[sensor.id], services.shape == shape {
            services.accessory.isUnavailable = !sensor.reachable
            Self.showValues(sensor, on: services)
            record(sensor, on: services)
            for button in sensor.buttons { noteButton(button, on: services) }
            if let rotary = sensor.rotary { noteRotary(rotary, on: services) }
            return
        }
        do {
            sensorAccessories[sensor.id] = try addSensor(sensor, shape: shape)
            // What the buttons last reported is where presses start from, not a press.
            for button in sensor.buttons where buttonReports[button.id] == nil { buttonReports[button.id] = button.updated ?? "" }
            if let rotary = sensor.rotary, buttonReports[rotary.id] == nil { buttonReports[rotary.id] = rotary.updated ?? "" }
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

    /// Fires the ring's switch for a report newer than the last one seen (as `noteButton`): Single Press when a turn
    /// starts, Long Press once when it goes on past its first report (a longer turn), on the switch of its direction.
    /// A bridge that sends only the older `last_event` has no time on its reports: there, an event from the stream fires
    /// (each comes once) and a read fires nothing.
    func noteRotary(_ rotary: HueSensorDevice.Rotary, on services: SensorServices, fromEvent: Bool = false) {
        if let updated = rotary.updated {
            guard let last = buttonReports[rotary.id], updated > last else { return }
            buttonReports[rotary.id] = updated
        } else if !fromEvent {
            return
        }
        guard let clockwise = rotary.clockwise, let service = clockwise ? services.clockwise : services.anticlockwise else { return }
        let event: Int?
        switch rotary.action {
        case "start":
            longTurns[rotary.id] = nil
            event = HAPConstants.ProgrammableSwitchEvent.singlePress
        case "repeat":
            // The first repeat of a turn (or of a turn the start of which was missed, or that changed direction) is a long one.
            event = longTurns[rotary.id] == clockwise ? nil : HAPConstants.ProgrammableSwitchEvent.longPress
            longTurns[rotary.id] = clockwise
        default:
            event = nil
        }
        if let event { service.characteristic(.programmableSwitchEvent).sendEvent(.int(event)) }
    }

    /// The sensor's readings into its Eve history: the temperature and light level averaged over its ten minutes, as
    /// fakegato's are, and the motion when it changes, with the motion sensor's Last Activation when it starts.
    /// A reading goes in when it changes, not at every event or poll of the device (its battery's, its motion's), so the
    /// average is not weighted by how often the device speaks; the history repeats the last average itself. A sensor
    /// that cannot be reached adds nothing.
    func record(_ sensor: HueSensorDevice, on services: SensorServices) {
        guard let history = services.history, sensor.reachable else { return }
        let reading = RecordedReading(temperature: sensor.temperature.map { ($0.celsius * 10).rounded() / 10 }, lux: sensor.lightLevel?.lux)
        if reading.temperature != nil || reading.lux != nil, recordedReadings[sensor.id] != reading {
            recordedReadings[sensor.id] = reading
            history.add(EveHistory.Entry(temp: reading.temperature, lux: reading.lux))
        }
        guard let detected = sensor.motion?.detected, recordedMotion[sensor.id] != detected else { return }
        recordedMotion[sensor.id] = detected
        let entry = EveHistory.Entry(motion: detected ? 1 : 0)
        history.add(entry)
        if detected, let initial = history.initialTime, let last = services.motion?[EveCharacteristic.lastActivation] {
            last.value = .int(max(0, entry.time - initial))
        }
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
        let motion = sensor.motion.map { _ in
            let service = Self.sensorService(.motionSensor, sensor.name, subtype: "motion", isPrimary: true)
            // Eve's "last motion", seconds since its history began.
            _ = service.characteristic(adding: EveCharacteristic.lastActivation)
            return service
        }
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
            // The label service (added after) says how the buttons are numbered: 1, 2, 3… as the Home app lists them.
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
        }
        // The ring: a Stateless Programmable Switch per direction, numbered after the buttons, that knows a single and a
        // long press (a turn, a longer turn).
        var clockwise: Service?, anticlockwise: Service?
        if sensor.rotary != nil {
            let next = (sensor.buttons.map(\.controlID).max() ?? 0) + 1
            func ring(_ name: String, _ subtype: String, index: Int) -> Service {
                let event = CharacteristicType.programmableSwitchEvent.with(validValues: [
                    HAPConstants.ProgrammableSwitchEvent.singlePress, HAPConstants.ProgrammableSwitchEvent.longPress,
                ])
                let service = Service(
                    .statelessProgrammableSwitch, name: name, subtype: subtype, optional: [event, .serviceLabelIndex, .configuredName],
                    isPrimary: leading && sensor.buttons.isEmpty && index == next)
                service[.serviceLabelIndex]?.value = .int(min(max(index, 1), 255))
                service[.configuredName]?.value = .string(name)
                services.append(service)
                return service
            }
            clockwise = ring("\(sensor.name) Clockwise", "rotary:clockwise", index: next)
            anticlockwise = ring("\(sensor.name) Anticlockwise", "rotary:anticlockwise", index: next + 1)
        }
        if !sensor.buttons.isEmpty || sensor.rotary != nil {
            let label = Service(.serviceLabel, subtype: "buttons")
            label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
            services.append(label)
        }
        // One Eve history per accessory (Eve reads only one): its motion, temperature and light level.
        var history: EveHistory?
        let measured = [motion, temperature, lightLevel].compactMap { $0 }
        if !measured.isEmpty {
            let fields = EveHistory.fields(of: measured)
            let file = context.jsonFile("history-\(sensor.id).json", as: JSONValue.self).url
            let built = EveHistory(.custom(fields), accessoryName: sensor.name, storageURL: file)
            services.append(built.service)
            history = built
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
            serialNumber: sensor.serialNumber ?? sensor.id, firmwareRevision: sensor.firmware.isEmpty ? "1.0.0" : sensor.firmware,
            category: motion == nil && contact == nil && (!buttons.isEmpty || clockwise != nil) ? .programmableSwitch : .sensor, services: services,
            onIdentify: { [client, deviceID = sensor.id] in try? await client?.identify(deviceID: deviceID) })
        let built = SensorServices(
            accessory: accessory, motion: motion, temperature: temperature, lightLevel: lightLevel, contact: contact, battery: battery,
            buttons: buttons, clockwise: clockwise, anticlockwise: anticlockwise, history: history, shape: shape)
        Self.showValues(sensor, on: built)
        record(sensor, on: built)
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
                for try await event in events { await handle(eventData: event.data) }
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

    /// One event's data: a JSON array of changes. A change shown here makes a read already on its way stale (it was
    /// taken before it), so that read is dropped rather than put the old state back.
    func handle(eventData: String) async {
        guard let changes = try? JSONValue(data: Data(eventData.utf8)).arrayValue else { return }
        var readAgain = false
        var applied = false
        for change in changes {
            guard change["type"]?.stringValue == "update" else { readAgain = true; continue }
            for resource in change["data"]?.arrayValue ?? [] {
                if await apply(change: resource) { applied = true } else { readAgain = true }
            }
        }
        if applied { invalidateReads() }
        if readAgain { scheduleRefresh() }
    }

    /// Takes in a changed part of a sensor's, a light's or a room's resource and shows it; false for any other, which a
    /// read of the bridge shows.
    func apply(change resource: JSONValue) async -> Bool {
        guard let rid = resource["id"]?.stringValue else { return false }
        switch resource["type"]?.stringValue {
        case "light":
            guard let index = snapshot.lights.firstIndex(where: { $0.id == rid }) else { return false }
            snapshot.lights[index].apply(resource)
            let light = snapshot.lights[index]
            // Shown before the next event, so a burst lands in order; a light left out of the Home app stays out.
            if !isExcluded(light) { await show(light) }
            return true
        case "grouped_light":
            guard let index = snapshot.groups.firstIndex(where: { $0.groupedLightID == rid }) else { return false }
            if let on = resource["on"]?["on"]?.boolValue { snapshot.groups[index].on = on }
            if let level = resource["dimming"]?["brightness"]?.doubleValue { snapshot.groups[index].brightness = level }
            // A room switched on or off changes which of its scenes is on: the read shows those.
            if resource["on"] != nil { return false }
            await showRoomLight(snapshot.groups[index])
            return true
        default:
            guard let index = snapshot.sensorOfService[rid], snapshot.sensors.indices.contains(index) else { return false }
            snapshot.sensors[index].apply(resource)
            let sensor = snapshot.sensors[index]
            guard let services = sensorAccessories[sensor.id] else { return true }
            if resource["type"]?.stringValue == "button", let button = sensor.buttons.first(where: { $0.id == rid }) {
                noteButton(button, on: services)
            } else if resource["type"]?.stringValue == "relative_rotary", let rotary = sensor.rotary, rotary.id == rid {
                noteRotary(rotary, on: services, fromEvent: true)
            } else {
                Self.showValues(sensor, on: services)
                record(sensor, on: services)
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

    /// A read an event asked for, again when an event overtook it (it was dropped as stale), a few times at most.
    private func runScheduledRefresh() async {
        for _ in 0..<3 {
            await refresh()
            if !lastReadDropped { break }
        }
        pendingRefresh = nil
    }
}
