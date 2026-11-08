# SwitchBot over Bluetooth LE: functional specification (clean room)

Written by the spec writer; contains no source code. It extends docs/clean-room/SwitchBot.md (the cloud plugin,
`Plugins/SwitchBot`), whose §11 lists Bluetooth as a gap. Everything below is behaviour, names and data, in the spec
writer's words. Byte values are the interface and are quoted. Where the sources disagree, §9 says which one this spec
follows and why. Nothing here is guessed: a field no source pins is listed as unknown, and a device whose frames no source
pins stays on the cloud (§10).

## 0. Provenance

| Abbrev. | Source | Commit read | Licence |
|---|---|---|---|
| BLE | OpenWonderLabs/SwitchBotAPI-BLE, the published BLE documentation (`README.md`, `devicetypes/*.md`) | `87fcc47bda5e0adcda59f650ebd5bfe45709aadf` (2026-10-30) | No licence file. Public vendor documentation: cited, not copied. Several pages were edited to describe what pySwitchbot does and say so; they are still the published docs. |
| NS | OpenWonderLabs/node-switchbot 6.0.6 (`src/settings.ts`, `src/ble.ts`, `src/utils/*.ts`, `src/devices/*.ts`) | `cd828e48db89a03943c4a74fc491f4825fed11a0` | `LICENSE` file: ISC, "Copyright (c) 2020 SwitchBot". `package.json` says `MIT`. The two disagree (as SwitchBot.md §0 already notes). |
| HB | OpenWonderLabs/homebridge-switchbot 5.2.12 (`config.schema.json`, `README.md`): facts only (configuration keys, where users find keys) | `28fd83bb8951ee82556a8d94fb203931da9aaa26` | ISC, "Copyright (c) 2023 SwitchBot" |

NS and BLE both cite pySwitchbot (sblibs/pySwitchbot) as their reference. The spec writer did not read pySwitchbot. Where a
fact appears only in NS's pySwitchbot-derived code, it is marked "(NS only)".

## 1. Scope and configuration

- Adds a local transport beside the cloud for the device types in §3 and §5. The cloud plugin stays as it is. Every
  device type not listed stays on the cloud.
- Transport choice per device. The existing keys are read as they are (SwitchBot.md §2.2, §4.5):
  - `connectionType` `"BLE"`: Bluetooth only. A device that cannot be reached shows as unreachable (or "Offline as Off").
  - `"BLE/OpenAPI"`: Bluetooth first. On a Bluetooth failure (not found in scan, connect or reply timeout, a non-OK status) the
    same command or read goes to the cloud, when token and secret are set.
  - `"OpenAPI"` (the default when token and secret are set), `"Disabled"`: unchanged.
  - 5.x shape (HB `config.schema.json`): per-device `connectionPreference` `"ble"` / `"openapi"` / `"auto"` maps to
    `BLE` / `OpenAPI` / `BLE/OpenAPI`. Platform `enableBLE: false` (5.x) and per-device `disablePlatformBLE` (4.x) turn
    Bluetooth off.
- Other keys read (SwitchBot.md §2.2): `customBLEaddress` (a MAC to match instead of the one derived from `deviceId`),
  `scanDuration` (seconds, default 1), `maxRetry` (Bluetooth attempts, default 5), `encryptionKey` (32 hex characters) and
  `keyId` (2 hex characters). `encryptionKey` and `keyId` are secrets; `encryptionKey` already matches a secret-named key.
  5.x `blePollingEnabled` (default true) and `blePollIntervalMs` (default 600000, minimum 60000) set a periodic connected
  status read as a fallback to advertisements (HB `config.schema.json`).
- Bot password (§7.4): no Homebridge configuration key exists in these sources. If the implementer adds one, it is a
  Homeswift Accessory Setting under a secret-named key.
- Identity: the cloud `deviceId` is the device's MAC, 12 upper-case hex characters (SwitchBot.md §2.2, §3.2). A device found
  by Bluetooth is matched to its cloud or configured entry by that MAC. Accessory ids do not change when the transport changes.
- The Bluetooth stack is not part of this spec: on Linux BlueZ, on macOS CoreBluetooth. The protocol needs: an active
  scan (scan responses are required, §2.1), per-advertiser manufacturer data and 16-bit service data, connect, service and
  characteristic discovery, write with response, and notifications. macOS does not expose peripheral addresses, so the
  MAC must come from the manufacturer data (§2.2) (NS `src/ble.ts`, the MAC resolution comment).

## 2. Advertisements

### 2.1 Where the data is (BLE `README.md` "UUID Update Notes", `devicetypes/curtain3.md`, `devicetypes/lock.md`)

| Item | Value | Packet |
|---|---|---|
| Manufacturer specific data (AD type `0xFF`) company id | `0x0969`, sent little-endian (`69 09` on air). Before Bot 6.4, Curtain 4.6 and Meter 2.7 it was `0x0059` (Nordic). | ADV_IND |
| Service data (AD type `0x16`), 16-bit UUID | `0xFD3D` (`3D FD` on air). Before those firmware versions `0x000D`. | SCAN_RSP |
| Old 128-bit service UUID list | `cba20d00-224d-11e6-9fb8-0002a5d5c51b`, removed by those firmware versions | SCAN_RSP |

- NS accepts service data UUIDs `fd3d` and `000d` (short or expanded with the Bluetooth base UUID) (NS `src/ble.ts`, discovery
  handler). An advertisement without SwitchBot service data is ignored by NS. A Plug Mini, bulb or strip's state is in the
  manufacturer data, so both packets of one address must be merged before parsing.
- "Payload" below is the manufacturer data after the 2 company-id bytes. "Service data" is the service-data value after the
  2 UUID bytes. BLE's tables sometimes count from the AD length byte or from the company id; every offset here was converted
  to these two bases.
- Sensors may advertise as non-connectable. NS keeps non-connectable advertisements only for the passive sensor models
  (Meters, Contact, Motion, Leak) (NS `src/ble.ts`; `src/utils/sensor-advertisement.ts`, `isPassiveSensorModel`).

### 2.2 Common fields

- Service data byte 0: bit 7 reserved ("Enc type" in older pages), bits 6–0 the model code (§2.3). Model = byte 0 & `0x7F`
  (BLE `README.md`; NS `src/ble.ts`, `parseServiceData`).
- Service data byte 2: bits 6–0 battery 0–100 % for every type (BLE `devicetypes/meter.md`, `bot.md`, `curtain.md`).
- Payload bytes 0–5: the device MAC in display order (`01 02 03 04 05 06` is `01:02:03:04:05:06`) (BLE `devicetypes/plugmini.md`;
  NS `src/utils/index.ts`, `extractMacFromManufacturerData`).
- Payload byte 6, for types with a sequence number (Plug Mini, Color Bulb, Strip Light, Lock family, Blind Tilt): 1–255,
  incremented when the advertised state changes, 255 wraps to 1. A change means a new state.

### 2.3 Model codes (BLE `README.md` "Device Types"; NS `src/settings.ts`, `DEVICE_MODEL_MAP`)

Each product has two codes (pairing mode and normal mode, per BLE `curtain.md`, `contactsensor.md`); both mean the same product.

| Product | Codes (hex) | This spec |
|---|---|---|
| Bot | `48` (`H`) | §3.1, §5.1 |
| Curtain | `63` `c`, `43` `C` | §3.2, §5.2 |
| Curtain 3 | `7B` `{`, `5B` `[` | §3.2, §5.2 |
| Meter | `54` `T`, `74` `t` | §3.3 |
| Meter Plus | `69` `i`, `49` `I` | §3.3 |
| Indoor/Outdoor Thermo-Hygrometer (Outdoor Meter) | `77` `w`, `57` `W` | §3.3 |
| Meter Pro | `34` `4`, `14` | §3.3 |
| Meter Pro CO2 | `35` `5`, `15` | §3.3 |
| Contact Sensor | `64` `d`, `44` `D` | §3.4 |
| Motion Sensor | `73` `s`, `53` `S` | §3.5 |
| Plug Mini (US) | `67` `g`, `47` `G` | §3.6, §5.3 |
| Plug Mini (JP) | `6A` `j`, `4A` `J` | §3.6, §5.3 |
| Smart Lock (and Lock Lite: `2D` `-`, `0D`) | `6F` `o`, `4F` `O` | §3.7, §5.6 |
| Smart Lock Pro | `24` `$`, `04` | §3.7, §5.6 |
| Blind Tilt | `78` `x`, `58` `X` | §3.8, §5.5 |
| Color Bulb | `75` `u`, `55` `U` | §3.9, §5.4 |
| Strip Light | `72` `r`, `52` `R` | §3.9, §5.4 |
| Hub 2 | `76` `v`, `56` `V` | stays on the cloud (§10) |

NS also maps codes the BLE docs do not list (`01`/`02` Hub 2/3, `11` Lock Pro, `p` Strip Light, `k` Keypad…) "kept from
earlier node-switchbot releases" (NS `src/settings.ts`). They are not used here: an unknown code is ignored.

## 3. Advertisement layouts per type

Bit numbering: bit 7 is the most significant. "SD" = service data, "MP" = manufacturer payload (§2.1).

### 3.1 Bot (BLE `devicetypes/bot.md`, "(New) Broadcast Message")

| Byte | Field |
|---|---|
| SD 1 bit 7 | Mode: 0 press ("one state mode"), 1 switch ("on/off state mode") |
| SD 1 bit 6 | State: **0 on, 1 off** (meaningful in switch mode) |
| SD 1 bit 5 | Encryption type (0: algorithm 1, the password scheme of §7.4) |
| SD 1 bit 4 | Data commit flag |
| SD 1 bits 3–0 | Groups D, C, B, A |
| SD 2 bit 7 | Needs a time sync; bits 6–0 battery |

### 3.2 Curtain, Curtain 3 (BLE `devicetypes/curtain.md`, `devicetypes/curtain3.md`)

| Byte | Field |
|---|---|
| SD 1 bit 7 | Connection allowed (1 yes) |
| SD 1 bit 6 | Calibrated (1 yes; 0 needs calibration) |
| SD 2 bits 6–0 | Battery |
| SD 3 bit 7 | Moving (1) or stationary (0) |
| SD 3 bits 6–0 | Position %, 0 = open, 100 = closed (clamp to 0–100) |
| SD 4 bits 7–4 | Light level 1–10 |
| SD 4 bits 3–0 | Device chain length (curtains coupled as a group) |
| SD 5 (Curtain 3 only) | Crash type, documented as not connected |

The Curtain 3 page's table repeats rows and shows battery inside byte "5" of the AD structure. Its AD length (`0x09`: type,
2 UUID bytes, 6 data bytes) and its field list give the Curtain layout above plus one byte. The position direction (0 open)
follows from the open and close commands (§5.2) and the cloud's `slidePosition` (SwitchBot.md §6.4: HomeKit
CurrentPosition = 100 − position).

### 3.3 Meter family (BLE `devicetypes/meter.md`, "(New) Broadcast Message", "Manufacturer Data", "Outdoor…")

Temperature and humidity are three bytes in the same encoding wherever they appear:

| Byte of the triple | Field |
|---|---|
| 0, bits 3–0 | Tenths of a degree, 0–9 (bits 7–6: temperature alert, bits 5–4: humidity alert, in the SD form) |
| 1, bit 7 | Sign: 1 = zero or above, 0 = below zero |
| 1, bits 6–0 | Whole degrees °C, 0–127 |
| 2, bit 7 | Display unit on the device: 0 °C, 1 °F (the value is still °C) |
| 2, bits 6–0 | Relative humidity 0–99 % |

Temperature = sign × (whole + tenths / 10), in °C.

- Where the triple is: MP bytes 8–10 when the payload has at least 11 bytes; otherwise SD bytes 3–5 when the service data has
  at least 6 bytes (NS `src/utils/sensor-advertisement.ts`, `parseMeter`; BLE `meter.md` "Manufacturer Data": "reads them
  from here first and falls back to the Service Data").
- The Outdoor Meter's service data is only 3 bytes (model, status, battery); its readings are only in MP 8–10 (BLE `meter.md`
  "Outdoor Temperature/Humidity Sensor", whose sample is §11.1).
- Meter Pro CO2: CO2 ppm is MP bytes 13–14, big-endian, when the payload has at least 15 bytes. Range 400–9999; a larger
  value is a parse artefact and is dropped (BLE `meter.md`; NS `parseMeter`).
- A triple that decodes to 0.0 °C and 0 % is treated as "no reading" (NS `decodeTempHumidity`).
- Battery: SD byte 2.
- Not in the advertisement: the Meter Pro's light level, and the Hub 2's readings.

### 3.4 Contact Sensor (BLE `devicetypes/contactsensor.md`; NS `parseContact`)

Service data (9 bytes):

| Byte | Field |
|---|---|
| SD 1 bit 7 | Scope tested; bit 6 motion (PIR): 1 someone moving |
| SD 2 bits 6–0 | Battery |
| SD 3 bit 7, bit 6 | Bit 16 of the PIR time and of the HAL time (below) |
| SD 3 bits 2–1 | Door ("HAL") state: 0 closed, 1 open, 2 open and timed out (left open) |
| SD 3 bit 0 | Light: 0 dark, 1 light |
| SD 4–5 | Seconds since the last motion, low 16 bits, big-endian |
| SD 6–7 | Seconds since the last door change, low 16 bits, big-endian |
| SD 8 bits 7–6 | Entrance counter (1–3, cycles); bits 5–4 exit counter; bits 3–0 button press counter (1–15) |

Manufacturer form (NS only, used when the payload has at least 13 bytes, and then preferred): MP 7 bit 7 motion, bit 6 light,
bit 5 timed out, bit 4 open. Timed out counts as open (NS comment). A changed button counter means the button was pressed.

### 3.5 Motion Sensor (BLE `devicetypes/motionsensor.md`; NS `parseMotion`)

| Byte | Field |
|---|---|
| SD 1 bit 6 | Motion: 1 someone moving |
| SD 2 bits 6–0 | Battery |
| SD 3–4 | Seconds since the last motion, low 16 bits; SD 5 bit 7 is bit 16 |
| SD 5 bit 5, bit 4 | LED enabled, IoT enabled |
| SD 5 bits 3–2 | Sensing distance: 00 long, 01 middle, 10 short |
| SD 5 bits 1–0 | Light: 01 dark, 10 bright |

Manufacturer form (NS only, payload of at least 8 bytes, preferred): MP 7 bit 6 motion, bit 5 bright.

### 3.6 Plug Mini US and JP (BLE `devicetypes/plugmini.md`, manufacturer data of ADV_IND)

| Byte | Field |
|---|---|
| MP 6 | Sequence number |
| MP 7 | Power: `0x80` on, `0x00` off (bit 7) |
| MP 8 | bit 0 delay set, bit 1 timer set, bit 2 UTC time synced |
| MP 9 | Wi-Fi RSSI (signedness and sign convention not stated) |
| MP 10 bit 7 | Overload (more than 15 A) |
| MP 10 bits 6–0, MP 11 | Load power, 15 bits big-endian. **Unit not stated by any source**: do not show it as watts from Bluetooth; power and energy stay on the cloud. |

### 3.7 Lock and Lock Pro (BLE `devicetypes/lock.md`)

Lock status values (both families): 0 locked, 1 unlocked, 2 locking, 3 unlocking, 4 locking stopped (jammed), 5 unlocking
stopped (jammed), 6 not fully locked (EU lock type), 7 half locked (Lock Ultra EU). The status is invalid while not calibrated.

Smart Lock and Lock Lite:

| Byte | Field |
|---|---|
| SD 2 bits 6–0 | Battery (SD 1 reserved) |
| MP 6 | Sequence number |
| MP 7 bit 7 | Calibrated |
| MP 7 bits 6–4 | Lock status |
| MP 7 bit 3, bit 2 | Door update source (0 primary, 1 secondary lock); door open (1) |
| MP 8 | bit 7 double lock mode, bit 5 door-left-open alarm, bit 4 unlocked-too-long alarm, bit 1 auto-lock paused |

The Lock page's table counts from the AD length byte and gives the MAC as "Byte 7~13", seven bytes for a six-byte MAC; read
literally it puts the lock info one byte later. The offsets above put the sequence number right after the MAC, as the same
page's Lock Pro section, the Plug Mini, bulb and strip pages all do. Because of this discrepancy the connected lock info read
(§5.6), whose layout is unambiguous, is the authority after every command and on start; the advertisement only triggers it
when the sequence number changes. An implementation must have a fixture from a real Lock before trusting MP 7 alone.

Smart Lock Pro (offsets stated by the page from the payload start):

| Byte | Field |
|---|---|
| MP 6 | Sequence number |
| MP 7 bit 7 | Calibrated; bits 6–3 lock status |
| MP 8 | bits 7–6 updated from secondary lock, bit 5 door open (from secondary), bit 4 door open, bit 3 auto-lock paused |
| MP 9 bits 6–0 | Battery |
| MP 10 | bit 7 double lock, bit 6 this is the secondary lock, bit 5 manual unlock linkage |
| MP 11 | bit 7 door-left-open alarm, bit 6 unlocked alarm, bit 5 low temperature, bits 2 and 1 left / right battery compartment |

NS parses the lock from service data byte 1 (`src/ble.ts`), where BLE says the byte is reserved. Not followed (§9).

### 3.8 Blind Tilt (BLE `devicetypes/blindtilt.md`)

| Byte | Field |
|---|---|
| SD 2 bits 6–0 | Battery |
| MP 6 | Sequence number |
| MP 7 bit 0 | Calibrated |
| MP 8 bit 7 | Moving; bits 6–0 tilt 0–100: 0 closed down, 50 open, 100 closed up |
| MP 9 bits 7–4 | Light level |

Mapping to the cloud's terms (SwitchBot.md §6.5), arithmetic from the stated meaning: openness = 100 − 2 × |tilt − 50|,
direction `down` when tilt < 50, `up` when tilt > 50 (either at 50). The reverse: (`down`, h) → tilt = h / 2;
(`up`, h) → tilt = 100 − h / 2, rounded to an integer.

### 3.9 Color Bulb and Strip Light (BLE `devicetypes/colorbulb.md`, `devicetypes/ledstriplight.md`)

| Byte | Color Bulb | Strip Light |
|---|---|---|
| MP 6 | Sequence number | same |
| MP 7 | bit 7 on, bits 6–0 brightness 1–100 % | same |
| MP 8 | bit 7 delay, bits 6–4 network (0 Wi-Fi connecting, 1 IoT connecting, 2 IoT connected), bit 3 on-state preset, bits 2–0 mode: 1 white, 2 colour, 3 dynamic | bits 7, 6–4 as bulb; bits 3–0 mode: 2 colour, 3 scene, 4 music, 5 controller |
| MP 9– | bit 7 RSSI bad, bits 6–0 dynamic rate; MP 10 bits 7–2 loop index | MP 9–14: up to eight 2-bit-per-channel colours; MP 15 last fault code |

Hue, saturation and colour temperature are not in the advertisement; read them with the state command (§5.4).

## 4. GATT

### 4.1 Service and characteristics (BLE `bot.md`, `curtain.md`, `plugmini.md`; NS `src/settings.ts`)

| Role | UUID |
|---|---|
| Service | `cba20d00-224d-11e6-9fb8-0002a5d5c51b` |
| Write (requests, "RX") | `cba20002-224d-11e6-9fb8-0002a5d5c51b` |
| Notify (responses, "TX") | `cba20003-224d-11e6-9fb8-0002a5d5c51b` |

(BLE `meter.md` prints the service as `88cba20d00-…`; the stray `88` is a typo, every other page and NS agree.)

### 4.2 Exchange (BLE "BLE Communication Data Message Basic Format"; NS `src/ble.ts`, `exchangeLocked`, `sendCommand`)

- One request, one response. Messages are 1–20 bytes (MTU 20).
- Subscribe to notifications on `…0003…`, start waiting, then write the request to `…0002…` with response. The response is
  the next notification. A backend without notifications reads `…0003…` instead (NS).
- One exchange at a time per device. Reply timeout 5 s; connect timeout 10 s; disconnect after 8.5 s idle so a burst of
  commands shares a connection (NS `persistentConnectionMs`). Retries: up to `maxRetry` attempts (§1); NS's own default is
  3 attempts with backoff from 100 ms to 5 s (NS `DEFAULTS`).
- A disconnect forgets the encryption session (§7.2) (NS `dropConnectionState`).

### 4.3 Request frame (BLE `bot.md` "REQ message")

| Byte | Field |
|---|---|
| 0 | `0x57`, fixed |
| 1 | bits 7–6 version (0), bits 5–4 encryption mode (0 none, 1 = Bot password, §7.4), bits 3–0 command: `0x1` action, `0x2` get basic info, `0x3` set basic info, `0x8`/`0x9` timers, `0xF` extended (byte 2 is then the sub-command) |
| 2– | Payload |

### 4.4 Response status, byte 0 (BLE `bot.md`, `meter.md`, `curtain.md`, `contactsensor.md`, `lock.md`)

| Code | Meaning | Handling |
|---|---|---|
| `0x01` | OK | success |
| `0x02` | Error while executing | failure |
| `0x03` | Busy | failure, retryable |
| `0x04` | Protocol version incompatible | failure |
| `0x05` | Command not supported (a Bot in add-on mode answers `05 48 C0`) | failure, no state change, logged |
| `0x06` | Low battery (the command was executed, per `lock.md`) | success, log low battery |
| `0x07` | Device is encrypted (password or key needed) | failure: "password required" |
| `0x08` | Device is unencrypted | failure |
| `0x09` | Password error | failure: "wrong password"; do not retry |
| `0x0A` | Encryption method not supported | failure |
| `0x0B`, `0x0C` | Mesh device not found; network connection failed | failure |
| `0x0D` | Not supported in the current mode | failure |
| `0x0E` | Disconnected from a device that must stay connected | failure |

Bytes 1– are the payload of the reply. NS accepts `0x05` as acknowledged (`validateCommandResult`); this spec follows BLE (§9).

## 5. Commands (hex, before encryption)

### 5.1 Bot (BLE `bot.md` "0x01 Execute an Action"; NS `src/settings.ts`)

| Action | Request |
|---|---|
| Press (push and pull back) | `57 01 00` |
| On (switch mode) | `57 01 01` |
| Off (switch mode) | `57 01 02` |
| Basic info | `57 02` → status, battery, firmware, … |

Success replies `01 FF 00`. With a password, §7.4. The cloud plugin's `doublePress`/`pushRatePress`/`mode` behaviour
(SwitchBot.md §2.3) is unchanged; only the transport differs. The Bot's long-press and timer commands are not used.

### 5.2 Curtain, Curtain 3 (BLE `curtain.md`/`curtain3.md` "0x45"; NS `src/settings.ts`, `src/devices/wo-curtain.ts`)

`57 0F 45 01 05 SS PP`: function `01` action, `05` whole device chain, `SS` speed, `PP` target position % (0 open, 100 closed).

| Action | Request |
|---|---|
| Open | `57 0F 45 01 05 FF 00` |
| Close | `57 0F 45 01 05 FF 64` |
| Go to `PP` | `57 0F 45 01 05 FF PP` |
| Pause | `57 0F 45 01 00 FF` |

- Speed: the Curtain page fixes byte `SS` at `0xFF`. The Curtain 3 page documents `0x00` high speed and `0x01` low speed; NS
  sends `0xFF` to both by default (`setPosition(…, speed = 255)`). This spec sends `0xFF` (normal) and, for the cloud
  plugin's silent mode (`setOpenMode`/`setCloseMode` `"1"`, SwitchBot.md §6.4), `0x01` on a Curtain 3 only. The Curtain's
  silent speed is not documented: a Curtain set to silent is moved over the cloud when the cloud is available, else at `0xFF`.
- HomeKit TargetPosition h → `PP` = 100 − h. Reply to the action: status, then the current position of device 0 and device 1.
- Basic info `57 02`: battery, firmware, chain length, state 1 (bit 3 fault), state 2 (bit 3 solar panel, bit 2 calibrated,
  bits 1–0 motion: 0 static, 1 opening, 2 closing), position %, timer count (BLE `curtain.md` "0x02").

### 5.3 Plug Mini US and JP (BLE `plugmini.md` "0x570f5001", "0x570f5101")

| Action | Request | Reply |
|---|---|---|
| On | `57 0F 50 01 01 80` | `01 80` |
| Off | `57 0F 50 01 01 00` | `01 00` |
| Toggle | `57 0F 50 01 02 80` | `01 80` or `01 00` |
| Read state | `57 0F 51 01` | `01 80` on, `01 00` off |

NS sends `57 0F 50 01 01` / `…02` / `…00` (`src/settings.ts`, `PLUG`); not followed (§9).

### 5.4 Color Bulb (prefix `57 0F 47 01`) and Strip Light (prefix `57 0F 49 01`) (BLE `colorbulb.md`, `ledstriplight.md`)

| Action | Bulb request | Strip request |
|---|---|---|
| On | `57 0F 47 01 01` | `57 0F 49 01 01` |
| Off | `57 0F 47 01 02` | `57 0F 49 01 02` |
| Toggle | `57 0F 47 01 03` | `57 0F 49 01 03` |
| Brightness `LL` (0–100) | `57 0F 47 01 14 LL` | `57 0F 49 01 14 LL` |
| Brightness and RGB | `57 0F 47 01 12 LL RR GG BB` | `57 0F 49 01 12 LL RR GG BB` |
| RGB only | not used (the bulb table is garbled) | `57 0F 49 01 16 RR GG BB` |
| Colour temperature `TTTT` (2700–6500 K) | `57 0F 47 01 17 TT TT` | — (the strip has none) |
| Read state | `57 0F 48 01` | `57 0F 4A 01` |

- Colour temperature: the bulb page gives two bytes and no byte order; NS writes them big-endian (`wo-bulb.ts`). Big-endian.
  HomeKit mireds m → Kelvin 1 000 000 / m, clamped to 2700–6500.
- Hue and saturation: convert to RGB with the cloud plugin's conversion (SwitchBot.md §6.8) and send with the current brightness.
- State reply (both): byte 0 status, byte 1 bit 7 on, byte 2 brightness, bytes 3–5 R G B; bulb only: bytes 6–7 colour
  temperature (big-endian, as written), byte 10 current mode (1 white, 2 colour, 3 dynamic). The documented examples are §11.4.
- NS puts an extra byte (`02`) before `14`/`17`/`12` (`DEVICE_COMMANDS.BULB`); the documented examples have none. Not followed.
- Some strips need encryption (HB `config.schema.json`, `encryptionKey` description): when a key is configured, or a request
  is answered `0x07`, use §7.

### 5.5 Blind Tilt (BLE `blindtilt.md` "Commands")

Each action has two forms, for different firmware; send the first, and the second when the first is not answered `0x01`.
Done when either answer is `0x01`.

| Action | First form | Second form |
|---|---|---|
| Open (tilt 50) | `57 0F 45 01 01 01 32` | `57 0F 45 01 05 FF 32` |
| Close down (tilt 0) | `57 0F 45 01 01 01 00` | `57 0F 45 01 05 FF 00` |
| Close up (tilt 100) | `57 0F 45 01 01 01 64` | `57 0F 45 01 05 FF 64` |
| Tilt `NN` | `57 0F 45 01 01 01 NN` | `57 0F 45 01 05 SS NN` (`SS` `FF` normal, `01` slow: silent mode) |
| Stop | `57 0F 45 01 00 01` | `57 0F 45 01 00 FF` |

Basic info `57 02`: status, battery, firmware × 10, (byte 3 not described), flags (bit 5 light sensor, bit 3 fault), motion
(bit 3 solar, bit 2 calibrated, bit 1 opening, bit 0 closing), tilt.

### 5.6 Lock family (BLE `lock.md` "Lock Commands", "Lock info data"). Always encrypted (§7)

| Action | Smart Lock, Lock Lite | Smart Lock Pro |
|---|---|---|
| Lock | `57 0F 4E 01 01 10 00` | `57 0F 4E 01 01 00 00 00` |
| Unlock (also unlatches when the EU unlatch feature is on) | `57 0F 4E 01 01 10 80` | `57 0F 4E 01 01 00 00 80` |
| Unlock without unlatch | `57 0F 4E 01 01 10 A0` | `57 0F 4E 01 01 00 00 A0` |
| Read lock info | `57 0F 4F 81 01` | `57 0F 4F 81 04` |
| Enable status notifications | `57 0E 01 00 1E 00 00 81 01` | `57 0E 01 00 1E 00 00 81 04` |
| Disable status notifications | `57 0E 00` | `57 0E 00` |

- Reply status `0x01` OK, `0x06` OK with low battery.
- Lock info (the decrypted reply after its status byte; also every notification whose byte 0 is `0x0F`, decrypted from its
  byte 4):
  - Lock, Lock Lite: byte 0 bit 7 calibrated, bits 6–4 status, bit 2 door open; byte 1 bit 5 door-left-open alarm, bit 4
    unlocked alarm.
  - Lock Pro: byte 0 bit 7 calibrated, bits 6–3 status; byte 1 bit 4 door open; byte 5 bit 7 door-left-open alarm, bit 6
    unlocked alarm.
- HomeKit: status 0 → current SECURED; 1, 6 → UNSECURED; 2 → current UNSECURED, target SECURED; 3 → current SECURED, target
  UNSECURED; 4, 5 → JAMMED; not calibrated → UNKNOWN. A door-open bit feeds the cloud plugin's contact sensor
  (`hide_contactsensor`). UNSECURED and the "Latch" switch both send "Unlock", as the cloud plugin sends `unlock` for
  both (SwitchBot.md §3.4); "unlock without unlatch" is not used.
- NS's lock bytes (`57 0F 4E 01 00` lock, `… 01` unlock; Lock Pro `57 0F 4F 01 …`) contradict the published page and are not
  followed (§9). The locks are security accessories: written only through the host's confirmed path.

## 6. Reading state

- Passive types (Meters, Contact, Motion) are never connected to. Their values come from advertisements only.
- Connectable types: advertisements first; a connected read (`57 02`, the read-state commands, lock info) when the
  sequence number changes for a type that has none of the needed fields, after every command, and every `blePollIntervalMs`
  when polling is on.
- A device not heard for longer than its advertising allows is unreachable. No source states the interval; the cloud
  plugin's unreachable rules (SwitchBot.md §6.6) apply after `scanDuration`-long scans have missed it.

## 7. Encryption

### 7.1 Key material

- Encrypted devices (Lock family; some Strip Lights, relays and air purifiers per HB) need an `encryptionKey`, 16 bytes as 32
  hex characters, and a `keyId`, 1 byte as 2 hex characters (NS `src/devices/base.ts`, `setKey`).
- Where they come from: the user copies them from the SwitchBot app's device information page ("Encryption Key", "Key ID")
  (HB `README.md`, "How to Obtain BLE Encryption Key and Key ID"); NS says only "from the SwitchBot account". None of the three
  sources documents an API that fetches them (the OpenAPI's lock `keyList` is the keypad's passcodes, not these). The cloud
  plugin cannot fill them in automatically; Setup asks for them.
- Validation: anything but 32 hex digits or 2 hex digits is a configuration error for that device (NS).

### 7.2 Session (NS `src/ble.ts`, `sendEncryptedCommand`, `parseEncryptionInit`)

1. Once per connection, unencrypted: `57 00 00 00 0F 21 03 KK` (KK = key id). An encrypted device takes an unencrypted
   request as `57`, three zero bytes, then the rest.
2. Reply: byte 0 must be `0x01`, otherwise the key id is rejected. Byte 2 is the mode: `0` AES-128-CTR, `1` AES-128-GCM; any
   other value is unsupported.
   - CTR: the IV is reply bytes 4 to the end, which must be 16 bytes.
   - GCM: the IV is reply bytes 4 to (length − 4), which must be 12 bytes.
3. The IV belongs to the session until disconnect.

### 7.3 Encrypted request and reply

- Request `57 b1 b2 … bn` is sent as `57 KK H0 H1 E(b1 … bn)`:
  - CTR: E is AES-128-CTR with the key and the session IV as the initial 128-bit counter block, **restarted at that IV for every
    message** (the IV does not advance between messages). `H0 H1` = the first two IV bytes.
  - GCM: E is AES-128-GCM with the 12-byte IV and no additional data; `H0 H1` = the first two bytes of the 16-byte tag. After
    each command the IV is incremented as a 96-bit big-endian integer.
- Reply: byte 0 the status (in clear), bytes 1–3 not used, bytes 4– the encrypted payload, decrypted with the same key and IV
  (CTR from the IV again; GCM without checking the tag, which the reply does not carry in full). The result is the status
  followed by the plain payload; §4.4 applies to the status.
- All lock commands of §5.6 travel this way, and the notifications (byte 0 `0x0F`) are decrypted from byte 4 the same way.
- NS has a second, older path (`setEncryption` with a configured IV, and `src/utils/relay-encryption.ts`, which prefixes
  `0x11`) used only when no key id is set. It is not the documented protocol and is not specified.

### 7.4 Password-protected Bot (NS `src/utils/bot-ble.ts`, `src/devices/wo-hand.ts`) (NS only)

- A Bot with a password set in the app rejects plain actions with `0x07`.
- Request: `57 11 C3 C2 C1 C0 AA`: byte 1 `0x11` (encryption mode 1, command 1), then the CRC-32 of the password as 4
  bytes big-endian, then the action byte (`00` press, `01` on, `02` off).
- CRC-32: the common IEEE one (reflected polynomial `0xEDB88320`, initial `0xFFFFFFFF`, final XOR `0xFFFFFFFF`) over the
  password's characters as bytes.
- NS accepts exactly 4 letters or digits, case-sensitive. A wrong password answers `0x09`.
- The password is a secret: masked, sealed, never logged.

## 8. Logging

Debug: each new advertiser's model and address; each command's name, status and duration; the session mode. Warning:
statuses `0x05`, `0x07`, `0x09`, `0x0A`, a rejected key id, an IV of the wrong length. Never: keys, key ids, passwords,
CRCs, IVs, or the bytes of encrypted frames.

## 9. Where the sources disagree

| Point | BLE docs | NS | Followed |
|---|---|---|---|
| Bot state bit (SD 1 bit 6) | 0 on, 1 off | reads 1 as "state true" | BLE |
| Curtain SD 1 / SD 3 | calibrated SD 1 bit 6; moving SD 3 bit 7; light SD 4 bits 7–4 | moving SD 1 bit 6, calibrated SD 1 bit 5, light SD 4 bits 6–0, chain SD 5 | BLE |
| Plug Mini on/off/toggle | `…01 80` / `…01 00` / `…02 80`, with examples | `…01` / `…02` / `…00` | BLE |
| Lock commands and advertisement | §5.6, §3.7 | other bytes; status from SD 1 | BLE |
| Bulb commands | no extra byte, with examples | extra `02` | BLE |
| Status `0x05` | not supported | acknowledged ("success, encrypted" in the Bot helper) | BLE |
| Curtain 3 speed | `00` high, `01` low | `FF` | `FF` normal, `01` silent (§5.2) |

## 10. Stays on the cloud

No source pins these frames: Hub 2 and Hub 3 (a model code but no layout, NS parses nothing), Presence Sensor (no model
code), Plug Mini (EU) (a model code but the page covers US and JP only), Lock Ultra, Ultra Max, Vision, Vision Pro, Pro
WiFi (no model codes in the table, although `lock.md` gives their commands), Keypad, Water Leak Detector, Relay Switches,
Roller Shade, Garage Door Opener, Ceiling Lights, Humidifiers, Air Purifiers, Circulator Fan, vacuums, IR remotes. Also
from Bluetooth devices that are specified: Plug Mini power and energy (no unit), the Meter Pro's light level, the Curtain's
silent speed. A device configured `BLE` that is in this list is a configuration error logged once and uses the cloud
when it can.

## 11. Test vectors (computed by the spec writer; MAC `C0 FF EE 12 34 56`)

### 11.1 Meter family

| Input | Decoded |
|---|---|
| SD `54 00 64 05 96 37` | Meter (`T`), battery 100, 22.5 °C, 55 %, display °C |
| SD `54 00 64 03 05 B7` | −5.3 °C, 55 %, display °F (value still °C) |
| MP `C0FFEE123456 36 03 02 96 37 00` (BLE `meter.md` Outdoor sample, MAC replaced) with SD `77 00 64` | Outdoor Meter, 22.2 °C, 55 %, battery 100 |
| MP `C0FFEE123456 0B 2C 04 98 2D 00 00 03 E8` with SD `35 00 50` | Meter Pro CO2, 24.4 °C, 45 %, CO2 1000 ppm, battery 80 |
| SD `54 00 64 00 00 00` | no reading (0.0 °C and 0 %) |

### 11.2 Other advertisements

| Input | Decoded |
|---|---|
| SD `48 C0 5A` | Bot, switch mode, **off** (bit 6 set), battery 90 |
| SD `48 80 5A` | Bot, switch mode, on |
| SD `63 C0 5A 1E 51` | Curtain, connectable, calibrated, battery 90, still, position 30 → HomeKit 70, light 5, chain 1 |
| SD `64 40 5A 03 00 0A 00 3C 51` | Contact, motion, battery 90, open, light; 10 s since motion, 60 s since door; entrances 1, exits 1, button 1 |
| MP `C0FFEE123456 2A 80 04 3C 00 7B` | Plug Mini, sequence 42, on, UTC synced, raw power 123 (unit unknown) |
| MP `C0FFEE123456 07 88 10 55 00 00` | Lock Pro, calibrated, unlocked (status 1), door open, battery 85 |
| MP `C0FFEE123456 01 01 32 50` | Blind Tilt, calibrated, still, tilt 50 = open, light 5 |
| MP `C0FFEE123456 09 B2 02` | Color Bulb, on, brightness 50, colour mode (2) |

### 11.3 Commands

- Curtain to HomeKit 70 % open: `PP` = 30 → `57 0F 45 01 05 FF 1E`. HomeKit 50 → `57 0F 45 01 05 FF 32`.
- Bulb to 2700 K at 100 %: brightness `57 0F 47 01 14 64`, temperature `57 0F 47 01 17 0A 8C`.
- Bot with password `1234`: CRC-32 `9BE3E0A3`; press `57 11 9B E3 E0 A3 00`. Password `A1b2`: CRC-32 `B8593746`;
  on `57 11 B8 59 37 46 01`.

### 11.4 Bulb state reply (from BLE `colorbulb.md` examples)

`01 80 20 00 00 FF 00 00 FF FF 02`: OK, on, brightness 32, R 0 G 0 B 255, temperature 0, mode colour.

### 11.5 Encrypted lock (fake key and IV; AES-CTR checked against AES-ECB of the IV)

- Key `000102030405060708090A0B0C0D0E0F`, key id `01`, session init sent `57 00 00 00 0F 21 03 01`.
- Init reply (fixture) `01 00 00 00 F0 F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC FD FE FF`: OK, mode CTR, IV `F0F1…FEFF`.
- Keystream block 0 = AES-128-ECB(key, IV) = `66 A7 C7 E8 34 52 31 48 97 51 DE 07 33 16 AD AD`.
- Lock (Smart Lock), plain `57 0F 4E 01 01 10 00` → sent `57 01 F0 F1 69 E9 C6 E9 24 52`.
- Unlock, plain `57 0F 4E 01 01 10 80` → sent `57 01 F0 F1 69 E9 C6 E9 24 D2`.
- Read lock info, plain `57 0F 4F 81 01` → sent `57 01 F0 F1 69 E8 46 E9`.
- Reply `01 00 00 00 E6 A7` → decrypted payload `80 00` → status OK, lock info: calibrated, locked (status 0), door closed.
- No GCM vector: the spec writer's tools had no AES-GCM. A GCM fixture must come from an independent implementation.

## 12. Gaps

- The Lock (not Pro) advertisement offset (§3.7) needs a real capture; until then lock state is read over GATT.
- The Plug Mini power unit, the Curtain's silent speed, the Bulb's "RGB only" and "brightness and colour temperature" rows, and
  the advertising interval are not pinned by any source.
- Automatic retrieval of `encryptionKey`/`keyId` from the account is not documented in these sources.
- GCM-mode devices: the protocol is specified, but no source says which models use GCM, and there is no vector.
- The contact and motion sensors' manufacturer-data forms and the Bot password are NS only (pySwitchbot-derived, not in the
  published docs).
