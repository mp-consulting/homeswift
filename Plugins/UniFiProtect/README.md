# UniFi Protect

UniFi Protect controllers in HomeKit: cameras and doorbells with live video, snapshots, two-way audio and
HomeKit Secure Video; motion, smart detection, occupancy, tamper and ambient light sensors; doorbell rings,
messages and chimes; floodlights, UP Sense sensors, viewports and chimes; liveviews as a security system;
MQTT publishing and an M3U playlist of the cameras.

A port of [`homebridge-unifi-protect`](https://github.com/hjdhjd/homebridge-unifi-protect) (the
`@mp-consulting` fork). The platform block is the same (`"platform": "UniFi Protect"`), and so are the
feature options, so a Homebridge configuration works unchanged.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "UniFi Protect",
      "name": "UniFi Protect",
      "controllers": [
        { "address": "192.168.1.1", "username": "homeswift", "password": "secret" }
      ]
    }
  ]
}
```

Create a local user on the controller for Homeswift; give it the Full Management (admin) role so the plugin
can turn on RTSP streams and change device settings.

| Option | Default | What it does |
|---|---|---|
| `name` | `UniFi Protect` | The name in the log |
| `controllers` | | The Protect controllers, see below |
| `options` | `[]` | Feature options, see below |
| `ringDelay` | `0` | Seconds during which further rings of a doorbell are ignored |
| `verboseFfmpeg` | `false` | FFmpeg logs more for each stream |
| `videoProcessor` | `ffmpeg` on the path | The FFmpeg to run |
| `debug` | `false` | Debug lines at the info level |

Per controller:

| Option | What it does |
|---|---|
| `address`, `username`, `password` | The controller and its local user |
| `name` | The controller's name in the log, instead of the one it reports |
| `verifyTls` | Check the controller's certificate against the system's roots; otherwise the certificate seen first is pinned (`unifi-protect-tls-pins.json`) and a different one is refused |
| `overrideAddress` | The address of RTSP URLs, for VPN and remote setups |
| `doorbellMessages` | Extra messages for doorbells with a screen: `message`, `duration` in seconds (`0` keeps it) |
| `mqttUrl`, `mqttTopic`, `mqttVerifyTls` | Publish events to an MQTT broker under `mqttTopic` (`unifi/protect`) and take commands there |
| `cameraOverrides` | Per third-party camera (`mac`): its own `rtspUrl` and `snapshotUrl`, bypassing the controller; `onvif*` fields are remembered by the page's ONVIF discovery |
| `playlistAddress`, `playlistToken` | Where the M3U playlist (`Nvr.Service.Playlist`) listens (every interface, IPv4 and IPv6, when unset), and the `?token=` it requires |

### Feature options

Each option is `Enable.<Option>` or `Disable.<Option>`, scoped to everything, to a controller
(`.<controller MAC or address>`) or to a device (`.<device MAC>`); options with a value take it after the
scope (`Enable.Video.Transcode.Bitrate.F4E2C6000001.3000`). The categories are those of the Homebridge plugin:
Audio, Device, Doorbell, Logging, Motion, NVR, Security System, Sensor, UniFi Access, Video and HomeKit Secure
Video; the web page lists every option with its default and lets you set them per controller and device.

```json
"options": [
  "Disable.Video.Transcode",
  "Enable.Video.HKSV.Record.Only.High.F4E2C6000001",
  "Enable.Nvr.Service.Playlist.192.168.1.1"
]
```

### MQTT

With `mqttUrl`, every device publishes under `<mqttTopic>/<MAC>/`: `motion`, `doorbell`, `snapshot` (a JPEG
data URL), `telemetry` and the rest of the Homebridge plugin's topics, and answers `.../get` and `.../set`
topics (`snapshot/set` takes a snapshot, `message/set` writes a doorbell message, `liveview/set` arms the
security system...).

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin: the Homebridge plugin's settings
page. It finds consoles on the network, checks an address and the credentials before saving, lists a
controller's devices, edits the feature options with their scopes, sets up third-party cameras (ONVIF
discovery of their RTSP and snapshot URLs, a snapshot preview), and saves the block. The Assistant (the web UI's
chat, MCP clients) can read the running controllers and their devices, the feature option catalog, discover
consoles and check an address (`AssistantActions.swift`); the routes that take a password stay the page's. `Web/` holds the page;
`Sources/WebFiles.swift` is generated from it (`swift Scripts/embed-assets.swift web Plugins/UniFiProtect/Web
Plugins/UniFiProtect/Sources/WebFiles.swift UniFiProtectPlugin`).

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
- **Third-party cameras** with URLs of their own (`cameraOverrides`) are reached directly: snapshots from the
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
- Saving the web page writes the block at once (its **Save** button) rather than through Homebridge's own
  save.
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
- The settings page's device listing uses the certificate the running plugin pinned for that controller, and the
  saved password when the page sends none.
