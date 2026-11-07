import Foundation
import Homeswift
import HomeswiftPlugin

/// Samsung (and other) appliances (docs/clean-room/SmartThings.md, section 8): a power or Start Switch, a "Running"
/// Occupancy Sensor, compartment temperatures, and their other values for the web page and the Assistant.
enum Appliance: String, Sendable {
    case washer, dryer, dishwasher, oven, refrigerator, robotVacuum

    static func kind(of device: SmartThingsDevice, status: DeviceStatus) -> Appliance? {
        guard let main = device.main else { return nil }
        if main.has("washerOperatingState") || main.has("samsungce.washerOperatingState") { return .washer }
        if main.has("dryerOperatingState") || main.has("samsungce.dryerOperatingState") { return .dryer }
        if main.has("dishwasherOperatingState") || main.has("samsungce.dishwasherOperation") { return .dishwasher }
        if main.has("ovenOperatingState") || main.has("samsungce.ovenOperatingState") { return .oven }
        if main.has("robotCleanerOperatingState") || main.has("samsungce.robotCleanerOperatingState") || main.has("robotCleanerMovement") { return .robotVacuum }
        let compartments: Swift.Set<String> = ["cooler", "freezer", "cvroom", "onedoor", "flexzone"]
        if device.has("refrigerationSetpoint")
            || device.components.contains(where: { compartments.contains($0.id) && $0.has("temperatureMeasurement") })
            || (main.has("samsungce.driverState") && main.has("custom.disabledComponents")) {
            return .refrigerator
        }
        return nil
    }

    /// The standard operating-state capability of a laundry appliance.
    var operatingState: String? {
        switch self {
        case .washer: "washerOperatingState"
        case .dryer: "dryerOperatingState"
        case .dishwasher: "dishwasherOperatingState"
        default: nil
        }
    }

    var jobStateAttribute: String? {
        switch self {
        case .washer: "washerJobState"
        case .dryer: "dryerJobState"
        case .dishwasher: "dishwasherJobState"
        default: nil
        }
    }

    var modeCapability: String? {
        switch self {
        case .washer: "washerMode"
        case .dryer: "dryerMode"
        case .dishwasher: "dishwasherMode"
        default: nil
        }
    }

    var samsungCapability: String? {
        switch self {
        case .washer: "samsungce.washerOperatingState"
        case .dryer: "samsungce.dryerOperatingState"
        case .dishwasher: "samsungce.dishwasherOperation"
        case .oven: "samsungce.ovenOperatingState"
        case .robotVacuum: "samsungce.robotCleanerOperatingState"
        case .refrigerator: nil
        }
    }

    var cycleCapability: String? {
        switch self {
        case .washer: "samsungce.washerCycle"
        case .dryer: "samsungce.dryerCycle"
        case .dishwasher: "samsungce.dishwasherWashingCourse"
        default: nil
        }
    }

    var category: AccessoryCategory {
        switch self {
        case .robotVacuum: .switch
        case .refrigerator, .oven: .sensor
        default: .switch
        }
    }

    /// A laundry job state that does not count as running, whatever the machine says (section 8.2).
    static let idleJobs: Swift.Set<String> = ["finish", "finished", "none", "delaywash"]

    static func isRunning(_ appliance: Appliance, _ status: DeviceStatus) -> Bool {
        switch appliance {
        case .washer, .dryer, .dishwasher:
            guard let capability = appliance.operatingState, let job = appliance.jobStateAttribute else { return false }
            let machine = status.string("main", capability, "machineState") ?? status.string("main", appliance.samsungCapability ?? "", "machineState")
            guard machine == "run" else { return false }
            let jobState = status.string("main", capability, job) ?? status.string("main", appliance.samsungCapability ?? "", job)
            return !(jobState.map { idleJobs.contains($0.lowercased()) } ?? false)
        case .oven:
            let machine = status.string("main", "ovenOperatingState", "machineState") ?? status.string("main", "samsungce.ovenOperatingState", "operatingState")
            return machine?.lowercased() == "running"
        case .robotVacuum:
            if let state = status.string("main", "robotCleanerOperatingState", "operatingState") { return state == "running" }
            if let state = status.string("main", "samsungce.robotCleanerOperatingState", "operatingState") { return state == "running" || state == "cleaning" }
            return ["cleaning", "point"].contains(status.string("main", "robotCleanerMovement", "robotCleanerMovement") ?? "")
        case .refrigerator:
            return false
        }
    }

    /// When the cycle ends: the operating state's `completionTime`.
    static func completionTime(_ appliance: Appliance, _ status: DeviceStatus) -> Date? {
        let capability = appliance == .oven ? "ovenOperatingState" : appliance.operatingState
        return capability.flatMap { status.string("main", $0, "completionTime") }.flatMap(SmartThingsDates.parse)
    }

    /// Minutes left: `completion` (its `completionTime`) minus now, floored at 0, else Samsung's `remainingTime` (section 8.2).
    static func remainingMinutes(_ appliance: Appliance, _ status: DeviceStatus, now: Date, completion: Date?) -> Int? {
        if let date = completion {
            return max(0, Int(saturating: (date.timeIntervalSince(now) / 60).rounded(.down)) ?? 0)
        }
        if let samsung = appliance.samsungCapability, let minutes = status.number("main", samsung, "remainingTime") {
            return max(0, Int(saturating: minutes) ?? 0)
        }
        return nil
    }

    /// A temperature as a person reads it: no trailing ".0", and SmartThings' "C"/"F" as °C/°F.
    static func reading(_ value: Double, unit: String?) -> String {
        let number = value.rounded() == value ? String(Int(saturating: value) ?? 0) : String(format: "%.1f", value)
        let symbol = switch unit?.uppercased() { case "C": "°C"; case "F": "°F"; case let other?: other; case nil: "" }
        return symbol.isEmpty ? number : "\(number) \(symbol)"
    }

    /// The values that have no HomeKit characteristic (section 8.9).
    static func details(_ appliance: Appliance, _ status: DeviceStatus, now: Date) -> [DeviceDetail] {
        var list: [DeviceDetail] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { list.append(DeviceDetail(label: label, value: value)) } }
        switch appliance {
        case .washer, .dryer, .dishwasher:
            let capability = appliance.operatingState ?? ""
            add("State", status.string("main", capability, "machineState") ?? status.string("main", appliance.samsungCapability ?? "", "machineState"))
            add("Job", status.string("main", capability, appliance.jobStateAttribute ?? "") ?? status.string("main", appliance.samsungCapability ?? "", appliance.jobStateAttribute ?? ""))
            let completion = completionTime(appliance, status)
            if let minutes = remainingMinutes(appliance, status, now: now, completion: completion) { add("Remaining", "\(minutes) min") }
            if let completion { add("Finishes at", SmartThingsDates.format(completion)) }
            if let progress = status.number("main", capability, "progress") { add("Progress", "\(Int(saturating: progress) ?? 0) %") }
            if let mode = appliance.modeCapability { add("Mode", status.string("main", mode, mode)) }
            if let cycle = appliance.cycleCapability {
                add("Cycle", status.string("main", cycle, appliance == .dishwasher ? "washingCourse" : appliance == .dryer ? "dryerCycle" : "washerCycle"))
            }
        case .oven:
            add("State", status.string("main", "ovenOperatingState", "machineState"))
            add("Job", status.string("main", "ovenOperatingState", "ovenJobState"))
            add("Mode", status.string("main", "ovenMode", "ovenMode"))
            if let setpoint = status.number("main", "ovenSetpoint", "ovenSetpoint") {
                add("Setpoint", Self.reading(setpoint, unit: status.unit("main", "ovenSetpoint", "ovenSetpoint")))
            }
            if let minutes = remainingMinutes(.oven, status, now: now, completion: completionTime(.oven, status)) { add("Remaining", "\(minutes) min") }
            if let progress = status.number("main", "ovenOperatingState", "progress") { add("Progress", "\(Int(saturating: progress) ?? 0) %") }
            add("Operation time", status.string("main", "ovenOperatingState", "operationTime"))
        case .refrigerator:
            for (component, capabilities) in status.components.sorted(by: { $0.key < $1.key }) {
                if let setpoint = capabilities["refrigerationSetpoint"]?["refrigerationSetpoint"], let value = setpoint.value.doubleValue {
                    add("Setpoint (\(component))", Self.reading(value, unit: setpoint.unit))
                }
                if let rapid = capabilities["rapidCooling"]?["rapidCooling"]?.value.stringValue { add("Rapid cooling (\(component))", rapid) }
            }
            add("Rapid freezing", status.string("freezer", "samsungce.freezerConvertMode", "freezerConvertMode"))
            add("Ice maker", status.string("icemaker", "switch", "switch"))
        case .robotVacuum:
            add("State", status.string("main", "robotCleanerOperatingState", "operatingState") ?? status.string("main", "samsungce.robotCleanerOperatingState", "operatingState"))
            add("Movement", status.string("main", "robotCleanerMovement", "robotCleanerMovement"))
            add("Cleaning mode", status.string("main", "robotCleanerCleaningMode", "robotCleanerCleaningMode"))
            add("Turbo mode", status.string("main", "robotCleanerTurboMode", "robotCleanerTurboMode"))
        }
        if let remote = Convert.flag(status.value("main", "remoteControlStatus", "remoteControlEnabled")) {
            add("Remote control", remote ? "allowed" : "not allowed")
        }
        return list
    }
}

extension AccessoryBuilder {
    mutating func buildAppliance(_ appliance: Appliance) {
        kind = appliance.rawValue
        category = appliance.category
        let snapshot = appliance
        details.append { status, now in Appliance.details(snapshot, status, now: now) }
        switch appliance {
        case .washer, .dryer, .dishwasher: laundry(appliance)
        case .oven: oven()
        case .refrigerator: refrigerator()
        case .robotVacuum: robotVacuum()
        }
    }

    /// The "Running" Occupancy Sensor every appliance but a fridge has (section 8.2).
    mutating func runningSensor(_ appliance: Appliance) {
        let service = makeService(.occupancySensor, "main", "occupancy.running", name: serviceName("main", "Running"))
        update { status in service.set(.occupancyDetected, .int(Appliance.isRunning(appliance, status) ? 1 : 0)) }
    }

    // MARK: Washer, dryer, dishwasher (8.2)

    mutating func laundry(_ appliance: Appliance) {
        guard let main = device.main, let operating = appliance.operatingState else { return }
        let hasSwitch = main.has("switch")
        let machine = main.has(operating) ? operating : appliance.samsungCapability ?? operating
        let canStart = (status.strings("main", machine, "supportedMachineStates")?.contains("run") ?? false) && main.has("remoteControlStatus")
        let writer = writer
        let box = box
        let logger = env.logger
        let label = name
        if hasSwitch, !settings.removeLegacySwitchForLaundry {
            let service = makeService(.switch, "main", "switch", name: serviceName("main", "Power"), kind: appliance.rawValue, category: .switch)
            bindOn(service, "main")
        } else if canStart {
            let service = makeService(.switch, "main", "switch.start", name: serviceName("main", "Start"), kind: appliance.rawValue, category: .switch)
            service.characteristic(.on).onWrite { value in
                guard Convert.flag(box.status.value("main", "remoteControlStatus", "remoteControlEnabled")) == true else {
                    logger.warning("Remote control is off on \(label): turn on Smart Control on the appliance")
                    throw HAPStatusError(.notAllowedInCurrentState)
                }
                // Pause, not stop: stop cancels the cycle.
                let state = value.boolValue == true ? "run" : "pause"
                try await writer.send([DeviceCommand("main", machine, "setMachineState", [.string(state)])], set: [("main", machine, "machineState", .string(state))])
            }
            update { status in service.set(.on, status.string("main", machine, "machineState").map { .bool($0 == "run") }) }
        }
        runningSensor(appliance)
        consume("main", ["switch", operating, "remoteControlStatus"] + [appliance.samsungCapability, appliance.modeCapability, appliance.cycleCapability].compactMap { $0 })
    }

    // MARK: Oven (8.3)

    mutating func oven() {
        // No start from HomeKit: heat is a safety matter. Cooktop burners show nothing.
        let ovenCapabilities = ["ovenOperatingState", "samsungce.ovenOperatingState", "ovenMode", "ovenSetpoint", "samsungce.ovenMode"]
        for component in device.components where component.has("temperatureMeasurement") && (component.id == "main" || !component.capabilities.filter(ovenCapabilities.contains).isEmpty) {
            let id = component.id
            let service = makeService(.temperatureSensor, id, "temperature", name: id == "main" ? serviceName("main", "Oven") : "\(name) Oven \(component.label ?? id)",
                                      optional: [.currentTemperature.with(minValue: -100, maxValue: 400, minStep: 0.1)], kind: "oven", category: .sensor)
            update { status in
                service.set(.currentTemperature, status.number(id, "temperatureMeasurement", "temperature").map {
                    .double(Convert.celsius($0, unit: status.unit(id, "temperatureMeasurement", "temperature")))
                })
            }
            consume(id, ovenCapabilities + ["temperatureMeasurement", "switch"])
        }
        runningSensor(.oven)
        consume("main", ovenCapabilities + ["switch", "remoteControlStatus"])
    }

    // MARK: Refrigerator (8.5)

    static func compartmentName(_ component: String) -> String? {
        switch component {
        case "main", "cooler": "Fridge"
        case "freezer": "Freezer"
        case "cvroom", "onedoor", "flexzone": "FlexZone"
        default: nil
        }
    }

    mutating func refrigerator() {
        let disabled = disabledComponents
        let withTemperature = device.components.filter { $0.has("temperatureMeasurement") && !disabled.contains($0.id) }
        let fallback = settings.exposeMultiZoneRefrigerator
        for component in withTemperature {
            let id = component.id
            // `main` and `cooler` both report the fridge: one Fridge sensor, the cooler's (section 8.5).
            if id == "main", withTemperature.contains(where: { $0.id == "cooler" }) { consume(id, ["temperatureMeasurement"]); continue }
            let label = Self.compartmentName(id) ?? (component.label ?? id)
            let service = makeService(.temperatureSensor, id, "temperature", name: "\(name) \(label)",
                                      optional: [.currentTemperature.with(minValue: -50, maxValue: 50, minStep: 0.1)], kind: "refrigerator", category: .sensor)
            update { status in
                if let value = status.number(id, "temperatureMeasurement", "temperature") {
                    service.set(.currentTemperature, .double(Convert.celsius(value, unit: status.unit(id, "temperatureMeasurement", "temperature"))))
                } else if fallback, let celsius = Self.driverStateTemperature(status, component: id) {
                    service.set(.currentTemperature, .double(celsius))
                }
            }
            consume(id, ["temperatureMeasurement"])
        }
        for component in device.components where component.has("contactSensor") && !disabled.contains(component.id) {
            let id = component.id
            let label = id == "main" ? "Door" : "\(Self.compartmentName(id) ?? component.label ?? id) Door"
            let service = makeService(.contactSensor, id, "contact", name: "\(name) \(label)", kind: "refrigerator", category: .sensor)
            update { status in service.set(.contactSensorState, status.string(id, "contactSensor", "contact").map { .int($0 == "closed" ? 0 : 1) }) }
            consume(id, ["contactSensor"])
        }
        for component in device.components {
            consume(component.id, ["refrigerationSetpoint", "thermostatCoolingSetpoint", "rapidCooling", "samsungce.driverState", "custom.disabledComponents"])
        }
    }

    /// A compartment's temperature from Samsung's OCF `driverState` (section 8.5), in °C: below 15 is read as Celsius.
    static func driverStateTemperature(_ status: DeviceStatus, component: String) -> Double? {
        guard let state = status.value("main", "samsungce.driverState", "driverState") else { return nil }
        let items = state.arrayValue ?? state["device/0"]?.arrayValue ?? state.objectValue?.values.first(where: { $0.arrayValue != nil })?.arrayValue ?? []
        let paths: [String] = switch component {
        case "main", "cooler": ["/temperature/current/cooler/0", "/temperatures/vs/0"]
        case "freezer": ["/temperature/current/freezer/0", "/temperatures/vs/0"]
        default: ["/temperature/current/cooler/0"]
        }
        for path in paths {
            guard let rep = items.first(where: { $0["href"]?.stringValue == path })?["rep"] else { continue }
            var value = rep["temperature"]?.doubleValue
            if value == nil, let list = rep["x.com.samsung.da.items"]?.arrayValue {
                let wanted = component == "freezer" ? ("0", "Freezer") : ("1", "Fridge")
                let item = list.first { $0["x.com.samsung.da.id"]?.stringValue == wanted.0 || $0["x.com.samsung.da.description"]?.stringValue == wanted.1 }
                value = item?["x.com.samsung.da.current"]?.stringValue.flatMap(Double.init) ?? item?["x.com.samsung.da.current"]?.doubleValue
            }
            if let value, value.isFinite { return value < 15 ? value : (value - 32) * 5 / 9 }
        }
        return nil
    }

    // MARK: Robot vacuum (8.6)

    mutating func robotVacuum() {
        guard let main = device.main else { return }
        let standard = main.has("robotCleanerOperatingState")
        let samsung = main.has("samsungce.robotCleanerOperatingState")
        let movement = main.has("robotCleanerMovement")
        if settings.exposeRobotVacuum {
            let service = makeService(.switch, "main", "switch", kind: "robotVacuum", category: .switch)
            service.standsFor = .cleaningRobot
            let writer = writer
            let box = box
            service.characteristic(.on).onWrite { value in
                let on = value.boolValue == true
                let commands = (box.status.strings("main", "robotCleanerOperatingState", "supportedOperatingStateCommands")
                    ?? box.status.strings("main", "robotCleanerOperatingState", "supportedCommands")) ?? []
                let command: DeviceCommand
                if on {
                    if standard, commands.isEmpty || commands.contains("start") {
                        command = DeviceCommand("main", "robotCleanerOperatingState", "start")
                    } else if samsung {
                        command = DeviceCommand("main", "samsungce.robotCleanerOperatingState", "start")
                    } else {
                        command = DeviceCommand("main", "robotCleanerMovement", "setRobotCleanerMovement", ["cleaning"])
                    }
                } else if standard, commands.isEmpty || commands.contains("goHome") {
                    command = DeviceCommand("main", "robotCleanerOperatingState", "goHome")
                } else if samsung {
                    command = DeviceCommand("main", "samsungce.robotCleanerOperatingState", "returnToHome")
                } else {
                    command = DeviceCommand("main", "robotCleanerMovement", "setRobotCleanerMovement", ["homing"])
                }
                let set: Writer.Set = standard ? [("main", "robotCleanerOperatingState", "operatingState", on ? "running" : "seekingCharger")]
                    : movement ? [("main", "robotCleanerMovement", "robotCleanerMovement", on ? "cleaning" : "homing")] : []
                try await writer.send([command], set: set)
            }
            update { status in service.set(.on, .bool(Appliance.isRunning(.robotVacuum, status))) }
        }
        runningSensor(.robotVacuum)
        consume("main", ["switch", "robotCleanerOperatingState", "samsungce.robotCleanerOperatingState", "robotCleanerMovement", "robotCleanerCleaningMode", "robotCleanerTurboMode"])
    }
}
