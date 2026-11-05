import Foundation
import Homeswift
import HomeswiftPlugin

/// A charger's own Plugin Accessory Settings (config.schema.json's `accessorySchema`; docs/clean-room/V2CTrydan.md, 2).
struct ChargerSettings: Decodable, Sendable, Equatable {
    /// How the Status page's Energy section counts `HousePower`.
    enum HouseRole: String, Decodable, Sendable {
        case none, home, grid
    }

    var host: String?
    var exposeCurrent: Bool?
    var exposeLock: Bool?
    var exposeSensors: Bool?
    var exposeDynamic: Bool?
    var exposeLeds: Bool?
    var houseEnergyRole: HouseRole?
    var solarEnergy: Bool?
    var exposeModes: Bool?
    /// The wiring (`ChargeMode`): `monophasic`, `threephase` or `mixed`; nil leaves the charger's.
    var chargeMode: String?
    /// Installation limits (3.4): the lowest and highest current offered, 6 to 32 A, and the installation's voltage, 1 to
    /// 500 V; nil leaves the charger's.
    var minIntensity: Int?
    var maxIntensity: Int?
    var voltageInstallation: Int?

    var showsCurrent: Bool { exposeCurrent ?? true }
    var showsLock: Bool { exposeLock ?? true }
    var showsSensors: Bool { exposeSensors ?? true }
    var showsDynamic: Bool { exposeDynamic ?? false }
    var showsLeds: Bool { exposeLeds ?? false }
    var showsModes: Bool { exposeModes ?? false }

    /// The installation keywords these settings ask the charger for, with their values.
    var installation: [(keyword: String, value: Int)] {
        var writes: [(keyword: String, value: Int)] = []
        if let wiring = chargeMode.flatMap(ChargeWiring.init(rawValue:)) { writes.append(("ChargeMode", wiring.value)) }
        if let minIntensity { writes.append(("MinIntensity", minIntensity)) }
        if let maxIntensity { writes.append(("MaxIntensity", maxIntensity)) }
        if let voltageInstallation { writes.append(("VoltageInstallation", voltageInstallation)) }
        return writes
    }
}

/// What an accessory's services depend on besides the settings: the installation's maximum current (the Rotation
/// Speed's maximum) and the LEDs the firmware reported. A change of it rebuilds the accessory: its props change, its
/// iids do not.
struct TrydanShape: Sendable, Equatable {
    var maxCurrent = 32
    var lightLED = false
    var logoLED = false

    /// The shape once `report` is known: LEDs once reported stay.
    func updated(with report: TrydanReport) -> TrydanShape {
        TrydanShape(maxCurrent: report.intensityRange.upperBound, lightLED: lightLED || report.lightLED != nil, logoLED: logoLED || report.logoLED != nil)
    }
}

// Out of the struct's body, so its memberwise initializer stays.
extension TrydanShape {
    /// The shape an accessory restored from the cache was built with, so a restart does not rebuild it.
    init(cached: Accessory) {
        if let speed = cached.service(.fanv2, subtype: TrydanServices.Subtype.current)?[.rotationSpeed]?.type,
           let high = speed.maxValue.flatMap({ Int(saturating: $0) }), (6...32).contains(high) {
            maxCurrent = high
        }
        lightLED = cached.service(.lightbulb, subtype: TrydanServices.Subtype.lightLED) != nil
        logoLED = cached.service(.lightbulb, subtype: TrydanServices.Subtype.logoLED) != nil
    }
}

/// What a HomeKit write asks of the charger.
enum TrydanCommand: Sendable, Equatable {
    /// Outlet On or Fan Active: `Paused` 0 charges, 1 pauses.
    case allowCharging(Bool)
    /// Rotation Speed in amperes; 0 pauses.
    case current(Double)
    case lock(Bool)
    case timer(Bool)
    case dynamic(Bool)
    case pauseDynamic(Bool)
    case lightLED(on: Bool)
    case lightLEDBrightness(Int)
    case logoLED(on: Bool)
    /// A mode switch: On sets `DynamicPowerMode`.
    case mode(DynamicPowerMode, on: Bool)
}

/// A charger's accessory and the services the plugin sets (docs/clean-room/V2CTrydan.md, 4.2). The subtypes stay as
/// they are: they key the iids.
struct TrydanServices: Sendable {
    enum Subtype {
        static let charger = "charger"
        static let current = "current"
        static let lock = "lock"
        static let plug = "plug"
        static let timer = "timer"
        static let dynamic = "dynamic"
        static let pauseDynamic = "pauseDynamic"
        static let lightLED = "lightLED"
        static let logoLED = "logoLED"
        static func mode(_ mode: DynamicPowerMode) -> String { "mode.\(mode.name)" }
    }

    let accessory: Accessory
    let outlet: Service
    let fan: Service?
    let lock: Service?
    let plug: Service?
    let timer: Service?
    let dynamic: Service?
    let pauseDynamic: Service?
    let lightLED: Service?
    let logoLED: Service?
    /// The mode switches, by `DynamicPowerMode`.
    let modes: [DynamicPowerMode: Service]
    let shape: TrydanShape

    static let manufacturer = "V2C"
    static let model = "Trydan"

    static func make(
        id: String, deviceID: String, name: String, firmware: String?, settings: ChargerSettings, shape: TrydanShape, cached: Accessory?,
        write: @escaping @Sendable (TrydanCommand) async throws -> Void
    ) -> TrydanServices {
        let outlet = Service(
            .outlet, name: name, subtype: Subtype.charger, optional: [.outletInUse],
            extra: [
                Characteristic(EveCharacteristic.currentConsumption, value: .int(0)), Characteristic(EveCharacteristic.totalConsumption, value: .double(0)),
                Characteristic(EveCharacteristic.voltage, value: .double(0)), Characteristic(EveCharacteristic.electricCurrent, value: .double(0)),
                Characteristic(TrydanCharacteristic.sessionEnergy, value: .double(0)),
            ],
            isPrimary: true)
        var services = [outlet]
        var fan: Service?, lock: Service?, plug: Service?, timer: Service?, dynamic: Service?, pauseDynamic: Service?, lightLED: Service?, logoLED: Service?
        if settings.showsCurrent {
            // The Rotation Speed is in amperes, up to the installation's maximum. Its lowest value is 0 rather than the
            // minimum current, so the Home app's slider at the bottom (0) still pauses; 1 to the minimum offer the minimum.
            let speed = CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: Double(shape.maxCurrent), minStep: 1)
            let service = Service(.fanv2, name: "Charge current", subtype: Subtype.current, optional: [speed])
            service.characteristic(.active).onWrite { value in try await write(.allowCharging((value.intValue ?? 0) == 1)) }
            service.characteristic(.rotationSpeed).onWrite(changesOnly: true) { value in try await write(.current(value.doubleValue ?? 0)) }
            fan = service
            services.append(service)
        }
        if settings.showsLock {
            let service = Service(.lockMechanism, name: "Charger lock", subtype: Subtype.lock)
            // Lock Target State is a security control already: the bridge's own surfaces ask before writing it.
            service.characteristic(.lockTargetState).securityControl().onWrite { value in try await write(.lock((value.intValue ?? 0) == 1)) }
            lock = service
            services.append(service)
        }
        if settings.showsSensors {
            let service = Service(.contactSensor, name: "Car connected", subtype: Subtype.plug, optional: [.statusFault])
            plug = service
            services.append(service)
        }
        if settings.showsDynamic {
            let timerService = Service(.switch, name: "Charge timer", subtype: Subtype.timer)
            timerService.characteristic(.on).onWrite { value in try await write(.timer(value.boolValue ?? false)) }
            let dynamicService = Service(.switch, name: "Dynamic power", subtype: Subtype.dynamic)
            dynamicService.characteristic(.on).onWrite { value in try await write(.dynamic(value.boolValue ?? false)) }
            let pauseService = Service(.switch, name: "Pause dynamic", subtype: Subtype.pauseDynamic)
            pauseService.characteristic(.on).onWrite { value in try await write(.pauseDynamic(value.boolValue ?? false)) }
            timer = timerService
            dynamic = dynamicService
            pauseDynamic = pauseService
            services += [timerService, dynamicService, pauseService]
        }
        if settings.showsLeds, shape.lightLED {
            let service = Service(.lightbulb, name: "Light LED", subtype: Subtype.lightLED, optional: [.brightness])
            service.characteristic(.on).onWrite { value in try await write(.lightLED(on: value.boolValue ?? false)) }
            service.characteristic(.brightness).onWrite(changesOnly: true) { value in
                try await write(.lightLEDBrightness(Int(saturating: value.doubleValue ?? 0, in: 0...100) ?? 0))
            }
            lightLED = service
            services.append(service)
        }
        if settings.showsLeds, shape.logoLED {
            let service = Service(.lightbulb, name: "Logo LED", subtype: Subtype.logoLED)
            service.characteristic(.on).onWrite { value in try await write(.logoLED(on: value.boolValue ?? false)) }
            logoLED = service
            services.append(service)
        }
        var modes: [DynamicPowerMode: Service] = [:]
        if settings.showsModes {
            // One switch per mode, as a radio: the charger is in one mode at a time.
            for mode in DynamicPowerMode.switchable {
                let service = Service(.switch, name: mode.switchName, subtype: Subtype.mode(mode), optional: [.configuredName])
                service.characteristic(.on).onWrite { value in try await write(.mode(mode, on: value.boolValue ?? false)) }
                modes[mode] = service
                services.append(service)
            }
        }
        outlet.characteristic(.on).onWrite { value in try await write(.allowCharging(value.boolValue ?? false)) }
        let accessory = Accessory(
            id: id, name: name, manufacturer: manufacturer, model: model, serialNumber: deviceID,
            firmwareRevision: TrydanIdentity.firmwareRevision(firmware), category: .outlet, services: services)
        if let cached { accessory.takeValues(from: cached) }
        return TrydanServices(
            accessory: accessory, outlet: outlet, fan: fan, lock: lock, plug: plug, timer: timer, dynamic: dynamic, pauseDynamic: pauseDynamic,
            lightLED: lightLED, logoLED: logoLED, modes: modes, shape: shape)
    }

    /// Sets every characteristic from a report; HomeKit hears of those that changed.
    func show(_ report: TrydanReport, lifetimeEnergy: Double? = nil) {
        let allowed = report.paused == 0
        outlet.characteristic(.on).value = .bool(allowed)
        outlet.characteristic(.outletInUse).value = .bool(report.isCharging)
        outlet.characteristic(EveCharacteristic.currentConsumption).value = .int(Int(saturating: report.chargePower.rounded(), in: 0...100_000) ?? 0)
        // Eve's Total Consumption only grows: the lifetime total, the session's energy beside it.
        if let lifetimeEnergy { outlet.characteristic(EveCharacteristic.totalConsumption).value = .double(max(0, (lifetimeEnergy * 100).rounded() / 100)) }
        outlet.characteristic(TrydanCharacteristic.sessionEnergy).value = .double(max(0, (report.chargeEnergy * 100).rounded() / 100))
        if let voltage = report.voltage { outlet.characteristic(EveCharacteristic.voltage).value = .double(voltage.rounded()) }
        if let current = report.current { outlet.characteristic(EveCharacteristic.electricCurrent).value = .double((current * 10).rounded() / 10) }
        if let fan {
            fan.characteristic(.active).value = .int(allowed ? 1 : 0)
            let speed = min(max(report.intensity, 0), shape.maxCurrent)
            fan.characteristic(.rotationSpeed).value = .double(Double(speed))
        }
        if let lock {
            let secured = report.locked == 1 ? 1 : 0
            lock.characteristic(.lockCurrentState).value = .int(secured)
            lock.characteristic(.lockTargetState).value = .int(secured)
        }
        if let plug {
            plug.characteristic(.contactSensorState).value = .int(report.isConnected ? 0 : 1)
            plug.characteristic(.statusFault).value = .int(report.isFault ? 1 : 0)
        }
        timer?.characteristic(.on).value = .bool(report.timer == 1)
        dynamic?.characteristic(.on).value = .bool(report.dynamic == 1)
        pauseDynamic?.characteristic(.on).value = .bool(report.pauseDynamic == 1)
        if let lightLED, let level = report.lightLED {
            lightLED.characteristic(.on).value = .bool(level > 0)
            if level > 0 { lightLED.characteristic(.brightness).value = .int(min(level, 100)) }
        }
        if let logoLED, let level = report.logoLED { logoLED.characteristic(.on).value = .bool(level > 0) }
        for (mode, service) in modes { service.characteristic(.on).value = .bool(report.dynamicPowerMode == mode.rawValue) }
        if let firmware = report.firmwareVersion {
            accessory.information.characteristic(.firmwareRevision).value = .string(TrydanIdentity.firmwareRevision(firmware))
        }
    }
}
