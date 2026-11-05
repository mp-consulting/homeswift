# Reolink

Puts Reolink cameras, video doorbells, NVRs and Home Hubs in HomeKit, over the local network (no Reolink cloud). Each
camera channel is an accessory of its own, added in the Home app with the bridge's setup code, with live video,
snapshots, HomeKit Secure Video, motion and AI detections (person, vehicle, pet, face, package), the doorbell button,
the floodlight (with its colour temperature and Adaptive Lighting), the siren, the IR lights, privacy mode, the device's
own recording and wireless chimes; PTZ cameras move, zoom and go to their presets from the Assistant and MCP clients. Events come by the devices' own push protocol (Baichuan, TCP 9000); the
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
| Speaker (two-way audio) | `twoWayAudio: true` and the channel's talk ability says it can (Experimental) | The Home app's talk button plays through the camera's speaker, over Baichuan |
| Doorbell (`doorbell`, primary) | the model says Doorbell, or the device reports a visitor button | A press on each rising edge of the visitor event, at most once per `ringThrottleSeconds` |
| Motion Sensor (`motion`) | the channel reports motion | Motion Detected; it also triggers HomeKit Secure Video |
| Motion Sensors (`person`, `vehicle`, `pet`, `face`, `package`) | each AI type the camera supports (pet also needs `supportAiAnimal`) | Motion Detected for that type |
| Lightbulb (`floodlight`) | the camera has a floodlight or spotlight | On, Brightness 1 to 100; Color Temperature (3000 to 6000 K) and Adaptive Lighting where Baichuan's `ledCtrl` has the colour bit |
| Switch (`siren`) | `siren: true` and the camera has one | A manual siren; the switch turns itself off after a minute. A security control: MCP clients confirm before they change it |
| Switch (`ir`, "Infrared") | `irLights: true` and the camera has IR lights | On is `Auto`, off is `Off` |
| Battery (`battery`) | a battery camera behind a hub or NVR, or on its own | Level, Charging, Low below 20 % (or when the camera says so) |
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

## Two-way audio (Experimental)

With `twoWayAudio: true` in a channel's options (off by default), the Home app's talk button reaches the camera's
speaker over the Baichuan session ([spec](../../docs/clean-room/ReolinkTalk.md)), for a camera or doorbell, a channel
of an NVR or Home Hub, and a battery camera on its own. Tried against fake devices only.

- **Only where the device says so.** At start, a channel whose abilities allow talk (HTTP `talk`, Baichuan
  `ipcAudioTalk` for the channel, or a camera's own `audioTalk`) is asked its talk ability (`cmd_id` 10): two-way
  audio needs `mixAudioStream`, or `followVideoStream` with full duplex, and mono 16-bit ADPCM at 8 or 16 kHz. Only
  then is the camera published with two-way audio (a Speaker); otherwise the log says why, once. Talk goes over the
  push session, so a device with `pushEvents: false` has none. A battery camera is asked once (that wakes it) and the
  answer is kept in `battery-cameras.json`.
- **A Talk** is one burst of speech (HomeswiftFFmpeg's return audio: FFmpeg decodes HomeKit's AAC-ELD into PCM at the
  camera's rate). It starts with `TalkConfig` (`cmd_id` 201: a 422, a Talk left open, is stopped with 11 and asked once
  more; a 400 of a battery channel behind a hub waking is asked again 1.5 s later, up to 3 times); its audio is IMA
  ADPCM, one block of 1025 samples (64 ms at 16 kHz) per `cmd_id` 202, all on one message number, each sent once the
  previous one is answered; the stop (`cmd_id` 11) waits until the audio sent has played, plus 100 ms. A camera slower
  than the audio drops the oldest blocks beyond three. A refused or unanswered block ends the Talk; after a refusal the
  next Talks send four blocks per message, as Reolink's own app does. One Talk at a time per channel.
- **Volume:** HomeKit's Speaker volume scales the samples (never above 100 %); the camera's own talk volume
  (`talkAndReplyVolume`, set in the Reolink app) is left alone. A siren switched on during a Talk waits for it to end
  (up to 10 s, then it is refused).
- **Battery cameras** stay awake while a Talk runs, and are let sleep 5 s after it, as after any use.

## Battery cameras on their own (Experimental)

Argus, Altas, battery doorbells and other Reolink battery cameras on their own Wi-Fi, not behind a Home Hub or NVR, have
no HTTP API: everything goes over Baichuan ([spec](../../docs/clean-room/ReolinkBattery.md)). Add one on **Add
accessories** by its address and a local user, as any device: when the HTTP API does not answer, Setup logs in over
Baichuan (TCP 9000) and reads the abilities (`cmd_id` 199, `battery` on channel 0); a battery camera is kept with
`batteryCamera: true` in its settings. A block written by hand says `"batteryCamera": true` in its `devices` entry.
Wake the camera first (press its button, or move in front of it): whether a sleeping camera wakes for a connection is
not known, and Setup says a camera that does not answer may be asleep.

- **What HomeKit gets:** a camera accessory (Video Doorbell for a model whose name says Doorbell, or `doorbell: true`)
  with live video and snapshots, a Motion Sensor (the PIR) and Battery (level, charging, low). No HomeKit Secure Video
  (it needs a prebuffer, so a camera always awake), no AI sensors, lights, siren or PIR switch; one stream at a time.
- **It sleeps.** The plugin never polls it: no periodic connection, snapshot or battery read. A Baichuan session is
  opened only when HomeKit asks for video, for a snapshot the cache cannot answer, or once after the camera wakes on its
  own (to read the battery and take a snapshot while it is up), and it is closed (logout) **5 seconds** after its last
  use. Logins are at least 15 s apart; one session at a time. A request the camera answers with 400 (still waking) is
  sent again 1.5 s later, up to 3 times; a connection gets 4 s, the nonce 5 s, a snapshot 10 s in all and a stream's
  first frame 15 s.
- **Accessory Information** comes from what Setup read (`VersionInfo`, the UID), kept in `battery-cameras.json`: the
  accessory is published at launch without waking the camera, and a camera not seen awake since shows its last state
  and snapshot rather than No Response. Its Device Id is its UID (`Reolink:<UID>`).
- **Snapshots** come from Baichuan's `cmd_id` 109 (the sub stream up to 640 wide), with the first I-frame of a short
  stream through FFmpeg when it fails. **Cache:** while the camera sleeps, every request is answered with the last image,
  whatever its age, and a `periodic` request (the Home app's every 10 s) never wakes it; a request for an `event` wakes
  it when the image is over 60 s old; while a session is open anyway, the image is refreshed when over 10 s old. A new
  image is also taken after each wake and at the end of each live stream. The last one is kept on disk for a restart.
- **Live video:** the media stream (`cmd_id` 3, the sub stream for sizes up to 640 × 360, the main one above; stopped
  with `cmd_id` 4) is split into its frames (H.264 or H.265, AAC or ADPCM audio), remuxed into MPEG-TS in Swift and
  piped to FFmpeg, which encodes for HomeKit as for wired cameras (H.265 is always encoded, H.264 copied with `vcodec:
  copy`). With `audio`, the camera's AAC goes along (its ADPCM is dropped); the TS header waits up to 2 s of video for it.
- **Events** need no connection: the camera posts them to the bridge (its webhook, `cmd_id` 806/807). The plugin
  listens on a port of its own (`webhookPort`; empty: one chosen once and kept in `webhook.json`), at
  `/reolink/<token>`, a random token kept in the vault and never logged. A wake by the PIR is motion, on for
  `motionTimeout` seconds (30; the camera never says it stopped), a wake by the doorbell button is a press. The camera
  has one webhook slot: when another receiver holds it (Home Assistant's Reolink integration), the plugin leaves it and
  logs so; `takeOverEventPush: true` in the camera's settings replaces it. A firmware without the webhook gets no
  motion or doorbell events at all (logged once).

## Configuration

Add devices on **Add accessories**: the plugin lists the Reolink devices of the network it can see (their MAC starts
with `EC:71:DB` and they answer on TCP 9000), and **Add by address…** adds any other (on another subnet, say). Setup
asks for the address when needed, the user name (`admin` unless you change it) and the password of a local user, signs
in, reads `GetDevInfo` and `GetChannelstatus`, and keeps the device under its host id (its P2P UID, else its MAC;
"Identity" above): the login in the vault and the address in its Accessory Settings. A block written by hand works
too:

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
| `devices[].batteryCamera` | `false` | A battery camera on its own, over Baichuan only (Experimental; Setup sets it) |
| `devices[].takeOverEventPush` | `false` | A battery camera's event push replaces another receiver's (its single slot) |
| `webhookPort` | chosen once | The port battery cameras post their events to; the cameras must reach it (a firewall opens it) |
| `devices[].cameras["<channel>"]` | | A channel's options, below; once the settings are saved they move into the channel's Accessory Settings |

A channel's options (also its Accessory Settings): `name`, `motionSensor` (true), `aiSensors` (every supported type),
`doorbell` (auto), `floodlight` (true), `siren` (false), `irLights` (false), `stream` (`auto`, `main`, `sub`), `audio`
(false), `recording` (false), `prebuffer` (false), `maxStreams` (2), `vcodec` (`libx264` or `copy`), `encoderOptions`,
`debug`, `ringThrottleSeconds` (3), `twoWayAudio` (false, Experimental: "Two-way audio" above), and for a battery camera
on its own `motionTimeout` (30 s).

New in the Accessory Settings: `presetSwitches` (false), `patrolSwitch` (false), `privacySwitch` (true), `recordingSwitch`
(false), `chimeSwitch` (false) and `chimeTone` (`citybird`, `originaltune`, `pianokey`, `loop`, `attraction`, `hophop`,
`goodday`, `operetta`, `moonlight`, `waybackhome`), `floodlightMode` (`off`, `auto`, `night`, `schedule`, `autoAdaptive`,
`adaptive`; only a mode the camera offers is taken), `motionSensitivity` (1 to 50, sent as the device's `sensDef` 51 − s)
and `aiSensitivity` (0 to 100, for every AI type the camera detects). The device-side ones (mode, sensitivities) are read
in one batch at start and written in one more, only where the device differs; empty leaves the device's own.

An accessory's settings sheet groups them: Sensors, Lights and switches, Video, and Connection (the address, ports,
protocol and refresh intervals).

### PTZ from the web UI, the Assistant and MCP clients

The camera's live view in the web UI has a pad that pans and tilts it a step at a time while held (a move stopped after
0.4 s), with its presets and its guard's home position beside it (HomeswiftPlugin's `CameraControls`).


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
- **Battery cameras behind a hub or NVR**: only commands that do not wake them (no `GetEnc`, `GetWhiteLed`,
  `GetAudioAlarm`), so their floodlight and stream codec are not read; their snapshots and streams wake them.
- An unreachable host leaves its cameras showing No Response and is retried with backoff; a channel that goes offline
  on an NVR shows No Response, and a new one appears at the next refresh.

The password, the token, the nonce, the login hashes, the AES key and URLs with credentials are never logged (stream
URLs are masked in FFmpeg's command lines).

## Gaps

Choices made where the spec is silent or leaves it open:

- **Standalone battery cameras** are Experimental and over **local TCP only** (spec 2.1): a camera that refuses TCP 9000,
  or whose abilities say Baichuan V3 over UDP (`netPort & 0x40`), is refused at Setup with a message to add it to a Home
  Hub instead; one that refuses TCP three times right after waking up is reported in the log the same way. Cellular
  models (Go) and cameras on another network (P2P relay) are out.
- **Whether a sleeping camera wakes for a TCP connection** is not settled by the sources (spec 13). The plugin takes
  the safe way: a connection that fails inside its 4 s is "asleep and out of reach", a snapshot is answered from the
  cache and a stream fails at once (HomeKit shows the camera as not available for that view) rather than retrying or
  holding the radio up. If your camera wakes only on motion, live view works after a wake, not before.
- **Battery cameras on wired power** (`powerSupplyStatus` `normal`) still stream over Baichuan: the spec's "RTSP first"
  recommendation is not done.
- **Battery camera choices:** one stream at a time (a single session); a doorbell is told by `Doorbell` in its model
  name (the sources give no ability for it; `doorbell` in the settings decides otherwise); camera timestamps that step
  back count as no time passing; the PIR switch (`cmd_id` 212/213), talk, floodlights and sirens of battery models, and
  AI sensors are not offered; the webhook is plain HTTP (the camera is told `verify_cert` 0) and its first check runs at
  Setup or at the first connection of a run; another receiver's webhook is replaced only with `takeOverEventPush`, not
  asked for in Setup.
- **Snapshot size:** an image whose length differs from the camera's `pictureSize` is accepted (and logged at debug)
  when it is a whole JPEG (starts `ff d8`, ends `ff d9`).
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
  is used for battery cameras on their own only.
- **Discovery** reads the ARP table, so it sees only devices the bridge's machine talked to lately; others are added by
  address. `ARPTable.entries()` was added to HomeswiftNetwork for it.
- **While push is active** the full refresh leaves the event commands out and a poll answered late is not applied, so
  an older poll never undoes a newer push.
- The spec's AES vector says its plaintext is 48 bytes; the text and the ciphertext it gives are 47, and they match.
- **Two-way audio** (Experimental) has been tried against fake devices only. Its open points, as the spec leaves them:
  - **The talk messages' `ch_id`.** Whether a camera takes 201, 202 and 11 with channel + 1 in header byte 12 (as every
    other channel command, and `cmd_id` 10) or the bare channel is not known. The plugin sends channel + 1 first; a
    TalkConfig refused with any status but 422 is asked once more with the bare channel, which is then kept for the
    channel's Talks; refused both ways, the Talk ends and the next one starts again from channel + 1.
  - **Full-AES sessions** (battery cameras): the audio's binary is sent in clear, as in AES sessions; whether such a
    camera wants it encrypted with an `encryptLen` is not known.
  - Whether an NVR or a hub relays a Talk to its channel's camera, formats other than ADPCM, a siren or chime during a
    Talk, and whether the camera checks the frame's block-size field are not known. The RTSP backchannel (PCMA on some
    models) is not used: battery cameras have none.
- **Baichuan over UDP** (P2P, port 2015) stays out: that transport is about as large as the whole plugin again; such
  cameras are supported behind a Home Hub or NVR.
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
Battery cameras on their own (`ReolinkBatteryTests`, a fake camera that sleeps, answers 400 while waking and speaks full
AES): the headers of ReolinkBattery.md 12.1 and the body lengths, its media frames (in one buffer, split at every
position, garbage, a duplicate, early audio, a split magic), the MPEG-TS remux (PAT and PMT with their CRCs, PTS), the
webhook bodies of 12.3, a snapshot in parts on another message number (12.4), the cache answering a sleeping camera and
a `periodic` request never waking it, the retry on 400, a live stream (byte 13, the stop's bytes 12 to 15, a snapshot
then a logout 5 s after), Setup by address, a UDP-only camera refused, another receiver's webhook kept, and the
accessory published from what Setup kept without a connection, its motion and doorbell from the webhook.
Two-way audio (`ReolinkTalkTests`, the fake devices answering 10, 201, 202 and 11): ReolinkTalk.md 9.1's headers, the
394- and 131-byte bodies, the media frames of 9.3, the ability fixture of 9.4 and its variants; a second of talk as 16
messages of 528 bytes on one message number, the volume, a 422 stopped first, the bare channel after a refusal, a waking
hub channel, a refused block and the four-frame fallback, an unanswered one, a dropped session (no stop), Talks in turn;
the Speaker only with the option and the ability, for a camera, an NVR channel and a battery camera kept awake while
it talks.

## Clean-room implementation

A new platform built on the behaviour of [reolink-aio](https://github.com/starkillerOG/reolink_aio) by starkillerOG (MIT
License) and its use in Home Assistant's `reolink` integration (Apache License 2.0), with homebridge-reolink-doorbell by
Alex (Ultra-Sack) (Apache License 2.0) for the doorbell's throttle and block. Written from the functional spec in
[docs/clean-room/Reolink.md](../../docs/clean-room/Reolink.md), without reading or copying their code. Interface facts
also come from Reolink's "Camera HTTP API User Guide" (version 7), as the spec quotes them.
