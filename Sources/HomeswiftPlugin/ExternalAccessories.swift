import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// The standalone HAP servers of the accessories plugins publish outside their bridge (Homebridge's
/// external accessories): one server per accessory, with its own identity and pairings, the main bridge's
/// setup code so the user has one code to enter. HomeKit wants televisions and cameras this way.
///
/// State lives in `external/<platform>-<name>-<accessory id>.json` under the storage directory.
final class ExternalAccessories: @unchecked Sendable {
    private let bridges: NIOLockedValueBox<[PluginHost.Bridge]>
    private let running = NIOLockedValueBox(false)
    private let storageDirectory: URL
    private let options: PluginHost.Options
    private let setupCode: @Sendable () -> SetupCode

    init(bridges: NIOLockedValueBox<[PluginHost.Bridge]>, storageDirectory: URL, options: PluginHost.Options, setupCode: @escaping @Sendable () -> SetupCode) {
        self.bridges = bridges
        self.storageDirectory = storageDirectory
        self.options = options
        self.setupCode = setupCode
    }

    /// Whether the host has started its servers: a server published from now on starts at once.
    var isRunning: Bool { running.withLockedValue { $0 } }

    func markRunning() { running.withLockedValue { $0 = true } }

    func bridge(id: String, key: String) -> PluginHost.Bridge? {
        bridges.withLockedValue { $0.first { $0.isExternal && $0.ownerKey == key && $0.server.primary.id == id } }
    }

    /// Creates the server of a new accessory, or replaces the accessory of the server that already has
    /// its id (same identity, same iids). A new server is started by the caller when the host runs.
    func publish(_ accessory: Accessory, key: String, owner: String) throws -> (bridge: PluginHost.Bridge, isNew: Bool) {
        if let existing = bridge(id: accessory.id, key: key) {
            try existing.server.replace(primary: accessory)
            return (existing, false)
        }
        let storageName = "external/\(key)-\(PluginHost.slug(accessory.id))"
        var serverLogger = Logger(label: accessory.name)
        serverLogger.logLevel = options.logger.logLevel
        var serverOptions = HAPServer.Options(advertise: options.advertise, logger: serverLogger)
        serverOptions.setupCode = setupCode()
        let storage = options.makeStorage?(storageName)
            ?? FileStorage(url: storageDirectory.appendingPathComponent("\(storageName).json"))
        let server = try HAPServer(accessory: accessory, storage: storage, options: serverOptions)
        let bridge = PluginHost.Bridge(name: accessory.name, server: server, isChild: false, isExternal: true, owner: owner, ownerKey: key)
        bridges.withLockedValue { $0.append(bridge) }
        return (bridge, true)
    }

    /// Stops and forgets the server of an accessory. Its state file stays, so publishing the accessory
    /// again brings its identity and pairings back.
    func unpublish(id: String, key: String) async {
        guard let bridge = bridge(id: id, key: key) else { return }
        bridges.withLockedValue { $0.removeAll { $0 === bridge } }
        await bridge.server.stop()
    }
}
