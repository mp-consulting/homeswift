import Foundation
import Homeswift
import HomeswiftPlugin
import Matter

// Setup (docs/plugins.md, "Setup"): Add a Matter device… asks for a pairing code, finds the node whose pairing window
// matches it, commissions it onto Homeswift's fabric and ends with its Device Id (its node id). A window found on the
// network is listed too, and its Setup asks for the code the same way. The prompts are English, with their French,
// Spanish and Portuguese in the web UI's catalogs.
extension MatterDevicesPlugin {
    /// The nodes Homeswift added, and the pairing windows open on the network now.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        for (deviceID, record) in records().sorted(by: { $0.key < $1.key }) {
            var device = DiscoveredDevice(deviceID: deviceID, name: record.name ?? "Matter device", model: Self.model(record),
                                          isSetUp: context.credentials(for: deviceID) != nil, kind: record.kind ?? "device")
            if let link = nodes[deviceID]?.link { device.isReachable = await link.status != .unreachable }
            devices.append(device)
        }
        let windows = await dependencies.discovery.commissionable(for: .seconds(3), until: nil)
        for window in windows {
            devices.append(DiscoveredDevice(deviceID: Self.windowDeviceID(window.instance), name: Self.windowName(window.info),
                                            model: Self.vendorText(window.info.vendorID), address: window.address.description,
                                            authorization: .deviceCode, isSetUp: false, kind: "device"))
        }
        return devices
    }

    static let windowPrefix = "window-"
    /// The answer that adds a device whose certification did not check out (`uncertifiedPrompt`).
    static let addAnyway = "add"
    static func windowDeviceID(_ instance: String) -> String { windowPrefix + instance }

    static func model(_ record: NodeRecord) -> String? {
        [record.vendorName, record.productName].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    /// What a pairing window calls its device: the name it gives, else its vendor's.
    static func windowName(_ info: CommissionableNodeInfo) -> String {
        info.deviceName ?? "\(vendorText(info.vendorID) ?? "Matter device") (pairing window open)"
    }

    /// Some vendors by their CSA vendor id; the others by the number.
    static func vendorText(_ id: UInt16?) -> String? {
        guard let id else { return nil }
        let known: [UInt16: String] = [0x117C: "IKEA of Sweden", 0x100B: "Signify (Philips Hue)", 0x130A: "Eve", 0x115A: "Nanoleaf",
                                       0x6006: "Google", 0x1349: "Apple", 0x1217: "Amazon", 0xFFF1: "Test vendor"]
        return known[id] ?? String(format: "Vendor 0x%04X", id)
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let window: String?
        switch request.target {
        case .account: return .done(SetupOutcome())
        case .newDevice: window = nil
        case .device(let device):
            guard device.deviceID.hasPrefix(Self.windowPrefix) else {
                // A node Homeswift has: set up already, nothing to ask. Forget, then add it again, to change its fabric.
                return .done(SetupOutcome())
            }
            window = String(device.deviceID.dropFirst(Self.windowPrefix.count))
        }
        // The code comes back in the state (kept server-side) while the person answers `uncertifiedPrompt`.
        guard let text = request.answer("code") ?? request.state["code"]?.stringValue else {
            return .ask(SetupPrompt(
                message: "In the app that already has the device (Apple Home, Google Home, its maker's app), turn on its pairing mode for another app, then enter the pairing code it shows. The device must be on your network already: Wi-Fi, Ethernet, or Thread through a border router.",
                fields: [SetupField("code", label: "Pairing code", kind: .code)]))
        }
        let code: PairingCode
        do { code = try PairingCode(text) } catch { throw SetupError("That is not a Matter pairing code: it has 11 or 21 digits, or starts with MT:") }
        // The person's answer to `uncertifiedPrompt`: the device it was about, by its window, with its code kept.
        let consented = request.state["uncertified"]?.stringValue
        if consented != nil, request.answer("trust") != Self.addAnyway { throw SetupError("The device was not added.") }

        let match: @Sendable (CommissionableNode) -> Bool = { node in
            (window == nil || node.instance == window) && (consented == nil || node.instance == consented) && node.info.matches(code)
        }
        let candidates = await dependencies.discovery.commissionable(for: dependencies.windowSearch, until: match).filter(match)
        guard !candidates.isEmpty else {
            throw SetupError("No device with a pairing window open matches this code. Turn its pairing mode on again and enter the new code.")
        }
        // A manual code carries only four bits of the discriminator: two windows may match, and only one takes the code.
        var failure: (any Error)?
        for node in candidates {
            do {
                let deviceID = try await commission(node, passcode: code.passcode, verified: consented == nil)
                return .done(try SetupOutcome(encoding: NodeCredentials(nodeID: deviceID), deviceID: deviceID))
            } catch let uncertified as UncertifiedDevice {
                // Its window stays open: the same code commissions it once the person agrees.
                return .ask(Self.uncertifiedPrompt(uncertified, node: node),
                            state: ["uncertified": .string(node.instance), "code": .string(text)])
            } catch {
                failure = error
            }
        }
        throw failure ?? SetupError("No device took this code.")
    }

    /// A device whose certification did not check out (Core §6.2.3.1), though it signs with its own certificate.
    struct UncertifiedDevice: Error {
        var failure: AttestationFailure
    }

    /// What the person is told before adding an uncertified device: why, adapted to the reason (Core §5.5, step 10).
    static func uncertifiedPrompt(_ device: UncertifiedDevice, node: CommissionableNode) -> SetupPrompt {
        let message = switch device.failure {
        case .untrustedRoot:
            "{device} is not a certified Matter device: its certificates do not come from a manufacturer in the Matter registry. It may be a development or homemade device."
        case .unknownDeclarationSigner:
            "{device} is not a certified Matter device: its certification was not signed by the Connectivity Standards Alliance. It may be a development or homemade device."
        default:
            "{device} is not a certified Matter device: its certification does not cover this product."
        }
        return SetupPrompt(
            message: message, values: ["device": windowName(node.info)],
            fields: [.choice("trust", label: "Add it anyway?", options: [
                SetupOption(addAnyway, label: "Add it anyway"), SetupOption("cancel", label: "Do not add it"),
            ])],
            warning: "Add it only if you know where it comes from: Homeswift cannot tell whether it is genuine.")
    }

    /// Commissions a node onto Homeswift's fabric (made on the first one, kept in the vault) and records it; answers its
    /// Device Id. `verified`: its attestation is checked against the Matter registry (Core §6.2.3.1), and an uncertified
    /// device throws `UncertifiedDevice`; else only its signatures, once the person agreed to add it.
    func commission(_ node: CommissionableNode, passcode: UInt32, verified: Bool = true) async throws -> String {
        let layer = MessageLayer(transport: await dependencies.transport(), reliability: dependencies.reliability)
        let commissioner: Commissioner
        let policy: Commissioner.AttestationPolicy = verified ? .verify : .signaturesOnly
        if let snapshot = fabricFile.load() {
            commissioner = try Commissioner(layer: layer, snapshot: snapshot, trustStore: dependencies.trustStore, attestationPolicy: policy)
        } else {
            // A fabric of Homeswift's own (Core §2.5.1): a random fabric id, the controller's node id in the operational range.
            commissioner = try Commissioner(layer: layer, fabricID: UInt64.random(in: 1...0xFFFF_FFFF_FFFF_FFF0), nodeID: Self.randomNodeID(),
                                            trustStore: dependencies.trustStore, attestationPolicy: policy)
            try fabricFile.save(await commissioner.snapshot)
            logger.info("Made Homeswift's Matter fabric")
        }
        try await commissioner.start()
        defer { Task { await layer.stop() } }

        let peer = try dependencies.peer(node.address)
        let nodeID = Self.randomNodeID()
        let commissioned: Commissioner.Commissioned
        do {
            commissioned = try await withTimeout(.seconds(120)) {
                // The fabric's label is how the person tells Homeswift apart in the other apps' lists of controllers.
                try await commissioner.commissionNode(peer, passcode: passcode, nodeID: nodeID, peerParameters: node.address.parameters,
                                                      fabricLabel: "Homeswift")
            }
        } catch CommissioningError.attestationFailed(let failure) where failure.isCertificationFailure {
            logger.notice("Matter device not certified: \(failure)", metadata: ["address": "\(node.address.description)"])
            throw UncertifiedDevice(failure: failure)
        } catch let error as CommissioningError {
            logger.warning("Matter commissioning failed: \(error)", metadata: ["address": "\(node.address.description)"])
            throw SetupError(Self.explain(error))
        } catch {
            let missingRoute = dependencies.missingRoute(node.address.host)
            let reason = missingRoute.map { "this host has no route to \($0)" } ?? MatterNodeLink.describe(error)
            logger.warning("Matter commissioning failed: \(reason)", metadata: ["address": "\(node.address.description)"])
            throw SetupError(Self.unanswered(node.address, missingRoute: missingRoute))
        }
        // The serial number of the next certificate moved: the fabric is saved again before anything can fail.
        try fabricFile.save(await commissioner.snapshot)
        let deviceID = Self.deviceID(nodeID: nodeID)
        let record = NodeRecord(nodeID: nodeID, name: node.info.deviceName, vendorID: commissioned.vendorID ?? node.info.vendorID,
                                productID: commissioned.productID ?? node.info.productID, address: node.address, added: Date())
        try recordFile(deviceID).save(record)
        logger.info("Matter device added", metadata: ["device": "\(deviceID)", "address": "\(node.address.description)"])
        return deviceID
    }

    /// A node id in the operational range (Core §2.5.5): 0x0000_0000_0000_0001 to 0xFFFF_FFEF_FFFF_FFFF.
    static func randomNodeID() -> NodeID { UInt64.random(in: 1...0xFFFF_FFEF_FFFF_FFFF) }

    /// Why a device did not answer: the host has no route to its Thread network (`HostRoutes`), else the device itself.
    static func unanswered(_ address: NodeAddress, missingRoute: String?) -> String {
        guard let missingRoute else {
            return "The device did not answer at \(address.description). Check that it is on and that its pairing window is still open, then try again with a new code."
        }
        return "This server has no route to the device's Thread network (\(missingRoute)), so it cannot reach it at \(address.description). "
            + "Its system does not learn the routes Thread border routers announce: add one through a border router, as the Matter Devices "
            + "README explains (Network), then try again with a new code."
    }

    static func explain(_ error: CommissioningError) -> String {
        switch error {
        case .attestationFailed: "The device failed its attestation: it may not be a genuine Matter device, so Homeswift did not add it."
        case .commandFailed(let command, let status): "The device refused \(command) (status \(status)). Open its pairing window again and retry."
        case .unexpectedResponse: "The device answered something unexpected. Open its pairing window again and retry."
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
