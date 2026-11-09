# Zigbee2MQTT

**Experimental**: tested against a fake broker only, not yet with a real Zigbee2MQTT installation.

Puts the devices and groups of a [Zigbee2MQTT](https://www.zigbee2mqtt.io) installation in HomeKit. The plugin never
talks Zigbee: it connects to the MQTT broker Zigbee2MQTT publishes on, reads its device list (each device's `exposes`),
builds one accessory per device and per group, shows its state messages and publishes HomeKit's writes as `set`
messages.

| Zigbee2MQTT exposes | HomeKit |
|---|---|
| `light` | Lightbulb: On, Brightness, Hue and Saturation (`color_hs` or `color_xy`), Color Temperature; Adaptive Lighting on lights with brightness and colour temperature |
| `switch` | Switch, or Outlet with `converters.switch.type: "outlet"`; one per endpoint (`l1`, `l2`…) |
| `cover` | Window Covering: position, tilt, Hold Position; movement from `motor_state`, or from positions asked for every 4 s while it moves |
| `lock` | Lock Mechanism |
| `climate` | Thermostat (heating setpoint, `system_mode` and `running_state`) |
| `temperature`, `humidity`, `illuminance(_lux)`, `pressure`, `contact`, `occupancy`, `presence`, `vibration`, `moving`, `smoke`, `carbon_monoxide`, `water_leak`, `gas`, `device_temperature`, `co2` | The matching sensor, with Status Low Battery and Status Tampered from `battery_low` and `tamper`; air pressure as Eve's |
| `voc`, `pm10`, `pm25` | Air Quality Sensor |
| `power`, `voltage`, `current`, `energy`, `produced_energy` | Eve's consumption characteristics |
| `action` | One Stateless Programmable Switch per button, its single, double and long presses mapped from the action values |
| `battery`, `battery_low` | Battery |

Accessory ids are `zigbee2mqtt:<IEEE address>` and `zigbee2mqtt:group-<id>`, so renaming a device in Zigbee2MQTT keeps
its accessory, room and automations.

## Configuration

Add it on the web UI's **Add accessories** page: Setup asks for the broker's address, Zigbee2MQTT's base topic and the
broker's user name and password, checks that Zigbee2MQTT answers there, and keeps the password in the vault. A
homebridge-z2m block works as it is:

```json
{
  "platform": "zigbee2mqtt",
  "mqtt": { "base_topic": "zigbee2mqtt", "server": "mqtt://localhost:1883", "user": "z2m", "password": "…" },
  "defaults": { "excluded_keys": ["linkquality"] },
  "exclude_grouped_devices": false,
  "devices": [
    { "id": "0x1234567890abcdef", "exclude": true },
    { "id": "Living room lights", "converters": { "light": { "adaptive_lighting": { "transition": 2, "min_delta": 5 } } } }
  ]
}
```

- `mqtt`: `base_topic` and `server` (`mqtt://`, `mqtts://`, `tcp://`, `ssl://`, `tls://`, `ws://`, `wss://`) are
  required; `ca`, `key` and `cert` are paths to PEM files; `user` and `password` are sent only together;
  `reject_unauthorized: false` accepts any certificate; `client_id`, `keepalive`, `version` (3, 4 or 5) and
  `disable_qos`. A `password` in the block is moved to the vault on the next settings write.
- `log`: `debug_as_info`, and `mqtt_publish` (the level of the line logged for each publish).
- `defaults` and `devices`: per-device options (`exclude`, `ignore_availability`, `ignore_z2m_online`, `excluded_keys`,
  `included_keys`, `excluded_endpoints`, `values`, `converters`, `experimental`, `exposes`), a `devices` entry's `id` an
  IEEE address, a friendly name or a group's name or id. Once Zigbee2MQTT's lists say which device an entry names, the
  bridge moves it to that device's Accessory Settings (`_accessories`, by Device Id), where the Settings page edits it.
- `exclude_grouped_devices`: devices in a group appear only through the group.

## Adding devices

**Add a Zigbee device…** on Add accessories lets devices join Zigbee2MQTT's network for two minutes
(`bridge/request/permit_join`) and waits while you reset the device or hold its button. It follows Zigbee2MQTT's
`bridge/event` messages and is done once the device that joined has been interviewed; the network closes again then,
or when the time is up. Zigbee2MQTT's own web page is not needed for it. docs/zigbee-zwave.md runs Zigbee2MQTT and its
broker beside the bridge.

## Behaviour worth knowing

- **Availability works**, and shows No Response: for a device Zigbee2MQTT reports offline (`{"state":"offline"}` or
  plain `offline` on `<device>/availability`, when Zigbee2MQTT's own availability is on for it), and for every device
  while Zigbee2MQTT or the broker is away. homebridge-z2m's version never did (it read Zigbee2MQTT's configuration from
  the wrong object and the device payload from the wrong key), so it needed the `AVAILABILITY` experimental flag and
  still showed nothing; here no flag is needed. `ignore_availability` and `ignore_z2m_online` turn either off for a
  device. The whole accessory shows No Response, its battery included.
- **Groups are kept** across restarts whatever order the broker sends `bridge/devices` and `bridge/groups` in: nothing
  is removed until both lists came.
- A device's accessory is rebuilt when Zigbee2MQTT reports it changed, so a service it no longer has goes at once
  (homebridge-z2m kept it until a restart).
- Writes of one moment (a request's On and Brightness, a slider's drag) go out as one `set` message, at QoS 1
  (Homeswift's MQTT client does not send QoS 2; `disable_qos` sends QoS 0). Messages published while the broker is away
  are kept (the last 200) and sent once it is back.
- A value outside a characteristic's range is shown as it is and warned about once; the range HomeKit was given is not
  widened while the bridge runs.
- Adaptive Lighting is Homeswift's own controller; `only_when_on`, `min_delta` and `transition` apply to its writes, and
  a colour or a white more than 10 mireds away reported by the light turns it off.

### Power On

A light that exposes `power_on_behavior` has a Power On on its settings sheet (or `set_power_on`): Last on (`on`),
Power loss recovery (`previous`) and Off (`off`). One that also exposes `color_temp_startup` comes back in a white:
Custom (`on` at a white; Zigbee2MQTT has no power-on brightness) and the bridge's Natural Light (`previous` at the white
the bridge keeps the time of day's). The values are read from the device's state and sent as one `set`.

## Clean-room implementation

Compatible with the configuration of [homebridge-z2m](https://github.com/itavero/homebridge-z2m) by Arno Moonen
(Apache License 2.0). Written from the functional specification in
[docs/clean-room/Zigbee2MQTT.md](../../docs/clean-room/Zigbee2MQTT.md), without reading or copying its code. The topics
and payloads follow [Zigbee2MQTT's MQTT documentation](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html).

## Tests

`swift test --filter "Zigbee2MQTTTests|RulesTests"`: the spec's vectors (colour conversions, button mappings, names,
availability configuration), and the plugin end to end on a `PluginHost` against `FakeMQTTConnection`: accessories and
their services, state messages, coalesced writes, covers' two state machines, Adaptive Lighting, availability, groups,
the cache, Setup and the settings' canonical shape.

Maintainer: Mickael Palma.
