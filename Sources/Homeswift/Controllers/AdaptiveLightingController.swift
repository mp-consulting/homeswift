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

    // MARK: SerializableController

    public var controllerID: String {
        "characteristic-transition-" + lightbulb.type.uuid.uuidString + (lightbulb.subtype ?? "")
    }

    private struct Serialized: Codable {
        var activeTransition: Transition
    }

    public func serialize() -> Data? {
        guard let active = activeTransition else { return nil }
        return try? JSONEncoder().encode(Serialized(activeTransition: active))
    }

    public func deserialize(_ data: Data) throws {
        let serialized = try JSONDecoder().decode(Serialized.self, from: data)
        state.withLockedValue { $0.activeTransition = serialized.activeTransition }
        handleActiveTransitionUpdated(fromDeserializer: true)
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
        // Math.round: halves go up.
        var value = Int((temperature + factor * multiplier + 0.5).rounded(.down))
        value += customTemperatureAdjustment
        return Int(max(bounds.0, min(bounds.1, Double(value))))
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
        let iid = Int(try HAPTLV.readVariableUInt(iidData))
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
        let iid = Int(try HAPTLV.readVariableUInt(iidData))
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

        let startTimeMillis = Self.epoch2001Millis + Int(HAPTLV.readUInt(startTime))
        let timeMillisOffset = clock() - startTimeMillis

        var curve: [TransitionCurveEntry] = []
        for entryData in curveConfiguration[Curve.transitionEntry] ?? [] {
            let entry = try HAPTLV.decode(entryData)
            guard let factor = entry[Entry.adjustmentFactor], let value = entry[Entry.value], let offset = entry[Entry.transitionOffset]
            else { throw HAPTLV.DecodingError.missing("transition entry") }
            let duration = try entry[Entry.duration].map { Int(try HAPTLV.readVariableUInt($0)) }
            if !curve.isEmpty { curve[curve.count - 1].duration = duration }
            curve.append(TransitionCurveEntry(
                temperature: Double(try HAPTLV.readFloat32(value)), brightnessAdjustmentFactor: Double(try HAPTLV.readFloat32(factor)),
                transitionTime: Int(try HAPTLV.readVariableUInt(offset))))
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
            brightnessCharacteristicIID: Int(try HAPTLV.readVariableUInt(adjustmentIIDData)),
            brightnessAdjustmentRange: BrightnessAdjustmentRange(
                minBrightnessValue: Int(HAPTLV.readUInt(minimum.prefix(4))), maxBrightnessValue: Int(HAPTLV.readUInt(maximum.prefix(4)))),
            transitionCurve: curve, updateInterval: updateInterval ?? 60000, notifyIntervalThreshold: notifyIntervalThreshold)

        let renewed = state.withLockedValue { state -> Bool in
            state.activeTransition = transition
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
