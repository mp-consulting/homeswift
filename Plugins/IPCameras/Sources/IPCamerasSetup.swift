import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

// Setup (GLOSSARY.md, "Setup"): each camera is a device whose Device Id is its name (`Camera-ffmpeg:<name>`), of the
// Device Kind `camera`, listed from the block's `cameras` and asking nothing: its credentials are in its `source`. The
// account is the MQTT broker's sign-in, kept in the vault; Homebridge's `passmqtt` moves there at the next settings write.
extension IPCamerasPlugin {
    /// What the vault keeps for the account.
    struct BrokerCredentials: Codable, Sendable {
        var password: String?
    }

    /// The MQTT broker's user name and password, when it asks for them.
    public static var accountAuthorization: AuthorizationMethod { .accountLogin }
    /// Optional: the cameras stream and snapshot without it; only MQTT's motion, doorbell and switches need the broker.
    public static let accountRequirement = AccountRequirement.optional(adds: "Signs in to the MQTT broker that reports motion and doorbell presses.")

    /// The broker's password: the vault's, or the block's `passmqtt` until it moves there.
    var brokerPassword: String? {
        context.credentials(as: BrokerCredentials.self)?.password ?? configuration.mqttPassword
    }

    /// The cameras of the block, by name. FFmpeg reaches them only when HomeKit asks for a picture, so whether they answer
    /// is not known here.
    public func discover() async throws -> [DiscoveredDevice] {
        Self.accept(configuredCameras(), logger: Logger(label: "homeswift.camera-ffmpeg.discover") { _ in SwiftLogNoOpLogHandler() }).map { entry in
            DiscoveredDevice(
                deviceID: entry.name, name: context.accessorySettings(for: entry.name).name ?? entry.name, model: entry.camera.model,
                isSetUp: true, kind: Self.cameraKind)
        }
    }

    /// A camera asks nothing. The account asks the broker's user name and password, both optional (a broker without
    /// sign-in), kept as `usermqtt` and in the vault.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { return .done(SetupOutcome()) }
        if request.isFirst {
            return .ask(SetupPrompt(
                message: "The MQTT broker's user name and password, if it asks for them (motion and doorbell messages come from it).",
                fields: [
                    SetupField("usermqtt", label: "User name", optional: true, value: configuration.mqttUsername),
                    SetupField("password", label: "Password", kind: .secret, optional: true),
                ]))
        }
        let password = request.secret("password")
        return .done(SetupOutcome(
            credentials: password.map { ["password": .string($0)] }, settings: ["usermqtt": request.answer("usermqtt").map(JSONValue.string) ?? .null]))
    }

    /// Authorized unless the broker has a user name and no password is known.
    public func accountAuthorized() async -> Bool? {
        configuration.mqttHost == nil || configuration.mqttUsername == nil || brokerPassword != nil
    }

    /// A camera's Device Id is its name, the whole rest of its accessory id.
    public static func deviceID(ofAccessory suffix: String) -> String? { suffix }

    public func deviceKind(of deviceID: String) async -> String? { Self.cameraKind }

    // MARK: Settings

    /// The block without Homebridge's `passmqtt`, which moves into the vault once the block is written (the block's own,
    /// which may be newer than the vault's).
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard let password = block["passmqtt"]?.stringValue, !password.isEmpty else { return Self.canonical(block) }
        if context.credentials(as: BrokerCredentials.self)?.password != password {
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(BrokerCredentials(password: password)) }
        }
        return Self.canonical(block)
    }

    /// The block without `passmqtt`, and each named camera's motion, doorbell and switch options moved from its `cameras`
    /// entry into its Accessory Settings (by its name, its Device Id), what those already hold winning.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        fields.removeValue(forKey: "passmqtt")
        if let cameras = fields["cameras"]?.arrayValue {
            var entries = AccessoryEntries(fields)
            fields["cameras"] = .array(cameras.map { item in
                guard var camera = item.objectValue, let name = item["name"].truthyString else { return item }
                for key in Camera.accessorySettingKeys {
                    if let value = camera.removeValue(forKey: key) { entries.setIfAbsent(key, value, on: name) }
                }
                return .object(camera)
            })
            entries.write(into: &fields)
        }
        return .object(fields)
    }
}
