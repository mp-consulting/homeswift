# LG ThinQ

LG ThinQ appliances in HomeKit through LG's cloud, ported from
[homebridge-lg-thinq](https://github.com/mp-consulting/homebridge-lg-thinq) (platform `LGThinQ`, same
configuration), originally by nVuln, under the Apache License 2.0 (notice and changes in
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

Add the platform on the **Plugins** page, then **Open** its page: sign in with your LG account (the region,
email and password; only the refresh token is kept unless you ask to remember them), or, for accounts that
sign in to LG with Google, Apple, Facebook or Amazon, through LG's own sign-in page. The page then lists the
account's devices: check the ones for HomeKit (none checked adds them all), set each one's options with ⚙, and
save. The plugin reloads with the new block at once.

```json
{
  "platform": "LGThinQ",
  "name": "LG ThinQ",
  "auth_mode": "token",
  "refresh_token": "…",
  "country": "US",
  "language": "en-US",
  "thinq1": false,
  "devices": [
    { "id": "device id", "name": "Living Room AC", "ac_mode": "BOTH", "ac_swing_mode": "VERTICAL", "ac_air_quality": true },
    { "id": "washer id", "washer_trigger": true, "washer_door_lock": true }
  ]
}
```

| Option | Default | What it does |
|---|---|---|
| `auth_mode` | `account` | `account` (username and password) or `token` |
| `refresh_token` | | The account's refresh token; used first when present |
| `username`, `password` | | The LG account, when there is no refresh token |
| `country`, `language` | `US`, `en-US` | The account's region (alpha-2 country, language tag) |
| `thinq1` | `false` | Also add the account's ThinQ v1 devices |
| `refresh_interval` | `5` (`60` in the form) | Seconds between ThinQ v1 polls |
| `devices` | all | The devices to add, by `id`, with their options |

Per device: `name`, `serial_number`, and

| Option | Devices | What it does |
|---|---|---|
| `washer_trigger` | washer, dryer, wash tower | A Program Finished occupancy sensor, on for ten minutes |
| `washer_door_lock` | washer, dryer (ThinQ2) | The door lock as a Lock Mechanism |
| `washer_tub_clean` | washer | The Tub Clean Coach sensor (on from 30 cycles) |
| `dishwasher_trigger` | dishwasher | A Program Finished occupancy sensor |
| `ac_mode` | AC | `BOTH`, `COOLING` or `HEATING` (any case): the target states offered |
| `ac_swing_mode` | AC | `BOTH`, `VERTICAL` or `HORIZONTAL` (any case): the axes swing switches |
| `ac_air_quality` | AC | An air quality sensor, when the unit has one |
| `ac_temperature_sensor`, `ac_humidity_sensor` | AC | The current temperature and humidity as sensors |
| `ac_led_control` | AC | The display light as a light |
| `ac_fan_control` | AC | A separate fan (auto and manual speed, swing) |
| `ac_jet_control` | AC | A Jet Mode switch (models that have it) |
| `ac_energy_save`, `ac_air_clean` | AC | Energy save and air purify switches (models that have them; on by default) |
| `ac_temperature_unit` | AC | `C` or `F`: in `F`, temperatures follow the unit's own Fahrenheit table |
| `ac_buttons` | AC | `[{ "name": "Dry", "op_mode": 1 }]`: switches that select an operation mode |
| `ref_express_freezer`, `ref_express_fridge`, `ref_eco_friendly` | refrigerator | Switches for those modes |
| `air_fast_mode` | air purifier, AeroTower | An Air Fast switch |

## What differs from the Homebridge plugin

- The sign-in, the device list and the per-device options are this plugin's page in the Homeswift UI, with
  the same steps and fields; the `thinq login` and `thinq auth` commands are the page's two sign-in forms.
  The Assistant's Explain buttons come from the Homeswift UI.
- Accessories are `LGThinQ:<device id>`. Dishwashers, ovens and microwaves are published on their own, as the
  Homebridge plugin publishes them as external accessories: add each in the Home app with the bridge's code.
- When LG's device list comes back empty (an outage, a rate limit), or the request for one of the account's
  homes fails, cached accessories stay instead of leaving HomeKit with their rooms and automations; a device
  that is gone from a list LG did answer for every home, or deselected, still leaves.
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
  appliance of its LG account (`GET devices`, `GET account-devices`), and get LG's sign-in page for
  Google, Apple, Facebook or Amazon accounts. Signing in stays on the plugin's page.
- `ac_mode` and `ac_swing_mode` are read in any case: the Homebridge plugin's documentation writes `both` and
  `vertical`, which it then ignored. The settings page has the options of AeroTowers (`air_fast_mode`) and
  WashTower 2 (the washer's), which the Homebridge page left out.
- The schema is the Homebridge plugin's, with `air_fast_mode` shown for AeroTowers too; its `condition` keys and
  layout types the Homeswift form does not know are ignored.
