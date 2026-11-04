# Somfy TaHoma

Puts an Overkiz setup in HomeKit: Somfy TaHoma (v2, Beecon, Switch) and Connexoon, Atlantic, Thermor and Sauter
Cozytouch, Bouygues Flexom, Rexel Energeasy Connect and Hitachi Hi Kumo. Each device of the setup becomes an accessory
chosen from its uiClass and widget, and the scenarios can be switches. Changes arrive through the server's event
listener; HomeKit's changes go out as executions, followed until they complete.

**Status: experimental.** Nobody has run it against a real gateway or account yet: it is tested against a fake Overkiz
server that answers as the [functional spec](../../docs/clean-room/Tahoma.md) describes it (see [Tests](#tests)).
Please report what works on yours.

**Maintainer:** Mickael Palma.

## In HomeKit

| Overkiz uiClass (widget) | HomeKit |
|---|---|
| `RollerShutter`, `ExteriorScreen`, `Screen`, `Shutter`, `Curtain`, `SwingingShutter`, `Pergola`, `Awning`, `Generic` (`RTSGeneric`) | Window Covering (with **My** for a stateless RTS motor) |
| `Window` | Window |
| `VenetianBlind`, `ExteriorVenetianBlind`, `AdjustableSlatsRollerShutter` | Window Covering with the slats' tilt |
| `GarageDoor`, `Generic` (`CyclicGeneric`, `RTSGeneric4T`), `Gate` | Garage Door Opener; a gate's pedestrian opening is a Lock Mechanism (`pedestrian`) |
| `DoorLock` | Lock Mechanism |
| `Alarm` (and MyFox, TSK) | Security System |
| `Light`, `Generic` (`DimmerOnOff`), `OnOff`, `Siren` | Lightbulb or Switch, Switch, Speaker |
| Contact, window handle, occupancy, smoke, rain, water, temperature, humidity, light and air sensors | The matching sensor services |
| `HeatingSystem` and its Atlantic, Somfy, Hitachi and EvoHome widgets | Thermostat (with **Prog** and **Eco**, Boost and drying switches where they exist) |
| `WaterHeatingSystem` | Thermostat (with Boost, the showers left) |
| `VentilationSystem` | Air Purifier |

Garage doors, gates, locks and alarms are security controls: the MCP server and the Assistant change them only after the
user confirms. A sub-device that measures something for its device (a heater's temperature or energy sensor) is
attached to it rather than shown alone. Scenarios are switches when `exposeScenarios` is on (or lists their names).

## Setup

**Add accessories** asks for the service and the account: the vendor app's e-mail and password, or, for a gateway's
local API, its PIN (or IP address) and a Developer Mode token (in the TaHoma by Somfy app, tap the box's PIN seven times
in its settings, accept the terms, then generate a token). The account is kept in the bridge's vault.

With a Somfy cloud account whose setup has a single gateway, the plugin mints a Developer Mode token for that gateway
itself, over the cloud session (Developer Mode turned on when the gateway says it is off, a token generated, then
activated with the label "Homeswift" and the scope `devmode`; kept in the vault), and talks to the gateway on the local network from then on, falling
back to the cloud at start when the gateway does not answer. `preferLocalAPI: false` keeps it on the cloud. The
accessories are the same either way: their Device Id is the deviceURL, which the cloud and the gateway share.

## Configuration

The block is homebridge-tahoma's, so a Homebridge configuration works unchanged:

```json
{ "platform": "Tahoma", "name": "My TaHoma Box", "service": "somfy_europe", "user": "user@example.com", "password": "…",
  "exposeScenarios": true, "exclude": ["hue", "rts", "Main door"],
  "devicesConfig": [ { "key": "Alarm", "stayZones": "A,C" }, { "key": "UpDownRollerShutter", "defaultPosition": 50 } ] }
```

| Option | Default | |
|---|---|---|
| `service` | `somfy_europe` | `local`, `somfy_europe` (`tahoma`, `tahoma_switch`, `connexoon`), `somfy_australia` (`connexoon_rts`), `somfy_north_america`, `cozytouch`, `flexom`, `rexel`, `hi_kumo` |
| `user`, `password` | | The account, or the gateway's PIN or address and its token. Moved to the vault by the first settings write |
| `pollingPeriod` | 60 | Seconds between event fetches; at least 10 on a cloud, 0 fetches only while a command runs |
| `execPollingPeriod` | 5 | Seconds between event fetches while a command runs |
| `refreshPeriod` | 30 | Minutes between full refreshes, which catch changes made with remotes, and new or removed devices |
| `exposeScenarios` | false | `true`, or the names of the scenarios to show |
| `exclude` | `[]` | uiClasses, widgets, controllable names, labels or protocols to leave out (`Pod`, `ProtocolGateway` and other gateway parts always are) |
| `devicesConfig` | `[]` | Options by `key`: a protocol, uiClass, widget, label, deviceURL or the Homebridge accessory's UUID, merged in that order |
| `preferLocalAPI` | true | Homeswift's own: see Setup |
| `debug`, `proxy` | | Debug lines at info level; a base URL every request goes to, with `X-Forward-Host` |

A device's own options are Accessory Settings (its settings on the web UI): `reverse`, `defaultPosition`,
`initPosition`, `movementDuration`, `offsetMovementDuration`, `blindMode`, `blindsOnRollerShutter`, `lowSpeed`
(`always` or `HH:MM-HH:MM`), `cyclic`, `cycleDuration`, `pedestrianDuration`, `stayZones`, `nightZones`,
`derogationDuration`, `comfort`, `eco`. A `devicesConfig` entry keyed by a device, and an `exclude` entry naming a device
or a scenario, move there with the block's next settings write; entries for a kind of device stay.

## How it talks to Overkiz

- **Somfy Europe:** Somfy's OAuth, as the TaHoma app signs in (spec section 11): a password grant at
  `accounts.somfy.com` with the app's public client, then `Authorization: Bearer` on `ha101-1.overkiz.com`, with no
  `/login` and no cookie. The token is refreshed when it has 5 s left (the event listener is registered again then), and
  the refresh token is kept in the vault (`somfy-oauth.json`), so a restart refreshes instead of sending the password;
  a 401 from Overkiz is one new password grant and one retry. `error.invalid.grant` is a refused password.
- **Other clouds:** HTTPS to `ha<n>-1.overkiz.com` (the system's roots), signed in with `POST /login` and its `JSESSIONID`
  cookie (Somfy Oceania and North America still sign in this way); Cozytouch first gets an Atlantic token and JWT. A 401
  signs in again once. A sign-in the server refuses (4xx)
  pauses sign-ins for 60 s, then four times longer each time up to 4 hours, so a wrong password does not get the account
  banned; the plugin's card then says it Needs Authorization.
- **Local API:** `https://<gateway>:8443/enduser-mobile-web/1/enduserAPI` with the token as a Bearer. The gateway is found
  by browsing `_kizboxdev._tcp` for 10 s and matching its `gateway_pin` TXT record (its name without one), else
  `gateway-<PIN>.local`. Its certificate must be signed by the **Overkiz Root CA**, bundled from Somfy's own developer
  documentation (`https://ca.overkiz.com/overkiz-root-ca-2048.crt`, fingerprint checked by the tests), and name
  `gateway-<PIN>.local` when the PIN is known; reached by IP address alone, any certificate that CA signed is accepted.
  The local API is never sent an execution mode (it refuses them).
- **Events:** one listener per setup, fetched every `pollingPeriod` (every `execPollingPeriod` while a command runs);
  a failed fetch waits 10 s, doubling up to 10 minutes, is logged once per outage, and registers the listener again.
- **Commands:** writes within 100 ms go out as one execution (one action per device, commands of a device merged by
  name), sliders after 500 ms of quiet; each is followed until it completes, fails or 2 minutes pass. A full execution
  queue is tried again with a backoff.

Passwords, the OAuth client secret and tokens, the session cookie and the JWT are never logged, and the gateway's PIN is masked in request logs.

## Gaps

Choices made where the spec is silent or the original was wrong, each labelled in the code:

- Somfy's multi-site sign-in (a Keycloak token exchange and a site directory, spec 11.6) is not implemented: the spec
  gives it for reference, as a flow that may still change, and choosing among several sites would need a Setup step.
  Somfy Europe accounts sign in with the single-site OAuth, which is the TaHoma app's for one home.
- Rexel's newer Azure sign-in, and the other servers the spec lists for reference only, are not supported; `rexel` is
  kept as an unverified session login.
- The command labels the vendor's app shows in its history are translated only for `setClosure` (English and French),
  the only entry the spec gives; the others are the raw `<name>.<parameter>` keys, as the original showed most of them.
- The comfort and eco target temperature states of the Pass APC heating zone and water heater are not named by the spec;
  `core:ComfortHeatingTargetTemperatureState`, `core:EcoHeatingTargetTemperatureState`,
  `core:ComfortTargetDHWTemperatureState` and `core:EcoTargetDHWTemperatureState` are inferred from their commands.
- States several mappers read together are computed after each batch of events rather than 500 ms later.
- The Somfy thermostat's refresh on HomeKit reads is not done (nothing runs on HomeKit's read path); the full refresh
  covers it.
- Electricity sensors shown on their own (`ElectricitySensor`) are left out: the original showed nothing in them. A
  heater's energy sensor still gives its thermostat Eve's Total Consumption.
- The V2 SPLIT water heater's target temperature steps by 0.5 °C from 50 to 54.5 (the original's step of 2 with a list
  of valid values cannot be expressed on a float characteristic).
- The local API is chosen at start: a gateway that stops answering later is not swapped for the cloud until the next
  start, and a new device appears with the next full refresh.
- Fixed from the original (spec section 10): commands of one device are merged instead of dropped, position and tilt
  have their own debounce, and each sends the other's latest value with it, an unknown uiClass is skipped instead of stopping discovery, JSON
  states update, `blindsOnRollerShutter` moves 2 % from the reached closure, a gate reporting only
  `core:OpenClosedState` is read, the exterior heater reads `core:OnOffState`, the water detection sensor reads its
  state, the CO2 sensor keeps its defects, MyFox's Home arms partially, a garage door's failed write restores any
  previous target, the ventilation's Active and current state follow the device, Hue writes are sent, a list of
  scenario names is honoured, the low-speed shutter honours the cover options, backoffs are capped, and identities
  are the deviceURL on the cloud and locally.

## Tests

`swift test --filter Tahoma` runs the plugin against a fake Overkiz server, with no gateway, account or network: the
spec's UUID and serial vectors, the root CA's fingerprint, the setup excerpt's accessories (positions, the stateless
blind's My, the heater's Prog and temperature from its attached sensor), the spec's apply body byte for byte, writes
coalesced (a drag is one command, two devices one execution) and polling once per cycle, execution events and a hazard
failure, a timed stateless move that stops itself, venetian, alarm and water heater commands, exclusions, option
precedence, scenarios, timeouts, the session and lockout, Somfy's OAuth against the spec's vectors (the grant's body, the Bearer, the refresh 5 s
before expiry, a 401 as a new password grant, a refused grant, the refresh token kept between runs), Cozytouch's sign-in, the local API found by PIN, a Somfy
account moving to the local API with a minted token, the settings moved into `_accessories`, and Setup.

## Clean-room implementation

Compatible with the configuration of [homebridge-tahoma](https://github.com/dubocr/homebridge-tahoma) by Romain Duboc
(Apache License 2.0), built on his [overkiz-client](https://github.com/dubocr/overkiz-client) (Apache License 2.0), with
details of the local API and the servers from [python-overkiz-api](https://github.com/iMicknl/python-overkiz-api) by
Mick Vleeshouwer (MIT). Written from the functional spec in [docs/clean-room/Tahoma.md](../../docs/clean-room/Tahoma.md),
without reading or copying their code. The Overkiz Root CA and the `gateway_pin` TXT record come from Somfy's own
documentation, [Somfy-TaHoma-Developer-Mode](https://github.com/Somfy-Developer/Somfy-TaHoma-Developer-Mode).
