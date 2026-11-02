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
for the home of the account's first STREAM (one that reports, else one configured, else the app's device list's). With
all four, the Status page splits each day's home use by source. The first import takes everything (a request per month
and chart); then the last two days are taken again every 6 hours, as the cloud fills hours in late. The battery and
grid charts' codes are the ones the app's dashboard lists for the system (`/iot-service/dashboard/platform/getPageListById`
with page type 4, then `getPageChartByPageId`), asked for by a unit's serial number; a system whose cloud refuses them
keeps its solar and home history. The space's answers carry the home's address: only its id and time zone are read,
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

## Models

The plugin knows a model by the first characters of its serial number. A model it does not know, or one with no
battery for HomeKit (a Smart Plug, EcoFlow's Shelly plug and meter, a microinverter or Smart Meter, a Smart Generator,
an Alternator Charger, a WAVE, a PowerPulse, the first Smart Home Panel), is left out, and the log says so once, with
the serial number's first four characters only.

| Model | Serial | App route | Developer API | Checked on a device |
|---|---|---|---|---|
| STREAM Ultra, AC Pro | BK11, BK31 | Protobuf, as above | STREAM keys, as above | Both routes |
| STREAM Ultra X, Pro, Max, AC | BK61, BK12, BK41, BK51 | As the Ultra | As the Ultra | No |
| RIVER 3, RIVER 3 Plus | R65x, R63x | The status message, as above | `cmsBattSoc`, `powInSumW`, `powOutSumW`, `powGetAcIn`, `powGetAcOut` | App route |
| DELTA 3 (Plus, Classic, Air, Max, Max Plus, Ultra, Ultra Plus), DELTA Pro 3, DELTA Pro Ultra X, GLACIER Classic | P231, P351, P32x, PR1x, D3N1, D3M1, D751, D511, MR5x, P101, RF45 | As the RIVER 3 | As the RIVER 3 | No |
| RAPID Pro X; RAPID Pro | P513; P521 | The status message: input, output, the percentage (262) | Not read | RAPID Pro X, app route |
| DELTA 2, 2 Max, 2 Plus; RIVER 2, 2 Max, 2 Pro; DELTA Pro, Max, Mini; GLACIER | R33x, R35x, D36x, R60x, R61x, R62x, DC…, DAEB, DBAB, BX11 | JSON quotas, asked with `latestQuotas` | The same keys | No |
| DELTA Pro Ultra | Y711 | Not read | `hs_yj751_pd_appshow_addr.soc`, `.wattsInSum`, `.wattsOutSum` | No |
| PowerStream | HW51 | 20/1, tenths of a watt | `20_1.*` | No |
| PowerOcean; PowerOcean Fit | HJ31; HC31 | 96/33 | `bpSoc`, `mpptPwr`, `sysLoadPwr`, `sysGridPwr`, `bpPwr`; Fit not read | No |
| Smart Home Panel 3 | HR62, HR63, HR6C | The status message's system flows | Not read | No |
| Smart Home Panel 2 | HD31 | Not read | `backupIncreInfo.backupBatPer`, `wattInfo.gridWatt`, `wattInfo.allHallWatt` | No |

The older stations' JSON keys: the display's percentage (`bms_emsStatus.lcdShowSoc`, `ems.lcdShowSoc` on a DELTA
Pro or Max, `pd.soc`), the totals (`pd.wattsInSum`, `pd.wattsOutSum`; a GLACIER's `bms_bmsStatus.inWatts` and
`outWatts`), the inverter's AC (`inv.inputWatts`, `inv.outputWatts`) and the solar charger (`mppt.inWatts`, in tenths of
a watt on a DELTA Pro, Max or Mini). A PowerStream's battery power is positive while the battery supplies the inverter,
and it has no grid reading. A home system's solar, home, grid and battery feed the Status page's Energy section, as a
STREAM's do; a station's ports do not. `EcoFlowModels.swift` has every key.

## Configuration

Add an `EcoFlow` platform block to `config.json`:

```json
{
  "platform": "EcoFlow",
  "name": "EcoFlow",
  "accessKey": "your access key",
  "secretKey": "your secret key",
  "region": "eu",
  "email": "you@example.com",
  "password": "your EcoFlow password",
  "devices": [
    { "id": "your STREAM's serial number", "name": "STREAM Ultra" },
    { "id": "your RIVER's serial number", "name": "RIVER 3 Plus" }
  ]
}
```

- **Route:** `both` (the default), `developer` or `app`. The form shows the settings the route needs. The web UI's **Add
  accessories** page asks for the route, then the keys, the app's email and password, or both, and checks each before
  keeping it (the keys in the vault).
- **Access key and secret key:** from your developer account. They are stored in `config.json`, which only the
  bridge's owner can read; the secret key is sent only in each request's signature, never in a URL or a log.
- **Region:** `us` or `eu`, the region your developer account was created in.
- **Email and password:** your EcoFlow account's, for the app.
- **Devices:** the serial numbers the app reads, with optional names. A name replaces the one the device reports.
  Without a list, the app reads the account's devices from its device list (EcoFlow's broker refuses a subscription to
  every device at once). The plugin's page offers to add the devices it reads to this list (**Add to the
  configuration**), under the names they report.
- **Import the energy history:** `importHistory`, on by default; it needs the email and password (above, [What it
  does](#what-it-does)).
- **Interval** (under Developer API): `pollingInterval`, the seconds between reads of the developer API's REST values, 60 by
  default, 30 at least; the form shows it when the route uses the developer API. Both routes also use MQTT, which is
  live whatever the interval: the developer API's pushes for a STREAM, and the app's stream for every device it reads (a
  RIVER, a RAPID), as in the app.
- **The form** groups the settings by route: **EcoFlow account** (email, password, the history import) and **Developer
  API** (keys, region, interval), each shown when the route uses it. The email and password are marked required on the
  EcoFlow app route, the keys on the developer API's; with Both, either pair, or both, will do.

Every option is optional. There is no Homebridge plugin to stay compatible with, so the option names are the
plugin's own.

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
  schema checks, the energy history import, and the accessories the plugin publishes. Run them with
  `swift test --filter EcoFlow`.
- **Recorded data:** nothing recorded from a real account is in the repository; each test builds the bytes it needs.
- **On a bridge:** both routes ran on a throwaway bridge with the five devices above, and their readings were compared
  with the EcoFlow app's screens at the same minutes.

The plugin stays experimental until someone has run it on their own devices.
