# Govee

Govee devices in HomeKit: lights (colour, white, scenes from the Govee library, DIY effects, live music
mode, Adaptive Lighting), plugs and power strips (shown as switches, outlets, purifiers, heaters, coolers,
taps, valves or TV-type accessories), thermo-hygrometers, leak, presence, contact and air quality sensors,
heaters, fans, humidifiers, dehumidifiers, purifiers, diffusers, kettles and ice makers.

A port of [`@mp-consulting/homebridge-govee`](https://github.com/mp-consulting/homebridge-govee). The platform
block is the same, so a Homebridge configuration works unchanged.

## How it reaches the devices

- **Govee's cloud**: the plugin logs in to the Govee app's account API with your email and password, lists the
  account's devices, and reads sensor values from that list every `httpRefreshTime`. The login also yields the
  account's AWS IoT certificate (kept, owner-only, as `govee.pfx` in the plugin's directory): commands and
  real-time status go over **AWS IoT** (MQTT over TLS with that certificate), and every minute each device is
  asked for its status.
- **LAN**: models with the LAN API turned on in the Govee app are found by a multicast scan
  (239.255.255.250:4001, answers on port 4002) every `lanScanInterval`, polled every `lanRefreshTime`, and
  controlled on port 4003. Discovery is unauthenticated, so only devices of the account (or listed in the
  configuration) become accessories, and a device is reached at the packet's source address.
- **Bluetooth**: commands are written to the device's control characteristic, one at a time, at least
  `bleControlInterval` apart; thermo-hygrometers are read from their advertisements every `bleRefreshTime`.

A command goes over LAN, then AWS, then Bluetooth, whichever works first. Without credentials the plugin runs
with LAN and Bluetooth only.

### New-device verification

Govee challenges a login from a client it has not seen with a one-time code it emails. The log (or **Test
Connection** on the plugin's page) says so: put the code in `code` (the page's **Verification Code**) and save.
The client id is derived from the account as the Homebridge plugin's was, so a login Govee verified for
Homebridge is not challenged again.

## The web page

The Plugins page has an **Open** button for this plugin, with the Homebridge plugin's three tabs:

- **Devices**: **Discover Devices** logs in and adds the account's devices to the lists; the devices the
  plugin found at its start are added too. One list per device type, each device with how the plugin reaches
  it (LAN, AWS, BLE), **Edit** and **Remove**. A light's editor has three tabs: General, **Scene Library** (the
  Govee library for that exact model, with the app's icons, your DIY effects, or the catalogue bundled with
  the plugin when Govee cannot be reached; each scene picked becomes a switch in HomeKit) and **Music Mode**.
  Tabs Govee says the light lacks are hidden.
- **Settings**: the account with **Test Connection**, the general options, and the three connections.
- **Tools**: **Clear Cache** (the kept login and certificate, the discovered devices, the devices' state).

**Save Configuration** writes this instance's block; the plugin restarts with it at once. With the Assistant
on, **Explain** sits next to errors.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "Govee",
      "name": "Govee",
      "username": "your-govee-email@example.com",
      "password": "your-govee-password"
    }
  ]
}
```

| Option | Default | Description |
|---|---|---|
| `username` | | Your Govee account email |
| `password` | | Your Govee account password |
| `code` | | The one-time email verification code, when Govee asks for one |
| `ignoreMatter` | `false` | Skip Matter-capable models, to add them to HomeKit natively |
| `disableDeviceLogging` | `false` | Don't log device state changes |
| `debug` | `false` | Debug lines at the info level (`homeswift -D` shows them anyway) |
| `httpRefreshTime` | `30` | Seconds between polls of the device list for sensor readings (30 at least) |
| `awsDisable` | `false` | Disable the AWS IoT connection |
| `bleDisable` | `false` | Disable Bluetooth |
| `bleRefreshTime` | `300` | Seconds between Bluetooth scans for thermo-hygrometers (60 at least) |
| `bleControlInterval` | `500` | Milliseconds between Bluetooth commands (500 and up; 5 to 499 are read as seconds, as older configurations meant) |
| `lanDisable` | `false` | Disable LAN control |
| `lanRefreshTime` | `30` | Seconds between LAN status polls |
| `lanScanInterval` | `60` | Seconds between LAN scans (30 at least) |
| `colourSafeMode` | `false` | A slower but more reliable way of setting colours (no colour temperature, no Adaptive Lighting) |

Each device type has its list: `lightDevices`, `switchDevices`, `thermoDevices`, `leakDevices`, `fanDevices`,
`heaterDevices`, `humidifierDevices`, `dehumidifierDevices`, `purifierDevices`, `diffuserDevices`,
`kettleDevices`, `iceMakerDevices`. Every entry has `deviceId`, `label` and `ignoreDevice`; besides:

- **Lights**: `showAs` (`default` or `switch`), `customIPAddress`, `customAddress` (Bluetooth MAC),
  `brightnessStep`, `adaptiveLightingShift` (-1 turns Adaptive Lighting off), `awsBrightnessNoScale`,
  `awsColourMode` (`default`, `rgb`, `redgreenblue`), `scenes` (picked on the page), `musicModeLive`
  (`enabled`, `effect`, `sensitivity`, `autoColour`, `soft`, `protocol`), and the older fixed slots `scene` to
  `sceneFour`, `diyMode` to `diyModeFour`, `musicMode`, `musicModeTwo`, `videoMode`, `videoModeTwo`,
  `segmented` to `segmentedFour` (`sceneCode`, `bleCode`, `showAs`).
- **Plugs**: `showAs` (`default`, `outlet`, `switch`, `purifier`, `heater`, `cooler`, `tap`, `valve`, `audio`,
  `box`, `stick`) and `temperatureSource`, the thermo-hygrometer a plug shown as a heater or cooler follows.
- **Thermo-hygrometers**: `lowBattThreshold`, `showExtraSwitch` (a read-only thermostat instead of a
  temperature sensor). **Leak sensors**: `lowBattThreshold`.
- **Fans**: `hideLight`. **Heaters**: `tempReporting`. **Kettles**: `hideModeGreenTea`, `hideModeOolongTea`,
  `hideModeCoffee`, `hideModeBlackTea`, `showCustomMode1`, `showCustomMode2`.

## What differs from the Homebridge plugin

- **Files**: the login is kept in `credentials.json` and the certificate in `govee.pfx`, both owner-only,
  under `~/.homeswift/plugins/Govee-<name>/`, with the discovered devices, the devices' state and the Eve
  histories. A Homebridge `govee_cache` is not read: the first start logs in again.
- **Bluetooth** runs on macOS through CoreBluetooth, which hides MAC addresses: a device is found by the name it
  advertises (Govee's `bleName`) or by the end of its MAC in that name. macOS allows Bluetooth only to a binary
  whose Info.plist describes the use (`NSBluetoothAlwaysUsageDescription`); without it the plugin logs that
  Bluetooth is unavailable and runs without it. There is no Bluetooth on Linux yet (noble was optional upstream
  too).
- A plug shown as an **audio receiver, set-top box or streaming stick** is published as an accessory of its
  own, as HomeKit wants televisions: add it in the Home app with the bridge's setup code.
- `label` names every device in HomeKit, not only LAN-only ones, as the page's help always said.
- `temperatureSource` works: the Homebridge plugin never read it, so its plug heaters and coolers kept 20°C.
- `customAddress` is used as the device's Bluetooth address.
- Purifiers (`statePuri`), the H7131/H7132 heaters (`stateHeat`, `multiSync`) and the H7105/H7107 fan lights
  (`multiSync`) send the commands of the original homebridge-govee; the Homebridge plugin failed them as
  "Invalid command".
- The H7126 family's speed reports set one of its three speeds (the Homebridge plugin set an invalid value).
- The settings page's "Describe your setup" is left to the runtime's Assistant (`Explain` remains on errors).
