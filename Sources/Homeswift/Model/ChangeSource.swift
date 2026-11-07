import Foundation

/// Who or what made a change (GLOSSARY.md): the Home app, a Homeswift user, an MCP client, an Automation or Scene,
/// or the Device itself.
///
/// The paths that write a characteristic set it for the task that writes (`ChangeSource.$current`): the HAP server
/// for a controller's write, the web UI for its user, the MCP server for its client, the scenes runner for its Scene
/// or Automation. Whatever changes a value with none set, a plugin hearing from its device, is the Device. Observers
/// of changes and writes (`HAPServer.observeChanges`, `observeWrites`) are called in the writing task, so
/// `ChangeSource.resolved` there says who made the change.
public enum ChangeSource: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A HomeKit controller, known only by its pairing's identifier.
    case homeApp(pairing: String)
    /// A signed-in user of the web UI, by username.
    case user(String)
    /// An MCP client, by the name it gave (or its token's).
    case mcpClient(String)
    /// An Automation, by name.
    case automation(String)
    /// A Scene, by name.
    case scene(String)
    /// The device itself: changed at the device, by its hub, or by its plugin.
    case device

    /// The source the current task writes for; nil when none was set (`resolved` is then `device`).
    @TaskLocal public static var current: Stamped?

    /// A source and when it was set: a task a write handler spawned inherits it, and one that lives on (a polling
    /// loop started by a write) must not make the device's later changes look like that writer's.
    public struct Stamped: Sendable {
        public var source: ChangeSource
        public var since: ContinuousClock.Instant
    }

    /// How long a source set for a task stands for the changes made in it.
    public static let lifetime: Duration = .seconds(60)

    /// Who makes the change the current task makes now.
    public static var resolved: ChangeSource {
        guard let current, ContinuousClock.now - current.since < lifetime else { return .device }
        return current.source
    }

    /// Runs `operation` with this as the source of the changes it makes.
    public func run<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
        try await Self.$current.withValue(Stamped(source: self, since: .now)) { try await operation() }
    }

    /// The kind, as JSON and the web UI's filter have it.
    public var kind: String {
        switch self {
        case .homeApp: "homeApp"
        case .user: "user"
        case .mcpClient: "mcp"
        case .automation: "automation"
        case .scene: "scene"
        case .device: "device"
        }
    }

    /// A person or an MCP client: who it is, which only administrators see (the audit log's rule).
    public var namesSomeone: Bool {
        switch self {
        case .user, .mcpClient: true
        case .homeApp, .automation, .scene, .device: false
        }
    }

    /// The kinds whose names only administrators see, as `kind` writes them.
    public static let kindsNamingSomeone: Set<String> = ["user", "mcp"]

    /// The name: the pairing, the user, the client, the Automation or Scene; nil for the device.
    public var name: String? {
        switch self {
        case .homeApp(let pairing): pairing
        case .user(let name), .mcpClient(let name), .automation(let name), .scene(let name): name
        case .device: nil
        }
    }

    public init?(kind: String, name: String?) {
        switch (kind, name) {
        case ("homeApp", let name?): self = .homeApp(pairing: name)
        case ("user", let name?): self = .user(name)
        case ("mcp", let name?): self = .mcpClient(name)
        case ("automation", let name?): self = .automation(name)
        case ("scene", let name?): self = .scene(name)
        case ("device", _): self = .device
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .homeApp(let pairing): "the Home app (\(pairing.prefix(8)))"
        case .user(let name): "user \(name)"
        case .mcpClient(let name): "MCP client \(name)"
        case .automation(let name): "automation \(name)"
        case .scene(let name): "scene \(name)"
        case .device: "the device"
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard let source = ChangeSource(kind: kind, name: try container.decodeIfPresent(String.self, forKey: .name)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not a change source: \(kind)")
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(name, forKey: .name)
    }
}
