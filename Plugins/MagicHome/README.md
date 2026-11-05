# Magic Home

Puts Magic Home Wi-Fi lights in HomeKit: the bulbs, LED strip controllers, ceiling and table lights and sockets sold
under Magic Home, Zengge, LEDENET and many other names, reached on the local network. No cloud, no account.

**Status: experimental.** Nobody has run it against a real Magic Home device yet: it is tested against fake devices
that speak the protocol as the [functional spec](../../docs/clean-room/MagicHome.md) describes it (see [Tests](#tests)).
Please report what works on yours, and the model and version bytes of a device it does not know (the log names them).

**Maintainer:** Mickael Palma.

## In HomeKit

Each device is one accessory with one primary service: Manufacturer MagicHome, the Wi-Fi module (`AK001-ZJ2145`) as the
model, the MAC address as the serial number.

| Model byte | Device | HomeKit |
|---|---|---|
| `04`, `06` | RGBW controllers | Lightbulb: On, Brightness, Hue, Saturation |
| `07` | RGBCW controller | Lightbulb: On, Brightness, Hue, Saturation, Color Temperature, Adaptive Lighting |
| `25` | RGB/WW/CW multi-mode controller | the same; Color Temperature only in a mode with a tunable white (its mode byte: CCT, RGBWW, RGB/CCT, or the factory default) |
| `33`, `08`, `1B`, `45`, `81` | RGB controllers | Lightbulb: On, Brightness, Hue, Saturation |
| `35` | RGBCW bulb, any firmware (version 10 and later speaks the 25-byte protocol) | Lightbulb: On, Brightness, Hue, Saturation, Color Temperature, Adaptive Lighting |
| `0E`, `1E` | RGBCW floor and ceiling lights | the same |
| `44`, `54`, `B6` | RGB/W bulbs and lights | Lightbulb: On, Brightness, Hue, Saturation (white below `colorWhiteThreshold`) |
| `09`, `1C` | CCT bulbs and table lights | Lightbulb: On, Brightness, Color Temperature, Adaptive Lighting |
| `52`, `16`, `62`, `E1`, `E2` | CCT bulbs, controllers and ceiling lights | the same |
| `21`, `41`, `65`, `17`, `1D` | Dimmable bulbs and controllers | Lightbulb: On, Brightness |
| `A1`, `A2`, `A3`-`A7`, `10`, `1A` | Addressable strips, Christmas and string lights | Lightbulb: On, Brightness, Hue, Saturation (one colour; no effects, no segments) |
| `18`, `D1` | Plant grow light, clock light | Lightbulb: On |
| `93`, `97`, `0B`, `19`, `94`-`96` | Sockets and switches | Switch: On (the first channel only) |

Color Temperature runs from 154 to 370 mireds (6500 K to 2700 K). A model byte neither table knows, and devices of
the original LEDENET protocol (`01` to `03`), are left out with a line in the log.

- **Colours** are written as the Homebridge plugin wrote them on the models it knew (section 5.2 of the spec: the value
  of the colour fixed, scaled by the brightness, HomeKit's two white swatches and the `whiteEffects` thresholds that
  light the white LEDs), and by the newer firmware's rules on the others. Hue, Saturation and Brightness of one change
  go out as one frame; a slider's drag sends its last value only.
- **Turning on**: a level change on a light that is off sends power off, as the Homebridge plugin did; Adaptive
  Lighting's white for a light that is off waits until it is on. Some firmware needs `71 23 0F` before levels; it is
  sent first there (the Homebridge plugin's rule on the version byte for its models, the family's for the others).
- **Reading**: every 30 seconds, and once after each write has settled (3 s, so a fade is not read half-way). Devices
  whose family sends its changes (the dimmable-effects controllers, sockets, CCT and addressable v3 lights) keep one
  connection open and are read every 90 seconds; the others get a connection per burst of commands, closed after
  3 seconds. A device that does not answer four times in a row shows **No Response**, is asked less and less often
  (up to every five minutes), and is logged once until it answers again.
- **Adaptive Lighting** on every light with Color Temperature. A colour, or a white other than its own, reported by the
  device (set in the Magic Home app or with a remote) turns it off.
- **Identify** flashes the light and puts it back as it was; a socket is not toggled.
- **Effects** (`effects`, off by default so accessories stay as they were): a switch per built-in pattern on the colour
  lights whose family plays them (the 8-, 9- and 25-byte families: colour loop, gradual changes, cross-fades, strobes,
  seven-colour jump, and on the dimmable-effects controllers RGB cross-fade, RGB cycle and seven-colour cycle), as
  Philips Hue's effects are. On plays the pattern at `effectSpeed` (0 to 100, sent as the delay 31 to 1), turning the
  light on first; Off on the pattern playing puts the light's colour back; a colour or brightness from HomeKit ends it.
  The switches follow what the device reports it plays (state byte 3), a pattern started in the Magic Home app included.
  CCT lights, dimmers, sockets and addressable strips get none (their patterns are numbered without names). A light's
  Accessory Settings may turn its own on or off and set its own speed.

### From Homebridge

The block is homebridge-magichome-dynamic-platform's, so it can be pasted unchanged. The Device Id is the MAC address
as discovered (12 hexadecimal digits, `ACCF23A1B2C3`), the seed the Homebridge plugin made its accessory's UUID from;
the accessory's id is `homebridge-magichome-dynamic-platform:<MAC>`. A module that reports its MAC in lowercase had a
UUID made from the lowercase text: the Device Id is uppercase here.

What changes for HomeKit:

- **`52` bulbs become CCT bulbs**: the Homebridge plugin drove them as RGBWW bulbs. They keep their Lightbulb service, lose
  Hue and Saturation and gain Color Temperature: scenes that set a colour on them need saving again.
- **`09` bulbs** take their Color Temperature (which the Homebridge plugin ignored) and no longer show the Hue and
  Saturation that appeared on them there; the RGBCW bulbs (`35`) and controllers (`07`, `25`) gain Color Temperature.
- **Addressable strips** (`A1`, `A2`) get their own frames rather than the plain levels frame.
- A device the Homebridge plugin skipped as unknown may now be added (section 10's models).
- A name containing "delete" no longer removes an accessory: Exclude it in its settings instead.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "homebridge-magichome-dynamic-platform",
      "name": "Magic Home",
      "addresses": ["192.168.2.40"],
      "whiteEffects": { "simultaniousDevicesColorWhite": true, "colorWhiteThreshold": 10,
                        "colorWhiteThresholdSimultaniousDevices": 50, "colorOffThresholdSimultaniousDevices": 5 },
      "deviceManagement": { "blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": [] },
      "advancedOptions": { "periodicDiscovery": true, "namesWithMacAddress": false, "logLevel": 3 }
    }
  ]
}
```

Every option is optional; an absent one takes the default below (the Homebridge plugin needed the four objects).

| Option | Default | |
|---|---|---|
| `addresses` | | Devices by address, for those the broadcast does not reach: each gets the discovery probe directly (new here) |
| `effects` | false | A switch per built-in pattern on the lights that play them (new here; also an Accessory Setting of each light) |
| `effectSpeed` | 50 | The patterns' speed, 0 (slowest) to 100 (fastest) (new here; also an Accessory Setting) |
| `whiteEffects.simultaniousDevicesColorWhite` | true | Controllers that drive colour and white together mix both for pale colours |
| `whiteEffects.colorWhiteThreshold` | 10 | Below this saturation a colour-or-white bulb shows white |
| `whiteEffects.colorWhiteThresholdSimultaniousDevices` | 50 | Below this saturation a colour-and-white controller mixes in white |
| `whiteEffects.colorOffThresholdSimultaniousDevices` | 5 | Below this saturation a colour-and-white controller shows white only |
| `deviceManagement.blacklistOrWhitelist` | `blacklist` | Whether `blacklistedUniqueIDs` leaves those devices out or lets only them in |
| `deviceManagement.blacklistedUniqueIDs` | | MAC addresses, compared without case |
| `pruning.pruneMissingCachedAccessories` | false | Removes a device's accessory after `restartsBeforeMissingAccessoriesPruned` launches (3) without a scan or a read hearing it |
| `pruning.pruneAllAccessoriesNextRestart` | false | Removes every accessory at the next launch, then adds what the scan finds: turn it off again |
| `advancedOptions.periodicDiscovery` | true | A scan every 30 seconds, for new devices and new addresses |
| `advancedOptions.namesWithMacAddress` | false | New devices named `Bulb A1B2C3` (`Strip`, `Switch`, `LED`) rather than by their type |
| `advancedOptions.logLevel` | 3 | 1 errors, 2 warnings, 3 information, 4 debug, 5 trace (debug and trace are written as information) |
| `advancedOptions.additionalSubnets` | | More broadcast addresses for the scan |

A `blacklist` moves into the block's `_accessories` the first time the settings are saved: each MAC becomes an Excluded
device. A `whitelist` cannot be said per device (it also leaves out the devices not found yet) and stays as it is.
There are no secrets in this plugin.

**Setup.** Every device the scan finds is added, as the Homebridge plugin did; Add accessories lists them with their
model (from `AT+LVER` when the device answers it) and address. A device on another network goes in `addresses`. One is
left out with Exclude in its settings.

## How it talks to the devices

- **Discovery**: `HF-A11ASSISTHREAD` on UDP 48899 to the broadcast address of each interface (and `additionalSubnets`,
  `addresses`), from port 48899 (older modules answer only there; any port when it is taken), then `AT+LVER\r` for the
  model and version. The socket's own probe heard back, replies from this machine's addresses and replies of fewer than
  three fields are ignored. A device is reached at the address its reply came from. A device that does not answer, or
  whose model the plugin does not know, is warned about once and not asked again at that address for five minutes. Six
  scans at most at start while none answers. What the plugin learned of each device is kept
  in its `devices.json`, so a known device is controllable at the next launch before any scan.
- **TCP 5577**: frames with an 8-bit sum checksum; the `B0 B1 B2 B3` wrapper with its counter where the family needs it;
  replies read by length across TCP segments (14-byte states with their head and checksum checked, wrapped replies,
  the extended `EA 81` reply, 4-byte power replies). One command at a time per device. The devices known at launch have
  their first polls spread over the 30 seconds, so many lights are not all read at once.

The protocol carries no credentials. Addresses and MACs are logged at debug level.

## Gaps

Choices made where the spec leaves the decision open, or where it is silent:

- The accessory id uses the platform name as its prefix (`homebridge-magichome-dynamic-platform:<MAC>`), not the spec's
  suggested `MagicHome:`: the bridge maps accessories to their Device Id, Excluded and Accessory Settings by that prefix.
- Section 1's models are driven by the Homebridge plugin's branches except where section 10 corrects them (`09`, `1C`,
  `52`, `16`, `62`, `E1`, `E2` as tunable whites; `35` from version 10; `A1`, `A2`); every other model by section 10's
  rules. Dimmers get the red-channel frame with mask `F0` (the spec's recommendation), `21` included, where flux_led
  would send `00`.
- Addressable `A1` gets the 9-byte levels frame (flux_led) rather than the Homebridge plugin's 7-byte one. Unverified on
  hardware, as is `41`'s mask.
- The Homebridge plugin's first-write "probe" frame is not sent (the same end state).
- Music mode, timers, the clock and the 2.4 GHz remote are not exposed. Multi-channel switches show their first channel
  only. Effects follow the spec's frames (10.3.8), checked against its rules only: unverified on hardware.
- An RGB/W light (`44`, `54`, `B6`) shows white below `colorWhiteThreshold`, as the Homebridge plugin's RGBW bulb did.
- A model byte in neither table is left out rather than driven as an RGB light (flux_led's choice).
- Polling (30 s, 90 s for devices that push), No Response after four unanswered queries, and the 3-second settle are the
  spec's recommendations; the Homebridge plugin had none.

## Tests

`swift test --filter MagicHomeTests` runs the plugin against fake devices on a fake LAN, with no network: every byte
vector of the spec's sections 7 and 10.8 (fixed frames, the Homebridge plugin's level branches, the hue split and HSV
maths, the state replies, discovery, the accessory id, each family's frames, the wrapper
and its counter, wrapped and extended replies, power replies, the CCT mapping), then end to end: each kind's services,
the power-first write sequence, coalesced writes and slider drags, a count of the queries over several polls, a change
on the device, No Response and recovery, Adaptive Lighting kept by its own white and turned off by a colour set
elsewhere, a wrapped device's kept connection and pushes, a device that moves, the lists and Excluded, an unknown
model not asked again, Adaptive Lighting's white held for the power-on, a whitelist removing cached accessories,
known devices at launch, pruning, Identify, Setup and the canonical settings, and the effects: their speeds and frames
per family, which lights play them, off by default, a pattern played, followed from the device and ended.

## Clean-room implementation

Compatible with the configuration of
[homebridge-magichome-dynamic-platform](https://github.com/Zacknetic/HomebridgeMagicHome-DynamicPlatform) by Zachary
Avino (Zacknetic) and contributors (Apache License 2.0). The newer firmware's protocol facts come from the spec's
description of Home Assistant's [flux_led](https://github.com/lightinglibs/flux_led) (LGPL-3.0-or-later); no code of it
was used. Written from the functional spec in [docs/clean-room/MagicHome.md](../../docs/clean-room/MagicHome.md), without
reading or copying the code of either project.
