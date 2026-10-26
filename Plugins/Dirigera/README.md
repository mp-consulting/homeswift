# IKEA DIRIGERA

IKEA lights, outlets, door and window sensors and scenes in HomeKit through a DIRIGERA hub's local API, without the
cloud: lights with their brightness, colour and white temperature, outlets, PARASOLL sensors with their battery, and
a switch per scene. The hub pushes its changes over a websocket, so the Home app follows the IKEA Home smart app and
the remotes at once.

Written for Homeswift (not a port); the block is [homebridge-dirigera](https://github.com/uboness/homebridge-dirigera)'s,
so a Homebridge configuration works unchanged. The wire details follow Leggin/dirigera and lpgera/dirigera (both MIT;
no code taken). Tested against a DIRIGERA hub (firmware 2.975.3, API 1.6.7): pairing, its plugs, a light driver and
PARASOLL sensors; writes, scenes and events against a fake hub in the tests. Maintained by the Homeswift authors.

![The plugin's page: devices as the Accessories page's widgets](../../docs/images/plugins/dirigera-devices.png)

## Configuration

```json
{
  "platforms": [
    { "platform": "Dirigera", "name": "IKEA DIRIGERA", "hubs": [{ "host": "192.168.1.30" }] }
  ]
}
```

A hub without a `token` pairs from the plugin's page: **Pair** (on a hub found on the network, or an address), then
press the action button under the hub within a minute. The token is kept in the plugin's folder
(`plugins/Dirigera-<name>/hubs.json`), never in config.json, with the hub's certificate pinned on first use. A token
from homebridge-dirigera in `token` works as it is.

| Option | Default | What it does |
|---|---|---|
| `hubs` | `[]` | The hubs: `host`, optional `token` and `name` (the scenes accessory is "<name> Scenes") |
| `transitionMs` | `100` | How long a light takes to reach a new level or colour; `0` changes at once |
| `scenes` | `true` | A switch for each scene of the hub (see below) |
| `excludeDevices` | `[]` | Device names or ids to leave out of HomeKit |
| `excludeScenes` | `[]` | Scene names or ids to leave out |

### Scenes

The hub's user scenes are switches on one accessory per hub: **On** triggers the scene and the switch goes back off a
second later; **Off** within 30 seconds of triggering undoes it (the hub's undo window). Wake-up and playlist scenes,
which run on their own schedule, are left out.

## The web page

With the web UI on, the plugin's page lists the hubs (their state, devices and scenes, **Pair** with a countdown, the
hubs found on the network to pair, an address to add), then three tabs: **Devices**, every light, outlet and sensor
drawn by the Accessories page's widgets; **Scenes**, a tile per scene (a tap runs it, the eye leaves it out of the Home
app); **Settings**, the transition and the scenes switch.

![Scenes](../../docs/images/plugins/dirigera-scenes.png)

## How it works

Pairing is the hub's OAuth 2 with PKCE: `GET /v1/oauth/authorize` with a S256 challenge, then `POST /v1/oauth/token`
until the button is pressed (403 before). The plugin reads `GET /v1/devices` and `GET /v1/scenes`, then follows the
websocket at `wss://<hub>:8443/v1` (`deviceStateChanged` updates a device; added and removed devices and scenes read
the hub again), reconnecting when it drops.

A light's changes of one moment go out in the order the hub wants, one `PATCH /v1/devices/<id>` each: `isOn` first when
it turns on, `lightLevel`, then `colorHue` and `colorSaturation` together or `colorTemperature` (kelvin), each with
`transitionTime`; off alone. Plugs list `lightLevel` among their attributes but only switch, so they are outlets.
A PARASOLL sensor is a contact sensor (`isOpen`) with a battery service (`batteryPercentage`, low below 10 %).
The accessory ids are `Dirigera:<device id>` and `Dirigera:scenes:<hub address>`.
