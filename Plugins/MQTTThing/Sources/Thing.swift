import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Whether an accessory (or an entry of a `custom` one) answers: from its `getOnline` topic and from confirmation
/// (sections 6.1, 6.2, 6.5). Read on HomeKit's path, so it is a lock, not an actor.
final class OnlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }
}

/// How a characteristic's value travels (section 3.4).
enum Kind {
    case bool(Booleans)
    case int
    case float
    case string
    case enumeration(Enumeration)
}

/// One accessory block at run time: its subscriptions and publishes, timers, and the characteristics they drive. All
/// of its state is the actor's; characteristic handlers and broker messages come in through it.
actor Thing {
    struct Dependencies: Sendable {
        /// Scales every delay (`turnOffAfterms`, confirmation, debounce, coalescing): tests run them faster.
        var timeScale: Double = 1
        var now: @Sendable () -> Date = { Date() }
        var hostName: String = ProcessInfo.processInfo.hostName
    }

    let config: Config
    let id: String
    let broker: Broker
    let logger: Logger
    let dependencies: Dependencies
    let context: PluginContext
    let logMqtt: Bool
    private let optimizePublishing: Bool
    private let debounce: Duration?
    private let publishQoS: MQTTQoS
    private let publishRetain: Bool
    /// The built-in `json` codec, when the block names it (section 8.3).
    let codec: JSONCodecSettings?

    private struct Subscription {
        var property: String
        var path: [JSONPath.Step]?
        var handler: (JSONValue) -> Void
        var number: Int
    }

    private var subscriptions: [String: [Subscription]] = [:]
    private var lastPayloads: [String: String] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var timerActions: [String: (generation: Int, action: () -> Void)] = [:]
    private var generation = 0
    private var writeHandlers: [ObjectIdentifier: (HAPValue) -> Void] = [:]
    private var notedApply: Set<String> = []
    /// The json codec's messages waiting for their 50 ms, by topic.
    var codecPending: [String: OrderedJSON] = [:]
    var codecRetained: [String: OrderedJSON] = [:]
    /// What `build()` made, kept for as long as the accessory runs (Adaptive Lighting controllers, Eve histories).
    var keep: [AnyObject] = []
    var adaptiveLighting: [AdaptiveLightingController] = []
    /// Each light's state, by its service builder.
    var lightStates: [ObjectIdentifier: LightState] = [:]

    init(config: Config, id: String, broker: Broker, context: PluginContext, dependencies: Dependencies) {
        self.config = config
        self.id = id
        self.broker = broker
        self.context = context
        self.dependencies = dependencies
        var logger = context.logger
        logger[metadataKey: "accessory"] = "\(config.name)"
        self.logger = logger
        logMqtt = config.flag("logMqtt")
        optimizePublishing = config.flag("optimizePublishing")
        debounce = config.milliseconds("debounceRecvms")
        let options = config["mqttPubOptions"]
        publishQoS = (options?["qos"]?.doubleValue ?? 0) >= 1 ? .atLeastOnce : .atMostOnce
        publishRetain = options?["retain"]?.boolValue ?? false
        codec = JSONCodecSettings(config, logger: logger)
    }

    // MARK: Time

    func scaled(_ duration: Duration) -> Duration { duration * dependencies.timeScale }

    /// Runs `action` after `delay` (scaled, unless `scaled` is false), replacing what was waiting under `key`.
    func after(_ key: String, _ delay: Duration, scaled: Bool = true, _ action: @escaping () -> Void) {
        timers[key]?.cancel()
        generation += 1
        let mine = generation
        timerActions[key] = (mine, action)
        let delay = scaled ? self.scaled(delay) : delay
        timers[key] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.fire(key, mine)
        }
    }

    func cancel(_ key: String) {
        timers.removeValue(forKey: key)?.cancel()
        timerActions.removeValue(forKey: key)
    }

    func isWaiting(_ key: String) -> Bool { timerActions[key] != nil }

    private func fire(_ key: String, _ generation: Int) {
        guard let entry = timerActions[key], entry.generation == generation else { return }
        timerActions.removeValue(forKey: key)
        timers.removeValue(forKey: key)
        entry.action()
    }

    func stop() {
        for task in timers.values { task.cancel() }
        timers.removeAll()
        timerActions.removeAll()
        subscriptions.removeAll()
        writeHandlers.removeAll()
        for history in keep.compactMap({ $0 as? EveHistory }) { history.flush() }
        keep.removeAll()
        adaptiveLighting.removeAll()
    }

    // MARK: MQTT in

    /// A topic key's topic, or nil (with a line, once) for one whose `apply` JavaScript Homeswift cannot run.
    func spec(_ config: Config, _ key: String, get: Bool) -> TopicSpec? {
        guard let spec = TopicSpec(config.topics[key], get: get) else { return nil }
        if spec.hasApply {
            if notedApply.isEmpty {
                logger.warning("\(config.name): \"apply\" functions are JavaScript, which Homeswift does not run; the topics that have one are left out")
            }
            if notedApply.insert(key).inserted { logger.info("\(config.name): \(key) is left out (it has an \"apply\" function)") }
            return nil
        }
        return spec
    }

    /// Subscribes `handler` to the topic of `key`, after JSONPath, the codec and the debounce (section 3.5).
    func subscribe(_ config: Config, _ key: String, property: String, _ handler: @escaping (JSONValue) -> Void) {
        guard let spec = spec(config, key, get: true) else { return }
        generation += 1
        let first = subscriptions[spec.topic] == nil
        subscriptions[spec.topic, default: []].append(Subscription(property: property, path: spec.path, handler: handler, number: generation))
        if first { broker.subscribe(spec.topic, for: self) }
    }

    func received(topic: String, payload: Data) {
        let text = String(decoding: payload, as: UTF8.self)
        if logMqtt { logger.info("Received MQTT: \(topic) = \(text)") }
        for subscription in subscriptions[topic] ?? [] {
            var message = JSONValue.string(text)
            if let path = subscription.path {
                guard let json = try? JSONValue(string: text), let found = JSONPath.first(path, in: json) else {
                    if logMqtt { logger.info("JSONPath found nothing in \(topic)") }
                    continue
                }
                message = found
            }
            if let codec {
                guard let decoded = codecDecode(codec, property: subscription.property, message: message) else { continue }
                message = decoded
            }
            if let debounce {
                let handler = subscription.handler
                after("debounce-\(subscription.number)", debounce) { handler(message) }
            } else {
                subscription.handler(message)
            }
        }
    }

    // MARK: MQTT out

    /// Publishes `value` on the topic of `key` through the codec (section 3.5); nil publishes nothing.
    func publish(_ config: Config, _ key: String, property: String, _ value: JSONValue?) {
        guard let value, let spec = spec(config, key, get: false) else { return }
        if let codec {
            codecEncode(codec, topic: spec.topic, property: property, value: value)
            return
        }
        publish(topic: spec.topic, payload: JS.text(value))
    }

    /// The last step: `optimizePublishing`, the log, `mqttPubOptions`.
    func publish(topic: String, payload: String) {
        if optimizePublishing, lastPayloads[topic] == payload { return }
        lastPayloads[topic] = payload
        if logMqtt { logger.info("Publishing MQTT: \(topic) = \(payload)") }
        let message = MQTTMessage(topic: topic, payload: Data(payload.utf8), qos: publishQoS, retain: publishRetain)
        broker.publish(message)
    }

    // MARK: Characteristics

    /// The handlers HomeKit's writes reach, set by `onWrite`.
    func onWrite(_ characteristic: Characteristic, _ handler: @escaping (HAPValue) -> Void) {
        let key = ObjectIdentifier(characteristic)
        let installed = writeHandlers[key] != nil
        writeHandlers[key] = handler
        guard !installed else { return }
        characteristic.onWrite { [weak self] value in await self?.homeKitWrote(key, value) }
    }

    private func homeKitWrote(_ key: ObjectIdentifier, _ value: HAPValue) {
        writeHandlers[key]?(value)
    }

    /// Reads answer the stored value, or No Response while `online` says offline.
    nonisolated func serveReads(_ characteristic: Characteristic, _ online: OnlineState) {
        characteristic.onRead { [weak characteristic] in
            guard online.isOnline else { throw HAPStatusError(.serviceCommunicationFailure) }
            return characteristic?.value ?? .null
        }
    }

    nonisolated static func hap(_ flag: Bool, for characteristic: Characteristic) -> HAPValue {
        characteristic.type.format == .bool ? .bool(flag) : .int(flag ? 1 : 0)
    }

    /// What a received message means for `characteristic`, before validation; nil for one to ignore.
    func decode(_ kind: Kind, _ message: JSONValue, for characteristic: Characteristic, key: String) -> HAPValue? {
        switch kind {
        case .bool(let booleans):
            return booleans.decode(message).map { Self.hap($0, for: characteristic) }
        case .int:
            return JS.parseInt(message).map(HAPValue.int) ?? .double(.nan)
        case .float:
            return .double(JS.parseFloat(message) ?? .nan)
        case .string:
            return .string(JS.text(message))
        case .enumeration(let enumeration):
            guard let index = enumeration.index(of: message) else {
                if logMqtt { logger.info("Unknown value \(JS.text(message)) on \(key)") }
                return nil
            }
            return .int(index)
        }
    }

    /// What HomeKit's value is published as.
    static func encode(_ kind: Kind, _ value: HAPValue) -> JSONValue? {
        switch kind {
        case .bool(let booleans): booleans.encode(value.boolValue ?? false)
        case .int: value.intValue.map { .number(Double($0)) }
        case .float: value.doubleValue.map(JSONValue.number)
        case .string: value.stringValue.map(JSONValue.string)
        case .enumeration(let enumeration): value.intValue.flatMap(enumeration.value)
        }
    }

    /// Why `value` does not fit the characteristic (section 6.4), or nil.
    func invalid(_ value: HAPValue, for characteristic: Characteristic, config: Config) -> String? {
        if config["validate"] == .bool(false) { return nil }
        let type = characteristic.type
        func range(_ number: Double) -> String? {
            if let minimum = type.minValue, number < minimum { return "below minimum (\(JSONValue.number(minimum).text()))" }
            if let maximum = type.maxValue, number > maximum { return "above maximum (\(JSONValue.number(maximum).text()))" }
            return nil
        }
        switch type.format {
        case .int, .uint8, .uint16, .uint32, .uint64:
            guard let number = value.doubleValue, number.isFinite, number.rounded() == number, value.stringValue == nil else { return "not an integer" }
            return range(number)
        case .float:
            guard let number = value.doubleValue, !number.isNaN else { return "not a number" }
            return range(number)
        case .bool:
            guard case .bool = value else { return "not a boolean" }
            return nil
        case .string:
            return value.stringValue == nil ? "not a string" : nil
        default:
            return nil
        }
    }

    static func same(_ a: HAPValue, _ b: HAPValue) -> Bool {
        if let x = a.doubleValue, let y = b.doubleValue { return x == y }
        return a == b
    }

    /// Ties a characteristic to its get and set topics (section 5's tables). `received` runs on every valid message
    /// (`changed` tells whether it changed the value), `wrote` after each HomeKit write was published.
    func bind(
        _ characteristic: Characteristic, _ config: Config, _ kind: Kind, get: String?, set: String?, property: String, online: OnlineState,
        eventOnly: Bool = false, received: ((HAPValue, Bool) -> Void)? = nil, wrote: ((HAPValue) -> Void)? = nil
    ) {
        if !eventOnly { serveReads(characteristic, online) }
        if let set, config.has(set) {
            onWrite(characteristic) { value in
                self.publish(config, set, property: property, Self.encode(kind, value))
                wrote?(value)
            }
        } else if let wrote {
            onWrite(characteristic, wrote)
        }
        guard let get, config.has(get) else { return }
        subscribe(config, get, property: property) { [weak characteristic] message in
            guard let characteristic, let value = self.decode(kind, message, for: characteristic, key: get) else { return }
            self.apply(value, to: characteristic, config: config, eventOnly: eventOnly, received: received)
        }
    }

    /// A received value: validated, then set when it changed (an event-only one fires every time).
    func apply(_ value: HAPValue, to characteristic: Characteristic, config: Config, eventOnly: Bool = false, received: ((HAPValue, Bool) -> Void)? = nil) {
        if let reason = invalid(value, for: characteristic, config: config) {
            logger.warning("Ignoring invalid value [\(value.doubleValue.map { JSONValue.number($0).text() } ?? value.stringValue ?? "\(value)")] for \(characteristic.type.name) - \(reason)")
            return
        }
        if eventOnly {
            characteristic.sendEvent(value)
            received?(value, true)
            return
        }
        let changed = !Self.same(characteristic.value, value)
        if changed { characteristic.value = value }
        received?(value, changed)
    }
}
