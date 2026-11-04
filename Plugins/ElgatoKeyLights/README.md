# Elgato Key Lights

Elgato Key Light, Key Light Air, Key Light Mini and Ring Light in HomeKit: power, brightness and colour
temperature, found over Bonjour, polled so changes made with the Control Center app or the light's buttons
show up in the Home app.

A port of [`@mp-consulting/homebridge-elgato-key-lights`](https://github.com/mp-consulting/homebridge-elgato-key-lights),
originally by Julian J. Maurer, under the MIT license (notice in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)).
A Homebridge configuration loads unchanged; what the bridge writes is the canonical shape below.

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

That is enough: every light on the network is added. Edit the settings on the web UI's **Settings** page of the
plugin (each light's from its accessory), or with the MCP tools `get_settings` and `update_settings`. The Plugin
Settings:

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
| `addresses` | `[]` | Lights Bonjour does not reach (a container without multicast, another network): `host` (an IP address or a host name), `port` (9123 by default) and `mac`. Without a MAC the plugin asks the light for it, and writes it there at the next settings change. Announcements never move such a light |

Each light's Accessory Settings sit in the block's `_accessories`, by its MAC (the Device Id; the accessory id is
`ElgatoKeyLights:<MAC>`): the Core ones (its Name, room, Excluded…) and `powerOnBehavior`, `powerOnBrightness` and
`powerOnTemperature`, which overrule the Plugin Settings of the same names for that light (`powerOnTemperature: 0`
keeps the light's own), and `host` and `port` for a light added by its address.

**Add by address…** on the instance in the Add accessories page (or `start_setup` with `addByAddress`) asks for a
light's IP address or host name and its port (9123 by default), asks the light there who it is, and keeps where it
answers in its Accessory Settings under its MAC: the plugin reaches it there, as a light of `addresses`, without
Bonjour. Nothing answering says so in the sheet ("No light answered at 192.0.2.50:9123"). `addresses` keeps working.

```json
{
  "platform": "ElgatoKeyLights",
  "name": "Elgato Key Lights",
  "pollingRate": 1000,
  "powerOnBehavior": 2,
  "powerOnBrightness": 20,
  "powerOnTemperature": 4695,
  "addresses": [{ "host": "192.168.1.50", "mac": "3C:6A:9D:04:0A:0C" }],
  "_accessories": {
    "3C:6A:9D:04:0A:0B": { "name": "Desk Light", "powerOnBrightness": 40 },
    "3C:6A:9D:04:0A:0D": { "excluded": true }
  }
}
```

### A Homebridge block

The Homebridge plugin's `devices` list (by `mac`: `displayName`, `ip`, `host`, `port`, `enabled`, `powerOnBehavior`,
`powerOnBrightness`, `powerOnTemperature`) still loads, read where `_accessories` and `addresses` say nothing. The first
settings change written through the bridge moves it: `enabled: false` becomes Excluded, `displayName` the Name, the
power-on settings the light's own (`powerOnBehavior: 0`, the platform's, is dropped), `ip` or `host` and `port` an
entry of `addresses`. An entry without a MAC stays as it is.

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin, a page with what the Homebridge
plugin's page shows: every light the instance knows (its state, address, serial and firmware, whether it answers),
the ones it tried that did not answer (offline, with why) and the Excluded ones; **Identify** flashes one and **Test
connection** asks it who it is. **On the network** lists the lights Bonjour announces (the Homebridge plugin's
**Discover**, kept up to date since Homeswift browses all the time); **Check an address** asks a light Bonjour does not
reach for its name and MAC (`macAddress` in `accessory-info`, else the ARP table), to put in `addresses`. The page
writes no settings: **Settings** opens the plugin's Settings page, and a light's menu its own. With the Assistant on,
**Explain** sits next to errors; without, a tip says how to set it up. `Web/` holds the page; `Sources/WebFiles.swift`
is generated from it.

## How it works

Lights announce `_elg._tcp` over Bonjour with their MAC in the TXT record. The plugin resolves each one
(its host name through the ARP table, or the announced address with `useIP`), reads `/elgato/accessory-info`, `/elgato/lights` and `/elgato/lights/settings` over HTTP on port 9123, applies
the power-on settings from the configuration, and adds a lightbulb accessory with Brightness and Color
Temperature (143 to 344 mirek, the light's range). Writes go straight to the light; after three failed polls
the light counts as unreachable and the Home app shows "No Response" until it answers again. A light announced
again on a new address is followed.

Accessories are cached by the runtime, so the lights are in the Home app right after launch, before they
answered. The accessory id is `ElgatoKeyLights:<MAC>`, the Device Kind of every light `light`.
