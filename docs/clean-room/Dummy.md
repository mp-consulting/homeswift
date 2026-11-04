# Dummy — functional specification (clean room)

## 0. Provenance

| Item | Value |
|---|---|
| Source | https://github.com/mpatfield/homebridge-dummy |
| npm package | `homebridge-dummy`, version 2.1.4 (current major: 2) |
| Commit | `95303ec3ba044ac67bcf8c72ad9bfa8cb6fe2b84` (2026-10-30) |
| Legacy versions also read | tags `v0.9.2` (last `"accessory": "DummySwitch"` version) and `v1.7.0` (last version with the legacy-config migrator) |
| License | Apache License 2.0 (`LICENSE`, `"license": "Apache-2.0"` in package.json) |
| Copyright holders | Author `mpatfield` (package.json `author`); the original 0.x plugin was created by `nfarina` (credited in README). The LICENSE file carries no explicit copyright line. Vendored third-party code: `lib/fakegato-history` (fakegato-history 0.6.7, © 2017 simont77, credited in README). |
| Homebridge identifiers | plugin name `homebridge-dummy`, platform name `HomebridgeDummy`, display alias `Homebridge Dummy`, legacy accessory name `DummySwitch` |

This document was written by the spec writer; it contains no source code. Interface identifiers (JSON keys, enum values,
characteristic names, file names) are quoted because a drop-in replacement must match them.

Terminology used below:

- **identifier** — the accessory's stable string identity (section 3.1).
- **default state** — the state an accessory rests in (e.g. Off for a switch whose `defaultState` is not `"on"`).
- **trigger** — put the accessory in its *non-default* state ("opposite" state).
- **reset** — put the accessory back in its *default* state.
- **stored properties** — the per-identifier key/value persistence of section 6.

---

## 1. Plugin shape

- One platform block, `"platform": "HomebridgeDummy"`. The schema marks it `singular` (one block per bridge in the UI),
  but the runtime does not enforce that.
- All accessories are declared in the block's `accessories` array. Accessories are dynamic (cached) platform accessories;
  cached accessories that no longer match a configured identifier are removed at startup.
- Optional embedded HTTP(S) webhook server shared by every accessory that enables it (section 9).
- Optional per-accessory: auto-attached sensor, schedule, auto-reset, fade-out, time limiter, trigger conditions
  (other accessories' states, log-file patterns, network reachability), shell commands, periodic sync command,
  push notifications (two cloud APIs), Eve history.
- Two protocols per accessory: `HomeKit` (default) and `Matter` (only Switch, Outlet, Lightbulb).

---

## 2. Configuration interface

### 2.1 Platform block (top level)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Must be `"HomebridgeDummy"`. |
| `name` | string | `"Homebridge Dummy"` (schema default; the companion UI writes this on first install) | Platform instance name; not used for identity. |
| `accessories` | array of accessory objects | `[]` | The accessories (2.2). Entries without `name` are skipped silently. |
| `verbose` | boolean | `false` | When `true`, debug-level messages are logged (startup environment line, condition evaluation, webhook payloads, history entries, reachability changes, notification request/response dumps). |
| `webhookConfig` | object | `{}` | Webhook server options (2.10). |
| `webhookPort` | number | — | **Deprecated.** Port of the webhook server; used only when `webhookConfig.port` is absent. The companion UI moves it into `webhookConfig.port`. |
| `_bridge` | object | — | Homebridge child-bridge settings; not read by the plugin. |

### 2.2 Accessory object (`accessories[]`)

Common keys (apply to every type unless stated):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | absent | Stable identity. If absent, an identity is derived from type and name (3.1). The companion UI writes a random v4 UUID (lowercase, hyphenated) into every accessory lacking one, so most real configs have it. An empty string is used as-is (not treated as absent). |
| `name` | string | **required** | Display name. Missing → accessory skipped. |
| `type` | string enum | **required** | One of the 21 types in section 4. Unknown → error logged "unsupported accessory type", no services built (see quirk Q1). |
| `protocol` | `"HomeKit"` \| `"Matter"` | `"HomeKit"` | Matter supported only for `Switch`, `Outlet`, `Lightbulb`. Any other string → warning listing the valid values, accessory skipped. |
| `groupName` | string | absent | Non-empty → this accessory becomes one service of a shared "group" accessory (3.3). Ignored with a warning for Matter (accessory skipped). |
| `sensor` | object | absent | Attach a sensor service (2.3). HomeKit only. |
| `schedule` | schedule object (2.4) | absent | When to **trigger**. |
| `autoReset` | schedule object (2.4) | absent | When to **reset**. |
| `syncSchedule` | schedule object (2.4) | absent | When to run `commandSync`. Required when `commandSync` is set (else error "missing required field 'syncSchedule'" and sync disabled). |
| `commandSync` | string (shell command) | absent | Sync command (8.3). |
| `notification` | object (2.5) | absent | Push notification on trigger and/or reset. |
| `limiter` | object (2.6) | absent | Maximum total time in the non-default state per period. |
| `conditions` | object (2.7) | absent | Trigger/reset from other accessories, log lines, or reachability. |
| `simulation` | object (2.8) | absent | Open/close motion simulation for Door, GarageDoorOpener, Window, WindowCovering. |
| `fadeOut` | object (2.9) or legacy boolean | absent | Lightbulb (dimmer) brightness count-down. |
| `resetOnRestart` | boolean | `false` | `true` → the accessory starts in its default state after a restart (stored state is not restored). Otherwise the accessory is **stateful**. |
| `enableWebhook` | boolean | `false` | Register this accessory's webhooks (section 9). |
| `enableWebook` | boolean | — | **Deprecated misspelling** of `enableWebhook`; either one `true` enables webhooks. UI migrates it. |
| `enableHistory` | boolean | `false` | Eve history and Eve extra characteristics (section 10). HomeKit only. |
| `disableLogging` | boolean | `false` | Suppress this accessory's routine informational logs (state changes, timers, command output, push success, webhook registration). Errors/warnings still logged. |

Type-specific keys:

| Key | Types | Type / values | Default | Meaning |
|---|---|---|---|---|
| `defaultState` | Switch, Outlet, Lightbulb, Valve, HumidifierDehumidifier | `"on"` \| `"off"` | off | Resting state. Any other value → warning listing valid values, treated as off. |
| `defaultOn` | Switch, Outlet, Lightbulb | boolean | — | **Deprecated** (pre-1.4). Only the UI migrates it (`true` → `defaultState: "on"`, else `"off"`). The runtime ignores it. |
| `isDimmer` | Lightbulb | boolean | `false` unless `defaultBrightness` present | Adds Brightness. |
| `defaultBrightness` | Lightbulb | number | — | **Deprecated.** Its mere presence (any value) makes the bulb a dimmer when `isDimmer` is absent. Its value is not used. |
| `defaultLockState` | LockMechanism | `"locked"` \| `"unlocked"` | locked | Resting state. Invalid → warning, locked. |
| `defaultPosition` | Door, GarageDoorOpener, Window, WindowCovering | `"open"` \| `"closed"` | closed | Resting position. Invalid → warning, closed. |
| `temperatureUnits` | Thermostat, TemperatureSensor | `"C"` \| `"F"` | `"C"` | Units of config temperatures and webhook temperatures, and the displayed unit. Invalid → warning. |
| `defaultThermostatState` | Thermostat | `"auto"` \| `"heat"` \| `"cool"` \| `"off"` | off | Initial target mode. Invalid → warning. |
| `defaultTemperature` | Thermostat | number (in `temperatureUnits`) | 20 °C | Initial target temperature. A value of `0` is treated as absent. |
| `minimumTemperature` / `maximumTemperature` | Thermostat | number (in `temperatureUnits`) | 10 °C / 38 °C | Range of current and target temperature. `0` is honoured here. |
| `validStates` | Thermostat | array of `"off"`,`"heat"`,`"cool"`,`"auto"` | all four | Restrict selectable modes. Not an array → warning, all four. Contains an unknown string → warning, all four. |
| `humidifierType` | HumidifierDehumidifier | `"humidifier"` \| `"dehumidifier"` | humidifier | Invalid → warning (treated as humidifier). |
| `valveType` | Valve | `"generic"` \| `"faucet"` \| `"irrigation"` \| `"shower"` | generic | Invalid → warning (treated as generic). |
| `commandOn` / `commandOff` | Switch, Outlet, Lightbulb, Valve, HumidifierDehumidifier, Thermostat; `commandOn` also StatelessProgrammableSwitch | string | — | Shell commands (8.1). |
| `commandLock` / `commandUnlock` | LockMechanism | string | — | |
| `commandOpen` / `commandClose` | Door, GarageDoorOpener, Window, WindowCovering | string | — | |
| `commandActive` / `commandInactive` | the 7 top-level sensor types | string | — | |
| `commandHumidity` | HumiditySensor | string | — | Run when humidity changes. |
| `commandTemperature` | TemperatureSensor, Thermostat | string | — | Run when (target, for Thermostat) temperature changes. |

Unknown keys are ignored.

### 2.3 `sensor` (attached sensor add-on)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `type` | `"CarbonDioxideSensor"`, `"CarbonMonoxideSensor"`, `"ContactSensor"`, `"LeakSensor"`, `"MotionSensor"`, `"OccupancySensor"`, `"SmokeSensor"` | **required** | Missing → error, no sensor. Invalid → error listing valid types, no sensor. |
| `behavior` | `"MIRROR"` \| `"TIMER"` | `"MIRROR"` | Invalid → error, no sensor. See 7.5. |
| `timerControlled` | boolean | — | **Deprecated.** `true` forces `TIMER` regardless of `behavior`. UI migrates (`behavior` = TIMER if true else MIRROR, unless behavior already set). |

A pre-1.1 string form (`"sensor": "MotionSensor"`) is **not** accepted by the current version (it fails the `type` requirement and is reported as missing).

### 2.4 Schedule object (`schedule`, `autoReset`, `syncSchedule`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `type` | `"TIMEOUT"`, `"INTERVAL"`, `"CRON"`, `"SUNRISE"`, `"SUNSET"`, `"DAWN"`, `"DUSK"`, `"GOLDEN_HOUR"`, `"NIGHT"` | **required** | Missing → error, schedule disabled. Unknown → error listing valid types. |
| `time` | integer ≥ 1 | required for TIMEOUT/INTERVAL | Duration amount. Missing → error mentioning `delay`. |
| `units` | `"MILLISECONDS"`, `"SECONDS"`, `"MINUTES"`, `"HOURS"` | required for TIMEOUT/INTERVAL | Missing → error; invalid → error listing valid units. |
| `random` | boolean | `false` | Randomise each duration, `time` being the maximum (7.2). |
| `cron` | string | required for CRON | A preset (`"@secondly"`, `"@minutely"`, `"@hourly"`, `"@daily"`, `"@weekly"`, `"@weekdays"`, `"@weekends"`, `"@monthly"`, `"@yearly"`), the literal `"CRON_CUSTOM"`, or (accepted by the runtime though not offered by the UI) a raw cron expression. |
| `cronCustom` | string | required when `cron` is `"CRON_CUSTOM"` | Cron expression (7.3). |
| `offset` | number (minutes, may be negative) | 0 | Added to a sun event time. The UI offers −45, −30, −20, −15, −10, −5…−1, +1…+5, +10, +15, +20, +30, +45, but any number works. |
| `latitude`, `longitude` | number (decimal degrees) | required for sun types | Location for sun events. Missing → error, schedule disabled. The only location source. |

Legacy schedule form: an object containing a `delay` key is read as `{type: TIMEOUT, time: delay, units, random}` (all other keys dropped).

### 2.5 `notification`

| Key | Type | Meaning |
|---|---|---|
| `api` | `"PINGIE_NOTIFY"` \| `"PUSHOVER"` | **required**. Missing → error. Invalid → warning, notifications disabled. |
| `token` | string (**secret**) | Notify!: the user's API token. Pushover: the **user key**. Required for both. |
| `id` | string | Notify!: device or group id (required). Pushover: optional **application token** (**secret**). |
| `title` | string | Title of the trigger notification (optional). |
| `text` | string | Body of the trigger notification. Absent → no trigger notification. |
| `resetTitle` | string | Title of the reset notification (optional). |
| `resetText` | string | Body of the reset notification. Absent → no reset notification. |
| `groupType` | string | Notify! only, passed through. |
| `iconURL` | string | Notify! only; default is an icon URL on getnotifyapp.com (`https://icons.getnotifyapp.com/icons/mt1lwzhb-coo64058.png`). |

At least one of `text`/`resetText` must be non-blank, else a warning naming both keys and notifications are disabled.
Missing `token` (or `id` for Notify!) → error per missing key, disabled.

### 2.6 `limiter`

| Key | Type | Meaning |
|---|---|---|
| `limit` | number | **required**. Allowed total time in the non-default state per period, in `units`. |
| `units` | `"SECONDS"`, `"MINUTES"`, `"HOURS"` (runtime also accepts `"MILLISECONDS"`) | **required**. Invalid → error. |
| `period` | `"HOUR"`, `"DAY"`, `"WEEK"`, `"MONTH"` | **required**. Invalid → error. |
| `resetOnRestart` | boolean | `true` → usage is not restored after restart. |
| `id` | string | **Deprecated**; only used to find usage stored by older versions (6.3). |

Validation: missing key → error per key; if `limit` converted to milliseconds exceeds the period length (HOUR 1 h, DAY 24 h,
WEEK 7 days, MONTH 31 days) → error "limit exceeds period", limiter disabled.

### 2.7 `conditions`

| Key | Type | Meaning |
|---|---|---|
| `operator` | `"and"` \| `"or"` | **required**. UI labels: "ALL conditions are met" / "ANY conditions are met". |
| `operands` | array (≥1) of operand objects | **required**. |

Operand:

| Key | Type | Applies to | Meaning |
|---|---|---|---|
| `type` | `"ACCESSORY"`, `"LOG"`, `"PING"` | all | **required**. |
| `accessoryId` | string | ACCESSORY | The **identifier** (section 3.1) of another Dummy accessory. Required. Must not equal this accessory's own identifier (error "cannot reference itself", conditions disabled). |
| `accessoryState` | `"on"`, `"off"`, `"open"`, `"closed"`, `"locked"`, `"unlocked"` | ACCESSORY | Required. Desired state of that accessory. |
| `pattern` | string | LOG | Required. Regular expression (JavaScript syntax); if it does not compile it is matched as a literal substring. |
| `pingHost` | string | PING | Required. Hostname, IP address, URL (its host part is used), or MAC address (`aa:bb:cc:dd:ee:ff` or with `-`, any case). |
| `pingAvailability` | `"AVAILABLE"` \| `"NOT_AVAILABLE"` | PING | Desired reachability. Anything other than `NOT_AVAILABLE` (including absent) means AVAILABLE. |
| `checkInterval` | integer ≥ 1 | PING | Check period amount; default 60. |
| `checkUnits` | units enum (2.4) | PING | Default SECONDS. |
| `pingInterval` / `pingUnits` | | PING | **Deprecated** aliases of `checkInterval` / `checkUnits`, used when those are absent. |

Validation: every operand needs `type` plus its required keys; any failure → conditions disabled (error per missing key).
More than one LOG operand with operator `and` → error, conditions disabled.

### 2.8 `simulation` (Door, GarageDoorOpener, Window, WindowCovering)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | **required** when the object is present (missing → error, simulation off) | `true` → simulate movement. |
| `time` | integer ≥ 1 | 15 | Duration of a full movement. |
| `units` | units enum | SECONDS | |

### 2.9 `fadeOut` (Lightbulb with brightness)

| Key | Type | Meaning |
|---|---|---|
| `type` | `"FIXED"` \| `"INCREMENTAL"` | FIXED: the fade from the current brightness to 0 takes `time`. INCREMENTAL ("egg timer"): each 1 % step takes `time` (total = `time` × brightness). |
| `time` | integer ≥ 1 | |
| `units` | units enum | |

All three required (missing → error per key, fade disabled). Ignored when the bulb is not a dimmer.
Legacy boolean form (pre-1.7): if `fadeOut` is a boolean (true **or** false — the runtime does not distinguish) and
`autoReset` is a TIMEOUT with `time` and `units`, it is read as `{type: FIXED, time: autoReset.time, units: autoReset.units}`
and the `autoReset` is discarded; otherwise `fadeOut` is discarded. (The companion UI performs the same rewrite but only
for `true`.)

### 2.10 `webhookConfig`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `port` | number | 63743 | Listening port. A non-number → error, default used. |
| `disableSSL` | boolean | `false` | `true` → always plain HTTP. |
| `key` | string (file path) | from Homebridge UI | PEM private key file. |
| `cert` | string (file path) | from Homebridge UI | PEM certificate file. |
| `pfx` | string (file path) | from Homebridge UI | PKCS#12 bundle; takes precedence over key/cert. |
| `passphrase` | string (**secret**) | from Homebridge UI | Passphrase for `pfx`. |

Non-string `key`/`cert`/`pfx`/`passphrase` → error naming the parameter, value dropped.
Note: the published schema lists `keyPath` and `certPath`, but the runtime never reads those two names; only `key`/`cert` work.

Defaults come from Homebridge's own config.json: the plugin reads the `platforms` entry whose `platform` is `"config"`
(homebridge-config-ui-x) and takes its `ssl` object (`key`, `cert`, `pfx`, `passphrase`, `selfSigned`) and `lang`. When
`ssl.selfSigned` is `true`, missing key/cert default to `<directory of config.json>/ssl-certs/private-key.pem` and
`.../ssl-certs/certificate.pem`. Plugin `webhookConfig` values override the UI's. Failure to read config.json → warning, no
defaults.

### 2.11 Legacy configuration

**`"accessory": "DummySwitch"` blocks (v0.9.x and earlier).** The current version registers only the platform and does
**not** read these blocks at runtime; Homebridge would report them as an unknown accessory. Until v1.7.0 the companion UI
offered a one-shot migrator (removed in 1.7.1). Its mapping, for reference, from each top-level `accessories[]` entry with
`"accessory": "DummySwitch"` into the `HomebridgeDummy` platform's `accessories`:

| Legacy key (v0.9.2) | Meaning in v0.9.2 | Migrated to |
|---|---|---|
| `name` (required) | name | `name` |
| — | — | `id`: a fresh random UUID (so HomeKit identity was **not** preserved by the official migration) |
| `dimmer` (bool, default false) | Lightbulb with Brightness instead of Switch | `type: "Lightbulb"`, `isDimmer: true`; otherwise `type: "Switch"` |
| `reverse` (bool) | default state is On | `defaultState: "on"` |
| `stateful` (bool) | keep state, never auto-off, persisted | no `autoReset` |
| `time` (number, ms; schema default 1000) | auto-off delay when not stateful | if not stateful and `time` truthy: `autoReset: {type: TIMEOUT, time, units: MILLISECONDS, random}` |
| `random` (bool) | random delay in [0, time] | `autoReset.random` |
| `resettable` (bool) | restart the timer when turned on again | dropped (the new auto-reset always restarts) |
| `brightness` (int 0–100) | initial brightness | dropped |
| `disableLogging` (bool) | | `disableLogging` |
| `_bridge` (child bridge) | | copied to the platform's `_bridge` if the platform has none |

It also wrote `config.json.bak` before rewriting. Legacy v0.9.2 identity and persistence, in case a replacement wants to
honour such blocks directly (this is Homebridge's accessory-plugin behaviour, not this plugin's code, so verify against
Homebridge): the bridged accessory UUID is HAP-NodeJS's name-based UUID (3.2) of `"DummySwitch:" + (uuid_base or name)`;
v0.9.2 stored state in node-persist under keys `homebridge-dummy:<name with whitespace→'_' lowercased>_state` (string
`"true"`/`"false"`) and `..._brightness` (number as string); its Serial Number was `Dummy-<name with whitespace→'-'>`,
Manufacturer "Homebridge", Model "Dummy Switch"/"Dummy Dimmer" (exact English model strings not verified).

**Deprecated keys still honoured by the current runtime:** `webhookPort`, `enableWebook`, `defaultBrightness` (as dimmer
flag), boolean `fadeOut`, `sensor.timerControlled`, schedule `delay`, operand `pingInterval`/`pingUnits`, `limiter.id`,
stored key `Timer` (6.3). Keys the runtime ignores and only the companion UI migrates: `defaultOn`. Removed in 1.8.0 and no
longer read: the pre-1.5 per-accessory `timer` object (replaced by `autoReset`).

---

## 3. Identity

### 3.1 Accessory identifier

- If `id` is present (any string, even empty): the identifier is `id` verbatim.
- Otherwise: `HomebridgeDummy:<type>:<name with every whitespace run removed>` (JavaScript `\s`, which includes Unicode
  spaces and NBSP). Example: `{"name": "My Switch", "type": "Switch"}` → `HomebridgeDummy:Switch:MySwitch`.

The identifier is used for: the HomeKit accessory UUID, the grouped service subtype, the Serial Number, stored properties,
webhook `id`, condition `accessoryId`, the Matter UUID, command environment variable names, the limiter hash, the history
file name.

### 3.2 HomeKit accessory UUID

UUID = HAP-NodeJS's name-based UUID of the identifier string: take the SHA-1 digest of the UTF-8 bytes as 40 lowercase hex
digits h[0..39]; output `h[0..7]-h[8..11]-4h[12..14]-Yh[16..18]-h[19..30]` where Y is the hex digit
`(value of h[15] AND 3) OR 8`. (The literal `4` consumes no digest digit.) Homebridge's cached-accessory UUIDs equal this
value, so preserving it keeps HomeKit rooms/scenes/automations.

| Identifier string | UUID |
|---|---|
| `HomebridgeDummy:Switch:MySwitch` | `8c1a1e2a-e4ee-432a-acc4-74e1053649de` |
| `3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f` | `f76a7be0-5e66-4b53-8c02-8da11fc4ad3b` |
| `HomebridgeDummy:Group:LivingRoom)}` | `c2d8b53c-f535-47da-973d-eee490dcbff7` |

The cached accessory's context holds `identifier` (the string above); that is how cached accessories are matched.

### 3.3 Group accessories

All HomeKit accessories sharing a non-empty `groupName` are services of one accessory:

- Group identifier: `HomebridgeDummy:Group:<groupName with whitespace removed>)}` — note the literal two characters `)}`
  appended (an artefact of the original, but it is what determines the UUID, so it must be reproduced exactly).
  Example: `"Living Room"` → `HomebridgeDummy:Group:LivingRoom)}`.
- Accessory display name = `groupName` (set only when first created).
- AccessoryInformation: Manufacturer `Homebridge Dummy`, Model `GroupAccessory`, Serial Number = the group accessory's
  UUID string, Firmware Revision = plugin version.
- Each member contributes its primary service with **subtype = member identifier**, service name = member `name`, plus the
  optional ConfiguredName characteristic set to `name`. Name and ConfiguredName are written only when the service is first
  created (later renames in config do not change them).
- Services whose subtype is not among the current members (or whose type changed for the same subtype) are removed.
- Members keep their own identifier for storage, webhooks and conditions. Groups are built after all ungrouped
  accessories, in order of first appearance of each group name; members in config order.

### 3.4 Accessory Information (ungrouped HomeKit accessories)

Written at every startup: Name = `name`, ConfiguredName = `name` (on the information service), Manufacturer =
`Homebridge Dummy`, Model = the `type` string (e.g. `Switch`), Serial Number = identifier (full length), Firmware Revision =
plugin version (2.1.4 at this commit). If the cached display name differs from `name`, it is updated.

The primary service is created without a service name and without subtype. On startup, any service on the accessory whose
type is one of the 21 Dummy types but is neither the current primary type nor the configured `sensor.type` is removed; when
no `sensor` is configured, all 7 sensor-type services other than the primary are removed (net effect: exactly the primary
service plus at most one sensor add-on service).

### 3.5 Matter identity

Matter accessories use the same name-based UUID function over the identifier (Homebridge's Matter API). Serial number = the
identifier if ≤ 32 characters, else its first 31 characters followed by `…`. Manufacturer `HomebridgeDummy`, model = type,
software version = plugin version. Matter accessories are not HomeKit accessories (they are exposed only over Matter).

---

## 4. Device model

Value encodings below are HAP's. "Stored key" is the stored-property key (section 6) holding the persisted state.

### 4.1 On/off family

| type | Service | Characteristics | Default | Stored key |
|---|---|---|---|---|
| `Switch` | Switch | On (r/w) | `defaultState` (off) | `On` (bool) |
| `Outlet` | Outlet | On (r/w) (OutletInUse is not managed) | idem | `On` |
| `Lightbulb` | Lightbulb | On (r/w); Brightness (r/w, 0–100 %) only when dimmer — removed from a cached service when not | idem; brightness 100 | `On`, `Brightness` (number) |

Lightbulb brightness: initial value = stored `Brightness` if any (read even when `resetOnRestart`), else 100. Reading
Brightness returns the fading value while a fade runs, else the brightness. A write equal to the current brightness is
ignored. Turning a dimmer off re-publishes its stored brightness (so after a fade the brightness shows its pre-fade value).

### 4.2 `StatelessProgrammableSwitch` (button)

Service StatelessProgrammableSwitch, characteristic ProgrammableSwitchEvent (events only; 0 single, 1 double, 2 long
press). No state, no persistence. `resetOnRestart`, autoReset, limiter are meaningless (UI hides them).

### 4.3 `LockMechanism`

LockTargetState (r/w) and LockCurrentState (read) always equal. SECURED = 1, UNSECURED = 0. Default SECURED unless
`defaultLockState: "unlocked"`. Stored key `LockTargetState` (0/1).

### 4.4 Position family

| type | Service | Target / current | Values | Extra |
|---|---|---|---|---|
| `Door` | Door | TargetPosition (r/w) / CurrentPosition | 0 (closed) or 100 (open) | PositionState always STOPPED (2) |
| `Window` | Window | idem | idem | idem |
| `WindowCovering` | WindowCovering | idem | idem | idem |
| `GarageDoorOpener` | GarageDoorOpener | TargetDoorState (r/w) / CurrentDoorState | OPEN = 0, CLOSED = 1 (current also OPENING 2 / CLOSING 3 during simulation) | ObstructionDetected always false; no PositionState |

Positions are binary: any written target equal to the "closed" value is closed; anything else becomes fully open (100,
or OPEN for the garage). E.g. writing TargetPosition 40 yields 100. Default closed unless `defaultPosition: "open"`. Stored
key `TargetPosition` (0/100) or, for the garage, `TargetDoorState` (0/1). CurrentPosition equals target except during
simulation (7.7).

### 4.5 `Valve`

Service Valve: ValveType (read): generic 0, irrigation 1, shower 2, faucet 3. Active (r/w) and InUse (read) always equal
(0/1). IsConfigured reads CONFIGURED (1). Default Active per `defaultState`. Stored key `On` (number 1/0).
When `autoReset` is a TIMEOUT with `time` and `units`: SetDuration (r/w, props min 1, max 3600 s) and RemainingDuration
(read) are added (7.9).

### 4.6 `HumidifierDehumidifier`

Service HumidifierDehumidifier:
- Active (r/w), default per `defaultState`. Stored key `On` (1/0).
- TargetHumidifierDehumidifierState: valid values restricted to the single value matching `humidifierType`
  (HUMIDIFIER 1 or DEHUMIDIFIER 2), minStep 1; reads return that value; writes are accepted and ignored.
- CurrentHumidifierDehumidifierState (read): INACTIVE 0 when Active is 0; else HUMIDIFYING 2 (humidifier) or
  DEHUMIDIFYING 3 (dehumidifier).
- Threshold: RelativeHumidityHumidifierThreshold (humidifier) or RelativeHumidityDehumidifierThreshold (dehumidifier),
  r/w = target humidity, default 50. Stored key `TargetRelativeHumidity`.
- CurrentRelativeHumidity (read): the last value set by webhook/sync, otherwise mirrors the target humidity. Stored key
  `CurrentRelativeHumidity`.

### 4.7 `Thermostat`

Service Thermostat:
- TemperatureDisplayUnits: reads 1 (F) when `temperatureUnits` is `"F"`, else 0 (C). Not writable in effect (writes do not
  change what is read).
- TargetHeatingCoolingState (r/w): valid values = `validStates` mapped off 0, heat 1, cool 2, auto 3, ascending. Default =
  `defaultThermostatState` (off).
- CurrentHeatingCoolingState (read): valid values = the same minus auto. Default = `defaultThermostatState` unless it is
  auto/absent → off.
- CurrentTemperature and TargetTemperature: min/max props = configured min/max converted to °C (defaults 10/38 °C).
  TargetTemperature (r/w) default `defaultTemperature` (20 °C). CurrentTemperature mirrors the target until a value is set
  by webhook/sync.
- Stored keys: `CurrentHeatingCoolingState`, `TargetHeatingCoolingState`, `CurrentTemperature`, `TargetTemperature`
  (all in °C for temperatures).
- Conversions: F→C = (F − 32) × 5/9 (not rounded); C→F = round(C × 9/5 + 32).
- Thermostats do not support schedule, autoReset, limiter, conditions or the sensor add-on (attempting a trigger or reset
  is an internal error; the UI hides these sections).

### 4.8 Value sensors

| type | Service / characteristic | Range | Initial | Stored key |
|---|---|---|---|---|
| `TemperatureSensor` | TemperatureSensor / CurrentTemperature (°C, HAP default props −270…100) | webhook range −270…100 °C (−454…212 °F) | stored value if stateful, else 0 | `CurrentTemperature` |
| `HumiditySensor` | HumiditySensor / CurrentRelativeHumidity | 0…100 | stored value if stateful, else 0 | `CurrentRelativeHumidity` |

Read-only; only webhook/sync change them. No trigger/reset (no schedule, autoReset, limiter, conditions).

### 4.9 Binary sensors (top-level)

| type | Characteristic | Inactive / active value |
|---|---|---|
| `CarbonDioxideSensor` | CarbonDioxideDetected | 0 normal / 1 abnormal |
| `CarbonMonoxideSensor` | CarbonMonoxideDetected | 0 / 1 |
| `ContactSensor` | ContactSensorState | 0 detected (closed) / 1 not detected (open) |
| `LeakSensor` | LeakDetected | 0 / 1 |
| `MotionSensor` | MotionDetected | false / true (booleans) |
| `OccupancySensor` | OccupancyDetected | 0 / 1 |
| `SmokeSensor` | SmokeDetected | 0 / 1 |

Default inactive. Stored key = the characteristic name (e.g. `MotionDetected`). Initial value = stored value if stateful,
else inactive. Trigger → active, reset → inactive. They have no manual control: only schedule, webhook/sync (and
autoReset/limiter). If neither `schedule` nor `enableWebhook` is set, a warning says the sensor can never trigger.
They do not report state to conditions.

### 4.10 Matter mapping (protocol `Matter`)

| type | Matter device type | Clusters |
|---|---|---|
| `Switch` | OnOffSwitch | onOff |
| `Outlet` | OnOffOutlet | onOff |
| `Lightbulb` (not dimmer) | OnOffLight | onOff |
| `Lightbulb` (dimmer) | DimmableLight | onOff + levelControl (min level 1, max 254) |

onOff commands on/off set the state; level ↔ brightness: level = round(brightness/100 × 253) + 1; incoming
moveToLevelWithOnOff level L → brightness round((L − 1)/253 × 100). No groups, no sensor add-on, no history for Matter.
Every other feature (schedule, autoReset, fade, limiter, conditions, commands, webhooks, notifications) works the same.
Requires the host to have Matter available and enabled, else a warning and the accessory is skipped.

---

## 5. Startup and lifecycle

1. Read optional language and SSL defaults from Homebridge's config.json (2.10). Language: the UI's `lang`; empty or
   `auto` → the system locale's language; supported `en`, `de`, `el`, `es`, `ru`, `vi`, else English.
2. On "launch finished": load stored properties (section 6), then for each configured accessory in order: skip if no
   `name`; default protocol HomeKit; HomeKit + `groupName` → defer to its group; else find the cached accessory by
   identifier or create and register a new one (log "adding new HomeKit accessory"), build the accessory, register its
   webhooks if enabled.
3. Build groups (3.3).
4. Remove cached accessories whose identifier is not in the configured set (log "removing HomeKit accessory").
5. Start the webhook server if at least one webhook is registered.
6. On shutdown: stop all timers, cron jobs, faders, reachability checks, the log watcher, and close the webhook server.

Each accessory, after construction (deferred to the next event-loop turn for on/off and valve types), restores its state
when stateful (section 6.2) and reports its initial state to the condition engine (section 7.6).

---

## 6. Persistence

### 6.1 Store

A single key/value store in Homebridge's `persist/` directory (node-persist), one datum under the key `HomebridgeDummy`
whose value is a **JSON string** encoding an array of pairs `[identifier, [[propertyKey, value], …]]`. Values are booleans,
numbers, strings, arrays or flat objects. Every change rewrites the whole datum (writes are serialised). Unparseable data
is ignored (empty store). A replacement that wants to inherit existing Homebridge state needs to read this datum (node-persist
names the file after a hash of the key — see Gaps).

### 6.2 What is stored, and restoring

Per identifier:

| Key | Written when | Restored at startup |
|---|---|---|
| `On`, `Brightness`, `LockTargetState`, `TargetPosition`, `TargetDoorState`, sensor characteristic keys, `CurrentRelativeHumidity`, `TargetRelativeHumidity`, `CurrentHeatingCoolingState`, `TargetHeatingCoolingState`, `CurrentTemperature`, `TargetTemperature` | on each change of that value (always, even with `resetOnRestart`) | only when stateful (`resetOnRestart` not true); restoring goes through the normal "set" path, which re-runs triggered/reset bookkeeping (resuming timers, see 7.1) but runs commands only where noted |
| `SetDuration` (valve, seconds) | when HomeKit writes it, or on first run from the autoReset time | always |
| `Schedule`, `AutoReset`, `SyncSchedule` | expiry time (epoch milliseconds) of a running TIMEOUT timer; removed when it fires or is cancelled | read always; used the next time that timer is started |
| `Timer` | (legacy, pre-1.5 auto-reset expiry) | read as fallback for any of the three above, then deleted |
| `OpenDuration`, `ClosedDuration`, `TimesOpened`, `ResetTotal`, `LastActivation` | Eve characteristics (section 10) | always |

Limiter usage is stored under a **separate identifier** (6.3).

Restore quirks that are observable:
- If no state is stored yet (first run), the accessory starts in its default state without the "reset" bookkeeping, so a
  TIMEOUT `schedule` is **not armed** until the accessory is first reset (see 7.1).
- Top-level binary sensors, temperature and humidity sensors restore their value silently (no timers resumed, no
  commands).
- Thermostat restoring a stored current mode marks the current mode as "explicitly set" (see 7.10), and, if the restored
  current mode is off and `commandOff` is set, runs `commandOff` once at startup.

### 6.3 Limiter storage

Limiter identifier = SHA-256 hex of the string `<accessory identifier>:<limit>:<units>:<period>` (numbers in their
JSON/JavaScript decimal form), first 32 hex digits formatted 8-4-4-4-12. Example: `3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f:1:HOURS:DAY`
→ `0891db4a-556e-42fd-8ee0-a5a3a9004061`. Stored under property key `Limiter` as an object
`{timeRemaining: ms, resetTimestamp: epoch ms, startTimestamp?: epoch ms}`. Fallback read: key `Limiter` under the
identifier `limiter.id` or, if absent, the accessory **name** (older versions). Changing limit/units/period therefore starts
fresh usage.

---

## 7. Behaviour

### 7.1 Trigger / reset bookkeeping (common to all stateful types)

Whenever an accessory's state is set (from HomeKit, Matter, webhook, sync, schedule, condition, restore) — **even if the
value did not change** — it does the following after updating its value:

- If the new state is **non-default** ("triggered"):
  - (re)start the `autoReset` timer if it is TIMEOUT (restarting from zero; the timer is resettable by design);
  - send the trigger notification, only if the state actually changed;
  - (re)start the limiter (7.8).
- If the new state is the **default** ("reset"):
  - (re)start the `schedule` timer if it is TIMEOUT;
  - cancel a running TIMEOUT `autoReset` (log "cancelled auto-reset timer" if one was running);
  - pause the limiter (account usage);
  - send the reset notification, only if the state actually changed.
- Only when the value changed: log the new state, write the stored property, run the matching command (unless the change
  came from a `sync`), record history.
- Update the attached sensor (7.5) and report the state to the condition engine (7.6).

A schedule fires the accessory's **trigger** (set to the non-default state). An autoReset fires **reset** (set to default
only if currently non-default; for TIMER sensors also pulses the sensor). The button's trigger is a single press.

### 7.2 Durations

Milliseconds = time × {MILLISECONDS 1, SECONDS 1000, MINUTES 60 000, HOURS 3 600 000}.
Random (`random: true`): duration = floor(max(1, U × duration)) with U uniform in [0, 1), i.e. 1 ms … just under the
maximum, drawn anew each time the timer starts. The log then expresses it in the largest unit not exceeding it (ms below
1 s, s below 1 min, min below 1 h, else h), rounded.

### 7.3 Schedule types

- **TIMEOUT** — a one-shot delay. For `schedule`: armed each time the accessory enters (or is re-set to) its default
  state; fires trigger. For `autoReset`: armed each time the accessory is (re)triggered; fires reset. For `syncSchedule`:
  never armed (effectively unusable). While running, its expiry time is stored; after a restart, when the timer is next
  started it uses the remaining time if the stored expiry is in the future (log "resuming … timer"), or fires after 100 ms
  if it already passed (log "… expired while restarting"). Starting a fresh timer logs "will trigger/reset/synchronize in N
  <units>".
- **INTERVAL** — repeating: starts at accessory construction and re-arms after every firing (each period re-randomised if
  `random`). Not affected by state changes.
- **CRON** — a cron job in the host's local time zone, started at construction (log "starting … cronjob"). The expression
  is `cronCustom` when `cron` is `CRON_CUSTOM`, else `cron` itself. Invalid expression → error "invalid cron expression",
  no job.
  Syntax is that of the npm `cron` package v4: 5 fields (minute hour day-of-month month day-of-week) or 6 fields with a
  leading seconds field; `*`, lists `,`, ranges `-`, steps `/`; months 1–12 or `jan`…`dec`; weekdays 0–7 (0 and 7 =
  Sunday) or `sun`…`sat`. Presets: `@secondly` every second; `@minutely` every minute at second 0; `@hourly` minute 0;
  `@daily` midnight; `@weekly` Sunday midnight; `@weekdays` Monday–Friday midnight; `@weekends` Saturday and Sunday
  midnight; `@monthly` the 1st at midnight; `@yearly` (and `@annually`) 1 January midnight. The UI's validation pattern
  for `cronCustom` describes 5 fields.
- **Sun events** — SUNRISE (upper limb, −0.833°), SUNSET, DAWN (civil dawn, −6°), DUSK (civil dusk, −6°), GOLDEN_HOUR
  (evening golden hour start, +6° before sunset), NIGHT (astronomical dusk, −18°, "night starts"), computed with the
  SunCalc v2 algorithm for `latitude`/`longitude`. Each arming: compute today's event (for the current date/time) plus
  `offset` minutes; if that instant is not in the future, compute for the same time tomorrow (plus offset). Log "will
  trigger at <local time>". Re-arms after firing. Starts at construction. If the event does not exist (polar day/night) the
  behaviour is undefined in the original (see Gaps).

### 7.4 Fade-out (Lightbulb, dimmer)

On every trigger (bulb set to its non-default state, i.e. On for a normal bulb — and on every brightness change while a
fade is running, which also restarts autoReset/limiter): total = `time` (FIXED) or `time` × current brightness
(INCREMENTAL), converted to ms; log "fading out over N <units>" (this log is not suppressed by `disableLogging`). The
displayed brightness then steps down by 1 every total ÷ brightness ms from the current brightness to 0; reads return the
stepping value; the stored brightness is unchanged. Reaching 0 turns the bulb Off (normal off path: command, notification,
etc.); the published brightness then returns to the stored value. Starting brightness equal to 0 → immediately off. Reset
(entering default state) cancels the fade.

### 7.5 Sensor add-on

A sensor service of `sensor.type` is added to the accessory (no name, no subtype). Its value is 0/1 (inactive/active);
initial 0, not persisted (it follows the restored main state). It is driven only by on/off types (Switch, Outlet,
Lightbulb), LockMechanism and the position family; on other types it is present but never changes.

- **MIRROR**: active exactly while the main accessory is in its non-default state.
- **TIMER**: becomes inactive whenever the main accessory goes non-default; when the main accessory is returned to default
  by a **reset** (autoReset, limiter expiry, condition not satisfied — not a direct HomeKit/webhook write and not a fade
  ending), the sensor becomes active and goes back to inactive after 1 second.

Every change logs the type-specific "detected …"/"stopped detecting …" message and, for ContactSensor, records Eve door
history and (with history) increments TimesOpened on activation; for MotionSensor records motion history.

### 7.6 Conditions

The condition engine keeps the last reported state of each accessory identifier (`on`/`off` from Switch, Outlet,
Lightbulb, Valve, HumidifierDehumidifier; `open`/`closed` from the position family; `locked`/`unlocked` from locks; no
reports from sensors, thermostat, button). An accessory reports after construction (initial state) and on every state set
(even unchanged). Humidifiers report only once their state is first set.

For a target accessory T with conditions:

- **ACCESSORY operands**: when an accessory A referenced by T reports, if this is A's first report (initialisation) it is
  only recorded. Otherwise T's conditions are evaluated: satisfied → T is triggered (log "conditions have been satisfied.
  Triggering…"); not satisfied → T is reset, **but only if T has no `autoReset`** (with an autoReset, the autoReset is
  responsible for resetting).
- **Evaluation**: operands in order; LOG operands are skipped under `or` (and when evaluating on behalf of a log match),
  and make the result false under `and`; an ACCESSORY operand whose referenced state is not yet known, or a PING operand
  whose host has not been checked yet, makes the whole result false immediately (also under `or`). Otherwise results are
  combined with AND/OR. No evaluable operands → true. Comparing a state to a desired value of another family
  (e.g. `on` vs `locked`) logs an error suggesting a typo and counts as false.
- **LOG operands**: the file `homebridge.log` in Homebridge's storage directory is tailed (new lines only, from the
  moment the first pattern is registered); missing file → error, no watching. On a line matching the pattern: if it is
  the only operand or the operator is `or` → trigger T; under `and` → evaluate the other operands (ignoring LOG) and trigger
  if satisfied. Log matches never reset.
- **PING operands**: checked immediately and then every `checkInterval` `checkUnits` (default 60 s). Hostname/IP/URL
  host: an ICMP ping via the system ping tool. MAC address: an ARP scan of the local networks for that MAC; when found,
  its IP is pinged on later checks; if that IP stops answering and was learnt more than 24 h ago, the next check goes back
  to ARP. After **every** check (changed or not) T's conditions are evaluated and T is triggered or (without autoReset)
  reset, as above. Reachability state is keyed by the `pingHost` string. Check errors → warning, state unchanged.

### 7.7 Open/close simulation

- Door, Window, WindowCovering with `simulation.enabled: true`: when the target changes, CurrentPosition moves from the old
  to the new value one percent at a time, a step every duration ÷ 100 ms (duration from `simulation`, default 15 s). A new
  target cancels and restarts from the previous **target** value.
- GarageDoorOpener: when the target changes, CurrentDoorState becomes CLOSING (3) when closing or OPENING (2) when
  opening, and after the duration becomes equal to the target.
- Without simulation the current value follows the target immediately.

### 7.8 Limiter

Tracks a remaining allowance (ms) and the time the current period ends.

- On each trigger: if the period has ended (or there is no prior record): allowance = `limit` and period end = the next
  boundary in local time — HOUR: next full hour; DAY: next midnight; WEEK: the next Sunday 00:00 (a full week ahead if
  today is Sunday); MONTH: the 1st of next month 00:00. If the allowance exceeds the time left in the period, the allowance
  becomes `limit` + time left in the period (the rest of this period plus the next period's full allowance). If allowance
  > 0: log the remaining allowance, note the start time, store. Then a timer is set for max(allowance, 100 ms); when it
  fires the usage is accounted (allowance becomes 0, log "time limit has expired") and the accessory is **reset**.
  An exhausted allowance therefore bounces the accessory back to default 100 ms after each trigger until the period ends.
- On reset (entering default): if running, the elapsed time is subtracted from the allowance, the start time cleared, the
  record stored, and the remaining allowance logged (seconds below 1 min, minutes below 1 h, hours below 1 day, else
  "more than a day remaining", or "expired" at 0).
- After restart (unless `limiter.resetOnRestart`): the stored record is restored; if it had a start time, the time
  elapsed since then is subtracted.
- Quirk: re-triggering an already non-default accessory starts an additional timer without cancelling the previous one;
  the earliest one fires first.

### 7.9 Valve durations

When SetDuration exists: on first run it is initialised (and stored) from the autoReset duration rounded to seconds,
clamped to 1…3600 with a warning if out of range. A HomeKit write to SetDuration stores it and changes the autoReset to
that many seconds for subsequent timers. RemainingDuration = round((expiry − now) / 1 s) while the autoReset timer runs,
0 otherwise (cleared on reset). Quirk: after a restart the autoReset uses the configured `time` again, while SetDuration
shows the stored value, until HomeKit writes SetDuration again. Reading SetDuration with nothing stored returns 3600.

### 7.10 Thermostat behaviour

- Setting the target mode (changed): log "<name> set to <Mode>" (or "Setting <name> to <Mode>…" when the current mode is
  decoupled), store. If the current mode has **not** been explicitly set since startup: run `commandOff` when the new mode
  is off, or `commandOn` when going from off to a non-off mode (unless sync); then make the current mode equal to the target
  (stored), except that target auto leaves the current mode unchanged.
- Setting the current mode (webhook/sync, or restore at startup): marks it explicit; from then on the current mode no longer
  follows the target and target changes run no commands. Commands run on current-mode changes instead with the same on/off
  rule (unless sync).
- Setting the target temperature (changed): log, store, run `commandTemperature` (unless sync); the current temperature
  follows unless explicitly set.
- Setting the current temperature (changed): log, store, weather history; no command.
- Temperatures in webhooks/sync are in `temperatureUnits` and converted to °C.

### 7.11 Humidifier, humidity, temperature sensors

Setting Active behaves like the on/off family (commandOn/commandOff on 1/0). Target and current humidity changes are
logged and stored; current humidity records weather history. HumiditySensor runs `commandHumidity` on changes,
TemperatureSensor runs `commandTemperature` on changes (unless sync); both record weather history.

### 7.12 Button

A press (trigger via schedule/condition, or webhook value 0/1/2): log "<name> was single/double/long pressed", run
`commandOn` (fire-and-forget), run the trigger bookkeeping then the reset bookkeeping (so both notifications, if configured,
are sent; autoReset/limiter are started and immediately cancelled; a TIMEOUT schedule is re-armed), then emit the
ProgrammableSwitchEvent value.

---

## 8. Commands

### 8.1 State commands

Shell command strings executed by the system shell (`/bin/sh -c` on Unix), fire-and-forget (not awaited), when the
corresponding value **changes** and the change did not come from a `sync`. Environment: the bridge process's environment
plus one variable per stored property of **every** accessory: `Dummy_<identifier with all non-alphanumeric ASCII characters
removed>_<propertyKey>` = the value as text (`true`/`false`, numbers in decimal, objects as `[object Object]`). This
includes timer expiries and Eve keys, and limiter records under their hashed identifiers. Example: an accessory with id
`3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f` whose `On` is true gives `Dummy_3f2c9a1e8b7d4c559e210a1b2c3d4e5f_On=true`.

### 8.2 Command results

stdout trimmed. Success: info log "<name> executed command: <command>" followed by the output on a new line (suppressed by
`disableLogging`). Non-zero exit: error "<name> failed to execute command: <command> (<exit code>)" plus stderr when
non-empty. Spawn failure: error with the message. No timeout.

### 8.3 Sync command

On each `syncSchedule` firing, `commandSync` is run and awaited. Its trimmed stdout must be a JSON object whose keys are
webhook characteristic names of this accessory (section 9.3, regardless of `enableWebhook`) and whose values are JSON
booleans or numbers. Each key: unknown → warning "trying to sync unsupported characteristic"; invalid value → error with
the validation message; else applied as a `sync` (state, storage, timers, notifications, conditions all updated; commands
not run). Empty output or invalid JSON → error "sync command must produce valid JSON".

---

## 9. Webhooks (HTTP interface)

### 9.1 Server

- One server for the whole platform, started only if at least one accessory has `enableWebhook` (or `enableWebook`)
  `true`. Listens on all interfaces at `webhookConfig.port` (default 63743).
- HTTPS when not `disableSSL` and either `pfx` (with `passphrase`) or both `key` and `cert` are available (2.10); if loading
  them fails → error "failed to load SSL credentials", falls back to HTTP. Otherwise HTTP. Logs "Webhook server listening on
  port N (https|http)".
- **No authentication of any kind.**
- Paths: only `/`, methods GET and POST. Parameters are the union of the URL query and the body (body wins); bodies may
  be `application/x-www-form-urlencoded` (nested syntax allowed) or JSON.

### 9.2 Requests

| Parameters | Response |
|---|---|
| none at all | 200, `text/html`: an "Available Webhooks" page with a table: Name, ID (identifier), Command (characteristic), Values (allowed values or `min - max`), Example (a link `?id=<id>&command=<characteristic>&value=<first allowed value or min>`). |
| missing `id` | 400 `{"error": "Request is missing id"}` (not logged). |
| `id` + `get=<Characteristic>` | 200 `{"value": <current value>}` (the button returns `{}`). |
| `id` + `set=<Characteristic>` (or legacy `command=`) + `value` | Validated and applied with commands; 200 `{"success": "<log-style message>"}` (e.g. `"Desk Lamp is on"`). |
| `id` + `sync=<Characteristic>` + `value` | Same but commands are not run. |
| `id` without get/set/sync/command | 400 error "missing a get or set command" (logged). |
| set/sync without `value` | 400 error "`set` requests require a `value`" (not logged). |
| unknown `id` (no registered webhook with that identifier) | 400 error naming the id (logged). |
| known `id`, characteristic not offered | 400 error naming the characteristic (logged). |
| invalid value | 400 error: for ranges "The <C> characteristic expects a number value between <min> and <max>", for value lists "Valid values for the <C> characteristic command are: <list>" (logged). |

Priority when several are present: `get` first; then `set`, then `sync`, then `command`. A request is a sync when the
chosen characteristic equals the `sync` parameter.

Value parsing (query/form strings): `"true"`/`"false"` → booleans; a non-blank numeric string → number; anything else stays
a string (and then fails validation). JSON bodies keep their types (strings are parsed the same way).
Validation: a range requires a number within [min, max] inclusive; a value list requires a boolean or number strictly
equal to one of the listed values (so `1` is not accepted where `true`/`false` are listed, and vice versa).

Verbose mode logs every received payload.

### 9.3 Characteristics per type

| type | Characteristic name | Allowed values | Effect |
|---|---|---|---|
| Switch, Outlet | `On` | `true`, `false` | set On |
| Lightbulb | `On` | `true`, `false` | set On |
| Lightbulb | `Brightness` | 0–100 | set brightness (offered even when not a dimmer; sync flag ignored) |
| LockMechanism | `LockTargetState` | 0 (unlocked), 1 (locked) | set lock |
| Door, Window, WindowCovering | `TargetPosition` | 0–100 (0 closed, anything else → 100) | set position |
| GarageDoorOpener | `TargetDoorState` | 0 (open), 1 (closed) | set door |
| Valve | `On` | `true`, `false` | Active 1/0 |
| HumidifierDehumidifier | `On` | `true`, `false` | Active 1/0 |
| HumidifierDehumidifier | `CurrentRelativeHumidity` | 0–100 | current humidity |
| HumidifierDehumidifier | `TargetRelativeHumidity` | 0–100 | threshold |
| HumiditySensor | `CurrentRelativeHumidity` | 0–100 | humidity |
| TemperatureSensor | `CurrentTemperature` | −270…100 in °C, or −454…212 in °F | temperature (in configured units) |
| Thermostat | `CurrentHeatingCoolingState` | valid current modes (0 off, 1 heat, 2 cool) | current mode |
| Thermostat | `TargetHeatingCoolingState` | valid target modes (0–3) | target mode |
| Thermostat | `CurrentTemperature`, `TargetTemperature` | configured min…max, expressed in configured units (C→F rounded) | temperatures |
| MotionSensor | `MotionDetected` | `true`, `false` | active/inactive |
| other binary sensors | their characteristic (`ContactSensorState`, `LeakDetected`, `OccupancyDetected`, `SmokeDetected`, `CarbonDioxideDetected`, `CarbonMonoxideDetected`) | 1 (active), 0 (inactive) | active/inactive |
| StatelessProgrammableSwitch | `ProgrammableSwitchEvent` | 0 single, 1 double, 2 long | press |

On registration each webhook logs "<name> adding webhook with id `<identifier>` and command `<Characteristic>`" (unless
`disableLogging`).

---

## 10. Eve history and extra characteristics (`enableHistory`, HomeKit only)

- History is the fakegato-history format (Eve app). One history service per accessory, created lazily on the first
  recorded entry, type fixed by that first entry: `custom` (on/off status 0/1 — Switch, Outlet, Lightbulb), `weather`
  (`temp` for TemperatureSensor/Thermostat current temperature, `humidity` for HumiditySensor/Humidifier current
  humidity), `door` (status — ContactSensor, top-level or add-on), `motion` (status — MotionSensor, top-level or add-on).
  Options: memory size 4032 entries, filesystem storage in Homebridge's `persist/` directory, file name = the name-based UUID
  (3.2) of `<identifier>dbca6d94-6d1b-45e1-9feb-daf030819984` (concatenated, no separator), periodic timer and
  repeat-last-data enabled. Entry time = Unix seconds.
- When history is **not** enabled for an accessory and something would be recorded, the accessory's history file (if any)
  is deleted once (verbose log "removing history").
- LastActivation (Eve): for types whose entries "update last activation" (on/off, door, motion), 1 s after the history service
  is created the characteristic is added with value (time of the last entry − history initial time) and stored; later
  entries update it when it is already stored.
- Times opened (position family with history, and ContactSensor add-on/top-level with history): Eve characteristics
  OpenDuration (0), ClosedDuration (0), TimesOpened (stored, starts 0) and ResetTotal (stored, starts at
  now − 978307200 s, i.e. seconds since 2001-01-01) are added to the service. TimesOpened increments each time the target
  becomes open (position) or the contact sensor becomes active. Writing ResetTotal sets TimesOpened's stored value to 0,
  stores and publishes the written ResetTotal, and logs "<name> open count has been reset". OpenDuration/ClosedDuration
  never change. (Eve UUIDs per homebridge-lib's EveHomeKitTypes; see Gaps.)

The UI offers "Enable History" for ContactSensor, Door, GarageDoorOpener, HumidifierDehumidifier, HumiditySensor,
MotionSensor, Outlet, Lightbulb, Switch, TemperatureSensor, Thermostat, Window, WindowCovering.

---

## 11. Push notifications

Sent only on actual state changes (7.1): trigger → `title`/`text`, reset → `resetTitle`/`resetText`; skipped when the
relevant text is absent. Timeout 10 s.

- **PINGIE_NOTIFY** (Notify!, getnotifyapp.com): HTTP POST `https://push.getnotifyapp.com/notify-json/<id>?token=<token>`,
  JSON body `{text, title, groupType, iconUrl}` (absent fields omitted), no redirects followed, any status < 500 is a
  response. 200 → info "<name> sent a push notification" (unless disableLogging); other status → warning "unable to send
  push notification – <message or error field of the JSON reply, or 'unknown error'>"; network error → error.
- **PUSHOVER**: HTTP POST `https://api.pushover.net/1/messages.json` with query parameters `token=<application token>`,
  `user=<notification.token>`, `message=<text>`, `title=<title>`, header `Content-Type: application/json`, no body. Same
  logging. The application token is `notification.id`; when absent the original falls back to an application token of the
  original author's own Pushover app, embedded in obfuscated form (it must not be reused; see Gaps).

---

## 12. Logging (paraphrased)

All messages are prefixed by Homebridge with the platform name. `%s` placeholders below are the accessory name.

- Startup: "adding new HomeKit/Matter accessory: <name>", "removing … accessory: <name>"; verbose: "restoring cached …
  accessory", and an environment line (plugin version, OS, Node, Homebridge and HAP versions, Matter availability).
- Validation: "<name> is missing required field '<key>'"; "<name> has invalid <thing> '<value>'. Must be one of: 'a', 'b'";
  unsupported type/protocol; Matter unavailable/disabled/groups unsupported; sensor "will never be triggered" warning;
  thermostat validStates warnings; valve duration clamp warnings; limiter "exceeds period".
- State changes (info, suppressed by disableLogging): "<name> is on/off", "<name> is on, brightness is N%", "<name>
  brightness is N%", "is locked/unlocked", "is open/closed", sensor "detected …/stopped detecting …", "<name> humidity is
  N%", "<name> is N°C/°F", thermostat "set to Heat/Cool/Auto/Off" or "Setting … to …", "set to N°C/°F", humidifier "humidity
  set to N%", button "was single/double/long pressed".
- Timers: "<name> will trigger/reset/synchronize in N <units>", "… at <local time>", "starting … cronjob", "resuming …
  timer", "… expired while restarting", "cancelled auto-reset timer", "invalid cron expression '<expr>'", fade "fading out
  over N <units>".
- Limiter: remaining seconds/minutes/hours, more than a day, expired.
- Conditions: "conditions have been satisfied. Triggering…" (info); verbose evaluation trace; errors for self reference,
  multiple log operands under ALL, unrelated state comparison; log watcher "missing file"/errors; verbose
  reachable/unreachable.
- Commands: "executed command: <command>" + output; "failed to execute command: <command> (<code>)" + stderr; sync errors.
- Webhooks: registration lines, "listening on port N (http/https)", SSL fallback, bad port/SSL parameter, request errors
  (section 9.2), verbose payload dumps, verbose shutdown.
- Notifications: success, failure (with the API's message), verbose request dump.

**Secrets**: `notification.token` (Notify! token / Pushover user key), `notification.id` when `api` is PUSHOVER (application
token), `webhookConfig.passphrase`, and the contents of key/pfx files. The original's verbose notification dump shows only
the first 5 characters of `token` followed by `…`, but prints the Pushover application token in full and the Notify! `id`
in the URL. **Command strings are logged verbatim** (they may embed credentials,
e.g. a curl with a token), as is their stdout/stderr. Webhook payload dumps (verbose) include whatever was sent.

---

## 13. Companion UI (homebridge-ui custom page)

A custom Homebridge UI page wrapping the standard schema form:

- **First install** (no platform block yet): writes a block `{name: "Homebridge Dummy"}`, shows a thank-you intro asking
  "Are you upgrading from v0.9.2 or earlier?". "No" → settings. "Yes" → a warning page ("STOP", link to the project wiki's
  Migration page) stating the user must install a separate legacy package to keep old accessories, otherwise reconfigure
  scenes and automations; "Continue" → settings. No automatic migration is performed any more.
- **Every open** with an existing block: silently rewrites deprecated fields and saves: `webhookPort` → `webhookConfig.port`
  (unless already set); `defaultOn` → `defaultState`; `sensor.timerControlled` → `sensor.behavior`; `enableWebook` →
  `enableWebhook`; `defaultBrightness` → `isDimmer: true` (removing the old key); boolean `fadeOut: true` → FIXED fadeOut
  object from a TIMEOUT autoReset (which is removed), else removed; `pingInterval`/`pingUnits` → `checkInterval`/`checkUnits`.
- **On every config change**: any accessory without `id` gets a random v4 UUID and the config is saved; each accessory's
  collapsible section title shows its name (or "Accessory").
- **Condition editor**: the `accessoryId` text field is replaced by a drop-down of other accessories (by name; only entries
  with both id and name, excluding the 7 binary sensors, Humidity/Temperature sensors, the button and Thermostat); the
  `accessoryState` choices are filtered by the selected accessory's type (on/off for Humidifier, Lightbulb, Outlet, Switch,
  Valve; open/closed for the position family; locked/unlocked for locks), clearing an incompatible selection.
- The form shows/hides sections per type: schedule hidden for Humidity/Temperature sensors and Thermostat; autoReset hidden
  for those plus the button and when fadeOut is set; fadeOut only for dimmers without autoReset; limiter hidden for those
  plus the button; conditions hidden for Thermostat and all `…Sensor` types; protocol choice only for Lightbulb, Outlet,
  Switch; groupName hidden for Matter; the commands offered per type as in 2.2; `commandSync` for all but the button.
- Translations: en, de, el, es, ru, vi.

---

## 14. Test vectors

### TV1 — derived identity, auto-off switch

```json
{ "platform": "HomebridgeDummy", "accessories": [
  { "name": "My Switch", "type": "Switch",
    "autoReset": { "type": "TIMEOUT", "time": 5, "units": "SECONDS" } } ] }
```

- Identifier `HomebridgeDummy:Switch:MySwitch`, UUID `8c1a1e2a-e4ee-432a-acc4-74e1053649de`, one Switch service, Serial
  Number `HomebridgeDummy:Switch:MySwitch`, Model `Switch`, Manufacturer `Homebridge Dummy`.
- Write On = true at t=0 → logs "My Switch is on", "My Switch will reset in 5 seconds"; stored `On` = true and
  `AutoReset` = t+5000 ms. Write On = true again at t=3 s → timer restarts, now resets at t=8 s. At t=8 s → On = false,
  log "My Switch is off", `AutoReset` removed.
- Restart at t=6 s (before reset): On restored to true, "resuming auto-reset timer", resets at t=8 s. Restart at t=10 s
  while it should already have reset: On restored true, "expired while restarting", resets ~100 ms later.

### TV2 — explicit id, webhook

```json
{ "platform": "HomebridgeDummy", "webhookConfig": { "port": 8080, "disableSSL": true }, "accessories": [
  { "id": "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", "name": "Desk Lamp", "type": "Lightbulb",
    "isDimmer": true, "enableWebhook": true } ] }
```

- UUID `f76a7be0-5e66-4b53-8c02-8da11fc4ad3b`. Lightbulb with On and Brightness (100 on first run).
- `GET http://host:8080/?id=3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f&set=On&value=true` → 200
  `{"success":"Desk Lamp is on, brightness is 100%"}`.
- `…&set=On&value=1` → 400 `{"error":"Valid values for the On characteristic command are: true, false"}`.
- `…&get=Brightness` → 200 `{"value":100}`. `…&set=Brightness&value=150` → 400 range error (0 and 100).
- `POST /` JSON `{"id":"3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f","sync":"On","value":false}` → off without running
  `commandOff`.
- `GET http://host:8080/` → HTML table with two rows (On, Brightness).
- `id=nope&set=On&value=true` → 400 error naming `` `nope` ``.

### TV3 — group

```json
{ "platform": "HomebridgeDummy", "accessories": [
  { "id": "a1", "name": "Lamp", "type": "Lightbulb", "groupName": "Living Room" },
  { "id": "b2", "name": "Fan", "type": "Switch", "groupName": "Living Room" } ] }
```

One accessory, identifier `HomebridgeDummy:Group:LivingRoom)}`, UUID `c2d8b53c-f535-47da-973d-eee490dcbff7`, display name
"Living Room", Model `GroupAccessory`; services Lightbulb (subtype `a1`, name/ConfiguredName "Lamp") and Switch (subtype
`b2`, "Fan"). Stored state and webhooks under `a1` and `b2`.

### TV4 — conditions

```json
{ "platform": "HomebridgeDummy", "accessories": [
  { "id": "door", "name": "Front Door", "type": "Door" },
  { "id": "lock", "name": "Front Lock", "type": "LockMechanism" },
  { "id": "alarm", "name": "Alarm", "type": "Switch",
    "conditions": { "operator": "and", "operands": [
      { "type": "ACCESSORY", "accessoryId": "door", "accessoryState": "open" },
      { "type": "ACCESSORY", "accessoryId": "lock", "accessoryState": "locked" } ] } } ] }
```

At startup door reports closed and lock reports locked (initialisation, no evaluation). Open the door → evaluated: open ∧
locked → Alarm On. Close the door → not satisfied, Alarm has no autoReset → Alarm Off. Re-writing the door's same target
(closed) re-evaluates and re-resets (no log of state change since unchanged).

### TV5 — limiter

`{"name": "Heater", "type": "Switch", "limiter": {"limit": 1, "units": "HOURS", "period": "DAY"}}`, triggered at 23:30
local with no stored usage: the period ends at the coming midnight, only 30 min remain, so the allowance becomes
1 h + 30 min = 90 min; log "has 2 hours remaining" (90 min rounded to hours). If left on, it is reset at 01:00 (log
"has expired"). Because the period end (midnight) has passed, the next trigger starts a fresh 1 h allowance with the
following midnight as period end.

### TV6 — sun schedule with offset

`{"name": "Porch", "type": "Switch", "schedule": {"type": "SUNSET", "offset": -15, "latitude": 48.8566, "longitude":
2.3522}, "autoReset": {"type": "TIMEOUT", "time": 4, "units": "HOURS"}}` → every day On at (SunCalc sunset for Paris −
15 min), Off 4 h later; log "Porch will trigger at <time>".

### TV7 — cron presets

`"schedule": {"type": "CRON", "cron": "@weekdays"}` → trigger at 00:00:00 Monday–Friday local time.
`"schedule": {"type": "CRON", "cron": "CRON_CUSTOM", "cronCustom": "*/10 * * * * *"}` → every 10 s.
`"schedule": {"type": "CRON", "cron": "CRON_CUSTOM"}` → error missing `cronCustom`, no schedule.

### TV8 — environment for commands

With TV2's lamp on at brightness 40 and a switch `{"name":"My Switch","type":"Switch"}` off, any command sees
`Dummy_3f2c9a1e8b7d4c559e210a1b2c3d4e5f_On=true`, `Dummy_3f2c9a1e8b7d4c559e210a1b2c3d4e5f_Brightness=40`,
`Dummy_HomebridgeDummySwitchMySwitch_On=false`.

### TV9 — sync command

`{"name":"Garage","type":"GarageDoorOpener","commandSync":"cat /tmp/g.json","syncSchedule":{"type":"INTERVAL","time":1,"units":"MINUTES"}}`
with `/tmp/g.json` = `{"TargetDoorState": 0}` → each minute the door is set open (if not already) without `commandOpen`;
`{"On": true}` → warning unsupported characteristic `'On'`; `not json` → error.

### TV10 — fade

Dimmer at brightness 50, `"fadeOut": {"type": "INCREMENTAL", "time": 1, "units": "MINUTES"}` → turning On logs "fading out
over 50 minutes"; brightness reads 49 after 1 min, … 0 after 50 min → Off; Brightness then shows 50 again.
FIXED with time 10 SECONDS from 50 → a step every 200 ms, Off after 10 s.

### TV11 — legacy limiter key and Timer

Stored `{"Limiter": {...}}` under identifier = the accessory's name (pre-1.5.7) is picked up when no record exists under
the hashed identifier. Stored `Timer` = future epoch ms under the identifier resumes the autoReset after upgrade and is
then deleted.

### TV12 — thermostat

`{"name":"Thermo","type":"Thermostat","temperatureUnits":"F","minimumTemperature":50,"maximumTemperature":90,
"validStates":["off","heat"],"enableWebhook":true,"id":"t"}` → min 10 °C, max 32.2222 °C; Target modes {0,1}, Current
modes {0,1}; `set=TargetTemperature&value=68` → stored 20 °C, response "Thermo set to 68°F"; `value=95` → range error
"between 50 and 90"; `set=TargetHeatingCoolingState&value=2` → error, valid values "0 (Off), 1 (Heat)".

---

## 15. Quirks of the original worth knowing (observable behaviour)

- Q1: An accessory with an unknown `type` still gets a (serviceless) HomeKit accessory registered and kept in the cache.
- Q2: Two config entries with the same identifier share one cached accessory (behaviour undefined).
- Q3: A TIMEOUT `schedule` is not armed at first start (no stored state) or with `resetOnRestart`, until the accessory is
  first reset; afterwards it re-arms on every reset (including no-op resets via webhooks or conditions).
- Q4: Writing a value equal to the current one still restarts autoReset/limiter/fade and re-evaluates conditions.
- Q5: Thermostat stops mirroring the target into the current mode (and stops running commands on target changes) after
  any restart where a current mode was stored, which is always the case once the target mode has been changed once.
- Q6: Sensor add-ons inside a group are one unsubtyped service per sensor type on the group accessory, and members without
  a sensor remove all sensor services from the group accessory when they are built; history services in a group are per
  member on the same accessory.
- Q7: The Lightbulb `Brightness` webhook exists even for non-dimmers.
- Q8: `TargetHumidifierDehumidifierState` writes are ignored.
- Q9: Top-level binary sensors do not resume a running autoReset after restart (their stored active state is restored
  but no timer runs), so they can stay active until triggered again.

---

## 16. Gaps (not determined from the source)

- Exact behaviour of the npm `cron` v4 parser in corner cases (day-of-month and day-of-week both restricted, `L`/`#`
  support, DST transitions); described from the library's documented behaviour, not verified here.
- SunCalc v2 exact algorithm (which day it computes for a given instant; polar cases where an event is missing produce an
  invalid date in the original, with undefined timer behaviour). The replacement needs a SunCalc-compatible calculation
  to match times to the minute.
- node-persist on-disk details for reading existing state: the datum file name is a hash of the key `HomebridgeDummy`
  (believed SHA-256 hex in node-persist ≥ 3) and the file content a JSON object with `key` and `value` fields; not verified.
- The fakegato-history on-disk file format and the Eve characteristic UUIDs (OpenDuration, ClosedDuration, TimesOpened,
  ResetTotal, LastActivation) come from homebridge-lib's EveHomeKitTypes and the vendored fakegato-history; not restated
  here.
- Legacy v0.9.2 accessory UUID (`DummySwitch:<name>`) and its exact info-service strings are Homebridge/legacy behaviour,
  inferred, not verified against a running Homebridge.
- The Pushover fallback application token is the original author's credential (obfuscated in the source); it is
  deliberately not reproduced. Without `notification.id`, a replacement has no application token of its own.
- Webhook TLS defaults come from Homebridge UI's config entry, which does not exist outside Homebridge; what the
  replacement uses instead is unspecified by the source.
- Matter exposure is through Homebridge 2's Matter API; how this maps onto another host's Matter bridge is outside the
  source.
- Values of `ProgrammableSwitchEvent` reads (HAP returns null for this characteristic) and HomeKit's handling of writes to
  TemperatureDisplayUnits are HAP-NodeJS behaviour, not the plugin's.
- MAC-address reachability depends on an ARP scan library (arpping) whose scan range/interfaces were not examined.
