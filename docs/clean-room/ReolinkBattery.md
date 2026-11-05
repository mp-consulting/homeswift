# Reolink: standalone battery cameras (clean room)

## 0. Provenance

Written by the spec writer as a supplement to `Reolink.md`, which left standalone battery cameras out (§1, §7.5,
addendum E). It contains **no source code**. Baichuan message ids, header bytes, XML element names and bodies, the media
frame magics and layouts, JSON keys and the timings are given exactly because they are the interface. **Recommendation**
marks the spec writer's choices. Test vectors (section 12) were computed by the spec writer.

| Id | Source | What was taken | Version / commit | Licence |
|---|---|---|---|---|
| R | reolink-aio, `baichuan/baichuan.py`, `media_decoder.py`, `udp_protocol.py`, `webhook_server.py`, `xmls.py`, `api.py`, `enums.py` | how a battery camera is detected, TCP and UDP raced, the 5-second idle close, the webhook push (`cmd_id` 806/807, `HaCfg`) and its JSON, sleep/wake events, `BatteryInfo` (252/253), Baichuan snapshot (109), the media decoder (magics, headers, 8-byte padding, resynchronisation), no RTSP on battery power | `0.22.0`, commit `2da8b6bdba09e755f1167f32b146c18bd872b050` (2026-11-04) | MIT, `Copyright (c) 2023 starkillerOG` |
| N | neolink, `crates/core/src/bc_protocol/{stream,snap,battery,login}.rs`, `bc/{de,codex,crypto,xml}.rs`, `bcmedia/*`, `bc_protocol.rs` (connection choice), `connection/discovery.rs` (`check_tcp`), `README.md` (pause, idle disconnect, discovery), `dissector/{messages,mediapacket,udp}.md` | the live stream (`cmd_id` 3/4, `Preview`, header byte 13, handles), binary mode per message number, full-AES binary, BcMedia framing and fields, snapshot replies 200/201, battery list push, idle disconnect after 30 s, TCP check timings, UDP ports | commit `6e05e7844b5b50f89787d30bffcbbd3471bfcfde` (2025-01-30) | **AGPL-3.0**; nothing ported, protocol facts only |

The implementer must read neither. THIRD-PARTY-NOTICES: no code is ported.

## 1. Scope

Reolink battery cameras on their own Wi-Fi (Argus 2/2E/3/3 Pro/4 Pro, Argus PT/Eco, battery doorbell, Altas, Duo
battery…), not behind a Home Hub or NVR: no HTTP API, everything over Baichuan. What they give HomeKit: live video
(+ audio) on demand, snapshots, motion (PIR) and AI events, the doorbell button, battery level and charging, and talk
(`ReolinkTalk.md`). Cellular models (Go) are out of scope (they are not on the LAN).

Today the plugin refuses them (`ReolinkHTTP` "has no HTTP API" message). This spec adds a **battery host** kind beside
the HTTP host.

## 2. Reaching the camera

### 2.1 Local TCP 9000 (the path specified here)

- Same session as `Reolink.md` §5.3: nonce, login, AES. reolink-aio races a TCP connection to port 9000 and a UDP one and
  keeps whichever succeeds first; neolink tries TCP to `address:9000` first (a TCP connect plus a legacy login message
  answered within **4 s**) and only then UDP.
- **Local TCP alone suffices** when the camera accepts TCP on 9000 while it is awake (many Wi-Fi battery models do:
  reolink-aio would otherwise never win with TCP), and when the bridge reaches it in a few seconds after a wake.
- It does **not** suffice when:
  1. the camera refuses TCP 9000 (UDP-only firmware);
  2. its abilities say "Baichuan V3 over UDP-TCP" (host ability `netPort` with bit `0x40`, `Reolink.md` addendum A.2):
     reolink-aio then switches to its UDP transport for every later connection, even after a TCP login worked;
  3. the camera must be woken from deep sleep by a connection request it only honours over UDP (P2P) — not established
     by the sources (§13);
  4. the camera is on another network (P2P relay through Reolink's servers).
- **Recommendation:** v1 supports TCP only. At Setup, connect and log in over TCP; when TCP is refused or times out
  three times right after a wake event (§3.3), or `netPort & 0x40` is set, tell the user "this camera only talks over
  Reolink's UDP protocol, which Homeswift does not support yet; add it to a Reolink Home Hub instead".

### 2.2 UDP / P2P (not specified)

For the record (`Reolink.md` addendum E): UDP to port **2015** (and 2018), packets with magics `3acf872a` (connection
XML: `C2D_S`, `C2D_C` with the camera **UID**, `C2D_DISC`), `10cf872a` (Baichuan data, fragmented, MTU 1350),
`20cf872a` (acknowledgements); resend after 1 s, at most 3 resends, at most 10 unacknowledged packets; connection
messages given up after 10 s; heartbeat `cmd_id` 234 answered. Local discovery broadcasts to 255.255.255.255:2015;
remote/map/relay go through Reolink's servers. A separate spec would be needed.

### 2.3 Identity and host data (no HTTP)

| Need | Message | Body / reply |
|---|---|---|
| Model, firmware, serial, name | `cmd_id` 80 (VersionInfo), `ch_id` 250, no body | `VersionInfo`: `name`, `type` (model), `serialNumber`, `hardwareVersion`, `firmwareVersion`, `buildDay` |
| UID (Device Id) | `cmd_id` 114, `ch_id` 250, no body | `Uid/uid` |
| Abilities | `cmd_id` 199 (`Reolink.md` A.2) | host `battery` > 0 on channel 0 and not an NVR → battery camera; `netPort` (above) |
| Login reply | `DeviceInfo` | `type`, `typeInfo`, `channelNum` (1), `sleep` |

**Recommendation:** Device Id = the UID (as for hub channels), accessory id `Reolink:<UID>`; persist model and firmware
in the cache so that HomeKit's Accessory Information is right while the camera sleeps.

## 3. Sleep and wake

### 3.1 What the camera does

- It sleeps most of the time (radio in a low-power state) and wakes on: PIR motion, a doorbell press, its own schedule
  (cloud check-ins), the Reolink app connecting, and an incoming connection.
- **While a Baichuan session is open it stays awake** and drains its battery: neolink's README asks to disconnect idle
  cameras ("idle disconnect", 30 s after the last use) to save battery, and reolink-aio closes a battery camera's
  connection **5 s** after the last request it sent when no reply is pending (it also runs no keepalive for battery
  cameras).
- A request that reaches it while it is still waking is answered with status **400**: wait **1.5 s** and send again
  (reolink-aio, up to its retry count).
- Push `cmd_id` 145 (`ChannelInfo` with `channelId`, `loginState`: `standby` = asleep) reports sleep while connected.

### 3.2 Battery-friendly policy (Recommendation)

- **Never poll.** No periodic connection, no periodic snapshot, no periodic battery read.
- **Connect on demand only**: a HomeKit live stream, a snapshot that the cache cannot answer (§7), a Talk, a user's
  write (PIR switch), and once after each wake push (§6) to refresh battery and take a snapshot while the camera is up
  anyway.
- **Close when idle**: log out (`cmd_id` 2) and close **5 s** after the last request when no stream, Talk or reply is in
  progress (reolink-aio's value); never hold the event subscription (`cmd_id` 31) open on a battery camera.
- At most one connection at a time per camera; logins at most every 15 s (`Reolink.md` §5.3.2) — a wake push that comes
  sooner waits.
- Events reach the bridge by **webhook** (§6), which needs no connection.

### 3.3 Timeline of an on-demand connection

TCP connect (timeout 4 s) → nonce (timeout 5 s) → login → request; on status 400, 1.5 s and again (up to 3 times);
whole budget **10 s** for a snapshot, **15 s** for a stream's first frame. A camera that does not answer inside the
budget is "asleep and unreachable": answer HomeKit from the cache (snapshot) or fail the stream
(`serviceCommunicationFailure`).

## 4. Session specifics

### 4.1 Header byte 13 for media

The 24-byte header's bytes 12–15 are, in neolink's reading, `channel` (1 byte), **`stream type`** (1 byte) and a
16-bit message number — Homeswift reads bytes 13–15 as one 24-bit counter. For the media messages (`cmd_id` 3 and 4)
byte 13 must carry the stream code (main `0`, sub `1`, extern `0`) and the counter goes in bytes 14–15 (16 bits). Other
messages keep the 24-bit counter (its low byte then lands in byte 13; reolink-aio sends every command that way and
cameras answer, so byte 13 evidently does not matter for them). The reply and every
media message carry the same four bytes 12–15.

### 4.2 Binary mode

A reply whose extension contains `<binaryData>1</binaryData>` switches its full message id to **binary**: from then on
every message with that `cmd_id` and full message id carries binary data in its body (extension length 0, the whole
body binary) until the stream stops (a later extension with `binaryData` 0 switches it back). Received binary is not
encrypted in an "AES" session; see 4.4 for "full AES".

### 4.3 Status codes seen on media

200 (data follows), 201 (last part, snapshots), 400 (waking, retry), 401 (not logged in), 422 (busy). Anything else on
the start → the stream cannot start.

### 4.4 Full AES

The nonce reply's bytes 16–17 (`Reolink.md` §5.1) decide the session's encryption: `00 dd` none, `01 dd` Baichuan XOR,
`02 dd` AES, `12 dd` **full AES**. In full AES, a binary message's extension carries `<encryptLen>N</encryptLen>`: its
first N bytes of binary are AES-CFB encrypted (fresh IV), the rest clear (`Reolink.md` §5.2 already describes the
decryption). Battery cameras (Argus 2 in neolink's fixtures) use this.

## 5. Live media over Baichuan

### 5.1 Start and stop

Start — `cmd_id` **3**, `ch_id` = channel + 1, byte 13 = stream code (4.1), channel extension, AES body:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<Preview version="1.1">
<channelId>{channel}</channelId>
<handle>{handle}</handle>
<streamType>{mainStream|subStream|externStream}</streamType>
</Preview>
</body>
```

`handle`: `0` for mainStream, `256` for subStream, `1024` for externStream (the official client's values). Reply 200,
with an extension `binaryData` 1 and usually the first media bytes (the info frame) as its binary; then a continuous
series of binary messages (4.2), each status 200.

Stop — `cmd_id` **4**, same `ch_id`, byte 13 and message number as the start, the same `Preview` **without**
`streamType`. Wait at most **2 s** for its 200, then go on (neolink's timing); then log out and close when idle (3.2).

**Recommendation:** HomeKit's small sizes (≤ 640 wide) from `subStream` (usually 640×360 H.264), larger from
`mainStream` (often H.265 2K/4K, to transcode); the camera's main stream on battery cameras is often 2560×1440 or
2304×1296.

### 5.2 BcMedia framing

The binary bodies of all media messages, concatenated in order, form a byte stream of **media frames**; a frame may
start in one Baichuan message and end in a later one. All integers little-endian. Every frame starts with a 4-byte
ASCII magic:

| Magic | Kind | Header |
|---|---|---|
| `1001`, `1002` | Info (V1, V2) | 32 bytes in all: magic; uint32 header size = 32; uint32 width; uint32 height; 1 byte unknown (0/1); 1 byte fps (on some old cameras an index into a table); 6 bytes start year−1900, month, day, hour, minute, second; 6 bytes end time likewise; 2 bytes reserved |
| `d0dc` with `d` a digit `0`–`9` | **I-frame** (`00dc` normally; the digit is the channel on NVR recordings) | magic; 4 ASCII bytes codec `H264` or `H265`; uint32 payload size `n`; uint32 extra header size `x`; uint32 timestamp in **microseconds** (wraps at 2³²); uint32 unknown; then `x` bytes: when `x` ≥ 4 the first 4 are a POSIX time (seconds, UTC), the rest unknown; then `n` bytes of payload; then zero padding to a multiple of 8 of `n` |
| `d1dc` | **P-frame** | as the I-frame (24-byte fixed part, `x` extra bytes, usually 0), payload, padding |
| `05wb` | **AAC** audio | magic; uint16 payload size `n`; uint16 `n` again; `n` bytes (an ADTS frame: sync word, sample-rate index, 1024 samples); padding to 8 of `n` |
| `01wb` | **ADPCM** audio | magic; uint16 `P`; uint16 `P`; uint16 sub-magic (`00 01` or `00 7a`); uint16 half block size (or 2); `P − 4` bytes of DVI-4 IMA ADPCM block (`ReolinkTalk.md` §4); padding to 8 of `P`. Camera ADPCM is 8000 Hz (neolink's assumption) |

Video payloads are **Annex B** elementary streams (start codes `00 00 00 01`; SPS/PPS, and VPS for H.265, before each
I-frame), what FFmpeg's `h264`/`hevc` demuxers and MPEG-TS take directly.

Parsing rules (reolink-aio's decoder, which is tolerant):

- Need 8 bytes to read a magic and a short length; an info frame needs 32, a video frame 24 + `x` + `n` + padding.
- A frame whose payload is identical to the previous video frame is a duplicate the camera sometimes sends: drop it.
- Audio before the first video frame is pre-record audio: drop it (keeps A/V in step).
- Unknown bytes: search forward for the next known magic (any of `1001`, `1002`, `00dc`, `01dc`, `05wb`, `01wb`),
  skipping what lies before it; keep the last 3 bytes of a buffer in case a magic straddles two messages.
- Bound the buffer (e.g. 4 MiB); a larger frame is an error that ends the stream.

### 5.3 Feeding FFmpeg (Recommendation)

FFmpeg reads a pipe on standard input (`FfmpegProcess.writeStdin`); `RTSPSource` grows a variant that is "an input
argument list plus a writer task" instead of a URL.

- **First milestone, video only**: write each video payload as it comes to FFmpeg with
  `-f h264` (or `-f hevc`) `-framerate ‹fps›` `-use_wallclock_as_timestamps 1 -fflags +genpts+nobuffer -i pipe:0`, then
  the usual live-stream arguments (`RTSPCameraArguments.live` after its input). Start writing at the first I-frame
  (discard P-frames before it) so FFmpeg's first frame decodes.
- **With audio**: mux in Swift into MPEG-TS (as reolink-aio does): video PID with stream type `0x1B` (H.264) or `0x24`
  (H.265), AAC PID with `0x0F` (ADTS); PTS in 90 kHz = 90000 + (microseconds − first) × 9 / 100 (handling the 32-bit
  wrap); audio PTS counted on from the first audio frame by 1024 × 90000 / sampleRate per frame, moved forward to the
  video's when it falls more than 1 s behind; feed `-f mpegts -i pipe:0`. ADPCM camera audio has no MPEG-TS mapping:
  drop it (or decode it in Swift to PCM and send AAC… not worth it). reolink-aio waits for up to 2 s of video for the
  first audio frame before writing the TS header.
- Wait for the first I-frame up to the stream budget (15 s, 3.3); a typical battery camera sends one at start.
- Inactivity: the existing RTCP watcher ends the stream; on stop, send `cmd_id` 4 then close as 3.2.
- HomeKit Secure Video is **not** offered for standalone battery cameras: it needs a prebuffer, i.e. a camera always
  awake. (Recording only after a PIR wake would miss the first seconds; out of scope.)
- When the camera is on wired power (`BatteryInfo.powerSupplyStatus` = `normal`), reolink-aio offers its RTSP URLs
  instead (`rtsp://…/Preview_01_main`, `Reolink.md` §4.6); **Recommendation:** try RTSP first in that case and fall back
  to Baichuan media when `DESCRIBE` fails.

## 6. Push events without a connection: the webhook

### 6.1 Subscribing

- Supported when `cmd_id` **806** (read, `ch_id` 250, no body) answers 200; reolink-aio records the capability
  `bc_webhook` from that. Battery models whose firmware lacks it have **no motion push** at all (reolink-aio warns "no
  motion/AI push updates").
- Write with `cmd_id` **807**, `ch_id` 250, no extension, body:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<HaCfg version="1.1">
<enable>1</enable>
<url>{url}</url>
<verify_cert>0</verify_cert>
</HaCfg>
</body>
```

  then read 806 again: success when its `enable` is `1` and `url` equals what was written. Unsubscribe: the same body
  with `enable` 0 and an empty `url`.
- This is a **setting stored on the camera** (one URL only): Home Assistant's Reolink integration uses the same slot, so
  the last writer wins. **Recommendation:** read 806 first; if another URL is set, do not overwrite it silently — show
  it on the plugin page and ask (Setup step "use Homeswift for this camera's events"). Write 807 only when the URL
  changes.
- `url`: `http://<bridge address on the camera's network>:<port>/<path>`; reolink-aio runs its own HTTP server on a
  random port with path `/webhook`, and finds the local address with a UDP "connect" to the camera's address.
  **Recommendation:** a plugin-owned HTTP listener (as `Plugins/Dummy/Sources/WebhookServer.swift`), a fixed port in the
  plugin block (default 0 = chosen once and kept in the plugin's state), path `/reolink/<32 random hex>` generated at
  Setup and kept in `context.secretFile`; plain HTTP (the camera is told `verify_cert` 0 anyway, but HTTP avoids TLS on
  the camera's battery). Body cap 64 KiB; any method accepted; answer `200` with body `OK` at once, then process.

### 6.2 Payloads

The camera POSTs UTF-8 JSON, one of two shapes:

| Shape | Keys | Meaning |
|---|---|---|
| Event | `uid` (the camera's UID), `data`: `{"event": …, "reason": …}` | `event`: `sleep`, `wake`, `test`; `reason` (with `wake`): `pir` (motion), `doorbell` (button), `network`, `other` |
| Message | `uid`, `cmd` (integer `cmd_id`), `xml` (the XML a push of that `cmd_id` would carry, as text), optional `ext_xml` | parse `xml` exactly as the TCP push of that `cmd_id` (33 events, 145 sleep, 252 battery…) |

Rules (reolink-aio): ignore a body whose `uid` is not the camera's; `wake` + `pir` → motion on; `wake` + `doorbell` →
visitor on (a press); `sleep` → asleep, and clear a tamper state; `test` → "events work" (no state). Unknown events or
reasons: log once.

**Recommendation for HomeKit:** motion on from `wake`/`pir` or a 33 with `MD`/`other`, off after `motionTimeout`
(default 30 s) unless a later 33 says otherwise (a sleeping camera sends no "motion stopped"); doorbell
`ProgrammableSwitchEvent` single press on `wake`/`doorbell` or a rising `visitor`, throttled by `ringThrottleSeconds`
(`Reolink.md` §2.2). On any `wake`, if no connection is open, connect once to read the battery (§8) and refresh the
snapshot (§7), then close when idle.

### 6.3 While connected

The usual pushes arrive on the open session: 33 (`Reolink.md` §5.4.1; battery PIR as AI type `other`), 145 (sleep),
252 (battery). Do not subscribe with 31 on a battery camera (it would be one more reason to keep a session open).

## 7. Snapshots

- **Baichuan snapshot**, `cmd_id` **109**, channel command (extension, `ch_id` channel + 1), body:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<Snap version="1.1">
<channelId>{channel}</channelId>
<logicChannel>{channel}</logicChannel>
<time>0</time>
<fullFrame>0</fullFrame>
<streamType>{main|sub}</streamType>
</Snap>
</body>
```

  First reply 200 whose XML `Snap` has `fileName` and `pictureSize` (bytes). Then binary messages with `cmd_id` 109
  (extension `binaryData` 1): status **200** = a part, **201** = the last part (it may carry the final bytes). neolink
  notes the parts may come on **any** message number, so match on `cmd_id` 109 alone while one snapshot is in progress
  (reolink-aio allows one 109 at a time per channel). The JPEG is the concatenation; a total different from
  `pictureSize` is logged, not fatal (neolink) — reolink-aio treats it as an error. **Recommendation:** accept when the
  data starts with `ff d8` and ends with `ff d9`.
- reolink-aio uses 109 for every device without HTTP (`snapType` `sub` by default, with the sub stream's size when
  known); HA shows that image. Each 109 wakes the camera.
- Fallback: the first I-frame of a short sub-stream start (5.1) through FFmpeg `-f h264 -i pipe:0 -frames:v 1 -f image2 -`
  (reolink-aio's `to_jpeg`).
- **Cache policy (Recommendation):** HomeKit asks for snapshots every 10 s while the Home app shows the camera, and on
  events. Answer from the cached JPEG when the camera is asleep, whatever its age; refresh it (109) only on a wake push,
  at the end of a live stream (last frame), or when a request's `reason` is `event` and the cache is over 60 s old. Never
  wake the camera for a `periodic` request. Persist the last JPEG in the plugin's storage so a restart has an image.

## 8. Battery

- Push `cmd_id` **252** (`BatteryList` with one `BatteryInfo` per channel) right after login and on changes; request
  `cmd_id` **253** (channel command, extension, no body) → `BatteryInfo`. Fields: `channelId`, `chargeStatus`
  (`charging`, `chargeComplete`, `none` = discharging), `adapterStatus` (e.g. `solarPanel`), `voltage` (mV), `current`
  (mA, negative when charging), `temperature` (°C), `batteryPercent` (0–100), `lowPower` (0/1), `batteryVersion`,
  `powerSupplyStatus` (`normal` = on wired power, newer firmware). An unknown `chargeStatus` → discharging.
- HomeKit Battery service: Battery Level = `batteryPercent`; Charging State = 1 for `charging`, 0 otherwise
  (`chargeComplete` included); Status Low Battery = 1 when `lowPower` is 1 or the level < 20. Update only from pushes and
  from connections made for other reasons (3.2): the value may be hours old, which is fine for a battery.
- Optional PIR switch: read `cmd_id` 212 (`rfAlarmCfg`, extension `<rfId>0</rfId>`), write 213 with `enable` 0/1 and
  the rest as read. Off by default.

## 9. HomeKit mapping (Recommendation)

One external camera accessory per camera (`context.publishExternal`), as for wired cameras: Camera (live stream
from 5, snapshots from 7, AAC-ELD audio when the camera's audio is AAC, talk per `ReolinkTalk.md`), Motion Sensor,
Doorbell (battery doorbells), Battery. No HKSV, no floodlight/siren unless their abilities say so and only on demand.
`Not in Home` and Excluded follow GLOSSARY.md. A camera never seen awake since start shows its cached state, not "No
Response".

## 10. Timings and limits

| What | Value | Source |
|---|---|---|
| TCP connect / TCP check | 4 s | N |
| Retry on status 400 (waking) | 1.5 s, up to 3 times | R |
| Idle close after last request | 5 s (R); neolink 30 s | R, N |
| Login spacing | ≥ 15 s | R |
| Media stop reply wait | 2 s | N |
| Wait for first I-frame | 15 s budget (Recommendation) | — |
| Wait for audio before TS header | up to 2 s of video | R |
| Snapshot | one 109 at a time per channel; 10 s budget | R, Recommendation |
| Request size | ≤ 38 000 bytes | `Reolink.md` §5.1 |
| Media frame padding | 8 bytes | R, N |
| UDP (not specified) | port 2015/2018, MTU 1350, resend 1 s ×3, window 10, connect 10 s | R |

## 11. Logging and secrets

As `Reolink.md` §8; additionally the webhook path token is a secret (mask it in logs and on the plugin page), and the
UID is masked in logs (it lets anyone reach the camera through Reolink's P2P servers).

## 12. Test vectors (computed by the spec writer)

### 12.1 Headers (channel 0 → `ch_id` 1)

| Message | Bytes |
|---|---|
| 3 start subStream (byte 13 = 1, message number 0x0018 in bytes 14–15; extension 104 + body 171) | `f0 de bc 0a 03 00 00 00 13 01 00 00 01 01 18 00 00 00 14 64 68 00 00 00` |
| 4 stop subStream (same bytes 12–15; extension 104 + body 136) | `f0 de bc 0a 04 00 00 00 f0 00 00 00 01 01 18 00 00 00 14 64 68 00 00 00` |
| 109 snapshot sub (counter 0x19; 104 + 209) | `f0 de bc 0a 6d 00 00 00 39 01 00 00 01 19 00 00 00 00 14 64 68 00 00 00` |
| 253 battery (counter 0x1a) | `f0 de bc 0a fd 00 00 00 68 00 00 00 01 1a 00 00 00 00 14 64 68 00 00 00` |
| 806 webhook read (host, counter 0x1c) | `f0 de bc 0a 26 03 00 00 00 00 00 00 fa 1c 00 00 00 00 14 64 00 00 00 00` |
| 807 webhook write (host, counter 0x1b, body 196 bytes with the URL below) | `f0 de bc 0a 27 03 00 00 c4 00 00 00 fa 1b 00 00 00 00 14 64 00 00 00 00` |

Body lengths are of the templates above with `\n` line ends and a final `\n`: Preview (subStream, handle 256) 171,
Preview stop 136, Snap (`sub`) 209, HaCfg with `http://192.168.1.10:51828/reolink/0123456789abcdef` 196.

### 12.2 Media frames

- Info V2 (as recorded from a camera): `31 30 30 32 20 00 00 00 00 09 00 00 10 05 00 00 00 0f 78 0a 06 12 24 22 78 0a 06
  12 24 22 00 00` → 2304 × 1296, 15 fps, start 2020-10-06 18:36:34.
- I-frame header, H.264, 1000-byte payload, extra header 8 (time 1700000000), timestamp 123456789 µs:
  `30 30 64 63 48 32 36 34 e8 03 00 00 08 00 00 00 15 cd 5b 07 00 00 00 00 00 f1 53 65 00 00 00 00`, then 1000 bytes, no
  padding (1000 = 125 × 8).
- P-frame header, H.265, 13-byte payload, no extra header: `30 31 64 63 48 32 36 35 0d 00 00 00 00 00 00 00 4a 4f 5c 07
  00 00 00 00`, 13 bytes, then 3 zero bytes.
- AAC, 187 bytes: `30 35 77 62 bb 00 bb 00`, 187 bytes, 5 zero bytes.
- Parser checks: these four frames in one buffer; the same split at every byte position (across two "messages");
  6 bytes of garbage before the first magic (skipped); a duplicate P-frame (dropped); an AAC frame before the first
  video frame (dropped); a magic split `30 30 64` | `63 …` across two buffers.

### 12.3 Webhook bodies (invented UID)

```json
{"uid": "95270000AAAAAAAA", "data": {"event": "wake", "reason": "pir"}}
{"uid": "95270000AAAAAAAA", "data": {"event": "sleep"}}
{"uid": "95270000AAAAAAAA", "cmd": 252, "xml": "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<BatteryList version=\"1.1\">\n<BatteryInfo>\n<channelId>0</channelId>\n<chargeStatus>charging</chargeStatus>\n<adapterStatus>solarPanel</adapterStatus>\n<voltage>4083</voltage>\n<current>-396</current>\n<temperature>32</temperature>\n<batteryPercent>87</batteryPercent>\n<lowPower>0</lowPower>\n<batteryVersion>2</batteryVersion>\n</BatteryInfo>\n</BatteryList>\n</body>\n"}
{"uid": "95270000BBBBBBBB", "data": {"event": "wake", "reason": "doorbell"}}
```

→ motion on; asleep; battery 87 %, charging; ignored (other UID).

### 12.4 Snapshot replies

First reply XML `<body><Snap version="1.1"><channelId>0</channelId><fileName>01_20260105140240.jpg</fileName><time>0</time><pictureSize>23644</pictureSize></Snap></body>`,
then binary 109 messages of 16000 bytes (status 200) and 7644 bytes (status 201, `c9 00` → `0xc9` = 201 in bytes 16–17):
the JPEG is 23 644 bytes.

## 13. Open questions / unknowns

- **Waking over TCP**: whether a deeply sleeping camera wakes for a TCP SYN to port 9000, or only for UDP P2P traffic
  (or only from Reolink's servers), is not settled by the sources. If TCP only works while the camera is awake for
  other reasons, live view from HomeKit works only after a PIR/doorbell wake: measure on a device before promising it.
- **Which models accept TCP 9000 at all**, and what `netPort & 0x40` (V3 UDP-TCP) changes for TCP, are not listed.
- **Wake latency** (first answered request after a wake) is not measured anywhere; 1.5 s retries suggest a few seconds.
- **Webhook**: which `cmd` values a camera posts as "Message" bodies (252? 33?) and how often, how quickly after a PIR
  trigger, and whether it retries a failed POST, are not shown; whether `verify_cert` 1 with HTTPS works was not tried.
- **Header byte 13** as stream type is neolink's reading; Homeswift's 24-bit counter reading works for other messages.
  Whether the camera echoes the 16-bit number when the counter exceeds 65535 is unknown (keep counters small: restart
  at 1 on each connection, as the session already does).
- **ADPCM camera audio rate** (8000 Hz) is neolink's assumption; Reolink talk uses 16000 Hz.
- The meaning of the info frame's unknown byte and the frame headers' unknown fields; whether I-frames always carry SPS/
  PPS (assumed, since reolink-aio's MPEG-TS works without extracting them).
- **Snapshot size mismatch**: neolink tolerates a total different from `pictureSize`, reolink-aio rejects it; why the
  two differ is not explained.
- The UDP transport (2.2) is out of scope; without it some models cannot be supported.
