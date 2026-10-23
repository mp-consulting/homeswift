import Foundation
import Homeswift
import Logging

// What the MCP server and the web UI do to a running host besides applying a configuration: stop, start and
// restart a child bridge, list and clear the accessory caches, forget a bridge's pairings.

extension PluginHost {
    /// A child bridge as `list_child_bridges` shows it. Homeswift runs child bridges in its own process, so
    /// there are no crashes to count: a plugin that failed to start is the closest thing (`failures`).
    public struct ChildBridgeStatus: Sendable, Equatable {
        /// The bridge's device ID (Homebridge's `username`).
        public var id: String
        public var name: String
        /// The platform instances on it, by name, and their platforms and plugins.
        public var instances: [String]
        public var platforms: [String]
        public var plugins: [String]
        /// Its HAP server listens.
        public var running: Bool
        /// Stopped through `stopChildBridge`; it stays down until `startChildBridge`.
        public var stoppedManually: Bool
        public var paired: Bool
        public var controllers: Int
        public var port: Int?
        public var accessories: Int
        public var startedAt: Date?
        /// Restarts through `restartChildBridge` since the process started.
        public var restarts: Int
        /// Instance name to why its plugin did not start.
        public var failures: [String: String]

        /// `ok`, `degraded` (a plugin on it did not start) or `stopped`.
        public var status: String { !running ? "stopped" : failures.isEmpty ? "ok" : "degraded" }
    }

    /// An accessory in a platform instance's cache file (`accessories/<platform>-<name>.json`).
    public struct CachedAccessoryInfo: Sendable, Equatable {
        public var id: String
        public var name: String
        public var category: String
        public var manufacturer: String
        public var model: String
        /// The cache file, relative to the storage directory.
        public var cacheFile: String
        /// The instance the file belongs to; nil when no running block has that file any more.
        public var platform: String?
        public var instance: String?
        public var bridge: String?
        /// Published on its own HAP server.
        public var external: Bool
        /// Back from the cache, and its plugin has not added it again: a device it has not reached yet, or no
        /// longer has.
        public var restoredOnly: Bool
    }

    /// Runs `work` after the reloads and controls queued before it, so a save and a stop never interleave.
    func serialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = reloadTail.withLockedValue { tail -> Task<T, Never> in
            let previous = tail
            let task = Task { () -> T in
                _ = await previous?.value
                return await work()
            }
            tail = Task { _ = await task.value }
            return task
        }
        return await task.value
    }

    // MARK: Child bridges

    public var childBridges: [ChildBridgeStatus] {
        let instances = self.instances
        return bridges.filter(\.isChild).map { bridge in
            let mine = instances.filter { $0.context.bridge === bridge }
            let lifecycle = bridge.lifecycle.withLockedValue { $0 }
            let server = bridge.server
            let running = server.port != nil
            var failures: [String: String] = [:]
            for instance in mine { if let failure = instance.failure.withLockedValue({ $0 }) { failures[instance.context.name] = failure } }
            return ChildBridgeStatus(
                id: server.deviceID, name: bridge.name, instances: mine.map(\.context.name), platforms: mine.map(\.context.platform), plugins: mine.map(\.entry.name),
                running: running, stoppedManually: lifecycle.stoppedManually, paired: server.isPaired, controllers: server.pairings.count, port: server.port,
                accessories: max(0, server.accessories.count - 1), startedAt: running ? lifecycle.startedAt : nil, restarts: lifecycle.restarts, failures: failures)
        }
    }

    /// The child bridge with this device ID (with or without colons, any case) or name.
    public func childBridge(id: String) -> Bridge? {
        bridges.filter(\.isChild).first { Self.sameBridge($0, id) }
    }

    static func sameBridge(_ bridge: Bridge, _ id: String) -> Bool {
        let bare = { (text: String) in text.replacingOccurrences(of: ":", with: "").uppercased() }
        return bare(bridge.server.deviceID) == bare(id) || bridge.name.lowercased() == id.lowercased()
    }

    /// Stops the plugins of a child bridge, the servers of their external accessories and the bridge's server.
    /// It stays down, across configuration saves, until `startChildBridge`; a restart of the process starts it.
    public func stopChildBridge(id: String) async throws {
        guard let bridge = childBridge(id: id) else { throw HostControlError.unknownChildBridge(id) }
        await serialized {
            bridge.lifecycle.withLockedValue { $0.stoppedManually = true }
            await self.halt(bridge)
            self.logger.notice("Child bridge stopped", metadata: ["bridge": "\(bridge.name)"])
        }
    }

    /// Starts a child bridge `stopChildBridge` stopped, and its plugins. Nothing happens to one that runs.
    public func startChildBridge(id: String) async throws {
        guard let bridge = childBridge(id: id) else { throw HostControlError.unknownChildBridge(id) }
        let failure: String? = await serialized {
            bridge.lifecycle.withLockedValue { $0.stoppedManually = false }
            do {
                try await self.resume(bridge)
                return nil
            } catch {
                return "\(error)"
            }
        }
        if let failure { throw HostControlError.startFailed(bridge.name, failure) }
    }

    /// Stops a child bridge and starts it again: its plugins start afresh on the same accessories, aids and
    /// pairings. A stopped one just starts.
    public func restartChildBridge(id: String) async throws {
        guard let bridge = childBridge(id: id) else { throw HostControlError.unknownChildBridge(id) }
        let failure: String? = await serialized {
            await self.halt(bridge)
            bridge.lifecycle.withLockedValue {
                $0.stoppedManually = false
                $0.restarts += 1
            }
            do {
                try await self.resume(bridge)
                return nil
            } catch {
                return "\(error)"
            }
        }
        if let failure { throw HostControlError.startFailed(bridge.name, failure) }
    }

    private func externalBridges(of instances: [Instance]) -> [Bridge] {
        let keys = Set(instances.map(\.context.key))
        return bridges.filter { $0.isExternal && $0.ownerKey.map(keys.contains) == true }
    }

    private func halt(_ bridge: Bridge) async {
        let mine = instances.filter { $0.context.bridge === bridge }
        for instance in mine { await stopPlugin(instance) }
        for external in externalBridges(of: mine) { await external.server.stop() }
        await bridge.server.stop()
        bridge.lifecycle.withLockedValue { $0.startedAt = nil }
    }

    private func resume(_ bridge: Bridge) async throws {
        if bridge.server.port == nil {
            try await bridge.server.start()
            bridge.lifecycle.withLockedValue { $0.startedAt = Date() }
            logger.notice("Child bridge started", metadata: ["bridge": "\(bridge.name)"])
        }
        let mine = instances.filter { $0.context.bridge === bridge }
        for external in externalBridges(of: mine) where external.server.port == nil {
            do { try await external.server.start() } catch { logger.warning("Could not start \(external.name): \(error)") }
        }
        for instance in mine where instance.plugin.withLockedValue({ $0 }) == nil {
            await launch(instance)
        }
    }

    // MARK: Accessory caches

    var cacheDirectory: URL { storageDirectory.appendingPathComponent("accessories") }

    /// Every accessory of every cache file, those of blocks no longer in the configuration included.
    public func cachedAccessories() -> [CachedAccessoryInfo] {
        let byKey = Dictionary(instances.map { ($0.context.key, $0) }, uniquingKeysWith: { first, _ in first })
        return cacheFiles().flatMap { file -> [CachedAccessoryInfo] in
            let key = String(file.dropLast(".json".count))
            guard let cache = try? JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: cacheDirectory.appendingPathComponent(file))) else { return [] }
            let instance = byKey[key]
            return cache.accessories.map { accessory in
                CachedAccessoryInfo(
                    id: accessory.id, name: accessory.name, category: "\(accessory.category)", manufacturer: accessory.manufacturer, model: accessory.model,
                    cacheFile: "accessories/\(file)", platform: instance?.context.platform, instance: instance?.context.name,
                    bridge: instance?.context.bridge.name, external: accessory.external ?? false,
                    restoredOnly: instance?.context.isRestoredOnly(id: accessory.id) ?? false)
            }
        }
    }

    private func cacheFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Removes one accessory from its cache and, when its instance has it, from HomeKit. A plugin that still
    /// has the device adds it again. `cacheFile` (as `cachedAccessories` gives it) says which, when several
    /// files have the id.
    @discardableResult
    public func removeCachedAccessory(id: String, cacheFile: String? = nil) async throws -> CachedAccessoryInfo {
        let matches = cachedAccessories().filter { $0.id == id && (cacheFile == nil || $0.cacheFile == cacheFile) }
        guard let found = matches.first else { throw HostControlError.unknownCachedAccessory(id) }
        guard matches.count == 1 else { throw HostControlError.ambiguousCachedAccessory(id, matches.map(\.cacheFile)) }
        let failure: String? = await serialized {
            let key = String(found.cacheFile.dropFirst("accessories/".count).dropLast(".json".count))
            if let instance = self.instances.first(where: { $0.context.key == key }), instance.context.accessory(id: id) != nil {
                do { try await instance.context.remove(id: id) } catch { return "\(error)" }
            } else {
                // A file no running block has: rewritten without the accessory, removed when it was the last one.
                let url = self.storageDirectory.appendingPathComponent(found.cacheFile)
                do {
                    var cache = try JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: url))
                    cache.accessories.removeAll { $0.id == id }
                    if cache.accessories.isEmpty {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try OwnerOnlyFile.write(encoder.encode(cache), to: url)
                    }
                } catch {
                    return "\(error)"
                }
            }
            self.logger.notice("Removed a cached accessory", metadata: ["accessory": "\(found.name)", "cache": "\(found.cacheFile)"])
            return nil
        }
        if let failure { throw HostControlError.cacheWriteFailed(failure) }
        return found
    }

    /// Empties every accessory cache: each instance's accessories leave HomeKit and its plugin starts again on
    /// an empty cache, adding the devices it has (with the aids and iids they had, so rooms and automations
    /// stay); files of blocks no longer configured go. Returns how many cached accessories there were.
    @discardableResult
    public func resetCachedAccessories() async -> Int {
        await serialized {
            let count = self.cachedAccessories().count
            let all = self.instances
            for instance in all {
                await self.stopPlugin(instance)
                await instance.context.detach()
            }
            for file in self.cacheFiles() { try? FileManager.default.removeItem(at: self.cacheDirectory.appendingPathComponent(file)) }
            self.logger.notice("Accessory caches reset", metadata: ["accessories": "\(count)"])
            for instance in all { await self.launch(instance, as: "Started on an empty accessory cache") }
            return count
        }
    }

    // MARK: Pairings

    /// The bridge, child bridge or external accessory with this device ID or name.
    public func bridge(id: String) -> Bridge? {
        bridges.first { Self.sameBridge($0, id) }
    }

    /// Forgets every controller paired with a bridge and disconnects them: the Home app must add it again
    /// (rooms and automations go with it). Returns the bridge.
    @discardableResult
    public func resetPairings(bridgeID id: String) throws -> Bridge {
        guard let bridge = bridge(id: id) else { throw HostControlError.unknownBridge(id) }
        try bridge.server.resetPairings()
        logger.warning("Pairings reset: add the bridge again in the Home app", metadata: ["bridge": "\(bridge.name)"])
        return bridge
    }
}

public enum HostControlError: Error, CustomStringConvertible, Equatable, Sendable {
    case unknownChildBridge(String)
    case unknownBridge(String)
    case startFailed(String, String)
    case unknownCachedAccessory(String)
    case ambiguousCachedAccessory(String, [String])
    case cacheWriteFailed(String)

    public var description: String {
        switch self {
        case .unknownChildBridge(let id): "no child bridge \"\(id)\""
        case .unknownBridge(let id): "no bridge \"\(id)\""
        case .startFailed(let name, let error): "\(name) did not start: \(error)"
        case .unknownCachedAccessory(let id): "no cached accessory \"\(id)\""
        case .ambiguousCachedAccessory(let id, let files): "\"\(id)\" is in several caches; pass cacheFile (\(files.joined(separator: ", ")))"
        case .cacheWriteFailed(let error): "could not change the cache: \(error)"
        }
    }
}
