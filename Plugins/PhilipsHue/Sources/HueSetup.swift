import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the Hue Bridge is the instance's account, authorized by a Button Press on its link
// button; its lights and sensors are the devices, which need nothing more and can be Excluded.
extension PhilipsHuePlugin {
    public static let accountAuthorization = AuthorizationMethod.buttonPress

    /// The lights and sensors the bridge has (`<id>` and `device:<id>`, as their accessories' ids), read once when the
    /// plugin has not read them yet (an instance made only for Setup).
    public func discover() async throws -> [DiscoveredDevice] {
        var snapshot = self.snapshot
        // The key Setup just saved, when this plugin started without one.
        let key = stored.applicationKey ?? context.credentials(as: StoredBridge.self)?.applicationKey
        if snapshot.lights.isEmpty, snapshot.sensors.isEmpty, let key, let host = await bridgeHost() {
            snapshot = HueSnapshot(resources: try await HueClient(host: host, applicationKey: key, transport: dependencies.transport(trust)).resources())
        }
        let lights = snapshot.lights.map { DiscoveredDevice(deviceID: $0.id, name: $0.name, model: $0.product, isSetUp: true, excludedBySettings: isExcluded($0)) }
        let sensors = snapshot.sensors.map {
            DiscoveredDevice(deviceID: "device:\($0.id)", name: $0.name, model: $0.model, isSetUp: true, excludedBySettings: !(configuration.sensors ?? true) || isExcluded($0))
        }
        return lights + sensors
    }

    /// The bridge's address (asked when none is set or found), then its link button, tried every two seconds by the page
    /// for a minute. The key, the bridge ID and the address go in the vault.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { throw SetupError("Hue lights and sensors need no setup of their own") }
        let typed = request.answer("host")
        var host = typed ?? request.state["host"]?.stringValue
        if host == nil { host = await bridgeHost() }
        guard let host else {
            return .ask(SetupPrompt(message: "No Hue Bridge answered on the network. Enter its address, from the Hue app's settings.",
                                    fields: [SetupField("host", label: "Address", kind: .text)]))
        }
        // The certificate the bridge shows while pairing is the one the key is kept with: pinned from the first step on.
        let pinned = PinnedFingerprint(typed == nil ? request.state["fingerprint"]?.stringValue : nil)
        let trust = HTTPClient.TrustOnFirstUse(pinned: pinned.value) { pinned.value = $0 }
        let client = HueClient(host: host, applicationKey: nil, transport: dependencies.transport(trust))
        let waiting = SetupPrompt(message: "Press the link button on the Hue Bridge.", waitSeconds: Int(Self.pairingWindow.components.seconds), retryAfter: 2)
        let key: String, bridgeID: String?
        do {
            (key, bridgeID) = try await Self.requestKey(client)
        } catch HueClient.Failure.linkButtonNotPressed {
            return .ask(waiting, state: ["host": .string(host), "fingerprint": pinned.value.map(JSONValue.string) ?? .null])
        } catch {
            throw SetupError("The Hue Bridge at \(host) did not answer: \(error)")
        }
        let fingerprint = pinned.value
        logger.info("Paired with the Hue Bridge at \(host)")
        let credentials = StoredBridge(host: host, bridgeID: bridgeID, applicationKey: key, fingerprint: fingerprint)
        return .done(SetupOutcome(credentials: try JSONValue(data: JSONEncoder().encode(credentials)), settings: typed.map { ["host": .string($0)] } ?? [:]))
    }
}

/// The certificate a pairing saw, set from the connection's callback.
private final class PinnedFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(_ value: String?) { stored = value }
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
