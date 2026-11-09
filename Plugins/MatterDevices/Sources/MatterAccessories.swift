import Foundation
import Homeswift
import HomeswiftPlugin
import Matter

/// Sends a command to one of the node's endpoints; throws when the node does not take it.
typealias MatterCommandSender = @Sendable (_ endpoint: EndpointNumber, _ cluster: ClusterID, _ command: CommandID, _ fields: [TLVElement]) async throws -> Void

/// A node's accessories, built from its structure (Application Clusters and Device Library): which services stand for
/// which clusters, what each reported attribute sets, and the Switch endpoints whose events press HomeKit buttons.
struct MatterAccessoryPlan {
    var accessories: [Accessory] = []
    /// What an attribute's report sets, by attribute.
    var updates: [ConcreteAttribute: @Sendable (TLVValue) -> Void] = [:]
    /// The attributes subscribed to: those `updates` handles.
    var attributes: [ConcreteAttribute] { updates.keys.sorted { ($0.endpoint, $0.cluster, $0.attribute) < ($1.endpoint, $1.cluster, $1.attribute) } }
    /// Each switch endpoint's Stateless Programmable Switch.
    var buttons: [EndpointNumber: Service] = [:]
    /// What sort of device it is, for its settings (`x-kinds`): a remote when it only has buttons.
    var deviceKind = "device"
}

enum MatterAccessories {
    static let lightTypes: [DeviceType] = [DeviceTypes.onOffLight, DeviceTypes.dimmableLight, DeviceTypes.colorTemperatureLight, DeviceTypes.extendedColorLight]
    static let plugTypes: [DeviceType] = [DeviceTypes.onOffPlugInUnit, DeviceTypes.dimmablePlugInUnit]
    /// The Identify cluster (Application Clusters §1.2).
    static let identifyCluster: ClusterID = IdentifyCluster.id

    /// The accessories of a node: one for the node, and one per bridged device behind a bridge (Core §9.13), each with
    /// its parts. The node's own accessory id is `accessoryID`; a bridged device's adds `:<endpoint>`.
    static func plan(_ structure: NodeStructure, accessoryID: String, serialNumber: String, send: @escaping MatterCommandSender) -> MatterAccessoryPlan {
        var plan = MatterAccessoryPlan()
        let bridged = structure.endpoints.filter { $0.is(DeviceTypes.bridgedNode) }
        let bridgedParts = Set(bridged.flatMap { [$0.id] + $0.parts })
        // The node's own endpoints: everything but the bridged devices and the aggregator that lists them.
        let own = structure.endpoints.filter { !bridgedParts.contains($0.id) && !$0.is(DeviceTypes.aggregator) }
        var groups: [(id: String, name: String, endpoints: [NodeStructure.Endpoint], serial: String)] = [(accessoryID, structure.name, own, serialNumber)]
        for device in bridged {
            let endpoints = [device] + device.parts.compactMap(structure.endpoint)
            groups.append(("\(accessoryID):\(device.id)", device.label ?? "\(structure.name) \(device.id)", endpoints, "\(serialNumber)-\(device.id)"))
        }
        var kinds = Set<String>()
        let buttonNames = self.buttonNames(structure)
        for group in groups {
            var services: [Service] = []
            var primaryTaken = false
            for endpoint in group.endpoints.sorted(by: { $0.id < $1.id }) {
                services += self.services(of: endpoint, accessoryName: group.name, buttonName: buttonNames[endpoint.id], plan: &plan, kinds: &kinds,
                                          primaryTaken: &primaryTaken, send: send)
            }
            guard !services.isEmpty else { continue }
            if services.contains(where: { $0.type == .statelessProgrammableSwitch }) {
                let label = Service(.serviceLabel, subtype: "buttons")
                label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
                services.append(label)
            }
            let category: AccessoryCategory = switch services.first(where: \.isPrimary)?.type {
            case .lightbulb: .lightbulb
            case .outlet: .outlet
            case .switch: .switch
            case .statelessProgrammableSwitch: .programmableSwitch
            default: .sensor
            }
            // Identify (Application Clusters §1.2.6.1) blinks or beeps the device for a few seconds, when it can.
            let identify = group.endpoints.first { $0.has(identifyCluster) }.map { endpoint in
                { @Sendable () async throws in try await send(endpoint.id, identifyCluster, IdentifyCluster.Command.identify, [.field(0, .unsigned(5))]) }
            }
            plan.accessories.append(Accessory(
                id: group.id, name: group.name, manufacturer: structure.vendorName ?? "Matter", model: structure.productName ?? "Matter device",
                serialNumber: group.serial, firmwareRevision: structure.softwareVersion ?? "1.0.0", category: category, services: services,
                onIdentify: identify))
        }
        // A remote when it only has buttons; a light when it has one; else its first kind, alphabetically.
        plan.deviceKind = kinds.contains("light") ? "light" : kinds.min() ?? "device"
        return plan
    }

    // MARK: - An endpoint's services

    /// What a remote's buttons are called: a wheel channel's parts by their channel and role ("Channel 1 up"), so the Home
    /// app's list says which is which; other buttons are numbered.
    static func buttonNames(_ structure: NodeStructure) -> [EndpointNumber: String] {
        var names: [EndpointNumber: String] = [:]
        for channel in WheelChannel.channels(structure) {
            names[channel.up] = "Channel \(channel.number) up"
            names[channel.down] = "Channel \(channel.number) down"
            if let press = channel.press { names[press] = "Channel \(channel.number) button" }
        }
        return names
    }

    private static func services(of endpoint: NodeStructure.Endpoint, accessoryName: String, buttonName: String?, plan: inout MatterAccessoryPlan,
                                 kinds: inout Set<String>, primaryTaken: inout Bool, send: @escaping MatterCommandSender) -> [Service] {
        var services: [Service] = []
        /// The accessory's first service but its battery is its primary one.
        func primary() -> Bool {
            defer { primaryTaken = true }
            return !primaryTaken
        }
        let ep = endpoint.id
        func key(_ cluster: ClusterID, _ attribute: AttributeID) -> ConcreteAttribute { ConcreteAttribute(ep, cluster, attribute) }

        if endpoint.has(OnOffCluster.id) {
            let isLight = lightTypes.contains(where: endpoint.is), isPlug = plugTypes.contains(where: endpoint.is)
            let dimmable = isLight && endpoint.has(LevelControlCluster.id)
            let (type, kind, prefix): (ServiceType, String, String) = isLight ? (.lightbulb, "light", "light") : isPlug ? (.outlet, "plug", "outlet") : (.switch, "switch", "switch")
            kinds.insert(kind)
            let service = Service(type, name: accessoryName, subtype: "\(prefix):\(ep)", optional: dimmable ? [.brightness] : [], isPrimary: primary())
            let on = service.characteristic(.on)
            on.onWrite(changesOnly: true) { value in
                try await send(ep, OnOffCluster.id, (value.boolValue ?? false) ? OnOffCluster.Command.on : OnOffCluster.Command.off, [])
            }
            plan.updates[key(OnOffCluster.id, OnOffCluster.Attribute.onOff)] = { value in
                if let flag = value.bool { on.value = .bool(flag) }
            }
            if dimmable, let brightness = service[.brightness] {
                brightness.onWrite(changesOnly: true) { value in
                    let level = LevelControlCluster.level(percent: Double(value.intValue ?? 0))
                    // MoveToLevelWithOnOff (Application Clusters §1.6.7.6, MoveToLevel's fields of §1.6.7.1): the light's own
                    // transition time (null), options untouched.
                    try await send(ep, LevelControlCluster.id, LevelControlCluster.Command.moveToLevelWithOnOff,
                                   [.field(0, .unsigned(UInt64(level))), .field(1, .null), .field(2, .unsigned(0)), .field(3, .unsigned(0))])
                }
                plan.updates[key(LevelControlCluster.id, LevelControlCluster.Attribute.currentLevel)] = { value in
                    if let level = value.uint { brightness.value = .int(LevelControlCluster.percent(level: level)) }
                }
            }
            services.append(service)
        }

        /// A sensor: a service whose one characteristic follows one attribute, a nil reading (null, unknown) left out.
        func sensor(_ cluster: ClusterID, _ attribute: AttributeID, _ type: ServiceType, _ prefix: String, _ characteristic: CharacteristicType,
                    optional: [CharacteristicType] = [], reading: @escaping @Sendable (TLVValue) -> HAPValue?) {
            guard endpoint.has(cluster) else { return }
            kinds.insert("sensor")
            let service = Service(type, name: accessoryName, subtype: "\(prefix):\(ep)", optional: optional, isPrimary: primary())
            let target = service.characteristic(characteristic)
            plan.updates[key(cluster, attribute)] = { value in if let reading = reading(value) { target.value = reading } }
            services.append(service)
        }
        // A contact sensor's StateValue is true while in contact, closed (Device Library §7.1): HomeKit's 0.
        sensor(BooleanStateCluster.id, BooleanStateCluster.Attribute.stateValue, .contactSensor, "contact", .contactSensorState) { value in
            value.bool.map { .int($0 ? 0 : 1) }
        }
        sensor(OccupancySensingCluster.id, OccupancySensingCluster.Attribute.occupancy, .occupancySensor, "occupancy", .occupancyDetected) { value in
            value.uint.map { .int(Int($0 & 1)) }
        }
        // MeasuredValue is in hundredths of a degree, or of a percent of humidity, null while unknown.
        sensor(TemperatureMeasurementCluster.id, TemperatureMeasurementCluster.Attribute.measuredValue, .temperatureSensor, "temperature",
               .currentTemperature, optional: [.currentTemperature.with(minValue: -100, maxValue: 100, minStep: 0.1)]) { value in
            value.int.map { .double(Double($0) / 100) }
        }
        sensor(RelativeHumidityMeasurementCluster.id, RelativeHumidityMeasurementCluster.Attribute.measuredValue, .humiditySensor, "humidity",
               .currentRelativeHumidity) { value in
            value.uint.map { .double(min(Double($0) / 100, 100)) }
        }
        if endpoint.has(SwitchCluster.id) {
            kinds.insert("remote")
            let number = plan.buttons.count + 1
            let validValues = buttonEvents(endpoint)
            let name = buttonName ?? "Button \(number)"
            let service = Service(.statelessProgrammableSwitch, name: name, subtype: MatterRemote.part(button: ep),
                                  optional: [.serviceLabelIndex, .configuredName,
                                             .programmableSwitchEvent.with(minValue: 0, maxValue: Double(validValues.max() ?? 0), validValues: validValues)],
                                  isPrimary: primary())
            service[.serviceLabelIndex]?.value = .int(number)
            service[.configuredName]?.value = .string(name)
            plan.buttons[ep] = service
            services.append(service)
        }
        if endpoint.hasBattery {
            let service = Service(.battery, name: "Battery", subtype: "battery:\(ep)", optional: [.batteryLevel, .chargingState])
            let level = service.characteristic(.batteryLevel), low = service.characteristic(.statusLowBattery)
            service.characteristic(.chargingState).value = .int(HAPConstants.ChargingState.notChargeable)
            plan.updates[key(PowerSourceCluster.id, PowerSourceCluster.Attribute.batPercentRemaining)] = { value in
                // BatPercentRemaining is in half percents, null while unknown.
                if let halves = value.uint { level.value = .int(Int(min(halves, 200) / 2)) }
            }
            plan.updates[key(PowerSourceCluster.id, PowerSourceCluster.Attribute.batChargeLevel)] = { value in
                // BatChargeLevel: 0 OK, 1 warning, 2 critical.
                if let charge = value.uint { low.value = .int(charge >= 1 ? 1 : 0) }
            }
            services.append(service)
        }
        return services
    }

    // MARK: - Buttons

    /// The Programmable Switch Events a switch endpoint can give: a rotary part's turn is a single press; a button's
    /// double press needs MultiPressMax 2 and its long press the long-press feature (Application Clusters §1.13.4, §1.13.5.3).
    static func buttonEvents(_ endpoint: NodeStructure.Endpoint) -> [Int] {
        if endpoint.isRotary { return [HAPConstants.ProgrammableSwitchEvent.singlePress] }
        var events = [HAPConstants.ProgrammableSwitchEvent.singlePress]
        let features = endpoint.switchFeatureSet
        if features.contains(.momentarySwitchMultiPress), (endpoint.multiPressMax ?? 0) >= 2 { events.append(HAPConstants.ProgrammableSwitchEvent.doublePress) }
        if features.contains(.momentarySwitchLongPress) { events.append(HAPConstants.ProgrammableSwitchEvent.longPress) }
        return events
    }

    /// The Programmable Switch Event a Switch event makes, or nil (Application Clusters §1.13.6, in the sequences of
    /// §1.13.7 and §1.13.8): a multi-press switch counts presses in MultiPressComplete, which ends a gesture (0 is an
    /// aborted one, beyond MultiPressMax: nothing); one without counts each ShortRelease, and one without release events
    /// each InitialPress. A long press is LongPress. A rotary part gives one single press per turn.
    static func buttonEvent(_ event: EventID, data: TLVValue, endpoint: NodeStructure.Endpoint) -> Int? {
        let features = endpoint.switchFeatureSet
        let multi = features.contains(.momentarySwitchMultiPress)
        switch event {
        case SwitchCluster.Event.multiPressComplete where multi:
            let count = data[1]?.uint ?? 1
            guard count > 0 else { return nil }
            if endpoint.isRotary { return HAPConstants.ProgrammableSwitchEvent.singlePress }
            switch count {
            case 1: return HAPConstants.ProgrammableSwitchEvent.singlePress
            case 2: return HAPConstants.ProgrammableSwitchEvent.doublePress
            default: return nil
            }
        case SwitchCluster.Event.longPress:
            return HAPConstants.ProgrammableSwitchEvent.longPress
        case SwitchCluster.Event.shortRelease where !multi:
            return HAPConstants.ProgrammableSwitchEvent.singlePress
        case SwitchCluster.Event.initialPress where !multi && !features.contains(.momentarySwitchRelease):
            return HAPConstants.ProgrammableSwitchEvent.singlePress
        default:
            return nil
        }
    }
}
