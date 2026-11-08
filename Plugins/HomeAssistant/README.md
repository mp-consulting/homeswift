# Home Assistant

**Experimental: tested against a fake Home Assistant server only.** Reports from a real server are welcome.

Puts the devices of a [Home Assistant](https://www.home-assistant.io) server in HomeKit, over Home Assistant's
WebSocket API (`/api/websocket`) with a long-lived access token. Each Home Assistant device becomes one accessory and
each of its supported entities one service on it; states follow Home Assistant's `state_changed` events as they
happen, and what you change in the Home app goes back as `call_service`. Several servers can each have their own
instance (platform `HomeAssistant`).

The entities map as Home Assistant's own HomeKit bridge maps them, so an entity looks the same in Apple Home whichever
bridge shows it:

| Domain | HomeKit |
|---|---|
| `light` | Lightbulb: On, Brightness (0–255 ↔ 0–100 %), Hue and Saturation, Color Temperature (kelvin ↔ mireds, the light's own range); Adaptive Lighting for lights with a white temperature |
| `switch`, `input_boolean` | Switch, or Outlet for a switch of device class `outlet` |
| `scene`, `script`, `button`, `input_button` | A Switch that runs it and turns itself off after a second |
| `cover` | Garage Door Opener (`garage`, `gate`), Window, Door or Window Covering, with position, tilt and stop |
| `lock` | Lock Mechanism (a security control: Homeswift's MCP tools and Assistant change it only after you confirm) |
| `climate` | Thermostat: modes, target temperature or heating and cooling thresholds, humidity; °F servers converted |
| `sensor` | Temperature, humidity, light level, CO₂, CO, PM2.5 and PM10 (air quality); battery sensors fill the device's Battery |
| `binary_sensor` | Contact (door, window, opening, garage door), motion, occupancy and presence, leak, smoke, CO and gas |
| `fan` | Fan v2: speed, oscillation, direction, a preset as Target Fan State, or a switch per preset |
| `media_player` | A Power switch, for players that turn on and off |
| `valve` | Valve (a `gas` valve is a security control) |
| `alarm_control_panel` | Security System (a security control) |
| `humidifier` | Humidifier-Dehumidifier |

Any other domain is logged once as not supported and left out. An entity whose state is `unavailable` shows No
Response; `unknown` keeps its last values. An entity with a `battery_level` attribute, a battery sensor or a low-battery
binary sensor gives its device a Battery service.

## Setting it up

Open **Add accessories**, add **Home Assistant**, then choose the server found on your network (or type its address,
`http://homeassistant.local:8123`) and paste a long-lived access token: in Home Assistant, open your profile, then
**Security**, **Long-lived access tokens**, **Create token**. Setup checks the token with the server and keeps it in
Homeswift's vault; the address and the server's id go in the block. Every device of the server is then listed; leave a
whole device out with **Exclude**, or one of its entities by switching it off among the device's parts.

By default Home Assistant's hidden entities and its configuration and diagnostic entities are left out, as Home
Assistant's own HomeKit bridge does (`includeEntities` brings them back), and so are disabled entities and devices.

A user who is not an administrator can be used: the registries are read where Home Assistant allows it, and without
them each entity becomes an accessory of its own.

## Configuration

```json
{
  "platform": "HomeAssistant",
  "name": "Home Assistant",
  "url": "http://homeassistant.local:8123",
  "mirror": ["light.*"],
  "excludeEntities": ["switch.*_child_lock"]
}
```

| Key | Meaning |
|---|---|
| `url` | The address of Home Assistant, as you open it in a browser (http or https; port 8123 when none is given) |
| `accessToken` | A long-lived access token. Setup keeps it in the vault: leave it out of the block. A secret-named key, so the runtime seals and masks it when it is there |
| `serverId` | The `uuid` the server announces over mDNS, kept by Setup |
| `domains` | The domains taken, all of the table's by default |
| `includeEntities`, `excludeEntities` | Entity ids or patterns with `*` and `?`: shown even when hidden or a configuration or diagnostic entity, or left out |
| `mirror` | Entities shown in Homeswift's web UI, scenes, automations and MCP tools but never published to Apple Home (`Accessory.mirroredFrom`): entity ids, patterns, or `all` |
| `lockPasscode`, `alarmPasscode` | Not in the form (credentials never are): set in config.json, sealed in the vault at the next start. The code sent with `lock.lock`/`unlock` and with the alarm's arm and disarm services, for those that ask for one (secret-named keys: sealed and masked) |
| `verifyTLS` | `false` for an `https` address with a self-signed certificate: the first certificate seen is trusted, then pinned |

## Running it beside Home Assistant's own HomeKit bridge

Home Assistant can publish its entities to Apple Home itself (the HomeKit Bridge integration). Running both would show
those entities twice. Either leave them out of one bridge, or list them in `mirror`: Homeswift then shows them in its
web UI, scenes, automations and MCP tools, but keeps them out of HomeKit. The plugin warns once in the log when Home
Assistant has its HomeKit integration loaded; it cannot read which entities that bridge publishes.

The other direction is a loop: if Home Assistant has paired **this** bridge through its HomeKit Controller integration,
Homeswift's own accessories come back as Home Assistant entities. Those are always skipped (by the HomeKit pairing id in
their unique id, by their device's identifiers, or by the manufacturer and serial number of an accessory Homeswift
publishes), with a warning in the log. Other HomeKit Controller devices (an Ecobee, a third-party HomeKit device) are
kept.

## Identity

An accessory's id is `HomeAssistant:<device registry id>`; an entity without a device is `HomeAssistant:entity:<entity
registry id>`, and one that is not in the registry at all `HomeAssistant:state:<entity_id>` (which does not survive a
rename). Each service's subtype is the entity's integration and `unique_id` (`hue.00:17:88:…-0b`), which stays when
you rename an entity's `entity_id` and when an entity is removed and added again (an entity without one uses its
registry `id`): the accessory, its aid and its iids stay, and HomeKit keeps rooms, scenes and automations. The Serial
Number is the device's MAC address from its `mac` connection (uppercase, without separators), else the device's own
serial number, else its id. The suggested room is the entity's or the device's Home Assistant area.

## Gaps against Home Assistant's own HomeKit bridge

Compared with Home Assistant's HomeKit Bridge integration at Home Assistant 2026.12 (the version the specification was
written from), this plugin does not:

- publish televisions (`media_player` of class `tv`, `receiver`, `projector` as a Television service), nor the
  Play-Pause, Play-Stop and Mute switches of media players;
- give climate devices a linked Fan v2 for their fan modes, swing modes and presets;
- map nitrogen dioxide, VOC, ozone, sulphur dioxide or other gas sensors, nor `power` and `energy` sensors (no Meter
  is declared for them yet);
- set a white on an `rgbww`-only light from Color Temperature (Home Assistant's kelvin-to-rgbww formula is not
  specified here), nor expose light effects, `camera`, `vacuum`, `water_heater`, `remote`, `device_tracker`,
  `person`, `lawn_mower`, `event` or `select` entities;
- support Home Assistant's per-entity HomeKit options (linked battery and motion sensors, a feature list per media
  player, a code per lock) beyond the plugin-wide `lockPasscode` and `alarmPasscode`;
- serve the accessories before the server answers after a restart: the cached accessories show their last values, and
  writes wait for the connection.

## How it was tested

`Plugins/HomeAssistant/Tests` runs the plugin against a fake Home Assistant server behind `FakeWebSocket`: the auth
phase (accepted, and a refused token that is never retried), coalesced frames, a dropped connection (No Response, then
a reconnection), the conversions of each domain (brightness, kelvin and mireds, cover position and tilt, °F climates and
modes, lock and alarm states, PM2.5 air quality, CO₂ detection, battery sensors), a state change reaching HomeKit, the
`call_service` each HomeKit write sends (one call for a batch of writes), a renamed entity keeping its accessory and
iids, an entity of this bridge coming back through HomeKit Controller being skipped, mirrored entities, a token without
the registries, Setup and discovery. No server or network is used.

## Clean-room implementation

There is no Homebridge plugin behind it. Written from the functional specification in
[docs/clean-room/HomeAssistant.md](../../docs/clean-room/HomeAssistant.md), without reading or copying Home Assistant's
code; the facts it records (the WebSocket API's messages, the domains' states and attributes, and which domain the
HomeKit Bridge integration maps to which HomeKit service) come from Home Assistant (Apache-2.0, © the Home Assistant
authors) and its developer documentation. This plugin is not affiliated with
Home Assistant.
