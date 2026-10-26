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
`git mv` and a Package.swift. `swift Scripts/new-plugin.swift <Name> <platform> "<Display Name>"` creates it: a
plugin that polls a fake API and puts each device in HomeKit, with its tests, README and schema. Each
`--service <service>[:<characteristic>,…]` gives the devices a service (a switch without one), and the device
state, the changes HomeKit asks for, the write handlers and the tests are typed from its characteristics;
`--list [<service>]` shows what Definitions.swift has. It also
adds the two targets to `Package.swift` and the library to the `HomeswiftCLI` executable's dependencies, and
registers the type in `Sources/HomeswiftCLI/Plugins.swift`. `swift run homeswift plugins` then lists it.
[CONTRIBUTING.md](../CONTRIBUTING.md) has what a plugin needs before its pull request, and the
`homeswift-plugin` skill (`.claude/skills`) walks a coding agent through a port.

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
  `name`, `_bridge`, `_paused`) cost nothing. Make every option optional and apply defaults in code, as Homebridge
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
- **Shared transports.** `HomeswiftNetwork` has what devices and clouds need, on NIO and NIOSSL so it works the
  same on Linux: `HTTPClient` (a self-signed certificate trusted or pinned, where URLSession cannot;
  `HTTPClient.TrustOnFirstUse` pins the first certificate seen), `DigestAuthentication`, `WakeOnLAN`, `UDPSocket`
  and `localIPv4Networks()` for LAN discovery, `WebSocket`, `MQTTClient` (TCP, TLS with a client certificate,
  WebSocket; `Reconnect(firstConnection: true)` retries the first connection too), `TLSOptions` (bundled roots such
  as `.amazonRootCA1`, client identities, ALPN), `AWSSignatureV4`, `URLEncoding` (the JavaScript encodings, byte for
  byte, for signed requests) and `Backoff` (retry delays with jitter). A plugin depends on it rather than adding a
  package; its tests take `FakeMQTTConnection` and `FakeWebSocket` from the `HomeswiftNetworkTestSupport` target.
- **Helpers.** `Service(optional:)` with a type the service has already (`.targetTemperature.with(minValue: 30)`)
  changes its props; `accessory.takeValues(from: cached)` keeps the last values of a rebuilt accessory;
  `characteristic.revert(to:after:)` puts a value back after a write the device refused;
  `context.removeAccessories(keeping:)` drops accessories of devices that are gone. In `HomeswiftPlugin`, `TaskBag`
  holds the tasks `stop()` cancels, `LatestCallGuard` lets the last of quick slider writes through,
  `PersistedDictionary` and `context.jsonFile(_:as:)` keep values in owner-only JSON files, and `EveHistory` is
  fakegato-history for the Eve app.
- **Cameras.** `CameraController` (and `DoorbellController`) mirror HAP-NodeJS's: implement
  `CameraStreamingDelegate` (`handleSnapshotRequest`, `prepareStream`, `handleStreamRequest`, async instead of
  callbacks) and, for HomeKit Secure Video, `CameraRecordingDelegate` (`handleRecordingStreamRequest` returns an
  `AsyncThrowingStream<RecordingPacket, any Error>` of fMP4 fragments). `accessory.configureController(camera)` adds
  the services and serves snapshots (`POST /resource`); `context.configureController(camera, accessoryID:)` keeps
  the recording settings across launches; publish the accessory with `context.publishExternal`. The library runs the
  RTP setup (SRTP keys, SSRCs), the HomeKit Data Stream server for recordings and the doorbell event;
  `HomeswiftFFmpeg` has what runs FFmpeg for the streams and recordings (options per host and hardware
  accelerator, the process, RTP port reservation, the return audio demuxer, fMP4 parsing).
- **Live video in the web UI.** The Accessories page gives each camera a card with snapshots from its
  `CameraStreamingDelegate`. For live video, implement `liveFeed(accessoryID:)` and return a `CameraLiveFeed`: the
  fMP4 initialization segment, an `AsyncThrowingStream` of fragments (`moof` and `mdat`) and what releases the
  source; the MIME type for Media Source Extensions comes from the segment's avcC or hvcC (`CameraLiveFeed.mimeType`),
  or give it. The UI asks while a card is on screen and cancels when it leaves; finish the stream when the source
  restarts (new timestamps need a new initialization segment, which the page asks for). Prefer a low-bandwidth
  stream and share it with HomeKit's consumers: `Plugins/UniFiProtect/Sources/ProtectLiveFeed.swift` does both.
- **Adaptive Lighting.** `AdaptiveLightingController(lightbulb, mode: .automatic or .manual, customTemperatureAdjustment:)`
  on a Lightbulb with Brightness and Color Temperature, created before the accessory goes on the bridge, then
  `context.configureController(controller, accessoryID:)` so an active schedule survives restarts. Automatic mode
  writes Color Temperature through its `onWrite` handler every minute and turns itself off on colour writes from
  HomeKit; call `disableAdaptiveLighting()` when the device changes colour on its own. Manual mode hands the
  schedule to `onUpdate` for lights that run transitions themselves.

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
| Controller states (Adaptive Lighting, cameras) per platform instance | `~/.homeswift/controllers/<platform>-<name>.json` |

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
identity and pairing, like Homebridge's. A block with `"_paused": true` is **paused**: its plugin does not
run, so nothing reaches its devices or their cloud (an iOS app sharing the account keeps its session), and its
accessories stay in HomeKit, with their rooms and automations, answering No Response until it resumes (reads,
writes, identify and snapshots fail without reaching the plugin's handlers: `Accessory.isUnavailable`).
`disabledPlugins` lists platform names to skip; their accessories leave HomeKit. Homebridge's `accessories`
blocks are not supported.

**The accessory cache.** When a plugin adds or removes an accessory, and at shutdown, the runtime writes
the instance's accessories (services, characteristics, values) to its cache file. At the next launch they
are back on the bridge before the plugin starts, so the Home app shows them at once instead of dropping
them while the plugin reaches its devices. A cached accessory serves its last values and accepts writes
without a handler until the plugin adds the same id and replaces it. A cached accessory the plugin no
longer adds stays until the plugin calls `context.remove(id:)`; `context.accessories` lists them. The
controller states (`context.configureController`) of accessories that are no longer in the cache are dropped
when the cache is restored, as HAP-NodeJS's ControllerStorage purges them.

**Security controls.** Lock Target State, Target Door State, Security System Target State and Lock Control
Point unlock, open or disarm, and the bridge's own surfaces guard them: the MCP server and the Assistant write
them only through `set_security_accessory`, after the user confirmed, and the web UI asks before it writes. A
characteristic of yours that does the same, such as a switch whose On unlocks a door, gets the same treatment
when you mark it; HomeKit itself is not affected:

```swift
let trigger = Service(.switch, name: "Unlock Front Door", subtype: "lock-trigger")
trigger.characteristic(.on).securityControl().onWrite { value in try await door.unlock() }
// or: trigger.characteristic(.on).isSecurityControl = true
```

**Mirrored accessories.** An accessory HomeKit already has another way (the Home app's own, which
`Plugins/Wingman` reads through Homeswift Wingman on a Mac) is added with `accessory.mirroredFrom = "Apple Home"`
before `context.add`. The bridge keeps it out of HomeKit: it is not in `GET /accessories`, and controllers cannot
read, write or subscribe to it, so the Home app does not show it twice. The web UI, the MCP tools, scenes, moods and
automations use it as any other; the UI marks it with a house badge and filters on it (**Only from Apple Home**,
`?from=`). `accessory.suggestedRoom` is the room the other controller gives it, the web UI's until the user picks one;
both survive the accessory cache. `CharacteristicType.known(uuid:)` and `ServiceType.known(uuid:)` find Homeswift's
own types from a UUID another controller reports, so the widgets and moods, which know types by name, recognise them.
`context.publishedSerialNumbers` lists the serial numbers of every accessory Homeswift itself publishes (bridges, child
bridges, external accessories), so a plugin reading the Home app's view leaves Homeswift's own out. Renaming or removing a
room the other controller suggests makes it the layout's own; a removed one leaves its accessories with no room.
`accessory.isUnavailable` set for a device that does not answer shows No Response in the web UI, which follows its
changes as they happen (a change is announced with an event of an unchanged value).

**Confidential values.** A characteristic whose value is for HomeKit only (`isConfidential`) is read and
written by controllers as usual, but the MCP server, the web UI and its event stream show it as null, the
accessory cache keeps no value, and the `HAP_DEBUG` trace prints only its size. Setup Endpoints (its value
holds the SRTP master keys of a live stream), Setup Data Stream Transport, Setup Transfer Transport and the
pairing characteristics are confidential by default; set it on a characteristic of your own that carries a
key or a token.

**Numbers from devices.** `Int(someDouble)` traps on NaN, infinity and values beyond `Int`'s range, and a
device, a cloud or a config file can send any of them. Convert with `Int(saturating:)` (rounds toward zero,
clamps, nil for NaN; `Int(saturating: x, in: 0...100)` clamps to a range), `JSONValue.saturatingIntValue`
for JSON, `Int(clamping:)` for a wider integer, and `x.finite` to drop NaN and infinity from a reading.

### Web pages

A plugin can give the web UI a page of its own: a `Web/` directory next to `Sources`, embedded as
`webFiles`, and a `handleWebRequest(_:)` that answers the page's requests. `docs/ui.md` has the details
and `Plugins/ElgatoKeyLights/Web` is the example. The page speaks the user's language with `t()` and a `Web/i18n.js`
of its own ([translations.md](translations.md)).

### In the web UI

Every accessory shows on the web UI's Accessories page as a widget of its kind, built from its services: mark the
primary service, link the others to it, give ranges their real `minStep` and bounds, restrict `validValues` to
what the device does, mark what opens or unlocks with `isSecurityControl`, and give a light with a white
temperature an `AdaptiveLightingController`. [widgets.md](widgets.md) shows what each choice does, with examples,
and how a plugin's own page draws its accessories with the same widgets.

### What the Assistant can do

`assistantActions` describes routes of `handleWebRequest` for a model, so the Assistant (the web UI's chat,
an MCP client) can find, check or pair a device the way the plugin's page does. Each becomes the tool
`<platform>_<name>`, with an `instance` argument when the platform has several blocks; arguments go in the
query of a `GET` and in the JSON body otherwise (`queryKeys` puts some in the query of a `POST`). `access`
sets the MCP scope it needs (`configure` is admin), and `confirm: true` asks the user before it runs.

```swift
public static let assistantActions = [
    AssistantAction(
        name: "probe", title: "Check an address",
        description: "Asks the light at an address who it is. Add it with put_list_entry (platform ElgatoKeyLights, list devices, match mac).",
        path: "probe", access: .read,
        inputSchema: ["type": "object", "required": ["host"], "properties": ["host": ["type": "string"]]]),
]
```

The description is the model's only guide: say what comes back and which tool writes it into config.json
(`put_list_entry` adds or replaces one entry of a list, keyed by `mac` unless told otherwise). Secrets in
the answer reach the model as handles it passes on without reading (`docs/ai.md`).

`assistantBackground` is what the Assistant should know to explain the plugin's errors: what its error
messages mean, quotas, ports, the usual fixes (the `*_AI_CONTEXT` of a Homebridge plugin's
`homebridge-ui/assistant.js`). It goes with every request from the plugin's pages and its `context.assistant`,
so keep it to a paragraph or two, use the messages the plugin really logs, and never ask for secrets in it.

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
| `setProps({ minValue, maxValue })` | `.c.with(minValue:maxValue:)` in `optional`, or `Characteristic(.c.with(...))` in `extra` |
| `throw new HapStatusError(SERVICE_COMMUNICATION_FAILURE)` | `throw HAPStatusError(.serviceCommunicationFailure)` |
| `accessory.on('identify')` | `Accessory(onIdentify:)` |
| `api.user.storagePath()` | `context.storageDirectory` |
| `api.publishExternalAccessories(...)` | `try await context.publishExternal(accessory)` |
| `tvService.addLinkedService(input)` | `Service(.television, linked: [input, ...])` |
| `bonjour-service` / `mdns` | `BonjourBrowser.browse(type:)` in `Homeswift` |
| `axios` / `undici` | `URLSession` (import `FoundationNetworking` on Linux), or `HomeswiftNetwork.HTTPClient` for a device with a self-signed certificate or Digest authentication |
| `mqtt` | `HomeswiftNetwork.MQTTClient` (`MQTTConfiguration(url:clientID:)` takes the same URLs) |
| `ws` | `HomeswiftNetwork.WebSocket.connect(to:options:)` |
| `aws-iot-device-sdk` | `MQTTClient` over `.tls(…, options: TLSOptions(trust: .amazonRootCA1, clientIdentity: …))`, or a WebSocket URL from `AWSSignatureV4.presignIoTURL` |
| `fakegato-history` | `EveHistory(kind, accessoryName:storageURL:)` in `HomeswiftPlugin`, its `service` on the accessory |
| `dgram` | `HomeswiftNetwork.UDPSocket` |
| `homebridge-ui/server.js`, `config.schema.json` | Keep the schema file; the settings page comes with the Homeswift UI |

Ten of the plugins under `Plugins/` are ported this way; between them they use every transport above, cameras
(UniFi Protect) and external accessories (Philips TV). Three are Homeswift's own: Wingman mirrors the Home
app's accessories (below, "Mirrored accessories"), and Philips Hue and IKEA DIRIGERA talk to their bridges' local APIs.

## Where plugins live

Plugins live in this repository, under `Plugins/`, and are released and installed with it. One pull
request can change the plugin API and every plugin together, which matters while the API is pre-1.0;
there is one CI run, one version, and no matrix of plugin versions against library versions. Because Swift
has no runtime loading, a plugin in another repository would need users to build their own `homeswift`
binary. Once the API is stable, a plugin can still move out: its directory is already a package layout,
and a Package.swift that depends on `homeswift` plus a `Plugins.swift` listing it builds a custom binary.

Settings pages: a plugin ships `config.schema.json`, and the Homeswift UI renders it as Homebridge Config UI X
does. A custom page (`homebridge-ui/public`) goes in `Plugins/<Name>/Web/`, served by the UI, with its server-side
routes in the plugin's `handleWebRequest` (see [ui.md](ui.md)); the Assistant's "Explain" is the runtime's, for
every plugin.

### Identifying a physical accessory

Pass an `onIdentify` handler when creating an `Accessory`. Homeswift exposes `supportsIdentify`
from that handler and shows **Identify** in the web UI only for supported accessories.

```swift
Accessory(id: "MyPlugin:device", name: "Desk light", services: [light], onIdentify: {
    try await client.identify()
})
```

Implement `client.identify()` using the device's documented identification command (blink, beep or
another visible signal). There is no universal request across manufacturers. Use the plugin's existing
transport and authentication, propagate failures, and test against a fake transport. Do not advertise
support if the model cannot identify itself. Avoid simulating identification by toggling power unless
the device requires it and its original state can be restored reliably.

Wingman reports HomeKit's `supportsIdentify` flag and invokes its native `identify()` action through
the authenticated `/write` endpoint (`characteristic: "Identify"`, `value: true`). Older Wingman
versions fall back to a writable Identify characteristic in Accessory Information. Wingman's changes permission and certificate pinning still apply.
