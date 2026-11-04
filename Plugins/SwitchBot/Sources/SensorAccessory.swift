import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// Meters, hubs, motion, contact and presence sensors and the Water Detector: they only report.
final class SensorAccessory: DeviceAccessory, @unchecked Sendable {
    let family: Family
    let temperature: Service?
    let humidity: Service?
    let carbonDioxide: Service?
    let motion: Service?
    let contact: Service?
    let occupancy: Service?
    let leak: Service?
    let lightSensor: Service?
    let battery: Service?
    let co2Threshold: Double
    /// The last temperature, for an IR air conditioner linked to this meter (`meterId`).
    private(set) var lastTemperature: Double?

    override var category: AccessoryCategory { .sensor }

    init(info: DeviceInfo, family: Family, co2Threshold: Double, link: DeviceLink, debounce: Duration, logger: Logger) {
        self.family = family
        self.co2Threshold = co2Threshold
        let options = info.options, name = info.name
        let climate = family == .meter || family == .hub
        temperature = climate && !options.flag("hide_temperature")
            ? Service(.temperatureSensor, name: "\(name) Temperature Sensor", extra: [
                Characteristic(CharacteristicType.currentTemperature.with(minValue: -270, maxValue: 100, minStep: 0.1), value: .double(30)),
            ]) : nil
        humidity = climate && !options.flag("hide_humidity")
            ? Service(.humiditySensor, name: "\(name) Humidity Sensor", extra: [
                Characteristic(CharacteristicType.currentRelativeHumidity.with(minStep: 0.1), value: .double(50)),
            ]) : nil
        carbonDioxide = info.type == "MeterPro(CO2)" && !options.flag("hide_co2")
            ? Service(.carbonDioxideSensor, name: "\(name) Carbon Dioxide Sensor", optional: [.carbonDioxideLevel]) : nil
        switch family {
        case .motion: motion = Service(.motionSensor, name: name, optional: [.statusActive], isPrimary: true)
        case .contact where !options.flag("hide_motionsensor"): motion = Service(.motionSensor, name: "\(name) Motion Sensor", optional: [.statusActive])
        default: motion = nil
        }
        contact = family == .contact ? Service(.contactSensor, name: name, isPrimary: true) : nil
        occupancy = family == .presence ? Service(.occupancySensor, name: name, optional: [.statusActive], isPrimary: true) : nil
        leak = family == .waterDetector && !options.flag("hide_leak") ? Service(.leakSensor, name: name, optional: [.statusActive], isPrimary: true) : nil
        let hasLight = family == .hub || family == .motion || family == .contact || family == .presence
        lightSensor = hasLight && !options.flag("hide_lightsensor") ? Self.lightSensorService(name, minStep: family == .hub ? 1 : nil) : nil
        battery = family == .hub ? nil : Self.batteryService(name)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([contact, occupancy, leak, motion, temperature, humidity, carbonDioxide, lightSensor, battery])
        for service in [motion, occupancy, leak] { service?[.statusActive]?.value = .bool(true) }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        // A Hub 3 reports under `sensorData`.
        var status = status
        if let inner = status["sensorData"]?.objectValue { status.merge(inner) { old, _ in old } }
        showBattery(status, on: battery)
        if let celsius = celsius(status, webhook: webhook) {
            lock.withLock { lastTemperature = celsius }
            temperature?.characteristic(.currentTemperature).value = .double(min(max(celsius, -270), 100))
        }
        if let value = status["humidity"].flatMap(number) {
            humidity?.characteristic(.currentRelativeHumidity).value = .double(min(max(value, 0), 100))
        }
        if let ppm = (status["CO2"] ?? status["co2"]).flatMap(number), let carbonDioxide {
            carbonDioxide.characteristic(.carbonDioxideLevel).value = .double(min(max(ppm, 0), 100_000))
            carbonDioxide.characteristic(.carbonDioxideDetected).value = .int(ppm >= co2Threshold ? 1 : 0)
        }
        switch family {
        case .hub, .presence: showLightLevel(status["lightLevel"], steps: 19, on: lightSensor)
        default: showBrightness(status["brightness"], on: lightSensor)
        }
        if let detected = Self.detected(status["moveDetected"] ?? status["detectionState"]) {
            motion?.characteristic(.motionDetected).value = .bool(detected)
        }
        if let detected = Self.detected(status["Detected"] ?? status["detected"] ?? status["detectionState"]) {
            occupancy?.characteristic(.occupancyDetected).value = .int(detected ? 1 : 0)
        }
        if let state = status["openState"]?.stringValue {
            contact?.characteristic(.contactSensorState).value = .int(state == "close" ? 0 : 1)
        }
        if let leak {
            let reading = webhook ? status["detectionState"] : status["status"]
            if let value = reading.flatMap(number) {
                let wet = (value != 0) != options.flag("dry")
                if wet && leak.characteristic(.leakDetected).value.intValue != 1 { logger.warning("\(info.type) \(name): leak detected") }
                leak.characteristic(.leakDetected).value = .int(wet ? 1 : 0)
            }
            if !webhook, let level = status["battery"].flatMap(number) { leak[.statusActive]?.value = .bool(level != 0) }
        }
    }

    /// A detection: a flag, or `DETECTED`/`NOT_DETECTED`.
    static func detected(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag): flag
        case .string(let text): text.uppercased() == "DETECTED"
        case .number(let number): number != 0
        default: nil
        }
    }

    override func showOffline() {
        temperature?.characteristic(.currentTemperature).value = .double(30)
        humidity?.characteristic(.currentRelativeHumidity).value = .double(50)
        battery?.characteristic(.batteryLevel).value = .int(100)
        contact?.characteristic(.contactSensorState).value = .int(0)
        motion?.characteristic(.motionDetected).value = .bool(false)
        occupancy?.characteristic(.occupancyDetected).value = .int(0)
        leak?.characteristic(.leakDetected).value = .int(0)
    }
}
