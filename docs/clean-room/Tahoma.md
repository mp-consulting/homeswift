# Somfy TaHoma (Overkiz): functional specification (clean room)

## 0. Provenance

| | |
|---|---|
| Primary source | https://github.com/dubocr/homebridge-tahoma (npm `homebridge-tahoma`, display name "Homebridge TaHoma", version 2.2.64), commit `cdfcc5988e62ec2bb45267ac0dad4b33ffabbacd` (shallow clone of the default branch, committed 2026-09-05) |
| Client library | https://github.com/dubocr/overkiz-client (npm `overkiz-client`, "Overkiz API Client", version 1.0.23; the plugin depends on `^1.0.23`), commit `1605feb9cbe4c60682e8dba698cf093ad7ba1a7b` (2026-07-31) |
| Second source | https://github.com/iMicknl/python-overkiz-api (PyPI `pyoverkiz` 2.3.1), commit `5f31858570e14be4f58e6cc58b7a448000556449` (2026-10-28). Consulted for the local API, server endpoints per brand/region, error codes, retry policy and JSON fixtures |
| Licences | `homebridge-tahoma`: Apache License 2.0 (LICENSE file is the bare licence text with no copyright line; `package.json` names the author "Romain DUBOC <dubocr@gmail.com>"). `overkiz-client`: Apache License 2.0 (same, bare text, no copyright line; author "Romain DUBOC"). `pyoverkiz`: MIT, "Copyright (c) 2020 Mick Vleeshouwer" |
| Third-party behaviour described from use only | `axios` (HTTP), `bonjour` (mDNS browse), `uuid` (v5), `moment` (time-of-day window) |

This document was written by the spec writer; it contains no source code. Identifiers that form the interface (JSON keys,
URLs, header names, Overkiz command and state names, uiClass/widget names, enum strings, characteristic UUIDs) are quoted
exactly because a compatible implementation needs them. Everything else is paraphrase. Nothing from the repositories was
installed or executed (only the pyoverkiz JSON fixtures were read as data, and the Overkiz root CA certificate file was
inspected with `openssl x509` as data).

Source tags used below: **[HT]** homebridge-tahoma, **[OC]** overkiz-client, **[PY]** pyoverkiz. A fact without a tag is
from [HT]/[OC]. Where the source is buggy, the literal behaviour is described first and a fix is labelled
**Recommendation**.

Words: **setup** = everything one Overkiz account (or one local gateway) holds; **device** = one entry of the setup's
device list, identified by its `deviceURL`; **main device** = a device whose `deviceURL` has no `#` suffix or `#1`;
**sub-device** = `#2`, `#3`, ...; **mapper** = the per-device HomeKit adapter chosen from the device's uiClass/widget;
**execution** = one `exec/apply` request and its life on the server (`execId`); **stateless** device = one that reports no
usable states (RTS motors, typically).

---

## 1. Scope and supported devices

The plugin is a Homebridge dynamic platform that mirrors an Overkiz setup into HomeKit. Overkiz is the cloud and gateway
platform behind:

- Somfy TaHoma (v2, Beecon, Switch), Connexoon IO / RTS, "Kit de connectivité Orange" (cloud, region-specific servers);
- the Somfy **local API** ("Developer Mode") on TaHoma v2, Beecon, Switch, Connexoon IO/RTS gateways [PY lists these];
- Atlantic / Thermor / Sauter **Cozytouch** (heaters, water heaters, heat pumps);
- Bouygues **Flexom**, Rexel **Energeasy Connect**, Hitachi **Hi Kumo**.

What it exposes:

1. Every device of the setup (after exclusions, section 2.3) as one HomeKit accessory, with services chosen from the
   device's `definition.uiClass` and `definition.widgetName` (section 5).
2. Optionally, every scenario (Overkiz "action group") as a Switch (section 5.12).

There is no per-device discovery on the LAN beyond finding the gateway for the local API (mDNS, section 3.4). Devices come
from the setup listing.

---

## 2. Configuration interface

### 2.1 Platform block

Platform name (`pluginAlias` and `platform` value): **`Tahoma`**. `pluginType` `platform`, `singular: false` (several
blocks are allowed, e.g. one per account or service).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | `"Tahoma"`. |
| `name` | string | `"TaHoma"` | Display name for the log only. |
| `service` | string | `"somfy_europe"` | Which Overkiz server (2.2). Unknown value: the client constructor throws "Invalid service name: ..." and the platform does not start. Compared case-insensitively. |
| `user` | string | required | Cloud: the account e-mail/user id. Local: the gateway PIN (`XXXX-XXXX-XXXX`, digits) or the gateway's IPv4 address. Personal data. |
| `password` | string | required | Cloud: the account password. Local: the Developer Mode bearer token. **Secret.** |
| `pollingPeriod` | number (seconds) | 60 (code; README says 30, schema placeholder 60, schema minimum 10) | Event-listener fetch period when no execution is in progress (6.2). `0` means "poll only while an execution is in progress". On a cloud service a value below 10 other than 0 is logged as an error and replaced by 60; below 30 logs a "discouraged" warning; above 60 logs a warning that sessions may time out. These checks are skipped for `local`. |
| `refreshPeriod` | number (minutes) | 30 | Period of the full state refresh (6.3). Below 30 logs a "discouraged" warning. |
| `execPollingPeriod` | number (seconds) | 5 | Not in the schema. Fetch period while at least one execution is in progress. |
| `exposeScenarios` | boolean (README: or array of names) | false | Expose action groups as switches. Any truthy value exposes **all** of them; the README's "list of names" form is not implemented (an array is truthy, so all are exposed). |
| `exclude` | array of strings | `[]` | Exclusions (2.3). |
| `devicesConfig` | array of objects | `[]` | Per-device overrides (2.4). |
| `debug` | boolean | false | Not in the schema. When true, debug lines are logged at info level (in grey). |
| `proxy` | string (base URL) | absent | Not in the schema. When set, every request is sent to this base URL instead, with path kept and a header `X-Forward-Host: <original host>`. |

Secrets: `password` (both cloud password and local token). `user` is personal data (e-mail or gateway PIN) and should be
masked in logs. **Recommendation:** in Homeswift keep `password` under a secret-named key so the runtime seals it, and
store any token minted by Setup (3.5) with `context.secretFile`.

### 2.2 `service` values and servers

| `service` (also accepted aliases) | Server host [OC] | Auth flow | Brand |
|---|---|---|---|
| `local` | the gateway, port 8443 | Bearer token (3.4) | Somfy Developer Mode |
| `somfy_europe` (`tahoma`, `tahoma_switch`, `connexoon`) | `ha101-1.overkiz.com` | session login (3.1) | Somfy Europe |
| `somfy_australia` (`connexoon_rts`) | `ha201-1.overkiz.com` | session login | Somfy Oceania / Connexoon RTS |
| `somfy_north_america` | `ha401-1.overkiz.com` | session login | Somfy North America |
| `cozytouch` | `ha110-1.overkiz.com` | Atlantic token + JWT (3.2) | Atlantic, Thermor, Sauter |
| `flexom` | `ha108-1.overkiz.com` | session login | Bouygues Flexom |
| `rexel` | `ha112-1.overkiz.com` | session login | Rexel Energeasy Connect |
| `hi_kumo` | `ha117-1.overkiz.com` | session login | Hitachi Hi Kumo (Europe) |

Cloud base URL: `https://<host>/enduser-mobile-web/enduserAPI` (paths below are appended, e.g. `/setup/devices`).

[PY] knows further servers and newer flows (for reference; not in the plugin): Hi Kumo Asia/Oceania `ha203-1.overkiz.com`;
Brandt and Sauter Smart Control `ha3-1.overkiz.com` (behind a `https://www.smartcontrol-app.com` middleware); Hexaom
HexaConnect `ha5-1.overkiz.com`; Nexity `ha106-1.overkiz.com` (AWS Cognito); Ubiwizz `ha129-1.overkiz.com`; SIMU LiveIn2 =
`ha101-1`. For Rexel, [PY] no longer uses `ha112-1` but an Azure B2C OAuth flow and
`https://econnect-api.rexelservices.fr/api/enduser/overkiz/` with a `gatewayId` header. For Somfy Europe, [PY] uses an
OAuth password grant at `accounts.somfy.com` and a Bearer token instead of `/login` (3.3). [PY] maps a Somfy site's
country to a region: `EMEA` → `ha101-1`, `APAC` → `ha201-1`, `SNABA` (US, CA, MX) → `ha401-1`.

### 2.3 Exclusions

A device is skipped when any of these equals (exact, case-sensitive) an entry of the exclusion list: its
`definition.uiClass`, its `definition.widgetName`, its `controllableName`, its `label`, or its **protocol** (the part of
`controllableName` before the first `:`, e.g. `io`, `rts`, `hue`, `zwave`, `ovp`, `modbuslink`, `internal`).

The user's `exclude` list is always extended with built-in entries: `Pod`, `ConfigurationComponent`, `NetworkComponent`,
`ProtocolGateway`, `ConsumptionSensor`, `OnOffHeatingSystem`, `Wifi`, `RemoteController`, `io:LightIOSystemDeviceSensor`,
`io:RelativeHumidityIOSystemDeviceSensor`, `enocean:EnOceanHumidityComfortSensor`, `WeatherForecastSensor`.

Scenarios are skipped when their `label` is in the list, starts with `internal:`, or is empty.

### 2.4 `devicesConfig` (per-device overrides)

Each element has a `key` and any options below. The entries are indexed by `key` (a later entry with the same key
replaces an earlier one). For a device, the effective options are the merge, in this order (later wins), of the entries
whose key equals: the device's uiClass, its widgetName, its label, its accessory UUID (5.1). The README also mentions
protocol as a key; the code does not look it up. **Recommendation:** also accept the protocol and the `deviceURL`.

| Option | Type | Default | Applies to | Meaning |
|---|---|---|---|---|
| `reverse` | bool | false | covers | Swap the direction mapping (0/100). Listed for garage doors in the schema but unused there. |
| `defaultPosition` | number 0–100 | 0 | stateless covers | Position shown after any completed command (0 = show the target instead). |
| `initPosition` | number | `defaultPosition` or 50 | stateless Window | Initial position (not in schema). |
| `movementDuration` | int seconds | 0 | stateless covers | Full travel time; enables intermediate positions by timed stop (5.3). |
| `offsetMovementDuration` | number seconds | 0 | stateless covers | Added to the computed travel time (not in schema). |
| `blindMode` | bool | false | venetian blinds | Main slider drives the slat orientation (5.4). |
| `blindsOnRollerShutter` | bool | false | covers | After a completed move, nudge by 2 (5.3). |
| `lowSpeed` | bool or `"HH:MM-HH:MM"` | false | `PositionableRollerShutterWithLowSpeedManagement` | Use the low-speed command, always or within a daily window (5.3.4). |
| `cyclic` | bool | false | garage doors, gates | Treat as a one-button cyclic opener (5.5). |
| `cycleDuration` | int seconds | 5 | garage doors, gates | Time after which a cyclic door shows closed again. |
| `pedestrianDuration` | int seconds | 0 | gates | Timed pedestrian opening for RTS gates (5.6). Not in schema. |
| `stayZones` | string | `"A"` | Alarm | Zones armed for HomeKit "Stay"/"Home". |
| `nightZones` | string | `"B"` | Alarm | Zones armed for HomeKit "Night". |
| `occupancySensor` | bool | false | Alarm | Documented ("occupancy sensor active when the alarm is triggered") but **not implemented**. |
| `derogationDuration` | int hours | 1 | heating | Duration of temporary setpoint overrides. Not in schema. |
| `comfort` | number °C | 19 | heating (pilot wire) | Comfort temperature shown and used for snapping. Not in schema. |
| `eco` | number °C | 17 | heating (pilot wire) | Eco temperature. Not in schema. |

All defaults use "falsy → default", so `0` and `false` mean "default" for the numeric options.

Example block the replacement must accept unchanged:

    { "platform": "Tahoma", "name": "My TaHoma Box", "service": "somfy_europe",
      "user": "user@example.com", "password": "...",
      "exposeScenarios": true,
      "exclude": ["hue", "rts", "Main door", "PositionableHorizontalAwning"],
      "devicesConfig": [
        { "key": "Alarm", "stayZones": "A,C" },
        { "key": "Bedroom blind", "blindMode": true },
        { "key": "UpDownRollerShutter", "defaultPosition": 50 },
        { "key": "Kitchen shutter", "lowSpeed": "22:00-07:30" } ] }

**Recommendation (Homeswift):** read `exclude` and `devicesConfig` as given (they are the Homebridge plugin's option names),
but write per-device choices as Accessory Settings in `_accessories` by Device Id (the `deviceURL`), and Excluded through the
Setup/Accessory Settings path, as for other ported plugins.

---

## 3. Authentication

### 3.1 Cloud session login (all cloud services except Cozytouch) [OC]

1. Drop any stored `Cookie` header.
2. `POST https://<host>/enduser-mobile-web/enduserAPI/login`, body `application/x-www-form-urlencoded`:
   `userId=<user>&userPassword=<password>`.
3. Take the `Set-Cookie` header whose cookie name is `JSESSIONID`, keep its `name=value` part, and send it as
   `Cookie: JSESSIONID=...` on every later request. (If no such cookie arrives, the login still counts as successful.)
4. The client is then "connected": the event polling and refresh tasks start (6.1).

[PY] adds: a successful login answers 200 with JSON `{"success": true}` (anything else is bad credentials) or 204 with no
body. Error bodies are JSON `{"errorCode": ..., "error": ...}`, e.g. `AUTHENTICATION_ERROR` / `"Bad credentials"`,
`AUTHENTICATION_ERROR` / `"Too many requests, try again later : login with ..."`, `"Too many attempts with an invalid token,
temporarily banned"`, and a plain HTML page containing `is down for maintenance` during maintenance.

**Login lockout [OC].** If the login (or any step of the Cozytouch pre-login) fails with an HTTP status 400–499, the client
locks itself: every further connect attempt fails immediately with a message telling the user to check the credentials or
wait to be unbanned, for `lockdownDelay` seconds (initially 60). When the lock expires, the next lock lasts 4 times longer
(60 s, 4 min, 16 min, 64 min, ...). A successful login resets the delay to 60 s. The warning says how long the lock lasts,
rounded to hours (> 3600 s), minutes (> 60 s) or seconds. The purpose is to avoid Overkiz's temporary ban for repeated bad
logins. 5xx and network errors do not lock.

### 3.2 Cozytouch (Atlantic) [OC], confirmed by [PY]

1. `POST https://apis.groupe-atlantic.com/token`, header
   `Authorization: Basic Q3RfMUpWeVRtSUxYOEllZkE3YVVOQmpGblpVYToyRWNORHpfZHkzNDJVSnFvMlo3cFNKTnZVdjBh` (the Cozytouch app's
   public client credentials, identical in [OC] and [PY]), form body `grant_type=password`,
   `username=GA-PRIVATEPERSON/<user>`, `password=<password>`. The JSON answer has `access_token` (absent → "Invalid
   credentials"). [PY]: an answer `{"error": "invalid_grant", "error_description": ...}` means bad credentials; no
   `token_type` means a service error.
2. `GET https://apis.groupe-atlantic.com/magellan/accounts/jwt` with `Authorization: Bearer <access_token>`. The body is
   the JWT as text. [OC] trims whitespace; [PY] strips surrounding double quotes. **Recommendation:** strip both.
3. `POST https://ha110-1.overkiz.com/enduser-mobile-web/enduserAPI/login`, form body `jwt=<jwt>`; then as 3.1 step 3.

### 3.3 Somfy accounts OAuth [PY only]

[PY] authenticates Somfy Europe with `POST https://accounts.somfy.com/oauth/oauth/v2/token/jwt` (form:
`grant_type=password`, `client_id`, `client_secret` (the TaHoma app's public values, quoted in [PY]'s constants),
`username`, `password`), then sends `Authorization: Bearer <access_token>` to `ha101-1` instead of a JSESSIONID, and
refreshes with `grant_type=refresh_token` when expired. The answer `{"message": "error.invalid.grant"}` means bad
credentials. [PY] also has a multi-site flow (Keycloak token exchange at `ginaite-prod.ovkube.net`, site directory at
`backoffice-service.ovkube.net`) selecting a site's region server. Overkiz rejects a request that carries both a
JSESSIONID and a Bearer token (`"Cannot use JSESSIONID and bearer token in same request"`). The plugin does not implement
this; see Gaps.

### 3.4 Local API (Developer Mode)

Choosing local vs cloud is explicit: `service: "local"` selects the local API, anything else the cloud. There is no
automatic fallback either way.

Resolving the host [OC]:

- `user` matching a dotted IPv4 address → that address.
- `user` matching `^[0-9]{4}-[0-9]{4}-[0-9]{4}$` (the gateway PIN) → browse mDNS for service type `_kizboxdev._tcp`; the first
  service whose instance name contains the PIN wins, and its first IPv4 address is used. Timeout 10 s. On timeout, warn
  ("No gateway found on your network", "check the PIN and that Developer Mode is activated", with the developer-mode
  link) and fall back to the host name `gateway-<PIN>.local`. Services whose name does not contain the PIN are logged at
  debug and ignored.
- Anything else → error "Invalid username. Please provide gateway PIN (XXXX-XXXX-XXXX) or gateway IP".

The advertised mDNS port is ignored: the base URL is always `https://<host>:8443/enduser-mobile-web/1/enduserAPI` (note the
extra `/1`). [PY] uses the same path (`/enduser-mobile-web/1/enduserAPI/`) and documents the host as
`gateway-xxxx-xxxx-xxxx.local:8443` or the IP; [PY] has no mDNS browsing.

Every local request carries `Authorization: Bearer <password>` (the token). No cookie.

TLS: [OC] disables certificate verification entirely. [PY] verifies against the bundled **Overkiz Root CA** (subject
`O=Overkiz, OU=Root CA, CN=Overkiz Root CA, C=FR`, self-signed, valid 2016-04-27 to 2036-04-27, SHA-256 fingerprint
`BB:FA:96:11:1E:AE:15:E3:C6:ED:15:F3:43:27:6C:0C:27:26:03:2E:A1:9D:F5:BB:D0:67:E2:F1:CF:FC:44:DB`), relaxes the strict-X.509
flag, and advises turning verification off when connecting by IP (the gateway certificate names `gateway-<PIN>.local`).
**Recommendation:** pin that root CA when the host is `gateway-<PIN>.local`; when connecting by IP or by mDNS-resolved IP,
use Homeswift's `TrustOnFirstUse`/pinning of the gateway's certificate rather than no verification.

Credential check [OC]: right after setting up the base URL and token, `GET /apiVersion` (the answer, [PY]:
`{"protocolVersion": "<version>"}`) is logged at debug. A failure here fails the connection. [PY] instead registers the
event listener, or calls `GET setup/gateways`.

Local API differences [PY]: no execution modes (an `exec/apply/highPriority` request is rejected, Somfy-Developer issue
227); no `/setup/location`; devices have **no `oid`** (so identities differ from the cloud's, see 5.1); local error bodies
use the same `{errorCode, error}` shape with slightly different quoting (`"Not authenticated."`, `"\"No registered event
listener.\""`).

### 3.5 Obtaining a local token

Current method (README): in the TaHoma by Somfy app, Settings of the box, tap the PIN 7 times quickly, accept the terms,
generate the token, then configure `service: "local"`, `user: <PIN>`, `password: <token>`.

Through the cloud API (offered by [OC], confirmed by [PY]; the plugin itself never calls these), with a cloud session:

| Call | Body / answer |
|---|---|
| `GET /config/<PIN>/local/tokens/generate` | answer `{"token": "<new token>"}` |
| `POST /config/<PIN>/local/tokens` | JSON `{"label": "<label>", "token": "<token>", "scope": "devmode"}` ([OC] also sends `"gatewayId": "<PIN>"`); answer [PY] `{"requestId": "..."}`. Activates the token. |
| `GET /config/<PIN>/local/tokens/devmode` | list of `{label, gatewayId, gatewayCreationTime, expirationTime, uuid, scope}` |
| `DELETE /config/<PIN>/local/tokens/<uuid>` | revokes one |

[PY] fixture: Developer Mode shows as a setup option `GET /setup/options` entry with `"optionId": "developerMode-<PIN>"` and
a `gatewayId` parameter. The gateways of a setup come from `GET /setup/gateways` (`gatewayId` is the PIN; [PY] treats ids
matching `\d{4}-\d{4}-\d{4}` as Overkiz gateways).

**Recommendation (Homeswift Setup):** `accountAuthorization` asks for the service and the cloud credentials (or the PIN and
an existing token for local); for local, `authorize` can optionally log into the cloud, list gateways, generate and activate
a token labelled e.g. "Homeswift", store it with `context.secretFile`, then switch to the local API. `discover` can browse
`_kizboxdev._tcp` to offer PINs.

### 3.6 Session expiry and reconnection [OC]

Every request first awaits "connected" (logging in if needed). On an HTTP 401 answer:

- the stored login is discarded; if the client was connected it becomes disconnected, logs "Session expired: <message>" at
  debug and emits "disconnect" (which stops the polling and refresh tasks, 6.1);
- unless the request was made with reconnect disabled (only the event fetch is), the request is retried once (which logs in
  again and emits "connect", restarting the tasks).

Error values are flattened into a string `Error <status> <error>(<errorCode>)` using the JSON body's `error` and
`errorCode`, or the transport's message. Callers match on substrings of that string (6.2).

---

## 4. API

All paths are relative to the base URL (cloud or local). JSON bodies use `Content-Type: application/json` (axios default).
`<deviceURL>` in a path is percent-encoded as a whole component (e.g. `io%3A%2F%2F1234-5678-9012%2F7654321`).

### 4.1 Endpoints the plugin uses

| Purpose | Method and path | Notes |
|---|---|---|
| Device list | `GET /setup/devices` | Discovery and refresh. Array of devices (4.2). |
| Scenarios | `GET /actionGroups` | Array of `{oid, label, actions, metadata}`. Only when `exposeScenarios`. |
| Location | `GET /setup/location` | Cloud only; `countryCode` picks the label language (7). |
| Register listener | `POST /events/register` | No body; answer `{"id": "<listenerId>"}`. |
| Fetch events | `POST /events/<listenerId>/fetch` | No body; answer: array of events (4.3). Sent with reconnect disabled. |
| Unregister listener | `POST /events/<listenerId>/unregister` | Offered by [OC], never called. |
| Execute | `POST /exec/apply` or `POST /exec/apply/highPriority` | Body 4.4; answer `{"execId": "<uuid>"}`. |
| Execute a scenario | `POST /exec/<actionGroupOid>` | Body: an empty execution object (5.12); answer `{"execId": ...}`. |
| Cancel | `DELETE /exec/current/setup/<execId>` | |
| Refresh all states | `POST /setup/devices/states/refresh` | JSON body `[]` (an empty list of device URLs). |
| Refresh one device | `POST /setup/devices/<deviceURL>/states/refresh` | No body. |

Also offered by [OC] but unused by the plugin: `GET /setup`, `GET /setup/gateways`, `GET /setup/devices/<url>/states`,
`GET /setup/devices/<url>/states/<stateName>`, `GET /history/executions`, `PUT /setup/devices/<url>/<label>` (rename).
[PY] additionally: `GET /exec/current`, `GET /exec/current/<execId>`, `POST /exec/schedule/<oid>/<timestamp>`, `GET
/setup/places`, `GET /reference/...`.

### 4.2 Device object (as used)

| Field | Use |
|---|---|
| `deviceURL` | Identity and address, e.g. `io://1234-5678-9012/7654321`, `rts://1234-5678-9012/16712345`, `io://1234-5678-9012/7654321#2`, `internal://1234-5678-9012/alarm/0`, `zwave://...`, `hue://...`, `ovp://...`, `modbuslink://...`. The part after `#` is the component id (absent means 1). |
| `oid` | Cloud only: the device's UUID. Absent on the local API. |
| `label` | Accessory name. |
| `controllableName` | `<protocol>:<uniqueName>`, e.g. `io:RollerShutterGenericIOComponent`. |
| `definition.uiClass`, `definition.widgetName` | Mapper choice. (Cloud also repeats them as top-level `uiClass` and `widget`; the plugin reads `definition`.) |
| `definition.commands` | Array of `{commandName, nparams}`; "has command X" means one entry has `commandName` X. |
| `states` | Array of `{name, type, value}`. `type`: 0 none, 1 integer, 2 float, 3 string, 4 blob, 5 date, 6 boolean, 9 password, 10 JSON array, 11 JSON object [PY]. A device may have no `states` key at all (stateless). |

Values may arrive as strings even for numeric types (e.g. `{"type": 1, "value": "23247220"}` in a cloud event).
**Recommendation:** decode by `type`, accepting numeric strings.

Accessory Information: Manufacturer = state `core:ManufacturerNameState` if present, else `"Somfy"`; Model = state
`core:ModelState` if present, else the uiClass; Serial Number = the `deviceURL` with everything from the first `/` to the
last `/` removed, cut to 64 characters (`io://1234-5678-9012/7654321` → `io:7654321`; with `#2` → `io:7654321#2`;
`internal://1234-5678-9012/alarm/0` → `internal:0`).

### 4.3 Events (answer of fetch)

Handled event `name`s:

- `DeviceStateChangedEvent`: `deviceURL`, `deviceStates` (array of `{name, type, value}`; `value` may be missing). Applied to
  the device with that URL (any device of the last listing, including sub-devices attached as sensors); unknown URLs are
  ignored.
- `ExecutionStateChangedEvent`: `execId`, `newState`, `oldState`, `timeToNextState` (`-1` = final), and on failure
  `failureType` (string, e.g. `CMDCANCELLED`, `WHILEEXEC_BLOCKED_BY_HAZARD`) and `failedCommands` (array of objects with at
  least `deviceURL`). Only executions started by this plugin are tracked.
- `RefreshAllDevicesStatesCompletedEvent`: ends a full refresh (6.3).

Other events (`ExecutionRegisteredEvent`, `GatewaySynchronizationStartedEvent`, `GatewaySynchronizationEndedEvent`, ...)
are ignored.

Execution states: `INITIALIZED`, `NOT_TRANSMITTED`, `TRANSMITTED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`; [PY] adds
`QUEUED_GATEWAY_SIDE`, `QUEUED_SERVER_SIDE`, `UNKNOWN`; the plugin adds a synthetic `TIMED_OUT` (6.4).

### 4.4 Execution body

    { "label": "<label>",
      "actions": [ { "deviceURL": "<url>",
                     "commands": [ { "type": 1, "name": "<commandName>", "parameters": [ ... ] } ] } ],
      "metadata": null }

- `parameters` is always an array (a single value is wrapped; no parameters → `[]`). Elements are numbers, strings or, for a
  few commands, objects (e.g. `setCurrentOperatingMode` with `{"relaunch": "off", "absence": "on"}`).
- One action per device per execution; [PY] documents the server's rule "at most one action per device per action group"
  (`DUPLICATE_FIELD_OR_VALUE`, "Another action exists on the same device").
- The JavaScript object also serialises some event-emitter bookkeeping fields (`_events`, `_eventsCount`, ...). They are an
  accident; the server ignores them. Do not reproduce.
- Mode: `apply/highPriority` when the device has the state `io:PriorityLockLevelState`, else `apply`. (Local API rejects
  modes: see Gaps.)
- [PY] for RTS devices appends a default duration as the last parameter when exactly one parameter slot is left (`nparams -
  1` given); the plugin does not.

### 4.5 Errors, limits, retries

[PY] error codes (`errorCode` + substring of `error`) worth handling:

| errorCode / message | Meaning |
|---|---|
| `RESOURCE_ACCESS_DENIED` "Not authenticated" (401) | session gone: log in again |
| `AUTHENTICATION_ERROR` "Bad credentials" / "No such user account" | bad credentials |
| `AUTHENTICATION_ERROR` "Too many requests" , `QUOTA_EXCEEDED` | rate limited |
| "Too many attempts with an invalid token, temporarily banned" | banned |
| `RESOURCE_ACCESS_DENIED` "too many concurrent requests" | retry later |
| `RESOURCE_ACCESS_DENIED` "Too many executions" ("Server busy, please try again later.") | retry later |
| `EXEC_QUEUE_FULL` "Execution queue is full on gateway: #... (soft limit: 10)" | at most 10 concurrent executions per gateway |
| `UNSPECIFIED_ERROR` "Invalid event listener id" / "No registered event listener" (400 on local) | re-register listener |
| `UNSUPPORTED_OPERATION` "No such command" | invalid command |
| `NO_SUCH_DEVICE`, `NO_SUCH_ACTION_GROUP`, `INVALID_API_CALL` | not found |
| `DUPLICATE_FIELD_OR_VALUE` | two actions for one device |
| HTML "is down for maintenance", any 5xx with HTML body | service unavailable |

[PY] retry policy (exponential backoff with full jitter): auth errors 2 tries / 60 s with re-login between; connection
failures (timeout, connect error, server disconnect) 3 tries / 30 s; too many concurrent requests 5 tries / 120 s; too many
executions 5 tries / 300 s; listener errors 2 tries / 30 s with re-registration; execution queue full 5 tries / 120 s.

[OC] behaviour: no retries except the single re-login on 401 and the polling backoff (6.2). Before posting an execution it
intends to wait 10 s and retry when 10 executions are in flight (to avoid `EXEC_QUEUE_FULL`), but the check never triggers
(see Gaps).

---

## 5. Device model and HomeKit mapping

### 5.1 Identity

Accessory UUID ([OC] `uuid`):

- if the device has a non-empty `oid`: the `oid` itself if it is a valid UUID string, else UUID version 5 of the `oid` in the
  namespace `6ba7b812-9dad-11d1-80b4-00c04fd430c8` (the RFC 4122 OID namespace);
- otherwise (local API): UUID v5 of the `deviceURL` in that same namespace, lowercase.

Scenario accessories use the action group's `oid` directly as the UUID.

Consequence (README warning): switching between cloud and local changes every UUID, so HomeKit loses rooms and automations.

**Recommendation (Homeswift):** seed the accessory id with the `deviceURL`, which is the same on cloud and local:
`Tahoma:<deviceURL>` (scenarios: `Tahoma:scene:<oid>`). Services' subtypes below are stable strings (`boost`, `drying`,
`pedestrian`), so aids/iids stay stable.

Vectors (computed by the spec writer, UUID v5 in the OID namespace):

| deviceURL | UUID | Serial |
|---|---|---|
| `io://1234-5678-9012/7654321` | `3892b52a-cffc-5c6b-92ed-821149e1148c` | `io:7654321` |
| `io://1234-5678-9012/7654321#2` | `ff55e3f0-435e-53cc-9e3f-62ca4256b764` | `io:7654321#2` |
| `rts://1234-5678-9012/16712345` | `f45d05a3-b3b7-58b9-b83a-d7def5831642` | `rts:16712345` |
| `internal://1234-5678-9012/alarm/0` | `ca122a11-3a3e-52f4-8ef0-9b46bfc4975f` | `internal:0` |

### 5.2 Grouping sub-devices, choosing the mapper, building services

**Grouping.** The device list is walked in the server's order, tracking the last main device, the last device and the
list of non-sensor sub-devices since the last main device:

- a main device (component 1) starts a new group and is exposed;
- a sub-device that is a **sensor of** the last device, or else of the last main device, or else of any earlier sub-device of
  the group, is attached to it (not exposed; its states feed the owner's mapper);
- otherwise the sub-device is exposed as its own accessory, with the last main device as its `parent`.

"Sensor of" rules (by the candidate's `controllableName`, then its widget):

| Candidate | Attaches to |
|---|---|
| `io:AtlanticPassAPCOutsideTemperatureSensor` | never |
| `io:AtlanticPassAPCZoneTemperatureSensor` | a device whose uiClass is `HeatingSystem` |
| `io:HeatingRelatedElectricalEnergyConsumptionSensor` | a device whose controllableName is `io:AtlanticPassAPCHeatPumpMainComponent` |
| `io:DHWRelatedElectricalEnergyConsumptionSensor` | `io:AtlanticPassAPCDHWComponent` |
| `io:CumulatedElectricalEnergyConsumptionIOSystemDeviceSensor` | `io:AtlanticElectricalHeaterWithAdjustableTemperatureSetpointIOComponent` or `io:AtlanticElectricalTowelDryerIOComponent` |
| any device whose widget is `TemperatureSensor` | a device whose uiClass is `HeatingSystem` |

Exclusions (2.3) are applied to the exposed devices only.

**Mapper choice** (first that exists): mapper for `uiClass/widgetName/uniqueName` (uniqueName = the part of
controllableName after the last `:`), then `uiClass/widgetName`, then `uiClass`. The tables in 5.3–5.11 list every mapper.
If none exists the source crashes the whole discovery (see Gaps). **Recommendation:** skip such a device with a warning
"<uiClass> > <widget> not supported".

**Building.**

1. Effective options (2.4).
2. **Stateless** = the device has no states, or the mapper declares expected states and the device has none of them.
   Expected states: covers `core:ClosureState`, `core:TargetClosureState`; garage doors `core:OpenClosedPartialState`,
   `core:OpenClosedUnknownState`, `core:OpenClosedState`; gates only `core:OpenClosedPedestrianState`. Other mappers
   declare none (stateless only if no states at all).
3. Services are registered; the main service without subtype is named with the device label; subtype services are named by
   their subtype: `boost` → "Boost", `drying` → "Séchage", others capitalised (`pedestrian` → "Pedestrian"). If building
   the main service throws (unsupported mapper such as `ConsumptionSensor`, `RemoteController`), a warning with the message
   is logged and the accessory keeps only Accessory Information.
4. Cached services not produced this time are removed.
5. If not stateless: every current state of the device, then of each attached sensor, is fed once to the mapper (no log),
   and later state changes of the device and its sensors are fed as they arrive (logged at debug as "<state> => <value>").
   **Stateless devices never receive states.**

**State delivery** [OC]: updates to a device are merged in a per-device buffer and delivered 100 ms after the last update
(coalescing), only for states whose value changed or that are new. Existing states of type 10 or 11 (JSON array/object) are
never updated (see Gaps).

**Write path.** HomeKit writes call a handler that builds one or more commands and executes them (6.4). If the handler yields
no command (undefined or an empty list), the error "No target command for <label>" is logged and the write fails with HAP
status `-70409` (resource does not exist). If posting the execution fails, the write fails with `-70402` (communication
failure) and "<command> <message>" is logged. Writes marked *debounced* wait 500 ms after the last write before sending
(values listed as *immediate* are sent at once and their errors are returned to HomeKit; errors of delayed sends are
swallowed). One debounce timer and one "postpone" timer (500 ms, used for `computeStates`) exist per mapper (shared by all
its characteristics).

Below, "on COMPLETED/FAILED/IN_PROGRESS" refers to the execution states of the command's own action (6.4). HAP values:
TargetHeatingCoolingState OFF 0, HEAT 1, COOL 2, AUTO 3; CurrentHeatingCoolingState OFF 0, HEAT 1, COOL 2; PositionState
DECREASING 0, INCREASING 1, STOPPED 2; CurrentDoorState OPEN 0, CLOSED 1, OPENING 2, CLOSING 3, STOPPED 4; TargetDoorState
OPEN 0, CLOSED 1; LockCurrentState UNSECURED 0, SECURED 1, JAMMED 2, UNKNOWN 3; SecuritySystem target STAY 0, AWAY 1, NIGHT
2, DISARM 3, current adds TRIGGERED 4. "Idle" means the mapper's last execution is no longer in flight.

### 5.3 Window coverings

#### 5.3.1 Mapper table

| uiClass / widget (/ uniqueName) | Behaviour |
|---|---|
| `RollerShutter` (any widget not below) | Roller shutter (5.3.2) |
| `RollerShutter/PositionableRollerShutterUno` | Roller shutter, states from `core:TargetClosureState` only (5.3.3) |
| `RollerShutter/PositionableRollerShutterWithLowSpeedManagement` | Roller shutter with low speed (5.3.4) |
| `ExteriorScreen`, `Screen`, `Shutter`, `Curtain`, `SwingingShutter`, `Pergola` (any widget not below) | Roller shutter |
| `Window` | Roller shutter on a **Window** service (5.3.5) |
| `Awning` | Awning (5.3.6) |
| `Awning/PositionableHorizontalAwningUno` | Awning, Uno state handling |
| `Pergola/PergolaHorizontalAwningUno` | Roller shutter with inverted states (5.3.7) |
| `Pergola/BioclimaticPergola` | Slats only (5.3.7) |
| `VenetianBlind`, `ExteriorVenetianBlind` | Venetian blind (5.4) |
| `AdjustableSlatsRollerShutter` | Adjustable slats (5.4) |
| `Generic/RTSGeneric` | Roller shutter whose target command is `down` for 0 and `up` otherwise |

#### 5.3.2 Roller shutter

Service **Window Covering** (main). Characteristics: Current Position, Target Position, Position State (initialised to
STOPPED). Stateful: Obstruction Detected. Stateless and the device has command `my`: the custom characteristic **My**
(5.13), writable bool. A legacy On characteristic left on the cached service is removed.

Conversion: `reversedValue(v)` = `100 - v` normally, `v` when `reverse`. (Overkiz closure 0 = open, 100 = closed; HomeKit
position 100 = open.)

Reads:

- `core:ClosureState` → Current Position = reversedValue; also Target Position if the device has no
  `core:TargetClosureState` and the mapper is idle.
- `core:TargetClosureState` → Target Position = reversedValue; also Current Position if the device has no
  `core:ClosureState`.

Target Position write (debounced; 0 and 100 immediate):

- Stateful: `setClosure(reversedValue(value))`.
- Stateless: 100 → `open` (`close` when reverse); 0 → `close` (`open` when reverse); other values: if `movementDuration > 0`,
  `open` when the target is above the current position else `close` (swapped when reverse), sent as a **standalone**
  execution (6.4); otherwise `my`.

Execution feedback for a Target Position write:

- IN_PROGRESS: Position State = INCREASING if the target is 100 or above the current position, else DECREASING. For a timed
  stateless move: compute `offsetMovementDuration × 1000 + round(movementDuration × |target − current| × 1000 / 100)` ms, log
  "Will stop movement in <ms> millisec", and when it elapses: if idle send `stop` (standalone), else cancel the execution
  (`DELETE /exec/current/setup/<execId>`). A new Target Position write cancels a pending stop timer.
- COMPLETED: Position State = STOPPED. Stateless: Current (and Target) = `defaultPosition` if non-zero, else Current = target.
  Stateful: Obstruction Detected = false. If `blindsOnRollerShutter` and the target is below 98, send `setClosure(target +
  2)` (see Gaps: the source passes the HomeKit position, not the closure).
- FAILED: stateless timed moves cancelled by the stop (`failureType` `CMDCANCELLED`) show the result as COMPLETED would;
  Position State = STOPPED; Obstruction Detected = (`failureType` is `WHILEEXEC_BLOCKED_BY_HAZARD`); Target Position is reset
  to Current Position when the device has no `core:TargetClosureState`.

My write (true only; false ignored): `my`. COMPLETED: My = false; stateless: Current and Target = `defaultPosition` if
non-zero, else 50. FAILED: My = false, obstruction and target reset as above.

#### 5.3.3 Uno variants

`PositionableRollerShutterUno`: only `core:TargetClosureState` is read: Target Position = reversedValue when idle, Current
Position = reversedValue always. `PositionableHorizontalAwningUno`: same with the awning's conversion.

#### 5.3.4 Low speed (`PositionableRollerShutterWithLowSpeedManagement`)

Target command: `setClosureAndLinearSpeed([reversedValue(value), "lowspeed"])` when low speed applies, else
`setClosure(reversedValue(value))`. Low speed applies when `lowSpeed` is `true`, or when it is a string `"HH:MM-HH:MM"`
(split on `-` and `:`) and the local time is within the window: if the end is before the start (overnight), now after
start or before end; otherwise strictly between start and end (seconds zero).

Quirk: this mapper replaces the option parsing instead of extending it, so `reverse`, `defaultPosition`, `movementDuration`,
`blindsOnRollerShutter` are ignored for it (reverse behaves as false). **Recommendation:** honour all cover options.

#### 5.3.5 Window

As the roller shutter, but service **Window** (Current Position, Target Position, Position State, plus Obstruction Detected
when stateful); no My characteristic. Stateless: Current and Target initialised to `initPosition`.

#### 5.3.6 Awning

`reversedValue(v)` = `v` normally, `100 - v` when reverse (deployment = HomeKit position).

- Stateful write: `setDeployment(reversedValue(value))`.
- Stateless write: 100 → `deploy` (`undeploy` if reverse); 0 → `undeploy` (`deploy` if reverse); other: timed
  `deploy`/`undeploy` as for shutters, else `my`.
- Reads: `core:DeploymentState` and `core:ClosureState` → Current = reversedValue, and Target if no
  `core:TargetClosureState` (no idle check); `core:TargetClosureState` → Target, and Current if no `core:ClosureState`.

#### 5.3.7 Pergolas

`PergolaHorizontalAwningUno`: every state value is first replaced by `100 - value`, then the roller shutter's read rules
apply (so with defaults Current = closure). Writes as the roller shutter.

`BioclimaticPergola`: write `setOrientation(reversedValue(value))`; read `core:SlatsOrientationState` → Current =
reversedValue, Target too when idle. Nothing else is read.

### 5.4 Venetian blinds

`VenetianBlind` / `ExteriorVenetianBlind`: the roller shutter plus, when stateful, Current Horizontal Tilt Angle and Target
Horizontal Tilt Angle (target `minStep` 10; HAP range −90…90). With `blindMode` both tilt characteristics are removed.

Conversions: angle = round(orientation × 1.8 − 90); orientation = round((angle + 90) / 1.8). Overkiz orientation 0–100.

Target Position write (stateless: as the roller shutter, but `reverse` is ignored):

- `blindMode`: 100 → `open`; else if the device has `setClosureAndOrientation` → `setClosureAndOrientation([100,
  reversedValue(value)])`; else two commands `setClosure(100)` and `setOrientation(reversedValue(value))`.
- otherwise: with `setClosureAndOrientation` → `setClosureAndOrientation([reversedValue(value), orientation(target angle)])`;
  else `setClosure(reversedValue(value))` plus, if the device has `setOrientation`, `setOrientation(orientation(target
  angle))`.

Target Tilt write (debounced, nothing immediate; stateless → no command): with `setClosureAndOrientation` →
`setClosureAndOrientation([reversedValue(current Target Position), orientation(value)])`; else `setClosure(...)` plus
`setOrientation(orientation(value))` when available. FAILED: Target Tilt reset to Current Tilt.

Reads without blindMode: the roller shutter's rules plus `core:SlateOrientationState` → Current Tilt = angle, and Target Tilt
when idle.

Reads with blindMode (on `core:OpenClosedState` or `core:SlateOrientationState`): if `core:OpenClosedState` is `closed`:
position = reversedValue(`core:SlateOrientationState`); if it is an integer, Current Position = position, and Target
Position = position when idle or when round(position/5) equals round(current target/5). Otherwise (open): Current = 100, and
Target = 100 when idle.

`AdjustableSlatsRollerShutter` (extends venetian blind): Target Position write: blindMode → 100 gives `setClosure(0)`, other
values `setClosureOrOrientation([100, reversedValue(value)])`; otherwise `setClosureOrOrientation([reversedValue(value),
orientation(target angle)])`. Target Tilt write: `setClosureOrOrientation([reversedValue(target position),
orientation(value)])`. Reads: the venetian blind's, plus `core:ClosureOrRockerPositionState` → Current = reversedValue, and
Target when no `core:TargetClosureState`.

### 5.5 Garage doors

Mappers: `GarageDoor`, `Generic/CyclicGeneric`, `Generic/RTSGeneric4T`.

Service **Garage Door Opener**: Current Door State, Target Door State. Stateless: both initialised to CLOSED. `cyclic` =
option or the device has command `cycle`.

Write Target Door State: if the device has `cycle` → `cycle`; else CLOSED (1) → `close`, OPEN (0) → `open`.
Feedback: IN_PROGRESS → Current = OPENING for an OPEN target, else CLOSING. COMPLETED: stateless → apply the read rule below
with `closed` (target CLOSED) or `open`, and if cyclic, after `cycleDuration` seconds apply `closed`; stateful and cyclic →
after 60 s request `POST /setup/devices/<url>/states/refresh`. FAILED → Target restored to its previous value (only if
that value was non-zero, i.e. CLOSED: see Gaps).

Read (any of the expected states): `open` → Current OPEN, Target OPEN; `partial` → Current STOPPED, Target OPEN; `closed` →
Current CLOSED, Target CLOSED; `unknown` → nothing.

### 5.6 Gates

Mapper `Gate`. As the garage door, plus:

- Expected state is only `core:OpenClosedPedestrianState` (a gate without it is stateless, even if it reports
  `core:OpenClosedState`).
- Pedestrian command = the first of `setPedestrianPosition`, `partialPosition`, `my` that the device has.
- If a pedestrian command exists or `pedestrianDuration` > 0: an extra **Lock Mechanism** service, subtype `pedestrian`
  (name "Pedestrian"), Lock Current State / Lock Target State; stateless → both SECURED initially.
- Lock Target write: UNSECURED with a pedestrian command → that command; else UNSECURED → `open`, SECURED → `close`.
  IN_PROGRESS: stateless with no pedestrian command and a `pedestrianDuration` → after that many ms (logged "Will stop
  movement in ..."), `stop` (standalone) if idle, else cancel. COMPLETED: stateless → apply `closed` (SECURED target) or
  `pedestrian`, and if cyclic, `closed` after `cycleDuration`.
- Read `core:OpenClosedPedestrianState`: `open` or `unknown` → door OPEN/OPEN, pedestrian lock current UNKNOWN, target
  UNSECURED; `pedestrian` or `partial` → door STOPPED/target OPEN, lock UNSECURED/UNSECURED; `closed` → door CLOSED/CLOSED,
  lock SECURED/SECURED.

(A switch variant for the pedestrian opening exists in the source but is never registered.)

Homeswift: Garage Door Opener targets and the pedestrian Lock Mechanism are security controls (written only through
`set_security_accessory`).

### 5.7 Lights, switches, siren

`Light` and `Generic/DimmerOnOff`: **Lightbulb** if the device has `setIntensity`, else **Switch**. On write → `on` / `off`.
With `setIntensity`: Brightness write → `setIntensity(value)`. With `setHueAndSaturation` as well: Hue and Saturation;
Saturation write → `setHueAndSaturation([current Hue, value])`; Hue writes are not handled (the value stays local). Reads:
`core:OnOffState` → On = (value `on`); `core:IntensityState` or `core:LightIntensityState` → Brightness;
`core:ColorHueState` → Hue; `core:ColorSaturationState` → Saturation.

`OnOff`: **Switch**, On ↔ `on`/`off`, read `core:OnOffState`.

`Siren`: **Speaker** service, Mute (initialised true) and Volume. Mute write true → `off`, false → `on`. Volume →
`setVolume(value)`. Read `core:OnOffState` → Mute = (value `off`).

### 5.8 Lock and alarms

`DoorLock`: **Lock Mechanism**. Target write SECURED → `setLockedUnlocked("locked")`, anything else →
`setLockedUnlocked("unlocked")`. COMPLETED and stateless → Current = target. FAILED → Target = Current. Read
`core:LockedUnlockedState`: `locked` → SECURED, anything else → UNSECURED; Target follows Current when idle. Security control.

`Alarm`: **Security System**. Target write: STAY → `alarmZoneOn([stayZones])`, NIGHT → `alarmZoneOn([nightZones])`, AWAY →
`alarmOn`, DISARM → `alarmOff` (unknown values behave as STAY). COMPLETED and stateless → Current = target. FAILED → Target =
Current unless Current is TRIGGERED. Read `core:ActiveZonesState`: equal to stayZones → STAY/STAY; `A,B,C` → AWAY/AWAY; equal
to nightZones → NIGHT/NIGHT; `triggered` → Current TRIGGERED (target unchanged); `""` or anything else → DISARMED/DISARM.
(Cases are tested in that order: stayZones before `A,B,C` before nightZones.) Security control.

`Alarm/MyFoxAlarmController`: STAY → no command (write fails, see 5.2), NIGHT → `partial`, AWAY → `arm`, DISARM → `disarm`.
Read `myfox:AlarmStatusState`: `armed` → AWAY/AWAY, `partial` → NIGHT/NIGHT, `disarmed` or anything else → DISARMED/DISARM.

`Alarm/TSKAlarmController`: STAY → `alarmPartial1`, NIGHT → `alarmPartial2`, AWAY → `alarmOn`, DISARM → `alarmOff`.
`internal:CurrentAlarmModeState` → Current, `internal:TargetAlarmModeState` → Target: `partial1`/`zone1` → STAY, `total` →
AWAY, `partial2`/`zone2` → NIGHT, `off` or anything else → DISARMED/DISARM.

### 5.9 Sensors

Common defect handling (where listed): if the device has `core:SensorDefectState`, add Status Fault and Status Low Battery;
`lowBattery` → Low Battery LOW; `maintenanceRequired` or `dead` → Fault GENERAL_FAULT; `noDefect` → Fault NO_FAULT and Low
Battery NORMAL.

| Mapper | Service | Reads |
|---|---|---|
| `ContactSensor` | Contact Sensor (+ defect) | `core:ContactState`: `closed` → DETECTED (0); `open`/`tilt` → NOT_DETECTED (1) |
| `WindowHandle` | Contact Sensor (+ defect chars, but defect state not read) | `core:ThreeWayHandleDirectionState`: `closed` → 0, `open`/`tilt` → 1; `core:OpenClosedState`: `closed` → 0, `open` → 1 |
| `OccupancySensor` | **Motion Sensor** (Motion Detected) if the widget name starts with `Motion`, else **Occupancy Sensor** (Occupancy Detected) (+ defect) | `core:OccupancyState` = `personInside` → detected |
| `SmokeSensor` | Smoke Sensor; Fault + Low Battery if any of `core:SensorDefectState`, `io:MaintenanceRadioPartBatteryState`, `io:SensorRoomState` exists (the source's fourth check has a misspelled state name and never matches); Status Active if `core:StatusState` | `core:SmokeState` = `detected`; `core:StatusState` = `available` → Active; defect states; `io:MaintenanceRadioPartBatteryState` / `io:MaintenanceSensorPartBatteryState`: `normal`/`absence` → NORMAL, `low` → LOW; `io:SensorRoomState`: `clean` → NO_FAULT, `dirty` → GENERAL_FAULT |
| `RainSensor` | Contact Sensor (+ defect) | `core:RainState` = `detected` → 1 (NOT_DETECTED) else 0 |
| `WaterSensor` | Leak Sensor | `core:WaterDetectionState` = `detected` → LEAK_DETECTED |
| `HumiditySensor/WaterDetectionSensor` | Contact Sensor (+ defect chars) | intended `core:WaterDetectionState` = `detected` → 0 else 1, but the source's state name has a trailing space and never matches: nothing is read |
| `TemperatureSensor`, `EvoHome/DHWSetPoint` | Temperature Sensor | `core:TemperatureState`: values > 200 are Kelvin (subtract 273.15) |
| `HumiditySensor`, `AirSensor/RelativeHumiditySensor` | Humidity Sensor | `core:RelativeHumidityState` |
| `LightSensor` | Light Sensor | `core:LuminanceState` → Current Ambient Light Level (lux) |
| `AirSensor` | Air Quality Sensor, Status Fault always; Low Battery if `core:SensorDefectState`; Status Active if `core:StatusState` | `core:AirQualityState`: `optimalAirRange` → EXCELLENT; `slightlyHumidRange`, `slightlyDryAirRange` → GOOD; `dryAirRange`, `slightlyHotAndHumidRange` → FAIR; `excessivelyDryAirRange`, `highHumidityRange`, `highTemperatureAndHumidityRange` → INFERIOR; `mouldsAndDustMitesRisk`, `mouldsRisk`, `temperatureOrHumidityOutOfAnalysisRange` → POOR; `error` → UNKNOWN; plus StatusState and defect |
| `AirSensor/CO2Sensor` | as AirSensor plus Carbon Dioxide Level | only `core:CO2ConcentrationState` is read (the defect/status handling is lost): CO2 level, and Air Quality: < 350 EXCELLENT, < 1000 GOOD, < 2000 FAIR, < 5000 INFERIOR, else POOR |
| `ElectricitySensor` | Accessory Metrics service (HAP 0x270) | every state change is logged at info "<name> => <value>"; nothing exposed |
| `ElectricitySensor/CumulativeElectricPowerConsumptionSensor` | Accessory Metrics + Eve Total Consumption + Eve Current Consumption (5.13) | `core:ElectricEnergyConsumptionState` (Wh) / 1000 → kWh; `core:ElectricPowerConsumptionState` → W |
| `ConsumptionSensor`, `RemoteController` | none (excluded by default; building throws "not implemented") | |

Note the Contact Sensor values: 0 = contact detected (closed), 1 = not detected (open).

**Recommendation:** fix WaterDetectionSensor's state name, keep defect handling in CO2Sensor, use a Contact/Leak choice that
makes sense for rain (the source reports rain as "open"), and for electricity sensors report energy through Homeswift's
`Energy` tags instead of an Accessory Metrics service; drop the per-change info log.

### 5.10 Heating (uiClass `HeatingSystem` and relatives)

#### 5.10.1 Base thermostat (`HeatingSystem`, and `HitachiHeatingSystem/HitachiAirToWaterHeatingZone`,
`HitachiAirToWaterMainComponent` (min 0))

Service **Thermostat** (primary). Current Temperature (`minStep` 0.1), Target Temperature (min `MIN_TEMP` 7, max `MAX_TEMP`
30, step 0.5; a cached value outside the range is clamped), Current/Target Heating Cooling State (Target `validValues` =
the mapper's modes, base AUTO and OFF). Optional custom characteristics **Prog** and **Eco** (5.13) when the mapper lists
them. If an attached sensor has widget `CumulativeElectricPowerConsumptionSensor`: Eve Total Consumption.

- Target state write: ignored when equal to the current Target value. Base commands: AUTO → `auto`, HEAT → `heat`, COOL →
  `cool`, OFF → `off`. COMPLETED + stateless → Current = target. FAILED → Target = Current.
- Target temperature write (debounced 500 ms): base `setTargetTemperature(value)`.
- Prog/Eco write: store the value, then, if Target state is not OFF, execute the mapper's "prog commands" (base: the target
  state command for the current Target value).
- Switch services (where a mapper adds one): On write → base `setOn(value)`; FAILED → On = !value.
- Reads: `core:TemperatureState` → Current Temperature (values > 273.15 are Kelvin); `core:TargetTemperatureState` → Target
  Temperature; `core:ElectricEnergyConsumptionState` / 1000 → Total Consumption.

Several mappers recompute their states from several Overkiz states with a 500 ms postpone after any relevant change
("computeStates"); they update Target state only when idle.

#### 5.10.2 Mapper table

| widget (uiClass `HeatingSystem` unless noted) | Modes | Temperature | Writes | Reads |
|---|---|---|---|---|
| `AtlanticElectricalHeater` (pilot wire) | HEAT, COOL, OFF; Eco char | 7 … `comfort`, step 1, perms read/notify/write | AUTO → `setHeatingLevel(eco if Eco else comfort)`; HEAT → `setHeatingLevel("comfort")`; COOL → `setHeatingLevel("eco")`; OFF → `setHeatingLevel("off")`. Temperature (ignored when target OFF): snap: ≤ 7+(eco−7)/2 → 7; ≤ eco → eco; ≤ eco+(comfort−eco)/2 → comfort; value shown if changed; 7 → `setHeatingLevel("frostprotection")` (Target COOL), eco → `"eco"` (Target COOL), comfort → `"comfort"` (Target HEAT), other → no command. Eco write → `setHeatingLevel(eco ? "eco" : "comfort")` | `io:TargetHeatingLevelState`: `off` → target OFF, current OFF; `frostprotection` → target HEAT, current OFF, temps 7; `comfort`/`comfort-1`/`comfort-2` → HEAT/HEAT, Eco false, temps = comfort; `eco` → COOL/COOL, Eco true, temps = eco (target only when idle); others base |
| `AtlanticElectricalHeaterWithAdjustableTemperatureSetpoint` | AUTO, OFF, plus HEAT if `io:NativeFunctionalLevelState` is `Top`; Prog | 7–28 | AUTO → `setOperatingMode("auto")` if Top, else `setOperatingMode(prog ? "internal" : "basic")`; HEAT (Top only) → `setOperatingMode(prog ? "internal" : "basic")`; OFF → `setOperatingMode("standby")`. Temperature: prog → `setDerogatedTargetTemperature(v)`, else `setTargetTemperature(v)` | computeStates on `io:EffectiveTemperatureSetpointState`, `core:TargetTemperatureState`, `io:TargetHeatingLevelState`, `core:OperatingModeState`: mode `off`/`away`/`frostprotection`/`standby` → OFF, current OFF, target temp = `core:TargetTemperatureState`; `auto` → AUTO, Prog false; `prog`/`program`/`internal`/`comfort`/`eco`/`manual`/`basic` → AUTO (HEAT if Top), Prog = mode in {prog, program, internal}; for the last two groups current = COOL if `io:TargetHeatingLevelState` is `eco` else HEAT, target temp = `io:EffectiveTemperatureSetpointState` |
| `AtlanticElectricalTowelDryer` | AUTO, OFF; Prog | 7–28 | AUTO → `setTowelDryerOperatingMode(prog ? "internal" : "external")`; OFF → `"standby"`. Temperature as above (derogated when prog). Switch `boost` (if `setTowelDryerBoostModeDuration`): on → `setTowelDryerTemporaryState("boost")` + `setTowelDryerBoostModeDuration(10)`, off → `setTowelDryerTemporaryState("permanentHeating")`. Switch `drying` (if `setDryingDuration`): on → `setTowelDryerTemporaryState("drying")` + `setDryingDuration(60)`, off → `"permanentHeating"` | `io:TowelDryerTemporaryStateState` → boost = `boost`, drying = `drying`. computeStates on target/derogated/comfort/eco room temperature, operating mode, heating level: base temp = `core:ComfortRoomTemperatureState`; level `off` → current OFF, target temp = `core:TargetTemperatureState`; `eco` → current COOL, temp = comfort − `core:EcoRoomTemperatureState`; `comfort` → current HEAT. Mode `standby` → OFF; `internal` → Prog true, AUTO, temp = `core:DerogatedTargetTemperatureState` if > 0 else the computed temp; `external` → Prog false, AUTO, computed temp (target state updated without idle check) |
| `ThermostatSetPoint`, `ProgrammableAndProtectableThermostatSetPoint` | AUTO only (Target AUTO, Current HEAT at start) | 7–30 | `setHeatingTargetTemperature(v)` | `zwave:SetPointHeatingValueState` and `core:RoomTemperatureState` → Current Temperature; `core:HeatingTargetTemperatureState` → Target |
| `SomfyThermostat` | AUTO, HEAT, COOL, OFF | 0–26 | AUTO → `exitDerogation`; HEAT → `setDerogation(["atHomeMode", "further_notice"])`; COOL → `setDerogation(["sleepingMode", "further_notice"])`; OFF → `setDerogation(["awayMode", "further_notice"])`; temperature → `setDerogation([v, "further_notice"])`. Reading Target state from HomeKit sends `refreshState` at most once a minute | computeStates on target/derogated temperature, `core:DerogationActivationState`, `somfythermostat:DerogationHeatingModeState`: derog = activation `active`; mode = `somfythermostat:DerogationHeatingModeState` if derog else `somfythermostat:HeatingModeState`; `atHomeMode`/`geofencingMode`/`manualMode` → current HEAT, target HEAT if derog else AUTO; `sleepingMode`/`suddenDropMode` → COOL, COOL or AUTO; `awayMode`/`freezeMode` → OFF/OFF. Target temp from `somfythermostat:<Mode>TargetTemperatureState` (`AtHome`, `GeofencingMode`, `ManualMode`, `SleepingMode`, `SuddenDropMode`, `AwayMode`, `FreezeMode`), else derogated/target temperature |
| `SomfyHeatingTemperatureInterface` | AUTO, HEAT, COOL, OFF; Prog, Eco | 0–26 | AUTO → `setOnOff("on")` + `setOperatingMode("both")`; HEAT → `+ "heating"`; COOL → `+ "cooling"`; OFF → `setOnOff("off")`. Prog/Eco → `setActiveMode("auto")` if Prog, else `setManuAndSetPointModes(eco ? "eco" : "comfort")`. Temperature → `setComfortTemperature(v)` if `ovp:HeatingTemperatureInterfaceSetPointModeState` is `comfort`, else `setEcoTemperature(v)` | computeStates on `core:OnOffState`, `ovp:HeatingTemperatureInterfaceOperatingModeState`: on + `both` → HEAT/AUTO; `heating` → HEAT/HEAT; `cooling` → COOL/COOL; off → OFF/OFF |
| `ValveHeatingTemperatureInterface` | AUTO, HEAT, COOL, OFF | 7–30 | AUTO → `exitDerogation`; HEAT → `setDerogation(["comfort", "further_notice"])`; COOL → `["eco", ...]`; OFF → `["away", ...]`; temperature → `setDerogation([v, "further_notice"])` | `core:TargetRoomTemperatureState` → Target temp. computeStates on `core:OperatingModeState`, `io:CurrentHeatingModeState`: auto = operating mode in {auto, prog, program}; `manual`/`comfort` → HEAT, AUTO or HEAT; `eco` → COOL, AUTO or COOL; `off`/`awayMode`/`frostprotection` → OFF/OFF |
| `AtlanticPassAPCHeatingZone` | AUTO, OFF; Eco, Prog | 10–35 | AUTO → `setHeatingOnOffState("on")` + (prog → `setPassAPCHeatingMode("internalScheduling")`; else `setDerogationOnOffState("off")` + `setPassAPCHeatingMode(eco ? "eco" : "comfort")`); OFF → `setHeatingOnOffState("off")`. Temperature: prog → `setDerogatedTargetTemperature(v)`, `setDerogationTime(derogationDuration)`, `setDerogationOnOffState("on")`; else `setEcoHeatingTargetTemperature(v)` or `setComfortHeatingTargetTemperature(v)` by Eco | computeStates on target temp, `core:HeatingOnOffState`, `io:PassAPCHeatingModeState`, `io:PassAPCHeatingProfileState`, comfort/eco heating target temps: off → OFF/OFF, temp = target; on: mode `off`/`absence` → OFF; `auto`/`internalScheduling`/`externalScheduling` → AUTO, Prog true, current HEAT if profile `comfort` else COOL, temp by profile (`derogation` → derogated, `comfort`, `eco`, else target); `comfort` → AUTO, Prog/Eco false, HEAT, comfort temp; `eco` → AUTO, Eco true, COOL, eco temp |
| `AtlanticPassAPCHeatingAndCoolingZone` | AUTO, OFF; Prog | 16–30 | "Heating" or "Cooling" = parent's `io:PassAPCOperatingModeState` is `cooling` ? Cooling : Heating. AUTO → `set<HC>OnOffState("on")` + `setPassAPC<HC>Mode(prog ? "internalScheduling" : "manu")`; OFF → `set<HC>OnOffState("off")`. Temperature: prog → if `setDerogatedTargetTemperature` exists: that + `setDerogationTime` + `setDerogationOnOffState("on")`; else `set<Profile><HC>TargetTemperature(v)` with Profile = `Eco` if `core:Eco<HC>TargetTemperatureState` equals `core:TargetTemperatureState` else `Comfort`; not prog → `set<HC>TargetTemperature(v)` if present, else `setComfort<HC>TargetTemperature(v)` | `core:TargetTemperatureState` ≥ 16 → Target temp. computeStates on heating/cooling on-off, mode and profile states: `core:<HC>OnOffState` `off` → OFF/OFF; else target temp = `core:<HC>TargetTemperatureState` or `core:TargetTemperatureState`; heating: current OFF if current temp ≥ target + 0.5 else HEAT; cooling: OFF if ≤ target − 0.5 else COOL; target AUTO; Prog = `io:PassAPC<HC>ModeState` is `internalScheduling`; target temp shown if ≥ 16 and idle |
| `AtlanticPassAPCHeatPump` | AUTO, HEAT, COOL, OFF | min 0, Target temperature read-only (perms read/notify) | AUTO/HEAT → `setPassAPCOperatingMode("heating")`; COOL → `"cooling"`; OFF → `"stop"` | computeStates on `io:PassAPCOperatingModeState`: `heating` → HEAT/HEAT, `cooling` → COOL/COOL, `stop` → OFF/OFF |
| `AtlanticPassAPCZoneControl` | AUTO, HEAT, COOL, OFF | read-only | AUTO → `setPassAPCOperatingMode("heating")` + `setHeatingCoolingAutoSwitch("on")`; HEAT → `"heating"` + `"off"`; COOL → `"cooling"` + `"off"`; OFF → `setPassAPCOperatingMode("stop")` | computeStates on `io:PassAPCOperatingModeState`, `core:HeatingCoolingAutoSwitchState`: heating → AUTO if auto switch `on` else HEAT, current HEAT; cooling → AUTO or COOL, current COOL; stop → OFF |
| `AtlanticPassAPCBoiler` | — | — | **Switch** only: on → `setPassAPCOperatingMode("heating")`, off → `"stop"` | `io:PassAPCOperatingModeState`: `stop` → off; `heating`/`drying`/`cooling` → on |
| `HitachiHeatingSystem/HitachiAirToAirHeatPump` | AUTO, HEAT, COOL, OFF | 16–30 | Both writes send `globalControl([onOff, temperature, "auto", heatMode, "manu"])`, built from the requested state and temperature (the other taken from the current Target): onOff `off` for OFF else `on`; heatMode `heating` for HEAT, `cooling` for COOL, `auto` for AUTO; for OFF heatMode follows the Current state (HEAT → `heating`, COOL → `cooling`, else `auto`); for AUTO (and OFF with neither, or an unknown state) the temperature becomes the offset target − current (current truncated to an integer), clamped to −5…5 and truncated; finally rounded. Logged at debug "FROM <cur>/<temp> TO <state>/<temp>" | `ovp:MainOperationState` `Off`/`off` → OFF/OFF; else `ovp:ModeChangeState` lowercased: `auto cooling` → COOL/AUTO, `auto heating` → HEAT/AUTO, `cooling` → COOL/COOL, `heating` → HEAT/HEAT. `ovp:RoomTemperatureState` → Current temp; `core:TargetTemperatureState` → Target |
| uiClass `EvoHome`: `EvoHomeController` | AUTO, OFF | 7–30 | AUTO → `setOperatingMode("auto")`, OFF → `setOperatingMode("off")` | base |
| uiClass `EvoHome`: `HeatingSetPoint` | AUTO (set at start) | 7–30 | base `setTargetTemperature` | base |
| uiClass `ExteriorHeatingSystem` | — | — | **Switch**: on/off → `on` / `off` | nothing that matches a switch (base heating reads only); **Recommendation:** read `core:OnOffState` |
| `ExteriorHeatingSystem/DimmerExteriorHeating` | — | — | **Lightbulb**: On → `on`/`off`; Brightness (debounced; 0/100 immediate) → `setLevel(100 − value)` | `core:LevelState`: brightness = 100 − level; On = brightness ≠ 0 |

### 5.11 Water heating and ventilation

`WaterHeatingSystem` (uiClass base, and `HitachiHeatingSystem/HitachiDHW`): the base thermostat with min 40, max 65, step 1,
modes AUTO and OFF (commands `auto` / `off`, temperature `setTargetTemperature`).

| widget (uiClass `WaterHeatingSystem`) | Specifics |
|---|---|
| `AtlanticPassAPCDHW` | Eco, Prog. Switch `boost` if `setBoostOnOffState` (on/off → `setBoostOnOffState("on"/"off")`). AUTO → `setDHWOnOffState("on")` + `setPassAPCDHWMode("internalScheduling" if Prog, else "eco"/"comfort" by Eco)`; OFF → `setDHWOnOffState("off")`. Temperature: Target state COOL → `setEcoTargetDHWTemperature(v)`, else `setComfortTargetDHWTemperature(v)`. Reads: `core:TargetDHWTemperatureState` → **Current** Temperature; `core:BoostOnOffState` → boost; computeStates on `core:DHWOnOffState`, `io:PassAPCDHWModeState`, `io:PassAPCDHWProfileState`, comfort/eco DHW temps: off → OFF, temp = `core:TargetDHWTemperatureState`; on: mode `off`/`stop` → OFF; `internalScheduling`/`externalScheduling` → AUTO, Prog true, profile `comfort` → HEAT and comfort temp else COOL and eco temp; `comfort` → AUTO, HEAT, comfort temp; `eco` → AUTO, Eco true, COOL, eco temp |
| `DomesticHotWaterProduction` | Modes AUTO, HEAT, OFF; Eco. Always a Switch `boost` (on/off → `setBoostMode("on"/"off")`). If `core:NumberOfShowerRemainingState` exists: custom Current Shower and Target Shower (5.13), Target range from `core:MinimalShowerManualModeState`…`core:MaximalShowerManualModeState`; Target Shower write → `setExpectedNumberOfShower(v)` (FAILED → previous value). Target state write, by the first command the device has: **`setDHWMode`**: when the current Target is OFF first `setAbsenceMode("off")`; AUTO → `setDHWMode("autoMode")`, HEAT → `setDHWMode("manualEcoActive")` if Eco else `"manualEcoInactive"`, OFF → `setAbsenceMode("on")`. **`setCurrentOperatingMode`**: AUTO → `{"relaunch": "off", "absence": "off"}`, HEAT → `{"relaunch": "on", "absence": "off"}`, OFF → `{"relaunch": "off", "absence": "on"}`. **`setBoostModeDuration`**: AUTO → `setBoostModeDuration(0)` + `setAwayModeDuration(0)`; HEAT → `setBoostModeDuration(1)`; OFF → `setAwayModeDuration(30)`. **`setBoostMode`**: AUTO → `setBoostMode("off")` + `setAbsenceMode("off")`; HEAT → `setBoostMode("on")`; OFF → `setAbsenceMode("on")`. Temperature → `setWaterTargetTemperature(v)`. Reads: `io:DHWBoostModeState` / `modbuslink:DHWBoostModeState` → boost = value ≠ `off`; `core:WaterTemperatureState` → Current temp unless the device has `io:MiddleWaterTemperatureState`; `io:MiddleWaterTemperatureState` / `modbuslink:MiddleWaterTemperatureState` → Current temp; `core:TargetTemperatureState` / `core:WaterTargetTemperatureState` → Target temp; `core:NumberOfShowerRemainingState` → Current Shower; `core:ExpectedNumberOfShowerState` → Target Shower; computeStates (prefix `io` or `modbuslink`, from which state changed) on `<p>:DHWModeState`, `<p>:DHWAbsenceModeState`: absence `off` and mode `autoMode` → AUTO/HEAT; `manualEcoInactive` → Eco false, HEAT/HEAT; `manualEcoActive` → Eco true, HEAT target, COOL current; absence not `off` → OFF/OFF |
| `DomesticHotWaterProduction/AtlanticDomesticHotWaterProductionV2_SPLIT_IOComponent` (by uniqueName) | As DomesticHotWaterProduction, with: Target temperature min 50, max 54.5, step 2, validValues 50, 52, 54, 54.5, 55; write `setTargetTemperature(v)` with 54 sent as 54.5. Target state: if current Target OFF first `setCurrentOperatingMode({"relaunch": "off", "absence": "off"})`; AUTO → `setDHWMode("autoMode")`; HEAT → `manualEcoActive`/`manualEcoInactive` by Eco; OFF → `setCurrentOperatingMode({"relaunch": "off", "absence": "on"})`. Boost → `setCurrentOperatingMode({"relaunch": "on"/"off", "absence": "off"})`. Reads only `io:MiddleWaterTemperatureState` (current), `core:TargetTemperatureState` (target), and computeStates on `io:DHWModeState` / `core:OperatingModeState` (an object): boost = `relaunch` ≠ `off`; absence `off` → mode `autoMode` → AUTO, `manualEcoInactive`/`manualEcoActive` → HEAT (Eco accordingly), current HEAT if `io:PowerHeatElectricalState` > 100 or `io:PowerHeatPumpState` > 100 else OFF; absence on → OFF/OFF |
| `DomesticHotWaterTank` | Only a Switch `boost`: `setForceHeating("on"/"off")`; read `io:ForceHeatingState` = `on` |

`VentilationSystem`: **Air Purifier** with Active (writes accepted but nothing sent; never updated), Current Air Purifier
State (never updated) and Target Air Purifier State: AUTO → `setAirDemandMode("auto")`, MANUAL (or other) →
`setAirDemandMode("boost")`; COMPLETED + stateless → Current = target; FAILED → Target = Current. Read `io:AirDemandModeState`:
`auto` → AUTO, anything else → MANUAL. `VentilationSystem/DimplexVentilationInletOutlet`: AUTO → `auto`, MANUAL → `max`.

### 5.12 Scenarios

When `exposeScenarios` is truthy: for each action group (after the exclusions of 2.3), an accessory named with its `label`
(UUID = its `oid`) with one **Switch** service, On initialised to false.

- On written true → `POST /exec/<oid>` (body: an execution object with an empty label, no actions, null metadata); the returned
  execId is remembered. When that execution reaches COMPLETED or FAILED: log "[Scene] <label> <COMPLETED | failureType>" and
  set On back to false.
- On written false while that execution is still in flight → `DELETE /exec/current/setup/<execId>`.

Scenario accessories have no Accessory Information details beyond Homebridge's defaults.

### 5.13 Custom characteristics

| Name | UUID | Format and props |
|---|---|---|
| Current Shower | `10000001-0000-1000-8000-0026BB765291` | int 0–8 step 1, read/notify |
| Target Shower | `10000002-0000-1000-8000-0026BB765291` | int 0–8 step 1, read/write/notify |
| My | `10000003-0000-1000-8000-0026BB765291` | bool, read/write/notify |
| Prog | `10000004-0000-1000-8000-0026BB765291` | bool, read/write/notify |
| Eco | `10000005-0000-1000-8000-0026BB765291` | bool, read/write/notify |
| Total Consumption (Eve) | `E863F10C-079E-48FF-8F27-9C2605A29F52` | float kWh 0–1000000 step 0.1, read/notify |
| Current Consumption (Eve) | `E863F10D-079E-48FF-8F27-9C2605A29F52` | float W 0–12000 step 0.1, read/notify |

The first five use Apple's base-UUID suffix; keep them for compatibility with existing Eve/Controller layouts, but note the
Home app does not show them.

---

## 6. Behaviour

### 6.1 Start-up

1. Log in (3.x) lazily on the first request.
2. Discovery: `GET /setup/devices`, group (5.2), skip exclusions, create or reuse accessories, build mappers. Then, if
   `exposeScenarios`, `GET /actionGroups` and build scenario switches. Cached accessories not seen are removed. Any error
   during discovery: log it, log "Retry in <n> sec...", retry after n seconds, n starting at 60 and doubling each failure
   (reset on success).
3. Cloud only: `GET /setup/location`; its `countryCode` (lowercase) selects the execution label language (English, French);
   failure is a warning.
4. On "connect" (each successful login) the refresh task starts with `refreshPeriod` and the event polling with
   `pollingPeriod`; on "disconnect" both stop and the listener id is forgotten.

### 6.2 Event polling

A repeating task with the current period. The period is `pollingPeriod` normally and `execPollingPeriod` (5 s) while an
execution is in flight. Changing the period restarts the timer; when the listener is not yet registered the first run
happens immediately. A period of 0 stops the timer and forgets the listener ("Disable event polling" at debug).

Each run:

- If the current period is not `pollingPeriod` and no execution is in flight, switch back to `pollingPeriod` (and do
  nothing else this run).
- Else, unless a previous run is still running, fetch: if a listener id exists, `POST /events/<id>/fetch` and process the
  events (4.3). On success the error delay resets to 10 s. On error: log "Polling error - <error>"; if the error text
  contains `400`, `401` or `404`, forget the listener; wait the error delay (blocking further runs), then double it.
- If no listener id: `POST /events/register` and keep the `id`; on error log "Registration error - <error>", wait the error
  delay, double it.

The error delay has no upper bound in the source. **Recommendation:** cap it (e.g. 10 min) and use Homeswift's `Backoff`.

Overkiz drops a listener that is not fetched for a while (the warning about `pollingPeriod` > 60 s exists for that reason);
the error then comes back as "Invalid event listener id" / "No registered event listener" and the listener is re-registered.

### 6.3 Full refresh

Every `refreshPeriod` minutes: `POST /setup/devices/states/refresh` with body `[]` (errors ignored), which asks the gateway
to poll every device. When `RefreshAllDevicesStatesCompletedEvent` arrives (or, failing that, 30 s later), `GET
/setup/devices` and apply each device's `states` as a state update (only changed values are delivered). Errors are logged.
This is what catches changes made with local remotes that the gateway does not report by itself.

### 6.4 Executions

Batching:

- Per mapper: the first command of a write opens a 100 ms window; commands from the same device within the window are meant
  to join the same action (but see Gaps: they are dropped).
- Per platform: actions from different devices within another 100 ms window go into one execution; its label becomes
  "Execute scene (<n> devices) - HomeKit".
- **Standalone** executions (timed stops and the moves they stop) skip the platform window and go alone.

Label of a single-device execution: "<device label> - <command label> - HomeKit". Command label: the command name, plus
`.<first parameter>` when there are parameters, looked up in the language file (English: `setClosure` → "Close <n>%"; French
"Fermeture <n>%"); because of how the lookup is written only parametrised entries are translated, others stay as the raw
key (e.g. `open`, `setHeatingLevel.comfort`), and on the local API (no language loaded) all are raw. Labels are cosmetic
(shown in the vendor app's history).

Posting: `POST /exec/apply` (or `apply/highPriority`, 4.4). The returned execId is tracked. After posting, the polling period
switches to `execPollingPeriod`. A 2 minute timer removes the execution if no final event came, emitting TIMED_OUT to its
actions.

Tracking: each `ExecutionStateChangedEvent` for a tracked execution is passed to every action of it: if the event has
`failureType` and `failedCommands`, actions whose `deviceURL` is in `failedCommands` get FAILED (with the failure object),
the others COMPLETED; otherwise all get the event's `newState`. `timeToNextState` = −1 ends tracking. Action updates are
logged per mapper: FAILED at error "[label] <command> <failureType>", COMPLETED at info "[label] <command> COMPLETED", others
at debug.

In-progress feedback is per mapper (Position State, Door State OPENING/CLOSING, ...), see section 5. Target values are not
overwritten by incoming states while the mapper's own execution is in flight ("idle" checks), so HomeKit sliders do not jump
back during a move.

### 6.5 Edge cases

- Devices that become unavailable are not marked in HomeKit (no `available` handling). **Recommendation:** use the device's
  `available` field and the `core:StatusState` value `unavailable` to flag Not Responding.
- New devices appear only on restart (discovery runs once). **Recommendation:** re-run discovery on the full refresh.
- State values for unknown states (not in the initial listing) are appended and delivered.
- Writes on stateless devices update HomeKit only from the execution outcome.

---

## 7. Logging (paraphrased)

Platform: "Create accessory: <label>" (info) when new; "Configure device <label>" and "  <uiClass> > <widget>" (info) for
each device; the effective device options as JSON (debug, or info when `debug`); "<widget> not supported." or the mapper's
error message (warn); discovery errors and "Retry in <n> sec..." (error); "Create accessory <label>" and "Map scene <label>"
for scenarios; "Fail to load lang file" (warn).

Mapper: each command sent "[label] <name>[<parameters as JSON>]" (info); outcomes as in 6.4; "Will stop movement in <ms>
millisec" (info); "No target command for <label>" (error); state changes "[label] <state> => <value>" (debug).

Client: the period warnings of 2.1; "Enable event polling period every <n> sec", "Change event polling period to <n> sec",
"Disable event polling" (debug); "Polling error - ...", "Registration error - ..." (error); "Refresh all states completed"
(debug); the lockout warning (3.1); "Session expired: ..." (debug); every request "<METHOD> <url>" (debug); local: mDNS
progress (debug) and the "no gateway found" warnings.

Secrets: the source never logs the password or token directly, but [OC]'s token creation logs the generated token object at
debug. **Recommendation:** never log tokens, JSESSIONID, JWTs or the Basic credential; mask the gateway PIN and e-mail.

---

## 8. Test vectors (invented identifiers)

### 8.1 Setup excerpt (`GET /setup/devices`, cloud)

    [ { "oid": "0f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f", "deviceURL": "io://1234-5678-9012/7654321",
        "label": "Living room shutter", "controllableName": "io:RollerShutterGenericIOComponent",
        "available": true, "enabled": true,
        "definition": { "uiClass": "RollerShutter", "widgetName": "PositionableRollerShutter", "type": "ACTUATOR",
          "commands": [ { "commandName": "setClosure", "nparams": 1 }, { "commandName": "open", "nparams": 0 },
                        { "commandName": "close", "nparams": 0 }, { "commandName": "stop", "nparams": 0 },
                        { "commandName": "my", "nparams": 0 } ] },
        "states": [ { "name": "core:ClosureState", "type": 1, "value": 30 },
                    { "name": "core:TargetClosureState", "type": 1, "value": 30 },
                    { "name": "core:ManufacturerNameState", "type": 3, "value": "Somfy" } ] },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000002", "deviceURL": "rts://1234-5678-9012/16712345",
        "label": "Kitchen blind", "controllableName": "rts:BlindRTSComponent",
        "definition": { "uiClass": "ExteriorScreen", "widgetName": "UpDownExteriorScreen",
          "commands": [ { "commandName": "open", "nparams": 1 }, { "commandName": "close", "nparams": 1 },
                        { "commandName": "my", "nparams": 1 }, { "commandName": "stop", "nparams": 1 } ] } },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000003", "deviceURL": "io://1234-5678-9012/5551234#1",
        "label": "Bathroom heater", "controllableName": "io:AtlanticElectricalHeaterWithAdjustableTemperatureSetpointIOComponent",
        "definition": { "uiClass": "HeatingSystem", "widgetName": "AtlanticElectricalHeaterWithAdjustableTemperatureSetpoint",
          "commands": [ { "commandName": "setOperatingMode", "nparams": 1 }, { "commandName": "setTargetTemperature", "nparams": 1 },
                        { "commandName": "setDerogatedTargetTemperature", "nparams": 1 } ] },
        "states": [ { "name": "core:OperatingModeState", "type": 3, "value": "internal" },
                    { "name": "io:TargetHeatingLevelState", "type": 3, "value": "comfort" },
                    { "name": "io:EffectiveTemperatureSetpointState", "type": 2, "value": 20.5 },
                    { "name": "io:NativeFunctionalLevelState", "type": 3, "value": "Top" } ] },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000004", "deviceURL": "io://1234-5678-9012/5551234#2",
        "label": "Bathroom heater temperature", "controllableName": "io:TemperatureIOSystemSensor",
        "definition": { "uiClass": "TemperatureSensor", "widgetName": "TemperatureSensor", "commands": [] },
        "states": [ { "name": "core:TemperatureState", "type": 2, "value": 293.65 } ] } ]

Expected:

- Shutter: Window Covering; Current = Target = 70 (100 − 30); Obstruction Detected present; no My. Serial `io:7654321`.
  Manufacturer "Somfy", Model "RollerShutter".
- Kitchen blind: stateless (no states): Window Covering with My (has `my`); writing Target 100 sends `open`, 0 sends `close`,
  40 sends `my`; with `movementDuration: 20` and Current 0, writing 40 sends `open` alone (standalone) and 8000 ms after
  IN_PROGRESS sends `stop` or cancels.
- Heater (`#1`): Thermostat with Prog; modes AUTO, OFF, HEAT (Top); after 500 ms: Target state HEAT (Top + `internal`), Prog
  true, Current HEAT, Target temperature 20.5.
- `#2`: widget `TemperatureSensor` → attached to the heater (uiClass HeatingSystem), not exposed; Current Temperature of the
  thermostat = 20.5 (293.65 − 273.15).

### 8.2 Apply bodies

Target Position 60 on the shutter (→ closure 40), cloud, English location:

    POST /exec/apply
    { "label": "Living room shutter - Close 40% - HomeKit",
      "actions": [ { "deviceURL": "io://1234-5678-9012/7654321",
                     "commands": [ { "type": 1, "name": "setClosure", "parameters": [40] } ] } ],
      "metadata": null }
    → { "execId": "ee7a5676-0000-4000-8000-0000000000aa" }

Two devices within 100 ms: one body, label "Execute scene (2 devices) - HomeKit", two `actions`.

Venetian blind (has `setClosureAndOrientation`), Target Position 100 with Target Tilt 0: `setClosureAndOrientation` with
parameters `[0, 50]`. Tilt −90 → orientation 0; tilt 90 → 100; orientation 30 → tilt −36.

Alarm, HomeKit Night, default zones: `{"type":1,"name":"alarmZoneOn","parameters":["B"]}`.

Water heater V2 SPLIT, OFF while Target was AUTO: one command
`{"type":1,"name":"setCurrentOperatingMode","parameters":[{"relaunch":"off","absence":"on"}]}`.

### 8.3 Events

    POST /events/register → { "id": "a70f6d96-0000-4000-8000-0000000000bb" }
    POST /events/a70f6d96-0000-4000-8000-0000000000bb/fetch →
    [ { "name": "ExecutionStateChangedEvent", "execId": "ee7a5676-0000-4000-8000-0000000000aa",
        "oldState": "TRANSMITTED", "newState": "IN_PROGRESS", "timeToNextState": 0, "type": 1, "subType": 1 },
      { "name": "DeviceStateChangedEvent", "deviceURL": "io://1234-5678-9012/7654321",
        "deviceStates": [ { "name": "core:ClosureState", "type": 1, "value": 40 } ] },
      { "name": "ExecutionStateChangedEvent", "execId": "ee7a5676-0000-4000-8000-0000000000aa",
        "oldState": "IN_PROGRESS", "newState": "COMPLETED", "timeToNextState": -1, "type": 1, "subType": 1 } ]

Expected (shutter at Current 70, target 60): Position State DECREASING on IN_PROGRESS, then Current 60 (Target untouched
because the device has `core:TargetClosureState`), then STOPPED and Obstruction false; tracking ends; polling returns to
`pollingPeriod` on the next run.

Failure:

    { "name": "ExecutionStateChangedEvent", "execId": "...", "newState": "FAILED", "timeToNextState": -1,
      "failureType": "WHILEEXEC_BLOCKED_BY_HAZARD",
      "failedCommands": [ { "deviceURL": "io://1234-5678-9012/7654321", "command": { "name": "setClosure" } } ] }

Expected: Position State STOPPED, Obstruction Detected true; error log "[Living room shutter] setClosure
WHILEEXEC_BLOCKED_BY_HAZARD".

Errors (from [PY] fixtures, shapes only):

    401 { "errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not authenticated" }
    400 { "errorCode": "UNSPECIFIED_ERROR", "error": "Invalid event listener id : abc-123-def" }
    400 { "errorCode": "EXEC_QUEUE_FULL", "error": "Execution queue is full on gateway: #1234-5678-9012 (soft limit: 10)" }

### 8.4 Login requests

    POST https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI/login
    Content-Type: application/x-www-form-urlencoded
    userId=user%40example.com&userPassword=...
    → 200, Set-Cookie: JSESSIONID=ABCDEF0123456789; Path=/enduser-mobile-web; Secure; HttpOnly

    Local: GET https://192.168.1.50:8443/enduser-mobile-web/1/enduserAPI/apiVersion
    Authorization: Bearer 0123456789abcdef0123
    → { "protocolVersion": "2026.4.4-12" }

### 8.5 Behaviour checks worth testing

- Exclusion by protocol (`rts`), by label, by uiClass; built-in `Pod` excluded.
- `devicesConfig` precedence: uiClass entry < widget entry < label entry < UUID entry.
- Stateless gate with only `core:OpenClosedState` (literal: stateless; recommended: stateful).
- Low-speed window `22:00-07:30` at 23:00 → `setClosureAndLinearSpeed([c, "lowspeed"])`; at 12:00 → `setClosure(c)`.
- Pilot-wire snapping with comfort 19, eco 17 (limits: frost/eco 12, eco/comfort 18): 8 → 7 (`frostprotection`),
  12 → 7, 13 → 17 (`eco`), 18 → 19 (`comfort`), 19 → 19.
- Execution timeout after 2 min emits TIMED_OUT; 401 during fetch re-logs in on the next registration.

---

## 9. What a drop-in must reproduce exactly

- Platform name `Tahoma`; keys `service`, `user`, `password`, `pollingPeriod` (s), `refreshPeriod` (min), `exposeScenarios`,
  `exclude`, `devicesConfig` with `key` and the option names of 2.4; service values and aliases of 2.2.
- Server hosts, base paths (`/enduser-mobile-web/enduserAPI`, local `/enduser-mobile-web/1/enduserAPI` on 8443), login forms
  (`userId`/`userPassword`, Cozytouch `jwt` after the Atlantic token and JWT calls with `GA-PRIVATEPERSON/` prefix), JSESSIONID
  cookie, local Bearer token, PIN pattern and `_kizboxdev._tcp`/`gateway-<PIN>.local`.
- Event listener register/fetch, `exec/apply` body shape, `exec/<oid>` for scenarios, cancel path, refresh paths.
- Every command name, parameter order and literal of section 5, and every state name and value mapping.
- Conversions: closure inversion (100 − v, flipped by `reverse`), awning non-inversion, orientation ↔ tilt (×1.8 − 90), Kelvin
  detection (> 200 sensors, > 273.15 thermostats), Wh → kWh (/1000), dimmer exterior heating inversion.
- Exclusion semantics including the built-in list; sub-device attachment rules (5.2).
- Custom characteristic UUIDs (5.13).
- In-progress feedback and "idle" guarding of targets; stateless behaviour (no state subscription).
- Identity: a stable id per `deviceURL` (Homeswift: `Tahoma:<deviceURL>`), stable subtypes `boost`, `drying`, `pedestrian`.

---

## 10. Gaps and hard parts

1. **Somfy cloud login is moving to OAuth.** [OC] still posts `userId`/`userPassword` to `/login`; [PY] uses
   `accounts.somfy.com` OAuth with Bearer tokens (and a multi-site Keycloak flow). **Recommendation:** implement the session
   login as the default (drop-in), add the OAuth password grant as an automatic fallback when `/login` answers bad
   credentials for `somfy_europe`, never send cookie and Bearer together, and prefer the local API through Setup.
2. **Rexel** on `ha112-1` with a session login is likely obsolete ([PY] uses Azure B2C OAuth + a proxy with `gatewayId`
   header). **Recommendation:** keep the option, mark it unverified; Rexel local API (Energeasy Connect V2/V3) works like
   Somfy's local API [PY].
3. **Local API and execution modes.** `apply/highPriority` (chosen when the device has `io:PriorityLockLevelState`) is
   rejected by the local API [PY]. **Recommendation:** never send a mode on `local`.
4. **Command merging bug.** The per-mapper 100 ms merge replaces parameters of commands already in the action instead of
   adding the new ones, so a second command in the window is silently dropped (e.g. On + Brightness written together sends
   only `on`). **Recommendation:** merge by command name (replace same name, append others), and for a light written On=true
   with Brightness send only `setIntensity` (or `on` then `setIntensity`).
5. **Shared debounce timer.** Position and tilt share one 500 ms timer, so a tilt write cancels a pending position write.
   **Recommendation:** one timer per characteristic, and merge position + tilt into one `setClosureAndOrientation`.
6. **Concurrency limit never applies.** The "10 executions in flight → wait 10 s" guard counts the wrong thing and never
   triggers. **Recommendation:** count tracked executions, and on `EXEC_QUEUE_FULL` / "Too many executions" retry with backoff
   ([PY]'s policy, 4.5).
7. **Unknown uiClass crashes discovery** (mapper lookup falls back to a non-constructible value), which aborts and retries the
   whole discovery with doubling delays. **Recommendation:** skip unsupported devices with a warning.
8. **JSON object states frozen.** Existing states of type 10/11 are never updated, so the V2 SPLIT water heater's
   `core:OperatingModeState` (an object) never changes after start. **Recommendation:** compare JSON values structurally and
   update them.
9. **blindsOnRollerShutter** sends `setClosure(position + 2)` with the HomeKit position, not the closure; intended is likely
   a 2 % move back up from the reached closure. **Recommendation:** send `setClosure(max(0, closure − 2))`; confirm with users.
10. **Gate stateless detection** ignores `core:OpenClosedState`; **ExteriorHeatingSystem** ignores `core:OnOffState`;
    **WaterDetectionSensor** never matches its state; **CO2Sensor** loses defect handling; **MyFox** Stay has no command;
    **GarageDoor** failure restore skips an OPEN previous target; **Alarm** `occupancySensor` unimplemented;
    **VentilationSystem** Active/Current never driven; **Light** Hue writes not sent; **exposeScenarios** list not honoured;
    **LowSpeed** mapper ignores other cover options. Each: **Recommendation:** fix, keeping the literal behaviour where
    HomeKit layouts depend on it (service types and subtypes must not change).
11. **Identity across cloud/local.** UUIDs come from `oid` on the cloud and from `deviceURL` locally. **Recommendation:** use
    `deviceURL` everywhere (5.1) so a user can switch to the local API without losing HomeKit rooms.
12. **Unbounded backoffs** (polling error delay, lockout ×4, discovery ×2). **Recommendation:** cap them; keep the login lockout
    (it protects against Overkiz bans) but cap at a few hours and surface it in the UI.
13. **TLS on the local API** is unverified in [OC]. **Recommendation:** pin the Overkiz Root CA (3.4) or TOFU per gateway.
14. **Rate limits.** Overkiz throttles logins, concurrent requests and executions (4.5). Polling more often than every 10 s on
    the cloud, or many quick slider writes, risks bans; keep debouncing and batching.
15. **Hard parts for the implementer:** the per-uiClass mapping surface (section 5, ~60 mappers) with many vendor-specific
    command names; execution tracking across the shared event listener (per-action outcome from `failedCommands`); the timed
    stop for stateless RTS covers (standalone executions, cancel vs `stop`); the Cozytouch double token flow; mDNS PIN
    lookup with Avahi on Linux (browse `_kizboxdev._tcp`, match the instance name); and keeping HomeKit targets stable during
    in-flight executions.

---

## 11. Somfy OAuth sign-in (from pyoverkiz)

Addendum. Every fact in this section comes from [PY] 2.3.1 (commit `5f31858570e14be4f58e6cc58b7a448000556449`), from its
constants, its auth strategies and their tests. Neither homebridge-tahoma nor overkiz-client implements this flow. Where
[PY] does not say something (for example the HTTP status of an error), this section says so instead of guessing.

### 11.1 Which servers use which sign-in (as of pyoverkiz 2.3.1)

| [PY] server | Overkiz base URL | Sign-in [PY] uses |
|---|---|---|
| `somfy_europe` | `https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI/` | **Somfy OAuth password grant** (11.2), Bearer token |
| `somfy` (multi-site) | chosen per site: EMEA `ha101-1`, APAC `ha201-1`, SNABA `ha401-1` (same path) | OAuth password grant, then a Keycloak token exchange and site-scoped tokens (11.6) |
| `somfy_oceania` | `https://ha201-1.overkiz.com/enduser-mobile-web/enduserAPI/` | old session login: `POST <base>login`, form `userId`, `userPassword` |
| `somfy_america` | `https://ha401-1.overkiz.com/enduser-mobile-web/enduserAPI/` | old session login |
| `simu_livein2`, `flexom`, `hi_kumo_*`, `hexaom_hexaconnect`, `ubiwizz` | their `haNNN-1` host | old session login |
| `atlantic_cozytouch`, `thermor_cozytouch`, `sauter_cozytouch` | `ha110-1` | Atlantic token, then a JWT, then `login` with `jwt` (3.2) |
| `brandt`, `sauter_smart_control`, `nexity`, `rexel` | various | their own middleware or OAuth flows (not the Somfy one) |

So in [PY] the Somfy OAuth flow applies only to `somfy_europe` and to `somfy`. Somfy Oceania (Australia) and Somfy North
America still go through the `userId`/`userPassword` session login. There is **one** OAuth token endpoint for all Somfy
regions; the region only changes the Overkiz host the token is then used against. [PY] does not state whether `ha101-1`
still accepts the old `/login` form. It simply no longer sends it for Somfy Europe. The plugin (overkiz-client) still sends
`/login` for every Somfy region.

### 11.2 Password grant (`somfy_europe`, and the first step of `somfy`)

- Endpoint: `POST https://accounts.somfy.com/oauth/oauth/v2/token/jwt`
- Header: `Content-Type: application/x-www-form-urlencoded`
- Form fields (exactly these five; no `scope`):
  - `grant_type` = `password`
  - `client_id` = `0d8e920c-1478-11e7-a377-02dd59bd3041_1ewvaqmclfogo4kcsoo0c8k4kso884owg08sg8c40sk4go4ksg`
  - `client_secret` = `12k73w1n540g8o4cokg0cw84cog840k84cwggscwg884004kgk`
  - `username` = the Somfy account e-mail
  - `password` = the account password
- The `client_id` and `client_secret` above are the TaHoma app's constants exactly as [PY] publishes them. [PY] comments that
  these OAuth client secrets are public by design, because they are embedded in the mobile apps.
- The JSON answer is used as follows:
  - `access_token` is required.
  - `refresh_token` is optional (if absent, no refresh is possible and the next expiry leads to a new password grant).
  - `expires_in`, in seconds, is optional. The expiry time is now + `expires_in`. With no `expires_in`, the token counts as
    never expiring until the server rejects it.
  - Other fields, such as `token_type`, are ignored.
- [PY] sends no `User-Agent` override on this call. The Overkiz calls carry `User-Agent: pyoverkiz/<version>`.

### 11.3 Using the token against Overkiz

- Every Overkiz request goes to the server's base URL (for `somfy_europe`
  `https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI/`, with paths such as `setup`, `events/register`,
  `exec/apply`). Each request carries `Authorization: Bearer <access_token>`.
- **No `login` call is made and no JSESSIONID cookie is used** afterwards. Overkiz rejects a request that carries both a
  cookie session and a Bearer token, with the error "Cannot use JSESSIONID and bearer token in same request"
  (`errorCode` `UNSPECIFIED_ERROR`). An implementation that switches a client from the old flow to OAuth must therefore drop
  any stored cookie.
- After authenticating, [PY]'s `login` registers the event listener (`POST events/register`) unless asked not to. It does
  not call any login endpoint on Overkiz.

### 11.4 Refresh

- Trigger: before **every** Overkiz request, [PY] checks the expiry. The token is due when now ≥ expiry − 5 seconds. Only a
  known expiry and a stored refresh token lead to a refresh; otherwise the request goes out as is.
- Request: `POST https://accounts.somfy.com/oauth/oauth/v2/token/jwt`, form-urlencoded. Fields:
  - `grant_type` = `refresh_token`
  - `client_id` (same value as in 11.2)
  - `client_secret` (same value as in 11.2)
  - `refresh_token` = the stored refresh token
- The answer has the same fields as in 11.2. The new values replace the old ones, including a new `refresh_token` when one is
  given.
- After a successful refresh, if an event listener was registered, [PY] registers a new one, because listener ids are tied
  to the old session.
- A reactive path also exists: an Overkiz answer of `RESOURCE_ACCESS_DENIED` / "Not authenticated" (HTTP 401 in the cloud
  fixtures) makes [PY] sign in again from scratch with a new password grant, not a refresh. It then retries the request once
  (backoff with jitter: 2 tries, at most 60 s).

### 11.5 Errors

- **Bad credentials, password grant:** the JSON body `{"message": "error.invalid.grant"}`. [PY] does not check the HTTP
  status for this; its tests return the body with status 200. It reports bad credentials whenever that `message` appears.
- **No access token:** an answer without `access_token` (for example only `{"token_type": "bearer"}`) is reported as a Somfy
  service error.
- **Server errors:** any 5xx answer from the token endpoint is treated as a temporary outage (service unavailable). This
  includes HTML pages and pages containing `is down for maintenance`.
- **Rejected refresh, single-site:** the same `{"message": "error.invalid.grant"}` maps to bad credentials, so the user has
  to sign in again.
- **Rejected refresh, multi-site** (11.6, the Keycloak endpoint): a non-200 answer whose JSON has
  `"error": "invalid_grant"` (with `error_description`) is bad credentials. Its test uses status 400 and gives a revoked
  refresh token after a password change as the cause. Other non-200 answers are service errors.
- **Expired or invalid Bearer at Overkiz:** HTTP 401 with `{"errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not
  authenticated"}`. A missing header gives `"Missing authorization token."` with the same `errorCode`. Repeated invalid
  tokens give `UNSPECIFIED_ERROR` `"Too many attempts with an invalid token, temporarily banned"`.

**Recommendation:** treat `error.invalid.grant` and `invalid_grant` as terminal (ask the user to sign in again in Setup;
do not retry in a loop), and treat 5xx as retryable with backoff.

### 11.6 Multi-site variant (`somfy`), for reference

[PY] says this flow copies how the TaHoma app signs in and may change within pyoverkiz 2.x. It works as follows:

1. Do the password grant of 11.2.
2. Exchange the token: `POST https://ginaite-prod.ovkube.net/realms/somfy-tahoma/protocol/openid-connect/token`, form
   fields:
   - `grant_type` = `urn:ietf:params:oauth:grant-type:token-exchange`
   - `client_id` = the same Somfy client id, used as a public client (no secret)
   - `subject_token` = the access token from step 1
   - `subject_issuer` = `somfy-customer`
   - `subject_token_type` = `urn:ietf:params:oauth:token-type:access_token`

   The answer gives an account-wide token (`access_token`, `refresh_token`, `expires_in`). A non-200 answer is a service
   error.
3. List the sites: `GET https://backoffice-service.ovkube.net/site-api/public/v1/sites?withGateways=true&limit=20&offset=<n>`.
   Headers: `Authorization: Bearer <account token>` and `X-Api-Key: 184638B3FBE874ACD24C14FBD657B`. Pages of 20, stopping
   at 200 sites. The answer has `results` (sites with `site_oid`, `name`, `country`, `roles`, `sub_sites` with `gateways` of
   `gateway_id`) and `total_count`. If there is exactly one site it is selected automatically.
4. Select a site:
   - its country gives the region (EMEA by default) and so the Overkiz host;
   - the token is then refreshed with `refresh_token` at the Keycloak URL with `?siteOID=<site oid>` appended. Form fields:
     `grant_type=refresh_token`, `client_id`, `refresh_token`, no secret. The answer is a site-scoped token used as the
     Bearer, with no gateway header;
   - if the answer has no `expires_in`, the token is assumed to last 5 minutes.
5. Keycloak **rotates** the refresh token on each refresh and invalidates the old one. Refreshes must therefore be
   serialised, and the new refresh token must be stored each time it changes.

### 11.7 Local Developer Mode token from an OAuth session

All the calls below go to the Overkiz cloud base URL with the OAuth Bearer from 11.3. `<pin>` is the gateway id, for
example `1234-5678-9012` (from `GET setup/gateways`, field `gatewayId`).

1. Developer Mode (optional check):
   - `GET setup/gateways/<pin>/developerMode` answers `{"active": true|false}`.
   - If it is not active, `POST setup/gateways/<pin>/developerMode` with no body switches it on. [PY] says Somfy gateways
     need this before local tokens can be used.
   - [PY] also has a `DELETE` on the same path to switch it off, but warns that some gateways answer
     `Request method 'DELETE' not supported`.
2. Generate: `GET config/<pin>/local/tokens/generate` answers `{"token": "<token>"}`.
3. Activate: `POST config/<pin>/local/tokens` with the JSON body
   `{"label": "<label>", "token": "<token from step 2>", "scope": "devmode"}`, exactly these three keys. It answers
   `{"requestId": "<id>"}`. (overkiz-client also adds `"gatewayId": "<pin>"` to this body.) A generated token is not usable
   until it has been activated.
4. List: `GET config/<pin>/local/tokens/devmode` answers an array of
   `{"label", "gatewayId", "uuid", "scope", ...}`. Revoke: `DELETE config/<pin>/local/tokens/<uuid>`.
5. Use the token against `https://<gateway>:8443/enduser-mobile-web/1/enduserAPI/` with `Authorization: Bearer <token>`
   (3.4).
6. Errors seen:
   - `RESOURCE_ACCESS_DENIED` `"Access denied to gateway #<pin> for action ADD_TOKEN"` when the account may not add tokens
     to that gateway;
   - `UNSPECIFIED_ERROR` `"Not such token with UUID: <uuid>"` on a delete of an unknown token.

The same calls work over the old cookie session (overkiz-client). For Somfy Oceania and North America that session is the
only cloud sign-in [PY] offers.

**Recommendation (Homeswift Setup):** for Somfy Europe, run the password grant in `authorize`. Keep the access token and
refresh token in memory only. Generate and activate a token labelled "Homeswift", store that local token with
`context.secretFile`, and then use only the local API. Never log the tokens, the client secret or the `requestId`.

### 11.8 Test vectors (invented values)

Password grant request body (form-urlencoded; the `@` is encoded):

    grant_type=password&client_id=0d8e920c-1478-11e7-a377-02dd59bd3041_1ewvaqmclfogo4kcsoo0c8k4kso884owg08sg8c40sk4go4ksg&client_secret=12k73w1n540g8o4cokg0cw84cog840k84cwggscwg884004kgk&username=user%40example.com&password=Secr3t

Token answer:

    { "access_token": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl",
      "refresh_token": "rt-7f3c2a10-0000-4000-8000-000000000001",
      "expires_in": 900, "token_type": "bearer" }

Expected:
- Received at 12:00:00, so the token is due for refresh from 12:14:55.
- The next Overkiz request is `GET https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI/setup` with
  `Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl` and no `Cookie`.

Refresh request at 12:15:00:

    grant_type=refresh_token&client_id=0d8e920c-...&client_secret=12k73w...&refresh_token=rt-7f3c2a10-0000-4000-8000-000000000001

Answer:

    { "access_token": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0MiJ9.c2lnbmF0dXJlMg",
      "refresh_token": "rt-7f3c2a10-0000-4000-8000-000000000002", "expires_in": 900 }

Expected: both tokens are replaced, and the event listener is registered again.

Bad credentials: `{"message": "error.invalid.grant"}`. Expected: bad credentials and no retry.

Expired Bearer at Overkiz: `401 {"errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not authenticated"}`. Expected: a new
password grant, then one retry of the request.

Local token:

    GET  .../enduserAPI/config/1234-5678-9012/local/tokens/generate  → { "token": "9f8e7d6c5b4a39281706" }
    POST .../enduserAPI/config/1234-5678-9012/local/tokens
         { "label": "Homeswift", "token": "9f8e7d6c5b4a39281706", "scope": "devmode" }
                                                                     → { "requestId": "req-0000-0001" }
    GET  .../enduserAPI/config/1234-5678-9012/local/tokens/devmode
         → [ { "label": "Homeswift", "gatewayId": "1234-5678-9012", "uuid": "c0ffee00-0000-4000-8000-000000000001",
               "scope": "devmode", "gatewayCreationTime": 1767225600000, "expirationTime": 1798761600000 } ]
