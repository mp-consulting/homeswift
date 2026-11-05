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
    public static let icon: String? = "bulb"     // the web UI's icon: a brand's logo in common.js, or what it controls
    public static let summary: String? = "Lights and plugs on the local network"   // its line in Add a plugin, translated in the UI's catalogs

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
  byte, for signed requests), `Backoff` (retry delays with jitter), `TCPStream` (a plain TCP byte stream), `Protobuf`
  (`ProtobufWriter` and `ProtobufMessage`: the wire format by field number, without a schema) and `Noise` (the
  `Noise_NNpsk0_25519_ChaChaPoly_SHA256` handshake and cipher states, ESPHome's encryption), `TCPSocket` (a TCP
  connection whose bytes arrive as a stream, for a binary protocol of the device's own), `SSDP` (an M-SEARCH and a
  listener for UPnP devices), `CoAPMessage` (the CoAP codec, for CoIoT status multicasts), `FCMReceiver` (an FCM
  web-push registration and receiver, for clouds that push to their phone app), `ARPTable` and `MACAddress` (the MAC
  behind a LAN address, in one spelling for accessory ids). A plugin depends on it rather than adding a
  package; its tests take `FakeMQTTConnection` and `FakeWebSocket` from the `HomeswiftNetworkTestSupport` target.
- **Helpers.** `Service(optional:)` with a type the service has already (`.targetTemperature.with(minValue: 30)`)
  changes its props; `accessory.takeValues(from: cached)` keeps the last values of a rebuilt accessory;
  `characteristic.revert(to:after:)` puts a value back after a write the device refused;
  `context.removeAccessories(keeping:)` drops accessories of devices that are gone. In `HomeswiftPlugin`, `TaskBag`
  holds the tasks `stop()` cancels, `LatestCallGuard` lets the last of quick slider writes through,
  `PersistedDictionary` and `context.jsonFile(_:as:)` keep values in owner-only JSON files, `context.secretFile(_:as:)`
  keeps a token or a key the same way but sealed in the bridge's vault (docs/vault-design.md), in the instance's
  namespace, moving the plain file of that name there the first time it reads it, `context.pictures(_:)` keeps
pictures a page uploads (`data:` URLs of JPEG, PNG or WebP, checked by their bytes; the Hue and DIRIGERA scene tiles), `EveHistory` is
  fakegato-history for the Eve app, and `context.logs` is the bridge's log from now on (`LogBuffer.observe`), for a
  plugin that acts on log lines (Dummy's log triggers); nil in a library or a test that gives the host none.
- **History and energy.** `context.recordValue(_:series:)` records a reading for the Status page's history (a minute
  keeps its count, sum, lowest and highest, for 8 days; `/api/metrics/values?series=plugin:<platform>:<series>`
  answers it over a range, for a plugin's page; several series separated by commas answer at once, by name, under
  `series`). A plugin that records many readings every few seconds names each series once with
  `context.series(_:)` and records with that. `recordValue(_:series:energy:)` with an `EnergyTag` also puts it in
  the Status page's Energy section, whatever the plugin: its `EnergyRole` (`.solar` and `.home` in watts, `.grid`
  positive while importing, `.battery` positive while charging, `.batteryLevel` in percent) and the device's name.
  A figure several devices report alike (a system's home use, reported by each of its units) takes the same
  `shared` name on each, so it counts once instead of adding up. `context.importEnergy(_:)` hands
  the long-term archive (the Status page's month and year views) a history the bridge did not record, such as a cloud's
  hours before the bridge ran: `EnergyHourImport`s of watt-hours (`EnergyFlows`, nil for what the history lacks). Each
  import replaces what the plugin imported for those hours; an hour the bridge recorded itself keeps its own figures.
  `context.reportEnergyImport(EnergyImportProgress(state: .running, done: 3, total: 10))` shows the import's progress
  on the Status page (then `.done` with `from` and `through`, or `.failed` with a `message` a person can act on);
  import in parts and report after each, so the history fills in as it goes.
  `Metrics.energy(from:to:)` and `Metrics.archive.periods(_:from:to:timeZone:)` give the same figures
  (charted power, levels, each day's kWh) to other code, such as the Assistant.
  ```swift
  context.recordValue(watts, series: "\(id):solar", energy: EnergyTag(role: .solar, device: name))
  context.recordValue(load, series: "\(id):home", energy: EnergyTag(role: .home, device: name, shared: "system"))
  ```
  A power reading with an `EnergyTag` is better declared as a Meter (below), which keeps its energy for years and lets a
  person change its Energy Role; `EnergyTag` stays for a battery's level.
- **Meters** (GLOSSARY.md, "Energy"; docs/adr/0004-meters-and-consumption-history.md). The bridge keeps each Meter's
  Consumption and Returned by the hour, for years (`MeterArchive`, under `metrics/meters/`), whatever its plugin. Most
  plugins need do nothing: every service with Eve's Total Consumption (kWh) or Current Consumption (watts) is a Meter on
  its own, keyed by the service's type and subtype, so it is as stable as its iids. Its energy comes from the counter's
  gains between readings (a restart loses nothing, a counter that goes back is a reset); power is counted only where
  there is no counter. An accessory with Current Consumption and no Eve history of its plugin's also gets one from the
  runtime (`EnergyHistory.swift`, kept under the plugin's files in `eve-energy/`), so the Eve app graphs its power; a
  plugin that keeps its own `EveHistory` keeps it. A plugin declares a Meter itself only for readings no characteristic
  carries: `context.meter(_:deviceID:device:suggestedRole:)` (an inverter's solar, a battery system's flows), or
  `context.meter(of: service, accessoryID:device:suggestedRole:)` to take over a service's Meter before the accessory is
  added (the power's sign, a counter of Returned energy, phases added up), keeping its key, history and Energy Role.
  The `PluginMeter` takes `record(watts:)` (in `EnergyRole`'s signs: a solar array's production, a grid's import and
  a battery's charge above zero), `record(counter:direction:)` (watt-hours, `.consumption` or `.returned`) and
  `importHours(_:)`: `MeterHourImport`s of a device's or a cloud's past, each replacing what was imported for that hour,
  while an hour the bridge measured keeps its own figures. `suggestedRole` is the plugin's Energy Role for it (`.grid`,
  `.solar`, `.home`, `.battery`, nil for a single device's use); a person may change it in the accessory's settings
  (`energyRoles` in `_accessories`, by the Meter's key: `grid`, `solar`, `home`, `battery` or `none`), live, without
  reloading the plugin. With a role, its power counts in the Status page's Energy section and its imported hours fill
  the Home Energy's long-term history where the bridge recorded nothing. Forget removes an accessory's Meters. Shelly's
  energy meters (imports from the device and from Shelly Cloud) and EcoFlow's flows are examples.
  ```swift
  let solar = context.meter("solar", deviceID: serial, device: name, suggestedRole: .solar)
  solar.record(watts: production)
  solar.record(counter: producedWh, direction: .returned)
  solar.importHours(cloudHours.map { MeterHourImport(start: $0.start, returned: $0.wattHours) })
  ```
- **Cameras.** `CameraController` (and `DoorbellController`) mirror HAP-NodeJS's: implement
  `CameraStreamingDelegate` (`handleSnapshotRequest`, `prepareStream`, `handleStreamRequest`, async instead of
  callbacks) and, for HomeKit Secure Video, `CameraRecordingDelegate` (`handleRecordingStreamRequest` returns an
  `AsyncThrowingStream<RecordingPacket, any Error>` of fMP4 fragments). `accessory.configureController(camera)` adds
  the services and serves snapshots (`POST /resource`); `context.configureController(camera, accessoryID:)` keeps
  the recording settings across launches; publish the accessory with `context.publishExternal`. The library runs the
  RTP setup (SRTP keys, SSRCs), the HomeKit Data Stream server for recordings and the doorbell event;
  `HomeswiftFFmpeg` has what runs FFmpeg for the streams and recordings (options per host and hardware
  accelerator, the process, RTP port reservation, the return audio demuxer, fMP4 parsing). A camera whose video is an
  RTSP URL needs no more: `RTSPCameraStreamer` and `RTSPCameraRecorder` (`RTSPCamera.swift`) run its live streams and
  recordings from an `RTSPSourceOpener` the plugin gives (the camera's own URL, or one a cloud makes per session), as
  `Plugins/Imou` does.
- **Live video in the web UI.** The Accessories page gives each camera a card with snapshots from its
  `CameraStreamingDelegate`. For live video, implement `liveFeed(accessoryID:)` and return a `CameraLiveFeed`: the
  fMP4 initialization segment, an `AsyncThrowingStream` of fragments (`moof` and `mdat`) and what releases the
  source; the MIME type for Media Source Extensions comes from the segment's avcC or hvcC (`CameraLiveFeed.mimeType`),
  or give it. The UI asks while a card is on screen and cancels when it leaves; finish the stream when the source
  restarts (new timestamps need a new initialization segment, which the page asks for). Prefer a low-bandwidth
  stream and share it with HomeKit's consumers: `Plugins/UniFiProtect/Sources/ProtectLiveFeed.swift` does both.
- **Pan and tilt in the web UI.** HomeKit has no PTZ service; a camera that moves gets a pad over its live view when the
  plugin answers `cameraControls(accessoryID:)` with a `CameraControls` (the directions it moves in, its presets, whether
  it has a home position) and carries out `controlCamera(accessoryID:_:)`'s `CameraCommand`: `.move(direction)` is one
  step (the pad sends the next once it was answered, while held), `.preset(id)` and `.home`. Throw `CameraControlError`
  for what the camera cannot do, in words the person can act on. `cameraControls` is asked when a live view starts:
  answer from what the plugin knows. `Plugins/Reolink/Sources/ReolinkActions.swift` and `Plugins/Tapo/Sources/TapoPTZ.swift`
  (a battery camera, moved only while a live view keeps it awake) implement it.
- **Adaptive Lighting.** Every Lightbulb with Brightness and Color Temperature gets one (the bridge's debug log names
  a light without it): `context.adaptiveLighting(for: lightbulb, accessoryID:, customTemperatureAdjustment:)` before the
  accessory goes on the bridge makes an automatic `AdaptiveLightingController` whose schedule survives restarts. The
  service holds the controller weakly: keep it with the light's services. It writes Color Temperature through the
  `onWrite` handler every minute and turns itself off on colour writes from HomeKit; pass the device's own reports of
  its colour to `disableIfChangedElsewhere(mireds:)` (nil for a colour), not the echo of the bridge's own write, so a
  colour or a white set elsewhere turns it off too. For lights that run transitions themselves, make one with
  `mode: .manual` and `context.configureController(controller, accessoryID:)`: `onUpdate` gets the schedule.

### What a service stands for

HAP has no service type for some devices: a robot vacuum or a pool robot is a Switch or a Fan v2 in HomeKit. Set
`Service.standsFor` before `context.add` to say what it is, and the ecosystems that have the type show it as that:
`.cleaningRobot` makes a service with On (a Switch) or Active (a Fan v2) a Robotic Vacuum Cleaner over Matter (start,
stop, pause and go home on it, running or stopped as the characteristic says, docs/matter.md). HomeKit sees the service as it is. The Dolphin Pool Cleaner, SwitchBot and Roborock
plugins do it for their robots.

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
| Each Meter's hourly Consumption and Returned | `~/.homeswift/metrics/meters/<Meter id in base64url>/` (`meter.json`, a file per UTC year: `2026.json`) |
| The Eve energy histories the runtime keeps | `~/.homeswift/plugins/<platform>-<name>/eve-energy/<accessory id in base64url>.json` |

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
`"_accessories": { "<key>": { … } }` holds the block's Accessory Settings (GLOSSARY.md;
docs/adr/0001-canonical-accessory-settings.md, 0003-room-and-visibility-in-accessory-settings.md), keyed by Device Id, or
for a device's other accessories by their Accessory Id without `<platform>:` (`<deviceID>:<more>`). The Core Accessory
Settings are `name`, `room` (`""` for none), `hidden` (off the web UI's wall), `notInHome` (out of the Home app),
`excluded` and `parts` (`{ "SideDoor": false }`); the other keys are the plugin's own (its Plugin Accessory Settings,
declared in its schema's `accessorySchema`). `name`, `room`, `hidden` and `notInHome` apply without reloading the
plugin, which never sees them; `excluded`, `parts` and the plugin's own reload it. The web UI's settings and MCP's
`get_settings`/`update_settings` read and write them, checked against the schema.
`notInHome` keeps the accessory out of the Home app (the web UI's **Not in Home**, in the accessory's Settings): it stays on the bridge for the
web UI, the MCP server and Matter, so a Matter device of its own can be in Apple Home through Matter alone. An older
`"_hiddenFromHomeKit": [ids]` list still applies, and moves into `_accessories` with the block's next settings write.
`name` renames an accessory, in the Home app too (the Name in the accessory's Settings on the web UI). The runtime puts the name on Accessory
Information's Name and on the services named after the accessory
(`Dyson` and `Dyson Temperature` become `Desk` and `Desk Temperature`), and gives the primary service a Configured
Name if it has none: the Home app keeps its own name for a paired accessory and does not follow Name, but it follows
Configured Name and writes it when someone renames the accessory there, which the bridge keeps in `_accessories` too.
Aids and iids stay, and a rename does not reload the plugin; without the name, the plugin's names come back. A plugin
does nothing for it, but should not set Name or Configured Name again on its own after adding an accessory.
`bridge.roomSync` is Room Sync (GLOSSARY.md), which needs no restart.
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
read, write or subscribe to it, so the Home app does not show it twice. The web UI, the MCP tools, scenes and
automations use it as any other; the UI marks it with a house badge and filters on it (**Only from Apple Home**,
`?from=`). `accessory.suggestedRoom` is the room the other controller gives it, the web UI's until the user picks one;
both survive the accessory cache. `CharacteristicType.known(uuid:)` and `ServiceType.known(uuid:)` find Homeswift's
own types from a UUID another controller reports, so the widgets and scenes, which know types by name, recognise them.
`context.publishedSerialNumbers` lists the serial numbers of every accessory Homeswift itself publishes (bridges, child
bridges, external accessories), so a plugin reading the Home app's view leaves Homeswift's own out. Renaming or removing a
room the other controller suggests makes it the layout's own; a removed one leaves its accessories with no room.
`accessory.isUnavailable` set for a device that does not answer shows No Response in the web UI, which follows its
changes as they happen (a change is announced with an event of an unchanged value). A mirror whose controller reports
reachability sets `accessory.isUnreachable` instead: No Response shows the same (`showsNoResponse` is either), but
writes still reach the plugin, as the Home app still tries an accessory it shows so, and the other controller answers.

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

### Secrets

Passwords, keys and tokens go through the bridge's vault (docs/vault-design.md); a plugin does little for it.

- **In the configuration.** A secret sits under a key the bridge reads as one (`password`, `token`, `apiKey`,
  `secret`, `privateKey`, `credential`, `pin`…: `Redaction.secretKeyPattern`). Under such a key config.json may hold
  the value, a sealed `enc:v1:` copy, or a reference (`vault:<entry>[#field]`, `env:<VARIABLE>`, `file:/path`), and
  the plugin always receives the plain value: the runtime opens and resolves the block before `init`, and masks the
  value in logs, MCP replies and the Assistant's prompts. Keep the Homebridge plugin's option names; a secret under
  another name (Govee's `localKey`) is neither sealed nor resolved, so say so in the README.
- **What a Setup gives** (a hub's key, a TV's password, a cloud's refresh token) goes in the vault through
  `SetupOutcome.credentials` and comes back with `context.credentials(for:as:)` ([Setup](#setup)); `legacyFile:` moves a
  file the plugin kept it in before.
- **Tokens the plugin gets at run time** (a cloud's session, a hub's token, a client key) go in
  `context.secretFile(_:as:)`, never `jsonFile` or `PersistedDictionary`: `load()`, `save(_:)` and `remove()` as
  `jsonFile`, sealed in the vault as `plugin.<instance>.<file>`, an entry only that instance's block can read. Give it
  the Homebridge plugin's file name: a file of that name in the plugin's folder (one copied from Homebridge) moves in
  the first time it is read, and `legacyFile:` names one kept elsewhere. What it holds under secret-named keys is
  masked in logs from then on.

  ```swift
  let tokens = context.secretFile("ewelink-tokens.json", as: Session.self)
  if let session = tokens.load() { … } else { try tokens.save(try await signIn()) }
  ```
- **What a plugin never does:** read `vault.json` or another entry, log a value (masking is a safety net, not
  permission), or write a secret anywhere else on disk.
- **Tests** run `secretFile` on a temporary storage directory (the vault's key is made on the first save); a test
  config that names `vault:` entries adds them first with `CredentialVault(storage:).set(_:_:)`.

### Setup

Setup (GLOSSARY.md) is how a device gets into the bridge, the same for every plugin: the plugin finds its devices, says
what each one, and its instance's account, asks before the bridge may talk to it, and answers the steps of that
Authorization. The bridge holds each Setup in progress, keeps what an Authorization gives in the vault, writes the
settings it brings and reloads the plugin; the web UI's **Add accessories** page and the MCP tools `discover_devices`,
`start_setup`, `continue_setup` and `cancel_setup` draw the same steps. `Setup.swift` has the types,
`Plugins/PhilipsHue/Sources/HueSetup.swift` is the example.

- **`static let accountAuthorization`**: what the instance's account asks, one of the Authorization Methods: `none`
  (the default), `buttonPress` (a hub's link button), `deviceCode` (a PIN a device shows), `accountLogin` (an email or
  user name and password, perhaps a one-time code), `browserRedirect` (a sign-in page whose redirect comes back) or
  `apiKey`.
- **`static let accountRequirement`**: whether the plugin's devices depend on that account. `.required` (the default):
  its devices come with the account or are reached through it, so the plugin's card says **Needs sign-in** (or
  **Needs pairing**, **Needs keys**) until it is set up, and its settings say its devices show once it is.
  `.optional(adds:)`: the plugin works without it, and `adds` says what setting it up brings, one sentence in English
  with its French, Spanish and Portuguese in the web UI's catalogs (`TranslationTests` reads it from the source):
  `.optional(adds: "Protects the webhooks with a password.")`. A plugin left without an optional account shows
  as running.
- **A refused account**: when the account refuses what Setup gave (a password changed, a refresh token revoked; not a
  cloud that does not answer), call `context.accountRefused("why, in English")`: the plugin's card and settings say it
  Needs Authorization, required account or not, until the account's Setup is done again, new credentials are saved
  (`saveCredentials` with a refreshed token) or removed, or `context.accountAccepted()`. A paused instance needs no one
  until it is resumed. `accountAuthorized()` should answer at once: the Plugins page waits 2 seconds for it, then reads
  the vault. `list_plugins` and `discover_devices` give it as `accountState`
  (`none`, `setUp`, `notSetUp`, `refused`) and `needsAuthorization`.
- **`discover()`**: the devices the plugin can find now (on the network, in the account, at the addresses its
  settings name), each a `DiscoveredDevice` with its Device Id (the part of its accessory's id after `<platform>:`), the
  Authorization it needs, whether it is set up (and `isReachable: false` for one set up that does not answer now: Not responding), and `excludedBySettings` for one the plugin's own Homebridge-shaped
  lists leave out. It may run on an instance made for Setup and never started: answer within a few seconds.
- **`authorize(_:)`**: one step at a time, for the account (`request.target == .account`) or a device. Answer
  `.ask(SetupPrompt(message:fields:url:waitSeconds:retryAfter:), state:)` for more, or `.done(SetupOutcome)`; throw
  `SetupError` for an answer that did not work, and the person is asked again. A step may run on another instance than
  the one before, so keep what the next one needs in `state` (it stays on the bridge, never reaches a page or a model).
  A field of kind `secret` is a password or a key: a person types it in the web UI, an MCP client may only pass a
  `vault:` reference. A wait (`waitSeconds`) is sent again with no answers every `retryAfter` seconds.
  A plugin with more than one way to sign in (Daikin's Developer Portal or Onecta login, LG's page or a password,
  EcoFlow's developer API, app or both) asks
  which first, with `SetupField.choice(_:label:options:value:)` (the block's current one as `value`), reads it with
  `request.choice(_:among:)`, and returns each later step `.keeping` it, so the steps after know it and the block
  keeps it once done. A short list of fixed answers (EcoFlow's region) is a choice too, not text to type. A country or a language is a
  choice of `SetupOption.countries()` (each country's ISO code, or what the plugin sends for it, such as eWeLink's
  calling codes) or `SetupOption.languages()`: the web UI shows a long choice as a menu, named in the reader's language.
- **What it gives**: `SetupOutcome.credentials` (tokens, keys, a device's password) go to the vault, read back with
  `context.credentials(for:as:)`; `settings` are merged into the block for the account (a `null` takes a key out,
  one the credentials now hold) or into the device's Accessory Settings; `deviceID` names the device when the
  Authorization is what tells it (a TV's MAC, read once paired). Credentials kept means Authorized: keep none for an
  account or a device that is not, or answer `accountAuthorized()` when the plugin keeps its tokens itself.
- **Accessory Settings** live in the block's `_accessories`, by Device Id (docs/adr/0001-canonical-accessory-settings.md):
  the Core ones for every plugin (`name`, `room`, `hidden`, `notInHome`, `excluded`, `parts`, `energyRoles`; the plugin
  sees `excluded` and `parts`, the others apply without it), the rest the plugin's own, declared in its schema's `accessorySchema`
  ([Settings](#settings)) and read with `context.accessorySettings(for:)` and `decode`. An
  Excluded device is never an accessory: the runtime refuses its `add` and takes it off the bridge, and the plugin should
  stop polling it (`context.isExcluded`). A Homebridge-shaped block (a `devices` list, exclude lists) still loads: read
  both, the Setup's first, and turn it into the canonical shape in `canonicalSettings` ([Settings](#settings)).
- **`DiscoveredDevice.kind`**: its Device Kind (`camera`, `sensor`), which decides the Plugin Accessory Settings the
  editor shows for it (`x-kinds`).
- **Parts.** A device that brings things a person may leave out (a UA Gate's side door, a door's position sensor, a
  doorbell) lists them in `DiscoveredDevice.parts` (`DevicePart(id, name:, icon:, included:)`). Add accessories shows
  each with a switch under its device; the choice goes in the device's Accessory Settings' `parts` (`{ "SideDoor": false }`),
  and the plugin reloads and reads it from `context.allAccessorySettings` (UniFi Access turns each into a `Hub.<id>`
  option of that device).
- **A device the network does not show** (Bonjour blocked, another subnet): an entry with only its address in the
  block's own list (a TV's `ip`, a Wingman's `host`) is a device `discover()` lists by that address, and its Setup
  keeps it under the Device Id the Authorization reads.
- **Add by address** (GLOSSARY.md): a plugin whose devices are reached by address and cannot be found (an EV charger,
  a solar gateway, a camera on another subnet) sets `static let addsDevicesByAddress = true`. The Add accessories page
  then offers **Add by address…** on its instance, and `start_setup` takes `addByAddress: true`; with or without an
  account (a plugin with an optional account offers both). Its Setup is `authorize` with `request.target == .newDevice`
  (`request.isNewDevice`): the first step asks for the address and whatever else the device needs, a later one may ask
  for more (a password, a camera's safety code) with `state`, as any Setup's. The plugin probes the device and answers
  `.done` with `SetupOutcome.deviceID` (required: the Device Id the device answered with), `settings` (its Accessory
  Settings, by that Device Id: where it answers, declared in `accessorySchema` so its settings sheet can change it; a
  `null` takes a key out) and `credentials` (to the vault, under that Device Id), or throws `SetupError` for what
  did not work ("No light answered at 192.0.2.50:9123"), which the sheet shows and asks again. A device added this way is
  included (an Excluded one is no longer), and the plugin reloads and reaches it from `context.allAccessorySettings`;
  `discover()` lists it, set up, like a discovered one. The plugin's own Homebridge-shaped address list (Elgato's
  `addresses`) keeps working beside it. `Plugins/ElgatoKeyLights/Sources/ElgatoSetup.swift` is the example:

  ```swift
  public static let addsDevicesByAddress = true

  public func authorize(_ request: SetupRequest) async throws -> SetupStep {
      guard request.isNewDevice else { return .done(SetupOutcome()) }
      guard let host = request.answer("host") else {
          return .ask(SetupPrompt(message: "Enter the address of the light: …", fields: [
              SetupField("host", label: "IP address or host name"), SetupField("port", label: "Port", optional: true),
          ]))
      }
      guard let info = try? await KeyLightClient(host: host, port: port, transport: transport).info(),
            let mac = info.macAddress.flatMap(MACAddress.canonical) else { throw SetupError("No light answered at \(host):\(port)") }
      return .done(SetupOutcome(settings: ["host": .string(host)], deviceID: mac))
  }
  ```

  Its prompt and errors are English, with their French, Spanish and Portuguese in the web UI's catalogs, as every
  prompt's (an error with a value is a `{placeholder}` key there: `"No light answered at {address}"`).
- **Its page** leads to Setup (`homeswift.setupCard`, docs/ui.md) rather than signing in or pairing itself.

### Settings

A plugin's `config.schema.json` declares every setting it stores (docs/adr/0002-schema-declares-every-setting.md): its
Plugin Settings under `schema`, as Homebridge's, and its Plugin Accessory Settings under `accessorySchema`, whose
`properties` are JSON schemas of the same kind, one per key of an accessory's entry in `_accessories`:

```json
{
  "pluginAlias": "UniFiProtect",
  "schema": { "type": "object", "properties": { "motionDuration": { "type": "integer", "title": "Motion duration", "description": "…" } } },
  "accessorySchema": {
    "properties": {
      "motionDuration": {
        "type": "integer", "minimum": 1, "title": "Motion duration", "description": "Seconds a motion event lasts for this camera",
        "x-kinds": ["camera"], "x-default": "motionDuration"
      },
      "offset": { "type": "number", "minimum": -5, "maximum": 5, "title": "Temperature offset", "description": "Added to the sensor's reading" }
    }
  },
  "i18n": { "fr": { "Motion duration": "Durée d'un mouvement", "…": "…" } }
}
```

- `x-kinds` (optional): the Device Kinds the field is for; the editor shows it only for a device of one of them, and the
  settings writers refuse it for another. Without it the field is every accessory's. A choice of a `oneOf` (or
  `anyOf`) may carry its own `x-kinds`, as Govee's `showAs` lists a switch's types beside a light's: `get_settings` gives
  a device the choices of its kind only, so the editor shows those, and the writers refuse another kind's choice.
- An object without `properties` is a map, its values declared by `additionalProperties` (text when it is not an
  object): the editor shows a row per entry, its key and its value, with Add and Remove, and saves an entry taken out as
  a `null` in it.
- An array of objects shows a row per entry, which opens to edit, with Move up, Move down and Remove: its order is kept
  (a TV's sources as its input menu lists them). A row is named by its entry's `name`, `displayName`, `customName`,
  `title`, `label`, `id`, `host`, `address` or `ip`, the first that has a value; `x-rowTitle` on `items` (a key, or a list of keys tried in turn)
  names another. An array whose `items` are choices (an `enum`, or a `oneOf` of them) is a set of checkboxes, written in
  the choices' order; `uniqueItems: false` keeps a menu per entry instead, for a list that may hold a choice twice.
- `x-default` (optional): the Plugin Setting that is the field's plugin-wide default; an accessory's own value overrules
  it. `get_settings` gives it as `default: {setting, value}`.
- A field's `title`, `description` and choices are translated from the schema's `i18n`, as the main schema's are
  (`TranslationTests` checks both). A field named like a Core Accessory Setting (`name`, `room`, `hidden`, `notInHome`,
  `excluded`, `parts`) or starting with `_` is not allowed (`HomeswiftCatalog.accessorySchemaProblems`).

Every write of a setting is checked against it: `update_settings` and the web UI's settings refuse a key the schema does
not declare, while the raw config tools (`patch_config`, `update_config`, the config.json editor) let an undeclared key
in `_accessories` through, so a block written before still saves, and check what is declared. `get_plugin_config_schema`
and `GET /api/plugins/<platform>/schema` give `accessorySchema` with the rest.

Two hooks, both optional, help the settings editor and the writers:

- **`deviceKind(of deviceID:) async -> String?`**: the Device Kind of one of the running instance's devices, for the
  fields to show (`x-kinds`). nil (the default) falls back on the kind the last discovery gave (`DiscoveredDevice.kind`).
- **`canonicalSettings(_ block: JSONValue) async -> JSONValue`**: the block in its canonical shape. The bridge asks the
  running instance just before each settings write to the block (`update_settings` and the web UI's settings, Setup's
  last step, Exclude and Include) and writes what it answers. Turn the plugin's Homebridge shapes (a `devices` list,
  exclude lists by name or id, typed arrays, feature-option strings) into Accessory Settings in `_accessories` by Device
  Id and declared Plugin Settings, and drop the legacy keys; it may use what the plugin knows now (its devices' names,
  to read a list of names). Leave what it cannot read as it is (`AccessoryEntries` moves an exclude list that way, an
  entry's own values winning). The default answers the block unchanged. It is asked on
  a dry run too, so it only answers: anything more, such as moving a legacy token into the vault before dropping it from
  the block, goes in `context.whenSettingsWritten { … }`, which runs once the write is checked, just before config.json
  is written, and never on a dry run or a refused write (an effect that throws stops the write, so make it idempotent).
  Answer the block as it will be once the effects have run (the token dropped as if the vault had it). Answer a block
  that means what it was given: when the canonical shape is all a write changes of what the plugin reads (a person
  renaming a device of a block still in Homebridge's shape), the running instance is not reloaded; it takes the new
  block, reads the moved Accessory Settings through its context, and loses the accessories they Exclude.

### Web pages

A plugin can give the web UI a page of its own: a `Web/` directory next to `Sources`, embedded as
`webFiles`, and a `handleWebRequest(_:)` that answers the page's requests: views, diagnostics and actions, never a
settings write (the Settings page edits what the schema declares, [Settings](#settings); the page links to it with
`homeswift.accessorySettings`). `docs/ui.md` has the details
and `Plugins/ElgatoKeyLights/Web` is the example. The page speaks the user's language with `t()` and a `Web/i18n.js`
of its own ([translations.md](translations.md)).

### In the web UI

Every accessory shows on the web UI's Accessories page as a widget of its kind, built from its services: mark the
primary service, link the others to it, give ranges their real `minStep` and bounds, restrict `validValues` to
what the device does, mark what opens or unlocks with `isSecurityControl`, and give a light with a white
temperature an `AdaptiveLightingController`. [widgets.md](widgets.md) shows what each choice does, with examples,
and how a plugin's own page draws its accessories with the same widgets.

### Scenes

A plugin whose hub keeps scenes (a Hue Bridge, a DIRIGERA hub, a Govee light's picks) lists them with
`scenes()` and recalls one with `recallScene(id:)`. The web UI's Scenes page shows them with Homeswift's own scenes,
in the room named as the hub's room or zone (or the room of `accessoryIDs`, when the plugin knows the lights), and
`list_scenes` and `run_scene` take them too. Homeswift asks each time it lists them, so answer from what the plugin
already knows; it keeps no copy. A recall is held like a scene's run: the lights it changed can be put back.
`Plugins/PhilipsHue/Sources/HueScenes.swift` is the example; [scenes-design.md](scenes-design.md) has where this goes.

```swift
public func scenes() async -> [PluginScene] {
    snapshot.scenes.map { PluginScene(id: $0.id, name: $0.name, room: $0.roomName, active: $0.isActive, colours: $0.swatches) }
}

public func recallScene(id: String) async throws {
    try await recall(sceneID: id)
}
```

A plugin whose lights have effects of their own plays an animated scene's effect natively: `animate(_:accessoryIDs:)`
gets a `LightEffect` (a style such as fire, candle or sunrise, with an optional colour, speed and brightness) and the
scene's lights it owns, and answers those it plays the way its brand's app does; Homeswift plays the others itself.
`stopAnimation(accessoryIDs:)` stops them before Homeswift puts their values back. Hue (`HueEffects.swift`: `effects_v2`,
`timed_effects`), Govee (the library scene of the style's name), DIRIGERA (a sunrise as one long fade), eWeLink (a
SONOFF L2 strip's own scenes) and the Ambilight TV (music) do.

A hub that keeps scenes can let Homeswift write them. `sceneTarget(accessoryIDs:)` answers where a new scene of exactly
those lights would go (a Hue room or zone), or nil; `createScene(name:lights:)` makes it from `PluginSceneLight` values
(On, Brightness, hue and saturation or a white in mireds, in HomeKit's units) and answers its id;
`updateScene(id:name:lights:)` renames it or replaces its lights, and `deleteScene(id:)` removes it. List what each
scene allows in `PluginScene.capabilities` (`rename`, `update`, `delete`) and its lights in `accessoryIDs`, so the page
can keep them "as they are". Write, then read the hub back: it stays the only keeper. Hue (`HueScenes.swift`) and
DIRIGERA (`DirigeraScenes.swift`, from lpgera/dirigera) do.

A hub that keeps rooms can follow Homeswift's: with Room Sync on (`bridge.roomSync`, the Accessories page's **Sync rooms
with the hubs**), a room renamed in Homeswift is renamed on the hubs. `rooms()` lists the hub's rooms as `PluginRoom`
(its id, name, and `place` when the instance has several hubs or homes); Homeswift calls it only on a rename, so it may
ask the hub. `renameRoom(id:name:)` renames one; Homeswift picks those named as the room was, case and accents aside,
and logs what each did. Hue (`HueRooms.swift`, rooms but not zones), DIRIGERA (`DirigeraRooms.swift`, from
lpgera/dirigera, the room's icon and colour kept), eWeLink (`EWeLinkRooms.swift`, `PUT /v2/family/room`) and Wingman
(`Structure.swift`, Apple Home's rooms) do.

A hub that keeps automations of its own lists them with `automations()` as `PluginAutomation`s: when they start
(`triggers`, any of them: a time or sunrise and sunset with an offset, an accessory's value or range, presence), what
ends them (`endTriggers`), their `conditions`, the plugin's scenes they run (`sceneIDs`) and their own `actions`, with
accessories named by Homeswift's ids and characteristic types and `names` for those Homeswift does not have.
`updateAutomation(id:change:)` applies a `PluginAutomationChange` (enabled, name, time, scenes, actions; nil leaves a
part as it is) and `deleteAutomation(id:)` removes one; list what each allows in `capabilities`. The hub stays the only
keeper, as for scenes. Wingman (`Structure.swift`, Apple Home's automations; docs/apple-home-design.md) does.

### What the Assistant can do

`assistantActions` describes routes of `handleWebRequest` for a model, so the Assistant (the web UI's chat,
an MCP client) can find, check or pair a device the way the plugin's page does. Each becomes the tool
`<platform>_<name>`, with an `instance` argument when the platform has several blocks; arguments go in the
query of a `GET` and in the JSON body otherwise (`queryKeys` puts some in the query of a `POST`). `access`
sets the MCP scope it needs (`configure` is admin), and `confirm: true` asks the user before it runs. An action that
changes lights on the device's own hub (a scene) sets `changesLights: true`: the bridge keeps how the lights it changed were,
and `stop_scene` puts them back, as after any scene.

```swift
public static let assistantActions = [
    AssistantAction(
        name: "probe", title: "Check an address",
        description: "Asks the light at an address who it is. Add it to the Plugin Setting addresses with update_settings (plugin ElgatoKeyLights).",
        path: "probe", access: .configure,
        inputSchema: ["type": "object", "required": ["host"], "properties": ["host": ["type": "string"]]]),
]
```

The description is the model's only guide: say what comes back and which tool writes it into config.json
(`update_settings`, by accessory for its Accessory Settings or by plugin for Plugin Settings; it merges objects key by key
and replaces a list whole, so a list is read with `get_settings` first). Secrets in
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
| `net` (`net.Socket`) | `HomeswiftNetwork.TCPSocket.connect(host:port:timeout:)` |
| `node-ssdp` | `HomeswiftNetwork.SSDP` |
| `push-receiver` / `@eneris/push-receiver` | `HomeswiftNetwork.FCMReceiver` |
| `homebridge-ui/server.js`, `config.schema.json` | Keep the schema file; the settings page comes with the Homeswift UI |
| `api.registerAccessory(name, Accessory)` | `static let runsAccessoryBlocks = true` with `platform = name`: see "Accessory plugins" below |

### Accessory plugins

A Homebridge accessory plugin's devices are top-level `accessories` blocks (`{"accessory": "mqttthing", …}`), one
accessory each, rather than a platform's. Homeswift runs them in a plugin whose `platform` is the accessory's name and
which says `static let runsAccessoryBlocks = true`:

- `HomeswiftConfiguration.decode` appends each accessory block, as it is, to the `accessories` list of the platform
  block of its name (the qualified `homebridge-mqttthing.mqttthing` names `mqttthing` too): the first one with the same
  child bridge (`_bridge.username`, or none), else a block it makes, named after the platform or after the `_bridge`. So
  every block of a bridge runs in one instance, which shares what the blocks share (MQTT Thing's connection per broker),
  and a block with a `_bridge` gets its child bridge as a platform does. The plugin's `Configuration` reads
  `accessories: [JSONValue]?`; a `{"platform": "mqttthing", "accessories": […]}` block written by hand works the same.
- `Platform.accessoryBlocks` counts what a block took in. Secrets in accessory blocks are opened and resolved like a
  platform block's, since they are part of it by the time the runtime reads them. The runtime warns about accessory blocks
  that no plugin runs.
- The Homebridge import (`HomebridgeImport`) turns a plugin's accessory blocks into such a platform block, its
  secrets sealed, and skips the others with a warning. Declare `accessories` in the schema (an array of objects without
  `properties`, so the import keeps every key).

`Plugins/MQTTThing` is the example.

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
does, every option explained by its `description` and its words translated by the schema's `i18n`
([translations.md](translations.md#forms)). A custom page (`homebridge-ui/public`) goes in `Plugins/<Name>/Web/`, served by the UI, with its server-side
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
