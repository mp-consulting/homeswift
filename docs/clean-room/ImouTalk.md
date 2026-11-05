# IMOU / Dahua: two-way talk on the LAN (clean room)

## 0. Provenance

Written by the spec writer as a supplement to `Imou.md` (whose addendum §3 found no talk in the IMOU sources). It
contains **no source code**. URLs, query parameters, header names and values, MIME types and SDP attributes are quoted
exactly because they are the interface. **Recommendation** marks the spec writer's choices. Test vectors (section 9)
were computed by the spec writer with Python's `hashlib`.

| Id | Source | What was taken | Version | Licence |
|---|---|---|---|---|
| H | Dahua, "DAHUA HTTP API FOR IPC & SD", Version 1.40 (PDF, public copy at `data.nag.wiki/Dahua/IP_camera/`) | §4.5 audio encode caps and config, §11 Audio: MIME types, `postAudio`, `getAudio`, `httptype` | V1.40 (release table up to 2013) | Dahua's published document; facts only |
| H2 | Same document, V1.67 revision table (public listing) | that `getCollect` for the `audioIn`/`audioOut` modules exists since V1.43 (2014) | V1.67 | facts only |
| S | Scrypted, `plugins/amcrest/src/main.ts` and `amcrest-api.ts` (github.com/koush/scrypted) | Amcrest/Dahua intercom: `postAudio` with `Content-Length: 9999999`, 1024-byte writes, A-law for Dahua doorbells, AAC (ADTS) otherwise; speaker probe `devAudioOutput.cgi?action=getCollect` → `result=1`; ONVIF backchannel needing `proto=Onvif` | `main`, read 2026-11-05 | Apache-2.0 (Koushik Dutta) |
| G | go2rtc (github.com/AlexxIT/go2rtc), `pkg/rtsp/client.go`, `consumer.go`, `pkg/pcm/handlers.go`, `internal/rtsp/README.md`, `README.md` | The ONVIF RTSP backchannel client: `Require` header, SDP `sendonly` track, interleaved TCP, packet size 1024 and zero timestamps for G.711, Dahua quirks (one backchannel at a time, `unicast=true&proto=Onvif`), Dahua codecs accepted | commit `990f4de3cc21d1cca917d02d0bc40f2fabe75a49` (2026-11-05) | MIT, `Copyright (c) 2022 Alexey Khit` |
| P | IMOU Open Platform docs (as `Imou.md` addendum [P]) | no talk method in the cloud API | read 2026-11-05 | facts only |
| — | `ReturnAudio.md` | PCM from HomeKit, the G.711 and AAC encoders | this repository | the project's own |

Home Assistant's Dahua integrations were searched for talk; none sends audio (they read events and snapshots), so
nothing was taken from them. THIRD-PARTY-NOTICES: nothing is ported; if reference sources are listed, list go2rtc (MIT)
and Scrypted (Apache-2.0).

## 1. Scope and choice of method

Two-way talk from HomeKit to an IMOU camera reached on the LAN (the plugin's `DahuaLocal`: Dahua CGI on `httpPort` with
Digest, user `admin` or the configured one, password the safety code; `Imou.md` §5.3).

| | Method | Why |
|---|---|---|
| **Primary** | HTTP `POST /cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1`, G.711 A-law 8 kHz, a raw TCP stream (section 3) | Dahua's documented interface [H]; one request, no RTSP client to write; Digest is already done by `DahuaLocal` |
| **Fallback** | RTSP ONVIF backchannel on the local stream (section 4) | Cameras whose firmware lacks `postAudio` (404/501/`Error`) but expose a `sendonly` audio track (ONVIF Profile T, most Dahua-based cameras [G]); needs a small RTSP client |
| Not available | the IMOU cloud | [P] has no talk method; abilities `TSV1`/`TSV2` name IMOU's private intercom protocol, which is not documented anywhere read |

A camera with neither (CGI disabled and no backchannel track) has no two-way audio: the plugin does not set
`twoWayAudio` and HomeKit shows no talk button.

## 2. Capability detection

Run once per device at start-up (and again after the device's settings change), only when the local path works
(`DahuaLocal.serialNumber()` succeeded); cache the result in memory.

1. **Speaker present**: `GET /cgi-bin/devAudioOutput.cgi?action=getCollect` (Digest). A body containing `result=` with
   an integer ≥ 1 (e.g. `result=1`) → the camera has an audio output. `result=0` → no speaker: no two-way audio.
   404, 501, or a body `Error` → unknown (old firmware): go to step 3. [S] treats only the substring `result=1` as
   supported; **Recommendation:** parse the integer.
2. **Method**: with a speaker, try the primary method on the first Talk (3). If its request answers 404, 501 or 400
   before any audio is sent, or the connection is refused, mark the method unavailable and use the fallback from then on.
3. **Backchannel present**: `DESCRIBE` of the main stream with the backchannel `Require` (4.2). An SDP with an
   `m=audio` section marked `a=sendonly` → fallback available. No such track, or `551 Option not supported` → none.
4. Cloud abilities are hints only: `AudioTalk`, `AudioTalkV1`, `TalkV2` in the device's ability string (`Imou.md` §1.2)
   say the product has an intercom; their absence does not rule out a speaker, and their presence does not mean the
   local CGI is enabled. **Recommendation:** offer `twoWayAudio` when step 1 says ≥ 1 or step 3 finds a track, or when
   the user forces it in the device's Accessory Settings (a `twoWayAudio` boolean, default "auto").

The Speaker service exists only when the camera is published with `twoWayAudio: true`, so detection must finish before
the camera accessory is published; when it is still unknown at publication (device unreachable), publish without it and
add it after the next restart (adding a service later changes the accessory's database, which HomeKit accepts, but keep
iids stable: the Speaker's keys are `aid/serviceUUID/subtype[/charUUID]` as for any service).

## 3. Primary: HTTP `postAudio`

### 3.1 Request

One request per Talk, on its own TCP connection to `host:httpPort` (HTTPS is not used for audio; the CGI's other calls
may still use HTTPS when configured). Request line and headers, CRLF, exactly:

```
POST /cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1 HTTP/1.1
Host: ‹host›[:‹port›]
Authorization: Digest ‹…›
Content-Type: Audio/G.711A
Content-Length: 9999999
Connection: close
```

then a blank line, then the audio bytes, written as they are produced, with no further framing.

- `channel` is the **audio** channel, 1-based: `1` for a single camera (the cloud's `channelId` + 1 for a multi-channel
  device).
- `Content-Length: 9999999` is the value of Dahua's own example [H] and of [S]; the camera plays bytes as they come and
  does not wait for the length. Do **not** send `Transfer-Encoding: chunked` (not in [H]; cameras are reported to answer
  400 to bodies whose length disagrees with what they expect).
- MIME types the API defines [H §11.1]: `Audio/PCM`, `Audio/ADPCM`, `Audio/G.711A`, `Audio/G.711Mu`, `Audio/G.726`,
  `Audio/G.729`, `Audio/MPEG2`, `Audio/AMR`, `Audio/AAC`. Which the speaker accepts is not exposed (the encode caps of
  §4.5 describe the microphone's encoder). **Recommendation:** `Audio/G.711A` at 8000 Hz mono (the documented example,
  and what [S] uses for Dahua doorbells); a per-device setting `talkCodec` with `G.711A` (default), `G.711Mu` and `AAC`
  (ADTS frames, 16 kHz, `ReturnAudio.md` §5.4; [S] uses it for Amcrest devices).
- `httptype=multipart` (each packet in a part with its own `Content-Type` and `Content-Length`, e.g. 800 bytes, boundary
  from the request's `Content-Type: multipart/x-mixed-replace; boundary=…`) is the documented alternative; not used.

### 3.2 Digest

The body cannot be resent, so the request must carry a valid `Authorization` the first time:

1. `DahuaLocal` keeps the last `WWW-Authenticate` challenge (realm `Login to <serial>`, `qop="auth"`, nonce, opaque). If
   none is held, or it is older than 5 minutes, send any cheap authenticated GET first
   (`devAudioOutput.cgi?action=getCollect`) to obtain a fresh one.
2. Compute RFC 2617 Digest with `qop=auth` for **method `POST`** and `uri` = the exact request target
   (`/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1`), the next nonce count for that nonce and a new
   client nonce (`DigestAuthentication.authorization(method:uri:)`).
3. If the camera answers `401` before the body has started (read the socket concurrently, 4.4), take its new challenge,
   close, and retry **once** on a new connection; a second `401` means a wrong safety code (report as `DahuaLocal` does).

### 3.3 Sending

- PCM from `ReturnAudio.md` at 8000 Hz, 20 ms frames (160 samples) → A-law (or µ-law), 160 bytes per frame.
- Write in **1024-byte** pieces (128 ms of G.711): [S] reports Dahua doorbells play smoothly with that size. Gather
  frames until 1024 bytes are ready, then write; at the end of the Talk write the remainder.
- Pacing is the HomeKit stream's own (frames arrive in real time). Never write faster than real time: if more than
  3 pieces (384 ms) are waiting (the camera reading slower than real time), drop the oldest.
- The first bytes may be written as soon as the headers are sent; there is no "ready" response.

### 3.4 Response, end and errors

- The camera normally answers nothing until the connection ends, or a `200 OK` with body `OK` at some point; ignore a
  200's timing. Any other status read from the socket (400 Bad Request, 401, 403, 404, 501, 503) ends the Talk with that
  error. Read and discard everything else.
- End of Talk (`frames` finishes): write the remainder, wait the duration of the audio still buffered on the camera
  (the bytes written in the last 300 ms, at 8000 bytes/s) plus 200 ms, then close the socket. Closing is the only way to
  end a singlepart post.
- Timeouts: TCP connect 5 s; a write that blocks more than 2 s (camera not reading) ends the Talk; no overall timeout
  (a Talk lasts as long as HomeKit sends audio, capped by `maximumTalk`).
- One Talk at a time per camera: a new Talk while the previous connection is still closing waits for it (at most 1 s),
  then opens its own. Some doorbells allow only one audio client: a 503 or an immediate close is reported once as
  "the camera's speaker is busy (another app is talking?)".
- A camera that is talking through another client (the IMOU app) may refuse; no retry within the Talk.
- Transport: a raw `TCPStream` (HomeswiftNetwork), because `HTTPClient` sends bodies whole. The request head is built by
  hand; the `Host` header follows `hostHeader(host:port:defaultPort:)`.

## 4. Fallback: RTSP ONVIF backchannel

### 4.1 URL

`rtsp://‹host›:‹rtspPort›/cam/realmonitor?channel=‹n›&subtype=0&unicast=true&proto=Onvif` (`n` = cloud channel + 1).
The two extra parameters make Dahua firmware use its ONVIF session handling, which activates the backchannel and
accepts several codecs for it [G, S]. Credentials go in Digest headers, not in the URL.

### 4.2 Session

A dedicated RTSP session per Talk, over TCP, separate from FFmpeg's video session. RTSP/1.0, CRLF, `CSeq` from 1.

1. `DESCRIBE ‹url› RTSP/1.0` with `Accept: application/sdp` and `Require: www.onvif.org/ver20/backchannel`. Expect
   `401` with `WWW-Authenticate: Digest realm="…", nonce="…"` (Dahua RTSP uses Digest without `qop`, or Basic on old
   firmware); repeat with `Authorization: Digest username="…", realm="…", nonce="…", uri="‹url›", response="…"` where
   response = MD5(HA1 ":" nonce ":" HA2), HA2 = MD5("DESCRIBE:" url). Each later request carries a fresh
   `Authorization` for its own method and URI. A `Content-Base` header replaces the base URL.
2. In the SDP, the backchannel is the `m=audio` section with `a=sendonly`. Its codec from `a=rtpmap`: payload type 8
   `PCMA/8000`, 0 `PCMU/8000`, or a dynamic one with `MPEG4-GENERIC/…` (AAC) or `L16/…`. Prefer PCMA, then PCMU, then
   AAC; skip others. Its `a=control` value (absolute, or relative to the base URL with a `/` between them) is the track
   URL.
3. `SETUP ‹trackURL›` with `Transport: RTP/AVP/TCP;unicast;interleaved=0-1` and the same `Require` header. Read the
   answer's `Session:` (the id before `;`, and `timeout=` seconds, default 60) and its `Transport` (the camera may pick
   another `interleaved=` channel: use the first number it gives). A failure here on Dahua usually means another
   backchannel is open [G]: report "speaker busy" and end the Talk.
4. `PLAY ‹url›` with `Session: ‹id›`. Send audio only after its `200 OK`.
5. Audio: interleaved frames `$`, channel byte, 2-byte big-endian length, then an RTP packet (version 2, marker 1,
   payload type from the SDP, a random SSRC, sequence from 0). G.711: 1024 payload bytes per packet (128 ms) [G]. go2rtc
   sends every G.711 backchannel packet with **timestamp 0** (a fix for a Reolink doorbell that it applies to all
   cameras); **Recommendation:** timestamps advancing by the samples sent (RFC 3550), with a per-device `zeroTimestamps`
   switch if a camera plays nothing.
6. Keep-alive: `GET_PARAMETER ‹url›` with the session every `timeout / 2` seconds while the Talk lasts.
7. End: `TEARDOWN ‹url›` with the session, then close. Wait for the buffered audio as in 3.4 first.
8. Ignore interleaved data arriving from the camera (RTCP) and any responses but those awaited.

### 4.3 Doorbells

On some Dahua/Amcrest doorbells an open backchannel disables the call button while it lasts [G]: the per-Talk session of
4.2 limits that to the Talk itself. Never request the backchannel on FFmpeg's video URL.

### 4.4 Errors and timeouts

TCP connect 5 s; each RTSP response 5 s; a status other than 200 ends the Talk (`401` twice → wrong safety code,
`454 Session Not Found` → end, `551 Option not supported` on `DESCRIBE` → no backchannel, record it). Writes as 3.4.

## 5. Audio formats summary

| Method | Codec | Rate | Bytes per write/packet | Pacing |
|---|---|---|---|---|
| `postAudio` (default) | G.711 A-law, `Audio/G.711A` | 8000 Hz mono | 1024 (128 ms) | real time, ≤ 3 queued |
| `postAudio` (`talkCodec`) | G.711 µ-law, `Audio/G.711Mu` | 8000 Hz | 1024 | same |
| `postAudio` (`talkCodec`) | AAC-LC ADTS, `Audio/AAC` | 16000 Hz | whole ADTS frames | same |
| backchannel | as the SDP's `sendonly` track (PCMA/PCMU/AAC) | its clock | 1024 for G.711; one AU per packet for AAC (RFC 3640 `AAC-hbr`) | same |

The `ReturnAudioFormat` asked from the streamer is 8000 Hz/20 ms for G.711, 16000 Hz/20 ms for AAC.

## 6. Plugin integration (Recommendation)

- `ImouCamera` builds its `RTSPCameraStreamer` with `ReturnAudioOptions(format:…, handler:)` when the device has a
  speaker (section 2), and publishes `AudioStreamingOptions(codecs: [AAC-ELD 16 kHz], twoWayAudio: true)`.
- The handler: on a Talk, pick the method (cached), open it, encode and send each frame, close at the end; on the
  method's "not available" errors, switch to the fallback for the next Talk.
- Only for devices reached locally (`Imou.md` §5.4, §7.5). A device on the cloud stream only gets no Speaker.
- Accessory Settings (Core, by Device Id): `twoWayAudio` (`auto`/`on`/`off`), `talkCodec` (`G.711A`/`G.711Mu`/`AAC`),
  `talkMethod` (`auto`/`http`/`rtsp`). Shown on the plugin page; changing them restarts the camera's streamer.

## 7. Logging and secrets

Never log the safety code, the `Authorization` header, or URLs with credentials. Info: "Talk started (HTTP, G.711A)",
"Talk ended (12.3 s)", "camera has no speaker". Warning once: method unavailable, speaker busy.

## 8. Tests (Recommendation)

A fake camera on a local TCP port: answers `GET devAudioOutput.cgi` with a Digest challenge then `result=1`; on the
`POST`, checks the request line, `Content-Type`, `Content-Length: 9999999` and the Digest response for `POST`, records the
bytes and their arrival times; variants answering `401` before the body, `404`, or reading slowly. A fake RTSP server for
4.2 that returns the SDP of 9.4 and records the interleaved packets.

## 9. Test vectors (computed by the spec writer)

### 9.1 Digest for `postAudio` (RFC 2617, qop=auth)

user `admin`, password `ABCD1234`, realm `Login to 2J0123456789ABC`, nonce
`000562fdY631973ef04f77a3ede7c1832ff48720ef95ad`, method `POST`,
uri `/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1`, nc `00000001`, cnonce `0a4f113b`:

| Value | Result |
|---|---|
| HA1 = MD5(user:realm:password) | `64f87461d7125741fd981b13c2f13647` |
| HA2 = MD5(POST:uri) | `6cacaf3d118f5b434d970b0053a177ca` |
| response | `d78deb64da2e419ab09192d3851f578a` |

Header: `Authorization: Digest username="admin", realm="Login to 2J0123456789ABC", nonce="000562fdY631973ef04f77a3ede7c1832ff48720ef95ad", uri="/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1", qop=auth, nc=00000001, cnonce="0a4f113b", response="d78deb64da2e419ab09192d3851f578a", opaque="…"`
(`opaque` echoed when the challenge had one).

### 9.2 RTSP Digest (no qop)

Same user and password, realm `Login to 2J0123456789ABC`, nonce `9c8bbb2a1bd1d3b4b8a3f1b4ad2e2d01`, method `DESCRIBE`,
uri `rtsp://192.168.1.40:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif` → response
`079b350a8538b869e1d1d5bbb22924ed`.

### 9.3 Speaker probe answers

`result=1\r\n` → speaker; `result=0\r\n` → none; `Error\r\nBad Request!\r\n` (status 400) → unknown.

### 9.4 Backchannel SDP (invented, in the shape of the cameras' answers)

```
v=0
o=- 2251938198 2251938198 IN IP4 0.0.0.0
s=Media Server
c=IN IP4 0.0.0.0
t=0 0
a=control:*
m=video 0 RTP/AVP 96
a=control:trackID=0
a=rtpmap:96 H264/90000
a=recvonly
m=audio 0 RTP/AVP 8
a=control:trackID=1
a=rtpmap:8 PCMA/8000
a=recvonly
m=audio 0 RTP/AVP 8
a=control:trackID=5
a=rtpmap:8 PCMA/8000
a=sendonly
```

Expected: backchannel = the third section, PCMA, track URL `‹base›/trackID=5`.

### 9.5 Interleaved RTP

First G.711 packet, channel 2 (as the camera's `Transport` answered `interleaved=2-3`), SSRC `0x12345678`, sequence 0,
timestamp 0, 1024 payload bytes: `24 02 04 0c` then `80 88 00 00 00 00 00 00 12 34 56 78` then the payload. The second
packet with advancing timestamps: `80 88 00 01 00 00 04 00 12 34 56 78` (timestamp 1024).

### 9.6 Pacing

A 2-second Talk at 8 kHz A-law is 16000 bytes: 15 writes of 1024 bytes and one of 640, the first written ≈ 128 ms after
the Talk begins, the socket closed ≈ 2.5 s after it begins (3.4).

## 10. Open questions / unknowns

- **Which IMOU models answer `postAudio`.** IMOU firmware is Dahua's, but IMOU consumer models are known to disable parts
  of the CGI; none of the sources tested an IMOU device. The fallback exists for that reason, and both may be absent.
- **The speaker's accepted codecs** are not reported by any documented call; A-law 8 kHz is a safe choice, not a
  verified one for every model. Whether `Audio/AAC` must be ADTS (as [S] sends) or raw is not documented.
- **`Content-Length: 9999999`**: whether a camera stops after 9 999 999 bytes (about 21 minutes of G.711) is unknown;
  `maximumTalk` (10 min) stays below it.
- **The response to `postAudio`**: when (or whether) the camera sends `200 OK` is not documented.
- **Backchannel timestamps**: go2rtc's zero timestamps vs. RFC 3550 timestamps — which Dahua firmware needs is not
  settled by the sources (go2rtc's comment says it does not know).
- **`devAudioOutput.cgi`** reply format is from [S]'s substring test and the API revision table, not from the API text
  itself (the V1.40 copy read predates it).
- **IMOU cloud intercom** (`TSV1`/`TSV2`, `CallByRtsp`) is undocumented; battery IMOU cameras (cloud only) therefore get
  no two-way audio.
