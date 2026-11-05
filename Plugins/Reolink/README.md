# Reolink

Puts Reolink cameras, video doorbells, NVRs and Home Hubs in HomeKit, over the local network (no Reolink cloud). Each
camera channel is an accessory of its own, added in the Home app with the bridge's setup code, with live video,
snapshots, HomeKit Secure Video, motion and AI detections (person, vehicle, pet, face, package), the doorbell button,
the floodlight (with its colour temperature and Adaptive Lighting), the siren, the IR lights, privacy mode, the device's
own recording and wireless chimes; PTZ cameras move, zoom and go to their presets from the Assistant and MCP clients. Events come by the devices' own push protocol (Baichuan, TCP 9000); the
the floodlight, the siren and the IR lights. Events come by the devices' own push protocol (Baichuan, TCP 9000); the
plugin polls them every 5 seconds only while push is not active.

**Status: experimental.** Nobody has run it against a real Reolink device yet: it is tested against a fake device that
speaks the HTTP API and Baichuan as the [functional spec](../../docs/clean-room/Reolink.md) describes them (see
[Tests](#tests)). Please report what works on yours.

**Maintainer:** Mickael Palma.

## In HomeKit

Each published channel is an external camera accessory (category IP Camera, or Video Doorbell for a doorbell):

| Service (subtype) | When | HomeKit |
|---|---|---|
| Camera | always | Live video and snapshots; HomeKit Secure Video with `recording` |
| Doorbell (`doorbell`, primary) | the model says Doorbell, or the device reports a visitor button | A press on each rising edge of the visitor event, at most once per `ringThrottleSeconds` |
| Motion Sensor (`motion`) | the channel reports motion | Motion Detected; it also triggers HomeKit Secure Video |
| Motion Sensors (`person`, `vehicle`, `pet`, `face`, `package`) | each AI type the camera supports (pet also needs `supportAiAnimal`) | Motion Detected for that type |
| Lightbulb (`floodlight`) | the camera has a floodlight or spotlight | On, Brightness 1 to 100; Color Temperature (3000 to 6000 K) and Adaptive Lighting where Baichuan's `ledCtrl` has the colour bit |
| Switch (`siren`) | `siren: true` and the camera has one | A manual siren; the switch turns itself off after a minute |
| Switch (`ir`, "Infrared") | `irLights: true` and the camera has IR lights | On is `Auto`, off is `Off` |
| Battery (`battery`) | a battery camera behind a hub or NVR | Level, Charging, Low below 20 % |
| Switch (`privacy`, "Privacy") | the camera has privacy mode (`privacySwitch`, on by default) | Privacy mode on or off; kept in step with HomeKit's Camera Active (with `recording`): privacy on is Camera Active off, and the other way round |
| Switch (`recording`, "Recording") | `recordingSwitch: true` and `GetRec`/`GetRecV20` answered | The device's own recording to its SD card or the NVR's disk (not HomeKit Secure Video) |
| Switches (`preset<id>`, "Go to <preset>") | `presetSwitches: true` and a PTZ camera with presets | Momentary: on turns the camera to the preset, then the switch turns itself off |
| Switch (`patrol`, "Patrol") | `patrolSwitch: true` and a PTZ camera with a patrol | Runs the first patrol set up in the Reolink app; its state is read back over Baichuan |
| Switches (`chime<id>`, "Chime <name>") | `chimeSwitch: true` and a doorbell with paired Reolink Chimes (`supportDingDongCtrl`) | Momentary: plays `chimeTone` on that chime |

A detection stays on at least two seconds after the device clears it, so short events reach HomeKit and HKSV. The siren
is a plain switch, not a security control, and neither is PTZ: they are loud or move a view, but they do not stop the
camera from seeing. **Privacy and Recording are security controls** (`securityControl()`): privacy mode turns the
camera's video and detections off, and recording off stops the device keeping footage, so either can blind a camera
someone relies on; Camera Active, which drives privacy mode too, is marked the same way. MCP clients change them only through `set_security_accessory`, after the user confirms, and the web
UI asks first. Every feature is gated by the device's abilities: a camera without one gets nothing new. Accessory Information: Manufacturer Reolink, the channel's model, the host's
| Lightbulb (`floodlight`) | the camera has a floodlight or spotlight | On, Brightness 1 to 100 |
| Switch (`siren`) | `siren: true` and the camera has one | A manual siren; the switch turns itself off after a minute |
| Switch (`ir`, "Infrared") | `irLights: true` and the camera has IR lights | On is `Auto`, off is `Off` |
| Battery (`battery`) | a battery camera behind a hub or NVR | Level, Charging, Low below 20 % |

A detection stays on at least two seconds after the device clears it, so short events reach HomeKit and HKSV. The siren
is a plain switch, not a security control. Accessory Information: Manufacturer Reolink, the channel's model, the host's
serial (an NVR channel's UID), the firmware as digits and dots (`v3.1.0.2368_23062508` is `3.1.0.2368`).

**Identity.** A camera on its own is `Reolink:<host id>`, the host id being its P2P UID, else its MAC. A channel of an
NVR or a hub is `Reolink:<host id>:<channel UID>` (so a camera keeps its accessory when moved to another NVR port), or
`Reolink:<host id>:ch<n>` without a UID. These are the Device Ids of Setup and Accessory Settings.

**Live video.** FFmpeg reads RTSP over TCP (or RTMP, FLV with `streamProtocol`): the sub stream for requests up to its
size, the main stream above (`stream` overrides). The video is encoded as HomeKit asks with libx264; `vcodec: copy`
sends an H.264 stream as it is, and an H.265 stream (most 4K main streams) is always encoded. Snapshots come from the
device's `Snap` command (the sub stream for small sizes), cached 10 seconds, with an FFmpeg frame of the stream when
`Snap` fails. A sleeping battery camera's snapshot is the last one, up to an hour old, so it is not woken for it.

**HomeKit Secure Video.** With `recording`, a motion event records the main stream transcoded to what HomeKit chose
(`RTSPRecordingSource` in HomeswiftFFmpeg). With `prebuffer` one stream stays open and keeps the last four seconds, so
recordings start before the motion; without it a recording starts when the event is seen.

## Configuration

Add devices on **Add accessories**: the plugin lists the Reolink devices of the network it can see (their MAC starts
with `EC:71:DB` and they answer on TCP 9000) and "A Reolink device by its address" for any other; Setup asks for the
address when needed, the user name and the password of a local user, signs in, reads `GetDevInfo` and
`GetChannelstatus`, and keeps the login in the vault and the address in the device's Accessory Settings. A block
written by hand works too:

```json
{
  "platform": "Reolink",
  "devices": [
    { "host": "192.168.1.30", "username": "admin", "password": "vault:reolink-nvr",
      "channels": [0, 1, 3],
      "cameras": { "0": { "siren": true }, "3": { "doorbell": true, "recording": true } } }
  ]
}
```

| Option | Default | |
|---|---|---|
| `videoProcessor` | `ffmpeg` | The FFmpeg executable |
| `devices[].host` | | The address of the camera, doorbell, NVR or hub |
| `devices[].username` | `admin` | A local user; an administrator is needed to switch floodlights, sirens and IR lights (another one's are read-only) |
| `devices[].password` | | A secret-named key: sealed in the vault, `vault:` references allowed, never logged. At most 31 characters; letters, digits and `@$*~_-+=!?.,:;'()[]` work in every stream URL (the plugin warns otherwise) |
| `devices[].port`, `useHttps` | auto | The HTTP(S) API: HTTPS on 443, then HTTP on 80 |
| `devices[].baichuanPort` | 9000 | Baichuan's port (the device's `mediaPort` when it reports one) |
| `devices[].channels` | every online channel | An NVR's or a hub's channels to publish, from 0 |
| `devices[].streamProtocol` | `rtsp` | `rtsp`, `rtmp` or `flv` |
| `devices[].pushEvents` | `true` | Baichuan push; `false` polls only |
| `devices[].pollInterval` | 60 s, +10 per camera above six | The full refresh: lights, battery, the NVR's channel list |
| `devices[].motionPollInterval` | 5 s | Motion polling while push is not active |
| `devices[].cameras["<channel>"]` | | A channel's options, below; once the settings are saved they move into the channel's Accessory Settings |

A channel's options (also its Accessory Settings): `name`, `motionSensor` (true), `aiSensors` (every supported type),
`doorbell` (auto), `floodlight` (true), `siren` (false), `irLights` (false), `stream` (`auto`, `main`, `sub`), `audio`
(false), `recording` (false), `prebuffer` (false), `maxStreams` (2), `vcodec` (`libx264` or `copy`), `encoderOptions`,
`debug`, `ringThrottleSeconds` (3).

New in the Accessory Settings: `presetSwitches` (false), `patrolSwitch` (false), `privacySwitch` (true), `recordingSwitch`
(false), `chimeSwitch` (false) and `chimeTone` (`citybird`, `originaltune`, `pianokey`, `loop`, `attraction`, `hophop`,
`goodday`, `operetta`, `moonlight`, `waybackhome`), `floodlightMode` (`off`, `auto`, `night`, `schedule`, `autoAdaptive`,
`adaptive`; only a mode the camera offers is taken), `motionSensitivity` (1 to 50, sent as the device's `sensDef` 51 − s)
and `aiSensitivity` (0 to 100, for every AI type the camera detects). The device-side ones (mode, sensitivities) are read
in one batch at start and written in one more, only where the device differs; empty leaves the device's own.

### PTZ from the Assistant and MCP clients

HomeKit has no PTZ service, so PTZ is a set of Assistant actions (MCP tools named after the plugin): `list_ptz_cameras`
(read scope: the moves each camera makes, its presets, patrols, guard and zoom and focus ranges), and with the configure
scope `move_camera` (a direction or zoom for up to 10 seconds, then `Stop`, which the plugin always sends),
`go_to_preset`, `run_patrol`, `camera_home_position` (go home, save the current position, or change the auto-return)
and `zoom_camera` (absolute zoom or focus, refused outside the camera's range). What a camera does comes from
`ptzType` (1, 2, 5 zoom; 2, 3, 5, 6 tilt; 2, 3, 5, 6, 7 pan), `ptzPreset` and `supportPtzSpeed` (speed only on types 2
and 3). **Zoom direction:** the HTTP guide calls `ZoomDec` zoom in and `ZoomInc` zoom out, reolink-aio the other way
round; the plugin follows the addendum's recommendation and reolink-aio: `zoomIn` sends `ZoomInc`. If a camera zooms
the wrong way, please report it.

### From homebridge-reolink-doorbell

There is no Homebridge platform named `Reolink`; this block is the spec's. homebridge-reolink-doorbell's `ReolinkDoorbell`
block (`doorbells: [{ name, host, port, username, password, channel, ringThrottleSeconds }]`) is not read: its accessory
was a bridged one with only a Doorbell service, and a Reolink camera here is a different, external accessory, so its
identity cannot be kept. Move each doorbell into a `Reolink` device instead: `host`, `username` and `password` as they
were, its `port` as `baichuanPort` (when not 9000), its `channel` in `channels` on an NVR, and `ringThrottleSeconds` in
that channel's `cameras` options. Then add the new accessory in the Home app and remove the old one.

## How it talks to the devices

- **HTTP JSON API** (`/cgi-bin/api.cgi`): one long session per host, its token reused and renewed 300 s before it
  expires with a logout first (never a logout without a token), one login and one request in flight at a time, at most
  35 commands per POST, three attempts per request. "Please login first" logs in once and retries; `-105` (frequent
  logins) waits a minute; a refused login is reported and retried every ten minutes. HTTPS certificates are
  self-signed: the first one is trusted and pinned (`certificates.json`), a different one later is refused, and the
  `DEFAULT` cipher list lets older cameras connect.
- **Baichuan** (TCP 9000): the nonce and login (MD5 hashes, the body XOR-encrypted), then AES-128-CFB with a key from the
  nonce and the password; the event subscription, a keepalive when nothing came for 30 s (shortened when the device
  drops idle connections early), logins at most every 15 s, reconnects with backoff from 5 s to 2 min, logged once
  per outage; motion, AI, visitor, floodlight, siren, sleep and privacy pushes. The siren goes through Baichuan when its
  session is up, HTTP's `AudioAlarmPlay` otherwise. The session starts before the HTTP login: a camera in privacy mode
  refuses HTTP logins, so it is asked first (`cmd_id` 574), and its abilities (`cmd_id` 199: the floodlight's `ledCtrl`)
  are read then. Privacy mode is written with `cmd_id` 575, the floodlight's colour with 289/290, a patrol's state read
  with 64.
- **Privacy mode** is not an outage: while it is on nothing is asked over HTTP (no refresh, no poll, no login), the
  camera keeps its accessory and last snapshot, and a refresh that fails because it just turned on is checked over
  Baichuan and not logged as an error. A camera in privacy mode at start is added when it ends (the 623 push, or a
  check over Baichuan each minute).
- **Cost:** the new reads join the existing batches (PTZ presets, patrols, guard and zoom range, chimes and the recording
  state at start-up; the recording state in the full refresh) or come from push; writes are coalesced (a slider, a drag of
  the colour, quick flips of a switch send the last), and one HTTP request is in flight per host, as before.
  per outage; motion, AI, visitor, floodlight, siren and sleep pushes. The siren goes through Baichuan when its session
  is up, HTTP's `AudioAlarmPlay` otherwise.
- **Battery cameras behind a hub or NVR**: only commands that do not wake them (no `GetEnc`, `GetWhiteLed`,
  `GetAudioAlarm`), so their floodlight and stream codec are not read; their snapshots and streams wake them.
- An unreachable host leaves its cameras showing No Response and is retried with backoff; a channel that goes offline
  on an NVR shows No Response, and a new one appears at the next refresh.

The password, the token, the nonce, the login hashes, the AES key and URLs with credentials are never logged (stream
URLs are masked in FFmpeg's command lines).

## Gaps

Choices made where the spec is silent or leaves it open:

- **Standalone battery cameras** (Argus, Go… on their own) are out of scope: they have no HTTP API and speak Baichuan
  over UDP. Their login fails; connect them to a Reolink Home Hub or NVR and add that instead.
- **ONVIF events** are not implemented (spec 5.6): Baichuan push and polling cover them.
- **RTSP URL probing**: the spec says reolink-aio checks each RTSP candidate with `DESCRIBE`; the plugin uses the URL of
  the codec `GetEnc` reports (or `GetRtspUrl`'s) without probing. If a camera's stream does not start, try
  `streamProtocol: rtmp`.
- **Event payloads** (spec 10): the `cmd_id` 33 parser follows the element names the spec gives and ignores the rest;
  the floodlight push (291) takes any element with `channel` and `status`. A real payload would confirm them.
- **Motion from `AItype` without `status`** is not applied (the spec only ties `other` to a status without `MD`).
- **The siren** switch turns itself off after 60 s (a guess, as the spec says); HTTP's mode string is `manul`, as
  reolink-aio spells it, untested.
- **Floodlight brightness** is always offered when the floodlight is; a camera that refuses `bright` answers the write
  with an error (the spec's "drop Brightness from the next start" is not done).
- **Battery cameras' waking refresh** (Home Assistant's hourly/12-hourly policy) is not done: battery channels are only
  read with non-waking commands.
- Baichuan's watchdog restart is not needed (the keepalive runs in the session's own loop); its snapshot (`cmd_id` 109)
  is not used.
- **Discovery** reads the ARP table, so it sees only devices the bridge's machine talked to lately; others are added by
  address. `ARPTable.entries()` was added to HomeswiftNetwork for it.
- **While push is active** the full refresh leaves the event commands out and a poll answered late is not applied, so
  an older poll never undoes a newer push.
- The spec's AES vector says its plaintext is 48 bytes; the text and the ciphertext it gives are 47, and they match.
- **Two-way audio** is not supported: none of the sources describes how to send talk audio (Home Assistant relies on an
  RTSP backchannel whose details they do not give, and FFmpeg cannot send one).
- **Standalone battery cameras** over Baichuan UDP stay out (see above): that transport is about as large as the whole
  plugin again; they are supported behind a Home Hub or NVR.
- **The hardwired chime** of a doorbell (Baichuan 483) is left out: reading its state makes the chime rattle.
- **Detection zones** are left out: the sources do not state the cell order of the motion and AI zone bitmaps, and a
  wrong guess would mask the wrong parts of the picture. Set them in the Reolink app.
- **Privacy mode needs Baichuan at start:** a camera whose Baichuan session is not up when the plugin connects gets no
  Privacy switch until the next start.
- **Older motion sensitivity** (`GetAlarm`/`SetAlarm`, firmware without `GetMdAlarm`'s `newSens`) is not written; the
  plugin logs that the camera has no sensitivity it can set. "YOLO" models' AI settings (Baichuan 628/629) are not done.
- Whether `SetPtzPreset` stores the current position is not stated by the sources, so presets are not created from
  Homeswift (the Reolink app does it). The privacy mask (black zones) and IR brightness are not exposed.
- Schedules (floodlight, recording) stay in the Reolink app; the master recording switch of a camera on its own is turned
  on with its schedule, never off.
- PTZ, chimes, two-way audio, privacy mode, colour temperature and schedules are not exposed (spec 1).

## Tests

`swift test --filter ReolinkTests` runs the plugin against a fake device, with no device or network: every vector of
the spec's section 9 byte for byte (the XOR keystreams, the MD5MOD hashes, the AES key and an AES-CFB ciphertext, the
296-byte login body and its encryption, the nonce, login, subscribe, keepalive, siren and push headers), the parser's
checks (two messages in one read, splits at bytes 3, 10, 22 and in the body, a 1466 reply, 200 against 401), a session
against a fake camera (login, subscription, events, keepalive, siren, a refused password retried slowly), the HTTP
client (the login body, token reuse and renewal with a logout, "please login first", refused and frequent logins, 40
commands as 35 + 5, one request in flight, a batch refused whole, HTTPS then HTTP), the fixtures of 9.4, the stream URLs,
and the plugin end to end: the accessory and its services, push events reaching HomeKit and stopping the polling, the
polling's one request per cycle, the doorbell's throttled rising edge, the floodlight's writes coalesced, the siren
over Baichuan, an unreachable device, No Response while offline, cached snapshots, Setup and the canonical settings. The
addendum's vectors and features (`ReolinkParityTests`): the 199, 574 and 575 headers and the privacy template, the 623
push, presets, `ptzType` 2 and 7, `ToPos`, `StartPatrol`, a zoom of 34 refused, `DingDongOpt`, `SetRecV20`, `sensDef` 21
for 30, ColorTemp 40 as 4800 K and 4500 K as 50; privacy and Camera Active both ways, no login while private and no outage
when a refresh fails in privacy mode; Adaptive Lighting turned off by a colour set elsewhere and not by its echo; every
feature absent without its ability; writes coalesced, no extra request per poll cycle and never two requests at once.
over Baichuan, an unreachable device, No Response while offline, cached snapshots, Setup and the canonical settings.

## Clean-room implementation

A new platform built on the behaviour of [reolink-aio](https://github.com/starkillerOG/reolink_aio) by starkillerOG (MIT
License) and its use in Home Assistant's `reolink` integration (Apache License 2.0), with homebridge-reolink-doorbell by
Alex (Ultra-Sack) (Apache License 2.0) for the doorbell's throttle and block. Written from the functional spec in
[docs/clean-room/Reolink.md](../../docs/clean-room/Reolink.md), without reading or copying their code. Interface facts
also come from Reolink's "Camera HTTP API User Guide" (version 7), as the spec quotes them.
