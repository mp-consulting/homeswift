import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

// MARK: Eve's types (the Eve app's own UUIDs)

enum EveTypes {
    static func float(_ name: String, _ uuid: String, max: Double, step: Double) -> CharacteristicType {
        CharacteristicType(name: name, uuid: HAPUUID(uuid), format: .float, permissions: [.pairedRead, .events], minValue: 0, maxValue: max, minStep: step)
    }

    static let airPressure = EveCharacteristic.airPressure
    static let airPressureSensor = ServiceType(name: "AirPressureSensor", uuid: HAPUUID("E863F00A-079E-48FF-8F27-9C2605A29F52"), required: [airPressure], optional: [.name])
    static let consumption = float("Consumption", "E863F10D-079E-48FF-8F27-9C2605A29F52", max: 65535, step: 0.1)
    static let voltage = float("Voltage", "E863F10A-079E-48FF-8F27-9C2605A29F52", max: 500, step: 0.1)
    static let current = float("Current", "E863F126-079E-48FF-8F27-9C2605A29F52", max: 100, step: 0.001)
    static let totalConsumption = float("Total Consumption", "E863F10C-079E-48FF-8F27-9C2605A29F52", max: 4_294_967_295, step: 0.001)
    static let totalProduction = float("Total Production", "E863F10C-079E-48FF-8F27-9C2605A29F52", max: 4_294_967_295, step: 0.001)
}

// MARK: Basic sensors (9.6)

/// One reading or detection, and the battery and tamper flags of its endpoint.
final class SensorHandler: ServiceHandler, @unchecked Sendable {
    enum Mapping {
        /// The number as it is.
        case number
        /// `value_on` → `on`, `value_off` → `off`.
        case binary(on: HAPValue, off: HAPValue)
    }

    let service: Service
    let gettableKeys: [String]
    private let entry: Expose
    private let characteristic: CharacteristicType
    private let mapping: Mapping
    private let batteryLow: Expose?
    private let tamper: Expose?
    private let link: DeviceLink
    /// Carbon dioxide: Detected once the level reaches it.
    private let abnormalAt: Double?

    init(service: Service, entry: Expose, characteristic: CharacteristicType, mapping: Mapping, batteryLow: Expose?, tamper: Expose?, abnormalAt: Double? = nil, link: DeviceLink) {
        self.service = service
        self.entry = entry
        self.characteristic = characteristic
        self.mapping = mapping
        self.batteryLow = batteryLow
        self.tamper = tamper
        self.abnormalAt = abnormalAt
        self.link = link
        gettableKeys = [entry.gettableProperty, batteryLow?.gettableProperty, tamper?.gettableProperty].compactMap { $0 }
    }

    func update(_ message: [String: JSONValue]) {
        if let property = entry.property, let value = message[property] {
            switch mapping {
            case .number:
                if let number = value.doubleValue {
                    link.setNumber(service.characteristic(characteristic), number)
                    if let abnormalAt { service.characteristic(.carbonDioxideDetected).value = .int(number >= abnormalAt ? 1 : 0) }
                }
            case .binary(let on, let off):
                if let state = entry.onOff(value) { service.characteristic(characteristic).value = state ? on : off }
            }
        }
        if let batteryLow, let property = batteryLow.property, let low = batteryLow.onOff(message[property]) {
            service.characteristic(.statusLowBattery).value = .int(low ? 1 : 0)
        }
        if let tamper, let property = tamper.property, let tampered = tamper.onOff(message[property]) {
            service.characteristic(.statusTampered).value = .int(tampered ? 1 : 0)
        }
    }
}

extension ServiceBuilder {
    private struct SensorKind {
        var names: [String]
        var numeric: Bool
        var service: ServiceType
        var characteristic: CharacteristicType
        var mapping: SensorHandler.Mapping
        var subtype: (String?) -> String?
        /// The characteristic's type when the entry has no range of its own.
        var defaultRange: CharacteristicType?
        var abnormalAt: Double?
        /// False for a reading whose range is HomeKit's own whatever the entry says (Eve's air pressure).
        var copiesRange = true
        var initialValue: HAPValue?

        static func endpoint(_ endpoint: String?) -> String? { endpoint }
        static func before(_ word: String) -> (String?) -> String? { { $0.map { "\(word) \($0)" } ?? word } }
        static func after(_ word: String) -> (String?) -> String? { { $0.map { "\($0) \(word)" } ?? word } }
    }

    private var sensorKinds: [SensorKind] {
        let detected = SensorHandler.Mapping.binary(on: .int(1), off: .int(0))
        let motion = SensorHandler.Mapping.binary(on: .bool(true), off: .bool(false))
        let occupancy = options.occupancyAsMotion
            ? SensorKind(names: ["occupancy"], numeric: false, service: .motionSensor, characteristic: .motionDetected, mapping: motion, subtype: SensorKind.after("occupancy"))
            : SensorKind(names: ["occupancy"], numeric: false, service: .occupancySensor, characteristic: .occupancyDetected, mapping: detected, subtype: SensorKind.endpoint)
        return [
            SensorKind(names: ["humidity"], numeric: true, service: .humiditySensor, characteristic: .currentRelativeHumidity, mapping: .number, subtype: SensorKind.endpoint),
            SensorKind(names: ["temperature"], numeric: true, service: .temperatureSensor, characteristic: .currentTemperature, mapping: .number,
                       subtype: SensorKind.endpoint, defaultRange: .currentTemperature.with(minValue: -100, maxValue: 100)),
            SensorKind(names: ["illuminance_lux", "illuminance"], numeric: true, service: .lightSensor, characteristic: .currentAmbientLightLevel, mapping: .number,
                       subtype: SensorKind.endpoint, defaultRange: .currentAmbientLightLevel.with(minValue: 0)),
            SensorKind(names: ["pressure"], numeric: true, service: EveTypes.airPressureSensor, characteristic: EveTypes.airPressure, mapping: .number, subtype: SensorKind.endpoint,
                       copiesRange: false, initialValue: .int(1013)),
            SensorKind(names: ["contact"], numeric: false, service: .contactSensor, characteristic: .contactSensorState, mapping: detected, subtype: SensorKind.endpoint),
            occupancy,
            SensorKind(names: ["presence"], numeric: false, service: .occupancySensor, characteristic: .occupancyDetected, mapping: detected, subtype: SensorKind.before("presence")),
            SensorKind(names: ["vibration"], numeric: false, service: .motionSensor, characteristic: .motionDetected, mapping: motion, subtype: SensorKind.before("vibration")),
            SensorKind(names: ["moving"], numeric: false, service: .motionSensor, characteristic: .motionDetected, mapping: motion, subtype: SensorKind.before("moving")),
            SensorKind(names: ["smoke"], numeric: false, service: .smokeSensor, characteristic: .smokeDetected, mapping: detected, subtype: SensorKind.endpoint),
            SensorKind(names: ["carbon_monoxide"], numeric: false, service: .carbonMonoxideSensor, characteristic: .carbonMonoxideDetected, mapping: detected, subtype: SensorKind.endpoint),
            SensorKind(names: ["water_leak"], numeric: false, service: .leakSensor, characteristic: .leakDetected, mapping: detected, subtype: SensorKind.after("water")),
            SensorKind(names: ["gas"], numeric: false, service: .leakSensor, characteristic: .leakDetected, mapping: detected, subtype: SensorKind.after("gas")),
            SensorKind(names: ["device_temperature"], numeric: true, service: .temperatureSensor, characteristic: .currentTemperature, mapping: .number,
                       subtype: SensorKind.after("device_temperature"), defaultRange: .currentTemperature.with(minValue: -100, maxValue: 100)),
            SensorKind(names: ["co2"], numeric: true, service: .carbonDioxideSensor, characteristic: .carbonDioxideLevel, mapping: .number, subtype: SensorKind.endpoint,
                       abnormalAt: 1200),
        ]
    }

    func buildBasicSensors(_ exposes: [Expose]) {
        let kinds = sensorKinds
        for (endpoint, entries) in Self.groupedByEndpoint(exposes, where: { _ in true }) {
            let batteryLow = entries.first { $0.name == "battery_low" && $0.isBinary }
            let tamper = entries.first { $0.name == "tamper" && $0.isBinary }
            for kind in kinds {
                let fits = { (entry: Expose) in kind.numeric ? entry.type == "numeric" : entry.isBinary }
                let named = kind.names.lazy.map { name in entries.filter { $0.name == name && fits($0) } }.first { !$0.isEmpty } ?? []
                for entry in named {
                    let subtype = kind.subtype(endpoint)
                    guard claim(kind.service, subtype: subtype) else { continue }
                    var optional: [CharacteristicType] = []
                    if kind.numeric, kind.copiesRange {
                        optional.append(entry.isNumericRange ? ranged(kind.characteristic, entry) : kind.defaultRange ?? kind.characteristic)
                    }
                    if batteryLow != nil { optional.append(.statusLowBattery) }
                    if tamper != nil { optional.append(.statusTampered) }
                    // An optional type the service requires replaces it, with the entry's range.
                    let service = service(kind.service, subtype: subtype, optional: optional)
                    if let initial = kind.initialValue { service.characteristic(kind.characteristic).value = initial }
                    add(SensorHandler(service: service, entry: entry, characteristic: kind.characteristic, mapping: kind.mapping, batteryLow: batteryLow,
                                      tamper: tamper, abnormalAt: kind.abnormalAt, link: link))
                }
            }
        }
    }
}

// MARK: Air quality (9.7)

final class AirQualityHandler: ServiceHandler, @unchecked Sendable {
    struct Reading {
        var entry: Expose
        var characteristic: CharacteristicType
        var thresholds: [Double]
    }

    let service: Service
    let gettableKeys: [String]
    private let readings: [Reading]
    private let link: DeviceLink
    private let levels: NIOLockedValueBox<[String: Int]>

    init(service: Service, readings: [Reading], link: DeviceLink) {
        self.service = service
        self.readings = readings
        self.link = link
        levels = NIOLockedValueBox([:])
        gettableKeys = readings.compactMap(\.entry.gettableProperty)
    }

    /// EXCELLENT (1) to POOR (5) for a value, UNKNOWN (0) for none.
    static func level(_ value: Double?, thresholds: [Double]) -> Int {
        guard let value else { return 0 }
        return (thresholds.firstIndex { value <= $0 } ?? thresholds.count) + 1
    }

    func update(_ message: [String: JSONValue]) {
        for reading in readings {
            guard let property = reading.entry.property, let value = message[property] else { continue }
            let number = value.doubleValue
            if let number { link.setNumber(service.characteristic(reading.characteristic), number) }
            levels.withLockedValue { $0[property] = Self.level(number, thresholds: reading.thresholds) }
        }
        service.characteristic(.airQuality).value = .int(levels.withLockedValue { $0.values.max() } ?? 0)
    }
}

extension ServiceBuilder {
    func buildAirQuality(_ exposes: [Expose]) {
        let kinds: [String: (CharacteristicType, [Double])] = [
            "voc": (.vocDensity, [333, 1000, 3333, 8332]), "pm10": (.pm10Density, [25, 50, 100, 300]), "pm25": (.pm2_5Density, [15, 35, 55, 75]),
        ]
        for (endpoint, entries) in Self.groupedByEndpoint(exposes, where: { $0.type == "numeric" && kinds[$0.name ?? ""] != nil }) {
            guard claim(.airQualitySensor, subtype: endpoint) else { continue }
            let readings = entries.compactMap { entry in kinds[entry.name ?? ""].map { AirQualityHandler.Reading(entry: entry, characteristic: $0.0, thresholds: $0.1) } }
            let service = service(.airQualitySensor, subtype: endpoint, optional: readings.map { ranged($0.characteristic, $0.entry) })
            add(AirQualityHandler(service: service, readings: readings, link: link))
        }
    }
}

// MARK: Electrical (9.8)

final class ElectricalHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let readings: [(property: String, characteristic: CharacteristicType)]
    private let link: DeviceLink

    init(service: Service, readings: [(property: String, characteristic: CharacteristicType)], link: DeviceLink) {
        self.service = service
        self.readings = readings
        self.link = link
        // Every one of them, whatever its access says (9.8).
        gettableKeys = readings.map(\.property)
    }

    func update(_ message: [String: JSONValue]) {
        for reading in readings {
            if let value = message[reading.property]?.doubleValue { link.setNumber(service.characteristic(reading.characteristic), value) }
        }
    }
}

extension ServiceBuilder {
    func buildElectrical(_ exposes: [Expose]) {
        let quantities: [(names: [String], characteristic: CharacteristicType)] = [
            (["power", "active_power", "load"], EveTypes.consumption), (["voltage", "mains_voltage", "rms_voltage"], EveTypes.voltage),
            (["current"], EveTypes.current), (["energy", "consumed_energy", "energy_consumed"], EveTypes.totalConsumption),
        ]
        let produced = ["produced_energy", "energy_produced"]
        let all = Set(quantities.flatMap(\.names) + produced)
        for (endpoint, entries) in Self.groupedByEndpoint(exposes, where: { $0.type == "numeric" && all.contains($0.name ?? "") }) {
            func first(_ names: [String]) -> String? { names.lazy.compactMap { name in entries.first { $0.name == name }?.property }.first }
            let readings = quantities.compactMap { quantity in first(quantity.names).map { (property: $0, characteristic: quantity.characteristic) } }
            // Voltage alone (a battery's, usually) is no meter.
            if readings.contains(where: { $0.characteristic != EveTypes.voltage }), claim(EveService.energy, subtype: endpoint) {
                let service = service(EveService.energy, subtype: endpoint, extra: readings.map { Characteristic($0.characteristic, value: .double(0)) })
                add(ElectricalHandler(service: service, readings: readings, link: link))
            }
            let productionSubtype = endpoint.map { "\($0) produced" } ?? "produced"
            if let property = first(produced), claim(EveService.energy, subtype: productionSubtype) {
                let service = service(EveService.energy, subtype: productionSubtype, extra: [Characteristic(EveTypes.totalProduction, value: .double(0))])
                add(ElectricalHandler(service: service, readings: [(property, EveTypes.totalProduction)], link: link))
            }
        }
    }
}

// MARK: Action (9.9)

final class ActionHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let property: String
    private let mapping: ButtonMapping

    init(service: Service, property: String, mapping: ButtonMapping, gettable: Bool) {
        self.service = service
        self.property = property
        self.mapping = mapping
        gettableKeys = gettable ? [property] : []
    }

    func update(_ message: [String: JSONValue]) {
        guard let action = message[property]?.stringValue else { return }
        let event: Int? = action == mapping.single ? 0 : action == mapping.double ? 1 : action == mapping.long ? 2 : nil
        if let event { service.characteristic(.programmableSwitchEvent).sendEvent(.int(event)) }
    }
}

extension ServiceBuilder {
    func buildActions(_ exposes: [Expose]) {
        for expose in exposes where expose.name == "action" && expose.isEnum && expose.isPublished {
            guard let property = expose.property else { continue }
            let mappings: [ButtonMapping]
            do {
                mappings = try ButtonMapping.mappings(for: expose.valueStrings)
            } catch {
                link.log.error("Could not map the buttons of \(link.displayName): \(error)")
                continue
            }
            for mapping in mappings {
                let subtype: String? =
                    switch (mapping.subtype, expose.endpoint) {
                    case let (m?, ep?): "\(m).\(ep)"
                    case let (m?, nil): m
                    case let (nil, ep?): ep
                    case (nil, nil): nil
                    }
                guard claim(.statelessProgrammableSwitch, subtype: subtype), let label = mapping.label else { continue }
                let events = [mapping.single, mapping.double, mapping.long].enumerated().compactMap { $0.element == nil ? nil : $0.offset }
                let event = Characteristic(
                    CharacteristicType.programmableSwitchEvent.with(minValue: Double(events.min() ?? 0), maxValue: Double(events.max() ?? 2), validValues: events))
                let service = service(.statelessProgrammableSwitch, subtype: subtype, optional: [.serviceLabelIndex], extra: [event])
                service.characteristic(.serviceLabelIndex).value = .int(label)
                link.log.info("Button \(label) (\(mapping.identifier ?? "")) \(mapping.extension_ > 0 ? "#ext\(mapping.extension_) " : ""): SINGLE = \(mapping.single ?? "-"), DOUBLE = \(mapping.double ?? "-"), LONG = \(mapping.long ?? "-")")
                add(ActionHandler(service: service, property: property, mapping: mapping, gettable: expose.isGettable))
            }
        }
    }
}
