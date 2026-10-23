import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The accessory handler types, by the name the factory routes to.
enum HandlerKind: String, Sendable {
    case `switch`, outlet, light, thermostat, thSensor, fan, sensor, curtain, garage, airConditioner, humidifier, diffuser, panel
    case virtual, motor, group, rfBridge, rfButton, rfSensor, switchMini, switchMate
    case lock, valve, tap, thHeater, thCooler, thHumidifier, thDehumidifier, thThermostat, heater, cooler, purifier
    case blind, door, window, doorbell, lightFan, tv, programmableButton, simulatedSensor, sensorLeak, rfBlind, rfDoor, rfWindow

    @EWeLinkActor
    func make(_ platform: EWeLinkPlatform, _ record: AccessoryRecord, _ box: DeviceBox) -> BaseAccessory {
        switch self {
        case .switch: SwitchAccessory(platform: platform, record: record, box: box)
        case .outlet: OutletAccessory(platform: platform, record: record, box: box)
        case .light: LightAccessory(platform: platform, record: record, box: box)
        case .thermostat: ThermostatAccessory(platform: platform, record: record, box: box)
        case .thSensor: THSensorAccessory(platform: platform, record: record, box: box)
        case .fan: FanAccessory(platform: platform, record: record, box: box)
        case .sensor: SensorAccessory(platform: platform, record: record, box: box)
        case .curtain: CurtainAccessory(platform: platform, record: record, box: box)
        case .garage: GarageAccessory(platform: platform, record: record, box: box)
        case .airConditioner: AirConditionerAccessory(platform: platform, record: record, box: box)
        case .humidifier: HumidifierAccessory(platform: platform, record: record, box: box)
        case .diffuser: DiffuserAccessory(platform: platform, record: record, box: box)
        case .panel: PanelAccessory(platform: platform, record: record, box: box)
        case .virtual: VirtualAccessory(platform: platform, record: record, box: box)
        case .motor: MotorAccessory(platform: platform, record: record, box: box)
        case .group: GroupAccessory(platform: platform, record: record, box: box)
        case .rfBridge: RFBridgeAccessory(platform: platform, record: record, box: box)
        case .rfButton: RFButtonAccessory(platform: platform, record: record, box: box)
        case .rfSensor: RFSensorAccessory(platform: platform, record: record, box: box)
        case .switchMini: SwitchMiniAccessory(platform: platform, record: record, box: box)
        case .switchMate: SwitchMateAccessory(platform: platform, record: record, box: box)
        case .lock: LockAccessory(platform: platform, record: record, box: box)
        case .valve: ValveAccessory(platform: platform, record: record, box: box)
        case .tap: TapAccessory(platform: platform, record: record, box: box)
        case .thHeater: THClimateAccessory(platform: platform, record: record, box: box, kind: .heat)
        case .thCooler: THClimateAccessory(platform: platform, record: record, box: box, kind: .cool)
        case .thHumidifier: THClimateAccessory(platform: platform, record: record, box: box, kind: .humidify)
        case .thDehumidifier: THClimateAccessory(platform: platform, record: record, box: box, kind: .dehumidify)
        case .thThermostat: THThermostatAccessory(platform: platform, record: record, box: box)
        case .heater: SwitchClimateAccessory(platform: platform, record: record, box: box, kind: .heat)
        case .cooler: SwitchClimateAccessory(platform: platform, record: record, box: box, kind: .cool)
        case .purifier: PurifierAccessory(platform: platform, record: record, box: box)
        case .blind: SwitchCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .windowCovering, label: "blind"))
        case .door: SwitchCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .door, label: "door"))
        case .window: SwitchCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .window, label: "window"))
        case .doorbell: DoorbellAccessory(platform: platform, record: record, box: box)
        case .lightFan: LightFanAccessory(platform: platform, record: record, box: box)
        case .tv: TVAccessory(platform: platform, record: record, box: box)
        case .programmableButton: ProgrammableButtonAccessory(platform: platform, record: record, box: box)
        case .simulatedSensor: SimulatedSensorAccessory(platform: platform, record: record, box: box)
        case .sensorLeak: SensorLeakAccessory(platform: platform, record: record, box: box)
        case .rfBlind: RFCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .windowCovering, label: "RF blind"))
        case .rfDoor: RFCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .door, label: "RF door"))
        case .rfWindow: RFCoverAccessory(platform: platform, record: record, box: box, spec: .init(serviceType: .window, label: "RF window"))
        }
    }

    /// `showAs` simulations that turn a device into another accessory.
    static let simulations: [String: HandlerKind] = [
        "blind": .blind, "door": .door, "window": .window, "garage": .garage, "gate": .garage, "lock": .lock, "valve": .valve,
        "switch_valve": .valve, "tap": .tap, "sensor": .simulatedSensor, "sensor_leak": .sensorLeak, "p_button": .programmableButton,
        "doorbell": .doorbell, "purifier": .purifier, "tv": .tv,
    ]

    /// `showAs` of a TH10/TH16 (UIID 15, 181).
    static let thSimulations: [String: HandlerKind] = [
        "heater": .thHeater, "cooler": .thCooler, "humidifier": .thHumidifier, "dehumidifier": .thDehumidifier, "thermostat": .thThermostat,
    ]

    static let categories: [DeviceCategory: HandlerKind] = [
        .outlet: .outlet, .light: .light, .fan: .fan, .sensor: .sensor, .curtain: .curtain, .garage: .garage, .airConditioner: .airConditioner,
        .humidifier: .humidifier, .diffuser: .diffuser, .panel: .panel, .virtual: .virtual, .motor: .motor, .group: .group, .rfBridge: .rfBridge,
    ]

    /// RF sub-devices by kind.
    static let rfSubTypes: [String: HandlerKind] = [
        "button": .rfButton, "curtain": .rfButton, "sensor": .rfSensor, "blind": .rfBlind, "door": .rfDoor, "window": .rfWindow,
    ]

    /// The handler for a device: a simulation named by `showAs`, else its category, as the Homebridge plugin
    /// decides.
    static func resolve(showAs: String, uiid: Int, category: DeviceCategory) -> HandlerKind {
        if let simulation = simulations[showAs] { return simulation }
        if DeviceCatalog.isTHSensor(uiid), let simulation = thSimulations[showAs] { return simulation }
        if showAs == "heater" { return .heater }
        if showAs == "cooler" { return .cooler }
        if showAs == "fan", DeviceCatalog.isDimmableLightForFan(uiid) { return .lightFan }
        if let kind = categories[category] { return kind }
        if category == .thermostat { return DeviceCatalog.isTHSensor(uiid) ? .thSensor : .thermostat }
        if DeviceCatalog.isProgrammableSwitch(uiid) { return DeviceCatalog.channelCount(uiid) > 1 ? .switchMini : .switchMate }
        if showAs == "outlet" { return .outlet }
        // Water valves (SWV-BSP, UIID 7027) are faucets unless shown as a switch.
        if DeviceCatalog.isWaterValve(uiid), showAs != "switch" { return .tap }
        return .switch
    }
}

/// Builds the HomeKit accessories and their handlers: one per device, one per channel of a multi-channel
/// device, one per remote or sensor an RF Bridge learned (the bridge itself stays out of HomeKit).
@EWeLinkActor
final class AccessoryFactory {
    unowned let platform: EWeLinkPlatform

    init(platform: EWeLinkPlatform) {
        self.platform = platform
    }

    private var registry: DeviceRegistry { platform.registry }
    private var configuration: EWeLinkPlugin.Configuration { platform.configuration }
    private var logger: Logger { platform.logger }

    /// Adds or updates a device's accessories.
    func addAccessory(_ device: EWeLinkDevice) async {
        if configuration.isIgnored(device.deviceid) {
            logger.debug("Device is ignored: \(device.name)")
            return
        }
        let box = registry.store(device)
        let id = AccessoryRecord.accessoryID(device.deviceid)
        let category = DeviceCategory.resolve(device)
        if device.uiid == 126, category == .curtain {
            logger.debug("UIID 126 device \"\(device.name)\" has curtain params, treating as curtain")
        }
        logger.debug("Device \"\(device.name)\" [\(device.deviceid)] - UIID: \(device.uiid), Category: \(category.rawValue)")

        // Bridges are not user-facing: only their sub-devices go to HomeKit. Their handler routes RF events.
        if category == .rfBridge {
            if platform.context.accessory(id: id) != nil {
                logger.info("Removing bridge device from HomeKit (not user-facing): \(device.name)")
                await platform.removeAccessory(id: id)
            }
            createBridgeHandler(box)
            await createRFSubDevices(box)
            return
        }

        // Multi-channel devices get one accessory per channel, unless a single-accessory simulation is set.
        if category == .multiSwitch {
            if exposesChannels(device, category: category) {
                await createChannelAccessories(box)
                return
            }
            await removeChannelAccessories(device)
        }

        let existing = platform.context.accessory(id: id)
        if let existing {
            logger.info("Restoring existing accessory from cache: \(existing.name)")
            if let old = platform.contexts.value(id, "category")?.stringValue, old != category.rawValue {
                logger.warning("Category changed for \(device.name): \(old) → \(category.rawValue). Removing old services.")
            }
        } else {
            logger.info("Adding new accessory: \(device.name)")
        }
        platform.contexts.set(id, "category", .string(category.rawValue))
        let record = AccessoryRecord(deviceID: device.deviceid, displayName: sanitizeHomeKitName(device.name))
        let showAs = configuration.showAs(device.deviceid, category: category) ?? "default"
        let kind = HandlerKind.resolve(showAs: showAs.isEmpty ? "default" : showAs, uiid: device.uiid, category: category)
        install(kind, record: record, box: box, identity: "device|\(category.rawValue)|\(showAs)|\(device.uiid)|\(configuration.entryIdentity(device.deviceid, category: category))")
    }

    /// A multi-channel device shows its channels unless `showAs` names a single-accessory simulation.
    private func exposesChannels(_ device: EWeLinkDevice, category: DeviceCategory) -> Bool {
        guard let showAs = configuration.showAs(device.deviceid, category: category) else { return true }
        return HandlerKind.simulations[showAs] == nil
    }

    /// Channel accessories left from before a simulation was configured.
    private func removeChannelAccessories(_ device: EWeLinkDevice) async {
        let ids = DeviceRegistry.channelIDs(device.deviceid, channelCount: DeviceCatalog.channelCount(device.uiid))
        let stale = ids.filter { platform.context.accessory(id: $0) != nil || registry.handler($0) != nil }
        guard !stale.isEmpty else { return }
        logger.info("Removing \(stale.count) channel accessories for \(device.name)")
        for id in stale { await platform.removeAccessory(id: id) }
    }

    private func createBridgeHandler(_ box: DeviceBox) {
        let record = AccessoryRecord(deviceID: box.device.deviceid, displayName: box.device.name)
        let id = record.id
        if let existing = registry.handler(id) as? RFBridgeAccessory {
            existing.refreshFromDevice()
            return
        }
        registry.setHandler(RFBridgeAccessory(platform: platform, record: record, box: box), for: id)
    }

    /// The kind of an RF remote: buttons (1-4), a curtain (5, or a cover simulation from `bridgeSensors`), a
    /// sensor (6, 7); nil when unknown.
    private func rfSubType(_ remoteType: String, fullDeviceID: String) -> String? {
        if DeviceLimits.rfButtonTypes.contains(remoteType) { return "button" }
        if remoteType == DeviceLimits.rfCurtainType {
            if let type = configuration.bridgeSensors?.first(where: { $0.fullDeviceId == fullDeviceID })?.curtainType, ["blind", "door", "window"].contains(type) {
                return type
            }
            return "curtain"
        }
        if DeviceLimits.rfSensorTypes.contains(remoteType) { return "sensor" }
        return nil
    }

    private func createRFSubDevices(_ box: DeviceBox) async {
        let bridge = box.device
        let remotes = bridge.rfDevices
        guard !remotes.isEmpty else {
            logger.debug("RF Bridge \(bridge.name) has no learned RF devices")
            return
        }
        logger.info("Creating RF sub-devices for bridge \(bridge.name)...")
        var channel = 0
        for remote in remotes {
            let fullDeviceID = "\(bridge.deviceid)SW\(channel + 1)"
            logger.debug("RF sub-device \(remote.name): buttons=\(remote.buttons.map { "\($0.channel)=\($0.name)" }.joined(separator: ","))")
            guard let subType = rfSubType(remote.remoteType, fullDeviceID: fullDeviceID), let kind = HandlerKind.rfSubTypes[subType] else {
                logger.warning("Unknown RF device type \(remote.remoteType) for \(remote.name), skipping")
                continue
            }
            var record = AccessoryRecord(deviceID: fullDeviceID, displayName: sanitizeHomeKitName(remote.name))
            record.rfButtonIndex = channel
            record.buttons = remote.buttons
            record.name = remote.name
            let verb = platform.context.accessory(id: record.id) == nil ? "Adding" : "Restoring"
            logger.info("\(verb) RF sub-device: \(remote.name) (type: \(subType))")
            let buttons = remote.buttons.map { "\($0.channel)=\($0.name)" }.joined(separator: ",")
            install(
                kind, record: record, box: box, identity: "rf|\(subType)|\(channel)|\(buttons)",
                information: .init(manufacturer: bridge.brandName ?? "eWeLink", model: "RF \(subType)", serial: fullDeviceID, firmware: bridge.firmware ?? "1.0.0"))
            channel += remote.buttons.count
        }
        logger.info("Created \(remotes.count) RF sub-devices for bridge \(bridge.name)")
    }

    /// Accessories for every channel of a multi-channel device: 0 is the master, 1...n the channels.
    private func createChannelAccessories(_ box: DeviceBox) async {
        let device = box.device
        let channelCount = DeviceCatalog.channelCount(device.uiid)
        guard channelCount > 1 else { return }
        logger.info("Creating \(channelCount + 1) channels for multi-switch device \(device.name)...")
        let entry = configuration.multi(device.deviceid)
        let hidden = Set((entry?.hideChannels ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let inchChannels = entry?.inchChannels ?? false

        // A single accessory from a previous simulation goes.
        let singleID = AccessoryRecord.accessoryID(device.deviceid)
        if platform.context.accessory(id: singleID) != nil || registry.handler(singleID) != nil {
            logger.info("Removing old single accessory for \(device.name)")
            await platform.removeAccessory(id: singleID)
        }

        let safeName = sanitizeHomeKitName(device.name)
        var created = 0
        for channel in 0...channelCount {
            let fullDeviceID = "\(device.deviceid)SW\(channel)"
            let isHidden = hidden.contains(fullDeviceID) || hidden.contains(String(channel)) || (channel == 0 && inchChannels)
            var record = AccessoryRecord(deviceID: fullDeviceID, displayName: channel == 0 ? safeName : "\(safeName) \(channel)")
            if isHidden {
                logger.debug(channel == 0 ? "Channel \(channel) (master) is hidden for \(device.name)" : "Channel \(channel) is hidden for \(device.name)")
                if platform.context.accessory(id: record.id) != nil || registry.handler(record.id) != nil { await platform.removeAccessory(id: record.id) }
                continue
            }
            record.switchNumber = channel
            record.channelCount = channelCount
            let kind: HandlerKind = entry?.showAs == "outlet" ? .outlet : .switch
            let entryText = entry.flatMap { try? JSONValue(encoding: $0).text() } ?? "null"
            install(kind, record: record, box: box, identity: "channel|\(channel)|\(channelCount)|\(entryText)")
            created += 1
        }
        logger.info("Created \(created) channel accessories for \(device.name)")
    }

    struct Information {
        var manufacturer: String
        var model: String
        var serial: String
        var firmware: String
    }

    /// Installs a handler and publishes its accessory. A live handler of the same kind built from the same
    /// settings is kept and re-synced instead, so its timers (auto-off, a cover moving, a garage pulse)
    /// survive a re-discovery after a cache restore.
    func install(_ kind: HandlerKind, record: AccessoryRecord, box: DeviceBox, identity: String, information: Information? = nil) {
        let fullIdentity = "\(kind.rawValue)|\(identity)"
        if let existing = registry.handler(record.id), registry.identities[record.id] == fullIdentity {
            existing.refresh(record: record)
            existing.refreshFromDevice()
            return
        }
        registry.removeHandler(record.id)
        let handler = kind.make(platform, record, box)
        registry.setHandler(handler, for: record.id)
        registry.identities[record.id] = fullIdentity
        guard !handler.services.isEmpty else { return }
        let device = box.device
        let info = information ?? Information(
            manufacturer: device.brandName ?? "eWeLink", model: device.productModel ?? device.model ?? "Unknown", serial: device.deviceid,
            firmware: device.firmware ?? "1.0.0")
        let accessory = Accessory(
            id: record.id, name: record.displayName, manufacturer: info.manufacturer, model: info.model, serialNumber: info.serial,
            firmwareRevision: info.firmware, category: handler.category, services: handler.services)
        do {
            try platform.context.add(accessory)
        } catch {
            logger.error("Failed to initialize accessory for \(device.name) [\(device.deviceid)]: \(error)")
        }
    }
}
