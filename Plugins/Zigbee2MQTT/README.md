# Zigbee2MQTT

TODO: the devices this plugin puts in HomeKit, how it reaches them (the local network, a cloud) and what the Home
app shows.

A port of [`TODO`](https://github.com/TODO), Copyright (c) TODO, under the TODO license; its notice is in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) (TODO: add it there). The platform block is the same, so a
Homebridge configuration works unchanged.

**Maintainer:** @TODO, who has the hardware and answers this plugin's issues. **Status:** experimental until someone
with the device confirms it works.

## In HomeKit

Each device is one accessory with:

- Switch (primary): On

## Configuration

```json
{
  "platforms": [
    {
      "platform": "zigbee2mqtt",
      "name": "Zigbee2MQTT",
      "devices": [{ "id": "TODO", "name": "Living Room" }]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `pollingInterval` | 30 | Seconds between polls, 5 at least |
| `devices` | | `id` and `name` of a device, to rename it |

## Tests

`swift test --filter Zigbee2MQTTTests` runs the plugin against a fake API, with no device or account.
