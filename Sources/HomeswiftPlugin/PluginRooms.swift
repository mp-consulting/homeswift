import Foundation

/// A room a plugin's hub or cloud keeps (a Hue Bridge's room, a DIRIGERA hub's, an eWeLink home's), listed by
/// `HomeswiftPlugin.rooms()` so a Room renamed in Homeswift is renamed there too: Homeswift renames, with
/// `HomeswiftPlugin.renameRoom(id:name:)`, the hub rooms named as the Room was (case and accents aside). A hub's rooms
/// only follow: a room renamed on the hub stays as Homeswift has it, and they never add to the Rooms. Apple Home's rooms
/// are the Rooms themselves, through the Home Link (`HomeLink.swift`).
///
/// ```swift
/// func rooms() async -> [PluginRoom] {
///     (try? await hub.rooms())?.map { PluginRoom(id: $0.id, name: $0.name) } ?? []
/// }
///
/// func renameRoom(id: String, name: String) async throws {
///     try await hub.renameRoom(id, to: name)
/// }
/// ```
public struct PluginRoom: Sendable, Equatable {
    /// The hub's own id, unique within the plugin instance.
    public var id: String
    public var name: String
    /// Where the room is when the instance has several hubs or homes ("DIRIGERA 192.168.1.20", "Home"), for the log.
    public var place: String?

    public init(id: String, name: String, place: String? = nil) {
        self.id = id
        self.name = name
        self.place = place
    }
}

extension HomeswiftPlugin {
    public func rooms() async -> [PluginRoom] { [] }

    public func renameRoom(id: String, name: String) async throws {
        throw PluginRoomError("\(Self.name) cannot rename rooms")
    }

}

public struct PluginRoomError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension PluginHost {
    /// The rooms of a running plugin instance, with the instance they come from.
    public struct InstanceRooms: Sendable {
        public let instance: PlatformInstance
        public let rooms: [PluginRoom]
    }

    /// Every running instance's rooms (`HomeswiftPlugin.rooms()`), asked at the same time; paused instances and those
    /// with none are left out.
    public func pluginRooms() async -> [InstanceRooms] {
        let running = runningPlugins()
        return await withTaskGroup(of: (Int, InstanceRooms?).self) { group in
            for (index, (instance, plugin)) in running.enumerated() {
                group.addTask {
                    let rooms = await plugin.rooms()
                    return (index, rooms.isEmpty ? nil : InstanceRooms(instance: instance.described, rooms: rooms))
                }
            }
            var found: [(Int, InstanceRooms)] = []
            for await (index, rooms) in group { if let rooms { found.append((index, rooms)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Renames a room of the instance `name` of `platform` (`HomeswiftPlugin.renameRoom(id:name:)`).
    public func renameRoom(platform: String, name: String, id: String, to roomName: String) async throws {
        guard let plugin = running(platform: platform, name: name) else {
            throw PluginRoomError("\(name) is not running")
        }
        try await plugin.renameRoom(id: id, name: roomName)
    }

    /// The Device Kind the running instance gives one of its devices (`HomeswiftPlugin.deviceKind(of:)`); nil when it
    /// does not run or does not say.
    public func deviceKind(platform: String, name: String, deviceID: String) async -> String? {
        guard let plugin = running(platform: platform, name: name) else { return nil }
        return await plugin.deviceKind(of: deviceID)
    }

    /// The choices the running instance gives one of its Plugin Accessory Settings for a device
    /// (`HomeswiftPlugin.accessorySettingChoices`); nil when it gives none, or does not run.
    public func accessorySettingChoices(platform: String, name: String, key: String, deviceID: String) async -> [SetupOption]? {
        guard let plugin = running(platform: platform, name: name) else { return nil }
        return await plugin.accessorySettingChoices(key, deviceID: deviceID)
    }

    /// The block in its canonical shape, as its running instance writes it (`HomeswiftPlugin.canonicalSettings`), and what
    /// the plugin asked to do once the block is written (`PluginContext.whenSettingsWritten`), for the writer to run just
    /// before it writes config.json, never on a dry run; the block as it is, and nothing to do, when the instance does
    /// not run.
    @_disfavoredOverload
    public func canonicalSettings(platform: String, name: String, block: JSONValue) async -> (block: JSONValue, whenWritten: SettingsWrite.Effects) {
        guard let plugin = running(platform: platform, name: name) else { return (block, SettingsWrite.Effects()) }
        let effects = SettingsWrite.Effects()
        let canonical = await SettingsWrite.$pending.withValue(effects) { await plugin.canonicalSettings(block) }
        return (canonical, effects)
    }

    /// The block in its canonical shape, what the plugin asked to do once it is written done at once, as outside a
    /// settings write (a plugin's tests of its hook).
    public func canonicalSettings(platform: String, name: String, block: JSONValue) async -> JSONValue {
        let (canonical, whenWritten): (block: JSONValue, whenWritten: SettingsWrite.Effects) = await canonicalSettings(platform: platform, name: name, block: block)
        do { try await whenWritten.run() } catch { logger.warning("A settings change of \(name) did not apply: \(error)") }
        return canonical
    }
}

/// A settings write the bridge is making (`update_settings`, the web UI's settings, Setup, Forget), for what a plugin's
/// `canonicalSettings` does beyond answering the block, such as moving a legacy token into the vault: held until the
/// write is checked and about to be written, so a dry run, or a write the schema refuses, changes nothing.
public enum SettingsWrite {
    /// What the plugins asked to do once the write's blocks are written, in the order they asked.
    public final class Effects: @unchecked Sendable {
        private let lock = NSLock()
        private var effects: [@Sendable () async throws -> Void] = []

        public init() {}

        func append(_ effect: @escaping @Sendable () async throws -> Void) {
            lock.withLock { effects.append(effect) }
        }

        /// Adds another write's effects after these.
        public func append(contentsOf other: Effects) {
            let more = other.lock.withLock { other.effects }
            lock.withLock { effects += more }
        }

        public var isEmpty: Bool { lock.withLock { effects.isEmpty } }

        /// Runs them, each once; the first that fails stops the write (config.json is not written).
        public func run() async throws {
            let pending = lock.withLock {
                defer { effects = [] }
                return effects
            }
            for effect in pending { try await effect() }
        }
    }

    /// The effects of the `canonicalSettings` call running now, set by `PluginHost.canonicalSettings`.
    @TaskLocal static var pending: Effects?
}

extension PluginContext {
    /// Runs `effect` once the settings write that asked for the canonical block (`HomeswiftPlugin.canonicalSettings`) is
    /// checked, just before config.json is written: never on a dry run or a refused write. An effect that throws stops the
    /// write, so a token the block drops is never lost; one that runs and whose write then fails has done no harm if it
    /// is idempotent (a vault entry written again). Outside a settings write, `effect` runs at once.
    ///
    /// ```swift
    /// func canonicalSettings(_ block: JSONValue) async -> JSONValue {
    ///     guard let token = block["token"]?.stringValue else { return block }
    ///     await context.whenSettingsWritten { try self.context.saveCredentials(["token": .string(token)]) }
    ///     var fields = block.objectValue ?? [:]
    ///     fields.removeValue(forKey: "token")   // as if the vault had it: it will once the block is written
    ///     return .object(fields)
    /// }
    /// ```
    public func whenSettingsWritten(_ effect: @escaping @Sendable () async throws -> Void) async {
        if let pending = SettingsWrite.pending {
            pending.append(effect)
        } else {
            do { try await effect() } catch { logger.warning("A settings change of \(name) did not apply: \(error)") }
        }
    }
}
