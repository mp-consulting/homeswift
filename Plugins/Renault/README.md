# Renault

**Experimental**: written from a functional specification and tested against fakes only, not yet on a car.

Renault, Dacia and Alpine cars in HomeKit, from the MyRenault cloud (Gigya's sign-in, Renault's Kamereon API). One
accessory per car, `Renault:<VIN>`, named after its registration plate:

| Service | What it does |
|---|---|
| **Battery** (primary, electric cars) | Battery Level, Charging State, Status Low Battery (below the car's minimum state of charge, else 20 %); the range, the time to a full charge and the charge power (see below) |
| **Climate** switch | On starts the climate at `climateTemperature`; Off stops it (`stop` or `cancel`, as the model wants) |
| **Charging** switch | On starts charging (refused while the car is unplugged); Off stops it on cars that can be told to |
| **Plugged In** contact sensor | Contact detected while the cable is in; Status Fault when the car reports a plug error |
| **Horn** and **Lights** switches | Sound the horn or flash the lights, then turn themselves off. The horn is off unless you include it |
| **Interior** and **Exterior** temperature sensors | Once the car has reported one |
| **Battery** temperature sensor | Once the car has reported its battery's temperature (older cars; not the Renault 5) |
| **Doors** contact sensors | Driver, passenger, rear doors and hatch, on cars that report them (not the Renault 5) |

Each is a Part of the car (its Accessory Settings), offered only when the car's model has the endpoint behind it. The
per-model table (`Sources/ModelEndpoints.swift`) says which; a model not in it takes Renault's default endpoints, and an
endpoint whose first read says the car does not have it (`err.tech.501`, `err.func.wired.forbidden`, `notFound`, `403`,
`400001`, HTTP 404) is dropped, remembered in `renault-endpoints.json` for a week (or until the model changes) so a
restart does not spend the quota finding it again.

### Range, time to full and charge power

HomeKit has no characteristic for a car's range, so the plugin adds its own to the Battery service, as other plugins
add Eve's: **Range (km)** (`batteryAutonomy`), **Time to Full (min)** (`chargingRemainingTime`, 0 unless the car
charges) and Eve's **Current Consumption** for the charge power in watts (`chargingInstantaneousPower`, 0 unless the car
charges), with the rest of the battery's report: **Available Energy (kWh)** (`batteryAvailableEnergy`, older cars),
**Charge Status** (`chargingStatus` in words: "waiting for a planned charge", "charge ended", "V2L connected"…) and
**Battery Updated** (when the car last reported, as it says it). The plug's state is the Plugged In sensor, a plug error
its Status Fault. The Home app does not show them; the web UI's accessory details and the Eve app do. The readings are
also recorded for the Status page's history (`<VIN>:range`, `timeToFull`, `power`, `batteryTemperature`,
`availableEnergy`, `level`, and `chargingStatus` as its code), the battery temperature where the car reports it. The charge power is not tagged for the Energy section: a car charging at home is part of the
home's use, which the home's meter counts already. They all come from the battery-status read each round already
makes: no request is added.

### Charge limits

The car's charge target and minimum state of charge are Accessory Settings of the car: **Charge target** (55 to 100 %,
in steps of 5) and **Charge minimum** (15 to 45 %, in steps of 5). When one is set and differs from what the car last
reported, the plugin sends both (`POST …/ev/soc-levels`, the one not set taken from the car) once, one request from the
hour's action reserve, and shows the new limits at once. It remembers the settings it sent, or found the car already
had (`renault-soc.json`), so the car answering its old values for a while, or a restart, does not send them again; a
later change in the MyRenault app, to either limit, wins until the setting changes. Limits Renault does not take, or a
request it refuses, are logged once and not tried again until the setting changes or the bridge restarts (a spent quota
is tried the next hour). Clearing both settings forgets them, so setting the same value later sends it again. The
minimum also sets when the battery shows as low.

### The Renault 5 E-Tech (`R5E1VE`)

Battery, plug, charging, climate, interior temperature, horn and lights. Charging **starts** the way the MyRenault app
does it: the plugin reads the car's charge settings, turns every departure program off and writes them back, so the car
charges at once. The programs **stay off** (re-enable them in the MyRenault app); the log says so each time. The R5
**cannot be told to stop charging**: Off is answered, nothing is sent, and the switch goes back to what the car reports
(unplug the car, or stop the charge from the charger). Climate stops with `"action": "stop"`.

Charging and Horn are marked as security controls, so the MCP server and the Assistant ask before they write them (a
real car in a public street, and charging changes the person's programs on an R5).

## Setup

On **Add accessories**, pick Renault, choose the account's country, and sign in with the MyRenault e-mail and password.
If Renault asks for it, it e-mails a code (pick the address when it has several) and the next step asks for it; a wrong
code is asked again without sending a new one. The bridge is then remembered by Gigya for about 30 days, so later
sign-ins skip the code. With several Renault accounts holding cars, the last step asks which one (MyRenault first).

The vault keeps the login token, the device ids Gigya remembers the bridge by, and the e-mail and password, so a login
token that dies is replaced once with the password, without you. If that is refused (the password changed, or Renault
asks for a code again), the plugin shows **Needs Authorization** and sends nothing more until Setup is done again.
The JWT and the person id stay in memory.

## Configuration

```json
{
  "platform": "Renault",
  "locale": "fr_FR",
  "username": "driver@example.com",
  "kamereonAccountId": "…"
}
```

| Option | Default | Meaning |
|---|---|---|
| `locale` | `fr_FR` | Picks Renault's servers and keys; its last two letters are the country. A locale the plugin does not list is looked up in the MyRenault app's configuration |
| `username` | | The MyRenault e-mail (Setup fills it in) |
| `password` | | Only for a block written by hand (no code step then: an account that asks for one needs Setup) |
| `kamereonAccountId` | the MyRenault account | The account whose cars are shown |
| `vins` | all | Only these cars: becomes Excluded Accessory Settings of the others at the next settings write |
| `climateTemperature` | 21 | °C asked for by the Climate switch, kept within 16 to 27 |
| `maxCallsPerHour` | 60 | Renault's hourly request quota (the MyRenault app counts too) |
| `pollInterval` | computed | Seconds between rounds; a value below the computed one is raised to it |

## Renault's quota

Renault allows about 60 requests an hour per account and answers `err.func.wired.overloaded` past it. The plugin:

- sends one request at a time for the whole account;
- never sends more than `maxCallsPerHour` in any rolling hour; polls and the reads that confirm an action stop at
  `maxCallsPerHour − 6`, so the last 6 requests of an hour are kept for what you do in the Home app;
- polls on Home Assistant's interval, `hour × pollers ÷ (budget − hourly requests)`: each round reads the battery and
  the climate status (and the doors where shown); the vehicle list and the state-of-charge limits are read once an hour.
  One R5 reads every 138 s;
- after an action, reads the related status after 60 s and 3 minutes, and shows what was written until a read agrees
  or 5 minutes pass;
- pauses everything for 15 minutes after the quota error (an action then answers "No Response").

The last data is served to HomeKit; nothing reaches Renault on a HomeKit read. A car shows No Response only when every
read has failed for three intervals.

## Privacy

Never logged: the password, tokens, the 2FA tokens and code, the device ids, request and response bodies, coordinates.
VINs are logged as their first 3 and last 4 characters. The plugin does not read the car's location.

## Gaps

Choices made where the specification is silent or leaves a choice:

- **The location is left out**: HomeKit has no place for a position, and coordinates are personal data, so the
  plugin neither reads `location` nor offers `refreshLocation` (spec 2). Mileage (`cockpit`) is not read either: one
  more endpoint each round for a figure HomeKit cannot show. The charge mode and tyres are not on the R5.
- **The action reserve** (6 requests an hour) is Homeswift's: Home Assistant's formula is kept, applied to the budget
  left after it, so a switch is not refused because polls took the hour.
- **State-of-charge limits** are read hourly (they set the low battery level) and written from the Accessory Settings,
  not from HomeKit: it has no fitting characteristic, and a Lightbulb's brightness would be a misuse (5.2).
- **Other models of the table** are given in the specification as differences from the R5's row; the keys it does not
  mention are taken as the R5's. Thermal cars are not in the table: their endpoints are defaults, dropped at the first
  read when the car refuses them.
- **Battery reads while charging** are not doubled.
- **`targetTemperature`** is clamped to 16 to 27 °C (the API's range is not documented); HTTP requests time out after
  30 s.
- A Gigya error at getJWT other than `403005`/`403013` is treated as Renault not answering (retried with Backoff), not
  as a refusal.

## How it was tested

Tests with a fake MyRenault cloud only (`Tests/`): the specification's vectors (locales, JWT expiry, Gigya and
Kamereon errors, the R5's endpoint table, poll intervals, lock-status aliases), Setup with the e-mailed code (a wrong
code, the remembered device on the second login), the R5's charge start and missing stop, climate with its optimistic
state, horn, the battery's readings on the accessory and the Status page, the charge target sent once (not again after a
restart, nor for a value Renault refuses), a dropped endpoint, a re-minted JWT, a dead login token replaced with the password, a refusal that stops
every request, the quota cool-down, and three scaled hours of polling with actions that never exceed the hourly budget
nor send two requests at once, a charge target and a charging car's readings included. To be checked on a real Renault 5 by its owner.

## Clean-room implementation

Compatible with the behaviour of [renault-api](https://github.com/hacf-fr/renault-api) by epenet (MIT, Copyright ©
2020 epenet) and of Home Assistant's [`renault` integration](https://github.com/home-assistant/core/tree/dev/homeassistant/components/renault)
(Apache License 2.0). Written from the functional specification in
[docs/clean-room/Renault.md](../../docs/clean-room/Renault.md), without reading or copying their code. The app keys and
server addresses in `RenaultLocale.swift` are the public constants of the MyRenault app. There is no maintained
Homebridge plugin for Renault: the platform name `Renault` and the VIN as Device Id are this plugin's own.

Maintainer: Mickael Palma.
