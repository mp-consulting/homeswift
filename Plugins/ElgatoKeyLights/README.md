# Elgato Key Lights

Elgato Key Light, Key Light Air, Key Light Mini and Ring Light in HomeKit: power, brightness and colour
temperature, found over Bonjour, polled so changes made with the Control Center app or the light's buttons
show up in the Home app.

A port of [`@mp-consulting/homebridge-elgato-key-lights`](https://github.com/mp-consulting/homebridge-elgato-key-lights).
The platform block is the same, so a Homebridge configuration works unchanged.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "ElgatoKeyLights",
      "name": "Elgato Key Lights"
    }
  ]
}
```

That is enough: every light on the network is added. The options:

| Option | Default | What it does |
|---|---|---|
| `pollingRate` | `1000` | Milliseconds between polls of each light; `250` at least |
| `powerOnBehavior` | the light's | `1` restores the last settings when the light is switched on, `2` the defaults below |
| `powerOnBrightness` | the light's | Brightness in percent for `powerOnBehavior: 2` |
| `powerOnTemperature` | the light's | Colour temperature in kelvin (2900 to 7000) for `powerOnBehavior: 2` |
| `switchOnDurationMs` | the light's | Fade-in when switching on |
| `switchOffDurationMs` | the light's | Fade-out when switching off |
| `colorChangeDurationMs` | the light's | Transition between colour temperatures |
| `useIP` | | Accepted for compatibility: Homeswift always connects to the address Bonjour resolved and uses the host name only when there is none |
| `devices` | `[]` | Per-light settings, see below |

Per light, keyed by MAC address (`id` in the light's Bonjour record; the log prints it when a light is found):

| Option | What it does |
|---|---|
| `mac` | The light's MAC address, in any usual spelling |
| `displayName` | The name in HomeKit, instead of the one the light reports |
| `ip`, `host`, `port` | Reach the light here without Bonjour, e.g. in a container without multicast; `ip` wins over `host`, the port defaults to 9123 |
| `enabled` | `false` keeps the light out of HomeKit, and removes it if it was there |
| `powerOnBehavior`, `powerOnBrightness`, `powerOnTemperature` | Override the platform's values for this light; `powerOnBehavior: 0` means the platform's |

```json
{
  "platform": "ElgatoKeyLights",
  "name": "Elgato Key Lights",
  "pollingRate": 1000,
  "powerOnBehavior": 2,
  "powerOnBrightness": 20,
  "powerOnTemperature": 4695,
  "devices": [
    { "mac": "3C:6A:9D:04:0A:0B", "displayName": "Desk Light" },
    { "mac": "3C:6A:9D:04:0A:0C", "ip": "192.168.1.50", "enabled": true }
  ]
}
```

## How it works

Lights announce `_elg._tcp` over Bonjour with their MAC in the TXT record. The plugin resolves each one,
reads `/elgato/accessory-info`, `/elgato/lights` and `/elgato/lights/settings` over HTTP on port 9123, applies
the power-on settings from the configuration, and adds a lightbulb accessory with Brightness and Color
Temperature (143 to 344 mirek, the light's range). Writes go straight to the light; after three failed polls
the light counts as unreachable and the Home app shows "No Response" until it answers again. A light announced
again on a new address is followed.

Accessories are cached by the runtime, so the lights are in the Home app right after launch, before they
answered. The accessory id is `ElgatoKeyLights:<MAC>`.

Not ported: the ARP lookup the Homebridge plugin used to turn a `.local` host name into an address (Bonjour
gives the address directly), and the custom settings page of the Homebridge UI.
