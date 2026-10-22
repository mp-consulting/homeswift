# Plugins

A Homeswift plugin puts devices of one kind in HomeKit. Each `platform` block in `config.json` becomes one
instance of a plugin: the runtime decodes the block into the plugin's `Configuration`, creates it, starts it
once the bridge is listening, and keeps its accessories across launches. Plugins are compiled into the
`homeswift` binary: Swift cannot load code at runtime, so a plugin is a SwiftPM target this repository
builds, and `brew install` ships them all.

`Plugins/ElgatoKeyLights` is the reference plugin.

## Writing a plugin

### Layout

```
Plugins/<Name>/
  README.md             what it does, the configuration options
  config.schema.json    the block's JSON schema (Homebridge's format; a UI will render it)
  Sources/              the target `Homeswift<Name>`
  Tests/                the target `<Name>Tests`
```

This is the layout of a standalone package, so a plugin can move to its own repository later with a
`git mv` and a Package.swift. Add the two targets to `Package.swift` (copy the Elgato entries), add the
library to the `HomeswiftCLI` executable's dependencies, and register the type in
`Sources/HomeswiftCLI/Plugins.swift`. `swift run homeswift plugins` then lists it.

### The protocol

```swift
import Homeswift
import HomeswiftPlugin

public actor MyDevicesPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        public var host: String
        public var token: String?
    }

    public static let platform = "MyDevices"     // the block's "platform" key
    public static let name = "My Devices"        // for `homeswift plugins` and the logs

    let configuration: Configuration
    let context: PluginContext
    private var poller: Task<Void, Never>?

    public init(configuration: Configuration, context: PluginContext) {
        self.configuration = configuration
        self.context = context
    }

    public func start() async throws {
        let devices = try await MyAPI(host: configuration.host, token: configuration.token).devices()
        for device in devices {
            let lightbulb = Service(.lightbulb, name: device.name, optional: [.brightness], isPrimary: true)
            lightbulb.characteristic(.on).onWrite(changesOnly: true) { value in
                try await device.setPower(value.boolValue ?? false)
            }
            try context.add(Accessory(
                id: "\(Self.platform):\(device.serial)", name: device.name, manufacturer: "Acme",
                model: device.model, serialNumber: device.serial, category: .lightbulb, services: [lightbulb]))
        }
        poller = Task { /* watch the devices, set characteristic values when they change */ }
    }

    public func stop() async {
        poller?.cancel()
    }
}
```

- **`Configuration`** is decoded from the whole block with `JSONDecoder`, so unknown keys (`platform`,
  `name`, `_bridge`) cost nothing. Make every option optional and apply defaults in code, as Homebridge
  plugins do, and keep the option names of the Homebridge plugin you port so users can paste their block.
  A block that fails to decode is logged with the key that is wrong and skipped; the other plugins run.
- **`init`** should not talk to devices; `start()` runs once the bridge is listening. Throwing from either
  logs the error and leaves this instance out.
- **`start()` returns quickly.** Discovery and polling run in tasks the plugin owns and cancels in `stop()`.
  An actor keeps the plugin's state safe; handlers capture the device objects, not the plugin.
- **Accessory ids** must be stable across launches and unique on the bridge: prefix a serial number or MAC
  with the platform name (`"ElgatoKeyLights:3C:6A:9D:04:0A:0B"`). The runtime keeps each id's aid and iids,
  so HomeKit keeps rooms, scenes and automations. `context.add` throws `PluginError.accessoryIDInUse` when
  another plugin on the same bridge has the id.
- **Replace, don't mutate.** Build a fresh `Accessory` and call `context.add` again when a device changes
  shape; the runtime swaps it under the same aid. Set `characteristic.value` for value changes.
- **Failures:** throw `HAPStatusError(.serviceCommunicationFailure)` (or any error) from a handler when the
  device does not answer; the Home app shows "No Response". Register `onRead` only when the stored value
  can be stale; most plugins set `value` from their own polling instead.
- **`context.logger`** carries the instance name; `homeswift -D` shows debug lines. Never log tokens,
  passwords or setup codes.
- **`context.storageDirectory`** is the plugin's own directory for tokens and caches.
- **External accessories.** HomeKit allows one television per bridge and wants cameras on their own, so
  Homebridge publishes those outside the bridge. `try await context.publishExternal(accessory)` does the
  same: a HAP server of its own (its identity and pairings in `external/<platform>-<name>-<id>.json`, the
  main bridge's setup code), listed with the bridges in the banner and on the status page so the user adds
  it in the Home app like a second bridge. Publishing the same id again replaces the accessory under the
  same identity, iids kept; the cache brings it back at launch before the plugin starts; `context.remove`
  stops its server. `Plugins/PhilipsAmbilightTV` does this for each TV.
- **Linked services.** A Television lists its input sources and speaker in `Service(linked:)`, which
  becomes `linked` in the accessory database; the Home app shows them with it.
- **Shared transports.** `HomeswiftNetwork` has what devices on the LAN need: `HTTPClient` (on NIO and
  NIOSSL, so a self-signed certificate can be trusted or pinned on Linux too, where URLSession cannot),
  `DigestAuthentication` and `WakeOnLAN`. A plugin depends on it rather than adding a package.

### The runtime

`PluginHost` (in `HomeswiftPlugin`) owns the bridges and the plugins; `homeswift` is a thin CLI around it.

| What | Where |
|---|---|
| `config.json` | `~/.homeswift/config.json` (`-U` changes the directory) |
| Main bridge state (identity, pairings, aids, iids) | `~/.homeswift/homeswift.json` |
| Child bridge state | `~/.homeswift/child-bridges/<platform>-<name>.json` |
| External accessory state | `~/.homeswift/external/<platform>-<name>-<accessory id>.json` |
| Accessory cache per platform instance | `~/.homeswift/accessories/<platform>-<name>.json` |
| Plugin files | `~/.homeswift/plugins/<platform>-<name>/` |

**config.json** has Homebridge's shape:

```json
{
  "bridge": {
    "name": "Homeswift",
    "username": "0E:1A:2B:3C:4D:5E",
    "pin": "031-45-154",
    "port": 51826
  },
  "platforms": [
    { "platform": "ElgatoKeyLights", "name": "Elgato Key Lights" },
    { "platform": "Other", "name": "Other things", "_bridge": { "username": "0E:1A:2B:3C:4D:5F" } }
  ]
}
```

`username` is the HAP device ID and `pin` the setup code; both are optional (generated and kept on first
launch). `port` is honoured when free. A block with `_bridge` runs on a **child bridge**: its own HAP server,
identity and pairing, like Homebridge's. `disabledPlugins` lists platform names to skip. Homebridge's
`accessories` blocks are not supported.

**The accessory cache.** When a plugin adds or removes an accessory, and at shutdown, the runtime writes
the instance's accessories (services, characteristics, values) to its cache file. At the next launch they
are back on the bridge before the plugin starts, so the Home app shows them at once instead of dropping
them while the plugin reaches its devices. A cached accessory serves its last values and accepts writes
without a handler until the plugin adds the same id and replaces it. A cached accessory the plugin no
longer adds stays until the plugin calls `context.remove(id:)`; `context.accessories` lists them.

### Web pages

A plugin can give the web UI a page of its own: a `Web/` directory next to `Sources`, embedded as
`webFiles`, and a `handleWebRequest(_:)` that answers the page's requests. `docs/ui.md` has the details
and `Plugins/ElgatoKeyLights/Web` is the example.

### Testing

Run a `PluginHost` with `MemoryStorage` and no Bonjour, and register the plugin with a closure that injects
fakes for its transport and discovery. `Plugins/ElgatoKeyLights/Tests` does this with an in-memory light:

```swift
var registry = PluginRegistry()
registry.register(platform: MyDevicesPlugin.platform, name: MyDevicesPlugin.name) { json, context in
    MyDevicesPlugin(configuration: try JSONDecoder().decode(MyDevicesPlugin.Configuration.self, from: json),
                    context: context, api: FakeAPI())
}
let block = try HomeswiftConfiguration.Platform(platform: "MyDevices", settings: ["host": "fake"])
let host = try PluginHost(
    configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry,
    storageDirectory: temporaryDirectory, options: .init(advertise: false) { _ in MemoryStorage() })
try await host.start()
let accessory = host.mainBridge.server.accessories[1]
```

Characteristic handlers are reachable in tests with `@testable import Homeswift` (`writeHandler(for:)`,
`readHandler`). `Tests/HomeswiftTests/TestController.swift` is a real HAP controller for end-to-end tests.

## Porting a Homebridge plugin

The HAP side maps almost one to one; the work is the device transport (HTTP, MQTT, WebSocket, cloud APIs).
Keep the platform name and the option names, and copy `config.schema.json` and the README.

| Homebridge | Homeswift |
|---|---|
| `api.registerPlatform(name, Platform)` | `HomeswiftPlugin` with `static let platform = name`, registered in `Plugins.swift` |
| `PlatformConfig` | `Configuration: Decodable` |
| `log.info/debug/warn/error` | `context.logger.info/debug/warning/error` |
| `api.on('didFinishLaunching')` | `start()` |
| `api.on('shutdown')` | `stop()` |
| `api.hap.uuid.generate(seed)` | `Accessory(id: "\(platform):\(seed)")` |
| `new PlatformAccessory(name, uuid)` + `registerPlatformAccessories` | `Accessory(id:name:...)` + `context.add` |
| `configureAccessory(cached)` | Nothing: the runtime restores the cache; `context.add` with the same id replaces it |
| `unregisterPlatformAccessories` | `try await context.remove(id:)` |
| `accessory.getService(S) ?? accessory.addService(S)` | `Service(.s, optional: [...], extra: [...])` passed to the `Accessory` |
| `setCharacteristic(C, v)` / `updateCharacteristic(C, v)` | `service.characteristic(.c).value = v` |
| `getCharacteristic(C).onSet(fn)` | `.onWrite(changesOnly:) { value in ... }` |
| `getCharacteristic(C).onGet(fn)` | `.onRead { ... }` (or set `value` and skip it) |
| `setProps({ minValue, maxValue })` | `Characteristic(.c.with(minValue:maxValue:))` in `extra` |
| `throw new HapStatusError(SERVICE_COMMUNICATION_FAILURE)` | `throw HAPStatusError(.serviceCommunicationFailure)` |
| `accessory.on('identify')` | `Accessory(onIdentify:)` |
| `api.user.storagePath()` | `context.storageDirectory` |
| `api.publishExternalAccessories(...)` | `try await context.publishExternal(accessory)` |
| `tvService.addLinkedService(input)` | `Service(.television, linked: [input, ...])` |
| `bonjour-service` / `mdns` | `BonjourBrowser.browse(type:)` in `Homeswift` |
| `axios` / `undici` | `URLSession` (import `FoundationNetworking` on Linux), or `HomeswiftNetwork.HTTPClient` for a device with a self-signed certificate or Digest authentication |
| `homebridge-ui/server.js`, `config.schema.json` | Keep the schema file; the settings page comes with the Homeswift UI |

`HomeswiftNetwork` is the first shared transport (HTTP with self-signed certificates, Digest, Wake-on-LAN). Still
to add, in the order the ported plugins need them: MQTT (Dyson, then
AWS IoT for Govee, LG ThinQ and Dolphin), WebSocket events (eWeLink, Daikin, UniFi Access). UniFi Protect
waits for camera streaming in the HAP library.

## Where plugins live

Plugins live in this repository, under `Plugins/`, and are released and installed with it. One pull
request can change the plugin API and every plugin together, which matters while the API is pre-1.0;
there is one CI run, one version, and no matrix of plugin versions against library versions. Because Swift
has no runtime loading, a plugin in another repository would need users to build their own `homeswift`
binary. Once the API is stable, a plugin can still move out: its directory is already a package layout,
and a Package.swift that depends on `homeswift` plus a `Plugins.swift` listing it builds a custom binary.

Settings pages: a plugin ships `config.schema.json`, and the Homeswift UI (not written yet) will render it
as Homebridge Config UI X does. Custom pages (`homebridge-ui/public`) will go in `Plugins/<Name>/ui/`,
served by that UI, with their server-side routes implemented by the plugin in Swift. The AI assistant
routes Homebridge plugins register one by one will be provided by the runtime for every plugin.
