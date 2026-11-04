# tado°

tado° smart thermostats, radiator valves, hot water and air conditioners in HomeKit, through tado's cloud
(`my.tado.com`; there is no local API). Each active zone of each home becomes an accessory, with the home's presence,
weather, central switch, presence lock and child locks if the block asks for them.

**Maintainer:** Mickael Palma. **Status:** experimental: written and tested against fakes of tado's cloud, not yet
tried with a tado° account. Reports from someone with one are welcome.

## In HomeKit

| tado | HomeKit |
|---|---|
| HEATING zone | Thermostat (Off, Heat, Auto = the schedule), or a Heater Cooler with `easyMode`; Battery |
| HOT_WATER zone | Switch, or Valve (`accTypeBoiler: FAUCET`), or a Heater Cooler with its temperature (`boilerTempSupport`) |
| AIR_CONDITIONING zone | Heater Cooler (Heat, Cool), Rotation Speed with `acFanSpeed`, Fan and Dry mode switches |
| Zone extras | Window contact sensor (`openWindowSensor`), switch for open-window detection (`openWindowSwitch`), separate temperature and humidity sensors |
| Presence | An occupancy or motion sensor per person's phone, and "Anyone" |
| Weather | Outside temperature; solar intensity as a lightbulb or a light sensor |
| Extras | Central switch (schedule, Boost, Off, a Dummy, heating hours), presence lock (a Security System, or Home and Away switches), child locks |

Accessory names, and so their ids (`TadoPlatform:<home> <zone> Heater`, `… Boiler`, `… AC`, `<home> Weather`…), are
the Homebridge plugin's, and services keep its subtypes: a block moved from Homebridge makes the same accessories. Zone
temperatures are HomeKit's Celsius whatever the home's unit (the Homebridge plugin put Fahrenheit numbers in them).

## Setup

Add accessories (or the MCP tool `start_setup`) signs in to tado: enter the account's email, open tado's page, sign in
as that account and confirm the code shown. The bridge waits for tado's answer, checks the account is the one entered
(`/me`), and keeps its refresh token in the vault, one per email, shared by every home of that account. A Homebridge
token file (`.tado-token-<hash>.json`) copied into the plugin's folder moves into the vault. An email with no home in
the block brings the account's homes and their zones. When tado refuses the refresh token, the log says to sign in
again; nothing else is tried until then.

## Configuration

The block of [homebridge-tado](https://github.com/homebridge-plugins/homebridge-tado) works unchanged:

```json
{
  "platform": "TadoPlatform",
  "homes": [{
    "id": 123456, "name": "My Home", "username": "mail@example.com",
    "zones": [
      { "active": true, "id": 1, "name": "Living Room", "type": "HEATING", "mode": "MANUAL", "openWindowSensor": true },
      { "active": true, "id": 0, "name": "Hot Water", "type": "HOT_WATER", "mode": "AUTO" }
    ],
    "presence": { "anyone": true, "user": [{ "active": true, "name": "Phone 1", "accType": "OCCUPANCY" }] },
    "weather": { "temperatureSensor": true },
    "extras": { "centralSwitch": true, "presenceLock": true, "accTypePresenceLock": "ALARM" }
  }]
}
```

Every option of the Homebridge plugin is read (`polling`, `nightPolling`, `addJitter`, `tadoApiUrl`, `skipAuth`,
`temperatureUnit`, `preferSiriTemperature`, `telegram`…). Each zone's own options (`mode`, `modeTimer`, `minValue`,
`maxValue`, `minStep`, `easyMode`, `noBattery`, `delaySwitch`, `autoOffDelay`, `openWindowSensor`, `openWindowSwitch`,
`separateTemperature`, `separateHumidity`, `boilerTempSupport`, `accTypeBoiler`, `acFanSpeed`, `acFanModeSwitch`,
`acDryModeSwitch`) are the Accessory Settings of the zone's accessory: the bridge moves them out of `zones` into
`_accessories` with its next settings write, and an inactive zone becomes an Excluded one. `telegram.token` is under a
secret-named key, so the bridge seals it; a legacy `password` is read by nothing and goes.

New: `dailyRequestLimit` (100 by default), the requests tado allows the account a day.

## tado's daily limit

tado allows an account without a subscription about 100 requests a day since 2025. The Homebridge plugin polled
every 5 minutes (576 or more requests a day) and asked for a zone's state before every write. This plugin:

- asks `zoneStates` once a poll for every zone, and the zone list (batteries, open-window detection) and heating hours
  every 6 hours;
- writes without asking first, from the last poll's state, and does not poll after a write; writes within 400 ms of
  each other become one request;
- without `polling`, polls as often as the day allows: the requests a poll makes over what is left of
  `dailyRequestLimit` once a fifth is kept for writes and sign-ins, every 1137 s (19 minutes) for zones alone, never
  more often than every 5 minutes. A home's `polling` is honoured, with one warning when it exceeds the day;
- counts its requests per account, the API's and the login server's, from midnight in Europe/Berlin, kept in
  `tado-api-<hash>.json`, logged hourly ("tado° API counter") and answered at `GET /api/plugins/TadoPlatform/<name>/status`;
- backs off when tado does not answer, up to an hour between polls, and logs the outage once.

## Changes from the Homebridge plugin

Fixed: a zone, person or child lock without a name skips only itself; the central switch drives the active heating
zones only, a TIMER zone's duration is its minutes × 60 and an AUTO zone's ends at the next time block; zones are
matched by name exactly (`Bath` no longer updates `Bathroom`); `boilerTempSupport` applies to hot water only; a low
battery sets Status Low Battery; changing an air conditioner's mode alone sends it; CUSTOM's "on goes back to the
schedule" works; the access token lives as long as tado's `expires_in` says. Writing Temperature Display Units no longer
rewrites the home's `temperatureUnit`.

Not ported: the Homebridge settings page and its legacy `user[]` auto-configuration (Setup does it), and the
zone-state debug file `tado-states-<home>.json`.

## How it was tested

`swift test --filter TadoTests` runs it against a fake of tado's cloud: the spec's zone states and overlay bodies, the
identity hashes, the device-code sign-in, a refresh token moved in from a Homebridge file and rotated, the request
budget. No account or network is used.

## Clean-room implementation

Compatible with the configuration of [homebridge-tado](https://github.com/homebridge-plugins/homebridge-tado) by SeydX
and smart7324 (MIT). Written from the functional specification in
[docs/clean-room/Tado.md](../../docs/clean-room/Tado.md), without reading or copying its code. tado's device
authorization is the standard OAuth 2.0 Device Authorization Grant ([RFC 8628](https://www.rfc-editor.org/rfc/rfc8628)).
