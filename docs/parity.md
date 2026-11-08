# Plugin parity: the plan

Where Homeswift's plugins stand against what the community offers in Homebridge and Home Assistant, and the order the
gaps are closed in. The comparison is the plugins' own `README.md` sections ("What differs", "Gaps", "Not done") checked
against the upstream feature lists; the clean-room specs in `docs/clean-room/` name the upstream commit each port was
written from, all of them from September to November 2026, so no plugin lags a release of its original.

The findings are not repeated here. **A plugin's gaps belong in its README**, beside the upstream it names: that is
where a reader looks, and it is the only place that stays true when an upstream ships. This file holds only the work
that is worth doing, in order.

## The order

| # | Work | Plugins it fixes | Size |
|---|---|---|---|
| 1 | [EcoFlow: writes](#1-ecoflow-writes) | EcoFlow | Small |
| 2 | [A WebRTC stack](#2-a-webrtc-stack) | Ring, GoogleNestSDM | Large |
| 3 | [SwitchBot over Bluetooth](#3-switchbot-over-bluetooth) | SwitchBot, later Govee and Xiaomi | Medium |
| 4 | [A Home Assistant bridge plugin](#4-a-home-assistant-bridge-plugin) | ~25 brands at once | Medium |
| 5 | [The rest](#5-the-rest) | Roborock, hardware confirmation, the long tail | Mixed |

Each item ends green on macOS and Linux, is one branch, and follows the house rules: a port gets a clean-room
specification in `docs/clean-room/` first (CONTRIBUTING.md), byte layouts are never guessed, plugins depend on
`Homeswift`, `HomeswiftPlugin` and this package's shared transport targets and never on a new package, and tests use
fakes with `advertise: false` and wait for what they check.

## 1. EcoFlow: writes

**The gap.** The plugin is read-only. Every device becomes one Battery service and a card on the plugin's page;
`Sources/EcoFlowAPI.swift` has `devices()`, the REST quota and the MQTT subscription and no write path at all. Home
Assistant's `ecoflow_cloud` exposes the AC, DC and USB outputs as switches, the charge and discharge limits, X-Boost,
generator auto-start, the beeper and the screen timeout. Today you can watch a power station and not operate it.

**What to build.** Output switches and charge limits on both routes:

- Developer API: `PUT /iot-open/sign/device/quota`, signed as every other call is (`EcoFlowAPI.signature`), with `sn`,
  `moduleType`, `operateType` and `params`.
- App route: the `set` topic of the account's MQTT broker. The newer units (STREAM, RAPID) take protobuf, which
  `Sources/EcoFlowProtobuf.swift` already encodes and decodes for the live stream.

**In HomeKit.** An Outlet per controllable output (`AC`, `DC12V`, `USB`), named after the port, on the device's
accessory beside the Battery. The charge and discharge limits are percentages with no fitting characteristic, so they
are Accessory Settings, as Renault's state-of-charge limits are (`Plugins/Renault`, spec 5.2) — not a Lightbulb's
brightness.

**The work, in order.**

1. `docs/clean-room/EcoFlowWrites.md`: the two set paths, each model's `moduleType`, `operateType` and parameter names,
   and which of them a model answers. Written from the open-source projects the README already credits plus captures
   from the author's own units, each fact marked with its source.
2. A `set` function on the `EcoFlowAPI` protocol, defaulting to a refusal, so a route that cannot write says so.
3. Outlets built from the model table; a model whose writes are unverified gets none and is marked **Untested** on the
   page, as the readings already are.
4. A refused or unanswered write fails the HomeKit write (the Home app shows it) and is followed by a read, as Tuya's
   are. The optimistic state is kept for two seconds while the device catches up.

**Done when** an output switches from the Home app on a STREAM and a RIVER 3, the page reflects it, and the tests drive
both routes against the existing fakes.

**Risk.** The app route is undocumented and EcoFlow can change it; a write sent to the wrong `moduleType` could change
a setting nobody asked for. Hence the spec first, and nothing published for a model whose writes were not seen.

## 2. A WebRTC stack

**The gap.** Two plugins advertise cameras whose streams cannot start:

- Ring: no live video and no two-way audio. `Plugins/Ring/Sources/RingCamera.swift:22` — "Live video needs WebRTC,
  which Homeswift has not: a stream request is refused." `homebridge-ring` has live video, two-way audio and HomeKit
  Secure Video.
- GoogleNestSDM: the 2021-and-later Nest Cam and Nest Doorbell have no live view and no HomeKit Secure Video; their
  motion, doorbell and clip-preview snapshots work. Both READMEs name the same cause.

Nothing in the repository speaks DTLS, ICE or STUN today (`grep -rwl` over `Sources/` and `Plugins/` finds the words
only in those two READMEs). This is the largest single piece of leverage in the list: one stack, two plugins, and the
Hue Entertainment API and HomeKit's own future WebRTC cameras behind it.

**What to build.** A new target in this package, `HomeswiftWebRTC` — a target, not a package, so plugins may depend on
it under the house rule. It receives a remote WebRTC stream and hands Homeswift's camera plumbing what it already
understands:

| Piece | Notes |
|---|---|
| ICE agent | Candidate gathering on the host's interfaces (`NetworkInterfaces`), STUN binding requests and responses, connectivity checks, trickle ICE. `UDPSocket` is already in `HomeswiftNetwork`. No TURN at first: both services offer host and server-reflexive candidates. |
| DTLS 1.2 | Client and server, with `use_srtp` so the SRTP keys are exported from the handshake. Written in Swift over swift-crypto: neither swift-nio-ssl nor swift-crypto exposes BoringSSL's DTLS, and a Swift implementation avoids a C target. Checked against OpenSSL's `s_server` and `s_client`. **Done.** |
| SRTP and SRTCP | AES-CM-128-HMAC-SHA1-80 at least. `Sources/Homeswift/Camera/RTPStreamManagement.swift` already does SRTP for HAP in the other direction; the key derivation is shared. |
| SCTP over DTLS | Only for the data channel Nest's signalling needs. Not required for Ring. Last, and skippable at first. |
| Signalling | Per plugin, not here: Ring's session over its own socket with trickle ICE; Nest's `GenerateWebRtcStream` SDP offer and answer, with `ExtendRtspStream`'s sibling to keep the session past Google's five minutes. |

**Into HomeKit.** WebRTC gives H.264 and Opus. H.264 passes through to HomeKit's SRTP; audio goes through
`HomeswiftFFmpeg`, which already decodes HomeKit's AAC-ELD for return audio (`Sources/HomeswiftFFmpeg/ReturnAudio.swift`)
and so can encode the other way. Two-way audio reverses the same path. HomeKit Secure Video reuses the prebuffer the
UniFi Protect and IP Cameras plugins already feed.

**The work, in order.**

1. STUN and ICE against published vectors (RFC 5389's test vectors), then a loopback agent in the tests.
2. The DTLS shim, checked against BoringSSL's own test server, and SRTP key export against RFC 3711's vectors.
3. SRTP and SRTCP, vectors first; nothing compared only against itself.
4. Ring: signalling, live video, then two-way audio. Ring first because its signalling is simpler and it needs no SCTP.
5. Nest: SDP offer and answer, the data channel, session extension, then HomeKit Secure Video.

**Done when** a Ring doorbell shows live video and passes speech both ways in the Home app, and a Nest Cam (battery)
does the same, with the streams ending cleanly when HomeKit stops reporting.

**Risks.** This is several times the size of any other item here and it is new attack surface: keep the C shim small and
vector-tested. Never log SDP, ICE credentials, SRTP keys or signalling bodies (sizes only), as the HAP rule already
requires. Ring's signalling is undocumented and can change; the spec records the version it was written from.

## 3. SwitchBot over Bluetooth

**The gap.** The plugin is cloud-only and says so: `connectionType: BLE` is refused with "Bluetooth is not supported:
set its connectionType to OpenAPI" (`Plugins/SwitchBot/Sources/SwitchBotPlugin.swift:360`), and the schema marks the
Bluetooth choices unsupported. Both `@switchbot/homebridge-switchbot` and Home Assistant's `switchbot` integration
drive the devices locally over Bluetooth Low Energy. Cloud-only means a Hub is required for every device, a ceiling of
10,000 requests a day, and nothing works while SwitchBot's cloud is down.

**What to build, first.** Lift Govee's Bluetooth client into the shared layer. `Plugins/Govee/Sources/BLEClient.swift`
already declares `BLECentral`, `BLEConnection`, `BLEAdvertisement` and `BLETarget`, with a CoreBluetooth implementation
on Darwin and a raw-HCI-plus-L2CAP one on Linux — but all of it is internal to the Govee plugin. Move it to
`HomeswiftNetwork` as a public `BLECentral`, keep Govee working on it unchanged, and put a fake central in
`HomeswiftNetworkTestSupport` beside `FakeMQTTConnection` and `FakeWebSocket`. Every later Bluetooth plugin then starts
from a tested client rather than a second copy.

That move carries Govee's hard-won platform notes with it, and they must stay documented: macOS grants Bluetooth only
to a binary whose `Info.plist` describes the use, and it asks the *responsible* process, so `homeswift` started from a
shell inherits that app's entitlement — the plugin turns Bluetooth off and logs which app is responsible rather than
letting macOS abort the bridge.

**Then the plugin.** `docs/clean-room/SwitchBotBLE.md` from `node-switchbot` and SwitchBot's published BLE
documentation, pinning the advertisement service data, the GATT service and the write and notify characteristics, the
command bytes per device type, and the encryption newer locks require (a key id and key the account's OpenAPI gives).
Byte layouts are never guessed; a device type whose frames the spec cannot pin stays on the cloud.

**Behaviour.** `connectionType` finally means what it says: `BLE` is local only, `OpenAPI` cloud only, `BLE/OpenAPI`
tries Bluetooth and falls back. Passive advertisements give the sensors their readings with no connection at all, which
takes Meters, Contact, Motion and Presence sensors off the request budget entirely — the single biggest relief to the
daily ceiling.

**Done when** a Bot, a Curtain 3, a Meter and a Lock work with the cloud turned off, the request counter stops counting
for devices on Bluetooth, and Govee still passes its tests on the shared central.

**Risk.** A lock over Bluetooth is a security control and stays one: its target state is written only through
`set_security_accessory`, confirmed, exactly as the cloud path is today.

## 4. A Home Assistant bridge plugin

**The gap, differently.** The community covers brands Homeswift has no plugin for at all: Eufy Security, Meross,
Nanoleaf, Wiz, Broadlink, Netatmo, Ecobee, Arlo, Nuki, Lutron, PowerView, Sensibo, Airthings, Levoit, Midea, MELCloud,
Home Connect, Miele, Ecovacs and Dreame, Enphase and SolarEdge, Apple TV, AVRs, Tesla. Writing twenty-five plugins is
years of work. Reading one hub is weeks, and a great many people already run Home Assistant beside their bridge.

**What to build.** `Plugins/HomeAssistant`, over Home Assistant's WebSocket API at `/api/websocket` with a long-lived
access token: `get_states` for the entities, `subscribe_events` (or `subscribe_trigger`) for changes, `call_service`
for writes, and `config/entity_registry/list` and `config/device_registry/list` for identity and grouping. The
domain-to-service mapping is the same shape `Zigbee2MQTT` and `ZWaveJS` already use, and `MQTTThing`'s table is the
precedent for how wide it can get.

**Identity matters most.** Key accessories on the entity registry's `unique_id`, never on `entity_id`, which a person
renames freely: aids and iids must stay stable for an accessory `id` or HomeKit loses rooms, scenes and automations.
Device Ids are `HomeAssistant:<unique_id>`; a Home Assistant device with several entities becomes one accessory with a
service each, grouped by the device registry.

**Not twice in Apple Home.** Home Assistant has its own HomeKit bridge, and a user may already expose some of these
entities to Apple Home. Entities Homeswift must show but never publish again use `Accessory.mirroredFrom`, the
mechanism `Plugins/Wingman` already uses for Apple Home's own accessories (docs/plugins.md): they join the web UI's
Accessories page, scenes, automations and the MCP tools without reaching HomeKit a second time. Which entities are
mirrored and which are published is a setting, defaulting to published, with a clear note in the README about running
both bridges.

**Setup.** Add accessories asks for the server's address (found over mDNS, `_home-assistant._tcp`, and confirmed by the
person, since anyone on the network can announce one) and a long-lived access token, checks it with a `get_states`, and
keeps it in the vault. Entities are then listed and any of them can be Excluded — with a sensible default, since a
Home Assistant install has hundreds and HomeKit should not get all of them.

**Done when** lights, switches, covers, locks, climate, sensors, binary sensors, fans, media players and scenes from a
real Home Assistant appear and drive correctly, a renamed entity keeps its accessory, and the tests run the plugin
against a fake WebSocket server (`TestSocketServer`).

**Risks.** Scope: the mapping table can grow forever, so the first release names the domains it covers and leaves the
rest logged as unsupported, the way `ESPHome` and `Zigbee2MQTT` do. Loops: a Homeswift accessory re-imported from Home
Assistant's HomeKit bridge and published again would double. Excluding Homeswift's own entities by their manufacturer
is the guard, and a warning in the log when one is seen.

## 5. The rest

**Roborock: rooms and clean modes.** No room or segment cleaning, no suction or mop selection, no find-me, no clearing
an error the robot keeps reporting. Closer than it looks: `fan_power` and `water_box_mode` are already parsed
(`Plugins/Roborock/Sources/RoborockMessages.swift:11`) and never written, and the Matter path already maps the robot to
`roboticVacuum` (`Sources/HomeswiftMatter/ServiceMapping.swift:147`) without the ServiceArea cluster that would carry
the rooms. Upstream's Matter beta has rooms, clean modes, multi-floor maps and identify; HomeKit itself offers a robot
no room control, so the rooms land on the Matter side and the web UI, and the clean modes become switches or Accessory
Settings on the HAP side.

**Hardware confirmation.** Thirteen plugins are tested against fakes only and say so: ESPHome, Zigbee2MQTT, ZWaveJS,
Sonos, SwitchBot, XiaomiMiot, Tapo, MagicHome, SmartThings, Roborock, EcoFlow, Weather and Presence. This is the
biggest practical difference from a community plugin with thousands of installs — larger than any missing feature on
this page — and it is the one thing on it that needs other people rather than code. It belongs in the tracker as a
`help wanted` checklist, one line per plugin, and each confirmation turns a README's "Experimental" into a version and
a firmware the plugin was seen working on.

**Left in the READMEs, deliberately.** These are long tails, not work items that ever close, and each is already
written down where a reader will find it:

| Plugin | What the community has |
|---|---|
| Tapo | Discovery; H100/H200 hubs and their sub-devices (T110, T310/T315, S200B, KE100); P300 strips; wired cameras; L900 segments and effects; KLAP's newer variant |
| ESPHome | Text sensors, numbers, selects, sirens, valves, media players, events, locks with a code, light transitions and white channels, fan presets, climate fan and swing modes |
| XiaomiMiot | Per-model handlers for kettles, water purifiers, towel racks, ovens and air fryers, bath heaters; Bluetooth and Zigbee sub-devices through a gateway |
| TPLinkSmarthome | KLAP devices, light-strip effects and segments |
| Shelly | Sleeping Gen 2 devices (Plus H&T, Plus Smoke), BLU behind a gateway, Gen 2 temperature and humidity components, scripts and virtual components |
| ElgatoKeyLights | Light Strip colour, Key Light Mini battery and studio mode, Wi-Fi signal, restart |
| ZWaveJS | Thermostat Fan Mode, Scene Activation, Humidity Control, Indicator, Protection. Configuration parameters and firmware stay in Z-Wave JS UI by design |
| Presence | iCloud and Find My, Bluetooth, a router's or UniFi controller's client list, phone geofencing. `PresenceSource` is the hook and is unused |
| Weather | Forecasts, and weather services other than Open-Meteo |
| PhilipsHue | homebridge-hue's API v1 bridges, schedules, CLIP sensors and Hue Labs; the Entertainment API needs DTLS, which item 2 brings |

A gap moves off this table and into the order above when someone wants it enough to say so.

## One documentation change

docs/plugins.md should say outright what the plugins already practise: **a plugin's README names the upstream it ports
or competes with, and states its gaps against it.** Thirty of the forty-four do, which is why this comparison was
possible at all; making it a stated expectation keeps the next port honest, and keeps parity out of a hand-maintained
table that nothing can check.
