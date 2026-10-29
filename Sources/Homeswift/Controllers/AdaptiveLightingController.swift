import Foundation
import Logging
import NIOConcurrencyHelpers

/// Adaptive Lighting for a Lightbulb service, as HAP-NodeJS's `AdaptiveLightingController`.
///
/// The lightbulb needs Brightness and Color Temperature; Hue and Saturation are optional. Create the controller
/// before the accessory goes on a server: it adds the transition characteristics (Supported Characteristic Value
/// Transition Configuration, Characteristic Value Transition Control, Characteristic Value Active Transition
/// Count) to the service, and iids are given when the accessory is added. In a plugin, pass it to
/// `context.configureController(_:accessoryID:)` so an active schedule survives restarts.
///
/// When the user turns Adaptive Lighting on, the Home app sends a 24-hour schedule of colour temperatures, which
/// a home hub renews every day. A brighter light is colder: the temperature also depends on the brightness.
///
/// - **Automatic** (the default): the controller writes the Color Temperature characteristic itself every
///   `updateInterval` (60 s), through its `onWrite` handler, as a write from HomeKit would; it adjusts the
///   temperature when Brightness changes; it turns Adaptive Lighting off when HomeKit writes Color Temperature,
///   Hue or Saturation. When the device changes colour on its own, call `disableAdaptiveLighting()`. With Hue and
///   Saturation, the controller sets them to the temperature's colour (`ColorUtils`) before each write.
/// - **Manual**: for lights that run transitions themselves. The controller handles the setup with HomeKit and
///   keeps the schedule; `onUpdate` gets it (when enabled, renewed or restored), and the plugin runs it, updates
///   the temperature when brightness changes, sends events at most every `notifyIntervalThreshold`, and calls
///   `disableAdaptiveLighting()` on manual colour changes. `onDisable` reports HomeKit turning it off.
public final class AdaptiveLightingController: SerializableController, @unchecked Sendable {
    public enum Mode: Int, Sendable, Codable {
        case automatic = 1
        case manual = 2
    }

    /// One point of the schedule.
    public struct TransitionCurveEntry: Codable, Sendable, Equatable {
        /// The colour temperature in mired at this point, before the brightness adjustment.
        public var temperature: Double
        /// Multiplied by the (clamped) brightness and added to `temperature`.
        public var brightnessAdjustmentFactor: Double
        /// Milliseconds from the previous point (or from the end of its `duration`) to this one.
        public var transitionTime: Int
        /// Milliseconds the value stays at this point before moving to the next one.
        public var duration: Int?

        public init(temperature: Double, brightnessAdjustmentFactor: Double, transitionTime: Int, duration: Int? = nil) {
            self.temperature = temperature
            self.brightnessAdjustmentFactor = brightnessAdjustmentFactor
            self.transitionTime = transitionTime
            self.duration = duration
        }
    }

    /// The brightness range used for the adjustment: the brightness is clamped into it.
    public struct BrightnessAdjustmentRange: Codable, Sendable, Equatable {
        public var minBrightnessValue: Int
        public var maxBrightnessValue: Int
    }

    /// The active schedule, kept across restarts. The field names are HAP-NodeJS's.
    public struct Transition: Codable, Sendable, Equatable {
        /// The iid of the characteristic the transition is for (Color Temperature).
        public var iid: Int
        /// When the schedule starts, in milliseconds since 1970 on the clock of the controller that sent it.
        public var transitionStartMillis: Int
        /// Our clock minus the controller's, measured when the schedule arrived.
        public var timeMillisOffset: Int
        public var transitionId: String
        /// The start time as HomeKit sent it, in hex.
        public var transitionStartBuffer: String
        public var id3: String?
        public var brightnessCharacteristicIID: Int
        public var brightnessAdjustmentRange: BrightnessAdjustmentRange
        public var transitionCurve: [TransitionCurveEntry]
        /// Milliseconds between two colour temperature updates, typically 60 000.
        public var updateInterval: Int
        /// The shortest interval between two event notifications, typically 600 000 (ten minutes).
        public var notifyIntervalThreshold: Int

        /// Times and ranges within what a controller can send, so the schedule's arithmetic cannot overflow: a
        /// saved schedule is read back through this too.
        func clamped() -> Transition {
            var transition = self
            transition.transitionStartMillis = Self.clamp(transitionStartMillis, AdaptiveLightingController.startTimeRange)
            transition.timeMillisOffset = Self.clamp(timeMillisOffset, -AdaptiveLightingController.maxStartMillis...AdaptiveLightingController.maxStartMillis)
            for index in transition.transitionCurve.indices {
                transition.transitionCurve[index].transitionTime = Self.clamp(transitionCurve[index].transitionTime, AdaptiveLightingController.timeRange)
                transition.transitionCurve[index].duration = transitionCurve[index].duration.map { Self.clamp($0, AdaptiveLightingController.timeRange) }
            }
            transition.updateInterval = Self.clamp(updateInterval, AdaptiveLightingController.timeRange)
            transition.notifyIntervalThreshold = Self.clamp(notifyIntervalThreshold, AdaptiveLightingController.timeRange)
            transition.brightnessAdjustmentRange.minBrightnessValue = Self.clamp(brightnessAdjustmentRange.minBrightnessValue, AdaptiveLightingController.timeRange)
            transition.brightnessAdjustmentRange.maxBrightnessValue = Self.clamp(brightnessAdjustmentRange.maxBrightnessValue, AdaptiveLightingController.timeRange)
            return transition
        }

        private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
    }

    /// What `onUpdate` gets in manual mode.
    public struct Update: Sendable, Equatable {
        public var transitionStartMillis: Int
        public var timeMillisOffset: Int
        public var transitionCurve: [TransitionCurveEntry]
        public var brightnessAdjustmentRange: BrightnessAdjustmentRange
        public var updateInterval: Int
        public var notifyIntervalThreshold: Int
    }

    public let lightbulb: Service
    public let mode: Mode
    /// Mired added to every computed temperature (Govee's `adaptiveLightingShift`).
    public let customTemperatureAdjustment: Int

    private let supportedTransitionConfiguration: Characteristic
    private let transitionControl: Characteristic
    private let activeTransitionCount: Characteristic
    private let logger: Logger
    private let clock: @Sendable () -> Int
    private let jobs: AsyncStream<@Sendable () async -> Void>.Continuation

    private struct State {
        var activeTransition: Transition?
        /// The last schedule HomeKit sent, kept when Adaptive Lighting goes off, so it can be resumed.
        var lastTransition: Transition?
        var didRunFirstInitializationStep = false
        var updateTimer: Task<Void, Never>?
        var lastTransitionPointInfo: (curveIndex: Int, lowerBoundTimeOffset: Int)?
        var lastEventNotificationSent = 0
        var lastNotifiedTemperatureValue = 0
        var lastNotifiedSaturationValue: Double = 0
        var lastNotifiedHueValue: Double = 0
        var colorTemperature: Characteristic?
        var brightness: Characteristic?
        var hue: Characteristic?
        var saturation: Characteristic?
        var observers: [(Characteristic, Int)] = []
        var stateChangeDelegate: (@Sendable () -> Void)?
        var onUpdate: (@Sendable (Update) -> Void)?
        var onDisable: (@Sendable () -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    /// Adds Adaptive Lighting to `lightbulb`, which must have Brightness and Color Temperature.
    public convenience init(_ lightbulb: Service, mode: Mode = .automatic, customTemperatureAdjustment: Int = 0, logger: Logger? = nil) {
        self.init(lightbulb, mode: mode, customTemperatureAdjustment: customTemperatureAdjustment, logger: logger) {
            Int((Date().timeIntervalSince1970 * 1000).rounded())
        }
    }

    /// `clock` returns milliseconds since 1970; tests pass their own.
    init(_ lightbulb: Service, mode: Mode, customTemperatureAdjustment: Int, logger: Logger?, clock: @escaping @Sendable () -> Int) {
        precondition(lightbulb[.colorTemperature] != nil, "Lightbulb must have the ColorTemperature characteristic added!")
        precondition(lightbulb[.brightness] != nil, "Lightbulb must have the Brightness characteristic added!")
        self.lightbulb = lightbulb
        self.mode = mode
        self.customTemperatureAdjustment = customTemperatureAdjustment
        self.logger = logger ?? Logger(label: "homeswift.adaptive-lighting")
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        jobs = continuation
        // One worker runs transition steps in order, so two writes of the colour temperature never cross.
        Task {
            for await job in stream { await job() }
        }

        supportedTransitionConfiguration = lightbulb.characteristic(adding: .supportedCharacteristicValueTransitionConfiguration)
        transitionControl = lightbulb.characteristic(adding: .characteristicValueTransitionControl)
        activeTransitionCount = lightbulb.characteristic(adding: .characteristicValueActiveTransitionCount)
        transitionControl.set(.string(""), notify: false)
        activeTransitionCount.set(.int(0), notify: false)
        lightbulb.adaptiveLightingBox.withLockedValue { $0.controller = self }

        supportedTransitionConfiguration.onRead { [weak self] in
            .string(self?.supportedTransitionConfigurationTLV().base64EncodedString() ?? "")
        }
        transitionControl.onRead { [weak self] in
            .string(self?.transitionControlResponse().base64EncodedString() ?? "")
        }
        transitionControl.onWriteResponse { [weak self] value in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            do {
                return .string(try self.handleTransitionControlWrite(value))
            } catch {
                self.logger.warning("Encountered error on CharacteristicValueTransitionControl characteristic", metadata: [
                    "lightbulb": "\(self.displayName)", "error": "\(error)",
                ])
                self.disableAdaptiveLighting()
                throw HAPStatusError(.serviceCommunicationFailure)
            }
        }
    }

    deinit {
        jobs.finish()
        state.withLockedValue { $0.updateTimer?.cancel() }
    }

    private var displayName: String { lightbulb[.name]?.value.stringValue ?? lightbulb.type.name }

    // MARK: Public API

    /// Whether an Adaptive Lighting schedule is active.
    public var isAdaptiveLightingActive: Bool { state.withLockedValue { $0.activeTransition != nil } }

    /// The active schedule, if any.
    public var activeTransition: Transition? { state.withLockedValue { $0.activeTransition } }

    /// Whether `resumeAdaptiveLighting()` can turn it on: off, with a schedule HomeKit sent before.
    public var canResumeAdaptiveLighting: Bool { state.withLockedValue { $0.activeTransition == nil && $0.lastTransition != nil } }

    /// Turns Adaptive Lighting on again with the last schedule the Home app sent, as the Home app itself does: the
    /// same transition id, a start time of now, and the curve rotated so it begins at the point for this time of day
    /// (`rotated(_:toStartAt:)`). The web UI's Adaptive swatch and moods use it. False when it is on already, when
    /// HomeKit never sent a schedule, or when a curve shorter than a day does not reach the time of day it is now.
    @discardableResult
    public func resumeAdaptiveLighting() -> Bool {
        let now = clock()
        let resumed = state.withLockedValue { state -> Bool in
            guard state.activeTransition == nil, let last = state.lastTransition,
                let transition = Self.rotated(last, toStartAt: now - last.timeMillisOffset)
            else { return false }
            state.activeTransition = transition
            state.lastTransition = transition
            state.lastTransitionPointInfo = nil
            return true
        }
        guard resumed else { return false }
        logger.debug("Adaptive lighting was resumed", metadata: ["lightbulb": "\(displayName)"])
        handleActiveTransitionUpdated(fromDeserializer: false)
        return true
    }

    static let dayMillis = 86_400_000

    /// `transition` started again at `start` (milliseconds on the clock of the controller that sent it), the way the
    /// Home app sends a schedule it turns on again: the same transition id, `start` as its start time, and a curve
    /// that begins with the point for that time of day. The Home app's curves cover a day and end where they begin,
    /// so such a curve wraps around and still covers a day; a shorter one keeps what is left of it, and is nil at a
    /// time of day it does not reach.
    static func rotated(_ transition: Transition, toStartAt start: Int) -> Transition? {
        let curve = transition.transitionCurve
        guard curve.count >= 2 else { return nil }
        // When each point is reached, counted from the first one.
        var reach = [0]
        for index in 1..<curve.count {
            reach.append(reach[index - 1] + (curve[index - 1].duration ?? 0) + curve[index].transitionTime)
        }
        let length = reach[curve.count - 1]
        guard length > 0 else { return nil }
        let wraps = abs(length - dayMillis) <= 60_000
        let period = wraps ? length : dayMillis
        let elapsed = start - transition.transitionStartMillis - curve[0].transitionTime
        let position = (elapsed % period + period) % period
        guard position < length, let index = (0..<curve.count - 1).last(where: { reach[$0] <= position }) else { return nil }

        let lower = curve[index]
        let upper = curve[index + 1]
        let hold = lower.duration ?? 0
        let into = position - reach[index]
        // The point for now; how long until the next one; how long the lower one holds and the ramp from it to
        // now take when the curve comes round again.
        let point: TransitionCurveEntry
        let untilNext: Int
        let heldAtEnd: Int
        let rampAtEnd: Int
        if into < hold {
            point = TransitionCurveEntry(
                temperature: lower.temperature, brightnessAdjustmentFactor: lower.brightnessAdjustmentFactor, transitionTime: 0,
                duration: hold - into)
            (untilNext, heldAtEnd, rampAtEnd) = (upper.transitionTime, into, 0)
        } else {
            // Past the hold and before the next point, so the ramp to it takes time.
            let fraction = Double(into - hold) / Double(upper.transitionTime)
            point = TransitionCurveEntry(
                temperature: lower.temperature + (upper.temperature - lower.temperature) * fraction,
                brightnessAdjustmentFactor: lower.brightnessAdjustmentFactor
                    + (upper.brightnessAdjustmentFactor - lower.brightnessAdjustmentFactor) * fraction,
                transitionTime: 0)
            (untilNext, heldAtEnd, rampAtEnd) = (reach[index + 1] - position, hold, into - hold)
        }

        var rotated = [point]
        // The last point is the first one again, so the curve goes on with the second.
        let order = Array(index + 1..<curve.count) + (wraps ? Array(1..<index + 1) : [])
        for (offset, number) in order.enumerated() {
            var entry = curve[number]
            if offset == 0 { entry.transitionTime = untilNext }
            if number == curve.count - 1 { entry.duration = wraps ? curve[0].duration : nil }
            rotated.append(entry)
        }
        if wraps {
            rotated[rotated.count - 1].duration = heldAtEnd
            rotated.append(TransitionCurveEntry(
                temperature: point.temperature, brightnessAdjustmentFactor: point.brightnessAdjustmentFactor, transitionTime: rampAtEnd))
        }

        var result = transition
        result.transitionStartMillis = start
        // HomeKit's start time: milliseconds since 2001, eight bytes little-endian.
        result.transitionStartBuffer = HAPTLV.hexString(HAPTLV.uint64(UInt64(max(0, start - epoch2001Millis))))
        result.transitionCurve = rotated
        return result.clamped()
    }

    /// When the current schedule started, in milliseconds since 1970 (see `timeOffset`).
    public var startTimeOfTransition: Int? { activeTransition?.transitionStartMillis }
    /// Our clock minus that of the controller that set up the schedule, in milliseconds.
    public var timeOffset: Int? { activeTransition?.timeMillisOffset }
    public var transitionCurve: [TransitionCurveEntry]? { activeTransition?.transitionCurve }
    public var brightnessMultiplierRange: BrightnessAdjustmentRange? { activeTransition?.brightnessAdjustmentRange }
    /// How often the light should change its colour, in milliseconds (typically 60 000).
    public var updateInterval: Int? { activeTransition?.updateInterval }
    /// The shortest interval between two event notifications, in milliseconds (typically 600 000).
    public var notifyIntervalThreshold: Int? { activeTransition?.notifyIntervalThreshold }

    /// Manual mode: called when Adaptive Lighting is enabled, its schedule renewed, or restored at launch.
    public func onUpdate(_ handler: (@Sendable (Update) -> Void)?) {
        state.withLockedValue { $0.onUpdate = handler }
    }

    /// Manual mode: called when HomeKit turns Adaptive Lighting off. The schedule is still active during the call.
    public func onDisable(_ handler: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.onDisable = handler }
    }

    /// Turns Adaptive Lighting off: in manual mode when the colour changed outside the schedule; in automatic
    /// mode when the device changed colour by itself (HomeKit writes are detected).
    public func disableAdaptiveLighting() {
        let (wasActive, delegate, observers) = state.withLockedValue { state -> (Bool, (@Sendable () -> Void)?, [(Characteristic, Int)]) in
            state.updateTimer?.cancel()
            state.updateTimer = nil
            let wasActive = state.activeTransition != nil
            let observers = state.observers
            if wasActive {
                state.observers = []
                state.activeTransition = nil
            }
            state.colorTemperature = nil
            state.brightness = nil
            state.hue = nil
            state.saturation = nil
            state.lastTransitionPointInfo = nil
            state.lastEventNotificationSent = 0
            state.lastNotifiedTemperatureValue = 0
            state.lastNotifiedSaturationValue = 0
            state.lastNotifiedHueValue = 0
            state.didRunFirstInitializationStep = false
            return (wasActive, state.stateChangeDelegate, wasActive ? observers : [])
        }
        for (characteristic, token) in observers { characteristic.removeObserver(token) }
        if wasActive { delegate?() }
        activeTransitionCount.sendEvent(.int(0))
        logger.debug("Disabling adaptive lighting", metadata: ["lightbulb": "\(displayName)"])
    }

    /// How far, in mireds, a white the device reports may be from the one shown before it counts as set elsewhere:
    /// devices round what they are sent (kelvin, a percentage).
    public static let changedElsewhereTolerance = 5

    /// The device reported its colour: `mireds`, the white it shows, or nil for a colour. Turns Adaptive Lighting off,
    /// as the Home app does when it sets one, when that is a colour or a white more than `changedElsewhereTolerance`
    /// from the Color Temperature shown: the device was set by something else (its app, a remote, a scene). Call it
    /// with the device's reports, not the echo of the bridge's own write still on its way. True when it turned it off.
    @discardableResult
    public func disableIfChangedElsewhere(mireds: Int?) -> Bool {
        guard isAdaptiveLightingActive else { return false }
        if let mireds {
            let characteristic = lightbulb.characteristic(.colorTemperature)
            guard let shown = characteristic.value.intValue else { return false }
            let low = Int(characteristic.type.minValue ?? 140), high = Int(characteristic.type.maxValue ?? 500)
            guard abs(min(max(mireds, low), high) - shown) > Self.changedElsewhereTolerance else { return false }
        }
        disableAdaptiveLighting()
        return true
    }

    /// Turns it on as the Home app would, with a day's schedule at a steady `mireds`: for tests (`@testable import`).
    func activateForTesting(mireds: Double = 300) throws {
        let curve = [
            TransitionCurveEntry(temperature: mireds, brightnessAdjustmentFactor: 0, transitionTime: 0),
            TransitionCurveEntry(temperature: mireds, brightnessAdjustmentFactor: 0, transitionTime: Self.dayMillis),
        ]
        let transition = Transition(
            iid: lightbulb.characteristic(.colorTemperature).iid, transitionStartMillis: clock(), timeMillisOffset: 0,
            transitionId: UUID().uuidString.lowercased(), transitionStartBuffer: "00", id3: nil,
            brightnessCharacteristicIID: lightbulb.characteristic(.brightness).iid,
            brightnessAdjustmentRange: BrightnessAdjustmentRange(minBrightnessValue: 10, maxBrightnessValue: 100), transitionCurve: curve,
            updateInterval: 60_000, notifyIntervalThreshold: 600_000)
        try deserialize(JSONEncoder().encode(Serialized(activeTransition: transition)))
    }

    // MARK: SerializableController

    public var controllerID: String {
        "characteristic-transition-" + lightbulb.type.uuid.uuidString + (lightbulb.subtype ?? "")
    }

    /// The active schedule, and the last one, which stays once Adaptive Lighting is off (a state saved before it
    /// existed has the active one only).
    private struct Serialized: Codable {
        var activeTransition: Transition?
        var lastTransition: Transition?
    }

    public func serialize() -> Data? {
        let (active, last) = state.withLockedValue { ($0.activeTransition, $0.lastTransition) }
        guard active != nil || last != nil else { return nil }
        return try? JSONEncoder().encode(Serialized(activeTransition: active, lastTransition: last))
    }

    public func deserialize(_ data: Data) throws {
        let serialized = try JSONDecoder().decode(Serialized.self, from: data)
        let active = serialized.activeTransition?.clamped()
        let last = (serialized.lastTransition ?? serialized.activeTransition)?.clamped()
        state.withLockedValue {
            $0.activeTransition = active
            $0.lastTransition = last
        }
        if active != nil { handleActiveTransitionUpdated(fromDeserializer: true) }
    }

    public func setupStateChangeDelegate(_ delegate: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.stateChangeDelegate = delegate }
    }

    // MARK: Transitions

    private func handleActiveTransitionUpdated(fromDeserializer: Bool) {
        if fromDeserializer {
            activeTransitionCount.set(.int(1), notify: false)
        } else {
            activeTransitionCount.sendEvent(.int(1))
        }
        switch mode {
        case .automatic:
            enqueue { await $0.scheduleNextUpdate(dryRun: false) }
        case .manual:
            let (update, handler) = state.withLockedValue { state -> (Update?, (@Sendable (Update) -> Void)?) in
                guard let active = state.activeTransition else { return (nil, nil) }
                return (
                    Update(
                        transitionStartMillis: active.transitionStartMillis, timeMillisOffset: active.timeMillisOffset,
                        transitionCurve: active.transitionCurve, brightnessAdjustmentRange: active.brightnessAdjustmentRange,
                        updateInterval: active.updateInterval, notifyIntervalThreshold: active.notifyIntervalThreshold),
                    state.onUpdate
                )
            }
            if let update { handler?(update) }
        }
        if !fromDeserializer {
            state.withLockedValue { $0.stateChangeDelegate }?()
        }
    }

    private func enqueue(_ job: @escaping @Sendable (AdaptiveLightingController) async -> Void) {
        jobs.yield { [weak self] in
            guard let self else { return }
            await job(self)
        }
    }

    /// Watches the lightbulb once a schedule runs: brightness changes adjust the temperature, colour writes
    /// from HomeKit turn Adaptive Lighting off.
    private func handleAdaptiveLightingEnabled(_ state: inout State) {
        let colorTemperature = lightbulb.characteristic(.colorTemperature)
        let brightness = lightbulb.characteristic(.brightness)
        state.colorTemperature = colorTemperature
        state.brightness = brightness
        state.hue = lightbulb[.hue]
        state.saturation = lightbulb[.saturation]
        let me = ObjectIdentifier(self)
        let manualWrite: Characteristic.Observer = { [weak self] change in
            // Updates, events and read results are not manual changes, nor are the controller's own writes.
            guard let self, change.reason == .write, change.context != me else { return }
            self.logger.debug("Received a manual write to a characteristic, disabling adaptive lighting", metadata: [
                "lightbulb": "\(self.displayName)", "newValue": "\(change.newValue)", "oldValue": "\(change.oldValue)",
            ])
            self.disableAdaptiveLighting()
        }
        let adjustment: Characteristic.Observer = { [weak self] change in
            guard let self, change.newValue != change.oldValue else { return }
            if change.reason == .read {
                // Hue and Saturation are probably being read at the same time; adjusting the temperature first
                // and seeing their stale values afterwards would look like a manual change. Wait a second.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isAdaptiveLightingActive else { return }
                    self.enqueue { await $0.scheduleNextUpdate(dryRun: true) }
                }
            } else {
                self.enqueue { await $0.scheduleNextUpdate(dryRun: true) }
            }
        }
        state.observers.append((colorTemperature, colorTemperature.observe(manualWrite)))
        state.observers.append((brightness, brightness.observe(adjustment)))
        if let hue = state.hue { state.observers.append((hue, hue.observe(manualWrite))) }
        if let saturation = state.saturation { state.observers.append((saturation, saturation.observe(manualWrite))) }
    }

    private func handleAdaptiveLightingDisabled() {
        let (notify, handler) = state.withLockedValue { (mode == .manual && $0.activeTransition != nil, $0.onDisable) }
        if notify { handler?() }
        disableAdaptiveLighting()
    }

    struct TransitionPoint {
        var lowerBoundTimeOffset: Int
        var transitionOffset: Int
        var lowerBound: TransitionCurveEntry
        var upperBound: TransitionCurveEntry
    }

    /// The schedule's two points around now, or nil past its end.
    func currentTransitionPoint() -> TransitionPoint? {
        let now = clock()
        return state.withLockedValue { currentTransitionPoint(&$0, now: now) }
    }

    private func currentTransitionPoint(_ state: inout State, now: Int) -> TransitionPoint? {
        guard let active = state.activeTransition else { return nil }
        // Now on the clock of the controller that sent the schedule, as an offset from its start.
        let offset = now - active.timeMillisOffset - active.transitionStartMillis
        let curve = active.transitionCurve
        var index = state.lastTransitionPointInfo?.curveIndex ?? 0
        var lowerBoundTimeOffset = state.lastTransitionPointInfo?.lowerBoundTimeOffset ?? 0
        var bounds: (TransitionCurveEntry, TransitionCurveEntry)?
        while index + 1 < curve.count {
            let lower = curve[index]
            let upper = curve[index + 1]
            let lowerDuration = lower.duration ?? 0
            lowerBoundTimeOffset += lower.transitionTime
            if offset >= lowerBoundTimeOffset {
                if offset <= lowerBoundTimeOffset + lowerDuration + upper.transitionTime {
                    bounds = (lower, upper)
                    break
                }
            } else if state.lastTransitionPointInfo != nil {
                // The cached position is past now: search again from the start.
                state.lastTransitionPointInfo = nil
                return currentTransitionPoint(&state, now: now)
            }
            lowerBoundTimeOffset += lowerDuration
            index += 1
        }
        guard let (lower, upper) = bounds else {
            state.lastTransitionPointInfo = nil
            return nil
        }
        state.lastTransitionPointInfo = (index, lowerBoundTimeOffset - lower.transitionTime)
        return TransitionPoint(
            lowerBoundTimeOffset: lowerBoundTimeOffset, transitionOffset: offset - lowerBoundTimeOffset, lowerBound: lower, upperBound: upper)
    }

    /// The temperature for now at the current brightness, clamped to the characteristic's bounds.
    func currentTemperature(_ point: TransitionPoint, brightness: Int, range: BrightnessAdjustmentRange, bounds: (Double, Double)) -> Int {
        let lower = point.lowerBound
        let upper = point.upperBound
        let temperature: Double
        let factor: Double
        if let duration = lower.duration, duration != 0, point.transitionOffset <= duration {
            temperature = lower.temperature
            factor = lower.brightnessAdjustmentFactor
        } else {
            let elapsed = Double(point.transitionOffset - (lower.duration ?? 0))
            let percentage = upper.transitionTime == 0 ? 1 : elapsed / Double(upper.transitionTime)
            temperature = lower.temperature + (upper.temperature - lower.temperature) * percentage
            factor = lower.brightnessAdjustmentFactor + (upper.brightnessAdjustmentFactor - lower.brightnessAdjustmentFactor) * percentage
        }
        let multiplier = Double(max(range.minBrightnessValue, min(range.maxBrightnessValue, brightness)))
        // Math.round: halves go up. In floating point until clamped: a curve value of 3e38 must not trap.
        let value = (temperature + factor * multiplier + 0.5).rounded(.down) + Double(customTemperatureAdjustment)
        guard !value.isNaN else { return Int(saturating: bounds.0) ?? 0 }
        return Int(saturating: max(bounds.0, min(bounds.1, value))) ?? 0
    }

    /// One step of the automatic mode; a dry run only adjusts the temperature to a new brightness.
    func scheduleNextUpdate(dryRun: Bool) async {
        let now = clock()
        enum Step {
            case none
            case endOfCurve
            case write(temperature: Int, hue: Double, saturation: Double, colorTemperature: Characteristic?, hueC: Characteristic?, saturationC: Characteristic?)
        }
        let step = state.withLockedValue { state -> Step in
            guard let active = state.activeTransition else { return .none }
            if !dryRun { state.updateTimer = nil }
            if !state.didRunFirstInitializationStep {
                state.didRunFirstInitializationStep = true
                handleAdaptiveLightingEnabled(&state)
            }
            guard let point = currentTransitionPoint(&state, now: now) else { return .endOfCurve }
            let type = state.colorTemperature?.type
            let brightness = state.brightness?.value.intValue ?? 0
            let temperature = currentTemperature(
                point, brightness: brightness, range: active.brightnessAdjustmentRange,
                bounds: (type?.minValue ?? 140, type?.maxValue ?? 500))
            let color = ColorUtils.colorTemperatureToHueAndSaturation(Double(temperature))
            return .write(
                temperature: temperature, hue: color.hue, saturation: color.saturation, colorTemperature: state.colorTemperature,
                hueC: state.hue, saturationC: state.saturation)
        }
        switch step {
        case .none:
            return
        case .endOfCurve:
            logger.debug("Reached end of transition curve", metadata: ["lightbulb": "\(displayName)"])
            // The schedule covers 24 hours; a home hub normally renews it before the end.
            if !dryRun { disableAdaptiveLighting() }
            return
        case .write(let temperature, let hue, let saturation, let colorTemperature, let hueC, let saturationC):
            logger.debug("Next temperature value", metadata: [
                "lightbulb": "\(displayName)", "temperature": "\(temperature)", "adjustment": "\(customTemperatureAdjustment)",
            ])
            let me = ObjectIdentifier(self)
            // Hue and Saturation first, without events: a plugin that converts the temperature with the same table
            // sets the same values, so no extra notification goes out between the throttled ones below.
            saturationC?.set(.double(saturation), context: me, notify: false)
            hueC?.set(.double(hue), context: me, notify: false)
            do {
                try await colorTemperature?.writeFromController(.int(temperature), context: me, notify: false)
            } catch {
                logger.debug("Failed to apply the next adaptive lighting transition point", metadata: ["lightbulb": "\(displayName)", "error": "\(error)"])
            }

            let events = state.withLockedValue { state -> [(Characteristic, HAPValue)] in
                guard let active = state.activeTransition else { return [] }
                guard !dryRun, now - state.lastEventNotificationSent >= active.notifyIntervalThreshold else { return [] }
                state.lastEventNotificationSent = now
                var events: [(Characteristic, HAPValue)] = []
                if let colorTemperature, state.lastNotifiedTemperatureValue != temperature {
                    events.append((colorTemperature, .int(temperature)))
                    state.lastNotifiedTemperatureValue = temperature
                }
                if let saturationC, state.lastNotifiedSaturationValue != saturation {
                    events.append((saturationC, .double(saturation)))
                    state.lastNotifiedSaturationValue = saturation
                }
                if let hueC, state.lastNotifiedHueValue != hue {
                    events.append((hueC, .double(hue)))
                    state.lastNotifiedHueValue = hue
                }
                return events
            }
            guard isAdaptiveLightingActive else {
                logger.warning(
                    "Adaptive Lighting was probably disabled by a call in the write handler of the Color Temperature characteristic: do not write Hue, Saturation or Color Temperature from it",
                    metadata: ["lightbulb": "\(displayName)"])
                return
            }
            if !events.isEmpty { logger.debug("Sending event notifications for current transition", metadata: ["lightbulb": "\(displayName)"]) }
            for (characteristic, value) in events {
                characteristic.set(value, reason: .event, context: me, force: true)
            }
            if !dryRun { scheduleTimer() }
        }
    }

    private func scheduleTimer() {
        state.withLockedValue { state in
            guard let interval = state.activeTransition?.updateInterval else { return }
            state.updateTimer?.cancel()
            state.updateTimer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
                self?.enqueue { await $0.scheduleNextUpdate(dryRun: false) }
            }
        }
    }

    // MARK: TLV

    private enum SupportedConfiguration {
        static let supportedTransitionConfiguration: UInt8 = 1
        static let characteristicIID: UInt8 = 1
        static let transitionType: UInt8 = 2
        static let brightness: UInt8 = 1
        static let colorTemperature: UInt8 = 2
    }

    private enum ControlType {
        static let readCurrentValueTransitionConfiguration: UInt8 = 1
        static let updateValueTransitionConfiguration: UInt8 = 2
    }

    private enum Configuration {
        static let characteristicIID: UInt8 = 1
        static let transitionParameters: UInt8 = 2
        static let unknown3: UInt8 = 3
        static let transitionCurveConfiguration: UInt8 = 5
        static let updateInterval: UInt8 = 6
        static let notifyIntervalThreshold: UInt8 = 8
    }

    private enum Parameters {
        static let transitionID: UInt8 = 1
        static let startTime: UInt8 = 2
        static let unknown3: UInt8 = 3
    }

    private enum Curve {
        static let transitionEntry: UInt8 = 1
        static let adjustmentCharacteristicIID: UInt8 = 2
        static let adjustmentMultiplierRange: UInt8 = 3
    }

    private enum Entry {
        static let adjustmentFactor: UInt8 = 1
        static let value: UInt8 = 2
        static let transitionOffset: UInt8 = 3
        static let duration: UInt8 = 4
    }

    /// Milliseconds from 1970 to 2001-01-01, HomeKit's epoch.
    static let epoch2001Millis = 978_307_200_000
    /// A start time past 2^53 ms (JavaScript's largest exact integer, as HAP-NodeJS reads it) is clamped there.
    static let maxStartMillis = 1 << 53
    static let startTimeRange = 0...(epoch2001Millis + maxStartMillis)
    /// Controller times (transition offsets, durations, intervals) are kept to 32 bits, ~49 days: the sum over a
    /// curve cannot overflow.
    static let timeRange = 0...Int(UInt32.max)

    func supportedTransitionConfigurationTLV() -> Data {
        let brightnessIID = lightbulb.characteristic(.brightness).iid
        let temperatureIID = lightbulb.characteristic(.colorTemperature).iid
        return HAPTLV.encode(
            (SupportedConfiguration.supportedTransitionConfiguration, .list([
                HAPTLV.encode(
                    (SupportedConfiguration.characteristicIID, .data(HAPTLV.variableUInt(brightnessIID))),
                    (SupportedConfiguration.transitionType, .byte(SupportedConfiguration.brightness))),
                HAPTLV.encode(
                    (SupportedConfiguration.characteristicIID, .data(HAPTLV.variableUInt(temperatureIID))),
                    (SupportedConfiguration.transitionType, .byte(SupportedConfiguration.colorTemperature))),
            ])))
    }

    private func parametersTLV(_ active: Transition) -> Data {
        var parameters = HAPTLV.encode(
            (Parameters.transitionID, .data(HAPTLV.uuidBytes(active.transitionId))),
            (Parameters.startTime, .data(HAPTLV.hexBytes(active.transitionStartBuffer))))
        if let id3 = active.id3 {
            parameters.append(HAPTLV.encode((Parameters.unknown3, .data(HAPTLV.hexBytes(id3)))))
        }
        return parameters
    }

    /// The Transition Control value: the active transition's status, empty without one.
    func transitionControlResponse(timeSinceStart time: Int? = nil) -> Data {
        guard let active = activeTransition else { return Data() }
        let timeSinceStart = time ?? (clock() - active.timeMillisOffset - active.transitionStartMillis)
        let status = HAPTLV.encode(
            (Configuration.characteristicIID, .data(HAPTLV.variableUInt(active.iid))),
            (Configuration.transitionParameters, .data(parametersTLV(active))),
            (3, .data(HAPTLV.variableUInt(timeSinceStart))))
        return HAPTLV.encode((1, .data(status)))
    }

    enum TransitionError: Error {
        case notBase64
        case unknownIID(Int)
        case notFinite(String)
    }

    /// A write of Characteristic Value Transition Control; returns the write response, base64.
    func handleTransitionControlWrite(_ value: HAPValue) throws -> String {
        guard let string = value.stringValue else { throw HAPStatusError(.invalidValueInRequest) }
        guard let data = Data(base64Encoded: string) else { throw TransitionError.notBase64 }
        let tlv = try HAPTLV.decode(data)
        var response = Data()
        if let read = tlv[ControlType.readCurrentValueTransitionConfiguration], let answer = try handleReadTransition(read) {
            response.append(answer)
        }
        if let update = tlv[ControlType.updateValueTransitionConfiguration] {
            response.append(try handleUpdateTransition(update))
        }
        return response.base64EncodedString()
    }

    private func handleReadTransition(_ data: Data) throws -> Data? {
        let read = try HAPTLV.decode(data)
        let iidData = try HAPTLV.required(read, Configuration.characteristicIID, "characteristic iid")
        let iid = Int(clamping: try HAPTLV.readVariableUInt(iidData))
        guard let active = activeTransition else { return nil }
        guard active.iid == iid else {
            logger.warning("The iid of the current adaptive lighting transition does not match the requested one", metadata: [
                "lightbulb": "\(displayName)", "active": "\(active.iid)", "requested": "\(iid)",
            ])
            throw HAPStatusError(.invalidValueInRequest)
        }
        let entries = active.transitionCurve.enumerated().map { index, entry in
            // Durations are kept on the entry they follow; HomeKit puts them on the next one.
            let duration = index > 0 ? (active.transitionCurve[index - 1].duration ?? 0) : 0
            return HAPTLV.encode(
                (Entry.adjustmentFactor, .data(HAPTLV.float32(Float(entry.brightnessAdjustmentFactor)))),
                (Entry.value, .data(HAPTLV.float32(Float(entry.temperature)))),
                (Entry.transitionOffset, .data(HAPTLV.variableUInt(entry.transitionTime))),
                (Entry.duration, .data(HAPTLV.variableUInt(duration))))
        }
        let curve = HAPTLV.encode(
            (Curve.transitionEntry, .list(entries)),
            (Curve.adjustmentCharacteristicIID, .data(HAPTLV.variableUInt(active.brightnessCharacteristicIID))),
            (Curve.adjustmentMultiplierRange, .data(HAPTLV.encode(
                (1, .data(HAPTLV.uint32(UInt32(clamping: active.brightnessAdjustmentRange.minBrightnessValue)))),
                (2, .data(HAPTLV.uint32(UInt32(clamping: active.brightnessAdjustmentRange.maxBrightnessValue))))))))
        return HAPTLV.encode((ControlType.readCurrentValueTransitionConfiguration, .data(HAPTLV.encode(
            (Configuration.characteristicIID, .data(HAPTLV.variableUInt(active.iid))),
            (Configuration.transitionParameters, .data(parametersTLV(active))),
            (Configuration.unknown3, .byte(1)),
            (Configuration.transitionCurveConfiguration, .data(curve)),
            (Configuration.updateInterval, .data(HAPTLV.variableUInt(active.updateInterval))),
            (Configuration.notifyIntervalThreshold, .data(HAPTLV.variableUInt(active.notifyIntervalThreshold)))))))
    }

    private func handleUpdateTransition(_ data: Data) throws -> Data {
        let update = try HAPTLV.decode(data)
        let configurationData = try HAPTLV.required(update, 1, "value transition configuration")
        let configuration = try HAPTLV.decode(configurationData)
        let iidData = try HAPTLV.required(configuration, Configuration.characteristicIID, "characteristic iid")
        let iid = Int(clamping: try HAPTLV.readVariableUInt(iidData))
        guard lightbulb.characteristics.contains(where: { $0.iid == iid }) else { throw HAPStatusError(.invalidValueInRequest) }

        // HomeKit sends only the iid to turn Adaptive Lighting off; otherwise the third item is always 1.
        guard let flag = configuration[Configuration.unknown3]?.first, flag != 0 else {
            handleAdaptiveLightingDisabled()
            return HAPTLV.encode((ControlType.updateValueTransitionConfiguration, .data(Data())))
        }

        guard let parametersData = configuration[Configuration.transitionParameters],
            let curveData = configuration[Configuration.transitionCurveConfiguration],
            let notifyData = configuration[Configuration.notifyIntervalThreshold]
        else { throw HAPTLV.DecodingError.missing("transition parameters") }
        let parameters = try HAPTLV.decode(parametersData)
        let curveConfiguration = try HAPTLV.decodeWithLists(curveData)
        let updateInterval = configuration[Configuration.updateInterval].map { Int(HAPTLV.readUInt($0.prefix(2))) }
        let notifyIntervalThreshold = Int(HAPTLV.readUInt(notifyData.prefix(4)))
        guard let transitionID = parameters[Parameters.transitionID], let startTime = parameters[Parameters.startTime], startTime.count == 8
        else { throw HAPTLV.DecodingError.missing("transition id or start time") }
        let id3 = parameters[Parameters.unknown3]

        // Clamped: 8 bytes from the controller would overflow Int, then the sums of the schedule.
        let startTimeMillis = Self.epoch2001Millis + Int(clamping: min(HAPTLV.readUInt(startTime), UInt64(Self.maxStartMillis)))
        let timeMillisOffset = clock() - startTimeMillis

        func time(_ data: Data) throws -> Int { min(Int(clamping: try HAPTLV.readVariableUInt(data)), Self.timeRange.upperBound) }
        func float(_ data: Data, _ name: String) throws -> Double {
            // NaN or infinity would reach the colour temperature.
            guard let value = Double(try HAPTLV.readFloat32(data)).finite else { throw TransitionError.notFinite(name) }
            return value
        }
        var curve: [TransitionCurveEntry] = []
        for entryData in curveConfiguration[Curve.transitionEntry] ?? [] {
            let entry = try HAPTLV.decode(entryData)
            guard let factor = entry[Entry.adjustmentFactor], let value = entry[Entry.value], let offset = entry[Entry.transitionOffset]
            else { throw HAPTLV.DecodingError.missing("transition entry") }
            let duration = try entry[Entry.duration].map(time)
            if !curve.isEmpty { curve[curve.count - 1].duration = duration }
            curve.append(TransitionCurveEntry(
                temperature: try float(value, "temperature"), brightnessAdjustmentFactor: try float(factor, "brightness adjustment factor"),
                transitionTime: try time(offset)))
        }
        guard let adjustmentIIDData = curveConfiguration[Curve.adjustmentCharacteristicIID]?.first,
            let rangeData = curveConfiguration[Curve.adjustmentMultiplierRange]?.first
        else { throw HAPTLV.DecodingError.missing("adjustment characteristic") }
        let range = try HAPTLV.decode(rangeData)
        guard let minimum = range[1], let maximum = range[2] else { throw HAPTLV.DecodingError.missing("adjustment multiplier range") }

        let transition = Transition(
            iid: iid, transitionStartMillis: startTimeMillis, timeMillisOffset: timeMillisOffset,
            transitionId: HAPTLV.uuidString(transitionID), transitionStartBuffer: HAPTLV.hexString(startTime),
            id3: id3.map(HAPTLV.hexString),
            brightnessCharacteristicIID: Int(clamping: try HAPTLV.readVariableUInt(adjustmentIIDData)),
            brightnessAdjustmentRange: BrightnessAdjustmentRange(
                minBrightnessValue: Int(HAPTLV.readUInt(minimum.prefix(4))), maxBrightnessValue: Int(HAPTLV.readUInt(maximum.prefix(4)))),
            transitionCurve: curve, updateInterval: updateInterval ?? 60000, notifyIntervalThreshold: notifyIntervalThreshold)

        let renewed = state.withLockedValue { state -> Bool in
            state.activeTransition = transition
            state.lastTransition = transition
            // A new schedule starts from the beginning of its curve.
            state.lastTransitionPointInfo = nil
            guard let timer = state.updateTimer else { return false }
            timer.cancel()
            state.updateTimer = nil
            return true
        }
        logger.debug(renewed ? "Adaptive lighting was renewed" : "Adaptive lighting was enabled", metadata: ["lightbulb": "\(displayName)"])
        handleActiveTransitionUpdated(fromDeserializer: false)
        return HAPTLV.encode((ControlType.updateValueTransitionConfiguration, .data(transitionControlResponse(timeSinceStart: 0))))
    }
}
