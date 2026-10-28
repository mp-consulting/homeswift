import Foundation
import Homeswift
import HomeswiftPlugin

/// The hub's sensors, blinds, air purifiers and remotes. Devices that are parts of one product (`relationId`: a
/// VALLHORN's motion and light sensors, a remote's buttons) are one accessory, `Dirigera:<relationId>`; a device on its
/// own is `Dirigera:<device id>`, as lights and outlets are.
extension DirigeraPlugin {
    /// A group's services: each device's, its main one (a motion sensor's, a blind's, a button's) first.
    struct GroupServices {
        let accessory: Accessory
        var services: [String: [Service]]
        let battery: Service?
        let shape: String

        /// The device's service of `type`.
        func service(_ type: ServiceType, of deviceID: String) -> Service? { services[deviceID]?.first { $0.type == type } }
    }

    /// The hub's devices that are not lights, outlets or contact sensors, by the accessory they show on.
    static func groups(of devices: some Sequence<DirigeraDevice>) -> [(id: String, devices: [DirigeraDevice])] {
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

    /// Shows a hub's grouped devices: their values, or a new accessory when what they have changed. Answers the
    /// groups shown, by group id.
    func showGroups(_ hub: Hub) -> Set<String> {
        var shown: Set<String> = []
        for group in Self.groups(of: hub.devices.values) where !isExcluded(group: group.devices, id: group.id) {
            shown.insert(group.id)
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
        return shown
    }

    // MARK: Values

    /// HomeKit's Air Quality (excellent to poor) from PM2.5 (µg/m³, the US EPA's breakpoints) and Sensirion's VOC index
    /// (100 is a room's average), whichever is worse; unknown without either.
    static func airQuality(pm25: Double?, vocIndex: Double?) -> Int {
        let fromPM = pm25.map { $0 <= 12 ? 1 : $0 <= 35 ? 2 : $0 <= 55 ? 3 : $0 <= 150 ? 4 : 5 }
        let fromVOC = vocIndex.map { $0 <= 100 ? 1 : $0 <= 150 ? 2 : $0 <= 250 ? 3 : $0 <= 400 ? 4 : 5 }
        return max(fromPM ?? HAPConstants.AirQuality.unknown, fromVOC ?? HAPConstants.AirQuality.unknown)
    }

    /// A remote's click as HomeKit's Programmable Switch Event.
    static func switchEvent(_ clickPattern: String) -> Int? {
        switch clickPattern {
        case "singlePress": HAPConstants.ProgrammableSwitchEvent.singlePress
        case "doublePress": HAPConstants.ProgrammableSwitchEvent.doublePress
        case "longPress": HAPConstants.ProgrammableSwitchEvent.longPress
        default: nil
        }
    }

    /// HomeKit's position (100 fully open) from IKEA's level (0 fully open), and the other way round.
    static func position(level: Int) -> Int { 100 - min(max(level, 0), 100) }

    /// A battery's level and whether it is low (below `lowBattery`).
    static func showBattery(_ level: Int?, on service: Service?) {
        guard let level, let service else { return }
        service[.batteryLevel]?.value = .int(min(max(level, 0), 100))
        service.characteristic(.statusLowBattery).value = .int(level < lowBattery ? HAPConstants.StatusLowBattery.batteryLevelLow : HAPConstants.StatusLowBattery.batteryLevelNormal)
    }

    static func showAirQuality(_ air: Service?, pm25: Double?, vocIndex: Double?) {
        guard let air else { return }
        air.characteristic(.airQuality).value = .int(airQuality(pm25: pm25, vocIndex: vocIndex))
        if let pm25 { air[.pm2_5Density]?.value = .double(min(max(pm25, 0), 1000)) }
    }

    static func showValues(_ device: DirigeraDevice, on services: GroupServices) {
        showBattery(device.battery, on: services.battery)
        let id = device.id
        switch device.kind {
        case .motion:
            services.service(.motionSensor, of: id)?.characteristic(.motionDetected).value = .bool(device.detected)
        case .lightSensor:
            services.service(.lightSensor, of: id)?.characteristic(.currentAmbientLightLevel).value = .double(min(max(device.illuminance ?? 0, 0.0001), 100_000))
        case .leak:
            services.service(.leakSensor, of: id)?.characteristic(.leakDetected).value =
                .int(device.leak ? HAPConstants.LeakDetected.leakDetected : HAPConstants.LeakDetected.leakNotDetected)
        case .environment:
            if let value = device.temperature { services.service(.temperatureSensor, of: id)?[.currentTemperature]?.value = .double(value) }
            if let value = device.humidity { services.service(.humiditySensor, of: id)?[.currentRelativeHumidity]?.value = .double(min(max(value, 0), 100)) }
            showAirQuality(services.service(.airQualitySensor, of: id), pm25: device.pm25, vocIndex: device.vocIndex)
            if let value = device.co2, let co2 = services.service(.carbonDioxideSensor, of: id) {
                co2[.carbonDioxideLevel]?.value = .double(min(max(value, 0), 100_000))
                // Above 1,000 ppm a room wants airing, as ALPSTUGA's own light turns amber.
                co2.characteristic(.carbonDioxideDetected).value =
                    .int(value > 1000 ? HAPConstants.CarbonDioxideDetected.co2LevelsAbnormal : HAPConstants.CarbonDioxideDetected.co2LevelsNormal)
            }
        case .blinds:
            guard let blind = services.service(.windowCovering, of: id) else { return }
            if let level = device.blindsLevel { blind.characteristic(.currentPosition).value = .int(position(level: level)) }
            if let target = device.blindsTarget ?? device.blindsLevel { blind.characteristic(.targetPosition).value = .int(position(level: target)) }
            // Up opens (its position grows), down closes.
            let state = switch device.blindsState {
            case "up": HAPConstants.PositionState.increasing
            case "down": HAPConstants.PositionState.decreasing
            default: HAPConstants.PositionState.stopped
            }
            blind.characteristic(.positionState).value = .int(state)
        case .airPurifier:
            guard let purifier = services.service(.airPurifier, of: id) else { return }
            let off = device.fanMode == "off"
            purifier.characteristic(.active).value = .int(off ? HAPConstants.Active.inactive : HAPConstants.Active.active)
            let current = off ? HAPConstants.CurrentAirPurifierState.inactive
                : (device.motorState ?? 0) == 0 ? HAPConstants.CurrentAirPurifierState.idle : HAPConstants.CurrentAirPurifierState.purifyingAir
            purifier.characteristic(.currentAirPurifierState).value = .int(current)
            purifier.characteristic(.targetAirPurifierState).value = .int(device.fanMode == "auto" ? 1 : 0)
            if let motor = device.motorState { purifier[.rotationSpeed]?.value = .double(Double(min(max(motor, 0), 50) * 2)) }
            if let lock = device.childLock {
                purifier[.lockPhysicalControls]?.value = .int(lock ? HAPConstants.LockPhysicalControls.controlLockEnabled : HAPConstants.LockPhysicalControls.controlLockDisabled)
            }
            if let filter = services.service(.filterMaintenance, of: id) {
                filter.characteristic(.filterChangeIndication).value =
                    .int(device.filterAlarm ? HAPConstants.FilterChangeIndication.changeFilter : HAPConstants.FilterChangeIndication.filterOk)
                if let elapsed = device.filterElapsed, let lifetime = device.filterLifetime, lifetime > 0 {
                    filter[.filterLifeLevel]?.value = .double(min(max(100 - elapsed / lifetime * 100, 0), 100).rounded())
                }
            }
            showAirQuality(services.service(.airQualitySensor, of: id), pm25: device.pm25, vocIndex: nil)
        case .controller, .light, .outlet, .contact:
            break
        }
    }

    // MARK: Accessories

    /// A service with its name shown in the Home app.
    private static func named(_ type: ServiceType, _ name: String, subtype: String, optional: [CharacteristicType] = [], isPrimary: Bool) -> Service {
        let service = Service(type, name: name, subtype: subtype, optional: optional + [.configuredName], isPrimary: isPrimary)
        service[.configuredName]?.value = .string(name)
        return service
    }

    /// The services of one device of a group, its main one first; empty for a device with nothing to show.
    private static func services(of device: DirigeraDevice, number: Int, of count: Int, isPrimary: Bool, client: DirigeraClient) -> [Service] {
        let deviceID = device.id
        let name = device.name
        // A write the hub refused is a communication failure to HomeKit.
        let patch: @Sendable (JSONValue) async throws -> Void = { attributes in
            do { try await client.patch(deviceID: deviceID, attributes: attributes) } catch { throw HAPStatusError(.serviceCommunicationFailure) }
        }
        switch device.kind {
        case .motion:
            return [named(.motionSensor, name, subtype: "motion:\(deviceID)", isPrimary: isPrimary)]
        case .lightSensor:
            return [named(.lightSensor, "\(name) Light", subtype: "light:\(deviceID)", isPrimary: isPrimary)]
        case .leak:
            return [named(.leakSensor, name, subtype: "leak:\(deviceID)", isPrimary: isPrimary)]
        case .environment:
            // The device's measures, each a service: the first it has leads.
            var measures: [(ServiceType, String, String, [CharacteristicType])] = []
            if device.temperature != nil { measures.append((.temperatureSensor, "Temperature", "temperature", [.currentTemperature.with(minValue: -50, maxValue: 100)])) }
            if device.humidity != nil { measures.append((.humiditySensor, "Humidity", "humidity", [])) }
            if device.pm25 != nil || device.vocIndex != nil { measures.append((.airQualitySensor, "Air Quality", "air", device.pm25 != nil ? [.pm2_5Density] : [])) }
            if device.co2 != nil { measures.append((.carbonDioxideSensor, "CO₂", "co2", [.carbonDioxideLevel])) }
            return measures.enumerated().map { index, measure in
                named(measure.0, "\(name) \(measure.1)", subtype: "\(measure.2):\(deviceID)", optional: measure.3, isPrimary: isPrimary && index == 0)
            }
        case .blinds:
            let blind = named(.windowCovering, name, subtype: "blind:\(deviceID)", optional: [.holdPosition], isPrimary: isPrimary)
            blind.characteristic(.targetPosition).onWrite { value in
                try await patch(["blindsTargetLevel": .number(Double(position(level: value.intValue ?? 0)))])
            }
            blind[.holdPosition]?.onWrite { value in
                if value.boolValue == true { try await patch(["blindsState": "stopped"]) }
            }
            return [blind]
        case .airPurifier:
            let purifier = named(.airPurifier, name, subtype: "purifier:\(deviceID)", optional: [.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 2), .lockPhysicalControls], isPrimary: isPrimary)
            let speed = purifier[.rotationSpeed]
            purifier.characteristic(.active).onWrite { value in
                try await patch(["fanMode": value.intValue == HAPConstants.Active.inactive ? "off" : "auto"])
            }
            purifier.characteristic(.targetAirPurifierState).onWrite { [weak speed] value in
                // Manual keeps the speed it has: the motor's state, at least its slowest.
                try await patch(value.intValue == 1 ? ["fanMode": "auto"] : ["motorState": .number(Double(max(1, Int((speed?.value.doubleValue ?? 20) / 2))))])
            }
            speed?.onWrite { value in
                // 0 to 100 % as the motor's 0 to 50; 0 switches it off, as the Home app's slider does.
                let percent = value.doubleValue ?? 0
                try await patch(percent < 1 ? ["fanMode": "off"] : ["motorState": .number(Double(min(max(Int((percent / 2).rounded()), 1), 50)))])
            }
            purifier[.lockPhysicalControls]?.onWrite { value in
                try await patch(["childLock": .bool(value.intValue == HAPConstants.LockPhysicalControls.controlLockEnabled)])
            }
            let filter = Service(.filterMaintenance, name: "Filter", subtype: "filter:\(deviceID)", optional: [.filterLifeLevel])
            purifier.linked = [filter]
            return [purifier, filter, Service(.airQualitySensor, name: "\(name) Air Quality", subtype: "air:\(deviceID)", optional: [.pm2_5Density])]
        case .controller:
            // A button: its number among its remote's, as the Home app lists them.
            let button = named(.statelessProgrammableSwitch, count == 1 ? name : "Button \(number)", subtype: "button:\(deviceID)", optional: [.serviceLabelIndex], isPrimary: isPrimary)
            button[.serviceLabelIndex]?.value = .int(number)
            return [button]
        case .light, .outlet, .contact:
            return []
        }
    }

    private func addGroup(_ devices: [DirigeraDevice], id: String, on hub: Hub, shape: String) throws -> GroupServices {
        let client = hub.client
        let buttons = devices.filter { $0.kind == .controller }
        var byDevice: [String: [Service]] = [:]
        var all: [Service] = []
        for device in devices {
            let number = (buttons.firstIndex { $0.id == device.id } ?? 0) + 1
            let services = Self.services(of: device, number: number, of: buttons.count, isPrimary: all.isEmpty, client: client)
            byDevice[device.id] = services
            all += services
        }
        if !buttons.isEmpty {
            let label = Service(.serviceLabel, subtype: "buttons")
            label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
            all.append(label)
        }
        var battery: Service?
        if devices.contains(where: { $0.battery != nil }) {
            let service = Service(.battery, name: "Battery", subtype: "battery", optional: [.batteryLevel, .chargingState])
            service[.chargingState]?.value = .int(HAPConstants.ChargingState.notChargeable)
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
        let built = GroupServices(accessory: accessory, services: byDevice, battery: battery, shape: shape)
        for device in devices { Self.showValues(device, on: built) }
        accessory.isUnavailable = !devices.allSatisfy(\.reachable)
        if let room = lead.room { accessory.suggestedRoom = room }
        try context.add(accessory)
        return built
    }

    /// The device that stands for a group (it blinks for Identify): its first, as the accessory's own Identify uses.
    static func lead(ofGroup id: String, in hub: Hub) -> DirigeraDevice? {
        groups(of: hub.devices.values.filter { $0.groupID == id }).first?.devices.first
    }

    // MARK: Events

    /// A grouped device's change, from a `deviceStateChanged` event; its reachability only when the event says.
    func showGroupChange(_ device: DirigeraDevice, reachabilityChanged: Bool, on hub: Hub) {
        guard let services = groupAccessories[device.groupID] else { return }
        Self.showValues(device, on: services)
        if reachabilityChanged {
            services.accessory.isUnavailable = !hub.devices.values.filter { $0.groupID == device.groupID }.allSatisfy(\.reachable)
        }
    }

    /// A remote's press (`remotePressEvent`): its button's switch fires.
    func press(deviceID: String, clickPattern: String, on hub: Hub) {
        guard let device = hub.devices[deviceID], device.kind == .controller, let event = Self.switchEvent(clickPattern),
              let button = groupAccessories[device.groupID]?.service(.statelessProgrammableSwitch, of: deviceID) else { return }
        button.characteristic(.programmableSwitchEvent).sendEvent(.int(event))
    }
}
