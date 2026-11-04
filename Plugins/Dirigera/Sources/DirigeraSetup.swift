import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the DIRIGERA hubs are the instance's account, each authorized by a Button Press on its
// action button; the token stays in the plugin's own entry, sealed in the vault (`hubs.json`), so the plugin
// says itself whether the account is Authorized. The hubs' lights, outlets, sensor groups and scenes are the devices
// (Device Kinds `light`, `outlet`, `sensor`, `blinds`, `airPurifier`, `controller`, `scene`): a device by the id its
// accessory goes by (`Dirigera:<id>`), a scene by its id on the hub, its switch on the hub's scenes accessory
// (`Dirigera:scenes:<host>`). They need nothing more, and their Accessory Settings (or, in a Homebridge block,
// `excludeDevices` and `excludeScenes`) may leave them out.
extension DirigeraPlugin {
    public static let accountAuthorization = AuthorizationMethod.buttonPress

    /// Authorized once a hub the plugin runs has a token: one pairing kept, or config.json's.
    public func accountAuthorized() async -> Bool? {
        // What another instance (Setup's) kept since this one started.
        stored = store.load() ?? stored
        return hubHosts.contains { token(for: $0) != nil }
    }

    /// Every device and scene of the hubs with a token, read once from a hub this plugin has not read yet (an instance
    /// made only for Setup). A hub that does not answer is left out, unless none does. Wake-up and playlist scenes run on
    /// the hub's schedule, with no switch: they are left out.
    public func discover() async throws -> [DiscoveredDevice] {
        stored = store.load() ?? stored
        var found: [DiscoveredDevice] = []
        var failure: (any Error)?
        for host in hubHosts {
            guard let token = token(for: host) else { continue }
            var devices: [DirigeraDevice], scenes: [DirigeraScene]
            if let hub = hubs[host], !hub.devices.isEmpty {
                (devices, scenes) = (Array(hub.devices.values), hub.scenes)
            } else {
                let client = DirigeraClient(host: host, token: token, transport: dependencies.transport(trust(for: host)))
                do {
                    devices = try await client.devices().compactMap(DirigeraDevice.init)
                    scenes = (configuration.scenes ?? true) ? try await client.scenes().compactMap(DirigeraScene.init) : []
                } catch {
                    logger.warning("Could not read the DIRIGERA hub at \(host): \(error)")
                    failure = error
                    continue
                }
            }
            for device in devices.sorted(by: { $0.name < $1.name }) where device.isStandalone {
                found.append(DiscoveredDevice(
                    deviceID: device.id, name: device.name, model: device.model, isSetUp: true, excludedBySettings: excludedBySettings(device),
                    kind: Self.kind(of: device.kind)))
            }
            for group in Self.groups(of: devices) {
                let lead = group.devices[0]
                found.append(DiscoveredDevice(
                    deviceID: group.id, name: lead.name, model: lead.model, isSetUp: true, excludedBySettings: excludedBySettings(group: group.devices, id: group.id),
                    kind: Self.kind(of: lead.kind)))
            }
            // Each scene a switch on the hub's scenes accessory, which a scenes accessory Excluded before leaves out.
            let scenesOff = context.isExcluded("scenes:\(host)")
            for scene in scenes.sorted(by: { $0.name < $1.name }) where scene.isRunnable {
                found.append(DiscoveredDevice(
                    deviceID: scene.id, name: scene.name, model: "DIRIGERA scene", address: host, isSetUp: true,
                    excludedBySettings: scenesOff || excludedBySettings(scene), kind: Self.sceneKind))
            }
        }
        if found.isEmpty, let failure { throw SetupError("The DIRIGERA hub did not answer: \(failure)") }
        return found
    }

    /// The hub's address (asked when none is found on the network), then its action button, tried every two seconds by
    /// the Setup sheet for a minute. The token and the certificate it was paired over go in the vault (`hubs.json`).
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("IKEA devices need no setup of their own")
        let typed = request.answer("host")
        var host = typed ?? request.state["host"]?.stringValue
        if host == nil {
            // A hub the block names that has no token yet, else one on the network not paired yet, else the first one found
            // (pairing it again).
            if let named = hubHosts.first(where: { self.token(for: $0) == nil }) {
                host = named
            } else {
                let hosts = await dependencies.discover()
                host = hosts.first { self.token(for: $0) == nil } ?? hosts.first
            }
        }
        guard let host else {
            return .ask(SetupPrompt(message: "No DIRIGERA hub answered on the network. Enter its address, from your router or the IKEA Home smart app.",
                                    fields: [SetupField("host", label: "Address", kind: .text)]))
        }
        // A pairing starts from no pin; the certificate the hub showed then is pinned from there on. A
        // typed address starts afresh.
        let fresh = typed != nil
        // The trust keeps the certificate it pins on the first connection: `trust.fingerprint`.
        let trust = HTTPClient.TrustOnFirstUse(pinned: fresh ? nil : request.state["fingerprint"]?.stringValue)
        let client = DirigeraClient(host: host, token: nil, transport: dependencies.transport(trust))
        // The code the hub gave for the verifier, asked once per pairing.
        let code: String, verifier: String
        if !fresh, let kept = request.state["code"]?.stringValue, let keptVerifier = request.state["verifier"]?.stringValue {
            (code, verifier) = (kept, keptVerifier)
        } else {
            verifier = DirigeraClient.makeVerifier()
            do {
                code = try await client.authorize(verifier: verifier)
            } catch {
                throw SetupError("The DIRIGERA hub at \(host) did not answer: \(error)")
            }
        }
        let token: String
        do {
            token = try await client.token(code: code, verifier: verifier, name: Self.clientName)
        } catch DirigeraClient.Failure.buttonNotPressed {
            let waiting = SetupPrompt(message: "Press the action button on the back of the DIRIGERA hub.", waitSeconds: Int(Self.pairingWindow.components.seconds), retryAfter: 2)
            return .ask(waiting, state: [
                "host": .string(host), "code": .string(code), "verifier": .string(verifier), "fingerprint": trust.fingerprint.map(JSONValue.string) ?? .null,
            ])
        } catch {
            throw SetupError("The DIRIGERA hub at \(host) did not answer: \(error)")
        }
        keep(token: token, fingerprint: trust.fingerprint, for: host)
        logger.info("Paired with the DIRIGERA hub at \(host)")
        // Nothing for the bridge to keep: the token is in the plugin's own vault entry, which `accountAuthorized` reads.
        return .done(SetupOutcome())
    }
}
