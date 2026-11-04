import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// What a characteristic reads from the device's cached state: nil keeps the value it has.
typealias TuyaGetter = @Sendable () -> HAPValue?
typealias TuyaSetter = @Sendable (HAPValue) async throws -> Void

/// A characteristic, once its service is built: event handlers made before the accessory exist reach it through this.
final class TuyaCharacteristicRef: Sendable {
    private let box = NIOLockedValueBox<Characteristic?>(nil)
    var characteristic: Characteristic? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

/// A service being described: its characteristics, what each reads and what a write sends.
final class TuyaServiceDraft {
    struct Spec {
        var type: CharacteristicType
        var get: TuyaGetter?
        var set: TuyaSetter?
        var onlineCheck: Bool
        var value: HAPValue?
        var ref: TuyaCharacteristicRef
    }

    let type: ServiceType
    let name: String?
    let subtype: String?
    /// The name also given as Configured Name (the source's name helper).
    var configuredName: String?
    var specs: [Spec] = []
    var service: Service?

    init(type: ServiceType, name: String?, subtype: String?) {
        self.type = type
        self.name = name
        self.subtype = subtype
    }

    /// Adds (or replaces) a characteristic. `value` is a fixed value it starts with.
    @discardableResult
    func add(
        _ type: CharacteristicType, value: HAPValue? = nil, onlineCheck: Bool = false, ref: TuyaCharacteristicRef = TuyaCharacteristicRef(),
        get: TuyaGetter? = nil, set: TuyaSetter? = nil
    ) -> TuyaCharacteristicRef {
        let spec = Spec(type: type, get: get, set: set, onlineCheck: onlineCheck, value: value, ref: ref)
        if let index = specs.firstIndex(where: { $0.type.uuid == type.uuid }) { specs[index] = spec } else { specs.append(spec) }
        return ref
    }

    func has(_ type: CharacteristicType) -> Bool { specs.contains { $0.type.uuid == type.uuid } }
}

/// An item of a push, as event handlers see it.
typealias TuyaEventHandler = @Sendable ([TuyaPushMessage.StatusItem]) -> Void

/// A light's Adaptive Lighting, attached once the accessory is built: the plugin gives it its controller.
final class TuyaAdaptiveLight: Sendable {
    let draftIndex: Int
    let temperatureCode: String
    /// The colour and work mode DPs, as the device reports them.
    let colourCodes: Set<String>
    let mireds: @Sendable () -> Int?
    let isColour: @Sendable () -> Bool
    private let box = NIOLockedValueBox<AdaptiveLightingController?>(nil)

    init(draftIndex: Int, temperatureCode: String, colourCodes: Set<String>, mireds: @escaping @Sendable () -> Int?, isColour: @escaping @Sendable () -> Bool) {
        self.draftIndex = draftIndex
        self.temperatureCode = temperatureCode
        self.colourCodes = colourCodes
        self.mireds = mireds
        self.isColour = isColour
    }

    /// A push's values that say the light was set elsewhere turn Adaptive Lighting off: a white far from the one shown,
    /// or a colour. Called before the characteristics show the push.
    func check(_ items: [TuyaPushMessage.StatusItem]) {
        guard let controller, controller.isAdaptiveLightingActive else { return }
        if items.contains(where: { colourCodes.contains($0.code) }), isColour() {
            controller.disableIfChangedElsewhere(mireds: nil)
        } else if items.contains(where: { $0.code == temperatureCode }), let mireds = mireds() {
            controller.disableIfChangedElsewhere(mireds: mireds)
        }
    }

    var controller: AdaptiveLightingController? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

/// How an accessory's writes reach its device, with the debounce queue and the plugin's other services.
final class TuyaDeviceLink: Sendable {
    let device: TuyaDevice
    let api: TuyaOpenAPI
    let logger: Logger
    let timeScale: Double
    private let queue: TuyaCommandQueue
    /// Re-reads every characteristic (set once the accessory is built).
    private let refreshBox = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)

    init(device: TuyaDevice, api: TuyaOpenAPI, logger: Logger, timeScale: Double) {
        self.device = device
        self.api = api
        self.logger = logger
        self.timeScale = timeScale
        let deviceID = device.id
        queue = TuyaCommandQueue(delay: .milliseconds(100) * timeScale) { [logger] commands in
            do {
                try await api.sendCommands(deviceID, commands)
            } catch {
                logger.warning("Could not send \(commands.map(\.code).joined(separator: ", ")) to \(deviceID): \(error)")
            }
        }
    }

    var onRefresh: (@Sendable () -> Void)? {
        get { refreshBox.withLockedValue { $0 } }
        set { refreshBox.withLockedValue { $0 = newValue } }
    }

    func refresh() { onRefresh?() }

    /// Sends commands (plugin-side codes and values): through the override, refused while the device is offline,
    /// stored locally at once; `debounced` waits 100 ms for more and sends them together.
    func send(_ commands: [TuyaCommand], debounced: Bool) async throws {
        let converted = device.deviceCommands(commands)
        guard !converted.isEmpty else { return }
        guard device.online else {
            logger.warning("\(device.name) is offline: command skipped")
            refresh()
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        device.store(converted)
        if debounced {
            await queue.enqueue(converted)
        } else {
            try await api.sendCommands(device.id, converted)
        }
    }

    func send(_ code: String, _ value: JSONValue, debounced: Bool = true) async throws {
        try await send([TuyaCommand(code: code, value: value)], debounced: debounced)
    }

    /// The queue's commands now, for tests.
    func flush() async { await queue.flush() }
}

/// A device's writes waiting to go together: a later value for a code replaces the earlier in its place, and the batch
/// goes 100 ms after the last write. The batch is taken before it is sent, so writes meanwhile make the next one.
actor TuyaCommandQueue {
    private var pending: [TuyaCommand] = []
    private var timer: Task<Void, Never>?
    private let delay: Duration
    private let deliver: @Sendable ([TuyaCommand]) async -> Void

    init(delay: Duration, deliver: @escaping @Sendable ([TuyaCommand]) async -> Void) {
        self.delay = delay
        self.deliver = deliver
    }

    func enqueue(_ commands: [TuyaCommand]) {
        for command in commands {
            if let index = pending.firstIndex(where: { $0.code == command.code }) { pending[index].value = command.value } else { pending.append(command) }
        }
        timer?.cancel()
        let delay = delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        timer = nil
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        await deliver(batch)
    }
}

/// Builds one accessory's services from a device, category by category (TuyaCategories.swift), with the blocks those
/// share.
final class TuyaAccessoryBuilder {
    let device: TuyaDevice
    let link: TuyaDeviceLink
    let logger: Logger
    let adaptiveLightingAllowed: Bool
    var drafts: [TuyaServiceDraft] = []
    var events: [TuyaEventHandler] = []
    var adaptiveLights: [TuyaAdaptiveLight] = []
    /// The camera's video, when the category is `sp` and the device is not virtual.
    var wantsCamera = false
    /// The IR hub of a remote, whose temperature and humidity it shows.
    var parent: TuyaDevice?
    /// Accessories this one's state feeds (an IR hub's remotes).
    var accessoryName: String { device.name }

    init(device: TuyaDevice, link: TuyaDeviceLink, logger: Logger) {
        self.device = device
        self.link = link
        self.logger = logger
        adaptiveLightingAllowed = device.override?.adaptiveLighting != false
    }

    // MARK: Services

    /// The draft of a service of that type and subtype, added if there is none.
    @discardableResult
    func service(_ type: ServiceType, name: String? = nil, subtype: String? = nil, configuredName: Bool = false) -> TuyaServiceDraft {
        if let existing = drafts.first(where: { $0.type.uuid == type.uuid && $0.subtype == subtype }) { return existing }
        let draft = TuyaServiceDraft(type: type, name: name, subtype: subtype)
        if configuredName { draft.configuredName = name }
        drafts.append(draft)
        return draft
    }

    func find(_ codes: String...) -> TuyaSchemaItem? { device.find(codes) }

    /// Each list needs one of its codes; the missing ones are logged with what the device has.
    func require(_ lists: [[String]]) -> Bool {
        let missing = lists.filter { device.find($0) == nil }
        guard !missing.isEmpty else { return true }
        logger.warning(
            "\(device.name) (category \(device.category)) lacks \(missing.map { $0.joined(separator: " or ") }.joined(separator: "; ")). It has: \(device.specificationCodes.joined(separator: ", ")). Switch the product to DP Instruction mode in the Tuya IoT Platform, or add deviceOverrides.")
        return false
    }

    // MARK: Values

    func status(_ item: TuyaSchemaItem?) -> JSONValue? { device.status(item) }
    func bool(_ item: TuyaSchemaItem?) -> Bool? { device.bool(item) }
    func number(_ item: TuyaSchemaItem?) -> Double? { device.number(item) }
    func string(_ item: TuyaSchemaItem?) -> String? { device.string(item) }

    /// JavaScript's truthiness, as the source tests some statuses.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let value)?: value
        case .number(let value)?: value != 0
        case .string(let text)?: !text.isEmpty
        case .array?, .object?: true
        default: false
        }
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, value)) }

    static func remap(_ value: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        b == a ? c : c + (value - a) * (d - c) / (b - a)
    }

    /// A rounded integer for HomeKit, NaN and infinity as nil.
    static func int(_ value: Double) -> HAPValue? {
        guard value.isFinite else { return nil }
        return .int(Int(saturating: value.rounded()) ?? 0)
    }

    static func double(_ value: Double) -> HAPValue? { value.isFinite ? .double(value) : nil }

    /// A number as a Tuya integer DP takes it.
    static func json(_ value: Double) -> JSONValue { .number(value.isFinite ? value.rounded() : 0) }

    // MARK: Blocks

    /// On, from a boolean DP (online check); a write is debounced.
    func on(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem) {
        let link = link
        draft.add(.on, onlineCheck: true, get: { [device = device] in device.bool(item).map(HAPValue.bool) }) { value in
            try await link.send(item.code, .bool(value.boolValue ?? false))
        }
    }

    /// A Switch whose subtype and name are the DP's code, with On.
    func switchService(_ item: TuyaSchemaItem, name: String? = nil, type: ServiceType = .switch) {
        on(service(type, name: name ?? item.code, subtype: item.code, configuredName: name == nil), item)
    }

    /// Active, from a boolean DP (online check).
    func active(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem) {
        let link = link
        draft.add(.active, onlineCheck: true, get: { [device = device] in device.bool(item).map { .int($0 ? 1 : 0) } }) { value in
            try await link.send(item.code, .bool(value.intValue == 1))
        }
    }

    func currentTemperature(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem) {
        let multiple = item.multiple
        let low = Swift.max(-270, item.min / multiple), high = Swift.min(100, item.max / multiple)
        let range = low < high ? (low, high) : (-270.0, 100.0)
        draft.add(.currentTemperature.with(minValue: range.0, maxValue: range.1, minStep: Swift.max(0.1, item.step / multiple)), get: { [device = device] in
            device.number(item).flatMap { Self.double(Self.clamp($0 / multiple, range.0, range.1)) }
        })
    }

    func temperatureSensor(_ item: TuyaSchemaItem?) {
        guard let item else { return }
        currentTemperature(service(.temperatureSensor), item)
    }

    func currentHumidity(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem) {
        let multiple = item.multiple
        draft.add(.currentRelativeHumidity, get: { [device = device] in device.number(item).flatMap { Self.double(Self.clamp($0 / multiple, 0, 100)) } })
    }

    func humiditySensor(_ item: TuyaSchemaItem?) {
        guard let item else { return }
        currentHumidity(service(.humiditySensor), item)
    }

    func lockPhysicalControls(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem?) {
        guard let item else { return }
        let link = link
        draft.add(.lockPhysicalControls, get: { [device = device] in device.bool(item).map { .int($0 ? 1 : 0) } }) { value in
            try await link.send(item.code, .bool(value.intValue == 1))
        }
    }

    func swingMode(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem?) {
        guard let item else { return }
        let link = link
        draft.add(.swingMode, get: { [device = device] in device.bool(item).map { .int($0 ? 1 : 0) } }) { value in
            try await link.send(item.code, .bool(value.intValue == 1))
        }
    }

    func temperatureDisplayUnits(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem?) {
        guard let item else { return }
        let link = link
        draft.add(.temperatureDisplayUnits, get: { [device = device] in device.string(item).map { .int($0.lowercased() == "c" ? 0 : 1) } }) { [device = device] value in
            let current = device.string(item) ?? "c"
            let unit = value.intValue == 0 ? "c" : "f"
            let uppercase = current == current.uppercased() && current != current.lowercased()
            try await link.send(item.code, .string(uppercase ? unit.uppercased() : unit), debounced: false)
        }
    }

    /// Rotation Speed from an Integer DP.
    func rotationSpeed(_ draft: TuyaServiceDraft, integer item: TuyaSchemaItem) {
        let multiple = item.multiple
        let low = item.min / multiple, high = item.max / multiple
        let link = link
        draft.add(.rotationSpeed.with(minValue: low, maxValue: Swift.max(high, low + 1), minStep: Swift.max(1, item.step / multiple)), get: { [device = device] in
            device.number(item).flatMap { Self.double(Self.clamp($0 / multiple, low, high)) }
        }) { value in
            let raw = Self.clamp(((value.doubleValue ?? 0) * multiple).rounded(), item.min, item.max)
            try await link.send(item.code, .number(raw))
        }
    }

    /// Rotation Speed from an Enum DP's levels (1 for the first), `ignoring` some values.
    func rotationSpeed(_ draft: TuyaServiceDraft, levels item: TuyaSchemaItem, ignoring: [String] = []) {
        let levels = item.range.filter { !ignoring.contains($0) }
        guard !levels.isEmpty else { return }
        let link = link
        draft.add(.rotationSpeed.with(minValue: 0, maxValue: Double(levels.count), minStep: 1), get: { [device = device] in
            guard let current = device.string(item) else { return nil }
            return .double(Double(levels.firstIndex(of: current).map { $0 + 1 } ?? 0))
        }) { value in
            let index = Int(saturating: ((value.doubleValue ?? 0) - 1).rounded()) ?? -1
            guard levels.indices.contains(index) else { return }
            try await link.send(item.code, .string(levels[index]))
        }
    }

    /// Rotation Speed of a fan that is only on or off.
    func rotationSpeed(_ draft: TuyaServiceDraft, onOnly item: TuyaSchemaItem) {
        draft.add(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 100), get: { [device = device] in
            device.bool(item).map { .double($0 ? 100 : 0) }
        }) { _ in }
    }

    func dehumidifierThreshold(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem?) {
        guard let item else { return }
        threshold(draft, .relativeHumidityDehumidifierThreshold, item)
    }

    func threshold(_ draft: TuyaServiceDraft, _ type: CharacteristicType, _ item: TuyaSchemaItem, then: [TuyaCommand] = []) {
        let multiple = item.multiple
        let link = link
        draft.add(type.with(minValue: 0, maxValue: 100, minStep: Swift.max(1, item.step / multiple)), get: { [device = device] in
            device.number(item).flatMap { Self.double(Self.clamp($0 / multiple, 0, 100)) }
        }) { value in
            let raw = Self.clamp(((value.doubleValue ?? 0) * multiple).rounded(), item.min, item.max)
            try await link.send(item.code, .number(raw), debounced: false)
            if !then.isEmpty { try await link.send(then, debounced: false) }
        }
    }

    /// An Air Quality Sensor from a quality DP (Integer or Enum), with the densities the device has.
    func airQuality(quality: TuyaSchemaItem?, pm25: TuyaSchemaItem?, pm10: TuyaSchemaItem?, voc: TuyaSchemaItem?) {
        let draft = service(.airQualitySensor)
        draft.add(.airQuality, get: { [device = device] in
            guard let quality else { return .int(0) }
            if quality.type == "Integer" {
                guard let raw = device.number(quality) else { return nil }
                let value = Self.clamp(raw / quality.multiple, 0, 1000)
                return .int(value <= 10 ? 1 : value <= 50 ? 2 : value <= 100 ? 3 : value <= 200 ? 4 : 5)
            }
            if quality.type == "Enum" {
                return .int(["great": 1, "good": 2, "mild": 3, "medium": 4, "severe": 5][device.string(quality) ?? ""] ?? 0)
            }
            return .int(0)
        })
        for (item, type) in [(pm25, CharacteristicType.pm2_5Density), (pm10, .pm10Density), (voc, .vocDensity)] {
            guard let item else { continue }
            draft.add(type, get: { [device = device] in device.number(item).flatMap { Self.double(Self.clamp($0 / item.multiple, 0, 1000)) } })
        }
    }

    func motionSensor(_ item: TuyaSchemaItem?) {
        guard let item else { return }
        service(.motionSensor).add(.motionDetected, get: { [device = device] in
            .bool(item.type == "Enum" && device.string(item) == "pir")
        })
    }

    func occupancySensor(_ item: TuyaSchemaItem?, draft: TuyaServiceDraft? = nil, detected: Set<String> = ["presence"]) {
        guard let item else { return }
        (draft ?? service(.occupancySensor)).add(.occupancyDetected, get: { [device = device] in
            device.string(item).map { .int(detected.contains($0) ? 1 : 0) }
        })
    }

    /// A Programmable Switch Event whose props come from the DP, and whose presses come from pushes only.
    @discardableResult
    func programmableSwitch(_ draft: TuyaServiceDraft, _ item: TuyaSchemaItem, listen: Bool = true) -> TuyaCharacteristicRef {
        var single = true, double = false, long = false
        if item.type == "Enum" {
            let range = item.range
            single = range.contains { ["click", "single_click", "1"].contains($0) }
            double = range.contains("double_click")
            long = range.contains { ["press", "long_press"].contains($0) }
            if !single, !double, !long { single = true }
        }
        let supported = [single ? 0 : nil, double ? 1 : nil, long ? 2 : nil].compactMap { $0 }
        let type = CharacteristicType.programmableSwitchEvent.with(
            minValue: Double(supported.first ?? 0), maxValue: Double(supported.last ?? 0), validValues: supported)
        let ref = draft.add(type)
        guard listen else { return ref }
        let code = device.deviceCode(for: item.code), itemType = item.type
        let logger = logger, name = device.name
        events.append { items in
            guard let pushed = items.last(where: { $0.code == code }),
                  let event = Self.pressEvent(pushed.value, type: itemType, logger: logger, name: name) else { return }
            ref.characteristic?.sendEvent(.int(event))
        }
        return ref
    }

    static func pressEvent(_ value: JSONValue, type: String, logger: Logger, name: String) -> Int? {
        switch (type, value) {
        case ("Raw", .string(let text)), ("String", .string(let text)):
            guard let data = Data(base64Encoded: text), !data.isEmpty else { break }
            logger.info("\(name): \(String(decoding: data, as: UTF8.self))")
            return 0
        case ("Enum", .string(let text)):
            if ["click", "single_click", "1"].contains(text) { return 0 }
            if text == "double_click" { return 1 }
            if ["press", "long_press"].contains(text) { return 2 }
        case ("Integer", .number(let number)) where number > 0:
            return 0
        default:
            break
        }
        logger.warning("\(name): a press Homeswift cannot read: \(value.text())")
        return nil
    }

    /// Eve's power characteristics on the service, from the DPs the device has.
    func energy(_ draft: TuyaServiceDraft) {
        for (code, type) in [("cur_current", TuyaEve.amperes), ("cur_power", TuyaEve.watts), ("cur_voltage", TuyaEve.volts), ("add_ele", TuyaEve.kilowattHours)] {
            guard let item = find(code) else { continue }
            let divisor = code == "cur_current" && item.unit == "mA" ? 1000 * item.multiple : item.multiple
            draft.add(type, get: { [device = device] in device.number(item).flatMap { Self.double($0 / divisor) } })
        }
    }

    /// A motion sensor that goes on when an event comes and off `duration` after the last.
    func pulseMotion(_ draft: TuyaServiceDraft, duration: Duration, when trigger: @escaping @Sendable ([TuyaPushMessage.StatusItem]) -> Bool) {
        let ref = draft.add(.motionDetected, value: .bool(false))
        let reset = NIOLockedValueBox<Task<Void, Never>?>(nil)
        let scaled = duration * link.timeScale
        events.append { items in
            guard trigger(items) else { return }
            ref.characteristic?.value = .bool(true)
            let task = Task {
                try? await Task.sleep(for: scaled)
                guard !Task.isCancelled else { return }
                ref.characteristic?.value = .bool(false)
            }
            reset.withLockedValue { previous in
                previous?.cancel()
                previous = task
            }
        }
    }

    /// A switch whose write does something once and turns itself back off after 150 ms (scenes, IR keys).
    func momentarySwitch(_ draft: TuyaServiceDraft, awaitAction: Bool, action: @escaping @Sendable () async throws -> Void) {
        let scaled = Duration.milliseconds(150) * link.timeScale
        let logger = logger
        let ref = TuyaCharacteristicRef()
        draft.add(.on, value: .bool(false), ref: ref, get: { .bool(false) }) { value in
            guard value.boolValue == true else { return }
            let resetLater = { @Sendable in
                Task {
                    try? await Task.sleep(for: scaled)
                    ref.characteristic?.value = .bool(false)
                }
            }
            if awaitAction {
                do {
                    try await action()
                } catch {
                    logger.warning("Could not run it: \(error)")
                    _ = resetLater()
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            } else {
                Task {
                    do { try await action() } catch { logger.warning("Could not send it: \(error)") }
                }
            }
            _ = resetLater()
        }
    }

    // MARK: Battery and StatusActive

    /// The Battery service when the device reports a level, and StatusActive on every service.
    func finish() {
        if let level = find("battery_percentage", "residual_electricity", "wireless_electricity", "va_battery", "battery") {
            let draft = service(.battery)
            draft.add(.batteryLevel, get: { [device = device] in device.number(level).flatMap { Self.int(Self.clamp($0 / level.multiple, 0, 100)) } })
            let state = find("battery_state")
            draft.add(.statusLowBattery, get: { [device = device] in
                if let state { return device.string(state).map { .int($0 == "low" ? 1 : 0) } }
                return device.number(level).map { .int($0 <= 20 ? 1 : 0) }
            })
            if let charging = find("charge_state") {
                draft.add(.chargingState, get: { [device = device] in device.bool(charging).map { .int($0 ? 1 : 0) } })
            }
        }
        let device = device
        for draft in drafts { draft.add(.statusActive, get: { .bool(device.online) }) }
    }
}

/// Eve's custom power characteristics (Eve Energy's).
enum TuyaEve {
    static let amperes = CharacteristicType(name: "Amperes", uuid: HAPUUID("E863F126-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.events, .pairedRead])
    static let watts = CharacteristicType(name: "Consumption", uuid: HAPUUID("E863F10D-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.events, .pairedRead])
    static let volts = CharacteristicType(name: "Volts", uuid: HAPUUID("E863F10A-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.events, .pairedRead])
    static let kilowattHours = CharacteristicType(name: "Total Consumption", uuid: HAPUUID("E863F10C-079E-48FF-8F27-9C2605A29F52"), format: .float, permissions: [.events, .pairedRead])
}

extension TuyaDevice {
    func status(_ item: TuyaSchemaItem?) -> JSONValue? { item.flatMap { status($0.code) } }

    func bool(_ item: TuyaSchemaItem?) -> Bool? {
        guard let value = status(item) else { return nil }
        return value.boolValue ?? TuyaAccessoryBuilder.truthy(value)
    }

    func number(_ item: TuyaSchemaItem?) -> Double? {
        switch status(item) {
        case .number(let value)?: value
        case .bool(let value)?: value ? 1 : 0
        case .string(let text)?: Double(text)
        default: nil
        }
    }

    func string(_ item: TuyaSchemaItem?) -> String? {
        switch status(item) {
        case .string(let text)?: text
        case .number(let number)?: TuyaDevice.text(.number(number))
        case .bool(let value)?: value ? "true" : "false"
        default: nil
        }
    }

}
