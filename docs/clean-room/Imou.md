# IMOU: functional specification (clean room)

## 0. Provenance

Written by the spec writer; contains **no source code**. Everything below is a description, in the spec writer's own
words, of the behaviour observed in the sources listed here. Method names, URLs, JSON keys, error codes, ability
strings, message types and the signing rule are reproduced exactly because they are interfaces. Nothing from the
repositories was installed or run; they were read as data.

Labels used throughout:

- **[A]** the HA custom integration `imou_life` by user2684 together with its library `imouapi` (same author).
- **[O]** IMOU's own (official) Home Assistant integration and its library `pyimouapi` (current, 2026).
- **[D]** `homebridge-dahua-alerts` (the local Dahua event stream).
- **Recommendation** marks what comes from the spec writer, not from a source.

| Id | Repository | Commit read | Version | Licence and copyright line |
|---|---|---|---|---|
| A1 | https://github.com/user2684/imouapi | `e559f86d8d85d18b5f3c00722f6294e264af1c7e` (2024-01-27) | 1.0.15 | MIT. `Copyright (c) 2022, user2684` |
| A2 | https://github.com/user2684/imou_life | `a1f09c3a26ab7a4b089ad956288b6617cf6d00eb` (2025-06-06) | 1.0.16 (requires imouapi 1.0.15) | MIT. `Copyright (c) 2021 user2684` |
| O1 | https://github.com/Imou-OpenPlatform/Py-Imou-Open-Api (PyPI `pyimouapi`) | `7caff29ba343e4d929c5d919adcc6547f74df847` (2026-10-21) | 1.4.4 | MIT. `Copyright (c) [2024] [IMOU]` (brackets as written) |
| O2 | https://github.com/Imou-OpenPlatform/Imou-Home-Assistant | `f32cd9fa92e89e7b577d1b6da8d3af55d31c4b72` (2026-10-21) | 1.4.4 (requires pyimouapi 1.4.4) | MIT. `Copyright (c) 2024 IMOU` |
| D1 | https://github.com/kushagharahi/homebridge-dahua-alerts (npm `homebridge-dahua-alerts`) | `a9696705dc78dae66023802c4b533a6be625ed56` (2024-05-10) | 1.3.0 | MIT per `package.json` (`"license": "MIT"`, author Kusha Gharahi). **No LICENSE file in the repository**, so no copyright line exists; credit "Kusha Gharahi". |

All four are MIT: a port may follow them; THIRD-PARTY-NOTICES.md should list A1, A2, O1, O2 (and D1 if the local event
stream is implemented) with the copyright lines above.

**No Homebridge plugin for IMOU exists.** The npm registry search for "homebridge imou", "imou" and "imoulife" (on
2026-11-04) returned no IMOU plugin; only Dahua plugins (`homebridge-dahua-alerts`, `homebridge-dahua-alarm`,
`homebridge-dahua-ultimate`, `homebridge-dahua-vto`). So there is no Homebridge block to stay compatible with, and the
platform name is ours to choose (section 2).

A2's README says the author stopped developing it (based on IMOU's 2021 documentation) and points to O2. **Where A and
O disagree, O is the current behaviour of the cloud and should win**; A is still useful for methods O dropped
(`getAlarmMessage` polling, HLS live) and for its fixtures.

The IMOU Open Platform's own documentation (open.imoulife.com/book/...) was not fetched; the sources cite pages of it.
Facts below are as the sources implement them.

## 1. Scope

### 1.1 Devices

The IMOU Open Platform ("Lechange"/"easy4ip" cloud, Dahua's consumer brand) holds the devices bound to the IMOU Life
account of the developer who made the app (and devices shared with it, [A] `type: "bindAndShare"`). Device kinds:

- **IPC** (single-lens cameras, the target): `catalog` `"IPC"` [A]; [O] calls a device "IPC" when `channelNum == 1` or
  `multiFlag` is true.
- **Multi-lens cameras and NVRs**: one device, several channels; [O] makes one camera per channel.
- **Doorbells** (ability `CallAbility`), battery cameras (abilities `Dormant`, `Electric`).
- **IoT devices** (a `productId` is present: plugs, bulbs, sensors, gateway accessories) are driven by a "thing model"
  of numeric refs (`getIotDeviceProperties`, `iotDeviceControl`, refs such as `"14800"`). **Out of scope** for this
  plugin (section 10). A device with a `productId` must be skipped (or listed as unsupported) by the first version.

The PaaS camera path (no `productId`, `accessType` `"PaaS"`) is the scope.

### 1.2 Abilities (capability strings)

A device and each of its channels carry a comma-separated `ability` string (A: `ability` in `deviceBaseDetailList`; O:
`deviceAbility` per device and `channelAbility` per channel in `listDeviceDetailsByPage`). Strings are case-sensitive.
The ones this plugin uses (meanings paraphrased from A1's table, which cites IMOU's FAQ page `faq/ability.html`):

| Ability | Meaning | Used for |
|---|---|---|
| `AlarmMD` | motion detection alarm | motion sensor; motion-detect switch |
| `MobileDetect` | "mobile detection" (merged with PIR) | motion-detect switch ([O]) |
| `HeaderDetect`, `AiHuman`, `SMDH` | human detection | human-detect switch ([O] uses all three) |
| `VideoMotionSMD` | motion events include humans and vehicles | informative |
| `AlarmPIR`, `AlarmPIRV2`, `AlarmPIRV3`, `AlarmPIRV4` | PIR (V2, V3: with an enable switch) | PIR switch ([O]: V2, V3) |
| `CloseCamera` | the camera can be closed (privacy mode) | privacy switch |
| `WhiteLight`, `ChnWhiteLight` | white light (spotlight) | light |
| `WLV2` | white light without brightness | informative |
| `LinkageWhiteLight` / `WLM` | white light on alarm | optional switch ([A] derives `Linkagewhitelight` from `WLM`) |
| `Siren` | siren | siren switch |
| `LinkageSiren` | siren on alarm | optional switch |
| `SLAlarm` | sound and light alarm | informative |
| `PT`, `PTZ`, `PT1`, `PT2` | pan/tilt(/zoom) | PTZ (optional, section 6.6) |
| `NVM` | night vision mode | optional |
| `Dormant` | sleeps; wake-up needed | section 7.4 |
| `Electric` | battery | Battery service |
| `LocalStorage`, `LocalStorageEnable` | SD card | optional |
| `Reboot` | restart | optional button |
| `CallAbility` | doorbell call | doorbell |
| `AudioTalk`, `AudioTalkV1` | two-way audio | informative (cloud path; RTSP backchannel not documented) |
| `Auth` | "device end loopback RTSP requires authentication" | local RTSP needs credentials |
| `SCCode` | the device has an SC security code (the "safety code" on its label) | local RTSP password |
| `WLAN`, `WIFI` | Wi-Fi | [A] adds an "online" sensor |

[A] also always adds a pseudo-ability `MotionDetect` (so every device gets a `motionDetect` switch) and derives
`pushNotifications` from `WLAN`.

### 1.3 Switches (enableType strings)

`getDeviceCameraStatus` / `setDeviceCameraStatus` take an `enableType` (IMOU FAQ page `faq/feature.html`). The ones
this plugin uses, exactly: `motionDetect`, `mobileDetect`, `headerDetect`, `aiHuman`, `smdHuman`, `alarmPIR`,
`closeCamera`, `whiteLight`, `linkageWhiteLight`, `siren` ([A] only), `linkageSiren`, `closeDormant` ([A] wake-up),
`breathingLight` (status LED), `abAlarmSound`, `playSound`, `audioEncodeControl`, `frameReverse`, `wideDynamic`,
`smartTrack`. Full list in A1 (about 50 names, e.g. `localRecord`, `infraredLight`, `searchLight`, `ccss`, `ledsw`).

How a switch is offered:

- [A]: for every known enableType, lowercase it and compare with each ability lowercased with a trailing `v<digit>`
  removed (so `AlarmPIRV2` offers `alarmPIR`); offer it once. The first match wins.
- [O] (preferred, explicit table): `motion_detect` from `MobileDetect` or `AlarmMD` (writes/reads enableTypes
  `mobileDetect` **and** `motionDetect`); `close_camera` from `CloseCamera` (`closeCamera`); `white_light` from
  `WhiteLight` or `ChnWhiteLight` (`whiteLight`); `header_detect` from `HeaderDetect` (`headerDetect`), `AiHuman`
  (`aiHuman`) or `SMDH` (`smdHuman`); `alarm_pir` from `AlarmPIRV2`/`AlarmPIRV3` (`alarmPIR`); `linkage_siren` from
  `LinkageSiren`; `linkage_white_light` from `WhiteLight`/`ChnWhiteLight` (`linkageWhiteLight`); `ab_alarm_sound`,
  `audio_encode_control` (`AudioEncodeControl`/`AudioEncodeControlV2`), `frame_reverse`, `wide_dynamic`,
  `smart_track`, `play_sound` likewise. Buttons: `restart_device` from `Reboot`; `siren_start`/`siren_stop` from
  `Siren`; PTZ directions from `PT` or `PTZ`.
- [O] ability matching rule for a channel: the ability applies when it is in the channel's `channelAbility`, **or**
  the device is an IPC, the channel is `"0"`, and the ability is in the device's `deviceAbility`. A device without
  channels uses its device abilities.

## 2. Configuration interface

Platform name: **`Imou`** (Recommendation; no Homebridge plugin exists). Plugin type: platform, singular is not
required (two blocks may hold two developer accounts, which A2's README recommends to get past the 5-device licence
limit, section 7.2). Ids are prefixed `Imou:`.

Setup (Homeswift's Setup, GLOSSARY.md): the account's Authorization is `apiKey` (an App Id and App Secret from the
developer console, https://open.imoulife.com/consoleNew/myApp/appInfo, "My App" → "App Information" → Edit, per A2's
README) plus the region. `discover()` lists the account's cameras (section 4.2). Each camera's own Authorization is
`deviceCode` (the safety code) when the local path is wanted, `none` when cloud-only.

Block keys (all Recommendation; names in the style of O2's options):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | `"Imou"` |
| `name` | string | `"Imou"` | Log name |
| `appId` | string | — | Developer App Id. Not a secret by itself ([O] leaves it unmasked in logs: "it names the account but cannot authenticate on its own"); [A] masks it. Recommendation: mask it in logs, store it in the block. |
| `appSecret` | string | — | **Secret** (key name matches the secret pattern; sealed in the vault). |
| `region` | string | `"sg"` | One of `sg`, `eu`, `na`, `cn` → API host (section 3.1). |
| `apiUrl` | string | none | Overrides the host: a host name (`openapi-fk.easy4ip.com`) or a full base URL (`https://openapi.easy4ip.com/openapi`, [A]'s form). |
| `pollingInterval` | integer s | `300` | State poll (O2: 300, range 30–900; A2: 900). |
| `alarmPollInterval` | integer s | `0` (off) | Cloud `getAlarmMessage` poll for motion, when neither local events nor push is available (section 5.1). Min 30. |
| `snapshotWait` | number s | `3` | Wait after `setDeviceSnapEnhanced` before downloading (O2: 3, range 1–9; A1: 1.5). |
| `wakeWait` | number s | `4` | Wait after waking a dormant device (A1: 4). |
| `dormantRetryWait` | integer s | `5` | Wait before retrying a write to a sleeping device once (O2: 5, range 5–60). |
| `resolution` | `"HD"`/`"SD"` | `"HD"` | Cloud live stream (`streamId` 0/1). |
| `ptzDuration` | integer ms | `500` | One PTZ step (O2: 500, range 100–10000). |
| `push` | object | absent | Cloud event push (section 5.2): `{ "enabled": false, "callbackUrl": "...", "types": ["alarm","deviceStatus"] }`. Off by default. |
| `devices` | array | `[]` | Per-camera options keyed by `deviceId` (written by the bridge as Accessory Settings in `_accessories`, by Device Id). |

Per-camera (`devices[]` / Accessory Settings), Recommendation:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `deviceId` | string | — | The cloud serial (e.g. `8L0DF93PAZ55FD2`), the Device Id. |
| `channelId` | string | all channels | Limit to one channel of a multi-lens device. |
| `host` | string | none | Local IPv4/host name of the camera. With it, live video, snapshots and motion events go local. |
| `rtspPort` | integer | `554` | The cloud's `deviceBaseDetailList` also reports `rtspPort` and `httpPort` (fixture: `"554"`, `"80"`). |
| `httpPort` | integer | `80` | For the Dahua CGI (section 5.3). |
| `username` | string | `"admin"` | Local user. |
| `safetyCode` | string | — | **Secret**: the safety code printed on the label (ability `SCCode`), which IMOU devices use as the local `admin` password unless changed. Kept in the vault through Setup. |
| `localEvents` | boolean | `true` when `host` set | Use the Dahua event stream for motion. |
| `motionTimeout` | integer s | `15` | Hold time when an event has no "stop" (O2's `MOTION_OFF_DELAY` 15). |
| `privacySwitch`, `lightSwitch`, `sirenSwitch`, `motionDetectSwitch`, `statusLightSwitch` | boolean | `true` when the ability exists | Expose those services. |
| `videoConfig` | object | — | Passed to the shared FFmpeg camera stack as IP Cameras' `videoConfig` (maxWidth, vcodec, audio, …), Recommendation. |

## 3. Cloud authentication and signing

### 3.1 Hosts and URL

- [O] hosts by region: `sg` → `openapi-sg.easy4ip.com` (default), `eu` → `openapi-fk.easy4ip.com`, `na` →
  `openapi-or.easy4ip.com`, `cn` → `openapi.lechange.cn`. The region must match the portal where the app was made
  (O2 README).
- [A] default base `https://openapi.easy4ip.com/openapi` (no region), user-editable.
- Request URL: `https://<host>/openapi/<method>` ([O]: `"https://" + host + "/openapi/" + method`; [A]: base + `/` +
  method, which gives the same with its default). Method names are case-sensitive camelCase (`accessToken`,
  `deviceBaseList`, …).
- **Regional redirect** [O]: the `accessToken` response may carry `currentDomain` (fixture:
  `"https://openapi-fk.easy4ip.com:443"`). [O] adds `https://` if no scheme, parses it, and from then on uses its
  network location (host and port, here `openapi-fk.easy4ip.com:443`) as the host for every request. [A] ignores it.
  Recommendation: follow [O], keep the redirect in memory only, and log the new host once.

### 3.2 Request

Every call is `POST`, header `Content-Type: application/json` ([O] also sends `Client-Type: HomeAssistant` on the
session it creates; Recommendation: `Client-Type: Homeswift` is harmless, or omit). Body, a JSON object:

```
{
  "system": { "ver": "1.0", "sign": "<md5 hex>", "appId": "<appId>", "time": <unix seconds, JSON integer>, "nonce": "<nonce>" },
  "params": { ...method parameters..., "token": "<accessToken>" },
  "id": "<request id string>"
}
```

- `ver` is the string `"1.0"`.
- `time` is the current Unix time in **seconds**, rounded to an integer, a JSON **number** (not a string).
- `nonce`: a fresh random string per request. Both sources use a URL-safe Base64 token of 32 random bytes (43
  characters, alphabet `A–Z a–z 0–9 - _`). Any unique printable string without commas or colons works
  (Recommendation: 32 random bytes, URL-safe Base64 without padding, or a UUID).
- `sign` = lowercase hex of **MD5** over the UTF-8 bytes of:

  `time:<time>,nonce:<nonce>,appSecret:<appSecret>`

  exactly: the literal `time:`, the same decimal integer as `system.time`, a comma, the literal `nonce:`, the nonce, a
  comma, the literal `appSecret:`, the secret. No spaces, no trailing newline, the App Id is **not** in it, the params
  are **not** signed. (Both A1 and O1 build it this way, citing `open.imoulife.com/book/http/develop.html`.)
- `id`: a request id string. [A] a random integer 1–10000 as a string; [O] a UUID v4 string. Responses echo it
  (fixtures show both kinds). Not checked by either source.
- `params.token`: the access token, added to every call **except** `accessToken` itself. `accessToken` is sent with
  `params` `{}`.

### 3.3 Response

HTTP 200 with a JSON body:

```
{ "result": { "code": "0", "msg": "Operation is successful.", "data": { ... } }, "id": "<echo>" }
```

- `result.code` is a **string**; `"0"` is success. `data` may be absent or `null` on success (treat as `{}`).
- [O] HTTP status handling: ≥500 → connection failure (temporary); any other non-200 → request failure; non-JSON → request
  failure; missing `result` or `result.code` → malformed. [A] treats any non-200 as an API error and requires
  `result.code` and `result.msg`.
- [O] timeout 30 s per request; [A] 10 s. [O] caps concurrent connections at 10 per host.

### 3.4 Access token

- `accessToken` → `data.accessToken` (fixture `"At_0000ea19a5687d45443399c8b8814e4a"`), `data.expireTime` (seconds
  remaining; fixture `190805`, about 53 h; O's tests use `3600`), optionally `data.currentDomain`.
- [A] requires both `accessToken` and `expireTime`; stores `expireTime` but never acts on it; reconnects only when a
  call answers `TK1002`. Up to 3 connection attempts before giving up ("not connected").
- [O] fetches lazily before the first call; concurrent callers share one fetch (a lock, and a re-check after it); on
  `TK1002` it refreshes only if the rejected token is still the current one, then **retries the call once**; a second
  `TK1002` is an error.
- Recommendation: do both: refresh when less than 5 minutes of `expireTime` remain, and on `TK1002` refresh once and
  retry once. The token is a secret (memory only; no need to persist, a restart fetches a new one).

### 3.5 Error codes

| Code | Meaning (source) | Handling |
|---|---|---|
| `0` | success | |
| `TK1002` | "Token expired or does not exist, please get token again." (A fixture) | refresh token, retry once |
| `SN1001` | invalid sign (O: `ERROR_CODE_INVALID_SIGN`) | App Id/Secret refused → Authorization refused (Setup "refused account"); also what a wrong clock gives (Recommendation: say "check App Secret and the system clock") |
| `SN1004` | invalid app (O) | Authorization refused |
| `OP1008` | "app ID id null." (A fixture; A maps it to invalid appId/appSecret) | Authorization refused |
| `OP1009` | "No right, cannot operate." (A fixture) | device not in this account/not authorised; mark that device unavailable |
| `DV1007` | device offline (O) | mark offline; for a sleeping device, retry once (7.4) |
| `DV1030` | device sleeping (O) | wake/retry once |
| `DV1026` | (O lists it among dormant-retryable codes, meaning not stated) | retry once if sleeping |
| `DV1049` | no storage medium (O) | storage sensor "no card" |
| `LV1001` | live already exists (A, O) | not an error for `bindDeviceLive` |
| `LV1002` | live does not exist (A, O) | not an error for `getLiveStreamInfo` (means "none yet") |
| `FL1001` | "Insufficient remaining available licenses" (A2 README) | the account's device licences (5 on a free account) are used up; log once per device with that advice |
| other | e.g. `"200"` "Error." (A fixture) | error with `<code>: <msg>` |

## 4. API methods

Parameters are inside `params` (plus `token`). Types matter: where a source sends a string, send a string. `channelId`
is a **string** (`"0"` for the first channel); [O] passes the channel's id as the device list gave it (converted to a
string when the list gave an integer). Responses below are `data`.

### 4.1 `accessToken`

Section 3.4.

### 4.2 Device list

**`listDeviceDetailsByPage`** [O, preferred]. Params: `page` (integer from 1), `pageSize` (integer; [O] 10 for full
listing, 50 for summaries). Data: `deviceList` (array), `count`. [O] pages while a page holds `pageSize` or more
entries (it counts the entries rather than trusting `count`). Each device:

| Key | Type | Notes |
|---|---|---|
| `deviceId` | string | serial |
| `deviceName` | string | name in IMOU Life |
| `deviceStatus` | string | `"1"` online, `"0"` offline (O's summary type); treat others as in `onLine` (4.3) |
| `brand` | string | e.g. `"Imou"` |
| `deviceModel` | string | optional (default "unknown"), e.g. `"IPC-A1"` |
| `deviceAbility` | string | CSV; `null` or `""` → none |
| `deviceVersion` | string | firmware |
| `channelNum` | integer | 1 for a single-lens camera |
| `multiFlag` | boolean | multi-lens device |
| `accessType` | string | `"PaaS"` for cameras |
| `channelList` | array or `null` | `{ channelId (string or integer), channelName, channelStatus, channelAbility (CSV or null) }` |
| `productId`, `parentProductId`, `parentDeviceId` | string | present for IoT devices → skip |

**`deviceBaseList`** [A]. Params: `bindId` `-1`, `limit` `50`, `type` `"bindAndShare"`, `needApInfo` `true`. Data:
`count`, `deviceList[]` of `{ deviceId, bindId, channels: [{ channelId, channelName }], aplist }`. (No paging beyond
50.) `deviceOpenList` takes the same params and answers the same shape.

**`deviceBaseDetailList`** [A]. Params: `deviceList: [{ "deviceId": "<id>", "channelList": "0" }]` (channelList a
string). Data `deviceList[]`, A reads the first: `catalog` (`"IPC"`), `version` (firmware, `"2.680.0000000.25.R.220527"`),
`name`, `deviceModel` (`"IPC-C22C"`), `ability` (CSV), `channels[]` (`channelId`, `channelName`, `ability`,
`status` `"online"`, `cameraStatus` `"off"`, `picUrl`, …), `status` (`"online"`), `brand` (`"easy4Ip"`),
`httpPort` `"80"`, `rtspPort` `"554"`, `privatePort` `"37777"`, `tlsPrivatePort` `"443"`, `encryptMode`,
`accessType` `"PaaS"`, `playToken` (**secret**, masked by A), `shareStatus` (`"owner"`). Missing `version`, `name`,
`deviceModel` or `ability` makes A reject the device. `deviceOpenDetailList` is the same.

**`listDeviceAbility`** [A, defined but unused]: same params; data `deviceList[]` of `{ deviceId, ability, channels:
[{ channelId, channelAbility }], aps }`.

Recommendation: `listDeviceDetailsByPage` for discovery and the device's name, model, firmware and abilities;
`deviceBaseDetailList` only to read `rtspPort`/`httpPort` as defaults for a local camera. Rediscover on a slow clock
(O2: every 600 s) separate from the state poll.

### 4.3 `deviceOnline`

Params: `deviceId`. Data: `deviceId`, `onLine` (string), `channels: [{ channelId, onLine }]`. Values: `"0"` offline,
`"1"` online, `"3"` upgrading ([O]), `"4"` sleeping/dormant. [O] uses the channel's `onLine` for a channel, the
device's when there is no channel list, and **offline** when the channel is missing or the value absent; an unknown
value is logged and taken as offline. [A] counts `"1"` and `"4"` as online (reachable).

### 4.4 `getDeviceCameraStatus` / `setDeviceCameraStatus`

- get params: `deviceId`, `channelId` (`"0"`), `enableType`. Data: `{ "enableType": "headerDetect", "status": "on" }`.
  `status` is `"on"`/`"off"`; [O] also accepts `1`/`0`, `"1"`/`"0"` and booleans.
- set params: `deviceId`, `channelId`, `enableType`, `enable` (JSON **boolean**). Data empty.
- [O]: a switch backed by several enableTypes (motion detect: `mobileDetect` and `motionDetect`) is on when any read
  says on; off only when every read answered off and none failed; a failed read never turns an on switch off. A write
  goes to all of them; it fails only when all writes fail.
- [A] does not read the `siren` enableType: it notes the siren's state cannot be read and keeps the last written state.

### 4.5 `modifyDeviceAlarmStatus` [O]

Params: `deviceId`, `channelId`, `enable` (boolean). [O] uses it to **write** the motion-detection switch (reads still
go through `getDeviceCameraStatus` with `mobileDetect`/`motionDetect`). [A] writes `motionDetect` with
`setDeviceCameraStatus` instead. Recommendation: [O]'s way, falling back to `setDeviceCameraStatus` `motionDetect` on
an error other than auth.

### 4.6 `getAlarmMessage` [A]

Params: `deviceId`, `count` `"10"` (string), `channelId` `"0"`, `beginTime` and `endTime` as `"YYYY-MM-DD HH:MM:SS"`
(local time; A uses now − 30 days and now + 1 day). Data: `alarms[]` newest first, `count`, `nextAlarmId`. An alarm:
`alarmId` (string), `msgType` (`"human"`, `"videoMotion"`, …), `type` (numeric string code, e.g. `"120"`), `time`
(Unix seconds, integer), `localDate` (`"2022-09-25 17:36:33"`), `deviceId`, `channelId`, `name`
(`"<deviceId>-1"`), `thumbUrl`, `picurlArray[]`, `token` (secret). [A] requires `time`, `type`, `msgType`, `deviceId`
in the newest alarm.

### 4.7 Snapshot: `setDeviceSnapEnhanced`

Params: `deviceId`, `channelId`. Data: `url` (an HTTPS object-storage URL with a signed query string, e.g. an Aliyun OSS
URL with `Expires`, `OSSAccessKeyId`, `Signature`). The camera takes and uploads the picture after the call: wait
`snapshotWait` (A 1.5 s; O 3 s), then `GET` the URL without credentials. [O] caps the download at 8 MiB and a 120 s
budget; [A] uses its 10 s timeout. A1 documents a rate of one capture per second. Missing `url` is an error. **The URL's
query is a credential**: never log it ([O] strips queries from logged URLs; [A] masks `picUrl`/`thumbUrl`).

### 4.8 Live video (cloud)

**`getStreamUrl`** [O, current]: params `deviceId`, `channelId`, `streamId` (integer: `0` HD main stream, `1` SD sub
stream), `productId` only for IoT devices. Data: `url`, a short-lived cloud **RTSP** URL (test fixture shape:
`rtsp://<proxy host>:8554/<path>`). [O] fetches a fresh one for every viewing session (it "works for the owner and
sharers", unlike HLS) and drops it about 10 s after the last viewer leaves. Every view consumes the account's
live-view quota (O2 README). Other response fields are not used.

**HLS** [A]: `getLiveStreamInfo` (params `deviceId`, `channelId`) → `streams[]` of `{ streamId (integer), liveToken,
hls (URL), status (string) }`; `LV1002` means none. `bindDeviceLive` (params `deviceId`, `channelId` `"0"`, `streamId`
integer 0/1) creates one → `liveToken`, `streams[{ streamId, hls, coverUrl }]`, `liveType`, `liveStatus`, `job`
(`[{"period":"always","status":true}]`), `coverUpdate`; `LV1001` means it already exists. A picks the stream whose
`streamId` matches the profile, whose `hls` starts with `https://`, and whose `status` is `"1"`. `unbindLive`
(`liveToken`) deletes it; `liveList` (`queryRange` `"1-20"`) lists all. **A's bug**: when `getLiveStreamInfo` returns
streams but none matches, A raises instead of binding a new one (the fixture's streams all have status `"0"`).
Recommendation: do not implement HLS; use local RTSP, else `getStreamUrl`.

### 4.9 Siren, light, privacy

- **Siren** [O]: `sirenStart` / `sirenStop`, params `deviceId` and, for a channel of a multi-channel device,
  `channels: [<channel as integer>]` (omitted for an IPC). No state read. [A] instead uses `setDeviceCameraStatus`
  with `enableType` `"siren"` and `enable` true/false. Recommendation: `sirenStart`/`sirenStop`, falling back to the
  `siren` enableType when the method is refused.
- **White light**: `setDeviceCameraStatus` `whiteLight` (on/off; no brightness via this API).
- **Privacy**: `setDeviceCameraStatus` `closeCamera`: `enable: true` (status `"on"`) **closes** the camera (privacy
  on, lens covered/stream stopped), false opens it.
- **Status LED**: `breathingLight`.

### 4.10 Others (optional)

- `restartDevice` (`deviceId`).
- `getNightVisionMode` (`deviceId`, `channelId`) → `mode` (`"Intelligent"`), `modes` (`["Intelligent","FullColor",
  "Infrared","Off"]`); `setNightVisionMode` (`deviceId`, `channelId`, `mode`). [O] maps lowercase names to the
  capitalised wire values: `intelligent`→`Intelligent`, `fullcolor`→`FullColor`, `infrared`→`Infrared`, `off`→`Off`,
  `lowlight`→`LowLight`, `smartlowlight`→`SmartLowLight`.
- `getDevicePowerInfo` (`deviceId`) → `electricitys: [{ type ("battery"), electric, alkElec, litElec }]`, strings
  (`"89"`). [O] takes `litElec`, else `alkElec`, else `electric`; [A] takes `electric`.
- `deviceSdcardStatus` (`deviceId`) → `status` (`"normal"`); `deviceStorage` (`deviceId`) → `totalBytes`, `usedBytes`
  (integers). `DV1049` = no card.
- PTZ: `controlMovePTZ` params `deviceId`, `channelId`, `operation`, `duration` (ms). Operation numbers: UP 0, DOWN 1,
  LEFT 2, RIGHT 3, UPPER_LEFT 4, BOTTOM_LEFT 5, UPPER_RIGHT 6, BOTTOM_RIGHT 7, ZOOM_IN 8, ZOOM_OUT 9, STOP 10. [A] sends
  both as strings (`"2"`, `"1000"`), [O] as integers. `controlLocationPTZ`: `h`, `v` numbers in [−1, 1], `z` in [0, 1].
  `devicePTZInfo` → `h`, `v`, `z` (strings, `"0.9"`).
- Wake: [O] `wakeUpDevice` params `deviceId`, `url` `"/device/wakeup"`; [A] `setDeviceCameraStatus` `closeDormant`
  `true`.
- `bindDevice` [O] (`deviceId`, `code` = the device's binding/safety code, **secret**): adds a device to the account.
  Not needed (devices are bound in the IMOU Life app).

### 4.11 `getMessageCallback` / `setMessageCallback`

- get: params none → `callbackFlag` (CSV), `callbackUrl`, `status` (`"on"`/`"off"`).
- set on: `status` `"on"`, `callbackUrl`, `callbackFlag` CSV from `alarm`, `deviceStatus`, `iot`, `numberstat`,
  `faceAnalysis` (default `"alarm,deviceStatus"`), `basePush`. set off: `status` `"off"`, `basePush`.
- `basePush`: O1's library default is `"2"`, O2 always sends `"1"` with the comment that it keeps pushes going to the
  IMOU app too. [A] does not send it. Meaning of `"2"` is not stated. Recommendation: `"1"`.
- The callback is **global to the developer account**, not per device (A2 README); changing it is limited to **10 times
  a day** and may take up to 5 minutes to apply (A2 README).

## 5. Events

Three sources, best first (Recommendation): local Dahua event stream (real time, no quota, needs `host` and the safety
code), cloud push (real time, needs an internet-reachable URL), cloud alarm polling (delayed, costs quota).

### 5.1 Cloud alarm polling [A]

Every poll, `getAlarmMessage` for the device; take `alarms[0]`; its time (A converts `time` to an ISO UTC string) is
compared with the one stored at the previous poll: different → motion **on** for this poll, same (or first poll) →
**off**. So a motion shows as one poll interval of "on", and an alarm older than the start is never reported. A2 runs
this at the 15-minute poll, or more often by pressing a "refresh alarm" button (README suggests every 30 s, noting the
API's limit of **20,000 calls a day**). Recommendation: compare `alarmId` (and `time`) rather than only `time`; report
each new alarm as a motion pulse of `motionTimeout` seconds instead of "until the next poll"; one call per camera per
`alarmPollInterval`; only alarm `msgType`s from the motion set below count.

### 5.2 Cloud push [O, A]

Enable with `setMessageCallback` (4.11). The cloud then `POST`s JSON to `callbackUrl`. The receiver must answer
`200` (body `ok`) immediately, even for bodies it ignores, and process afterwards (O2 acks first "so Imou does not stop
pushing"). No signature or authentication header is described in either source: the only protection is an
unguessable path (O2 uses HA's webhook id; it redacts the last path segment when logging). A2 reports the cloud's
requests are "malformed" enough that HA rejects them without a reverse proxy in front (cause not stated).

Payload fields ([O] normalisation; first present wins):

| Meaning | Keys |
|---|---|
| device | `did`, `deviceId`, `msgDeviceId` |
| channel | `cid`, `channelId`, `msgChannelId` (scalars only), `channels` (scalar), `content.monitor.channel` |
| type | `msgType` |
| product (IoT) | `pid` |
| time | `time`, `localTime`, `utcTime` (seconds, milliseconds when > 10¹², or text) |
| name | `cname`, `dname` |
| alarm id | `id`, `alarmId` |
| picture | `thumbUrl`, `picUrlArray`, `picUrlArr`, `picUrl` (string or list; pictures are **encrypted**, O2 decrypts with IMOU's native library; skip) |
| other | `token` (secret), `desc`, `content` |

A missing channel means channel `"0"`. Pushes with a `pid` other than `iotEvent`/`iotProperty` are ignored by O.

`msgType` mapping (O2), compared case-insensitively after removing a leading `e_`:

- **Motion on**: `videomotion`, `human`, `mobiledetect`, `motiondetect`, `alarmpir`, `pir_alarm`, `aiperarea`,
  `aiperareaalarm`, `multivideoaiperarea`, `multivideoaiperareaalarm`, `smartmixdetect`, `crosslinedetection`,
  `areadetect`, `areadetectalarm`, `multivideoareadetect`, `multivideodetectalarm`. Held on for 15 s (restarted by each
  new push), unless an off arrives.
- **Motion off**: `clearalarmpir`, `pir_cleared`.
- **Doorbell press**: `callbellevent`, `callevent`, `callquickevent`, `callsupplyevent`, `calleventcall`, and the
  numeric `309100`, `309200`, `311000`.
- **Siren**: on `sirenon`; off `sirenoff`, `siren_alarm_cleared` (on held 15 s).
- **Status, not alarms** (O's non-alarm list): `online`, `offline`, `sleep`, `openCamera`, `closeCamera`,
  `whiteLightOn`, `whiteLightOff`, `low_battery_alarm`, `electricity`, `upgrading`, `UpgradeSuccess`, `upgradeFail`,
  `bindDevice`, `unbindDevice`, `deviceShare`, `changeDevName`, `home`, `leave`, `no_defend`, storage ones, and others.
  Recommendation: use `online`/`offline`/`sleep` for reachability, `openCamera`/`closeCamera` for the privacy switch,
  `whiteLightOn`/`whiteLightOff` for the light; trigger a state poll of that device on any of them.
- A2's sample automation treats `videoMotion`, `human` and `openCamera` as worth a refresh.

In Homeswift (Recommendation): off by default. When on, the receiver is a route of the web UI server (or the plugin's
`handleWebRequest`), under a path with a random 32-byte token generated at Setup and kept in the vault; it must accept
the request without a cookie or `Origin` (like the OAuth exception) and only on that path, rate-limited, body capped
(e.g. 64 KiB), and the plugin must call `setMessageCallback` only when the URL or flags change (10 changes a day).

### 5.3 Local Dahua event stream [D] (and Recommendation)

IMOU cameras are Dahua firmware and generally answer Dahua's HTTP CGI on `httpPort` (80) with HTTP Digest
authentication, user `admin`, password the safety code (Recommendation; neither IMOU source uses the CGI, and some
IMOU models or firmwares disable it, so the plugin must fall back cleanly).

[D]'s behaviour:

- `GET http(s)://<host>/cgi-bin/eventManager.cgi?action=attach&codes=[<code>,<code>,...]` with header
  `Accept: multipart/x-mixed-replace`. The brackets and commas are sent literally. [D]'s codes: `VideoMotion`,
  `AlarmLocal`, `VideoLoss`, `VideoBlind` (each enabled in its config). [D] defaults to HTTPS with certificate
  checking off and TLS 1.0 allowed; `useHttp` switches to plain HTTP.
- The first answer is `401` with `WWW-Authenticate: Digest realm="Login to <serial>",qop="auth",nonce="...",opaque="..."`
  (spaces after the commas optional). [D] computes RFC 2617 Digest with `qop=auth`, `algorithm=MD5`, an 8-hex-digit
  nonce count and a random client nonce, and resends. **[D]'s bug**: it puts the URI template with the literal
  `{codes}` placeholder in `uri=` and in HA2 instead of the real request URI; the implementer must use the exact
  request-URI (path and query) sent on the request line. Homeswift's `DigestAuthentication` (HomeswiftNetwork) covers
  this.
- The body is a never-ending multipart stream. Each part: a boundary line (`--myboundary`), `Content-Type: text/plain`,
  `Content-Length: <n>`, a blank line, then a text line `Code=<code>;action=<Start|Stop|Pulse>;index=<n>` optionally
  followed by `;data={...JSON over several lines...}`. Example parts: `Code=VideoMotion;action=Stop;index=0` and
  `Code=VideoMotion;action=Stop;index=5;data={ "SmartMotionEnable" : false }`. [D] parses only lines containing `;`,
  taking `action` and `index`; it ignores `Code` (bug: every code is treated as motion).
- `index` is the zero-based channel: `index=0` is channel 1 in RTSP terms, channelId `"0"` in cloud terms.
- On stream end or error, [D] reconnects after 10 s. Keep-alive, one socket per host.

Recommendation for this plugin:

- Codes: `VideoMotion`, `SmartMotionHuman`, `SmartMotionVehicle`, `CrossLineDetection`, `CrossRegionDetection`,
  `AlarmLocal`, and on doorbells `CallNoAnswered` and `BackKeyLight` (Dahua codes, unverified on IMOU); ask for
  `codes=[All]` only if the camera refuses the list. Map `VideoMotion` and `SmartMotion*` Start → motion on, Stop → off (with `motionTimeout` as a safety
  release when a Stop never comes); a doorbell press from `CallNoAnswered` Start or `BackKeyLight` with data
  `State` 1 (unverified, section 10).
- Parse by `Content-Length` rather than by line, accept `\r\n` and `\n`, ignore `Heartbeat` parts (add
  `&heartbeat=5` to the query and treat 30 s of silence as a dead connection).
- Reconnect with Backoff (1 s → 60 s); a `401` after a Digest answer means a wrong safety code: stop, mark the device's
  Authorization refused.
- Snapshots locally: `GET /cgi-bin/snapshot.cgi?channel=<n>` (n = cloud channelId + 1), Digest auth, answers a JPEG.

### 5.4 Local RTSP (video)

Recommendation (Dahua convention, given in the brief, not in the IMOU sources):
`rtsp://<username>:<safetyCode>@<host>:<rtspPort>/cam/realmonitor?channel=<channelId+1>&subtype=0` (main stream);
`subtype=1` is the sub stream (use it for snapshots via FFmpeg when the CGI snapshot is unavailable, and for HomeKit's
low resolutions). User and password must be percent-encoded in the URL (a safety code is usually 8 upper-case
alphanumerics, but a changed password may not be). ONVIF on port 80 is another route (not specified here).

## 6. HomeKit mapping

### 6.1 Identity

- One accessory per camera channel. Id: `Imou:<deviceId>:<channelId>` (Recommendation; `deviceId` is the stable cloud
  serial, channelId `"0"` for a single-lens camera). O2's registry key is the same pair, `<deviceId>_<channelId>`.
  Never seed from the name, the IP or the region.
- A camera wants its own HAP server: publish with `context.publishExternal` (as IP Cameras does). Category: IP camera,
  or video doorbell when `CallAbility` is present.
- Accessory Information: Manufacturer `Imou` (A uses `"Imou"`; `brand` from the list is `"Imou"` or `"easy4Ip"`:
  Recommendation use `Imou`), Model `deviceModel`, Serial `deviceId`, Firmware `deviceVersion` (or `version`), Name the
  `deviceName` (channel name for an extra lens: `channelName`, which defaults to `<deviceId>-<n>`).

### 6.2 Camera

- Live video: local RTSP through the shared FFmpeg stack (HomeswiftFFmpeg, IP Cameras' `videoConfig` options) when
  `host` and the safety code are set; otherwise `getStreamUrl` (fetched per session, never cached beyond its session).
- Snapshot: local CGI snapshot, else an FFmpeg frame from the local sub stream, else `setDeviceSnapEnhanced` (slow:
  ~3 s, costs quota). HomeKit asks for snapshots often (every ~10 s while the Home app shows the tile): cache a cloud
  snapshot for at least 60 s (Recommendation); never call `setDeviceSnapEnhanced` more than once a second per camera.
- When privacy mode is on (closeCamera on) or the device is offline, answer snapshots with the last picture or an
  error, and refuse streams quickly instead of waiting on FFmpeg.
- HomeKit Secure Video: optional, from the local RTSP stream only (cloud live quota makes it unsuitable).

### 6.3 Motion Sensor

Present when the camera has `AlarmMD`, `MobileDetect`, `HeaderDetect`, `AiHuman`, `SMDH` or any `AlarmPIR*` (O2's
`PAAS_MOTION_ABILITIES` are the motion-detect and human-detect abilities), or when local events are configured.
`MotionDetected` from 5.3, else 5.2, else 5.1. `StatusActive` false while the device is offline. Linked to the camera's
recording when HKSV is on. Recommendation: when no event source is active at all (no host, push off, alarm polling
off), still add the sensor but say in the log and the Settings page that it never triggers.

### 6.4 Switches

- **Privacy** (`closeCamera`, ability `CloseCamera`): a Switch named "Privacy", On = camera closed. When HKSV is
  configured, also drive the CameraOperatingMode service's `HomeKitCameraActive` (Active = privacy off) and keep the two
  in step (Recommendation). Writes go through `setDeviceCameraStatus`.
- **Motion detection** (camera's own alarm arming): a Switch "Motion Detection" when the motion-detect switch exists
  ([O] semantics, 4.4/4.5). Recommendation: a plain switch, not mapped onto a CameraOperatingMode characteristic
  (HomeKit has no exact equivalent of the camera's own alarm arming).
- **Human detection** (`headerDetect`/`aiHuman`/`smdHuman`): optional switch.
- **Status light** (`breathingLight`): the CameraOperatingMode `CameraOperatingModeIndicator` characteristic when that
  service is present, else an optional switch.

### 6.5 Siren and light

- **Siren** (ability `Siren`): a Switch "Siren". On → `sirenStart`; Off → `sirenStop`. The state cannot be read: after
  On, report on and switch back to off after 15 s (O2's `SIREN_OFF_DELAY`) or on a `sirenoff` push. Recommendation:
  mark it a security control (`security: true`) so MCP only changes it through `set_security_accessory`.
- **Spotlight** (`WhiteLight`/`ChnWhiteLight`): a Lightbulb with On only (`whiteLight`); no Brightness (the cloud API
  has none for PaaS cameras). Updated by `whiteLightOn`/`whiteLightOff` pushes and the poll.

### 6.6 Others

- **Doorbell** (`CallAbility`): Doorbell service, `ProgrammableSwitchEvent` single press on a call push or local
  event.
- **Battery** (`Electric`): Battery service, level from 4.10, `StatusLowBattery` below 20 (Recommendation),
  `ChargingState` not supported.
- **PTZ** (`PT`/`PTZ`): HomeKit has none. Recommendation: leave out of HomeKit; expose MCP tools/a plugin page action
  for `controlMovePTZ` with `ptzDuration`.
- Night vision, SD storage, restart: not in HomeKit (optional plugin page/MCP).

## 7. Behaviour

### 7.1 Start-up and polling

1. Fetch the token (3.4); a refused App Id/Secret marks the account's Authorization refused and stops (no retry loop
   beyond Backoff, Recommendation).
2. List devices (4.2), skip IoT devices, build one accessory per selected channel, abilities as in 1.3.
3. Every `pollingInterval`, per device: `deviceOnline`; if online (or sleeping and not battery-critical), read each
   offered switch with `getDeviceCameraStatus` (O2 reads them concurrently; a failure of one does not hide the others),
   battery if `Electric`. [O] skips the reads of an offline device. [A] reads everything at a 15-minute default, and
   for dormant devices wakes them first (expensive on battery; Recommendation: never wake a dormant device just to
   poll it: show its last known state).
4. Rediscover every 600 s ([O]) to notice added/removed devices; removal follows Homeswift's Not in Home/Excluded rules.
5. After a write, set the state optimistically (both sources do) and confirm at the next poll.

### 7.2 Quotas and limits

- The cloud API is limited to **20,000 calls per day** per developer account (A2 README).
- A free developer account controls up to **5 devices**; more answer `FL1001` (A2 README). Remedy: a second IMOU
  account and developer app, or sharing the device to it (A2 README).
- `setMessageCallback` changes: **10 per day** (A2 README).
- Live video and snapshots consume the account's resource quota ("My Resources" in the console; O2 README). Numbers
  not given.
- Budget (Recommendation): at 300 s polling, a camera with 6 switches costs about 7 × 288 ≈ 2,000 calls/day, so 5
  cameras ≈ 10,000; alarm polling at 30 s adds 2,880 per camera. The plugin should estimate its daily calls from the
  configuration, warn above 15,000, count calls per UTC day and back off polling (double the interval) when over 18,000.

### 7.3 Writes

`setDeviceCameraStatus` with a boolean `enable`. On failure, keep the previous state and report the error to HomeKit
(`SERVICE_COMMUNICATION_FAILURE`). Serialise writes per device (Recommendation) to avoid racing toggles.

### 7.4 Dormant (battery) devices

- [A]: before any read or write of a `Dormant` device, `deviceOnline`; if `"4"`, `setDeviceCameraStatus`
  `closeDormant` true, wait `wakeWait` (4 s), recheck; still not `"1"` → warn "failed to wake up" and skip.
- [O]: only for user-initiated writes: if the device's status is sleep and the write fails with `DV1030`, `DV1007` or
  `DV1026`, wait `dormantRetryWait` (5 s) and retry once. `wakeUpDevice` exists for explicit waking.
- Recommendation: [O]'s rule for writes; for a stream or snapshot request to a sleeping device, call `wakeUpDevice`,
  wait, then proceed; never wake on a poll.

### 7.5 Local path failures

If the local RTSP or CGI fails (refused, 401, timeout), fall back to the cloud for that request and retry local on the
next one; after 3 consecutive local failures, log once (without the URL's password) and retry local every 5 minutes.

## 8. Logging and secrets

- Secrets: `appSecret`, the access token (`token` in params, `accessToken` in the response), `sign` (O's note: the MD5
  beside its `time` and `nonce` lets a log reader attack the secret offline), the safety code / local password (also
  `params.code` of `bindDevice`), `playToken`, `liveToken`, any `token` in alarms or pushes, the query string of every
  picture/snapshot URL (`thumbUrl`, `picUrl`, `picurlArray`, the snapshot `url`), the cloud RTSP/HLS URLs, the push
  callback URL's last path segment. RTSP URLs with embedded credentials are logged with the password replaced.
- [A] masks the values of `appId`, `sign`, `token`, `accessToken`, `playToken`, `thumbUrl`, `picUrl` in its debug logs
  of requests and responses; [O] masks `sign`, `params.token`, `params.code`, response `accessToken`, and for pushes
  `token`/`accessToken`/`access_token` and URL queries.
- The safety code is a secret-named key (`safetyCode`) sealed in the vault; the App Secret likewise.
- Logs: one info line per camera added (name, model, deviceId), warnings for refused credentials, `FL1001`, quota,
  failed wake; request/response bodies only at trace level, redacted as above.

## 9. Test vectors

### 9.1 Signature (computed by the spec writer with `md5` and Python's `hashlib`, which agree)

Invented values: appId `lcaa11bb22cc33dd44`, appSecret `a1b2c3d4e5f60718293a4b5c6d7e8f90`, time `1700000000`, nonce
`Xq3vP9-nonce-0001`.

- String to hash (82 bytes): `time:1700000000,nonce:Xq3vP9-nonce-0001,appSecret:a1b2c3d4e5f60718293a4b5c6d7e8f90`
- `sign` = `55dfb1b302fa7e16b04c70224fa9f111`

Request body for `deviceOnline` with token `At_test` and id `"42"` (key order irrelevant):

```
{"system":{"ver":"1.0","sign":"55dfb1b302fa7e16b04c70224fa9f111","appId":"lcaa11bb22cc33dd44","time":1700000000,"nonce":"Xq3vP9-nonce-0001"},
 "params":{"deviceId":"8L0DF93PAZ55FD2","token":"At_test"},"id":"42"}
```

Second vector: `time:1762257600,nonce:abc,appSecret:secret` → `8585679928d99b9b73ba46ec404dbcf6`.

### 9.2 Local Digest (RFC 2617, qop=auth) for the event stream

Challenge `realm="Login to 8L0DF93PAZ55FD2"`, `nonce="211955164"`; user `admin`, password `L2A3B4C5`; request URI
`/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion]`; nc `00000001`; cnonce `0a4f113b`.

- HA1 = MD5(`admin:Login to 8L0DF93PAZ55FD2:L2A3B4C5`) = `a67c39a0a978effee2c8e065f74724a6`
- HA2 = MD5(`GET:/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion]`) = `62ee70f0204ed207d44daabe5f69182f`
- response = MD5(`HA1:211955164:00000001:0a4f113b:auth:HA2`) = `d04e4f238fda0e2aabd2e5f3fa9b08b9`

### 9.3 Sample responses (invented ids, shapes from the sources' fixtures)

`accessToken`:
```
{"result":{"code":"0","msg":"Operation is successful.","data":{"accessToken":"At_0000aaaa","expireTime":190805,"currentDomain":"https://openapi-fk.easy4ip.com:443"}},"id":"14"}
```
→ token `At_0000aaaa`; host becomes `openapi-fk.easy4ip.com:443`.

`listDeviceDetailsByPage` (page 1, pageSize 10):
```
{"result":{"code":"0","msg":"ok","data":{"count":1,"deviceList":[{"deviceId":"TEST000CAM1","deviceName":"Garden","deviceStatus":"1","brand":"Imou","deviceModel":"IPC-F42P","deviceVersion":"2.840.0000000.12.R","channelNum":1,"multiFlag":false,"accessType":"PaaS","deviceAbility":"WLAN,AlarmMD,CloseCamera,Siren,WhiteLight,SCCode,Auth","channelList":[{"channelId":"0","channelName":"Garden","channelStatus":"online","channelAbility":"AlarmMD,HeaderDetect"}]}]}},"id":"a"}
```
→ one camera `Imou:TEST000CAM1:0`, one page (1 < 10); motion sensor, privacy, siren, spotlight; motion-detect switch
(AlarmMD), human-detect switch (HeaderDetect, from the channel). `channelStatus` value form is not confirmed (10).

`deviceOnline`: `{"channels":[{"channelId":"0","onLine":"4"}],"deviceId":"TEST000CAM1","onLine":"4"}` → sleeping.

`getDeviceCameraStatus` (`closeCamera`): `{"enableType":"closeCamera","status":"on"}` → Privacy On.

`getAlarmMessage`, two polls: first `alarms[0]` `{"alarmId":"1001","msgType":"human","type":"120","time":1700000100,"deviceId":"TEST000CAM1","channelId":"0"}` → no motion (first sight), then `alarms[0].alarmId` `"1002"` → motion pulse.

Errors: `{"result":{"code":"TK1002","msg":"Token expired or does not exist, please get token again."},"id":"24"}` →
one refresh then one retry; `{"result":{"code":"SN1001","msg":"..."}}` → Authorization refused, no retry;
`{"result":{"code":"FL1001","msg":"Insufficient remaining available licenses"}}` → device unavailable with advice.

Push: `{"msgType":"videoMotion","did":"TEST000CAM1","cid":"0","time":1700000200,"token":"x"}` → 200 `ok`, motion on
15 s. `{"msgType":"e_human","deviceId":"TEST000CAM1"}` → motion on, channel `"0"`. `{"msgType":"closeCamera","did":"TEST000CAM1"}` → Privacy On (Recommendation).

Local event part: `--myboundary\r\nContent-Type: text/plain\r\nContent-Length:37\r\n\r\nCode=VideoMotion;action=Start;index=0\r\n` → motion on for channel `"0"`; the matching `action=Stop` → off.

### 9.4 Checks worth testing

- Sign string exact (no App Id, integer time identical in sign and body); new nonce per request.
- `TK1002` → exactly one token fetch even with 5 concurrent calls, each retried once; a second `TK1002` fails.
- `currentDomain` redirect applied to the next call's URL.
- Paging stops on a short page, continues on a full one.
- Multi-ability switch aggregation (on if any on; a failed read keeps on).
- Siren auto-off after 15 s; motion hold restarts on a new push.
- IoT devices (with `productId`) skipped.
- Local stream parser across chunk boundaries and with a `data={…}` multi-line block; reconnect after end.
- Logs never contain the secret, token, sign, safety code or a picture URL's query.

## 10. Gaps and hard parts

- **Official API docs not read.** Method parameter types follow the sources; where they disagree (PTZ `operation` and
  `duration` as strings in A, integers in O; `basePush` `"1"` vs `"2"`), the implementer must pick one (O) and accept
  either form in tests. `channelStatus` values in `listDeviceDetailsByPage` (string "online"/"offline" or "1"/"0") are
  not shown by any fixture: accept both.
- **`getStreamUrl` response**: only `url` is known; lifetime, transport (RTSP over TCP?) and whether it needs auth
  are not documented. Treat as valid for one session, start FFmpeg with `-rtsp_transport tcp` (Recommendation).
- **Local CGI on IMOU devices is unverified** by any IMOU source: some consumer models (Ranger, Cue, Bullet Lite) may
  answer `eventManager.cgi`/`snapshot.cgi`, others not, and newer firmwares can disable RTSP until enabled in the app.
  The plugin must detect it at Setup (probe `snapshot.cgi` once) and fall back to cloud events.
- **Safety code as password**: convention from Dahua/IMOU practice (ability `SCCode`, A's "Auth" ability), not stated as
  a rule by the sources. If the user changed the device password in IMOU Life, that is the password.
- **Dahua event codes** beyond `VideoMotion`, `AlarmLocal`, `VideoLoss`, `VideoBlind` ([D]) are Recommendation;
  doorbell local events unverified.
- **Push**: no request signature, payloads "malformed" per A2 (HTTP framing oddities: the receiver should be lenient,
  e.g. accept a body without `Content-Type: application/json`, chunked or not); requires internet exposure the bridge
  does not provide by default; the callback is global per developer account, so two bridges on one account fight
  over it. Pictures in pushes are encrypted (native library): out of scope.
- **Quota numbers** for live and snapshots unknown; the 20,000/day and 5-device figures are from A2's 2021-era README and
  may have changed.
- **IoT thing-model devices** (refs) out of scope; O1's tables (`SWITCH_TYPE_REF` etc.) would be the source for a later
  version.
- **Dormant cameras**: waking costs battery and time (4–5 s); HomeKit's stream start may time out while waking: answer
  the stream request only after the wake completes, within HomeKit's limit, else fail.
- **Multi-lens devices**: one accessory per channel; the `channels: [int]` form for sirens; cloud `channelId` `"0"` vs
  RTSP `channel=1`: off-by-one must be tested.
- **Hard bits in [A] not to copy**: HLS stream selection bug (4.8), first-poll motion always off and motion lasting a
  whole poll interval (5.1), `camera_wait_before_download` option read but discarded (A1 waits 1.5 s regardless),
  waking dormant devices on every poll.
- **[D] bugs not to copy**: Digest `uri` built from the template with `{codes}`, `Code` ignored, line-based parsing.

# IMOU addendum: PTZ, detections, two-way audio (clean room)

Written by the spec writer as a supplement to `Imou.md`. It contains no source code; method names, keys, codes and
strings are quoted exactly because they are interfaces. Labels are those of `Imou.md` §0: **[A]** imouapi/imou_life,
**[O]** Py-Imou-Open-Api/Imou-Home-Assistant, **[D]** homebridge-dahua-alerts (same commits). One new source:

- **[P]** IMOU's public Open Platform documentation at `https://open.imoulife.com/book/…`, read on 2026-11-05. The pages
  read are under `/book/05-api/90.old/…` (legacy methods; each page is marked "Deprecated" and points to the newer
  capability API, but is "kept for existing integrations"), `/book/05-api/01.conventions/02.sign.html`,
  `/book/05-api/05.limit.html`, `/book/05-api/09.push/01.setMessageCallback.html`,
  `/book/03-guides/05.device-events.html` and `/book/04-capabilities/90.legacy/02.feature-flags.html`. These are
  documentation pages, not code. No licence is stated on them; facts (interfaces) are taken, no text is copied beyond
  identifiers.
- **Recommendation** marks what comes from the spec writer.

## 0. Correction to `Imou.md` §3.2: two signing schemes

[P]'s signature page now defines a different `sign` from the MD5 that [A] and [O] send:

- source string: `time:{time},nonce:{nonce},appSecret:{appSecret}` (unchanged; UTF-8; `time` and `nonce` equal to
  `system.time` and `system.nonce`);
- `password` = lowercase hex of SHA-256 of the App Secret's UTF-8 bytes;
- `sign` = standard Base64 (with `=` padding) of HMAC-SHA256 over the source string, **keyed with the 64-character
  lowercase hex `password` string's bytes** (not the raw 32-byte digest);
- `time` is UTC seconds; clock skew must stay within 5 minutes; a nonce must not be reused within 5 minutes (reuse
  gives `SN1005`). [P]'s sample generates a UUID per request.

[P]'s worked example, which the spec writer reproduced with Python's `hashlib`/`hmac`:

| Input | Value |
|---|---|
| time | `1706511734` |
| nonce | `f5a1ae2d-c09c-4d39-a744-83a5c2c653c2` |
| appSecret | `test123456789test123456789` |
| password | `1f2da89b2fab404859f02bcc80e8521bc7a63af3e5b1da5318f7cf7c56836b09` |
| sign | `xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU=` |

Both [A] (2024) and [O] (released 2026-10-21, 1.4.4) still send the MD5 hex form, and [O] is IMOU's own current
library, so the cloud accepts MD5 today. Recommendation: implement both behind one function; send HMAC-SHA256 by
default (the documented form); on `SN1001` from `accessToken`, retry once with MD5 and remember which one worked for
the account (in memory). Both test vectors are in §7.

## 1. PTZ

### 1.1 Cloud: `controlMovePTZ` (move for a duration)

Sources: [A] (`async_api_controlMovePTZ`), [O] (`async_control_device_ptz`, its HA buttons `ptz_up`, `ptz_down`,
`ptz_left`, `ptz_right` and service `control_move_ptz`), [P].

Gated by ability `PT` or `PTZ` ([O] `BUTTON_TYPE_ABILITY`; [P] "PTZ functions require the device to have a PT or PTZ
capability"). [A] additionally documents `PT1` (four directions, no zoom) and `PT2` (two directions only), so zoom
operations must be offered only with `PTZ`, and only left/right with `PT2` (Recommendation from those meanings).

`params` ([P] types; source differences noted):

| Key | Type ([P]) | Required | Meaning |
|---|---|---|---|
| `token` | String | yes | access token |
| `deviceId` | String | yes | serial |
| `channelId` | String | conditional | channel (`"0"` first); [P]: give `channelId` or `targetDevice` |
| `targetDevice` | String | conditional | alternative to `channelId` (not used by any source) |
| `operation` | String | unless speeds given | direction code, below. [A] sends a string (`"2"`); [O] sends a JSON integer (`2`); [P] types it String and its sample sends `"1"` |
| `duration` | Long | yes ([P] table; applies with `operation`) | milliseconds of movement. [A] sends a string (`"1000"`), [O] an integer; [P] sample `1000` (number) |
| `horizontalSpeed` | Double | no | [−1, 1]; pan speed, used **with** `verticalSpeed` **instead of** `operation` ("since API 1.0.16", [P]). No source uses it |
| `verticalSpeed` | Double | no | [−1, 1]; tilt speed |

Operation codes (identical in [A], [O] for the first four, and [P]):

| Code | Meaning | [A] name |
|---|---|---|
| `0` | up | `UP` |
| `1` | down | `DOWN` |
| `2` | left | `LEFT` |
| `3` | right | `RIGHT` |
| `4` | upper left | `UPPER_LEFT` |
| `5` | bottom left | `BOTTOM_LEFT` |
| `6` | upper right | `UPPER_RIGHT` |
| `7` | bottom right | `BOTTOM_RIGHT` |
| `8` | zoom in | `ZOOM_IN` |
| `9` | zoom out | `ZOOM_OUT` |
| `10` | stop | `STOP` |

There is **no speed parameter with `operation`**: speed exists only as the alternative `horizontalSpeed`/`verticalSpeed`
form. Durations: [A]'s service accepts 100–10000 ms (default 1000); [O]'s service and option accept 100–10000 ms
(default 500). Response: no `data`; `result.code` `"0"`. Errors listed by [P] for PTZ: `OP1002` missing parameter,
`OP1003` invalid parameter, `OP1013` total call limit, `OP1014` daily per-interface limit, `DV1007` offline, `DV1009`
busy, `DV1012` insufficient share permission, `DV1019` capability not supported, `DV1020` channel offline, `DV1026`
function not supported, `DV1028` not bound or channel missing (plus `SN1001`, `TK1002`, `OP1009`). A shared or
sub-account token needs permission `Ptz` on resource `cam:<serial>:<channel>`.

Recommendation: send `operation` as a **string** and `duration` as a **number** (matches [P]'s sample); on `OP1003`,
retry once with `operation` as a number (what [O] sends). Serialise PTZ calls per camera; a new move cancels nothing
on the device, so send `10` (stop) before changing direction when a previous move is still within its duration.

### 1.2 Cloud: absolute position and reading it

- `controlLocationPTZ` ([A], [P]): `deviceId`, `channelId` (String, required), `h` (Double, [−1, 1], horizontal), `v`
  (Double, [−1, 1], vertical), `z` (Double, [0, 1]; 0 widest, 1 maximum zoom). No `data`. [A] rejects out-of-range
  values before sending.
- `devicePTZInfo` ([A], [P]): `deviceId`, `channelId` → `data.h`, `data.v`, `data.z` as **strings** (`"0.9"`, `"0.2"`,
  `"0.0"`); [P] gives no ranges for them (presumably those of `controlLocationPTZ`).
- Presets ([O] select `collection_point`, ability `CollectionPoint`; [P] legacy `getCollection`, `setCollection`,
  `turnCollection`, `deleteCollection`, `modifyCollection`): [O] calls `getCollection` (`deviceId`, `channelId`) and
  `turnCollection` (`deviceId`, `channelId`, `name`). The `getCollection` response shape is not documented in this
  addendum's sources (gap).
- [P] daily limit: `controlPTZ` 200,000 per day (the only PTZ line in its limits table).

### 1.3 Local Dahua `ptz.cgi`

**Not covered by any source.** [D] uses only `eventManager.cgi`. Recommendation, from Dahua's general HTTP API
convention and unverified on IMOU firmware: `GET /cgi-bin/ptz.cgi?action=start&channel=<n>&code=<Code>&arg1=0&arg2=<speed 1–8>&arg3=0`
then `action=stop` with the same `code`, Digest auth as for events, `channel` one-based (cloud `channelId` + 1), codes
`Up`, `Down`, `Left`, `Right`, `LeftUp`, `RightUp`, `LeftDown`, `RightDown`, `ZoomTele`, `ZoomWide`. The implementer
must treat this as optional, probe it once, and fall back to the cloud.

### 1.4 HomeKit

HomeKit has no PTZ service (unchanged from `Imou.md` §6.6). Recommendation: no HomeKit service; offer PTZ through the
plugin's page and MCP tools (directions with a duration, absolute position, presets).

## 2. Detections, lights, siren linkage, night vision, other switches

### 2.1 Reading and setting a switch (common)

- Read: `getDeviceCameraStatus` with `deviceId`, `channelId`, `enableType` → `data.status` `"on"`/`"off"` (String,
  [P]) and `data.enableType` echoed. [P]: the `enableType` begins with a lowercase letter.
- Set: `setDeviceCameraStatus` with `deviceId`, `channelId`, `enableType`, `enable` (Boolean). No `data`.
- **Device-level vs channel-level** ([P], both pages): `channelId` is required for a channel-level switch and **must
  be omitted** for a device-level one. [A] always sends `"0"`; [O] always sends the channel's id. Recommendation: send
  `channelId` for channel and "all" scopes, omit it for device scope (table below), and if a device-scope call answers
  `OP1003`, retry once with `channelId` `"0"`.
- Gating rule ([P] feature-flags page): a switch is supported when its `enableType` **with the first letter
  capitalised** appears in the device's ability set (e.g. `closeCamera` ↔ `CloseCamera`). [A]'s rule (compare
  lowercased, ignoring a trailing `V<digit>` on the ability) is equivalent except it also accepts versioned abilities
  (`AlarmPIRV2` → `alarmPIR`). [O] has an explicit table (below), which sometimes differs from the capitalisation rule.
- Errors: `DV1019` capability not supported / `DV1026` function not supported → hide that switch for this device
  (Recommendation); `DV1020` channel offline; others as in `Imou.md` §3.5. A sub-account token needs permission
  `Config` on `cam:<serial>:<channel>`.
- [O] write semantics for switches backed by several enableTypes: write all, fail only if all fail; read: on if any is
  on, off only if all answered off and none failed (`Imou.md` §4.4).

### 2.2 The switches [O] exposes for PaaS cameras

[O]'s Home Assistant switch keys, their enableTypes and the abilities that gate them ([O] `SWITCH_TYPE_ABILITY`), with
[P]'s scope:

| [O] key | enableType(s) | Gating abilities ([O]) | [P] scope | Notes |
|---|---|---|---|---|
| `motion_detect` | `mobileDetect`, `motionDetect` | `MobileDetect`, `AlarmMD` | channel | [O] **writes** it with `modifyDeviceAlarmStatus` (§2.3), reads both enableTypes |
| `header_detect` (human detection) | `headerDetect` / `aiHuman` / `smdHuman` | `HeaderDetect` → `headerDetect`; `AiHuman` → `aiHuman`; `SMDH` → `smdHuman` | channel | one per matching ability; [P] would gate `smdHuman` by `SmdHuman`, [O] uses `SMDH` |
| `alarm_pir` | `alarmPIR` | `AlarmPIRV2`, `AlarmPIRV3` | channel | [A] meanings: V2/V3 have an enable switch; `AlarmPIR`/`AlarmPIRV4` do not |
| `close_camera` (privacy) | `closeCamera` | `CloseCamera` | channel | §5 |
| `white_light` (as an HA light, on/off) | `whiteLight` | `WhiteLight`, `ChnWhiteLight` | all | |
| `linkage_white_light` | `linkageWhiteLight` | `WhiteLight`, `ChnWhiteLight` | channel | [O] gates on the white-light abilities, not on `LinkageWhiteLight`; [A] derives it from `WLM` |
| `linkage_siren` | `linkageSiren` | `LinkageSiren` | all | siren sounds on alarm |
| `ab_alarm_sound` | `abAlarmSound` | `AbAlarmSound` | channel | abnormal-sound alarm |
| `audio_encode_control` | `audioEncodeControl` | `AudioEncodeControl`, `AudioEncodeControlV2` | channel | "Audio recording" in [O]'s English strings; [P] also lists `aecv3` |
| `frame_reverse` | `frameReverse` | `FrameReverse` | (not in [P]'s table) | image flip |
| `wide_dynamic` | `wideDynamic` | `WideDynamic` | channel | WDR |
| `smart_track` | `smartTrack` | `SmartTrack` | all | auto-tracking |
| `play_sound` | `playSound` | `PlaySound` | device | prompt sounds |

[O] also has HA-only switches with no cloud call (`notify_on_alarm`, `local_event_record`), and IoT-ref switches
(`light`, `switch`, `pet_detect`, ref-based variants) that are out of scope. [O] does **not** expose `breathingLight`.

### 2.3 Motion detection write: `modifyDeviceAlarmStatus`

[O], [P]: `deviceId`, `channelId` (String, required), `enable` (Boolean). No `data`. [P] adds: for devices whose
details show an `accessType`, it recommends `setDeviceCameraStatus` for function switches. So the two writes are
alternatives; [O] uses `modifyDeviceAlarmStatus`, [A] uses `setDeviceCameraStatus` `motionDetect`. Recommendation as in
`Imou.md` §4.5.

### 2.4 Status light

- enableType `breathingLight` ([A] switch "Status indicator"; [P] scope **device**, so no `channelId`), gated by
  `BreathingLight`.
- [P] also documents a dedicated legacy pair: `breathingLightStatus` (`deviceId`) → `data.status` `"on"`/`"off"`, and
  `modifyBreathingLight` (not read in detail). Recommendation: use the enableType; fall back to `breathingLightStatus`
  for reading if `getDeviceCameraStatus` answers `DV1019`/`DV1026`.
- [P] lists `inll` ("indicator light linkage", channel) separately; not used by any source.

### 2.5 Siren on demand and lights

- Siren on demand: `sirenStart`/`sirenStop` ([O]) or enableType `siren` ([A]); gated by `Siren` (`Imou.md` §4.9).
- Alarm-linked siren: `linkageSiren` (§2.2). Alarm-linked light: `linkageWhiteLight` (§2.2).
- Other lights in [P]'s table: `infraredLight` (device), `searchLight` (device), `ledsw` (fill light, device). Only
  [A] offers them (generic switches). No brightness in any source for PaaS cameras.

### 2.6 Night vision mode

Gated by ability `NVM` ([A], [O], [P]).

- Read `getNightVisionMode`: `deviceId`, `channelId` ([P]: optional; the device's default channel when omitted) →
  `data.mode` (String) and `data.modes` (array of String, the supported ones).
- Set `setNightVisionMode`: `deviceId`, `channelId` (required), `mode` (String; must be one of the device's `modes`).
- Values ([P], [O]): `Intelligent` (smart), `FullColor`, `Infrared`, `Off`, `LowLight`, `SmartLowLight`; exact case.
  [O] presents lowercase options and maps them back (`fullcolor` → `FullColor`, `smartlowlight` → `SmartLowLight`).
- [O] also knows an IoT variant with a `custom` mode (ref `139700`): out of scope.
- HomeKit: HAP's `NightVision` characteristic is a boolean on the deprecated Camera Control service. Recommendation:
  not in HomeKit; a select on the plugin page. If mapped at all, NightVision on = `Intelligent`, off = `Off`.

### 2.7 Other switches, for completeness ([P] feature-flags table; scope device/channel/all)

`localRecord` (channel), `faceCapture` (channel), `speechRecognition` (device), `smartLocate` (all),
`localAlarmRecord` (channel; depends on motion detection), `regularCruise` (all), `numberStat`, `manNumDec`,
`autoZoomFocus`, `faceDetect` (channel), `localStorageEnable` (device), `hoveringAlarm` (channel), `beOpenedDoor`
(device), `rtFaceDetect`, `rtFaceCompa` (channel), `closeDormant` (device), `heatMap` (channel), `tlsEnable` (device),
`aiHumanCar`, `aiCar` (channel), `openDoorByFace`, `openDoorByTouch` (device), `linkDevAlarm` (channel),
`linkAccDevAlarm` (device), `smdVehicle` (channel), `instantDisAlarm`, `periodDisAlarm` (device), `ccss` (privacy
plan, channel). Recommendation: none of these in HomeKit; at most `smdVehicle` and `aiHumanCar` as optional switches
next to human detection.

### 2.8 HomeKit mapping (Recommendation, extends `Imou.md` §6.4)

| Function | HomeKit |
|---|---|
| Motion detection arming (`motion_detect`) | Switch "Motion Detection" |
| Human detection (`header_detect`) | Switch "Person Detection" (optional) |
| Status light (`breathingLight`) | CameraOperatingMode `CameraOperatingModeIndicator` when that service exists (HKSV), else optional Switch |
| White light (`whiteLight`) | Lightbulb, On only |
| Light on alarm (`linkageWhiteLight`), siren on alarm (`linkageSiren`) | optional Switches, off the default set |
| Siren on demand | Switch "Siren", 15 s auto-off, security control |
| Night vision, WDR, flip, smart tracking, sounds | plugin page only |

Poll cost: each switch is one `getDeviceCameraStatus` call per poll (`Imou.md` §7.2); read only those that are exposed.

## 3. Two-way audio

**Not covered by any source.**

- [A] only lists the abilities `AudioTalk`, `AudioTalkV1` ("support voice intercom"), `TalkV2`, `TalkSoundModify`,
  `TSV1`/`TSV2` (intercom streaming over IMOU's private protocol), `CallByRtsp` (answer/hang up over RTSP); it has no
  intercom call. [O] has none either (its "audio" switch is `audioEncodeControl`, the microphone recording on/off).
  [D] has none.
- [P]'s legacy API list has no talk/intercom method; the only audio methods are `getSoundVolumeSize` /
  `setSoundVolumeSize` (device volume), and doorbell `doorbellCallAnswer`, `doorbellCallHangUp`,
  `doorbellCallRefuse` (door-lock section; not read in detail, they control call state, not audio). The cloud's
  `getStreamUrl` RTSP is receive-only in [O].
- Not documented anywhere read: Dahua's RTSP backchannel (ONVIF `Require: www.onvif.org/ver20/backchannel`) and
  `/cgi-bin/audio.cgi?action=postAudio…`. Recommendation: the first version ships **without** two-way audio
  (HomeKit's microphone button absent: the RTP setup omits return audio). A later version could try the RTSP
  backchannel on the local stream (G.711A, 8 kHz) when `AudioTalk*` is present, verified on a real camera first.

## 4. SD card, restart, push callback (brief)

### 4.1 SD card

- `deviceSdcardStatus` (`deviceId`) → `data.status` (String): `""` no card, `normal`, `abnormal`, `recovering`
  (formatting) ([P]); [A] reads capacity only when `normal`.
- `deviceStorage` (`deviceId`) → `data.totalBytes`, `data.usedBytes` (Long). [P]: may fail with business errors
  `NO_SD_CARD` (status empty) or `DEVICE_SD_EXCEPTION` (abnormal); [O] treats `DV1049` as no medium and
  `totalBytes` `0` as unusable. Gated by `LocalStorage`/`LocalStorageEnable` ([O]). Sub-account permission `Format`
  on `dev:<serial>`. Used % = usedBytes × 100 / totalBytes, integer ([A], [O]).
- HomeKit: none. Plugin page only.

### 4.2 Restart

`restartDevice` (`deviceId`; device-level only, no `channelId`) → no `data`. Gated by `Reboot` ([O]). Sub-account
permission `Config` on `dev:<serial>`. Recommendation: plugin page/MCP action, destructive (confirm), never HomeKit.

### 4.3 Push callback

`setMessageCallback` ([P]): `status` (`on`/`off`, required), `callbackUrl` (public **HTTPS** URL; when `on` the
platform probes it and accepts only an HTTP 2xx, else the call fails with `PARAM_ILLEGAL_VALUE`), `callbackFlag` CSV of
`alarm`, `deviceStatus`, `numberstat`, `faceAnalysis`, `capabilityEvent` ([O] also sends `iot`, not in [P]'s list),
`basePush` (`"1"` also push to the IMOU app, `"2"` do not; default `"2"`). No `data`. Limits ([P]): `setMessageCallback`
10 per day, `getMessageCallback` 10,000 per day. Delivery ([P] guide): `POST` to the URL; answer 2xx (200–399 counts as
success) or repeated failures make the platform **stop posting**; deduplicate by the message's id; for `alarm` and
`deviceStatus` the body has `did`, `cid`, `msgType` (string); for `capabilityEvent`, `msgType` is the event id with
`deviceId` and `outputData`. **No signature or authentication is described.** Other details as in `Imou.md` §5.2.

Other relevant limits ([P], per interface per day): `accessToken` 2,000; `deviceOnline` 100,000; `setDeviceSnap`
100,000; `bindDeviceLive` 10,000. Exceeding one gives `OP1014`; app-level quotas `OP1011`; total limit `OP1013`.
Recommendation: cache the token for its `expireTime` (2,000 token calls a day are easy to burn with a refresh loop).

## 5. Privacy kept in step with HomeKit's Camera Active

What to read:

- The state is the **channel-level** enableType `closeCamera`: `getDeviceCameraStatus` with `deviceId`, `channelId`,
  `enableType` `"closeCamera"` → `data.status`. `"on"` means the camera is **closed** (privacy on, [P]: "privacy
  mask"; [A] "Close camera"), `"off"` means it is open. Write with `setDeviceCameraStatus` `closeCamera`, `enable`
  true to close. Gated by `CloseCamera`.
- [P] lists `ccss` (privacy *plan*, a schedule switch) separately: when `ccss` is on, the camera closes and opens itself
  on a schedule, so the `closeCamera` value can change without a write. Recommendation: poll `closeCamera` every poll
  and also on the push types `closeCamera`/`openCamera` (`Imou.md` §5.2), which [O] classifies as non-alarm status
  messages.
- [A]'s `deviceBaseDetailList` channel has a `cameraStatus` field (`"off"` in the fixture). Its meaning is not stated;
  do not use it for privacy (gap).

Mapping (Recommendation):

- HomeKit's `HomeKitCameraActive` (CameraOperatingMode service, present when the camera has HKSV recording) is the
  inverse: Active (1) = `closeCamera` off; Inactive (0) = `closeCamera` on.
- A write to `HomeKitCameraActive` writes `closeCamera` (inverted); a write to the "Privacy" switch updates
  `HomeKitCameraActive`; a poll or push updates both. Write optimistically, revert both on failure.
- While closed: refuse new streams and recordings, answer snapshots with the last image (or a black frame), keep the
  motion sensor's `StatusActive` false.
- Without HKSV there is no CameraOperatingMode service: the "Privacy" switch alone.

## 6. Gaps

- Which signature form the cloud will require in future (§0); speed-form PTZ (`horizontalSpeed`/`verticalSpeed`)
  untested by any source; the `getCollection` response shape; local `ptz.cgi` and any two-way audio path.
- Device vs channel scope disagreements between [P] (omit `channelId` for device-level switches) and both libraries
  (always send it); both libraries work in practice, so sending `"0"` is evidently tolerated by the cloud.
- [O]'s ability table differs from [P]'s capitalisation rule for `smdHuman` (`SMDH` vs `SmdHuman`) and for
  `linkageWhiteLight` (white-light abilities vs `LinkageWhiteLight`): accept either ability.
- The newer capability API ([P]: `device.capability.list`, `device.property.get`/`set`, `device.service.invoke`,
  `ptz.aim.relative`, `detection.motion.enabled`, `image.night.mode`, `light.indicator.enabled`,
  `storage.local.capacity`, `device.reboot.execute`) is not used by any library and is not specified here. [P] says the
  legacy things-model API is not published for overseas integrations, and the legacy methods above remain documented.

## 7. Test vectors

All ids invented. Same App Id and Secret as `Imou.md` §9.1: appId `lcaa11bb22cc33dd44`, appSecret
`a1b2c3d4e5f60718293a4b5c6d7e8f90`; token `At_test`; serial `TEST000CAM1`. Computed by the spec writer (macOS `md5`
and Python `hashlib`/`hmac` agree).

### 7.1 Signatures

`password` for this secret (HMAC key, its hex text) =
`ff25d2389ab7917a77cc0c3546331401054d53cb7b2edeedb7b4e7742bb5286d`.

| time | nonce | MD5 sign ([A], [O]) | HMAC-SHA256 sign ([P]) |
|---|---|---|---|
| `1700000000` | `Xq3vP9-nonce-0001` | `55dfb1b302fa7e16b04c70224fa9f111` | `/KGDnPf4k0KNIoUMRkEtRBoKUOkWjrLVE0o0BDIymdQ=` |
| `1762300000` | `nonce-ptz-0002` | `7a6b5b38ad6ccd64362550b46107e15f` | `a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk=` |
| `1762300060` | `nonce-cam-0003` | `702096723e475730eab7927aac7470a4` | `iLddnaTOjE9xcTr72RwfBRJifAscu4yd810ozYxTgjs=` |
| `1706511734` | `f5a1ae2d-c09c-4d39-a744-83a5c2c653c2` (secret `test123456789test123456789`) | `fd37b62889e4757c58b8f3bf05fb9976` | `xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU=` ([P]'s own value) |

Source string for row 2: `time:1762300000,nonce:nonce-ptz-0002,appSecret:a1b2c3d4e5f60718293a4b5c6d7e8f90`.

### 7.2 Request bodies

PTZ left for 500 ms (row 2, HMAC form):

```
{"id":"ptz-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk=","time":1762300000,"nonce":"nonce-ptz-0002"},
 "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","operation":"2","duration":500}}
```

PTZ stop: same with `"operation":"10"`. PTZ speed form: `"horizontalSpeed":-0.5,"verticalSpeed":0,"duration":500`
and no `operation`. Absolute: `controlLocationPTZ` params `{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","h":0.5,"v":-0.25,"z":0}`.

Read privacy (row 3, MD5 form):

```
{"id":"cam-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"702096723e475730eab7927aac7470a4","time":1762300060,"nonce":"nonce-cam-0003"},
 "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","enableType":"closeCamera"}}
```
→ `{"result":{"code":"0","msg":"The operation was successful.","data":{"enableType":"closeCamera","status":"on"}},"id":"cam-1"}`
→ Privacy switch On, `HomeKitCameraActive` 0.

Other `params` (signature and envelope as above, each with its own time and nonce):

| Call | `params` (besides `token`) | Expected `data` |
|---|---|---|
| set human detection on | `{"deviceId":"TEST000CAM1","channelId":"0","enableType":"headerDetect","enable":true}` | none |
| set status light off (device scope) | `{"deviceId":"TEST000CAM1","enableType":"breathingLight","enable":false}` | none |
| linkage siren on | `{"deviceId":"TEST000CAM1","channelId":"0","enableType":"linkageSiren","enable":true}` | none |
| motion detection off | `modifyDeviceAlarmStatus` `{"deviceId":"TEST000CAM1","channelId":"0","enable":false}` | none |
| night vision read | `getNightVisionMode` `{"deviceId":"TEST000CAM1","channelId":"0"}` | `{"mode":"Intelligent","modes":["Intelligent","FullColor","Infrared","Off"]}` |
| night vision set | `setNightVisionMode` `{"deviceId":"TEST000CAM1","channelId":"0","mode":"FullColor"}` | none |
| SD status | `deviceSdcardStatus` `{"deviceId":"TEST000CAM1"}` | `{"status":""}` → no card; `{"status":"recovering"}` → formatting |
| storage | `deviceStorage` `{"deviceId":"TEST000CAM1"}` | `{"totalBytes":31254904832,"usedBytes":27553759232}` → 88 % |
| restart | `restartDevice` `{"deviceId":"TEST000CAM1"}` | none |
| callback on | `setMessageCallback` `{"status":"on","callbackUrl":"https://bridge.example.net/imou/AbC123","callbackFlag":"alarm,deviceStatus","basePush":"1"}` | none |

Errors to test: `getDeviceCameraStatus` answering `{"result":{"code":"DV1019","msg":"..."}}` hides the switch;
`controlMovePTZ` answering `OP1003` with a string `operation` is retried once with a number; `OP1014` stops that method
until the next UTC day (Recommendation) and logs once.
