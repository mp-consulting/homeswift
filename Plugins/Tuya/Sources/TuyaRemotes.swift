import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

/// IR control hubs and their remotes (developer.tuya.com, "IR control hub open service"), and the camera's events.
extension TuyaAccessoryBuilder {
    static let maximumRemoteKeys = 99

    func irHub() -> Bool {
        temperatureSensor(find("va_temperature"))
        humiditySensor(find("va_humidity", "humidity_value"))
        return true
    }

    /// One switch per key of a remote; a press is sent, and the switch turns back off.
    func irRemote(_ remote: TuyaRemoteKeys) -> Bool {
        guard let hub = device.parentID else { return false }
        if remote.keys.count > Self.maximumRemoteKeys {
            logger.warning("\(device.name) has \(remote.keys.count) keys: the first \(Self.maximumRemoteKeys) are shown")
        }
        let api = link.api, remoteID = device.id
        for key in remote.keys.prefix(Self.maximumRemoteKeys) {
            let draft = service(.switch, name: key.name, subtype: key.key, configuredName: true)
            momentarySwitch(draft, awaitAction: false) {
                if let code = key.learnedCode {
                    try await api.pressLearnedKey(hub: hub, remote: remoteID, code: code)
                } else {
                    try await api.pressKey(hub: hub, remote: remoteID, categoryID: remote.categoryID, remoteIndex: remote.remoteIndex, key: key.key, keyID: key.keyID)
                }
            }
        }
        return true
    }

    /// An IR air conditioner: its state kept here (`power`, `mode`, `temp`, `wind`), each change sending one command
    /// 100 ms after the last.
    func irAirConditioner(_ remote: TuyaRemoteKeys) -> Bool {
        guard let hub = device.parentID else { return false }
        let device = device, api = link.api, logger = logger
        let parent = parent, hubTemperature = parent?.find(["va_temperature"]), hubHumidity = parent?.find(["va_humidity", "humidity_value"])
        @Sendable func value(_ key: String) -> Int {
            switch device.rawStatus(key) {
            case .number(let number)?: Int(saturating: number) ?? 0
            case .bool(let flag)?: flag ? 1 : 0
            case .string(let text)?: Int(text) ?? 0
            default: 0
            }
        }
        let queue = TuyaCommandQueue(delay: .milliseconds(100) * link.timeScale) { _ in
            do {
                try await api.airConditionerCommand(hub: hub, remote: device.id, power: value("power"), mode: value("mode"), temp: value("temp"), wind: value("wind"))
            } catch {
                logger.warning("Could not send the state of \(device.name): \(error)")
            }
        }
        let link = link
        /// Stored at once, shown on every service (one mode at a time), sent with the next state.
        @Sendable func change(_ values: [String: Int]) async {
            device.store(values.map { TuyaCommand(code: $0.key, value: .number(Double($0.value))) })
            link.refresh()
            await queue.enqueue([TuyaCommand(code: "state", value: .null)])
        }
        let supported = Set(remote.modes.keys)
        let isOn: @Sendable () -> Bool = { value("power") == 1 }
        @Sendable func speedValue() -> HAPValue { .double(Double(value("wind") == 0 ? 3 : value("wind"))) }
        let speedType = CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: 3, minStep: 1)
        @Sendable func setSpeed(_ speed: HAPValue) async {
            let wind = Int(saturating: speed.doubleValue ?? 0) ?? 0
            if wind != 0 { await change(["wind": wind]) }
        }

        // The remote's modes: 0 cool, 1 heat, 2 auto; 3 (fan) and 4 (dry) are Other Modes.
        let numbers: [ClimateMode: Int] = [.cool: 0, .heat: 1, .auto: 2]
        var modes = Set(numbers.filter { supported.contains($0.value) }.keys)
        if modes.isEmpty {
            logger.warning("\(device.name) has none of auto, heat and cool: it is shown as a cooler")
            modes = [.cool]
        }
        func temperatures(_ mode: Int) -> ClosedRange<Double>? {
            guard let temperatures = remote.modes[mode], let low = temperatures.min(), let high = temperatures.max() else { return nil }
            return Double(low)...Double(high > low ? high : low + 1)
        }
        let heating = temperatures(1) ?? temperatures(0) ?? 16...30, cooling = temperatures(0) ?? heating
        let main = service(.heaterCooler)
        main.climate = TuyaServiceDraft.Climate(
            kind: .heaterCooler,
            capabilities: ClimateCapabilities(modes: modes, heatingRange: heating, coolingRange: cooling, step: 1),
            report: {
                let room: Double? = if let parent, let item = hubTemperature, let reading = parent.number(item) { reading / item.multiple } else { nil }
                let target = Double(value("temp"))
                return ClimateReport(power: isOn(), mode: numbers.first { $0.value == value("mode") }?.key, current: room ?? target, target: target)
            },
            apply: { command in
                var values: [String: Int] = [:]
                if let on = command.power {
                    values["power"] = on ? 1 : 0
                    // Turned on in fan or dry: back to auto, as the remote's own app does.
                    if on, command.mode == nil, ![0, 1, 2].contains(value("mode")) { values["mode"] = 2 }
                }
                if let mode = command.mode, let number = numbers[mode] { values["mode"] = number }
                if let target = command.target { values["temp"] = Int(saturating: target.rounded()) ?? 0 }
                await change(values)
            })
        main.add(speedType, get: speedValue) { await setSpeed($0) }
        if supported.contains(4) {
            let dry = service(.humidifierDehumidifier, name: "\(device.name) Dehumidifier")
            dry.add(.active, get: { .int(value("mode") == 4 && isOn() ? 1 : 0) }) { active in
                await change(["mode": 4, "power": active.intValue == 1 ? 1 : 0])
            }
            dry.add(.currentHumidifierDehumidifierState, value: .int(3))
            dry.add(.targetHumidifierDehumidifierState.with(minValue: 2, maxValue: 2, validValues: [2]), value: .int(2))
            dry.add(.currentRelativeHumidity, get: {
                guard let parent, let item = hubHumidity, let reading = parent.number(item) else { return .double(0) }
                return .double(Self.clamp(reading / item.multiple, 0, 100))
            })
            dry.add(speedType, get: speedValue) { await setSpeed($0) }
        }
        if supported.contains(3) {
            let fan = service(.fanv2, name: "\(device.name) Fan")
            fan.add(.active, get: { .int(value("mode") == 3 && isOn() ? 1 : 0) }) { active in
                await change(["mode": 3, "power": active.intValue == 1 ? 1 : 0])
            }
            fan.add(.targetFanState, get: { .int(value("wind") == 0 ? 1 : 0) }) { state in
                await change(["wind": state.intValue == 1 ? 0 : 1])
            }
            fan.add(speedType, get: speedValue) { await setSpeed($0) }
        }
        return true
    }

    // MARK: Camera

    func camera() -> Bool {
        let device = device
        if find("doorbell_ring_exist") != nil, let picture = find("doorbell_pic", "alarm_message") {
            let doorbell = service(.doorbell)
            let pictureCode = "doorbell_pic", alarmCode = "alarm_message"
            // A picture longer than one character (Tuya sends `$` as a placeholder), else an alarm message.
            let ref = programmableSwitch(doorbell, picture, listen: false)
            let logger = logger, name = device.name
            events.append { items in
                let item = items.first { $0.code == pictureCode && ($0.value.stringValue?.count ?? 0) > 1 }
                    ?? items.first { $0.code == alarmCode && ($0.value.stringValue?.count ?? 0) > 1 }
                guard let item, let text = item.value.stringValue, let data = Data(base64Encoded: text), !data.isEmpty else { return }
                logger.info("\(name) rang: \(String(decoding: data, as: UTF8.self))")
                ref.characteristic?.sendEvent(.int(0))
            }
        }
        if let motionSwitch = find("motion_switch") { switchService(motionSwitch) }
        let motionCode = "movement_detect_pic"
        let logger = logger
        pulseMotion(service(.motionSensor, name: "\(device.name) Motion Detect"), duration: .seconds(30)) { items in
            guard let text = items.first(where: { $0.code == motionCode })?.value.stringValue, let data = Data(base64Encoded: text), !data.isEmpty else {
                return false
            }
            logger.info("\(device.name) detected motion")
            return true
        }
        if let floodlight = find("floodlight_switch") {
            light(service(.lightbulb, name: "\(device.name) Floodlight"), on: floodlight, brightness: find("floodlight_lightness"))
        }
        return true
    }
}
