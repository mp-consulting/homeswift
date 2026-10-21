import Foundation
import Homeswift
import HomeswiftAI
import Testing

@testable import HomeswiftMCP

@Suite struct JSONRPCTests {
    @Test func parsesAndEncodes() throws {
        let request = try JSONRPCMessage.parse(data: Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8))
        #expect(request == [.request(id: 7, method: "ping", params: nil)])
        #expect(try JSONRPCMessage.parse(data: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == [.notification(method: "notifications/initialized", params: nil)])
        #expect(try JSONRPCMessage.parse(data: Data(#"{"jsonrpc":"2.0","id":"a","result":{}}"#.utf8)) == [.response(id: "a", result: [:])])
        #expect(try JSONRPCMessage.parse(data: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#.utf8)) == [.failure(id: 1, error: JSONRPCError(code: -32601, message: "no"))])
        #expect(try JSONRPCMessage.parse(data: Data(#"[{"jsonrpc":"2.0","id":1,"method":"a"},{"jsonrpc":"2.0","method":"b"}]"#.utf8)).count == 2)
        #expect(JSONRPCMessage.request(id: 1, method: "x", params: ["a": 1]).json == ["jsonrpc": "2.0", "id": 1, "method": "x", "params": ["a": 1]])
        #expect(JSONRPCMessage.failure(id: .null, error: .invalidRequest("bad")).json["error"]?["code"] == -32600)

        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(data: Data("nope".utf8)) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(["jsonrpc": "1.0", "method": "x"]) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(["jsonrpc": "2.0", "id": [1], "method": "x"]) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(["jsonrpc": "2.0", "id": 1]) }
    }
}

@Suite struct ScopeTests {
    @Test func readsTheConfigurationAndMatchesTokens() throws {
        let configuration = try MCPConfiguration(block: [
            "mcp": ["http": [
                "enabled": true, "port": 9000, "token": "main-token", "readOnly": false, "allowedOrigins": "https://a.example, https://b.example",
                "clients": [["name": "Dashboard", "token": "dash-token", "scope": "read"], ["token": "ctl-token", "scope": "control"], ["name": "empty"]],
            ]],
        ])
        #expect(configuration.enabled)
        #expect(configuration.port == 9000)
        #expect(configuration.allowedOrigins == ["https://a.example", "https://b.example"])
        #expect(configuration.clients.count == 2)
        #expect(configuration.principal(for: "main-token") == Principal(name: "default", scope: .admin))
        #expect(configuration.principal(for: "dash-token") == Principal(name: "Dashboard", scope: .read))
        #expect(configuration.principal(for: "ctl-token") == Principal(name: "client", scope: .control))
        #expect(configuration.principal(for: "main-toke") == nil)
        #expect(configuration.principal(for: "") == nil)

        var readOnly = configuration
        readOnly.readOnly = true
        #expect(readOnly.principal(for: "main-token")?.scope == .read)
        #expect(readOnly.principal(for: "ctl-token")?.scope == .read)

        #expect(MCPConfiguration().enabled == false)
        #expect(MCPConfiguration().port == 8582)
        #expect(throws: MCPConfigurationError.self) { try MCPConfiguration(block: ["mcp": ["http": ["clients": [["token": "t", "scope": "root"]]]]]) }
        #expect(throws: MCPConfigurationError.self) { try MCPConfiguration(block: ["mcp": ["http": ["port": 70000]]]) }
        #expect(Scope.read < .control && Scope.control < .admin)
        #expect(MCPConfiguration.generateToken().count >= 40)
        #expect(MCPConfiguration.generateToken() != MCPConfiguration.generateToken())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ProtocolTests {
    @Test func initializesListsAndCallsTools() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)

        await #expect(throws: JSONRPCError.self) { try await client.call("tools/list") }
        try await client.initialize()
        #expect(client.session.isInitialized)
        #expect(client.session.supportsElicitation)

        let tools = try await client.call("tools/list")["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names.contains("get_server_status"))
        #expect(names.contains("set_security_accessory"))
        #expect(names.contains("update_config"))
        let security = tools.first { $0["name"] == "set_security_accessory" }
        #expect(security?["annotations"]?["destructiveHint"] == true)
        #expect(tools.first { $0["name"] == "list_accessories" }?["annotations"]?["readOnlyHint"] == true)

        let status = try await client.tool("get_server_status")
        #expect(status["isError"] == nil)
        #expect(status["structuredContent"]?["bridges"]?[0]?["deviceId"] == "0E:11:22:33:44:55")
        #expect(status["structuredContent"]?["bridges"]?[0]?["accessories"] == 2)

        let accessories = try await client.tool("list_accessories")["structuredContent"]?["accessories"]?.arrayValue ?? []
        #expect(accessories.map { $0["id"] } == ["Devices:lamp", "Devices:lock"])
        #expect(accessories[0]["platform"] == "Devices")
        #expect(accessories[0]["services"]?[0]?["values"]?["Brightness"] == 40)

        let detailed = try await client.tool("get_accessory", ["id": "Devices:lamp"])["structuredContent"]
        #expect(detailed?["services"]?[0]?["characteristics"]?.arrayValue?.contains { $0["type"] == "Brightness" && $0["maxValue"] == 100 } == true)
        #expect(try await client.tool("get_accessory", ["id": "nope"])["isError"] == true)

        let plugins = try await client.tool("list_plugins")["structuredContent"]
        #expect(plugins?["platforms"]?[0]?["platform"] == "Devices")
        #expect(plugins?["unknownPlatforms"] == ["Ghost"])

        #expect(try await client.call("ping") == [:])
        await #expect(throws: JSONRPCError.self) { try await client.call("nope/method") }
        await #expect(throws: JSONRPCError.self) { try await client.tool("no_such_tool") }
        #expect(try await client.tool("get_recent_logs", ["lines": "many"])["isError"] == true)
    }

    @Test func writesWithScopesAndConfirmations() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }

        let reader = DirectClient(server: environment.server, scope: .read)
        try await reader.initialize()
        #expect(try await reader.call("tools/list")["tools"]?.arrayValue?.contains { $0["name"] == "set_accessory" } == false)
        let refused = try await reader.tool("set_accessory", ["id": "Devices:lamp", "characteristic": "On", "value": true])
        #expect(refused["isError"] == true)
        #expect(refused["content"]?[0]?["text"]?.stringValue?.contains("does not allow set_accessory") == true)

        let controller = DirectClient(server: environment.server, scope: .control)
        try await controller.initialize()
        let set = try await controller.tool("set_accessory", ["id": "Devices:lamp", "characteristic": "brightness", "value": 75])
        #expect(set["structuredContent"]?["value"] == 75)
        #expect(environment.written.last?.1 == .int(75))
        #expect(environment.host.mainBridge.server.accessories[1].service(.lightbulb)?[.brightness]?.value == .int(75))

        let tooHigh = try await controller.tool("set_accessory", ["id": "Devices:lamp", "characteristic": "Brightness", "value": 500])
        #expect(tooHigh["isError"] == true)
        let guarded = try await controller.tool("set_accessory", ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0])
        #expect(guarded["isError"] == true)
        #expect(guarded["content"]?[0]?["text"]?.stringValue?.contains("set_security_accessory") == true)

        // Declined, then accepted, through elicitation.
        let declined = try await controller.tool("set_security_accessory", ["id": "Devices:lock", "characteristic": "lockTargetState", "value": 0])
        #expect(declined["isError"] == true)
        #expect(declined["content"]?[0]?["text"]?.stringValue?.contains("did not confirm") == true)
        let unlocked = try await controller.tool("set_security_accessory", ["id": "Devices:lock", "characteristic": "lockTargetState", "value": 0], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(unlocked["isError"] == nil)
        #expect(environment.written.last?.0 == "lock.target")

        // Several at once, with a dry run first.
        let preview = try await controller.tool("set_accessories", ["dryRun": true, "changes": [["id": "Devices:lamp", "characteristic": "On", "value": true]]])
        #expect(preview["structuredContent"]?["results"]?[0]?["dryRun"] == true)
        #expect(environment.written.last?.0 == "lock.target")
        let bulk = try await controller.tool("set_accessories", ["changes": [["id": "Devices:lamp", "characteristic": "On", "value": true], ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 1]]])
        #expect(bulk["structuredContent"]?["results"]?[1]?["error"]?.stringValue?.contains("set_security_accessory") == true)
        #expect(bulk["isError"] == nil)
        #expect(try await controller.tool("identify_accessory", ["id": "Devices:lamp"])["isError"] == nil)
        #expect(environment.written.contains { $0.0 == "lamp.identify" })

        // Admin tools stay out of reach.
        #expect(try await controller.tool("update_config", ["config": [:]])["isError"] == true)

        let entries = environment.auditEntries
        #expect(entries.contains { $0["tool"] == "set_security_accessory" && $0["notConfirmed"] == true })
        #expect(entries.contains { $0["tool"] == "set_security_accessory" && $0["ok"] == true })
        #expect(entries.contains { $0["tool"] == "set_accessories" && $0["dryRun"] == true })
        #expect(entries.allSatisfy { $0["principal"] == "test" && $0["scope"] == "control" })
        #expect(!entries.contains { $0["tool"] == "get_server_status" })
    }

    @Test func confirmsWithAnArgumentWhenTheClientCannotAsk() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server, elicitation: false)
        try await client.initialize()
        #expect(!client.session.supportsElicitation)
        let refused = try await client.tool("set_security_accessory", ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0])
        #expect(refused["isError"] == true)
        #expect(refused["content"]?[0]?["text"]?.stringValue?.contains("\"confirmed\": true") == true)
        let done = try await client.tool("set_security_accessory", ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0, "confirmed": true])
        #expect(done["isError"] == nil)
    }

    @Test func managesTheConfigFile() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let config = try await client.tool("get_config")["structuredContent"]
        #expect(config?["platforms"]?[0]?["token"] == "__REDACTED__")
        #expect(config?["bridge"]?["pin"] == "__REDACTED__")
        #expect(config?["platforms"]?[0]?["platform"] == "Devices")

        let preview = try await client.tool("patch_config", ["platform": "Devices", "settings": ["pollingRate": 500], "dryRun": true])
        #expect(preview["structuredContent"]?["changes"] == ["platforms[0].pollingRate"])
        #expect(preview["structuredContent"]?["config"]?["platforms"]?[0]?["token"] == "__REDACTED__")
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]?["pollingRate"] == nil)

        let patched = try await client.tool("patch_config", ["platform": "Devices", "settings": ["pollingRate": 500, "name": .null]], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(patched["isError"] == nil)
        let written = try JSONValue(data: Data(contentsOf: environment.configURL))
        #expect(written["platforms"]?[0]?["pollingRate"] == 500)
        #expect(written["platforms"]?[0]?["token"] == "secret-token")
        #expect(written["platforms"]?[0]?["name"] == nil)
        let backups = try await client.tool("list_config_backups")["structuredContent"]?["backups"]?.arrayValue ?? []
        #expect(backups.count == 1)

        // A full replacement with redacted secrets keeps the real ones; an invalid one is refused.
        let redacted = try #require(try await client.tool("get_config")["structuredContent"])
        var root = redacted.objectValue!
        root["platforms"] = .array([redacted["platforms"]![0]!])
        let replacement = JSONValue.object(root)
        let replaced = try await client.tool("update_config", ["config": replacement], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(replaced["isError"] == nil)
        let final = try JSONValue(data: Data(contentsOf: environment.configURL))
        #expect(final["platforms"]?.arrayValue?.count == 1)
        #expect(final["platforms"]?[0]?["token"] == "secret-token")
        #expect(final["bridge"]?["pin"] == "031-45-154")
        let invalid = try await client.tool("update_config", ["config": ["bridge": ["pin": "111-11-111"]], "confirmed": true], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(invalid["isError"] == true)

        let restored = try await client.tool("restore_config", ["backup": .string(backups[0].stringValue!)], answer: ["action": "accept", "content": ["confirm": true]])
        #expect(restored["isError"] == nil)
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?.arrayValue?.count == 2)
        #expect(try await client.tool("restore_config", ["backup": "nope.json"], answer: ["action": "accept", "content": ["confirm": true]])["isError"] == true)
    }

    @Test func servesLogsResourcesPromptsAndCompletions() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        environment.logs.append(.init(level: .info, label: "Devices", text: "Found lamp token=abc"))
        environment.logs.append(.init(level: .warning, label: "Devices", text: "Lamp not responding"))

        let recent = try await client.tool("get_recent_logs", ["lines": 10, "level": "warning"])["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(recent.contains("Lamp not responding"))
        #expect(!recent.contains("Found lamp"))
        #expect(recent.hasPrefix("<untrusted-data"))
        let found = try await client.tool("search_logs", ["pattern": "LAMP"])["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(found.contains("2 match(es)"))
        #expect(try await client.tool("search_logs", ["pattern": "("])["isError"] == true)

        let resources = try await client.call("resources/list")["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue } ?? []
        #expect(resources == ["homeswift://status", "homeswift://accessories", "homeswift://logs/recent"])
        let accessories = try await client.call("resources/read", ["uri": "homeswift://accessories"])["contents"]?[0]?["text"]?.stringValue ?? ""
        #expect(accessories.contains("Devices:lamp"))
        let one = try await client.call("resources/read", ["uri": "homeswift://accessory/Devices:lock"])["contents"]?[0]?["text"]?.stringValue ?? ""
        #expect(one.contains("Lock Target State"))
        await #expect(throws: JSONRPCError.self) { try await client.call("resources/read", ["uri": "homeswift://accessory/none"]) }
        let templates = try await client.call("resources/templates/list")["resourceTemplates"]?.arrayValue?.compactMap { $0["uriTemplate"]?.stringValue } ?? []
        #expect(templates == ["homeswift://accessory/{id}", "homeswift://plugin/{platform}"])
        let completion = try await client.call("completion/complete", ["ref": ["type": "ref/resource", "uri": "homeswift://accessory/{id}"], "argument": ["name": "id", "value": "Devices:l"]])
        #expect(completion["completion"]?["values"] == ["Devices:lamp", "Devices:lock"])

        // Subscriptions: a change on the bridge becomes a notification on the session's own stream.
        _ = try await client.call("resources/subscribe", ["uri": "homeswift://accessory/Devices:lamp"])
        environment.host.mainBridge.server.accessories[1].service(.lightbulb)?.characteristic(.on).value = .bool(true)
        var notified = false
        let deadline = ContinuousClock.now + .seconds(5)
        for await message in client.session.outbound {
            if case .notification("notifications/resources/updated", let params) = message, params?["uri"] == "homeswift://accessory/Devices:lamp" {
                notified = true
                break
            }
            if ContinuousClock.now > deadline { break }
        }
        #expect(notified)

        let prompts = try await client.call("prompts/list")["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(prompts.contains("troubleshoot-device"))
        let prompt = try await client.call("prompts/get", ["name": "troubleshoot-device", "arguments": ["device": "Desk Lamp", "symptom": "flickers"]])
        #expect(prompt["messages"]?[0]?["content"]?["text"]?.stringValue?.contains("\"Desk Lamp\" (symptom: flickers)") == true)
        await #expect(throws: JSONRPCError.self) { try await client.call("prompts/get", ["name": "troubleshoot-device"]) }

        _ = try await client.call("logging/setLevel", ["level": "warning"])
        #expect(client.session.logLevel == .warning)
        await #expect(throws: JSONRPCError.self) { try await client.call("logging/setLevel", ["level": "loud"]) }
    }
}
