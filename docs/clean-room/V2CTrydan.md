# V2C Trydan: functional specification (clean room)

Written by the spec writer; contains no source code. Everything below is a description, in the spec writer's own
words, of the behaviour of the sources listed under Provenance. Identifiers that are part of an interface (HTTP
paths, JSON keys, keyword names, enum values, response bodies) are quoted exactly because they are wire interfaces.
Statements are tagged with their source in brackets: **[V2C]**, **[pytrydan]**, **[HA]**, **[HACS]**, **[Gladys]**.
Anything labelled **Recommendation** is the spec writer's proposal for Homeswift, not observed behaviour.

## 0. Provenance

| Tag | Source | Commit / version read | Licence | Copyright line |
|---|---|---|---|---|
| [V2C] | V2C's own public keyword sheet "V2C - Datamanager Modbus TCP & RTU : HTTP GET Requests", linked from pytrydan's README: `https://docs.google.com/spreadsheets/d/e/2PACX-1vQGA_7Z4YaSMZeHRTnAP6z_82dVPmM33NxJhvsDBEFn8LyWjX-RX_fkR7KCErqAE4aGFvPrUufooHoM/pubhtml?gid=1147522182&single=true` (read as its CSV export) | sheet says "Last Review 14/07/26" | none stated (vendor documentation; used for facts only) | none |
| [pytrydan] | https://github.com/dgomes/pytrydan (PyPI `pytrydan`) | `9f4ea76373a5205070385b86a5153c5a8e09774a` (2026-09-15), version 1.0.6 | MIT | "Copyright (c) 2023 Diogo Gomes" |
| [HA] | https://github.com/home-assistant/core, `homeassistant/components/v2c` and `tests/components/v2c` (sparse clone) | `5be1efbb099aa4dd91bd251337dbb3180331fa9c` (2026-11-04); manifest requires `pytrydan==1.0.5` | Apache License 2.0 (`LICENSE.md`; no copyright line in it, holder is the Home Assistant authors / Open Home Foundation) | none in the licence file |
| [HACS] | https://github.com/Rain1971/V2C_trydant (custom integration `v2c_trydan`) | `3b2f428e1e5d8c9da72aa14f25a0f1fa58ff5d16` (2026-04-03) | MIT | "Copyright (c) [2023] [Rafael S.]" |
| [Gladys] | https://github.com/LM1LC3N7/gladys-v2c-trydan (consulted for timings only; itself derived from pytrydan) | `43a2c8020df1e4eb8b6b5fc98c4d60d92e6d3962` (2026-10-23) | Apache License 2.0 | none in the licence file |

**Homebridge plugin:** none usable. npm has no `homebridge-v2c*` or `homebridge-trydan*` package. The only GitHub
repository with that name, `Valou49c/homebridge-v2c-trydan` ("Pluging for V2C Trydan EV Charger"), is **empty**
(no commits, size 0, no licence). There is therefore no Homebridge configuration to stay compatible with; section 2
is a Recommendation.

**V2C cloud API:** V2C runs a cloud API (an API key from the V2C Cloud app). None of the sources read use it; one
Jeedom plugin that does (`kornflex/v2c_trydan`) has no licence and was **not** read. Out of scope: the plugin is
local only (see Gaps).

Nothing was installed or executed. All repositories were cloned under the scratchpad and read as data.

## 1. Scope and devices

- Device: the **V2C Trydan** wall-box EV charger (EVSE), Wi-Fi or Ethernet, single-phase or three-phase.
  [HA] names the device manufacturer "V2C", model "Trydan". Other V2C products (Trydan Pro, Eleqtron, etc.) are not
  claimed by any source; if they answer the same `/RealTimeData` they work unchanged (not verified).
- Transport: plain HTTP on port 80, **no authentication, no TLS** [V2C, Gladys]. Anyone on the LAN can read and
  drive the charger.
- Poll-only: the device pushes nothing over HTTP. (It can publish/subscribe MQTT for dynamic power on some firmware;
  no source here uses it: Gaps.)
- One charger per host. A home may have several chargers: each is its own accessory.
- Discovery: no source performs any (no mDNS/SSDP service is documented). The user enters an IP address or host
  name [HA config flow: one field, `host`].

## 2. Configuration interface (Recommendation)

No Homebridge plugin exists, so this is a proposal shaped like Homeswift's other local plugins.

Platform name: **`V2CTrydan`**. Plugin ids are prefixed `V2CTrydan:<Device Id>`.

Plugin Settings (the block):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | - | `V2CTrydan`. |
| `name` | string | `"V2C Trydan"` | Log name. |
| `pollingInterval` | integer, seconds | `10` | Period of `/RealTimeData` reads. Minimum 5 (HA and HACS poll every 5 s; Gladys defaults to 30 s, range 10..600). Clamp below 5 to 5. |
| `timeout` | integer, seconds | `5` | Per request. [pytrydan] uses 10 s, [Gladys] 5 s, [HACS] 10 s for reads and 5 s total / 2 s connect for writes. |
| `devices` | array | `[]` | Homebridge-style list of chargers reached by address: `{ "host": "192.168.1.50", "name": "Garage charger" }`. `host` required (IPv4, IPv6 in brackets, or a host name; optional `:port`). |

Canonical shape: the bridge writes per-charger Accessory Settings into `_accessories` keyed by Device Id
(docs/adr/0001). Plugin Accessory Settings (declare them in `accessorySchema`):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `host` | string | from Setup | Address of the charger. |
| `exposeCurrent` | bool | `true` | Expose the charge-current control (section 4). |
| `exposeLock` | bool | `true` | Expose `Locked` as a Lock Mechanism. |
| `exposeSensors` | bool | `true` | Expose the plug sensor and the house/solar power readings. |
| `exposeDynamic` | bool | `false` | Expose `Dynamic` and `PauseDynamic` switches (advanced). |
| `exposeLeds` | bool | `false` | Expose the LEDs as lightbulbs (only when the firmware reports them). |
| `houseEnergyRole` | string enum `"none"`, `"home"`, `"grid"` | `"none"` | How `HousePower` is tagged on the Status page's Energy section (section 4.4). |
| `solarEnergy` | bool | `false` | Tag `FVPower` with the `solar` role. |

Setup (Recommendation): `accountAuthorization = none`; there is no account. `discover()` lists every charger named by
`devices` or `_accessories` by probing `GET /RealTimeData` (a few seconds, the configured timeout); a charger that
answers is identified by its `ID` (section 3.3). Adding a new one is an "add by address" Setup step: one text field
(host); the step probes the address, refuses (SetupError, "No V2C Trydan answered at <host>") when the reply is not
a JSON object with `ChargeState`, and on success returns `.done` with `deviceID` = the charger's Device Id and
settings `{ "host": … }`. No credentials are kept (nothing to keep), so the device is Authorized by having settings.
No secrets exist anywhere in this plugin.

## 3. Protocol

### 3.1 Endpoints

All are `GET`, no body, no headers needed, port 80 [V2C].

| Path | Purpose | Reply |
|---|---|---|
| `/RealTimeData` | Every value at once | One JSON object (3.2). [V2C] says "From version 2.1.16", yet the test fixtures of [pytrydan] (firmware `1.6.18`) and [HA] (`2.1.7`) also show it answering; treat it as present on all firmware the plugin supports. |
| `/read/<Keyword>` | One value | Plain text, the value alone (e.g. `230`), status 200. HTTP **404** when that firmware does not know the keyword [pytrydan]. |
| `/write/<Keyword>=<Value>` | Set one value | Status 200 and body exactly `OK` (two bytes, no newline) on success [pytrydan tests]. Anything else (other status, other body) is a failure. |

Note the write path is literally `/write/` + keyword + `=` + value inside the path, not a query string, e.g.
`/write/Intensity=16`. Keywords are case-sensitive as listed below (PascalCase, `FVPower`, `LightLED`, `LogoLED`).
Values are decimal integers with no sign except `ContractedPower`, which may be negative (3.4).

HTTP status handling [pytrydan]: 401 or 403 → communication error (not expected; the device has no auth); any other
non-200 → invalid response. A 200 whose body is not a JSON object → invalid response.

### 3.2 Response quirks

- The reply's `Content-Type` may not be `application/json` (some firmware answers as text) [HACS]: parse the body
  regardless of the header.
- Some firmware sends **malformed JSON** [HACS]:
  - the `"FirmwareVersion":"…",` member appears more than once; keep the last;
  - the firmware version appears unquoted (observed `1.6.13` bare), which is not valid JSON;
  - a comma is missing before `"ReadyState":`.
  **Recommendation:** parse strictly first; on failure apply those three repairs to the text (drop all but the last
  `"FirmwareVersion":"<…>",` occurrence; quote a bare dotted version number that follows `"FirmwareVersion":`; insert a
  comma before `"ReadyState":` when the preceding non-space character is not `,` or `{`), then parse again; if it
  still fails, the poll fails and the raw body's first 200 characters go to the debug log.
- Numbers: powers and energy arrive as decimals with two places (`0.00`, `2664.00`, `1500.27`); `HousePower` may be
  an integer or a decimal; the rest are integers. Accept an integer or a decimal for every numeric field and round
  where an integer is wanted.
- Whitespace may appear between members ([V2C]'s own sample has spaces before `"MinIntensity"`).
- The reply is about 400 bytes [Gladys]; cap a read at 16 KiB.
- Fields vary by firmware (3.3, "Presence"). Unknown extra fields must be ignored.

### 3.3 Fields of `/RealTimeData`

Presence column: **R** = [pytrydan] fails the read without it; **O** = optional, may be absent on some firmware.
W = writable through `/write/` [V2C "WRITE ENABLED" column, and pytrydan's validation table].

| Key | Type | Unit | W | Presence | Meaning and values |
|---|---|---|---|---|---|
| `ID` | string | - | N | O | The charger's identifier (the [V2C] sample shows a six-character placeholder; [HA] uses it as the config entry's unique id). |
| `ChargeState` | int enum | - | N | R | IEC 61851 state. `0` state A, no vehicle ("waiting EV"); `1` state B, vehicle connected, not charging; `2` state C, charging; `4` state F, system failure / leak detected (pytrydan alias "pilot short"); `5` state E, control-pilot error / ground failure (alias "general fault"); `6` state D, ventilation required [V2C, pytrydan]. **`3` is not defined**: pytrydan rejects it and fails the whole read. |
| `ReadyState` | int | - | N | O (default 0) | Not in [V2C]'s sheet. pytrydan: `0` not ready, `1` ready. Fixtures show `1` while connected-not-charging and `0` while charging; exact meaning unknown (Gaps). |
| `ChargePower` | number | W | N | R | Power delivered to the car now. |
| `ChargeEnergy` | number | kWh | N | R | Energy of the **current charging session** [V2C]. Starts again at the next session; stays at its last value after charging stops (fixture: `7.60` with state 1). [HA] treats it as an ever-increasing total (which tolerates a reset). |
| `ChargeTime` | int | s | N | R | Duration of the current session [V2C]. |
| `HousePower` | number | W | N | R | "House power consumption" [V2C], measured by the charger's clamp or meter (the dynamic-power installation). Often `0` without a clamp. Whether it is the home's total use or the grid exchange depends on where the installer put the clamp (Gaps). |
| `FVPower` | number | W | N | R | Photovoltaic generation [V2C], from the same meter; `0` without one. |
| `BatteryPower` | number | W | N | O | Home battery power from the meter. Not in [V2C]'s sheet; sign convention undocumented. [HA] exposes it disabled by default. |
| `SlaveError` | int enum | - | N | R | State of the link to the external meter (the "slave"). Codes in 3.5. |
| `Paused` | int | - | Y | R | `0` not paused, `1` current session paused. |
| `Locked` | int | - | Y | R | Disabling state of the charge point: `0` enabled (usable), `1` disabled (locked) [V2C]. |
| `Timer` | int | - | Y | R | Charge timers (schedules set in the V2C app): `1` on, `0` off. |
| `Intensity` | int | A | Y | R | Current the charger offers the car now. Writable 6..32. |
| `MinIntensity` | int | A | Y | R | Lower limit of the offered current (dynamic mode). Writable 6..32. |
| `MaxIntensity` | int | A | Y | R | Upper limit of the offered current (the installation's limit). Writable 6..32. |
| `Dynamic` | int | - | Y | R | Dynamic intensity modulation: `0` disabled, `1` enabled. |
| `PauseDynamic` | int | - | Y | R | Dynamic control modulation pause: `0` modulating, `1` not modulating (paused). Note the inverted sense. |
| `DynamicPowerMode` | int enum | - | Y | R | Solar/dynamic mode, 3.6. |
| `ContractedPower` | int | W | Y | R | The home's contracted grid power (e.g. `4600`). |
| `VoltageInstallation` | int | V | Y | O | Nominal installation voltage (e.g. `230`). Missing from RealTimeData on some firmware; then read through `/read/VoltageInstallation`. [V2C]'s sample shows `0`. |
| `ChargeMode` | int enum | - | Y | O | Wiring: `0` monophasic (single-phase), `1` three-phase, `2` mixed [V2C]. Often only via `/read/ChargeMode`. |
| `LightLED` | int | % | Y | O | LED (light ring) intensity 0..100 [V2C]. |
| `LogoLED` | int | - | Y | O | Logo LED. [V2C] says boolean: `0` disabled, `1` enabled. [pytrydan] validates 0..100 and [HA] drives it as a dimmable light 0..100 (Gaps). |
| `FirmwareVersion` | string | - | N | O | E.g. `"1.6.18"`, `"2.1.7"`. May be duplicated or unquoted (3.2). |
| `SSID` | string | - | N | O | Wi-Fi network name. |
| `IP` | string | - | N | O | The charger's IP address. |
| `SignalStatus` | int | - | N | O | Wi-Fi signal quality; [V2C] sample `3`; scale undocumented (probably 0..4 bars, Gaps). |
| `IntensityMeasure_L1`, `IntensityMeasure_L2`, `IntensityMeasure_L3` | number | A | N | O | Measured current per phase [V2C]. (The sheet's sample misspells the first as `IntensityMeasure_L1y`; accept both.) No other source reads them. |
| `VoltageMeasure_L1`, `VoltageMeasure_L2`, `VoltageMeasure_L3` | number | V | N | O | Measured voltage per phase [V2C]. |

Filling gaps through `/read` [pytrydan 1.0.1+]: pytrydan holds a fixed list of keywords (`ChargeState`,
`ChargePower`, `VoltageInstallation`, `ChargeEnergy`, `ChargeMode`, `SlaveError`, `ChargeTime`, `HousePower`,
`FVPower`, `Paused`, `Locked`, `Timer`, `Intensity`, `Dynamic`, `MinIntensity`, `MaxIntensity`, `PauseDynamic`,
`LightLED`, `LogoLED`, `DynamicPowerMode`, `ContractedPower`). After each RealTimeData read, every one of those absent
from the object is fetched with `/read/<Keyword>` (sorted by name, one after the other) and its text parsed as an
integer, else a decimal, else kept as text. A keyword answered with 404 is remembered as unavailable and never asked
again for the life of the client; other errors fail the poll. The set of keywords to fetch only grows.
**Recommendation:** do the same but only for `VoltageInstallation`, `ChargeMode`, `LightLED`, `LogoLED` (the ones
seen missing), fetch them at the first poll and then at most once an hour ([Gladys] reads `ChargeMode` hourly), not on
every 5-second poll. A required field missing from RealTimeData that `/read` cannot supply fails the poll.

### 3.4 Writable keywords

Validation before sending [pytrydan; HA's number limits]. Reject out-of-range values locally, without a request.

| Keyword | Accepted values | Notes |
|---|---|---|
| `Paused` | `0`, `1` | `1` pauses the session, `0` resumes. |
| `Locked` | `0`, `1` | `1` disables (locks) the charge point, `0` enables it. |
| `Timer` | `0`, `1` | Timers off / on. |
| `Dynamic` | `0`, `1` | Dynamic modulation off / on. |
| `PauseDynamic` | `0`, `1` | `1` = stop modulating (paused), `0` = modulating. |
| `Intensity` | integer 6..32 | **Recommendation:** also clamp to `MinIntensity`..`MaxIntensity` as last read ([Gladys] does; pytrydan does not). |
| `MinIntensity` | integer 6..32 | **Recommendation:** not above `MaxIntensity`. |
| `MaxIntensity` | integer 6..32 | **Recommendation:** not below `MinIntensity`. |
| `DynamicPowerMode` | `0`..`5` | 3.6. [V2C] marks `1` deprecated; pytrydan still accepts it. |
| `ChargeMode` | `0`, `1`, `2` | Wiring; a configuration value, not for HomeKit. |
| `ContractedPower` | integer (W) | pytrydan rejects a negative value unless the current `DynamicPowerMode` is `0` or `3`. |
| `VoltageInstallation` | integer > 0 | [HA] offers 1..500. |
| `LightLED` | integer 0..100 | |
| `LogoLED` | integer 0..100 per pytrydan; `0`/`1` per V2C | **Recommendation:** send `0` for off and `1` for on unless the device reported a value above 1 before, then treat it as 0..100. |
| `ChargeState` | in pytrydan's validation table but meaningless to write | Never write it. |

Values are sent as the bare decimal integer. A float is rounded first [pytrydan].

### 3.5 `SlaveError` codes

[V2C] documents `0`..`10`; [pytrydan] adds Modbus-gateway codes. Names in parentheses are pytrydan's; [HA] shows them
with "slave" replaced by "meter".

| Code | Meaning |
|---|---|
| 0 | No error |
| 1 | Communication |
| 2 | Reading |
| 3 | Slave (meter) |
| 4 | Waiting for Wi-Fi |
| 5 | Waiting for communication |
| 6 | Wrong IP |
| 7 | Slave (meter) not found |
| 8 | Wrong slave (meter) |
| 9 | No response |
| 10 | Clamp not connected |
| 21 | Illegal function (Modbus) |
| 22 | Illegal data address |
| 23 | Illegal data value |
| 24 | Server device failure |
| 25 | Acknowledge |
| 26 | Server device busy |
| 27 | Negative acknowledge |
| 28 | Memory parity error |
| 30 | Gateway path unavailable |
| 31 | Gateway target did not respond |
| 32 | Server RTU inactive / timeout |
| 245 | Invalid server |
| 246 | CRC error |
| 247 | Function code mismatch |
| 248 | Server id mismatch |
| 249 | Packet length error |
| 250 | Parameter count error |
| 251 | Parameter limit error |
| 252 | Request queue full |
| 253 | Illegal IP or port |
| 254 | IP connection failed |
| 255 | TCP header mismatch |
| 256 | Empty message |
| 257 | Undefined error |

Any other code (firmware 2.5.1 has been seen sending `224`) maps to "Undefined error" (257) and must not fail the
read [pytrydan 1.0.6]. A non-zero code is normal on a charger with no meter installed (the [HA] fixture has `4`), so it
is a diagnostic, never a fault.

### 3.6 `DynamicPowerMode`

| Value | [V2C] sheet and [pytrydan ≥ 1.0.4] | [HACS] label |
|---|---|---|
| 0 | Timed power enabled (the V2C app's / cloud's schedule profile) | Enable timed power |
| 1 | Timed power disabled (V2C: **deprecated**, old value) | Disable timed power |
| 2 | Timed power disabled, **FV + minimum power** mode | "Exclusive" |
| 3 | Timed power disabled, **FV exclusive** mode (solar only) | "Min power" |
| 4 | Timed power disabled, **FV + grid** mode | Grid + FV |
| 5 | Timed power disabled, **Stop** mode | Stop |

[HACS] swaps the labels of 2 and 3 against V2C's own sheet. **Follow V2C and pytrydan.** [HA] currently exposes no
entity for this field (only reads it); [Gladys] names them `timed`, `timed-off`, `solar-min`, `solar-only`,
`solar-grid`, `stop`.

## 4. HomeKit mapping

HomeKit has no EV charger service. Everything below is a **Recommendation** unless marked as a source's behaviour.

### 4.1 What the sources expose

[HA] entities (one device per charger, unique id prefix = config entry; device's unique id = `ID`):
- binary sensors: Connected (`ChargeState` ≠ 0, plug class), Charging (`ChargeState` = 2), Ready (`ReadyState` = 1);
- sensors: Charge power (W), Charge energy (kWh, total increasing), Charge time (s), House power (W), Photovoltaic
  power (W), Battery power (W, disabled by default), Meter error (enum of 3.5, diagnostic, disabled by default), SSID,
  IP address, Signal status (diagnostic, disabled by default); Installation voltage sensor is deprecated in favour of
  the number;
- switches: Pause session (`Paused`), Lock EVSE (`Locked`), Charge point timer (`Timer`), Dynamic intensity
  modulation (`Dynamic`), Pause dynamic control modulation (`PauseDynamic` = 1 is on);
- numbers: Intensity 6..32 A, Min intensity, Max intensity (config), Installation voltage 1..500 V (config, disabled
  by default);
- select: Charge mode (`monophasic`, `threephasic`, `mixed`), only when the firmware reports it;
- lights: Light LED (on/off only, writes 100 / 0; disabled by default), Logo LED (brightness 0..100), each only when
  reported. Turning a dimmable LED on with brightness b (1..255 scale) writes round(b/255×100), at least 1.
[HACS] adds a `DynamicPowerMode` select and a "km charged" estimate (not relevant).

### 4.2 Recommended accessory

One accessory per charger, category **Outlet** (an EV charger reads naturally as a big socket in the Home app), id
`V2CTrydan:<Device Id>`.

Accessory Information: Manufacturer `V2C`, Model `Trydan`, Serial Number = Device Id, Firmware Revision =
`FirmwareVersion` normalised to `major.minor.patch` (digits only; absent → `0.0.0`), Name = the user's name, else
"V2C Trydan".

Services (stable subtypes in brackets; keep them fixed so iids never move):

1. **Outlet** [`charger`], primary.
   - On = charging allowed = `Paused` = 0. Writing On=false sends `Paused=1`, On=true sends `Paused=0`.
   - Outlet In Use = `ChargeState` = 2.
   - Eve characteristics (custom, as other Homeswift plugins do): Consumption `E863F10D-079E-48FF-8F27-9C2605A29F52`
     = `ChargePower` W; Total Consumption `E863F10C-079E-48FF-8F27-9C2605A29F52` = `ChargeEnergy` kWh (session; see
     Gaps for a lifetime total); Voltage `E863F10A-079E-48FF-8F27-9C2605A29F52` = `VoltageInstallation` (or the mean of
     the `VoltageMeasure_Lx` present) when known; Electric Current `E863F126-079E-48FF-8F27-9C2605A29F52` = sum of the
     `IntensityMeasure_Lx` present, else `ChargePower` / voltage when both are known.
   - No Status Fault here: HAP's Outlet service does not list it; the fault shows on the Contact Sensor (4).
   - Writing On while `Locked` = 1: send it anyway (the device decides), then re-read; the state shows what happened.
2. **Fan v2** [`current`] "Charge current" (when `exposeCurrent`).
   - Active mirrors the Outlet's On (Active=1 ⇔ `Paused`=0) and writes `Paused` the same way.
   - Rotation Speed in **amperes**: properties overridden to minValue `MinIntensity`, maxValue `MaxIntensity`, minStep
     1 (fallback 6..32 when unknown); value = `Intensity`; a write sends `Intensity=<rounded, clamped>`. The Home app
     shows it as a percent slider; that is accepted (the number is the amps). When `MinIntensity`/`MaxIntensity`
     change, update the characteristic's properties (a HAP configuration change), not the iid.
   - Writing Rotation Speed 0 (the Home app does this when the slider goes to the bottom) means pause: send
     `Paused=1`, not an intensity.
   - Alternative if property overrides prove awkward: a Lightbulb "Charge current" with Brightness mapped linearly
     6..32 A → 0..100 %. Pick one and keep it, since changing service type loses automations.
3. **Lock Mechanism** [`lock`] (when `exposeLock`): Current and Target Lock State = 1 (secured) when `Locked` = 1,
   0 when `Locked` = 0; a target write sends `Locked=<target>`. Mark it as a security control (CLAUDE.md: written only
   through `set_security_accessory`); it locks a charger against use, a theft-relevant action.
4. **Contact Sensor** [`plug`] (when `exposeSensors`) "Car connected": Contact Sensor State = 0 (detected) when
   `ChargeState` ≠ 0, else 1. (An Occupancy Sensor is an acceptable alternative; Contact gives better automation
   wording "opens/closes".) Status Fault = 1 when `ChargeState` is 4, 5 or 6, else 0. Without `exposeSensors` the
   fault has no place in HomeKit; it is still logged.
5. **Switch** [`timer`] "Charge timer" (when `exposeDynamic`): On = `Timer` = 1.
6. **Switch** [`dynamic`] "Dynamic power" and **Switch** [`pauseDynamic`] "Pause dynamic" (when `exposeDynamic`):
   On = `Dynamic` = 1; On = `PauseDynamic` = 1.
7. **Lightbulb** [`lightLED`] and [`logoLED`] (when `exposeLeds` and the keyword is reported): `LightLED` with
   Brightness 0..100 (On = value > 0; On=true without a brightness writes the last non-zero value or 100);
   `LogoLED` as on/off (V2C's boolean, 3.4).

`DynamicPowerMode`, `ContractedPower`, `ChargeMode`, `VoltageInstallation`, `MinIntensity`, `MaxIntensity` are
installation settings: not in HomeKit. **Recommendation:** offer them on the plugin's settings or an MCP tool
(`V2CTrydan_set_mode` taking the names of [Gladys]'s column, destructive=false; `MaxIntensity` writes should require
confirmation because a wrong value can exceed the installation's wiring).

### 4.3 Value conversions summary

| HomeKit | Device |
|---|---|
| Outlet On / Fan Active 1 | `Paused` 0 |
| Outlet In Use 1 | `ChargeState` 2 |
| Rotation Speed n (n ≥ 1) | `Intensity` n, clamped to [`MinIntensity`, `MaxIntensity`] ∩ [6, 32] |
| Rotation Speed 0 | `Paused` 1 |
| Lock state 1 (secured) | `Locked` 1 |
| Contact 0 (detected) | `ChargeState` ∈ {1, 2, 4, 5, 6} |
| Status Fault 1 | `ChargeState` ∈ {4, 5, 6} |

### 4.4 Energy (Status page)

Homeswift's `EnergyRole` has `solar`, `home`, `grid`, `battery`, `batteryLevel`; no EV role.
- Record `ChargePower` with `context.recordValue` (series `<DeviceId>:charge`) **without** an `EnergyTag`: the car's
  draw is part of the home's use, and tagging it `home` would double-count it against a meter plugin.
- `HousePower`: tag only as the user chooses with `houseEnergyRole` (`home` when the clamp measures the home's use,
  `grid` when it sits at the grid connection, positive while importing), default untagged. Use `shared: "v2c-meter"`
  when several chargers share the same meter, so it counts once.
- `FVPower`: tag `solar` only if `solarEnergy` is true (default false: an inverter plugin usually reports solar
  already).
- `BatteryPower`: untagged (sign convention unknown).
- If Homeswift later adds an EV/load role, `ChargePower` is the reading for it.

## 5. Behaviour

### 5.1 Polling
- One task per charger. Read `/RealTimeData` every `pollingInterval` seconds (HA/HACS: 5 s fixed). Never let two
  reads of one charger overlap; a poll that is still running when the next is due is skipped.
- After a successful read, update every characteristic whose value changed (events only on change).
- [HA] does the first read before creating any entity and takes the device's unique id from `ID`; the config entry is
  re-keyed when `ID` changes. **Recommendation:** at start, create the accessory from the cached settings without
  waiting, and fill values on the first successful read.

### 5.2 Writes
- A HomeKit write sends one `/write/` request, checks for 200 + `OK`, then updates the cached value optimistically
  and **re-reads `/RealTimeData` at once** (HA calls a refresh after every write) and again about 2 s later (the
  device may apply some writes, e.g. `Paused`, with a delay; the sources do not say how long, Gaps).
- A failed write: answer the HomeKit request with a communication error (HAP status -70402) and leave the cached
  value as last read.
- Serialise requests per charger (one at a time): the embedded HTTP server is small; [Gladys] and [HACS] do the same
  implicitly.
- Rapid slider moves: coalesce Intensity writes, sending only the latest value after ~500 ms of quiet
  (`LatestCallGuard`).

### 5.3 Errors, retries and reachability
- Timeouts: connect and total per request = `timeout` (default 5 s).
- [pytrydan] has a retry helper, but its read and write paths do not use it: a failed read just fails that poll. [HACS]
  retries a read 3 times 2 s apart. [Gladys] backs off after failures: 30 s, 1 min, 2 min, then 5 min.
- **Recommendation:** no inner retry; after 3 consecutive failed polls mark the accessory Not responding (HAP
  -70402 on reads) and back off as [Gladys] (30 s, 60 s, 120 s, then every 300 s, never shorter than the interval);
  one success restores the normal interval and the values.
- `ChargeState` value outside the enum (`3` or anything new): pytrydan fails the whole read. **Recommendation:** keep
  the read, treat the state as "connected, not charging" for the outlet and the plug sensor, Status Fault 0, and log
  once at warning per new value.
- Missing optional fields: leave the related characteristic at its last value (or omit the service at creation when
  never seen: LEDs, per-phase measures). Do not remove a service later just because a field went missing once.
- An HTTP 429 is not expected from a charger; if seen, honour `Retry-After` bounded to 1 min..6 h [Gladys].

### 5.4 Identity
- Device Id = the `ID` string, trimmed, upper-cased, with any character outside `A-Z`, `0-9`, `-`, `_` removed.
- If the firmware sends no `ID` (it is optional in pytrydan): fall back to `host-<host>` normalised the same way, and
  log at info that the identity will change if the address changes. Once an accessory exists under a Device Id, keep
  it; if a later read reveals an `ID` for a host-keyed charger, do not re-key automatically (that would lose HomeKit
  rooms and automations); log it once.
- Two configured hosts answering with the same `ID`: keep the first, log an error for the second.

## 6. Logging

- info: charger added (name, host, Device Id, firmware); reachability lost and restored (once per transition);
  session start (state 1/0 → 2) and end (2 → other) with the session's energy and time.
- warning: unknown `ChargeState`; malformed JSON repaired (once per firmware version); write refused (keyword, value,
  status, first 100 characters of the body).
- debug: every request path and status, the body size, the parsed values. The device has no secrets, so request
  paths may be logged in full (`/write/Intensity=16`). Never log anything else from the network.
- error: duplicate `ID`, a write whose value was rejected by local validation (with the allowed range).

## 7. Test vectors

All ids invented. Hosts are documentation addresses.

### 7.1 RealTimeData, idle with car connected (firmware 1.x, no LEDs/voltage/mode in the object)

    {"ChargeState":1,"ReadyState":1,"ChargePower":0.00,"ChargeEnergy":7.60,"SlaveError":0,"ChargeTime":9979,
     "HousePower":0.00,"FVPower":0.00,"BatteryPower":0.00,"Paused":0,"Locked":0,"Timer":1,"Intensity":16,"Dynamic":0,
     "MinIntensity":6,"MaxIntensity":16,"PauseDynamic":0,"FirmwareVersion":"1.6.18","DynamicPowerMode":2,
     "ContractedPower":4600}

Decoded: car plugged in, not charging, not paused (Outlet On, In Use false, Contact detected), last session 7.6 kWh
over 2 h 46 min 19 s, offering 16 A (Rotation Speed 16, range 6..16), timers on, dynamic off, mode 2 = FV + minimum
power, contracted power 4.6 kW. No `ID`: Device Id falls back to the host. `/read/VoltageInstallation`,
`/read/ChargeMode`, `/read/LightLED`, `/read/LogoLED` are then asked; e.g. replies `230`, `2`, `75`, `25` (text) give
230 V, mixed wiring, LEDs 75 and 25; a 404 on each means "not supported", asked no more.

### 7.2 Charging (firmware 2.x, all fields)

    {"ID":"TRY4F2A","ChargeState":2,"ReadyState":0,"ChargePower":1500.27,"VoltageInstallation":230,
     "ChargeEnergy":1.80,"ChargeMode":1,"SlaveError":4,"ChargeTime":4355,"HousePower":0.0,"FVPower":0.0,
     "BatteryPower":0.0,"Paused":0,"Locked":0,"Timer":0,"Intensity":6,"Dynamic":0,"MinIntensity":6,"MaxIntensity":16,
     "PauseDynamic":0,"LightLED":25,"LogoLED":1,"FirmwareVersion":"2.1.7","DynamicPowerMode":2,"ContractedPower":4600,
     "SSID":"home-wifi","IP":"192.0.2.50","SignalStatus":3}

Decoded: Device Id `TRY4F2A`; charging (In Use true) at 1500.27 W, session 1.8 kWh over 1 h 12 min 35 s; 6 A offered;
three-phase wiring; meter link "waiting for Wi-Fi" (4) is a diagnostic only, no fault; Eve current ≈ 1500.27 / 230 =
6.52 A when no per-phase measures are present.

### 7.3 Fault and unknown values

- `"ChargeState":4` → Contact Sensor Status Fault 1, Contact detected, In Use false.
- `"ChargeState":3` → read kept, treated as connected not charging, one warning.
- `"SlaveError":224` → "Undefined error" (257), no failure.

### 7.4 Malformed replies to repair

- `{"ChargeState":0,"FirmwareVersion":"1.6.13","ChargePower":0.00,"FirmwareVersion":"1.6.13",…}` → keep the last
  `FirmwareVersion`.
- `{…,"FirmwareVersion":1.6.13,…}` → quote it: `"1.6.13"`.
- `{…,"Intensity":16"ReadyState":1,…}` → insert the comma before `"ReadyState":`.
- Body `<html>…` with status 200 → invalid response, poll fails.

### 7.5 Writes (host 192.0.2.50)

| HomeKit action | Request | Expected reply |
|---|---|---|
| Outlet Off | `GET http://192.0.2.50/write/Paused=1` | 200 `OK` |
| Outlet On | `GET http://192.0.2.50/write/Paused=0` | 200 `OK` |
| Rotation Speed 10 | `GET http://192.0.2.50/write/Intensity=10` | 200 `OK` |
| Rotation Speed 40 with Max 16 | `GET http://192.0.2.50/write/Intensity=16` (clamped) | 200 `OK` |
| Rotation Speed 0 | `GET http://192.0.2.50/write/Paused=1` | 200 `OK` |
| Lock target secured | `GET http://192.0.2.50/write/Locked=1` | 200 `OK` |
| Logo LED off | `GET http://192.0.2.50/write/LogoLED=0` | 200 `OK` |
| Light LED 75 % | `GET http://192.0.2.50/write/LightLED=75` | 200 `OK` |
| Mode FV exclusive (tool) | `GET http://192.0.2.50/write/DynamicPowerMode=3` | 200 `OK` |

Failure cases: 200 with body `ERROR` or empty → write failed; 404 → write failed; `Intensity=5` or `Intensity=33` →
refused locally, nothing sent.

### 7.6 Behaviour checks worth testing (with a fake transport)

- Poll → characteristics; a changed value raises one event, an unchanged one none.
- Write → request sent, then an immediate re-read.
- Three failed polls → Not responding; one success → values back.
- `/read` fallback asks each missing keyword once, remembers 404s, and re-asks the supported ones only hourly.
- Min/Max change → Rotation Speed properties change, iids do not.
- No `ID` → host-based Device Id; later `ID` → no re-key, one log line.

## 8. Gaps and hard parts

1. **No Homebridge plugin** exists: the configuration interface (section 2) is new and there are no users to stay
   compatible with.
2. **`ReadyState`** is undocumented by V2C; the fixtures show it 1 when idle-connected and 0 while charging. Not
   mapped to HomeKit.
3. **`HousePower`** semantics depend on the clamp's position; hence the opt-in `houseEnergyRole`. `BatteryPower`'s
   sign is unknown.
4. **`LogoLED`** is a boolean per V2C but 0..100 per pytrydan/HA; [HA] also treats `LightLED` as on/off and `LogoLED`
   as dimmable, the reverse of V2C's sheet. Verify on hardware.
5. **`DynamicPowerMode` 2 and 3**: [HACS] labels them the other way round from V2C and pytrydan; this spec follows
   V2C. Value 1 is deprecated by V2C.
6. **Lifetime energy** is not available locally (only the session's `ChargeEnergy`); a lifetime total would have to be
   accumulated by the plugin from session ends (persist it with `jsonFile` if wanted) or come from the V2C cloud.
7. **Write latency** (how long until `/RealTimeData` reflects a write) is not stated in any source; hence the second
   re-read.
8. **V2C cloud API and MQTT** are out of scope; no licensed source describing them was read.
9. **Firmware coverage**: [V2C] says `/RealTimeData` is "from version 2.1.16" while fixtures from 1.6.18 and 2.1.7
   show it; firmware without it is unsupported (could be served by `/read` of each keyword, not specified here).
10. **Discovery**: no network advertisement is documented; Setup is by address only. `SignalStatus`'s scale and the
    exact `ID` format (length, alphabet) are unknown.
11. **Charge current in HomeKit** has no native characteristic; the Fan-speed-in-amps choice is a compromise
    (the Home app labels it %). Changing that choice later changes the service type and loses automations.
