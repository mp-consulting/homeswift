# Ring live video over WebRTC: functional specification (clean room)

Companion to `docs/clean-room/Ring.md` (sections 6.2 to 6.5 describe the same call from the plugin's side and how it is
handed to HomeKit). This file is what Homeswift's own WebRTC receive stack (ICE agent with STUN, DTLS-SRTP, SRTP) has to
do to get a stream out of Ring: signalling, the offer, ICE, codecs, key frames and return audio.

## 0. Provenance

| | |
|---|---|
| Source | https://github.com/dgreif/ring, package `packages/ring-client-api` |
| Commit | `1c52affa18084e9edbf6ae6200b531ab0aa064f5` (shallow clone of the default branch, committed 2026-11-06) |
| Package version | `ring-client-api` 14.3.0 |
| License | MIT, "Copyright (c) 2022 Dusty Greif" (`LICENSE`) |
| Files read | `streaming/webrtc-connection.ts`, `streaming/streaming-messages.ts`, `streaming/peer-connection.ts`, `streaming/streaming-session.ts`, `streaming/simple-webrtc-session.ts`; `ring-camera.ts` (`createStreamingConnection`, `startLiveCall`, `isRingEdgeEnabled`, `createSimpleWebRtcSession`), `ring-types.ts` (`SocketTicketResponse`), `rest-client.ts` (base URLs, headers), `CHANGELOG.md` |
| WebRTC stack used by the original | `werift` 0.26.0 (`package.json`), MIT, "Copyright (c) 2020 shinyoshiaki". The original never writes SDP itself: the offer is whatever werift generates from the configuration in `peer-connection.ts`. To say what that offer contains, werift's tag `v0.26.0` (https://github.com/shinyoshiaki/werift-webrtc, commit `d67314bddfae08c3b980fd6a9b2977a306a6841c`) was read: `packages/webrtc/src/sdp.ts`, `sdpManager.ts`, `api/peerConfig.ts`, `const.ts`, `transport/dtls.ts`, `media/rtpReceiver.ts`. Facts marked **[werift]** come from there, not from Ring's client. |

Note: `Ring.md` was written from commit `2d1ebfd…` and names werift 0.25.1; the streaming files' behaviour described
there is unchanged at this commit.

Nothing in the repository contains a captured Ring answer SDP, captured ICE candidates or a captured message exchange.
Everything about what **Ring** sends is inferred from how the client parses it (types in `streaming-messages.ts`,
comments quoting real close reasons). Such facts are marked as inferred; unknowns are listed in section 8.

## 1. Who offers

The client is always the **offerer**; Ring answers (`webrtc-connection.ts` `initiateCall`: the offer travels inside
`live_view`; the answer comes back as `sdp` with `type: "answer"`). The same holds for the HTTP alternative
(`simple-webrtc-session.ts`: the client POSTs its offer and receives `{"sdp": <answer>}`). Being the offerer, the client's
ICE agent is the **controlling** agent (standard JSEP; werift follows it **[werift]** `transport/dtls.ts`).

## 2. Signalling

### 2.1 The ticket

Source: `ring-camera.ts` `createStreamingConnection`, `rest-client.ts`, `ring-types.ts`.

1. If the camera's `settings.live_view_disabled` is `true`, refuse ("Live view is currently disabled for <name> …
   Enable live view for this camera in the Ring app") without contacting Ring (`ring-camera.ts` `startLiveCall`).
2. `POST https://prd-api-us.prd.rings.solutions/api/v1/clap/ticket/request/signalsocket` (the "app API" base URL in
   `rest-client.ts`, path from `ring-camera.ts`). No body. The request carries the client's usual authenticated headers
   (`rest-client.ts`): `authorization: Bearer <access token>`, `hardware_id: <the session's hardware id>`,
   `User-Agent: android:com.ringapp` (same as every other Ring call; see `Ring.md` section 3).
3. Response (`SocketTicketResponse`): `{"ticket": "<string>", "responseTimestampe": <number>}` (the misspelling is the
   field's name). Only `ticket` is used.

A ticket is fetched for every call; it is never reused (`createStreamingConnection` runs once per `startLiveCall`).

### 2.2 The WebSocket

Source: `webrtc-connection.ts` constructor.

URL (one line):

`wss://api.prod.signalling.ring.devices.a2z.com:443/ws?api_version=4.0&auth_type=ring_solutions&client_id=ring_site-<random UUIDv4>&token=<ticket>`

- `client_id` is `ring_site-` followed by a fresh random UUID per connection.
- The ticket is inserted as is (no extra encoding in the source).
- Header `User-Agent` must be present, or Ring closes the socket immediately; its content does not seem to matter (the
  source sends `android:com.ringapp`). No `Authorization` header: the ticket is the credential.
- Same URL for Ring Edge cameras (local storage enabled, `settings.sheila_settings.local_storage_enabled === true`) and
  cloud cameras; the only difference is a log line (`webrtc-connection.ts`; `CHANGELOG.md`: "condensed to use a single
  API, rather than a separate setup between Ring Cloud and Ring Edge").

All frames are JSON text, one message per frame.

### 2.3 Ids

- `dialog_id`: a random UUIDv4 the client chooses per call, sent on every client message except the final `close`.
- `doorbot_id`: the camera's numeric id (the `id` of the device in Ring's device list), in every body both ways.
- `session_id`: chosen by Ring, learned from the first `session_created` or `session_started` carrying one.

Incoming filtering (`handleMessage`): a message whose `body.doorbot_id` is not this camera is ignored; once the session
id is known, a message whose `body.session_id` is present and different is ignored.

### 2.4 Sequence

Source: `webrtc-connection.ts`.

1. Socket opens → create the offer, set it locally, send `live_view` (2.5). Mark "offer sent".
2. Local ICE candidates are sent as `ice` messages as they are gathered, but only after "offer sent" (candidates gathered
   earlier wait for it). Null (end-of-gathering) candidates are not sent (`peer-connection.ts` filters them). No
   end-of-candidates message exists.
3. Ring sends `session_created` (and/or `session_started`) with the `session_id` (inferred: the client accepts either
   as the first).
4. Ring sends `sdp` (the answer) → set it as the remote description, then send session messages `activate_session` and
   `stream_options` (audio and video enabled), in that order. Without `activate_session` the stream ends after about
   70 s (source comment).
5. Ring sends its own `ice` candidates (trickled; inferred from the handler) → add each as a remote candidate.
6. Ring sends `notification` texts: `camera_connected` (the camera itself joined), `PeerConnectionState::kConnecting`,
   `PeerConnectionState::kConnected`; and `camera_started`, `stream_info` (ignored by the client).
7. Keep-alive: from the moment the connection object exists, every **5 s** send a session `ping` (source comment: the
   Ring Edge session needs one every 5 s; it is sent for every camera). Pings wait for the session id (2.6). Ring's
   `close` code 6 "Timeout waiting for ping" is what happens without them. Incoming `ping` → reply `pong`; incoming
   `pong` → nothing.
8. Two-way audio: when the first return-audio packet is about to be sent, wait for `camera_connected` (if it has not
   arrived yet) and send `camera_options` with `stealth_mode: false` once per call (turns on the camera's speaker).
9. End: send `{"reason": {"code": 0, "text": ""}, "method": "close"}`, close the socket, close the peer connection.

Session duration: the source sets no limit and never re-requests a ticket or renegotiates during a call; how long Ring
keeps an activated session open is not stated anywhere (unknown). A new call needs a new ticket and a new socket.

### 2.5 Messages the client sends (fake ids)

`live_view` (no `session_id` yet):

```json
{"method": "live_view", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"doorbot_id": 123456789,
          "stream_options": {"audio_enabled": true, "video_enabled": true},
          "sdp": "v=0\r\no=- …\r\n…"}}
```

`ice` (no `session_id`; `ice` is the candidate attribute value without `a=`, `mlineindex` the m-line index):

```json
{"method": "ice", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"doorbot_id": 123456789,
          "ice": "candidate:1 1 udp 2130706431 192.168.1.20 50312 typ host",
          "mlineindex": 0}}
```

Session messages (all carry `doorbot_id` and `session_id`; extra fields first, then those two):

```json
{"method": "activate_session", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-0000-4000-8000-00000000abcd"}}
{"method": "stream_options", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"audio_enabled": true, "video_enabled": true,
          "doorbot_id": 123456789, "session_id": "a1b2c3d4-0000-4000-8000-00000000abcd"}}
{"method": "camera_options", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"stealth_mode": false,
          "doorbot_id": 123456789, "session_id": "a1b2c3d4-0000-4000-8000-00000000abcd"}}
{"method": "ping", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-0000-4000-8000-00000000abcd"}}
{"method": "pong", "dialog_id": "3f6c2a8e-1b7d-4c55-9e0a-7d2b5c1f4e90",
 "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-0000-4000-8000-00000000abcd"}}
```

Final close (exactly this, no `dialog_id`, no `body`):

```json
{"reason": {"code": 0, "text": ""}, "method": "close"}
```

The session id format is not known (the example's UUID shape is made up).

### 2.6 Queueing

A session message sent before the session id is known is held and sent as soon as it arrives
(`sendSessionMessage`); once known, it is sent at once. After the call has ended nothing more is sent.

### 2.7 Messages Ring sends (types from `streaming-messages.ts`; fake ids)

```json
{"method": "session_created", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…"}}
{"method": "session_started", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…"}}
{"method": "sdp", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…",
                           "sdp": "v=0\r\n…", "type": "answer"}}
{"method": "ice", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…",
                           "ice": "candidate:…", "mlineindex": 1}}
{"method": "ping", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…"}}
{"method": "pong", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…"}}
{"method": "notification", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…",
                                    "is_ok": true, "text": "camera_connected"}}
{"method": "camera_started", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…"}}
{"method": "stream_info", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…",
                                  "transcoding": true, "transcoding_reason": "codec_mismatch"}}
{"method": "close", "body": {"doorbot_id": 123456789, "session_id": "a1b2c3d4-…",
                             "reason": {"code": 6, "text": "Timeout waiting for ping"}}}
```

Whether Ring's messages carry a `dialog_id` is not known (the client's types do not declare one and it never reads one).

Close reason codes (`streaming-messages.ts`, with texts quoted in its comments): `0` normal close; `5` authentication
failed (texts seen: an "Unauthorized: invalid or expired token" from Ring's liveview server, "Authentication failed: -1",
"Sessions with the provided ID not found"); `6` timeout ("Timeout waiting for ping"). Any `close` ends the call; the
client does not retry.

Other `notification` texts and unknown methods are logged as unknown and otherwise ignored.

### 2.8 Ending

Any of these ends the call, once (`callEnded` is idempotent): a `close` from Ring, a WebSocket error or close, the peer
connection's state becoming `failed` or `closed` (also ICE connection state `closed`), an error while handling a message
(an error mentioning "negotiate codecs failed" is reported as a known Ring issue, see 4.4), or the caller stopping.

## 3. The offer

### 3.1 What the client configures (`peer-connection.ts`)

- ICE servers (STUN only, no TURN, no credentials):
  `stun:stun.kinesisvideo.us-east-1.amazonaws.com:443`, `stun:stun.kinesisvideo.us-east-2.amazonaws.com:443`,
  `stun:stun.kinesisvideo.us-west-2.amazonaws.com:443`, `stun:stun.l.google.com:19302`, `stun:stun1.l.google.com:19302`,
  `stun:stun2.l.google.com:19302`, `stun:stun3.l.google.com:19302`, `stun:stun4.l.google.com:19302`.
- ICE transport policy `all`. **Bundle policy `disable`**: no `a=group:BUNDLE`; audio and video each get their own ICE
  credentials, candidates and DTLS transport.
- Audio codecs, in order: Opus 48000/2 (dynamic payload type), PCMU 8000/1 with payload type **0**.
- Video codecs, in order: H.264 90000 with RTCP feedback `transport-cc`, `ccm fir`, `nack`, `nack pli`, `goog-remb` and
  fmtp `packetization-mode=1;profile-level-id=640029;level-asymmetry-allowed=1` (High profile, level 4.1); then RTX
  90000. Only that one H.264 profile-level-id is offered.
- Transceivers, in order: audio `sendrecv` (it carries return audio), video `recvonly`. So m-line index 0 is audio,
  1 is video.
- No header extensions configured (werift's default is none **[werift]** `api/peerConfig.ts`), so the offer has no
  `a=extmap` lines even though `transport-cc` is listed as feedback.

### 3.2 What the offer therefore contains **[werift]**

- Payload types: werift numbers codecs without one as 96 + their index over the audio list followed by the video list,
  and gives RTX `apt=<its payload type − 1>` (`api/peerConfig.ts` `assignDynamicPayloadTypes`). Here: Opus **96**,
  PCMU **0**, H.264 **98**, RTX **99** with `apt=98`.
- Each m-line: `UDP/TLS/RTP/SAVPF`, port 9, `c=IN IP4 0.0.0.0`, `a=rtcp:9 IN IP4 0.0.0.0`, `a=rtcp-mux`, its own
  `a=ice-ufrag`/`a=ice-pwd`, `a=ice-options:trickle`, one `a=fingerprint:sha-256 <hex>`, `a=setup:actpass`, the
  direction, `a=mid` (`0` and `1`), `a=msid`, `a=ssrc:<n> cname:<cname>` (and on video an RTX SSRC with
  `a=ssrc-group:FID`), then `a=rtpmap`/`a=rtcp-fb`/`a=fmtp` per codec (`sdpManager.ts`
  `createMediaDescriptionForTransceiver`, `addTransportDescription`; `sdp.ts`).
- No `a=ice-lite` (werift is full ICE by default).
- Candidates gathered before the offer is serialised may appear in it; the rest are trickled (2.4).

Shape of the offer (reconstructed from werift's serialiser and the configuration; not a captured offer):

```
v=0
o=- <id> 0 IN IP4 0.0.0.0
s=-
t=0 0
a=msid-semantic:WMS *
m=audio 9 UDP/TLS/RTP/SAVPF 96 0
c=IN IP4 0.0.0.0
a=ice-ufrag:Ab3d
a=ice-pwd:<22+ chars>
a=ice-options:trickle
a=fingerprint:sha-256 AA:BB:…
a=setup:actpass
a=sendrecv
a=mid:0
a=rtcp:9 IN IP4 0.0.0.0
a=rtcp-mux
a=ssrc:1111111111 cname:<cname>
a=rtpmap:96 opus/48000/2
a=rtpmap:0 PCMU/8000
m=video 9 UDP/TLS/RTP/SAVPF 98 99
c=IN IP4 0.0.0.0
a=ice-ufrag:Xy9z
a=ice-pwd:<22+ chars>
a=ice-options:trickle
a=fingerprint:sha-256 AA:BB:…
a=setup:actpass
a=recvonly
a=mid:1
a=rtcp:9 IN IP4 0.0.0.0
a=rtcp-mux
a=ssrc:2222222222 cname:<cname>
a=ssrc:3333333333 cname:<cname>
a=ssrc-group:FID 2222222222 3333333333
a=rtpmap:98 H264/90000
a=rtcp-fb:98 transport-cc
a=rtcp-fb:98 ccm fir
a=rtcp-fb:98 nack
a=rtcp-fb:98 nack pli
a=rtcp-fb:98 goog-remb
a=fmtp:98 packetization-mode=1;profile-level-id=640029;level-asymmetry-allowed=1
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=98
```

The exact session-level lines (`o=`, `s=`, `msid-semantic`), `msid` values and whether `a=msid` appears on the
receive-only video line are werift details Ring is not known to depend on. No Ring-specific SDP attribute exists in the
client. What Ring is known to require: an offer it can match (4.4); nothing else about the offer is documented.

### 3.3 The answer

Nothing in the source shows a full answer. What the client relies on:

- `type` is `answer`; the SDP is applied as the remote description as is.
- Audio is either Opus or PCMU: the client decides "Opus" when the answer contains ` opus/` (case-insensitive)
  (`streaming-session.ts`); otherwise PCMU. Its FFmpeg handling feeds the answer's audio and video m-sections to FFmpeg
  as an SDP, so the answer has ordinary `m=audio`/`m=video` sections with `rtpmap` lines (`getCleanSdp`).
- The DTLS role Ring picks (`a=setup:active` or `passive`), its fingerprint algorithm, whether it includes candidates
  inline, whether it is ICE-lite and whether it accepts the RTX/feedback lines: **unknown**. A stack must handle either
  DTLS role (with `actpass` offered, the answerer chooses).

## 4. ICE, DTLS, media

### 4.1 ICE

- STUN only; no TURN server is configured anywhere, and streaming works for the original's users without one (unknown
  whether Ring ever needs relayed candidates from the client).
- Trickle both ways over the signalling socket (2.4, 2.7). Remote candidates carry `mlineindex` (0 audio, 1 video), not a
  mid.
- Candidate types Ring returns: **unknown** (no captured candidates). Ring Edge cameras stream from a local hub, so host
  candidates on the LAN are plausible there but not documented.
- The client agent is full ICE and controlling; whether Ring's side is ICE-lite is unknown (werift handles both).
- With bundle disabled there are two ICE sessions (audio, video) and two DTLS handshakes.

### 4.2 Payload types and RTP

- Payload types are whatever the answer confirms; the client takes media from the audio and video tracks without looking
  at payload types itself.
- Video RTP (already SRTP-decrypted) is forwarded per packet; the HomeKit side rewrites SSRC and payload type
  (`Ring.md` 6.4).
- Audio RTP from Ring is forwarded as plain RTP to FFmpeg for transcoding (`streaming-session.ts`).

### 4.3 Key frames

`peer-connection.ts`: when the first video RTP packet arrives, send an RTCP **PLI** for the received track's SSRC at once,
then every **4 s** for the rest of the call, and also whenever a key frame is requested explicitly (`requestKeyFrame`).
FIR is offered (`ccm fir`) but never sent by the client. PLI is a payload-specific feedback RTCP packet with the
receiver's RTCP sender SSRC and the media SSRC (**[werift]** `media/rtpReceiver.ts` `sendRtcpPLI`; werift sends it only
when PLI was negotiated). Other RTCP (receiver reports, NACK, REMB, transport-cc) is left to the stack; which of it Ring
needs is unknown.

### 4.4 Codec negotiation failures

Some cameras fail with an error containing "negotiate codecs failed"; the client reports it as a known Ring issue and
points to its "Streaming Legacy Mode" wiki page (`webrtc-connection.ts`). `stream_info` may report
`transcoding: true, transcoding_reason: "codec_mismatch"` (Ring transcoding server-side). `CHANGELOG.md` says the single
streaming API lets "all cameras" stream, "including those using HEVC". Whether Ring ever answers H.265 to this H.264-only
offer: unknown.

### 4.5 Two-way audio

- The audio transceiver is `sendrecv`; return audio is sent on it, so it uses the audio m-line's negotiated codec (Opus
  96 in practice), SRTP and transport.
- The original writes ready RTP packets into the outgoing track: Opus at 48 kHz, 2 channels, 60 ms frames, 48 kbit/s
  produced by FFmpeg from HomeKit's audio (`Ring.md` 6.4). The stack sends them with the sender's own SSRC and
  sequence/timestamp continuity (**[werift]** `media/rtpSender.ts`).
- Before the first return packet, `camera_options` `{"stealth_mode": false}` is sent once `camera_connected` was seen
  (2.4 step 8). Without it the camera's speaker stays off (inferred from the name and use).
- If Ring answered PCMU, the original's generic helper would send µ-law mono 8 kHz instead (`Ring.md` 6.4); the plugin
  does not handle it.

## 5. The HTTP alternative (not used by the plugin)

`simple-webrtc-session.ts`, authenticated like other Ring calls:

- `POST https://api.ring.com/integrations/v1/liveview/start`
  `{"session_id": "<client UUIDv4>", "device_id": 123456789, "sdp": "<offer>", "protocol": "webrtc"}` →
  `{"sdp": "<answer>"}`. No trickle ICE ("no backplane for trickle ICE": the offer must carry all its candidates).
- `POST …/liveview/end` `{"session_id": "…"}`.
- `PATCH …/liveview/options` `{"session_id": "…", "actions": ["turn_off_stealth_mode"]}`.
- Same `live_view_disabled` check first. Ring Edge cameras stream with the speaker on from the start with this API
  (`ring-camera.ts` comment). Keep-alive, session lifetime and key-frame behaviour for this path: unknown.

## 6. The SIP path

No longer used. `CHANGELOG.md` records "remove sip calling in favor of live calls" (10.0.0-beta.0, 2022-02-18) and that all streaming
uses "the new Ring api via WebRTC + WebSockets"; no SIP code remains in `packages/ring-client-api` (the `README.md`
still mentions `createSipSession`, which no longer exists).

## 7. Timing summary

| What | Value | Source |
|---|---|---|
| Ticket | one per call, fetched just before the socket | `ring-camera.ts` |
| Session `ping` | every 5 s from connection start, held until the session id is known | `webrtc-connection.ts` |
| Reply to Ring's `ping` | immediately, `pong` | `webrtc-connection.ts` |
| `activate_session` | right after applying the answer; without it the stream stops after ~70 s | `webrtc-connection.ts` |
| PLI | on the first video packet, then every 4 s, and on demand | `peer-connection.ts` |
| Ring's ping timeout | unknown interval; ends with `close` code 6 | `streaming-messages.ts` |
| Maximum session length | unknown; no re-request or renegotiation in the source | |

## 8. Unknowns

- A real answer SDP, Ring's DTLS role, its candidate types, ICE-lite or not, fingerprint algorithm.
- The session id format, whether Ring's messages carry `dialog_id`, and the full list of `notification` texts.
- Ring's ping timeout and maximum session length.
- Whether Ring needs RTCP receiver reports, NACK or transport-cc feedback from the client to keep sending.
- Whether answers can be H.265 or carry a different H.264 profile than the offered `640029`.
