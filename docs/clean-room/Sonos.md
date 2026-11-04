# Sonos (homebridge-zp) — functional specification

Written by the spec writer; contains no source code. Everything below is a description of observed behaviour, in
the spec writer's own words. Identifiers that form an interface (JSON keys, UPnP/SOAP action and argument names, HAP
UUIDs, URI schemes, XML element names) are reproduced because a compatible implementation must use them.

## 0. Provenance

| Repository | Package | Version read | Commit (`git rev-parse HEAD`) | License | Copyright holder |
|---|---|---|---|---|---|
| https://github.com/ebaauw/homebridge-zp | `homebridge-zp` | 1.4.72-0 | `9a001a4504f53259f9bd2866bb5191a226eaddb3` | Apache-2.0 | Erik Baauw (2016-2026) |
| https://github.com/ebaauw/hb-zp-tools | `hb-zp-tools` (the Sonos UPnP client, XML parser, event listener) | 2.0.8-0 | `5c71ac5e66cec95c18844749be9d3cc24ae2cdbd` | Apache-2.0 | Erik Baauw (2019-2026) |
| https://github.com/ebaauw/hb-lib-tools | `hb-lib-tools` (SSDP client, mDNS client, HTTP client, option parser) | 4.0.0 | `e62d2ffa13fd693824c52cb5795aa79b9efe01ef` | Apache-2.0 | Erik Baauw (2018-2026) |
| https://github.com/ebaauw/homebridge-lib | `homebridge-lib` (accessory/service/characteristic delegates, custom characteristic UUIDs, accessory id to UUID) | 9.0.0-0 | `315077c2141e13412472f5f27eecc866daed7d3c` | Apache-2.0 | Erik Baauw (2017-2026) |

homebridge-zp depends on `hb-zp-tools ~2.0.8-0`, `homebridge-lib ~9.0.0-0` and `he` (HTML entity escaping);
hb-zp-tools on `hb-lib-tools ~4.0.0-6`, `xml2js` and `he`. The repositories were read only (no code run).

The plugin also ships a `zp` command-line tool (in both homebridge-zp and hb-zp-tools); it is out of scope.

## 1. Configuration interface

Platform name (the `platform` value, also the Homebridge plugin alias): **`ZP`**. The schema marks it `singular`
(one block per bridge). The block is parsed leniently: an unknown key, a wrong type or an invalid enum value produces a
warning naming the key ("config.json: …") and is otherwise ignored; integer options are **clamped** to their range
(not rejected). Booleans accept JSON booleans, numbers 0/1 and the strings true/yes/on/1 and false/no/off/0 (any
case). Integers accept numbers or decimal (also hex/octal/binary prefixed) strings.

| Key | Type | Default | Range / values | Meaning |
|---|---|---|---|---|
| `platform` | string | — | `"ZP"` | Platform identifier. |
| `name` | string | `"Sonos"` (schema default) | | Log prefix of the platform. |
| `alarms` | bool | false | | Add a Switch service per Sonos alarm to the zone's accessory (§4.5). Also subscribes the household's AlarmClock events. |
| `brightness` | bool | false | | Expose volume as `Brightness` instead of `Volume`, only when `service` is `switch` or `speaker`; for `light`/`fan` a warning "ignoring brightness for service …" is logged. See Gap G1. |
| `excludeAirPlay` | bool | false | | Do not create zone (master) accessories (nor TV accessories) for zone players that report AirPlay support in the topology. Does not affect LED-only slave accessories. |
| `heartrate` | int | unset (disabled) | 1–60 | Seconds between polls of LED state and button lock (only meaningful with `leds`). When set (>0) the LED service has no on-read handler and polls instead. |
| `leds` | bool | false | | Add a Lightbulb "LED" service per zone player (to the zone accessory for the master, and a separate accessory for each slave/satellite player) (§4.4). |
| `maxFavourites` | int | 96 | 16–96 | Number of InputSource services created on each TV accessory; also the max value of `ActiveIdentifier`. |
| `mdns` | bool | true | | Also discover zone players by mDNS (`_sonos._tcp`). |
| `port` | int | 0 | 0–65535; any value ≤ 1024 becomes 0 | TCP port of the local HTTP server that receives UPnP event notifications. 0 = OS-chosen. |
| `resetTimeout` | int | 500 | 1–60 (see note) | Milliseconds after which momentary characteristics (Change Volume, Change Track, Change Input, refused writes) are put back. Note: the default 500 is outside the declared range; an explicitly configured value is clamped to 1–60 ms. A compatible implementation should accept the same key; see Gap G2. |
| `service` | string enum | `"switch"` | `switch`, `light`, `speaker`, `fan` | HAP type of the zone ("Sonos") and "Speakers" services and the volume characteristic: `switch` → Switch + Volume; `light` → Lightbulb + Brightness; `speaker` → Speaker + Volume; `fan` → Fan (v1, UUID 00000040) + RotationSpeed. Absent → Switch + Volume. |
| `speakers` | bool | false | | Add a second, per-zone "Speakers" service (§4.3) and subscribe RenderingControl. |
| `subscriptionTimeout` | int | 30 | 1–1440 (minutes) | Documented as the GENA subscription duration. Parsed and converted to seconds but **not passed to the UPnP client** in this version, which always uses 30 minutes. See Gap G3. |
| `timeout` | int | 15 | 1–60 (seconds) | HTTP request timeout to zone players; also how long to wait for the first event after subscribing. |
| `tv` | bool | false | | Create an additional, non-bridged (externally published) Television accessory per zone (§4.6), and subscribe ContentDirectory for Sonos favourites. |
| `tvIdPrefix` | string (non-empty) | `"TV"` | | Prefix that replaces `RINCON` in the TV accessory's id/serial, so two bridges on one network don't collide. |

Keys asked about but **not present** in this version: `address`/`host`/a static player list, `forceBalance`,
`nameScheme`. They would be reported as invalid keys and ignored. There is no way to configure players statically:
discovery is always automatic (SSDP, optionally mDNS), seeded by cached accessories' last known addresses.

Example (from the docs, paraphrased): `{"platform": "ZP", "service": "speaker", "brightness": true, "speakers": true}`.

## 2. Discovery

### 2.1 SSDP

- Device type filter: `urn:schemas-upnp-org:device:ZonePlayer:1`.
- **Active search**: once, about one second after start-up (first platform heartbeat), a single M-SEARCH is sent from
  a fresh ephemeral UDP socket to `239.255.255.250:1900`. Lines (CRLF separated, ending with one empty line, i.e. the
  datagram ends with a single CRLF after the last header):
  `M-SEARCH * HTTP/1.1`, `HOST: 239.255.255.250:1900`, `MAN: "ssdp:discover"`, `MX: 5`,
  `ST: urn:schemas-upnp-org:device:ZonePlayer:1`. Responses are collected for 5 seconds, then the socket closes.
  There is no periodic re-search.
- **Passive listening**: a UDP socket bound to port 1900 (address reuse on) receives `NOTIFY * HTTP/1.1` messages.
  (The original does not explicitly join the multicast group; see Gap G4.)
- Parsing (both): trim, split on CRLF; the first line is the status line; every other line that splits on `": "`
  (colon + space) into exactly two parts becomes a header with a lower-cased name. Lines with no value (`EXT:`) or with
  more than one `": "` are dropped.
- Acceptance: search responses must have status line `HTTP/1.1 200 OK` and `st` equal to the device type; notifies must
  have status line `NOTIFY * HTTP/1.1`, `nts` = `ssdp:alive` and `nt` equal to the device type (byebye is ignored).
- Extracted values: player id = second `:`-separated field of `usn` (e.g. `uuid:RINCON_…::urn:…` → `RINCON_…`);
  address = the UDP sender address (not `LOCATION`); household = header `x-rincon-household`; boot sequence = integer of
  header `x-rincon-bootseq`.

### 2.2 mDNS (when `mdns` is true, the default)

Browse service type `_sonos._tcp`. For every "service up": id = TXT `uuid`, household = TXT `hhid`, boot sequence =
integer of TXT `bootseq`, address = the IP address the answer came from. Missing id/address/household → ignored (debug
log).

### 2.3 Handling a discovery hit

For (id, address, household, bootseq):

1. If a client for this id exists with the same address, reuse it; otherwise create (or replace) the client for this
   id with the new address and **probe** it (§2.4).
2. Feed the "alive" information to the client: ignore if the id differs from the client's; adopt the household if it
   changed; if the address changed, switch the client to the new address and warn ("now at <address>"); if the boot
   sequence is higher than the known one, treat as a reboot (§6.3); update "last seen".

Cached accessories restored at start-up are probed the same way using the address and household stored in their
context (the address the player had when last seen), before any discovery.

### 2.4 Probing a zone player

1. Resolve the host by DNS (Sonos rejects requests addressed by hostname; requests always go to the IP) and use
   `http://<ip>:1400`.
2. `GET /xml/device_description.xml` (§3.1). The UDN's second `:` field is the player id; if an id was expected and it
   differs, the probe fails with "address mismatch".
3. Read the topology (§3.4): subscribe `/ZoneGroupTopology/Event` on that player, wait up to `timeout` s for the first
   NOTIFY, unsubscribe. (A player whose topology was already read from another player's event re-uses that state with no
   network traffic.)
4. Determine the household: the `MuseHouseholdId` property of the topology event up to its first `.` (S2 systems);
   else the household from discovery/cache; else SOAP `DeviceProperties#GetHouseholdID` (`CurrentHouseholdID`).
5. For every zone player listed in the topology that has no client yet, create one at the address from its
   `Location` and probe it too (in parallel).
6. If the player is not invisible: create the household record if new; make this player the household's
   **associated player** if there is none yet, or if the current one has a battery (a portable speaker) and this one
   doesn't.
7. When no probes remain outstanding and the topology changed, run "expose" (§5.1).

Probe failures are logged as errors; the player is retried on its next discovery hit.

## 3. Protocol

All control traffic is HTTP/1.1 to `<ip>:1400`, one keep-alive connection per player (requests to one player are
serialised), request timeout `timeout` seconds. Any message from a player (response, NOTIFY, SSDP/mDNS alive) updates
its **last seen** timestamp, rendered as the first 24 characters of a JavaScript `Date.toString()`, e.g.
`Wed Nov 04 2026 10:15:30` (before the first contact: `n/a`).

### 3.1 Device description (`GET /xml/device_description.xml`)

Fields used from the root `<device>`:

| Element | Use |
|---|---|
| `UDN` | `uuid:RINCON_<MAC 12 hex><port 01400>`; the part after `uuid:` is the **player id** (e.g. `RINCON_000E58A1B2C301400`). |
| `modelName` | e.g. `Sonos One`. First space-separated word → Manufacturer, second word → model name. |
| `modelNumber` | e.g. `S18`. |
| `displayVersion` | e.g. `16.4`. Firmware revision. Major version ≤ 11 → "S1", otherwise "S2" (log only). |
| `roomName` | The zone (room) name. |
| `memory` | Informational. |
| `serviceList/service/serviceId` | Fourth `:` field `AudioIn` → player has line-in (`audioIn`); `HTControl` → player has TV input (`tvIn`). Only the root device's own service list is looked at. |

### 3.2 SOAP actions

Request: `POST`, path `/<Service>/Control` for the root device ("ZonePlayer") or `/<Device>/<Service>/Control` for
`MediaRenderer` / `MediaServer`. Headers: `SOAPaction: "urn:schemas-upnp-org:service:<Service>:1#<Action>"` (with the
double quotes) and `content-type: text/xml; charset=utf-8`. Body (no XML declaration, no whitespace):
an `s:Envelope` element with `xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"` and
`s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"`, containing `s:Body`, containing
`u:<Action>` with `xmlns:u="urn:schemas-upnp-org:service:<Service>:1"`, containing one child element per argument in
the order listed, the value inserted as text **without further escaping** (values that need escaping — URIs and DIDL
metadata — are passed already XML-escaped). Booleans are written as listed (`1`/`0`, `On`/`Off`, or the literal
`true`).

Response: the children of `s:Body/u:<Action>Response` (names below as Sonos sends them). A SOAP fault (HTTP 500
with a body) is not raised as an error by the original; the caller just sees no expected field. Implementers should
treat it as a failure (log).

| Device / Service | Action | Arguments (in order) | Response fields used |
|---|---|---|---|
| ZonePlayer / AlarmClock | `ListAlarms` | — | `CurrentAlarmList` (escaped XML, §3.6) |
| ZonePlayer / AlarmClock | `UpdateAlarm` | `ID`, `StartLocalTime`, `Duration`, `Recurrence`, `Enabled` (1/0), `RoomUUID`, `ProgramURI` (escaped), `ProgramMetaData` (escaped DIDL, §3.7, or empty), `PlayMode`, `Volume`, `IncludeLinkedZones` | — |
| ZonePlayer / DeviceProperties | `GetLEDState` | — | `CurrentLEDState` = `On`/`Off` |
| ZonePlayer / DeviceProperties | `SetLEDState` | `DesiredLEDState` = `On`/`Off` | — |
| ZonePlayer / DeviceProperties | `GetButtonLockState` | — | `CurrentButtonLockState` = `On`/`Off` |
| ZonePlayer / DeviceProperties | `SetButtonLockState` | `DesiredButtonLockState` = `On`/`Off` | — |
| ZonePlayer / DeviceProperties | `GetHouseholdID` | — | `CurrentHouseholdID` |
| MediaRenderer / AVTransport | `Play` | `InstanceID`=0, `Speed`=1 | — |
| MediaRenderer / AVTransport | `Pause`, `Stop`, `Next`, `Previous` | `InstanceID`=0 | — |
| MediaRenderer / AVTransport | `SetCrossfadeMode` | `InstanceID`=0, `CrossfadeMode` 1/0 | — |
| MediaRenderer / AVTransport | `GetTransportSettings` | `InstanceID`=0 | `PlayMode` |
| MediaRenderer / AVTransport | `SetPlayMode` | `InstanceID`=0, `NewPlayMode` | — |
| MediaRenderer / AVTransport | `SetAVTransportURI` | `InstanceID`=0, `CurrentURI`, `CurrentURIMetaData` (may be empty) | — |
| MediaRenderer / AVTransport | `RemoveAllTracksFromQueue` | `InstanceID`=0 | — |
| MediaRenderer / AVTransport | `AddURIToQueue` | `InstanceID`=0, `EnqueuedURI`, `EnqueuedURIMetaData`, `DesiredFirstTrackNumberEnqueued`=1, `EnqueueAsNext`=1 | — |
| MediaRenderer / AVTransport | `BecomeCoordinatorOfStandaloneGroup` | `InstanceID`=0 | — |
| MediaRenderer / AVTransport | `DelegateGroupCoordinationTo` | `InstanceID`=0, `NewCoordinator`=<player id>, `RejoinGroup`=`true` | — |
| MediaRenderer / AVTransport | `GetRemainingSleepTimerDuration` | `InstanceID`=0 | `RemainingSleepTimerDuration`: `""` or `HH:MM:SS` |
| MediaRenderer / AVTransport | `ConfigureSleepTimer` | `InstanceID`=0, `NewSleepTimerDuration`: `""` (cancel) or `HH:MM:SS` | — |
| MediaRenderer / GroupRenderingControl | `SetGroupVolume` | `InstanceID`=0, `DesiredVolume` 0–100 | — |
| MediaRenderer / GroupRenderingControl | `SetRelativeGroupVolume` | `InstanceID`=0, `Adjustment` (signed) | `NewVolume` |
| MediaRenderer / GroupRenderingControl | `SetGroupMute` | `InstanceID`=0, `DesiredMute` 1/0 | — |
| MediaRenderer / RenderingControl | `SetVolume` | `InstanceID`=0, `Channel` (`Master`, `LF`, `RF`), `DesiredVolume` | — |
| MediaRenderer / RenderingControl | `SetRelativeVolume` | `InstanceID`=0, `Channel`=`Master`, `Adjustment` | `NewVolume` |
| MediaRenderer / RenderingControl | `SetMute` | `InstanceID`=0, `Channel`=`Master`, `DesiredMute` 1/0 | — |
| MediaRenderer / RenderingControl | `SetLoudness` | `InstanceID`=0, `Channel`=`Master`, `DesiredLoudness` 1/0 | — |
| MediaRenderer / RenderingControl | `SetBass` / `SetTreble` | `InstanceID`=0, `DesiredBass` / `DesiredTreble` (−10…10) | — |
| MediaRenderer / RenderingControl | `SetEQ` | `InstanceID`=0, `EQType`, `DesiredValue` | — |
| MediaServer / ContentDirectory | `Browse` | `ObjectID`=`FV:2`, `BrowseFlag`=`BrowseDirectChildren`, `Filter`=`dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI`, `StartingIndex`=0, `RequestedCount`=0, `SortCriteria`=empty | `Result` (escaped DIDL-Lite, §3.7) |

EQ types used: `NightMode` (0/1), `DialogLevel` (0/1, speech enhancement), `SurroundEnable` (0/1), `SurroundLevel`
(TV level −15…15), `MusicSurroundLevel` (−15…15), `SurroundMode` (0/1, "music playback full"), `HeightChannelLevel`
(−10…10), `SubEnable` (0/1), `SubGain` (−15…15).

Play modes (`SetPlayMode`/`GetTransportSettings`), as (repeat, shuffle): `NORMAL` = (off, no), `REPEAT_ONE` = (one,
no), `REPEAT_ALL` = (all, no), `SHUFFLE_NOREPEAT` = (off, yes), `SHUFFLE_REPEAT_ONE` = (one, yes), `SHUFFLE` = (all,
yes). Changing repeat first reads the current play mode to keep shuffle, and vice versa, then sets the combined mode.

Balance write (value −100…100): if negative, set `LF` to 100 and `RF` to 100 − |b|; otherwise set `RF` to 100 and `LF`
to 100 − b (two `SetVolume` calls, the 100 one first). Balance read = RF volume − LF volume.

Queueing a favourite that is a container: `RemoveAllTracksFromQueue`, `AddURIToQueue` (the favourite's URI and
metadata), then `SetAVTransportURI` with `x-rincon-queue:<player id>#0` (no metadata). A non-container favourite:
`SetAVTransportURI` with its URI and metadata. Both followed by `Play`.

Transport URI schemes produced: group join `x-rincon:<coordinator id>`; line-in `x-rincon-stream:<player id>`; TV
input `x-sonos-htastream:<player id>:spdif`; AirPlay (input source only) `x-sonos-vli:<player id>:1`; chime
`x-rincon-buzzer:0`.

### 3.3 GENA event subscriptions

**Callback server.** One HTTP server for all players, listening on `0.0.0.0:<port>` (port 0 → random). It starts
when the first player registers and closes when the last one unregisters. Logged URL: `http://<ip>:<port>/notify`.
Per player, the callback base is `http://<local IP of the socket used to reach that player>:<port>/notify/<player id>`
(so multi-homed hosts give each player a reachable address). The subscription CALLBACK for a resource is that base
followed by the event path, e.g. `<http://192.168.1.2:58004/notify/RINCON_000E58A1B2C301400/MediaRenderer/AVTransport/Event>`.

**Incoming requests.**
- `NOTIFY`: the path is split on `/`. With 5 segments (`""`, `notify`, id, Service, `Event`) the device is
  `ZonePlayer`; with 6 (`""`, `notify`, id, Device, Service, `Event`) the device is the given one. The body (XML) is
  delivered to that player's client. SID/SEQ headers are not checked. The reply is HTTP 200 with an empty body.
- `GET /notify`: an HTML table of registered players (name, id, IP, local IP, subscriptions without the `/Event`
  suffix), for troubleshooting.
- Anything else: empty 200.

**SUBSCRIBE (new)**: method `SUBSCRIBE`, path = the event path (e.g. `/MediaRenderer/AVTransport/Event`,
`/ZoneGroupTopology/Event`), headers `CALLBACK: <url>`, `NT: upnp:event`, `TIMEOUT: Second-<n>`. The response header
`SID` is stored. See Gap G3 for `<n>`: the original intends the subscription duration plus 30 s but produces the
duration's digits followed by `30` (`Second-180030` for the fixed 30 minutes).

**Renewal**: a timer of the subscription duration (1800 s) after each successful subscribe sends `SUBSCRIBE` to the
same path with `SID: <sid>` and `TIMEOUT` only (no CALLBACK/NT). If the renewal is refused with 412 (unknown SID), a
new subscription is made. Errors are logged and mark the subscriptions as needing a check.

**UNSUBSCRIBE**: method `UNSUBSCRIBE` with `SID`. When a player's last subscription is removed it is unregistered
from the callback server.

**Reboot**: when a player's boot sequence increases, all its subscriptions are dropped locally and re-made fresh
(new SIDs) after re-reading the device description.

Subscriptions made:

| Who | Event path | When |
|---|---|---|
| Each probed player | `/ZoneGroupTopology/Event` | temporarily during probing (§2.4) |
| Household's associated player | `/ZoneGroupTopology/Event` | permanently |
| Household's associated player | `/AlarmClock/Event` | if `alarms` |
| Household's associated player | `/MediaServer/ContentDirectory/Event` | if `tv` |
| Each zone (master) accessory's player | `/MediaRenderer/AVTransport/Event`, `/MediaRenderer/GroupRenderingControl/Event` | once the accessory is initialised |
| Each zone accessory's player | `/MediaRenderer/RenderingControl/Event` | if `speakers` |

Each time the household's associated player is (re)set, it waits up to `timeout` seconds for the first event of each
of its subscriptions in turn (topology, then alarms, then favourites) and warns "no <X> event received in <n>s" on
expiry, carrying on regardless.

### 3.4 ZoneGroupTopology event

The NOTIFY body is a UPnP property set. The property `ZoneGroupState` holds escaped XML of a `ZoneGroupState` element
with `ZoneGroups/ZoneGroup` elements (attributes `Coordinator` = coordinator player id, `ID`) each containing
`ZoneGroupMember` elements, optionally with nested `Satellite` elements, and optionally a `VanishedDevices` element
with `Device` children (attribute `UUID`). Other properties used: `MuseHouseholdId` (S2). Older firmware may send
`ZoneGroupState` without the outer element or with the groups directly; both must be handled ("zone groups" are the
`ZoneGroup` elements wherever they are).

Per member (and per satellite) attributes used:

| Attribute | Meaning |
|---|---|
| `UUID` | player id |
| `Location` | `http://<ip>:1400/xml/device_description.xml` → address = host part |
| `ZoneName` | zone (room) name |
| `BootSeq` | integer boot sequence |
| `Invisible` | `1` → invisible (Boost, Bridge, …): never exposed, never associated |
| `AirPlayEnabled` | `1` → supports AirPlay |
| `ChannelMapSet` | present → stereo pair (or stereo pair + sub) |
| `HTSatChanMapSet` | present → home-theatre setup |
| `MoreInfo` | battery: `RawBattPct:<n>,BattPct:<n>,BattChg:<WORD>,BattTmp:<n>` → percentage = BattPct, charging = (BattChg is `CHARGING`); anything else = no battery |

Channel map sets are `;`-separated `<player id>:<channels>` entries. Channel codes map to labels: `LF,LF` → `L`,
`RF,RF` → `R`, `SW,SW` → `Sub`, `LF,RF` → empty (the home-theatre master), `SW` → `Sub`, `LR` → `LS`, `RR` → `RS`,
`LR,RR` → `LS+RS` (an Amp as surrounds), `LR,LTR` → `LS`, `RR,RTR` → `RS` (Era 300 as surrounds); unknown codes are
used verbatim. The label list is **sorted alphabetically** and then assigned to the ids by position (quirk, kept: the
labels are not necessarily matched to the right ids).

Derived per player:
- **role**: `master` unless the player appears in a map set (`ChannelMapSet` → "slave", `HTSatChanMapSet` →
  "satellite") at a position other than the first; the first id of the set is the master.
- **zone** = the master's id (own id for a master).
- **channel**: master → first sorted label; others → the label at their position. No map set → none.
- **slaves** / **satellites** (on the master): the other ids of the set.
- **zone display name** = zone name + ` (` + labels joined by `+` + `)`; for home theatre the first sorted label (the
  master's, normally empty) is left out; `+Sub+Sub` is shortened to `+Subx2`. Satellites and slaves take their master's
  zone display name. E.g. `Living Room (LS+RS+Sub)`, `Bedroom (L+R)`.
- **zone player name** = zone name, plus ` (<channel>)` if the channel is non-empty.
- **zone group** = the group's `Coordinator`.
- **group name** = coordinator zone's name followed by ` + ` and the other master members' zone names sorted;
  **group short name** = coordinator zone's name, plus ` + <count of other master members>` if any (e.g.
  `Living Room + 1`).
- **balance supported** = player has line-in or is in a stereo pair.
- **household** as in §2.4.
- Address changes and boot-sequence increases of the player itself are detected from its own entry (§6.3).

The list of zone players is ordered by zone name (then master id), each master followed by its slaves and satellites.

On every topology event received by the associated player: re-derive the state for every coordinator and member that
has a client, without network traffic; for each vanished device, mark the player lost (§6.2); then notify all
accessories of the household that the topology changed (§5.3).

### 3.5 AVTransport / RenderingControl / GroupRenderingControl events

AVTransport and RenderingControl NOTIFYs carry a `LastChange` property: escaped XML of an `Event` element with one
`InstanceID val="0"` child, whose children are state variables with a `val` attribute (RenderingControl's `Volume`,
`Mute`, `Loudness` repeat per `channel` attribute: `Master`, `LF`, `RF`). Values that are all digits are integers;
`title`/`album` stay strings; `title` and `streamContent` are additionally HTML-entity-decoded. Metadata values
(`CurrentTrackMetaData`, `EnqueuedTransportURIMetaData`) are themselves escaped DIDL-Lite whose single `item` gives
`dc:title`, `upnp:class`, `r:streamContent`, `r:streamInfo`, `res`, … An empty metadata value means "no metadata".

AVTransport state variables used: `TransportState`, `CurrentTrackURI`, `CurrentTrackMetaData`,
`EnqueuedTransportURI`, `EnqueuedTransportURIMetaData`, `CurrentTransportActions` (comma+space list, e.g.
`Set, Stop, Pause, Play, X_DLNA_SeekTime, Next, Previous, X_DLNA_SeekTrackNr`), `CurrentValidPlayModes` (comma
list, e.g. `SHUFFLE,REPEAT,REPEATONE,CROSSFADE`), `CurrentPlayMode`, `CurrentCrossfadeMode`, `SleepTimerGeneration`.

RenderingControl variables used: `Volume` (Master, LF, RF), `Mute` (Master), `Loudness` (Master), `Bass`, `Treble`,
`NightMode`, `DialogLevel`, `SurroundEnabled`, `SurroundLevel`, `MusicSurroundLevel`, `SurroundMode`,
`HeightChannelLevel`, `SubEnabled`, `SubGain`.

GroupRenderingControl NOTIFYs carry plain properties (no LastChange): `GroupVolume`, `GroupMute`
(`GroupVolumeChangeable` is ignored).

Events with no `LastChange` (or an empty one) are ignored. Only the state variables present are applied (events are
partial).

### 3.6 AlarmClock

The event body is ignored; any AlarmClock event triggers `ListAlarms`. `CurrentAlarmList` is escaped XML of
`Alarms/Alarm` elements with attributes `ID`, `StartTime` (`HH:MM:SS`), `Duration`, `Recurrence`, `Enabled` (0/1),
`RoomUUID`, `ProgramURI`, `ProgramMetaData` (escaped DIDL or empty), `PlayMode`, `Volume`, `IncludeLinkedZones`.
`UpdateAlarm` writes them all back unchanged except `Enabled` (the metadata rebuilt as in §3.7; any extra content
tags the Sonos app put in it are lost).

### 3.7 ContentDirectory favourites

The event's `FavoritesUpdateID` property is compared with the last seen value; when it changes (or the first time),
`Browse FV:2` is issued. `Result` is escaped DIDL-Lite with `item` (or `container`) elements. Per element:
`dc:title` (the key; duplicate titles overwrite, see Gap G9), `res` text (the URI), `r:description`,
`r:resMD` (escaped DIDL of the item to play: its `upnp:class` starting with `object.container.` marks the favourite
as a **container**, played through the queue), `upnp:albumArtURI` (zero or more).

Metadata passed back to Sonos for a favourite (and for alarms) is rebuilt as a DIDL-Lite document and XML-escaped:
root `DIDL-Lite` with namespaces `xmlns:dc="http://purl.org/dc/elements/1.1/"`,
`xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"`, `xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/"`,
`xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"`; one `item` with attributes `id`, `parentID`, `restricted`
taken from the resMD item; children `dc:title`, `upnp:class`, then one `upnp:albumArtURI` per art URI (escaped), then
`r:description` if any, then `desc` with `id="cdudn"` and `nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/"`
holding the resMD's `desc` text. Empty source metadata → empty string. URIs are kept XML-escaped (`&` → `&amp;`, `<`,
`>`, `"`, `'`, `` ` `` escaped) for storage, comparison with event URIs (which are escaped the same way before
comparing), and insertion into SOAP bodies.

## 4. Device model

### 4.1 Accessories and identity

| Accessory | Created for | Accessory id (seed) | Category | Bridged? |
|---|---|---|---|---|
| Zone ("Master") | each zone player with role `master` that is not invisible and not excluded by `excludeAirPlay` | the player id, e.g. `RINCON_000E58A1B2C301400` | Speaker (26) | yes |
| LED-only ("Slave") | each slave/satellite player, if `leds` (no AirPlay/invisible filter), and only if its zone's master accessory exists | the player id | Speaker (26) | yes |
| TV | each zone accessory, if `tv` | `tvIdPrefix` + the player id with its first 6 characters (`RINCON`) removed, e.g. `TV_000E58A1B2C301400` | Speaker (26) | no — published as an external accessory with its own HAP server |

The HomeKit accessory UUID in Homebridge is HAP-NodeJS's `uuid.generate(<accessory id>)`, upper-cased. Service
identity is (service type UUID, subtype) as listed below; there is at most one service per (type, subtype).

Accessory Information (all three kinds): Name = initial accessory name; SerialNumber = the accessory id; Manufacturer
= first word of `modelName`; Model = second word of `modelName` + ` (` + `modelNumber` + `)` (e.g. `One (S18)`; further
words are dropped); FirmwareRevision = `displayVersion`. Initial accessory name = zone name, plus ` <channel>` when the
player has a non-empty channel (so a stereo pair's master is e.g. `Bedroom L`, a sub `Living Room Sub`). Homebridge
persists names and characteristic values in its accessory cache; later name changes (from HomeKit) win over these
initial names.

Every service except Accessory Information also carries `Name` (initial service name) and a `ConfiguredName` with
permissions paired-read, notify, paired-write, hidden, initial value = the service name; writing an empty value is
refused; a written value becomes the service name (and the accessory name for the TV's primary service).

Custom characteristic UUIDs are `000000XX-0000-1000-8000-656261617577` with `XX` as listed. All custom ones have
paired-read and notify; "w" adds paired-write.

| Key | Name (display) | UUID suffix | Format, range | Perms |
|---|---|---|---|---|
| Bass | Bass | 041 | int −10…10 step 1 | rw |
| Treble | Treble | 042 | int −10…10 step 1 | rw |
| Loudness | Loudness | 043 | bool | rw |
| Balance | Balance | 044 | int −100…100 step 5, unit percentage | rw |
| CurrentTrack | Track | 045 | string | r |
| SonosGroup | Sonos Group | 046 | string | r |
| ChangeTrack | Track Change | 047 | int −1…1 step 1 | rw |
| ChangeVolume | Volume Change | 049 | int −10…10 step 1 | rw |
| ChangeInput | Input Change | 04A | int −1…1 step 1 | rw |
| NightSound | Night Sound | 04B | bool | rw |
| SpeechEnhancement | Speech Enhancement | 04C | bool | rw |
| SonosCoordinator | Sonos Coordinator | 04D | bool | rw |
| Tv | TV | 04E | bool | r |
| Time | Time | 04F | string | r |
| LastSeen | Last Seen | 061 | string | r |
| LogLevel | Log Level | 065 | uint8 0…3 step 1, overridden to max 4 here; write admin-only | rw |
| Repeat | Repeat | 066 | uint8 0…2 step 1 (0 none, 1 one, 2 all) | rw |
| Shuffle | Shuffle | 067 | bool | rw |
| Crossfade | Crossfade | 068 | bool | rw |
| SubEnabled | Sub Enabled | 06D | bool | rw |
| SubLevel | Sub Level | 07D | int −15…15 step 1 | rw |
| SurroundEnabled | Surround Enabled | 08C | bool | rw |
| TvLevel | TV Level | 08D | int −15…15 step 1 | rw |
| MusicLevel | Music Level | 08E | int −15…15 step 1 | rw |
| MusicPlaybackFull | Music Playback Full | 08F | bool | rw |
| HeightLevel | Height Level | 090 | int −10…10 step 1 | rw |

"Volume characteristic" below means HAP `Volume` (00000119) for `switch`/`speaker`, `Brightness` (00000008) for
`light` or when `brightness` applies, `RotationSpeed` (00000029) for `fan`; always 0–100 %.

### 4.2 Zone accessory: "Sonos" service (group control)

Type per `service` option, **subtype `group`**, name `<zone name> Sonos`. Controls the Sonos *group* the zone is in:
all writes go to the zone's current group coordinator's player. Characteristics:

| Characteristic | Behaviour |
|---|---|
| On | Playing. Read from AVTransport `TransportState` (PLAYING or TRANSITIONING → on). Write on: only if the coordinator's transport actions include `Play` and its current track isn't `TV` → `Play`, then `ConfigureSleepTimer` with `""` when Set Duration ≤ 10 s, else Set Duration as `HH:MM:SS`. Write off: `Pause` if allowed, else `Stop` if allowed. Otherwise the write is reverted after `resetTimeout`. Write handler timeout 5 s. |
| SetDuration (HAP, 000000D3) | Max 86399, initial 0, unit s. Sleep timer to apply on the next "on". After a write of ≤ 10 it resets to 0 after `resetTimeout`. |
| RemainingDuration (HAP, 000000D4) | Max 86399, unit s. On read: 0 if no coordinator or the service is in fault, else `GetRemainingSleepTimerDuration` on the coordinator converted to seconds (`""` → 0; errors → 0); read timeout 2 s. Also pushed when an AVTransport event on the coordinator contains `SleepTimerGeneration`. |
| Volume characteristic | Group volume from `GroupVolume`. Write → `SetGroupVolume` on the coordinator. |
| ChangeVolume (custom) | Initial 0. Write n → `SetRelativeGroupVolume` n on the coordinator; resets to 0 after `resetTimeout`. |
| Mute | From `GroupMute`. Write → `SetGroupMute`. |
| Repeat (custom) | From the play mode. Write 0 always allowed; 1 needs `REPEATONE`, 2 needs `REPEAT` in the coordinator's valid play modes, otherwise reverts to 0 after `resetTimeout`. Sends repeat off/one/all. |
| Shuffle (custom) | From the play mode. Write true needs `SHUFFLE` in valid play modes (else reverts to false). |
| Crossfade (custom) | From `CurrentCrossfadeMode` (=1). Write true needs `CROSSFADE` (else reverts to false) → `SetCrossfadeMode`. |
| CurrentTrack (custom) | Track text, at most 64 characters (§6.4). |
| ChangeTrack (custom) | Initial 0. Write > 0 → `Next` if allowed; < 0 → `Previous` if allowed; resets to 0 after `resetTimeout`. |
| ActiveIdentifier (HAP) | Only if `tv`. Max `maxFavourites`. Mirrors the TV accessory's ActiveIdentifier; a write is forwarded to the TV service as if HomeKit wrote it there. |
| ChangeInput (custom) | Only if `tv`. Initial 0. A non-zero write makes the TV select the next (+1) / previous (−1) visible input (§4.6); resets to 0 after `resetTimeout`. |
| Tv (custom) | Only if the player has TV input (`tvIn`). True when the TV input carries a signal (§6.4). |
| SonosGroup (custom) | The group short name (e.g. `Living Room + 1`), initial empty string. |
| SonosCoordinator (custom) | Initial false. Marks this zone as the bridge's **target coordinator** for its household (§5.4). Write true → this zone becomes target coordinator; if this zone isn't the coordinator of its current group, `DelegateGroupCoordinationTo(<this id>, RejoinGroup true)` is sent to the current coordinator. Write false → reverted to true after `resetTimeout`. At start-up, a cached true makes the zone target coordinator again. |
| LogLevel (custom) | Per-accessory log verbosity (0 none … 4 very verbose), initial = the platform's level; persisted. |
| LastSeen (custom) | Player's last-seen timestamp; initial `n/a`. |
| StatusFault (HAP) | General fault (1) at creation and when the player is lost (§6.2); no fault (0) on any contact from the player. |

Values kept with the service but not exposed: valid play modes (list), current transport actions (list), current URI
(escaped), target coordinator id.

### 4.3 Zone accessory: "Speakers" service (zone control), if `speakers`

Type per `service` option, **subtype `zone`**, name `<zone name> Speakers`. Acts on this zone's player only.

| Characteristic | Behaviour |
|---|---|
| On | "Is a member of another zone's group". Set off when the zone coordinates its own group, on otherwise (on every topology change). Write on: if this zone is the target coordinator, or no target coordinator exists, revert to off after `resetTimeout`; else `SetAVTransportURI x-rincon:<target coordinator id>` on this player (join). Write off: `BecomeCoordinatorOfStandaloneGroup` on this player (leave). Timeout 5 s. |
| Volume characteristic | From RenderingControl `Volume` Master. Write → `SetVolume` Master. |
| ChangeVolume | Write n → `SetRelativeVolume` n; resets to 0 after `resetTimeout`. |
| Mute | From `Mute` Master → `SetMute`. |
| Loudness | From `Loudness` Master → `SetLoudness`. |
| Bass, Treble | From `Bass`/`Treble` → `SetBass`/`SetTreble`. |
| Balance | Only if balance supported (line-in or stereo pair). RF − LF from events; write per §3.2. |
| NightSound, SpeechEnhancement | Only if `tvIn`. From `NightMode`/`DialogLevel`; write → `SetEQ` `NightMode`/`DialogLevel` 1/0. |
| SurroundEnabled, TvLevel, MusicLevel, MusicPlaybackFull, HeightLevel | Only if the zone display name contains, within parentheses, the text `LS+RS` (surrounds present). From `SurroundEnabled`, `SurroundLevel`, `MusicSurroundLevel`, `SurroundMode`, `HeightChannelLevel` → `SetEQ` `SurroundEnable`, `SurroundLevel`, `MusicSurroundLevel`, `SurroundMode`, `HeightChannelLevel`. |
| SubEnabled, SubLevel | Only if the zone display name contains `Sub` within parentheses. From `SubEnabled`/`SubGain` → `SetEQ` `SubEnable`/`SubGain`. |

Unlike the Sonos service, errors from these writes are returned to HomeKit as failures (except ChangeVolume).

### 4.4 LED service, if `leds`

Lightbulb, **subtype `led` + channel** (`led` for a player without a channel or with an empty one, else e.g. `ledL`,
`ledR`, `ledSub`, `ledLS`, `ledRS`). Name `<zone name> Sonos LED` on the zone accessory; on a slave accessory
`<zone name> Sonos <channel> LED`. On the zone accessory it controls the master player; each slave/satellite player
gets its own accessory containing only this service (plus Accessory Information and a Battery service if
applicable).

| Characteristic | Behaviour |
|---|---|
| On | LED state: `GetLEDState`/`SetLEDState`. |
| LockPhysicalControls (HAP) | Button lock: `GetButtonLockState`/`SetButtonLockState` (0 disabled ↔ Off, 1 enabled ↔ On). Write admin-only. |
| LastSeen (custom) | Slave accessories only; initial `n/a`, updated on contact. |

Sonos sends no events for these. Without `heartrate`, both are fetched from the player on each HomeKit read. With
`heartrate` N, both are polled every N seconds (the LED read is skipped while identify blinking is in progress) and
reads return the cached value. On slave accessories the original also keeps a fault status for this service but, through
a typo, never exposes it as a characteristic (it is only stored); see Gap G7.

### 4.5 Alarm services, if `alarms`

On the zone accessory, one Switch per alarm whose `RoomUUID` is this zone's player id: **subtype `alarm<ID>`**, name
`<zone name> Sonos Alarm <ID>`.

| Characteristic | Behaviour |
|---|---|
| On | Alarm enabled (`Enabled` = 1). Write → `UpdateAlarm` with the cached alarm, `Enabled` 1/0. |
| CurrentTrack (custom) | `Sonos Chime` if `ProgramURI` is `x-rincon-buzzer:0`; else the program metadata title (≤ 64 chars); else `unknown`. |
| Time (custom) | `StartTime` (`HH:MM:SS`). |

On every alarm list update, services are created for new alarms, updated for existing ones, and removed (log "remove
Alarm <ID>") for alarms that disappeared. In the original a newly created alarm service keeps its cached values until
the next alarm list update (its values aren't applied on creation); see Gap G8.

### 4.6 Battery service

Added to zone and slave accessories when the topology reports a battery with both percentage and charging state:
HAP Battery, no subtype, name `<accessory name> Battery`; BatteryLevel = BattPct; ChargingState charging (1) / not
charging (0); StatusLowBattery low when level ≤ 20. Updated on every topology change.

### 4.7 TV accessory, if `tv`

External accessory, id per §4.1, same information as the zone accessory, no battery. Services:

**Television** — primary, **subtype `tv`**. Initial name = the zone's Sonos service's ConfiguredName (initially
`<zone name> Sonos`); the two ConfiguredNames are kept equal in both directions.

| Characteristic | Behaviour |
|---|---|
| Active | Mirrors the Sonos service's On (1/0). A write is applied as a write of On to the Sonos service (§4.2). |
| ActiveIdentifier | Max `maxFavourites`. Set from the zone's current URI: the 1-based index of the first input source whose URI equals it, else 0; recomputed when the URI or the favourites change. Write (see below). Mirrored to the Sonos service's ActiveIdentifier. |
| SleepDiscoveryMode | Always discoverable (1). |
| DisplayOrder | TLV8, base64: for each identifier 1…`maxFavourites`, bytes `01 04 <id> 00 00 00`; then `00 00`. |
| RemoteKey | Play/Pause (11) → toggle via Sonos On; Arrow Left (6) → Change Track −1; Arrow Right (7) → Change Track +1; Arrow Up (4) → previous visible input; Arrow Down (5) → next visible input; other keys are only logged (names: Rewind, Fast Forward, Next Track, Previous Track, Select, Back, Exit, Info). |
| PowerModeSelection | Any write → write true to the Sonos service's SonosCoordinator. |
| StatusFault | General fault initially; no fault on any contact from the player. |

**TelevisionSpeaker** — **subtype `tvSpeaker`**, name `<zone name> TV Speaker`. VolumeControlType = absolute (3).
VolumeSelector increment (0) / decrement (1) → write ChangeVolume +1/−1 on the zone's Speakers service if present, else
on the Sonos service. Mute → written through to the same service's Mute. (No Volume characteristic.)

**InputSource × `maxFavourites`** — **subtype `tvInput<n>`** for n = 1…`maxFavourites`, all linked to the
Television service, created once (HomeKit dislikes changing service sets) and reconfigured in place. Each has
ConfiguredName (initially `Input <n>`), Identifier = n, InputSourceType (default Other 0), InputDeviceType = audio
system (5), IsConfigured (default not configured), CurrentVisibilityState and TargetVisibilityState (default hidden;
current follows target).

Input source table, rebuilt whenever the favourites change (and the first entry also on topology / target
coordinator changes):

| n | Name | URI | Configured & shown |
|---|---|---|---|
| 1 | group entry: `Leave <group short name>` if the Sonos Group value differs from the zone name; else `Join <target coordinator's group short name>` (URI `x-rincon:<target id>`) if a target coordinator other than this zone exists; else `none` | none / join URI | shown unless `none` |
| 2 | `AirPlay` | `x-sonos-vli:<id>:1` | never shown (type Other) |
| 3 | `Audio In` | `x-rincon-stream:<id>` | if the player has line-in |
| 4 | `TV` | `x-sonos-htastream:<id>:spdif` | if the player has TV input (type HDMI 3) |
| 5… | each Sonos favourite, name truncated to 64 chars, in favourites order | favourite URI | yes (type Tuner 2 if the URI starts with `x-sonosapi-stream:`) |
| up to `maxFavourites`−1 | padding `Input <n>` | none | no |
| next | `Sonos Chime` | `x-rincon-buzzer:0` | configured, but hidden |

Only the first `maxFavourites` entries are mapped to services. After a rebuild the visible names are logged.

ActiveIdentifier write v (1…`maxFavourites`): v = 1 without URI ("Leave") → `BecomeCoordinatorOfStandaloneGroup` on
this zone. Otherwise, if the source has a URI, the target player is this zone for v ≤ 4 and the zone's group
coordinator for v > 4; containers are queued, others set as transport URI (§3.2), then `Play` (its failure only
logged); after a join (v = 1) the identifier is set back to the zone's Sonos ActiveIdentifier after `resetTimeout`.
Sources without a URI do nothing.

Next/previous visible input: starting from the current identifier, step by ±1, wrapping below 2 to
`maxFavourites`−1 and above `maxFavourites`−1 to 2, until an input source whose current visibility is shown is found
or the start is reached again.

### 4.8 Identify

Identify on any of these accessories blinks the player's LED: read the LED state, toggle it ten times one second
apart, then restore it. A second identify while blinking is ignored.

## 5. Behaviour

### 5.1 Expose

After probing settles: forget clients of cached accessories whose probe failed (so they are retried); if no
household was found warn "no zone players found". Otherwise log the number of households and, per household: (re)set
its associated player (§3.3), log a tree of zones and players (§7), then create accessories in zone-player order
(§3.4) for players not yet having one, per §4.1. Accessories already created are never recreated. When all have
initialised and every cached accessory was matched by a successful probe, the platform is "initialised", after which
cached accessories without a delegate (e.g. after turning `leds` or `tv` off) are removed. A cached accessory whose
player never answers keeps the platform from initialising, so it is not removed (HomeKit keeps its room and
automations).

### 5.2 Group following

Per zone accessory: it is **coordinator** when its player's zone group equals its own id. A coordinator's AVTransport
and GroupRenderingControl events update its own Sonos service and are copied to all **members** (zone accessories
that aren't coordinators and whose zone group is this id): On, current track, transport actions, valid play modes,
repeat/shuffle, crossfade, URI, volume, mute, remaining duration. A non-coordinator, on each topology change, copies
the coordinator's group name, On, volume, mute, current track, transport actions and URI — unless it is "leaving",
which it becomes as soon as it receives an AVTransport event of its own while not coordinator, and stops being when it
becomes coordinator again. Writes on any member's Sonos service go to the group coordinator's player.

### 5.3 Topology changes

On each topology event: every zone accessory recomputes group short name, coordinator status, the Speakers On value,
copies from the coordinator, and its battery; slave accessories update their battery; TV accessories refresh input 1.
Newly appearing players are only picked up through discovery (SSDP alive/mDNS), which probes them and runs expose again.

### 5.4 Target coordinator

Per household, at most one zone is the target coordinator (SonosCoordinator true on that zone, false on the others of
the same household, and every zone's stored target id updated). It's what Speakers On joins and what the TV's "Join"
input points to. Zones in other households are unaffected (S1/S2 split systems are separate households).

### 5.5 Momentary and refused writes

Change Volume / Track / Input reset to 0, refused On/Repeat/Shuffle/Crossfade/SonosCoordinator writes revert, each
after `resetTimeout` ms. Errors from the Sonos service's writes are logged, not returned to HomeKit.

## 6. Edge cases

### 6.1 Persisted values

All characteristic values are persisted with the cached accessory and restored at start-up; the first NOTIFY after
each subscription (UPnP sends the full state) refreshes them. Accessory context stores name, id, address, household.

### 6.2 Unreachable players

A player is marked lost when the topology lists it under vanished devices: Sonos On → off, StatusFault → general
fault, Speakers On → off (if present); for a slave, the LED service's (unexposed) fault. Every 300 s (at 30 s past the
period) the platform logs each zone player's last-seen time and boot sequence (as info if ≥ 600 s ago, debug
otherwise); it intends to mark players unseen for ≥ 600 s as lost, but through a bug never does (Gap G6). Any later
contact clears the fault.

### 6.3 Reboot and address changes

A higher boot sequence (from SSDP/mDNS or the player's own topology entry) → warn "rebooted (old → new)", re-read the
device description, re-make all subscriptions. A different address in the topology or a discovery message → switch
the client to it, warn "address changed"/"now at".

### 6.4 Track, URI and TV detection from AVTransport

From `CurrentTrackURI` (if non-empty), by scheme (text before the first `:`):

| Scheme | Track | URI |
|---|---|---|
| `x-rincon-buzzer` | `Sonos Chime` | the track URI |
| `x-sonos-vli`, `x-sonosapi-vli` (AirPlay) | metadata title | track URI up to the first `,` |
| `x-rincon-stream` (line-in) | metadata title | the track URI |
| `x-sonos-htastream` (TV) | `TV`; TV signal = metadata `streamInfo` ≠ 0 (0 no input, 2 stereo, 18 Dolby 5.1, …) | the track URI |
| `aac`, `x-sonosapi-stream`, `x-rincon-mp3radio` (radio) | metadata `streamContent`; if empty, the enqueued metadata title (station) | — |
| `hls-radio` | if `streamContent` matches `TYPE=SNG|TITLE <t>|ARTIST <a>|ALBUM…`: `<t>` if `<a>` is empty, else `<a> - <t>`; else the enqueued metadata title | — |
| `x-file-cifs`, `x-sonos-http`, `http`, `https`, `x-sonos-spotify`, `x-sonosprog-http`, `x-sonosapi-rtrecent` | metadata title if present | — |
| `x-sonosapi-hls`, `x-sonosapi-hls-static` | unchanged (a later event brings the metadata) | — |
| `x-rincon` (member of a group) | unchanged (comes from the coordinator) | — |
| other | warn "unknown uri"; metadata title, or empty | — |

Then: a non-empty `EnqueuedTransportURI` replaces the URI (playlist/station/favourite). A `CurrentTransportActions`
list of exactly one action clears the track to empty. Track values `ZPSTR_CONNECTING` and `ZPSTR_BUFFERING` are
ignored. The URI is stored XML-escaped.

TV flag (only meaningful on players with TV input): computed false for every event that isn't a TV-input track. If
it differs from the current value it is applied at once when it becomes true, when there is no previous value, or when
the track isn't `TV`; when the TV input loses its signal (track `TV`, flag false) it is applied after 10 s, and that
delayed change is cancelled if a later event brings the current value again.

`CurrentCrossfadeMode` 1 → crossfade on. `CurrentPlayMode` → repeat/shuffle per §3.2. `CurrentValidPlayModes` split
on `,`; `CurrentTransportActions` split on `, `.

### 6.5 Misc

- When no player answers at all, "no zone players found" is warned and again every 300 s.
- The household's associated player is never a portable (battery) speaker when a mains-powered one exists; association
  is not moved away from a player later (the unsubscribe-from-the-previous path never triggers in this version).
- Invisible players (Boost, Bridge) are probed and logged with "(invisible)" but never exposed.
- Restored TV accessories: Homebridge doesn't cache external accessories, so only bridged accessories are restored.

## 7. Logging (paraphrased)

- Info: the listener URL; "found N households"; per household "<household>: found N S1/S2 zone players in M zones",
  followed by a tree: one line per zone (zone display name, "(invisible)" if so), then one line per player (id, player
  name, model name, model number, role and capabilities "airPlay", "audioIn", "tvIn"); the associated player per
  household; TV input source lists; "remove Alarm <id>"; remote key and volume selector names; each characteristic
  change made by the plugin ("set to X (from Y)") and by HomeKit ("changed to X (from Y)").
- Warnings: config problems; "no zone players found"; reboot (old → new boot sequence); address changes; "no
  ZoneGroupTopology/AlarmClock/ContentDirectory event received in Ns"; unknown track URI scheme; request failures
  (with the request id, method, resource and action); write timeouts.
- Debug: every request (id, method, resource, action) and response (status), every notification (service), probing
  progress and the player's model/version and local address, SSDP/mDNS hits; verbose levels add bodies.
- Never logged: nothing sensitive is handled (no credentials).

## 8. Test vectors (example data, constructed by the spec writer from Sonos's wire formats)

### 8.1 SSDP search response

```
HTTP/1.1 200 OK
CACHE-CONTROL: max-age = 1800
EXT:
LOCATION: http://192.168.1.10:1400/xml/device_description.xml
SERVER: Linux UPnP/1.0 Sonos/80.1-55240 (ZPS18)
ST: urn:schemas-upnp-org:device:ZonePlayer:1
USN: uuid:RINCON_000E58A1B2C301400::urn:schemas-upnp-org:device:ZonePlayer:1
X-RINCON-HOUSEHOLD: Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d
X-RINCON-BOOTSEQ: 42
BOOTID.UPNP.ORG: 42
X-RINCON-WIFIMODE: 0
X-RINCON-VARIANT: 2
```
Received from 192.168.1.10 → id `RINCON_000E58A1B2C301400`, address `192.168.1.10`, household
`Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d`, bootseq 42. (`EXT:` is dropped.) A `NOTIFY * HTTP/1.1` with `NT:` equal to the
device type and `NTS: ssdp:alive` and the same USN/X-RINCON headers gives the same result.

### 8.2 mDNS

`Kitchen._sonos._tcp.local` from 192.168.1.10, TXT `uuid=RINCON_000E58A1B2C301400`,
`hhid=Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d`, `bootseq=42` (others such as `info`, `vers`, `protovers`, `mhhid`,
`location`, `sslport` ignored) → same as 8.1.

### 8.3 Device description (abridged)

```xml
<?xml version="1.0" encoding="utf-8" ?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
 <specVersion><major>1</major><minor>0</minor></specVersion>
 <device>
  <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
  <friendlyName>192.168.1.10 - Sonos Beam - RINCON_000E58A1B2C301400</friendlyName>
  <manufacturer>Sonos, Inc.</manufacturer>
  <modelNumber>S14</modelNumber>
  <modelName>Sonos Beam</modelName>
  <softwareVersion>80.1-55240</softwareVersion>
  <UDN>uuid:RINCON_000E58A1B2C301400</UDN>
  <displayVersion>16.4</displayVersion>
  <roomName>Living Room</roomName>
  <memory>1024</memory>
  <serviceList>
   <service><serviceType>urn:schemas-upnp-org:service:AlarmClock:1</serviceType><serviceId>urn:upnp-org:serviceId:AlarmClock</serviceId><controlURL>/AlarmClock/Control</controlURL><eventSubURL>/AlarmClock/Event</eventSubURL><SCPDURL>/xml/AlarmClock1.xml</SCPDURL></service>
   <service><serviceType>urn:schemas-upnp-org:service:DeviceProperties:1</serviceType><serviceId>urn:upnp-org:serviceId:DeviceProperties</serviceId><controlURL>/DeviceProperties/Control</controlURL><eventSubURL>/DeviceProperties/Event</eventSubURL><SCPDURL>/xml/DeviceProperties1.xml</SCPDURL></service>
   <service><serviceType>urn:schemas-upnp-org:service:ZoneGroupTopology:1</serviceType><serviceId>urn:upnp-org:serviceId:ZoneGroupTopology</serviceId><controlURL>/ZoneGroupTopology/Control</controlURL><eventSubURL>/ZoneGroupTopology/Event</eventSubURL><SCPDURL>/xml/ZoneGroupTopology1.xml</SCPDURL></service>
   <service><serviceType>urn:schemas-upnp-org:service:HTControl:1</serviceType><serviceId>urn:upnp-org:serviceId:HTControl</serviceId><controlURL>/HTControl/Control</controlURL><eventSubURL>/HTControl/Event</eventSubURL><SCPDURL>/xml/HTControl1.xml</SCPDURL></service>
  </serviceList>
  <deviceList><!-- MediaServer and MediaRenderer sub-devices --></deviceList>
 </device>
</root>
```
→ id `RINCON_000E58A1B2C301400`, zone `Living Room`, Manufacturer `Sonos`, Model `Beam (S14)`, firmware `16.4`, S2,
tvIn = true, audioIn = false.

### 8.4 SOAP request / response (GetLEDState)

```
POST /DeviceProperties/Control HTTP/1.1
Host: 192.168.1.10:1400
SOAPaction: "urn:schemas-upnp-org:service:DeviceProperties:1#GetLEDState"
content-type: text/xml; charset=utf-8

<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetLEDState xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"></u:GetLEDState></s:Body></s:Envelope>
```
```
HTTP/1.1 200 OK
CONTENT-TYPE: text/xml; charset="utf-8"

<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetLEDStateResponse xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"><CurrentLEDState>On</CurrentLEDState></u:GetLEDStateResponse></s:Body></s:Envelope>
```
→ LED on. A write of group volume 25 sends to `/MediaRenderer/GroupRenderingControl/Control`, SOAPaction
`"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupVolume"`, body element
`<u:SetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><InstanceID>0</InstanceID><DesiredVolume>25</DesiredVolume></u:SetGroupVolume>`
inside the same envelope.

Sleep timer: `GetRemainingSleepTimerDuration` answering `RemainingSleepTimerDuration` = `00:29:41` → 1781 s; `""` → 0.
Set Duration 5400 then On → `ConfigureSleepTimer` with `01:30:00`.

### 8.5 SUBSCRIBE

```
SUBSCRIBE /MediaRenderer/AVTransport/Event HTTP/1.1
Host: 192.168.1.10:1400
CALLBACK: <http://192.168.1.2:58004/notify/RINCON_000E58A1B2C301400/MediaRenderer/AVTransport/Event>
NT: upnp:event
TIMEOUT: Second-1830
```
→ `HTTP/1.1 200 OK`, `SID: uuid:RINCON_000E58A1B2C301400_sub0000001234`, `TIMEOUT: Second-1830`. Renewal after
1800 s: same path, headers `SID: uuid:RINCON_000E58A1B2C301400_sub0000001234`, `TIMEOUT: …`.

### 8.6 NOTIFY: AVTransport

`NOTIFY /notify/RINCON_000E58A1B2C301400/MediaRenderer/AVTransport/Event` with body:

```xml
<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot; xmlns:r=&quot;urn:schemas-rinconnetworks-com:metadata-1-0/&quot;&gt;&lt;InstanceID val=&quot;0&quot;&gt;&lt;TransportState val=&quot;PLAYING&quot;/&gt;&lt;CurrentPlayMode val=&quot;SHUFFLE_NOREPEAT&quot;/&gt;&lt;CurrentCrossfadeMode val=&quot;0&quot;/&gt;&lt;CurrentTrackURI val=&quot;x-sonosapi-stream:s1234?sid=254&amp;amp;flags=8224&amp;amp;sn=0&quot;/&gt;&lt;CurrentTrackMetaData val=&quot;&amp;lt;DIDL-Lite xmlns:dc=&amp;quot;http://purl.org/dc/elements/1.1/&amp;quot; xmlns:upnp=&amp;quot;urn:schemas-upnp-org:metadata-1-0/upnp/&amp;quot; xmlns:r=&amp;quot;urn:schemas-rinconnetworks-com:metadata-1-0/&amp;quot; xmlns=&amp;quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&amp;quot;&amp;gt;&amp;lt;item id=&amp;quot;-1&amp;quot; parentID=&amp;quot;-1&amp;quot; restricted=&amp;quot;true&amp;quot;&amp;gt;&amp;lt;res protocolInfo=&amp;quot;x-sonosapi-stream:*:*:*&amp;quot;&amp;gt;x-sonosapi-stream:s1234?sid=254&amp;amp;amp;flags=8224&amp;amp;amp;sn=0&amp;lt;/res&amp;gt;&amp;lt;r:streamContent&amp;gt;Artist X - Song Y&amp;lt;/r:streamContent&amp;gt;&amp;lt;dc:title&amp;gt;s1234&amp;lt;/dc:title&amp;gt;&amp;lt;upnp:class&amp;gt;object.item&amp;lt;/upnp:class&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&quot;/&gt;&lt;r:EnqueuedTransportURI val=&quot;x-sonosapi-stream:s1234?sid=254&amp;amp;flags=8224&amp;amp;sn=0&quot;/&gt;&lt;r:EnqueuedTransportURIMetaData val=&quot;&quot;/&gt;&lt;CurrentTransportActions val=&quot;Set, Stop, Pause, Play&quot;/&gt;&lt;r:CurrentValidPlayModes val=&quot;CROSSFADE&quot;/&gt;&lt;r:SleepTimerGeneration val=&quot;0&quot;/&gt;&lt;/InstanceID&gt;&lt;/Event&gt;</LastChange></e:property></e:propertyset>
```
Decoded: transport state PLAYING → On true; scheme `x-sonosapi-stream` → track `Artist X - Song Y`; enqueued URI
non-empty → URI `x-sonosapi-stream:s1234?sid=254&flags=8224&sn=0` (stored escaped as `…&amp;flags=8224&amp;sn=0`);
transport actions [Set, Stop, Pause, Play] (more than one, track kept); valid play modes [CROSSFADE]; play mode
SHUFFLE_NOREPEAT → repeat 0, shuffle true; crossfade false; SleepTimerGeneration present and this zone is coordinator
→ query the remaining sleep timer. If this zone coordinates a group, the same values are copied to the member zones.

### 8.7 NOTIFY: RenderingControl and GroupRenderingControl

`/notify/<id>/MediaRenderer/RenderingControl/Event`, LastChange event (unescaped here for readability):
`InstanceID val=0` with `Volume channel=Master val=30`, `Volume channel=LF val=100`, `Volume channel=RF val=80`,
`Mute channel=Master val=0`, `Loudness channel=Master val=1`, `Bass val=2`, `Treble val=-1`, `NightMode val=1`,
`DialogLevel val=0`, `SubEnabled val=1`, `SubGain val=3` → Speakers: volume 30, balance −20 (if supported), mute
false, loudness true, bass 2, treble −1, night sound true, speech enhancement false, sub enabled true, sub level 3.
(Note `-1` is not all digits and stays a string in the original's parser; implementations should parse signed
integers.)

`/notify/<id>/MediaRenderer/GroupRenderingControl/Event`:
`<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><GroupMute>0</GroupMute></e:property><e:property><GroupVolume>14</GroupVolume></e:property><e:property><GroupVolumeChangeable>1</GroupVolumeChangeable></e:property></e:propertyset>`
→ Sonos volume 14, mute false (copied to members).

### 8.8 NOTIFY: ZoneGroupTopology (ZoneGroupState shown unescaped)

```xml
<ZoneGroupState><ZoneGroups>
 <ZoneGroup Coordinator="RINCON_000E58A1B2C301400" ID="RINCON_000E58A1B2C301400:3141">
  <ZoneGroupMember UUID="RINCON_000E58A1B2C301400" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Living Room" BootSeq="42" AirPlayEnabled="1"
     HTSatChanMapSet="RINCON_000E58A1B2C301400:LF,RF;RINCON_000E58D4E5F601400:SW;RINCON_000E58112233401400:LR;RINCON_000E58556677801400:RR">
   <Satellite UUID="RINCON_000E58D4E5F601400" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Living Room" BootSeq="17" Invisible="1"
     HTSatChanMapSet="RINCON_000E58A1B2C301400:LF,RF;RINCON_000E58D4E5F601400:SW;RINCON_000E58112233401400:LR;RINCON_000E58556677801400:RR"/>
  </ZoneGroupMember>
  <ZoneGroupMember UUID="RINCON_000E58998877601400" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="Kitchen" BootSeq="9"/>
 </ZoneGroup>
 <ZoneGroup Coordinator="RINCON_000E58AABBCC01400" ID="RINCON_000E58AABBCC01400:77">
  <ZoneGroupMember UUID="RINCON_000E58AABBCC01400" Location="http://192.168.1.13:1400/xml/device_description.xml" ZoneName="Garden" BootSeq="5" MoreInfo="RawBattPct:87,BattPct:85,BattChg:NOT_CHARGING,BattTmp:31"/>
 </ZoneGroup>
</ZoneGroups><VanishedDevices><Device UUID="RINCON_000E58FFEEDD01400" ZoneName="Office" Reason="powered off"/></VanishedDevices></ZoneGroupState>
```
(other properties in the same body: `MuseHouseholdId` = `Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d.hJ7k` → household
`Sonos_q8xYjGwRk1sT0hZpLmN4bVcA2d`.) Decoded:
- Living Room master `…A1B2C3…`: role master, home theatre, labels `''`, `Sub`, `LS`, `RS` sorted to `''`, `LS`, `RS`,
  `Sub`; channel empty; zone display name `Living Room (LS+RS+Sub)` → Speakers gets surround and sub
  characteristics; group Living Room coordinator; group name `Living Room + Kitchen`, short `Living Room + 1`.
  Zone accessory id `RINCON_000E58A1B2C301400`, name `Living Room`; LED subtype `led`; TV accessory id
  `TV_000E58A1B2C301400`.
- The satellite listed (`…D4E5F6…`, the sub): role satellite, zone `…A1B2C3…`, channel by sorted position 1 = `LS`
  (the positional quirk of §3.4), name `Living Room (LS)`; with `leds` an accessory `Living Room LS` with LED subtype
  `ledLS`.
- Kitchen: master, member of the Living Room group (Speakers On true, Sonos service writes go to Living Room).
- Garden: standalone, battery 85 %, not charging, normal → Battery service. Not chosen as associated player if a
  mains-powered player exists.
- Office vanished → its zone accessory goes to general fault, On off.

### 8.9 ListAlarms response (CurrentAlarmList unescaped)

`<Alarms><Alarm ID="12" StartTime="07:30:00" Duration="01:00:00" Recurrence="WEEKDAYS" Enabled="1" RoomUUID="RINCON_000E58998877601400" ProgramURI="x-rincon-buzzer:0" ProgramMetaData="" PlayMode="SHUFFLE_NOREPEAT" Volume="20" IncludeLinkedZones="0"/></Alarms>`
→ on the Kitchen accessory a Switch subtype `alarm12`, name `Kitchen Sonos Alarm 12`, On true, Track `Sonos Chime`,
Time `07:30:00`. Turning it off sends `UpdateAlarm` with ID 12, StartLocalTime 07:30:00, Duration 01:00:00,
Recurrence WEEKDAYS, Enabled 0, RoomUUID …, ProgramURI `x-rincon-buzzer:0`, ProgramMetaData empty, PlayMode
SHUFFLE_NOREPEAT, Volume 20, IncludeLinkedZones 0.

### 8.10 Browse FV:2 (Result unescaped, abridged)

`<DIDL-Lite …><item id="FV:2/5" parentID="FV:2" restricted="false"><dc:title>Jazz Radio</dc:title><upnp:class>object.itemobject.item.sonos-favorite</upnp:class><res protocolInfo="x-sonosapi-stream:*:*:*">x-sonosapi-stream:s5678?sid=254&amp;flags=8224&amp;sn=0</res><r:description>TuneIn Station</r:description><r:resMD>&lt;DIDL-Lite …&gt;&lt;item id="F00092020s5678" parentID="L" restricted="true"&gt;&lt;dc:title&gt;Jazz Radio&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.audioBroadcast&lt;/upnp:class&gt;&lt;desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/"&gt;SA_RINCON65031_&lt;/desc&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</r:resMD></item></DIDL-Lite>`
→ input source 5 `Jazz Radio`, URI `x-sonosapi-stream:s5678?sid=254&flags=8224&sn=0`, type Tuner, not a container;
selecting it on a TV whose zone is in a group sends `SetAVTransportURI` (that URI, escaped, with the rebuilt escaped
DIDL of id `F00092020s5678`, parentID `L`, restricted `true`, title, class, description `TuneIn Station`, desc
`SA_RINCON65031_`) to the group coordinator, then `Play`.

## 9. Gaps and hard parts

- **G1 — `brightness` and `service` storage.** The intended behaviour (README and schema) is that `brightness` applies
  to `switch` (including when `service` is omitted) and `speaker`. In the parser version read, an enum key's value is
  passed to its callback but not stored, so the check "service is switch or speaker" may always fail and
  `brightness` would always be ignored with a warning. Implement the intended behaviour; it only changes the volume
  characteristic type (Volume vs Brightness), which in Homeswift changes that characteristic's iid key.
- **G2 — `resetTimeout` range.** Declared 1–60 with a 500 ms default; an explicit value is clamped to 60 ms. Probably
  intended as milliseconds without that cap; recommend accepting the configured value as milliseconds (clamp to a
  sane range, e.g. 1–60000) and defaulting to 500.
- **G3 — subscription duration.** `subscriptionTimeout` is not passed to the client (always 30 minutes), and the
  TIMEOUT header is built by string concatenation (`Second-180030`). Intended: `Second-<duration+30>`, renewed every
  `<duration>` seconds. Recommend honouring `subscriptionTimeout` and sending a well-formed header; use the duration the
  player returns if shorter.
- **G4 — SSDP listening.** The passive listener binds UDP 1900 without joining 239.255.255.250; implementers should
  join the group (on each IPv4 interface) to receive alive messages reliably.
- **G5 — Replacement on address change.** A discovery hit with a new address replaces the client in the platform's
  table while existing accessories keep the old client (which follows its own address changes from topology events).
  Follow the address on one client per player id instead.
- **G6 — Lost after 600 s.** The periodic check reads a non-existent field, so "unseen for 10 minutes" never marks a
  player lost; only vanished devices do. Decide whether to implement the intended 600 s rule.
- **G7 — Slave LED StatusFault.** Not exposed on slave LED services (typo); expose it or not — changing it adds a
  characteristic.
- **G8 — New alarm services' initial values** are not applied until the next alarm list change; apply them on creation.
- **G9 — Favourite order and duplicates.** Favourites are keyed by title in an insertion-ordered map: duplicate titles
  collapse to the last one, and titles that are canonical non-negative integers (e.g. "538") are ordered first,
  ascending. Input source numbers (and so HomeKit's mapping) depend on this order. Keep Sonos's order and decide
  whether to reproduce these two quirks.
- **G10 — Channel labels by sorted position** (§3.4) can mislabel satellites (names and LED subtypes like
  `ledLS` for a sub). LED subtypes derive from it, so changing the algorithm changes service identity for existing
  users. Recommended: reproduce it exactly.
- **G11 — Signed integers in events.** The original only converts all-digit strings to integers, so negative bass,
  treble or EQ levels arrive as strings. Parse signed integers.
- **G12 — Metadata absent.** If an AVTransport event has `CurrentTrackURI` but no `CurrentTrackMetaData`, the original
  fails on that event; treat missing metadata as empty.
- **G13 — "Leaving" flag** (§5.2) makes non-coordinators stop copying from their coordinator after their first own
  AVTransport event; members' own events normally carry the group state anyway.
- **G14 — TV flag flicker.** Partial AVTransport events without a track URI set the TV flag false immediately.
- **G15 — Associated-player waits.** Re-associating on every topology rescan renews existing subscriptions, which don't
  produce an initial event, so each wait can run to its full `timeout` and warn. Wait only after new subscriptions.
- **G16 — Accessory UUID.** Homebridge derives the HAP accessory UUID from HAP-NodeJS's `uuid.generate(id)`
  (SHA-1-based); Homeswift's stable keys come from the accessory id, so the ids of §4.1 (and the service subtypes and
  characteristic UUIDs above) are what has to stay identical. Homeswift's convention of prefixing ids with the
  platform name must be reconciled with keeping these ids.
- **G17 — Not determined:** the exact TIMEOUT the players grant; Sonos's limit on `maxFavourites`-sized TV services
  (HomeKit's own limit on InputSource services); behaviour for more favourites than `maxFavourites` − 5 (they push the
  chime and later favourites past the last service, unmapped); what SOAP faults the players return for refused actions
  (the original doesn't distinguish them).
- **Hard parts:** the nested escaped XML (LastChange inside a property, DIDL metadata inside LastChange, escaped twice);
  household association and topology fan-out without extra requests; group following (coordinator writes, member
  copies, target coordinator); the TV accessory's 96 pre-created input sources reconfigured in place; keeping ids,
  subtypes and characteristic sets identical so existing HomeKit homes survive.
