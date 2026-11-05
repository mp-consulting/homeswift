import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Finds boxes over Bonjour (`_huesync._tcp`, section 3.2): their name, `uniqueid` and address from the TXT record and SRV.
enum SyncBoxDiscovery {
    static let serviceType = "_huesync._tcp"

    struct Box: Sendable, Equatable {
        var name: String
        var uniqueID: String?
        /// As `syncBoxIpAddress` takes it: the address, with `:port` when it is not 443.
        var address: String
        var model: String?
    }

    static func browse(logger: Logger) -> AsyncStream<Box> {
        AsyncStream { continuation in
            let task = Task {
                for await event in BonjourBrowser.browse(type: serviceType, logger: logger) {
                    guard case .found(let service) = event, let box = Box(service) else { continue }
                    continuation.yield(box)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension SyncBoxDiscovery.Box {
    init?(_ service: BonjourService) {
        var host = service.preferredAddress
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        if host.contains(":") { host = "[\(host)]" }
        let port = service.port == 0 ? 443 : service.port
        self.init(
            name: service.txt["name"]?.nonEmpty ?? service.name, uniqueID: service.txt["uniqueid"]?.nonEmpty,
            address: port == 443 ? host : "\(host):\(port)", model: service.txt["devicetype"]?.nonEmpty)
    }
}

// Setup (GLOSSARY.md, "Setup"): the box is the instance's account, authorized by a Button Press; its accessories (Device
// Kinds `light`, `switch` and `tv`, Device Ids the Homebridge plugin's seeds) need nothing more and can be Excluded.
extension HueSyncBoxPlugin {
    public static let accountAuthorization = AuthorizationMethod.buttonPress

    /// How long the box takes registrations after its button (section 3.1 says about five seconds once green; the
    /// button is held first): the Setup sheet tries every second for this long.
    static let registrationWindow = 60

    /// The accessories the options make, once the box is set up.
    public func discover() async throws -> [DiscoveredDevice] {
        guard configuration.syncBoxIpAddress != nil, token != nil else { return [] }
        let name = state?.name ?? configuration.name ?? "Sync Box"
        return configuration.kinds.map { kind in
            DiscoveredDevice(
                deviceID: deviceID(kind), name: kind == .power ? "\(name) Power" : name, model: Self.label(kind), isSetUp: true, kind: kind.deviceKind)
        }
    }

    static func label(_ kind: SyncBoxKind) -> String {
        switch kind {
        case .lightbulb: "Sync lightbulb"
        case .switch: "Sync switch"
        case .power: "Power switch"
        case .hdmiTV: "HDMI inputs TV"
        case .modeTV: "Modes TV"
        case .intensityTV: "Intensities TV"
        case .entertainmentTV: "Entertainment areas TV"
        }
    }

    public func deviceKind(of deviceID: String) async -> String? {
        SyncBoxKind.allCases.first { $0.deviceID(seed: configuration.uuidSeed) == deviceID }?.deviceKind
    }

    /// The box (one found on the network, or a typed address), then its button: one registration a second until the
    /// box takes it. The token goes in the vault, the address and the box's `uniqueId` in the block.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("The Sync Box's lights and televisions need no setup of their own")
        var boxes = request.state["boxes"]?.objectValue ?? [:]
        var address = request.answer("address") ?? request.answer("box") ?? request.state["address"]?.stringValue
        if address == nil, request.isFirst {
            if let configured = configuration.syncBoxIpAddress {
                address = configured
            } else {
                let found = await dependencies.browse(logger).collect(for: dependencies.discoveryWindow)
                for box in found { boxes[box.address] = box.uniqueID.map(JSONValue.string) ?? .null }
                if found.count == 1 { address = found[0].address }
                if found.count > 1 {
                    let options = found.map { SetupOption($0.address, label: $0.name, detail: [$0.uniqueID, $0.address].compactMap { $0 }.joined(separator: " · ")) }
                    return .ask(
                        SetupPrompt(message: "Choose the Sync Box, or enter its address.", fields: [
                            .choice("box", label: "Sync Box", options: options, optional: true),
                            SetupField("address", label: "Address", optional: true),
                        ]),
                        state: ["boxes": .object(boxes)])
                }
            }
        }
        guard let address, SyncBoxClient.baseURL(address) != nil else {
            if let address { throw SetupError("\(address) is not an address") }
            return .ask(SetupPrompt(
                message: "No Sync Box answered on the network. Enter its address, from the Hue Sync app's settings.",
                fields: [SetupField("address", label: "Address")]))
        }
        let uniqueID = boxes[address]?.stringValue ?? request.state["uniqueId"]?.stringValue
            ?? (address == configuration.syncBoxIpAddress ? configuration.syncBoxUniqueId : nil)
        var kept: JSONValue = ["address": .string(address)]
        if let uniqueID { kept = ["address": .string(address), "uniqueId": .string(uniqueID)] }
        let waiting = SetupPrompt(
            message: "Press and hold the button on the Sync Box until its light turns green.", waitSeconds: Self.registrationWindow, retryAfter: 1)

        let transport = dependencies.transport(SyncBoxCertificate.tls(uniqueID: uniqueID))
        let registration: SyncBoxClient.Registration
        do {
            registration = try await SyncBoxClient.register(address: address, appName: "homeswift", instanceName: "Homeswift", transport: transport)
        } catch let error as SyncBoxError where error == .buttonNotPressed {
            return .ask(waiting, state: kept)
        } catch {
            throw SetupError("The Sync Box at \(address) did not answer: \(error)")
        }
        // The state once, to check the token and learn the box's name for its certificate.
        guard let client = SyncBoxClient(address: address, token: registration.accessToken, transport: transport, logger: logger) else {
            throw SetupError("\(address) is not an address")
        }
        let state: SyncBoxState
        do {
            state = try await client.state()
        } catch {
            throw SetupError("The Sync Box at \(address) took the registration but not its token: \(error)")
        }
        logger.info("Registered with the Sync Box \(state.name) at \(address)")
        var settings: [String: JSONValue] = ["syncBoxIpAddress": .string(address), "syncBoxApiAccessToken": .null]
        if !state.uniqueID.isEmpty {
            settings["syncBoxUniqueId"] = .string(state.uniqueID)
            // A block that never had a box: its seed tells this box's accessories from another block's.
            if configuration.syncBoxIpAddress == nil, configuration.block["uuidSeed"] == nil { settings["uuidSeed"] = .string(state.uniqueID) }
        }
        let credentials = Registration(accessToken: registration.accessToken, registrationId: registration.registrationId)
        return .done(try SetupOutcome(encoding: credentials, settings: settings))
    }

    // MARK: Settings

    /// The block with each television's Homebridge options (`tvAccessoryType`, `tvAccessoryLightbulb`,
    /// `tvAccessoryConfiguredName`) moved into its Accessory Settings (`accessoryType`, `lightbulb`, and the Core `name`),
    /// and the box's `uniqueId` once a state told it.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var block = Self.canonical(block)
        if let learned = learnedUniqueID, block["syncBoxUniqueId"] == nil, var fields = block.objectValue {
            fields["syncBoxUniqueId"] = .string(learned)
            block = .object(fields)
        }
        return block
    }

    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        let seed = fields["uuidSeed"]?.stringValue ?? ""
        var entries = fields["_accessories"]?.objectValue ?? [:]
        for kind in SyncBoxKind.televisions {
            guard let prefix = kind.optionPrefix else { continue }
            let moves: [(legacy: String, key: String)] = [("\(prefix)Type", "accessoryType"), ("\(prefix)Lightbulb", "lightbulb"), ("\(prefix)ConfiguredName", "name")]
            let id = kind.deviceID(seed: seed)
            var entry = entries[id]?.objectValue ?? [:]
            for move in moves {
                guard let value = fields.removeValue(forKey: move.legacy) else { continue }
                if case .string(let text) = value, text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                // What the Accessory Settings say already stays.
                if entry[move.key] == nil {
                    entry[move.key] = move.key == "accessoryType" ? .string(value.stringValue?.lowercased() ?? "tv") : value
                }
            }
            if !entry.isEmpty { entries[id] = .object(entry) }
        }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
