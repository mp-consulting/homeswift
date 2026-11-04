import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Builds the services and accessories of a block's entries (spec 3, 4) and wires HomeKit's writes to the engine.
struct DummyAccessoryBuilder {
    let engine: DummyEngine
    let storage: URL
    let logger: Logger

    /// The types whose Eve history the Homebridge plugin records, and its kind.
    static func historyKind(_ config: AccessoryConfig) -> EveHistory.Kind? {
        switch config.type {
        case .switch, .outlet, .lightbulb: return .custom([.status])
        case .temperatureSensor, .humiditySensor, .thermostat, .humidifier: return .weather
        case .contactSensor: return .door
        case .motionSensor: return .motion
        default:
            switch config.sensor?.type {
            case .contactSensor?: return .door
            case .motionSensor?: return .motion
            default: return nil
            }
        }
    }

    func services(for config: AccessoryConfig, grouped: Bool) -> DeviceServices {
        let historyURL = storage.appendingPathComponent("history-\(DummyIdentity.historyFileName(config.identifier)).json")
        var history: EveHistory?
        if config.enableHistory, !grouped, let kind = Self.historyKind(config) {
            history = EveHistory(kind, accessoryName: config.name, storageURL: historyURL)
        } else if FileManager.default.fileExists(atPath: historyURL.path) {
            try? FileManager.default.removeItem(at: historyURL)
            logger.debug("\(config.name): removing history")
        }
        let primary = primaryService(config, grouped: grouped)
        var sensor: Service?
        if let addOn = config.sensor {
            var extra: [Characteristic] = []
            if config.enableHistory, addOn.type == .contactSensor { extra = Self.openingCharacteristics() }
            sensor = Service(addOn.type.service, subtype: grouped ? "\(config.identifier):sensor" : nil, extra: extra)
            if let type = addOn.type.sensorCharacteristic { sensor?[type]?.value = addOn.type == .motionSensor ? .bool(false) : .int(0) }
            wireResetTotal(sensor, config)
        }
        return DeviceServices(primary: primary, sensor: sensor, history: history)
    }

    /// Eve's open counts: the Homebridge plugin adds them to doors, windows, garage doors and contact sensors with history.
    static func openingCharacteristics() -> [Characteristic] {
        [
            Characteristic(EveCharacteristic.openDuration, value: .int(0)), Characteristic(EveCharacteristic.closedDuration, value: .int(0)),
            Characteristic(EveCharacteristic.timesOpened, value: .int(0)),
            Characteristic(EveCharacteristic.resetTotal, value: .int(Int(Date().timeIntervalSince1970) - 978_307_200)),
        ]
    }

    func primaryService(_ config: AccessoryConfig, grouped: Bool) -> Service {
        let engine = engine
        let id = config.identifier
        var optional: [CharacteristicType] = []
        var extra: [Characteristic] = []
        switch config.type {
        case .lightbulb where config.isDimmer: optional = [.brightness]
        case .button: extra = [Characteristic(.programmableSwitchEvent.with(validValues: [0, 1, 2]))]
        case .valve:
            optional = [.isConfigured]
            if config.autoReset?.isTimeout == true { optional += [.setDuration.with(minValue: 1, maxValue: 3600), .remainingDuration] }
        case .humidifier:
            let target = config.dehumidifier ? 2 : 1
            optional = [config.dehumidifier ? .relativeHumidityDehumidifierThreshold : .relativeHumidityHumidifierThreshold]
            extra = [Characteristic(.targetHumidifierDehumidifierState.with(minStep: 1, validValues: [target]), value: .int(target))]
        case .thermostat:
            let current = config.validStates.filter { $0 != 3 }
            let low = config.minimumTemperature, high = config.maximumTemperature
            extra = [
                Characteristic(.targetHeatingCoolingState.with(validValues: config.validStates)),
                Characteristic(.currentHeatingCoolingState.with(validValues: current.isEmpty ? [0] : current)),
                Characteristic(.currentTemperature.with(minValue: low, maxValue: high)),
                Characteristic(.targetTemperature.with(minValue: low, maxValue: high)),
            ]
        default: break
        }
        if config.enableHistory, !grouped {
            switch config.family {
            case .position, .garage: extra += Self.openingCharacteristics()
            case .binarySensor where config.type == .contactSensor: extra += Self.openingCharacteristics()
            default: break
            }
            switch Self.historyKind(config) {
            case .custom?, .door?, .motion?: extra.append(Characteristic(EveCharacteristic.lastActivation, value: .int(0)))
            default: break
            }
        }
        if grouped { optional.append(.configuredName) }
        let service = Service(
            config.type.service, name: grouped ? config.name : nil, subtype: grouped ? id : nil, optional: optional, extra: extra, isPrimary: !grouped)
        if grouped { service[.configuredName]?.value = .string(config.name) }

        func write(_ type: CharacteristicType, _ make: @escaping @Sendable (HAPValue) -> DummyEngine.Write?) {
            guard let characteristic = service[type] else { return }
            characteristic.onWrite { [weak characteristic] value in
                guard let request = make(value) else { return }
                if let shown = await engine.write(id, request) { characteristic?.revert(to: shown, after: .milliseconds(1)) }
            }
        }
        switch config.family {
        case .onOff:
            write(.on) { .on($0.boolValue ?? (($0.intValue ?? 0) != 0)) }
            write(.brightness) { $0.intValue.map(DummyEngine.Write.brightness) }
        case .lock: write(.lockTargetState) { $0.intValue.map(DummyEngine.Write.lock) }
        case .position: write(.targetPosition) { $0.intValue.map(DummyEngine.Write.targetPosition) }
        case .garage: write(.targetDoorState) { $0.intValue.map(DummyEngine.Write.targetDoor) }
        case .valve:
            write(.active) { $0.intValue.map(DummyEngine.Write.active) }
            write(.setDuration) { $0.intValue.map(DummyEngine.Write.setDuration) }
            service[.remainingDuration]?.onRead { .int(await engine.remainingDuration(id)) }
        case .humidifier:
            write(.active) { $0.intValue.map(DummyEngine.Write.active) }
            write(config.dehumidifier ? .relativeHumidityDehumidifierThreshold : .relativeHumidityHumidifierThreshold) { $0.doubleValue.map(DummyEngine.Write.threshold) }
            // Writes of the one mode it has are accepted and change nothing.
            service[.targetHumidifierDehumidifierState]?.onWrite { _ in }
        case .thermostat:
            write(.targetHeatingCoolingState) { $0.intValue.map(DummyEngine.Write.targetMode) }
            write(.targetTemperature) { $0.doubleValue.map(DummyEngine.Write.targetTemperature) }
            let units = HAPValue.int(config.fahrenheit ? 1 : 0)
            service[.temperatureDisplayUnits]?.onWrite { [weak service] _ in
                service?[.temperatureDisplayUnits]?.revert(to: units, after: .milliseconds(1))
            }
        default: break
        }
        wireResetTotal(service, config)
        return service
    }

    private func wireResetTotal(_ service: Service?, _ config: AccessoryConfig) {
        guard let characteristic = service?[EveCharacteristic.resetTotal] else { return }
        let engine = engine
        let id = config.identifier
        characteristic.onWrite { value in
            _ = await engine.write(id, .resetTotal(value.intValue ?? 0))
        }
    }

    func accessory(for config: AccessoryConfig, services: DeviceServices) -> Accessory {
        Accessory(
            id: DummyPlugin.accessoryID(deviceID: config.deviceID), name: config.name, manufacturer: DummyPlugin.manufacturer,
            model: config.type.rawValue, serialNumber: config.identifier, firmwareRevision: PluginHost.version, category: config.type.category,
            services: [services.primary] + [services.sensor, services.history?.service].compactMap { $0 })
    }

    /// One accessory for the members of a group: a service of each, by its identifier (spec 3.3).
    func group(name: String, members: [(AccessoryConfig, DeviceServices)]) -> Accessory {
        let identifier = DummyIdentity.groupIdentifier(name)
        let deviceID = String(identifier.dropFirst(DummyPlugin.platform.count + 1))
        var services: [Service] = []
        for (_, member) in members {
            services.append(member.primary)
            if let sensor = member.sensor {
                member.primary.linked.append(sensor)
                services.append(sensor)
            }
        }
        return Accessory(
            id: DummyPlugin.accessoryID(deviceID: deviceID), name: name, manufacturer: DummyPlugin.manufacturer, model: "GroupAccessory",
            serialNumber: DummyIdentity.uuid(identifier), firmwareRevision: PluginHost.version, category: members.first?.0.type.category ?? .other,
            services: services)
    }
}
