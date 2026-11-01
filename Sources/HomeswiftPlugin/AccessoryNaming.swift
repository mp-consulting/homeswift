import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// The names a person gives a plugin instance's accessories (`name` in the block's `_accessories`, by Device Id), put on
/// the accessories the plugin adds: the Name of Accessory Information (what the web UI, the MCP server and Matter show),
/// and the Name and Configured Name of the services named after the accessory.
///
/// The Home app keeps its own name for a paired accessory and does not follow its Name. It follows Configured Name, and
/// writes it when the accessory is renamed there, so the primary service gets one (homebridge-plugin-utils's
/// `setServiceName`: Configured Name and Name together); a write of it from a controller is handed to `onRenamed`, which
/// the MCP catalog stores as the name. Values change in place: the aids and iids stay, and a Configured Name added to a
/// running accessory gets the iid its key gives (`aid/serviceUUID/subtype/charUUID`).
///
/// A Device Id is the accessory's id after `<platform>:` (`ElgatoKeyLights:3C:6A:9D:12:34:56` is `3C:6A:9D:12:34:56`),
/// its whole id when it has no such prefix.
public final class AccessoryNaming: Sendable {
    /// What the runtime changed on one accessory, to put back when its name goes.
    private struct Applied {
        var accessory: ObjectIdentifier
        /// The values the plugin gave, by characteristic.
        var originals: [ObjectIdentifier: (characteristic: Characteristic, value: HAPValue)] = [:]
    }

    private struct State {
        var names: [String: String] = [:]
        var applied: [String: Applied] = [:]
        /// The Configured Name watched for the Home app's renames, by accessory id.
        var watched: [String: ObjectIdentifier] = [:]
        var onRenamed: (@Sendable (_ accessoryID: String, _ name: String) -> Void)?
    }

    /// HAP strings are 64 bytes at most; a name is cut to 64 characters, on a character, like the Home app's.
    public static let maxLength = 64

    let platform: String
    private let state = NIOLockedValueBox(State())

    init(platform: String) {
        self.platform = platform
    }

    /// A name as it is kept: spaces trimmed and runs of them made one, control characters left out, 64 characters at
    /// most. nil for one with nothing left.
    public static func cleaned(_ name: String) -> String? {
        let words = name.unicodeScalars.filter { $0.properties.generalCategory != .control }
            .split { CharacterSet.whitespacesAndNewlines.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maxLength))
    }

    /// The Device Id of one of the platform's accessories.
    public static func deviceID(of accessoryID: String, platform: String) -> String {
        let prefix = "\(platform):"
        return accessoryID.hasPrefix(prefix) ? String(accessoryID.dropFirst(prefix.count)) : accessoryID
    }

    /// The name given to the accessory `id`, if one was.
    func name(for accessoryID: String) -> String? {
        let deviceID = Self.deviceID(of: accessoryID, platform: platform)
        return state.withLockedValue { $0.names[deviceID] }
    }

    /// The name the plugin gave the accessory, when it was renamed.
    func originalName(of accessory: Accessory) -> String? {
        guard let name = accessory.information[.name] else { return nil }
        return state.withLockedValue { state in
            guard let applied = state.applied[accessory.id], applied.accessory == ObjectIdentifier(accessory) else { return nil }
            return applied.originals[ObjectIdentifier(name)]?.value.stringValue
        }
    }

    /// Replaces the names, by Device Id; `apply(to:)` then puts them on the accessories. Answers whether they changed.
    @discardableResult
    func setNames(_ names: [String: String]) -> Bool {
        state.withLockedValue { state in
            defer { state.names = names }
            return state.names != names
        }
    }

    /// Called with a name a controller wrote to an accessory's Configured Name (the Home app's rename).
    func onRenamed(_ handler: (@Sendable (_ accessoryID: String, _ name: String) -> Void)?) {
        state.withLockedValue { $0.onRenamed = handler }
    }

    /// Puts the accessory's name on it, or the plugin's names back when it has none any more, and watches its Configured
    /// Name. Answers whether it gave the primary service a Configured Name, a change to the accessory's structure: one on
    /// a server has to be added to it again.
    @discardableResult
    func apply(to accessory: Accessory) -> Bool {
        guard accessory.mirroredFrom == nil else { return false }
        let wanted = name(for: accessory.id)
        let key = ObjectIdentifier(accessory)
        var applied = state.withLockedValue { state -> Applied? in
            // A fresh accessory from the plugin carries the plugin's names: what was recorded of the old one is gone.
            guard let applied = state.applied[accessory.id], applied.accessory == key else { return nil }
            return applied
        }
        var addedConfiguredName = false
        if let wanted {
            var record = applied ?? Applied(accessory: key)
            let original = { (characteristic: Characteristic) -> HAPValue in
                record.originals[ObjectIdentifier(characteristic)]?.value ?? characteristic.value
            }
            let set = { (characteristic: Characteristic, value: String) in
                let id = ObjectIdentifier(characteristic)
                if record.originals[id] == nil { record.originals[id] = (characteristic, characteristic.value) }
                if characteristic.value != .string(value) { characteristic.value = .string(value) }
            }
            let information = accessory.information.characteristic(adding: .name)
            let pluginName = original(information).stringValue ?? accessory.id
            set(information, wanted)
            // Services named after the accessory follow it: "Dyson" and "Dyson Temperature" become "Desk" and "Desk
            // Temperature"; those with names of their own ("Filter") keep them.
            for service in Self.namedServices(of: accessory) {
                for characteristic in [service[.name], service[.configuredName]].compactMap({ $0 }) {
                    guard let text = original(characteristic).stringValue else { continue }
                    if text == pluginName {
                        set(characteristic, wanted)
                    } else if text.hasPrefix(pluginName + " ") {
                        set(characteristic, String((wanted + text.dropFirst(pluginName.count)).prefix(Self.maxLength)))
                    }
                }
            }
            if let primary = Self.primaryService(of: accessory) {
                if let name = primary[.name] { set(name, wanted) }
                if primary[.configuredName] == nil {
                    // Its value until now: the service's own name, else the accessory's.
                    let added = primary.characteristic(adding: .configuredName)
                    added.value = .string(primary[.name].flatMap { original($0).stringValue } ?? pluginName)
                    addedConfiguredName = true
                }
                set(primary.characteristic(.configuredName), wanted)
            }
            applied = record
        } else if let record = applied {
            for (characteristic, value) in record.originals.values where characteristic.value != value {
                characteristic.value = value
            }
            applied = nil
        }
        let watch = Self.primaryService(of: accessory)?[.configuredName]
        let watchNow = state.withLockedValue { state -> Bool in
            state.applied[accessory.id] = applied
            guard let watch, state.watched[accessory.id] != ObjectIdentifier(watch) else { return false }
            state.watched[accessory.id] = ObjectIdentifier(watch)
            return true
        }
        if let watch, watchNow {
            let id = accessory.id
            watch.observe { [weak self] change in
                guard change.reason == .write, let self, let text = change.newValue.stringValue, let name = Self.cleaned(text) else { return }
                // A write of the name it already has is no rename.
                let current = self.name(for: id)
                guard name != current, current != nil || name != change.oldValue.stringValue else { return }
                self.state.withLockedValue { $0.onRenamed }?(id, name)
            }
        }
        return addedConfiguredName
    }

    /// Forgets an accessory that left the instance.
    func forget(_ accessoryID: String) {
        state.withLockedValue { state in
            state.applied[accessoryID] = nil
            state.watched[accessoryID] = nil
        }
    }

    /// The service that stands for the accessory: the primary one, else the first that is not Accessory Information,
    /// Protocol Information or hidden.
    static func primaryService(of accessory: Accessory) -> Service? {
        let named = namedServices(of: accessory)
        return named.first(where: \.isPrimary) ?? named.first { !$0.isHidden }
    }

    /// The services a name can be on: all but Accessory Information and Protocol Information.
    private static func namedServices(of accessory: Accessory) -> [Service] {
        accessory.services.filter {
            $0.type.uuid != ServiceType.accessoryInformation.uuid && $0.type.uuid != ServiceType.protocolInformation.uuid
        }
    }
}
