import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// What a climate device is set to do with the room's temperature (GLOSSARY.md, Climate Mode). Off is its power.
public enum ClimateMode: String, Sendable, CaseIterable, Codable {
    case heat, cool, auto
}

/// What a climate device is doing now (GLOSSARY.md, Action).
public enum ClimateAction: String, Sendable, Equatable {
    case idle, heating, cooling
}

/// How a climate device keeps its temperatures (GLOSSARY.md, Setpoint Kind).
public enum ClimateSetpoints: Sendable, Equatable {
    /// One target for every mode (most air conditioners): `target`. In auto, Apple Home shows the Auto Band around it.
    case single
    /// One target in heat or cool (`target`), a low and a high in auto (`heating` and `cooling`), kept apart.
    case range
    /// A heat-to (`heating`) and a cool-to (`cooling`) temperature kept apart, the heat one used in heat, the cool one
    /// in cool and both in auto; with `autoSetpoint`, the device also has one auto setpoint (`target`), which the
    /// controller keeps at their middle.
    case separate(autoSetpoint: Bool)
}

/// The climate service a device is shown as. An accessory keeps the one it has (docs/adr/0013-climate-is-mapped-once.md).
public enum ClimateServiceKind: Sendable, Equatable {
    /// A Heater Cooler: Active is its power, its modes are auto, heat and cool.
    case heaterCooler
    /// A Thermostat: Off is one of its modes.
    case thermostat
}

/// What a climate device can do: what the controller offers Apple Home.
public struct ClimateCapabilities: Sendable, Equatable {
    /// What a setpoint written while the device is off does.
    public enum WhileOff: Sendable, Equatable {
        /// Sent at once: the device keeps it for when it is on again.
        case sends
        /// Held, shown, and sent with the next turn-on: the device refuses setpoints while it is off.
        case holds
    }

    /// The Climate Modes the device has; heat alone for a heater.
    public var modes: Set<ClimateMode>
    public var setpoints: ClimateSetpoints
    /// The temperatures the device takes in heat, and in auto for the low end, in °C.
    public var heatingRange: ClosedRange<Double>
    /// The temperatures the device takes in cool, and in auto for the high end, in °C.
    public var coolingRange: ClosedRange<Double>
    /// The device's step, in °C.
    public var step: Double
    /// Whether a Thermostat offers Off (a Heater Cooler is always turned off by Active).
    public var canTurnOff: Bool
    public var whileOff: WhileOff
    /// The Auto Band's width, in °C, for a Single setpoint device in auto.
    public var autoBand: Double

    /// `range` is the device's for every mode unless `heatingRange` or `coolingRange` say otherwise.
    public init(
        modes: Set<ClimateMode>,
        setpoints: ClimateSetpoints = .single,
        range: ClosedRange<Double> = 10...30,
        heatingRange: ClosedRange<Double>? = nil,
        coolingRange: ClosedRange<Double>? = nil,
        step: Double = 0.5,
        canTurnOff: Bool = true,
        whileOff: WhileOff = .sends,
        autoBand: Double = 2
    ) {
        precondition(!modes.isEmpty, "A climate device has at least one Climate Mode")
        self.modes = modes
        self.setpoints = setpoints
        self.heatingRange = heatingRange ?? range
        self.coolingRange = coolingRange ?? range
        self.step = step > 0 ? step : 0.5
        self.canTurnOff = canTurnOff
        self.whileOff = whileOff
        self.autoBand = autoBand
    }

    /// The temperatures a Single target or a Thermostat's Target Temperature takes: both ranges.
    var targetRange: ClosedRange<Double> {
        min(heatingRange.lowerBound, coolingRange.lowerBound)...max(heatingRange.upperBound, coolingRange.upperBound)
    }
}

/// A climate device's state, as its plugin reads it. Temperatures in °C; nil where the device did not say.
public struct ClimateReport: Sendable, Equatable {
    public var power: Bool
    /// Its Climate Mode, nil in an Other Mode (dry, fan only, eco): the target then stays as it was.
    public var mode: ClimateMode?
    /// What it does now, nil when it does not say: the controller then guesses from the room and the setpoints.
    public var action: ClimateAction?
    /// The room's temperature.
    public var current: Double?
    /// A Single or Range device's target; a Separate device's auto setpoint.
    public var target: Double?
    /// A Separate device's heat-to; a Range device's low.
    public var heating: Double?
    /// A Separate device's cool-to; a Range device's high.
    public var cooling: Double?

    public init(power: Bool, mode: ClimateMode?, action: ClimateAction? = nil, current: Double? = nil,
                target: Double? = nil, heating: Double? = nil, cooling: Double? = nil) {
        self.power = power
        self.mode = mode
        self.action = action
        self.current = current
        self.target = target
        self.heating = heating
        self.cooling = cooling
    }
}

/// What Apple Home asks the device to do: only what changes. Temperatures in °C, on the device's step and in its ranges.
public struct ClimateCommand: Sendable, Equatable {
    /// Turn it on or off. Never set by a Heater Cooler's mode or setpoint writes (ADR 0013, rule 4).
    public var power: Bool?
    public var mode: ClimateMode?
    /// A Single or Range device's target; a Separate device's auto setpoint.
    public var target: Double?
    /// A Separate device's heat-to; a Range device's low (sent with `cooling`).
    public var heating: Double?
    /// A Separate device's cool-to; a Range device's high (sent with `heating`).
    public var cooling: Double?

    public init(power: Bool? = nil, mode: ClimateMode? = nil, target: Double? = nil, heating: Double? = nil, cooling: Double? = nil) {
        self.power = power
        self.mode = mode
        self.target = target
        self.heating = heating
        self.cooling = cooling
    }

    public var isEmpty: Bool { self == ClimateCommand() }
    var hasSetpoints: Bool { target != nil || heating != nil || cooling != nil }
}

/// A thermostat or air conditioner's Heater Cooler or Thermostat service, mapped the same way for every plugin
/// (docs/adr/0013-climate-is-mapped-once.md). The plugin gives the device's capabilities and a closure that sends a
/// `ClimateCommand`, adds `service` to its accessory and reports the device's state with `update(_:)`; the controller
/// owns the service's Active, states, Target Temperature and thresholds, and the plugin binds none of them.
///
/// ```swift
/// let climate = ClimateController(.heaterCooler, name: name, isPrimary: true,
///     capabilities: ClimateCapabilities(modes: [.heat, .cool, .auto], range: 16...30, whileOff: .holds),
///     optional: [.rotationSpeed]) { command in try await unit.send(command) }
/// accessory.addService(climate.service)
/// unit.onChange { state in climate.update(ClimateReport(power: state.on, mode: state.mode, current: state.room, target: state.target)) }
/// ```
///
/// The Home app writes Active, the mode and both thresholds of one change at once: they reach `apply` as one command
/// after `window`, every write waiting for it, and a command that fails puts the service back as the device last
/// reported it and fails the writes.
public final class ClimateController: Sendable {
    public let service: Service
    public let kind: ClimateServiceKind
    public let capabilities: ClimateCapabilities

    /// How long writes are gathered: the Home app's writes of one change arrive within a few milliseconds.
    public static let defaultWindow = Duration.milliseconds(30)

    private let window: Duration
    private let apply: @Sendable (ClimateCommand) async throws -> Void
    private let state = NIOLockedValueBox(State())
    /// One command at a time, each built from the device's state after the one before it.
    private let commands = SerialTasks()

    /// What a write asks, gathered until the window closes.
    struct Pending: Equatable {
        var power: Bool?
        var mode: ClimateMode?
        var targetTemperature: Double?
        var heatingThreshold: Double?
        var coolingThreshold: Double?
    }

    private struct State {
        /// The device's state as last reported, with the commands sent since applied to it.
        var report: ClimateReport?
        /// The mode Apple Home shows: the last Climate Mode, kept through Other Modes and power off.
        var shownMode: ClimateMode?
        /// The Auto Band last written, while its middle is the target (Single setpoint).
        var band: (low: Double, high: Double)?
        /// Setpoints written while off, for the next turn-on (`WhileOff.holds`).
        var held = ClimateCommand()
        var pending = Pending()
        var batch: Task<Void, any Error>?
    }

    /// Builds the service. `optional` and `extra` add the plugin's own characteristics (Rotation Speed, Swing Mode, Name,
    /// a display unit's props); one of a type the controller has replaces its props.
    public init(
        _ kind: ClimateServiceKind,
        name: String? = nil,
        subtype: String? = nil,
        isPrimary: Bool = false,
        capabilities: ClimateCapabilities,
        optional: [CharacteristicType] = [],
        extra: [Characteristic] = [],
        linked: [Service] = [],
        window: Duration = defaultWindow,
        apply: @escaping @Sendable (ClimateCommand) async throws -> Void
    ) {
        self.kind = kind
        self.capabilities = capabilities
        self.window = window
        self.apply = apply
        let types = Self.characteristicTypes(kind, capabilities)
        service = Service(kind == .heaterCooler ? .heaterCooler : .thermostat, name: name, subtype: subtype,
                          optional: types + optional, extra: extra, linked: linked, isPrimary: isPrimary)
        let initialMode = Self.preferredMode(capabilities.modes)
        state.withLockedValue { $0.shownMode = initialMode }
        bind()
        show()
    }

    // MARK: The service

    /// The controller's characteristics, with the props the capabilities give.
    static func characteristicTypes(_ kind: ClimateServiceKind, _ capabilities: ClimateCapabilities) -> [CharacteristicType] {
        let modes = capabilities.modes
        let step = capabilities.step
        var types: [CharacteristicType] = []
        let heats = modes.contains(.heat) || modes.contains(.auto)
        let cools = modes.contains(.cool) || modes.contains(.auto)
        let heating = capabilities.setpoints == .single ? capabilities.targetRange : capabilities.heatingRange
        let cooling = capabilities.setpoints == .single ? capabilities.targetRange : capabilities.coolingRange
        switch kind {
        case .heaterCooler:
            let valid = [ClimateMode.auto, .heat, .cool].filter(modes.contains).map(Self.heaterCoolerValue)
            types.append(.targetHeaterCoolerState.with(validValues: valid))
            if heats { types.append(.heatingThresholdTemperature.with(minValue: heating.lowerBound, maxValue: heating.upperBound, minStep: step)) }
            if cools { types.append(.coolingThresholdTemperature.with(minValue: cooling.lowerBound, maxValue: cooling.upperBound, minStep: step)) }
        case .thermostat:
            var valid = capabilities.canTurnOff ? [0] : []
            valid += [ClimateMode.heat, .cool, .auto].filter(modes.contains).map(Self.thermostatValue)
            types.append(.targetHeatingCoolingState.with(validValues: valid))
            types.append(.currentHeatingCoolingState.with(validValues: cools ? [0, 1, 2] : [0, 1]))
            let target = capabilities.targetRange
            types.append(.targetTemperature.with(minValue: target.lowerBound, maxValue: target.upperBound, minStep: step))
            if modes.contains(.auto) {
                types.append(.heatingThresholdTemperature.with(minValue: heating.lowerBound, maxValue: heating.upperBound, minStep: step))
                types.append(.coolingThresholdTemperature.with(minValue: cooling.lowerBound, maxValue: cooling.upperBound, minStep: step))
            }
        }
        return types
    }

    static func heaterCoolerValue(_ mode: ClimateMode) -> Int { mode == .auto ? 0 : mode == .heat ? 1 : 2 }
    static func thermostatValue(_ mode: ClimateMode) -> Int { mode == .heat ? 1 : mode == .cool ? 2 : 3 }

    /// The mode shown before the device has said: heat, else cool, else auto.
    static func preferredMode(_ modes: Set<ClimateMode>) -> ClimateMode {
        modes.contains(.heat) ? .heat : modes.contains(.cool) ? .cool : .auto
    }

    private func bind() {
        if kind == .heaterCooler {
            service[.active]?.onWrite { [weak self] value in try await self?.write { $0.power = value.intValue == 1 } }
            service[.targetHeaterCoolerState]?.onWrite { [weak self] value in
                let mode: ClimateMode = value.intValue == 1 ? .heat : value.intValue == 2 ? .cool : .auto
                try await self?.write { $0.mode = mode }
            }
        } else {
            service[.targetHeatingCoolingState]?.onWrite { [weak self] value in
                switch value.intValue ?? 0 {
                case 0: try await self?.write { $0.power = false }
                case let number: try await self?.write { $0.mode = number == 1 ? .heat : number == 2 ? .cool : .auto }
                }
            }
            service[.targetTemperature]?.onWrite { [weak self] value in
                guard let temperature = value.doubleValue else { return }
                try await self?.write { $0.targetTemperature = temperature }
            }
        }
        service[.heatingThresholdTemperature]?.onWrite { [weak self] value in
            guard let temperature = value.doubleValue else { return }
            try await self?.write { $0.heatingThreshold = temperature }
        }
        service[.coolingThresholdTemperature]?.onWrite { [weak self] value in
            guard let temperature = value.doubleValue else { return }
            try await self?.write { $0.coolingThreshold = temperature }
        }
    }

    // MARK: The device to Apple Home

    /// The device's state as its plugin last reported it, with the commands sent since.
    public var report: ClimateReport? { state.withLockedValue { $0.report } }

    /// Shows the device's state. Call it with every state the device reports; held setpoints go out when it turns on.
    public func update(_ report: ClimateReport) {
        let turnedOnWithHeld = state.withLockedValue { state in
            let wasOff = state.report.map { !$0.power } ?? false
            state.report = report
            if let mode = report.mode { state.shownMode = mode }
            if let band = state.band, report.mode != .auto || !(abs(Self.middle(band.low, band.high) - (report.target ?? .nan)) <= capabilities.step / 2) {
                state.band = nil
            }
            return wasOff && report.power && !state.held.isEmpty
        }
        show()
        // Turned on elsewhere (its remote, its app): the setpoints held for it go out now, kept again if that fails.
        if turnedOnWithHeld {
            Task { [weak self] in
                guard let self else { return }
                try? await commands.run { [self] in
                    let held = takeHeld()
                    guard self.report?.power == true, !held.isEmpty else { return restoreHeld(held) }
                    do { try await send(held) } catch { restoreHeld(held) }
                }
                show()
            }
        }
    }

    /// The held setpoints, no longer held: sending them.
    private func takeHeld() -> ClimateCommand {
        state.withLockedValue { state in
            defer { state.held = ClimateCommand() }
            return state.held
        }
    }

    /// Holds setpoints again after their send failed, under any written since.
    private func restoreHeld(_ held: ClimateCommand) {
        state.withLockedValue { state in
            state.held.target = state.held.target ?? held.target
            state.held.heating = state.held.heating ?? held.heating
            state.held.cooling = state.held.cooling ?? held.cooling
        }
    }

    /// Sets every characteristic from the report, the held setpoints and the band.
    private func show() {
        let (report, mode, band, held) = state.withLockedValue { ($0.report, $0.shownMode ?? .heat, $0.band, $0.held) }
        guard var report else { return }
        // Held setpoints are what the person asked for: shown until they are sent.
        if let target = held.target { report.target = target }
        if let heating = held.heating { report.heating = heating }
        if let cooling = held.cooling { report.cooling = cooling }
        let shown = setpoints(report, mode: mode, band: band)
        if let current = report.current { set(.currentTemperature, .double(current)) }
        switch kind {
        case .heaterCooler:
            set(.active, .int(report.power ? 1 : 0))
            set(.targetHeaterCoolerState, .int(Self.heaterCoolerValue(mode)))
            let action = action(report, mode: report.mode, low: shown.low, high: shown.high, target: shown.target)
            set(.currentHeaterCoolerState, .int(!report.power ? 0 : action == .heating ? 2 : action == .cooling ? 3 : 1))
        case .thermostat:
            set(.targetHeatingCoolingState, .int(report.power ? Self.thermostatValue(mode) : 0))
            let action = action(report, mode: report.mode, low: shown.low, high: shown.high, target: shown.target)
            set(.currentHeatingCoolingState, .int(!report.power ? 0 : action == .heating ? 1 : action == .cooling ? 2 : 0))
            if let target = shown.target { set(.targetTemperature, .double(target)) }
        }
        if let low = shown.low { set(.heatingThresholdTemperature, .double(low)) }
        if let high = shown.high { set(.coolingThresholdTemperature, .double(high)) }
    }

    /// The temperatures Apple Home shows: the thresholds and a Thermostat's Target Temperature, in `mode`.
    func setpoints(_ report: ClimateReport, mode: ClimateMode, band: (low: Double, high: Double)?) -> (target: Double?, low: Double?, high: Double?) {
        switch capabilities.setpoints {
        case .single:
            guard let target = report.target else { return (nil, nil, nil) }
            guard mode == .auto else { return (target, target, target) }
            if let band { return (target, band.low, band.high) }
            let half = capabilities.autoBand / 2
            return (target, rounded(target - half, in: capabilities.targetRange), rounded(target + half, in: capabilities.targetRange))
        case .range:
            let low = report.heating ?? report.target, high = report.cooling ?? report.target
            switch mode {
            case .heat: return (report.target, report.target ?? low, high)
            case .cool: return (report.target, low, report.target ?? high)
            case .auto: return (low.flatMap { low in high.map { Self.middle(low, $0) } } ?? report.target, low, high)
            }
        case .separate:
            let low = report.heating, high = report.cooling
            switch mode {
            case .heat: return (low, low, high)
            case .cool: return (high, low, high)
            case .auto: return (report.target ?? low.flatMap { low in high.map { Self.middle(low, $0) } }, low, high)
            }
        }
    }

    /// What the device does: what it says, else what its mode, setpoints and room make likely (at least half a degree away).
    func action(_ report: ClimateReport, mode: ClimateMode?, low: Double?, high: Double?, target: Double?) -> ClimateAction {
        guard report.power else { return .idle }
        if let action = report.action { return action }
        guard let mode, let current = report.current else { return .idle }
        let tolerance = 0.5
        switch mode {
        case .heat:
            return (low ?? target).map { current <= $0 - tolerance ? .heating : .idle } ?? .idle
        case .cool:
            return (high ?? target).map { current >= $0 + tolerance ? .cooling : .idle } ?? .idle
        case .auto:
            if let low, current <= low - tolerance { return .heating }
            if let high, current >= high + tolerance { return .cooling }
            return .idle
        }
    }

    /// Sets a characteristic the service has to a value it takes, clamped into its bounds.
    private func set(_ type: CharacteristicType, _ value: HAPValue) {
        guard let characteristic = service[type] else { return }
        var value = value
        if case .double(let number) = value {
            let bounds = characteristic.type
            value = .double(min(bounds.maxValue ?? number, max(bounds.minValue ?? number, number)))
        }
        guard let coerced = characteristic.type.coerce(value) else { return }
        characteristic.value = coerced
    }

    // MARK: Apple Home to the device

    /// Adds a write to the gathered command and waits for it to be sent.
    private func write(_ change: (inout Pending) -> Void) async throws {
        let task: Task<Void, any Error> = state.withLockedValue { state in
            change(&state.pending)
            if let batch = state.batch { return batch }
            let batch = Task { [weak self, window] in
                try await Task.sleep(for: window)
                try await self?.flush()
            }
            state.batch = batch
            return batch
        }
        try await task.value
    }

    private func flush() async throws {
        let pending = state.withLockedValue { state in
            defer {
                state.pending = Pending()
                state.batch = nil
            }
            return state.pending
        }
        try await commands.run { [self] in try await process(pending) }
    }

    /// Builds the command a moment's writes make from the device's state now, and sends it.
    private func process(_ pending: Pending) async throws {
        let (report, shownMode, band) = state.withLockedValue { ($0.report, $0.shownMode ?? .heat, $0.band) }
        let (command, newBand) = command(for: pending, report: report, shownMode: shownMode, band: band)
        var toSend = command
        let isOff = !(command.power ?? report?.power ?? true)
        let holds = capabilities.whileOff == .holds && isOff && command.hasSetpoints
        var taken = ClimateCommand()
        if holds {
            toSend.target = nil
            toSend.heating = nil
            toSend.cooling = nil
        } else if command.power == true {
            taken = takeHeld()
            toSend.target = toSend.target ?? taken.target
            toSend.heating = toSend.heating ?? taken.heating
            toSend.cooling = toSend.cooling ?? taken.cooling
        }
        do {
            try await send(toSend)
        } catch {
            restoreHeld(taken)
            show()
            throw error
        }
        state.withLockedValue { state in
            if holds {
                state.held.target = command.target ?? state.held.target
                state.held.heating = command.heating ?? state.held.heating
                state.held.cooling = command.cooling ?? state.held.cooling
            }
            if let newBand { state.band = newBand }
            // The mode Apple Home asked for, sent (or already the device's).
            if let mode = pending.mode { state.shownMode = mode }
        }
        show()
    }

    /// Sends a command and applies it to the report, so the next writes start from it.
    private func send(_ command: ClimateCommand) async throws {
        guard !command.isEmpty else { return }
        try await apply(command)
        state.withLockedValue { state in
            guard var report = state.report else { return }
            if let power = command.power { report.power = power }
            if let mode = command.mode { report.mode = mode }
            if let target = command.target { report.target = target }
            if let heating = command.heating { report.heating = heating }
            if let cooling = command.cooling { report.cooling = cooling }
            state.report = report
        }
    }

    /// The command a moment's writes make, and the Auto Band they set.
    func command(for pending: Pending, report: ClimateReport?, shownMode: ClimateMode, band: (low: Double, high: Double)?)
        -> (ClimateCommand, (low: Double, high: Double)?) {
        var command = ClimateCommand()
        var newBand: (low: Double, high: Double)?
        let isOn = report?.power ?? false
        switch kind {
        case .heaterCooler:
            if let power = pending.power, power != isOn || report == nil { command.power = power }
        case .thermostat:
            // A Thermostat's power is its Off mode: Off turns it off, another mode turns it on.
            if pending.power == false {
                if isOn || report == nil { command.power = false }
            } else if pending.mode != nil, !isOn {
                command.power = true
            }
        }
        // Compared with the device's mode, not Apple Home's: auto while in dry must still be sent. A turn-on carries the
        // mode chosen, whatever the device last said while off.
        if let mode = pending.mode, mode != report?.mode || report == nil || command.power == true { command.mode = mode }
        let mode = pending.mode ?? shownMode
        let report = report ?? ClimateReport(power: isOn, mode: nil)
        let shown = setpoints(report, mode: mode, band: band)
        let heating = pending.heatingThreshold.map { rounded($0, in: thresholdRange(heating: true)) }
        let cooling = pending.coolingThreshold.map { rounded($0, in: thresholdRange(heating: false)) }
        var target = pending.targetTemperature.map { rounded($0, in: capabilities.targetRange) }
        // A Thermostat's Target Temperature in auto moves the range, keeping its width.
        var low = heating, high = cooling
        if mode == .auto, let moved = target, let shownLow = shown.low, let shownHigh = shown.high {
            let half = (shownHigh - shownLow) / 2
            low = low ?? rounded(moved - half, in: thresholdRange(heating: true))
            high = high ?? rounded(moved + half, in: thresholdRange(heating: false))
            target = nil
        }
        switch capabilities.setpoints {
        case .single:
            if mode == .auto, low != nil || high != nil {
                let range = (low ?? shown.low ?? report.target ?? 0, high ?? shown.high ?? report.target ?? 0)
                command.target = rounded(Self.middle(range.0, range.1), in: capabilities.targetRange)
                newBand = (min(range.0, range.1), max(range.0, range.1))
            } else if let value = target ?? (mode == .cool ? high ?? low : low ?? high) {
                command.target = value
            }
        case .range:
            if mode == .auto, low != nil || high != nil {
                command.heating = low ?? shown.low
                command.cooling = high ?? shown.high
            } else if let value = target ?? (mode == .cool ? high ?? low : low ?? high) {
                command.target = value
            }
        case .separate(let autoSetpoint):
            // Each end in its own range: Target Temperature takes both ranges.
            if let target {
                if mode == .cool { high = rounded(target, in: capabilities.coolingRange) } else { low = rounded(target, in: capabilities.heatingRange) }
            }
            command.heating = low
            command.cooling = high
            if autoSetpoint, low != nil || high != nil, let middleLow = low ?? report.heating, let middleHigh = high ?? report.cooling {
                command.target = rounded(Self.middle(middleLow, middleHigh), in: capabilities.targetRange)
            }
        }
        // Unchanged setpoints are not sent again; a Range device takes its low and high together.
        if command.target == report.target { command.target = nil }
        if capabilities.setpoints == .range {
            if command.heating != nil || command.cooling != nil {
                let low = command.heating ?? report.heating, high = command.cooling ?? report.cooling
                let unchanged = low == report.heating && high == report.cooling
                command.heating = unchanged ? nil : low
                command.cooling = unchanged ? nil : high
            }
        } else {
            if command.heating == report.heating { command.heating = nil }
            if command.cooling == report.cooling { command.cooling = nil }
        }
        return (command, newBand)
    }

    private func thresholdRange(heating: Bool) -> ClosedRange<Double> {
        capabilities.setpoints == .single ? capabilities.targetRange : heating ? capabilities.heatingRange : capabilities.coolingRange
    }

    /// A temperature on the device's step, inside `range`.
    func rounded(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let step = capabilities.step
        let stepped = (value / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, (stepped * 1000).rounded() / 1000))
    }

    static func middle(_ low: Double, _ high: Double) -> Double { (low + high) / 2 }
}
