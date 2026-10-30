# The Matter bridge

Homeswift puts the plugins' accessories in Apple Home over HAP. The Matter bridge puts the same accessories in
Google Home, Amazon Alexa, SmartThings and Home Assistant: each accessory becomes a Matter bridged device, both
ways. A value a plugin sets reaches the Matter controllers; a command from a Matter controller writes the
characteristic as the Home app would, so plugins see no difference and need no change.

The protocol is [swift-matter](https://github.com/mp-consulting/swift-matter) (target `HomeswiftMatter`, the
`Matter` library), a package dependency from 0.2.1.

## Configuration

A system block in config.json, like the web UI's:

```json
{ "platform": "HomeswiftMatter", "port": 5540, "include": ["PhilipsHue", "Desk*"], "exclude": ["*garage*"], "exposeSecurity": false }
```

| Key | Default | What it does |
|---|---|---|
| `port` | 5540 | The UDP port Matter controllers reach the bridge on (Matter's own) |
| `include` | every accessory | Bridge only the accessories matching one of these: a plugin's platform, a plugin instance's name, an accessory id or name; `*` matches any run of characters, case is ignored |
| `exclude` | none | Accessories never bridged, matched the same way; it wins over `include` |
| `exposeSecurity` | false | Bridge locks, and what a plugin marks as a security control (a switch that opens a gate) |
| `tcp` | false | Also accept Matter over TCP on the same port, for controllers that send large messages; UDP is always on |
| `bridge` | true | Run the bridge; off, only the `devices` are on Matter |
| `devices` | none | Accessory ids that are Matter devices of their own (below) rather than bridged |

Saving the block in the web UI or over MCP applies it: a change to which accessories are on Matter (`include`,
`exclude`, `exposeSecurity`, `devices`) applies in place, and the controllers keep their sessions; a change of
`port`, `tcp` or `bridge` restarts Matter, and the fabrics stay. The passcode,
the discriminator, the device attestation keys and the fabrics are made on first start and kept under
`matter/` in the storage directory (owner-only files), never in config.json. Mirrored accessories (Wingman's Apple
Home devices) are not bridged.

## Adding the bridge to an ecosystem

Until a controller commissions it, the bridge keeps its commissioning window open, as a HAP bridge stays pairable.
The pairing code and the QR code's text are printed at start (standard output, never the log) and shown to
administrators on the web UI's Status page, in the Matter bridge card. In Google Home, Alexa, SmartThings or Home
Assistant: add a Matter device, then scan the QR code or type the 11-digit code.

To add it to another ecosystem afterwards, an administrator opens the window again: **Add to another ecosystem** on
the card, or the MCP tool `open_matter_commissioning_window` (15 minutes at most, the spec's limit). The card lists
each ecosystem (a *fabric*) with a button to remove it; `remove_matter_fabric` does the same over MCP and asks the
user first. When the last ecosystem is removed, the window opens again by itself, so the bridge can be added back
with the same code.

swift-matter is checked against connectedhomeip's own controller (Home Assistant's build): commissioning over the
network, reads, invokes and subscriptions pass. Apple Home, Google Home and Alexa have not been tried yet.

Homeswift is not a certified Matter product: it uses the test vendor ID `0xFFF1` with connectedhomeip's test
attestation credentials, as Matterbridge does. Controllers warn that the device is uncertified; Google Home needs a
developer project for the vendor and product IDs (`0xFFF1`, `0x8000`).

Do not add the Matter bridge to Apple Home too: it already has the accessories over HAP, and would show each twice.

## A device of its own

An accessory can be a Matter device by itself rather than a bridged one: a node of its own, with its own port (the
first free one after the bridge's, kept for the next start), pairing code and QR code, which Apple Home, Google
Home or Alexa add as that device, not as a bridge. An administrator turns it on from the accessory's ⋯ menu on the
Accessories page, **Make a Matter device**, which then opens the Status page at the device's Matter card with its
code; **Take off Matter** puts it back. Over MCP, `set_matter_device` does the same. It writes the accessory's id
in the block's `devices`, and makes the block if there is none, with `bridge` off so that only that accessory is on
Matter.

The switch refuses an accessory Matter has nothing for (a lock while `exposeSecurity` is off, services without a
Matter device type). The device's state lives under `matter/devices/<its id>/` and stays when it is taken off
Matter, so turning it on again finds the ecosystems that had it. Its name and whether it responds are its node's
Basic Information.

To try it: `homeswift-demo --matter-device demo-lamp` prints the lamp's own pairing code.

## What is bridged

| HAP service | Matter device type | Conversions |
|---|---|---|
| Lightbulb | On/Off, Dimmable, Color Temperature or Extended Color Light | Brightness 0–100 % ↔ CurrentLevel 1–254; mireds both sides; Hue 0–360 and Saturation 0–100 ↔ 0–254; a CIE xy color from Matter becomes hue and saturation, and a white the hue and saturation of that white on a light without Color Temperature |
| Outlet, Switch | On/Off Plug-in Unit | On ↔ OnOff |
| Switch that stands for a cleaning robot (`Service.standsFor = .cleaningRobot`) | Robotic Vacuum Cleaner | On ↔ RVC Run Mode Cleaning; Pause, Stop and GoHome turn it off; running or stopped as On says |
| Contact Sensor | Contact Sensor | HAP's 0 (contact detected) is StateValue true |
| Motion Sensor, Occupancy Sensor | Occupancy Sensor | detected ↔ occupied |
| Temperature Sensor | Temperature Sensor | °C ↔ hundredths of a degree |
| Humidity Sensor | Humidity Sensor | % ↔ hundredths of a percent |
| Light Sensor | Light Sensor | lux ↔ 10000·log10(lux) + 1 |
| Leak Sensor | Water Leak Detector | detected ↔ StateValue true |
| Window Covering | Window Covering | percent open ↔ hundredths of a percent closed; stop holds the position |
| Fan, Fanv2 | Fan | Active or On and Rotation Speed ↔ PercentSetting and FanMode |
| Thermostat | Thermostat, heating (and cooling when the target state allows it) | off/heat/cool ↔ SystemMode; the target temperature ↔ the setpoint of the mode in use |
| Lock Mechanism | Door Lock (only with `exposeSecurity`) | secured ↔ locked; locking and unlocking need a timed interaction |
| Stateless Programmable Switch | Generic Switch | single, double and long presses ↔ the Switch cluster's events |
| Air Quality Sensor | Air Quality Sensor | HAP excellent to poor ↔ Matter good to very poor |
| Smoke Sensor, Carbon Monoxide Sensor | Smoke CO Alarm | detected ↔ SmokeState or COState critical, with the alarm events |
| Valve | Water Valve | Open/Close ↔ Active; In Use ↔ CurrentState |
| Eve power and energy readings (on an outlet, a switch, a light) | + Electrical Sensor on the same endpoint | watts ↔ ActivePower in mW; kWh ↔ CumulativeEnergyImported in mWh |
| Battery (beside the others) | Power Source on the device | percent ↔ BatPercentRemaining |

An accessory with several of these services (a fan with a light, a strip of outlets) becomes one compound device,
a part per service. Its name, manufacturer, model and serial number fill Bridged Device Basic Information, and a
paused plugin's accessories show as unreachable. Televisions, cameras, heater-coolers, air purifiers and robot
vacuums are not bridged yet.

Controllers that group devices (a room's lights at once, as Home Assistant and Google Home can) send one group command:
the bridge takes group key sets, joins the groups' multicast addresses and runs the command on each member. Both counter
policies work: trust-first, and cache-and-sync, where the bridge first asks the sender for its counter (MCSP).

Each device keeps its endpoint numbers across restarts (they are stored by accessory id), and a removed
accessory's numbers are never given to another, so the ecosystems keep their rooms and automations.

## Security

- A Matter controller writes what it bridges without the confirmation the web UI and the MCP server ask before a
  lock or a security control: those stay out unless `exposeSecurity` is on.
- Only administrators see the pairing code and the QR code, open the commissioning window or remove a fabric, in
  the web UI and over MCP (`open_matter_commissioning_window` and `remove_matter_fabric` are admin-scoped,
  `remove_matter_fabric` is destructive). `get_matter_status` never gives the code out.
- The code, keys and session bodies are never logged.

## Network

Matter runs over UDP on IPv6 (and IPv4), and is found over mDNS (`_matterc._udp` while the window is open,
`_matter._tcp` for each fabric). In Docker, use host networking; on Synology and other hosts, keep IPv6 on.

## Trying it

`homeswift-demo --matter` runs the demo bridge (a lamp, a switch, a temperature sensor) over HAP and Matter at once and
prints the Matter pairing codes; the Matter node's state is kept in `~/.homeswift/homeswift-demo-matter/`, which you
delete to start over.
