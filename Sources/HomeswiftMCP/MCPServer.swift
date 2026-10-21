import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

// The Model Context Protocol, server side: sessions, the request methods, and what the server offers.

public struct ClientInfo: Sendable, Equatable {
    public var name: String
    public var version: String
}

/// One client's session: who it is, what it declared at `initialize`, what it subscribed to, and the
/// requests the server sent it that still wait for an answer.
public final class MCPSession: Sendable, Identifiable {
    public let id: String
    public let principal: Principal

    struct State {
        var initialized = false
        var protocolVersion: String?
        var clientCapabilities: JSONValue = [:]
        var clientInfo: ClientInfo?
        /// Log lines at this level and above are forwarded as `notifications/message` (`logging/setLevel` changes it).
        var logLevel: Logger.Level = .warning
        var subscriptions: Set<String> = []
        var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
        var nextRequestID = 1
        var lastActivity = Date()
        var hasStandingStream = false
    }

    let state: NIOLockedValueBox<State>
    /// Messages the server sends on its own, outside any request: resource updates, log messages.
    public let outbound: AsyncStream<JSONRPCMessage>
    private let outboundContinuation: AsyncStream<JSONRPCMessage>.Continuation

    init(principal: Principal) {
        id = UUID().uuidString
        self.principal = principal
        state = NIOLockedValueBox(State())
        (outbound, outboundContinuation) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public var isInitialized: Bool { state.withLockedValue { $0.initialized } }
    public var protocolVersion: String? { state.withLockedValue { $0.protocolVersion } }
    public var clientInfo: ClientInfo? { state.withLockedValue { $0.clientInfo } }
    public var lastActivity: Date { state.withLockedValue { $0.lastActivity } }
    public var logLevel: Logger.Level { state.withLockedValue { $0.logLevel } }
    public var subscriptions: Set<String> { state.withLockedValue { $0.subscriptions } }
    /// Whether the client can show the user a question (MCP elicitation).
    public var supportsElicitation: Bool { state.withLockedValue { $0.clientCapabilities["elicitation"] != nil } }

    func touch() { state.withLockedValue { $0.lastActivity = Date() } }

    /// Whether a transport stream for server-initiated messages is open (`GET` over HTTP).
    public var hasStandingStream: Bool { state.withLockedValue { $0.hasStandingStream } }

    public func setStandingStream(_ attached: Bool) {
        state.withLockedValue { $0.hasStandingStream = attached }
    }

    /// Queues a server-initiated message for the client's standing stream.
    public func send(_ message: JSONRPCMessage) {
        outboundContinuation.yield(message)
    }

    /// Sends a request to the client through `emit` and waits for the answer, which arrives as a response
    /// message the transport hands to `MCPServer.handle`.
    func request(_ method: String, params: JSONValue, timeout: Duration = .seconds(600), emit: @escaping @Sendable (JSONRPCMessage) -> Void) async throws -> JSONValue {
        let id = state.withLockedValue { state -> Int in
            defer { state.nextRequestID += 1 }
            return state.nextRequestID
        }
        let key = idKey(.number(Double(id)))
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.state.withLockedValue { $0.pending[key] = continuation }
                        emit(.request(id: .number(Double(id)), method: method, params: params))
                    }
                } onCancel: {
                    self.state.withLockedValue { $0.pending.removeValue(forKey: key) }?.resume(throwing: CancellationError())
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPError.timeout(method)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Resolves a client's response to a server request. Returns false for an id nobody waits for.
    @discardableResult
    func deliver(id: JSONValue, result: JSONValue?, error: JSONRPCError?) -> Bool {
        guard let continuation = state.withLockedValue({ $0.pending.removeValue(forKey: idKey(id)) }) else { return false }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: result ?? .null)
        }
        return true
    }

    func close() {
        let pending = state.withLockedValue { state -> [CheckedContinuation<JSONValue, any Error>] in
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: MCPError.sessionClosed) }
        outboundContinuation.finish()
    }
}

public enum MCPError: Error, CustomStringConvertible, Sendable {
    case timeout(String)
    case sessionClosed
    case notConfirmed

    public var description: String {
        switch self {
        case .timeout(let method): "the client did not answer \(method) in time"
        case .sessionClosed: "the session was closed"
        case .notConfirmed: "the user did not confirm"
        }
    }
}

/// What a tool handler gets: the session, the arguments, and a way to ask the user.
public struct ToolCall: Sendable {
    public let session: MCPSession
    public let tool: MCPTool
    public let arguments: JSONValue
    let emit: @Sendable (JSONRPCMessage) -> Void
    let elicitationEnabled: Bool
    /// The exchange cannot carry a server request (JSON-only HTTP); the standing stream may.
    let serverRequests: Bool

    /// A dry run of a tool that supports them: previews, changes nothing, needs no confirmation.
    public var isDryRun: Bool { tool.supportsDryRun && arguments["dryRun"] == .bool(true) }

    /// Whether the user can be asked through MCP elicitation on this exchange or the standing stream.
    public var canAsk: Bool {
        elicitationEnabled && session.supportsElicitation && (serverRequests || session.hasStandingStream)
    }

    /// Asks the user to confirm through MCP elicitation. Check `canAsk` first.
    public func confirm(_ message: String) async throws -> Bool {
        let session = session
        let send: @Sendable (JSONRPCMessage) -> Void
        if serverRequests {
            send = emit
        } else {
            send = { message in session.send(message) }
        }
        let params: JSONValue = [
            "message": .string(message),
            "requestedSchema": [
                "type": "object",
                "properties": ["confirm": ["type": "boolean", "title": "Confirm", "description": "Yes to run it"]],
                "required": ["confirm"],
            ],
        ]
        let answer = try await session.request("elicitation/create", params: params, emit: send)
        let accepted = answer["action"] == "accept"
        let confirmed = answer["content"]?["confirm"] == JSONValue.bool(true)
        return accepted && confirmed
    }

    /// A string argument, or an invalid-params error naming it.
    public func string(_ name: String) throws -> String {
        guard let value = arguments[name]?.stringValue, !value.isEmpty else { throw JSONRPCError.invalidParams("\(name) is required") }
        return value
    }

    public func optionalString(_ name: String) -> String? { arguments[name]?.stringValue?.nonEmpty }
    public func int(_ name: String, default value: Int) -> Int { arguments[name]?.intValue ?? value }
    public func bool(_ name: String) -> Bool { arguments[name] == .bool(true) }
}

public struct ToolResult: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError = false

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult { ToolResult(text: text) }
    /// An error for the model, secrets masked whatever the text came from.
    public static func error(_ text: String) -> ToolResult { ToolResult(text: Redaction.redactText(text), isError: true) }
    /// A JSON value as both the text and the structured content.
    public static func json(_ value: JSONValue) -> ToolResult { ToolResult(text: value.text(pretty: true), structured: value) }

    var json: JSONValue {
        var object: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]]]
        if let structured { object["structuredContent"] = structured }
        if isError { object["isError"] = true }
        return .object(object)
    }
}

public struct MCPTool: Sendable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue
    /// The lowest scope that may call it.
    public var scope: Scope
    public var readOnly: Bool
    /// Asks the user before running: through elicitation, or with a one-time code from the bridge's log
    /// when the client cannot ask; logged with `notConfirmed` when declined.
    public var destructive: Bool
    /// Honours `dryRun: true`: previews, changes nothing, and then needs no confirmation.
    public var supportsDryRun: Bool
    public var idempotent: Bool
    public var handler: @Sendable (ToolCall) async throws -> ToolResult

    /// The schema gets `dryRun` and `confirmationCode` where they apply, and refuses unknown arguments.
    public init(
        name: String, title: String? = nil, description: String, inputSchema: JSONValue = ["type": "object", "properties": [:]],
        scope: Scope, readOnly: Bool? = nil, destructive: Bool = false, supportsDryRun: Bool = false, idempotent: Bool = false,
        handler: @escaping @Sendable (ToolCall) async throws -> ToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        var schema = inputSchema.objectValue ?? ["type": "object"]
        var properties = schema["properties"]?.objectValue ?? [:]
        if supportsDryRun { properties["dryRun"] = ["type": "boolean", "description": "Preview without changing anything"] }
        if destructive {
            properties["confirmationCode"] = ["type": "string", "description": "The one-time code from the homeswift log, when the client cannot ask the user"]
        }
        schema["properties"] = .object(properties)
        if schema["additionalProperties"] == nil { schema["additionalProperties"] = false }
        self.inputSchema = .object(schema)
        self.scope = scope
        self.readOnly = readOnly ?? (scope == .read)
        self.destructive = destructive
        self.supportsDryRun = supportsDryRun
        self.idempotent = idempotent
        self.handler = handler
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title ?? name), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent), "openWorldHint": false,
            ],
        ]
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

public struct MCPResource: Sendable {
    public var uri: String
    public var name: String
    public var description: String
    public var mimeType: String
    public var read: @Sendable () async throws -> String

    public init(uri: String, name: String, description: String, mimeType: String = "application/json", read: @escaping @Sendable () async throws -> String) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
    }

    var json: JSONValue { ["uri": .string(uri), "name": .string(name), "description": .string(description), "mimeType": .string(mimeType)] }
}

public struct MCPResourceTemplate: Sendable {
    public var uriTemplate: String
    public var name: String
    public var description: String
    public var mimeType: String
    /// The content for the variables of a matching URI, or nil when there is no such resource.
    public var read: @Sendable ([String: String]) async throws -> String?
    /// Completions for a variable: `(variable, typed so far)` to candidates.
    public var complete: @Sendable (String, String) async -> [String]

    public init(
        uriTemplate: String, name: String, description: String, mimeType: String = "application/json",
        read: @escaping @Sendable ([String: String]) async throws -> String?,
        complete: @escaping @Sendable (String, String) async -> [String] = { _, _ in [] }
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
        self.complete = complete
    }

    var json: JSONValue { ["uriTemplate": .string(uriTemplate), "name": .string(name), "description": .string(description), "mimeType": .string(mimeType)] }

    /// The variables of `uri` when it matches the template (`{name}` segments match one path segment).
    func match(_ uri: String) -> [String: String]? {
        let pattern = uriTemplate.split(separator: "/", omittingEmptySubsequences: false)
        let parts = uri.split(separator: "/", omittingEmptySubsequences: false)
        guard pattern.count == parts.count else { return nil }
        var variables: [String: String] = [:]
        for (expected, actual) in zip(pattern, parts) {
            if expected.hasPrefix("{"), expected.hasSuffix("}") {
                let name = String(expected.dropFirst().dropLast())
                guard !actual.isEmpty, let value = actual.removingPercentEncoding else { return nil }
                variables[name] = value
            } else if expected != actual {
                return nil
            }
        }
        return variables
    }
}

public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]
    public var render: @Sendable ([String: String]) throws -> String

    public init(name: String, title: String, description: String, arguments: [Argument] = [], render: @escaping @Sendable ([String: String]) throws -> String) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.render = render
    }

    var json: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] }),
        ]
    }
}

/// The MCP server: holds what it offers and answers one message at a time per session. Transports own
/// the sessions' lifetimes and deliver the messages.
public final class MCPServer: Sendable {
    public struct Options: Sendable {
        public var name = "homeswift"
        public var version: String
        public var instructions: String?
        /// Ask the user through elicitation when the client supports it (`HOMESWIFT_ELICITATION=false` turns it off).
        public var elicitation = true
        public var logger = Logger(label: "homeswift.mcp")

        public init(version: String, instructions: String? = nil) {
            self.version = version
            self.instructions = instructions
        }
    }

    public static let protocolVersion = "2025-06-18"
    public static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let options: Options
    public let tools: [MCPTool]
    public let resources: [MCPResource]
    public let templates: [MCPResourceTemplate]
    public let prompts: [MCPPrompt]
    public let audit: AuditLog?
    let confirmationCodes = ConfirmationCodes()
    private let sessions = NIOLockedValueBox<[String: MCPSession]>([:])
    var logger: Logger { options.logger }

    public init(options: Options, tools: [MCPTool], resources: [MCPResource] = [], templates: [MCPResourceTemplate] = [], prompts: [MCPPrompt] = [], audit: AuditLog? = nil) {
        self.options = options
        self.tools = tools
        self.resources = resources
        self.templates = templates
        self.prompts = prompts
        self.audit = audit
    }

    // MARK: Sessions

    public func makeSession(principal: Principal) -> MCPSession {
        let session = MCPSession(principal: principal)
        sessions.withLockedValue { $0[session.id] = session }
        return session
    }

    public func session(id: String) -> MCPSession? {
        sessions.withLockedValue { $0[id] }
    }

    public var activeSessions: [MCPSession] { sessions.withLockedValue { Array($0.values) } }

    public func endSession(_ session: MCPSession) {
        _ = sessions.withLockedValue { $0.removeValue(forKey: session.id) }
        session.close()
    }

    /// Ends sessions idle for longer than `limit`.
    public func expireSessions(idleFor limit: Duration) {
        let cutoff = Date().addingTimeInterval(-(Double(limit.components.seconds)))
        for session in activeSessions where session.lastActivity < cutoff {
            logger.debug("Session expired", metadata: ["session": "\(session.id)"])
            endSession(session)
        }
    }

    // MARK: Server-initiated messages

    /// Tells every session subscribed to `uri` that it changed.
    public func notifyResourceUpdated(_ uri: String) {
        for session in activeSessions where session.subscriptions.contains(uri) {
            session.send(.notification(method: "notifications/resources/updated", params: ["uri": .string(uri)]))
        }
    }

    /// A log line for the sessions whose level allows it; the text is only built when one wants it.
    public func log(level: Logger.Level, logger name: String, message: @autoclosure () -> String) {
        let targets = activeSessions.filter { $0.isInitialized && level >= $0.logLevel }
        guard !targets.isEmpty else { return }
        let text = message()
        for session in targets {
            session.send(.notification(method: "notifications/message", params: [
                "level": .string(Self.mcpLevel(level)), "logger": .string(name), "data": .string(text),
            ]))
        }
    }

    static func mcpLevel(_ level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .warning: "warning"
        case .error: "error"
        case .critical: "critical"
        }
    }

    static func loggerLevel(_ name: String) -> Logger.Level? {
        switch name {
        case "debug": .debug
        case "info": .info
        case "notice": .notice
        case "warning": .warning
        case "error": .error
        case "critical", "alert", "emergency": .critical
        default: nil
        }
    }

    // MARK: Handling

    /// Handles one message. A request yields the messages the server sends while handling it (an
    /// elicitation request, say) and then the response; a notification or a response yields nothing.
    /// `serverRequests: false` means the transport cannot deliver a server request on this exchange; a
    /// confirmation then goes through the session's standing stream, or a one-time code.
    public func handle(_ message: JSONRPCMessage, session: MCPSession, serverRequests: Bool = true) -> AsyncStream<JSONRPCMessage> {
        session.touch()
        return AsyncStream { continuation in
            switch message {
            case .request(let id, let method, let params):
                let task = Task {
                    let response = await self.respond(id: id, method: method, params: params ?? [:], session: session, serverRequests: serverRequests) { continuation.yield($0) }
                    continuation.yield(response)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            case .notification(let method, let params):
                self.notified(method: method, params: params, session: session)
                continuation.finish()
            case .response(let id, let result):
                if !session.deliver(id: id, result: result, error: nil) {
                    self.logger.debug("Response for an unknown request", metadata: ["id": "\(id)"])
                }
                continuation.finish()
            case .failure(let id, let error):
                session.deliver(id: id, result: nil, error: error)
                continuation.finish()
            }
        }
    }

    private func notified(method: String, params: JSONValue?, session: MCPSession) {
        switch method {
        case "notifications/initialized":
            session.state.withLockedValue { $0.initialized = true }
        case "notifications/cancelled", "notifications/progress", "notifications/roots/list_changed":
            break
        default:
            logger.debug("Ignoring notification", metadata: ["method": "\(method)"])
        }
    }

    private func respond(id: JSONValue, method: String, params: JSONValue, session: MCPSession, serverRequests: Bool, emit: @escaping @Sendable (JSONRPCMessage) -> Void) async -> JSONRPCMessage {
        do {
            let result = try await dispatch(method: method, params: params, session: session, serverRequests: serverRequests, emit: emit)
            return .response(id: id, result: result)
        } catch let error as JSONRPCError {
            return .failure(id: id, error: error)
        } catch is CancellationError {
            return .failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: "cancelled"))
        } catch {
            logger.error("Request failed", metadata: ["method": "\(method)", "error": "\(error)"])
            return .failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: Redaction.redactText("\(error)")))
        }
    }

    private func dispatch(method: String, params: JSONValue, session: MCPSession, serverRequests: Bool, emit: @escaping @Sendable (JSONRPCMessage) -> Void) async throws -> JSONValue {
        switch method {
        case "initialize":
            return initialize(params, session: session)
        case "ping":
            return [:]
        default:
            break
        }
        guard session.protocolVersion != nil else {
            throw JSONRPCError.invalidRequest("the session is not initialized; send initialize first")
        }
        switch method {
        case "tools/list":
            return ["tools": .array(tools.filter { $0.scope <= session.principal.scope }.map(\.json))]
        case "tools/call":
            return try await callTool(params, session: session, serverRequests: serverRequests, emit: emit)
        case "resources/list":
            return ["resources": .array(resources.map(\.json))]
        case "resources/templates/list":
            return ["resourceTemplates": .array(templates.map(\.json))]
        case "resources/read":
            return try await readResource(params)
        case "resources/subscribe":
            let uri = try requiredString(params, "uri")
            _ = session.state.withLockedValue { $0.subscriptions.insert(uri) }
            return [:]
        case "resources/unsubscribe":
            let uri = try requiredString(params, "uri")
            _ = session.state.withLockedValue { $0.subscriptions.remove(uri) }
            return [:]
        case "prompts/list":
            return ["prompts": .array(prompts.map(\.json))]
        case "prompts/get":
            return try getPrompt(params)
        case "completion/complete":
            return try await complete(params)
        case "logging/setLevel":
            let name = try requiredString(params, "level")
            guard let level = Self.loggerLevel(name) else { throw JSONRPCError.invalidParams("unknown level \(name)") }
            session.state.withLockedValue { $0.logLevel = level }
            return [:]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    private func requiredString(_ params: JSONValue, _ name: String) throws -> String {
        guard let value = params[name]?.stringValue, !value.isEmpty else { throw JSONRPCError.invalidParams("\(name) is required") }
        return value
    }

    private func initialize(_ params: JSONValue, session: MCPSession) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.protocolVersion
        session.state.withLockedValue { state in
            state.protocolVersion = version
            state.clientCapabilities = params["capabilities"] ?? [:]
            if let info = params["clientInfo"] {
                state.clientInfo = ClientInfo(name: info["name"]?.stringValue ?? "?", version: info["version"]?.stringValue ?? "?")
            }
        }
        logger.info("MCP client connected", metadata: [
            "client": "\(session.clientInfo.map { "\($0.name) \($0.version)" } ?? "unknown")", "scope": "\(session.principal.scope.rawValue)",
            "protocol": "\(version)", "elicitation": "\(session.supportsElicitation)",
        ])
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": true, "listChanged": false],
                "prompts": ["listChanged": false],
                "logging": [:],
                "completions": [:],
            ],
            "serverInfo": ["name": .string(options.name), "version": .string(options.version)],
        ]
        if let instructions = options.instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    private func callTool(_ params: JSONValue, session: MCPSession, serverRequests: Bool, emit: @escaping @Sendable (JSONRPCMessage) -> Void) async throws -> JSONValue {
        let name = try requiredString(params, "name")
        guard let tool = tools.first(where: { $0.name == name }) else { throw JSONRPCError.invalidParams("unknown tool \(name)") }
        let arguments = params["arguments"] ?? [:]
        guard arguments.objectValue != nil else { throw JSONRPCError.invalidParams("arguments must be an object") }
        guard tool.scope <= session.principal.scope else {
            return ToolResult.error("This token's scope (\(session.principal.scope.rawValue)) does not allow \(name), which needs \(tool.scope.rawValue).").json
        }
        let errors = JSONSchema.validate(arguments, against: tool.inputSchema)
        if !errors.isEmpty {
            return ToolResult.error("Invalid arguments: \(errors.joined(separator: "; "))").json
        }
        let call = ToolCall(session: session, tool: tool, arguments: arguments, emit: emit, elicitationEnabled: options.elicitation, serverRequests: serverRequests)
        func audit(ok: Bool, error: String? = nil, notConfirmed: Bool = false) {
            guard tool.scope > .read || tool.destructive else { return }
            self.audit?.record(AuditLog.Entry(
                tool: name, arguments: arguments, ok: ok, error: error, session: session.id, client: session.clientInfo?.name ?? "unknown",
                principal: session.principal.name, scope: session.principal.scope, dryRun: call.isDryRun, notConfirmed: notConfirmed))
        }
        if tool.destructive, !call.isDryRun {
            var bare = arguments.objectValue ?? [:]
            let presentedCode = bare.removeValue(forKey: "confirmationCode")?.stringValue
            let summary = Redaction.redactSecrets(.object(bare)).text()
            if let presentedCode {
                guard confirmationCodes.redeem(presentedCode, tool: name, arguments: .object(bare)) else {
                    logger.warning("A wrong, expired or mismatched confirmation code was presented for \(name) \(summary)")
                    audit(ok: false, notConfirmed: true)
                    return ToolResult.error("Not run: the confirmation code is wrong, expired or for other arguments.").json
                }
            } else if call.canAsk {
                let confirmed: Bool
                do {
                    confirmed = try await call.confirm("Allow \(name)? Arguments: \(summary)")
                } catch {
                    audit(ok: false, error: "\(error)", notConfirmed: true)
                    return ToolResult.error("Not run: \(error)").json
                }
                guard confirmed else {
                    audit(ok: false, notConfirmed: true)
                    return ToolResult.error("Not run: the user did not confirm.").json
                }
            } else {
                // The client cannot ask: the user reads a code in the bridge's output and passes it on. The MCP
                // log tools and notifications hide it (HomeswiftCatalog.safe), so the client cannot read it back.
                switch confirmationCodes.issue(tool: name, arguments: .object(bare)) {
                case .code(let code):
                    logger.warning("Confirmation needed for \(name) \(summary): tell the assistant the confirmation code \(code) to allow it (valid 5 minutes, once)")
                    audit(ok: false, notConfirmed: true)
                    return ToolResult.error(
                        "Not run: this changes something that cannot be undone and this client cannot ask the user. "
                            + "A one-time confirmation code was written to the homeswift log (the terminal and the web UI; not readable through MCP); "
                            + "ask the user for it and call again with \"confirmationCode\"."
                    ).json
                case .locked(let until):
                    let minutes = max(1, Int(until.timeIntervalSinceNow / 60) + 1)
                    audit(ok: false, notConfirmed: true)
                    return ToolResult.error("Not run: too many wrong confirmation codes for this call; it can be tried again in \(minutes) minute(s).").json
                }
            }
        }
        do {
            let result = try await tool.handler(call)
            audit(ok: !result.isError, error: result.isError ? result.text : nil)
            return result.json
        } catch let error as JSONRPCError {
            audit(ok: false, error: error.message)
            throw error
        } catch {
            audit(ok: false, error: "\(error)")
            return ToolResult.error("\(error)").json
        }
    }

    private func readResource(_ params: JSONValue) async throws -> JSONValue {
        let uri = try requiredString(params, "uri")
        if let resource = resources.first(where: { $0.uri == uri }) {
            return ["contents": [["uri": .string(uri), "mimeType": .string(resource.mimeType), "text": .string(try await resource.read())]]]
        }
        for template in templates {
            if let variables = template.match(uri), let text = try await template.read(variables) {
                return ["contents": [["uri": .string(uri), "mimeType": .string(template.mimeType), "text": .string(text)]]]
            }
        }
        throw JSONRPCError(code: -32002, message: "Resource not found: \(uri)")
    }

    private func getPrompt(_ params: JSONValue) throws -> JSONValue {
        let name = try requiredString(params, "name")
        guard let prompt = prompts.first(where: { $0.name == name }) else { throw JSONRPCError.invalidParams("unknown prompt \(name)") }
        let arguments = (params["arguments"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        for argument in prompt.arguments where argument.required && arguments[argument.name]?.nonEmpty == nil {
            throw JSONRPCError.invalidParams("\(argument.name) is required")
        }
        let text = try prompt.render(arguments)
        return ["description": .string(prompt.description), "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
    }

    private func complete(_ params: JSONValue) async throws -> JSONValue {
        let argument = params["argument"]
        let name = argument?["name"]?.stringValue ?? ""
        let typed = argument?["value"]?.stringValue ?? ""
        var values: [String] = []
        if params["ref"]?["type"] == "ref/resource", let uri = params["ref"]?["uri"]?.stringValue,
            let template = templates.first(where: { $0.uriTemplate == uri })
        {
            values = await template.complete(name, typed)
        }
        let limited = Array(values.prefix(100))
        return ["completion": ["values": .array(limited.map(JSONValue.string)), "total": .number(Double(values.count)), "hasMore": .bool(values.count > limited.count)]]
    }
}

/// One-time codes for destructive calls from clients that cannot ask the user: the bridge logs the code,
/// the user reads it, the client repeats it. A code is bound to one tool call's arguments, lasts five
/// minutes and works once; three wrong guesses lock that call until the code expires, and ten wrong guesses
/// in five minutes, over any calls, lock every call until they age out (varying the arguments buys nothing).
final class ConfirmationCodes: Sendable {
    struct Entry {
        var code: String
        var expires: Date
        var wrongGuesses = 0
        var isLocked: Bool { wrongGuesses >= ConfirmationCodes.maxWrongGuesses }
    }

    enum Issued: Equatable {
        case code(String)
        /// Too many wrong guesses: nothing until the entry expires.
        case locked(until: Date)
    }

    struct State {
        var entries: [String: Entry] = [:]
        /// When each wrong guess happened, over every call, within the last `lifetime`.
        var wrongGuesses: [Date] = []

        mutating func prune() {
            let now = Date()
            entries = entries.filter { $0.value.expires > now }
            wrongGuesses.removeAll { now.timeIntervalSince($0) > ConfirmationCodes.lifetime }
        }

        /// The moment the overall lock lifts, when there is one.
        var lockedUntil: Date? {
            guard wrongGuesses.count >= ConfirmationCodes.maxWrongGuessesOverall, let oldest = wrongGuesses.first else { return nil }
            return oldest.addingTimeInterval(ConfirmationCodes.lifetime)
        }
    }

    private let state = NIOLockedValueBox(State())
    static let lifetime: TimeInterval = 300
    static let maxWrongGuesses = 3
    static let maxWrongGuessesOverall = 10

    static func key(tool: String, arguments: JSONValue) -> String { "\(tool)\n\(arguments.text())" }

    /// The code for this call, issuing a new one when there is none or it expired.
    func issue(tool: String, arguments: JSONValue) -> Issued {
        let key = Self.key(tool: tool, arguments: arguments)
        return state.withLockedValue { state in
            state.prune()
            if let until = state.lockedUntil { return .locked(until: until) }
            if let existing = state.entries[key] { return existing.isLocked ? .locked(until: existing.expires) : .code(existing.code) }
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            state.entries[key] = Entry(code: code, expires: Date().addingTimeInterval(Self.lifetime))
            return .code(code)
        }
    }

    /// Consumes the code when it matches this call. Compared in constant time; a wrong code counts towards both locks.
    func redeem(_ code: String, tool: String, arguments: JSONValue) -> Bool {
        let key = Self.key(tool: tool, arguments: arguments)
        return state.withLockedValue { state in
            state.prune()
            guard state.lockedUntil == nil, var entry = state.entries[key] else { return false }
            guard !entry.isLocked, Secrets.constantTimeEqual(entry.code.utf8, code.utf8) else {
                entry.wrongGuesses += 1
                state.entries[key] = entry
                state.wrongGuesses.append(Date())
                return false
            }
            state.entries.removeValue(forKey: key)
            return true
        }
    }

    /// For tests.
    func current(tool: String, arguments: JSONValue) -> String? {
        state.withLockedValue { $0.entries[Self.key(tool: tool, arguments: arguments)]?.code }
    }
}
