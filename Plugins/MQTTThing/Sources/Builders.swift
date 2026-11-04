import Foundation
import Homeswift
import HomeswiftPlugin

/// A service's characteristics gathered before it is made, so a required one can get other bounds (HAP-NodeJS's
/// `setProps`) and the handlers are on the objects the service keeps.
final class ServiceBuilder: @unchecked Sendable {
    let type: ServiceType
    private(set) var characteristics: [Characteristic] = []

    init(_ type: ServiceType) { self.type = type }

    /// The characteristic of this type, made with `value` the first time.
    @discardableResult
    func add(_ characteristicType: CharacteristicType, _ value: HAPValue? = nil) -> Characteristic {
        if let existing = self[characteristicType] { return existing }
        let characteristic = Characteristic(characteristicType, value: value)
        characteristics.append(characteristic)
        return characteristic
    }

    subscript(type: CharacteristicType) -> Characteristic? { characteristics.first { $0.type.uuid == type.uuid } }

    func build(name: String?, subtype: String?, primary: Bool = false, hidden: Bool = false, linked: [Service] = []) -> Service {
        Service(type, name: name, subtype: subtype, extra: characteristics, linked: linked, isPrimary: primary, isHidden: hidden)
    }
}

/// One entry being built: a whole block, or one service of a `custom` block (section 5.33).
final class Entry: @unchecked Sendable {
    let config: Config
    let online: OnlineState
    var primaryHasLowBattery = false
    var history: EveHistory?

    init(config: Config, online: OnlineState) {
        self.config = config
        self.online = online
    }

    var name: String { config.name }
    var subtype: String? { config.subtype }
}

/// The Eve and weather characteristics MQTTThing uses (homebridge-lib's UUIDs and properties, section 5).
enum Eve {
    static func uuid(_ short: String) -> HAPUUID { HAPUUID("E863\(short)-079E-48FF-8F27-9C2605A29F52") }
    static let readEvents: Set<CharacteristicPermission> = [.pairedRead, .events]

    static let airPressureSensor = ServiceType(name: "Air Pressure Sensor", uuid: uuid("F00A"), required: [airPressure])
    static let airPressure = CharacteristicType(name: "Air Pressure", uuid: uuid("F10F"), format: .float, permissions: readEvents, minValue: 700, maxValue: 1100, minStep: 0.1)
    static let elevation = CharacteristicType(name: "Elevation", uuid: uuid("F130"), format: .int, permissions: readEvents, minValue: -450, maxValue: 9000, minStep: 1)
    static let airParticulateDensity = CharacteristicType(
        name: "Air Particulate Density", uuid: uuid("F10B"), format: .float, permissions: readEvents, minValue: 0, maxValue: 5000, minStep: 1)
    static let currentConsumption = CharacteristicType(
        name: "Current Consumption", uuid: uuid("F10D"), format: .float, permissions: readEvents, minValue: 0, maxValue: 12000, minStep: 0.1)
    static let voltage = CharacteristicType(name: "Voltage", uuid: uuid("F10A"), format: .float, permissions: readEvents, minValue: 0, maxValue: 380, minStep: 0.1)
    static let electricCurrent = CharacteristicType(
        name: "Electric Current", uuid: uuid("F126"), format: .float, permissions: readEvents, minValue: 0, maxValue: 48, minStep: 0.01)
    static let totalConsumption = CharacteristicType(
        name: "Total Consumption", uuid: uuid("F10C"), format: .float, permissions: readEvents, minValue: 0, maxValue: 1_000_000, minStep: 0.001)

    static func weather(_ short: String) -> HAPUUID { HAPUUID(short) }
    static let weatherService = ServiceType(name: "Weather", uuid: HAPUUID("D92D5391-92AF-4824-AF4A-356F25F25EA1"), required: [])
    static let condition = CharacteristicType(name: "Condition", uuid: HAPUUID("CD65A9AB-85AD-494A-B2BD-2F380084134D"), format: .string, permissions: readEvents)
    static let rain1h = CharacteristicType(name: "Rain Last Hour", uuid: HAPUUID("10C88F40-7EC4-478C-8D5A-BD0C3CCE14B7"), format: .uint16, permissions: readEvents, minValue: 0, maxValue: 200)
    static let rain24h = CharacteristicType(name: "Rain All Day", uuid: HAPUUID("CCC04890-565B-4376-B39A-3113341D9E0F"), format: .uint16, permissions: readEvents, minValue: 0, maxValue: 2000)
    static let uvIndex = CharacteristicType(name: "UV Index", uuid: HAPUUID("05BA0FE0-B848-4226-906D-5B64272E05CE"), format: .uint8, permissions: readEvents, minValue: 0, maxValue: 10)
    static let visibility = CharacteristicType(name: "Visibility", uuid: HAPUUID("D24ECC1E-6FAD-4FB5-8137-5AF88BD5E857"), format: .uint8, permissions: readEvents, minValue: 0, maxValue: 100)
    static let windDirection = CharacteristicType(name: "Wind Direction", uuid: HAPUUID("46F1284C-1912-421B-82F5-EB75008B167E"), format: .string, permissions: readEvents)
    static let windSpeed = CharacteristicType(
        name: "Wind Speed", uuid: HAPUUID("49C8AE5A-A3A5-41AB-BF1F-12D5654F9F41"), format: .float, permissions: readEvents, minValue: 0, maxValue: 150, minStep: 0.1)
    static let maximumWindSpeed = CharacteristicType(
        name: "Maximum Wind Speed", uuid: HAPUUID("6B8861E5-D6F3-425C-83B6-069945FFD1F1"), format: .float, permissions: readEvents, minValue: 0, maxValue: 150, minStep: 0.1)
    static let dewPoint = CharacteristicType(
        name: "Dew Point", uuid: HAPUUID("095C46E2-278E-4E3C-B9E7-364622A0F501"), format: .float, permissions: readEvents, minValue: -40, maxValue: 100, minStep: 0.1)
}

// MARK: Binding helpers

extension Thing {
    /// A boolean characteristic (section 3.4) with its auto-off (`turnOffAfterms`) or reset (`resetStateAfterms`).
    @discardableResult
    func boolean(
        _ service: ServiceBuilder, _ type: CharacteristicType, _ entry: Entry, get: String?, set: String? = nil, property: String,
        initial: Bool = false, autoOff: Bool = false, reset: Duration? = nil, onChange: ((Bool) -> Void)? = nil
    ) -> Characteristic {
        let characteristic = service.add(type)
        if initial { characteristic.value = Self.hap(true, for: characteristic) }
        let config = entry.config
        let booleans = Booleans(config)
        let offAfter = autoOff ? config.milliseconds("turnOffAfterms") : nil
        func turnedOn(_ on: Bool) {
            guard on else { return }
            if let offAfter, let set, config.has(set) {
                after("off-\(property)-\(ObjectIdentifier(characteristic))", offAfter) { [weak characteristic] in
                    guard let characteristic else { return }
                    characteristic.value = Self.hap(false, for: characteristic)
                    self.publish(config, set, property: property, booleans.encode(false))
                    onChange?(false)
                }
            }
        }
        bind(
            characteristic, config, .bool(booleans), get: get, set: set, property: property, online: entry.online,
            received: { [weak characteristic] value, changed in
                let on = value.boolValue == true
                if changed { onChange?(on); turnedOn(on) }
                if on, let reset, let characteristic {
                    self.after("reset-\(property)-\(ObjectIdentifier(characteristic))", reset) { [weak characteristic] in
                        guard let characteristic else { return }
                        let wasOn = characteristic.value.boolValue == true
                        characteristic.value = Self.hap(false, for: characteristic)
                        if wasOn { onChange?(false) }
                    }
                }
            },
            wrote: { value in
                let on = value.boolValue == true
                onChange?(on)
                turnedOn(on)
            })
        return characteristic
    }

    /// An integer characteristic, its range from the given keys when they are integers.
    @discardableResult
    func integer(
        _ service: ServiceBuilder, _ type: CharacteristicType, _ entry: Entry, get: String?, set: String? = nil, property: String,
        initial: Int? = nil, minimum: Int? = nil, maximum: Int? = nil, onChange: ((Int) -> Void)? = nil
    ) -> Characteristic {
        let characteristic = service.add(type.with(minValue: minimum.map(Double.init), maxValue: maximum.map(Double.init)))
        if let initial { characteristic.value = .int(initial) }
        bind(
            characteristic, entry.config, .int, get: get, set: set, property: property, online: entry.online,
            received: { value, changed in if changed, let number = value.intValue { onChange?(number) } },
            wrote: { value in if let number = value.intValue { onChange?(number) } })
        return characteristic
    }

    /// A float characteristic.
    @discardableResult
    func float(
        _ service: ServiceBuilder, _ type: CharacteristicType, _ entry: Entry, get: String?, set: String? = nil, property: String,
        initial: Double? = nil, minimum: Double? = nil, maximum: Double? = nil, onReceive: ((Double) -> Void)? = nil
    ) -> Characteristic {
        let characteristic = service.add(type.with(minValue: minimum, maxValue: maximum))
        if let initial { characteristic.value = .double(initial) }
        bind(
            characteristic, entry.config, .float, get: get, set: set, property: property, online: entry.online,
            received: { value, _ in if let number = value.doubleValue { onReceive?(number) } })
        return characteristic
    }

    /// An enumeration (section 6.10), with `restrict…` as its valid values.
    @discardableResult
    func enumerated(
        _ service: ServiceBuilder, _ type: CharacteristicType, _ entry: Entry, keys: [String], defaults: [String], get: String?, set: String? = nil,
        property: String, initial: Int? = nil, restrict: String? = nil, eventOnly: Bool = false, onChange: ((Int) -> Void)? = nil
    ) -> Characteristic {
        var characteristicType = type
        if let restrict, let allowed = entry.config[restrict]?.arrayValue?.compactMap(\.doubleValue).map({ Int($0) }), !allowed.isEmpty {
            characteristicType = type.with(validValues: allowed)
        }
        let characteristic = service.add(characteristicType)
        if let initial { characteristic.value = .int(initial) }
        let enumeration = Enumeration(entry.config, keys: keys, default: defaults)
        bind(
            characteristic, entry.config, .enumeration(enumeration), get: get, set: set, property: property, online: entry.online, eventOnly: eventOnly,
            received: { value, changed in if changed, let index = value.intValue { onChange?(index) } },
            wrote: { value in if let index = value.intValue { onChange?(index) } })
        return characteristic
    }

    /// The optional sensor status set ("+status").
    func status(_ service: ServiceBuilder, _ entry: Entry) {
        let config = entry.config
        if config.has("getStatusActive") { boolean(service, .statusActive, entry, get: "getStatusActive", property: "statusActive", initial: true) }
        if config.has("getStatusFault") { boolean(service, .statusFault, entry, get: "getStatusFault", property: "statusFault") }
        if config.has("getStatusTampered") { boolean(service, .statusTampered, entry, get: "getStatusTampered", property: "statusTampered") }
        if config.has("getStatusLowBattery") { boolean(service, .statusLowBattery, entry, get: "getStatusLowBattery", property: "statusLowBattery") }
    }

    /// Active, with `turnOffAfterms`.
    @discardableResult
    func active(_ service: ServiceBuilder, _ entry: Entry, get: String = "getActive", set: String = "setActive", property: String = "active", onChange: ((Bool) -> Void)? = nil) -> Characteristic {
        boolean(service, .active, entry, get: get, set: set, property: property, autoOff: true, onChange: onChange)
    }

    /// The common characteristics of the primary service (section 5.34), then the service.
    func primary(
        _ service: ServiceBuilder, _ entry: Entry, name: String? = nil, subtype: String?? = nil, isPrimary: Bool = false, linked: [Service] = []
    ) -> Service {
        let config = entry.config
        if config.has("getName") {
            let characteristic = service.add(.name, .string(config.name))
            bind(characteristic, config, .string, get: "getName", set: nil, property: "name", online: entry.online)
        }
        if config.has("getOnline") {
            let booleans = Booleans(config)
            let onlineValue = config.values["onlineValue"].map { $0 == .null ? JSONValue.string("null") : $0 } ?? booleans.on
            let offlineValue = config.values["offlineValue"].map { $0 == .null ? JSONValue.string("null") : $0 } ?? booleans.off ?? .string("null")
            let online = entry.online
            subscribe(config, "getOnline", property: "online") { message in
                if JS.matches(message, onlineValue) {
                    if !online.isOnline { self.logger.info("\(config.name) is online") }
                    online.isOnline = true
                } else if JS.matches(message, offlineValue) {
                    if online.isOnline { self.logger.info("\(config.name) is offline") }
                    online.isOnline = false
                }
            }
        }
        if let override = config.string("nameOverride"), !override.isEmpty { service.add(.configuredName, .string(override)) }
        entry.primaryHasLowBattery = service[.statusLowBattery] != nil
        return service.build(name: name ?? config.name, subtype: subtype ?? entry.subtype, primary: isPrimary, linked: linked)
    }

    /// The Battery service (section 5.35) for a type other than `battery`, when its topics ask for one.
    func battery(_ entry: Entry, standalone: Bool) -> Service? {
        let config = entry.config
        let needed = config.hasAny("getBatteryLevel", "getChargingState") || (config.has("getStatusLowBattery") && !entry.primaryHasLowBattery)
        guard standalone || needed else { return nil }
        let service = ServiceBuilder(.battery)
        if config.has("getBatteryLevel") { integer(service, .batteryLevel, entry, get: "getBatteryLevel", property: "batteryLevel") }
        if config.has("getChargingState") {
            enumerated(service, .chargingState, entry, keys: ["chargingStateValues"], defaults: ["NOT_CHARGING", "CHARGING", "NOT_CHARGEABLE"], get: "getChargingState", property: "chargingState", initial: 0)
        }
        if config.has("getStatusLowBattery") { boolean(service, .statusLowBattery, entry, get: "getStatusLowBattery", property: "statusLowBattery") }
        if standalone { return primary(service, entry, subtype: .some(nil)) }
        return service.build(name: "\(config.name)-battery", subtype: nil)
    }

    /// CurrentTemperature with its range (section 5.29).
    @discardableResult
    func currentTemperature(_ service: ServiceBuilder, _ entry: Entry, onReceive: ((Double) -> Void)? = nil) -> Characteristic {
        let config = entry.config
        let given = config.number("minTemperature") != nil || config.number("maxTemperature") != nil
        return float(
            service, .currentTemperature, entry, get: "getCurrentTemperature", property: "currentTemperature",
            minimum: given ? config.number("minTemperature") : -100, maximum: given ? config.number("maxTemperature") : nil, onReceive: onReceive)
    }

    func temperatureDisplayUnits(_ service: ServiceBuilder, _ entry: Entry) {
        enumerated(
            service, .temperatureDisplayUnits, entry, keys: ["temperatureDisplayUnitsValues"], defaults: ["CELSIUS", "FAHRENHEIT"],
            get: "getTemperatureDisplayUnits", set: "setTemperatureDisplayUnits", property: "temperatureDisplayUnits", initial: 0)
    }

    func lockPhysicalControls(_ service: ServiceBuilder, _ entry: Entry) {
        guard entry.config.hasAny("getLockPhysicalControls", "setLockPhysicalControls") else { return }
        enumerated(
            service, .lockPhysicalControls, entry, keys: ["lockPhysicalControlsValues"], defaults: ["DISABLED", "ENABLED"],
            get: "getLockPhysicalControls", set: "setLockPhysicalControls", property: "lockPhysicalControls", initial: 0)
    }

    func swingMode(_ service: ServiceBuilder, _ entry: Entry) {
        guard entry.config.hasAny("getSwingMode", "setSwingMode") else { return }
        enumerated(service, .swingMode, entry, keys: ["swingModeValues"], defaults: ["DISABLED", "ENABLED"], get: "getSwingMode", set: "setSwingMode", property: "swingMode", initial: 0)
    }

    func rotationSpeed(_ service: ServiceBuilder, _ entry: Entry) {
        guard entry.config.hasAny("getRotationSpeed", "setRotationSpeed") else { return }
        integer(
            service, .rotationSpeed, entry, get: "getRotationSpeed", set: "setRotationSpeed", property: "rotationSpeed",
            minimum: entry.config.integer("minRotationSpeed"), maximum: entry.config.integer("maxRotationSpeed"))
    }

    func rotationDirection(_ service: ServiceBuilder, _ entry: Entry) {
        guard entry.config.hasAny("getRotationDirection", "setRotationDirection") else { return }
        integer(service, .rotationDirection, entry, get: "getRotationDirection", set: "setRotationDirection", property: "rotationDirection")
    }

    func lockStates(_ service: ServiceBuilder, _ entry: Entry) {
        let values = entry.config["lockValues"]?.arrayValue
        if entry.config.has("setLockTargetState") {
            let characteristic = service.add(.lockTargetState)
            let enumeration = Enumeration(values: values.map { Array($0.prefix(2)) } ?? [.string("U"), .string("S")])
            bind(characteristic, entry.config, .enumeration(enumeration), get: "getLockTargetState", set: "setLockTargetState", property: "lockTargetState", online: entry.online)
        }
        if entry.config.has("getLockCurrentState") {
            let characteristic = service.add(.lockCurrentState)
            let enumeration = Enumeration(values: values ?? ["U", "S", "J", "?"].map(JSONValue.string))
            bind(characteristic, entry.config, .enumeration(enumeration), get: "getLockCurrentState", set: nil, property: "lockCurrentState", online: entry.online)
        }
    }
}
