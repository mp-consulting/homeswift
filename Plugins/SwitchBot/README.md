# SwitchBot

**Experimental**: written and tested against fakes of SwitchBot's cloud, not yet on the devices.

SwitchBot devices and IR remotes in HomeKit through SwitchBot's cloud ([OpenAPI v1.1](https://github.com/OpenWonderLabs/SwitchBotAPI)),
platform `SwitchBot`.

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
(Bluetooth's, MQTT's, `maxRetries` per device) stay in the list under its `deviceId`.

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

### Webhook

With `options.webhookURL`, the bridge listens on its port and registers the URL with SwitchBot's cloud, its path followed
by a random segment kept in `webhook.json`: only the cloud learns it, and any other path or method is answered `403`.
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
changes; the Blind Tilt's silent switches are two. The humidifier sends `turnOn` before a mode when it was off.
Webhook events match `deviceMac` whatever its spelling.

## Gaps

- **Bluetooth** (`BLE`, `connectionType` `BLE`, `scanDuration`, `encryptionKey`…) is not supported: a device the cloud
  does not serve does not work, and `BLE/OpenAPI` uses the cloud.
- The MQTT relay of webhook events (`mqttURL`) is not implemented.
- Eve history (`history`) is not wired, as in 4.x.
- The Humidifier2's own commands, the Battery Circulator Fan's night light, the air purifiers' speed and mode, and the
  television's remote keys are not sent (their API commands are not specified or are not documented).
- Scenes are not exposed.

## How it was tested

Unit and integration tests with a fake of SwitchBot's cloud (`Tests/Support.swift`): the documentation's signing
vectors, the device list and statuses of the spec's §10, commands, coalesced writes, Adaptive Lighting, No Response, the
request budget, the webhook listener and its events, and the settings' move. On a throwaway bridge without an account
it starts and says it has no token.

## Clean-room implementation

Compatible with the configuration of [`@switchbot/homebridge-switchbot`](https://github.com/OpenWonderLabs/homebridge-switchbot)
by SwitchBot and Donavan Becker (ISC). Written from the functional specification in
[docs/clean-room/SwitchBot.md](../../docs/clean-room/SwitchBot.md) and SwitchBot's public OpenAPI documentation,
without reading or copying the plugin's code.

Maintainer: Mickael Palma.
