import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The broker's user name and password, kept in the vault by Setup.
struct BrokerLogin: Codable, Sendable, Equatable {
    var user: String?
    var password: String
}

// Setup (GLOSSARY.md, "Setup"): the instance's account is the MQTT broker Zigbee2MQTT publishes on, an Account Login
// (its address, the base topic, a user name and a password). The password goes in the vault, never in config.json;
// the devices and groups come with Zigbee2MQTT and need nothing more, and an Excluded one is never an accessory.
extension Zigbee2MQTTPlugin {
    public static let accountAuthorization = AuthorizationMethod.accountLogin

    /// Set up once the block names a broker, whether Setup or a pasted Homebridge block did.
    public func accountAuthorized() async -> Bool? { (try? Settings(configuration.block)) != nil }

    /// The devices and groups Zigbee2MQTT reports: the lists the plugin has, or, on an instance that has none (one made
    /// for Setup), Zigbee2MQTT's retained lists read once from the broker.
    public func discover() async throws -> [DiscoveredDevice] {
        guard let settings = settings ?? (try? Settings(configuration.block)) else { return [] }
        let lists: (devices: [DeviceEntry], groups: [JSONValue])
        if let known = knownLists {
            lists = known
        } else {
            lists = try await Self.readBridge(mqttSettings(settings), dependencies: dependencies)
        }
        var entries = lists.devices.filter(\.hasValidDefinition)
        entries += lists.groups.compactMap { group in
            guard let id = group["id"]?.intValue, let name = group["friendly_name"]?.stringValue else { return nil }
            return DeviceEntry(ieeeAddress: String(id), friendlyName: name, groupID: id, definition: .init(vendor: "Zigbee2MQTT", model: "GROUP-\(id)", exposes: []))
        }
        let members = Self.members(of: lists.groups)
        return entries.sorted { $0.friendlyName < $1.friendlyName }.map { entry in
            let options = settings.options(for: entry.optionIDs)
            let grouped = settings.excludeGroupedDevices && !entry.isGroup && members.contains(entry.ieeeAddress)
            var device = DiscoveredDevice(
                deviceID: entry.deviceID, name: entry.friendlyName, model: entry.definition?.model, isSetUp: true,
                excludedBySettings: options.exclude ?? grouped)
            if let accessory = devices[entry.deviceID]?.accessory { device.isReachable = !accessory.isUnavailable }
            return device
        }
    }

    /// The broker's address, Zigbee2MQTT's base topic, and a login if the broker asks for one; checked by reading
    /// Zigbee2MQTT's device list there.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Zigbee2MQTT devices come with the broker: they need no setup of their own")
        var mqtt = configuration.block["mqtt"]?.objectValue ?? [:]
        guard let server = request.answer("server") else {
            return .ask(SetupPrompt(
                message: "Enter the MQTT broker Zigbee2MQTT publishes on, as in Zigbee2MQTT's own mqtt settings.",
                fields: [
                    SetupField("server", label: "Broker address", value: mqtt["server"]?.stringValue ?? "mqtt://localhost:1883"),
                    SetupField("base_topic", label: "Base topic", value: mqtt["base_topic"]?.stringValue ?? "zigbee2mqtt"),
                    SetupField("user", label: "User name", optional: true, value: mqtt["user"]?.stringValue),
                    SetupField("password", label: "Password", kind: .secret, optional: true),
                ]))
        }
        let base = request.answer("base_topic") ?? "zigbee2mqtt"
        let user = request.answer("user")
        let password = request.secret("password") ?? (mqtt["user"]?.stringValue == user ? context.credentials(as: BrokerLogin.self)?.password : nil)
        mqtt["server"] = .string(server)
        mqtt["base_topic"] = .string(base)
        mqtt["user"] = user.map(JSONValue.string)
        mqtt["password"] = nil
        var block = configuration.block.objectValue ?? [:]
        block["mqtt"] = .object(mqtt)
        guard let settings = try? Settings(.object(block)) else { throw SetupError("Enter the broker's address, such as mqtt://192.168.1.10:1883") }
        var login = settings.mqtt
        login.password = password
        let lists: (devices: [DeviceEntry], groups: [JSONValue])
        do {
            lists = try await Self.readBridge(login, dependencies: dependencies)
        } catch MQTTError.connectionRefused(let code) where [4, 5, 0x86, 0x87].contains(code) {
            throw SetupError("The broker refused the user name or password")
        } catch {
            throw SetupError("Could not reach the broker at \(Self.masked(server)): \(error)")
        }
        logger.info("Zigbee2MQTT found on \(Self.masked(server)): \(lists.devices.count) devices and \(lists.groups.count) groups")
        guard let password else { return .done(SetupOutcome(settings: ["mqtt": .object(mqtt)])) }
        return .done(try SetupOutcome(encoding: BrokerLogin(user: user, password: password), settings: ["mqtt": .object(mqtt)]))
    }

    private var logger: Logger { context.logger }

    /// Zigbee2MQTT's retained device and group lists, read once; throws when the broker does not answer or no
    /// Zigbee2MQTT publishes on the base topic.
    static func readBridge(_ mqtt: Settings.MQTT, dependencies: Dependencies) async throws -> (devices: [DeviceEntry], groups: [JSONValue]) {
        var configuration = try mqttConfiguration(mqtt, readFile: dependencies.readFile)
        configuration.reconnect = nil
        configuration.connectTimeout = dependencies.bridgeTimeout
        let connection = dependencies.connect(configuration)
        let base = mqtt.baseTopic
        let messages = connection.messages
        try await connection.subscribe("\(base)/bridge/devices", qos: .atMostOnce)
        try await connection.subscribe("\(base)/bridge/groups", qos: .atMostOnce)
        do {
            try await connection.connect()
        } catch {
            await connection.disconnect()
            throw error
        }
        let timeout = dependencies.bridgeTimeout
        let found: (devices: [DeviceEntry]?, groups: [JSONValue]?) = await withTaskGroup(of: (devices: [DeviceEntry]?, groups: [JSONValue]?)?.self) { group in
            group.addTask {
                var devices: [DeviceEntry]?, groups: [JSONValue]?
                for await message in messages {
                    if message.topic == "\(base)/bridge/devices" {
                        devices = (try? JSONValue(data: message.payload))?.arrayValue?.compactMap { try? $0.decode(DeviceEntry.self) }
                    } else if message.topic == "\(base)/bridge/groups" {
                        groups = (try? JSONValue(data: message.payload))?.arrayValue
                    }
                    if devices != nil, groups != nil { break }
                }
                return (devices, groups)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? (nil, nil)
        }
        await connection.disconnect()
        guard let devices = found.devices else {
            throw SetupError("No Zigbee2MQTT device list on \(base)/bridge/devices: check the base topic, and that Zigbee2MQTT runs")
        }
        return (devices, found.groups ?? [])
    }
}
