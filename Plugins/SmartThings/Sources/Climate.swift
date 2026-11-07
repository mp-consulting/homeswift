import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A fan mode list as a 0–100 speed (sections 7.3.10 and 8.7): the auto mode reads 0, the manual ones in rank order.
struct FanModes: Sendable, Equatable {
    var auto: String?
    var manual: [String]

    init(_ modes: [String], autoNames: [String], ranks: [String: Int]) {
        let automatic = autoNames.first { modes.contains($0) }
        auto = automatic
        let others = modes.enumerated().filter { $0.element != automatic }
        manual = others.sorted { (ranks[$0.element.lowercased()] ?? 99, $0.offset) < (ranks[$1.element.lowercased()] ?? 99, $1.offset) }.map(\.element)
    }

    func speed(of mode: String) -> Int? {
        if mode == auto { return 0 }
        guard let index = manual.firstIndex(of: mode), !manual.isEmpty else { return nil }
        return Int(floor(Double(index + 1) / Double(manual.count) * 100))
    }

    /// The manual mode for a speed above 0.
    func mode(forSpeed speed: Double) -> String? {
        guard !manual.isEmpty else { return auto }
        let index = min(manual.count - 1, max(0, Int(ceil(speed / 100 * Double(manual.count))) - 1))
        return manual[index]
    }

    static let airConditionerRanks = ["sleep": 1, "quiet": 2, "low": 3, "1": 4, "medium": 5, "mid": 6, "2": 7, "high": 8, "3": 9, "turbo": 10, "4": 11, "max": 12]
    static let purifierRanks = ["sleep": 1, "silent": 2, "quiet": 3, "windfree": 4, "low": 5, "medium": 6, "mid": 6, "pet": 7, "high": 8, "max": 9, "turbo": 10]
}

extension AccessoryBuilder {
    // MARK: Air conditioner (7.3.10)

    static func airConditionerState(mode: String) -> Int {
        switch mode.lowercased() {
        case "cool", "dry": 2
        case "heat": 1
        case "auto", "aicomfort": 3
        default: 0
        }
    }

    mutating func airConditioner(_ component: String, caps: Swift.Set<String>) {
        kind = "airConditioner"
        category = .airConditioner
        let unitNow = status.unit(component, "temperatureMeasurement", "temperature")
        let range = setpointRange(component, "thermostatCoolingSetpoint", "coolingSetpointRange", unit: unitNow, fallback: (16, 30, 1))
        var valid: [Int] = [0, 1, 2, 3]
        let available = status.strings(component, "airConditionerMode", "availableAcModes") ?? []
        let modes = available.isEmpty ? (status.strings(component, "airConditionerMode", "supportedAcModes") ?? []) : available
        if !modes.isEmpty { valid = Swift.Set([0] + modes.map(Self.airConditionerState)).sorted() }
        let allowed = valid
        let thermostat = makeService(.thermostat, component, "thermostat", optional: [
            .currentTemperature.with(minValue: -50, maxValue: 100, minStep: 0.1),
            .targetTemperature.with(minValue: range.0, maxValue: range.1, minStep: range.2),
            .targetHeatingCoolingState.with(validValues: valid),
        ], kind: "airConditioner", category: .airConditioner)
        let fanList = status.strings(component, "airConditionerFanMode", "availableAcFanModes").flatMap { $0.isEmpty ? nil : $0 }
            ?? status.strings(component, "airConditionerFanMode", "supportedAcFanModes").flatMap { $0.isEmpty ? nil : $0 }
            ?? ["auto", "low", "medium", "high", "turbo"]
        let fanModes = FanModes(fanList, autoNames: ["auto"], ranks: FanModes.airConditionerRanks)
        let swing = caps.contains("fanOscillationMode")
        let fan = makeService(.fanv2, component, "fan", name: serviceName(component, "Fan"), optional: [.rotationSpeed] + (swing ? [.swingMode] : []))
        let writer = writer
        let box = box
        @Sendable func unit(_ status: DeviceStatus) -> String? { status.unit(component, "temperatureMeasurement", "temperature") }
        @Sendable func target(_ status: DeviceStatus) -> Int {
            guard status.string(component, "switch", "switch") != "off" else { return 0 }
            return status.string(component, "airConditionerMode", "airConditionerMode").map(Self.airConditionerState) ?? 0
        }
        thermostat.characteristic(.targetHeatingCoolingState).onWrite { value in
            let state = value.intValue ?? 0
            if state == 0 {
                try await writer.send([DeviceCommand(component, "switch", "off")], set: [(component, "switch", "switch", "off")])
                return
            }
            let mode = state == 1 ? "heat" : state == 2 ? "cool" : "auto"
            try await writer.send([DeviceCommand(component, "switch", "on"), DeviceCommand(component, "airConditionerMode", "setAirConditionerMode", [.string(mode)])],
                                  set: [(component, "switch", "switch", "on"), (component, "airConditionerMode", "airConditionerMode", .string(mode))])
        }
        thermostat.characteristic(.targetTemperature).onWrite(changesOnly: true) { value in
            let setpoint = Convert.deviceTemperature(value.doubleValue ?? 24, unit: box.status.unit(component, "thermostatCoolingSetpoint", "coolingSetpoint") ?? unit(box.status))
            try await writer.send([DeviceCommand(component, "thermostatCoolingSetpoint", "setCoolingSetpoint", [setpoint])],
                                  set: [(component, "thermostatCoolingSetpoint", "coolingSetpoint", setpoint)])
        }
        thermostat.characteristic(.temperatureDisplayUnits).onWrite { _ in }
        // HomeKit sends Active 0 with a speed of 0: that off is ignored for 1.5 s (section 7.3.10).
        let zeroSpeedAt = NIOLockedValueBox<Date?>(nil)
        let now = env.now
        let window = env.timing.timeInterval(1.5)
        fan.characteristic(.active).onWrite { value in
            if value.intValue == 1 {
                let state = target(box.status)
                let mode = state == 1 ? "heat" : state == 2 ? "cool" : state == 3 ? "auto" : "wind"
                try await writer.send([DeviceCommand(component, "switch", "on"), DeviceCommand(component, "airConditionerMode", "setAirConditionerMode", [.string(mode)])],
                                      set: [(component, "switch", "switch", "on"), (component, "airConditionerMode", "airConditionerMode", .string(mode))])
            } else {
                let recent = zeroSpeedAt.withLockedValue { $0.map { now().timeIntervalSince($0) < window } ?? false }
                let auto = box.status.string(component, "airConditionerFanMode", "fanMode") == fanModes.auto && fanModes.auto != nil
                guard !recent, !auto else { return }
                try await writer.send([DeviceCommand(component, "switch", "off")], set: [(component, "switch", "switch", "off")])
            }
        }
        fan.characteristic(.rotationSpeed).onWrite(changesOnly: true) { value in
            let speed = value.doubleValue ?? 0
            let mode: String?
            if speed <= 0 {
                zeroSpeedAt.withLockedValue { $0 = now() }
                mode = fanModes.auto ?? fanModes.manual.first
            } else {
                mode = fanModes.mode(forSpeed: speed)
            }
            guard let mode else { return }
            try await writer.send([DeviceCommand(component, "airConditionerFanMode", "setFanMode", [.string(mode)])],
                                  set: [(component, "airConditionerFanMode", "fanMode", .string(mode))])
        }
        if swing {
            let oscillation = status.strings(component, "fanOscillationMode", "availableFanOscillationModes")
                ?? status.strings(component, "fanOscillationMode", "supportedFanOscillationModes") ?? []
            let swingOn = oscillation.contains("all") || oscillation.isEmpty ? "all" : oscillation.first { !$0.hasPrefix("fixed") && $0 != "off" } ?? "all"
            let swingOff = oscillation.contains("fixed") || oscillation.isEmpty ? "fixed" : oscillation.first { $0.hasPrefix("fixed") || $0 == "off" } ?? "fixed"
            fan.characteristic(.swingMode).onWrite(changesOnly: true) { value in
                let mode = value.intValue == 1 ? swingOn : swingOff
                try await writer.send([DeviceCommand(component, "fanOscillationMode", "setFanOscillationMode", [.string(mode)])],
                                      set: [(component, "fanOscillationMode", "fanOscillationMode", .string(mode))])
            }
        }
        update { status in
            let temperatureUnit = unit(status)
            let current = status.number(component, "temperatureMeasurement", "temperature").map { Convert.celsius($0, unit: temperatureUnit) }
            thermostat.set(.currentTemperature, current.map { .double($0) })
            let setpoint = status.number(component, "thermostatCoolingSetpoint", "coolingSetpoint").map {
                Convert.celsius($0, unit: status.unit(component, "thermostatCoolingSetpoint", "coolingSetpoint") ?? temperatureUnit)
            }
            thermostat.set(.targetTemperature, setpoint.map { .double($0) })
            let state = target(status)
            if allowed.contains(state) { thermostat.set(.targetHeatingCoolingState, .int(state)) }
            let currentState: Int = switch state {
            case 0: 0
            case 2: 2
            case 1: 1
            default: (current ?? 0) > (setpoint ?? 0) ? 2 : 1
            }
            thermostat.set(.currentHeatingCoolingState, .int(currentState))
            thermostat.set(.temperatureDisplayUnits, .int(temperatureUnit?.uppercased() == "F" ? 1 : 0))
            fan.set(.active, status.string(component, "switch", "switch").map { .int($0 == "on" ? 1 : 0) })
            if let mode = status.string(component, "airConditionerFanMode", "fanMode"), let speed = fanModes.speed(of: mode) { fan.set(.rotationSpeed, .int(speed)) }
            if swing, let mode = status.string(component, "fanOscillationMode", "fanOscillationMode") {
                fan.set(.swingMode, .int(mode.hasPrefix("fixed") || mode == "off" ? 0 : 1))
            }
        }
        if options.exposeHumidity, caps.contains("relativeHumidityMeasurement"), let humidity = Sensor.all.first(where: { $0.capability == "relativeHumidityMeasurement" }) {
            sensor(component, humidity)
        }
        if caps.contains("custom.airConditionerOptionalMode") {
            let modes: [(label: String, value: String)] = switch options.optionalMode {
            case "Sleep": [("Sleep", "sleep")]
            case "Speed": [("Speed", "speed")]
            case "WindFree": [("WindFree", "windFree")]
            case "WindFreeSleep": [("WindFreeSleep", "windFreeSleep")]
            case "Speed and Windfree": [("Speed", "speed"), ("WindFree", "windFree")]
            default: []
            }
            for (label, value) in modes { optionalModeSwitch(component, label: label, value: value) }
        }
    }

    mutating func optionalModeSwitch(_ component: String, label: String, value: String) {
        let service = makeService(.switch, component, "switch.\(value.lowercased())", name: serviceName(component, label))
        let writer = writer
        service.characteristic(.on).onWrite { on in
            let mode = on.boolValue == true ? value : "off"
            try await writer.send([DeviceCommand(component, "custom.airConditionerOptionalMode", "setAcOptionalMode", [.string(mode)])],
                                  set: [(component, "custom.airConditionerOptionalMode", "acOptionalMode", .string(mode))])
        }
        update { status in service.set(.on, status.string(component, "custom.airConditionerOptionalMode", "acOptionalMode").map { .bool($0 == value) }) }
    }

    // MARK: Air purifier (8.7)

    mutating func airPurifier(_ component: String, caps: Swift.Set<String>, purifierFanMode: Bool) {
        let (capability, listAttribute, attribute, command) = purifierFanMode
            ? ("airPurifierFanMode", "supportedAirPurifierFanModes", "airPurifierFanMode", "setAirPurifierFanMode")
            : ("airConditionerFanMode", "supportedAcFanModes", "fanMode", "setFanMode")
        let listed = (purifierFanMode ? nil : status.strings(component, capability, "availableAcFanModes").flatMap { $0.isEmpty ? nil : $0 })
            ?? status.strings(component, capability, listAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? ["auto", "low", "medium", "high"]
        let modes = FanModes(listed, autoNames: ["auto", "smart"], ranks: FanModes.purifierRanks)
        let service = makeService(.airPurifier, component, "airPurifier", optional: [.rotationSpeed], kind: "airPurifier", category: .airPurifier)
        let writer = writer
        // Samsung purifiers beep on every command: a redundant on is not sent (changesOnly), fan mode writes are debounced.
        service.characteristic(.active).onWrite(changesOnly: true) { value in
            let on = value.intValue == 1
            try await writer.send([DeviceCommand(component, "switch", on ? "on" : "off")], set: [(component, "switch", "switch", .string(on ? "on" : "off"))])
        }
        let pending = NIOLockedValueBox<(auto: Bool?, speed: Double?)>((nil, nil))
        let latest = LatestCallGuard(delay: env.timing.seconds(0.5))
        let flush: @Sendable () async throws -> Void = {
            guard await latest() else { return }
            let (auto, speed) = pending.withLockedValue { value in defer { value = (nil, nil) }; return value }
            let mode: String?
            if auto == true, let automatic = modes.auto {
                mode = automatic
            } else if let speed {
                mode = speed <= 0 ? modes.manual.first : modes.mode(forSpeed: speed)
            } else {
                mode = modes.manual.first
            }
            guard let mode else { return }
            try await writer.send([DeviceCommand(component, capability, command, [.string(mode)])], set: [(component, capability, attribute, .string(mode))])
        }
        service.characteristic(.targetAirPurifierState).onWrite(changesOnly: true) { value in
            pending.withLockedValue { $0.auto = value.intValue == 1 }
            try await flush()
        }
        service.characteristic(.rotationSpeed).onWrite(changesOnly: true) { value in
            pending.withLockedValue { $0.speed = value.doubleValue ?? 0 }
            try await flush()
        }
        update { status in
            if let state = status.string(component, "switch", "switch") {
                service.set(.active, .int(state == "on" ? 1 : 0))
                service.set(.currentAirPurifierState, .int(state == "on" ? 2 : 0))
            }
            if let mode = status.string(component, capability, attribute) {
                service.set(.targetAirPurifierState, .int(mode == modes.auto ? 1 : 0))
                if let speed = modes.speed(of: mode) { service.set(.rotationSpeed, .int(speed)) }
            }
        }
        if !caps.isDisjoint(with: ["filterState", "custom.filterState", "custom.hepaFilter"]) {
            let filter = makeService(.filterMaintenance, component, "filter", name: serviceName(component, "Filter"), optional: [.filterLifeLevel])
            update { status in
                let usage = status.number(component, "custom.hepaFilter", "hepaFilterUsage")
                let life = status.number(component, "filterState", "filterLifeRemaining") ?? status.number(component, "custom.filterState", "filterLifeRemaining")
                    ?? usage.map { 100 - $0 }
                if let life { filter.set(.filterLifeLevel, .double(Convert.clamp(life, 0...100))) }
                let hepa = status.string(component, "custom.hepaFilter", "hepaFilterStatus")
                let change = (life.map { $0 < 10 } ?? false) || (hepa.map { $0.lowercased() != "normal" } ?? false) || (usage.map { $0 >= 90 } ?? false)
                filter.set(.filterChangeIndication, .int(change ? 1 : 0))
            }
        }
        if !caps.isDisjoint(with: ["airQualitySensor", "dustSensor", "fineDustSensor", "veryFineDustSensor", "odorSensor"]) {
            let quality = makeService(.airQualitySensor, component, "airQuality", name: serviceName(component, "Air Quality"),
                                      optional: [.pm2_5Density, .pm10Density, .vocDensity])
            update { status in
                let fine = status.number(component, "dustSensor", "fineDustLevel") ?? status.number(component, "fineDustSensor", "fineDustLevel")
                if let fine { quality.set(.pm2_5Density, .double(max(fine, 0))) }
                if let coarse = status.number(component, "dustSensor", "dustLevel") { quality.set(.pm10Density, .double(max(coarse, 0))) }
                if let odor = status.number(component, "odorSensor", "odorLevel") { quality.set(.vocDensity, .double(max(odor, 0))) }
                quality.set(.airQuality, Self.airQuality(pm25: fine, index: status.number(component, "airQualitySensor", "airQuality")).map { .int($0) })
            }
        }
    }

    /// HomeKit's 1–5 from PM2.5 when known, else from `airQualitySensor.airQuality` (section 8.7).
    static func airQuality(pm25: Double?, index: Double?) -> Int? {
        if let pm25 {
            return pm25 <= 15 ? 1 : pm25 <= 35 ? 2 : pm25 <= 55 ? 3 : pm25 <= 75 ? 4 : 5
        }
        guard let index else { return nil }
        if index <= 5 { return index <= 1 ? 1 : index <= 2 ? 2 : index <= 3 ? 3 : index <= 4 ? 4 : 5 }
        return index <= 20 ? 1 : index <= 40 ? 2 : index <= 60 ? 3 : index <= 80 ? 4 : 5
    }
}
