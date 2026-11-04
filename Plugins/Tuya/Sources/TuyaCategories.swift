import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// The services of each Tuya category (the spec's §5), on the builder's blocks.
extension TuyaAccessoryBuilder {
    static let lightCategories: Set<String> = ["dj", "dsd", "xdd", "fwd", "dc", "dd", "gyd", "tyndj", "sxd"]
    static let irHubCategories: Set<String> = ["wnykq", "hwktwkq", "wsdykq"]

    /// Builds the device's services; false when the category is not supported or the device lacks a DP it needs, which
    /// leaves the bare accessory.
    func build() -> Bool {
        if let remote = device.remote { return remote.categoryID == 5 ? irAirConditioner(remote) : irRemote(remote) }
        if Self.irHubCategories.contains(device.category) { return irHub() }
        switch device.category {
        case let category where Self.lightCategories.contains(category): return lightCategory()
        case "tgq", "tgkg": return dimmer()
        case "dlq", "kg", "tdq", "qjdcz", "szjqr": return switches(.switch)
        case "cz", "pc", "wkcz": return switches(.outlet)
        case "wxkg": return wirelessSwitch()
        case "cjkg": return sceneSwitch()
        case "bzyd": return whiteNoiseLight()
        case "kt", "ktkzq": return airConditioner()
        case "qtwk": return sauna()
        case "qn": return heater()
        case "kj": return airPurifier(hood: false)
        case "yyj": return airPurifier(hood: true)
        case "xxj": return diffuser()
        case "ckmkzq": return garageDoor()
        case "cl", "clkg", "mc": return windowCovering()
        case "cwwsq": return petFeeder()
        case "msp": return catToilet()
        case "wk", "wkf": return thermostat()
        case "ggq", "sfkzq": return valve()
        case "jsq": return humidifier()
        case "cs": return dehumidifier()
        case "fs", "fsd", "fskg": return fan()
        case "sp": return camera()
        case "ywbj", "mcs", "zd", "rqbj", "jwbj", "sj", "cobj", "cocgq", "co2bj", "co2cgq", "wsdcg", "ldcg", "pir", "pm25", "pm2.5", "pm25cgq", "hjjcy", "hps",
             "qxj":
            return sensor()
        case "ms", "jtmspro": return lock()
        case "mal": return securitySystem()
        case "wxml": return doorbell()
        case "scene": return scene()
        default:
            logger.warning("\(device.name) is an unsupported device (category \(device.category)): only its information is shown")
            return false
        }
    }

    /// The codes of the specification whose prefix and type match, sorted (the raw list, overrides not applied).
    func channels(prefix: String, type: String? = nil) -> [String] {
        device.specificationCodes.filter { $0.hasPrefix(prefix) && (type == nil || device.schema[$0]?.type == type) }
    }

    /// A channel's DP: through the override when it is found, else the raw specification's.
    func channelItem(_ code: String) -> TuyaSchemaItem? { find(code) ?? device.schema[code] }

    // MARK: Lights and switches

    func lightCategory() -> Bool {
        guard require([["switch_led"]]) else { return false }
        light(service(.lightbulb), on: find("switch_led"), brightness: find("bright_value", "bright_value_v2"),
              temperature: find("temp_value", "temp_value_v2"), colour: find("colour_data", "colour_data_v2"), mode: find("work_mode"))
        if let pir = find("switch_pir") { switchService(pir) }
        motionSensor(find("pir_state"))
        if let master = find("switch") { switchService(master) }
        return true
    }

    func dimmer() -> Bool {
        guard require([["switch", "switch_led", "switch_1", "switch_led_1"], ["bright_value", "bright_value_1"]]) else { return false }
        let codes = channels(prefix: "bright_value")
        let device = device, link = link, logger = logger
        for code in codes {
            guard let item = channelItem(code) else { continue }
            let suffix = String(code.dropFirst("bright_value".count))
            let draft = service(.lightbulb, name: codes.count == 1 ? device.name : code, subtype: code, configuredName: true)
            if let on = find("switch\(suffix)", "switch_led\(suffix)") { self.on(draft, on) }
            let range = Swift.max(item.max, 1)
            var low = 0.0, high = 100.0
            if let minimum = number(find("brightness_min\(suffix)")), let maximum = number(find("brightness_max\(suffix)")), maximum > minimum {
                low = Swift.max(0, (100 * minimum / range).rounded(.up))
                high = Swift.min(100, (100 * maximum / range).rounded(.down))
            }
            draft.add(.brightness.with(minValue: low, maxValue: high, minStep: 1), get: { [low, high] in
                device.number(item).flatMap { Self.int(Self.clamp((100 * $0 / range).rounded(), low, high)) }
            }) { value in
                try await link.send(item.code, Self.json(Self.clamp(((value.doubleValue ?? 0) * range / 100).rounded(), item.min, item.max)))
            }
            let limits = ["brightness_min\(suffix)", "brightness_max\(suffix)"]
            events.append { items in
                if items.contains(where: { limits.contains($0.code) }) {
                    logger.info("\(device.name)'s brightness range changed: restart Homeswift to use it")
                }
            }
        }
        return true
    }

    func switches(_ type: ServiceType) -> Bool {
        guard require([["switch", "switch_1"]]) else { return false }
        let codes = channels(prefix: "switch", type: "Boolean")
        let energyCode = find("switch", "switch_1")?.code
        for code in codes {
            guard let item = channelItem(code) else { continue }
            let draft = service(type, name: codes.count == 1 ? device.name : code, subtype: code, configuredName: true)
            on(draft, item)
            if code == energyCode { energy(draft) }
        }
        temperatureSensor(find("va_temperature", "temp_current"))
        humiditySensor(find("va_humidity", "humidity_value"))
        if let inching = find("switch_inching"), inching.type == "String" {
            let device = device, link = link
            @Sendable func bytes() -> [UInt8]? {
                guard case .string(let text)? = device.status(inching.code), let data = Data(base64Encoded: text) else { return nil }
                return [UInt8](data)
            }
            service(.switch, name: inching.code, subtype: inching.code).add(.on, onlineCheck: true, get: {
                bytes().map { .bool($0.count == 3 && $0[0] == 1) }
            }) { value in
                var current = bytes() ?? [0, 0, 0]
                if current.count != 3 { current = [0, 0, 0] }
                current[0] = value.boolValue == true ? 1 : 0
                try await link.send(inching.code, .string(Data(current).base64EncodedString()))
            }
        }
        return true
    }

    func wirelessSwitch() -> Bool {
        guard require([["switch_mode1", "switch1_value"]]) else { return false }
        let codes = device.specificationCodes.filter { Self.buttonDigits($0) != nil }
        for code in codes {
            guard let item = device.schema[code], let digits = Self.buttonDigits(code) else { continue }
            let draft = service(.statelessProgrammableSwitch, name: codes.count == 1 ? device.name : code, subtype: code, configuredName: true)
            draft.add(.serviceLabelIndex, value: .int(digits))
            programmableSwitch(draft, item)
        }
        return true
    }

    /// The digits of `switch_mode<n>` or `switch<n>_value`.
    static func buttonDigits(_ code: String) -> Int? {
        var digits: Substring?
        if code.hasPrefix("switch_mode") { digits = code.dropFirst("switch_mode".count) }
        else if code.hasPrefix("switch"), code.hasSuffix("_value") { digits = code.dropFirst("switch".count).dropLast("_value".count) }
        guard let digits, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    func sceneSwitch() -> Bool {
        let codes = channels(prefix: "switch", type: "Boolean")
        let device = device, link = link
        for code in codes {
            guard let item = channelItem(code) else { continue }
            let mode = find("mode\(code.dropFirst("switch".count))")
            service(.switch, name: codes.count == 1 ? device.name : code, subtype: code, configuredName: true)
                .add(.on, get: { device.bool(item).map(HAPValue.bool) }) { value in
                    // A button in scene mode does not stay on.
                    let sceneMode = device.string(mode)?.hasPrefix("scene") ?? false
                    try await link.send(item.code, .bool(sceneMode ? false : value.boolValue ?? false), debounced: false)
                }
        }
        return true
    }

    func whiteNoiseLight() -> Bool {
        guard require([["switch_led"], ["switch_music"]]), let led = find("switch_led"), let music = find("switch_music") else { return false }
        if let colour = find("colour_data") {
            light(service(.lightbulb), on: led, colour: colour, colourDefaults: true)
        } else {
            switchService(led)
        }
        switchService(music)
        return true
    }

    func fan() -> Bool {
        guard require([["switch_fan", "fan_switch", "switch"]]), let fanOn = find("switch_fan", "fan_switch", "switch") else { return false }
        let swing = find("switch_horizontal", "switch_vertical")
        let isV2 = find("child_lock") != nil || swing != nil
        let draft = service(isV2 ? .fanv2 : .fan)
        if isV2 {
            active(draft, fanOn)
            lockPhysicalControls(draft, find("child_lock"))
            swingMode(draft, swing)
        } else {
            on(draft, fanOn)
        }
        if let speed = find("fan_speed", "fan_speed_percent"), speed.type == "Integer" {
            rotationSpeed(draft, integer: speed)
        } else if let speed = find("fan_speed_enum", "fan_speed"), speed.type == "Enum" {
            rotationSpeed(draft, levels: speed)
        } else {
            rotationSpeed(draft, onOnly: fanOn)
        }
        if let direction = find("fan_direction") {
            let device = device, link = link
            draft.add(.rotationDirection, get: { device.string(direction).map { .int($0 == "reverse" ? 1 : 0) } }) { value in
                try await link.send(direction.code, .string(value.intValue == 0 ? "forward" : "reverse"), debounced: false)
            }
        }
        fanLight()
        return true
    }

    /// A fan's or a hood's light: two white lights, a light, or a switch.
    func fanLight() {
        if let warm = find("light"), let warmBrightness = find("bright_value"), let white = find("switch_led"), let whiteBrightness = find("bright_value_1") {
            light(service(.lightbulb, name: "Warm Light", subtype: "warm_light"), on: warm, brightness: warmBrightness)
            light(service(.lightbulb, name: "White Light", subtype: "white_light"), on: white, brightness: whiteBrightness)
        } else if let on = find("light", "switch_led") {
            let brightness = find("bright_value", "bright_value_v2"), temperature = find("temp_value", "temp_value_v2")
            let colour = find("colour_data"), mode = find("work_mode")
            if brightness != nil || temperature != nil || colour != nil || mode != nil {
                light(service(.lightbulb), on: on, brightness: brightness, temperature: temperature, colour: colour, mode: mode)
            } else {
                switchService(on)
            }
        }
    }

    // MARK: Climate

    func airConditioner() -> Bool {
        guard require([["switch"], ["mode"], ["work_status", "mode"], ["temp_current"]]),
              let power = find("switch"), let mode = find("mode"), let current = find("temp_current") else { return false }
        let device = device, link = link, logger = logger
        let acModes = ["auto", "cold", "hot"]
        let range = mode.range
        let main = service(.heaterCooler)
        @Sendable func modeNow() -> String? { device.string(mode) }
        main.add(.active, onlineCheck: true, get: {
            guard let on = device.bool(power) else { return nil }
            return .int(on && acModes.contains(modeNow() ?? "") ? 1 : 0)
        }) { value in
            var commands = [TuyaCommand(code: power.code, value: .bool(value.intValue == 1))]
            if !acModes.contains(modeNow() ?? ""), let first = acModes.first(where: range.contains) {
                commands.append(TuyaCommand(code: mode.code, value: .string(first)))
            }
            try await link.send(commands, debounced: true)
        }
        let state = find("work_status", "mode")
        main.add(.currentHeaterCoolerState, get: {
            device.string(state).map { ["heating": 2, "hot": 2, "cooling": 3, "cold": 3][$0].map(HAPValue.int) ?? .int(0) }
        })
        let valid = [range.contains("auto") ? 0 : nil, range.contains("hot") ? 1 : nil, range.contains("cold") ? 2 : nil].compactMap { $0 }
        if valid.isEmpty {
            logger.warning("\(device.name)'s modes have none of auto, hot and cold: Target Heater Cooler State is not configured")
        } else {
            main.add(.targetHeaterCoolerState.with(minValue: Double(valid.first!), maxValue: Double(valid.last!), validValues: valid), get: {
                switch modeNow() {
                case "hot"?: return .int(1)
                case "cold"?: return .int(2)
                case nil: return nil
                default: return .int(valid.contains(0) ? 0 : valid[0])
                }
            }) { value in
                try await link.send(mode.code, .string(value.intValue == 1 ? "hot" : value.intValue == 2 ? "cold" : "auto"))
            }
        }
        currentTemperature(main, current)
        let lock = find("lock", "child_lock")
        lockPhysicalControls(main, lock)
        let speed = find("fan_speed_enum", "windspeed")
        if let speed { rotationSpeed(main, levels: speed, ignoring: ["auto"]) }
        if let setpoint = find("temp_set") {
            let multiple = setpoint.multiple
            let low = setpoint.min / multiple, high = Swift.max(setpoint.max / multiple, low + 1), step = Swift.max(0.1, setpoint.step / multiple)
            for (type, autoValue) in [(CharacteristicType.coolingThresholdTemperature, low), (.heatingThresholdTemperature, high)] {
                let ref = TuyaCharacteristicRef()
                main.add(type.with(minValue: low, maxValue: high, minStep: step), ref: ref, get: {
                    if modeNow() == "auto" { return .double(autoValue) }
                    return device.number(setpoint).flatMap { Self.double(Self.clamp($0 / multiple, low, high)) }
                }) { value in
                    guard modeNow() != "auto" else {
                        Task { ref.characteristic?.value = .double(autoValue) }
                        return
                    }
                    try await link.send(setpoint.code, Self.json((value.doubleValue ?? 0) * multiple))
                }
            }
        }
        temperatureDisplayUnits(main, find("temp_unit_convert", "c_f"))
        let humidity = find("humidity_current")
        if range.contains("wet") {
            let dry = service(.humidifierDehumidifier, name: "\(device.name) Dehumidifier")
            dry.add(.active, onlineCheck: true, get: { device.bool(power).map { .int($0 && modeNow() == "wet" ? 1 : 0) } }) { value in
                try await link.send([TuyaCommand(code: power.code, value: .bool(value.intValue == 1)), TuyaCommand(code: mode.code, value: .string("wet"))], debounced: true)
            }
            dry.add(.currentHumidifierDehumidifierState, value: .int(3))
            dry.add(.targetHumidifierDehumidifierState.with(minValue: 2, maxValue: 2, validValues: [2]), value: .int(2))
            if let humidity { currentHumidity(dry, humidity) } else { dry.add(.currentRelativeHumidity, value: .double(0)) }
            lockPhysicalControls(dry, lock)
            if let speed { rotationSpeed(dry, levels: speed, ignoring: ["auto"]) }
            dehumidifierThreshold(dry, find("humidity_set"))
        }
        if range.contains("wind") {
            let fan = service(.fanv2, name: "\(device.name) Fan")
            fan.add(.active, onlineCheck: true, get: { device.bool(power).map { .int($0 && modeNow() == "wind" ? 1 : 0) } }) { value in
                try await link.send([TuyaCommand(code: power.code, value: .bool(value.intValue == 1)), TuyaCommand(code: mode.code, value: .string("wind"))], debounced: true)
            }
            lockPhysicalControls(fan, lock)
            if let speed { rotationSpeed(fan, levels: speed, ignoring: ["auto"]) }
        }
        temperatureSensor(current)
        humiditySensor(humidity)
        return true
    }

    /// A threshold or target temperature from an Integer DP, `low` and `high` bounding its range; the write is rounded
    /// to what the DP takes.
    func setpoint(_ draft: TuyaServiceDraft, _ type: CharacteristicType, _ item: TuyaSchemaItem, bounds: ClosedRange<Double>? = nil,
                  fallback: ClosedRange<Double>? = nil) {
        var multiple = item.multiple
        var low = item.min / multiple, high = item.max / multiple, step = Swift.max(0.1, item.step / multiple)
        if let bounds { low = Swift.max(bounds.lowerBound, low); high = Swift.min(bounds.upperBound, high) }
        if high <= low {
            let fallback = fallback ?? (bounds ?? 10...38)
            logger.warning("\(device.name)'s \(item.code) range is not usable: \(fallback.lowerBound) to \(fallback.upperBound) is used")
            low = fallback.lowerBound; high = fallback.upperBound; step = 1; multiple = 1
        }
        let device = device, link = link
        let scale = multiple
        draft.add(type.with(minValue: low, maxValue: high, minStep: step), get: { [low, high] in
            guard let raw = device.number(item) else { return .double(low) }
            return Self.double(Self.clamp(raw / scale, low, high))
        }) { value in
            try await link.send(item.code, Self.json((value.doubleValue ?? 0) * scale), debounced: false)
        }
    }

    func heater() -> Bool {
        guard require([["switch"]]), let power = find("switch") else { return false }
        let device = device
        let main = service(.heaterCooler)
        active(main, power)
        let workState = find("work_state")
        main.add(.currentHeaterCoolerState, get: {
            guard let workState else { return .int(1) }
            return device.string(workState).map { .int($0 == "heating" ? 2 : $0 == "warming" ? 1 : 0) }
        })
        main.add(.targetHeaterCoolerState.with(minValue: 0, maxValue: 0, validValues: [0]), value: .int(0), get: { .int(0) }) { _ in }
        if let current = find("temp_current") { currentTemperature(main, current) }
        lockPhysicalControls(main, find("lock"))
        swingMode(main, find("shake"))
        if let target = find("temp_set") { setpoint(main, .heatingThresholdTemperature, target) }
        temperatureDisplayUnits(main, find("temp_unit_convert", "c_f"))
        return true
    }

    func thermostat() -> Bool {
        guard require([["temp_current", "temp_set"], ["temp_set"]]), let target = find("temp_set") else { return false }
        let device = device, link = link
        let main = service(.thermostat)
        let power = find("switch")
        let mode = find("mode")
        let state = find("work_state", "mode")
        let current = find("temp_current", "temp_set")
        main.add(.currentHeatingCoolingState, get: {
            if let power, device.bool(power) == false { return .int(0) }
            if let state {
                return device.string(state).map { ["hot": 1, "opened": 1, "heating": 1, "cold": 2, "eco": 2, "idle": 2, "window_opened": 2][$0].map(HAPValue.int) ?? .int(0) }
            }
            guard let wanted = device.number(target), let now = device.number(current) else { return nil }
            return .int(wanted > now ? 1 : wanted < now ? 2 : 0)
        })
        let range = mode?.range ?? []
        let valid = [power != nil ? 0 : nil, range.contains("hot") ? 1 : nil, range.contains("cold") || range.contains("eco") ? 2 : nil, 3].compactMap { $0 }
        main.add(.targetHeatingCoolingState.with(minValue: Double(valid.first!), maxValue: 3, validValues: valid), get: {
            if let power, device.bool(power) == false { return .int(0) }
            guard let mode else { return .int(3) }
            switch device.string(mode) {
            case "hot"?: return .int(1)
            case "cold"?, "eco"?: return .int(2)
            default: return .int(3)
            }
        }) { value in
            var commands: [TuyaCommand] = []
            let wanted = value.intValue ?? 3
            if let power {
                if wanted == 0 { commands.append(TuyaCommand(code: power.code, value: .bool(false))) }
                else if device.bool(power) == false { commands.append(TuyaCommand(code: power.code, value: .bool(true))) }
            }
            if let mode {
                let word: String? = switch wanted {
                case 1: range.contains("hot") ? "hot" : nil
                case 2: range.contains("eco") ? "eco" : range.contains("cold") ? "cold" : nil
                case 3: range.contains("auto") ? "auto" : nil
                default: nil
                }
                if let word { commands.append(TuyaCommand(code: mode.code, value: .string(word))) }
            }
            try await link.send(commands, debounced: false)
        }
        if let current { currentTemperature(main, current) }
        setpoint(main, .targetTemperature, target, bounds: 10...38)
        temperatureDisplayUnits(main, find("temp_unit_convert", "c_f"))
        return true
    }

    func sauna() -> Bool {
        guard require([["currtemp", "settemp"], ["settemp"]]), let target = find("settemp") else { return false }
        let device = device, link = link
        let main = service(.thermostat)
        let power = find("powerswitch")
        let heat: TuyaGetter = { .int(power.flatMap { device.bool($0) } == false ? 0 : 1) }
        main.add(.currentHeatingCoolingState, get: heat)
        main.add(.targetHeatingCoolingState.with(minValue: 0, maxValue: 1, validValues: [0, 1]), get: heat) { value in
            guard let power else { return }
            try await link.send(power.code, .bool(value.intValue == 1), debounced: false)
        }
        if let current = find("currtemp", "settemp") { currentTemperature(main, current) }
        setpoint(main, .targetTemperature, target, bounds: 30...90, fallback: 30...90)
        temperatureDisplayUnits(main, find("temp_unit_convert", "c_f"))
        for (code, name) in [("lightswitch", "Sauna Main Light"), ("ledswitch", "Sauna LED Light")] {
            let draft = service(.lightbulb, name: name, subtype: code)
            if let item = find(code) { light(draft, on: item) }
        }
        return true
    }

    func humidifier() -> Bool {
        guard require([["switch"]]), let power = find("switch") else { return false }
        let device = device, link = link
        let main = service(.humidifierDehumidifier)
        active(main, power)
        main.add(.currentHumidifierDehumidifierState, get: { device.bool(power).map { .int($0 ? 2 : 0) } })
        main.add(.targetHumidifierDehumidifierState.with(minValue: 1, maxValue: 1, validValues: [1]), value: .int(1))
        if let humidity = find("humidity_current") { currentHumidity(main, humidity) }
        if let target = find("humidity_set") {
            let spray = find("spray_mode")
            threshold(main, .relativeHumidityHumidifierThreshold, target, then: spray.map { [TuyaCommand(code: $0.code, value: .string("humidity"))] } ?? [])
        } else {
            logger.warning("\(device.name) has no humidity_set: no humidity threshold")
        }
        if let mode = find("mode") {
            main.add(.rotationSpeed, get: {
                device.string(mode).map { .double(Self.remap(Double($0 == "small" ? 1 : $0 == "middle" ? 2 : 3), 0, 3, 0, 100)) }
            }) { value in
                let level = Int(((value.doubleValue ?? 0) * 3 / 100).rounded())
                try await link.send(mode.code, .string(level == 2 ? "middle" : level == 3 ? "large" : "small"), debounced: false)
            }
        } else {
            logger.warning("\(device.name) has no mode: no rotation speed")
        }
        temperatureSensor(find("temp_current"))
        if let led = find("switch_led") {
            light(on: led, brightness: find("bright_value", "bright_value_v2"), colour: find("colour_data", "colour_data_hsv"), mode: find("work_mode"))
        }
        return true
    }

    func dehumidifier() -> Bool {
        guard require([["switch"], ["humidity_indoor"]]), let power = find("switch"), let humidity = find("humidity_indoor") else { return false }
        let device = device
        let main = service(.humidifierDehumidifier)
        active(main, power)
        main.add(.currentHumidifierDehumidifierState, get: { device.bool(power).map { .int($0 ? 3 : 0) } })
        main.add(.targetHumidifierDehumidifierState.with(minValue: 2, maxValue: 2, validValues: [2]), value: .int(2))
        currentHumidity(main, humidity)
        lockPhysicalControls(main, find("child_lock"))
        dehumidifierThreshold(main, find("dehumidify_set_value"))
        if let speed = find("fan_speed_enum") { rotationSpeed(main, levels: speed) }
        swingMode(main, find("swing"))
        temperatureSensor(find("temp_indoor"))
        return true
    }

    func diffuser() -> Bool {
        guard require([["switch_spray"]]), let spray = find("switch_spray") else { return false }
        let device = device
        if let power = find("switch") { switchService(power) }
        let main = service(.airPurifier)
        active(main, spray)
        main.add(.currentAirPurifierState, get: { device.bool(spray).map { .int($0 ? 2 : 0) } })
        if let level = find("level") { rotationSpeed(main, levels: level) }
        if let led = find("switch_led") {
            light(on: led, brightness: find("bright_value", "bright_value_v2"), colour: find("colour_data", "colour_data_hsv"), mode: find("work_mode"))
        }
        if let sound = find("switch_sound") { switchService(sound) }
        return true
    }

    func airPurifier(hood: Bool) -> Bool {
        guard require([["switch"]]), let power = find("switch") else { return false }
        let device = device, link = link
        let main = service(.airPurifier)
        active(main, power)
        main.add(.currentAirPurifierState, get: { device.bool(power).map { .int($0 ? 2 : 0) } })
        if let mode = find("mode") {
            main.add(.targetAirPurifierState, get: { device.string(mode).map { .int($0 == "auto" ? 1 : 0) } }) { value in
                try await link.send(mode.code, .string(value.intValue == 1 ? "auto" : "manual"))
            }
        }
        lockPhysicalControls(main, find("lock"))
        if let speed = find("speed"), speed.type == "Integer" {
            rotationSpeed(main, integer: speed)
        } else if let speed = find("fan_speed_enum", "speed"), speed.type == "Enum" {
            rotationSpeed(main, levels: speed)
        }
        if hood {
            fanLight()
        } else if let quality = find("air_quality", "pm25") {
            airQuality(quality: quality, pm25: find("pm25"), pm10: nil, voc: find("tvoc"))
        }
        return true
    }

    func valve() -> Bool {
        guard require([["switch", "switch_1"]]) else { return false }
        let codes = ["switch", "switch_1"].filter { find($0)?.type == "Boolean" }
        let device = device
        for code in codes {
            guard let item = find(code) else { continue }
            let draft = service(.valve, name: codes.count == 1 ? device.name : code, subtype: code, configuredName: true)
            draft.add(.valveType, value: .int(1))
            draft.add(.inUse, get: { device.bool(item).map { .int($0 ? 1 : 0) } })
            active(draft, item)
        }
        return true
    }

    // MARK: Doors, windows, locks

    func garageDoor() -> Bool {
        guard require([["switch_1"]]), let power = find("switch_1") else { return false }
        let device = device, link = link
        let main = service(.garageDoorOpener)
        main.add(.targetDoorState, get: { device.bool(power).map { .int($0 ? 0 : 1) } }) { value in
            try await link.send(power.code, .bool(value.intValue == 0), debounced: false)
        }
        let contact = find("doorcontact_state")
        main.add(.currentDoorState, get: {
            guard let contact else { return .int(4) }
            guard let open = device.bool(contact), let on = device.bool(power) else { return nil }
            switch (open, on) {
            case (true, true): return .int(0)
            case (false, false): return .int(1)
            case (false, true): return .int(2)
            case (true, false): return .int(3)
            }
        })
        main.add(.obstructionDetected, value: .bool(false))
        return true
    }

    func windowCovering() -> Bool {
        guard require([["control", "mach_operate"]]) else { return false }
        var curtains: [(name: String, current: TuyaSchemaItem?, target: TuyaSchemaItem?, control: TuyaSchemaItem?)] = [
            ("control", find("percent_state"), find("percent_control", "position"), find("control", "mach_operate")),
        ]
        if find("control_2") != nil {
            // The second curtain's own position when it reports one (the source read the first curtain's).
            curtains.append(("control_2", find("percent_state_2", "percent_state"), find("percent_control_2", "position"), find("control_2", "mach_operate")))
        }
        logger.info("\(device.name) has \(curtains.count) curtain(s)")
        let device = device, link = link
        for curtain in curtains {
            let draft = service(.windowCovering, name: curtain.name, subtype: curtain.name)
            let current = curtain.current, target = curtain.target, control = curtain.control
            @Sendable func fromControl() -> HAPValue? {
                guard let word = device.string(control) else { return nil }
                switch word {
                case "close", "FZ": return .int(0)
                case "open", "ZZ": return .int(100)
                default: return .int(50)
                }
            }
            draft.add(.currentPosition, get: {
                if let current { return device.number(current).flatMap { Self.int(Self.clamp($0, 0, 100)) } }
                if let target { return device.number(target).flatMap { Self.int(Self.clamp($0, 0, 100)) } }
                return fromControl()
            })
            draft.add(.positionState, get: {
                guard let current, let target, let now = device.number(current), let wanted = device.number(target) else { return .int(2) }
                if wanted == 100, now != 100 { return .int(1) }
                if wanted == 0, now != 0 { return .int(0) }
                return .int(2)
            })
            if let target {
                draft.add(.targetPosition, get: { device.number(target).flatMap { Self.int(Self.clamp($0, 0, 100)) } }) { value in
                    try await link.send(target.code, .number(Double(value.intValue ?? 0)))
                }
            } else if let control {
                let oldWords = !control.range.contains("open")
                draft.add(.targetPosition.with(minStep: 50), get: fromControl) { value in
                    let position = value.intValue ?? 50
                    let word = position == 0 ? (oldWords ? "FZ" : "close") : position == 100 ? (oldWords ? "ZZ" : "open") : (oldWords ? "STOP" : "stop")
                    try await link.send(control.code, .string(word))
                }
            }
        }
        return true
    }

    func lock() -> Bool {
        guard require([["open_close", "closed_opened", "lock_motor_state"]]) else { return false }
        let device = device, link = link, logger = logger
        let main = service(.lockMechanism)
        let open = find("open_close"), closedOpened = find("closed_opened"), motor = find("lock_motor_state")
        @Sendable func unsecured(_ item: TuyaSchemaItem?) -> Bool? {
            guard let value = device.status(item) else { return nil }
            // `closed_opened` is an enum on some locks: `open` is unlocked, `closed` locked.
            if case .string(let word) = value { return word == "open" || word == "opened" || word == "true" }
            return TuyaAccessoryBuilder.truthy(value)
        }
        let first = open ?? closedOpened ?? motor
        main.add(.lockCurrentState, get: { unsecured(first).map { .int($0 ? 0 : 1) } })
        if let motor {
            main.add(.lockTargetState, get: { unsecured(motor).map { .int($0 ? 0 : 1) } }) { value in
                do {
                    try await link.api.operateLock(device.id, open: value.intValue == 0)
                } catch {
                    logger.warning("Could not operate \(device.name): \(error)")
                }
            }
        } else {
            main.add(.lockTargetState, get: { unsecured(first).map { .int($0 ? 0 : 1) } }) { _ in
                logger.warning("\(device.name) reports its state but cannot be locked or unlocked remotely")
                throw HAPStatusError(.readOnlyCharacteristic)
            }
        }
        return true
    }

    func securitySystem() -> Bool {
        guard require([["master_mode"], ["sos_state"]]), let mode = find("master_mode"), let sos = find("sos_state") else { return false }
        let device = device, link = link
        let night = NIOLockedValueBox(false)
        let main = service(.securitySystem, name: device.name, configuredName: true)
        @Sendable func state() -> Int? {
            switch device.string(mode) {
            case "home"?: night.withLockedValue { $0 } ? 2 : 0
            case "arm"?: 1
            case "disarmed"?: 3
            default: nil
            }
        }
        main.add(.securitySystemCurrentState, get: {
            if TuyaAccessoryBuilder.truthy(device.status(sos)) { return .int(4) }
            return state().map(HAPValue.int)
        })
        main.add(.securitySystemTargetState, get: { state().map(HAPValue.int) }) { value in
            let target = value.intValue ?? 3
            var commands: [TuyaCommand] = []
            if TuyaAccessoryBuilder.truthy(device.status(sos)), target == 3 { commands.append(TuyaCommand(code: sos.code, value: .bool(false))) }
            night.withLockedValue { $0 = target == 2 }
            commands.append(TuyaCommand(code: mode.code, value: .string(target == 1 ? "arm" : target == 3 ? "disarmed" : "home")))
            try await link.send(commands, debounced: true)
        }
        return true
    }

    // MARK: Sensors

    func sensor() -> Bool {
        let device = device
        func alarm(_ item: TuyaSchemaItem?, _ words: Set<String>) -> Bool { device.string(item).map(words.contains) ?? false }
        switch device.category {
        case "mcs":
            guard require([["doorcontact_state", "switch"]]), let item = find("doorcontact_state", "switch") else { return false }
            service(.contactSensor).add(.contactSensorState, get: { device.status(item).map { .int(TuyaAccessoryBuilder.truthy($0) ? 1 : 0) } })
        case "rqbj", "jwbj", "sj":
            guard require([["gas_sensor_status", "gas_sensor_state", "ch4_sensor_state", "watersensor_state"]]) else { return false }
            let gas = find("gas_sensor_status", "gas_sensor_state"), methane = find("ch4_sensor_state"), water = find("watersensor_state")
            service(.leakSensor).add(.leakDetected, get: {
                let leak = (device.string(gas).map { ["alarm", "1"].contains($0) } ?? false) || device.string(methane) == "alarm" || device.string(water) == "alarm"
                return .int(leak ? 1 : 0)
            })
        case "cobj", "cocgq":
            guard require([["co_status", "co_state"]]), let item = find("co_status", "co_state") else { return false }
            let draft = service(.carbonMonoxideSensor)
            draft.add(.carbonMonoxideDetected, get: { device.string(item).map { .int(["alarm", "1"].contains($0) ? 1 : 0) } })
            if let level = find("co_value") {
                draft.add(.carbonMonoxideLevel, get: { device.number(level).flatMap { Self.double(Self.clamp($0 / level.multiple, 0, 100)) } })
            }
        case "co2bj", "co2cgq":
            guard require([["co2_state"]]), let item = find("co2_state") else { return false }
            let draft = service(.carbonDioxideSensor)
            draft.add(.carbonDioxideDetected, get: { device.string(item).map { .int($0 == "alarm" ? 1 : 0) } })
            if let level = find("co2_value") {
                draft.add(.carbonDioxideLevel, get: { device.number(level).flatMap { Self.double(Self.clamp($0 / level.multiple, 0, 100_000)) } })
            }
        case "ywbj":
            guard require([["smoke_sensor_status", "smoke_sensor_state"]]), let item = find("smoke_sensor_status", "smoke_sensor_state") else { return false }
            service(.smokeSensor).add(.smokeDetected, get: { device.string(item).map { .int(["alarm", "1"].contains($0) ? 1 : 0) } })
        case "wsdcg":
            guard require([["va_temperature", "va_humidity", "humidity_value"]]) else { return false }
            temperatureSensor(find("va_temperature"))
            humiditySensor(find("va_humidity", "humidity_value"))
        case "ldcg":
            guard require([["bright_value"]]), let item = find("bright_value") else { return false }
            service(.lightSensor).add(.currentAmbientLightLevel, get: {
                device.number(item).flatMap { Self.double(Self.clamp($0 / item.multiple, 0.0001, 100_000)) }
            })
        case "pir":
            guard require([["pir"]]) else { return false }
            motionSensor(find("pir"))
        case "hps":
            guard require([["presence_state"]]) else { return false }
            occupancySensor(find("presence_state"))
        case "zd":
            guard require([["shock_state"]]), let item = find("shock_state") else { return false }
            let code = device.deviceCode(for: item.code)
            pulseMotion(service(.motionSensor), duration: .seconds(3)) { items in
                items.contains { $0.code == code && ["vibration", "drop"].contains($0.value.stringValue ?? "") }
            }
        case "qxj":
            for (index, code) in device.specificationCodes.filter({ $0.contains("ToutCh") }).enumerated() {
                guard let item = device.schema[code] else { continue }
                service(.temperatureSensor, name: "Temperature Sensor \(index + 1)", subtype: "temperature_sensor_\(index + 1)")
                    .add(.currentTemperature.with(minValue: -100, maxValue: 100), get: {
                        .double(device.number(item).map { Self.clamp($0 / item.multiple, -100, 100) } ?? 0)
                    })
            }
            for (index, code) in device.specificationCodes.filter({ $0.contains("HoutCh") }).enumerated() {
                guard let item = device.schema[code] else { continue }
                service(.humiditySensor, name: "Humidity Sensor \(index + 1)", subtype: "humidity_sensor_\(index + 1)")
                    .add(.currentRelativeHumidity, get: { .double(device.number(item).map { Self.clamp($0, 0, 100) } ?? 0) })
            }
        default:
            // pm25, pm2.5, pm25cgq, hjjcy
            guard require([["pm25_value"]]), let item = find("pm25_value") else { return false }
            airQuality(quality: item, pm25: item, pm10: find("pm10_value", "pm10"), voc: find("voc_value"))
            temperatureSensor(find("va_temperature", "temp_indoor", "temp_current"))
            humiditySensor(find("va_humidity", "humidity_value"))
        }
        return true
    }

    func doorbell() -> Bool {
        guard require([["doorbell_call"]]), let call = find("doorbell_call") else { return false }
        logger.info("\(device.name) is a doorbell without a camera: HomeKit shows it as a button, its presses for automations")
        programmableSwitch(service(.statelessProgrammableSwitch), call)
        return true
    }

    // MARK: Other

    func scene() -> Bool {
        let link = link, device = device
        momentarySwitch(service(.switch), awaitAction: true) {
            try await link.api.triggerScene(homeID: device.ownerID, sceneID: device.id)
        }
        return true
    }

    func petFeeder() -> Bool {
        guard require([["switch"]]), let power = find("switch") else { return false }
        let device = device, link = link
        let main = service(.switch)
        active(main, power)
        // The feed the switch gives, as the source's last handler that took effect: a meal plan, a manual, slow or quick
        // feed, else the light. The source attached them all to the same On, so only one ever ran; here it is chosen once.
        let feed = find("meal_plan").map { ($0, JSONValue.bool(true)) } ?? find("manual_feed").map { ($0, JSONValue.number(1)) }
            ?? find("slow_feed").map { ($0, JSONValue.bool(true)) } ?? find("quick_feed").map { ($0, JSONValue.bool(true)) }
        let light = find("light")
        main.add(.on, value: .bool(false), set: { value in
            let on = value.boolValue ?? false
            if let (item, sent) = feed {
                guard on else { return }
                try await link.send(item.code, sent)
            } else if let light {
                try await link.send(light.code, .bool(on))
            }
        })
        if feed == nil, light == nil { logger.warning("\(device.name) has none of meal_plan, manual_feed, slow_feed, quick_feed and light: its switch does nothing") }
        if let battery = find("battery_percentage") {
            main.add(.batteryLevel, get: { device.number(battery).flatMap { Self.int(Self.clamp($0, 0, 100)) } })
        }
        return true
    }

    func catToilet() -> Bool {
        guard require([["switch"]]), let power = find("switch") else { return false }
        let device = device
        let main = service(.switch, name: device.name, subtype: "switch", configuredName: true)
        on(main, power)
        if let fault = find("fault") {
            main.add(.statusFault, get: { device.number(fault).map { .int($0 > 0 ? 1 : 0) } })
        }
        for (code, name) in [("auto_clean", "Auto Clean"), ("manual_clean", "Manual Clean"), ("deodorization", "Deodorization"), ("uv", "UV Sterilization")] {
            if let item = find(code) { on(service(.switch, name: name, subtype: code, configuredName: true), item) }
        }
        if let light = find("light") { on(service(.lightbulb, name: "Mood Light", subtype: "light", configuredName: true), light) }
        if let status = find("status") {
            occupancySensor(status, draft: service(.occupancySensor, name: "Status", subtype: "status", configuredName: true),
                            detected: ["cleaning", "uv", "deodorization"])
        }
        if let notification = find("notification") {
            service(.filterMaintenance, name: "Waste Box", subtype: "notification", configuredName: true).add(.filterChangeIndication, get: {
                device.number(notification).map { .int(Int(saturating: $0).map { $0 & 1 } ?? 0) }
            })
        }
        return true
    }
}
