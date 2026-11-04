# Ring: functional specification (clean room)

## 0. Provenance

| | |
|---|---|
| Source | https://github.com/dgreif/ring (monorepo), packages `packages/homebridge-ring` (the Homebridge plugin) and `packages/ring-client-api` (the cloud client it uses) |
| Commit | `2d1ebfd1ce28b141735f7fbf8682a8f2ea1a903b` (shallow clone, default branch) |
| Package names / versions | `homebridge-ring` 14.3.0, `ring-client-api` 14.3.0 (both by `dgreif`) |
| License | MIT, "Copyright (c) 2022 Dusty Greif" (same LICENSE file in the repository root and in both packages) |
| Notable third-party dependencies (not in the repository, behaviour described from their use only) | `@eneris/push-receiver` 4.4.0 (FCM push), `werift` 0.25.1 (WebRTC, SRTP, RTP), `@homebridge/camera-utils` 3.x (FFmpeg process, UDP "RTP splitter" sockets, SRTP option generation, return-audio transcoder), `json-bigint`, `undici`, `uuid`, `systeminformation` |

This document was written by the spec writer; it contains no source code. Identifiers that form the interface (JSON keys,
URLs, header names, message types, enum strings) are quoted because a compatible implementation needs them exactly.
Everything else is paraphrase.

Words used below: **hub device** = a device reported by a location's alarm base station or Smart Lighting bridge over the
location WebSocket (identified by a string `zid`); **REST device** = camera, chime or intercom from the `ring_devices`
REST endpoint (identified by a numeric `id`).

---

## 1. Configuration interface

Platform name (the `platform` value in config.json and the plugin alias): **`Ring`**. Singular (one block). The block has
no required key except `refreshToken`.

| JSON key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Must be `"Ring"`. |
| `name` | string | — | Display name only; not used by the logic. |
| `refreshToken` | string | required | Ring credential. Either the plugin's own wrapper token (base64 of a JSON object, see 2.2) or a raw Ring OAuth refresh token (legacy). If absent, the plugin logs a warning that it is not configured and does nothing else. **Rotated by the plugin** (see 1.2). Secret. |
| `alarmOnEntryDelay` | bool | false | When true, the alarm's `entry-delay` state counts as "alarm triggered" for the Security System current state. |
| `hideLightGroups` | bool | false | Do not expose Smart Lighting light groups (deviceType `group.light-group.beams`). |
| `hideDoorbellSwitch` | bool | false | Do not add the Stateless Programmable Switch service on doorbell cameras (the Doorbell service stays). |
| `hideCameraLight` | bool | false | Do not add the Lightbulb service on cameras that have a light. |
| `hideCameraMotionSensor` | bool | false | Do not add the Motion Sensor service on cameras. |
| `hideCameraSirenSwitch` | bool | false | Do not add the camera "Siren" switch. |
| `hideInHomeDoorbellSwitch` | bool | false | Do not add the "In-Home Doorbell" switch on doorbells with a mechanical/digital chime. |
| `hideAlarmSirenSwitch` | bool | false | Do not add the "Siren" switch on the security panel accessory. |
| `showPanicButtons` | bool | false | Add a "Panic Buttons" accessory per location that has a security panel, with "Burglar Alarm" and "Fire Alarm" switches that dispatch real emergency signals. |
| `nightModeBypassFor` | string, `"all"` or `"some"` | unset | When set, the Security System accepts Night; Night arms the alarm in the given Ring mode (`all` = Away, `some` = Home) while bypassing every open contact sensor. Any other value means "no Night mode". |
| `avoidSnapshotBatteryDrain` | bool | false | For cameras operating on battery, consider a snapshot valid for 10 minutes instead of 10 seconds (fewer forced snapshots). |
| `beamDurationSeconds` | integer 1…32767 | unset | How long a Smart Lighting light stays on when turned on from HomeKit. Clamped to 32767. Unset: individual lights send no duration (Ring reuses the last duration set in the Ring app); light groups use 60 s. |
| `debug` | bool | false | Enables the client's debug log lines (including FFmpeg output). |
| `disableLogs` | bool | false | Suppresses all of the client library's info/error log lines (the platform's own few warnings still print). |
| `cameraStatusPollingSeconds` | integer ≥ 0 | 20 | Interval for re-fetching camera/chime/intercom state (`ring_devices`). 0 disables polling **and** on-demand refreshes entirely. |
| `locationModePollingSeconds` | integer ≥ 0 | 20 | Interval for re-fetching the location mode, for locations without an alarm base station. 0 disables polling **and hides the Location Mode accessory**. |
| `hideDeviceIds` | string[] | [] | Accessories to hide. **Matched against the accessory's HomeKit UUID** (the value derived from the identity seed, see 4.1 — the UUID that the plugin logs at start), not against the raw Ring id. |
| `locationIds` | string[] | all | Only these Ring `location_id`s are used. Present but empty means no location at all (an error is logged saying so). |
| `onlyDeviceTypes` | string[] | all | If non-empty, only accessories whose "device type" string is listed are exposed (see 4.1 for each accessory's device type). |
| `ffmpegPath` | string | bundled FFmpeg | Path (or bare `ffmpeg`) of the FFmpeg binary. |
| `controlCenterDisplayName` | string | `"homebridge-ring"` | Not in the schema but accepted (the block is spread over the defaults). Sent to Ring as the session's `device_model`, which is the name Ring shows for this client in the Ring app's Control Center / authorized devices list. |
| `systemId` | string | — | Accepted by the client but **always overridden** by the plugin with the value from `.ring.json` (see 1.3). |
| `externalPorts` | object `{start,end}` | — | Declared in the client's options type but unused. |

Accessory Settings: the original has none per device beyond `hideDeviceIds`. A Homeswift port should read all of the
above keys as they are.

The schema has a custom UI ("Generate New Refresh Token"); see 2.7 for what it does.

### 1.1 Environment

`RING_DEBUG=true` (environment variable) makes the plugin prefix every identity seed, accessory name and service name
with `TEST ` (a test mode that produces different UUIDs). Normal installations never set it.

### 1.2 Persisting a rotated refresh token

Every successful OAuth token request (start-up and each hourly refresh) yields a new Ring refresh token. The client
re-wraps it (2.2) into a new wrapper string and emits an "updated" event carrying the old and new wrapper strings. The
plugin, on each such event **where an old token existed**, reads the Homebridge `config.json` as text, replaces every
occurrence of the old token string with the new one, and writes the file back only if the text changed. It does not
re-parse JSON; it is a plain textual substitution. The in-memory client keeps working with the new token either way.

The same "updated" event fires when FCM push credentials are first created or change (they are stored inside the
wrapper, 2.2).

Consequence for a drop-in: the token in config.json changes on (roughly) every start and every hour; a user's pasted
token is valid exactly once at Ring (Ring refresh tokens are single use after rotation), so the new value must be
persisted durably before or right after it is used.

### 1.3 `.ring.json`

In the Homebridge storage directory the plugin keeps `.ring.json`: a JSON object `{"systemId": "<64 hex chars>"}`. The
systemId is created once as the SHA-256 hex digest of 32 random bytes and reused afterwards (a missing or unreadable file
is recreated). It feeds the hardware id (2.3) only when the refresh token does not already carry one.

---

## 2. Authentication

### 2.1 Common HTTP behaviour

- All JSON requests carry `Content-Type: application/json` and `Accept: application/json`; bodies are JSON.
- Authenticated requests additionally carry `authorization: Bearer <access_token>`, `hardware_id: <hardware id>` and
  `User-Agent: android:com.ringapp`.
- Default timeout 20 s per attempt.
- **Transport failures** (no HTTP response at all: DNS, connection reset, timeout) are retried after 5 s, indefinitely;
  from the first retry on, each failure is logged with the URL. Requests flagged "allow no response" (the snapshot
  request) are not retried.
- Two response headers are captured on JSON-object and binary responses: `date` (as epoch ms, "response timestamp") and
  `x-time-millis` (a number, "time millis"). The snapshot logic needs both (6.6).
- HTTP keep-alive pool of 6 connections, 115 s keep-alive.

Retry rules for authenticated requests (after the transport retry):

| Status | Behaviour |
|---|---|
| 401 | Discard the cached access token, obtain a new one (refresh grant), retry the request. |
| 504 | Wait 5 s, retry. |
| 404 whose JSON body has an `errors` array containing known codes | Map codes: 7050 `NO_ASSET`, 7019 `ASSET_OFFLINE`, 7061 `ASSET_CELL_BACKUP`, 7062 `UPDATING`, 7063 `MAINTENANCE`; log them, wait 20 s, retry (indefinitely). Unknown codes are logged and fall through. |
| 404 on a `https://api.ring.com/clients_api/` URL whose body `error` text contains this client's hardware id (Ring's text is "Session not found for <hardware_id>") | Create a session (2.5) unless one is already being created, then retry. |
| other 404 on `clients_api` | Fail with "not found" and the body. |
| any other error status | Log URL, status and body; fail. |

### 2.2 The refresh token wrapper

The string in `refreshToken` is normally base64 (standard alphabet, padded) of a compact JSON object:

| Key | Meaning |
|---|---|
| `rt` | The current Ring OAuth refresh token (required). |
| `hid` | The hardware id used when the token was created; reused forever so Ring sees the same client. |
| `pnc` | Push notification (FCM) credentials as stored by the push library (an object; the client only checks that it has a `config` member and reads `fcm.token`). Opaque to everything else. |

Parsing: base64-decode (as ASCII), JSON-parse; if that fails or there is no `rt`, the whole string is taken as a raw
Ring refresh token (legacy) with no `hid`/`pnc`. Writing: after each token response the wrapper is rebuilt as the
previous fields with `rt` replaced by the new refresh token and `hid` set to the hardware id in use, then
JSON-serialised and base64-encoded. A compatible implementation should keep unknown members it does not understand so a
user can move back.

### 2.3 Hardware id

- If the wrapper has `hid`, use it.
- Else, if a systemId is available (always, in the plugin: `.ring.json`), the hardware id is a **UUID version 5** of the
  systemId string in the namespace `e53ffdc0-e91d-4ce1-bec2-df939d94739d` (lowercase, dashed).
- Else (library use without systemId) it is a UUIDv5 of the OS's system UUID in that namespace, falling back to a random
  UUIDv4 if the system UUID cannot be read within 5 s or is the placeholder `-`.

The hardware id is sent as a header on every request, in the token request, in the session body, and identifies this
client in Ring's Control Center.

### 2.4 OAuth token request

`POST https://oauth.ring.com/oauth/token`, JSON body and headers:

- Body always has `client_id: "ring_official_android"` and `scope: "client"`, plus the grant:
  - refresh: `grant_type: "refresh_token"`, `refresh_token: <rt>` — used whenever an `rt` exists and no 2FA code is being
    submitted;
  - password (only for the token-generation flow, 2.7): `grant_type: "password"`, `username: <email>`,
    `password: <password>`.
- Headers: `2fa-support: true`, `2fa-code: <code or empty string>`, `hardware_id: <hardware id>`,
  `User-Agent: android:com.ringapp` (plus the JSON headers). No `authorization`.
- Success body: `access_token`, `expires_in` (seconds), `refresh_token`, `scope` (`client`), `token_type` (`Bearer`).
- The access token is cached and reused until 60 s before `expires_in` (3600 assumed when missing), after which the next
  request fetches a new one with the refresh grant (which rotates `rt`, 1.2).

Errors:

- Refresh grant fails (any error after transport retries): the client forgets the token and tries again without one;
  with no email/password configured this fails at once with "refresh token is not valid; generate a new one" (pointing at
  the project's Refresh Tokens wiki page). No further automatic retries at that level; the next API call will try again.
- HTTP **412**: the account needs a 2FA code. The body may carry `tsv_state` (`sms`, `email` or `totp`), `phone` (masked
  destination) and `next_time_in_secs`. The prompt shown is "enter the code from your authenticator app" for `totp`, or
  "enter the code sent to <phone> via <tsv_state>", or a generic "code sent to your text/email" when the body has no
  `tsv_state`.
- HTTP **400** whose `error` string starts with `Verification Code`: the submitted code was wrong; prompt again.
- Body `error_description` equal to `too many requests from dependency service`: Ring's 2FA rate limit (the plugin's
  message says 10 codes per 10 minutes; wait 10 minutes).
- Anything else: "Failed to fetch oauth token from Ring; verify the refresh token (or email/password)" with the error
  text (the body's `error` string or `HTTP <status>`).

### 2.5 Session

`POST https://api.ring.com/clients_api/session` with Bearer token and body
`{"device": {"hardware_id": <hid>, "metadata": {"api_version": 11, "device_model": <controlCenterDisplayName>}, "os": "android"}}`.
The response is the user profile (`{"profile": {...}}`; fields include `id`, `email`, names, `hardware_id`, `features`,
`tfa_enabled`…; nothing of it is used beyond signalling that a session exists).

When it is created: **lazily**. Requests are made without a session; the first `clients_api` request that comes back
404 "Session not found for <hardware_id>" triggers creation, and the request is retried. Once created, the session is
re-created every 12 hours (to keep it alive outside the US, where Ring is believed to drop it after about a day, which
silently breaks push notifications). Session request errors: 401 → refresh the access token and retry; 429 → wait
`Retry-After` seconds + 1 (200 s when the header is missing or not a number), log, retry; others fail.

Every time a session is created the client: re-subscribes every camera to ding and motion events (6.2) (throttled to
once per second), and re-sends the push token registration (2.6).

### 2.6 Push registration with Ring

`PATCH https://api.ring.com/clients_api/device` with
`{"device": {"metadata": {"api_version": 11, "device_model": <controlCenterDisplayName>, "pn_dict_version": "2.0.0", "pn_service": "fcm"}, "os": "android", "push_notification_token": <FCM token>}}`.
Sent whenever the FCM token is new/changed, at start-up if stored credentials are reused unchanged, and again after every
session creation. Errors are logged only.

### 2.7 Obtaining the first token (custom UI)

The plugin's settings page has two server calls. "Send code": build a client from email + password (+ the
`.ring.json` systemId and the `homebridge-ring` display name) and request a token with the password grant; if that
succeeds without 2FA return the wrapper token; if it fails with a 2FA prompt, return the prompt text. "Token": with
email, password and code, request again with the password grant and the `2fa-code` header set, and return the wrapper
token; a failure says "check the code and try again". The email and password are never stored. There is also a
command-line equivalent in the client package doing the same steps interactively. In Homeswift this maps naturally to a
Setup `accountAuthorization` with an email/password step and a code step.

---

## 3. Cloud API

Base URLs:

| Name | Base |
|---|---|
| clients | `https://api.ring.com/clients_api/` |
| devices | `https://api.ring.com/devices/v1/` |
| commands | `https://api.ring.com/commands/v1/` |
| app | `https://prd-api-us.prd.rings.solutions/api/v1/` |

### 3.1 Endpoints used by the plugin

| Purpose | Method and URL | Body / notes |
|---|---|---|
| Locations | GET devices `locations` | Response `{"user_locations": [UserLocation…]}`; missing list → fatal error "account has no locations". |
| All REST devices | GET clients `ring_devices` | Response object with arrays `doorbots`, `stickup_cams`, `authorized_doorbots` (shared doorbells), `chimes`, `base_stations`, `beams_bridges`, `other`. `other` is split by `kind`: `onvif_camera` (treated as a camera), `intercom_handset_audio` / `intercom_handset_video` (intercoms), `third_party_gdo` (ignored), anything else ignored. |
| Subscribe to dings | POST clients `doorbots/{id}/subscribe` | No body. Cameras: at start and after every session creation. Intercoms: only at start, and only if the intercom's `subscribed` is false. (`unsubscribe` exists, unused.) |
| Subscribe to motions | POST clients `doorbots/{id}/motions_subscribe` | Cameras only, same timing. (`motions_unsubscribe` unused.) |
| Camera light | PUT clients `doorbots/{id}/floodlight_light_on` or `…/floodlight_light_off` | No body. On success the local state `led_status` is set to `on`/`off` immediately. |
| Camera siren | PUT clients `doorbots/{id}/siren_on` or `…/siren_off` | No body. On success local `siren_status.seconds_remaining` is set to 1 (on) or 0 (off). |
| Camera settings (in-home chime) | PUT clients `doorbots/{id}/` (trailing slash) | `{"doorbot": {"settings": {"chime_settings": {"enable": <bool>}}}}`, then a state refresh is requested. |
| Snapshot | GET `https://app-snaps.ring.com/snapshots/next/{id}` with query | See 6.6. `accept: image/jpeg`, binary response. |
| Live-view signalling ticket | POST app `clap/ticket/request/signalsocket` | No body; response `{"ticket": "<string>", …}`. |
| Location hub ticket | GET app `clap/tickets?locationID={locationId}&enableExtendedEmergencyCellUsage=true&requestedTransport=ws` | Response `{"assets": [TicketAsset…], "host": "<hostname>", "ticket": "<string>", "subscriptionTopics": [...]}`. |
| Location mode (read) | GET app `mode/location/{locationId}` | Response `{"mode": "home"|"away"|"disarmed"|"disabled"|"unset", "readOnly": bool, "lastUpdateTimeMS": n, "securityStatus": {...}, "notYetParticipatingInMode": [...]}` |
| Location mode (write) | POST app `mode/location/{locationId}` | `{"mode": "home"|"away"|"disarmed"}`; response same shape as read. |
| Panic dispatch | POST app `rs/monitoring/accounts/{locationId}/assets/{baseStationAssetUuid}/userAlarm` | `{"alarmSessionUuid": <random UUIDv4>, "currentTsMs": <now ms>, "eventOccurredTime": <now ms>, "signalType": "user-verified-burglar-xa"|"user-verified-fire-xa"}`. The asset is the location ticket's asset whose `kind` is `base_station_v1`; without one, fail "cannot dispatch panic events without an alarm base station". |
| Light group on/off | POST `https://api.ring.com/groups/v1/locations/{locationId}/groups/{groupId}/devices` | `{"lights_on": {"duration_seconds": <n, default 60>, "enabled": <bool>}}` |
| Chime play | POST clients `chimes/{id}/play_sound` | `{"kind": "ding"|"motion"}` |
| Chime snooze | POST clients `chimes/{id}/do_not_disturb` | `{"time": <minutes>}` to snooze (plugin uses 1440); the same POST **without a body** clears it. Then a refresh is requested. |
| Chime volume | PUT clients `chimes/{id}/` (trailing slash) | `{"chime": {"settings": {"volume": <0…11>}}}`, then a refresh. Values outside 0…11 are rejected locally. |
| Chime nightlight | PATCH devices `devices/{id}/settings` | `{"night_light_settings": {"light_sensor_enabled": <bool>}}`, then a refresh. |
| Intercom unlock | PUT commands `devices/{id}/device_rpc` | `{"command_name": "device_rpc", "request": {"jsonrpc": "2.0", "method": "unlock_door", "params": {"door_id": 0, "user_id": 0}}}` |
| Session, push token | see 2.5, 2.6 | |

Endpoints present in the client but not used by the plugin (useful context, not required): camera health
`doorbots/{id}/health`, snapshot by uuid `clients_api/snapshots/uuid?uuid=`, events and history, recordings, video search,
device settings GET/PATCH on devices `devices/{id}/settings`, Amazon Key lock associations, location mode settings and
sharing, monitoring status, ringtones, an HTTP live-view alternative (`https://api.ring.com/integrations/v1/liveview/start|end|options`).

### 3.2 Shapes that matter

UserLocation: `location_id` (string, UUID-like), `name`, `address{…}`, `geo_coordinates`, `owner_id`, timestamps.

Camera (from `doorbots`, `stickup_cams`, `authorized_doorbots`, ONVIF in `other`): `id` (number), `description` (the
name), `device_id` (hardware id/MAC-like string, used as serial), `kind` (model code, table 4.3), `location_id`,
`alerts.connection` (`online`/`offline`), `alerts.battery` (`low`…), `battery_life` and optional `battery_life_2`
(number, numeric string, or null), `external_connection` (bool), `led_status` (`on`/`off`, present only if the camera has a
light), `siren_status` (`{seconds_remaining: n, …}`, present only if it has a siren), `settings.chime_settings`
(`{type: 0 mechanical | 1 digital | 2 none, enable: bool, duration}`), `settings.power_mode` (`battery`/`wired`),
`settings.motion_detection_enabled` (false when Modes or "Record Motion" disable it), `settings.live_view_disabled`,
`settings.sheila_settings.local_storage_enabled` (true for Ring Edge), `health{battery_percentage, battery_present,
second_battery_percentage, …}`, `subscribed`, `subscribed_motions`; ONVIF cameras add
`metadata.third_party_manufacturer` and `metadata.third_party_model`.

Chime: `id`, `description`, `device_id`, `kind` (`chime`, `chime_pro`, `chime_v2`, `chime_pro_v2`), `location_id`,
`settings.volume` (0…11), `settings.night_light_settings.light_sensor_enabled` (object present only on models with a
nightlight), `do_not_disturb.seconds_left`, `alerts`.

Intercom: `id`, `description`, `device_id`, `kind`, `location_id`, `battery_life` (string), `subscribed`, `alerts.connection`.

Base station / beams bridge: only `location_id` is used, to decide which locations have hubs (either kind) and which
have an alarm base station (`base_stations` only).

TicketAsset: `uuid`, `kind` (`base_station_v1`, `beams_bridge_v1`, others), `doorbotId`, `onBattery`, `status`. Only
assets whose `kind` starts with `base_station` or `beams_bridge` are "supported" (WebSocket capable).

### 3.3 The location WebSocket (alarm hub / lighting bridge)

The original names it "socket.io", but it is a plain WebSocket carrying JSON text frames.

Opened only for locations that have a base station or a beams bridge (from `ring_devices`), lazily on the first need
(device discovery at start-up). Steps:

1. GET the location hub ticket (3.1). Keep the supported assets; none → error "no assets (alarm hubs or beam bridges)
   for location".
2. Connect to `wss://<host>/ws?authcode=<ticket>&ack=false` (no extra headers, no Bearer).
3. On open: mark connected, log "connected", and send a device list request (`DeviceInfoDocGetList`) to **every** asset
   from the ticket (including unsupported ones).

Outgoing frame envelope: `{"channel": "message", "msg": {"msg": <MessageType>, "datatype": <optional>, "dst": <asset uuid>, "body": <optional>, "seq": <n>}}`,
where `seq` is a per-location counter starting at 1 and incremented on every message.

Incoming frame envelope: `{"channel": <string>, "msg": {"msg": <MessageType>, "datatype": <DataType>, "src": <asset uuid>, "body": [ … ]}}`.

Message types: `DeviceInfoDocGetList`, `DeviceInfoSet`, `SessionInfo`, `RoomGetList`. Data types: `DeviceInfoDocType`,
`DeviceInfoSetType`, `SessionInfoType`, `RoomListV2Type`, `HubDisconnectionEventType`.

Handling:

- **Device list**: every incoming message whose `msg` is `DeviceInfoDocGetList` (whatever the channel) is folded into the
  location's device inventory: each body element is a document `{"general": {"v2": {…}}, "device": {"v1": {…}}}`,
  flattened by merging `general.v2` then `device.v1` (the latter wins on clashes). A `zid` already known updates that
  device (shallow merge); an unknown `zid` adds a device bound to the message's `src` asset. The message's `src` is
  recorded as "list received". The inventory is considered ready only once a list has been received from **every
  supported asset**; the start-up discovery waits for that (no timeout).
- **Data updates**: messages on channel `DataUpdate` with datatype `DeviceInfoDocType` and a body: each element is
  flattened the same way and shallow-merged into the device with that `zid` (fields absent from the update keep their
  previous values).
- **SessionInfo** (channel `DataUpdate`, `msg` `SessionInfo`): body is a list of `{assetUuid, connectionStatus
  ("online"|"cell-backup"|"unknown"), doorbotId, kind, sessionId}`. For a known asset going not-online, log once that it
  is offline or on cellular backup and remember it; when it comes back online, log that and re-request its device list.
- **HubDisconnectionEventType** (any `msg`): reconnect.
- Unparseable frames: log an error with the raw text.
- **Reconnect** (also on socket `error` and `close`): unless already reconnecting, mark disconnected, close the socket,
  wait 1 s, fetch a **new ticket** and connect again (clearing the "lists received" and "offline" bookkeeping). A failed
  connect leads to another reconnect (so it keeps trying every ~1 s plus ticket latency). Stops only on shutdown.

Writing to a hub device (`DeviceInfoSet`): send to the device's asset (`dst` = the asset uuid the device was listed by)
with `datatype: "DeviceInfoSetType"` and body `[{"zid": <zid>, …payload}]`. Two payload forms:

- settings: `"device": {"v1": {<field>: <value>, …}}` — e.g. `{"on": true}`, `{"level": 0.42}`, `{"brightness": 0.5}`,
  `{"volume": 0.3}`, `{"mode": "heat"}`, `{"setPoint": 21.5}`, `{"basicValue": 255}`;
- commands: `"command": {"v1": [{"commandType": <string>, "data": {…}}]}`.

Commands used: `security-panel.switch-mode` (`{"mode": "all"|"some"|"none", "bypass": [zids…]}` — `bypass` omitted when
not bypassing), `security-panel.sound-siren`, `security-panel.silence-siren`, `lock.lock`, `lock.unlock`, `valve.open`,
`valve.close`, `light-mode.set` (`{"lightMode": "on", "duration": <s, omitted if unset>}` or `{"lightMode": "default"}`).

Alarm mode change semantics: send `security-panel.switch-mode` to the security panel, then wait for the panel's **next**
data change; if its `mode` is not the requested one, fail with "failed to set alarm mode; sensors may require bypass,
which can only be done in the Ring app". (The wait has no timeout in the original.)

Volume writes for hub devices are only allowed for deviceTypes `hub.redsky` and `security-keypad`, in 0…1, else the
write fails locally (logged).

### 3.4 Hub device data (flattened)

Fields used: `zid`, `name`, `deviceType` (table 4.2), `categoryId` (number: 1 Outlets, 2 Lights, 5 Sensors, 7 Appliances,
10 Locks, 11 Thermostats, 12 Cameras, 15 Alarms, 17 Fans, 22 Security, 29 Unknown, 30 SensorsMotion, 31 Controller,
32 RangeExtenders, 33 Keypads, 34 Sirens, 35 PanicButtons, 37 WaterValves), `manufacturerName`, `serialNumber`,
`batteryLevel` (0…100), `batteryStatus` (`full`, `charged`, `ok`, `low`, `none`, `charging`), `batteryBackup`
(`charged`, `charging`, `inUse`), `acStatus` (`ok`, `error`), `tamperStatus` (`ok`, `tamper`), `faulted` (bool), `status`
(`enabled`/`disabled`), `locked` (`locked`, `unlocked`, `jammed`, `unknown`), `volume` (0…1), `brightness` (0…1),
`mode` (alarm: `all`/`some`/`none`; thermostat: `heat`/`cool`/`off`/`aux`), `alarmInfo` (`{state, faultedDevices,
timestamp, uuid}`; `state` one of `burglar-alarm`, `entry-delay`, `fire-alarm`, `co-alarm`, `panic`,
`user-verified-burglar-alarm`, `user-verified-co-or-fire-alarm`, `burglar-accelerated-alarm`, `fire-accelerated-alarm`;
absent or null when no alarm), `siren` (`{state: on|off}`), `alarmStatus` (`active`/`inactive`), `smoke`/`co`
(`{alarmStatus}`), `components` (`{"alarm.smoke": {alarmStatus}, "alarm.co": {alarmStatus}}` on Kidde detectors),
`flood`/`freeze` (`{faulted}`), `motionStatus` (`clear`/`faulted`), `motionSensorEnabled`, `groupId`, `on`, `level`
(0…1), `celsius`, `setPoint`, `setPointMin`, `setPointMax`, `parentZid` (component devices, e.g. a thermostat's
temperature sensor), `basicValue` (0 / 255), `valveState` (`open`/`closed`), `transitionDelayEndTimestamp`, `tags`.

### 3.5 Polling

- **REST devices**: if `cameraStatusPollingSeconds` > 0 and there is at least one camera, chime or intercom, fetch
  `ring_devices` at start, then again N seconds after each response arrives (a fixed delay after the previous result, not a
  fixed rate). Additionally a "refresh requested" event (raised when HomeKit reads certain characteristics, and after
  chime/camera settings writes) triggers a fetch; triggers are throttled to one per 500 ms and a newer fetch supersedes an
  in-flight one. Each result replaces the whole data object of every known camera/chime/intercom by `id` (devices that
  appear later are ignored; devices that disappear just stop updating). A failed fetch is ignored (and still re-arms the
  N-second timer).
- **Location mode**: for locations **without an alarm base station** and with `locationModePollingSeconds` > 0, fetch the
  mode at start, then N seconds after the last mode was received or requested. (Also fetched on HomeKit reads, 4.6.)
- Hub devices are not polled; they update live over the WebSocket.

### 3.6 Push notifications (FCM)

Ding (button press) and motion events, and intercom dings/unlocks, arrive **only** by push; there is no polling fallback.
Without push the doorbell and motion characteristics never fire.

What the client does (the protocol itself lives in the third-party push library and could not be read here; see 10):

- It acts as an FCM client of Ring's Android app Firebase project: API key `AIzaSyCv-hdFBmmdBBJadNy-TFwB-xN_H5m3Bk8`,
  project id `ring-17770`, sender id `876313859327`, app id `1:876313859327:android:e10ec6ddb3c81f39`. (These are the
  public identifiers embedded in Ring's Android app.)
- Stored credentials (wrapper `pnc`, 2.2) are reused if present and complete; otherwise the library registers a new FCM
  client and reports new credentials, which the client stores in the wrapper (raising the token-updated event, 1.2) and
  registers with Ring (2.6).
- The library keeps a persistent connection to Google's mobile push service (the client's error hint names
  `mtalk.google.com`, TCP port 5228); on disconnect it reconnects by itself; repeated failure is logged with a hint to
  check firewalls and DNS ad-blocking.
- Each received message is a map of string keys to string values. Each value is JSON-parsed **with big integers kept as
  strings** (ding ids exceed 2^53); values that are not JSON are kept as strings.
- Messages received in the first 2 s after connecting are ignored (likely redelivered duplicates; no persistent ids
  are stored).
- Routing:
  - "v2" notifications have a top-level `android_config`. Device id = `data.device.id`; the notification is handed to the
    camera or intercom with that id. Known categories (`android_config.category`): `com.ring.pn.live-event.ding`
    (doorbell press), `com.ring.pn.live-event.motion` (motion), `com.ring.pn.live-event.intercom` (intercom ding); other
    categories are debug-logged.
  - "v1"/alarm notifications have `data.gcmData.alarm_meta`; device = `data.gcmData.alarm_meta.device_zid`, handed to
    the camera/intercom with that id (in practice only intercom unlock uses it: `data.gcmData.action` =
    `com.ring.push.INTERCOM_UNLOCK_FROM_APP`). Other alarm actions seen: `com.ring.push.HANDLE_NEW_SECURITY_PANEL_MODE_NONE_NOTICE`,
    `…MODE_SOME_NOTICE`, `com.ring.push.HANDLE_NEW_USER_SOUND_SIREN`, `com.ring.push.HANDLE_NEW_NON_ALARM_SIREN_SILENCED` (unused).
  - Anything else is debug-logged and dropped.
- Device ids may arrive as numbers or (if huge) strings; match on the string form.

Camera handling of a v2 notification (only if it has `data.event.ding`): put it in the camera's list of **active
notifications**, replacing any earlier entry with the same `data.event.ding.id`, emit it as a "new notification", and
remove it from the active list 65 s later ("dings last about a minute"). Derived signals:

- doorbell pressed = each new notification whose category is the ding category;
- motion detected = true while any active notification has the motion category, false otherwise (distinct changes only);
- latest snapshot uuid = `img.snapshot_uuid` of the most recent active notification.

Intercom: category intercom ding → "ding"; gcmData action intercom unlock → "unlocked".

---

## 4. Device model and HomeKit mapping

### 4.1 Identity, inventory and lifecycle

At start the plugin connects, lists locations (filtered by `locationIds`), fetches REST devices once, and for each
location gets the hub devices (if the location has hubs; else none). For each location it builds the accessory list in
this order: hub devices (WebSocket inventory order), cameras, chimes, intercoms, then optional extras.

| Accessory | Identity seed (string) | Name | "Device type" (for `onlyDeviceTypes`, logs) | Exposed as |
|---|---|---|---|---|
| Camera / doorbell (incl. ONVIF via Ring Edge) | `<camera id>` + `camera` (e.g. `1001camera`) | `description` | camera `kind` | **external** accessory, category Camera (17) — even doorbells |
| Chime | `<chime id>` | `description` | chime `kind` | bridged |
| Intercom | `<intercom id>` | `description` | intercom `kind` | bridged |
| Hub device | `<zid>` | `name` | `deviceType` | bridged |
| Panic Buttons (if `showPanicButtons` and the location has a security panel) | `<security panel zid>` + `panic` | `Panic Buttons` | `security-panel` | bridged |
| Location Mode (if `locationModePollingSeconds` > 0 and the location supports mode switching, 4.6) | `<location_id>` + `mode` | `<location name> Mode` | `location.mode` | bridged |

The HomeKit accessory UUID is the Homebridge/HAP-NodeJS name-based UUID of the seed: SHA-1 of the UTF-8 seed, hex
digest; the UUID is formed from hex digits 0–7, a dash, 8–11, a dash, the literal `4` followed by digits 12–14, a dash,
digit 15 reduced to its low two bits and OR'ed with 8 (one hex digit `8`–`b`) followed by digits 16–18, a dash, and digits
19–30 (lowercase). Homeswift's own Homebridge-compatible id derivation should already do this; a ported plugin should use
the same seeds (with the platform prefix convention Homeswift requires, if any, applied consistently so ids stay stable
for users of the port). `hideDeviceIds` compares against these UUID strings. Bridged accessories in the original are
created with category Security System (11); this does not matter behind a bridge.

Filtering (an accessory is skipped and logged "Hidden accessory <uuid> <deviceType> <name>" when any holds): no mapping
for its device type; light group with `hideLightGroups`; UUID in `hideDeviceIds`; `onlyDeviceTypes` set and the device
type not in it. The log line is suppressed for the infrastructure types `adapter.ringnet`, `adapter.zigbee`,
`access-code.vault`, `access-code`, `adapter.zwave`, `range-extender.zwave`, `device.beams`, `security-panic`.

Cached accessories that are not produced in this run are removed (stale). A camera that exists in the cache as a
bridged accessory (very old plugin versions) is removed from the bridge with a warning that it must be paired again as
its own accessory.

Persistent per-accessory context (Homebridge's cached `context`): the security panel stores `targetingNightMode` (bool);
"brightness only" devices store `brightness` (0…100). A port needs equivalent persisted state.

Services are created on demand and any cached service not created in this run is pruned (except camera RTP stream
management). Unless stated, a service's display name is the accessory name and it has **no subtype**.

### 4.2 Hub device type → accessory kind

Any hub device whose `status` is `disabled` is not exposed. Then by `deviceType`:

| deviceType | Kind |
|---|---|
| `sensor.contact`, `sensor.zone` (retrofit zone), `sensor.tilt`, `sensor.glassbreak` | Contact sensor |
| `sensor.motion` | Motion sensor |
| `sensor.flood-freeze` | Flood/freeze sensor |
| `sensor.freeze` | Freeze sensor |
| `security-panel` | Security panel |
| `hub.redsky` (base station), `hub.kili` (base station pro), `security-keypad` | Brightness-only (+ volume, battery) |
| `alarm.smoke` | Smoke alarm |
| `alarm.co` | CO alarm |
| `listener.smoke-co`, `comp.bluejay.sensor_bluejay_wsc` (Kidde) | Smoke + CO listener |
| `motion-sensor.beams`, `switch.beams`, `switch.multilevel.beams`, `switch.transformer.beams`, `group.light-group.beams` | Smart Lighting ("Beam") |
| `switch.multilevel` | Fan if `categoryId` = 17, else Multi-level switch (dimmer) |
| `switch.multilevel.bulb` | Multi-level switch |
| `switch` | Outlet if `categoryId` = 1, else Switch |
| `sensor.temperature` | Temperature sensor |
| `sensor.water` | Water sensor |
| `temperature-control.thermostat` | Thermostat |
| `valve.water` | Valve (as a switch) |
| `unknown.zwave` | Unknown Z-Wave switch |
| `lock` or any type starting with `lock.` | Lock |
| `sensor` (generic) | Motion sensor if the name contains "motion" (case-insensitive), else Contact sensor |
| anything else (adapters, extenders, access codes, `device.beams`, `security-panic`, `bridge.flatline`, `range-extender.zwave`, …) | not exposed |

### 4.3 HomeKit characteristic values used

SecuritySystemCurrentState: 0 stay, 1 away, 2 night, 3 disarmed, 4 triggered. SecuritySystemTargetState: 0 stay, 1 away,
2 night, 3 disarm. LockCurrentState: 0 unsecured, 1 secured, 2 jammed, 3 unknown. LockTargetState: 0 unsecured, 1 secured.
ContactSensorState: 0 detected (closed), 1 not detected (open). StatusLowBattery: 0 normal, 1 low. ChargingState:
0 not charging, 1 charging, 2 not chargeable. StatusTampered: 0 / 1. SmokeDetected, CarbonMonoxideDetected, LeakDetected,
OccupancyDetected: 0 / 1. ProgrammableSwitchEvent: 0 single press. Heating/cooling: 0 off, 1 heat, 2 cool (3 auto
excluded). TemperatureDisplayUnits: 0 °C, 1 °F.

Camera model names by `kind` (used in the Model string, 4.5): doorbot/doorbell/doorbell_v3 "Doorbell"; doorbell_v4,
doorbell_v5 "Doorbell 2"; doorbell_oyster "Doorbell 4"; doorbell_portal "Door View Cam"; doorbell_scallop "Doorbell 3
Plus"; doorbell_scallop_lite "Doorbell 3"; doorbell_graham_cracker "Doorbell Wired"; lpd_v1, lpd_v2 "Doorbell Pro";
lpd_v4 "Doorbell Pro 2"; jbox_v1 "Doorbell Elite"; stickup_cam, stickup_cam_v3, stickup_cam_elite, stickup_cam_lunar,
cocoa_camera "Stick Up Cam"; stickup_cam_longfin "Spotlight Cam Pro"; spotlightw_v2, hp_cam_v2, stickup_cam_v4
"Spotlight Cam"; hp_cam_v1, floodlight_v1, floodlight_v2 "Floodlight Cam"; floodlight_pro "Floodlight Pro";
cocoa_doorbell "Doorbell Gen 2"; cocoa_doorbell_v2 "Battery Doorbell Plus"; cocoa_doorbell_v3 "Battery Doorbell Pro";
cocoa_floodlight "Floodlight Cam Plus"; cocoa_spotlight "Spotlight Cam Plus"; stickup_cam_mini "Indoor Cam";
onvif_camera "ONVIF Camera"; unknown kinds "Unknown Model". Chime models: chime "Chime", chime_pro "Chime Pro",
chime_v2 "Chime v2", chime_pro_v2 "Chime Pro v2", other "Chime".

### 4.4 Common parts of hub-device accessories

Every hub-device accessory except Panic Buttons gets:

- Accessory Information: Manufacturer = `manufacturerName` or "Ring"; Model = `deviceType`; Serial = `serialNumber` or
  "Unknown".
- If the initial data has a `volume` key: Speaker service with Mute (always false, read-only behaviour) and Volume
  (0…100 = `volume` × 100, 0 when missing; writes send `volume` = value / 100; see "level" rule below).
- If `batteryStatus` is not `none`: Battery service with
  - BatteryLevel: `batteryLevel` if present; else 100 for `full`/`charged`, 50 for `ok`/`charging`, 0 otherwise;
  - StatusLowBattery: low when that level ≤ 20;
  - ChargingState: charging if `batteryStatus` is `charging`/`charged`, or `batteryBackup` is `charged`/`charging`, or
    `acStatus` is `ok`; not charging if `batteryBackup` is `inUse` or `acStatus` is `error`; else not chargeable.
- Sensor services (contact, motion, leak, occupancy, smoke, CO, temperature) also carry StatusTampered (0 when
  `tamperStatus` is `ok`, else 1) and, if battery-powered as above, StatusLowBattery.

**Level rule** (Volume, Brightness, RotationSpeed): HomeKit writes are debounced 500 ms (only the last value in a burst is
sent); after a write the characteristic reports the written value until the device reports exactly that value, then
follows the device again.

**Write rule**: HomeKit writes are acknowledged immediately; the Ring call runs in the background and errors are only
logged (except where a revert is stated).

All characteristic values are pushed to HomeKit when the device data changes (distinct values only).

### 4.5 Accessories

**Contact sensor**: Contact Sensor service, ContactSensorState = not detected (open) when `faulted`, else detected. Plus
tamper/low battery.

**Motion sensor**: Motion Sensor service, MotionDetected = `faulted`. Plus tamper/low battery.

**Flood/freeze sensor**: Leak Sensor service named "<name> Flood Sensor" (LeakDetected = `flood.faulted`) and Occupancy
Sensor named "<name> Freeze Sensor" (OccupancyDetected = `freeze.faulted`; occupancy stands for "freezing"). Both with
tamper/low battery. Logs "<name> Detected Flooding" / "Detected Freezing" when each becomes true.

**Freeze sensor**: Occupancy Sensor, OccupancyDetected = `faulted`; logs when it becomes true.

**Water sensor**: Leak Sensor, LeakDetected = `faulted`; logs "Detected Water".

**Temperature sensor**: Temperature Sensor service, CurrentTemperature = `celsius`. Plus tamper/low battery.

**Smoke alarm**: Smoke Sensor, detected when `alarmStatus` = `active`. **CO alarm**: Carbon Monoxide Sensor, abnormal
when `alarmStatus` = `active`. **Smoke/CO listener and Kidde**: both services; smoke status from `smoke.alarmStatus`,
falling back to `components["alarm.smoke"].alarmStatus`; CO likewise with `co` / `components["alarm.co"]`. Each service
has tamper/low battery.

**Security panel** (one per location with an alarm):

- Security System service (primary).
- Current state: triggered (4) when `alarmInfo.state` is one of the alarm states — all of them when `alarmOnEntryDelay`,
  otherwise all except `entry-delay`; else equal to the target state below.
- Target state from `mode`: if Night is being targeted (persisted flag) and `mode` equals `nightModeBypassFor`, Night (2);
  otherwise the flag is cleared and `all` → Away (1), `some` → Stay (0), `none` or anything else → Disarm (3).
- Valid target values: Away, Stay, Disarm, plus Night only when `nightModeBypassFor` is `all` or `some`.
- Writing the target: set the persisted Night flag to (value is Night). Night with a valid `nightModeBypassFor` becomes
  Away (`all`) or Stay (`some`) **with bypass**; Night without it becomes Stay without bypass. With bypass, the zids of
  all hub devices of type `sensor.contact` that are currently `faulted` are passed as `bypass` and their names are added to
  the log line. Then Away → mode `all`, Disarm → `none`, else → `some` (3.3 semantics). Log "Arming (Away) <name>[ -
  Bypassing Sensors: …]", "Disarming <name>", "Arming (Home) <name>…". On failure, log the error and push the target
  state recomputed from the current data back to HomeKit (revert).
- Unless `hideAlarmSirenSwitch`: Switch service named "<name> Siren" (no subtype), On = `siren.state` = `on`; writing
  true sends `security-panel.sound-siren`, false `security-panel.silence-siren`.
- Plus the common parts (battery, volume if present).

**Panic Buttons** (security panel's data, extra accessory):

- Accessory Information: Manufacturer `manufacturerName` or "Ring"; Model "Panic Buttons for <location name>"; Serial "None".
- Switch subtype `Burglar`, name "Burglar Alarm" (Name and ConfiguredName characteristics also set to that). On = alarm
  state in {`burglar-alarm`, `user-verified-burglar-alarm`, `burglar-accelerated-alarm`}. Writing true: dispatch burglar
  (3.1), log "Burglar Alarm activated for <location>"; writing false: set alarm mode `none` (disarm), log "turned off".
- Switch subtype `Fire`, name "Fire Alarm", same pattern with {`fire-alarm`, `user-verified-co-or-fire-alarm`,
  `fire-accelerated-alarm`} and the fire signal.

**Brightness-only** (base station, base station pro, keypad): only if `brightness` is a number, a Lightbulb service
(primary) with On = `brightness` non-zero, and Brightness = `brightness` × 100 (0 when missing). Every reported non-zero
brightness is remembered in the persisted context. Writing Brightness stores it (if non-zero) and sends `brightness` =
value / 100; writing On true sends the remembered brightness (or 100), false sends 0. Log "Setting brightness of <name>
to <n>%". Plus common parts (volume, battery).

**Smart Lighting (Beam)**:

- Every type except `motion-sensor.beams`: Lightbulb service (primary) with On = `on`. Writing: log "Turning <name>
  On/Off". For a light group (`group.light-group.beams` with a `groupId`): the light group REST call (3.1) with enabled =
  value and duration = `beamDurationSeconds` (clamped to 32767) or 60. Otherwise the `light-mode.set` command: on →
  `lightMode: on` plus duration if configured; off → `lightMode: default` (returns the light to its automatic behaviour).
- `switch.multilevel.beams`: Brightness = `level` × 100; writes send `level` = value / 100 (level rule).
- If `motionStatus` is present and `motionSensorEnabled` is not false: Motion Sensor service, MotionDetected =
  `motionStatus` = `faulted`, plus tamper/low battery.

**Multi-level switch** (dimmers, bulbs): Lightbulb, On = `on` (write `on`); if the initial data has `level`, Brightness
= `level` × 100 (write `level` / 100, level rule). **Fan**: Fan service (original Fan, not Fanv2), On = `on`, and
RotationSpeed from `level` the same way. **Outlet**: Outlet service, On = `on` (write `on`), OutletInUse = `on`.
**Switch**: Switch service, On = `on`. **Unknown Z-Wave**: Switch, On = `basicValue` non-zero, write `basicValue` 255 / 0.
**Valve**: Switch service (not Valve), On = `valveState` = `open`; writes send `valve.open` / `valve.close`. All log
"Turning <name> On/Off" (fan speed "Setting speed of …", dimmer "Setting brightness of …").

**Lock**: Lock Mechanism service. Current: `unlocked` → 0, `locked` → 1, `jammed` → 2, else 3. Target: the last
requested state while a request is in flight, otherwise the current value. Writing: command `lock.lock` for Secured,
`lock.unlock` otherwise; the requested target is remembered unless it already equals the current state, and is
forgotten as soon as the current state equals it. (Quirk: the original treats an in-flight "unsecured" target (0) as
absent, so during an unlock the target simply mirrors current; jammed/unknown current values pass through to the target
as 2/3.)

**Thermostat**:

- Its temperature comes from a **component device**: the hub device whose `parentZid` is the thermostat's zid and whose
  type is `sensor.temperature` (its `celsius`). If there is no such component, the temperature-derived characteristics
  never update.
- CurrentTemperature = component `celsius` rounded to one decimal; if missing/zero, 22 with an error log.
- CurrentHeatingCoolingState (from temperature, `setPoint`, `mode`): `mode` off → off; missing temperature or setPoint →
  off (error log); |temp − setPoint| < 0.1 → off; temp ≥ setPoint + 0.1 and mode cool → cool; temp ≤ setPoint − 0.1 and
  mode heat or aux → heat; otherwise off.
- TargetHeatingCoolingState: off/heat/aux/cool → 0/1/1/2; valid values off, heat, cool; writes send `mode`
  `off`/`heat`/`cool` (unknown values logged and ignored). Log "Setting <name> mode to <mode>".
- TargetTemperature = `setPoint`; writes send `setPoint` if within [max(setPointMin or 10, 10), min(setPointMax or 38,
  38)], else logged and ignored. When the device reports setPointMin or setPointMax, the characteristic's min/max are set
  to that range.
- TemperatureDisplayUnits fixed at Fahrenheit (1), the only valid value; writes ignored.
- Plus common parts.

**Location Mode** (locations with cameras and Ring Modes but no alarm): Security System service named "<location> Mode".
Mode → state: `away` → Away (1), `home` → Stay (0), `disarmed` and anything else → Disarmed (3). Current state: follows
the latest fetched mode; a HomeKit read returns the last known mode and triggers a background fetch. Target: valid Away,
Stay, Disarm; reads return the in-flight target if any, else the current state. Writing: each write gets a sequence
number and later writes win; fetch the current state; Night is converted to Stay (and 100 ms later the target is pushed
back to HomeKit as Stay); if equal to current, nothing is sent; otherwise remember the target and POST `away` / `disarmed`
/ `home`, logging "Setting <location> Mode to …". The remembered target is cleared when a fetched mode matches it. On
failure (if still the latest write) log, clear the target, and push the current state as target. Accessory Information:
Manufacturer "Ring", Model "Location Mode", Serial "N/A".

Location mode "supported" test (only evaluated when `locationModePollingSeconds` > 0): false if the location has an alarm
base station or has no cameras; otherwise fetch the mode and require `readOnly` false and mode not `disabled`/`unset`.

**Chime**:

- Switch subtype `snooze`, name "<name> Snooze" (primary): On = `do_not_disturb.seconds_left` > 0; true → snooze 1440
  minutes (log "snoozed for 24 hours"), false → clear (log "snooze cleared").
- Speaker: Mute always false; Volume = `settings.volume` raw, props min 0 max 11 (level rule), writes PUT the volume.
- Switch subtype `play-ding`, name "<name> Play Ding": always reads false; true → play `ding` and set back to false
  1 s later. Switch subtype `play-motion`, "<name> Play Motion": same with `motion`.
- If `settings.night_light_settings` exists: Lightbulb subtype `nightlight`, name "<name> Nightlight", On =
  `light_sensor_enabled`; writes PATCH it (log "nightlight enabled/disabled").
- Accessory Information: Manufacturer "Ring", Model from the chime model table, Serial `device_id` or "Unknown".
- HomeKit reads of these characteristics trigger a REST refresh (3.5).

**Intercom**:

- Lock Mechanism (primary). The state is purely local: secured, except "unlocking" which shows unsecured. Writing
  Unsecured: log "Unlocking <name>", call unlock (3.1), log the JSON response (or log the error), then show unsecured for
  both current and target for 5 s and return to secured. Writing Secured: nothing is sent; just show secured. An
  "unlocked" push (unlocked from the Ring app) also shows unsecured for 5 s.
- Doorbell service and a Stateless Programmable Switch, both emitting single press on each intercom ding push, throttled
  to one per 15 s. The switch's max value is single press.
- If a battery level is derivable: Battery service, BatteryLevel (null → 100). (Reads trigger a refresh.)
- Accessory Information: Manufacturer "Ring", Model "Intercom Handset Audio" (also for the video kind), Serial
  `device_id` or "Unknown".

**Camera** (external accessory, category Camera):

- Camera stream management: see section 6 (10 concurrent stream management services, i.e. `cameraStreamCount` 10).
- Microphone service with Mute = false; Speaker service with Mute = false.
- Unless `hideCameraMotionSensor`: Motion Sensor, MotionDetected from the motion signal (3.6). When motion starts, the
  plugin first tries to refresh the snapshot (6.7) and only then sets true; motion ending sets false immediately.
- Doorbells (cameras listed in `doorbots` or `authorized_doorbots`, or whose `kind` starts with `doorbell`): a Doorbell
  service whose ProgrammableSwitchEvent fires single press on each doorbell-press push, throttled to one per 15 s (the
  first press passes), after the snapshot refresh. Unless `hideDoorbellSwitch`, also a Stateless Programmable Switch that
  fires single press on every press immediately (not throttled, no snapshot wait), max value single press.
- If the camera has a light (`led_status` present) and not `hideCameraLight`: Lightbulb (no subtype), On =
  `led_status` = `on`. Writing: call the light endpoint and, for 30 s, report the written value regardless of polled data.
  Reads trigger a refresh.
- If it has a siren (`siren_status` present) and not `hideCameraSirenSwitch`: Switch subtype `Siren`, name
  "<name> Siren", On = `siren_status.seconds_remaining` > 0; writes call the siren endpoint. Reads trigger a refresh.
- If it is a doorbell with `settings.chime_settings.type` mechanical (0) or digital (1), and not
  `hideInHomeDoorbellSwitch`: Switch subtype `In-Home Doorbell`, name "<name> In-Home Doorbell", On =
  `chime_settings.enable`; writes PUT the setting. Reads trigger a refresh.
- Accessory Information: Manufacturer = `metadata.third_party_manufacturer` (ONVIF) or "Ring"; Model =
  `metadata.third_party_model` (ONVIF) or "<model name> (<kind>)", e.g. "Doorbell Pro (lpd_v1)"; Serial = `device_id`.
- Battery (only if a battery level is derivable, below): StatusLowBattery = low when `alerts.battery` is `low`;
  ChargingState = charging when `external_connection` is true, else not charging; BatteryLevel = derived level (null →
  100).

Camera battery level: parse `battery_life` and `battery_life_2` (numbers or numeric strings; unparseable → absent); no
level if both are absent, or if `health` exists and none of `health.battery_percentage`, `health.battery_present`,
`health.second_battery_percentage` is truthy; otherwise the minimum of the parsed values. The same function applies to
intercoms (which have no `health`). "Operating on battery" = has a battery level and `settings.power_mode` is not `wired`.

---

## 5. Behaviour summary (events, timing, edge cases)

- Start-up waits for: locations, REST devices, and for each hub location the full device lists from every supported
  asset. If a hub never answers, start-up of that location hangs (no timeout in the original).
- Locations are processed concurrently; accessories are registered after all locations are done.
- The plugin never marks accessories "not responding". Offline cameras show an offline placeholder snapshot (6.6);
  offline hub assets are only logged.
- Live hub updates are merged per zid; REST device state is replaced wholesale on each poll.
- HomeKit reads never wait for the network: they return the cached value (and some trigger a background refresh).
- Panic switches trigger real emergency dispatch (professional monitoring). A port should mark them as security
  controls.
- Shutdown: unsubscribe everything, close location sockets and live streams, clear timers.

---

## 6. Live video and snapshots (the hardest part)

### 6.1 HomeKit-side configuration

Advertised streaming configuration:

- SRTP crypto suite AES_CM_128_HMAC_SHA1_80 only.
- Video: H.264, profile Baseline, level 3.1; resolutions (w×h@fps): 1920×1024@30, 1280×720@30, 1024×768@30, 640×480@30,
  640×360@30, 480×360@30, 480×270@30, 320×240@30, 320×240@15 (needed by Apple Watch), 320×180@30.
- Audio: Opus at 8 kHz (needed by Apple Watch), 16 kHz and 24 kHz. Two-way audio is used.
- Up to 10 simultaneous streams.

Note: the video actually forwarded is whatever Ring sends (H.264 offered as profile-level-id 640029, i.e. High 4.1),
passed through without transcoding (6.4); HomeKit accepts it in practice despite the advertised Baseline 3.1.

### 6.2 Obtaining a stream from Ring (WebRTC)

Done at HomeKit's **prepare** request (so the call is already connecting when "start" arrives).

1. If `settings.live_view_disabled` is true, fail with "live view is disabled for <name> by Modes; enable it in the Ring
   app".
2. POST app `clap/ticket/request/signalsocket` → `ticket`.
3. Open a WebSocket to
   `wss://api.prod.signalling.ring.devices.a2z.com:443/ws?api_version=4.0&auth_type=ring_solutions&client_id=ring_site-<random UUIDv4>&token=<ticket>`
   with a `User-Agent` header (`android:com.ringapp`); without a User-Agent Ring closes the socket immediately; its value
   does not seem to matter.
4. Create a WebRTC peer connection:
   - ICE servers (STUN only): `stun:stun.kinesisvideo.us-east-1.amazonaws.com:443`, `…us-east-2…:443`, `…us-west-2…:443`,
     `stun:stun.l.google.com:19302`, `stun:stun1.l.google.com:19302` … `stun:stun4.l.google.com:19302`. ICE transport
     policy all; **bundle policy "disable"** (audio and video use separate ICE/DTLS transports; no BUNDLE).
   - Audio transceiver send+receive (it carries return audio to the camera) offering Opus 48000/2 and PCMU 8000/1
     (payload type 0).
   - Video transceiver receive-only offering H.264 90000 with RTCP feedback `transport-cc`, `ccm fir`, `nack`, `nack pli`,
     `goog-remb` and fmtp `packetization-mode=1;profile-level-id=640029;level-asymmetry-allowed=1`, plus RTX.
   - DTLS-SRTP as usual for WebRTC.
5. When the socket opens: create the offer, set it as the local description and send it (6.3 `live_view`). Local ICE
   candidates are trickled after the offer was sent.
6. On the answer: set the remote description, then send `activate_session` and `stream_options` (audio and video
   enabled). `activate_session` is required or the stream ends after about 70 s.
7. When the first video RTP packet arrives, send an RTCP PLI (key frame request) for the received SSRC immediately and
   then every 4 s for the whole call, and also whenever a key frame is requested explicitly (FFmpeg start).
8. Every 5 s send a session `ping` (Ring Edge sessions need it).
9. Two-way audio: on the first return-audio packet from HomeKit, wait for the `camera_connected` notification (if not
   already received) and send `camera_options` with `stealth_mode: false` (turns on the camera's speaker). Only once per
   call.

Call end triggers: signalling `close` message (logged with its reason), WebSocket error or close, peer connection state
`failed` or `closed`, HomeKit stop, inactivity (6.4), FFmpeg exit. Ending sends a final frame
`{"reason": {"code": 0, "text": ""}, "method": "close"}`, closes the socket and the peer connection. Every end path is
idempotent.

### 6.3 Signalling messages

All frames are JSON text: `{"method": <string>, "dialog_id": <UUIDv4 chosen per call>, "body": {…}}`.

Sent:

| method | body |
|---|---|
| `live_view` | `{"doorbot_id": <camera id>, "stream_options": {"audio_enabled": true, "video_enabled": true}, "sdp": <offer SDP>}` |
| `ice` | `{"doorbot_id": <id>, "ice": <candidate line, e.g. "candidate:…">, "mlineindex": <m-line index>}` |
| session messages: `ping`, `pong`, `activate_session`, `stream_options` (`audio_enabled`, `video_enabled`), `camera_options` (`stealth_mode`) | always include `doorbot_id` and `session_id`; sent only once the session id is known (queued until then) |
| `close` | see 6.2 (no dialog id or body) |

Received (messages whose `body.doorbot_id` is not this camera are ignored; once a session id is known, messages with a
different `body.session_id` are ignored):

| method | handling |
|---|---|
| `session_created`, `session_started` | the first one carrying `body.session_id` fixes the session id |
| `sdp` | `body.sdp` (and `body.type` = `answer`): the answer |
| `ice` | `body.ice` candidate string, `body.mlineindex`: add remote candidate |
| `ping` | reply with session message `pong` |
| `pong` | ignore |
| `notification` | `body.text` = `camera_connected` → camera is connected (needed for `camera_options`); `PeerConnectionState::kConnecting` / `kConnected` → ignore; other texts are logged as unknown; `body.is_ok` also present |
| `close` | `body.reason` = `{code, text}` (0 normal, 5 authentication failed / session not found, 6 timeout waiting for ping): end the call |
| `camera_started`, `stream_info` (`transcoding`, `transcoding_reason` such as `codec_mismatch`) | ignore |
| anything else | log as unknown |

An error while handling a message ends the call; if its text mentions "negotiate codecs failed", the logged message
points users to the project's "Streaming Legacy Mode" wiki page.

Whether Ring answered with Opus or PCMU is decided by whether the answer SDP contains ` opus/` (case-insensitive).

### 6.4 Handing the stream to HomeKit

Per HomeKit session (keyed by HomeKit's session id) the plugin creates:

- random audio and video SSRCs and random SRTP key+salt for each (the key/salt returned in the prepare response are used
  for **both** directions: the plugin encrypts what it sends and HomeKit's return traffic is decrypted with the same
  values);
- three local UDP sockets on ephemeral ports: "video" (its port is the video port in the prepare response), "audio" (the
  audio port in the prepare response) and "transcoded audio" (internal).

Prepare response: audio `{port, ssrc, srtp_key, srtp_salt}`, video `{port, ssrc, srtp_key, srtp_salt}` (Homeswift's
RTPStreamManagement presumably owns this exchange).

Right after prepare, for the life of the session:

- **RTCP keep-alive**: every 500 ms send an SRTCP-encrypted (video key/salt) RTCP Sender Report with the video SSRC and
  all-zero sender info (NTP 0, RTP timestamp 0, counts 0) from the video socket to HomeKit's video address/port. Without
  it HomeKit considers the stream dead after ~30 s.
- **Inactivity**: any packet received from HomeKit on the video or audio socket counts as activity. If nothing has been
  received for 5 s after the last activity — with an initial grace of 15 s after prepare — end the call (log "live stream
  appears to be inactive"), e.g. when the Home app is force-quit.

At HomeKit's **start** request (`pt`, `sample_rate`, `packet_time`, `max_bit_rate`, `channel` for audio; `pt` for video):

- **Video (no transcoding)**: for every RTP packet received from the WebRTC video track (already decrypted from
  DTLS-SRTP), set the SSRC to the session's video SSRC and the payload type to HomeKit's video `pt`, keep everything
  else (sequence numbers, timestamps, marker, header extensions), SRTP-encrypt with the video key/salt and send from the
  video socket to HomeKit's address and video port. Log "received stream data" with the elapsed seconds on the first
  packet.
- **Audio to HomeKit (FFmpeg transcode)**:
  - Wait for Ring's answer SDP (or the end of the call). Build an FFmpeg input SDP from it: drop everything before the
    first `m=` line, drop the video media section, and rewrite the audio port in the `m=audio` line to a local port
    reserved for FFmpeg (the original reserves two consecutive ports). Feed it to FFmpeg on stdin.
  - FFmpeg input arguments: hide banner, protocol whitelist `pipe,udp,rtp,file,crypto`, input decoder libopus when Ring
    answered Opus (none for PCMU), format `sdp`, `-vn`, input `pipe:`.
  - Output: libopus, application lowdelay, frame duration = HomeKit `packet_time`, global header flag, sample rate
    `<sample_rate>k`, bitrate `<max_bit_rate>k`, buffer 4 × bitrate, `<channel>` channels, payload type = HomeKit audio
    `pt`, SSRC = session audio SSRC, format RTP to `rtp://127.0.0.1:<transcoded audio socket port>`.
  - Every WebRTC audio RTP packet is re-serialized as plain RTP and sent to FFmpeg's input port (in order).
  - Each RTP packet FFmpeg sends to the transcoded-audio socket: replace its timestamp with a running counter (starts at
    the first packet's timestamp; each packet adds `sample_rate` (kHz number) × `packet_time` (ms), e.g. 16 × 20 = 320;
    taken modulo 0xFFFFFFFF) — HomeKit expects RFC 3550-style clock rate timestamps instead of the 48 kHz Opus clock —
    then SRTP-encrypt with the audio key/salt and send from the audio socket to HomeKit's audio port.
  - The FFmpeg label is "From Ring (<name>)"; when FFmpeg exits the call ends.
- **Return audio (HomeKit → camera)**: a second FFmpeg (camera-utils "return audio transcoder") reads HomeKit's SRTP Opus
  stream that arrives on the audio socket (an SDP describing HomeKit's incoming stream: HomeKit's audio `pt`, Opus at the
  negotiated rate, the session's SRTP key/salt, the session audio SSRC; RTCP ignored) and outputs libopus, application
  lowdelay, 60 ms frames, global header, 48 kHz, 48 kbit/s, buffer 192k, 2 channels, as RTP to a local socket. Each packet
  there is parsed (parse failures ignored) and written into the WebRTC audio track (the WebRTC stack re-packetizes and
  encrypts it). The first such packet turns on the camera speaker (6.2 step 9). Label "Return Audio (<name>)". It stops
  when the call ends. (Ring answering PCMU is not handled in this path by the plugin; the client's generic return-audio
  helper would encode PCM µ-law mono 8 kHz in that case.)
- The start request is answered after both FFmpeg processes have started; failure answers "failed to activate stream".

At HomeKit's **stop**: close the three sockets and end the call; forget the session. A start/stop for an unknown session
id is answered with an error. When the Ring call ends on its own, HomeKit is not told explicitly (the RTCP keep-alive stops
and HomeKit times out).

Timing logs: "Preparing Live Stream", "Stream Prepared (<s>)", "Activating stream (<s>)", "Streaming active (<s>)",
"Stopped Live Stream"; prepare failure "Failed to prepare stream (<s>)" with the error.

### 6.5 Simple alternative (not used by the plugin)

The client also offers an HTTP live-view session for browsers: POST `https://api.ring.com/integrations/v1/liveview/start`
`{"session_id": <uuid>, "device_id": <camera id>, "sdp": <offer>, "protocol": "webrtc"}` → `{"sdp": <answer>}` (no
trickle ICE), `…/end` `{"session_id"}`, PATCH `…/options` `{"session_id", "actions": ["turn_off_stealth_mode"]}`. It could
be an easier path for a port (one HTTP round trip instead of the signalling socket), but it is untested by the plugin.

### 6.6 Snapshots from Ring

Per camera the client keeps: the last snapshot request (in flight or done), the camera-side timestamp of the last
snapshot, and a local "taken at" time.

- **Lifetime**: 600 s when `avoidSnapshotBatteryDrain` and the camera operates on battery; otherwise 10 s. A snapshot is
  "within lifetime" when now − local taken-at < lifetime.
- Getting a snapshot: if a previous request exists and the last snapshot is within lifetime, return that same result.
  Otherwise: fail with "motion detection is disabled for <name>, which prevents snapshots (Modes or Record Motion)" when
  `settings.motion_detection_enabled` is false; fail "offline" when `alerts.connection` is `offline`; else request
  `GET https://app-snaps.ring.com/snapshots/next/<camera id>` with query either `uuid=<uuid>` (when a notification
  snapshot uuid is given, with anything from the first `:` on removed) or `after-ms=<camera timestamp of last snapshot,
  0 initially>&extras=force`, header `accept: image/jpeg`, binary JPEG response, no transport retry. Race it against
  15 s; on timeout fail with "snapshot failed to refresh after 15 seconds" (adding "normal, this camera cannot capture
  snapshots while streaming" for cameras that cannot).
- After a response: camera timestamp = `x-time-millis` header; local taken-at = now − |`date` header − `x-time-millis`|
  (the image's age as seen by the server). A failed request is forgotten so the next call retries.
- "Can take a snapshot while recording" = not operating on battery and `kind` is not `doorbell_graham_cracker`.

### 6.7 Snapshots to HomeKit

The camera accessory keeps one cached JPEG.

- HomeKit snapshot request (requested size ignored; the JPEG is returned as-is):
  1. camera offline → a bundled 1920×1080 JPEG placeholder saying the camera is offline;
  2. snapshots blocked (`settings.motion_detection_enabled` false) → a bundled 1920×1080 JPEG placeholder saying
     snapshots are blocked;
  3. otherwise, if the last Ring snapshot is not within lifetime, start a background refresh (not awaited); return the
     cached JPEG if any, else answer with an error ("no snapshot cached") rather than an empty image.
  A port needs its own two placeholder images.
- Refresh: at most one at a time (concurrent callers share it); on success the cache holds the new image, which is
  dropped lifetime + 2 minutes later unless replaced (so slow clients polling every 60 s still get an image); on failure
  the cache is cleared and a debug line notes whether the camera reports offline.
- Event snapshots (motion start, doorbell press, before notifying HomeKit, so the rich notification shows the moment):
  take the latest notification's snapshot uuid. If the camera cannot snapshot while recording and there is no uuid yet,
  wait up to 2 s for a notification that carries one; if still none, log "<name> Detected Motion" (or "Doorbell
  Pressed") and fire without a new snapshot. Otherwise log "…, loading snapshot before sending event to HomeKit", refresh
  (by uuid, or forced), and fire; on failure log "failed to load snapshot, sending event without new snapshot" and fire.

---

## 7. Logging (paraphrased) and secrets

Info: the list of locations ("locationId: <id> - <name>"); "Configuring <n> cameras and <m> devices for location";
per accessory "Adding new accessory <uuid> <deviceType> <name>", "Configured camera <uuid> …", "Hidden accessory …",
"Configuring cached accessory …", "Removing stale cached accessory …", "Pruning unused service …"; every user-driven
action ("Arming (Away) …", "Turning X On", "Setting brightness of X to n%", "X snoozed for 24 hours", "Unlocking X" and
the unlock response, "Burglar Alarm activated for <location>"…); hub socket lifecycle ("Creating location connection -
<name>", "connected", "Reconnecting", "told to reconnect", asset offline/back online); session rate limiting; event
lines ("<name> Detected Motion", "Doorbell Pressed", "Detected Flooding/Freezing/Water"); stream timings (6.4);
WebRTC ICE and connection state changes; "Ignoring push notification received in first two seconds".

Errors: request failures with URL, status and **response body**; token failures (with Ring's error text); 2FA
prompts; push connection failures with the firewall hint; FFmpeg errors; unknown signalling messages (logged whole,
which includes session ids); thermostat fallbacks.

Debug (`debug: true`): FFmpeg output, snapshot cache decisions and timings, location mode responses, unknown push
payloads (logged whole), WebSocket close codes.

Secrets — never log them, and treat them as such in storage:

- `refreshToken` (the wrapper contains the Ring refresh token **and** the FCM credentials, including private keys and
  auth secrets of the push registration), Ring access tokens;
- the email, password and 2FA codes of the token flow;
- the hub ticket (`authcode` in the WebSocket URL), the signalling ticket (`token` in its URL), and the full WebSocket
  URLs;
- the FCM token; SRTP keys and salts; SDP bodies (ICE credentials, DTLS fingerprints);
- the hardware id is an account-bound client identifier (treat as sensitive, not secret);
- snapshot images and push payloads contain personal data (names, location ids, addresses in some responses, owner
  email in `ring_devices` and session/profile responses).

The original logs some of these (whole error response objects of the token request, unknown push payloads, unknown
signalling frames); a port should mask them.

---

## 8. Test vectors (invented data, personal data replaced)

### 8.1 Identity seeds and UUIDs

Computed by the spec writer from the algorithm in 4.1 (verify against Homeswift's helper):

| Seed | UUID |
|---|---|
| `1001camera` | `0c3b0c68-90ba-4c1e-ac80-efd358d2c1b6` |
| `1002camera` | `5322f216-72ab-4eb6-9bed-1bca0da88ec1` |
| `2001` | `9195f873-d171-45b7-975f-88118db6dc42` |
| `5001` | `7b61dec0-7e02-4c18-8790-670af43e717f` |
| `zid-security-panel` | `80dd424c-99c8-44fc-98d2-15e50c1a00ca` |
| `zid-contact` | `08c163b6-1a37-4394-b1e5-a55c9caa85bd` |
| `zid-security-panelpanic` | `12db32f8-286d-4548-9f7f-b9a2fc2075cd` |
| `loc-alarm-001mode` | `cb47393a-1236-4e4b-8364-ffdaf0279083` |

Wrapper token: `{"rt":"EXAMPLE-RT","hid":"11111111-2222-5333-8444-555555555555"}` encodes to
`eyJydCI6IkVYQU1QTEUtUlQiLCJoaWQiOiIxMTExMTExMS0yMjIyLTUzMzMtODQ0NC01NTU1NTU1NTU1NTUifQ==`. A string that does not
decode to JSON with `rt` (e.g. `abc.def`) is a raw refresh token.

Hardware id: UUIDv5 of the systemId `0123456789abcdef` repeated four times, namespace
`e53ffdc0-e91d-4ce1-bec2-df939d94739d` → `c3b5b8ad-76e2-5873-a024-9491721d2150`.

### 8.2 OAuth

Request body (refresh): `{"client_id":"ring_official_android","scope":"client","grant_type":"refresh_token","refresh_token":"EXAMPLE-RT"}`.
Success: `{"access_token":"AT-1","expires_in":3600,"refresh_token":"EXAMPLE-RT-2","scope":"client","token_type":"Bearer"}`.
2FA needed: status 412, body `{"next_time_in_secs":60,"phone":"+1xxxxxx1234","tsv_state":"sms"}`.
Wrong code: status 400, body `{"error":"Verification Code is invalid or expired"}`.
Rate limited: status 400/429 with `{"error":"…","error_description":"too many requests from dependency service"}`.
Session missing: any `clients_api` call → 404 `{"error":"Session not found for 11111111-2222-5333-8444-555555555555"}`.

### 8.3 Locations and REST devices

`GET devices/v1/locations`:
```json
{"user_locations":[{"location_id":"loc-alarm-001","name":"Home","owner_id":1,
  "address":{"address1":"1 Example St","address2":"","cross_street":"","city":"Exampleville","state":"CA",
  "timezone":"America/Los_Angeles","zip_code":"00000"},
  "geo_coordinates":{"latitude":"0","longitude":"0"},"geo_service_verified":"address_only","user_verified":true,
  "created_at":"2020-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}]}
```

`GET clients_api/ring_devices` (abridged):
```json
{"doorbots":[{"id":1001,"description":"Front Door","device_id":"aa:bb:cc:dd:ee:01","kind":"lpd_v1",
   "location_id":"loc-alarm-001","alerts":{"connection":"online"},"battery_life":null,"external_connection":true,
   "settings":{"chime_settings":{"type":0,"enable":true,"duration":0},"motion_detection_enabled":true,
     "live_view_disabled":false,"sheila_settings":{"cv_processing_enabled":false,"local_storage_enabled":false}},
   "health":{"device_type":"lpd_v1","connected":true},"subscribed":true,"subscribed_motions":true}],
 "stickup_cams":[{"id":1002,"description":"Garage Cam","device_id":"aa:bb:cc:dd:ee:02","kind":"stickup_cam_mini",
   "location_id":"loc-alarm-001","alerts":{"connection":"online","battery":"ok"},"battery_life":"87",
   "external_connection":false,"led_status":"off","siren_status":{"seconds_remaining":0},
   "settings":{"power_mode":"battery","motion_detection_enabled":true,
     "sheila_settings":{"local_storage_enabled":false}},"health":{"battery_percentage":87}}],
 "authorized_doorbots":[],
 "chimes":[{"id":2001,"description":"Hall Chime","device_id":"chime-hw-1","kind":"chime_pro_v2",
   "location_id":"loc-alarm-001","settings":{"volume":6,"night_light_settings":{"light_sensor_enabled":false}},
   "do_not_disturb":{"seconds_left":0},"alerts":{"connection":"online"}}],
 "base_stations":[{"id":3001,"kind":"base_station_v1","location_id":"loc-alarm-001","description":"Alarm Base Station"}],
 "beams_bridges":[{"id":4001,"kind":"beams_bridge_v1","location_id":"loc-alarm-001","description":"Lighting Bridge"}],
 "other":[{"id":5001,"kind":"intercom_handset_audio","description":"Lobby Intercom","device_id":"ic-hw-1",
   "location_id":"loc-alarm-001","battery_life":"100","subscribed":true,"alerts":{"connection":"online"}},
  {"id":1003,"kind":"onvif_camera","description":"ONVIF Cam","device_id":"onvif-1","location_id":"loc-alarm-001",
   "metadata":{"third_party_manufacturer":"Acme","third_party_model":"X1"}}]}
```
Expected: cameras 1001 (doorbell; Doorbell + programmable switch + in-home doorbell switch, no light/siren/battery),
1002 (light, siren, battery 87, not a doorbell), 1003 (ONVIF; Manufacturer "Acme", Model "X1"); chime 2001 with a
nightlight; intercom 5001 with battery 100. The location has hubs and an alarm base station, so no Location Mode accessory.
Battery: `battery_life` "87" with `health.battery_percentage` 87 → 87; `battery_life` null → no battery service.

### 8.4 Location hub socket

Ticket response:
```json
{"assets":[{"uuid":"asset-base-uuid-0001","kind":"base_station_v1","doorbotId":3001,"onBattery":false,"status":"online"},
           {"uuid":"asset-beam-uuid-0001","kind":"beams_bridge_v1","doorbotId":4001,"onBattery":false,"status":"online"}],
 "host":"hub.example.invalid","ticket":"TICKET","subscriptionTopics":[]}
```
→ connect `wss://hub.example.invalid/ws?authcode=TICKET&ack=false`, then send
`{"channel":"message","msg":{"msg":"DeviceInfoDocGetList","dst":"asset-base-uuid-0001","seq":1}}` and the same with
`asset-beam-uuid-0001`, `seq` 2.

Device list from the base station:
```json
{"channel":"message","msg":{"msg":"DeviceInfoDocGetList","datatype":"DeviceInfoDocType","src":"asset-base-uuid-0001",
 "body":[
  {"general":{"v2":{"zid":"zid-security-panel","name":"Security Panel","deviceType":"security-panel","categoryId":22,
     "batteryStatus":"none","tamperStatus":"ok","tags":[]}},"device":{"v1":{"mode":"none"}}},
  {"general":{"v2":{"zid":"zid-base-station","name":"Base Station","deviceType":"hub.redsky","categoryId":22,
     "batteryStatus":"none","tamperStatus":"ok","tags":[],"volume":0.5}},"device":{"v1":{}}},
  {"general":{"v2":{"zid":"zid-contact","name":"Front Door Contact","deviceType":"sensor.contact","categoryId":5,
     "batteryStatus":"ok","tamperStatus":"ok","tags":[]}},"device":{"v1":{"faulted":false}}},
  {"general":{"v2":{"zid":"zid-thermostat","name":"Living Thermostat","deviceType":"temperature-control.thermostat",
     "categoryId":11,"batteryStatus":"none","tamperStatus":"ok","tags":[]}},
     "device":{"v1":{"mode":"heat","setPoint":21,"setPointMin":7,"setPointMax":30}}},
  {"general":{"v2":{"zid":"zid-thermo-temp","name":"Living Thermostat Temperature","deviceType":"sensor.temperature",
     "categoryId":5,"batteryStatus":"none","tamperStatus":"ok","tags":[],"parentZid":"zid-thermostat"}},
     "device":{"v1":{"celsius":19.94}}}
 ]}}
```
Expected: security panel (disarmed: current 3, target 3; siren switch off), base station (no brightness → only Speaker
volume 50; no battery), contact sensor (detected/closed, battery 50, low battery normal), thermostat (current 19.9,
heating state heat because 19.94 ≤ 21 − 0.1, target range 10…30), temperature sensor 19.94.

Live update (door opens):
`{"channel":"DataUpdate","msg":{"msg":"DeviceInfoDocGetList","datatype":"DeviceInfoDocType","src":"asset-base-uuid-0001","body":[{"general":{"v2":{"zid":"zid-contact"}},"device":{"v1":{"faulted":true}}}]}}`
→ ContactSensorState 1.

Alarm triggered:
`…"body":[{"general":{"v2":{"zid":"zid-security-panel"}},"device":{"v1":{"mode":"all","alarmInfo":{"state":"burglar-alarm","faultedDevices":["zid-contact"],"timestamp":1700000000000}}}}]`
→ current 4, target 1. With `alarmInfo.state` `entry-delay`: current 1 (or 4 with `alarmOnEntryDelay`).

Session info:
`{"channel":"DataUpdate","msg":{"msg":"SessionInfo","datatype":"SessionInfoType","src":"asset-base-uuid-0001","body":[{"assetUuid":"asset-base-uuid-0001","connectionStatus":"cell-backup","doorbotId":3001,"kind":"base_station_v1","sessionId":1}]}}`
→ "offline or on cellular backup" logged once; a later `online` re-requests its list.

Reconnect order:
`{"channel":"message","msg":{"msg":"DeviceInfoDocGetList","datatype":"HubDisconnectionEventType","src":"asset-base-uuid-0001","body":[]}}`.

Arm away with bypass (Night with `nightModeBypassFor` `all`, door open):
`{"channel":"message","msg":{"msg":"DeviceInfoSet","datatype":"DeviceInfoSetType","dst":"asset-base-uuid-0001","body":[{"zid":"zid-security-panel","command":{"v1":[{"commandType":"security-panel.switch-mode","data":{"mode":"all","bypass":["zid-contact"]}}]}}],"seq":3}}`.

Dimmer write (Smart Lighting beam at 42 %):
`{"channel":"message","msg":{"msg":"DeviceInfoSet","datatype":"DeviceInfoSetType","dst":"asset-beam-uuid-0001","body":[{"zid":"zid-beam-dimmer","device":{"v1":{"level":0.42}}}],"seq":4}}`.

### 8.5 Push notifications

Ding (FCM data map; each value is a JSON string):
```
version        = "2.0.0"
android_config = {"category":"com.ring.pn.live-event.ding","body":"There's someone at your Front Door"}
analytics      = {"server_correlation_id":"x","server_id":"com.ring.pns","subcategory":"","triggered_at":1700000000000,"sent_at":1700000000100,"referring_item_type":"","referring_item_id":""}
data           = {"device":{"id":1001,"kind":"lpd_v1","name":"Front Door","e2ee_enabled":false},
                  "event":{"ding":{"id":"7300000000000000001","created_at":"2024-01-01T00:00:00Z","subtype":"ding"},
                           "riid":"r","is_sidewalk":false},
                  "location":{"id":"loc-alarm-001"}}
img            = {"snapshot_uuid":"abcd-1234:extra"}
```
→ camera 1001: doorbell press (single press on Doorbell after a snapshot load by uuid `abcd-1234`; immediate press on the
programmable switch). Note the ding id kept as a string. The same with category `com.ring.pn.live-event.motion` → motion
true, false 65 s later. Category `com.ring.pn.live-event.intercom` with device id 5001 → intercom ding.

Intercom unlock: `data = {"gcmData":{"action":"com.ring.push.INTERCOM_UNLOCK_FROM_APP","aps":{"alert":"…"},"alarm_meta":{"device_zid":5001,"location_id":"loc-alarm-001"}}}`.

### 8.6 Signalling

Received in order for a successful call (bodies abridged; `doorbot_id` 1001 everywhere):
`{"method":"session_created","body":{"doorbot_id":1001,"session_id":"S1"}}`,
`{"method":"sdp","body":{"doorbot_id":1001,"session_id":"S1","type":"answer","sdp":"v=0…m=audio 9 UDP/TLS/RTP/SAVPF 111…a=rtpmap:111 opus/48000/2…m=video 9 UDP/TLS/RTP/SAVPF 96…"}}`,
`{"method":"ice","body":{"doorbot_id":1001,"session_id":"S1","ice":"candidate:1 1 udp 2122260223 192.0.2.10 50000 typ host","mlineindex":0}}`,
`{"method":"notification","body":{"doorbot_id":1001,"session_id":"S1","is_ok":true,"text":"camera_connected"}}`,
`{"method":"ping","body":{"doorbot_id":1001,"session_id":"S1"}}` (→ reply `pong`),
`{"method":"close","body":{"doorbot_id":1001,"session_id":"S1","reason":{"code":6,"text":"Timeout waiting for ping"}}}`.

### 8.7 Location mode

`GET app mode/location/loc-cam-only` → `{"mode":"home","readOnly":false,"lastUpdateTimeMS":1700000000000,"securityStatus":{"md":"none","returnTopic":"t"}}`
→ supported; current 0. `{"mode":"disabled",…}` or `"readOnly":true` → no accessory.

### 8.8 Fixtures in the original tests (described, not copied)

The client's tests use: a locations list with one location; a `ring_devices` response with one doorbell (Pro), one
battery indoor cam with light and siren, a chime pro v2 with nightlight, a base station, a beams bridge, an audio
intercom and an ONVIF camera; a hub ticket with one base station and one beams bridge asset; device documents for one of
each hub kind (security panel, base station, contact, motion, flood/freeze, smoke, CO, lock, thermostat, valve, outlet,
fan, dimmer, keypad, freeze, temperature, water, tilt, glass-break, smoke/CO listener, Kidde, unknown Z-Wave, retrofit
zone; beams switch, dimmer with motion, group, motion sensor, transformer); builders for device-list, data-update,
session-info and hub-disconnection frames; a mock WebSocket. The REST tests fake the OAuth endpoint (refresh and 2FA
paths), the session endpoint (counting session creations and checking the hardware id and body) and a protected endpoint
that answers 401 to an expired token and 404 "Session not found for <hid>" before a session exists. The plugin's tests
drive each accessory kind through a harness with fake HAP services and check characteristic values and writes, the
platform's routing table (4.2), config defaults and token rewriting.

---

## 9. What a drop-in must reproduce exactly

1. Platform `Ring`, the option keys of section 1 with their defaults.
2. Identity seeds of 4.1 and the HAP UUID derivation; `hideDeviceIds` against those UUIDs.
3. Service types and subtypes of 4.5 (subtypes `Burglar`, `Fire`, `snooze`, `play-ding`, `play-motion`, `nightlight`,
   `Siren` (camera only), `In-Home Doorbell`; everything else without subtype), so instance ids stay stable.
4. Reading the existing wrapper token (and its `hid`) so Ring sees the same client; rotating and persisting it.
5. Cameras as external accessories (the user re-pairs them once in any case, since pairings are not transferable).

## 10. Gaps and hard parts

- **FCM push** is implemented by an external library whose code is not in this repository; its wire protocol
  (Firebase Installations / FCM registration, GCM check-in, the MCS connection to `mtalk.google.com:5228`, and whether
  payloads are encrypted web-push style or plain Android data messages) could not be determined here. Only the
  configuration values (3.6), the credential storage (`pnc`, with `fcm.token` and a `config` member) and the message
  contents are known. Without it, no doorbell or motion events. The exact `pnc` object layout is library-defined; a port
  can keep its own credentials elsewhere but should preserve `pnc` in the wrapper.
- **WebRTC** (ICE with trickle, separate DTLS-SRTP transports for audio and video, RTP/RTCP, PLI, sending return audio on
  a negotiated track) is the hardest part; there is no FFmpeg-only shortcut for the receive side because Ring only
  offers WebRTC. The HTTP live-view endpoint (6.5) removes the signalling socket but not WebRTC itself.
- The HomeKit return-audio SDP and FFmpeg arguments come from `@homebridge/camera-utils`, which is not in this repository;
  6.4 describes them from their use. Homeswift's FFmpeg and RTP stream code likely covers it.
- Advertised Baseline 3.1 while forwarding High-profile H.264 untouched works with HomeKit in practice (per the
  original's behaviour), but is not guaranteed for every client (Apple Watch requests 320×240@15 and still receives Ring's
  native stream).
- Start-up waits without a timeout for hub device lists, and alarm mode changes wait without a timeout for the panel's
  next update; a port should add timeouts.
- Ring rotates refresh tokens; losing the rotated token (crash before persisting) locks the user out until a new token
  is generated. Two processes using the same token invalidate each other.
- The FCM credentials, hardware id and session are all tied together; changing the hardware id makes Ring list a new
  client in Control Center and may drop push delivery to the old one.
- The 404 error code meanings (7050 etc.) and the close reason codes come from observed behaviour noted in the original,
  not from documentation; Ring's API is private and may change without notice.
- Not determined: the full `ring_devices` schema for every model (only the fields used are listed), Ring's rate limits
  beyond the session 429 and the 2FA limit, and the exact content of the two placeholder JPEGs (a port draws its own).
- The `Sensor` (generic `sensor`) routing by name containing "motion" is a heuristic.
- The original exposes the water valve as a Switch and the fan as the legacy Fan service; a port should keep those for
  compatibility with existing scenes (changing service types changes iids).

---

## 11. Push registration values

Taken from the same clone, under the same clean-room rules. These are the interface values as ring-client-api uses them.

### 11.1 What is passed to the push receiver library

ring-client-api builds one push receiver (`@eneris/push-receiver` 4.4.0) per API instance with these options:

| Field | Value |
|---|---|
| `firebase.apiKey` | `AIzaSyCv-hdFBmmdBBJadNy-TFwB-xN_H5m3Bk8` |
| `firebase.projectId` | `ring-17770` |
| `firebase.messagingSenderId` | `876313859327` (Ring's Android app. A comment in the source gives `703521446232` as the value for "ring-site"; it is not used.) |
| `firebase.appId` | `1:876313859327:android:e10ec6ddb3c81f39` |
| `credentials` | The stored `pnc` object (11.4), passed only when it is present and has a `config` member; otherwise nothing is passed and the library registers from scratch |
| `debug` | `false` |

No VAPID key, bundle id, package name, certificate hash or any other field is passed. If the library uses such values, they are its own defaults, which are not in this repository.

From the lockfile, the library depends on `http_ece` (Encrypted Content-Encoding for HTTP, RFC 8188 / aesgcm), `protobufjs`, `long` and `jsonwebtoken`. That suggests it registers as an encrypted web-push style FCM client and decrypts each message itself. This is an inference; the library's code was not read.

Library events used:
- **Credentials changed** (new or renewed credentials): store them as `pnc` (11.4), then register the new `fcm.token` with Ring (11.2).
- **Notification**: one message whose `data` is a string-to-string map.
- **Disconnect**: log any failure of the library's own reconnect, with the hint about TCP 5228 and `mtalk.google.com`.
- **connect()**: called once at start-up. A failure is logged and not retried by the client.

### 11.2 Registering the token with Ring

`PATCH https://api.ring.com/clients_api/device`, sent with the normal authenticated headers (Bearer token, `hardware_id`, `User-Agent: android:com.ringapp`, JSON) and this body:

```json
{"device": {
   "metadata": {"api_version": 11, "device_model": "homebridge-ring",
                "pn_dict_version": "2.0.0", "pn_service": "fcm"},
   "os": "android",
   "push_notification_token": "<fcm.token>"}}
```

`device_model` is the `controlCenterDisplayName` (default `homebridge-ring`). The PATCH is sent:
- each time the library reports new credentials;
- at start-up, if stored credentials were passed in and their `fcm.token` is unchanged after `connect()`;
- again after every session creation (`POST clients_api/session`, see 2.5), with the latest token.

Errors are only logged. Ring links the token to the session identified by the `hardware_id` header, so the hardware id has to stay the same (2.3).

Separately, each camera must be subscribed for Ring to send it pushes: `POST clients_api/doorbots/{id}/subscribe` (dings) and `…/motions_subscribe` (motion). This is done at start-up and after each session creation. Intercoms are subscribed at start-up only, and only when their `subscribed` is false.

### 11.3 Notification payloads

Each value of the message's `data` map is JSON-parsed separately. Integers too large for a double are kept as decimal strings. A value that is not valid JSON stays a plain string. Messages arriving in the first 2 s after connecting are dropped.

**Ding or motion (v2)**. The map has these keys:
- `version`: `"2.0.0"`;
- `android_config`: `{category, body}`;
- `analytics`: `{server_correlation_id, server_id, subcategory, triggered_at, sent_at, referring_item_type, referring_item_id}`;
- `data`: an object, described below;
- `img`: optional `{snapshot_uuid}`.

The `data` object contains:
- `device`: `{id, kind, name, e2ee_enabled}`;
- `event`: `{ding: {id, created_at, subtype, detection_type?}, eventito: {type, timestamp}, riid, is_sidewalk, live_session: {streaming_data_hash, active_streaming_profile, default_audio_route, max_duration}}`;
- `location`: `{id}`.

Fields the client reads:
- `android_config` being present selects v2 handling. `android_config.category` is one of `com.ring.pn.live-event.ding`, `com.ring.pn.live-event.motion` or `com.ring.pn.live-event.intercom`.
- `data.device.id` is the camera or intercom id, matched as a string.
- `data.event.ding` must be present for cameras. `data.event.ding.id` deduplicates notifications and expires each one 65 s later.
- `img.snapshot_uuid` is used for the event snapshot, with everything from the first `:` removed.

`subtype` takes values such as `ding`, `motion`, `other_motion` or `human`; it is not used for routing.

Example, motion on camera 1001 (invented ids):

```
version        "2.0.0"
android_config {"category":"com.ring.pn.live-event.motion","body":"There is motion at your Garage Cam"}
analytics      {"server_correlation_id":"c0ffee","server_id":"com.ring.pns","subcategory":"motion","triggered_at":1700000000000,"sent_at":1700000000250,"referring_item_type":"","referring_item_id":""}
data           {"device":{"id":1001,"kind":"stickup_cam_mini","name":"Garage Cam","e2ee_enabled":false},
                "event":{"ding":{"id":7300000000000000002,"created_at":"2024-01-01T00:00:00Z","subtype":"human"},
                         "eventito":{"type":"human","timestamp":1700000000000},"riid":"r-1","is_sidewalk":false,
                         "live_session":{"streaming_data_hash":"h","active_streaming_profile":"rms","default_audio_route":"","max_duration":600}},
                "location":{"id":"loc-alarm-001"}}
img            {"snapshot_uuid":"5e1f-aaaa:1700000000"}
```

The ding id arrives as a raw JSON number above 2^53 and is kept as the string `"7300000000000000002"`. Camera 1001's motion becomes true, then false 65 s after the last motion notification. A ding is the same message with category `…live-event.ding`; it fires a doorbell press.

**Alarm-style (v1)**. There is no `android_config`. The `data` value is `{"gcmData": {"action": <string>, "aps": {"alert": <text>}, "alarm_meta": {"device_zid": <id>, "location_id": <id>}}}`. It is routed to the device whose id equals `alarm_meta.device_zid`. Only intercoms use it, when `action` is `com.ring.push.INTERCOM_UNLOCK_FROM_APP` (unlocked from the app).

Any other shape is dropped and logged at debug level.

### 11.4 `pnc` inside the refresh-token wrapper

The wrapper is base64 of `{"rt": …, "hid": …, "pnc": …}`. `pnc` holds the library's credentials object exactly as the library reported it, serialised with the rest of the wrapper.

The client relies on only two members:
- `config`: its presence means the stored credentials are complete and may be reused;
- `fcm.token`: the FCM registration token sent to Ring.

All other members are library-defined. Most likely they are GCM/Android check-in ids, a security token, Firebase installation data and the push-encryption key pair and auth secret, but this was not determined from this repository.

How the wrapper changes when `pnc` changes:
1. Set `pnc` to the new credentials, keeping `rt` and `hid`.
2. Re-encode the wrapper.
3. If the encoded string differs from the current one, emit the token-updated event, which rewrites config.json (1.2).

`pnc` can only be set once a refresh token exists. Any later OAuth refresh keeps `pnc` and replaces only `rt`.

Compatibility notes for a port that implements its own FCM client:
- **Reusing a wrapper from homebridge-ring:** the existing `pnc` is only useful if the port can read the library's format. Otherwise it can ignore it and register again: the new token simply replaces the old one at Ring through the PATCH in 11.2.
- **Writing its own credentials:** the port should store them in a shape the original will not try to reuse. Either leave out `config`, or keep them under a different key so `pnc` is preserved for moving back.
