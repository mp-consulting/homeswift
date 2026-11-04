# TPLinkSmarthome: functional specification

Written by the spec writer; contains no source code. Everything below is a description, in the spec
writer's own words, of observable behaviour, wire formats and interface names (JSON keys, command names,
characteristic UUIDs) read from the sources listed under Provenance.

---

## 1. Provenance

| Package | Repository | Commit read | Version | License | Copyright |
|---|---|---|---|---|---|
| `homebridge-tplink-smarthome` (the Homebridge plugin) | https://github.com/plasticrake/homebridge-tplink-smarthome | `e716f80cf6fd5db4ea7f56c14ee4a4b1c56779d1` | 8.0.4 | MIT | Copyright (c) 2016 Donald Patrick Seal |
| `tplink-smarthome-api` (the protocol library the plugin uses, `~5.0.0`) | https://github.com/plasticrake/tplink-smarthome-api | `33f55531e6d5935d57a065fb95fa5dc340c4f392` | 5.0.0 | MIT | Copyright (c) 2016 Donald Patrick Seal |
| `tplink-smarthome-crypto` (the cipher, a dependency of the API, `^4.0.0`) | https://github.com/plasticrake/tplink-smarthome-crypto | `cdbb96ae372ec3c78702fb6b6c6e2aec7164ce4f` | 4.0.0 | MIT | Copyright (c) 2017 Donald Patrick Seal |
| `tplink-smarthome-simulator` (the API's test fake; read only for realistic sysinfo field shapes) | https://github.com/plasticrake/tplink-smarthome-simulator | `c8a3155ffde27effe74d57b46e510c6334a01e25` | 5.0.1 | MIT | Copyright (c) 2017 Donald Patrick Seal |

The sources were cloned and read as text only; none of their code was run. The cipher test vectors in
section 9 were computed by the spec writer with an independent script written from the description in
section 5.1, not from the sources' tests.

THIRD-PARTY-NOTICES: the port is of MIT-licensed work by Donald Patrick Seal (the plugin, the API, the
crypto package).

---

## 2. Scope in one paragraph

A single (singular) dynamic platform. It discovers TP-Link Kasa "Smart Home" devices on the LAN by UDP
broadcast on port 9999 (plus optional unicast to configured hosts), talks to each over TCP 9999 (or UDP)
using a JSON protocol obfuscated with an XOR autokey cipher, and exposes each device (or each outlet of a
multi-outlet strip) as one HomeKit accessory: an Outlet, a Switch or a Lightbulb, with optional Eve
energy characteristics. State is refreshed by the periodic discovery broadcast (default every 10 s) and,
for energy, by a separate poll (default every 20 s). No cloud, no credentials. Tapo devices and the newer
KLAP-authenticated Kasa firmware are **not supported** (section 5.9).

---

## 3. Configuration interface

### 3.1 Platform block

- Platform name (the `platform` value, also the plugin alias): **`TplinkSmarthome`** (exact case: capital
  T, lowercase "plink", capital S, lowercase "marthome").
- Plugin package name: `homebridge-tplink-smarthome`.
- Singular: only one block of this platform is expected.
- Minimal block: `{"platform": "TplinkSmarthome", "name": "TplinkSmarthome"}`. Most users have exactly
  this.
- Unknown keys are allowed (no additional-properties restriction), so `platform`, `_bridge` etc. pass.

### 3.2 Options

All keys are top level in the platform block. "Effective default" is what the plugin uses when the key
is absent (only keys that are absent/undefined get the default; an explicit value, even a falsy one, is
kept).

| JSON key | JSON type | Effective default | Allowed values / validation | Meaning |
|---|---|---|---|---|
| `name` | string | (schema default `"TplinkSmarthome"`) | **required** by the schema, min length 1 | Platform display name; used only as the log prefix. |
| `addCustomCharacteristics` | boolean | `true` | boolean | Add the Eve energy characteristics (section 4.6) to devices that report energy. When false, any previously added ones are removed. |
| `emeterPollingInterval` | integer (seconds) | `20` | integer | How often energy readings are polled. `0` or negative disables the energy poll entirely (readings then only refresh on HomeKit reads). |
| `inUseThreshold` | number (watts) | `0` | number | For energy-monitoring plugs: OutletInUse is true when power **strictly greater than** this. (The API's own default is 0.1 W, but the plugin always passes its own value, so the effective default is 0.) |
| `switchModels` | array of strings | `["HS200", "HS210"]` | strings | A plug whose `model` **contains** any entry as a substring (case-sensitive) is exposed as a Switch instead of an Outlet/Lightbulb. Supplying the key replaces the default list entirely. |
| `discoveryPort` | number | `0` | number | Local UDP port the discovery socket binds to. 0 = OS-chosen ephemeral port. |
| `broadcast` | string | `"255.255.255.255"` | IPv4 address format | Destination address of the discovery broadcast (e.g. a subnet broadcast `192.168.0.255`). |
| `pollingInterval` | integer (seconds) | `10` | integer | Interval between discovery rounds. Discovery is also the state poll: every response refreshes the device's cached sysinfo and pushes HomeKit updates. |
| `deviceTypes` | array of strings | `["bulb", "plug"]` (schema UI default `["plug","bulb"]`; order irrelevant) | each `"plug"` or `"bulb"` | Only discover these kinds. An empty array means no type filtering. |
| `macAddresses` | array of strings | absent (no allow-list) | strings, glob patterns | Allow-list. When non-empty, only devices whose MAC matches one pattern are added. |
| `excludeMacAddresses` | array of strings | absent | strings, glob patterns | Deny-list. Devices whose MAC matches a pattern are skipped. Applied after the allow-list. |
| `devices` | array of objects | absent | each object needs `host` (string); optional `port` | Hosts that also get the discovery packet by unicast each round (in addition to the broadcast), for networks where broadcast does not work. Needs static IPs. |
| `devices[].host` | string | — | required | IP or hostname to send the discovery packet to. |
| `devices[].port` | see quirk | `9999` | see quirk | Destination port for the unicast discovery packet only. It does **not** set the port used for subsequent commands (that is 9999, or the discovery reply's source port if `devicesUseDiscoveryPort`). |
| `timeout` | integer (seconds) | `15` | integer | Per-request communication timeout (converted to ms). 0 means no timeout. |
| `transport` | string | absent → TCP | `"tcp"` or `"udp"` | Transport for commands. Discovery always uses UDP. |
| `waitTimeUpdate` | integer (ms) | `100` | integer | Coalescing window for HomeKit reads/writes to one device (section 6.6). |
| `devicesUseDiscoveryPort` | boolean | `false` | boolean | When true, the device's command port becomes the source port of its discovery reply; when false, always 9999. |

Validation in the source: the block is validated against the JSON schema (types, enums, ipv4 format,
`name` required) and then a second hand-written type check; any failure aborts the platform with an error
listing each offending path and message (e.g. "`devices/0/host` must be string", "must have required
property 'host'").

**Quirk, `devices[].port`:** the schema declares it a *string* (the README example writes `"9999"`), but
the second type check requires a *number*. In the source, therefore, any block that sets `port` at all
fails to load. A drop-in replacement should accept both a number and a numeric string, and treat it as
the unicast discovery destination port.

**Note:** the README's "all options" sample also lists `"transport": "tcp"`, `"macAddresses": []`,
`"excludeMacAddresses": []`, `"devices": []`; those are equivalent to absent (empty lists disable the
filters).

### 3.3 MAC matching (both lists)

- Device MAC is taken from sysinfo `mac`, else `mic_mac`, else `ethernet_mac`, else empty.
- Normalisation of the device MAC: remove every character that is not an ASCII letter or digit, then
  uppercase. `aa:bb:cc:00:11:22` → `AABBCC001122`.
- Normalisation of a pattern: remove every character that is not an ASCII letter, digit, `?` or `*`;
  uppercase; then `?` matches exactly one character and `*` matches zero or more; the pattern must match
  the whole normalised MAC (anchored both ends).
- A device matches a list if any pattern matches.

---

## 4. Device model and HomeKit mapping

### 4.1 Device kinds, as read from `system.get_sysinfo`

The type string is sysinfo `type` if present, else `mic_type`. Kind:
- contains "plug" (case-insensitive) → **plug** (e.g. `IOT.SMARTPLUGSWITCH`, `IOT.RANGEEXTENDER.SMARTPLUG`);
- contains "bulb" (case-insensitive) → **bulb** (`IOT.SMARTBULB`);
- otherwise "device" (filtered out by `deviceTypes` unless that list is empty; then object creation
  still fails because it is neither shape below, and the response is discarded).

Shape checks used to build an object (plug is tried first):
- Common: has `alias`, `deviceId`, `model`, `sw_ver`, `hw_ver`.
- Plug shape: common + (`type` or `mic_type`) + (`mac` or `ethernet_mac`) + `feature` + (`relay_state`
  or `children`).
- Bulb shape: common + `mic_type`, `mic_mac`, `description`, `light_state`, `is_dimmable`, `is_color`,
  `is_variable_color_temp`.

Capabilities:
- Plug **supports energy** iff `feature` is a string containing `ENE` (e.g. `"TIM:ENE"`).
- Plug **is a dimmer** iff sysinfo has a `brightness` key (HS220, ES20M, KP405…).
- Plug **has outlets** iff `children` is a non-empty array (HS107, HS300, KP303, KP400, KP200, EP40…).
- Bulb: dimmable iff `is_dimmable == 1`; tunable white iff `is_variable_color_temp == 1`; colour iff
  `is_color == 1`.
- Bulb **is a light strip** iff sysinfo `length` is a number > 0 (KL400, KL420, KL430). This changes the
  lighting module and method names (section 5.6), not the HomeKit mapping.
- Bulb **always** counts as supporting energy (the library hard-wires it). Energy requests to bulbs that
  lack a meter simply fail and are logged.

### 4.2 Identity (stable ids)

- **Device id seed** for a single device: sysinfo `deviceId` exactly as reported (typically 40 uppercase
  hex characters).
- **Outlet id seed** for each child of a multi-outlet device: the child's `id`, normalised:
  - when the reported child `id` is 2 characters (e.g. `"00"`), the seed is `deviceId` followed by those
    2 characters;
  - when it is 1 character, `deviceId` + `"0"` + the character;
  - otherwise (most firmware already reports the full 42 characters) the `id` as is.
  Example: deviceId `8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A`, child `"01"` →
  `8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A01`.
- A multi-outlet device yields **only** its outlets as accessories; the parent itself is never an
  accessory.
- Devices whose `deviceId` is missing or empty are ignored at discovery.
- Homebridge accessory UUID = HAP-NodeJS `uuid.generate(seed)` (SHA-1 of the seed's UTF-8 bytes, laid out
  as a version-4-shaped UUID: hex digits 0–7, 8–11, then "4" + digits 12–14, then the variant nibble
  `(digit15 & 3) | 8` + digits 16–18, then digits 19–30). This derivation is HAP-NodeJS's, not these
  sources'; verify against Homeswift's existing Homebridge-cache helper. Vectors in section 9.4.
- The accessory's stored context is `{ "deviceId": <seed> }` (the seed, i.e. the child id for outlets).
- The seed alone determines identity; the MAC is not part of it. (The MAC appears only in the serial
  number.)
- Each accessory has exactly one primary service of type Outlet, Switch or Lightbulb, created **without a
  subtype**, named with the alias. So per-accessory service keys are just the service type UUID.

### 4.3 Accessory Information

| Characteristic | Value |
|---|---|
| Name | alias (child alias for an outlet) |
| Manufacturer | `TP-Link` |
| Model | sysinfo `model` (an outlet reports its parent's model, e.g. `HS300(US)`) |
| SerialNumber | `<mac> <id>` — the MAC exactly as reported (with colons, from `mac`/`mic_mac`/`ethernet_mac`), one space, then the id seed. Outlets use the parent's MAC and their own child id. |
| FirmwareRevision | sysinfo `sw_ver` (e.g. `1.5.7 Build 180912 Rel.104837`) — a free string, not a HAP x.y.z version |
| HardwareRevision | sysinfo `hw_ver` (e.g. `1.0`) |

Category: Outlet (7), Switch (8) or Lightbulb (5), matching the primary service. On every start an
existing accessory's display name is reset to the current alias and its category corrected if it changed.

### 4.4 Plug decision table

Evaluated in this order:
1. Model contains any `switchModels` entry → **Switch** (category Switch).
2. Else dimmer (sysinfo has `brightness`) → **Lightbulb**.
3. Else → **Outlet**.

| Kind | Service | Characteristics |
|---|---|---|
| Outlet (plain plug, or one outlet of a strip) | Outlet | On; OutletInUse; + energy set if energy & enabled |
| Switch (`switchModels` match) | Switch | On; + energy set if energy & enabled. No OutletInUse. |
| Dimmer plug/switch | Lightbulb | On; Brightness; + energy set if energy & enabled |

Note: a dimmer whose model matches `switchModels` becomes a Switch without Brightness.

Outlet services of other kinds, and Brightness on Outlet/Switch services, are removed if present from an
earlier configuration (section 6.5).

### 4.5 Bulb mapping

Always one **Lightbulb** service with:
- **On** (always);
- **Brightness** iff dimmable;
- **ColorTemperature** iff tunable white, with props from the model's kelvin range (4.5.1);
- **Hue** and **Saturation** iff colour;
- **Watts** (Eve "Consumption", section 4.6) iff `addCustomCharacteristics` (bulbs always count as energy
  capable).
Characteristics not applicable are removed if present.

README's model examples: KL50/LB100/LB110/LB200 dimmable only; LB120/KL120 dimmable + colour temperature;
KL125/KL400/KL430/LB130/LB230 everything.

#### 4.5.1 Kelvin ranges and mired props

Range chosen by the first pattern (anchored at the start of `model`) that matches, in this order:

| Model starts with | Min K | Max K | ColorTemperature minValue (mired) | maxValue (mired) |
|---|---|---|---|---|
| `KB130` | 2500 | 9000 | 112 | 400 |
| `KL120(EU)` | 2700 | 6500 | 154 | 370 |
| `KL120(US)` | 2700 | 5000 | 200 | 370 |
| `KL125` | 2500 | 6500 | 154 | 400 |
| `KL130` | 2500 | 9000 | 112 | 400 |
| `KL135` | 2500 | 9000 | 112 | 400 |
| `KL430` | 2500 | 9000 | 112 | 400 |
| `LB120` | 2700 | 6500 | 154 | 370 |
| `LB130` | 2500 | 9000 | 112 | 400 |
| `LB230` | 2500 | 9000 | 112 | 400 |
| anything else (e.g. `KL120(JP)`, `KL400L5`, `LB110`) | 2700 | 6500 | 154 | 370 |

Props: minValue = ceil(1,000,000 / maxK); maxValue = floor(1,000,000 / minK). Mired and kelvin are
inverse: the coolest kelvin is the smallest mired.

#### 4.5.2 Conversions

- Kelvin → mired for reported values: round(1,000,000 / K) (nearest integer).
- Mired → kelvin for writes: round(1,000,000 / mired). No clamping (the props keep it in range; e.g.
  112 → 8929 K, 400 → 2500 K, 154 → 6494 K, 370 → 2703 K, 200 → 5000 K).
- Brightness: device and HomeKit both 0–100, passed through unchanged.
- Hue: device 0–360 degrees, HomeKit 0–360, unchanged.
- Saturation: device 0–100, HomeKit 0–100, unchanged.
- Colour mode vs white mode: device `color_temp` > 0 means white mode; `color_temp` = 0 means colour mode
  (hue/saturation meaningful).

### 4.6 Eve energy characteristics

All are custom characteristics with: format float (except where noted), minValue 0, maxValue 65535,
permissions paired-read + notify (read-only, no write), initial value the format default (0).

| Name used in code/logs | HAP display name | UUID | Unit | minStep | Source value |
|---|---|---|---|---|---|
| Volts | `Volts` | `E863F10A-079E-48FF-8F27-9C2605A29F52` | V | 0.1 | `voltage` |
| Amperes | `Amperes` | `E863F126-079E-48FF-8F27-9C2605A29F52` | A | 0.01 | `current` |
| Watts | `Consumption` | `E863F10D-079E-48FF-8F27-9C2605A29F52` | W | 0.1 | `power` |
| VoltAmperes | `Apparent Power` | `E863F110-079E-48FF-8F27-9C2605A29F52` | VA | 0.1 | `voltage × current` (see quirk) |
| KilowattHours | `Total Consumption` | `E863F10C-079E-48FF-8F27-9C2605A29F52` | kWh | 0.001 | `total` |
| KilowattVoltAmpereHour | `Apparent Energy` | `E863F127-079E-48FF-8F27-9C2605A29F52` | kVAh | 1 (format uint32) | **defined but never added** to any service (the README claims HS110 has it; the code does not) |

Which accessory gets what (only when `addCustomCharacteristics` is true; otherwise all are removed):
- Plug kinds with energy (`feature` contains `ENE`: HS110, HS300 outlets, KP115, KP125, EP25 hw…):
  Amperes, KilowattHours, VoltAmperes, Volts, Watts, all on the primary service (Outlet, Switch or
  Lightbulb).
- Plugs without energy: none.
- Bulbs: Watts only, on the Lightbulb service.

These are added to the existing primary service; no Eve history service, no separate Eve service.

Values (units after normalisation, section 5.7): volts V, amperes A, watts W, total kWh. When a field is
missing in a reading, the pushed value for that characteristic is null (a plug) and the read value is 0.
For bulbs a missing `power` pushes an error status ("Could not retrieve watts") and a read returns null
with a warning.

**Quirk, VoltAmperes:** a pushed update (after each energy reading) carries voltage × current, but a
HomeKit read of it in the source returns voltage × voltage (an evident slip). A replacement should use
voltage × current for both.

### 4.7 Characteristic behaviour per kind

All reads return the **cached** value at once and, in the background, start a coalesced refresh
(section 6.6) whose result arrives later as pushed updates. Reads never fail.

**Plug (any kind), On**
- Read: cached relay state: for an outlet, its child `state == 1`; for a single plug, `relay_state == 1`.
  (A multi-outlet parent is never exposed, so the "any child on" rule does not apply.)
- Write: must be boolean (anything else → error to HomeKit). Coalesced (6.6): the last value written
  during the window is sent once: `system.set_relay_state` `{"state":1|0}` with the child context for an
  outlet. On success the cache is updated and On (and OutletInUse) pushed. On failure the write fails to
  HomeKit.
- Background refresh: `system.get_sysinfo`.

**Outlet, OutletInUse** (only on Outlet services)
- Value: if the device supports energy and has a cached `power` reading: `power > inUseThreshold`;
  otherwise equals the relay state.
- Pushed after every sysinfo update and every relay write. Energy readings update the cache it reads,
  but do not push it themselves; the next sysinfo update does. See Gaps item 3.

**Dimmer plug, Brightness**
- Read: cached sysinfo `brightness`.
- Write (number): if > 0, send `smartlife.iot.dimmer` `set_brightness` `{"brightness": n}` (no child
  context) and update the cache immediately (before the reply); this does **not** turn the relay on
  (since 8.0.3, deliberately). If 0, send `system.set_relay_state` `{"state":0}` (turns off) and do not
  change brightness. Not coalesced. Non-number → error.
- Pushed on every sysinfo update that includes `brightness`, and after a brightness write.

**Bulb, On / Brightness / ColorTemperature / Hue / Saturation**
- Writes are merged into one pending light state per bulb and sent once after the coalescing window:
  - On → `on_off` 1/0;
  - Brightness → `brightness` n;
  - ColorTemperature mired m → `color_temp` round(1e6/m);
  - Hue h → `hue` h **and** `color_temp` 0;
  - Saturation s → `saturation` s **and** `color_temp` 0.
  Later keys overwrite earlier ones within the window (so a ColorTemperature write after a Hue write in
  the same window wins `color_temp`, and vice versa). Non-number/non-boolean values are logged as a
  warning and ignored (the write "succeeds").
- The command always includes `"ignore_default": 1` (section 5.6). If nothing is pending when the timer
  fires, nothing is sent.
- Reads (cached sysinfo `light_state`):
  - On: `on_off == 1`.
  - Brightness: `brightness`, else `dft_on_state.brightness`, else 0.
  - ColorTemperature: if `color_temp` > 0 → round(1e6/K); else if `dft_on_state.color_temp` > 0 →
    round(1e6/K); else floor(1e6/minK) (the warmest end, = maxValue).
  - Hue: `hue`, else `dft_on_state.hue`, else 0. Saturation likewise.
  (When a bulb is off, devices report only `on_off: 0` plus `dft_on_state`, the state it will come back
  on in; that is why reads fall back to it.)
- Background refresh: `system.get_sysinfo` (not `get_light_state`).
- Pushed updates come from two sources: each sysinfo `light_state` (discovery or refresh) and each
  reply of a set command (merged onto the previous reply-derived state). For each such state:
  - On pushed if `on_off` present;
  - Brightness pushed if `brightness` present;
  - ColorTemperature pushed if `color_temp` > 0;
  - if `color_temp` > 0: Hue and Saturation pushed as 0; else Hue pushed if present, Saturation pushed
    if present.
  So with the bulb off nothing but On changes.

**Watts / energy set**: read returns the cached reading (0/null if none) and triggers a coalesced
`get_realtime`; pushed after every reading.

### 4.8 Identify

- Plug kinds: blink the device LED once, then twice, each blink cycle 500 ms (section 6.7). Errors
  logged.
- Bulbs: read the current light state, then three times: set on at brightness 100, wait 500 ms, set on
  at brightness 10, wait 500 ms; finally restore the original light state (on_off, mode, hue, saturation,
  brightness, color_temp, transition_period as they were in sysinfo). Each set goes through the coalescing
  window. Errors logged.

---

## 5. Protocol

### 5.1 Cipher ("autokey" XOR, initial key 171)

Let the plaintext be the UTF-8 bytes p₀ … pₙ₋₁ (non-ASCII characters are encoded as UTF-8 first; the
cipher works on bytes).

- Encryption: k₀ = 171 (0xAB). cᵢ = pᵢ XOR kᵢ, and kᵢ₊₁ = cᵢ. Each ciphertext byte is the key for the
  next one.
- Decryption: k₀ = 171. pᵢ = cᵢ XOR kᵢ, and kᵢ₊₁ = cᵢ (the *ciphertext* byte, not the plaintext one).
  Equivalently p₀ = c₀ XOR 171, and pᵢ = cᵢ XOR cᵢ₋₁ for i ≥ 1.
- Empty input → empty output. Lengths are preserved.
- There is no key exchange, no authentication, no integrity check. It is obfuscation only.

### 5.2 TCP framing (port 9999, default transport)

- Request: a 4-byte **unsigned big-endian** length of the ciphertext, followed by the ciphertext. No
  trailing bytes.
- Response: the same framing. The receiver accumulates segments until at least 4 bytes are present, reads
  the length (the source reads it as a signed 32-bit big-endian, harmless in practice), and when
  `received − 4 ≥ length` decrypts bytes 4…end (all of them) as UTF-8.
- One TCP connection per request: connect, write the frame, read the full frame, then half-close (FIN)
  and treat the response as final when the socket closes. A close before any data arrived, or a socket
  error, is a failure. Responses are routinely split over several TCP segments (sysinfo of a strip or
  bulb can be > 1 KB).
- Timeout: the configured `timeout` (default 15 s in the plugin) runs from the start of the request;
  on expiry the socket is destroyed and the request fails ("TCP Timeout after N ms").
- Requests to the same device over the same transport are **serialised** (one in flight at a time, FIFO
  queue, unbounded).

### 5.3 UDP transport (option `transport: "udp"`) and UDP datagrams in general

- Datagrams carry the ciphertext **without** the 4-byte length prefix.
- A UDP command uses a fresh UDP socket bound to an ephemeral port, sends one datagram to host:port and
  takes the first datagram that arrives as the response (decrypted to UTF-8). Timeout as above
  ("UDP Timeout after N ms").
- Large multi-command requests are prone to fail over UDP; the plugin uses only single commands.

### 5.4 Discovery

- One UDP/IPv4 socket bound to `discoveryPort` (0 = ephemeral) on all addresses, with broadcast enabled.
- Discovery payload: the plaintext `{"system":{"get_sysinfo":{}}}` (exactly these 29 bytes, no
  whitespace), encrypted, no length prefix (vector 9.1).
- Each round: (a) offline check (5.8); (b) send the payload to `broadcast`:9999; (c) send it to every
  `devices[]` entry at host:(port or 9999); (d) increment the round counter. The first round runs as soon
  as the socket is bound, then every `pollingInterval` seconds. Discovery runs until shutdown (no
  discovery timeout).
- Replies arrive on the same socket from the device's IP, source port normally 9999. Each reply is a
  datagram holding the encrypted JSON `{"system":{"get_sysinfo":{…sysinfo…}}}` (some firmware adds other
  top-level modules; they are ignored).
- Processing a reply:
  1. Decrypt and parse JSON. It must have `system.get_sysinfo` as a non-null object; otherwise the reply is
     ignored (logged at debug as an invalid discovery reply).
  2. `deviceTypes` filter (4.1).
  3. MAC allow-list, then deny-list (3.3).
  4. Ignore if `deviceId` is missing or empty.
  5. If `children` is a non-empty array: for each child, compute the outlet id (4.2) and create-or-update
     an object for it; else create-or-update one object keyed by `deviceId`.
  6. Create-or-update: if the id is known, set its host to the reply's source IP (so DHCP address changes
     are followed), its port to the reply's source port only when `devicesUseDiscoveryPort`, replace its
     cached sysinfo with this one (which pushes HomeKit updates, section 6.3), mark it online and record
     the round number it was seen in. If unknown, create it (host = source IP, port 9999 or the source
     port) and mark it new + online.
  7. Any parse/shape error → the reply is discarded.
- Shutdown: stop the timer, close the socket.

### 5.5 Commands and responses (as used by the plugin)

General request shape: a JSON object whose top-level keys are module names, each holding an object of
method names, each holding a parameter object. For an outlet of a strip, a top-level `context` key is
added **after** the module key: `"context":{"child_ids":["<full 42-char child id>"]}` (child ids are
normalised as in 4.2 before sending).

General response shape: the same module/method nesting, each method object containing `err_code`
(0 = success) and, on error, often `err_msg`. A response is accepted only if every method requested is
present with `err_code` 0; a missing `err_code` or a non-zero one is an error (message includes the raw
response and the command). For a single command the useful result is the inner method object.

Device error codes seen in practice (from the simulator's behaviour): `-1` module not support, `-2`
method not support, `-3` invalid argument (format), `-10000` invalid input argument (e.g. colour
temperature out of range), `-14` entry not exist (bad child id).

| Purpose | Request (plaintext JSON) | Successful response (inner object) |
|---|---|---|
| Sysinfo (all kinds; never with child context; also the discovery payload) | `{"system":{"get_sysinfo":{}}}` | the sysinfo object with `err_code: 0` (section 9.3 examples) |
| Relay on/off (plug, outlet) | `{"system":{"set_relay_state":{"state":1}}}` (0 for off), plus `context` for an outlet | `{"err_code":0}` |
| LED on/off (identify) | `{"system":{"set_led_off":{"off":0}}}` (`off:0` = LED on, `1` = LED off); never with context | `{"err_code":0}` |
| Dimmer brightness | `{"smartlife.iot.dimmer":{"set_brightness":{"brightness":50}}}` | `{"err_code":0}` |
| Energy, plug / outlet | `{"emeter":{"get_realtime":{}}}`, plus `context` for an outlet (each outlet of an HS300 meters separately) | reading object + `err_code` (5.7) |
| Energy, bulb | `{"smartlife.iot.common.emeter":{"get_realtime":{}}}` | reading object + `err_code` (bulbs typically report only `power_mw`) |
| Bulb light state | `{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{…}}}` | the resulting light state + `err_code` |
| Light strip light state | `{"smartlife.iot.lightStrip":{"set_light_state":{…}}}` | a subset of the light state (`on_off`, `mode`, maybe `groups`) + `err_code` |

Not used by the plugin (exist in the API): `get_light_state`, `get_light_details`, schedule, timer,
away, cloud, time, netif, `set_dev_alias`, reboot/reset. The plugin never renames devices.

### 5.6 Light-state parameter object

Keys, in this order, each only when given:
`ignore_default` (always present, 1 unless explicitly 0), `transition_period` (ms), `on_off` (0/1),
`mode` (e.g. `"normal"`), `hue` (0–360), `saturation` (0–100), `brightness` (0–100), `color_temp` (kelvin,
0 = colour mode). The plugin never sends `transition_period` or `mode` except when restoring the state
after identify.

Example: turning a bulb on at 50 %:
`{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"on_off":1,"brightness":50}}}`.

Bulb reply when on (typical): `{"on_off":1,"mode":"normal","hue":0,"saturation":0,"color_temp":2700,"brightness":50,"err_code":0}`.
Bulb reply when off (typical): `{"on_off":0,"dft_on_state":{"mode":"normal","hue":0,"saturation":0,"color_temp":2700,"brightness":50},"err_code":0}`.

### 5.7 Energy reading normalisation

Two firmware generations:
- V1 (older HS110): `current` (A), `voltage` (V), `power` (W), `total` (kWh), floats.
- V2 (newer): `current_ma` (mA), `voltage_mv` (mV), `power_mw` (mW), `total_wh` (Wh), integers.

For each pair (current/current_ma, power/power_mw, total/total_wh, voltage/voltage_mv): if the V1 field is
a number and the V2 field is absent, V2 = floor(V1 × 1000); else if the V1 field is null/absent and the V2
field is a number, V1 = V2 / 1000. HomeKit uses the V1 (SI) values. Other fields (`err_code`, `slot_id`)
are kept and ignored.

Example: `{"voltage_mv":121512,"current_ma":82,"power_mw":4380,"total_wh":1520,"err_code":0}` → volts
121.512, amperes 0.082, watts 4.38, kWh 1.52, VoltAmperes 121.512 × 0.082 = 9.964.

### 5.8 Polling, timeouts, offline detection

- State poll = discovery, every `pollingInterval` (default 10 s). There is no per-device sysinfo poll
  otherwise; extra sysinfo requests happen only as the background refresh of HomeKit reads.
- Energy poll: when `emeterPollingInterval` > 0, starts once at launch and then re-arms itself
  `emeterPollingInterval` after each run finishes (not a fixed-rate timer). A run groups the exposed
  accessories by host; hosts run in parallel; within a host (e.g. the six outlets of an HS300) requests run
  one after another. Only energy-capable accessories are polled (every bulb counts as capable). Failures
  are logged per device and do not stop the run.
- Request timeout: `timeout` (default 15 s).
- Offline: before each discovery round, any known device not already offline whose last-seen round is 3
  or more rounds behind the current round counter is marked offline. With the default interval this is
  about 30 s without a reply. The plugin only logs it at debug level: **the accessory stays, its
  characteristics keep their last values, and no "No Response" status is set.** When it replies again it
  is marked online and its sysinfo replaces the cache (which pushes values). Commands to an offline device
  are still attempted and fail by timeout.

### 5.9 KLAP / Tapo / newer firmware

Not handled by any of the sources. The API README states Tapo devices are not supported and the plugin
README says they are out of scope. Devices on the newer authenticated protocol (KLAP over HTTP, used by
some recent Kasa hardware revisions; outside knowledge, not from these sources) do not answer the
port-9999 discovery and therefore simply never appear. A drop-in replacement need not support them.

---

## 6. Behaviour

### 6.1 Startup

1. Validate the block (3.2); on failure, log the error list and do not start.
2. Restore cached accessories (keyed by UUID/seed) without touching them.
3. Start discovery and, if enabled, the energy poll.
4. On each newly seen device id: if an accessory for that id already exists in this run, do nothing more;
   otherwise reuse the cached accessory with that UUID (correct its name and category, store the id in its
   context) or create and register a new one; then build/repair its services (6.5).

### 6.2 Accessories never seen

Cached accessories whose device never shows up are **kept indefinitely** (never unregistered). They
answer HomeKit with whatever the cache holds (no handlers are attached until the device is found).

### 6.3 Updates from sysinfo

Every new sysinfo (discovery reply or a refresh) for a plug: recompute the relay state and in-use value
and push On and OutletInUse (pushed every time, changed or not); for a dimmer also push Brightness. For an
outlet, its state comes from its own entry in `children`. For a bulb: apply the light-state rules of 4.7
to `light_state`.

### 6.4 Names

The alias (child alias for outlets) is the accessory display name, service name and Name characteristic,
reapplied at each start. Renaming in the Kasa app is picked up on the next restart only (the plugin does
not rename at runtime). Renames in the Home app are HomeKit-side.

### 6.5 Service repair on start

- Remove every service other than Accessory Information, Lightbulb, Outlet and Switch.
- Then remove the primary-service types that do not match the current kind (e.g. a plug that became a
  Switch loses its Outlet service), remove Brightness from Outlet/Switch services, remove inapplicable
  bulb characteristics and energy characteristics as described in 4.4–4.6.
- Add missing characteristics to the existing service rather than recreating it, so its iid is kept.

### 6.6 Coalescing ("waitTimeUpdate")

For each accessory there are coalesced operations: sysinfo refresh, energy refresh, plug relay write,
bulb light-state write. The first call opens a window of `waitTimeUpdate` ms (default 100); every call
made during the window joins it; when the window closes the operation runs once and all joined callers
get its single result (or error). Writes keep only the final desired value (plug) or the merged desired
state (bulb), which is cleared when the command is sent. HomeKit typically sends On + Brightness (or
Hue + Saturation) together, which therefore become one device command.

### 6.7 Plug LED blink (identify)

Blink(times, rate): read sysinfo to learn the original LED state (`led_off == 0` means on). Then
2 × times steps, alternating LED on, off, on, off… (starting with on), each step one `set_led_off`
command padded to at least rate/2 ms. If the final state differs from the original, set the original
back. The identify does blink(1, 500) then blink(2, 500).

### 6.8 Edge cases

- Multi-outlet strip with energy (HS300): each outlet has its own energy set and its own OutletInUse
  from its own `power`; the strip's `feature` decides capability for all outlets.
- Strip outlets share one host; their commands run independently but the device serialises them (each
  outlet object keeps its own connection queue in the source).
- A device that changes IP is followed by discovery (5.4, step 6). A device that changes from plug
  to bulb kind cannot happen for the same id.
- A child id that cannot be found in the parent's `children` aborts creation of that outlet (logged).
- `children: null` in a sysinfo reply makes that reply be discarded.
- `pollingInterval` 0 would make discovery spin continuously; the source does not guard it (a
  replacement should impose a sane minimum).
- `timeout` 0 disables the timeout entirely.
- Hue/Saturation writes force colour mode (`color_temp` 0); a ColorTemperature write forces white mode by
  sending a non-zero `color_temp`.
- Brightness 0 on a bulb is sent as brightness 0 (devices clamp to 1 or turn off; firmware-dependent);
  only the dimmer plug maps 0 to relay off.
- Light strips: same HomeKit mapping as a colour bulb; the sysinfo `light_state` of a strip that is on
  carries `hue`, `saturation`, `color_temp`, `brightness`; when off, `dft_on_state` may only carry `mode`
  and `groups`, so reads fall back to 0 / warmest temperature.

---

## 7. Logging (paraphrased)

Info:
- At start: plugin name and version, runtime and Homebridge versions.
- For each cached accessory restored: its display name, UUID and stored device id.
- When a device first answers: "device first online" with alias, kind (`plug`/`bulb`), id, host, port.
- When an accessory is added: alias, kind, id.
- Each HomeKit write: "Setting <characteristic> to: <value>" (On, Brightness, ColorTemperature, Hue,
  Saturation).
- Identify start (plug).

Warn:
- Removing a stale service or characteristic (names its type, UUID and subtype).
- Correcting an accessory's category.
- Invalid value types in HomeKit writes; a write fired with nothing pending.
- Bulb read of Watts when no reading exists.

Error:
- Configuration errors (list of path + message).
- A device reply without a device id.
- Failed energy reading (device alias and the error), failed background refresh (the error as JSON),
  failed identify, failed sends (transport + host:port + error), UDP discovery socket errors (discovery
  stops on a socket error).
- Missing colour temperature range.

Debug: the whole config block, every request payload and decrypted response, every pushed characteristic
value, discovery filtering decisions (alias, id, MAC, reason), online/offline transitions, scheduling of
the energy poll.

Secrets: **none**. The local protocol has no credentials or tokens; the cipher has a fixed public key.
MAC addresses and device ids are identifiers (personal-ish data, fine at debug level); device responses
may include Wi-Fi RSSI, latitude/longitude (`latitude_i`, `longitude_i` in some sysinfo) and the cloud
account's username in `cnCloud` replies (the plugin never requests the latter). A replacement may want to
mask location fields when logging raw sysinfo.

---

## 8. Fixtures worth building (described, not copied)

The API's tests run against a simulator (a fake device that speaks the real cipher over TCP and UDP 9999,
answers discovery, and models modules per device). Fixtures to reproduce in tests:
- A plain plug (HS100/HS105-like: `feature` `"TIM"`, `relay_state`, `mac`).
- An energy plug, both generations: V1 readings (HS110 v1) and V2 readings (HS110 v2 / KP115).
- A dimmer (HS220: `mic_type`, `brightness`, `feature` `"TIM"`).
- A six-outlet strip with energy (HS300: `children` with full 42-char ids, `feature` `"TIM:ENE"`, per-child
  emeter reached through `context.child_ids`; an unknown child id answers `err_code -14`).
- Bulbs: dimmable only (LB100), tunable (LB120), colour (LB130), a light strip (KL430 with `length` 16,
  module `smartlife.iot.lightStrip`).
- A colour-temperature write outside the model's range answers `err_code -10000`.
- An "unreliable" device that never answers (for timeouts and offline after 3 rounds).
- Discovery replies that are not valid JSON or lack `system.get_sysinfo` (must be ignored).

---

## 9. Test vectors (computed independently)

### 9.1 Discovery / sysinfo request

Plaintext (29 bytes): `{"system":{"get_sysinfo":{}}}`

Ciphertext (UDP datagram, no prefix):
`d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08bf68bf6`

TCP frame:
`0000001d` + `d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08bf68bf6`

### 9.2 Other commands

`{"system":{"set_relay_state":{"state":1}}}` (42 bytes):
`d0f281f88bff9af7d5ef94b6c5a0d48bf99cf091e8b7c4b0d1a5c0e2d8a381f286e793f6d4eedfa2dfa2`
TCP frame prefix `0000002a`.

`{"emeter":{"get_realtime":{}}}` (30 bytes):
`d0f297fa9feb8efcdee49fbddabfcb94e683e28efa93fe9bb983f885f885`
TCP frame prefix `0000001e`.

Outlet off with context,
`{"system":{"set_relay_state":{"state":0}},"context":{"child_ids":["800612345678901234567890123456789012345601"]}}`
(113 bytes, prefix `00000071`):
`d0f281f88bff9af7d5ef94b6c5a0d48bf99cf091e8b7c4b0d1a5c0e2d8a381f286e793f6d4eedea3def2d0b3dcb2c6a3dbaf8db7ccee8de58ce084dbb2d6a587bde6c4fcccfccafbc9facefbcdfac2fbcbfac8fbcffaccfbc3facafbc9facefbcdfac2fbcbfac8fbcffaccfccdefb2cfb2`

Bulb on at 50 %,
`{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"ignore_default":1,"on_off":1,"brightness":50}}}`
(118 bytes, prefix `00000076`):
`d0f281ec8dff8be78ee88da3caa5d1ff8ce180f286e491fd9fb1ddb4d3bbcfa6c8afdcb9cbbdd4b7d2f0cab193e795f49ae980f49df29cc3afc6a1c9bde291e584f095b78df6d4bddab4dba9cc93f792f495e08cf8dae0d1fddfb0de81ee88eeccf6c7ebc9abd9b0d7bfcba5c0b3c0e2d8eddda0dda0`

Decryption check: `{"system":{"get_sysinfo":{"err_code":0}}}` encrypts to
`d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08ba9ccbecc93f09ffb9ebc86b6cbb6cb`; decrypting that
must give the plaintext back. Note the shared prefix with 9.1: the cipher is a prefix-preserving stream.

### 9.3 Example `get_sysinfo` responses (demonstration values; field names are the devices')

Each is the value of `system.get_sysinfo` inside `{"system":{"get_sysinfo":{…}}}`.

Energy plug, V1 (HS110 v1):
```json
{"sw_ver":"1.0.8 Build 151113 Rel.24658","hw_ver":"1.0","type":"IOT.SMARTPLUGSWITCH","model":"HS110(US)",
 "mac":"50:C7:BF:01:02:03","deviceId":"8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A","hwId":"60FF6B258734EA6880E186F8C96DDC61",
 "fwId":"060BFEA28A8CD1E67146EB5B2B599CC8","oemId":"FFF22CFF774A0B89F7624BFC6F50D5DE","alias":"Kitchen Kettle",
 "dev_name":"Wi-Fi Smart Plug With Energy Monitoring","icon_hash":"","relay_state":1,"on_time":3600,
 "active_mode":"schedule","feature":"TIM:ENE","updating":0,"rssi":-65,"led_off":0,
 "latitude":0,"longitude":0,"err_code":0}
```
→ Outlet; On true; energy set; serial `50:C7:BF:01:02:03 8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A`.
Its `get_realtime` (V1): `{"current":0.1256,"voltage":122.05,"power":3.14,"total":51.493,"err_code":0}`.

Plain switch (HS200): same shape with `"model":"HS200(US)"`, `"feature":"TIM"`,
`"dev_name":"Wi-Fi Smart Light Switch"` → Switch (default `switchModels`), no energy.

Dimmer (HS220):
```json
{"sw_ver":"1.5.7 Build 180912 Rel.104837","hw_ver":"1.0","mic_type":"IOT.SMARTPLUGSWITCH","model":"HS220(US)",
 "mac":"50:C7:BF:0A:0B:0C","deviceId":"80069A1B2C3D4E5F60718293A4B5C6D7E8F90A1B","alias":"Hall Dimmer",
 "dev_name":"Smart Wi-Fi Dimmer","relay_state":0,"brightness":50,"on_time":0,"active_mode":"none",
 "feature":"TIM","updating":0,"rssi":-60,"led_off":0,
 "preferred_state":[{"index":0,"brightness":100},{"index":1,"brightness":75}],"err_code":0}
```
→ Lightbulb with On (false) and Brightness (50), no energy.

Six-outlet strip with energy (HS300):
```json
{"sw_ver":"1.0.6 Build 180627 Rel.081000","hw_ver":"1.0","model":"HS300(US)","mic_type":"IOT.SMARTPLUGSWITCH",
 "mac":"B0:BE:76:11:22:33","deviceId":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C","alias":"Desk Strip",
 "feature":"TIM:ENE","updating":0,"led_off":0,"rssi":-68,"child_num":6,
 "children":[
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C00","state":1,"alias":"Monitor","on_time":120,"next_action":{"type":-1}},
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C01","state":0,"alias":"Lamp","on_time":0,"next_action":{"type":-1}},
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C02","state":0,"alias":"Speakers","on_time":0,"next_action":{"type":-1}},
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C03","state":0,"alias":"Charger","on_time":0,"next_action":{"type":-1}},
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C04","state":0,"alias":"Printer","on_time":0,"next_action":{"type":-1}},
  {"id":"8006F1E2D3C4B5A69788796A5B4C3D2E1F0A9B8C05","state":0,"alias":"Router","on_time":0,"next_action":{"type":-1}}],
 "err_code":0}
```
→ six Outlet accessories (ids = the child ids), each with the energy set; no accessory for the strip
itself. Some firmware (KP303/HS107) report only the 2-digit suffix `"00"`…; the ids are then built as
`deviceId + "00"` etc. and are identical to the above. Per-outlet energy request: section 9.2 shape with
`{"emeter":{"get_realtime":{}},"context":{"child_ids":["…00"]}}`; reply V2, e.g.
`{"voltage_mv":121512,"current_ma":82,"power_mw":4380,"total_wh":1520,"slot_id":0,"err_code":0}`.

Colour bulb (LB130), on:
```json
{"sw_ver":"1.6.0 Build 170703 Rel.141938","hw_ver":"1.0","model":"LB130(US)",
 "description":"Smart Wi-Fi LED Bulb with Color Changing","alias":"Reading Lamp","mic_type":"IOT.SMARTBULB",
 "dev_state":"normal","mic_mac":"50C7BF445566","deviceId":"8012A1B2C3D4E5F60718293A4B5C6D7E8F901234",
 "oemId":"D75F9AA8F7B6F6B9D8C9B5F1A2E3C4D5","hwId":"111E35908497A05512E259BB76801E10","is_factory":false,
 "disco_ver":"1.0","ctrl_protocols":{"name":"Linkie","version":"1.0"},
 "light_state":{"on_off":1,"mode":"normal","hue":120,"saturation":80,"color_temp":0,"brightness":60},
 "is_dimmable":1,"is_color":1,"is_variable_color_temp":1,"preferred_state":[],"rssi":-55,"active_mode":"none",
 "heapsize":302452,"err_code":0}
```
→ Lightbulb with On true, Brightness 60, ColorTemperature (props 112–400; value from fallback: no
positive `color_temp`, no `dft_on_state` → 400), Hue 120, Saturation 80, Watts. Serial
`50C7BF445566 8012A1B2C3D4E5F60718293A4B5C6D7E8F901234` (bulbs report the MAC without separators).

Tunable bulb (LB120), off: same family with `"model":"LB120(US)"`, `"is_color":0`,
`"is_variable_color_temp":1`, and
`"light_state":{"on_off":0,"dft_on_state":{"mode":"normal","hue":0,"saturation":0,"color_temp":2700,"brightness":100}}`
→ props 154–370; reads: On false, Brightness 100, ColorTemperature round(1e6/2700) = 370.

Light strip (KL430), off:
```json
{"sw_ver":"1.0.9 Build 200305 Rel.090639","hw_ver":"1.0","mic_type":"IOT.SMARTBULB","model":"KL430(US)",
 "deviceId":"801222BAA511374991036875D0A280AD1D35A16F","alias":"TV Backlight",
 "description":"Kasa Smart Light Strip, Multicolor","mic_mac":"1C3BF3778899","length":16,
 "is_dimmable":1,"is_color":1,"is_variable_color_temp":1,
 "light_state":{"on_off":0,"dft_on_state":{"mode":"normal","hue":0,"saturation":0,"color_temp":9000,"brightness":100}},
 "lighting_effect_state":{"enable":0,"name":"Aurora","custom":0,"id":"xqUxDhbAhNLqulcuRMyPBmVGyTOyEMEu","brightness":63},
 "dev_state":"normal","active_mode":"none","preferred_state":[],"rssi":-58,"err_code":0}
```
→ strip (length 16): writes use `smartlife.iot.lightStrip` / `set_light_state`; HomeKit mapping as the
colour bulb; props 112–400.

### 9.4 Identity vectors (HAP-NodeJS-style UUID, see 4.2 caveat)

| Seed | SHA-1 (hex) | UUID |
|---|---|---|
| `8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A` | `e16c020be79f67af38525f712f21702cabad4934` | `e16c020b-e79f-467a-b385-25f712f21702` |
| `8006ECB1D454C4428953CB2B8D3B4A3E1A3C4C2A00` | `a629d9fb7db582f63c446c0d7fc16832b1b8ac54` | `a629d9fb-7db5-482f-a3c4-46c0d7fc1683` |
| `801222BAA511374991036875D0A280AD1D35A16F` | `025c1fe29debbb00713fb4a90b9ba02db1fd27cd` | `025c1fe2-9deb-4bb0-8713-fb4a90b9ba02` |

### 9.5 Conversion vectors

- Mired props: 2500–9000 K → 112–400; 2700–6500 K → 154–370; 2700–5000 K → 200–370; 2500–6500 K →
  154–400.
- Read 2700 K → 370 mired; 6500 K → 154; 4000 K → 250; 9000 K → 111 (rounding; below the 112 minimum —
  see Gaps item 4).
- Write 250 mired → 4000 K; 112 → 8929 K; 370 → 2703 K.
- MAC pattern `aa:bb:*` matches `AA:BB:CC:00:11:22`; `AABBCC00112?` matches it; `AABB` does not
  (anchored).
- Outlet id: deviceId `D…` (40 chars) + child `"3"` → `D…03`; child `"03"` → `D…03`; child of 42 chars →
  unchanged.

---

## 10. Gaps and hard parts

1. **TCP reassembly and close semantics.** Responses span segments; the frame is complete when the
   4-byte length is satisfied. The source half-closes after a complete frame and resolves on close; a
   replacement can resolve as soon as the frame is complete. Some devices close the connection
   themselves after replying.
2. **`devices[].port` type conflict** (3.2): the source rejects any block with a port; accept number or
   string.
3. **Pushes of OutletInUse after an energy reading:** the energy reading updates the cache that in-use
   reads, but the source pushes OutletInUse only on sysinfo updates and relay writes, so with the default
   10 s discovery it lags at most one discovery interval. A replacement may push it after readings too
   (harmless).
4. **Kelvin rounding at range ends:** reported values use round(1e6/K), which can fall just outside the
   ceil/floor props (9000 K → 111 vs min 112; the other range ends land inside). The
   source does not clamp; a replacement should clamp reported mireds into the props.
5. **VoltAmperes read path** returns voltage² in the source (4.6); use voltage × current.
6. **Bulb energy:** every bulb gets Watts and is polled every 20 s even without a meter; failures are
   logged each time. Could not determine which bulb models really answer `smartlife.iot.common.emeter`
   (the simulator answers for all).
7. **No offline status:** the source never marks accessories unreachable. Homeswift may choose to report
   "No Response" after the offline rule (3 missed rounds) without affecting ids.
8. **Coalescing helper never forgets past callers** in the source (a slow leak, behaviourally invisible).
9. **Discovery reply source port:** devices normally reply from 9999; `devicesUseDiscoveryPort` exists
   for NAT/port-forwarding setups. Manual `devices` entries with a custom port affect only discovery.
10. **Child-context firmware variants:** the plugin always sends the full 42-char child id; older
    firmware accepting only the 2-digit form was not observed in the sources. Could not determine.
11. **Light strip state:** the strip's set reply is a subset (`on_off`, `mode`, `groups`), so after a
    strip write only On is pushed until the next discovery. Strip effects (`lighting_effect_state`) and
    per-segment `groups` are ignored by the plugin.
12. **Bulb brightness 0** is forwarded as-is; real device behaviour not determinable from the sources.
13. **Sysinfo vs reply caches:** reads use the sysinfo cache, pushes come also from set replies; a read
    right after a write can return the pre-write value until the background refresh lands (it triggers
    one). A replacement may update the read cache from the write reply.
14. **KLAP / Tapo:** not supported by the sources (5.9).
15. **HAP UUID derivation** comes from HAP-NodeJS, not from these sources; check against Homeswift's own
    implementation before relying on 9.4.
16. **Parent of a multi-outlet device** with `children` present but every child unparsable: no accessory
    at all.
