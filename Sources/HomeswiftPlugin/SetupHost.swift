import Foundation
import HomeswiftAI
import NIOConcurrencyHelpers

// The host's side of Setup: the plugin a step runs on, and what discovery finds. A step runs on the instance's running
// plugin when its block is the one asked for; otherwise (a block not saved yet, a plugin that failed to start, a paused
// one) on a plugin made for the step and stopped after it, never started, so Setup never waits for a reload.
extension PluginHost {
    /// Runs `body` with a plugin for the block `platform`/`name`: the instance's running plugin, else one made from
    /// `block` when given (a draft not saved yet) or the block config.json has. The context is the instance's, or the one it will have once the block is saved, so the
    /// credentials it reads and writes are the instance's.
    public func withSetupPlugin<T: Sendable>(
        platform: String, name: String?, block: JSONValue? = nil, _ body: (any HomeswiftPlugin, PluginContext) async throws -> T
    ) async throws -> T {
        guard let entry = registry.entry(for: platform) else { throw SetupError("No plugin for platform \(platform)") }
        let name = name ?? platform
        let instance = instances.first { $0.context.platform == platform && $0.context.name == name }
        var json: Data
        if let block {
            json = block.encoded()
        } else if let instance {
            json = instance.block.json
        } else {
            json = JSONValue.object(["platform": .string(platform), "name": .string(name)]).encoded()
        }
        // A running plugin answers for its instance, whatever block was asked: a second plugin on its context would write
        // the same credentials and stores at the same time. A draft only makes sense for a block not saved yet.
        if let instance, !instance.block.paused, let plugin = instance.plugin.withLockedValue({ $0 }) {
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
                externals: externals, values: ValueFeed(), energyImports: EnergyImportFeed(), energyProgress: .init([:]), meterReadings: MeterFeed(limit: 0), assistantBackground: entry.assistantBackground,
                location: locationReader)
            context.accessorySettingsBox.withLockedValue { $0 = draft.accessorySettings }
            context.ownDeviceIDBox.withLockedValue { $0 = entry.deviceIDOfAccessory }
            share(with: context)
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

    /// What the plugin of the block finds now, and whether its account is Authorized, from one plugin: each device set up
    /// when the plugin says so, when it has credentials and Accessory Settings of its own, or when its accessory is on the
    /// bridge, and Excluded
    /// when its Accessory Settings say so.
    public func discover(platform: String, name: String?, block: JSONValue? = nil) async throws -> Discovery {
        try await withSetupPlugin(platform: platform, name: name, block: block) { plugin, context in
            async let found = plugin.discover()
            async let pluginAnswer = plugin.accountAuthorized()
            var seen = Set<String>()
            let devices = try await found.filter { seen.insert($0.deviceID).inserted }
            // One read of the vault's names for the account and every device.
            let authorized = context.haveCredentials([nil] + devices.filter { $0.authorization != .none }.map(\.deviceID))
            // A device's credentials count with its Accessory Settings, as the runtime runs it (`setUpDevices`): a login
            // left in the vault by a block removed and added again is not a device set up.
            let configured = Set(context.allAccessorySettings.keys)
            let accessoryIDs = context.accessories.map(\.id)
            let marked = devices.map { device in
                var device = device
                device.isExcluded = context.isExcluded(device.deviceID)
                let published = accessoryIDs.contains { context.isAccessory($0, of: device.deviceID) }
                device.isSetUp = !device.isExcluded && !device.excludedBySettings && (device.isSetUp || published || authorized.contains(device.deviceID) && configured.contains(device.deviceID))
                return device
            }
            let accountAuthorized = await pluginAnswer ?? authorized.contains(nil)
            let account = AccountState(method: registry.entry(for: platform)?.accountAuthorization ?? .none, refused: context.accountRefusal != nil, authorized: accountAuthorized)
            return Discovery(devices: marked, accountAuthorized: accountAuthorized, accountState: account)
        }
    }

    /// Where the account of each instance the host runs stands, by `<platform>/<name>`, without a discovery: what its
    /// running plugin answers (`accountAuthorized()`), else whether the vault has its credentials, and refused when the
    /// plugin said so. A paused instance, or one whose plugin did not start, is read from the vault, and so is a plugin
    /// that takes longer than `accountAnswerTimeout` to answer: a busy one does not hold up the Plugins page.
    public func accountStates() async -> [String: AccountState] {
        await withTaskGroup(of: (String, AccountState).self) { group in
            for instance in instances {
                let method = instance.entry.accountAuthorization
                let plugin = instance.block.paused ? nil : instance.plugin.withLockedValue { $0 }
                let context = instance.context
                group.addTask {
                    let id = "\(context.platform)/\(context.name)"
                    guard method != .none else { return (id, .none) }
                    let refused = context.accountRefusal != nil
                    var authorized = false
                    if !refused {
                        let answer = if let plugin { await Self.accountAnswer(of: plugin, within: Self.accountAnswerTimeout) } else { Bool?.none }
                        authorized = answer ?? context.haveCredentials([nil]).contains(nil)
                    }
                    return (id, AccountState(method: method, refused: refused, authorized: authorized))
                }
            }
            var states: [String: AccountState] = [:]
            for await (id, state) in group { states[id] = state }
            return states
        }
    }

    /// How long `accountStates` waits for a plugin's `accountAuthorized()`.
    static let accountAnswerTimeout: Duration = .seconds(2)

    /// The plugin's `accountAuthorized()`, or nil when it has not answered within `timeout` (it goes on, unheard).
    static func accountAnswer(of plugin: any HomeswiftPlugin, within timeout: Duration) async -> Bool? {
        let pending = NIOLockedValueBox<CheckedContinuation<Bool?, Never>?>(nil)
        let resume: @Sendable (Bool?) -> Void = { answer in pending.withLockedValue { continuation in continuation?.resume(returning: answer); continuation = nil } }
        return await withCheckedContinuation { continuation in
            pending.withLockedValue { $0 = continuation }
            let timer = Task { try? await Task.sleep(for: timeout); resume(nil) }
            Task { resume(await plugin.accountAuthorized()); timer.cancel() }
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
