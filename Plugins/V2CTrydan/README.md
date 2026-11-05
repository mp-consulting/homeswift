# V2C Trydan

V2C Trydan EV chargers in HomeKit, over their local HTTP interface: no account, no cloud. A new plugin, no Homebridge
counterpart (no Homebridge plugin for the Trydan exists), so its configuration is Homeswift's own.

**Status: experimental.** Tested against fakes built from the test vectors in its spec, not yet on a charger.
Maintainer: Mickael Palma (`mp-consulting`).

## What it does

Each charger is one accessory, `V2CTrydan:<ID>` (the `ID` its `/RealTimeData` reports), category Outlet:

| Service | What it shows | What a write does |
|---|---|---|
| Outlet (primary) | On: charging allowed (`Paused` 0). Outlet In Use: charging. Eve power (W), the lifetime energy (Eve's Total Consumption, kWh), the session's energy (Session Energy, kWh), voltage and current | On pauses or resumes the session (`Paused`) |
| Fan v2 "Charge current" | Active as the Outlet's On; Rotation Speed is the current offered, **in amperes** (the Home app labels it %), up to the installation's maximum | Speed 1-32 sets `Intensity`, clamped to the charger's minimum and maximum; 0 pauses |
| Lock Mechanism "Charger lock" | Secured while the charger is disabled (`Locked` 1) | Locks or unlocks it. A security control: the bridge's MCP tools and Assistant ask before writing it |
| Contact Sensor "Car connected" | Contact detected while a car is plugged in; Status Fault on states E, F and D (pilot, leak, ventilation) | |
| Switches "Charge timer", "Dynamic power", "Pause dynamic" (opt-in) | `Timer`, `Dynamic`, `PauseDynamic` | Sets them |
| Lightbulbs "Light LED" and "Logo LED" (opt-in, when the firmware reports them) | The light ring's level, the logo on or off | Sets them |
| Switches "Timed power", "Solar and minimum", "Solar only", "Solar and grid", "Stop mode" (opt-in) | On for the `DynamicPowerMode` in force | On puts the charger in that mode; Off on the mode in force turns it back on (one mode is always in force) |

The charger is polled every `pollingInterval` seconds (one `/RealTimeData` request; the four optional keywords some
firmware leaves out, `ChargeMode`, `LightLED`, `LogoLED` and `VoltageInstallation`, are asked through `/read/` at the first
poll and then hourly, and never again once the firmware answers 404). Writes are one `/write/` request each, then a
read at once and another two seconds later; slider moves send only their last value. After three failed polls in a row
the accessory shows No Response and the plugin retries after 30 s, 1, 2, 4 and then every 5 minutes; one answer brings it
back. Requests to a charger go one at a time.

Some firmware sends malformed JSON (a duplicated `FirmwareVersion`, an unquoted version, a missing comma before
`ReadyState`): the plugin repairs those and logs it once per firmware version.

**Energy.** The Status page's history records each charger's `ChargePower`, `HousePower`, `FVPower` and `BatteryPower`,
and its diagnostics HomeKit has no place for: the session's time (`chargeTime`, seconds), the meter's code
(`meterError`, 3.5's codes; non-zero is normal without a meter, so it is never a fault), the Wi-Fi signal (`signal`,
its scale undocumented) and the current and voltage of each phase the charger measures (`currentL1`…, `voltageL1`…).
None is counted in the Energy section by default: the car's draw is part of the home's use (a meter plugin counts it), and
the charger's own meter clamp may measure the home or the grid depending on where the installer put it. Tag them per
charger with `houseEnergyRole` (`home` or `grid`) and `solarEnergy`; several chargers on one meter count once.

**The dynamic power mode** (`DynamicPowerMode`: timed, solar and minimum power, solar only, solar and grid, stop) is a
set of switches with `exposeModes`, one per mode, which scenes and automations can turn on (solar only by day, say). The
deprecated "timed power off" (1) is not offered. The Assistant and MCP clients also set it with the `V2CTrydan_set_mode`
tool.

**The lifetime energy.** The charger only reports the session's energy (`ChargeEnergy`, which starts again at each
session). The plugin adds what each reading grew by, or all of it when it fell (a new session), into a total kept in
`chargers.json` in the plugin's storage (written at most every five minutes, and when the plugin stops), so it only grows and survives restarts. It is Eve's Total
Consumption (Eve's history expects a total that only grows) and the Status page's `<Device Id>:energy` series; the
session's energy is the Session Energy characteristic and the `session` series. The total counts from the first read:
what a charger delivered before the plugin ran is not in it, nor a session that started and grew past the last reading
while the bridge was down (its part before the restart is lost).

**The wiring** (`ChargeMode`: single-phase, three-phase or mixed) is an installation setting: set it in the charger's
Accessory Settings (`chargeMode`) and the plugin sends it once, when the charger reports another, and remembers it sent
it (a later change on the charger itself stays until the setting changes).

**The installation's limits** work the same way: `minIntensity` and `maxIntensity` (6 to 32 A, the minimum never above
the maximum, the one not set taken from the charger) and `voltageInstallation` (1 to 500 V). A raised minimum past the
charger's maximum sends the maximum first. A value out of range, or a minimum above the maximum, is not sent (logged
once). `maxIntensity` must never exceed what the wiring and the breaker take: like every Accessory Setting, only an
administrator's settings write sets it, and each write is in the log.

## Configuration

```json
{
  "platform": "V2CTrydan",
  "name": "V2C Trydan",
  "pollingInterval": 10,
  "devices": [{ "host": "192.168.1.50", "name": "Garage charger" }]
}
```

| Plugin Setting | Default | |
|---|---|---|
| `pollingInterval` | 10 | Seconds between reads, 5 at least |
| `timeout` | 5 | Seconds per request |
| `devices` | | Chargers by address (`host`: an IP address, `[IPv6]` or host name, with `:port` when not 80; `name`) |

Once a charger listed in `devices` has answered, the next settings write moves it into its Accessory Settings
(`_accessories` by its Device Id), which also take:

| Accessory Setting | Default | |
|---|---|---|
| `host` | | Its address |
| `exposeCurrent` | true | The "Charge current" fan |
| `exposeLock` | true | The lock |
| `exposeSensors` | true | The "Car connected" sensor |
| `exposeDynamic` | false | The timer and dynamic power switches |
| `exposeLeds` | false | The LEDs, when the firmware reports them |
| `houseEnergyRole` | `none` | `home` or `grid`: how the Energy section counts `HousePower` |
| `solarEnergy` | false | Count `FVPower` as solar |
| `exposeModes` | false | The dynamic power mode switches |
| `chargeMode` | | `monophasic`, `threephase` or `mixed`: the wiring, sent once when it changes |
| `minIntensity`, `maxIntensity` | | 6 to 32 A: the current's limits, sent once when they change |
| `voltageInstallation` | | 1 to 500 V: the installation's voltage, sent once when it changes |

The charger has no password: anyone on the network can read and drive it, and so the plugin keeps no secret.

## Setup

There is nothing to authorize. The plugin finds no charger by itself (the Trydan announces nothing on the network):
add one with **Add by address…** on the instance in the Add accessories page (or `start_setup` with `addByAddress: true`
through MCP). It asks for the address, reads `/RealTimeData` there once, refuses an address where no Trydan answers ("No
V2C Trydan answered at 192.0.2.50"), and keeps the address in the charger's Accessory Settings (`host`) under the `ID` it
answered (`HOST-<address>` for a charger that sends none). The Add accessories page then lists every charger, set up,
with whether it answers. A Homebridge block's `devices` list keeps working, and moves into `_accessories` when the
bridge writes the block.

## Clean-room implementation

Written from the functional spec in [docs/clean-room/V2CTrydan.md](../../docs/clean-room/V2CTrydan.md), without reading
or copying any project's code. The spec writer took the facts (endpoints, keywords, values, the malformed replies) from:

- V2C's public keyword sheet, "V2C - Datamanager Modbus TCP & RTU : HTTP GET Requests" (vendor documentation);
- [pytrydan](https://github.com/dgomes/pytrydan) by Diogo Gomes (MIT License, © 2023 Diogo Gomes);
- Home Assistant's [`v2c` integration](https://github.com/home-assistant/core/tree/dev/homeassistant/components/v2c)
  (Apache License 2.0, the Home Assistant authors);
- for the malformed JSON and timings, the custom integration [V2C_trydant](https://github.com/Rain1971/V2C_trydant)
  by Rafael S. (MIT) and [gladys-v2c-trydan](https://github.com/LM1LC3N7/gladys-v2c-trydan) (Apache License 2.0).

No code was ported, so there is no entry in THIRD-PARTY-NOTICES.md.

## Gaps

Choices made where the spec is silent or a device must confirm, each worth checking on a charger:

1. **Rotation Speed's minimum is 0, not `MinIntensity`.** The spec asks for both a minimum of `MinIntensity` and a write
   of 0 that pauses; HAP refuses a write below the minimum, so the minimum is 0 and 1 up to `MinIntensity` offer the
   minimum. Only `MaxIntensity` changes the props (the accessory is rebuilt, its iids kept).
2. **No `ID`.** A charger that sends none is keyed `HOST-<address>`, its `.` and `:` made `-` and everything else but
   letters, digits, `-` and `_` taken out (`192.0.2.50` is `HOST-192-0-2-50`): taking the dots out as well, as the spec
   says, would give 192.168.1.23 and 192.168.12.3 one Device Id. A later `ID` is logged once, never re-keyed.
3. **`LogoLED`** is on or off (V2C's sheet): on sends 1, unless the charger once reported more than 1, then its last level.
   `LightLED` is dimmable. Verify on hardware which of the two dims.
4. **The meter's figures** are shared as `v2c-meter`, so several chargers of one instance on one meter count once; two
   chargers with separate meters, both tagged, would be averaged rather than added.
6. **Backoff** after three failures is 30 s, 60 s, 120 s, 240 s, then 300 s (`Backoff` doubling); the spec's source goes
   from 120 s to 300 s directly.
7. **The lifetime energy** is the plugin's own sum of the sessions (see above), not the charger's: a session's energy
   during a bridge restart can be partly missed.
8. **Not done:** `ContractedPower` writes (the home's contract with its supplier, and its sign rule depends on the
   dynamic power mode: 3.4), the V2C cloud, MQTT, and firmware without `/RealTimeData`. `SignalStatus` is recorded
   as the charger sends it: its scale is unknown.
9. **Write latency:** how long the charger takes to show a write is unknown; hence the second read after two seconds.
