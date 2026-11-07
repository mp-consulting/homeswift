# Z-Wave JS

The nodes of a Z-Wave network in HomeKit, through **zwave-js-server**: the WebSocket server that
[Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui) and Home Assistant's Z-Wave JS add-on run, on port 3000 by
default. The plugin brings in the nodes on the network and includes new ones from **Add accessories**; excluding
nodes, their configuration parameters and firmware updates stay in Z-Wave JS UI.

Written from zwave-js-server's protocol documentation (its README: `set_api_schema`, `start_listening`,
`node.set_value` and the events); no code was ported from another project. It has no Homebridge plugin to replace, so
the block has nothing to keep compatible.

**Maintainer:** the Homeswift maintainers. **Status:** experimental until someone with a Z-Wave network confirms it
works: it is tested against a fake zwave-js-server, not yet against real devices.

## Setting it up

Run zwave-js-server: on its own beside the bridge (docs/zigbee-zwave.md, which needs no Z-Wave JS UI at all), or in
Z-Wave JS UI with **Settings → Home Assistant → WS Server** turned on (the Home Assistant add-on runs it already). Then
add the Z-Wave JS plugin in the web UI, and on **Add accessories**:

**Add a Z-Wave device…** with no network connected yet asks for the server's host and port (3000 by default). A server that announces itself over mDNS
(`_zwave-js-server._tcp`, unless its discovery is turned off in those settings) is filled in: check it is yours, since
anyone on the network can announce one.

The plugin checks that the server answers and keeps its `host` and `port` in the server's Accessory Settings,
under the home id of its network, so a server whose address changes keeps its accessories: change the address in its settings (Add by address refuses
to move a network already set up elsewhere, as a server elsewhere could claim its home id). Each node
then shows as a device of its own, which can be Excluded.

```json
{
  "platforms": [
    {
      "platform": "ZWaveJS",
      "name": "Z-Wave JS",
      "_accessories": {
        "3967423180": { "host": "192.168.1.20" },
        "3967423180-3": { "showAs": "lightbulb" }
      }
    }
  ]
}
```

Several networks (several sticks) are several servers, each set up the same way.

## Adding devices

Once a network is connected, **Add a Z-Wave device…** asks which network the device joins (or another server, by its
address), starts an inclusion there for two minutes and waits while you put the device in inclusion mode (most take
three quick presses of their button). The plugin grants the security classes the device asks for; a device that
asks for S2 Authenticated or Access Control (a lock, a garage door) then needs the five-digit PIN printed on it or its
box, which Setup asks for. Setup is done once the node is added; its accessory comes when its interview is over. A
device still in another network must leave it first: exclude it there, or reset it to its factory settings.

## In HomeKit

Each node is one accessory, `ZWaveJS:<homeId>-<nodeId>`, named as in Z-Wave JS UI (else by its product), its Serial
Number the node's own (Manufacturer Specific's Device ID) or else its Device Id: Z-Wave nodes have no MAC. A node with
several endpoints (a double relay) gets a service per endpoint. The controller's own node is left out.

| Command class | In HomeKit |
|---|---|
| Binary Switch | Switch, or Outlet when the node meters energy; `showAs` picks `switch`, `outlet`, `lightbulb` or `fan` |
| Multilevel Switch | Lightbulb with Brightness; Fan with Rotation Speed for a fan controller (Fan Switch device class); Window Covering for a motor (Window Covering or Motor Control device class); `showAs` picks `lightbulb` or `fan` |
| Color Switch | Hue and Saturation on the light (red, green and blue; warm and cold white are set to 0 with a colour); Color Temperature when it has both warm and cold white, from 2700 K (all warm) to 6500 K (all cold), with Adaptive Lighting |
| Barrier Operator | Garage Door Opener: open, closed, opening, closing and stopped; Target Door State is guarded as every garage door is by the bridge's own surfaces |
| Sound Switch | A Siren switch: on plays the default tone, off stops it |
| Binary Sensor | Motion, Contact (Door/Window, Tilt), Leak (Water), Smoke, Carbon Monoxide (CO); `General Purpose` (else `Any`) is a Contact on a node with no other sensor |
| Notification | Motion (Home Security), Contact (Access Control's door state), Leak, Smoke, Carbon Monoxide and Carbon Dioxide (CO2); preferred to Binary Sensor's. Home Security's cover removed is Status Tampered on the node's sensors |
| Multilevel Sensor | Temperature (°F converted), Humidity, Light (in lux) |
| Meter | Eve's Current and Total Consumption on the switch (or a service of their own), declared as the accessory's Meter, so the Status page's Energy section counts it; energy produced counts as Returned |
| Door Lock | Lock Mechanism (secured or not, unknown, and the target), guarded as every lock is by the bridge's own surfaces; an endpoint with Door Lock is its lock whatever else it has, and an Entry Control node's switch (a door strike, a gate) is a guarded switch whatever `showAs` says |
| Thermostat Mode, Setpoint, Operating State | Thermostat: Off, Heat, Cool and Auto as the node supports them, the heating setpoint (cooling's in Cool), the air temperature |
| Battery | Battery: level and low battery |
| Central Scene | A Stateless Programmable Switch per scene: pressed once is a single press, twice a double, held down a long press |

A node reported **dead** answers No Response until it is alive again, and every node of a server does while the
server is away (the plugin reconnects with a backoff, logging the outage once). Values follow `value updated` events;
nothing is polled. A node included or removed in Z-Wave JS UI comes or goes on its own (`node added`, once it is ready,
and `node removed`), and one removed while the bridge was away leaves at the next connection.

Adaptive Lighting, once turned on in the Home app, sets the white every minute and with the brightness; a white or a colour
set elsewhere (Z-Wave JS UI, a scene on the node) turns it off, as setting one in the Home app does. Its schedule is kept
across restarts.

Not yet: a single white channel's temperature (an RGBW bulb's white is set to 0 with a colour), a fan's own speeds
(Thermostat Fan Mode), tones other than the default one, and the Notification types beyond those above.

## Settings

| Accessory Setting | For | |
|---|---|---|
| `host` | a server | Where zwave-js-server answers |
| `port` | a server | Its WebSocket port, 3000 by default |
| `showAs` | a switch | A Binary Switch as `switch`, `outlet`, `lightbulb` or `fan`; a Multilevel Switch as `lightbulb` or `fan` |

## Tests

`swift test --filter ZWaveJSTests` runs the plugin against a fake zwave-js-server (a `FakeWebSocket` from
`HomeswiftNetworkTestSupport`) that replays a `start_listening` state, `Tests/Fixtures/start_listening.json`, written in
the shape zwave-js-server's documentation gives it (a dimmable colour bulb, a metered plug, a multisensor, a lock, a
thermostat, a door sensor, a scene remote, a roller shutter, a dead leak sensor, a tunable white bulb, a fan
controller, a garage door controller, a siren, a dry contact input and a CO2 detector), and its events. No device or
server is reached.
