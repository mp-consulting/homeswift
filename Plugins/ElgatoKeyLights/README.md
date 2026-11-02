# Elgato Key Lights

Elgato Key Light, Key Light Air, Key Light Mini and Ring Light in HomeKit: power, brightness and colour
temperature, found over Bonjour, polled so changes made with the Control Center app or the light's buttons
show up in the Home app.

A port of [`@mp-consulting/homebridge-elgato-key-lights`](https://github.com/mp-consulting/homebridge-elgato-key-lights),
originally by Julian J. Maurer, under the MIT license (notice in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)).
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
| `powerOnTemperature` | the light's | Colour temperature in kelvin (2900 to 7000) for `powerOnBehavior: 2`; `0` keeps the light's |
| `switchOnDurationMs` | the light's | Fade-in when switching on |
| `switchOffDurationMs` | the light's | Fade-out when switching off |
| `colorChangeDurationMs` | the light's | Transition between colour temperatures |
| `useIP` | `false` | `true` connects to the address Bonjour announced. Off, the plugin connects to the light's `.local` host name, turned into an address through the ARP table (by the light's MAC), then the addresses Bonjour announced |
| `devices` | `[]` | Per-light settings, see below |

Per light, keyed by MAC address (`id` in the light's Bonjour record; the log prints it when a light is found):

| Option | What it does |
|---|---|
| `mac` | The light's MAC address, in any usual spelling |
| `displayName` | The name in HomeKit, instead of the one the light reports |
| `ip`, `host`, `port` | Reach the light here without Bonjour, e.g. in a container without multicast; `ip` wins over `host`, the port defaults to 9123 |
| `enabled` | `false` keeps the light out of HomeKit, and removes it if it was there (Excluding the light by its MAC on the web UI's **Add accessories** page does the same) |
| `powerOnBehavior`, `powerOnBrightness`, `powerOnTemperature` | Override the platform's values for this light; `powerOnBehavior: 0` means the platform's, `powerOnTemperature: 0` the light's own |

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

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin, a page with what the Homebridge
plugin's settings page does: every light the instance knows (its state, address, serial and firmware, whether
it answers), the configured ones that did not answer (offline, with why, their settings and **Remove**) and the
disabled ones from config.json; **Identify** flashes one. **Settings** keeps a light in or out of HomeKit, names
it, and sets what it does when switched on (the platform's setting, the last settings, or a default brightness
and colour temperature), with a connection test. **On the network** lists the lights Bonjour announces (the
Homebridge plugin's **Discover**, kept up to date since Homeswift browses all the time) and adds one to
config.json; **Add by address** adds a light Bonjour does not reach, asking it for its MAC (`macAddress` in
`accessory-info`, else the ARP table). With the Assistant on, **Explain** sits next to errors; without, a tip
says how to set it up. Saving applies at once, no restart. `Web/` holds the page; `Sources/WebFiles.swift` is
generated from it.

## How it works

Lights announce `_elg._tcp` over Bonjour with their MAC in the TXT record. The plugin resolves each one
(its host name through the ARP table, or the announced address with `useIP`), reads `/elgato/accessory-info`, `/elgato/lights` and `/elgato/lights/settings` over HTTP on port 9123, applies
the power-on settings from the configuration, and adds a lightbulb accessory with Brightness and Color
Temperature (143 to 344 mirek, the light's range). Writes go straight to the light; after three failed polls
the light counts as unreachable and the Home app shows "No Response" until it answers again. A light announced
again on a new address is followed.

Accessories are cached by the runtime, so the lights are in the Home app right after launch, before they
answered. The accessory id is `ElgatoKeyLights:<MAC>`.
