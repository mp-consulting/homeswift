import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The optional services of a vehicle (GLOSSARY.md, "Part"), offered only when the model has the endpoint behind them.
enum VehiclePart: String, CaseIterable, Sendable {
    case climate = "Climate"
    case charging = "Charging"
    case pluggedIn = "PluggedIn"
    case horn = "Horn"
    case lights = "Lights"
    case interiorTemperature = "InteriorTemperature"
    case exteriorTemperature = "ExteriorTemperature"
    case doors = "Doors"

    var name: String {
        switch self {
        case .climate: "Climate"
        case .charging: "Charging"
        case .pluggedIn: "Plugged in"
        case .horn: "Horn"
        case .lights: "Lights"
        case .interiorTemperature: "Interior temperature"
        case .exteriorTemperature: "Exterior temperature"
        case .doors: "Doors"
        }
    }

    /// The horn sounds in the street: off unless a person includes it.
    var includedByDefault: Bool { self != .horn }

    /// The Part as Setup lists it, `included` from the Accessory Settings.
    func devicePart(included: Bool?) -> DevicePart {
        DevicePart(rawValue, name: name, icon: icon, included: included ?? includedByDefault)
    }

    var icon: String? {
        switch self {
        case .climate: "fan"
        case .charging: "battery"
        case .pluggedIn: "power"
        case .horn: "bell"
        case .lights: "bulb"
        case .interiorTemperature, .exteriorTemperature: "thermo"
        case .doors: "door"
        }
    }
}

/// How a read of an endpoint went.
enum ReadOutcome: Sendable, Equatable {
    case read
    /// The car does not have it: dropped for good (4.7, 6.3).
    case dropped
    /// Not sent: the hour's budget is spent or the cool-down runs.
    case skipped
    case failed(String)
    /// The account refused its credentials.
    case refused(RenaultError)
}

/// One vehicle: what the model resolves, the last data of each endpoint, its services and their writes. Handlers capture
/// it, not the plugin. Nothing here reaches the network on a HomeKit read.
actor RenaultVehicle {
    struct Options: Sendable {
        var climateTemperature: Double = 21
        var parts: [String: Bool] = [:]
    }

    let info: VehicleInfo
    let accountID: String
    private let session: RenaultSession
    private let options: Options
    private let timing: RenaultTiming
    private let logger: Logger
    private let tasks: TaskBag
    /// Called when an endpoint is dropped, to remember it (6.3).
    private let onDrop: @Sendable (String, Endpoint) -> Void

    private(set) var dropped: Set<Endpoint>
    /// The endpoints that have answered at least once.
    private(set) var working: Set<Endpoint> = []
    private var warnedUndocumented: Set<Endpoint> = []
    private(set) var battery: BatteryStatus?
    private(set) var hvac: HvacStatus?
    private(set) var soc: SocLevels?
    private(set) var lock: LockStatus?
    private var seenInterior = false
    private var seenExterior = false
    /// The programs' activation flags before a charge start turned them off (4.6), in memory.
    private(set) var programsBeforeChargeStart: [Bool]?
    private(set) var lastSuccess: ContinuousClock.Instant?
    private let created = ContinuousClock.now

    private struct Pending { var value: Bool; var until: ContinuousClock.Instant }
    private var pendingClimate: Pending?
    private var pendingCharging: Pending?
    private var confirmations: [Endpoint: Task<Void, Never>] = [:]

    private(set) var accessory: Accessory?
    private var services: [String: Service] = [:]

    init(
        info: VehicleInfo, accountID: String, session: RenaultSession, options: Options, dropped: Set<Endpoint>, timing: RenaultTiming,
        logger: Logger, tasks: TaskBag, onDrop: @escaping @Sendable (String, Endpoint) -> Void
    ) {
        self.info = info
        self.accountID = accountID
        self.session = session
        self.options = options
        self.dropped = dropped
        self.timing = timing
        self.logger = logger
        self.tasks = tasks
        self.onDrop = onDrop
    }

    var logName: String { maskedVIN(info.vin) }

    // MARK: What the model has

    /// Where an endpoint goes for this car, nil when the model refuses it or the car did not have it.
    func resolve(_ endpoint: Endpoint) -> (path: String, mode: EndpointMode)? {
        guard !dropped.contains(endpoint) else { return nil }
        let (resolution, documented) = ModelEndpoints.resolve(endpoint, model: info.modelCode, vin: info.vin)
        guard case .supported(let path, let mode) = resolution else { return nil }
        if !documented, ModelEndpoints.isKnown(info.modelCode), !warnedUndocumented.contains(endpoint) {
            warnedUndocumented.insert(endpoint)
            logger.warning("\(endpoint.rawValue) is not documented for the model \(info.modelCode ?? "?"): using the default endpoint")
        }
        return (Kamereon.vehiclePath(accountID, path), mode)
    }

    func has(_ endpoint: Endpoint) -> Bool { resolve(endpoint) != nil }

    /// The parts this car can have.
    func availableParts() -> [VehiclePart] { Self.parts(for: info, dropped: dropped) }

    /// The parts a car of this model can have, from the table and the endpoints it did not have.
    static func parts(for info: VehicleInfo, dropped: Set<Endpoint>) -> [VehiclePart] {
        func has(_ endpoint: Endpoint) -> Bool {
            !dropped.contains(endpoint) && ModelEndpoints.resolve(endpoint, model: info.modelCode, vin: info.vin).resolution.isSupported
        }
        return VehiclePart.allCases.filter { part in
            switch part {
            case .climate: has(.hvacStatus) && has(.hvacStart)
            case .charging: info.usesElectricity && has(.batteryStatus) && has(.chargeStart)
            case .pluggedIn: info.usesElectricity && has(.batteryStatus)
            case .horn: has(.hornStart)
            case .lights: has(.lightsStart)
            case .interiorTemperature, .exteriorTemperature: has(.hvacStatus)
            case .doors: has(.lockStatus)
            }
        }
    }

    func isIncluded(_ part: VehiclePart) -> Bool { options.parts[part.rawValue] ?? part.includedByDefault }

    /// The endpoints read each round (6.1): only those something in HomeKit shows.
    func roundEndpoints() -> [Endpoint] {
        let parts = Set(availableParts().filter(isIncluded))
        var endpoints: [Endpoint] = []
        if info.usesElectricity, has(.batteryStatus) { endpoints.append(.batteryStatus) }
        if has(.hvacStatus), !parts.isDisjoint(with: [.climate, .interiorTemperature, .exteriorTemperature]) { endpoints.append(.hvacStatus) }
        if parts.contains(.doors) { endpoints.append(.lockStatus) }
        return endpoints
    }

    /// The endpoints read once an hour, with the vehicle list: the state-of-charge limits, which set the low battery level.
    func hourlyEndpoints() -> [Endpoint] {
        info.usesElectricity && has(.socLevels) ? [.socLevels] : []
    }

    // MARK: Reads

    @discardableResult
    func read(_ endpoint: Endpoint, _ priority: RequestBudget.Priority) async -> ReadOutcome {
        guard let (path, _) = resolve(endpoint) else { return .dropped }
        let label = endpoint.rawValue
        let plain = path.contains("/kcm/")
        do {
            let json = try await session.perform(priority) { session in
                try await session.send(priority, path: path, label: label)
            }
            apply(endpoint, Kamereon.attributes(json, plain: plain))
            working.insert(endpoint)
            lastSuccess = .now
            return .read
        } catch RenaultError.quota {
            return .skipped
        } catch RenaultError.kamereon(let error) where error.code == KamereonError.overloaded {
            return .skipped
        } catch RenaultError.kamereon(let error) where error.alwaysDrops || (!working.contains(endpoint) && error.meansMissingEndpoint) {
            drop(endpoint, because: error.description)
            return .dropped
        } catch let error as RenaultError where error.isRefusal {
            return .refused(error)
        } catch is CancellationError {
            return .skipped
        } catch {
            return .failed("\(error)")
        }
    }

    private func drop(_ endpoint: Endpoint, because reason: String) {
        dropped.insert(endpoint)
        logger.warning("Ignoring \(endpoint.rawValue) for \(logName) as this car does not have it: \(reason)")
        onDrop(info.vin, endpoint)
    }

    private func apply(_ endpoint: Endpoint, _ attributes: JSONValue) {
        switch endpoint {
        case .batteryStatus:
            let status = BatteryStatus(attributes: attributes, reportsWatts: ModelEndpoints.reportsWatts(model: info.modelCode))
            if let value = status.chargingStatus, ChargingStatus.names[value] == nil, battery?.chargingStatus != value {
                logger.warning("Unknown charging status \(value) for \(logName)")
            }
            battery = status
            if let charging = status.isCharging { settle(&pendingCharging, read: charging) }
        case .hvacStatus:
            let status = HvacStatus(attributes: attributes)
            hvac = status
            if status.internalTemperature != nil { seenInterior = true }
            if status.externalTemperature != nil { seenExterior = true }
            if let on = status.isOn { settle(&pendingClimate, read: on) }
        case .socLevels:
            soc = SocLevels(attributes: attributes)
        case .lockStatus:
            lock = LockStatus(attributes: attributes)
        default:
            break
        }
        show()
    }

    /// A read that agrees with what was written ends the optimistic state; so does its time running out.
    private func settle(_ pending: inout Pending?, read: Bool) {
        guard let current = pending else { return }
        if current.value == read || ContinuousClock.now >= current.until { pending = nil }
    }

    private func shown(_ pending: Pending?, read: Bool?) -> Bool? {
        if let pending, ContinuousClock.now < pending.until { return pending.value }
        return read
    }

    var climateShown: Bool { shown(pendingClimate, read: hvac?.isOn) ?? false }
    var chargingShown: Bool { shown(pendingCharging, read: battery?.isCharging) ?? false }

    // MARK: Services

    /// The services this car gets now: a temperature sensor only once a value has been seen (5.2).
    func serviceKeys() -> Set<String> {
        let parts = Set(availableParts().filter(isIncluded))
        var keys: Set<String> = []
        if info.usesElectricity, has(.batteryStatus) { keys.insert("Battery") }
        for part in parts {
            switch part {
            case .interiorTemperature: if seenInterior { keys.insert(part.rawValue) }
            case .exteriorTemperature: if seenExterior { keys.insert(part.rawValue) }
            default: keys.insert(part.rawValue)
            }
        }
        return keys
    }

    /// A fresh accessory with the services of `serviceKeys()`, its last values kept from `previous`.
    func makeAccessory(id: String, firmware: String, previous: Accessory?) -> Accessory? {
        let keys = serviceKeys()
        guard !keys.isEmpty else { return nil }
        let name = info.displayName
        var built: [String: Service] = [:]
        if keys.contains("Battery") {
            built["Battery"] = Service(.battery, name: name, optional: [.batteryLevel, .chargingState], isPrimary: true)
        }
        if keys.contains(VehiclePart.climate.rawValue) {
            let climate = Service(.switch, name: "\(name) Climate", subtype: "Climate", optional: [.configuredName], isPrimary: built.isEmpty)
            climate.characteristic(.on).onWrite { [weak self] value in try await self?.setClimate(value.boolValue ?? false) }
            built["Climate"] = climate
        }
        if keys.contains(VehiclePart.charging.rawValue) {
            let charging = Service(.switch, name: "\(name) Charging", subtype: "Charging", optional: [.configuredName])
            // It starts a charge (and on an R5 turns the departure programs off): MCP clients ask first.
            charging.characteristic(.on).securityControl().onWrite { [weak self] value in try await self?.setCharging(value.boolValue ?? false) }
            built["Charging"] = charging
        }
        if keys.contains(VehiclePart.pluggedIn.rawValue) {
            built["PluggedIn"] = Service(.contactSensor, name: "\(name) Plugged In", subtype: "PluggedIn", optional: [.statusFault, .configuredName])
        }
        for (part, endpoint) in [(VehiclePart.horn, Endpoint.hornStart), (.lights, .lightsStart)] where keys.contains(part.rawValue) {
            let service = Service(.switch, name: "\(name) \(part.name)", subtype: part.rawValue, optional: [.configuredName])
            let on = service.characteristic(.on)
            if part == .horn { on.securityControl() }
            on.onWrite { [weak self] value in try await self?.flash(endpoint, value: value.boolValue ?? false) }
            built[part.rawValue] = service
        }
        if keys.contains(VehiclePart.interiorTemperature.rawValue) {
            built["InteriorTemperature"] = Service(.temperatureSensor, name: "\(name) Interior", subtype: "InteriorTemperature", optional: [.configuredName])
        }
        if keys.contains(VehiclePart.exteriorTemperature.rawValue) {
            built["ExteriorTemperature"] = Service(.temperatureSensor, name: "\(name) Exterior", subtype: "ExteriorTemperature", optional: [.configuredName])
        }
        if keys.contains(VehiclePart.doors.rawValue) {
            for opening in LockStatus.openingNames {
                built["Door.\(opening)"] = Service(.contactSensor, name: "\(name) \(Self.openingName(opening))", subtype: "Door.\(opening)", optional: [.configuredName])
            }
        }
        let order = ["Battery", "Climate", "Charging", "PluggedIn", "Horn", "Lights", "InteriorTemperature", "ExteriorTemperature"]
            + LockStatus.openingNames.map { "Door.\($0)" }
        let accessory = Accessory(
            id: id, name: name, manufacturer: info.manufacturer, model: info.modelName ?? info.modelCode ?? "Renault",
            serialNumber: info.vin, firmwareRevision: firmware, category: .other, services: order.compactMap { built[$0] })
        if let previous { accessory.takeValues(from: previous) }
        services = built
        self.accessory = accessory
        show()
        return accessory
    }

    static func openingName(_ opening: String) -> String {
        ["Driver": "Driver Door", "Passenger": "Passenger Door", "RearLeft": "Rear Left Door", "RearRight": "Rear Right Door", "Hatch": "Hatch"][opening] ?? opening
    }

    /// The last data on the characteristics; only the values that changed are set.
    func show() {
        if let battery {
            if let service = services["Battery"] {
                if let level = battery.level {
                    set(service.characteristic(.batteryLevel), .int(level))
                    let threshold = soc?.minimum ?? 20
                    set(service.characteristic(.statusLowBattery), .int(level < threshold ? 1 : 0))
                }
                if let charging = battery.isCharging { set(service.characteristic(.chargingState), .int(charging ? 1 : 0)) }
            }
            if let service = services["PluggedIn"] {
                if let plugged = battery.isPluggedIn {
                    set(service.characteristic(.contactSensorState), .int(plugged ? 0 : 1))
                    set(service.characteristic(.statusFault), .int(0))
                } else {
                    set(service.characteristic(.statusFault), .int(1))
                }
            }
        }
        if let service = services["Charging"], battery?.isCharging != nil || pendingCharging != nil {
            set(service.characteristic(.on), .bool(chargingShown))
        }
        if let service = services["Climate"], hvac?.isOn != nil || pendingClimate != nil {
            set(service.characteristic(.on), .bool(climateShown))
        }
        if let value = hvac?.internalTemperature, let service = services["InteriorTemperature"] {
            set(service.characteristic(.currentTemperature), .double(value))
        }
        if let value = hvac?.externalTemperature, let service = services["ExteriorTemperature"] {
            set(service.characteristic(.currentTemperature), .double(value))
        }
        if let lock {
            for (opening, open) in lock.openings {
                if let service = services["Door.\(opening)"] { set(service.characteristic(.contactSensorState), .int(open ? 1 : 0)) }
            }
        }
    }

    private func set(_ characteristic: Characteristic, _ value: HAPValue) {
        if characteristic.value != value { characteristic.value = value }
    }

    /// No Response when every endpoint has failed for longer than `limit` (6.5).
    func updateAvailability(limit: Duration) {
        let since = lastSuccess ?? created
        let unavailable = ContinuousClock.now - since > limit
        if let accessory, accessory.isUnavailable != unavailable {
            accessory.isUnavailable = unavailable
            if unavailable { logger.warning("\(logName) has not answered for a while: shown as not responding") }
        }
    }

    // MARK: Actions (4.4 to 4.6)

    func setClimate(_ on: Bool) async throws {
        if on {
            guard let (path, _) = resolve(.hvacStart) else { throw HAPStatusError(.notAllowedInCurrentState) }
            let temperature = min(max(options.climateTemperature.finite ?? 21, 16), 27)
            let body: JSONValue = ["data": ["type": "HvacStart", "attributes": ["action": "start", "targetTemperature": .number(temperature)]]]
            try await act(path: path, body: body, label: "climate start")
            logger.info("Started the climate of \(logName) at \(temperature) °C")
        } else {
            guard let (path, mode) = resolve(.hvacStop) else {
                logger.info("\(logName) stops its climate on its own: nothing was sent")
                return
            }
            let body: JSONValue = ["data": ["type": "HvacStart", "attributes": ["action": .string(mode == .kcaStop ? "stop" : "cancel")]]]
            try await act(path: path, body: body, label: "climate stop")
            logger.info("Stopped the climate of \(logName)")
        }
        pendingClimate = Pending(value: on, until: .now + timing.optimisticHold)
        confirm(.hvacStatus)
    }

    func setCharging(_ on: Bool) async throws {
        let charging = services["Charging"]?.characteristic(.on)
        if on {
            if battery?.isUnplugged == true {
                logger.info("\(logName) is not plugged in: charging was not started")
                throw HAPStatusError(.notAllowedInCurrentState)
            }
            guard let (path, mode) = resolve(.chargeStart) else { throw HAPStatusError(.notAllowedInCurrentState) }
            switch mode {
            case .kcmSettings:
                try await startChargeBySettings(path: path)
            case .kcmPauseResume:
                try await act(path: path, body: ["data": ["type": "ChargePauseResume", "attributes": ["action": "resume"]]], label: "charge start")
                logger.info("Started charging \(logName)")
            default:
                try await act(path: path, body: ["data": ["type": "ChargingStart", "attributes": ["action": "start"]]], label: "charge start")
                logger.info("Started charging \(logName)")
            }
        } else {
            guard let (path, mode) = resolve(.chargeStop) else {
                // The R5 cannot be told to stop: the switch goes back to what the car reports.
                logger.info("\(logName) cannot be told to stop charging: unplug it or stop the charge from the charger")
                let shown = HAPValue.bool(chargingShown)
                _ = charging?.revert(to: shown, after: .milliseconds(100))
                return
            }
            let body: JSONValue = mode == .kcmPauseResume
                ? ["data": ["type": "ChargePauseResume", "attributes": ["action": "pause"]]]
                : ["data": ["type": "ChargingStart", "attributes": ["action": "stop"]]]
            try await act(path: path, body: body, label: "charge stop")
            logger.info("Stopped charging \(logName)")
        }
        pendingCharging = Pending(value: on, until: .now + timing.optimisticHold)
        confirm(.batteryStatus)
    }

    /// The R5's charge start (4.6): read `ev/settings`, turn every program off, write the document back as it was
    /// otherwise. The programs stay off; their flags are kept in memory.
    private func startChargeBySettings(path: String) async throws {
        let vin = logName
        let previous: [Bool]
        do {
            previous = try await session.perform(.action, cost: 2) { session in
                let settings = try await session.send(.action, path: path, label: "charge settings")
                guard var document = settings.objectValue else { throw RenaultError.missing("charge settings") }
                var flags: [Bool] = []
                if let programs = document["programs"]?.arrayValue {
                    document["programs"] = .array(programs.map { program in
                        guard var fields = program.objectValue else { return program }
                        flags.append(fields["programActivationStatus"]?.boolValue ?? false)
                        fields["programActivationStatus"] = false
                        return .object(fields)
                    })
                }
                _ = try await session.send(.action, method: "POST", path: path, body: .object(document), label: "charge start")
                return flags
            }
        } catch {
            throw Self.status(for: error, logger: logger, action: "charge start", vehicle: vin)
        }
        programsBeforeChargeStart = previous
        logger.info("Started charging \(vin) by turning its departure programs off (\(previous.filter { $0 }.count) were on)")
    }

    /// Horn or lights: the action, then the switch turns itself off.
    func flash(_ endpoint: Endpoint, value: Bool) async throws {
        guard value else { return }
        guard let (path, _) = resolve(endpoint) else { throw HAPStatusError(.notAllowedInCurrentState) }
        let target = endpoint == .hornStart ? "horn" : "lights"
        try await act(path: path, body: ["data": ["type": "HornLights", "attributes": ["action": "start", "target": .string(target)]]], label: target)
        logger.info("Sent \(target) to \(logName)")
        let key = endpoint == .hornStart ? "Horn" : "Lights"
        _ = services[key]?.characteristic(.on).revert(to: .bool(false), after: timing.momentary)
    }

    private func act(path: String, body: JSONValue, label: String) async throws {
        do {
            _ = try await session.perform(.action) { session in
                try await session.send(.action, method: "POST", path: path, body: body, label: label)
            }
        } catch {
            throw Self.status(for: error, logger: logger, action: label, vehicle: logName)
        }
    }

    /// An action's failure as HomeKit hears it, logged.
    static func status(for error: any Error, logger: Logger, action: String, vehicle: String) -> HAPStatusError {
        switch error {
        case RenaultError.quota:
            logger.warning("Renault's hourly quota is spent: the \(action) for \(vehicle) was not sent")
        default:
            logger.warning("The \(action) for \(vehicle) failed: \(error)")
        }
        return HAPStatusError(.serviceCommunicationFailure)
    }

    /// Reads the endpoint again after the action, at 6.1's delays, inside the budget (a read that does not fit is skipped).
    private func confirm(_ endpoint: Endpoint) {
        confirmations[endpoint]?.cancel()
        let delays = timing.confirmations
        let task = tasks.add { [weak self] in
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                _ = await self?.read(endpoint, .confirmation)
            }
        }
        confirmations[endpoint] = task
    }
}
