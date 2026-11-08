# Home Assistant: functional specification (clean room)

Written by the spec writer; contains no source code. Everything below describes, in the spec writer's own words,
observable behaviour and wire interfaces. Message types, JSON keys, state strings, service names, bit values and
HAP characteristic names are interfaces and are given exactly. There is no Homebridge plugin being ported: the
plugin `HomeAssistant` is new, and this document is its contract with a Home Assistant server.

---

## 0. Provenance

| Source | What it contributed | Commit / version | Licence | Holder |
|---|---|---|---|---|
| https://github.com/home-assistant/core | The WebSocket API (`components/websocket_api`: `auth.py`, `connection.py`, `http.py`, `messages.py`, `commands.py`, `const.py`), state and event shapes (`core.py`, `const.py`), the registries (`helpers/entity_registry.py`, `helpers/device_registry.py`, `helpers/area_registry.py`, `components/config/*_registry.py`), `get_config` (`core_config.py`), the zeroconf announcement (`components/zeroconf`), the domains' states, attributes, feature bits and services (`components/{light,cover,climate,fan,lock,alarm_control_panel,humidifier,valve,media_player,sensor,binary_sensor}/const.py`) | `3124627fb0dd27f9faa338beaa0495e7e62a9dc2` (committed 2026-11-07), package version `2026.12.0.dev0` | Apache-2.0 (`LICENSE.md`, stock text, no holder line) | The Home Assistant authors |
| same repository, `components/homekit` | **Only the mapping facts**: which domain / device class becomes which HAP service, which attribute fills which characteristic, and the value conversions. Its manifest pins `HAP-python==5.2.0` | same commit | Apache-2.0 | same |
| same repository, `components/homekit_controller` | How HA records accessories it pulls *from* HomeKit (identifiers, unique ids, manufacturer), for loop avoidance (§9). Pins `aiohomekit==4.0.1` (not read) | same commit | Apache-2.0 | same |
| https://contributors.home-assistant.io/core/internals/websocket-api/ (the old developers.home-assistant.io address redirects there) | Cross-check of the documented message examples (§2) | read 2026-11-07 | page states none | Home Assistant |

Reading method: shallow sparse clone, read with `grep`/`sed`. Nothing was run. Marks used below:
**[proposal]** is the spec writer's design for Homeswift with no HA behaviour behind it; **[unknown]** is a fact the
sources did not settle.

---

## 1. Overview

- Platform name: **`HomeAssistant`**. One instance per HA server; several instances may coexist (two servers).
- The plugin is a WebSocket **client** of HA's API at `/api/websocket`, authenticated with a **long-lived access
  token** (created by the user in HA: Profile → Security → Long-lived access tokens).
- It reads the entity, device and area registries and all states, subscribes to state changes, and turns each
  supported entity into a HomeKit Function; HomeKit writes become `call_service` commands.
- HA's own `homekit` integration does the same job from inside HA. The mapping in §7 follows it so that an entity
  looks the same in Apple Home whichever bridge exposes it.

---

## 2. Protocol

### 2.1 Connection

- URL: `ws://<host>:<port>/api/websocket`, or `wss://` when HA serves HTTPS. Default port **8123**. A base URL from
  mDNS (§3) or the user (e.g. `https://ha.example.com`) has its scheme mapped `http→ws`, `https→wss` and
  `/api/websocket` appended.
- Every message is one WebSocket **text** frame holding JSON. Binary frames exist (first byte a handler id, used by
  voice pipelines) and are not used by this plugin.
- The server sends WebSocket ping frames every **55 s** (aiohttp heartbeat) and expects pongs; a WebSocket library
  answers them itself.

### 2.2 Authentication phase

1. On connect the server sends:
   `{"type":"auth_required","ha_version":"2026.12.0"}`
2. The client sends, within **10 s** (else the server closes), at most **64 KiB**:
   `{"type":"auth","access_token":"<token>"}`
   (`api_password` instead of `access_token` is accepted by the schema, exclusive with it; legacy, not used.)
3. Success: `{"type":"auth_ok","ha_version":"2026.12.0"}`. Failure:
   `{"type":"auth_invalid","message":"Invalid access token or password"}`, then the server closes.
   A malformed auth message gets `auth_invalid` with `"message":"Auth message incorrectly formatted: …"`.
   A user not allowed from this network (local-only user from outside) gets `auth_invalid` with another message.
- Auth messages carry **no `id`**. `ha_version` is the server version string.
- `auth_invalid` is Needs Authorization (GLOSSARY): stop reconnecting until the token is replaced **[proposal]**.
  Failed logins count towards HA's IP ban (`http: ip_ban_enabled`), so never retry a refused token in a loop.
- A revoked token closes the connection later, at any time.

### 2.3 Command phase: ids

- Every client message is an object with an integer **`id`** (> 0) and a string **`type`**; anything else gets
  error `invalid_format` ("Message incorrectly formatted.").
- Ids must **strictly increase** on a connection. An id ≤ the last accepted one gets `id_reuse`
  ("Identifier values have to increase."). A new connection starts again (first id 1 is fine).
- The last id only advances after a message has been dispatched; an unknown `type` gets `unknown_command`
  ("Unknown command.").
- A schema with extra keys is rejected (`invalid_format`, message from the schema validator).
- The client **may send a JSON array** of command objects in one frame; each element is handled in order.

### 2.4 Results and errors

Success:
`{"id":5,"type":"result","success":true,"result":<any or null>}`

Error:
`{"id":5,"type":"result","success":false,"error":{"code":"<code>","message":"<text>"}}`
optionally with `"translation_key"`, `"translation_placeholders"`, `"translation_domain"` inside `error`.

Codes: `id_reuse`, `invalid_format`, `not_allowed`, `not_found`, `not_supported`, `home_assistant_error`,
`service_validation_error`, `unknown_command`, `unknown_error`, `unauthorized`, `timeout`, `template_error`.

### 2.5 Events

A subscription's messages carry the subscribing command's id:
`{"id":7,"type":"event","event":{…}}`. The key order is not fixed (`id` may come last): parse as JSON.

### 2.6 Commands the plugin uses

**`supported_features`** (send first, right after `auth_ok`):
`{"id":1,"type":"supported_features","features":{"coalesce_messages":1}}` → result `null`.
Values are integers. Effect: see §2.7.

**`get_config`**: `{"id":2,"type":"get_config"}` → result object with, among others: `location_name`, `latitude`,
`longitude`, `elevation`, `unit_system` (`{"length","accumulated_precipitation","area","mass","pressure",
"temperature","volume","wind_speed"}`, e.g. `"temperature":"°C"` or `"°F"`), `time_zone`, `components` (loaded
integrations, e.g. contains `"homekit"`), `version`, `state` (`"RUNNING"` once started; `"NOT_RUNNING"`,
`"STARTING"`, `"STOPPING"`, `"FINAL_WRITE"`, `"STOPPED"` otherwise **[unknown: exact set not read]**),
`external_url`, `internal_url`, `language`, `country`, `currency`. `external_url` is dropped for local-only users.
The climate domain's temperatures are in `unit_system.temperature` (§7.6).

**`get_states`**: `{"id":3,"type":"get_states"}` → result is an array of full states:
```json
{"entity_id":"light.kitchen","state":"on",
 "attributes":{"friendly_name":"Kitchen","supported_color_modes":["color_temp","hs"],"color_mode":"hs",
               "brightness":180,"hs_color":[30.0,60.0],"supported_features":40},
 "last_changed":"2026-11-07T10:00:00.123456+00:00","last_reported":"…","last_updated":"…",
 "context":{"id":"01J…","parent_id":null,"user_id":null}}
```
Only entities the user may read are returned (an admin sees all).

**`subscribe_events`**: `{"id":4,"type":"subscribe_events","event_type":"state_changed"}` → result `null`, then
events. Omitting `event_type` subscribes to all events (admin only). A non-admin may subscribe only to:
`state_changed`, `area_registry_updated`, `device_registry_updated`, `entity_registry_updated`,
`floor_registry_updated`, `label_registry_updated`, `category_registry_updated`, `component_loaded`,
`core_config_updated`, `service_registered`, `service_removed`, `repairs_issue_registry_updated`, and some
UI/recorder events; others get `unauthorized`.

`state_changed` event:
```json
{"id":4,"type":"event","event":{
  "event_type":"state_changed",
  "data":{"entity_id":"light.kitchen","old_state":{…full state…},"new_state":{…full state…}},
  "origin":"LOCAL","time_fired":"2026-11-07T10:37:24.265429+00:00",
  "context":{"id":"01J…","parent_id":null,"user_id":null}}}
```
`old_state` is `null` when the entity appeared; `new_state` is `null` when it was removed. `origin` is `"LOCAL"`
or `"REMOTE"`. `context.user_id` is the token's user when the change came from this client's own `call_service`.

Registry events (subscribe one `subscribe_events` per type), `event.data`:
- `entity_registry_updated`: `{"action":"create"|"remove","entity_id":…}` or
  `{"action":"update","entity_id":…,"changes":{<field>:<old value>},"old_entity_id":…?}`.
- `device_registry_updated`: `{"action":"create","device_id":…}`, `{"action":"remove","device_id":…,"device":{…}}`,
  `{"action":"update","device_id":…,"changes":{…}}`.
- `area_registry_updated`: `{"action":…,"area_id":…}` **[unknown: payload fields not read; refetch the list]**.

**`subscribe_entities`** (an alternative to `get_states` + `state_changed`, compressed):
`{"id":5,"type":"subscribe_entities","entity_ids":["light.kitchen"]}` (`entity_ids` optional) → result `null`,
then a first event `{"a":{"<entity_id>":{"s":"on","a":{…attributes…},"c":"<context id>","lc":1731000000.12,
"lu":…}}}`, then events with any of: `"a"` (added, same shape), `"c"` (changed: `{"<entity_id>":{"+":{"s":…,
"a":{changed attributes},"lc":…|"lu":…,"c":…},"-":{"a":["removed attribute",…]}}}`), `"r"` (removed:
`["<entity_id>",…]`). Keys: `s` state, `a` attributes, `c` context (a bare id string when it has no parent or
user, else the `{id,parent_id,user_id}` object), `lc` last changed (Unix seconds, float), `lu` last updated (present
only when different from `lc`). The server registers the listener before sending the first event, so no change is
lost. Either approach is valid; `get_states` + `subscribe_events` is simpler to reason about **[proposal: use it]**.

**`unsubscribe_events`**: `{"id":9,"type":"unsubscribe_events","subscription":4}` → result `null`, or `not_found`.

**`call_service`**:
```json
{"id":24,"type":"call_service","domain":"light","service":"turn_on",
 "service_data":{"brightness_pct":50},"target":{"entity_id":"light.kitchen"}}
```
→ `{"id":24,"type":"result","success":true,"result":{"context":{"id":"01J…","parent_id":null,"user_id":"…"}}}`.
`target` may hold `entity_id`, `device_id`, `area_id`, `floor_id`, `label_id` (string or array); `entity_id` may
also go in `service_data` (HA's own homekit does that). `"return_response":true` adds `"response"` to the result
(only for services that return data). The call is **blocking**: the result comes after the service finished, so
the entity's `state_changed` usually arrives before the result. Errors: `not_found` ("Service light.foo not
found."), `invalid_format` (bad data), `service_validation_error` ("Validation error: …"),
`home_assistant_error` (device failure), `unknown_error`, `unauthorized`.

**Registries** (each returns the whole list as `result`):
- `{"id":10,"type":"config/entity_registry/list"}` (§4.1)
- `{"id":11,"type":"config/device_registry/list"}` (§4.2)
- `{"id":12,"type":"config/area_registry/list"}` (§4.3)
The three `list` commands carry no admin requirement (only the registries' create/update/remove commands do), so a
non-admin token can read them. Still treat an `unauthorized` or `unknown_command` reply as "registries unavailable"
and fall back to states only (§4.4) **[proposal]**.

**`ping`**: `{"id":30,"type":"ping"}` → `{"id":30,"type":"pong"}` (a message of its own type, not a `result`).
**[proposal]** Ping every 30 s; no pong within 10 s → close and reconnect.

### 2.7 Coalesced messages

After `supported_features` with `coalesce_messages`, the server may send **a JSON array of messages in one text
frame** (`[{"id":4,"type":"event",…},{"id":4,"type":"event",…}]`) when several are queued; a lone message is still
sent bare. The client must accept both a top-level object and a top-level array, from then on (the server decides
per write). Without the feature, every frame is one object.

### 2.8 Limits

- The server queues at most **4096** messages for a client; reaching that, it logs "Client unable to keep up" and
  closes the connection. Read continuously; never block the reader on HomeKit work.
- Above 1024 pending messages for more than 10 s the server also closes **[from constants `PENDING_MSG_PEAK`,
  `PENDING_MSG_PEAK_TIME`; exact behaviour not traced]**.

### 2.9 Session sequence **[proposal]**

connect → `auth_required` → `auth` → `auth_ok` → `supported_features` → `get_config` →
`subscribe_events state_changed` (subscribe **before** reading states, buffer events) → registries (three lists) →
`get_states` → apply buffered events newer than the snapshot → subscribe the three registry events → ping loop.
On close: mark every accessory unreachable (no fault, keep last values), reconnect with backoff 1 s doubling to
60 s (`HomeswiftNetwork` `Backoff`), redo the whole sequence. When `get_config.state` is not `RUNNING`, states may be
incomplete: reread states when it becomes running (the `core_config_updated` event, or retry after 10 s).

---

## 3. Discovery (mDNS)

- Service type **`_home-assistant._tcp`** (`.local.`). Instance name: the location name (filtered of disallowed
  characters, at most 63 bytes, "Home" when empty). SRV target `<uuid>.local.`, port = HA's HTTP port.
- TXT keys:
  | Key | Value |
  |---|---|
  | `location_name` | The home's name |
  | `uuid` | The instance id (32 hex chars **[unknown: format not read; treat as opaque]**); stable across restarts: the **Device Id** of the server for Setup |
  | `version` | e.g. `2026.12.0` |
  | `external_url` | e.g. `https://ha.example.com` or empty |
  | `internal_url` | e.g. `http://192.168.1.10:8123` or empty |
  | `base_url` | Legacy: `external_url` if set, else `internal_url` |
  | `requires_api_password` | **Not sent** by the commit read (legacy key of old versions); ignore when present |
- A value longer than 230 bytes is sent empty.
- **[proposal]** Prefer `internal_url`, else the SRV address and port with `http`. Discovered servers are
  Discovered Devices; their Authorization Method is **API Key** (the long-lived token).

---

## 4. Identity

### 4.1 Entity registry entry (`config/entity_registry/list` element)

`area_id`, `categories` (object), `config_entry_id`, `config_subentry_id`, `created_at` (Unix seconds), `device_id`,
`disabled_by`, `entity_category`, `entity_id`, `hidden_by`, `icon`, `id` (registry id, opaque, stable even when
`entity_id` is renamed), `labels` (array), `modified_at`, `name` (user's name or null), `next_name_part`,
`options`, `original_name`, `platform` (the integration, e.g. `hue`, `homekit_controller`), `translation_key`,
`unique_id` (unique within `platform` only). (`has_entity_name`, `device_class`, `capabilities`, `aliases` belong
to the extended entry of `config/entity_registry/get`, not to the list.)

- `disabled_by`: null or `"config_entry"`, `"device"`, `"hass"`, `"integration"`, `"user"`. A disabled entity
  has **no state** at all.
- `hidden_by`: null or `"integration"`, `"user"`.
- `entity_category`: null, `"config"` or `"diagnostic"`.
- Entities without a unique id are not in the registry (YAML templates without `unique_id`); they have states only.

### 4.2 Device registry entry

`area_id`, `configuration_url`, `config_entries`, `config_entries_subentries`, `config_entry_id`, `connections`
(array of `[type, value]` pairs: `"mac"` with value lowercased `aa:bb:cc:dd:ee:ff`, also `"bluetooth"`, `"upnp"`,
`"zigbee"`), `created_at`, `disabled_by` (`"config_entry"`, `"integration"`, `"user"` or null), `entry_type` (null
or `"service"`), `hw_version`, `id`, `identifiers` (array of `[domain, id]`, sometimes 3 items in old entries),
`labels`, `manufacturer`, `model`, `model_id`, `modified_at`, `name`, `name_by_user`, `next_name_part`,
`parent_device_id`, `primary_config_entry`, `serial_number`, `sw_version`, `via_device_id`.

### 4.3 Area registry entry

`aliases`, `area_id`, `floor_id`, `humidity_entity_id`, `icon`, `labels`, `name`, `picture`,
`temperature_entity_id`, `created_at`, `modified_at`.

### 4.4 Homeswift identities **[proposal]**

- Plugin instance key: the server's `uuid` (from mDNS, or from Add by address via the `uuid`… **[unknown: no
  WebSocket command read returns the instance uuid; use the configured URL as fallback key]**).
- **Device Id = HA device registry `id`** for entities that have a device; **`entity:<entity registry id>`** for
  registry entities without a device; **`state:<entity_id>`** for entities with no registry entry (not stable
  across renames). Accessory Id `HomeAssistant:<Device Id>`.
- One accessory per HA device; each supported entity of the device is one Function (a HAP service with subtype =
  the entity registry `id`, else the `entity_id`), so renaming an `entity_id` keeps HomeKit's iids.
- Entity → entity mapping on rename: an `entity_registry_updated` `update` with `old_entity_id` moves the binding.
- Accessory Name: device `name_by_user` ?? `name`; Function name: entity state attribute `friendly_name`.
- Room hint: entity `area_id` ?? device `area_id` → area `name`.
- Accessory Information: Manufacturer = device `manufacturer` ?? "Home Assistant"; Model = `model` ?? the domain;
  FirmwareRevision = `sw_version` when it parses as a version; Serial Number = the device's `mac` connection as
  uppercase hex without separators (repo rule), else `serial_number`, else the Device Id.

### 4.5 Which entities are taken **[proposal, following HA homekit]**

- HA's homekit skips registry entities with `entity_category` or `hidden_by` set unless explicitly included. Do the
  same by default (diagnostic/config entities are noise); an Accessory Setting can include them.
- Skip `disabled_by` entities (they have no state) and devices with `disabled_by`.
- States `unavailable`: Function not reachable (no value change). `unknown`: keep previous values. HA's homekit
  does exactly this: it never pushes values for these two states.
- An entity whose attributes change in a way that changes the service shape (light `supported_color_modes`,
  `min/max_color_temp_kelvin`; fan `percentage_step`, `preset_modes`; climate `hvac_modes`, `min_temp`, `max_temp`,
  `min_humidity`, `fan_modes`…; humidifier `min/max_humidity`) is rebuilt (HA's homekit reloads the accessory).

---

## 5. Common state attributes

`friendly_name`, `supported_features` (integer bitmask, absent = 0), `device_class`, `unit_of_measurement`,
`state_class` (`measurement`, `total`, `total_increasing`, `measurement_angle`), `icon`, `entity_picture`,
`battery_level` (0–100, on some entities), `battery_charging` (bool). Generic states: `on`, `off`, `unknown`,
`unavailable`; numbers are sent as **strings** in `state` (`"21.5"`).

Battery (HA homekit): an entity with a `battery_level` attribute gets a Battery service: BatteryLevel = the value,
StatusLowBattery = 1 when level < **20**, ChargingState = 1/0 from `battery_charging` when present. A separate
`sensor` with `device_class: battery` on the same device can fill the device's Battery service **[proposal; HA
does it only through a configured `linked_battery_sensor`]**.

---

## 6. Write rules (all domains)

- Writes are `call_service` with `target: {"entity_id": …}`.
- HA's homekit gathers the characteristic writes of one service that arrive within **10 ms** into one call (so
  On + Brightness + Hue become one `light.turn_on`). Do the same.
- After a write, do not set the characteristic from the request: the `state_changed` sets it **[proposal]**, except
  where §7 says HA sets an optimistic value.
- A `result` error is a write failure (HAP status `-70402`, service communication failure) **[proposal]**.

---

## 7. Domain mapping (first release)

### 7.1 light → Lightbulb

- States `on`/`off`. Features: `EFFECT=4`, `FLASH=8`, `TRANSITION=32` (none needed).
- `supported_color_modes` (list) from: `onoff`, `brightness`, `color_temp`, `hs`, `xy`, `rgb`, `rgbw`, `rgbww`,
  `white` (`unknown` also exists). `color_mode` is the current one.
  - brightness supported ⇔ any mode other than `onoff`; colour ⇔ any of `hs`, `xy`, `rgb`, `rgbw`, `rgbww`;
    colour temperature ⇔ `color_temp`.
- Attributes: `brightness` (0–255), `color_temp_kelvin`, `min_color_temp_kelvin`, `max_color_temp_kelvin`,
  `hs_color` [hue 0–360, saturation 0–100], `rgb_color`, `xy_color`, `rgbw_color`, `rgbww_color`, `effect`,
  `effect_list`. Mired attributes (`color_temp`, `min_mireds`, `max_mireds`) are **not sent** at the commit read;
  older servers sent them **[unknown: removal version]**. Use kelvin only.
- Characteristics: On; Brightness if brightness; Hue + Saturation if colour; ColorTemperature if colour
  temperature, or if `rgbww`, `rgbw` or `white` is supported.
- Read:
  - On = `state == "on"`.
  - Brightness = round(`brightness` / 255 × 100); 0 while on becomes 1. Absent (light off) → keep last.
  - Hue/Saturation: if `color_temp_kelvin` is set, the hue/saturation of that white point (HA converts the
    temperature to hs; use `ColorUtils`); if `color_mode == "white"`, 0/0; else `hs_color` rounded.
  - ColorTemperature (mireds) = floor(1 000 000 / `color_temp_kelvin`) when colour temperature is supported;
    `min_mireds` when `color_mode == "white"`. Range: minValue = floor(1e6 / `max_color_temp_kelvin`, default 6500)
    = 153, maxValue = floor(1e6 / `min_color_temp_kelvin`, default 2000) = 500 (swap if reversed). Without
    `color_temp` and without `rgbww`, maxValue = minValue (a fixed white).
- Write (one call per 10 ms batch):
  - On = false, or Brightness = 0 → `light.turn_off` (nothing else).
  - Otherwise `light.turn_on` with: `brightness_pct` = Brightness (1–100) when Brightness was written;
    ColorTemperature written → `color_temp_kelvin` = floor(1e6 / mireds) if `color_temp` supported, else
    `rgbww_color` (computed from the kelvin, **[unknown: HA's `color_temperature_to_rgbww` formula not
    specified here; omit rgbww-only white in the first release]**), else `rgbw_color` [0,0,0,b] or `white` = b,
    with b = round(Brightness × 255 / 100); Hue/Saturation written → `hs_color` [hue, saturation], filling the one
    not written from the current characteristic. A ColorTemperature write cancels pending Hue/Saturation and the
    reverse (last wins). `brightness_pct` is not sent together with `rgbw_color`/`rgbww_color`.

### 7.2 switch, input_boolean → Switch (or Outlet)

- States `on`/`off`. `switch` with `device_class: "outlet"` → **Outlet** (OutletInUse fixed true); `device_class:
  "switch"` or none → **Switch**. `input_boolean` → Switch.
- Read On = `state == "on"`. Write `<domain>.turn_on` / `<domain>.turn_off`.

### 7.3 scene, script, button (and input_button) → Switch, momentary

- HA homekit treats `button`, `input_button`, `scene`, `script` as **activate-only**: state changes are ignored, On
  stays false except after a write.
- Write On = true: `scene.turn_on` (target the entity); `script.<object_id>` with **no** data (the script's own
  service, e.g. entity `script.good_night` → `{"domain":"script","service":"good_night"}`); `button.press`;
  `input_button.press`. Then On returns to false after **10 s** (HA's delay; **[proposal]** 1 s is friendlier, either
  is valid). On = false writes are ignored.
- States for reference: scene and button state is the ISO timestamp of last activation; script is `on` while
  running, `off` otherwise.

### 7.4 cover

Features: `OPEN=1`, `CLOSE=2`, `SET_POSITION=4`, `STOP=8`, `OPEN_TILT=16`, `CLOSE_TILT=32`, `STOP_TILT=64`,
`SET_TILT_POSITION=128`, `SPEED=256`. States `open`, `opening`, `closed`, `closing`. Attributes
`current_position` (0–100, 100 = open), `current_tilt_position` (0–100). Device classes: `awning`, `blind`,
`curtain`, `damper`, `door`, `garage`, `gate`, `shade`, `shutter`, `window`. Services: `open_cover`,
`close_cover`, `stop_cover`, `set_cover_position` (`position`), `set_cover_tilt_position` (`tilt_position`),
`open_cover_tilt`, `close_cover_tilt`, `stop_cover_tilt`, `toggle`.

Service choice, first match:
1. `garage` or `gate` with OPEN or CLOSE → **GarageDoorOpener**.
2. `window` with SET_POSITION → **Window**. 3. `door` with SET_POSITION → **Door**.
4. SET_POSITION → **WindowCovering**. 5. OPEN or CLOSE → **WindowCovering, basic** (below).
6. SET_TILT_POSITION only → WindowCovering (positions fixed: TargetPosition min = max = 0).
7. else not supported.

GarageDoorOpener: CurrentDoorState from state: `open`→0, `closed`→1, `opening`→2, `closing`→3; TargetDoorState:
`open`/`opening`→0, `closed`/`closing`→1. ObstructionDetected = attribute `obstruction-detected` is `true` (rare;
default false). Write TargetDoorState 0 → `open_cover`, 1 → `close_cover`; HA sets CurrentDoorState to 2 (opening) /
3 (closing) at once when it differs from the target.

Window / Door / WindowCovering (with SET_POSITION): CurrentPosition = int(`current_position`). TargetPosition =
CurrentPosition when not moving; while `opening` a target below the current position becomes 100, while `closing` a
target above it becomes 0 (otherwise keep HomeKit's). PositionState: `opening`→1 (going to max), `closing`→0 (going to
min), else 2 (stopped). Write TargetPosition → `set_cover_position {position}`. With STOP: HoldPosition, write
true (1) → `stop_cover`. With SET_TILT_POSITION: CurrentHorizontalTiltAngle and TargetHorizontalTiltAngle (both) = int(`current_tilt_position` / 100 × 180 − 90);
write angle → `set_cover_tilt_position {tilt_position: round((angle + 90) / 180 × 100)}`.

WindowCovering, basic (OPEN/CLOSE without SET_POSITION): Current/TargetPosition 100 for `open`, 0 for `closed`
(target untouched while moving); PositionState as above. Write TargetPosition v: with STOP, v > 70 →
`open_cover` (100), v < 30 → `close_cover` (0), else `stop_cover` (50); without STOP, v ≥ 50 → open (100), else close
(0). HA sets Current and Target to that number at once.

### 7.5 lock → LockMechanism

States `locked`, `unlocked`, `locking`, `unlocking`, `jammed`, `open`, `opening` (+ `unknown`). Feature `OPEN=1`.
Attribute `code_format` (regex, when a code is needed). Services `lock`, `unlock`, `open` (optional `code`).

- LockCurrentState: `unlocked`→0, `unlocking`→1, `locking`→0, `locked`→1, `jammed`→2, anything else (incl.
  `open`, `opening`, `unknown`)→3.
- LockTargetState: `unlocked`/`unlocking`→0, `locking`/`locked`→1; other states leave it unchanged.
- Write 1 → `lock.lock`, 0 → `lock.unlock`, with `code` when the user configured one (secret-named key,
  **[proposal]** `lockCode`). Locks are security controls: writes only through `set_security_accessory` (repo rule).

### 7.6 climate → Thermostat

States = HVAC mode: `off`, `heat`, `cool`, `heat_cool`, `auto`, `dry`, `fan_only`. Features:
`TARGET_TEMPERATURE=1`, `TARGET_TEMPERATURE_RANGE=2`, `TARGET_HUMIDITY=4`, `FAN_MODE=8`, `PRESET_MODE=16`,
`SWING_MODE=32`, `TURN_OFF=128`, `TURN_ON=256`, `SWING_HORIZONTAL_MODE=512`. Attributes: `hvac_modes`,
`hvac_action` (`off`, `idle`, `heating`, `cooling`, `drying`, `fan`, `preheating`, `defrosting`),
`current_temperature`, `temperature`, `target_temp_high`, `target_temp_low`, `min_temp` (default 7), `max_temp`
(default 35), `target_temp_step`, `current_humidity`, `humidity` (target), `min_humidity` (30), `max_humidity`
(99), `fan_mode(s)`, `preset_mode(s)`, `swing_mode(s)`. **Temperatures are in `get_config.unit_system.temperature`**
(°C or °F); HomeKit is Celsius: convert both ways.

- Mode map HA→HomeKit TargetHeatingCoolingState: `off`→0, `heat`→1, `cool`→2, `auto`→3, `heat_cool`→3, `dry`→2,
  `fan_only`→2. The HomeKit→HA reverse is built from `hvac_modes` (default `[heat, cool, heat_cool, off]`), leaving
  out `auto` when `heat_cool` is present and `dry`/`fan_only` when `cool` is present; TargetHeatingCoolingState's
  valid values are those it covers.
- CurrentHeatingCoolingState from `hvac_action`: `off`/`idle`→0, `heating`/`preheating`/`defrosting`→1,
  `cooling`/`drying`/`fan`→2; unknown action→0; no attribute → leave.
- CurrentTemperature = `current_temperature` (converted). TargetTemperature = `temperature`; when absent and
  RANGE is supported: `target_temp_low` in heat (1), `target_temp_high` in cool (2). Range of TargetTemperature and
  the thresholds: [`min_temp`, `max_temp`] converted, swapped if reversed, rounded inward to 0.1, minimum clamped to
  ≥ 0. With RANGE: CoolingThresholdTemperature = `target_temp_high`, HeatingThresholdTemperature =
  `target_temp_low`. TemperatureDisplayUnits = 0 for °C, 1 for °F. With `current_humidity` or TARGET_HUMIDITY:
  CurrentRelativeHumidity; with TARGET_HUMIDITY: TargetRelativeHumidity (minValue `min_humidity`).
- Writes:
  - TargetHeatingCoolingState → `climate.set_hvac_mode {hvac_mode}`. A value with no HA mode (Siri sends 3 to
    heat-only devices) falls back in order 3,1,2,0 (prefer heat), or 3,2,1,0 when the written TargetTemperature is
    below the current temperature; the characteristic takes the fallback.
  - TargetTemperature with TARGET_TEMPERATURE → `climate.set_temperature {temperature}` (converted to HA's unit).
    With only RANGE, it becomes the heating threshold in heat mode, the cooling threshold in cool mode.
  - Thresholds → `climate.set_temperature {target_temp_high, target_temp_low}`, both sent: the unwritten one from
    the current characteristic; if high < low the other moves to keep a **5 °C** gap, then each is clamped to the
    range, and the gap is restored on the side not at a bound.
  - TargetRelativeHumidity → `climate.set_humidity {humidity}`.
  - Fan, swing and presets as a linked Fanv2: **[not in the first release]**.

### 7.7 sensor

Pick by `device_class` (then unit), first match; `state` parsed as a number, non-numbers ignored:

| HA | HAP service and characteristic | Conversion |
|---|---|---|
| `temperature`, or unit `°C`/`°F` | TemperatureSensor / CurrentTemperature (minValue −273, maxValue 999) | to °C from the entity's `unit_of_measurement` (default °C) |
| `humidity` **and** unit `%` | HumiditySensor / CurrentRelativeHumidity | none |
| `illuminance`, or unit `lx` | LightSensor / CurrentAmbientLightLevel | none (HAP's minimum is 0.0001 lux **[proposal: clamp]**) |
| `carbon_dioxide` (`co2` in the entity id as fallback) | CarbonDioxideSensor / CarbonDioxideLevel, CarbonDioxidePeakLevel, CarbonDioxideDetected | Peak = highest seen; Detected = 1 when level > **1000** ppm |
| `carbon_monoxide` | CarbonMonoxideSensor / CarbonMonoxideLevel, PeakLevel, Detected | Detected when level > **25** ppm |
| `pm25` (`pm25` in id as fallback) | AirQualitySensor / PM2_5Density, AirQuality | AirQuality from µg/m³: ≤9→1, ≤35.4→2, ≤55.4→3, ≤125.4→4, else 5 |
| `pm10` | AirQualitySensor / PM10Density, AirQuality | ≤54→1, ≤154→2, ≤254→3, ≤354→4, else 5 |
| `battery` | the device's Battery service (§5) **[proposal; HA homekit makes no accessory for it]** | level; low < 20 |
| `power` (W, kW…), `energy` (Wh, kWh…) | no HAP service. **[proposal]** feed the bridge's Energy (Eve characteristics or a Meter via `context.meter`), converting to W and kWh | — |

Order matters: HA tests temperature, humidity, pm10, pm25, nitrogen_dioxide, volatile_organic_compounds, ozone,
sulphur_dioxide, gas, carbon_monoxide, carbon_dioxide, illuminance, then the entity-id fallbacks (`pm10`, `pm25`,
`gas`, `co2`). Others (NO2, VOC, ozone, SO2) are out of the first release.

### 7.8 binary_sensor

`state` `on`/`off` (`on` = detected / open / wet / low). Value written = 1 (or true) when `on`:

| device_class | Service / characteristic |
|---|---|
| `door`, `window`, `opening`, `garage_door` | ContactSensor / ContactSensorState (on = open = 1 "not detected") |
| `motion` | MotionSensor / MotionDetected (bool) |
| `occupancy`, `presence`, any other or none | OccupancySensor / OccupancyDetected (HA's default for unmapped classes) |
| `moisture` | LeakSensor / LeakDetected |
| `smoke` | SmokeSensor / SmokeDetected |
| `carbon_monoxide`, `gas` | CarbonMonoxideSensor / CarbonMonoxideDetected |
| `battery` | **[proposal]** StatusLowBattery on the device's Battery service, not a sensor (HA would make it an occupancy sensor) |

**[proposal]** Leave out the classes where an occupancy sensor would mislead (`connectivity`, `problem`, `update`,
`running`, `plug`, `power`, `light`, `lock`, `tamper`…) unless the user includes them.

### 7.9 fan → Fanv2

States `on`/`off`. Features `SET_SPEED=1`, `OSCILLATE=2`, `DIRECTION=4`, `PRESET_MODE=8`, `TURN_OFF=16`,
`TURN_ON=32`. Attributes `percentage` (0–100), `percentage_step`, `oscillating`, `direction` (`forward`/`reverse`),
`preset_mode`, `preset_modes`.

- Active = 1 for `on`, 0 for `off` (other states leave it).
- RotationSpeed (SET_SPEED, minStep = `percentage_step`, default 1) = `percentage` when not off; 0 while on →
  max(1, step). Write → `fan.set_percentage {percentage}`.
- SwingMode (OSCILLATE) = `oscillating` 1/0; write → `fan.oscillate {oscillating: bool}`.
- RotationDirection (DIRECTION): `reverse`→1, `forward`→0; write → `fan.set_direction {direction}`.
- Active write: 0 → `fan.turn_off` (and nothing else from the batch); 1 → `fan.turn_on`, unless RotationSpeed is
  in the same batch (then only `set_percentage`).
- Presets: exactly one preset → TargetFanState (1 = `preset_mode` set; write 1 → `fan.set_preset_mode
  {preset_mode}`, write 0 → `fan.turn_on {percentage: current or 50}`); several → one linked Switch per preset named
  "<fan> <preset>" (On = that preset is current; write true → `set_preset_mode`, false → `fan.turn_on`).

### 7.10 media_player → Switch (power)

States `off`, `on`, `idle`, `playing`, `paused`, `standby`, `buffering`. Features (selected): `PAUSE=1`,
`VOLUME_MUTE=8`, `TURN_ON=128`, `TURN_OFF=256`, `STOP=4096`, `PLAY=16384`.

- Only when TURN_ON or TURN_OFF is supported: a Switch "<name> Power", On = state not in (`off`, `unknown`,
  `standby`, `"None"`); write → `media_player.turn_on`/`turn_off`. HA also offers Play-Pause, Play-Stop and Mute
  switches and a Television service for `device_class` `tv`/`receiver`/`projector`: **[not in the first release]**.

### 7.11 valve → Valve

States `open`, `opening`, `closing`, `closed`. Features `OPEN=1`, `CLOSE=2`, `SET_POSITION=4`, `STOP=8`. Device
classes `water`, `gas`. Services `open_valve`, `close_valve`, `set_valve_position {position}`, `stop_valve`.

- Active = InUse = 1 when state ∈ {`open`, `opening`, `closing`}, else 0. ValveType 0 (generic; HA's default
  `valve` type). Write Active 1/0 → `valve.open_valve`/`close_valve`; HA sets InUse to the written value at once.
- **[proposal]** A `gas` valve is a security control (written only through `set_security_accessory`).

### 7.12 alarm_control_panel → SecuritySystem

States `disarmed`, `armed_home`, `armed_away`, `armed_night`, `armed_vacation`, `armed_custom_bypass`, `pending`,
`arming`, `disarming`, `triggered`. Features `ARM_HOME=1`, `ARM_AWAY=2`, `ARM_NIGHT=4`, `TRIGGER=8`,
`ARM_CUSTOM_BYPASS=16`, `ARM_VACATION=32` (absent attribute: assume HOME|AWAY|NIGHT|TRIGGER|VACATION).
Attributes `code_format` (`text`/`number`/null), `code_arm_required`. Services `alarm_disarm`, `alarm_arm_home`,
`alarm_arm_away`, `alarm_arm_night`, `alarm_arm_vacation`, `alarm_arm_custom_bypass`, `alarm_trigger` (`code`).

- SecuritySystemCurrentState: `armed_home`→0 (stay), `armed_away`/`armed_vacation`→1 (away), `armed_night`→2,
  `disarmed`/`arming`→3, `triggered`→4; others (`pending`, `disarming`, `armed_custom_bypass`) leave it.
- SecuritySystemTargetState: `armed_home`→0, `armed_away`/`armed_vacation`/`arming`→1, `armed_night`→2,
  `disarmed`→3 (`arming` is skipped when 1 is not a valid value).
- Valid values: current always 3 and 4; with ARM_HOME 0; with ARM_AWAY or ARM_VACATION 1; with ARM_NIGHT 2; target
  likewise without 4. Values outside are never pushed.
- Write 0→`alarm_arm_home`, 1→`alarm_arm_away`, 2→`alarm_arm_night`, 3→`alarm_disarm`, with `code` when configured
  (**[proposal]** secret-named `alarmCode`). Security control: `set_security_accessory` only.

### 7.13 humidifier → HumidifierDehumidifier

States `on`/`off`. `device_class` `humidifier` (default) or `dehumidifier`. Attributes `humidity` (target),
`current_humidity`, `min_humidity` (default 0), `max_humidity` (default 100), `target_humidity_step`, `action`
(`humidifying`, `drying`, `idle`, `off`), `mode`, `available_modes`. Services `turn_on`, `turn_off`,
`set_humidity {humidity}`, `set_mode {mode}`.

- TargetHumidifierDehumidifierState fixed: 1 (humidifier) or 2 (dehumidifier), min = max = that value.
- Active = `state == "on"`. CurrentHumidifierDehumidifierState: on → 2 (humidifying) or 3 (dehumidifying) by
  class, off → 0 (HA ignores `action`; **[proposal]** use `action`: `idle`→1, `humidifying`→2, `drying`→3, `off`→0).
- HumidifierRelativeHumidityThreshold (humidifier) or DehumidifierRelativeHumidityThreshold (dehumidifier) =
  `humidity`, range 0–100 step 1; CurrentRelativeHumidity = `current_humidity`.
- Writes: Active → `humidifier.turn_on`/`turn_off`; threshold → `humidifier.set_humidity {humidity: round(v)}`
  clamped to [`min_humidity`, `max_humidity`].

---

## 8. Configuration **[proposal]**

The block in `platforms` (canonical shape; Accessory Settings in `_accessories` by Device Id):

| Key | Type | Meaning |
|---|---|---|
| `platform` | `"HomeAssistant"` | |
| `name` | string | Instance name, default the `location_name` |
| `url` | string | Base URL, e.g. `http://homeassistant.local:8123` |
| `accessToken` | string, **secret** (matches `token`) | The long-lived access token; sealed by the runtime |
| `serverId` | string | The mDNS `uuid` when discovered (identity of the server) |
| `domains` | array of strings | Domains taken, default all of §7 |
| `includeEntities` / `excludeEntities` | arrays of entity ids or globs | Overrides of §4.5 |
| `lockCode`, `alarmCode` | string, secret | Codes sent with `lock.*` and `alarm_*` |
| `verifyTLS` | bool, default true | For `wss://` with a self-signed certificate: trust on first use (`HomeswiftNetwork` `TrustOnFirstUse`) |

Setup: Discovered Device from mDNS (§3) or Add by address (`url`); Authorization Method **API Key** (the token);
probe = connect, auth, `get_config`. Each HA device is then a Discovered Device of the instance.

---

## 9. Loops with HomeKit

Two different loops exist.

### 9.1 HA's `homekit` integration (HA → HomeKit) exposing the same entities

Not a loop but duplicates in Apple Home. Accessories it publishes carry:
- Bridge accessory: Manufacturer **`Home Assistant`**, Model **`Bridge`**, Serial **`homekit.bridge`**, name
  "Home Assistant Bridge" style (`HASS Bridge` short form).
- Each entity accessory: Serial Number = the **`entity_id`** (or the HA device id for device-trigger accessories);
  Manufacturer = the HA device's `manufacturer`, else the integration's name, else `"Home Assistant <Domain>"` title
  cased (e.g. "Home Assistant Light"); Model = the device's `model`, else the domain title cased; FirmwareRevision =
  the device's `sw_version` or HA's version, digits only.
- HA registers its HomeKit bridge in its own device registry with `manufacturer: "Home Assistant"`, `entry_type:
  "service"`, a `mac` connection = the bridge's virtual HAP id (lowercase), identifiers `["homekit", <entry id>,
  "homekit.bridge"]`.
- **[proposal]** When `get_config.components` contains `homekit`, warn once that the same entities may already be in
  Apple Home through HA's bridge. Homeswift cannot read which entities that bridge includes **[unknown: no
  WebSocket command for the homekit filter was read]**.

### 9.2 HA's `homekit_controller` (HomeKit → HA) paired with Homeswift

If HA has paired Homeswift's own bridge, Homeswift's accessories come back as HA entities and would be re-exposed:
a true loop (writes echo). Recognise them:
- entity registry `platform == "homekit_controller"`, **and**
- its `unique_id` starts with Homeswift's **own HAP Device ID** (homekit_controller's unique ids are
  `<AccessoryPairingID>_<aid>_<iid>`, `<…>_<aid>` or `<…>_<aid>_<service iid>_<char iid>`, the pairing id being the
  accessory's `id` as sent during pairing — **[unknown: its case; compare case-insensitively]**), or its device has
  identifier `["homekit_controller:accessory-id", "<pairing id>:aid:<aid>"]` with that id, or any device whose
  `via_device_id` leads to such a device. Devices from external accessories (`context.publishExternal`, each its own
  HAP id) need the same test against every HAP id the bridge publishes.
- **Always exclude those** (not even an Accessory Setting brings them back). Other `homekit_controller` entities
  (an Ecobee, a third-party HomeKit device) are legitimate and stay.
- As a second guard **[proposal]**, also exclude a `homekit_controller` device whose `manufacturer` and `serial_number`
  equal those of an accessory Homeswift publishes.
- HA's `homekit_controller` already refuses to offer for pairing an mDNS HAP device whose id matches a device of its
  own `homekit` bridge (by the `mac` connection); it has no such check for Homeswift.

---

## 10. Vectors

| Input | Output |
|---|---|
| `brightness` 255 / 128 / 1 (on) | Brightness 100 / 50 / 1 (round(0.39) = 0 → 1) |
| Brightness 50 written | `light.turn_on {brightness_pct: 50}` |
| `color_temp_kelvin` 2700 | ColorTemperature 370 (floor 370.37) |
| ColorTemperature 370 written | `color_temp_kelvin` 2702 (floor 2702.70) |
| `min_color_temp_kelvin` absent, `max_…` absent | ColorTemperature range 153–500 |
| `current_tilt_position` 0 / 50 / 100 | tilt angle −90 / 0 / 90 |
| tilt angle 45 written | `tilt_position` 75 |
| climate 70 °F | 21.1 °C (70 − 32) × 5 / 9 = 21.11 |
| PM2.5 `"12"` | PM2_5Density 12, AirQuality 2 |
| CO2 `"1001"` | Level 1001, Detected 1 |
| lock `jammed` | LockCurrentState 2, target unchanged |
| alarm `armed_vacation` | Current 1, Target 1 |

---

## 11. Unknowns, collected

- `area_registry_updated` payload; the exact set of `get_config.state` values.
- The format of the zeroconf `uuid`, and no WebSocket command read returns it (§3, §4.4).
- The HA version that removed the mired light attributes (§7.1).
- HA's `color_temperature_to_rgbww` and `color_temperature_to_hs` formulas (not transcribed; use the repo's
  `ColorUtils` for kelvin → hs).
- The case of homekit_controller's `AccessoryPairingID` in unique ids (§9.2).
