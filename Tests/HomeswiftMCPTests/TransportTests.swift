import Foundation
import HomeswiftAI
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import HomeswiftMCP

/// A Streamable HTTP client for the tests, on URLSession.
struct HTTPClientForTests {
    let url: URL
    var token: String?
    var sessionID: String?
    var origin: String?

    func send(_ method: String = "POST", body: String? = nil, accept: String = "application/json, text/event-stream") async throws -> (status: Int, headers: [String: String], body: String) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
        return (http.statusCode, headers, String(decoding: data, as: UTF8.self))
    }

    /// The JSON-RPC messages in a reply, whether JSON or SSE.
    static func messages(in body: String) -> [JSONValue] {
        if body.contains("data:") {
            return body.split(separator: "\n").filter { $0.hasPrefix("data:") }.compactMap { try? JSONValue(string: String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        guard let value = try? JSONValue(string: body) else { return [] }
        return value.arrayValue ?? [value]
    }
}

func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> String {
    JSONRPCMessage.request(id: .number(Double(id)), method: method, params: params).json.text()
}

@Suite(.timeLimit(.minutes(1)))
struct TransportTests {
    @Test func authenticatesAndRunsSessions() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        var configuration = MCPConfiguration()
        configuration.token = "admin-token"
        configuration.clients = [.init(name: "viewer", token: "viewer-token", scope: .read)]
        configuration.allowedOrigins = ["https://dashboard.example"]
        var options = MCPHTTPServer.Options(host: "127.0.0.1", port: 0)
        options.logger = testLogger
        options.allowedOrigins = configuration.allowedOrigins
        let transport = MCPHTTPServer(server: environment.server, configuration: configuration, options: options)
        try await transport.start()
        defer { Task { await transport.stop(); await environment.stop() } }
        let url = URL(string: "http://127.0.0.1:\(try #require(transport.port))/mcp")!

        // No token, bad token, bad origin.
        var client = HTTPClientForTests(url: url)
        let anonymous = try await client.send(body: request(1, "initialize"))
        #expect(anonymous.status == 401)
        #expect(anonymous.headers["www-authenticate"] == "Bearer")
        client.token = "wrong"
        #expect(try await client.send(body: request(1, "initialize")).status == 401)
        client.token = "admin-token"
        client.origin = "https://evil.example"
        #expect(try await client.send(body: request(1, "initialize")).status == 403)
        client.origin = "https://dashboard.example"
        #expect(try await client.send(body: request(1, "ping")).status == 400)
        client.origin = nil
        #expect(try await client.send(body: "{not json").status == 400)
        #expect(try await client.send(body: request(1, "ping")).status == 400)

        // Initialize: the session id comes back in a header; a JSON-only client gets JSON.
        let initialized = try await client.send(body: request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]), accept: "application/json")
        #expect(initialized.status == 200)
        #expect(initialized.headers["content-type"]?.hasPrefix("application/json") == true)
        let sessionID = try #require(initialized.headers["mcp-session-id"])
        #expect(HTTPClientForTests.messages(in: initialized.body).first?["result"]?["serverInfo"]?["name"] == "homeswift")
        client.sessionID = sessionID
        #expect(try await client.send(body: JSONRPCMessage.notification(method: "notifications/initialized", params: nil).json.text()).status == 202)

        // A request with SSE accepted streams the response as an event.
        let listed = try await client.send(body: request(2, "tools/list"))
        #expect(listed.status == 200)
        #expect(listed.headers["content-type"]?.hasPrefix("text/event-stream") == true)
        let tools = HTTPClientForTests.messages(in: listed.body).first?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.contains { $0["name"] == "update_config" })

        // Another token cannot use this session; an unknown session is 404; a read token sees fewer tools.
        var viewer = HTTPClientForTests(url: url, token: "viewer-token", sessionID: sessionID)
        #expect(try await viewer.send(body: request(3, "tools/list")).status == 403)
        viewer.sessionID = "nope"
        #expect(try await viewer.send(body: request(3, "tools/list")).status == 404)
        viewer.sessionID = nil
        let viewerInit = try await viewer.send(body: request(1, "initialize"))
        viewer.sessionID = viewerInit.headers["mcp-session-id"]
        let viewerTools = HTTPClientForTests.messages(in: try await viewer.send(body: request(2, "tools/list")).body).first?["result"]?["tools"]?.arrayValue ?? []
        #expect(!viewerTools.contains { $0["name"] == "set_accessory" })

        // The standing stream carries a resource update; DELETE ends the session.
        _ = try await client.send(body: request(4, "resources/subscribe", ["uri": "homeswift://accessories"]))
        let streamTask = Task { () -> String in
            // The same streaming client the stdio proxy uses, which also works on Linux.
            let http = try await URLSessionTransport(timeout: 10).stream(HTTPRequest(
                method: "GET", url: url, headers: ["Authorization": "Bearer admin-token", "Mcp-Session-Id": sessionID, "Accept": "text/event-stream"]))
            #expect(http.status == 200)
            var text = ""
            for try await event in SSE.events(http.body) {
                text += event.data + "\n"
                if event.data.contains("notifications/resources/updated") { break }
            }
            return text
        }
        try await Task.sleep(for: .milliseconds(300))
        environment.host.mainBridge.server.accessories[1].service(.lightbulb)?.characteristic(.on).value = .bool(true)
        let streamed = try await streamTask.value
        #expect(streamed.contains("notifications/resources/updated"))
        #expect(streamed.contains("homeswift://accessories"))

        #expect(try await client.send("DELETE").status == 204)
        #expect(try await client.send(body: request(5, "ping")).status == 404)
        #expect(try await client.send("PUT", body: "{}").status == 405)
        #expect(try await HTTPClientForTests(url: URL(string: "http://127.0.0.1:\(transport.port!)/other")!, token: "admin-token").send(body: request(1, "ping")).status == 404)
    }

    @Test func proxiesStdioIncludingQuestions() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        var configuration = MCPConfiguration()
        configuration.token = "proxy-token"
        var options = MCPHTTPServer.Options(host: "127.0.0.1", port: 0)
        options.logger = testLogger
        let transport = MCPHTTPServer(server: environment.server, configuration: configuration, options: options)
        try await transport.start()
        defer { Task { await transport.stop(); await environment.stop() } }
        let url = URL(string: "http://127.0.0.1:\(try #require(transport.port))/mcp")!

        var proxyOptions = StdioProxy.Options(url: url, token: "proxy-token")
        proxyOptions.logger = testLogger
        let proxy = StdioProxy(options: proxyOptions, transport: URLSessionTransport(timeout: 30))
        let (input, feed) = AsyncStream<Data>.makeStream()
        let output = OutputLines()
        let running = Task { await proxy.run(input: input) { output.add($0) } }

        // Lines arrive back to back, as a piped client sends them: initialize must land first.
        feed.yield(Data(request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": ["elicitation": [:]], "clientInfo": ["name": "stdio", "version": "1"]]).utf8))
        feed.yield(Data(JSONRPCMessage.notification(method: "notifications/initialized", params: nil).json.text().utf8))
        feed.yield(Data(request(2, "tools/call", ["name": "get_server_status", "arguments": [:]]).utf8))
        #expect(await eventually { output.lines.contains { $0["id"] == 1 && $0["result"]?["protocolVersion"] == "2025-06-18" } })
        #expect(await eventually { output.lines.contains { $0["id"] == 2 && $0["result"]?["structuredContent"]?["bridges"]?[0]?["deviceId"] == "0E:11:22:33:44:55" } })
        #expect(!output.lines.contains { $0["id"] == 2 && $0["error"] != nil })

        // A destructive tool: the server's question comes out of the proxy, the answer goes back in.
        feed.yield(Data(request(3, "tools/call", ["name": "set_security_accessory", "arguments": ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0]]).utf8))
        #expect(await eventually { output.lines.contains { $0["method"] == "elicitation/create" } })
        let question = try #require(output.lines.first { $0["method"] == "elicitation/create" })
        #expect(question["params"]?["message"]?.stringValue?.contains("set_security_accessory") == true)
        feed.yield(Data(JSONRPCMessage.response(id: question["id"]!, result: ["action": "accept", "content": ["confirm": true]]).json.text().utf8))
        #expect(await eventually { output.lines.contains { $0["id"] == 3 && $0["result"]?["isError"] == nil && $0["result"]?["structuredContent"]?["value"] == 0 } })
        #expect(environment.written.contains { $0.0 == "lock.target" })

        // A notification from the server reaches stdout through the standing stream.
        feed.yield(Data(request(4, "resources/subscribe", ["uri": "homeswift://accessories"]).utf8))
        #expect(await eventually { output.lines.contains { $0["id"] == 4 } })
        try await Task.sleep(for: .milliseconds(500))
        environment.host.mainBridge.server.accessories[1].service(.lightbulb)?.characteristic(.brightness).value = .int(10)
        #expect(await eventually { output.lines.contains { $0["method"] == "notifications/resources/updated" } })

        feed.finish()
        await running.value
        #expect(environment.server.activeSessions.isEmpty)
    }
}

final class OutputLines: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [JSONValue] = []
    var lines: [JSONValue] { lock.withLock { collected } }
    func add(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let value = try? JSONValue(data: Data(line)) { lock.withLock { collected.append(value) } }
        }
    }
}
