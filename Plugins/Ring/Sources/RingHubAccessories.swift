import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// An accessory and what shows a device's data on it.
struct RingBuiltAccessory {
    /// The identity seed after `Ring:` (docs/clean-room/Ring.md, 4.1): the Device Id.
    let seed: String
    let deviceType: String
    let accessory: Accessory
    /// Shows the device's data; also called for the zids in `follows` (a thermostat's temperature sensor).
    let update: @Sendable (JSONValue) -> Void
    var follows: [String] = []
}

/// The hub devices' accessories (docs/clean-room/Ring.md, 4.2 and 4.5).
enum RingHubAccessories {
    enum Kind: Equatable {
        case contact, motion, floodFreeze, freeze, securityPanel, brightnessOnly, smoke, carbonMonoxide, smokeAndCarbonMonoxide
        case beam, fan, multiLevelSwitch, outlet, plainSwitch, temperature, water, thermostat, valve, unknownZWave, lock
    }

    static func kind(of data: JSONValue) -> Kind? {
        let type = data["deviceType"]?.stringValue ?? ""
        let category = data["categoryId"]?.saturatingIntValue
        switch type {
        case "sensor.contact", "sensor.zone", "sensor.tilt", "sensor.glassbreak": return .contact
        case "sensor.motion": return .motion
        case "sensor.flood-freeze": return .floodFreeze
        case "sensor.freeze": return .freeze
        case "security-panel": return .securityPanel
        case "hub.redsky", "hub.kili", "security-keypad": return .brightnessOnly
        case "alarm.smoke": return .smoke
        case "alarm.co": return .carbonMonoxide
        case "listener.smoke-co", "comp.bluejay.sensor_bluejay_wsc": return .smokeAndCarbonMonoxide
        case "motion-sensor.beams", "switch.beams", "switch.multilevel.beams", "switch.transformer.beams", "group.light-group.beams": return .beam
        case "switch.multilevel": return category == 17 ? .fan : .multiLevelSwitch
        case "switch.multilevel.bulb": return .multiLevelSwitch
        case "switch": return category == 1 ? .outlet : .plainSwitch
        case "sensor.temperature": return .temperature
        case "sensor.water": return .water
        case "temperature-control.thermostat": return .thermostat
        case "valve.water": return .valve
        case "unknown.zwave": return .unknownZWave
        case "sensor": return (data["name"]?.stringValue ?? "").lowercased().contains("motion") ? .motion : .contact
        default: return type == "lock" || type.hasPrefix("lock.") ? .lock : nil
        }
    }

    /// The infrastructure types whose hiding is not logged.
    static let quietTypes: Set<String> = [
        "adapter.ringnet", "adapter.zigbee", "access-code.vault", "access-code", "adapter.zwave", "range-extender.zwave", "device.beams", "security-panic",
    ]

    /// The alarm states that count as triggered (all but `entry-delay` unless `alarmOnEntryDelay`).
    static let alarmStates: Set<String> = [
        "burglar-alarm", "entry-delay", "fire-alarm", "co-alarm", "panic", "user-verified-burglar-alarm", "user-verified-co-or-fire-alarm",
        "burglar-accelerated-alarm", "fire-accelerated-alarm",
    ]
    static let burglarStates: Set<String> = ["burglar-alarm", "user-verified-burglar-alarm", "burglar-accelerated-alarm"]
    static let fireStates: Set<String> = ["fire-alarm", "user-verified-co-or-fire-alarm", "fire-accelerated-alarm"]

    /// The accessory of a hub device, or nil for one that is not exposed (disabled, infrastructure, no mapping).
    static func make(zid: String, data: JSONValue, hub: RingLocationHub, environment: RingEnvironment) -> RingBuiltAccessory? {
        guard data["status"]?.stringValue != "disabled", let kind = kind(of: data) else { return nil }
        let name = data["name"]?.stringValue ?? zid
        let deviceType = data["deviceType"]?.stringValue ?? ""
        var parts = RingCommon.services(zid: zid, data: data, name: name, hub: hub, environment: environment)
        var services: [Service] = []
        var show: @Sendable (JSONValue) -> Void = { _ in }
        let logger = environment.logger

        func onOff(_ service: Service, field: String = "on", log verb: String = "Turning") {
            service.characteristic(.on).onWrite { value in
                let on = value.boolValue ?? false
                logger.info("\(verb) \(name) \(on ? "On" : "Off")")
                environment.background("Turning \(name) \(on ? "on" : "off")") { try await hub.set(zid, [field: .bool(on)]) }
            }
        }

        /// A 0…100 characteristic from a 0…1 field, written through the level rule.
        func level(_ characteristic: Characteristic, field: String, log: String) -> @Sendable (JSONValue) -> Void {
            let guardian = RingLevel(debounce: environment.timing.levelDebounce)
            characteristic.onWrite { value in
                let percent = value.doubleValue ?? 0
                logger.info("Setting \(log) of \(name) to \(Int(saturating: percent) ?? 0)%")
                environment.background("Setting the \(log) of \(name)") {
                    try await guardian.write(percent / 100) { try await hub.set(zid, [field: .number($0)]) }
                }
            }
            return { data in
                let shown = guardian.shown(data[field]?.looseDouble) ?? 0
                characteristic.show(.int(Int(saturating: (shown * 100).rounded(), in: 0...100) ?? 0))
            }
        }

        switch kind {
        case .contact:
            let sensor = RingCommon.sensor(.contactSensor, data: data, isPrimary: true)
            parts.sensors = [sensor]
            services = [sensor]
            show = { data in sensor.characteristic(.contactSensorState).show(.int(data["faulted"]?.boolValue == true ? 1 : 0)) }

        case .motion:
            let sensor = RingCommon.sensor(.motionSensor, data: data, isPrimary: true)
            parts.sensors = [sensor]
            services = [sensor]
            show = { data in sensor.characteristic(.motionDetected).show(.bool(data["faulted"]?.boolValue == true)) }

        case .floodFreeze:
            let flood = RingCommon.sensor(.leakSensor, name: "\(name) Flood Sensor", data: data, isPrimary: true)
            let freeze = RingCommon.sensor(.occupancySensor, name: "\(name) Freeze Sensor", data: data)
            parts.sensors = [flood, freeze]
            services = [flood, freeze]
            show = { data in
                let flooding = data["flood"]?["faulted"]?.boolValue == true, freezing = data["freeze"]?["faulted"]?.boolValue == true
                if flooding, flood.characteristic(.leakDetected).value != .int(1) { logger.info("\(name) Detected Flooding") }
                if freezing, freeze.characteristic(.occupancyDetected).value != .int(1) { logger.info("\(name) Detected Freezing") }
                flood.characteristic(.leakDetected).show(.int(flooding ? 1 : 0))
                freeze.characteristic(.occupancyDetected).show(.int(freezing ? 1 : 0))
            }

        case .freeze, .water:
            let sensor = RingCommon.sensor(kind == .water ? .leakSensor : .occupancySensor, data: data, isPrimary: true)
            parts.sensors = [sensor]
            services = [sensor]
            let characteristic = sensor.characteristic(kind == .water ? .leakDetected : .occupancyDetected)
            show = { data in
                let detected = data["faulted"]?.boolValue == true
                if detected, characteristic.value != .int(1) { logger.info("\(name) Detected \(kind == .water ? "Water" : "Freezing")") }
                characteristic.show(.int(detected ? 1 : 0))
            }

        case .temperature:
            let sensor = RingCommon.sensor(.temperatureSensor, data: data, isPrimary: true)
            parts.sensors = [sensor]
            services = [sensor]
            show = { data in if let celsius = data["celsius"]?.looseDouble { sensor.characteristic(.currentTemperature).show(.double(celsius)) } }

        case .smoke, .carbonMonoxide, .smokeAndCarbonMonoxide:
            let smoke = kind == .carbonMonoxide ? nil : RingCommon.sensor(.smokeSensor, data: data, isPrimary: true)
            let co = kind == .smoke ? nil : RingCommon.sensor(.carbonMonoxideSensor, data: data, isPrimary: smoke == nil)
            parts.sensors = [smoke, co].compactMap { $0 }
            services = parts.sensors
            show = { data in
                func active(_ key: String, component: String) -> Bool {
                    if kind != .smokeAndCarbonMonoxide { return data["alarmStatus"]?.stringValue == "active" }
                    return (data[key]?["alarmStatus"] ?? data["components"]?[component]?["alarmStatus"])?.stringValue == "active"
                }
                smoke?.characteristic(.smokeDetected).show(.int(active("smoke", component: "alarm.smoke") ? 1 : 0))
                co?.characteristic(.carbonMonoxideDetected).show(.int(active("co", component: "alarm.co") ? 1 : 0))
            }

        case .securityPanel:
            return securityPanel(zid: zid, data: data, name: name, parts: parts, hub: hub, environment: environment)

        case .brightnessOnly:
            if data["brightness"]?.looseDouble != nil {
                let light = Service(.lightbulb, name: name, optional: [.brightness], isPrimary: true)
                services = [light]
                let memoryKey = zid
                light.characteristic(.brightness).onWrite { value in
                    let percent = Int(saturating: value.doubleValue ?? 0, in: 0...100) ?? 0
                    if percent > 0 { _ = environment.memory.update(memoryKey) { $0 = RingMemory(targetingNightMode: $0?.targetingNightMode, brightness: percent) } }
                    logger.info("Setting brightness of \(name) to \(percent)%")
                    environment.background("Setting the brightness of \(name)") { try await hub.set(zid, ["brightness": .number(Double(percent) / 100)]) }
                }
                light.characteristic(.on).onWrite { value in
                    let on = value.boolValue ?? false
                    let percent = on ? environment.memory[memoryKey]?.brightness ?? 100 : 0
                    logger.info("Setting brightness of \(name) to \(percent)%")
                    environment.background("Setting the brightness of \(name)") { try await hub.set(zid, ["brightness": .number(Double(percent) / 100)]) }
                }
                show = { data in
                    let brightness = data["brightness"]?.looseDouble ?? 0
                    let percent = Int(saturating: (brightness * 100).rounded(), in: 0...100) ?? 0
                    if percent > 0, environment.memory[memoryKey]?.brightness != percent {
                        _ = environment.memory.update(memoryKey) { $0 = RingMemory(targetingNightMode: $0?.targetingNightMode, brightness: percent) }
                    }
                    light.characteristic(.on).show(.bool(percent > 0))
                    light.characteristic(.brightness).show(.int(percent))
                }
            }

        case .beam:
            var shows: [@Sendable (JSONValue) -> Void] = []
            if deviceType != "motion-sensor.beams" {
                let light = Service(.lightbulb, name: name, optional: deviceType == "switch.multilevel.beams" ? [.brightness] : [], isPrimary: true)
                services.append(light)
                let groupID = deviceType == "group.light-group.beams" ? data["groupId"]?.stringValue : nil
                let duration = environment.configuration.beamDurationSeconds.map { min(max($0, 1), 32767) }
                let locationID = hub.locationID
                light.characteristic(.on).onWrite { value in
                    let on = value.boolValue ?? false
                    logger.info("Turning \(name) \(on ? "On" : "Off")")
                    environment.background("Turning \(name) \(on ? "on" : "off")") {
                        if let groupID {
                            try await environment.client.setLightGroup(locationID: locationID, groupID: groupID, on: on, duration: duration ?? 60)
                        } else if on {
                            var mode: [String: JSONValue] = ["lightMode": "on"]
                            if let duration { mode["duration"] = .number(Double(duration)) }
                            try await hub.command(zid, "light-mode.set", data: .object(mode))
                        } else {
                            try await hub.command(zid, "light-mode.set", data: ["lightMode": "default"])
                        }
                    }
                }
                shows.append { data in light.characteristic(.on).show(.bool(data["on"]?.boolValue == true)) }
                if deviceType == "switch.multilevel.beams" { shows.append(level(light.characteristic(.brightness), field: "level", log: "brightness")) }
            }
            if data["motionStatus"] != nil, data["motionSensorEnabled"]?.boolValue != false {
                let motion = RingCommon.sensor(.motionSensor, data: data, isPrimary: services.isEmpty)
                parts.sensors = [motion]
                services.append(motion)
                shows.append { data in motion.characteristic(.motionDetected).show(.bool(data["motionStatus"]?.stringValue == "faulted")) }
            }
            let all = shows
            show = { data in for show in all { show(data) } }

        case .multiLevelSwitch, .fan:
            let hasLevel = data["level"] != nil
            let service = kind == .fan
                ? Service(.fan, name: name, optional: hasLevel ? [.rotationSpeed] : [], isPrimary: true)
                : Service(.lightbulb, name: name, optional: hasLevel ? [.brightness] : [], isPrimary: true)
            services = [service]
            onOff(service)
            let showLevel = hasLevel ? level(service.characteristic(kind == .fan ? .rotationSpeed : .brightness), field: "level", log: kind == .fan ? "speed" : "brightness") : nil
            show = { data in
                service.characteristic(.on).show(.bool(data["on"]?.boolValue == true))
                showLevel?(data)
            }

        case .outlet:
            let outlet = Service(.outlet, name: name, isPrimary: true)
            services = [outlet]
            onOff(outlet)
            show = { data in
                let on = data["on"]?.boolValue == true
                outlet.characteristic(.on).show(.bool(on))
                outlet.characteristic(.outletInUse).show(.bool(on))
            }

        case .plainSwitch:
            let service = Service(.switch, name: name, isPrimary: true)
            services = [service]
            onOff(service)
            show = { data in service.characteristic(.on).show(.bool(data["on"]?.boolValue == true)) }

        case .unknownZWave:
            let service = Service(.switch, name: name, isPrimary: true)
            services = [service]
            service.characteristic(.on).onWrite { value in
                let on = value.boolValue ?? false
                logger.info("Turning \(name) \(on ? "On" : "Off")")
                environment.background("Turning \(name) \(on ? "on" : "off")") { try await hub.set(zid, ["basicValue": .number(on ? 255 : 0)]) }
            }
            show = { data in service.characteristic(.on).show(.bool((data["basicValue"]?.looseDouble ?? 0) != 0)) }

        case .valve:
            let service = Service(.switch, name: name, isPrimary: true)
            services = [service]
            service.characteristic(.on).onWrite { value in
                let open = value.boolValue ?? false
                logger.info("Turning \(name) \(open ? "On" : "Off")")
                environment.background("Turning \(name) \(open ? "on" : "off")") { try await hub.command(zid, open ? "valve.open" : "valve.close") }
            }
            show = { data in service.characteristic(.on).show(.bool(data["valveState"]?.stringValue == "open")) }

        case .lock:
            let lock = Service(.lockMechanism, name: name, isPrimary: true)
            services = [lock]
            let requested = NIOLockedValueBox<Int?>(nil)
            @Sendable func current(_ data: JSONValue) -> Int {
                switch data["locked"]?.stringValue {
                case "unlocked": 0
                case "locked": 1
                case "jammed": 2
                default: 3
                }
            }
            let showLock: @Sendable (JSONValue) -> Void = { data in
                let state = current(data)
                lock.characteristic(.lockCurrentState).show(.int(state))
                let target = requested.withLockedValue { requested -> Int in
                    if requested == state { requested = nil }
                    // An in-flight unsecure (0) reads as none, as the original's.
                    return requested.flatMap { $0 == 0 ? nil : $0 } ?? state
                }
                // Jammed and unknown have no target in HomeKit: the last one stays.
                if target <= 1 { lock.characteristic(.lockTargetState).show(.int(target)) }
            }
            lock.characteristic(.lockTargetState).onWrite { value in
                let secured = (value.intValue ?? 1) == 1
                let state = current(hub.inventory.data(zid) ?? data)
                requested.withLockedValue { $0 = (secured ? 1 : 0) == state ? nil : (secured ? 1 : 0) }
                environment.background("\(secured ? "Locking" : "Unlocking") \(name)") { try await hub.command(zid, secured ? "lock.lock" : "lock.unlock") }
            }
            show = showLock

        case .thermostat:
            return thermostat(zid: zid, data: data, name: name, parts: parts, hub: hub, environment: environment)
        }

        let common = parts, shown = show
        let showAll: @Sendable (JSONValue) -> Void = { data in
            shown(data)
            RingCommon.show(data, on: common)
        }
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: zid), name: name, manufacturer: data["manufacturerName"]?.stringValue ?? "Ring", model: deviceType,
            serialNumber: data["serialNumber"]?.stringValue ?? "Unknown", category: .other,
            services: services + [parts.speaker, parts.battery].compactMap { $0 })
        showAll(data)
        return RingBuiltAccessory(seed: zid, deviceType: deviceType, accessory: accessory, update: showAll)
    }

    // MARK: Security panel

    static func securityPanel(zid: String, data: JSONValue, name: String, parts: RingCommon.Parts, hub: RingLocationHub, environment: RingEnvironment) -> RingBuiltAccessory {
        let configuration = environment.configuration
        let bypassMode = ["all", "some"].contains(configuration.nightModeBypassFor ?? "") ? configuration.nightModeBypassFor : nil
        let validTargets = bypassMode == nil ? [0, 1, 3] : [0, 1, 2, 3]
        let panel = Service(.securitySystem, name: name, optional: [.securitySystemTargetState.with(validValues: validTargets)], isPrimary: true)
        let siren = configuration.hideAlarmSirenSwitch == true ? nil : Service(.switch, name: "\(name) Siren")
        let memoryKey = zid
        let logger = environment.logger
        let triggerStates = configuration.alarmOnEntryDelay == true ? alarmStates : alarmStates.subtracting(["entry-delay"])

        @Sendable func target(_ data: JSONValue) -> Int {
            let mode = data["mode"]?.stringValue
            if environment.memory[memoryKey]?.targetingNightMode == true, let bypassMode, mode == bypassMode { return 2 }
            if environment.memory[memoryKey]?.targetingNightMode == true {
                _ = environment.memory.update(memoryKey) { $0 = RingMemory(targetingNightMode: false, brightness: $0?.brightness) }
            }
            switch mode {
            case "all": return 1
            case "some": return 0
            default: return 3
            }
        }
        let show: @Sendable (JSONValue) -> Void = { data in
            let targetState = target(data)
            let triggered = data["alarmInfo"]?["state"]?.stringValue.map(triggerStates.contains) ?? false
            panel.characteristic(.securitySystemTargetState).show(.int(targetState))
            panel.characteristic(.securitySystemCurrentState).show(.int(triggered ? 4 : targetState))
            siren?.characteristic(.on).show(.bool(data["siren"]?["state"]?.stringValue == "on"))
            RingCommon.show(data, on: parts)
        }
        panel.characteristic(.securitySystemTargetState).onWrite { value in
            let state = value.intValue ?? 3
            _ = environment.memory.update(memoryKey) { $0 = RingMemory(targetingNightMode: state == 2, brightness: $0?.brightness) }
            var effective = state, bypass: [String] = [], bypassNames: [String] = []
            if state == 2 {
                if let bypassMode {
                    effective = bypassMode == "all" ? 1 : 0
                    for device in hub.inventory.all where device.data["deviceType"]?.stringValue == "sensor.contact" && device.data["faulted"]?.boolValue == true {
                        bypass.append(device.zid)
                        bypassNames.append(device.data["name"]?.stringValue ?? device.zid)
                    }
                } else {
                    effective = 0
                }
            }
            let mode = effective == 1 ? "all" : effective == 3 ? "none" : "some"
            let suffix = bypassNames.isEmpty ? "" : " - Bypassing Sensors: \(bypassNames.joined(separator: ", "))"
            logger.info(effective == 3 ? "Disarming \(name)" : effective == 1 ? "Arming (Away) \(name)\(suffix)" : "Arming (Home) \(name)\(suffix)")
            let bypassed = bypass
            environment.tasks.add {
                do {
                    try await hub.setAlarmMode(panel: zid, mode: mode, bypass: bypassed)
                } catch is CancellationError {
                } catch {
                    logger.error("\(error)")
                    let current = hub.inventory.data(zid) ?? data
                    panel.characteristic(.securitySystemTargetState).value = .int(target(current))
                }
            }
        }
        siren?.characteristic(.on).onWrite { value in
            let on = value.boolValue ?? false
            environment.background("\(on ? "Sounding" : "Silencing") the siren of \(name)") {
                try await hub.command(zid, on ? "security-panel.sound-siren" : "security-panel.silence-siren")
            }
        }
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: zid), name: name, manufacturer: data["manufacturerName"]?.stringValue ?? "Ring", model: "security-panel",
            serialNumber: data["serialNumber"]?.stringValue ?? "Unknown", category: .securitySystem,
            services: [panel, siren, parts.speaker, parts.battery].compactMap { $0 })
        show(data)
        return RingBuiltAccessory(seed: zid, deviceType: "security-panel", accessory: accessory, update: show)
    }

    /// The location's Panic Buttons: switches that dispatch real emergency signals, marked as security controls.
    static func panicButtons(panelZid zid: String, data: JSONValue, locationName: String, hub: RingLocationHub, environment: RingEnvironment) -> RingBuiltAccessory {
        let logger = environment.logger
        func button(_ subtype: String, _ name: String, signal: String, states: Set<String>) -> (Service, @Sendable (JSONValue) -> Void) {
            let service = Service(.switch, name: name, subtype: subtype, optional: [.configuredName])
            service.characteristic(.configuredName).value = .string(name)
            service.characteristic(.on).securityControl().onWrite { value in
                if value.boolValue == true {
                    logger.info("\(name) activated for \(locationName)")
                    environment.background("\(name) for \(locationName)") {
                        guard let asset = await hub.alarmAsset else { throw RingError.unexpected("Cannot dispatch panic events without an alarm base station") }
                        try await environment.client.dispatchPanic(locationID: hub.locationID, assetUUID: asset, signal: signal)
                    }
                } else {
                    logger.info("\(name) turned off for \(locationName)")
                    environment.background("Turning off the \(name) for \(locationName)") { try await hub.setAlarmMode(panel: zid, mode: "none", bypass: []) }
                }
            }
            return (service, { data in service.characteristic(.on).show(.bool(data["alarmInfo"]?["state"]?.stringValue.map(states.contains) ?? false)) })
        }
        let (burglar, showBurglar) = button("Burglar", "Burglar Alarm", signal: "user-verified-burglar-xa", states: burglarStates)
        let (fire, showFire) = button("Fire", "Fire Alarm", signal: "user-verified-fire-xa", states: fireStates)
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: "\(zid)panic"), name: "Panic Buttons", manufacturer: data["manufacturerName"]?.stringValue ?? "Ring",
            model: "Panic Buttons for \(locationName)", serialNumber: "None", category: .securitySystem, services: [burglar, fire])
        let show: @Sendable (JSONValue) -> Void = { data in
            showBurglar(data)
            showFire(data)
        }
        show(data)
        return RingBuiltAccessory(seed: "\(zid)panic", deviceType: "security-panel", accessory: accessory, update: show, follows: [])
    }

    // MARK: Thermostat

    static func thermostat(zid: String, data: JSONValue, name: String, parts: RingCommon.Parts, hub: RingLocationHub, environment: RingEnvironment) -> RingBuiltAccessory {
        let logger = environment.logger
        let low = max(data["setPointMin"]?.looseDouble ?? 10, 10), high = min(data["setPointMax"]?.looseDouble ?? 38, 38)
        let service = Service(.thermostat, name: name, optional: [
            .targetTemperature.with(minValue: low, maxValue: high),
            .targetHeatingCoolingState.with(validValues: [0, 1, 2]),
            .temperatureDisplayUnits.with(validValues: [1]),
        ], isPrimary: true)
        service.characteristic(.temperatureDisplayUnits).value = .int(1)
        service.characteristic(.temperatureDisplayUnits).onWrite { _ in service.characteristic(.temperatureDisplayUnits).value = .int(1) }
        let component = hub.inventory.all.first {
            $0.data["parentZid"]?.stringValue == zid && $0.data["deviceType"]?.stringValue == "sensor.temperature"
        }?.zid

        let show: @Sendable (JSONValue) -> Void = { _ in
            let data = hub.inventory.data(zid) ?? data
            let mode = data["mode"]?.stringValue
            service.characteristic(.targetHeatingCoolingState).show(.int(["heat": 1, "aux": 1, "cool": 2][mode ?? ""] ?? 0))
            if let setPoint = data["setPoint"]?.looseDouble { service.characteristic(.targetTemperature).show(.double(min(max(setPoint, low), high))) }
            guard let component else { return }
            let celsius = hub.inventory.data(component)?["celsius"]?.looseDouble
            let temperature: Double
            if let celsius, celsius != 0 {
                temperature = (celsius * 10).rounded() / 10
            } else {
                logger.error("\(name) has no temperature; showing 22 °C")
                temperature = 22
            }
            service.characteristic(.currentTemperature).show(.double(temperature))
            var heating = 0
            if mode != "off", let celsius, let setPoint = data["setPoint"]?.looseDouble {
                if abs(celsius - setPoint) < 0.1 {
                    heating = 0
                } else if celsius >= setPoint + 0.1, mode == "cool" {
                    heating = 2
                } else if celsius <= setPoint - 0.1, mode == "heat" || mode == "aux" {
                    heating = 1
                }
            }
            service.characteristic(.currentHeatingCoolingState).show(.int(heating))
            RingCommon.show(data, on: parts)
        }
        service.characteristic(.targetHeatingCoolingState).onWrite { value in
            guard let mode = [0: "off", 1: "heat", 2: "cool"][value.intValue ?? -1] else {
                logger.error("\(name) cannot take that mode")
                return
            }
            logger.info("Setting \(name) mode to \(mode)")
            environment.background("Setting the mode of \(name)") { try await hub.set(zid, ["mode": .string(mode)]) }
        }
        service.characteristic(.targetTemperature).onWrite { value in
            guard let setPoint = value.doubleValue, (low...high).contains(setPoint) else {
                logger.error("\(name) takes set points from \(low) to \(high) °C")
                return
            }
            environment.background("Setting the temperature of \(name)") { try await hub.set(zid, ["setPoint": .number(setPoint)]) }
        }
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: zid), name: name, manufacturer: data["manufacturerName"]?.stringValue ?? "Ring",
            model: "temperature-control.thermostat", serialNumber: data["serialNumber"]?.stringValue ?? "Unknown", category: .thermostat,
            services: [service, parts.speaker, parts.battery].compactMap { $0 })
        show(data)
        return RingBuiltAccessory(seed: zid, deviceType: "temperature-control.thermostat", accessory: accessory, update: show, follows: component.map { [$0] } ?? [])
    }
}
