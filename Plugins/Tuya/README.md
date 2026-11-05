# Tuya

Tuya and Smart Life devices in HomeKit through the Tuya Cloud OpenAPI: lights, switches and plugs, dimmers, fans,
air conditioners, heaters, thermostats, humidifiers and dehumidifiers, purifiers and diffusers, curtains and garage
doors, locks and alarms, sensors, doorbells, cameras (live video and snapshots), IR remotes (and IR air conditioners) behind an IR
hub, and a Smart Home account's scenes.

**Experimental**: written from a specification and tested against fakes of the cloud and its MQTT, not yet on real
devices. Maintainer: Mickael Palma.

## How it works

- **Sign-in.** A **Smart Home** project (`projectType` `"2"`) signs in with the Tuya Smart or Smart Life app's account
  linked to a cloud project on the [Tuya IoT Platform](https://iot.tuya.com); a **Custom** project (`"1"`) uses its own
  token, a `homebridge` user it creates, and the devices of its assets. Requests are signed as Tuya's
  [API request](https://developer.tuya.com/en/docs/iot/new-singnature) documentation describes, the token refreshed a
  minute before it expires.
- **Push, no polling.** States come from Tuya's [Message Service](https://developer.tuya.com/en/docs/iot/open-hub-message-service)
  over MQTT (TLS), decrypted with AES-128-ECB (Smart Home) or AES-128-GCM (Custom, the tag checked); a late message cannot
  roll a value back. The MQTT configuration is renewed a minute before it expires, and asked for again with a growing
  delay when Tuya refuses it. Without push, states stay as they were last reported.
- **Writes.** A write from HomeKit goes to the cloud's `commands` endpoint; slider and colour writes wait 100 ms for
  more and go as one request (hue and saturation together). A device that is offline answers No Response.
- **Adaptive Lighting** on every light with brightness and colour temperature (turn it off with
  `"adaptiveLighting": false`); a colour or a white set in the Tuya app turns it off.
- **IR remotes** of an IR hub (`wnykq`, `hwktwkq`, `wsdykq`) are a switch per key (a DIY remote's learned codes
  included), an IR air conditioner a heater-cooler with its dehumidifier and fan modes.
- **Locks** open and close through Tuya's password-free door operation; HomeKit's lock state goes through the bridge's
  security rules (the MCP server and the Assistant ask first).
- **Cameras** (`sp`) keep their doorbell, motion sensor and floodlight in the bridge, as before, so existing homes keep
  their rooms, scenes and automations. Their video is an accessory of its own (`context.publishExternal`): add it in the
  Home app as a camera, with the bridge's setup code. It has live video, snapshots, and a Motion Sensor and a Doorbell
  that follow the bridged ones, so HomeKit's notifications carry a picture. Each stream asks the cloud for a fresh RTSP
  URL (`POST /v1.0/devices/{id}/stream/actions/allocate`, `{"type":"rtsp"}`), read by FFmpeg over TCP with a 10 second
  socket timeout (left out when FFmpeg's version is unknown, where the option's name differs); an answer that is not an
  RTSP URL is not read. Snapshots are a frame of such a stream, kept 10 seconds and shared by the requests that come
  meanwhile; a failed one answers the requests of the next 10 seconds without another cloud call. The cloud project needs the **IoT Video Live Stream** service authorized; when Tuya answers that it is not
  subscribed or expired, no stream is asked for that camera for 5 minutes. An offline camera is refused without a cloud
  call. The URL carries a credential: it is never logged, and FFmpeg's command lines and messages show it masked.
  FFmpeg is the `ffmpeg` on the `PATH` (with `libfdk_aac` for audio, or AudioToolbox's AAC on macOS). Virtual devices
  (ids starting `vdevo`) have no video. In the camera's Accessory Settings, **Video** (`video`, on by default) turns the
  video accessory off, and **HomeKit Secure Video** (`recording`, off by default) records its motion and rings, each recording
  opening a stream of its own.

## Configuration

Add the instance on **Add accessories**: Setup asks the project's type, its Access ID and Access Secret (and, for a
Smart Home project, the app account), signs in to check them, and keeps the Access Secret and the app's password in
the bridge's vault. A homebridge-tuya-platform block works as it is:

```json
{
  "platform": "TuyaPlatform",
  "name": "Tuya",
  "options": {
    "projectType": "2",
    "accessId": "…",
    "accessKey": "…",
    "countryCode": 33,
    "username": "user@example.com",
    "password": "…",
    "appSchema": "smartlife",
    "homeWhitelist": [12345678],
    "deviceOverrides": [
      { "id": "keyabc123", "category": "kg" },
      { "id": "bf9876543210zyxwvuts", "schema": [ { "code": "temp_set", "onGet": "(value * 5);", "onSet": "(value / 5);" } ] }
    ]
  }
}
```

| Option | Meaning |
|---|---|
| `projectType` | `"1"` Custom, `"2"` Smart Home (the numbers are read too). |
| `accessId`, `accessKey` | The cloud project's Access ID and Access Secret. `accessKey` is not a secret-named key: Setup keeps it in the vault, and a block's moves there with the next settings write. |
| `endpoint` | The data centre (`https://openapi.tuyaeu.com`…). Required for Custom; Smart Home takes its country's. |
| `countryCode`, `username`, `password`, `appSchema` | Smart Home: the app account (`password` may be its MD5). |
| `homeWhitelist` | Smart Home: only these homes. |
| `deviceOverrides` | By device id or uuid, product id, scene id or `global`: `category` (`hidden` leaves it out), `unbridged`, `adaptiveLighting`, `schema` (DP overrides: `code`, `newCode`, `type`, `property`, `onGet`, `onSet`, `hidden`; the legacy `oldCode` is read). A device's own entry moves into its Accessory Settings. |
| `debug`, `debugLevel` | Debug logs of the API (`api`) or of devices (their ids). No token, key or password is logged. |

**`onGet` and `onSet`.** Homebridge runs these as JavaScript. Homeswift reads the part of JavaScript the original
plugin's documentation shows, without running code: numbers, strings, `true`/`false`/`undefined`, `value` and `device`
(`device.online`, `device.status.find(s => s.code === 'x').value`…), `+ - * / %`, comparisons, `! && ||`, `? :` and
`Math.round/floor/ceil/min/max/abs/trunc`. An expression outside that is logged once and ignored (the device's value
is used as it is).

## Differences from homebridge-tuya-platform

Deliberate fixes of the behaviour the specification describes: a current DP in another unit than `mA` no longer
divides by zero; a pet feeder's switch sends one feed; a second curtain reads its own `percent_state_2` when it has
one; a lock's `closed_opened` enum (`closed`/`open`) reads as its words; thermostat and speed writes are rounded to
what the DP takes; a failed MQTT configuration is asked for again; a debounced write sent while another is in flight
is not lost, and one the cloud refuses is followed by a read of the device's state; device records are asked for twenty
at a time; a token that cannot be refreshed leads to a new sign-in; a battery's low state and a weather station's
humidity follow the DP's scale; a lock that fails to move reports it to HomeKit.

Choices of Homeswift's own:

- **Adaptive Lighting is on by default** for every light with brightness and colour temperature (the original only
  with `adaptiveLighting: true`); `"adaptiveLighting": false` turns it off.
- **The Access Secret goes in the vault** through Setup; a block's `accessKey` moves there with the next settings
  write (it is not a secret-named key, so the runtime does not seal it in place).
- **`projectType` may be a number** (`1` or `2`) as well as the strings.
- **A lock without `lock_motor_state`** shows its state read-only: writing its target is refused.
- **Cameras' video** (docs/clean-room/TuyaCamera.md): an allocation that fails answers HomeKit at once (the original
  never answered); a stream ends after 30 seconds without HomeKit's reports at the least (the original's 2.5 seconds
  stopped healthy streams); an offline camera's stream is refused (the original tried); the stream is scaled to the size
  HomeKit asks; snapshots are coalesced (the original allocated a stream for every one); the URL is never logged (the
  original logged FFmpeg's whole command line).

## Gaps

- **Cameras:** no two-way audio (the original has none either); HLS and the other stream types are not asked for; the
  lifetime of an allocated URL is unknown, so a very long stream ends when the cloud closes it (HomeKit can start another);
  a snapshot is the camera's full frame, not resized; HomeKit Secure Video starts each recording on a new cloud stream,
  so its first seconds are those of the connection, with no prebuffer.
- **`onGet`/`onSet`** beyond the documented subset (above).
- **Custom projects** read the first 100 top-level assets, as the original does.

## Tested

`swift test --filter "TuyaTests|TuyaProtocolTests"`: the specification's signing vectors (token grant, Smart Home
login, a signed query, commands), its MQTT vectors (AES-ECB and AES-GCM, a changed byte or time refused), the device
list and specification of its example lamp and power strip end to end on a host (values, coalesced writes, offline,
push, Adaptive Lighting, scenes, overrides), a camera's video on fakes (the allocation's signature from the camera
specification's vector, one allocation per stream start, coalesced snapshots, a refusal answered and backed off, an
offline camera refused without a call, the URL never logged), the expression evaluator on the documented examples, the settings'
canonical shape. Checked on a throwaway bridge without an account (it says it is not configured, and does not crash).

## Clean-room implementation

Compatible with the configuration of [homebridge-tuya-platform](https://github.com/0x5e/homebridge-tuya-platform) by
Tuya Inc. (MIT). Written from the functional specifications in
[docs/clean-room/Tuya.md](../../docs/clean-room/Tuya.md) and [docs/clean-room/TuyaCamera.md](../../docs/clean-room/TuyaCamera.md), and Tuya's public developer documentation
(developer.tuya.com: API request and signing, the standard instruction sets, the Message Service, the IR control hub
open service, password-free unlocking), without reading or copying its code.
