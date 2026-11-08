import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import NIOConcurrencyHelpers

@testable import HomeswiftHomeAssistant

/// A Home Assistant server in memory, behind `FakeWebSocket`s: the auth phase, the commands the plugin sends, and the
/// events it subscribes to, with the shapes of docs/clean-room/HomeAssistant.md (written for these tests).
final class FakeHomeAssistant: Sendable {
    struct Call: Sendable, Equatable {
        var domain: String
        var service: String
        var data: JSONValue
        var entityID: String?
    }

    private struct State: Sendable {
        var token = "good-token"
        var states: [String: JSONValue] = [:]
        var entities: [JSONValue] = []
        var devices: [JSONValue] = []
        var areas: [JSONValue] = []
        var config: JSONValue = ["location_name": "Home", "version": "2026.12.0", "state": "RUNNING", "unit_system": ["temperature": "°C"], "components": []]
        var registriesAllowed = true
        var calls: [Call] = []
        var sockets: [FakeWebSocket] = []
        /// Each socket's subscriptions: event type → subscribing id.
        var subscriptions: [ObjectIdentifier: [String: Int]] = [:]
        var stamp = 0
    }

    private let state = NIOLockedValueBox(State())

    var calls: [Call] { state.withLockedValue { $0.calls } }
    var connections: Int { state.withLockedValue { $0.sockets.count } }
    var socket: FakeWebSocket? { state.withLockedValue { $0.sockets.last } }

    func setToken(_ token: String) { state.withLockedValue { $0.token = token } }
    func setFahrenheit() { state.withLockedValue { $0.config = ["location_name": "Home", "state": "RUNNING", "unit_system": ["temperature": "°F"], "components": []] } }
    func denyRegistries() { state.withLockedValue { $0.registriesAllowed = false } }
    func setComponents(_ components: [String]) {
        state.withLockedValue { $0.config = ["location_name": "Home", "state": "RUNNING", "unit_system": ["temperature": "°C"], "components": .array(components.map(JSONValue.string))] }
    }

    // MARK: The server's content

    /// Adds an entity: its state, and a registry entry when `registryID` is given.
    func add(_ entityID: String, state value: String, attributes: [String: JSONValue] = [:], registryID: String? = nil, uniqueID: String? = nil,
             device: String? = nil, platform: String = "demo", category: String? = nil, hidden: String? = nil) {
        state.withLockedValue { state in
            state.stamp += 1
            state.states[entityID] = Self.stateJSON(entityID, value, attributes, stamp: state.stamp)
            if let registryID {
                state.entities.append([
                    "id": .string(registryID), "entity_id": .string(entityID), "unique_id": .string(uniqueID ?? registryID), "platform": .string(platform),
                    "device_id": device.map(JSONValue.string) ?? .null, "area_id": .null, "disabled_by": .null,
                    "hidden_by": hidden.map(JSONValue.string) ?? .null, "entity_category": category.map(JSONValue.string) ?? .null, "name": .null,
                ])
            }
        }
    }

    func addDevice(_ id: String, name: String, manufacturer: String? = "Acme", model: String? = "M1", mac: String? = nil, serial: String? = nil,
                   area: String? = nil, identifiers: [[String]] = [], via: String? = nil) {
        state.withLockedValue { state in
            state.devices.append([
                "id": .string(id), "name": .string(name), "name_by_user": .null, "manufacturer": manufacturer.map(JSONValue.string) ?? .null,
                "model": model.map(JSONValue.string) ?? .null, "serial_number": serial.map(JSONValue.string) ?? .null, "sw_version": "1.2.3",
                "area_id": area.map(JSONValue.string) ?? .null, "disabled_by": .null, "via_device_id": via.map(JSONValue.string) ?? .null,
                "connections": .array(mac.map { [[.string("mac"), .string($0)]] } ?? []),
                "identifiers": .array(identifiers.map { .array($0.map(JSONValue.string)) }),
            ])
        }
    }

    func addArea(_ id: String, name: String) {
        state.withLockedValue { $0.areas.append(["area_id": .string(id), "name": .string(name)]) }
    }

    static func stateJSON(_ entityID: String, _ value: String, _ attributes: [String: JSONValue], stamp: Int) -> JSONValue {
        let time = String(format: "2026-11-07T10:%02d:%02d.000000+00:00", (stamp / 60) % 60, stamp % 60)
        return ["entity_id": .string(entityID), "state": .string(value), "attributes": .object(attributes),
                "last_changed": .string(time), "last_updated": .string(time), "context": ["id": "01J", "parent_id": .null, "user_id": .null]]
    }

    // MARK: Events

    /// A state change, sent to every socket subscribed to `state_changed`.
    func change(_ entityID: String, state value: String, attributes: [String: JSONValue] = [:]) {
        let (event, targets) = state.withLockedValue { state -> (JSONValue, [(FakeWebSocket, Int)]) in
            state.stamp += 1
            let old = state.states[entityID] ?? .null
            let new = Self.stateJSON(entityID, value, attributes, stamp: state.stamp)
            state.states[entityID] = new
            let event: JSONValue = ["event_type": "state_changed", "data": ["entity_id": .string(entityID), "old_state": old, "new_state": new],
                                    "origin": "LOCAL", "time_fired": "2026-11-07T10:37:24.265429+00:00"]
            return (event, Self.targets(state, "state_changed"))
        }
        for (socket, id) in targets { socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "event", "event": event]).text()) }
    }

    /// Renames an entity (a new entity id, the same registry entry), as HA does: the registry event, then the old state
    /// removed and the new one added.
    func rename(_ old: String, to new: String) {
        let (targets, stateTargets, oldState, newState) = state.withLockedValue { state -> ([(FakeWebSocket, Int)], [(FakeWebSocket, Int)], JSONValue, JSONValue) in
            for index in state.entities.indices where state.entities[index]["entity_id"]?.stringValue == old {
                if case .object(var fields) = state.entities[index] {
                    fields["entity_id"] = .string(new)
                    state.entities[index] = .object(fields)
                }
            }
            let previous = state.states.removeValue(forKey: old) ?? .null
            var moved = previous
            if case .object(var fields) = moved { fields["entity_id"] = .string(new); moved = .object(fields) }
            state.states[new] = moved
            return (Self.targets(state, "entity_registry_updated"), Self.targets(state, "state_changed"), previous, moved)
        }
        for (socket, id) in targets {
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "event", "event": [
                "event_type": "entity_registry_updated", "data": ["action": "update", "entity_id": .string(new), "old_entity_id": .string(old), "changes": ["entity_id": .string(old)]],
            ]]).text())
        }
        for (socket, id) in stateTargets {
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "event", "event": [
                "event_type": "state_changed", "data": ["entity_id": .string(old), "old_state": oldState, "new_state": .null]]]).text())
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "event", "event": [
                "event_type": "state_changed", "data": ["entity_id": .string(new), "old_state": .null, "new_state": newState]]]).text())
        }
    }

    /// An `entity_registry_updated` event, after entities were added.
    func registryChanged() {
        let targets = state.withLockedValue { Self.targets($0, "entity_registry_updated") }
        for (socket, id) in targets {
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "event", "event": [
                "event_type": "entity_registry_updated", "data": ["action": "create", "entity_id": "light.echo"]]]).text())
        }
    }

    private static func targets(_ state: State, _ type: String) -> [(FakeWebSocket, Int)] {
        state.sockets.compactMap { socket in
            guard socket.isOpen, let id = state.subscriptions[ObjectIdentifier(socket)]?[type] else { return nil }
            return (socket, id)
        }
    }

    // MARK: The connection

    /// What the plugin's `Dependencies.connect` calls: a new socket, `auth_required` already sent.
    func connect(_ url: URL) -> any WebSocketConnection {
        let socket = FakeWebSocket(url: url)
        state.withLockedValue { $0.sockets.append(socket) }
        socket.onSend { [weak socket, weak self] message in
            guard let socket, let self, let text = message.text, let json = try? JSONValue(string: text) else { return }
            self.answer(json, on: socket)
        }
        socket.receive(text: #"{"type":"auth_required","ha_version":"2026.12.0"}"#)
        return socket
    }

    private func answer(_ message: JSONValue, on socket: FakeWebSocket) {
        let type = message["type"]?.stringValue ?? ""
        if type == "auth" {
            let token = state.withLockedValue { $0.token }
            if message["access_token"]?.stringValue == token {
                socket.receive(text: #"{"type":"auth_ok","ha_version":"2026.12.0"}"#)
            } else {
                socket.receive(text: #"{"type":"auth_invalid","message":"Invalid access token or password"}"#)
                socket.finish(code: 1000)
            }
            return
        }
        guard let id = message["id"]?.intValue else { return }
        func result(_ value: JSONValue) {
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "result", "success": true, "result": value]).text())
        }
        func error(_ code: String, _ text: String) {
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "result", "success": false, "error": ["code": .string(code), "message": .string(text)]]).text())
        }
        let snapshot = state.withLockedValue { $0 }
        switch type {
        case "supported_features": result(.null)
        case "get_config": result(snapshot.config)
        case "get_states": result(.array(snapshot.states.values.sorted { ($0["entity_id"]?.stringValue ?? "") < ($1["entity_id"]?.stringValue ?? "") }))
        case "config/entity_registry/list": snapshot.registriesAllowed ? result(.array(snapshot.entities)) : error("unauthorized", "Unauthorized")
        case "config/device_registry/list": snapshot.registriesAllowed ? result(.array(snapshot.devices)) : error("unauthorized", "Unauthorized")
        case "config/area_registry/list": snapshot.registriesAllowed ? result(.array(snapshot.areas)) : error("unauthorized", "Unauthorized")
        case "subscribe_events":
            let eventType = message["event_type"]?.stringValue ?? "*"
            state.withLockedValue { $0.subscriptions[ObjectIdentifier(socket), default: [:]][eventType] = id }
            result(.null)
        case "call_service":
            let call = Call(domain: message["domain"]?.stringValue ?? "", service: message["service"]?.stringValue ?? "",
                            data: message["service_data"] ?? [:], entityID: message["target"]?["entity_id"]?.stringValue)
            state.withLockedValue { $0.calls.append(call) }
            result(["context": ["id": "01K", "parent_id": .null, "user_id": "u1"]])
        case "ping":
            socket.receive(text: JSONValue.object(["id": .number(Double(id)), "type": "pong"]).text())
        default:
            error("unknown_command", "Unknown command.")
        }
    }
}
