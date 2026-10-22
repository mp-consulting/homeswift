# Philips Ambilight TV

Philips Android TVs with Ambilight in HomeKit: power (with Wake-on-LAN), the inputs (the tuner, Home, HDMI 1
to 4, the apps the TV reports or the ones you list), the remote, volume and mute, Ambilight as a colour light,
and optional switches and sensors so scenes and automations can use the TV's state.

A port of [`homebridge-philips-ambilight-tv`](https://github.com/mp-consulting/homebridge-philips-ambilight-tv).
The platform block is the same, so a Homebridge configuration works unchanged. Each TV is published as an
accessory of its own, as Homebridge does: HomeKit allows one television per bridge, so a TV appears in the
Home app as a second accessory to add, with the same setup code as the bridge.

## Pairing

A TV has to accept the plugin once, like the Philips TV Remote app: with the web UI on, the Plugins page has
an **Open** button for this plugin whose page finds TVs on the network (or takes an address), asks the TV to
show a PIN, and turns the PIN into the TV's entry for the block, with the `username` and `password` the TV
handed out and the fingerprint of its certificate. **Add to the configuration** writes the entry into this
block (a restart follows); **Copy the entry** gives it to paste by hand. The settings page of the Homebridge
plugin produces the same keys.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "PhilipsAmbilightTV",
      "name": "Philips Ambilight TV",
      "devices": [
        {
          "name": "Living Room TV",
          "ip": "192.168.1.20",
          "mac": "AA:BB:CC:DD:EE:FF",
          "username": "2b8a0f6e5c1d4a7e",
          "password": "6f…",
          "certFingerprint": "c434…"
        }
      ]
    }
  ]
}
```

Per TV, `name`, `ip`, `mac`, `username` and `password` are required; a TV with one missing is skipped with a
line in the log. The options:

| Option | Default | What it does |
|---|---|---|
| `certFingerprint` | | SHA-256 of the TV's certificate, recorded at pairing: connections are refused when the TV presents another. Without it the first certificate seen is pinned for the run, and the log says the value to add |
| `pollingInterval` | `10000` | Milliseconds between state polls, 1000 to 60000. Once the TV's own push channel delivers, polls slow to once a minute |
| `wakeOnLanEnabled` | `true` | Send a Wake-on-LAN packet before switching on; a TV in deep standby hears nothing else |
| `ambilightMode` | `FOLLOW_VIDEO/NATURAL` | The style (and algorithm) Ambilight takes when switched on from HomeKit |
| `ambilightOnStart` | `false` | Switch Ambilight on whenever the TV comes on |
| `infoButtonKey`, `backButtonKey`, `playPauseButtonKey` | `Source`, `Back`, `PlayPause` | The TV keys the remote's Info, Back and Play/Pause buttons send |
| `inputs` | discovered | An explicit list of inputs (`name`, `type` of `app`, `source` or `channel`, `identifier`, `displayOrder`); with one, apps are not discovered |
| `customApps` | `[]` | Apps the TV does not list (`name`, `packageName`, optional `className` and `action`) |
| `sources` | `[]` | Per input, by `id`: `order` in the wheel, `visible`, `customName` |
| `sourceSwitches` | `false` | One Switch per input, for scenes and automations; exactly one is on |
| `ambilightHueSwitch` | `false` | A Switch for the TV's Ambilight+hue feature (`HueLamp/power`) |
| `customButtons` | `[]` | Momentary switches that send a key (`name`, `key`); one per key |
| `stateSensors` | `[]` | Motion sensors mirroring `power`, `ambilight` and `mute`, for automations |

## In the Home app

The television: power, the input wheel (Watch TV, Home, HDMI 1 to 4, then the apps, 30 inputs at most),
the Control Center remote (arrows, select, back, play/pause, info), volume up and down and mute through the
speaker. Inputs can be renamed and hidden in the Home app; the plugin keeps the names, the visibility and the
identifiers in its own directory, so scenes survive restarts and newly discovered apps never renumber the old.

Ambilight is a lightbulb: on switches the TV's configured style on (the TV reasserts its own default a few
seconds after waking, so the style is re-applied twice), a colour pick sends one `FOLLOW_COLOR` command for
the hue, saturation and brightness that arrive together, and brightness while Ambilight follows the picture or
the sound sets the TV's menu brightness instead of forcing a colour. Colour temperature is turned into a hue
and saturation. Adaptive Lighting is not ported.

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

Not ported: Adaptive Lighting on the Ambilight light, the ARP lookup of a MAC (the pairing page asks the TV
for it, and the TV's network settings show it), and the Homebridge settings page's source editor (the
`sources` keys are honoured; the web UI's form edits them).
