# Roborock: suction, mop, rooms, locate and errors (functional specification)

A supplement to `Roborock.md`. It specifies what the Roborock plugin needs to select the suction and mop modes, clean
chosen rooms (on any floor map), make the robot announce itself, and clear an error. Spot and zone cleaning are out of
scope. Wire framing, encryption, transports, the request id and the parameter conventions are as in `Roborock.md` §4
(in particular §4.3: a request's inner object is `{"id":<requestId>,"method":"<method>","params":<params>}`; a command
without arguments sends `[]`; a single number is sent wrapped as `[n]`).

## 0. Provenance

| | Source A | Source B |
|---|---|---|
| Project | https://github.com/tasict/homebridge-roborock-vacuum | https://github.com/Python-roborock/python-roborock (the `Humbol/python-roborock` address no longer resolves; this is where the project now lives) |
| Commit | `c16594fdd004e3d7b8fef9142d7f62ff02f0a006` (2026-10-21), the commit `Roborock.md` names | `8e471dc43c2ed1f3626636651b1e9d1b1b85dffe` (2026-11-02) |
| Licence | MIT ("Copyright (c) 2018-2019 Nico Hartung") | **Apache License 2.0** (`LICENSE`), not GPL-3 |

Only facts are taken: method names, parameter shapes, numeric codes and decision rules. "A:" and "B:" before a path
name the source. Where the two disagree, both are stated. "Unknown" means neither source settles it.

## 1. Suction (`fan_power`)

### 1.1 Codes

The robot reports suction as `fan_power` in `get_status` (and in status pushes, schema id 123; `Roborock.md` §4.4).

The current family ("V1 protocol" robots, every model the plugin supports), B: `roborock/data/v1/v1_clean_modes.py`
(`VacuumModes`):

| Code | Name | Notes |
|---|---|---|
| 101 | Quiet | |
| 102 | Balanced | The default "on" value in both sources (A: `roborockLib/roborockAPI.js`, `getCleanModeCapabilities`, `fanDefault: 102`). |
| 103 | Turbo | |
| 104 | Max | |
| 105 | Off **or** Gentle | One code, two meanings: "Off" (mop only, no suction) on robots that support pure mopping (§3, `purecleanmop`); "Gentle" on the others. |
| 106 | Custom | The per-room customised suction set in the Roborock app. |
| 108 | Max+ | |
| 109 | "Off, raise main brush" | Listed in B's enum. B: `get_mop_only_vacuum_mode` says the app still sends 105 for mop only, even on robots that lift the brush; 109 is never sent by B. |
| 110 | Smart mode | SmartPlan. |

There is no 107 in either source.

Older families, only in B: `roborock/data/v1/v1_code_mappings.py` (`RoborockFanSpeedV1` 38/60/77/90, `RoborockFanSpeedV3`
38/60/75/100, `RoborockFanSpeedE2` 41/50/68/79/100, `VacuumModesOld` 38/60/75/100). They are percentages from the Xiaomi
era. Nothing in B selects them by model and nothing in A knows them: unknown which robots use them. The plugin should
treat any value outside the table above as an unnamed level (show it, never write it).

A's own comment says the supported models share "fan 101-105, water 200-203" (A: `roborockAPI.js`, above
`getCleanModeCapabilities`).

### 1.2 Which codes a robot offers

B: `v1_clean_modes.py`, `get_clean_modes(features)`, builds the list in this order:

1. Always Quiet 101, Balanced 102, Turbo 103, Max 104.
2. Max+ 108 when `cleanmode_maxplus` **or** `cleanmode_none_purecleanmop_with_maxplus` (§3).
3. Off 105 when `cleanmode_purecleanmop`; otherwise Gentle 105.
4. Smart mode 110 when new-feature-string bit 55 (`SMART_CLEAN_MODE_SET`).
5. Custom 106 when `mop_shake_module` or `mop_spin_module` (B calls it `is_customized_clean_supported`).

A offers no list: it writes only 105 (off) and the robot's current or default value (A: `src/vacuum_matter_accessory.ts`,
the clean-mode handler).

### 1.3 Setting it

Method `set_custom_mode`, params the code wrapped in a list.

```json
{"id":42,"method":"set_custom_mode","params":[103]}
```

A: `roborockAPI.js` `setCleanModeParameters` calls `vacuum.command(duid, "set_custom_mode", n)`, and
`roborockLib/lib/vacuum.js` `command` wraps a number as `[n]`. B: `roborock/testing/v1_simulator.py` accepts `[n]` (also
`{"fan_power": n}`); B's test `tests/testing/test_v1_simulator.py` sends `[105]`. The reply is `["ok"]` (Roborock.md §5.1).
After any `set_…` A immediately sends the matching `get_…` (here `get_custom_mode`, params `[]`, reply e.g. `[102]`;
B: `docs/V1_API_COMMANDS.md` "get_custom_mode") to refresh; re-reading `get_status` serves the same purpose.

## 2. Mop

### 2.1 Water flow (`water_box_mode`)

Reported as `water_box_mode` in `get_status` (push schema id 124). B: `v1_clean_modes.py` (`WaterModes`) and
`docs/V1_API_COMMANDS.md` "set_water_box_custom_mode":

| Code | Name(s) |
|---|---|
| 200 | Off (vacuum only) |
| 201 | Low; "Mild" on vibrating-mop robots |
| 202 | Medium; "Standard" on vibrating-mop robots |
| 203 | High; "Intense" on vibrating-mop robots |
| 204 | Custom (per-room, set in the app) |
| 205 | Min |
| 206 | Max |
| 207 | Custom water flow (a 0–100 distance setting) |
| 208 | Extreme |
| 209 | Smart mode |
| 210 | Smart water (water-slide robots) |

B's older `RoborockMopIntensityV2` (`v1_code_mappings.py`) has 200 off, 201 low, 202 medium, 203 high, 207 custom.

**Water-slide robots** (new-feature-string bit 106; A additionally treats model `roborock.vacuum.a298` as one even
without the bit, A: `getCleanModeCapabilities`) report and accept 200 for off and otherwise `220 + position`, the app's
slider position 1–30. The app groups positions into named ranges (B: `_WATER_SLIDE_RANGES`): 1–3 "slight" (B writes
221), 4–7 "low" (225), 8–12 "gentle" (230), 13–17 "medium" (235), 18–22 "moderate" (240), 23–27 "high" (245), 28–30
"extreme" (250). A position below 1 or above 30 has no name. The default mopping value: B 235, A 233. Writing a classic
value (202) to such a robot is rejected (A's comment; B's comment in `_get_default_mopping_water_mode`).

### 2.2 Which water codes a robot offers

B: `get_water_modes(features)`:

- Water slide: 200, 221, 225, 230, 235, 240, 245, 250 only.
- Otherwise 200; then 201/202/203 (named Mild/Standard/Intense with `mop_shake_module`, Low/Medium/High without);
  207 when robot-new-features bit 2147483648 (`is_custom_water_box_distance_supported`); 208 when `mop_shake_module`
  **and** new-feature-string bit 45 (`MOP_SHAKE_WATER_MAX`); 209 when bit 55; 204 when `mop_shake_module` or
  `mop_spin_module`.

Whether a robot has a water box at all:

- B: `is_support_water_mode`, true when the model's product features include `mop_electronic_module`,
  `mop_shake_module` or `mop_spin_module` (§3). Without it B offers no high-level cleaning modes.
- A: a fixed model list (`Roborock.md` §5.4, A: `roborockLib/lib/deviceFeatures.js` `isWaterBoxSupported`). A polls
  `get_water_box_custom_mode` only for models outside `s4 s5 s5e a08 a10 a40 a140 a95 a159 ss07 s6 a27`
  (A: `roborockAPI.js` `updateDataMinimumData`).

The two lists do not agree for every model; unknown which is right for the disputed ones.

### 2.3 Setting the water flow

Method `set_water_box_custom_mode`, params the code wrapped in a list (A as for `set_custom_mode`; B's docs and
simulator accept `[n]`, the docs also `{"water_box_mode": n}`).

```json
{"id":43,"method":"set_water_box_custom_mode","params":[202]}
```

Mop only = `set_custom_mode` `[105]` plus a water value other than 200; vacuum only = water 200 (B's docs for
`set_water_box_custom_mode`; A's clean-mode handler does the same, sending 105 and the current or default water value
for "Mop", the current or default fan value and 200 for "Vacuum", both non-off for "Vacuum & Mop", and never writing
water on a robot without a water box).

### 2.4 Mop route (`mop_mode`)

Reported as `mop_mode` in `get_status` on robots that have it (B: `v1_containers.py` `Status.mop_mode`); also read with
`get_mop_mode` (params `[]`, reply e.g. `[300]`). A knows `get_mop_mode` as a status read (A: `vacuum.js` `parameterFolders`) but never writes the route.

B: `v1_clean_modes.py` (`CleanRoutes`):

| Code | Name |
|---|---|
| 300 | Standard |
| 301 | Deep |
| 302 | Custom |
| 303 | Deep+ |
| 304 | Fast |
| 305 | Deep+ (China region variant, shown as "deep_plus") |
| 306 | Smart mode |

Which routes a robot offers, B: `get_clean_routes(features, region)`:

- None when the robot has no route setting. B's `is_clean_route_setting_supported` is true when the model has
  `mop_shake_module` or `mop_spin_module`, **or** robot-new-features bit 262144 (`is_shake_mop_set_supported`), **or**
  new-feature-string bit `ROLLER_MOP` (B: `roborock/device_features.py`, end of `from_feature_flags`).
- With `cleanmode_none_purecleanmop_with_maxplus`: exactly Fast 304 and Standard 300.
- Otherwise Standard 300; Deep 301 unless new-feature-string bit 108 (`CLEAN_EFFICIENCY`); Deep+ when the upper-32 bit 9
  of the robot-new-features (`is_careful_slow_mop_supported`): 305 when the region is `cn` **and** not new-feature-string
  mask (2147483648 over the last 8 hex digits, corner clean) **and** mask (16777216, 8) (deep slow plus), else 303;
  Fast 304 when mask (256, 8); Smart 306 with bit 55; Custom 302 with `mop_shake_module`/`mop_spin_module`.

"Mask (m, 8)": the last 8 hex digits of the new-feature string read as a number, ANDed with m (B:
`from_feature_flags`). Bit n of the string is as in `Roborock.md` §5.4.

Method `set_mop_mode`, params the code in a list (B: `docs/V1_API_COMMANDS.md` "set_mop_mode: Parameters: mop_mode 300";
B's simulator reads `params[0]`):

```json
{"id":44,"method":"set_mop_mode","params":[301]}
```

### 2.5 All three at once (`set_clean_motor_mode`)

B's high-level "cleaning mode" (B: `status.py` `set_cleaning_mode`, `v1_clean_modes.py` `get_cleaning_mode_parameters`)
sends one request with an object in a list; `mop_mode` is included only when the robot has route settings:

```json
{"id":45,"method":"set_clean_motor_mode","params":[{"fan_power":102,"water_box_mode":202,"mop_mode":300}]}
```

B's presets: Vacuum = 102/200/300; Vacuum & Mop = 102/default water/300; Mop = 105/default water/300 (only with
`purecleanmop`); Custom = 106/204/302; Smart = 110/209/306. Default water is 202, or 235 on water-slide robots.
B reads the current mode back in this priority: any of 209/110/306 → Smart; any of 106/204/302 → Custom; water not 200
and fan 105 on a `purecleanmop` robot → Mop; water 200 → Vacuum; else Vacuum & Mop. A never sends this method. Which
firmware accepts it is unknown beyond B using it for every V1 robot with a water box.

## 3. Model families and feature flags

B: `roborock/data/code_mappings.py` maps the last part of the model (`roborock.vacuum.<short>`) to a family
("nickname"); an unknown short model is treated as **PearlPlus**. B: `device_features.py` `_BASE_PRODUCT_FEATURE_MAP`
gives each family its product features, then adds `custom_cleanmode` and `cleanmode_purecleanmop` to every family except
those listed in `PRODUCTS_WITHOUT_CUSTOM_CLEAN` and `PRODUCTS_WITHOUT_PURE_CLEAN_MOP`.

| Family (short models) | maxplus | none_purecleanmop_with_maxplus | purecleanmop | mop module |
|---|---|---|---|---|
| Coral (a20 a21), CoralPro (a143 a144), Vivian (a134 a135 a155 a156), PearlPlus (a86 a87), PearlPlusS (a116 a117 a136) | yes | | yes | spin |
| Pearl (a74 a75), PearlS (a100 a101), PearlC (a103 a104), PearlSLite (a122 a123), PearlE (a167 a168), PearlELite (a169 a170) | yes | | yes | spin |
| VivianC (a158 a159) | yes | | yes | spin |
| Ultron (a50 a51), UltronSC (a94 a95), UltronSPlus (a68 a69 a70), UltronSV (a96 a97), Verdelite (a146 a147) | yes | | yes | shake |
| UltronE (a72 a84) | | yes | no | none |
| UltronLite (a73 a85), UltronSE (a124 a125 a139 a140) | | yes | UltronLite no, UltronSE yes | electronic |
| TopazS (a29 a30 a76), TanosS (a14 a15) | | | yes | shake |
| TopazSPlus (a46 a47 a66), TopazSV (a26 a27), TanosSMax (a52), TopazSPower (a62), TopazSC (a64 a65), TanosSPlus (a23 a24) | yes (TanosSPlus no) | | yes | shake |
| TanosSLite (a37 a38) | | | no | electronic |
| TanosSC (a39 a40), TanosSE (a33 a34) | | | no | none |
| Tanos (t6 s6) | | | no | none |
| TanosE (t7 a11), TanosV (t7p a09 a10) | | | no | electronic |
| RubyPlus (t4 s4), RubySC (p5 a08), RubySE (a19) | | | no | none |
| RubySLite (p6 s5e a05) | | | no | electronic |

`custom_cleanmode` is missing only for Tanos, RubyPlus, RubySC and RubySE. (TanosSPlus: `TANOSS_FEATURES` plus camera
features, no maxplus.)

Where the bits come from:

- B reads them from the RPC `app_get_init_status` (fields `new_feature_info`, an integer, and `new_feature_info_str`, a
  hex string; B: `devices/traits/v1/device_features.py`, `v1_containers.py` `AppInitStatus`).
- A reads the same two values from the home data's device entry, `featureSet` and `newFeatureSet` (A: `roborockAPI.js`,
  `new deviceFeatures(this, device.featureSet, device.newFeatureSet, duid)`). They are the same flags: A's shake-mop bit
  262144 and custom-water-distance bit 2147483648 of `featureSet` equal B's `robot_new_features` masks. The plugin
  already has both values (`Roborock.md` §5.4), so it needs no extra RPC.
- B's "upper_32_bits" n is bit n of `floor(featureSet / 2^32)`.

## 4. Rooms

### 4.1 Segments: `get_room_mapping`

```json
{"id":46,"method":"get_room_mapping","params":[]}
```

Reply: a list of entries `[segment_id, iot_room_id, …]` for the **loaded map only** (A: `vacuum.js`; B: `rooms.py`).
`segment_id` is a small integer (16, 17, …) used by the cleaning commands; `iot_room_id` is the cloud room id, sent
as a string by newer firmware (B's docs example `[[16,"14731399",12],[17,"2220009",2], …]`) and compared as a string by
B (`str(iot_id)`). The third element (12, 2, 9, …) is not used by either source; its meaning is unknown. B also accepts
a single flat pair `[segment_id, iot_room_id]` (a reply whose length is 2 and whose first element is not a list); an
entry that is not a list of at least two elements is skipped with a warning. An empty list means no room is named in
the app (A logs a warning, "name your rooms via the mobile app").

Segment ids repeat across floor maps; the mapping must be rebuilt, not merged, when the map changes (A's comment).

### 4.2 Room names

The home data's `rooms` array, `[{"id": <int>, "name": "<text>"}]` (`Roborock.md` §2.7), maps `iot_room_id` to a name.
Shared devices: `GET user/deviceshare/query/<duid>/rooms`, `result` the same shape, the id under `id` or `roomId` (A:
`loadSharedDeviceRooms`; B: `web_api/homes.py`). B, when the mapping holds an iot id it has not seen, refetches
`GET /user/homes/<homeId>/rooms` (`result` the same shape) once per new id (B: `rooms.py` `refresh`). A segment whose iot
id has no name is dropped by A; B names it "Room <segment_id>" (B: `data/containers.py` `NamedRoomMapping`).

### 4.3 Cleaning rooms: `app_segment_clean`

A always sends one object in a list (A: `roborockAPI.js` `app_segment_clean`, `repeat` default 1):

```json
{"id":47,"method":"app_segment_clean","params":[{"segments":[16,17],"repeat":1}]}
```

B's docs give the same shape (`[{"segments":[17,19],"repeat":2}]`, "Supported devices: S8 Pro Ultra"). B's unit test
passes `{"segments":[1,2,3]}` to a mocked channel, which proves nothing about firmware. Neither source ever sends the
older flat form (`[16,17]`), and neither has a rule choosing between the forms by model or firmware: **unknown**. Use
the object form.

Resume a paused room clean with `resume_segment_clean`, params `[]`: `app_start` would restart a full clean (A's comment
on `resume_segment_clean`). A stops with `app_stop` as for any clean. While the robot cleans rooms, `state` is 18
(`Roborock.md` §5.3).

### 4.4 Floors: `get_multi_maps_list`, `load_multi_map`

```json
{"id":48,"method":"get_multi_maps_list","params":[]}
```

Reply: a one-element list holding an object (A takes `result[0]` when the reply is a list; B requires it):
`{"max_multi_map":4,"max_bak_map":1,"multi_map_count":2,"map_info":[{"mapFlag":0,"add_time":1699919699,"length":4,"name":"Home","bak_maps":[{"mapFlag":4,"add_time":1699823921}]},{"mapFlag":1,…,"name":"Boys bathroom",…}]}`
(B: `docs/V1_API_COMMANDS.md`). A keeps entries whose `mapFlag` is a number; an empty `name` becomes "Map <mapFlag+1>".
`bak_maps` are backups, not floors.

The loaded map: `map_status >> 2` from `get_status`; 63 means no map (A: `getCurrentMapFlag`; B: `v1_containers.py`
`current_map`, `const.py` `NO_MAP = 63`).

```json
{"id":49,"method":"load_multi_map","params":[1]}
```

Behaviour around it (A: `roborockAPI.js` `loadMap`, `switchToMap`, `discoverMultiMapRooms`):

- A switches maps only while the robot is docked, `state` 8 or 100 (A: `sceneRunner.js` `DOCKED_STATES`).
- After `load_multi_map` A polls `get_status` every 3 s, at most 4 times, until `map_status >> 2` is the requested
  flag; otherwise the switch failed. B refreshes the status once after the command (B: `maps.py` `set_current_map`).
- Rooms of a map are known only while it is loaded. A learns the other floors' rooms by loading each in turn, reading
  `get_room_mapping` (once more after 7 s when the first answer is empty), and loading the original map again at the
  end; it caches them per `mapFlag`. A refuses a room selection spanning two floors.
- Before a room clean on another floor, A loads that floor, re-reads `get_room_mapping`, and refuses the clean when the
  requested segments are no longer in it ("Rooms changed on the vacuum; try again").
- A asks for the map list only on protocol `1.0` robots. B sends the map trait's commands over the **cloud** only (B:
  `maps.py`, `@common.mqtt_rpc_channel`); A uses its usual local-first transport. Whether the robot answers them
  locally is not stated by B; A's practice is that it does.

## 5. Find the robot

```json
{"id":50,"method":"find_me","params":[]}
```

The robot speaks so it can be found; reply `["ok"]` (A: `roborockAPI.js` `findMe`, `vacuum.command(duid, "find_me", null)`,
which sends `[]`; B: `docs/V1_API_COMMANDS.md` "find_me: Parameters: None"). A maps HomeKit/Matter Identify to it.
`get_status` has an `is_locating` field (B: `Status.is_locating`); neither source reads it.

## 6. Errors

### 6.1 Robot `error_code` (from `get_status`, push id 120)

Sources: B `v1_code_mappings.py` `RoborockErrorCode`; A `src/error_codes.ts` (as in `Roborock.md` §5.3).

B's meanings: 0 none, 1 lidar blocked, 2 bumper stuck, 3 wheels suspended, 4 cliff sensor error, 5 main brush jammed,
6 side brush jammed, 7 wheels jammed, 8 robot trapped, 9 no dustbin, 10 filter wet or blocked, 11 strong magnetic field,
12 low battery, 13 charging error, 14 battery error, 15 wall sensor dirty, 16 robot tilted, 17 side brush error, 18 fan
error, 19 dock not connected to power, 20 optical flow sensor dirty, 21 vertical bumper pressed, 22 dock locator error,
23 return to dock failed, 24 no-go zone detected, 25 camera error, 26 wall sensor error (light touch), 27 VibraRise
jammed, 28 robot on carpet, 29 filter blocked, 30 invisible wall detected, 31 cannot cross carpet, 32 internal error,
34 auto-empty dock: clean it, 35 auto-empty dock voltage error, 36 and 45 wash roller may be jammed, 37 wash roller not
lowered properly, 38 check the clean water tank, 39 check the dirty water tank, 40 reinstall the water filter, 41 clean
water tank empty, 42 check the water filter is installed, 43 positioning button error, 44 clean the dock water filter,
48 water supply error, 49 drain error, 51 temperature protection, 52 cleaning carousel error, 53 cleaning carousel water
full, 54 water carriage dropped, 55 check the cleaning carousel, 56 audio error. No 33, 46, 47, 50.

A's labels cover only 1–19, 21–24, 254 "bin full" and 255 "internal error" (none for 20 or 25–56), and differ from B
for 21 ("laser pressure sensor problem"), 22 ("charge sensor problem") and 23 ("dock problem"); B has no 254 or 255.
Where both have a code, prefer B's meaning; keep A's 254 and 255.

(48, 49, 52–55 are B's identifiers `up_water_exception`, `drain_water_exception`, `clean_carousel_exception`,
`clean_carousel_water_full`, `water_carriage_drop`, `check_clean_carouse`; the English is a reading of those names.)

Dock errors are a separate field, `dock_error_status` (`Roborock.md` §5.3; B: `RoborockDockErrorCode`): 0 ok, 32 no
dustbin or filter, 33 auto-empty fan error, 34 auto-empty jammed, 35 auto-empty voltage error, 38 clean water tank empty,
39 dirty water tank full or missing, 42 maintenance brush jammed, 44 water filter blocked / dirty tank latch open,
46 dustbin not installed, 53 cleaning tank full or blocked.

### 6.2 Clearing an error: `resolve_error`

Both sources clear with `resolve_error`, the code in an **object** (A's comment: the firmware rejects array params):

```json
{"id":51,"method":"resolve_error","params":{"error_code":38}}
```

Rule (A: `roborockAPI.js` `resolveError`; B: `devices/traits/v1/status.py` `resolve_error`): without an explicit code,
refresh `get_status`, then resolve the non-zero `dock_error_status` if any, else the non-zero `error_code`; when both are
0 send nothing. Afterwards refresh `get_status`. Some dock errors (water empty) stay latched until resolved even after
the cause is fixed. A sends it only to protocol `1.0` robots and throws otherwise.

Neither source has a `clear_error` method, and neither uses `app_stop` to clear an error (A's `app_stop` only stops a
clean and cancels a running scene).
