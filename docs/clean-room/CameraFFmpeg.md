# CameraFFmpeg — functional specification

Written by the spec writer; contains no source code. Everything below is a description, in the spec writer's own words,
of the externally observable behaviour of the original plugin. JSON keys, wire strings, HTTP paths, MQTT topics and
FFmpeg command-line flags are reproduced exactly because they are interfaces.

## 1. Provenance

| | |
|---|---|
| Source | https://github.com/homebridge-plugins/homebridge-camera-ffmpeg |
| Commit read | `7522d924bedf922b3a7a4d71d35eb722dd3d790e` (2025-09-18, version 4.1.0) |
| npm package | `@homebridge-plugins/homebridge-camera-ffmpeg` (formerly the unscoped `homebridge-camera-ffmpeg`, before 4.0.0) |
| Licence | Conflicting: the `LICENSE` file is the Apache License 2.0 text with an unfilled copyright line (`Copyright {yyyy} {name of copyright owner}`); `package.json` declares `"license": "ISC"`. Treat as Apache-2.0 / ISC; neither names a copyright holder explicitly. |
| Authors / holders | `package.json` author: Khaos Tian; contributors: Sunoo, Khaos Tian; maintainers: Homebridge. The changelog credits Donavan Becker and others for recent releases. |
| Runtime deps (for reference) | `@homebridge/camera-utils` (only to find a bundled FFmpeg path), `mqtt` 5.14.1 (MQTT.js), `pick-port` (free UDP port), `@homebridge/plugin-ui-utils` (custom UI) |
| Files read | `config.schema.json`, `src/*.ts` (platform, streaming, recording, prebuffer, ffmpeg process wrapper, logger, settings), `src/homebridge-ui/*`, `README.md`, `CHANGELOG.md`, `docs/_automation/*.md` |

## 2. Plugin kind and names

- Kind: **dynamic platform plugin**, `singular: true` (one platform block per Homebridge instance).
- Platform name / `pluginAlias`: **`Camera-ffmpeg`** (exact case, with hyphen). Config blocks carry `"platform": "Camera-ffmpeg"`.
- Every camera is published as an **external (unbridged) accessory** — each camera gets its own HAP server and is paired
  separately in the Home app with the bridge's setup code. Since 4.0.0 there is no option to bridge a camera. (The legacy
  `unbridge` key is no longer read.)
- The schema advertises a custom UI (`customUi: true`), described in section 11.

## 3. Configuration interface

All keys are optional unless noted. Unknown keys are ignored (old configs contain legacy keys such as `unbridge`,
`hflip`, `vflip`, `additionalCommandline`, a top-level `topic`; they have no effect and must not cause an error).
"Falsy" below means: absent, `null`, `false`, `0` or empty string, following JavaScript truthiness, because the source
uses truthiness tests in most places; where it tests only for absence ("undefined"), that is said explicitly.

### 3.1 Platform level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — (required) | `"Camera-ffmpeg"` |
| `name` | string | schema default `"Camera FFmpeg"` | Platform display name; not used by the plugin's behaviour. |
| `videoProcessor` | string | see below | Path or name of the FFmpeg-compatible executable used for every process (snapshots, streams, two-way audio, recording, prebuffer). If falsy: the FFmpeg bundled by Homebridge's `ffmpeg-for-homebridge` package when installed, else `ffmpeg` from `PATH`. |
| `mqtt` | string | none | Hostname or IP of the MQTT broker. If falsy, MQTT is not started at all, and per-camera `mqtt` blocks are ignored. |
| `portmqtt` | integer (accept a numeric string too) | `1883` | Broker port. Falsy → 1883. |
| `tlsmqtt` | boolean | `false` | Truthy → connect with TLS (`mqtts://`), else plain TCP (`mqtt://`). |
| `usermqtt` | string | none | MQTT username; absent → none sent. |
| `passmqtt` | string | none | MQTT password (**secret**). |
| `porthttp` | integer (the docs' examples write it as a string, `"8080"`: accept both) | none | TCP port of the HTTP automation server. Falsy → no HTTP server. |
| `localhttp` | boolean | `false` | Truthy → the HTTP server listens on `localhost` only; else on all interfaces. |
| `cameras` | array of camera objects | `[]` | The cameras. |

### 3.2 Camera object (`cameras[]`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | — (schema: required) | Display name; **also the identity seed** (section 4.1). |
| `manufacturer` | string | `"Homebridge"` | Accessory Information Manufacturer (falsy → default). |
| `model` | string | `"Camera FFmpeg"` | Accessory Information Model (falsy → default). |
| `serialNumber` | string | `"SerialNumber"` | Accessory Information Serial Number (falsy → default). |
| `firmwareRevision` | string | the plugin's version, `"4.1.0"` at this commit | Accessory Information Firmware Revision (falsy → default). A port should use its own version string. |
| `motion` | boolean | `false` | Add a Motion Sensor service. |
| `doorbell` | boolean | `false` | Add a Doorbell service. |
| `switches` | boolean | `false` | Add "trigger" Switch services for motion and/or doorbell (only for those of the two that are enabled). |
| `motionTimeout` | integer ≥ 0, seconds | `1` | Seconds after a motion trigger before the sensor resets automatically; `0` disables the automatic reset for MQTT and HTTP triggers (switch triggers always reset after at least 1 s). Also the hold time of the doorbell trigger switch (section 6.3). |
| `motionDoorbell` | boolean | `false` | A motion trigger also rings the doorbell (when no motion reset timer was already running). |
| `videoConfig` | object | — (required) | Video settings, 3.3. |
| `mqtt` | object | none | MQTT topics, 3.4. Note: the same key `mqtt` is a string at platform level and an object at camera level. |

### 3.3 `videoConfig`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `source` | string | — (required) | FFmpeg input options, e.g. `-i rtsp://user:pass@host:554/stream`, possibly with options before `-i` (`-rtsp_transport tcp -i …`, `-re -f mjpeg -i …`). **Contains secrets** (credentials in URLs). |
| `stillImageSource` | string | none → `source` is used | FFmpeg input options for snapshots, same syntax as `source`. **May contain secrets.** |
| `returnAudioTarget` | string | none | FFmpeg *output* options for two-way audio sent back to the camera (experimental). Truthy → two-way audio is advertised and a second FFmpeg is started per stream. **May contain secrets.** |
| `maxStreams` | integer ≥ 1 | `2` (applied when absent) | Number of simultaneous live streams (number of RTP stream management services). |
| `maxWidth` | integer ≥ 0, even | absent = no cap | Cap on stream width; `0` = use the source's width (no scaling in that dimension). |
| `maxHeight` | integer ≥ 0, even | absent = no cap | Cap on stream height; `0` = source height. |
| `maxFPS` | integer ≥ 0 | absent = no cap | Cap on frame rate; `0` = source frame rate (no `-r`). |
| `maxBitrate` | integer ≥ 0, kbit/s | absent = no cap | Cap on video bitrate; `0` = no `-b:v`. |
| `forceMax` | boolean | `false` | Truthy → each defined `max*` value replaces HomeKit's request even when the request is lower. |
| `preserveRatio` | boolean | — | In the schema but **never read**: no effect. |
| `vcodec` | string | `"libx264"` | Video encoder name (`-codec:v`). Common values: `libx264`, `h264_omx`, `h264_videotoolbox`, `h264_v4l2m2m`, `copy`. `copy` disables filters, frame rate and bitrate (section 7.3). |
| `packetSize` | number, multiple of 188 | `1316` | `pkt_size` of the video SRTP output (falsy → 1316). The audio output always uses 188. |
| `videoFilter` | string | none | Comma-separated extra FFmpeg video filters, prepended to the plugin's scaling filters. If one comma-separated element is exactly `none`, it is removed and the plugin's own scaling filters are not added. |
| `encoderOptions` | string | `-preset ultrafast -tune zerolatency` **only when** the effective vcodec is `libx264`; otherwise none | Extra options placed after the video output options. |
| `mapvideo` | string | none | Truthy → `-map <value>` for the video output, replacing the default `-an -sn -dn`. |
| `mapaudio` | string | none | Truthy → `-map <value>` for the audio output, replacing the default `-vn -sn -dn`. |
| `audio` | boolean | `false` | Truthy → stream audio to HomeKit. Also affects recording when explicitly `false` (section 9.4). |
| `debug` | boolean | `false` | Verbose FFmpeg output for snapshots and main stream; promotes the plugin's debug messages for this camera to info level (section 10). |
| `debugReturn` | boolean | `false` | Verbose FFmpeg output for the two-way audio process. |
| `recording` | boolean | `false` | Enable HomeKit Secure Video (HKSV) recording. |
| `prebuffer` | boolean | `false` | Keep a rolling buffer of the source for HKSV. Only effective when `recording` is truthy. |

### 3.4 Camera `mqtt` block

| Key | Type | Default | Meaning |
|---|---|---|---|
| `motionTopic` | string | none (the schema's `homebridge/motion` is only a placeholder) | Topic on which a matching message triggers motion. |
| `motionMessage` | string | the camera's `name` | Exact payload that triggers motion. |
| `motionResetTopic` | string | none (placeholder `homebridge/motion/reset`) | Topic on which a matching message resets motion. |
| `motionResetMessage` | string | the camera's `name` | Exact payload that resets motion. |
| `doorbellTopic` | string | none (placeholder `homebridge/doorbell`) | Topic on which a matching message rings the doorbell. |
| `doorbellMessage` | string | the camera's `name` | Exact payload that rings the doorbell. |

Each of the three actions is registered only when its topic is truthy. A falsy message falls back to the camera name.

### 3.5 Example blocks (test fixtures)

Minimal:

```json
{ "platform": "Camera-ffmpeg",
  "cameras": [ { "name": "Front Door",
                 "videoConfig": { "source": "-i rtsp://u:p@10.0.0.5:554/s1" } } ] }
```

Full automation:

```json
{ "platform": "Camera-ffmpeg",
  "mqtt": "127.0.0.1", "portmqtt": 1883, "usermqtt": "hb", "passmqtt": "secret",
  "porthttp": "8080", "localhttp": true,
  "cameras": [ { "name": "Front Door", "motion": true, "doorbell": true, "switches": true,
                 "motionTimeout": 15, "motionDoorbell": false,
                 "videoConfig": { "source": "-rtsp_transport tcp -i rtsp://u:p@10.0.0.5:554/s1",
                                  "stillImageSource": "-i http://10.0.0.5/snap.jpg",
                                  "maxStreams": 2, "maxWidth": 1280, "maxHeight": 720, "maxFPS": 30,
                                  "audio": true, "recording": true, "prebuffer": false },
                 "mqtt": { "motionTopic": "home/camera", "motionMessage": "ON",
                           "motionResetTopic": "home/camera", "motionResetMessage": "OFF",
                           "doorbellTopic": "home/doorbell", "doorbellMessage": "ON" } } ] }
```

## 4. Device model

There is one device kind: a **camera**, optionally with a motion sensor, a doorbell and trigger switches, all on the same
external accessory.

### 4.1 Validation and identity

Cameras are processed in array order:

1. If `name` is falsy: log an error saying the camera has no name, and **give it the name `Camera N`**, where N = (number
   of cameras accepted so far) + 1. Despite the message, the camera is *not* skipped. The fallback name is written back
   into the camera's config, so it is also the default MQTT message and the HTTP lookup name.
2. If `videoConfig` is missing: error, camera skipped.
3. If `videoConfig.source` is falsy: error, camera skipped. Otherwise, if splitting `source` on whitespace yields no token
   exactly equal to `-i`: warning (likely misconfigured), camera kept.
4. If `stillImageSource` is set and has no `-i` token: warning, kept.
5. If `vcodec` is `copy` and `videoFilter` is set: warning that the filter will be ignored, kept.
6. Identity: **accessory UUID = HAP-NodeJS `uuid.generate(name)`** over the UTF-8 name string. If that UUID is already
   taken by an earlier camera: warning about duplicate names, the later camera is skipped.

HAP-NodeJS `uuid.generate(data)`: take the lowercase hex SHA-1 of the data (40 hex digits, s[0]…s[39]); output the
pattern `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where each `x` is the next unused hex digit of s in order and the `y` is
the next digit d replaced by `(d & 0x3) | 0x8`; the literal `4` and the dashes do not consume digits. So the output uses
s[0…30]: s[0–7] `-` s[8–11] `-4` s[12–14] `-` y(s[15]) s[16–18] `-` s[19–30].

Vectors:

| name | SHA-1 | UUID |
|---|---|---|
| `Front Door` | `4ffef82265923bb898a028dd181bd698060dba07` | `4ffef822-6592-43bb-898a-028dd181bd69` |
| `Camera Name` | `727c22f8f330b789226010e5d64a28390de26b41` | `727c22f8-f330-4b78-9226-010e5d64a283` |
| `Camera 1` | `404d3fdaa26671223f118a7efa9eddf4b63276ec` | `404d3fda-a266-4712-a3f1-18a7efa9eddf` |

Consequence: renaming a camera in config creates a new accessory. The accessory's display name is the camera name.

External-accessory identity (Homebridge host behaviour, not the plugin's): Homebridge derives the external accessory's
HAP "username" (advertised device ID) from the accessory UUID, gives it the bridge's setup code and a port from the
bridge's port range, and keeps its pairings and instance ids per external accessory. A Homeswift port cannot inherit
Homebridge's pairings anyway: the user re-adds each camera. What must be stable is the accessory `id` from the name, so
Homeswift's own aid/iid keys stay stable across restarts.

Accessory category: the plugin passes no category when creating the accessory (Homebridge's default is "Other", 1). See
Gaps.

### 4.2 Services

Created on each start, in this order:

1. **Accessory Information**: Manufacturer, Model, Serial Number, Firmware Revision as in 3.2. Identify requests are only
   logged (info).
2. **Camera controller services** (HAP-NodeJS `CameraController`, which Homeswift's `CameraController` ports):
   - `maxStreams` (default 2) × **Camera RTP Stream Management**, with the streaming options of section 4.3.
   - **Microphone** (always, as the camera controller creates it) and **Speaker** only when `returnAudioTarget` is truthy
     (two-way audio).
   - When `recording` is truthy: the recording services HAP-NodeJS's controller adds (Camera Recording Management,
     Camera Operating Mode, Data Stream Transport Management), with the options of section 9.1. No `sensors` option is
     passed to the controller, so the controller itself creates no motion/occupancy sensor.
3. Before adding the optional services, any existing Motion Sensor, Doorbell, Switch with subtype `DoorbellTrigger`,
   Switch with subtype `MotionTrigger`, and Stateless Programmable Switch with subtype `DoorbellSwitch` (left over from
   older versions) are removed from the accessory, then re-added as below.
4. If `motion`: **Motion Sensor**, name = camera name, no subtype. Characteristic Motion Detected (bool, initial false).
5. If `motion` and `switches`: **Switch**, name `<name> Motion Trigger`, subtype `MotionTrigger`. Characteristic On.
6. If `doorbell`: **Doorbell**, name `<name> Doorbell`, no subtype. Characteristic Programmable Switch Event (the
   standard Doorbell service; only Single Press, value 0, is ever sent).
7. If `doorbell` and `switches`: **Switch**, name `<name> Doorbell Trigger`, subtype `DoorbellTrigger`. Characteristic On.

No service is marked primary and no services are linked by the plugin. No characteristic props are changed from the HAP
defaults. There are no unit conversions.

Stable id keys for Homeswift (service type + subtype): RTP Stream Management × N (HAP-NodeJS gives them subtypes equal to
the stream index), Microphone, Speaker, recording services, Motion Sensor (no subtype), Switch `MotionTrigger`, Doorbell
(no subtype), Switch `DoorbellTrigger`.

### 4.3 Streaming options advertised

- Stream count: `maxStreams` (default 2).
- SRTP crypto suites: only `AES_CM_128_HMAC_SHA1_80`.
- Video codec H.264, profiles Baseline, Main, High; levels 3.1, 3.2, 4.0.
- Video resolutions [width, height, fps], in this order: `[320,180,30]`, `[320,240,15]`, `[320,240,30]`, `[480,270,30]`,
  `[480,360,30]`, `[640,360,30]`, `[640,480,30]`, `[1280,720,30]`, `[1280,960,30]`, `[1920,1080,30]`,
  `[1600,1200,30]`. (`320×240@15` is the Apple Watch's.)
- Audio: codecs = one entry, **AAC-ELD at 16 kHz** (Opus is not advertised). `twoWayAudio` = whether `returnAudioTarget`
  is truthy. These audio options are advertised whether `audio` is on or not.

## 5. Platform lifecycle

1. On construction: validate cameras (4.1).
2. Cached accessories handed back by the host (only possible for bridged accessories from versions before 4.0.0): logged
   at info. If one matches a configured camera's UUID it is set up like a new one (services as in 4.2) and kept as it is,
   bridged, *not* re-published externally.
3. After launch, for each accepted camera without a cached accessory: create the accessory (name, UUID), set it up
   (4.2), and publish it as an external accessory; logged at info.
4. If `prebuffer` is truthy (and recording on), start the prebuffer for that camera right after the controller is
   configured (section 9.3).
5. MQTT (if `mqtt` is set) and HTTP (if `porthttp` is set) are started after all accessories (sections 6.4, 6.5).
6. Cached accessories with no matching camera are unregistered (logged at info).
7. Shutdown: recording processes and the prebuffer FFmpeg are killed (section 9). The live-stream shutdown handler is
   effectively a no-op in the source (it iterates the session map in a way that visits nothing), so live-stream FFmpegs
   are not stopped explicitly at shutdown. A port should stop them.

## 6. Motion and doorbell

Per camera there are two independent timers: a **motion timer** and a **doorbell timer**. Each automation call returns a
result `{error: Bool, message: String, cooldownActive?: Bool}` used by the HTTP API (section 6.5); MQTT and switch
triggers ignore it.

### 6.1 Motion trigger (input: active, minimumTimeout)

If the camera has no Motion Sensor service: result `{error: true, message: "Motion is not enabled for this camera."}`,
nothing else happens.

Otherwise (debug log of on/off):

- Let `hadTimer` = a motion timer was running; cancel it in any case.
- **active = true**:
  1. Motion Detected ← true (event pushed); Motion Trigger switch (if present) On ← true.
  2. If `!hadTimer` and `motionDoorbell` is truthy: ring the doorbell (6.2, active = true).
  3. t = `motionTimeout` if present (not undefined/null), else 1. If t < minimumTimeout, t = minimumTimeout.
  4. If t > 0: start a motion timer of t seconds; when it fires (debug log): Motion Detected ← false, trigger switch On ←
     false.
  5. Result `{error: false, message: "Motion switched on.", cooldownActive: hadTimer}`.
- **active = false**: Motion Detected ← false; trigger switch On ← false; if `motionDoorbell` truthy, doorbell reset
  (6.2, active = false). Result `{error: false, message: "Motion switched off."}`.

minimumTimeout is 1 for the Motion Trigger switch and 0 for MQTT and HTTP. So with `motionTimeout: 0`, HTTP/MQTT motion
stays on until an explicit reset, while the switch still resets after 1 s. Because no timer is ever running when
`motionTimeout` is 0, `motionDoorbell` then rings the doorbell on every trigger, and `cooldownActive` is always false.

### 6.2 Doorbell trigger (input: active, default true)

If the camera has no Doorbell service: `{error: true, message: "Doorbell is not enabled for this camera."}`.

Otherwise (debug log): cancel the doorbell timer if any.

- **active = true**: Programmable Switch Event ← Single Press (0) (sent as an event every time, even if the value is
  unchanged). If the Doorbell Trigger switch exists: On ← true, and start a doorbell timer of t seconds, t =
  `motionTimeout` if it is truthy and > 0, else 1; when it fires (debug log), the switch On ← false. Result
  `{error: false, message: "Doorbell switched on."}`.
- **active = false**: Doorbell Trigger switch On ← false (if present). Result `{error: false, message: "Doorbell switched off."}`.

### 6.3 Trigger switches (HomeKit writes)

- Motion Trigger switch, write On = v: motion trigger (6.1) with active = v, minimumTimeout = 1. The write succeeds
  immediately.
- Doorbell Trigger switch, write On = v: doorbell trigger (6.2) with active = v.

Their On value is otherwise driven by the handlers above (no persistence; starts false).

### 6.4 MQTT

- Connection URL: `mqtt://<mqtt>:<port>` or `mqtts://<mqtt>:<port>` when `tlsmqtt`; port = `portmqtt` or 1883. Username
  and password from `usermqtt`/`passmqtt` when given. The client's other settings are MQTT.js defaults: MQTT 3.1.1,
  keep-alive 60 s, clean session, a random client id (`mqttjs_` + 8 hex digits), automatic reconnect every 1 s, TLS
  verifying the broker's certificate against the system roots. Log at info "setting up MQTT" and "MQTT connected".
- On every (re)connect, subscribe (QoS 0) to every distinct topic registered by any camera (debug log per topic).
- Registration (at accessory setup, only when the platform `mqtt` is set and the camera has an `mqtt` block): a table
  topic → exact message string → list of actions, appended in camera order and, per camera, in the order motion,
  motion reset, doorbell. Several cameras can share a topic and be told apart by message; one camera's motion and reset
  can share a topic with different messages.
- On a message: look up the topic, then the payload decoded as UTF-8 text compared **exactly** (no trimming, case
  sensitive) with the registered message. Each matching action runs in order: motion → 6.1 (active, minimumTimeout 0);
  motion reset → 6.1 (inactive); doorbell → 6.2 (active). No match: ignored silently. Errors (e.g. sensor not enabled)
  are ignored silently.
- Retained messages delivered on subscribe trigger like any other.

Vectors (with the full example of 3.5): publish `ON` to `home/camera` → Front Door motion on, auto-reset after 15 s;
publish `OFF` to `home/camera` → motion off; publish `ON` to `home/doorbell` → doorbell Single Press and the Doorbell
Trigger switch on for 15 s. With the camera's `mqtt` block giving only `"motionTopic": "homebridge/motion"`, publishing
the payload `Front Door` to `homebridge/motion` triggers motion.

### 6.5 HTTP

- A plain HTTP/1.1 server on `porthttp`, bound to `localhost` when `localhttp` is truthy (Node resolves `localhost`;
  binding the loopback address(es) is the equivalent), else all interfaces. Info log on start (mentions localhost-only).
  No authentication, no TLS. Any method is accepted (GET is what users use); the body is ignored.
- Request target parsing:
  1. Split the request target on `?`. It must give **exactly two** parts, else "Malformed URL." (so no `?`, or two `?`,
     are malformed).
  2. Camera name = the percent-decoded query (the whole second part, decoded), then cut at the first `=` (the part
     before it). So `?Front%20Door`, `?Front%20Door=` and `?Front%20Door=anything` all name `Front Door`.
  3. Find the accessory whose display name equals the name exactly; none → `Camera "<name>" not found.`
  4. Path segments = the first part split on `/`, empty segments dropped. First segment `motion`: second segment
     exactly `reset` → motion reset (6.1 inactive), anything else or none → motion trigger (6.1 active, minimumTimeout
     0). First segment `doorbell` → doorbell ring (6.2 active; there is no doorbell reset over HTTP). Otherwise:
     `First directory level must be "motion" or "doorbell", got "<seg>".` (with `<seg>` printed as `undefined` when
     there is no segment). Further segments are ignored.
- Response: status **200** when `error` is false, **500** when true; body the JSON object with keys in the order
  `error`, `message`, and `cooldownActive` only for a successful motion trigger. No Content-Type header is set.
- Edge: a query with an invalid percent escape makes the original throw inside the request handler (crashing the
  process); a port should answer 500 "Malformed URL." instead.

Vectors (camera "Front Door", motion and doorbell enabled, motionTimeout 15):

| Request | Status | Body |
|---|---|---|
| `GET /motion?Front%20Door` (no timer running) | 200 | `{"error":false,"message":"Motion switched on.","cooldownActive":false}` |
| same again within 15 s | 200 | `{"error":false,"message":"Motion switched on.","cooldownActive":true}` (timer restarted) |
| `GET /motion/reset?Front%20Door` | 200 | `{"error":false,"message":"Motion switched off."}` |
| `GET /doorbell?Front%20Door` | 200 | `{"error":false,"message":"Doorbell switched on."}` |
| `GET /motion?Back%20Yard` | 500 | `{"error":true,"message":"Camera \"Back Yard\" not found."}` |
| `GET /motion` | 500 | `{"error":true,"message":"Malformed URL."}` |
| `GET /light?Front%20Door` | 500 | `{"error":true,"message":"First directory level must be \"motion\" or \"doorbell\", got \"light\"."}` |
| `GET /?Front%20Door` | 500 | `{"error":true,"message":"First directory level must be \"motion\" or \"doorbell\", got \"undefined\"."}` |
| `GET /doorbell?Front%20Door` on a camera without `doorbell` | 500 | `{"error":true,"message":"Doorbell is not enabled for this camera."}` |

## 7. Snapshots and live streaming (FFmpeg command lines)

### 7.0 How arguments are formed

Every FFmpeg command except the recording and prebuffer ones is built as **one string and split on runs of
whitespace** into argv (no shell, no quoting). Consequences a drop-in must keep: user strings (`source`,
`stillImageSource`, `encoderOptions`, `videoFilter`, `returnAudioTarget`, `mapvideo`, `mapaudio`) are split on spaces
too, so a filter containing a space breaks into several arguments; quote characters are passed to FFmpeg literally (the
scale filter's single quotes below are interpreted by FFmpeg's filter parser, not a shell); and a `source` with a
leading space produces an empty first argument. The environment is the bridge's environment.

Notation: `‹x›` is a substituted value; `[ … ]` an optional part.

### 7.1 Resolution and filter computation

Input: requested width W, height H (from HomeKit), and whether it is for a snapshot.

1. Start with w = W, h = H.
2. Only for streams (not snapshots): if `maxWidth` is defined (not undefined) and (`forceMax` or W > `maxWidth`), w =
   `maxWidth`. Same for height with `maxHeight`.
3. Filters = `videoFilter` split on `,` (empty list when unset). If an element equals `none`, remove the first such
   element and remember "none".
4. snapFilter = the remaining user filters joined by `,` (may be empty).
5. If not "none" and (w > 0 or h > 0):
   resizeFilter = `scale=‹A›:‹B›:force_original_aspect_ratio=decrease` with ‹A› = `'min(‹w›,iw)'` when w > 0 else `iw`,
   ‹B› = `'min(‹h›,ih)'` when h > 0 else `ih` (the single quotes are part of the text).
   Append resizeFilter and then `scale=trunc(iw/2)*2:trunc(ih/2)*2` to the filters.
6. videoFilter (effective) = filters joined by `,` when there is at least one, else none.

### 7.2 Snapshots

On a snapshot request (W×H):

1. Compute 7.1 for the snapshot (no caps).
2. If a snapshot fetch is cached (in flight or finished less than 3 s ago), reuse its result; else start a fetch with
   this request's snapFilter.
3. **Fetch** command:
   `‹videoProcessor›` `‹stillImageSource or source›` `-frames:v 1` [`-filter:v ‹snapFilter›` when non-empty] `-f image2 -`
   `-hide_banner -loglevel error`
   Stdout is collected. On process exit: non-empty output → success; empty → failure "Failed to fetch snapshot.". A spawn
   failure → failure "FFmpeg process creation failed: ‹reason›". The cache entry (success or failure) expires **3 s
   after the process exits**, so requests within that window get the same image or the same error.
   Timing log by runtime r seconds: r < 5 debug; 5 ≤ r < 22 warning; r ≥ 22 error, adding that the request has timed out
   and HomeKit was not refreshed. There is no kill timeout on the snapshot process.
   Stderr lines are logged (at error level, labelled `‹name›] [Snapshot` so they read `[‹name›] [Snapshot] …`) only when
   `debug` is on.
4. **Resize** (always run, on the cached or fresh image):
   `‹videoProcessor› -i pipe: -frames:v 1` [`-filter:v ‹resizeFilter›` when one was computed] `-f image2 -`
   with the image written to stdin. Stdout (possibly empty) is the reply. Only the first scale filter is used here (no
   even-dimension filter), and user filters are not re-applied.
5. Errors are logged at error level and returned to HomeKit as a failure.

Vector: source `-i rtsp://u:p@10.0.0.5:554/s1`, no stillImageSource, no videoFilter, request 640×360:
- fetch argv: `-i`, `rtsp://u:p@10.0.0.5:554/s1`, `-frames:v`, `1`, `-f`, `image2`, `-`, `-hide_banner`, `-loglevel`, `error`
- resize argv: `-i`, `pipe:`, `-frames:v`, `1`, `-filter:v`, `scale='min(640,iw)':'min(360,ih)':force_original_aspect_ratio=decrease`, `-f`, `image2`, `-`

With `"videoFilter": "hflip,none"`: fetch gets `-filter:v hflip`; resize gets no filter.

### 7.3 Prepare stream

On prepare (session id, controller address, IPv4/IPv6, video and audio target ports, SRTP key and salt for each):

- Pick two free UDP ports (on `::` for IPv6 or `0.0.0.0`): video return port and audio return port.
- Generate a video SSRC and an audio SSRC (HAP-NodeJS's synchronisation source generator: a random 32-bit value).
- Remember: address, IP version, video target port, video SRTP = key ‖ salt (16 + 14 = 30 bytes), video SSRC, and the same
  for audio.
- Reply: video port = video return port, SSRC = video SSRC, SRTP key/salt = **the controller's own** key and salt
  echoed back; the same for audio.

### 7.4 Start stream

If no prepared session matches: error log, failure reply.

Values:
- vcodec = `vcodec` or `libx264`; mtu = `packetSize` or 1316 (HomeKit's requested MTU is ignored).
- encoderOptions = `encoderOptions`; if falsy and vcodec is `libx264`: `-preset ultrafast -tune zerolatency`.
- Resolution: 7.1 for the stream with the requested W×H.
- fps = `maxFPS` if defined and (`forceMax` or requested fps > `maxFPS`), else the requested fps.
- bitrate = `maxBitrate` if defined and (`forceMax` or requested max bitrate > `maxBitrate`), else the requested max
  bitrate (kbit/s).
- If vcodec is `copy`: w = h = 0, no video filter, fps = 0, bitrate = 0.
- Logs: requested values at debug; info "starting video stream" with w×h (`native` when 0), fps (`native` when 0),
  bitrate (`???` when 0) and the audio codec when audio is on.

Main FFmpeg argv, in order:

1. `‹source›` tokens.
2. Video output: [`-map ‹mapvideo›`] if mapvideo truthy, else `-an -sn -dn`; then `-codec:v ‹vcodec› -pix_fmt yuv420p
   -color_range mpeg`; [`-r ‹fps›` when fps > 0]; `-f rawvideo`; [‹encoderOptions› tokens]; [`-filter:v ‹videoFilter›`
   when one]; [`-b:v ‹bitrate›k` when bitrate > 0]; `-payload_type ‹video pt›`.
3. Video target: `-ssrc ‹videoSSRC› -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params ‹base64(video key‖salt)›
   srtp://‹address›:‹videoPort›?rtcpport=‹videoPort›&pkt_size=‹mtu›`
   (for IPv6 the address is inserted as is, without brackets).
4. If `audio` is truthy:
   - If the requested audio codec is AAC-ELD or Opus: [`-map ‹mapaudio›`] if truthy, else `-vn -sn -dn`; then for Opus
     `-codec:a libopus -application lowdelay`, for AAC-ELD `-codec:a libfdk_aac -profile:a aac_eld`; then
     `-flags +global_header -f null -ar ‹sample rate in kHz›k -b:a ‹audio max bitrate›k -ac ‹channels› -payload_type ‹audio pt›`
     followed by `-ssrc ‹audioSSRC› -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params ‹base64(audio key‖salt)›
     srtp://‹address›:‹audioPort›?rtcpport=‹audioPort›&pkt_size=188`.
     (The `-f null` is overridden by the later `-f rtp`; keep it for fidelity.)
   - Other codecs: error log "unsupported audio codec", no audio output.
5. `-loglevel level` (or `-loglevel level+verbose` when `debug`) `-progress pipe:1`.

Note that `-hide_banner` is not used for the main stream. The FFmpeg used needs `libfdk_aac` for audio (the Homebridge
bundled FFmpeg has it).

Vector: source `-i rtsp://u:p@10.0.0.5:554/s1`, `maxWidth` 1280, `maxHeight` 720, `maxFPS` 30, audio on; HomeKit asks
1920×1080, 30 fps, 802 kbps, video pt 99, address 192.168.1.20, video port 51000, audio AAC-ELD 16 kHz, 24 kbps, 1
channel, pt 110, audio port 51002; video SSRC 1111, audio SSRC 2222; video key‖salt base64 `VV…` (40 chars), audio `AA…`:

```
-i rtsp://u:p@10.0.0.5:554/s1
-an -sn -dn -codec:v libx264 -pix_fmt yuv420p -color_range mpeg -r 30 -f rawvideo -preset ultrafast -tune zerolatency
-filter:v scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2
-b:v 802k -payload_type 99
-ssrc 1111 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params VV… srtp://192.168.1.20:51000?rtcpport=51000&pkt_size=1316
-vn -sn -dn -codec:a libfdk_aac -profile:a aac_eld -flags +global_header -f null -ar 16k -b:a 24k -ac 1 -payload_type 110
-ssrc 2222 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params AA… srtp://192.168.1.20:51002?rtcpport=51002&pkt_size=188
-loglevel level -progress pipe:1
```
(one argv entry per whitespace-separated token; line breaks here are for reading only). With `"maxBitrate": 299` the
`-b:v` becomes `299k`. With `"vcodec": "copy"`: `-an -sn -dn -codec:v copy -pix_fmt yuv420p -color_range mpeg -f rawvideo
-payload_type 99 …` (no `-r`, no encoder options, no filter, no `-b:v`). With `"maxWidth": 0, "maxHeight": 0` and no
forceMax: no scale filters at all (w = h = 0) unless HomeKit asked 0. With `forceMax` and `maxFPS` 15, a 30 fps request
becomes `-r 15`, and a 10 fps request also becomes `-r 15`.

### 7.5 Stream process supervision

- **Start reply**: the HomeKit start request is answered with success as soon as the FFmpeg process writes its **first
  stderr line** (any line). If the process cannot be spawned: error log, failure reply, the session is stopped.
- **Progress**: stdout carries `-progress` blocks of `key=value` lines. A chunk that begins with `frame=` is parsed
  (keys `frame`, `fps`, `stream_0_0_q`, `bitrate`, `total_size`, `out_time_us`, `out_time`, `dup_frames`,
  `drop_frames`, `speed`, `progress`). The first time frame > 0, log the time to first frames: < 5 s debug, < 22 s
  warning, else error. Progress is used only for this log.
- **Stderr**: with `debug`, lines containing `[panic]`, `[fatal]` or `[error]` are logged at error level, the others at
  debug-promoted-to-info; without `debug`, nothing is logged.
- **Exit**: let "stopping" = the plugin asked it to stop (7.6).
  - stopping and exit code 0 → debug "exited (expected)".
  - exit code null (killed by a signal) or 255: if the plugin killed it (SIGKILL) → debug "(forced)"; otherwise error
    "(unexpected)". Nothing else happens.
  - any other code → error log with code and signal; the session is stopped (7.6); if the start reply has not been sent
    yet and no frame was seen, reply failure; otherwise ask the camera controller to force-stop the streaming session.
- **Inactivity**: a UDP socket (udp4/udp6 matching the session) is bound to the **video return port**. Timeout =
  clamp(rtcp_interval × 5 × 1000 ms, 30 000, 300 000) where rtcp_interval is HomeKit's requested video RTCP interval in
  seconds (HomeKit typically sends 0.5 → 30 s). The timer starts at stream start and is restarted on every datagram
  received on that socket (HomeKit's RTCP). When it fires: info "device appears inactive, stopping", force-stop the
  streaming session in the controller and stop it (7.6). A socket error: error log and stop. Test values: interval 0.5 →
  30 000 ms; 10 → 50 000 ms; 100 → 300 000 ms.
- Reconfigure requests: logged at debug ("ignored"), answered success, nothing changes.
- Stop requests: stop (7.6), answered success.

### 7.6 Stopping a stream

Clear the inactivity timer, close the socket, stop the main process and the two-way process (each error logged at error
level and otherwise ignored), forget the session, log info "stopped video stream" (logged even when the session was
unknown). Stopping a process = write `q` and a newline to its stdin, then SIGKILL it if it is still running 2 s later.

### 7.7 Two-way audio (returnAudioTarget)

When `returnAudioTarget` is truthy, at stream start a second process is spawned with argv:

`-hide_banner -protocol_whitelist pipe,udp,rtp,file,crypto -f sdp -c:a libfdk_aac -i pipe: ‹returnAudioTarget tokens›
-loglevel level` (or `level+verbose` with `debugReturn`)

and this SDP is written to its stdin, which is then closed (CRLF line endings, ‹V› = `IP6` for IPv6 else `IP4`, ‹addr› =
the controller's address, ‹port› = the **audio return port** from 7.3, ‹key› = base64 of the audio SRTP key‖salt):

```
v=0
o=- 0 0 IN ‹V› ‹addr›
s=Talk
c=IN ‹V› ‹addr›
t=0 0
m=audio ‹port› RTP/AVP 110
b=AS:24
a=rtpmap:110 MPEG4-GENERIC/16000/1
a=rtcp-mux
a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00
a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:‹key›
```

(There is a space between the last `;` and `config=`.) This process has no start reply; its stderr is logged as in 7.5
under the label `‹name›] [Two-way` and with `debugReturn`; its exit follows 7.5's rules (a non-0/255 exit stops the whole
session and force-stops it in the controller). A typical target is `-acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts
udp://camera:port` (user-supplied).

## 8. (reserved: no polling)

The plugin polls nothing and discovers nothing. Cameras are reached only by FFmpeg, when HomeKit asks for a snapshot, a
stream or a recording, plus the permanent prebuffer process when enabled. An unreachable camera shows up as failed or
slow snapshots and streams (logged as above); there are no retries.

## 9. HomeKit Secure Video

### 9.1 Recording options (only when `recording` is truthy)

- Prebuffer length: 4000 ms.
- Event trigger options overridden to Motion and Doorbell.
- Media container: one entry, type 0 (fragmented MP4), fragment length 4000 ms.
- Video: H.264, levels 3.1, 3.2, 4.0; profiles Baseline, Main, High; the same 11 resolutions as 4.3.
- Audio codecs: one entry, AAC-LC, bitrate mode 0 (variable), sample rates [32 kHz], 1 channel.

### 9.2 Recording delegate

- Recording active changes: info log only. Recording configuration updates: info log, remember the selected
  configuration (or none).
- Recording stream request (stream id): info log. Without a remembered configuration: error log, end the stream with
  nothing sent. If `prebuffer` is set, make sure the prebuffer is started (failure logged and ignored). Then run the
  recording FFmpeg (9.4) and yield, in order: the **initialisation segment** = all boxes read up to and including the
  first `moov`, concatenated (normally `ftyp` + `moov`); then for each `moof` followed by an `mdat`, one fragment =
  `moof` box ‖ `mdat` box. Other boxes after initialisation are dropped. Every packet is sent with isLast = false. When
  FFmpeg's output ends normally the generator just finishes (no isLast = true packet is sent; the data stream layer
  closes the stream). On an error, one empty packet with isLast = true is sent. Debug logs per fragment (size, totals),
  info at completion (fragment count, bytes).
- Close recording stream (stream id, reason): info log with the reason, and a log line per reason: 0 normal (info);
  1 generic error, 2 network, 3 insufficient resources, 4 HomeKit busy, 5 insufficient buffer space, 6 stream format
  incompatibility (suggesting to check H.264 parameters), 7 maximum recording time exceeded, 8 storage full (warnings);
  other values warning "unknown". Then abort the generator and SIGTERM that stream's FFmpeg.
- Only one recording FFmpeg per camera at a time: starting a new one SIGKILLs the previous one if still alive.
- Shutdown: kill the prebuffer FFmpeg and close its server, SIGTERM all recording FFmpegs.

### 9.3 Prebuffer

When enabled (`recording` and `prebuffer`), started once per camera at setup and again (no-op if running) on each
recording request:

- Open a TCP server on a random port 10000 + round(random × 30000) (retrying on failure), listening on **all
  interfaces** (see Gaps), accepting one connection (the server stops listening after the first).
- FFmpeg argv: `source` split on **single spaces** (not whitespace runs), then `-f mp4 -vcodec copy -movflags
  frag_keyframe+empty_moov+default_base_moof tcp://127.0.0.1:‹port›`. No audio codec option (FFmpeg's mp4 default then
  applies to any audio). Stdio ignored; the full command line is logged at **info** (it contains the source URL with
  credentials — a port should mask it).
- Parse the stream into boxes (9.5). First box is kept as `ftyp`, second as `moov`; every later box is appended to a
  rolling list stamped with its arrival time; boxes older than 15 000 ms are dropped from the front after each arrival.
  Each box is also broadcast to live listeners. The time between successive `mdat`s is tracked (unused).
- For a recording: open another one-shot TCP server on a random port (same rule), which stops accepting after 30 s; the
  recording FFmpeg's input becomes `-f mp4 -i tcp://127.0.0.1:‹port›`. On connection, write `ftyp`, `moov`, then the
  buffered boxes no older than the requested prebuffer duration (= the selected configuration's fragment length,
  default 4000 ms), starting at the first `moof` among them, then every new box live, until the socket ends, closes,
  errors, or the prebuffer is killed (info log "prebuffer request ended").
- No restart if the prebuffer FFmpeg dies.
- Source defect to know: the original keeps the prebuffer session in one process-wide variable, so only the **first**
  camera with prebuffer ever starts one; other cameras' prebuffers stay empty. The drop-in should keep one prebuffer per
  camera.

### 9.4 Recording FFmpeg argv

Values from the selected recording configuration: profile = `high` / `main` / `baseline` (High / Main / anything else),
level = `4.0` / `3.2` / `3.1` (4.0 / 3.2 / anything else), bitrate B (kbit/s), fps F = the selected resolution's frame
rate, audio bitrate A (kbit/s), audio channels C, audio type (AAC-LC → `aac_low`, else `aac_eld`).

argv:

1. `-hide_banner`
2. input: with prebuffer, `-f mp4 -i tcp://127.0.0.1:‹port›`; else the `source` trimmed, split on whitespace, empty
   tokens dropped (no source → error "no video source").
3. only when `videoConfig.audio` is **exactly `false`** (not when absent): `-f lavfi -i anullsrc=cl=mono:r=32000`
4. `-f mp4`
5. `-acodec aac -profile:a ‹aac_low|aac_eld› -ar 32000 -b:a ‹A›k -ac ‹C› -sn -dn -vcodec libx264 -pix_fmt yuv420p
   -profile:v ‹profile› -level:v ‹level› -preset veryfast -tune zerolatency -b:v ‹B›k -maxrate ‹floor(B × 1.2)›k
   -bufsize ‹B × 2›k -g 30 -keyint_min 15 -sc_threshold 0 -force_key_frames expr:gte(t,n_forced*1) -r ‹F›`
6. `-movflags frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset pipe:1`

Notes: no `-map` (FFmpeg picks the streams); no scaling to the selected resolution (only its frame rate is used);
`vcodec`, `videoFilter`, `encoderOptions`, `mapvideo`/`mapaudio` and the `max*` caps are not applied to recordings
(the executable is still `videoProcessor`). Stderr chunks containing `error` or `Error` are logged at error level; a non-zero
exit other than 255 that the plugin did not cause is a warning.

Vector: no prebuffer, `audio` absent, source `-i rtsp://u:p@10.0.0.5:554/s1`, configuration High / 4.0 / 2000 kbps /
1920×1080@30, AAC-LC 32 kHz 64 kbps 1 channel:

```
-hide_banner -i rtsp://u:p@10.0.0.5:554/s1 -f mp4
-acodec aac -profile:a aac_low -ar 32000 -b:a 64k -ac 1 -sn -dn -vcodec libx264 -pix_fmt yuv420p -profile:v high -level:v 4.0
-preset veryfast -tune zerolatency -b:v 2000k -maxrate 2400k -bufsize 4000k -g 30 -keyint_min 15 -sc_threshold 0
-force_key_frames expr:gte(t,n_forced*1) -r 30 -movflags frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset pipe:1
```
With `"audio": false`: `-hide_banner -i rtsp://… -f lavfi -i anullsrc=cl=mono:r=32000 -f mp4 -acodec aac …`. With
B = 333: `-maxrate 399k -bufsize 666k`.

### 9.5 MP4 box framing

Each box: 4-byte **big-endian signed** size (including the 8-byte header), 4-byte ASCII type, then size − 8 bytes of
payload. The 64-bit "largesize" form (size = 1) and size = 0 are not supported. For recordings, a payload length < 0 or
> 50 MiB (52 428 800) is an error. End of stream while reading a box ends the parse (an error unless the plugin killed
the process). Fixture: the bytes `00 00 00 10 66 74 79 70` + 8 payload bytes are one `ftyp` box of length 8.

## 10. Logging

Every plugin message is prefixed `[‹camera name›] ` when it concerns a camera. "Debug" messages are emitted at debug
level when Homebridge runs in debug mode; otherwise they are dropped, except messages for a camera whose `debug` is on,
which are then emitted at **info** (the FFmpeg command lines, snapshot and stream timings, requested sizes, FFmpeg stderr).

Paraphrased messages by level:

- **error**: camera without name (renamed `Camera N`); missing `videoConfig`; missing `source`; snapshot failure; slow
  snapshot ≥ 22 s or first frames ≥ 22 s; FFmpeg spawn failure; FFmpeg unexpected or error exit (with code and signal);
  unsupported audio codec; unknown session at stream start; socket errors; errors stopping processes; with `debug`,
  FFmpeg stderr lines tagged panic/fatal/error and every snapshot stderr line; recording: no configuration, prebuffer
  start failure, FFmpeg session failure, recording stream errors, FFmpeg stderr containing "error".
- **warn**: source or still source without `-i`; filter with `copy`; duplicate camera names; slow snapshot or first
  frames between 5 and 22 s; HKSV close reasons 1–8 and unknown; recording FFmpeg non-zero exit.
- **info**: configuring cached / new accessories, removing stale ones; identify requests; MQTT setting up and connected;
  HTTP server starting (port, localhost-only); "starting video stream" with the effective parameters; "stopped video
  stream"; inactivity stop; recording active changed, configuration updated, stream requested, completed, closed with
  reason; prebuffer start and the full prebuffer command line; "prebuffer request ended".
- **debug**: motion/doorbell on/off and their timer expiries; MQTT subscriptions; snapshot and stream commands; snapshot
  request size and "sending snapshot … (cached)"; requested stream parameters; reconfigure ignored; stream timeout
  value; FFmpeg exits expected/forced; HKSV fragment sizes; recording on/off and prebuffer on/off at construction.

**Secrets**: `passmqtt` (and `usermqtt`); `source`, `stillImageSource`, `returnAudioTarget` (camera credentials in
URLs); the SRTP keys and salts (in the stream argv, the SDP). The original logs whole command lines (debug, or info with
`debug`, and always info for the prebuffer), which include source credentials and SRTP keys; Homeswift's rule says never
log keys or tokens, so a port must mask these.

## 11. Companion UI (homebridge-ui custom page)

A small custom page inside Homebridge Config UI X:

- Header: the Homebridge logo.
- First use (no config block yet): adds an empty block `{ "name": "Camera-ffmpeg" }` to the plugin config and shows a
  "thank you for installing" intro with a Continue button that leads to the settings.
- Three tabs: **Settings** (the standard form generated from the schema, with the layout: Cameras as a tab array titled
  by camera name with sections Branding, Video Output, Advanced (containing an "EXPERIMENTAL" section for two-way audio,
  `debugReturn`, `recording`, `prebuffer`), and Automation (motion/doorbell/switches/timeout/motionDoorbell and an MQTT
  Settings section); then Global Automation with HTTP Server and MQTT Client sections; then Global Advanced with
  `videoProcessor`), **Devices** and **Support**.
- Devices: a drop-down of this plugin's cached accessories sorted by name (from the host's cached-accessories API, or a
  plugin-side request `/getCachedAccessories` that reads the host's `accessories/cachedAccessories` file and returns the
  entries whose `plugin` is this package; any error returns an empty list); selecting one shows a table of display name,
  serial number, model and firmware revision read from the accessory's `context` (which this plugin never fills, so they
  show empty / "N/A"; and external cameras are not cached, so the list is normally "No Devices").
- Support: links to the project wiki, changelog, issue form and the author's page.
- A banner when the plugin is disabled, with an Enable button that clears `disablePlugin` and saves the config.

This page carries no camera functionality; for Homeswift the plugin's schema-driven settings are enough.

## 12. Gaps and hard parts

- **Licence ambiguity** (Apache-2.0 file without holder vs ISC in package.json): record both in THIRD-PARTY-NOTICES.
- **Category**: the original sets none (Homebridge default Other). The Home app still shows a camera because of the RTP
  services. A port may advertise Camera (17), or Video Doorbell (18) when `doorbell` is on; it only affects the pairing
  sheet's icon, not ids.
- **Doorbell model**: the original uses a plain camera controller plus a separately added Doorbell service (not a
  doorbell controller); keep the Doorbell service's type and empty subtype for stable ids.
- **HAP-NodeJS controller internals** (exact services, subtypes and characteristics of RTP stream management,
  recording management, operating mode, data stream, the SSRC generator, the selected-configuration TLVs) are
  HAP-NodeJS's, not this plugin's; Homeswift's `CameraController`/`RecordingManagement` ports already define them.
- **Whitespace splitting** of option strings (7.0) is load-bearing for compatibility (users write multi-option
  strings) but breaks values with spaces; the prebuffer uses single-space splitting, the recording path trims and drops
  empties.
- **Start reply on first stderr line**: HomeKit is told the stream started before any frame is sent; a port that waits
  for real frames may change timing behaviour.
- **SRTP via FFmpeg**: the stream is encrypted by FFmpeg itself (`-srtp_out_*`); the plugin never touches RTP packets.
  The return socket only counts RTCP for the inactivity timeout.
- **Two-way audio** depends on FFmpeg reading SRTP from an SDP with `a=crypto` and on `libfdk_aac`; it is marked
  experimental upstream and untested here.
- **HKSV**: no isLast packet at normal end; no scaling to the selected resolution; only the first camera's prebuffer
  works (bug); prebuffer TCP servers listen on all interfaces (the original binds no host), which exposes the camera
  stream on the LAN for up to 30 s — a port should bind 127.0.0.1; prebuffer FFmpeg is not restarted when it dies.
- **Shutdown** does not stop live streams in the original (bug); a port should.
- **HTTP**: invalid percent escapes crash the original; no auth; Node's `localhost` resolution (IPv4 and/or IPv6) is not
  specified exactly.
- **MQTT** client defaults (client id, keep-alive, reconnect) come from MQTT.js, not from this plugin's code; any
  reasonable equivalent works. TLS options beyond defaults (CA, client certs, insecure) are not configurable.
- **Snapshot cache key**: the cache ignores the requested size and filter: a second request within the window reuses the
  first fetch's image (and the first request's snapFilter), then resizes it for its own size.
- Could not determine without running Homebridge: the exact external-accessory username/port assignment and whether the
  category is overridden by the host for camera accessories.
