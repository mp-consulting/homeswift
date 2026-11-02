import Foundation

/// An automation a plugin's hub keeps (Apple Home's, through Wingman), listed by `HomeswiftPlugin.automations()` so the
/// web UI and the MCP tools show it beside Homeswift's own scenes with triggers, and changed on the hub with
/// `updateAutomation(id:change:)` and `deleteAutomation(id:)`. As with `PluginScene`, the hub stays its only keeper:
/// Homeswift asks again each time and keeps no copy. docs/apple-home-design.md has the design.
///
/// Accessories are named by Homeswift's ids and characteristic types, so a page draws them with their own names and
/// widgets; one Homeswift does not have is named by `names`.
///
/// ```swift
/// func automations() async -> [PluginAutomation] {
///     hub.rules.map { PluginAutomation(id: $0.id, name: $0.name, enabled: $0.on, triggers: [.time(PluginAutomationTime(hour: 7, minute: 0))]) }
/// }
///
/// func updateAutomation(id: String, change: PluginAutomationChange) async throws {
///     if let enabled = change.enabled { try await hub.setRule(id, on: enabled) }
/// }
/// ```
public struct PluginAutomation: Sendable, Equatable {
    /// What Homeswift may change on the hub.
    public enum Capability: String, Sendable, CaseIterable {
        /// Turn it on and off.
        case enable
        case rename
        /// Change its time (one `.time` trigger only).
        case time
        /// Change which of the plugin's scenes it runs.
        case scenes
        /// Replace its own actions.
        case actions
        case delete
    }

    /// The hub's own id: unique within the plugin instance, without a `/`.
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Where it is when the instance has several homes or hubs ("Home"), for display.
    public var place: String?
    /// Any of them starts it.
    public var triggers: [PluginAutomationTrigger]
    /// Any of them ends it, such as "Turn off after 10 minutes".
    public var endTriggers: [PluginAutomationTrigger]
    /// All must hold for it to run.
    public var conditions: [PluginAutomationCondition]
    /// The plugin's own `PluginScene` ids it runs.
    public var sceneIDs: [String]
    /// Its own actions, besides the scenes.
    public var actions: [PluginAutomationAction]
    /// The names, as the hub has them, of the accessories it mentions, by Homeswift id: for those Homeswift leaves out.
    public var names: [String: String]
    public var lastRun: Date?
    public var capabilities: Set<Capability>

    public init(id: String, name: String, enabled: Bool, place: String? = nil, triggers: [PluginAutomationTrigger], endTriggers: [PluginAutomationTrigger] = [],
                conditions: [PluginAutomationCondition] = [], sceneIDs: [String] = [], actions: [PluginAutomationAction] = [], names: [String: String] = [:],
                lastRun: Date? = nil, capabilities: Set<Capability> = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.place = place
        self.triggers = triggers
        self.endTriggers = endTriggers
        self.conditions = conditions
        self.sceneIDs = sceneIDs
        self.actions = actions
        self.names = names
        self.lastRun = lastRun
        self.capabilities = capabilities
    }
}

/// A time of day: a clock time, or sunrise or sunset with an offset, on some weekdays.
public struct PluginAutomationTime: Sendable, Equatable {
    public enum SolarEvent: String, Sendable, CaseIterable { case sunrise, sunset }

    public var hour: Int?
    public var minute: Int?
    /// Instead of a clock time.
    public var solarEvent: SolarEvent?
    /// Minutes after the solar event (before when negative).
    public var offsetMinutes: Int
    /// 1 (Sunday) to 7, as `Calendar` numbers them; empty is every day.
    public var weekdays: [Int]

    public init(hour: Int? = nil, minute: Int? = nil, solarEvent: SolarEvent? = nil, offsetMinutes: Int = 0, weekdays: [Int] = []) {
        self.hour = hour
        self.minute = minute
        self.solarEvent = solarEvent
        self.offsetMinutes = offsetMinutes
        self.weekdays = weekdays
    }
}

/// What starts (or ends) an automation.
public enum PluginAutomationTrigger: Sendable, Equatable {
    case time(PluginAutomationTime)
    /// A characteristic reaching a value, or entering a range (`minimum`, `maximum`, either open).
    case accessory(accessoryID: String, characteristic: String, value: JSONValue?, minimum: Double?, maximum: Double?)
    /// `who` is "anyone", "me" or "everyone".
    case presence(who: String, arriving: Bool)
    /// A while after it started.
    case duration(seconds: Int)
    /// Anything else, as the hub describes it.
    case other(String)
}

/// What must hold for an automation to run.
public enum PluginAutomationCondition: Sendable, Equatable {
    /// Between two times; either may be open.
    case time(after: PluginAutomationTime?, before: PluginAutomationTime?)
    /// `comparison` is "==", "!=", "<", "<=", ">" or ">=".
    case accessory(accessoryID: String, characteristic: String, comparison: String, value: JSONValue)
    /// Whether `who` ("anyone", "me", "everyone") is at home.
    case presence(who: String, home: Bool)
    case other(String)
}

/// A characteristic an automation sets.
public struct PluginAutomationAction: Sendable, Equatable {
    /// Homeswift's id of the accessory.
    public var accessoryID: String
    /// Homeswift's name for the characteristic type ("Brightness"), or its UUID for one Homeswift does not know.
    public var characteristic: String
    public var value: JSONValue

    public init(accessoryID: String, characteristic: String, value: JSONValue) {
        self.accessoryID = accessoryID
        self.characteristic = characteristic
        self.value = value
    }
}

/// What `HomeswiftPlugin.updateAutomation` changes; nil leaves it as it is.
public struct PluginAutomationChange: Sendable, Equatable {
    public var name: String?
    public var enabled: Bool?
    public var time: PluginAutomationTime?
    public var sceneIDs: [String]?
    public var actions: [PluginAutomationAction]?

    public init(name: String? = nil, enabled: Bool? = nil, time: PluginAutomationTime? = nil, sceneIDs: [String]? = nil, actions: [PluginAutomationAction]? = nil) {
        self.name = name
        self.enabled = enabled
        self.time = time
        self.sceneIDs = sceneIDs
        self.actions = actions
    }
}

extension HomeswiftPlugin {
    public func automations() async -> [PluginAutomation] { [] }

    public func updateAutomation(id: String, change: PluginAutomationChange) async throws {
        throw PluginAutomationError("\(Self.name) cannot change its automations")
    }

    public func deleteAutomation(id: String) async throws {
        throw PluginAutomationError("\(Self.name) cannot remove its automations")
    }
}

public struct PluginAutomationError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension PluginHost {
    /// The automations of a running plugin instance, with the instance they come from.
    public struct InstanceAutomations: Sendable {
        public let instance: PlatformInstance
        public let automations: [PluginAutomation]
    }

    /// Every running instance's automations (`HomeswiftPlugin.automations()`), asked at the same time; paused instances
    /// and those with none are left out.
    public func pluginAutomations() async -> [InstanceAutomations] {
        let running = runningPlugins()
        return await withTaskGroup(of: (Int, InstanceAutomations?).self) { group in
            for (index, (instance, plugin)) in running.enumerated() {
                group.addTask {
                    let automations = await plugin.automations()
                    return (index, automations.isEmpty ? nil : InstanceAutomations(instance: instance.described, automations: automations))
                }
            }
            var found: [(Int, InstanceAutomations)] = []
            for await (index, automations) in group { if let automations { found.append((index, automations)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func updateAutomation(platform: String, name: String, id: String, change: PluginAutomationChange) async throws {
        try await automationPlugin(platform: platform, name: name).updateAutomation(id: id, change: change)
    }

    public func deleteAutomation(platform: String, name: String, id: String) async throws {
        try await automationPlugin(platform: platform, name: name).deleteAutomation(id: id)
    }

    private func automationPlugin(platform: String, name: String) throws -> any HomeswiftPlugin {
        guard let running = runningPlugins().first(where: { $0.instance.context.platform == platform && $0.instance.context.name == name }) else {
            throw PluginAutomationError("\(name) is not running")
        }
        return running.plugin
    }
}
