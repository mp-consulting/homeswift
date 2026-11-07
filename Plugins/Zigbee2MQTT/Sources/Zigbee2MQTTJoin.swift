import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Join (GLOSSARY.md): a new Zigbee device brought into Zigbee2MQTT's network from Add accessories, so nobody opens
// Zigbee2MQTT's own frontend for it. Setup asks Zigbee2MQTT to let devices join (`bridge/request/permit_join`), waits as a
// Button Press does while the person resets the device, follows `bridge/event` (`device_joined`, then `device_interview`)
// and is done with the device's IEEE address once Zigbee2MQTT has read what it does. The network closes again then, or
// when the time is up. The device's accessory comes as every other does, with the device list Zigbee2MQTT publishes.

/// What a Join has seen so far.
struct Joining: Sendable {
    /// How long the network stays open.
    var window: JoinWindow
    /// The device that joined, by IEEE address, and its name.
    var joined: (address: String, name: String)?
    /// Its interview went through: Setup is done.
    var interviewed = false
    /// Why it stopped, for people.
    var failure: String?
}

extension Zigbee2MQTTPlugin {
    /// A step of a Join: the first opens the network; the others, sent every `JoinWindow.poll` seconds, say where it is.
    func join(_ request: SetupRequest) async throws -> SetupStep {
        guard let settings, let connection, !brokerDown else {
            throw SetupError("Zigbee2MQTT is not connected: set up its MQTT broker first, then add devices")
        }
        if request.state["joining"] == nil {
            joining?.window.cancel()
            try await permitJoin(JoinWindow.defaultSeconds, connection: connection, base: settings.mqtt.baseTopic)
            joining = Joining(window: JoinWindow { [weak self] in await self?.endJoin() })
            log.info("Zigbee2MQTT lets devices join for \(JoinWindow.defaultSeconds) seconds")
            return .ask(waitPrompt(nil), state: ["joining": true])
        }
        guard let current = joining else {
            throw SetupError("Zigbee2MQTT closed its network: start again to add a device")
        }
        if let failure = current.failure {
            await endJoin()
            throw SetupError(failure)
        }
        if current.interviewed, let joined = current.joined {
            await endJoin()
            log.info("\(joined.name) joined Zigbee2MQTT's network")
            return .done(SetupOutcome(deviceID: joined.address))
        }
        guard current.window.isOpen else {
            await endJoin()
            throw SetupError("No device joined: reset it close to the coordinator, then try again")
        }
        return .ask(waitPrompt(current.joined?.name), state: ["joining": true])
    }

    private func waitPrompt(_ joined: String?) -> SetupPrompt {
        let left = joining?.window.secondsLeft ?? 0
        guard let joined else {
            return SetupPrompt(
                message: "Reset the device, or hold its button until its light blinks: Zigbee2MQTT lets it join for two minutes.",
                warning: "A device that was in another Zigbee network leaves it as it resets.",
                waitSeconds: left, retryAfter: JoinWindow.poll)
        }
        return SetupPrompt(
            message: "{name} joined: Zigbee2MQTT is reading what it does. Keep a battery device awake by pressing its button now and then.",
            values: ["name": joined], waitSeconds: left, retryAfter: JoinWindow.poll)
    }

    /// Asks Zigbee2MQTT to let devices join for `seconds`, 0 to stop. Zigbee2MQTT 2 reads `time`; 1.x `value` and `time`.
    func permitJoin(_ seconds: Int, connection: any MQTTConnection, base: String) async throws {
        let payload = JSONValue.object(["value": .bool(seconds > 0), "time": .number(Double(seconds))]).text()
        do {
            try await connection.publish("\(base)/bridge/request/permit_join", string: payload, qos: .atLeastOnce)
        } catch {
            throw SetupError("Could not ask Zigbee2MQTT to let devices join: \(error)")
        }
    }

    /// The Join is over: its network closed, unless it closed by itself.
    func endJoin() async {
        guard let current = joining else { return }
        joining = nil
        current.window.cancel()
        guard let connection, let settings else { return }
        try? await permitJoin(0, connection: connection, base: settings.mqtt.baseTopic)
    }

    /// `bridge/event`: a device joined, announced itself, was interviewed or left.
    func receivedEvent(_ payload: Data) {
        guard let event = try? JSONValue(data: payload), let type = event["type"]?.stringValue else { return }
        let data = event["data"] ?? .null
        guard let address = data["ieee_address"]?.stringValue else { return }
        let name = data["friendly_name"]?.stringValue ?? address
        switch type {
        case "device_joined":
            log.info("\(name) joined the Zigbee network")
            guard joining != nil, joining?.joined == nil else { return }
            joining?.joined = (address, name)
        case "device_interview":
            guard joining != nil else { return }
            // A device the network already has, interviewed again as it rejoins, is not the one Setup waits for: only a
            // new one is, the first that joined.
            if joining?.joined == nil, !isKnown(address) { joining?.joined = (address, name) }
            guard joining?.joined?.address == address else { return }
            switch data["status"]?.stringValue {
            case "successful":
                if data["supported"]?.boolValue == false {
                    log.warning("\(name) joined, but Zigbee2MQTT does not support it yet: it shows no controls")
                }
                joining?.interviewed = true
            case "failed":
                joining?.failure = "Zigbee2MQTT could not read what the device does: keep it close to the coordinator, reset it and try again"
            default:
                break
            }
        default:
            break
        }
    }

    /// A device the bridge already has: an accessory of its own, or one the cache brought back.
    private func isKnown(_ address: String) -> Bool {
        devices[address] != nil || context.accessory(id: Self.accessoryID(deviceID: address)) != nil
    }

    /// `bridge/response/permit_join`: Zigbee2MQTT refused to open its network.
    func receivedPermitJoin(_ payload: Data) {
        guard let response = try? JSONValue(data: payload), response["status"]?.stringValue == "error" else { return }
        let reason = response["error"]?.stringValue ?? "no reason given"
        log.warning("Zigbee2MQTT refused to let devices join: \(reason)")
        if joining != nil { joining?.failure = "Zigbee2MQTT refused to let devices join: \(reason)" }
    }
}
