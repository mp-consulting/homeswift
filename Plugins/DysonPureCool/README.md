# Dyson Pure Cool

Dyson Pure Cool, Hot+Cool, Humidify+Cool, Big+Quiet purifiers and the Dyson Cool fan in HomeKit, over each
device's local MQTT broker. The Homeswift port of
[`@mp-consulting/homebridge-dyson-pure-cool`](https://github.com/mp-consulting/homebridge-dyson-pure-cool):
same platform name (`DysonPureCool`), same `config.json` block, same settings wizard.

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

## The settings page

**Plugins › Dyson Pure Cool › Open** is the Homebridge plugin's wizard:

1. **Account**: your Dyson email, password and country. Dyson emails a 6-digit code.
2. **Code**: the code, within ten minutes. The password is held in memory until then, never saved.
3. **Devices**: the account's devices with their local credentials, decrypted; pick the ones to add, name them,
   set continuous monitoring, offsets, Fahrenheit logging and the heating service.
4. **Options**: sensors, controls, polling interval. **Save** writes the block (keys the wizard does not show, such
   as `_bridge` or per-device overrides, are kept) and the plugin reloads with it.

Once devices are set up, the page lists them with their connection state and live readings; changes are saved as
you make them, and **Re-sync from Dyson Cloud** signs in again to add devices or refresh credentials. When the
Assistant is set up (a `HomeswiftAiKit` block), failed sign-ins and unreachable devices get an **Explain** button;
it never sees the email, password, codes, credentials, serial numbers or addresses.

The Assistant (the web UI's chat, MCP clients) can also list the devices with their state, list the product
types, check a device and, after you confirm, switch its continuous monitoring (`Sources/AssistantActions.swift`).
Those tools name a configured device by its serial number and see its address; the credentials stay in the
bridge, and the Dyson sign-in is not one of them.

## Configuration

```json
{
  "platform": "DysonPureCool",
  "name": "Dyson Pure Cool",
  "countryCode": "GB",
  "devices": [
    {
      "name": "Living Room Purifier",
      "serial": "ABC-AB-12345678",
      "productType": "438",
      "localCredentials": "the credential the wizard fetched",
      "ipAddress": "192.168.1.100",
      "temperatureOffset": -2,
      "humidityOffset": 5
    }
  ]
}
```

### Platform options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `countryCode` | string | `US` | The Dyson account's country (the wizard signs in with it) |
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

### Per-device options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `serial` | string | | Required |
| `productType` | string | | Required: the Dyson product type code (`438`, `527K`, …) |
| `localCredentials` (or `credentials`) | string | | Required: the local MQTT password |
| `name` | string | `Dyson <serial>` | |
| `ipAddress` | string | | Leave empty for mDNS |
| `firmwareVersion` | string | | Shown as the firmware revision |
| `temperatureOffset` | number | `0` | °C |
| `humidityOffset` | number | `0` | % |
| `useFahrenheit` | boolean | `false` | Log temperatures in °F |
| `isTemperatureIgnored`, `isHumidityIgnored`, `isAirQualityIgnored` | boolean | `false` | Hide a sensor |
| `isHeatingDisabled` | boolean | `false` | Hide heating |
| `heatingServiceType` | string | `thermostat` | `thermostat`, `heater-cooler` or `both` |
| `fullRangeHumidity` | boolean | `false` | 0-100 % instead of 30-70 % |
| `enableAutoModeWhenActivating`, `enableOscillationWhenActivating`, `enableNightModeWhenActivating` | boolean | `false` | Switched on with the device, in the same command |
| `isNightModeEnabled`, `isJetFocusEnabled` | boolean | `true` | |
| `isContinuousMonitoringEnabled` | boolean | `false` | |
| `isFilterStatusDisabled`, `isHumidifierDisabled` | boolean | `false` | |
| `isHeatingSafetyIgnored` | boolean | `false` | Accepted, not used (as in the Homebridge plugin) |

A device's own keys win over the platform's toggles. Numbers and booleans written as strings are accepted.

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
  through `HomeswiftNetwork`'s client (see `Sources/DysonMQTTClient.swift`), which speaks MQTT 3.1 and 3.1.1: the
  CONNECT ladder's MQTT 5 step is skipped, the others are tried as in Homebridge.
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
- The settings page uses the bridge's connection to a device when there is one, instead of a second MQTT session.
- A Dyson cloud answer of 401 or 403 with an empty body fails the request ("Session expired" for the device list);
  Homebridge read it as an empty success and listed no devices.
- `config.schema.json` is the Homebridge plugin's, with the CF1 added to the product types.
