# Tado: functional specification (clean room)

## 0. Provenance

- Source: https://github.com/homebridge-plugins/homebridge-tado
- Commit read: `52aa7ea54869230d81734da5ed7626fbd00a70a0` (committed 2026-10-17, package version 10.2.0)
- npm package: `@homebridge-plugins/homebridge-tado`
- License: MIT. Copyright line: "Copyright (c) 2018+ SeydX, 2025+ smart7324" (original author SeydX, current maintainer smart7324).
- Written by the spec writer; contains no source code. Everything below describes behaviour in the spec writer's own words. JSON keys, endpoint paths, enum values, UUIDs and log-free identifiers are interface facts.
- Facts marked **[source]** come straight from the code. Facts marked **[tado, typical]** are typical tado API response shapes that the code reads but that the repository does not contain as fixtures; treat them as illustrative.

---

## 1. Overview

A Homebridge dynamic platform, platform name **`TadoPlatform`** (also the `pluginAlias`; `singular: true`). One platform block holds an array of tado homes (`homes[]`). Each home is driven by its own tado account (`username`), polled on a timer, and exposes:

- one accessory per active zone (thermostat, heater-cooler, switch or faucet, chosen by zone type and options),
- optional per-zone extra accessories (open-window contact sensor, separate temperature sensor, separate humidity sensor),
- one "Open Window" accessory grouping open-window switches of all zones that want one,
- presence accessories (one per selected mobile device user, plus an "Anyone" sensor),
- weather accessories (outside temperature, solar intensity),
- extras: a "Central Switch" accessory with sub-switches (Central, Boost, Shedule, Off, Dummy), a "Presence Lock" accessory (security system or two switches), a "Child Lock" accessory (one switch per selected valve).
- optional Telegram notifications on presence and open-window changes.

There is no local/LAN control. Everything goes through tado's cloud REST API (`my.tado.com`), the tado login server (`login.tado.com`) and, for running-time statistics, `minder.tado.com`.

---

## 2. Configuration interface

### 2.1 Platform level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Must be `TadoPlatform`. |
| `name` | string | `TadoPlatform` | Log name only. |
| `debug` | boolean | false | When true, debug messages are emitted at info level. |
| `preferSiriTemperature` | boolean | false | Changes how a simultaneous "set to AUTO" + temperature write is interpreted (section 7.2). |
| `homes` | array | [] | The homes, see 2.2. |
| `user` | array | absent | Legacy auto-configuration (section 2.6). Not in the schema. Entries `{ "username": string, "reconfigure": boolean, "tadoApiUrl"?: string, "skipAuth"?: boolean }`. |

### 2.2 `homes[]`

| Key | Type | Default | Meaning / validation |
|---|---|---|---|
| `id` | integer | none | tado home id. If absent at runtime, the plugin calls `/api/v2/me` and takes the **first** home of the account, requiring its `name` to equal `homes[].name`; otherwise the poll fails. |
| `name` | string | required | Home name; must match tado's home name for config generation. Used as the prefix of every accessory name (therefore part of every identity seed). Home skipped (warning) if missing. |
| `username` | string | required | tado account e-mail. Home skipped (warning) if missing. Special case: if it ends with `.json` (case-insensitive) it is a **path to an externally maintained token file** (section 3.4). |
| `tadoApiUrl` | string | `https://my.tado.com` | Replaces the API base URL (e.g. `http://localhost:8080`, a local proxy). When set, running-time requests are skipped entirely. |
| `skipAuth` | boolean (or the string "true") | false | When true, no token is obtained and requests carry no `Authorization` header. |
| `addJitter` | boolean (or "true") | false | Adds a uniformly random ±10 % offset to each polling interval. |
| `polling` | integer, minimum 30 | 300 | Polling interval, seconds. If not an integer, 300 is used; integer values below 30 are raised to 30. |
| `nightPolling` | integer, minimum 30 | unset | Interval used while the local hour is 0–5 (00:00–05:59). Effective value is the maximum of `nightPolling`, `polling` and 30. Ignored if absent, 0 or not an integer. (Discovery writes 300.) |
| `temperatureUnit` | `CELSIUS` \| `FAHRENHEIT` | `CELSIUS` | Unit of every temperature value the plugin reads from tado and writes into HomeKit (section 6.10). If absent at runtime, it is fetched from `GET /api/v2/homes/{id}` (`temperatureUnit`). |
| `geolocation` | object `{ "longitude": string, "latitude": string }` | — | Informational; written by discovery, filled from the home if missing, otherwise unused. |
| `presence` | object | — | 2.4 |
| `weather` | object | — | 2.4 |
| `extras` | object | — | 2.5 |
| `zones` | array | [] | 2.3 |
| `telegram` | object | — | 2.5 |

### 2.3 `homes[].zones[]`

Only zones with `active: true` produce accessories.

| Key | Type | Default (runtime) | Meaning |
|---|---|---|---|
| `active` | boolean | false | Expose this zone. |
| `id` | integer | none | tado zone id. Zone id `0` is valid. If missing, a warning is logged at start and the id is resolved at runtime by matching the zone `name` (and `type`) against `GET /homes/{h}/zones`. |
| `name` | string | required | tado zone name (exact). Used in the accessory name, and to match the zone to tado's zone list and accessories to zones. A zone without name is skipped with a warning (see bug in 8.9). |
| `type` | `HEATING` \| `HOT_WATER` \| `AIR_CONDITIONING` | `HEATING` | Any other value is replaced by `HEATING` with a warning. |
| `mode` | `MANUAL` \| `AUTO` \| `TIMER` \| `CUSTOM` | `MANUAL` | Termination of overlays the plugin creates. MANUAL: until changed by the user; AUTO: until the next schedule block (tado "TADO_MODE"); TIMER: for `modeTimer` minutes; CUSTOM: documented as "OFF manual, ON returns to schedule" for heater-cooler accessories (actual effect in 7.4). Invalid → MANUAL. |
| `modeTimer` | integer ≥ 1 | 1 if missing or < 1 | Timer, minutes, for `mode: TIMER`. (Discovery writes 30.) |
| `easyMode` | boolean | false | HEATING only: expose as HeaterCooler (On/Off) instead of Thermostat. |
| `minValue` | number | type default | Minimum target temperature (in the home unit). |
| `maxValue` | number | type default | Maximum target temperature. |
| `minStep` | number | 1 | Target temperature step; used only if 0 < step ≤ 1, otherwise 1; rounded to 2 decimals. |
| `noBattery` | boolean | false | Do not expose a Battery service. |
| `delaySwitch` | boolean | false | Adds custom characteristics Delay (switch) and Timer to the zone's thermostat/heater-cooler service (not for HOT_WATER). |
| `autoOffDelay` | boolean | false | With `delaySwitch`: the Delay switch does not affect heating; it turns itself off after Timer seconds. |
| `openWindowSensor` | boolean | false | Adds a "Window" contact-sensor accessory for the zone. |
| `openWindowSwitch` | boolean | false | Adds a switch for this zone to the home's "Open Window" accessory. |
| `separateTemperature` | boolean | false | Adds a separate "Temperature" sensor accessory. (The built-in current temperature stays.) |
| `separateHumidity` | boolean | false | Adds a separate "Humidity" sensor accessory and removes humidity from the main service. |
| `boilerTempSupport` | boolean | false | HOT_WATER with adjustable temperature: expose as HeaterCooler. **Takes precedence over every other choice, for any zone type** (8.9). |
| `accTypeBoiler` | `SWITCH` \| `FAUCET` | `SWITCH` | HOT_WATER without temperature: Switch or Valve (faucet). |
| `acFanSpeed` | boolean | false | AIR_CONDITIONING only: RotationSpeed for fan level. |
| `acFanModeSwitch` | boolean | false | AIR_CONDITIONING only: extra switch turning on FAN mode. |
| `acDryModeSwitch` | boolean | false | AIR_CONDITIONING only: extra switch turning on DRY mode. |
| `accTypeOpenWindowSwitch` | string | — | Written by discovery (`SWITCH`), never read. |

Type defaults for temperature limits (in the home unit):

| Zone type | Celsius min/max | Fahrenheit min/max |
|---|---|---|
| HEATING, AIR_CONDITIONING | 5 / 25 | 41 / 77 |
| HOT_WATER | 30 / 65 | 86 / 149 |

Limit override rules differ slightly per accessory kind (preserve these exactly):
- Thermostat: config `minValue` is used if it is less than the default max; then config `maxValue` is used if greater than the (resulting) min. A missing value compares false and leaves the default.
- HeaterCooler and the write path: `minValue` is used only if present, > 0, and < default max; `maxValue` only if present, > 0, and > resulting min.

### 2.4 `presence` and `weather`

`presence`:
| Key | Type | Default | Meaning |
|---|---|---|---|
| `anyone` | boolean | false | Expose an "Anyone" sensor (only if at least one user sensor is active). |
| `accTypeAnyone` | `OCCUPANCY` \| `MOTION` | OCCUPANCY | `MOTION` → motion sensor, anything else → occupancy sensor. |
| `user` | array of `{ "active": bool, "name": string, "accType": "OCCUPANCY"\|"MOTION" }` | [] | One sensor per active entry. `name` must equal the tado mobile device `name`. `accType: MOTION` → motion sensor, else occupancy. |

`weather`:
| Key | Type | Default | Meaning |
|---|---|---|---|
| `temperatureSensor` | boolean | false | Outside-temperature sensor accessory. |
| `solarIntensity` | boolean | false | Solar-intensity accessory. |
| `accTypeSolarIntensity` | `LIGHTBULB` \| `SENSOR` | LIGHTBULB | `SENSOR` → light sensor, anything else → lightbulb. |

### 2.5 `extras` and `telegram`

`extras`:
| Key | Type | Default | Meaning |
|---|---|---|---|
| `centralSwitch` | boolean | false | Expose the "Central Switch" accessory (needs ≥ 1 active, valid zone). All following sub-switch options require it. |
| `runningInformation` | boolean | false | Adds heating running-hour characteristics (day/month/year) to the Central sub-switch and polls `minder.tado.com`. |
| `boostSwitch` | boolean | false | Sub-switch "Boost". |
| `sheduleSwitch` | boolean | false | Sub-switch "Shedule" (sic). |
| `turnoffSwitch` | boolean | false | Sub-switch "Off". |
| `dummySwitch` | boolean | false | Sub-switch "Dummy" (stateful, no API effect). |
| `presenceLock` | boolean | false | Expose the "Presence Lock" accessory. |
| `accTypePresenceLock` | `ALARM` \| `SWITCH` | **SWITCH when absent** (discovery writes ALARM) | `ALARM` → SecuritySystem; anything else → two switches. |
| `childLockSwitches` | array of `{ "active": bool, "name": string, "serialNumber": string }` | [] | One switch per active entry (`name` required, else skipped with the same sticky-error bug as zones). |
| `accTypeChildLock` | string | — | Written by discovery (`SWITCH`), never read. |

`telegram` (active only if `active` true and both `token` and `chatID` non-empty):
| Key | Type | Meaning |
|---|---|---|
| `active` | boolean | Enable. |
| `token` | string | **Secret.** Telegram bot token. |
| `chatID` | string | Target chat. |
| `messages.presence.user_in` / `user_out` / `anyone_in` / `anyone_out` | string | Message templates. |
| `messages.openWindow.opened` / `closed` | string | Message templates. |

Template substitution: the first `@` is replaced with the accessory name without the `"<home name> "` prefix (not replaced for the Anyone sensor); then the first `%` is replaced with the home name. A message is sent only if the template for that event exists. Sending: `POST https://api.telegram.org/bot<token>/sendMessage` as multipart form with fields `chat_id`, `parse_mode` = `Markdown`, `text`. Non-200 responses and errors are logged, never retried. Note: only one Telegram configuration exists per platform; with several homes, the last home configured with Telegram wins for all homes.

### 2.6 Legacy auto-configuration (`user[]`) and what discovery writes

If the platform block has `user[]` entries with a `username` and `reconfigure` not `false`:
- for each such user: if a `homes[]` entry has the same `username`, the first such home is "refreshed"; otherwise all homes of the account are "added";
- the whole platform block is then written back to the host's config.json, with `user` replaced by `[{ "reconfigure": false, "username": ... }]` (dropping `tadoApiUrl`/`skipAuth` from those entries), and normal start continues.

**Add** (per home of `GET /api/v2/me` → `homes[]` not already present by `name` or `id`): a new `homes[]` entry with `id`, `name`, `username`, `tadoApiUrl`, `skipAuth`, `addJitter: false`, `polling: 300`, `nightPolling: 300`, `temperatureUnit` and `geolocation` (stringified numbers) from `GET /homes/{id}`, `presence { anyone: false, accTypeAnyone: OCCUPANCY, user: [one inactive OCCUPANCY entry per mobile device name] }`, `weather { temperatureSensor: false, solarIntensity: false, accTypeSolarIntensity: LIGHTBULB }`, `extras { all switches false, presenceLock: false, accTypePresenceLock: ALARM, accTypeChildLock: SWITCH, childLockSwitches: [...] }`, `telegram { active: false }`, and one zone per tado zone: `active: true`, `id`, `name`, `type`, `delaySwitch/autoOffDelay/noBattery/easyMode/openWindowSensor/openWindowSwitch/separateTemperature/separateHumidity/boilerTempSupport: false`, `mode: MANUAL`, `modeTimer: 30`, `accTypeOpenWindowSwitch: SWITCH`, `accTypeBoiler: SWITCH`, and `minValue`/`maxValue`/`minStep` from `GET /homes/{h}/zones/{z}/capabilities` → `temperatures.celsius` or `.fahrenheit` (`min`, `max`, `step`) per home unit, falling back to 5 / 25 / 1 when the zone has no `temperatures`.
Child-lock candidates: every device in a zone's `devices[]` whose `deviceType` contains `VA01` or `VA02`, named `"<zone name> <shortSerialNo>"`, `serialNumber: shortSerialNo`, `active: false`.

**Refresh** (existing home, matched by name): updates `id`, `username`, `tadoApiUrl`, `skipAuth`, `temperatureUnit` (default CELSIUS), `geolocation`; removes presence users and zones whose name no longer exists in tado; appends new ones with the defaults above; for existing zones overwrites `id`, `type`, `minValue`, `maxValue`, `minStep` from capabilities; prunes and appends child-lock entries by `serialNumber`. (The plugin's custom settings UI does the same, except its fallback limits when a zone has no `temperatures` are type-aware: HOT_WATER 30/65 °C (86/149 °F), others 5/27 °C (41/77 °F); 27 is a quirk of the UI only.)

In Homeswift this maps onto Setup's `discover`; the shapes above are what a pasted block will look like.

### 2.7 Example block (personal data replaced)

```json
{
  "platform": "TadoPlatform",
  "name": "TadoPlatform",
  "debug": false,
  "preferSiriTemperature": false,
  "homes": [{
    "id": 123456, "name": "My Home", "username": "mail@example.com",
    "polling": 300, "nightPolling": 900, "addJitter": false, "temperatureUnit": "CELSIUS",
    "presence": { "anyone": true, "accTypeAnyone": "MOTION",
                  "user": [{ "active": true, "name": "Buddy 1", "accType": "OCCUPANCY" }] },
    "weather": { "temperatureSensor": true, "solarIntensity": true, "accTypeSolarIntensity": "LIGHTBULB" },
    "extras": { "centralSwitch": true, "runningInformation": true, "boostSwitch": true,
                "sheduleSwitch": true, "turnoffSwitch": true, "dummySwitch": true,
                "presenceLock": true, "accTypePresenceLock": "ALARM",
                "childLockSwitches": [{ "active": true, "name": "Living Room VA0000000001", "serialNumber": "VA0000000001" }] },
    "zones": [
      { "active": true, "id": 1, "name": "Living Room", "type": "HEATING", "mode": "MANUAL", "modeTimer": 30,
        "minValue": 5, "maxValue": 25, "minStep": 0.5, "easyMode": false, "delaySwitch": true,
        "openWindowSensor": true, "openWindowSwitch": true, "separateHumidity": true },
      { "active": true, "id": 0, "name": "Bathroom", "type": "HOT_WATER", "mode": "AUTO", "accTypeBoiler": "FAUCET" },
      { "active": true, "id": 5, "name": "Office", "type": "AIR_CONDITIONING", "mode": "TIMER", "modeTimer": 60,
        "acFanSpeed": true, "acFanModeSwitch": true, "acDryModeSwitch": true }
    ],
    "telegram": { "active": false }
  }]
}
```

---

## 3. Authentication

### 3.1 Constants [source]

- Login base: `https://login.tado.com/oauth2`
- Client id: `1bb50063-6b0c-4d11-bd99-387f4a91cc46`
- Scope: `offline_access`
- All login requests are `POST` with `application/x-www-form-urlencoded` bodies and `Accept: application/json`. They are **not** retried by the HTTP layer.

### 3.2 Device authorization (OAuth 2.0 Device Authorization Grant, RFC 8628)

1. `POST https://login.tado.com/oauth2/device_authorize`, form `client_id`, `scope=offline_access`, timeout 15 s.
   Response [tado, typical]: `{ "device_code": "...", "user_code": "ABC123", "verification_uri": "https://login.tado.com/oauth2/device", "verification_uri_complete": "https://login.tado.com/oauth2/device?user_code=ABC123", "expires_in": 300, "interval": 5 }`. Missing `device_code` → failure.
2. The plugin logs (info) the `verification_uri_complete` and asks the user to sign in **as the configured username**, suggesting a private browser window if their browser is signed in to another tado account. The UI flow returns this URL to the settings page.
3. Polling: interval = `interval` seconds (default 5 if missing/≤ 0); deadline = now + `expires_in` (default 300 s). While "now + interval" is before the deadline: wait one interval, then `POST https://login.tado.com/oauth2/token` with form `client_id`, `device_code`, `grant_type=urn:ietf:params:oauth:grant-type:device_code`, timeout 15 s.
   - error `slow_down` → interval grows by 5 s, continue;
   - error `access_denied` or `expired_token` → fail;
   - any other error (including `authorization_pending`, HTTP 400, network) → log "waiting for confirmation" and continue;
   - success with both `access_token` and `refresh_token` → identity check (3.3), then store (3.5), log success.
   - Deadline reached → fail ("timed out").
4. While a device authorization is running, all API calls of that account wait on it (single in-flight token operation per account; concurrent callers share it).

### 3.3 Identity verification after device authorization

With the new access token, `GET {apiBase}/api/v2/me` (bearer). Compare the lower-cased `email` (or `username` if no email) with the lower-cased configured `username`. If the response has a non-empty identity that differs → fail with a message saying the browser was probably signed in to another tado account; the tokens are **not** stored. If the `/me` request itself fails → fail. Skipped when the account is an external token file (no username).

### 3.4 External token file mode

When `username` ends with `.json`: no OAuth at all. The file is read (up to 3 attempts, 5 s apart) and must contain JSON with `access_token`. The token's age is taken as the file's modification time (capped at now). It is re-read whenever it is older than 9 minutes. Never refreshed, never written, no identity check.

### 3.5 Token lifetime, refresh and rotation

- Access token reuse: a token is considered valid for **9 minutes from when it was obtained** (local clock; `expires_in` from tado is ignored). After that, the next API call triggers a refresh first.
- Refresh: `POST https://login.tado.com/oauth2/token`, form `client_id`, `grant_type=refresh_token`, `refresh_token=<current>`, timeout 30 s.
  - HTTP 400 or 401 (refresh token rejected, e.g. `invalid_grant`) → log a warning and start device authorization (3.2).
  - Any other failure (network, timeout, 5xx) → the call fails; the refresh token is kept and the refresh is retried on the next call. No new authorization.
  - Success without both tokens → warning, start device authorization.
  - Success → the response's new `access_token` **and new `refresh_token`** replace the old ones (tado rotates refresh tokens; the old one is invalid from now on). The new pair is kept in memory first, then persisted. A persistence failure is logged as an error but the in-memory tokens keep working.
- Start-up: the in-memory token is empty; the refresh token is read from the persisted file (up to 3 attempts, 1 s apart; the stored `access_token` is ignored) and immediately refreshed. If no file exists → device authorization.
- 401 from an API call: if the rejected token has since been replaced by another call → retry once with the current token; else if the token is less than 60 s old → do not renew, fail the call (avoids refresh loops); else mark the token stale, obtain a new one (refresh) and retry the request once.
- `skipAuth: true` → none of this; requests have no `Authorization` header.

### 3.6 Persistence of tokens

Homebridge layout [source]: `<storage>/.tado-token-<h>.json`, content `{"access_token": "...", "refresh_token": "..."}`, written atomically (temporary file `<path>.<pid>.tmp` then rename), permissions 0600. `<h>` is a username hash: the 32-bit string hash "h ← 31·h + code unit" over the UTF-16 code units of the username, modulo 2^32, taken as unsigned, written in lower-case base 36, left-padded with `0` to at least 7 characters. Vectors: `mail@example.com` → `1mjwh6c`; `user@example.org` → `0hxh36z`.

In Homeswift the refresh token belongs in the vault (`context.secretFile`), keyed per username; a migration may import an existing `.tado-token-<h>.json` (its `refresh_token`) once, using the hash above to find it. Several homes sharing one username share one token (one account, one refresh token chain): two independent refreshers on the same refresh token would invalidate each other, so the token state must be shared per username.

### 3.7 Legacy password flow

None remains in this version. No `password` key is read; tado's old password grant is not used. (A pasted block from an old version may still contain `password`; it is ignored. It is a secret and should be masked.)

---

## 4. HTTP layer behaviour

- API base: `homes[].tadoApiUrl` or `https://my.tado.com`; all paths below are relative to it unless stated.
- Headers: `Accept: application/json`; `Authorization: Bearer <access_token>` unless `skipAuth`; `Content-Type: application/json` when a JSON body is sent.
- A JSON body is sent only for non-GET methods and only if the body object has at least one key (so DELETE on `presenceLock` does carry a body, 5.11).
- Query parameters are set from a map.
- Timeout: 15 s per attempt for API calls (login: see section 3).
- Retries for API calls: up to 2 retries (3 attempts) for methods GET, POST, PUT, DELETE on HTTP 408, 429, 503, 504 and on network errors (timeout, connection reset/refused, broken pipe, DNS not found / temporary failure, network unreachable, address in use). Delay: `Retry-After` if present (seconds or HTTP date, floored at 0); otherwise 1 s for the first retry, 2 s for the second, plus up to 100 ms random noise. If `Retry-After` exceeds 30 s, no retry (the error surfaces at once).
- Response bodies are parsed as JSON when possible (empty body → empty string). Non-2xx → error carrying status and parsed body.
- A 404 on `GET .../overlay` is mapped to "no overlay" (empty object); that endpoint is not used by the runtime.

---

## 5. API endpoints used

All under `/api/v2` on the API base unless stated. `{h}` home id, `{z}` zone id.

### 5.1 `GET /api/v2/me`
Used at discovery, identity verification and when a home has no `id`. Reads `email`, `username`, `homes[]` (`id`, `name`).
```json
{ "name": "Jane Doe", "email": "mail@example.com", "username": "mail@example.com",
  "homes": [{ "id": 123456, "name": "My Home" }] }
```

### 5.2 `GET /api/v2/homes/{h}`
Reads `id`, `name`, `temperatureUnit` (`CELSIUS`|`FAHRENHEIT`), `geolocation.latitude/longitude` (numbers).

### 5.3 `GET /api/v2/homes/{h}/zones`
Called on **every zone poll** (once, twice if some configured zone has no id). Reads per zone: `id`, `name`, `type`, `devices[]` (`deviceType`, `shortSerialNo`, `batteryState`, `duties[]`), `openWindowDetection.enabled`.
```json
[{ "id": 1, "name": "Living Room", "type": "HEATING",
   "openWindowDetection": { "supported": true, "enabled": true, "timeoutInSeconds": 900 },
   "devices": [{ "deviceType": "VA02", "serialNo": "VA0000000001", "shortSerialNo": "VA0000000001",
                 "batteryState": "NORMAL", "duties": ["ZONE_UI", "ZONE_DRIVER", "ZONE_LEADER"] }] }]
```

### 5.4 `GET /api/v2/homes/{h}/zoneStates`
One call for all zone states, every zone poll. Response `{ "zoneStates": { "<zoneId as string>": <zone state> } }`. Zone state fields read: `setting.type`, `setting.power` (`ON`|`OFF`), `setting.temperature.celsius|fahrenheit`, `setting.mode`, `setting.fanLevel` / `setting.fanSpeed`, `overlayType` (null when following the schedule), `overlay.termination`, `sensorDataPoints.insideTemperature.celsius|fahrenheit`, `sensorDataPoints.humidity.percentage`, `openWindow` (object or null), `openWindowDetected` (boolean). See test vectors in section 10.

### 5.5 `GET /api/v2/homes/{h}/zones/{z}/state`
Called **before every overlay PUT** (one extra request per write) to copy the current `setting` (and for AC the current overlay termination, mode, fan, swing, light).

### 5.6 `GET /api/v2/homes/{h}/zones/{z}/capabilities`
At discovery for every zone (limits), and at runtime for AIR_CONDITIONING zones only, cached per home+zone for the process lifetime (a failed request is not cached). HEATING [tado, typical]: `{ "type": "HEATING", "temperatures": { "celsius": { "min": 5, "max": 25, "step": 0.1 }, "fahrenheit": { "min": 41, "max": 77, "step": 0.1 } } }`. AC: one object per mode key (`COOL`, `HEAT`, `DRY`, `FAN`, `AUTO`), each optionally with `temperatures`, `fanLevel` (newer units) or `fanSpeeds` (older units), `swings`, `verticalSwing`, `horizontalSwing`, `light` arrays.

### 5.7 `PUT /api/v2/homes/{h}/zones/{z}/overlay` (non-AC)
Body: `{ "setting": <copy of current zone state's setting, then modified>, "termination": {...} }` where:
- `setting.type` = the configured zone type (not tado's, which may be missing).
- power ON: `setting.power: "ON"`; if a numeric, non-zero temperature is given: `setting.temperature: { "celsius": t }` where t is converted from Fahrenheit by (t − 32)·5/9 (unrounded) when the accessory unit is FAHRENHEIT; otherwise `setting.temperature: null`.
- power OFF: `setting.power: "OFF"`, `setting.temperature: null`.
- termination by zone `mode`: TIMER → `{ "type": "TIMER", "durationInSeconds": modeTimer·60 }`; AUTO → `{ "type": "TADO_MODE" }`; MANUAL and CUSTOM → `{ "type": "MANUAL" }`. (A hidden `next_time_block` value would add top-level `"type": "MANUAL"` and `termination.typeSkillBasedApp: "NEXT_TIME_BLOCK"`; unreachable from config.)

### 5.8 `PUT /api/v2/homes/{h}/zones/{z}/overlay` (AIR_CONDITIONING)
Built from current zone state (if readable, otherwise empty) and cached capabilities (if readable):
- power ON: `setting = { "type": "AIR_CONDITIONING", "power": "ON", "mode": <mode or COOL> }`, then:
  - temperature: if the mode's capabilities are unknown or have `temperatures`: the given temperature (°F converted to °C as above) as `{ "celsius": t }`, else the current setting's `temperature.celsius` if any. Modes without `temperatures` get no temperature.
  - fan: setting key `fanLevel` if the mode capabilities list `fanLevel`, else `fanSpeed` if they list `fanSpeeds`. Value: the requested fan level if it is in the supported list, else the current setting's value if supported, else (FAN/DRY only) `AUTO` if supported, otherwise the lowest manual level.
  - `swing` (checked against capability `swings`), `verticalSwing`, `horizontalSwing`, `light`: copied from the current setting when the current value is in the capability list.
- power OFF: `setting = { "type": "AIR_CONDITIONING", "power": "OFF" }` plus `mode` = the current setting's mode if present.
- termination: never has `type`. Always `typeSkillBasedApp: "MANUAL"`, plus `durationInSeconds: modeTimer·60` when zone mode is TIMER. (AUTO mode therefore behaves like MANUAL for AC.)

### 5.9 `DELETE /api/v2/homes/{h}/zones/{z}/overlay`
Return to schedule (no body).

### 5.10 `POST /api/v2/homes/{h}/overlay` (central switch, several zones)
Body `{ "overlays": [ { "room": <zone id>, "overlay": { "setting": { "power": "ON"|"OFF", "type": <zone type or HEATING>, "temperature"?: { "celsius": c, "fahrenheit": f } } }, "termination": { "typeSkillBasedApp": <zone mode: MANUAL|AUTO|TIMER, else MANUAL>, "durationInSeconds"?: n } } ] }`.
- `temperature` only when a non-zero Celsius value is given (`fahrenheit` = c·9/5+32 rounded to 2 decimals; 25 °C → 77).
- Note `termination` sits beside `overlay`, not inside it, and `typeSkillBasedApp` carries `AUTO` literally for AUTO zones.
- For TIMER zones `durationInSeconds` = (per-room timer in seconds)·60, where the per-room timer is already modeTimer·60 (or 1800); the result is modeTimer·3600 (bug, preserve or fix knowingly; 8.9).

### 5.11 `DELETE /api/v2/homes/{h}/overlay?rooms=<id,id,...>`
Resume schedule for several zones. `rooms` is the comma-joined list of zone ids, dropping falsy ids (so zone id 0 is dropped). Refuses with an error if the list is empty.

### 5.12 `GET /api/v2/homes/{h}/state`
Presence lock state: `{ "presence": "HOME"|"AWAY", "presenceLocked": true|false }`.

### 5.13 `PUT|DELETE /api/v2/homes/{h}/presenceLock`
HOME/AWAY → `PUT` with `{ "homePresence": "HOME"|"AWAY" }`; AUTO → `DELETE` with JSON body `{ "homePresence": "AUTO" }`.

### 5.14 `GET /api/v2/homes/{h}/mobileDevices`
`[ { "id": 1, "name": "Buddy 1", "settings": { "geoTrackingEnabled": true }, "location": { "atHome": true } } ]`. Only `name` and `location.atHome` are used for presence.

### 5.15 `GET /api/v2/homes/{h}/weather`
`{ "outsideTemperature": { "celsius": 7.5, "fahrenheit": 45.5 }, "solarIntensity": { "percentage": 42.3 }, "weatherState": { "value": "CLOUDY" } }`.

### 5.16 Devices and child lock
- `GET /api/v2/homes/{h}/devices` → array of devices; reads `serialNo` and `childLockEnabled`.
- `PUT /api/v2/devices/{serialNumber}/childLock` with `{ "childLockEnabled": true|false }`.

### 5.17 Open window
- `PUT /api/v2/homes/{h}/zones/{z}/openWindowDetection` with `{ "enabled": bool, "timeoutInSeconds": 3600 }`.
- Then `POST /api/v2/homes/{h}/zones/{z}/state/openWindow/activate` (on) or `DELETE /api/v2/homes/{h}/zones/{z}/state/openWindow` (off).

### 5.18 Running time (heating statistics)
`GET https://minder.tado.com/v1/homes/{h}/runningTimes` (fixed host, same bearer token), query `aggregate` (`day`|`month`|`year`), `summary_only=true`, `from` (YYYY-MM-DD, local date) and for years `to`. Response read: `summary.totalRunningTimeInSeconds`. Skipped (no request) when `tadoApiUrl` is set.

### 5.19 Defined but unused at runtime
Mobile device detail and settings (geo-tracking toggle), temperature offset get/put, identify device, installations, users, air comfort, zone day report, schedule timetables and blocks, away configuration, single overlay GET. Not needed for parity. No energy (Energy IQ / meter readings) endpoints are used.

### 5.20 Request budgeting and tado's daily limit

The plugin does **not** budget or throttle against tado's daily quota (tado limits accounts without a subscription to about 100 requests per day since 2025). What it does:
- one `zoneStates` call instead of one call per zone;
- `nightPolling`, `addJitter`, minimum polling 30 s;
- `tadoApiUrl` + `skipAuth` so users can put a caching proxy in front;
- a **request counter** per account (runtime instances only, not the discovery or UI instances): incremented after every successful API call and after every successful login-server call (device authorize, each token poll that returned, refresh, the identity `/me`); reset when the calendar date in **Europe/Berlin** changes; logged at info level ("tado API counter: N") 4 s after start and hourly; persisted every 5 minutes to `<storage>/tado-api-<h>.json` as `{ "counterData": { "counter": n, "counterTimestamp": "<ISO 8601>" } }` and restored at start.
- 429 responses are retried at most twice (section 4); nothing else backs off.

Requests per zone poll: `zones` + `zoneStates` (2), +1 `zones` if a configured zone lacks an id, +1 capabilities per AC zone with fan speed (first time only), +1 `mobileDevices` if any active user, +1 `weather` if weather enabled, +3 `minder` running-time calls if `runningInformation`, +1 `state` if presence lock, +1 `devices` if child locks. At the default 300 s that is at least 576 calls/day, far beyond 100. Each HomeKit write costs a GET state + PUT (+ the AC capabilities once), followed by a 2-call zone refresh (7.6). Token refreshes (login server) happen at most once per 9 minutes, on demand. To fit 100/day with zones only and no writes, `polling` must be at least about 1730 s. A drop-in replacement must at least behave the same; better budgeting is an improvement left to the implementer (mention in its docs).

---

## 6. Device model

### 6.1 Accessory set, names and identity seeds

`<H>` = `homes[].name`, `<Z>` = zone `name`, `<U>` = presence user `name`. The accessory display name **is** the identity seed: Homebridge derived each accessory UUID with `hap.uuid.generate(<display name>)` (SHA-1 of the UTF-8 string, laid out as a version-4-looking UUID: the 8-4-4-4-12 pattern where the third group starts with a literal `4`, the fourth group's first digit is `(nibble & 3) | 8`, and every other hex digit is taken from the SHA-1 hex in order; the literal `4` does not consume a digit). Keep the same seeds to keep HomeKit's rooms and automations.

| Accessory | Display name / seed | Created when | Model | Serial number |
|---|---|---|---|---|
| Zone | `<H> <Z> Heater` (HEATING), `<H> <Z> AC` (AIR_CONDITIONING), `<H> <Z> Boiler` (HOT_WATER) | active, valid zone | the zone type (`HEATING` etc.) | hash(display name) |
| Window contact | `<H> <Z> Window` | zone `openWindowSensor` | `zone-window-contact` | hash(`<Z>`) |
| Separate temperature | `<H> <Z> Temperature` | zone `separateTemperature` | `zone-temperature` | hash(`<Z>`) |
| Separate humidity | `<H> <Z> Humidity` | zone `separateHumidity` | `zone-humidity` | hash(`<Z>`) |
| Open window switches | `<H> Open Window` | ≥ 1 active zone with `openWindowSwitch` | `zone-window-switch` | hash(display name) |
| Presence user | `<H> <U>` | active user entry with name | `presence-motion` or `presence-occupancy` | hash(display name) |
| Anyone | `<H> Anyone` | `presence.anyone` and ≥ 1 user sensor created | as above | hash(display name) |
| Weather | `<H> Weather` | `weather.temperatureSensor` | `Weather Temperature` | hash(display name) |
| Solar | `<H> Solar Intensity` | `weather.solarIntensity` | `Solar Intensity` | hash(display name) |
| Central | `<H> Central Switch` | `extras.centralSwitch` and ≥ 1 valid active zone | `Central Switch` | hash(display name) |
| Presence lock | `<H> Presence Lock` | `extras.presenceLock` | `Presence Lock` | hash(display name) |
| Child lock | `<H> Child Lock` | ≥ 1 active child-lock entry | `extra-childswitch` | hash(display name) |

Serial "hash": the Java-style 32-bit string hash (h ← 31·h + code unit, wrapped to signed 32 bits at every step), absolute value, decimal string. Manufacturer `tado`; FirmwareRevision = the plugin version (Homebridge used `10.2.0`; Homeswift can use its own). Duplicate display names: the second one is skipped with a warning. Accessories cached but no longer configured are removed.

The internal kind ("subtype") of the zone accessory, which also is the **subtype of its primary service**:
- HEATING: `zone-thermostat`, or `zone-heatercooler` with `easyMode`;
- AIR_CONDITIONING: `zone-heatercooler-ac`;
- HOT_WATER: `zone-faucet` when `accTypeBoiler` is `FAUCET`, else `zone-switch`;
- any zone type with `boilerTempSupport: true`: `zone-heatercooler-boiler`.

Identity vectors (HAP UUID from seed / serial), computed by the spec writer:

| Seed | UUID | Serial of this seed |
|---|---|---|
| `My Home Living Room Heater` | `ab99b9ef-1f1f-45e2-adb8-a94aee74669c` | 1357935336 |
| `My Home Living Room Window` | `341ed0f5-07cd-4706-a686-facb5a376375` | (serial uses `Living Room` → 981103630) |
| `My Home Living Room Temperature` | `36243006-4b04-49fc-aa35-e3b59002d20a` | (981103630) |
| `My Home Living Room Humidity` | `37e4e696-258e-4870-9c7c-885209319980` | (981103630) |
| `My Home Bathroom Boiler` | `7ec5ffda-e331-48ae-ae1d-6c0ca295e309` | 1209459106 |
| `My Home Office AC` | `114e33aa-381a-4b17-9708-1e4c9aa13213` | 1928093991 |
| `My Home Open Window` | `68db60d9-bf85-4a1d-8213-1de03e56979d` | 1466203975 |
| `My Home Buddy 1` | `faa9c397-8b84-4d43-bc5d-1d9bf05483ea` | 1097948394 |
| `My Home Anyone` | `4f1822e5-071d-4df3-9fcf-c8f1307a2555` | 1661608185 |
| `My Home Weather` | `9565db25-6a38-4150-9d7c-8c795658a52d` | 2095282055 |
| `My Home Solar Intensity` | `b0326d58-eb0b-4b0a-801a-04494609a8ed` | 1977581305 |
| `My Home Central Switch` | `61687aa2-034c-4728-94ad-c060ff30758b` | 71916180 |
| `My Home Presence Lock` | `74221a68-9a87-41d5-9d19-505c8ebc6223` | 1372490077 |
| `My Home Child Lock` | `e1e74ef4-432b-44ea-969f-2d835b5fbf1b` | 1630848676 |

### 6.2 Services and their subtypes (for stable iids)

| Accessory kind | Services (name, subtype) |
|---|---|
| zone-thermostat | Thermostat (display name, `zone-thermostat`); Battery (no subtype) unless `noBattery` |
| zone-heatercooler / -boiler / -ac | HeaterCooler (display name, the kind string); Battery (no subtype) only for zone type HEATING and not `noBattery`; AC: Switch (`<display> Fan`, `FanModeSwitch`) if `acFanModeSwitch`, Switch (`<display> Dry`, `DryModeSwitch`) if `acDryModeSwitch` |
| zone-switch | Switch (display name, `zone-switch`) |
| zone-faucet | Valve (display name, `zone-faucet`) |
| zone-window-contact | ContactSensor (display name, `zone-window-contact`); Battery if zone type HEATING and not `noBattery` |
| zone-temperature | TemperatureSensor (display name, `zone-temperature`); Battery as above |
| zone-humidity | HumiditySensor (display name, `zone-humidity`); Battery as above |
| zone-window-switch | one Switch per zone: name and subtype both `<Z> Window` |
| presence-motion / presence-occupancy | MotionSensor / OccupancySensor (display name, the kind) |
| weather-temperature | TemperatureSensor (display name, `weather-temperature`); no battery |
| weather-lightbulb / weather-lightsensor | Lightbulb / LightSensor (display name, the kind) |
| extra-cntrlswitch | Switches: `Central`/`Central`, `Boost`/`CentralBoost`, `Shedule`/`CentralShedule`, `Off`/`CentralOff`, `Dummy`/`CentralDummy` (name/subtype), only the enabled ones |
| extra-plock | SecuritySystem (display name, `extra-plock`) |
| extra-plockswitch | Switch `Home`/`HomeSwitch`, Switch `Away`/`AwaySwitch` |
| extra-childswitch | one Switch per entry: name = entry `name`, subtype = entry `serialNumber` |

When the kind of a cached accessory changes, the old kind's services are removed (e.g. Thermostat ↔ HeaterCooler ↔ Switch ↔ Valve; SecuritySystem ↔ Home/Away switches; Motion ↔ Occupancy; Lightbulb ↔ LightSensor), and sub-switches no longer configured are removed.

### 6.3 Custom characteristics (UUIDs and props are interface facts)

| Name | UUID | Format, props | Perms | Used on |
|---|---|---|---|---|
| Delay ("DelaySwitch") | `b7c9db1a-e54e-4f4f-b3b4-17a19b2c4631` | bool | read, write, notify | zone thermostat/heater-cooler with `delaySwitch` (not HOT_WATER) |
| Timer ("DelayTimer") | `2e4eb630-62ab-41fe-bcc1-ea5c3cf98508` | int 0–120 step 10 (seconds) | read, write, notify | same |
| Mode Auto | `12edece0-36c8-427f-895c-3b88ea186388` | int 0–100 step 1 | read, notify | Central sub-switch |
| Mode Manual | `2be09385-4dc3-4438-9fee-b5b2e0642004` | int 0–100 step 1 | read, notify | Central sub-switch |
| Mode Off | `93131984-615c-401b-84ac-54e22db492c6` | int 0–100 step 1 | read, notify | Central sub-switch |
| Activity Day | `43c89074-b70a-480c-8239-51697a9db445` | float 0–99999 step 0.01 (hours) | read, notify | Central, with `runningInformation` |
| Activity Month | `1874332a-d7dd-4e45-9d65-a4baa6d11121` | same | read, notify | same |
| Activity Year | `d105b9f7-afe7-44a2-9cbe-f079ba499733` | same | read, notify | same |
| Eve Valve Position | `E863F12E-079E-48FF-8F27-9C2605A29F52` | uint8 percentage | read, notify | added to every Thermostat and HeaterCooler service; never updated (stays 0) |
| Eve Last Activation | `E863F11A-079E-48FF-8F27-9C2605A29F52` | uint32 seconds | read, notify | ContactSensor, MotionSensor |
| Eve Times Opened | `E863F129-079E-48FF-8F27-9C2605A29F52` | uint32 | read, notify | ContactSensor |
| Eve Reset Total | `E863F112-079E-48FF-8F27-9C2605A29F52` | uint32 seconds | read, write, notify | ContactSensor |
| Eve Open Duration | `E863F118-079E-48FF-8F27-9C2605A29F52` | uint32 seconds | read, write, notify | ContactSensor (never updated) |
| Eve Closed Duration | `E863F119-079E-48FF-8F27-9C2605A29F52` | uint32 seconds | read, write, notify | ContactSensor |

### 6.4 Thermostat (HEATING, `easyMode` false)

- TargetHeatingCoolingState: valid values 0 (OFF), 1 (HEAT), 3 (AUTO); a cached value 2 is turned into 1.
- CurrentHeatingCoolingState: 0 or 1.
- CurrentTemperature: props −255…255.
- TargetTemperature: min/max per 2.3 (thermostat rule), step per `minStep`; a cached value outside is clamped at start.
- CurrentRelativeHumidity present unless `separateHumidity`.
- TemperatureDisplayUnits: writable (6.10).
- Delay/Timer per `delaySwitch`.
- Battery: BatteryLevel, ChargingState NOT_CHARGEABLE (2). StatusLowBattery is never set (stays normal).

### 6.5 HeaterCooler

Common: Active; CurrentTemperature −255…255; HeatingThresholdTemperature (always) with min/max/step per 2.3 (heater-cooler rule), cached value clamped (non-finite → min); ValvePosition; TargetHeaterCoolerState forced to 1 at start.

- HEATING with `easyMode` (`zone-heatercooler`): CurrentHeaterCoolerState valid 0–3; TargetHeaterCoolerState only 1 (HEAT); CoolingThresholdTemperature present with the same props (mirrors the heating threshold); humidity unless `separateHumidity`; battery; delay characteristics.
- HOT_WATER with `boilerTempSupport` (`zone-heatercooler-boiler`): CurrentHeaterCoolerState valid 0, 1, 2; TargetHeaterCoolerState only 1; no CoolingThreshold, no humidity, no battery, no delay characteristics. Default/last temperature for the write buffer starts at the min value; temperatures are clamped into [min, max].
- AIR_CONDITIONING (`zone-heatercooler-ac`): CurrentHeaterCoolerState 0–3; TargetHeaterCoolerState valid 1 (HEAT) and 2 (COOL); CoolingThresholdTemperature present (its props are left at the HAP defaults, the heating threshold gets the configured range); humidity unless `separateHumidity`; **no battery service** (battery only for HEATING); RotationSpeed if `acFanSpeed`; Fan/Dry mode switches. Delay characteristics can be added (`delaySwitch`), but the delay logic is skipped for AC.

### 6.6 Hot water switch / faucet

- `zone-switch`: Switch.On.
- `zone-faucet`: Valve with Name, IsConfigured CONFIGURED, StatusFault NO_FAULT, ValveType WATER_FAUCET (3); Active and InUse.

### 6.7 Sensors

- Window contact: ContactSensorState (1 = open), Eve characteristics (6.3). Battery per 6.2.
- Temperature: CurrentTemperature props −100…100.
- Humidity: CurrentRelativeHumidity.
- Presence: MotionDetected (bool, with Eve LastActivation) or OccupancyDetected (0/1).
- Weather temperature: TemperatureSensor.
- Solar lightbulb: On + Brightness (read-only in effect: any write is reverted 500 ms later to the last polled values). Solar light sensor: CurrentAmbientLightLevel.

### 6.8 Security system (presence lock, ALARM)

Name; SecuritySystemAlarmType 0; StatusFault NO_FAULT; StatusTampered NOT_TAMPERED; Current and Target states restricted to 0 (STAY_ARM = Home), 1 (AWAY_ARM = Away), 3 (DISARMED = Auto/unlocked). In Homeswift this is a security control (set via `set_security_accessory`).

### 6.9 Mapping summary

| tado | HomeKit |
|---|---|
| HEATING zone | Thermostat, or HeaterCooler (easyMode) |
| HOT_WATER zone | Switch or Valve (faucet), or HeaterCooler (boilerTempSupport) |
| AIR_CONDITIONING zone | HeaterCooler (+ RotationSpeed, Fan/Dry switches) |
| zone humidity | humidity characteristic or separate sensor |
| zone battery | Battery service (level 100 normal / 10 otherwise) |
| open window | ContactSensor; detection toggle as Switch |
| mobile device at home | Occupancy / Motion |
| home presence lock | SecuritySystem or Home/Away switches |
| child lock | Switch per valve |
| weather | TemperatureSensor; Lightbulb or LightSensor |

### 6.10 Temperature units

- Values read from tado are taken from the `celsius` or `fahrenheit` field according to the **home** `temperatureUnit`, and written as-is into HomeKit temperature characteristics. With FAHRENHEIT, Fahrenheit numbers go into characteristics HomeKit treats as Celsius (and the limits are 41–77 / 86–149). This is the plugin's behaviour; reproduce it for parity or document a deliberate change.
- Writes: an accessory whose unit is FAHRENHEIT converts the target to Celsius before sending (unrounded).
- Thermostat TemperatureDisplayUnits write: 0 → the accessory unit becomes CELSIUS and CurrentTemperature is immediately converted F→C (rounded to integer); 1 → FAHRENHEIT and C→F (rounded). Then the home's `temperatureUnit` in the stored configuration is changed to match (persisted; takes full effect on restart).
- During polling, if the accessory's unit differs from the home's unit, the current temperature is converted (rounded) according to the display-unit characteristic (1 → to °F, else → to °C).

---

## 7. Behaviour

### 7.1 Start and polling

- At start, per home, the first poll runs immediately; each next poll is scheduled after the previous one finished, with interval = night interval during local hours 0–5 if `nightPolling` is set, else `polling`; ±10 % random (rounded ms) if `addJitter`.
- A poll does, in order: resolve home id (if missing, 2.2), fetch unit (if missing), zones (if any active zone), mobile devices (if any active user), weather (if temperature or solar enabled), running time (if central switch and `runningInformation`), presence lock (if enabled), devices (if any child lock). An exception in one step aborts the rest of that poll (logged); the next poll is still scheduled.
- Each step is skipped while any write (7.3) of the same home is in progress.
- Zone updates are serialized: if one is running when another is requested, one more run is queued.
- Zone states are also written to `<storage>/tado-states-<homeId>.json` (`{ "zoneStates": ... }`) at most every 10 s; a debugging artefact, not read back.

### 7.2 The 400 ms write buffer (Thermostat and HeaterCooler only)

Writes to TargetHeatingCoolingState / Active ("state") and TargetTemperature / HeatingThreshold / CoolingThreshold (AC only) ("temperature") are not sent directly. Each write stores the latest state or temperature and restarts a 400 ms timer. When it fires, the pending state and temperature are taken and cleared, and **at most one** action is sent:

1. The temperature is normalized: non-numeric → none; below the minimum → none (HOT_WATER heater-cooler: clamped to the minimum); above the maximum → unchanged (HOT_WATER: clamped to the maximum); otherwise rounded to 2 decimals. Minimum is 5 and maximum none for the Thermostat; the configured range for HeaterCooler. A temperature of exactly 5 is the "Siri auto" marker and stays 5.
2. The last temperature is remembered whenever a temperature was set (except a 5 when `preferSiriTemperature` is on). Initial last temperature: 20 (HOT_WATER heater-cooler: its minimum).
3. If `preferSiriTemperature` and the state is 3 and a temperature is set: temperature 5 → send state 3 (AUTO); otherwise → send that temperature only (ignore the AUTO).
4. Otherwise: state 0 → send state OFF; state 3 → send state AUTO; a temperature is set → send the temperature; state 1 → send the last temperature. Nothing pending → nothing.

So "turn on" (HEAT / Active 1) always becomes "set temperature T" (power ON with T), never a bare state 1.

### 7.3 Zone writes (after the buffer)

For each write: mark "write in progress" for the home, log `<target>: <value>` at info level.

The zone id is the accessory's stored id, else the configured zone matched by type and name (display name equal to `<H> <Z> <suffix>`, or equal to / ending with `<Z> <suffix>`), else resolved from `GET /zones` by name and type; if still unknown → error log, no request.

Thermostat / heater-cooler (not AC), value V:
- **Delay path**: if kind is not boiler or AC, `autoOffDelay` off, `delaySwitch` on, the Delay characteristic is currently on, Timer > 0, and V < 5:
  - V = 0 → cancel any pending delayed action, send OFF immediately (overlay, power OFF, current target temperature read from the characteristic, termination per mode).
  - else → cancel the previous pending action and, after Timer seconds: if V = 3, or (V non-zero, zone mode AUTO and kind is a heater-cooler) → DELETE overlay; else overlay power ON with the characteristic's current target temperature, termination per mode. No follow-up refresh for delayed actions.
- **Normal path**: V in {0, 1, 3} → state: V = 3 → DELETE overlay (back to schedule). V = 1 with mode CUSTOM on a heater-cooler → DELETE overlay. V = 0 → overlay power OFF (termination MANUAL instead of the mode when mode is CUSTOM on a heater-cooler; else per mode). V = 1 otherwise → overlay power ON with the current target-temperature characteristic value. Any other V → temperature: overlay power ON with temperature V.
- The temperature sent is rounded to 2 decimals and, for HOT_WATER, clamped to the limits.

AIR_CONDITIONING, value V (no delay path):
- V = 3 → DELETE overlay.
- otherwise AC mode from the current TargetHeaterCoolerState: 1 → HEAT, 2 → COOL, else AUTO. V = 0 → AC overlay OFF. V = 1 → AC overlay ON with the current HeatingThreshold value. Other V (temperature) → AC overlay ON, the temperature re-read from HeatingThreshold when HEAT, CoolingThreshold when COOL (so the written threshold wins).
- TargetHeaterCoolerState itself has **no write handler**: changing Heat↔Cool alone sends nothing; it takes effect with the next Active or threshold write (the Home app usually sends Active too).
- After an AC overlay, the stored AC mode is the new mode if ON, none if OFF, and the Fan/Dry switches are set to (mode = FAN) / (mode = DRY).
- Fan speed (RotationSpeed write, not buffered): 0 → ignored (Active handles off). Mode = stored AC mode, else HEAT if target state 1, else COOL. Steps from that mode's capabilities (7.5); none → warning, nothing sent. The level is stored; 500 ms later RotationSpeed is snapped to the level's exact percentage. If the AC is off (Active 0 and no stored mode) → nothing sent, the level is used on the next turn-on. Else AC overlay ON with that mode, the level, temperature from HeatingThreshold (target state 1) or CoolingThreshold.
- Fan / Dry switch: off → AC overlay OFF. On → if capabilities are known and lack `FAN`/`DRY` → warning, switch reverted after 500 ms; else AC overlay ON with mode FAN/DRY (fan level per 5.8).
- The fan level is sent only if `acFanSpeed` is on; otherwise the AC's current level is kept.

HOT_WATER switch / faucet: On / Active → overlay power ON (no temperature) or OFF, termination per mode (configured zone type HOT_WATER). Faucet InUse is set to the written value immediately. (An AC zone exposed as a switch would send an AC overlay with mode COOL; not reachable from valid config.)

Presence lock: SecuritySystem target 1 → AWAY (PUT), 3 → AUTO (DELETE), anything else (0) → HOME (PUT); the current state is set to the target immediately. Switches: Home on → HOME (Away switch shown off); Away on → AWAY (Home shown off); either turned off → AUTO (both shown off).

Open window switch for zone id N: PUT detection `{enabled: value, timeoutInSeconds: 3600}`, then activate (on) / DELETE (off) the open-window state.

Child lock switch: PUT child lock for the entry's `serialNumber`.

Central switch (zones = all configured zones of the home with an id and type HEATING, **active or not**); local optimistic updates apply to the home's HEATING-type accessories:
- Central on, or Shedule on → `DELETE /homes/{h}/overlay?rooms=...`; show every heating Thermostat as target AUTO (3) and every HeaterCooler as Active 1; Central shown on. (Shedule then turns back off after 500 ms.)
- Boost on → `POST /homes/{h}/overlay` with every zone power ON at 25 °C (77 °F), termination per zone mode; show thermostats current HEAT, target HEAT, target temperature = its max; heater-coolers Active 1 and heating threshold = its max; Central shown on; Boost turns back off after 500 ms.
- Off on → POST with every zone power OFF (no temperature); show thermostats current/target OFF, heater-coolers Active 0; Central shown off; Off turns back off after 500 ms.
- Central off → same as "Off on" but without a sub-switch reset.
- Boost/Shedule/Off turned off → nothing.
- Dummy → state kept in the accessory's persistent context, no API call.

After a write: unless another write of the home is still in progress, a zone request was attempted (even if it failed), and the next poll is more than 10 s away, the zone states are refreshed immediately (`zones` + `zoneStates`). Errors are logged ("failed to set states"); HomeKit is not told of the failure and the characteristic keeps the written value until the next poll.

Delay characteristics: without `autoOffDelay`, Delay and Timer are plain stored values (in the accessory's persistent context). With `autoOffDelay`, turning Delay on with Timer > 0 starts a timer that turns Delay back off after Timer seconds; turning it off cancels it; Delay starts off.

### 7.4 CUSTOM mode, as it actually behaves

Because the buffer (7.2) converts "turn on" to a temperature write, V = 1 never reaches 7.3 from HomeKit, so CUSTOM's "turn-on clears the overlay" rule is effectively unreachable; turn-off sends an OFF overlay with MANUAL termination, turn-on sends an ON overlay with MANUAL termination. Similarly the delay path's "mode AUTO on a heater-cooler clears the overlay" uses AUTO where the normal path uses CUSTOM.

### 7.5 AC fan levels ↔ RotationSpeed

Levels come from the mode's capability `fanLevel` (else `fanSpeeds`). Manual levels (all but `AUTO`) are ordered by the rank list `SILENT, LOW, LEVEL1, MIDDLE, LEVEL2, LEVEL3, HIGH, LEVEL4, LEVEL5` (unknown levels after them, in their original order); `AUTO`, if supported, is appended last. With N steps, step i (1-based) shows as round(i·100/N) %. A written percentage p > 0 maps to step clamp(round(p·N/100), 1, N). Example: [LOW, MIDDLE, HIGH, AUTO] → 25, 50, 75, 100; p = 60 → MIDDLE (round(2.4) = 2); p = 10 → LOW.

### 7.6 Zone poll: state mapping

For each configured active zone with a resolved id; zones without id or without a state (or without `setting`) are skipped with a warning. Accessories are matched to a zone by **substring**: the accessory display name contains `<Z>` (8.9).

From `GET /zones` (before `zoneStates`): the zone id is refreshed (by name and type) on the zone and on matching accessories; `openWindowEnabled` = `openWindowDetection.enabled`; battery state = unless `noBattery`: for HEATING/AC zones the first device whose `batteryState` is not `NORMAL`, else the `batteryState` of the device with duty `ZONE_LEADER` (a zone without leader device throws and aborts the zone update). Battery level shown = 100 if that state is `NORMAL`, else 10 (also 10 when unknown).

If `setting.type` is `HEATING`:
- humidity = `sensorDataPoints.humidity.percentage`.
- only if `insideTemperature` exists: current = its value in the home unit; if power ON: target = setting temperature; currentState = 1 if current < target else 0; targetState = 3 if `overlayType` is null else 1; active 1; tempEqual = rounded current equals rounded target. If power OFF: currentState 0, targetState 0, active 0.
- Thermostat: CurrentTemperature (unit rule 6.10), TargetTemperature, Current/Target state, humidity (if present); battery level if a battery service and battery state.
- HeaterCooler (easyMode; also any AC heater-cooler whose name contains the zone name): Active; CurrentTemperature; both thresholds = target; CurrentHeaterCoolerState = 0 if inactive, else 1 (IDLE) when on schedule or tempEqual, else 2 (HEATING) if current < target, else 1; TargetHeaterCoolerState 1; humidity.

Otherwise (`HOT_WATER`, `AIR_CONDITIONING`):
- humidity and current temperature as available.
- power ON: active 1, target = setting temperature (may be absent). AC: AC mode = `setting.mode` or COOL; tempEqual = both present and |current − target| < 0.5; FAN/DRY → target state 2, current 1; HEAT → target 1, current 1 if tempEqual else (2 if current < target else 1); COOL/AUTO/other → target 2, current 1 if tempEqual else (3 if current > target else 1). Not AC: current = 1 if `overlayType` null else 2; target 1.
- power OFF: active 0, current 0, no target temperature, target state 2 for AC, 1 otherwise.
- HeaterCooler (boiler and AC kinds): Active, Current/Target state, CurrentTemperature — for HOT_WATER without a reading: last shown value, else target, else zone `minValue`, else 30; both thresholds = target (cooling only if present). AC: stored mode (power ON only), Fan/Dry switches, and if `acFanSpeed` and the level (`fanLevel` or `fanSpeed`) maps to a step: RotationSpeed and stored level. Humidity if present.
- Switch (`zone-switch`): On = active. Valve (`zone-faucet`): Active = InUse = active.

For every zone (both branches): separate temperature sensors (battery level, current temperature if present), separate humidity sensors (battery, humidity), window contact (battery; ContactSensorState = 1 if `openWindow` is non-null or `openWindowDetected` true), open-window switch whose subtype contains `<Z>` (On = `openWindowEnabled`).

Central switch counters, over zones whose `setting.type` is HEATING: auto = `overlayType` null; off = overlay and power OFF; manual = overlay, power ON and `overlay.termination` present. Mode Auto/Manual/Off characteristics = those counts; Central On = (manual or auto count) non-zero (the expression effectively tests "manual non-zero, else auto non-zero").

### 7.7 Other polls

- Presence: for each mobile device, the user accessory named `<H> <device name>` gets detected = `location.atHome`. Anyone = 1 if at least one matched user accessory is at home (devices without a configured accessory do not count).
- Weather: TemperatureSensor = `outsideTemperature` in the home unit (only if present). Solar: on = percentage ≠ 0, brightness = percentage (also stored for the revert in 6.7); light sensor lux = percentage·1000, or 0.0001 when 0.
- Running time: three requests 500 ms apart: day (`aggregate=day`, `from` = today); month (`aggregate=month`, `from` = (today − 1 day) − 1 month, day clamped to month length); year (`aggregate=year`, `from` = (first day of next month) − 1 year, `to` = today). Activity Day/Month/Year = `summary.totalRunningTimeInSeconds` / 3600.
- Presence lock: state = 3 if not `presenceLocked`, else 1 for AWAY, 0 for HOME. Security current and target = state; switches Home on iff 0, Away on iff 1.
- Child locks: for each device in `GET /devices`, the switch whose subtype equals `serialNo` gets On = `childLockEnabled` (missing → false). Note the configured serial comes from `shortSerialNo`; they are equal for tado devices in practice.

### 7.8 Change-driven side effects

When a sensor value changes (old ≠ new):
- Window contact opened: Times Opened +1 (persistent context); Last Activation and Closed Duration = now − reference time, where the reference time is the first time the accessory needed one (stored in context, Unix seconds); closed: Closed Duration = now − reference. Telegram `openWindow.opened` / `closed`.
- Presence: motion sensors also set Last Activation the same way. Telegram `presence.user_in/user_out` or `anyone_in/anyone_out`.
- Reset Total write: Reset Total = seconds since 2001-01-01T00:00:00Z, Times Opened = 0.

### 7.9 Unreachable / error handling

- No "No Response" signalling: failures are logged and characteristics keep their last values. Polls continue at the normal interval (no backoff beyond section 4).
- A home whose first poll cannot resolve its id keeps failing every poll.
- Device authorization in progress blocks the home's polling until it completes or times out (default 300 s); the next poll starts a new authorization if still needed, logging a new URL each time.

---

## 8. Edge cases and quirks (preserve unless deliberately changed)

8.1 Zone id 0 is valid everywhere except the central "resume schedule" room list.
8.2 Accessory-to-zone matching uses "name contains zone name": zone `Bath` also updates `My Home Bathroom Boiler` and the like. HEATING state updates any Thermostat/HeaterCooler (easy or AC kind) whose name contains the zone name.
8.3 A HEATING zone with `boilerTempSupport: true` becomes a `zone-heatercooler-boiler` HeaterCooler that the HEATING poll never updates (its kind is not in the HEATING branch's list).
8.4 Separate temperature/humidity/window sensors inherit the zone's type, so non-HEATING zones never get batteries on them.
8.5 The Anyone sensor exists only if at least one user sensor was created.
8.6 `presence.user[].name` and child-lock `name` and zone `name` are required; see 8.9 for the sticky skip.
8.7 Telegram is global (last configured home wins).
8.8 Writing a thermostat's display unit rewrites the home's `temperatureUnit` in the stored config.
8.9 Bugs observed in the source (decide per case; listed so behaviour can be matched or fixed knowingly):
  - The "zone has no name" skip flag is not reset per zone: once a nameless active zone is seen, every later active zone of the same home is skipped too. Same for presence users and child-lock entries.
  - Central TIMER duration is modeTimer·3600 s instead of modeTimer·60 s (5.10).
  - Central switch includes inactive HEATING zones.
  - `boilerTempSupport` overrides the kind for any zone type (8.3).
  - Delay path cancels/schedules per accessory display name; delayed actions do not trigger the follow-up refresh.
  - `modeTimer` missing → 1 minute (not 30).
  - FAHRENHEIT values are written to HomeKit as if Celsius (6.10).
  - Battery service never sets StatusLowBattery.

---

## 9. Logging (paraphrased) and secrets

Info:
- requesting device authorization; "open this URL and sign in as <username> (use a private window if signed in to another account): <verification URL>"; "waiting for confirmation" per poll of the device code; authentication successful.
- per write: "<target>: <value>" with the accessory name (e.g. "Temperature: 21.5", "State: 0", "Home: true", "<serial>: true").
- "delay: wait N seconds", "delay timer finished, switching to <state>", "resetting delay timer", "timer expired, turning off delay switch".
- service added/removed messages on start ("Adding Thermostat service", "Removing Battery service"…), "configuring new accessory", "removing accessory".
- hourly "tado API counter: N".
- discovery: "refreshing home", "generating new home", "storing config", "done".
Warn:
- home/zone/user/child-lock skipped for missing name/username; invalid zone type defaulted; missing zone id (will be resolved); duplicate names skipped; zone skipped for missing id or state; refresh token rejected; empty tokens; could not read zone state / capabilities; fan speed or FAN/DRY mode not supported; token file read attempts failing.
Error:
- "API request failed" with method, URL, message, status and **response body**; failed to set/get states; failed to update zones; cannot resolve zone id; token file write failed; config store failures; Telegram errors.
Debug (only with `debug`):
- every API request (method, URL, query, **JSON body**) and every success (status and **full response body**); update-buffer decisions; per-zone state dumps; values set on thermostats; central switch counters.

Secrets and personal data:
- Secrets: access token, refresh token, device code, Telegram bot `token` (also embedded in the Telegram URL), any legacy `password`. None of these is logged by the plugin (the token URL of Telegram is not logged).
- Sensitive: the device-authorization verification URL contains the user code (logged at info; it is short-lived and needed by the user); the username/e-mail (logged); debug bodies contain e-mail, names of people (mobile devices), home geolocation and device serial numbers.
- In Homeswift: `telegram.token` and `password` sit under secret-named keys; the refresh token goes to the vault; never log the device code or tokens.

---

## 10. Test vectors (personal data replaced)

### 10.1 Zone states (`GET /homes/123456/zoneStates`)

```json
{ "zoneStates": {
  "1": { "tadoMode": "HOME", "overlayType": null, "overlay": null, "openWindow": null, "openWindowDetected": false,
         "setting": { "type": "HEATING", "power": "ON", "temperature": { "celsius": 21.0, "fahrenheit": 69.8 } },
         "sensorDataPoints": { "insideTemperature": { "celsius": 19.6, "fahrenheit": 67.28 },
                               "humidity": { "type": "PERCENTAGE", "percentage": 48.2 } } },
  "2": { "overlayType": "MANUAL",
         "overlay": { "type": "MANUAL", "setting": { "type": "HEATING", "power": "OFF", "temperature": null },
                      "termination": { "type": "MANUAL", "typeSkillBasedApp": "MANUAL" } },
         "openWindow": null, "openWindowDetected": true,
         "setting": { "type": "HEATING", "power": "OFF", "temperature": null },
         "sensorDataPoints": { "insideTemperature": { "celsius": 17.0, "fahrenheit": 62.6 },
                               "humidity": { "percentage": 55.0 } } },
  "0": { "overlayType": null, "setting": { "type": "HOT_WATER", "power": "ON", "temperature": { "celsius": 55.0, "fahrenheit": 131.0 } },
         "sensorDataPoints": {} },
  "5": { "overlayType": "MANUAL", "overlay": { "termination": { "type": "MANUAL" } },
         "setting": { "type": "AIR_CONDITIONING", "power": "ON", "mode": "COOL",
                      "temperature": { "celsius": 22.0, "fahrenheit": 71.6 }, "fanLevel": "LEVEL2",
                      "verticalSwing": "OFF", "horizontalSwing": "OFF", "light": "ON" },
         "sensorDataPoints": { "insideTemperature": { "celsius": 25.3, "fahrenheit": 77.54 }, "humidity": { "percentage": 60.1 } } }
} }
```

Expected HomeKit (home unit CELSIUS):
- Zone 1 Thermostat: Current 19.6, Target 21, CurrentHeatingCooling 1, TargetHeatingCooling 3, humidity 48.2. As easyMode HeaterCooler: Active 1, Current state 1 (on schedule), Target 1, thresholds 21.
- Zone 2 Thermostat: Current 17, Current/Target state 0 (TargetTemperature unchanged). Window contact = 1 (openWindowDetected). Central counters with zones 1 and 2: auto 1, off 1, manual 0 → Central On true.
- Zone 0 boiler HeaterCooler: Active 1, Current state 1, Target 1, CurrentTemperature = previous value, else 55 (target). As switch: On true. As faucet: Active 1, InUse 1.
- Zone 5 AC: Active 1, target state 2, current 3 (25.3 > 22, not within 0.5), thresholds 22; with capabilities COOL `fanLevel: [LEVEL1, LEVEL2, LEVEL3, AUTO]` → RotationSpeed 50.

### 10.2 Overlay bodies per HomeKit write (home 123456)

Zone 1 (HEATING, CELSIUS), current state `setting = {"type":"HEATING","power":"ON","temperature":{"celsius":21.0}}`:

| HomeKit write (after buffer) | mode | Request |
|---|---|---|
| TargetTemperature 22.5 | MANUAL | `PUT /api/v2/homes/123456/zones/1/overlay` `{"setting":{"type":"HEATING","power":"ON","temperature":{"celsius":22.5}},"termination":{"type":"MANUAL"}}` |
| TargetTemperature 22.5 | AUTO | same setting, `"termination":{"type":"TADO_MODE"}` |
| TargetTemperature 22.5 | TIMER, modeTimer 30 | same setting, `"termination":{"type":"TIMER","durationInSeconds":1800}` |
| TargetHeatingCoolingState 0 | MANUAL | `{"setting":{"type":"HEATING","power":"OFF","temperature":null},"termination":{"type":"MANUAL"}}` |
| TargetHeatingCoolingState 3 | any | `DELETE /api/v2/homes/123456/zones/1/overlay` |
| TargetHeatingCoolingState 1 (alone) | MANUAL | becomes temperature = last temperature (20 if none yet): `{"setting":{"type":"HEATING","power":"ON","temperature":{"celsius":20}},"termination":{"type":"MANUAL"}}` |
| State 3 + TargetTemperature 21 within 400 ms, preferSiriTemperature false | — | DELETE overlay (state wins) |
| same, preferSiriTemperature true | MANUAL | PUT with temperature 21 |
| State 3 + TargetTemperature 5, preferSiriTemperature true | — | DELETE overlay |

Each PUT is preceded by `GET /api/v2/homes/123456/zones/1/state`.

FAHRENHEIT home, TargetTemperature 70 → `"temperature":{"celsius":21.11111111111111}` (unrounded IEEE double, as JSON-serialized).

Zone 0 (HOT_WATER switch, mode AUTO): On true → `{"setting":{"type":"HOT_WATER","power":"ON","temperature":null},"termination":{"type":"TADO_MODE"}}`; On false → power OFF, temperature null. Boiler HeaterCooler (min 30, max 65), threshold write 70 → temperature 65; Active 1 alone → temperature 30 (initial last temperature) unless a temperature was written before.

Zone 5 (AC, mode TIMER, modeTimer 60), current setting as in 10.1, capabilities `COOL: { temperatures: {...}, fanLevel: [LEVEL1, LEVEL2, LEVEL3, AUTO], verticalSwing: [OFF, ON], horizontalSwing: [OFF, ON], light: [OFF, ON] }`, `FAN: { fanLevel: [LEVEL1, LEVEL2, LEVEL3, AUTO] }`:
- CoolingThreshold 21 with TargetHeaterCoolerState 2: `{"setting":{"type":"AIR_CONDITIONING","power":"ON","mode":"COOL","temperature":{"celsius":21},"fanLevel":"LEVEL2","verticalSwing":"OFF","horizontalSwing":"OFF","light":"ON"},"termination":{"durationInSeconds":3600,"typeSkillBasedApp":"MANUAL"}}`
- Active 0: `{"setting":{"type":"AIR_CONDITIONING","power":"OFF","mode":"COOL"},"termination":{"durationInSeconds":3600,"typeSkillBasedApp":"MANUAL"}}`
- Fan switch on: `{"setting":{"type":"AIR_CONDITIONING","power":"ON","mode":"FAN","fanLevel":"LEVEL2"},"termination":{...}}` (current LEVEL2 is supported in FAN; with no current level it would be AUTO).
- RotationSpeed 100 (acFanSpeed) in COOL: as the first example with `"fanLevel":"AUTO"`.

Central switch, zones 1 (MANUAL) and 2 (TIMER, modeTimer 30):
- Boost on: `POST /api/v2/homes/123456/overlay` `{"overlays":[{"room":1,"overlay":{"setting":{"power":"ON","type":"HEATING","temperature":{"celsius":25,"fahrenheit":77}}},"termination":{"typeSkillBasedApp":"MANUAL"}},{"room":2,"overlay":{"setting":{"power":"ON","type":"HEATING","temperature":{"celsius":25,"fahrenheit":77}}},"termination":{"typeSkillBasedApp":"TIMER","durationInSeconds":108000}}]}`
- Off on: same rooms, `"power":"OFF"`, no temperature.
- Central on / Shedule on: `DELETE /api/v2/homes/123456/overlay?rooms=1,2`

Presence lock: Away → `PUT /api/v2/homes/123456/presenceLock` `{"homePresence":"AWAY"}`; Disarm → `DELETE` same path with body `{"homePresence":"AUTO"}`.
Open window switch for zone 2 on → `PUT /api/v2/homes/123456/zones/2/openWindowDetection` `{"enabled":true,"timeoutInSeconds":3600}` then `POST /api/v2/homes/123456/zones/2/state/openWindow/activate`.
Child lock on → `PUT /api/v2/devices/VA0000000001/childLock` `{"childLockEnabled":true}`.

### 10.3 Token exchanges (values fake)

- `POST https://login.tado.com/oauth2/token` body `client_id=1bb50063-6b0c-4d11-bd99-387f4a91cc46&grant_type=refresh_token&refresh_token=RT1` → `{"access_token":"AT2","refresh_token":"RT2","expires_in":599,"token_type":"Bearer"}` → store AT2/RT2; RT1 is never used again.
- Same with RT1 rejected (`400 {"error":"invalid_grant"}`) → device authorization starts.
- Same with a 503 → error, RT1 kept, next call retries the refresh.
- Device code poll `400 {"error":"authorization_pending"}` → continue; `400 {"error":"slow_down"}` → interval +5 s; `400 {"error":"access_denied"}` → stop.

---

## 11. Gaps and hard parts

- Identity: seeds are display names (home name + zone name + suffix); renaming a home or zone in config changes identity, as in Homebridge. The UUID algorithm is Homebridge's, not part of this repository; vectors in 6.1 were computed by the spec writer.
- Rate limit: the plugin has no budget; at defaults it exceeds 100/day by a factor of five or more. Whether login-server calls count against tado's quota could not be determined from the source (the plugin counts them).
- The 9-minute access-token lifetime is a plugin assumption; tado's `expires_in` (about 10 minutes) is ignored.
- Shared refresh token between several homes on one account: the plugin creates one API client per home with the same token file; concurrent refreshes from two homes could race (each has its own in-memory token and single-flight guard). A port should share token state per username.
- Exact tado response shapes beyond the fields listed are not in the repository; examples marked [tado, typical] are illustrative.
- `typeSkillBasedApp: "AUTO"` in central-switch overlays and the TIMER ×60 duration are likely wrong against tado's API; tado's acceptance could not be verified.
- Fahrenheit homes write Fahrenheit numbers into HomeKit temperature characteristics; matching it keeps parity, fixing it changes what users see.
- The settings UI's "exec any API method" bridge and the config.json rewriting (legacy `user[]`, display-unit write) are Homebridge-specific; in Homeswift they map to Setup and to config updates through the host.
- Behaviour on HAP characteristic "change" events at startup (Telegram on first poll after restart) depends on Homebridge restoring cached values; with an empty cache the first poll may fire open/close or in/out messages.
