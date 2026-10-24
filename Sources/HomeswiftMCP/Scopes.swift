import Foundation
import Homeswift
import HomeswiftAI
import Logging

/// What a client token may do: `read` < `control` (device control) < `admin` (everything).
public enum Scope: String, Sendable, Codable, CaseIterable, Comparable {
    case read, control, admin

    private var rank: Int {
        switch self {
        case .read: 0
        case .control: 1
        case .admin: 2
        }
    }

    public static func < (a: Scope, b: Scope) -> Bool { a.rank < b.rank }
}

/// Who a session acts as: the token's name and scope, and what its scope allows that it still may not see: tools,
/// resources (URIs and URI templates) and prompts by name. A web UI user who is not an administrator signs an app
/// in with `HomeswiftCatalog.administratorOnly` hidden, as the UI hides the log and config.json from them.
public struct Principal: Sendable, Hashable {
    public var name: String
    public var scope: Scope
    public var hidden: Set<String>

    public init(name: String, scope: Scope, hidden: Set<String> = []) {
        self.name = name
        self.scope = scope
        self.hidden = hidden
    }

    /// Whether a tool, resource URI or template, or prompt of this name is out of its sight.
    public func hides(_ name: String) -> Bool { hidden.contains(name) }
}

/// The `mcp.http` part of the `HomeswiftAiKit` block: whether the HTTP MCP server runs, where, and
/// which tokens reach it. The keys are those of `homebridge-ai-kit`.
///
/// ```json
/// "mcp": { "http": { "enabled": true, "port": 8582, "token": "…",
///                    "clients": [{ "name": "Dashboard", "token": "…", "scope": "read" }] } }
/// ```
public struct MCPConfiguration: Sendable, Equatable {
    public struct Client: Sendable, Equatable {
        public var name: String?
        public var token: String
        public var scope: Scope

        public init(name: String? = nil, token: String, scope: Scope) {
            self.name = name
            self.token = token
            self.scope = scope
        }
    }

    public static let defaultPort = 8582
    public static let defaultHost = "127.0.0.1"
    public static let defaultMaxSessions = 32
    public static let defaultSessionIdleMinutes = 30

    public var enabled = false
    public var host = defaultHost
    public var port = defaultPort
    /// The main client token (`admin`, or `read` with `readOnly`). Secret.
    public var token: String?
    /// More client tokens, each with a scope.
    public var clients: [Client] = []
    /// Caps every token at read-only access.
    public var readOnly = false
    /// Browser origins allowed besides loopback and this server's own address (`*` for any).
    public var allowedOrigins: [String] = []
    /// Log every write tool call to a JSONL file.
    public var auditLog = true
    public var auditLogPath: String?
    /// Sessions at once; a new one ends the least recently used idle session.
    public var maxSessions = defaultMaxSessions
    /// A session idle this long ends.
    public var sessionIdleMinutes = defaultSessionIdleMinutes

    public init() {}

    /// Reads the `mcp.http` object of a `HomeswiftAiKit` block (or a whole block), then the environment's
    /// overrides (`applyEnvironment`). Unknown scopes and bad numbers throw; client rows without a token are skipped.
    public init(block: JSONValue) throws {
        try self.init(block: block, environment: ProcessInfo.processInfo.environment)
    }

    public init(block: JSONValue, environment: [String: String]) throws {
        try self.init(parsing: block)
        try applyEnvironment(environment)
    }

    private init(parsing block: JSONValue) throws {
        let http = block["mcp"]?["http"] ?? block["http"] ?? [:]
        func string(_ key: String) -> String? { http[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
        enabled = http["enabled"] == .bool(true)
        host = string("host") ?? Self.defaultHost
        if let port = http["port"], !port.isNull {
            guard let value = port.portValue else { throw MCPConfigurationError.invalid(key: "mcp.http.port", expected: "a port number") }
            self.port = value
        }
        token = string("token")
        readOnly = http["readOnly"] == .bool(true)
        auditLog = http["auditLog"] != .bool(false)
        auditLogPath = string("auditLogPath")
        for (key, keyPath) in [("maxSessions", \MCPConfiguration.maxSessions), ("sessionIdleMinutes", \MCPConfiguration.sessionIdleMinutes)] {
            guard let value = http[key], !value.isNull else { continue }
            guard let number = value.intValue, number >= 1 else { throw MCPConfigurationError.invalid(key: "mcp.http.\(key)", expected: "a whole number from 1") }
            self[keyPath: keyPath] = number
        }
        if let origins = http["allowedOrigins"] {
            if let list = origins.arrayValue {
                allowedOrigins = list.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty }
            } else if let text = origins.stringValue {
                allowedOrigins = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        for (index, row) in (http["clients"]?.arrayValue ?? []).enumerated() {
            guard let token = row["token"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty else { continue }
            let scopeName = row["scope"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "read"
            guard let scope = Scope(rawValue: scopeName) else {
                throw MCPConfigurationError.invalid(key: "mcp.http.clients[\(index)].scope", expected: "read, control or admin")
            }
            clients.append(Client(name: row["name"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty, token: token, scope: scope))
        }
    }

    public var hasTokens: Bool { token != nil || !clients.isEmpty }

    /// The environment names `homebridge-ai-kit` reads, each under a `HOMESWIFT_` name that wins over it.
    public static let environmentNames: [(homeswift: String, homebridge: String)] = [
        ("HOMESWIFT_MCP_MAX_SESSIONS", "HOMEBRIDGE_AI_MCP_MAX_SESSIONS"),
        ("HOMESWIFT_MCP_SESSION_IDLE_MINUTES", "HOMEBRIDGE_AI_MCP_SESSION_IDLE_MINUTES"),
        ("HOMESWIFT_READ_ONLY", "HOMEBRIDGE_READ_ONLY"),
        ("HOMESWIFT_MCP_TOKENS", "HOMEBRIDGE_AI_MCP_TOKENS"),
        ("HOMESWIFT_MCP_ALLOWED_ORIGINS", "HOMEBRIDGE_AI_MCP_ALLOWED_ORIGINS"),
        ("HOMESWIFT_MCP_AUDIT_LOG", "HOMEBRIDGE_AI_AUDIT_LOG"),
    ]

    /// Overrides from the environment, over config.json: the session cap and idle minutes, read-only
    /// (`1`/`true`/`yes`/`on` or `0`/`false`/`no`/`off`), more tokens as `scope:token` pairs separated by
    /// commas (`read:abc,control:def`; added to the block's clients), allowed origins separated by commas,
    /// and the audit log's path.
    public mutating func applyEnvironment(_ environment: [String: String]) throws {
        func value(_ index: Int) -> (name: String, text: String)? {
            let (own, upstream) = Self.environmentNames[index]
            for name in [own, upstream] {
                if let text = environment[name]?.trimmingCharacters(in: .whitespaces), !text.isEmpty { return (name, text) }
            }
            return nil
        }
        func positive(_ index: Int) throws -> Int? {
            guard let (name, text) = value(index) else { return nil }
            guard let number = Int(text), number >= 1 else { throw MCPConfigurationError.invalid(key: name, expected: "a whole number from 1") }
            return number
        }
        if let number = try positive(0) { maxSessions = number }
        if let number = try positive(1) { sessionIdleMinutes = number }
        if let (name, text) = value(2) {
            switch text.lowercased() {
            case "1", "true", "yes", "on": readOnly = true
            case "0", "false", "no", "off": readOnly = false
            default: throw MCPConfigurationError.invalid(key: name, expected: "true or false")
            }
        }
        if let (name, text) = value(3) {
            for (index, entry) in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }).enumerated() {
                guard let colon = entry.firstIndex(of: ":"), let scope = Scope(rawValue: String(entry[..<colon])), entry.index(after: colon) < entry.endIndex else {
                    throw MCPConfigurationError.invalid(key: "\(name) entry \(index + 1)", expected: "read:<token>, control:<token> or admin:<token>")
                }
                clients.append(Client(name: "\(scope.rawValue)-\(index + 1)", token: String(entry[entry.index(after: colon)...]), scope: scope))
            }
        }
        if let (_, text) = value(4) {
            allowedOrigins = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let (_, text) = value(5) {
            auditLog = true
            auditLogPath = text
        }
    }

    /// The audit log the block asks for (`auditLogPath`, else `homeswift-mcp-audit.jsonl` in the config
    /// directory), or nil with `auditLog: false`. The web UI's chat writes to the same one.
    public func makeAuditLog(configDirectory: URL, logger: Logger) -> AuditLog? {
        guard auditLog else { return nil }
        let url = auditLogPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? configDirectory.appendingPathComponent("homeswift-mcp-audit.jsonl")
        return AuditLog(url: url, logger: logger)
    }

    /// The principal a presented bearer token identifies, or nil. Every token is compared in constant
    /// time, and all of them are compared whatever matches, so timing says nothing about the tokens.
    public func principal(for presented: String) -> Principal? {
        var found: Principal?
        if let token, Secrets.constantTimeEqual(token.utf8, presented.utf8) {
            found = Principal(name: "default", scope: readOnly ? .read : .admin)
        }
        for client in clients {
            let matches = Secrets.constantTimeEqual(client.token.utf8, presented.utf8)
            if matches, found == nil {
                found = Principal(name: client.name ?? "client", scope: readOnly ? .read : client.scope)
            }
        }
        return found
    }

    /// A random token for a client: 32 bytes, URL-safe base64.
    public static func generateToken() -> String { Secrets.randomToken() }
}

public enum MCPConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(key: String, expected: String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftAiKit: \"\(key)\" must be \(expected)"
        }
    }
}

