import Foundation
import Homeswift
import HomeswiftAI

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

/// Who a session acts as: the token's name and scope.
public struct Principal: Sendable, Hashable {
    public var name: String
    public var scope: Scope

    public init(name: String, scope: Scope) {
        self.name = name
        self.scope = scope
    }
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

    public init() {}

    /// Reads the `mcp.http` object of a `HomeswiftAiKit` block (or a whole block). Unknown scopes and bad
    /// numbers throw; client rows without a token are skipped.
    public init(block: JSONValue) throws {
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

