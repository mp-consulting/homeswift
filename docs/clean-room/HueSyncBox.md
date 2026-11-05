# Hue Sync Box: functional specification (clean room)

## 0. Provenance

Written by the spec writer for a clean-room port; it contains **no source code** from any of the projects below. Everything is a description, in my own words, of observed behaviour. Interface identifiers (URLs, JSON keys, enum strings, config keys, HomeKit subtypes) are quoted exactly because a drop-in must match them. Statements marked **Recommendation** are mine, not the source's. Nothing from the repositories was installed or run; they were read as data. Each fact is tagged with its source where it matters: **[HB]**, **[AIO]**, **[HA]**.

| Tag | Project | URL | Commit read | Version | Licence and copyright |
|---|---|---|---|---|---|
| **[HB]** (primary) | Homebridge plugin `homebridge-philips-hue-sync-box` (display name "Homebridge Philips Hue Sync Box") | https://github.com/jabrown93/homebridge-philips-hue-sync-box | `f3e1090fcec46327db8d3161f1637912d2e56000` (2026-11-04) | 3.1.5 (npm `latest`; `4.0.0-beta.1` exists as `beta`, not read) | MIT. `LICENSE` line: "Copyright (c) 2025 Jared Brown". `package.json` lists Jared Brown as author and Lukas Rögner as contributor; README: "originally developed by Lukas Rögner". |
| **[AIO]** | Python library `aiohuesyncbox` | https://github.com/mvdwetering/aiohuesyncbox | `c623c831e30afc58c6c61ca1988448e5f7527162` (2026-11-04) | 0.1.6 | Apache-2.0 (`LICENSE` is the plain Apache 2.0 text with no copyright line, no NOTICE file). Author in `pyproject.toml`: Michel van de Wetering. |
| **[HA]** | Home Assistant custom integration `huesyncbox` | https://github.com/mvdwetering/huesyncbox | `60eb8b57e2e907a9a945676556bd46bf98568c4c` (2026-10-31) | manifest `0.0.0`, needs aiohuesyncbox 0.1.6 | Apache-2.0 (same: no copyright line, no NOTICE). |

Note on the name: the task brief says `homebridge-hue-sync-box` by lukasroegner. That repository name does not exist; the original is `lukasroegner/homebridge-philips-hue-sync-box`, which GitHub now redirects to the jabrown93 repository (cloning both gave the same commit). jabrown93's is the maintained one (npm package `homebridge-philips-hue-sync-box`, published from it). No more maintained fork was found (`jabrown93/homebridge-philips-hue-sync-box-v2` and `fbdegroot/homebridge-philips-hue-play-hdmi-sync-box` are stale).

The Sync Box's root certificate (section 3.3) is Philips's published data, not any project's code; [HB] and [AIO] embed the identical certificate and cite Philips's developer site.

For THIRD-PARTY-NOTICES: if the port is treated as derived from [HB], the MIT notice "Copyright (c) 2025 Jared Brown" applies. [AIO] and [HA] were used only for protocol facts (registration, mDNS, error codes).

## 1. Scope

The Philips Hue Play HDMI Sync Box (model ids seen: `HSB001` in the mDNS TXT record per [HA], `HSB2` as `device.deviceType` in [HB]'s mock state) is a 4-in, 1-out HDMI switch that drives Hue entertainment lights. It has a local HTTPS REST API, API level 7 or newer ([AIO] logs an error below 7).

[HB] is a Homebridge *dynamic platform* for **one box per platform block** (several boxes = several blocks, each with its own `uuidSeed`). It has **no discovery and no registration**: the user enters the IP and an access token obtained by hand (section 3). It exposes up to seven accessories, each enabled by config:

| Kind (internal name, also the id seed) | Enabled by | HomeKit form | Published |
|---|---|---|---|
| `LightBulbAccessory` | `baseAccessory` = `lightbulb` (default) | Lightbulb (On, Brightness) | bridged |
| `SwitchAccessory` | `baseAccessory` = `switch` | Switch (On) | bridged |
| `PowerSwitchAccessory` | `powerSwitchAccessory` = true | Switch (On) | bridged |
| `TVAccessory` | `tvAccessory` = true | Television whose inputs are the 4 HDMI inputs | external (own HAP server) |
| `ModeTVAccessory` | `modeTvAccessory` = true | Television whose inputs are the 5 modes | external |
| `IntensityTVAccessory` | `intensityTvAccessory` = true | Television whose inputs are the 4 intensities | external |
| `EntertainmentTVAccessory` | `entertainmentTvAccessory` = true | Television whose inputs are the Hue entertainment areas | external |

`baseAccessory` = `none` creates neither the lightbulb nor the switch. Each TV may carry an extra Lightbulb service. [HB] also has an optional local HTTP API (section 6.6).

In Homeswift: the bridged ones are ordinary accessories; the TVs go through `context.publishExternal`. Registration should become a Setup flow (section 3.4), which [HB] lacks.

## 2. Configuration interface

Platform name (`pluginAlias`, the `platform` value): **`PhilipsHueSyncBoxPlatform`**. `pluginType` `platform`, several blocks allowed (one per box). The schema has `strictValidation: true`.

| Key | Type | Default (applied at runtime when absent) | Meaning |
|---|---|---|---|
| `platform` | string | - | `PhilipsHueSyncBoxPlatform`. |
| `name` | string | none | Only used in log lines ("Initializing platform: <name>"). Not part of any id. |
| `syncBoxIpAddress` | string | **required** | IPv4 address (or host name) of the box. Plugin refuses to start (logs "Missing required configuration parameters" and throws) when empty. |
| `syncBoxApiAccessToken` | string | **required** | Bearer token from registration. **Secret** (matches Homeswift's `token` key pattern). Same refusal when empty. |
| `defaultOnMode` | string | `video` | Mode written when a HomeKit "on" is set: `video`, `music`, `game` or `lastSyncMode` (resolved to the box's `execution.lastSyncMode`, falling back to `video` when that is empty). |
| `defaultOffMode` | string | `passthrough` | Mode written when a HomeKit "off" is set: `passthrough` or `powersave`. |
| `baseAccessory` | string | `lightbulb` | `lightbulb`, `switch` or `none`. |
| `powerSwitchAccessory` | bool | false | Adds the power switch (on = passthrough, off = powersave). |
| `tvAccessory` | bool | false | HDMI-input TV. |
| `tvAccessoryConfiguredName` | string | absent | Fixed name for the HDMI TV (overrides any name set in HomeKit). |
| `tvAccessoryType` | string | `tv` | Icon/category: `tv` (schema also lists `TV`), `settopbox`, `tvstick`, `audioreceiver`. Matched lowercased; anything else gives Television. |
| `tvAccessoryLightbulb` | bool | false | Adds a Lightbulb service to the HDMI TV. |
| `modeTvAccessory`, `modeTvAccessoryConfiguredName`, `modeTvAccessoryType`, `modeTvAccessoryLightbulb` | as above | false / absent / `tv` / false | Mode TV. |
| `intensityTvAccessory`, `intensityTvAccessoryConfiguredName`, `intensityTvAccessoryType`, `intensityTvAccessoryLightbulb` | as above | same | Intensity TV. |
| `entertainmentTvAccessory`, `entertainmentTvAccessoryConfiguredName`, `entertainmentTvAccessoryType`, `entertainmentTvAccessoryLightbulb` | as above | same | Entertainment area TV. |
| `treatPassthroughAsOffForTv` | bool | false | When true, every TV's Active shows 0 in `passthrough` (default: on in passthrough, off only in powersave). |
| `updateIntervalInSeconds` | integer | 5 | Poll period. |
| `uuidSeed` | string | absent (treated as empty) | Appended to every accessory's id seed; must differ per box when several blocks exist (at most one block may leave it empty). Changing it re-creates every accessory. |
| `apiServerEnabled` | bool | false | Starts the plugin's own HTTP API (section 6.6). |
| `apiServerPort` | integer | 40220 | Its TCP port. |
| `apiServerToken` | string | none, min length 32 | Required in the `Authorization` header of that API. **Secret.** |

Category numbers for the `*Type` options (HAP categories): `tv` 31 (Television), `settopbox` 35 (TV set-top box), `tvstick` 36 (TV streaming stick), `audioreceiver` 34 (audio receiver).

Example block (must load unchanged):

    { "platform": "PhilipsHueSyncBoxPlatform", "name": "Living Room Sync Box",
      "syncBoxIpAddress": "192.168.1.50", "syncBoxApiAccessToken": "<token>",
      "defaultOnMode": "lastSyncMode", "defaultOffMode": "passthrough",
      "baseAccessory": "lightbulb", "powerSwitchAccessory": true,
      "tvAccessory": true, "tvAccessoryType": "settopbox", "tvAccessoryLightbulb": false,
      "modeTvAccessory": true, "intensityTvAccessory": false, "entertainmentTvAccessory": true,
      "treatPassthroughAsOffForTv": false, "updateIntervalInSeconds": 5, "uuidSeed": "LivingRoom" }

**Recommendation (Homeswift):** read these keys as they are; what Setup writes (section 3.4) should also be the box's `uniqueId` (needed for proper TLS, section 3.3), stored under a non-secret key such as `syncBoxUniqueId`, and the token sealed as `syncBoxApiAccessToken`.

## 3. Registration and transport

### 3.1 Getting a token ([HB] README, [AIO], [HA])

[HB] has no code for this; its README tells the user to do it by hand. [AIO]/[HA] automate it. Combined behaviour:

1. Send `POST https://<host>/api/v1/registrations`, header `Content-Type: application/json`, **no `Authorization` header** ([AIO] explicitly sends this request unauthenticated: a stale token makes it fail), body `{"appName": "<app>", "instanceName": "<instance>"}`. [HB] README uses `"homebridge"` for both; [HA] uses appName `"Home Assistant"` and instanceName the HA location name.
2. Until the button is pressed the box answers with a non-200 status and the JSON error `{"code": 16, "message": "Invalid State"}`. This is expected.
3. The user presses and holds the box's button until the LED blinks/turns green ([HB] README: release as soon as it is green; it returns to white). The box then accepts registrations for about 5 seconds ([HB] README).
4. [AIO]/[HA] loop: send the POST, swallow the `Invalid State` error, wait 1 second, repeat until a success. [HA] has no upper bound on the loop (it runs as a progress step the user can abandon). **Recommendation:** poll every 1 s for at most 30-60 s, then fail with "the button was not pressed".
5. Success: HTTP 200, JSON `{"registrationId": "<id>", "accessToken": "<token>"}`. Keep both; the token is the secret, the registration id is needed to unregister.

Other registration endpoints ([AIO]):
- `GET /api/v1/registrations` with the token: succeeds when the token is valid; an `Unauthorized` error means it is not (used by [HA] as "is registered"). Answer is a map `{ "<registrationId>": { "appName", "instanceName", "role" ("admin"/"user"), "verified" (API level 10+), "lastUsed", "created" } }`. The same map appears as `registrations` in the full state.
- `DELETE /api/v1/registrations/<registrationId>`: unregisters; only the id belonging to the token in use can be removed.

Error body format ([AIO]): every non-200 JSON answer is `{"code": <int>, "message": <string>}`. Codes: 1, 2, 3 = unauthorized (bad/missing token); 10-15 = request errors; 16 = invalid state (no button press, or the box can't do it now). Others: generic.

### 3.2 Discovery ([AIO] example, [HA])

mDNS service type `_huesync._tcp` (`_huesync._tcp.local.`). TXT keys used: `uniqueid` (the box's unique id, e.g. 12 hex-ish chars like "C43212345678" per [AIO] README; equals `device.uniqueId`), `path` (API base path, `/api`), `name` (the box's user-visible name), `devicetype` (`HSB001`). The SRV port is used, defaulting to 443. The SRV/A addresses give the host. [HA] keys a configured box by `uniqueid` and updates its host when rediscovered.

### 3.3 HTTPS and the certificate

- Always HTTPS on port 443. Base URL: [HB] `https://<syncBoxIpAddress>/api/v1/`; [AIO] `https://<host>:<port><path>/v1` with `path` from TXT (default `/api`).
- The leaf certificate is **not** self-signed: it is signed by the Hue Sync Box root CA, the same in every box. The leaf's subject CN is the box's `uniqueId`, not its IP ([HB] comment, [AIO] behaviour).
- [HB]: trusts only that CA, **disables host-name verification** (it doesn't know the uniqueId before connecting), keeps connections alive.
- [AIO]: trusts only that CA, sends the `uniqueId` as the TLS server name (SNI) and checks it against the certificate's CN (common-name matching enabled). This is the stronger form.
- **Recommendation:** pin to the CA; verify the CN equals the configured/discovered `uniqueId` when known, otherwise (an [HB] config without it) accept any leaf from the CA, read `device.uniqueId` from the first state and from then on require it. Homeswift's `HTTPClient` trust/pin options apply.

The CA, as published by Philips at `https://developers.meethue.com/wp-content/uploads/2020/01/hsb_cacert.pem_.txt` (identical in [HB] and [AIO]): subject = issuer = `C=NL, O=Philips Hue, CN=root-hsb`, EC P-256 key, valid 2017-01-01 to 9999-12-31, SHA-256 fingerprint `A8:4F:E4:D6:E4:B7:24:4D:45:D0:A0:03:4F:7E:E1:49:85:2C:EC:B5:2E:BA:7F:C1:2A:3A:CA:76:6E:E6:8C:74`. PEM:

    -----BEGIN CERTIFICATE-----
    MIIBwDCCAWagAwIBAgIBATAKBggqhkjOPQQDAjA2MQswCQYDVQQGEwJOTDEUMBIG
    A1UECgwLUGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMCAXDTE3MDEwMTAw
    MDAwMFoYDzk5OTkxMjMxMjM1OTU5WjA2MQswCQYDVQQGEwJOTDEUMBIGA1UECgwL
    UGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMFkwEwYHKoZIzj0CAQYIKoZI
    zj0DAQcDQgAEr9FgOxnsonsrnUZr3C4ggST7YCR9wISvDuwlNdZcAz4HiVCNmAAP
    tAnAFDG0U19Rmc4MfRYBMO8GrOHrOkZ7sKNjMGEwHQYDVR0OBBYEFCK+VIWZqp++
    DHqmGLWEZHYdH9v7MB8GA1UdIwQYMBaAFCK+VIWZqp++DHqmGLWEZHYdH9v7MA8G
    A1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMCA0gAMEUC
    IAFDI0Q4IOPxV7cY4wSVOJAn4y5AdZwrItJ1XuNpmCltAiEA5c6wcu6qmF596uyA
    r7xLnr3/F5zJxrE3AyLD4t+5oKs=
    -----END CERTIFICATE-----

- Every authenticated request carries `Authorization: Bearer <accessToken>` and `Content-Type: application/json` ([HB], [AIO]).
- The box handles few connections: [AIO] limits itself to 1 connection per host; [HB] serialises every request (section 6.3).

### 3.4 Homeswift Setup (Recommendation)

The Homeswift rule is that a device enters through Setup. Map: `discover` = browse `_huesync._tcp` (offer each box's name, uniqueid, host); also accept a typed IP (then read `uniqueId` from the TLS leaf or the first state). `authorize` = a step whose prompt says "Press and hold the button on the Sync Box until the light turns green", then runs the 1-second registration loop of 3.1 with appName `homeswift` and instanceName the bridge's name, and stores the token. Then fetch the state once to confirm, and write the block in [HB]'s shape.

## 4. API used

### 4.1 Reading: `GET /api/v1/` ([HB] path `''`)

One GET returns the whole state: `device`, `hue`, `execution`, `hdmi`, `behavior`, `ir`, `registrations`, `presets`. Fields [HB] reads:

| Path | Type / values | Used for |
|---|---|---|
| `device.name` | string, non-empty | Accessory display names, TV fallback name. |
| `device.uniqueId` | string | SerialNumber (plus suffix). |
| `device.firmwareVersion` | string, e.g. `"2.4.2"` | FirmwareRevision. |
| `execution.mode` | `powersave`, `passthrough`, `video`, `music`, `game` | All On/Active states, Mode TV input. |
| `execution.lastSyncMode` | `video`, `music`, `game` | `defaultOnMode` = `lastSyncMode`, intensity when not syncing. |
| `execution.hdmiSource` | `input1`..`input4` | HDMI TV input. |
| `execution.brightness` | integer 0-200 (100 = unchanged, 0 = max reduction, 200 = max boost, per [AIO]) | Lightbulb brightness, remote up/down. |
| `execution.video.intensity`, `execution.music.intensity`, `execution.game.intensity` | `subtle`, `moderate`, `high`, `intense` | Intensity TV. |
| `hue.groups` | object `{ "<groupId>": { "name", "numLights", "active", "owner"? } }` | Entertainment TV inputs, in the object's key order. |
| `hue.groupId` | string, one of the keys (or unknown) | Entertainment TV active input. |
| `hdmi.input1`..`hdmi.input4` | `{ "name", "type", "status", "lastSyncMode" }` | HDMI TV input names. |

Also present but not used by [HB]: `execution.syncActive` (false in powersave/passthrough), `execution.hdmiActive` (false only in powersave), `execution.hueTarget` (selected area; entertainment configuration id for Hue bridge API v2, per [AIO]), `execution.preset`, `video/game.backgroundLighting`, `music.palette` (`happyEnergetic`, `happyCalm`, `melancholicCalm`, `melancholicEnergetic`, `neutral`), `device.apiLevel`, `deviceType`, `wifi`, `ipAddress`, `ledMode`, `hdmi.output`, `hdmi.contentSpecs`, `hue.connectionState` (`uninitialized`, `disconnected`, `connecting`, `unauthorized`, `connected`, `invalidgroup`, `streaming`, `busy`), `hdmi.inputN.status` (`unplugged`, `plugged`, `linked`, `unknown`), `hdmi.inputN.type` (a device kind such as `generic`, `appletv`, `playstation`, `xbox`, `soundbar`...).

Validation [HB] applies to every GET answer before using it (a failure counts as a failed read, not retried): top level is an object; `device` object with non-empty string `name`, string `firmwareVersion`, string `uniqueId`; `execution` object with string `mode`, `hdmiSource` exactly matching `input1`..`input4`, `brightness` a finite number 0..200; `hue` object whose `groups` is an object where every value is an object with a non-empty string `name`; `hdmi` object with `input1`..`input4` each an object with a non-empty string `name`. Answers larger than 100000 bytes are rejected.

### 4.2 Writing

Two endpoints, both `PUT`, JSON body, success = any 2xx (body ignored):

- `PUT /api/v1/execution` with a partial execution object. Bodies [HB] sends, one key per request:
  - `{"mode": "<video|music|game|passthrough|powersave>"}`
  - `{"brightness": <0..200 integer>}`
  - `{"hdmiSource": "input<1..4>"}`
  - `{"<video|music|game>": {"intensity": "<subtle|moderate|high|intense>"}}` (the mode object with only `intensity`; the box merges it)
- `PUT /api/v1/hue` with `{"groupId": "<groupId>"}` to select the entertainment area.

Other execution keys the box accepts ([AIO], not used by [HB]; useful for a richer port): `syncActive`, `toggleSyncActive`, `hdmiActive`, `toggleHdmiActive`, `cycleSyncMode` / `cycleHdmiSource` / `cycleIntensity` (`"next"` / `"previous"`), `incrementBrightness` (delta -200..200), `intensity` (current mode, if syncing), `toggleSyncMode`, `backgroundLighting`, `toggleBackgroundLighting`, `hueTarget`, `preset`. `PUT /api/v1/hue/groups/<id>` with `{"active": bool}` exists too.

## 5. HomeKit mapping

### 5.1 Identity

Each accessory's Homebridge UUID = HAP-NodeJS `uuid.generate(seed)` = SHA-1 of the seed's UTF-8 bytes, hex lowercase, first 32 hex digits grouped 8-4-4-4-12. Seed = **kind name + `uuidSeed`** (empty when absent), no separator. Kind names exactly: `LightBulbAccessory`, `SwitchAccessory`, `PowerSwitchAccessory`, `TVAccessory`, `ModeTVAccessory`, `IntensityTVAccessory`, `EntertainmentTVAccessory`. Neither the IP nor the box's id is part of it.

Vectors (computed by the spec writer):

| Seed | UUID |
|---|---|
| `LightBulbAccessory` | `ad853a47-efc5-2248-fee2-948a82d8330b` |
| `SwitchAccessory` | `b4b0764a-b898-42a0-f446-b300388e9382` |
| `PowerSwitchAccessory` | `ebf74ef2-f931-919e-8837-72e9855e83c6` |
| `TVAccessory` | `f501684e-b1d3-47f7-0122-f2f5d64f6cce` |
| `ModeTVAccessory` | `d7ff0815-d407-977b-0be5-b66f71b9abf5` |
| `IntensityTVAccessory` | `699ca871-6693-4488-2b8e-7d1b8f6f14dc` |
| `EntertainmentTVAccessory` | `e475535c-32c7-fd89-462c-3a75356efc2d` |
| `LightBulbAccessoryLivingRoom` | `d37fd116-0afd-7894-3cc7-865ad29c69a4` |
| `TVAccessoryLivingRoom` | `03467bd9-a1a9-c606-3085-19f7d1bd406b` |

Switching `baseAccessory` from lightbulb to switch makes a new accessory (different seed). Homeswift: use `HueSyncBox:` style ids per its prefix rule, but derive them from the same seed so a migration can map them; the Device Id should be the box's `uniqueId` plus the kind (**Recommendation**).

Display names: `device.name` for every kind except the power switch, `device.name + " Power"`. Names come from the box at first creation; a cached accessory keeps its name.

Accessory Information on every accessory: Manufacturer `Philips`, Model `Sync Box`, FirmwareRevision = `device.firmwareVersion`, SerialNumber = `device.uniqueId` + suffix: lightbulb/switch none, power switch `-power`, HDMI TV `-T`, Mode TV `-M`, Intensity TV `-I`, Entertainment TV `-E`.

Categories: lightbulb = Lightbulb (5); switch and power switch = Switch (8); TVs per their `*Type` option (section 2).

### 5.2 Base lightbulb / switch

- Service: Lightbulb (no subtype) with On and Brightness, or Switch (no subtype) with On. The service's Name = display name.
- On (read, from poll) = mode is `video`, `music` or `game` ("syncing"); false in `passthrough` and `powersave`.
- On (write): if the value equals the characteristic's current value, nothing is sent. True → `{"mode": <defaultOnMode resolved>}`. False → `{"mode": <defaultOffMode>}`.
- Brightness (lightbulb, write): `{"brightness": round(v / 100 * 200)}`, i.e. 2 × v.
- Brightness (read): **[HB] never updates the base lightbulb's Brightness from the box** (only On is refreshed). HomeKit shows the last value it wrote. **Recommendation:** refresh it with round(brightness / 2) like the TV lightbulb does (section 5.4); that changes nothing for a user except correctness.

### 5.3 Power switch

Switch, no subtype. On (read) = mode is anything but `powersave`. On (write, same equal-value skip): true → `{"mode": "passthrough"}`, false → `{"mode": "powersave"}`. Independent of `defaultOnMode`/`defaultOffMode`.

### 5.4 Television accessories (common part)

One accessory per enabled TV, published externally (each needs adding in Home with the bridge's setup code; [HB] logs this hint in its schema header).

Television service (primary role in practice; it is the only Television service) with subtype and service name:

| TV | Television subtype | Service name | Input subtype prefix | Inputs |
|---|---|---|---|---|
| HDMI | `TV` | `TV` | `HDMI ` | 4 |
| Mode | `ModeAccessory` | `Mode` | `MODE ` | 5 |
| Intensity | `IntensityTVAccessory` | `Intensity` | `INTENSITY ` | 4 |
| Entertainment | `EntertainmentTVAccessory` | `Entertainment Area` | `AREA ` | one per `hue.groups` entry |

Characteristics on the Television service:
- Name = display name (`device.name`).
- SleepDiscoveryMode = 1 (always discoverable).
- ConfiguredName = the `<kind>ConfiguredName` config value if set, else a name saved earlier from HomeKit (see below), else `device.name`. Written by HomeKit: if the config value is set, log a warning (text in section 7) and do not save it; otherwise save it as the new name. [HB] saves it in the *base accessory's* cached context under the config key name (`tvAccessoryConfiguredName`, `modeTvAccessoryConfiguredName`, `intensityTvAccessoryConfiguredName`, `entertainmentTvAccessoryConfiguredName`); with `baseAccessory` = `none` it is not saved at all. **Recommendation:** persist per TV in the plugin's own storage.
- Active (read) = 0 in `powersave`; in `passthrough` 1, or 0 when `treatPassthroughAsOffForTv`; 1 in `video`/`music`/`game`.
- Active (write): skip when equal to current; 1 → `{"mode": <defaultOnMode resolved>}`, 0 → `{"mode": <defaultOffMode>}` (same as the base switch).
- ActiveIdentifier: per TV (5.5-5.8).
- RemoteKey (write only), same on all four TVs, using the last polled state:

| Key (HAP value) | Effect |
|---|---|
| ARROW_UP (4) | `{"brightness": min(200, brightness + 50)}` |
| ARROW_DOWN (5) | `{"brightness": max(0, brightness - 50)}` |
| ARROW_LEFT (6) | intensity one step down for the *intensity mode* (below); from `subtle` nothing; an unknown current intensity counts as `intense`, so it goes to `high` |
| ARROW_RIGHT (7) | intensity one step up; from `intense` nothing; unknown counts as `subtle`, so it goes to `moderate` |
| SELECT (8) | next mode with numbering video 1, music 2, game 3, passthrough 4, powersave 5: next = (n mod 4) + 1. So video→music→game→passthrough→video, powersave→music, unknown mode→video. Sends `{"mode": ...}`. |
| PLAY_PAUSE (11) | if syncing → `{"mode": <defaultOffMode>}`, else `{"mode": <defaultOnMode resolved>}` (no equal-value skip) |
| INFORMATION (15) | next HDMI input: input n → input (n mod 4) + 1; sends `{"hdmiSource": "inputN"}` |
| other keys | ignored |

Intensity steps use the order `subtle` 1, `moderate` 2, `high` 3, `intense` 4. The *intensity mode* is the current mode when syncing, else `execution.lastSyncMode`, else `video`. The body is `{"<that mode>": {"intensity": "<new>"}}`. If the state has no object for that mode, nothing is sent.

Input sources: one InputSource service per input, linked to the Television service. For each:
- subtype = prefix + 1-based position, e.g. `HDMI 1`, `MODE 3`, `INTENSITY 4`, `AREA 2` (exact case and space).
- service name (display name) = that subtype lowercased with its first space removed (`hdmi1`, `mode3`, `intensity4`, `area2`).
- ConfiguredName = the input's name with its first letter upper-cased (rest unchanged).
- IsConfigured = 1 (configured), CurrentVisibilityState = 0 (shown), TargetVisibilityState = 0 (shown).
- Identifier = the last character of the subtype as a number (so 1..9; see Gaps for 10+ areas).
- InputSourceType = 3 (HDMI) for all, modes and areas included.
- TargetVisibilityState write (HDMI, Mode, Intensity TVs only, not Entertainment): copy the value to CurrentVisibilityState. Not persisted beyond HAP's cache, never sent to the box.
- Inputs are built once at start from the first state; renames on the box or new areas appear only after a restart.

Optional Lightbulb service on a TV (when `<kind>Lightbulb` is true), no subtype, on the TV accessory:
- On (read) = syncing (video/music/game); On (write) = like the base lightbulb (equal-value skip, defaultOn/OffMode).
- Brightness (read) = round(brightness / 200 × 100) (JavaScript rounding, .5 up); (write) = 2 × v.

### 5.5 HDMI TV

Inputs `HDMI 1`..`HDMI 4` named from `hdmi.inputN.name` (fallback `HDMI N` if missing; validation already requires a name). ActiveIdentifier (read) = N from `execution.hdmiSource` `inputN`. Write: an integer 1..4 → `{"hdmiSource": "inputN"}`; anything else → warning "Ignoring out-of-range HDMI input identifier: <v>", nothing sent.

### 5.6 Mode TV

Inputs `MODE 1`..`MODE 5` = `Video`, `Music`, `Game`, `Passthrough`, `Powersave` (identifiers 1..5). ActiveIdentifier (read) = the mode's number; an unknown mode logs an error "Unknown mode for Mode TV: <mode>" and leaves the value. Write: identifier → `{"mode": "<name>"}`; an unknown identifier makes [HB] send an empty body `{}` (Recommendation: send nothing).

### 5.7 Intensity TV

Inputs `INTENSITY 1`..`INTENSITY 4` = `Subtle`, `Moderate`, `High`, `Intense`. ActiveIdentifier (read) = the number of `execution.<intensity mode>.intensity` (intensity mode as in 5.4); unchanged when that object or value is missing/unknown. Write: `{"<intensity mode>": {"intensity": "<name>"}}`; an unknown identifier makes [HB] send an empty string intensity (Recommendation: send nothing).

### 5.8 Entertainment TV

Inputs `AREA 1`..`AREA n`, in the order of `hue.groups`'s keys as received, named from each group's `name`. ActiveIdentifier (read) = 1-based position of `hue.groupId` among the keys; when not found, n + 1 (matches no input). Write: identifier k → the k-th key; if it exists, `PUT /api/v1/hue` `{"groupId": "<key>"}` (debug log "Switch entertainment area to <name>"); otherwise nothing. Errors: "Failed to switch entertainment area to <name>". Positions depend on key order; a box that reorders its groups moves the mapping.

## 6. Behaviour

### 6.1 Start-up

1. Validate IP and token present (else refuse).
2. One GET of the state. If it fails or is invalid: error "Could not get state from sync box on initialization. This error is not recoverable, ensure the sync box is online and the API token is correct and restart the plugin.", **no accessories and no polling** until restart. **Recommendation:** retry with backoff instead (Homeswift `Backoff`), keeping cached accessories meanwhile.
3. Build the enabled accessories (section 1), reusing cached ones by UUID; register new bridged ones; remove cached bridged accessories whose UUID is no longer produced (e.g. a TV or base type turned off, or `uuidSeed` changed). Publish the TVs externally.
4. Apply the state once, then start polling.

### 6.2 Polling

Every `updateIntervalInSeconds` (default 5 s) GET the state and push it to every accessory (only characteristic updates; no structure changes). A tick is skipped when the previous one is still running. A failed poll logs a warning ("Failed to get state from Sync Box: <reason>") and leaves every characteristic as it was (no "not responding" is raised by [HB]; Recommendation: mark not responding after a few consecutive failures).

### 6.3 Requests, retries, serialisation

- All requests (polls and writes) go through **one lock**: one at a time, in order. A caller waits at most 15 s for its turn; one held at most 20 s.
- Per attempt timeout 8 s; per request total budget 12 s.
- Transport failures (connection, TLS, timeout) are retried up to 3 more times with backoff 1 s, 2 s, 4 s, but not when the next backoff would pass the 12 s budget. A non-2xx answer or an invalid state is **not** retried.
- A non-2xx answer logs "Error: <status> - <statusText>. <first 500 chars of body>".
- [AIO] for comparison: total timeout 10 s, 1 connection per host, no retries.

### 6.4 Writes

HomeKit writes are fire-and-forget: the handler returns success immediately and the request is queued; failures are only logged ("Error updating execution: <reason>" / "Error updating hue: <reason>"). There is **no refresh after a write**; the next poll (≤ 5 s) brings the truth, and until then the characteristic keeps the written value. **Recommendation:** after a successful write, poll once at once (or apply the expected value) so dependent characteristics (power switch, TV Active, Mode TV input) update quickly.

### 6.5 Edge cases

- With `defaultOffMode` = `passthrough`, turning a TV off while the box is in passthrough sends passthrough again: the TV stays on (unless `treatPassthroughAsOffForTv`).
- The equal-value skip compares with HomeKit's cached value, not the box: after a missed poll a write may be dropped though the box differs.
- TV Active 1 while in passthrough (not treated as off) is skipped, so turning the TV "on" from passthrough does not start syncing; Play/Pause does.
- `lastSyncMode` empty → `video`.
- Mode `powersave` with the TV off: SELECT goes to `music`.
- HDMI names, mode/intensity lists and areas are fixed at start.

### 6.6 Optional HTTP API ([HB]; Recommendation: drop it in Homeswift, whose MCP server and web UI cover it, or keep it behind the same keys)

When `apiServerEnabled`: HTTP (plain) on `0.0.0.0:<apiServerPort>`. Refuses to start (error log) if the port is missing or `apiServerToken` is not a string of at least 32 characters. Each request: the `Authorization` header must equal the token exactly (raw token, no `Bearer`), compared in constant time, checked before reading the body; else 401 `{"error": "Unauthorized"}`. Body cap 100000 bytes (413 `{"error": "Payload too large."}`); request timeout 10 s. Any path is accepted (README calls it `/state`).
- `GET` → 200 with the box's full state JSON (as read, not validated further); errors 500 `{"error": "An error occurred while processing your request."}`.
- `POST` with a JSON object that may hold `execution` and/or `hue`:
  - empty body → 400 `Body missing.`; bad JSON → 400 `Body malformed.`; not an object → 400 `Body must be a JSON object.`
  - `execution` must be an object with at least one key, every key one of: `mode` (the five modes), `brightness` (number 0..200), `hdmiSource` (`input1`..`input4`), `video`/`game`/`music` (an object with exactly one key `intensity` from the four). Error texts: `execution must be an object.`, `execution.mode must be one of: video, music, game, passthrough, powersave.`, `execution.brightness must be a number between 0 and 200.`, `execution.hdmiSource must match input1 through input4.`, `execution.<k> must be an object.`, `execution.<k> may only contain an 'intensity' field.`, `execution.<k>.intensity must be one of: subtle, moderate, high, intense.`, `execution.<k> is not a recognized or settable field.`, `execution must contain at least one recognized field.`
  - `hue` must be an object with exactly the key `groupId`, a non-empty string that is a key of the box's current `hue.groups` (read live). Errors: `hue must be an object.`, `hue may only contain a groupId field.`, `hue.groupId must be a non-empty string.`, `hue.groupId does not match a known entertainment area.`
  - Then PUT execution, then PUT hue, then GET; answer 200 with the new state. All errors are `{"error": "<text>"}`.
- Other methods → 405, empty body. Logs "API server started." once listening; bind errors are logged, not fatal.

## 7. Logging

Info: "Initializing platform: <name>", "Finished initializing platform: <name>", "Loading accessory from cache: <kind>", "Registering new accessory: <kind>", "Removing existing accessory from cache: <kind>", "API server started.". Warn: a deprecation notice under Homebridge 1.x (not relevant), "Failed to get state from Sync Box: <reason>", the ConfiguredName text "<key> is set in the config, therefore it cannot be changed by HomeKit. Please change it in the Homebridge config. Alternatively remove the config and manually configure in HomeKit (not recommended).", the out-of-range HDMI identifier. Error: missing configuration, start-up failure (6.1), HTTP status errors, write failures, unknown Mode TV mode. Debug: every request URL and options **with the Authorization header replaced by `[REDACTED]`**, retries with their delay, the discovered state with `device.ipAddress`, `device.wifi.ssid` and `hue.bridgeIpAddress` replaced by `[REDACTED]`, each characteristic change.

Never log the access token, the registration body's answer (it contains the token), or the API server token (Homeswift rule as well).

## 8. Test vectors (invented ids)

State answer (trimmed to what matters; a fake box should return this for `GET /api/v1/`):

    { "device": { "name": "Lounge Sync Box", "deviceType": "HSB2", "uniqueId": "A1B2C3D4E5F6",
                  "apiLevel": 10, "firmwareVersion": "2.4.2", "ipAddress": "192.0.2.50",
                  "wifi": { "ssid": "ExampleNet", "strength": 3 } },
      "hue": { "bridgeUniqueId": "B00000000001", "bridgeIpAddress": "192.0.2.10",
               "groupId": "22222222-0000-4000-8000-000000000002",
               "groups": { "11111111-0000-4000-8000-000000000001": { "name": "TV area", "numLights": 3, "active": false },
                           "22222222-0000-4000-8000-000000000002": { "name": "cinema", "numLights": 5, "active": true } },
               "connectionState": "streaming" },
      "execution": { "mode": "music", "syncActive": true, "hdmiActive": true, "hdmiSource": "input3",
                     "hueTarget": "22222222-0000-4000-8000-000000000002", "brightness": 150,
                     "lastSyncMode": "music",
                     "video": { "intensity": "moderate", "backgroundLighting": true },
                     "game":  { "intensity": "intense",  "backgroundLighting": false },
                     "music": { "intensity": "high", "palette": "happyEnergetic" }, "preset": null },
      "hdmi": { "input1": { "name": "Apple TV", "type": "appletv", "status": "linked", "lastSyncMode": "video" },
                "input2": { "name": "HDMI 2", "type": "generic", "status": "unplugged", "lastSyncMode": "video" },
                "input3": { "name": "console", "type": "playstation", "status": "linked", "lastSyncMode": "game" },
                "input4": { "name": "HDMI 4", "type": "generic", "status": "unplugged", "lastSyncMode": "video" } } }

Expected HomeKit values with defaults: base lightbulb On = true; power switch On = true; every TV Active = 1; HDMI TV ActiveIdentifier = 3, input ConfiguredNames `Apple TV`, `HDMI 2`, `Console`, `HDMI 4`; Mode TV ActiveIdentifier = 2; Intensity TV ActiveIdentifier = 3 (music is `high`); Entertainment TV inputs `TV area` (1), `Cinema` (2), ActiveIdentifier = 2; TV lightbulb Brightness = 75; SerialNumbers `A1B2C3D4E5F6`, `A1B2C3D4E5F6-power`, `A1B2C3D4E5F6-T`, `-M`, `-I`, `-E`.

Writes from that state (path, body):

| HomeKit action | Request |
|---|---|
| Base lightbulb On → false | `PUT /api/v1/execution` `{"mode":"passthrough"}` |
| Base lightbulb On → true (state was passthrough, defaultOnMode `lastSyncMode`) | `{"mode":"music"}` |
| Lightbulb Brightness → 40 | `{"brightness":80}` |
| Power switch → false | `{"mode":"powersave"}` |
| HDMI TV ActiveIdentifier → 1 | `{"hdmiSource":"input1"}` |
| HDMI TV ActiveIdentifier → 7 | nothing, warning |
| Mode TV ActiveIdentifier → 3 | `{"mode":"game"}` |
| Intensity TV ActiveIdentifier → 4 | `{"music":{"intensity":"intense"}}` |
| Entertainment TV ActiveIdentifier → 1 | `PUT /api/v1/hue` `{"groupId":"11111111-0000-4000-8000-000000000001"}` |
| Remote ARROW_UP | `{"brightness":200}` |
| Remote ARROW_DOWN | `{"brightness":100}` |
| Remote ARROW_RIGHT | `{"music":{"intensity":"intense"}}` |
| Remote ARROW_LEFT | `{"music":{"intensity":"moderate"}}` |
| Remote SELECT | `{"mode":"game"}` |
| Remote PLAY_PAUSE | `{"mode":"passthrough"}` |
| Remote INFORMATION | `{"hdmiSource":"input4"}` |

In passthrough with `lastSyncMode` `video`: ARROW_RIGHT sends `{"video":{"intensity":"high"}}` (video was `moderate`).

Registration exchange (fake box): first `POST /api/v1/registrations` `{"appName":"homeswift","instanceName":"Homeswift"}` → 400 (status not documented; any non-200) `{"code":16,"message":"Invalid State"}`; after a simulated button press → 200 `{"registrationId":"7","accessToken":"EXAMPLE-TOKEN-0123456789abcdef"}`. Bad token on `GET /api/v1/` → non-200 with code 1, 2 or 3 (status assumed 401).

Brightness conversions: HK→box 0→0, 1→2, 50→100, 100→200. Box→HK 0→0, 1→1 (0.5 rounds up), 99→50, 100→50, 150→75, 199→100, 200→100.

## 9. What a drop-in must reproduce exactly

- Platform name `PhilipsHueSyncBoxPlatform` and every config key/default of section 2, including `lastSyncMode` resolution and the lowercased `*Type` matching (so `TV` works).
- Accessory seeds (kind + `uuidSeed`) and the set of kinds per option, so the HomeKit identity of an existing install survives a switch from Homebridge (with Homeswift's own id mapping).
- Service subtypes: Television `TV` / `ModeAccessory` / `IntensityTVAccessory` / `EntertainmentTVAccessory`; inputs `HDMI n` / `MODE n` / `INTENSITY n` / `AREA n` with identifiers n. HomeKit scenes reference these.
- Input numbering: modes video 1, music 2, game 3, passthrough 4, powersave 5; intensities subtle 1, moderate 2, high 3, intense 4; areas by key order; HDMI by input number.
- On/Active semantics (syncing vs not powersave, `treatPassthroughAsOffForTv`), the power switch's passthrough/powersave pair, the remote-key table, the ±50 brightness step and the 0-200 ↔ 0-100 conversion.
- The exact PUT bodies of section 4.2 and the Bearer header; TLS pinned to the Hue Sync Box CA.
- SerialNumber suffixes, Manufacturer `Philips`, Model `Sync Box`.
- Serialised requests (one at a time to the box).

## 10. Gaps

- [HB] has no registration or discovery; section 3.1/3.2 come from [AIO]/[HA]. The HTTP status code carrying `{"code":16}` and the unauthorized codes are not stated by either source (they only read the JSON body when the content type is JSON). Treat any non-200 JSON body with a `code` as an error.
- The "5 seconds" registration window is from [HB]'s README only.
- Whether the box rejects a TLS server name other than its `uniqueId` (SNI) is not documented; [HB] connects by IP with no SNI and works, [AIO] sends the uniqueId.
- Entertainment area selection: [HB] writes `hue.groupId`; [AIO] documents `execution.hueTarget` as the selected area (Hue bridge API v2 entertainment configuration id). With bridge v2 setups the `hue.groupId` write may be legacy; the source still uses it. A port could read `hueTarget` too and write both if `hue.groupId` fails (untested).
- Input identifiers come from the last character of the subtype: with 10 or more entertainment areas, identifiers repeat (`AREA 10` → 0, `AREA 11` → 1). Recommendation: use n for the identifier (same for 1..9, so no change for real installs).
- The base lightbulb's Brightness is never read back (5.2).
- No not-responding state on failures; start-up failure is final (6.1, 6.2).
- `4.0.0-beta.1` of [HB] was not read; it may change behaviour.
- `device.apiLevel` minimum (7) is from [AIO]; [HB] doesn't check it.
- Hue Play HDMI Sync Box 8K and the Sync TV/screen products ([AIO]'s "HueSyncDevice") likely share the API; [HB] doesn't mention them. 8K boxes report a different `deviceType` (not seen in sources).
- [HB] logs nothing about TLS failures specifically; a wrong/foreign certificate surfaces as a generic failed poll.
