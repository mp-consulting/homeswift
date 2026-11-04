# Dyson Pure Cool

Dyson Pure Cool, Hot+Cool, Humidify+Cool, Big+Quiet purifiers and the Dyson Cool fan in HomeKit, over each
device's local MQTT broker. The Homeswift port of
[`@mp-consulting/homebridge-dyson-pure-cool`](https://github.com/mp-consulting/homebridge-dyson-pure-cool), originally by
Lukas Rogner, under the MIT license (notice in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)):
same platform name (`DysonPureCool`); a Homebridge `config.json` block loads unchanged, and what Homeswift writes is its
canonical shape ([Configuration](#configuration)).

## What it does

Each device becomes an accessory (`DysonPureCool:<serial>`) with:

- **Air Purifier**: power, speed in steps of 10 % (Dyson speeds 1-10), oscillation, Auto/Manual. In auto mode the
  slider keeps the last manual speed. A plain fan (CF1) offers Manual only.
- **Temperature** and **Humidity** sensors, with calibration offsets.
- **Air Quality**: the worst of PM2.5, PM10 (EPA breakpoints), VOC and NO2 (Dyson's index); the densities as
  reported. Link models (TP02, DP01, HP02) report a 0-9 index instead, rated on its own scale, without densities.
- **Filter**: the most worn of the HEPA and carbon filters, a change alert at 10 % or less.
- **Night Mode**, **Continuous Monitoring** and **Jet Focus** switches.
- **Thermostat** and/or **Heater Cooler** on Hot+Cool models (heat only, 1-37 °C on the thermostat, 10-38 °C on the
  heater cooler); turning the heater on also starts the fan, in one command.
- **Humidifier** on Humidify+Cool models: on/off, auto or manual, target humidity (30-70 % or 0-100 %), water level.

Services the model lacks, or the options turn off, are left out. Reads answer "No Response" while the device is
disconnected.

Devices with an `ipAddress` connect at once; the others are looked up over mDNS (`_dyson_mqtt._tcp`, local
addresses only, since the device's credential goes to whatever answers). The connection uses the serial number and
the local credential; firmware that refuses the usual CONNECT (Big+Quiet) gets alternative client ids, protocol
levels and session flags. The state is requested every `pollingInterval`, and changes arrive as they happen. A
lost connection is retried five times with backoff, then every five minutes. A device that stops answering at its
configured address is looked up over mDNS; the new address is kept in `ip-overrides.json` (in the plugin's storage
directory, owner-only) and used at the next launch while config.json still names the old one.

## Setting up

Devices come in through Setup: **Add accessories** (the Dyson Pure Cool row), or an AI agent through the MCP server's
`start_setup` and `continue_setup`. The account asks your Dyson email and country, then your password with the 6-digit
code Dyson emails (the password is never kept); the account's token goes in the bridge's vault. Each supported device
of the account is then a Discovered Device: setting one up reads its local credential into the vault under its serial
number, and its product type, name and firmware into its Accessory Settings. A device whose credential stops working
is set up again the same way.

**Plugins › Dyson Pure Cool › Open** lists the devices this instance runs with their connection state and live
readings (fan, temperature, humidity, PM2.5, filter), and switches each one's continuous monitoring, which is the
device's own state. A device's **Settings** opens its options on the plugin's Settings page
(`/plugins/<slug>/settings?accessory=DysonPureCool:<serial>`), where it is also Excluded or Forgotten. The page writes no
settings. When the Assistant is set up (a `HomeswiftAiKit` block), unreachable devices get an **Explain** button; it
never sees the credentials, serial numbers or addresses.

The Assistant (the web UI's chat, MCP clients) can also list the devices with their state, list the product
types, check a device and, after you confirm, switch its continuous monitoring (`Sources/AssistantActions.swift`),
and read and write the settings with `get_settings` and `update_settings`. Those tools name a device by its serial
number and see its address; the credentials stay in the bridge, and the Dyson sign-in is Setup's.

## Configuration

What Homeswift writes (docs/adr/0001-canonical-accessory-settings.md): the plugin's settings in the block, each device's
in `_accessories` by its serial number (its Device Id), the credentials in the vault.

```json
{
  "platform": "DysonPureCool",
  "name": "Dyson Pure Cool",
  "countryCode": "GB",
  "enableFilterStatus": true,
  "_accessories": {
    "ABC-AB-12345678": {
      "name": "Living Room Purifier",
      "productType": "438",
      "ipAddress": "192.168.1.100",
      "temperatureOffset": -2,
      "humidityOffset": 5,
      "enableNightMode": false
    }
  }
}
```

### Plugin Settings

| Setting | Type | Default | Description |
|--------|------|---------|-------------|
| `countryCode` | string | `US` | The Dyson account's country (Setup sets it) |
| `discoveryTimeout` | number | `10` | mDNS scan length in seconds (values over 60 are read as milliseconds) |
| `pollingInterval` | number | `60` | Seconds between state requests (10-300) |
| `enableTemperature` | boolean | `true` | Temperature sensor |
| `enableHumidity` | boolean | `true` | Humidity sensor |
| `enableAirQuality` | boolean | `true` | Air quality sensor |
| `enableNightMode` | boolean | `true` | Night mode switch |
| `enableContinuousMonitoring` | boolean | `false` | Continuous monitoring switch |
| `enableJetFocus` | boolean | `true` | Jet focus switch |
| `enableHeater` | boolean | `true` | Heating on HP models |
| `enableHumidifier` | boolean | `true` | Humidifier on PH models |
| `enableFilterStatus` | boolean | `false` | Filter life; shown when the key is absent, as in the Homebridge plugin |
| `enableAutoMode`, `isSingleAccessoryModeEnabled`, `isSingleSensorAccessoryModeEnabled` | boolean | | Accepted; the Homebridge plugin never acted on them either |

The `enable*` switches are plugin-wide defaults: each is also an Accessory Setting of the same name, which overrules it
for one device.

### Accessory Settings

Each device's (the schema's `accessorySchema`), besides its Name and Excluded; the Device Kind is `purifier`, `heater`
(Hot+Cool) or `humidifier` (Humidify+Cool), from the product type.

| Setting | Type | Default | Description |
|--------|------|---------|-------------|
| `productType` | string | | The Dyson product type code (`438`, `527K`, …), Setup's |
| `ipAddress` | string | | Leave empty for mDNS |
| `firmwareVersion` | string | | Shown as the firmware revision, Setup's |
| `temperatureOffset` | number | `0` | °C |
| `humidityOffset` | number | `0` | % |
| `useFahrenheit` | boolean | `false` | Log temperatures in °F |
| `enableTemperature`, `enableHumidity`, `enableAirQuality` | boolean | the plugin's | Show a sensor |
| `enableNightMode`, `enableJetFocus`, `enableContinuousMonitoring` | boolean | the plugin's | Show a switch |
| `enableFilterStatus` | boolean | the plugin's | Show the filter life |
| `enableHeater`, `heatingServiceType` | | the plugin's, `thermostat` | `heater` only: show heating; `thermostat`, `heater-cooler` or `both` |
| `enableHumidifier`, `fullRangeHumidity` | boolean | the plugin's, `false` | `humidifier` only: show the humidifier; 0-100 % instead of 30-70 % |
| `enableAutoModeWhenActivating`, `enableOscillationWhenActivating`, `enableNightModeWhenActivating` | boolean | `false` | Switched on with the device, in the same command |

A Homebridge block still loads: its `devices` list, by `serial`, with `localCredentials` (or `credentials`) and the
per-device keys above, of which `isTemperatureIgnored`, `isHumidityIgnored`, `isAirQualityIgnored`,
`isHeatingDisabled`, `isHumidifierDisabled` and `isFilterStatusDisabled` are the inverse of the `enable*` switches and
`isNightModeEnabled`, `isJetFocusEnabled` and `isContinuousMonitoringEnabled` the same; it is read where
`_accessories` says nothing. The first settings write (the Settings page, `update_settings`, Setup) moves each entry
into `_accessories` (`name` as the Name, the inverse keys turned around, `isHeatingSafetyIgnored`, which nothing read,
dropped) and its credential into the vault, and drops `devices`; an entry whose credential is a reference the bridge
cannot read stays. Numbers and booleans written as strings are accepted.

## Supported devices

| Series | Models (product type) |
|--------|--------|
| Pure Cool Link | TP02 (475), DP01 (469) |
| Pure Cool | TP04/TP06 (438), TP07 (438E), TP09 (438K), TP11 (438M), DP04 (520) |
| Pure Hot+Cool Link | HP02 (455) |
| Pure Hot+Cool | HP04/HP06 (527), HP07 (527E), HP09 (527K), HP11 (527M) |
| Humidify+Cool | PH01 (358), PH02 (520E), PH03 (358H, 358J), PH04 (358E, 520F), PH05 (358K) |
| Big+Quiet | BP02 (664), BP03 (664B), BP04 (664E), BP06 (664F) |
| Cool | CF1 (739) |

## What differs from Homebridge

- The cloud is reached with Homeswift's HTTP client and the credentials decrypted with swift-crypto; MQTT goes
  through `HomeswiftNetwork`'s client (see `Sources/DysonMQTTClient.swift`), and the CONNECT ladder (MQTT 5 and
  3.1 included) is tried as in Homebridge.
- `discoveryTimeout` is read as seconds up to 60 and as milliseconds above: the Homebridge plugin's README says
  seconds but its code uses milliseconds (`10000` by default), so both kinds of config.json mean what they meant.
  The scan lasts between 1 and 60 seconds.
- HomeKit writes arrive one by one: a mode or speed write within a second of an OFF is dropped (Homebridge dropped
  those in the same tick), so turning the fan off does not switch it back on.
- Values the Home app showed, and service names it was given, carry over from the accessory cache until the device
  reports. Services an option turns off disappear at once (the accessory is rebuilt).
- Every connection and poll also sends `REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA` after
  `REQUEST-CURRENT-STATE`: Link models (an HP02 at least) never send their sensor readings on their own, even with
  continuous monitoring on, so with Homebridge their temperature and humidity stay at the defaults.
- With continuous monitoring off and the fan idle, a Link model reports its temperature and humidity as `OFF`: the
  sensors keep their last reading with **Status Active** off, so the Home app shows them as not current, and turn
  active again with the next reading. Homebridge showed the old reading as current.
- The page uses the bridge's connection to a device when there is one, instead of a second MQTT session. It no
  longer signs in or writes the devices (the Homebridge wizard's `authenticate`, `verify-otp` and `get-devices`):
  Setup does, and the local credentials never reach the browser.
- A Dyson cloud answer of 401 or 403 with an empty body fails the request ("Session expired" for the device list);
  Homebridge read it as an empty success and listed no devices.
- `config.schema.json` declares the Plugin Settings and, in `accessorySchema`, each device's, with positive switches
  in place of the Homebridge keys' inverses; the CF1 is among the product types, and 358K is the PH05 (the Homebridge
  schema called it an HP06).
