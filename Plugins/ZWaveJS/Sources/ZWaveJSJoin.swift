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

/// What an inclusion has seen so far.
struct Inclusion: Sendable {
    var homeID: String
    /// When the plugin stops it.
    var deadline: ContinuousClock.Instant
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
    /// Stops the inclusion once the time is up.
    var closer: Task<Void, Never>?
}

extension ZWaveJSPlugin {
    /// How long the controller includes: as long as Zigbee2MQTT lets devices join.
    static let inclusionSeconds = 120
    static let inclusionPoll = 2
    /// The choice that adds a server by its address instead.
    static let addressChoice = "address"

    /// A Join's step, or nil for Add by address: no network connected, or the person picked a server's address.
    func joinStep(_ request: SetupRequest) async throws -> SetupStep? {
        let connected = servers.filter { $0.value.client != nil }.keys.sorted()
        guard !connected.isEmpty else { return nil }
        let picked = request.state["network"]?.stringValue ?? request.answer("network")
        guard let homeID = picked else {
            return .ask(SetupPrompt(
                message: "Which Z-Wave network does the device join?",
                fields: [.choice("network", label: "Network", options: connected.map { SetupOption($0, label: Self.serverName(homeID: $0)) }
                    + [SetupOption(Self.addressChoice, label: "Another zwave-js-server, by its address")], value: connected[0])]))
        }
        if homeID == Self.addressChoice { return nil }
        guard connected.contains(homeID) else { throw SetupError("Z-Wave network \(homeID) is not connected: check zwave-js-server, then try again") }
        return try await include(request, homeID: homeID)
    }

    /// The first step starts the inclusion; the others answer the PIN or say where it is.
    func include(_ request: SetupRequest, homeID: String) async throws -> SetupStep {
        let state: JSONValue = ["network": .string(homeID), "including": true]
        guard request.state["including"] != nil else {
            try await beginInclusion(homeID)
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
            current.closer?.cancel()
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
        guard current.found || ContinuousClock.now < current.deadline else {
            await endInclusion()
            throw SetupError("No device joined: put it in inclusion mode close to the controller, then try again")
        }
        return .ask(waitPrompt(), state: state)
    }

    private func waitPrompt() -> SetupPrompt {
        let left = max(0, Int(((inclusion?.deadline ?? .now) - .now).components.seconds))
        return SetupPrompt(
            message: "Put the device in inclusion mode: most devices take three quick presses of their button. Its manual says how.",
            warning: "A device that was in another Z-Wave network must leave it first: exclude it there, or reset it to its factory settings.",
            waitSeconds: left, retryAfter: Self.inclusionPoll)
    }

    private func pinPrompt(_ dsk: String) -> SetupPrompt {
        SetupPrompt(
            message: "Enter the five-digit PIN printed on the device or its box: the first, often underlined, digits of its key {dsk}.",
            values: ["dsk": dsk], fields: [SetupField("pin", label: "PIN", kind: .code)])
    }

    func beginInclusion(_ homeID: String) async throws {
        await endInclusion()
        let started: JSONValue
        do {
            started = try await command(homeID, "controller.begin_inclusion", ["options": ["strategy": 0]])
        } catch {
            throw SetupError("Z-Wave JS could not start an inclusion: \(error)")
        }
        // Older schemas answer `{ success }`.
        guard started["success"]?.boolValue != false else {
            throw SetupError("Z-Wave JS could not start an inclusion: another inclusion or exclusion may be running")
        }
        let deadline = ContinuousClock.now + .seconds(Self.inclusionSeconds)
        let closer = Task { [weak self] in
            try? await Task.sleep(until: deadline + .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.inclusionTimedOut()
        }
        inclusion = Inclusion(homeID: homeID, deadline: deadline, closer: closer)
        logger.info("Including a device into the Z-Wave network \(homeID) for \(Self.inclusionSeconds) seconds")
    }

    /// The inclusion is over: stopped on the controller, unless zwave-js stopped it already.
    func endInclusion() async {
        guard let current = inclusion else { return }
        inclusion = nil
        current.closer?.cancel()
        guard current.nodeID == nil else { return }
        _ = try? await command(current.homeID, "controller.stop_inclusion")
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
