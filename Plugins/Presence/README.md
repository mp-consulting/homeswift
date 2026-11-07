# Presence

Who is home (GLOSSARY.md, "Presence"). Each **Person** who lives in the home is known by the devices they carry, a
phone, a watch: they are home while one of those devices is on the network, and away once none has been for the grace
period (10 minutes by default). Each Person is an occupancy sensor in HomeKit, and **Anyone Home** is one more,
occupied while at least one Person is home, so Apple Home's automations and Homeswift's can follow them.

Written for Homeswift: not a port. **Maintainer:** @mp-consulting. **Status:** experimental until it has run on more
networks than the author's.

## In HomeKit

- A Person (`Presence:person-<8 hex digits>`): an Occupancy Sensor, occupied while home. Its Serial Number is its
  Device Id: a Person has no MAC of their own.
- Anyone Home (`Presence:anyone`): an Occupancy Sensor, occupied while any Person is home. Exclude it in its Accessory
  Settings to leave it out.

On the web UI's wall they read **Home** or **Away** (Anyone Home: **Someone home**, **Nobody home**).

## Adding a Person

On **Add accessories**, the Presence card's **Add a Person…**:

1. Their name, and the web UI user they are, when the web UI has users. Linked, that user's Status page and Account
   say "You are home" or "You are away".
2. Their devices, picked from those on the network now: the ARP table, named by what the devices announce over mDNS
   (an iPhone's "Alex's iPhone") or by the host name they gave the router's DHCP. A device with a **Private address**
   made it up for this network.

**Private Wi-Fi addresses.** iOS 18 and Android give each network a private address. Set to **Rotating** (iOS) or
**Randomized each time**, it changes now and then, and the Person's device is lost. In the phone's Wi-Fi settings, open
this network and set **Private Wi-Fi Address** to **Fixed** (iPhone) or use the device's MAC (Android), then pick it.

An MCP client adds a Person the same way: `start_setup` with `{"platform": "Presence", "addByAddress": true}`, then
`continue_setup` with `name` (and `user`), then `devices`, an array of MACs.

## Configuration

```json
{
  "platforms": [
    { "platform": "Presence", "name": "Presence", "graceMinutes": 10 }
  ]
}
```

| Option | Default | What it does |
|---|---|---|
| `graceMinutes` | `10` | Minutes without any of a Person's devices before they are away (1 to 240). A phone asleep may not answer for a few minutes |
| `interval` | `30` | Seconds between checks of the network (10 to 600) |

A Person's Accessory Settings sit in the block's `_accessories`, by their Device Id: the Core ones (`name`, `room`,
`excluded`…) and the plugin's `devices` (MAC addresses) and `user` (a web UI user name):

```json
"_accessories": {
  "person-3f9a1c2b": { "name": "Alex", "devices": ["A8:5B:78:0C:11:22"], "user": "alex" }
}
```

## How it finds the devices

Every check reads the ARP table (`/proc/net/arp` on Linux, `arp -an` on macOS). A device the table lacks makes the
system resolve every address of the local networks first (one empty datagram to each, which the device answers at the
ARP level). Each address the table gives a Person's MAC is then probed with a TCP connection (62078, which iPhones keep
open, then 80 and 443): accepted or refused, the device answered. ICMP ping needs privileges the bridge does not have.
The table is read once more after the probes, so an address now handed to another device does not count.

A phone asleep may not answer for minutes: the grace period covers it, counted from the last time a device was seen.
Who is home is kept in `presence.json` in the plugin's directory, so a restart within the grace period changes nothing.

`PresenceSource` is where another source plugs in: a UniFi Network controller's clients, for instance, without the rest
of the plugin changing.

**Docker:** the ARP table is the container's own unless it runs with **host networking** (`network_mode: host`), which
the bridge needs for mDNS anyway (docs/synology.md). On a bridged network no Person is ever home.

## For the rest of the bridge

The plugin publishes who is home on the host's `PresenceBoard` (`PluginHost.presence`, `context.presence`): each Person
with their state, since when, and their web UI user; it tells its observers when a Person arrives or leaves and when
Anyone Home changes (`PresenceEvent`). The web UI's `GET /api/presence` answers the signed-in user's own Persons and
Anyone Home, never the others or their devices. Automations can take these as Triggers (a Person arriving or leaving,
Anyone Home changing); until they do, the occupancy sensors' changes work as an accessory's Trigger.

## Tests

`swift build --target PresenceTests`, then run the bundle as `Scripts/test.sh` does. The tests run on a fake source
(`FakeSource`) and a fake ARP table and probe (`FakeNetwork`), on a clock they move: no sleeps, no network.
