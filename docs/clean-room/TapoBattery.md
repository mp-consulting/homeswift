# Tapo battery camera: battery level and charging state: functional specification

## 0. Provenance

- [src1] https://github.com/JurajNyiri/pytapo, commit `088d14fc9873351ab0e1bb86267b57d51451ecb2` (2026-10-23), the
  same checkout as TapoPTZ.md. Files read: `pytapo/__init__.py` (`getBatteryStatus`, `getBatteryPowerSave`,
  `getBatteryOperatingMode`, `getBatteryOperatingModeParam`, `getChargingMode`, `getPowerMode`, `getBatteryStatistic`,
  `getBatteryConfig`, `getBatteryCapability` and their setters, `getBasicInfo`, `getMost`), `test_pytapo.py`
  (searched: no battery test), `README.md`. MIT, "Copyright (c) 2020 Juraj Nyíri". pytapo has **no fixtures or canned
  replies** for any battery call.
- [src2] https://github.com/JurajNyiri/HomeAssistant-Tapo-Control, commit `6d2c8adb81f3551070ec62fd9590f26254df145a`
  (2026-10-23). Files read: `custom_components/tapo_control/sensor.py` (the battery sensor), `utils.py`
  (`isBatteryPowered`, `getCamData`, `convertBasicInfo`, the media-sync interval), `__init__.py` (the update loop and
  the battery interval), `const.py`, `binary_sensor.py`, `switch.py`, `select.py` (searched: no battery entity),
  `README.md` (battery and solar notes). Apache-2.0.
- [src3] https://github.com/python-kasa/python-kasa, commit `9478ed25ac9fc72ddafcbdf6bd1f9328e8632df4`. Files read:
  the captured replies `tests/fixtures/smartcam/C460(CA)_1.0_1.2.0.json` (a battery/solar camera),
  `TD21(EU)_2.0_1.1.5.json` (a battery doorbell at 7 %), `child/D230(EU)_1.20_1.1.19.json` and `H200(EU)_1.0_1.3.6.json`
  (a hub and its battery doorbell), the other `smartcam/*.json` (mains cameras, for what they lack), and
  `kasa/smartcam/modules/battery.py` (how it reads the same keys). GPL-3.0. Read for wire facts only.
- [src4] The Tapo iOS app, `/Applications/Tapo.app` (version 3.22.501, build 32510), as in TapoPTZ.md [src4].
  **Static inspection only**: `strings` (default length and `-n 2`) of the unencrypted frameworks `TPCameraNetwork`,
  `TPIoTCloudClient`, `IotSwiftSDK`, `TPAppCloudNetwork`, `TPIPCNotificationCenter`; `en.lproj/IPCamera.strings`
  (converted to JSON with `plutil`); a search of the main executable for the two notification type names only. Where
  I group a key with a method, that is **inferred** from the order of the strings in the binary (a string appears once,
  at its first use, so a key shared with an earlier method is not repeated next to a later one). The app was not run;
  no traffic was captured; no camera or TP-Link server was contacted. Proprietary (TP-Link).
- [src5] This repository: docs/clean-room/TapoPTZ.md (sections 2–4, 6, 7: the control API, its envelope, battery
  cameras, errors), TapoCamera.md (sections 8, 12: standby, what wakes the camera), TapoCloudEvents.md (sections 4.4,
  5.1, 5.3, 6.3, 7: cloud hosts and headers, the notification inbox, what wakes the camera), and
  `Plugins/Tapo/Sources/TapoControl.swift` (only to know that the implementer has `call(method, params)` returning an
  entry's `result`), `TapoCloud.swift` (that `details` and the notification inbox are already called).
- Downloads were shallow clones into the scratchpad, only read; nothing was executed. Written by the spec writer;
  **contains no source code** from any source. Labels: **[srcN]** shows which source says it; **inferred** = my
  reading, not seen working; **Recommendation** = advice beyond the sources. Every value in the examples that is not
  attributed to a capture is invented.

## 1. Scope and the short answer

- The camera reports its battery in the **control API** (port 443, TapoPTZ.md sections 2–4), in the reply to
  **`getDeviceInfo`** (`device_info.basic_info`): `battery_percent` (integer 0–100), `battery_charging` (string, `"NO"`
  when not charging), `low_battery` (boolean, the camera's own judgement), `power` (`"BATTERY"`, and per the app
  `"ADAPTER"` or `"SOLAR"`), plus `battery_overheated`, `power_save_mode`, `power_save_status` [src2, src3, src4].
  This is what Home Assistant's battery sensor reads [src2] and what three captured battery devices answer [src3].
- A dedicated `getBatteryStatus` (`{"battery":{"name":"status"}}`) exists [src1, src4]; its reply shape is not in any
  capture (section 2.3). It is not needed for HomeKit.
- The control API answers **only while the camera is awake** (TapoPTZ.md 6.1). So the battery can be read
  without cost only when something else has already woken it: a live view (TapoPTZ.md 6.3), Setup.
- **No-wake route: none confirmed.** The cloud device list, `/details` and `/rt-info` carry no battery field (section
  4). The one candidate is the cloud **thing shadow** (`/v1/things/{id}/shadows`, and its MQTT update topic): the app
  has a method that updates a camera's battery information from the shadow's reported states, and battery-named shadow
  keys, but no source shows a camera's shadow on the wire (section 4.3). The notification inbox's `CameraLowBattery`
  and `BatteryEmpty` messages are a no-wake **event** (a threshold was crossed), not a level (section 4.4).
- Nothing is C675D-specific in the sources: no capture of a C675D's `getDeviceInfo`. The keys are the same across the
  C460 (camera), TD21 and D230 (doorbells) [src3]; that the C675D answers the same is **inferred**.

## 2. Requests on the control API

All requests go in a `multipleRequest` (TapoPTZ.md 4); the examples show one entry of `requests` and the matching entry
of `responses`. The implementer's `call(method, params)` returns the entry's `result`, which is what each "Result"
below shows.

### 2.1 `getDeviceInfo`: the one to use

Request entry [src1 `getBasicInfo`, also in `getMost`]:

```json
{"method":"getDeviceInfo","params":{"device_info":{"name":["basic_info"]}}}
```

Result: `{"device_info":{"basic_info":{…}}}`. Captured examples (identifiers masked by the capturer) [src3]:

```json
{"device_info":{"basic_info":{
  "device_type":"SMART.IPCAMERA","device_model":"C460","hw_version":"1.0",
  "sw_version":"1.2.0 Build 250910 Rel.70120n","mac":"3C-78-95-00-00-00","dev_id":"0000000000000000000000000000000000000000",
  "power":"BATTERY","battery_percent":100,"battery_charging":"NO","low_battery":false,"battery_overheated":false,
  "power_save_mode":"off","power_save_status":"off","region":"CA","features":3}}}
```

```json
{"device_info":{"basic_info":{
  "device_type":"SMART.TAPODOORBELL","device_model":"TD21","hw_version":"2.0",
  "power":"BATTERY","battery_percent":7,"battery_charging":"NO","low_battery":true,"battery_overheated":false,
  "power_save_mode":"off","power_save_status":"off"}}}
```

(The captures have about 30 more keys: alias, ids, location, `sw_version`, …; they are irrelevant here and must be
ignored.)

| Key | Type | Meaning, values |
|---|---|---|
| `battery_percent` | integer | State of charge, percent, 0–100. Seen: 100, 90, 7 [src3]. Home Assistant shows it as is, unit % [src2]. Present only on battery devices: no mains camera capture has it, and Home Assistant creates the sensor only when the key is present [src2, src3]. |
| `battery_charging` | string | `"NO"` when not charging (every capture) [src3]. The other values are **not captured**. The app distinguishes Charging, Charged / Fully Charged, and charging paused by temperature (its status page strings), and keeps both a string `batteryCharing` and booleans `charging`, `chargingComplete` in its models [src4]. python-kasa treats `yes`, `true`, `1`, `charging`, `on` (any case) or a JSON `true` as charging and anything else as not [src3 `battery.py`]. See section 5.2. |
| `low_battery` | boolean | The camera's own low-battery flag. `true` at 7 %, `false` at 90 % and 100 % [src3]. Its threshold is not stated anywhere (section 5.3). |
| `power` | string | Power source. `"BATTERY"` in every capture [src3]; the app's strings next to the `basic_info` keys are `BATTERY`, `ADAPTER`, `SOLAR` [src4]. Home Assistant counts a device as battery-powered when `power` **or** `power_mode` (in `basic_info`) is `"BATTERY"` or `"SOLAR"` [src2], so some firmware reports `power_mode` there instead. Absent on mains cameras [src3]. |
| `battery_overheated` | boolean | The battery is too hot (the app: "Charging paused: Temperature too high") [src3, src4]. |
| `power_save_mode`, `power_save_status` | string | `"off"` seen; the setter takes `"auto"` or `"off"` (`setBatteryPowerSave`, section 2.4) [src1, src3]. The app turns Power Saving Mode on automatically below 10 % (its strings) [src4]. Not needed for HomeKit. |
| `battery_chg_temp_status` | string | In the app's key list for `basic_info` [src4], not captured. The app's adjacent value strings `NORMAL`, `QUICK`, `HALT`, `COOL`, `WARM`, `INCONSISTENT` look like charge-temperature states (**inferred**). |

A hub's child list (`child_info_from_parent` of a hub-paired doorbell) adds `battery_installed` (1), `battery_voltage`
(millivolts: 4073, 4022) and `battery_temperature` (°C: 5, 3) [src3; python-kasa divides the voltage by 1000]. A
C675D on its own Wi-Fi is not a hub child; these may or may not appear in its own `basic_info`.

### 2.2 Does the camera have a battery

- Presence of `battery_percent` in `basic_info` (Home Assistant's test) [src2], or `power`/`power_mode` in
  `{BATTERY, SOLAR}` [src2].
- The component list: `getAppComponentList` lists `{"name":"battery","version":3}` on the C460, TD21 and the hub's
  doorbell [src3]; mains cameras' lists lack it (**inferred** from the fixtures).
- **Recommendation:** decide at Setup from the first `getDeviceInfo` (the camera is awake then); a battery camera
  model (C675D) always gets the Battery service.

### 2.3 `getBatteryStatus`

Request entry [src1]: `{"method":"getBatteryStatus","params":{"battery":{"name":"status"}}}`. The app has the same
method (`IPCTSGetBatteryStatusRequest`) [src4]. pytapo does not include it in `getMost`; nobody parses its reply.

Result: **not captured.** By the string order in the app, the method's new keys are `power_mode`, `battery_voltage`,
`battery_capacity`, `battery_temperature`, `battery_vendor`, `battery_model` (keys already used earlier, such as
`battery_percent`, `battery_charging`, `low_battery`, would not be repeated) [src4]. The expected shape (**inferred**,
by analogy with every other `name` read, whose reply nests under the same two keys):

```json
{"battery":{"status":{"battery_percent":82,"battery_charging":"NO","power_mode":"SOLAR",
                      "battery_voltage":4012,"battery_temperature":18}}}
```

**Recommendation:** do not depend on it. If wanted (diagnostics), send it in the same `multipleRequest` as
`getDeviceInfo` and read `battery.status` defensively; an unsupported-method code (TapoPTZ.md 7: `-40105`, `-40210`,
`-40106`) means skip it from then on.

(The app's Kasa camera SDK, `IotSwiftSDK`, has a different protocol for Kasa cameras, module
`smartlife.cam.ipcamera.battery`, with `battery_installed`, `battery_percent`, `battery_charging`, `battery_capacity`,
`battery_temperature`, `power` [src4]. It is not the Tapo control API; do not mix them.)

### 2.4 The other battery reads (not needed)

All take `{"battery":{"name":"<x>"}}` except the statistic [src1]; result under `battery.<x>`:

| Method | `params` | What it is [src1, src4] |
|---|---|---|
| `getPowerMode` | `{"battery":{"name":"power"}}` | The power mode. The app's strings for power sources and modes: `adapter`, `solar`, `wired_always_on`, `wired_wakeup`, `plug_in` and `W-ALWAYS-ON`, `W-WAKEUP`, `PLUG-IN` (doorbells' wired modes, the C-series "Plug-In Mode") [src4]. Reply keys not captured; probably `power_mode` (**inferred**). |
| `getChargingMode` | `{"battery":{"name":"charging_mode"}}` | `charging_privacy_mode` (`on`/`off`: privacy mode while charging), `adapter_mode` [src1, src4]. |
| `getBatteryCapability` | `{"battery":{"name":"capability"}}` | Flags: `charging_use_support`, `charging_privacy_mode_support`, `adapter_mode_support`, `battery_use_time_support`, `battery_percent_info_support`, `battery_operating_mode_support`; ranges `battery_power_mode_range`, `battery_operating_mode_range` [src4, by string order]. |
| `getBatteryPowerSave` | `{"battery":{"name":"power_save"}}` | `enabled` (`auto`/`off`), `cur_status` [src1, src4]. |
| `getBatteryOperatingMode` / `…Param` | `{"battery":{"name":"operating"}}` / `"operating_mode_param"` | Working mode: `battery_life_first`, `monitor_performance_first`, `super_power_saving`, `customized`; the param's `config_array[].mode` lists the allowed ones [src1, src4]. |
| `getBatteryConfig` | `{"battery":{"name":"config"}}` | Display options `show_on_liveview`, `show_percentage`, `low_power` [src1, src4]. |
| `getBatteryStatistic` | `{"battery":{"statistic":{"days":30}}}` | Per-day/hour history: `bat_per`, `bat_status`, `charging`, `bat_usage`, `solar_charge_cap`, `day_runtime`, `hour_runtime`, `hour_num`, `day_num`, `bat_chg_temp_status` [src1, src4 by string order]. Shapes unknown. |
| `getBatteryPlugInCondition` | (shape unknown) `plug_in_condition` | Whether Plug-In Mode can be used [src4]. |

## 3. What needs the camera awake

| Route | Gives | Wakes / needs awake |
|---|---|---|
| Control API `getDeviceInfo` (2.1) | level, charging, low, source | **Needs it awake.** A request to a sleeping camera may hang (TapoPTZ.md 6.1); each exchange keeps it awake longer (TapoPTZ.md 6.2). |
| Control API `getBatteryStatus` and 2.4 | same, more detail | Same. |
| Cloud passthrough / `services-sync` carrying the same requests | same | **Wakes it** (TapoCloudEvents.md 7). Never. |
| Cloud lists, `/details`, `/rt-info` | nothing about the battery | No wake (section 4). |
| Cloud thing shadow (4.3) | possibly level, charging, low | No wake (cloud-held); **content unverified**. |
| Notification inbox (4.4) | "low" and "empty" events | No wake. |

Home Assistant reads `getDeviceInfo` with the rest of `getMost` at most every **600 s** on battery and solar devices
(`update_interval_battery`, user-adjustable) [src2], i.e. it does wake or keep awake the camera every 10 min; its own
notes say battery cameras' bulk work is skipped "to let them return to sleep sooner" [src2 README]. That interval is a
battery cost Homeswift should not copy.

## 4. Cloud routes that do not reach the camera

### 4.1 Device lists

`getDeviceListByPage` and `/v2/things` (TapoCloudEvents.md 4.1, 4.2): their fields (`deviceId`, `alias`, `deviceModel`,
`status`, `fwVer`, …) include nothing about power or battery; the app's response model for the list
(`TPAppCloudNetwork`) has no battery-named field at all [src4]. **No battery here.**

### 4.2 `/v1/things/{id}/details` and `/rt-info`

The details model's fields are listed in TapoCloudEvents.md 4.4 (route 1): `ip`, `mac`, `ssid`, `model`, firmware and
hardware ids, … — no battery. `/rt-info` carries Wi-Fi `rssi`, `signalLevel`, jamming, memory and load figures
(TapoCloudEvents.md 4.4.1) — no battery. **No battery here.**

### 4.3 The thing shadow (the only candidate, unverified)

What the app shows [src4]:
- Cloud paths in `TPIoTCloudClient`: `GET /v1/things/{thingName}/shadows` (one device) and `/v1/things/shadows` (several;
  the list request takes `thingNames`, `deviceType`, `specificProperties`), `/v1/things/shadows/specific-properties`;
  the shadow's keys include `reported`, `desired` and a `version` ("ShadowVersion Low, need retry"); TapoCloudEvents.md
  4.4.1 lists `thingName`, `version`, `reported`, `desired`, and where `reported` sits in the body (under a `state`
  object or at top level) is not visible. They are
  on the NBU app server, like `/details` (TapoCloudEvents.md 4.4.1: same host resolution and the headers of 5.1)
  (**inferred** from their neighbours in the binary).
- An MQTT topic `<prefix>/things/<thingName>/shadow/update/accepted` that the app subscribes to (`subscribeShadowTopic`,
  `handleShadowUpdateTopicMessage:`), delivering shadow changes as they happen (TapoCloudEvents.md 6.3 on the MQTT
  gateway, exploratory).
- In the camera layer (`TPCameraNetwork`): `-[TPCameraClient thingShadowDidChanged:]`,
  `updateDeviceBatteryInfoWithThingShadowResportedStates:` and `updateDeviceWithThingShadowResportedStates:`, and,
  next to the notification `kTPCameraClientShadowUpdatedNotification`, the key strings `at_low_battery`,
  `batteryRemainingPercent`, `batteryCharging`, `powerSaveMode`, `powerSaveStatus`, `batteryOverheated`,
  `batteryChgTempStatus`, `powerOn`, `in_alarm`, `sdStatus`, `antiTheftStatus`, `snoozeAlertStatus`. That these are the
  keys of a camera shadow's `reported` object is **inferred** from their order; their types are unknown (presumably a
  number for `batteryRemainingPercent`, booleans or strings for the rest).
- So: the app reads a battery camera's battery state from the cloud shadow, which the camera updates when it is awake
  and connected to the cloud. Reading the shadow does not reach the camera (cloud-held, TapoCloudEvents.md 4.4.1).

None of the open-source clients reads a camera's shadow; nothing here was seen on the wire. **Recommendation:** treat
it as an experiment: with the user's account, `GET {nbuAppServer}/v1/things/{deviceId}/shadows` with the NBU headers,
log the body's key names (not values) once at debug level, and use it only if its `reported` object holds a percentage-like
key. If it does, it is the best source: no wake, and as fresh as the camera's last cloud check-in.

### 4.4 The notification inbox

`getAppNotificationByPage` (TapoCloudEvents.md 5.3) takes `msgTypes` that include `CameraLowBattery` and
`BatteryEmpty` [src4]. The app's texts for them: "Your camera has only {1} battery left. Please charge it as soon as
possible." and, when Power Saving Mode turned itself on, the same with "Power Saving Mode has been turned on
automatically"; `BatteryEmpty`: "Your camera is about to power off. Please recharge immediately." (doorbell variants
say "doorbell") [src4 strings]. Whether the inbox entry's `content` carries the filled-in percentage, and whether
the message has any structured battery field, is unknown; the entry fields seen are those of TapoCloudEvents.md 5.3
(`msgType`, `deviceId`, `time`, `title`, `content`, …). Whether these messages need the camera's notification switches
on, as detection messages do, is unknown (**inferred**: yes). No wake.

**Plain statement:** no source shows a route that gives the battery **percentage** without the camera awake. The shadow
(4.3) probably does and must be tried; the inbox (4.4) gives the low and empty events.

## 5. HomeKit mapping

The Battery service (`Battery Level`, `Charging State`, `Status Low Battery`) on the camera's accessory; on the C675D,
**one** Battery service for the device, on the first lens's accessory (or on each lens's accessory with the same
values) — **Recommendation**: on each, since HomeKit shows a battery per accessory and both lenses share it.

### 5.1 Battery Level

`battery_percent`, clamped to 0–100, rounded if a number with a fraction arrives. Missing → keep the last value (5.5).

### 5.2 Charging State (0 not charging, 1 charging, 2 not chargeable)

- `2` (not chargeable) only when the device has no battery (2.2), which does not happen for a battery camera model;
  a C675D always has a rechargeable battery, so never `2` for it.
- `1` when `battery_charging` is truthy: a JSON `true`, or a string other than `"NO"` whose lower-case form is not
  `no`, `false`, `0`, `off`, `none`, `""`, `full`, `finished`, `charged`, `complete` (**Recommendation**; only `"NO"` is
  captured). This also catches unknown "charging" spellings such as `"YES"` or `"CHARGING"`.
- `0` otherwise, including "fully charged" (HomeKit has no "full" state) and charging paused by temperature
  (`battery_overheated` true: report `0`).
- **Solar:** `power` = `"SOLAR"` says the camera is on a solar panel, **not** that it is charging now (the app: solar
  charging pauses with little sun, near full, or at extreme temperatures). Use `battery_charging` alone for the state;
  never derive `1` from `power`.
- `power` = `"ADAPTER"` (or a Plug-In Mode): mains-fed; use `battery_charging` as well (charging until full, then `0`).

### 5.3 Status Low Battery (0 normal, 1 low)

- When `low_battery` is present, use it: it is the camera's own judgement and the one the app's Low Battery state and
  its `CameraLowBattery` notification follow (**inferred**).
- Without it: `battery_percent` < 20 → `1` (**Recommendation**; the sources give no camera threshold for "low". The app
  turns Power Saving Mode on below 10 % [src4], which is later than a useful warning. 20 % is HomeKit's common
  choice). Optionally a user setting, but not needed.
- A `CameraLowBattery` notification for the device (4.4) → set `1` at once; `BatteryEmpty` → set `1`, and keep the
  level as last read (do not invent a value). The next real reading overrides both.

### 5.4 Status Fault, staleness

The Battery service has no "stale" characteristic. Keep the last values and their time; do not mark the accessory
unreachable because the battery is old.

### 5.5 Persistence

Keep the last reading (`battery_percent`, `battery_charging`, `low_battery`, `power`, the time it was read) per Device Id
on disk (e.g. the plugin's `jsonFile`, it is not a secret), restore it at start so HomeKit sees a level before the next
live view, and write it again only when a value changed.

## 6. When to read (Recommendation)

1. **At Setup** (the camera is awake): `getDeviceInfo`, decide 2.2, store the first reading.
2. **During a live view**: once the control session is open for that live view (TapoPTZ.md 6.3: the plugin opens it
   lazily; for the battery, open it a few seconds after the stream has started, when the camera has proved awake),
   send one `multipleRequest` with `getDeviceInfo` (optionally `getBatteryStatus`). Read again every 5 min while the
   live view lasts (charging can change it), never faster. Close with the stream as TapoPTZ.md says.
3. **From the cloud, without the camera**: if the shadow (4.3) proves to hold the battery, read it at start and every
   30 min (and on each shadow update if the MQTT route is ever implemented); this replaces nothing above, it fills the
   gaps between live views. On each inbox poll that already runs for motion (TapoCloudEvents.md 5.3), add
   `CameraLowBattery` and `BatteryEmpty` to `msgTypes` and apply 5.3.
4. **Never** open a control session only to read the battery, never poll the control API on a timer, never use the
   cloud passthrough for it.
5. Timeouts and errors: as TapoPTZ.md 6.1 and 7 (connect 3 s, request 10 s, a timeout is "asleep", not a failure). A
   failed battery read is logged at debug level and keeps the last values; it never ends the live view or retries a
   login on its own. A missing key leaves that characteristic as it was. An unsupported-method code on
   `getBatteryStatus` stops sending it for that camera.

## 7. Test vectors (data)

Each row: the `basic_info` keys of a `getDeviceInfo` result → Battery Level, Charging State, Status Low Battery.

| # | `basic_info` (relevant keys) | Level | Charging | Low | Note |
|---|---|---|---|---|---|
| 1 | `{"power":"BATTERY","battery_percent":100,"battery_charging":"NO","low_battery":false}` | 100 | 0 | 0 | C460 capture [src3] |
| 2 | `{"power":"BATTERY","battery_percent":7,"battery_charging":"NO","low_battery":true}` | 7 | 0 | 1 | TD21 capture [src3] |
| 3 | `{"power":"BATTERY","battery_percent":90,"battery_charging":"NO","low_battery":false,"battery_overheated":false}` | 90 | 0 | 0 | D230 capture [src3] |
| 4 | `{"power":"SOLAR","battery_percent":64,"battery_charging":"YES","low_battery":false}` | 64 | 1 | 0 | invented; charging spelling unverified |
| 5 | `{"power":"SOLAR","battery_percent":64,"battery_charging":"NO","low_battery":false}` | 64 | 0 | 0 | solar, not charging now |
| 6 | `{"power":"ADAPTER","battery_percent":100,"battery_charging":"FINISHED"}` | 100 | 0 | 0 | invented; "full" is not charging; no `low_battery` → 100 ≥ 20 |
| 7 | `{"power_mode":"BATTERY","battery_percent":15}` | 15 | 0 | 1 | invented; no `low_battery`, below 20 → low; no `battery_charging` → 0 |
| 8 | `{"power":"BATTERY","battery_percent":30,"battery_charging":true,"low_battery":false}` | 30 | 1 | 0 | boolean form |
| 9 | `{"power":"BATTERY","battery_percent":105,"battery_charging":"NO","low_battery":false}` | 100 | 0 | 0 | clamped |
| 10 | `{"power":"BATTERY","battery_charging":"NO"}` with a stored level 55, low 0 | 55 | 0 | 0 | missing percent keeps the last |
| 11 | `{"power":"BATTERY","battery_percent":40,"battery_charging":"CHARGING","battery_overheated":true,"low_battery":false}` | 40 | 0 | 0 | paused by heat |
| 12 | `{"device_model":"C200","sw_version":"…"}` (no battery keys) | — | — | — | no Battery service (mains camera) |

Envelope vector: the decrypted reply

```json
{"result":{"responses":[{"method":"getDeviceInfo","result":{"device_info":{"basic_info":{"power":"BATTERY","battery_percent":7,"battery_charging":"NO","low_battery":true}}},"error_code":0},
                        {"method":"getBatteryStatus","result":{},"error_code":-40210}]},"error_code":0}
```

→ Level 7, Charging 0, Low 1; `getBatteryStatus` marked unsupported, no error surfaced.

Notification vector: stored level 22, low 0; the inbox returns
`{"msgType":"CameraLowBattery","deviceId":"<the camera's id>","time":1762340000,"content":"Your camera has only 19% battery left. Please charge it as soon as possible."}`
→ Level stays 22 (do not parse the text), Low 1, Charging unchanged. A later `getDeviceInfo` with `low_battery:false`
and `battery_percent:60` → Low 0, Level 60.

## 8. Gaps and open questions

1. A C675D's `getDeviceInfo` reply: whether it has `battery_percent` / `battery_charging` / `low_battery` like the C460,
   and whether `power` reads `"SOLAR"` when on its panel. To capture on the user's camera during a live view.
2. The values of `battery_charging` other than `"NO"` (charging, full). 5.2 is written to survive any spelling.
3. `getBatteryStatus`'s reply shape (2.3) and `getPowerMode`'s keys.
4. The thing shadow (4.3): whether a camera has one, whether its `reported` object holds the battery keys listed, their
   types and units, and how often the camera updates it while sleeping (only on wake, presumably).
5. The low-battery threshold behind `low_battery` and `CameraLowBattery`, and whether the inbox entry carries the
   percentage in a field.
6. Whether the inbox's `CameraLowBattery`/`BatteryEmpty` messages need the camera's notification switches, like
   detection messages.
