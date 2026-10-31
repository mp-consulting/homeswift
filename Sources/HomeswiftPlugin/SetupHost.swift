import Foundation
import HomeswiftAI
import NIOConcurrencyHelpers

// The host's side of Setup: the plugin a step runs on, and what discovery finds. A step runs on the instance's running
// plugin when its block is the one asked for; otherwise (a block not saved yet, a plugin that failed to start, a paused
// one) on a plugin made for the step and stopped after it, never started, so Setup never waits for a reload.
extension PluginHost {
    /// Runs `body` with a plugin for the block `platform`/`name`: `block` when given (a draft not saved yet), else the
    /// block config.json has. The context is the instance's, or the one it will have once the block is saved, so the
    /// credentials it reads and writes are the instance's.
    public func withSetupPlugin<T: Sendable>(
        platform: String, name: String?, block: JSONValue? = nil, _ body: (any HomeswiftPlugin, PluginContext) async throws -> T
    ) async throws -> T {
        guard let entry = registry.entry(for: platform) else { throw SetupError("No plugin for platform \(platform)") }
        let name = name ?? platform
        let instance = instances.first { $0.context.platform == platform && $0.context.name == name }
        var json: Data
        if let block {
            json = try block.encoded()
        } else if let instance {
            json = instance.block.json
        } else {
            json = try JSONValue.object(["platform": .string(platform), "name": .string(name)]).encoded()
        }
        if let instance, !instance.block.paused, instance.block.json == json, let plugin = instance.plugin.withLockedValue({ $0 }) {
            return try await body(plugin, instance.context)
        }
        let context: PluginContext
        if let instance {
            context = instance.context
        } else {
            let draft = HomeswiftConfiguration.Platform(platform: platform, name: name, json: json)
            let key = Self.uniqueKey(for: draft, taken: Set(instances.map(\.context.key)))
            context = Self.makeContext(
                block: draft, key: key, bridge: mainBridge, storageDirectory: storageDirectory, logLevel: logger.logLevel, assistant: assistantBox,
                externals: externals, values: ValueFeed(), energyImports: EnergyImportFeed(), energyProgress: .init([:]), assistantBackground: entry.assistantBackground)
            context.accessorySettingsBox.withLockedValue { $0 = draft.accessorySettings }
        }
        let plugin = try await entry.make(json, context)
        do {
            let result = try await body(plugin, context)
            await plugin.stop()
            return result
        } catch {
            await plugin.stop()
            throw error
        }
    }

    /// What the plugin of the block finds now, each device marked set up when the plugin says so, when it has
    /// credentials of its own, or when its accessory is on the bridge; never when it is Excluded.
    public func discoverDevices(platform: String, name: String?, block: JSONValue? = nil) async throws -> [DiscoveredDevice] {
        try await withSetupPlugin(platform: platform, name: name, block: block) { plugin, context in
            let accessoryIDs = Set(context.accessories.map(\.id))
            var seen = Set<String>()
            return try await plugin.discover().compactMap { device in
                guard seen.insert(device.deviceID).inserted else { return nil }
                var device = device
                let id = context.accessoryID(of: device.deviceID)
                let published = accessoryIDs.contains(id) || accessoryIDs.contains { $0.hasPrefix("\(id):") }
                let authorized = device.authorization != .none && context.credentials(for: device.deviceID) != nil
                device.isSetUp = !context.isExcluded(device.deviceID) && (device.isSetUp || published || authorized)
                return device
            }
        }
    }

    /// The context of a block's instance, when the host runs one.
    public func context(platform: String, name: String?) -> PluginContext? {
        instances.first { $0.context.platform == platform && $0.context.name == (name ?? platform) }?.context
    }

    /// Starts a fresh plugin on the instance's context, as a changed block does: what Setup saved in the vault reaches it.
    public func relaunch(platform: String, name: String?) async {
        await serialized {
            guard let instance = self.instances.first(where: { $0.context.platform == platform && $0.context.name == (name ?? platform) }) else { return }
            await self.stopPlugin(instance)
            await self.launch(instance, as: "Reloaded")
        }
    }
}
