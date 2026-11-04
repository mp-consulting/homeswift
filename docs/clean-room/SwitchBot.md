# SwitchBot: functional specification (clean room)

Written by the spec writer; contains no source code. Everything below is a description, in the spec
writer's own words, of observable behaviour and of the wire protocol. Interface identifiers (platform
name, JSON keys, command names, endpoint paths, HomeKit service and characteristic names) are quoted
because they are the interface.

## 0. Provenance

| Source | URL | Ref read | Commit | Licence (holder) |
|---|---|---|---|---|
| Homebridge plugin, 4.x line (the config shape existing users have) | https://github.com/OpenWonderLabs/homebridge-switchbot | tag `v4.3.14` | `c0c76c3b1cffee6ec4417b0f76f27536660a6c64` | ISC, "Copyright (c) 2023 SwitchBot"; package author SwitchBot, contributor Donavan Becker |
| Homebridge plugin, current default branch (5.2.0) | same | `HEAD` | `bd3937a78acb28ef4f3dfa3cbbbc20c9bcbfc9a4` | ISC, "Copyright (c) 2023 SwitchBot" |
| Protocol library used by 4.3.14 (`node-switchbot ^3.6.6`, resolves to 3.6.8) | https://github.com/OpenWonderLabs/node-switchbot | tags `v3.6.8` and `v3.6.6` | `72965a5412173cfde657c45577777d0f749bc687` (3.6.8) | LICENSE file: ISC, "Copyright (c) 2020 SwitchBot"; `package.json` says `MIT` (the two disagree) |
| Protocol library used by 5.x (`node-switchbot ^6`) | same | `HEAD` (6.0.4) | `1306fbb7522b935b9f8b835c8e52de10ee74544e` | as above |
| SwitchBot OpenAPI v1.1 documentation | https://github.com/OpenWonderLabs/SwitchBotAPI | `HEAD` | `dc9a6b0e4ad77882c72d186ecd5d134113acdad0` | no licence file in the repository; public documentation, cited, not copied |

Package names: `@switchbot/homebridge-switchbot` (Homebridge plugin, versions 4.3.14 and 5.2.0),
`node-switchbot` (3.6.8 and 6.0.4).

Which version this spec follows. The configuration blocks users have in their `config.json` today are
almost all in the 4.x shape (`credentials`, `options.devices`, `options.irdevices`, …): that is the
shape the request names, and 5.x still reads it (it maps the 4.x keys onto its own, §2.9). The behaviour
below is therefore that of 4.3.14 talking to the cloud, with the 5.x differences called out where they
matter (identity, write coalescing, request budgeting). Places where 4.3.14 is plainly broken are
described as written and flagged "Defect", with the evident intent, so the implementer can choose.

## 1. Scope for Homeswift

- In scope: the SwitchBot cloud (OpenAPI v1.1) for discovery, status polling and commands; webhooks
  (push from the SwitchBot cloud); the optional MQTT relay of webhook events; IR remotes (virtual
  infrared devices behind a Hub, which only exist in the cloud).
- There is no local LAN API in either plugin version. Physical devices talk to the cloud either over
  Wi-Fi (Plug Mini, Hub 2/3, Ceiling Light, Strip Light, Color Bulb, Robot Vacuum, Air Purifier, Relay
  Switch, Lock via Hub, …) or through a Hub over BLE. The plugin's only non-cloud path is Bluetooth LE.
- BLE (out of scope, gap): §11.

## 2. Configuration interface

### 2.1 Platform block

- `platform`: `"SwitchBot"` (exact; Homebridge plugin alias; the schema marks it singular: one block
  per bridge).
- `name`: string, default `"SwitchBot"`, cosmetic.
- `credentials` (object)
  - `token` (string): the OpenAPI token from the SwitchBot app. **Secret.**
  - `secret` (string): the OpenAPI client secret. **Secret.**
  - `notice` (string, default `"Keep your Token & Secret a secret!"`): UI decoration only. Its only
    effect: when present, the "missing token/secret" debug warnings are not printed.
- `options` (object), every key optional:

| Key | Type | Default (code) | Meaning |
|---|---|---|---|
| `devices` | array | absent | Per-device overrides for physical devices (§2.2). Its presence changes discovery (§4.2). |
| `deviceConfig` | object keyed by OpenAPI `deviceType` (e.g. `"Bot"`, `"Curtain"`, `"Hub 2"`) | absent | Options applied to every discovered device of that type (same keys as §2.2/§2.3). |
| `irdevices` | array | absent | Per-remote overrides for IR remotes (§2.4). Its presence changes discovery. |
| `irdeviceConfig` | object keyed by `remoteType` (e.g. `"TV"`, `"DIY Fan"`, `"Others"`) | absent | Options for every IR remote of that type. Keys in the schema: `hide_device`, `connectionType`, `external`, `disableCaching`, `offline`, `history`, `firmware`, `logging`, `refreshRate`, `updateRate`, `pushRate`. |
| `refreshRate` | number, seconds | 300 | Status polling interval for every device without its own `refreshRate`. Schema placeholder says 360. |
| `updateRate` | number, seconds | 5 | Fast polling interval used while a curtain / blind tilt is moving; BLE scan duration floor. |
| `pushRate` | number, seconds | 0.1 | Debounce window between a HomeKit write and the command being sent (§6.2). |
| `maxRetries` | number | 5 for discovery; 2 for device requests when unset | Attempts per request (§5.6). |
| `delayBetweenRetries` | number | 5000 for discovery, 3000 for device requests (both treated as **milliseconds** at platform level) | Delay between attempts. Defect: the schema documents seconds; per-device values are multiplied by 1000, the platform value is not. |
| `hostname` | string, URL | `https://api.switch-bot.com` | Replaces the API base URL (scheme + host, no path; `/v1.1/...` is appended). |
| `webhookURL` | string, URL | absent | Enables webhooks (§7). The schema placeholder is `http://${FQDN}:${PORT}/${PATH}`. |
| `mqttURL` | string | absent | MQTT broker URL for the webhook relay (§7.5). |
| `mqttOptions` | object (schema shows a string) | `{}` | Options passed to the MQTT connect. |
| `mqttPubOptions` | object (schema shows a string) | `{}` | Options for MQTT publishes. |
| `BLE` | boolean | false | Enable a platform-wide BLE scan (gap, §11). |
| `discoverBLE` | boolean | — | Declared, not used by 4.3.14. |
| `disableLogsforBLE` | boolean | false | Mute the BLE library's log events. |
| `disableLogsforOpenAPI` | boolean | false | Mute the OpenAPI library's log events. |
| `logging` | `"standard"`, `"debug"`, `"none"` | `"standard"` (or debug when Homebridge runs with `-D`) | Platform log level (§9). |
| `allowInvalidCharacters` | boolean | false | Skip the accessory-name cleaning (§4.6). |

### 2.2 `options.devices[]` (physical devices), common keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `deviceId` | string, required | — | SwitchBot device id, normally 12 upper-case hex characters (the BLE MAC without separators), e.g. `81F3UT59513F` is the schema's placeholder. Matching against discovered devices ignores case and every non-alphanumeric character. |
| `configDeviceName` | string | — | Overrides the name from the app. |
| `configDeviceType` | string, one of the OpenAPI device types (§3.1 list) | — | Used only when the cloud reports no type, or with no token (manual mode, §4.3). |
| `hide_device` | boolean | false | Do not expose; a cached accessory for it is removed. |
| `connectionType` | `"OpenAPI"`, `"BLE"`, `"BLE/OpenAPI"`, `"Disabled"` | `"OpenAPI"` when token and secret are both set, otherwise unset | Transport selection (§4.5). |
| `refreshRate`, `updateRate`, `pushRate` | number, seconds | platform value, then 300 / 5 / 0.1 | Per-device overrides. Note: a value of 0 counts as "set" for these three. |
| `maxRetries` | number | platform value, then 2 | OpenAPI attempts. |
| `delayBetweenRetries` | number, **seconds** | platform value (ms), then 3000 ms | Multiplied by 1000. |
| `webhook` | boolean | false | Apply webhook events to this device (§7). The UI only offers it when `options.webhookURL` is set. |
| `offline` | boolean | false | "Offline as Off": when the device cannot be reached by its connection type, show it off/closed/secured (§6.6). |
| `external` | boolean | false | Publish as its own HomeKit accessory instead of on the bridge. |
| `firmware` | string | — | Overrides the reported firmware revision. |
| `logging` | `"standard"`, `"debug"`, `"none"` | platform value | Per-device log level. |
| `disableCaching` | boolean | false | Curtain / Blind Tilt: send the position command even when target equals current. |
| `history` | boolean | false | Eve history; effectively not wired in 4.3.14 (gap). |
| `mqttURL`, `mqttOptions`, `mqttPubOptions` | — | — | Per-device MQTT publishing; dead code in 4.3.14 (§7.5). |
| BLE-only: `disablePlatformBLE`, `scanDuration` (default 1 s), `customBLEaddress`, `maxRetry` (BLE attempts, default 5), `encryptionKey`/`keyId` (5.x) | | | Gap (§11). `encryptionKey` and `keyId` are **secrets**. |

### 2.3 `options.devices[]` per-type keys

| Device type(s) | Key | Type, default | Meaning |
|---|---|---|---|
| Bot, Relay Switch 1, Relay Switch 1PM | `type` | `door`, `fan`, `faucet`, `garagedoor`, `lock`, `outlet`, `stateful`, `switch`, `window`, `windowcovering` (lower case); default see §3.2 | Which HomeKit service represents it. |
| Bot | `mode` | `switch` (default), `press`, `multipress` | Physical mode. Any other value is a configuration error for that device. |
| Bot | `doublePress` | number, 1 | Number of times each command is sent. |
| Bot | `pushRatePress` | number seconds, 15 | Interval between the repeated sends. |
| Bot, Relay Switch | `allowPush` | boolean, false | Send the command even if the state did not change. |
| Meter, MeterPlus, Meter Plus (JP), Meter Pro, MeterPro(CO2), WoIOSensor, Hub 2/Hub Mini 2/Hub 3, Humidifier | `hide_temperature` | boolean | Remove the temperature service. |
| same minus Humidifier | `hide_humidity` | boolean | Remove the humidity service. |
| Meter Pro / MeterPro(CO2) | `hide_co2` | boolean | Remove the CO₂ service (code key; not in the schema). |
| sensors, Humidifier, Hub | `convertUnitTo` | `CELSIUS` or `FAHRENHEIT` | Applied to webhook temperatures only (§6.7). |
| Curtain, Curtain3, Blind Tilt, Contact, Motion, Presence, Hub | `hide_lightsensor` | boolean | Remove the light sensor. |
| same | `set_minLux` / `set_maxLux` | number, 1 / 6001 | Lux reported for the dimmest / brightest level. **The schema writes `set_minlux` and `set_maxlux` (lower-case l); the code reads `set_minLux`/`set_maxLux`, so values saved by the UI are ignored.** Accept both spellings. |
| Contact Sensor | `hide_motionsensor` | boolean | Remove the motion sensor. |
| Smart Lock family | `hide_contactsensor` | boolean | Remove the door contact sensor. |
| Smart Lock family | `activate_latchbutton` | boolean | The "Latch" switch is shown unless this is exactly `false` (so absent shows it). |
| Water Detector | `hide_leak` | boolean | Remove the leak sensor. |
| Water Detector | `dry` | boolean | Invert: report a leak when the device reports dry. |
| Curtain family, Blind Tilt | `set_min`, `set_max` | number 0–100 | Snap thresholds (§6.4). |
| Curtain family, Blind Tilt, Color Bulb, Strip Light, Ceiling Light, Humidifier | `set_minStep` | number, 1 | `minStep` of the position / brightness / humidity threshold. |
| Curtain family, Blind Tilt | `setOpenMode`, `setCloseMode` | `"0"` performance, `"1"` silent | Speed mode for opening (target > 50) / closing. |
| Curtain family, Blind Tilt | `silentModeSwitch` | boolean | Adds two switches to pick silent mode at run time. |
| Curtain, Curtain3, Blind Tilt | `disable_group` | boolean | Expose the secondary curtain of a group too (§4.4). |
| Blind Tilt | `mapping` | `only_up` (default), `only_down`, `down_and_up`, `up_and_down`, `use_tilt_for_direction` | Position mapping (§6.5). |
| Color Bulb, Strip Light, Ceiling Light(s) | `adaptiveLightingShift` | number, 0 | ≥ 0: Adaptive Lighting with that mired shift; −1: disable and remove Adaptive Lighting. |

### 2.4 `options.irdevices[]` (IR remotes)

| Key | Type, default | Meaning |
|---|---|---|
| `deviceId` | string, required | IR remote id, e.g. `02-202008110034-13`. |
| `configDeviceName` | string | Name override. |
| `configRemoteType` | one of the remote types (§3.3) | Used when the cloud reports no `remoteType`. |
| `hide_device` | boolean | Do not expose. |
| `connectionType` | `"OpenAPI"` (default), `"Disabled"` | Commands are sent only when exactly `"OpenAPI"`. |
| `external` | boolean; default **true for every `DIY …` remote type**, false otherwise | Publish as its own accessory. |
| `customize` | boolean | Use learned buttons: commands become `customOn`/`customOff` with `commandType` `customize`. |
| `customOn`, `customOff` | string | Learned button names for on and off. |
| `commandType` | string (schema placeholder `tag`) | With `customize`, overrides the `commandType` sent. |
| `disablePushOn`, `disablePushOff`, `disablePushDetail` | boolean | Suppress the on command / the off command / every other command. |
| `type` (Others only) | `Outlet` default; see §3.3 | Service for an "Others" remote. |
| Fan: `rotation_speed`, `swing_mode` (boolean), `set_minStep` (1), `set_min` (1), `set_max` (100) | | Optional characteristics and their props. |
| Light: `stateless` | boolean | Two stateless buttons instead of a light bulb. |
| Air Conditioner: `hide_automode` (boolean), `set_max_heat` (35), `set_min_heat` (0), `set_max_cool` (35), `set_min_cool` (0), `meterType` (one of `Hub 2`, `Hub Mini 2`, `Meter`, `MeterPlus`, `Meter Plus (JP)`, `Meter Pro`, `MeterPro(CO2)`, `WoIOSensor`, `Humidifier`), `meterId` | | Temperature limits and a linked SwitchBot sensor (§3.3). |
| `refreshRate`, `updateRate`, `pushRate`, `maxRetries`, `delayBetweenRetries`, `firmware`, `logging`, `offline`, `history`, `disableCaching` | as §2.2 | IR remotes have no status, so only the retry and logging keys matter. |

### 2.5 Merge order

For a discovered physical device the effective object is: the OpenAPI device-list entry, then the
`options.deviceConfig[deviceType]` object laid over it (shallow, its keys win), then the matching
`options.devices[]` entry laid over that (its keys win, including `deviceId` as the user typed it).
IR remotes: list entry, then `options.irdeviceConfig[remoteType]`, then the `options.irdevices[]` entry.
Indexing `options.devices` by id is also attempted and has no effect (it is an array).

### 2.6 Validation at start

- A `devices[]` entry not hidden and without `deviceId` stops the plugin with a configuration error.
- A `devices[]` entry with `connectionType` but no `configDeviceType` stops the plugin likewise.
- An `irdevices[]` entry without `deviceId` (or without both id and `configRemoteType`) only logs an error.
- Missing token or secret: debug warning "cloud devices and IR remotes will not work" (not printed
  when `credentials.notice` is set).

### 2.7 Secrets in the configuration

`credentials.token`, `credentials.secret`, and (5.x) `openApiToken`, `openApiSecret`,
`devices[].encryptionKey`, `devices[].keyId`. The webhook URL is not secret by itself but anyone who
learns it can post fake events (§7.4).

### 2.8 Example 4.x block (data)

```json
{
  "platform": "SwitchBot",
  "name": "SwitchBot",
  "credentials": { "token": "<token>", "secret": "<secret>" },
  "options": {
    "refreshRate": 300,
    "pushRate": 0.1,
    "webhookURL": "http://192.168.1.10:8790/switchbot",
    "devices": [
      { "deviceId": "C271111EC0AB", "configDeviceType": "Meter", "webhook": true, "hide_humidity": false },
      { "deviceId": "E2F6032048AB", "configDeviceType": "Curtain", "setOpenMode": "1", "set_minStep": 5 },
      { "deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "type": "switch", "mode": "press" }
    ],
    "irdevices": [
      { "deviceId": "02-202008110034-13", "configRemoteType": "TV", "external": true },
      { "deviceId": "02-202102220012-55", "configRemoteType": "Air Conditioner",
        "meterType": "Meter", "meterId": "C271111EC0AB", "hide_automode": true }
    ]
  }
}
```

### 2.9 The 5.x shape (also accept)

5.x reads a flatter block; when its own keys are absent it takes the 4.x ones:
`openApiToken` ← `credentials.token`, `openApiSecret` ← `credentials.secret`, `enableBLE` ←
`options.BLE`, `openApiRefreshRate` ← `options.refreshRate` (when > 0), `devices` (top level) ←
`options.devices`. 5.x keys: `openApiToken`, `openApiSecret` (secrets), `enableBLE` (default true),
`nodeSwitchBotLogLevel` (0–4, default 2), `co2AbnormalThreshold` (ppm, default 1000, 400–5000),
`writeDebounceMs` (default 100, 0 disables), `openApiRefreshRate` (default 300, minimum 30),
`dailyApiLimit` (default 10000, minimum 1000), `dailyApiReserveForCommands` (default 1000),
`dailyApiResetLocalMidnight` (default false: UTC), `webhookOnlyOnReserve`, `matterBatchEnabled`
(default true), `matterBatchRefreshRate`, `matterBatchConcurrency` (default 5), `matterBatchJitter`
(seconds, default 0), `preferMatter`/`enableMatter` (Homebridge Matter, irrelevant here), and
`devices[]` with `enabled` (default true), `configDeviceName`, `deviceId`, `configDeviceType`,
`botDisplay` (default `switch`; same values as 4.x `type`), `mode` (`''`, `press`, `switch`,
`multipress`), `connectionPreference` (`auto`, `ble`, `openapi`), `room`, `encryptionKey`, `keyId`,
`refreshRate` (default 300, minimum 30). 5.x has no webhooks and no IR remote list of its own. 5.x
exposes only the devices listed in `devices` (the UI writes discovered devices there).

## 3. Device model

### 3.1 Physical device types recognised (OpenAPI `deviceType`, exact strings)

`Humidifier`, `Humidifier2`, `Hub 2`, `Hub Mini 2`, `Hub 3`, `Bot`, `Relay Switch 1`, `Relay Switch 1PM`,
`Meter`, `MeterPlus`, `Meter Plus (JP)`, `Meter Pro`, `MeterPro(CO2)`, `WoIOSensor` (Outdoor Meter),
`Water Detector`, `Motion Sensor`, `Presence Sensor`, `Contact Sensor`, `Curtain`, `Curtain3`,
`WoRollerShade`, `Roller Shade`, `Blind Tilt`, `Plug`, `Plug Mini (US)`, `Plug Mini (JP)`, `Plug Mini (EU)`,
`Smart Lock`, `Smart Lock Pro`, `Smart Lock Ultra`, `Lock Ultra`, `Color Bulb`, `K10+`, `K10+ Pro`,
`WoSweeper`, `WoSweeperMini`, `Robot Vacuum Cleaner S1`, `Robot Vacuum Cleaner S1 Plus`,
`Robot Vacuum Cleaner S10`, `Ceiling Light`, `Ceiling Light Pro`, `Strip Light`,
`Battery Circulator Fan`, `Air Purifier`, `Air Purifier Table`, `Air Purifier VOC`,
`Air Purifier Table VOC`, `Air Purifier PM2.5`, `Air Purifier Table PM2.5`.

Silently skipped (debug log): `Hub Mini`, `Hub Plus`, `Remote`, `Indoor Cam`, `remote with screen`.
Anything else: a warning naming the device and type, not exposed. (5.x adds more types; their names are
in its schema enum: Keypad family, Lock Lite/Vision, Circulator Fan, Standing Circulator Fan, Floor Lamp,
RGBIC lights, Strip Light 3, Smart Radiator Thermostat, Garage Door Opener, Video Doorbell, …; out of
scope for a 4.x drop-in.)

### 3.2 Identity

- **Homebridge accessory UUID seed (4.x)**: physical devices `"<deviceId>-<deviceType>"`; IR remotes
  `"<deviceId>-<remoteType>"`, e.g. `C271111EC0AB-Meter`, `02-202008110034-13-TV`. `deviceId` is the
  id after the merge of §2.5, i.e. the `options.devices[]` spelling if the user listed the device
  (normally identical to the cloud's upper-case 12-hex form), and `deviceType` is the cloud's type (or
  `configDeviceType` when the cloud reports none). In manual mode (no token, §4.3) `deviceId` is first
  reformatted as a colon-separated MAC with the case preserved (`C2:71:11:1E:C0:AB`) and `deviceType` is
  `configDeviceType`, so the seed is e.g. `C2:71:11:1E:C0:AB-Meter`.
- Homebridge turns the seed into a UUID with HAP-NodeJS's `uuid.generate`: the SHA-1 of the UTF-8 seed
  as 40 lower-case hex digits, laid into the pattern `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` taking hex
  digits in order for each `x`/`y` (the literal `4` consumes none), and for the `y` position the digit
  `d` becomes `(d & 3) | 8`. (This is HAP-NodeJS behaviour, stated from the spec writer's knowledge; check
  it against HAP-NodeJS before relying on it.) Worked values in §10.4.
- **5.x seed**: the bare `deviceId` as configured; before creating a new accessory 5.x reuses any
  cached accessory whose stored `deviceId` equals it, so accessories created by 4.x keep their 4.x UUID.
- Changing a device's type (e.g. a Plug reported differently, or `configDeviceType` used in manual
  mode) changes the 4.x seed. The device type is part of the identity.
- Device ids are the stable key across the cloud, webhooks (`context.deviceMac`) and BLE (MAC).
  Webhook events are matched to devices by exact string equality of `context.deviceMac` with the
  device's (merged) `deviceId` (§7.3).
- Services that can appear twice on one accessory carry a subtype only in one case: the Curtain's
  "Silent Open Mode" / "Silent Close Mode" switches use as subtype the UUID generated from the switch's
  name (`"<accessory name> Silent Open Mode"`), so their identity follows the accessory name. Every
  other service is the only one of its type on the accessory (no subtype), except the defects noted in
  §3.4 (Blind Tilt silent switches, IR Light stateless buttons), where 4.x ends up with a single shared
  service.

### 3.3 IR remote types (`remoteType`, exact strings)

TV-like (Television service): `TV`, `DIY TV`, `Projector`, `DIY Projector`, `Set Top Box`,
`DIY Set Top Box`, `IPTV`, `DIY IPTV`, `DVD`, `DIY DVD`, `Speaker`, `DIY Speaker`. Others: `Fan`,
`DIY Fan`, `Air Conditioner`, `DIY Air Conditioner`, `Light`, `DIY Light`, `Air Purifier`,
`DIY Air Purifier`, `Water Heater`, `DIY Water Heater`, `Vacuum Cleaner`, `DIY Vacuum Cleaner`,
`Camera`, `DIY Camera`, `Others`. Other types: warning, not exposed. A remote is exposed only when it
has a `hubDeviceId` and is not hidden.

### 3.4 Services and characteristics per type

Common to every accessory, AccessoryInformation: Manufacturer `SwitchBot`; AppMatchingIdentifier
`id1087374760` (the SwitchBot iOS app); Name and ConfiguredName = the display name; Model = the model
code below (IR: the `remoteType`); SerialNumber and ProductData = `deviceId`; HardwareRevision,
SoftwareRevision and FirmwareRevision = the normalised version (§4.7).

Model codes (physical): Humidifier `W0801800`; Humidifier2 `WXXXXXXX`; Hub 2 and Hub Mini 2 `W3202100`;
Hub 3 `W3302100`; Hub Mini `W0202200`; Hub Plus `SwitchBot Hub S1`; Bot `SwitchBot S1`;
Relay Switch 1 `W5502300`; Relay Switch 1PM `W5502310`; Meter `SwitchBot MeterTH S1`; MeterPlus
`W2301500`; Meter Plus (JP) `W2201500`; Meter Pro `W4900000`; MeterPro(CO2) `W4900010`; WoIOSensor
`W3400010`; Water Detector `W4402000`; Motion Sensor `W1101500`; Presence Sensor `W8200000`; Contact
Sensor `W1201500`; Curtain `W0701600`; Curtain3, WoRollerShade, Roller Shade `W2400000`; Blind Tilt
`W2701600`; Plug `SP11`; Plug Mini (US) `W1901400/W1901401`; Plug Mini (JP) `W2001400/W2001401`; Plug
Mini (EU) `W7732300`; Smart Lock `W1601700`; Smart Lock Pro `W3500000`; Smart Lock Ultra and Lock Ultra
`W3600000`; Color Bulb `W1401400`; K10+ `K10+`; K10+ Pro `K10+ Pro`; WoSweeper `WoSweeper`;
WoSweeperMini `WoSweeperMini`; Robot Vacuum Cleaner S1 `W3011000`; S1 Plus `W3011010`; S10 `W3211800`;
Ceiling Light `W2612230/W2612240`; Ceiling Light Pro `W2612210/W2612220`; Strip Light `W1701100`;
Battery Circulator Fan `W3800510`; Air Purifier (and VOC, PM2.5) `W5302300`; Air Purifier Table (and
Table VOC, Table PM2.5) `W5302310`; anything else `Unknown`.

Names of secondary services: `"<name> Battery"`, `"<name> Temperature Sensor"`, `"<name> Humidity
Sensor"`, `"<name> Light Sensor"`, `"<name> Contact Sensor"`, `"<name> Carbon Dioxide Sensor"`,
`"<name> Latch"`, `"<name> Night Light"`, `"<name> Air Quality"`, `"<name> Speaker"`,
`"<name> Silent Open Mode"`, `"<name> Silent Close Mode"`, `"<name> On"`, `"<name> Off"`.
Low battery means BatteryLevel < 10 everywhere.

#### Bot (`Bot`); Relay Switch 1 / 1PM (same without Battery)

- Battery (Bot only): BatteryLevel, StatusLowBattery, ChargingState fixed NOT_CHARGEABLE.
- One control service chosen by `type`, the others removed:
  `switch` → Switch.On; `outlet` → Outlet.On; `garagedoor` → GarageDoorOpener (TargetDoorState written,
  Current/TargetDoorState shown OPEN when on, CLOSED when off); `door` → Door, `window` → Window,
  `windowcovering` → WindowCovering (TargetPosition written; Current/TargetPosition 100 when on, 0 when
  off; PositionState STOPPED); `lock` → LockMechanism (LockTargetState written; on = UNSECURED,
  off = SECURED); `faucet` → Faucet.Active; `fan` → Fanv2.Active; `stateful` →
  StatefulProgrammableSwitch (ProgrammableSwitchOutputState written; on each update a SINGLE_PRESS event
  and OutputState 1/0).
  "On" requested = value is not the off value of that characteristic (Switch/Outlet: not false;
  garage: not CLOSED; positions/stateful/fan: not 0; lock: not SECURED; faucet: not INACTIVE).
- Default `type`: 4.x falls back to the string `Outlet` (capital O), which matches no entry, so a Bot
  without `type` gets **no control service** (only Battery) in 4.x. 5.x defaults to `switch`.
  Defect; recommended: default `switch` (5.x) and compare `type` case-insensitively.
- Defect: when `type` is `windowcovering`, 4.x removes the WindowCovering service it just created
  (the removal list tests the presence instead of the absence).
- Status: Bot `power` `"on"`/`"off"` → on (always off in `press` mode), `battery` → BatteryLevel;
  Relay `switchStatus` (0/1) → on.
- Commands (§5.4): `switch` mode sends `turnOn`/`turnOff`; `press` and `multipress` send `press` and
  return the control to off. `doublePress` > 1 sends the command that many times every
  `pushRatePress` s. `multipress` (only when no `type` matched) counts the "on" writes received in the
  debounce window and sends that many `press` commands.

#### Curtain, Curtain3, WoRollerShade, Roller Shade

- WindowCovering: CurrentPosition and TargetPosition (0–100, `minStep` = `set_minStep`), PositionState
  (read from memory), HoldPosition (writable), ObstructionDetected fixed false. Initial values 100 (open).
- Battery: BatteryLevel, StatusLowBattery, ChargingState (NOT_CHARGING).
- LightSensor (Curtain and Curtain3 only, unless `hide_lightsensor`): CurrentAmbientLightLevel
  (initial 0.0001), StatusActive true.
- With `silentModeSwitch`: two Switches, "Silent Open Mode" and "Silent Close Mode" (subtype §3.2);
  their state is kept locally and only chooses the speed mode of later moves.
- Position mapping: HomeKit 100 = open; the device's `slidePosition` 0 = open, 100 = closed, so
  HomeKit = 100 − slidePosition and the command position = 100 − target.

#### Blind Tilt

- WindowCovering: TargetPosition/CurrentPosition (0–100, `minStep` = `set_minStep`), Target/
  CurrentHorizontalTiltAngle with props −90..90, `minStep` 180, valid values −90 and 90 (initial 90),
  PositionState. Battery (ChargingState NOT_CHARGEABLE). LightSensor unless `hide_lightsensor`.
- Silent switches as for curtains, but without subtypes: both names resolve to the same single Switch
  service (defect).
- Mapping of positions and tilt: §6.5.

#### Plug, Plug Mini (US/JP/EU)

Outlet.On ← `power == "on"`; writes `turnOn`/`turnOff`. (Plug Mini's `voltage`, `weight` (W),
`electricityOfDay`, `electricCurrent` are ignored by 4.x.)

#### Meter, MeterPlus, Meter Plus (JP), Meter Pro, MeterPro(CO2), WoIOSensor

- Battery (BatteryLevel, StatusLowBattery, NOT_CHARGEABLE).
- TemperatureSensor unless `hide_temperature`: CurrentTemperature, unit Celsius, −273.15..100,
  `minStep` 0.1 (initial 30).
- HumiditySensor unless `hide_humidity`: CurrentRelativeHumidity, `minStep` 0.1 (initial 50).
- MeterPro(CO2) only, unless `hide_co2`: CarbonDioxideSensor, CarbonDioxideLevel (`minStep` 1) ←
  `CO2`; CarbonDioxideDetected ABNORMAL whenever the level is > 0 in 4.x (defect: always abnormal),
  ≥ `co2AbnormalThreshold` (default 1000 ppm) in 5.x. Recommended: 5.x behaviour. 4.x also never
  pushes the CO₂ values (they are only served on read).

#### Hub 2, Hub Mini 2, Hub 3

TemperatureSensor (unless hidden), HumiditySensor (unless hidden), LightSensor (unless hidden,
`minStep` 1). No Battery. Status fields may be at the top level (Hub 2) or under `sensorData`
(Hub 3); both are read. Light level 1–20 is mapped with 19 steps (§6.3). (Hub Mini 2 has no sensors;
4.x still creates the services.)

#### Motion Sensor

MotionSensor.MotionDetected (StatusActive true) ← `moveDetected` / webhook `detectionState ==
"DETECTED"`. Battery. LightSensor unless hidden ← `brightness` `bright`/`dim`.

#### Contact Sensor

ContactSensor.ContactSensorState: `openState` `open` or `timeOutNotClose` → CONTACT_NOT_DETECTED,
`close` → CONTACT_DETECTED. MotionSensor unless `hide_motionsensor` ← `moveDetected` /
`detectionState`. LightSensor unless hidden ← `brightness`. Battery.

#### Presence Sensor

OccupancySensor.OccupancyDetected (StatusActive true) ← `Detected` / webhook `detectionState`.
LightSensor unless hidden: 4.x uses max lux when `lightLevel` (1–20) is truthy, min otherwise
(defect: the level is ignored; the Hub's 19-step mapping fits). Battery.

#### Water Detector

LeakSensor unless `hide_leak`: LeakDetected ← `status` 1 (leak) / 0 (dry) (`dry` inverts);
StatusActive ← `battery != 0` (cloud) or truthiness of webhook `detectionState`. Battery.

#### Smart Lock, Smart Lock Pro, Smart Lock Ultra, Lock Ultra

- LockMechanism: LockTargetState (writable) and LockCurrentState ← `lockState`: `locked` →
  SECURED, anything else (`unlocked`, `jammed`) → UNSECURED. Webhook `lockState` is upper case
  (`LOCKED`, `UNLOCKED`, `JAMMED`). Recommended: map `jammed` to JAMMED (4.x does not).
- ContactSensor unless `hide_contactsensor`: `doorState == "opened"` → CONTACT_NOT_DETECTED, else
  DETECTED.
- Switch "Latch" unless `activate_latchbutton` is `false`: turning it on sends `unlock` immediately
  (not debounced), then the switch is returned to off after 0.5 s. (The API's `deadbolt` command exists
  for Lock Pro; 4.x does not use it.)
- Battery.
- Writes: SECURED → `lock`, UNSECURED → `unlock`.
- In Homeswift, locks are security accessories: writes come only through the confirmed path.

#### Color Bulb, Strip Light, Ceiling Light, Ceiling Light Pro

- Lightbulb: On, Brightness (0–100, `minStep` = `set_minStep`), ColorTemperature (140–500 mired),
  Hue (0–360), Saturation (0–100). The Strip Light and Ceiling Lights get the same five
  characteristics in 4.x.
- Adaptive Lighting: on by default (automatic mode, `adaptiveLightingShift` as the mired shift); with
  shift −1 the Lightbulb service is removed and re-added without the controller.
- Status: `power` `on`/`off`; `brightness` 1–100; `color` `"r:g:b"` → Hue/Saturation (§6.8);
  `colorTemperature` (K) → mired = round(10⁶ / K) clamped to 140–500 (Color Bulb, Ceiling).
- Writes, sent in this order after the debounce: `turnOn`/`turnOff` if On changed; then, only while
  on: `setBrightness` (`"<0-100>"`) if changed, `setColorTemperature` (`"<K>"`, K = round(10⁶ /
  mired)) if changed, `setColor` (`"r:g:b"`, §6.8) if Hue or Saturation changed. A ColorTemperature
  write is dropped when the light is off or the rounded Kelvin (to 100 K, clamped 2000–9000) did not
  change; it also updates Hue/Saturation to the colour of that temperature. A Hue or Saturation write
  sets ColorTemperature to 140.
- Defects in 4.x: Ceiling Light status assigns the `power` string itself to On (should be
  `power == "on"`); Ceiling Light sends Kelvin = 10⁶ × mired (should divide); Ceiling Lights have no
  colour but receive `setColor`; the Strip Light exposes ColorTemperature but its cloud path sends only
  on/off, `setBrightness` and `setColor` (the device has no colour temperature). The API ranges: brightness 1–100, colour temperature 2700–6500 K.

#### Humidifier, Humidifier2

- HumidifierDehumidifier: Active, CurrentRelativeHumidity, WaterLevel (0 when `lackWater`, else
  100), TargetHumidifierDehumidifierState with valid values 0 (HUMIDIFIER_OR_DEHUMIDIFIER, used as
  "auto") and 1 (HUMIDIFIER), CurrentHumidifierDehumidifierState, RelativeHumidityHumidifierThreshold
  (0–100, `minStep` = `set_minStep`).
- TemperatureSensor unless `hide_temperature`.
- Status: Active ← `power == "on"`; humidity clamped 0–100; `auto` true → target auto, current
  HUMIDIFYING, threshold = current humidity; otherwise target HUMIDIFIER, threshold =
  min(`nebulizationEfficiency`, 100), current IDLE when humidity > threshold, INACTIVE when off,
  else HUMIDIFYING.
- Writes: if target is HUMIDIFIER, active, and threshold ≠ current humidity → `setMode` with the
  threshold as parameter (`"0"`…`"100"`); else if target is auto and active → `setMode` `auto`; else if
  inactive → `turnOff`. There is no explicit `turnOn` (the API has one). Setting the threshold while off
  makes it active first. Humidifier2 (evaporative) is treated identically, though its API commands
  differ (gap).

#### Battery Circulator Fan

- Fanv2: Active, RotationSpeed (← `fanSpeed`, 1–100), SwingMode (← `oscillation == "on"`).
- Battery: BatteryLevel, StatusLowBattery, ChargingState (← `chargingStatus == "charging"`).
- Lightbulb "Night Light": On, Brightness. Kept locally only; no command is ever sent for it.
- Writes: `turnOn`/`turnOff` when Active changed; then while active `setWindSpeed` (`"<speed>"`)
  but only when SwingMode changed (defect: should test RotationSpeed) and `setOscillation`
  `on`/`off` when SwingMode changed. The API documents `setNightLightMode` and `setWindMode`, not
  `setOscillation` (gap).

#### Robot vacuums (K10+, K10+ Pro, WoSweeper, WoSweeperMini, Robot Vacuum Cleaner S1, S1 Plus, S10)

- Lightbulb (named as the accessory): On ← `onlineStatus == "online"` (sic), Brightness with valid
  values 0, 25, 50, 75, 100.
- Battery: level, low, ChargingState ← `workingStatus == "Charging"`.
- Writes: On → `start`, off → `dock`. The brightness → `PowLevel` 0–3 mapping exists but is never
  called in 4.x (25→0, 50→1, 75→2, 100→3, 0→`dock`).

#### Air Purifier family (VOC, PM2.5, Table variants)

- AirPurifier: Active ← `power == "on"`; CurrentAirPurifierState PURIFYING_AIR when on, INACTIVE
  when off; TargetAirPurifierState AUTO when `mode == 0`, else MANUAL; RotationSpeed 0 in auto,
  else round(mode / 3 × 100); LockPhysicalControls ← `childLock == 1`.
- AirQualitySensor "Air Quality": AirQuality (UNKNOWN), PM2_5Density (0); not fed from the cloud.
- Writes: only `turnOn`/`turnOff`. Speed and target state writes are stored, never sent.
- Webhook handler registered but does nothing.

#### IR TV-like remotes

- Television: Active (writable), ActiveIdentifier (1), SleepDiscoveryMode ALWAYS_DISCOVERABLE,
  ConfiguredName, RemoteKey (writable). Category: SPEAKER for Speaker types, TV_STREAMING_STICK for
  IPTV, TV_SET_TOP_BOX for DVD and Set Top Box, TELEVISION otherwise.
- TelevisionSpeaker: Active ACTIVE, VolumeControlType ABSOLUTE, VolumeSelector (writable):
  INCREMENT → `volumeAdd`, DECREMENT → `volumeSub`.
- Active ACTIVE → on command, INACTIVE → off command (§5.5).
- RemoteKey writes are only logged in 4.x (the `Up`/`Down`/`Left`/`Right`/`Ok`/`Back`/`Menu` sends are
  disabled).
- No input sources.

#### IR Fan

Fanv2.Active (on/off commands). With `swing_mode`: SwingMode; a write sends the on command then
`swing`. With `rotation_speed`: RotationSpeed (`minStep`, min, max from config); an increase sends
`highSpeed` then the on command, a decrease `lowSpeed`. Without them those characteristics are removed.

#### IR Light

Default: Lightbulb.On → on/off commands. With `stateless`: two StatefulProgrammableSwitch buttons
"On" and "Off" (ProgrammableSwitchEvent limited to SINGLE_PRESS; OutputState 1 sends the on resp. off
command). Defect: both get the same service (no subtype).

#### IR Air Conditioner

- HeaterCooler: Active, CurrentTemperature, TargetHeaterCoolerState (valid values 0 AUTO, 1 HEAT,
  2 COOL; without AUTO when `hide_automode`), CurrentHeaterCoolerState, Heating- and
  CoolingThresholdTemperature (both the same value; props from `set_min_heat`/`set_max_heat` and
  `set_min_cool`/`set_max_cool`, `minStep` 0.5), RotationSpeed (int 1–4). Defaults: temperature 24,
  threshold 24, speed 4.
- Linked sensor: with `meterType` and `meterId`, the accessory whose 4.x UUID is generated from
  `"<meterId>-<meterType>"` is looked up; CurrentTemperature reads that accessory's last temperature,
  and 4.x adds a HumiditySensor service **to the meter's accessory** fed from its last humidity.
- Writes: Active on → on command (or, with `disablePushOn`, a `setAll`); off → off command.
  Mode, threshold or speed writes are collected for 1.5 s, then one `setAll` with parameter
  `"<temp>,<mode>,<fan>,<on|off>"`: mode AUTO → 1 (threshold forced to 25), COOL → 2, HEAT → 5;
  HomeKit speed 4 → fan 1 (auto), 1 → 2 (low), 2 → 3 (medium), 3 → 4 (high). `disablePushDetail`
  suppresses every command here.
- CurrentHeaterCoolerState is derived: inactive → INACTIVE; threshold < current and target ≠ HEAT →
  COOLING; threshold > current and target ≠ COOL → HEATING; else IDLE.

#### IR Air Purifier, Water Heater, Vacuum Cleaner, Camera

Air Purifier: AirPurifier (Active, Current/TargetAirPurifierState) plus a TemperatureSensor
(24, never fed); Active → on/off commands. Water Heater: Valve.Active → on/off. Vacuum Cleaner and
Camera: Switch.On → on/off (categories OTHER and CAMERA).

#### IR Others

One service from `type`, compared **case-sensitively** against `Switch`, `GarageDoor`, `Door`,
`Window`, `WindowCovering`, `Lock`, `Faucet`, `Fan`, `Stateful`, `Outlet` (default `Outlet`). The
schema offers the lower-case values (`switch`, `garagedoor`, …), which match nothing in 4.x, leaving
the accessory without a control service (defect; recommended: compare case-insensitively). Commands are
sent only with `customize` true (learned buttons); without it the write only logs an error.

## 4. Discovery and lifecycle

### 4.1 Start

On launch, with a token: request the device list, retrying up to `maxRetries` (5) times; on HTTP 500
wait `delayBetweenRetries` (5000 ms) between tries; on exceptions retry immediately. A response counts as
successful when the HTTP status is 200 or the code is 100. Then physical devices, then IR remotes.

### 4.2 Which devices are exposed (4.x)

- No `options.devices` and no `options.deviceConfig`: every listed device with a `deviceType`.
- Otherwise: **only the devices listed in `options.devices`**, merged with their list entries (§2.5).
  Consequences as written: with only `deviceConfig` set, nothing is exposed; a device listed in the
  config but absent from the cloud list gets no type and is reported unsupported.
- IR remotes: the same rule with `irdevices`/`irdeviceConfig`. A cloud remote with no `remoteType` and
  no `configRemoteType` is skipped with an error.
- Cached accessories that are not re-announced are left in the cache (4.x does not prune them, except
  hidden or unregistrable physical devices, which are removed).

### 4.3 No token (manual mode)

The `options.devices` entries are created from the config alone (`deviceType` = `configDeviceType`,
`deviceName` = `configDeviceName`, id reformatted as a MAC, §3.2). Only BLE could reach them; on
Homeswift (no BLE) they cannot work. If `devices` is also absent: error "neither token nor device config".

### 4.4 Registration rules

- `connectionType` defaults to `OpenAPI` when token and secret are present.
- A physical device is exposed when not `hide_device` and its connection type is `OpenAPI`,
  `BLE/OpenAPI` or `Disabled`, or `BLE` with `deviceId`, `configDeviceType` and `configDeviceName`
  all set.
- Curtain, Curtain3, Blind Tilt (not Roller Shade): exposed when master of a group, or master not in a
  group, or not master with `disable_group`, or over BLE. A group's secondary curtain is otherwise
  hidden (the master drives the group). List entries carry `master`, `group`, `curtainDevicesIds` /
  `blindTiltDevicesIds`.
- A cached accessory whose device now fails these rules is unregistered.
- IR remotes: exposed when not hidden and `hubDeviceId` is present.
- `external` (or a `DIY` remote type) publishes the accessory on its own instead of on the bridge.

### 4.5 Connection type and cloud service

- `OpenAPI` / `BLE/OpenAPI`: cloud polling and commands (`BLE/OpenAPI` prefers BLE, falls back to
  the cloud on BLE failure; on Homeswift that is the cloud).
- When the list entry says `enableCloudService: false` and the transport is the cloud, refreshes and
  commands are skipped (debug log). Devices created from config alone have no such field and are
  therefore skipped too over the cloud.
- `Disabled` (or no usable transport): no requests; "Offline as Off" applies (§6.6).

### 4.6 Display name

`configDeviceName`, else the app's `deviceName`. Unless `allowInvalidCharacters`: when the name is not
"letters/digits, then letters/digits/spaces/apostrophes, ending in a letter or digit" (Unicode-aware),
warn, remove every character that is not a letter, digit, space or apostrophe, then strip leading and
trailing non-alphanumerics.

### 4.7 Firmware revision

Source: `firmware` (config) → list `version` → cached value → the plugin's own version → `0.0.0`.
Normalisation: drop a leading `V` and everything from the first `-`; if no `.` remains, put a `.`
between every character (`V31` → `3.1`, `V4.2-1` → `4.2`). Later status responses carrying `version`
update Hardware and Firmware revision with the first step only (Blind Tilt also does the dot step).

## 5. OpenAPI v1.1

### 5.1 Base and headers

Base `https://api.switch-bot.com` (or `options.hostname`), prefix `/v1.1`. Every request carries:

- `Authorization`: the token.
- `t`: current time in milliseconds since the epoch, 13 decimal digits.
- `nonce`: a fresh random UUID string per request (version 4, lower-case with dashes).
- `sign`: base64 (standard alphabet, padded) of HMAC-SHA256 with key = the secret's UTF-8 bytes over the
  UTF-8 string token ∥ t ∥ nonce (plain concatenation, no separators).
- `Content-Type: application/json` (also sent on GET).

The documentation's prose says to upper-case the signature, but its own examples and the plugin send it
as is; the plugin's form is the one known to work. Tokens are sent unmodified. Worked vectors: §10.1.

### 5.2 Endpoints

| Purpose | Method and path | Body |
|---|---|---|
| Device list | `GET /v1.1/devices` | — |
| Device status | `GET /v1.1/devices/{deviceId}/status` | — |
| Command | `POST /v1.1/devices/{deviceId}/commands` | `{"command": …, "parameter": …, "commandType": "command" \| "customize"}` |
| Scene list | `GET /v1.1/scenes` | — (not used by the plugin) |
| Run scene | `POST /v1.1/scenes/{sceneId}/execute` | — (not used by the plugin) |
| Set up webhook | `POST /v1.1/webhook/setupWebhook` | `{"action":"setupWebhook","url":…,"deviceList":"ALL"}` |
| Query webhook | `POST /v1.1/webhook/queryWebhook` | `{"action":"queryUrl"}` or `{"action":"queryDetails","urls":[…]}` |
| Update webhook | `POST /v1.1/webhook/updateWebhook` | `{"action":"updateWebhook","config":{"url":…,"enable":true}}` |
| Delete webhook | `POST /v1.1/webhook/deleteWebhook` | `{"action":"deleteWebhook","url":…}` |

Every response is `{"statusCode": <int>, "message": <string>, "body": <object|array>}`.
The list body has `deviceList` (objects with `deviceId`, `deviceName`, `deviceType`,
`enableCloudService`, `hubDeviceId`, and per type `master`, `group`, `calibrate`, `openDirection`,
`curtainDevicesIds`, `blindTiltDevicesIds`, `direction`, `slidePosition`, `lockDevicesIds`,
`groupName`, `version`) and `infraredRemoteList` (`deviceId`, `deviceName`, `remoteType`,
`hubDeviceId`). `hubDeviceId` `000000000000` means the device has no hub (Wi-Fi).

### 5.3 Response codes and handling

| Code | Meaning | Plugin handling |
|---|---|---|
| 100 | success | proceed (HTTP 200 is also accepted as success) |
| 151 | command not supported by this device type | error log |
| 152 | device not found | error log |
| 160 | command not supported | error log |
| 161 | device offline | error log |
| 171 | hub offline | error log (IR: reported as 161 when the hub id equals the remote id or is all zeros) |
| 190 | device internal error / states not synchronised / command format invalid; the list endpoint also returns it as "system error" | error log |
| HTTP 401 `{"message":"Unauthorized"}` | bad token or signature, **and also what the API returns once the 10,000 daily calls are used up** | error log |
| HTTP 400, 403, 404, 406, 415, 422, 429, 500 | standard | error log; discovery retries on 500 |

No failure code changes HomeKit state; only exceptions do (§6.6). The plugin never backs off on
190/429 beyond the retry loop.

Defect worth knowing: in 4.3.14 with node-switchbot 3.6.x the status call hands the plugin the inner
`body` and the plugin then looks for `statusCode` inside it, so polled values are discarded (5.1.0's
changelog fixes "push polled values to HomeKit instead of discarding them"). The intent, which this spec
describes, is: code 100 → parse the body.

### 5.4 Physical device commands used

`parameter` is `"default"` unless stated.

| Device | Commands |
|---|---|
| Bot | `turnOn`, `turnOff`, `press` |
| Relay Switch 1 / 1PM, Plug, Plug Mini | `turnOn`, `turnOff` (API also has `toggle`) |
| Curtain family | `setPosition` with `"0,<mode>,<position>"`: index 0, mode `1` (silent) or `ff` (default; performance mode 0 is never sent because 0 falls back to `ff`), position 0 = open … 100 = closed; `pause` for HoldPosition (API also: `turnOn` = open, `turnOff` = close) |
| Blind Tilt | `fullyOpen` (mapped position 100), `closeUp` / `closeDown` (position 0 with direction up / down), `setPosition` with `"<up\|down>;<position>"` (API: position must be even; 4.x does not round) |
| Smart Lock family | `lock`, `unlock` (API: `deadbolt` on Lock Pro) |
| Color Bulb, Strip Light, Ceiling Light(s) | `turnOn`, `turnOff`, `setBrightness` `"1-100"`, `setColor` `"r:g:b"` (0–255 each), `setColorTemperature` `"2700-6500"` |
| Humidifier | `turnOff`, `setMode` with `auto` or `0`…`100` (API also `101`/`102`/`103` = 34/67/100 % atomisation, and `turnOn`) |
| Battery Circulator Fan | `turnOn`, `turnOff`, `setWindSpeed` `"1-100"`, `setOscillation` `on`/`off` (not in the API document; the API documents `setNightLightMode` `off`/`1`/`2`, `setWindMode` `direct`/`natural`/`sleep`/`baby`, `closeDelay`) |
| Robot vacuums | `start`, `dock` (API: `stop`, `PowLevel` 0–3) |
| Air Purifiers | `turnOn`, `turnOff` |

### 5.5 IR commands used

- On: `turnOn`, off: `turnOff`, `commandType` `command`; with `customize`: `customOn`/`customOff` and
  `commandType` = `commandType` from config, else `customize`. `disablePushOn`/`disablePushOff` suppress
  them. Commands are sent only when the remote's `connectionType` is exactly `OpenAPI`.
- TV-like: `volumeAdd`, `volumeSub` (suppressed by `disablePushDetail`). API also: `SetChannel`
  (channel number), `channelAdd`, `channelSub`, `setMute`, `FastForward`, `Rewind`, `Next`,
  `Previous`, `Pause`, `Play`, `Stop` (unused).
- Fan: `swing`, `lowSpeed`, `highSpeed` (API also `middleSpeed`, `timer`).
- Air Conditioner: `setAll` `"<°C>,<mode>,<fan>,<on|off>"`; API modes 0/1 auto, 2 cool, 3 dry, 4 fan,
  5 heat; fan 1 auto, 2 low, 3 medium, 4 high.
- Light: API also `brightnessUp`, `brightnessDown` (unused).
- Others: learned button names only, `commandType` `customize`.

### 5.6 Retries

Status and command requests: up to `maxRetries` attempts (device default 2) **only when the request
throws** (network error, unparseable body), waiting `delayBetweenRetries` (3 s default) after each
failure; when all attempts throw, the result is treated as HTTP 500 with an empty body. API codes other
than 100 are not retried. The webhook setup request itself retries 3 times with 1 s, 2 s waits.

### 5.7 Rate limit and polling budget

- The API allows 10,000 calls per account per day; past that it answers 401 "Unauthorized".
- 4.x has no budget: each physical device polls its status every `refreshRate` (300 s → 288 calls per
  device per day, so about 34 devices exhaust the quota), plus one refresh 15 s after every command
  burst, plus fast polling every `updateRate` (5 s) while a curtain or blind tilt is moving, plus the
  commands. IR remotes never poll. Webhooks do not reduce polling in 4.x.
- 5.x adds a budget: a daily counter of poll requests, reset at UTC midnight + 1 s (or local midnight
  + 1 s with `dailyApiResetLocalMidnight`); polling is skipped while counter + reserve
  (`dailyApiReserveForCommands`, 1000) ≥ `dailyApiLimit` (10000, minimum 1000), with a warning unless
  `webhookOnlyOnReserve`; devices with their own `refreshRate` (minimum 30 s) poll on their own timers,
  the rest in one batch every `openApiRefreshRate` (300 s, minimum 30 s), at most 5 at a time, with an
  optional random initial delay of up to `matterBatchJitter` s. Commands are not counted.

## 6. Behaviour

### 6.1 Polling

At start every physical device fetches its status once; then every `refreshRate` seconds, skipped while a
write is in flight. A successful status updates the in-memory values and pushes every characteristic to
HomeKit (values `undefined`/`null` are not pushed). Reads (`onGet`) return the in-memory value
immediately; they never trigger requests. After any command, one refresh is scheduled 15 s later (and
deferred while another write is in flight).

### 6.2 Write coalescing

- 4.x: each accessory has one debounce: every HomeKit write updates the in-memory target and restarts a
  timer of `pushRate` seconds (default 0.1 s); when it fires, the accessory compares the targets with
  the last values it reported to HomeKit and sends only the commands for what changed (in a fixed order
  per type, §3.4). "Last reported" is updated when a characteristic is pushed, so a failed command
  leaves the difference in place. `allowPush` (Bot, Relay) and `disableCaching` (curtain, blind tilt)
  bypass the comparison. While the debounce is pending or a push runs, polling ticks are skipped.
  IR remotes send immediately (no debounce), except the Air Conditioner's 1.5 s `setAll` window.
- 5.x: commands to the same device and the same command group within `writeDebounceMs` (100 ms) are
  merged, last write wins, every caller gets the result of the one request sent. `turnOn`, `turnOff`
  and `toggle` form one group (`power`); every other command is its own group.

### 6.3 Light level

Given level L, a minimum lux m (`set_minLux`, 1), maximum M (`set_maxLux`, 6001) and a number of steps
S: L = 1 gives m, L = S + 1 gives M, other levels give (M − m) / S × (L − 1). Hub (levels 1–20) uses
S = 19. Curtain, Blind Tilt, Motion and Contact report `bright`/`dim`: 4.x feeds M or m as L with S = 2,
so `dim` gives m but `bright` gives (M − m) / 2 × (M − 1) (18,000,000 with defaults, beyond HomeKit's
100,000 maximum) — defect; the evident intent is `bright` → M, `dim` → m. HomeKit's minimum is 0.0001.

### 6.4 Curtain movement and thresholds

- Setting TargetPosition clears HoldPosition, sets PositionState INCREASING (target > current),
  DECREASING (target < current) or STOPPED, flags "new target" for `updateRate` seconds and starts the
  debounce. HoldPosition true sends `pause`.
- Speed mode: target > 50 uses the open mode, else the close mode; silent when the config mode is
  `"1"` or the matching silent switch is on.
- On each status: CurrentPosition = 100 − `slidePosition`; while "new target" or `moving` the
  PositionState follows the comparison and fast polling (every `updateRate` s) runs; otherwise
  TargetPosition is set to CurrentPosition and PositionState STOPPED.
- Thresholds (curtains): if `set_min` is set and current ≥ `set_min`, current becomes 100; if `set_max`
  is set and current ≤ `set_max`, current becomes 0. Blind Tilt: current ≤ `set_min` → 0; current ≥
  `set_max` → 100.
- Webhook (curtain): `slidePosition` and `battery` as for the status.

### 6.5 Blind Tilt mapping

Device: `direction` (`up`/`down`) and `slidePosition` p (0–100, 0 closed, 100 open as a HomeKit-like
openness in the API's own terms for commands). HomeKit position h, tilt angle a.

| `mapping` | device → HomeKit | HomeKit → command (direction; position) |
|---|---|---|
| `only_up` (default) | p < 50 → h = 100; else h = 100 − 2(p − 50) | (`up`; h) |
| `only_down` | p > 50 → h = 100; else h = 2p | (`down`; h) |
| `down_and_up` | h = p | h ≤ 50 → (`down`; 100 − 2h); else (`up`; 2(h − 50)) |
| `up_and_down` | h = 100 − p | h ≤ 50 → (`up`; 2h); else (`down`; 100 − 2h) — gives negative values for h > 50 (defect; evidently 200 − 2h) |
| `use_tilt_for_direction` | p ≤ 50 → h = 2p, a = −90; else h = 100 − 2(p − 50), a = 90 | a ≤ 0 → (`down`; h); else (`up`; h) |

Then: mapped position 100 → `fullyOpen`; 0 → `closeUp` or `closeDown` by direction; otherwise
`setPosition`. Tilt is only shown and compared with `use_tilt_for_direction`, where the current angle is
snapped to −90 or 90. The webhook's `version` updates the firmware revision.

### 6.6 Unreachable and offline

- When a status or command request throws (after retries), every characteristic of the accessory's
  main services is set to an error, which HomeKit shows as "No Response" until the next good update.
  API error codes (161 offline, 171 hub offline, 190) do not do this; they are only logged.
- "Offline as Off" (`offline: true`) applies when the device has no usable transport (connection type
  `Disabled`, or cloud without token): switches/outlets/lights/fans off, positions 0 (Bot-like types) or
  100 (curtains, open), locks SECURED, contact DETECTED, motion/occupancy not detected, leak not
  detected, humidifier INACTIVE, meters 30 °C / 50 % / battery 100.

### 6.7 Temperature units

Status temperatures are Celsius. Webhooks carry `scale` (`CELSIUS` or `FAHRENHEIT`). 4.x converts only
when `scale` and `convertUnitTo` are equal: both `CELSIUS` → °C to °F, rounded to an integer; both
`FAHRENHEIT` → °F to °C rounded to 0.5. Otherwise the value is used as is (so a Fahrenheit webhook
without `convertUnitTo` is stored as Celsius). HomeKit wants Celsius; recommended: convert whenever
`scale` is `FAHRENHEIT`, and honour `convertUnitTo: "FAHRENHEIT"` as the 4.x behaviour for users who set it.

### 6.8 Colour conversions

- `r:g:b` → Hue/Saturation: the HSV hue (degrees, rounded, 0–360) and saturation (max − min) / max
  × 100 (rounded) of the 0–255 channels; value is dropped.
- Hue/Saturation → `r:g:b`: HSV with value 1 scaled to 255; then, when the red channel is 255, green
  and blue are multiplied by 0.8, and both set to 0 if both are then ≤ 25; channels rounded.
- ColorTemperature → Hue/Saturation for the display: a lookup over 140–500 mired; HAP-NodeJS's
  colour-temperature conversion is an equivalent in spirit (exact table not reproduced).

## 7. Webhooks

### 7.1 Registration

With `options.webhookURL` set and a token:

1. Listen for HTTP on all interfaces on the URL's port (80 when the URL has none). The cloud must be
   able to reach this URL from the Internet (port forwarding, a tunnel or a reverse proxy).
2. `setupWebhook` with the URL and `deviceList` `ALL` (any non-100 answer is logged; it usually means a
   webhook URL is already registered, in which case the next step replaces it).
3. `updateWebhook` with `{url, enable: true}`.
4. `queryWebhook` `queryUrl` and log the registered URL (`body.urls[0]`).
5. On shutdown `deleteWebhook` with the URL, then close the listener.

The SwitchBot cloud keeps a single webhook URL per account; registering one here replaces any other
integration's URL.

### 7.2 Receiving

A `POST` whose request path (including any query string) equals the URL's path is answered `200`,
`text/plain`, body `OK`, and the JSON body is parsed (4.x parses the first received chunk only; read the
whole body). Any other method or path is answered `403`, body `NG`. There is no authentication, signature
or source check.

### 7.3 Dispatch

The event is `{"eventType": "changeReport", "eventVersion": "1", "context": {…}}`. The handler is chosen
by `context.deviceMac` (upper-case 12 hex, same as `deviceId`) and runs only for devices with
`webhook: true`. It updates in-memory values and pushes them to HomeKit as a status would. Common context
keys: `deviceType` (internal names such as `WoHand`, `WoCurtain`, `WoCurtain3`, `WoMeter`,
`WoMeterPlus`, `WoIOSensor`, `WoPresence`, `WoContact`, `WoLock`, `WoLockPro`, `WoBulb`, `WoStrip`,
`WoCeiling`, `WoCeilingPro`, `WoPlugUS`, `WoPlugJP`, `WoPlugEU`, `WoSweeper`, `WoSweeperMini`,
`WoHub2`, `WoFan2`, `WoRollerShade`, `Water Detector`, …; not used for dispatch), `deviceMac`,
`timeOfSample` (ms).

### 7.4 Payload fields used per type

| Device | Fields |
|---|---|
| Bot | `power` `on`/`off`, `battery`, `deviceMode` `pressMode`/`switchMode`/`customizeMode` (replaces the Bot mode in 4.x memory) |
| Curtain, Curtain3 | `slidePosition` 0–100, `battery`, `calibrate`, `group` |
| Blind Tilt | `direction`, `slidePosition`, `battery`, `version`, `calibrate`, `group` |
| Meter, MeterPlus, Meter Pro, MeterPro(CO2), WoIOSensor | `temperature`, `humidity`, `scale`, `battery`, `CO2` (CO2 model) |
| Hub 2 / 3 | `temperature`, `humidity`, `lightLevel` 1–20, `scale` |
| Motion | `detectionState` `DETECTED`/`NOT_DETECTED`, `battery` (4.x uses only the detection) |
| Presence | `detectionState`, `battery`, `lightLevel` (4.x uses only the detection) |
| Contact | `detectionState` (motion), `openState` `open`/`close`/`timeOutNotClose`, `brightness`, `doorMode` `IN_DOOR`/`OUT_DOOR`, `battery` |
| Water Detector | `detectionState` 0 dry / 1 leak, `battery` |
| Lock family | `lockState` `LOCKED`/`UNLOCKED`/`JAMMED`, `battery` (4.x uses only `lockState`) |
| Plug, Plug Mini | `powerState` `ON`/`OFF` |
| Relay Switch 1 / 1PM | `switchStatus` 0/1, `online`, `overTemperature`, `overload` (1PM) |
| Color Bulb | `powerState`, `brightness`, `color` `r:g:b`, `colorTemperature` (K) |
| Strip Light | `powerState`, `brightness`, `color` |
| Ceiling Light(s) | `powerState`, `brightness`, `colorTemperature` |
| Humidifier(2) | `temperature`, `humidity`, `scale` (4.x updates humidity and temperature only) |
| Battery Circulator Fan | `powerState`, `oscillation` `on`/`off`, `fanSpeed` 1–100, `battery`, `chargingStatus` `charging`/`uncharged`, `version`, `mode`, `nightStatus`, `verticalOscillation` |
| Robot vacuums | `workingStatus` (`Standby`, `Clearing`, `Paused`, `GotoChargeBase`, `Charging`, `ChargeDone`, `Dormant`, `InTrouble`, `InRemoteControl`, `InDustCollecting`), `onlineStatus`, `battery`; S10 also `waterBaseBattery`, `taskType` |
| Air Purifiers | `power`, `mode`, `childLock` (4.x ignores them) |

### 7.5 MQTT relay (optional)

- With `mqttURL` and no `webhookURL`: connect to the broker, subscribe to
  `homebridge-switchbot/webhook/+`, and treat each message as a webhook `context` object (JSON),
  dispatched by its `deviceMac`.
- With both: every received webhook's `context` is also published to
  `homebridge-switchbot/webhook/<mac>`, where `<mac>` is the `deviceMac` in lower case with `:` every
  two characters (`c2:71:11:1e:c0:ab`), using `mqttPubOptions`.
- Per-characteristic publishing (`homebridge-switchbot/<deviceType>/<mac>[/…]`) exists in 4.x but never
  runs (the per-device client is never connected); not required.

## 8. Edge cases

- Device ids are compared case- and punctuation-insensitively when merging config with the cloud list,
  but webhooks match exactly; a config id typed in another spelling breaks webhooks for that device and
  changes the 4.x identity seed.
- `hubDeviceId` absent on an IR remote → not exposed. IR remotes have no status: their HomeKit state is
  whatever was last written.
- Battery-less Wi-Fi devices (Plug, Hub, lights) report no `battery`; 4.x tests for the key on
  Meter Pro only, elsewhere it assumes it.
- A Bot in press mode always reads off; a webhook `deviceMode` can switch the in-memory mode.
- A command answered with a non-100 code leaves HomeKit at the requested value until the next refresh
  (15 s later) corrects it.
- The cloud may answer status with `statusCode` 190 for BLE-only devices whose hub lost them.
- Group curtains: commands go to the master id; the cloud moves the group.
- Shutdown deletes the webhook; a crash leaves it registered (harmless; it is replaced next start).

## 9. Logging (paraphrased)

- Levels: `standard` (info, warnings, errors), `debug` (adds debug lines at info level, prefixed
  `[DEBUG]`), `none` (silent). Homebridge debug mode (`-D`) forces debug output at debug level. Device
  lines are prefixed with the device type and display name; IR lines with the remote type and name.
- Start: plugin version, the rates in use, whether each comes from the device, platform or default;
  "Restoring existing accessory from cache: <name> deviceId: <id>" or "Adding new accessory: …" /
  "Loading external accessory: …"; "Removing existing accessory from cache: <name>"; unsupported types
  with a link to file a feature request; secondary group curtains named as such.
- Requests: on error, a message from the §5.3 table with the code; on 100, a debug line. Debug output
  includes full device-list and status JSON (device ids, names, positions; no secrets).
- Webhook: "listening webhook on <url>", failures of each setup step with HTTP and API codes, invalid
  requests (method and path), received bodies at debug level.
- Leak detected is logged as a warning.
- Secrets: token, secret (and 5.x BLE `encryptionKey`/`keyId`). node-switchbot 3.x logs the token at
  debug level when it starts — Homeswift must not. The `sign` and `nonce` headers are not secrets but
  need not be logged. Treat the webhook URL as sensitive (it is an unauthenticated entry point).

## 10. Test vectors (computed by the spec writer from the documented algorithm)

### 10.1 Signing

1. token `yourtoken`, secret `yoursecret`, t `1700000000000`, nonce `requestID`.
   String to sign `yourtoken1700000000000requestID`.
   HMAC-SHA256 (hex) `b941f89e6592ee516ed62b62abec15f60eefbc0a77bc51cb916a63991a583c6d`.
   `sign` = `uUH4nmWS7lFu1itiq+wV9g7vvAp3vFHLkWpjmRpYPG0=`
   (upper-cased variant from the documentation's prose, for a negative test:
   `UUH4NMWS7LFU1ITIQ+WV9G7VVAP3VFHLKWPJMRPYPG0=`).
2. token = the 96 characters `0123456789abcdef` repeated six times, secret
   `fedcba9876543210fedcba9876543210`, t `1730700000123`, nonce `5f1c2b9e-1d2a-4c3b-9e8f-7a6b5c4d3e2f`.
   HMAC (hex) `fa395b2e86c66d4abe49b48bb65b0151cc96b3f62c9b46210feaee22843c5f6a`.
   `sign` = `+jlbLobGbUq+SbSLtlsBUcyWs/Ysm0YhD+ruIoQ8X2o=`.

Headers for vector 1: `Authorization: yourtoken`, `t: 1700000000000`, `nonce: requestID`,
`sign: uUH4nmWS7lFu1itiq+wV9g7vvAp3vFHLkWpjmRpYPG0=`, `Content-Type: application/json`.

### 10.2 Device list (data)

```json
{
  "statusCode": 100,
  "message": "success",
  "body": {
    "deviceList": [
      { "deviceId": "C271111EC0AB", "deviceName": "Office Meter", "deviceType": "Meter",
        "enableCloudService": true, "hubDeviceId": "FA7310762361" },
      { "deviceId": "E2F6032048AB", "deviceName": "Living Curtain", "deviceType": "Curtain",
        "enableCloudService": true, "hubDeviceId": "FA7310762361", "calibrate": true,
        "group": false, "master": true, "openDirection": "left", "curtainDevicesIds": ["E2F6032048AB"] },
      { "deviceId": "D1A2B3C4D5E6", "deviceName": "Coffee Bot", "deviceType": "Bot",
        "enableCloudService": true, "hubDeviceId": "FA7310762361" },
      { "deviceId": "6055F92F0A1B", "deviceName": "Desk Plug", "deviceType": "Plug Mini (US)",
        "enableCloudService": true, "hubDeviceId": "000000000000" },
      { "deviceId": "FA7310762361", "deviceName": "Hub", "deviceType": "Hub 2",
        "enableCloudService": true, "hubDeviceId": "000000000000" }
    ],
    "infraredRemoteList": [
      { "deviceId": "02-202008110034-13", "deviceName": "Living Room TV", "remoteType": "TV",
        "hubDeviceId": "FA7310762361" },
      { "deviceId": "02-202102220012-55", "deviceName": "Bedroom AC", "remoteType": "Air Conditioner",
        "hubDeviceId": "FA7310762361" }
    ]
  }
}
```

With no `options.devices`, all five physical devices and both remotes are exposed (the Hub 2 as a
temperature/humidity/light sensor). With §2.8's config, only the Meter, Curtain and Bot, plus both
remotes.

### 10.3 Status responses (data) and expected HomeKit values

- Meter `{"statusCode":100,"message":"success","body":{"deviceId":"C271111EC0AB","deviceType":"Meter",
  "hubDeviceId":"FA7310762361","humidity":52,"temperature":26.1,"battery":87,"version":"V3.1"}}` →
  CurrentTemperature 26.1, CurrentRelativeHumidity 52, BatteryLevel 87, StatusLowBattery NORMAL,
  firmware `3.1`.
- Curtain `{"statusCode":100,"body":{"deviceId":"E2F6032048AB","deviceType":"Curtain",
  "hubDeviceId":"FA7310762361","calibrate":true,"group":false,"moving":false,"slidePosition":30,
  "battery":9,"lightLevel":"dim"},"message":"success"}` → CurrentPosition 70, TargetPosition 70,
  PositionState STOPPED, BatteryLevel 9, StatusLowBattery LOW, light 1 lux.
  Setting TargetPosition 100 with `setOpenMode` `"1"` → `setPosition` `"0,1,0"`; with no mode →
  `"0,ff,0"`; setting 20 → `"0,ff,80"`.
- Bot (switch mode) `{"statusCode":100,"body":{"deviceId":"D1A2B3C4D5E6","deviceType":"Bot",
  "hubDeviceId":"FA7310762361","power":"on","battery":100},"message":"success"}` → On true.
- Plug Mini `{"statusCode":100,"body":{"deviceId":"6055F92F0A1B","deviceType":"Plug Mini (US)",
  "hubDeviceId":"000000000000","power":"off","voltage":120.1,"weight":0,"electricityOfDay":3,
  "electricCurrent":0},"message":"success"}` → Outlet On false.
- Smart Lock `{"statusCode":100,"body":{"deviceId":"F1E2D3C4B5A6","deviceType":"Smart Lock",
  "hubDeviceId":"FA7310762361","lockState":"locked","doorState":"closed","moveDetected":false,
  "battery":64},"message":"success"}` → LockCurrentState and LockTargetState SECURED, ContactSensorState
  DETECTED.
- Color Bulb `{"statusCode":100,"body":{"deviceId":"A1B2C3D4E5F6","deviceType":"Color Bulb",
  "hubDeviceId":"000000000000","power":"on","brightness":80,"color":"255:0:0","colorTemperature":4000},
  "message":"success"}` → On true, Brightness 80, Hue 0, Saturation 100, ColorTemperature 250.
  Setting Hue 120 / Saturation 100 → `setColor` `"0:255:0"`. Setting ColorTemperature 370 →
  `setColorTemperature` `"2703"`.
- Humidifier `{"statusCode":100,"body":{"deviceId":"500291B269BE","deviceType":"Humidifier",
  "hubDeviceId":"000000000000","power":"on","humidity":45,"temperature":22.5,
  "nebulizationEfficiency":60,"auto":false,"childLock":false,"sound":true,"lackWater":false},
  "message":"success"}` → Active, target HUMIDIFIER, threshold 60, current HUMIDIFYING, WaterLevel 100.
- Blind Tilt (`only_up`) `{"statusCode":100,"body":{"deviceId":"B0E9FE11A2C3","deviceType":"Blind Tilt",
  "hubDeviceId":"FA7310762361","calibrate":true,"battery":75,"direction":"up","slidePosition":75,
  "version":"V2.1"},"message":"success"}` → CurrentPosition 50. Setting 100 → `fullyOpen`; 40 →
  `setPosition` `"up;40"`; 0 → `closeUp`.
- Error `{"statusCode":161,"message":"device offline","body":{}}` on a command → error log, no state
  change.

### 10.4 Identity seeds (4.x) and their HAP UUIDs (per §3.2's algorithm)

| Seed | SHA-1 (hex) | UUID |
|---|---|---|
| `C271111EC0AB-Meter` | `ee5027bc62f130eb094f8fbac979d71f812722cc` | `ee5027bc-62f1-430e-b094-f8fbac979d71` |
| `E2F6032048AB-Curtain` | `ae47196a1e16dd6049853c0cd0f8caa9e3b4105c` | `ae47196a-1e16-4dd6-8498-53c0cd0f8caa` |
| `02-202008110034-13-TV` | `37e65d0898fa42392a3ebf6ec28c0ab4cb847971` | `37e65d08-98fa-4423-92a3-ebf6ec28c0ab` |
| `C271111EC0AB` (5.x seed) | `0ae98863c9a5845b8b383448e32248e3f50c85ee` | `0ae98863-c9a5-4845-b8b3-83448e32248e` |

### 10.5 Webhook payloads (data)

```json
{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoMeter","deviceMac":"C271111EC0AB","temperature":78.8,"scale":"FAHRENHEIT","humidity":50,"battery":90,"timeOfSample":1730700000000}}
```
4.x without `convertUnitTo`: CurrentTemperature 78.8 (wrong; Celsius expected). With
`convertUnitTo: "FAHRENHEIT"`: 26. Recommended behaviour: 26.0.

```json
{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoContact","deviceMac":"D8C1A2B3C4D5","detectionState":"DETECTED","doorMode":"IN_DOOR","brightness":"bright","openState":"timeOutNotClose","battery":80,"timeOfSample":1730700001000}}
```
→ ContactSensorState NOT_DETECTED (open), MotionDetected true, light = `set_maxLux` (intended).

```json
{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoLock","deviceMac":"F1E2D3C4B5A6","lockState":"JAMMED","battery":50,"timeOfSample":1730700002000}}
```
→ 4.x UNSECURED (recommended JAMMED).

```json
{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoCurtain","deviceMac":"E2F6032048AB","calibrate":false,"group":false,"slidePosition":50,"battery":100,"timeOfSample":123456789}}
```
→ CurrentPosition 50.

```json
{"eventType":"changeReport","eventVersion":"1","context":{"deviceType":"WoPlugUS","deviceMac":"6055F92F0A1B","powerState":"ON","timeOfSample":1730700003000}}
```
→ Outlet On true.

Requests to the listener: `POST /switchbot` → `200 OK`; `GET /switchbot` → `403 NG`;
`POST /other` → `403 NG`. An event for a device without `webhook: true` changes nothing.

### 10.6 Air conditioner `setAll`

Active, COOL, threshold 23, HomeKit speed 2 → `setAll` `"23,2,3,on"`. AUTO, speed 4 → `"25,1,1,on"`.
Inactive (off command suppressed by `disablePushOff`) → nothing; otherwise `turnOff`.

## 11. Gaps

- **BLE** (4.x `BLE`, `connectionType` `BLE`/`BLE/OpenAPI`, `scanDuration`, `customBLEaddress`,
  `maxRetry`, `disablePlatformBLE`; 5.x `enableBLE`, `encryptionKey`, `keyId`): passive advertisement
  scanning (service-data parsing per model, models identified by a one-character code), GATT commands on
  the SwitchBot service `cba20d00-224d-11e6-9fb8-0002a5d5c51b` (write characteristic `…0002…`, notify
  `…0003…`), AES-encrypted commands for locks and newer devices. Not portable to Homeswift on Linux; not
  specified. Devices configured for BLE only (and every device in no-token mode) cannot work; the cloud
  covers every device that has "Cloud Services" enabled in the app.
- 4.3.14's status path discards polled values (§5.3): behaviour of real 4.3.14 installs is therefore
  "values come from webhooks and command echoes", not from polling. This spec describes the intent.
- Several mappings are visibly wrong in 4.x (light level for bright, `up_and_down`, Ceiling Light
  power and Kelvin, CO₂ detected, Others' type case, Bot default type, fan speed guard, `set_minlux`
  spelling, platform `delayBetweenRetries` units, temperature conversion). Each is flagged above with
  the evident intent; the implementer must decide which to keep for compatibility (none affects ids).
- Humidifier2 (evaporative humidifier) has different OpenAPI commands (`setMode` with a mode and a
  target humidity object) that 4.x does not send; its exact parameter shape was not checked.
- Battery Circulator Fan's `setOscillation` is not in the published API; whether the cloud accepts it was
  not determined.
- Eve history (`history`) is declared but not wired for these devices in 4.x; not specified.
- Adaptive Lighting's exact HomeKit behaviour follows HAP-NodeJS's controller (Homeswift has one); the
  plugin only chooses automatic mode and a shift.
- The HAP UUID derivation in §3.2 is from the spec writer's knowledge of HAP-NodeJS, not from these
  sources; verify before relying on it for migration.
- Scenes are available in the API but used by neither plugin version.
- The documentation lists more device types (Keypads, Lock Lite/Vision, Garage Door Opener, Smart
  Radiator Thermostat, Relay Switch 2PM, newer lights and vacuums, cameras) that 4.x does not support;
  5.x supports some through a different internal model not specified here.
- Whether the cloud delivers webhooks over plain `http://` or requires `https://` was not determined
  from the sources (the plugin's placeholder uses `http://`).
- MQTT option objects are typed as strings in the schema and objects in the code; their accepted
  keys are those of the MQTT.js client and are not specified.
