# ESPHome

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
      "platform": "esphome",
      "name": "ESPHome"
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `pollingInterval` | 30 | Seconds between polls, 5 at least |

Each device's settings (its name, room, Excluded) are in its Accessory Settings, under `_accessories` by device id,
edited on the plugin's Settings page. A Homebridge block's `devices` list (`id` and `name`) still loads, and moves
there with the next settings write.

## Tests

`swift test --filter ESPHomeTests` runs the plugin against a fake API, with no device or account.
