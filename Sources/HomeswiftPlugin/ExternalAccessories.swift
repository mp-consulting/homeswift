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
    // The servers on their way out, by "<key>/<accessory id>" (`unpublishInBackground`).
    private let stopping = NIOLockedValueBox<[String: Task<Void, Never>]>([:])
    private let storageDirectory: URL
    private let options: PluginHost.Options
    private let setupCode: @Sendable () -> SetupCode
    private let added: @Sendable (PluginHost.Bridge) -> Void

    init(
        bridges: NIOLockedValueBox<[PluginHost.Bridge]>, storageDirectory: URL, options: PluginHost.Options, setupCode: @escaping @Sendable () -> SetupCode,
        added: @escaping @Sendable (PluginHost.Bridge) -> Void = { _ in }
    ) {
        self.bridges = bridges
        self.storageDirectory = storageDirectory
        self.options = options
        self.setupCode = setupCode
        self.added = added
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
        serverOptions.advertiser = options.advertiser
        serverOptions.interfaces = options.interfaces
        serverOptions.setupCode = setupCode()
        let storage = options.makeStorage?(storageName)
            ?? FileStorage(url: storageDirectory.appendingPathComponent("\(storageName).json"))
        let server = try HAPServer(accessory: accessory, storage: storage, options: serverOptions)
        let bridge = PluginHost.Bridge(name: accessory.name, server: server, isChild: false, isExternal: true, owner: owner, ownerKey: key)
        bridges.withLockedValue { $0.append(bridge) }
        added(bridge)
        return (bridge, true)
    }

    /// Stops and forgets the server of an accessory. Its state file stays, so publishing the accessory
    /// again brings its identity and pairings back.
    func unpublish(id: String, key: String) async {
        await take(id: id, key: key)?.server.stop()
    }

    /// Takes the server of an accessory off the list at once and stops it in the background: a `publish` from
    /// then on makes a new server rather than finding one on its way out, and `stopped` waits for the old one.
    func unpublishInBackground(id: String, key: String) {
        guard let bridge = take(id: id, key: key) else { return }
        let name = "\(key)/\(id)", stopping = stopping
        let task = Task { await bridge.server.stop() }
        stopping.withLockedValue { $0[name] = task }
        Task {
            await task.value
            stopping.withLockedValue { if $0[name] == task { $0[name] = nil } }
        }
    }

    /// Waits until the server `unpublishInBackground` took for this accessory has stopped, so its successor
    /// never advertises the same identity beside it.
    func stopped(id: String, key: String) async {
        let name = "\(key)/\(id)"
        await stopping.withLockedValue { $0[name] }?.value
    }

    private func take(id: String, key: String) -> PluginHost.Bridge? {
        bridges.withLockedValue { bridges in
            guard let index = bridges.firstIndex(where: { $0.isExternal && $0.ownerKey == key && $0.server.primary.id == id }) else { return nil }
            return bridges.remove(at: index)
        }
    }
}
