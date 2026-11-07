# SmartThings

Samsung SmartThings devices in HomeKit through SmartThings' cloud API (`api.smartthings.com`), signed in with your own
SmartThings app. Platform `HomeBridgeSmartThings`: a block of
[homebridge-smartthings-oauth](https://github.com/aziz66/homebridge-smartthings) or
[homebridge-smartthings-ik](https://github.com/iklein99/homebridge-smartthings) loads unchanged.

**Maintainer:** Mickael Palma. **Status:** experimental: written and tested against a fake of SmartThings' cloud built
from the official documentation, **not yet tried with a real SmartThings account**. Reports from someone with one are
welcome.

Homeswift is not affiliated with Samsung and cannot give anyone API access.

## The SmartThings Developer plan

Since 4 November 2026 the SmartThings API for individuals needs a **SmartThings Developer plan** on your Samsung
account: $4.99 a month (US price before tax), up to 100,000 cloud API calls a month and 10 active app installs,
server-sent events included, in some countries only (https://developer.smartthings.com/smartthingsapi). Without a
plan you cannot create or edit an API app, and from **15 December 2026** SmartThings says access for accounts without
one "may be limited, paused, or discontinued" and their active API keys are deactivated.

Every Homeswift user creates their own app (below), so as we read SmartThings' terms each user is a developer and needs
their own plan. Whether someone who only signs in to another person's app needs one too is **not clear**: SmartThings
does not say.

## Creating your app

SmartThings calls it an **API Access App** or **OAuth-In App**. Make it in the
[Developer Center](https://developer.smartthings.com/) (**Service Integrations → Get Started**) or with the
[SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli):

1. Install the CLI and sign in.
2. Run `smartthings apps:create` (newer CLIs call it `smartthings smartapps:create`; `smartthings --help` lists them).
3. App type **OAuth-In App**; display name e.g. `Homeswift`; description: anything; icon: skip; target URL: leave
   empty if the CLI lets you, else any `https://` address (it only serves webhooks, which Homeswift does not use).
4. Scopes: `r:devices:*`, `x:devices:*`, `r:locations:*`, `r:scenes:*`, `x:scenes:*` and **`sse`** (live updates; Setup
   asks whether your app has it).
5. Redirect URI: the one Homeswift's Setup shows, `https://<this bridge's address>:8583/oauth/callback`. You may add
   `https://httpbin.org/get` as a second one, to paste from (below).
6. Copy the **OAuth Client Id** and **OAuth Client Secret** at once: the CLI shows them only once
   (`smartthings smartapps:oauth:generate` makes a new pair).

## Signing in

On **Add accessories**, the SmartThings row's account Setup (or an AI agent through the MCP tools `start_setup` and
`continue_setup`) asks for the client id and secret, whether the app has the `sse` scope, and optionally the callback
server's address and port. It then opens SmartThings' page: sign in, **pick the location** and allow access. One
sign-in covers one location; several locations take several blocks, one each (untested).

SmartThings only redirects to `https://` addresses, so the bridge runs a small HTTPS server with a self-signed
certificate on port 8583 for ten minutes: the browser warns about the certificate when it comes back, accept it. If the
redirect cannot reach the bridge (another network, a private address SmartThings refuses), copy the address the
browser ends on (`https://httpbin.org/get?code=…&state=…` with the second redirect URI) and paste it in Setup.

The client id and secret are kept sealed in the bridge's vault as the account's credentials. The tokens are in the
vault too (`smartthings_tokens.json`, the Homebridge plugin's name): access tokens last about 24 hours and are renewed
when three quarters of their life has gone; each renewal gives a new **single-use** refresh token, saved to the vault
before anything uses it. A refresh token unused for about 30 days (the bridge off for a month), or one SmartThings
refuses, means signing in again: the plugin's card says it **Needs Authorization**, the log says why, and the
accessories stay (No Response) until you do. A crash between SmartThings' answer and the save also loses the chain.

## Updates

- **With `sse`**: SmartThings' server-sent events. The plugin subscribes to the location's device, health and
  lifecycle events, reads every device once on each (re)connection (events during a gap are lost), and once every 30
  minutes for safety. A stream silent for 5 minutes, a goodbye or an error makes a new subscription. If SmartThings
  refuses the stream (no plan, the scope not granted), it polls and tries the stream again every 30 minutes.
- **Without**: polling, **one list call for every device** (`GET devices?includeStatus=true&includeHealth=true`, all its
  pages) per period. The period is the smallest non-zero `Poll*Seconds` of the block, **at least 60 seconds**; 300
  without any; 0 everywhere reads only every 30 minutes. The log says what that costs in a month (pages × 86,400 ÷ period
  × 30: 43,200 at 60 s for one page, 8,640 at 300 s) and warns above 60,000 of the plan's 100,000 calls.
- After a write, the plugin reads that device's status once (3 seconds later when polling, 10 seconds later when no
  event confirmed it), within SmartThings' 12 requests a minute per device; commands go 10 a request at most. A 429
  pauses every read for the time SmartThings says.
- **Buttons need `sse`**: a poll sees a press only when the button's timestamp changed, and two presses of the same
  kind between polls look like one.

The webhook options (`server_url`, `webhook_port`, `verifyWebhookSignatures`, `selectedCapabilities`, ik's
`WebhookToken`) load and do nothing: a webhook needs a public HTTPS address. ik's relay is never contacted.

## In HomeKit

Each device is one accessory (`HomeBridgeSmartThings:<deviceId>`), its services from its components' capabilities;
every service has the stable subtype `<component>/<role>`.

| SmartThings | HomeKit |
|---|---|
| `switch` (+ `switchLevel`, `colorControl`, `colorTemperature`) | Switch; Lightbulb with brightness, colour and colour temperature (Adaptive Lighting when it has brightness and colour temperature); a `Light` category switch is a Lightbulb |
| `switch` with metering and `ExposeEnergyAsOutlet` (`outlet`) | Outlet with Outlet In Use |
| `powerMeter`, `energyMeter`, `powerConsumptionReport` | a Homeswift Meter on the device's switch, outlet or light; Eve's power, energy and voltage with `ExposeEnergyMonitoring` |
| `fanSpeed`, `fanSpeedPercent` | Fan v2 with speed |
| thermostats (`thermostatMode`, setpoints, operating state) | Thermostat in °C whatever the device's unit; heating and cooling thresholds when it has both setpoints; `heatMode`/`coolMode` per device |
| Samsung air conditioners | Thermostat (single setpoint) and Fan v2 (fan modes as a speed, swing); humidity, optional modes and the display light on request |
| air purifiers | Air Purifier (auto and fan modes), Filter Maintenance, Air Quality Sensor |
| `windowShade`, `windowShadeLevel` | Window Covering (pause as Hold Position, tilt) |
| `doorControl`, `lock` | Garage Door Opener, Lock: security controls, written by MCP clients only through `set_security_accessory` |
| `valve` | Valve |
| sensors (motion, contact, presence, occupancy, water, smoke, CO, temperature, humidity, illuminance) | the matching sensor; one that never reported a value is left out until it does |
| `button` | Stateless Programmable Switch (single, double, long); a remote's `button1`…`buttonN` labelled 1…N |
| `battery` | Battery (low at 20 %) |
| `securitySystem` | Security System (stay, away, night, disarmed, alarm), a security control |
| washers, dryers, dishwashers | a **Power** switch (or **Start** where SmartThings can start it remotely and the appliance has no power switch) and a **Running** occupancy sensor |
| ovens | the cavity temperature and **Running** (no start from HomeKit) |
| refrigerators | a temperature sensor per compartment (Fridge, Freezer, FlexZone) and the door's contact sensor |
| robot vacuums | a switch that starts it and sends it home, and **Running** |
| TVs | a Television published on its own (inputs from the TV, apps from `tvApps`, remote keys, volume and mute) |
| scenes | a momentary switch per scene (`HomeBridgeSmartThings:scene:<sceneId>`), and on the web UI's Scenes page |

An appliance's state, job, cycle, mode, time left, finish time and whether remote control is allowed are on the
plugin's page and given to the Assistant and MCP clients (`HomeBridgeSmartThings_list_devices`).

A device that is offline shows **No Response**, except a TV, which shows off. A device with nothing to map (a hub, an
unknown capability) is a Discovered Device that stays **Excluded**; its capabilities are on the plugin's page and in
`HomeBridgeSmartThings_diagnostics`, for asking for support.

**TVs** are published on their own: add each in the Home app (Add Accessory → More options → the TV) with the bridge's
setup code, or set `publishTVsAsExternal` to false to keep them on the bridge. SmartThings can only turn a TV on while
it keeps its network connection in standby (Samsung's "Power on with mobile").

**SmartThings Home Monitor** cannot be shown yet: SmartThings offers no API to read or set its state with the scopes an
app can have (its only surface is a webhook event, and the event stream has no security events). A device with the
`securitySystem` capability is shown; for Home Monitor itself, a SmartThings routine that follows a virtual switch is
the usual way round.

### Matter devices

A SmartThings device that is a **Matter** device may already be in Apple Home through its own Matter pairing: the log
and the plugin's page say so, and you set it **Not in Home** in its settings so it does not show twice. Nothing is done
automatically.

Devices that are **Homeswift's own accessories**, brought into SmartThings through Homeswift's Matter bridge, are
always skipped: Homeswift's bridge is recognised by its Matter ids (0xFFF1/0x8000) and its name, and a device is a copy
when its parent is that bridge, it is on the same Matter node, or its UniqueID is one of the bridge's accessories'. The
plugin's page lists what it skipped and why.

## Configuration

```json
{
  "platform": "HomeBridgeSmartThings",
  "name": "SmartThings",
  "PollSwitchesAndLightsSeconds": 60,
  "OptionalModeForAirConditioners": "WindFree",
  "tvApps": ["3201907018807", "111299001912"]
}
```

Every option of both Homebridge plugins is read:

- `BaseURL`: SmartThings' API, `https://api.smartthings.com/v1/` or the China base `https://api.samsungiotcloud.cn/v1/`;
  any other address is refused (the plugin logs it and does not start).
- `client_id`, `client_secret`: your app; Setup moves both into the vault. `client_secret` is sealed by its name;
  `client_id` is not a secret-named key, so it stays in clear text in config.json until the first settings write moves
  it.
- `Poll*Seconds` (`PollSwitchesAndLightsSeconds`, `PollSensorsSeconds`, `PollLocksSeconds`, `PollDoorsSeconds`,
  `PollSecuritySystemsSeconds`, `PollTelevisionsSeconds`, `PollWindowShadesSeconds`, `PollEnergySeconds`): the poll
  period, as above.
- `IgnoreDevices`, `ShowOnlyDevices`, `IgnoreLocations`: by name (typographic quotes count as plain ones, case aside).
  The bridge moves them to the devices' **Excluded** setting with its next settings write; names that match no device
  stay in the list.
- `thermostatModeOverrides` (`deviceName`, `heatMode`, `coolMode`): the modes a thermostat takes for Heat and Cool,
  moved to the thermostat's own settings (`heatMode`, `coolMode`).
- `ExposeHumiditySensorForAirConditioners`, `ExposeACDisplayLight`, `OptionalModeForAirConditioners` (`None`, `Sleep`,
  `Speed`, `WindFree`, `WindFreeSleep`, `Speed and Windfree`): plugin-wide defaults of each air conditioner's
  `exposeHumidity`, `displayLight` and `optionalMode`.
- `ExposeEnergyAsOutlet` (each switch's `outlet`), `ExposeEnergyMonitoring`, `ExposeRobotVacuum` (on unless false),
  `removeLegacySwitchForLaundry`, `ExposeMultiZoneRefrigerator` (a compartment's temperature from Samsung's driver state
  when SmartThings has none), `ExposeZigbangSmartDoorlock`.
- `enableTelevisionService`, `publishTVsAsExternal`, `registerVolumeSlider`, `tvApps`; a TV's `hiddenInputs`.
- New: `locationId` (Setup writes it), `callbackServerExternalAddress` and `callbackServerPort` (8583).

### Coming from homebridge-smartthings-oauth or -ik

The block loads as it is. aziz66's `oauth_access_token` and `oauth_refresh_token` (and a copied
`smartthings_tokens.json` in the plugin's folder) are taken as the starting tokens and moved into the vault; ik's
`AccessToken` (a Personal Access Token) is used until it expires, never refreshed, and the plugin asks to sign in with
your own app. Loaded and ignored: `server_url`, `webhook_port`, `verifyWebhookSignatures`, `selectedCapabilities`,
`WebhookToken`, `GarageDoorMaxPoll`, `UnregisterAll`, `ExposeContactSensorFor*` (the **Running** sensor replaces them),
`removeLegacySwitchForTV` (Homeswift adds no extra TV switch) and `frameTvDevices` (local control of Samsung TVs, a
possible later addition; its `token` is masked).

Changes from the Homebridge plugins: one list call per period instead of a timer per characteristic; hue and saturation
sent together; a thermostat's setpoint goes to the mode HomeKit has now; a failed temperature read is No Response, not
0 °C; each component's services are named after it; an empty label falls back to the device's name.

## Troubleshooting

- **HTTP 403**: no Developer plan on the account, or a scope missing from the app. After 15 December 2026 an account
  without a plan may get it on every call.
- **`invalid_grant`**: the refresh token is gone (used twice, expired, revoked): sign in again on Add accessories. At
  sign-in it can also mean the redirect URI differs from the app's.
- **`redirect_uri_mismatch`**: add the redirect URI Setup shows to the app exactly as written.
- **HTTP 429**: too many requests: lengthen the `Poll*Seconds`.

## Not verified

Written from SmartThings' documentation and the Homebridge plugins' behaviour; these were not checked against the real
service, and the plugin takes the safe side:

- the status code an account without a plan gets after 15 December 2026 (403 or 429 are handled), and whether token
  refreshes and event-stream calls count towards the 100,000 calls;
- whether SmartThings accepts a redirect URI with a private address or a `.local` name (the paste is the fallback),
  and whether the CLI's command is `apps:create` or `smartapps:create`;
- whether the CLI offers the `sse` scope and SmartThings grants it, and whether a personal access token can open the
  event stream (treated as polling only);
- the event stream's keepalive interval and lifetime, its goodbye message's exact form (a goodbye event name or data),
  the shapes of health and lifecycle events (read defensively);
- that one sign-in covers exactly one location, and several blocks for several locations;
- how SmartThings shows devices bridged through Homeswift's Matter bridge (parent, network id, UniqueID): the rules
  above should be checked against a real bridge;
- Samsung's own capabilities (`samsungce.*`, `samsungvd.*`, `custom.*`), whose names and commands come from the
  Homebridge plugins, and category names (`Television`, `Light`) used as hints;
- whether SmartThings refuses an appliance's remote start while remote control is off (Homeswift refuses it first);
- the `airQualitySensor` scale (values up to 5 are read as aziz66 did, higher ones as 0–100 in five bands).

## How it was tested

`Scripts/test.sh -- --filter SmartThings` runs it against a fake of SmartThings' cloud with the spec's fixtures: the
aziz66 and ik blocks, the device list's two pages, the lamp, thermostat, hub, washer, TV, air conditioner, shade, lock,
security system, power strip and remote, the commands each write sends, token rotation (saved before use, refused as
`invalid_grant`), the event stream (welcome, events, a keepalive, goodbye and a new subscription, a silent stream, a
refused one), polling within its period, 12 requests a minute per device, ten commands a request, 429 and 401 handling,
scenes, Setup's sign-in with a pasted address, and Matter copies. No account or network is used.

## Clean-room implementation

Compatible with the configuration of [homebridge-smartthings-oauth](https://github.com/aziz66/homebridge-smartthings)
by aziz66 and [homebridge-smartthings-ik](https://github.com/iklein99/homebridge-smartthings) by iklein99 (both
Apache-2.0). Written from the functional specification in [docs/clean-room/SmartThings.md](../../docs/clean-room/SmartThings.md),
without reading or copying their code. The API calls follow SmartThings' official documentation
(developer.smartthings.com).
