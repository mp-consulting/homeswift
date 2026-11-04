# Sonos

**Experimental**: written without Sonos hardware at hand, and not yet tested on a real household. Reports and fixes
are welcome.

Sonos zone players in HomeKit, over their local UPnP API (no cloud, no account):

- **A speaker accessory per zone** (`ZP:<player id>`, e.g. `ZP:RINCON_000E58A1B2C301400`), whose **Sonos** service
  controls the zone's *group*: play and pause (with a sleep timer from Set Duration), group volume and mute, volume,
  track and input steps, repeat, shuffle and crossfade, the current track, the group's name, whether the TV input
  carries a signal (on a Beam, Arc or Playbar), the player's last contact and a fault while it is lost.
  A Sonos Coordinator switch makes the zone the one others join.
- With `speakers`, a **Speakers** service for the zone itself: its own volume and mute, loudness, bass, treble, the
  balance (a stereo pair, a line-in), night sound and speech enhancement (home theatre), the surround and sub levels
  when the zone has them, and joining or leaving the target coordinator's group.
- With `leds`, a **LED** light per player (the LED and the button lock), on the zone's accessory and on an accessory of
  its own for a stereo pair's other player, a sub and surrounds. `heartrate` polls them instead of reading them on
  each HomeKit read.
- With `alarms`, a switch per **Sonos alarm** on its zone, with the alarm's time and what it plays.
- With `tv`, a **Television** per zone, published on its own like a second bridge (`ZP:TV_…`, `tvIdPrefix` replacing
  `RINCON`): Active is the zone's play state, the inputs are joining or leaving a group, Audio In, the TV input, the
  household's Sonos favourites and the chime; the remote's arrows change track and input.
- A **Battery** service for a portable speaker (Roam, Move).

Players are found by SSDP (one search at start, and the announcements players send) and mDNS (`_sonos._tcp`), and
remembered at their last address. Each zone is followed through UPnP (GENA) events on a small HTTP server of the
plugin's own, so nothing is polled: a player quiet for five minutes is asked once whether it is there, and one that
has not answered for ten minutes (or that the household reports as vanished) shows No Response until it is heard from
again.

## Configuration

The block of [homebridge-zp](https://github.com/ebaauw/homebridge-zp) works unchanged:

```json
{
  "platform": "ZP",
  "name": "Sonos",
  "service": "speaker",
  "brightness": true,
  "speakers": true,
  "leds": true,
  "tv": true
}
```

| Option | Default | Meaning |
|---|---|---|
| `service` | `switch` | The type of the Sonos and Speakers services: `switch` (Switch with Volume), `light` (Lightbulb with Brightness), `speaker` (Speaker with Volume) or `fan` (Fan with Rotation Speed) |
| `brightness` | `false` | The volume as Brightness rather than Volume, for `switch` and `speaker` |
| `speakers` | `false` | The Speakers service |
| `leds` | `false` | The LED lights, and the accessories of slave players |
| `heartrate` | none | Seconds (1–60) between polls of the LEDs and button locks |
| `alarms` | `false` | A switch per alarm |
| `tv` | `false` | A Television accessory per zone |
| `maxFavourites` | `96` | Input sources on each TV (16–96) |
| `tvIdPrefix` | `TV` | Replaces `RINCON` in the TVs' ids, for two bridges on one network |
| `excludeAirPlay` | `false` | No zone (nor TV) for players with AirPlay 2, which the Home app has already |
| `mdns` | `true` | Also find the players over mDNS |
| `port` | `0` | The port of the event server (0, or anything up to 1024: the system picks one) |
| `timeout` | `15` | Seconds a request to a player may take, and the wait for a subscription's first event |
| `subscriptionTimeout` | `30` | Minutes an event subscription lasts before it is renewed |
| `resetTimeout` | `500` | Milliseconds after which the Change characteristics and refused writes are put back |

As in homebridge-zp, a wrong type or an unknown value is a warning in the log and the default; numbers are clamped
to their range, and booleans take `"yes"`/`"no"`, `"on"`/`"off"` and 0/1 too. Where the original did not do what
its documentation says, this plugin does what it says: `subscriptionTimeout` sets the subscriptions' duration (the
`TIMEOUT` header is `Second-<duration + 30>`), `brightness` works for `switch` and `speaker`, `resetTimeout` is taken
in milliseconds up to a minute (the original capped an explicit value at 60 ms), players unseen for ten minutes are
marked lost, a slave's LED exposes its fault, and a new alarm's switch shows the alarm at once.

The event server listens on every interface and accepts events only from the player each event names, at that
player's address. The players must reach the bridge on `port`: give a fixed one when a firewall sits between them.
SSDP needs UDP port 1900 (shared with other listeners) and multicast; in a container, use host networking.

Setup (Add accessories, or an MCP client's `discover_devices`) lists the players found; they need no pairing.

## How it was tested

With fakes only (`Tests/`): the spec's vectors for SSDP, mDNS, device descriptions, SOAP, the topology, AVTransport
and RenderingControl events, alarms and favourites; and the plugin on a host against a fake household (a Beam with a
Sub, a One in its group, a Roam on battery), driving discovery, subscriptions and their renewal, events, group writes,
the Speakers, LED, alarm and TV services, and lost players. The event server is tested over a real local socket. Not
yet on real players: please say how it goes.

## Clean-room implementation

Compatible with the configuration of [homebridge-zp](https://github.com/ebaauw/homebridge-zp) by Erik Baauw
(Apache-2.0), and with its accessory ids, service subtypes and characteristic UUIDs, so HomeKit keeps its rooms and
automations. Written from the functional specification in
[docs/clean-room/Sonos.md](../../docs/clean-room/Sonos.md), without reading or copying its code.

## Maintainer

Mickael Palma.
