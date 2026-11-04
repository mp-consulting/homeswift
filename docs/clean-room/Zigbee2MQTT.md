# Zigbee2MQTT plugin: functional specification

## 0. Provenance

| Item | Value |
|---|---|
| Source | https://github.com/itavero/homebridge-z2m |
| Commit read | `b2c934b1a05c58ad4f6dc17f702e106d71789ea9` (commit date 2026-11-01) |
| npm package | `homebridge-z2m`, version 1.11.2 (display name "Homebridge Zigbee2MQTT") |
| License | Apache License 2.0 (`LICENSE` is the stock Apache 2.0 text; `package.json` says `Apache-2.0`) |
| Copyright holder / author | Arno Moonen (package author; no explicit copyright line in the repository) |
| Runtime dependencies (for reference only) | `mqtt` (MQTT.js) for the broker connection, `color-convert` for HSV/RGB, `semver` for version comparison |

This document was written by the spec writer; it contains no source code. Everything here is a description, in
my own words, of the plugin's observable behaviour. Identifiers that are part of an interface (JSON keys,
MQTT topics, enum values on the wire, HAP UUIDs) are quoted as they are.

Reading method: the repository was cloned with `--depth 1` and read with `cat`/`grep`/`sed`. No package script
was run. A few numeric vectors in section 15 were recomputed with a throwaway script written by the spec writer
from the formulas in section 12, and they match the source's own test expectations.

---

## 1. What the plugin is

A Homebridge **dynamic platform** plugin that bridges an existing Zigbee2MQTT installation (Z2M) to HomeKit.
It never talks Zigbee. It connects to the same MQTT broker as Z2M, reads Z2M's device list (each device carries
an "exposes" description of its capabilities), builds one HomeKit accessory per Z2M device (and per Z2M group),
mirrors state messages into characteristics, and publishes `set`/`get` JSON messages for HomeKit writes.

- Platform name / `pluginAlias`: **`zigbee2mqtt`**
- Plugin type: **platform** (`pluginType: "platform"`), `singular: true` (only one instance is expected).
- No custom Homebridge UI page (no `homebridge-ui` directory). Only the config schema form exists.

---

## 2. Configuration interface

The block sits in `platforms` of Homebridge's `config.json`. Standard Homebridge keys (`platform`, `name`,
`_bridge`) may be present and are not used by the plugin.

```
{
  "platform": "zigbee2mqtt",
  "mqtt": { ... },                 // required
  "log": { ... },                  // optional
  "defaults": { <device options> },// optional
  "exclude_grouped_devices": false,// optional
  "experimental": [ "FLAG" ],      // optional
  "devices": [ { "id": "...", <device options> } ]  // optional
}
```

### 2.1 `mqtt` (object, required)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `base_topic` | string, non-empty, **required** | schema default `"zigbee2mqtt"` | Z2M's base topic. All topics below are `<base_topic>/...`. |
| `server` | string, non-empty, **required** | schema default `"mqtt://localhost:1883"` | Broker URL. Schemes accepted by MQTT.js: `mqtt://`, `mqtts://`, `tcp://`, `ssl://`, `tls://`, `ws://`, `wss://`. A URL may embed `user:password@`. |
| `ca` | string (file **path**) | none | Path to a PEM CA certificate; the file's contents are read at startup and used as the trusted CA. |
| `key` | string (file **path**) | none | Path to the client private key (PEM). Used only if `cert` is also set. |
| `cert` | string (file **path**) | none | Path to the client certificate (PEM). Used only if `key` is also set. |
| `user` | string | none | Username. Sent only if `password` is also set (both non-empty). |
| `password` | string | none | Password. Sent only if `user` is also set. **Secret.** |
| `client_id` | string | none (library generates a random id `mqttjs_` + 8 hex chars) | MQTT client identifier. |
| `reject_unauthorized` | boolean | schema default `false`, but only an **explicit `false`** changes behaviour | When explicitly `false`, TLS certificate verification is disabled. When absent, certificates are verified. (The UI title reads "Disable self-signed SSL certificates".) |
| `keepalive` | integer seconds | 60 (library default; schema default 60) | Applied only when truthy (0 means "use library default"). |
| `version` | integer 3, 4 or 5 | 4 | MQTT protocol level: 3 = MQTT 3.1, 4 = 3.1.1, 5 = MQTT 5. Applied only when truthy. |
| `disable_qos` | boolean | `false` | When `true`, every publish uses QoS 0 instead of the per-message QoS (section 5.3). Not a Z2M option. |

Other keys are tolerated (the object is open) and ignored.

### 2.2 `log` (object, optional)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `debug_as_info` | boolean | `false` | Every debug-level message of this plugin is emitted at info level instead. A warning saying so is logged at startup. |
| `mqtt_publish` | string, one of `debug`, `info`, `warn`, `error` | `debug` | Log level of the "publishing to topic X: payload Y" line. |

An invalid `log` block is reported as an error but does **not** invalidate the configuration.

### 2.3 Device options (used in `defaults` and in each `devices[]` entry)

| Key | Type | Where | Meaning |
|---|---|---|---|
| `id` | string, length ≥ 1 | `devices[]` only, required | Matches a device by IEEE address (`0x…`) **or** friendly name, or a group by friendly name **or** numeric group id (as a string). Matching is case-insensitive. The first entry in `devices` that matches wins. |
| `exclude` | boolean | both | `true`: the device gets no accessory (and an existing one is removed). `false` in a device entry: explicitly included, overriding `exclude_grouped_devices`. |
| `ignore_availability` | boolean | both | `true`: per-device availability from Z2M is ignored (section 10). |
| `ignore_z2m_online` | boolean | both | `true`: Z2M bridge online/offline and broker disconnects do not mark this device unreachable. |
| `excluded_keys` | array of strings | both | Exposes `property` values to drop (applies recursively, to nested features too). |
| `included_keys` | array of strings | `devices[]` (also honoured if present in `defaults`, though the schema doesn't offer it there) | Properties that are kept even if listed in `excluded_keys` (typically to override a default exclusion). |
| `excluded_endpoints` | array of strings (empty string allowed) | both | Exposes entries whose `endpoint` is in this list are dropped. `""` matches entries **without** an endpoint. |
| `values` | array of `{ "property": string (≥1 char; schema says ≥3), "include"?: [string], "exclude"?: [string] }` | both | Per-property allow/deny list for enum values (section 7.3). |
| `converters` | object, keys are converter tags | both | Per-converter options (section 2.5). |
| `experimental` | array of strings | both | Experimental feature flags for this device (section 2.6). |
| `exposes` | array of Z2M exposes entries | `devices[]` (not in the schema form; documented) | Replaces the device's (or group's) exposes from Z2M entirely. |

### 2.4 Top-level options

| Key | Type | Default | Meaning |
|---|---|---|---|
| `defaults` | object of device options (no `id`) | `{}` | Base options for every device. A `defaults.exclude` of `false` is treated as "unset" (so `exclude_grouped_devices` still applies). |
| `exclude_grouped_devices` | boolean | `false` | Devices that are a member of any Z2M group are excluded (they appear only through the group accessory), unless their effective `exclude` is explicitly `false`. |
| `experimental` | array of strings | none | Global experimental flags. |
| `devices` | array of device option objects | none | Per-device overrides. |

**Merging defaults and a device entry.** The effective options of a matched device are a shallow merge: every key
of the device entry replaces the same key of `defaults` (arrays are replaced, not concatenated). The single
exception is `converters`: when both have one, the result is a merge at tag level (device tag objects replace the
default's object for the same tag; tags present only in defaults remain). Experimental flags are normalised
(trimmed, upper-cased). A device without a matching entry uses `defaults` as is.

### 2.5 Converter options (`converters` object)

Exactly three tags exist; any other key makes the **whole configuration invalid**. Keys are matched as written
(lowercase); `"Light"` would be an unknown tag.

| Tag | Shape | Validation | Effect |
|---|---|---|---|
| `switch` | `{ "type"?: "switch" \| "outlet" }` | `type` absent, or a non-empty string whose lower-case form is `switch` or `outlet` | `type` exactly `"outlet"` (lower case) exposes Z2M `switch` features as **Outlet** services instead of **Switch**. (A value such as `"Outlet"` passes validation but is treated as switch.) |
| `occupancy` | `{ "type"?: "occupancy" \| "motion" }` | `type` absent, or exactly `occupancy` or `motion` (case-sensitive) | `motion` exposes the `occupancy` property as a Motion Sensor instead of an Occupancy Sensor (section 9.6). |
| `light` | `{ "adaptive_lighting"?: boolean \| { "enabled"?: boolean, "only_when_on"?: boolean, "transition"?: number, "min_delta"?: integer ≥ 1 }, "request_brightness"?: boolean }` | `adaptive_lighting` absent, boolean, or an object whose present fields have the listed types (`min_delta` must be a number ≥ 1). `request_brightness` is not type-checked. | See section 9.1. Defaults: Adaptive Lighting enabled, `only_when_on: true`, no `transition`, `min_delta: 1`; `request_brightness: false`. `adaptive_lighting: true` means "defaults". |

### 2.6 Experimental flags

Flags are compared after trimming and upper-casing. The only flag that has an effect is **`AVAILABILITY`**
(globally in `experimental`, or per device). Without it, the availability logic still runs and logs, but
characteristics are never put into an error state (section 10). Any flag present in the global list is logged as a
warning at startup; per-device flags are logged as a warning when the device's accessory is built.

### 2.7 Validation rules (when the configuration is rejected)

The configuration is **invalid** (the plugin logs a prominent error and does nothing at all: no MQTT
connection) when any of these holds:

1. `mqtt` missing, or `base_topic`/`server` missing, not a string, or empty.
2. `defaults` present but: `exclude`/`ignore_availability`/`ignore_z2m_online` not boolean; `excluded_keys`/
   `excluded_endpoints`/`experimental` not arrays of strings; `converters` not an object; `values` not an array of
   valid value configurations (each needs a non-empty string `property`; `include`/`exclude`, if present, must be
   string arrays); or a converter option fails section 2.5.
3. `experimental` present but not an array of strings.
4. `exclude_grouped_devices` present but not a boolean.
5. `devices` present but not an array.
6. A `devices[]` entry that is an object with a non-empty string `id` but fails the same checks as `defaults`, has
   `included_keys` that is not a string array, has `exposes` that is not an array of exposes entries, or has an
   invalid converter option.

Not fatal (skipped with a warning): a `devices[]` element that is not an object, and an element without a
non-empty string `id`.

An "exposes entry" (for `devices[].exposes`) is valid when it is an object with a non-null `type` and at least one
of: `name`, `property`, `access`, `endpoint`, `values`, both `value_on` and `value_off`, both `value_min` and
`value_max`, or an array `features`.

When the configuration is invalid, accessories restored from the cache are still rebuilt (with `defaults`
semantics = none) but never receive updates.

### 2.8 Example (as documented by the source, paraphrased)

```json
{
  "platform": "zigbee2mqtt",
  "mqtt": { "base_topic": "zigbee2mqtt", "server": "mqtt://localhost:1883" },
  "log": { "mqtt_publish": "debug", "debug_as_info": false },
  "defaults": { "excluded_keys": ["lqi"] },
  "exclude_grouped_devices": false,
  "experimental": ["AVAILABILITY"],
  "devices": [
    { "id": "0x1234567890abcdef", "exclude": true },
    { "id": "0xabcdef1234567890", "excluded_keys": ["battery"] },
    { "id": "0xabcd1234abcd1234", "excluded_endpoints": ["l2"], "converters": { "switch": { "type": "outlet" } } },
    { "id": "0x1234abcd1234abcd", "values": [ { "property": "action", "include": ["toggle", "recall_scene_*"] } ] },
    { "id": "Living room lights", "converters": { "light": { "adaptive_lighting": { "transition": 2, "min_delta": 5 } } } }
  ]
}
```

---

## 3. Identity, naming and persistence

### 3.1 Accessory identity (stable id seed)

| Kind | UUID seed string | Serial number | Topic used for commands |
|---|---|---|---|
| Device | its `ieee_address` exactly as Z2M sends it (e.g. `0x00178d0009876543`, lower-case hex as Z2M formats it) | the `ieee_address` | `ieee_address` |
| Group | `group-<id>` where `<id>` is the decimal group id (e.g. `group-5`) | `GROUP:<id>` | the group's `friendly_name` |

The Homebridge accessory UUID is HAP-NodeJS's `uuid.generate(seed)`: SHA-1 of the UTF-8 seed as 40 lower-case hex
digits `h`; the UUID string is `h[0..8] - h[8..12] - "4" + h[12..15] - v + h[16..19] - h[19..31]`, where `v` is the
hex digit `(h[15] & 0x3) | 0x8` (lower-case). Hex digit 31 onward is unused. A drop-in replacement must derive its
accessory id from the same seed (Homeswift plugins prefix ids with the platform name; the seed is what must be
stable). Vectors in section 15.1.

Renaming a device in Z2M (new `friendly_name`) keeps the IEEE address, so the accessory and its services survive.
Renaming a group keeps its id, but its command topic changes to the new name.

### 3.2 Names

Name sanitising (used for the accessory, the Name characteristic of every service, and AccessoryInformation):

1. Replace every run of characters that are **not** a Unicode letter, a Unicode number, U+2019 (right single
   quotation mark), space, `'`, `.`, `,` or `-` by a single space.
2. Collapse runs of 2+ whitespace characters into one space.
3. Strip leading characters from the set {U+2019, space, `'`, `.`, `,`, `-`}.
4. Strip trailing characters from the set {space, `'`, `.`, `,`, `-`} (U+2019 is allowed at the end).
5. An empty result means "no usable name" and the caller falls back (below).

- Accessory display name: sanitised `friendly_name`, else the UUID seed (IEEE address, or `group-<id>`).
- Service display name for a service with subtype `S`: sanitised `"<friendly_name> <S>"` (just `friendly_name`
  when there's no subtype), else the IEEE address (for groups: the group id string).
- Every non-information service has a Name characteristic. Whenever an accessory is (re)built at startup and
  whenever the friendly name changes, every service's Name is rewritten from its **subtype** with the rule above.
  So effectively Name = sanitised friendly name + space + subtype.

### 3.3 AccessoryInformation

| Characteristic | Value |
|---|---|
| Name | sanitised friendly name, else IEEE address |
| Manufacturer | `definition.vendor`, else `Zigbee2MQTT` (groups: `Zigbee2MQTT`) |
| Model | `definition.model`, else `unknown` (groups: `GROUP-<id>`) |
| SerialNumber | IEEE address, or `GROUP:<id>` |
| HardwareRevision | device's `date_code`, else `?` |
| FirmwareRevision | device's `software_build_id`, else `?` |

### 3.4 What is persisted

The accessory cache stores, per accessory, the last Z2M device entry (after option filtering, section 7) under the
accessory's context (`context.device`). At startup, each cached accessory is rebuilt from that stored entry
immediately (services, handlers, get requests) before any MQTT message arrives; cached accessories whose stored
entry is now excluded are removed. A stored entry without the modern shape (`ieee_address`, `friendly_name`,
boolean `supported`) is a pre-1.0 leftover: it is restored but stays inert until fresh device info arrives, and
an error is logged saying so.

Service identity is (service type UUID, subtype). Section 9 lists the exact subtype of every service; HomeKit
rooms and automations depend on these staying identical.

---

## 4. Device model (Z2M side)

### 4.1 Device list entry (`bridge/devices` payload element)

Fields used: `ieee_address` (string), `friendly_name` (string), `supported` (boolean), `definition` (object or
null) with `vendor` (string), `model` (string), `exposes` (array), and optional `software_build_id`, `date_code`.
Other fields (`type`, `network_address`, `disabled`, `interview_completed`, …) are ignored; notably a `disabled`
device is not skipped.

A device is turned into an accessory only if `definition` is an object with truthy `vendor`, truthy `model` and an
array `exposes`. The coordinator (definition null) and unsupported devices without a definition are skipped.

### 4.2 Exposes entry

Fields: `type` (`numeric`, `binary`, `switch`, `lock`, `enum`, `text`, `composite`, `light`, `cover`, `fan`,
`climate`, …), `name`, `property` (the JSON key in state/set/get payloads), `endpoint`, `access` (bit mask),
`unit`, `values` (enum), `value_on`, `value_off`, `value_min`, `value_max`, `value_step`, `features` (nested
entries for composite types).

`access` bits: `1` = published (appears in state messages), `2` = settable, `4` = gettable.

Terminology used below:
- **has property**: `name`, `property` and `access` are all present.
- **numeric range**: has property, `type` `numeric`, `value_min` and `value_max` present.
- **binary**: has property, `type` `binary`, `value_on` and `value_off` present.
- **enum**: has property, `type` `enum`, non-empty `values` array.

### 4.3 Group list entry (`bridge/groups` payload element)

`{ "id": <int>, "friendly_name": <string>, "members": [ { "ieee_address": <string>, "endpoint": <int> } ], ... }`.

---

## 5. Transport: MQTT

### 5.1 Connection

- Connect to `mqtt.server` with the options of 2.1. Clean session, auto-reconnect using the library defaults
  (MQTT.js: reconnect every 1000 ms, connect timeout 30 s). TLS material is read from the file paths at startup.
- After Homebridge finishes launching, subscribe to `<base_topic>/#` (QoS 0). The library re-subscribes on
  reconnect. Messages are processed only from then on.
- On `connect`: log info "connected". If this is a reconnect after a disconnect, and the last known Z2M bridge
  state is not "offline", tell every accessory that Z2M is online again (section 10). If no device list has been
  received yet, start a one-shot 120 000 ms timer; if still no device list when it fires, log an error asking to
  check that Z2M runs and is at least v1.17.0.
- On `close`: only the first close after a successful connection counts. Log an error "disconnected", and tell
  every accessory that Z2M is offline (section 10). Further closes during the reconnect loop are silent.
- Publishes while disconnected are queued by the client library and sent after reconnecting (the source has a
  connection guard that never fires).

### 5.2 Topics consumed

All topics are relative to `<base_topic>/`. A message whose topic does not start with `<base_topic>/` is ignored
(debug log).

| Relative topic | Payload | Handling |
|---|---|---|
| `bridge/devices` | JSON array of device entries | Device list, section 6.2. Unparseable JSON: error log, message dropped. |
| `bridge/groups` | JSON array of group entries | Group list, section 11. Unparseable JSON: error log, message dropped. |
| `bridge/state` | `{"state":"online"}` / `{"state":"offline"}` (Z2M ≥ 2.0) or plain `online` / `offline` | Bridge online state, section 10.3. If the payload is JSON with a string `state`, that string is used; otherwise the raw payload string. The bridge is offline iff that string is exactly `offline`; anything else (including `{"foo":1}`, `null`, `["online"]`) counts as online. |
| `bridge/info` | JSON object | Version and config check, section 6.4. |
| any other `bridge/...` | — | Ignored (e.g. `bridge/logging`, `bridge/event`, `bridge/response/...`). |
| `<id>/availability` | `{"state":"online"}` style JSON or plain `online`/`offline` | Device availability, section 10.2. `<id>` is everything before the suffix. |
| `<anything>/get`, `<anything>/set` | — | Ignored (these are commands, including the plugin's own). |
| `<id>` (anything else) | JSON object of property values | Device state, section 6.3. `<id>` is the whole remainder of the topic, so friendly names containing `/` work. Endpoint sub-topics like `<name>/l1` do not match any accessory and are ignored. |

Matching `<id>` to an accessory: exact, **case-sensitive** equality with the accessory's stored `ieee_address`
(for groups, the group id as a string) or its stored `friendly_name`. Unmatched topics produce a debug log.

Any exception while processing a message is caught; an error is logged naming the topic (with a hint to check the
MQTT version) plus the error text.

### 5.3 Topics published

| Topic | Payload | QoS | Retain | When |
|---|---|---|---|---|
| `<base>/<cmdTopic>/set` | JSON object, all pending writes for that accessory merged | 2 (0 if `disable_qos`) | false | After HomeKit writes (section 6.5). |
| `<base>/<cmdTopic>/get` | JSON object `{ "<property>": 0, ... }` for every pending key | 1 (0 if `disable_qos`) | false | Initial refresh, periodic refresh, cover polling. |

`<cmdTopic>` is the IEEE address for devices (stable even when the friendly name changes) and the group's
friendly name for groups. Each publish is logged at the `log.mqtt_publish` level with topic and payload.

---

## 6. Behaviour

### 6.1 Startup

1. Validate the configuration (2.7). If invalid: log and stop.
2. Apply `log.debug_as_info`, normalise global experimental flags, compute the base device options (`defaults`,
   with `exclude: false` turned into "unset"), log the effective defaults at debug.
3. Connect to MQTT (5.1).
4. Homebridge hands back each cached accessory: if it is excluded under the current options it is removed
   (warning logged with friendly name and IEEE address), otherwise it is rebuilt from its stored device entry
   (info log "restoring accessory") and an initial `get` is queued (6.6).
5. After launch: subscribe and process messages.

### 6.2 Device list (`bridge/devices`)

- Remember the list. If `exclude_grouped_devices` is `true` and no group list has been received yet, defer the
  device processing until the first group list arrives (that group message then processes both). Otherwise
  process immediately. If a group list arrived earlier while no device list existed, process the groups too now.
- Processing a device list: mark "devices received", then for each entry (in list order) create or update its
  accessory:
  - Skip entries without a valid definition (4.1) or that are excluded (6.7).
  - UUID from the seed (3.1). If an accessory with that UUID exists: update its device information (6.8) and
    re-evaluate whether availability is enabled for it (10.1). Otherwise create a new accessory (display name per
    3.2), store the entry, register it, build services, enable/disable availability (10.1), and queue the initial
    get. Log info "new accessory: <friendly name> (<display name>)".
- After processing devices and/or groups, remove stale accessories: every accessory whose IEEE address is not in
  the last device list **and** whose group id is not in the last group list, or which is now excluded, is
  unregistered (debug log per accessory).
  - Consequence to preserve or consciously improve: if `bridge/devices` is processed while no group list has been
    received (and `exclude_grouped_devices` is false), cached group accessories are removed and come back as new
    accessories when the group list arrives. An empty device list removes all device accessories.

### 6.3 State messages (`<base>/<id>`)

1. Empty payload: ignored (debug).
2. Find the accessory (5.2). None: debug "unhandled".
3. Parse JSON (parse error: error log with the payload). Restart the accessory's 4-hour refresh timer (6.6).
4. Remove every top-level key whose value is `null`.
5. Give the object to every service handler of the accessory, in creation order (section 9). Each handler reads
   only the keys it knows; unknown keys are ignored. Keys absent from a message leave the characteristic as is.
6. Debug log "handled device update for <topic>: <payload>".

Common rules for characteristic updates from state:
- **Passthrough**: the JSON value is written as is.
- **Mapping**: the JSON value is looked up in a table (strict equality, so `true` ≠ `"true"`); unmapped values are
  ignored (no update).
- **Linear scale** (input range `[a,b]` → output `[c,d]`, where `[c,d]` defaults to the characteristic's own
  min/max): input ≤ a → c; input ≥ b → d; else `c + (input−a)/(b−a)·(d−c)`. No rounding at this step (HAP's integer
  formats round; brightness: see 9.1). Construction fails when a = b.
- **Threshold**: one HAP value when a predicate on the JSON value holds, another otherwise.
- **Range growth**: before writing a numeric value, if it is below the characteristic's current `minValue`,
  `minValue` is lowered to it (warning logged naming the characteristic, old and new minimum); if above `maxValue`,
  `maxValue` is raised to it (warning). So out-of-range device values are never clamped away.

### 6.4 `bridge/info`

- If the JSON has `version`: when it differs from the last one seen, log info "using Zigbee2MQTT v<version>
  (identified via <topic>)". Strip a trailing `-dev`, compare as semver with `1.17.0`; if lower, log a loud error
  that Z2M must be updated and the plugin might not work. (An unparseable version raises an error caught by the
  message handler.) Without `version`: error "no version found".
- If the JSON has `config`: if `config.experimental.output` is defined and does not contain the substring `json`,
  log an error that Z2M must output JSON; otherwise debug. Then run the availability configuration step (10.1).

### 6.5 HomeKit writes → `set`

Each handler turns a characteristic write into a partial JSON object (`{ "<property>": value }`, possibly nested
for colours). Writes are coalesced per accessory: all partial objects produced while handling the same
event-loop turn (in Homeswift terms: one HAP write request, which can carry several characteristics, e.g. On +
Brightness, or Hue + Saturation) are shallow-merged (later keys win) and published as one `set` message right
after. Write callbacks report success immediately (they do not wait for the device), except the explicit errors
listed in section 9.

### 6.6 `get` requests and refresh

- Every handler declares "gettable keys": the properties it uses whose exposes entry has the GET bit, with the
  exceptions noted per handler.
- When an accessory is built (startup restore or new device), all gettable keys of all handlers are queued once.
- A 4-hour (14 400 000 ms) repeating timer queues all gettable keys again. The timer is (re)started by every state
  message for that accessory, so it only fires after 4 hours of silence, then every 4 hours. It is not started
  before the first state message.
- Queued keys are coalesced per accessory within the same turn into one `get` message (`{key: 0, ...}`); duplicates
  collapse. Nothing is published when there are no keys.

### 6.7 Exclusion

A device (or group) is excluded when, in order:
1. its effective `exclude` is `true` → excluded (debug log);
2. its effective `exclude` is `false` (explicitly, in its device entry) → included;
3. `exclude_grouped_devices` is `true` and its IEEE address is a member of any group in the last group list →
   excluded (debug log naming the group);
4. otherwise included.

### 6.8 Updating an existing accessory's device information

1. If the device's effective options contain a non-empty `exposes` (only possible with a matching `devices[]`
   entry), it replaces the definition's exposes.
2. Filter the exposes (section 7).
3. If the new entry differs from the stored one (or on the initial build): compare friendly name, IEEE address,
   `supported`, `software_build_id`, `date_code`, and definition (both null, or same model, vendor and an equal
   exposes collection, order-insensitive): store it; if the definition is invalid, log an error "no device
   definition"; else refresh AccessoryInformation and run every converter (section 9) to create any missing
   services/handlers. Then remove "stale" services (any service on the accessory whose (UUID, subtype) was never
   produced during this process's lifetime; AccessoryInformation counts as produced). If the friendly name
   changed (or initial build), rewrite all service names (3.2).
4. Persist the accessory.

Handlers are only ever added, never removed during a run; a service that stops being produced is removed only
after a restart.

---

## 7. Exposes filtering (per device, before building services)

### 7.1 Endpoint inheritance

Nested `features` without their own `endpoint` take the endpoint of their parent entry (recursively).

### 7.2 Key and endpoint exclusion

Applied to each top-level entry and, recursively, to each entry of `features` (the check on a feature happens on
its own `endpoint` field as written, before it inherits its parent's endpoint):
- Excluded if its `property` is in `excluded_keys` and not in `included_keys` (entries without a property are
  never excluded by key).
- Excluded if `excluded_endpoints` is non-empty and contains the entry's `endpoint` (an absent endpoint is compared
  as `""`).

### 7.3 Value filtering

For every entry (recursively) that has a non-empty `values` array and a `property`, keep only the values allowed
by the first `values` configuration whose `property` equals the entry's property:
- If `include` is non-empty, a value must match at least one include pattern.
- If `exclude` is non-empty, a value must match no exclude pattern.

Pattern match: an empty pattern never matches. A pattern of length ≥ 2 starting with `*` matches values ending with
the rest; else a pattern of length ≥ 2 ending with `*` matches values starting with the rest; otherwise exact
equality (a lone `*` matches only the literal `*`).

---

## 8. Building services: general rules

The converters run in this fixed order for every device: Light, Switch, Cover, Lock, Basic sensors, Air quality,
Electrical, Stateless programmable switch (action), Thermostat, Battery. An exception inside one converter is
logged as an error and the others still run. Most converters also catch a failure to build a single service and
log a warning naming the accessory and the expose JSON.

- No service is marked primary, and no linked services are used.
- A service is reused if the accessory already has one with the same (UUID, subtype) (cache), otherwise added.
- Each handler has a unique identifier (service UUID plus endpoint and sometimes a kind prefix); a converter does
  not create a second handler with the same identifier. Identifiers are internal; HAP identity is (UUID, subtype).
- "Copy range from exposes" (used by several sensors): only when the entry is a numeric range. First the current
  value is brought into range (if it has no value: `round((min+max)/2)`; below min: min; above max: max), then
  `minValue = value_min`, `maxValue = value_max`, `minStep = value_step` or **1** when absent.
- "Restrict to valid values" (thermostat states): if the current value is not in the list, set it to the first
  listed value; then `minValue`/`maxValue` = min/max of the list and `validValues` = the list.
- "Single value" (heat-only thermostat, display units): value, `minValue`, `maxValue` and `validValues` all set to
  that one value, then the value is pushed.
- "Main characteristics" per handler are the ones put into an error state when the device is unreachable
  (section 10); they are listed per service below.

---

## 9. Converters (device kinds)

### 9.1 Light → Lightbulb

**Trigger:** a top-level entry with `type: "light"` and `features`, containing a feature named `state` that is
binary, published and settable.

**Service:** `Lightbulb`, subtype = the light entry's `endpoint` (none when absent). One per endpoint.

**Features used** (searched among the light's features that "have property", except colour composites):

| Feature | Requirement | Characteristic |
|---|---|---|
| `state` | binary, published, settable | `On` (main). `value_on` → true, `value_off` → false; other values (e.g. `TOGGLE`) ignored. |
| `brightness` | numeric range, published, settable | `Brightness` (main). Linear scale `[value_min, value_max]` → `[0, 100]`; a result strictly between 0 and 1 becomes 1. |
| `color_hs` (preferred) or `color_xy` | a feature of type `composite` with that `name`, a `property` (normally `color`), and numeric sub-features `hue`+`saturation` (for hs) or `x`+`y` (for xy), each with name, property and access | `Hue` + `Saturation` |
| `color_temp` | numeric range, published, settable | `ColorTemperature` with range copied from exposes (8). |

**State → HomeKit:**
- If the message contains `color_mode`:
  - Adaptive Lighting check (below) first.
  - If `color_mode` is not `color_temp`, the colour-temperature key is ignored for this message.
  - If `color_mode` is `color_temp`, the colour composite key (e.g. `color`) is ignored for this message.
- Update order: On, Brightness, colour, ColorTemperature, then colour-from-temperature.
- Colour (hs): `color.hue` → Hue, `color.saturation` → Saturation (passthrough; Z2M uses 0–360 and 0–100).
- Colour (xy): when both `color.x` and `color.y` are present, convert with XY→HS (12.2) and update Hue and
  Saturation.
- Colour temperature: `color_temp` passthrough (mired).
- Colour from temperature: only if the light has both colour and colour temperature, the message has `color_temp`
  **and** `color_mode` equal to `color_temp`: convert mired → XY → HS (12.3) and update Hue and Saturation.

**HomeKit → set:**
- On: `{ <state property>: value_on | value_off }`.
- Brightness: non-number → error callback ("non-numeric brightness"), warning logged. v ≤ 0 → `value_min`;
  v ≥ 100 → `value_max`; else `round(value_min + v/100·(value_max − value_min))`.
- Hue and Saturation: each write caches its value and sets a "received" flag. Only when both flags are set is
  anything published (then both flags reset). If Adaptive Lighting is active, it is disabled first. hs lights:
  `{ <color property>: { <hue property>: H, <saturation property>: S } }`. xy lights:
  `{ <color property>: { <x property>: x, <y property>: y } }` with HS→XY (12.1). If the light has no colour,
  error callback "color not supported".
- ColorTemperature: clamp to `[value_min, value_max]`, then apply the Adaptive Lighting gate (below); if allowed,
  `{ <color_temp property>: mired }`. Non-number → error callback.

**Adaptive Lighting** (only when the light has both brightness and colour temperature):
- Enabled (default): attach HAP's Adaptive Lighting controller (automatic mode) to the Lightbulb service. When the
  controller signals it was disabled, forget the last AL temperature.
- Disabled by config: if the cached service still carries the transition characteristic
  (`SupportedCharacteristicValueTransitionConfiguration`), attach and immediately remove a controller so the cached
  AL characteristics are cleaned up (debug log). Otherwise nothing.
- Gate on every ColorTemperature write while AL is active:
  - `only_when_on` true and On is false → skip (no publish, success callback; debug log).
  - No last AL temperature yet → remember it, publish.
  - |new − last| < `min_delta` → skip (debug log with both values).
  - Otherwise: if the light is on and `transition` > 0, add `{ "transition": <seconds> }` to the same set message;
    remember new as last; publish (debug log).
  - While AL is not active, every write forgets the last AL temperature and publishes.
- Disabling from state: when a message has `color_mode` and AL is active: if `color_mode` ≠ `color_temp`, disable
  AL; else if a last AL temperature exists and the message has `color_temp` with |last − color_temp| > 10, disable
  AL (debug logs say why).
- Turning the light on or changing brightness does not reset the last AL temperature (so turning on doesn't push a
  redundant temperature).

**Gettable keys:** `state` if gettable; `brightness` only if gettable **and** `request_brightness` is true;
`color_temp` if gettable; the colour composite property (e.g. `color`) if either component is gettable.

**Errors:** a light without a usable `state` fails with a warning.

### 9.2 Switch → Switch or Outlet

**Trigger:** top-level `type: "switch"` with `features` containing `state` that is binary, published, settable.

**Service:** `Switch` (default) or `Outlet` (when `converters.switch.type` is exactly `outlet`); subtype =
`endpoint`. One per endpoint. An Outlet's required `OutletInUse` is never updated (stays at its default false).

**Characteristic:** `On` (main): `value_on` ↔ true, `value_off` ↔ false (mapping both ways, as for lights).

**Gettable keys:** `state` if gettable.

Example: a 5-gang Tuya plug (`ts0115`) has switch entries with endpoints `l1`…`l5` and properties
`state_l1`…`state_l5`: five Switch services with subtypes `l1`…`l5`, names "<name> l1" etc.

### 9.3 Cover → WindowCovering

**Trigger:** top-level `type: "cover"` with `features`.

**Features:** `position` (numeric range, published, settable); `tilt` (same); `state` (enum, settable, whose values
include `STOP`). If there is no `position` but there is `tilt`, the tilt feature is used **as the position** and
there is no tilt. Neither → warning, no service. Additionally a top-level (not nested) entry named `motor_state`
with the same endpoint, enum, published, whose values include `opening`, `closing` and `stopped`, enables
"motor-state mode".

**Service:** `WindowCovering`, subtype = `endpoint`.

**Characteristics:** CurrentPosition (main), PositionState (main), TargetPosition, plus CurrentHorizontalTiltAngle
and TargetHorizontalTiltAngle when tilt exists, plus HoldPosition when the `state` feature exists. HAP ranges are
used: positions 0–100, tilt angles −90–90 (an error is logged if Current and Target position ranges differ).

**Tilt:** state `tilt` → CurrentHorizontalTiltAngle by linear scale `[value_min, value_max]` → `[−90, 90]`. Write
TargetHorizontalTiltAngle a → `round(scale a from [−90, 90] to [value_min, value_max])` → `{ tilt: n }`.

**HoldPosition:** writing true → `{ <state property>: "STOP" }`; writing false sends nothing.

**Polling timer (4000 ms, repeating):** exists only when the position is gettable and there is no motor state. When
it fires and an update is awaited, queue a `get` for the position property.

**Internal state:** last position sent (device units, initially −1), current position (device units, initially
−1), "awaiting update", "ignore next update if equal to last sent", motor state and previous motor state, "target
set by HomeKit".

**HomeKit TargetPosition write** (value 0–100): target = linear scale to `[value_min, value_max]` (not rounded);
publish `{ position: target }`.
- Without motor state: PositionState becomes INCREASING (1) if target > current position, DECREASING (0) if lower,
  STOPPED (2) if equal (comparison in device units against the last received position).
- With motor state: TargetPosition is set to target right away and "target set by HomeKit" is remembered.
- Remember target as "last sent". If the position is gettable, set "ignore next update if equal to last sent".
- Mark "awaiting update" and (re)start the polling timer (if it exists).

**State message:**
1. Tilt update (above).
2. If the message has the motor-state key: `opening` or `closing` are stored as is; any other value is stored as
   `stopped`.
3. If the message has the position key (otherwise stop here):
   - If "ignore next" was set (it is cleared now in any case) and the position equals the last sent → ignore the
     message (debug log).
   - Clear "awaiting update". Assume stopped, unless the polling timer is running: if the position equals the
     previous current position, stop the timer (stopped); otherwise keep "moving", mark awaiting and restart the
     timer.
   - Store the position; scale to 0–100.
   - Without motor state: update CurrentPosition; if stopped, also PositionState = STOPPED and TargetPosition =
     current (debug "assume movement stopped").
   - With motor state, only when the motor state differs from the previous one: `closing` → PositionState
     DECREASING and target 0; `opening` → INCREASING and target 100; `stopped` → STOPPED, CurrentPosition = scaled
     position, target = scaled position. TargetPosition is written when stopped, or when the movement was not
     started from HomeKit. Then previous = current motor state and "target set by HomeKit" is cleared. (While the
     motor state stays the same, position values are not written at all.)

**Gettable keys:** position (if gettable), tilt (if gettable), motor state (if gettable).

### 9.4 Lock → LockMechanism

**Trigger:** top-level `type: "lock"` with features `state` (binary, published, settable; Z2M uses `LOCK` /
`UNLOCK`) and `lock_state` (enum, published). Every value of `lock_state` must be one of `locked`, `unlocked`,
`not_fully_locked`; otherwise warning, no service.

**Service:** `LockMechanism`, subtype = `endpoint`.

| Characteristic | Mapping |
|---|---|
| LockTargetState | from `state`: `value_on` → SECURED (1), `value_off` → UNSECURED (0). Write: SECURED (any non-zero) → `value_on`, UNSECURED (0) → `value_off`, published as `{ state: ... }`. |
| LockCurrentState (main) | from `lock_state`: `locked` → SECURED (1), `unlocked` → UNSECURED (0), `not_fully_locked` → JAMMED (2). |

**Gettable keys:** `state`, `lock_state` if gettable.

### 9.5 Thermostat → Thermostat

**Trigger:** top-level `type: "climate"` with features containing a setpoint (name `current_heating_setpoint` or
`occupied_heating_setpoint`, has property, published, settable; the first one in feature order is used) and
`local_temperature` (has property, published). A climate entry that has any feature named
`occupied_cooling_setpoint` is skipped entirely.

Mode/state are used only when both exist: `system_mode` (enum, published, settable) and `running_state` (enum,
published). If only one exists it is ignored (debug log).

**Service:** `Thermostat`, subtype = `endpoint`.

| Characteristic | Behaviour |
|---|---|
| CurrentTemperature (main) | passthrough of `local_temperature`; range copied from exposes when it is a numeric range (else HAP default). |
| TargetTemperature | passthrough of the setpoint; range copied when available. Write → `{ <setpoint property>: value }` unchanged. |
| CurrentHeatingCoolingState | with mode/state: `running_state` values mapped `idle` → OFF (0), `heat` → HEAT (1), `cool` → COOL (2) (only values the device lists; others like `fan_only` ignored); valid values = mapped HAP values in that order (idle, heat, cool). No mappable value → no service (warning). Without mode/state: fixed HEAT (single value). |
| TargetHeatingCoolingState | with mode/state: `system_mode` values `off` → OFF (0), `heat` → HEAT (1), `cool` → COOL (2), `auto` → AUTO (3) (`dry`, `fan_only` etc. unsupported); valid values restricted accordingly. Write → `{ system_mode: <reverse-mapped value> }` (unknown HAP value: nothing sent, success). Without mode/state: fixed HEAT; a write gets the error "changing the target state is not supported". |
| TemperatureDisplayUnits | fixed CELSIUS (0), single value. |

**Gettable keys:** local temperature, setpoint, `system_mode`, `running_state`, each if gettable.

Edge: when the mode/state mappings turn out empty, the failure happens after the Thermostat service was already
added, so the service stays on the accessory without a handler (it is not removed as stale).

### 9.6 Basic sensors

**Grouping:** all top-level entries that have a property and are published are grouped by endpoint (entries
without endpoint form one group; groups are processed in the order their endpoint first appears in the exposes
list). Within each endpoint group, "optional" entries are the
binary entries named `battery_low` or `tamper`. For each sensor kind below (in the listed order), the entries with
the kind's name (or, if none, its fallback name) and the required type are selected; for each such entry a service
is built, unless a handler with that kind's identifier for that endpoint already exists.

Every basic sensor service also gets, when present in the same endpoint group:
- `StatusLowBattery` from `battery_low`: `value_on` → LOW (1), `value_off` → NORMAL (0);
- `StatusTampered` from `tamper`: `value_on` → TAMPERED (1), `value_off` → NOT_TAMPERED (0).
Their properties join the gettable keys when gettable.

Notation: `ep` = the entry's endpoint (absent when none). "Subtype" lists the HAP service subtype.

| Order | Exposes name (type) | Service | Subtype | Characteristic and mapping |
|---|---|---|---|---|
| 1 | `humidity` (numeric) | HumiditySensor | `ep` | CurrentRelativeHumidity (main), passthrough, range copied if available. |
| 2 | `temperature` (numeric) | TemperatureSensor | `ep` | CurrentTemperature (main), passthrough; range copied if available, else −100…100. |
| 3 | `illuminance_lux`, fallback `illuminance` (numeric) | LightSensor | `ep` | CurrentAmbientLightLevel (main), passthrough; range copied if available, else only `minValue` 0. |
| 4 | `pressure` (numeric) | custom service UUID `E863F00A-079E-48FF-8F27-9C2605A29F52` (Eve weather/air pressure) | `ep` | custom characteristic "Air Pressure", UUID `E863F10F-079E-48FF-8F27-9C2605A29F52`, format uint16, perms paired-read + notify, 700…1100 step 1, initial 1013 (main); passthrough (hPa). |
| 5 | `contact` (binary) | ContactSensor | `ep` | ContactSensorState (main): `value_on` → CONTACT_NOT_DETECTED (1), `value_off` → CONTACT_DETECTED (0). (Z2M declares `value_on: false`, `value_off: true` for contact, so `contact: true` (closed) → 0.) |
| 6 | `occupancy` (binary) | OccupancySensor (default) | `ep` | OccupancyDetected (main): `value_on` → 1, `value_off` → 0. |
| 6' | `occupancy` (binary) with `converters.occupancy.type: "motion"` | MotionSensor | `"occupancy"` or `"<ep> occupancy"` | MotionDetected (main): `value_on` → true, `value_off` → false. |
| 7 | `presence` (binary) | OccupancySensor | `"presence"` or `"presence <ep>"` | OccupancyDetected: on → 1, off → 0. |
| 8 | `vibration` (binary) | MotionSensor | `"vibration"` or `"vibration <ep>"` | MotionDetected: on → true, off → false. |
| 9 | `moving` (binary) | MotionSensor | `"moving"` or `"moving <ep>"` | MotionDetected: on → true, off → false. |
| 10 | `smoke` (binary) | SmokeSensor | `ep` | SmokeDetected: on → 1 (detected), off → 0. |
| 11 | `carbon_monoxide` (binary) | CarbonMonoxideSensor | `ep` | CarbonMonoxideDetected: on → 1 (abnormal), off → 0. |
| 12 | `water_leak` (binary) | LeakSensor | `"water"` or `"<ep> water"` | LeakDetected: on → 1, off → 0. |
| 13 | `gas` (binary) | LeakSensor | `"gas"` or `"<ep> gas"` | LeakDetected: on → 1, off → 0. |
| 14 | `device_temperature` (numeric) | TemperatureSensor | `"device_temperature"` or `"<ep> device_temperature"` | CurrentTemperature (main), passthrough; range copied if available, else −100…100. |
| 15 | `co2` (numeric) | CarbonDioxideSensor | `ep` | CarbonDioxideLevel passthrough (range copied if available); CarbonDioxideDetected (main) = ABNORMAL (1) when the value ≥ 1200 ppm, else NORMAL (0). |

Note the word order: kinds whose service type is shared get a kind word; for presence/vibration/moving the word
comes **before** the endpoint (`"presence l1"`), for occupancy-as-motion, leaks and device temperature it comes
**after** (`"l1 water"`). With the naming rule (3.2), a presence sensor on a device "Hall" is named "Hall presence".

**Gettable keys:** the sensor's property plus tamper/battery_low, each if gettable.

### 9.7 Air quality → AirQualitySensor

**Trigger:** top-level entries that have a property, are published, are numeric, and are named `voc`, `pm10` or
`pm25`; grouped by endpoint. One service per endpoint.

**Service:** `AirQualitySensor`, subtype = endpoint. `AirQuality` is the main characteristic.

| Property | Characteristic (passthrough, range copied if numeric range) | Level thresholds (value ≤ threshold) |
|---|---|---|
| `voc` | VOCDensity | ≤333 EXCELLENT, ≤1000 GOOD, ≤3333 FAIR, ≤8332 INFERIOR, else POOR |
| `pm10` | PM10Density | ≤25, ≤50, ≤100, ≤300, else POOR |
| `pm25` | PM2_5Density | ≤15, ≤35, ≤55, ≤75, else POOR |

HAP AirQuality values: UNKNOWN 0, EXCELLENT 1, GOOD 2, FAIR 3, INFERIOR 4, POOR 5. Each property remembers the
level of its latest numeric value (initially UNKNOWN; a non-number gives UNKNOWN). On **every** state message the
service's AirQuality is set to the worst (numerically highest) remembered level, even if the message carried none
of these keys. No unit conversion (Z2M's `voc` is often in ppb; it is written as is).

**Gettable keys:** each property if gettable.

### 9.8 Electrical (Eve energy characteristics)

**Trigger:** top-level entries that have a property, are published, numeric, named one of the lists below; grouped
by endpoint. For each endpoint, the first name in each list that exists is used.

| Quantity | Names, in preference order |
|---|---|
| power | `power`, `active_power`, `load` |
| voltage | `voltage`, `mains_voltage`, `rms_voltage` |
| current | `current` |
| energy consumed | `energy`, `consumed_energy`, `energy_consumed` |
| energy produced | `produced_energy`, `energy_produced` |

**Consumption service** (only if power, current or consumed energy exists; voltage alone, typically battery
voltage, creates nothing): custom service UUID `00000001-0000-1777-8000-775D67EC4377`, subtype = endpoint. It
gets, for each quantity present:

| Characteristic name | UUID | Format | Range / step | Initial |
|---|---|---|---|---|
| `Consumption` (W) | `E863F10D-079E-48FF-8F27-9C2605A29F52` | float, paired-read + notify | 0…65535, step 0.1 | 0 |
| `Voltage` (V) | `E863F10A-079E-48FF-8F27-9C2605A29F52` | float | 0…500, step 0.1 | 0 |
| `Current` (A) | `E863F126-079E-48FF-8F27-9C2605A29F52` | float | 0…100, step 0.001 | 0 |
| `Total Consumption` (kWh) | `E863F10C-079E-48FF-8F27-9C2605A29F52` | float | 0…4294967295, step 0.001 | 0 |

All passthrough without unit conversion; all present ones are main characteristics. (A voltage reported in mV
would exceed 500 and raise `maxValue` by range growth.)

**Production service** (if produced energy exists): same service UUID, subtype `"produced"` or `"<ep> produced"`,
one characteristic named `Total Production` with UUID `E863F10C-079E-48FF-8F27-9C2605A29F52` (same UUID as Total
Consumption, on a different service), same format and range, passthrough, main.

**Gettable keys:** every used property, **regardless of its access bits** (the only converter that does this).

### 9.9 Action → Stateless Programmable Switches

**Trigger:** each top-level entry that is published, enum, and named `action`. Its (filtered, see 7.3) `values` are
turned into "button mappings" by the algorithm of section 13. Each valid mapping becomes one
`StatelessProgrammableSwitch` service. If the algorithm fails (conflicting values, label overflow, a value
containing `*`), no service is created for that entry and an error is logged.

For a mapping with subtype `M` (section 13) on an entry with endpoint `ep`:
- Service subtype: `M` if no endpoint; `M.ep` (dot) if both; `ep` if `M` is absent; none if both are absent.
- `ServiceLabelIndex` = the mapping's label.
- `ProgrammableSwitchEvent` (main): `validValues` = the events the mapping has, in the order SINGLE_PRESS (0),
  DOUBLE_PRESS (1), LONG_PRESS (2); `minValue`/`maxValue` = min/max of those.
- State: when the `action` property equals the mapping's single/double/long value, fire the corresponding event.
  Other values (including `""` and `release` variants) are ignored.
- No ServiceLabel service is created.
- At creation, an info log lists, per device, "Button <label> (<identifier>) [#ext<n>]:" followed by the SINGLE,
  DOUBLE and LONG values.

**Gettable keys:** `action` if gettable (normally not).

### 9.10 Battery → Battery

**Trigger:** top-level entries that have a property, are published, and are either `battery` (numeric range) or
`battery_low` (binary); grouped by endpoint. One service per endpoint.

**Service:** `Battery`, subtype = endpoint. No main characteristics (it never shows unreachable on its own).

| Characteristic | Behaviour |
|---|---|
| BatteryLevel | with `battery`: linear scale `[value_min, value_max]` → `[0, 100]`. Without `battery`: from `battery_low`, `value_on` → 0, `value_off` → 100. |
| StatusLowBattery | with `battery_low`: `value_on` → LOW (1), `value_off` → NORMAL (0). Without it: LOW when the **raw** `battery` value < 30, else NORMAL. |
| ChargingState | fixed NOT_CHARGEABLE (2), set at creation. |

**Gettable keys:** `battery`, `battery_low` if gettable.

### 9.11 Not supported

Exposes types `fan`, `text`, generic `enum` (other than `action`, `motor_state`, thermostat modes), generic
`numeric`/`binary` with other names (e.g. `linkquality`, `voltage` alone, `power_on_behavior`), and covers/climate
outside the rules above produce nothing.

---

## 10. Availability (reachability)

### 10.1 Is availability enabled for a device?

Each accessory has an "availability enabled" flag: it starts `true` unless `ignore_availability` is true, and is
set again every time the device list is processed and when Z2M's availability configuration changes (always forced
to `false` when `ignore_availability` is true). Setting it to `false` clears any error state on the main
characteristics (when the experimental flag is on).

The intended rule (from the source's helper, modelled on Z2M's own logic) applied to Z2M's configuration object:
- Globally enabled if `availability` is truthy or `advanced.availability_timeout` is truthy, **and** the pass list
  (`advanced.availability_passlist` + `advanced.availability_whitelist`) is empty.
- Per device: entries of `devices` (keyed by IEEE address, with optional `friendly_name`) with
  `availability: false` are disabled, with any other defined `availability` value are enabled. If the pass list is
  non-empty, every listed device is enabled (block lists ignored); otherwise every device in
  `advanced.availability_blocklist` + `advanced.availability_blacklist` is disabled.
- A device in the enabled list → enabled; else in the disabled list → disabled; else the global value.
- When the global value changes, every accessory is re-evaluated; otherwise only devices whose list membership
  changed (debug logs for each decision).

**Effective behaviour of the source (likely a bug, see Gaps):** the rule is applied to the whole `bridge/info`
object instead of its `config` member, so it never finds `availability`, `advanced` or `devices`; globally enabled
is therefore always false and no device lists exist. As a result, once the device list has been processed,
availability is disabled for every device, and per-device availability messages have no effect. Z2M bridge
online/offline and broker disconnects (10.3) still apply.

### 10.2 Device availability messages (`<id>/availability`)

- If the payload contains `{`, it is parsed as JSON and the device is available iff it has an `availability`
  member whose `state` is `online`. (Z2M actually sends `{"state":"online"}`, which this check reads as
  unavailable; see Gaps.) Otherwise the device is available iff the payload is exactly `online`.
- On a change of availability: debug log; if availability is enabled for the device, becoming available re-sends
  the last known value of each main characteristic as an event, becoming unavailable puts them in the error state.

### 10.3 Bridge state and broker connection

- `bridge/state`: on a change from the last known value: offline → error log "Zigbee2MQTT is OFFLINE", remember
  that it has been offline; online → info log. Only once Z2M has been seen offline during this run are accessories
  told about online/offline (so the first "online" after startup does nothing).
- Broker disconnect / reconnect: see 5.1.
- Telling an accessory "offline": unless `ignore_z2m_online`, put its main characteristics in the error state.
  "Online": unless `ignore_z2m_online`, re-send the last known values of its main characteristics.

### 10.4 Error state

Only when the `AVAILABILITY` experimental flag is enabled (globally or for the device): the error state is HAP
status −70402 (`SERVICE_COMMUNICATION_FAILURE`, "not responding") on every main characteristic; clearing it means
status success; "re-send last value" sends an event with the characteristic's current non-null value. Without the
flag, these steps only produce debug logs.

---

## 11. Groups

When a group list is processed (immediately if a device list exists, else deferred until one arrives), each group
becomes a pseudo-device entry:

- `friendly_name`: the group's name; `ieee_address`: the group id as a decimal string; `group_id`: the id;
  `supported: true`; `definition: { vendor: "Zigbee2MQTT", model: "GROUP-<id>", exposes: <computed> }`.
- Computed exposes: walk the members in order, skipping (warning) members not in the device list or without
  exposes. The first usable member gives its top-level exposes minus entries named `linkquality`; each further
  member intersects with the running result (11.1).
- If the result is empty: use the group's configured `exposes` (a matching `devices[]` entry, not excluded, with a
  non-empty `exposes`), else skip the group (debug log). If not empty: debug log the computed exposes as JSON.
- The pseudo-device then goes through the same create-or-update path as a device (exclusion by its options, UUID
  seed `group-<id>`, stale removal).
- Options for a group match its friendly name or its id (as a string), case-insensitively.

### 11.1 Exposes intersection

1. Normalise both lists: remove `endpoint` from every entry and feature (recursively); an entry that had an
   endpoint and has both property and name gets `property := name` (e.g. `state_l1` → `state`); then drop
   duplicate entries (by the equality of 11.2).
2. For each entry of the first list, find an entry of the second with the same `name`, `property` and `type`
   (absent equals absent). If found, merge:
   - Keep every non-array field whose value is identical in both.
   - numeric: `value_min` = the larger of the two mins (or the one defined if only the first lacks it); `value_max`
     = the smaller of the two maxes (same rule).
   - binary: if `value_on` or `value_off` differ, the entry is dropped.
   - enum: `values` = values of the first also in the second (first's order); none in common → dropped.
   - If both have `features`, merge features pairwise the same way (unmatched/dropped features disappear);
     otherwise no `features`.
3. The result is the list of merged entries, in the first list's order.

### 11.2 Exposes equality

Two entries are equal when `type`, `name`, `property`, `access`, `endpoint`, `value_min`, `value_max`,
`value_off`, `value_on` are identical, their `values` arrays have the same length and every value of the first is in
the second, and either neither has `features` or both have feature collections that are equal. Two collections are
equal when they have the same length and every entry of the first has an equal entry in the second.

---

## 12. Colour mathematics

`round` below is JavaScript's `Math.round` (halves round toward +∞). HSV↔RGB is the standard model (H in degrees,
S and V in percent), and every output of those two conversions is rounded to an integer.

### 12.1 HomeKit hue/saturation → CIE xy (for `color_xy` lights)

1. RGB = HSV→RGB(H, S, V = 100), integers 0–255.
2. For each channel c/255 apply gamma: if > 0.04045, ((c + 0.055)/1.055)^2.4, else c/12.92.
3. X = 0.664511·R + 0.154324·G + 0.162028·B; Y = 0.283881·R + 0.668433·G + 0.047685·B;
   Z = 0.000088·R + 0.072310·G + 0.986039·B.
4. x = X/(X+Y+Z), y = Y/(X+Y+Z), each rounded to 5 decimals as round((v + 2^−52)·10^5)/10^5.

### 12.2 CIE xy → hue/saturation

1. z = 1 − x − y; Y = 1; X = x/y; Z = z/y.
2. r = 1.656492·X − 0.354851·Y − 0.255038·Z; g = −0.707196·X + 1.655397·Y + 0.036152·Z;
   b = 0.051713·X − 0.121364·Y + 1.011530·Z.
3. If the smallest of r, g, b is negative, subtract it from all three.
4. If r is strictly greater than both g and b and r > 1, divide g and b by r and set r = 1; else the same for g
   (strictly greater than r and b, and > 1); else the same for b.
5. Inverse gamma per channel: v ≤ 0.0031308 → 12.92·v, else 1.055·v^(1/2.4) − 0.055.
6. Let m = max(r, g, b). Each channel equal to m becomes 255; others become 255·c/m.
7. RGB→HSV (rounded integers); return H and S.

### 12.3 Mired → CIE xy (deCONZ's polynomial)

Let T = 1 000 000 / mired (kelvin).

- If T < 4000: X = 57520658/T + 11790 − 15358885888/T² − 17440695910400/T³.
- Else: X = 138086835814/T² + 14590587/T + 15754 − 198301902438400/T³.
- If T < 2222: Y = 35808·X/2^16 − 18126·X³/2^48 − 22087·X²/2^32 − 3312.
- Else if T < 4000: Y = 34265·X/2^16 − 15645·X³/2^48 − 22514·X²/2^32 − 2744.
- Else: Y = 61458·X/2^16 + 50491·X³/2^48 − 96229·X²/2^32 − 6062.
- Y = 4·Y; x = X/65535; y = Y/65535; each rounded to 4 decimals (round(v·10^4)/10^4).

Then apply 12.2 to get hue/saturation.

---

## 13. Action value → button mapping algorithm

Inputs: the list of `action` enum values (strings). Output: an ordered list of mappings, each with an optional
identifier, an extension number (0 or 1), up to three values (single, double, long) and a label (ServiceLabelIndex).

**Word sets** (compared case-insensitively):
- single: `single`, `click`, `press`
- double: `double`
- long: `hold`, `long`
- triple (extension 1, used as single): `triple`, `tripple`
- quadruple (extension 1, used as double): `quadruple`
- ignored: `release`, `hold-release`

Separators: `_` and `-`.

**Mapping subtype:** if the extension is 0 or unset, the identifier (possibly absent); else
`"<identifier or empty>#ext<extension>"` (e.g. `button_1#ext1`, or `#ext1` for a bare `triple`).

**Step 1, per value V:**
1. If V contains `*`: the whole computation fails ("wildcard cannot be mapped").
2. If V as a whole (case-insensitive) is one of the word sets above other than "ignored": a mapping with no
   identifier and that value in the corresponding slot (triple/quadruple also set extension 1).
3. If V is exactly `release` or `hold-release`: an empty mapping (no identifier, no values).
4. Identifier I = V with one leading "word + separator" removed and then one trailing "separator + word" removed,
   where "word" is any word of all six sets (case-insensitive). The leading form is anchored at the start; the
   trailing form is anchored at the end and the leftmost possible match is taken (so `on-hold-release` loses
   `-hold-release`, giving `on`). Alternatives are tried in this order: `release`, `hold-release`, `single`,
   `click`, `press`, `double`, `hold`, `long`, `triple`, `tripple`, `quadruple`.
5. If I = V (nothing stripped): single press with identifier I and single value V.
6. Else, if a leading word was found and it is in a non-ignored set: put V in that word's slot (with extension for
   triple/quadruple). Else, if a trailing word was found and it is in a non-ignored set: same with that word. Else
   (e.g. `button_1_release`): a mapping with identifier I and no values.

**Step 2, merge:** group the per-value mappings by subtype. Merging fills empty slots from the other mapping; if the
same slot holds two different values, the whole computation fails.

**Step 3:** drop mappings with no values.

**Step 4, sort** (stable sort) by comparing the identifiers lower-cased and trimmed (absent = empty string):
1. Equal identifiers: lower extension first.
2. "First number" of a string = the integer value of its first run of digits, taking at most 3 digits. A string
   with a first number goes before one without. If both have one and they differ: a 0 goes after any non-zero,
   otherwise lower first. (Equal numbers: continue.)
3. Empty string first.
4. Fewer separator runs first (a run is a maximal sequence of `_`/`-`).
5. Code-unit lexicographic order.

**Step 5, labels:** over the sorted mappings, consider each identifier's first number when it is ≤ 9 (0 included):
count how often each number occurs; let `maxCount` be the largest count and `highest` the largest such number
(0 if none).
- multiplier = 1 if `maxCount` ≤ 1, else 10.
- incremental = `maxCount` > 10.
- start = 1 if incremental, else (`highest` + 1) × multiplier.

Then, in sorted order, a mapping whose first number n is in 1…9 (and not incremental) starts at n × multiplier with
an upper bound n × multiplier + multiplier − 1; any other mapping starts at `start` with bound 255. While the
candidate label is already used, increment it; reaching the bound fails the whole computation ("service label
index out of range"). Assign and mark used.

**Step 6:** keep mappings that have a label and at least one value.

Examples are in 15.4.

---

## 14. Logging (paraphrased)

| Level | Messages |
|---|---|
| error | Invalid configuration (prominent, names the plugin, says it won't work) and the specific validation failure, including the offending JSON of the entry. Disconnected from the MQTT broker. Zigbee2MQTT is offline. No devices received two minutes after connecting (check Z2M runs and is ≥ v1.17.0). Z2M too old (minimum v1.17.0). Z2M not configured to output JSON. No version in `bridge/info`. Failed to parse `bridge/devices` / `bridge/groups`. Failed to process an MQTT message (topic, MQTT version hint, error text). Failed to process a state or availability payload (payload, error). Duplicate service handler. Restoring a pre-1.0 accessory. No device definition for a device. Thermostat/cover range inconsistencies. Invalid occupancy type chosen. Action mapping failures. Failure to delete an excluded accessory. |
| warn | `debug_as_info` is active. Experimental flags enabled (global and per device). Excluded device found in the cache on startup. Device entry skipped (not an object, or missing `id`, with a hint on what to put in `id`). Failure to set up a service (accessory name, expose JSON, reason). Group member missing from the device list or without exposes. A characteristic's min/max widened because of a received value. Non-numeric brightness written. Air quality property not understood. |
| info | Connecting to the broker (logs the server URL), connected. Z2M version in use. Z2M is online. Restoring an accessory; new accessory. Button mapping table for each `action` entry. |
| debug (or info with `debug_as_info`) | Every MQTT publish (at `log.mqtt_publish` level instead). Each handled state/availability message with its payload; unhandled topics. TLS paths, keepalive, client id, reject_unauthorized=false. Effective default options and per-accessory options (JSON). Pending set/get data. Service configuration ("configuring X for Y"), stale service clean-up, service renames. Adaptive Lighting decisions. Cover decisions (ignored update, assumed stopped, motor state transitions). Availability decisions. Exclusion reasons. Group exposes computed. |

**Secrets:** `mqtt.password` (never logged by the plugin itself, but the per-accessory and defaults option dumps do
not include the `mqtt` block). The server URL is logged at info and can embed `user:password@` (mask it). The
`ca`/`key`/`cert` values are file paths (logged at debug); the key file's contents are secret. Payloads of
`set`/`get` and state messages contain no credentials.

---

## 15. Test vectors and fixtures

### 15.1 Accessory UUIDs (HAP-NodeJS `uuid.generate`, recomputed by the spec writer)

| Seed | UUID |
|---|---|
| `0x00178d0009876543` | `8f190bf1-41f8-454c-89a6-ee5b5f593f33` |
| `0x1234567890abcdef` | `93dbcb4d-645e-46f3-ada1-33a73d4dbaa1` |
| `group-5` | `c8d3e02b-0b89-43f2-a69b-4fb7fd1c569c` |

(Verify against Homeswift's existing HAP-NodeJS-compatible UUID helper if one exists.)

### 15.2 Colour (from the source's tests; also reproduced from 12.x)

| Input | Output |
|---|---|
| HS (0, 100) → xy | (0.70061, 0.2993) |
| HS (120, 100) → xy | (0.17242, 0.7468) |
| HS (240, 100) → xy | (0.1355, 0.03988) |
| HS (300, 100) → xy | (0.38547, 0.15463) |
| HS (60, 100) → xy | (0.44416, 0.51657) |
| xy (0.44416, 0.51657) → HS | (60, 100) |
| mired 343 → xy → HS | xy (0.4426, 0.4062) → HS (39, 48) |
| mired 153 / 250 / 370 / 500 → HS (spec writer's computation) | (212, 5) / (43, 26) / (39, 54) / (35, 75) |

Light state example (Hue colour lamp with `color_xy` and `color_temp`):
`{"color":{"hue":34,"saturation":77,"x":0.4435,"y":0.4062},"color_mode":"color_temp","color_temp":343,"linkquality":72}`
→ ColorTemperature 343, Hue 39, Saturation 48 (the `color` object is ignored because the mode is colour
temperature). `{"color":{"x":0.44416,"y":0.51657},"color_mode":"xy","color_temp":169}` → Hue 60, Saturation 100,
ColorTemperature untouched.

### 15.3 Brightness and positions

- Brightness exposes 0…254. State 0 → 0, 1 → 1, 2 → 1, 127 → 50, 254 → 100. HomeKit 50 → `{"brightness":127}`,
  0 → `0`, 100 → `254`. `{"state":"TOGGLE"}` changes nothing.
- hs light: HomeKit Hue 0 + Saturation 100 → `{"color":{"hue":0,"saturation":100}}`.
- Cover (IKEA KADRILJ, position gettable, no motor state): state `{"position":100}` → Current 100, PositionState
  STOPPED, Target 100. After state 50, HomeKit target 51 → `{"position":51}` and PositionState INCREASING; the next
  `{"position":51}` is ignored; target 49 → DECREASING; then states 51, 49 update CurrentPosition only (still
  moving), a repeated 49 → STOPPED and Target 49, timer stops. Setting 49 again (equal to current) → STOPPED, and
  4 s later a `get` for `position` is published.
- Cover with tilt (Insta 57008000): state `{"position":100,"tilt":100}` → tilt angle 90; tilt 50 → 0; tilt 0 →
  −90. HomeKit target tilt −90 → `{"tilt":0}`, 0 → `{"tilt":50}`, 90 → `{"tilt":100}`. HoldPosition true →
  `{"state":"STOP"}`.
- Tilt-only cover (CP180335E-01): TargetPosition 51 → `{"tilt":51}`; state `{"tilt":51}` → CurrentPosition 51.
- Motor-state cover (Bosch BMCT-SLZ): `{"position":100,"motor_state":"stopped"}` → Current 100, STOPPED, Target
  100; repeating it changes nothing; HomeKit 51 → `{"position":51}` and Target 51; `{"position":41,"motor_state":
  "closing"}` → PositionState DECREASING only; `{"position":51,"motor_state":"stopped"}` → Current 51, STOPPED,
  Target 51.
- Thermostat (Immax 07703L): `{"local_temperature":19.5}` → CurrentTemperature 19.5; HomeKit setpoint 19 →
  `{"current_heating_setpoint":19}`; running_state `idle`/`heat` → 0/1; system_mode `off`/`auto`/`heat` → 0/3/1 and
  back.
- Lock (Danalock V3): HomeKit SECURED → `{"state":"LOCK"}`, UNSECURED → `{"state":"UNLOCK"}`.

### 15.4 Action mappings (from the source's tests)

Notation: identifier / extension → label: single, double, long.

| Device and values | Result |
|---|---|
| `single, double, hold` | (none) → 1: single, double, hold |
| `off, single, double, hold` | (none) → 1: single/double/hold; `off` → 2: single `off` |
| `1_single, 1_double, 1_hold, 2_single, 2_double, 2_hold` | `1` → 1; `2` → 2 |
| `single, double, triple, quadruple, hold, release` | (none) → 1: single/double/hold; (none)#ext1 → 2: single `triple`, double `quadruple` |
| `button_1_click, button_1_hold, button_1_release, …` up to `button_4` | `button_1`…`button_4` → 1…4 (single `_click`, long `_hold`) |
| Aqara Opple 6 buttons, each `_hold, _release, _single, _double, _triple` | `button_n` → 10n (single/double/hold); `button_n#ext1` → 10n+1 (single `_triple`) |
| `on_1, off_1, brightness_move_up_1, brightness_move_down_1, brightness_stop_1` and the same with `_2` | single presses, labels: off_1 10, on_1 11, brightness_stop_1 12, brightness_move_down_1 13, brightness_move_up_1 14; off_2 20, on_2 21, brightness_stop_2 22, brightness_move_down_2 23, brightness_move_up_2 24 |
| `scene_1` … `scene_6` | single presses, labels 1…6 |
| `close, open, stop` | close 1, open 2, stop 3 |
| `up, up_hold, up_release, down_release, down, down_hold, circle_click, circle_release, circle_hold` | `circle` 1 (click, hold); `down` 2 (`down`, `down_hold`); `up` 3 (`up`, `up_hold`) |
| `on, up, down, off, on_double, on_long, off_double, off_long` | `down` 1; `off` 2 (`off`, `off_double`, `off_long`); `on` 3 (likewise); `up` 4 |
| `home, sleep, away, panic` | away 1, home 2, panic 3, sleep 4 |
| `single_left, single_right, single_both, double_…, hold_…` | `both` 1, `left` 2, `right` 3 (single/double/hold each) |
| `recall_scene_0, recall_scene_1, recall_scene_2, toggle` | recall_scene_1 1, recall_scene_2 2, recall_scene_0 3, toggle 4 |
| Hue dimmer `on-press, on-hold, on-hold-release, up-…, down-…, off-…` | `down` 1, `off` 2, `on` 3, `up` 4 (single `-press`, long `-hold`) |

Service-level example (Aqara WXKG07LM, values `single_left … hold_both`, no endpoint): three
StatelessProgrammableSwitch services with subtypes `left`, `right`, `both`; ServiceLabelIndex both 1, left 2,
right 3; each with validValues [0, 1, 2]; `{"action":"single_left"}` fires SINGLE_PRESS on `left`;
`{"action":""}` does nothing. With the `values` filter of 7.3 limiting an Opple's values to
`button_5_hold, button_5_release, button_5_triple`, `button_5` gets only LONG and `button_5#ext1` only SINGLE.

### 15.5 Name sanitising

`Living Room Light` unchanged; `Kitchen@Light!` → `Kitchen Light`; `Kitchen-Light` unchanged; `Dr. Smith, Jr`
unchanged; `Bob’s Light` unchanged; `My Device-` → `My Device`; `My Device.` → `My Device`; `My  Device` →
`My Device`; `---My Device` → `My Device`; `My Device   ` → `My Device`; Cyrillic, Chinese and Arabic names
unchanged; an emoji-only name → no name (fallback).

### 15.6 Bridge state parsing

`{"state":"online"}` → online; `{"state":"offline"}` → offline; `online` → online; `offline` → offline;
`{"foo":"bar"}`, `{"state":123}`, `["online"]`, `null` → online.

### 15.7 Availability configuration (Z2M config object)

Globally enabled: `{availability: true}`, `{availability: {active: {timeout: 10}}}`, `{availability: {passive:
{timeout: 1500}}}`, `{availability: {}}` (an empty object is truthy), `{advanced: {availability_timeout: 1}}`.
Not enabled: no `availability`, `{advanced: {availability_timeout: 0}}`, `{availability: false}`, or a non-empty
pass list.

### 15.8 Fixtures in the source repository (described, not copied)

- `test/exposes/<vendor>/<model>.json`: real Z2M exposes arrays for about 30 devices (Philips Hue colour lamp
  8718696449691, Innr RB 249 T, OSRAM AC03645 RGBW, Namron 4512700 dimmer, IKEA E1926 KADRILJ blind, E1766 open/close
  remote, E160x/E170x/E190x, Insta 57008000 blind with tilt, Current Products CP180335E-01 tilt-only blind, Bosch
  BMCT-SLZ (manual) with motor state, Danalock V3 lock, Immax 07703L TRV, Aqara contact/motion/leak/temperature/
  button/Opple/plug devices, Tuya TS0115 5-gang and TS011F plug, Heiman HS1VS-N smoke, Xiaomi JTYJ-GD-01LM gas,
  SmartThings presence/multipurpose, Aeotec ZGA003, Titan TPZRCO2HT-Z3 CO2, Oujiabao CR701-YZ, Ubisys S2). Each file is
  the `definition.exposes` array as Z2M publishes it. Useful to check service counts, subtypes and properties.
- `test/smoke/fixtures/bridge-info.json`: a Z2M 2.7.2 `bridge/info` (version, coordinator, network, `config`
  with `availability: false`, `mqtt.base_topic`).
- `test/smoke/fixtures/bridge-devices.json`: two devices: `test_light` (IEEE `0x00178d0009876543`, Router,
  model 8718696449691, exposes a `light` with `state` (ON/OFF/TOGGLE, access 7) and `brightness` 0…254 access 7)
  and `test_sensor` (model WSDCGQ12LM, temperature/humidity/battery). The smoke mock publishes, in this order,
  `bridge/state` `{"state":"online"}`, `bridge/info`, `bridge/devices`, `bridge/groups` `[]`, then
  `test_light` `{"state":"OFF","brightness":254}` and `test_sensor` `{"temperature":22.5,"humidity":45,"battery":95}`,
  and checks that the plugin subscribed to `zigbee2mqtt/#`.

Example of the expected outgoing traffic for that light after startup: `zigbee2mqtt/0x00178d0009876543/get` with
`{"state":0}` (brightness is not requested by default), QoS 1.

---

## 16. Companion UI

None. The plugin has only the Homebridge config schema form (fields as in section 2; per-device fields other than
`id`/`exclude` are shown only while the device is not excluded; a header asks to reuse Z2M's MQTT settings).

---

## 17. Gaps and points needing a decision

1. **Availability from `bridge/info`:** the source evaluates Z2M's availability configuration on the whole info
   object rather than `info.config`, so availability is effectively always disabled after the device list arrives
   (10.1). And per-device JSON availability payloads are read from an `availability.state` member, whereas Z2M sends
   `{"state":"online"}` (10.2). Both look like bugs; they only matter with the `AVAILABILITY` experimental flag.
   Decide whether to reproduce or fix (fixing changes behaviour only for users who enabled the flag).
2. **Group removal race** (6.2): cached group accessories are dropped and recreated when `bridge/devices` is
   processed before `bridge/groups`. With retained messages the broker's delivery order decides. A replacement that
   waits for both lists before removing would keep group accessories (and their HomeKit rooms) stable.
3. **HAP-NodeJS semantics relied on implicitly:** characteristic writes from HomeKit in one request are coalesced
   (6.5); asking for a characteristic that a service lacks adds it (every service ends up with a Name);
   integer-format values (Brightness, BatteryLevel, positions) are rounded by HAP; Adaptive Lighting is HAP-NodeJS's
   controller in automatic mode (Homeswift has `AdaptiveLightingController`).
4. **Broker URL schemes:** MQTT.js also accepts `ws://`/`wss://`; check what the Homeswift MQTT client supports
   (TCP and TLS at least). `ca`/`key`/`cert` are file paths, not PEM text.
5. **Initial characteristic values** before the first state message are HAP defaults (e.g. On false, positions 0);
   the source does not seed them.
6. **Units are not converted** anywhere (VOC ppb vs µg/m³, mV voltages, hPa pressure); range growth absorbs
   out-of-range values.
7. **Stale handlers:** handlers are never removed during a run, and a service once produced is never considered
   stale until restart (6.8).
8. **Edge cases left as in the source:** `converters.switch.type` validated case-insensitively but honoured only as
   lower-case `outlet`; a `converters.light` value of `null` is not handled gracefully; `excluded_endpoints`
   containing `""` also drops features that only inherit their parent's endpoint (7.2); `defaults.exposes` would be
   applied to devices that have their own `devices[]` entry.
9. Not determined: the exact MQTT.js defaults beyond those named (they are library behaviour, not plugin
   behaviour).
