import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the Homebridge plugin's keys as they are. Each
// accessory's Plugin Accessory Setting, `inUseThreshold` for a metering outlet, sits in `_accessories` by its Device Id
// (`deviceId`, or an outlet's full child id), the platform's key of the same name its plugin-wide default. The
// Homebridge block has no per-device entries to move (`devices` lists hosts for discovery, the MAC lists are patterns,
// not Device Ids) and no secrets, so its canonical shape is the block itself.
extension TPLinkSmarthomePlugin {
    /// An accessory's own Plugin Accessory Settings (the schema's `accessorySchema`); nil takes the platform's.
    struct UnitSettings: Decodable, Sendable, Equatable {
        var inUseThreshold: Double?
    }

    /// Outlet In Use's threshold for this accessory: its own, else the platform's, else 0.
    func inUseThreshold(for deviceID: String) -> Double {
        context.accessorySettings(for: deviceID).decode(UnitSettings.self)?.inUseThreshold ?? configuration.inUseThreshold ?? 0
    }

    /// The block unchanged: it is already canonical (see above).
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue { block }
}
