# IMOU

Puts IMOU cameras and doorbells (Dahua's consumer brand) in HomeKit, local first. Each camera channel is a camera
accessory of its own, added in the Home app like a second bridge with the bridge's setup code. Its live video and HomeKit
Secure Video come from its RTSP stream on the local network, its snapshots from its web interface, and its motion and
doorbell presses from its Dahua event stream, all signed in with the **safety code** printed on its label. The IMOU
cloud (the IMOU Open Platform, optional) lists your account's cameras for Setup and adds what only it does: privacy mode,
the siren, the spotlight and the camera's own motion detection, live video and snapshots when the camera cannot be
reached locally, and its alarms for a camera whose local event stream is down.

**Status: experimental.** Nobody has run it against a real IMOU camera or account yet: it is tested against a fake cloud
and a fake camera that behave as the [functional spec](../../docs/clean-room/Imou.md) describes (see [Tests](#tests)).
Please report what works on yours.

**Maintainer:** Mickael Palma.

## In HomeKit

| Service | When | From |
|---|---|---|
| Camera (live video, snapshots) | Always | The local RTSP stream (`cam/realmonitor`), else a cloud stream made for each session (`getStreamUrl`) |
| HomeKit Secure Video | A camera with a local address and safety code (`recording`) | The local stream only: the cloud's live quota is no place for recordings |
| Motion Sensor (Status Active) | Always (it records for HomeKit Secure Video) | The local event stream; the cloud's alarms when it is down |
| Doorbell | Ability `CallAbility` (a video doorbell) | The local event stream (`CallNoAnswered`, `BackKeyLight`), or the cloud's call alarms |
| Switch "Privacy" | Ability `CloseCamera` and a cloud account | `closeCamera`: on closes the camera; streams are refused at once while it is. With HomeKit Secure Video, HomeKit Camera Active is kept its inverse both ways: turning the camera off in the Home app closes it, and a poll that finds it closed (a privacy plan) turns it off there |
| Switch "Motion Detection" | Ability `MobileDetect` or `AlarmMD`, and a cloud account | The camera's own alarm arming (`mobileDetect` and `motionDetect`) |
| Switch "Siren" | Ability `Siren` and a cloud account | `sirenStart`/`sirenStop`; it shows off again after 15 seconds (the siren's state cannot be read). A security control: MCP and the Assistant change it only after you confirm |
| Lightbulb "Spotlight" | Ability `WhiteLight` or `ChnWhiteLight`, and a cloud account | `whiteLight`, On only (the API has no brightness) |
| Battery | Ability `Electric` and a cloud account | `getDevicePowerInfo`, low below 20 % |
| Switch "Person Detection" | `personDetectSwitch`, and ability `HeaderDetect`, `AiHuman`, `SMDH` or `SmdHuman` | `headerDetect`, `aiHuman` and `smdHuman`, those the abilities give: on when any reads on, written to each |
| Switch "Status Light", or the Camera Operating Mode's status indicator with HomeKit Secure Video | `statusLightSwitch`, ability `BreathingLight` | `breathingLight`, device-level (no `channelId`); `breathingLightStatus` for a camera that does not answer the enableType |
| Switch "Siren on Alarm" | `linkageSirenSwitch`, ability `LinkageSiren` | `linkageSiren` |
| Switch "Light on Alarm" | `linkageLightSwitch`, ability `WhiteLight`, `ChnWhiteLight` or `LinkageWhiteLight` | `linkageWhiteLight` |
| Switch "Night Vision" | `nightVisionSwitch`, ability `NVM` | `getNightVisionMode`/`setNightVisionMode`: on is `Intelligent` (another of the camera's modes without it), off is `Off`. The other modes are the `set_night_vision` action's |
| Speaker (two-way audio, experimental) | `twoWayAudio` `auto` or `on`, a camera with a local address and safety code | See **Two-way audio** below |
| Switch "Go to <preset>" per preset | `presetSwitches`, ability `CollectionPoint` | `getCollection` when the camera is published, `turnCollection`; it shows off again after a second |

The switches after Battery are off unless their Accessory Setting is on: each costs one call per enableType per poll. A
switch whose read answers `DV1019` or `DV1026` (the camera lacks it) is no longer read, and is left out from the next
start (`unsupported.json` in the plugin's directory). A failed read never turns a switch off.

**Actions** (MCP tools `Imou_<name>` and the Assistant, at the configure scope unless said): `list_cameras` (read: each
camera's state, switches, what it can do, night vision's mode and modes, and the SD card's status and use), `move` (up,
down, left, right, the diagonals, zoom in and out, or stop, for 100 to 10,000 ms; `PTZ` cameras zoom, `PT`/`PT1` cameras
do not, `PT2` cameras only go left and right; a move in another direction while one runs stops it first), `point`
(`controlLocationPTZ`'s `h`, `v` and `z`), `list_presets`, `go_to_preset`, `set_night_vision` (one of the camera's modes)
and `restart` (ability `Reboot`, after you confirm). The SD card (ability `LocalStorage` or `LocalStorageEnable`) is read
on a poll once an hour; its use is recorded for the Status page's history (`sdcard:<deviceId>`).

Accessory Information has Manufacturer Imou, the camera's model, its serial (the cloud's `deviceId`) and the leading
numbers of its firmware version. The accessory's id is `Imou:<deviceId>:<channelId>` (`Imou:8L0DF93PAZ55FD2:0` for a
single-lens camera), so it keeps its identity whether it came from the cloud or was added by address.

- **Snapshots** come from the camera's `snapshot.cgi`, else a frame of its local sub stream through FFmpeg, else the
  cloud (`setDeviceSnapEnhanced`: about 3 seconds and quota, so kept a minute and never more than once a second). A
  closed or offline camera answers with its last picture.
- **Motion** lasts as the camera's Start and Stop say, `motionTimeout` (15 s) at most without a Stop; a cloud alarm is a
  motion of `motionTimeout`. The first alarm the cloud shows after a start is only noted, never reported.
- **A camera that does not answer locally** three times in a row is used through the cloud, and tried locally again every
  five minutes.
- **Battery cameras** are never woken for a poll: they keep their last state. A stream or a snapshot wakes one first
  (`wakeWait`), and a change that a sleeping camera refuses is sent once more after `dormantRetryWait`.
- A cloud camera that is offline shows **No Response**, unless it is reachable locally.

### Two-way audio (experimental)

Off unless a camera's `twoWayAudio` Accessory Setting says otherwise (docs/clean-room/ImouTalk.md). With `auto`, the
camera is asked once when it is published whether it has a speaker (`devAudioOutput.cgi?action=getCollect`, `result=1`
or more), and, when it does not say, whether its stream has an ONVIF backchannel track; `on` takes it for granted. Only
then is it published with two-way audio, which gives it the Speaker service and the Home app its talk button; a camera
that could not be asked (unreachable) is asked again at the next start.

Each Talk (HomeKit's return audio, from the first decoded audio to a second of silence, ten minutes at most) is decoded by
FFmpeg (`HomeswiftFFmpeg`'s return audio) and sent to the camera:

- **HTTP**, first: `POST /cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=<n>` on a connection of its own,
  `Content-Length: 9999999`, Digest signed with a challenge under five minutes old (a `401` before the audio is answered
  once on a new connection), then G.711 A-law at 8 kHz (`talkCodec`: µ-law, or AAC in ADTS through a second FFmpeg) in
  writes of 1024 bytes, at most three waiting; the connection closes once the last audio has played.
- **The RTSP backchannel**, when `postAudio` answers 400, 404 or 501 or the port refuses (from the next Talk on), or
  with `talkMethod` `rtsp`: `DESCRIBE` of the main stream with `Require: www.onvif.org/ver20/backchannel`
  (`unicast=true&proto=Onvif`), `SETUP` of its `sendonly` track over interleaved TCP, `PLAY`, RTP packets of 1024 bytes of
  G.711 (PCMA, then PCMU, then AAC as the track offers), `GET_PARAMETER` to keep it alive, `TEARDOWN` at the end. A
  session per Talk, never on FFmpeg's video connection. `talkZeroTimestamps` sends every packet with timestamp 0.

The Speaker's volume scales the samples (IMOU has no speaker volume setting the spec covers); a mute ends the Talk. A
`503` or a connection the camera closes at once is "the camera's speaker is busy", warned once. The safety code, the
`Authorization` headers and the SRTP keys are never logged.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "Imou",
      "name": "Imou",
      "appId": "lc0123456789abcdef",
      "region": "eu",
      "devices": [ { "host": "192.168.1.40", "name": "Porch" } ]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `appId` | | Your developer app's App Id, from [open.imoulife.com](https://open.imoulife.com/consoleNew/myApp/appInfo) (My App, App Information). Setup asks for it with its App Secret |
| `appSecret` | | A hand-written block's App Secret (a secret-named key, so the bridge seals it); it moves into the vault at the next settings save |
| `region` | `sg` | `sg`, `eu`, `na` or `cn`: the portal your app was made in |
| `apiUrl` | | Another host, or a whole base address (`https://openapi.easy4ip.com/openapi`) |
| `pollingInterval` | 300 | Seconds between polls of the cloud's switches, 30 to 900 |
| `alarmPollInterval` | | Empty: the cloud's alarms every 60 s, only for a camera whose local event stream is down. 0: never. 30 or more: that often, also for cameras without a local address |
| `motionTimeout` | 15 | Seconds a motion lasts without a Stop |
| `resolution` | `HD` | Cloud live video: `HD` (main stream) or `SD` |
| `snapshotWait` | 3 | Seconds a cloud snapshot is given to upload, 1 to 9 |
| `wakeWait` | 4 | Seconds a sleeping camera is given to wake |
| `dormantRetryWait` | 5 | Seconds before a sleeping camera's one retry, 5 to 60 |
| `videoProcessor` | `ffmpeg` | The FFmpeg to run |
| `encoder` | `libx264 -preset ultrafast -tune zerolatency` | FFmpeg's video encoder for live video; `copy` sends the camera's H.264 |
| `devices[]` | | Cameras by address (`host`, `name`) for Setup to add: those the account does not list, or all of them without an account |

Each camera's own settings (its Accessory Settings, in `_accessories` by Device Id): `host`, `httpPort` (80), `rtspPort`
(554), `username` (`admin`), `localEvents` (on), `motionTimeout`, `privacySwitch`, `motionDetectSwitch`, `sirenSwitch`,
`lightSwitch` (all on when the camera has the ability), `personDetectSwitch`, `statusLightSwitch`, `linkageSirenSwitch`,
`linkageLightSwitch`, `nightVisionSwitch` and `presetSwitches` (all off), `recording` (on) and `encoder`. Its safety code is in the vault.
A hand-written `devices` entry may also carry its `deviceId`, these options and its safety code as `password` (or
`safetyCode`); the next settings save moves it into `_accessories` and the code into the vault. Both names are
secret-named: the bridge seals them in config.json and masks them until then.

**Setup.** On Add accessories, the account asks for the App Id, the App Secret and the region, and checks them by fetching
a token; the App Secret goes in the vault. Its cameras are then listed, each asking for its address on your network and
its safety code (and its user name, `admin` unless changed): the plugin checks the code on the camera and that the camera
at that address is the one the account lists. Leave them empty to use a camera through the cloud alone. A camera of
`devices` (by address) asks for its safety code; its serial, read from the camera (`magicBox.cgi?action=getSerialNo`,
else the realm of its Digest challenge, `Login to <serial>`), becomes its Device Id, the same as the cloud's `deviceId`, so
the camera keeps its accessory if the account lists it later. A camera neither lists is added with **Add by address…**
on the instance (`start_setup` with `addByAddress: true` through MCP), with or without an account: it asks for the
camera's address, checks that something answers there ("No camera answered at 192.0.2.60"), then asks for its safety code
and reads its serial the same way. The address and user name go in the camera's Accessory Settings under its serial, the
safety code in the vault.

**The cloud's limits.** A developer account has 20,000 calls a day and, on a free account, 5 devices (`FL1001` beyond:
use a second account, or share the camera to one). At 300 s, a camera with all four switches costs about 1,500 calls a
day. The plugin estimates its calls at start-up and warns above 15,000, counts them per UTC day, polls half as often once
past 18,000, and stops polling (but not your changes) at 19,500 until midnight UTC. Privacy, the spotlight and motion
detection are read on every poll; when the switches after them would take the day past 15,000, they are read on one
poll in as many as keep it under (said in the log), and on none once past 18,000. A method the cloud says is spent for
the day (`OP1014`) is not called again until midnight UTC.

## How it talks to the cameras

- **The cloud**: a JSON `POST` to `https://<host>/openapi/<method>`, signed with a fresh nonce: the documented Base64
  HMAC-SHA256 of `time:<time>,nonce:<nonce>,appSecret:<secret>`, keyed with the hex SHA-256 of the secret; an account
  whose token request refuses it (`SN1001`) is signed with the MD5 hex of the same text, as IMOU's own libraries send it,
  from then on (until a restart); the access token is fetched once, again five minutes
  before it expires, and on `TK1002` (one refresh, one retry). A `currentDomain` in the token's answer moves the account to
  that host. A refused App Id or App Secret (`SN1001`, `SN1004`, `OP1008`) marks the account Needs Authorization, and no
  cloud call is made again until Setup. A device's own error code to a poll is logged once and leaves the other devices
  polled. An `apiUrl` in plain HTTP is warned of: the access token would cross the network unencrypted.
- **The camera**: Dahua's HTTP CGI with Digest authentication; the event stream is
  `eventManager.cgi?action=attach&codes=[VideoMotion,…]&heartbeat=5` (the brackets as written, `[All]` if the camera
  refuses the list), a multipart stream parsed by each part's length. It reconnects with backoff (1 to 60 seconds),
  logged once per outage; 30 seconds of silence is a dead connection; a refused safety code or a camera without the CGI
  stops it, and the cloud's alarms stand in.

The App Secret, the access token, the signatures, the safety codes, the snapshot addresses (their query is a credential)
and the cloud's stream addresses are never logged.

## Gaps

What the spec leaves open, and what this version chose:

- **The local serial** is read with `magicBox.cgi?action=getSerialNo` (Dahua's HTTP API, which the spec does not cover;
  `sn=<serial>`), else from the Digest realm the spec shows (`Login to <serial>`). Never from the address.
- **Local CGI and RTSP on IMOU models** are unverified by any IMOU source: some models or firmware may not answer them,
  or need RTSP turned on in IMOU Life. Such a camera falls back to the cloud.
- **Dahua event codes** beyond `VideoMotion` and `AlarmLocal` (`SmartMotionHuman`, `SmartMotionVehicle`,
  `CrossLineDetection`, `CrossRegionDetection`, and the doorbell's `CallNoAnswered` and `BackKeyLight` with `State` 1) are
  the spec's recommendation, unverified on IMOU.
- **The cloud's push** (`setMessageCallback`) is not used: it needs a public HTTPS address the platform reaches and
  probes, and describes no signature to check what is posted to it. The cloud's alarms
  are polled instead, only when they stand in for a camera's local events (`alarmPollInterval`).
- **`getStreamUrl`'s stream**: only its `url` is known; it is read over TCP and made again for every session.
- **Two-way audio is tested against fakes only.** Neither `postAudio` nor the backchannel has been tried on an IMOU (or
  Dahua) camera: which models answer them, which codecs their speakers accept, and whether the backchannel wants zero
  timestamps are unknown, hence off by default. Battery cameras (cloud only) get none: IMOU's cloud intercom is
  undocumented. Choices where the spec is silent: the receiver binds its port even while the Speaker is muted (an unmute
  during the stream then works); a 16 kHz Talk sent as G.711 (an AAC `talkCodec` with a PCMA backchannel) is halved by
  averaging pairs of samples; L16 backchannel tracks are skipped; a `401` arriving after the first audio ends the Talk;
  the backchannel's `GET_PARAMETER` answers are not awaited. The real-FFmpeg AAC-ELD test of the spec is not written
  (it needs an AAC-ELD encoder to make HomeKit's packets).
- **PTZ** goes through the cloud only: Dahua's local `ptz.cgi` is unverified on IMOU firmware. The speed form
  (`horizontalSpeed`, `verticalSpeed`) is not used. `controlMovePTZ`'s `operation` is sent as a string, as the
  documentation's sample does, and as a number from then on if the cloud answers `OP1003`.
- **`getCollection`'s answer** is undocumented: preset names are read from any list of strings, or of objects with a
  `name`, in its `data`. A device-level switch goes without `channelId`, and once with `"0"` if the cloud answers
  `OP1003`.
- **Not in this version:** the other switches of the spec's long list (WDR, flip, smart tracking, sounds, the abnormal
  sound alarm and the rest of the documentation's table), SD card formatting, and IoT devices (plugs, bulbs, sensors with
  a `productId`), which are skipped. A local-only camera is its channel 0 only (an NVR's other channels come through the
  cloud's listing).
- **The day's call count**, the signature that works and the methods spent for the day are kept in memory: a restart
  starts them again.

## Tests

`swift test --filter ImouTests` runs the plugin against a fake cloud and a fake camera, with no device, account or
network: the signature vectors (MD5 and HMAC-SHA256, the documentation's worked example among them), the MD5 fallback, the
addendum's PTZ and privacy bodies and each switch's, the spec's `deviceOnline` body, the Digest vector, the event stream byte by byte with
a multi-line `data` block, the token's one refresh shared by concurrent calls and its one retry, the regional redirect,
paging, the device list's abilities and channels, IoT devices skipped, each service, polls counted over several cycles
(one `deviceOnline` and the switches, nothing else), writes sent once and refused writes put back, the siren's return to
off, motion from local events and from new cloud alarms, the `[All]` fallback, a wrong safety code stopping the stream,
cloud snapshots kept a minute, sleeping cameras never woken by a poll, No Response, Setup for the account and for cameras
by address and from the account, the canonical shape, and logs without secrets; the switches gated by their abilities and
settings, the combined reads, a switch the camera lacks left out, coalesced writes, privacy and HomeKit Camera Active both
ways, PTZ moves gated and stopped before turning, presets, restart, the SD card hourly, and the quota governor counted
poll by poll; two-way audio's Digest, RTSP Digest, probe, SDP, interleaved RTP and pacing vectors, `postAudio` written in
1024-byte pieces with its head and Digest checked, the `401` retry, the fallback to the backchannel after a `404`, the
backchannel session request by request, and the Speaker given only by `twoWayAudio` and the camera's answer.

## Clean-room implementation

No Homebridge plugin exists for IMOU. Written from the functional spec in
[docs/clean-room/Imou.md](../../docs/clean-room/Imou.md), without reading or copying the code of the projects it
describes: user2684's [imou_life](https://github.com/user2684/imou_life) and [imouapi](https://github.com/user2684/imouapi)
(MIT), IMOU's own [Imou-Home-Assistant](https://github.com/Imou-OpenPlatform/Imou-Home-Assistant) and
[Py-Imou-Open-Api](https://github.com/Imou-OpenPlatform/Py-Imou-Open-Api) (MIT), and Kusha Gharahi's
[homebridge-dahua-alerts](https://github.com/kushagharahi/homebridge-dahua-alerts) (MIT) for the local event stream.
`magicBox.cgi?action=getSerialNo` follows Dahua's published HTTP API, which the spec does not cover. Two-way audio was
written from [docs/clean-room/ImouTalk.md](../../docs/clean-room/ImouTalk.md) and
[docs/clean-room/ReturnAudio.md](../../docs/clean-room/ReturnAudio.md) alone, without reading go2rtc or Scrypted (the
sources that spec cites); Dahua's HTTP API document was not needed beyond it. The addendum (PTZ,
the switches, privacy and Camera Active, the SD card, restart and the HMAC-SHA256 signature) also draws on IMOU's public
Open Platform documentation.
