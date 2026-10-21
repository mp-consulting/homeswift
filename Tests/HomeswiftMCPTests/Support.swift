import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftMCP

let testLogger: Logger = {
    var logger = Logger(label: "homeswift.mcp")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A plugin with a lamp and a lock, for the tools.
actor DevicesPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {
        var name: String?
    }

    static let platform = "Devices"
    static let name = "Devices Plugin"

    let configuration: Configuration
    let context: PluginContext
    /// What HomeKit (or a tool) wrote, per test environment.
    let writes: NIOLockedValueBox<[(String, HAPValue)]>

    init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, writes: NIOLockedValueBox([]))
    }

    init(configuration: Configuration, context: PluginContext, writes: NIOLockedValueBox<[(String, HAPValue)]>) {
        self.configuration = configuration
        self.context = context
        self.writes = writes
    }

    func start() async throws {
        let writes = self.writes
        let lightbulb = Service(.lightbulb, name: "Desk Lamp", optional: [.brightness], isPrimary: true)
        lightbulb.characteristic(.brightness).value = .int(40)
        lightbulb.characteristic(.on).onWrite { value in writes.withLockedValue { $0.append(("lamp.on", value)) } }
        lightbulb.characteristic(.brightness).onWrite { value in writes.withLockedValue { $0.append(("lamp.brightness", value)) } }
        try context.add(Accessory(id: "Devices:lamp", name: "Desk Lamp", manufacturer: "Acme", model: "L1", category: .lightbulb, services: [lightbulb], onIdentify: {
            writes.withLockedValue { $0.append(("lamp.identify", .bool(true))) }
        }))

        let lock = Service(.lockMechanism, name: "Front Door", isPrimary: true)
        lock.characteristic(.lockTargetState).onWrite { value in writes.withLockedValue { $0.append(("lock.target", value)) } }
        try context.add(Accessory(id: "Devices:lock", name: "Front Door", category: .doorLock, services: [lock]))
    }
}

/// A host with the devices plugin, the catalog and an MCP server, in a temporary directory.
final class MCPTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-mcp-tests-\(UUID().uuidString)")
    let logs = LogBuffer()
    let writes = NIOLockedValueBox<[(String, HAPValue)]>([])
    let host: PluginHost
    let catalog: HomeswiftCatalog
    let server: MCPServer
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var auditURL: URL { directory.appendingPathComponent("audit.jsonl") }

    init(elicitation: Bool = true, allowSecrets: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let auditURL = directory.appendingPathComponent("audit.jsonl")
        let config = """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [
                { "platform": "Devices", "name": "Devices", "token": "secret-token" },
                { "platform": "Ghost", "name": "Nobody" },
                { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
              ]
            }
            """
        try Data(config.utf8).write(to: configURL)
        var registry = PluginRegistry()
        let writes = self.writes
        registry.register(platform: DevicesPlugin.platform, name: DevicesPlugin.name) { json, context in
            DevicesPlugin(configuration: try JSONDecoder().decode(DevicesPlugin.Configuration.self, from: json), context: context, writes: writes)
        }
        host = try PluginHost(
            configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory,
            options: .init(advertise: false, logger: testLogger) { _ in MemoryStorage() })
        catalog = HomeswiftCatalog(host: host, logs: logs, configURL: configURL, allowSecrets: allowSecrets, logger: testLogger)
        var options = MCPServer.Options(version: "test", instructions: HomeswiftCatalog.instructions)
        options.elicitation = elicitation
        options.logger = testLogger
        server = MCPServer(options: options, tools: catalog.tools, resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts, audit: AuditLog(url: auditURL, logger: testLogger))
        catalog.attach(to: server)
    }

    func start() async throws {
        try await host.start()
    }

    func stop() async {
        await host.stop()
    }

    var written: [(String, HAPValue)] { writes.withLockedValue { $0 } }

    var auditEntries: [JSONValue] {
        guard let text = try? String(contentsOf: auditURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONValue(string: String($0)) }
    }
}

/// Drives a session directly: sends a request and collects what the server emits.
struct DirectClient {
    let server: MCPServer
    let session: MCPSession
    let elicitation: Bool

    init(server: MCPServer, scope: Scope = .admin, elicitation: Bool = true) {
        self.server = server
        session = server.makeSession(principal: Principal(name: "test", scope: scope))
        self.elicitation = elicitation
    }

    func initialize() async throws {
        let capabilities: JSONValue = elicitation ? ["elicitation": [:]] : [:]
        let result = try await call("initialize", ["protocolVersion": "2025-06-18", "capabilities": capabilities, "clientInfo": ["name": "tests", "version": "1"]])
        #expect(result["protocolVersion"] == "2025-06-18")
        for await _ in server.handle(.notification(method: "notifications/initialized", params: nil), session: session) {}
    }

    /// Sends a request; answers any elicitation with `answer`; returns the result or throws the error.
    func call(_ method: String, _ params: JSONValue = [:], answer: JSONValue? = nil) async throws -> JSONValue {
        var result: JSONValue?
        var failure: JSONRPCError?
        var asked: [JSONRPCMessage] = []
        for await message in server.handle(.request(id: 1, method: method, params: params), session: session) {
            switch message {
            case .request(let id, "elicitation/create", _):
                asked.append(message)
                // The client's answer arrives as its own message on the session.
                let reply: JSONRPCMessage = answer.map { .response(id: id, result: $0) } ?? .response(id: id, result: ["action": "decline"])
                for await _ in server.handle(reply, session: session) {}
            case .response(_, let value): result = value
            case .failure(_, let error): failure = error
            default: break
            }
        }
        if let failure { throw failure }
        return result ?? .null
    }

    func tool(_ name: String, _ arguments: JSONValue = [:], answer: JSONValue? = nil) async throws -> JSONValue {
        try await call("tools/call", ["name": .string(name), "arguments": arguments], answer: answer)
    }
}

func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
