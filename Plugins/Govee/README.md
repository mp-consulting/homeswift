# Govee

Govee devices in HomeKit: lights (colour, white, scenes from the Govee library, DIY effects, live music
mode, Adaptive Lighting), plugs and power strips (shown as switches, outlets, purifiers, heaters, coolers,
taps, valves or TV-type accessories), thermo-hygrometers, leak, presence, contact and air quality sensors,
heaters, fans, humidifiers, dehumidifiers, purifiers, diffusers, kettles and ice makers.

A port of [`@mp-consulting/homebridge-govee`](https://github.com/mp-consulting/homebridge-govee), originally by Ben Potter
(bwp91), under the MIT license; its Linux Bluetooth follows noble's hci-socket bindings (MIT, Sandeep Mistry). The
notices are in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md). A Homebridge configuration loads unchanged; what Homeswift writes is its canonical shape
([Configuration](#configuration)).

## How it reaches the devices

- **Govee's cloud**: the plugin logs in to the Govee app's account API with your email and password, lists the
  account's devices, and reads sensor values from that list every `httpRefreshTime`. The login also yields the
  account's AWS IoT certificate (kept in the vault with the login): commands and
  real-time status go over **AWS IoT** (MQTT over TLS with that certificate), and every minute each device is
  asked for its status.
- **LAN**: models with the LAN API turned on in the Govee app are found by a multicast scan
  (239.255.255.250:4001, answers on port 4002) every `lanScanInterval`, polled every `lanRefreshTime`, and
  controlled on port 4003. Discovery is unauthenticated, so only devices of the account (or listed in the
  configuration) become accessories, and a device is reached at the packet's source address.
- **Bluetooth**: commands are written to the device's control characteristic, one at a time, at least
  `bleControlInterval` apart; thermo-hygrometers are read from their advertisements every `bleRefreshTime`.

A command goes over LAN, then AWS, then Bluetooth, whichever works first. Without credentials the plugin runs
with LAN and Bluetooth only. Bluetooth works on macOS (the `homeswift` binary embeds the Info.plist key
CoreBluetooth needs; a binary without it logs that Bluetooth needs `NSBluetoothAlwaysUsageDescription`) and on
Linux, where it uses the adapter `hci0` (or the one `NOBLE_HCI_DEVICE_ID` names, as for noble) through a raw HCI
socket, which needs root or `CAP_NET_RAW`: `sudo setcap cap_net_raw,cap_net_admin+eip "$(command -v homeswift)"`.
Without Bluetooth hardware the log says "Bluetooth not available on this system" and the plugin runs without it.

### New-device verification

Govee challenges a login from a client it has not seen with a one-time code it emails: Setup asks for it. A
Homebridge block's `code` still works at the next start.
The client id is derived from the account as the Homebridge plugin's was, so a login Govee verified for
Homebridge is not challenged again.

## The web page

The Plugins page has an **Open** button for this plugin. It writes no settings: the plugin's and each device's are on
its **Settings** page.

- **Devices**: the devices of the account and of the LAN the plugin found at its start, one list per device type,
  each with how the plugin reaches it (LAN, AWS, BLE), Excluded or not on the bridge, and a **Settings** link to its
  Accessory Settings (`/plugins/<slug>/settings?accessory=Govee:<deviceId>`). **Discover Devices** asks Govee for the
  account's devices now. A light's **Scenes** opens its **Scene Library** (the Govee library for that exact model,
  with the app's icons, your DIY effects, or the catalogue bundled with the plugin when Govee cannot be reached): the
  scenes in the light's settings have a tick, and a tile shows the name, code and id to add to them. While no
  account is signed in, a link leads to Setup.
- **Tools**: **Clear Cache** (the kept login and certificate, the discovered devices, the devices' state; a password
  Setup kept stays, and the next start signs in with it).

With the Assistant on, **Explain** sits next to errors.

The Assistant (the web UI's chat, MCP clients) has the page's routes as tools: `Govee_list_devices` (the
instance's devices and how it reaches them), `Govee_discovered_devices`, `Govee_discover` (the account's
devices from the cloud), `Govee_scenes` and `Govee_diy_effects` for a light (to add them to its `scenes` with `update_settings`),
and `Govee_clear_cache`, which asks first. They log in with the instance's own account: no password goes
through the model.

## Configuration

What Homeswift writes (docs/adr/0001-canonical-accessory-settings.md): the plugin's settings in the block, each
device's in `_accessories` by its Govee device id (its Device Id), the account in the vault.

```json
{
  "platforms": [
    {
      "platform": "Govee",
      "name": "Govee",
      "lanScanInterval": 60,
      "_accessories": {
        "AA:BB:CC:DD:EE:FF:00:11": { "name": "Desk Light", "customIPAddress": "192.168.1.50", "brightnessStep": 5 },
        "AA:BB:CC:DD:EE:FF:00:22": { "showAs": "outlet" },
        "F9:44:AB:CD:12:34:56:78": { "excluded": true }
      }
    }
  ]
}
```

| Plugin Setting | Default | Description |
|---|---|---|
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
| `homebridgeStoragePath` | `~/.homebridge` | Homeswift only: the Homebridge storage path whose Govee login a first start imports |

Each device has its Name and Excluded, and the Accessory Settings of its Device Kind (the schema's `accessorySchema`,
`x-kinds`): the list its model's entry went in, without `Devices` (`light`, `switch`, `thermo`, `leak`, `fan`,
`heater`, `humidifier`, `dehumidifier`, `purifier`, `diffuser`, `kettle`, `iceMaker`).

- **Lights** (`light`): `showAs` (`default` or `switch`), `customIPAddress`, `customAddress` (Bluetooth MAC),
  `brightnessStep`, `adaptiveLightingShift` (-1 turns Adaptive Lighting off), `awsBrightnessNoScale`,
  `awsColourMode` (`default`, `rgb`, `redgreenblue`), `lanScenes` (scenes, DIY effects and music mode over LAN
  as `ptReal`, off by default: the light does not acknowledge LAN commands, so one that ignores them gets no cloud
  or Bluetooth fallback), `scenes` (`name`, `sceneCode`, `sceneId`, `kind`: the Scene Library shows them), `musicModeLive`
  (`enabled`, `effect`, `sensitivity`, `autoColour`, `soft`, `protocol`), and the older fixed slots `scene` to
  `sceneFour`, `diyMode` to `diyModeFour`, `musicMode`, `musicModeTwo`, `videoMode`, `videoModeTwo`,
  `segmented` to `segmentedFour` (`sceneCode`, `bleCode`, `showAs`).
- **Plugs** (`switch`): `showAs` (`default`, `outlet`, `switch`, `purifier`, `heater`, `cooler`, `tap`, `valve`, `audio`,
  `box`, `stick`) and `temperatureSource`, the thermo-hygrometer a plug shown as a heater or cooler follows.
  `audio`, `box` and `stick` are televisions on the bridge, as in Homebridge; the Home app shows one television
  per bridge, so several go on a child bridge (`_bridge`) each.
- **Thermo-hygrometers** (`thermo`): `lowBattThreshold`, `showExtraSwitch` (a read-only thermostat instead of a
  temperature sensor). **Leak sensors** (`leak`): `lowBattThreshold`.
- **Fans**: `hideLight`. **Heaters**: `tempReporting`. **Kettles**: `hideModeGreenTea`, `hideModeOolongTea`,
  `hideModeCoffee`, `hideModeBlackTea`, `showCustomMode1`, `showCustomMode2`.

A Homebridge block still loads: its `username`, `password` and `code`, and its twelve lists (`lightDevices`,
`switchDevices`, `thermoDevices`, `leakDevices`, `fanDevices`, `heaterDevices`, `humidifierDevices`,
`dehumidifierDevices`, `purifierDevices`, `diffuserDevices`, `kettleDevices`, `iceMakerDevices`), each entry with its
`deviceId`, `label`, `ignoreDevice` and the options above, read under `_accessories`. The first settings write (the
Settings page, `update_settings`, Setup) moves every entry into `_accessories` (`label` as the Name, `ignoreDevice`
as Excluded) and drops the lists, and moves `username` and `password` into the vault's login.

## What differs from the Homebridge plugin

- **Setup**: the account is signed in to from the **Add accessories** page (an Account Login: the email and
  password, then the code Govee emails for a new device). The login, the AWS IoT certificate and the password go in
  the vault, and `username`, `password` and `code` leave the block; a block's `username` and `password` still work. Devices
  found only on the LAN are published once added there (they get Accessory Settings), and a device Excluded there
  is left out as `ignoreDevice` leaves it out.
- **Files**: the login and the certificate are kept in the vault (`credentials.json` and `govee.pfx`, kept before,
  move there at the next start); `~/.homeswift/plugins/Govee-<name>/` holds the discovered devices, the devices'
  state and the Eve histories. A first start without a kept login imports the Homebridge plugin's, once, so Govee does not ask for
  a verification code again: node-persist's file for `Govee_All_Devices_temp` in `govee_cache` and
  `persist/govee.pfx` of `homebridgeStoragePath`, else `~/.homebridge`, when it is the same account.
- **Bluetooth** on Linux finds devices by MAC address as the Homebridge plugin does, but does not reset the
  adapter as noble did (that drops BlueZ's other connections): it scans on a raw HCI socket and connects through
  the kernel's L2CAP socket on the ATT channel, so BlueZ may keep running. On macOS it runs through CoreBluetooth,
  which hides MAC addresses: a device is found by the name it advertises (Govee's `bleName`) or by the end of its
  MAC in that name, and so are the thermo-hygrometers' readings. macOS allows Bluetooth only to a binary
  whose Info.plist describes the use (`NSBluetoothAlwaysUsageDescription`); without it the plugin logs that
  Bluetooth is unavailable and runs without it. macOS asks the *responsible* process: homeswift started on its
  own (launchd, `brew services`) is responsible for itself, but started from a shell it is the app that opened
  that shell (an IDE, an agent's app). When that app declares no Bluetooth use, macOS would abort the whole
  bridge at the first Bluetooth call, so the plugin turns Bluetooth off and logs which app is responsible.
- `label` names every device in HomeKit, not only LAN-only ones, as the page's help always said; it is the
  device's Name once the block is written again.
- The page writes no settings: its device editor, scene picker and Settings tab are the Settings page's fields
  (the scenes a list of name and code there), and signing in is Setup's.
- `temperatureSource` works: the Homebridge plugin never read it, so its plug heaters and coolers kept 20°C.
- `customAddress` is used as the device's Bluetooth address.
- Purifiers (`statePuri`), the H7131/H7132 heaters (`stateHeat`, `multiSync`) and the H7105/H7107 fan lights
  (`multiSync`) send the commands of the original homebridge-govee; the Homebridge plugin failed them as
  "Invalid command".
- The H7126 family's speed reports set one of its three speeds (the Homebridge plugin set an invalid value).
- The settings page's "Describe your setup" is left to the runtime's Assistant (`Explain` remains on errors).
- The page's Discover, scenes, DIY effects and capabilities requests without a username in them use the
  instance's own login (its token, else config.json's account), rather than failing: the Assistant uses them so.
- **Clear Cache** also clears what the running instance holds, so the devices' state it kept in memory is not
  written back before the restart.
- Interval options above 2147483647 (seconds, or milliseconds for `bleControlInterval`) are taken as that
  maximum; Node's timers ran such intervals after 1 ms.
