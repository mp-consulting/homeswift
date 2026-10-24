import Foundation
import HomeswiftAI
import NIOConcurrencyHelpers

/// What the user is asked before a tool that changes something runs.
public struct ToolConfirmation: Sendable {
    public var tool: String
    /// "Change one platform block".
    public var title: String
    /// The arguments, secrets as handles.
    public var arguments: JSONValue
    /// What a dry run of the call answered, when the tool has one: what would change.
    public var preview: JSONValue?
}

/// The MCP server's tools for the web UI's chat: a session inside the process that acts as the signed-in user
/// and can ask them, so the chat goes through the same scopes, confirmations and audit log as any MCP client.
/// A tool's confirmation (MCP elicitation) becomes a call to `confirm`, with a dry run's answer to show.
public final class ChatToolbox: Sendable {
    let server: MCPServer
    public let session: MCPSession
    private let nextID = NIOLockedValueBox(1)

    /// `hidden`: what the user's scope allows that they still may not see (`HomeswiftCatalog.administratorOnly` for a
    /// user who is not an administrator); the server refuses it as for any client.
    public init(server: MCPServer, user: String, scope: Scope = .admin, hidden: Set<String> = []) async {
        self.server = server
        session = server.makeSession(principal: Principal(name: user, scope: scope, hidden: hidden))
        let initialize: JSONValue = [
            "protocolVersion": .string(MCPServer.protocolVersion), "capabilities": ["elicitation": [:]],
            "clientInfo": ["name": "web UI chat", "version": .string(server.options.version)],
        ]
        for await _ in server.handle(.request(id: 0, method: "initialize", params: initialize), session: session) {}
        for await _ in server.handle(.notification(method: "notifications/initialized", params: nil), session: session) {}
    }

    /// The session's vault: the conversation's secrets.
    public var vault: SecretVault { session.vault }

    public func close() {
        server.endSession(session)
    }

    /// The tools this user may call, for the Assistant. `confirm` decides each change; false leaves it undone.
    public func agentTools(confirm: @escaping @Sendable (ToolConfirmation) async -> Bool) -> [AgentTool] {
        server.tools.filter { $0.scope <= session.principal.scope && !session.principal.hides($0.name) }.map { tool in
            var schema = tool.inputSchema.objectValue ?? [:]
            // The page asks the user itself: the log's one-time code is for clients that cannot.
            if var properties = schema["properties"]?.objectValue {
                properties.removeValue(forKey: "confirmationCode")
                schema["properties"] = .object(properties)
            }
            let definition = ToolDefinition(name: tool.name, description: tool.description, inputSchema: .object(schema))
            return AgentTool(definition: definition, title: tool.title ?? tool.name, readOnly: tool.readOnly) { [self] arguments in
                await call(tool, arguments: arguments, confirm: confirm)
            }
        }
    }

    func call(_ tool: MCPTool, arguments: JSONValue, confirm: @escaping @Sendable (ToolConfirmation) async -> Bool) async -> AgentToolOutput {
        let declined = NIOLockedValueBox(false)
        // The server runs the dry run and sends what it would change with its question (MCPServer.callTool).
        var output = await send(tool, arguments: arguments) { [vault] params in
            let shown = ToolConfirmation(tool: tool.name, title: tool.title ?? tool.name, arguments: vault.conceal(arguments), preview: params["_meta"]?["homeswift/preview"])
            let allowed = await confirm(shown)
            declined.withLockedValue { $0 = !allowed }
            return allowed
        }
        output.declined = declined.withLockedValue { $0 }
        return output
    }

    /// One `tools/call` through the server; an elicitation it sends on the way (its params) is answered by `confirm`.
    private func send(_ tool: MCPTool, arguments: JSONValue, confirm: @escaping @Sendable (JSONValue) async -> Bool) async -> AgentToolOutput {
        let id = nextID.withLockedValue { id -> Int in
            defer { id += 1 }
            return id
        }
        let request = JSONRPCMessage.request(id: .number(Double(id)), method: "tools/call", params: ["name": .string(tool.name), "arguments": arguments])
        var output = AgentToolOutput(text: "The tool did not answer.", isError: true)
        for await message in server.handle(request, session: session) {
            switch message {
            case .request(let requestID, "elicitation/create", let params):
                let accepted = await confirm(params ?? .null)
                let answer: JSONValue = accepted ? ["action": "accept", "content": ["confirm": true]] : ["action": "decline"]
                for await _ in server.handle(.response(id: requestID, result: answer), session: session) {}
            case .response(_, let result):
                let answer = ToolResult(json: result)
                output = AgentToolOutput(text: answer.text, structured: answer.structured, isError: answer.isError)
            case .failure(_, let error):
                output = AgentToolOutput(text: error.message, isError: true)
            default:
                break
            }
        }
        return output
    }
}
