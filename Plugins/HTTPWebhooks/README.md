# HTTP Webhooks

Virtual accessories driven over HTTP: sensors, switches, push buttons, doorbells, dimmable lights, thermostats,
outlets, security systems, garage doors, stateless switches, window coverings, locks, fans, CO2 sensors and valves,
listed in the block. One HTTP (or HTTPS) server on the LAN takes webhooks from other systems (a home automation
server, a script, a device's own HTTP actions) that set their states or read them back, and a write from HomeKit can
call a URL the entry gives, so tapping a tile in the Home app reaches the other system.

There is no discovery, polling or device protocol: every accessory is virtual, driven only by webhooks and HomeKit.

**Maintainer:** Mickael Palma. **Status:** experimental: tested against fakes and on a throwaway bridge, not yet with
the systems users drive with it.

## Clean-room implementation

Compatible with the configuration of [homebridge-http-webhooks](https://github.com/benzman81/homebridge-http-webhooks)
by benzman81 and its contributors (GPL-3.0). This plugin was written from the functional specification in
[docs/clean-room/HTTPWebhooks.md](../../docs/clean-room/HTTPWebhooks.md), without reading or copying that plugin's
code; no code was copied, so it carries no third-party notice.

## Configuration

The block of homebridge-http-webhooks works unchanged, with the same platform name and option names:

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "http_auth_user": "hook",
  "http_auth_pass": "s3cret",
  "sensors": [{ "id": "motion1", "name": "Hall Motion", "type": "motion", "autoRelease": true, "autoReleaseTime": 2000 }],
  "switches": [{ "id": "switch1", "name": "Desk Fan", "on_url": "http://10.0.0.5/relay?on=1", "off_url": "http://10.0.0.5/relay?on=0" }],
  "lights": [{ "id": "light1", "name": "Desk Lamp", "brightness_factor": 2.55,
               "brightness_url": "http://10.0.0.7/set?on=%statusPlaceholder&bri=%brightnessPlaceholder" }]
}
```

| Option | Default | |
|---|---|---|
| `webhook_port` | `51828` | The server's port, a number or a numeric string |
| `webhook_listen_host` | `0.0.0.0` | The address it listens on: `::` for IPv6 too, `127.0.0.1` for this machine alone |
| `webhook_enable_cors` | off | CORS headers on every answer, and `OPTIONS` answered with 200 |
| `http_auth_user`, `http_auth_pass` | | Basic authentication on every request, when both are given. Read from a Homebridge block; Setup (**Add accessories**, the account's login) keeps them in the vault instead and takes them out of config.json |
| `https` | off | HTTPS, when exactly `true` |
| `https_keyfile`, `https_certfile` | | PEM key and certificate; without both, a self-signed certificate made once (for `homebridgeHttpWebhooks.com` and `localhost`), kept in the vault and made again after 364 days |
| `cache_directory` | | Read by Homebridge only (see "State") |
| `sensors`, `switches`, `pushbuttons`, `doorbells`, `lights`, `thermostats`, `outlets`, `security`, `garagedooropeners`, `statelessswitches`, `windowcoverings`, `lockmechanisms`, `fanv2s`, `co2sensors`, `valves` | | The accessories, each with an `id` (the webhook's `accessoryId`) and a `name` |

Every entry's options are those of homebridge-http-webhooks: a sensor's `type` (`contact`, `motion`, `occupancy`,
`smoke`, `temperature`, `humidity`, `airquality`, `light`, `leak`), `autoRelease` and `autoReleaseTime`; a doorbell's
and a stateless switch button's `single_press`, `double_press` and `long_press`; a light's `brightness_factor`; a
thermostat's `minTemp`, `maxTemp` and `minStep`; a window covering's `auto_set_current_position`; a fan's
`speed_factor`, `enableLockPhysicalControls`, `enableTargetStateControls` and `enableSwingModeControls`; a CO2
sensor's `co2_peak_level`; a valve's `type`; and `rejectUnauthorized` for the calls of an entry.

An action's call is `<action>_url`, `_method` (`GET` by default), `_body`, `_form` (a JSON object sent as a form,
which wins over the body) and `_headers` (a JSON object, as a string). A body goes with `POST`, `PUT` and `PATCH`; a
user name and password in the URL become Basic authentication. The actions are `on`/`off` (switches, outlets, lights,
fans, valves), `push`, `brightness` (`%statusPlaceholder`, `%brightnessPlaceholder`), `set_target_temperature` (`%f`),
`set_target_heating_cooling_state` (`%b`), `set_state` (`%d`), `open`/`close` (garage doors; for locks, unlock and
lock), `open`, `open_20`, `open_40`, `open_60`, `open_80`, `close` (window coverings, by position), `speed`
(`%speedPlaceholder`), `lock`/`unlock` (a fan's physical controls), `target_state` (`%targetState`), `swing_mode`
(`%swingMode`) and `rotation_direction` (`%rotationDirection`). A call times out after 10 seconds (35 for a window
covering), and HomeKit's write fails with it: the Home app shows No Response.

`*_headers`, `*_url` and `*_body` are kept in config.json as written: a token there is not sealed or resolved from the
vault. The log never shows headers, bodies, query strings or the user name and password of a URL. On a redirect to
another host, or from HTTPS to HTTP, a call drops its Authorization and every header the entry gives.

### Accessory ids

An accessory's id is `HttpWebHooks:<name>`, the seed Homebridge gives a static platform's accessory, so its Device Id is
the entry's `name`. As in Homebridge, renaming an entry makes a new accessory; two entries with the same name are one
identity, and the second is left out with an error. Rename an accessory with **Rename** in the web UI instead (its
`_accessories` entry, by name).

## The webhooks

Any method and path; only the query counts, and the body is ignored:

```sh
curl -u hook:s3cret "http://bridge.local:51828/?accessoryId=motion1&state=true"     # {"success":true}
curl -u hook:s3cret "http://bridge.local:51828/?accessoryId=switch1"                # {"success":true,"state":false}
```

| Kind | Parameters | Readback (no parameter) |
|---|---|---|
| contact, motion, occupancy, smoke sensor | `state=true\|false` | `state` |
| temperature, humidity, air quality, light, leak sensor | `value` | `state` |
| switch | `state` | `state` |
| push button | `state=true` presses it | |
| doorbell | `event=0\|1\|2` (single, double, long), one the entry allows, else `{"error": …}` | |
| light | `state`, `value` (brightness in the target scale) | `brightness`, `state` |
| thermostat | `currenttemperature`, `targettemperature`, `currentstate`, `targetstate` | |
| outlet | `state`, `stateOutletInUse` | `state`, `stateOutletInUse` |
| security system | `currentstate` (0–4), `targetstate` (0–3) | `currentState`, `targetState` |
| garage door | `currentdoorstate`, `targetdoorstate`, `obstructiondetected` | `currentState`, `targetState`, `obstruction` |
| stateless switch | `buttonName`, `event` | |
| window covering | `currentposition`, `targetposition`, `positionstate` | `CurrentPosition`, `TargetPosition`, `PositionState` |
| lock | `lockcurrentstate` (0–3), `locktargetstate` (0–1) | `currentState`, `targetState` |
| fan | `state`, `speed`, `rotationDirection`, `lockstate`, `targetState`, `swingMode` | |
| CO2 sensor | `value` (ppm) | `state` |
| valve | `state`, `statusFault` | `state`, `statusFault` |

Without `accessoryId` the server answers 404 `[ERROR Http WebHook Server] No accessoryId in request.`, and for an
unknown one 404 `[ERROR Http WebHook Server] AccessoryId '<id>' not found.`; without the right credentials, 401 with
`WWW-Authenticate: Basic realm="Auth required"`. A webhook never makes an outgoing call. Values that are not numbers
are left out (and logged); numbers are kept within the characteristic's bounds.

The server listens on the LAN: give it a user name and a password through Setup (the bridge warns without them), and HTTPS when
the network is not trusted. It takes a body of 64 KB at most, 64 connections at once, and closes a connection quiet for
30 seconds.

## State

The states are kept in the plugin's folder (`plugins/HttpWebHooks-<name>/http-webhooks-state.json`, under the
Homebridge plugin's keys), so readbacks and HomeKit show the last values after a restart. The Homebridge plugin's
node-persist cache (`cache_directory`) is not read: after a move from Homebridge, states start from the defaults until
the first webhook of each accessory.

## Differences from homebridge-http-webhooks

The HTTP interface is the same (port, paths, parameters, methods, authentication, answers), so scripts keep working.
Where the Homebridge plugin's behaviour is clearly unintended, this one follows what it documents:

- **Readbacks answer the values after the call, as numbers.** A sensor's `value` comes back as `21.5`, not `"21.5"`. The
  garage door, window covering and lock answer their current values whatever was given (the Homebridge plugin answered
  the values before the call, and only for the parameters given); the security system adds `targetState`.
- **A fan's `speed` alone does not turn it off.** Only `state` sets Active; each fan parameter sets its own
  characteristic and is kept, so HomeKit reads it back.
- **A fan's `lockstate` works** (the Homebridge plugin read a differently cased parameter).
- **The CO2 readback answers the stored level**, and the level and detection are set only when they change.
- **The garage door keeps its current state** after a HomeKit write that worked.
- **A failed call changes nothing**: the state is kept once the call worked (switches, outlets, lights, fans, valves,
  security systems, garage doors, window coverings). A lock whose call failed still goes to Unknown, as before.
- **A light keeps its brightness in the target system's scale**, whoever set it, so its readback is what the system was
  told or said (the Homebridge plugin kept HomeKit's scale after a HomeKit write).
- **A new trigger restarts an auto release** (contact, motion, occupancy), and the resting state cancels one: a
  sensor triggered again stays triggered for the whole `autoReleaseTime`.
- **A stateless switch's button is pressed by its own name only**, never the accessory's.
- **Slider writes are coalesced**: a brightness, speed, target temperature or position dragged in the Home app makes one
  call, with the last value.
- **Invalid entries are left out** with an error: a sensor of an unknown `type`, an entry without `id` or `name`, a
  second entry of the same name. Doorbell and button entries with every press flag off allow all three events.
- The per-kind accessory blocks (`HttpWebHookSwitch`…) are not supported: Homeswift runs platforms only.
- Redirects of a `GET` are followed (5 at most), as the Homebridge plugin's HTTP library did.

## Tests

`swift test --filter "HTTPWebhooksTests|TransportTests"` runs the plugin against a fake HTTP client, with the
specification's example block and requests; the server's own tests talk to it over the loopback interface, plain and
HTTPS. No network beyond the loopback, and no device.
