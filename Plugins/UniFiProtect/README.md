# UniFi Protect

UniFi Protect controllers in HomeKit: cameras and doorbells with live video, snapshots, two-way audio and
HomeKit Secure Video; motion, smart detection, occupancy, tamper and ambient light sensors; doorbell rings,
messages and chimes; floodlights, UP Sense sensors, viewports and chimes; liveviews as a security system;
MQTT publishing and an M3U playlist of the cameras.

A port of [`homebridge-unifi-protect`](https://github.com/hjdhjd/homebridge-unifi-protect) (the
`@mp-consulting` fork), Copyright (c) 2017-2026 HJD, under the ISC license; its notice is in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md). The platform name is the same (`"platform": "UniFi Protect"`), and
a Homebridge block loads unchanged, `controllers` and the `options` array of feature options included; what the bridge
writes is the canonical shape ([Settings](#settings)).

## Settings

Controllers come through Setup ([below](#setup)); the rest is on the plugin's Settings page
(`/plugins/unifi-protect/settings`) and each device's Settings sheet, or `get_settings` and `update_settings` over MCP.

```json
{
  "platform": "UniFi Protect",
  "name": "UniFi Protect",
  "videoTranscode": false,
  "_accessories": {
    "001122334455": { "address": "192.168.1.1", "mqttUrl": "mqtt://broker.local", "nvrSystemInfo": true },
    "F4E2C6000001": { "videoTranscodeBitrate": 3000, "parts": { "Motion.OccupancySensor": true } },
    "F23E23931F5C": { "rtspUrl": "rtsp://viewer:pass@192.168.2.100:8555/guest" }
  }
}
```

Create a local user on the controller for Homeswift; give it the Full Management (admin) role so the plugin
can turn on RTSP streams and change device settings. Its login, and the M3U playlist's token, are kept in the vault.

| Plugin Setting | Default | What it does |
|---|---|---|
| `name` | `UniFi Protect` | The name in the log |
| `controllers` | | Consoles by address, for those discovery does not find (`address`, and optionally the controller settings below); each is signed in to through Setup |
| `ringDelay` | `0` | Seconds during which further rings of a doorbell are ignored |
| `verboseFfmpeg` | `false` | FFmpeg logs more for each stream |
| `videoProcessor` | `ffmpeg` on the path | The FFmpeg to run |
| `debug` | `false` | Debug lines at the info level |
| one per feature option | the option's | The plugin-wide default of each device's setting of the same name (below) |

Each device has its Accessory Settings in `_accessories`, by its MAC (as Protect writes it: `F4E2C6000001`), of its
Device Kind: the controller (`nvr`, its NVR's MAC), `camera`, `thirdPartyCamera` (an ONVIF or other camera adopted in
Protect), `light`, `sensor`, `chime`, `viewer`.

| A controller's setting | What it does |
|---|---|
| `address` | The controller's address |
| `verifyTls` | Check the controller's certificate against the system's roots; otherwise the certificate seen first is pinned (`unifi-protect-tls-pins.json`) and a different one is refused |
| `overrideAddress` | The address of RTSP URLs, for VPN and remote setups |
| `doorbellMessages` | Extra messages for doorbells with a screen: `message`, `duration` in seconds (`0` keeps it) |
| `mqttUrl`, `mqttTopic`, `mqttVerifyTls` | Publish events to an MQTT broker under `mqttTopic` (`unifi/protect`) and take commands there |
| `playlistAddress` | Where the M3U playlist (`nvrServicePlaylist`) listens (every interface, IPv4 and IPv6, when unset); its `?token=` is in the vault |

| A third-party camera's setting | What it does |
|---|---|
| `rtspUrl`, `snapshotUrl` | Its own URLs, bypassing the controller; the page's **Find a camera's URLs** asks the camera for them over ONVIF |
| `onvifPort`, `onvifUsername`, `onvifServicePath` | Where its ONVIF service answers, kept from a Homebridge block's override; an ONVIF password goes into the camera's credentials in the vault |

### One setting per feature option

Every feature option of the Homebridge plugin is a setting named after it (`Video.Transcode.Bitrate` is
`videoTranscodeBitrate`, `Motion.Duration` `motionDuration`, `Doorbell.Messages` `doorbellMessagesEnabled`), titled
with the option's name, for the Device Kinds whose models the option is for; an option with a value is a number (or,
`Motion.SmartDetect.ObjectSensors.LicensePlate`, text). A device's own setting overrules the Plugin Setting of the same
name. The options a device offers as Parts on Add accessories and in its Settings (an occupancy sensor, a motion
detection switch, a status light switch, a night vision dimmer, a recording switch, a doorbell's mute switch, chime
switches, fingerprint sensor or package camera flashlight) are its `parts` (`{ "Motion.OccupancySensor": true }`), the
Plugin Setting their default. The categories are those of the Homebridge plugin: Audio, Device, Doorbell, Logging,
Motion, NVR, Security System, Sensor, UniFi Access, Video and HomeKit Secure Video.

### A Homebridge block

A block with `controllers[].username`, `password`, `playlistToken` and `cameraOverrides`, and an `options` array of
feature options (`Enable.<Option>` or `Disable.<Option>`, scoped to a controller, `.<controller MAC or address>`, or a
device, `.<device MAC>`, and for options with a value followed by it: `Enable.Video.Transcode.Bitrate.F4E2C6000001.3000`)
runs as it did. At the next settings change the bridge writes it in the canonical shape: a running controller's entry
moves into its Accessory Settings, its login and playlist token into the vault, each camera override into that camera's
settings; an option scoped to a device becomes that device's setting (`Disable.Device.<MAC>` Excluded, a Part its
`parts`), one without a scope the Plugin Setting, one scoped to a controller each of its devices' (an NVR option the
controller's own). What no setting says (an option with a value turned off, a global `Disable.Device`, an option of a
device the controller does not have now) stays in `options`, read after the settings.

### MQTT

With `mqttUrl`, every device publishes under `<mqttTopic>/<MAC>/`: `motion`, `doorbell`, `snapshot` (a JPEG
data URL), `telemetry` and the rest of the Homebridge plugin's topics, and answers `.../get` and `.../set`
topics (`snapshot/set` takes a snapshot, `message/set` writes a doorbell message, `liveview/set` arms the
security system...).

## Setup

The **Add accessories** page lists each controller as a device, by its MAC: the running ones, those of `controllers`,
and the UniFi consoles discovery finds on the network. A console not set up asks for an **Account Login**, a local
account of the console that can use UniFi Protect; the login is checked before it is kept, in the vault under the
controller's MAC, and its address goes in its Accessory Settings. The controller's cameras, lights, sensors, chimes and
viewers need nothing more. A `Disable.Device.<MAC>` in `options` shows as left out by the plugin's own settings.

Only consoles that run UniFi Protect are listed (asked without signing in, one without it answers with its web page).
Once one is signed in, its devices are offered to pick, and each camera, light or sensor lists its parts, what it can
add to the Home app or leave out (an occupancy sensor, a motion detection switch, a status light switch, a doorbell's
mute switch or package camera flashlight, as the device supports them): a part switched there is that device's feature
option (`Enable.Motion.OccupancySensor.<MAC>`), kept in its Accessory Settings' `parts`.

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin: each controller the plugin runs, whether it
answers, its events and certificate, and its devices, each with a **Settings** button for its Accessory Settings;
the plugin's own Settings are beside Pause, a card leads to Add accessories for another controller, and
**Find a camera's URLs** asks a third-party camera for its RTSP and snapshot URLs over ONVIF (with a snapshot of each
profile), to put in the camera's Settings. The page writes no settings. The Assistant (the web UI's chat, MCP clients)
can read the running controllers and their devices, discover consoles and check an address (`AssistantActions.swift`);
the ONVIF lookup, which takes a password, stays the page's. `Web/` holds the page; `Sources/WebFiles.swift` is generated
from it (`swift Scripts/embed-assets.swift web Plugins/UniFiProtect/Web Plugins/UniFiProtect/Sources/WebFiles.swift
UniFiProtectPlugin`).

## How it works

The plugin logs in to each controller, reads its bootstrap and follows the events WebSocket (its binary
packets: an action and a zlib-compressed payload), refreshing the bootstrap every two minutes. Each device
becomes an accessory with the id `UniFi Protect:<MAC>`; package cameras are `UniFi Protect:<MAC>.PackageCamera`.

Video goes through FFmpeg, which the plugin checks at launch (no FFmpeg, no controllers):

- **Live streams** read the camera's RTSPS stream, or, while HomeKit Secure Video records, the controller's
  livestream API (fMP4 over a WebSocket) through the timeshift buffer, which starts streams at once. Streams are
  transcoded by default (`Video.Transcode`), copied otherwise, and always for cellular clients
  (`Video.Transcode.HighLatency`).
- **Audio** is AAC-ELD with an FFmpeg that has libfdk_aac (or `aac_at` on macOS), as in the Homebridge plugin, and
  Opus with one that has libopus instead, such as the container image's
  [ffmpeg-for-homeswift](../../FFmpeg/README.md): live streams, and two-way audio, which reaches the camera as
  FFmpeg's own AAC. Recordings are AAC-LC either way.
- **Snapshots** come from the timeshift buffer, the RTSP stream, then the controller's snapshot API, with a
  recent image as the last resort; identical requests share one FFmpeg.
- **Third-party cameras** with URLs of their own (`rtspUrl`, `snapshotUrl`; a Homebridge block's `cameraOverrides`) are reached directly: snapshots from the
  snapshot URL, else a frame of the RTSP stream; live streams from the RTSP stream; and in the web UI a live
  view that FFmpeg remuxes from the RTSP stream to fragmented MP4 (video only, not transcoded, one FFmpeg per
  viewer).
- **The web UI's live view** of a Protect camera reads the livestream API's fMP4 of its lowest channel, sharing the
  session with HomeKit's streams and the timeshift buffer.
- **HomeKit Secure Video** keeps the last ten seconds of the livestream API in memory and hands an event's
  video, from before the motion, to FFmpeg, which makes HomeKit's fMP4 fragments.
- **Two-way audio** decodes HomeKit's microphone and sends it to the camera through the controller's talkback
  WebSocket (or straight to the camera with `Audio.TwoWay.Direct`).

The camera code uses Homeswift's `CameraController` and its delegates directly, and FFmpeg through small
protocols (CameraSupport.swift) that HomeswiftCameraKit.swift fills with the HomeswiftFFmpeg library. Tests drive
the same code with the real controller and FFmpeg in memory.

## Differences from the Homebridge plugin

- Controller-scoped feature options also accept the controller's configured address as the scope, as the
  Homebridge settings page writes it.
- Feature options are settings (Plugin Settings and each device's Accessory Settings), edited on the Settings pages;
  there is no controller scope between the two, so the bridge writes a controller's options as each of its devices'.
- A controller's login and playlist token, and a camera's ONVIF password, are kept in the vault, not in config.json.
- HomeKit categories are set for every accessory.
- Liveview switches and the security system are cleaned up for this controller only, and a removed doorbell
  message switch really goes away.
- A third-party camera with an RTSP or snapshot URL override gets snapshots and live streams even when Protect
  reports it disconnected (Protect often does for such cameras, and the Homebridge plugin then gives no picture);
  its RTSP URL is grabbed for snapshots even without `Video.HighResSnapshots`, and a transcoded stream uses it at any
  size rather than failing when the host's pixel limit leaves no channel.
- Credentials in a snapshot URL override (`http://user:password@camera/...`) go as Basic authentication, as in the
  Homebridge plugin, and also as Digest when the camera answers with a Digest challenge (the Homebridge plugin
  stops at the 401).
- Feature option numbers, configuration numbers and controller or MQTT values that do not fit (`1e300`) are clamped
  rather than taken as is; duration options stop at a year, `ringDelay` at a day.
- Setup's sign-in to a controller uses the certificate the running plugin pinned for its address.
