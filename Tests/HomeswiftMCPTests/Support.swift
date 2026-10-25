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
        /// Colour lightbulbs `Devices:bulb1`…, for the moods; the last one fails every write when `failingBulb` is set.
        var colourBulbs: Int?
        var failingBulb: Bool?
        /// A colour bulb mirrored from Apple Home (`Devices:mirrored`, in the room Salon), as Wingman adds one.
        var mirroredBulb: Bool?
        /// A second one, `Devices:mirrored2`, in this room.
        var secondMirroredRoom: String?
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
        // A switch that unlocks the door (UniFi Access's Lock Trigger), marked as a security control, and a
        // characteristic whose value carries keys.
        let trigger = Service(.switch, name: "Door Trigger", subtype: "trigger", extra: [Characteristic(.setupEndpoints, value: "c3J0cC1tYXN0ZXIta2V5")])
        trigger.characteristic(.on).securityControl().onWrite { value in writes.withLockedValue { $0.append(("trigger.on", value)) } }
        try context.add(Accessory(id: "Devices:lock", name: "Front Door", category: .doorLock, services: [lock, trigger]))

        let bulbs = configuration.colourBulbs ?? 0
        for number in 0..<bulbs {
            let name = "bulb\(number + 1)"
            let fails = configuration.failingBulb == true && number == bulbs - 1
            let light = Service(.lightbulb, name: "Bulb \(number + 1)", optional: [.brightness, .hue, .saturation, .colorTemperature], isPrimary: true)
            light.characteristic(.on).value = .bool(false)
            light.characteristic(.brightness).value = .int(40)
            light.characteristic(.hue).value = .double(10)
            light.characteristic(.saturation).value = .double(20)
            light.characteristic(.colorTemperature).value = .int(300)
            for (type, key) in [(CharacteristicType.on, "on"), (.brightness, "brightness"), (.hue, "hue"), (.saturation, "saturation"), (.colorTemperature, "colorTemperature")] {
                light.characteristic(type).onWrite { value in
                    if fails { throw HAPStatusError(.serviceCommunicationFailure) }
                    writes.withLockedValue { $0.append(("\(name).\(key)", value)) }
                }
            }
            try context.add(Accessory(id: "Devices:\(name)", name: "Bulb \(number + 1)", category: .lightbulb, services: [light]))
        }

        if configuration.mirroredBulb == true {
            let light = Service(.lightbulb, name: "Ceiling Light", optional: [.brightness, .hue, .saturation, .colorTemperature], isPrimary: true)
            light.characteristic(.brightness).value = .int(70)
            for (type, key) in [(CharacteristicType.on, "on"), (.brightness, "brightness"), (.hue, "hue"), (.saturation, "saturation"), (.colorTemperature, "colorTemperature")] {
                light.characteristic(type).onWrite { value in writes.withLockedValue { $0.append(("mirrored.\(key)", value)) } }
            }
            let mirrored = Accessory(id: "Devices:mirrored", name: "Ceiling Light", category: .lightbulb, services: [light])
            mirrored.mirroredFrom = "Apple Home"
            mirrored.suggestedRoom = "Salon"
            try context.add(mirrored)
        }
        if let room = configuration.secondMirroredRoom {
            let second = Accessory(id: "Devices:mirrored2", name: "Floor Lamp", category: .lightbulb, services: [Service(.lightbulb, name: "Floor Lamp", isPrimary: true)])
            second.mirroredFrom = "Apple Home"
            second.suggestedRoom = room
            try context.add(second)
        }
    }

    static let assistantActions = [
        AssistantAction(
            name: "pair", title: "Pair a device", description: "Pairs the device at an address; answers its entry for the devices list.",
            method: "POST", path: "pair", access: .configure,
            inputSchema: ["type": "object", "required": ["ip"], "properties": ["ip": ["type": "string"]]]),
    ]

    /// `POST pair` hands out a password, as a TV does when it pairs.
    func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        guard request.method == "POST", request.path == "pair", let ip = request.body["ip"]?.stringValue else { return .error(404, "nothing there") }
        return PluginWebResponse(["device": ["ip": .string(ip), "mac": "AA:BB:CC:00:11:22", "username": "homeswift", "password": "s3cret-pass"]])
    }
}

/// A model that follows a script: each step answers a request with text or tool calls.
final class ScriptedProvider: Provider, @unchecked Sendable {
    let name = "scripted"
    let model = "scripted-1"
    let capabilities = ProviderCapabilities(streaming: false, contextTokens: 200_000)
    private let lock = NSLock()
    private var steps: [@Sendable (ChatRequest) -> ChatResult]
    private(set) var requests: [ChatRequest] = []

    init(_ steps: [@Sendable (ChatRequest) -> ChatResult]) {
        self.steps = steps
    }

    static func calls(_ calls: [HomeswiftAI.ToolCall]) -> @Sendable (ChatRequest) -> ChatResult {
        { _ in ChatResult(model: "scripted-1", text: "", toolCalls: calls, usage: TokenUsage(inputTokens: 100, outputTokens: 10), stopReason: .toolCalls) }
    }

    static func answer(_ text: String) -> @Sendable (ChatRequest) -> ChatResult {
        { _ in ChatResult(model: "scripted-1", text: text, toolCalls: [], usage: TokenUsage(inputTokens: 100, outputTokens: 10), stopReason: .end) }
    }

    func chat(_ request: ChatRequest) async throws -> ChatResult {
        let step = lock.withLock { () -> (@Sendable (ChatRequest) -> ChatResult)? in
            requests.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        return step?(request) ?? ChatResult(model: model, text: "(no more steps)", toolCalls: [], usage: .zero, stopReason: .end)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do { continuation.yield(.done(try await self.chat(request))) } catch { continuation.finish(throwing: error) }
                continuation.finish()
            }
        }
    }

    /// Everything the model was sent, as text.
    var sentText: String { lock.withLock { requests.map { $0.messages.map { "\($0)" }.joined() + ($0.system ?? "") }.joined() } }
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

    /// `config` replaces the default config.json; `schema` is the devices plugin's config.schema.json, `blockSchemas`
    /// the catalog's for blocks no plugin provides.
    init(elicitation: Bool = true, allowSecrets: Bool = false, config custom: String? = nil, schema: String? = nil, blockSchemas: [String: String] = [:],
         aiTransport: (any HTTPTransport)? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let auditURL = directory.appendingPathComponent("audit.jsonl")
        let config = custom ?? """
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
        registry.register(platform: DevicesPlugin.platform, name: DevicesPlugin.name, configurationSchemaJSON: schema, assistantActions: DevicesPlugin.assistantActions) { json, context in
            DevicesPlugin(configuration: try JSONDecoder().decode(DevicesPlugin.Configuration.self, from: json), context: context, writes: writes)
        }
        var hostOptions = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        hostOptions.aiTransport = aiTransport
        host = try PluginHost(
            configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory, options: hostOptions)
        catalog = HomeswiftCatalog(host: host, logs: logs, configURL: configURL, allowSecrets: allowSecrets, blockSchemas: blockSchemas, logger: testLogger)
        var options = MCPServer.Options(version: "test", instructions: HomeswiftCatalog.instructions)
        options.elicitation = elicitation
        options.logger = testLogger
        server = MCPServer(options: options, tools: catalog.tools, resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts, audit: AuditLog(url: auditURL, logger: testLogger))
        _ = catalog.attach(to: server)
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

/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
