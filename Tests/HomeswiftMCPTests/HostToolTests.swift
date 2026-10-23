import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftMCP

private let accept: JSONValue = ["action": "accept", "content": ["confirm": true]]

/// The Devices plugin on the main bridge and again on a child bridge.
private let childBridgeConfig = """
    {
      "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
      "platforms": [
        { "platform": "Devices", "name": "Devices" },
        { "platform": "Devices", "name": "Upstairs", "_bridge": { "username": "0E:AA:BB:CC:DD:EE", "name": "Upstairs Bridge", "port": 0 } }
      ]
    }
    """

@Suite(.timeLimit(.minutes(1)))
struct HostToolTests {
    @Test func listsToolsWithOutputSchemasForTheirProtocolVersion() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let tools = try await client.call("tools/list")["tools"]?.arrayValue ?? []
        let byName = Dictionary(tools.compactMap { tool in tool["name"]?.stringValue.map { ($0, tool) } }, uniquingKeysWith: { a, _ in a })
        for name in ["list_child_bridges", "get_child_bridge_health", "restart_child_bridge", "stop_child_bridge", "start_child_bridge", "get_cached_accessories",
                     "remove_cached_accessory", "reset_cached_accessories", "get_pairing_info", "reset_pairings", "get_accessory_history"] {
            #expect(byName[name] != nil, "\(name)")
        }
        for name in ["restart_child_bridge", "stop_child_bridge", "remove_cached_accessory", "reset_cached_accessories", "reset_pairings"] {
            #expect(byName[name]?["annotations"]?["destructiveHint"] == true, "\(name)")
        }
        #expect(byName["start_child_bridge"]?["annotations"]?["destructiveHint"] == false)
        for name in ["get_server_status", "list_accessories", "get_accessory", "list_plugins", "get_system_info", "search_logs", "list_child_bridges", "get_pairing_info", "get_accessory_history"] {
            #expect(byName[name]?["outputSchema"]?["type"] == "object", "\(name)")
        }

        // Every structured answer of those tools is an object with the required fields.
        for name in ["get_server_status", "list_accessories", "list_plugins", "list_config_backups", "list_child_bridges", "get_child_bridge_health", "get_pairing_info", "get_cached_accessories"] {
            let result = try await client.tool(name)
            let structured = try #require(result["structuredContent"]?.objectValue, "\(name)")
            for field in byName[name]?["outputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(structured[field] != nil, "\(name).\(field)")
            }
        }

        // A client on an older protocol gets no outputSchema.
        let old = DirectClient(server: environment.server)
        let initialized = try await old.call("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "old", "version": "1"]])
        #expect(initialized["protocolVersion"] == "2025-03-26")
        let oldTools = try await old.call("tools/list")["tools"]?.arrayValue ?? []
        #expect(!oldTools.isEmpty)
        #expect(oldTools.allSatisfy { $0["outputSchema"] == nil })
    }

    @Test func controlsChildBridges() async throws {
        let environment = try MCPTestEnvironment(config: childBridgeConfig)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let list = try await client.tool("list_child_bridges")["structuredContent"]?["childBridges"]?.arrayValue ?? []
        #expect(list.count == 1)
        #expect(list.first?["id"] == "0E:AA:BB:CC:DD:EE")
        #expect(list.first?["name"] == "Upstairs Bridge")
        #expect(list.first?["status"] == "ok")
        #expect(list.first?["instances"] == ["Upstairs"])

        // Stopping asks first.
        let declined = try await client.tool("stop_child_bridge", ["id": "0E:AA:BB:CC:DD:EE"])
        #expect(declined["isError"] == true)
        #expect(environment.host.childBridges.first?.running == true)
        let stopped = try await client.tool("stop_child_bridge", ["id": "0EAABBCCDDEE"], answer: accept)
        #expect(stopped["structuredContent"]?["status"] == "stopped")
        #expect(environment.host.childBridges.first?.running == false)
        #expect(environment.host.mainBridge.server.port != nil)

        let health = try await client.tool("get_child_bridge_health", ["id": "Upstairs Bridge"])["structuredContent"]?["bridges"]?[0]
        #expect(health?["status"] == "stopped")
        #expect(health?["stoppedManually"] == true)
        #expect(try await client.tool("get_child_bridge_health", ["id": "nope"])["isError"] == true)

        // Starting does not ask.
        let started = try await client.tool("start_child_bridge", ["id": "Upstairs Bridge"])
        #expect(started["structuredContent"]?["status"] == "ok")
        let restarted = try await client.tool("restart_child_bridge", ["id": "Upstairs Bridge"], answer: accept)
        #expect(restarted["structuredContent"]?["restarts"] == 1)
        #expect(restarted["structuredContent"]?["uptimeSeconds"]?.doubleValue != nil)

        let resource = try await client.call("resources/read", ["uri": "homeswift://child-bridge/0E:AA:BB:CC:DD:EE"])["contents"]?[0]?["text"]?.stringValue ?? ""
        #expect(resource.contains("Upstairs Bridge"))
        let completion = try await client.call("completion/complete", ["ref": ["type": "ref/resource", "uri": "homeswift://child-bridge/{id}"], "argument": ["name": "id", "value": "0e"]])
        #expect(completion["completion"]?["values"] == ["0E:AA:BB:CC:DD:EE"])

        let entries = environment.auditEntries
        #expect(entries.contains { $0["tool"] == "stop_child_bridge" && $0["notConfirmed"] == true })
        #expect(entries.contains { $0["tool"] == "stop_child_bridge" && $0["ok"] == true })
        #expect(entries.contains { $0["tool"] == "start_child_bridge" && $0["ok"] == true })
        #expect(entries.contains { $0["tool"] == "restart_child_bridge" && $0["ok"] == true })

        // Reading is open to a read token, control is not.
        let reader = DirectClient(server: environment.server, scope: .read)
        try await reader.initialize()
        #expect(try await reader.tool("list_child_bridges")["isError"] == nil)
        #expect(try await reader.tool("start_child_bridge", ["id": "Upstairs Bridge"])["isError"] == true)
    }

    @Test func managesCachedAccessories() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let cached = try await client.tool("get_cached_accessories")["structuredContent"]?["accessories"]?.arrayValue ?? []
        #expect(cached.compactMap { $0["id"]?.stringValue } == ["Devices:lamp", "Devices:lock"])
        #expect(cached.first?["cacheFile"] == "accessories/Devices-Devices.json")
        #expect(cached.first?["restoredOnly"] == false)

        let removed = try await client.tool("remove_cached_accessory", ["id": "Devices:lock"], answer: accept)
        #expect(removed["structuredContent"]?["removed"]?["id"] == "Devices:lock")
        #expect(environment.host.mainBridge.server.accessories.map(\.id) == ["bridge", "Devices:lamp"])
        #expect(try await client.tool("remove_cached_accessory", ["id": "Devices:lock"], answer: accept)["isError"] == true)

        let reset = try await client.tool("reset_cached_accessories", answer: accept)
        #expect(reset["structuredContent"]?["removed"] == 1)
        // The plugin started again and added both.
        #expect(environment.host.mainBridge.server.accessories.map(\.id) == ["bridge", "Devices:lamp", "Devices:lock"])
        #expect(environment.auditEntries.contains { $0["tool"] == "reset_cached_accessories" && $0["ok"] == true })
    }

    @Test func givesPairingInfoWithoutTheSetupCodeAndResetsPairings() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        let info = try await client.tool("get_pairing_info")
        let text = info.text()
        #expect(!text.contains("031-45-154"))
        #expect(!text.contains("03145154"))
        #expect(!text.contains("X-HM://"))
        let bridge = info["structuredContent"]?["bridges"]?[0]
        #expect(bridge?["deviceId"] == "0E:11:22:33:44:55")
        #expect(bridge?["kind"] == "main")
        #expect(bridge?["paired"] == false)
        #expect(bridge?["controllers"] == 0)

        let reader = DirectClient(server: environment.server, scope: .control)
        try await reader.initialize()
        #expect(try await reader.tool("reset_pairings")["isError"] == true)

        #expect(try await client.tool("reset_pairings")["isError"] == true)
        let reset = try await client.tool("reset_pairings", ["bridge": "Test Bridge"], answer: accept)
        #expect(reset["structuredContent"]?["deviceId"] == "0E:11:22:33:44:55")
        #expect(try await client.tool("reset_pairings", ["bridge": "nope"], answer: accept)["isError"] == true)
        #expect(environment.auditEntries.contains { $0["tool"] == "reset_pairings" && $0["ok"] == true })
    }

    @Test func readsAccessoryHistory() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server, scope: .read)
        try await client.initialize()

        let none = try await client.tool("get_accessory_history", ["id": "Devices:lamp"])["structuredContent"]
        #expect(none?["series"] == [])
        #expect(none?["note"]?.stringValue?.contains("Eve history") == true)

        let history = EveHistory(.weather, accessoryName: "Sensor", averaging: false)
        let sensor = Accessory(id: "Devices:sensor", name: "Sensor", category: .sensor, services: [Service(.temperatureSensor, name: "Sensor", isPrimary: true), history.service])
        try environment.host.mainBridge.server.add(sensor)
        let now = Int(Date().timeIntervalSince1970)
        history.add(EveHistory.Entry(unixTime: now - 7200, temp: 18, humidity: 50))
        history.add(EveHistory.Entry(unixTime: now - 3600, temp: 22, humidity: 40))
        history.add(EveHistory.Entry(unixTime: now - 100 * 3600, temp: 5, humidity: 90))

        let result = try await client.tool("get_accessory_history", ["id": "Devices:sensor", "hours": 3])["structuredContent"]
        let series = result?["series"]?.arrayValue ?? []
        #expect(series.compactMap { $0["type"]?.stringValue } == ["CurrentTemperature", "CurrentRelativeHumidity"])
        let temperature = series.first
        #expect(temperature?["count"] == 2)
        #expect(temperature?["min"]?["value"] == 18)
        #expect(temperature?["max"]?["value"] == 22)
        #expect(temperature?["last"]?["value"] == 22)
        #expect(temperature?["unit"] == "celsius")
        // 18 for an hour, then 22 for an hour: 20 on average.
        #expect(abs((temperature?["avg"]?.doubleValue ?? 0) - 20) < 0.1)
        #expect(temperature?["points"]?.arrayValue?.count == 2)

        let humidity = try await client.tool("get_accessory_history", ["id": "Devices:sensor", "hours": 3, "type": "CurrentRelativeHumidity"])["structuredContent"]
        #expect(humidity?["series"]?.arrayValue?.count == 1)
        #expect(try await client.tool("get_accessory_history", ["id": "nope"])["isError"] == true)
    }

    @Test func historyHelpers() {
        let points = (0..<100).map { (time: Double($0 * 60), value: Double($0)) }
        let down = HomeswiftCatalog.downsample(points, to: 10)
        #expect(down.count == 10)
        #expect(down.first?.value == 4.5)
        #expect(HomeswiftCatalog.downsample(points, to: 200).count == 100)
        let summary = HomeswiftCatalog.summarize([(0, 10), (100, 20)], to: 400)
        // 10 for 100 s, 20 for 300 s.
        #expect(summary["avg"] == .number(17.5))
        #expect(HomeswiftCatalog.minute(0) == "1970-01-01T00:00Z")
    }

    @Test func filtersAccessories() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server, scope: .read)
        try await client.initialize()
        func ids(_ arguments: JSONValue) async throws -> [String] {
            try await client.tool("list_accessories", arguments)["structuredContent"]?["accessories"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        }
        #expect(try await ids(["type": "lightbulb"]) == ["Devices:lamp"])
        #expect(try await ids(["type": "Lock Mechanism"]) == ["Devices:lock"])
        #expect(try await ids(["type": "Switch"]) == ["Devices:lock"])
        #expect(try await ids(["manufacturer": "acme"]) == ["Devices:lamp"])
        #expect(try await ids(["excludeManufacturer": "ACME"]) == ["Devices:lock"])
        #expect(try await ids(["name": "trigger"]) == ["Devices:lock"])
        #expect(try await ids(["name": "desk", "platform": "Devices"]) == ["Devices:lamp"])
        #expect(try await ids(["platform": "Nobody"]) == [])
        #expect(try await client.tool("list_accessories", ["room": "Kitchen"])["isError"] == true)
    }

    @Test func setsAccessoriesByFilterOrIDs() async throws {
        let environment = try MCPTestEnvironment(config: childBridgeConfig)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server, scope: .control)
        try await client.initialize()

        let preview = try await client.tool("set_accessories", ["filter": ["excludeManufacturer": "nobody"], "characteristic": "On", "value": true, "dryRun": true])["structuredContent"]
        // Two lamps (main bridge and child bridge); the door triggers are security controls.
        #expect(preview?["wouldChange"] == 2)
        #expect(preview?["skipped"]?.arrayValue?.count == 2)
        #expect(preview?["skipped"]?[0]?["reason"]?.stringValue?.contains("set_security_accessory") == true)
        #expect(environment.written.isEmpty)

        let capped = try await client.tool("set_accessories", ["filter": ["type": "lightbulb"], "characteristic": "On", "value": true, "maxTargets": 1])
        #expect(capped["isError"] == true)
        #expect(capped.text().contains("maxTargets"))
        #expect(environment.written.isEmpty)

        let done = try await client.tool("set_accessories", ["filter": ["type": "lightbulb"], "characteristic": "Brightness", "value": 60])["structuredContent"]
        #expect(done?["changed"] == 2)
        #expect(environment.written.filter { $0.0 == "lamp.brightness" }.count == 2)

        let byID = try await client.tool("set_accessories", ["ids": ["Devices:lamp", "Devices:lamp", "nope"], "characteristic": "On", "value": false])["structuredContent"]
        #expect(byID?["skipped"]?[0]?["reason"] == "no such accessory")
        #expect(try await client.tool("set_accessories", ["filter": [:], "characteristic": "On", "value": true])["isError"] == true)
        #expect(try await client.tool("set_accessories", ["characteristic": "On", "value": true])["isError"] == true)
        #expect(try await client.tool("set_accessories", ["ids": ["Devices:lamp"], "filter": ["type": "lightbulb"], "characteristic": "On", "value": true])["isError"] == true)
    }

    @Test func searchesLogsWithFilters() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let admin = DirectClient(server: environment.server)
        try await admin.initialize()
        let now = Date()
        let logs = environment.logs
        logs.append(.init(date: now.addingTimeInterval(-7200), level: .warning, label: "Kitchen Lights", text: "old warning"))
        logs.append(.init(date: now.addingTimeInterval(-60), level: .info, label: "Kitchen Lights", text: "lamp on"))
        logs.append(.init(date: now.addingTimeInterval(-50), level: .error, label: "Garage", text: "door timeout"))
        logs.append(.init(date: now.addingTimeInterval(-40), level: .debug, label: "Garage", text: "polling"))
        logs.append(.init(date: now.addingTimeInterval(-30), level: .warning, label: "Kitchen Lights", text: "Lamp slow"))

        func search(_ arguments: JSONValue, as client: DirectClient? = nil) async throws -> JSONValue {
            try await (client ?? admin).tool("search_logs", arguments)
        }
        func texts(_ result: JSONValue) -> [String] { result["structuredContent"]?["matches"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? [] }

        #expect(texts(try await search(["level": "warn"])).suffix(3) == ["old warning", "door timeout", "Lamp slow"])
        #expect(texts(try await search(["level": "warning", "since": "1h"])) == ["door timeout", "Lamp slow"])
        #expect(texts(try await search(["plugin": "kitchen", "since": "1h"])) == ["lamp on", "Lamp slow"])
        #expect(texts(try await search(["pattern": "lamp", "caseSensitive": true])) == ["lamp on"])
        #expect(texts(try await search(["pattern": "lamp", "until": "45s"])) == ["lamp on"])
        let structured = try await search(["pattern": "lamp", "limit": 1])["structuredContent"]
        #expect(structured?["total"] == 2)
        #expect(structured?["shown"] == 1)
        #expect(structured?["matches"]?[0]?["plugin"] == "Kitchen Lights")
        #expect(structured?["matches"]?[0]?["level"] == "warning")

        let context = try await search(["pattern": "timeout", "context": 1])
        let contextText = context["content"]?[0]?["text"]?.stringValue ?? ""
        let lines = contextText.split(separator: "\n")
        #expect(contextText.contains("<untrusted-data source=\"log\">"))
        #expect(lines.contains { $0.hasPrefix("> ") && $0.contains("door timeout") })
        #expect(lines.contains { $0.hasPrefix("  ") && $0.contains("lamp on") })
        #expect(lines.contains { $0.hasPrefix("  ") && $0.contains("polling") })

        #expect(texts(try await search(["pattern": "^.*slow$", "regex": true, "since": "1h"])) == ["Lamp slow"])
        #expect(try await search(["since": "yesterday-ish"])["isError"] == true)
        #expect(try await search([:])["isError"] == true)
        #expect(try await search(["pattern": "(", "regex": true])["isError"] == true)
        #expect(HomeswiftCatalog.parseTimeBound("2026-10-04T18:00") != nil)
        #expect(HomeswiftCatalog.parseTimeBound("2026-10-04T18:00:00Z") == Date(timeIntervalSince1970: 1_791_136_800))
        #expect(abs(HomeswiftCatalog.parseTimeBound("2d", now: now)!.timeIntervalSince(now) + 172_800) < 0.001)
    }

    @Test func stopsARegexThatRunsTooLong() throws {
        let environment = try MCPTestEnvironment()
        environment.logs.append(.init(level: .info, label: "Test", text: String(repeating: "a", count: 40) + "!"))
        var query = HomeswiftCatalog.LogQuery(pattern: "(a+)+$")
        query.regex = true
        let started = ContinuousClock.now
        #expect(throws: HomeswiftCatalog.LogSearchTimeout.self) { try environment.catalog.searchLogs(query, budget: .milliseconds(300)) }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func reportsLoadAndNetwork() async throws {
        let environment = try MCPTestEnvironment()
        let client = DirectClient(server: environment.server, scope: .read)
        try await client.initialize()
        let info = try await client.tool("get_system_info")["structuredContent"]
        #expect(info?["cpus"]?.doubleValue ?? 0 >= 1)
        #expect(info?["network"]?["interfaces"]?.arrayValue != nil)
        #expect(info?["network"]?["sampledSeconds"]?.doubleValue ?? 0 > 0)
        #if os(macOS) || os(Linux)
        #expect(info?["loadAverage"]?.arrayValue?.count == 3)
        #endif

        let dev = """
            Inter-|   Receive                                                |  Transmit
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
                lo:  1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
              eth0: 123456     100    0    0    0     0          0         0    654321     200    0    0    0     0       0          0
            """
        #expect(SystemLoad.parseProcNetDev(dev) == ["eth0": .init(received: 123_456, sent: 654_321)])
        let before = SystemLoad.Sample(date: Date(timeIntervalSince1970: 0), interfaces: ["en0": .init(received: 1000, sent: UInt64(UInt32.max) - 99)])
        let after = SystemLoad.Sample(date: Date(timeIntervalSince1970: 2), interfaces: ["en0": .init(received: 3000, sent: 100)])
        let rates = SystemLoad.throughput(from: before, to: after)
        #expect(rates.received == 1000)
        #expect(rates.sent == 100)
    }

    @Test func offersTheSceneBuilderPrompt() async throws {
        let environment = try MCPTestEnvironment()
        let client = DirectClient(server: environment.server, scope: .read)
        try await client.initialize()
        let prompt = try await client.call("prompts/get", ["name": "scene-builder", "arguments": ["description": "movie night", "area": "Living Room"]])
        let text = prompt["messages"]?[0]?["content"]?["text"]?.stringValue ?? ""
        #expect(text.contains("\"movie night\""))
        #expect(text.contains("with room \"Living Room\""))
        #expect(text.contains("save_scene"))
        await #expect(throws: JSONRPCError.self) { try await client.call("prompts/get", ["name": "scene-builder"]) }
    }
}

@Suite struct SessionLimitTests {
    @Test func evictsTheLeastRecentlyUsedIdleSession() async throws {
        let server = MCPServer(options: .init(version: "test"), tools: [])
        let principal = Principal(name: "test", scope: .read)
        let first = try #require(server.makeSession(principal: principal, limit: 2))
        try await Task.sleep(for: .milliseconds(10))
        let second = try #require(server.makeSession(principal: principal, limit: 2))
        let third = try #require(server.makeSession(principal: principal, limit: 2))
        #expect(server.session(id: first.id) == nil)
        #expect(server.session(id: second.id) != nil)
        #expect(server.session(id: third.id) != nil)

        // Sessions holding a stream are busy: none can go, so a new one is refused.
        second.setStandingStream(true)
        third.setStandingStream(true)
        #expect(server.makeSession(principal: principal, limit: 2) == nil)
        third.setStandingStream(false)
        #expect(server.makeSession(principal: principal, limit: 2) != nil)
        #expect(server.session(id: third.id) == nil)
    }

    @Test func readsTheLimitsAndOverridesFromTheEnvironment() throws {
        let block: JSONValue = ["mcp": ["http": ["enabled": true, "token": "main", "maxSessions": 4, "sessionIdleMinutes": 10, "allowedOrigins": ["https://a.example"]]]]
        let plain = try MCPConfiguration(block: block, environment: [:])
        #expect(plain.maxSessions == 4)
        #expect(plain.sessionIdleMinutes == 10)
        #expect(MCPConfiguration().maxSessions == 32)
        #expect(MCPConfiguration().sessionIdleMinutes == 30)
        #expect(throws: MCPConfigurationError.self) { try MCPConfiguration(block: ["mcp": ["http": ["maxSessions": 0]]], environment: [:]) }

        let upstream = try MCPConfiguration(block: block, environment: [
            "HOMEBRIDGE_AI_MCP_MAX_SESSIONS": "8", "HOMEBRIDGE_AI_MCP_SESSION_IDLE_MINUTES": "5", "HOMEBRIDGE_READ_ONLY": "true",
            "HOMEBRIDGE_AI_MCP_TOKENS": "read:abc, control:def", "HOMEBRIDGE_AI_MCP_ALLOWED_ORIGINS": "https://b.example,https://c.example",
            "HOMEBRIDGE_AI_AUDIT_LOG": "/tmp/audit.jsonl",
        ])
        #expect(upstream.maxSessions == 8)
        #expect(upstream.sessionIdleMinutes == 5)
        #expect(upstream.readOnly)
        #expect(upstream.clients == [.init(name: "read-1", token: "abc", scope: .read), .init(name: "control-2", token: "def", scope: .control)])
        #expect(upstream.principal(for: "def") == Principal(name: "control-2", scope: .read))
        #expect(upstream.allowedOrigins == ["https://b.example", "https://c.example"])
        #expect(upstream.auditLogPath == "/tmp/audit.jsonl")

        // The HOMESWIFT_ names win over the upstream ones.
        let own = try MCPConfiguration(block: block, environment: ["HOMESWIFT_MCP_MAX_SESSIONS": "3", "HOMEBRIDGE_AI_MCP_MAX_SESSIONS": "8", "HOMESWIFT_READ_ONLY": "off"])
        #expect(own.maxSessions == 3)
        #expect(!own.readOnly)
        #expect(throws: MCPConfigurationError.self) { try MCPConfiguration(block: block, environment: ["HOMESWIFT_MCP_TOKENS": "root:abc"]) }
        #expect(throws: MCPConfigurationError.self) { try MCPConfiguration(block: block, environment: ["HOMESWIFT_MCP_MAX_SESSIONS": "lots"]) }

        let transport = MCPHTTPServer(server: MCPServer(options: .init(version: "test"), tools: []), configuration: upstream)
        #expect(transport.maxSessions == 8)
        #expect(transport.idleTimeout == .seconds(300))
    }
}
