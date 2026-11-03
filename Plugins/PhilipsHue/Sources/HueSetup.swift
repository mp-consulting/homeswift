import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Hue Bridge is the instance's account, authorized by a Button Press on its link
// button; its lights, sensors, switches and scenes are the devices (Device Kinds `light`, `sensor`, `switch`, `scene`),
// which need nothing more and can be Excluded. A scene's Device Id is its id on the bridge: Excluded, it has no switch
// on its room's accessory (`PhilipsHue:scenes:<room>`, whose id stays) and is left off the Scenes page.
extension PhilipsHuePlugin {
    public static let accountAuthorization = AuthorizationMethod.buttonPress

    /// The lights, sensors and scenes the bridge has (`<id>` and `device:<id>`, as their accessories' ids, and a scene's
    /// id), read once when the plugin has not read them yet (an instance made only for Setup).
    public func discover() async throws -> [DiscoveredDevice] {
        var snapshot = self.snapshot
        // The key Setup just saved, when this plugin started without one.
        let key = stored.applicationKey ?? context.credentials(as: StoredBridge.self)?.applicationKey
        if snapshot.lights.isEmpty, snapshot.sensors.isEmpty, let key, let host = await bridgeHost() {
            snapshot = HueSnapshot(resources: try await HueClient(host: host, applicationKey: key, transport: dependencies.transport(trust)).resources())
        }
        let lights = snapshot.lights.map { DiscoveredDevice(deviceID: $0.id, name: $0.name, model: $0.product, isSetUp: true, excludedBySettings: isListed($0), kind: "light") }
        let sensors = snapshot.sensors.map {
            DiscoveredDevice(
                deviceID: Self.sensorDeviceID($0.id), name: $0.name, model: $0.model, isSetUp: true, excludedBySettings: !(configuration.sensors ?? true) || isListed($0),
                kind: Self.kind(of: $0))
        }
        let rooms = Dictionary(snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let scenes = snapshot.scenes.map { scene in
            let room = rooms[scene.groupID] ?? ""
            return DiscoveredDevice(
                deviceID: scene.id, name: room.isEmpty ? scene.name : "\(room) · \(scene.name)", model: scene.smart ? "Smart scene" : "Scene", isSetUp: true,
                excludedBySettings: configuration.scenes == false || isListed(scene, room: room), kind: "scene")
        }
        return lights + sensors + scenes
    }

    /// The bridge's address (asked when none is set or found), then its link button, tried every two seconds by the Setup
    /// sheet for a minute. The key, the bridge ID and the address go in the vault.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Hue lights and sensors need no setup of their own")
        let typed = request.answer("host")
        var host = typed ?? request.state["host"]?.stringValue
        if host == nil { host = await bridgeHost() }
        guard let host else {
            return .ask(SetupPrompt(message: "No Hue Bridge answered on the network. Enter its address, from the Hue app's settings.",
                                    fields: [SetupField("host", label: "Address", kind: .text)]))
        }
        // The certificate the bridge shows while pairing is the one the key is kept with: pinned from the first step on.
        // Pairing again with the same bridge keeps the certificate it was paired with; a typed address starts afresh.
        let saved = context.credentials(as: StoredBridge.self)
        let known = saved?.host == host ? saved?.fingerprint : nil
        // The trust keeps the certificate it pins on the first connection: `trust.fingerprint`.
        let trust = HTTPClient.TrustOnFirstUse(pinned: typed == nil ? request.state["fingerprint"]?.stringValue ?? known : nil)
        let client = HueClient(host: host, applicationKey: nil, transport: dependencies.transport(trust))
        let waiting = SetupPrompt(message: "Press the link button on the Hue Bridge.", waitSeconds: Int(Self.pairingWindow.components.seconds), retryAfter: 2)
        let key: String, bridgeID: String?
        do {
            (key, bridgeID) = try await Self.requestKey(client)
        } catch HueClient.Failure.linkButtonNotPressed {
            return .ask(waiting, state: ["host": .string(host), "fingerprint": trust.fingerprint.map(JSONValue.string) ?? .null])
        } catch {
            throw SetupError("The Hue Bridge at \(host) did not answer: \(error)")
        }
        let fingerprint = trust.fingerprint
        logger.info("Paired with the Hue Bridge at \(host)")
        let credentials = StoredBridge(host: host, bridgeID: bridgeID, applicationKey: key, fingerprint: fingerprint)
        return .done(SetupOutcome(credentials: try JSONValue(encoding: credentials), settings: typed.map { ["host": .string($0)] } ?? [:]))
    }
}
