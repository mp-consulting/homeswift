import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Join (GLOSSARY.md): a new Z-Wave device included from Add accessories, so nobody opens Z-Wave JS UI for it. Setup asks
// for the network (or another zwave-js-server, added by its address instead), starts the inclusion
// (`controller.begin_inclusion`, zwave-js's default strategy: S2 when the device supports it), and waits as a Button
// Press does while the person puts the device in inclusion mode. zwave-js asks which security classes to grant: the
// plugin grants those the device requests. For S2 Authenticated and Access Control (locks, garage doors), it then asks
// for the PIN printed on the device: Setup asks the person. It is done with the node's Device Id once zwave-js has added
// it; its accessory comes when its interview is over, as every node's does.
//
// The same Setup also takes a device out of a network (an exclusion, `controller.begin_exclusion`): the person picks
// "Remove a device from …" and puts the device in exclusion mode, which for most is the same presses as inclusion. A
// device of another network leaves it too, which readies it for this one. It ends with `SetupOutcome.removed`.

/// What an inclusion has seen so far.
struct Inclusion: Sendable {
    var homeID: String
    /// Taking a device out of the network rather than adding one.
    var excluding = false
    /// The exclusion took a device out: the node, when it was one of this network's.
    var removed = false
    var removedNodeID: Int?
    /// How long it runs before the plugin stops it.
    var window: JoinWindow
    /// A device answered: the controller stopped looking, and the time no longer runs out (zwave-js has its own for S2).
    var found = false
    /// The DSK zwave-js shows while it waits for the PIN (`12345-…`, the first five digits hidden): Setup asks for them.
    var dsk: String?
    /// The node zwave-js added.
    var nodeID: Int?
    /// Added without the security it asked for (an S2 bootstrap that failed).
    var lowSecurity = false
    /// Why it stopped, for people.
    var failure: String?
}

extension ZWaveJSPlugin {
    /// The choice that adds a server by its address instead.
    static let addressChoice = "address"
    /// The choice that removes a device from a network: `remove:<homeId>`.
    static let removePrefix = "remove:"

    /// A Join's step, or nil for Add by address: no network connected, or the person picked a server's address.
    func joinStep(_ request: SetupRequest) async throws -> SetupStep? {
        let connected = servers.filter { $0.value.client != nil }.keys.sorted()
        guard !connected.isEmpty else { return nil }
        let picked = request.state["network"]?.stringValue ?? request.answer("network")
        guard let homeID = picked else {
            return .ask(SetupPrompt(
                message: "Which Z-Wave network does the device join?",
                fields: [.choice("network", label: "Network", options: connected.map { SetupOption($0, label: Self.serverName(homeID: $0)) }
                    + [SetupOption(Self.addressChoice, label: "Another zwave-js-server, by its address")]
                    + connected.map { SetupOption(Self.removePrefix + $0, label: "Remove a device from the network", detail: Self.serverName(homeID: $0)) },
                    value: connected[0])]))
        }
        if homeID == Self.addressChoice { return nil }
        if homeID.hasPrefix(Self.removePrefix) {
            let network = String(homeID.dropFirst(Self.removePrefix.count))
            guard connected.contains(network) else { throw SetupError("Z-Wave network \(network) is not connected: check zwave-js-server, then try again") }
            return try await exclude(request, homeID: network)
        }
        guard connected.contains(homeID) else { throw SetupError("Z-Wave network \(homeID) is not connected: check zwave-js-server, then try again") }
        return try await include(request, homeID: homeID)
    }

    /// The first step starts the inclusion; the others answer the PIN or say where it is.
    func include(_ request: SetupRequest, homeID: String) async throws -> SetupStep {
        let state: JSONValue = ["network": .string(homeID), "including": true]
        guard request.state["including"] != nil else {
            try await begin(homeID, excluding: false)
            return .ask(waitPrompt(), state: state)
        }
        guard let current = inclusion, current.homeID == homeID else {
            throw SetupError("The inclusion stopped: start again to add a device")
        }
        if let failure = current.failure {
            await endInclusion()
            throw SetupError(failure)
        }
        if let nodeID = current.nodeID {
            inclusion = nil
            current.window.cancel()
            if current.lowSecurity { logger.warning("Node \(nodeID) joined without the security it asked for: include it again for S2") }
            return .done(SetupOutcome(deviceID: Self.deviceID(homeID: homeID, nodeID: nodeID)))
        }
        if let dsk = current.dsk {
            guard let pin = request.answer("pin") else { return .ask(pinPrompt(dsk), state: state) }
            guard pin.count == 5, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw SetupError("The PIN is five digits") }
            inclusion?.dsk = nil
            try await command(homeID, "controller.validate_dsk_and_enter_pin", ["pin": .string(pin)])
            return .ask(waitPrompt(), state: state)
        }
        guard current.found || current.window.isOpen else {
            await endInclusion()
            throw SetupError("No device joined: put it in inclusion mode close to the controller, then try again")
        }
        return .ask(waitPrompt(), state: state)
    }

    /// The first step starts the exclusion; the others say where it is.
    func exclude(_ request: SetupRequest, homeID: String) async throws -> SetupStep {
        let state: JSONValue = ["network": .string(Self.removePrefix + homeID), "excluding": true]
        guard request.state["excluding"] != nil else {
            try await begin(homeID, excluding: true)
            return .ask(exclusionPrompt(), state: state)
        }
        guard let current = inclusion, current.homeID == homeID, current.excluding else {
            throw SetupError("The removal stopped: start again to remove a device")
        }
        if let failure = current.failure {
            await endInclusion()
            throw SetupError(failure)
        }
        if current.removed {
            inclusion = nil
            current.window.cancel()
            return .done(.removed(deviceID: current.removedNodeID.map { Self.deviceID(homeID: homeID, nodeID: $0) }))
        }
        guard current.window.isOpen else {
            await endInclusion()
            throw SetupError("No device left the network: put it in exclusion mode close to the controller, then try again")
        }
        return .ask(exclusionPrompt(), state: state)
    }

    private func exclusionPrompt() -> SetupPrompt {
        let left = inclusion?.window.secondsLeft ?? 0
        return SetupPrompt(
            message: "Put the device in exclusion mode: for most devices, the same presses of their button as to add it. Its manual says how.",
            waitSeconds: left, retryAfter: JoinWindow.poll)
    }

    private func waitPrompt() -> SetupPrompt {
        let left = inclusion?.window.secondsLeft ?? 0
        return SetupPrompt(
            message: "Put the device in inclusion mode: most devices take three quick presses of their button. Its manual says how.",
            warning: "A device that was in another Z-Wave network must leave it first: choose Remove a device from the network, or reset it to its factory settings.",
            waitSeconds: left, retryAfter: JoinWindow.poll)
    }

    private func pinPrompt(_ dsk: String) -> SetupPrompt {
        SetupPrompt(
            message: "Enter the five-digit PIN printed on the device or its box: the first, often underlined, digits of its key {dsk}.",
            values: ["dsk": dsk], fields: [SetupField("pin", label: "PIN", kind: .code)])
    }

    /// Starts an inclusion, or an exclusion (zwave-js's default strategy: the device's provisioning entry kept, disabled).
    func begin(_ homeID: String, excluding: Bool) async throws {
        await endInclusion()
        let started: JSONValue
        do {
            started = excluding
                ? try await command(homeID, "controller.begin_exclusion")
                : try await command(homeID, "controller.begin_inclusion", ["options": ["strategy": 0]])
        } catch {
            throw SetupError(excluding ? "Z-Wave JS could not start removing a device: \(error)" : "Z-Wave JS could not start an inclusion: \(error)")
        }
        // Older schemas answer `{ success }`.
        guard started["success"]?.boolValue != false else {
            throw SetupError("Z-Wave JS could not start an inclusion: another inclusion or exclusion may be running")
        }
        inclusion = Inclusion(homeID: homeID, excluding: excluding, window: JoinWindow { [weak self] in await self?.inclusionTimedOut() })
        logger.info("\(excluding ? "Removing a device from" : "Including a device into") the Z-Wave network \(homeID) for \(JoinWindow.defaultSeconds) seconds")
    }

    /// The inclusion is over: stopped on the controller, unless zwave-js stopped it already.
    func endInclusion() async {
        guard let current = inclusion else { return }
        inclusion = nil
        current.window.cancel()
        guard current.nodeID == nil, !current.removed else { return }
        _ = try? await command(current.homeID, current.excluding ? "controller.stop_exclusion" : "controller.stop_inclusion")
    }

    /// The time is up: stopped, unless a device is being included.
    func inclusionTimedOut() async {
        guard inclusion?.found == false else { return }
        await endInclusion()
    }

    /// A command on a server's open connection.
    @discardableResult
    func command(_ homeID: String, _ name: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let client = servers[homeID]?.client else { throw ZWaveError.closed }
        return try await client.command(name, fields)
    }

    /// The controller's events while an inclusion runs.
    func followInclusion(_ name: String, _ event: JSONValue) async {
        guard let homeID = inclusion?.homeID else { return }
        if inclusion?.excluding == true {
            switch name {
            case "node removed":
                inclusion?.removed = true
                inclusion?.removedNodeID = event["node"]?["nodeId"]?.intValue ?? event["nodeId"]?.intValue
            case "exclusion stopped":
                // zwave-js stops once a device left; a device of another network leaves no node removed here, and a stop
                // made elsewhere looks the same: the outcome names no device, and the page says only that it ended.
                if inclusion?.failure == nil { inclusion?.removed = true }
            case "exclusion failed":
                inclusion?.failure = "Z-Wave JS could not remove the device: keep it close to the controller and try again"
            default:
                break
            }
            return
        }
        switch name {
        case "grant security classes":
            // The classes the device asks for, granted as asked; the person's PIN, when S2 needs one, comes next.
            let requested = event["requested"] ?? .null
            let grant: JSONValue = ["securityClasses": requested["securityClasses"] ?? [], "clientSideAuth": .bool(false)]
            do {
                try await command(homeID, "controller.grant_security_classes", ["inclusionGrant": grant])
            } catch {
                inclusion?.failure = "Z-Wave JS could not secure the device: \(error)"
            }
        case "validate dsk and enter pin":
            inclusion?.dsk = event["dsk"]?.stringValue ?? "?"
        case "node found":
            inclusion?.found = true
        case "node added":
            inclusion?.found = true
            guard let nodeID = event["node"]?["nodeId"]?.intValue else { return }
            inclusion?.nodeID = nodeID
            inclusion?.lowSecurity = event["result"]?["lowSecurity"]?.boolValue ?? false
        case "inclusion failed":
            inclusion?.failure = "Z-Wave JS could not include the device: reset it, keep it close to the controller and try again"
        case "inclusion stopped":
            // zwave-js stops looking once a device answers; stopped before that, it was stopped elsewhere (Z-Wave JS UI).
            if inclusion?.found == false, inclusion?.failure == nil {
                inclusion?.failure = "The inclusion stopped before a device joined: start again to add one"
            }
        default:
            break
        }
    }
}
