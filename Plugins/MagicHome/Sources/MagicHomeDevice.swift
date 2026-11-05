import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's timings; tests shorten them.
struct MagicHomeTiming: Sendable {
    var connection = MagicHomeConnection.Timing()
    /// Between two state queries of a device that does not send its changes.
    var poll: Duration = .seconds(30)
    /// Between two state queries of a device that sends its changes on its open connection.
    var pushPoll: Duration = .seconds(90)
    /// After a query that went unanswered.
    var retry = Backoff(initial: .seconds(5), maximum: .seconds(300), jitter: .proportional(0.2))
    /// Unanswered queries in a row before the accessory shows No Response.
    var failuresBeforeNoResponse = 4
    /// HomeKit's writes of one change are gathered this long (section 5.2's 20 ms).
    var coalesce: Duration = .milliseconds(20)
    /// A slider's writes: only the last of those this close together is sent.
    var slider: Duration = .milliseconds(100)
    /// Between the power-on frame and the levels (section 5.2's 100 ms).
    var powerToLevels: Duration = .milliseconds(100)
    /// After a write, how long the device may still report what it showed before (a fade); it is read once after.
    var settle: Duration = .seconds(3)
    var identifyStep: Duration = .milliseconds(300)
    var identifyTicks = 20
    /// How long a scan listens.
    var scanWindow: Duration = .seconds(2)
    /// Between two scans with `periodicDiscovery`.
    var periodicDiscovery: Duration = .seconds(30)
    /// State queries of a device just found before it is given up until the next scan.
    var addAttempts = 3
    /// Before a device found that did not answer, or that the plugin does not know, is asked again at the same address.
    var retryRejected: Duration = .seconds(300)
}

/// The plugin's log, filtered by `advancedOptions.logLevel` (section 6): 1 errors, 2 warnings, 3 information (the
/// default), 4 debug and 5 trace, those two written as information once asked for.
struct MagicHomeLog: Sendable {
    let logger: Logger
    let level: Int

    func error(_ message: @autoclosure () -> Logger.Message) { logger.error(message()) }
    func warning(_ message: @autoclosure () -> Logger.Message) { if level >= 2 { logger.warning(message()) } }
    func info(_ message: @autoclosure () -> Logger.Message) { if level >= 3 { logger.info(message()) } }
    func debug(_ message: @autoclosure () -> Logger.Message) { if level >= 4 { logger.info(message()) } else { logger.debug(message()) } }
    func trace(_ message: @autoclosure () -> Logger.Message) { if level >= 5 { logger.info(message()) } else { logger.trace(message()) } }
}

/// What the plugin keeps of a device between launches (its `devices.json`), so it is controllable before a scan finds it.
struct MagicHomeRecord: Sendable, Codable, Equatable {
    var host: String
    var module: String
    var model: UInt8
    var version: UInt8
    var mode: UInt8
    /// Launches since a scan or a query last heard it (`pruning`).
    var restartsSinceSeen = 0
}

/// The characteristics of an accessory the plugin sets.
struct MagicHomeServices: @unchecked Sendable {
    let accessory: Accessory
    let primary: Service
    let on: Characteristic
    var brightness: Characteristic?
    var hue: Characteristic?
    var saturation: Characteristic?
    var colorTemperature: Characteristic?
}

/// One device: its connection, its light as last known, HomeKit's writes (gathered, the sliders' last only) and the
/// polls that keep its accessory current and say when it stops answering.
actor MagicHomeDevice {
    struct Options: Sendable {
        var effects = MagicHomeWhiteEffects()
        var timing = MagicHomeTiming()
    }

    /// The Device Id, the MAC.
    let id: String
    let options: Options
    let connection: MagicHomeConnection
    let log: MagicHomeLog
    private(set) var record: MagicHomeRecord
    private(set) var profile: MagicHomeProfile
    private(set) var light = MagicHomeLight()
    private(set) var isReachable = true
    private var services: MagicHomeServices?
    private var adaptiveLighting: AdaptiveLightingController?
    private var batcher: LightChangeBatcher?
    private let sliders: LatestCallGuard
    private var failures = 0
    private var lastUpdate: ContinuousClock.Instant?
    private var lastWrite: ContinuousClock.Instant?
    /// A white Adaptive Lighting set while the light was off: sent with the power-on.
    private var levelsWaiting = false
    private var sleeper: Task<Void, Never>?
    private var identifying: Task<Void, Never>?
    /// The profile changed shape (a firmware update, another mode): the plugin builds the accessory again.
    private var onReshape: (@Sendable (MagicHomeProfile) async -> Void)?
    /// The record changed (a new address, a version): the plugin saves it.
    private var onRecord: (@Sendable (MagicHomeRecord) async -> Void)?

    init(id: String, record: MagicHomeRecord, profile: MagicHomeProfile, transport: any MagicHomeTransport, options: Options, log: MagicHomeLog) {
        self.id = id
        self.record = record
        self.profile = profile
        self.options = options
        self.log = log
        sliders = LatestCallGuard(delay: options.timing.slider)
        connection = MagicHomeConnection(host: record.host, persistent: profile.family.pushes, transport: transport, timing: options.timing.connection)
    }

    var name: String { services?.primary[.name]?.value.stringValue ?? id }

    func observe(reshape: (@Sendable (MagicHomeProfile) async -> Void)?, record: (@Sendable (MagicHomeRecord) async -> Void)?) {
        onReshape = reshape
        onRecord = record
    }

    /// Attaches the accessory's characteristics, shows `state` (the last known) and starts taking pushes; called each
    /// time the accessory is built, before it goes on the bridge.
    func attach(_ services: MagicHomeServices, adaptiveLighting: AdaptiveLightingController?, state: MagicHomeState?) async {
        self.services = services
        self.adaptiveLighting = adaptiveLighting
        services.accessory.isUnavailable = !isReachable
        if batcher == nil {
            batcher = LightChangeBatcher(window: options.timing.coalesce) { [weak self] changes in try await self?.flush(changes) }
        }
        if let state { show(MagicHomeReading.of(state, profile: profile, effects: options.effects)) }
        await connection.setPush { [weak self] message in await self?.pushed(message) }
    }

    /// A scan heard the device, at this address.
    func seen(at host: String) async {
        guard host != record.host || record.restartsSinceSeen != 0 else { return }
        if host != record.host {
            log.warning("\(name) moved from \(record.host) to \(host)")
            await connection.update(host: host, persistent: profile.family.pushes)
        }
        record.host = host
        record.restartsSinceSeen = 0
        await onRecord?(record)
    }

    // MARK: Polling

    /// Polls until cancelled: first after `first` (the interval when nil), then every `poll` (`pushPoll` for a device that sends its
    /// changes), sooner after a write, and less and less often while it does not answer.
    func run(first: Duration?) async {
        var delay = first ?? interval
        while !Task.isCancelled {
            if delay > .zero {
                let wait = delay
                let sleeper = Task { _ = try? await Task.sleep(for: wait) }
                self.sleeper = sleeper
                await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
                self.sleeper = nil
                if Task.isCancelled { break }
            }
            delay = await poll()
        }
        await stop()
    }

    func stop() async {
        identifying?.cancel()
        identifying = nil
        sleeper?.cancel()
        await connection.setPush(nil)
        await connection.close()
    }

    private var interval: Duration { profile.family.pushes ? options.timing.pushPoll : options.timing.poll }

    /// One query, unless a write is settling (the time left is the answer) or the device sent its state recently.
    /// Answers the delay before the next.
    func poll() async -> Duration {
        let now = ContinuousClock.now
        if let lastWrite, now - lastWrite < options.timing.settle { return options.timing.settle - (now - lastWrite) }
        if profile.family.pushes, await connection.isOpen, let lastUpdate, now - lastUpdate < interval { return interval - (now - lastUpdate) }
        do {
            let state = try await connection.query(wrapped: profile.family.wrapsRequests)
            await answered()
            await received(state)
            return interval
        } catch {
            return await unanswered(error)
        }
    }

    private func answered() async {
        failures = 0
        if record.restartsSinceSeen != 0 {
            record.restartsSinceSeen = 0
            await onRecord?(record)
        }
        guard !isReachable else { return }
        isReachable = true
        services?.accessory.isUnavailable = false
        log.info("\(name) answers again")
    }

    private func unanswered(_ error: any Error) async -> Duration {
        failures += 1
        await connection.close()
        if failures == options.timing.failuresBeforeNoResponse, isReachable {
            isReachable = false
            services?.accessory.isUnavailable = true
            // Once per outage.
            log.warning("\(name) at \(record.host) does not answer: \(error)")
        } else {
            log.debug("\(name) did not answer (\(failures)): \(error)")
        }
        return options.timing.retry.delay(attempt: failures - 1)
    }

    /// Wakes the poll loop: it reads the device once the write has settled.
    private func wake() { sleeper?.cancel() }

    private func pushed(_ message: MagicHomeMessage) async {
        switch message {
        case .state(let state):
            await received(state)
        case .power(let on):
            lastUpdate = .now
            guard !isSettling else { return }
            light.isOn = on
            set(services?.on, .bool(on))
        case .other:
            break
        }
    }

    private var isSettling: Bool { lastWrite.map { ContinuousClock.now - $0 < options.timing.settle } ?? false }

    /// A state reply or push: the profile (and the accessory) follow the device, then its values.
    func received(_ state: MagicHomeState) async {
        lastUpdate = .now
        if state.model != record.model || state.version != record.version || state.mode != record.mode {
            record.model = state.model
            record.version = state.version
            record.mode = state.mode
            if let profile = MagicHomeProfile.make(model: state.model, version: state.version, modeByte: state.mode), profile != self.profile {
                let reshaped = profile.shape != self.profile.shape
                self.profile = profile
                await connection.update(host: record.host, persistent: profile.family.pushes)
                if reshaped { await onReshape?(profile) }
            }
            await onRecord?(record)
        }
        // A fade may still report what it showed before the write: read again once it settled.
        guard !isSettling else { return }
        show(MagicHomeReading.of(state, profile: profile, effects: options.effects))
    }

    /// The device's report: Adaptive Lighting turned off by a colour or a white set elsewhere, then each value that
    /// changed.
    private func show(_ reading: MagicHomeReading) {
        if reading.on, let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive {
            if reading.showsWhite, let mireds = reading.mireds {
                adaptiveLighting.disableIfChangedElsewhere(mireds: mireds, tolerance: Self.tolerance(reading, writer: profile.writer))
            } else if !reading.showsWhite, reading.hue != nil {
                adaptiveLighting.disableIfChangedElsewhere(mireds: nil)
            }
        }
        light.isOn = reading.on
        set(services?.on, .bool(reading.on))
        if let brightness = reading.brightness {
            light.brightness = Double(brightness)
            set(services?.brightness, .int(brightness))
        }
        if let hue = reading.hue {
            light.hue = hue
            set(services?.hue, .double(hue))
        }
        if let saturation = reading.saturation {
            light.saturation = saturation
            set(services?.saturation, .double(saturation))
        }
        // An off light under Adaptive Lighting keeps the white Adaptive Lighting chose (sent with the power-on), not the
        // one the device last showed.
        if let mireds = reading.mireds, reading.on || adaptiveLighting?.isAdaptiveLightingActive != true {
            light.mireds = mireds
            set(services?.colorTemperature, .int(mireds))
        }
        if profile.hasTemperature, reading.mireds != nil || reading.hue != nil { light.showsWhite = reading.showsWhite }
    }

    /// How far a white read back may be from the one sent: a percent of 3800 K is up to 5 mireds at the warm end; warm
    /// and cool levels are whole bytes, which at a low brightness are a few steps from warm to cool.
    static func tolerance(_ reading: MagicHomeReading, writer: MagicHomeProfile.Writer) -> Int {
        if writer == .percentCCT { return 7 }
        let span = Double(MagicHomeColour.miredRange.upperBound - MagicHomeColour.miredRange.lowerBound)
        let levels = 2.55 * Double(max(reading.brightness ?? 100, 1))
        return max(AdaptiveLightingController.changedElsewhereTolerance, Int((span / levels).rounded(.up)) + 1)
    }

    private func set(_ characteristic: Characteristic?, _ value: HAPValue) {
        guard let characteristic, characteristic.value != value else { return }
        characteristic.value = value
    }

    // MARK: HomeKit's writes

    /// A change from HomeKit: a slider's only when no later one came within `slider`, then gathered with the others of
    /// the moment into one command.
    func write(_ change: LightChangeBatcher.Change) async throws {
        let slider: String? = switch change {
        case .brightness: "brightness"
        case .hue: "hue"
        case .saturation: "saturation"
        case .mirek: "mirek"
        case .on: nil
        }
        if let slider, !(await sliders(slider)) { return }
        guard let batcher else { return }
        try await batcher.set(change)
    }

    /// One command for a moment's changes (section 5.2): the power alone when no level changed or the light is off,
    /// else the levels, after `71 23 0F` on the devices that need it.
    func flush(_ changes: LightChangeBatcher.Changes) async throws {
        if let on = changes.on { light.isOn = on }
        if let brightness = changes.brightness { light.brightness = min(max(brightness, 0), 100) }
        if let hue = changes.hue { light.hue = min(max(hue, 0), 360); light.showsWhite = false }
        if let saturation = changes.saturation { light.saturation = min(max(saturation, 0), 100); light.showsWhite = false }
        if let mireds = changes.mirek {
            light.mireds = min(max(mireds, MagicHomeColour.miredRange.lowerBound), MagicHomeColour.miredRange.upperBound)
            light.showsWhite = true
        }
        let levelsChanged = levelsWaiting || changes.brightness != nil || changes.hue != nil || changes.saturation != nil || changes.mirek != nil
        // Adaptive Lighting's white for a light that is off waits for it to be on, rather than sending it off again.
        if !light.isOn, changes.on == nil, changes.brightness == nil, changes.hue == nil, changes.saturation == nil {
            levelsWaiting = true
            return
        }
        if light.isOn { levelsWaiting = false }
        // A command of HomeKit's ends the flash (which then leaves the light as it is).
        identifying?.cancel()
        identifying = nil
        var frames: [MagicHomeOutgoing]
        if !levelsChanged || !light.isOn || profile.writer == .powerOnly {
            frames = [power(light.isOn)]
        } else {
            frames = MagicHomeLevels.frames(for: light, profile: profile, effects: options.effects)
            if profile.needsPowerOnFirst(module: record.module), !frames.isEmpty {
                frames[0].delay = max(frames[0].delay, options.timing.powerToLevels)
                frames.insert(power(true), at: 0)
            }
        }
        lastWrite = .now
        log.debug("\(name): \(changes)")
        log.trace("\(name): sending \(frames.map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") })")
        do {
            try await connection.send(frames)
        } catch {
            log.debug("\(name) did not take the command: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        wake()
    }

    private func power(_ on: Bool) -> MagicHomeOutgoing {
        MagicHomeOutgoing(bytes: MagicHomeFrame.power(on), wrapVersion: profile.family.wrapsRequests ? 1 : nil)
    }

    // MARK: Identify

    /// Flashes the light without holding up HomeKit's request (section 5.6), then shows what it showed before. A
    /// switch is not toggled: what it powers may not like it.
    func identify() {
        log.info("Identifying accessory \(name)")
        guard profile.writer != .powerOnly, identifying == nil else { return }
        identifying = Task { [weak self] in await self?.flash() }
    }

    private func flash() async {
        let saved = light
        var flashing = light
        flashing.hue = 100
        flashing.saturation = 100
        flashing.showsWhite = false
        do {
            if !saved.isOn { try await connection.send([power(true)]) }
            for tick in 0..<options.timing.identifyTicks {
                try Task.checkCancellation()
                // The flash is not a reading: polls and pushes meanwhile are not shown, nor end Adaptive Lighting.
                lastWrite = .now
                flashing.brightness = tick.isMultiple(of: 2) ? 0 : 100
                try await connection.send(MagicHomeLevels.frames(for: flashing, profile: profile, effects: options.effects))
                try await Task.sleep(for: options.timing.identifyStep)
            }
            try Task.checkCancellation()
            try await connection.send(MagicHomeLevels.frames(for: saved, profile: profile, effects: options.effects) + (saved.isOn ? [] : [power(false)]))
        } catch is CancellationError {
        } catch {
            log.debug("\(name) did not take the identify flash: \(error)")
        }
        lastWrite = .now
        identifying = nil
        wake()
    }
}
