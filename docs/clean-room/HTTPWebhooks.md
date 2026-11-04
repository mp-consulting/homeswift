# HTTPWebhooks: functional specification

## 0. Provenance

| | |
|---|---|
| Source | https://github.com/benzman81/homebridge-http-webhooks |
| Commit | `45b13fb1af213d960ee3d0f6259d2ff824a53787` (shallow clone of the default branch, read 2026-11-04) |
| npm package | `homebridge-http-webhooks`, version 0.2.0, display name "Homebridge Webhooks" |
| License | GPL-3.0 (`package.json` "license": "GPL-3.0"; `LICENSE` is the GNU GPL v3 text) |
| Copyright holders | No copyright line in the sources. `package.json` author: `benzman81`. The changelog credits contributors (among them jsiegenthaler, shirnschall, mgoeppl, NikDevx, emptygalaxy). |
| Runtime dependencies (for context only) | `http-auth` ^4.2.0 (basic auth), `node-persist` ^2.1.0 (state cache), `request` ^2.88.2 (outgoing calls), `selfsigned` ^2.4.1 (self-signed certificate) |

The spec writer wrote this document. It contains no source code. Interface identifiers (JSON keys, query parameter names, storage keys, literal response and identity strings) are reproduced because a drop-in replacement needs them. Everything else is described in my own words.

---

## 1. Overview

The plugin is a **static Homebridge platform**. At startup it builds a fixed list of accessories from arrays in its config block. It also starts **one HTTP (or HTTPS) server** that outside systems call to push state into HomeKit or read it back. When HomeKit writes a characteristic (the user taps a tile, say), the plugin can make an **outgoing HTTP request** that the user configured for that action. State is kept in a small key-value cache on disk, so reads after a restart return the last known values.

There is no discovery, no polling and no device protocol. Every accessory is virtual and driven only by webhooks and HomeKit.

---

## 2. Configuration interface

### 2.1 Platform

- Platform name (the `platform` value, also the schema's `pluginAlias`): **`HttpWebHooks`**. Plugin type is platform, and the schema marks it **singular** (one block per bridge).
- Homebridge also registers 15 per-kind *accessory* names with the same constructors (`HttpWebHookSensor`, `HttpWebHookSwitch`, `HttpWebHookPushButton`, `HttpWebHookDoorbell`, `HttpWebHookLight`, `HttpWebHookThermostat`, `HttpWebHookOutlet`, `HttpWebHookSecurity`, `HttpWebHookGarageDoorOpener`, `HttpWebHookStatelessSwitch`, `HttpWebHookLockMechanism`, `HttpWebHookWindowCovering`, `HttpWebHookFanv2`, `HttpWebHookCarbonDioxideSensor`, `HttpWebHookValve`). These cannot work on their own: they need the platform's shared storage and server and would fail without them. The documented use is the platform only. Treat the accessory registrations as unsupported (see Gaps).

### 2.2 Top-level options

Values are read with "value or default" semantics: any falsy value (missing, `""`, `0`, `false`, `null`) gets the default.

| JSON key | Type | Default | Meaning |
|---|---|---|---|
| `webhook_port` | number or numeric string (the schema types it as a string, e.g. `"51828"`; the schema says required) | `51828` | TCP port of the webhook server. |
| `webhook_listen_host` | string | `"0.0.0.0"` | Address to bind. `"::"` is a typical alternative for IPv6/dual stack. |
| `webhook_enable_cors` | boolean | `false` | Adds CORS headers and answers `OPTIONS` (see 4.3). Any truthy value enables it. |
| `cache_directory` | string (path) | `"./.node-persist/storage"`, relative to the Homebridge process's working directory | Directory of the persistent state cache (section 5). |
| `http_auth_user` | string | none | Basic auth user name. Auth is on only when **both** user and pass are non-empty. |
| `http_auth_pass` | string | none | Basic auth password. **Secret.** |
| `https` | boolean | `false` | HTTPS only when the value is exactly the JSON boolean `true` (the string `"true"` does not count). |
| `https_keyfile` | string (path) | none | PEM private key file. A self-signed certificate is used unless both `https_keyfile` and `https_certfile` are set. |
| `https_certfile` | string (path) | none | PEM certificate file. |
| `sensors` | array | `[]` | Sensors (2.4.1). |
| `switches` | array | `[]` | Switches (2.4.2). |
| `pushbuttons` | array | `[]` | Momentary switches (2.4.3). |
| `doorbells` | array | `[]` | Doorbells (2.4.4). |
| `lights` | array | `[]` | Dimmable lights (2.4.5). |
| `thermostats` | array | `[]` | Thermostats (2.4.6). |
| `outlets` | array | `[]` | Outlets (2.4.7). |
| `security` | array | `[]` | Security systems (2.4.8). |
| `garagedooropeners` | array | `[]` | Garage door openers (2.4.9). |
| `statelessswitches` | array | `[]` | Multi-button stateless switches (2.4.10). |
| `windowcoverings` | array | `[]` | Window coverings (2.4.11). |
| `lockmechanisms` | array | `[]` | Locks (2.4.12). |
| `fanv2s` | array | `[]` | Fans, Fanv2 service (2.4.13). |
| `co2sensors` | array | `[]` | Carbon dioxide sensors (2.4.14). |
| `valves` | array | `[]` | Valves (2.4.15). |

Array keys are all lowercase. `fanv2s`, `co2sensors` and `doorbells` are read by the code. The schema lists `doorbells`, `co2sensors` and `fanv2s` too.

### 2.3 The common "outgoing call" key group

Many kinds configure an outgoing HTTP call per action. Each action uses one prefix `<p>` (for example `on`, `off`, `push`, `brightness`, `open`, `close`, `open_20`, `set_state`, `set_target_temperature`, `speed`, `lock`, `target_state`...) and the same five keys:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `<p>_url` | string | `""` | URL to request. An empty URL means no request: the HomeKit write succeeds at once. |
| `<p>_method` | string | `"GET"` | HTTP method, sent as written. A body is attached only when the method is exactly `POST`, `PUT` or `PATCH` (uppercase, case-sensitive). |
| `<p>_body` | string | `""` | Raw request body (for POST/PUT/PATCH), sent verbatim. No Content-Type is added automatically: the user puts one in the headers. |
| `<p>_form` | string holding a JSON object | `""` | When set (and the method allows a body), it is parsed as JSON and sent as an `application/x-www-form-urlencoded` body. **Form wins over body.** Not in the schema, but read by the code and mentioned in the README. |
| `<p>_headers` | string holding a JSON object | `"{}"` | Request headers, for example `"{\"Authorization\": \"Bearer X\", \"Content-Type\": \"application/json\"}"`. It is a JSON *string*, not an object. |

Per-entry shared key:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `rejectUnauthorized` | boolean | `true` | Verify the TLS certificate of outgoing HTTPS calls. If absent, `true`. If present, verification stays on only when the value is exactly boolean `true`. Any other present value (`false`, `"true"`, `1`) turns it **off**. |

Every entry has `id` (string: the webhook key and the storage key, not the HomeKit identity) and `name` (string: the HomeKit display name **and** the identity seed, section 3.1).

### 2.4 Per-kind entry keys

#### 2.4.1 `sensors[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name` | string | | |
| `type` | string, one of `contact`, `motion`, `occupancy`, `smoke`, `temperature`, `humidity`, `airquality`, `light`, `leak` | none | Sensor kind. Any other value or a missing one creates an accessory with no primary service (broken: see Gaps). |
| `autoRelease` | boolean | false | Only for `contact`, `motion`, `occupancy`: return to the resting state after a delay. |
| `autoReleaseTime` | integer (ms) | `5000` (also when 0) | Delay before auto release. |

#### 2.4.2 `switches[]`
`id`, `name`, `rejectUnauthorized`, outgoing groups `on_*` and `off_*`.

#### 2.4.3 `pushbuttons[]`
`id`, `name`, `rejectUnauthorized`, outgoing group `push_*`.

#### 2.4.4 `doorbells[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name` | string | | |
| `single_press` | boolean | **true** | Allow event 0. |
| `double_press` | boolean | **true** | Allow event 1. (The README suggests these are off by default, but the code treats a missing value as true.) |
| `long_press` | boolean | **true** | Allow event 2. |

Only `double_press` and `long_press` are in the schema. `single_press` is read anyway.

#### 2.4.5 `lights[]`
`id`, `name`, `rejectUnauthorized`, groups `on_*`, `off_*`, `brightness_*`, plus:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `brightness_factor` | number | `1` (also when 0) | Scale between HomeKit's 0–100 and the target system. Outgoing value = ceil(HomeKit brightness × factor). Incoming webhook value is divided by the factor and rounded up. |

#### 2.4.6 `thermostats[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name`, `rejectUnauthorized` | | | |
| `minTemp` | number | `15` (also when 0) | TargetTemperature minValue. |
| `maxTemp` | number | `30` | TargetTemperature maxValue. |
| `minStep` | number | `0.5` | TargetTemperature minStep. |
| `set_target_temperature_*` | group | | Called when HomeKit sets the target temperature. |
| `set_target_heating_cooling_state_*` | group | | Called when HomeKit sets the target mode. |

Note: an old option name `maxValue` was renamed to `maxTemp` in 0.1.17. Only `minTemp`/`maxTemp`/`minStep` are read now.

#### 2.4.7 `outlets[]`
`id`, `name`, `rejectUnauthorized`, groups `on_*`, `off_*`.

#### 2.4.8 `security[]`
`id`, `name`, `rejectUnauthorized`, group `set_state_*`.

#### 2.4.9 `garagedooropeners[]`
`id`, `name`, `rejectUnauthorized`, groups `open_*`, `close_*`.

#### 2.4.10 `statelessswitches[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name` | string | | |
| `buttons` | array of objects | `[]` | One stateless programmable switch per element, in order. |
| `buttons[].name` | string | | Button name: the service's display name and the webhook's `buttonName`. |
| `buttons[].single_press` / `double_press` / `long_press` | boolean | each **true** | Events the button allows (`single_press` is not in the schema but is read). |

#### 2.4.11 `windowcoverings[]`
`id`, `name`, `rejectUnauthorized`, groups `open_*`, `open_20_*`, `open_40_*`, `open_60_*`, `open_80_*`, `close_*`, plus:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `auto_set_current_position` | boolean | false | After a successful HomeKit write, also set the current position to the target (section 6.11). |

#### 2.4.12 `lockmechanisms[]`
`id`, `name`, `rejectUnauthorized`, groups `open_*` (unlock) and `close_*` (lock).

#### 2.4.13 `fanv2s[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name`, `rejectUnauthorized` | | | |
| `on_*`, `off_*` | groups | | Active on/off. |
| `speed_*` | group | | RotationSpeed writes. |
| `speed_factor` | number | `1` (also when 0) | Outgoing speed = ceil(HomeKit speed × factor). |
| `enableLockPhysicalControls` | boolean | false | Adds LockPhysicalControls. |
| `lock_*`, `unlock_*` | groups | | Lock or unlock physical controls. |
| `enableTargetStateControls` | boolean | false | Adds TargetFanState. |
| `target_state_*` | group | | TargetFanState writes. |
| `enableSwingModeControls` | boolean | false | Adds SwingMode. |
| `swing_mode_*` | group | | SwingMode writes. |
| `rotation_direction_*` | group | | RotationDirection writes (the characteristic is always present). |

#### 2.4.14 `co2sensors[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name` | string | | |
| `co2_peak_level` | integer (ppm) | `1200` (also when 0) | Above this level (strictly greater), CarbonDioxideDetected is "abnormal". |

#### 2.4.15 `valves[]`
| Key | Type | Default | Meaning |
|---|---|---|---|
| `id`, `name`, `rejectUnauthorized` | | | |
| `type` | string: `generic valve`, `irrigation`, `shower head`, `water faucet` | `generic valve` | ValveType value 0, 1, 2, 3. Unknown or missing gives 0. |
| `on_*`, `off_*` | groups | | Active writes. |

---

## 3. Device model

### 3.1 Identity (stable ids)

- This is a static platform: Homebridge, not the plugin, derives each accessory's UUID, from the accessory's **display name**. The plugin sets no `uuid_base`.
- The seed is **`<platform value as written in the config block>:<name>`**, so normally **`HttpWebHooks:<name>`**. The UUID is HAP-NodeJS's name-based UUID of that seed (SHA-1 of the UTF-8 string, laid out as a UUID with the version nibble 4 and the variant bits 10). If a user wrote the qualified form `homebridge-http-webhooks.HttpWebHooks` in `platform`, that string is the prefix instead (see Gaps: this comes from Homebridge's behaviour, not from this repository).
- Consequences: renaming an entry changes its identity. Two entries with the same `name` (even of different kinds) collide. The `id` plays no part in the HomeKit identity.
- Vectors, computed by the spec writer from the algorithm above (check them against Homeswift's existing HAP-NodeJS-compatible UUID helper):
  - `HttpWebHooks:Switch name 1` → `18FAC0D0-4B38-4C83-A34A-31826F39AF3B`
  - `HttpWebHooks:Motion Sensor name 2` → `45B216E6-1783-40A6-A40D-8D5AD9C6A923`
- Services carry **no subtype** except: the doorbell's two services (subtypes `sps` and `db`) and the stateless switch's buttons (subtypes `"0"`, `"1"`, `"2"`... the zero-based index as a string).
- Accessories are created in this order (it matters only for the HTTP lookup when ids collide, section 4.2): sensors, switches, pushbuttons, doorbells, lights, thermostats, outlets, security, garagedooropeners, windowcoverings, statelessswitches, lockmechanisms, fanv2s, co2sensors, valves.

### 3.2 Accessory Information (every kind)

| Characteristic | Value |
|---|---|
| Manufacturer | `HttpWebHooksPlatform` |
| Model | `<ModelPrefix>-<name>` |
| SerialNumber | `<ModelPrefix>-<id>`, **except the doorbell, whose serial is the bare `id`** |
| Name | the entry's name (set by Homebridge) |
| FirmwareRevision | set by the host (Homebridge's version), not by the plugin |

ModelPrefix per kind: sensors `HttpWebHookSensorAccessory`; switch `HttpWebHookSwitchAccessory`; push button `HttpWebHookPushButtonAccessory`; doorbell `HttpWebHookDoorbellAccessory`; light `HttpWebHookLightAccessory` (note: not "LightBulb"); thermostat `HttpWebHookThermostatAccessory`; outlet `HttpWebHookOutletAccessory`; security `HttpWebHookSecurityAccessory`; garage `HttpWebHookGarageDoorOpenerAccessory`; stateless switch `HttpWebHookStatelessSwitchAccessory`; lock `HttpWebHookLockMechanismAccessory`; window covering `HttpWebHookWindowCoveringAccessory`; fan `HttpWebHookFanv2Accessory`; CO2 `HttpWebHookCarbonDioxideSensorAccessory`; valve `HttpWebHookValveAccessory`.

### 3.3 Services and characteristics per kind

Each primary service's display name is the entry's `name`. Characteristics not listed keep HAP's default props.

| Kind | Service | Characteristics handled (r = read handler, w = write handler) | Props set by the plugin |
|---|---|---|---|
| sensor `contact` | ContactSensor | ContactSensorState (r) | |
| sensor `motion` | MotionSensor | MotionDetected (r) | |
| sensor `occupancy` | OccupancySensor | OccupancyDetected (r) | |
| sensor `smoke` | SmokeSensor | SmokeDetected (r) | |
| sensor `humidity` | HumiditySensor | CurrentRelativeHumidity (r) | |
| sensor `temperature` | TemperatureSensor | CurrentTemperature (r) | minValue −100, maxValue 140 |
| sensor `airquality` | AirQualitySensor | AirQuality (r) | |
| sensor `light` | LightSensor | CurrentAmbientLightLevel (r) | |
| sensor `leak` | LeakSensor | LeakDetected (r) | |
| switch | Switch | On (r, w) | |
| pushbutton | Switch | On (r, w) | |
| doorbell | 1st: StatelessProgrammableSwitch, subtype `sps`; 2nd: Doorbell, subtype `db` | ProgrammableSwitchEvent on both | both get the same min/max/validValues from the press flags (below) |
| light | Lightbulb | On (r, w), Brightness (r, w) | |
| thermostat | Thermostat | TargetHeatingCoolingState (r, w), CurrentHeatingCoolingState (r), TargetTemperature (r, w), CurrentTemperature (r); TemperatureDisplayUnits is present (required) with no handler, so it keeps an in-memory value (default 0, Celsius) | TargetTemperature minValue = minTemp, maxValue = maxTemp, minStep = minStep |
| outlet | Outlet | On (r, w), OutletInUse (r) | |
| security | SecuritySystem | SecuritySystemTargetState (r, w), SecuritySystemCurrentState (r) | |
| garagedooropener | GarageDoorOpener | TargetDoorState (r, w), CurrentDoorState (r), ObstructionDetected (r) | |
| statelessswitch | one StatelessProgrammableSwitch per button (name = button name, subtype = index string). No ServiceLabel service. | ProgrammableSwitchEvent; ServiceLabelIndex (optional characteristic, added) = index + 1 | min/max from the press flags (below) |
| lockmechanism | LockMechanism | LockTargetState (r, w), LockCurrentState (r) | |
| windowcovering | WindowCovering | TargetPosition (r, w), CurrentPosition (r), PositionState (r) | |
| fanv2 | Fanv2 | Active (r, w), RotationSpeed (r, w), RotationDirection (r, w); LockPhysicalControls (r, w) only when `enableLockPhysicalControls`; TargetFanState (r, w) only when `enableTargetStateControls`; SwingMode (r, w) only when `enableSwingModeControls` | |
| co2sensor | CarbonDioxideSensor | CarbonDioxideLevel (r), CarbonDioxideDetected (r) | |
| valve | Valve | Active (r, w), InUse (r; the same handlers as Active are attached), StatusFault (r, optional characteristic added); ValveType set once to 0–3 from `type` | The accessory declares category 30 (HAP's shower-head category value); for a bridged accessory this barely matters |

**Press flags → ProgrammableSwitchEvent props** (0 single, 1 double, 2 long):

- Doorbell (both services): the advertised valid values are exactly the enabled events. minValue is the lowest enabled event and maxValue the highest. With all three flags false, no props are set at all (Gaps).
- Stateless switch buttons: minValue/maxValue as for the doorbell. Valid values are given explicitly only for the single+long combination (`[0, 2]`). For the other combinations only min and max are set (with single+double+long, 0..2). The intent is clearly "valid values = the enabled events". Whether HAP-NodeJS still advertised its default `[0,1,2]` valid-values list with a narrowed min/max is uncertain (Gaps). Advertising the enabled set is the safe reading.

---

## 4. The HTTP interface (incoming webhooks)

### 4.1 Server

- One server for the platform, started after the accessories are built, on `webhook_listen_host`:`webhook_port` (defaults 0.0.0.0:51828). It logs once that it started, with the port and host.
- Plain HTTP by default. HTTPS when `https` is `true` (section 4.6).
- **Every method** reaches the handler (GET, POST, PUT...). The **path is ignored**: only the query string counts, so `/`, `/anything?accessoryId=x` and so on all behave the same. The request body is read and **ignored**: parameters in a POST form body are not used.
- The query string is decoded the usual way (percent-decoding, `+` as space). A parameter repeated in the query arrives as a list and no longer equals the expected strings. Treat it as "not equal to `true`" and so on (it is a quirk, not a feature).
- Parameter names are **case-sensitive**.

### 4.2 Dispatch and generic responses

1. If `accessoryId` is missing or empty: status **404**, `Content-Type: text/plain`, body exactly `[ERROR Http WebHook Server] No accessoryId in request.`, and the same text is logged.
2. Otherwise the first accessory (in the order of 3.1) whose `id` **equals the string** `accessoryId` handles the request. A non-string `id` in the config (for example a JSON number) never matches.
3. No match: status **404**, `text/plain`, body `[ERROR Http WebHook Server] AccessoryId '<accessoryId>' not found.` (logged too).
4. Match: status **200**, `Content-Type: application/json`, body = the JSON object of the kind's handler (section 6). JSON keys whose value is undefined are left out.

(There is a third 404 text for "handler returned nothing", `[ERROR Http WebHook Server] AccessoryId '<id>' did not return a response body from 'changeFromServer'.`. Every kind always returns an object, so it is unreachable in practice.)

Parameter values compared with `"true"` are exact and case-sensitive: `TRUE`, `1` and `yes` are not true.

### 4.3 CORS

When `webhook_enable_cors` is set, every response (including errors) carries `Access-Control-Allow-Origin: *`, `Access-Control-Request-Method: *`, `Access-Control-Allow-Methods: OPTIONS, GET, POST` and `Access-Control-Allow-Headers: *`. An `OPTIONS` request gets **200 with an empty body** and nothing else happens. With basic auth on, authentication runs before this, so an unauthenticated preflight gets 401.

### 4.4 Authentication

- HTTP Basic, on only when both `http_auth_user` and `http_auth_pass` are non-empty. The realm is `Auth required`. Credentials must equal the configured values exactly.
- Missing or wrong credentials: **401** with a `WWW-Authenticate: Basic realm="Auth required"` challenge. The handler does not run. (The exact body is the auth library's default HTML page, see Gaps. Scripts should rely only on the status.)
- Auth applies to every request, OPTIONS included.

### 4.5 Query parameters per kind

| Kind | Parameters |
|---|---|
| sensors (contact/motion/occupancy/smoke) | `state` = `true`/`false` |
| sensors (temperature/humidity/airquality/light/leak) | `value` = number |
| switch | `state` |
| pushbutton | `state` (only `true` does anything) |
| doorbell | `event` = 0/1/2 |
| light | `state`, `value` (brightness in the target system's scale) |
| thermostat | `currenttemperature`, `targettemperature`, `currentstate` (0 off, 1 heat, 2 cool), `targetstate` (0 off, 1 heat, 2 cool, 3 auto) |
| outlet | `state`, `stateOutletInUse` |
| security | `currentstate` (0 stay, 1 away, 2 night, 3 disarmed, 4 triggered), `targetstate` (0 stay, 1 away, 2 night, 3 disarm) |
| garagedooropener | `currentdoorstate` (0 open, 1 closed, 2 opening, 3 closing, 4 stopped), `targetdoorstate` (0 open, 1 closed), `obstructiondetected` (0/1) |
| statelessswitch | `buttonName`, `event` (0/1/2) |
| lockmechanism | `lockcurrentstate` (0 unsecured, 1 secured, 2 jammed, 3 unknown), `locktargetstate` (0/1) |
| windowcovering | `currentposition`, `targetposition` (0–100), `positionstate` (0 decreasing, 1 increasing, 2 stopped) |
| fanv2 | `state`, `speed`, `swingMode`, `rotationDirection`, `lockstate`, `targetState` (note the mixed case) |
| co2sensor | `value` (ppm) |
| valve | `state`, `statusFault` (`true`/`false`) |

Section 6 gives each kind's exact semantics and response.

### 4.6 HTTPS

- With `https_keyfile` **and** `https_certfile` set: both files are read at startup as PEM key and certificate. An unreadable file is a startup failure.
- Otherwise the plugin uses an automatic self-signed certificate. It is generated once and kept in the state cache under key `http-webhook-ssl-cert`, as an object with the PEM `private` key, `public` key, `cert`, a creation `timestamp` (ms since epoch) and `certVersion` = 2. It is valid for **365 days**. Its subject attributes name `homebridgeHttpWebhooks.com`, and its subjectAltName DNS entries are `homebridgeHttpWebhooks.com` and `localhost`. At startup the cached certificate is replaced when it is more than 364 days old or its `certVersion` is not 2. There is no renewal while running.
- HTTPS and basic auth combine freely.

---

## 5. State persistence

- Store: a flat key → JSON-value cache in `cache_directory` (node-persist 2.x layout, one file per key: see Gaps for the exact on-disk format). It is read and written synchronously. All accessories share it.
- Values keep their JSON type. **Values that came from a webhook are stored as the raw query strings** (for example `"21.5"`, `"1"`). Values that came from HomeKit writes are stored as numbers or booleans. Plugin-computed values are booleans or numbers. Readbacks echo whatever is stored (so numbers may come back as JSON strings).
- Keys (`<id>` is the entry's `id`):

| Kind | Keys |
|---|---|
| sensors, switch, light, outlet, valve, fan (power) | `http-webhook-<id>` |
| light | `http-webhook-brightness-<id>` |
| outlet | `http-webhook-<id>-inUse` |
| valve | `http-webhook-<id>-statusFault` |
| thermostat | `http-webhook-current-temperature-<id>`, `http-webhook-target-temperature-<id>`, `http-webhook-current-heating-cooling-state-<id>`, `http-webhook-target-heating-cooling-state-<id>` |
| security | `http-webhook-current-security-state-<id>`, `http-webhook-target-security-state-<id>` |
| garage | `http-webhook-current-door-state-<id>`, `http-webhook-target-door-state-<id>`, `http-webhook-obstruction-detected-<id>` |
| lock | `http-webhook-lock-current-state-<id>`, `http-webhook-lock-target-state-<id>` |
| window covering | `http-webhook-current-position-<id>`, `http-webhook-target-position-<id>`, `http-webhook-position-state-<id>` |
| fan | `http-webhook-speed-<id>`, `http-webhook-swingmode-<id>`, `http-webhook-rotationdirection-<id>`, `http-webhook-lockstate-<id>`, `http-webhook-targetstate-<id>` |
| CO2 | `http-webhook-carbon-dioxide-level-<id>`, `http-webhook-carbon-dioxide-detected-<id>` |
| platform | `http-webhook-ssl-cert` |

- Push buttons, doorbells and stateless switches store nothing.
- Because keys contain only the `id`, two entries of different kinds that share an `id` share cache keys.
- HomeKit reads are answered from the store, with the per-kind defaults of section 6 when a key is absent.

### 5.1 Outgoing call semantics (shared by all kinds)

When HomeKit writes a characteristic that has an outgoing group:

1. The plugin first updates the store as section 6 says. (This happens **before** the request, so a failed request still leaves the new value stored, except where noted.)
2. If the selected URL is empty, the write succeeds at once.
3. Otherwise the plugin makes one request: the method from `<p>_method`, the headers from the JSON in `<p>_headers`, and for POST/PUT/PATCH the form (if `<p>_form` is non-empty, urlencoded) or else the raw body (if `<p>_body` is non-empty). TLS verification follows `rejectUnauthorized`. Timeout **10 s** (window coverings **35 s**). Redirects follow the HTTP library's default for GET (see Gaps).
4. The HomeKit write's answer **waits for the request**. A 2xx status succeeds. Anything else (non-2xx, connection error, timeout) answers HomeKit with an error (a communication failure) and runs the kind's failure hook, if it has one.
5. Placeholders: a substitution replaces **only the first occurrence** of the token. Each kind lists where tokens apply. There is no URL-encoding of substituted values. Booleans substitute as `true`/`false`, numbers in their shortest decimal form (`21`, `21.5`).
6. Invalid JSON in `<p>_headers` or `<p>_form` makes that write fail.
7. Webhook-driven changes never trigger outgoing calls. The plugin only pushes values to HomeKit, which does not count as a HomeKit write.

---

## 6. Behaviour per kind

Notation: "push X" means updating characteristic X's value and notifying HomeKit subscribers, without running the write handler. "Readback" is the response when the kind's state parameters are absent.

### 6.1 Sensors

- Kinds based on booleans: contact, motion, occupancy, smoke. They read `state`. A `state` that is present (even an empty string) counts as given, and the value is `state == "true"`.
- Kinds based on numbers: temperature, humidity, airquality, light, leak. They read `value`, which counts as given whenever present.
- Readback (parameter absent): `{"success": true, "state": <stored>}`. For a missing key, the stored value is taken as `false` for the boolean kinds and `0` for the numeric ones. The numeric kinds return the stored raw string, for example `{"success":true,"state":"21.5"}`.
- When given, the new value (a boolean, or the raw string for the numeric kinds) **is stored on every call**. Only when it differs from the previous stored value (strictly: `"21.5"` and `"21.50"` differ) is it pushed:
  - contact: true → ContactSensorState 0 (CONTACT_DETECTED), false → 1 (NOT_DETECTED).
  - motion: MotionDetected = the value.
  - occupancy: true → 1 (OCCUPANCY_DETECTED), false → 0.
  - smoke: true → 1 (SMOKE_DETECTED), false → 0.
  - humidity → CurrentRelativeHumidity, temperature → CurrentTemperature, airquality → AirQuality, leak → LeakDetected: the value converted to a number.
  - light: CurrentAmbientLightLevel = the value parsed as a float.
- Response when given: `{"success": true}`.
- Auto release (contact/motion/occupancy with `autoRelease` set): **only when the value changed**, whatever the new value is, a timer of `autoReleaseTime` ms is started. When it fires it stores and pushes the resting state. Contact rests at **true / CONTACT_DETECTED (0)**, motion at **false**, occupancy at **false / 0**. Earlier timers are not cancelled when a new event arrives, so an older timer can release a later trigger early. Smoke has no auto release.
- HomeKit reads: a missing key reads as `false`. contact/smoke/occupancy map the boolean to the enumerations above. Light sensors read as a float, and a missing or false value reads as **0.0001** (HAP's minimum). The other kinds return the stored value converted to the characteristic's type (missing → 0 or false).

### 6.2 Switch

- Readback (`state` absent or empty): `{"success": true, "state": <stored boolean, default false>}`.
- `state` given: store `state == "true"`. If it differs from the stored value, push On. Response `{"success": true}`.
- HomeKit write On: store the value, then call `on_*` for true or `off_*` for false (5.1). HomeKit read: stored, default false.

### 6.3 Push button

- `state` absent or empty: `{"success": true}` (no state field).
- `state == "true"`: push On = true, then 1 s later push On = false. Any other value does nothing. Response `{"success": true}`.
- HomeKit read On: always false.
- HomeKit write On = false: succeeds, nothing else.
- HomeKit write On = true: with `push_url` empty, it succeeds and On is pushed back to false 1 s later. Otherwise the plugin calls `push_*`. When the call ends, **success or failure**, On is pushed back to false 1 s later. The HomeKit answer follows the call's result.
- Nothing is stored.

### 6.4 Doorbell

- If `event` is present and non-empty, the plugin goes through the two services (programmable switch `sps` first, doorbell `db` second). For each it checks that `event`, as a number, is among that service's valid values. If it is **not**, the plugin stops at once (before any push) and answers **200** with `{"error": "event value <event> is outside of valid values: <v1>,<v2>,..."}` (the valid values joined by commas, no spaces) and logs a warning. If it is valid, ProgrammableSwitchEvent = event is pushed on both services (one log line, for the doorbell).
- Otherwise, or after the pushes: `{"success": true}`.
- No readback state. Nothing is stored. A missing `event` simply answers success.

### 6.5 Light

- Readback (`state` and `value` both absent or empty): `{"success": true, "brightness": <stored, default -1>, "state": <stored boolean, default false>}`.
- Otherwise:
  - brightness = `value` if non-empty, else the stored brightness (default −1). state = `state` if non-empty, else the stored state. The boolean state is "true" (string) or true (stored boolean).
  - Store the boolean state and brightness as an integer (truncated parse of `value`).
  - If the state changed, or the integer brightness differs from the stored one: push On = state **and** Brightness = ceil(brightness ÷ `brightness_factor`), both together.
  - Response `{"success": true}`.
  - So sending only `value` does **not** turn the light on: the stored state is kept.
- HomeKit write On: store it, then call `on_*` or `off_*`. No placeholders in these.
- HomeKit write Brightness b: store state = (b > 0) and brightness = b (in **HomeKit** scale, while webhooks store the target scale: a known inconsistency). Compute out = ceil(b × factor). In `brightness_url`, replace `%statusPlaceholder` with true/false (b > 0) and `%brightnessPlaceholder` with out. Make the same substitution in `brightness_form` if it is set, else in `brightness_body`. Then call.
- HomeKit reads: On = stored, default false. Brightness = 0 when the stored state is false, else the stored brightness (default 100), as an integer.

### 6.6 Thermostat

- For each of `currenttemperature`, `targettemperature`, `currentstate`, `targetstate` that is present: store the raw string, and if it differs from the previous stored value (defaults 0, 10, 0 (OFF), 0 (OFF)), push CurrentTemperature, TargetTemperature, CurrentHeatingCoolingState or TargetHeatingCoolingState respectively, converted to a number. For the two states, an empty string is stored but not pushed.
- Response always `{"success": true}`. There is **no readback** of state.
- HomeKit write TargetTemperature t: store t, replace `%f` in `set_target_temperature_url` with t (URL only, not body or form), then call.
- HomeKit write TargetHeatingCoolingState s: store s, replace `%b` in `set_target_heating_cooling_state_url` with s (URL only), then call.
- HomeKit reads: target temperature default **20**, current temperature default **20**, target state default 0, current state default 0.

### 6.7 Outlet

- Readback (`state` and `stateOutletInUse` both absent or empty): `{"success": true, "state": <bool, default false>, "stateOutletInUse": <bool, default false>}`.
- Each non-empty parameter is stored as `== "true"` and pushed to On or OutletInUse respectively when it changed. Response `{"success": true}`.
- HomeKit write On: store, then call `on_*` or `off_*`. Reads: stored, default false.

### 6.8 Security system

- Readback (`currentstate` and `targetstate` both absent or empty): `{"success": true, "currentState": <stored current, default 3>}`. There is no target in the readback.
- `currentstate` present: store the raw value. If it differs from the stored current (default 3, DISARMED), push SecuritySystemCurrentState.
- `targetstate` present: store it. If it differs from the stored target (default 3, DISARM), push SecuritySystemTargetState.
- Response `{"success": true}`.
- HomeKit write target n (0–3): store **both target and current** = n, replace `%d` in `set_state_url` with n (URL only), call. On success push SecuritySystemCurrentState = n. On failure there is no push, but the store already says current = n.
- HomeKit reads: target default 3, current default 3.

### 6.9 Garage door opener

- For each of `currentdoorstate` (default 1 CLOSED), `targetdoorstate` (default 1 CLOSED) and `obstructiondetected` (default false) that is present: remember the previously stored value, store the new raw value, and if it differs and is non-empty, push CurrentDoorState, TargetDoorState or ObstructionDetected (the obstruction string "1"/"true" → true, "0"/"false" → false).
- Response: `{"success": true, "currentState": <prev>, "targetState": <prev>, "obstruction": <prev>}`. Each field is the value stored **before** this call, and is included **only if its parameter was present**. So a call with no parameters returns only `{"success": true}`, and the response never shows the new value. Example: the first `?accessoryId=g&currentdoorstate=0` returns `{"success":true,"currentState":1}`.
- HomeKit write TargetDoorState v: store target = v. open = (v == 0). Call `open_*` when opening, else `close_*`. On success push TargetDoorState and CurrentDoorState = 0 (open) or 1 (closed). **The current door state is not stored** on this path, so a later HomeKit read of CurrentDoorState still returns the old stored value. There is no failure hook.
- HomeKit reads: target default 1, current default 1, obstruction default false. These reads log at info level (not debug) in the original.

### 6.10 Stateless switch

- When `event` is present and non-empty: every service whose Name equals `buttonName` exactly gets ProgrammableSwitchEvent = event pushed, with no validation against the flags. Several buttons with the same name all fire.
- Response always `{"success": true}`, even when no button matched or `buttonName` is missing.
- Quirk not to replicate: the original also compares the Accessory Information service's name, so a `buttonName` equal to the accessory's own name would push an event on the information service.

### 6.11 Window covering

- `currentposition` present: store the raw value. If it differs from the previous value (default 100), push CurrentPosition (even when empty).
- `targetposition` present: store. If it differs (default 100) and is non-empty, push TargetPosition.
- `positionstate` present: store. If it differs (default false) and is non-empty, push PositionState.
- Response: `{"success": true, "CurrentPosition": <prev>, "TargetPosition": <prev>, "PositionState": <prev>}`. These are capitalised keys holding the **previous** stored values, each only if its parameter was present (the same pattern as the garage door).
- HomeKit write TargetPosition p (integer 0–100): store target = p. If `auto_set_current_position` is set, also store current = p **now**. Pick the group: p = 0 → `open_*`; 1–25 → `open_20_*`; 26–45 → `open_40_*`; 46–65 → `open_60_*`; 66–94 → `open_80_*`; ≥ 95 → `close_*`. (This is the literal mapping. In HomeKit terms 0 is fully closed, so the plugin's "open" group is used at position 0. Keep the mapping as is for compatibility.) No placeholders. Timeout 35 s. On success push TargetPosition = p, and if auto is set, push CurrentPosition = p **1 s later**. There is no failure hook.
- HomeKit reads: target default 100, current default 100, position state default 2 (STOPPED).

### 6.12 Lock mechanism

- `lockcurrentstate` present: store. If it differs from the previous value (default 1 SECURED) and is non-empty, push LockCurrentState.
- `locktargetstate` present: the same with LockTargetState (default 1).
- Response: `{"success": true, "currentState": <prev>, "targetState": <prev>}`, only for parameters present (the same pattern as the garage door).
- HomeKit write LockTargetState v: lock = (v == 1). Store target = v. Locking calls `close_*`, unlocking calls `open_*`.
  - On success: store current = 1 (lock) or 0 (unlock), push LockTargetState and LockCurrentState to match.
  - On failure: store current = **3 (UNKNOWN)**, push LockTargetState = the requested value and LockCurrentState = 3, and HomeKit gets an error.
- HomeKit reads: target default 1, current default 1.

### 6.13 Fanv2

Webhook (response always `{"success": true}`, no readback):

- **Active**: on **every** call, the plugin pushes Active = 1 if `state == "true"`, otherwise 0. That includes calls without `state`, so a call that only sends `speed` turns the fan off in HomeKit. The one exception: no push when `state` loosely equals the stored power value (for example `state=1` with stored 1, or `state=0` with stored 0 or false). The webhook does **not** store the power state. This is the original's observable behaviour and looks unintended (Gaps).
- `speed` present: integer parse. If it differs from the stored speed (loosely), push RotationSpeed with it (**no** factor division, **not stored**).
- `swingMode` present and swing mode enabled: integer parse. If it differs from the stored value, push SwingMode (not stored).
- `rotationDirection` present: integer parse. If it differs, push RotationDirection (not stored).
- `lockstate` present and lock controls enabled: the original reads the value from a differently cased parameter (`lockState`), gets "not a number" and always pushes an invalid value. The documented intent is to push LockPhysicalControls from `lockstate` (Gaps).
- `targetState` present and target-state controls enabled: integer parse. If it differs, push TargetFanState (not stored).

HomeKit writes:

- Active v: store v, call `on_*` if truthy, else `off_*`.
- RotationSpeed s: store power = (s > 0) as a boolean and speed = s. out = ceil(s × `speed_factor`). In `speed_url`, replace `%statusPlaceholder` (true/false) and `%speedPlaceholder` (out), and the same in `speed_form` if set, else in `speed_body`. Then call.
- LockPhysicalControls v: store, call `lock_*` if truthy, else `unlock_*`. No placeholders.
- TargetFanState v: store, replace `%targetState` with v in `target_state_url` **and** `target_state_body` (not form), call.
- SwingMode v: store, replace `%swingMode` in `swing_mode_url` and `swing_mode_body`, call.
- RotationDirection v: store, replace `%rotationDirection` in `rotation_direction_url` and `rotation_direction_body`, call.

HomeKit reads: Active = stored power (default false → 0). RotationSpeed = 0 if power is falsy, else the stored speed (default 100), as an integer. LockPhysicalControls, TargetFanState, SwingMode and RotationDirection = stored, default 0.

### 6.14 CO2 sensor

- `value` absent: `{"success": true, "state": 0}`. The original's readback reads a key it never writes (`http-webhook-<id>`), so it effectively always returns 0 (Gaps: a replacement may return the stored level, but byte-for-byte compatibility means 0).
- `value` present: detected = (value as a number > `co2_peak_level`). Store the raw level and the detected boolean. Because the comparison base is always 0 (see above), it effectively **always pushes** CarbonDioxideLevel = value and CarbonDioxideDetected = 1 (ABNORMAL) if detected, else 0 (NORMAL). Response `{"success": true}`.
- HomeKit reads: level = stored, default 0. Detected = 1 or 0 from the stored boolean, default 0.

### 6.15 Valve

- Readback (`state` and `statusFault` both absent or empty): `{"success": true, "state": <stored number, default 0>, "statusFault": <stored number, default 0>}`.
- `state` non-empty: n = 1 if `"true"`, else 0. Store n, log at info level. If it changed, push Active = n and InUse = n.
- `statusFault` non-empty: n the same way. Store n, log. If it changed, push StatusFault = n.
- Response `{"success": true}`.
- HomeKit write Active v: store v, push Active = v and InUse = v at once, then call `on_*` if v is truthy, else `off_*`.
- HomeKit reads: Active and InUse = stored (default 0). StatusFault = stored (default 0).

---

## 7. Logging (paraphrased)

- Startup: the server started, with port and host. For automatic HTTPS: it uses an automatic certificate, and when it makes one, that it generated a new certificate.
- HTTP errors: request and response stream errors are logged with the reason. Missing or unknown `accessoryId` logs the same text as the 404 body.
- Webhook-driven changes (info level): "<name>: changing HomeKit <characteristic or state> for <kind> to <value>". One per push. The doorbell logs once per press with the event number. The stateless switch logs button name and event. A doorbell event that is not allowed logs a warning with the allowed values.
- HomeKit writes (info level): "<name>: <what> for <id>...". The window covering also logs the new target, and the lock whether it is locking.
- HomeKit reads: debug level (garage reads at info level).
- Outgoing calls: when a form or body is attached, the plugin logs "adding form/body" **with its full content**. When the call ends: the URL, the status code (−1 if none), the response body and any error.
- Sensor and CO2 webhooks log debug detail (incoming value, previous cached value, whether it changed).

**Secrets**: `http_auth_pass` (and arguably `http_auth_user`). The content of every `*_headers` string (it usually holds `Authorization: Bearer ...` or API keys), and possibly `*_body`/`*_form` and `*_url` (tokens in query strings). The original logs URLs, bodies, forms and response bodies verbatim. A replacement should not log headers, and should mask credentials in URLs, bodies and forms. The self-signed private key in the cache is a secret too. Note for the porter: in Homeswift only `http_auth_pass` has a secret-named key. The tokens inside `*_headers` strings sit under keys that do not look like secrets.

---

## 8. Test vectors

### 8.1 Example config block

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "http_auth_user": "hook",
  "http_auth_pass": "s3cret",
  "sensors": [
    { "id": "motion1", "name": "Hall Motion", "type": "motion", "autoRelease": true, "autoReleaseTime": 2000 },
    { "id": "temp1", "name": "Attic Temperature", "type": "temperature" },
    { "id": "door1", "name": "Front Door", "type": "contact" }
  ],
  "switches": [
    { "id": "switch1", "name": "Switch name 1",
      "on_url": "http://10.0.0.5/relay?on=1", "off_url": "http://10.0.0.5/relay?on=0" }
  ],
  "pushbuttons": [ { "id": "bell", "name": "Gate Button", "push_url": "http://10.0.0.6/pulse", "push_method": "POST",
                     "push_body": "{\"pulse\":true}", "push_headers": "{\"Content-Type\":\"application/json\"}" } ],
  "doorbells": [ { "id": "db1", "name": "Doorbell", "double_press": false, "long_press": false } ],
  "lights": [ { "id": "light1", "name": "Desk Lamp", "brightness_factor": 2.55,
                "brightness_url": "http://10.0.0.7/set?on=%statusPlaceholder&bri=%brightnessPlaceholder" } ],
  "thermostats": [ { "id": "th1", "name": "Living Thermostat",
                     "set_target_temperature_url": "http://10.0.0.8/t?target=%f",
                     "set_target_heating_cooling_state_url": "http://10.0.0.8/m?mode=%b" } ],
  "outlets": [ { "id": "out1", "name": "Kettle" } ],
  "security": [ { "id": "alarm", "name": "Alarm", "set_state_url": "http://10.0.0.9/mode/%d" } ],
  "garagedooropeners": [ { "id": "garage", "name": "Garage", "open_url": "http://10.0.0.10/open", "close_url": "http://10.0.0.10/close" } ],
  "statelessswitches": [ { "id": "remote", "name": "Remote", "buttons": [ { "name": "Up" }, { "name": "Down", "long_press": false } ] } ],
  "windowcoverings": [ { "id": "blind", "name": "Blind", "open_url": "http://x/o", "open_40_url": "http://x/o40", "close_url": "http://x/c", "auto_set_current_position": true } ],
  "lockmechanisms": [ { "id": "lock", "name": "Front Lock", "open_url": "http://x/unlock", "close_url": "http://x/lock" } ],
  "fanv2s": [ { "id": "fan", "name": "Ceiling Fan", "speed_url": "http://x/fan?s=%speedPlaceholder", "speed_factor": 0.03 } ],
  "co2sensors": [ { "id": "co2", "name": "CO2", "co2_peak_level": 1000 } ],
  "valves": [ { "id": "tap", "name": "Garden Tap", "type": "irrigation" } ]
}
```

Identity: "Switch name 1" → seed `HttpWebHooks:Switch name 1` → `18FAC0D0-4B38-4C83-A34A-31826F39AF3B`. Serial `HttpWebHookSwitchAccessory-switch1`, model `HttpWebHookSwitchAccessory-Switch name 1`. Doorbell serial `db1`. Doorbell ProgrammableSwitchEvent valid values `[0]`. Remote buttons: "Up" subtype "0", label index 1, events 0..2; "Down" subtype "1", label index 2, events 0..1.

### 8.2 Requests (all with valid basic auth unless stated; fresh, empty cache)

| # | Request | Status, body | HomeKit effect / store |
|---|---|---|---|
| 1 | `GET /?accessoryId=switch1` without credentials | 401, `WWW-Authenticate: Basic realm="Auth required"` | none |
| 2 | `GET /` | 404 text/plain `[ERROR Http WebHook Server] No accessoryId in request.` | none |
| 3 | `GET /?accessoryId=nope` | 404 text/plain `[ERROR Http WebHook Server] AccessoryId 'nope' not found.` | none |
| 4 | `GET /?accessoryId=switch1` | 200 `{"success":true,"state":false}` | none |
| 5 | `POST /whatever?accessoryId=switch1&state=true` | 200 `{"success":true}` | On → true pushed; store `http-webhook-switch1` = true; **no** outgoing call |
| 6 | `GET /?accessoryId=switch1` | 200 `{"success":true,"state":true}` | |
| 7 | `GET /?accessoryId=switch1&state=TRUE` | 200 `{"success":true}` | stored false, On → false pushed |
| 8 | HomeKit writes On=true on Switch name 1 | — | store true; GET `http://10.0.0.5/relay?on=1`; the write succeeds on 2xx and fails on other statuses or after 10 s |
| 9 | `?accessoryId=motion1&state=true` | `{"success":true}` | MotionDetected true; after 2 s MotionDetected false and store false |
| 10 | `?accessoryId=temp1&value=21.5` then `?accessoryId=temp1` | `{"success":true}` then `{"success":true,"state":"21.5"}` | CurrentTemperature 21.5 |
| 11 | `?accessoryId=door1&state=false` | `{"success":true}` | ContactSensorState 1 (not detected, open) |
| 12 | `?accessoryId=bell&state=true` | `{"success":true}` | On true, then false after 1 s; no call |
| 13 | `?accessoryId=db1&event=0` | `{"success":true}` | event 0 pushed on the programmable switch and doorbell services |
| 14 | `?accessoryId=db1&event=1` | 200 `{"error":"event value 1 is outside of valid values: 0"}` | none |
| 15 | `?accessoryId=light1&state=true&value=255` | `{"success":true}` | On true, Brightness ceil(255/2.55) = 100; store state true, brightness 255 |
| 16 | `?accessoryId=light1` | `{"success":true,"brightness":255,"state":true}` | |
| 17 | HomeKit sets Brightness 50 on Desk Lamp | — | store state true, brightness 50; GET `http://10.0.0.7/set?on=true&bri=128` (ceil(127.5)) |
| 18 | `?accessoryId=th1&currenttemperature=19.5&targetstate=1` | `{"success":true}` | CurrentTemperature 19.5, TargetHeatingCoolingState 1 |
| 19 | HomeKit sets TargetTemperature 21.5 | — | GET `http://10.0.0.8/t?target=21.5` |
| 20 | `?accessoryId=out1&stateOutletInUse=true` then `?accessoryId=out1` | `{"success":true}` then `{"success":true,"state":false,"stateOutletInUse":true}` | OutletInUse true |
| 21 | `?accessoryId=alarm` | `{"success":true,"currentState":3}` | |
| 22 | HomeKit sets SecuritySystemTargetState 1 | — | store target and current 1; GET `http://10.0.0.9/mode/1`; on 2xx SecuritySystemCurrentState → 1 |
| 23 | `?accessoryId=garage&currentdoorstate=0` | `{"success":true,"currentState":1}` | CurrentDoorState 0; stored "0" |
| 24 | `?accessoryId=garage&currentdoorstate=1` | `{"success":true,"currentState":"0"}` | CurrentDoorState 1 |
| 25 | `?accessoryId=garage` | `{"success":true}` | |
| 26 | `?accessoryId=remote&buttonName=Down&event=2` | `{"success":true}` | ProgrammableSwitchEvent 2 pushed on "Down" (not validated) |
| 27 | HomeKit sets TargetPosition 40 on Blind | — | store target 40, current 40; GET `http://x/o40` (35 s timeout); on 2xx push TargetPosition 40, then 1 s later CurrentPosition 40 |
| 28 | HomeKit sets TargetPosition 0 | — | GET `http://x/o` (the "open" group) |
| 29 | `?accessoryId=blind&currentposition=50` (after 27) | `{"success":true,"CurrentPosition":40}` | CurrentPosition 50 |
| 30 | HomeKit sets LockTargetState 0, and `http://x/unlock` returns 500 | — | write fails; store target 0, current 3; push target 0 and current 3 (UNKNOWN) |
| 31 | `?accessoryId=lock&locktargetstate=1` | `{"success":true,"targetState":0}` | LockTargetState 1 (previous stored target was 0 from #30) |
| 32 | `?accessoryId=fan&speed=40` | `{"success":true}` | RotationSpeed 40 **and Active 0** (quirk 6.13) |
| 33 | HomeKit sets RotationSpeed 100 on Ceiling Fan | — | store power true, speed 100; GET `http://x/fan?s=3` |
| 34 | `?accessoryId=co2&value=1500` then `?accessoryId=co2` | `{"success":true}` then `{"success":true,"state":0}` | CarbonDioxideLevel 1500, Detected 1 |
| 35 | `?accessoryId=tap&state=true` then `?accessoryId=tap` | `{"success":true}` then `{"success":true,"state":1,"statusFault":0}` | Active 1, InUse 1; ValveType 1 |
| 36 | `OPTIONS /` with CORS enabled and no auth configured | 200, empty body, the four CORS headers | none |

---

## 9. Gaps and uncertainties

1. **Identity seed** comes from Homebridge's handling of static platforms (prefix = the `platform` value as written, then `:`, then the accessory `name`), not from this repository. Confirm against Homeswift's existing support for static Homebridge platforms before relying on it. The two UUID vectors were computed by the spec writer.
2. **On-disk cache format** belongs to node-persist 2.x (not in the repository): I could not check whether each key is a file named by the key or by a hash, or whether the file holds the bare JSON value or a wrapper with key and TTL. A migration of existing state needs that checked separately. The default directory is relative to Homebridge's working directory, not its storage path.
3. **401 body and headers** come from `http-auth` 4.x defaults (an HTML page in my recollection). Only the status and challenge are certain.
4. **Redirect handling, keep-alive and the default User-Agent** of outgoing calls are those of the `request` library (it follows redirects for GET by default). Not specified by the plugin.
5. **Self-signed certificate details** (key algorithm and size, signature hash, the exact subject attribute layout) are the `selfsigned` library's defaults. The plugin sets only the name attribute, 365 days and the two DNS SANs.
6. **ProgrammableSwitchEvent props for stateless switches**: whether HAP-NodeJS kept advertising the default valid values `[0,1,2]` while min/max were narrowed is not established. With all three press flags false, neither kind sets props (the doorbell would then fail validation), which is undefined behaviour.
7. **Fan webhook quirks** (6.13): Active is pushed (to 0 unless `state=true`) on every call, the webhook stores nothing for the fan, and `lockstate` is read from `lockState`, which always yields an invalid number. These are faithful to the source but almost certainly unintended. The porter must choose between bug-compatibility and the documented intent (README: `lockstate`, `targetState`, `swingMode`, `rotationDirection`, `speed` each push their characteristic).
8. **CO2 readback** always returns `"state": 0` because it reads a key the CO2 kind never writes. For the same reason every value is pushed. This is likely a bug.
9. **Garage door**: on a successful HomeKit write the current door state is pushed but not stored, so a later read returns the stale stored value. Likely a bug.
10. **Values coming from webhooks are not validated** (non-numeric temperatures, positions over 100, invalid enum values). The original hands them to HAP-NodeJS, which coerces, clamps or warns depending on its version. The light's −1 default brightness can reach HomeKit as −1 or 0.
11. **Sensor with a missing or unknown `type`**: the original builds an accessory without a primary service (Homebridge then errors). A replacement should skip it with an error.
12. **Duplicate `id`s**: only the first in the order of 3.1 receives webhooks, and kinds that share an `id` share cache keys.
13. **Per-kind accessory registrations** (`HttpWebHookSwitch` and the others, as accessory blocks) cannot work without the platform. Not supported.
14. HAP-NodeJS's own timeout for a slow `set` handler (outgoing calls can take up to 10 s or 35 s) affects how HomeKit sees a slow write. That is the host's behaviour, not the plugin's.
15. TemperatureDisplayUnits on the thermostat is neither handled nor persisted: it resets to the default on restart.
