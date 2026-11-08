# EcoFlow

Shows the EcoFlow devices on your account in HomeKit, each as a battery with its state of charge and whether it is
charging: STREAM, RIVER, DELTA, RAPID and GLACIER, and the home systems PowerStream, PowerOcean and Smart Home Panel
([Models](#models) lists them). Its page shows their power as the EcoFlow app does, live.

It reads one of two sources, or both, as the **Route** setting says:

- **Developer API**: the documented route, with an access key and a secret key you create yourself at
  [developer.ecoflow.com](https://developer.ecoflow.com). It reads the models EcoFlow documents for it.
- **EcoFlow app**: the app's own sign-in, with your EcoFlow email and password, and the app's live stream. It is
  unofficial and undocumented: EcoFlow can change or stop it at any time, and the password is kept in config.json. It
  reads every model the plugin knows, the RIVER and RAPID among them.
- **Both** (the default): every device, each from one of them: a device both report is read from the developer API,
  unless its model was checked on the app's route only (a RIVER 3 is read from the app).

**Status: experimental.** Run on a bridge with a STREAM Ultra, a STREAM AC Pro, a RIVER 3, a RIVER 3 Plus and a RAPID
Pro X, and checked against the EcoFlow app's screens; some readings are not mapped yet (see [Not mapped](#not-mapped)).
The other models are mapped from what open-source projects found (see [Credits](#credits)) and have not been checked
on a real device: the plugin's page marks them **Untested**.

## What it does

| Device | HomeKit | The plugin's page |
|---|---|---|
| Each device the route reads | A Battery service on its own accessory, named after the device: its level, charging state, low below 10 % | Its power, laid out by kind (below), with the last hour of each reading and its source (MQTT, REST or App) |
| Each output it switches ([Writes](#writes)) | An Outlet beside the Battery, named after the port (AC1, AC2, AC, DC 12 V, USB) | Its state and a button that switches it |
| Its charge and discharge limits | Accessory Settings of the device (`chargeLimit`, `dischargeLimit`) | The device's limits |
| A RIVER 3 Plus's light ([Writes](#writes)) | A Lightbulb "Light" (Dim, Bright) and a Switch "SOS" beside the Battery | Its mode and a choice of Off, Dim, Bright and SOS |

HomeKit has no characteristic for watts, so the power is on the plugin's page only, a card per device, two to a row
on a wide screen; a card's grip drags it to another place (or moves it with the arrow keys), and the plugin keeps the
order for every viewer. The page refreshes every few
seconds and records each reading for the Status page's graphs. A STREAM's solar, home, grid and battery power and every device's
battery level also feed the Status page's **Energy** section, added up across STREAM units: with an Ultra and an AC
Pro, the Ultra reports the whole system's flows and the AC Pro 0 for each.

With the EcoFlow app's email and password, the plugin also imports the cloud's energy history into the Status page's
month and year views (**Import the energy history**, `importHistory`, on by default): each hour's solar production and
home use since the system was set up, from the app's Space dashboard (home use from the system's smart meter when it has
one), and the STREAM system's battery charge and discharge and grid import and export, from its Battery and Grid pages,
for the home of one STREAM: one the block's `devices` names, else the one earlier imports used, else the first by serial
number of those that report, else the app's device list's first; never an Excluded one. The one chosen is kept in
`energy-history.json`: when it changes, the old one's imported hours are dropped and the whole history is read onto the
new one's meters. With
all four, the Status page splits each day's home use by source. Each hour goes to the meter of its Energy Role on that
STREAM — solar, home, grid, battery, the same four the device reports live — so the Status page's **Consumption by
device** has the cloud's past as well, and the runtime fills the Home Energy from them. The first import takes
everything (a request per month and chart), saving where it is after each month, so one that fails goes on from there;
then the last two days are taken again every 6 hours, as the cloud fills hours in late. A bridge that imported the history before 0.26.0, when it went in as the home's flows under the plugin's
own name, drops that import and reads the whole history again the first time it runs: the two would be added together. The battery and
grid charts' codes are the ones the app's dashboard lists for the system (`/iot-service/dashboard/platform/getPageListById`
with page type 4, then `getPageChartByPageId`), asked for by a unit's serial number. When the cloud refuses them, the
import is not done and is made again from the refused month 10 minutes later; after three imports refused in a row the
history goes on without them (a system without those pages keeps its solar and home history), and they are asked for
again each time, taken up as soon as they answer. The space's answers carry the home's address: only its id and time zone are read,
and no answer is logged.

### STREAM

| Reading | Developer API (MQTT and REST) | EcoFlow app (field) | Positive means |
|---|---|---|---|
| Battery | `f32ShowSoc` (MQTT only) | 32/50: 25, else 6 | percent, rounded as the app shows it |
| Solar | `powGetPvSum` | 517 | generation |
| Home | `powGetSysLoad` | 516 | consumption |
| Grid | `powGetSysGrid` | 515 | import from the grid (export is negative) |
| Battery power | `powGetBpCms` | 518 | charging (discharging is negative) |
| Grid connection port | `gridConnectionPower` | 616 | output (taking power in is negative) |
| Panels PV1–PV4 | `powGetPv` to `powGetPv4` | 361, 70, 996, 997 | generation of each panel input |
| AC1, AC2 | `powGetSchuko1`, `powGetSchuko2` | 1210, 1211 | supplying an appliance |

The developer API's MQTT pushes stand for a device once they carry the battery and the five power flows; until then,
and after a restart, the REST quota does. The REST quota has no unit's level: its `cmsBattSoc` is the whole system's on the unit that leads it (62 beside units at 85 and 40) and 0 on the others, so on REST alone a STREAM's level is not known, and with Both the app's route, which has it, is read instead. `f32ShowSoc` matches the app.
The STREAM AC Pro has no solar input, so the page shows no panels for it.

On the app's stream, the flows are in the status message (254/21) and the battery in the battery pack's message (32/50),
each read by its command: the status message's field 6 is the backup state (an AC Pro sends 0 there in about a third
of its messages), and its field 262 the system's percentage, which only the system's main unit reports.

### RIVER and RAPID

A RIVER or a RAPID answers on the app's stream with several messages, told apart by their header's command. The
plugin reads the station's message (254/21) and the battery's (32/2); the battery pack's (32/50) reuses the station's
field numbers and is read for its percentage only.

| Reading | Message | Field | The app's label |
|---|---|---|---|
| Input | 254/21 | 3 | Input |
| Output | 254/21 | 4 | Output |
| AC input | 254/21 | 54 | AC (input tab) |
| AC output | 254/21 | 368 (negative) | 230V AC |
| USB-A | 254/21 | 9 (negative) | USB-A |
| USB-C | 254/21 | 11 (negative) | USB-C |
| Battery (RIVER) | 32/2 | 1, then 15 (precise; else 254/21 field 262, else 32/50 field 6) | the percentage |
| Battery (RAPID) | 254/21 | 262 | the percentage |

The outputs add up to the output total, which is how the ports were told apart. Field 270 of the station's message is
the charge limit. A RAPID sends no battery message: its percentage is field 262 of the station's message (field 5
stays at 100 whatever the level). A RAPID shows Input and Output only.

### Not mapped

- The RAPID's four ports. The C-cable is field 857 of the station's message (a message of its own: 1 the watts, 2 the
  volts, 3 the amps, as the app showed 25.3 W, 8.8 V and 2.9 A); C1, C2 and C3 are likely 852, 856 and 853, as
  ha-ef-ble names them, unconfirmed.
- The RIVER's 12V DC output and Solar/Car input: they read 0 W in every capture so far.

## Writes

The plugin switches a device's outputs and sets its charge limit (the maximum state of charge) and discharge limit
(the minimum), as `docs/clean-room/EcoFlowWrites.md` specifies them on each route:

- **Outputs:** an Outlet per output the model has, beside the Battery, its subtype stable (`ac`, `ac2`, `dc12v`, `usb`):
  a STREAM's AC1 and AC2 sockets (a STREAM Max's one AC), a RIVER 3's AC and 12 V, a DELTA 3's AC, AC2, 12 V and USB as
  each model has them, a DELTA Pro 3's high-voltage and low-voltage AC and 12 V, a DELTA 2's AC, 12 V and USB, a RIVER 2's
  AC and 12 V, a DELTA Pro's, Max's and Mini's AC and 12 V (USB on a DELTA Max), a DELTA Pro Ultra's DC. Outlet In Use is
  always on. On is the device's where it reports it; a switched output keeps the state asked for two seconds while the
  device catches up. The page shows each output's state with a button that switches it the same way.
- **Limits:** the device's Accessory Settings `chargeLimit` and `dischargeLimit` (its Settings sheet, or
  `update_settings`), clamped to the model's range (50 to 100 % and 0 to 30 %; a PowerStream's 70 to 100 and 1 to 30),
  the charge limit kept above the discharge limit, and sent once when they change (`limits.json` keeps what was sent). A
  limit the device already has is not sent; one refused is not sent again until the settings change.
- **Light:** a RIVER 3 Plus's LED (R631, R634, R635), on the app's route only (`cfg_led_mode`, field 89 of the
  ConfigWrite; read back from `led_mode`, field 357 of the status message), spec section 8. It takes a mode: Off, Dim,
  Bright or SOS, and no other value is sent. It was checked with the RIVER 3 Plus's other writes (written and read back
  on a device), so it needs no **Writes to untested models**. It appears once the device's status has carried its mode,
  and stays from then on, across restarts too, though a report lacks the mode (a partial push, an offline reading, the
  developer API's): HomeKit would drop the scenes and automations using a service that went away. Until the mode is
  reported again it shows what it showed, and its writes wait. The plain RIVER 3 has none, and the developer API has no
  such write. In HomeKit, a Lightbulb (subtype `light`, Brightness in steps of 50 %) shows Dim as on at 50 % and Bright
  as on at 100 %, Off and SOS as off; a Brightness up to 50 % sends Dim, above it Bright, 0 % Off; On sends the last Dim
  or Bright the device had (else Bright), and off sends Off; the Home app's On and Brightness of one change go as one
  write. A Switch "SOS" (subtype `light-sos`) is on in SOS, and switches to SOS and back to Off. The page's Light row
  shows the mode and sets it: one of four choices, each its glyph alone where the card is narrow.
- **Failures:** a write refused, or not answered within a few seconds, fails in the Home app (the device is not
  responding), is logged, and the device is read again.

| Route | How | Models |
|---|---|---|
| EcoFlow app | Protobuf to `/app/<user>/<serial>/thing/property/set`, the device's `set_reply` (a ConfigWriteAck) confirming it | STREAM (its own header), RIVER 3, DELTA 3, DELTA Pro 3, PowerStream (limits) |
| EcoFlow app | JSON (`moduleType`/`operateType`, or `operateType` `TCP`), confirmed by the reply or by the readings that follow | DELTA 2, RIVER 2, DELTA Pro, Max, Mini |
| Developer API | `PUT /iot-open/sign/device/quota`, the body flattened and signed | DELTA 2, 2 Max (12 V, USB, limits), RIVER 2 Pro (12 V, limits), DELTA Pro (AC, 12 V, limits), DELTA Pro Ultra (DC, limits), PowerStream (limits) |

With both routes, each write goes by the developer API when it has it, else by the app's route; a route where the
model's writes were seen working wins.

**Gating.** A write that changes the wrong field could change a setting nobody asked for, so writes go only to the models
whose writes were seen working on a real device (`EcoFlowWrites.checked`): the STREAM Ultra (BK11), the STREAM AC Pro
(BK31), the RIVER 3 (R65x) and the RIVER 3 Plus (R63x), on the app's route. Every other model's writes, and every
developer API write, are sent only with **Writes to untested models** (`untestedWrites`, off by default): its Outlets
appear then, and the page marks its writes **Untested**. A model with no fitting writes (a GLACIER, a PowerOcean, a Smart
Home Panel, a RAPID) gets none.

**Not known yet** (the spec's open questions, left out rather than guessed):

- How the developer API signs a JSON boolean: the STREAM's, the DELTA 3 Max's and the DELTA Pro 3's developer bodies
  carry booleans, so those models write over the app's route only, and with the developer API alone they have no writes.
- The developer API's AC write on a DELTA 2 or RIVER 2 Pro carries the X-Boost and the frequency, which it has no
  documented "unchanged" value or key for, and a DELTA Pro Ultra's AC carries values whose meaning is not documented:
  their AC goes by the app's route, or not at all.
- The app's stream has no documented read-back of a protobuf model's outputs: a DELTA 3's On is what the device last
  acknowledged. A STREAM's relays (fields 980 and 982) and a RIVER 3's 12 V (field 33) were seen in its status.
- A RIVER 3's AC flag was not observed: its On comes from the AC output's power (field 368), on while it delivers power,
  and nothing is said at 0 W (an AC on with nothing plugged in looks the same as off). So switching the AC off on the unit
  itself, or in the EcoFlow app, leaves HomeKit's Outlet on until the plugin writes it or power flows again; an Outlet
  switched off is not turned on until power flows.
- Which header fields the devices check, a JSON reply's shape, and whether a limit sent to a STREAM system's secondary
  unit applies.
- The DELTA 3's 12 V output on models other than the Classic, Max and Max Plus; the RIVER 3's and the DELTA Pro 3's USB;
  the RAPID's ports; RIVER 2, RIVER 2 Max, DELTA Max and Mini on the developer API; DELTA 2 Plus, DELTA Pro Ultra X and
  GLACIER Classic anywhere.

## Models

The plugin knows a model by the first characters of its serial number. A model it does not know, or one with no
battery for HomeKit (a Smart Plug, EcoFlow's Shelly plug and meter, a microinverter or Smart Meter, a Smart Generator,
an Alternator Charger, a WAVE, a PowerPulse, the first Smart Home Panel), is left out, and the log says so once, with
the serial number's first four characters only.

| Model | Serial | App route | Developer API | Writes ([Writes](#writes)) | Checked on a device |
|---|---|---|---|---|---|
| STREAM Ultra, AC Pro | BK11, BK31 | Protobuf, as above | STREAM keys, as above | AC1, AC2, limits (app; checked) | Both routes |
| STREAM Ultra X, Pro, Max, AC | BK61, BK12, BK41, BK51 | As the Ultra | As the Ultra | AC1, AC2, limits (app); the STREAM Max one AC, the STREAM AC its limits only | No |
| RIVER 3, RIVER 3 Plus | R65x, R63x | The status message, as above | `cmsBattSoc`, `powInSumW`, `powOutSumW`, `powGetAcIn`, `powGetAcOut` | AC, DC 12 V, limits (app; checked); the Plus's light (app; checked) | App route |
| DELTA 3 (Plus, Classic, Air, Max, Max Plus, Ultra, Ultra Plus), DELTA Pro 3, DELTA Pro Ultra X, GLACIER Classic | P231, P351, P32x, PR1x, D3N1, D3M1, D751, D511, MR5x, P101, RF45 | As the RIVER 3 | As the RIVER 3; a DELTA 3 Max's and a DELTA Pro 3's outputs and limits too | DELTA 3: AC, USB (not the Air), DC 12 V (Classic, Max, Max Plus), AC2 (Max Plus, Ultra Plus), limits; DELTA Pro 3: HV and LV AC, DC 12 V, limits (app); none for the Ultra X and the GLACIER Classic | No |
| RAPID Pro X; RAPID Pro | P513; P521 | The status message: input, output, the percentage (262) | Not read | None | RAPID Pro X, app route |
| DELTA 2, 2 Max, 2 Plus; RIVER 2, 2 Max, 2 Pro; DELTA Pro, Max, Mini; GLACIER | R33x, R35x, D36x, R60x, R61x, R62x, DC…, DAEB, DBAB, BX11 | JSON quotas, asked with `latestQuotas` | The same keys | AC, DC 12 V, limits, and USB on a DELTA 2, 2 Max and Max (app); 12 V, USB and limits of a DELTA 2 and 2 Max, a RIVER 2 Pro's 12 V and limits, a DELTA Pro's AC, 12 V and limits (developer); none for a DELTA 2 Plus or a GLACIER | No |
| DELTA Pro Ultra | Y711 | Not read | `hs_yj751_pd_appshow_addr.soc`, `.wattsInSum`, `.wattsOutSum` | DC, limits (developer) | No |
| PowerStream | HW51 | 20/1, tenths of a watt | `20_1.*` | Limits (both) | No |
| PowerOcean; PowerOcean Fit | HJ31; HC31 | 96/33 | `bpSoc`, `mpptPwr`, `sysLoadPwr`, `sysGridPwr`, `bpPwr`; Fit not read | None | No |
| Smart Home Panel 3 | HR62, HR63, HR6C | The status message's system flows | Not read | None | No |
| Smart Home Panel 2 | HD31 | Not read | `backupIncreInfo.backupBatPer`, `wattInfo.gridWatt`, `wattInfo.allHallWatt` | None | No |

The older stations' JSON keys: the display's percentage (`bms_emsStatus.lcdShowSoc`, `ems.lcdShowSoc` on a DELTA
Pro or Max, `pd.soc`), the totals (`pd.wattsInSum`, `pd.wattsOutSum`; a GLACIER's `bms_bmsStatus.inWatts` and
`outWatts`), the inverter's AC (`inv.inputWatts`, `inv.outputWatts`) and the solar charger (`mppt.inWatts`, in tenths of
a watt on a DELTA Pro, Max or Mini). A PowerStream's battery power is positive while the battery supplies the inverter,
and it has no grid reading. A home system's solar, home, grid and battery feed the Status page's Energy section, as a
STREAM's do; a station's ports do not. `EcoFlowModels.swift` has every key.

## Settings

The account is set up on the web UI's **Add accessories** page (Setup), or by an AI agent with `start_setup`: it asks for
the route, then the developer keys, the app's email and password, or both, and checks each before keeping it. The keys
and the password are kept in the bridge's vault; the rest is on the plugin's Settings page (or `get_settings` and
`update_settings`):

```json
{
  "platform": "EcoFlow",
  "name": "EcoFlow",
  "route": "both",
  "region": "eu",
  "email": "you@example.com",
  "_accessories": {
    "your STREAM's serial number": { "name": "STREAM Ultra" }
  }
}
```

- **Route:** `both` (the default), `developer` or `app`. The form shows the settings the route needs.
- **Region:** `us` or `eu`, the region your developer account was created in.
- **Email:** your EcoFlow account's, for the app; its password is in the vault (**Set up again** changes it).
- **Import the energy history:** `importHistory`, on by default; it needs the email and password (above, [What it
  does](#what-it-does)).
- **Writes to untested models:** `untestedWrites`, off by default: the outputs and limits of models whose writes nobody
  has confirmed on a real device ([Writes](#writes)).
- **Interval** (under Developer API): `pollingInterval`, the seconds between reads of the developer API's REST values, 60 by
  default, 30 at least; the form shows it when the route uses the developer API. Both routes also use MQTT, which is
  live whatever the interval: the developer API's pushes for a STREAM, and the app's stream for every device it reads (a
  RIVER, a RAPID), as in the app.
- **The form** groups the settings by route: **EcoFlow account** (email, the history import) and **Developer API**
  (region, interval), each shown when the route uses it.

Each device comes with the account, by its serial number, of the Device Kind of its model (`stream`, `home`, `portable`,
`powerBank`); its Accessory Settings (its Name, room, Excluded) are in `_accessories` and its Settings sheet, with the
plugin's own `chargeLimit` and `dischargeLimit` ([Writes](#writes)). The app reads the account's devices from its device list (EcoFlow's broker refuses a
subscription to every device at once).

A block written before still runs: `accessKey`, `secretKey` and `password` in it (sealed), and `devices`, serial numbers
with names, which the app reads first. At the next settings change the bridge moves the keys and the password into the
vault and each device's name into its Accessory Settings. The option names are the plugin's own: there is no Homebridge
plugin to stay compatible with.

## How it works

**Developer API.** Each request is signed with HMAC-SHA256 under the secret key, over the query parameters sorted by
name and the authentication parameters (`accessKey`, `nonce`, `timestamp`), carried in headers, to
`https://api.ecoflow.com` or `https://api-e.ecoflow.com`. The plugin lists the devices, connects to the developer MQTT
broker with the certificate from `/iot-open/sign/certification`, and subscribes to each device's
`/open/<account>/<serial>/quota`. A device's REST quota is asked for only while its pushes are incomplete. Its MQTT
client id is the account and a suffix of this bridge's own (`<account>_homeswift_<8 hex>`, kept in `mqtt-client.json`):
the broker keeps one connection per client id, so two bridges with the same keys no longer cut each other off, and the
id never changes, since EcoFlow is reported to block an account's MQTT after too many client ids in a day.

**EcoFlow app.** The plugin signs in to `/auth/login` with the password base64-encoded, as the app does, reads the MQTT
account from `/iot-auth/app/certification` and the devices (names, product types, and the serial numbers when none
are configured) from `/app/user/device/list`, then subscribes to each device's `/app/device/property/<serial>` and `/app/<user>/<serial>/thing/property/get_reply`. Every
minute it sends each device the read request the app sends when it opens one (`thing/property/get`), so the devices
answer without the app open. The messages are protobuf, read by field number without the schema; most pushes are
encrypted (`enc_type` 1), which is an XOR with the low byte of the header's sequence number.

**Changes in the APIs.** Each answer is checked against the shape the plugin reads; a change is logged once, and once
more when it matches again. An API that fails is logged the same way, and the other API's devices still show. The
energy history's answers are checked too (the space, its systems, the device list, each chart's points), after each
import; a list field missing from its items is named once (`[*].unit`), so a change reads the same in every answer. A
battery or grid chart the cloud stops answering, as a renamed code would, is logged once, and the import goes on with
solar and home use.

## Credits

This plugin is new, not a port. The models beyond the five above were mapped from what these projects found by reading
the devices; the field numbers, keys and serial prefixes are facts taken from them, and no code was copied:

- [tolwi/hassio-ecoflow-cloud](https://github.com/tolwi/hassio-ecoflow-cloud) (Apache-2.0): the app's JSON quotas and
  the `latestQuotas` request, the older stations' keys.
- [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble) (Apache-2.0): the status message's field numbers, shared
  across models, and the serial prefixes.
- [foxthefox/ioBroker.ecoflow-mqtt](https://github.com/foxthefox/ioBroker.ecoflow-mqtt) (MIT): the PowerStream's and
  the PowerOcean's messages.
- [MichelFR/ha-ecoflow-iot](https://github.com/MichelFR/ha-ecoflow-iot) and [evcc](https://github.com/evcc-io/evcc)
  (MIT): the developer API's keys and signs per model, with EcoFlow's own developer documentation.

The writes were implemented in a clean room from `docs/clean-room/EcoFlowWrites.md`, a specification written by another
author from EcoFlow's developer documentation, tolwi/hassio-ecoflow-cloud, rabits/ha-ef-ble and
foxthefox/ioBroker.ecoflow-mqtt (its section 0 lists the commits): the implementer never read those projects, and no code
was copied. The spec's test vectors (the messages byte for byte, both signatures) are in the tests. The RIVER 3 Plus's
light comes from the spec's section 8 (its addendum), its vectors in the tests likewise.

It learned the developer API's request format and the field names from:

- [TarasKhust/ecoflow-api-mqtt](https://github.com/TarasKhust/ecoflow-api-mqtt), a Home Assistant integration. Its
  licence is not stated, so no code was copied from it. The request format and the field sign notes come from its
  documented behaviour.
- [ecoflow_mqtt_credentials](https://www.npmjs.com/package/ecoflow_mqtt_credentials), an Apache-2.0 package. Its
  sign-in steps informed the app route. Its code was not copied; the Swift is written from the same steps.
- The EcoFlow app, whose screens every reading was checked against.

Neither project's licence notice is carried here, since no code was taken from either.

## Maintainer

Mickael Palma ([@mp-consulting](https://github.com/mp-consulting)), who has the five devices above.

## Testing

- **Automated:** the tests use fake transports and never reach a device or an account. They check the request
  signature against a value computed independently, the state read from a quota and from MQTT pushes, the read
  request's bytes, a RIVER's and a RAPID's answers built message by message, a STREAM's backup state kept apart from
  its battery, a DELTA 2's JSON quotas, a PowerStream's tenths of a watt, the models left out, the decryption, the route setting, the
  schema checks, the energy history import, and the accessories the plugin publishes. The writes: the spec's messages
  and signatures byte for byte, both routes against fake transports (acknowledged, refused, unanswered, a JSON write
  confirmed by its readings), the Outlets and their two-second hold, a refused write failing in HomeKit, the limits from
  the Accessory Settings, and the gating. Run them with
  `swift test --filter EcoFlow`.
- **Recorded data:** nothing recorded from a real account is in the repository; each test builds the bytes it needs.
- **On a bridge:** both routes ran on a throwaway bridge with the five devices above, and their readings were compared
  with the EcoFlow app's screens at the same minutes.

The plugin stays experimental until someone has run it on their own devices.
