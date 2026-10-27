// Creates a plugin: Plugins/<Name>/ with a skeleton that builds and passes its tests, its two targets in
// Package.swift, the library in the `homeswift` executable's dependencies and its registration in
// Sources/HomeswiftCLI/Plugins.swift. Run from the repository root:
//
//   swift Scripts/new-plugin.swift <Name> [<platform> [<display name>]] [--service <service>[:<characteristic>,…]]…
//   swift Scripts/new-plugin.swift Lights Lights "Lights" --service lightbulb:brightness,colorTemperature --service battery
//   swift Scripts/new-plugin.swift --list                  the services it can generate
//   swift Scripts/new-plugin.swift --list thermostat       a service's characteristics, with their formats and ranges
//
// <Name> names the directory and the targets (`Homeswift<Name>`, `<Name>Tests`). The platform defaults to it; a
// port keeps the Homebridge plugin's `pluginAlias`. Each `--service` adds a HAP service to every device's accessory,
// with its required characteristics and the optional ones listed (`all` for every one); the first is the primary
// service, the others are linked to it. Without one, each device is a switch. The services and characteristics come
// from Sources/Homeswift/Model/Definitions.swift (HAP-NodeJS's), so the device state, the API's changes, the write
// handlers and the tests match them. Then `swift test --filter <Name>Tests` and the TODOs.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("new-plugin: \(message)\n".utf8))
    exit(1)
}

// MARK: - HAP definitions

struct CharacteristicDefinition {
    var name: String
    var title: String
    var format: String
    var permissions: [String]
    var unit: String?
    var minValue: Double?
    var maxValue: Double?
    var minStep: Double?
    var validValues: [Int]?

    var isReadable: Bool { permissions.contains("pairedRead") }
    var isWritable: Bool { permissions.contains("pairedWrite") }

    /// The Swift type of its value in the device state; nil for TLV8 and data, which a skeleton cannot model.
    var swiftType: String? {
        switch format {
        case "bool": "Bool"
        case "int", "uint8", "uint16", "uint32", "uint64": "Int"
        case "float": "Double"
        case "string": "String"
        default: nil
        }
    }
}

struct ServiceDefinition {
    var name: String
    var title: String
    var required: [String]
    var optional: [String]
}

let definitionsPath = "Sources/Homeswift/Model/Definitions.swift"
guard let definitionsText = try? String(contentsOfFile: definitionsPath, encoding: .utf8) else {
    fail("cannot read \(definitionsPath): run from the repository root")
}

func match(_ pattern: String, in text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<result.numberOfRanges).map { index in
        Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}

func names(_ list: String) -> [String] {
    list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
}

var characteristics: [String: CharacteristicDefinition] = [:]
var services: [String: ServiceDefinition] = [:]
var constants: [String: [(name: String, value: Int)]] = [:]
var currentEnum: String?
for line in definitionsText.components(separatedBy: "\n") {
    if let groups = match(#"public static let (\w+) = CharacteristicType\(name: "([^"]+)", uuid: [^,]+, format: \.(\w+), permissions: \[([^\]]*)\](.*)\)$"#, in: line) {
        let rest = groups[5]
        func number(_ key: String) -> Double? { match(key + #": (-?[0-9.]+)"#, in: rest).flatMap { Double($0[1]) } }
        characteristics[groups[1]] = CharacteristicDefinition(
            name: groups[1], title: groups[2], format: groups[3], permissions: names(groups[4]),
            unit: match(#"unit: \.(\w+)"#, in: rest)?[1], minValue: number("minValue"), maxValue: number("maxValue"),
            minStep: number("minStep"), validValues: match(#"validValues: \[([^\]]*)\]"#, in: rest).map { names($0[1]).compactMap { Int($0) } })
    } else if let groups = match(#"public static let `?(\w+)`? = ServiceType\(name: "([^"]+)", uuid: [^,]+, required: \[([^\]]*)\], optional: \[([^\]]*)\]\)"#, in: line) {
        services[groups[1]] = ServiceDefinition(name: groups[1], title: groups[2], required: names(groups[3]), optional: names(groups[4]))
    } else if let groups = match(#"^    public enum (\w+) \{"#, in: line) {
        currentEnum = groups[1]
    } else if let enumName = currentEnum, let groups = match(#"public static let (\w+): Int = (-?\d+)"#, in: line) {
        constants[enumName, default: []].append((groups[1], Int(groups[2])!))
    } else if line.hasPrefix("    }") {
        currentEnum = nil
    }
}
guard !characteristics.isEmpty, !services.isEmpty else { fail("could not read the definitions in \(definitionsPath)") }

/// Services a skeleton cannot model: a required characteristic is TLV8 or data (pairing, cameras, Siri, …).
func unsupportedReason(_ service: ServiceDefinition) -> String? {
    if service.name == "accessoryInformation" { return "the runtime adds it to every accessory" }
    let infrastructure: Set = [
        "accessControl", "assetUpdate", "assistant", "protocolInformation", "serviceLabel", "siri", "tunnel", "wiFiSatellite",
        "wiFiTransport",
    ]
    if infrastructure.contains(service.name) { return "it belongs to the HAP protocol, not to a device" }
    if ["cameraOperatingMode", "cameraRecordingManagement", "microphone"].contains(service.name) {
        return "cameras get it from `CameraController` (see Plugins/UniFiProtect)"
    }
    let opaque = service.required.filter { characteristics[$0]?.swiftType == nil }
    return opaque.isEmpty ? nil : "\(opaque.joined(separator: ", ")) \(opaque.count == 1 ? "is" : "are") TLV8 or data"
}

/// What to read before going further with some services.
let serviceNotes: [String: String] = [
    "television": "A Television is published on its own with `context.publishExternal`, with InputSource services linked to it: see Plugins/PhilipsAmbilightTV.",
    "inputSource": "Input sources are linked to a Television: see Plugins/PhilipsAmbilightTV.",
    "doorbell": "A doorbell with video is a camera: see `DoorbellController` and Plugins/UniFiProtect.",
    "lockMechanism": "Lock Target State is a security control: the MCP server and the Assistant write it only through set_security_accessory.",
    "garageDoorOpener": "Target Door State is a security control: the MCP server and the Assistant write it only through set_security_accessory.",
    "securitySystem": "Security System Target State is a security control: the MCP server and the Assistant write it only through set_security_accessory.",
    "statelessProgrammableSwitch": "A button: set Programmable Switch Event's value when the device reports a press (0 single, 1 double, 2 long).",
]

func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

let unitNames = ["percentage": "%", "celsius": "°C", "arcdegrees": "°", "lux": "lux", "seconds": "s"]

func describe(_ characteristic: CharacteristicDefinition) -> String {
    var parts: [String] = []
    if let values = characteristic.validValues, let named = constants[characteristic.name.prefix(1).uppercased() + characteristic.name.dropFirst()] {
        let labels = values.map { value in "\(value) \(named.first { $0.value == value }?.name ?? "?")" }
        parts.append(labels.joined(separator: ", "))
    } else if let values = characteristic.validValues {
        parts.append(values.map(String.init).joined(separator: ", "))
    } else if let minimum = characteristic.minValue, let maximum = characteristic.maxValue {
        // HAP gives Color Temperature no unit; it is in mireds (1,000,000 / kelvin).
        let unit = characteristic.name == "colorTemperature" ? "mired" : characteristic.unit.flatMap { unitNames[$0] }
        parts.append("\(formatNumber(minimum)) to \(formatNumber(maximum))" + (unit.map { " \($0)" } ?? ""))
    } else if let unit = characteristic.unit.flatMap({ unitNames[$0] }) {
        parts.append(unit)
    }
    return parts.joined(separator: "; ")
}

// MARK: - Arguments

var positional: [String] = []
var serviceSpecs: [String] = []
var listing: String??
var argumentIterator = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let argument = argumentIterator.next() {
    switch argument {
    case "--service", "-s":
        guard let spec = argumentIterator.next() else { fail("--service needs <service>[:<characteristic>,…]") }
        serviceSpecs.append(spec)
    case "--list":
        listing = .some(nil)
    case let flag where flag.hasPrefix("-"):
        fail("unknown option \(flag)")
    default:
        if case .some(nil) = listing, positional.isEmpty { listing = .some(argument) } else { positional.append(argument) }
    }
}

if let listing {
    if let name = listing {
        guard let service = services[name] else { fail("no service \(name); swift Scripts/new-plugin.swift --list") }
        print("\(service.name) (\(service.title))" + (unsupportedReason(service).map { ": not generated, \($0)" } ?? ""))
        for (heading, list) in [("required", service.required), ("optional", service.optional)] {
            print("  \(heading):")
            for characteristicName in list {
                guard let characteristic = characteristics[characteristicName] else { continue }
                let access = [characteristic.isReadable ? "read" : nil, characteristic.isWritable ? "write" : nil].compactMap { $0 }.joined(separator: "/")
                let note = characteristic.swiftType == nil ? "not generated" : describe(characteristic)
                print("    \(characteristicName.padding(toLength: 34, withPad: " ", startingAt: 0)) \(characteristic.format.padding(toLength: 7, withPad: " ", startingAt: 0)) \(access.padding(toLength: 11, withPad: " ", startingAt: 0)) \(note)")
            }
        }
        if let note = serviceNotes[name] { print("  \(note)") }
    } else {
        for service in services.values.sorted(by: { $0.name < $1.name }) where unsupportedReason(service) == nil {
            print("\(service.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(service.required.joined(separator: ", "))")
        }
        print("\nswift Scripts/new-plugin.swift --list <service> shows its characteristics.")
    }
    exit(0)
}

guard (1...3).contains(positional.count) else {
    fail("usage: swift Scripts/new-plugin.swift <Name> [<platform> [<display name>]] [--service <service>[:<characteristic>,…]]… | --list [<service>]")
}
let name = positional[0]
let platform = positional.count > 1 ? positional[1] : name
let display = positional.count > 2 ? positional[2] : name

guard name.range(of: "^[A-Z][A-Za-z0-9]*$", options: .regularExpression) != nil else {
    fail("<Name> is a Swift type name: a capital letter, then letters and digits (\(name))")
}
guard platform.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
    fail("the platform is letters, digits, '.', '_' and '-' (\(platform))")
}
guard !display.isEmpty, !display.contains(where: { "\"\\\n".contains($0) }) else {
    fail("the display name has no quotes, backslashes or newlines")
}

// MARK: - The services to generate

let keywords: Set<String> = ["switch", "default", "case", "in", "is", "as", "for", "if", "do", "repeat", "return", "where", "class", "struct", "enum", "protocol", "import", "self", "Self", "true", "false", "nil", "try", "throw", "init", "deinit", "let", "var", "func", "operator", "extension", "subscript", "static", "public", "private", "internal", "fileprivate", "while", "break", "continue", "fallthrough", "guard", "defer", "typealias", "associatedtype", "inout", "Any", "super", "catch", "throws", "rethrows"]

func escaped(_ identifier: String) -> String { keywords.contains(identifier) ? "`\(identifier)`" : identifier }
func capitalized(_ identifier: String) -> String { identifier.prefix(1).uppercased() + identifier.dropFirst() }

struct Chosen {
    var definition: ServiceDefinition
    /// Required, then the optional ones asked for; Name is the service's own, TLV8 and data are left out.
    var characteristics: [CharacteristicDefinition]
    var optional: [String]

    /// The name in a declaration or at the start of an expression; after a dot, `definition.name` needs no escaping.
    var property: String { escaped(definition.name) }
    var typeName: String { capitalized(definition.name) }
    var state: [CharacteristicDefinition] { characteristics.filter(\.isReadable) }
}

var chosen: [Chosen] = []
for spec in serviceSpecs.isEmpty ? ["switch"] : serviceSpecs {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard let service = services[parts[0]] else {
        fail("no service \(parts[0]); swift Scripts/new-plugin.swift --list shows them")
    }
    if let reason = unsupportedReason(service) { fail("\(service.name) cannot be generated: \(reason)") }
    guard !chosen.contains(where: { $0.definition.name == service.name }) else {
        fail("\(service.name) is listed twice; add a second one by hand, with a subtype")
    }
    // Name is the service's own; the transition count goes with Adaptive Lighting's TLV8 characteristics.
    let usable = service.optional.filter { !["name", "characteristicValueActiveTransitionCount"].contains($0) && characteristics[$0]?.swiftType != nil }
    var optional: [String] = []
    if parts.count > 1 {
        let asked = names(parts[1])
        optional = asked == ["all"] ? usable : asked
        for characteristic in optional where !usable.contains(characteristic) {
            fail("\(service.name) has no optional characteristic \(characteristic) a skeleton can model; it has: \(usable.joined(separator: ", "))")
        }
    }
    let list = (service.required + optional).compactMap { characteristics[$0] }.filter { $0.name != "name" && $0.swiftType != nil }
    chosen.append(Chosen(definition: service, characteristics: list, optional: optional))
}
let primary = chosen[0]
let writable = chosen.flatMap { service in service.characteristics.filter(\.isWritable).map { (service, $0) } }
let multipleServices = chosen.count > 1

/// The case of `<Name>Change` for a writable characteristic.
func changeCase(_ service: Chosen, _ characteristic: CharacteristicDefinition) -> String {
    multipleServices ? service.definition.name + capitalized(characteristic.name) : escaped(characteristic.name)
}

func defaultLiteral(_ characteristic: CharacteristicDefinition) -> String {
    switch characteristic.swiftType {
    case "Bool": return "false"
    case "String": return "\"\""
    default:
        if let first = characteristic.validValues?.first { return String(first) }
        // 0, or the nearest bound when the range leaves it out (a target temperature starts at 10).
        let value = min(max(0, characteristic.minValue ?? -.infinity), characteristic.maxValue ?? .infinity)
        if characteristic.swiftType == "Int" { return String(Int(value)) }
        return value == value.rounded() ? String(format: "%.1f", value) : String(value)
    }
}

/// A valid value other than the default, for the tests.
func testLiteral(_ characteristic: CharacteristicDefinition) -> String {
    let standard = defaultLiteral(characteristic)
    switch characteristic.swiftType {
    case "Bool": return "true"
    case "String": return "\"Test\""
    case "Int":
        if let values = characteristic.validValues { return String(values.last { String($0) != standard } ?? values[0]) }
        if let maximum = characteristic.maxValue, formatNumber(maximum) != standard { return formatNumber(maximum) }
        return String((Int(standard) ?? 0) + 1)
    default:
        if let maximum = characteristic.maxValue { return String(format: "%.1f", maximum) }
        return String(format: "%.1f", (Double(standard) ?? 0) + 1)
    }
}

func hapValue(_ expression: String, _ characteristic: CharacteristicDefinition) -> String {
    switch characteristic.swiftType {
    case "Bool": ".bool(\(expression))"
    case "Int": ".int(\(expression))"
    case "Double": ".double(\(expression))"
    default: ".string(\(expression))"
    }
}

func fromHAPValue(_ characteristic: CharacteristicDefinition) -> String {
    switch characteristic.swiftType {
    case "Bool": "value.boolValue ?? false"
    case "Int": "value.intValue ?? 0"
    case "Double": "value.doubleValue ?? 0"
    default: "value.stringValue ?? \"\""
    }
}

/// How a test reads a characteristic's value back.
func valueAccessor(_ characteristic: CharacteristicDefinition) -> String {
    switch characteristic.swiftType {
    case "Bool": "boolValue"
    case "Int": "intValue"
    case "Double": "doubleValue"
    default: "stringValue"
    }
}

let categories: [String: String] = [
    "lightbulb": "lightbulb", "switch": "switch", "outlet": "outlet", "thermostat": "thermostat", "fan": "fan", "fanv2": "fan",
    "garageDoorOpener": "garageDoorOpener", "lockMechanism": "doorLock", "door": "door", "window": "window",
    "windowCovering": "windowCovering", "securitySystem": "securitySystem", "airPurifier": "airPurifier",
    "heaterCooler": "airConditioner", "humidifierDehumidifier": "humidifier", "valve": "sprinkler", "irrigationSystem": "sprinkler",
    "faucet": "faucet", "television": "television", "speaker": "speaker", "smartSpeaker": "speaker",
    "statelessProgrammableSwitch": "programmableSwitch", "statefulProgrammableSwitch": "programmableSwitch", "doorbell": "videoDoorbell",
    "airQualitySensor": "sensor", "carbonDioxideSensor": "sensor", "carbonMonoxideSensor": "sensor", "contactSensor": "sensor",
    "humiditySensor": "sensor", "leakSensor": "sensor", "lightSensor": "sensor", "motionSensor": "sensor", "occupancySensor": "sensor",
    "smokeSensor": "sensor", "temperatureSensor": "sensor",
]
let category = categories[primary.definition.name] ?? "other"

// MARK: - Checks before writing anything

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

// MARK: - Package.swift and Plugins.swift

// Everything is changed in memory first, so a missing anchor leaves the repository as it was.
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

// The import among the others, in order, and the registration last.
var registry = read("Sources/HomeswiftCLI/Plugins.swift")
var lines = registry.components(separatedBy: "\n")
guard let firstImport = lines.firstIndex(where: { $0.hasPrefix("import ") }) else { fail("Plugins.swift has no imports") }
let lastImport = lines.lastIndex(where: { $0.hasPrefix("import ") })!
let imports = (lines[firstImport...lastImport] + ["import Homeswift\(name)"]).sorted()
lines.replaceSubrange(firstImport...lastImport, with: imports)
registry = insert("    registry.register(\(name)Plugin.self)\n", before: "    return registry", in: lines.joined(separator: "\n"), file: "Plugins.swift")

// MARK: - The plugin's files

func template(_ text: String) -> String {
    text.replacingOccurrences(of: "__NAME__", with: name)
        .replacingOccurrences(of: "__PLATFORM__", with: platform)
        .replacingOccurrences(of: "__DISPLAY__", with: display)
}

func indent(_ lines: [String], _ spaces: Int) -> String {
    lines.map { $0.isEmpty ? "" : String(repeating: " ", count: spaces) + $0 }.joined(separator: "\n")
}

let homeKitList = chosen.map { service in
    "- \(service.definition.title)" + (service.definition.name == primary.definition.name ? " (primary)" : "") + ": "
        + service.characteristics.map(\.title).joined(separator: ", ")
}.joined(separator: "\n")

let readme = #"""
# __DISPLAY__

TODO: the devices this plugin puts in HomeKit, how it reaches them (the local network, a cloud) and what the Home
app shows.

A port of [`TODO`](https://github.com/TODO), Copyright (c) TODO, under the TODO license; its notice is in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) (TODO: add it there). The platform block is the same, so a
Homebridge configuration works unchanged.

**Maintainer:** @TODO, who has the hardware and answers this plugin's issues. **Status:** experimental until someone
with the device confirms it works.

## In HomeKit

Each device is one accessory with:

\#(homeKitList)

## Configuration

```json
{
  "platforms": [
    {
      "platform": "__PLATFORM__",
      "name": "__DISPLAY__",
      "devices": [{ "id": "TODO", "name": "Living Room" }]
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

// The API: the device, its state (one struct per service), the changes HomeKit asks for.
var stateLines: [String] = []
for service in chosen {
    stateLines.append("/// The \(service.definition.title) service.")
    stateLines.append("struct \(service.typeName): Sendable, Equatable {")
    for characteristic in service.state {
        let description = describe(characteristic)
        let access = characteristic.isWritable ? "HomeKit writes it" : "read only"
        stateLines.append("    /// \(characteristic.title)\(description.isEmpty ? "" : ": \(description)") (\(access)).")
        stateLines.append("    var \(escaped(characteristic.name)): \(characteristic.swiftType!) = \(defaultLiteral(characteristic))")
    }
    stateLines.append("}")
    stateLines.append("")
}
for service in chosen { stateLines.append("var \(service.property) = \(service.typeName)()") }

var changeDeclaration = ""
var applyFunction = ""
var setRequirement = ""
var setUnimplemented = ""
if !writable.isEmpty {
    let cases = writable.map { service, characteristic in
        "    case \(changeCase(service, characteristic))(\(characteristic.swiftType!))"
    }
    changeDeclaration = """

        /// What HomeKit asks a device to change: one case per writable characteristic.
        enum \(name)Change: Sendable, Equatable {
        \(cases.joined(separator: "\n"))
        }

        """
    let applyCases = writable.map { service, characteristic in
        characteristic.isReadable
            ? "        case .\(changeCase(service, characteristic))(let value): \(service.property).\(characteristic.name) = value"
            : "        case .\(changeCase(service, characteristic)): break"
    }
    applyFunction = """


            /// The state once the device has made `change`, before it reports it.
            mutating func apply(_ change: \(name)Change) {
                switch change {
        \(applyCases.joined(separator: "\n"))
                }
            }
        """
    setRequirement = "\n    /// Asks the device to make `change`. TODO: the device's command for each case.\n    func set(_ change: \(name)Change, deviceID: String) async throws"
    setUnimplemented = "\n    func set(_ change: \(name)Change, deviceID: String) async throws { throw NotImplemented() }"
}

let api = #"""
import Foundation

/// A device as the API reports it.
struct __NAME__Device: Sendable, Equatable {
    var id: String
    var name: String
    var state = __NAME__State()
}

/// What a device reports, in HomeKit's units: one value per readable characteristic of its services. TODO: convert
/// the device's own values (a 0-255 brightness, Fahrenheit, mireds) in the transport, not in the plugin.
struct __NAME__State: Sendable, Equatable {
\#(indent(stateLines, 4))\#(applyFunction)
}
\#(changeDeclaration)
/// How the plugin reaches its devices; tests use a fake. TODO: the real transport, on HomeswiftNetwork's
/// `HTTPClient`, `MQTTClient`, `WebSocket` or `UDPSocket` rather than a new package.
protocol __NAME__API: Sendable {
    func devices() async throws -> [__NAME__Device]\#(setRequirement)
}

/// Until the transport is written: every call fails, so the devices answer No Response.
struct Unimplemented__NAME__API: __NAME__API {
    struct NotImplemented: Error, CustomStringConvertible {
        var description: String { "the __DISPLAY__ API is not implemented yet" }
    }

    func devices() async throws -> [__NAME__Device] { throw NotImplemented() }\#(setUnimplemented)
}

"""#

// The plugin: the services of a device, the values shown, the write handlers.
let servicesStruct = chosen.map { "        let \($0.property): Service" }.joined(separator: "\n")
var showLines: [String] = []
for service in chosen {
    for characteristic in service.state {
        showLines.append("services.\(service.definition.name).characteristic(.\(characteristic.name)).value = \(hapValue("state.\(service.definition.name).\(characteristic.name)", characteristic))")
    }
}
var buildLines: [String] = []
for service in chosen.dropFirst() + [primary] {
    let isPrimary = service.definition.name == primary.definition.name
    var arguments = [".\(service.definition.name)"]
    if isPrimary { arguments.append("name: name") }
    if !service.optional.isEmpty { arguments.append("optional: [\(service.optional.map { ".\($0)" }.joined(separator: ", "))]") }
    if isPrimary && multipleServices { arguments.append("linked: [\(chosen.dropFirst().map(\.property).joined(separator: ", "))]") }
    if isPrimary { arguments.append("isPrimary: true") }
    buildLines.append("let \(service.property) = Service(\(arguments.joined(separator: ", ")))")
}
var handlerLines: [String] = []
for (service, characteristic) in writable {
    handlerLines.append("\(service.property).characteristic(.\(characteristic.name)).onWrite(changesOnly: \(characteristic.isReadable)) { value in")
    handlerLines.append("    try await api.set(.\(changeCase(service, characteristic))(\(fromHAPValue(characteristic))), deviceID: device.id)")
    handlerLines.append("}")
}
let serviceArguments = chosen.map { "\($0.definition.name): \($0.property)" }.joined(separator: ", ")
let accessoryServices = ([primary] + chosen.dropFirst()).map(\.property).joined(separator: ", ")
let notes = chosen.compactMap { serviceNotes[$0.definition.name] }
let noteComment = notes.isEmpty ? "" : "\n///\n" + notes.map { "/// \($0)" }.joined(separator: "\n")

let plugin = #"""
import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// TODO: what this plugin puts in HomeKit and how it reaches the devices.
///
/// The configuration is the one of `TODO: the Homebridge plugin`, so a Homebridge block works unchanged.
/// See README.md in this directory.\#(noteComment)
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

    /// A device's services on its accessory.
    struct DeviceServices {
\#(servicesStruct)
    }

    public static let platform = "__PLATFORM__"
    public static let name = "__DISPLAY__"
    /// The web UI's icon: a name from Sources/HomeswiftUI/Web/common.js's icons, its brand's logo where there is one.
    public static let icon: String? = "plugin"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingInterval = 30
    static let minimumPollingInterval = 5

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    /// Each device's services, by device id.
    private var devices: [String: DeviceServices] = [:]
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

    /// Adds an accessory for each new device and shows the values of the others.
    func refresh() async {
        let reported: [__NAME__Device]
        do {
            reported = try await dependencies.api.devices()
        } catch {
            logger.warning("Could not list the devices: \(error)")
            return
        }
        for device in reported {
            if let services = devices[device.id] {
                Self.show(device.state, on: services)
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

    /// Sets each characteristic from the device's state; HomeKit hears of the values that changed.
    static func show(_ state: __NAME__State, on services: DeviceServices) {
\#(indent(showLines, 8))
    }

    private func add(_ device: __NAME__Device) throws {
        let name = configuration.devices?.first { $0.id == device.id }?.name ?? device.name
\#(indent(buildLines, 8))
        let services = DeviceServices(\#(serviceArguments))
        Self.show(device.state, on: services)\#(handlerLines.isEmpty ? "" : "\n        let api = dependencies.api\n" + indent(handlerLines, 8))
        try context.add(Accessory(
            id: Self.accessoryID(deviceID: device.id), name: name, manufacturer: "TODO", model: "TODO",
            serialNumber: device.id, category: .\#(category), services: [\#(accessoryServices)]))
        devices[device.id] = services
    }
}

"""#

// The tests: one write and one change from the device, on the first characteristics that allow them.
var serviceChecks: [String] = []
for service in chosen {
    let variable = service.definition.name + "Service"
    serviceChecks.append("let \(variable) = try #require(accessory.service(.\(service.definition.name)))")
    if service.definition.name == primary.definition.name { serviceChecks.append("#expect(\(variable).isPrimary)") }
    for characteristic in service.characteristics {
        serviceChecks.append("#expect(\(variable)[.\(characteristic.name)] != nil)")
    }
}

let fakeSet = writable.isEmpty ? "" : #"""

    private(set) var changes: [__NAME__Change] = []

    func set(_ change: __NAME__Change, deviceID: String) {
        changes.append(change)
        update(deviceID: deviceID) { $0.apply(change) }
    }
"""#

var writeTest = ""
// A readable characteristic whose test value differs from its default, so the write is a change.
let testable = writable.filter { testLiteral($0.1) != defaultLiteral($0.1) }
if let (service, characteristic) = testable.first(where: { $0.1.isReadable }) ?? testable.first {
    let value = testLiteral(characteristic)
    writeTest = #"""

    @Test func writesReachTheDevice() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        let characteristic = try #require(accessory.service(.\#(service.definition.name))?[.\#(characteristic.name)])
        let handler = try #require(characteristic.writeHandler(for: \#(hapValue(value, characteristic))))
        try await handler(\#(hapValue(value, characteristic)))
        #expect(await environment.api.changes == [.\#(changeCase(service, characteristic))(\#(value))])
        await host.stop()
    }

"""#
}

var changeTest = ""
if let (service, characteristic) = chosen.flatMap({ service in service.state.map { (service, $0) } }).first(where: { testLiteral($0.1) != defaultLiteral($0.1) }) {
    let value = testLiteral(characteristic)
    changeTest = #"""

    @Test func changesOnTheDeviceReachHomeKit() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        let characteristic = try #require(accessory.service(.\#(service.definition.name))?[.\#(characteristic.name)])

        await environment.api.update(deviceID: "dev-1") { $0.\#(service.definition.name).\#(characteristic.name) = \#(value) }
        await environment.plugin?.refresh()
        #expect(characteristic.value.\#(valueAccessor(characteristic)) == \#(value))
        await host.stop()
    }

"""#
}

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
    private(set) var list = [__NAME__Device(id: "dev-1", name: "Test Device")]

    func devices() -> [__NAME__Device] { list }
\#(fakeSet)
    /// A change made elsewhere, in the device's own app.
    func update(deviceID: String, _ change: @Sendable (inout __NAME__State) -> Void) {
        for index in list.indices where list[index].id == deviceID { change(&list[index].state) }
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
        #expect(configuration.pollingInterval == nil)
    }

    @Test func eachDeviceBecomesAnAccessory() async throws {
        let host = try await environment.start(settings: ["devices": [["id": "dev-1", "name": "Renamed"]]])
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(accessoryID == "__PLATFORM__:dev-1")
        #expect(accessory.information.characteristic(.name).value == .string("Renamed"))
\#(indent(serviceChecks, 8))
        await host.stop()
    }
\#(writeTest)\#(changeTest)
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

// MARK: - Writing

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
    Created \(directory) (platform \(platform)): \(chosen.map(\.definition.title).joined(separator: ", ")), registered in Package.swift
    and Sources/HomeswiftCLI/Plugins.swift.
    Next: swift test --filter \(name)Tests, then the TODOs in \(directory). docs/plugins.md and CONTRIBUTING.md say what a
    plugin needs before its pull request.
    """)
for note in notes { print("Note: \(note)") }
