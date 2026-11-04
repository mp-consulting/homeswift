import Foundation
import Homeswift
import HomeswiftAI

// MARK: - Lights and switches (docs/clean-room/Tahoma.md 5.7)

/// `Light` and `Generic/DimmerOnOff`: a Lightbulb with `setIntensity`, else a Switch.
final class LightMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .lightbulb }
    override class var kind: String { "light" }
    private var light: Service!

    var dimmable: Bool { device.has("setIntensity") }
    var coloured: Bool { dimmable && device.has("setHueAndSaturation") }

    override func build() throws -> [Service] {
        let light: Service
        if dimmable {
            light = Service(.lightbulb, name: label, optional: coloured ? [.brightness, .hue, .saturation] : [.brightness], isPrimary: true)
        } else {
            light = Service(.switch, name: label, isPrimary: true)
        }
        light.characteristic(.on).onWrite { [weak self] value in
            try await self?.writeOnOff(value.boolValue == true)
        }
        light[.brightness]?.onWrite { [weak self] value in
            guard let self, await debounced("brightness") else { return }
            try await execute([OverkizCommand("setIntensity", .number(value.doubleValue ?? 0))])
        }
        // Hue and Saturation go together; the Homebridge plugin never sent a Hue write (10.10).
        light[.hue]?.onWrite { [weak self] value in
            guard let self else { return }
            self.light[.hue]?.value = value
            guard await debounced("colour") else { return }
            try await execute([OverkizCommand("setHueAndSaturation", [.number(value.doubleValue ?? 0), .number(self.light.number(.saturation) ?? 0)])])
        }
        light[.saturation]?.onWrite { [weak self] value in
            guard let self else { return }
            self.light[.saturation]?.value = value
            guard await debounced("colour") else { return }
            try await execute([OverkizCommand("setHueAndSaturation", [.number(self.light.number(.hue) ?? 0), .number(value.doubleValue ?? 0)])])
        }
        self.light = light
        return [light]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let on = states["core:OnOffState"]?.stringValue { light.characteristic(.on).value = .bool(on == "on") }
        if let level = (states["core:IntensityState"] ?? states["core:LightIntensityState"])?.number { light[.brightness]?.setClamped(level) }
        if let hue = states["core:ColorHueState"]?.number { light[.hue]?.setClamped(hue) }
        if let saturation = states["core:ColorSaturationState"]?.number { light[.saturation]?.setClamped(saturation) }
    }
}

/// `OnOff`, and `ExteriorHeatingSystem` (which reads `core:OnOffState` here; the Homebridge plugin read nothing, 10.10).
final class OnOffMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .switch }
    override class var kind: String { "switch" }
    private var power: Service!

    override func build() throws -> [Service] {
        let power = Service(.switch, name: label, isPrimary: true)
        power.characteristic(.on).onWrite { [weak self] value in
            try await self?.writeOnOff(value.boolValue == true)
        }
        self.power = power
        return [power]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let on = states["core:OnOffState"]?.stringValue else { return }
        power.characteristic(.on).value = .bool(on == "on")
    }
}

/// `ExteriorHeatingSystem/DimmerExteriorHeating`: a Lightbulb whose brightness is 100 minus the level.
final class DimmerExteriorHeatingMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .heater }
    override class var kind: String { "light" }
    private var light: Service!

    override func build() throws -> [Service] {
        let light = Service(.lightbulb, name: label, optional: [.brightness], isPrimary: true)
        light.characteristic(.on).onWrite { [weak self] value in
            try await self?.writeOnOff(value.boolValue == true)
        }
        light.characteristic(.brightness).onWrite { [weak self] value in
            guard let self else { return }
            let level = value.doubleValue ?? 0
            if level != 0, level != 100 { guard await debounced("brightness") else { return } }
            try await execute([OverkizCommand("setLevel", .number(100 - level))])
        }
        self.light = light
        return [light]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let level = states["core:LevelState"]?.number else { return }
        let brightness = 100 - level
        light.characteristic(.brightness).setClamped(brightness)
        light.characteristic(.on).value = .bool(brightness != 0)
    }
}

/// `Siren`: a Speaker, Mute on while it is off.
final class SirenMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .speaker }
    override class var kind: String { "siren" }
    private var speaker: Service!

    override func build() throws -> [Service] {
        let speaker = Service(.speaker, name: label, optional: [.volume], isPrimary: true)
        speaker.characteristic(.mute).value = true
        // Mute silences a sounding alarm: a security control, as the alarm's target is.
        speaker.characteristic(.mute).securityControl().onWrite { [weak self] value in
            try await self?.execute([OverkizCommand(value.boolValue == true ? "off" : "on")])
        }
        speaker.characteristic(.volume).onWrite { [weak self] value in
            guard let self, await debounced("volume") else { return }
            try await execute([OverkizCommand("setVolume", .number(value.doubleValue ?? 0))])
        }
        self.speaker = speaker
        return [speaker]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let on = states["core:OnOffState"]?.stringValue else { return }
        speaker.characteristic(.mute).value = .bool(on == "off")
    }
}

// MARK: - Sensors (5.9)

/// A sensor: one service, its reading, and where listed the defect handling of `core:SensorDefectState`.
class SensorMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .sensor }
    override class var kind: String { "sensor" }
    private(set) var sensor: Service!

    /// The service, built by the subclass.
    func makeService() -> Service { Service(.contactSensor, name: label, isPrimary: true) }
    /// Whether it gets Status Fault and Status Low Battery from `core:SensorDefectState`.
    var readsDefect: Bool { true }
    func read(_ states: [String: JSONValue]) {}

    override func build() throws -> [Service] {
        let sensor = makeService()
        if hasState("core:SensorDefectState") {
            sensor.characteristic(adding: .statusFault).value = 0
            sensor.characteristic(adding: .statusLowBattery).value = 0
        }
        self.sensor = sensor
        return [sensor]
    }

    /// A Contact Sensor's state from each of `names` present, in order: 1 (no contact) when `isOpen`.
    func showContact(_ states: [String: JSONValue], _ names: [String], isOpen: (String) -> Bool) {
        for name in names {
            if let value = states[name]?.stringValue { sensor.characteristic(.contactSensorState).value = .int(isOpen(value) ? 1 : 0) }
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        read(states)
        if readsDefect, let defect = states["core:SensorDefectState"]?.stringValue {
            switch defect {
            case "lowBattery": sensor[.statusLowBattery]?.value = 1
            case "maintenanceRequired", "dead": sensor[.statusFault]?.value = 1
            case "noDefect":
                sensor[.statusFault]?.value = 0
                sensor[.statusLowBattery]?.value = 0
            default: break
            }
        }
    }
}

/// `ContactSensor`: 0 (contact) while closed.
final class ContactSensorMapper: SensorMapper, @unchecked Sendable {
    override func read(_ states: [String: JSONValue]) {
        showContact(states, ["core:ContactState"]) { $0 != "closed" }
    }
}

/// `WindowHandle`.
final class WindowHandleMapper: SensorMapper, @unchecked Sendable {
    override func read(_ states: [String: JSONValue]) {
        showContact(states, ["core:ThreeWayHandleDirectionState", "core:OpenClosedState"]) { $0 != "closed" }
    }
}

/// `RainSensor`: a Contact Sensor that is open while it rains, as the Homebridge plugin showed it (its service stays).
final class RainSensorMapper: SensorMapper, @unchecked Sendable {
    override func read(_ states: [String: JSONValue]) {
        showContact(states, ["core:RainState"]) { $0 == "detected" }
    }
}

/// `HumiditySensor/WaterDetectionSensor`: a Contact Sensor closed while it detects water (the Homebridge plugin's state
/// name had a trailing space and never matched, 10.10).
final class WaterDetectionContactMapper: SensorMapper, @unchecked Sendable {
    override func read(_ states: [String: JSONValue]) {
        showContact(states, ["core:WaterDetectionState"]) { $0 != "detected" }
    }
}

/// `OccupancySensor`: a Motion Sensor for a widget named `Motion…`, else an Occupancy Sensor.
final class OccupancySensorMapper: SensorMapper, @unchecked Sendable {
    var motion: Bool { device.widgetName.hasPrefix("Motion") }

    override func makeService() -> Service { Service(motion ? .motionSensor : .occupancySensor, name: label, isPrimary: true) }

    override func read(_ states: [String: JSONValue]) {
        guard let value = states["core:OccupancyState"]?.stringValue else { return }
        if motion { sensor.characteristic(.motionDetected).value = .bool(value == "personInside") }
        else { sensor.characteristic(.occupancyDetected).value = .int(value == "personInside" ? 1 : 0) }
    }
}

/// `SmokeSensor`.
final class SmokeSensorMapper: SensorMapper, @unchecked Sendable {
    override func makeService() -> Service { Service(.smokeSensor, name: label, isPrimary: true) }

    override func build() throws -> [Service] {
        let services = try super.build()
        if ["core:SensorDefectState", "io:MaintenanceRadioPartBatteryState", "io:SensorRoomState"].contains(where: hasState) {
            sensor.characteristic(adding: .statusFault).value = 0
            sensor.characteristic(adding: .statusLowBattery).value = 0
        }
        if hasState("core:StatusState") { sensor.characteristic(adding: .statusActive).value = true }
        return services
    }

    override func read(_ states: [String: JSONValue]) {
        if let smoke = states["core:SmokeState"]?.stringValue { sensor.characteristic(.smokeDetected).value = .int(smoke == "detected" ? 1 : 0) }
        if let status = states["core:StatusState"]?.stringValue { sensor[.statusActive]?.value = .bool(status == "available") }
        for name in ["io:MaintenanceRadioPartBatteryState", "io:MaintenanceSensorPartBatteryState"] {
            switch states[name]?.stringValue {
            case "normal", "absence": sensor[.statusLowBattery]?.value = 0
            case "low": sensor[.statusLowBattery]?.value = 1
            default: break
            }
        }
        switch states["io:SensorRoomState"]?.stringValue {
        case "clean": sensor[.statusFault]?.value = 0
        case "dirty": sensor[.statusFault]?.value = 1
        default: break
        }
    }
}

/// `WaterSensor`: a Leak Sensor.
final class WaterSensorMapper: SensorMapper, @unchecked Sendable {
    override func makeService() -> Service { Service(.leakSensor, name: label, isPrimary: true) }
    override var readsDefect: Bool { false }

    override func read(_ states: [String: JSONValue]) {
        if let value = states["core:WaterDetectionState"]?.stringValue { sensor.characteristic(.leakDetected).value = .int(value == "detected" ? 1 : 0) }
    }
}

/// `TemperatureSensor`, `EvoHome/DHWSetPoint`: values above 200 are kelvin.
final class TemperatureSensorMapper: SensorMapper, @unchecked Sendable {
    override func makeService() -> Service {
        Service(.temperatureSensor, name: label, optional: [CharacteristicType.currentTemperature.with(minValue: -50, maxValue: 100, minStep: 0.1)], isPrimary: true)
    }
    override var readsDefect: Bool { false }

    override func read(_ states: [String: JSONValue]) {
        guard let value = states["core:TemperatureState"]?.number else { return }
        sensor.characteristic(.currentTemperature).setClamped(value > 200 ? value - 273.15 : value)
    }
}

/// `HumiditySensor`, `AirSensor/RelativeHumiditySensor`.
final class HumiditySensorMapper: SensorMapper, @unchecked Sendable {
    override func makeService() -> Service { Service(.humiditySensor, name: label, isPrimary: true) }
    override var readsDefect: Bool { false }

    override func read(_ states: [String: JSONValue]) {
        sensor.characteristic(.currentRelativeHumidity).setClamped(states["core:RelativeHumidityState"]?.number)
    }
}

/// `LightSensor`: lux.
final class LightSensorMapper: SensorMapper, @unchecked Sendable {
    override func makeService() -> Service { Service(.lightSensor, name: label, isPrimary: true) }
    override var readsDefect: Bool { false }

    override func read(_ states: [String: JSONValue]) {
        sensor.characteristic(.currentAmbientLightLevel).setClamped(states["core:LuminanceState"]?.number)
    }
}

/// `AirSensor`, and `AirSensor/CO2Sensor` with its CO2 level (keeping the defect handling the Homebridge plugin lost, 10.10).
final class AirSensorMapper: SensorMapper, @unchecked Sendable {
    var measuresCO2: Bool { device.widgetName == "CO2Sensor" }

    override func makeService() -> Service {
        Service(.airQualitySensor, name: label, optional: measuresCO2 ? [.carbonDioxideLevel] : [], isPrimary: true)
    }

    override func build() throws -> [Service] {
        let services = try super.build()
        sensor.characteristic(adding: .statusFault).value = 0
        if hasState("core:StatusState") { sensor.characteristic(adding: .statusActive).value = true }
        return services
    }

    static func quality(_ value: String) -> Int? {
        switch value {
        case "optimalAirRange": 1
        case "slightlyHumidRange", "slightlyDryAirRange": 2
        case "dryAirRange", "slightlyHotAndHumidRange": 3
        case "excessivelyDryAirRange", "highHumidityRange", "highTemperatureAndHumidityRange": 4
        case "mouldsAndDustMitesRisk", "mouldsRisk", "temperatureOrHumidityOutOfAnalysisRange": 5
        case "error": 0
        default: nil
        }
    }

    static func quality(co2: Double) -> Int {
        switch co2 {
        case ..<350: 1
        case ..<1000: 2
        case ..<2000: 3
        case ..<5000: 4
        default: 5
        }
    }

    override func read(_ states: [String: JSONValue]) {
        if let value = states["core:AirQualityState"]?.stringValue, let quality = Self.quality(value) {
            sensor.characteristic(.airQuality).value = .int(quality)
        }
        if let status = states["core:StatusState"]?.stringValue { sensor[.statusActive]?.value = .bool(status == "available") }
        if measuresCO2, let co2 = states["core:CO2ConcentrationState"]?.number {
            sensor[.carbonDioxideLevel]?.setClamped(co2)
            sensor.characteristic(.airQuality).value = .int(Self.quality(co2: co2))
        }
    }
}
