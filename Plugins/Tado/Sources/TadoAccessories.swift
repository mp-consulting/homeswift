import Foundation
import Homeswift
import HomeswiftPlugin

// The accessories of a home (docs/clean-room/Tado.md, section 6): their names are the Homebridge plugin's identity
// seeds (the accessory ids are `TadoPlatform:<display name>`), their services keep its subtypes, so the aids and iids
// stay what they are for the same block.

extension CharacteristicType {
    private static func custom(_ name: String, _ uuid: String, _ format: CharacteristicFormat, write: Bool = false,
                               min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: CharacteristicUnit? = nil) -> CharacteristicType {
        CharacteristicType(name: name, uuid: HAPUUID(uuid), format: format, permissions: write ? [.pairedRead, .pairedWrite, .events] : [.pairedRead, .events],
                           unit: unit, minValue: min, maxValue: max, minStep: step)
    }

    static let tadoDelay = custom("Delay", "B7C9DB1A-E54E-4F4F-B3B4-17A19B2C4631", .bool, write: true)
    static let tadoDelayTimer = custom("Timer", "2E4EB630-62AB-41FE-BCC1-EA5C3CF98508", .int, write: true, min: 0, max: 120, step: 10, unit: .seconds)
    static let tadoModeAuto = custom("Mode Auto", "12EDECE0-36C8-427F-895C-3B88EA186388", .int, min: 0, max: 100, step: 1)
    static let tadoModeManual = custom("Mode Manual", "2BE09385-4DC3-4438-9FEE-B5B2E0642004", .int, min: 0, max: 100, step: 1)
    static let tadoModeOff = custom("Mode Off", "93131984-615C-401B-84AC-54E22DB492C6", .int, min: 0, max: 100, step: 1)
    static let tadoActivityDay = custom("Activity Day", "43C89074-B70A-480C-8239-51697A9DB445", .float, min: 0, max: 99999, step: 0.01)
    static let tadoActivityMonth = custom("Activity Month", "1874332A-D7DD-4E45-9D65-A4BAA6D11121", .float, min: 0, max: 99999, step: 0.01)
    static let tadoActivityYear = custom("Activity Year", "D105B9F7-AFE7-44A2-9CBE-F079BA499733", .float, min: 0, max: 99999, step: 0.01)
    static let eveValvePosition = custom("Valve Position", "E863F12E-079E-48FF-8F27-9C2605A29F52", .uint8, min: 0, max: 100, step: 1, unit: .percentage)
    static let eveLastActivation = custom("Last Activation", "E863F11A-079E-48FF-8F27-9C2605A29F52", .uint32, unit: .seconds)
    static let eveTimesOpened = custom("Times Opened", "E863F129-079E-48FF-8F27-9C2605A29F52", .uint32)
    static let eveResetTotal = custom("Reset Total", "E863F112-079E-48FF-8F27-9C2605A29F52", .uint32, write: true, unit: .seconds)
    static let eveOpenDuration = custom("Open Duration", "E863F118-079E-48FF-8F27-9C2605A29F52", .uint32, write: true, unit: .seconds)
    static let eveClosedDuration = custom("Closed Duration", "E863F119-079E-48FF-8F27-9C2605A29F52", .uint32, write: true, unit: .seconds)
}

/// The services of one zone, on its accessories.
struct ZoneServices: Sendable {
    let zone: ZoneSettings
    let kind: ZoneKind
    let deviceID: String
    let limits: (min: Double, max: Double, step: Double)
    let primary: Service
    let battery: Service?
    let fanSwitch: Service?
    let drySwitch: Service?
    let window: Service?
    let windowBattery: Service?
    let temperature: Service?
    let temperatureBattery: Service?
    let humidity: Service?
    let humidityBattery: Service?
    /// Its switch on the home's Open Window accessory.
    var windowSwitch: Service?

    var batteries: [Service] { [battery, windowBattery, temperatureBattery, humidityBattery].compactMap { $0 } }
}

enum TadoAccessories {
    static let manufacturer = "tado"

    static func battery() -> Service {
        let battery = Service(.battery, optional: [.batteryLevel, .chargingState])
        battery.characteristic(.chargingState).value = .int(2)
        battery.characteristic(.batteryLevel).value = .int(100)
        return battery
    }

    /// The zone's accessories: its own, then the window contact and the separate sensors it asks for.
    static func zone(_ zone: ZoneSettings, home: String, unit: TemperatureUnit, firmware: String) -> (services: ZoneServices, accessories: [Accessory]) {
        let display = HomeSettings.zoneDeviceID(home: home, zone: zone.name, type: zone.type)
        let kind = zone.kind
        let limits = zone.limits(unit: unit, heaterCoolerRule: kind != .thermostat)
        var optional: [CharacteristicType] = []
        var extra: [Characteristic] = []
        let humidity = !zone.separateHumidity && zone.type != .hotWater
        let delay = zone.delaySwitch && zone.type != .hotWater && (kind == .thermostat || kind.isHeaterCooler)
        if delay {
            extra.append(Characteristic(.tadoDelay, value: .bool(false)))
            extra.append(Characteristic(.tadoDelayTimer, value: .int(0)))
        }
        let primary: Service
        var fanSwitch: Service?, drySwitch: Service?
        var category = AccessoryCategory.thermostat
        switch kind {
        case .thermostat:
            optional = [
                .currentTemperature.with(minValue: -255, maxValue: 255),
                .targetTemperature.with(minValue: limits.min, maxValue: limits.max, minStep: limits.step),
                .targetHeatingCoolingState.with(validValues: [0, 1, 3]),
                .currentHeatingCoolingState.with(minValue: 0, maxValue: 1, validValues: [0, 1]),
            ] + (humidity ? [.currentRelativeHumidity] : [])
            extra.append(Characteristic(.eveValvePosition, value: .int(0)))
            primary = Service(.thermostat, name: display, subtype: kind.rawValue, optional: optional, extra: extra, isPrimary: true)
            primary.characteristic(.targetTemperature).value = .double(min(max(20, limits.min), limits.max))
            primary.characteristic(.temperatureDisplayUnits).value = .int(unit == .fahrenheit ? 1 : 0)
        case .heaterCooler, .boiler, .airConditioner:
            category = kind == .airConditioner ? .airConditioner : (kind == .boiler ? .heater : .thermostat)
            let currentStates = kind == .boiler ? [0, 1, 2] : [0, 1, 2, 3]
            optional = [
                .currentTemperature.with(minValue: -255, maxValue: 255),
                .heatingThresholdTemperature.with(minValue: limits.min, maxValue: limits.max, minStep: limits.step),
                .currentHeaterCoolerState.with(validValues: currentStates),
                .targetHeaterCoolerState.with(minValue: 1, maxValue: kind == .airConditioner ? 2 : 1, validValues: kind == .airConditioner ? [1, 2] : [1]),
            ]
            if kind == .heaterCooler { optional.append(.coolingThresholdTemperature.with(minValue: limits.min, maxValue: limits.max, minStep: limits.step)) }
            if kind == .airConditioner { optional.append(.coolingThresholdTemperature) }
            if humidity && kind != .boiler { optional.append(.currentRelativeHumidity) }
            if kind == .airConditioner && zone.acFanSpeed { optional.append(.rotationSpeed) }
            extra.append(Characteristic(.eveValvePosition, value: .int(0)))
            primary = Service(.heaterCooler, name: display, subtype: kind.rawValue, optional: optional, extra: extra, isPrimary: true)
            primary.characteristic(.targetHeaterCoolerState).value = .int(1)
            primary.characteristic(.heatingThresholdTemperature).value = .double(kind == .boiler ? limits.min : min(max(20, limits.min), limits.max))
            if kind == .airConditioner {
                if zone.acFanModeSwitch { fanSwitch = Service(.switch, name: "\(display) Fan", subtype: "FanModeSwitch") }
                if zone.acDryModeSwitch { drySwitch = Service(.switch, name: "\(display) Dry", subtype: "DryModeSwitch") }
            }
        case .switch:
            category = .switch
            primary = Service(.switch, name: display, subtype: kind.rawValue, isPrimary: true)
        case .faucet:
            category = .faucet
            primary = Service(.valve, name: display, subtype: kind.rawValue, optional: [.isConfigured, .statusFault], isPrimary: true)
            primary.characteristic(.isConfigured).value = .int(1)
            primary.characteristic(.valveType).value = .int(3)
        }
        let battery = zone.hasBattery && (kind == .thermostat || kind == .heaterCooler) ? Self.battery() : nil
        let zoneAccessory = Accessory(
            id: "\(TadoPlugin.platform):\(display)", name: display, manufacturer: manufacturer, model: zone.type.rawValue,
            serialNumber: TadoHash.serial(display), firmwareRevision: firmware, category: category,
            services: [primary] + [battery, fanSwitch, drySwitch].compactMap { $0 })
        var accessories = [zoneAccessory]

        func sensor(_ suffix: String, _ type: ServiceType, subtype: String, model: String, optional: [CharacteristicType] = [], extra: [Characteristic] = []) -> (Service, Service?) {
            let name = "\(home) \(zone.name) \(suffix)"
            let service = Service(type, name: name, subtype: subtype, optional: optional, extra: extra, isPrimary: true)
            let battery = zone.hasBattery ? Self.battery() : nil
            accessories.append(Accessory(
                id: "\(TadoPlugin.platform):\(name)", name: name, manufacturer: manufacturer, model: model, serialNumber: TadoHash.serial(zone.name),
                firmwareRevision: firmware, category: .sensor, services: [service] + (battery.map { [$0] } ?? [])))
            return (service, battery)
        }
        var window: (Service, Service?)?, temperature: (Service, Service?)?, humiditySensor: (Service, Service?)?
        if zone.openWindowSensor {
            window = sensor("Window", .contactSensor, subtype: "zone-window-contact", model: "zone-window-contact", extra: [
                Characteristic(.eveLastActivation, value: .int(0)), Characteristic(.eveTimesOpened, value: .int(0)),
                Characteristic(.eveResetTotal, value: .int(0)), Characteristic(.eveOpenDuration, value: .int(0)),
                Characteristic(.eveClosedDuration, value: .int(0)),
            ])
        }
        if zone.separateTemperature {
            temperature = sensor("Temperature", .temperatureSensor, subtype: "zone-temperature", model: "zone-temperature",
                                 optional: [.currentTemperature.with(minValue: -100, maxValue: 100)])
        }
        if zone.separateHumidity { humiditySensor = sensor("Humidity", .humiditySensor, subtype: "zone-humidity", model: "zone-humidity") }
        // Until the first poll (or the cache) says: 0 rather than the range's lowest.
        for service in [primary, temperature?.0].compactMap({ $0 }) { service[.currentTemperature]?.value = .double(0) }
        let services = ZoneServices(
            zone: zone, kind: kind, deviceID: display, limits: limits, primary: primary, battery: battery, fanSwitch: fanSwitch, drySwitch: drySwitch,
            window: window?.0, windowBattery: window?.1, temperature: temperature?.0, temperatureBattery: temperature?.1,
            humidity: humiditySensor?.0, humidityBattery: humiditySensor?.1, windowSwitch: nil)
        return (services, accessories)
    }

    /// An accessory of the home that is not a zone's, its primary service first.
    static func accessory(_ name: String, model: String, category: AccessoryCategory, firmware: String, services: [Service]) -> Accessory {
        Accessory(id: "\(TadoPlugin.platform):\(name)", name: name, manufacturer: manufacturer, model: model, serialNumber: TadoHash.serial(name),
                  firmwareRevision: firmware, category: category, services: services)
    }
}
