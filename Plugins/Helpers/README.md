# Helpers

Helpers (GLOSSARY.md, "Helper") are accessories whose state the bridge works out from your other accessories. There is
no device behind them, so they never need a sign-in or a network: they read what the bridge already has.

| Kind | What it shows | Example |
|---|---|---|
| **Threshold** | An occupancy sensor, on while a reading is above (or below) the on value, off again once it is back past the off value | "Kitchen hot": on above 25 °C, off below 23 °C |
| **Combine** | A sensor of one measure (temperature, humidity, light level or power) showing the lowest, highest or average of several | "Average temperature" of the bedroom and the living room |
| **Stays** | An occupancy sensor, on once something has been in a state for longer than a duration | "Front door left open": open for more than 10 minutes |

A Helper is an accessory like any other: put it in a room, use it in the Home app's automations and on the web UI's
wall. Timers and webhooks stay in [Dummy](../Dummy).

A core plugin of Homeswift, with no Homebridge plugin behind it. Maintained with Homeswift.

## Adding one

Add the plugin on the web UI's **Add accessories** page, then **Add a Helper…** on its card (or in the plugin's
settings). The sheet asks which kind, then:

- **Threshold**: the reading to watch (any number an accessory reports and tells of its changes: a temperature, a
  humidity, a battery level, a power), whether the Helper turns on above or below, the on value and the off value.
  The gap between them (hysteresis) keeps a reading hovering at the line from turning the Helper on and off; left empty,
  the off value is the on value. A number may have a decimal point or a comma.
- **Combine**: the measure, then the sensors, and whether to show the lowest, the highest or the average.
- **Stays**: the accessory and its state (a contact sensor's Open, a switch's On, a lock's Unsecured, a garage door's
  Open…), and for longer than how many minutes.

Each asks a name. Once added, the Helper's settings sheet (from its tile or the plugin's devices) changes its sources and
values; its kind, and a Combine's measure, stay as they were added: add another Helper for another one. The MCP tools
`discover_devices` (`addLabel: "Add a Helper…"`), `start_setup` with `addByAddress: true` and `continue_setup` do the
same for an AI agent.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "Helpers",
      "name": "Helpers",
      "_accessories": {
        "3f9a2c1b": { "name": "Kitchen hot", "rule": "threshold", "source": "Shelly:shellyht-AB12#10", "direction": "above", "on": 25, "off": 23 },
        "77d0e413": { "name": "Average temperature", "rule": "combine", "measure": "temperature", "function": "average",
                      "sources": ["Shelly:shellyht-AB12#10", "Dirigera:9c2f#12"] },
        "c01b5e88": { "name": "Front door left open", "rule": "stays", "source": "Dirigera:51aa#10", "state": "1", "minutes": 10 }
      }
    }
  ]
}
```

Setup writes these; there is nothing to type by hand. Each Helper is an entry of `_accessories` by its Device Id (eight
characters Setup draws), so its accessory id is `Helpers:<Device Id>` and stays the same as long as it exists.

| Setting | For | What it is |
|---|---|---|
| `rule` | all | `threshold`, `combine` or `stays`: the Helper's Device Kind, set when it is added |
| `source` | Threshold, Stays | The characteristic read: its accessory's id, `#`, the characteristic's iid. Both stay the same across restarts |
| `direction` | Threshold | `above` (the default) or `below` |
| `on`, `off` | Threshold | The on value, and the off value (the on value when absent). Above: off at most on; below: off at least on |
| `measure` | Combine | `temperature`, `humidity`, `lightLevel` or `power`, set when it is added |
| `sources` | Combine | The characteristics combined, each as `source` is written |
| `function` | Combine | `min`, `max` or `average` (the default) |
| `state` | Stays | The value waited on: `1` and `0` for a flag or a contact sensor's Open and Closed, a named state's number otherwise |
| `minutes` | Stays | For longer than how many minutes, 0 to 10080 (a week) |

HomeKit has no power sensor: a Combine of power is a light sensor whose level is the watts, with Eve's Current
Consumption beside it, as the APsystems ECU shows its solar power.

## How it works

- The plugin reads its sources on every server the bridge runs (its own bridge, child bridges, accessories published on
  their own) and follows their changes as they happen; nothing is polled.
- A source missing (its plugin not started yet, its device Excluded or gone) or No Response makes the Helper No
  Response, until every source answers again. A Combine needs all its sources.
- A Threshold between its off and on values keeps the state it had; at a restart it starts off.
- A Stays counts from when it last saw its source enter the state: after a restart, or once its source answers again,
  it counts from then.
- Changing a Helper's settings reloads the plugin; the Helper keeps its accessory id, so HomeKit keeps its room and its
  automations.

## Testing

`Tests/HelpersTests.swift` runs the plugin on a bridge beside a fake plugin's sensors, contact sensor and power meter:
each rule as its sources change, the hysteresis, a Stays' duration on a shortened minute, No Response when a source is
missing or unreachable, Setup's steps and checks, and the settings' choices.
