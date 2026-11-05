# TP-Link Tapo

Puts TP-Link Tapo plugs, bulbs and battery cameras in HomeKit, reached on the local network, signed in with the Tapo
account's email and password. A plug or a bulb is listed by its address, a camera found in the account's cloud
([Battery cameras](#battery-cameras)); the plugin asks a plug or a bulb for its state every
few seconds and sends HomeKit's changes to it, and reaches a camera only while someone watches it
([Battery cameras](#battery-cameras)).

**Status: experimental.** Nobody has run it against a real Tapo device yet: it is tested against a fake device that
speaks the protocols as the [functional spec](../../docs/clean-room/Tapo.md) describes them (see [Tests](#tests)).
Please report what works on yours.

**Maintainer:** Mickael Palma.

## In HomeKit

| `type` | Devices | HomeKit |
|---|---|---|
| `Plug` (the default, and any value it does not know) | P100, P105 | Outlet: On; Outlet In Use always on (the plug cannot tell) |
| `PowerPlug` | P110 | Outlet: On, Outlet In Use while it draws power; Eve's Current Consumption (W) and Total Consumption (kWh today); Eve history |
| `Light` | L510E | Lightbulb: On, Brightness |
| `WhiteLight` | L520E | Lightbulb: On, Brightness, Color Temperature (154 to 400 mireds), Adaptive Lighting |
| `Colorlight` | L530E | Lightbulb: On, Brightness, Color Temperature (140 to 400 mireds), Hue, Saturation, Adaptive Lighting; Eve's consumption characteristics and history |
| `Camera` | Battery cameras with one lens (C400, C420, C425, …; untested) | A camera of its own (live video, snapshots) |
| `DualLensCamera` | C675D | Two cameras of their own: the wide lens, and the tele lens as `<name> Tele` |

`type` is matched in any case. Accessory Information has Manufacturer TP-Link, the model of the kind (`Tapo P110`), the
device's hardware id as the serial number and the version of its firmware.

- **Total Consumption is today's**: the devices count from midnight, so it starts again every day.
- **An L530's power is an average**: the bulb reports the watt-hours it used today and how long it has been on, so
  Current Consumption is the one divided by the other while it is on, and 0 while off. It is read every ten minutes.
- **A P110's power** is read with each poll. It stays on Eve's characteristics and history: it is not added to the
  Status page's Energy section, where a meter measuring the whole home would count it a second time.
- **Brightness and colours of a bulb that is off** are not sent, as the Homebridge plugin does: the Home app's write is
  acknowledged and the bulb keeps its own. Turning it on and setting a brightness in one scene works: writes made within
  `waitTimeUpdate` go out together, on or off first. A Brightness of 0 is sent as 1, the lowest the bulbs take.
- **Adaptive Lighting** writes the white through the same path, so it waits while the bulb is off. A white or a colour
  set in the Tapo app turns it off, as one set in the Home app does.
- A device that does not answer shows **No Response**; the plugin asks it again after its `updateInterval`, then less and
  less often up to every five minutes, and as before once it answers.

### From Homebridge

The block is homebridge-tapo's, so it can be pasted unchanged, and the accessories keep their identity: the Device Id is
the device's `host` and `name` run together (`192.168.1.21Kitchen`, the host alone without a name), the seed the
Homebridge plugin made its accessory's UUID from. As there, changing a device's address or name in `devices` makes a new
accessory. A device no longer in `devices` leaves the bridge, as with every Homeswift plugin (the Homebridge plugin kept it until
the cache was cleared).

**A `WhiteLight` device changes**: the Homebridge plugin meant it as a white lightbulb but compared the type in a way that
never matched, so an L520E was an Outlet there. Here it is a Lightbulb with Brightness and Color Temperature; HomeKit
sees a new service, so the automations and scenes that used it as an outlet need doing again.

## Battery cameras

Tapo's battery cameras have no RTSP and no camera account: they stream only through TP-Link's own media server on port
8800, which signs in with the **cloud password of the camera's owner** (the account the plugin is signed in with must be
the primary owner's; a shared account is refused). Each lens is a camera accessory on a HAP server of its own (add it in
the Home app with the bridge's setup code, as other cameras).

- **The battery comes first.** The camera is reached only while the Home app shows its live view: the plugin connects
  when HomeKit starts a stream and disconnects a few seconds after the last viewer leaves. It never connects for a
  snapshot: a snapshot is the last image a live view saw (kept on disk, so it survives a restart), and a camera nobody
  has watched yet has none. There is no HomeKit Secure Video and no prebuffer, which would keep the camera streaming.
- **Both lenses of a C675D come in one session** (HD): watching both costs the camera one connection. Each lens is
  HEVC, which HomeKit does not take, so FFmpeg transcodes it to H.264 (with VideoToolbox on a Mac, set
  `videoProcessor` to an FFmpeg that has it).
- **`resolution: "VGA"`** asks for the camera's sub stream instead: one 1280 × 720 H.264 stream, of the tele lens only on a
  C675D, which then shows as one camera.
- **Standby.** A battery camera ends its stream about every ten minutes; while someone watches, the plugin opens a new
  session at once (a few seconds without picture), at most five times in ten minutes, then ends the view.
- **Motion comes from the TP-Link cloud.** Nothing on the local network reports motion without keeping the camera
  awake, so each lens has a Motion Sensor fed by the account's notification inbox in the TP-Link cloud
  ([docs/clean-room/TapoCloudEvents.md](../../docs/clean-room/TapoCloudEvents.md)): the camera wakes on its own sensor and
  reports the detection there, and the plugin asks the inbox every five seconds (one request for every camera of the
  account), which never reaches the camera. Motion Detected stays on 30 seconds after the last detection; expect it a
  few seconds after the Tapo app's notification. The camera's **Activity Notifications** must be on in the Tapo app.
  `motion: false` leaves the sensor and the cloud out.
- **Signing in to the cloud** happens at Setup (Add accessories), with the account's sign-in: the first time, the cloud
  e-mails the account a code for this new "terminal" (it may also e-mail that a new device signed in); once given, the
  terminal is trusted and its session is kept in the vault. Without cameras the code may be left empty: the account then
  works for plugs and bulbs alone. A refused sign-in stops the motion until Setup signs in again. The camera is found in
  the account by its `cloudId`, its MAC address (when the bridge knows it), its name or its model (the log lists the
  account's cameras when none matches).
- **Cameras are found through the cloud.** Once the account is signed in, Add accessories lists the account's cameras
  that the block does not have yet, by their cloud id (their Device Id). The cloud has no camera's address and asking
  the camera would wake it, so the bridge looks for the camera's MAC in its ARP table; when it is not there, the bridge
  sends one empty datagram to the discard port of every address of its local networks (of 1024 addresses at most), so
  the system resolves their MACs, and reads the table again. A camera on another subnet or VLAN than the bridge is
  never in its ARP table: its Setup asks for the address. **Set up** writes the camera's `host`, `type` (`DualLensCamera`
  for a C675D, `Camera` otherwise), `cloudId` and name into its Accessory Settings; an address typed in is checked
  against the camera's MAC when the bridge knows the address. A mains-powered Tapo camera is listed too: with RTSP, the
  IP Cameras plugin suits it better.
- **No audio** yet: the cameras' G.711 is declared in a way FFmpeg reads as MP3.
- The password is sent as the camera asks for it (its SHA-256, then its MD5 once on a new connection), never in clear,
  and neither the password, its hashes nor the session's keys are logged. A refused password is reported once and not
  tried again until the next view.

```json
{ "name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera" }
```

## Configuration

```json
{
  "platforms": [
    {
      "platform": "TapoP100",
      "name": "Tapo Smart Platform",
      "username": "me@example.com",
      "password": "…",
      "devices": [
        { "name": "Kitchen", "host": "192.168.1.21", "type": "Plug" },
        { "name": "Heater", "host": "192.168.1.22", "type": "PowerPlug", "updateInterval": 30 },
        { "name": "Sofa", "host": "192.168.1.23", "type": "Colorlight" }
      ]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `username`, `password` | | A Homebridge block's Tapo account: read, and moved into the vault at the next settings save. Setup (Add accessories) signs in instead; the settings form has no field for them |
| `waitTimeUpdate` | 100 | Milliseconds a change from HomeKit waits for the ones made with it (unused by the Homebridge plugin) |
| `devices[].name` | | The name in HomeKit, and part of the Device Id |
| `devices[].host` | | The device's IP address or host name; HTTP on port 80 |
| `devices[].type` | `Plug` | See [In HomeKit](#in-homekit) |
| `devices[].updateInterval` | 10 | Seconds between polls (0 is the default) |
| `devices[].timeout` | 2 | Seconds a securePassthrough request waits; KLAP waits 5 |
| `devices[].resolution` | `HD` | A camera's stream: `HD` (every lens) or `VGA` (the sub stream: one lens) |
| `devices[].motion` | `true` | A camera's Motion Sensor, from the TP-Link cloud |
| `devices[].cloudId` | | The camera's id in the TP-Link cloud, when it is not found otherwise |
| `videoProcessor` | `ffmpeg` | The FFmpeg the cameras' streams go through |

Each `devices` entry moves into the block's `_accessories` the first time the settings are saved, under its Device Id
(the host and name as before), with its name as the accessory's Name and `host`, `type`, `updateInterval`, `timeout`
and `resolution` as its own settings; from then on a rename or a new address keeps the accessory. A Homebridge block works in either shape.

Numbers may be written as strings (`"10"`), as the Homebridge plugin's form wrote them. `pollingInterval`, `timeout` at
the top and `devices[].port` are read and unused, as there.

**Setup.** On Add accessories, the instance's account asks for the Tapo email and password, checks them with the
TP-Link cloud (and its e-mailed code, the first time) and on the first plug or bulb of `devices` when it answers, and keeps them in the vault (taking `username` and `password` out of the block).
Plugs and bulbs are added to `devices` by address: they announce nothing the plugin listens for. Cameras come from the
account's cloud ([Battery cameras](#battery-cameras)). Each needs **Third-Party Compatibility** turned on in the Tapo app
on current firmware.

## How it talks to the devices

Plain HTTP to the device, one request at a time per device, with:

- **KLAP**, current firmware: two handshakes prove both sides know the account (SHA-256 over random seeds and a hash of
  the email and password), then each request is AES-128-CBC with a key, an IV prefix and a sequence number derived from
  them, signed with SHA-256. The session cookie's `TIMEOUT` is honoured (a new handshake a minute before it ends), and an
  HTTP 403 or 401, a response that does not decrypt, a session timeout (9999) or refused credentials (-1501) start one
  new handshake and one retry; a second refusal is reported.
  The response's signature is not checked.
- **securePassthrough**, older firmware, only when KLAP's handshake1 answers 404, and never for a device that completed a
  KLAP handshake before (kept in the plugin's `klap-devices.json`), so whatever answers at its address cannot have the
  bridge send the login this protocol carries: an RSA-1024 key exchange gives an
  AES key and IV, `login_device` a token, and each request is wrapped in a `securePassthrough` envelope.

Every answer's `error_code` is checked, writes included, and read leniently (`-0301` is -301). The account's email,
password, the derived keys and the session cookie are never logged.

A battery camera is reached over plain TCP on port 8800 (Streamd, [docs/clean-room/TapoCamera.md](../../docs/clean-room/TapoCamera.md)):
`POST /stream` with a multipart body each way, an HTTP Digest login as `admin` whose password is the uppercase hex of
the cloud password's SHA-256 (when the camera's challenge says `encrypt_type="3"`) or MD5, then a preview request; the
camera's parts are MPEG-TS, AES-128-CBC encrypted with a key and an IV made from its `Key-Exchange` nonce and the hash,
each part from the same IV. Ten seconds without a part end the session. FFmpeg reads the TS on its standard input and
takes the lens's video stream.

## Pan and tilt

A C675D's tele lens is on a motor. Its live view in the web UI has a **Pan and tilt** pad that turns it 15° a step while
held, with the camera's presets (from the Tapo app) beside it; the Assistant and MCP clients get `list_ptz_cameras`,
`move_camera` (up, down, left or right by 1° to 90°) and `go_to_preset`. The camera's control API
([docs/clean-room/TapoPTZ.md](../../docs/clean-room/TapoPTZ.md)) is HTTPS on port 443, its self-signed certificate
pinned on first use in `control-certificates.json`, signed in as `admin` with the owner's cloud password:

- **Only while awake.** A move is sent only while a live view (the Home app's or the web UI's) keeps the camera awake: a
  request never wakes it on its own, and asleep the pad's answer says to open the live view first.
- **Asked once.** Whether a camera has a motor is asked the first time it is watched and kept in `ptz.json`; its presets
  are read again every five minutes while it is watched, and when one asked for is not among them.
- **The login.** The encrypt_type 3 login: the camera proves it knows the password's hash before the bridge sends its own
  proof, so an address that is not the camera learns nothing. A firmware that offers only the newer SPAKE2+ login is not
  supported yet (the log says so). A wrong password or a lockout stops the attempts for a minute, or as long as the
  camera says; a new certificate (after a firmware update) is trusted again once the camera's proof passes.
- At most one motor request a second; the end of the range answers "cannot turn further that way".
- **Untested on a real camera** so far: please report how yours moves.

## Not done

- Plugs and bulbs have to be listed by address; cameras come from the account.
- L900 light strips have no type of their own; as `Colorlight` they may work (untested), without their segments and
  effects.
- KLAP's newer variant used by some cameras and hubs, and accounts whose devices expect other credentials in the
  handshake, are not supported.
- Eve's Reset Total is not offered (the Homebridge plugin defines it but adds it nowhere), and the total is today's.
- Battery cameras: no audio, no two-way audio, no HomeKit Secure Video (recording on motion needs a recording source fed by
  the stream rather than RTSP); person, vehicle and pet detections are all Motion; the cameras' settings (privacy mode,
  the floodlight, the siren, the battery level) are not read from the camera's control API, which the plugin uses for pan
  and tilt only. Motion
  push (FCM) instead of the inbox poll is not done.

## Tests

`swift test --filter TapoTests` runs the plugin against a fake device, with no device, account or network: the spec's
KLAP and login vectors byte for byte (hashes, session keys, the first request's ciphertext and signature), the identity
seed against the Homebridge plugin's UUIDs, an RSA handshake, both protocols end to end (403 and a cookie timeout giving
one new handshake, a refused set, malformed error codes), each kind's services, writes grouped and dropped while off,
No Response and recovery, the P110 and L530 energy, Adaptive Lighting turned off by a colour set elsewhere, and Setup.
The cameras run against a fake Streamd server: the spec's Digest, key and part vectors, the SHA-256 login and its MD5
fallback, a refused password and a busy camera, parts split across reads, silence and a closed connection ending a
session, the feed opening no connection until someone watches, one session for both lenses, the session closed after its
last viewer, quiet reconnections after standby and the budget that ends them. The motion runs against a fake TP-Link
cloud that checks each call's signature: the sign-in, the e-mailed code of a new terminal through Setup, an expired token
refreshed once, a refused password stopping the watch, the camera found by its MAC, and a detection reaching both lenses
and clearing after its hold without a connection to the camera.

`StreamdLiveTests` records a sample from a real camera when `TAPO_LIVE_HOST`, `TAPO_LIVE_PASSWORD_FILE` (a file holding
the cloud password) and `TAPO_LIVE_OUTPUT` are set, and runs the live stream's FFmpeg command on a recorded sample for
each lens when `TAPO_LIVE_SAMPLE` is; both are skipped otherwise. On a C675D (firmware 1.1.7) the session opened in 2
seconds and the HD sample held two 3840 × 2160 HEVC streams at 15 fps (wide, then tele) and the 0x91 audio, each lens
encoding to 1080p H.264 several times faster than real time with VideoToolbox.

## Clean-room implementation

Compatible with the configuration of [homebridge-tapo](https://github.com/apatsufas/homebridge-tapo-p100) by apatsufas
(Apache License 2.0). Written from the functional spec in [docs/clean-room/Tapo.md](../../docs/clean-room/Tapo.md),
without reading or copying its code. The cameras are written from [docs/clean-room/TapoCamera.md](../../docs/clean-room/TapoCamera.md),
a spec of the Streamd protocol as [pytapo](https://github.com/JurajNyiri/pytapo) (MIT) and
[go2rtc](https://github.com/AlexxIT/go2rtc) (MIT) speak it, without reading or copying their code; their motion from
[docs/clean-room/TapoCloudEvents.md](../../docs/clean-room/TapoCloudEvents.md), a spec of the TP-Link cloud's sign-in and
notification inbox written from public projects and the Tapo app's published names.
