# Z-Wave JS

The nodes of a Z-Wave network in HomeKit, through **zwave-js-server**: the WebSocket server that
[Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui) and Home Assistant's Z-Wave JS add-on run, on port 3000 by
default. The plugin brings in the nodes already on the network; including and excluding nodes, their configuration
parameters and firmware updates stay in Z-Wave JS UI.

Written from zwave-js-server's protocol documentation (its README: `set_api_schema`, `start_listening`,
`node.set_value` and the events); no code was ported from another project. It has no Homebridge plugin to replace, so
the block has nothing to keep compatible.

**Maintainer:** the Homeswift maintainers. **Status:** experimental until someone with a Z-Wave network confirms it
works: it is tested against a fake zwave-js-server, not yet against real devices.

## Setting it up

In Z-Wave JS UI, turn on **Settings → Home Assistant → WS Server** (the Home Assistant add-on runs it already). Then add
the Z-Wave JS plugin in the web UI, and on **Add accessories**:

- a server that announces itself over mDNS (`_zwave-js-server._tcp`, unless its discovery is turned off in those
  settings) shows as **Z-Wave network &lt;home id&gt;**: set it up;
- otherwise, **Add by address…** asks for its host and port (3000 by default).

Either way the plugin checks that the server answers and keeps its `host` and `port` in the server's Accessory Settings,
under the home id of its network, so a server whose address changes is set up again without losing anything. Each node
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

## In HomeKit

Each node is one accessory, `ZWaveJS:<homeId>-<nodeId>`, named as in Z-Wave JS UI (else by its product), its Serial
Number the node's own (Manufacturer Specific's Device ID) or else its Device Id: Z-Wave nodes have no MAC. A node with
several endpoints (a double relay) gets a service per endpoint. The controller's own node is left out.

| Command class | In HomeKit |
|---|---|
| Binary Switch | Switch, or Outlet when the node meters energy; `showAs` picks `switch`, `outlet` or `lightbulb` |
| Multilevel Switch | Lightbulb with Brightness; Window Covering for a motor (Window Covering or Motor Control device class) |
| Color Switch | Hue and Saturation on the light (red, green and blue; warm and cold white are set to 0 with a colour) |
| Binary Sensor | Motion, Contact (Door/Window, Tilt), Leak (Water), Smoke, Carbon Monoxide (CO); `Any` and `General Purpose` are left out |
| Notification | Motion (Home Security), Contact (Access Control's door state), Leak, Smoke and Carbon Monoxide; preferred to Binary Sensor's |
| Multilevel Sensor | Temperature (°F converted), Humidity, Light (in lux) |
| Meter | Eve's Current and Total Consumption on the switch (or a service of their own), declared as the accessory's Meter, so the Status page's Energy section counts it; energy produced counts as Returned |
| Door Lock | Lock Mechanism (secured or not, unknown, and the target), guarded as every lock is by the bridge's own surfaces |
| Thermostat Mode, Setpoint, Operating State | Thermostat: Off, Heat, Cool and Auto as the node supports them, the heating setpoint (cooling's in Cool), the air temperature |
| Battery | Battery: level and low battery |
| Central Scene | A Stateless Programmable Switch per scene: pressed once is a single press, twice a double, held down a long press |

A node reported **dead** answers No Response until it is alive again, and every node of a server does while the
server is away (the plugin reconnects with a backoff, logging the outage once). Values follow `value updated` events;
nothing is polled. A node included or removed in Z-Wave JS UI comes or goes on its own (`node added`, once it is ready,
and `node removed`), and one removed while the bridge was away leaves at the next connection.

Not yet: colour temperature (warm and cold white channels), fans, sirens, garage doors, the Notification types beyond
those above, and the Binary Sensor types that say nothing of what they sense.

## Settings

| Accessory Setting | For | |
|---|---|---|
| `host` | a server | Where zwave-js-server answers |
| `port` | a server | Its WebSocket port, 3000 by default |
| `showAs` | a Binary Switch | `switch`, `outlet` or `lightbulb` |

## Tests

`swift test --filter ZWaveJSTests` runs the plugin against a fake zwave-js-server (a `FakeWebSocket` from
`HomeswiftNetworkTestSupport`) that replays a `start_listening` state, `Tests/Fixtures/start_listening.json`, written in
the shape zwave-js-server's documentation gives it (a dimmable colour bulb, a metered plug, a multisensor, a lock, a
thermostat, a door sensor, a scene remote, a roller shutter and a dead leak sensor), and its events. No device or
server is reached.
