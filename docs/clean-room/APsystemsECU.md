# APsystems ECU: functional specification (clean room)

## 0. Provenance

Written by the spec writer for a clean-room port; it contains **no source code**. Everything below describes, in the
spec writer's own words, behaviour observed in the sources listed here and in raw frames users posted in those projects'
issue trackers. Statements are tagged with where they come from: **[HAE]**, **[KSH]**, **[IOB]**, **[XLS]**, **[ISS]**,
**[ECUC]**. Advice of the spec writer is labelled **Recommendation**. Nothing from the repositories was installed or run;
the spreadsheet was unpacked and read as XML. The test vectors in section 7 were built and decoded by a small script the
spec writer wrote from this document alone (not from the sources), and the same script decoded the real frames listed in
7.2 to check the layouts.

There is **no Homebridge plugin** for the ECU family. The only Homebridge match, `dys0n45/homebridge-apsystems-ez1`, is
for the EZ1 microinverter's own local API (a different device and protocol); it was not used. The npm package
`apsystems` (rkokkelk, 2021, GPL-3.0) was not read. The primary protocol sources are the Home Assistant integrations.

| Tag | Source | Version / commit read | Licence, copyright line |
|---|---|---|---|
| **[HAE]** | https://github.com/HAEdwin/homeassistant-apsystems_ecu_reader ("APsystems ECU Reader", HA domain `apsystems_ecu_reader`), maintained; the README calls it the continuation of [KSH] | manifest version `2.15.0`, commit `6b3006358827257c8aa6ed0c8383ec3fea25e650` (2026-10-31) | Apache License 2.0 (`LICENSE.txt`), appendix filled in: "Copyright 2025 HAEdwin". No NOTICE file. |
| **[KSH]** | https://github.com/ksheumaker/homeassistant-apsystems_ecur (HA domain `apsystems_ecur`); its README says it is no longer maintained and points to [HAE] | manifest version `v1.4.4`, commit `b147385fa794f6da1740cb6e65b1fd8533918455` (2026-05-17) | Apache License 2.0 (`LICENSE`), appendix left as the template ("Copyright [yyyy] [name of copyright owner]"); copyright holder is the author, GitHub user `ksheumaker`. No NOTICE file. |
| **[IOB]** | https://github.com/npeter/ioBroker.apsystems-ecu (ioBroker adapter, Node.js) | package `iobroker.apsystems-ecu` `0.2.10`, commit `548da10e3e534154e71dcdfa060190a62172ed66` (2023-10-10) | MIT, "Copyright (c) 2021 npeter <peter_n@gmx.de>" |
| **[XLS]** | `local_ECU-protocol.xlsx` in the [IOB] repository: the adapter author's protocol table (two sheets, same content) | same commit as [IOB] | same as [IOB] (MIT) |
| **[ISS]** | Raw frames and reports in the issue trackers of [HAE] (issues 116, 122, 131, 141) and [KSH] (issues 74, 80, 185, 193, 241) | read 2026-11-04 | user posts; only byte layouts and facts are used, the ids in them are replaced by invented ids in section 7.1 |
| **[ECUC]** | https://github.com/normanp2pl/apsystems_ecuc (an ECU-C HTML page scraper) | commit `2507a7dee580cf473d0cda268d57bcdd0085efbd` (2021-08-19) | **No licence** (all rights reserved; one bundled file is AGPLv3). Read only for the fact that the pages exist; nothing in this spec depends on it. |

Where [HAE] and [KSH] differ, [HAE] (newer, maintained) is taken as the reference and the difference is noted. Where the
spreadsheet [XLS] disagrees with code that both [HAE] and [IOB] share and real frames confirm, the code wins (noted at each
place).

## 1. Scope and devices

### 1.1 ECU models

The ECU ("Energy Communication Unit") is APsystems' gateway: it talks Zigbee to the microinverters on the roof and is on
the LAN by Wi-Fi (and Ethernet on some models). It answers a small binary protocol on **TCP port 8899** on the LAN; this
spec is about that protocol. The model is told by the first four digits of the 12-digit ECU id **[HAE]**:

| ECU id prefix | Model | Notes |
|---|---|---|
| `2160` | ECU-R | Wi-Fi only. No software reboot in [HAE]. |
| `2162` | ECU-R-Pro ("ECU-R with SunSpec") | Needs the socket closed and reopened between queries (3.1). |
| `2163` | ECU-B | Wi-Fi only. |
| `2150` (any `215…`) | **ECU-C** | Wired or Wi-Fi; has CT clamps (consumption meter) read over HTTP (3.9). The user's device. |
| `2030` | ECU-3 | Old powerline model; [HAE] lists the prefix but points ECU-3 owners elsewhere; out of scope. |

[HAE]'s README: ECU-C units built into APsystems storage systems (ELS/ELT) are not supported, and EZ1 inverters (no ECU)
are a different integration.

### 1.2 Inverter families

Two fields tell an inverter's family: the **type code** (two ASCII characters in its real-time record, 3.5) decides the
record's layout, and the first two hex digits of its 12-digit **UID** give the marketing model name **[HAE]**:

| Type code | Layout | Channels (panels) | Families seen | Record length |
|---|---|---|---|---|
| `"00"` | registered only: the ECU knows the inverter but has no data for it | - | any (seen for DS3 `70…`, QS1/YC `806…` [ISS]) | 9 bytes |
| `"01"` | 2-channel | 2 powers, 2 voltages | YC600 (`40…`), DS3 (`70…`) | 21 bytes |
| `"04"` | 2-channel (same layout as `"01"`) | 2 | DS3D-L / DS3-H per [HAE]'s comment | 21 bytes |
| `"02"` | 4-channel, three-phase | 4 powers, 3 voltages | YC1000 (`50…`), QT2 (`90…`) — real QT2 frames carry `"02"` [ISS] | 27 bytes |
| `"03"` | QS1 | 4 powers, 1 voltage | QS1 (`80…`) | 23 bytes |
| `"05"` | **disputed**: [HAE] treats it as 4-channel (comment "QT2"), [KSH] as 2-channel | 4 or 2 | not seen in any frame | 27 or 21 bytes |

UID prefix to model name **[HAE]**: `10` YC500 series, `40` YC600 series, `50` YC1000 series, `70` DS3 series, `80` QS1
series, `90` QT2 series; anything else "Unknown Model". [KSH] names by type code instead: `"01"`/`"04"`/`"05"` "YC600/DS3
series", `"02"` "YC1000/QT2", `"03"` "QS1". [IOB] decides the layout from the UID's first byte (0x40, 0x70 two-channel;
0x50 YC1000; 0x80 QS1) and treats type `"00"` as registered-only; an unknown first byte is an error.

**Recommendation:** decide the layout by the type code (as [HAE] and [KSH]), name the model by the UID prefix.

## 2. Configuration interface

No Homebridge plugin exists, so there is no platform name to keep. **Recommendation:** platform name **`APsystemsECU`**,
one block per bridge, a list of ECUs (most homes have one, [HAE] supports several):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | - | `APsystemsECU`. |
| `name` | string | `"APsystems"` | Instance name for the log. |
| `ecus` | array | `[]` | The ECUs. |
| `ecus[].host` | string | required | IPv4 address or host name. The ECU should have a fixed address ([HAE] README). |
| `ecus[].port` | integer | `8899` | TCP port (no source makes it configurable except [IOB]; default 8899 everywhere). |
| `ecus[].name` | string | `"ECU <ECU id>"` | Display name. |
| `pollInterval` | integer seconds | `300` | Time between polls. [HAE] and [KSH] default to 300 s ("Recommended: 300 seconds" in [HAE]'s README); [IOB] 60 s with a range 10..900 (but per request, see 5.1). Clamp to 60..3600. |
| `connectRetries` | integer | `2` | Connection attempts per query, 1..10 ([HAE] option `port_retries`, form default 5, code fallback 2). |
| `inverters` | boolean | `true` | Publish an accessory per inverter (section 4). |
| `meter` | boolean | `true` | ECU-C only: read the CT clamps over HTTP (3.9). |

The settings [HAE]/[KSH] expose that this port should **not** carry over: `wifi_ssid`/`wifi_password` (`SSID`/`WPA-PSK`
in [KSH]) exist only for the reboot trick of 5.4; `cache_reboot` (`CACHE`); `show_graphs` (`stop_graphs` in [KSH],
inverted). The Device Id of the ECU accessory is the ECU id, and of each inverter its UID (Accessory Settings in
`_accessories` by Device Id as usual).

Setup (**Recommendation**): Authorization Method `none`. Discovery cannot use mDNS (none of the sources finds the ECU
on the network; [HAE]'s README tells users to look for an "Espressif Inc." device in their router). Setup can take a
host from the person and confirm it by sending the system query (3.3): a valid answer gives the ECU id (the Discovered
Device's id) and its model (1.1). [HAE]'s own set-up step does the same: it refuses a host that does not answer with an
ECU id and uses that id as the entry's unique id. An optional sweep of the local /24 networks on port 8899 with the
system query is possible but slow and not done by any source.

## 3. Protocol

### 3.1 Transport

- Plain TCP to port 8899, no TLS, no authentication **[all]**.
- One request per connection: **connect, send one request, read the answer, close**, then reconnect for the next
  request. [HAE] does this for every model ("the 2162 models require an open and close on the port between the individual
  queries; the best generic solution is to now do this for all models"); [KSH] the same with the comment "Some ECUs like
  the socket to be closed and re-opened between commands"; [IOB] also disconnects after every response.
- A poll is three requests in order: system info (3.3), real-time data (3.5), signal levels (3.7). The ECU id from the
  first answer is needed in the other two requests.
- Timing:
  - [HAE]: no pause between the three connections; the read has a 5 s timeout; the connect is retried
    `port_retries` times with 2 s between attempts (a refused, reset or "address in use" connect counts as an attempt);
    a whole poll took about 0.5 s on an ECU-C [ISS 141].
  - [KSH]: 10 s timeout on connect, send and read, and a **fixed 5 s wait after sending** before reading, so a poll takes
    at least 15 s. [KSH] issue 193 reports that this wait was later shortened in a pre-release.
  - [IOB]: 3 s response watchdog; after it fires, the connection is closed and the cycle carries on.
- Only one ECU is queried at a time: [HAE] holds one lock across all its configured ECUs, and starts every ECU after
  the first 10 s later than the one before.
- Reading: all three sources do **one** read of at most 1024 bytes ([HAE], [KSH]; [KSH] links its issue 108 for the
  size) or take the first data event ([IOB]), and parse that. A real-time answer is 30 + 21..27 bytes per inverter (3.5),
  so with more than 36 four-channel or 47 two-channel inverters it cannot fit in 1024 bytes, and a frame split by TCP
  fails the length check (3.2).
  **Recommendation:** read until the number of bytes the header announces (length field + 1) has arrived, with a 5 s
  timeout overall and a cap (64 KiB); fall back to stopping at a trailing `END\n` only if the length field cannot be
  parsed. Do not stop at the first `END\n` seen, because binary fields can contain those bytes.

### 3.2 Frame format (requests and answers)

Every frame, both ways, is ASCII framing around fields, ending with `END` and a line feed:

| Offset | Length | Encoding | Field | Value |
|---|---|---|---|---|
| 0 | 3 | ASCII | start signature | `APS` |
| 3 | 2 | ASCII | command group | `11` in requests; answers carry `11` or `12` (3.4) |
| 5 | 4 | ASCII decimal | length | the frame's length in bytes **without the final line feed** (so total bytes = value + 1) |
| 9 | 4 | ASCII | command code | `0001`, `0002`, `0003`, `0004`, `0030` |
| 13 | … | | payload | per command |
| len-4 | 3 | ASCII | end signature | `END` |
| len-1 | 1 | | line feed | 0x0A |

There is **no checksum** other than the length. The sources call the length field a checksum: [HAE] and [KSH] parse
offsets 5..8 as a decimal number and require it to equal the received byte count minus one, then require `APS` at 0 and
`END` at len-4; any failure makes the whole poll fail (5.2). [IOB] checks the trailing `END\n` and the `APS` start but
not the length. The command group of an answer is not checked by any source.

Numbers inside payloads: "ASCII" fields are characters (decimal digits where numeric); "binary" fields are unsigned
big-endian integers; "BCD" fields are packed decimal, two digits per byte, read as their hex digits. UIDs are 6 bytes
whose 12 hex digits are the 12-digit UID (for example bytes `70 30 00 72 76 15` are UID `703000727615`). The [XLS]
calls the inverter UID "ASCII"; it is not: it is 6 BCD bytes ([HAE], [KSH], [IOB] and every real frame agree).

### 3.3 Requests

| Purpose | Exact request bytes (ASCII) | Notes |
|---|---|---|
| System info | `APS1100160001END` + LF | 16 characters + LF; `0016` is its own length. |
| Real-time data | `APS1100280002` + ECU id (12 digits) + `END` + LF | 28 + LF. |
| Signal levels | `APS1100280030` + ECU id + `END` + LF | 28 + LF. |
| Power of a day [IOB] | `APS1100390003` + ECU id + `END` + date as 8 ASCII digits `YYYYMMDD` + `END` + LF | 39 + LF. [IOB] builds the date from the ISO date's digits (ASCII); [XLS] calls it BCD. Optional, see 3.8. |
| Energy of week/month/year [IOB] | `APS1100390004` + ECU id + `END` + period + `END` + LF; period `00` week, `01` month, `02` year | Actual length is 33 but [IOB] writes `0039` in the length field; [XLS] shows the request without the second `END`. Unverified; see Gaps. |

The ECU id is the 12 ASCII characters from the system answer (3.4), sent as they are. LF is byte 0x0A. The request is
sent as one write. **[HAE]** requests in this order on each poll, a fresh connection each: system, real-time, signal.

### 3.4 System info answer (command `0001`)

Two layouts exist, chosen by the "ECU model" field at offset 25 **[HAE], [KSH]**. Both the ECU-C and the ECU-R send
`"01"` in all frames seen [ISS].

Layout `"01"` (the one in every frame seen; [XLS] and [IOB] give the same field list):

| Offset | Length | Encoding | Field | Scale, meaning |
|---|---|---|---|---|
| 13 | 12 | ASCII | ECU id | e.g. `215000xxxxxx`. |
| 25 | 2 | ASCII | ECU model | `"01"` (or `"02"`, below). |
| 27 | 4 | binary | lifetime energy | ÷ 10 = kWh. |
| 31 | 4 | binary | current power ("last system power") | W, AC, the whole system. |
| 35 | 4 | binary | today's energy | ÷ 100 = kWh; reset by the ECU at midnight. |
| 39 | 7 | BCD | last connection to the EMA cloud | `YYYYMMDDhhmmss`; on ECU-R frames always `D0D0D0D0D0D0D0` [XLS, ISS], on ECU-C a real time [ISS]. Read only by [IOB], unused. |
| 46 | 2 | binary | inverters (registered) | count. |
| 48 | 2 | binary | inverters online | count. |
| 50 | 2 | ASCII | Zigbee channel | always `"10"` in frames seen ([XLS]: "always 10"). [IOB] reads it, unused. |
| 52 | 3 | ASCII decimal | firmware length `v` | e.g. `"016"`. |
| 55 | v | ASCII | firmware version | e.g. `ECU-C-Z_C1.2.24D`, `ECU_R_1.3.6C`, `ECU_R_1.2.22`. |
| 55+v | 3 | ASCII decimal | time zone length `t` | e.g. `"013"`. |
| 58+v | t | ASCII | time zone | e.g. `Europe/Warsaw`, `Etc/GMT-8`. |
| 58+v+t | 6 | binary | Ethernet MAC | [IOB], [XLS]; unused by HA. |
| 64+v+t | 6 | binary | wireless MAC | [IOB], [XLS]; zeros on some ECU-R. |
| 70+v+t | … | | ECU-C only: 12 more bytes before `END`: ASCII `"00"` then ten 0x00 bytes | seen in every ECU-C frame [ISS]; meaning unknown, nobody reads it. |
| len-4 | 3+1 | | `END` LF | |

Command group: ECU-R frames carry `11`; **ECU-C frames carry `12`** (all three ECU-C system frames seen) [ISS]. The
real-time and signal answers of the same ECU-C carry `11` [ISS 116].

Layout `"02"` (in [HAE] and [KSH]; no frame of it was seen and no source says which ECU sends it): ECU id, model,
lifetime, power and today at the same offsets as above, then inverters (2 bytes binary) at **39**, online (2 bytes) at
**41**, bytes 43..48 unread, firmware length (3 ASCII digits) at **49**, firmware at **52**; no time zone is read.

Fields used afterwards by [HAE]: ECU id, lifetime, current power, today, inverters, online, firmware (shown as the
ECU's software version), time zone (kept, unused). The model name comes from the id prefix (1.1).

### 3.5 Real-time data answer (command `0002`)

| Offset | Length | Encoding | Field |
|---|---|---|---|
| 13 | 2 | ASCII | match status: `"00"` = data follows [XLS, IOB] |
| 15 | 2 | ASCII | ECU model, `"01"` in every frame seen |
| 17 | 2 | binary | number of inverter records N |
| 19 | 7 | BCD | time of the data, `YYYYMMDDhhmmss` (the ECU's local time; it advances in 5-minute steps between polls in [ISS 80], and [HAE]'s log shows data time 12:30:00 on a 12:36 poll [ISS 141]) |
| 26 | … | | N inverter records, back to back |
| len-4 | 3+1 | | `END` LF |

How the sources gate on the header: [IOB] reads it as above and needs status `"00"`. [HAE] and [KSH] read two characters
at offset **14** and need `"00"`, then two at offset **15** and need `"01"`, and skip every record otherwise — i.e. they
in effect require bytes 13..16 to read `"0001"` with overlapping, off-by-one windows. Both agree on the frames seen.
**Recommendation:** read status at 13 and model at 15 as [IOB]/[XLS] do; accept status `"00"` only; do not require the
model to be `"01"` (log a model other than `"01"` once and still parse).

Each record starts with the same 9 bytes:

| Record offset | Length | Encoding | Field |
|---|---|---|---|
| +0 | 6 | BCD | inverter UID (12 digits) |
| +6 | 1 | binary | state: 1 = online, 0 = offline ([HAE], [KSH]: any non-zero is online) |
| +7 | 2 | ASCII | type code (1.2) |

followed by, per type code (all binary, 2 bytes each, big-endian):

| Type | +9 | +11 | +13 | +15 | +17 | +19 | +21 | +23 | +25 | Next record at |
|---|---|---|---|---|---|---|---|---|---|---|
| `"00"` | - | | | | | | | | | +9 |
| `"01"`, `"04"` | frequency | temperature | power 1 | voltage 1 | power 2 | voltage 2 | | | | +21 |
| `"02"` (and `"05"` in [HAE]) | frequency | temperature | power 1 | voltage 1 | power 2 | voltage 2 | power 3 | voltage 3 | power 4 | +27 |
| `"03"` | frequency | temperature | power 1 | AC voltage | power 2 | power 3 | power 4 | | | +23 |

Scales: frequency ÷ 10 = Hz; temperature − 100 = °C; powers in W (per panel / DC input as the ECU reports it; [IOB]
calls them `dc_power1..4` and sums them as the inverter's DC power); voltages in V (grid side). For the three-phase
`"02"` families (UID prefix `50` or `90`) [HAE] labels the three voltages "Voltage L1/L2/L3"; real QT2 values are about
405..415 V [ISS], which suggests line-to-line voltage. For all other families [HAE] shows only the first voltage as
"Voltage" (the second 2-channel voltage is read but not shown). The [XLS] marks YC1000's last field "not clear"; [HAE]
and [KSH] read it as the fourth power. [IOB]'s YC1000 branch reads only three powers and three voltages and falls through
into the QS1 branch (a bug); ignore it.

Unknown type code: [HAE] and [KSH] advance 9 bytes and carry on, which misreads every later record if the unknown record
was longer. **Recommendation:** on an unknown type code, stop parsing that frame's records (keep the ones before it) and
log the code once with the frame in hex at debug level.

Values while offline (state 0): the ECU still sends the full record. At night frequency, temperature, powers and voltages
are all 0, so the temperature reads **−100 °C** ([KSH] issue 86 is titled that; [ISS 116]); some offline QT2 records keep
a raw temperature of 100 (0 °C) and real voltages [ISS 241]. What the sources do with them:
- Temperature is set **only when the inverter is online** [HAE], [KSH]; otherwise it is absent (unknown).
- With `show_graphs` on (the [HAE] default) frequency, powers and voltages of an offline inverter are taken as read
  (zeros); with it off they are unknown. [KSH]'s `stop_graphs` is the inverse.
- Signal is unknown while offline [HAE] (in [KSH] only when `stop_graphs` is on).
- A registered-only record (`"00"`) gives an inverter with only UID, online flag and signal, and no channels: [HAE]
  creates only its online sensor.
- Odd values pass through unchanged: an online QS1 record with 65.0 Hz, 15 °C and powers 0/0/4/4 appears in a real
  frame [ISS 74]. **Recommendation:** clamp what HomeKit cannot take (temperature to −270..100, which HAP allows) and pass
  the rest.

N = 0 happens: an ECU-C on firmware `C1.2.24B` answered every real-time request with zero records while its system info
still worked [ISS 131] (frame V10).

### 3.6 Inverter output, derived

None of the protocol's fields is an inverter's AC power. [IOB] computes each inverter's DC power as the sum of its
channel powers and the day's peak of the total; [HAE] shows the channels only. The system's AC power is the system
answer's current power (3.4). **Recommendation:** an inverter's power = sum of its channel powers (rounding not needed:
integers).

### 3.7 Signal answer (command `0030`)

| Offset | Length | Encoding | Field |
|---|---|---|---|
| 13 | 2 | ASCII | status, `"00"` |
| 15 | 7 × M | | M records: 6 bytes BCD UID, 1 byte binary signal level (0..255) |
| len-4 | 3+1 | | `END` LF |

The [XLS] places the records at 17 with a 2-byte level; that is wrong ([HAE], [KSH], [IOB] and every real frame have
7-byte records from offset 15). The records are **not in the same order** as the real-time records [ISS 185, 122]:
match by UID. A level of 0 is reported for offline inverters.

How M is found: [HAE] and [KSH] read as many records as the system answer's "inverters" count, [IOB] as many as fit
before `END`. **Recommendation:** read as many 7-byte records as fit between offset 15 and len-4.

Conversion of the level differs per source:
- [KSH]: percent = integer part of level ÷ 255 × 100.
- [HAE]: "dBm" = integer part of (−100 + level ÷ 255 × 100), so −100..0, shown with unit dBm.
- [IOB]: `signal_level` = level, `rssi` = level − 256.
No source documents which is right. **Recommendation:** keep the raw level and show percent ([KSH]'s formula,
truncating toward zero) where a person reads it.

### 3.8 Day and period history (optional, [IOB] only)

- Power of a day (`0003`) answer: status (2 ASCII) at 13, then pairs to the end: 2 bytes BCD time `hhmm`, 2 bytes binary
  power in W. [IOB] requests it for one day (today by default, or a date the user sets).
- Energy of week/month/year (`0004`) answer: status (2 ASCII) at 13, period (2 ASCII: `00` week, `01` month, `02` year)
  at 15, then pairs to the end: 4 bytes BCD date `YYYYMMDD`, then the energy as binary ÷ 100 = kWh. The energy is
  **2 bytes when the answer's command group is `11` and 4 bytes when it is `12`** [IOB]; a real group-`12` frame
  (week) confirms 4-byte values [ISS 185]. [XLS] lists the command code of this answer as `0040`; the code in [IOB] and
  the real frame use `0004`.
- [HAE] and [KSH] at the commits read do not use either (a [KSH] pre-release once added an "energy history" query, per
  its issue 193).
**Recommendation:** not needed for a first version; the power-of-day series is the candidate for `context.importEnergy`
(5 min power samples → hourly Wh) if a backfill is wanted later.

### 3.9 ECU-C meter (CT clamps) over HTTP ([HAE] only)

For an ECU id starting `215`, after the three TCP queries [HAE] fetches
`http://<host>/index.php/meter/old_meter_power_graph` (GET, header `X-Requested-With: XMLHttpRequest`, 15 s timeout).
The answer is JSON with arrays `power1` (production CTs) and `power2` (grid CTs); [HAE] takes each array's **last**
element and from it the numbers `powerA`, `powerB`, `powerC` (W per phase). An empty array gives unknown. Derived per
phase: consumed = production + grid (missing taken as 0). So grid is positive while importing (inferred from that sum;
no source states the sign). [HAE] then **fails the whole poll if this request fails** or does not parse.

Firmware history [ISS 131, 141]: ECU-C firmware `C1.2.24B` (an automatic overnight update, 2026) removed most of the
local web site ("due to a security issue", per [HAE]'s maintainer) and broke local reading; [HAE] released a fix;
`C1.2.24D` "partly restored" HTTP so the CT values work again; a user on `C1.2.24D` reports CTs reading 0.0 W while the
inverter data works [ISS 141 title]. **Recommendation:** treat the meter as optional: a failed or malformed meter request
leaves the meter readings unknown and never fails the TCP poll. Turn it off with `meter: false`.

Other local HTTP pages exist ([ECUC], [HAE]): the home page (`/` and `/index.php/home`) and
`/index.php/realtimedata` show the same data as HTML tables; [HAE] also posts to `/index.php/configuration/
set_switch_state`, `/configuration/set_maxpower`, `/meter/set_meter_display_funcs`, `/management/set_wlan_ap`, and [KSH]
to `/configuration/set_switch_all_on` and `set_switch_all_off`. **Recommendation:** do not read the HTML pages (the TCP
protocol has everything and the pages are being removed); the write endpoints (inverter on/off, max power, zero export,
reboot) are out of scope for a first version (Gaps).

## 4. HomeKit mapping

### 4.1 What the sources expose (Home Assistant entities, [HAE])

Per ECU: current power (W), today energy (kWh, total increasing), lifetime energy (kWh, total increasing), "lifetime
maximum power" (the highest current power ever seen, kept across restarts), inverters, inverters online, "using cache
counter", a binary "using cached data", firmware version, a switch that stops querying (5.3), a reboot button (5.4); for
ECU-C also production CT A/B/C, grid CT A/B/C, consumed A/B/C (W), a zero-export switch and a power-limit number. Per
inverter: online (binary), temperature (°C), frequency (Hz), signal (dBm), voltage (or L1..L3), power per channel, an
on/off switch and a max-power number (ECU-R-Pro and ECU-C). Device names: "ECU <id>", "Inverter <uid>", manufacturer
"APsystems", suggested area "Roof".

### 4.2 Recommended mapping (all of 4.2 is **Recommendation**)

HomeKit has no power or energy service, so production is shown with the conventions other Homeswift plugins and
Homebridge use, and the figures go to the Status page's Energy section.

ECU accessory (Device Id = ECU id; Accessory Id `APsystemsECU:<ECU id>`; Name "ECU-C <ECU id>" or the configured name):
- Accessory Information: Manufacturer `APsystems`, Model from the id prefix (1.1), SerialNumber = ECU id,
  FirmwareRevision = the firmware string (HAP needs a dotted number: take the first `x.y.z` found in it, e.g.
  `ECU-C-Z_C1.2.24D` → `1.2.24`; keep the full string in the web UI).
- Primary service **Light Sensor** "Solar power": CurrentAmbientLightLevel = current power in W (HAP's minimum is
  0.0001, so 0 W is written as 0.0001; maximum 100000). StatusActive = false while the data is from the cache (5.2);
  StatusFault = 1 after the poll has failed `connectRetries` times in a row.
- Eve characteristics on the same service so the Eve app shows energy: Current Consumption
  `E863F10D-079E-48FF-8F27-9C2605A29F52` (W) and Total Consumption `E863F10C-079E-48FF-8F27-9C2605A29F52` (kWh) =
  lifetime energy. (Homeswift's `EveHistory` is available for an energy history if wanted.)
- Optional Occupancy Sensor "Producing" (detected while current power > 0) for automations; off by default.
- ECU-C with meter data: no extra HomeKit service by default (watts again); the figures go to the Energy section.

Energy section (Homeswift's `EnergyRole`, docs/plugins.md "History and energy"), recorded on every successful poll:
- current power → role `.solar` (`recordValue(watts, series: "<ECU id>:solar", energy: EnergyTag(role: .solar,
  device: <name>))`).
- ECU-C meter: sum of the three grid phases → `.grid` (positive importing, as inferred in 3.9) and sum of the three
  consumed phases → `.home`. Not `shared` (one device).
- Do not record cached values (5.2): a minute without a reading counts as nothing, which is right while the ECU is down.
- At night the ECU answers with 0 W (V2, V9): record 0, not nothing, so the day's solar total stays honest.

Inverter accessories (when `inverters` is true; Device Id = UID; Accessory Id `APsystemsECU:<UID>`; Name "Inverter
<UID>"; Model from the UID prefix; one per record of type other than `"00"`; registered-only ones get none until they
report):
- Primary **Light Sensor** "Power" = sum of channel powers (3.6), 0.0001 when 0. StatusActive = online.
- **Temperature Sensor**: CurrentTemperature = temperature while online; while offline keep the last online value and
  StatusActive = false (never publish the −100 °C of an offline record).
- Per-channel powers, voltages, frequency and signal: web UI and history only (`recordValue` series
  `<UID>:power1`…), not HomeKit services.
- An inverter that disappears from the real-time answer keeps its accessory (the ECU sometimes drops records) until the
  person removes it.

Ids must stay stable: they derive only from the ECU id and UIDs, never from the host or the order of records.

## 5. Behaviour

### 5.1 Polling

- [HAE]/[KSH]: one poll (three queries, 3.1) every `scan_interval` (default 300 s). [HAE] refreshes twice at start-up
  (first refresh, then one more). [IOB] sends **one request per cycle**, cycling system → real-time → signal → (power of
  day) → (week/month/year), with the poll interval between requests, and stops at sunset and resumes at sunrise (sun
  times from the ioBroker host's coordinates, recomputed at 00:01).
- **Recommendation:** poll every `pollInterval` (300 s default) all day; start the first poll at once. No sunset
  pause by default (the ECU answers at night with zeros, and pausing loses the end-of-day and morning readings); a
  night poll every 15 minutes when the system answer says 0 inverters online is a reasonable saving.

### 5.2 Validation, caching and night handling

- A poll fails when a connect fails after its retries, a read times out, the connection is reset, an answer is empty,
  the length/signature check fails (3.2), the command code is not the one asked, or decoding throws. [HAE] then returns
  the **last good data** with "data from cache" true and a "cache counter" incremented; on success the counter is 0.
  [KSH] the same; with no cached data at all the poll errors.
- Firmware glitches filtered by [HAE] (each filtered field keeps its previous value):
  - inverters count 0 → keep the previous count (an ECU-R-Pro bug where both count and today read 0; [KSH] drops count
    and today together when the count is 0);
  - today's energy 0 while some inverters are online → keep the previous today ([KSH] issue 193: today drops to 0 for
    a few minutes during the ECU-C's evening maintenance); 0 with 0 online is accepted (night, after midnight reset);
  - lifetime energy 0 → keep the previous lifetime.
- [HAE] issue 122 (maintainer): "in the late evening, the ECU performs maintenance and data is synchronized with the
  EMA cloud"; users report periods where the ECU stops answering or freezes until power-cycled, and Zigbee drop-outs
  where inverters show offline during the day while the cloud app still has data.
- **Recommendation:** on failure keep the last values in HomeKit with StatusActive false, do not record them to history;
  apply the three filters above; treat today's energy as monotonic within a day except at the ECU's midnight reset
  (accept a drop only when the real-time timestamp's date changed or no inverter is online); lifetime as monotonic
  (ignore a smaller value). Retry the next poll on schedule; after 3 consecutive failures back off to 2× the interval,
  capped at 15 minutes, back to normal on the first success.

### 5.3 Stopping queries

[HAE] and [KSH] have a switch that stops querying (cached data is returned while it is off); [KSH] says it is for
stopping after sunset. **Recommendation:** not needed (pausing the plugin instance does this in Homeswift).

### 5.4 The reboot trick (out of scope)

When the cache counter reaches `cache_reboot` (3..5, default 3 in [HAE], 5 in [KSH]) and the ECU id starts with `215`
or `2162`, the sources reboot the ECU by posting its Wi-Fi settings to `/index.php/management/set_wlan_ap` (form fields
`SSID`, `channel` 0, `method` 2, `psk_wep` empty, `psk_wpa` the Wi-Fi password, header `X-Requested-With:
XMLHttpRequest`): rewriting the access-point settings makes the ECU restart. In [HAE] the counter is incremented before
the check, so with 3 the third poll after two failures reboots instead of querying, and the counter resets. For an
ECU-R or ECU-B, [KSH] stops querying and asks for a manual power cycle. [HAE]'s set-up message says an ECU may need 10
minutes to recover from a reboot. **Recommendation:** do not implement it (it needs the home's Wi-Fi password and the
endpoint is gone on recent ECU-C firmware); log a hint to power-cycle the ECU after an hour of failures.

## 6. Logging

- [HAE] logs at debug the raw answers in hex ("raw basic data", "raw inverter data", "raw signal data"), each connect
  attempt, and the decoded result; a warning "Using cached data for ECU <id>: <reason>" on each failed poll; a warning
  when it reboots; an error when set-up finds no ECU id ("check IP address or wait 10 minutes because the ECU might be
  recovering from reboot"). [KSH] does not warn for a plain timeout. [IOB] can mask the ECU id in its logs (default on),
  replacing its last six digits.
- **Recommendation:** debug: each request (with the ECU id), the answer in hex with the ECU id's last six digits and the
  MAC addresses masked, the decoded summary. Info: first contact (model, firmware, inverter count). Warning: the first
  failed poll of a series and every tenth after, with the reason (refused, timeout, short frame with byte counts, bad
  signature, length mismatch); info when it recovers ("ECU answering again after N failed polls"). No secrets exist in
  this protocol; the ECU id and MACs are personal enough to mask outside debug.

## 7. Test vectors

### 7.1 Invented-id frames (hex, then decoded)

ECU ids `215000999901` (ECU-C) and `216000999902` (ECU-R); inverter UIDs `…999…`; MACs `02aabbccdd0x`. Every frame
passes the length rule (length field = byte count − 1). V1, V2, V4, V6, V7, V9, V10 and V11 copy the shape and values of
real frames in 7.2 with the ids replaced; V3, V5 and V8 are built from the layouts above.

**V1 — ECU-C system info, daytime (group 12, ECU-C trailer), 115 bytes**

    4150533132303131343030303132313530303039393939303130310002c45100001fec00000bc4202605031234290007000731303031364543552d432d5a5f43312e322e3234443031334575726f70652f57617273617702aabbccdd0102aabbccdd02303000000000000000000000454e440a

group `12`, length 114, command `0001`, ECU id `215000999901`, model `01`, lifetime 181329 → 18132.9 kWh, power 8172 W,
today 3012 → 30.12 kWh, EMA time 2026-05-03 12:34:29, inverters 7, online 7, channel `10`, firmware length 16
`ECU-C-Z_C1.2.24D`, time zone length 13 `Europe/Warsaw`, Ethernet MAC 02:aa:bb:cc:dd:01, wireless MAC 02:aa:bb:cc:dd:02,
trailer `303000000000000000000000`.

**V2 — ECU-C system info, evening (0 online), 117 bytes**

    41505331323031313630303031323135303030393939393031303100008d8b0000000000000086202411231257450004000031303031354543552d432d5a5f43312e322e31313031364575726f70652f416d7374657264616d02aabbccdd0102aabbccdd02303000000000000000000000454e440a

ECU id `215000999901`, lifetime 36235 → 3623.5 kWh, power 0 W, today 134 → 1.34 kWh, EMA 2024-11-23 12:57:45, inverters
4, online 0, firmware `ECU-C-Z_C1.2.11`, time zone `Europe/Amsterdam`. Expected handling: today 1.34 accepted, 0 W
recorded as solar 0.

**V3 — ECU-R system info (group 11, no trailer), 95 bytes**

    4150533131303039343030303132313630303039393939303230310000aa3d0000028e000011d0d0d0d0d0d0d0d00006000631303031324543555f525f312e332e36433030394574632f474d542d3802aabbccdd03000000000000454e440a

ECU id `216000999902` (ECU-R), lifetime 43581 → 4358.1 kWh, power 654 W, today 4560 → 45.60 kWh, EMA `d0d0d0d0d0d0d0`,
inverters 6, online 6, firmware `ECU_R_1.3.6C`, time zone `Etc/GMT-8`, Ethernet 02:aa:bb:cc:dd:03, wireless all zero.

**V4 — real-time, DS3 (type `01`) plus a registered-only inverter, 60 bytes**

    415053313130303539303030323030303100022022062009510370300099900100303070300099900201303101f40085005800e8005600e8454e440a

status `00`, model `01`, N = 2, time 2022-06-20 09:51:03. Record 1: UID `703000999001`, state 0, type `00` → registered
only, next record at +9. Record 2: UID `703000999002`, online, type `01`, 500 → 50.0 Hz, 133 → 33 °C, power 88 W / 86 W,
voltage 232 V / 232 V; inverter power 174 W. The `END` sits right after the last record (offset 56).

**V5 — real-time, YC600 (type `01`), 51 bytes**

    415053313130303530303030323030303100012026110412150040600099930101303101f3008d009800e5009300e5454e440a

N = 1, time 2026-11-04 12:15:00; UID `406000999301` (YC600 series), online, 49.9 Hz, 41 °C, 152 W / 147 W, 229 V / 229 V.

**V6 — real-time, QS1 (type `03`), one online and one offline, 76 bytes**

    415053313130303735303030323030303100022022043009133980200099910101303301f4007c008e00f10065011c011f8020009991020030330000006400000000000000000000454e440a

N = 2, time 2022-04-30 09:13:39. `802000999101`: online, 50.0 Hz, 24 °C, powers 142 / 101 / 284 / 287 W (inverter 814
W), AC voltage 241 V. `802000999102`: offline, raw frequency 0, raw temperature 100 (0 °C) — temperature not published
because offline; powers 0, voltage 0.

**V7 — real-time, QT2 three-phase (type `02`), 57 bytes**

    415053313130303536303030323030303100012023050813190090100099920101303201f4008b00cc019c00d2019f00d6019900cd454e440a

N = 1, time 2023-05-08 13:19:00; UID `901000999201` (QT2 series), online, 50.0 Hz, 39 °C, powers 204 / 210 / 214 /
205 W (833 W), voltages L1 412 V, L2 415 V, L3 409 V.

**V8 — real-time, YC1000 (type `02`), 57 bytes**

    415053313130303536303030323030303100012026110412150050100099940101303201f5008700b400e700b000e800b600e600b3454e440a

UID `501000999401` (YC1000 series), 50.1 Hz, 35 °C, powers 180 / 176 / 182 / 179 W, voltages 231 / 232 / 230 V.

**V9 — real-time at night, two DS3 offline, 72 bytes**

    4150533131303037313030303230303031000220260126190751703000999003003031000000000000000000000000703000999004003031000000000000000000000000454e440a

N = 2, time 2026-01-26 19:07:51; both offline, type `01`, every field 0 → raw temperature −100 °C (must not be
published), 0 Hz, 0 W.

**V10 — real-time with no records (ECU-C on C1.2.24B), 30 bytes**

    4150533131303032393030303230303031000020260426152000454e440a

status `00`, model `01`, N = 0, time 2026-04-26 15:20:00. A valid frame: no inverter data this poll (keep inverters'
last values, StatusActive false).

**V11 — signal levels, 40 bytes**

    415053313130303339303033303030703000999002cf70300099900100802000999101a8454e440a

status `00`; `703000999002` level 207 (81 %, [HAE] −18 dBm, [IOB] rssi −49); `703000999001` level 0 (0 %); `802000999101`
level 168 (65 %, [HAE] −34 dBm, [IOB] rssi −88). [HAE]'s conversion truncates toward zero: −100 + 168 ÷ 255 × 100 =
−34.12 → **−34**, 207 → −18.82 → **−18**, 0 → **−100**.

**Negative cases** (all must fail the poll, not crash):
- V1 with the final `0a` removed (114 bytes): length 114 ≠ 113.
- V4 truncated after 40 bytes (a split TCP read): no `END`, length mismatch; with the Recommendation of 3.1 the reader
  waits for the rest instead.
- V4 with bytes 0..2 changed to `41505a` (`APZ`): bad start signature.
- A system answer whose command code is `0002`: wrong answer for the request.
- A real-time record with type `"07"`: records before it kept, parsing stops (Recommendation of 3.5).

### 7.2 Real frames used to check the layouts (ids as posted)

For the implementer's tests these may be used as they are (they decode with the rules above); the owners' ids are in
them, so prefer the invented versions in fixtures that ship.

- [ISS 141], ECU-C system, 115 bytes: `4150533132303131343030303132313530303030313231313530310002c45100001fec00000bc4202605031234290007000731303031364543552d432d5a5f43312e322e3234443031334575726f70652f57617273617780971b02121160c5a879a5ae303000000000000000000000454e440a` → `215000012115`, 18132.9 kWh, 8172 W, 30.12 kWh, 7/7, `ECU-C-Z_C1.2.24D`, `Europe/Warsaw`. The same user's next frame, `4150533132303131343030303132313530303030313231313530310002c457000020ba00000c26202605031239290007000731303031364543552d432d5a5f43312e322e3234443031334575726f70652f57617273617780971b02121160c5a879a5ae303000000000000000000000454e440a`, decodes to 8378 W, 31.10 kWh today, 18133.5 kWh lifetime, which is exactly what [HAE] logged as its decoded result for that poll: a check of the system offsets and scales against the reference.
- [ISS 185], ECU-R system, 95 bytes: `4150533131303039343030303132313630303031323038333030310000aa3d0000028e00000011d0d0d0d0d0d0d00006000631303031324543555f525f312e332e36433030394574632f474d542d3880971b05ce12000000000000454e440a` → `216000120830`, 4358.1 kWh, 654 W, today 0.17 kWh, 6/6, `ECU_R_1.3.6C`, `Etc/GMT-8`.
- [ISS 80], real-time 2-channel + registered-only, 60 bytes: `415053313130303539303030323030303100022022062009510370400000025400303070400000688801303101f40085005800e8005600e8454e440a`.
- [ISS 74], real-time 5 QS1 + 4 registered-only, 181 bytes: `415053313130313830303030323030303100092022043009133980200014221601303301f4007c008e00f10065011c011f80200014253401303301f4007e012c00f1012d012f012e802000142349013033028a00730000000500000004000480200014264201303301f4007500a000f200a200a6008d80200014258501303301f40076009f00f200a200a50095806000008104003030806000008668003030806000008897003030806000009733003030454e440a`.
- [ISS 185], real-time 6 QT2, 192 bytes: `415053313130313931303030323030303100062023050813190090100000420801303201f4008b00cc019c00d2019f00d6019900cd90100000576401303201f4008b00d3019d00d6019c00e5019900db90100000698301303201f4008900cc019a00d6019e00d7019a000090100000623401303201f4008c0097019700d3019900e6019f00e490100000694601303201f4008d00cb019800d6019b00e0019c00df90100000735201303201f4008b00bf019800e6019500f1019700ec454e440a`.
- [ISS 241], real-time 2 QT2 offline with voltages and raw temperature 100, 84 bytes: `4150533131303038333030303230303031000220240313211236901500034029003032000000640000018200000183000101850000901500034411003032000000640000018700000186000101830000454e440a`.
- [ISS 116], real-time 4 DS3 at night (all zero), 114 bytes: `4150533131303131333030303230303031000420260126190751703001018240003031000000000000000000000000703001016257003031000000000000000000000000703001016397003031000000000000000000000000703001018380003031000000000000000000000000454e440a`.
- [ISS 131], real-time N = 0: `4150533131303032393030303230303031000020260426152000454e440a`.
- [ISS 185], signal for 6 inverters (order differs from the real-time frame), 61 bytes: `41505331313030363030303330303090100000735200901000006946a890100000623400901000006983009010000057640090100000420800454e440a`.
- [ISS 122], signal for 4 DS3, 47 bytes: `415053313130303436303033303030703000727615cf703000741095c9703000727193bf703000727181cf454e440a`.
- [ISS 185], week energy, group `12`, 77 bytes: `41505331323030373630303034303030302023111400000000202311150000000020231116000000032023111700000005202311180000000020231119000000002023112000000011454e440a` → status `00`, period `00`, seven days 2023-11-14..20 with 4-byte values 0, 0, 3, 5, 0, 0, 17 (÷ 100 kWh).

## 8. Gaps

- **Type code `"05"`**: 4-channel in [HAE], 2-channel in [KSH], no frame seen. **Recommendation:** follow [HAE]
  (27-byte record) but check it against the frame length: if the bytes left before `END` after the remaining records
  cannot fit, log the frame. Ask a QT2D/DS3 owner for a frame.
- **System layout `"02"`**: offsets from [HAE]/[KSH] only, bytes 43..48 unknown, no time zone; which ECU sends it is
  unknown.
- **The ECU-C's 12 trailing bytes** in system answers (`"00"` + ten zero bytes) and the command group `12`: meaning
  unknown; ignore.
- **Signal level scale**: three different conversions, none documented by APsystems.
- **Grid CT sign** on the ECU-C meter (3.9) is inferred from [HAE]'s consumed = production + grid; check against a real
  export.
- **Energy of week/month/year request**: the length field written by [IOB] (`0039`) does not match its 33-byte
  request, and [XLS] shows a different form; untested here. Group `11` answers use 2-byte values (from [IOB] only).
- **Power of a day date encoding**: ASCII digits in [IOB]'s code, "BCD" in [XLS].
- **Recent ECU-C firmware**: `C1.2.24B` broke local real-time data and HTTP; `C1.2.24D` restored part of it. Behaviour of
  later firmware unknown; the plugin must keep working on whatever subset answers (system info alone, or no meter).
- **Write operations** (out of scope): inverter on/off (`set_switch_state` with the UID followed by `1` on / `2` off,
  answer message "See the results 5 minutes later !"), max power per inverter (`set_maxpower`, fields `id`,
  `maxpower`), zero export (`set_meter_display_funcs`, fields `meter_func`, `this_func` 1, `power_limit`), all on/off,
  reboot. All are HTTP form posts on the local site that recent ECU-C firmware removed, and they would need
  `security`-style confirmation in Homeswift. Not specified further.
- **SunSpec/Modbus TCP (port 502)** exists on ECU-R-Pro and ECU-C (other projects) and might outlive the 8899 protocol;
  not covered here.
- **Concurrency with the EMA app**: unknown whether the ECU tolerates two clients at once (the local EMA Manager app and
  the bridge); the sources serialise their own requests only.
- **Timestamp time zone**: the real-time time is the ECU's local time (its time zone string is in the system answer);
  no source converts it.
