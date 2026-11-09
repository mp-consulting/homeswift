import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A device of `bridge/devices` (4.1), or a group as a device (11).
struct DeviceEntry: Codable, Sendable, Equatable {
    struct Definition: Codable, Sendable, Equatable {
        var vendor: String?
        var model: String?
        var exposes: [Expose]?
    }

    /// For a group, its id as text.
    var ieeeAddress: String
    var friendlyName: String
    var supported: Bool?
    var groupID: Int?
    var definition: Definition?
    var softwareBuildID: String?
    var dateCode: String?

    enum CodingKeys: String, CodingKey {
        case ieeeAddress = "ieee_address", friendlyName = "friendly_name", supported, groupID = "group_id", definition
        case softwareBuildID = "software_build_id", dateCode = "date_code"
    }

    init(ieeeAddress: String, friendlyName: String, supported: Bool? = true, groupID: Int? = nil, definition: Definition?, softwareBuildID: String? = nil, dateCode: String? = nil) {
        self.ieeeAddress = ieeeAddress
        self.friendlyName = friendlyName
        self.supported = supported
        self.groupID = groupID
        self.definition = definition
        self.softwareBuildID = softwareBuildID
        self.dateCode = dateCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ieeeAddress = try container.decode(String.self, forKey: .ieeeAddress)
        friendlyName = (try? container.decodeIfPresent(String.self, forKey: .friendlyName)) ?? ieeeAddress
        supported = try? container.decodeIfPresent(Bool.self, forKey: .supported)
        groupID = try? container.decodeIfPresent(Int.self, forKey: .groupID)
        definition = try? container.decodeIfPresent(Definition.self, forKey: .definition)
        softwareBuildID = try? container.decodeIfPresent(String.self, forKey: .softwareBuildID)
        dateCode = try? container.decodeIfPresent(String.self, forKey: .dateCode)
    }

    var isGroup: Bool { groupID != nil }
    /// The Device Id, after `zigbee2mqtt:` in the accessory's id: the IEEE address, or `group-<id>` (3.1).
    var deviceID: String { groupID.map { "group-\($0)" } ?? ieeeAddress }
    /// The topic `set` and `get` go under: the IEEE address, stable across renames, or a group's name.
    var commandTopic: String { isGroup ? friendlyName : ieeeAddress }
    /// The ids its `devices` entry may name.
    var optionIDs: [String] { isGroup ? [friendlyName, ieeeAddress] : [ieeeAddress, friendlyName] }
    var hasValidDefinition: Bool {
        guard let definition else { return false }
        return !(definition.vendor ?? "").isEmpty && !(definition.model ?? "").isEmpty && definition.exposes != nil
    }

    /// What 6.8 compares: the exposes in any order.
    func sameInformation(as other: DeviceEntry) -> Bool {
        guard friendlyName == other.friendlyName, ieeeAddress == other.ieeeAddress, supported == other.supported, groupID == other.groupID,
              softwareBuildID == other.softwareBuildID, dateCode == other.dateCode else { return false }
        switch (definition, other.definition) {
        case (nil, nil): return true
        case let (a?, b?): return a.vendor == b.vendor && a.model == b.model && Expose.collectionsMatch(a.exposes ?? [], b.exposes ?? [])
        default: return false
        }
    }
}

/// A device's accessory and what the plugin keeps of it.
final class DeviceAccessory {
    let entry: DeviceEntry
    let options: DeviceOptions
    let handlers: [any ServiceHandler]
    let accessory: Accessory
    /// What a `get` asks for, from every handler.
    let gettableKeys: [String]
    /// Zigbee2MQTT reports this device's availability (10.1).
    var availabilityEnabled = true
    /// Its last availability message.
    var online = true
    var refresh: Task<Void, Never>?
    /// Its last state message.
    var lastState: ContinuousClock.Instant?
    /// What it does when its power comes on, as its state last said (`power_on_behavior`, `color_temp_startup`).
    var powerOnState: [String: JSONValue] = [:]

    init(entry: DeviceEntry, options: DeviceOptions, handlers: [any ServiceHandler], accessory: Accessory) {
        self.entry = entry
        self.options = options
        self.handlers = handlers
        self.accessory = accessory
        gettableKeys = handlers.flatMap(\.gettableKeys)
    }

    deinit { refresh?.cancel() }
}

/// Publishes `set` and `get` for the accessories: the writes of one moment for one device merged into one message
/// (a request's On and Brightness, a slider's drag), and kept while the broker is away.
final class Publisher: Sendable {
    private struct Pending {
        var set: [String: JSONValue] = [:]
        var get: [String] = []
    }

    let baseTopic: String
    private let connection: any MQTTConnection
    private let qos: MQTTQoS
    private let log: Log
    private let level: Settings.PublishLevel
    private let coalesce: LatestCallGuard
    private let tasks: TaskBag
    private let pending = NIOLockedValueBox<[String: Pending]>([:])
    private let backlog = NIOLockedValueBox<[MQTTMessage]>([])
    /// What is kept while the broker is away, the oldest dropped first.
    static let backlogLimit = 200

    init(connection: any MQTTConnection, settings: Settings, log: Log, coalescing: Duration, tasks: TaskBag) {
        self.connection = connection
        baseTopic = settings.mqtt.baseTopic
        // QoS 2 is not sent by Homeswift's MQTT client: `set` goes at least once.
        qos = settings.mqtt.disableQoS ? .atMostOnce : .atLeastOnce
        self.log = log
        level = settings.publishLevel
        coalesce = LatestCallGuard(delay: coalescing)
        self.tasks = tasks
    }

    func set(_ topic: String, _ partial: [String: JSONValue]) {
        pending.withLockedValue { $0[topic, default: Pending()].set.merge(partial) { $1 } }
        schedule(topic)
    }

    func get(_ topic: String, _ keys: [String]) {
        guard !keys.isEmpty else { return }
        pending.withLockedValue { pending in
            for key in keys where !pending[topic, default: Pending()].get.contains(key) { pending[topic, default: Pending()].get.append(key) }
        }
        schedule(topic)
    }

    private func schedule(_ topic: String) {
        let coalesce = self.coalesce
        tasks.add { [weak self] in
            guard await coalesce(topic) else { return }
            await self?.flush(topic)
        }
    }

    private func flush(_ topic: String) async {
        guard let taken = pending.withLockedValue({ $0.removeValue(forKey: topic) }) else { return }
        if !taken.set.isEmpty { await publish("\(baseTopic)/\(topic)/set", .object(taken.set), qos: qos) }
        if !taken.get.isEmpty {
            await publish("\(baseTopic)/\(topic)/get", .object(Dictionary(taken.get.map { ($0, JSONValue.number(0)) }) { a, _ in a }), qos: qos)
        }
    }

    private func publish(_ topic: String, _ payload: JSONValue, qos: MQTTQoS) async {
        let text = payload.text()
        let line = "Publishing to \(topic): \(text)"
        switch level {
        case .debug: log.debug(line)
        case .info: log.info(line)
        case .warn: log.warning(line)
        case .error: log.error(line)
        }
        await send(MQTTMessage(topic: topic, string: text, qos: qos))
    }

    private func send(_ message: MQTTMessage) async {
        do {
            try await connection.publish(message)
        } catch MQTTError.notConnected {
            backlog.withLockedValue { backlog in
                backlog.append(message)
                if backlog.count > Self.backlogLimit { backlog.removeFirst(backlog.count - Self.backlogLimit) }
            }
        } catch {
            log.error("Could not publish to \(message.topic): \(error)")
        }
    }

    /// Sends what was kept while the broker was away.
    func sendBacklog() async {
        let messages = backlog.withLockedValue { backlog in
            defer { backlog = [] }
            return backlog
        }
        for message in messages { await send(message) }
    }
}
