# Xiaomi

Xiaomi Mi Home Wi-Fi devices in HomeKit, controlled on the local network: lights, plugs, switches, air purifiers,
humidifiers and dehumidifiers, fans, heaters, air conditioners, curtains, temperature and humidity sensors, and robot
vacuums. Each device is reached over miIO (UDP port 54321) at its address with its own token. Its MIoT spec is fetched
once from [miot-spec.org](https://miot-spec.org) and kept, and its standard services and properties become HomeKit
services by their type, so a model the plugin has never seen works when its spec uses the standard types. The older
Roborock-family robots (`rockrobo.vacuum.*`, `roborock.vacuum.*`) speak miIO's vacuum commands instead.

**Maintainer:** Mickael Palma. **Status:** experimental — written and tested against fakes only, not yet checked with a
real device. Reports from someone with Mi Home devices are welcome.

## In HomeKit

| Device | HomeKit |
|---|---|
| Light | Lightbulb: On, Brightness, Color Temperature, Hue and Saturation; Adaptive Lighting with Brightness and Color Temperature |
| Plug, outlet | Outlet (Outlet In Use = On), Current Consumption in watts when the spec has `electric-power`; one Outlet per further switch |
| Switch | A Switch per channel |
| Air purifier | Air Purifier (Active, state, Auto or Manual, Rotation Speed from the fan levels), Air Quality, Temperature and Humidity sensors, Filter |
| Humidifier, dehumidifier | Humidifier-Dehumidifier with its target humidity, Rotation Speed and Water Level; Temperature sensor |
| Fan | Fan v2 (Active, Rotation Speed, Swing Mode); Temperature and Humidity sensors |
| Heater | Heater-Cooler in Heat with its target temperature, or a Switch without one |
| Air conditioner | Heater-Cooler (Auto, Heat, Cool as the device lists them) |
| Curtain | Window Covering: positions, Position State, Hold Position, Obstruction Detected |
| Temperature and humidity sensor | Temperature sensor, Humidity sensor, Battery |
| Robot vacuum | Fan v2 that cleans (on starts a clean, off sends it to the dock), Battery, a Filter Maintenance per filter and brush — the Roborock plugin's shape |

Every accessory has the id `miot:<did>` (the Xiaomi device id, its Device Id); its Serial Number is its MAC address
when the account or the device gives it, else the did. Child lock is Lock Physical Controls on the main service. A
device that misses 4 polls shows No Response and is tried again, waiting longer each time. A spec that does not map
(a vendor's own services) is reached through the extra controls below and the plugin's page.

Devices already in Apple Home, natively or through Matter, are not detected as such: mark them **Not in Home** in their
settings so the Home app does not show them twice.

## Setup

Add accessories (or the MCP tool `start_setup`) adds devices three ways:

1. **Your Xiaomi account, with a QR code** (first): choose the region, open the QR code and scan it with the Mi Home app,
   then confirm on the phone. The account's devices are then listed with their tokens.
2. **Your Xiaomi account, with its password**: the email (or phone number or user id) and password, then the code
   Xiaomi sends by email. An account that sends its code by text message, or asks for a captcha, uses the QR code.
3. **A token per device**: a device found on the network that the account does not list asks for its token (32
   hexadecimal characters); **Add by address…** takes an IP address and a token. The plugin checks the token with the
   device before keeping it.

The account is optional and is used only to sign in and list the devices: control and polling stay on the local
network. Its session and the tokens are in the vault. Discovery sends the miIO hello to the network's broadcast
addresses and merges what answers with the account's list. Bluetooth and Zigbee sub-devices, cloud-only devices,
cameras, speakers, gateways and IR remotes are left out.

## Configuration

A block of [homebridge-miot](https://github.com/merdok/homebridge-miot) loads as it is:

```json
{
  "platform": "miot",
  "micloud": { "username": "user@example.com", "password": "…", "country": "de" },
  "devices": [
    { "name": "Desk Lamp", "ip": "192.168.1.50", "token": "00112233445566778899aabbccddeeff", "deviceId": "123456789",
      "model": "yeelink.light.colorc", "pollingInterval": 10 }
  ]
}
```

With the next settings write the bridge moves each `devices[]` entry with a `deviceId` (or whose did it learned from the
device) into `_accessories` under its did, its token and the account's password into the vault. A device's options
are then its settings: `ip`, `model`, `pollingInterval` (seconds; 15 by default, values from 500 read as milliseconds),
`propertyChunkSize` (1–14), `deviceEnabled`, `micloud`, `customAccessory`, `onlyMainService`, and the extra controls.
Plugin-wide: `micloud.country` (the region), `micloud.timeout`, `pollingInterval`, `pm25Breakpoints`,
`co2AbnormalThreshold`. `nameLanguage`, `prefsDir`, `deepDebugLog`, `silentLog`, `stableId` and the Matter options are
read and ignored. `micloud.forceMiCloud` is read but not supported yet: the device stays on the local network and the
log says so.

## Extra controls

Each is a device setting, shown for the kinds of device it applies to:

- `buzzerControl`, `ledControl`, `modeControl`, `screenControl`, `fanLevelControl`, `swingControl`, `moveControl`,
  `ioniserControl`, `offDelayControl` (only when the spec gives the delay a unit of time), `motorControl`,
  `horizontalAngleButtons`, `verticalAngleButtons`: switches beside the main service.
- `childLockControl` and `showTemperature` (an outlet's temperature sensor): on by default.
- `suppressAutoServiceCreation`: leave out the automatic temperature, humidity or light sensor.
- `actionButtons` (actions of the spec, by name like `filter:reset-filter-life` or id like `4.1`), `methodButtons` (raw
  miIO methods, the answer in the log), `propertyControl` (a switch, slider or switch per value for any writable
  property), `propertyMonitor` (an occupancy sensor while a comparison holds, or a sensor showing a value).

**Changed from homebridge-miot:** every flag that adds a service is off by default. homebridge-miot turned the buzzer,
LED, mode, screen and motor switches on unless told otherwise; a block that relied on that must now set
`buzzerControl`, `ledControl`, `modeControl`, `screenControl` or `motorControl` to `true`.

## The page and the Assistant

The plugin's page lists the devices, and for one of them reads every property of its spec now, with a control for
each writable one (a switch, a menu or a number) and a button for each action: what HomeKit does not show is there.
It writes no settings; each device's Settings are a link away. The Assistant and MCP clients have the same:
`miot_devices`, `miot_properties`, `miot_set_property` and `miot_run_action` (the last two ask before they run).

## How it was tested

`Scripts/test.sh -- --filter XiaomiMiot` runs it against a fake LAN of miIO devices (they decrypt the plugin's packets
with their token and answer as the protocol says), miot-spec.org answered from the saved specs in `Tests/Fixtures`, and a
fake Xiaomi account. The tests check the protocol's and the cloud's test vectors byte for byte (key, IV, hello,
requests, replies, padding, signing, RC4), the HomeKit accessory of ten saved models, writes and changes both ways,
Adaptive Lighting, both kinds of vacuum, every Setup way, discovery, the Homebridge block's move, No Response for a
device that stops answering, and that no token, password or session reaches the log. No device, account or network
is used.

## Clean-room implementation

Compatible with the configuration of [homebridge-miot](https://github.com/merdok/homebridge-miot) by merdok (MIT).
Written from the functional specification in [docs/clean-room/XiaomiMiot.md](../../docs/clean-room/XiaomiMiot.md),
without reading or copying the code of homebridge-miot or of any other miIO implementation. The device specs are those
of Xiaomi's public registry, [miot-spec.org](https://miot-spec.org), fetched at run time.
