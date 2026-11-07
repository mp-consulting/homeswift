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
    /// When the network closes.
    var deadline: ContinuousClock.Instant
    /// The device that joined, by IEEE address, and its name.
    var joined: (address: String, name: String)?
    /// Its interview went through: Setup is done.
    var interviewed = false
    /// Why it stopped, for people.
    var failure: String?
    /// Closes the network once the time is up.
    var closer: Task<Void, Never>?
}

extension Zigbee2MQTTPlugin {
    /// How long Zigbee2MQTT lets devices join: its frontend's own default.
    static let joinSeconds = 120
    /// How often Setup asks how the Join goes.
    static let joinPoll = 2

    /// A step of a Join: the first opens the network; the others, sent every `joinPoll` seconds, say where it is.
    func join(_ request: SetupRequest) async throws -> SetupStep {
        guard let settings, let connection, !brokerDown else {
            throw SetupError("Zigbee2MQTT is not connected: set up its MQTT broker first, then add devices")
        }
        if request.state["joining"] == nil {
            joining?.closer?.cancel()
            let deadline = ContinuousClock.now + .seconds(Self.joinSeconds)
            try await permitJoin(Self.joinSeconds, connection: connection, base: settings.mqtt.baseTopic)
            let closer = Task { [weak self] in
                try? await Task.sleep(until: deadline + .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.endJoin()
            }
            joining = Joining(deadline: deadline, closer: closer)
            log.info("Zigbee2MQTT lets devices join for \(Self.joinSeconds) seconds")
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
        guard ContinuousClock.now < current.deadline else {
            await endJoin()
            throw SetupError("No device joined: reset it close to the coordinator, then try again")
        }
        return .ask(waitPrompt(current.joined?.name), state: ["joining": true])
    }

    private func waitPrompt(_ joined: String?) -> SetupPrompt {
        let left = max(0, Int(((joining?.deadline ?? .now) - .now).components.seconds))
        guard let joined else {
            return SetupPrompt(
                message: "Reset the device, or hold its button until its light blinks: Zigbee2MQTT lets it join for two minutes.",
                warning: "A device that was in another Zigbee network leaves it as it resets.",
                waitSeconds: left, retryAfter: Self.joinPoll)
        }
        return SetupPrompt(
            message: "{name} joined: Zigbee2MQTT is reading what it does. Keep a battery device awake by pressing its button now and then.",
            values: ["name": joined], waitSeconds: left, retryAfter: Self.joinPoll)
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
        current.closer?.cancel()
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
            // A device already interviewed rejoining, or one joining while another is read, is the one Setup waits for
            // only when it is the first that joined.
            if joining?.joined == nil { joining?.joined = (address, name) }
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

    /// `bridge/response/permit_join`: Zigbee2MQTT refused to open its network.
    func receivedPermitJoin(_ payload: Data) {
        guard let response = try? JSONValue(data: payload), response["status"]?.stringValue == "error" else { return }
        let reason = response["error"]?.stringValue ?? "no reason given"
        log.warning("Zigbee2MQTT refused to let devices join: \(reason)")
        if joining != nil { joining?.failure = "Zigbee2MQTT refused to let devices join: \(reason)" }
    }
}
