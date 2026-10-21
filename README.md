<p align="center">
  <img src="docs/images/icon.svg" width="128" height="128" alt="Homeswift icon: the Swift bird inside a white house, on an orange square">
</p>

<h1 align="center">Homeswift</h1>

<p align="center">
  The HomeKit Accessory Protocol in Swift: put your own devices in the Home app, alone or behind a bridge.
</p>

<p align="center">
  <a href="https://github.com/mp-consulting/homeswift/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mp-consulting/homeswift/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+ and Linux" src="https://img.shields.io/badge/platforms-macOS%2014%2B%20%C2%B7%20Linux-blue">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

> **Status: early.** Pairing, control, identify and events work with the Home app. Linux builds and passes the
> tests in CI but has not been paired with a real Home app yet. The API may still change before 1.0. See [CHANGELOG.md](CHANGELOG.md).

Homeswift is a library for the accessory side of HomeKit over IP, the part
[HAP-NodeJS](https://github.com/homebridge/HAP-NodeJS) plays for Homebridge. You describe accessories with
services and characteristics, react to writes from the Home app, set values when your device changes, and
Homeswift takes care of pairing, encryption, Bonjour and keeping the accessory's identity across launches.

It is also a Homebridge written in Swift: the `homeswift` bridge reads a Homebridge-style `config.json` and
runs the plugins compiled into it, one small binary, no Node.js, no npm. The first plugin is Elgato Key Lights;
[docs/plugins.md](docs/plugins.md) explains how to write or port one.

## What it does

- **Pairing**: pair setup with the 8-digit setup code (SRP-6a, 3072-bit), pair verify, and the pairings the Home
  app adds and removes for other users and home hubs. Up to 16 controllers; removing the last admin unpairs.
- **Encrypted sessions**: ChaCha20-Poly1305 framing on every request after pair verify.
- **Accessories**: a single accessory or a bridge with any number of bridged accessories. All 73 services and 252
  characteristics HomeKit knows, with their formats, units, ranges and valid values.
- **Reads, writes and events**: read and write handlers per characteristic, events to every subscribed controller
  except the one that made the change, timed writes (locks, garage doors), write responses, multi-status errors.
- **Stable identity**: the device ID, keys, pairings, port and every accessory's aid and iids are saved, so
  rooms, scenes and automations survive restarts. Adding or removing accessories bumps the configuration
  number, and the Home app refreshes on its own.
- **Bonjour**: `_hap._tcp` advertising through dns_sd on macOS and Avahi on Linux, updated when pairing changes.
- **Setup code and setup URI**: a random code on first launch (or your own), shown as the Home app shows it
  (`0052-1956`), and the `X-HM://` URI for a QR code.

Not included: Bluetooth LE and Thread accessories, camera and doorbell video streaming (RTP), Siri audio,
MFi authentication. Without MFi, the Home app shows the accessory as uncertified when you add it and asks you to
confirm.

## Install

Add Homeswift to your package:

```swift
dependencies: [
    .package(url: "https://github.com/mp-consulting/homeswift.git", from: "0.1.0"),
],
targets: [
    .executableTarget(name: "MyBridge", dependencies: [
        .product(name: "Homeswift", package: "homeswift"),
    ]),
]
```

macOS 14 or later, or Linux with Swift 6.1 or later. On Linux, install Avahi's dns_sd compatibility library and
keep the Avahi daemon running:

```bash
sudo apt install libavahi-compat-libdnssd-dev avahi-daemon
```

## Example

A bridge with a dimmable lamp:

```swift
import Homeswift

let light = Service(.lightbulb, name: "Desk Lamp", optional: [.brightness], isPrimary: true)

// Writes from the Home app. changesOnly skips writes of the value the lamp already has.
light.characteristic(.on).onWrite(changesOnly: true) { value in
    try await myLamp.setPower(value.boolValue ?? false)
}
light.characteristic(.brightness).onWrite(changesOnly: true) { value in
    try await myLamp.setBrightness(value.intValue ?? 100)
}

let lamp = Accessory(
    id: "desk-lamp",              // stable across launches: a serial number, a MAC, your own key
    name: "Desk Lamp", manufacturer: "Acme", model: "L1",
    category: .lightbulb, services: [light],
    onIdentify: { await myLamp.blink() })

let bridge = Accessory(id: "bridge", name: "My Bridge", category: .bridge, services: [])
let server = try HAPServer(bridge: bridge, accessories: [lamp], storage: FileStorage(name: "my-bridge"))

print("Setup code:", server.setupCode)   // 1234-5678, as the Home app shows it
try await server.run()
```

When the lamp changes on its own (a wall switch, another app), set the value and every subscribed Home app
updates:

```swift
light.characteristic(.on).value = true
```

A few things to know:

- Throw `HAPStatusError(.serviceCommunicationFailure)` from a handler when the device does not answer: the Home
  app shows "No Response" for it.
- `onRead` fetches a fresh value for every read. Most devices are better served by setting `value` when they
  report a change.
- Use `sendEvent(_:)` for stateless events such as a programmable switch press, where the same value repeats.
- Leave `changesOnly` off when the stored value can drift from the device, so tapping the tile again still
  reaches it.
- `FileStorage(name:)` keeps state in `~/.homeswift/<name>.json` (owner-only). Delete the file to start over with
  a new identity; the old accessory must then be removed from the Home app.
- Run one server per identity: two processes advertising the same device ID confuse the Home app.

## Run a bridge with plugins

`homeswift` is the bridge: it reads `~/.homeswift/config.json`, runs the plugins listed in it, and prints the
setup code.

```bash
swift run --scratch-path ~/Library/Caches/homeswift-build homeswift
```

The first run creates a `config.json` with a random username and pin. Add platform blocks to it; a block
written for the Homebridge version of a plugin works unchanged:

```json
{
  "bridge": { "name": "Homeswift", "username": "0E:1A:2B:3C:4D:5E", "pin": "031-45-154" },
  "platforms": [
    { "platform": "ElgatoKeyLights", "name": "Elgato Key Lights" }
  ]
}
```

`homeswift plugins` lists the plugins compiled in, `-U <dir>` uses another directory, `-D` logs debug output.
A block with `_bridge` runs on its own child bridge, with its own pairing. Accessories are cached, so they
are back in the Home app at the next launch before the plugin has reached its devices.

| Plugin | Platform | Devices |
|---|---|---|
| [Elgato Key Lights](Plugins/ElgatoKeyLights) | `ElgatoKeyLights` | Key Light, Key Light Air, Key Light Mini, Ring Light |

## The Assistant

Add a `HomeswiftAiKit` block and the bridge gets an AI assistant: it explains device errors, diagnoses
logs, answers questions and writes configuration blocks, on Claude, OpenAI, Gemini, a local
OpenAI-compatible server, or Apple's on-device model (macOS 26 with Apple Intelligence; no key, nothing
leaves the Mac). Plugins reach it through `context.assistant`; the command line through
`homeswift ask`, `homeswift explain` and `homeswift diagnose`. Secrets are redacted before anything is
sent. See [docs/ai.md](docs/ai.md).

```json
{ "platform": "HomeswiftAiKit", "provider": "apple" }
```

The same block can turn on an **MCP server**, so Claude Desktop, Claude Code or Cursor control the
bridge: accessories, config.json and the log, with scoped tokens, confirmations for locks and
configuration changes, and an audit log. `homeswift mcp --snippets` prints the client configs. See
[docs/mcp.md](docs/mcp.md).

## The web UI

A `HomeswiftUI` block adds a web interface on port 8581: status and pairing codes, accessories with live
control, each plugin's settings as a form from its `config.schema.json`, the raw config.json, and the
live log, behind a login created on the first visit with a set-up code from the bridge's output. See
[docs/ui.md](docs/ui.md).

```json
{ "platform": "HomeswiftUI" }
```

## Demo

`homeswift-demo` is a bridge with a lamp, a switch and a temperature sensor that drifts. Install it with
Homebrew (macOS 15 or later; it builds from source with Swift 6.1 or later):

```bash
brew install mp-consulting/tap/homeswift
```

```bash
homeswift-demo
```

Or run it in the background, at login, with `brew services start homeswift`; the setup code is then in
`$(brew --prefix)/var/log/homeswift.log`. From a checkout, `swift run homeswift-demo` does the same.

It prints the setup code. In the Home app choose **Add Accessory**, then **More options**, pick **Homeswift
Bridge** and enter the code. Set `HAP_SETUP_CODE=031-45-154` for a fixed code and `HAP_DEBUG=1` to log every
request. Its state lives in `~/.homeswift/homeswift-demo.json`.

## How it works

| Layer | Files |
|---|---|
| Model: accessories, services, characteristics, values, the generated definitions | `Sources/Homeswift/Model` |
| Crypto: TLV8, SRP-6a over a C Montgomery multiplication (`CHAPMath`), HKDF and ChaCha20-Poly1305 | `Sources/Homeswift/Crypto` |
| Pairing: setup code, pair setup (M1–M6), pair verify (M1–M4), pairings | `Sources/Homeswift/Pairing` |
| Server: SwiftNIO listener, HTTP and EVENT messages, encrypted sessions, endpoints, storage, Bonjour advertising and browsing | `Sources/Homeswift/Server` |
| Plugin API and runtime: `HomeswiftPlugin`, `PluginContext`, `PluginHost`, config.json, the accessory cache, child bridges | `Sources/HomeswiftPlugin` |
| The `homeswift` bridge: command line, logging, the plugins compiled in | `Sources/HomeswiftCLI` |
| The Assistant: chat providers over plain HTTP, Apple's on-device model, redaction, prompts, schema-checked JSON | `Sources/HomeswiftAI` |
| The MCP server: JSON-RPC, sessions, scopes, elicitation, the audit log, tools over the bridge, Streamable HTTP on NIO, the stdio proxy | `Sources/HomeswiftMCP` |
| The web UI: login and sessions, the JSON API over the same control surface, the pages (`Web/`, embedded) | `Sources/HomeswiftUI` |
| Plugins, one directory each with sources, tests, README and config schema | `Plugins/` |

Each connection handles its requests in order on one task; handlers are `async`, so a slow device never blocks
other connections. Crypto comes from [swift-crypto](https://github.com/apple/swift-crypto) (CryptoKit on macOS).

Apple no longer publishes the HAP specification outside the MFi program. The protocol details follow HAP-NodeJS
and the tests check SRP against [fast-srp-hap](https://github.com/homebridge/fast-srp)'s vectors.
`Sources/Homeswift/Model/Definitions.swift` is generated from HAP-NodeJS's service and characteristic
definitions:

```bash
node Scripts/generate-definitions.js path/to/hap-nodejs > Sources/Homeswift/Model/Definitions.swift 2>/dev/null
```

## Development

```bash
swift build
swift test
```

On macOS, if `swift test` fails to code sign the test bundle (files under `~/Documents` can carry Finder
metadata), build outside the repository with `--scratch-path ~/Library/Caches/homeswift-build`.

## License

MIT, see [LICENSE](LICENSE). The service and characteristic definitions come from HAP-NodeJS (Apache-2.0).

Homeswift is not made or endorsed by Apple. HomeKit, Swift and the Swift logo are trademarks of Apple Inc.
