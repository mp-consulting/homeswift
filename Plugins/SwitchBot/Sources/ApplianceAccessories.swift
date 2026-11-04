import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Humidifier and Humidifier2: a Humidifier-Dehumidifier with auto (0) or a humidity threshold (1), and the
/// temperature it reports.
final class HumidifierAccessory: DeviceAccessory, @unchecked Sendable {
    let humidifier: Service
    let temperature: Service?
    private var active = false
    private var auto = false
    private var threshold = 50
    private var humidity = 50.0
    private var reportedActive: Bool?

    override var category: AccessoryCategory { .humidifier }

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        let step = max(info.options.number("set_minStep") ?? 1, 1)
        humidifier = Service(.humidifierDehumidifier, name: info.name, optional: [.waterLevel], extra: [
            Characteristic(CharacteristicType.targetHumidifierDehumidifierState.with(validValues: [0, 1]), value: .int(1)),
            Characteristic(CharacteristicType.relativeHumidityHumidifierThreshold.with(minValue: 0, maxValue: 100, minStep: step), value: .int(50)),
        ], isPrimary: true)
        temperature = info.options.flag("hide_temperature") ? nil : Service(.temperatureSensor, name: "\(info.name) Temperature Sensor", extra: [
            Characteristic(CharacteristicType.currentTemperature.with(minValue: -270, maxValue: 100, minStep: 0.1), value: .double(30)),
        ])
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([humidifier, temperature])
        humidifier.characteristic(.active).onWrite { [weak self] value in
            try await self?.write { self?.active = value.intValue == 1 }
        }
        humidifier.characteristic(.targetHumidifierDehumidifierState).onWrite { [weak self] value in
            try await self?.write { self?.auto = value.intValue == 0 }
        }
        humidifier.characteristic(.relativeHumidityHumidifierThreshold).onWrite { [weak self] value in
            try await self?.write {
                // A threshold set while off turns it on.
                self?.threshold = min(max(value.intValue ?? 50, 0), 100)
                self?.active = true
            }
        }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        if let value = status["humidity"].flatMap(number) {
            let humidity = min(max(value, 0), 100)
            lock.withLock { self.humidity = humidity }
            humidifier.characteristic(.currentRelativeHumidity).value = .double(humidity)
        }
        if let celsius = celsius(status, webhook: webhook) {
            temperature?.characteristic(.currentTemperature).value = .double(min(max(celsius, -270), 100))
        }
        guard !webhook, let power = status["power"]?.stringValue else { return }
        let on = power.lowercased() == "on"
        let isAuto = status["auto"]?.boolValue ?? false
        let (humidity, threshold) = lock.withLock { () -> (Double, Int) in
            active = on
            reportedActive = on
            auto = isAuto
            if isAuto {
                threshold = Int(humidity.rounded())
            } else if let efficiency = status["nebulizationEfficiency"].flatMap(number) {
                threshold = Int(saturating: min(efficiency, 100), in: 0...100) ?? threshold
            }
            return (humidity, threshold)
        }
        humidifier.characteristic(.active).value = .int(on ? 1 : 0)
        humidifier.characteristic(.targetHumidifierDehumidifierState).value = .int(isAuto ? 0 : 1)
        humidifier.characteristic(.relativeHumidityHumidifierThreshold).value = .int(threshold)
        let current = !on ? 0 : isAuto ? 2 : humidity > Double(threshold) ? 1 : 2
        humidifier.characteristic(.currentHumidifierDehumidifierState).value = .int(current)
        if let lack = status["lackWater"]?.boolValue { humidifier[.waterLevel]?.value = .double(lack ? 0 : 100) }
    }

    override func showOffline() { humidifier.characteristic(.active).value = .int(0) }

    override func push() async throws {
        let (active, auto, threshold, humidity, reported) = lock.withLock { (self.active, self.auto, self.threshold, self.humidity, self.reportedActive) }
        var commands: [Command] = []
        if !active {
            commands.append(Command(command: "turnOff"))
        } else {
            // 4.x never sends turnOn; the API has it, and setMode alone does not wake a humidifier that is off.
            if reported == false { commands.append(Command(command: "turnOn")) }
            if auto {
                commands.append(Command(command: "setMode", parameter: "auto"))
            } else if Double(threshold) != humidity.rounded() {
                commands.append(Command(command: "setMode", parameter: "\(threshold)"))
            }
        }
        if try await send(commands) { lock.withLock { reportedActive = active } }
    }
}

/// Battery Circulator Fan: a Fan v2 with speed and oscillation, and its battery.
final class FanAccessory: DeviceAccessory, @unchecked Sendable {
    let fan: Service
    let battery: Service
    private var target = (active: false, speed: 50, swing: false)
    private var reported: (active: Bool, speed: Int, swing: Bool)?

    override var category: AccessoryCategory { .fan }

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        fan = Service(.fanv2, name: info.name, optional: [CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 1), .swingMode], isPrimary: true)
        battery = Self.batteryService(info.name, chargeable: true)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([fan, battery])
        fan.characteristic(.active).onWrite { [weak self] value in try await self?.write { self?.target.active = value.intValue == 1 } }
        fan.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.write { self?.target.speed = value.intValue ?? 50 } }
        fan.characteristic(.swingMode).onWrite { [weak self] value in try await self?.write { self?.target.swing = value.intValue == 1 } }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        showBattery(status, on: battery)
        if let charging = status["chargingStatus"]?.stringValue { battery.characteristic(.chargingState).value = .int(charging == "charging" ? 1 : 0) }
        var values = lock.withLock { reported ?? target }
        if let power = (status["power"] ?? status["powerState"])?.stringValue { values.active = power.lowercased() == "on" }
        if let speed = status["fanSpeed"].flatMap(number) { values.speed = Int(saturating: speed, in: 1...100) ?? values.speed }
        if let swing = status["oscillation"]?.stringValue { values.swing = swing == "on" }
        lock.withLock {
            reported = values
            target = values
        }
        fan.characteristic(.active).value = .int(values.active ? 1 : 0)
        fan.characteristic(.rotationSpeed).value = .int(values.speed)
        fan.characteristic(.swingMode).value = .int(values.swing ? 1 : 0)
    }

    override func showOffline() { fan.characteristic(.active).value = .int(0) }

    override func push() async throws {
        let (target, reported) = lock.withLock { (self.target, self.reported) }
        var commands: [Command] = []
        if target.active != reported?.active { commands.append(Command(command: target.active ? "turnOn" : "turnOff")) }
        if target.active {
            // 4.x guards the speed on a change of oscillation; the speed's own change is meant.
            if target.speed != reported?.speed, target.speed > 0 { commands.append(Command(command: "setWindSpeed", parameter: "\(min(target.speed, 100))")) }
            if target.swing != reported?.swing { commands.append(Command(command: "setOscillation", parameter: target.swing ? "on" : "off")) }
        }
        if try await send(commands) { lock.withLock { self.reported = target } }
    }
}

/// The robot vacuums: a Switch that stands for a cleaning robot (on while it cleans: `start`; off: `dock`), and its
/// battery.
final class VacuumAccessory: DeviceAccessory, @unchecked Sendable {
    let control: Service
    let battery: Service

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        control = Service(.switch, name: info.name, isPrimary: true)
        control.standsFor = .cleaningRobot
        battery = Self.batteryService(info.name, chargeable: true)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([control, battery])
        control.characteristic(.on).onWrite { [weak self] value in
            try await self?.send([Command(command: value.boolValue == true ? "start" : "dock")])
        }
    }

    static let cleaning: Set<String> = ["Clearing", "InRemoteControl", "InDustCollecting"]

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        showBattery(status, on: battery)
        guard let working = status["workingStatus"]?.stringValue else { return }
        control.characteristic(.on).value = .bool(Self.cleaning.contains(working))
        battery.characteristic(.chargingState).value = .int(working == "Charging" ? 1 : 0)
    }

    override func showOffline() { control.characteristic(.on).value = .bool(false) }
}

/// The Air Purifiers: Active (`turnOn`/`turnOff`), the state and speed they report, and their child lock.
final class AirPurifierAccessory: DeviceAccessory, @unchecked Sendable {
    let purifier: Service
    override var category: AccessoryCategory { .airPurifier }

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        purifier = Service(.airPurifier, name: info.name, optional: [.rotationSpeed, .lockPhysicalControls], isPrimary: true)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([purifier])
        purifier.characteristic(.active).onWrite(changesOnly: true) { [weak self] value in
            try await self?.send([Command(command: value.intValue == 1 ? "turnOn" : "turnOff")])
        }
        // The API's modes are not specified for speed and auto: kept, not sent.
        purifier.characteristic(.targetAirPurifierState).onWrite { _ in }
        purifier.characteristic(.rotationSpeed).onWrite { _ in }
        purifier.characteristic(.lockPhysicalControls).onWrite { _ in }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        if let power = status["power"]?.stringValue {
            let on = power.lowercased() == "on"
            purifier.characteristic(.active).value = .int(on ? 1 : 0)
            purifier.characteristic(.currentAirPurifierState).value = .int(on ? 2 : 0)
        }
        if let mode = status["mode"].flatMap(number) {
            purifier.characteristic(.targetAirPurifierState).value = .int(mode == 0 ? 1 : 0)
            purifier.characteristic(.rotationSpeed).value = .int(mode == 0 ? 0 : min(Int((mode / 3 * 100).rounded()), 100))
        }
        if let childLock = status["childLock"].flatMap(number) { purifier.characteristic(.lockPhysicalControls).value = .int(childLock == 1 ? 1 : 0) }
    }

    override func showOffline() { purifier.characteristic(.active).value = .int(0) }
}
