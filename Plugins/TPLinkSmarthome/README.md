# TP-Link Kasa

TP-Link Kasa "Smart Home" plugs, switches, dimmers, power strips and bulbs in HomeKit, on the local network with no
cloud and no account: found by a UDP broadcast on port 9999, controlled over TCP (or UDP) 9999 with the Kasa protocol.

**Experimental**: written and tested against fakes of the devices, not yet on hardware. Reports are welcome.

Maintainer: Mickael Palma.

## What it shows

| Device | Accessory |
|---|---|
| Plug (HS100, HS105, KP100…) | Outlet: On, Outlet In Use |
| Plug with energy monitoring (HS110, KP115, KP125…) | Outlet with the Eve energy characteristics (volts, amperes, watts, apparent power, kWh) and an Eve history; Outlet In Use from the power |
| Power strip (HS300, HS107, KP303, KP400, EP40…) | One Outlet per outlet, each with its own energy on a metering strip; no accessory for the strip itself |
| Wall switch (HS200, HS210, or any model in `switchModels`) | Switch |
| Dimmer (HS220, ES20M, KP405…) | Lightbulb with Brightness. Brightness 0 switches it off; another brightness does not switch it on |
| Bulb and light strip (KL, LB, KB) | Lightbulb with Brightness (dimmable), Color Temperature in the model's range (tunable), Hue and Saturation (colour), and the power in Eve. Tunable bulbs get Adaptive Lighting |

Each accessory's id is `TplinkSmarthome:<deviceId>` (a strip's outlet: its full child id, the strip's `deviceId` and two
digits), the Device Id of Setup and of its Accessory Settings. The serial number is the MAC and that id.

Every discovery round (each `pollingInterval`) is also the state poll: each reply updates its device in HomeKit, and
follows a device that changed address. A device that misses three rounds shows No Response until it answers again.
HomeKit's writes to a device within `waitTimeUpdate` go as one command (On, brightness and colour together).

## Configuration

```json
{
  "platforms": [
    { "platform": "TplinkSmarthome", "name": "TplinkSmarthome" }
  ]
}
```

That is enough: every Kasa device the broadcast reaches is added. The block of
[homebridge-tplink-smarthome](https://github.com/plasticrake/homebridge-tplink-smarthome) loads unchanged. Its options:

| Option | Default | What it does |
|---|---|---|
| `pollingInterval` | `10` | Seconds between discovery rounds, the state poll (1 at least) |
| `emeterPollingInterval` | `20` | Seconds between energy readings; `0` reads only when HomeKit asks |
| `addCustomCharacteristics` | `true` | The Eve energy characteristics on devices that meter |
| `inUseThreshold` | `0` | Watts above which a metering outlet is In Use |
| `switchModels` | `["HS200", "HS210"]` | Models (a part of the model name) shown as a Switch |
| `deviceTypes` | `["plug", "bulb"]` | The kinds of device to add; empty adds both |
| `macAddresses` | none | Only the devices whose MAC matches a pattern (`*`, `?`; separators ignored) |
| `excludeMacAddresses` | none | Leaves out the devices whose MAC matches a pattern |
| `devices` | none | Hosts that also get the discovery packet directly: `host` and `port` (9999; a number or a numeric string) |
| `broadcast` | `255.255.255.255` | Where the discovery broadcast goes (a subnet's broadcast address) |
| `discoveryPort` | `0` | The local UDP port discovery binds; 0 lets the system choose |
| `devicesUseDiscoveryPort` | `false` | Commands go to the port a device's discovery reply came from rather than 9999 (port forwarding) |
| `transport` | `tcp` | `tcp` or `udp` for commands; discovery is always UDP |
| `timeout` | `15` | Seconds a command may take; `0` waits as long as the TCP connection lasts (a UDP reply 15 s) |
| `waitTimeUpdate` | `100` | Milliseconds HomeKit's writes to a device are gathered for |

Each accessory's Accessory Settings sit in the block's `_accessories`, by its Device Id: the Core ones (its Name, room,
Excluded…) and `inUseThreshold`, which overrules the plugin's for that outlet. The block has nothing to move into that
shape (the MAC lists are patterns, not Device Ids) and no secrets.

## Setup

Nothing to authorize: **Add accessories** (or the MCP tool `discover_devices`) lists every device a discovery reply
named, the ones the MAC lists or `deviceTypes` leave out marked as such, and those that stopped answering as not
responding.

## Gaps

- **KLAP and Tapo.** Newer Kasa hardware revisions and firmware that speak TP-Link's authenticated KLAP protocol over
  HTTP do not answer the port-9999 discovery, so they never appear; Tapo devices neither.
- Light strip effects and segments (`lighting_effect_state`, `groups`) are not shown.
- A HomeKit read answers the last reported value; the next discovery round refreshes it (the Homebridge plugin also
  asks the device in the background on each read).
- A bulb's energy is asked for like a plug's; a bulb that answers it has no meter is not asked again.
- The energy readings stay in Eve: they are not added to the Status page's Energy section.

## How it was tested

Unit tests (`Tests/`) against a fake LAN of devices built from the spec's sysinfo examples: the cipher and framing
against the spec's vectors, every device kind becoming its accessory with its props, writes reaching the device once,
coalesced, with a strip outlet's `child_ids`, changes and new addresses reaching HomeKit, No Response after three silent
rounds, the MAC and type filters, Adaptive Lighting turned off by a colour set elsewhere, identify, energy in both
firmwares' units; the TCP transport against a loopback server that answers in several segments, and its timeout. Run
on a throwaway bridge with no devices on the network (it broadcasts, nothing answers, no crash). Not tested on
hardware.

## Clean-room implementation

Compatible with the configuration of [homebridge-tplink-smarthome](https://github.com/plasticrake/homebridge-tplink-smarthome)
and its protocol library [tplink-smarthome-api](https://github.com/plasticrake/tplink-smarthome-api) by Donald Patrick
Seal (MIT). Written from the functional specification in
[docs/clean-room/TPLinkSmarthome.md](../../docs/clean-room/TPLinkSmarthome.md), without reading or copying their code.
