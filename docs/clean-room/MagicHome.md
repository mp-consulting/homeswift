# Magic Home: functional specification (clean room)

## 0. Provenance

- Primary source: the Homebridge plugin `homebridge-magichome-dynamic-platform`, display name "Homebridge MagicHome Dynamic Platform", repository https://github.com/Zacknetic/HomebridgeMagicHome-DynamicPlatform.
  - **Version specified: 1.9.11**, the npm `latest` dist-tag (published 2025). Read from the published npm tarball (`dist/*.js`, `config.schema.json`, `README.md`), because the repository's `master` branch (commit `7b0db9c357e2d5cfc53b8829889a7f1e5e912e26`, 2021-11-16, package.json version 1.9.7) is older than what npm ships. The tarballs of 1.9.7 and 1.9.11 were compared; 1.9.11 differs in the colour maths (HSV instead of HSL, section 5.2), the CCT strip's write, and the discovery reply filter. Where this document says "the source" it means 1.9.11.
  - Not specified: the `2.x` alpha line (npm `alpha` tag 2.1.0-alpha.7, branch `homebridge_2`, commit `22d095c665e478d7861b3d2d7c92cd2f9a1b9b43`), which moves the protocol into separate libraries (`magichome-platform`, MIT, "Copyright (c) 2021 Zacknetic", repository https://github.com/Zacknetic/MagicHome-Platform, commit `dcd584c81831ec8721acdb7d865db14b38ee9baf`). It was only glanced at; nothing below comes from it.
  - Licence: Apache License 2.0 (full text in `LICENSE`, no NOTICE file). **No copyright line appears anywhere in the repository or the package.** The holder is the author, Zachary Avino (GitHub `Zacknetic`, "Zachary Avino ZackAvino@Zacknetic.org" in package.json `contributors`, with "Igor Ramos"). A notice should read along the lines of "homebridge-magichome-dynamic-platform, Copyright Zachary Avino (Zacknetic) and contributors, Apache-2.0".
- Second source, protocol facts only: Home Assistant's library `flux_led` (https://github.com/lightinglibs/flux_led, version 1.2.0, commit `cea6348fc6769bf41c91403289b2690089adbec2`), **LGPL-3.0-or-later**, author Daniel Hjelseth Høyer; no copyright line in the files read. Used only to confirm byte meanings (state response field names, the persistence byte, message lengths, model descriptions). Every fact taken from it is marked **[flux_led]**. Nothing was copied from it; LGPL code must not be ported, only facts used.
- Section 10 (newer devices and firmware) is based entirely on flux_led and is tagged **[flux_led]** throughout.
- Written by the spec writer; contains no source code. Everything below describes observed behaviour in my own words. Recommendations where the source is buggy or incomplete are labelled **Recommendation**; everything else describes the source. Test vectors in section 7 were computed by the spec writer from the rules in this document (floating point as in JavaScript doubles), not taken from the source.
- Nothing from the repositories was executed (no npm install, no scripts, no tests).

## 1. Scope and supported devices

A Homebridge *dynamic platform*, singular (one block). It has **no manual device list**: every device is found by UDP broadcast discovery on the local networks (section 4.1), then queried over TCP port 5577 for its type byte, which picks one of nine behaviours ("controller logic types"):

| Type byte (state response byte 1) | Logic type | Default name (`convenientName`) | Lightbulb or Switch | Colour | CCT | flux_led's description of that byte **[flux_led]** |
|---|---|---|---|---|---|---|
| `0x04` | `RGBWStrip` | `RGBW Simultaneous` | Lightbulb | yes | no | Controller RGB&W |
| `0x06` | `RGBWStrip` | `RGBW Simultaneous` | Lightbulb | yes | no | Controller RGBW |
| `0x07` | `RGBWWStrip` | `RGBWW Simultaneous` | Lightbulb | yes | no | Controller RGBCW |
| `0x09` | `CCTStrip` | `CCT Strip` | Lightbulb | no | yes | High Voltage Bulb CCT |
| `0x21` | `DimmerStrip` | `Dimmer` | Lightbulb | no | no | Bulb Dimmable |
| `0x25` | `RGBWWStrip` | `RGBWW Simultaneous` | Lightbulb | yes | no | Controller RGB/WW/CW |
| `0x33` | `GRBStrip` | `GRB Strip` | Lightbulb | yes | no | Controller RGB |
| `0x35` | `RGBWWBulb` | `RGBWW Non-Simultaneous` | Lightbulb | yes | no | Bulb RGBCW |
| `0x41` | `DimmerStrip` | `Dimmer` | Lightbulb | no | no | Controller Dimmable |
| `0x44` | `RGBWBulb` | `RGBW Non-Simultaneous` | Lightbulb | yes | no | Bulb RGBW |
| `0x52` | `RGBWWBulb` | `RGBWW Non-Simultaneous` | Lightbulb | yes | no | Bulb CCT (sic: flux_led treats `0x52` as a CCT bulb, the plugin as RGBWW) |
| `0x65` | `DimmerStrip` | `Dimmer` | Lightbulb | no | no | (not checked) |
| `0x93` | `Switch` | `Power Socket` | Switch | no | no | Switch, 1 channel |
| `0x97` | `Switch` | `Power Socket` | Switch | no | no | Socket, 1 channel |
| `0xA1` | `RGBStrip` | `RGB Strip` | Lightbulb | yes | no | Addressable v1 |
| `0xA2` | `RGBStrip` | `RGB Strip` | Lightbulb | yes | no | Addressable v2 |

Each map entry also carries the flags `simultaneousCCT` (true for `0x04`, `0x06`, `0x07`, `0x25`, `0x33`; false otherwise), `hasColor`, `hasCCT`, `hasBrightness` (false only for `0x93`/`0x97`). Only `hasColor`, `hasCCT` and `hasBrightness` change behaviour; `simultaneousCCT` is stored but never read.

Any other type byte: the device is skipped with a warning (unknown device version, file an issue). Not supported at all: the original LEDENET protocol (state query `0xEF 0x01 0x77`, mentioned in a comment only), the newer wrapped/extended protocols (bytes `0xB0..0xB3` wrapper, 25- and 27-byte states), effects/patterns, music mode, timers, addressable segments.

## 2. Configuration interface

Platform name (the `platform` value, `pluginAlias` in config.schema.json): **`homebridge-magichome-dynamic-platform`** (identical to the npm package name). `pluginType` `platform`, `singular` true. Devices are not configured; the block only holds options, in four nested objects. **No option is a secret.**

| Key path | Type | Schema default | Default when absent in the source | Meaning |
|---|---|---|---|---|
| `pruning.pruneMissingCachedAccessories` | boolean | false | (crash, see below) | Remove cached accessories not seen for N restarts. |
| `pruning.restartsBeforeMissingAccessoriesPruned` | integer | 3 | - | N for the option above. |
| `pruning.pruneAllAccessoriesNextRestart` | boolean | false | - | Remove every accessory of the plugin at the next start (README: set it back afterwards). |
| `whiteEffects.simultaniousDevicesColorWhite` (sic, misspelt) | boolean | true | - | Allow colour and white LEDs together on "simultaneous" types. |
| `whiteEffects.colorWhiteThreshold` | integer (percent saturation) | 10 | - | Below this saturation a non-simultaneous device switches from colour to white. Also used to synthesise Saturation on RGBWW reads (5.3). |
| `whiteEffects.colorWhiteThresholdSimultaniousDevices` (sic) | integer | 50 | - | Below this saturation a simultaneous device mixes colour and white. |
| `whiteEffects.colorOffThresholdSimultaniousDevices` (sic) | integer | 5 | - | Below this saturation a simultaneous device shows white only. |
| `deviceManagement.blacklistOrWhitelist` | string, `blacklist` or `whitelist` | `blacklist` | no filtering | How the list below is used. |
| `deviceManagement.blacklistedUniqueIDs` | array of strings | (items default `[]`) | no filtering | Unique IDs (the 12-hex-digit MAC the device reports, e.g. `6001940EDC1F`; exact, case-sensitive match). |
| `advancedOptions.periodicDiscovery` | boolean | **true** | **false** | Re-run discovery every 30 s. |
| `advancedOptions.namesWithMacAddress` | boolean | false | false | Name new devices "<Bulb/Strip/Switch/LED> <last 6 characters of the unique ID>" instead of the type name. |
| `advancedOptions.logLevel` | integer 1-5 | 3 | 3 | 1 errors, 2 warnings, 3 info, 4 debug, 5 trace (section 6). |
| `advancedOptions.additionalSubnets` | array of strings (broadcast addresses) | not in the schema | none | Extra broadcast addresses for discovery (read by the source, undocumented). |

Defaults when absent: the source dereferences `advancedOptions`, `pruning` and `whiteEffects` without checks. A block without `advancedOptions` throws at construction (plugin dead); without `pruning`, every cached accessory hits an error in the pruning loop (logged, accessory skipped); without `whiteEffects`, every accessory handler fails to construct (logged as "controllerLogicType does not exist") and nothing works. Homebridge's UI always writes the full objects with the schema defaults. **Recommendation:** treat every absent key as its schema default (note `periodicDiscovery` then becomes true, not the source's false).

Unknown/extra keys (`name`, `platform`, `_bridge`) are ignored. Example block (Homebridge UI shape, which a drop-in must accept unchanged):

    { "platform": "homebridge-magichome-dynamic-platform",
      "pruning": { "pruneMissingCachedAccessories": false, "restartsBeforeMissingAccessoriesPruned": 3, "pruneAllAccessoriesNextRestart": false },
      "whiteEffects": { "simultaniousDevicesColorWhite": true, "colorWhiteThreshold": 10, "colorWhiteThresholdSimultaniousDevices": 50, "colorOffThresholdSimultaniousDevices": 5 },
      "deviceManagement": { "blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": [] },
      "advancedOptions": { "periodicDiscovery": true, "namesWithMacAddress": false, "logLevel": 3 } }

Allow/deny rule (only when both `blacklistedUniqueIDs` and `blacklistOrWhitelist` are present): a device is refused when the mode string contains `blacklist` and its unique ID is in the list, or when the mode contains `whitelist` and its ID is not in the list. Otherwise allowed.

## 3. Device model and HomeKit mapping

### 3.1 Identity

- Accessory UUID = HAP-NodeJS `uuid.generate(uniqueId)`: SHA-1 of the UTF-8 unique ID string exactly as discovered (the second comma field of the discovery reply, normally 12 uppercase hex digits), lowercase hex, first 32 digits grouped 8-4-4-4-12. No platform prefix, no IP. Vectors in 7.6.
- So the identity follows the device's MAC: an IP change keeps the accessory (the README advertises this), a reset device keeps it too.
- One accessory per device, one primary service. No bridge/child structure.

### 3.2 Persisted per-accessory data (Homebridge `accessory.context.device`)

For a cache migration, the context object holds: `UUID`, `cachedIPAddress` (the IP used for TCP, updated when discovery sees a new one), `restartsSinceSeen` (integer), `displayName`, `ipAddress` (the IP at first discovery; never updated), `uniqueId`, `modelNumber` (third discovery field, e.g. `AK001-ZJ2145`), `lightParameters` (`controllerLogicType` string from the table in section 1, `convenientName`, `simultaneousCCT`, `hasColor`, `hasCCT`, `hasBrightness`), `controllerHardwareVersion` (the type byte, a number), `controllerFirmwareVersion` (state byte 10, a number), `lastKnownState` (the last decoded state, may be absent). Also `accessory.context.pendingRegistration` (boolean, transient).

A cached device is considered "valid" only if all of those root keys and the five light keys (`controllerLogicType`, `convenientName`, `simultaneousCCT`, `hasColor`, `hasBrightness`) are present and non-null, `lastKnownState` is not undefined, and `controllerLogicType` is one of the nine names. An invalid cached device that is seen during discovery is rebuilt (re-queried; keeps its old display name); one that is not seen is skipped this run ("pending update").

### 3.3 Accessory Information

- Manufacturer: `MagicHome`
- Model: `modelNumber` from discovery (e.g. `AK001-ZJ2145`, `HF-LPB100-ZJ200`).
- SerialNumber: `uniqueId`.
- Firmware/hardware revision: not set.
- Identify: handled (section 5.6). `ConfiguredName` is added as an optional characteristic on Accessory Information.
- Display name: `convenientName` from the table, or the MAC-style name (2) when `namesWithMacAddress`. The pretty name's prefix is `Bulb` if the logic type name contains "bulb" (case-insensitive), else `Strip` if it contains "strip", else `Switch` if it contains "switch", else `LED`; then a space and the last 6 characters of the unique ID (`Bulb A1B2C3`).
- No accessory category is set (Homebridge default). The service type drives the Home tile.

### 3.4 Services

**Lightbulb types** (every type except `Switch`): one `Lightbulb` service (no subtype). If a `Switch` service exists on the cached accessory it is removed first.

- `On` (get/set).
- `Brightness` (get/set), default props (0-100, step 1).
- `Hue` (get/set) and `Saturation` (set only; a get is answered from the characteristic's stored value) when `hasColor`. Default props (Hue 0-360, Saturation 0-100). So present for RGBW/RGBWW/RGB/GRB types, absent for Dimmer and CCT.
- `ColorTemperature` (get/set) when `hasCCT` (only `0x09` CCT Strip), default props (140-500 mireds).
- `ConfiguredName` (set handler) on the Lightbulb service.
- `Name` set to `displayName`.
- Note: the CCT Strip and Dimmer still receive `Hue`/`Saturation` value pushes from reads (5.3) although they have no handlers; on HAP-NodeJS `updateCharacteristic` adds the characteristic if missing, so those two types end up exposing Hue and Saturation characteristics anyway (with a warning in Homebridge's log). **Recommendation:** do not expose Hue/Saturation on Dimmer and CCT types; a drop-in loses nothing users rely on.

**Switch types** (`0x93`, `0x97`): one `Switch` service with `On` (get/set) and `ConfiguredName` (set). `Name` = displayName.

No linked services, no Adaptive Lighting.

Renaming: a write to `ConfiguredName` stores the text as `displayName` and saves the accessory cache. The new name only becomes the service `Name` at the next start. A name containing `delete` (case-insensitive) makes the accessory be removed at the next discovery run (5.1).

## 4. Protocol

### 4.1 Discovery (UDP 48899)

1. Build the list of broadcast addresses: for every non-internal IPv4 interface, the directed broadcast of its CIDR (address OR the inverted netmask), plus each string of `advancedOptions.additionalSubnets`. Duplicates are sent once.
2. Open one UDP socket with address reuse, **bound to port 48899** (the same port as the destination), broadcast enabled.
3. Send the 17 ASCII bytes `HF-A11ASSISTHREAD` (no terminator) to each broadcast address, port 48899.
4. Collect replies for the scan timeout (2000 ms in this plugin), then close.
5. Each reply is ASCII text split on `,`: field 0 IP address, field 1 unique ID (MAC as 12 hex digits), field 2 model string. Example `192.168.1.50,ACCF23A1B2C3,AK001-ZJ2145`. Replies with more than 4 fields are ignored; duplicates (same unique ID) are ignored after the first. **[flux_led]** confirms the format and that replies may end with CR/LF.

Quirk: because the socket is bound to 48899 and broadcasts on it, it also receives its own `HF-A11ASSISTHREAD` datagram, which splits to one field and is recorded as a device without unique ID or model; it then fails later (an exception caught and logged at debug). **Recommendation:** ignore replies with fewer than 3 fields, strip CR/LF, ignore replies whose source address is one of the host's own, and take the IP from field 0 (or the datagram's source).

A scan run: scan once; while zero devices were found, rescan, up to 5 more times (at most 6 scans, ~12 s).

Other UDP commands on this port (`AT+LVER\r` firmware query etc. **[flux_led]**) are not used.

### 4.2 TCP transport (port 5577)

- One TCP connection **per command**: connect to `cachedIPAddress:5577`, write the frame, wait for the first chunk of data or a timeout, then end and destroy the socket. Commands to one device are serialised through a queue (one in flight; unbounded length).
- The connect wait is fixed at 200 ms; on timeout it does *not* fail, the write is queued on the still-connecting socket and the read wait starts. A socket error (refused, unreachable) aborts the command silently (it returns "no data").
- The read wait returns the **first `data` chunk only** (no reassembly), or "no data" after the timeout: 1000 ms for state reads during operation, 10 000 ms for the type query at discovery, 200 ms (default) after writes.
- Every frame sent gets a checksum byte appended: the low 8 bits of the sum of all preceding bytes. (The source has a "no checksum" flag but it is never honoured: all frames carry a checksum.)

**Recommendation:** keep one command at a time per device, but connect with a real timeout (about 2 s), and read until the expected length is reached (14 bytes for a state response) rather than taking the first chunk. A persistent connection works with these devices too **[flux_led]** (it keeps one open), but a per-command connection is what this plugin does and is the safest drop-in.

### 4.3 Frames

All values are bytes, written in hex; `cs` is the checksum (4.2). Byte 0 `0x31` means "persist" **[flux_led: `0x41` is the non-persisting variant]**; the plugin always uses `0x31`. The trailing `0x0F` before the checksum is a fixed terminator ("remote/local" byte in other sources).

| Purpose | Bytes before the checksum | Used by |
|---|---|---|
| State query | `81 8A 8B` | all |
| Power on | `71 23 0F` | all |
| Power off | `71 24 0F` | all |
| Levels, 7-byte body ("8-byte protocol" in flux_led) | `31 R G B W M 0F` | RGBStrip, GRBStrip, RGBWBulb, RGBWStrip, DimmerStrip |
| Levels, 8-byte body (9 bytes on the wire) | `31 R G B WW CW M 0F` | RGBWWStrip, RGBWWBulb, CCTStrip, and the one-time probe below |
| CCT level | `35 B1 X Y 00 00 00 03` | CCTStrip (second frame) |

M is the write mask: `F0` colours only, `0F` whites only, `FF` (or `00` **[flux_led: `00` means "all"]**) both. In the 7-byte form flux_led documents byte 5 as the mask for non-simultaneous devices and `00` for others **[flux_led]**; the plugin sends `F0`, `0F` or `FF` as given in 5.2.

The "8-byte probe": RGBStrip, GRBStrip, RGBWBulb and RGBWStrip start in an "unknown" mode. On their **first** colour write after the handler is created, they send the 8-byte-body form `31 R G B W 00 M 0F cs` (with the 7-byte form's W in the warm-white position and `00` as cold white) and then, unconditionally, the 7-byte form `31 R G B W M 0F cs`. The intent was to keep the 8-byte form if the device answered, but the source's send helper never returns the reply, so the mode always becomes "7-byte" after that first write. Net behaviour: the very first colour write per handler sends both frames, every later one sends only the 7-byte form. **Recommendation:** send only the 7-byte form for these types (identical end state, one frame fewer).

Responses to writes are read (200 ms) and discarded. **[flux_led]**: a power command is answered by a 4-byte power-state message whose first two bytes are one of `F0 71`, `0F 71`, `00 71`, `01 71`, then `23`/`24`, then a checksum that "does not always match"; level writes are usually unanswered.

### 4.4 State response (14 bytes)

Reply to `81 8A 8B 96`. Byte positions, with what the plugin reads and **[flux_led]** names for the rest:

| Byte | Meaning | Read by the plugin as |
|---|---|---|
| 0 | `0x81`, message head | not checked |
| 1 | device type ("model number") | `controllerHardwareVersion`, picks the logic type (table 1) |
| 2 | power: `0x23` on, `0x24` off | `isOn` = (byte == `0x23`); anything else is off |
| 3 | preset pattern / mode **[flux_led]** (`0x61` static colour, `0x62` music, `0x60` custom, `0x25`-`0x38` built-in effects) | ignored |
| 4 | LED wiring mode **[flux_led]** | ignored |
| 5 | effect speed (`0x01` fastest .. `0x1F` slowest) **[flux_led]** | ignored |
| 6 | red 0-255 | `RGB.red` |
| 7 | green 0-255 | `RGB.green` |
| 8 | blue 0-255 | `RGB.blue` |
| 9 | warm white 0-255 | `whiteValues.warmWhite` |
| 10 | firmware/version number | `controllerFirmwareVersion` |
| 11 | cool white 0-255 | `whiteValues.coldWhite` |
| 12 | colour mode: `F0` colours were set, `0F` whites, `00` both **[flux_led]** | ignored |
| 13 | checksum of bytes 0-12 | not verified |

The parser only needs bytes 1-11 to exist; a shorter first chunk makes the read fail (logged at debug, treated as "no data"). No head or checksum check. **Recommendation:** require length 14, head `0x81` and a correct checksum **[flux_led does all three]**, and buffer until 14 bytes arrive.

Bytes 1 and 10 are captured at discovery and stored; the type byte is never re-read afterwards (a cached device keeps its first classification).

## 5. Behaviour

### 5.1 Start-up, discovery runs and registration

At start (after Homebridge restores the cache) one discovery run; with `periodicDiscovery` one more every 30 000 ms. Cached accessories have `restartsSinceSeen` incremented by one at load time (so once per process start, not per periodic run) and are flagged pending registration.

A discovery run:

1. Scan (4.1).
2. For each discovered device (`uniqueId`, `ipAddress`, `modelNumber`):
   - UUID from `uniqueId` (3.1).
   - **New** (no cached accessory with that UUID): query its state (state query, up to 5 attempts of 10 s each; the first non-empty reply wins). No reply: warning (device unresponsive, make sure it works in the "Magichome Pro" app; a special text for model `000-0000`, "unsupported") and skip. Unknown type byte: warning, skip. Refused by the allow/deny rule: warning, skip. Otherwise create the accessory with the display name (3.3), `restartsSinceSeen` 0, `cachedIPAddress` = discovered IP, register it, create its handler. (The creation is not awaited in the source, so the summary counts are approximate.)
   - **Cached**: if its stored data is invalid (3.2), rebuild it (two state queries, the initial one and the type query; on failure an error is logged and the device skipped). Then: refused by the allow/deny rule → unregistered (warning), skip. Else set `restartsSinceSeen` = 0; if the cached IP differs from the discovered one, log a warning with both and replace `cachedIPAddress`. If its registration already completed in this process and the IP is unchanged, nothing more (debug "already registered"). Otherwise create its handler (with the possibly new IP) and save the cache.
3. Then for every accessory in the cache list, in order:
   - invalid data → "pending update", skip;
   - `displayName` contains `delete` (case-insensitive) → unregister, warning "pruned ... marked for deletion";
   - else if `pruneMissingCachedAccessories` or `pruneAllAccessoriesNextRestart`: if `restartsSinceSeen` ≥ `restartsBeforeMissingAccessoriesPruned`, or prune-all is set → unregister, warning with the count;
   - else if `restartsSinceSeen` > 0 (not seen since this start): refused by allow/deny → unregister (warning); otherwise create its handler on its cached IP anyway (debug "continuing to register cached accessory despite not being seen") so it stays controllable.
4. Debug summary: registered, new, cached seen, cached unseen.

Quirks: with prune-all, the accessories found as new or cached in step 2 are also unregistered in step 3 (they are in the same list), so a prune-all start leaves nothing until the next start re-adds them. In periodic runs, an unseen cached accessory gets a fresh handler every 30 s (step 3 last branch) and a renamed-to-"delete" accessory is pruned within 30 s. **Recommendation:** in Homeswift, map "not seen" pruning and prune-all onto the bridge's own cache removal; do not recreate handlers on every periodic run; keep the "delete" rename rule only if compatibility is wanted (it is a documented user feature).

### 5.2 Writes (HomeKit to device)

Each handler keeps a local light state: `HSV` {hue 0-360, saturation 0-100, value 0-100}, `RGB`, `whiteValues` {warmWhite, coldWhite}, `isOn`, `brightness` (0-100), `CCT` (mireds). Initial values before any read: hue 255, saturation 100, value 100, RGB 0/0/0, whites 0/0, on = true, brightness 100, CCT 0.

Characteristic writes are acknowledged immediately (never an error) and only update the local state:
- `On` → `isOn`.
- `Hue` → `HSV.hue`, marks a colour command, clears the "colour temperature mode" flag.
- `Saturation` → `HSV.saturation`, colour command, clears the flag.
- `Brightness` → `brightness`, colour command.
- `ColorTemperature` → `CCT`, colour command, sets the flag.

Then a coalescing step: if no flush is pending, one is scheduled **20 ms** later; writes arriving within that window only change the local state. The flush:

1. If no colour command is pending, or the state says off: send power on or off according to `isOn` (so a Brightness write while off sends power **off**, and a Hue write with On=false in the same batch sends only power off).
2. Otherwise (colour command and on): if the stored firmware byte (state byte 10) is 2, 3, 4 or 5, or is 8, or is 1 and the model string contains `HF-LPB100-ZJ200`, first send power on. Then, **100 ms** later (asynchronously), send the level frame(s) for the logic type (below).
3. Clear the colour-command flag and the pending flag (this happens right after step 1 or the power-on of step 2, before the delayed level frames go out).

There is no read-back after a write; HomeKit is not updated by the plugin after writes.

Colour conversion used by every colour type ("HSV to RGB"): standard HSV-to-RGB with **value fixed at 1** (the stored value/brightness is ignored at this step): h' = hue/360 × 6, sector i = floor(h'), f = h' − i, p = 1 − s, q = 1 − f·s, t = 1 − (1 − f)·s with s = saturation/100; sector 0 → (1, t, p), 1 → (q, 1, p), 2 → (p, 1, t), 3 → (p, q, 1), 4 → (t, p, 1), 5 → (1, p, q) (sector taken modulo 6, so hue 360 = sector 0); each channel × 255, rounded half up. Then scaled: channel byte = round(clamp(channel, 0, 255) / 100 × brightness) (JavaScript rounding of the double, so 255/100 × 50 gives 127, not 128; see 7.2).

White split from hue ("hue to white temperature"), used by RGBWW and CCT types, sets `whiteValues`:
- hue ≤ 90: warm 255, cold = round(255 × hue/90);
- 90 < hue ≤ 180: cold 255, warm = round(255 × (1 − (hue − 90)/90));
- 180 < hue ≤ 270: cold 255, warm = round(255 × (hue − 180)/90);
- hue > 270: warm 255, cold = round(255 × (1 − (hue − 270)/90)).
So red (0/360) is warm only, cyan (180) cold only, 90 and 270 both full.

"White presets": the exact (hue, saturation) pairs (31, 33) and (208, 17) are HomeKit's default warm-white and cool-white swatches; the comparisons are exact equality on the numbers received.

Let T1 = `colorWhiteThreshold`, Tmix = `colorWhiteThresholdSimultaniousDevices`, Toff = `colorOffThresholdSimultaniousDevices`, SIM = `simultaniousDevicesColorWhite`, br = brightness, (r, g, b) the scaled colour bytes, W = round(255/100 × br).

Per logic type:

- **RGBStrip** (`0xA1`, `0xA2`) and **GRBStrip** (`0x33`): 7-byte levels `31 r g b 00 F0 0F` (with the first-write probe, 4.3). GRBStrip does **not** reorder channels despite its name.
- **RGBWBulb** (`0x44`): if saturation < T1, or (hue, sat) is (31, 33) or (208, 17) or (0, 0): white only, `31 00 00 00 W 0F 0F`. Else colour only, `31 r g b 00 F0 0F`. (With probe.)
- **RGBWStrip** (`0x04`, `0x06`): mask always `FF`. If (31, 33), (208, 17), (0, 0) or saturation < Toff: `31 00 00 00 W FF 0F`. Else if saturation < Tmix and SIM: the colour recomputed at saturation 100 and **not scaled by brightness** (full-intensity hue) plus W: `31 R100 G100 B100 W FF 0F`. Else `31 r g b 00 FF 0F`. (With probe.)
- **RGBWWStrip** (`0x07`, `0x25`): whites from the hue split, scaled: ww = round(clamp(warm, 0, 255)/100 × br), cw likewise. If (31, 33): `31 00 00 00 W 00 0F 0F`. Else if (208, 17): `31 00 00 00 00 W 0F 0F`. Else if saturation < Toff: `31 00 00 00 ww cw FF 0F`. Else if saturation < Tmix and SIM: full-saturation unscaled colour plus scaled whites, `31 R100 G100 B100 ww cw FF 0F`. Else `31 r g b 00 00 FF 0F`.
- **RGBWWBulb** (`0x35`, `0x52`): same white split. (31, 33): `31 00 00 00 W 00 0F 0F`. (208, 17): `31 00 00 00 00 W 0F 0F`. saturation < T1: `31 00 00 00 ww cw 0F 0F`. Else `31 r g b 00 00 F0 0F`.
- **CCTStrip** (`0x09`): whites from the hue split (the stored hue, which for this type only ever comes from reads, since it has no Hue handler), each clamped to **127** then scaled: x = round(min(warm, 127)/100 × br), y likewise from cold. Two frames: `31 00 00 00 x y FF 0F` then `35 B1 x y 00 00 00 03`. The `ColorTemperature` value is stored but **does not affect what is sent** (a source bug; an unused mireds-to-white formula exists, see 9). **[flux_led]** interprets `35 B1` differently: byte 2 is the colour temperature as 0-100 (0 warm, 100 cool) and byte 3 the brightness 0-100.
- **DimmerStrip** (`0x21`, `0x41`, `0x65`): the source defines a dimmer-specific write but never calls it, so the generic colour write runs: `31 r g b 00 F0 0F` from the stored hue/saturation and brightness. For a dimmer whose last read was red-only (normal for a dimmer: its level is in byte 6) the stored hue is 0 and saturation 100, so this sends `31 L 00 00 00 F0 0F` with L = round(255/100 × br), which works. Before any successful read, the initial hue 255 makes it send red 64×br/100, blue 255×br/100. The intended dimmer frame was `31 L 00 00 03 01 0F` with L = round(2.55 × br). **Recommendation:** for dimmers send the red channel only, L = round(2.55 × brightness), mask `F0` (equivalent to what works today).
- **Switch** (`0x93`, `0x97`): only power frames.

### 5.3 Reads (device to HomeKit)

There is **no polling timer**. A state read ("refresh") is started:
- once when a handler is created;
- on every HomeKit GET of `On` and `Brightness`, and of `Hue` (only when not in colour-temperature mode) and `ColorTemperature` (only when in colour-temperature mode).

The GET itself is answered immediately from the local state (never an error, never "No Response"): `On` → `isOn`, `Brightness` → `brightness`, `Hue` → `HSV.hue`, `ColorTemperature` → `CCT`. The refresh runs in the background and pushes values when it completes.

A refresh is skipped when a write flush is pending or another refresh is running. It makes up to 6 attempts of the state query (1000 ms read timeout each, new connection each). If all fail: debug "no response from device", nothing pushed (HomeKit keeps showing the last values; an offline device never shows "No Response"). On success: store the decoded state as `lastKnownState`; `RGB` and `whiteValues` from the reply; `HSV` from RGB ("RGB to HSV": max and min of the three bytes, d = max − min; saturation = d/max × 100 (0 when max is 0); value = max/255 × 100; hue = 0 when max = min, else by the max channel: red → ((g − b) + d × (6 if g < b else 0)) / (6d), green → ((b − r) + 2d)/(6d), blue → ((r − g) + 4d)/(6d), times 360; unrounded floats); `isOn` from byte 2. Then push per type:

- **Generic** (RGBStrip, GRBStrip): On, Hue, Saturation; if value > 0 and on, `brightness` := value; Brightness := `brightness`.
- **RGBWBulb, RGBWStrip**: On, Hue, Saturation; if value > 0 and on: Brightness := value; else if on: Brightness := clamp(warm/2.55, 0, 100). (The local `brightness` is not updated.)
- **RGBWWStrip, RGBWWBulb**: On, Hue, Saturation; if value > 0 and on: Brightness := value; else if on (white mode, RGB all 0): Brightness := clamp(cold/2.55 + warm/2.55, 0, 100), and if warm > cold: Saturation := T1 − T1 × cold/255 and Hue := 0, else Saturation := T1 − T1 × warm/255 and Hue := 180. (This synthesises a near-white point on the colour wheel for HomeKit.)
- **CCTStrip**: On, Hue, Saturation (from RGB, normally 0/0); if on, Brightness := clamp(cold/1.27 + warm/1.27, 0, 100).
- **DimmerStrip**: `brightness` := red/2.55; On; if on, Brightness := `brightness`.
- **Switch**: On.

Values are pushed as unrounded floats (HAP-NodeJS rounds to the characteristic's step). While off, Brightness is not pushed (it keeps its last value). Because the read replaces `HSV` with the value decoded from the device's scaled RGB, the hue/saturation of a dimmed colour read back as the same hue at full value, and brightness as the value: the round trip is consistent for pure colours.

**Recommendation:** add a periodic refresh (for example every 10-30 s and after each write, one in flight per device), mark the accessory unreachable after the 6 failed attempts instead of silently keeping stale values, and round pushed values to integers.

### 5.4 Timing summary

| What | Value |
|---|---|
| Discovery scan window | 2000 ms, up to 6 scans while nothing is found |
| Periodic discovery | every 30 000 ms (when enabled) |
| Type query at discovery | up to 5 attempts, 10 000 ms read timeout each |
| Refresh | up to 6 attempts, 1000 ms read timeout each |
| TCP connect wait | 200 ms (not enforced as a failure) |
| Read after a write | 200 ms, reply discarded |
| Write coalescing window | 20 ms |
| Power-on to level frame | 100 ms |
| Identify flash | 20 ticks of 300 ms |

### 5.5 Errors and edge cases

- Command failures are never reported to HomeKit; writes always succeed from HomeKit's view.
- Unknown type byte: never becomes an accessory.
- A cached accessory whose `controllerLogicType` is not one of the nine: error logged, not handled.
- Characteristic handlers are replaced (all listeners removed first) each time a handler is created, so re-registration does not stack handlers.
- The shared type table entry's `convenientName` is overwritten in place when `namesWithMacAddress` is on (the source mutates the table), which can leak one device's MAC name into another device's rebuild fallback. Harmless for a fresh implementation that copies the entry.

### 5.6 Identify

Writing Identify starts a flash: hue 100, saturation 100; then every 300 ms brightness alternates 0 and 100 (starting with 0) and the type's level frame(s) are sent (no power command); after the 20th tick, hue 0, saturation 5, brightness 100 is sent and the flash stops. The local state is left at hue 0, saturation 5, brightness 100 (the user's colour is not restored). The source's identify handler never completes the HomeKit request (no callback), so the Identify write times out on the controller side. **Recommendation:** acknowledge Identify immediately, run the flash, then restore the previous state.

## 6. Logging

Levels: the plugin's own filter on top of Homebridge's logger. Level 1 shows errors, 2 adds warnings, 3 (default) adds info, 4 adds debug, 5 adds trace; info, debug and trace lines are all written at Homebridge's info level once enabled.

Paraphrased lines:
- Warning: plugin initialised with its version (logged at warning level at every start); unknown device version byte (with the hex) and a request to file a GitHub issue; discovered device did not respond (with the device data; special text for unsupported model `000-0000`); new device blacklisted / not whitelisted (unique ID); accessory pruned because blacklisted, marked "delete", or unseen for N restarts; IP address discrepancy (expected vs discovered) and reassignment.
- Info: "consider giving the project a star" at start; "<n> - Registering new accessory...! [ <name> ]" and "Registering existing accessory: [ <name> ]"; "Identifying accessory <name>".
- Error: device type could not be determined during a cache rebuild; rebuild failed; logic type not in the accessory table (with the whole device object); pruning loop exceptions (with the context object); refresh exceptions; transport errors without an error code.
- Debug: each discovery reply (raw buffer, unique ID, IP, model, running count), each broadcast address scanned, rescans, counts, per-device controller assignment (type and version bytes in hex), the device details on registration (logic type, model, unique ID, IP, type and "firmware" bytes; the source prints the type byte twice by mistake), every characteristic GET with its value, rename, no-response from a device, replies to commands.

Sensitive data: none in the protocol (no credentials). Logs contain IP addresses, MAC-based unique IDs and model strings. **Recommendation:** keep IPs and IDs at debug level; do not dump whole context objects.

## 7. Test vectors

All frames are hex bytes on the wire, checksum last. Values computed by the spec writer from sections 4 and 5.

### 7.1 Fixed frames

| Frame | Bytes |
|---|---|
| State query | `81 8A 8B 96` |
| Power on | `71 23 0F A3` |
| Power off | `71 24 0F A4` |

### 7.2 Level frames

| Type, HomeKit state (hue, saturation, brightness), default thresholds (T1 10, Tmix 50, Toff 5, SIM true) | Frame(s) |
|---|---|
| RGBStrip, (120, 100, 50), first write after the handler is created | `31 00 7F 00 00 00 F0 0F AF` then `31 00 7F 00 00 F0 0F AF` (green 255 × 50/100 = 127.4999… → 127) |
| RGBStrip, same state, later write | `31 00 7F 00 00 F0 0F AF` |
| RGBWBulb, (any, 5, 80): white | `31 00 00 00 CC 0F 0F 1B` |
| RGBWBulb, (240, 60, 100): colour (102, 102, 255) | `31 66 66 FF 00 F0 0F FB` |
| RGBWStrip, (0, 30, 40): mix, full red plus W = 102 | `31 FF 00 00 66 FF 0F A4` |
| RGBWWStrip, (0, 100, 100): colour | `31 FF 00 00 00 00 FF 0F 3E` |
| RGBWWStrip, (31, 33, 60): warm preset, W = 153 | `31 00 00 00 99 00 0F 0F E8` |
| RGBWWStrip, (208, 17, 60): cool preset | `31 00 00 00 00 99 0F 0F E8` |
| RGBWWStrip, (200, 30, 50): mix; colour at sat 100 = (0, 170, 255); hue split warm 57, cold 255 → scaled 28, 127 | `31 00 AA FF 1C 7F FF 0F 83` |
| RGBWWStrip, (200, 3, 50): white only | `31 00 00 00 1C 7F FF 0F DA` |
| RGBWWBulb, (45, 5, 100): white; hue split warm 255, cold 128 | `31 00 00 00 FF 80 0F 0F CE` |
| CCTStrip, stored hue 0, brightness 50: warm min(255,127) → 64, cold 0 | `31 00 00 00 40 00 FF 0F 7F` then `35 B1 40 00 00 00 00 03 29` |
| CCTStrip, stored hue 135, brightness 100: warm 128 → 127, cold 255 → 127 | `31 00 00 00 7F 7F FF 0F 3D` then `35 B1 7F 7F 00 00 00 03 E7` |
| DimmerStrip, last read red-only, brightness 75 | `31 BF 00 00 00 F0 0F EF` |

Write sequence example (RGBWWStrip, firmware byte 5, model `AK001-ZJ2145`; HomeKit writes Hue 0, Saturation 100, Brightness 100 within 20 ms while on): 20 ms after the first write `71 23 0F A3` (firmware 5 is in 2..5), then ~100 ms later `31 FF 00 00 00 00 FF 0F 3E`. Each on its own TCP connection. Same with firmware byte 6: only the level frame.

### 7.3 Hue split (hue → warm, cold)

0 → 255, 0; 45 → 255, 128; 90 → 255, 255; 135 → 128, 255; 180 → 0, 255; 225 → 128, 255; 270 → 255, 255; 315 → 255, 128; 360 → 255, 0.

HSV to RGB at value 1 (hue, sat → r, g, b): (0, 100) → 255, 0, 0; (30, 100) → 255, 128, 0; (100, 100) → 85, 255, 0; (240, 50) → 128, 128, 255; (255, 100) → 64, 0, 255 (the initial state); (359, 100) → 255, 0, 4.

### 7.4 State responses (invented devices)

1. `81 25 23 61 01 10 FF 80 00 00 05 00 F0 AF`: type `0x25` → RGBWWStrip; on; RGB 255, 128, 0; warm 0; firmware 5; cold 0. HSV = hue 30.1176…, saturation 100, value 100. Pushed: On true, Hue 30.12, Saturation 100, Brightness 100.
2. `81 35 23 61 01 10 00 00 00 C0 08 40 0F 62`: type `0x35` → RGBWWBulb; on; RGB 0; warm 192; firmware 8; cold 64. Value 0 → white path: Brightness = clamp(64/2.55 + 192/2.55) = 100.39 → 100; warm > cold → Hue 0, Saturation = 10 − 10 × 64/255 = 7.49 (T1 = 10).
3. `81 44 24 61 01 10 00 00 FF 00 04 00 F0 4E`: type `0x44` → RGBWBulb; **off** (`0x24`); blue 255; firmware 4. Pushed: On false, Hue 240, Saturation 100; Brightness not pushed (off).
4. `81 97 23 61 41 10 00 00 00 00 01 00 00 EE`: type `0x97` → Switch "Power Socket"; on. Pushed: On true.
5. A Dimmer `0x21` with byte 6 = `0x80`: Brightness = 128/2.55 = 50.196 → 50.

### 7.5 Discovery

Sent: the ASCII bytes of `HF-A11ASSISTHREAD` (`48 46 2D 41 31 31 41 53 53 49 53 54 48 52 45 41 44`) to each broadcast address, UDP port 48899, from local port 48899.
Reply: `192.168.1.50,ACCF23A1B2C3,AK001-ZJ2145` → IP 192.168.1.50, unique ID `ACCF23A1B2C3`, model `AK001-ZJ2145`. A reply `HF-A11ASSISTHREAD` (own echo) must be ignored.

### 7.6 Identity and names

| Unique ID | Accessory UUID |
|---|---|
| `ACCF23A1B2C3` | `90f6f8b9-3d5d-f625-9c68-0e82779f3f9f` |
| `6001940EDC1F` | `4cb4622f-7322-6e03-b334-f7a135a4ca57` |

`namesWithMacAddress` with `ACCF23A1B2C3`: RGBWWBulb → `Bulb A1B2C3`, RGBWWStrip → `Strip A1B2C3`, Switch → `Switch A1B2C3`.

### 7.7 Behaviour checks worth testing

- Type byte → service, characteristics and name per table 1; an unknown byte creates nothing.
- Allow/deny: blacklist with the ID → refused; whitelist without the ID → refused; either key absent → allowed.
- Coalescing: Hue, Saturation and Brightness written within 20 ms produce one power-on (when the firmware rule applies) and one level frame.
- Brightness written while off sends power off only.
- GETs answer from the local state at once and trigger a refresh; a refresh with no reply changes nothing.
- IP change on rediscovery updates the target address without changing the UUID.
- A display name containing "delete" removes the accessory at the next discovery run.

## 8. What a drop-in must reproduce exactly

- Platform name `homebridge-magichome-dynamic-platform` and the option names of section 2, including the misspellings (`simultaniousDevicesColorWhite`, `colorWhiteThresholdSimultaniousDevices`, `colorOffThresholdSimultaniousDevices`) and `blacklistedUniqueIDs`, `blacklistOrWhitelist` with values `blacklist` / `whitelist`, plus the unlisted `advancedOptions.additionalSubnets`.
- The UUID seed: the bare unique ID string from discovery (3.1). With Homeswift's own id scheme (platform-prefixed ids), the migration must map an existing Homebridge accessory whose UUID is `uuid.generate(uniqueId)` onto the new id so HomeKit keeps rooms and automations.
- Service types per logic type: Lightbulb for all but `0x93`/`0x97`, which are Switch. Changing a Switch to an Outlet or a Dimmer to something else would be a new service for HomeKit.
- Discovery datagram `HF-A11ASSISTHREAD` on UDP 48899, reply parsing `ip,id,model`.
- TCP 5577, the checksum rule, the frames of 4.3 with the exact bytes per type and branch of 5.2 (mask values, white presets (31, 33) and (208, 17), thresholds and their comparisons as strict "less than"), the power-on-first rule on firmware bytes 2-5, 8 and 1 + `HF-LPB100-ZJ200`.
- State decoding of 4.4 and the type table of section 1.
- Accessory information values (Manufacturer `MagicHome`, Model = discovery model, Serial = unique ID).

Not needed for compatibility (fix freely): the duplicate probe frame, the 200 ms connect wait, first-chunk reads, the missing Identify completion, the per-30 s re-creation of unseen handlers, the CCT strip ignoring ColorTemperature, the absence of polling.

## 9. Gaps and hard parts

- **No polling and no reachability.** The source only reads on HomeKit GETs and never reports a device as unreachable. **Recommendation:** poll each device on an interval (10-30 s), refresh after writes, and mark it not responding after consecutive failures; keep GETs answered from the cache.
- **Colour maths are lossy and type-specific.** Ten branches across five level-writing behaviours (5.2) and five read-back mappings (5.3), with exact-equality white presets and a synthesised hue/saturation for white mode on RGBWW. These must be reproduced branch for branch; the vectors in 7.2-7.4 are the check. Note that the colour is computed with value 1 and then scaled linearly by brightness, and that the mixing branches send an unscaled full-saturation colour.
- **CCT devices are effectively broken in the source.** `0x09` writes depend on a hue that only comes from reads, ignore ColorTemperature, and clamp whites to 127; `0x52` (a CCT bulb per **[flux_led]**) is driven as an RGBWW bulb. An unused formula in the source maps mireds to whites as follows: c = mireds − 140; with threshold 110, if c ≥ 110 then warm 127 and cold = round(127 × (1 − (c − 110)/250)), else cold 127 and warm = round(127 × c/110). **Recommendation:** for `0x09` implement ColorTemperature properly: map mireds 140-500 to the device's warm/cool split and send the `35 B1` frame as **[flux_led]** reads it (byte 2 = temperature 0-100 from warm to cool, byte 3 = brightness 0-100, a minimum of 2), and verify on hardware; decide whether `0x52` should become a CCT light (a service change: Hue/Saturation removed, ColorTemperature added; same Lightbulb service, so HomeKit keeps it).
- **Dimmer write path is accidental** (5.2). Implement the recommended red-channel frame.
- **Addressable controllers `0xA1`/`0xA2`** are driven with the plain `31` levels frame. **[flux_led]** gives them their own protocols; whether `31` works on them was not verified. Keep the plugin's behaviour for compatibility; flag as unverified.
- **Newer firmware is unsupported.** Devices answering with the wrapped (`B0 B1 B2 B3 00 01 …`) or extended states, `0x35` bulbs with version ≥ 10 (the 25-byte protocol **[flux_led]**), and original-protocol devices (`EF 01 77` / `66 …`) are not handled; an unknown or malformed reply simply means no accessory. **Recommendation:** treat a reply that is not a 14-byte `0x81` state as "unsupported device" with a clear log line.
- **Identify** never completes in the source and leaves the light at a near-white; see 5.6.
- **Discovery details:** binding to 48899 can conflict with other software on the host (Homeswift itself must not run two discoveries at once); the own-echo reply; directed broadcasts per interface. Containers without host networking will see nothing. **Recommendation:** fit this into Homeswift's Setup as a `discover` step (broadcast, list `ip, id, model`, then the type query to name the device), with manual IP entry as a fallback, and only add accessories the user accepts, instead of auto-adding everything as the source does. The allow/deny list and pruning options then map onto Setup's exclusion and the cache's removal.
- **Port 5577 accepts few connections.** These Wi-Fi modules handle one or two TCP clients; the vendor app and other integrations compete. One connection per command, closed at once, is what the source does and is the least intrusive.
- **Timing quirks** (20 ms coalescing, 100 ms power-to-level delay, power-on first on some firmware bytes) come from field experience in the source, not from a specification; keep them.
- **The 2.x line** (alpha) is a rewrite on `magichome-platform` and a further protocol library; it was not specified. Configuration and identity may differ there.

## 10. Newer devices and firmware (from flux_led)

Everything in this section is **[flux_led]** (version 1.2.0, commit `cea6348f`, LGPL-3.0-or-later), described as protocol facts in my own words. The original plugin implements none of it beyond section 4. The wrapper algorithm below was checked against three captured frames quoted in flux_led's comments (a CCT-wrapped level frame, an A3 state query and a Christmas-light colour frame): the rules here reproduce their bytes exactly. The other vectors were computed by the spec writer from the rules.

### 10.1 Protocol families

flux_led picks a **protocol family** from two bytes of the first state reply: the model byte (byte 1) and the version byte (byte 10). For the extended reply (10.4.3) they are bytes 4 and 5. Each model lists `(minimum version → family)` pairs, highest minimum first. The first pair whose minimum the version reaches wins; if none does, the last pair's family is used. An unknown model byte gets the family that answered the probe (normally `8BYTE`) and colour mode RGB.

| Family | Query | Power on / off | Levels | Effects | Needs power-on before levels/effects | Device pushes changes |
|---|---|---|---|---|---|---|
| `ORIGINAL` | `EF 01 77` (no checksum) | `CC 23 33` / `CC 24 33` | `56 R G B AA` | `BB p delay 44` | yes | no |
| `ORIGINAL_RGBW` | same | same | `56 R G B W M AA` | same | yes | no |
| `ORIGINAL_CCT` | same | same | `56 a b AA` (two channels) | same | yes | no |
| `8BYTE` | `81 8A 8B` + cs | `71 23 0F` / `71 24 0F` + cs | `P R G B W M 0F` + cs | `61 p delay 0F` + cs | yes | no |
| `8BYTE_AUTO_ON` | as 8BYTE | as 8BYTE | as 8BYTE | as 8BYTE | **no** | no |
| `8BYTE_DIMMABLE_EFFECTS` | as 8BYTE | as 8BYTE | as 8BYTE | `38 p delay brightness` + cs | no | power and state |
| `9BYTE` | as 8BYTE | as 8BYTE | `P R G B WW CW M 0F` + cs | `61 p delay 0F` + cs | yes | no |
| `9BYTE_AUTO_ON` | as 8BYTE | as 8BYTE | as 9BYTE | as 9BYTE | no | no |
| `9BYTE_DIMMABLE_EFFECTS` | as 8BYTE | as 8BYTE | as 9BYTE | `38 p delay brightness` + cs | no | power and state |
| `25BYTE` | `81 8A 8B` + cs (plain) | plain `71` frames | wrapped, version 2, `E0 01 00 …` (10.3.5) | `61 p delay 0F` + cs | yes | no |
| `EXTENDED_CUSTOM` | as 25BYTE | as 25BYTE | as 25BYTE | as 25BYTE (custom effects not documented) | yes | no |
| `CCT` | as 8BYTE | as 8BYTE | `35 B1 T L 00 00 00 03` + cs | (none listed) | yes | power |
| `CCT_WRAPPED` | wrapped query | wrapped power | wrapped `35 B1 …` | (none) | no | state |
| `SOCKET` | as 8BYTE | as 8BYTE | (none) | (none) | - | power and state |
| `ADDRESSABLE_A1` | as 8BYTE | as 8BYTE | as 9BYTE | `61 hi lo speed 0F` + cs | no | power |
| `ADDRESSABLE_A2` | as 8BYTE | as 8BYTE | `41 01 R G B 00 00 00 60 FF 00 00` + cs, white `47 W` + cs | `42 p speed brightness` + cs | no | no (buggy firmware) |
| `ADDRESSABLE_A3` | wrapped query | wrapped power | A2 frames, each wrapped | A2 frame wrapped | no | power and state |
| `ADDRESSABLE_CHRISTMAS` | wrapped query | wrapped power | wrapped `3B A1 …` | wrapped `38 p delay` | no | power and state |

Notation: "+ cs" means the 8-bit sum checksum of section 4.2 is appended. P is the persistence byte: `31` saves the level (persist), `41` does not. M is the write mask: `00` writes both colours and whites, `F0` colours only, `0F` whites only. The 25BYTE family uses `00`, `A1` (colours) and `B1` (whites) instead.

Which mask to use: if the model "writes white and colours together" (`awwc` in 10.2), or its current colour modes include RGBW or RGBWW, the mask is always `00`. Otherwise it is `F0` when no white value is given and `0F` when no colour value is given.

Whites in the 9-byte form: when only one white value is given, cool white is set as follows. If the current colour mode is CCT or RGBWW, the device's current cool-white value is kept. Otherwise cool white is a copy of warm white.

### 10.2 Model table

Columns:
- **Byte**: state byte 1, the model byte.
- **Families by version**: the version → family pairs of 10.1, for example "v≥7 9BYTE_AUTO_ON".
- **Colour modes**:
  - RGB, RGBW (colour plus one white together), RGBWW (colour plus warm and cool together).
  - RGB/W (colour *or* white, one at a time), RGB/CCT (colour *or* tunable white).
  - DIM (one white channel), CCT (warm plus cool), ADDR (addressable, RGB).
  - "by mode byte": decided at run time from state byte 4 (10.4.1).
- **Remap**: the channel remap (10.4.2). "W↔R" means the single white level travels in the red byte. "WW↔R, CW↔G" means warm white travels in the red byte and cool white in the green byte.
- **awwc**: always writes white and colours together, mask `00`.
- **Mic**: built-in microphone (music mode).
- **Switch**: the device is a switch or socket, with no lighting.

| Byte | flux_led description | Families by version | Colour modes | Remap | awwc | Mic | Switch |
|---|---|---|---|---|---|---|---|
| `01` | Legacy Controller RGB | ORIGINAL | RGB | - | no | no | no |
| `02` | Legacy Controller Dimmable | ORIGINAL | DIM | W↔R | no | no | no |
| `03` | Legacy Controller CCT | ORIGINAL_CCT | CCT | WW↔R, CW↔G | no | no | no |
| `04` | Controller RGB&W | v≥6 8BYTE_AUTO_ON; else 8BYTE | RGBW | - | yes | no | no |
| `06` | Controller RGBW | v≥2 8BYTE_DIMMABLE_EFFECTS; v1 8BYTE_AUTO_ON; v0 8BYTE | RGBW or RGB/W by mode byte | - | no | no | no |
| `07` | Controller RGBCW | v≥2 9BYTE_DIMMABLE_EFFECTS; else 9BYTE | RGBWW or RGB/CCT by mode byte | - | no | no | no |
| `08` | Controller RGB with MIC | v≥2 8BYTE_DIMMABLE_EFFECTS; v1 8BYTE_AUTO_ON; v0 8BYTE | RGB (mode byte) | - | yes | yes | no |
| `09` | High Voltage Bulb CCT | CCT | CCT | - (temperature/brightness slots, 10.4.2) | no | no | no |
| `0B` | Switch 1 Channel | 8BYTE | none | - | no | no | yes |
| `0E` | Floor Lamp RGBCW | v≥9 9BYTE_DIMMABLE_EFFECTS; v≥7 9BYTE_AUTO_ON; else 9BYTE | RGB/CCT | - | no | no | no |
| `10` | Christmas Light | ADDRESSABLE_CHRISTMAS | ADDR | - | no | no | no |
| `16` | Magnetic Light CCT | 8BYTE | CCT | WW↔R, CW↔G | yes | no | no |
| `17` | Magnetic Light Dimable | 8BYTE | DIM | W↔R | yes | no | no |
| `18` | Plant Grow Light | 8BYTE | none | - | no | no | no |
| `19` | Socket with 2 USB | SOCKET | none | - | no | no | yes |
| `1A` | String Lights | ADDRESSABLE_CHRISTMAS | ADDR | - | no | no | no |
| `1B` | Aroma Fragrance Light | 8BYTE | RGB | - | no | no | no |
| `1C` | Table Light CCT | CCT_WRAPPED | CCT | - (temperature/brightness slots) | no | no | no |
| `1D` | Fill Light | 8BYTE_AUTO_ON (the only entry; a version below its minimum falls back to the last listed family, the same one) | DIM | W↔R | yes | no | no |
| `1E` | Ceiling Light RGBCW | as `0E` | RGB/CCT | - | no | no | no |
| `21` | Bulb Dimmable | v≥2 8BYTE_AUTO_ON; else 8BYTE | DIM | W↔R | yes | no | no |
| `25` | Controller RGB/WW/CW (multi-mode) | 9BYTE | by mode byte (`BASE_MODE_MAP`, 10.4.1); RGBWW when unset | - | yes | no | no |
| `33` | Controller RGB | v≥9 8BYTE_DIMMABLE_EFFECTS; v≥6 8BYTE_AUTO_ON; else 8BYTE | RGB (mode byte: wiring) | - | yes | no | no |
| `35` | Bulb RGBCW | v≥10 **25BYTE**; v9 9BYTE_DIMMABLE_EFFECTS; v7-8 9BYTE_AUTO_ON; else 9BYTE | RGB/CCT | - | no | no | no |
| `41` | Controller Dimmable | v≥2 8BYTE_AUTO_ON; else 8BYTE | DIM | W↔R | no | no | no |
| `44` | Bulb RGBW | v≥9 8BYTE_AUTO_ON; else 8BYTE | RGB/W | - | no | no | no |
| `45` | (unknown model) | 8BYTE | RGB, DIM | - | no | no | no |
| `52` | Bulb CCT | 8BYTE | **CCT** | WW↔R, CW↔G | yes | no | no |
| `54` | Downlight RGBW | 8BYTE | RGB/W | - | no | no | no |
| `62` | Controller CCT | 8BYTE | CCT | WW↔R, CW↔G | yes | no | no |
| `81` | (unknown model) | 8BYTE | RGBW | - | yes | no | no |
| `93` | Switch | SOCKET | none | - | no | no | yes |
| `94` | Switch Watt | SOCKET | none | - | no | no | yes |
| `95` | Switch 2 Channel | SOCKET | none | - | no | no | yes |
| `96` | Switch 4 Channel | SOCKET | none | - | no | no | yes |
| `97` | Socket | SOCKET | none | - | no | no | yes |
| `A1` | Addressable v1 | ADDRESSABLE_A1 | ADDR | - | no | no | no |
| `A2` | Addressable v2 | ADDRESSABLE_A2 | ADDR | - | no | yes | no |
| `A3` | Addressable v3 | ADDRESSABLE_A3 | ADDR (RGBW when configured for SK6812 RGBW strips) | - | no | yes | no |
| `A4` | Addressable v4 | ADDRESSABLE_A3 | ADDR | - | no | no | no |
| `A6` | Addressable v6 | ADDRESSABLE_A3 | ADDR | - | no | yes | no |
| `A7` | Addressable v7 | ADDRESSABLE_A3 | ADDR | - | no | yes | no |
| `B6` | Surplife Outdoor Permanent Lighting | EXTENDED_CUSTOM | RGB/W | - | no | yes | no |
| `D1` | Digital Time Light | 8BYTE | none | - | no | no | no |
| `E1` | Ceiling Light CCT | 8BYTE | CCT | WW↔R, CW↔G | yes | no | no |
| `E2` | Ceiling Light CCT Assist | 8BYTE | CCT | WW↔R, CW↔G | yes | no | no |

flux_led also knows the module strings that appear in discovery or in `AT+LVER` (10.6). It uses them only to add a suffix to the model description:

| Module string | Suffix |
|---|---|
| `ZG-BL-IR`, `IR`, `IR_ZG` | "IR" |
| `IR_MINI` | "IR Mini" |
| `ZG-BL-EH7W` | "7w" |
| `ZG-BL-IH9WL`, `ZG-BL-IH9W` | "9w RF" |
| `ZG-BL-CB1`, `LWS-BL` | "Ceiling" |
| `LWS-LX-IR` | "Ceiling IR" |
| `ZG-LX-EJ9W` | "9w" |
| `RF` | "RF" |
| `ZG-BL-5V` | "5v" |
| `ZGIR44` | "44 Key IR" |
| others | none |

Compared with the original plugin's table (section 1), the corrections that matter for HomeKit:
- `0x52` is a **CCT bulb** (warm and cool in the red and green bytes), not RGBWW.
- `0x09` and `0x1C` take temperature and brightness as 0-100 values, not warm/cool levels.
- `0x21`, `0x41`, `0x17` and `0x1D` carry their single level in the red byte.
- `0xA1`, `0xA2` and `0xA3`-`0xA7` are addressable strips with their own level frames. A1 accepts the 9-byte `31` frame; A2 and A3 do not.
- `0x35` from version 10 on uses the 25BYTE family.
- `0x0B`, `0x19`, `0x94`, `0x95`, `0x96` are switches.

### 10.3 Command forms per family

Levels below are 0-255 unless marked as percent.

**10.3.1 Power.** `71 23 0F` + cs is on, `71 24 0F` + cs is off. All non-original families use this frame; A3, CCT_WRAPPED and Christmas send it inside the wrapper (10.3.6). The device answers with a 4-byte power-state message:
- byte 0 is `F0`, `0F`, `00` or `01` (seen values);
- byte 1 is `71`;
- byte 2 is `23` (on) or `24` (off);
- byte 3 is a checksum, which some firmware gets wrong, so it must not be enforced.

flux_led's power procedure:
1. Send the frame. Wait up to 1.2 s × 3/8 for the power reply and/or a state reply. On families that need power-on before levels, both replies are expected.
2. If the reply is missing or shows the wrong state, send a state query and wait 1.2 s × 5/8.
3. Up to 6 attempts. From the 4th attempt on, any power reply counts as success (the vendor app behaves this way). If the device still reports the opposite state, flux_led trusts the requested state, because some firmware replies "off" while actually turning on.

**10.3.2 RGB.** In the 8BYTE/9BYTE families the frame is `31 R G B W M 0F` (7 bytes) or `31 R G B WW CW M 0F` (8 bytes), plus cs.
- Brightness for RGB is applied by scaling the colour: take the hue and saturation of (R, G, B), set the value to the target brightness (0-255), convert back to RGB, and truncate each channel to an integer.
- On RGB/W and RGB/CCT models, a colour write zeroes the whites (mask `F0`) and a white write zeroes the colour (mask `0F`).
- On RGBW/RGBWW models (and awwc models) both groups are written together with mask `00`.

**10.3.3 White, single channel (DIM).** Send the level as warm white. On remapped models it travels in the red byte, for example `31 L 00 00 00 M 0F` + cs. M is `00` on awwc models (`0x21`, `0x17`, `0x1D`). On `0x41` the source's rules give `F0` (the mapped white field is empty, so the write counts as a colour write).

**10.3.4 Tunable white (CCT), warm and cool levels.** Temperature K (Kelvin) and brightness Bb (0-255) are converted to levels:
1. Clamp K to [minimum, 6500]. The minimum is 2700 by default; a user setting can make it 4600 or 6500.
2. b = Bb/255 rounded to 2 decimals.
3. warm = (6500 − K)/(6500 − minimum) × b; cool = b − warm.
4. Each level = round(255 × value).

Sending the levels:
- 9-byte models: `31 00 00 00 WW CW 0F 0F` + cs (mask `0F` on split models, `00` on awwc/RGBWW).
- Remapped CCT models (`03`, `16`, `52`, `62`, `E1`, `E2`): `31 WW CW 00 00 00 0F` + cs, warm in the red byte and cool in the green byte, mask `00`.
- RGBW models in CCT emulation (when the minimum is not 6500): R = G = B = cool, W = warm.

The reverse, levels to temperature and brightness:
- w = warm/255, c = cool/255, s = w + c;
- K = (c/s) × (6500 − minimum) + minimum, or the minimum when s is 0;
- brightness = min(255, round(s × 255)).

**10.3.5 Tunable white, temperature-and-brightness form.**
- Families CCT (`0x09`) and CCT_WRAPPED (`0x1C`): `35 B1 T L 00 00 00 03` + cs, wrapped for `0x1C`.
  - T is the temperature in percent: 0 is fully warm, 100 fully cool.
  - L is the brightness in percent, sent as at least 2; below that the device flips from cool to warm.
  - From warm/cool levels: s = warm/255 + cool/255; T = round((cool/255)/s × 100) (0 when s is 0); L = min(100, round(s × 100)).
- Family 25BYTE (`0x35` v≥10) and `0xB6`: wrapped, version `02`, with an inner frame of 14 bytes **without its own checksum**: `E0 01 00 M h s v T L 00 00 14 00 00`.
  - M: `A1` colour, `B1` white, `00` both.
  - Colour fields: h = trunc(hue°/2) (0-180), s = trunc(saturation × 100), v = trunc(value × 100), from the RGB.
  - White fields: T = round(cool/(warm + cool) × 100), L = round(min(warm + cool, 255)/255 × 100). Both are 0 when no whites are given or both are zero.
  - When colour is not given, h, s and v are 0.

**10.3.6 Wrapper (the "outer message").** Frame layout:

| Bytes | Content |
|---|---|
| 0-5 | `B0 B1 B2 B3 00 01` |
| 6 | V, the version: `01`, or `02` for the 25BYTE level frame |
| 7 | C, a counter |
| 8-9 | inner length, big-endian |
| 10 … | the inner message |
| last | the checksum of every preceding byte |

- The counter is kept per connection/protocol instance. It starts so that the first wrapped message carries 0, increments by one per wrapped message, and after 254 wraps to 0 (255 is never used).
- Whether the inner message carries its own checksum depends on the frame:
  - wrapped query, power, CCT level, A3 frames and the remote-control config query: the inner message is the normal frame **with** its checksum;
  - Christmas levels and effects: the inner frame gets a checksum added before wrapping;
  - 25BYTE level frame: no inner checksum.
- Replies can also arrive wrapped. When a reply starts with the six header bytes (or just `B0`) and its checksum is right, the inner message is bytes 10 up to the last byte, exclusive.
- When the wrapper is used: always for A3-A7, `0x1C`, `0x10`/`0x1A`, the 25BYTE level frame and the 2.4 GHz remote config. In other families replies may be wrapped while requests are plain.

**10.3.7 Addressable.**
- A1: levels as 9BYTE.
- A2: colour frame `41 01 R G B 00 00 00 60 FF 00 00` + cs ("preset 1, fixed colour"). A white level is a separate frame `47 W` + cs, sent 1 s after the colour frame when both are given.
- A3-A7: the same A2 frames, each wrapped.
- Christmas (`0x10`, `0x1A`): wrapped `3B A1 h s v 00 00 00 00 00 00 00` with an inner checksum, where h = trunc(hue fraction × 180), s and v are percent truncated.
- Zones (A3 and Christmas): `A0 00 06`, then per pixel `00 index R G B 00 00 FF`, wrapped. This is listed only for completeness.

**10.3.8 Effects (presets).** Speed and delay convert as:
- delay = trunc((100 − speed) × 30/100) + 1, giving 1 (fast) to 31 (slow);
- speed = 100 − trunc((delay − 1) × 100/30), with delay clamped to 1-31.

Built-in pattern IDs for the 8/9-byte families:

| ID | Pattern |
|---|---|
| `25` | colour loop |
| `26` | red gradual change |
| `27` | green gradual change |
| `28` | blue gradual change |
| `29` | yellow gradual change |
| `2A` | cyan gradual change |
| `2B` | purple gradual change |
| `2C` | white gradual change |
| `2D` | red/green cross-fade |
| `2E` | red/blue cross-fade |
| `2F` | green/blue cross-fade |
| `30` | seven-colour strobe |
| `31` | red strobe |
| `32` | green strobe |
| `33` | blue strobe |
| `34` | yellow strobe |
| `35` | cyan strobe |
| `36` | purple strobe |
| `37` | white strobe |
| `38` | seven-colour jump |
| `24` | RGB cross-fade (dimmable-effects families only) |
| `39` | RGB cycle (dimmable-effects families only) |
| `3A` | seven-colour cycle (dimmable-effects families only; works only on some bulbs) |

Legacy CCT family effects: `3A` warm gradual, `3C` warm flash, `4A` cool gradual, `4C` cool flash.

Special values of state byte 3: `61` (and `41`) static colour or white, `60` custom pattern, `62` music (`63` legacy music).

Effect frames:
- plain: `61 id delay 0F` + cs;
- dimmable-effects families: `38 id delay brightness%` + cs;
- A1: `61 hi lo speed 0F` + cs, where hi/lo are the big-endian (ID + 99), ID 1-300;
- A2/A3: `42 id speed brightness%` + cs, ID 1-100, wrapped for A3;
- Christmas: wrapped `38 id delay` with an inner checksum, ID 1-100.

A custom pattern (up to 16 colours, `51 …`) and music mode exist but are out of scope. **Recommendation:** expose no effects in HomeKit (it has no effect control). At most, offer them as plugin tools in the web UI or MCP later.

### 10.4 State responses

**10.4.1 Standard 14-byte reply** (`81 …`, section 4.4), with these refinements:
- Validity: length exactly 14, byte 0 `0x81`, correct checksum.
- Byte 2: on = `23`, off = `24`.
- Byte 4 is the **mode byte**:
  - Multi-mode `0x25`, low nibble (`BASE_MODE_MAP`): `01` DIM, `02` CCT, `03` RGB, `04` RGBW (RGB&W), `05` RGBWW (RGB&CCT), `06` RGB/W, `07` RGB/CCT. A value of 0 means factory default, which is RGBWW.
  - `0x33` RGB: `13`, `23`, `33` (RGB, GRB, BRG wiring).
  - `0x06` RGBW: `14`/`24`/`34` RGB&W, `16`/`26`/`36` RGB/W; the high nibble is the wiring.
  - `0x07` RGBCW: `x5` RGB&CCT and `x7` RGB/CCT; the high nibble 1-F is one of 15 wirings.
  - `0x0E`/`0x1E`/`0x35`: `01` and `17` both mean RGB/CCT.
  - For an unknown model, the low nibble is read through `BASE_MODE_MAP`, with RGB as the default.
  - The device applies the wiring itself. The bridge always reads and writes logical R, G, B.
- Byte 5: speed, as a delay 1-31 (A1, A2, A3, Christmas and 25BYTE: speed 0-100).
- Bytes 6-9 and 11: R, G, B, warm, cool.
- Byte 10: version (selects the family).
- Byte 12: colour mode as last set (`F0`, `0F`, `00`).

How a light's current colour mode is decided:
- RGBWW-capable: RGBWW when any colour channel is non-zero, else CCT.
- RGB/CCT split: CCT when any white is non-zero, else RGB.
- RGB/W split: DIM when the white is non-zero, else RGB.
- RGBW with CCT emulation: CCT when R = G = B and at least one channel is non-zero, else RGBW.

Brightness (0-255) per mode:
- DIM: the warm level.
- CCT: the brightness of 10.3.4's reverse conversion.
- RGB: the HSV value × 255, truncated.
- RGBW: round((value×255 + warm)/2).
- RGBWW: round((value×255 + warm + cool)/3).
- During an effect: 255, or for A2/A3 with dimmable effects, the red byte as a percent × 255/100.

**10.4.2 Per-family reinterpretation of the 14 bytes.**
- Remapped models (Remap column): before use, swap red ↔ warm (and green ↔ cool) as listed. A dimmer's level is in byte 6, a CCT light's warm in byte 6 and cool in byte 7.
- CCT and CCT_WRAPPED (`0x09`, `0x1C`): byte 9 is the temperature in percent (0 warm, 100 cool) and byte 11 the brightness in percent. Convert to levels:
  - b = brightness/100 rounded to 2 decimals;
  - warm = round(255 × (100 − T)/100 × b) and cool = round(255 × (b − (100 − T)/100 × b)), where T is the temperature percent.
- A3 family: byte 9 (warm white) is on a scale of 128-228 and converts to 0-255 as round((clamp(value, 128, 228) − 128) × 255/100).
- A2/A3 effects: byte 3 `25` means an effect, with byte 4 the effect ID; `24` means a multi-colour mode, with byte 4 the ID (static, running water, strobe, jump, breathing). A1: effect ID = (byte 3 × 256) + byte 4 − 99. Christmas: byte 3 `25` with byte 4 the ID, and the speed in byte 7.
- `ORIGINAL` family (11 bytes): `66 model power pattern ? speed R G B W cs`, head `0x66`, no checksum check. Power state reply head `0x78`.

**10.4.3 Extended reply** (`EA 81 …`, at least 20 bytes; used by 25BYTE `0x35` v≥10, and the only reply `0xB6` sends, which is 27 bytes):

| Byte | Meaning |
|---|---|
| 0-1 | `EA 81` |
| 2-3 | reserved (seen `01`, `10`/`00`) |
| 4 | model byte |
| 5 | version |
| 6 | power `23`/`24` |
| 7 | preset pattern (`61` static; `25` custom effect on `0xB6`) |
| 8 | `01` white / `00` colour (on `0xB6` in effect mode: the effect ID) |
| 9 | speed |
| 10 | `0F` white / `F0` colour |
| 11 | hue / 2 (0-180) |
| 12 | saturation % |
| 13 | value % |
| 14 | white temperature % (0 warm, 100 cool) |
| 15 | white brightness % |
| 16-19 | unknown |
| 18 | on `0xB6`: configured LED count |

flux_led converts this reply to the 14-byte layout:
- R, G, B = trunc(255 × HSV-to-RGB(hue×2/360, sat/100, value/100)), each clamped to 0-255;
- warm and cool from bytes 14 and 15 by the percent conversion of 10.4.2. On `0xB6`, temperature > 100 or brightness of 0 or > 100 means whites off.

It usually arrives inside the wrapper, which supplies the length. A bare `EA` message has no length rule, and the whole received chunk is taken as the message.

**10.4.4 Other replies.**

| Reply | Head | Length | Content |
|---|---|---|---|
| power state | `xx 71` | 4 | as in 10.3.1 |
| time | `xx 11` | 12 | bytes 3-8 = year−2000, month, day, hour, minute, second |
| timers | `xx 22` | 88 / 94 / 100 | timers; length depends on the family |
| power-restore (sockets) | `xx 32` | 7 | bytes 2-5 per channel: `FF` always off, `0F` always on, `F0` last state |
| device/strip config, A2/A3 | `xx 63` | 11 | strip configuration |
| device/strip config, A1 | `63` | 12 | strip configuration |
| remote config | `2B` | 14 | byte 1 mode (`01` disabled, `02` open, `03` paired only), byte 3 number of paired remotes |
| music mode | `72` | 13 | music settings |

Reassembly: read until the expected length for the head is reached. A wrapped reply's length is 10 + inner length + 1.

### 10.5 Queries, the "0x23" byte, and time

- **There is no separate "0x23 query".** `0x23` is the "on" value: in byte 2 of the state reply, in the power frame `71 23 0F`, and in byte 2 of the power reply.
- The only state query is `81 8A 8B` + cs (`96`): plain for most families, wrapped for A3-A7, `0x1C` and `0x10`/`0x1A`. Legacy devices use `EF 01 77`.
- Probing at connect: send the plain 8-byte query first, then the original one if there is no reply within the timeout (5 s by default in flux_led). Legacy devices are tried in the reverse order: MAC prefix `ACCF23`, or a discovery version without a model number.
- The first reply fixes the family, and later queries use the family's form. Devices that need the wrapped form still answer the plain query during probing.
- Other queries (all + cs; wrapped where noted):
  - time `11 1A 1B 0F`;
  - timers `22 2A 2B 0F`;
  - power-restore state `32 3A 3B 0F` (sockets, sent at set-up);
  - strip config `63 12 21 0F` (A2; wrapped for A3), or the 4 literal bytes `63 12 21 36` on A1;
  - remote config: wrapped `2B 2C 2D` + cs (models with 2.4 GHz remotes).
- **Time.** Set: `10 14 YY MM DD hh mm ss dow 00 0F` + cs, where YY is year − 2000 and dow is 1 = Monday … 7 = Sunday. Get: as above, reply in 10.4.4. flux_led never sets the clock on its own, only on request. The device clock matters only for its on-board timers. **Recommendation:** do not sync the time; Homeswift does not use device timers.
- Polling in flux_led:
  - It keeps one TCP connection open per device and queries the state on each update request.
  - While the device is on and its family pushes state changes, or whenever its family pushes power changes, it skips polls for 90 s after the last update. Such devices send unsolicited `81 …` or power replies when changed from the app, a remote or IR.
  - After 4 unanswered queries it closes the connection and marks the device unavailable.
  - State replies that arrive during a transition are ignored, so a fade is not read back half-way: 2 s plus the effect delay after a level change (5 s on addressable), 3 s after a power change.

### 10.6 Discovery (UDP 48899)

- flux_led sends three datagrams to the broadcast address (or to a single address), 0.4 s apart: `HF-A11ASSISTHREAD`, `AT+LVER\r` and `AT+SOCKB\r`. It re-sends them every timeout/6 seconds (10 s total by default) until the answers are complete.
- It binds to source port 48899 if it can, because legacy devices answer only to that port, and falls back to any port otherwise.
- It ignores datagrams equal to its own messages and keys answers by source IP.

Replies (ASCII; trailing CR/LF stripped):

| Request | Reply | Fields |
|---|---|---|
| `HF-A11ASSISTHREAD` | `<ip>,<MAC 12 hex>,<module>` | e.g. `192.168.1.50,ACCF23A1B2C3,AK001-ZJ2145`. Fewer than 3 fields is not a device. The module string (`AK001-ZJ21xx`, `HF-LPB100-ZJ200`, …) is hardware, not the light type. |
| `AT+LVER\r` | `+ok=<model hex>_<version hex>_<YYYYMMDD>_<module info>\r` | e.g. `+ok=35_0A_20220103_ZG-BL\r` → model byte `0x35`, version 10, firmware date 2022-01-03, module info `ZG-BL`. A single field means the version only (old devices). |
| `AT+SOCKB\r` | `+ok=TCP,<port>,<host>\r` | cloud "remote access" target; `+ok=` alone means disabled |

So newer devices give their model byte and version in discovery, before any TCP connection. This lets the bridge name and classify a device during Setup. Other AT commands (reboot `AT+Z\r`, setting or clearing remote access) change the device. **Recommendation:** never send them.

### 10.7 Recommended CCT mapping for HomeKit (fixes 0x09 and 0x52)

**Recommendation:**
- Expose ColorTemperature with props min 154, max 370 mireds (6500-2700 K) on every model whose colour modes include CCT: `03`, `09`, `16`, `1C`, `52`, `62`, `E1`, `E2`, the RGB/CCT bulbs and lamps (`0E`, `1E`, `35`), and `07`/`25` in an RGB/CCT or RGBWW mode.
- Colour-plus-CCT models (`07`, `0E`, `1E`, `25`, `35`) keep Hue and Saturation. Pure CCT models do not get them.

Conversions:
- Mireds M → Kelvin K = 10⁶/M, clamped to [2700, 6500] → temperature fraction t = (K − 2700)/3800, with 0 warm and 1 cool.
- HomeKit Brightness B (0-100) → b = B/100.

What to send:
- `0x09`, `0x1C`: `35 B1 round(100 t) max(2, round(100 b)) 00 00 00 03` + cs, wrapped for `0x1C`.
- Remapped CCT models (`03` original form, `16`, `52`, `62`, `E1`, `E2`): warm = round(255 × (1 − t) × b) in the red byte, cool = round(255 × t × b) in the green byte, `31 warm cool 00 00 00 0F` + cs.
- 9-byte models in white mode: `31 00 00 00 warm cool 0F 0F` + cs (mask `00` on `0x25`).
- 25BYTE: the white form of 10.3.5 with T = round(100 t), L = round(100 b).
- RGB/CCT split devices: a ColorTemperature write switches to white (mask `0F`/`B1`), a Hue/Saturation write switches to colour.

Reading back:
- t = cool/(warm + cool); K = 2700 + 3800 t; M = round(10⁶/K); Brightness = round(100 × min(1, (warm + cool)/255)).
- For `0x09`/`0x1C`, read t and b directly from bytes 9 and 11.
- When warm + cool is 0, keep the last ColorTemperature.

Adaptive Lighting then works through Homeswift's `AdaptiveLightingController` on these models.

Migration: an existing `0x52` accessory (RGBWW in the original) keeps its Lightbulb service. It loses Hue and Saturation and gains ColorTemperature. HomeKit keeps the accessory, but scenes that set a colour on it need re-saving.

### 10.8 Test vectors per family

All hex, checksum last. Wrapped counters are arbitrary.

| Family / model | Input | Frame |
|---|---|---|
| 8BYTE `0x33` (awwc) | red 255 | `31 FF 00 00 00 00 0F 3F` |
| 8BYTE `0x44` RGB/W | blue 255 | `31 00 00 FF 00 F0 0F 2F` |
| 8BYTE `0x44` RGB/W | white 128 | `31 00 00 00 80 0F 0F CF` |
| 9BYTE `0x07`/`0x35` (v<10) split | colour 255, 128, 0 | `31 FF 80 00 00 00 F0 0F AF` |
| 9BYTE split | 4600 K at full brightness → warm 128, cool 128 | `31 00 00 00 80 80 0F 0F 4F` |
| 9BYTE `0x25` (awwc) | 255, 0, 0, warm 64, cool 32 | `31 FF 00 00 40 20 00 0F 9F` |
| CCT `0x09` | 2700 K, brightness 255 → levels 255/0 → T 0, L 100 | `35 B1 00 64 00 00 00 03 4D` |
| CCT `0x09` | 5000 K, brightness 128 → levels 50/77 → T 61, L 50 | `35 B1 3D 32 00 00 00 03 58` |
| CCT_WRAPPED `0x1C` | same, counter 0 | `B0 B1 B2 B3 00 01 01 00 00 09 35 B1 3D 32 00 00 00 03 58 81` |
| 8BYTE remapped CCT `0x52` | 4600 K full → warm 128 (red byte), cool 128 (green byte) | `31 80 80 00 00 00 0F 40` |
| DIM `0x21` (awwc) | level 128 in the red byte | `31 80 00 00 00 00 0F C0` |
| DIM `0x41` | level 128 | `31 80 00 00 00 F0 0F B0` |
| 25BYTE `0x35` v≥10 | green 0, 255, 0 → h 60, s 100, v 100; counter 0 | `B0 B1 B2 B3 00 01 02 00 00 0E E0 01 00 A1 3C 64 64 00 00 00 00 14 00 00 71` |
| 25BYTE | white 4600 K full → T 50, L 100; counter 1 | `B0 B1 B2 B3 00 01 02 01 00 0E E0 01 00 B1 00 00 00 32 64 00 00 14 00 00 14` |
| A1 `0xA1` | red 255 | `31 FF 00 00 00 00 F0 0F 2F` |
| A1 | effect 5, speed 50 (ID + 99 = 104) | `61 00 68 32 0F 0A` |
| A2 `0xA2` | red 255 | `41 01 FF 00 00 00 00 00 60 FF 00 00 A0` |
| A2 | white 128 | `47 80 C7` |
| A2 | effect 12, speed 50, brightness 100 | `42 0C 32 64 E4` |
| A3 `0xA3` | red 255, counter 1 | `B0 B1 B2 B3 00 01 01 01 00 0D 41 01 FF 00 00 00 00 00 60 FF 00 00 A0 16` |
| A3 | power on, counter 2 | `B0 B1 B2 B3 00 01 01 02 00 04 71 23 0F A3 14` |
| A3 | state query, counter 12 | `B0 B1 B2 B3 00 01 01 0C 00 04 81 8A 8B 96 04` |
| Christmas `0x1A` | red, counter 5 | `B0 B1 B2 B3 00 01 01 05 00 0D 3B A1 00 64 64 00 00 00 00 00 00 00 A4 22` |
| 8BYTE effect | colour loop `25`, speed 50 → delay 16 | `61 25 10 0F A5` |
| DIMMABLE_EFFECTS | same, brightness 80 % | `38 25 10 50 BD` |
| any | set time 2026-11-04 13:05:09, Wednesday (3) | `10 14 1A 0B 04 0D 05 09 03 00 0F 7A` |
| any | get time / power-restore query / A2 strip config | `11 1A 1B 0F 55` / `32 3A 3B 0F B6` / `63 12 21 0F A5` |
| remote models | remote config query, counter 0 | `B0 B1 B2 B3 00 01 01 00 00 04 2B 2C 2D 84 D4` |

State replies (invented devices):

| Reply | Meaning |
|---|---|
| `81 09 23 61 00 10 00 00 00 1E 05 50 0F A0` | `0x09` CCT bulb, on, version 5. T 30 %, brightness 80 % → levels warm 143, cool 61 → ColorTemperature: t 0.30 → K 3840 → 260 mireds; Brightness 80. |
| `81 52 23 61 02 10 C0 40 00 00 03 00 0F 7B` | `0x52` CCT bulb, on, version 3. After the remap warm 192 (byte 6), cool 64 (byte 7) → t 0.25 → 3650 K → 274 mireds; Brightness 100 (sum 256 capped). |
| `81 25 23 61 07 10 00 00 00 80 05 80 0F 55` | `0x25` multi-mode, mode byte `07` = RGB/CCT. Whites 128/128, colour 0 → CCT mode, 4600 K (217 mireds), Brightness 100. |
| `81 21 23 61 00 10 80 00 00 00 02 00 00 B8` | `0x21` dimmable bulb, level 128 in byte 6 → Brightness 50. |
| `B0 B1 B2 B3 00 01 01 07 00 0E 81 A3 23 61 00 10 FF 00 00 00 01 00 F0 A8 2D` | wrapped reply; inner `81 A3 …` = `0xA3` addressable, on, red 255. |
| `EA 81 01 00 35 0B 23 61 00 32 F0 5A 64 32 00 00 00 00 00 00` | extended: `0x35` version 11, on, colour, hue 0x5A × 2 = 180°, saturation 100 %, value 50 % → RGB 0, 127, 127. Wrapped with counter 9: `B0 B1 B2 B3 00 01 01 09 00 14` + the 20 bytes + `27`. |
| `EA 81 01 00 35 0B 23 61 01 32 0F 00 00 00 32 64 00 00 00 00` | extended, white mode, T 50 %, brightness 100 % → warm 128, cool 128 (4600 K). |
| `F0 71 23 84` / `0F 71 24 A4` | power replies: on / off |

Discovery:
- `192.168.1.50,ACCF23A1B2C3,AK001-ZJ2145`
- `+ok=35_0A_20220103_ZG-BL\r` → model `0x35`, version 10 → family 25BYTE before any TCP connection.

Mireds → temperature percent (10.7): 140 → 6500 K, 100 %; 154 → 100 %; 200 → 5000 K, 61 %; 250 → 4000 K, 34 %; 370 → 2703 K, 0 %; 400 or more → 2700 K, 0 %.

### 10.9 Homeswift id and migration

**Recommendation:** the accessory `id` is `MagicHome:<MAC>`. The MAC is the 12 hexadecimal digits of the discovery reply's second field, uppercased, with any `:` or `-` removed, for example `MagicHome:ACCF23A1B2C3`. It is the Device Id in Setup and the key in `_accessories`.

Migration from the Homebridge plugin:
- The original accessory UUID is HAP-NodeJS `uuid.generate(uniqueId)` over the bare MAC string as discovered (section 3.1).
- The Homebridge cache stores that MAC in `context.device.uniqueId`. A migration reads it, normalises it to uppercase, checks that `uuid.generate` of it matches the cached UUID, and maps the cached accessory to `MagicHome:<MAC>`. Rooms, scenes and automations then survive, provided the bridge keeps the HAP aid for that id.
- The display name (`context.device.displayName`) and the last IP (`context.device.cachedIPAddress`) become the Accessory Settings name and the starting address.
- If the discovered MAC is lowercase, the original UUID was computed from the lowercase string. The check must hash the string exactly as cached, not the normalised one.

### 10.10 Hard parts added by newer firmware

- **The family depends on version.** The same model byte (`0x35`, `0x06`, `0x33`, `0x44`, `0x07`) changes command forms with the version byte. Choose the family once from the first reply (or from `AT+LVER`), and re-choose it if the version changes after a firmware update.
- **Wrapped families need a counter.** The counter must be kept per device connection and wrap at 255. Replies may come wrapped even to plain requests, so the reader must unwrap first, then classify by head.
- **Turn-on rules differ.** "Needs power-on" families must get `71 23 0F` before levels or effects. Auto-on families must not, because an extra power frame causes a visible flash on some.
- **Push devices** send unsolicited state. With per-command connections (section 4.2) these updates are lost. **Recommendation:** keep one persistent connection per device, as flux_led does, read pushes, poll every 30 s while on and every 90 s while off (or always 30 s for simplicity), and mark the device not responding after 4 unanswered queries.
- **Addressable strips** (A1-A7, Christmas) need strip configuration (pixel count, IC type, wiring) only for effects and zones. Plain colour and white work without it. **Recommendation:** colour only, no strip configuration in a first version.
- **Original-protocol devices** (`0x01`-`0x03`, MAC prefix `ACCF23` without a model in discovery) have no checksums and an 11-byte state. Support them only if a user owns one.
- **Unverified on hardware:** the exact turn-on behaviour of `0x41` (mask `F0` vs `0F`), the 25BYTE reply's bytes 2-3 and 16-19, and whether the 25BYTE family needs power-on before levels (flux_led says yes).
