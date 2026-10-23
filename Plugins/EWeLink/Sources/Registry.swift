import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The accessories, their handlers and timers live on one actor, as they lived on Node's single thread: a
/// handler's state is never touched by two things at once, and the code reads like the Homebridge plugin's.
@globalActor actor EWeLinkActor {
    static let shared = EWeLinkActor()
}

/// A device in the platform's cache. Every handler of a device shares its box, so a command one channel
/// sent is seen by the others, as the Homebridge plugin's shared `params` object was.
@EWeLinkActor
final class DeviceBox {
    var device: EWeLinkDevice

    init(_ device: EWeLinkDevice) {
        self.device = device
    }

    var params: DeviceParams {
        get { device.params }
        set { device.params = newValue }
    }
}

/// What a handler is attached to: the HomeKit accessory's id and name, and where the device behind it sits
/// (a channel of a multi-channel device, a button of an RF Bridge). The Homebridge plugin's accessory context.
struct AccessoryRecord: Sendable {
    /// `eWeLink:<device id>`, with the channel suffix for sub-devices (`eWeLink:1000abcdefSW1`).
    var id: String
    /// The device id, with the channel suffix for sub-devices.
    var deviceID: String
    var displayName: String
    /// A channel of a multi-channel device: 0 is the master, 1...n the channels.
    var switchNumber: Int?
    var channelCount: Int?
    /// An RF sub-device: its first channel on the bridge and its buttons.
    var rfButtonIndex: Int?
    var buttons: [(channel: String, name: String)]?
    /// An RF sub-device's name in eWeLink.
    var name: String?

    static func accessoryID(_ deviceID: String) -> String { "\(EWeLinkPlugin.platform):\(deviceID)" }

    init(deviceID: String, displayName: String) {
        id = Self.accessoryID(deviceID)
        self.deviceID = deviceID
        self.displayName = displayName
    }
}

/// Values a handler keeps across launches (a cover's position, a thermostat's target), the Homebridge
/// plugin's `accessory.context.cache*` fields: `accessory-context.json`, by accessory id then key.
extension PersistedDictionary where Value == [String: JSONValue] {
    func value(_ accessoryID: String, _ key: String) -> JSONValue? { self[accessoryID]?[key] }

    func set(_ accessoryID: String, _ key: String, _ value: JSONValue?) {
        update(accessoryID) { values in
            guard values?[key] != value else { return }
            var entry = values ?? [:]
            entry[key] = value
            values = entry
        }
    }
}

/// The device cache, the handlers by accessory id, and the temperatures heater and cooler simulations read.
@EWeLinkActor
final class DeviceRegistry {
    /// Devices from the cloud (or the cache file before login), by device id.
    private(set) var devices: [String: DeviceBox] = [:]
    /// Handlers by accessory id.
    private(set) var handlers: [String: BaseAccessory] = [:]
    /// What each handler was built from, so a re-discovery keeps a handler that would be built the same.
    var identities: [String: String] = [:]
    private var temperatures: [String: Double] = [:]

    /// Puts a device in the cache; an existing box gets the fresh data, so its handlers see it.
    @discardableResult
    func store(_ device: EWeLinkDevice) -> DeviceBox {
        if let box = devices[device.deviceid] {
            box.device = device
            return box
        }
        let box = DeviceBox(device)
        devices[device.deviceid] = box
        return box
    }

    func box(_ deviceID: String) -> DeviceBox? { devices[deviceID] }
    func device(_ deviceID: String) -> EWeLinkDevice? { devices[deviceID]?.device }

    func displayName(_ deviceID: String) -> String { devices[deviceID]?.device.name ?? deviceID }

    func handler(_ accessoryID: String) -> BaseAccessory? { handlers[accessoryID] }

    /// Installs a handler, destroying a different one it replaces.
    func setHandler(_ handler: BaseAccessory, for accessoryID: String) {
        if let previous = handlers[accessoryID], previous !== handler { previous.destroy() }
        handlers[accessoryID] = handler
    }

    func removeHandler(_ accessoryID: String) {
        identities[accessoryID] = nil
        handlers.removeValue(forKey: accessoryID)?.destroy()
    }

    func destroyAllHandlers() {
        let all = handlers.values
        handlers.removeAll()
        identities.removeAll()
        for handler in all { handler.destroy() }
    }

    /// The accessory ids of a multi-channel device's channels: 0 is the master.
    static func channelIDs(_ deviceID: String, channelCount: Int) -> [String] {
        (0...max(channelCount, 0)).map { AccessoryRecord.accessoryID("\(deviceID)SW\($0)") }
    }

    func setTemperature(_ deviceID: String, _ temperature: Double) { temperatures[deviceID] = temperature }
    func temperature(_ deviceID: String) -> Double? { temperatures[deviceID] }
}
