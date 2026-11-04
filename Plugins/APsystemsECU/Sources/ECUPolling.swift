import Foundation
import Homeswift
import HomeswiftPlugin

/// What the plugin knows of one configured ECU between polls.
struct ECURuntime: Sendable {
    let host: String
    let port: Int
    let configuredName: String?
    var ecuID: String?
    /// The last good system answer, after the filters (5.2).
    var system: ECUProtocol.SystemInfo?
    /// The date (`YYYYMMDD`) of the last real-time data, to tell the ECU's midnight reset from a glitch.
    var dataDate: String?
    var meter: ECUMeter?
    /// Polls that failed in a row.
    var failures = 0
    var realTimeFailing = false
    var meterFailing = false
    var loggedHint = false
    var lastSuccess: Date?
    var nextPoll = ContinuousClock.now
}

/// An ECU's accessory: its production.
struct ECUServices: Sendable {
    let solar: Service
}

/// An inverter's accessory: its power and temperature.
struct InverterServices: Sendable {
    let power: Service
    let temperature: Service
}

/// An inverter's last reading, for the page and Setup.
struct InverterReading: Sendable {
    var ecuID: String
    var record: ECUProtocol.Inverter
    /// 0...255, nil when the ECU did not say.
    var signal: Int?
    var updated: Date
    /// Whether the last poll's answer carried it.
    var current: Bool
}

/// Eve's power characteristics, which the Eve app shows on the production's Light Sensor; the Home app ignores them.
enum Eve {
    static let consumption = CharacteristicType(
        name: "Consumption", uuid: HAPUUID("E863F10D-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 100_000, minStep: 0.1)
    static let totalConsumption = CharacteristicType(
        name: "Total Consumption", uuid: HAPUUID("E863F10C-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 100_000_000, minStep: 0.1)
}

extension Characteristic {
    /// Sets the value when it differs: an unchanged reading reaches no controller.
    func update(_ value: HAPValue) {
        if self.value != value { self.value = value }
    }
}

extension APsystemsECUPlugin {
    /// HAP's Current Ambient Light Level for a power in W: at least 0.0001, at most 100000.
    static func lux(_ watts: Int) -> HAPValue { .double(min(max(Double(watts), 0.0001), 100_000)) }

    // MARK: A poll

    /// One poll of an ECU (3.1): system info, real-time data and signal levels, each on its own connection, then the
    /// ECU-C's meter. The system answer decides success; the others only add to it.
    func poll(_ key: String) async {
        guard var ecu = ecus[key] else { return }
        if let id = ecu.ecuID, context.isExcluded(id) {
            ecu.nextPoll = .now + scaled(seconds: pollSeconds)
            ecus[key] = ecu
            return
        }
        let exchanger = self.exchanger
        do {
            let systemFrame = try ECUProtocol.validate(
                try await exchanger.exchange(ECUProtocol.systemRequest, host: ecu.host, port: ecu.port), expecting: .system)
            let system = try ECUProtocol.parseSystem(systemFrame)
            logger.debug("System answer", metadata: ["ecu": "\(ECUProtocol.masked(system.ecuID))",
                "hex": "\(ECUProtocol.maskedHex(systemFrame, ecuID: system.ecuID, masked: ECUProtocol.systemMACRange(systemFrame)))"])
            if ecu.ecuID == nil || ecu.ecuID != system.ecuID {
                logger.info("Found \(ECUProtocol.ecuModel(system.ecuID)) at \(ecu.host): firmware \(system.firmware), \(system.inverters) inverters")
            }
            if context.isExcluded(system.ecuID) {
                ecu.ecuID = system.ecuID
                ecu.nextPoll = .now + scaled(seconds: pollSeconds)
                ecus[key] = ecu
                return
            }
            let realTime = await readRealTime(&ecu, ecuID: system.ecuID, exchanger: exchanger)
            let levels = realTime == nil ? nil : await readSignal(ecu, ecuID: system.ecuID, exchanger: exchanger)
            let meter = await readMeter(&ecu, ecuID: system.ecuID)
            succeeded(&ecu, system: system, realTime: realTime, levels: levels, meter: meter)
        } catch is CancellationError {
            return
        } catch {
            failed(&ecu, error)
        }
        ecu.nextPoll = .now + nextDelay(ecu)
        ecus[key] = ecu
    }

    /// The real-time answer, nil when it fails (logged once until it answers again).
    private func readRealTime(_ ecu: inout ECURuntime, ecuID: String, exchanger: any ECUExchanging) async -> ECUProtocol.RealTime? {
        do {
            let frame = try ECUProtocol.validate(try await exchanger.exchange(ECUProtocol.realTimeRequest(ecuID: ecuID), host: ecu.host, port: ecu.port), expecting: .realTime)
            logger.debug("Real-time answer", metadata: ["ecu": "\(ECUProtocol.masked(ecuID))", "hex": "\(ECUProtocol.maskedHex(frame, ecuID: ecuID))"])
            let realTime = try ECUProtocol.parseRealTime(frame)
            if realTime.model != "01", loggedOddities.insert("model \(realTime.model)").inserted {
                logger.info("The ECU's real-time data has model \(realTime.model) (01 expected): read as usual")
            }
            if let type = realTime.unknownType, loggedOddities.insert("type \(type)").inserted {
                logger.warning("An inverter record of unknown type \(type): the records after it are left out")
                logger.debug("Frame with an unknown type", metadata: ["hex": "\(ECUProtocol.maskedHex(frame, ecuID: ecuID))"])
            }
            if realTime.truncated, loggedOddities.insert("truncated").inserted {
                logger.warning("The ECU's real-time data ends before its last inverter record: the records read are kept")
            }
            if ecu.realTimeFailing { logger.info("The ECU's inverter data is back") }
            ecu.realTimeFailing = false
            return realTime
        } catch {
            if !ecu.realTimeFailing { logger.warning("Could not read the inverters from the ECU at \(ecu.host): \(error)") }
            ecu.realTimeFailing = true
            return nil
        }
    }

    /// The signal levels, nil when they fail (the levels are a detail: debug only).
    private func readSignal(_ ecu: ECURuntime, ecuID: String, exchanger: any ECUExchanging) async -> [String: Int]? {
        do {
            let frame = try ECUProtocol.validate(try await exchanger.exchange(ECUProtocol.signalRequest(ecuID: ecuID), host: ecu.host, port: ecu.port), expecting: .signal)
            logger.debug("Signal answer", metadata: ["ecu": "\(ECUProtocol.masked(ecuID))", "hex": "\(ECUProtocol.maskedHex(frame, ecuID: ecuID))"])
            return try ECUProtocol.parseSignal(frame)
        } catch {
            logger.debug("Could not read the signal levels: \(error)")
            return nil
        }
    }

    /// An ECU-C's CT clamps, nil when the meter is off, the ECU has none, or it fails: never a failed poll (3.9).
    private func readMeter(_ ecu: inout ECURuntime, ecuID: String) async -> ECUMeter? {
        guard configuration.meter != false, ECUProtocol.hasMeter(ecuID) else { return nil }
        do {
            let meter = try await dependencies.meter.meter(host: ecu.host)
            if ecu.meterFailing { logger.info("The ECU-C's meter answers again") }
            ecu.meterFailing = false
            return meter
        } catch {
            if !ecu.meterFailing {
                logger.warning("The ECU-C's meter did not answer (\(error)): its CT readings stay unknown, the production is read as usual")
            }
            ecu.meterFailing = true
            return nil
        }
    }

    /// The wait before the next poll: the interval; twice it (at most 15 minutes, unless the interval is longer) after
    /// failures in a row; 15 minutes at night, while no inverter is online.
    func nextDelay(_ ecu: ECURuntime) -> Duration {
        let interval = pollSeconds
        if ecu.failures >= Self.failuresBeforeBackoff { return scaled(seconds: max(interval, min(2 * interval, Self.slowInterval))) }
        if ecu.failures == 0, let system = ecu.system, system.invertersOnline == 0 { return scaled(seconds: max(interval, Self.slowInterval)) }
        return scaled(seconds: interval)
    }

    // MARK: Failure

    private func failed(_ ecu: inout ECURuntime, _ error: any Error) {
        ecu.failures += 1
        if ecu.failures == 1 || ecu.failures % 10 == 0 {
            logger.warning("Cannot read the ECU at \(ecu.host): \(error); keeping its last values (failed \(ecu.failures) time\(ecu.failures == 1 ? "" : "s") in a row)")
        }
        if !ecu.loggedHint, ecu.failures * pollSeconds >= 3600 {
            ecu.loggedHint = true
            logger.warning("The ECU at \(ecu.host) has not answered for an hour: if it stays so, power-cycle it")
        }
        guard let id = ecu.ecuID else { return }
        if let services = ecuServices[id] {
            services.solar.characteristic(.statusActive).update(.bool(false))
            if ecu.failures >= connectRetries { services.solar.characteristic(.statusFault).update(.int(1)) }
        }
        markInverters(of: id, current: [])
    }

    // MARK: Success

    /// The system answer with the firmware's glitches filtered (5.2): a count or a lifetime of 0, a today that drops while
    /// inverters are online on the same day, a lifetime that drops.
    static func filtered(_ system: ECUProtocol.SystemInfo, previous: ECUProtocol.SystemInfo?, previousDate: String?, newDate: String?) -> ECUProtocol.SystemInfo {
        guard let previous, previous.ecuID == system.ecuID else { return system }
        var accepted = system
        if system.inverters == 0 { accepted.inverters = previous.inverters }
        if system.lifetimeEnergy == 0 || system.lifetimeEnergy < previous.lifetimeEnergy { accepted.lifetimeEnergy = previous.lifetimeEnergy }
        let newDay = previousDate != nil && newDate != nil && previousDate != newDate
        if system.todayEnergy == 0, system.invertersOnline > 0 {
            accepted.todayEnergy = previous.todayEnergy
        } else if system.todayEnergy < previous.todayEnergy, !newDay, system.invertersOnline > 0 {
            accepted.todayEnergy = previous.todayEnergy
        }
        return accepted
    }

    private func succeeded(
        _ ecu: inout ECURuntime, system raw: ECUProtocol.SystemInfo, realTime: ECUProtocol.RealTime?, levels: [String: Int]?, meter: ECUMeter?
    ) {
        if ecu.failures > 0 { logger.info("The ECU at \(ecu.host) answers again after \(ecu.failures) failed poll\(ecu.failures == 1 ? "" : "s")") }
        let system = Self.filtered(raw, previous: ecu.system, previousDate: ecu.dataDate, newDate: realTime?.date)
        ecu.failures = 0
        ecu.loggedHint = false
        ecu.ecuID = system.ecuID
        ecu.system = system
        ecu.meter = meter
        ecu.lastSuccess = Date()
        if let date = realTime?.date, date.count == 8 { ecu.dataDate = date }
        let id = system.ecuID
        let name = ecu.configuredName ?? "\(ECUProtocol.ecuModel(id)) \(id)"

        if let services = ecuServices[id] ?? addECU(id: id, name: name, system: system) {
            services.solar.characteristic(.currentAmbientLightLevel).update(Self.lux(system.currentPower))
            services.solar.characteristic(.statusActive).update(.bool(true))
            services.solar.characteristic(.statusFault).update(.int(0))
            services.solar[Eve.consumption]?.update(.double(min(Double(system.currentPower), 100_000)))
            services.solar[Eve.totalConsumption]?.update(.double(min(system.lifetimeEnergy, 100_000_000)))
        }
        // The Energy section: the production, 0 at night included; the meter when it answered.
        context.recordValue(Double(system.currentPower), series: "\(id):solar", energy: EnergyTag(role: .solar, device: name))
        context.recordValue(system.todayEnergy, series: "\(id):today")
        if let grid = meter?.gridPower { context.recordValue(grid, series: "\(id):grid", energy: EnergyTag(role: .grid, device: name)) }
        if let home = meter?.homePower { context.recordValue(home, series: "\(id):home", energy: EnergyTag(role: .home, device: name)) }

        guard let realTime else {
            markInverters(of: id, current: [])
            return
        }
        var current: Set<String> = []
        for record in realTime.inverters {
            current.insert(record.uid)
            let signal = levels?[record.uid]
            inverterReadings[record.uid] = InverterReading(ecuID: id, record: record, signal: signal, updated: Date(), current: true)
            guard !record.isRegisteredOnly else { continue }
            recordHistory(record, signal: signal)
            guard configuration.inverters != false, !context.isExcluded(record.uid) else { continue }
            guard let services = inverterServices[record.uid] ?? addInverter(record) else { continue }
            Self.show(record, on: services)
        }
        markInverters(of: id, current: current)
        if configuration.inverters == false { removeInverterAccessories(current) }
    }

    /// Shows an inverter's reading: its power, and its temperature while it is online (an offline record's −100 °C never).
    static func show(_ record: ECUProtocol.Inverter, on services: InverterServices) {
        services.power.characteristic(.currentAmbientLightLevel).update(lux(record.power))
        services.power.characteristic(.statusActive).update(.bool(record.online))
        if record.online, let temperature = record.temperature {
            services.temperature.characteristic(.currentTemperature).update(.double(Double(min(max(temperature, -270), 100))))
            services.temperature.characteristic(.statusActive).update(.bool(true))
        } else {
            services.temperature.characteristic(.statusActive).update(.bool(false))
        }
    }

    /// The history of an inverter's channels: powers always (an offline inverter's zeros are its production), the rest
    /// while it is online.
    private func recordHistory(_ record: ECUProtocol.Inverter, signal: Int?) {
        let uid = record.uid
        context.recordValue(Double(record.power), series: "\(uid):power")
        for (index, power) in record.powers.enumerated() { context.recordValue(Double(power), series: "\(uid):power\(index + 1)") }
        guard record.online else { return }
        for (index, voltage) in record.voltages.enumerated() { context.recordValue(Double(voltage), series: "\(uid):voltage\(index + 1)") }
        if let frequency = record.frequency { context.recordValue(frequency, series: "\(uid):frequency") }
        if let temperature = record.temperature { context.recordValue(Double(temperature), series: "\(uid):temperature") }
        if let signal { context.recordValue(Double(ECUProtocol.signalPercent(signal)), series: "\(uid):signal") }
    }

    /// The inverters of an ECU that this answer did not carry (or that only registered): their last values kept, not active.
    private func markInverters(of ecuID: String, current: Set<String>) {
        for (uid, reading) in inverterReadings where reading.ecuID == ecuID {
            let fresh = current.contains(uid) && !reading.record.isRegisteredOnly
            if !current.contains(uid) { inverterReadings[uid]?.current = false }
            guard !fresh, let services = inverterServices[uid] else { continue }
            services.power.characteristic(.statusActive).update(.bool(false))
            services.temperature.characteristic(.statusActive).update(.bool(false))
        }
    }

    private func removeInverterAccessories(_ uids: Set<String>) {
        let present = Set(context.accessories.map(\.id))
        for uid in uids where present.contains(Self.accessoryID(deviceID: uid)) {
            inverterServices[uid] = nil
            let id = Self.accessoryID(deviceID: uid)
            tasks.add { [context] in try? await context.remove(id: id) }
        }
    }

    // MARK: Accessories

    private func addECU(id: String, name: String, system: ECUProtocol.SystemInfo) -> ECUServices? {
        let solar = Service(
            .lightSensor, name: "Solar power", optional: [.statusActive, .statusFault],
            extra: [Characteristic(Eve.consumption, value: .double(0)), Characteristic(Eve.totalConsumption, value: .double(0))], isPrimary: true)
        let services = ECUServices(solar: solar)
        do {
            try context.add(Accessory(
                id: Self.accessoryID(deviceID: id), name: name, manufacturer: "APsystems", model: ECUProtocol.ecuModel(id), serialNumber: id,
                firmwareRevision: ECUProtocol.firmwareRevision(system.firmware), category: .sensor, services: [solar]))
        } catch {
            logger.error("Could not add the ECU \(ECUProtocol.masked(id)): \(error)")
            return nil
        }
        ecuServices[id] = services
        return services
    }

    private func addInverter(_ record: ECUProtocol.Inverter) -> InverterServices? {
        let power = Service(.lightSensor, name: "Power", optional: [.statusActive], isPrimary: true)
        let temperature = Service(.temperatureSensor, name: "Temperature", optional: [.statusActive])
        power.characteristic(.statusActive).value = .bool(false)
        temperature.characteristic(.statusActive).value = .bool(false)
        let services = InverterServices(power: power, temperature: temperature)
        do {
            try context.add(Accessory(
                id: Self.accessoryID(deviceID: record.uid), name: "Inverter \(record.uid)", manufacturer: "APsystems",
                model: ECUProtocol.inverterModel(record.uid), serialNumber: record.uid, category: .sensor, services: [power, temperature]))
        } catch {
            logger.error("Could not add the inverter \(ECUProtocol.masked(record.uid)): \(error)")
            return nil
        }
        inverterServices[record.uid] = services
        return services
    }
}
