import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The pure helpers the cooking and cleaning appliances share (oven, microwave, dishwasher).
enum Cooking {
    nonisolated static let secondsPerMinute = 60.0
    nonisolated static let oneHour = 3600.0
    nonisolated static let maxNameLength = 64
    nonisolated static let truncatedNameLength = 60

    /// A Configured Name under HomeKit's 64 characters.
    nonisolated static func truncateName(_ name: String) -> String {
        name.count >= maxNameLength ? String(name.prefix(truncatedNameLength)) + "..." : name
    }

    /// A finite number from a snapshot value; anything else is 0.
    nonisolated static func toNumber(_ value: JSONValue?) -> Double {
        switch value {
        case .number(let number)?: return number.isFinite ? number : 0
        case .string(let string)? where !string.trimmingCharacters(in: .whitespaces).isEmpty:
            let number = JS.number(string)
            return number.isFinite ? number : 0
        default: return 0
        }
    }

    /// A finite number other than 0.
    nonisolated static func nonZero(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite, number != 0 else { return nil }
        return number
    }

    nonisolated static func includes(_ value: JSONValue?, _ needle: String) -> Bool { value?.stringValue?.contains(needle) ?? false }
    /// A reported string without the needle (a missing value is false).
    nonisolated static func excludes(_ value: JSONValue?, _ needle: String) -> Bool { value?.stringValue.map { !$0.contains(needle) } ?? false }

    nonisolated static func sumTimeFields(_ hours: JSONValue?, _ minutes: JSONValue?, _ seconds: JSONValue? = nil) -> Double {
        toNumber(hours) * oneHour + toNumber(minutes) * secondsPerMinute + toNumber(seconds)
    }

    nonisolated static func sumTimeFields(_ data: [String: JSONValue], prefix: String) -> Double {
        sumTimeFields(data[prefix + "Hour"], data[prefix + "Minute"], data[prefix + "Second"])
    }

    /// `H:MM:SS`, the hour without its leading zero, wrapping at a day like the ISO time it comes from.
    nonisolated static func formatClock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds.rounded(.down) : 0)) % 86_400
        let clock = String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        return clock.hasPrefix("0") ? String(clock.dropFirst()) : clock
    }

    nonisolated static func durationUnit(_ seconds: Double) -> String {
        seconds > oneHour ? "Hours" : seconds == oneHour ? "Hour" : "Minutes"
    }

    /// `1:30:00 Hours`, `0:05:00 Minutes`.
    nonisolated static func formatDuration(_ seconds: Double) -> String { formatClock(seconds) + " " + durationUnit(seconds) }

    /// `Monday, January 1, 2024 at 13:05:00 CET` (long) or `Mon, Jan 1, 2024, 13:05:00 CET` (short), as
    /// `toLocaleString('en-US')` writes them.
    nonisolated static func formatDateTime(_ date: Date, short: Bool = false, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = short ? "EEE, MMM d, yyyy, HH:mm:ss z" : "EEEE, MMMM d, yyyy 'at' HH:mm:ss z"
        let text = formatter.string(from: date)
        // ICU on Apple names UTC "GMT"; Node names it "UTC".
        if ["UTC", "GMT", "Etc/UTC"].contains(timeZone.identifier), text.hasSuffix(" GMT") { return String(text.dropLast(3)) + "UTC" }
        return text
    }

    /// `SOME_VALUE` as `Some_value`; anything but a string is empty.
    nonisolated static func capitalize(_ value: JSONValue?) -> String {
        guard let string = value?.stringValue, let first = string.lowercased().first else { return "" }
        return first.uppercased() + string.lowercased().dropFirst()
    }

    nonisolated static func roundToHalf(_ value: Double) -> Double { 0.5 * (2 * value).rounded(.toNearestOrAwayFromZero) }
    nonisolated static func tempCtoF(_ celsius: Double) -> Double { (celsius * 1.8 + 32).rounded(.toNearestOrAwayFromZero) }
    nonisolated static func tempFtoC(_ fahrenheit: Double) -> Double { roundToHalf((fahrenheit - 32) / 1.8) }
    nonisolated static func isFahrenheit(_ unit: JSONValue?) -> Bool { includes(unit, "FAH") }
    nonisolated static func toCelsius(_ value: Double, _ unit: JSONValue?) -> Double { isFahrenheit(unit) ? tempFtoC(value) : roundToHalf(value) }

    struct TemperatureLimit {
        var modes: [String]
        var fahrenheit: (Double, Double)
        var celsius: (Double, Double)
    }

    nonisolated static let ovenLimits: [TemperatureLimit] = [
        .init(modes: ["CONVECTION_BAKE", "CONVECTION_ROST", "CONVECTION_ROAST", "FROZEN_MEAL", "AIR_FRY"], fahrenheit: (300, 550), celsius: (150, 285)),
        .init(modes: ["BAKE"], fahrenheit: (170, 550), celsius: (80, 285)),
        .init(modes: ["AIR_SOUSVIDE"], fahrenheit: (100, 205), celsius: (38, 96)),
    ]

    nonisolated static let microwaveLimits: [TemperatureLimit] = [
        .init(modes: ["COMBI_BAKE", "CONV_BAKE", "COMBI_ROAST", "OVEN"], fahrenheit: (250, 450), celsius: (125, 230)),
        .init(modes: ["DEHYDRATE"], fahrenheit: (100, 200), celsius: (38, 92)),
    ]

    /// A cook temperature within the range of its mode (the first entry with a matching mode).
    nonisolated static func clampCookTemp(_ limits: [TemperatureLimit], mode: String, unit: JSONValue?, _ temperature: Double) -> Double {
        guard let limit = limits.first(where: { $0.modes.contains { mode.contains($0) } }) else { return temperature }
        let (low, high) = isFahrenheit(unit) ? limit.fahrenheit : limit.celsius
        guard temperature.isFinite else { return low }
        return min(high, max(low, temperature))
    }

    struct Burner {
        var index: Int
        var label: String
        var subtype: String
        var identifier: Int
    }

    /// `Front Left Burner is On. Cooking for 0:05:00 Minutes`.
    nonisolated static func burnerStatus(_ data: [String: JSONValue], _ burner: Burner) -> (name: String, inUse: Bool) {
        let prefix = "cooktop\(burner.index)"
        let state = data[prefix + "CooktopState"]
        if state == nil || state == .null || state?.stringValue == "INIT" { return ("\(burner.label) Burner Not in Use", false) }
        let seconds = sumTimeFields(data, prefix: prefix + "OperationTime")
        let name = seconds != 0 ? "\(burner.label) Burner is On. Cooking for \(formatDuration(seconds))" : "\(burner.label) Burner is On"
        return (truncateName(name), true)
    }

    /// True only on the transition into `target`.
    nonisolated static func enteredState(_ previous: JSONValue?, _ current: JSONValue?, _ target: String) -> Bool {
        current?.stringValue == target && previous?.stringValue != target
    }
}

/// Holds refreshes back while the user composes a command in HomeKit, or right after one was sent; a
/// snapshot that arrives meanwhile is replayed when the pause ends.
@ThinQActor
final class UpdatePauser {
    private(set) var isPaused = false
    private var pending = false
    private let timer = Timeout()
    private let fallback: Duration
    private let onResume: @ThinQActor () -> Void

    init(fallback: Duration = .seconds(120), onResume: @escaping @ThinQActor () -> Void) {
        self.fallback = fallback
        self.onResume = onResume
    }

    func pause(_ duration: Duration? = nil) {
        isPaused = true
        timer.schedule(after: duration ?? fallback) { [weak self] in self?.resume() }
    }

    func markPending() {
        pending = true
        if !timer.isScheduled { timer.schedule(after: fallback) { [weak self] in self?.resume() } }
    }

    func resume() {
        timer.cancel()
        isPaused = false
        if pending {
            pending = false
            onResume()
        }
    }

    func dispose() {
        timer.cancel()
        isPaused = false
        pending = false
    }
}

/// One command at a time: while one is in flight, and a second after it settles, others are dropped.
@ThinQActor
final class CommandGate {
    private(set) var isBusy = false
    private let timer = Timeout()
    private let cooldown: Duration

    init(cooldown: Duration = .seconds(1)) {
        self.cooldown = cooldown
    }

    /// Runs the command unless another is in flight; false when dropped.
    @discardableResult
    func run(_ command: @ThinQActor () async throws -> Void) async throws -> Bool {
        if isBusy { return false }
        isBusy = true
        timer.cancel()
        defer { timer.schedule(after: cooldown) { [weak self] in self?.isBusy = false } }
        try await command()
        return true
    }

    func dispose() {
        timer.cancel()
        isBusy = false
    }
}

/// The Start, Duration, End and Timer lines shown as television inputs: the start is captured once when
/// cooking begins, the others recomputed when their value changes.
struct CookTimeTracker {
    struct Labels {
        var start: String
        var cookTime: String
        var end: String
        var timer: String
    }

    let defaults: Labels
    var startString: String
    var cookTimeString: String
    var endString: String
    var timerString: String
    var showTime = false
    var showTimer = false
    private var startPending = true
    private var lastDuration = 0.0
    private var lastTimer = 0.0

    init(_ defaults: Labels) {
        self.defaults = defaults
        startString = defaults.start
        cookTimeString = defaults.cookTime
        endString = defaults.end
        timerString = defaults.timer
    }

    mutating func update(cooking: Bool, targetSeconds: Double, timerSeconds: Double, now: Date = Date()) {
        if cooking {
            if startPending {
                startString = "Start: " + Cooking.formatDateTime(now)
                startPending = false
            }
            showTime = true
        } else {
            startPending = true
            showTime = false
            startString = defaults.start
        }
        if targetSeconds != 0 {
            if targetSeconds != lastDuration {
                lastDuration = targetSeconds
                cookTimeString = "Duration: " + Cooking.formatDuration(targetSeconds)
                endString = "End: " + Cooking.formatDateTime(now.addingTimeInterval(targetSeconds))
            }
            showTime = true
        } else {
            lastDuration = 0
            cookTimeString = defaults.cookTime
            endString = defaults.end
        }
        if timerSeconds != 0 {
            if timerSeconds != lastTimer {
                lastTimer = timerSeconds
                timerString = "Timer: " + Cooking.formatDuration(timerSeconds)
            }
            showTimer = true
        } else {
            lastTimer = 0
            showTimer = false
            timerString = defaults.timer
        }
    }
}

/// The status boards of the oven, the microwave and the dishwasher: a Television whose inputs are lines of text.
extension BaseDevice {
    /// The board, not primary, always discoverable; picking an identifier outside `1...inputs` picks the first.
    func createTelevision(name: String, subtype: String, configuredName: String, inputs: Int, identifierLabel: String = "ActiveIdentifier") -> Service {
        let television = Service(.television, name: name, subtype: subtype)
        television.set(.configuredName, configuredName)
        television.set(.sleepDiscoveryMode, 1)
        television.set(.activeIdentifier, activeInput)
        television.characteristic(.activeIdentifier).onSet { [weak self] value in
            guard let self else { return }
            guard let identifier = Normalize.number(value) else {
                logger.error("\(identifierLabel) is not a number")
                return
            }
            activeInput = identifier > Double(inputs) || identifier < 1 ? 1 : Int(identifier)
        }.onGet { [weak self] in .int(self?.activeInput ?? 1) }
        return append(television)
    }

    /// An input of the board whose Configured Name is a line of status.
    func createInputSource(_ television: Service, name: String, subtype: String, identifier: Int, shown: Bool,
                           getName: @escaping @ThinQActor @Sendable () -> String) -> Service {
        let input = Service(.inputSource, name: name, subtype: subtype, optional: [.identifier, .targetVisibilityState])
        input.set(.identifier, identifier)
        input.set(.configuredName, getName())
        input.set(.isConfigured, 1)
        input.set(.inputSourceType, 10)
        input.set(.targetVisibilityState, shown ? 0 : 1)
        input.set(.currentVisibilityState, shown ? 0 : 1)
        input.characteristic(.configuredName).onGet { .string(getName()) }
        television.linked.append(input)
        return append(input)
    }

    func setVisibility(_ service: Service, _ shown: Bool) {
        service.set(.targetVisibilityState, shown ? 0 : 1)
        service.set(.currentVisibilityState, shown ? 0 : 1)
    }
}

/// The oven and the microwave (thanks to carlosgamezvillegas for the Homebridge versions): a status board whose
/// inputs read out the appliance, valves for the cook time and the kitchen timer, mode switches, Start and Stop,
/// and a thermostat. A cook is composed in HomeKit (mode, temperature, duration) and sent with Start; refreshes
/// wait while the user composes one and right after a command. The subclasses add their own services, build
/// them in their order with the helpers here, and send their cook.
class CookingAppliance: BaseDevice {
    nonisolated static let minTargetC = 38.0
    nonisolated static let ambientC = 22.0
    nonisolated static let ambientHumidity = 50.0
    nonisolated static let commandSettle: Duration = .seconds(10)
    nonisolated static let userEditPause: Duration = .seconds(120)

    struct ModeDefinition {
        var name: String
        var subtype: String
        /// The cook name sent.
        var mode: String
        /// Other names the appliance reports for it.
        var aliases: [String] = []
    }

    /// `Oven`, `Microwave`: in the logs.
    class var appliance: String { "" }
    /// Where the status keys start: `upper`, `LWO`.
    class var statusPrefix: String { "" }
    /// Whether the timer command carries hours (the oven) or minutes only (the microwave).
    class var timerHasHours: Bool { false }
    class var cookTimeLabels: CookTimeTracker.Labels { .init(start: "", cookTime: "", end: "", timer: "") }

    lazy var cookTimes = CookTimeTracker(Self.cookTimeLabels)
    var timerAlarmSec = 0.0
    /// An unsent selection in HomeKit.
    var userSelectionPending = false
    /// A target temperature (°C) chosen in HomeKit and not sent yet.
    var userTargetTemperature: Double?
    private(set) var pauser: UpdatePauser!
    let commandGate = CommandGate(cooldown: .seconds(1))

    var ovenService: Service!
    var ovenState: Service!
    var ovenModeInput: Service!
    var ovenTemp: Service!
    var ovenOptions: Service!
    var ovenStart: Service!
    var ovenTimer: Service!
    var ovenTime: Service!
    var ovenEndTime: Service!
    var ovenTimerService: Service!
    var ovenAlarmService: Service!
    var modeSwitchServices: [(definition: ModeDefinition, service: Service)] = []
    var cancelSwitch: Service!
    var startOvenSwitch: Service!
    var ovenTempControl: Service!

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        pauser = UpdatePauser(fallback: Self.userEditPause) { [weak self] in self?.refreshCharacteristics() }
    }

    var status: [String: JSONValue] { statusData("ovenState") }

    override func destroy() {
        pauser.dispose()
        commandGate.dispose()
        super.destroy()
    }

    // MARK: What the subclasses answer

    /// The board's Active, and turning it on or off.
    func boardActive() -> Int { 0 }
    func setBoardActive(_ on: Bool) async throws {}
    /// The mode of the pending cook.
    var selectedMode: String {
        get { "" }
        set {}
    }
    func sendOvenCommand() async throws {}
    /// The pending cook's temperature, from one chosen in HomeKit (°C).
    func selectTargetTemperature(_ celsius: Double) {}
    func isMonitorOnly() -> Bool { false }
    func ovenStatus() -> String { "" }
    func ovenModeName() -> String { "" }
    func ovenTemperature() -> String { "" }
    func ovenOptionsName() -> String { "" }
    func ovenCurrentTemperature() -> Double { Self.ambientC }
    func ovenTargetTemperature() -> Double { Self.minTargetC }
    func currentHeatingState() -> Int { 0 }
    func targetHeatingState() -> Int { 0 }
    func refreshCharacteristics() {}

    // MARK: State

    func remainTime() -> Double { Cooking.sumTimeFields(status, prefix: Self.statusPrefix + "RemainTime") }
    func ovenTargetTime() -> Double { Cooking.sumTimeFields(status, prefix: Self.statusPrefix + "TargetTime") }
    func ovenTimerTime() -> Double { Cooking.sumTimeFields(status, prefix: Self.statusPrefix + "Timer") }

    func isModeSelected(_ definition: ModeDefinition) -> Bool {
        selectedMode == definition.mode || definition.aliases.contains(selectedMode)
    }

    // MARK: Building

    /// The status board, whose Active the subclass decides.
    func createBoard(configuredName: String, inputs: Int) -> Service {
        let tv = createTelevision(name: config.name ?? device.name, subtype: "NicoCataGaTa-OvenOven7", configuredName: configuredName, inputs: inputs)
        tv.characteristic(.active).onGet { [weak self] in .int(self?.boardActive() ?? 0) }
            .onSet { [weak self] value in try await self?.setBoardActive(Normalize.boolean(value)) }
        ovenService = tv
        return tv
    }

    /// An input of the board whose line is read from the appliance.
    func input(_ name: String, _ subtype: String, _ identifier: Int, _ shown: Bool,
               _ getName: @escaping @ThinQActor @Sendable (CookingAppliance) -> String) -> Service {
        createInputSource(ovenService, name: name, subtype: subtype, identifier: identifier, shown: shown) { [weak self] in
            self.map(getName) ?? name
        }
    }

    /// The board's lines: the status, the cook's mode, temperature and options (shown while `cooking`), and the
    /// times. `extra` is the appliance's own line, identifier 2 before the mode (`extraFirst`) or 4 after the
    /// temperature.
    @discardableResult
    func addBoardInputs<Appliance: CookingAppliance>(mode: String, temperature: String, cooking: Bool, extra: String, extraShown: Bool, extraFirst: Bool,
                                                     _ extraName: @escaping @ThinQActor @Sendable (Appliance) -> String) -> Service {
        let appliance = Self.appliance
        ovenState = input("\(appliance) Status", "NicoCataGaTa-Oven1003", 1, true) { $0.ovenStatus() }
        func addExtra() -> Service {
            input(extra, "NicoCata-Always15", extraFirst ? 2 : 4, extraShown) { ($0 as? Appliance).map(extraName) ?? extra }
        }
        let first = extraFirst ? addExtra() : nil
        let offset = extraFirst ? 1 : 0
        ovenModeInput = input(mode, "NicoCataGaTa-Oven1004", 2 + offset, cooking) { $0.ovenModeName() }
        ovenTemp = input(temperature, "NicoCataGaTa-Oven1004T", 3 + offset, cooking) { $0.ovenTemperature() }
        let extraInput = first ?? addExtra()
        ovenOptions = input("\(appliance) Options", "NicoCata-Always4", 5, cooking) { $0.ovenOptionsName() }
        ovenStart = input("\(appliance) Start Time", "NicoCata-Always1", 6, cookTimes.showTime) { Cooking.truncateName($0.cookTimes.startString) }
        ovenTimer = input("\(appliance) Timer Status", "NicoCata-Always2", 7, cookTimes.showTimer) { Cooking.truncateName($0.cookTimes.timerString) }
        ovenTime = input("\(appliance) Cook Time Status", "NicoCata-Always2T", 8, cookTimes.showTime) { Cooking.truncateName($0.cookTimes.cookTimeString) }
        ovenEndTime = input("\(appliance) End Time", "NicoCata-Always3", 9, cookTimes.showTime) { Cooking.truncateName($0.cookTimes.endString) }
        return extraInput
    }

    /// The cook time (Active starts or stops the cook) and the kitchen timer, as valves used as countdowns.
    func addValves(cookTime: String, cookTimeMax: Double, timer: String, timerMax: Double, timerLimit: Double, timerStep: Double? = nil) {
        ovenTimerService = addDurationValve(cookTime, subtype: "NicoCataGaTa-OvenT2", primary: true, maxRemaining: cookTimeMax,
            remaining: { [weak self] in self?.remainTime() ?? 0 }, setDuration: { [weak self] in self?.ovenTargetTime() ?? 0 },
            onActiveSet: { [weak self] active in
                guard let self else { return }
                if active {
                    try await sendOvenCommand()
                    return
                }
                try await stopOven()
                ovenTimerService.set(.active, 0)
                ovenTimerService.set(.remainingDuration, 0)
                ovenTimerService.set(.inUse, 0)
            },
            onSetDuration: { [weak self] seconds in
                guard let self else { return }
                logger.debug("Cooking Duration set to: \(Cooking.formatDuration(seconds))")
                setCookDuration(seconds)
                markUserSelection()
            })
        ovenAlarmService = addDurationValve(timer, subtype: "NicoCataGaTa-OvenT32", maxRemaining: timerMax, setDurationStep: timerStep,
            remaining: { [weak self] in self?.ovenTimerTime() ?? 0 }, setDuration: { [weak self] in self?.timerAlarmSec ?? 0 },
            onActiveSet: { [weak self] active in
                guard let self else { return }
                let seconds = active ? timerAlarmSec : 0
                try await sendTimerCommand(seconds)
                if !active { timerAlarmSec = 0 }
                ovenAlarmService.set(.active, active ? 1 : 0)
                ovenAlarmService.set(.remainingDuration, seconds)
                ovenAlarmService.set(.inUse, active ? 1 : 0)
            },
            onSetDuration: { [weak self] seconds in self?.timerAlarmSec = min(seconds, timerLimit) })
    }

    /// The pending cook's duration.
    func setCookDuration(_ seconds: Double) {}

    /// A Valve used as a countdown.
    private func addDurationValve(_ name: String, subtype: String, primary: Bool = false, maxRemaining: Double, setDurationStep: Double? = nil,
                                  remaining: @escaping @ThinQActor @Sendable () -> Double, setDuration: @escaping @ThinQActor @Sendable () -> Double,
                                  onActiveSet: @escaping @ThinQActor @Sendable (Bool) async throws -> Void,
                                  onSetDuration: @escaping @ThinQActor @Sendable (Double) -> Void) -> Service {
        let valve = Service(.valve, name: name, subtype: subtype, optional: [
            CharacteristicType.remainingDuration.props(max: maxRemaining),
            CharacteristicType.setDuration.props(max: maxRemaining, step: setDurationStep),
        ], extra: [Characteristic(.configuredName, value: .string(name))], isPrimary: primary)
        valve.set(.valveType, 1)
        valve.characteristic(.active).onGet { .int(remaining() != 0 ? 1 : 0) }
            .onSet { value in try await onActiveSet(Normalize.boolean(value)) }
        valve.set(.inUse, remaining() > 0 ? 1 : 0)
        valve.characteristic(.remainingDuration).onGet { .double(remaining()) }
        let logger = logger
        valve.characteristic(.setDuration).onGet { .double(setDuration()) }
            .onSet { value in
                guard let seconds = Normalize.number(value) else {
                    logger.error("\(name): SetDuration is not a number")
                    return
                }
                onSetDuration(seconds)
            }
        return append(valve)
    }

    /// A switch with a Configured Name, by subtype.
    func createSwitch(_ name: String, subtype: String) -> Service {
        addService(.switch, name: name, subtype: subtype)
    }

    /// A switch per mode: on when the pending cook has it, selecting it when turned on.
    func addModeSwitches(_ definitions: [ModeDefinition]) {
        modeSwitchServices = definitions.map { definition in
            let service = createSwitch(definition.name, subtype: definition.subtype)
            service.characteristic(.on).onGet { [weak self] in .bool(self?.isModeSelected(definition) ?? false) }
                .onSet { [weak self] value in
                    guard let self else { return }
                    if Normalize.boolean(value) {
                        selectedMode = definition.mode
                        markUserSelection()
                    }
                    syncModeSwitches()
                }
            return (definition, service)
        }
    }

    /// A button-like switch that stops the cook.
    func addStopSwitch(_ name: String) {
        cancelSwitch = createSwitch(name, subtype: "CataNicoGaTa-Control6")
        cancelSwitch.characteristic(.on).onGet { .bool(false) }.onSet { [weak self] value in
            guard let self else { return }
            defer {
                resetMomentarySwitch(cancelSwitch)
                syncModeSwitches()
            }
            if Normalize.boolean(value) { try await stopOven() }
        }
    }

    /// A button-like switch that sends the pending cook.
    func addStartSwitch(_ name: String) {
        startOvenSwitch = createSwitch(name, subtype: "CataNicoGaTa-Control8")
        startOvenSwitch.characteristic(.on).onGet { .bool(false) }.onSet { [weak self] value in
            guard let self, Normalize.boolean(value) else { return }
            defer { resetMomentarySwitch(startOvenSwitch) }
            try await sendOvenCommand()
        }
    }

    /// Turns a button-like switch back off a second later.
    func resetMomentarySwitch(_ service: Service, after delay: Duration = .seconds(1)) {
        service[.on]?.revert(to: .bool(false), after: delay)
    }

    /// The thermostat of the cook: heating on pauses refreshes for the user, off stops the cook; a target
    /// temperature is part of the pending cook.
    func addTemperatureControl(_ name: String, subtype: String, current: ClosedRange<Double>, targetMax: Double) -> Service {
        let control = addService(.thermostat, name: name, subtype: subtype, optional: [
            CharacteristicType.targetHeatingCoolingState.valid([0, 1]),
            CharacteristicType.currentTemperature.props(min: current.lowerBound, max: current.upperBound, step: 0.5),
            CharacteristicType.targetTemperature.props(min: Self.minTargetC, max: targetMax, step: 0.5),
            .currentRelativeHumidity,
        ])
        control.set(.name, name)
        control.set(.currentHeatingCoolingState, currentHeatingState())
        control.characteristic(.targetHeatingCoolingState).onGet { [weak self] in .int(self?.targetHeatingState() ?? 0) }
            .onSet { [weak self] value in
                guard let self else { return }
                if Normalize.boolean(value) { pauser.pause(Self.userEditPause) } else { try await stopOven() }
            }
        control.characteristic(.currentTemperature).onGet { [weak self] in .double(self?.ovenCurrentTemperature() ?? Self.ambientC) }
        control.characteristic(.currentRelativeHumidity).onGet { .double(Self.ambientHumidity) }
        control.characteristic(.targetTemperature).onGet { [weak self] in .double(self?.ovenTargetTemperature() ?? Self.minTargetC) }
            .onSet { [weak self] value in
                guard let self else { return }
                guard let celsius = Normalize.number(value) else {
                    logger.error("TargetTemperature is not a number")
                    return
                }
                selectTargetTemperature(celsius)
                userTargetTemperature = celsius
                markUserSelection()
            }
        ovenTempControl = control
        return control
    }

    // MARK: Commands

    func markUserSelection() {
        userSelectionPending = true
        pauser.pause(Self.userEditPause)
    }

    func clearUserSelection() {
        userSelectionPending = false
        userTargetTemperature = nil
    }

    /// A ThinQ2 `Set` of the `ovenState`; a failure or a refusal is a communication failure for HomeKit.
    func sendOvenState(_ ctrlKey: String, _ ovenState: [String: JSONValue]) async throws {
        try await sendAccepted(Self.dataSetList(["ovenState": .object(ovenState)]), ctrlKey: ctrlKey,
            failed: { logger.error("[\(device.name)] \(ctrlKey) command failed: \($0)") },
            refused: { logger.error("[\(device.name)] \(ctrlKey) command was not accepted by the device") })
    }

    func sendTimerCommand(_ time: Double) async throws {
        try await commandGate.run {
            logger.debug("Alarm Set to: \(Cooking.formatDuration(time))")
            defer { pauser.pause(Self.commandSettle) }
            let hasHours = Self.timerHasHours
            try await sendOvenState("SetTimer", [
                "cmdOptionContentsType": "TIMER", "cmdOptionDataLength": "TIMER", "lowerTimerHour": 128, "lowerTimerMinute": 128, "lowerTimerSecond": 128,
                "upperTimerHour": .number(hasHours ? (time / 3600).rounded(.down) : 0),
                "upperTimerMinute": .number(hasHours ? (time.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down) : (time / 60).rounded(.down)),
                "upperTimerSecond": .number(time.truncatingRemainder(dividingBy: 60).rounded(.down)),
            ])
        }
    }

    func stopOven() async throws {
        if isMonitorOnly() {
            logger.info("[\(device.name)] Monitor Only Mode is on; stop command not sent")
            return
        }
        try await commandGate.run {
            pauser.pause(Self.userEditPause)
            defer { pauser.pause(Self.commandSettle) }
            logger.debug("Stop Command Sent to \(Self.appliance)")
            try await sendOvenState("SetCookStop", ["cmdOptionCookStop": "UPPER"])
            clearUserSelection()
        }
    }

    // MARK: Updates

    func syncModeSwitches() {
        for (definition, service) in modeSwitchServices { service.set(.on, isModeSelected(definition)) }
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        guard let pauser else { return }
        if pauser.isPaused {
            // Replayed when the pause ends.
            pauser.markPending()
            return
        }
        refreshCharacteristics()
    }

    /// The board's lines, those of the cook shown while `cooking`, and the valves.
    func refreshBoard(cooking: Bool, targetTime: Double, timerTime: Double, remaining: Double) {
        ovenState.set(.configuredName, ovenStatus())
        ovenModeInput.set(.configuredName, ovenModeName())
        ovenTemp.set(.configuredName, ovenTemperature())
        ovenStart.set(.configuredName, Cooking.truncateName(cookTimes.startString))
        ovenTimer.set(.configuredName, Cooking.truncateName(cookTimes.timerString))
        ovenTime.set(.configuredName, Cooking.truncateName(cookTimes.cookTimeString))
        ovenEndTime.set(.configuredName, Cooking.truncateName(cookTimes.endString))
        ovenOptions.set(.configuredName, ovenOptionsName())
        setVisibility(ovenModeInput, cooking)
        setVisibility(ovenTemp, cooking)
        setVisibility(ovenOptions, cooking)
        setVisibility(ovenStart, cookTimes.showTime)
        setVisibility(ovenTime, cookTimes.showTime)
        setVisibility(ovenEndTime, cookTimes.showTime)
        setVisibility(ovenTimer, cookTimes.showTimer)

        ovenTimerService.set(.active, remaining > 0 ? 1 : 0)
        if targetTime == 0 {
            ovenTimerService.set(.inUse, 0)
        } else if cooking {
            ovenTimerService.set(.inUse, 1)
        }
        ovenTimerService.set(.remainingDuration, remaining)
        if !userSelectionPending { ovenTimerService.set(.setDuration, targetTime) }
        ovenAlarmService.set(.active, timerTime > 0 ? 1 : 0)
        ovenAlarmService.set(.remainingDuration, timerTime)
        ovenAlarmService.set(.inUse, timerTime > 0 ? 1 : 0)
    }
}
