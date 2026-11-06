# ESPHome

**Experimental**: written and tested against fakes of the native API, not yet on a real ESPHome device. Reports
from people who run it are welcome.

ESPHome devices in HomeKit over their [native API](https://esphome.io/components/api/) (TCP 6053), plaintext or
encrypted with the device's key, one accessory per entity. Devices push their states as they change: nothing is
polled. Found over mDNS (`_esphomelib._tcp`) or listed by address.

| ESPHome entity | HomeKit |
|---|---|
| `switch` | Switch |
| `light` | Lightbulb: On, Brightness, Hue and Saturation (RGB modes), Color Temperature (color temperature and cold/warm white modes, with Adaptive Lighting), and a Switch per effect (`<light> - <effect>`; one at a time) |
| `binary_sensor` | By device class: `motion`, `occupancy`, `presence` a Motion Sensor; `door`, `window`, `opening`, `garage_door` a Contact Sensor; `smoke` a Smoke Sensor; `moisture` a Leak Sensor. Others are not mapped |
| `sensor` | `°C` or `°F` a Temperature Sensor (Fahrenheit converted); `%` with the `humidity` class or the `mdi:water-percent` icon a Humidity Sensor; `lx` or the `illuminance` class a Light Sensor. Others are not mapped |
| `cover` | Window Covering (position, stop, tilt), or Garage Door Opener for the `garage`, `gate` and `door` classes |
| `fan` | Fan: Active, Rotation Speed in the device's speed levels, Swing Mode, Rotation Direction |
| `climate` | Thermostat: modes (off, heat, cool, auto) as the device supports them, target or low and high temperatures, current temperature and humidity, the device's unit converted |
| `lock` | Lock Mechanism. Lock Target State is a security control: the bridge's own surfaces (the web UI, MCP, the Assistant) write it only once a person confirmed. Locks that need a code are not supported |
| `button` | Switch: on presses the button, then it turns back off |

Text sensors, numbers, selects, sirens, valves, media players and the other types are left out (logged as not
supported).

## Bluetooth sensors

ESPHome devices with [`bluetooth_proxy:`](https://esphome.io/components/bluetooth_proxy/) pass on the Bluetooth LE
advertisements they hear, and the plugin turns passive sensors among them into accessories. It subscribes to every
connected proxy (raw advertisements in batches when the firmware has them, parsed ones on older firmware); the
host's own Bluetooth adapter is not used. A sensor heard by several proxies is read once per frame (the same bytes
within 5 seconds), and the loudest proxy of the last minute is the one it is nearest.

| Format | Devices | Bindkey |
|---|---|---|
| [BTHome v2](https://bthome.io/format/) (service data 0xFCD2) | Shelly BLU, BTHome firmware on Xiaomi thermometers (pvvx, ATC), DIY sensors | Only when it encrypts (AES-CCM) |
| Xiaomi MiBeacon (service data 0xFE95), versions 4 and 5 | LYWSD03MMC, LYWSD02, CGG1, LYWSDCGQ and others on stock firmware | Encrypted frames: yes (the device's 32-character bindkey) |
| Govee (manufacturer data) | H5072, H5075, H5074; H5100, H5101, H5102, H5104, H5174, H5177, H5179 (told by their GVH5 name) | Never |

| Value | HomeKit |
|---|---|
| Temperature, humidity, illuminance, CO₂ | Temperature, Humidity, Light, Carbon Dioxide Sensor (CO₂ detected from 1200 ppm) |
| Battery percent, battery low | Battery (low under 20 % when the device does not say) |
| Motion; occupancy, presence | Motion Sensor; Occupancy Sensor |
| Opening, door, window, garage door | Contact Sensor |
| Moisture (wet), smoke, carbon monoxide | Leak, Smoke, Carbon Monoxide Sensor |
| BTHome button events | A Stateless Programmable Switch per button: press, double press, long press (and hold) |

The accessory gets a service for each value as the sensor first sends it, so a Xiaomi sending its temperature,
humidity and battery in turn has its three within a minute or two. Its id is `esphome:<MAC>`, its Serial Number the MAC
without separators (`A4C138123456`).

**Setup.** Each sensor heard in one of these formats is a Discovered Device of the Device Kind `sensor` in **Add
accessories** (or `discover_devices`), its Device Id its MAC. A Govee thermometer or an open BTHome sensor asks
nothing; an encrypted one (every stock Xiaomi, an encrypted BTHome) asks for its bindkey, checked against the last
frame heard and kept in the vault. Setup writes the sensor's `format` in its Accessory Settings; without it a sensor
is not an accessory, so a neighbour's thermometer never shows up on its own. Discovery lists only what the running
plugin has heard: Setup on a paused instance finds no sensors.

```json
{
  "platform": "esphome",
  "bluetoothTimeout": 30,
  "_accessories": {
    "A4:C1:38:12:34:56": { "format": "xiaomi" },
    "38:1F:8D:00:11:22": { "format": "govee", "name": "Cellar" }
  }
}
```

| Option | Default | What it does |
|---|---|---|
| `bluetooth` | `true` | Subscribe to the advertisements of every Bluetooth proxy |
| `bluetoothTimeout` | `30` | Minutes without a frame before a sensor shows No Response |

A sensor not heard for `bluetoothTimeout` minutes shows No Response, until it is heard again. After a restart its
cached accessory keeps its values and stays reachable for that long while the proxies reconnect.

The decoders were written from BTHome's specification (checked against its encryption example), the MiBeacon frame
layout as the community documents it, and the Govee frame layouts as owners have documented them; no code was copied.
AES-CCM is built on swift-crypto's AES block function and checked against RFC 3610's vectors.

## Configuration

A [homebridge-esphome-ts](https://github.com/lucavb/homebridge-esphome-ts) block loads unchanged:

```json
{
  "platform": "esphome",
  "devices": [{ "host": "my_esp.local", "password": "…", "port": 6053, "retryAfter": 120000 }],
  "retryAfter": 60000,
  "discover": true,
  "discoveryTimeout": 6000,
  "blacklist": ["My blacklisted switch"]
}
```

| Option | Default | What it does |
|---|---|---|
| `devices` | `[]` | Devices by address: `host` (a host name or an IP address), `port` (6053), `password` (the legacy API password, for firmware before 2026.1), `encryptionKey` (the base64 key under the device's `api: encryption: key:`), `retryAfter` |
| `discover` | `false` | Look for devices over mDNS at start and connect to each one found, with the credentials Setup keeps for it |
| `discoveryTimeout` | `5000` | Milliseconds the mDNS search lasts |
| `retryAfter` | `90000` | Milliseconds: the longest wait between attempts to reach a device that does not answer. Attempts back off from 1 second by 1.8 times, to this or one minute, whichever is shorter |
| `blacklist` | `[]` | Entity names to leave out, exactly as ESPHome sends them; their cached accessories are removed |
| `debug` | `false` | Logs each device's entities, and those left out, at the info level |

`password` and `encryptionKey` are secrets: config.json may hold them sealed or as `vault:`, `env:` or `file:`
references, and they are masked in logs. Setup is the better way: the web UI's **Add accessories** (or the MCP tools
`discover_devices` and `start_setup`) lists the devices mDNS finds, asks for the encryption key of an encrypted one
(or the password of an old one), checks it by connecting, and keeps it in the vault. A device set up so has its
Accessory Settings in `_accessories` by its MAC (the Device Id): `host`, `port` and `retryAfter`. A `devices` entry
moves there at the next settings write once the plugin has reached the device (its key or password into the vault);
one it has not reached stays.

```json
{
  "platform": "esphome",
  "_accessories": {
    "AC:BC:32:89:0E:A9": { "host": "192.168.1.40" },
    "AC:BC:32:89:0E:AA": { "host": "garage.local", "port": 9001, "excluded": true }
  }
}
```

## Identity

Each entity is an accessory whose id is its name, `esphome:<entity name>`, as the Homebridge plugin had it, so a
migrated bridge keeps its accessories. Renaming an entity in ESPHome makes a new accessory, and the old one leaves the bridge once the device lists its
entities without it. Entities of sub-devices (`devices:`) are told apart by their `device_id`. Two entities with the
same name (two devices with a "Temperature" each) no longer share one accessory: the second gets
`esphome:<name>@<MAC>`, and an entity without a name `esphome:@<MAC>`, with a warning in the log. The ids taken are
kept in `entities.json` in the plugin's folder, so they do not depend on which device answers first.

## Connection

The plugin follows ESPHome's reference client: Hello, the password if one is configured (never waited for: firmware
since 2026.1 ignores it), the device's information, its entities, then the subscription to their states. It pings the
device every 20 seconds and closes a connection that stays silent for 90; it answers the device's pings and time
requests. A device that disconnects on purpose (rebooting) is reconnected after 5 seconds, one that drops at once.
A rejected password or encryption key stops the attempts until the configuration changes, with an error in the log.
While a device is away its accessories show No Response, and writes to them fail.

Encryption is `Noise_NNpsk0_25519_ChaChaPoly_SHA256` with the prologue `NoiseAPIInit\0\0`, in
`HomeswiftNetwork/Noise.swift` (tested against the Noise project's test vectors); messages are protobuf
(`HomeswiftNetwork/Protobuf.swift`) in ESPHome's framing, with lengths and types as real varints (the Homebridge
plugin's library wrote single bytes, which lost long entity lists).

## Gaps

- Not tested on a device yet.
- `debug` does not write the Homebridge plugin's raw frame dump to `/tmp`.
- Locks with a code, light transitions, flashes and white channels, fan presets, climate fan and swing modes and
  presets are not mapped.
- Devices that appear on the network after the start are found by Setup, not connected until the plugin reloads.
- Bluetooth: no active connections through proxies (sensors that must be read over GATT), no MiBeacon before version 4
  when encrypted, no BTHome v1, and the Xiaomi and Govee decoders are checked on frames built to their layouts, not on
  captures from devices.

## Clean-room implementation

Compatible with the configuration of [homebridge-esphome-ts](https://github.com/lucavb/homebridge-esphome-ts) by Luca
Becker (GPL-3.0). This plugin was written from the functional specification in
[docs/clean-room/ESPHome.md](../../docs/clean-room/ESPHome.md) and ESPHome's public documentation
([native API](https://esphome.io/components/api/)), without reading or copying the Homebridge plugin's code or its
libraries'.

## Maintainer and tests

Maintained by Mickael Palma. `swift test --filter ESPHomeTests` runs it against a fake device in memory that speaks the
native API (plaintext and Noise, as a responder): the specification's framing and message vectors, each entity type,
writes reaching the device, pushes reaching HomeKit, a wrong key and a wrong password stopping the attempts, a device
offline then back, Setup asking for a key, the canonical settings; Bluetooth: AES-CCM on RFC 3610's vector, BTHome
open and encrypted (its specification's example), MiBeacon and Govee frames, proxies subscribing and passing on
advertisements, one frame from two proxies read once, a sensor going No Response unheard, Setup asking for a bindkey.
