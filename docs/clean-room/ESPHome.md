# ESPHome — functional specification (clean room)

Written by the spec writer; contains no source code. Everything below is a description, in the spec
writer's own words, of observable behaviour and of wire interfaces (message names, field numbers, JSON keys
and byte layouts are interfaces and are given exactly).

---

## 1. Provenance

| Source | What it contributed | Commit (`git rev-parse HEAD`) | Package / version | License | Copyright holder |
|---|---|---|---|---|---|
| https://github.com/lucavb/homebridge-esphome-ts | The Homebridge plugin: config block, entity to HomeKit mapping, identities, connection status, discovery | `20242152d5b6b79c490667c8500260e8b2e22443` (committed 2026-10-06) | npm `homebridge-esphome-ts` 1.5.3 | GPL-3.0 | Luca Becker (package author; the LICENSE file is the plain GPLv3 text with no holder line) |
| https://github.com/lucavb/esphome-ts (read in addition: it is the plugin's protocol dependency, `esphome-ts` ^5.0.0, locked at 5.0.0; the checkout is 5.1.0) | How the plugin's library connects, frames, decodes entities, builds commands, retries | `589259113275680e35462526e0d506ddb5d8f29b` (committed 2026-10-11) | npm `esphome-ts` 5.1.0 | GPL-3.0 (bundles a protobuf licence file and an MIT file for a vendored snippet) | Luca Becker |
| https://github.com/esphome/aioesphomeapi | The reference native API client: plaintext and Noise framing, handshake, `api.proto` (message ids and field numbers), keepalive, reconnect policy, mDNS service type, test vectors | `2a417c57c6b01cff7747ef7d6ee59f9e089d8c04` (committed 2026-11-02) | PyPI `aioesphomeapi` 46.25.2 | MIT | Copyright (c) 2018 Otto Winter |

Facts marked **[Noise spec]** come from the public Noise Protocol Framework specification (revision 34), not
from these sources. Facts marked **[HAP-NodeJS]** describe HAP-NodeJS behaviour that the Homebridge plugin
relies on implicitly. Facts marked **[extension]** describe behaviour the original plugin does not have; they
are the spec writer's proposals for the entity types the task requires and carry no compatibility constraint.

---

## 2. Scope of the original plugin

The Homebridge plugin exposes four ESPHome entity types: **light, switch, binary_sensor, sensor**. Covers,
fans, climates, locks, buttons and all other entity types produce no accessory (the plugin logs that the
component is not supported). Its library (esphome-ts) speaks **plaintext only** (no Noise encryption) and
authenticates with the legacy API password. Sections 6–7 specify the full protocol including Noise, because
a replacement that only spoke the original's dialect would not work with current firmware (see §11).

---

## 3. Configuration interface

Platform name (Homebridge `pluginAlias`): **`esphome`** (exact, lowercase). Plugin type: platform, singular
(one block per bridge). Plugin package name `homebridge-esphome-ts`.

### 3.1 Platform-level keys

| JSON key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Must be `"esphome"`. |
| `devices` | array of device objects (§3.2) | absent | Devices to connect to. If absent **and** `discover` is not true, an error is logged ("no devices and discovery disabled, no accessories") and the device list is treated as empty. |
| `discover` | boolean | `false` | Browse mDNS for ESPHome devices at startup (§8) and connect to every one found, in addition to `devices`. |
| `discoveryTimeout` | integer, milliseconds, ≥ 0 | `5000` | How long the mDNS browse runs. After it, no further discovered devices are taken in (the browse is stopped). |
| `retryAfter` | integer, milliseconds | `90000` | Reconnect cadence while a device is not alive (§7.6). Overridden per device. |
| `blacklist` | array of strings | `[]` | Entity **names** (the `name` field from ListEntities, exact, case-sensitive) to exclude (§5.6). |
| `debug` | boolean | `false` | Verbose logging; in the original also writes a raw-frame dump file per device (§10). |

The UI schema shown in Homebridge lists only `devices[].host`, `devices[].port`, `devices[].password`,
`debug`, `discover`, `discoveryTimeout`; `retryAfter` and `blacklist` are read although the schema does not
list them. Unknown keys are ignored.

### 3.2 Device object (each element of `devices`)

| JSON key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | — (required) | Hostname or IP address (e.g. `my_esp.local`, `192.168.1.40`). Also the key by which a device is matched to a discovered one and the value stored with each accessory (§5.5). |
| `port` | number | `6053` | TCP port of the native API. |
| `password` | string | `""` | Legacy API password. Empty string means "no password". **Secret.** |
| `retryAfter` | integer, ms | platform `retryAfter`, else 90000 | Per-device reconnect cadence; takes precedence over the platform value. |
| `encryptionKey` | string (base64 of 32 bytes) | absent | **[extension]** Not read by the original plugin (its library has no encryption). The task requires it: the device's `api: encryption: key:` value, base64 of exactly 32 bytes. When present, the connection uses Noise (§6.3); when absent, plaintext. **Secret.** A replacement should store it under this exact key so the runtime treats it as a secret-named key. |

Example of a block a user would paste unchanged (from the plugin's documentation, restated):
`{"platform":"esphome","devices":[{"host":"my_esp.local","password":"…","port":9001,"retryAfter":120000}],"retryAfter":60000,"discover":true,"discoveryTimeout":6000,"blacklist":["My blacklisted switch"],"debug":false}`.

### 3.3 Merging configured and discovered devices (when `discover` is true)

1. For each mDNS result (§8): if a configured device has `host` equal to the discovered **SRV target host
   name** (e.g. `livingroom.local`), the two are merged; configured values win over discovered ones (so a
   configured password/port applies). The configured device is marked as "seen".
2. The effective `host` of a discovered device is then replaced by its chosen IP address when one was found
   (to avoid OS-level mDNS resolution), otherwise the SRV host name is kept.
3. The discovered port is used only if it differs from 6053; otherwise the default applies.
4. After the browse ends, every configured device not "seen" is connected as configured.
5. A device discovered but not configured has no password and no key; it therefore only works if the device
   has neither.

---

## 4. Identity

### 4.1 One accessory per entity

The plugin creates **one HomeKit (bridged) accessory per ESPHome entity**, not one per device.

- Display name of the accessory: the entity's `name` field exactly as sent in its ListEntities response.
- Accessory UUID (the Homebridge identity, from which HomeKit's aid follows): **HAP-NodeJS `uuid.generate`
  of the entity name string, and nothing else** — no host, MAC, key, object_id or entity type.
- [HAP-NodeJS] `uuid.generate(s)`: take SHA-1 of the UTF-8 bytes of `s`, as 40 lowercase hex digits
  d0…d39. The UUID is `d0..d7 - d8..d11 - '4' d12..d14 - y d16..d18 - d19..d30`, where the literal `4`
  consumes no digit and `y` is the hex digit `(value(d15) AND 3) OR 8`. Digits d31–d39 are unused.
  - Vector: `"Living Room Light"` → SHA-1 `b9eb56990e4a9543251381a7d0010ba91b00c87d` → UUID
    `b9eb5699-0e4a-4954-b251-381a7d0010ba`.
  - Vector: `"Kitchen Temperature"` → SHA-1 `d7600616bc1d06c04893a304ea8e6aa1eef24892` → UUID
    `d7600616-bc1d-406c-8489-3a304ea8e6aa`.
- Consequences a drop-in must keep: renaming an entity in ESPHome creates a new accessory; the same entity
  name on two devices (common since ESPHome sends the bare entity name, e.g. "Temperature", when the device
  has a `friendly_name`) maps both entities onto **the same accessory** (the second binds onto the first's
  services; both devices' state pushes land on it). An empty `name` (entity named after the device) hashes the
  empty string. See §11.

### 4.2 Services inside an accessory, and their subtypes

| Service | Display name | Subtype |
|---|---|---|
| The entity's primary service (Switch, Lightbulb, sensor service, …) | entity name | none (constructed with an empty-string subtype; an empty subtype is treated as no subtype) |
| Light effect switches (§5.2) | `<entity name> - <effect name>` | `<effect name> Switch` (e.g. `Rainbow Switch`) |

A service is found again on a cached accessory by service UUID plus, for effect switches, subtype; it is
added only if missing.

### 4.3 AccessoryInformation

The plugin sets nothing; HAP-NodeJS defaults apply (Manufacturer `Default-Manufacturer`, Model
`Default-Model`, SerialNumber `Default-SerialNumber`, Name = display name). The device's DeviceInfoResponse
is fetched but not used. **[extension]** A replacement may fill Manufacturer (`manufacturer` or "ESPHome"),
Model (`model`), SerialNumber (MAC), FirmwareRevision (`esphome_version`); this does not affect identity.

### 4.4 Other identifiers available on the wire (for reference; not used by the original's identity)

- `key` (fixed32): per-entity number, the hash ESPHome firmware computes from the object id; stable across
  reboots for an unchanged config; used to match state responses and commands to an entity. It is unique
  per device, not globally.
- `object_id` (string): the snake_case, sanitised entity name. Newer firmware may send it **empty**; the
  reference client then computes it: take the entity name (or, if the name is empty: the sub-device name for a
  sub-device entity, else the device `friendly_name`, else — if the device name ends in `-` plus the last six
  lowercase hex digits of the MAC — the empty string, else the device name), map space to `_` and A–Z to a–z,
  then replace every character outside `a–z 0–9 _ -` with `_`.
- `unique_id`: field 4 of every ListEntities message is **reserved** (removed); the reference client builds
  one itself, version 1: `<mac lowercase no colons>-<entity type>-<object_id>`, e.g.
  `aabbccddeeff-sensor-temperature_sensor`; version 3: `<mac>/<device_id>/<entity type>/<name>`.
- MAC: DeviceInfoResponse `mac_address` (`AC:BC:32:89:0E:A9` style), also the Noise server hello and the
  mDNS TXT `mac` (§8).
- The original's library keyed entities internally by `object_id`; entities with an empty or colliding
  object_id overwrite each other there (§11).

---

## 5. Device model: entity → HomeKit

General rules for every mapped entity:

- **State pushes** from the device update characteristic values silently (they never trigger the write
  handler, so they never echo back to the device).
- **Writes** from HomeKit are fire-and-forget: the write handler returns success as soon as the command is
  queued; a failure to deliver is not reported to HomeKit. Only a synchronous failure in the handler maps to
  HAP status −70402 (service communication failure).
- **Duplicate states are dropped**: a state response identical in every field to the previous one for the
  same entity is not propagated.
- Each mapped service additionally gets **StatusActive** (§5.5).
- Unless noted, a characteristic has no read handler: HomeKit reads return the last pushed (cached) value.

### 5.1 switch (ListEntitiesSwitchResponse 17 / SwitchStateResponse 26 / SwitchCommandRequest 33)

| HomeKit | Behaviour |
|---|---|
| Service **Switch**, characteristic **On** | Read handler returns the entity's current state (`false` until a state arrives). Push: state `state` (bool). Write: if the requested value equals the current known state, nothing is sent; otherwise a SwitchCommandRequest with `key` and `state` (true/false). Truthy non-boolean values count as true. |

Switch commands are sent immediately (not serialised, §7.5). `assumed_state`, `device_class`, `icon` are not
used.

### 5.2 light (ListEntitiesLightResponse 15 / LightStateResponse 24 / LightCommandRequest 32)

Capability detection in the original uses only the **legacy** list fields `legacy_supports_brightness`
(field 5) and `legacy_supports_rgb` (field 6). Current firmware no longer sends those fields (they are
deprecated and the firmware's generator drops deprecated fields), so on current firmware the original shows
every light as **on/off only**. A replacement should derive the same two flags from
`supported_color_modes` (field 12; each enum value is a bitmask: ON_OFF 1, BRIGHTNESS 2, WHITE 4,
COLOR_TEMPERATURE 8, COLD_WARM_WHITE 16, RGB 32): *supportsBrightness* = some mode has bit 2;
*supportsRgb* = some mode has bit 32; fall back to the legacy fields when the list is empty. This adds
characteristics to the same service and does not change identity.

Color-mode enum values (`ColorMode`): UNKNOWN 0, ON_OFF 1, LEGACY_BRIGHTNESS 2, BRIGHTNESS 3, WHITE 7,
COLOR_TEMPERATURE 11, COLD_WARM_WHITE 19, RGB 35, RGB_WHITE 39, RGB_COLOR_TEMPERATURE 47,
RGB_COLD_WARM_WHITE 51.

Service **Lightbulb** (name = entity name). Characteristics by capability:

| Characteristic | Present when | Push (from LightStateResponse) | Write → command |
|---|---|---|---|
| **On** | always | `state` as bool | true → "turn on" command; false → "turn off" command (below). No dedup against current state. |
| **Brightness** | supportsRgb, or supportsBrightness | RGB lights: `brightness × 100`. Brightness-only lights: `brightness × 100` (0 if absent). | RGB lights: send the colour command with current hue/saturation and value = new brightness. Brightness-only: clamp to 0…100, divide by 100, send a "turn on" command whose `brightness` is that value. |
| **Hue** | supportsRgb | hue (0–360) computed from `red`,`green`,`blue` by the standard RGB→HSV conversion, rounded to an integer | send the colour command with hue = new value and saturation = the **last saturation HomeKit wrote in this session, or 0 if none** (quirk: changing hue first gives a white light); value = current brightness × 100 |
| **Saturation** | supportsRgb | saturation (0–100) from the same conversion, rounded | send the colour command with hue = current state's hue, saturation = new value, value = current brightness × 100; remember the value as "last saturation" |

Hue/saturation are scale-independent, so the 0…1 float channels give the same hue and saturation as 0…255
channels would.

Command contents (LightCommandRequest; all built from the latest known state at the moment of sending):

| Command | Fields set |
|---|---|
| Turn on | `key`; `has_state`=true, `state`=true; `has_brightness`=supportsBrightness, `brightness`= current state brightness or 1 if unknown; `has_rgb`=supportsRgb, `red`/`green`/`blue` = current state values or 1 if unknown; `has_white`=false, `has_color_temperature`=false, `has_effect`=false, `has_flash_length`=false, `has_transition_length`=false (a `transition_length` of 1 is present but flagged off), `has_color_mode` not set. |
| Turn off | as turn on, but `state`=false and the "unknown" fallback for brightness and channels is 0. |
| Brightness (brightness-only light) | turn on, with `brightness` = new value (0…1). |
| Colour (RGB light) | turn on, with `red`,`green`,`blue` = HSV(hue, saturation, 100 %) converted to RGB 0…255 then divided by 255 (each clamped to 0…1), and `brightness` = value / 100. |
| Effect | turn on, with `has_effect`=true, `effect` = effect name, `has_rgb`=false. Sent only if that name is in the entity's `effects` list. |

Effects: the list `effects` (field 11) normally begins with `None` (believed to be always sent by firmware;
not verified in these sources). For every effect other than `None` the accessory gets an extra **Switch**
service (§4.2) with **On**:

- Push: On = (`effect` field of the state equals this effect name).
- Write true → effect command with this name; write false → effect command with name `None` (sent only if
  `None` is in the list, otherwise nothing happens). After a successful write the **other** effect switches
  of the same light are set to false silently (radio-group behaviour).

Not mapped in the original: `color_temperature`, `min_mireds`/`max_mireds`, white channels, transitions,
flash. **[extension]** A replacement may add ColorTemperature (mireds, bounded by `min_mireds`…`max_mireds`,
HomeKit 140–500) when a mode has bit 8 or 16; it adds a characteristic and does not affect identity.

### 5.3 binary_sensor (ListEntitiesBinarySensorResponse 12 / BinarySensorStateResponse 21)

Service and characteristic chosen from `device_class` (field 5, string):

| device_class | Service | Characteristic | Value |
|---|---|---|---|
| `motion` | MotionSensor | MotionDetected | `state` bool |
| `door` | ContactSensor | ContactSensorState | `state` true (open) → 1 (CONTACT_NOT_DETECTED), false → 0 (CONTACT_DETECTED) |
| `window` | ContactSensor | ContactSensorState | same as door |
| `smoke` | SmokeSensor | SmokeDetected | true → 1 (detected), false → 0 |
| `moisture` | LeakSensor | LeakDetected | true → 1 (leak), false → 0 |

- Read handler returns the current state (`false`/0 until a state arrives); pushes on every state change.
- Any other device class, including an empty one (no device_class configured), is **not mapped**: no
  accessory is created, and a cached accessory of that name is unregistered (§5.6). The other ESPHome classes
  known to the library are: battery, cold, connectivity, garage_door, gas, heat, light, lock, moving,
  occupancy, opening, plug, power, presence, problem, safety, sound, vibration.
- `missing_state` (field 3, "no valid state yet") is not interpreted; the boolean `state` (default false) is
  used.

### 5.4 sensor (ListEntitiesSensorResponse 16 / SensorStateResponse 25)

Classification, first match wins, on `unit_of_measurement` (field 6), `icon` (field 5), `device_class`
(field 9):

| Condition | Service | Characteristic | Conversion |
|---|---|---|---|
| unit is `°C` or `°F` (the degree sign U+00B0) | TemperatureSensor | CurrentTemperature | `°F` values converted to °C: (F − 32) × 5 / 9; °C as is |
| unit is `%` and (icon is `mdi:water-percent` or device_class is `humidity`) | HumiditySensor | CurrentRelativeHumidity | as is |
| unit is `lx` or device_class is `illuminance` | LightSensor | CurrentAmbientLightLevel | clamped to 0.0001 … 100000 |
| anything else | not mapped (no accessory; cached one unregistered) | | |

- Push only (no read handler). No push while no value has been received.
- The float `state` (field 2) may be NaN when the sensor has no valid state (`missing_state`, field 3, true);
  a replacement should skip such values rather than push NaN (the original's guard only covers "no state
  received yet").
- `accuracy_decimals`, `state_class`, `force_update` are not used. Sensors with unit `K` are not mapped.

### 5.5 Connection status (StatusActive) and reachability

- Every service of a mapped accessory except AccessoryInformation gets the **StatusActive** characteristic
  (added if missing).
- StatusActive = true while the device is **alive**, false otherwise. Alive becomes true when the TCP
  connection is established or any frame arrives; it becomes false when the connection closes, or when no
  frame at all has arrived for **90 seconds**.
- The initial state is not alive (false) until the first connection; transitions are de-duplicated.
- The accessory list per device is re-evaluated on every transition, so accessories added later get the
  current state; newly added accessories are initialised with the last known state of their device (true if
  none known yet).
- Each accessory stores the device's effective `host` in its persisted context (key `host`), so accessories
  restored from cache at startup are associated with their device for status updates before the device has
  been listed again. Cached accessories without that context entry (older caches) get no status updates.
- Log lines (§10) fire only after the first successful connection: a later loss logs a warning ("values may
  be stale"), a recovery logs info ("re-established").
- Values are otherwise left as they are while offline (no "No Response" is forced).

### 5.6 Accessory lifecycle

- At startup cached accessories are restored. A cached accessory whose display name is in `blacklist` is
  unregistered (removed) immediately.
- When a device's entity list is complete (ListEntitiesDoneResponse) for the first time **within 10 seconds of
  the device being created**, every entity is processed in list order:
  1. name in `blacklist` → skipped (debug log);
  2. entity type not one of the four → "not supported" info log, skipped;
  3. accessory looked up by UUID (§4.1) among cached/known ones, else created;
  4. the mapping (§5.1–5.4) is applied; if it cannot map (binary_sensor class or sensor unit not in the
     tables) → "could not be mapped" log; a **cached** accessory of that UUID is unregistered, a new one is
     discarded;
  5. otherwise the accessory's context `host` is set, new accessories are registered, and it is associated
     with the device for status.
- If the list does not complete within 10 s, a warning "device could not be reached" is logged and
  **no accessories are added for that device in this run**, even if it connects later (cached accessories
  stay but have no handlers bound). **[extension]** A replacement should instead add accessories whenever the
  first complete list arrives.
- Entities appearing in later lists (after a reconnect) are not added until restart; existing ones are
  re-bound to the new state stream.
- Cached accessories whose entity no longer exists are **never removed** automatically (only blacklisted or
  unmappable ones are).

### 5.7 Entity types not in the original — proposed mappings **[extension]**

Each would be one accessory per entity with the same identity seed (§4.1), primary service named after the
entity, no subtype. Values come from the protocol tables in §7.4.

| ESPHome entity | HomeKit service | Characteristics and conversions |
|---|---|---|
| **cover** (13/22/30) | WindowCovering (device_class `garage` → GarageDoorOpener; `door`/`gate` could also be GarageDoorOpener) | CurrentPosition = `position` × 100 (rounded); TargetPosition: write → CoverCommandRequest `has_position`=true, `position`=value/100 (if `supports_position`; otherwise ≥ 50 → position 1.0 (open), < 50 → 0.0 (close)); PositionState from `current_operation`: IDLE → 2 (stopped), IS_OPENING → 1 (increasing), IS_CLOSING → 0 (decreasing). HoldPosition write true → `stop`=true (if `supports_stop`). Tilt (`supports_tilt`): CurrentHorizontalTiltAngle/TargetHorizontalTiltAngle −90…90 ↔ `tilt` 0…1 (tilt = (angle+90)/180). GarageDoorOpener: CurrentDoorState 0 open (position 1 or opening finished), 1 closed (position 0), 2 opening, 3 closing, 4 stopped (partial idle); TargetDoorState 0 open → position 1, 1 closed → position 0. Legacy fields (`legacy_state`, `legacy_command`) must not be relied on: firmware dropped legacy command handling in 2025.8.0. |
| **fan** (14/23/31) | Fanv2 | Active ↔ `state` (write → `has_state`, `state`); RotationSpeed 0–100 ↔ `speed_level` 1…`supported_speed_count` (speed% = level / count × 100; write: level = ceil(value/100 × count), 0 → turn off) when `supports_speed`; SwingMode ↔ `oscillating` when `supports_oscillation`; RotationDirection 0 clockwise ↔ FORWARD 0, 1 counter-clockwise ↔ REVERSE 1 when `supports_direction`. Deprecated `speed` (LOW/MEDIUM/HIGH) not used. |
| **climate** (46/47/48) | Thermostat (or HeaterCooler) | CurrentTemperature ← `current_temperature` (if feature flag SUPPORTS_CURRENT_TEMPERATURE); TargetTemperature ↔ `target_temperature` (write → `has_target_temperature`); bounds from `visual_min_temperature`/`visual_max_temperature`, step `visual_target_temperature_step`. Two-point devices (flag bit 1 or 2): CoolingThresholdTemperature ↔ `target_temperature_high`, HeatingThresholdTemperature ↔ `target_temperature_low`. TargetHeatingCoolingState: OFF 0 ↔ mode OFF 0, HEAT 1 ↔ HEAT 3, COOL 2 ↔ COOL 2, AUTO 3 ↔ HEAT_COOL 1 (or AUTO 6 if only that is in `supported_modes`); restrict valid values to the supported modes. CurrentHeatingCoolingState from `action` (if SUPPORTS_ACTION): HEATING 3 → 1, COOLING 2 → 2, others → 0; without action support derive from mode. CurrentRelativeHumidity ← `current_humidity` (flag bit 3); TargetRelativeHumidity ↔ `target_humidity` (bit 4). TemperatureDisplayUnits from `temperature_unit` (0 °C, 1 °F; values on the wire are in that unit — convert °F to °C for HomeKit; KELVIN 2 subtract 273.15). |
| **lock** (58/59/60) | LockMechanism | LockCurrentState from `state`: LOCKED 1 → 1 secured, UNLOCKED 2 → 0 unsecured, JAMMED 3 → 2 jammed, NONE 0 → 3 unknown, LOCKING 4 / UNLOCKING 5 → keep previous current state (target already reflects intent), OPENING 6 / OPEN 7 → 0 unsecured. LockTargetState: write 1 → LockCommandRequest `command`=LOCK_LOCK 1, write 0 → LOCK_UNLOCK 0. `requires_code`/`code` not implemented (Homeswift rules: a lock is written only through the security tool). |
| **button** (61/62) | StatelessProgrammableSwitch is input-only, so use **Switch** | On write true → ButtonCommandRequest with `key`; then reset On to false after a short delay (about 1 s). Never send for false. |

---

## 6. Protocol: framing

All connections are TCP to `host:port` (default 6053). TCP_NODELAY is set by the reference client. The client
always speaks first; the device never sends anything before the client's first frame.

### 6.1 Protobuf encoding (applies to every message body)

- proto3. Tag = varint of (field number × 8 + wire type). Wire types used: 0 varint (bool, uint32, int32, enum),
  2 length-delimited (string, bytes, packed repeated scalars, sub-messages), 5 fixed 32-bit little-endian
  (`fixed32`, `float` IEEE-754 single). `sint32` (only in GetTimeResponse's time-zone sub-messages) is
  zig-zag varint. A negative `int32` encodes as a 10-byte varint.
- Fields equal to their default (0, false, empty string, empty list) are normally omitted; a decoder must use
  defaults for absent fields, skip unknown fields of any wire type, and accept repeated enums both packed
  (wire type 2) and unpacked (wire type 0).
- An empty message has a zero-length body.

### 6.2 Plaintext frame

`0x00` (preamble) · varint(body length) · varint(message type id) · body.

- Varint: unsigned LEB128, 7 bits per byte, least significant group first, high bit = continuation.
  The reference client rejects a varint longer than 4 bytes and a length above 65535 as protocol errors and
  closes the connection.
- A preamble byte other than 0x00 is an error. If it is **0x01**, the device requires encryption (the device
  answered a plaintext hello with a Noise frame): report "device requires encryption, set `encryptionKey`".
- Several frames may arrive in one TCP read and one frame may span reads; reassemble.
- The original's library got this wrong: it wrote and read the length and the type as **single bytes**, which
  breaks any body ≥ 128 bytes and any type id ≥ 128 (ListEntities light responses with effects easily exceed
  127 bytes). A replacement must use real varints.

### 6.3 Noise (encrypted) frame and handshake

Protocol: **Noise_NNpsk0_25519_ChaChaPoly_SHA256**, client = initiator, prologue = the 14 bytes
`4e 6f 69 73 65 41 50 49 49 6e 69 74 00 00` (ASCII `NoiseAPIInit` followed by two zero bytes), PSK = the
base64-decoded `encryptionKey` (must decode to exactly 32 bytes; decoding is lenient — characters outside the
base64 alphabet, e.g. whitespace, are ignored; otherwise report "malformed key" without printing the key).

Every Noise-mode frame on the wire: `0x01` (preamble) · 2-byte big-endian length N · N bytes.

Handshake sequence:

1. **Client → device, in one write**: the empty "hello" frame `01 00 00`, immediately followed by the
   handshake frame `01` · len(1 + M) big-endian · `00` · M bytes of Noise message 1. Message 1 is 48 bytes
   (32-byte ephemeral public key + 16-byte tag of the encrypted empty payload), so this frame is
   `01 00 31 00` + 48 bytes.
2. **Device → client, frame 1 (server hello)**: body byte 0 = chosen protocol, must be `0x01`
   (otherwise error "unknown protocol"; an empty body is an error). Then, if present (firmware ≥ 2022.2), the
   device name as UTF-8 terminated by `0x00`, then, if present (firmware ≥ 2025.4), the MAC address string
   (e.g. `aabbccddeeff`, up to 16 characters as sanitised for display) terminated by `0x00`. A client that
   knows the expected name or MAC compares the raw bytes and aborts on mismatch.
3. **Device → client, frame 2 (handshake result)**: body byte 0:
   - `0x00`: success; the remaining bytes are Noise message 2 (48 bytes: device ephemeral key + tag of an
     empty payload). Processing it completes the handshake; an authentication failure here means a wrong key.
   - `0x01`: failure; the remaining bytes are a UTF-8 explanation. The exact text `Handshake MAC failure`
     means **invalid encryption key**; any other text is a generic handshake failure. An empty body is an error.
4. **Transport**: after the handshake the first split cipher state encrypts client→device, the second
   decrypts device→client [Noise spec]. Each message is sent as one Noise frame whose plaintext is
   `type (2 bytes BE) · body length (2 bytes BE) · body`, encrypted with ChaCha20-Poly1305, empty associated
   data, nonce = 4 zero bytes followed by the 64-bit little-endian message counter (starting at 0, separate
   counters per direction) [Noise spec]. Ciphertext = plaintext length + 16. On receive, decrypt; plaintext
   shorter than 4 bytes is an error; the inner length field is not trusted (the body is "everything after
   byte 4"). A decryption failure after the handshake is a fatal "encryption error".
5. Error indications in Noise mode: a first received byte of `0x00` means the device is in plaintext mode
   ("device uses plaintext; remove the key or enable encryption"); any other preamble is "invalid marker
   byte"; the connection being reset right after the hello means the device does not have encryption enabled.

Handshake internals [Noise spec], so an implementer can check against a generic Noise implementation:
the 36-byte protocol name is longer than 32, so h = SHA-256(name) and ck = h; h is mixed with the prologue;
message 1 tokens `psk, e` (mix-key-and-hash the PSK; write e and, because of PSK mode, mix it into the key as
well as the hash) then encrypt-and-hash an empty payload; message 2 tokens `e, ee` (read re, mix into hash and
key; mix-key DH(e, re)) then decrypt-and-hash an empty payload; then split. HKDF over HMAC-SHA-256,
X25519 DH.

**[reference]** Devices can be "provisionable" (DeviceInfoResponse field 26): they accept a Noise handshake
with the all-zeros PSK so a key can be set (NoiseEncryptionSetKeyRequest 124 / Response 125). Not needed here.

---

## 7. Protocol: messages and session

### 7.1 Message type ids (the subset this plugin needs)

| Id | Message | Direction | Body |
|---|---|---|---|
| 1 | HelloRequest | client→device | §7.2 |
| 2 | HelloResponse | device→client | §7.2 |
| 3 | AuthenticationRequest (formerly ConnectRequest) | client→device | `password` 1 string. **Deprecated: ignored by firmware ≥ 2026.1.0** |
| 4 | AuthenticationResponse (formerly ConnectResponse) | device→client | `invalid_password` 1 bool. Deprecated, as above |
| 5 | DisconnectRequest | both | `reason` 1 enum (0 UNSPECIFIED, 1 PROVISIONING_CLOSED) |
| 6 | DisconnectResponse | both | empty |
| 7 | PingRequest | both | empty |
| 8 | PingResponse | both | empty |
| 9 | DeviceInfoRequest | client→device | empty |
| 10 | DeviceInfoResponse | device→client | §7.3 |
| 11 | ListEntitiesRequest | client→device | empty |
| 12 | ListEntitiesBinarySensorResponse | device→client | §7.4 |
| 13 | ListEntitiesCoverResponse | device→client | §7.4 |
| 14 | ListEntitiesFanResponse | device→client | §7.4 |
| 15 | ListEntitiesLightResponse | device→client | §7.4 |
| 16 | ListEntitiesSensorResponse | device→client | §7.4 |
| 17 | ListEntitiesSwitchResponse | device→client | §7.4 |
| 18 | ListEntitiesTextSensorResponse | device→client | (ignored) |
| 19 | ListEntitiesDoneResponse | device→client | empty; ends the list |
| 20 | SubscribeStatesRequest | client→device | empty |
| 21 | BinarySensorStateResponse | device→client | §7.4 |
| 22 | CoverStateResponse | device→client | §7.4 |
| 23 | FanStateResponse | device→client | §7.4 |
| 24 | LightStateResponse | device→client | §7.4 |
| 25 | SensorStateResponse | device→client | §7.4 |
| 26 | SwitchStateResponse | device→client | §7.4 |
| 27 | TextSensorStateResponse | device→client | (ignored) |
| 30 | CoverCommandRequest | client→device | §7.4 |
| 31 | FanCommandRequest | client→device | §7.4 |
| 32 | LightCommandRequest | client→device | §7.4 |
| 33 | SwitchCommandRequest | client→device | §7.4 |
| 36 | GetTimeRequest | device→client | empty |
| 37 | GetTimeResponse | client→device | `epoch_seconds` 1 fixed32; `timezone` 2 string (deprecated); `parsed_timezone` 3 message |
| 46 | ListEntitiesClimateResponse | device→client | §7.4 |
| 47 | ClimateStateResponse | device→client | §7.4 |
| 48 | ClimateCommandRequest | client→device | §7.4 |
| 58 | ListEntitiesLockResponse | device→client | §7.4 |
| 59 | LockStateResponse | device→client | §7.4 |
| 60 | LockCommandRequest | client→device | §7.4 |
| 61 | ListEntitiesButtonResponse | device→client | §7.4 |
| 62 | ButtonCommandRequest | client→device | §7.4 |

Other ids exist (up to 162: logs 28/29, Home Assistant services/states 34–40, user services 41/42/131,
camera 43–45, number 49–51, select 52–54, siren 55–57, media player 63–65, Bluetooth proxy 66–93 and 145/146,
voice assistant, alarm panel 94–96, text 97–99, date/time 100–105 and 112–114, event 107/108, valve 109–111,
update 116–118, water heater 132–134, capabilities 149/150, …). Unknown ids must be ignored, not treated as
errors. Messages for entity types not handled are ignored.

### 7.2 Hello

HelloRequest: `client_info` 1 string (free text like a user agent; the original sent `esphome-ts`, the
reference client sends its caller's name), `api_version_major` 2 uint32, `api_version_minor` 3 uint32
(reference client: 1 and 19; the original sent neither, i.e. 0.0), `outgoing_connection_target` 4 bool (omit).

HelloResponse: `api_version_major` 1 uint32, `api_version_minor` 2 uint32, `server_info` 3 string (ESPHome
version string), `name` 4 string (device host name, ≤ 31 chars). A major version > 2 is incompatible: close.
The minor version gates legacy fallbacks (e.g. < 1.6 → light capabilities from legacy flags; < 1.13 → climate
features from the legacy booleans).

### 7.3 DeviceInfoResponse (id 10) fields

`uses_password` 1 bool (deprecated); `name` 2 string; `mac_address` 3 string; `esphome_version` 4 string;
`compilation_time` 5 string; `model` 6 string; `has_deep_sleep` 7 bool; `project_name` 8 string;
`project_version` 9 string; `webserver_port` 10 uint32; `legacy_bluetooth_proxy_version` 11 uint32;
`manufacturer` 12 string; `friendly_name` 13 string; `legacy_voice_assistant_version` 14 uint32;
`bluetooth_proxy_feature_flags` 15 uint32; `suggested_area` 16 string; `voice_assistant_feature_flags` 17
uint32; `bluetooth_mac_address` 18 string; `api_encryption_supported` 19 bool; `devices` 20 repeated
message DeviceInfo {`device_id` 1 uint32, `name` 2 string, `area_id` 3 uint32, `relation` 4 enum};
`areas` 21 repeated message AreaInfo {`area_id` 1 uint32, `name` 2 string}; `area` 22 AreaInfo;
`zwave_proxy_feature_flags` 23; `zwave_home_id` 24; `serial_proxies` 25 repeated message;
`api_encryption_provisionable` 26 bool; `api_outgoing_connection_supported` 27 bool.

### 7.4 Entity messages (field number, type)

Common to every ListEntities*Response: `object_id` 1 string; `key` 2 fixed32; `name` 3 string; field 4
reserved (was `unique_id`). Every *StateResponse and *CommandRequest: `key` 1 fixed32. Most also carry
`device_id` (sub-device, uint32) at the number listed; 0 = main device.

**ListEntitiesBinarySensorResponse (12)**: `device_class` 5 string; `is_status_binary_sensor` 6 bool;
`disabled_by_default` 7 bool; `icon` 8 string; `entity_category` 9 enum (0 none, 1 config, 2 diagnostic);
`device_id` 10.
**BinarySensorStateResponse (21)**: `state` 2 bool; `missing_state` 3 bool; `device_id` 4.

**ListEntitiesCoverResponse (13)**: `assumed_state` 5 bool; `supports_position` 6 bool; `supports_tilt` 7 bool;
`device_class` 8 string; `disabled_by_default` 9; `icon` 10; `entity_category` 11; `supports_stop` 12 bool;
`device_id` 13; `supports_stop_tilt` 14 bool; `supports_toggle` 15 bool.
**CoverStateResponse (22)**: `legacy_state` 2 enum (0 open, 1 closed; deprecated); `position` 3 float
(0 closed … 1 open; "closed" ⇔ position == 0); `tilt` 4 float (0…1); `current_operation` 5 enum
(0 IDLE, 1 IS_OPENING, 2 IS_CLOSING); `device_id` 6.
**CoverCommandRequest (30)**: `has_legacy_command` 2 bool and `legacy_command` 3 enum (0 open, 1 close, 2 stop)
— deprecated, send nothing; `has_position` 4 bool; `position` 5 float; `has_tilt` 6 bool; `tilt` 7 float;
`stop` 8 bool; `device_id` 9; `stop_tilt` 10 bool; `toggle` 11 bool.

**ListEntitiesFanResponse (14)**: `supports_oscillation` 5 bool; `supports_speed` 6 bool;
`supports_direction` 7 bool; `supported_speed_count` 8 int32; `disabled_by_default` 9; `icon` 10;
`entity_category` 11; `supported_preset_modes` 12 repeated string; `device_id` 13.
**FanStateResponse (23)**: `state` 2 bool; `oscillating` 3 bool; `speed` 4 enum (deprecated);
`direction` 5 enum (0 FORWARD, 1 REVERSE); `speed_level` 6 int32; `preset_mode` 7 string; `device_id` 8.
**FanCommandRequest (31)**: `has_state` 2; `state` 3; `has_speed` 4 / `speed` 5 (deprecated);
`has_oscillating` 6; `oscillating` 7; `has_direction` 8; `direction` 9; `has_speed_level` 10;
`speed_level` 11 int32; `has_preset_mode` 12; `preset_mode` 13 string; `device_id` 14.

**ListEntitiesLightResponse (15)**: `legacy_supports_brightness` 5 bool; `legacy_supports_rgb` 6 bool;
`legacy_supports_white_value` 7 bool; `legacy_supports_color_temperature` 8 bool (all four deprecated, no
longer sent by current firmware); `min_mireds` 9 float; `max_mireds` 10 float; `effects` 11 repeated string;
`supported_color_modes` 12 repeated enum ColorMode; `disabled_by_default` 13; `icon` 14; `entity_category` 15;
`device_id` 16.
Legacy flags → modes (API < 1.6): none → ON_OFF; brightness → ON_OFF|BRIGHTNESS; brightness+color temp →
+COLOR_TEMPERATURE; brightness+rgb → ON_OFF|BRIGHTNESS|RGB; brightness+rgb+white → +WHITE;
brightness+rgb+color temp → +COLOR_TEMPERATURE; all four → all bits.
**LightStateResponse (24)**: `state` 2 bool; `brightness` 3 float (0…1); `red` 4, `green` 5, `blue` 6 float
(0…1); `white` 7 float; `color_temperature` 8 float (mireds); `effect` 9 string; `color_brightness` 10 float;
`color_mode` 11 enum; `cold_white` 12 float; `warm_white` 13 float; `device_id` 14.
**LightCommandRequest (32)**: `has_state` 2 bool; `state` 3 bool; `has_brightness` 4 bool; `brightness` 5 float;
`has_rgb` 6 bool; `red` 7, `green` 8, `blue` 9 float; `has_white` 10 bool; `white` 11 float;
`has_color_temperature` 12 bool; `color_temperature` 13 float; `has_transition_length` 14 bool;
`transition_length` 15 uint32 (ms); `has_flash_length` 16 bool; `flash_length` 17 uint32 (ms);
`has_effect` 18 bool; `effect` 19 string; `has_color_brightness` 20 bool; `color_brightness` 21 float;
`has_color_mode` 22 bool; `color_mode` 23 enum; `has_cold_white` 24 bool; `cold_white` 25 float;
`has_warm_white` 26 bool; `warm_white` 27 float; `device_id` 28.

**ListEntitiesSensorResponse (16)**: `icon` 5 string; `unit_of_measurement` 6 string; `accuracy_decimals` 7
int32; `force_update` 8 bool; `device_class` 9 string; `state_class` 10 enum (0 none, 1 measurement,
2 total_increasing, 3 total, 4 measurement_angle); `legacy_last_reset_type` 11 (deprecated);
`disabled_by_default` 12; `entity_category` 13; `device_id` 14.
**SensorStateResponse (25)**: `state` 2 float; `missing_state` 3 bool; `device_id` 4.

**ListEntitiesSwitchResponse (17)**: `icon` 5 string; `assumed_state` 6 bool; `disabled_by_default` 7;
`entity_category` 8; `device_class` 9 string; `device_id` 10.
**SwitchStateResponse (26)**: `state` 2 bool; `device_id` 3; `missing_state` 4 bool.
**SwitchCommandRequest (33)**: `state` 2 bool; `device_id` 3.

**ListEntitiesClimateResponse (46)**: `supports_current_temperature` 5 bool; `supports_two_point_target_temperature`
6 bool; `supported_modes` 7 repeated enum ClimateMode; `visual_min_temperature` 8 float;
`visual_max_temperature` 9 float; `visual_target_temperature_step` 10 float; `legacy_supports_away` 11
(deprecated); `supports_action` 12 bool; `supported_fan_modes` 13 repeated enum; `supported_swing_modes` 14
repeated enum; `supported_custom_fan_modes` 15 repeated string; `supported_presets` 16 repeated enum;
`supported_custom_presets` 17 repeated string; `disabled_by_default` 18; `icon` 19; `entity_category` 20;
`visual_current_temperature_step` 21 float; `supports_current_humidity` 22 bool; `supports_target_humidity`
23 bool; `visual_min_humidity` 24 float; `visual_max_humidity` 25 float; `device_id` 26; `feature_flags` 27
uint32; `temperature_unit` 28 enum (0 °C, 1 °F, 2 K).
Feature flag bits: 1 current temperature, 2 supports two-point target, 4 requires two-point target,
8 current humidity, 16 target humidity, 32 action. For API < 1.13 build them from the booleans 5, 6 (→ bit
"requires two-point"), 22, 23, 12.
ClimateMode: 0 OFF, 1 HEAT_COOL, 2 COOL, 3 HEAT, 4 FAN_ONLY, 5 DRY, 6 AUTO. ClimateAction: 0 OFF, 2 COOLING,
3 HEATING, 4 IDLE, 5 DRYING, 6 FAN, 7 DEFROSTING. ClimateFanMode: 0 ON, 1 OFF, 2 AUTO, 3 LOW, 4 MEDIUM,
5 HIGH, 6 MIDDLE, 7 FOCUS, 8 DIFFUSE, 9 QUIET. ClimateSwingMode: 0 OFF, 1 BOTH, 2 VERTICAL, 3 HORIZONTAL.
ClimatePreset: 0 NONE, 1 HOME, 2 AWAY, 3 BOOST, 4 COMFORT, 5 ECO, 6 SLEEP, 7 ACTIVITY.
**ClimateStateResponse (47)**: `mode` 2 enum; `current_temperature` 3 float; `target_temperature` 4 float;
`target_temperature_low` 5 float; `target_temperature_high` 6 float; 7 deprecated; `action` 8 enum;
`fan_mode` 9 enum; `swing_mode` 10 enum; `custom_fan_mode` 11 string; `preset` 12 enum; `custom_preset` 13
string; `current_humidity` 14 float; `target_humidity` 15 float; `device_id` 16; `missing_state` 17 bool.
**ClimateCommandRequest (48)**: `has_mode` 2; `mode` 3; `has_target_temperature` 4; `target_temperature` 5;
`has_target_temperature_low` 6; `target_temperature_low` 7; `has_target_temperature_high` 8;
`target_temperature_high` 9; 10–11 deprecated; `has_fan_mode` 12; `fan_mode` 13; `has_swing_mode` 14;
`swing_mode` 15; `has_custom_fan_mode` 16; `custom_fan_mode` 17; `has_preset` 18; `preset` 19;
`has_custom_preset` 20; `custom_preset` 21; `has_target_humidity` 22; `target_humidity` 23 float;
`device_id` 24.

**ListEntitiesLockResponse (58)**: `icon` 5; `disabled_by_default` 6; `entity_category` 7; `assumed_state` 8
bool; `supports_open` 9 bool; `requires_code` 10 bool; `code_format` 11 string; `device_id` 12.
**LockStateResponse (59)**: `state` 2 enum (0 NONE, 1 LOCKED, 2 UNLOCKED, 3 JAMMED, 4 LOCKING, 5 UNLOCKING,
6 OPENING, 7 OPEN); `device_id` 3.
**LockCommandRequest (60)**: `command` 2 enum (0 UNLOCK, 1 LOCK, 2 OPEN); `has_code` 3 bool; `code` 4 string;
`device_id` 5.

**ListEntitiesButtonResponse (61)**: `icon` 5; `disabled_by_default` 6; `entity_category` 7; `device_class` 8
string; `device_id` 9.
**ButtonCommandRequest (62)**: `device_id` 2.

### 7.5 Connection sequence

Reference client (aioesphomeapi), which works with all current firmware:

1. Resolve the host (a `.local` name may be resolved by mDNS), TCP connect (timeout 60 s).
2. Noise mode: send hello + handshake (§6.3) and wait for completion (timeout 60 s; slow ESP8266 handshakes
   of ~30 s have been observed). Plaintext mode: ready immediately.
3. Send HelloRequest; if a password is configured, send AuthenticationRequest right after it **without
   waiting for an AuthenticationResponse**; wait only for HelloResponse (timeout 30 s). If an
   AuthenticationResponse with `invalid_password` = true arrives at any time, that is a fatal
   "invalid password" error.
4. Start the keepalive (§7.6).
5. DeviceInfoRequest → DeviceInfoResponse.
6. ListEntitiesRequest → zero or more ListEntities*Response, then ListEntitiesDoneResponse.
7. SubscribeStatesRequest (no reply) → the device then sends the current state of every entity and afterwards
   each change.

The original did the same steps in the same order (Hello → Connect/Authentication → DeviceInfo → ListEntities →
SubscribeStates) but waited for the Connect response with no timeout (see §11), and sent ListEntities and
SubscribeStates back-to-back without waiting for the Done response.

Commands may be sent any time after step 3. On every (re)connection the list is requested again; matching
entities by `key` (and the identity rule of §4.1) re-binds them.

Incoming requests to answer:
- PingRequest (7) → PingResponse (8), always, immediately.
- DisconnectRequest (5) → DisconnectResponse (6), then close; the reference client waits 5 s before
  reconnecting after such an expected disconnect (device rebooting). A reason of 1 (PROVISIONING_CLOSED) is
  logged.
- GetTimeRequest (36) → GetTimeResponse with `epoch_seconds` = current Unix time (fixed32) (optional; the
  original ignored it).

Graceful close: send DisconnectRequest and wait up to 10 s for DisconnectResponse, then close.

Command serialisation in the original: switch and cover commands are written immediately. Light commands are
serialised per light: a new one waits until the previous one has been answered by any state response for that
light, or until 30 s have passed; its contents are computed when it is actually sent, from the latest state.
Any command is held up to 5 s waiting for a connection; after that it is silently dropped (reported on an
internal error channel only).

### 7.6 Keepalive, liveness, reconnect

- **Device-side**: the firmware sends PingRequest when the link is idle and drops clients that do not answer;
  answering PingRequest is mandatory.
- **Reference client**: sends its own PingRequest every **20 s** (keepalive interval); if no message of any kind
  arrives within **90 s** (4.5 × interval) after a ping, the connection is declared dead and closed. Any
  received message cancels the pending timeout. While waiting, further pings keep being sent every 20 s
  (forcing a TCP reset if the device rebooted).
- **Original**: never pings by itself; declares "not alive" after **90 s** without any received frame and also
  sets a 90 s TCP idle timeout that destroys the socket.
- **Reconnect, original**: on a transition to disconnected it reopens immediately; after any socket error
  (refused, reset, write error) it reopens 1 s later if still disconnected; a handshake step failing for any
  reason other than a rejected password is retried after 1 s; additionally every `retryAfter` ms while not
  alive it reopens (logging "trying to reconnect"). A **rejected password** (`invalid_password`) is terminal:
  the session is closed and no further retries happen until restart; an error is logged telling the user to
  check the password.
- **Reconnect, reference client**: immediate retry after an unexpected disconnect, 5 s after an expected one;
  after failed attempts wait round(min(1.8^n, 60)) seconds with n = consecutive failures capped at 10 (15 s cap
  for deep-sleep devices); authentication or encryption errors (invalid key, invalid password, name/MAC
  mismatch) jump straight to the 60 s maximum. It also listens for the device's mDNS records and reconnects at
  once when they reappear. Optionally, if the device turned out to be plaintext while a key is configured, it
  can downgrade with a warning (identity not verifiable).
- A replacement honouring the user's config uses `retryAfter` as its retry interval (or as a cap), never retries
  faster than ~1 s, and stops retrying on an invalid password or invalid encryption key until the
  configuration changes.

---

## 8. mDNS discovery

- Service type **`_esphomelib._tcp.local.`**; instance name = the device's host name (`name`), SRV target
  `<name>.local.`, port normally 6053.
- TXT keys read by the reference client: `mac` (12 lowercase hex digits), `version` (ESPHome version),
  `platform` (e.g. ESP32, ESP8266), `board`. ESPHome firmware also publishes (from ESPHome documentation, not
  verified in these sources): `friendly_name`, `network` (wifi/ethernet/thread), `api_encryption` (the
  Noise protocol name when encryption is on), `project_name`, `project_version`, `package_import_url`.
  TXT values are peer-controlled: sanitise before logging.
- Original's choice of address per result: the first address that is IPv4 and not link-local (does not start
  with `169.254`), or any IPv6 address, in the order the browser lists them; none acceptable → keep the host
  name. Port kept only if not 6053. Each discovered device logs an info line with its service name.
- The browse runs once at startup for `discoveryTimeout` ms; devices that appear later are not picked up.

---

## 9. Behaviour summary and edge cases

- One accessory per entity, identity = hash of the entity name (§4.1); duplicate names across devices merge.
- Blacklist matches the entity name exactly; matching cached accessories are removed at startup.
- Unmappable binary sensors and sensors are skipped (cached ones removed); unsupported entity types are
  skipped without removal.
- Identical consecutive states are suppressed. Device pushes never echo commands.
- Lights: effect switches act as a radio group; "None" turns effects off; hue writes reuse the last written
  saturation (or 0).
- Writes always succeed towards HomeKit; delivery failures are silent.
- Status: StatusActive on every non-information service; false at startup until connected, false after 90 s
  without frames or on close.
- Entities with an empty `object_id` (newer firmware) collided in the original's library; a replacement must
  key entities by `key` within a device.
- Sensor NaN (missing state) must not reach a characteristic; temperatures in °F are converted; lux is clamped.
- Strings from the device (names, effect names, TXT, server hello) are peer-controlled; lengths: name ≤ 120,
  device name ≤ 31, MAC display ≤ 16/17, handshake explanation ≤ 64 (sanitised for logs).

---

## 10. Logging (paraphrased)

| Level | When | Content |
|---|---|---|
| info | startup | the platform is starting |
| error | no `devices` and discovery off | no devices configured and discovery disabled; nothing will be exposed |
| info | each mDNS result | a device was discovered, with its service name |
| info | each `retryAfter` tick while offline | trying to reconnect to the device at `<host>` |
| error | password rejected | the device at `<host>` rejected the password; check the configured password |
| debug | other device errors | an error from the device at `<host>`, with the error |
| warn | list not complete within 10 s | the device at `<host>` could not be reached |
| warn | connection lost after having been up | connection to `<host>` lost; values may be stale |
| info | connection back | connection to `<host>` re-established |
| info | per entity | `<name>` discovered and set up / `<name>` is not supported (file an issue) / `<name>` could not be mapped to HomeKit |
| debug (info when `debug`) | per entity / cache | skipped because blacklisted; is a new accessory; cached accessory added; blacklisted cached accessory removed; dump of the device's entities |
| info | `debug` on | raw data from the device is being written to `/tmp` |

With `debug`, the original appended every **received** frame to `/tmp/esphome-log-<epoch ms>-<host>.json`,
one JSON object per line with `type` (message id), `payload` (base64 body) and `time` (epoch ms). A
replacement may keep this as an opt-in trace in its own data directory instead of `/tmp`.

Secrets — never logged, never in traces: `password`, `encryptionKey` (and the decoded PSK), Noise handshake
messages, and any outgoing AuthenticationRequest (it carries the password in clear). Errors about a malformed
key report only its length. Device names, MACs and IPs are not secret.

---

## 11. Gaps, hazards and what could not be determined

1. **Password authentication is gone**: ESPHome 2026.1.0 removed it; AuthenticationRequest/Response are kept
   only as documentation and not processed. The original waited for a Connect/Authentication response with no
   timeout, so against such firmware it would stall after Hello until the 90 s idle timeout, then loop. A
   replacement must never wait for that response; `password` is useful only for older firmware.
2. **Encryption**: the original cannot talk to devices with `api: encryption:` (the ESPHome default for new
   devices). `encryptionKey` is an extension; the original's users with encrypted devices had no working setup.
3. **Framing bug in the original** (single-byte length/type): large list responses were mis-parsed, so some
   users may never have seen certain lights; a replacement that parses correctly may expose entities the
   original silently missed. Those are new accessories, not identity changes.
4. **Light capabilities**: on current firmware the original showed lights as on/off only (legacy flags no longer
   sent). Deriving capabilities from color modes adds Brightness/Hue/Saturation to existing accessories.
5. **Identity by name only**: two devices with same-named entities share one accessory; renaming changes
   identity; empty names collide. A drop-in must keep this seed to preserve existing accessories, and should
   warn on duplicate names.
6. **Accessory info** is HAP-NodeJS defaults in the original; filling it changes no ids.
7. **Noise vectors**: the sources contain no deterministic ciphertext vectors (the ephemeral key is random in
   their tests; round trips are verified against a responder built from the same PSK). Use the Noise
   project's published NNpsk0 vectors (cacophony / snow) for the handshake and a self-made responder for
   round trips.
8. Not determined from the sources: whether firmware always prefixes `effects` with `None`; the device-side
   ping interval and its client-drop timeout; the full TXT record set; how firmware picks a color mode when a
   command sets RGB without `has_color_mode`.
9. The fan/cover/climate/lock/button mappings (§5.7) are proposals with no original behaviour; lock writes
   are security-sensitive.

---

## 12. Test vectors and fixtures (data)

### 12.1 Varints (unsigned LEB128)

| Value | Bytes |
|---|---|
| 0 | `00` |
| 42 | `2a` |
| 127 | `7f` |
| 128 | `80 01` |
| 300 | `ac 02` |
| 65536 | `80 80 04` |
| 149 (DeviceCapabilitiesRequest id) | `95 01` |

### 12.2 Plaintext frames

| Frame | Bytes |
|---|---|
| empty frame, type 1 | `00 00 01` |
| PingRequest / PingResponse | `00 00 07` / `00 00 08` |
| DeviceInfoRequest | `00 00 09` |
| ListEntitiesRequest | `00 00 0b` |
| ListEntitiesDoneResponse | `00 00 13` |
| SubscribeStatesRequest | `00 00 14` |
| HelloRequest, client_info `esphome-ts` only (what the original sent) | `00 0c 01 0a 0a 65 73 70 68 6f 6d 65 2d 74 73` |
| HelloRequest, client_info `homeswift`, API 1.10 | `00 0f 01 0a 09 68 6f 6d 65 73 77 69 66 74 10 01 18 0a` |
| HelloResponse, API 1.12, server_info `2025.1.0`, name `kitchen` | `00 17 02 08 01 10 0c 1a 08 32 30 32 35 2e 31 2e 30 22 07 6b 69 74 63 68 65 6e` |
| 192-byte body of `42`s, type 1 | `00 c0 01 01` + 192 × `42` |
| 4-byte body, type 100 | `00 04 64 42 42 42 42` |
| 1-byte body, type 32768 | `00 01 80 80 02 42` |

### 12.3 Entity messages (plaintext frames)

- ListEntitiesSwitchResponse: object_id `relay`, key `0x12345678`, name `Relay` →
  `00 13 11 | 0a 05 72 65 6c 61 79 | 15 78 56 34 12 | 1a 05 52 65 6c 61 79`.
- SwitchStateResponse key `0x12345678`, state true → `00 07 1a 0d 78 56 34 12 10 01` (HomeKit: On = true).
- SwitchCommandRequest key `0x12345678`, state true → `00 07 21 0d 78 56 34 12 10 01`.
- SensorStateResponse key `0x12345678`, state 21.5 → `00 0a 19 0d 78 56 34 12 15 00 00 ac 41`.
  With unit `°F` HomeKit shows (21.5 − 32) × 5/9 ≈ −5.83 °C; with `°C`, 21.5.
- ListEntitiesLightResponse: object_id `lamp`, key `0x01020304`, name `Lamp`, effects `None`, `Rainbow`,
  supported_color_modes [RGB 35] →
  `00 23 0f | 0a 04 6c 61 6d 70 | 15 04 03 02 01 | 1a 04 4c 61 6d 70 | 5a 04 4e 6f 6e 65 | 5a 07 52 61 69 6e 62 6f 77 | 62 01 23`.
  Expected accessory: name `Lamp`, UUID from `Lamp`; Lightbulb with On, Hue, Saturation, Brightness,
  StatusActive; one Switch `Lamp - Rainbow`, subtype `Rainbow Switch`, with On and StatusActive.
- LightStateResponse key `0x01020304`, state true, brightness 0.5, red 1.0, green 0, blue 0, color_mode 35,
  effect `None` →
  `00 19 18 | 0d 04 03 02 01 | 10 01 | 1d 00 00 00 3f | 25 00 00 80 3f | 58 23 | 4a 04 4e 6f 6e 65`.
  Expected: On true, Hue 0, Saturation 100, Brightness 50, Rainbow switch Off.
- LightCommandRequest key `0x01020304`: on, brightness 0.5 (brightness-only light, minimal form) →
  `00 10 20 | 0d 04 03 02 01 | 10 01 | 18 01 | 20 01 | 2d 00 00 00 3f`.
- ListEntitiesBinarySensorResponse with `device_class` = `door` (field 5, tag `2a`) and a state of true →
  ContactSensor, ContactSensorState 1. With `device_class` absent → no accessory.

### 12.4 Noise

- Prologue: `4e 6f 69 73 65 41 50 49 49 6e 69 74 00 00`.
- PSK used by the reference tests (base64): `QRTIErOb/fcE9Ukd/5qA3RGYMn0Y+p06U58SCtOXvPc=` (32 bytes); the
  same string without the trailing `=` is rejected as malformed in those tests.
- Client's first write (random ephemeral; one recorded instance):
  `01 00 00` then `01 00 31 00 1ed7f7bb0b74085418258ed5928931bc36ade7cf06937fcff089044d4ab142643f1b2c9935bb77696f23d930836737a4`
  (48 bytes after the `00`).
- Server hello for a device named `servicetest`, no MAC: `01 00 0d 01 73 65 72 76 69 63 65 74 65 73 74 00`.
- Handshake rejection for a wrong key: `01 00 16 01` + ASCII `Handshake MAC failure`
  (`48 61 6e 64 73 68 61 6b 65 20 4d 41 43 20 66 61 69 6c 75 72 65`) → "invalid encryption key".
- A server frame starting `00` in Noise mode → "device is using plaintext".
- Encrypted PingRequest after the handshake: plaintext `00 07 00 00`, ciphertext 20 bytes, wire
  `01 00 14` + 20 bytes. Nonce for the first message in each direction: 12 zero bytes; second: `00 00 00 00 01 00 00 00 00 00 00 00`.

### 12.5 Fixtures the sources test with (described)

- Plaintext parser: frames fed whole, in one buffer with several frames, byte by byte, with oversized varints
  (5+ bytes → protocol error), length above 65535 → error, wrong preamble → error, preamble `01` →
  "requires encryption".
- Noise: handshake success in a single packet and split byte by byte; wrong-name server hello → name mismatch
  error; MAC mismatch; failure text `forced to fail` → generic handshake error; `Handshake MAC failure` →
  invalid key; empty server hello and empty handshake frame → errors; ciphertext tampered → encryption error.
- Plugin: binary sensors for each mapped class and an unmapped one; sensors for lux (including clamping
  above 100000 and below 0.0001), illuminance class, °F conversion, humidity by icon and by class, no push
  before the first value; lights RGB (four rows) and brightness-only (two rows), hue-then-saturation ordering,
  effects list `None, Strobe, Flicker` → switches for Strobe and Flicker only; switch writes deduplicated against
  current state; connection status with a device that is offline at start (no log), lost (warning), back
  (info); blacklist of cached accessories; password rejection stopping retries.
