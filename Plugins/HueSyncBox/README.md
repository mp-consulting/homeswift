# Philips Hue Sync Box

**Experimental**: written from a functional specification and tested against fakes only, not yet on a Sync Box.

The Philips Hue Play HDMI Sync Box in HomeKit, over its local HTTPS API:

- A **Lightbulb** (or a **Switch**, or nothing: `baseAccessory`) that starts syncing (`defaultOnMode`) and stops it
  (`defaultOffMode`); the Lightbulb's Brightness is the box's brightness (0 to 200 on the box, 0 to 100 in HomeKit), read
  back on each poll.
- A **power switch** (`powerSwitchAccessory`): on is passthrough, off is power save.
- Up to four **televisions**, each an accessory of its own (add it in the Home app like a bridge, with the bridge's
  setup code):
  - the HDMI inputs (`tvAccessory`);
  - the modes: video, music, game, passthrough, power save (`modeTvAccessory`);
  - the intensities: subtle, moderate, high, intense (`intensityTvAccessory`);
  - the Hue Bridge's entertainment areas (`entertainmentTvAccessory`).

  Each can have a Lightbulb of its own (its Accessory Settings' **Lightbulb**). In the Remote of Control Center, up and
  down change the brightness by 50 (of 200), left and right the intensity, Select the next mode, Play/Pause starts or
  stops syncing, and Info the next HDMI input.

The box's state is read every `updateIntervalInSeconds` (5 by default) in one request for every accessory. A write is
sent at once (one at a time: the box takes few connections), then the state is read again so the switches and inputs
that follow from it show. A drag of the brightness sends one request. When the box stops answering, the plugin says so
once and tries again with back-off; after three failed reads its accessories show No Response, those the cache kept
from the last run included. A token the box refuses (its registration deleted in the Hue Sync app) shows on Add
accessories as the account to pair again.

## Setup

On **Add accessories**, pick Philips Hue Sync Box. The plugin looks for boxes on the network (Bonjour, `_huesync._tcp`)
and offers them, or asks for the address; a box the block names already is tried there first, and asked for again,
the old address filled in, when it no longer answers. Then press and hold the button on the box until its light turns green: the
Setup sheet asks the box for a token every second for a minute. The token goes in the vault; the block gets the address
(`syncBoxIpAddress`), the box's unique ID (`syncBoxUniqueId`) and, for a new block, `uuidSeed` set to that ID.

A Homebridge block with `syncBoxApiAccessToken` works as it is: the token is a secret-named key, which the bridge seals.

The box's certificate is checked against the Hue Sync Box root certificate Philips publishes (the same in every box),
and against the box's unique ID, which its certificate names: from the first request when the block has
`syncBoxUniqueId`, and from the first state on otherwise.

## Configuration

The block of [homebridge-philips-hue-sync-box](https://github.com/jabrown93/homebridge-philips-hue-sync-box) works
unchanged; one block per box.

```json
{
  "platform": "PhilipsHueSyncBoxPlatform",
  "name": "Living Room Sync Box",
  "syncBoxIpAddress": "192.168.1.50",
  "syncBoxApiAccessToken": "<token>",
  "defaultOnMode": "lastSyncMode",
  "baseAccessory": "lightbulb",
  "powerSwitchAccessory": true,
  "tvAccessory": true,
  "tvAccessoryType": "settopbox",
  "entertainmentTvAccessory": true,
  "uuidSeed": "LivingRoom"
}
```

| Option | Default | Meaning |
|---|---|---|
| `syncBoxIpAddress` | | The box's address (Setup writes it) |
| `syncBoxApiAccessToken` | | A Homebridge block's token (Setup keeps its own in the vault) |
| `syncBoxUniqueId` | | The box's unique ID, which its certificate names (Setup writes it; learned from the box otherwise) |
| `defaultOnMode` | `video` | `video`, `music`, `game` or `lastSyncMode` (the box's last, else video) |
| `defaultOffMode` | `passthrough` | `passthrough` or `powersave` |
| `baseAccessory` | `lightbulb` | `lightbulb`, `switch` or `none` |
| `powerSwitchAccessory` | false | The power switch |
| `tvAccessory`, `modeTvAccessory`, `intensityTvAccessory`, `entertainmentTvAccessory` | false | The televisions |
| `treatPassthroughAsOffForTv` | false | The televisions show off in passthrough too, not only in power save |
| `updateIntervalInSeconds` | 5 | Seconds between reads (1 at least) |
| `uuidSeed` | | Added to every accessory's id: one per box when there are several blocks |

Each television's `<prefix>Type` (`tv`, `settopbox`, `tvstick`, `audioreceiver`), `<prefix>Lightbulb` and
`<prefix>ConfiguredName` are read as they are, and the next settings write moves them into the television's Accessory
Settings: **Icon** (`accessoryType`), **Lightbulb** (`lightbulb`) and its Name. A name given in the Home app is kept by
the bridge as the accessory's Name.

`apiServerEnabled`, `apiServerPort` and `apiServerToken` (the Homebridge plugin's own HTTP API) are not supported: the
web UI and the MCP server control the box. The plugin logs a warning when `apiServerEnabled` is on.

Accessory ids are `PhilipsHueSyncBoxPlatform:` and the Homebridge plugin's seed, the accessory's kind and `uuidSeed`
(`PhilipsHueSyncBoxPlatform:LightBulbAccessoryLivingRoom`); those seeds are the Device Ids. Device Kinds are `light`,
`switch` and `tv`. The televisions' services keep the Homebridge plugin's subtypes (`TV`, `ModeAccessory`,
`IntensityTVAccessory`, `EntertainmentTVAccessory`) and inputs (`HDMI 1`, `MODE 3`, `AREA 2`), so their numbering is the
same.

## Gaps

Choices made where the specification is silent or open (docs/clean-room/HueSyncBox.md, section 10):

- **The server name.** The box's unique ID is sent as the TLS server name (SNI) and checked against its certificate, as
  aiohuesyncbox does; the Homebridge plugin sends none. Whether every box takes that SNI is not documented.
- **The registration's status.** A refused registration is read from its body's `code` 16 with any status that is not
  2xx; a refused token from codes 1 to 3, or a 401 without a code.
- **The registration window.** Setup tries every second for 60 seconds. The registration's `instanceName` is
  `Homeswift`, its `appName` `homeswift`.
- **Entertainment areas.** They are chosen with `hue.groupId`, as the Homebridge plugin does; `execution.hueTarget`
  (Hue Bridge API v2) is not written. Areas keep the order of the box's keys; an input's Identifier is its position
  (the Homebridge plugin's last digit, which repeats from a tenth area).
- **Start-up.** A first read that fails is tried again with back-off rather than given up until a restart; the cached
  accessories stay meanwhile.
- **Not responding.** Accessories show No Response after three failed reads in a row (the Homebridge plugin never does).
- **The base Lightbulb's Brightness** is read back from the box, as the television's Lightbulb is.
- **Unknown inputs.** A Mode or Intensity TV input no mode or intensity has sends nothing (the Homebridge plugin sends an
  empty body).
- **A television's name** written from the Home app is kept by the bridge as its Name rather than in the base accessory's
  cache, and a `<prefix>ConfiguredName` in the block is its Name until a settings write moves it.
- `device.apiLevel` is not checked.

## How it was tested

Tests with fakes only (`Tests/`): the state of section 8 and its expected HomeKit values, the areas in the box's key
order, validation, the brightness conversions, the remote's keys, the writes of section 8's table end to end, one read
per cycle and one request for a brightness drag, No Response and back, the certificate's root and server name, Setup
(the button, a token sent nowhere but the vault, the block it writes), the settings move, and the client's retries and
one request at a time. `HomeswiftNetworkTests` checks `HTTPClient.TLS.authority` against a real TLS server.

## Clean-room implementation

Compatible with the configuration of
[homebridge-philips-hue-sync-box](https://github.com/jabrown93/homebridge-philips-hue-sync-box) by Jared Brown,
originally developed by Lukas Rögner (MIT). Registration and discovery follow the behaviour of
[aiohuesyncbox](https://github.com/mvdwetering/aiohuesyncbox) and the Home Assistant
[huesyncbox](https://github.com/mvdwetering/huesyncbox) integration by Michel van de Wetering (Apache-2.0). Written from
the functional specification in [docs/clean-room/HueSyncBox.md](../../docs/clean-room/HueSyncBox.md), without reading or
copying their code. The Hue Sync Box root certificate is Philips's published one (developers.meethue.com).

Maintainer: Mickael Palma.
