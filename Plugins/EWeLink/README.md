# eWeLink

eWeLink devices (SONOFF and every brand on the eWeLink app) in HomeKit: switches, outlets with power
monitoring, lights, curtains, fans, thermostats, sensors, panels, RF Bridge remotes and sensors, Zigbee devices
and eWeLink groups, plus simulations that show a switch as a blind, a garage door, a lock, a valve, a heater and
more. A port of [`@mp-consulting/homebridge-ewelink`](https://github.com/mp-consulting/homebridge-ewelink), originally by bwp91,
under the MIT license (notice in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)): the
platform name (`eWeLink`) and every option are read, so a Homebridge block loads unchanged; what Homeswift writes is
its canonical shape ([Configuration](#configuration)).

- **Hybrid connection.** Commands go over the LAN first (devices found over mDNS, `_ewelink._tcp`, which mDNS
  proxies carry across VLANs; AES-128-CBC encrypted HTTP to `/zeroconf/switch`), and through the cloud otherwise.
  A device whose LAN commands fail three times in a row is skipped for a minute.
- **Real-time updates** over the eWeLink WebSocket, which reconnects with exponential backoff (5 s doubling to
  5 min, ±20 %) and logs in again when the session was taken over by another login. Devices also send updates
  over UDP (port 8082); an encrypted device's update counts only when it decrypts with its key, and no datagram
  changes the address commands go to (mDNS and the cloud do).
- **Cloud commands are queued**: 250 ms apart, three at a time by default (`commandQueueInterval`,
  `commandQueueConcurrency`), so a scene switching twenty devices does not trip eWeLink's limits. A command that
  never left is retried, one that timed out is retried once, one lost when the socket closed is never resent.
- **Login** with an email or a phone number, signed as the eWeLink app signs it; the region follows the country
  code and eWeLink's redirects; a password stored in base64 is tried decoded; expired tokens are refreshed.
- **Animated scenes.** A Homeswift scene's effect plays as one of a SONOFF L2 strip's own scenes (Candle, Sunrise,
  Sunset, Rainbow, Ocean, Moonlight, Sunshine, Dream, or following the music), as homebridge-ewelink's L2 modes
  list them; other lights, and styles the strip has no scene for, are played by Homeswift.
- **Offline first.** The devices of the last discovery are kept, so at launch the accessories work (over the
  LAN) before the cloud answers, and keep working while it is down. Login and discovery retry with backoff
  (15 s doubling to 5 min).

## Supported devices

| Category | UIIDs |
|---|---|
| Single-channel switches | 1, 6, 14, 24, 27, 77, 78, 81, 107, 112, 138, 160, 209 |
| Multi-channel switches (one accessory per channel: `SW1` drives outlet 0, `SW2` outlet 1...; `SW0`, the master, all of them) | 2, 3, 4, 7, 8, 9, 29, 30, 31, 82, 83, 84, 113, 114, 126, 139–141, 161, 162, 210–212 |
| Outlets with power monitoring (Eve watts, volts, amps) | 5, 32, 165, 182, 190, 191, 225, 226, 262, 276 |
| SwitchMan R5 (6 programmable buttons) and S-MATE | 174, 177 |
| Lights: dimmable, CCT, RGB, RGB+CCT | 36, 44, 57, 52, 103, 22, 33, 59, 104, 135–137, 173 |
| Curtains, and a DUALR3 in motor mode | 11, 67, 91, 258, 126 |
| Temperature/humidity (TH10/TH16), contact, motion | 15, 181, 102, 154, 130 |
| Thermostat, air conditioner, humidifier, diffuser, ceiling fans | 127, 151, 19, 25, 34 |
| NSPanel, NSPanel Pro, CAST | 133, 195, 228, 223 |
| RF Bridge (its remotes and sensors) and Zigbee bridges | 28, 98, 66, 128, 168, 243 |
| Zigbee switches, lights, curtains, sensors, thermostats, the SWV-BSP water valve (a faucet) | 1000+, 7000+ |
| Virtual devices, eWeLink groups | 265, 5000 |

The full list, with each UIID's channels, power monitoring and parameters, is `Sources/DeviceCatalogData.swift`,
generated from the Homebridge plugin's catalog.

## Configuration

What Homeswift writes (docs/adr/0001-canonical-accessory-settings.md): the plugin's settings in the block, each
device's in `_accessories` by its eWeLink device id (its Device Id; a channel's or an RF sub-device's accessory,
`eWeLink:<id>SW<n>`, has its device's), the account in the vault.

```json
{
  "platform": "eWeLink",
  "name": "eWeLink",
  "countryCode": "+1",
  "mode": "auto",
  "_accessories": {
    "1000aaaaaa": { "showAs": "valve", "disableTimer": true },
    "1000bbbbbb": { "hideChannels": "4" },
    "1000cccccc": { "excluded": true }
  }
}
```

| Plugin Setting | Type | Default | Description |
|--------|------|---------|-------------|
| `countryCode` | string | `+1` | Country dial code (e.g. `+1`, `+44`, `+86`): picks the API region; Setup asks for it |
| `mode` | string | `auto` | `auto` (LAN, then the cloud), `lan` (LAN only), `wan` (cloud only) |
| `debug` | boolean | `false` | Accessories log their debug lines (run `homeswift -D` to see them) |
| `disableDeviceLogging` | boolean | `false` | No per-device state lines at info level; a device's own setting overrules it |
| `offlineAsOff` | boolean | `false` | Offline devices read as off instead of "No Response" |
| `commandQueueInterval` | number | `250` | Milliseconds between queued cloud commands |
| `commandQueueConcurrency` | number | `3` | Cloud commands in flight at once |
| `bridgeSensors` | array | | RF sub-device settings, by `fullDeviceId` (`curtainType` `blind`, `door`, `window` turns an RF curtain into a timed cover) |
| `groups` | array | | Accepted; eWeLink's own groups come from the account |

### Accessory Settings

Besides Excluded, a device has the Accessory Settings of its Device Kind (the schema's `accessorySchema`, `x-kinds`):
its category (`single`, `multi`, `thermostat`, `light`, `fan`, `sensor`, `rf_bridge`, `outlet`, `air_conditioner`,
`panel`…), whose list its entry went in under Homebridge.

| Device Kind | Keys |
|---|---|
| `single` | `showAs` (`default`, `outlet`, `switch`, `valve`, `tap`, `lock`, `garage`, `gate`, `sensor`, `sensor_leak`, `p_button`, `doorbell`, `purifier`, `tv`, `heater`, `cooler`), `isInched`, `inUsePowerThreshold`, `sensorType`, `tempSource` (heater/cooler), `disableTimer` (valve/tap), `type` (lock), `lowBattThreshold` |
| `outlet` | `isInched`, `inUsePowerThreshold` |
| `air_conditioner`, `panel` | `offset`, `offsetFactor` |
| `multi` | `showAs` (`default`, `outlet`, `blind`, `door`, `window`, `garage`, `gate`, `lock`, `valve`), `hideChannels` (`1,2` or full ids), `inchChannels` (hides the master), `operationTime`, `operationTimeDown` (seconds, covers), `sensorType`, `tempSource`, `disableTimer`, `type` |
| `thermostat` | `showAs` (`default`, `thermostat`, `heater`, `cooler`, `humidifier`, `dehumidifier`), `tempOffset`, `offsetFactor`, `humidityOffset`, `humidityOffsetFactor`, `minTarget`, `maxTarget`, `targetTempThreshold` (hysteresis, °C), `showHeatCool` |
| `light` | `showAs: fan` (a dimmer as a fan), `brightnessStep`, `deviceModel: offlineAsOff`, `adaptiveLightingShift` (mireds warmer; -1 leaves Adaptive Lighting off) |
| `fan` | `hideLight` |
| `sensor` | `hideTemp`, `hideHumidity`, `hideSwitch`, `tempOffset`, `humidityOffset`, `lowBattery` |
| `rf_bridge` | `subdevices`: `index`, `label`, `showAs` (`motion`, `contact`, `water`, `smoke`, `co`, `co2`, `occupancy`, `button`, `doorbell`), `resetTime`, `operationTime`, `operationTimeDown` |
| every kind | `disableDeviceLogging`, the plugin's being its default |

A light with brightness and colour temperature has Adaptive Lighting, which a colour set in the eWeLink app turns off.

A Homebridge block still loads: its `username` and `password`, `ignoredDevices`, and the seven lists `singleDevices`,
`multiDevices`, `thDevices`, `lightDevices`, `fanDevices`, `sensorDevices` and `rfDevices`, by `deviceId`, read under
`_accessories`. The first settings write (the Settings page, `update_settings`, Setup) moves the lists' entries into
`_accessories` (a device in two lists takes its own category's first) and drops the lists, makes `ignoredDevices`
Excluded devices (a channel's id, which never matched a device, stays in it), and moves the account into the vault.
The keys that never had an effect (`label`, `ignoreDevice`, `ipAddress`, `overrideLogging`, `language`,
`hideDevFromHB`…) are accepted and dropped then; accessory ids do not change.

## Signing in

The account is signed in to on **Add accessories** (Setup, docs/plugins.md): the email or phone number, the password
and the country code, checked with a login. The username and the password go in the bridge's vault, not in `config.json`, and the
session the login gives in the plugin's own vault entry. An AI agent does the same through the MCP server's
`start_setup` and `continue_setup`. A block with a `username` and a `password`, pasted from Homebridge, signs in by
itself.

## The page

**Open** on the Plugins page shows the Homebridge plugin's settings page, without its login: while the account is not
signed in, a card leads to its Setup on Add accessories; once it is, the account with **Sign in again**, the account's
devices with their LAN address (a 3 s mDNS scan runs while the cloud answers), the RF sub-devices under their bridge
with their buttons, online, LAN and RF badges, and an **Explain** for offline devices and devices missing on the LAN
when the Assistant is set up, and a **Settings** link on each device to its Accessory Settings
(`/plugins/<slug>/settings?accessory=eWeLink:<deviceId>`). The page writes no settings: the connection mode, debug,
`offlineAsOff` and the rest are on the plugin's Settings page.

The page's requests: `GET devices`, `POST test-device`, `GET accessories` (the instance's accessories with their kept
values, Homebridge's `/getCachedAccessories`), `GET status`. They use the session the plugin logged in with.

The Assistant (the web UI's chat, MCP clients) can call three of them as tools: `eWeLink_status`,
`eWeLink_list_devices` and `eWeLink_test_device` (admin, confirmed first). Signing in is Setup's.

## Files

Under the instance's directory (`~/.homeswift/plugins/eWeLink-<name>/`), owner-only: `devices.json` (the last discovery, for offline-first launches) and
`accessory-context.json` (covers' positions, thermostats' targets, valves' durations). The session, reused for a day, is
sealed in the vault (`plugin.<instance>.ewelink-tokens.json`).

## What differs from the Homebridge plugin

- Signing in is Setup's, and the session stays in the plugin: the browser never receives an access token (the
  Homebridge page passed it back with every request). "Describe your setup" is the Homeswift UI's own Assistant.
- `hideChannels` hides the channels it names (by number or full id), and `inchChannels` the master channel; the
  Homebridge plugin only logged them.
- Ignored devices leave HomeKit; Homebridge kept their cached tile.
- `disableDeviceLogging` can be set per device, the plugin's being its default.
- An accessory's services are rebuilt when its type changes (Homeswift replaces accessories rather than mutating
  them); the aid and iids stay.
- A multi-channel device's channel n drives outlet n - 1 (eWeLink numbers outlets from 0) and the master
  channel all of them. The Homebridge plugin drove outlet n from channel n (so `SW1` switched the second outlet and
  the last channel nothing), the master only outlet 0, and every channel shown as an outlet outlet 0.
- When another client signs in to the same account (each login ends the other's session), the WebSocket's
  backoff keeps growing up to 5 minutes instead of starting over at 5 s after every fresh login: it starts over
  only after a connection stayed up for a minute. The Homebridge plugin reset it on each login, so the two
  clients took the session from each other about every half minute, forever.
- A UDP update never moves a device's LAN address (the Homebridge plugin followed any encrypted datagram, which
  anyone on the LAN can replay from another host); the address comes from mDNS and the cloud.
- Numbers from devices, the cloud and the configuration are read as JavaScript would but never crash the bridge:
  NaN and the infinities count as missing, and values out of range are clamped.
- `SensorVisibleAccessory` (a DW2 sensor driving a garage door or lock) is not ported: no setting of the
  Homebridge plugin routes a device to it.
