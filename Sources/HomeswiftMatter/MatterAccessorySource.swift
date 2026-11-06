import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// Where the Matter bridge finds the accessories it bridges and hears of their changes: the plugins (`PluginHost`), or
/// one HAP server (`ServerAccessories`, `homeswift-demo --matter`).
public protocol MatterAccessorySource: AnyObject, Sendable {
    /// Every accessory, with the names the configuration's `include` and `exclude` match it by.
    var matterAccessories: [(accessory: Accessory, names: [String])] { get }
    /// Changes of the accessories `matterAccessories` lists: one of a Function separated in HomeKit is said as its
    /// device's, which Matter has whole.
    func observeDeviceChanges(_ observer: @escaping HAPServer.ChangeObserver) -> Observation
    func observeStructure(_ observer: @escaping @Sendable () -> Void) -> Observation
}

extension PluginHost: MatterAccessorySource {
    /// The accessories of every bridge, matched by their plugin's platform and name, then their id and name. An accessory
    /// whose Functions are separated in HomeKit stays whole in Matter: the plugin's own accessory, its parts left out.
    public var matterAccessories: [(accessory: Accessory, names: [String])] {
        var owners: [ObjectIdentifier: [String: PlatformInstance]] = [:]
        for platform in platforms {
            for id in platform.accessoryIDs { owners[ObjectIdentifier(platform.bridge), default: [:]][id] = platform }
        }
        return bridges.flatMap { bridge in
            bridge.server.accessories.compactMap { published in
                if let original = published.separatedFrom, original.id != published.id { return nil }
                let accessory = published.separatedFrom ?? published
                let platform = owners[ObjectIdentifier(bridge)]?[accessory.id]
                return (accessory, [platform?.platform, platform?.name, accessory.id, accessory.name].compactMap { $0 })
            }
        }
    }

    public func observeDeviceChanges(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
        observeChanges { published, characteristic, value in observer(published.separatedFrom ?? published, characteristic, value) }
    }
}

/// The accessories of one HAP server, matched by their id and name.
public final class ServerAccessories: MatterAccessorySource {
    private let server: HAPServer

    public init(_ server: HAPServer) {
        self.server = server
    }

    public var matterAccessories: [(accessory: Accessory, names: [String])] {
        server.accessories.map { ($0, [$0.id, $0.name]) }
    }

    // The server keeps its observers: a cancelled observation stops passing calls on.
    public func observeDeviceChanges(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
        let active = NIOLockedValueBox(true)
        server.observeChanges { accessory, characteristic, value in
            if active.withLockedValue({ $0 }) { observer(accessory, characteristic, value) }
        }
        return Observation { active.withLockedValue { $0 = false } }
    }

    public func observeStructure(_ observer: @escaping @Sendable () -> Void) -> Observation {
        let active = NIOLockedValueBox(true)
        server.observeStructure {
            if active.withLockedValue({ $0 }) { observer() }
        }
        return Observation { active.withLockedValue { $0 = false } }
    }
}
