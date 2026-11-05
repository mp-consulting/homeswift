# Shelly

**Experimental**: written from a functional specification and tested against fakes of the devices, not yet on real
hardware.

Puts Shelly devices in HomeKit, on the local network, without the Shelly cloud. One plugin, two platforms, so the blocks
of both Homebridge plugins load unchanged:

| Platform | Devices | How |
|---|---|---|
| `ShellyNG` | Gen 2, Gen 3 and Gen 4 (Plus, Pro, Gen3, Gen4) | Found over mDNS (`_shelly._tcp`), at the addresses config.json gives and where they were last seen; driven over the device's WebSocket RPC at `ws://<host>/rpc`, whose `NotifyStatus`, `NotifyFullStatus` and `NotifyEvent` keep HomeKit current without polling |
| `Shelly` | Gen 1 (Shelly 1, 1PM, 1L, 2, 2.5, 4Pro, HD, Uni, Plug, Plug S, Plug US, Air, EM, 3EM, Bulb, Bulb RGBW, RGBW2, Duo, Vintage, Dimmer, Dimmer 2, Button1, i3, Door/Window, Door/Window 2, Flood, H&T, Gas, Sense, Motion) | Heard over CoIoT, the CoAP status the devices multicast to 224.0.1.187:5683 on every change; driven over their HTTP API |

Each family runs only when its block is there: a `ShellyNG` block alone does not listen for Gen 1 devices.

## What each device becomes

**Gen 2+**, as homebridge-shelly-ng has them:

- A relay (`switch:N`) is a Switch, or an Outlet with the device option `"type": "outlet"`; with a Power Meter (Eve's
  Consumption, Voltage, Electric Current and Total Consumption) on a metering model. One relay is the accessory
  `<deviceId>-switch`; several are `<deviceId>-switch-N`, named `Switch N+1`.
- A 2PM in cover profile is a Window (the original's default, kept for compatibility), a Door or a Window Covering
  (`cover:0.type`), with its Power Meter, as `<deviceId>-cover`. An uncalibrated cover is published without controls
  and logs `Only calibrated covers are supported.`
- The Plus I4's inputs: those configured as buttons are Stateless Programmable Switches on `<deviceId>-buttons`
  (single, double and long press), the others read-only Switches `<deviceId>-switchN`.
- Beyond the original: `light:N` (white dimmers) are Lightbulbs with Brightness; `rgb:N` and `rgbw:N` add Hue and
  Saturation; `cct:N` adds Color Temperature and Adaptive Lighting; `em:N`, `em1:N` and `pm1:N` (Pro 3EM, Pro EM, PM
  Mini) are Power Meters. Every metered component is a Meter whose Consumption the bridge keeps by the hour for years;
  an `em` or `em1` also keeps what it sent back (Returned), and a whole home's meter (an `em`, or the first `em1`) is
  suggested as the grid on the Status page's Energy section. Each Meter's Energy Role can be changed in its accessory's
  settings (a Pro EM's second clamp on the solar, say). The weeks of per-minute records an `em` or `em1` keeps
  are imported into its Meter by the hour as it connects, a day at a time from its CSV (`/emdata/<id>/data.csv`), the
  newest days first, then on from where the last import stopped.
  Models the original did not know (Plus Plug S, Gen3, Gen4…) are mapped from
  the components their status lists.

**Gen 1**, as homebridge-shelly has them: relays as switches (or `outlet`, `valve`, `contactSensor`, `motionSensor`,
`occupancySensor`) with a Power Meter where the model meters; a Shelly 2 or 2.5 in roller mode as a Window Covering (or
`window`, `door`, `garageDoorOpener`); dimmers and the RGBW2's white channels as Lightbulbs; the Duo with Color
Temperature and Adaptive Lighting; the Bulbs and the RGBW2 in colour mode with Hue and Saturation (`colorMode` `rgbw` or
`rgb`); Button1 and i3 as Stateless Programmable Switches; the sensors with their Contact, Motion, Leak, Smoke,
Temperature, Humidity, Light, Tilt and Battery services. An EM's or 3EM's power meter is one Meter for the whole device
(its phases added up, with the energy counted and sent back), suggested as the grid on the Energy section.

Accessory ids keep the Homebridge plugins' seeds, so a device keeps its identity: `ShellyNG:<deviceId>-<accessory>`
(`ShellyNG:shellyplus1pm-aabbccddeeff-switch`) and `Shelly:<model name> <device id>[ #<index>]`
(`Shelly:Shelly 2.5 A4CF12 #1`). A Gen 1 device changing mode (relay to roller, colour to white) gets new accessories,
as it did.

## Configuration

Both Homebridge blocks paste as they are:

```json
{
  "platform": "ShellyNG",
  "name": "Shelly NG",
  "devices": [
    { "id": "shellyplus1pm-aabbccddeeff", "name": "Kitchen", "switch:0": { "type": "outlet" } },
    { "id": "shellypro2pm-aabbccddeeff", "hostname": "192.168.1.40", "password": "…", "cover:0": { "type": "windowCovering" } }
  ],
  "mdns": { "enable": true, "interface": "eth0" },
  "websocket": { "requestTimeout": 10, "pingInterval": 60, "reconnectInterval": "5,10,30,60,300,600" }
}
```

```json
{
  "platform": "Shelly",
  "name": "Shelly",
  "username": "admin", "password": "…",
  "networkInterface": "192.168.1.10",
  "requestTimeout": 10000,
  "staleTimeout": 0,
  "devices": [
    { "id": "74B5A3", "exclude": true },
    { "id": "6A78BB", "colorMode": "rgb" },
    { "id": "1D56B0", "accessories": [{ "type": "outlet" }, { "type": "switch", "name": "Fan" }] }
  ]
}
```

What the bridge writes is the canonical shape (docs/adr/0001-canonical-accessory-settings.md): each device's options
move into `_accessories` by its Device Id (the Gen 2 id lowercased, the Gen 1 id uppercased), its `name` as the Name and
`exclude` as Excluded; passwords move into the vault. The settings editor shows `hostname`, `switch:0` … `switch:3` and
`cover:0` for Gen 2 devices, `type`, `colorMode` and `accessories` for Gen 1 ones. Gen 1's `admin` block (the original's
own page) is read and ignored: the web UI replaces it. `protocol: "outboundWebsocket"` fails that device, as it did.

### Passwords

A device whose authentication is on asks for its password on **Add accessories** (Setup): Gen 2+ devices need the
password only (the user is always `admin`), Gen 1 devices their restricted login's user name and password. The bridge
checks them and keeps them in the vault. A `password` in a block is a secret-named key, sealed and masked like any
other, and moves into the vault with the next settings write; Gen 1's block-wide `username` and `password` become the
account's, used for every device without its own.

## What it does better than the originals

- mDNS follows a Gen 2 device to its new address after a DHCP change; the original kept trying the old one.
- After a reconnection the status is read again, so changes missed while away show up.
- A device listed with an address that does not answer at start-up is retried with a backoff, and its cached accessories
  answer No Response meanwhile; a failed attempt leaves no connection behind.
- A cover moved from a wall switch gets its target set to where it stopped, instead of staying "Opening…".
- Digest authentication answers with a fresh nonce count per request and takes a new nonce when the device says the old
  one is stale, as aioshelly does.
- A Gen 1 Button1 or i3 made from the cache does not fire a press for its last event when it is first heard again.
- Slider writes (brightness, colour, cover position) are coalesced into one request.

## Gaps

- Sleeping Gen 2 devices (Plus H&T, Plus Smoke) connect out to a server rather than wait for one: not supported, as in
  the original.
- BLU devices behind a gateway, and Gen 2 temperature and humidity components, are not mapped.
- `mdns.interface` given as an address checks it is the host's but browses every interface; a name filters by interface.
- The Gen 2 `light`, `rgb`, `rgbw`, `cct`, `em1` and `pm1` field names come from Shelly's public API documentation
  (https://shelly-api-docs.shelly.cloud), not from the Homebridge plugin, which has no mapping for them.

## Tests

`swift test --filter ShellyTests` runs the plugin against fakes: a Gen 2 device behind an in-memory WebSocket that
answers from fixtures, challenges with a digest and pushes notifications; CoIoT datagrams and an HTTP fake for Gen 1.
They cover the spec's vectors (the digest exchange, the CoIoT packet), the accessories each layout makes, writes,
notifications, reconnection, mDNS address changes, Excluded and unknown devices, stale removal, Adaptive Lighting and
the canonical settings. The CoAP codec's tests are in `Tests/HomeswiftNetworkTests/CoAPTests.swift`.

## Clean-room implementation

Compatible with the configuration of [homebridge-shelly-ng](https://github.com/alexryd/homebridge-shelly-ng) (GPL-3.0)
and [homebridge-shelly](https://github.com/alexryd/homebridge-shelly) (MIT) by Alexander Rydén, and their libraries
shellies-ng and shellies; protocol details cross-checked with Home Assistant's aioshelly (Apache-2.0). Written from the
functional specification in [docs/clean-room/Shelly.md](../../docs/clean-room/Shelly.md), without reading or copying
their code. Shelly's public API documentation (https://shelly-api-docs.shelly.cloud) was used for the components the
originals do not map.

Maintainer: Mickael Palma.
