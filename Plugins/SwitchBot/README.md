# SwitchBot

**Experimental**: written and tested against fakes of SwitchBot's cloud and of a Bluetooth adapter, not yet on the
devices.

SwitchBot devices and IR remotes in HomeKit through SwitchBot's cloud ([OpenAPI v1.1](https://github.com/OpenWonderLabs/SwitchBotAPI))
and, for the devices that have it, over Bluetooth LE ([below](#bluetooth)), platform `SwitchBot`.

| Device types | In HomeKit |
|---|---|
| Bot, Relay Switch 1 / 1PM | One service chosen by `type` (`switch` by default; `outlet`, `garagedoor`, `door`, `window`, `windowcovering`, `lock`, `faucet`, `fan`, `stateful`), battery (Bot); `mode` `switch`, `press` or `multipress` |
| Plug, Plug Mini (US, JP, EU) | Outlet |
| Curtain, Curtain3, Roller Shade | Window Covering (moves polled every `updateRate` seconds while they last), battery, light sensor, optional silent mode switches |
| Blind Tilt | Window Covering with the five `mapping`s, battery, light sensor |
| Meter, Meter Plus, Meter Pro, Meter Pro CO2, Outdoor Meter | Temperature, humidity, carbon dioxide (Meter Pro CO2), battery |
| Hub 2, Hub Mini 2, Hub 3 | Temperature, humidity, light |
| Motion, Contact and Presence Sensors, Water Detector | Motion, contact, occupancy, leak, light, battery |
| Smart Lock, Lock Pro, Lock Ultra | Lock Mechanism (jammed shows as jammed), door contact sensor, a Latch switch that unlocks at once; both are security controls |
| Color Bulb, Strip Light, Ceiling Light, Ceiling Light Pro | Lightbulb; colour temperature with Adaptive Lighting (Color Bulb, Ceiling Lights), colour (Color Bulb, Strip Light) |
| Humidifier, Humidifier2 | Humidifier with auto or a target humidity, water level, temperature |
| Battery Circulator Fan | Fan with speed and oscillation, battery |
| Robot vacuums (K10+, S1, S10…) | A switch that stands for a cleaning robot (`start`, `dock`), battery |
| Air Purifiers | Air Purifier (on and off; speed and mode shown) |
| IR remotes (TV, Projector, Set Top Box, IPTV, DVD, Speaker, Fan, Air Conditioner, Light, Air Purifier, Water Heater, Vacuum Cleaner, Camera, Others, and their DIY kinds) | Television with its speaker (published on its own), Fan, Heater Cooler (`setAll`, a linked meter's temperature), Lightbulb or two buttons, Air Purifier, Valve, Switch, or for Others the service `type` names, with learned buttons (`customize`) |

## Setup

Add accessories asks for the account's **token** and **client secret**: in the SwitchBot app, Profile, Preferences, tap
App Version ten times, then Developer Options. They are checked with a device list and kept in the bridge's vault. Every
device and remote of the account is then listed; leave one out with its Accessory Settings (Excluded). A device needs
"Cloud Services" on in the SwitchBot app.

## Configuration

A block of `@switchbot/homebridge-switchbot` loads unchanged, in its 4.x shape (`credentials`, `options.devices`,
`options.irdevices`, `deviceConfig`, `irdeviceConfig`) or its 5.x shape (`openApiToken`, `openApiSecret`, `devices`,
`dailyApiLimit`…). The bridge writes it back in its canonical shape at the next settings change: the token and secret
move into the vault, and each listed device's options into `_accessories` under its Device Id. Its Device Id is the 4.x
plugin's: `<deviceId>-<deviceType>` (`C271111EC0AB-Meter`), `<deviceId>-<remoteType>` for a remote
(`02-202008110034-13-TV`), with the `deviceId` as the list spelled it. As in 4.x, a block that lists devices exposes only
those: the devices it does not name are Excluded when it moves. A device's options the schema does not declare
(MQTT's, `maxRetries` per device) stay in the list under its `deviceId`. A device's `keyId` moves as `encryptionKeyId`,
a secret-named key the bridge seals as it seals `encryptionKey`.

```json
{
  "platform": "SwitchBot",
  "options": {
    "refreshRate": 300,
    "webhookURL": "https://switchbot.example.com:8790/switchbot",
    "deviceConfig": { "Curtain": { "setOpenMode": "1", "webhook": true } }
  }
}
```

### Requests

SwitchBot allows an account 10,000 requests a day and answers "Unauthorized" past it. Every request counts (it is kept
across restarts in `requests.json`); polls stop for the day when only `dailyApiReserveForCommands` (1,000) are left, so
commands still go, and the polling interval grows when the devices would use more than the rest
(`dailyApiLimit − dailyApiReserveForCommands`). Each device's status is asked every `refreshRate` seconds (300, at
least 30), once 15 seconds after a command, and every `updateRate` seconds (5) while a curtain or blind moves. IR remotes
are never polled.

### Bluetooth

A device's `connectionType` says how it is reached: `OpenAPI` the cloud only (the default with a token), `BLE` Bluetooth
only (the default without one), `BLE/OpenAPI` Bluetooth, and the cloud when Bluetooth fails (the device is not found, a
connection or a reply times out, or the device refuses), `Disabled` not at all. 5.x's `connectionPreference` (`ble`,
`openapi`, `auto`) means the same; `enableBLE: false` (5.x) or a device's `disablePlatformBLE` turn Bluetooth off.

| Device types | Over Bluetooth |
|---|---|
| Meter, Meter Plus, Outdoor Meter, Meter Pro, Meter Pro CO2 | Temperature, humidity, CO₂, battery from their advertisements: no connection, no request |
| Contact Sensor, Motion Sensor | Contact, motion, light, battery from their advertisements |
| Bot | Press, on and off (`botPassword` for a Bot with a password); its state and battery from its advertisements |
| Curtain, Curtain 3 | Positions and pause; position, motion, battery and light level from their advertisements. A Curtain 3's silent mode is its low speed |
| Blind Tilt | Its tilts (both firmware forms); tilt, motion, battery from its advertisements |
| Plug Mini (US, JP) | On and off; its state from its advertisements and a connected read |
| Color Bulb, Strip Light | On, off, brightness, colour, colour temperature (Color Bulb); on and brightness from the advertisements, colour from a connected read |
| Smart Lock, Smart Lock Pro | Lock and unlock, AES-encrypted with the key and key id; the lock's info read after each command, at start, every read interval and, for a Smart Lock, when its advertisement changes. A Lock Pro's advertisement shows its state too |

Every other type stays on the cloud: Hubs, the Presence Sensor, the Plug Mini (EU), the Lock Ultra and Vision locks, the
Keypad, the Water Detector, Relay Switches, the Roller Shade, the Garage Door Opener, the Ceiling Lights, humidifiers, air
purifiers, the fan, vacuums and IR remotes. One configured `BLE` is logged once and uses the cloud when it can. On
Bluetooth too, a Plug Mini's power and energy (no source gives the unit), the Meter Pro's light level and a Curtain's silent
speed (sent through the cloud when the device has it, at normal speed otherwise) stay out.

A device is matched by its MAC address: `customBLEaddress`, else its `deviceId`. Without a token, the block's devices
that name their `configDeviceType` are added and reached over Bluetooth alone. Devices on Bluetooth never spend the day's
requests; one on `BLE/OpenAPI` spends them only when Bluetooth fails.

- **Keys.** A Smart Lock needs its **encryption key** (32 hex digits) and **key id** (2) from the SwitchBot app's device
  information page; SwitchBot publishes no API that gives them. Enter them in its Accessory Settings (`encryptionKey`,
  `encryptionKeyId`; a Homebridge block's `keyId` is read): both are sealed, masked and never logged. A lock without them
  stays on the cloud. A Strip Light given a key talks encrypted too.
- **Options.** `maxRetry` (5) attempts per command, with a backoff; `blePollingEnabled` (on) and `blePollIntervalMs`
  (600000, at least 60000) read the state of plugs, lights and locks besides their advertisements. A device read from its
  advertisements alone that is not heard for its `refreshRate` shows No Response (`BLE`) or is asked of the cloud
  (`BLE/OpenAPI`). `scanDuration` is read but not
  needed: the bridge scans all the time.
- **macOS.** Bluetooth goes through CoreBluetooth on the shared adapter. macOS grants it only to a binary whose
  Info.plist describes the use, and asks the *responsible* app: `homeswift` started from a terminal inherits that
  terminal's permission. Without it the plugin logs why and devices on `BLE/OpenAPI` use the cloud. macOS hides MAC
  addresses: a device is recognised by the MAC its manufacturer data starts with, and connected to by the identifier
  macOS gave that advertisement. A device whose advertisement carries no MAC in its manufacturer data (a Meter's
  service data alone has none) can only be matched on Linux, and a device never heard since the bridge started
  cannot be connected to on macOS.
- **Linux.** A raw HCI socket on `hci0` (`NOBLE_HCI_DEVICE_ID` picks another): the bridge needs `CAP_NET_RAW`
  (`setcap cap_net_raw+eip`, or the container's `--cap-add NET_RAW` with the host's network).

### Webhook

With `options.webhookURL`, the bridge listens on its port and registers the URL with SwitchBot's cloud, its path followed
by a random segment kept in the vault (`webhook.json`): only the cloud learns it, and any other path or method is answered `403`.
Bodies over 64 KB are refused. The URL must be reachable from the Internet (a port forward, a tunnel or a reverse proxy,
which must pass on what is under the path). SwitchBot keeps one webhook URL per account: registering this one replaces
another integration's. Events are shown on the devices with `webhook: true`, matched by `deviceMac`. The webhook is
deleted when the bridge stops.

## What differs from the Homebridge plugin

The 4.x plugin's evident intent is kept where it is broken: polled statuses are applied; a Bot without `type` is a
switch; `type` (and an Others remote's) is compared without case; `bright` is `set_maxLux` and a hub's light levels are
scaled; `set_minlux` and `set_maxlux` are read; the Ceiling Light's power and Kelvin are right and it gets no colour; the
Strip Light gets no colour temperature; CO₂ is abnormal from `co2AbnormalThreshold`; `up_and_down` sends positions
within range; a webhook's Fahrenheit is converted; a jammed lock shows as jammed; the fan's speed is sent when it
changes; the Blind Tilt's silent switches are two. The humidifier sends `turnOn` before a mode when it was off (4.x never sends it). A robot vacuum is a Switch that stands for a cleaning robot (4.x showed a Lightbulb). A Bot or Relay shown as a door, a window or a window covering is a security control, confirmed before the bridge's own surfaces open it.
Webhook events match `deviceMac` whatever its spelling.

## Gaps

- **Bluetooth** is experimental and tested only against a fake adapter. Open points of the spec: the Smart Lock's
  advertisement offsets disagree on SwitchBot's page, so its state comes from the connected read only; AES-GCM locks follow
  the protocol but no published vector checks them (they are checked against swift-crypto's AES-GCM); the Plug Mini's
  load unit, the Curtain's silent speed and the bulb's "RGB only" frame are not pinned; the contact and motion sensors'
  manufacturer-data forms and the Bot password come from node-switchbot, not the published documentation. Where the
  sources disagree (the Bot's state bit, the Curtain's flags, the plug, bulb and lock frames, status `0x05`) the published
  documentation is followed.
- Bluetooth is one connection per command batch (no connection kept for 8.5 s), lock status notifications are not
  subscribed, and Setup does not ask for a lock's key: it is entered in the Accessory Settings.
- The MQTT relay of webhook events (`mqttURL`) is not implemented.
- Eve history (`history`) is not wired, as in 4.x.
- The Humidifier2's own commands, the Battery Circulator Fan's night light, the air purifiers' speed and mode, and the
  television's remote keys are not sent (their API commands are not specified or are not documented).
- Scenes are not exposed.

## How it was tested

Unit and integration tests with a fake of SwitchBot's cloud (`Tests/Support.swift`): the documentation's signing
vectors, the device list and statuses of the spec's §10, commands, coalesced writes, Adaptive Lighting, No Response, the
request budget, the webhook listener and its events, and the settings' move. Bluetooth (`Tests/SwitchBotBLETests.swift`)
against `FakeBLECentral`: the Bluetooth spec's §11 vectors byte for byte (advertisements, curtain and bulb frames, Bot
password CRCs, the AES-CTR lock frames), the GCM session against swift-crypto, a curtain moved over Bluetooth, sensors
that spend no request, the fallback to the cloud, and a Bot, Curtain 3, Meter and Smart Lock without a token. On a throwaway bridge without an account
it starts and says it has no token.

## Clean-room implementation

Compatible with the configuration of [`@switchbot/homebridge-switchbot`](https://github.com/OpenWonderLabs/homebridge-switchbot)
by SwitchBot and Donavan Becker (ISC). Written from the functional specification in
[docs/clean-room/SwitchBot.md](../../docs/clean-room/SwitchBot.md), its Bluetooth companion
[docs/clean-room/SwitchBotBLE.md](../../docs/clean-room/SwitchBotBLE.md) and SwitchBot's public OpenAPI documentation,
without reading or copying the plugin's or node-switchbot's code.

Maintainer: Mickael Palma.
