# Reolink: functional specification (clean room)

## 0. Provenance

Written by the spec writer for a clean-room port; **contains no source code**. Behaviour is described in the spec
writer's own words. Interface identifiers (URLs, JSON command and field names, ports, Baichuan message ids, header
bytes, XML element names and the small XML request templates the camera expects) are quoted exactly because they are
the wire interface. Everything labelled **Recommendation** is the spec writer's proposal, not observed behaviour.
Nothing from the sources was installed, built or run; the test vectors in section 9 were computed by the spec writer
from the algorithms described here, with a scratch script and `openssl`.

| Source | What was taken from it | Version / commit | Licence and copyright line |
|---|---|---|---|
| reolink-aio (Python), https://github.com/starkillerOG/reolink_aio | The HTTP JSON client (login, token, batching, retries, abilities, streams, snapshots, light/IR/siren writes), the Baichuan TCP protocol (header, XOR and AES encryption, login, subscription, keepalive, push event parsing), polling fallbacks, battery handling | version `0.22.0` (`setup.py`), commit `2da8b6bdba09e755f1167f32b146c18bd872b050` (2026-11-04) | MIT License, `Copyright (c) 2023 starkillerOG` |
| Reolink "Camera HTTP API User Guide", Version 7, 2022-9 (PDF shipped in reolink-aio's `doc/`) | Request and response shapes of `Login`, `GetDevInfo`, `GetChannelstatus`, `GetAbility`, `GetMdState`, `GetAiState`, `Snap`, `GetWhiteLed`/`SetWhiteLed`, `GetIrLights`/`SetIrLights`, `AudioAlarmPlay`; the short-session (`user=`/`password=`) form; the `rspCode` error table | Version 7, 2022-9 | Reolink's published developer document; no licence stated. Only interface facts are used. |
| Home Assistant core, `homeassistant/components/reolink` (the consumer of reolink-aio) | Polling intervals, how push/polling are combined, battery wake policy, entity choices (which feature becomes which entity), unique-id scheme | commit `c0d99009cbbf71500923a528da89a3bc9e103236` (2026-11-04), requires `reolink-aio==0.22.0` | Apache License 2.0 (Home Assistant authors) |
| homebridge-reolink-doorbell, https://github.com/Ultra-Sack/homebridge-reolink-doorbell | The only maintained Homebridge Reolink plugin found that is a platform: its platform name, options, identity seed and ring throttle. It delegates Baichuan to a library (`@apocaliss92/nodelink-js`) that was not read. | `0.1.0` in `package.json` (npm has 0.5.0), commit `24cbab2b266a8406899feb1636d3014098b3e528` (2026-09-08) | Apache License 2.0, `Copyright 2026 Alex (Ultra-Sack)` |

Searched and not used: npm has **no** package named `homebridge-reolink`. The other npm packages
(`homebridge-reolink-hksv-doorbell`, `homebridge-reolink-control`, `homebridge-reolink-elite-floodlight`,
`homebridge-reolink-camera-siren-and-light`, `@drpollio/...`) are single-purpose; the repository of
`homebridge-reolink-hksv-doorbell` no longer exists. None of them is a Homebridge "Reolink" platform with cameras,
detections and lights, so this plugin is a new platform built on reolink-aio's behaviour, not a port of a Homebridge
plugin.

THIRD-PARTY-NOTICES: the implementation is written from this document, not ported; if the project lists reference
sources anyway, list reolink-aio (MIT, starkillerOG) and homebridge-reolink-doorbell (Apache-2.0) for the config block.

## 1. Scope

Devices, all over the local network (no Reolink cloud):

| Kind | How it appears | Notes |
|---|---|---|
| Standalone wired camera (PoE or Wi-Fi), e.g. RLC-, E1, Duo, TrackMix | One host, channel `0` (a dual-lens camera has stream channels `0` and `1` but one motion channel, see 4.3) | HTTP(S) API + RTSP/RTMP/FLV + Baichuan on TCP 9000 |
| Video doorbell (wired, PoE or Wi-Fi) | Same as a camera; recognised as a doorbell when its model (`typeInfo`/`model`) contains `Doorbell`, or when `GetEvents` reports `visitor.support == 1` | Visitor (button) events come as `visitor` in Baichuan push and in `GetEvents` |
| NVR (`exactType`/`type` = `NVR` or `WIFI_NVR`) and Home Hub (`HOMEHUB`) | One host, channels `0…count-1` from `GetChannelstatus`; only `online == 1` channels are cameras | One login, one Baichuan connection and one event stream for all channels; every request carries the channel |
| Battery camera behind an NVR or Home Hub | A channel of that host, with ability `battery` | Supported (see 7.5): the hub answers HTTP and streams; commands that would wake the camera are limited |
| Battery camera on its own (Argus, Go, etc.) | — | **Out of scope.** These have no HTTP API and reach the network through Baichuan over UDP (P2P-style, `udp_protocol.py` in reolink-aio), a different and large protocol. reolink-aio itself tells such users to put the camera behind a Home Hub or NVR. Log a clear message (7.5). |

Features per channel (each only when the device reports it, section 4.5): live video and snapshots; motion; AI
detections `people` (person), `vehicle`, `dog_cat` (pet), plus `face` and `package` where reported; doorbell press
(`visitor`); floodlight/spotlight (`WhiteLed`); siren (`AudioAlarmPlay`); IR lights (`IrLights`); battery level.

Not in scope: PTZ, zoom/focus, chimes, recordings playback/VOD, firmware updates, privacy mode control, two-way audio,
Reolink cloud, ONVIF event subscription (5.6), smart-AI zones (crossline, intrusion…).

## 2. Configuration interface

There is no Homebridge platform to keep the name of (section 0). **Recommendation:** platform name **`Reolink`**,
singular block, devices listed by host. Devices enter the bridge through Setup (`discover`, `accountAuthorization`,
`authorize`), and the bridge writes Accessory Settings under `_accessories` by Device Id (docs/plugins.md, ADR 0001).

### 2.1 Platform block (Recommendation)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | `"Reolink"` |
| `name` | string | `"Reolink"` | Log name |
| `videoProcessor` | string | `ffmpeg` | FFmpeg executable (same meaning as IP Cameras' option) |
| `devices` | array | `[]` | One entry per host (camera, doorbell, NVR or hub) |

### 2.2 `devices[]` (Recommendation)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | required | IP or host name |
| `username` | string | `admin` | Local Reolink user (an admin user is needed for writes: lights, siren, IR) |
| `password` | string | required | **Secret** (secret-named key: sealed in the vault, masked in logs). Reolink limits: at most 31 characters; only `a-z A-Z 0-9` and `@$*~_-+=!?.,:;'()[]` are known to work in every URL (FLV/RTMP carry it unencoded). Warn otherwise (8). |
| `port` | integer | auto | HTTP(S) API port. Absent: try HTTPS 443, then HTTP 80 (3.4) |
| `useHttps` | boolean | auto | Force HTTPS or HTTP; absent = auto (3.4) |
| `baichuanPort` | integer | `9000` | Baichuan TCP port; replaced by `GetNetPort`'s `mediaPort` when the device reports one |
| `channels` | array of integers | all online channels | NVR/hub: which channels to publish (0-based) |
| `streamProtocol` | `"rtsp"` \| `"rtmp"` \| `"flv"` | `"rtsp"` | Transport FFmpeg reads (4.6). HA's default is `rtsp`; reolink-aio's library default is `rtmp`. |
| `pushEvents` | boolean | `true` | Baichuan TCP push (section 5); `false` = HTTP polling only (5.5) |
| `pollInterval` | seconds | `60` (+10 per camera above 6) | Full state refresh (7.1) |
| `motionPollInterval` | seconds | `5` | Motion/AI/visitor polling while push is not active (5.5) |
| `cameras` | object keyed by channel number as a string | — | Per-channel options below |

Per-channel options (`cameras["0"]`, also usable as Accessory Settings):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | the device's channel name | Display name |
| `motionSensor` | boolean | `true` when motion is supported | Motion Sensor service |
| `aiSensors` | array of `person`, `vehicle`, `pet`, `face`, `package` | every supported type | One Motion Sensor per type (6.3) |
| `doorbell` | boolean | auto (doorbell detected) | Doorbell service |
| `floodlight` | boolean | `true` when supported | Lightbulb |
| `siren` | boolean | `false` | Switch (off by default: a siren in an automation is loud) |
| `irLights` | boolean | `false` | Switch "IR lights" |
| `stream` | `"main"` \| `"sub"` \| `"auto"` | `"auto"` | Which stream answers HomeKit (6.2) |
| `audio`, `recording`, `prebuffer`, `maxStreams`, `vcodec`, `encoderOptions`, `debug` | as IP Cameras' `videoConfig` | as there | FFmpeg and HKSV options, same meaning and defaults |
| `ringThrottleSeconds` | integer | `3` | Ignore repeated visitor events within this window (from homebridge-reolink-doorbell) |

### 2.3 Compatibility with `ReolinkDoorbell` (optional)

homebridge-reolink-doorbell's block: `{"platform": "ReolinkDoorbell", "doorbells": [{"name", "host", "port" (Baichuan,
default 9000), "username" (default "admin"), "password", "channel" (default 0), "ringThrottleSeconds" (default 3)}]}`.
It publishes a **bridged** accessory with only a Doorbell service; identity is the HAP UUID of
`reolink-doorbell-<host>-<channel>`. **Recommendation:** do not register `ReolinkDoorbell`; at most offer a migration
in Setup that copies host/username/password/channel into a `Reolink` device. Keeping its accessory identity is not
useful, since a Reolink camera accessory is a different, external accessory.

### 2.4 Example

```json
{ "platform": "Reolink",
  "devices": [
    { "host": "192.168.1.30", "username": "admin", "password": "vault:reolink-nvr" ,
      "channels": [0, 1, 3],
      "cameras": { "0": { "siren": true }, "3": { "doorbell": true, "recording": true } } } ] }
```

### 2.5 Setup (Recommendation)

- `discover`: HA finds Reolink devices by DHCP host name `reolink*` and MAC prefix `EC:71:DB` (its manifest); the
  sources have no LAN discovery protocol of their own for wired devices. Offer the hosts of the ARP/neighbour table
  whose MAC starts with `EC:71:DB` and that accept TCP on 9000, and let the user type an address otherwise.
- `accountAuthorization`: username + password prompt; `authorize` runs the login of section 3 and `GetDevInfo` and
  reports model, serial and channel list. Wrong credentials → the prompt again with the device's message.

## 3. Authentication (HTTP API)

### 3.1 Endpoint

All commands are `POST <scheme>://<host>:<port>/cgi-bin/api.cgi?cmd=<FirstCmd>&token=<token>` with a JSON array body.
(The Reolink guide also shows `/api.cgi`; reolink-aio always uses `/cgi-bin/api.cgi`.) The `cmd` query value is the first
command of the body; for a write it is the write command. Snapshots are a `GET` (4.7).

**JSON responses come with `Content-Type: text/html`**, not `application/json`: accept `text/html` and parse JSON.

### 3.2 Login (long session, the one to use)

Request: `POST …/cgi-bin/api.cgi?cmd=Login&token=null` with body

```json
[{"cmd": "Login", "action": 0, "param": {"User": {"userName": "admin", "password": "<password>"}}}]
```

(The guide adds `"Version": "0"` inside `User`; reolink-aio does not send it.) Success:

```json
[{"cmd": "Login", "code": 0, "value": {"Token": {"leaseTime": 3600, "name": "42da7586d7b82a6"}}}]
```

- `code != 0` → login failed. The token is `value.Token.name`; it expires `leaseTime` seconds (normally 3600) after now.
- Every later request carries `token=<name>` in the query.
- Renewal: before each request, if the token expires within **300 s**, log in again (reolink-aio). Before logging in,
  send `Logout` for the old token if there is one (`[{"cmd": "Logout", "action": 0, "param": {}}]` with `cmd=Logout&token=…`;
  its response may be arbitrary text: ignore it). This avoids the `-5 max session` error. Never send `Logout` without a
  token: on some firmware that breaks later logins.
- Only one login at a time (a mutex); concurrent callers wait for it.
- HTTP status 300 on `Login`/`Logout` means HTTP was used where HTTPS is expected: try HTTPS.

### 3.3 Short session (fallback)

Each request carries `user=<username>&password=<password>` in the query instead of a token (guide 2.6.2). Not used by
reolink-aio. **Recommendation:** do not use it (the password would travel in every URL and appear in access logs);
keep it only as a documented alternative.

### 3.4 Port, HTTPS and self-signed certificates

- Without a configured port/scheme, reolink-aio tries HTTPS 443 then HTTP 80 (when Baichuan is available it first asks
  the device which of HTTP/HTTPS are enabled, Baichuan `cmd_id` 37; the plugin may skip that and simply try both).
- HTTPS certificates are self-signed: reolink-aio disables verification and host name checks and allows the `DEFAULT`
  cipher list (older cameras use weak ciphers). **Recommendation:** use `HomeswiftNetwork.HTTPClient` with
  `TrustOnFirstUse` for the device's certificate (pin it at Setup), and a permissive cipher list through `TLSOptions`.
- reolink-aio can switch disabled HTTP/RTSP/ONVIF/RTMP ports on through Baichuan (`cmd_id` 36). **Recommendation:** do
  not change device settings; report "HTTP(S) API disabled on the camera, enable it in the Reolink app" instead.

### 3.5 Errors and retries (reolink-aio behaviour)

- Response bodies shorter than 500 bytes with content type `text/html` containing `"detail" : "please login first"`
  (not for Logout) → token invalid: drop the session, log in, retry. Containing `"detail" : "invalid user"`,
  `"detail" : "login failed"`, `"detail" : "password wrong"` or `Login has been locked` → credentials error (on Login:
  stop, report; elsewhere: retry, then report).
- HTTP 404 or 502 → drop the session, retry. HTTP ≥ 400 otherwise → error.
- Up to 3 attempts per request (`RETRY_ATTEMPTS = 3`), timeout 30 s per request (TCP connect 10 s).
- Per-command errors: an item `{"cmd": …, "code": 1, "error": {"rspCode": <int>, "detail": "<text>"}}`. `rspCode`
  `-12`, `-13`, `-17` (get/set config failed, receive failed) on a battery channel: wait 1 s (camera waking) and retry
  those commands. `-9` not supported, `-26` ability error: the feature is absent. `-5` max session, `-6` please login
  first, `-7` login failed, `-27` invalid user, `-105` frequent logins, `-502` password err, `-506` login locked,
  `-507` login reach max: authentication problems; `-49` channel invalid; `-99` device offline; `-48` snapshot failed.
- Writes: success is `code == 0` **and** `value.rspCode == 200`.
- Batches: at most **35 commands per POST** (more returns `rspCode -16 send failed`); split longer batches. If the
  number of responses differs from the number of commands, wait 5 s and retry; on the last attempt send each command on
  its own. Some firmware answers a whole batch with one error item (`code 1`, negative `rspCode`): send each separately.
  A command that times out (`-8`) on its own is skipped for the rest of the session.
- All HTTP requests to one host are serialised (one in flight at a time).

## 4. HTTP API commands

Body items have the form `{"cmd": "<Name>", "action": 0|1, "param": {…}}`. `action: 1` also returns `initial` and
`range` blocks; `action: 0` only `value`. Responses are arrays in the same order as the request.

### 4.1 Host data (at start-up), one batch

```json
[{"cmd": "GetChannelstatus"},
 {"cmd": "GetDevInfo",  "action": 0, "param": {}},
 {"cmd": "GetLocalLink","action": 0, "param": {}},
 {"cmd": "GetNetPort",  "action": 0, "param": {}},
 {"cmd": "GetP2p",      "action": 0, "param": {}},
 {"cmd": "GetHddInfo",  "action": 0, "param": {}},
 {"cmd": "GetUser",     "action": 0, "param": {}},
 {"cmd": "GetNtp",      "action": 0, "param": {}},
 {"cmd": "GetTime",     "action": 0, "param": {}},
 {"cmd": "GetPushCfg",  "action": 0, "param": {}},
 {"cmd": "GetAbility",  "action": 0, "param": {"User": {"userName": "<username>"}}}]
```

Fields used (an item with `code == 1` is skipped; the device may not support it):

| Command | Field | Use |
|---|---|---|
| `GetDevInfo` | `value.DevInfo.exactType`, `.type` | `NVR`, `WIFI_NVR`, `HOMEHUB` → multi-channel host; `HOMEHUB` → hub |
| | `.serial`, `.name`, `.model`, `.itemNo` (optional), `.hardVer`, `.firmVer`, `.channelNum` | Accessory Information; `channelNum` only when `GetChannelstatus` failed: then channels are `0…channelNum-1` and each channel's model is the host model |
| `GetChannelstatus` | `value.count`, `value.status[]` each `channel`, `online` (1/0), `name` (optional; ignore `"0"`/`"1"`), `typeInfo` (model, optional), `uid` (optional), `sleep` (1 = battery camera asleep, optional) | Channel list = channels with `online == 1`; `typeInfo` containing `Doorbell` → doorbell. If two channels report the same `uid`, make them unique by appending `_<channel>`. Ignore channels whose name is `NVT` or `IPCAM` and whose model is `IPC` (other brands on an NVR). |
| `GetLocalLink` | `value.LocalLink.mac` | MAC (identity fallback) |
| `GetNetPort` | `value.NetPort.rtspPort` (default 554), `rtmpPort` (1935), `onvifPort` (8000), `rtspEnable`, `rtmpEnable`, `onvifEnable` (default 1), `mediaPort` (optional, the Baichuan port) | Stream URLs; Baichuan port |
| `GetP2p` | `value.P2p.uid` | Host UID (identity) |
| `GetUser` | `value.User[]` with `userName`, `level` | `level == "admin"` needed for writes; warn when not admin |
| `GetTime` | `value.Time` with `year`, `mon`, `day`, `hour`, `min`, `sec` | Clock difference (informational) |
| `GetAbility` | `value.Ability` (4.5) | Abilities |

For a single camera reolink-aio also reads the channel count from the Baichuan login reply (5.3.3).

### 4.2 Channel data (at start-up), one batch per host

Per channel, in this order (reolink-aio): `GetChnTypeInfo` (`{"channel": n}`; returns `value.typeInfo` model,
`firmVer`, `boardInfo` hardware; a success marks the channel online), then per stream channel `GetEnc` and
`GetRtspUrl` (`{"channel": n}`), then `GetMdState`, `GetAiState`, `GetEvents`, `GetIsp`, then `GetWhiteLed`,
`GetIrLights`, `GetManualRec`, `GetAudioAlarm` or `GetAudioAlarmV20` (V20 when `Ability.scheduleVersion.ver >= 1`),
and for battery channels `GetBatteryInfo`. Every one is `{"cmd": X, "action": 0, "param": {"channel": n}}`.

Fields used:

| Command | Response | Use |
|---|---|---|
| `GetEnc` | `value.Enc.mainStream` / `subStream`: `vType` (`h264`/`h265`), `width`, `height`, `frameRate`, `bitRate` | Codec per stream (decides RTSP path and transcoding); sub snapshot size |
| `GetRtspUrl` | `value.rtspUrl.channel`, `.mainStream`, `.subStream` (full `rtsp://…` URLs without credentials) | Preferred RTSP URLs when `Ability.rtsp.ver >= 3` (4.6) |
| `GetMdState` | `value.state` (1 = motion) | Motion (older firmware) |
| `GetAiState` | `value.channel`, then per type (`people`, `vehicle`, `dog_cat`, `face`, `package`, …) `{"alarm_state": 0/1, "support": 0/1}`. Firmware before 3.0.0-494 gives a bare integer per type instead (then supported = true, state = value == 1) | AI support and state |
| `GetEvents` | `value.channel`; `value.md` `{alarm_state, support}` (absent `support` = 1); `value.ai` per type `{alarm_state, support}` plus `other` (battery cameras report PIR motion as `ai.other`); `value.visitor` `{alarm_state, support}` | One command for motion + AI + visitor. A list value inside `ai` (smart AI) is ignored. `visitor.support == 1` marks the channel a doorbell. If `value.channel` differs from the requested channel, ignore the item. |
| `GetWhiteLed` | `value.WhiteLed`: `channel`, `state` (0/1), `bright` (0–100), `mode`, `LightingSchedule` `{StartHour, StartMin, EndHour, EndMin}`, optional `ColorTemp` (0–100, where 0 = 6000 K and 100 = 3000 K) | Floodlight state |
| `GetIrLights` | `value.IrLights.state`: `"Auto"`, `"Off"` or `"On"` | IR lights on = `"Auto"` |
| `GetAudioAlarm` | `value.Audio.schedule.enable`; V20: `value.Audio.enable` | Siren alarm enabled (informational) |
| `GetBatteryInfo` | `value.Battery.batteryPercent`, `.chargeStatus` (0 discharging, 1 charging, 2 charge complete), `.temperature` | Battery service |

Whether `GetEvents` exists is decided once: if its item in this batch succeeded, use `GetEvents` for motion polling;
otherwise `GetMdState` (+ `GetAiState` when AI is supported).

Dual lens and auto-track models: when not an NVR and `Ability.abilityChn[0].supportAutoTrackStream.ver > 0`, the stream
channels are `[0, 1]` but motion/AI/lights belong to channel `0` only. Models `Reolink Duo PoE` and `Reolink Duo WiFi`
have motion on both lenses.

### 4.3 State refresh batch (periodic)

Per channel: `GetEvents` (or `GetMdState` + `GetAiState`), `GetIrLights` when IR is supported, `GetWhiteLed` when the
floodlight is supported, `GetBatteryInfo` for battery channels, `GetAudioAlarm[V20]` when the siren is supported; for an
NVR/hub add `{"cmd": "GetChannelstatus", "action": 0, "param": {}}` to notice cameras that come or go (count changed,
new online channel, changed `uid` or `typeInfo`: log "new Reolink device" and refresh the channel list).

Commands reolink-aio counts as **not waking** a battery camera: `GetIsp`, `GetEvents`, `GetMdState`, `GetAiState`,
`GetIrLights`, `GetBatteryInfo`, `GetPirInfo`, `GetPowerLed`, `GetAutoFocus`, `GetDeviceAudioCfg`, `GetManualRec`,
`GetImage`, `GetBuzzerAlarmV20`, `GetEmailV20`, `GetEmail`, `GetPushV20`, `GetPush`, `GetFtpV20`, `GetFtp`, `GetRecV20`,
`GetRec`, `GetAudioAlarmV20`, `GetMdAlarm`, `GetAlarm`, `GetStateLight`, `GetHddInfo`, `GetChannelstatus`,
`GetPushCfg`, `GetScene`. **Waking**: `GetEnc`, `GetWhiteLed`, `GetZoomFocus`, `GetAudioCfg`, `GetPtzGuard`,
`GetAutoReply`, `GetPtzTraceSection`, `GetAiCfg`, `GetAiAlarm`, `GetPtzCurPos`, `GetAudioAlarm`, `GetDingDongList`,
`GetDingDongCfg`, `DingDongOpt`, `GetPerformance`, `GetMask`. Snapshots and streams wake the camera too.

### 4.4 Writes

| Feature | Request body (exact) | Notes |
|---|---|---|
| Floodlight on/off and brightness | `[{"cmd": "SetWhiteLed", "param": {"WhiteLed": {"channel": 0, "state": 1, "bright": 80}}}]` | `state` 1 on / 0 off; `bright` 0–100 (reject outside). Include only the fields being changed. Wait 3 s, then re-read `GetWhiteLed` (reolink-aio). Optional `mode` (HTTP numbers): 0 off, 1 auto (night + motion), 2 on at night, 3 schedule, 4 auto adaptive, 5 adaptive. |
| IR lights | `[{"cmd": "SetIrLights", "action": 0, "param": {"IrLights": {"channel": 0, "state": "Auto"}}}]` | Switch on → `"Auto"`, off → `"Off"`. Re-read `GetIrLights`. |
| Siren | `[{"cmd": "AudioAlarmPlay", "action": 0, "param": {"alarm_mode": "manul", "manual_switch": 1, "channel": 0}}]` (start, continuous) / `… "manual_switch": 0 …` (stop) / `{"alarm_mode": "times", "times": 2, "channel": 0}` (play N times) | The mode string is spelled `manul` by reolink-aio (the guide writes `"manu"` in the description and `times`/`manual_switch` in its example). For a hub's own siren, omit `channel`. reolink-aio 0.22 sends the siren through Baichuan instead (5.4.3), because HTTP `AudioAlarmPlay` is unreliable on some firmware; **Recommendation:** use the Baichuan form when the Baichuan session is up, HTTP otherwise. Stopping a `times` play early does not work on some firmware unless a manual play is started first: send manual-on, then manual-off. |

After every `Set…` write, re-read the matching `Get…` for that channel (`Set` → `Get` in the name).

### 4.5 Abilities

`GetAbility` returns `value.Ability`: host keys `{"<name>": {"permit": n, "ver": n}}` and `abilityChn`, an array with
one object per channel of the same shape. `ver > 0` means supported. For a stream channel beyond the array (second lens),
use `abilityChn[0]`. Abilities that decide features:

| Feature | Rule (reolink-aio) |
|---|---|
| RTSP / RTMP / FLV available | host `rtsp.ver > 0` / `rtmp.ver > 0` / `httpFlv.ver > 0` (and the port known) |
| H.265 main stream | `abilityChn[ch].mainEncType.ver > 0` (when `GetEnc` gives no `vType`) |
| Motion | the channel got a motion state from `GetEvents`/`GetMdState` |
| AI type `t` | `support == 1` for `t` in `GetEvents.ai` / `GetAiState`; pet also needs `supportAiAnimal` |
| Floodlight | `GetWhiteLed` answered **and** (`abilityChn[ch].floodLight.ver > 0` or `supportFLswitch.ver > 0`) |
| IR lights | `abilityChn[ch].ledControl.ver > 0` and `GetIrLights` answered |
| Siren | (`alarmAudio.ver > 0` or `supportAudioAlarm.ver > 0`) and `GetAudioAlarm[V20]` answered; hub: `GetDeviceAudioCfg` answered |
| Battery | `abilityChn[ch].battery.ver > 0` |
| Doorbell | model contains `Doorbell`, or `GetEvents.visitor.support == 1`, or `supportDoorbellLight.ver > 0` |
| Not admin | `GetUser` level ≠ `admin`: features that write stay read-only; log once |

### 4.6 Stream URLs

`CC` = channel + 1 as two digits (`01`, `02`…). `<pw>` is the password percent-encoded with no safe characters for RTSP;
RTMP and FLV need it **unencoded**.

| Protocol | URL | Notes |
|---|---|---|
| RTSP (preferred when `rtsp.ver >= 3`) | `GetRtspUrl`'s `mainStream`/`subStream` with `<user>:<pw>@` inserted after `rtsp://` | |
| RTSP (otherwise) | `rtsp://<user>:<pw>@<host>:<rtspPort>/<codec>Preview_<CC>_<stream>` with `<codec>` = `h264` or `h265` from `GetEnc` `vType` (main defaults to `h265` when `mainEncType` says so, else `h264`; sub defaults to `h264`) and `<stream>` = `main` or `sub`. E.g. `rtsp://admin:pw@192.168.1.20:554/h264Preview_01_main` | reolink-aio checks each candidate with an RTSP `DESCRIBE` (expects `200 OK`), trying in turn: the codec from `GetEnc`, the other codec, then `rtsp://…/Preview_<CC>_<stream>`; if none answers it uses the first. Battery channels: no check. Auto-track/telephoto lens: `Preview_<CC>_autotrack`. |
| RTMP | `rtmp://<host>:<rtmpPort>/bcs/channel<ch>_<stream>.bcs?channel=<ch>&stream=<0\|1>&user=<user>&password=<password>` | `<ch>` is 0-based; `stream=1` for `sub`, `0` otherwise; `<stream>` may be `main`, `sub`, `ext`. Alternative auth: `&token=<token>` instead of user/password. |
| FLV over HTTP(S) | `<http\|https>://<host>:<port>/flv?port=<rtmpPort>&app=bcs&stream=channel<ch>_<stream>.bcs&user=<user>&password=<password>` | Uses the API port. `ext` (a middle "clear/fluent" stream) is only offered over RTMP/FLV. |

**Recommendation:** RTSP over TCP for FFmpeg (`-rtsp_transport tcp -i <url>`); `sub` for HomeKit requests at or below
the sub stream's size (usually 640×360 or 640×480), `main` above; `copy` only when the chosen stream is H.264 (HomeKit
needs H.264; 4K main streams are often H.265 and must be transcoded). Mask the credentials in every logged FFmpeg
command line (8).

### 4.7 Snapshot

`GET <scheme>://<host>:<port>/cgi-bin/api.cgi?cmd=Snap&channel=<ch>&snapType=<main|sub>&token=<token>`; for `sub`, add
`&width=<sub width>&height=<sub height>` from `GetEnc`. The guide also documents `rs=<random fixed-length string>` to
defeat caches; reolink-aio does not send it (either works). Success: `Content-Type: image/jpeg`, the JPEG as body. An
error is a `text/html` JSON body. Empty body → failure (drop the session). Snapshots wake battery cameras.
**Recommendation:** answer HomeKit snapshot requests from this endpoint (`sub` for small sizes), cache the last image
for 10 s, and fall back to an FFmpeg frame from the stream when `Snap` fails. reolink-aio falls back to a Baichuan
snapshot (`cmd_id` 109, a binary payload) — not needed here (Gaps).

## 5. Push events

Two ways exist in reolink-aio: **Baichuan TCP push** (port 9000, what HA uses first: "TCP push") and ONVIF (SWN
webhook subscription or PullPoint long-polling). HA falls back to polling `GetEvents` every 5 s until one of them
delivers. This spec fully specifies Baichuan TCP (5.1–5.4) and polling (5.5). ONVIF is not specified (5.6).

### 5.1 Baichuan framing (TCP)

All integers are **little-endian**. Every message starts with the 4 magic bytes `f0 de bc 0a`.

Header, 24 bytes (message class `1464`, used for every request after the nonce request, and for most replies and pushes):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `f0 de bc 0a` |
| 4 | 4 | `cmd_id` (uint32) |
| 8 | 4 | body length = extension length + body length + binary payload length (uint32), header excluded |
| 12 | 1 | `ch_id`: `channel + 1` for a channel command (1–100), `250` (0xFA) for a host command, `251` (0xFB) for the event subscription; pushes arrive with `0` or `251` |
| 13 | 3 | message counter (uint24) |
| 16 | 2 | status code (uint16): `0` in requests; replies: `200`, `201`, `300` = OK, `401` = unauthorised, `400` = retry (a battery camera waking; wait 1.5 s), anything else = error |
| 18 | 2 | message class, the bytes `14 64` |
| 20 | 4 | extension length (uint32, "payload offset"): in requests, the length of the extension XML that precedes the body; 0 when none |

Bytes 12–15 read together as a uint32 are the **full message id**; a reply carries the same full message id and the same
`cmd_id` as its request. The counter starts at 1 and increments for every request (modulo 2^24).

Header, 20 bytes, legacy class `1465` (only the nonce request, 5.3.1): bytes 0–15 as above, bytes 16–17 `12 dc`, bytes
18–19 `14 65`.

Received 20-byte header, class `1466` (bytes 18–19 `14 66`): bytes 0–15 as above; bytes 16–17 give the encryption of the
body: `01 dd` or `12 dd` = Baichuan XOR, `02 dd` or `03 dd` = AES, `00 dd` = none. No status code, no extension length.
Received class `0000` is treated like `1464` (24 bytes). Received `1465` is not parsed (error for the waiting request).
Any other class → error.

Reassembly: TCP delivers arbitrary chunks. Buffer until 20 bytes (24 for class `1464`/`0000`) plus the body length are
present; several messages may arrive in one read (parse them in turn). Data that does not start with the magic when no
message is pending is dropped (a partial magic of fewer than 4 bytes is kept). A new magic at the start of a read while a
message is pending replaces the pending data (reolink-aio's choice).

Received body layout: if the extension length (bytes 20–23) is non-zero, the first that many bytes are an extension XML
and the rest is the binary payload; if it is zero, the whole body is the XML. A request is at most **38 000 bytes**
including the header (above about 40 000 the camera drops the connection).

### 5.2 Encryption

Two methods. XML text is UTF-8 and always begins `<?xml` once decrypted (a leading newline is allowed in what we send).

**Baichuan XOR ("BC")**, used for the nonce request and the login. The key is the 8 bytes
`1F 2D 3C 4B 5A 69 78 FF`. With `offset` = the message's `ch_id` (0–255), byte `i` of the text is XORed with
`key[(offset + i) mod 8] XOR offset`. Encryption and decryption are the same operation. When a request has an extension
and a body, each is XORed separately, each starting at `i = 0`. On receipt, `offset` is byte 12 of the header.

**AES**, used for everything after login: AES-128 in CFB mode with 128-bit segments (CFB128, what OpenSSL calls
`aes-128-cfb`), IV = the 16 ASCII bytes `0123456789abcdef`, no padding (output length = input length). The key is
derived from the login nonce (5.3.1): `MD5MOD(nonce + "-" + password)`, its first 16 characters, as ASCII bytes. A new
cipher state (fresh IV) is used for every piece: the extension and the body of a request are encrypted separately; a
received XML part is decrypted as one piece; a received binary payload whose extension contains `<encryptLen>N</encryptLen>`
(case-insensitive) has its first N bytes AES-decrypted (fresh IV) and the rest left as is.

`MD5MOD(s)` = the MD5 of the UTF-8 bytes of `s`, written as **upper-case** hexadecimal, **truncated to 31 characters**
(the 32nd hex digit is dropped).

Decrypting a reply: for a 20-byte header, follow bytes 16–17; for a 24-byte header, use AES unless the request used BC.
If the result does not start with `<?xml`, try the other method (XOR with offset = byte 12; or plain text). If neither
gives `<?xml`, it is an error. An empty body is a valid reply (e.g. to `cmd_id` 31).

### 5.3 Session

#### 5.3.1 Nonce

Open TCP to `<host>:<baichuanPort>` (connect timeout 10 s). Send a header-only legacy message: `cmd_id` 1, class `1465`,
body length 0, `ch_id` 250. The reply (`cmd_id` 1, BC-encrypted XML) contains a `nonce` element anywhere in it (e.g.
inside an `Encryption` element). If it also contains `<sigVer>v3</sigVer>`, the device is an **account device**
(Reolink cloud account bound): local login may be refused; if the login then fails, tell the user to switch it back to a
"local device" (reset; Reolink support article "Introduction to Reolink Local Device and Account Device"). No nonce →
error.

#### 5.3.2 Login

Send `cmd_id` 1, class `1464`, `ch_id` 250, **BC-encrypted** (offset 250), no extension, body:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<LoginUser version="1.1">
<userName>{MD5MOD(username + nonce)}</userName>
<password>{MD5MOD(password + nonce)}</password>
<userVer>1</userVer>
</LoginUser>
<LoginNet version="1.1">
<type>LAN</type>
<udpPort>0</udpPort>
</LoginNet>
</body>
```

(Lines end with a single `\n`, the body ends with one; braces mark the computed values.) Reply status `200` = logged in;
`401` = invalid credentials (report, do not retry quickly). Another error on an account device → the account-device
message. **At most one login attempt every 15 s** (reolink-aio refuses earlier attempts). The reply body (BC) contains a
`DeviceInfo` element; useful children: `type` (`nvr`, `wifi_nvr`, `homehub`, `ipc`…), `typeInfo`, `channelNum` (stream
channels), `analogChnNum` (motion channels), `sleep` (privacy mode on, 0/1). From here on every message uses AES.

#### 5.3.3 Commands used

| `cmd_id` | Direction | `ch_id` | Body | Purpose |
|---|---|---|---|---|
| 1 | request | 250 | 5.3.1 / 5.3.2 | nonce, login |
| 2 | request | 250 | logout XML below | logout (then close the socket) |
| 31 | request | **251** | none | subscribe to events; reply 200 with empty body |
| 93 | request | 250 | none | "LinkType", used as keepalive |
| 33 | push | 0/251 | AlarmEvent list (5.4.1) | motion, AI, visitor, tamper, day/night |
| 145 | push | | `ChannelInfo` elements with `channelId`, `loginState` (`standby` = battery camera asleep) | sleep state |
| 291 | push | | list of events with `channel` and `status` (0/1) | floodlight turned on/off (also by the camera itself) |
| 547 | push | | `SirenStatus` elements with `channel`, `status` (0/1) | siren playing |
| 263 | request | channel+1 | siren XML (5.4.3), with channel extension | siren |
| 234 | push | | none | UDP heartbeat only; ignore on TCP |

Logout body:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<LoginUser version="1.1">
<userVer>1</userVer>
</LoginUser>
</body>
```

Channel extension (sent before the body of a channel command, its length in header bytes 20–23, encrypted separately):

```
<?xml version="1.0" encoding="UTF-8" ?>
<Extension version="1.1">
<channelId>{channel}</channelId>
</Extension>
```

`channel` here is 0-based; `ch_id` in the header is `channel + 1`.

A reply whose full message id or `cmd_id` does not match a pending request is a push (or stale): hand it to the push
parser. Only one request per (`cmd_id`, full message id) may be pending.

#### 5.3.4 Keepalive and reconnects (reolink-aio)

- After subscribing, a keepalive loop runs: whenever nothing has been **received** for `keepaliveInterval` (start 30 s),
  send `cmd_id` 93 if events have been seen since the subscription ("events active"), otherwise send `cmd_id` 31 again.
- The first `cmd_id` 33 received after subscribing marks events active. HA waits **10 s** after subscribing; with no
  event yet it falls back (ONVIF, then polling every 5 s) while still listening.
- When the socket closes while subscribed and events were active: log in again and resend 31 at once (no more than one
  such immediate reconnect per 60 s). If that succeeded within 5 s, the camera is dropping idle connections early: lower
  the interval to `max(9, min(secondsSinceLastReceive − 2, interval − 1))`; after an hour connected, raise it by 1 s per
  hour back to 30 s. Otherwise log an error and let the keepalive/next refresh retry.
- If the keepalive loop has not run for 5 × 30 s, restart it (watchdog).
- **Recommendation:** use `Backoff` (5 s doubling to 2 min, as homebridge-reolink-doorbell) between failed reconnects,
  respecting the 15 s login spacing.
- On shutdown: logout (`cmd_id` 2, `ch_id` 250, AES, body above), close.

### 5.4 Event payloads

#### 5.4.1 `cmd_id` 33

The decrypted XML is a `body` root whose children are lists, whose children are events. reolink-aio walks root →
every child → every grandchild and does not check the list's name. Each event has a `channelId` (0-based; ignore
channels not published). Event tags:

- `AlarmEvent`:
  - `status`: a text in which these substrings are tested: `MD` (motion), `visitor` (doorbell pressed), `tamper`.
    Each event sets all three for its channel (absent substring = false). No `status` element → no change to them.
  - `AItype`: comma-separated AI types currently detected, e.g. `people`, `vehicle`, `dog_cat`, `face`, `package`,
    `other`, `none`. For every AI type the channel supports, state = the type appears in the text. If `MD` was not in
    `status`, motion = `other` appears in `AItype` (battery cameras' PIR). Unknown types: log once.
  - `smartAiTypeList` (crossline etc.): ignore.
- `DayNightEvent` with `mode`: day/night state (informational).
- Other tags: log once at debug.

Illustrative event (element names from the parser; the exact set of extra children varies by firmware and is not used):

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<AlarmEventList version="1.1">
<AlarmEvent version="1.1">
<channelId>0</channelId>
<status>MD,visitor</status>
<AItype>people</AItype>
</AlarmEvent>
</AlarmEventList>
</body>
```

States are levels, not pulses: the camera sends a new event when they change (an event without `MD` clears motion).
The doorbell press is the **rising edge** of `visitor` (6.4).

#### 5.4.2 Battery cameras through a hub

They push through the hub's connection like any channel. reolink-aio closes the Baichuan connection of a battery
**host** after 5 s idle to save battery; that applies only to standalone battery cameras (out of scope), not to hubs.

#### 5.4.3 Siren over Baichuan (`cmd_id` 263)

With the channel extension and `ch_id` = channel + 1, AES. Bodies (channel present; for a hub's own siren omit the
`channelId` line and send with `ch_id` 250, no extension):

Play N times (`playMode` 0):

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<audioPlayInfo version="1.1">
<channelId>{channel}</channelId>
<playMode>0</playMode>
<playDuration>10</playDuration>
<playTimes>{times}</playTimes>
<onOff>1</onOff>
</audioPlayInfo>
</body>
```

Manual on/off (`playMode` 2, `onOff` 1 start, 0 stop):

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<audioPlayInfo version="1.1">
<channelId>{channel}</channelId>
<playMode>2</playMode>
<playDuration>10</playDuration>
<playTimes>1</playTimes>
<onOff>{enable}</onOff>
</audioPlayInfo>
</body>
```

reolink-aio's templates begin with a newline before `<?xml`; the camera accepts both. If manual-on fails, reolink-aio
plays `times` 2 instead. One "time" lasts about 5 s (reolink-aio's estimate for when a `times` play ends).

### 5.5 Polling fallback (fully specified)

Used when `pushEvents` is false, when the Baichuan login fails, or while push is not active (HA's rule: poll until the
first push event, then stop; resume when push is lost).

- Every `motionPollInterval` (5 s), one batch for all published channels: `GetEvents` per channel when it exists
  (4.2), else `GetMdState` per channel plus `GetAiState` for channels with AI. These are non-waking commands.
- Map the results as in 4.2. Visitor is only available through `GetEvents`; without it, a doorbell press cannot be seen
  by polling (log once; Gaps).
- A 5 s poll misses presses shorter than the interval and events shorter than 5 s; that is the accepted cost.
- Errors: log the first failure as error, later ones at debug until a success.

### 5.6 ONVIF (not specified)

reolink-aio can also subscribe to ONVIF events at `http://<host>:<onvifPort>/onvif/event_service` (WS-Security digest,
SWN push to a webhook with 15-minute termination time renewed when under 300 s, or PullPoint long-polling with a 5-minute
timeout). It carries motion and AI states but not as reliably and needs a reachable webhook; HA uses it only when TCP
push is unavailable. **Recommendation:** do not implement; Baichuan + polling covers it.

## 6. HomeKit mapping

### 6.1 Accessories and identity

- Each published channel is **one external camera accessory** (`context.publishExternal`, a HAP server of its own, like
  IP Cameras and UniFi Protect cameras). A doorbell channel uses category Video Doorbell, others IP Camera.
- Device Id / stable id seed (Recommendation, following HA's unique ids):
  - host id = the host UID (`GetP2p` `uid`) when known, else the MAC from `GetLocalLink` (lowercase, colon-separated);
  - standalone camera: `Reolink:<hostId>`;
  - NVR/hub channel with a channel UID (`GetChannelstatus` `uid`): `Reolink:<hostId>:<channelUid>` — the camera keeps its
    accessory when moved to another NVR port;
  - NVR/hub channel without UID: `Reolink:<hostId>:ch<channel>`;
  - second lens of a dual-lens camera: `Reolink:<hostId>:lens<channel>` (only if a lens is published separately;
    default: publish lens 0 only).
- Services carry fixed subtypes (`motion`, `person`, `vehicle`, `pet`, `face`, `package`, `doorbell`, `floodlight`,
  `siren`, `ir`, `battery`) so iids stay stable.
- Accessory Information: Manufacturer `Reolink`; Model = channel model (`typeInfo`) or host `model`; Serial = host
  `serial` for a camera, the channel UID (or `<serial>-ch<n>`) for an NVR channel; Firmware = channel `firmVer` or host
  `firmVer` (strip a leading `v`; HAP wants digits and dots, e.g. `v3.0.0.59_20080734` → `3.0.0.59`); Hardware =
  `hardVer`/`boardInfo`.
- Excluded / Not in Home per the glossary: a channel the user excludes is not published.

### 6.2 Camera

Through the shared camera stack (`CameraController`, `HomeswiftFFmpeg`), with the source from 4.6 and snapshots from
4.7. Advertise the resolutions up to the main stream's size. Optional HKSV with prebuffer, triggered by the Motion
Sensor (as IP Cameras). `audio` off by default. Offline channel (`online == 0`, or a failing `Snap` and stream): the
camera keeps its last snapshot; Motion Sensor `StatusActive` false.

### 6.3 Motion and AI sensors

| Service (subtype) | Characteristic | Source |
|---|---|---|
| Motion Sensor `motion` | Motion Detected | `md` / `MD` / `GetMdState.state` (battery: `ai.other`) |
| Motion Sensor `person` | Motion Detected | AI `people` |
| Motion Sensor `vehicle` | Motion Detected | AI `vehicle` |
| Motion Sensor `pet` | Motion Detected | AI `dog_cat` |
| Motion Sensor `face`, `package` | Motion Detected | AI `face`, `package` (only when reported supported) |

Names: "<camera> Motion", "<camera> Person", etc. **Recommendation:** hold each "detected" for at least 2 s after the
device clears it, so short events reach HomeKit and HKSV; never invent a detection.

### 6.4 Doorbell

Doorbell service: Programmable Switch Event `SINGLE_PRESS` (0) on each rising edge of `visitor`, at most once per
`ringThrottleSeconds` (3 s). Reads of the characteristic return null (HAP's convention for events). A doorbell also gets
the normal motion sensors.

### 6.5 Floodlight

Lightbulb `floodlight`: On ↔ `WhiteLed.state` (1/0), Brightness ↔ `bright` (1–100; HomeKit 0 means off). Turning on
with a brightness sends both. Pushes `cmd_id` 291 update On immediately. `ColorTemp`, modes and schedules are not
exposed (they are configuration, not control). Not all floodlights accept `bright`: if a write of `bright` returns an
error, drop Brightness from the next start.

### 6.6 Siren

Switch `siren`: on → manual siren on (4.4 / 5.4.3), off → manual off. Pushes 547 update it; otherwise turn the switch off
by itself after 60 s (Recommendation: firmware stops a manual siren on its own after a while; the switch must not stay on).
Siren writes are audited like any write; **Recommendation:** not a security characteristic (it is not a lock or alarm
system), off by default in configuration.

### 6.7 IR lights, battery

Switch `ir` ("Infrared"): on ↔ `"Auto"`, off ↔ `"Off"`. Battery service on battery channels: Battery Level =
`batteryPercent`; Charging State = 1 when `chargeStatus` is 1, 0 otherwise (2 = charge complete → not charging);
Status Low Battery when `batteryPercent < 20`.

## 7. Behaviour

### 7.1 Start-up and polling

1. Per host: login (3), host batch (4.1), channel batch (4.2), abilities (4.5), build accessories.
2. Baichuan: nonce, login, subscribe (`cmd_id` 31), keepalive (5.3). If it fails, polling (5.5) and retry Baichuan later.
3. Full refresh (4.3) every `pollInterval`: HA uses max(60 s, 10 s × number of cameras).
4. Motion polling only while push is not active (5.5).

### 7.2 Writes

Serialise per host with reads (one HTTP request in flight). Update the HomeKit value optimistically, then re-read
(4.4); on failure, restore the previous value and log a warning. A command against an offline channel fails at once.

### 7.3 Sessions and rate limits

- Reolink devices allow few concurrent sessions (API `-5 max session`, `-507 login reach max`); a crashed client's
  session lingers up to an hour. Hence: one HTTP token per host, reused; logout before re-login and at shutdown.
- `-105 Frequent logins, please try again later!`: wait 60 s before the next login (Recommendation).
- One Baichuan connection per host. Logins at most every 15 s.
- RTSP: cameras serve a limited number of simultaneous streams (Recommendation, not from the sources: assume 2 per
  camera, so `maxStreams` 2, and share one FFmpeg prebuffer for HKSV rather than opening a second session).
- The doorbell plugin's Baichuan library and the Reolink app also hold sessions; do not run two bridges on one camera.

### 7.4 Offline and errors

Connection errors after retries: mark the host offline (all its channels' sensors `StatusActive` false), retry the
login with `Backoff` (5 s → 2 min). When a channel goes `online == 0` in `GetChannelstatus`, mark it offline; when a new
online channel appears, add its accessory at the next refresh (published only if not Excluded).

### 7.5 Battery cameras

Through a hub/NVR: keep refreshes to non-waking commands (4.3). HA's policy: a waking full refresh of a battery
channel only when the camera is awake on its own (`sleep == 0`) and the last waking refresh is over 1 h old, or when
over 6 h old regardless, or a waking refresh of all channels every 12 h. Snapshots and streams wake the camera: answer
HomeKit snapshot requests for a sleeping battery channel from the cached image unless it is older than 1 h
(Recommendation). Standalone battery cameras: `Login` fails (no HTTP); log "this Reolink device has no HTTP API; connect
it to a Reolink Home Hub or NVR and add the hub instead".

## 8. Logging and secrets

- Never log the password, the token, the nonce, the two login hashes, the AES key, or URLs containing credentials:
  replace them with `<password>`, `<token>`, etc. reolink-aio also masks UIDs in its debug logs (`<uid>`);
  **Recommendation:** mask UIDs and serials in logs as well, they identify the device to Reolink's cloud.
- Follow the CLAUDE.md rule for pairing material: log Baichuan and HTTP bodies only at trace level, and only their size
  for login messages.
- `password` sits under a secret-named key, so the runtime seals and resolves it (`vault:` references allowed). No token
  needs storing (login is cheap); nothing goes in `context.secretFile`.
- FFmpeg command lines with an RTSP/RTMP/FLV URL: log with credentials masked.
- Info level: host connected (model, firmware, channels), push active / fell back to polling, doorbell pressed. Warning:
  password characters outside the known-good set, user not admin, account device, max sessions.

## 9. Test vectors (computed by the spec writer)

### 9.1 Baichuan XOR keystream

| Offset (`ch_id`) | First 8 keystream bytes (repeat every 8) |
|---|---|
| 0 | `1f 2d 3c 4b 5a 69 78 ff` |
| 250 | `c6 b1 a0 93 82 05 e5 d7` |

`<?xml version="1.0"` XORed with offset 250 → `fa 8e d8 fe ee 25 93 b2 b4 c2 c9 fc ec 38 c7 e6 e8 81 82`.

### 9.2 Hashes and AES key

nonce `0a1b2c3d4e5f6a7b`, username `admin`, password `Secret123` (invented):

| Value | Result |
|---|---|
| `MD5MOD("admin" + nonce)` | `7D99C1CE9846F14A9EF988709951595` (31 chars) |
| `MD5MOD("Secret123" + nonce)` | `B6368B64B0B8014C8B91739A9B971AB` |
| AES key = first 16 of `MD5MOD(nonce + "-Secret123")` | `9CAEAF70935CDBA6` = bytes `39 43 41 45 41 46 37 30 39 33 35 43 44 42 41 36` |
| AES-128-CFB128, IV `0123456789abcdef`, of `<?xml version="1.0" encoding="UTF-8" ?>\n<body/>` (48 bytes) | `197170e110398a66ba77386c4cd2678ed5a7f3930e4dadf2379965476c8ef189c6d53830c07217f5eafdd9ea9e78a9` |

The login body of 5.3.2 with these values is 296 bytes; BC-encrypted (offset 250) it starts
`fa 8e d8 fe ee 25 93 b2 b4 c2 c9 fc ec 38 c7 e6 e8 81 82 b3 e7 6b 86 b8 a2 d8 ce f4 bf 27 b0 83`.

### 9.3 Headers (as sent on a fresh connection)

| Message | Bytes |
|---|---|
| nonce request (counter 1) | `f0 de bc 0a 01 00 00 00 00 00 00 00 fa 01 00 00 12 dc 14 65` |
| login (counter 2, body 296 bytes) | `f0 de bc 0a 01 00 00 00 28 01 00 00 fa 02 00 00 00 00 14 64 00 00 00 00` |
| subscribe 31 (counter 3) | `f0 de bc 0a 1f 00 00 00 00 00 00 00 fb 03 00 00 00 00 14 64 00 00 00 00` |
| keepalive 93 (counter 4) | `f0 de bc 0a 5d 00 00 00 00 00 00 00 fa 04 00 00 00 00 14 64 00 00 00 00` |
| siren 263, channel 0, `times` 2 (counter 5): extension 104 bytes + body 224 bytes (the template with its leading newline) | `f0 de bc 0a 07 01 00 00 48 01 00 00 01 05 00 00 00 00 14 64 68 00 00 00` |
| a push `cmd_id` 33 of 300 bytes, status 200 (example) | `f0 de bc 0a 21 00 00 00 2c 01 00 00 fb 00 00 00 c8 00 14 64 00 00 00 00` |

Parser checks: two messages in one read; one message split at byte 3, 10, 22 and inside the body; a `1466` reply with
`01 dd`; a reply with status `c8 00` vs `91 01` (401); a reply whose full message id differs from the request (treat as
push).

### 9.4 HTTP fixtures (invented serials and UIDs)

Login: as 3.2. `GetDevInfo` of a camera:

```json
[{"cmd": "GetDevInfo", "code": 0, "value": {"DevInfo": {"model": "RLC-810A", "name": "Driveway", "serial": "00000000000001",
  "hardVer": "IPC_523128M8MP", "firmVer": "v3.1.0.2368_23062508", "exactType": "IPC", "type": "IPC", "channelNum": 1, "itemNo": ""}}}]
```

NVR channel status:

```json
[{"cmd": "GetChannelstatus", "code": 0, "value": {"count": 4, "status": [
  {"channel": 0, "name": "Garden", "online": 1, "typeInfo": "RLC-520A", "uid": "95270000AAAAAAAA"},
  {"channel": 1, "name": "Front Door", "online": 1, "typeInfo": "Reolink Video Doorbell PoE", "uid": "95270000BBBBBBBB"},
  {"channel": 2, "name": "", "online": 0, "typeInfo": ""},
  {"channel": 3, "name": "Shed", "online": 1, "typeInfo": "Argus 3 Pro", "uid": "95270000CCCCCCCC", "sleep": 1}]}}]
```

Expected: channels 0, 1, 3; channel 1 a doorbell; channel 3 asleep.

`GetEvents`, doorbell pressed with a person:

```json
[{"cmd": "GetEvents", "code": 0, "value": {"channel": 1,
  "ai": {"people": {"alarm_state": 1, "support": 1}, "vehicle": {"alarm_state": 0, "support": 1},
         "dog_cat": {"alarm_state": 0, "support": 0}, "other": {"alarm_state": 0, "support": 0}},
  "md": {"alarm_state": 1, "support": 1}, "visitor": {"alarm_state": 1, "support": 1}}}]
```

Expected: motion on, person on, vehicle off, no pet sensor, doorbell (one press).

`GetAiState` new and old forms:

```json
[{"cmd": "GetAiState", "code": 0, "value": {"channel": 0, "dog_cat": {"alarm_state": 0, "support": 1},
  "face": {"alarm_state": 0, "support": 0}, "people": {"alarm_state": 1, "support": 1}, "vehicle": {"alarm_state": 0, "support": 1}}}]
[{"cmd": "GetAiState", "code": 0, "value": {"channel": 0, "people": 1, "vehicle": 0}}]
```

`GetRtspUrl` (shape of the URLs illustrative):

```json
[{"cmd": "GetRtspUrl", "code": 0, "value": {"rtspUrl": {"channel": 0,
  "mainStream": "rtsp://192.168.1.20:554/Preview_01_main", "subStream": "rtsp://192.168.1.20:554/Preview_01_sub"}}}]
```

Write success / failure:

```json
[{"cmd": "SetWhiteLed", "code": 0, "value": {"rspCode": 200}}]
[{"cmd": "SetWhiteLed", "code": 1, "error": {"rspCode": -9, "detail": "not support"}}]
```

Token expiry, as the camera formats it (spaces around the colons, which reolink-aio's substring test relies on):
`[ { "cmd" : "GetEvents", "code" : 1, "error" : { "detail" : "please login first", "rspCode" : -6 } } ]` served as
`text/html` → one re-login and one retry. **Recommendation:** parse the JSON and test `rspCode == -6` or the `detail`
text, rather than a byte substring, so either spacing works. A batch of 40 commands → two POSTs (35 + 5).

Stream URLs for host `192.168.1.20`, user `admin`, password `p@ss!`, channel 0, RTSP 554, RTMP 1935, API HTTPS 443:
RTSP `rtsp://admin:p%40ss%21@192.168.1.20:554/h264Preview_01_main`; RTMP
`rtmp://192.168.1.20:1935/bcs/channel0_sub.bcs?channel=0&stream=1&user=admin&password=p@ss!`; FLV
`https://192.168.1.20:443/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=admin&password=p@ss!`.

## 10. Gaps

- **Event XML samples**: reolink-aio has no recorded `cmd_id` 33 payload; the element names in 5.4.1 come from its
  parser. The list element's name and the extra children (e.g. recording flags, timestamps) are not known from the
  sources; the parser must not depend on them. Capture a real payload when testing on a device.
- **Nonce reply shape**: only "contains a `nonce` element, maybe `sigVer`" is known from the parser.
- **Standalone battery cameras** (Baichuan over UDP, P2P discovery, UDP key and CRC in reolink-aio's `util.py`) are
  out of scope.
- **ONVIF** events not specified (5.6).
- **Baichuan snapshot** (`cmd_id` 109, binary payload with `encryptLen`) not specified in detail; HTTP `Snap` and FFmpeg
  frames cover it.
- **Visitor without push**: firmware without `GetEvents` cannot report doorbell presses by polling.
- **Siren**: HTTP `AudioAlarmPlay` mode string (`manul` vs the guide's `manu`) is untested here; reolink-aio moved to
  Baichuan. Manual siren auto-stop time is unknown (the 60 s switch reset is a guess).
- **Floodlight brightness** support differs by model; the ability `floodLight.ver` 2 means "automatic mode" support,
  not brightness.
- **Concurrent RTSP limits** and the `ext` stream's resolution are model-specific; not in the sources.
- **ColorTemp**, spotlight modes and schedules, smart AI zones, chimes, PTZ, two-way audio: deliberately not exposed.
- reolink-aio's automatic opening of disabled ports through Baichuan (`cmd_id` 36/37) is deliberately not reproduced.
- Not verified on a real device by the spec writer; everything comes from the sources' code and Reolink's guide.
