# Tapo battery camera (Streamd, port 8800): functional specification

## 0. Provenance

- Source 1: https://github.com/JurajNyiri/pytapo (Python library, PyPI `pytapo`). Commit read:
  `088d14fc9873351ab0e1bb86267b57d51451ecb2` (shallow clone of the default branch, committed 2026-10-23).
  Files read: `pytapo/media_stream/session.py` (`HttpMediaSession`), `crypto.py`, `_utils.py`, `streamer.py`,
  `snapshot.py`, `pes.py`, `tsReader.py`, `downloader.py` (error handling only), `pytapo/__init__.py` (media session
  construction, battery and detection methods), `pytapo/const.py` (error codes), `test_pytapo.py` (canned replies),
  `README.md`.
  License: MIT. Copyright line as it appears in `LICENSE`: "Copyright (c) 2020 Juraj Nyíri".
- Source 2: https://github.com/AlexxIT/go2rtc, package `pkg/tapo/` (`client.go`, `producer.go`, `backchannel.go`),
  plus the MPEG-TS stream type constants in `pkg/mpegts/demuxer.go` and `internal/tapo/README.md`. Commit read:
  `990f4de3cc21d1cca917d02d0bc40f2fabe75a49` (committed 2026-11-05).
  License: MIT. Copyright line as it appears in `LICENSE`: "Copyright (c) 2022 Alexey Khit".
- Source 3: the user's own bridge `tapo-onvif` (local checkout, commit `a90ef979f316bc052590b8dfcbfb5e45f9fe612d`,
  MIT, the user's own project): `src/tapo_to_rtsp.py`, `src/snapshot_server.py`, `README.md`, `CHANGELOG.md`,
  `CLAUDE.md`, `docs/*.md`, and the commit messages of `f681dca`, `7577c8a`, `3acfcb6`. It runs pytapo against a real
  C675D. Its configuration files and secrets were not read into this document; every credential below is a placeholder
  (`owner@example.com`, `ExamplePassw0rd!`).
- Source 4: facts the coordinator relayed from the user's live tests that are **not written down in any of the above**
  (marked "[live, relayed]" where used): VGA gives one 1280x720 H.264 stream of the tele lens whatever the channel;
  firmware 1.1.7.
- Written by the spec writer; **contains no source code** from the sources. Everything is a description in my own words,
  wire formats, constants, and test vectors I computed myself (section 13) with my own script and the `openssl` CLI;
  no reference code was executed.
- Labels: **Recommendation** marks advice beyond the sources; **[pytapo]**, **[go2rtc]**, **[tapo-onvif]** say which
  source shows a behaviour when they differ.

## 1. Scope

A TP-Link Tapo battery camera (first target C675D: dual lens, solar/battery) streams live video only through
TP-Link's "Streamd" media server on **TCP 8800**: one plain-TCP HTTP/1.1 connection, HTTP Digest authentication with
a hash of the TP-Link **cloud** password, then a never-ending `multipart/mixed` body in each direction. The camera's
parts carry AES-128-CBC encrypted MPEG-TS. There is no RTSP and no ONVIF on these models.

Battery models authenticate only the **primary owner's** cloud account (no shared users, no camera account)
[tapo-onvif README]. The Streamd user name is always the literal `admin`; the cloud e-mail is **not** used on port
8800 (it is used only by the separate control API on 443, section 9).

## 2. Connection and initial request

1. Open TCP to `<host>:8800`. Connect timeout 10 s [pytapo `CONNECTION_TIMEOUT`].
2. Send an unauthenticated request. Exact bytes as pytapo sends them (known to work on the C675D through tapo-onvif):

       POST /stream HTTP/1.1\r\n
       Content-Type: multipart/mixed;boundary=--client-stream-boundary--\r\n
       Connection: keep-alive\r\n
       Content-Length: -1\r\n
       \r\n

   No `Host` header, no body. go2rtc sends the same request line through Go's HTTP writer instead: it adds
   `Host: <host>:8800`, a `User-Agent`, a zero (or absent) `Content-Length`, and writes the Content-Type with a space,
   `multipart/mixed; boundary=--client-stream-boundary--`. Both are accepted by cameras, so the server is lenient
   about these headers.
   - Hub children only: pytapo adds a query string `?deviceId=<child id>&playerId=<uuid>&type=video` and the header
     `X-Client-UUID: <playerId>`; go2rtc adds `?deviceId=<id>` alone. Not needed for a camera on its own Wi-Fi.
     The Digest `uri` stays `/stream` in pytapo even with a query string; go2rtc uses the path with the query.
3. The camera answers `401` with a Digest challenge, e.g. (values invented; the field set is what both sources read):

       HTTP/1.1 401 Unauthorized\r\n
       WWW-Authenticate: Digest realm="streamd-example",nonce="6f1c2a9e3b7d4c58",qop="auth",opaque="64943214",algorithm="MD5",encrypt_type="3"\r\n
       \r\n

   - Parse the value after the first space as comma-separated `key=value`, quotes removed. Fields used: `realm`,
     `nonce`, `qop` (go2rtc reads it; pytapo always answers `auth`), `opaque` (pytapo **requires** it, so the camera
     always sends one in practice; go2rtc includes it only when present), `encrypt_type`.
   - `algorithm="MD5"` is the Digest algorithm; it says nothing about the password prehash (section 3).
   - The 401 may carry a body without a usable length: pytapo reads only up to the blank line and then copes with
     a following status line that arrives glued to stray text (it documents a camera replying
     `HTTP ERROR 401HTTP/1.0 200 OK`). **Recommendation:** after the 401, discard bytes up to the first `HTTP/` of the
     next response, and accept `HTTP/1.0` or `HTTP/1.1`.
4. Resend the **same request on the same connection** with an `Authorization` header (pytapo appends it after the
   three headers above). pytapo's exact layout:

       Authorization: Digest username="admin",realm="<realm>",uri="/stream",algorithm=MD5,nonce="<nonce>",nc=00000001,cnonce="<cnonce>",qop=auth,response="<response>",opaque="<opaque>"

   go2rtc's layout (also accepted): `Digest username="admin", realm="…", nonce="…", uri="/stream", qop=auth,
   nc=00000001, cnonce="…", response="…", opaque="…", algorithm=MD5` (comma-space separated; `opaque` and `algorithm`
   only when the challenge had an opaque).
   - `cnonce`: pytapo = 24 random bytes as 48 lowercase hex characters; go2rtc = 32 random alphanumerics. Any random
     token works. `nc` is always `00000001` (one request per challenge).
   - `response` = RFC 2617 Digest with qop `auth`, all hex lowercase:
     `HA1 = MD5hex("admin:" + realm + ":" + P)`, `HA2 = MD5hex("POST:/stream")`,
     `response = MD5hex(HA1 + ":" + nonce + ":" + nc + ":" + cnonce + ":" + "auth" + ":" + HA2)`,
     where **P is the hashed cloud password** of section 3 (uppercase hex text), never the plaintext.
5. Success is `200` with, at least:

       HTTP/1.0 200 OK\r\n            (or HTTP/1.1)
       Content-Type: multipart/mixed;boundary=--device-stream-boundary--\r\n
       Key-Exchange: username="admin" nonce="9a4cf1e07b2d4e8f8c1b3a5d6e7f9012"\r\n
       \r\n

   (values invented). pytapo fails the session if `Key-Exchange` is missing. It takes the boundary from the
   Content-Type's `boundary=` parameter, defaulting to `--device-stream-boundary--`; go2rtc hard-codes that default.
   - `Key-Exchange` format: space-separated `key="value"` tokens. pytapo's parser requires every token to contain `=`,
     so the value has **no bare leading word** such as `Streamd` on the cameras it supports. go2rtc only searches the
     text for `nonce="…"`, `username="none"` and `encrypt_type="3"`. **Recommendation:** parse tolerantly (skip tokens
     without `=`), take `nonce` (required) and `username` (default `admin`).
6. A wrong password gives another `401` on the second request. pytapo then retries once with MD5 (section 3).
   The TCP connection stays open after the 200 and carries both multipart bodies (section 5).

## 3. Password hash: which one, in what order

- `P_MD5 = uppercase hex of MD5(cloud password UTF-8)` (32 characters).
- `P_SHA256 = uppercase hex of SHA-256(cloud password UTF-8)` (64 characters).
- Selection [pytapo and go2rtc agree]: if the 401 challenge contains `encrypt_type="3"`, use `P_SHA256`; otherwise
  `P_MD5`. go2rtc also looks for `encrypt_type="3"` in `Key-Exchange` when deriving the AES key; pytapo reuses the hash
  that authenticated.
- Fallback [pytapo only]: if the SHA-256 attempt gets `401`, open a **new TCP connection**, get a fresh challenge and
  authenticate with `P_MD5` ("some firmware advertises 3 but only accepts MD5"). No fallback in the other direction.
  go2rtc has no fallback, but lets the user pass a prehashed password with user `admin` instead.
- The C675D advertises `encrypt_type="3"` and authenticates with SHA-256 [tapo-onvif README: "HTTP-Digest auth
  (SHA-256 + cnonce + encrypt_type=3)"].
- The plaintext password is never sent. The same hash `P` feeds the AES key (section 4).
- Lockout: the 443 control API counts failed logins (10 attempts, `-40401`/`time`/`max_time` counters seen by
  tapo-onvif over BLE). Whether port 8800 failures count too is unknown. **Recommendation:** after an authentication
  failure on both hashes, stop and report a credential error; do not retry in a loop.

## 4. AES key, IV, mode, what is encrypted

Inputs: `nonce` and `username` from `Key-Exchange` (not the Digest nonce), and `P` (section 3, the uppercase hex
text, as ASCII bytes).

- `key = MD5(nonce + ":" + P)` — the raw 16-byte digest (AES-128).
- `iv  = MD5(username + ":" + nonce)` — raw 16 bytes; `username` is the Key-Exchange value, normally `admin`
  [pytapo]; go2rtc always uses `admin` (or `none`, below), which is the same in practice.
- Encryption-off variant: when `Key-Exchange` has `username="none"`, `key = MD5(nonce + ":" + "TPL075526460603")`,
  `iv = MD5("none:" + nonce)`. The constant is a fixed key published with CVE-2022-37255 [go2rtc]; pytapo takes it as
  a caller-supplied "super secret key". Not expected on current firmware; support is optional.
- Mode: **AES-128-CBC, PKCS#7 padding**, and the **IV is reset to `iv` for every part**: each multipart part body is
  an independent CBC message (no chaining across parts). Decrypt the whole `Content-Length` bytes (a multiple of 16),
  then strip the padding. A padding error almost always means the wrong password hash [pytapo's own error text].
  go2rtc strips the last byte's count without checking; **Recommendation:** check PKCS#7 and treat failures as an
  error for that part.
- What is encrypted: camera → client parts whose header `X-If-Encrypt` is `1` (media parts always are on the C675D;
  JSON replies may be either). Client → camera: the preview request is sent **in clear** by both sources (no
  `X-If-Encrypt` header). pytapo can encrypt an outgoing part (same key/IV, padded, `X-If-Encrypt: 1`) but never does
  for live view.

## 5. Multipart framing

### 5.1 Client → camera

Boundary parameter `--client-stream-boundary--`; each part starts with `--` + boundary, i.e. the line
`----client-stream-boundary--`. Exact bytes of the live-view request part:

    ----client-stream-boundary--\r\n
    Content-Type: application/json\r\n
    Content-Length: <decimal byte count of the JSON>\r\n
    \r\n
    <JSON>\r\n

- pytapo also sends `X-Data-Window-Size: <n>` before the blank line (Streamer default 50, session default 500);
  go2rtc does not. Not needed for live view.
- A non-JSON part (talkback audio) also carries `X-If-Encrypt: 0|1` and `X-Session-Id: <id>`.
- No closing boundary is ever sent; the client stops by closing TCP.
- Acknowledgements [pytapo only, for recordings]: when a received part's sequence (`X-Data-Sequence` header or JSON
  `seq`) is a multiple of the window size, pytapo sends a part with headers `X-Session-Id`, `X-Data-Received:
  <window * (seq div window)>` and `Content-Length`, body `{"type":"notification","params":{"event_type":"stream_sequence"}}`.
  Its own comment says the live stream is never acknowledged, and go2rtc never acknowledges. **Recommendation:** do
  not acknowledge for live view.

### 5.2 Camera → client

Boundary `--device-stream-boundary--` (or the one from the 200's Content-Type); part delimiter line
`----device-stream-boundary--`. Each part:

    ----device-stream-boundary--\r\n
    Content-Type: video/mp2t\r\n
    Content-Length: 18816\r\n
    X-If-Encrypt: 1\r\n
    X-Session-Id: 7\r\n
    \r\n
    <exactly Content-Length bytes>
    (possibly \r\n before the next delimiter)

- Reading rule (pytapo): find the delimiter, discard everything before it, read headers up to the blank line, read
  exactly `Content-Length` bytes. Headers: `Content-Type`, `Content-Length` (always), `X-If-Encrypt` (always; pytapo
  fails without it), optional `X-Session-Id`, optional `X-Data-Sequence`.
- Content types seen: `video/mp2t` (media), `application/json` (replies and notifications), `image/jpeg` (snapshot
  downloads, section 10), `audio/mp2t` (client talkback only).
- Telling them apart: by `Content-Type` only. go2rtc ignores every part that is not `video/mp2t` after the first reply.
- Session matching: the reply to a request carries the request's `seq` in its JSON and `params.session_id` (a
  **string**, e.g. `"7"`); later media parts carry `X-Session-Id` with that number. With one request per connection
  (the recommended design) everything on the connection belongs to that session.
- Part sizes: not stated in the sources. Media parts hold whole 188-byte TS packets in pytapo's handling, but pytapo
  still re-aligns on the 0x47 sync byte and buffers partial packets across parts; **Recommendation:** do the same.
- Keep-alives: none in either direction for live view. Liveness is "a part arrived recently" (section 8).

## 6. The live-view request and its reply

Request JSON (go2rtc's exact text; pytapo's is the same object with keys in another order and a random `seq`):

    {"params":{"preview":{"audio":["default"],"channels":[0],"resolutions":["HD"]},"method":"get"},"seq":1,"type":"request"}

- `channels`: list of channel numbers, `[0]` by default (go2rtc `channel` query option).
- `resolutions`: `["HD"]` (main stream) or `["VGA"]` (sub stream; go2rtc `subtype=1`).
- `audio`: `["default"]`; go2rtc's comment lists `default`, `disable`, `enable` as the values.
- Optional keys pytapo can add inside `preview`: `streams` (list), `deviceId` (hub child), `ignore_limit` (unknown
  semantics; presumably bypasses the concurrent-viewer limit). Not needed.
- `seq`: go2rtc sends `1`; pytapo replaces it with a random number in 1000…32767 to keep its dispatch table free of
  clashes with camera-initiated sequence numbers. Either works.
- Compact JSON (no spaces) in both sources.

Reply (from pytapo's tests; one `application/json` part):

    {"type":"response","seq":1,"params":{"error_code":0,"session_id":"7"}}

- Non-zero `error_code` means refused. Codes pytapo treats as "busy": `-52405` TOO_MANY_REQUEST, `-52407`
  TOO_MANY_CLIENT, `-52417` VOD_SESSION_OCCUPIED, `-52435` VOD_SESSION_FULL. Others in its table: `-52411`
  TALK_IS_USED, `-52419` TOO_MANY_HTTPS_CLIENT, `-52402` VOD_INVALID_REQUEST, `-3` DIGEST_AUTHORIZE_FAIL.
- Media parts follow immediately (`video/mp2t`, `X-Session-Id` = the session id).
- End notification (seen for recordings, possibly for live): `{"type":"notification","params":{"event_type":"stream_status","status":"finished"}}`
  with no session id; treat it as the end of the stream.
- Stopping: there is no stop request in either source. Close the TCP connection.
- Talkback [go2rtc, optional]: a second request `{"params":{"talk":{"mode":"aec"},"method":"get"},"seq":3,"type":"request"}`
  (on the same connection if no preview runs, else a second connection), then parts `Content-Type: audio/mp2t`,
  `X-If-Encrypt: 0`, `X-Session-Id: <talk session>`, carrying MPEG-TS with one G.711 A-law stream (type 0x90).

## 7. MPEG-TS content

- Stream types (both sources): `0x1B` H.264, `0x24` H.265/HEVC, `0x90` G.711 A-law (TP-Link private), `0x91`
  G.711 μ-law (TP-Link private). Standard MPEG-TS assigns 0x91 nothing ffmpeg maps, so ffmpeg probes the payload and
  guesses MP3 [tapo-onvif]. Audio PES payloads are raw G.711 bytes (one byte per sample).
- Audio rate: 8 kHz mono by default [pytapo falls back to 8000; it asks the 443 API for `sampling_rate` in kHz when
  it can]. go2rtc notes that **some newer firmware sends 0x91 μ-law at 16 kHz** and transcodes it. Not known for the
  C675D. **Recommendation:** measure: payload bytes per second of PTS (90 kHz clock) gives the sample rate (8000 or
  16000).
- Timestamps: PES PTS on the 90 kHz clock; go2rtc uses them unchanged (scaled to the codec's clock). tapo-onvif runs
  ffmpeg with `+genpts`, implying missing or unreliable timestamps at times; nothing more specific is recorded.
- PIDs: no source records the PID numbers; parse PAT → PMT and take elementary streams in PMT order.
- C675D, `HD` [tapo-onvif]: **two HEVC video streams** in one TS — the first video stream (ffmpeg `0:v:0`) is the
  **wide** lens, the second (`0:v:1`) the **tele** lens — plus one μ-law audio stream (0x91). Resolutions are not
  recorded; tapo-onvif's 1280x720 snapshot scaling and its comment that downscaling to 1080p was tried suggest the
  sources are larger than 1080p.
- C675D, `VGA` [live, relayed]: one 1280x720 **H.264** stream of the **tele** lens only, whatever `channels` says.
- Single-lens Tapo models: one video stream (H.264 or HEVC by model), A-law or μ-law audio.

## 8. Session lifetime, standby, reconnecting

- A battery C675D goes to standby about **every 10 minutes** while streaming [tapo-onvif commit f681dca]. On the
  wire the camera simply **stops sending parts**; neither tapo-onvif nor pytapo records a TCP close or an error JSON
  for this case. pytapo declares the stream over after **10 s without a part** (`no_data_timeout`).
- Reconnecting right away works: tapo-onvif opens a new Streamd session (a new TCP connection, a new Digest
  handshake, a new preview request) and the outage per cycle is **about 3–5 s**, most of it its ffmpeg restart.
  Budget: at most 5 reconnects within 600 s, then give up and let the supervisor restart everything.
- Deep sleep / off network: TCP to the camera may connect and then stay silent for minutes (tapo-onvif saw an
  established, silent connection on port 443 for ~9 min, camera not pingable). tapo-onvif bounds its handshake at
  30 s.
- Grace periods tapo-onvif tuned on the real camera: 60 s from start to first published frame, 30 s of no output
  counts as stalled.
- One session per connection is all either source uses; pytapo opens a new connection for each media session.

## 9. Device information

- **Nothing on port 8800 identifies the device**: no model, MAC, serial, firmware or lens count in the challenge,
  the 200 headers or the preview reply as the sources describe them.
- The camera's control API (HTTPS 443, KLAP / SPAKE2+ login with the cloud account) has `getBasicInfo`
  (`device_info.basic_info`: alias, model, firmware, MAC, …); tapo-onvif calls it at start (alias only), so the C675D
  does expose 443 when awake, contrary to "only 8800 open". Its login protocol is outside this spec (the existing
  `docs/clean-room/Tapo.md` covers the plug variant; the camera variant differs).
- **Recommendation:** without 443: take the MAC from the host's ARP table after connecting (Homeswift's `ARPTable`),
  use it as the Device Id, and let the user pick the model (C675D: two lenses). Lens count can also be inferred from
  the number of video streams in an `HD` session.

## 10. Snapshots

- tapo-onvif: a continuous ffmpeg per lens decodes its own RTSP republication at 1 fps (`-skip_frame nokey`,
  `-vf fps=1,scale=1280:720`, `-q:v 4`, `-update 1 -atomic_writing 1`) and serves the latest JPEG. It needs the live
  stream running all the time.
- pytapo has a direct snapshot: a Streamd **download** session (`?…type=sdvod` query for hub children; plain
  `/stream` otherwise) with request
  `{"type":"request","seq":1,"params":{"download":{"client_id":<user id>,"channels":[0],"media_type":3,"start_time":"<unix seconds>","player_id":"<uuid>"},"method":"get"}}`;
  the camera answers one `image/jpeg` part (640x360 on a C510W, ~0.2 s), then `stream_status` `finished`.
  `media_type` 2 with a recording's start time gives that recording's thumbnail. `client_id` comes from the 443 API
  (`getUserID`). Untested on battery models; it needs the camera awake.
- **Recommendation:** decode one keyframe from a live session when one is running (or from the start of a session
  opened for motion), keep it as the snapshot, and **never open a session just for a snapshot**: HomeKit asks for
  snapshots every few seconds while the Home app is open. Return the cached image (or a placeholder) otherwise.

## 11. ffmpeg recipes (data)

Input side as tapo-onvif runs it, the decrypted TS piped on stdin:

    -loglevel warning -fflags +genpts+nobuffer -probesize 5M -analyzeduration 5M -f mpegts -i pipe:0

- HD wide lens: `-map 0:v:0`; HD tele lens: `-map 0:v:1`; one ffmpeg can emit both (two outputs, each with its own
  `-map`). Encoding there: `-c:v h264_videotoolbox -b:v 3M -maxrate 4M -bufsize 6M -profile:v main -pix_fmt yuv420p
  -g 30` (HEVC → H.264; HomeKit takes H.264 only, so transcoding is required in HD). pytapo's own defaults are
  `-probesize 32 -analyzeduration 0` with `-c:v copy`, too small for the two-stream HD TS.
- VGA: one H.264 stream, `-map 0:v:0`; `-c:v copy` is possible if the profile/level suits HomeKit, otherwise
  transcode.
- Audio as shipped by tapo-onvif: **none from the camera**. It adds silent AAC: second input
  `-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000`, `-map 1:a:0 -c:a aac -b:a 64k -ar 48000 -ac 2`.
- Forcing μ-law: tapo-onvif tried an input codec override (`-c:a:0 pcm_mulaw` on the TS input); **ffmpeg crashed at
  start and the camera's session stayed stuck for minutes**. pytapo's side channel (demux audio itself, write raw
  bytes to a second ffmpeg input `-f mulaw -ar 8000 -i /dev/fd/N`, with `-map 0:v:0 -map 1:a:0`) works in principle
  but pytapo keeps only the first PES per part, so almost no audio arrived.
  **Recommendation:** demux the TS in Swift (PAT/PMT/PES are simple), forward the TS to ffmpeg for video, and write
  every 0x91 PES payload, in order, to a second input `-f mulaw -ar 8000 -ac 1 -i <pipe>` (16000 if measured,
  section 7), mapped as the audio stream. Alternatively rewrite the PMT's 0x91 entry to drop the audio from the TS.
  The relayed claim that a pcm_mulaw override works on the live camera is not backed by any written source.

## 12. Battery and motion

### 12.1 What tapo-onvif does

It streams **continuously, 24/7**, HD, both lenses, reconnecting after every standby (every ~10 min), plus four
always-running snapshot decoders. It has **no motion detection** and no event source of any kind. Battery cost is
not measured anywhere; it relies on the solar panel.

### 12.2 Does a Streamd connection wake the camera; what it costs

- No source measures battery cost per connection or says how long the camera stays awake after a session.
- Observed: while streaming, the camera drops into standby every ~10 min and an immediate reconnect succeeds within
  seconds, so port 8800 is reachable at least shortly after standby starts. When the camera is in deep sleep, TCP may
  connect and stay silent, or the camera may not answer ping at all (section 8). Whether an incoming TCP SYN on Wi-Fi
  wakes it (Wi-Fi keep-alive wake) is unknown.
- pytapo exposes battery settings over 443 only: `getBatteryStatus`, `getBatteryPowerSave`/`setBatteryPowerSave`,
  `getBatteryOperatingMode`/`setBatteryOperatingMode` (+ `operating_mode_param`), `getPowerMode`, charging mode, and
  `getWakeUpConfig`/`setWakeUpConfig` with `wake_up_type` `doorbell` or `detection`.

### 12.3 Ways to learn about motion without holding a session

| Way | In the sources? | Works on battery / needs camera awake |
|---|---|---|
| Something the camera pushes on the LAN (ONVIF events, UDP/multicast broadcast, HTTP callback) | **None.** No source describes any. Battery Tapo models have no ONVIF; nothing listens or announces besides 8800 (and 443 when awake). | — |
| A Streamd request that subscribes to events or returns detection state | **None.** The only Streamd methods seen are `preview`, `talk`, `download` and playback (recordings). | — |
| 443 control API, polled: `searchDetectionList` (playback, start/end time, channel 0 → detection list on SD card), `getLastAlarmInfo` (`msg_alarm` / `chn1_msg_alarm_info`, the alarm settings, not a last-event time), `getMotionDetection` (settings) | pytapo | Polling; needs the camera awake, so it drains the battery and cannot catch an event while asleep. Needs the KLAP/SPAKE2+ login. |
| TP-Link cloud push (what the Tapo app receives) | **Not in any source.** pytapo only reads/writes the camera's notification switches (`msg_push` / `chn1_msg_push_info`: `notification_enabled`, `rich_notification_enabled`). tapo-onvif mentions the cloud host `eu-wap.tplinkcloud.com` (passthrough) and a WebRTC endpoint `/v1/sfu/request` that battery cams do not use (`errorCode 2001`), nothing about push. | This is how the Tapo app learns of motion from a sleeping battery camera (the camera wakes on PIR and notifies the cloud), but the registration, endpoints and auth are undocumented here. |

**Plain statement: no local motion source exists in any of the sources.** The only route that does not keep the
camera awake is the TP-Link cloud's push notifications, and nothing read describes them.

**Recommendation:** connect to 8800 only while HomeKit has an active stream (or a recording request), close on stop,
never pre-buffer, never connect for snapshots (section 10), and reconnect after standby only while a viewer remains.
For motion, investigate separately (a different clean-room spec): the Tapo app's cloud login and its FCM push
registration (Homeswift already has `FCMReceiver`); until then expose no motion sensor rather than a polled one.

## 13. Test vectors (computed by me; inputs invented)

Cloud password `ExamplePassw0rd!` (16 ASCII bytes).

- `P_MD5    = FD344607B3AAFF7BB5FE20B9B04149FD`
- `P_SHA256 = D23E8AD06AA8C81F7A6FC25A66922E4CFE2D3BDF6AC227C166F1EEC354E41767`

### 13.1 Digest

Challenge:
`WWW-Authenticate: Digest realm="streamd-example",nonce="6f1c2a9e3b7d4c58",qop="auth",opaque="64943214",algorithm="MD5",encrypt_type="3"`
with `cnonce = 0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978`, `nc = 00000001`, user `admin`.

- `HA2 = a09936ba0b87edc637304f0563093321` (MD5 of `POST:/stream`)
- SHA-256 password: `HA1 = cf1a6400ce4072dd0495d42b7cf47a19`, `response = 28d0f773c39507f9a39a85b35a787131`
- MD5 password (fallback): `HA1 = 8798d26dc3fe46151cab08a7e99595cf`, `response = e2d6cb92cbd626e614ee6abb47edd69e`

Expected header (pytapo layout, SHA-256):

    Authorization: Digest username="admin",realm="streamd-example",uri="/stream",algorithm=MD5,nonce="6f1c2a9e3b7d4c58",nc=00000001,cnonce="0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978",qop=auth,response="28d0f773c39507f9a39a85b35a787131",opaque="64943214"

### 13.2 Key and IV

`Key-Exchange: username="admin" nonce="9a4cf1e07b2d4e8f8c1b3a5d6e7f9012"`

| Hash | key | iv |
|---|---|---|
| SHA-256 | `cb561b8390a544fe465ab7f1cd96f345` | `87e9a7a3ab9e1e20c4284584bb837aba` |
| MD5 | `1e915847bc98909257f226225706d105` | `87e9a7a3ab9e1e20c4284584bb837aba` |
| `username="none"` | `f1809011b25f53fe6d0a4be7261a111d` | `b810f22e6696c0303595c0f6ee1c2c10` |

### 13.3 Encrypted parts (AES-128-CBC, PKCS#7, IV reset per part)

Plaintext (120 bytes): the preview request of section 6 exactly as written there. Ciphertext (128 bytes):

- SHA-256 key:
  `503a7c0a4ad9b8e9866a1ee497099e4ea19b050dad2507dc7b9001be9a3fcaa63161b79ab580571fc6d474f158e9284010312aaec772e6d7422850871e0d58c508ff03e768b9b92281f1012f7cb02f6c2f67e83a4ab8ab2885288b3e0cebbce6d57ff860ff0bf225ee482a89941f9b1cd3043fa77439487f0d21bfccbb9c850d`
- MD5 key:
  `24e4dfab6b8c1e513080f873730fb4626e43470da789e93d162842f443bcdda0c34ae5b3a06b8a0af698c24ef5a7bdbbad08be4834ae7205825b6b23ca81a23bf90a3ee6ee593bec3184566d584673eae797c77fcd05f09630e249b107c9a71773a0dcea5492dd6aab9e3814320fbd46c8c4aabe4e069858203ec39a63f18f28`

Reply part, SHA-256 key, plaintext `{"type":"response","seq":1,"params":{"error_code":0,"session_id":"7"}}` (70 bytes) →
80 bytes:
`3f7fe8b54ca9c8d4fc5ac24e74a37500f8dd8ae81188e8bde8f829be6fe899d281db2da727fe8d8e2e198cf0215ab5f13e1965742fa7cfe8b3621a4fbe119660d1b3b9e3adc93ff3e87123ebf7044d0a`

Media part, SHA-256 key, plaintext one TS null packet (188 bytes: `47 1F FF 10` then 184 × `FF`) → 192 bytes (the last
16 are a full padding block):
`ffdc4eefa544ecdfbd272cf5066bea5716a99d2ce8a5d39db520a6c77bf9ed2f680e9c77664d7eb3f1ea17726e1a5dad8bb837ae8de28a982a2e852e463e1f214d0c9a51eba833a0236857f1b1c4d0f541db88c60072c86a98fdf8972ebdcd8cb3ad505a2ca2c7b641d8485ec81d9a62752c1ece9fbe963914df43d94d782edb6a5dcec75040286a95bad0e943c8c0f57a7847d41c9b291eb27128258742b4d1e326292e7511438899b5c4e3a5e670ec2b5481ea4b93e39a21c8aff1d62bdfbb`

Decrypting the reply and the media part each with a fresh IV must give the plaintexts back; decrypting the media
part with the IV left at the end of the previous part must not (a test for the per-part reset).

## 14. Gaps / uncertainties

1. **No local motion source** exists in any source (section 12.3); cloud push is undocumented here.
2. Battery cost per connection, and how long the camera stays awake after a session, are unknown. Whether a TCP
   connect to 8800 wakes a sleeping camera is unknown.
3. How standby looks on the wire (silence vs. TCP close vs. a `stream_status` notification) is not recorded; handle
   all three.
4. Exact `WWW-Authenticate` / `Key-Exchange` text from a C675D is not captured anywhere; the examples are
   reconstructions from what the parsers read. Whether `encrypt_type` also appears in `Key-Exchange` is unknown.
5. μ-law sample rate on the C675D (8 vs 16 kHz) and PID numbers are unknown; the working way to feed its audio to
   ffmpeg is unproven (section 11).
6. C675D HD resolutions and frame rates are not recorded; the VGA behaviour comes only from the relayed live test.
7. Whether failed Digest attempts on 8800 count towards the camera's login lockout is unknown.
8. Concurrent viewers: the busy codes exist, but the limit for a C675D (and whether the Tapo app watching blocks the
   bridge) is unknown.
9. Device information needs the 443 API, which contradicts "only 8800 open"; to be checked on the camera.

## 15. Recommendations (summary)

- One TCP connection per live session, one preview request, close to stop; HD for HomeKit (transcode HEVC → H.264
  per lens), VGA only as a low-cost tele-lens option.
- Authenticate with SHA-256 when `encrypt_type="3"`, retry once with MD5 on a new connection, then stop with a
  credential error.
- Parse multipart by delimiter + `Content-Length`; decrypt each part with a fresh IV; validate PKCS#7; re-align TS on
  0x47.
- Treat 10 s without parts as end of stream; reconnect at once while a viewer is active (≤ 5 per 10 min, then back off),
  never otherwise.
- Snapshots from a cached keyframe; never wake the camera for one.
- Never log the cloud password, either hash, the Digest response, the Key-Exchange nonce, the key or the IV.
