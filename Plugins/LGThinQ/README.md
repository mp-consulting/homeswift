# LG ThinQ

LG ThinQ appliances in HomeKit through LG's cloud, ported from
[homebridge-lg-thinq](https://github.com/mp-consulting/homebridge-lg-thinq) (platform `LGThinQ`; a Homebridge
configuration loads unchanged, and what Homeswift writes is its canonical shape, [Configuration](#configuration)), originally by nVuln, under the Apache License 2.0 (notice and changes in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)). ThinQ v2 devices are pushed over AWS IoT MQTT, with a REST reconciliation every five minutes;
older ThinQ v1 devices are polled. The API is not official: it is what LG's ThinQ app uses.

| Device | HomeKit | Control | ThinQ2 | ThinQ1 |
|---|---|---|---|---|
| Air conditioner, heat pump | Heater Cooler (fan speed, swing, Eve energy), optional sensors, light, fan, mode switches, op-mode buttons | yes | yes | yes |
| Air purifier, AeroTower | Air Purifier, air quality sensor, light, filter, Air Fast (AeroTower: temperature, humidity, UV, 3-level light) | yes | yes | yes (purifier) |
| Refrigerator | a Thermostat for the fridge and the freezer, door, Express Freezer / Express Fridge / Eco Friendly, water filter | yes | yes | yes |
| Washer, dryer, WashTower | Valve with the remaining time, door lock, Program Finished and Tub Clean Coach sensors | no | yes | yes |
| Dishwasher | its own accessory: a Television whose inputs read out the cycle, a Valve, the door, Program Finished | no | yes | no |
| Dehumidifier | Humidifier Dehumidifier with target humidity, speed, tank level, and a humidity sensor | yes | yes | no |
| Oven / range | its own accessory: status board, cook time and timer valves, mode switches, Start/Stop/Monitor Only, door, burners, thermostats | yes | yes | no |
| Microwave | its own accessory: vent fan and lamp, power, status board, cook time and timer, mode switches, thermostat | yes | yes | no |
| Range hood | Fan (vent level) and a dimmable light | yes | yes | yes |
| Styler | Valve with the remaining time | no | yes | no |

## Setting up

Sign in on **Add accessories** (the LG ThinQ row, then its account's Setup; the plugin's page leads there), or
have an AI agent do it through the MCP server's `start_setup` and `continue_setup`. Setup asks how to sign in (LG's
own sign-in page, which also takes accounts that sign in to LG with Google, Apple, Facebook or Amazon: paste the
address it ends on, which contains `iabClose`; or the account's email and password), then the account's country and
language (LG's list of regions); only the refresh token (and the email) are kept, sealed in the vault. Every appliance
of the account is then added. **Open** the plugin's page: it shows the account's region and way of signing in, with
Sign in again, and lists the account's appliances with where each stands (in HomeKit, Excluded, not supported); an
appliance's **Settings** opens its options on the plugin's Settings page
(`/plugins/<slug>/settings?accessory=LGThinQ:<device id>`), where it is also Excluded or included again. The page itself
writes no settings.

## Configuration

What Homeswift writes (docs/adr/0001-canonical-accessory-settings.md): the plugin's settings in the block, each
appliance's in `_accessories` by LG's device id (its Device Id), the sign-in in the vault.

```json
{
  "platform": "LGThinQ",
  "name": "LG ThinQ",
  "auth_mode": "token",
  "country": "US",
  "language": "en-US",
  "thinq1": false,
  "_accessories": {
    "<device id>": { "ac_mode": "BOTH", "ac_swing_mode": "VERTICAL", "ac_air_quality": true },
    "<washer id>": { "washer_trigger": true, "washer_door_lock": true },
    "<dryer id>": { "excluded": true }
  }
}
```

| Plugin Setting | Default | What it does |
|---|---|---|
| `auth_mode` | `token` | How Setup signs in: `token` (LG's page) or `account` (email and password) |
| `country`, `language` | `US`, `en-US` | The account's region (alpha-2 country, language tag), set by Setup |
| `thinq1` | `false` | Also add the account's ThinQ v1 devices |
| `refresh_interval` | `60` | Seconds between ThinQ v1 polls |

Each appliance's Accessory Settings (the schema's `accessorySchema`), besides its Name and Excluded: `serial_number`
(the serial number the Home app shows; empty uses LG's) and the options of its Device Kind, LG's type name:

| Accessory Setting | Device Kinds | What it does |
|---|---|---|
| `washer_trigger` | `WASHER`, `WASHER_NEW`, `WASH_TOWER`, `WASH_TOWER_2`, `DRYER` | A Program Finished occupancy sensor, on for ten minutes |
| `washer_door_lock` | the same (ThinQ2) | The door lock as a Lock Mechanism |
| `washer_tub_clean` | the same | The Tub Clean Coach sensor (on from 30 cycles) |
| `dishwasher_trigger` | `DISHWASHER` | A Program Finished occupancy sensor |
| `ac_mode` | `AC` | `BOTH`, `COOLING` or `HEATING` (any case): the target states offered |
| `ac_swing_mode` | `AC` | `BOTH`, `VERTICAL` or `HORIZONTAL` (any case): the axes swing switches |
| `ac_air_quality` | `AC` | An air quality sensor, when the unit has one |
| `ac_temperature_sensor`, `ac_humidity_sensor` | `AC` | The current temperature and humidity as sensors |
| `ac_led_control` | `AC` | The display light as a light |
| `ac_fan_control` | `AC` | A separate fan (auto and manual speed, swing) |
| `ac_jet_control` | `AC` | A Jet Mode switch (models that have it) |
| `ac_energy_save`, `ac_air_clean` | `AC` | Energy save and air purify switches (models that have them; on by default) |
| `ac_temperature_unit` | `AC` | `C` or `F`: in `F`, temperatures follow the unit's own Fahrenheit table |
| `ac_buttons` | `AC` | `[{ "name": "Dry", "op_mode": 1 }]`: switches that select an operation mode |
| `ref_express_freezer`, `ref_express_fridge`, `ref_eco_friendly` | `REFRIGERATOR` | Switches for those modes |
| `air_fast_mode` | `AIR_PURIFIER`, `AERO_TOWER` | An Air Fast switch |

An Excluded appliance is not set up, not polled and not an accessory.

A Homebridge block still loads: its `refresh_token` (or `username` and `password`), and its `devices` list, the
appliances to add by `id` with their options (empty adds them all), read where `_accessories` and the vault say
nothing. The first settings write (the Settings page, `update_settings`, Setup) moves them: each entry's options into
`_accessories` under its id (its `name` as the Name where it is not LG's own; `type` dropped, the Device Kind is LG's),
every appliance the list left out becomes Excluded, and the list goes; that needs the account's appliances, so while
LG has not listed them yet the list stays. The refresh token (the block's, or the one a password got once it signed in)
and the email go into the vault, and `refresh_token`, `username` and `password` leave the block.

## What differs from the Homebridge plugin

- The sign-in is Setup's (Add accessories, or `start_setup`): the `thinq login` and `thinq auth` commands are its two
  ways of signing in, and the refresh token goes in the vault rather than the block. Each appliance's options are its
  Accessory Settings, on the plugin's Settings page with the Homebridge page's fields (by Device Kind); the plugin's page
  lists the account's appliances and writes no settings. In place of the `devices` allow list, an appliance is
  Excluded. The Assistant's Explain buttons come from the Homeswift UI.
- Accessories are `LGThinQ:<device id>`. Dishwashers, ovens and microwaves are published on their own, as the
  Homebridge plugin publishes them as external accessories: add each in the Home app with the bridge's code.
- When LG's device list comes back empty (an outage, a rate limit), or the request for one of the account's
  homes fails, cached accessories stay instead of leaving HomeKit with their rooms and automations; a device
  that is gone from a list LG did answer for every home, or Excluded, still leaves.
- The MQTT client certificate is requested with a key and a certificate request made with swift-crypto
  instead of node-forge; the broker's root is bundled, never downloaded. The key, the request and each
  device's model JSON are kept, owner-only, in the plugin's storage directory. A key made anew (its file lost
  or unreadable) also gets a new certificate request: the Homebridge plugin kept the old request, whose
  certificate the new key cannot use, and MQTT then never connected.
- ThinQ1 monitoring data is decoded as leniently as Node's `Buffer.from(…, 'base64')`. A ThinQ1 model whose
  control template is not valid JSON fails the HomeKit write, as the Homebridge plugin's `JSON.parse` does,
  instead of sending an empty command. Numbers out of range (a huge `refresh_interval`, a device type or a
  byte layout LG reports oddly) are clamped or skipped instead of stopping the bridge.
- The Assistant (the web UI's chat, MCP clients) can list the appliances this instance runs and every
  appliance of its LG account (`GET devices`, `GET account-devices`), and their settings with `get_settings` and
  `update_settings`. It signs in only through Setup (`start_setup`), where the password or LG's redirected address is
  entered by the person.
- `ac_mode` and `ac_swing_mode` are read in any case: the Homebridge plugin's documentation writes `both` and
  `vertical`, which it then ignored. AeroTowers have `air_fast_mode` and WashTower 2 the washer's options, which the
  Homebridge page left out.
- The schema declares the Plugin Settings under `properties` and each appliance's options in `accessorySchema`; the
  account's keys and the `devices` list are no longer in it.
