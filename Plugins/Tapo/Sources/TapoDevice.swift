import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// One device of the block: its session, its last report, the polling that keeps it fresh, and HomeKit's writes.
///
/// It polls `get_device_info` every `updateInterval` while it answers, and backs off (up to five minutes) while it does
/// not, back to `updateInterval` at the first answer. A P110 reads its energy with each poll, an L530 every ten
/// minutes. Writes made within `waitTimeUpdate` go out together, in order: on or off, brightness, then the white or the
/// colour; a light that is off takes no brightness or colour (they are acknowledged and dropped, as the Homebridge
/// plugin does).
actor TapoDevice {
    struct Settings: Sendable {
        var deviceID: String
        var name: String
        var host: String
        var kind: TapoKind
        var interval: Duration
        var backoff: Backoff
        var writeDelay: Duration
        var bulbEnergyInterval: Duration
    }

    let settings: Settings
    let connection: TapoConnection
    private let logger: Logger
    private(set) var services: TapoServices?
    private(set) var state: TapoState?
    private(set) var energy: TapoEnergy?
    private(set) var isReachable = true
    private(set) var failures = 0
    private var shownInformation = false
    private var lastBulbEnergy: ContinuousClock.Instant?
    private var pending = TapoWrite()
    private var flush: Task<Void, any Error>?
    /// `set_device_info`'s `terminalUUID` for on and off: one per device and run.
    private let terminalUUID = UUID().uuidString.uppercased()

    init(settings: Settings, connection: TapoConnection, logger: Logger) {
        self.settings = settings
        self.connection = connection
        self.logger = logger
    }

    func attach(_ services: TapoServices) {
        self.services = services
    }

    /// Polls until cancelled.
    func run() async {
        while !Task.isCancelled {
            let delay = await poll() ? settings.interval : settings.backoff.delay(attempt: failures - 1)
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    /// One poll: the state, then the energy when it is due. True when the device answered.
    @discardableResult
    func poll() async -> Bool {
        let fresh: TapoState
        do {
            fresh = TapoState(info: try await connection.call("get_device_info"))
        } catch {
            failed(error)
            return false
        }
        let previous = state
        state = fresh
        if failures > 0 || !isReachable {
            if !isReachable { logger.info("\(settings.name) (\(settings.host)) is responding again") }
            failures = 0
            isReachable = true
        }
        services?.accessory.isUnreachable = false
        services?.show(fresh, previous: previous, kind: settings.kind)
        if !shownInformation {
            shownInformation = true
            services?.showInformation(fresh)
            logger.info("Connected to \(settings.name) (\(settings.host))")
        }
        await readEnergy()
        return true
    }

    private func failed(_ error: any Error) {
        failures += 1
        guard isReachable else {
            logger.debug("\(settings.name) (\(settings.host)) still does not answer: \(error)")
            return
        }
        isReachable = false
        services?.accessory.isUnreachable = true
        switch error {
        case TapoError.invalidCredentials, TapoError.noCredentials:
            logger.error("Cannot sign in to \(settings.name) (\(settings.host)): \(error)")
        default:
            logger.warning("Cannot reach \(settings.name) (\(settings.host)), will keep trying: \(error)")
        }
    }

    private func readEnergy() async {
        let reading: TapoEnergy?
        do {
            switch settings.kind {
            case .powerPlug:
                reading = TapoEnergy(plugUsage: try await connection.call("get_energy_usage"))
            case .colorLight:
                if let lastBulbEnergy, ContinuousClock.now - lastBulbEnergy < settings.bulbEnergyInterval { return }
                lastBulbEnergy = .now
                reading = TapoEnergy(bulbUsage: try await connection.call("get_device_usage"), isOn: state?.on == true)
            default:
                return
            }
        } catch {
            logger.debug("Could not read the energy of \(settings.name): \(error)")
            return
        }
        guard let reading else { return }
        energy = reading
        services?.show(reading, kind: settings.kind)
        services?.history?.add(EveHistory.Entry(power: reading.watts))
    }

    // MARK: Writes

    /// A write from HomeKit, sent with the others made within `writeDelay`; throws No Response when it failed.
    func write(_ change: TapoWrite) async throws {
        guard state != nil else { throw HAPStatusError(.serviceCommunicationFailure) }
        pending.merge(change)
        let task: Task<Void, any Error>
        if let flush {
            task = flush
        } else {
            let delay = settings.writeDelay
            task = Task {
                try await Task.sleep(for: delay)
                try await self.sendPending()
            }
            flush = task
        }
        do {
            try await task.value
        } catch {
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    private func sendPending() async throws {
        let write = pending
        pending = TapoWrite()
        flush = nil
        do {
            try await send(write)
        } catch {
            logger.error("Could not set \(Self.describe(write)) on \(settings.name) (\(settings.host)): \(error)")
            throw error
        }
    }

    private func send(_ write: TapoWrite) async throws {
        if let on = write.on {
            _ = try await connection.call("set_device_info", params: ["device_on": .bool(on)], terminalUUID: terminalUUID)
            state?.on = on
        }
        guard write.brightness != nil || write.mireds != nil || write.hue != nil || write.saturation != nil else { return }
        guard state?.on == true else {
            logger.debug("\(settings.name) is off: not sending \(Self.describe(write))")
            return
        }
        if let brightness = write.brightness {
            // The devices take 1 to 100.
            let value = min(max(brightness, 1), 100)
            _ = try await connection.call("set_device_info", params: ["brightness": .number(Double(value))])
            state?.brightness = value
        }
        if let mireds = write.mireds {
            let kelvin = TapoConversion.kelvin(mireds: mireds)
            _ = try await connection.call("set_device_info", params: ["hue": 0, "saturation": 0, "color_temp": .number(Double(kelvin))])
            state?.kelvin = kelvin
            state?.hue = 0
            state?.saturation = 0
        } else if write.hue != nil || write.saturation != nil {
            let hue = write.hue ?? state?.hue ?? 0
            let saturation = write.saturation ?? state?.saturation ?? 0
            _ = try await connection.call("set_device_info", params: ["hue": .number(Double(hue)), "color_temp": 0, "saturation": .number(Double(saturation))])
            state?.hue = hue
            state?.saturation = saturation
            state?.kelvin = 0
        }
        logger.debug("Set \(Self.describe(write)) on \(settings.name)")
    }

    static func describe(_ write: TapoWrite) -> String {
        var parts: [String] = []
        if let on = write.on { parts.append(on ? "power on" : "power off") }
        if let brightness = write.brightness { parts.append("brightness \(brightness)") }
        if let mireds = write.mireds { parts.append("colour temperature \(mireds) mireds") }
        if let hue = write.hue { parts.append("hue \(hue)") }
        if let saturation = write.saturation { parts.append("saturation \(saturation)") }
        return parts.joined(separator: ", ")
    }
}
