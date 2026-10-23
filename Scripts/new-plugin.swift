// Creates a plugin: Plugins/<Name>/ with a skeleton that builds and passes its tests, its two targets in
// Package.swift, the library in the `homeswift` executable's dependencies and its registration in
// Sources/HomeswiftCLI/Plugins.swift. Run from the repository root:
//
//   swift Scripts/new-plugin.swift <Name> [<platform> [<display name>]]
//   swift Scripts/new-plugin.swift CameraFFmpeg Camera-ffmpeg "Camera FFmpeg"
//
// <Name> names the directory and the targets (`Homeswift<Name>`, `<Name>Tests`). The platform defaults to it; a
// port keeps the Homebridge plugin's `pluginAlias`. Then `swift test --filter <Name>Tests` and the TODOs: the
// skeleton polls a fake API and puts a switch per device in HomeKit, which the port replaces with the real thing.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("new-plugin: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (1...3).contains(arguments.count) else {
    fail("usage: swift Scripts/new-plugin.swift <Name> [<platform> [<display name>]]")
}
let name = arguments[0]
let platform = arguments.count > 1 ? arguments[1] : name
let display = arguments.count > 2 ? arguments[2] : name

guard name.range(of: "^[A-Z][A-Za-z0-9]*$", options: .regularExpression) != nil else {
    fail("<Name> is a Swift type name: a capital letter, then letters and digits (\(name))")
}
guard platform.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
    fail("the platform is letters, digits, '.', '_' and '-' (\(platform))")
}
guard !display.isEmpty, !display.contains(where: { "\"\\\n".contains($0) }) else {
    fail("the display name has no quotes, backslashes or newlines")
}

let files = FileManager.default
guard files.fileExists(atPath: "Package.swift"), files.fileExists(atPath: "Scripts/embed-assets.swift") else {
    fail("run from the repository root")
}
let directory = "Plugins/\(name)"
guard !files.fileExists(atPath: directory) else { fail("\(directory) exists") }
for plugin in (try? files.contentsOfDirectory(atPath: "Plugins")) ?? [] {
    let sources = "Plugins/\(plugin)/Sources"
    for file in (try? files.contentsOfDirectory(atPath: sources)) ?? [] where file.hasSuffix(".swift") {
        let text = (try? String(contentsOfFile: "\(sources)/\(file)", encoding: .utf8)) ?? ""
        if text.contains("static let platform = \"\(platform)\"") { fail("Plugins/\(plugin) has the platform \(platform)") }
    }
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text
}

/// `text` with `insertion` before the first line that contains `anchor`.
func insert(_ insertion: String, before anchor: String, in text: String, file: String) -> String {
    guard let line = text.range(of: anchor) else { fail("\(file) has no \"\(anchor)\"; add the entries by hand") }
    let start = text[..<line.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    var text = text
    text.insert(contentsOf: insertion, at: start)
    return text
}

// Package.swift: the library product, the target, the CLI's dependency and the test target. Everything is
// changed in memory first, so a missing anchor leaves the repository as it was.
var package = read("Package.swift")
guard !package.contains("\"Homeswift\(name)\"") else { fail("Package.swift has Homeswift\(name)") }
package = insert(
    "        .library(name: \"Homeswift\(name)\", targets: [\"Homeswift\(name)\"]),\n",
    before: ".executable(name: \"homeswift\"", in: package, file: "Package.swift")
package = insert(
    """
            .target(
                name: "Homeswift\(name)",
                dependencies: ["Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", .product(name: "Logging", package: "swift-log")],
                path: "\(directory)/Sources"
            ),

    """,
    before: "// The `homeswift` bridge", in: package, file: "Package.swift")
guard let cli = package.range(of: "name: \"HomeswiftCLI\""),
      let dependencies = package.range(of: "\"Homeswift\", \"HomeswiftPlugin\"", range: cli.upperBound..<package.endIndex),
      let lineEnd = package[dependencies.upperBound...].firstIndex(of: "\n")
else { fail("Package.swift: cannot find the HomeswiftCLI target's dependencies") }
package.insert(contentsOf: " \"Homeswift\(name)\",", at: lineEnd)
guard let end = package.range(of: "\n    ]\n)", options: .backwards) else { fail("Package.swift: cannot find the end of the targets") }
package.insert(contentsOf: """

        .testTarget(
            name: "\(name)Tests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "Homeswift\(name)",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "\(directory)/Tests"
        ),
""", at: end.lowerBound)

// Plugins.swift: the import among the others, in order, and the registration last.
var registry = read("Sources/HomeswiftCLI/Plugins.swift")
var lines = registry.components(separatedBy: "\n")
guard let firstImport = lines.firstIndex(where: { $0.hasPrefix("import ") }) else { fail("Plugins.swift has no imports") }
let lastImport = lines.lastIndex(where: { $0.hasPrefix("import ") })!
let imports = (lines[firstImport...lastImport] + ["import Homeswift\(name)"]).sorted()
lines.replaceSubrange(firstImport...lastImport, with: imports)
registry = insert("    registry.register(\(name)Plugin.self)\n", before: "    return registry", in: lines.joined(separator: "\n"), file: "Plugins.swift")

// The plugin's files.
func template(_ text: String) -> String {
    text.replacingOccurrences(of: "__NAME__", with: name)
        .replacingOccurrences(of: "__PLATFORM__", with: platform)
        .replacingOccurrences(of: "__DISPLAY__", with: display)
}

let readme = #"""
# __DISPLAY__

TODO: the devices this plugin puts in HomeKit, how it reaches them (the local network, a cloud) and what the Home
app shows.

A port of [`TODO`](https://github.com/TODO) (TODO: its license; keep its copyright notice below). The platform block
is the same, so a Homebridge configuration works unchanged.

**Maintainer:** @TODO, who has the hardware and answers this plugin's issues. **Status:** experimental until someone
with the device confirms it works.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "__PLATFORM__",
      "name": "__DISPLAY__",
      "devices": [{ "id": "TODO", "name": "Desk Lamp" }]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `pollingInterval` | 30 | Seconds between polls, 5 at least |
| `devices` | | `id` and `name` of a device, to rename it |

## Tests

`swift test --filter __NAME__Tests` runs the plugin against a fake API, with no device or account.

"""#

let schema = #"""
{
  "pluginAlias": "__PLATFORM__",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "__DISPLAY__"
      },
      "pollingInterval": {
        "title": "Polling Interval (seconds)",
        "type": "integer",
        "required": false,
        "placeholder": 30,
        "minimum": 5
      },
      "devices": {
        "title": "Devices",
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "id": { "title": "ID", "type": "string", "required": true },
            "name": { "title": "Name", "type": "string" }
          }
        }
      }
    }
  }
}

"""#

let api = #"""
import Foundation

/// A device as the API reports it.
struct __NAME__Device: Sendable, Equatable {
    var id: String
    var name: String
    var isOn: Bool
}

/// How the plugin reaches its devices; tests use a fake. TODO: the real transport, on HomeswiftNetwork's
/// `HTTPClient`, `MQTTClient`, `WebSocket` or `UDPSocket` rather than a new package.
protocol __NAME__API: Sendable {
    func devices() async throws -> [__NAME__Device]
    func setOn(_ on: Bool, deviceID: String) async throws
}

/// Until the transport is written: every call fails, so the devices answer No Response.
struct Unimplemented__NAME__API: __NAME__API {
    struct NotImplemented: Error, CustomStringConvertible {
        var description: String { "the __DISPLAY__ API is not implemented yet" }
    }

    func devices() async throws -> [__NAME__Device] { throw NotImplemented() }
    func setOn(_ on: Bool, deviceID: String) async throws { throw NotImplemented() }
}

"""#

let plugin = #"""
import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// TODO: what this plugin puts in HomeKit and how it reaches the devices.
///
/// The configuration is the one of `TODO: the Homebridge plugin`, so a Homebridge block works unchanged.
/// See README.md in this directory.
public actor __NAME__Plugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            public var id: String
            /// Overrides the name the device reports.
            public var name: String?
        }

        public var name: String?
        /// Seconds between polls; 5 at least, 30 by default.
        public var pollingInterval: Int?
        public var devices: [Device]?
    }

    /// What the plugin uses to reach its devices; tests swap it for a fake.
    struct Dependencies: Sendable {
        var api: any __NAME__API = Unimplemented__NAME__API()
    }

    public static let platform = "__PLATFORM__"
    public static let name = "__DISPLAY__"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingInterval = 30
    static let minimumPollingInterval = 5

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    /// Each device's switch, by device id.
    private var switches: [String: Service] = [:]
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    var pollingInterval: Duration {
        .seconds(max(configuration.pollingInterval ?? Self.defaultPollingInterval, Self.minimumPollingInterval))
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    public func start() async throws {
        let interval = pollingInterval
        tasks.add { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    /// Adds an accessory for each new device and sets the values of the others.
    func refresh() async {
        let devices: [__NAME__Device]
        do {
            devices = try await dependencies.api.devices()
        } catch {
            logger.warning("Could not list the devices: \(error)")
            return
        }
        for device in devices {
            if let service = switches[device.id] {
                service.characteristic(.on).value = .bool(device.isOn)
                continue
            }
            do {
                try add(device)
            } catch {
                logger.error("Could not add \(device.name): \(error)")
            }
        }
        // TODO: once a device is known to be gone, `context.removeAccessories(keeping:)` drops its accessory.
    }

    private func add(_ device: __NAME__Device) throws {
        let name = configuration.devices?.first { $0.id == device.id }?.name ?? device.name
        let service = Service(.switch, name: name, isPrimary: true)
        service.characteristic(.on).value = .bool(device.isOn)
        let api = dependencies.api
        service.characteristic(.on).onWrite(changesOnly: true) { value in
            try await api.setOn(value.boolValue ?? false, deviceID: device.id)
        }
        try context.add(Accessory(
            id: Self.accessoryID(deviceID: device.id), name: name, manufacturer: "TODO", model: "TODO",
            serialNumber: device.id, category: .switch, services: [service]))
        switches[device.id] = service
    }
}

"""#

let tests = #"""
import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import Homeswift__NAME__

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The devices in memory.
actor FakeAPI: __NAME__API {
    private(set) var list = [__NAME__Device(id: "dev-1", name: "Desk Lamp", isOn: false)]
    private(set) var writes: [Bool] = []

    func devices() -> [__NAME__Device] { list }

    func setOn(_ on: Bool, deviceID: String) {
        writes.append(on)
        set(isOn: on, deviceID: deviceID)
    }

    /// A change made elsewhere, in the device's own app.
    func set(isOn: Bool, deviceID: String) {
        for index in list.indices where list[index].id == deviceID { list[index].isOn = isOn }
    }
}

/// A host with one platform block whose plugin talks to `api`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-__NAME__-tests-\(UUID().uuidString)")
    let api = FakeAPI()
    private let plugins = NIOLockedValueBox<[__NAME__Plugin]>([])

    var plugin: __NAME__Plugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: __NAME__Plugin.platform, name: __NAME__Plugin.name) { json, context in
            let configuration = try JSONDecoder().decode(__NAME__Plugin.Configuration.self, from: json)
            let plugin = __NAME__Plugin(configuration: configuration, context: context, dependencies: .init(api: self.api))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: __NAME__Plugin.platform, name: __NAME__Plugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct __NAME__Tests {
    let environment = TestEnvironment()
    let accessoryID = __NAME__Plugin.accessoryID(deviceID: "dev-1")

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(__NAME__Plugin.Configuration.self, from: Data(#"{"platform":"__PLATFORM__"}"#.utf8))
        #expect(configuration.devices == nil)
        let tooFast = try JSONDecoder().decode(__NAME__Plugin.Configuration.self, from: Data(#"{"pollingInterval":1}"#.utf8))
        #expect(tooFast.pollingInterval == 1)
    }

    @Test func eachDeviceBecomesAnAccessory() async throws {
        let host = try await environment.start(settings: ["devices": [["id": "dev-1", "name": "Lamp"]]])
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(accessoryID == "__PLATFORM__:dev-1")
        #expect(accessory.information.characteristic(.name).value == .string("Lamp"))
        await host.stop()
    }

    @Test func writesReachTheDeviceAndChangesComeBack() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let on = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID }?.service(.switch)?.characteristic(.on))

        try await on.writeHandler(for: .bool(true))?(.bool(true))
        #expect(await environment.api.writes == [true])

        await environment.api.set(isOn: false, deviceID: "dev-1")
        await environment.plugin?.refresh()
        #expect(on.value == .bool(false))
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(__NAME__Plugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/__NAME__ __NAME__Plugin")
        let schema = try JSONValue(string: try #require(__NAME__Plugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "__PLATFORM__")
    }
}

"""#

do {
    try files.createDirectory(atPath: "\(directory)/Sources", withIntermediateDirectories: true)
    try files.createDirectory(atPath: "\(directory)/Tests", withIntermediateDirectories: true)
    for (path, text) in [
        "README.md": readme, "config.schema.json": schema,
        "Sources/\(name)Plugin.swift": plugin, "Sources/\(name)API.swift": api, "Tests/\(name)Tests.swift": tests,
    ] {
        try template(text).write(toFile: "\(directory)/\(path)", atomically: true, encoding: .utf8)
    }
    try package.write(toFile: "Package.swift", atomically: true, encoding: .utf8)
    try registry.write(toFile: "Sources/HomeswiftCLI/Plugins.swift", atomically: true, encoding: .utf8)
} catch {
    fail("\(error)")
}

// ConfigurationSchema.swift, as the embed script writes it.
let embed = Process()
embed.executableURL = URL(fileURLWithPath: "/usr/bin/env")
embed.arguments = ["swift", "Scripts/embed-assets.swift", "plugin", directory, "\(name)Plugin"]
do {
    try embed.run()
    embed.waitUntilExit()
} catch {
    fail("could not run the embed script: \(error)")
}
guard embed.terminationStatus == 0 else {
    fail("the embed script failed; run: swift Scripts/embed-assets.swift plugin \(directory) \(name)Plugin")
}

print("""
    Created \(directory) (platform \(platform)) and registered it in Package.swift and Sources/HomeswiftCLI/Plugins.swift.
    Next: swift test --filter \(name)Tests, then the TODOs in \(directory). docs/plugins.md and CONTRIBUTING.md say what a
    plugin needs before its pull request.
    """)
