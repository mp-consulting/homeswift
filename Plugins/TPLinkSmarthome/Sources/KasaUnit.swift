import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// How the plugin reaches a device: its transport, one command at a time per host, and the block's options.
struct KasaLink: Sendable {
    var transport: any KasaTransport
    var queues: KasaHostQueues
    var udp: Bool
    var timeout: Duration?

    func send(_ request: KasaRequest, host: String, port: Int, logger: Logger) async throws -> JSONValue {
        let json = request.json
        logger.trace("Sending \(json) to \(host):\(port)")
        let transport = transport, udp = udp, timeout = timeout
        let response: String
        do {
            response = try await queues.run(host: host) { try await transport.send(json, host: host, port: port, udp: udp, timeout: timeout) }
        } catch {
            throw KasaSendError(transport: udp ? "UDP" : "TCP", host: host, port: port, underlying: error)
        }
        logger.trace("\(host):\(port) answered \(KasaLog.masked(response))")
        return try request.result(of: response)
    }
}

struct KasaSendError: Error, CustomStringConvertible {
    var transport: String
    var host: String
    var port: Int
    var underlying: any Error
    var description: String { "\(transport) \(host):\(port): \(underlying)" }
}

enum KasaLog {
    /// A raw sysinfo with its location left out (`latitude_i`, `longitude_i`, `latitude`, `longitude`).
    static func masked(_ text: String) -> String {
        text.replacingOccurrences(of: #""(latitude|longitude)(_i)?":-?[0-9.]+"#, with: #""$1$2":"…""#, options: .regularExpression)
    }
}

/// What an accessory shows of its device (section 4.4 and 4.5).
enum KasaPresentation: String, Sendable {
    case outlet, `switch`, dimmer, bulb

    /// The Device Kind of Setup and Accessory Settings.
    var deviceKind: String {
        switch self {
        case .outlet: "outlet"
        case .switch: "switch"
        case .dimmer, .bulb: "light"
        }
    }

    static func of(_ sysinfo: KasaSysinfo, switchModels: [String]) -> KasaPresentation {
        guard sysinfo.kind == .plug else { return .bulb }
        if switchModels.contains(where: { !$0.isEmpty && sysinfo.model.contains($0) }) { return .switch }
        // A strip's outlets are outlets even when the strip dims (none does).
        if sysinfo.isDimmerPlug, sysinfo.children == nil { return .dimmer }
        return .outlet
    }
}

/// The characteristics of an accessory the plugin sets.
struct KasaServices: @unchecked Sendable {
    let primary: Service
    let on: Characteristic
    var outletInUse: Characteristic?
    var brightness: Characteristic?
    var colorTemperature: Characteristic?
    var hue: Characteristic?
    var saturation: Characteristic?
    var volts: Characteristic?
    var amperes: Characteristic?
    var watts: Characteristic?
    var voltAmperes: Characteristic?
    var kilowattHours: Characteristic?
    var miredRange: ClosedRange<Int>
}

/// One accessory and its device: a plug, a switch, a dimmer, a bulb, or one outlet of a strip. Keeps the last sysinfo
/// and energy reading, sends HomeKit's writes (gathered for `waitTimeUpdate`) and shows what the device reports.
actor KasaUnit {
    struct Options: Sendable {
        var inUseThreshold: Double = 0
        /// `waitTimeUpdate`.
        var window: Duration = .milliseconds(100)
        /// One step of a plug's LED blink and of a bulb's flash (identify).
        var identifyStep: Duration = .milliseconds(500)
        /// How long a report may still carry what the bulb had before a write.
        var settling: Duration = .seconds(3)
    }

    /// The Device Id: the device's `deviceId`, or the outlet's full child id.
    let id: String
    /// A strip's outlet: its full child id, which its commands carry.
    let childID: String?
    let presentation: KasaPresentation
    private(set) var host: String
    private(set) var port: Int
    private(set) var sysinfo: KasaSysinfo
    private(set) var energy: KasaEnergyReading?
    let link: KasaLink
    let options: Options
    let logger: Logger
    private var services: KasaServices?
    private var adaptiveLighting: AdaptiveLightingController?
    private var history: EveHistory?
    /// Relay writes (a plug) or light changes (a bulb), gathered for `waitTimeUpdate`.
    private var batcher: LightChangeBatcher?
    private let brightnessGuard: LatestCallGuard
    /// A bulb whose meter answered that it has none is not asked again.
    private(set) var energyUnsupported = false
    private var energyFailing = false
    private var energyRefresh: Task<Void, Never>?

    init(id: String, childID: String?, presentation: KasaPresentation, sysinfo: KasaSysinfo, host: String, port: Int, link: KasaLink, options: Options, logger: Logger) {
        self.id = id
        self.childID = childID
        self.presentation = presentation
        self.sysinfo = sysinfo
        self.host = host
        self.port = port
        self.link = link
        self.options = options
        self.logger = logger
        self.brightnessGuard = LatestCallGuard(delay: options.window)
    }

    /// Attaches the accessory's characteristics; called once, before the accessory goes on the bridge.
    func attach(_ services: KasaServices, adaptiveLighting: AdaptiveLightingController?, history: EveHistory?) {
        self.services = services
        self.adaptiveLighting = adaptiveLighting
        self.history = history
        batcher = LightChangeBatcher(window: options.window) { [weak self] changes in
            try await self?.send(changes)
        }
    }

    var name: String { child?.alias ?? sysinfo.alias }
    var child: KasaSysinfo.Child? { childID.flatMap { id in sysinfo.children?.first { $0.id == id } } }
    var supportsEnergy: Bool { sysinfo.supportsEnergy && !energyUnsupported }

    // MARK: What the device reports

    /// A new sysinfo (a discovery reply): its address and what it shows (section 6.3).
    func update(_ sysinfo: KasaSysinfo, host: String, port: Int) async {
        self.host = host
        self.port = port
        // Most rounds report what the last did: nothing to show.
        let changed = sysinfo != self.sysinfo
        self.sysinfo = sysinfo
        guard let services else { return }
        if sysinfo.kind == .plug {
            guard changed else { return }
            showRelay(on: services)
            if presentation == .dimmer, let brightness = sysinfo.brightness { services.brightness?.value = .int(brightness) }
        } else if let light = sysinfo.lightState {
            if changed { show(light, on: services) }
            // A white or a colour set elsewhere (the Kasa app, a schedule) turns Adaptive Lighting off; not what the
            // bulb still reports of the time before the bridge's own write, so a report that came while it settled is
            // looked at again on the next round.
            if light.onOff == 1, let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive,
               await !(batcher?.isSettling(within: options.settling) ?? false) {
                let mireds = (light.colorTemperature ?? 0) > 0 ? KasaColorTemperature.mireds(kelvin: light.colorTemperature ?? 0, within: services.miredRange) : nil
                adaptiveLighting.disableIfChangedElsewhere(mireds: mireds)
            }
        }
    }

    /// The relay: the outlet's own state for a strip's outlet.
    var relayOn: Bool {
        if childID != nil { return child?.state == 1 }
        return sysinfo.relayState == 1
    }

    /// Outlet In Use: the power above `inUseThreshold` when the device meters it, else the relay.
    var inUse: Bool {
        if sysinfo.supportsEnergy, let watts = energy?.watts { return watts > options.inUseThreshold }
        return relayOn
    }

    private func showRelay(on services: KasaServices) {
        services.on.value = .bool(relayOn)
        services.outletInUse?.value = .bool(inUse)
    }

    /// A bulb's state as pushed (section 4.7): only what it carries; a white shows hue and saturation 0.
    private func show(_ light: KasaLightState, on services: KasaServices) {
        if let on = light.onOff { services.on.value = .bool(on == 1) }
        if let brightness = light.brightness { services.brightness?.value = .int(brightness) }
        if let kelvin = light.colorTemperature, kelvin > 0 {
            services.colorTemperature?.value = .int(KasaColorTemperature.mireds(kelvin: kelvin, within: services.miredRange))
            services.hue?.value = .double(0)
            services.saturation?.value = .double(0)
        } else {
            if let hue = light.hue { services.hue?.value = .double(Double(hue)) }
            if let saturation = light.saturation { services.saturation?.value = .double(Double(saturation)) }
        }
    }

    // MARK: HomeKit's writes

    func setOn(_ on: Bool) async throws {
        logger.info("Setting On to: \(on)", metadata: ["accessory": "\(name)"])
        try await batcher?.set(.on(on))
    }

    func setLight(_ change: LightChangeBatcher.Change) async throws {
        logger.info("Setting \(change)", metadata: ["accessory": "\(name)"])
        try await batcher?.set(change)
    }

    /// A dimmer's brightness: 0 switches it off and keeps the brightness; any other sets it without switching it on.
    func setDimmerBrightness(_ brightness: Int) async throws {
        guard await brightnessGuard() else { return }
        logger.info("Setting Brightness to: \(brightness)", metadata: ["accessory": "\(name)"])
        if brightness <= 0 {
            try await sendRelay(false)
            return
        }
        sysinfo.brightness = brightness
        _ = try await send(KasaRequest(module: "smartlife.iot.dimmer", method: "set_brightness", [("brightness", .int(brightness))]))
        services?.brightness?.value = .int(brightness)
    }

    private func send(_ changes: LightChangeBatcher.Changes) async throws {
        if presentation == .bulb {
            try await sendLight(changes)
        } else if let on = changes.on {
            try await sendRelay(on)
        }
    }

    private func sendRelay(_ on: Bool) async throws {
        _ = try await send(KasaRequest(module: "system", method: "set_relay_state", [("state", .int(on ? 1 : 0))], childID: childID))
        if let childID, let index = sysinfo.children?.firstIndex(where: { $0.id == childID }) {
            sysinfo.children?[index].state = on ? 1 : 0
        } else {
            sysinfo.relayState = on ? 1 : 0
        }
        if let services { showRelay(on: services) }
    }

    /// One command for a moment's changes: a hue or a saturation is a colour (`color_temp` 0), a white a kelvin.
    private func sendLight(_ changes: LightChangeBatcher.Changes) async throws {
        var parameters: [(String, KasaRequest.Parameter)] = [("ignore_default", .int(1))]
        if let on = changes.on { parameters.append(("on_off", .int(on ? 1 : 0))) }
        if let hue = changes.hue { parameters.append(("hue", .int(Int(hue.rounded())))) }
        if let saturation = changes.saturation { parameters.append(("saturation", .int(Int(saturation.rounded())))) }
        if let brightness = changes.brightness { parameters.append(("brightness", .int(Int(brightness.rounded())))) }
        if let mireds = changes.mirek {
            parameters.append(("color_temp", .int(KasaColorTemperature.kelvin(mireds: mireds))))
        } else if changes.hue != nil || changes.saturation != nil {
            parameters.append(("color_temp", .int(0)))
        }
        try await sendLightState(parameters)
    }

    private func sendLightState(_ parameters: [(String, KasaRequest.Parameter)]) async throws {
        let request = sysinfo.isLightStrip
            ? KasaRequest(module: "smartlife.iot.lightStrip", method: "set_light_state", parameters)
            : KasaRequest(module: "smartlife.iot.smartbulb.lightingservice", method: "transition_light_state", parameters)
        let reply = KasaLightState(try await send(request))
        // Reads take the sysinfo: what the bulb answered is what it shows now.
        sysinfo.lightState = (sysinfo.lightState ?? KasaLightState()).merging(reply)
        if let services { show(reply, on: services) }
    }

    private func send(_ request: KasaRequest) async throws -> JSONValue {
        try await link.send(request, host: host, port: port, logger: logger)
    }

    // MARK: Energy

    /// Asks the meter for a reading and shows it; a failure is logged once until a reading comes again.
    func refreshEnergy() async {
        guard supportsEnergy else { return }
        let request = sysinfo.kind == .bulb
            ? KasaRequest(module: "smartlife.iot.common.emeter", method: "get_realtime")
            : KasaRequest(module: "emeter", method: "get_realtime", childID: childID)
        let reading: KasaEnergyReading
        do {
            reading = KasaEnergyReading(try await send(request))
        } catch {
            // A bulb without a meter says so: it is not asked again.
            if sysinfo.kind == .bulb, let refused = error as? KasaResponseError, refused.code == -1 || refused.code == -2 {
                energyUnsupported = true
                logger.debug("No energy meter in this bulb", metadata: ["accessory": "\(name)"])
            } else if !energyFailing {
                energyFailing = true
                logger.error("Could not read the energy of \(name): \(error)")
            }
            return
        }
        if energyFailing { logger.info("Reading the energy of \(name) again") }
        energyFailing = false
        energy = reading
        show(reading)
    }

    /// For reads when the energy is not polled: one refresh at a time.
    func refreshEnergyInBackground() {
        guard energyRefresh == nil else { return }
        energyRefresh = Task {
            await refreshEnergy()
            energyRefresh = nil
        }
    }

    /// The plugin stopped: a refresh still waiting for the device goes.
    func cancel() {
        energyRefresh?.cancel()
        energyRefresh = nil
    }

    private func show(_ reading: KasaEnergyReading) {
        guard let services else { return }
        // Rounded to the characteristic's step (0.1 is 1 decimal), within its props.
        func set(_ characteristic: Characteristic?, _ value: Double?, decimals: Double) {
            guard let characteristic, let value, value.isFinite else { return }
            let scale = pow(10, decimals)
            characteristic.value = .double(min(max((value * scale).rounded() / scale, 0), 65535))
        }
        set(services.volts, reading.volts, decimals: 1)
        set(services.amperes, reading.amperes, decimals: 2)
        set(services.watts, reading.watts, decimals: 1)
        set(services.voltAmperes, reading.voltAmperes, decimals: 1)
        set(services.kilowattHours, reading.kilowattHours, decimals: 3)
        services.outletInUse?.value = .bool(inUse)
        if let watts = reading.watts { history?.add(EveHistory.Entry(power: watts)) }
    }

    // MARK: Identify

    func identify() async {
        logger.info("Identify", metadata: ["accessory": "\(name)"])
        do {
            if presentation == .bulb {
                try await flash()
            } else {
                try await blink(times: 1)
                try await blink(times: 2)
            }
        } catch {
            logger.error("Could not identify \(name): \(error)")
        }
    }

    /// The LED on, off, on, off… `2 × times` steps, then as it was (section 6.7).
    private func blink(times: Int) async throws {
        let current = try await send(.sysinfo)
        let wasOn = (current["led_off"]?.intValue ?? 0) == 0
        var on = true
        for _ in 0..<(2 * times) {
            let started = ContinuousClock.now
            _ = try await send(KasaRequest(module: "system", method: "set_led_off", [("off", .int(on ? 0 : 1))]))
            try await Task.sleep(until: started + options.identifyStep / 2)
            on.toggle()
        }
        // `on` is what the next step would have been: the last one left the LED the other way.
        if !on != wasOn {
            _ = try await send(KasaRequest(module: "system", method: "set_led_off", [("off", .int(wasOn ? 0 : 1))]))
        }
    }

    /// Bright, dim, three times, then the light as it was.
    private func flash() async throws {
        let original = sysinfo.lightState ?? KasaLightState()
        for _ in 0..<3 {
            try await sendLight(LightChangeBatcher.Changes(on: true, brightness: 100))
            try await Task.sleep(for: options.identifyStep)
            try await sendLight(LightChangeBatcher.Changes(on: true, brightness: 10))
            try await Task.sleep(for: options.identifyStep)
        }
        // Off, the light it comes back on with is `dft_on_state`.
        let defaults = original.defaultOn
        var parameters: [(String, KasaRequest.Parameter)] = [("ignore_default", .int(1))]
        if let period = original.transitionPeriod { parameters.append(("transition_period", .int(period))) }
        parameters.append(("on_off", .int(original.onOff ?? 0)))
        if let mode = original.mode ?? defaults?.mode { parameters.append(("mode", .string(mode))) }
        if let hue = original.hue ?? defaults?.hue { parameters.append(("hue", .int(hue))) }
        if let saturation = original.saturation ?? defaults?.saturation { parameters.append(("saturation", .int(saturation))) }
        if let brightness = original.brightness ?? defaults?.brightness { parameters.append(("brightness", .int(brightness))) }
        if let kelvin = original.colorTemperature ?? defaults?.colorTemperature { parameters.append(("color_temp", .int(kelvin))) }
        try await sendLightState(parameters)
    }
}
