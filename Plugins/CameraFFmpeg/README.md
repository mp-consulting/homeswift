# FFmpeg Cameras

Any camera FFmpeg can read (RTSP, HTTP, MJPEG, a file…) in HomeKit: snapshots and live video through FFmpeg, audio,
two-way audio, HomeKit Secure Video with an optional prebuffer, and a motion sensor, a doorbell and trigger switches
driven by MQTT messages or a small HTTP API. Each camera is an accessory of its own, on a HAP server of its own, which
the Home app adds with the bridge's setup code (the banner and the Status page list it with the bridges).

It reads the `Camera-ffmpeg` block of homebridge-camera-ffmpeg as it is, so a Homebridge configuration works unchanged.

**Maintainer:** Mickael Palma. **Status:** experimental: written from a functional specification and tested with fakes
(below), not yet on a real camera.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "Camera-ffmpeg",
      "name": "FFmpeg Cameras",
      "cameras": [
        { "name": "Front Door", "videoConfig": { "source": "-i rtsp://user:password@192.168.1.20:554/stream1" } }
      ]
    }
  ]
}
```

The web UI's **Settings** page of the plugin edits every option, each explained there in four languages; MCP's
`get_settings` and `update_settings` do the same. The plugin options:

| Option | Default | What it does |
|---|---|---|
| `videoProcessor` | `ffmpeg` | The FFmpeg executable, a path or a name in `PATH`. HomeKit's AAC-ELD audio uses `libfdk_aac`, or macOS's AudioToolbox (`aac_at`) when FFmpeg has no `libfdk_aac` (Homebrew's has none) |
| `mqtt` | none | The MQTT broker's host; MQTT is off without it |
| `portmqtt` | `1883` | The broker's port |
| `tlsmqtt` | `false` | TLS (`mqtts`), the broker's certificate checked against the system's roots |
| `usermqtt` | none | The broker's user name. Its password is given on **Add accessories** (the account's sign-in) and kept in the bridge's vault; a Homebridge block's `passmqtt` is read, and moves into the vault at the next settings write |
| `porthttp` | none | The HTTP API's port (a number or a numeric string); off without it |
| `localhttp` | `false` | The HTTP API listens on the loopback addresses only |
| `cameras` | `[]` | The cameras |

A camera's options: `name` (its identity: renaming a camera makes a new accessory), `manufacturer`, `model`,
`serialNumber`, `firmwareRevision`, `motion`, `doorbell`, `switches` (trigger switches for the motion sensor and the
doorbell), `motionTimeout` (seconds, `1` by default, `0` keeps motion until it is reset over MQTT or HTTP),
`motionDoorbell` (motion rings the doorbell too), `videoConfig` and `mqtt` (below).

`videoConfig`: `source` (FFmpeg's input options, `-i` and what comes before it), `stillImageSource` (the same for
snapshots), `returnAudioTarget` (FFmpeg's output options for two-way audio, experimental), `maxStreams` (`2`),
`maxWidth`, `maxHeight`, `maxFPS`, `maxBitrate` (caps on what HomeKit asks; `0` keeps the source's), `forceMax` (the
caps even when HomeKit asks for less), `vcodec` (`libx264`; `copy` sends the source as it is), `packetSize` (`1316`),
`videoFilter` (filters before the scaling ones; a `none` among them leaves the scaling out), `encoderOptions`
(`-preset ultrafast -tune zerolatency` with `libx264`), `mapvideo`, `mapaudio`, `audio`, `debug`, `debugReturn`,
`recording` (HomeKit Secure Video) and `prebuffer` (with `recording`: FFmpeg keeps the last 15 seconds ready, so a
recording starts before its event).

Option strings are split on spaces, as the original does: a value cannot hold a space, and several options go in one
string (`"encoderOptions": "-preset veryfast -tune zerolatency"`).

### Motion and doorbell over MQTT

With `mqtt` set, a camera's `mqtt` block names topics: `motionTopic`, `motionResetTopic` and `doorbellTopic`, each with
the exact message that triggers it (`motionMessage`, `motionResetMessage`, `doorbellMessage`; the camera's name when
empty). Several cameras can share a topic with different messages. A motion trigger switches the motion sensor on for
`motionTimeout` seconds; a doorbell message rings the doorbell.

### Motion and doorbell over HTTP

With `porthttp` set, a plain HTTP server (no authentication, no TLS: keep `localhttp` on unless the network is
trusted) answers:

| Request | Does |
|---|---|
| `GET /motion?Front%20Door` | Motion on; `cooldownActive` says whether it already was |
| `GET /motion/reset?Front%20Door` | Motion off |
| `GET /doorbell?Front%20Door` | Rings the doorbell |

The answer is JSON (`{"error":false,"message":"Motion switched on.","cooldownActive":false}`), status 200, or 500 with
the error (`Camera "Back Yard" not found.`, `Malformed URL.`).

## In HomeKit

Each camera is an accessory (a camera, or a video doorbell with `doorbell`) with `maxStreams` Camera RTP Stream
Management services, a Microphone, a Speaker with `returnAudioTarget`, the recording services with `recording`, and,
as configured, a Motion Sensor, a Doorbell and the switches `<name> Motion Trigger` and `<name> Doorbell Trigger`.
Its Device Id is its name: the accessory id is `Camera-ffmpeg:<name>`, and its Accessory Settings sit in the block's
`_accessories` under its name: `motion`, `doorbell`, `switches`, `motionTimeout` and `motionDoorbell` are its Accessory Settings (a
Homebridge block's are read from its `cameras` entry, and move there at the next settings write). An Excluded camera is not
published, and FFmpeg never reads it.

Setup asks nothing of a camera: its credentials are in its `source`. The account is the MQTT broker's sign-in (a user name
and a password, both optional). The Add accessories page lists the cameras of the block.

## Differences from homebridge-camera-ffmpeg

- Passwords in URLs and SRTP keys are masked in every log line (the original logged whole command lines; the plugin's own
  lines hide the user name too).
- The prebuffer runs for every camera that asks (the original only ever ran the first one's), and reaches the recording
  through pipes: nothing listens on the network for it (the original's TCP servers listened on every interface).
- Stopping the plugin stops every live stream and FFmpeg process.
- A malformed HTTP request (an invalid percent escape) gets `500 Malformed URL.` rather than crashing the bridge.
- Empty tokens of an option string (a leading space in `source`) are dropped instead of being passed to FFmpeg.
- The snapshot FFmpeg is stopped after a minute; HomeKit has given up by then.
- Recordings are scaled down to the size HomeKit selected (the original sent the source's size), and an IPv6
  controller's address is written in brackets in FFmpeg's `srtp://` URLs.
- Without `libfdk_aac`, AAC-ELD goes through macOS's AudioToolbox (`aac_at`) both ways; the original had no audio then.
- The web UI's camera cards get live video: FFmpeg copies the source into fragmented MP4 while a card is on screen.
- The MQTT client reconnects with a back-off up to a minute, rather than every second.
- The accessory's category is Camera (Video Doorbell with `doorbell`), for the pairing sheet's icon; the original set none.
- Homebridge's bundled FFmpeg (`ffmpeg-for-homebridge`) is not looked for: without `videoProcessor`, `ffmpeg` comes from
  `PATH`.

## Gaps

- Not yet run against a real camera: the UniFi Protect feeds tried for this port were out of FFmpeg's reach on the test
  Mac, where macOS's Local Network privacy refused Homebrew's FFmpeg ("No route to host") while curl reached the NVR.
  The plugin's FFmpeg paths were run with real FFmpeg on camera-like H.264 sources instead (below).
- Credentials inside `source`, `stillImageSource` and `returnAudioTarget` are stored as written: those keys are not
  secret-named, so the bridge neither seals them nor resolves `vault:` references in them. A token in a URL's path
  (UniFi Protect's RTSPS) is not masked in the log either: the plugin cannot tell it from a path.
- Two-way audio is experimental, as upstream: it needs a camera that takes audio at an FFmpeg output (`returnAudioTarget`).
- The web UI's live view copies the source's video: an MJPEG camera keeps its snapshots there.

## How it was tested

`swift test --filter CameraFFmpegTests`: the configuration (the spec's example blocks, truthiness), the identity
vectors, every FFmpeg command line against the spec's vectors, the MP4 box framing, the motion and doorbell triggers
and their timers, the MQTT routes on a fake broker, the HTTP API's vectors and its server on the loopback, and, with a
shell script standing in for FFmpeg, snapshots and their cache, stream start, stop and inactivity, the live view, and a recording cut
into fragments. Then a throwaway bridge with `check-on-bridge.sh`.

With real FFmpeg (9.0.2, Homebrew, no `libfdk_aac`), `RealFeedTests` runs the plugin's delegates on each feed of a file
given by `CAMERA_FFMPEG_FEEDS` (skipped otherwise; it prints no URL): on looped H.264 1080p with AAC and 7680×2160
sources, the snapshot came back as a 1280×720 JPEG (1280×360 from the 7680×2160 one, its aspect kept) in under 0.4 s;
a 1280×720 stream started on FFmpeg's first line in 0.04 s and sent SRTP for 20 s at about 870 kbit/s of video (802
asked) and 32 kbit/s of AAC-ELD through AudioToolbox; and a HomeKit Secure Video recording from the prebuffer gave its
initialization segment and 4 fragments of about 260 KB in under 2 s, the 7680×2160 source scaled to 1920×1080.

## Clean-room implementation

Compatible with the configuration of [homebridge-camera-ffmpeg](https://github.com/homebridge-plugins/homebridge-camera-ffmpeg)
by Khaos Tian, Sunoo and the Homebridge contributors (Apache-2.0 in its `LICENSE`, ISC in its `package.json`). This
plugin was written from the functional specification in
[docs/clean-room/CameraFFmpeg.md](../../docs/clean-room/CameraFFmpeg.md), without reading or copying its code.
