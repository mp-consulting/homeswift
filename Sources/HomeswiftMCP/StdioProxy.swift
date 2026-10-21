import Foundation
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// `homeswift mcp`: a stdio MCP server for clients that only speak stdio (Claude Desktop, Cursor), which
/// forwards every message to the bridge's HTTP MCP server and back. Each stdin message becomes a POST;
/// a reply streams to stdout as it arrives, so a server question (elicitation) reaches the client and the
/// client's answer, another stdin message, reaches the server while the first exchange still waits.
public final class StdioProxy: Sendable {
    public struct Options: Sendable {
        public var url: URL
        public var token: String
        public var logger = Logger(label: "homeswift.mcp")

        public init(url: URL, token: String) {
            self.url = url
            self.token = token
        }
    }

    public let options: Options
    let transport: any HTTPTransport
    private let sessionID = NIOLockedValueBox<String?>(nil)
    private let protocolVersion = NIOLockedValueBox<String?>(nil)
    var logger: Logger { options.logger }

    public init(options: Options, transport: any HTTPTransport = URLSessionTransport(timeout: 3600)) {
        self.options = options
        self.transport = transport
    }

    /// Lines from stdin (or another handle), read on a thread so a blocked read never holds a task.
    public static func lines(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread {
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = pending[pending.startIndex..<newline]
                        pending = Data(pending[pending.index(after: newline)...])
                        if !line.isEmpty { continuation.yield(Data(line)) }
                    }
                }
                if !pending.isEmpty { continuation.yield(pending) }
                continuation.finish()
            }
            thread.name = "homeswift.mcp.stdin"
            thread.start()
        }
    }

    /// Runs until the input ends, then lets the exchanges still in flight finish. Every line of input is
    /// one JSON-RPC message. `initialize` is forwarded before the next line is read, so the session exists
    /// for whatever follows; everything else runs concurrently.
    public func run(input: AsyncStream<Data>, output: @escaping @Sendable (Data) -> Void) async {
        let writer = Output(write: output)
        await withTaskGroup(of: Void.self) { group in
            for await line in input {
                let message = try? JSONRPCMessage.parse(data: line).first
                if case .request(_, "initialize", _)? = message {
                    await forward(line, message, to: writer)
                } else {
                    group.addTask { await self.forward(line, message, to: writer) }
                }
            }
        }
        await endSession()
    }

    private func headers(accept: String) -> [String: String] {
        var headers = ["Authorization": "Bearer \(options.token)", "Accept": accept]
        if let id = sessionID.withLockedValue({ $0 }) { headers["Mcp-Session-Id"] = id }
        if let version = protocolVersion.withLockedValue({ $0 }) { headers["MCP-Protocol-Version"] = version }
        return headers
    }

    /// `message` is the line parsed, once, by the caller: for the initialize handling and the error's id.
    private func forward(_ line: Data, _ message: JSONRPCMessage?, to writer: Output) async {
        var isInitialize = false
        if case .request(_, "initialize", _)? = message { isInitialize = true }
        do {
            let http = try await transport.stream(HTTPRequest(url: options.url, headers: headers(accept: "application/json, text/event-stream"), body: line))
            guard (200..<300).contains(http.status) else {
                var detail = Data()
                for try await chunk in http.body where detail.count < 2000 { detail.append(chunk) }
                throw ProxyError.http(http.status, String(decoding: detail, as: UTF8.self))
            }
            if isInitialize, let id = http.headers["mcp-session-id"] {
                sessionID.withLockedValue { $0 = id }
            }
            let contentType = http.headers["content-type"] ?? ""
            if contentType.contains("text/event-stream") {
                for try await event in SSE.events(http.body) {
                    if isInitialize { noteProtocolVersion(event.data) }
                    await writer.write(Data(event.data.utf8))
                }
            } else if http.status != 202 {
                var body = Data()
                for try await chunk in http.body { body.append(chunk) }
                if !body.isEmpty {
                    if isInitialize { noteProtocolVersion(String(decoding: body, as: UTF8.self)) }
                    await writer.write(body)
                }
            }
            if isInitialize { startStandingStream(writer) }
        } catch {
            logger.error("Forwarding to \(options.url) failed: \(error)")
            if let id = message?.id, message?.isRequest == true {
                let failure = JSONRPCMessage.failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: "homeswift mcp: \(error)"))
                await writer.write(failure.json.encoded())
            }
        }
    }

    private func noteProtocolVersion(_ text: String) {
        if let json = try? JSONValue(string: text), let version = json["result"]?["protocolVersion"]?.stringValue {
            protocolVersion.withLockedValue { $0 = version }
        }
    }

    /// The server's standing stream (GET): notifications and requests the server sends on its own. Reopened
    /// while the session lasts.
    private func startStandingStream(_ writer: Output) {
        Task {
            var attempt = 0
            while !Task.isCancelled, sessionID.withLockedValue({ $0 }) != nil {
                do {
                    let http = try await transport.stream(HTTPRequest(method: "GET", url: options.url, headers: headers(accept: "text/event-stream")))
                    guard http.status == 200 else {
                        if http.status == 404 || http.status == 401 || http.status == 403 { return }
                        throw ProxyError.http(http.status, "")
                    }
                    attempt = 0
                    for try await event in SSE.events(http.body) {
                        await writer.write(Data(event.data.utf8))
                    }
                } catch {
                    logger.debug("Standing stream ended: \(error)")
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(30, 1 << min(attempt, 5))))
            }
        }
    }

    private func endSession() async {
        guard let id = sessionID.withLockedValue({ $0 }) else { return }
        _ = try? await transport.post(HTTPRequest(method: "DELETE", url: options.url, headers: ["Authorization": "Bearer \(options.token)", "Mcp-Session-Id": id]))
    }

    /// Serializes writes so concurrent exchanges never interleave lines.
    actor Output {
        let sink: @Sendable (Data) -> Void

        init(write: @escaping @Sendable (Data) -> Void) {
            sink = write
        }

        func write(_ data: Data) {
            sink(data + Data("\n".utf8))
        }
    }

    enum ProxyError: Error, CustomStringConvertible {
        case http(Int, String)

        var description: String {
            switch self {
            case .http(let status, let body): "HTTP \(status)\(body.isEmpty ? "" : ": \(Redaction.redactText(body))")"
            }
        }
    }
}

/// Ready-to-paste client configurations for the bridge's MCP server.
public enum MCPClientSnippets {
    public static func all(command: String, url: String, token: String?) -> String {
        let tokenValue = token ?? "<your token>"
        return """
            Claude Desktop (claude_desktop_config.json) and Cursor (~/.cursor/mcp.json), over stdio:

            {
              "mcpServers": {
                "homeswift": {
                  "command": "\(command)",
                  "args": ["mcp"],
                  "env": { "HOMESWIFT_MCP_TOKEN": "\(tokenValue)", "HOMESWIFT_MCP_URL": "\(url)" }
                }
              }
            }

            Claude Code:

            claude mcp add homeswift --env HOMESWIFT_MCP_TOKEN=\(tokenValue) --env HOMESWIFT_MCP_URL=\(url) -- \(command) mcp

            Clients that speak Streamable HTTP themselves (Claude Code shown):

            claude mcp add --transport http homeswift \(url) --header "Authorization: Bearer \(tokenValue)"
            """
    }
}
