import Foundation
import Homeswift
import HomeswiftPlugin

/// The accessories' last states, under the Homebridge plugin's keys (`http-webhook-<id>`,
/// `http-webhook-brightness-<id>`...), in one owner-only JSON file of the plugin's folder. Values are numbers and
/// booleans, whether a webhook or HomeKit set them; the accessories read it back at launch.
///
/// The node-persist cache of the Homebridge plugin is not read: states start from the defaults, and the first webhook
/// of each accessory sets them.
final class StateStore: Sendable {
    private let values: PersistedDictionary<JSONValue>

    init(values: PersistedDictionary<JSONValue>) {
        self.values = values
    }

    func bool(_ key: String, default value: Bool = false) -> Bool {
        guard let stored = values[key] else { return value }
        return Loose.truthy(stored)
    }

    func number(_ key: String, default value: Double) -> Double {
        values[key]?.doubleValue ?? value
    }

    func set(_ key: String, _ value: Bool) { values[key] = .bool(value) }
    func set(_ key: String, _ value: Double) { values[key] = .number(value) }

    func flush() throws { try values.flush() }
}
