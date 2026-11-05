# Tuya camera video: functional specification (clean room)

Written by the spec writer; contains no source code. It describes, in my own words, how the original plugin gives a
Tuya camera live video and snapshots in HomeKit. Interface identifiers (API paths, JSON keys, category and DP codes,
FFmpeg flags, HAP names) are quoted exactly because a replacement must use them.

This document extends `docs/clean-room/Tuya.md` (cited below as **Tuya.md**), whose §5.25 already covers the camera's
doorbell, motion and floodlight, and whose §2.2 covers request signing. FFmpeg behaviour that is the same as
`docs/clean-room/CameraFFmpeg.md` (cited as **CameraFFmpeg.md**) is referenced, not repeated.

## 1. Provenance

| Item | Value |
|---|---|
| Source | https://github.com/0x5e/homebridge-tuya-platform (the maintained fork; the official `tuya/tuya-homebridge` is its unmaintained origin, and this fork's `package.json` calls itself the fork of it) |
| Commit read | `ab74ea4eee3c9df0be2ecc04c0fc56d9c0b02207` (committed 2026-07-11), the same commit Tuya.md was written from |
| npm package | `@0x5e/homebridge-tuya-platform`, version `1.7.0-beta.58` |
| Licence | MIT. Copyright line in `LICENSE`: "Copyright (c) 2014-2021 Tuya Inc." (no other holder named; `package.json` has no author) |
| Files read | the camera accessory, the streaming delegate, the FFmpeg process wrapper, the (stub) recording delegate, the accessory factory, the OpenAPI client, `README.md`, `SUPPORTED_DEVICES.md`, `CHANGELOG.md`, `config.schema.json`, `ADVANCED_OPTIONS.md` |
| Runtime dependency used for video | `@homebridge/camera-utils`, only to find a bundled FFmpeg binary and to reserve free UDP ports |

The changelog credits a community contributor for adding camera (`sp`) support. There are no tests of the camera code in
the source.

## 2. Which devices are cameras

- Tuya category **`sp`** ("Smart Camera") is the only category that gets video. Its handler is the same one Tuya.md §5.25
  describes; there is **no required DP** for video.
- Video is configured for every `sp` device **except virtual devices**: a device whose id starts with `vdevo` gets the
  doorbell/motion/floodlight services but no camera controller.
- The camera controller is created once per accessory (a second configuration pass does nothing).
- Category `wxml` (wireless doorbell, Tuya.md §5.24) never gets video.
- No DP is read or written for video. The DPs that relate to the camera (`doorbell_ring_exist`, `doorbell_pic`,
  `alarm_message`, `movement_detect_pic`, `motion_switch`, `floodlight_switch`, `floodlight_lightness`) keep the meaning
  given in Tuya.md §5.25.
- `config.schema.json` has no camera option: video cannot be turned off or tuned per device except by hiding the device.
- The README lists the cloud service the user must authorise for cameras: **"IoT Video Live Stream"** (in addition to the
  services Tuya.md lists).

Homeswift note (not in the source): HomeKit wants a camera on its own, so in Homeswift the video camera is published through
`context.publishExternal` (CLAUDE.md). The doorbell, motion sensor and floodlight belong on that same external accessory
(with a doorbell, the camera is a video doorbell: Homeswift's `DoorbellController`). See §14 item 9 for what this means for
devices already in the bridge.

## 3. The allocate API

### 3.1 Request

| | |
|---|---|
| Method | `POST` |
| Path | `/v1.0/devices/{device_id}/stream/actions/allocate` (`{device_id}` = the Tuya device `id`) |
| Query | none |
| Body | `{"type":"rtsp"}` exactly (compact JSON, lowercase value) |
| Host | the configured endpoint (Tuya.md §2.1), the same as every other call |
| Headers and signing | identical to every other business call: Tuya.md §2.2, signed **with** the access token (the path does not start with `/v1.0/token`). Body hash is over the exact bytes sent. |
| Token | the same token as the rest of the plugin (Tuya.md §2.3–2.5), refreshed before the call if needed |
| Project types | the same path is used for both the Custom and the Smart Home project; there is no `users/{uid}` variant in the source |

### 3.2 Response

Success: the standard envelope (Tuya.md §2.2) whose `result` is an object; the source reads **only `result.url`**, a string,
and hands it to FFmpeg as the input. No other field is read, so a replacement must not require one.

Facts about the URL that the source relies on but does not check:

- it is a complete media URL that FFmpeg can open directly (scheme, host, port, path and access token all inside it);
- it **carries credentials**: treat it as a secret (never log it at info, mask it in debug logs; CLAUDE.md "Never log …
  tokens"). The source logs the whole FFmpeg command line, URL included, at debug: do not reproduce that.

Failure: the standard `{ "success": false, "code": …, "msg": … }`. The source does not test `success`; reading `url` from a
missing `result` throws (see §11). A replacement must treat a failure, or a success without a non-empty string `url`, as
"no stream available" and report it (§11).

### 3.3 URL lifetime

The source never states or reads a lifetime. It sidesteps the question by allocating a **fresh URL for every use** (§6). A
replacement must assume a URL is single-use and short-lived and never cache one across stream starts (see §7 for an
optional short cache for snapshots).

## 4. Stream types

- The source always asks for **`rtsp`**. No other type is ever requested, there is no option to change it, and no fallback.
- Tuya's public API documentation also mentions `hls` (and, per Tuya's docs, `flv` and `rtmp`) as values
  of `type`. These are **not** exercised by the source; their response shape is assumed to be the same (`result.url`). A
  replacement should request `rtsp` and may offer `hls` only as an opt-in fallback (unverified, §14).

## 5. Live streaming

The HomeKit side (prepare, SRTP, SSRC, return ports, stop, inactivity) is the HAP-NodeJS camera controller pattern and
matches CameraFFmpeg.md §7.3–7.6 except where stated. In Homeswift, `RTSPCameraStreamer` (`Sources/HomeswiftFFmpeg/
RTSPCamera.swift`) with an `RTSPSourceOpener` that performs the allocate call is the intended fit; the opener returns an
`RTSPSource` whose `url` is the allocated URL (nothing to release: there is no "stop stream" call in the source).

### 5.1 Prepare

As CameraFFmpeg.md §7.3: one free UDP port each for video and audio return, a random SSRC each, the controller's SRTP
key ‖ salt remembered per medium and echoed back in the reply. No cloud call happens at prepare.

### 5.2 Start

1. Look up the prepared session. If none: error log, failure reply. (The source then carries on and crashes; a replacement
   stops here.)
2. **Allocate** a fresh RTSP URL (§3).
3. Spawn FFmpeg with these arguments, in this order (one argv entry per token; `‹…›` substituted):

```
-hide_banner -loglevel verbose
-i ‹allocated URL›
-an -sn -dn -r ‹requested fps› -codec:v libx264 -pix_fmt yuv420p -color_range mpeg -f rawvideo
-preset ultrafast -tune zerolatency
[-b:v ‹requested max bitrate›k]            (only when the requested bitrate > 0)
-payload_type ‹video pt› -ssrc ‹video SSRC› -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80
-srtp_out_params ‹base64(video key ‖ salt)›
srtp://‹controller address›:‹video port›?rtcpport=‹video port›&pkt_size=1316
‹audio output, below›
-progress pipe:1
```

   Audio output, only when the requested audio codec is AAC-ELD or Opus:

```
-vn -sn -dn
-acodec libfdk_aac -profile:a aac_eld          (AAC-ELD)
-acodec libopus -application lowdelay          (Opus)
-flags +global_header -f null -ar ‹sample rate kHz›k -b:a ‹audio max bitrate›k -ac ‹channels›
-payload_type ‹audio pt› -ssrc ‹audio SSRC› -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80
-srtp_out_params ‹base64(audio key ‖ salt)›
srtp://‹controller address›:‹audio port›?rtcpport=‹audio port›&pkt_size=188
```

   Any other audio codec: error log "unsupported audio codec", the stream goes on without audio.

   Differences from CameraFFmpeg.md §7.4 worth knowing: the video **is not scaled** (no `-filter:v`; the camera's own
   resolution is sent whatever HomeKit asked), the encoder is always libx264, HomeKit's MTU is ignored (1316), and there
   is no `-rtsp_transport`, timeout, `-analyzeduration` or `-probesize` on the input. A replacement may use Homeswift's
   standard argument builder (which scales and adds those input flags) — that is an improvement, not a deviation that
   HomeKit notices.

4. Supervision: as CameraFFmpeg.md §7.5, with these differences:
   - stderr lines containing `[panic]`, `[fatal]` or `[error]` are always logged at error level (no debug switch);
   - the inactivity timer is armed only when the **first** datagram arrives on the video return port (not at start), and
     its period is `rtcp_interval × 5` seconds **unclamped** (0.5 s → 2.5 s). A replacement should use Homeswift's
     standard clamp (30–300 s, CameraFFmpeg.md §7.5): a 2.5 s period stops healthy streams on a lost RTCP burst.
   - The start reply is sent on FFmpeg's first stderr line, as in CameraFFmpeg.md; with `-loglevel verbose` that line
     comes before the RTSP connection is up, so the reply does not mean video is flowing.
5. Reconfigure: acknowledged, ignored. Stop: as CameraFFmpeg.md §7.6 (write `q` + newline, SIGKILL after 2 s; close the
   socket; forget the session; log "stopped video stream").

Offline devices: a stream start does **not** check the device's `online` flag (snapshots do). A replacement should refuse a
stream start for an offline device without calling the cloud (§11).

## 6. Reallocation

- One allocate call per **stream start** and one per **snapshot**. Nothing else allocates.
- A running stream keeps its URL for its whole life; the source never refreshes a URL mid-stream. If the cloud ends the
  RTSP session, FFmpeg exits and the session ends (CameraFFmpeg.md §7.5's exit rules); HomeKit can start a new one, which
  allocates again.
- There is no periodic allocation, no pre-allocation and no reuse between a snapshot and a stream.

## 7. Snapshots

1. If the device's `online` flag (from the device list / lifecycle push, Tuya.md §2.7, §3.5) is false: debug log, failure
   "device is currently offline".
2. Allocate a fresh RTSP URL (§3).
3. Run FFmpeg once with: `-i ‹URL› -frames:v 1 -hide_banner -loglevel error -f image2 -` and collect stdout. (The
   `image2` muxer to a pipe produces a JPEG.)
4. Process exit: non-empty stdout → that JPEG is the reply; empty → error log (with up to the last few stderr chunks) and
   failure. Spawn failure → error log, failure.
5. The requested snapshot size is only logged; the image is the camera's full frame, not resized. There is no snapshot
   cache, no in-flight coalescing, no timeout on the process, and no reuse of a running stream (the source has a to-do for
   that).

No Tuya "snapshot" API is used. The `doorbell_pic` / `movement_detect_pic` DPs carry base64 data (Tuya.md §5.25) that may
reference an event picture; the source never uses them for snapshots (§14 item 7).

Homeswift recommendation: reuse the standard snapshot path (coalesce requests in flight, a short result cache like
CameraFFmpeg.md §7.2's 3 s, a resize to the requested size, a kill timeout), because every snapshot costs a cloud call and
a full RTSP connection.

## 8. FFmpeg input options for these streams

What the source does: nothing beyond `-i ‹URL›`. What a replacement needs, as facts about FFmpeg and these streams:

- **Transport:** a cloud RTSP stream over the internet should be read with `-rtsp_transport tcp` (UDP through NAT is
  unreliable and the cloud may not offer it). For an `rtsps://` URL FFmpeg uses TCP anyway; the flag is harmless.
  Homeswift's `RTSPCameraOptions.rtspOverTCP` adds it for any URL starting with `rtsp` (which covers `rtsps`); it should be
  **on** for Tuya.
- **Timeouts:** without a socket timeout FFmpeg can hang forever on a cloud URL that stopped answering. FFmpeg's RTSP
  demuxer takes `-timeout ‹microseconds›` (older builds `-stimeout`). A value of 10–15 s (`10000000`–`15000000`) before
  `-i` is appropriate; snapshots should also be killed by the plugin if they run longer than HomeKit waits (about 20 s).
- **Probing:** Homeswift's defaults (`-analyzeduration 15000000 -probesize 100000000`) work but delay the first frame;
  smaller values (for example 5 s / 5 MB) shorten start-up. Optional.
- **Encoding:** the source always transcodes with libx264. Whether `copy` (send the camera's H.264 as is) works with
  HomeKit depends on the camera's profile and keyframe interval; keep transcoding as the default.
- **Audio:** AAC-ELD needs an FFmpeg with `libfdk_aac` (CameraFFmpeg.md §7.4); without it, use Homeswift's
  `liveAudioEncoder()` choice or send no audio.

## 9. Quota and rate limits

- The source applies **no** rate limit, cache or quota accounting to allocate calls.
- Transport retries are the generic ones (Tuya.md §2.2: up to 10 retries on network errors, exponential back-off from
  100 ms).
- The only quota-related behaviour is the generic error explanation: code `28841002` (subscription expired) and `28841101` /
  `28841105` (API not subscribed). The source's "not subscribed" message does not name "IoT Video Live Stream"; a
  replacement's message for an allocate failure with those codes should name it.
- Tuya's cloud services are trial subscriptions with call quotas (README: the trial must be extended every 6 months). The
  numeric quota of "IoT Video Live Stream" is not in the source (§14). Because every snapshot allocates, a Home app left on
  a camera tile can make many calls; a replacement should coalesce snapshots (§7) and, after a quota/subscription error,
  back off allocation for that camera (for example 5 minutes) rather than calling on every request.

## 10. Two-way audio and recording

- **Two-way audio: none.** The controller advertises `twoWayAudio` false; the return-audio process slot exists but is
  never started.
- **HomeKit Secure Video: none.** A recording delegate exists only as unimplemented stubs, and the recording options are
  commented out of the controller configuration. A replacement must not advertise recording.

## 11. Errors and edge cases (fix in the replacement)

| Case | Source | Replacement |
|---|---|---|
| Allocate returns `success: false` or no `url` | throws while reading `url`; the stream start is never answered (HomeKit times out); a snapshot fails | fail the start / snapshot at once with a clear log naming the Tuya `code` and `msg` |
| Allocate HTTP status ≠ 200 | request never completes (Tuya.md §2.2 bug) | fail the request |
| No prepared session at start | error reply, then continues and crashes | stop after the error reply |
| Device offline | snapshot refused; stream attempted | refuse both without a cloud call |
| Virtual device (`vdevo…`) | no camera | same |
| URL in logs | full command line at debug | mask the URL |
| Inactivity period | `rtcp_interval × 5` s, unclamped | clamp 30–300 s |
| FFmpeg missing | spawn error, failure reply | same, logged once per camera |

## 12. HomeKit camera configuration advertised

Exactly as Tuya.md §5.25 "Video":

- SRTP crypto suite: `AES_CM_128_HMAC_SHA1_80` only.
- Video: H.264, profiles Baseline, Main, High; levels 3.1, 3.2, 4.0.
- Resolutions (width × height @ fps), in this order: 320×180@30, 320×240@15, 320×240@30, 480×270@30, 480×360@30,
  640×360@30, 640×480@30, 1280×720@30, 1280×960@30, 1920×1080@30, 1600×1200@30.
- Audio: AAC-ELD at 16 kHz only; `twoWayAudio` false. (Opus is handled at start if HomeKit asks, but not advertised.)
- No recording (HKSV) options; no motion/doorbell event triggers for recording.
- One camera stream management service (the controller default).
- The doorbell, when present (Tuya.md §5.25), is a Doorbell service on the same accessory; the source uses a plain camera
  controller plus a separate Doorbell service, not HAP-NodeJS's doorbell controller.

## 13. Test vectors

Common inputs as Tuya.md §9: `accessId` `4h3dxjpwamt9gcrkqv8e`, `accessKey` `a1b2c3d4e5f60718293a4b5c6d7e8f90`,
`t` `1700000000000`, `nonce` `6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b`, access token `c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4`.
Invented device id `bf5c4a3b2d1e0f9a8b7c`. Computed with `shasum -a 256` and `openssl dgst -sha256 -hmac`; the same tooling
reproduces Tuya.md §9.4's `sign` (`67B12C40…52C1`), which validates the method.

### 13.1 Allocate RTSP

`POST /v1.0/devices/bf5c4a3b2d1e0f9a8b7c/stream/actions/allocate`, body (exact bytes) `{"type":"rtsp"}`

- Body SHA-256: `4ca274a8eb0cfb8fd14c59b1c83570a1e93743355dfc174371290903cee74e0e`
- String to sign:
  `POST\n4ca274a8eb0cfb8fd14c59b1c83570a1e93743355dfc174371290903cee74e0e\nclient_id:4h3dxjpwamt9gcrkqv8e\n\n/v1.0/devices/bf5c4a3b2d1e0f9a8b7c/stream/actions/allocate`
- HMAC message: `4h3dxjpwamt9gcrkqv8e` + `c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4` + `1700000000000` + nonce + string to sign
- `sign` = `E81986164D7512568222E0D92D6493101137A539E0184B25DE188AFC30421D05`

### 13.2 Allocate HLS (only if the opt-in fallback is built)

Same path, body `{"type":"hls"}`

- Body SHA-256: `770aad24cf3e6e1fdf89a5eb4384f960b3c9486ad496d94ff2986d24198ce612`
- `sign` = `61EE8DDD3F20F74718C28541CAF5390C3C23D4AA02F7204FC502F4A200E20F0B`

### 13.3 Responses (illustrative, invented)

Success:
`{"success":true,"result":{"url":"rtsps://cam-proxy.example.invalid:443/v1/proxy/bf5c4a3b2d1e0f9a8b7c?token=ZXhhbXBsZQ"},"t":1700000000123,"tid":"0a1b2c3d4e5f"}`
→ URL `rtsps://cam-proxy.example.invalid:443/v1/proxy/bf5c4a3b2d1e0f9a8b7c?token=ZXhhbXBsZQ`; a log line shows it masked.

Not subscribed:
`{"success":false,"code":28841101,"msg":"No permissions. This API is not subscribed.","t":1700000000123,"tid":"0a1b2c3d4e60"}`
→ start reply fails at once; the log names "IoT Video Live Stream"; further allocations for this camera back off.

Success without URL: `{"success":true,"result":{},"t":1700000000123}` → "no stream available", failure.

### 13.4 Snapshot argv

URL as in 13.3, device online, request 640×360, source behaviour:
`-i`, `rtsps://cam-proxy.example.invalid:443/v1/proxy/bf5c4a3b2d1e0f9a8b7c?token=ZXhhbXBsZQ`, `-frames:v`, `1`,
`-hide_banner`, `-loglevel`, `error`, `-f`, `image2`, `-`. Device offline → failure, **no** allocate call (a fake
transport records zero requests).

### 13.5 Stream argv (source behaviour)

URL as 13.3; HomeKit asks 1920×1080, 30 fps, 802 kbps, video pt 99, address 192.168.1.20, video port 51000; audio
AAC-ELD 16 kHz, 24 kbps, 1 channel, pt 110, port 51002; SSRCs 1111 / 2222; SRTP base64 `VV…` / `AA…`:

```
-hide_banner -loglevel verbose -i rtsps://cam-proxy.example.invalid:443/v1/proxy/bf5c4a3b2d1e0f9a8b7c?token=ZXhhbXBsZQ
-an -sn -dn -r 30 -codec:v libx264 -pix_fmt yuv420p -color_range mpeg -f rawvideo -preset ultrafast -tune zerolatency
-b:v 802k -payload_type 99 -ssrc 1111 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params VV…
srtp://192.168.1.20:51000?rtcpport=51000&pkt_size=1316
-vn -sn -dn -acodec libfdk_aac -profile:a aac_eld -flags +global_header -f null -ar 16k -b:a 24k -ac 1
-payload_type 110 -ssrc 2222 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params AA…
srtp://192.168.1.20:51002?rtcpport=51002&pkt_size=188
-progress pipe:1
```

A Homeswift implementation on `RTSPCameraStreamer` will instead produce its standard argv (with `-rtsp_transport tcp`,
probing flags and a scale filter); its tests should check that the input URL is the allocated one and that exactly one
allocate call was made per start.

### 13.6 Allocation counts (behavioural)

- Two snapshots → two allocate calls (source); with the recommended coalescing, two snapshots within the cache window →
  one call.
- One stream start, then reconfigure, then stop → one allocate call.
- Device id `vdevo1234567890abcdef` (category `sp`) → no camera controller, zero allocate calls ever.

## 14. Gaps and hard parts

1. **URL lifetime and scheme.** Not in the source. Tuya's cloud URLs are commonly reported to be `rtsps://` on port 443
   and to expire within minutes; unverified here. Allocating per use makes the lifetime matter only for very long streams,
   whose behaviour at expiry (cloud closes, FFmpeg exits) is unobserved.
2. **Other response fields** (an expiry, a stream id) may exist; the source reads only `url`.
3. **Stopping a cloud stream.** The source never tells the cloud a stream ended; whether Tuya counts open sessions against
   a limit is unknown.
4. **Quota numbers** for "IoT Video Live Stream" are not in the source or its docs.
5. **HLS/FLV/RTMP** are untested by the source; `type` casing for them (lowercase as for `rtsp`) is assumed.
6. **Smart Home vs Custom.** The source uses the same `/v1.0/devices/…` path for both project types; whether a Smart Home
   project ever needs a user-scoped path is unverified (it works for the source's users).
7. **Event pictures.** `doorbell_pic` / `movement_detect_pic` likely encode a link to an (often encrypted) event image; the
   source only tests them for non-emptiness. Using them as snapshots is not specified.
8. **Native resolution.** The source sends the camera's native size regardless of the request; HomeKit tolerates it in
   practice. Scaling (Homeswift's standard) is safer.
9. **Bridged vs external.** The source attaches the camera controller to the bridged accessory. Homeswift publishes cameras
   externally (CLAUDE.md). The existing Homeswift Tuya plugin already shows `sp` devices' doorbell, motion and floodlight in
   the bridge; moving them onto an external accessory changes their identity in HomeKit (the user adds the camera
   separately, rooms and automations of the old bridged services are lost). Decide whether the bridged event services stay
   (and the external accessory adds only video) or move; whichever is chosen, keep the bridged aids/iids of anything that
   stays.
10. **Two-way audio and HKSV** are absent in the source; adding them is new work with no reference behaviour.
11. **Audio from the camera.** The cloud stream's audio codec is not known from the source (it always transcodes); a camera
    without audio makes the audio output fail to map — FFmpeg's behaviour then (error vs silence) should be tested against
    a fixture.
