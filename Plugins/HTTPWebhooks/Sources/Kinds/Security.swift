import Foundation
import Homeswift
import HomeswiftPlugin

/// A pair of a current and a target state set by webhooks (a security system, a garage door, a lock): each parameter
/// given and a number sets its characteristic and its key.
struct StatePair: Sendable {
    let parameter: String
    let key: String
    let characteristic: Characteristic
    let fallback: Double
    /// The field of the readback.
    let field: String

    func stored(_ store: StateStore) -> Double { store.number(key, default: fallback) }

    /// Applies the parameter when it is given; logs the change.
    func apply(_ query: WebhookQuery, environment: KindEnvironment, name: String) {
        guard let text = query.nonEmpty(parameter) else { return }
        guard let number = WebhookNumber.parse(text), characteristic.type.validValues?.contains(Int(saturating: number) ?? -1) ?? true else {
            environment.logger.warning("\(name): ignoring \(parameter) \"\(text)\", which is not one of its values")
            return
        }
        environment.store.set(key, number)
        if characteristic.show(number) { environment.logger.info("\(name): changing HomeKit \(characteristic.type.name) to \(text)") }
    }
}

extension [StatePair] {
    /// Applies each pair's parameter, then answers every pair's value after the call.
    func reply(to query: WebhookQuery, environment: KindEnvironment, name: String, adding extra: [(String, JSONValue)] = []) -> WebhookReply {
        for pair in self { pair.apply(query, environment: environment, name: name) }
        return WebhookReply(fields: [("success", true)] + map { ($0.field, .number($0.stored(environment.store))) } + extra)
    }
}

/// `security[]`: a Security System. `currentstate` (0 stay, 1 away, 2 night, 3 disarmed, 4 triggered) and
/// `targetstate` (0–3) set it; HomeKit's target calls `set_state_*` with `%d` in its URL, and the current state follows
/// once the call worked.
final class SecurityAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let current: StatePair
    private let target: StatePair
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let service = Service(.securitySystem, name: name, isPrimary: true)
        current = StatePair(
            parameter: "currentstate", key: "http-webhook-current-security-state-\(id)", characteristic: service.characteristic(.securitySystemCurrentState),
            fallback: 3, field: "currentState")
        target = StatePair(
            parameter: "targetstate", key: "http-webhook-target-security-state-\(id)", characteristic: service.characteristic(.securitySystemTargetState),
            fallback: 3, field: "targetState")
        accessory = HTTPWebhooksPlugin.accessory("Security", id: id, name: name, category: .securitySystem, services: [service])
        for pair in [current, target] { pair.characteristic.show(pair.stored(environment.store)) }

        let call = entry.call("set_state")
        let (current, target) = (current, target)
        target.characteristic.onWrite { [environment, name] value in
            let state = Double(value.intValue ?? 3)
            environment.logger.info("\(name): setting security system state to \(Format.number(state)) for \(id)")
            try await environment.send(call?.substituting([("%d", Format.number(state))], in: .url), name: name)
            environment.store.set(target.key, state)
            environment.store.set(current.key, state)
            current.characteristic.show(state)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        [current, target].reply(to: query, environment: environment, name: name)
    }
}

/// `garagedooropeners[]`: a Garage Door Opener. `currentdoorstate` (0 open, 1 closed, 2 opening, 3 closing, 4
/// stopped), `targetdoorstate` (0 open, 1 closed) and `obstructiondetected` set it; HomeKit's target calls `open_*` or
/// `close_*`, and the door shows open or closed once the call worked.
final class GarageDoorAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let current: StatePair
    private let target: StatePair
    private let obstruction: Characteristic
    private let environment: KindEnvironment
    private var obstructionKey: String { "http-webhook-obstruction-detected-\(id)" }

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let service = Service(.garageDoorOpener, name: name, isPrimary: true)
        current = StatePair(
            parameter: "currentdoorstate", key: "http-webhook-current-door-state-\(id)", characteristic: service.characteristic(.currentDoorState),
            fallback: 1, field: "currentState")
        target = StatePair(
            parameter: "targetdoorstate", key: "http-webhook-target-door-state-\(id)", characteristic: service.characteristic(.targetDoorState),
            fallback: 1, field: "targetState")
        obstruction = service.characteristic(.obstructionDetected)
        accessory = HTTPWebhooksPlugin.accessory("GarageDoorOpener", id: id, name: name, category: .garageDoorOpener, services: [service])
        for pair in [current, target] { pair.characteristic.show(pair.stored(environment.store)) }
        obstruction.show(environment.store.bool(obstructionKey))

        let calls = (open: entry.call("open"), close: entry.call("close"))
        let (current, target) = (current, target)
        target.characteristic.onWrite { [environment, name] value in
            let opening = value.intValue == 0
            let state: Double = opening ? 0 : 1
            environment.logger.info("\(name): \(opening ? "opening" : "closing") garage door \(id)")
            try await environment.send(opening ? calls.open : calls.close, name: name)
            environment.store.set(target.key, state)
            environment.store.set(current.key, state)
            current.characteristic.show(state)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        if let text = query.nonEmpty("obstructiondetected") {
            let detected = text == "1" || text == "true"
            environment.store.set(obstructionKey, detected)
            if obstruction.show(detected) { environment.logger.info("\(name): changing HomeKit Obstruction Detected to \(detected)") }
        }
        return [current, target].reply(to: query, environment: environment, name: name, adding: [("obstruction", .bool(environment.store.bool(obstructionKey)))])
    }
}

/// `lockmechanisms[]`: a Lock Mechanism. `lockcurrentstate` (0 unsecured, 1 secured, 2 jammed, 3 unknown) and
/// `locktargetstate` (0 unsecured, 1 secured) set it; HomeKit's target calls `close_*` to lock and `open_*` to unlock.
/// A call that fails leaves the lock in the unknown state (3).
final class LockAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let current: StatePair
    private let target: StatePair
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let service = Service(.lockMechanism, name: name, isPrimary: true)
        current = StatePair(
            parameter: "lockcurrentstate", key: "http-webhook-lock-current-state-\(id)", characteristic: service.characteristic(.lockCurrentState),
            fallback: 1, field: "currentState")
        target = StatePair(
            parameter: "locktargetstate", key: "http-webhook-lock-target-state-\(id)", characteristic: service.characteristic(.lockTargetState),
            fallback: 1, field: "targetState")
        accessory = HTTPWebhooksPlugin.accessory("LockMechanism", id: id, name: name, category: .doorLock, services: [service])
        for pair in [current, target] { pair.characteristic.show(pair.stored(environment.store)) }

        let calls = (unlock: entry.call("open"), lock: entry.call("close"))
        let (current, target) = (current, target)
        target.characteristic.onWrite { [environment, name] value in
            let locking = value.intValue == 1
            let state: Double = locking ? 1 : 0
            environment.logger.info("\(name): \(locking ? "locking" : "unlocking") \(id)")
            environment.store.set(target.key, state)
            do {
                try await environment.send(locking ? calls.lock : calls.unlock, name: name)
            } catch {
                // The lock may be anywhere now: HomeKit shows the target asked for and an unknown current state.
                environment.store.set(current.key, 3)
                current.characteristic.show(3)
                target.characteristic.show(state)
                throw error
            }
            environment.store.set(current.key, state)
            current.characteristic.show(state)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        [current, target].reply(to: query, environment: environment, name: name)
    }
}
