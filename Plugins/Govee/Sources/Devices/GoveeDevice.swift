import Foundation
import HomeswiftPlugin
import Homeswift
import Logging

/// Where the device handlers run: one serial executor for all of them, as the Homebridge plugin's handlers
/// shared Node's event loop. Between two awaits a handler's caches are its own.
@globalActor
actor GoveeActor {
    static let shared = GoveeActor()
}

/// What a handler knows about its device.
struct DeviceInfo: Sendable, Equatable {
    /// Govee's id, colon separated, upper case.
    var id: String
    var model: String
    var name: String
    var goodsType: Int?
    var firmware: String?
}

/// Which transports the device has, and which the plugin uses.
struct TransportFlags: Sendable, Equatable {
    var hasAWS = false
    var useAWS = false
    var hasBLE = false
    var useBLE = false
    var hasLAN = false
    var useLAN = false

    func label(_ has: Bool, _ use: Bool) -> String { has ? (use ? "enabled" : "disabled") : "unsupported" }
}

/// Everything a handler gets from the plugin.
struct DeviceEnvironment: Sendable {
    var info: DeviceInfo
    var settings: DeviceSettings
    var platform: GoveePlugin.Configuration
    var transports: TransportFlags
    /// Sends a command to this device over the first transport that takes it.
    var send: @Sendable (DeviceCommand) async throws -> Void
    var logger: Logger
    var deviceLogging: Bool
    var debugLogging: Bool
    /// The accessory the cache restored, whose values the new one starts from.
    var cached: Accessory?
    /// Small per-device state kept across launches (the Homebridge accessory's `context`).
    var store: DeviceStore
    /// Where Eve histories are kept; nil: none.
    var historyDirectory: URL?
    var adaptiveLighting: AdaptiveLightingFactory?
    /// When a plug shown as a heater or cooler first reads its source sensor.
    var temperatureSourceFirstRead: Duration = .seconds(5)
    /// How long a light waits after an On or Off write before sending the latest one.
    var stateDelay: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(400)) }
}

/// Adds Adaptive Lighting to a lightbulb that has Brightness and Color Temperature, before the accessory is
/// published. `customTemperatureAdjustment` shifts the curve, in mired.
typealias AdaptiveLightingFactory = @Sendable (_ lightbulb: Service, _ customTemperatureAdjustment: Int, _ deviceID: String) -> AdaptiveLightingController

/// A device's lines, `[name] message.`, from any task: `info` and `warn` quiet with `disableDeviceLogging`,
/// `debug` and `debugWarn` raised to info and warning with `debug`.
struct DeviceLog: Sendable {
    let logger: Logger
    let name: String
    let deviceLogging: Bool
    let debugLogging: Bool

    func info(_ message: @autoclosure () -> String) {
        guard deviceLogging else { return }
        logger.info("[\(name)] \(message()).")
    }

    func warn(_ message: @autoclosure () -> String) {
        guard deviceLogging else { return }
        logger.warning("[\(name)] \(message()).")
    }

    func debug(_ message: @autoclosure () -> String) {
        if debugLogging { logger.info("[\(name)] \(message()).") } else { logger.debug("[\(name)] \(message()).") }
    }

    func debugWarn(_ message: @autoclosure () -> String) {
        if debugLogging { logger.warning("[\(name)] \(message()).") } else { logger.debug("[\(name)] \(message()).") }
    }
}

/// A handler for one kind of device (`GoveeDeviceBase`): it builds the accessory's services, turns HomeKit's
/// writes into commands and the device's reports into characteristic values. Subclasses override
/// `configure()` and `externalUpdate(_:)`.
@GoveeActor
class GoveeDevice {
    let environment: DeviceEnvironment
    var info: DeviceInfo { environment.info }
    var settings: DeviceSettings { environment.settings }
    /// Updated when LAN discovery finds the device after it started.
    private(set) var transports: TransportFlags

    /// The services of the accessory, primary first.
    private(set) var services: [Service] = []
    /// The Eve history, when the handler keeps one.
    private(set) var history: EveHistory?
    var cacheState = "off"
    var initialised = false
    nonisolated let deviceLog: DeviceLog
    private let timers = TaskBag()
    /// Set while reports are ignored after a command (`holdReports`).
    private var reportHold: UUID?

    init(environment: DeviceEnvironment) {
        self.environment = environment
        transports = environment.transports
        deviceLog = DeviceLog(logger: environment.logger, name: environment.info.name, deviceLogging: environment.deviceLogging, debugLogging: environment.debugLogging)
    }

    func setTransports(_ flags: TransportFlags) { transports = flags }

    /// The HomeKit category of the accessory.
    var category: AccessoryCategory { .other }

    /// Builds the services and wires them; `init()` of the Homebridge plugin.
    func configure() {}

    /// A status from AWS, LAN, BLE or HTTP.
    func externalUpdate(_ update: DeviceUpdate) async {}

    /// Cancels the timers, at shutdown or when the device leaves; none starts afterwards.
    func destroy() {
        timers.cancelAll()
    }

    // MARK: Services

    /// Adds a service: `characteristics` are the optional ones to add, or required ones with other bounds;
    /// values come from the cached accessory when it had the same service.
    @discardableResult
    func addService(
        _ type: ServiceType, name: String? = nil, subtype: String? = nil, characteristics: [CharacteristicType] = [], extra: [Characteristic] = [],
        primary: Bool = false
    ) -> Service {
        let service = Service(type, name: name ?? info.name, subtype: subtype, optional: characteristics, extra: extra, isPrimary: primary)
        if let old = environment.cached?.services.first(where: { $0.type.uuid == service.type.uuid && $0.subtype == service.subtype }) {
            service.takeValues(from: old)
        }
        services.append(service)
        return service
    }

    /// Starts the Eve history of this accessory (fakegato's `new eveService(kind, accessory)`).
    func startHistory(_ kind: EveHistory.Kind) {
        guard let directory = environment.historyDirectory else { return }
        let file = directory.appendingPathComponent("\(info.id.replacingOccurrences(of: ":", with: ""))_persist.json")
        history = EveHistory(kind, accessoryName: info.name, storageURL: file)
    }

    /// fakegato's `custom` history: the temperature and humidity found on the accessory's services.
    func startCustomHistory() { startHistory(.custom(EveHistory.fields(of: services))) }

    func addHistory(temp: Double? = nil, humidity: Double? = nil, power: Double? = nil, status: Double? = nil) {
        history?.add(EveHistory.Entry(temp: temp, humidity: humidity, power: power, status: status))
    }

    // MARK: Values

    /// Sets a characteristic as HAP-NodeJS's `updateValue` does: numbers clamped to the bounds and rounded
    /// to the step.
    func update(_ characteristic: Characteristic?, _ value: HAPValue) {
        guard let characteristic else { return }
        characteristic.value = Self.fitted(value, to: characteristic.type)
    }

    func update(_ characteristic: Characteristic?, _ value: Bool) { update(characteristic, .bool(value)) }
    func update(_ characteristic: Characteristic?, _ value: Int) { update(characteristic, .int(value)) }
    func update(_ characteristic: Characteristic?, _ value: Double) { update(characteristic, .double(value)) }

    static func fitted(_ value: HAPValue, to type: CharacteristicType) -> HAPValue {
        guard case .bool = value else {
            switch type.format {
            case .uint8, .uint16, .uint32, .uint64, .int, .float:
                guard var number = value.doubleValue, number.isFinite else { return value }
                if let minimum = type.minValue { number = max(number, minimum) }
                if let maximum = type.maxValue { number = min(number, maximum) }
                if let step = type.minStep, step > 0 {
                    let base = type.minValue ?? 0
                    number = base + Govee.round((number - base) / step) * step
                    number = (number * 1e6).rounded() / 1e6
                }
                return type.format == .float ? .double(number) : .int(Int(saturating: number.rounded()) ?? 0)
            default:
                return value
            }
        }
        return value
    }

    func int(_ characteristic: Characteristic?) -> Int { characteristic?.value.intValue ?? 0 }
    func double(_ characteristic: Characteristic?) -> Double { characteristic?.value.doubleValue ?? 0 }
    func bool(_ characteristic: Characteristic?) -> Bool { characteristic?.value.boolValue ?? false }

    // MARK: Commands

    func send(_ command: DeviceCommand) async throws {
        try await environment.send(command)
    }

    /// A command HomeKit asked for failed: log it, put the characteristic back after a moment, and tell
    /// HomeKit the device did not answer (`handleUpdateError`).
    func failed(_ error: any Error, _ characteristic: Characteristic?, revert: HAPValue, after delay: Duration = .seconds(2)) -> HAPStatusError {
        logWarn("\(Lang.devNotUpdated) \(error)")
        if let characteristic { timers.add(characteristic.revert(to: Self.fitted(revert, to: characteristic.type), after: delay)) }
        return HAPStatusError(.serviceCommunicationFailure)
    }

    /// An on/off write from HomeKit (`internal…Update`): nothing when `current` already is the new state; else
    /// `command` (given "on" or "off") goes out and `label` is logged. Answers the new state for the caller to
    /// keep, nil when nothing was sent; a failure puts `characteristic` back to `revert` (read then).
    func toggle(
        _ on: Bool, current: String, label: String, _ characteristic: Characteristic?, revert: @autoclosure () -> HAPValue,
        _ command: (String) -> DeviceCommand
    ) async throws -> String? {
        let newValue = on ? "on" : "off"
        guard current != newValue else { return nil }
        do {
            try await send(command(newValue))
            log("\(label) [\(newValue)]")
            return newValue
        } catch {
            throw failed(error, characteristic, revert: revert())
        }
    }

    // MARK: Timers

    /// Runs `work` after `delay` unless the device is destroyed first (`schedule()`). Answers the timer, to
    /// cancel it; nil once the device is destroyed.
    @discardableResult
    func schedule(after delay: Duration, _ work: @escaping @Sendable @GoveeActor () -> Void) -> Task<Void, Never>? {
        timers.add {
            do { try await Task.sleep(for: delay) } catch { return }
            await work()
        }
    }

    /// Ignores the device's reports for `duration` after a command, while it catches up; a later hold replaces it.
    func holdReports(for duration: Duration = .seconds(60)) {
        let key = UUID()
        reportHold = key
        schedule(after: duration) { [weak self] in
            if self?.reportHold == key { self?.reportHold = nil }
        }
    }

    var isHoldingReports: Bool { reportHold != nil }

    // MARK: Logging

    /// A device line, `[name] message.`; quiet with `disableDeviceLogging`.
    func log(_ message: String) { deviceLog.info(message) }
    func logWarn(_ message: String) { deviceLog.warn(message) }
    func logDebug(_ message: String) { deviceLog.debug(message) }
    func logDebugWarn(_ message: String) { deviceLog.debugWarn(message) }

    /// Keeps a sensor's temperature for the plugs that follow it, written at once as the Homebridge plugin's
    /// `updateCache` wrote `<id>_temp`.
    func storeTemperature(_ value: Double) {
        environment.store.setTemperature(value, of: info.id)
        do {
            try environment.store.flush()
        } catch {
            logWarn("\(Lang.storageWriteErr) \(error)")
        }
    }

    /// The options the device starts with, like the Homebridge plugin's `devInitOpts` line.
    func logInitOptions(_ options: [(String, String)]) {
        let text = "{" + options.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        environment.logger.info("[\(info.name)] \(Lang.devInitOpts) \(text).")
    }

    func newScene(_ command: String, _ hex: String) {
        logDebugWarn("\(Lang.newScene): [\(command)] [\(hex)]")
    }

    var isBLEOnly: Bool { !transports.useAWS && !transports.useLAN }
}

/// Values a device keeps between launches, by device id: what the Homebridge plugin kept in the accessory's
/// context and in its `govee_cache` (a sensor's last temperature, for heaters that use it). One JSON file,
/// owner-only; a burst of changes is written once.
typealias DeviceStore = PersistedDictionary<[String: JSONValue]>

extension PersistedDictionary<[String: JSONValue]> {
    func value(_ device: String, _ key: String) -> JSONValue? { self[device]?[key] }

    func set(_ device: String, _ key: String, _ value: JSONValue?) {
        update(device) { entry in
            guard entry?[key] != value else { return }
            var values = entry ?? [:]
            values[key] = value
            entry = values
        }
    }

    /// The last temperature a sensor reported, °C (`<id>_temp` of the Homebridge plugin).
    func temperature(of device: String) -> Double? { value(device, "temp")?.doubleValue }
    func setTemperature(_ value: Double, of device: String) { set(device, "temp", .number(value)) }
}
