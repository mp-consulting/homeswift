# Philips Ambilight TV

Philips Android TVs with Ambilight in HomeKit: power (with Wake-on-LAN), the inputs (the tuner, Home, HDMI 1
to 4, the apps the TV reports or the ones you list), the remote, volume and mute, Ambilight as a colour light,
and optional switches and sensors so scenes and automations can use the TV's state.

A port of [`homebridge-philips-ambilight-tv`](https://github.com/mp-consulting/homebridge-philips-ambilight-tv).
A Homebridge configuration loads unchanged; what Homeswift writes is its canonical shape ([Configuration](#configuration)).
Each TV is published as an
accessory of its own, as Homebridge does: HomeKit allows one television per bridge, so a TV appears in the
Home app as a second accessory to add, with the same setup code as the bridge.

## Pairing

A TV has to accept the plugin once, like the Philips TV Remote app. Pairing is done on the web UI's **Add accessories**
page (Setup, docs/plugins.md), or by an AI agent through the MCP tools `discover_devices` and `start_setup`: it lists the
TVs on the network (they announce themselves only while on) and sets one up with the PIN it shows. Its `username` and
`password` and the fingerprint of its certificate go in the bridge's vault under its MAC address (from the TV's
`network/devices`, else this machine's ARP table, as the Homebridge plugin reads it; asked for when neither knows it),
and its address and settings in its Accessory Settings. The plugin reloads with it at once, no restart. A wrong PIN
says so and is asked again.

A TV Bonjour does not reach (another subnet, a container without multicast) is added by its address: an entry of the
Plugin Setting `devices` (the plugin's Settings page, or `update_settings`) with only its `name` and `ip`, and Add
accessories lists it to pair. After a reset of the TV, **Set up again** on Add accessories pairs it again; the TV keeps
its MAC address, so its place in the Home app. A Homebridge block whose `devices` hold the keys its settings page
produced works as it is.

## The web page

The page shows the TVs and controls them; pairing is Add accessories' (its card leads there), and it writes no settings.
Each TV has a card with its state and a remote, and:

- **Inputs**: the TV's inputs in the Home app's wheel order, shown then hidden, with the names the TV gives them and
  their IDs, the ones its Settings' `sources` take. **Refresh from TV** reads the TV's apps at once rather than at the
  next hourly refresh; **Detect from TV** names the app in the foreground (its package and launch activity), for
  `customApps`.
- **Settings…** opens the TV's Settings sheet on the plugin's Settings page
  (`/plugins/<slug>/settings?accessory=PhilipsAmbilightTV:<MAC>`): its Name, room, its options (address, Ambilight
  style, Wake-on-LAN, polling, the remote's keys, source switches, the Ambilight+hue switch, state sensors, inputs,
  custom apps, custom buttons, sources) and **Exclude** or **Forget**, which take it out of the Home app.

Every settings change applies at once: the plugin reloads and the TV keeps its place in the Home app.

## Configuration

What Homeswift writes (docs/adr/0001-canonical-accessory-settings.md): each paired TV's settings in `_accessories` by
its MAC address (its Device Id, uppercase as in its accessory id), its keys in the vault, and in `devices` only the TVs
to find by address.

```json
{
  "platforms": [
    {
      "platform": "PhilipsAmbilightTV",
      "name": "Philips Ambilight TV",
      "devices": [{ "name": "Bedroom TV", "ip": "10.0.20.31" }],
      "_accessories": {
        "AA:BB:CC:DD:EE:FF": { "name": "Living Room TV", "ip": "192.168.1.20", "ambilightOnStart": true, "stateSensors": ["power"] }
      }
    }
  ]
}
```

The Plugin Setting `devices` lists TVs Add accessories does not find on the network, each with its `name` and `ip`
(and `mac`, when known, for Wake-on-LAN before it is paired). Each TV's Accessory Settings (the schema's
`accessorySchema`; every TV is of the Device Kind `tv`), besides its Name and Excluded:

| Accessory Setting | Default | What it does |
|---|---|---|
| `ip` | | The TV's IPv4 address, Setup's; give it a fixed one in your router |
| `pollingInterval` | `10000` | Milliseconds between state polls, 1000 to 60000 (outside, the default with a warning). Once the TV's own push channel delivers, polls slow to once a minute |
| `wakeOnLanEnabled` | `true` | Send a Wake-on-LAN packet before switching on; a TV in deep standby hears nothing else |
| `ambilightMode` | `FOLLOW_VIDEO/NATURAL` | The style (and algorithm) Ambilight takes when switched on from HomeKit |
| `ambilightOnStart` | `false` | Switch Ambilight on whenever the TV comes on |
| `infoButtonKey`, `backButtonKey`, `playPauseButtonKey` | `Source`, `Back`, `PlayPause` | The TV keys the remote's Info, Back and Play/Pause buttons send |
| `inputs` | discovered | An explicit list of inputs (`name`, `type` of `app`, `source` or `channel`, `identifier`, `displayOrder`); with one, apps are not discovered |
| `customApps` | `[]` | Apps the TV does not list (`name`, `packageName`, optional `className` and `action`) |
| `sources` | `[]` | Per input, by `id`: `order` in the wheel, `visible`, `customName` |
| `sourceSwitches` | `false` | One Switch per input shown in the Home app, for scenes and automations; exactly one is on |
| `ambilightHueSwitch` | `false` | A Switch for the TV's Ambilight+hue feature (`HueLamp/power`) |
| `customButtons` | `[]` | Momentary switches that send a key (`name`, `key`); one per key |
| `stateSensors` | `[]` | Motion sensors mirroring `power`, `ambilight` and `mute`, for automations; they follow HomeKit's writes at once, and standby clears them |

The keys a pairing gives (`username`, `password` and `certFingerprint`, the SHA-256 of the TV's certificate: connections
are refused when the TV presents another; without it the first certificate seen is pinned for the run, and the log
says so) are in the vault under the TV's MAC.

A Homebridge block still loads: its `devices`, each TV with `name`, `ip`, `mac`, `username`, `password`,
`certFingerprint` and the options above, read where `_accessories` and the vault say nothing (a TV with something
missing is skipped with a line in the log). The first settings write (the Settings page, `update_settings`, Setup)
moves each paired TV (keys in its entry or in the vault) into `_accessories` under its MAC (`name` as the Name, the
options as they are) and its keys into the vault, and folds an entry with only an address into the TV Setup paired
there; TVs still to pair stay in `devices`, as do entries whose MAC is not one or whose keys are a reference the bridge
cannot read. The accessory keeps its id, `PhilipsAmbilightTV:<MAC>`, and its HAP server.

## In the Home app

The television: power, the input wheel (Watch TV, Home, HDMI 1 to 4, then the apps, 30 inputs at most),
the Control Center remote (arrows, select, back, play/pause, info), volume up and down and mute through the
speaker. Inputs can be renamed and hidden in the Home app; the plugin keeps the names, the visibility and the
identifiers in its own directory, so scenes survive restarts and newly discovered apps never renumber the old.

Ambilight is a lightbulb: on switches the TV's configured style on (the TV reasserts its own default a few
seconds after waking, so the style is re-applied twice), a colour pick sends one `FOLLOW_COLOR` command for
the hue, saturation and brightness that arrive together, and brightness while Ambilight follows the picture or
the sound sets the TV's menu brightness instead of forcing a colour. Colour temperature is turned into a hue
and saturation. Adaptive Lighting works on it: while Ambilight shows a colour the schedule's temperature
follows the day; while it follows the picture or the sound the schedule leaves it alone. The schedule survives
restarts (`controllers/`, as for any plugin).

A selection made while the TV is off or still booting is held and applied once the TV is up, with the TV's
own report checked, because a Philips set acknowledges a launch it is not ready for and drops it. The wheel and
the source switches are two views of one choice: a scene that sets both lands on what the switch asked for.

## How it works

JointSpace version 6 over HTTPS on port 1926 with HTTP Digest authentication, one request at a time with
100 ms between them. The configured `certFingerprint` is pinned; without one, the certificate of the first
answer is pinned for the run and the log says which value to configure. Plain HTTP on port 1925 is tried only
when nothing listens on 1926 (sets from before HTTPS), and never once HTTPS has answered or a fingerprint is
configured. A `certFingerprint` that is not a SHA-256 fingerprint skips the TV rather than accepting any
certificate. The
TV is polled at `pollingInterval` while it is off or until its `notifychange` long-poll delivers; after two
polls without an answer a TV believed on is reported off. Launches use the activity the TV reports for the
app, else `<package>.MainActivity`, refreshed from the TV when rejected; the tuner is selected by URI first,
then by the WatchTV key.

The accessory id is `PhilipsAmbilightTV:<MAC>`; its HAP state lives in `external/` next to the bridge's.
The plugin's own files (`inputs-<mac>.json`, `switch-names-<mac>.json`) are in its storage directory. The
HTTP client, Digest authentication and Wake-on-LAN are `HomeswiftNetwork`, shared with other plugins.
