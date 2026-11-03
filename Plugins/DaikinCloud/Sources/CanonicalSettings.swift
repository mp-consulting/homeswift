import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (`authMode`, the callback server,
// polling, the WebSocket, the transport) and the twelve `show*` switches; each device's Accessory Settings sit in
// `_accessories` by its Device Id (its gateway device's id): Excluded, and its own `show*` switches, whose plugin-wide
// defaults are the options of the same names. The account's credentials are in the vault (`email`, `password`,
// `clientId`, `clientSecret`). A Homebridge block still loads; `canonicalSettings` moves its shapes.
extension DaikinCloudPlugin {
    /// A device's Device Kind from its management points: `domesticHotWaterTank` for one with a hot water tank (an
    /// Altherma), `climateControl` for one with a climate control, `gateway` otherwise.
    static func kind(ofDevice raw: JSONValue) -> String {
        let points = Set((raw["managementPoints"]?.arrayValue ?? []).compactMap { $0["managementPointType"]?.stringValue ?? $0["embeddedId"]?.stringValue })
        if points.contains("domesticHotWaterTank") { return "domesticHotWaterTank" }
        if points.contains(where: { climateControlIDs.contains($0) }) { return "climateControl" }
        return "gateway"
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if let device = await session?.devices.first(where: { $0.id == deviceID }) { return Self.kind(ofDevice: device.raw) }
        for cached in devicesCache.values {
            if let device = cached.result["devices"]?.arrayValue?.first(where: { $0["id"]?.stringValue == deviceID }) { return device["kind"]?.stringValue }
        }
        return nil
    }

    /// The account's credentials: what the vault keeps with `changes` on top.
    func accountCredentials(_ changes: [String: JSONValue]) -> JSONValue {
        var fields = context.credentials()?.objectValue ?? [:]
        for (key, value) in changes where DaikinSettings.nonEmpty(value) != nil { fields[key] = value }
        return .object(fields)
    }

    /// The block in its canonical shape: the credentials it holds (`daikinEmail`, `daikinPassword`, their aliases
    /// `email` and `password`, `clientId`, `clientSecret`) moved into the vault once the block is written, where the vault
    /// has none of its own, and out of the block; `excludedDevicesByDeviceId` as Excluded devices; `showExtraFeatures` as each extra feature's switch
    /// it stood for, where the block sets none.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        // The block may only name a credential (a `vault:` reference, a sealed copy): the running configuration has it
        // resolved.
        let held = context.credentials()?.objectValue ?? [:]
        var moved = held
        for (field, key) in DaikinSettings.credentialKeys where DaikinSettings.nonEmpty(held[field]) == nil {
            let aliases = [key] + (field == "email" || field == "password" ? [field] : [])
            if let value = aliases.lazy.compactMap({ DaikinSettings.nonEmpty(self.configuration.raw[$0]) }).first { moved[field] = .string(value) }
        }
        // Moved once the block is written (`whenSettingsWritten`), the block answered as if the vault had them.
        if moved != held {
            let context = context, credentials = JSONValue.object(moved)
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        let inVault = Set(moved.filter { DaikinSettings.nonEmpty($0.value) != nil }.keys)
        return Self.canonical(block, credentialsInVault: inVault)
    }

    /// `credentialsInVault`: the credential fields the vault holds; the block's keys for them go.
    static func canonical(_ block: JSONValue, credentialsInVault: Set<String>) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        for (field, key) in DaikinSettings.credentialKeys where credentialsInVault.contains(field) {
            fields.removeValue(forKey: key)
            if field == "email" || field == "password" { fields.removeValue(forKey: field) }
        }
        if let ids = fields["excludedDevicesByDeviceId"]?.arrayValue {
            var entries = fields["_accessories"]?.objectValue ?? [:]
            var left: [JSONValue] = []
            for value in ids {
                guard let id = value.stringValue, !id.isEmpty else { left.append(value); continue }
                var entry = entries[id]?.objectValue ?? [:]
                if entry["excluded"] == nil { entry["excluded"] = true }
                entries[id] = .object(entry)
            }
            if !entries.isEmpty { fields["_accessories"] = .object(entries) }
            if left.isEmpty { fields.removeValue(forKey: "excludedDevicesByDeviceId") } else { fields["excludedDevicesByDeviceId"] = .array(left) }
        }
        if let legacy = fields["showExtraFeatures"] {
            // On, it switched on every extra feature its own key left unset; off (or not a boolean) it was the default.
            if legacy.boolValue == true {
                for key in FeatureKey.extra where fields[key.rawValue]?.boolValue == nil { fields[key.rawValue] = true }
            }
            fields.removeValue(forKey: "showExtraFeatures")
        }
        return .object(fields)
    }
}
