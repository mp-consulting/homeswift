import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import HomeswiftUI
import Logging

// A whole bridge the way the `homeswift` CLI runs it: the plugin runtime, the web UI and the MCP server over one
// catalog, with a synthetic home instead of real devices, for `bridge-bench.py` to measure every endpoint.
//
// Environment: STORAGE (a directory, required), ACCESSORIES (default 60), PORT (HAP, 0 for any), UI_PORT
// (8591), MCP_PORT (8592), MCP_TOKEN, TICK_MS (a sensor changes and a line is logged that often, default 1000;
// 0 for none), LOG_LINES (lines logged before the server is ready, default 5000).

let env = ProcessInfo.processInfo.environment
guard let storagePath = env["STORAGE"] else {
    FileHandle.standardError.write(Data("STORAGE must name a directory\n".utf8))
    exit(1)
}
let storage = URL(fileURLWithPath: storagePath)
let count = Int(env["ACCESSORIES"] ?? "60") ?? 60
let uiPort = Int(env["UI_PORT"] ?? "8591") ?? 8591
let mcpPort = Int(env["MCP_PORT"] ?? "8592") ?? 8592
let token = env["MCP_TOKEN"] ?? "bench-token-0123456789abcdef0123456789abcdef"
let tickMilliseconds = Int(env["TICK_MS"] ?? "1000") ?? 1000

let logBuffer = LogBuffer(archive: LogArchive(directory: storage.appendingPathComponent("logs")))
LoggingSystem.bootstrap { label in
    var handler = BenchLogHandler(label: label, buffer: logBuffer)
    handler.logLevel = .debug
    return handler
}
let logger = Logger(label: "homeswift")

/// Like the CLI's handler, without the terminal: the buffer and the archive are what the endpoints read.
struct BenchLogHandler: LogHandler {
    let label: String
    let buffer: LogBuffer
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var line = event.message.description
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        if !merged.isEmpty { line += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
        buffer.append(LogBuffer.Line(level: event.level, label: label, text: line))
    }
}

/// A home of mixed accessories: lights, switches, outlets, thermostats, sensors, blinds, fans, purifiers.
actor BenchHomePlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {
        var accessories: Int?
        var tickMilliseconds: Int?
    }

    static let platform = "BenchHome"
    static let name = "Bench Home"

    let configuration: Configuration
    let context: PluginContext
    private var ticker: Task<Void, Never>?

    init(configuration: Configuration, context: PluginContext) async throws {
        self.configuration = configuration
        self.context = context
    }

    func start() async throws {
        let total = configuration.accessories ?? 60
        var sensors: [Characteristic] = []
        for index in 0..<total {
            let (accessory, sensor) = Self.makeAccessory(index)
            try context.add(accessory)
            if let sensor { sensors.append(sensor) }
        }
        context.logger.info("Added accessories", metadata: ["count": "\(total)"])
        let interval = configuration.tickMilliseconds ?? 1000
        guard interval > 0, !sensors.isEmpty else { return }
        let logger = context.logger
        ticker = Task { [sensors] in
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                let sensor = sensors[step % sensors.count]
                let value = 18 + Double(step % 80) / 10
                sensor.value = .double(value)
                logger.debug("Sensor reading", metadata: ["sensor": "\(step % sensors.count)", "value": "\(value)"])
                step += 1
            }
        }
    }

    func stop() async {
        ticker?.cancel()
    }

    /// The accessory at `index`, and the characteristic the ticker moves when it has one.
    static func makeAccessory(_ index: Int) -> (Accessory, Characteristic?) {
        let id = "BenchHome:\(String(format: "%04d", index))"
        func noop(_ service: Service) -> Service {
            for characteristic in service.characteristics { characteristic.onWrite { _ in } }
            return service
        }
        switch index % 8 {
        case 0:
            let light = noop(Service(.lightbulb, name: "Lamp \(index)", optional: [.brightness, .hue, .saturation, .colorTemperature], isPrimary: true))
            return (Accessory(id: id, name: "Lamp \(index)", manufacturer: "Bench", model: "Lamp", category: .lightbulb, services: [light]), nil)
        case 1:
            let outlet = noop(Service(.outlet, name: "Plug \(index)", optional: [.outletInUse]))
            return (Accessory(id: id, name: "Plug \(index)", manufacturer: "Bench", model: "Plug", category: .outlet, services: [outlet]), nil)
        case 2:
            let thermostat = noop(Service(.thermostat, name: "Climate \(index)", optional: [.currentRelativeHumidity, .coolingThresholdTemperature, .heatingThresholdTemperature]))
            return (Accessory(id: id, name: "Climate \(index)", manufacturer: "Bench", model: "Thermostat", category: .thermostat, services: [thermostat]),
                    thermostat.characteristic(.currentTemperature))
        case 3:
            let temperature = Service(.temperatureSensor, name: "Temperature \(index)", subtype: "temperature", optional: [.statusActive])
            let humidity = Service(.humiditySensor, name: "Humidity \(index)", subtype: "humidity")
            let battery = Service(.battery, name: "Battery \(index)")
            return (Accessory(id: id, name: "Sensor \(index)", manufacturer: "Bench", model: "Sensor", category: .sensor, services: [temperature, humidity, battery]),
                    temperature.characteristic(.currentTemperature))
        case 4:
            let blind = noop(Service(.windowCovering, name: "Blind \(index)", optional: [.obstructionDetected, .holdPosition]))
            return (Accessory(id: id, name: "Blind \(index)", manufacturer: "Bench", model: "Blind", category: .windowCovering, services: [blind]), nil)
        case 5:
            let fan = noop(Service(.fanv2, name: "Fan \(index)", optional: [.rotationSpeed, .swingMode, .targetFanState, .currentFanState]))
            return (Accessory(id: id, name: "Fan \(index)", manufacturer: "Bench", model: "Fan", category: .fan, services: [fan]), nil)
        case 6:
            let purifier = noop(Service(.airPurifier, name: "Purifier \(index)", optional: [.rotationSpeed, .lockPhysicalControls], isPrimary: true))
            let filter = Service(.filterMaintenance, name: "Filter \(index)", optional: [.filterLifeLevel])
            let quality = Service(.airQualitySensor, name: "Air \(index)", optional: [.pm2_5Density, .pm10Density, .vocDensity])
            return (Accessory(id: id, name: "Purifier \(index)", manufacturer: "Bench", model: "Purifier", category: .airPurifier, services: [purifier, filter, quality]),
                    quality.characteristic(.pm2_5Density))
        default:
            let first = noop(Service(.switch, name: "Switch \(index) A", subtype: "a"))
            let second = noop(Service(.switch, name: "Switch \(index) B", subtype: "b"))
            let contact = Service(.contactSensor, name: "Door \(index)")
            let motion = Service(.motionSensor, name: "Motion \(index)")
            return (Accessory(id: id, name: "Switches \(index)", manufacturer: "Bench", model: "Switches", category: .switch, services: [first, second, contact, motion]), nil)
        }
    }
}

// config.json, written fresh each launch: the bench bridge, the web UI without sign-in, the MCP server.
let configURL = storage.appendingPathComponent("config.json")
try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
let config: [String: Any] = [
    "bridge": ["name": "Bench Bridge", "username": "0E:BE:AC:00:00:01", "pin": "031-45-154", "port": Int(env["PORT"] ?? "0") ?? 0],
    "platforms": [
        ["platform": "HomeswiftUI", "host": "127.0.0.1", "port": uiPort, "auth": "none"],
        ["platform": "HomeswiftAiKit", "enabled": false, "mcp": ["http": ["enabled": true, "port": mcpPort, "token": token, "auditLog": false]]],
        ["platform": "BenchHome", "name": "Bench Home", "accessories": count, "tickMilliseconds": tickMilliseconds],
    ],
]
try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)
let configuration = try HomeswiftConfiguration.load(from: configURL)

var registry = PluginRegistry()
registry.register(BenchHomePlugin.self)
var hostOptions = PluginHost.Options(logger: logger)
hostOptions.advertise = env["ADVERTISE"] == "1"
hostOptions.systemPlatforms.insert(UIConfiguration.platform)
let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: storage, options: hostOptions)

let main = Task {
    // The log the endpoints read: as full as a bridge's after a while.
    let filler = Logger(label: "Bench Home")
    for index in 0..<(Int(env["LOG_LINES"] ?? "5000") ?? 5000) {
        filler.info("Warm-up line", metadata: ["index": "\(index)", "accessory": "Lamp \(index % max(1, count))"])
    }
    try await host.start()
    let catalog = HomeswiftCatalog(host: host, logs: logBuffer, configURL: configURL, logger: logger)

    let mcp = try MCPConfiguration(block: try configuration.block(for: AIConfiguration.platform) ?? [:])
    let server = MCPServer(
        options: MCPServer.Options(version: PluginHost.version, instructions: HomeswiftCatalog.instructions), tools: catalog.tools,
        resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts, audit: nil)
    let observations = catalog.attach(to: server)
    var transportOptions = MCPHTTPServer.Options(host: mcp.host, port: mcp.port, allowedOrigins: mcp.allowedOrigins)
    transportOptions.logger = logger
    let transport = MCPHTTPServer(server: server, configuration: mcp, options: transportOptions)
    transport.onStop { observations.forEach { $0.cancel() } }
    try await transport.start()

    let ui = try UIConfiguration(block: try configuration.block(for: UIConfiguration.platform) ?? [:])
    let uiServer = UIServer(configuration: ui, catalog: catalog, usersURL: storage.appendingPathComponent("ui-users.json"))
    try await uiServer.start()
    // The driver waits for this line.
    print("READY hap=\(host.mainBridge.server.port ?? 0) ui=\(uiServer.port ?? 0) mcp=\(transport.port ?? 0) pid=\(getpid())")
    fflush(stdout)
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
}

let signals = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    signal(number, SIG_IGN)
    source.setEventHandler { @Sendable [main, host] in
        main.cancel()
        Task {
            await host.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
dispatchMain()
