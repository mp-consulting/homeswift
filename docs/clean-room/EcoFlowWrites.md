# EcoFlow writes: functional specification (clean room)

Written by the spec writer. It contains no source code. It describes, in the spec writer's own words, the wire
behaviour of the writes the EcoFlow plugin (`Plugins/EcoFlow`) will gain: the AC, DC (12 V) and USB output switches,
the charge limit (maximum charge %) and the discharge limit (minimum discharge %), on both of the plugin's routes.
Interface names (JSON keys, command codes, topic patterns, protobuf field names and numbers) are quoted because they
are the interface. Models are keyed by the serial prefixes of the plugin README's **Models** table.

## 0. Provenance

| Source | Where | Commit / version | Licence |
|---|---|---|---|
| EcoFlow developer documentation (primary) | https://developer-eu.ecoflow.com/us/document/… (the same pages as developer.ecoflow.com). The site is a single-page app: its text is in the bundle `https://cdn-fe.ecoflow.com/ef-open-platform/static/js/main.b47c052a.js` and its chunks `…/static/js/<id>.<hash>.chunk.js`, read as text on 2026-11-07 | bundle release `ef-open-platform_v2.6.3` | Vendor documentation, no licence; cited, not copied |
| tolwi/hassio-ecoflow-cloud | https://github.com/tolwi/hassio-ecoflow-cloud | `7dcf95109123b5b63570e8a1a571b823fbdaa28d` | Apache-2.0 |
| rabits/ha-ef-ble | https://github.com/rabits/ha-ef-ble | `491302bae299b4edbad1c0a4b3b2293f5f2a7cf7` | Apache-2.0 |
| foxthefox/ioBroker.ecoflow-mqtt | https://github.com/foxthefox/ioBroker.ecoflow-mqtt | `735bfc610d03628d057c8572de5272152304066f` | MIT, "Copyright (c) 2023-2026 foxthefox" |

The developer pages are cited by product and by bundle chunk id (the chunk names change with each release of the
site; the sample serial numbers in each page say which product it documents):

| Tag | Developer page | Chunk(s) | Sample serial |
|---|---|---|---|
| [D-GEN] | General: host, signature, `PUT/POST /iot-open/sign/device/quota` | 1194, 535 (two versions of the page) | `DCABZ***` |
| [D-STREAM] | STREAM | 2578 | `BK11…`, `BK41…`, `BK51…` |
| [D-D3MP] | DELTA 3 Max Plus | 2010 | `D3M1…` |
| [D-D3M] | DELTA 3 Max | 5986 | `D3N1…` |
| [D-DP3] | DELTA Pro 3 | 9099 (newer), 6736 | `MR51…` |
| [D-D2] | DELTA 2 | 5784, 7339 | `R331…` |
| [D-D2M] | DELTA 2 Max | 3578, 8861 | `R351…` |
| [D-R2P] | RIVER 2 Pro | 6751 | `R621…` |
| [D-DP] | DELTA Pro | 7681 (newer), 4590, 2977, 6626 | `DCABZ***` |
| [D-DPU] | DELTA Pro Ultra | 9590, 7292 | `Y711…` |
| [D-PS] | PowerStream | 4061, 795 | `HW51…` |
| [D-PO] | PowerOcean | 396, 9846 | `HJ31…` |
| [D-GL] | GLACIER | 4734, 5670 | `BX11…` |

Repository paths are cited as `[HA] path`, `[BLE] path`, `[IOB] path`, relative to the repository root.

**Observed or declared.** EcoFlow's pages are the vendor's own statement of the API; nothing in them says a given
request was run, so they count as *documented* (stronger than declared, but not observed by any source here).
`[HA]` and `[IOB]` declare their commands; neither records a per-command test on a device, except where noted
below. `[BLE]` sends the same protobuf messages over Bluetooth to devices its README lists as supported: that is
*observed over BLE*, which shows the message and field numbers are accepted by the device, not that the cloud broker
relays them. Each table row says which applies.

## 1. Scope and summary

Writes covered: AC output on/off, DC 12 V output on/off, USB output on/off, charge limit (maximum state of charge,
%), discharge limit (minimum state of charge, %). Nothing else (X-Boost, backup reserve, charging power, standby
times) is specified, except where a write must carry such a field (section 3.3, `acOutCfg`).

| Model (serial) | Developer API | App route (MQTT) |
|---|---|---|
| STREAM Ultra, Ultra X, Pro, AC Pro (BK11, ES11, BK61, BK12, BK31) | AC1, AC2 (section 3.1); limits: none | AC1, AC2, limits (protobuf, 5.1) |
| STREAM Max (BK41) | AC (one switch) | AC, limits |
| STREAM AC (BK51) | none | limits only |
| RIVER 3, 3 Plus (R65x, R63x) | unknown (no developer page) | AC, DC, limits (protobuf, 5.2) |
| DELTA 3 Max, Max Plus (D3N1, D3M1) | AC (Max Plus also AC2), DC, limits (3.2) | AC, DC, USB, limits (5.2); AC2 on Max Plus |
| DELTA 3, Plus, Classic, Air, Ultra, Ultra Plus (P231, P351, P32x, PR1x, D751, D511) | unknown (no developer page) | AC, limits; USB and DC per model (5.2) |
| DELTA Pro 3 (MR5x) | HV AC, LV AC, DC, limits (3.2) | same (5.3) |
| DELTA Pro Ultra X (P101), GLACIER Classic (RF45) | unknown | unknown |
| RAPID Pro X, RAPID Pro (P513, P521) | unknown | unknown over MQTT (section 7) |
| DELTA 2, 2 Max, 2 Plus (R33x, R35x, D36x) | AC, DC, USB, limits (3.3) | same JSON (4.2) |
| RIVER 2, 2 Max, 2 Pro (R60x, R61x, R62x) | AC, DC, limits (3.3; documented for 2 Pro only) | same JSON (4.2) |
| DELTA Pro, Max, Mini (DC…, DAEB, DBAB) | DELTA Pro: AC, DC, limits (3.4); Max and Mini: unknown | AC, DC, limits; USB on DELTA Max (4.3) |
| GLACIER (BX11) | no fitting writes | no fitting writes |
| DELTA Pro Ultra (Y711) | AC, DC, limits (3.5) | not read by the plugin |
| PowerStream (HW51) | limits (3.6) | limits (5.4) |
| PowerOcean, Fit (HJ31, HC31) | no writes documented ([D-PO] has "Get Quota" only) | unknown |
| Smart Home Panel 2, 3 (HD31, HR6x) | no fitting writes (circuits, not outputs) | unknown |

"No fitting writes": the model has no AC/DC/USB output or no state-of-charge limits in any source.

## 2. Developer API: transport

### 2.1 The set request [D-GEN]

- `PUT https://<host>/iot-open/sign/device/quota`, `Content-Type: application/json;charset=UTF-8`, the JSON body of
  section 3. The host is the one the plugin already uses for the account's region.
- Headers `accessKey`, `nonce` (a 6-digit number), `timestamp` (milliseconds since the epoch, UTC), `sign`.
- Response: `{"code":"0","message":"Success"}`; `code` other than `"0"` is a failure, with `message` the reason. The
  reply says the cloud accepted the request, not that the device applied it: the new state is read back from the
  quota (MQTT push or `POST /iot-open/sign/device/quota` with `params.quotas`, each page's "GetCmdRequest").

### 2.2 The signature over a JSON body [D-GEN]

1. Flatten the body: a nested object's keys become `parent.child` (`params.cmdSet`), an array's items `name[0]`,
   `name[1]`, an array of objects `list[0].id`. Each leaf becomes `key=value`.
2. Sort the pairs by key, in ASCII order, and join them with `&`.
3. Append `&accessKey=<key>&nonce=<nonce>&timestamp=<timestamp>` (in that order, not sorted with the rest).
4. `sign` = lowercase hex of HMAC-SHA256(string, key = secret key), both as UTF-8.

The page's own check vector (reproduced by the spec writer: the signature matches): access key
`Fp4SvIprYSDPXtYJidEtUAd1o`, secret `WIbFEKre0s6sLnh4ei7SPUeYnptHG6V`, nonce `345164`, timestamp
`1671171709428`, body `{"sn":"123456789","params":{"cmdSet":11,"id":24,"eps":0}}`:

```
params.cmdSet=11&params.eps=0&params.id=24&sn=123456789&accessKey=Fp4SvIprYSDPXtYJidEtUAd1o&nonce=345164&timestamp=1671171709428
→ 07c13b65e037faf3b153d51613638fa80003c4c38d2407379a7f52851af1473e
```

The spec writer's vector (fake keys), a DELTA 2 USB switch body as section 3.3 writes it:

```
accessKey TESTACCESSKEY0000   secretKey TESTSECRETKEY0000   nonce 123456   timestamp 1700000000000
body {"id":123456789,"version":"1.0","sn":"R331ZZZZ00000001","moduleType":1,"operateType":"dcOutCfg","params":{"enabled":1}}
string id=123456789&moduleType=1&operateType=dcOutCfg&params.enabled=1&sn=R331ZZZZ00000001&version=1.0&accessKey=TESTACCESSKEY0000&nonce=123456&timestamp=1700000000000
sign   4a7cd3628b090a2f2041ed14d7c9a9660f079a27900a6f19cc8a6e8f480497ec
```

**Unknown:** how a JSON boolean (`true`) and a value with a decimal point are written in the string to sign: no
page shows a signed example with either. The STREAM, DELTA 3 and DELTA Pro 3 bodies carry booleans (section 3.1,
3.2); the implementer must check the spelling against the live API before shipping those writes, and must not
assume one.

### 2.3 The same writes over the developer MQTT broker

Each developer page also documents MQTT: publish the body to `/open/<certificateAccount>/<sn>/set`; the device
answers on `/open/<certificateAccount>/<sn>/set_reply` [D-STREAM, D-D3MP, D-DP3, D-D2, D-DP]. The MQTT body adds
`"id"` (a number, echoed in the reply) and `"version":"1.0"`. Replies: JSON-model pages show
`{"code":"0","moduleType":…,"operateType":…,"data":{"ack":0},"id":…,"version":"1.0","time":…}` [D-D2, D-D2M,
D-R2P] (`ack` 0 in every example; its meaning is not stated); `cmdId`/`cmdFunc` pages show
`{"data":{"<cfgKey>":<value>,"configOk":true,"actionId":<n>},"id":…}` [D-DP3]; DELTA Pro shows
`{"code":"0","data":{"cmdSet":32,"id":…,"ack":0},"operateType":"TCP",…}` [D-DP]. `[HA] custom_components/ecoflow_cloud/api/public_api.py`
uses these two topics for its developer-route writes (declared). The plugin may use either transport; HTTP needs no
subscription and is what this spec recommends.

## 3. Developer API: the bodies per model

### 3.1 STREAM [D-STREAM] (documented)

Body: `{"sn":<sn>,"cmdId":17,"cmdFunc":254,"dirDest":1,"dirSrc":1,"dest":2,"needAck":true,"params":{…}}`.

| Write | `params` | Value | Read back | Models (as the page lists them) |
|---|---|---|---|---|
| AC1 | `cfgRelay2Onoff` | `true` on, `false` off | `relay2Onoff` | Ultra, Pro, AC Pro, Ultra X, Ultra (US) |
| AC2 | `cfgRelay3Onoff` | `true`/`false` | `relay3Onoff` | same |
| AC (single) | `cfgRelay2Onoff` | `true`/`false` | `relay2Onoff` | STREAM Max only |

- STREAM AC (BK51) has no AC switch ("Unsupported devices: STREAM Max, STREAM AC" for AC1/AC2; Max has its own row).
- In a system of several units, the AC switches are sent to the serial of the unit whose socket it is; every other
  write goes to the system's main unit, found with `GET /iot-open/sign/device/system/main/sn?sn=<any unit>`
  (answer `data.sn`).
- Charge and discharge limits are **not** settable on this route: the page lists `cmsMaxChgSoc` ("Charge limit") and
  `cmsMinDsgSoc` ("Discharge limit") as readings only, and its only SoC write is `cfgBackupReverseSoc`. `[HA]
  …/devices/public/stream_ac.py` declares the same three switches and no limit write.
- `[HA]` declares `cfgRelay2Onoff` as "AC1" and `cfgRelay3Onoff` as "AC2" for every STREAM over this route, with
  boolean values (declared). `[BLE] …/eflib/devices/stream_*.py` agrees per model: BK51 none; BK41 AC1 only; BK12,
  BK11, ES11, BK61, BK31 AC1 and AC2 (observed over BLE).

### 3.2 DELTA 3 Max, Max Plus, DELTA Pro 3 [D-D3M, D-D3MP, D-DP3] (documented)

Body as STREAM's (`cmdId` 17, `cmdFunc` 254, `dest` 2, `dirDest` 1, `dirSrc` 1, `needAck` true).

| Write | `params` | Value | Read back | Models |
|---|---|---|---|---|
| AC | `cfgAcOutOpen` | `true`/`false` | `flowInfoAcOut` (on when not 4) | D3N1, D3M1 |
| AC2 | `cfgAc2OutOpen` | `true`/`false` | `flowInfoAc2Out` (on when not 4) | D3M1 only |
| DC 12 V | `cfgDc12vOutOpen` | `true`/`false` | `flowInfo12v` (D3: on when not 4; DP3: 0 off, 2 on) | D3N1, D3M1, MR5x |
| High-voltage AC | `cfgHvAcOutOpen` | `true`/`false` | `flowInfoAcHvOut` (0 off, 2 on) | MR5x |
| Low-voltage AC | `cfgLvAcOutOpen` | `true`/`false` | `flowInfoAcLvOut` (0 off, 2 on) | MR5x |
| Charge limit | `cfgMaxChgSoc` | integer; D3: 50–100 | `cmsMaxChgSoc` | D3N1, D3M1, MR5x |
| Discharge limit | `cfgMinDsgSoc` | integer; D3: 0–30 | `cmsMinDsgSoc` | D3N1, D3M1, MR5x |

- The DELTA Pro 3 page states no range; `[HA] …/devices/internal/delta_pro_3.py` uses 50–100 and 0–30 (declared).
- No USB write is documented for these models on this route.
- The DELTA 3 Max Plus MQTT example spells `"dirSoc": 1` where the HTTP examples have `"dirSrc": 1`; take `dirSrc`.
- `[HA] …/devices/public/delta3_max_plus.py` and `…/public/delta_pro_3.py` declare the same keys.

### 3.3 DELTA 2 family and RIVER 2 family (`moduleType`/`operateType`) [D-D2, D-D2M, D-R2P] (documented)

Body: `{"id":<number>,"version":"1.0","sn":<sn>,"moduleType":<n>,"operateType":<name>,"params":{…}}`
(`moduleType` 1 PD, 2 BMS, 3 INV, 4 BMS_SLAVE, 5 MPPT).

| Write | DELTA 2 (R33x) | DELTA 2 Max (R35x) | RIVER 2 Pro (R62x) | `params` | Read back |
|---|---|---|---|---|---|
| AC | 5 `acOutCfg` | 3 `acOutCfg` | 5 `acOutCfg` | `enabled` 0/1, `xboost` 0/1, `out_voltage`, `out_freq` | `mppt.cfgAcEnabled` (D2, R2P); `inv.cfgAcEnabled` (D2M) |
| DC 12 V (car socket) | 5 `mpptCar` | 5 `mpptCar` | 5 `mpptCar` | `enabled` 0/1 | `mppt.carState` (D2, D2M); `pd.carState` (R2P) |
| USB ("DC (USB) switch") | 1 `dcOutCfg` | 1 `dcOutCfg` | not documented | `enabled` 0/1 | `pd.dcOutState` |
| Charge limit | 2 `upsConfig` | 2 `upsConfig` | 2 `upsConfig` | `maxChgSoc` integer | `bms_emsStatus.maxChargeSoc` |
| Discharge limit | 2 `dsgCfg` | 2 `dsgCfg` | 2 `dsgCfg` | `minDsgSoc` integer | `bms_emsStatus.minDsgSoc` |

- `acOutCfg` carries all four parameters in every example. `out_freq`: 1 = 50 Hz, 2 = 60 Hz [D-D2M, D-R2P]
  (the DELTA 2 page's MQTT example gives 1 too, its quota example 50). `out_voltage` is "read-only" [D-D2M]; the
  examples send 30, 150 or 4294967295. **Unknown** on this route: a value meaning "leave unchanged" for `xboost`
  and `out_freq`. The app route's convention (section 4.2) is not documented here; until checked, an AC write sends
  the device's current `xboost` and frequency (read from the quota) with the new `enabled`.
- The DELTA 2 Max MQTT example misspells `"enalbed"` once for `mpptCar`; the HTTP example and the other pages have
  `enabled`.
- `watthConfig` (`minChgSoc`, `minDsgSoc` in it) is marked "not in use" for limits [D-D2, D-R2P]; use
  `upsConfig`/`dsgCfg`.
- Ranges: none documented. `[HA] …/devices/internal/delta2.py`, `delta2_max.py`, `river2*.py` clamp to 50–100 and
  0–30 (declared).
- RIVER 2 (R60x) and RIVER 2 Max (R61x) have no developer page. `[HA] …/devices/public/river2.py` and
  `river2_max.py` reuse the app-route JSON of section 4.2 on the developer MQTT `set` topic (declared); treat those
  two as **declared only** on this route.
- DELTA 2 Plus (D36x): no developer page and no source: **unknown**.

### 3.4 DELTA Pro (`cmdSet` 32) [D-DP] (documented)

Body: `{"sn":<sn>,"params":{"cmdSet":32,"id":<n>,…}}` (the page's curl example, sent by PUT).

| Write | `id` | Other `params` | Read back |
|---|---|---|---|
| AC | 66 | `enabled` 0/1 and `xboost` 0/1 (newer page; the older page sends `enabled` only) | `inv.cfgAcEnabled`, `inv.cfgAcXboost` |
| DC 12 V ("car charger") | 81 | `enabled` 0/1 | `mppt.carState` |
| Charge limit | 49 | `maxChgSoc` | `ems.maxChargeSoc` |
| Discharge limit | 51 | `minDsgSoc` | `ems.minDsgSoc` |

- The page titles id 66 "Setting the X-Boost switch", but its read-back is the AC switch: both fields live in id 66.
- The MQTT form wraps the same `params` as `{"id":…,"version":"1.0","operateType":"TCP","params":{…}}`.
- No USB write is documented. DELTA Max and DELTA Mini have no developer page: **unknown** on this route.

### 3.5 DELTA Pro Ultra (`cmdCode`) [D-DPU] (documented)

Body: `{"sn":<sn>,"cmdCode":<code>,"params":{…}}`.

| Write | `cmdCode` | `params` | Read back |
|---|---|---|---|
| AC | `YJ751_PD_AC_DSG_SET` | `enable` 0/1, `xboost`, `outFreq` (50/60) | bit 2 (third from the right, counting from 0) of `hs_yj751_pd_appshow_addr.showFlag` |
| DC | `YJ751_PD_DC_SWITCH_SET` | `enable` 0/1 | bit 5 (sixth from the right) of `hs_yj751_pd_appshow_addr.showFlag` |
| Charge limit | `YJ751_PD_CHG_SOC_MAX_SET` | `maxChgSoc` | `hs_yj751_pd_app_set_info_addr.chgMaxSoc` |
| Discharge limit | `YJ751_PD_DSG_SOC_MIN_SET` | `minDsgSoc` | `hs_yj751_pd_app_set_info_addr.dsgMinSoc` |

MQTT reply: `{"data":{"result":0},"id":…}`. Ranges and the meaning of `xboost` values: not stated.

### 3.6 PowerStream (`cmdCode`) [D-PS] (documented)

| Write | `cmdCode` | `params` | Range | Read back |
|---|---|---|---|---|
| Charge limit | `WN511_SET_BAT_UPPER_PACK` | `upperLimit` | 70–100 | `20_1.upperLimit` |
| Discharge limit | `WN511_SET_BAT_LOWER_PACK` | `lowerLimit` | 1–30 | `20_1.lowerLimit` |

MQTT reply `{"data":{"ack":0},"id":…}`. The PowerStream has no switchable outputs.

## 4. App route: transport and JSON models

### 4.1 Topics

Publish to `/app/<userId>/<sn>/thing/property/set`; the device answers on
`/app/<userId>/<sn>/thing/property/set_reply`. `<userId>` is the one the plugin already uses for
`thing/property/get`. Sources: `[HA] custom_components/ecoflow_cloud/api/private_api.py`, `[IOB] main.js` and
`lib/ecoflow_utils.js` (both declared). The plugin must subscribe to `set_reply` to see acknowledgements; the new
state also arrives in the device's ordinary pushes.

### 4.2 JSON models: envelope, DELTA 2 and RIVER 2 families

Envelope `[HA] …/api/message.py` (declared): `{"from":"HomeAssistant","id":"<number as a string>","version":"1.0",
"moduleType":…,"operateType":…,"params":{…}}`. `from` names the client; the plugin uses its own name. `[HA]`'s ids
are 999 900 000 plus a random 10 000–99 999; any unique number will do as far as the sources show. Values are JSON
integers.

| Write | `moduleType`, `operateType` | `params` | Models | Source |
|---|---|---|---|---|
| AC | 5 `acOutCfg` | `enabled` 1/0, `out_voltage` -1, `out_freq` 255, `xboost` 255 | R33x, R60x, R61x, R62x | `[HA] …/internal/delta2.py`, `river2.py`, `river2_max.py`, `river2_pro.py` |
| AC | 3 `acOutCfg` | as above | R35x | `[HA] …/internal/delta2_max.py` |
| DC 12 V | 5 `mpptCar` | `enabled` 1/0 | R33x, R35x, R60x, R61x, R62x | same files |
| USB | 1 `dcOutCfg` | `enabled` 1/0 | R33x, R35x (RIVER 2 family: none) | `delta2.py`, `delta2_max.py` |
| Charge limit | 2 `upsConfig` | `maxChgSoc` 50–100 | all of the above | same files |
| Discharge limit | 2 `dsgCfg` | `minDsgSoc` 0–30 | all of the above | same files |

- In `[HA]`'s AC command, 255 (and -1 for the voltage) stands for "unchanged": the X-Boost switch is sent with
  `enabled` 255 and the AC switch with `xboost` 255 (declared; the developer pages do not document it).
- `[HA] delta2_max.py` adds `"moduleSn": <sn>` beside `moduleType` for its PD, BMS and INV writes, not for
  `mpptCar`. Whether the device needs it is not stated: send it for R35x as `[HA]` does.
- The bodies match the developer pages of section 3.3 key for key (documented there), which corroborates them.
- DELTA 2 Plus (D36x): no source declares its writes: **unknown**.

### 4.3 JSON models: DELTA Pro, Max, Mini (`operateType` "TCP")

`[HA] …/internal/delta_pro.py`, `delta_max.py`, `delta_mini.py` (declared), in the envelope of 4.2:

| Write | `params` | `moduleType` sent by `[HA]` | Models |
|---|---|---|---|
| AC | `{"id":66,"enabled":1/0}` | 0 | DC…, DAEB, DBAB |
| DC 12 V | `{"id":81,"enabled":1/0}` | 0 | DC…, DAEB, DBAB |
| USB | `{"id":34,"enabled":1/0}` | 0 | DAEB only |
| Charge limit | `{"id":49,"maxChgSoc":50–100}` | 0 (DAEB: 2) | DC…, DAEB, DBAB |
| Discharge limit | `{"id":51,"minDsgSoc":0–30}` | 0 (DAEB: 2) | DC…, DAEB, DBAB |

`operateType` is `"TCP"`. The developer page's DELTA Pro MQTT form (section 3.4) also adds `"cmdSet":32` inside
`params`; `[HA]`'s app-route bodies do not. **Unknown** whether the device needs `cmdSet` on this route; the
developer form is documented, so include it.

### 4.4 JSON replies

Neither `[HA]` nor `[IOB]` reads the JSON `set_reply` beyond logging it. Its shape on this route is **unknown**;
the developer pages' MQTT replies (section 2.3) are the likely model, not a verified one. The plugin should treat a
write as done when the device's pushes show the new value, and log the reply.

## 5. App route: protobuf models

### 5.1 The envelope

The message is the same framing the plugin's `EcoFlowProtobuf.swift` reads: a message whose field 1 (repeated) is
a header; the header's field 1 is `pdata`, the payload. The header fields a write sets, with each source's values:

| Field | No. | Type | `[HA]` RIVER 3, DELTA 3, DELTA Pro 3 | `[IOB]` RIVER 3, DELTA 3 family, DELTA Pro 3 | `[IOB]` STREAM | `[BLE]` packet |
|---|---|---|---|---|---|---|
| `pdata` | 1 | bytes | payload | payload | payload | payload |
| `src` | 2 | int32 | 32 | 32 | 32 | 0x20 = 32 |
| `dest` | 3 | int32 | 2 | 2 | 2 | 0x02 |
| `d_src` | 4 | int32 | 1 | 1 | 1 | 1 |
| `d_dest` | 5 | int32 | 1 | 1 | 1 | 1 |
| `cmd_func` | 8 | int32 | 254 | 254 | 254 | 0xFE |
| `cmd_id` | 9 | int32 | 17 | 17 | 17 | 0x11 |
| `data_len` | 10 | int32 | byte length of `pdata` | a fixed value per write (section 5.6) | byte length of `pdata` | (BLE framing) |
| `need_ack` | 11 | int32 | 1 | 1 | 1 | — |
| `seq` | 14 | int32 | random number | time in ms | time in ms | — |
| `product_id` | 15 | int32 | 1 | 1 | 56 | — |
| `version` | 16 | int32 | 19 | 19 | 3 | 0x13 = 19 (packet version) |
| `payload_ver` | 17 | int32 | 1 | 1 | 1 | — |
| `from` | 23 | string | absent | absent | `"Android"` | — |
| `device_sn` | 25 | string | the serial | absent | absent | — |

- `enc_type` (6) is not set by any source: writes go unencrypted. ("Encryption is set but not done" in `[IOB]`.)
  The XOR the plugin applies to pushes does not apply.
- **Unknown:** which of `product_id`, `version`, `from`, `device_sn` the device checks; the sources differ and all
  report working writes. The implementer should send the `[IOB]` STREAM values to STREAM units and the `[HA]`
  values to the others, as section 6 does, and not mix them.
- `seq`: an int32; `[IOB]` writes milliseconds since the epoch into it, which overflows int32 (protobuf.js keeps the
  low 32 bits). Use a positive number below 2^31.
- The `[BLE]` column is a Bluetooth packet with its own framing; only its addressing and command agree.

### 5.2 RIVER 3, RIVER 3 Plus, DELTA 3 family: `pdata` fields (cmd 254/17)

| Write | Field | No. | Wire | Value | Models | Sources |
|---|---|---|---|---|---|---|
| AC | `cfg_ac_out_open` | 76 | varint | 1 on, 0 off | R65x, R63x, all DELTA 3 | `[HA] …/proto/ef_river3.proto`, `ef_delta3.proto`; `[IOB] ef_river3_data.js`, `ef_delta3*_data.js`; `[BLE] proto/pr705.proto`, `pd335_sys.proto` (observed over BLE) |
| AC2 | `cfg_ac2_out_open` | 377 | varint | 1/0 | D3M1, D511 | `[BLE] eflib/devices/delta3_max_plus.py`, `delta3_ultra_plus.py` (observed over BLE) |
| DC 12 V | `cfg_dc12v_out_open` | 18 | varint | 1/0 | R65x, R63x, DELTA 3 family | `[HA]` river3 and delta3 (declared); `[IOB]` river3, delta3classic (declared); `[BLE]` river3, delta3_classic (observed over BLE) |
| USB | `cfg_usb_open` | 19 | varint | 1/0 | DELTA 3 family | `[HA] ef_delta3.proto` ("discovered via MQTT sniffing": observed over MQTT); `[BLE] delta3.py` (P231 and its Plus, Max, Ultra subclasses; observed over BLE); `[IOB] ef_delta3classic_data.js` (declared) |
| Charge limit | `cms_max_chg_soc` | 33 | varint | 50–100 | all | `[HA]` (range), `[IOB]`, `[BLE]` |
| Discharge limit | `cms_min_dsg_soc` | 34 | varint | 0–30 | all | same |

- RIVER 3 USB: field 19 is declared in `[BLE] proto/pr705.proto` but no device of any source writes it, and RIVER 3
  has no USB switch in the app as far as the sources show: **left out**.
- Which DELTA 3 variants have a 12 V output: `[BLE]` writes it on the Classic only; `[HA]` on every DELTA 3. Offer the
  switch only when the device reports a 12 V output (its status message's 12 V flow field), as `[BLE]` does.
- `[HA]` sends exactly one field per write; `[IOB]` sends the limit alone for RIVER 3 (no time field).

### 5.3 DELTA Pro 3: `pdata` fields (cmd 254/17)

From `[HA] …/proto/ef_dp3_iobroker.proto` (declared; its docstring says plain JSON is ignored by the device and only
this envelope works, which reads as observed) and `[BLE] proto/mr521.proto` (observed over BLE); they agree:

| Write | Field | No. | Value |
|---|---|---|---|
| High-voltage AC | `cfg_hv_ac_out_open` | 15 | 1/0 |
| Low-voltage AC | `cfg_lv_ac_out_open` | 16 | 1/0 |
| DC 12 V | `cfg_dc_12v_out_open` | 18 | 1/0 |
| Charge limit | `cms_max_chg_soc` | 33 | 50–100 |
| Discharge limit | `cms_min_dsg_soc` | 34 | 0–30 |

`[BLE]` also declares `cfg_usb_open` 19 for this model, unused by any device class: left out.

### 5.4 STREAM: `pdata` fields (cmd 254/17)

| Write | Field | No. | Value | Models |
|---|---|---|---|---|
| AC1 | `cfg_relay2_onoff` | 380 | 1/0 | BK41, BK12, BK11, ES11, BK61, BK31 |
| AC2 | `cfg_relay3_onoff` | 381 | 1/0 | BK12, BK11, ES11, BK61, BK31 |
| Charge limit | `cms_max_chg_soc` | 33 | integer % | every STREAM including BK51 |
| Discharge limit | `cms_min_dsg_soc` | 34 | integer % | every STREAM including BK51 |
| Time | `cfg_utc_time` | 6 | Unix seconds | sent with each write by `[IOB]` and `[BLE]` |

- Sources: `[BLE] proto/bk_series.proto` and `eflib/devices/stream_*.py` (observed over BLE, per model as above);
  `[IOB] lib/dict_data/ef_stream_ultra_data.js`, `ef_stream_ac_pro_data.js`, `ef_stream_ultra_x_data.js`,
  `ef_stream_ac_data.js` (declared; the AC data file declares no relays, matching BK51 having none). `[HA]`'s
  app-route STREAM has no writes.
- Both `[IOB]` and `[BLE]` (`stream_ac.py`, for every STREAM write) send `cfg_utc_time` (field 6, the current Unix
  time in seconds) with the written field; send it. With a limit write `[IOB]` also re-sends the other limit's
  current value (both 33 and 34); `[BLE]` sends only the one written. **Unknown** whether the other limit is needed:
  `[BLE]`'s single field is observed over BLE, so send only the written limit.
- Ranges: `[IOB] ef_stream_ultra_data.js` declares 50–100 for the charge limit and 0–30 for the discharge limit;
  `[BLE]` bounds each by the other's current value. Use 50–100 and 0–30, and keep the charge limit above the
  discharge limit.
- Multi-unit systems: limits are system-wide on the developer route (sent to the main unit); on the app route the
  sources send to the unit addressed. **Unknown** whether a limit sent to a secondary unit applies.

### 5.5 PowerStream (HW51): limits

`[HA] …/devices/internal/powerstream.py` and `[IOB] lib/dict_data/ef_pstream_data.js` (both declared, and they
agree): header `src` 32, `dest` 53, `d_src` 1, `d_dest` 1, `check_type` (7) 3, `need_ack` 1, `version` 19,
`payload_ver` 1, `from` `"ios"` ([IOB]) or the client's name ([HA]); `cmd_func` 20 and

| Write | `cmd_id` | `pdata` | Range |
|---|---|---|---|
| Discharge limit | 132 | field 1 (`lower_limit`), varint | 0–30 ([HA]); 1–30 per [D-PS] |
| Charge limit | 133 | field 1 (`upper_limit`), varint | 50–100 ([HA]); 70–100 per [D-PS] |

Use the documented ranges of [D-PS].

### 5.6 Replies

The device answers on `set_reply` with the same header framing, `cmd_func` 254 and `cmd_id` 18 [HA
`ef_river3.proto`: "Set Reply - cmdFunc=254, cmdId=18"]. Its `pdata` is a ConfigWriteAck: field 1 `action_id`
(varint), field 2 `config_ok` (varint, 1 = applied), then the written fields echoed with their own numbers
(`[HA] ef_river3.proto` `River3SetReply`; `[BLE] proto/pr705.proto`, `pd335_sys.proto` `ConfigWriteAck`). `[HA]`
decrypts a reply's `pdata` with the plugin's XOR when `enc_type` is 1 and `src` is not 32, and it accepts the
payload either raw or base64-encoded. The STREAM's and PowerStream's replies are not decoded by any source:
**unknown** beyond the header. A write is confirmed when `config_ok` is 1 or, failing a decodable reply, when the
pushes show the new value.

`[IOB]`'s fixed `data_len` values (3 for single RIVER 3 / DELTA 3 fields) equal the payload length for field 76
(3 bytes) but not for fields 18, 33 or 34 (2 bytes); `[HA]` uses the real length. Use the real length.

## 6. Test vectors (computed by the spec writer)

Encoded with a varint encoder written for this spec and checked by decoding with `protoc --decode` against a
schema of the fields above. Serials are fake.

**STREAM AC1 on**, `[IOB]` STREAM header, `cfg_utc_time` 1700000000, `seq` 1000:

```
pdata (9 bytes)  30 80e2cfaa06  e017 01
                 f6 utc=1700000000, f380=1
full             0a310a093080e2cfaa06e01701102018022001280140fe0148115009580170e8077838800103880101ba0107416e64726f6964
```

The full message is field 1 (length 0x31) holding: `pdata`, `src` 32, `dest` 2, `d_src` 1, `d_dest` 1,
`cmd_func` 254, `cmd_id` 17, `data_len` 9, `need_ack` 1, `seq` 1000, `product_id` 56, `version` 3, `payload_ver` 1,
`from` "Android".

**STREAM AC1 off** (same header):

```
pdata  3080e2cfaa06e01700
full   0a310a093080e2cfaa06e01700102018022001280140fe0148115009580170e8077838800103880101ba0107416e64726f6964
```

**STREAM AC2 on**: `pdata` `3080e2cfaa06e81701`, the full message as AC1 on with `e017` replaced by `e817`.

**RIVER 3 AC on**, `[HA]` header, `seq` 1000, `device_sn` "R651ZZZZ00000001":

```
pdata (3 bytes)  e00401                      (f76 = 1)
full             0a340a03e00401102018022001280140fe0148115003580170e8077801800113880101ca0110523635315a5a5a5a3030303030303031
```

(`product_id` 1 → `7801`, `version` 19 → `800113`, `payload_ver` 1 → `880101`, `device_sn` → `ca0110` + 16 bytes.)

Single-field payloads for the other writes:

| Write | `pdata` |
|---|---|
| DC 12 V on (f18) | `900101` |
| USB on (f19) | `980101` |
| Charge limit 80 (f33) | `880250` |
| Discharge limit 10 (f34) | `90020a` |
| AC2 on (f377) | `c81701` |
| DELTA Pro 3 HV AC on (f15) | `7801` |
| DELTA Pro 3 LV AC on (f16) | `800101` |
| Reply example: `action_id` 5, `config_ok` 1, AC echoed on | `08051001e00401` |

Developer API signature vectors: section 2.2.

## 7. Left out, and why

- RIVER 3 and the DELTA 3 variants other than Max and Max Plus on the developer API: EcoFlow publishes no page and
  no source writes them there. **Unknown.**
- DELTA Pro Ultra X (P101), GLACIER Classic (RF45): no source gives output or limit writes. **Unknown.**
- RAPID Pro (P521): `[BLE] eflib/devices/rapid_pro_320.py` switches its ports over BLE with `dev_apl_comm`
  ConfigWrite fields 176–180 (`cfg_typec1..4_port_enable`, `cfg_usb1_port_enable`), value 1 on and 2 off, and the
  same header as section 5.1's `[BLE]` column (observed over BLE). No source sends it over MQTT, and `[IOB]
  ef_rapidpro320_data.js` declares only fields 6, 7, 33, 34, 135 for it. Over MQTT: **unknown**; a port switch is a
  USB-C per port, not one USB switch. RAPID Pro X (P513): no source.
- GLACIER (BX11): its only battery write is `protectBat` (a protection level, not a %), no outputs [D-GL].
- PowerOcean, PowerOcean Fit, Smart Home Panel 2 and 3: no AC/DC/USB outputs; PowerOcean's page has no set command
  and the Smart Home Panels switch circuits, not outputs.
- DELTA 2 Plus (D36x): no source.
- The boolean spelling in a developer signature (section 2.2) and the "unchanged" values of `acOutCfg` on the
  developer route (section 3.3).

## 8. Addendum: the RIVER's light

**Answer.** The RIVER 3 Plus has an LED that its app sets to one of four modes; the sources call it only "LED" /
"LED mode" and describe no hardware. No source shows the plain RIVER 3 (R651, R653, R654, R655) using it. No source
gives it a developer API write: EcoFlow publishes no RIVER 3 page (section 7), and the developer pages read for
section 0 have no LED or lamp key.

### 8.1 The write and its read-back (app route, cmd 254/17, section 5.1's `[HA]` header)

| Direction | Message | Field | No. | Wire | Values |
|---|---|---|---|---|---|
| Write | ConfigWrite (`pdata` of 254/17) | `cfg_led_mode` | 89 | varint (uint32) | 0 Off, 1 Dim, 2 Bright, 3 SOS |
| Reply | ConfigWriteAck (254/18) | `cfg_led_mode` | 89 | varint | the mode echoed (section 5.6) |
| Read-back | DisplayPropertyUpload (254/21, the status message) | `led_mode` | 357 | varint (uint32) | the same four values |

Sources, each field:

- `[BLE] custom_components/ef_ble/eflib/devices/river3_plus.py`: `LedMode` OFF 0, DIM 1, BRIGHT 2, SOS 3; reads
  `led_mode` and writes `ConfigWrite(cfg_led_mode=…)` for R631, R634, R635. **Observed over BLE** on the RIVER 3 Plus.
  `[BLE] README.md` lists "Led Mode" for the River 3 family with "Only available on Plus variant", and
  `eflib/devices/river3.py` (R651/R653/R654/R655) has no LED control.
- `[BLE] proto/pr705.proto`: `cfg_led_mode = 89` in ConfigWrite and ConfigWriteAck, `led_mode = 357` in
  DisplayPropertyUpload (declared).
- `[HA] custom_components/ecoflow_cloud/devices/internal/river3.py`: a "LED Mode" select reading `led_mode` and
  sending `_create_river3_proto_command("cfg_led_mode", value, sn)` (the header of section 5.1, `data_len` the real
  length), options from `devices/const.py` `LED_MODE_OPTIONS` = Off 0, Dim 1, Bright 2, SOS 3. One class serves
  both `RIVER_3` and `RIVER_3_PLUS` (`devices/registry.py`), so `[HA]` offers it on both; `docs/devices/RIVER_3.md`
  and `RIVER_3_PLUS.md` list it. **Declared** (no test recorded; the generated docs are not a test).
- `[HA] …/devices/internal/proto/ef_river3.proto`: `led_mode = 357` in River3DisplayPropertyUpload ("cmdFunc=254,
  cmdId=21"), `cfg_led_mode = 89` in River3SetCommand and River3SetReply (declared).
- `[IOB] lib/dict_data/ef_river3_data.js`, `ef_river3plus_data.js`: `ledMode` as a read-only diagnostic text whose
  value map is only `0: 'OK?'`; `cfg_led_mode = 89` declared in their embedded protos; no write. `ledOutTime`
  (statistics object 26, `STATISTICS_OBJECT_LED_OUT_TIME`, also in `[BLE] pr705.proto` and `[HA] ef_river3.proto`) is
  a time counter, not a switch.

**Gating.** Offer it on R631/R634/R635 only, and only once the status message has carried field 357 (as section
5.2 does for 12 V). The RIVER 3 (R65x): **unknown** whether it has the LED; `[HA]`'s declaration is not evidence of
the hardware, and `[BLE]` says Plus only. The writes of section 5.2 were checked on a RIVER 3 Plus; this one was not:
it belongs behind `untestedWrites` until it is seen working on a device.

**No single "on".** The device takes a mode, not a boolean. No source maps on/off to a mode: Off is 0, and which of
Dim, Bright or SOS an "on" means is the implementer's choice (for example the last non-zero mode the device
reported). Values above 3: **unknown**, do not send.

### 8.2 Test vectors (computed by the spec writer, python3, checked with `protoc --decode_raw`)

Single-field `pdata` (tag 89 << 3 = 712 = varint `c8 05`):

| Mode | `pdata` |
|---|---|
| Off (0), "light off" | `c80500` |
| Dim (1) | `c80501` |
| Bright (2), "light on" in these vectors | `c80502` |
| SOS (3) | `c80503` |

Full message, `[HA]` header, `seq` 1000, `device_sn` "R631ZZZZ00000001" (fake), the same encoder reproducing
section 6's RIVER 3 AC vector byte for byte:

```
light on (Bright)  0a340a03c80502102018022001280140fe0148115003580170e8077801800113880101ca0110523633315a5a5a5a3030303030303031
light off          0a340a03c80500102018022001280140fe0148115003580170e8077801800113880101ca0110523633315a5a5a5a3030303030303031
```

Off is sent as an explicit `c80500` (the fields are `optional`, so a 0 is present on the wire, as `[HA]` and
`[BLE]` serialise it). Reply example: `action_id` 5, `config_ok` 1, Bright echoed: `08051001c80502`.

### 8.3 Other models in the README's table

- DELTA 3 family: `cfg_led_mode = 89` and `led_mode = 357` are **declared** in `[HA] …/proto/ef_delta3.proto` and
  `[IOB] ef_delta3_data.js`, `ef_delta3plus_data.js`, `ef_delta3classic_data.js`, `ef_delta3maxplus_data.js`, with no
  value meanings; no device class of any source reads or writes them, and `[BLE] proto/pd335_sys.proto` has neither.
  `[HA] ef_dp3_iobroker.proto` (DELTA Pro 3) has none. **Left out.**
- RIVER 2, 2 Max, 2 Pro; DELTA 2, 2 Max; DELTA Pro, Max, Mini; GLACIER (BX11) and GLACIER Classic: no LED, lamp or
  ambient-light key in `[HA]`, `[IOB]` or `[BLE]` for them (the GLACIER's `pd.ambientTmp` is a temperature).
- STREAM, PowerStream, PowerOcean, Smart Home Panels, RAPID: none found.
- `lcd_light` / `cfg_lcd_light` (field 14 in the RIVER 3 and DELTA 3 protos) is the screen's brightness, not a lamp.

## 9. Observed on the author's devices (2026-11-08)

Captured from the app's stream (`/app/device/property/<sn>` and `set_reply`) of the author's own STREAM Ultra and RIVER
3 Plus while each output was switched, from the EcoFlow app and from the plugin. These are observations, not sources: no
upstream code was read for them.

| Device | Output | Write (254/17 `pdata`) | Ack (254/18) | Read-back in the status message (254/21) |
|---|---|---|---|---|
| STREAM Ultra (BK11) | AC1 | field 380 | `config_ok` 1, 380 echoed | field 980: 1 on, 0 off |
| STREAM Ultra (BK11) | AC2 | field 381 | `config_ok` 1, 381 echoed | field 982: 1 on, 0 off |
| RIVER 3 Plus (R631) | DC 12 V | field 18 | `config_ok` 1, 18 echoed | field 33: 2 on, 0 off |
| RIVER 3 Plus (R631) | Light | field 89 (section 8) | `config_ok` 1, 89 echoed | field 357: 0, 1, 2, 3 as in 8.1, also for changes made in the app |

- The status followed each acknowledged write within about two seconds, as a push carrying the changed field only.
- The STREAM's field 281 moved (0, 1, 2) while a relay switched; its meaning is not known and it is not read.
- The RIVER's AC flag was not seen (its load could not be switched off). Its output power (field 368, negative) shows
  the AC on while it delivers power; at 0 W it says nothing about the switch.
- The RIVER 3 Plus's light was written by the plugin and turned off on the device, which the EcoFlow app showed: the
  write of section 8 works through EcoFlow's broker.

