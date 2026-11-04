# Shelly: functional specification (clean room)

Written by the spec writer; contains no source code. Everything below is a description, in the spec writer's
own words, of the behaviour of the sources listed under Provenance. Identifiers that are part of an interface
(JSON keys, RPC method names, HTTP paths, CoAP option numbers, enum strings, characteristic UUIDs) are quoted
exactly because they are wire or configuration interfaces.

## 0. Provenance

| Source | Role | Commit read | Licence | Copyright holder | Package |
|---|---|---|---|---|---|
| https://github.com/alexryd/homebridge-shelly-ng | Homebridge plugin for Gen 2+ (primary config interface) | `1da481054a089dbdd2260e6c88cd7cff92143cd1` (package version 1.6.0) | GPL-3.0 | Alexander Rydén | npm `homebridge-shelly-ng` |
| https://github.com/alexryd/node-shellies-ng | The Gen 2 protocol library the plugin above depends on (`shellies-ng` ^1.5.1); read for model ids, WebSocket RPC, digest auth, mDNS | `57f4380a78cfd37c6646978a4e9833cb65bceef1` (version 1.5.1) | GPL-3.0 | Alexander Rydén | npm `shellies-ng` |
| https://github.com/alexryd/homebridge-shelly | Homebridge plugin for Gen 1 | `a1f9a8c1cbe6c61c7e4efa255672fb7eae601492` (version 0.19.1) | MIT | Copyright (c) 2018 Alexander Rydén | npm `homebridge-shelly` |
| https://github.com/alexryd/node-shellies | The Gen 1 protocol library the plugin above depends on (`shellies` ^1.7.0); read for CoIoT, property ids, HTTP endpoints | `27ef11293809feb97dce358094f455c86d9f9ded` (version 1.7.0) | MIT | Copyright (c) 2018 Alexander Rydén | npm `shellies` |
| https://github.com/home-assistant-libs/aioshelly | Protocol cross-check: Gen 1 CoAP parsing, Gen 2 RPC frames, digest auth with nc/stale handling, BLU, model table | `6257a46666589c60d3e55c10fa0301719b7dc41f` | Apache-2.0 | Home Assistant library authors (the repository's LICENSE names no individual holder; it is the Apache 2.0 text) | PyPI `aioshelly` |

The two `node-*` libraries were not in the brief but the Homebridge plugins delegate all protocol work and the
model tables to them, so a drop-in replacement cannot be specified without them. They have the same author and
the same licences as the plugin that uses them. Nothing was executed; the repositories were read with text tools.

THIRD-PARTY-NOTICES: this spec copies no code, so no notice is strictly required; listing the five projects as
the behaviour's origin is still the honest thing to do.

---

## 1. Overview

Shelly devices come in two protocol families:

* **Gen 1** (model ids like `SHSW-1`, `SHPLG-S`, `SHRGBW2`): state is pushed by the device over **CoIoT** (CoAP over
  UDP, multicast group 224.0.1.187, port 5683); commands and settings use plain **HTTP GET** on port 80 with optional
  **HTTP Basic** auth. Homebridge plugin: `homebridge-shelly`, platform **`Shelly`**.
* **Gen 2 / Gen 3 / Gen 4** ("Plus", "Pro", "Gen3", "Gen4"; model ids like `SNSW-001P16EU`, `SPSW-004PE16EU`,
  `S3SW-…`, `S4SW-…`): a JSON-RPC 2.0-like protocol over a **WebSocket at `ws://<host>/rpc`** (also over HTTP `/rpc`),
  with state pushed as `NotifyStatus`/`NotifyFullStatus`/`NotifyEvent` frames; optional **SHA-256 digest** auth with
  the fixed user `admin`. Discovery over mDNS service `_shelly._tcp.local`. Homebridge plugin:
  `homebridge-shelly-ng`, platform **`ShellyNG`**.

The Homeswift plugin is one plugin that must accept **both** blocks, unchanged:

* a platform block with `"platform": "ShellyNG"` (Gen 2+ options, section 2.1), and
* a platform block with `"platform": "Shelly"` (Gen 1 options, section 2.2).

Each Homebridge plugin declares itself "singular" in spirit (ShellyNG's schema sets `singular: true`; the Gen 1 plugin
registers a single dynamic platform). A user typically has at most one block of each.

---

## 2. Configuration interface

### 2.1 `ShellyNG` block (Gen 2+)

Platform name: `ShellyNG`. Plugin name: `homebridge-shelly-ng`. Every option is optional except `name`, which
Homebridge requires (schema default `"Shelly NG"`).

```
{
  "platform": "ShellyNG",
  "name": "Shelly NG",
  "devices": [ <DeviceOptions>, ... ],
  "mdns": { "enable": true, "interface": "eth0" },
  "websocket": { "requestTimeout": 10, "pingInterval": 60, "reconnectInterval": [5,10,30,60,300,600] }
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | `"Shelly NG"` | Platform display name (log prefix). |
| `mdns` | object | `{ "enable": true }` | mDNS discovery settings. Merged key by key over the default. |
| `mdns.enable` | boolean | `true` | mDNS discovery runs only when the value (after merging over the default, so an absent key means `true`) is exactly boolean `true`; any other value, e.g. `false` or `"true"`, disables it. |
| `mdns.interface` | string | unset (all interfaces) | Network interface **name** (e.g. `eth0`) or a local **IP address** (e.g. `192.168.1.100`). A name resolves to that interface's first address; an address must match one of the host's addresses; otherwise discovery fails to start with an error "Invalid network interface "<value>"" (logged, plugin continues without mDNS). |
| `websocket` | object | see below | WebSocket client settings, merged key by key over defaults. |
| `websocket.requestTimeout` | integer, seconds | `10` | Time to wait for an RPC response before the request fails. Also the time to wait for a pong after a ping before the socket is killed. |
| `websocket.pingInterval` | integer, seconds | `60` | Interval between WebSocket protocol pings once connected. `0` (or negative) disables pings. |
| `websocket.reconnectInterval` | number, array of numbers, **or** string of comma-separated numbers | `[5, 10, 30, 60, 300, 600]` | Back-off schedule in seconds after an unintentional close. A string like `"5,10,30,60,300,600"` is split on `,` and each part parsed as a base-10 integer (the UI schema stores it as a string). The n-th consecutive attempt uses the n-th value; after the last value is reached it is reused forever. A value of `0` (or ≤0) at the current position stops reconnecting; `0` alone or an empty list disables reconnection. The index resets to the first value whenever a connection opens. |
| `devices` | array of DeviceOptions | `[]` | Per-device overrides. Entries without a string `id` are ignored. |

DeviceOptions (an element of `devices`):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string, required | — | Gen 2 device id, e.g. `shellyplus1-abcdef123456` (the mDNS instance name / `Shelly.GetDeviceInfo` `id`). Matched **case-insensitively**: the configured id is lowercased when stored and looked up with the device's id as reported (devices report lowercase). No trimming is done in ShellyNG. |
| `name` | string | unset | Accessory base name (see 3.1). Only used when an accessory is first created; the source's documentation says changing it later does not rename in HomeKit. |
| `exclude` | boolean | `false` | Ignore this device entirely: no connection, cached accessories removed, removed from the device cache. |
| `hostname` | string | unset | IP or hostname; the device is connected to directly at start-up (useful without mDNS). |
| `password` | string | unset | **Secret.** Password for digest auth (the user name is always `admin`). |
| `protocol` | string | `"websocket"` | Not in the UI schema, but an accepted key of the internal options. Only `"websocket"` is usable; `"outboundWebsocket"` makes every device fail with "No WebSocket server has been configured". Treat any other value as an error for that device. |
| `switch:0` … `switch:3` | object | unset | Per-switch-component overrides (keys are literally `"switch:0"`, `"switch:1"`, `"switch:2"`, `"switch:3"`, i.e. the RPC component key). |
| `switch:N.exclude` | boolean | `false` | Do not publish the accessory for switch N. |
| `switch:N.type` | string `"switch"` \| `"outlet"` | `"switch"` | HomeKit service used for switch N. Compared case-insensitively (lowercased); any value other than `outlet` means switch. |
| `cover:0` | object | unset | Override for the cover component (only meaningful when a 2PM device is in cover profile). |
| `cover:0.exclude` | boolean | `false` | Do not publish the cover accessory. |
| `cover:0.type` | string `"door"` \| `"window"` \| `"windowCovering"` | `"window"` | HomeKit service for the cover. Compared after lowercasing (`door`, `windowcovering`); anything else means `window`. **Note the default is Window, not Window Covering.** |

The UI schema shows `switch:1..3` and `cover:0` only for models that have them (by id prefix: `switch:0` for
`shellyplus1|shellyplus1pm|shellyplus2pm|shellyplusplug|shellyplusplugus|shellypro1|shellypro1pm|shellypro2|shellypro2pm|shellypro3|shellypro4pm`;
`switch:1` for `shellyplus2pm|shellypro2|shellypro2pm|shellypro3|shellypro4pm`; `switch:2` for `shellypro3|shellypro4pm`;
`switch:3` for `shellypro4pm`; `cover:0` for `shellyplus2pm|shellypro2pm`). This is presentation only; the runtime
reads any `switch:N`/`cover:0` key present for a component that exists.

Option merging: a configured device's options are its own keys laid over `{ exclude: false, protocol: "websocket" }`.
An unconfigured device gets those defaults.

### 2.2 `Shelly` block (Gen 1)

Platform name: `Shelly`. Plugin name: `homebridge-shelly`.

```
{
  "platform": "Shelly",
  "name": "Shelly",
  "username": "admin", "password": "…",
  "networkInterface": "192.168.1.10",
  "requestTimeout": 10000,
  "staleTimeout": 0,
  "admin": { "enabled": true, "port": 8181 },
  "devices": [
    { "id": "74B5A3", "exclude": true },
    { "id": "A612F0", "username": "admin", "password": "…" },
    { "id": "6A78BB", "colorMode": "rgb" },
    { "id": "AD2214", "name": "My Device" },
    { "id": "1D56AF", "type": "outlet" },
    { "id": "1D56B0", "accessories": [ { "type": "outlet" }, { "type": "switch", "name": "Fan" } ] }
  ]
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | `"Shelly"` | Platform display name. |
| `username` | string | unset | Global HTTP Basic user. Used only if **both** `username` and `password` are non-empty. |
| `password` | string | unset | **Secret.** Global HTTP Basic password. |
| `networkInterface` | string | unset | Interface **name** or local **IPv4 address** on which to join the CoIoT multicast group. A name resolves to its first address; an address must match a local address; an unknown value is logged as a warning ("ignoring unknown network interface name or address …") and ignored (default interface used). |
| `requestTimeout` | integer, milliseconds | `10000` | HTTP request timeout. Applied only if it is a number. |
| `staleTimeout` | integer, milliseconds | `0` (disabled) | How long a device may stay **offline** before its accessories are unregistered and the device forgotten. Applied only if a number; acts only if an integer > 0. The README also allows `false` (= disabled). |
| `admin` | object | `{ enabled: true, port: 8181 }` | The original plugin's own HTTP admin page and JSON API (section 7.8). |
| `admin.enabled` | boolean | `true` | Only an explicit `false` disables it. |
| `admin.port` | integer | `8181` | Port for that server (schema maximum 65353). |
| `devices` | array | `[]` | Per-device overrides; entries without `id` are skipped. |
| `devices[].id` | string, required | — | Gen 1 device id: 6 or 12 hexadecimal characters (schema pattern `^[A-Fa-f0-9]{6,12}$`), as printed in Settings → Device info → Device ID. Normalised by **uppercasing and trimming** before lookup. |
| `devices[].name` | string | unset | Accessory name (see 3.2). |
| `devices[].type` | string | model default | Accessory type for relay devices and Shelly 2/2.5 in roller mode (section 8.3). Typeahead values in the schema: `colorLightbulb`, `colorTemperatureLightbulb`, `contactSensor`, `door`, `garageDoorOpener`, `motionSensor`, `occupancySensor`, `outlet`, `sensor`, `statelessSwitch`, `switch`, `valve`, `whiteLightbulb`, `window`, `windowCovering`. |
| `devices[].colorMode` | string `"rgb"` \| `"rgbw"` | `"rgbw"` | For colour lights: whether the W channel is driven. Any other value is an error for that accessory ("Invalid color mode"). |
| `devices[].username` | string | unset | Per-device Basic user (with `password`, overrides the global pair). |
| `devices[].password` | string | unset | **Secret.** Per-device Basic password. |
| `devices[].exclude` | boolean | unset/false | Ignore the device; cached accessories for it are dropped at start-up. |
| `devices[].accessories` | array of objects | unset | **Undocumented but read**: element *i* is merged over the device object (its keys win) to form the configuration of the device's accessory number *i* (so `type`, `name`, `colorMode` can differ per relay/channel). The `accessories` key itself is removed from the merged result. |

Credential precedence for a device: per-device `username`+`password` if both set, else the global pair if both set,
else none.

### 2.3 Accepting both blocks in one plugin

* The two blocks are independent: a `Shelly` block configures Gen 1 discovery (CoIoT) and Gen 1 devices; a `ShellyNG`
  block configures Gen 2+ discovery (mDNS) and Gen 2+ devices. Device ids never collide (Gen 1 ids are bare hex;
  Gen 2 ids are `<app-lowercase>-<12 hex>`).
* If only one block exists, the other family's original plugin would not be running. A drop-in replacement must not
  start publishing Gen 1 accessories for a user who only had `ShellyNG` unless the implementer deliberately decides to
  (gap G1).
* Secrets: the keys `password` (top level of `Shelly`, and in every device entry of both blocks) are secrets. Both are
  secret-named keys, so Homeswift's runtime will seal and mask them. `username` is a credential but not secret.
* Gen 1's `admin` block configures a separate HTTP server that Homeswift does not need (its own UI replaces it). The
  block should be read and accepted without error.

---

## 3. Accessory identity and naming

HomeKit identity in Homebridge is a UUID derived from a seed string with HAP-NodeJS's `uuid.generate` (a SHA-1
hash of the seed formatted as a version-4-looking UUID). Homeswift keys accessories by an `id` string; to keep the
same identity rules, use the **seed strings below** (prefixed per Homeswift convention). What must not change: a
given physical component maps to the same seed across restarts, IP changes and firmware updates.

### 3.1 Gen 2+ (ShellyNG)

Seed: `"<deviceId>-<accessoryId>"`, where `<deviceId>` is the `id` returned by `Shelly.GetDeviceInfo` (lowercase,
e.g. `shellyplus1pm-aabbccddeeff`) and `<accessoryId>` is:

| Situation | accessoryId | Name suffix |
|---|---|---|
| Device with a single switch (Plus 1, Plus 1 PM, Plus Plug US, Pro 1, Pro 1 PM) | `switch` | none |
| Device with several switches (Plus 2 PM and Pro 2 PM in switch profile, Pro 2, Pro 3, Pro 4 PM), switch N (0-based) | `switch-N` | `Switch N+1` |
| Cover (Plus 2 PM / Pro 2 PM in cover profile) | `cover` | `Cover` |
| Plus I4: the accessory holding all inputs configured as buttons | `buttons` | none |
| Plus I4: input N configured as a switch | `switch0`, `switch1`, `switch2`, `switch3` (no dash) | none |

Examples: `shellyplus1pm-aabbccddeeff-switch`, `shellypro4pm-aabbccddeeff-switch-3`, `shellyplus2pm-aabbccddeeff-cover`,
`shellyplusi4-aabbccddeeff-buttons`, `shellyplusi4-aabbccddeeff-switch2`.

Accessory display name: base + (" " + suffix if any), where base is the first non-empty of: configured
`devices[].name`; the device's own name `Shelly.GetConfig` → `sys.device.name`; the model name from the table in
5.1 (e.g. `Shelly Plus 1 PM`). The I4's accessories all get the bare base name.

Accessory Information service (every accessory):

| Characteristic | Value |
|---|---|
| Name | the accessory display name |
| Manufacturer | `Allterco` |
| Model | model name from 5.1 (e.g. `Shelly Pro 4 PM`; revisions share the name of the base model) |
| SerialNumber | `mac` from `Shelly.GetDeviceInfo` (12 uppercase hex, no separators, e.g. `AABBCCDDEEFF`) |
| FirmwareRevision | `ver` from `Shelly.GetDeviceInfo` (e.g. `1.1.0`), or `1.0.0` if absent |

Category: not set (Homebridge's default, "Other").

Every service of an accessory carries a fixed display name and subtype (section 5.4). Each accessory stores the
device id in its context so that excluded devices' cached accessories can be found and removed.

### 3.2 Gen 1 (Shelly)

Seed: the accessory's **default name** at creation time:

* `"<modelName> <deviceId>"` if the device has one accessory, e.g. `Shelly 1PM A4CF12F45678`;
* `"<modelName> <deviceId> #<index>"` if the device has several (index 0-based), e.g. `Shelly 2.5 A4CF12 #1`,
  `Shelly RGBW2 B5E2C1 #3`.

`<modelName>` is the node-shellies model name in 8.1 (these differ from aioshelly's names in places: `Shelly Duo`
not `Shelly DUO`, `Shelly Plug` for `SHPLG2-1` not `Shelly Plug E`, `Shelly Button1` for both buttons). `<deviceId>` is
the id exactly as it arrives in the CoIoT device-id option (section 7.2), normally uppercase hex.

Number of accessories per device depends on the model **and mode** (8.3): Shelly 2 / 2.5 have 2 in relay mode and 1 in
roller mode; RGBW2 has 4 in white mode and 1 in colour mode; Shelly HD and Uni have 2; Shelly 4Pro has 4; all other
supported models have 1. So a mode change produces different seeds (new accessories), which is the original
behaviour.

Quirk to be aware of (do not copy unless matching it exactly matters): the original computes the default name from
the device's *name* if one is known at that moment (the configured `name`, or the name from `/settings`) instead of
`modelName id`. On first discovery no name is known yet, so the seed is `modelName id`; but when the original
re-creates an accessory because its configured `type` changed, the configured `name` may already be applied and the seed
becomes `"<configured name>"` (+ ` #i`). The recommended rule for the replacement is always `modelName id (#i)`.

Accessory display name: first non-empty of the accessory configuration's `name` (after the `accessories[i]` merge),
the device's name (the configured device `name`, which the original writes onto the device object, else
`/settings` → `name`), else the default name above.

Accessory Information:

| Characteristic | Value |
|---|---|
| Manufacturer | `Shelly` |
| Model | the model id (CoIoT type), e.g. `SHSW-PM` |
| SerialNumber | the device id, e.g. `A4CF12F45678` |
| FirmwareRevision | from `/settings` → `fw` (e.g. `20230913-113421/v1.14.0-gcb84623`): the first `v` followed by dot-separated digits, without the `v` (`1.14.0`); if there is no such match, the whole string. Set when settings are (re)loaded. |
| HardwareRevision | `/settings` → `hwinfo.hw_revision` (e.g. `prod-190516`) when present |
| Name | updated to the accessory name only when `/settings` → `name` equals the accessory's current name |

Category per accessory type: switch → Switch; outlet → Outlet; valve → Faucet; contact/motion/occupancy/sensor →
Sensor; lightbulbs → Lightbulb; door → Door; window → Window; windowCovering → Window Covering; garageDoorOpener →
Garage Door Opener; stateless switches → Other.

Each accessory persists `{ type, id, host, accessoryType, index, mode? }` (model id, device id, last IP, accessory type
string, accessory index, device mode if the model has modes) so that it can be re-created at start-up before the
device is heard from (7.6).

---

## 4. Gen 2+ transport and protocol

### 4.1 Discovery

Three sources feed one de-duplicating discovery pipeline, run in this order at start-up:

1. **Configured devices**: every `devices[]` entry with a `hostname` is "discovered" with that host (one every 20 ms).
2. **Device cache**: every device in the cache file (4.7) is discovered with its cached host (one every 20 ms).
3. **mDNS**, if `mdns.enable` is `true`: open an mDNS socket (on `mdns.interface` if set), send one query for
   `_shelly._tcp.local` type `PTR`, then keep listening passively to every mDNS response on the network.
   A response is used when its **answers** section contains a `PTR` record whose name is `_shelly._tcp.local` and has
   data; the device id is the instance name, i.e. the data up to the first `.` (e.g.
   `shellyplus1pm-aabbccddeeff._shelly._tcp.local` → `shellyplus1pm-aabbccddeeff`). The IP is the data of the last
   `A` record in the same **answers** section (records in the additional section are not looked at). Responses
   without an `A` answer are ignored. Logged: info "mDNS device discovery started"; error on failure to start.

A discovered `(deviceId, host)` is ignored if that id is already added, being added, or ignored (unknown model or
excluded). Otherwise:

* if the device's options say `exclude`, the id is marked ignored, its cache entry and accessories are removed, info
  "[<id>] Device excluded";
* else a WebSocket RPC handler is created for `host` and `Shelly.GetDeviceInfo` is called;
* the returned `id` must equal the discovered id exactly, otherwise the attempt fails ("Unexpected device ID
  (returned: X, expected: Y)");
* the returned `model` is looked up (case-insensitive) in 5.1; unknown → id marked ignored for the rest of the run,
  info "[<id>] Unknown device of model "<model>" discovered." (Note: `SNSN-0013A` Plus H&T is known to the library but
  has no accessory mapping in the plugin, so it also ends up as "unknown".)
* then `Shelly.GetStatus` and `Shelly.GetConfig` are called and their per-component objects stored;
* then the device is added (accessories created, 5.3) and its `{id, model, protocol:"websocket", hostname}` stored in
  the cache.

Any failure in these steps logs an error "Failed to add discovered device (id: <id>): <message>" and forgets the
attempt, so the next discovery of that id (e.g. the next mDNS response) retries. Once a device has been added, later
discoveries with a different IP are ignored for the rest of the run (gap G4).

### 4.2 WebSocket connection

* URL: `ws://<hostname>/rpc` (port 80, no TLS).
* The connection is opened as soon as the handler is created; any request first waits for the socket to be open. If a
  socket is closed when a request is made, a new socket is opened.
* Client source id: every outgoing frame carries `"src": "<clientId>"`. The original uses
  `homebridge-shelly-ng-<random integer 0..1000000>`; any stable unique string works. Replies carry it back as `dst`.
* Ping: after the socket opens, and after each pong, a protocol-level WebSocket ping is scheduled `pingInterval`
  seconds later. If no pong arrives within `requestTimeout` seconds after a ping, the socket is terminated (abnormal
  close → reconnection).
* Close handling: on any close with a code other than 1000 a reconnect is scheduled from `reconnectInterval`; code 1000
  (an intentional close) does not reconnect. The plugin logs:
  * warning `Device disconnected (reason: <reason>)` if it had been connected, else `Connection failed (code: <code>)`
    (the reason text is used when non-empty, otherwise the code);
  * info `Reconnecting in N second(s)` / `N minute(s)` / `N hour(s)` (floor; seconds below 60 s, minutes below 60 min).
  * info `Device connected` on each open.
* There is **no periodic polling**. After the initial `Shelly.GetStatus`/`Shelly.GetConfig`, state comes only from
  notifications. After a reconnect the original does **not** re-fetch the status (gap G5); a replacement should call
  `Shelly.GetStatus` after each reconnect (devices also send `NotifyFullStatus` in some cases).
* Pending requests are rejected with "Connection closed" when the handler is destroyed; each request also times out
  after `requestTimeout` seconds.
* aioshelly for comparison: WebSocket heartbeat 55 s, call timeout 10 s, device init timeout 30 s, receive buffer
  64 KiB.

### 4.3 Frames

Requests (client → device), one JSON text message each:

```
{ "src": "<clientId>", "jsonrpc": "2.0", "id": <positive integer>, "method": "<Component.Method>",
  "params": { ... }, "auth": { ... } }
```

`params` is omitted when there are none; keys whose value is undefined are omitted (e.g. `toggle_after`, `rel`);
`auth` is present only once a challenge has been answered (4.4). Ids increase per connection. aioshelly sends the same
shape without `jsonrpc` (the device does not require it) and may add `dst`.

Responses (device → client): `{ "id": <same id>, "src": "<deviceId>", "dst": "<clientId>", "result": {...} }` or
`{ "id": ..., "src": ..., "dst": ..., "error": { "code": <int>, "message": "<string>" } }`.

Notifications (device → client, no `id`):

* `{"src": "<deviceId>", "dst": "<clientId>", "method": "NotifyStatus", "params": { "ts": <float unix time>, "<component key>": { <changed fields> }, ... } }`
* `{"src": ..., "method": "NotifyFullStatus", "params": { "ts": ..., <every component's full status> } }`
* `{"src": ..., "method": "NotifyEvent", "params": { "ts": ..., "events": [ { "component": "input:0", "id": 0, "event": "single_push", "ts": ... }, ... ] } }`

Dispatch rule: a frame with a truthy `id` is a response; otherwise `method` selects the notification kind; anything
else is ignored. A device may also invoke a method on the client with an `id` (aioshelly answers
`{"id": .., "src": .., "error": {"code": 500, "message": "Not Implemented"}}`); the original ignores such frames.

Applying a status object to a component (both `NotifyStatus` and `NotifyFullStatus`, and the initial `GetStatus`):
for every key of `params` except `ts` whose value is an object, find the component with that key (e.g. `switch:1`) and,
for each known field present: if the field's current value and new value are objects, **merge the new object's keys into
the existing object** (shallow) and report a change only if they differ deeply; otherwise replace the value and report a
change if it differs. Fields absent from the notification keep their values. Changes are reported after the whole
object is applied.

### 4.4 Digest authentication

Sequence when a password is configured:

1. Send the request without `auth`.
2. If the response is an error with `code` 401: if no password is configured → fail with "Unauthorized". If the
   request already had `auth` → fail with "Invalid password". Otherwise `error.message` is a **JSON string** containing
   the challenge: `{"auth_type": "digest", "nonce": <int>, "nc": <int, optional>, "realm": "<realm>", "algorithm": "SHA-256"}`
   (firmware ≥ 2.0 may add `"stale": true`).
3. Reject `auth_type` other than `digest` and `algorithm` other than `SHA-256`.
4. Compute, with `H(x)` = lowercase hex SHA-256 of the UTF-8 string `x` and `:` as the separator:
   * `HA1 = H("admin:" + realm + ":" + password)`
   * `HA2 = H("dummy_method:dummy_uri")` (a constant: `6370ec69915103833b5222b368555393393f098bfbfbb59f47e0590af135f062`)
   * `response = H(HA1 + ":" + nonce + ":" + nc + ":" + cnonce + ":auth:" + HA2)`, with `nc` = the challenge's `nc`
     or 1, written in decimal, and `nonce` written exactly as received (decimal).
5. Retry the same request with `"auth": { "realm": realm, "username": "admin", "nonce": nonce, "cnonce": cnonce,
   "response": response, "algorithm": "SHA-256" }`. (aioshelly also sends `"nc": nc`.)

`cnonce`: the original uses a random integer 0..1000000 (sent as a JSON number); aioshelly uses a base64 string of 16
random bytes. Both are accepted.

Reuse: the original keeps the same `auth` object for every later request on that handler and never increments `nc`.
aioshelly computes a fresh `auth` per request with `nc` incremented after each use, and when a 401 says
`"stale": true` it adopts the new nonce and retries once; a non-stale 401 after an authenticated request is a wrong
password. The realm is the device id or, when set, `auth_domain` from `Shelly.GetDeviceInfo`. `Shelly.GetDeviceInfo`
never requires auth. Recommendation: behave like aioshelly (fresh `nc`, handle `stale`), which the devices accept and
which survives nonce expiry.

Over HTTP (not used by the original) Gen 2 uses standard RFC 7616 digest with `algorithm=SHA-256`, `qop=auth`,
realm = device id, user `admin`.

### 4.5 RPC methods used

| Method | Params | Result / use |
|---|---|---|
| `Shelly.GetDeviceInfo` | none | `{ "id", "mac", "model", "gen", "fw_id", "ver", "app", "auth_en", "auth_domain", "profile"? , "name"?, "slot"? }`. `profile` is `"switch"` or `"cover"` on 2PM devices. |
| `Shelly.GetStatus` | none | object keyed by component key (`sys`, `wifi`, `switch:0`, `cover:0`, `input:0`, …) |
| `Shelly.GetConfig` | none | object keyed by component key; `sys.device.name` is the user's device name (may be null); `input:N.type` is `"switch"` or `"button"` |
| `Switch.Set` | `{ "id": N, "on": true|false }` (`toggle_after` seconds optional, unused) | `{ "was_on": bool }` |
| `Cover.GoToPosition` | `{ "id": 0, "pos": 0..100 }` | null |
| (available, unused by the plugin) `Switch.Toggle {id}`, `Cover.Open {id, duration?}`, `Cover.Close {id, duration?}`, `Cover.Stop {id}`, `Cover.Calibrate {id}`, `Light.Set {id, on?, brightness?, toggle_after?}`, `Light.Toggle {id}`, `<Component>.GetStatus {id}`, `<Component>.GetConfig {id}`, `<Component>.SetConfig {id, config}`, `Shelly.Reboot {delay_ms}`, `Shelly.GetComponents {dynamic_only, offset}`, `BluTrv.GetRemoteConfig {id}` |

Over HTTP the same methods are available as `GET http://<host>/rpc/<Method>?<params>` or `POST /rpc` with the frame
as the body, and `GET /shelly` returns the `GetDeviceInfo` object without auth (aioshelly uses it to tell
generations apart: a `gen` key of 2, 3 or 4 means RPC; no `gen` key means Gen 1).

### 4.6 Removal and exclusion

* Excluded devices' accessories are unregistered (both live ones and ones only in the accessory cache, found by the
  device id stored in each accessory's context) and the device is removed from the device cache.
* A removed device (library `remove` event) has its accessories unregistered and its cache entry deleted; log info
  "Device removed".
* The original never removes a device just because it is unreachable: accessories stay with their last values and
  writes fail with a communication error (4.8).

### 4.7 Device cache

File `.shelly-ng.json` in the Homebridge storage directory: `{"devices": [ {"id": "<deviceId>", "model": "<model>",
"protocol": "websocket", "hostname": "<ip>"}, ... ]}`. Written 1 s after the last change (debounced). Missing file =
empty cache (debug log). Load failure → error "Failed to load cached devices: …". Homeswift can keep the equivalent in
its own plugin storage; the format need not be compatible.

### 4.8 Errors on writes

A write from HomeKit whose value equals the current device value is accepted without a request. A failed RPC logs
error `Failed to set switch: <message>` or `Failed to set target position: <message>` and answers HomeKit with
"service communication failure" (HAP status -70402).

---

## 5. Gen 2+ device model

### 5.1 Supported models (ShellyNG at the commit read)

| Model id(s) | Model name | Components used | Accessory layout |
|---|---|---|---|
| `SNSW-001X16EU`, `SNSW-001X15UL` | Shelly Plus 1 | `switch:0` | single switch |
| `SNSW-001P16EU`, `SNSW-001P15UL` | Shelly Plus 1 PM | `switch:0` (with metering) | single switch |
| `SNSW-002P16EU`, `SNSW-102P16EU` | Shelly Plus 2 PM | `switch:0`, `switch:1`, `cover:0` | profile `cover` → cover; else two switches |
| `SNSN-0024X` | Shelly Plus I4 | `input:0`…`input:3` | I4 layout (5.3) |
| `SNPL-00116US` | Shelly Plus Plug US | `switch:0` (with metering) | single switch |
| `SPSW-001XE16EU`, `SPSW-101XE16EU`, `SPSW-201XE16EU` | Shelly Pro 1 | `switch:0` | single switch |
| `SPSW-001PE16EU`, `SPSW-101PE16EU`, `SPSW-201PE16EU` | Shelly Pro 1 PM | `switch:0` | single switch |
| `SPSW-002XE16EU`, `SPSW-102XE16EU`, `SPSW-202XE16EU` | Shelly Pro 2 | `switch:0`, `switch:1` | two switches |
| `SPSW-002PE16EU`, `SPSW-102PE16EU`, `SPSW-202PE16EU` | Shelly Pro 2 PM | `switch:0`, `switch:1`, `cover:0` | profile `cover` → cover; else two switches |
| `SPSW-003XE16EU` | Shelly Pro 3 | `switch:0..2` | three switches |
| `SPSW-004PE16EU` | Shelly Pro 4 PM | `switch:0..3` | four switches |

Matching is case-insensitive on `model`. Every other model (Plus Plug S/IT/UK, Plus PM Mini, Plus H&T, dimmers, RGBW,
Pro 3EM, Gen 3, Gen 4, BLU Gateway, Wall Display, …) is "unknown" to the original. aioshelly's model table (its
`const.py` at the commit above, about 150 models across generations, with names and BLE model ids) is the place to
look when extending; section 6 describes the components such an extension would map.

### 5.2 Component fields

`switch:N` status: `id`, `source` (string, what last changed it), `output` (bool), `timer_started_at`?, `timer_duration`?,
`apower` (W, only on metering models), `voltage` (V)?, `current` (A)?, `pf`?, `aenergy` `{ "total": Wh, "by_minute":
[mWh…], "minute_ts": unix }`?, `temperature` `{ "tC", "tF" }`, `errors`? (array of strings).
`switch:N` config: `name`, `in_mode` (`momentary|follow|flip|detached`), `initial_state`, `auto_on`, `auto_on_delay`,
`auto_off`, `auto_off_delay`, `power_limit`, `voltage_limit`, `current_limit`.

`cover:N` status: `source`, `state` (`open|closed|opening|closing|stopped|calibrating`), `apower`, `voltage`, `current`,
`pf`, `aenergy`, `current_pos` (0..100 or null), `target_pos` (0..100 or null; present while moving to a position),
`move_timeout`?, `move_started_at`?, `pos_control` (bool: true once calibrated), `temperature`?, `errors`?,
newer firmware also `freq`, `last_direction`.

`input:N` status: `id`, `state` (bool or null; null for button-type inputs). Config: `name`, `type` (`switch` |
`button`; newer firmware also `analog`), `invert`, `factory_reset`?.
`input:N` events (`NotifyEvent`): `btn_down`, `btn_up`, `single_push`, `double_push`, `long_push` (newer firmware also
`triple_push`), plus the generic `config_changed` (`cfg_rev`, `restart_required`).

### 5.3 Accessories per device

Switch accessory (one per switch component, or the single one): three possible services, of which exactly the
applicable ones are present:

* **Outlet** service if `switch:N.type` is `outlet`, else **Switch** service.
* **Power Meter** custom service if the switch's `apower` was present in the initial status (i.e. a metering model).

Published unless `switch:N.exclude` is true or (2PM devices) the device is in cover profile.

Cover accessory (2PM devices): exactly one of **Door**, **Window Covering**, **Window** (by `cover:0.type`, default
Window), plus a **Power Meter** service (always, covers always report power). Published only when `profile` from
`Shelly.GetDeviceInfo` is `cover` and `cover:0.exclude` is not true. The profile is read once when the device is added;
a profile change is picked up at the next start (the device reboots on a profile change).

Plus I4 (`input:N.type` from the initial config):

* Accessory `buttons`: one **Stateless Programmable Switch** service per input whose type is `button`, plus a
  **Service Label** service. Published if at least one input is a button.
* Accessories `switch0`…`switch3`: one read-only **Switch** service for input N. Published if input N is not a button.

When an accessory or a service is not applicable it is not published; one that existed before (from cache) is removed,
which is how config changes (e.g. switch ↔ outlet, profile change) take effect while keeping the accessory identity.

### 5.4 Services, characteristics, mappings

All service subtypes and display names below are fixed strings (N = component id, N+1 shown to people).

**Switch** — name `Switch N+1`, subtype `switch-N`.
* On (bool, read/write/notify) = `output`. Write → `Switch.Set {id: N, on: value}` (skipped if equal to `output`).
  `output` changes → On updated.

**Outlet** — name `Outlet N+1`, subtype `outlet-N`.
* On = `output`, as for Switch.
* Outlet In Use = (`apower` present and ≠ 0) initially. On later `apower` changes the original pushes the raw number
  into this boolean (which HAP coerces); the intended meaning is `apower ≠ 0`.

**Power Meter** (custom, UUID `DEDBEA44-11ED-429C-BD75-9A2286AA8707`) — name `Power Meter N+1`, subtype
`power-meter-N`. Characteristics (Eve, all float, read/notify):

| Characteristic | UUID | Unit | Range / step | Source | Present when |
|---|---|---|---|---|---|
| Current Consumption | `E863F10D-079E-48FF-8F27-9C2605A29F52` | W | 0..12000, 0.1 | `apower` (0 if absent) | always (required) |
| Voltage | `E863F10A-079E-48FF-8F27-9C2605A29F52` | V | -1000..1000, 0.1 | `voltage` | `voltage` present initially, else removed |
| Electric Current | `E863F126-079E-48FF-8F27-9C2605A29F52` | A | 0..48, 0.1 | `current` | `current` present initially, else removed |
| Total Consumption | `E863F10C-079E-48FF-8F27-9C2605A29F52` | kWh | 0..1000000, 0.1 | `aenergy.total / 1000` (Wh → kWh) | `aenergy` present initially, else removed |

**Cover** — service type Window / Door / Window Covering; name `Window 1` / `Door 1` / `Window Covering 1`, subtype
`window-0` / `door-0` / `windowCovering-0`.
* If `pos_control` is not true at set-up: log warning `Only calibrated covers are supported.` and leave the service
  with default values and no handlers (it is still published).
* Current Position = `current_pos`, or 0 if null.
* Target Position = `target_pos`, or the current position if null. Write → `Cover.GoToPosition {id: 0, pos: value}`
  (skipped if equal to `target_pos`). `target_pos` changes → Target Position updated.
* Position State: `opening` → Increasing (1); `closing` → Decreasing (0); anything else (`open`, `closed`, `stopped`,
  `calibrating`) → Stopped (2).
* Positions map 1:1 (Shelly 100 = fully open = HomeKit 100).

**Read-only switch** (I4 switch inputs) — Switch service, name `Switch N+1`, subtype `readonly-switch-N`. On's
permissions are reduced to read and notify (no write). On = `input:N.state`, null → false.

**Stateless Programmable Switch** (I4 buttons) — name `Button N+1`, subtype `stateless-programmable-switch-N`.
* Service Label Index = N+1.
* `NotifyEvent` for component `input:N`: `single_push` → Programmable Switch Event 0 (single press); `double_push`
  → 1 (double); `long_push` → 2 (long). Other events ignored. Debug log `Input N: single press` (etc.).

**Service Label** (on the `buttons` accessory) — no subtype, Service Label Namespace = Arabic numerals (1).

**Accessory Information** — section 3.1.

---

## 6. Gen 2+ components beyond the original (for an extended mapping)

The original maps only `switch`, `cover` and `input`. The following facts come from shellies-ng's component
definitions and aioshelly's fixtures and are given so an extension can be built on the same protocol. None of it is
behaviour of the Homebridge plugin; ids for such accessories should follow the same seed pattern
(`<deviceId>-<component key or similar>`), chosen once and never changed.

* `light:N` status: `output` (bool), `brightness` (0..100), `source`, timers. Set: `Light.Set {id, on?, brightness?}`.
* `temperature:N` status: `tC`, `tF` (null on error), `errors`?. Config `report_thr_C`.
* `humidity:N` status: `rh` (percent, null on error).
* `devicepower:N` status: `battery { "V": volts, "percent": 0..100 }`, `external { "present": bool }`.
* `illuminance:N` (Wall Display): `lux`, `illumination` (`dark|twilight|bright`).
* `em:N` (three-phase meters, e.g. Pro 3EM): `a_/b_/c_` prefixed `act_power` (W), `aprt_power` (VA), `current`,
  `voltage`, `pf`, `freq`; `total_act_power`, `total_aprt_power`, `total_current`, `n_current`. `emdata:N`:
  `a_total_act_energy`, `a_total_act_ret_energy`, … `total_act`, `total_act_ret` (Wh). Single-phase meters use
  `em1:N`/`em1data:N` and `pm1:N` (not in the fixtures read; gap G7).
* Battery devices (Plus H&T and similar) sleep: `sys.wakeup_period` > 0; they cannot be reached by an outbound
  WebSocket while asleep and instead connect to a configured server (outbound WebSocket, aioshelly path
  `/api/shelly/ws`). Not supported by the original (gap G6).
* **BLU** devices are not devices on the network: they are dynamic components of a gateway (BLU Gateway, Gen 3
  gateways, many Pro/Plus devices). `Shelly.GetComponents {"dynamic_only": true, "offset": N}` returns
  `{"components": [ {"key": "bthomedevice:200", "status": {...}, "config": {"addr": "aa:bb:cc:dd:ee:ff", "name": ...},
  "attrs": {"flags": .., "model_id": ..}}, {"key": "bthomesensor:202", "status": {"value": 19}, "config": {"addr": ..,
  "obj_id": 69, "idx": 0}}, ...], "offset": 0, "total": 5, "cfg_rev": ..}`, paged until `offset + count ≥ total`.
  `obj_id` is the BTHome object id (e.g. 1 battery, 69 temperature). BLU TRVs appear as `blutrv:<id>` and their
  settings come from `BluTrv.GetRemoteConfig {id}` → `result.config["trv:0"]`; BLE model id 8 = `SBTR-001AEU` "Shelly
  BLU TRV". Dynamic components need firmware dated ≥ 20240213 and are not offered by sleeping devices. Status changes
  arrive as `NotifyStatus` keyed by these component keys.
* BLE advertisements (not needed for an IP plugin): Allterco manufacturer id `0x0BA9`, blocks `0x01` flags (2 bytes LE:
  bit0 discoverable, bit1 auth enabled, bit2 RPC over BLE, bit3 buzzer, bit4 pairing mode), `0x0A` MAC (6 bytes,
  reversed), `0x0B` model id (2 bytes LE).

---

## 7. Gen 1 transport and protocol

### 7.1 CoIoT listening

* Join multicast group **224.0.1.187** on UDP port **5683** (on `networkInterface` if set, else the default interface;
  address reuse enabled so other CoAP listeners can coexist).
* At start-up, send one multicast CoAP GET for `/cit/s` to 224.0.1.187:5683 and accept unicast replies for 500 ms;
  then keep the multicast listener running.
* Accept two kinds of messages: periodic/state-change multicasts with CoAP code **0.30** (decimal 30) and Uri-Path
  `cit`/`s`; and unicast replies with code **2.05** (decimal 69). aioshelly accepts exactly codes 30 and 69 and parses
  any path.
* Tokens: Shelly devices mishandle tokens, so requests are sent with a zero-length token.
* A message without a device-id option (3332) or whose id cannot be split is ignored.
* The original never sends unicast `/cit/s` requests later; it relies on devices multicasting periodically and on
  change. Devices on another subnet need their "CoIoT peer" set to the bridge's address (the source's README says so
  for Shelly Motion); such devices then send **unicast** 0.30 messages to port 5683, which the listener must accept.

A unicast request message, as aioshelly builds it, is exactly the bytes
`50 01 00 0A B3 63 69 74 01 <path byte> FF 00` (NON, GET, message id 0x000A, Uri-Path "cit", Uri-Path "s" or "d",
payload marker, one zero byte) sent to `<ip>:5683`.

### 7.2 CoAP message layout (as parsed)

* Byte 0: version (2 bits, = 1), type (2 bits), token length (4 bits). Byte 1: code (class·32 + detail). Bytes 2–3:
  message id (big endian). Then `token length` bytes of token (always 0 here).
* Options: each starts with a byte whose high nibble is the delta to the previous option number and low nibble the
  length. A nibble of 13 means "one extra byte follows, value = byte + 13"; 14 means "two extra bytes follow (big
  endian), value = that + 269"; 15 in either nibble is invalid except as the full `0xFF` payload marker. Delta extension
  bytes come before length extension bytes.
* `0xFF` ends the options; the rest is the payload (UTF-8 JSON). A message without payload is invalid.
* Shelly options:
  * **3332** (global device id): ASCII `"<model>#<deviceId>#<protocolRevision>"`, e.g. `SHSW-PM#A4CF12F45678#2`.
    `protocolRevision` `"1"` = CoIoT v1 (old firmware, 3-digit property ids), `"2"` = CoIoT v2 (firmware ≥ 1.8,
    4-digit ids). aioshelly keys devices by the last 6 characters of `<deviceId>`; the Gen 1 plugin keys them by
    `<model>` + full `<deviceId>`.
  * **3412** (status validity): unsigned 16-bit big endian. If the lowest bit is 0, the status is valid for
    `floor(value / 10)` seconds; if 1, for `value × 4` seconds.
  * **3420** (status serial): unsigned 16-bit big endian, increments when the status changes.
* Status payload (`/cit/s`): `{"G": [[<channel>, <propertyId>, <value>], ...]}`. The channel is ignored for mapping;
  the property id selects the property (8.2). A payload with a `G` that is not an array is an error for that message.
* Description payload (`/cit/d`, used by aioshelly, not by the plugin): `{"blk": [{"I": <block id>, "D": "relay_0"},
  ...], "sen": [{"I": <property id>, "T": "<type code>", "D": "<description>", "R": "<range>", "L": <block id or list>},
  ...]}`. Available over HTTP `GET /cit/d` on firmware dated ≥ 20210302, otherwise over CoAP.

### 7.3 Device registry and state

* Devices are keyed by `(model, deviceId)`. The first status from an unseen key creates the device with the sender's IP
  as host, applies the update, marks it online, then announces it (so accessories created at discovery see the
  initial values).
* Unknown models are announced as unknown and only logged (info "Unknown device <type> <id> at <host> discovered").
* Every message: if it has a validity, the device's TTL is (re)set to that many seconds; when the TTL expires without a
  new message the device goes **offline**. The host is updated from the sender's address (a host change is persisted
  with the accessories). Each update sets every mapped property (with the type coercion of 8.2: boolean, number or
  string) and fires a change only when the value differs. The device is marked online and `lastSeen` set.
* On going online (and at creation if already online) the plugin loads `GET /settings` once, if not yet loaded; on
  failure it logs (7.7) and marks the device offline.
* **Stale removal**: when a device goes offline and `staleTimeout` > 0, a timer of `staleTimeout` ms starts; if the
  device is still offline when it fires, log info "Device <type> <id> is stale. Unregistering its accessories.",
  unregister its accessories and forget the device (a later CoIoT message re-discovers it as new). Coming back online
  cancels the timer. Offline itself only logs at debug ("Device <type> <id> went offline"/"came online").
* Unreachable devices keep their last values in HomeKit; there is no "not responding" state.

### 7.4 HTTP API (Gen 1)

All requests are `GET http://<host>/<path>` with query parameters, header `User-Agent: node-shellies 1.7.0` in the
original (any value works), optional `Authorization: Basic base64(user:password)`, timeout `requestTimeout`.

| Path | Query | Use |
|---|---|---|
| `/shelly` | — | Identity without auth: `{"type", "mac", "auth" (bool: login required), "fw", "discoverable", "num_outputs", "num_meters"?, "name"?}` (aioshelly) |
| `/settings` | — | Settings: `name`, `fw`, `hwinfo {hw_revision, batch_id}`, `device {type, mac, hostname, num_outputs, num_meters}`, `relays[]`, `rollers[] {swap, …}`, `mode`, … |
| `/status` | — | Current status (not used by the plugin) |
| `/relay/<i>` | `turn=on|off` | Relay i |
| `/roller/0` | `go=to_pos&roller_pos=<0..100>` | Move roller to a position. (`go=open|close|stop[&duration=s]` also exists.) |
| `/light/0` | Bulb/Bulb RGBW: `mode=color&turn=on|off&gain=<0..100>&red=&green=&blue=&white=` (colour) | Colour bulbs |
| `/light/0` | Duo: `turn=on|off&temp=<K>&white=<0..100>&brightness=<1..100>` | Duo |
| `/light/0` | Dimmer, Dimmer 2, Vintage: `turn=on|off&brightness=<1..100>` | White dimmers |
| `/color/0` | RGBW2 colour mode: `turn=on|off&gain=&red=&green=&blue=&white=` (no `mode`) | RGBW2 colour |
| `/white/<i>` | RGBW2 white mode: `turn=on|off&brightness=` | RGBW2 channel i |
| `/settings` | `mode=color|white` (aioshelly), `target_t=` (TRV) | Settings changes, not used by the plugin |
| `/reboot` | — | Not used by the plugin |

### 7.5 Authentication (Gen 1)

HTTP Basic with the device or global credentials (2.2). A 401 is logged as "Wrong username or password (device <type>
<id>, at <host>)". CoIoT is unauthenticated.

### 7.6 Start-up and cached accessories

* For each cached accessory: if its device is excluded, or its stored `accessoryType` differs from the configured
  type for that index (configured `type` or the model default for the cached mode), it is marked stale. Otherwise the
  device object is re-created from the cached `type`, `id`, `host`, `mode` (offline, default property values) and the
  accessory set up again.
* After launch: stale accessories are unregistered and, unless the device is excluded, re-created with the new type and
  registered; log info "N accessories loaded from cache"; CoIoT listening starts.
* Newly discovered devices: info "New device discovered: <type> <id> at <host>"; excluded ones: info "Excluding device
  <type> <id> at <host>"; models without accessories: info "Unknown device, so skipping it".
* When a device's `mode` property changes (Shelly 2/2.5 relay ↔ roller, RGBW2 colour ↔ white) all its accessories are
  unregistered and re-created for the new mode.

### 7.7 Error logging for failed requests

A failed request logs the operation ("Failed to set relay0", "Failed to set light", "Failed to load device
settings", "Failed to identify device") followed by one of: "Wrong username or password", "Error: <status> <message>"
(plus the response body if any), "Error: <message>" for socket errors, "Request timeout", or "Error sending request",
each with "(device <type> <id>, at <host>)". Relay, outlet, valve and garage-door writes report the failure to HomeKit;
light and roller writes acknowledge HomeKit first and only log failures.

### 7.8 Admin server (original only)

An HTTP server (default port 8181) with a static page and `GET /api/devices`, `GET /api/devices/<type>.<id>`,
`DELETE /api/devices/<type>.<id>` returning `{success, data: {type, id, host, name, modelName, online, lastSeen (ms ago),
unknown, excluded}}`. Homeswift's UI and MCP tools replace it; nothing to implement.

---

## 8. Gen 1 device model

### 8.1 Models, names and accessory factories

| Model id | Model name (seed) | Default accessory type | Accessories | Power meters (`powerK` used) |
|---|---|---|---|---|
| `SHSW-1` | Shelly 1 | switch | 1 | none |
| `SHSW-PM` | Shelly 1PM | switch | 1 | power0 |
| `SHSW-L` | Shelly 1L | switch | 1 | power0 |
| `SHSW-21` | Shelly 2 | relay mode: switch; roller mode: windowCovering | relay 2, roller 1 | relay: both use power0; roller: none |
| `SHSW-25` | Shelly 2.5 | relay: switch; roller: windowCovering | relay 2, roller 1 | relay: power0, power1; roller: none |
| `SHSW-22` | Shelly HD | switch | 2 | power0, power1 |
| `SHSW-44` | Shelly 4Pro | switch | 4 | power0..power3 |
| `SHUNI-1` | Shelly Uni | switch | 2 | power0, power1 (properties do not exist on the Uni; see G9) |
| `SHPLG-1` | Shelly Plug | switch | 1 | power0 |
| `SHPLG2-1` | Shelly Plug | switch | 1 | power0 |
| `SHPLG-S` | Shelly Plug S | switch | 1 | power0 |
| `SHPLG-U1` | Shelly Plug US | switch | 1 | power0 |
| `SHAIR-1` | Shelly Air | switch | 1 | power0 |
| `SHEM` | Shelly EM | switch | 1 | power0 (channel 1 not shown) |
| `SHEM-3` | Shelly 3EM | switch | 1 | power0 (phases 2–3 not shown) |
| `SHBLB-1` | Shelly Bulb | colorLightbulb | 1 | — |
| `SHCB-1` | Shelly Bulb RGBW | colorLightbulb | 1 | — |
| `SHRGBW2` | Shelly RGBW2 | colour mode: colorLightbulb; white mode: whiteLightbulb | colour 1, white 4 | — |
| `SHBDUO-1` | Shelly Duo | colorTemperatureLightbulb | 1 | — |
| `SHVIN-1` | Shelly Vintage | whiteLightbulb | 1 | — |
| `SHDM-1` | Shelly Dimmer | whiteLightbulb | 1 | — |
| `SHDM-2` | Shelly Dimmer 2 | whiteLightbulb | 1 | — |
| `SHBTN-1`, `SHBTN-2` | Shelly Button1 | statelessSwitch | 1 | — |
| `SHIX3-1` | Shelly i3 | statelessSwitch | 1 (three buttons) | — |
| `SHDW-1` | Shelly Door/Window | sensor | 1 | — |
| `SHDW-2` | Shelly Door/Window 2 | sensor | 1 | — |
| `SHWT-1` | Shelly Flood | sensor | 1 | — |
| `SHHT-1` | Shelly H&T | sensor | 1 | — |
| `SHGS-1` | Shelly Gas | `smokeSensor` (but the accessory records itself as `sensor`, see G10) | 1 | — |
| `SHSEN-1` | Shelly Sense | sensor | 1 | — |
| `SHMOS-01` | Shelly Motion | sensor | 1 | — |

Known to the library but without accessories in the plugin (logged as "Unknown device, so skipping it"):
`SHCL-255` Shelly Color, `SHRGBWW-01` Shelly RGBW, `SHDIMW-1` Shelly Dimmer W1, `SH2LED-1` Shelly 2LED, `SHSM-01` Shelly
Smoke, `SHSM-02` Shelly Smoke 2, `SHMOS-02` Shelly Motion 2, `SHTRV-01` Shelly TRV. aioshelly additionally knows
`SHSPOT-1`/`SHSPOT-2` Spot and `SHBVIN-1` Vintage.

Power meter index for relay devices: accessory i uses `power<min(i, numberOfPowerMeters − 1)>` when the model has power
meters, else none.

### 8.2 CoIoT property ids per model

Format: property — ids (v1, v2…) — type. A property's ids map in both protocol revisions; "(relay)" / "(roller)" /
"(color)" / "(white)" means the mapping applies only in that device mode, everything else in all modes. Boolean
properties are coerced with truthiness (1 → true), number properties with numeric conversion, strings with string
conversion. Defaults (used for re-created, not yet heard devices): booleans false, numbers 0, strings as noted,
external temperatures/humidity null.

* **Shelly 1 (`SHSW-1`)**: relay0 — 112, 1101 — bool; input0 — 118, 2101 — number; inputEvent0 — 2102 — string;
  inputEventCounter0 — 2103 — number; externalTemperature0 — 119, 3101; externalTemperature1 — 3201;
  externalTemperature2 — 3301; externalHumidity — 3103; externalInput0 — 3117.
* **Shelly 1PM (`SHSW-PM`)**: all of Shelly 1, plus power0 — 111, 4101; energyCounter0 — 4103; overPower — 6102;
  overPowerValue — 6109; deviceTemperature — 113, 3104; overTemperature — 115, 6101.
* **Shelly 1L (`SHSW-L`)**: all of Shelly 1, plus input1 — 2201; inputEvent1 — 2202; inputEventCounter1 — 2203;
  power0 — 4101; energyCounter0 — 4103; deviceTemperature — 3104; overTemperature — 6101 (bool).
* **Shelly 2 (`SHSW-21`)**: relay0 — 112, 1101; relay1 — 122, 1201; input0 — 118, 2101; inputEvent0 — 2102;
  inputEventCounter0 — 2103; input1 — 128, 2201; inputEvent1 — 2202; inputEventCounter1 — 2203; power0 — 111, 4101,
  4102; energyCounter0 — 4103, 4104; mode — 9101 — string (`relay`|`roller`, default `relay` or the cached mode);
  (relay) overPower0 — 6102; (relay) overPower1 — 6202; (relay) overPowerValue — 6109; (roller) rollerState — 1102 —
  string (`open`|`close`|`stop`, default `stop`); (roller) rollerPosition — 113, 1103; (roller) rollerStopReason —
  6103 — string.
* **Shelly 2.5 (`SHSW-25`)**: all of Shelly 2, plus (relay) power1 — 121, 4201; (relay) energyCounter1 — 4203;
  deviceTemperature — 115, 3104; overTemperature — 117, 6101.
* **Shelly 4Pro (`SHSW-44`)**: power0 — 111; relay0 — 112; power1 — 121; relay1 — 122; power2 — 131; relay2 — 132;
  power3 — 141; relay3 — 142.
* **Shelly HD (`SHSW-22`)**: power0 — 111; relay0 — 112; power1 — 121; relay1 — 122.
* **Shelly Plug (`SHPLG-1`), Plug E (`SHPLG2-1`), Plug US (`SHPLG-U1`)**: relay0 — 112, 1101; power0 — 111, 4101;
  energyCounter0 — 4103; overPower — 6102; overPowerValue — 6109. **Plug S (`SHPLG-S`)** adds deviceTemperature —
  113, 3104; overTemperature — 115, 6101.
* **Shelly EM (`SHEM`)**: relay0 — 112, 1101; power0 — 111, 4105; energyCounter0 — 4106; energyReturned0 — 4107;
  voltage0 — 116, 4108; power1 — 121, 4205; energyCounter1 — 4206; energyReturned1 — 4207; voltage1 — 126, 4208;
  overPower — 6102.
* **Shelly 3EM (`SHEM-3`)**: relay0 — 112, 1101; for phase k ∈ {0,1,2} with p = 11+10k (111/121/131) and q =
  4105/4205/4305: powerK — p, q; energyCounterK — q+1; energyReturnedK — q+2; voltageK — p+5, q+3; currentK — p+4,
  q+4; powerFactorK — p+3, q+5. (Concretely phase 0: power0 111/4105, energyCounter0 4106, energyReturned0 4107,
  voltage0 116/4108, current0 115/4109, powerFactor0 114/4110.) overPower — 6102.
* **Shelly Uni (`SHUNI-1`)**: relay0 — 1101; relay1 — 1201; input0 — 2101; inputEvent0 — 2102; inputEventCounter0 —
  2103; input1 — 2201; inputEvent1 — 2202; inputEventCounter1 — 2203; externalTemperature0..4 — 3101, 3201, 3301, 3401,
  3501; voltage0 — 3118; externalHumidity — 3103.
* **Shelly Air (`SHAIR-1`)**: relay0 — 112, 1101; totalWorkTime — 121, 1104; input0 — 118, 2101; inputEvent0 — 2102;
  inputEventCounter0 — 2103; power0 — 111, 4101; energyCounter0 — 211, 4103; overPower — 6102; overPowerValue — 6109;
  deviceTemperature — 113, 3104; overTemperature — 115, 6101; externalTemperature0 — 119, 3101;
  externalTemperature1 — 3201; externalTemperature2 — 3301; externalHumidity — 3103.
* **Shelly Bulb (`SHBLB-1`), Bulb RGBW (`SHCB-1`)**: switch — 181, 1101 — bool; red — 111, 5105; green — 121, 5106;
  blue — 131, 5107; white — 141, 5108; gain — 151, 5102; brightness — 171, 5101; colorTemperature — 161, 5103;
  mode — 9101 (default `color`).
* **Shelly RGBW2 (`SHRGBW2`)**: (color) switch — 161, 1101; (color) red — 111, 5105; (color) green — 121, 5106;
  (color) blue — 131, 5107; (color) white — 141, 5108; (color) gain — 151, 5102; (white) switch0 — 151, 1101;
  (white) brightness0 — 111, 5101; (white) switch1 — 161, 1201; (white) brightness1 — 121, 5201; (white) switch2 —
  171, 1301; (white) brightness2 — 131, 5301; (white) switch3 — 181, 1401; (white) brightness3 — 141, 5401; power0 —
  4101; energyCounter0 — 4103; (white) power1..3 — 4201, 4301, 4401; (white) energyCounter1..3 — 4203, 4303, 4403;
  overPower — 6102; input0 — 118, 2101; inputEvent0 — 2102; inputEventCounter0 — 2103; mode — 9101 (default `color`
  or cached).
* **Shelly Duo (`SHBDUO-1`)**: switch — 121, 1101; brightness — 111, 5101; colorTemperature (Kelvin) — 131, 5103;
  whiteLevel — 5104; power0 — 141, 4101; energyCounter0 — 211, 4103.
* **Shelly Vintage (`SHVIN-1`)**: switch — 121, 1101; brightness — 111, 5101; power0 — 141, 4101; energyCounter0 —
  211, 4103.
* **Shelly Dimmer (`SHDM-1`), Dimmer 2 (`SHDM-2`)**: switch — 121, 1101; brightness — 111, 5101; input0 — 131, 2101;
  inputEvent0 — 2102; inputEventCounter0 — 2103; input1 — 141, 2201; inputEvent1 — 2202; inputEventCounter1 — 2203;
  power0 — 4101; energyCounter0 — 4103; overPower — 6102; loadError — 6104 (bool); deviceTemperature — 3104;
  overTemperature — 6101; mode — 9101 (default `white`).
* **Shelly Button1 (`SHBTN-1`, `SHBTN-2`)**: input0 — 118; inputEvent0 — 119, 2102 — string; inputEventCounter0 — 120,
  2103; sensorError — 3115 (bool); charging — 3112; battery — 77, 3111; wakeUpEvent — 9102 (default `unknown`).
* **Shelly i3 (`SHIX3-1`)**: for input k ∈ {0,1,2}: inputK — 118/128/138, 2101/2201/2301; inputEventK — 119/129/139,
  2102/2202/2302; inputEventCounterK — 120/130/140, 2103/2203/2303.
* **Shelly Door/Window (`SHDW-1`)**: state — 55, 3108 (0 closed, 1 open); tilt — 3109 (degrees); vibration — 6110;
  illuminance — 66, 3106 (lux); illuminanceLevel — 3110 (default `unknown`); sensorError — 3115; battery — 77, 3111;
  wakeUpEvent — 9102. **Door/Window 2 (`SHDW-2`)** adds temperature — 3101.
* **Shelly Flood (`SHWT-1`)**: temperature — 33, 3101; flood — 23, 6106; sensorError — 3115; battery — 3111;
  wakeUpEvent — 9102.
* **Shelly H&T (`SHHT-1`)**: temperature — 33, 3101; humidity — 44, 3103; sensorError — 3115; battery — 77, 3111
  (−1 when powered externally); wakeUpEvent — 9102.
* **Shelly Gas (`SHGS-1`)**: sensorOperation — 118, 3113; selfTest — 120, 3114; gas — 119, 6108 — string (default
  `unknown`; `none` when no gas); concentration — 122, 3107; valve — 1105.
* **Shelly Sense (`SHSEN-1`)**: temperature — 33, 3101; humidity — 44, 3103; motion — 11, 6107; illuminance — 66,
  3106; charging — 22, 3112; battery — 77, 3111.
* **Shelly Motion (`SHMOS-01`)**: motion — 6107; vibration — 6110; illuminance — 3106; battery — 3111.

Mode detection for CoIoT v1 (revision `"1"`), which has no 9101 property:
* Shelly 2/2.5: the device is in `roller` mode if the update contains property id 113, else `relay`. In roller mode on
  v1, `rollerState` is derived after each update: relay0 on → `open` (or `close` if `/settings` `rollers[0].swap` is
  true), else relay1 on → `close` (or `open` when swapped), else `stop`.
* RGBW2: `white` mode if the update contains at least two tuples whose id is 171 or 181, else `color`.

### 8.3 Accessory types

Relay devices (all with "switch" default above): the configured type selects the accessory for relay i:

| Type | Accessory | Services |
|---|---|---|
| `switch` (default, and any unrecognised value) | switch | Switch (On = relayI, writable) + Power Meter if the model has power meters |
| `outlet` | outlet | Outlet (On = relayI, Outlet In Use = powerK > 0 (truthy), false without meter) + Power Meter if metered |
| `valve` | valve | Valve (Active = relayI, In Use = powerK truthy or Not In Use without meter, Valve Type = Generic (0)) + Power Meter if metered |
| `contactSensor` | contactSensor | Contact Sensor (read-only from relayI) + Power Meter if metered |
| `motionSensor` | motionSensor | Motion Sensor (read-only from relayI) + Power Meter if metered |
| `occupancySensor` | occupancySensor | Occupancy Sensor (read-only from relayI) + Power Meter if metered |

Shelly 2 / 2.5 in roller mode: `door` → Door; `garageDoorOpener` → Garage Door Opener; `window` → Window; anything else
(default `windowCovering`) → Window Covering. Lights, buttons and sensors ignore `type`.

### 8.4 Services and mappings

Gen 1 services are added without subtypes (each accessory has at most one service of each type), except the stateless
switches. Every "single property" service (Switch, Contact, Motion, Occupancy, Leak, Smoke, Light Sensor,
Temperature, Humidity, Tilt) also carries **Status Fault**: General Fault (1) when the raw device value equals that
service's "invalid" marker, else No Fault (0).

**Switch**: On = truthiness of relayI. Write: skipped if equal; else `GET /relay/<i>?turn=on|off`; failure → error to
HomeKit. Invalid marker: null.

**Outlet**: On as Switch. Outlet In Use as in 8.3, updated on power changes.

**Valve**: Active 1/0 from relayI; write Active=1 → relay on, 0 → off (skipped if equal).

**Contact Sensor** (relay or Door/Window `state`): Contact Sensor State = 0 (contact detected) when the value is falsy
and not −1; 1 (not detected) otherwise. So relay on / window open → 1. Invalid marker −1.

**Motion Sensor** (relay, `vibration`, `motion`): Motion Detected = truthy and not −1. Invalid −1.

**Occupancy Sensor**: Occupancy Detected 1 when truthy and not −1, else 0.

**Leak Sensor** (Flood `flood`): Leak Detected 1 when truthy and not −1.

**Smoke Sensor** (Gas): Smoke Detected 1 when `gas` is neither `unknown` nor `none` (values like `mild`, `heavy`),
else 0.

**Temperature Sensor**: Current Temperature = value clamped to [−270, 100]; minimum value property set to −100; the
invalid marker 999 → 0 with General Fault.

**Humidity Sensor**: Current Relative Humidity = value clamped to [0, 100]; invalid 999 → 0.

**Light Sensor**: Current Ambient Light Level = lux clamped to [0.0001, 500000]; maximum property 500000; invalid −1 →
0.0001.

**Tilt Sensor** (custom service UUID `DA2354B4-3C77-4EAF-BD37-AA0838B59513`, display name "Tilt Sensor", containing
the standard Current Tilt Angle with range 0..180): value clamped to [0, 180]; invalid −1 → 0.

**Battery** service: Battery Level = value clamped to [0, 100], except that for the H&T a value of −1 (external power)
means 100; Status Low Battery = Low (1) when level < 10, else Normal (0); Charging State = Not Chargeable (2), except for
the Sense: Charging (1) when `charging` is truthy, else Not Charging (0).

**Power Meter** (custom, UUID `DEDBEA44-11ED-429C-BD75-9A2286AA8707`, display name "Power Meter", no subtype): only
the Consumption characteristic is used: UUID `E863F10D-079E-48FF-8F27-9C2605A29F52`, float, W, 0..65535, step 0.1,
read/notify, value = powerK clamped to [0, 65535]. (Optional Electric Current `E863F126-…` and Voltage `E863F10A-…`
exist on the service type but the plugin never fills them.)

**Rollers** (Window Covering / Window / Door, from rollerPosition and rollerState):
* Current Position = rollerPosition (0 if unset); Position State: `open` → Increasing (1), `close` → Decreasing (0),
  else Stopped (2).
* Target Position: an internal target, initially the current position.
* Write: acknowledge HomeKit immediately. If the value equals the current target, or a move is already pending,
  ignore it. Otherwise wait **1000 ms**, then send `GET /roller/0?go=to_pos&roller_pos=<value>` and, on success, take
  the value as the internal target (on failure log only).
* On rollerState or rollerPosition changes: update Position State / Current Position, then (debounced **500 ms**,
  at most one pending) recompute the target: state `stop` → target = position; state `open` and target ≤ position →
  100; state `close` and target ≥ position → 0; otherwise unchanged. If the target changed, push it to Target Position.

**Garage Door Opener** (roller mode, type `garageDoorOpener`):
* Current Door State: state `open` → Opening (2); `close` → Closing (3); else position ≥ 100 → Open (0); position ≤ 0
  → Closed (1); else Stopped (4).
* Target Door State: the last written value if any, else Open (0) when the current state is Open or Opening, else
  Closed (1).
* Obstruction Detected = false.
* Write Target Door State: skipped if equal; else remember it and send `roller_pos=100` for Open, `0` for Closed (no
  delay); failure → error to HomeKit.
* Only rollerState changes refresh Current Door State (position changes alone do not).

**White Lightbulb** (Dimmer, Dimmer 2, Vintage; RGBW2 white channel i with switchI/brightnessI): On, Brightness.
**Colour-temperature Lightbulb** (Duo): adds Color Temperature in mireds with range 154..370; device Kelvin ↔ mireds
by `round(1000000 / x)` both ways.
* Any write (On, Brightness, Color Temperature) that differs from the device value starts a **100 ms** debounce (at
  most one pending); when it fires, read the service's current On / Brightness / Color Temperature values and send one
  request with `turn` from On, brightness = max(Brightness, 1), and for the Duo `temp` = Kelvin and `white` =
  clamp(round((K − 2700) / (6500 − 2700) × 100), 0, 100). Endpoints in 7.4.
* Device changes of switch / brightness / colorTemperature update On / Brightness / Color Temperature.

**Colour Lightbulb** (Bulb, Bulb RGBW, RGBW2 colour mode): On = `switch`, Brightness = `gain`, Hue, Saturation.
* Device → HomeKit: when red, green or blue changes (debounced 100 ms), convert (r, g, b) in 0..255 to HSV and set Hue
  (0..360) and Saturation (0..100) from it, rounded to integers; the HSV value component is discarded. Initial hue and
  saturation are computed the same way.
* HomeKit → device: Hue and Saturation writes are stored and, like On/Brightness, start the 100 ms debounce; the
  request is built from (hue, saturation, value = 100) converted to RGB (integers 0..255), `gain` = max(Brightness, 1),
  `turn` from On, and in `rgbw` colour mode `white` = round(min(r, g, b) × Brightness / 100); in `rgb` mode no
  `white` is sent. The conversion is the standard HSV→RGB with integer rounding (as the `color-convert` npm package
  does: h 0..360, s and v 0..100).

**Stateless Programmable Switch** (Button1: one; i3: three):
* Button1: one service with display name `Button 1`, subtype `1`, Service Label Index 1, plus a Battery service.
* i3: three services `Button 1`..`Button 3`, subtypes `1`..`3`, Service Label Index 1..3, plus a Service Label service
  (namespace Arabic numerals).
* A press is detected when inputEventK or inputEventCounterK changes (both changes in one update count once,
  coalesced to the next tick): inputEventK `S` → single press (0), `SS` → double (1), `L` → long (2); any other
  value (`SSS`, `LS`, `SL`, empty) → nothing. The counter makes repeated identical presses detectable.

Sensor accessories (type `sensor`):

| Model | Services |
|---|---|
| Door/Window | Contact Sensor (state), Light Sensor (illuminance), Motion Sensor (vibration), Tilt Sensor (tilt), Battery |
| Door/Window 2 | as Door/Window, plus Temperature Sensor (temperature) before Battery |
| Flood | Leak Sensor (flood), Temperature Sensor, Battery |
| H&T | Temperature Sensor, Humidity Sensor, Battery (−1 = 100 %) |
| Gas | Smoke Sensor (gas) |
| Sense | Motion Sensor (motion), Temperature, Humidity, Light Sensor, Battery (chargeable, `charging`) |
| Motion | Motion Sensor (motion), Light Sensor (illuminance), Battery |

**Identify** (HomeKit identify): logs "<name> at <host> identified"; for relay accessories and lights additionally
inverts the on state for 1 s and restores it (two requests).

---

## 9. Custom UUID summary

| What | UUID | Used by |
|---|---|---|
| Power Meter service | `DEDBEA44-11ED-429C-BD75-9A2286AA8707` | both |
| Consumption / Current Consumption (W) | `E863F10D-079E-48FF-8F27-9C2605A29F52` | both (Gen 1: 0..65535; Gen 2: 0..12000) |
| Total Consumption (kWh) | `E863F10C-079E-48FF-8F27-9C2605A29F52` | Gen 2 |
| Voltage (V) | `E863F10A-079E-48FF-8F27-9C2605A29F52` | Gen 2 (declared, unused, in Gen 1) |
| Electric Current (A) | `E863F126-079E-48FF-8F27-9C2605A29F52` | Gen 2 (declared, unused, in Gen 1) |
| Tilt Sensor service | `DA2354B4-3C77-4EAF-BD37-AA0838B59513` | Gen 1 Door/Window |

---

## 10. Logging

ShellyNG (device lines prefixed `[<device name or id>] `):

| Level | When (paraphrased) |
|---|---|
| debug | Number of accessories loaded from cache; mDNS disabled; device cache file missing / N devices loaded / saving N devices; accessory loaded from cache, activated, deactivated (with accessory id); device connected or not at add time; each RPC request's method name ("WebSocket: <method>"); button presses; error stacks |
| info | mDNS discovery started; device added / removed; device excluded; unknown model discovered; device connected; reconnecting in N s/min/h |
| warn | Device disconnected (reason) / connection failed (code); cover not calibrated |
| error | mDNS failed to start / runtime mDNS errors; failure to add a discovered device; device added twice; failed to set switch / target position; failed to load or save the device cache; ability set-up/destroy failures |

Shelly (Gen 1):

| Level | When |
|---|---|
| debug | configuring cached accessory #i for a device; recreating an accessory whose type changed; device came online / went offline / changed host / changed mode; loading settings; every property change ("<property> of device <type> <id> changed to <value>"); every write ("Setting <property> of device … to …"); computed light and colour values |
| info | N accessories loaded from cache; admin server running on port P; new device discovered; excluding device; unknown device; device stale and unregistered; identify |
| warn | unknown network interface ignored |
| error | failed request diagnostics (7.7); failed to add device (with stack); admin server failed to start |

Secrets: the `password` values (and the Basic `Authorization` header built from them), the digest `HA1` and
`response`, and the challenge `nonce` must never be logged. The originals log RPC method names but not frames; a
replacement that traces frames must strip `auth`. Device ids, MACs and IPs are not secret.

---

## 11. Test vectors

Data written for this spec (shapes follow the devices' real responses; values are invented or computed here).

### 11.1 Gen 2 `GET /shelly` / `Shelly.GetDeviceInfo` result

```
{"id":"shellyplus1pm-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SNSW-001P16EU","gen":2,
 "fw_id":"20231219-133934/1.1.0-g34b5d4f","ver":"1.1.0","app":"Plus1PM","auth_en":false,"auth_domain":null,
 "name":"Kitchen","slot":0}
```
Expected: model "Shelly Plus 1 PM", one accessory, seed `shellyplus1pm-aabbccddeeff-switch`, SerialNumber
`AABBCCDDEEFF`, FirmwareRevision `1.1.0`. A Plus 2PM adds `"profile":"cover"` or `"profile":"switch"`.

### 11.2 Gen 2 `Shelly.GetStatus` result (Plus 1PM, abridged)

```
{"input:0":{"id":0,"state":false},
 "switch:0":{"id":0,"source":"WS_in","output":false,"apower":0.0,"voltage":232.8,"current":0.0,
             "aenergy":{"total":110.046,"by_minute":[0.0,0.0,0.0],"minute_ts":1707326934},
             "temperature":{"tC":30.3,"tF":86.6}},
 "sys":{"mac":"AABBCCDDEEFF","restart_required":false,"uptime":2622735,"cfg_rev":35}}
```
Expected: Switch On = false; Power Meter present with Current Consumption 0, Voltage 232.8, Electric Current 0,
Total Consumption 0.110046 kWh.

With `Shelly.GetConfig` `{"sys":{"device":{"name":"Kitchen", ...}}, "switch:0":{"name":"Light", ...}}` and no
configured name, the accessory name is `Kitchen`. With `"switch:0": {"type": "outlet"}` configured, an Outlet
service (`Outlet 1`, subtype `outlet-0`) replaces the Switch, Outlet In Use = false.

### 11.3 NotifyStatus and NotifyEvent

```
{"src":"shellyplus1pm-aabbccddeeff","dst":"homeswift-1234","method":"NotifyStatus",
 "params":{"ts":1707327000.12,"switch:0":{"id":0,"output":true,"source":"button","apower":41.7,
           "aenergy":{"total":110.051}}}}
```
Expected: On → true; Current Consumption → 41.7; Total Consumption → 0.110051 (the `aenergy` object is merged, so
`by_minute` and `minute_ts` keep their previous values); Voltage unchanged.

```
{"src":"shellyplusi4-aabbccddeeff","dst":"homeswift-1234","method":"NotifyEvent",
 "params":{"ts":1707327010.50,"events":[{"component":"input:2","id":2,"event":"double_push","ts":1707327010.50}]}}
```
Expected (input:2 configured as button): service `Button 3` (subtype `stateless-programmable-switch-2`) emits
Programmable Switch Event 1.

Cover in motion (Gen 3 2PM, from a real response shape):
`{"id":0,"source":"WS_in","state":"closing","apower":123.1,"voltage":219.7,"current":0.557,"pf":0.99,"freq":50.0,
"aenergy":{"total":314.801,"by_minute":[0,0,0],"minute_ts":1760365440},"temperature":{"tC":52.0,"tF":125.7},
"pos_control":true,"last_direction":"close","current_pos":51}` → Current Position 51, Position State 0
(decreasing), Target Position 51 (no `target_pos`, so the current position).

### 11.4 Digest exchange

Request: `{"src":"homeswift-1234","jsonrpc":"2.0","id":2,"method":"Switch.Set","params":{"id":0,"on":true}}`

Response: `{"id":2,"src":"shellyplus1pm-aabbccddeeff","dst":"homeswift-1234","error":{"code":401,"message":"{\"auth_type\":\"digest\",\"nonce\":1700000000,\"nc\":1,\"realm\":\"shellyplus1pm-aabbccddeeff\",\"algorithm\":\"SHA-256\"}"}}`

With password `secret`:

* HA1 = SHA-256(`admin:shellyplus1pm-aabbccddeeff:secret`) = `abf4a881bbc6e16f0c68bbf0fcabc24109b577fe615ca02a4f78be7bbdafa619`
* HA2 = SHA-256(`dummy_method:dummy_uri`) = `6370ec69915103833b5222b368555393393f098bfbfbb59f47e0590af135f062`
* cnonce `313773` (numeric, as the original), nc 1: response = SHA-256(`<HA1>:1700000000:1:313773:auth:<HA2>`) =
  `a9fdaa21db8597c0311326b58dd16eb0d24e799ca76bf9230b4887c62359c45d`
* cnonce `AAECAwQFBgcICQoLDA0ODw==` (base64 of bytes 00..0F, as aioshelly), nc 1: response =
  `ed9b9f40cd94a6814033c7c87f0b4900fdebfe240b8221aa5ccb3f3fb3162f25`

Retry: `{"src":"homeswift-1234","jsonrpc":"2.0","id":3,"method":"Switch.Set","params":{"id":0,"on":true},
"auth":{"realm":"shellyplus1pm-aabbccddeeff","username":"admin","nonce":1700000000,"cnonce":313773,
"response":"a9fdaa21db8597c0311326b58dd16eb0d24e799ca76bf9230b4887c62359c45d","algorithm":"SHA-256"}}`
→ `{"id":3,...,"result":{"was_on":false}}`. A second 401 to a request carrying `auth` = "Invalid password" (unless
it says `"stale": true`, see 4.4).

### 11.5 Gen 1 `GET /shelly` and `/settings` (Plug S)

`/shelly`: `{"type":"SHPLG-S","mac":"AABBCCDDEEFF","auth":false,"fw":"20230913-113421/v1.14.0-gcb84623",
"discoverable":true,"num_outputs":1,"num_meters":1}`

`/settings` (abridged): `{"name":"Test Name","fw":"20230913-113421/v1.14.0-gcb84623",
"hwinfo":{"hw_revision":"prod-190516","batch_id":1},"device":{"type":"SHPLG-S","mac":"AABBCCDDEEFF",
"hostname":"shellyplug-s-DDEEFF","num_outputs":1,"num_meters":1},"relays":[{"name":null,"ison":false,"default_state":"off"}]}`
→ FirmwareRevision `1.14.0`, HardwareRevision `prod-190516`.

`/status` (abridged): `{"relays":[{"ison":false,"source":"http"}],"meters":[{"power":0.0,"is_valid":true,"total":2632}],
"temperature":24.14,"overtemperature":false,"tmp":{"tC":24.14,"tF":75.45,"is_valid":true}}`

### 11.6 Gen 1 CoIoT packet

116 bytes, hex:

```
501e0001b36369740173ed0bec09534853572d504d234134434631324634353637382332d243017e82002aff
7b2247223a5b5b302c313130312c315d2c5b302c343130312c32332e34355d2c5b302c343130332c313233345d2c
5b302c333130342c34312e325d2c5b302c323130312c305d5d7d
```

Decoded:
* `50` version 1, type NON, token length 0; `1e` code 0.30 (periodic); `0001` message id 1.
* `b3 636974` option 11 (Uri-Path) `cit`; `01 73` option 11 `s`.
* `ed 0bec 09` + 22 bytes: delta 14-extended = 0x0BEC + 269 = 3321 → option 3332; length 13-extended = 9 + 13 = 22;
  value `SHSW-PM#A4CF12F45678#2` → model `SHSW-PM`, id `A4CF12F45678`, CoIoT revision 2.
* `d2 43 017e`: delta 13-extended = 0x43 + 13 = 80 → option 3412; length 2; value 382 (even) → valid for 38 s.
* `82 002a`: delta 8 → option 3420; length 2; serial 42.
* `ff` then payload `{"G":[[0,1101,1],[0,4101,23.45],[0,4103,1234],[0,3104,41.2],[0,2101,0]]}`.

Expected for a Shelly 1PM: relay0 = true, power0 = 23.45, energyCounter0 = 1234, deviceTemperature = 41.2,
input0 = 0; device online with a 38 s TTL; accessory seed `Shelly 1PM A4CF12F45678` with Switch On = true and Power
Meter Consumption 23.45.

CoIoT v1 example for a Shelly 2.5 in roller mode: option 3332 `SHSW-25#B92F3A#1`, payload
`{"G":[[0,112,1],[0,122,0],[0,113,40],[0,111,55.0]]}` → mode `roller` (id 113 present), rollerPosition 40, relay0 on →
rollerState `open` (no swap) → Position State Increasing; one accessory, seed `Shelly 2.5 B92F3A`.

### 11.7 Fixtures to build (descriptions)

* Gen 2 handler: a fake WebSocket that answers `Shelly.GetDeviceInfo`, `Shelly.GetStatus`, `Shelly.GetConfig` from
  JSON files per model (Plus 1PM, Plus 2PM in both profiles, Plus I4 with mixed input types, Pro 4PM), records
  `Switch.Set`/`Cover.GoToPosition` frames, can push NotifyStatus/NotifyEvent frames, and can answer the first
  request of a session with the 401 above.
* Reconnect: close with code 1006 and check the schedule 5 s, 10 s, 30 s … 600 s, 600 s (scaled), reset after a
  successful open; close with 1000 must not reconnect; `reconnectInterval` given as `"5,10"`, `[5,10]`, `5` and `0`.
* mDNS: a response with a PTR answer `_shelly._tcp.local` → `shellypro4pm-aabbccddeeff._shelly._tcp.local` and an A
  answer; the same with the A record only in additionals (ignored by the original).
* Gen 1: CoIoT datagrams as in 11.6 for each model's ids in both revisions; a validity of 1 (odd) → 4 s; a message
  without option 3332; the Shelly 2.5 relay ↔ roller switch; RGBW2 with ids 171 and 181 (white) and without (colour);
  HTTP fake recording `/relay/0?turn=on`, `/roller/0?go=to_pos&roller_pos=30`, `/light/0?...`, `/color/0?...`.

---

## 12. Gaps and hard parts

* **G1 Which family to run.** The original Gen 1 and Gen 2 plugins are separate; a combined plugin must decide
  whether a lone `ShellyNG` block also listens for CoIoT (and vice versa). For drop-in fidelity: run each family only
  when its block exists.
* **G2 Gen 1 identity seeds** depend on the node-shellies model names and on the accessory count, which depends on the
  device mode at discovery. A mode change re-creates accessories (original behaviour). The seed quirk with configured
  names is described in 3.2.
* **G3 Accessory UUIDs** themselves (HAP-NodeJS `uuid.generate` of the seed) only matter if Homeswift ever imports a
  Homebridge accessory cache; the seed strings are what keeps Homeswift ids stable.
* **G4 IP changes (Gen 2).** After a device is added the original ignores re-discoveries, so a DHCP change leaves it
  reconnecting to the old address forever. A replacement should update the host when mDNS reports a new address for a
  known id. A failed first connection also leaves an orphaned handler reconnecting in the background in the original;
  do not copy that.
* **G5 Status after reconnect (Gen 2).** The original does not re-read status after reconnecting; values missed while
  disconnected stay stale until the next notification. Re-reading `Shelly.GetStatus` on reconnect is recommended.
* **G6 Sleeping Gen 2 devices** (Plus H&T, Plus Smoke, BLU via gateway when asleep) and outbound WebSocket are not
  supported by the original; aioshelly's outbound path is `/api/shelly/ws`.
* **G7 Components beyond switch/cover/input** (light, rgb/rgbw, em/em1/pm1, temperature/humidity, BLU) have no
  HomeKit mapping in either Homebridge plugin; section 6 gives the wire facts available. `em1`, `pm1`, `rgb`, `rgbw`
  field names were not present in the material read and must be taken from Shelly's public API documentation.
* **G8 mDNS TXT records.** Neither source reads TXT records; the id comes from the instance name and the IP from the A
  record. Gen 2 devices also advertise `_http._tcp` (aioshelly filters that type by a `Shelly` name prefix). Gen 1
  devices are discovered by CoIoT only; their mDNS advertisements were not described in the sources.
* **G9 Shelly Uni power meter.** The Uni factory gives each relay a Power Meter bound to `power0`/`power1`, which the
  Uni model never defines, so the original computes a non-number. Use 0 or omit the service; omitting changes the
  services relative to the original (but the original's value is invalid anyway).
* **G10 Shelly Gas type mismatch.** Its default type is `smokeSensor` while its accessory stores `sensor`, so the
  original treats it as "type changed" at every start and re-creates it (same seed). A replacement need not repeat
  the churn.
* **G11 Gen 1 button false press.** A re-created (cached, not yet heard) Button1/i3 starts with an empty event string;
  the first CoIoT update after start-up changes it to the last event and fires a press in the original. Suppressing
  the first observation after start-up is advisable.
* **G12 Uncalibrated covers (Gen 2)** get a published but dead service in the original (warning only).
* **G13 Outlet In Use on Gen 2** is pushed a number on updates; implement as `apower ≠ 0`.
* **G14 Cover target after manual moves (Gen 2).** Target Position follows `target_pos` only when the device reports
  it; after a move from a wall switch the device may report no `target_pos`, leaving HomeKit's target at the old
  value. Setting the target to the current position when the state becomes `stopped`/`open`/`closed` would avoid a
  stuck "Opening…" but is not what the original does.
* **G15 Gen 1 roller and light writes** acknowledge HomeKit before the request and only log failures; relay writes
  report failures. Keep or unify deliberately.
* **G16 Gen 1 device ids** are 6 hex characters on older firmware/models and 12 on newer ones; the configured id must
  be compared with the id exactly as CoIoT reports it (after uppercasing the configured one). aioshelly matches on the
  last 6 characters, the Gen 1 plugin on the full string.
* **G17 Authentication on Gen 1 CoIoT**: none; devices with restricted login still multicast status. `/settings`
  needs Basic auth when `auth` is true in `/shelly`.
