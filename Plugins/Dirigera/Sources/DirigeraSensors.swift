import Foundation
import Homeswift
import HomeswiftPlugin

/// The hub's sensors, blinds, air purifiers and remotes. Devices that are parts of one product (`relationId`: a
/// VALLHORN's motion and light sensors, a remote's buttons) are one accessory, `Dirigera:<relationId>`; a device on its
/// own is `Dirigera:<device id>`, as lights and outlets are.
extension DirigeraPlugin {
    /// A group's services, by the id of the device each one shows.
    struct GroupServices {
        let accessory: Accessory
        /// The main service of each device (a motion sensor's, a blind's, a button's).
        var services: [String: Service]
        /// What else a device shows: an environment sensor's humidity, air quality and CO₂, a purifier's filter and air.
        var extra: [String: [Service]]
        let battery: Service?
        let shape: String
    }

    /// The hub's devices that are not lights, outlets or contact sensors, by the accessory they show on.
    static func groups(of devices: [DirigeraDevice]) -> [(id: String, devices: [DirigeraDevice])] {
        let parts = Dictionary(grouping: devices.filter { !$0.isStandalone }, by: \.groupID)
        return parts.map { key, list in
            // Buttons in their remote's order; a sensor's main part (its motion) first.
            let ordered = list.sorted { first, second in
                let rank = { (device: DirigeraDevice) in device.kind == .motion ? 0 : device.kind == .controller ? 2 : 1 }
                if rank(first) != rank(second) { return rank(first) < rank(second) }
                return (first.switchGroup ?? Int.max, first.id) < (second.switchGroup ?? Int.max, second.id)
            }
            return (key, ordered)
        }.sorted { $0.devices[0].name < $1.devices[0].name }
    }

    static func shape(ofGroup devices: [DirigeraDevice]) -> String {
        devices.map { device in
            let measures = [device.temperature, device.humidity, device.pm25, device.vocIndex, device.co2].map { $0 == nil ? "-" : "+" }.joined()
            return "\(device.id)=\(device.kind.rawValue)\(device.kind == .environment ? measures : "")"
        }.joined(separator: "|") + (devices.contains { $0.battery != nil } ? "|b" : "")
    }

    func isExcluded(group devices: [DirigeraDevice], id: String) -> Bool {
        excludedDevices.contains(id.lowercased()) || devices.contains { isExcluded($0) }
    }

    /// Shows a hub's grouped devices: their values, or a new accessory when what they have changed.
    func showGroups(_ hub: Hub) -> Set<String> {
        var keep: Set<String> = []
        for group in Self.groups(of: Array(hub.devices.values)) where !isExcluded(group: group.devices, id: group.id) {
            keep.insert(group.id)
            let shape = Self.shape(ofGroup: group.devices)
            if let services = groupAccessories[group.id], services.shape == shape {
                services.accessory.isUnavailable = !group.devices.allSatisfy(\.reachable)
                for device in group.devices { Self.showValues(device, on: services) }
                continue
            }
            do {
                groupAccessories[group.id] = try addGroup(group.devices, id: group.id, on: hub, shape: shape)
            } catch {
                logger.error("Could not add \(group.devices[0].name): \(error)")
            }
        }
        return keep
    }

    // MARK: Values

    /// A battery is low below this.
    static let lowBatteryLevel = 10

    /// HomeKit's Air Quality (1 excellent to 5 poor) from PM2.5 (µg/m³, the US EPA's breakpoints) and Sensirion's VOC
    /// index (100 is a room's average), whichever is worse; 0 (unknown) without either.
    static func airQuality(pm25: Double?, vocIndex: Double?) -> Int {
        let fromPM = pm25.map { $0 <= 12 ? 1 : $0 <= 35 ? 2 : $0 <= 55 ? 3 : $0 <= 150 ? 4 : 5 }
        let fromVOC = vocIndex.map { $0 <= 100 ? 1 : $0 <= 150 ? 2 : $0 <= 250 ? 3 : $0 <= 400 ? 4 : 5 }
        return max(fromPM ?? 0, fromVOC ?? 0)
    }

    /// A remote's click as HomeKit's Programmable Switch Event.
    static func switchEvent(_ clickPattern: String) -> Int? {
        switch clickPattern {
        case "singlePress": 0
        case "doublePress": 1
        case "longPress": 2
        default: nil
        }
    }

    /// HomeKit's position (100 fully open) from IKEA's level (0 fully open).
    static func position(level: Int) -> Int { 100 - min(max(level, 0), 100) }

    static func showValues(_ device: DirigeraDevice, on services: GroupServices) {
        if let battery = device.battery, let service = services.battery {
            service[.batteryLevel]?.value = .int(min(max(battery, 0), 100))
            service.characteristic(.statusLowBattery).value = .int(battery < lowBatteryLevel ? 1 : 0)
        }
        guard let service = services.services[device.id] else { return }
        let extra = services.extra[device.id] ?? []
        func extraService(_ type: ServiceType) -> Service? { extra.first { $0.type == type } }
        switch device.kind {
        case .motion:
            service.characteristic(.motionDetected).value = .bool(device.detected)
        case .lightSensor:
            service.characteristic(.currentAmbientLightLevel).value = .double(min(max(device.illuminance ?? 0, 0.0001), 100_000))
        case .leak:
            service.characteristic(.leakDetected).value = .int(device.leak ? 1 : 0)
        case .environment:
            if let value = device.temperature { (service.type == .temperatureSensor ? service : extraService(.temperatureSensor))?[.currentTemperature]?.value = .double(value) }
            if let value = device.humidity { (service.type == .humiditySensor ? service : extraService(.humiditySensor))?[.currentRelativeHumidity]?.value = .double(min(max(value, 0), 100)) }
            if let air = service.type == .airQualitySensor ? service : extraService(.airQualitySensor) {
                air.characteristic(.airQuality).value = .int(airQuality(pm25: device.pm25, vocIndex: device.vocIndex))
                if let pm25 = device.pm25 { air[.pm2_5Density]?.value = .double(min(max(pm25, 0), 1000)) }
            }
            if let value = device.co2, let co2 = service.type == .carbonDioxideSensor ? service : extraService(.carbonDioxideSensor) {
                co2[.carbonDioxideLevel]?.value = .double(min(max(value, 0), 100_000))
                // Above 1,000 ppm a room wants airing, as ALPSTUGA's own light turns amber.
                co2.characteristic(.carbonDioxideDetected).value = .int(value > 1000 ? 1 : 0)
            }
        case .blinds:
            if let level = device.blindsLevel { service.characteristic(.currentPosition).value = .int(position(level: level)) }
            if let target = device.blindsTarget ?? device.blindsLevel { service.characteristic(.targetPosition).value = .int(position(level: target)) }
            // Up opens (its position grows), down closes.
            service.characteristic(.positionState).value = .int(device.blindsState == "up" ? 1 : device.blindsState == "down" ? 0 : 2)
        case .airPurifier:
            let off = device.fanMode == "off"
            service.characteristic(.active).value = .int(off ? 0 : 1)
            service.characteristic(.currentAirPurifierState).value = .int(off ? 0 : (device.motorState ?? 0) == 0 ? 1 : 2)
            service.characteristic(.targetAirPurifierState).value = .int(device.fanMode == "auto" ? 1 : 0)
            if let motor = device.motorState { service[.rotationSpeed]?.value = .double(Double(min(max(motor, 0), 50) * 2)) }
            if let lock = device.childLock { service[.lockPhysicalControls]?.value = .int(lock ? 1 : 0) }
            if let filter = extraService(.filterMaintenance) {
                filter.characteristic(.filterChangeIndication).value = .int(device.filterAlarm ? 1 : 0)
                if let elapsed = device.filterElapsed, let lifetime = device.filterLifetime, lifetime > 0 {
                    filter[.filterLifeLevel]?.value = .double(min(max(100 - elapsed / lifetime * 100, 0), 100).rounded())
                }
            }
            if let air = extraService(.airQualitySensor) {
                air.characteristic(.airQuality).value = .int(airQuality(pm25: device.pm25, vocIndex: nil))
                if let pm25 = device.pm25 { air[.pm2_5Density]?.value = .double(min(max(pm25, 0), 1000)) }
            }
        case .controller, .light, .outlet, .contact:
            break
        }
    }

    // MARK: Accessories

    private func addGroup(_ devices: [DirigeraDevice], id: String, on hub: Hub, shape: String) throws -> GroupServices {
        let client = hub.client
        let fail: @Sendable (any Error) -> HAPStatusError = { _ in HAPStatusError(.serviceCommunicationFailure) }
        var all: [Service] = []
        var byDevice: [String: Service] = [:]
        var extra: [String: [Service]] = [:]
        let buttons = devices.filter { $0.kind == .controller }
        for device in devices {
            let primary = all.isEmpty
            let deviceID = device.id
            let named = { (type: ServiceType, name: String, subtype: String, optional: [CharacteristicType]) -> Service in
                let service = Service(type, name: name, subtype: subtype, optional: optional + [.configuredName], isPrimary: primary && type != .battery)
                service[.configuredName]?.value = .string(name)
                return service
            }
            switch device.kind {
            case .motion:
                byDevice[deviceID] = named(.motionSensor, device.name, "motion:\(deviceID)", [])
            case .lightSensor:
                byDevice[deviceID] = named(.lightSensor, "\(device.name) Light", "light:\(deviceID)", [])
            case .leak:
                byDevice[deviceID] = named(.leakSensor, device.name, "leak:\(deviceID)", [])
            case .environment:
                // The device's measures, each a service: the first it has leads.
                var measures: [Service] = []
                if device.temperature != nil {
                    measures.append(named(.temperatureSensor, "\(device.name) Temperature", "temperature:\(deviceID)", [.currentTemperature.with(minValue: -50, maxValue: 100)]))
                }
                if device.humidity != nil { measures.append(named(.humiditySensor, "\(device.name) Humidity", "humidity:\(deviceID)", [])) }
                if device.pm25 != nil || device.vocIndex != nil {
                    measures.append(named(.airQualitySensor, "\(device.name) Air Quality", "air:\(deviceID)", device.pm25 != nil ? [.pm2_5Density] : []))
                }
                if device.co2 != nil { measures.append(named(.carbonDioxideSensor, "\(device.name) CO₂", "co2:\(deviceID)", [.carbonDioxideLevel])) }
                guard let first = measures.first else { continue }
                byDevice[deviceID] = first
                extra[deviceID] = Array(measures.dropFirst())
            case .blinds:
                let blind = named(.windowCovering, device.name, "blind:\(deviceID)", [.holdPosition])
                blind.characteristic(.targetPosition).onWrite { value in
                    // HomeKit's position back to IKEA's level, 0 fully open.
                    let level = 100 - min(max(value.intValue ?? 0, 0), 100)
                    do { try await client.patch(deviceID: deviceID, attributes: ["blindsTargetLevel": .number(Double(level))]) } catch { throw fail(error) }
                }
                blind[.holdPosition]?.onWrite { value in
                    guard value.boolValue == true else { return }
                    do { try await client.patch(deviceID: deviceID, attributes: ["blindsState": "stopped"]) } catch { throw fail(error) }
                }
                byDevice[deviceID] = blind
            case .airPurifier:
                let purifier = named(.airPurifier, device.name, "purifier:\(deviceID)", [.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 2), .lockPhysicalControls])
                purifier.characteristic(.active).onWrite { value in
                    let mode = value.intValue == 0 ? "off" : "auto"
                    do { try await client.patch(deviceID: deviceID, attributes: ["fanMode": .string(mode)]) } catch { throw fail(error) }
                }
                purifier.characteristic(.targetAirPurifierState).onWrite { [purifier] value in
                    // Manual keeps the speed it has: the motor's state, at least its slowest.
                    let attributes: JSONValue = value.intValue == 1
                        ? ["fanMode": "auto"]
                        : ["motorState": .number(Double(max(1, Int((purifier[.rotationSpeed]?.value.doubleValue ?? 20) / 2))))]
                    do { try await client.patch(deviceID: deviceID, attributes: attributes) } catch { throw fail(error) }
                }
                purifier[.rotationSpeed]?.onWrite { value in
                    // 0 to 100 % as the motor's 0 to 50; 0 switches it off, as the Home app's slider does.
                    let speed = value.doubleValue ?? 0
                    let attributes: JSONValue = speed < 1 ? ["fanMode": "off"] : ["motorState": .number(Double(min(max(Int((speed / 2).rounded()), 1), 50)))]
                    do { try await client.patch(deviceID: deviceID, attributes: attributes) } catch { throw fail(error) }
                }
                purifier[.lockPhysicalControls]?.onWrite { value in
                    do { try await client.patch(deviceID: deviceID, attributes: ["childLock": .bool(value.intValue == 1)]) } catch { throw fail(error) }
                }
                byDevice[deviceID] = purifier
                let filter = Service(.filterMaintenance, name: "Filter", subtype: "filter:\(deviceID)", optional: [.filterLifeLevel])
                let air = Service(.airQualitySensor, name: "\(device.name) Air Quality", subtype: "air:\(deviceID)", optional: [.pm2_5Density])
                purifier.linked = [filter]
                extra[deviceID] = [filter, air]
            case .controller:
                // A button: its number among its remote's, as the Home app lists them.
                let number = (buttons.firstIndex { $0.id == deviceID } ?? 0) + 1
                let name = buttons.count == 1 ? device.name : "Button \(number)"
                let button = named(.statelessProgrammableSwitch, name, "button:\(deviceID)", [.serviceLabelIndex])
                button[.serviceLabelIndex]?.value = .int(number)
                byDevice[deviceID] = button
            case .light, .outlet, .contact:
                continue
            }
            if let main = byDevice[deviceID] { all.append(main) }
            all += extra[deviceID] ?? []
        }
        if !buttons.isEmpty {
            let label = Service(.serviceLabel, subtype: "buttons")
            label.characteristic(.serviceLabelNamespace).value = .int(1)
            all.append(label)
        }
        var battery: Service?
        if devices.contains(where: { $0.battery != nil }) {
            let service = Service(.battery, name: "Battery", subtype: "battery", optional: [.batteryLevel, .chargingState])
            service[.chargingState]?.value = .int(2)
            battery = service
            all.append(service)
        }
        let lead = devices[0]
        let category: AccessoryCategory = switch lead.kind {
        case .blinds: .windowCovering
        case .airPurifier: .airPurifier
        case .controller: .programmableSwitch
        default: .sensor
        }
        let identifyID = lead.id
        let accessory = Accessory(
            id: Self.accessoryID(deviceID: id), name: lead.name, manufacturer: lead.manufacturer, model: lead.model,
            serialNumber: lead.serial, firmwareRevision: lead.firmware.isEmpty ? "1.0.0" : lead.firmware, category: category, services: all,
            onIdentify: { try? await client.identify(deviceID: identifyID) })
        let built = GroupServices(accessory: accessory, services: byDevice, extra: extra, battery: battery, shape: shape)
        for device in devices { Self.showValues(device, on: built) }
        accessory.isUnavailable = !devices.allSatisfy(\.reachable)
        if let room = lead.room { accessory.suggestedRoom = room }
        try context.add(accessory)
        return built
    }

    // MARK: Events

    /// A grouped device's change, from a `deviceStateChanged` event.
    func showGroupChange(_ device: DirigeraDevice) {
        guard let services = groupAccessories[device.groupID] else { return }
        Self.showValues(device, on: services)
        if let hub = hubs.values.first(where: { $0.devices[device.id] != nil }) {
            services.accessory.isUnavailable = !hub.devices.values.filter { $0.groupID == device.groupID }.allSatisfy(\.reachable)
        }
    }

    /// A remote's press (`remotePressEvent`): its button's switch fires.
    func press(deviceID: String, clickPattern: String, on hub: Hub) {
        guard let device = hub.devices[deviceID], device.kind == .controller, let event = Self.switchEvent(clickPattern),
              let button = groupAccessories[device.groupID]?.services[deviceID] else { return }
        button.characteristic(.programmableSwitchEvent).sendEvent(.int(event))
    }
}
