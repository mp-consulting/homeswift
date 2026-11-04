# Tuya (Tuya Cloud OpenAPI) — functional specification

## 0. Provenance

| Item | Value |
|---|---|
| Source | https://github.com/0x5e/homebridge-tuya-platform |
| Commit | `ab74ea4eee3c9df0be2ecc04c0fc56d9c0b02207` (committed 2026-07-11) |
| npm package | `@0x5e/homebridge-tuya-platform`, version `1.7.0-beta.58` |
| Licence | MIT. Copyright notice in `LICENSE`: "Copyright (c) 2014-2021 Tuya Inc." (no other holder is named; `package.json` has no author field). |
| Public reference | Tuya Developer Platform docs (developer.tuya.com): "API request" / signing, "Standard Instruction Set" per category, "Message Service" (MQTT open-hub), IR control hub open service, smart lock password-free unlocking. |

This document was written by the spec writer; it contains no source code. Identifiers that are part of an
interface (JSON keys, Tuya category codes, DP codes, API paths, HTTP header names, HAP service and
characteristic names) are quoted because a drop-in replacement must use them. Everything else is described
in my own words.

Glossary used below:

- **DP** (data point): one Tuya device property, identified by a **DP code** (`switch_led`) and carrying a
  **status value** (boolean, number, string).
- **Specification** (schema): per DP, its `type` (`Boolean`, `Integer`, `Enum`, `String`, `Json`, `Raw`),
  `mode` (read/write) and `property` (for Integer `min`, `max`, `scale`, `step`, `unit`; for Enum `range`; for
  Json, e.g. colour, nested Integer properties `h`, `s`, `v`).
- **Scale**: Tuya integers are fixed-point; the real value is `raw / 10^scale`. Throughout this spec
  "multiple" means `10^scale` (with `scale` missing treated as 0 where noted).
- **clamp(x, lo, hi)**: min(hi, max(lo, x)).
- **remap(x, a, b, c, d)**: linear map of x from [a, b] onto [c, d]: `c + (x - a) * (d - c) / (b - a)`.

---

## 1. Configuration interface

The plugin is a dynamic platform; the platform name (Homebridge `pluginAlias`) is **`TuyaPlatform`**. The
schema marks it singular (one block per bridge), though nothing in the runtime enforces that.

Block shape: `{ "platform": "TuyaPlatform", "name": "...", "options": { ... } }`. All functional settings are
under **`options`**.

### 1.1 Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Must be `TuyaPlatform`. |
| `name` | string | `Tuya` | Display/log name of the platform. Not used for any identity. |
| `options` | object | — (required) | Everything below. If absent, the plugin logs "not configured" and does nothing. |

### 1.2 `options` — common keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `projectType` | **string** `"1"` or `"2"` | `"2"` in the UI schema | `"1"` = **Custom** project (Tuya IoT "Custom development"); `"2"` = **Smart Home** project (end-user app account linked to a cloud project). Any other value (including the numbers 1/2 if not strings — the comparison is strict to the strings) → error logged, plugin does nothing. |
| `accessId` | string | — (required, both types) | Cloud project Access ID; used as `client_id`. |
| `accessKey` | string | — (required, both types) | Cloud project Access Secret; HMAC key. **Secret.** |
| `endpoint` | string (URL) | Custom: required. Smart Home: optional, derived from `countryCode` (§2.1) | OpenAPI base URL, e.g. `https://openapi.tuyaeu.com`. Only the host part is used for requests (scheme is assumed HTTPS, any path is ignored). An empty string counts as unset for Smart Home. |
| `deviceOverrides` | array of objects | none | Per-device/per-product/global overrides (§1.4). |
| `debug` | boolean | `false` | Enables verbose logs (§8). |
| `debugLevel` | string | empty | Only meaningful with `debug`. A free string, documented as comma-separated tokens: `api` turns on HTTP API logs (and, per the README, MQTT logs), a device id turns on logs for that device. Blank = everything. The check is a plain substring test against the whole string (not a split), e.g. `"api"` matches inside any longer token. |

### 1.3 `options` — Smart Home only (`projectType` `"2"`)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `countryCode` | integer ≥ 1 | — (required) | Phone country code of the app account (e.g. 1, 33, 49, 86). Sent in the login and used to choose the default endpoint. |
| `username` | string | — (required) | Tuya Smart / Smart Life app account (e-mail or phone). |
| `password` | string | — (required) | App account password **or** its MD5 as 32 lowercase/uppercase hex characters (§2.3). **Secret.** |
| `appSchema` | string | `tuyaSmart` | `tuyaSmart` (Tuya Smart app) or `smartlife` (Smart Life app). Passed verbatim as `schema` at login. |
| `homeWhitelist` | array of integers | none (all homes) | If present, only homes whose numeric `home_id` is in the list are loaded; others are logged as excluded. An empty array therefore loads nothing. |

The Custom type's type declaration also lists `username`/`password`, but the Custom flow never reads them
(it always uses a fixed internal user, §2.4). The UI shows them only for Smart Home.

Validation (on start; any failure → errors logged, plugin inert):

- Required keys per type as in the tables (Custom: `endpoint`, `accessId`, `accessKey`; Smart Home:
  `accessId`, `accessKey`, `countryCode`, `username`, `password`, `appSchema`); `countryCode` integer ≥ 1;
  `endpoint` must look like a URL.
- `deviceOverrides[].id` must be unique across the array.
- Within each override, `schema[].code` must be unique.

### 1.4 `deviceOverrides[]`

Each element:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | — (required) | A **device id**, a device **uuid**, a **product id**, a **scene id**, or the literal `global`. |
| `category` | string | none | Replaces the device's Tuya category code before the accessory type is chosen (§5). The special value `hidden` hides the device or scene entirely (no accessory). |
| `unbridged` | boolean | `false` | Publish this device as a stand-alone HAP accessory instead of on the bridge (Homeswift: `context.publishExternal`). |
| `adaptiveLighting` | boolean | `false` | Attach HomeKit Adaptive Lighting to the light (only if it has both a brightness and a colour-temperature DP). |
| `schema` | array | none | DP overrides, below. |

Matching an override to a device: first an element whose `id` equals the device `id` or `uuid`; if none, one
whose `id` equals the device's `product_id`; if none, the `global` element. **Exactly one** element applies; they
are not merged. The same lookup applies to scenes (scene id).

`schema[]` elements (DP overrides):

| Key | Type | Meaning |
|---|---|---|
| `code` | string, required | The DP code **as the device reports it** (original code). |
| `newCode` | string | The DP code the plugin should see instead. The accessory logic asks for standard codes; when it asks for `newCode`, it gets the device's `code`. |
| `type` | string | Replacement DP type: `Boolean`, `Integer`, `Enum`, `String`, `Json`, `Raw`. (The UI default is the empty string, which counts as "no override".) |
| `property` | object | Replacement DP property: for Integer `min`, `max`, `scale`, `step` (and optionally `unit`); for Enum `range` (array of strings). Replaces the whole property object (no merge). |
| `onGet` | string | A one-line **JavaScript expression** converting the device value into the value the plugin sees. |
| `onSet` | string | A one-line JavaScript expression converting the plugin's value into the value sent to the device. If it yields `undefined`, that command is dropped (not sent). |
| `hidden` | boolean | Hide the DP: the plugin behaves as if the DP does not exist. |
| `oldCode` | string (legacy) | Older config shape. If present, it is interpreted as: `code` := `oldCode` and `newCode` := the element's `code`. Must still be accepted. |

Semantics, precisely:

1. **Lookup by requested code.** When accessory logic asks for code X, the override element that matches is the
   one whose `newCode` equals X, or, for elements without `newCode`, whose `code` equals X. An element with a
   `newCode` does not hide its original `code`: asking for the original still finds the raw DP (without
   conversions).
2. **Schema.** If an element matches X and the device has a specification for the element's `code`, the
   effective specification is: code X, the original `mode`, `type` = override `type` or original, `property` =
   override `property` or original. If the element is `hidden`, the lookup for X yields "absent", and — when the
   logic was trying a list of alternative codes — the whole alternative list yields "absent" (it does not go on
   to the next alternative). This override path does not require a status value to exist (unlike §5.1 rule 2).
3. **Status (read).** If an element matches X and the device has a status for the element's `code`, the
   effective status is code `newCode` (or `code`) with value = `onGet(value)` if `onGet` is set, else the raw
   value.
4. **Command (write).** Before sending, each command whose code matches an element (same rule as 1) is rewritten
   to the element's original `code` and, if `onSet` is set, its value becomes `onSet(value)`. Commands whose
   value is then undefined are dropped.
5. **Category** replacement happens once, at start-up, before IR remote discovery and accessory creation. Note:
   devices that appear later through push (`bindUser`, §3.5) do **not** get their category overridden or
   `unbridged` applied.
6. Overrides are not applied to the multi-channel enumeration of some accessories, which scans the raw
   specification list (Switch/Outlet, Dimmer, Scene switch, Wireless switch, Weather station; see §5): a hidden or
   renamed switch DP still produces its channel there.

**Expression evaluation (`onGet`/`onSet`).** The source evaluates these strings as JavaScript with two names in
scope: `value` (the value being converted) and `device` (the whole device record: `id`, `uuid`, `name`,
`online`, `product_id`, `category`, `status` — an array of `{code, value}` with **device-side** values —
`schema`, etc.). The result of the last expression statement is the converted value; a trailing `;` is common.
A Swift implementation cannot run JavaScript; to keep users' blocks working it needs an expression evaluator
covering at least what the project's own documentation shows:

- literals (numbers, strings in single or double quotes, `true`, `false`, `undefined`);
- arithmetic `+ - * /`, parentheses, comparisons `=== !== == != < <= > >=`, logical `&& || !`, ternary `? :`;
- `Math.round`, `Math.floor`, `Math.ceil`, `Math.min`, `Math.max`, `Math.abs`;
- `device.online` (boolean);
- `device.status.find(s => s.code === 'X').value` — the raw device-side value of another DP (an arrow-function
  lookup pattern; supporting this exact pattern, with any parameter name, is enough for the documented cases).

Documented examples a replacement must reproduce:

| Purpose | Override |
|---|---|
| Report off while offline | `onGet`: `(device.online && value)` |
| Enum ↔ Boolean | `type: Boolean`, `onGet`: `(value === 'open') ? true : false;`, `onSet`: `(value === true) ? 'open' : 'close';` |
| Rescale a thermostat whose raw unit is 0.2 °C | `code: temp_set`, `onGet`: `(value * 5);`, `onSet`: `(value / 5);`, `property`: min 50, max 350, scale 1, step 5 |
| Reverse a curtain | `percent_control` and `percent_state`, both with `onGet`/`onSet` `(100 - value)` |
| Skip a redundant on/off when moving a slider | `code: switch_led`, `onSet`: `(value === device.status.find(status => status.code === 'switch_led').value) ? undefined : value` |
| Fahrenheit device to Celsius | `code: temp_current`, `onGet`: `Math.round((value - 32) / 1.8);`, `onSet`: `Math.round(1.8 * value + 32);` |
| Rename a DP | `code: <old>`, `newCode: <new>` |
| Hide a DP | `code: floodlight_switch`, `hidden: true` |

An expression that fails to evaluate throws in the source (the read or write fails). Note that `===` with
`value` compares JS types strictly (`1 === '1'` is false).

### 1.5 Example blocks

```json
{
  "platform": "TuyaPlatform",
  "name": "Tuya",
  "options": {
    "projectType": "2",
    "accessId": "4h3dxjpwamt9gcrkqv8e",
    "accessKey": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
    "countryCode": 33,
    "username": "user@example.com",
    "password": "e4dac8847254e28266642c1bfe2ea3d2",
    "appSchema": "smartlife",
    "homeWhitelist": [12345678],
    "deviceOverrides": [
      { "id": "bf0123456789abcdefgh", "adaptiveLighting": true },
      { "id": "keyabc123", "category": "kg" },
      { "id": "bf9876543210zyxwvuts", "schema": [ { "code": "temp_set", "onGet": "(value * 5);", "onSet": "(value / 5);", "property": { "min": 50, "max": 350, "scale": 1, "step": 5 } } ] },
      { "id": "global", "unbridged": false }
    ]
  }
}
```

```json
{ "platform": "TuyaPlatform", "options": { "projectType": "1", "endpoint": "https://openapi.tuyaeu.com", "accessId": "…", "accessKey": "…" } }
```

---

## 2. Tuya OpenAPI (HTTP)

### 2.1 Endpoints (data centres)

Known base URLs: America `https://openapi.tuyaus.com`; America East `https://openapi-ueaz.tuyaus.com`; China
`https://openapi.tuyacn.com`; Europe `https://openapi.tuyaeu.com`; Europe West
`https://openapi-weaz.tuyaeu.com`; India `https://openapi.tuyain.com`.

Smart Home default endpoint from `countryCode` (when `endpoint` is not set). Codes not listed → America.

- **China**: 86.
- **India**: 91.
- **America**: 1, 51, 52, 54, 55, 56, 57, 58, 60, 62, 63, 64, 66, 81, 82, 84, 95, 239, 245, 246, 500, 502, 591,
  593, 594, 595, 597, 598, 670, 672, 674, 675, 677, 678, 682, 683, 686, 690, 852, 853, 886, 970, 1721, 1787,
  1809, 1829, 1849, 4779, 5999, 35818.
- **Europe**: 7, 20, 27, 30, 31, 32, 33, 34, 36, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 61, 65, 90, 92, 93, 94,
  212, 213, 216, 218, 220–238, 240–244, 248, 250–258, 260–269, 291, 297, 298, 299, 350–359, 370–382, 385, 386,
  387, 389, 420, 421, 423, 501, 503–509, 590, 592, 596, 673, 676, 679, 680, 681, 685, 687, 688, 689, 691, 692,
  855, 856, 880, 960, 961, 962, 964, 965, 966, 967, 968, 971–977, 992–996, 998, 1242, 1246, 1264, 1268, 1284,
  1340, 1345, 1441, 1473, 1649, 1664, 1670, 1671, 1684, 1758, 1767, 1784, 1868, 1869, 1876.
  (A range "a–b" includes every integer from a to b.)

After a successful Smart Home login the response's `platform_url` (if non-empty) **replaces** the endpoint for
all later requests.

### 2.2 Request format and signing

Every request is HTTPS to the endpoint host with these headers:

| Header | Value |
|---|---|
| `t` | Current time in **milliseconds** since the epoch, decimal string. |
| `client_id` | `accessId`. |
| `nonce` | A fresh random UUID v4 string per request (lowercase, with hyphens). |
| `Signature-Headers` | The literal `client_id`. |
| `sign` | The signature, below (uppercase hex). |
| `sign_method` | `HMAC-SHA256`. |
| `access_token` | The current access token, or empty string before login. Sent on **every** request, including token requests. |
| `lang` | `en`. |
| `dev_lang` | `javascript` (a replacement may send its own). |
| `dev_channel` | `homebridge` (likewise). |
| `devVersion` | The plugin version (likewise). |

Bodies are JSON (`POST`), serialized compactly (no spaces) with keys in the order listed in this spec; the
**exact same bytes** are hashed and sent. No `Content-Type` header is set by the source; sending
`application/json` is harmless.

String to sign (lines joined by a single `\n`):

1. HTTP method in uppercase (`GET`, `POST`, `DELETE`).
2. Lowercase hex SHA-256 of the body bytes; for no body, the SHA-256 of the empty string
   (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
3. The signed-headers block, which is `client_id:<accessId>` followed by its own `\n` (so, after joining, there
   is an empty line between this and the URL).
4. The URL: the path, plus — if there are query parameters — `?` and the parameters **sorted by key**, as
   `key=value` joined with `&`, values **not** URL-encoded, parameters whose value is null/undefined omitted.

Signature: HMAC-SHA256 with key = `accessKey` (UTF-8) over the concatenation
`accessId + accessToken + t + nonce + stringToSign`, as **uppercase** hex. `accessToken` is the empty string
(i) before login and (ii) for any path starting with `/v1.0/token` (token grant and refresh), even when a token
is held.

The query string actually sent is the parameters in their given order, `application/x-www-form-urlencoded`
encoded (so `,` becomes `%2C`, space `+`). The signature is over the unencoded, sorted form; Tuya accepts this.

Responses: JSON `{ "success": true, "result": …, "t": <ms>, "tid": "…" }` or
`{ "success": false, "code": <int>, "msg": "…", "t": …, "tid": "…" }`.

Transport behaviour: on a network error the request is retried up to 10 times with exponential back-off
(starting at 100 ms, factor 2, up to 100 ms random jitter). A non-200 HTTP status is logged as a warning (the
source then never completes that request — a bug; a replacement should fail it).

Error codes the plugin explains in the log (paraphrased):

| Code | Meaning to tell the user |
|---|---|
| 1004, 1114 | Wrong endpoint, Access ID or Access Secret. |
| 1106 | Wrong country code, username, password or app; or the app account is not linked to the cloud project. |
| 2401 | Wrong username or password. |
| 2406 | Wrong data centre for the app account, or account not linked to the project. |
| 1010 | Token invalid/expired; typically the same account is used by another Homebridge/Home Assistant instance at the same time (unsupported). |
| 28841002 | The cloud API subscription has expired; renew it on the Tuya IoT Platform. |
| 28841101, 28841105 | API not subscribed: authorise "Authorization Token Management", "Device Status Notification", "IoT Core" and, for Custom projects, "Industry Project Client Service". |

### 2.3 Token: Smart Home project (`projectType` "2")

`POST /v1.0/iot-01/associated-users/actions/authorized-login`, body keys in order:
`country_code` (integer), `username`, `password`, `schema` (= `appSchema`).

- `password` is the **lowercase hex MD5** of the configured password, unless the configured password already
  "is" an MD5, in which case it is sent as configured. The source's test: decoding the string as hex yields
  exactly 16 bytes. In practice: a string that is 32 hex digits (either case). (The source's hex decoder stops at
  the first non-hex pair, so a string starting with 32 hex digits followed by a single non-hex character also
  qualifies; this oddity need not be reproduced.)
- Result: `access_token`, `refresh_token`, `uid`, `expire_time` (seconds of validity), `platform_url`.
  Expiry instant = now + `expire_time` seconds. `platform_url`, if present, becomes the endpoint.
- The login is signed without an access token (none held yet; the token is cleared before logging in).

### 2.4 Token: Custom project (`projectType` "1")

1. `GET /v1.0/token?grant_type=1` → `access_token`, `refresh_token`, `uid`, `expire_time` (seconds).
2. `GET /v1.2/iot-02/users/homebridge` (look up the fixed user name `homebridge`). If the result has no
   non-empty `user_name`, create it: `POST /v1.0/iot-02/users` with body
   `{"username":"homebridge","password":<sha256hex("homebridge")>,"country_code":1}`. The user's id is the
   `user_id` of the lookup or creation result.
   SHA-256 hex of `homebridge` = `eb54078a2ac3e88954aa509df41065698b9f18606ae744920390556247074cda`.
3. `GET /v1.0/iot-02/assets/-1/sub-assets?page_no=0&page_size=100` → `result.list[]` of `{asset_id, asset_name}`
   (top-level assets; a single page of up to 100, no further paging). Empty → warning, stop.
4. `POST /v1.0/iot-03/users/<user_id>/actions/batch-assets-authorized` with body
   `{"asset_ids":"<id1>,<id2>,…","authorized_children":true}`.
5. `POST /v1.0/iot-03/users/login` with body `{"username":"homebridge","password":<sha256hex("homebridge")>}` →
   `access_token`, `refresh_token`, `uid`, `expire` (**seconds**; note the field name differs from the others).
   From here on requests carry this user's token. Login failure codes are explained as in §2.2.

Any failing step logs `code`/`msg` and the plugin stops (no accessories, cached ones kept untouched).

### 2.5 Token refresh

Before every request whose path does not start with `/v1.0/token`, if a token is held and it expires within
60 seconds: `GET /v1.0/token/<refresh_token>` (signed with an empty access token). Result as for the grant
(`access_token`, `refresh_token`, `uid`, `expire_time`). On failure the error is logged and the request proceeds
with the old token. There is no periodic refresh; it happens lazily. The refresh token appears in the URL path:
it must be masked in logs.

### 2.6 Endpoints used

| Purpose | Method and path | Notes |
|---|---|---|
| Homes of the user (Smart Home) | `GET /v1.0/users/<uid>/homes` | `result[]`: `{home_id (number), name, …}` |
| Devices of a home (Smart Home) | `GET /v1.0/homes/<home_id>/devices` | `result[]`: device records |
| Scenes of a home (Smart Home) | `GET /v1.1/homes/<home_id>/scenes` | `result[]`: `{scene_id, name, enabled (bool), status ("1" = valid), …}` |
| Run a scene | `POST /v1.0/homes/<home_id>/scenes/<scene_id>/trigger` | no body |
| Device ids of an asset (Custom) | `GET /v1.0/iot-02/assets/<asset_id>/devices?page_size=50[&last_row_key=…]` | `result.list[].device_id`, `result.has_next`, `result.last_row_key`; loop while `has_next` |
| Device records by ids (Custom) | `GET /v1.0/devices?device_ids=<id,id,…>` | `result.devices[]`; the source sends all ids in one request (Tuya documents a limit of 20 ids per call — see Gaps) |
| One device record | `GET /v1.0/devices/<device_id>` | `result`: device record |
| Specification | `GET /v1.0/devices/<device_id>/specifications` | `result.category`, `result.functions[]`, `result.status[]`, each `{code, type, values}`, `values` a JSON **string** |
| Send commands | `POST /v1.0/devices/<device_id>/commands` | body `{"commands":[{"code":…,"value":…},…]}`; result `true` |
| MQTT access config | `POST /v1.0/iot-03/open-hub/access-config` | §3 |
| Camera stream URL | `POST /v1.0/devices/<device_id>/stream/actions/allocate` | body `{"type":"rtsp"}` → `result.url` |
| Lock: temporary ticket | `POST /v1.0/smart-lock/devices/<device_id>/password-ticket` | no body → `result.ticket_id` |
| Lock: open/close without password | `POST /v1.0/smart-lock/devices/<device_id>/password-free/door-operate` | body `{"device_id":…,"ticket_id":…,"open":true/false}` |
| IR remotes of a hub | `GET /v2.0/infrareds/<hub_id>/remotes` | `result[]`: `{category_id, remote_id, …}` |
| IR remote keys | `GET /v2.0/infrareds/<hub_id>/remotes/<remote_id>/keys` | `result`: `{category_id, brand_id, remote_index, single_air, duplicate_power, key_list[{key, key_id, key_name, standard_key}], key_range[{mode, mode_name, temp_list[{temp, temp_name, fan_list[{fan, fan_name}]}]}]}` |
| IR AC state | `GET /v2.0/infrareds/<hub_id>/remotes/<remote_id>/ac/status` | `result`: object such as `{power, mode, temp, wind}` (values may be numbers or numeric strings) |
| IR DIY learned codes | `GET /v2.0/infrareds/<hub_id>/remotes/<remote_id>/learning-codes` | `result[]`: `{id, key, code, …}` |
| IR key press | `POST /v2.0/infrareds/<hub_id>/remotes/<remote_id>/raw/command` | body `{"category_id":…,"remote_index":…,"key":…,"key_id":…}` |
| IR DIY key press | `POST /v2.0/infrareds/<hub_id>/remotes/<remote_id>/learning-codes` | body `{"code":…}` |
| IR AC command | `POST /v2.0/infrareds/<hub_id>/air-conditioners/<remote_id>/scenes/command` | body `{"power":1,"mode":m,"temp":t,"wind":w}` when power is 1, else `{"power":0}` |

### 2.7 Building the device list

Device record fields used: `id`, `uuid`, `name`, `online`, `product_id`, `product_name`, `category`, `status[]`
(`{code, value}`), `owner_id` (home id or asset id), `sub`, `ip`, `lat`, `lon`, `time_zone`, `local_key`,
`create_time`, `active_time`, `update_time`, `icon`. Status entries are kept sorted by code.

Specification merge, per device: take `result.status` entries then `result.functions` entries; the first
occurrence of a code wins (so `type`/`values` come from `status` when a code is in both). `mode` is `rw` if the
code is in both lists, `ro` if only in `status`, `wo` if only in `functions`. `property` is `values` parsed as
JSON; a code whose `values` does not parse is dropped (this is normal for IR remotes). The result is sorted by
code. If the specification request fails, the device gets an empty specification (warning logged) and will
usually fall back to an unsupported accessory.

Order at start-up:

- Smart Home: login → start MQTT (§3) → homes (filtered by `homeWhitelist`; owner ids = home ids as strings)
  → devices of each home → specification of each device → scenes of each home (added as pseudo-devices, §5.13).
- Custom: token, user, assets, authorisation, user login (§2.4) → start MQTT → for each asset, its device ids
  (paged) → device records → specification of each device (owner ids = the asset ids).

Then: apply category overrides and `unbridged` (§1.4), then **IR remote discovery**: for each device whose
category is `wnykq`, `hwktwkq` or `wsdykq` (IR control hubs), list its remotes; for each remote whose
`remote_id` is also a device in the list: mark that device's parent = the hub, clear its specification, fetch
its keys (store as the device's remote keys); if the device's category is `infrared_ac`, fetch the AC state and
**replace** the device's status with one entry per key of the returned object (`power`, `mode`, `temp`,
`wind`, …); otherwise if the remote's `category_id` is 999 (DIY), fetch learned codes and attach to each key the
`code` of the learned entry whose `id` equals the key's `key_id` and whose `key` equals the key's `key`. Any
failing step is logged and that remote is left as is.

The source writes the final list (devices with specification, status and remote keys) to
`TuyaDeviceList.<uid>.json` in the persist directory for troubleshooting; it contains `local_key`, `uid`,
`ip`, `lat`, `lon` — sensitive. (A replacement may keep the equivalent through the runtime's file helper, or
expose it through a diagnostic tool, with those fields masked.)

---

## 3. Push (Tuya open-hub MQTT)

### 3.1 Obtaining the configuration

`POST /v1.0/iot-03/open-hub/access-config` with body keys in order:
`uid` (the token's `uid`), `link_id` (a random UUID v4 generated once per process/plugin instance), `link_type`
`"mqtt"`, `topics` `"device"`, `msg_encrypted_version` — **`"1.0"` for Smart Home** and **`"2.0"` for Custom**.

Result: `url` (e.g. `ssl://m1.tuyaeu.com:8883`), `client_id`, `username`, `password`, `expire_time`
(seconds of validity, typically 7200), `source_topic` (`{ "device": "cloud/token/in/…" }`), `sink_topic`
(`{ "device": "cloud/token/out/…" }`, unused). On failure the plugin logs a warning and **does not retry**
(push stays off until the next scheduled reconnect, which then also never happens — see §6).

### 3.2 Connection

Connect to `url` (MQTT over TLS) with the given client id, username and password (MQTT 3.1.1, default
keep-alive, clean session), subscribe to `source_topic.device`. The MQTT library reconnects by itself after
drops with the same credentials. A timer fires after `expire_time − 60` seconds: the connection is closed and the
whole procedure (new access-config, new connection) runs again. MQTT is started right after login, **before**
the device list is fetched. The `password` is also the decryption key source: **secret**.

### 3.3 Message envelope and decryption

Each MQTT payload is JSON with at least `protocol` (integer), `data` (base64 string), `t` (integer timestamp)
(Tuya also sends `pv` and `sign`, not checked). The key is the 16 characters at offsets 8 through 23
(0-based, end exclusive 24) of the MQTT `password`, used as their UTF-8 bytes (AES-128).

- **Version 1.0 (Smart Home)**: `data` is base64 of AES-128-**ECB** ciphertext with PKCS#7 padding. Decrypt,
  strip padding, UTF-8 decode → JSON text.
- **Version 2.0 (Custom)**: `data` is base64 of: 4-byte big-endian unsigned IV length `n`, then `n` IV bytes
  (Tuya uses 12), then ciphertext, then a 16-byte GCM tag. AES-128-**GCM** with that IV; additional
  authenticated data = the envelope's `t` written as a **6-byte big-endian** unsigned integer. The source
  decrypts without verifying the tag (it never finalises), so it also tolerates an AAD mismatch. A replacement
  should verify the tag, and if verification fails it may fall back to accepting unauthenticated plaintext only
  if that matches observed Tuya behaviour (see Gaps).

A message that fails to decrypt is logged (as a warning with the raw payload in the source — that payload is
ciphertext, but do not log it at warning level in a replacement) and dropped.

Decrypted message JSON by protocol:

- **4 — device status**: `{ "dataId": "…", "devId": "<device id>", "productKey": "<product id>", "status": [ {
  "code": "<dp code>", "value": <value>, "t": <ms or s>, "<dp number>": <value> }, … ] }`.
- **20 — device lifecycle/info**: `{ "bizCode": "<event>", "bizData": { … }, "devId": "<device id>", … }` with
  events `online`, `offline`, `nameUpdate` (`bizData.name`), `bindUser` (`bizData.ownerId`), `delete`
  (`bizData.ownerId`), `event_notify`, `p2pSignal`.
- Anything else: logged as unhandled.

### 3.4 Status messages (protocol 4)

1. **Out-of-order protection.** The plugin keeps the protocol-4 messages it has applied during the last 30
   seconds (timestamps above 10^12 are treated as milliseconds, otherwise seconds). When a message arrives whose
   `t` is older than the most recently applied message's `t`, then for each of its status items the plugin
   looks, among the kept messages for the same `devId` (newest first), for the latest item with the same code;
   if one exists with a different value, the incoming item's value (and `t`) are replaced by that newer value.
   Such an out-of-order message is still dispatched but not added to the kept list. In-order messages are added;
   kept messages older than 30 s (relative to now) are discarded from the front. Net effect: a late, stale
   message cannot roll a DP back to an older value.
2. Find the device by `devId` (unknown → ignored). For each status entry the device already has, if the message
   carries the same code, overwrite the cached value. Codes the device did not have are **not** added to the
   cache (but are passed to event handlers).
3. Notify the accessory: all characteristics are re-read from the cache and pushed to HomeKit (§6.4), and
   event-style handlers (buttons, doorbells, motion pulses) receive the message's raw status list.

### 3.5 Lifecycle messages (protocol 20)

| `bizCode` | Effect |
|---|---|
| `online` / `offline` | Set the device's online flag; re-read all characteristics (StatusActive, etc.). |
| `nameUpdate` | Set the device's cached name to `bizData.name`; re-read characteristics. (The HomeKit accessory and service names are **not** changed.) |
| `bindUser` | If `bizData.ownerId` is not one of the loaded owner ids (home ids / asset ids, as strings) → warn and ignore. Otherwise wait 10 seconds, fetch the device record and specification, replace/add it in the device list, **restart the MQTT connection** (§3.2) so the new device's messages arrive, and add its accessory (§4). |
| `delete` | If `bizData.ownerId` is not a loaded owner id → warn and ignore. Otherwise drop the device and unregister its accessory. |
| `event_notify`, `p2pSignal` | Ignored. |
| other | Logged as unhandled. |

---

## 4. Accessories and identity

- **One HomeKit accessory per Tuya device** (and per Smart Home scene). Multi-channel devices are one accessory
  with several services distinguished by **subtype** (the DP code in most cases; see each category).
- **Identity seed**: the device `id` string (for scenes the `scene_id`; for IR remotes the remote's device id).
  Homebridge's accessory UUID is HAP-NodeJS `uuid.generate(id)`: SHA-1 of the UTF-8 id, the first 32 hex digits
  laid out 8-4-4-4-12, uppercase. Example: id `bf0123456789abcdefgh` → SHA-1
  `b5e06b64b2145ad571bee42176f85847f53159a6` → `B5E06B64-B214-5AD5-71BE-E42176F85847`. A Homeswift port keys
  the accessory on the same id (with the plugin's platform-name prefix convention, if the runtime maps that to
  the same identity) and keeps service subtypes exactly as listed below so iids stay stable.
- Accessory display name at creation = device `name` (scenes: scene `name`). Renames in the Tuya app do not
  rename it.
- `category` `hidden` (from an override) → no accessory, logged as hidden.
- `unbridged` → published as an external accessory; such a device is always created fresh (a cached bridged
  copy, if any, is removed as unused).
- After all devices are added, cached accessories that no Tuya device claimed are removed. Devices that fail
  their category's requirements, or whose category is not supported, still get an accessory with only the
  information service (plus a battery service and StatusActive, below) and a warning "unsupported device".
- **Accessory Information**: Manufacturer `Tuya Inc.`; Model = `product_id`; Name and ConfiguredName = device
  name; SerialNumber = device `uuid` (scenes: scene id).
- **Battery** (any category): if one of `battery_percentage`, `residual_electricity`, `wireless_electricity`,
  `va_battery`, `battery` (first present, readable with a status) exists, add a Battery service (no subtype):
  BatteryLevel = clamp(value / multiple, 0, 100); StatusLowBattery = LOW if `battery_state` exists and equals
  `low`, otherwise (no `battery_state`) LOW when the percentage value ≤ 20 (raw value, not scaled); ChargingState
  = CHARGING when `charge_state` is true, NOT_CHARGING otherwise (only if `charge_state` exists).
- **StatusActive**: added to **every** service of the accessory (the information service included), value =
  device online flag.
- Names: services added "with a name" below get that string as their initial Name; services that call the
  name helper also get Name set and ConfiguredName set once (only if the characteristic was not already present).

### 4.1 Accessory selection

The (possibly overridden) category selects the handler:

| Category codes | Handler (§5) |
|---|---|
| `dj`, `dsd`, `xdd`, `fwd`, `dc`, `dd`, `gyd`, `tyndj`, `sxd` | Light |
| `tgq`, `tgkg` | Dimmer |
| `dlq`, `kg`, `tdq`, `qjdcz`, `szjqr` | Switch |
| `cz`, `pc`, `wkcz` | Outlet |
| `wxkg` | Wireless switch |
| `cjkg` | Scene switch |
| `bzyd` | White-noise light |
| `kt`, `ktkzq` | Air conditioner |
| `qtwk` | Sauna |
| `qn` | Heater |
| `kj` | Air purifier |
| `xxj` | Diffuser |
| `ckmkzq` | Garage door |
| `cl`, `clkg` | Window covering |
| `mc` | Window (behaves exactly like window covering, §5.15) |
| `cwwsq` | Pet feeder |
| `msp` | Cat toilet |
| `wk`, `wkf` | Thermostat |
| `ggq`, `sfkzq` | Valve |
| `jsq` | Humidifier |
| `cs` | Dehumidifier |
| `fs`, `fsd`, `fskg` | Fan |
| `yyj` | Extraction hood |
| `sp` | Camera |
| `ywbj` | Smoke sensor |
| `mcs` | Contact sensor |
| `zd` | Vibration sensor |
| `rqbj`, `jwbj`, `sj` | Leak sensor |
| `cobj`, `cocgq` | CO sensor |
| `co2bj`, `co2cgq` | CO₂ sensor |
| `wsdcg` | Temperature/humidity sensor |
| `ldcg` | Light sensor |
| `pir` | Motion sensor |
| `pm25`, `pm2.5`, `pm25cgq`, `hjjcy` | Air-quality sensor |
| `hps` | Presence sensor |
| `ms`, `jtmspro` | Lock |
| `mal` | Security system |
| `wxml` | Wireless doorbell |
| `qxj` | Weather station |
| `scene` | Scene (Smart Home scenes only) |
| `wnykq`, `hwktwkq`, `wsdykq` (any category in this set) | IR control hub — overrides the table above |
| any device with IR remote keys (§2.7) | IR AC if the keys' `category_id` is 5, else IR generic — overrides everything above |

Each handler declares **required DPs** (lists of alternatives; each list needs one present per §5.1). If any is
missing, the device falls back to the bare accessory, with warnings naming the category, the missing list and the
existing specification, advising the user to switch the product to "DP Instruction" mode and add
`deviceOverrides`.

---

## 5. Device model, per category

### 5.1 Common rules

1. **Finding a DP.** Accessory logic asks for a list of alternative codes and uses the first one found (with
   overrides per §1.4).
2. A DP whose mode is `rw` or `ro` only counts as present if the device also has a **status** entry for it.
   `wo` DPs count without a status.
3. Writes go through §6.1 (cache update, optional coalescing). "Debounced" below means coalesced (§6.1);
   "immediate" means sent at once.
4. Reads marked **(online check)** fail with a HAP communication error (-70402) when the device is offline;
   all other reads return cached values.
5. A characteristic whose DP has no status value at read time is undefined behaviour in the source (it throws);
   a replacement should return the characteristic's previous/default value.

HAP constants used (values): Active INACTIVE 0 / ACTIVE 1; Current/Target HeaterCoolerState and HeatingCooling
per HAP; LockCurrentState UNSECURED 0 / SECURED 1; ContactSensorState DETECTED 0 / NOT_DETECTED 1;
ProgrammableSwitchEvent SINGLE 0 / DOUBLE 1 / LONG 2; SecuritySystem STAY 0 / AWAY 1 / NIGHT 2 /
DISARMED(DISARM) 3 / TRIGGERED 4; TargetDoorState OPEN 0 / CLOSED 1.

### 5.2 Shared building blocks

**On (switch-like).** On = boolean status **(online check)**; set → `{code, value: bool}` debounced. When this
block creates its own service, it is a **Switch** with name = DP code and subtype = DP code.

**Active.** Active = ACTIVE iff status true **(online check)**; set → `true`/`false` debounced.

**Current temperature.** Value = clamp(raw / multiple, minValue, maxValue) with props minValue =
max(−270, min/multiple), maxValue = min(100, max/multiple), minStep = max(0.1, step/multiple). When it creates
its own service: TemperatureSensor, no subtype.

**Current relative humidity.** clamp(raw / multiple, 0, 100); own service: HumiditySensor, no subtype.

**Lock physical controls.** Status true → CONTROL_LOCK_ENABLED (1), else DISABLED (0); set → bool, debounced.

**Swing mode.** Status true → SWING_ENABLED (1); set → bool, debounced.

**Temperature display units.** Status (string) lowercased `c` → CELSIUS, else FAHRENHEIT. Set: `c` or `f`, in
the same letter case as the current status value (uppercase if the current value is uppercase); immediate.

**Rotation speed (integer DP).** Props min = min/multiple, max = max/multiple, minStep = max(1, step/multiple).
Get clamp(raw/multiple, min, max). Set → value × multiple (no rounding, no clamp), debounced.

**Rotation speed (enum DP, "levels").** Levels = the DP's enum range in order, minus any ignored values (the AC
ignores `auto`). Props min 0, max = number of levels, step 1, unit "speed". Get = (index of status in levels) + 1,
clamped (an unknown value reads 0). Set: index = round(value − 1); out of range (including 0) → nothing sent;
else send that level's string, debounced. The characteristic's value is updated to the computed level before
the props are applied.

**Rotation speed (on-only).** Props 0…100 step 100; get 100 if the on DP is true, else 0; writes do nothing.

**Relative humidity dehumidifier threshold.** Props 0…100, step max(1, step/multiple). Get clamp(raw/multiple,
0, 100). Set → clamp(value × multiple, min, max), immediate.

**Air quality.** Service AirQualitySensor (no subtype). AirQuality from the quality DP: if Integer,
v = clamp(raw/multiple, 0, 1000): ≤10 EXCELLENT(1), ≤50 GOOD(2), ≤100 FAIR(3), ≤200 INFERIOR(4), else POOR(5);
if Enum: `great` 1, `good` 2, `mild` 3, `medium` 4, `severe` 5; otherwise UNKNOWN(0). Optional densities
PM2_5Density, PM10Density, VOCDensity = clamp(raw/multiple, 0, 1000).

**Motion detected.** For an Enum DP: true iff status is `pir`. Any other type: always false. Own service:
MotionSensor, no subtype.

**Occupancy.** OCCUPANCY_DETECTED iff status is `presence`. Own service: OccupancySensor, no subtype.

**Programmable switch event (buttons, doorbells).** Props from the DP: if Enum, single = range contains `click`,
`single_click` or `1`; double = contains `double_click`; long = contains `press` or `long_press`; otherwise
single only. minValue = the lowest supported of (0, 1, 2), maxValue = the highest; if single and long but not
double, validValues = [0, 2]. Events (only from push, never at start-up, never re-read): for Raw or String DPs
the value is base64; if it decodes to a non-empty byte string → SINGLE_PRESS (the decoded text, usually a picture
URL, is logged at info). For Enum: `click`/`single_click`/`1` → SINGLE, `double_click` → DOUBLE,
`press`/`long_press` → LONG. For Integer: value > 0 → SINGLE. Anything else → warning, no event.

**Energy (Eve characteristics).** Added to a service when the DPs exist (custom characteristics, float, read +
notify):

| DP | Characteristic | UUID | Value |
|---|---|---|---|
| `cur_current` | Amperes (A) | `E863F126-079E-48FF-8F27-9C2605A29F52` | raw / (1000 × 10^scale) when the DP unit is `mA`. (For any other unit the source divides by zero; a replacement should use raw/10^scale.) |
| `cur_power` | Consumption (W) | `E863F10D-079E-48FF-8F27-9C2605A29F52` | raw / 10^scale |
| `cur_voltage` | Volts (V) | `E863F10A-079E-48FF-8F27-9C2605A29F52` | raw / 10^scale |
| `add_ele` | Total Consumption (kWh) | `E863F10C-079E-48FF-8F27-9C2605A29F52` | raw / 10^scale |

**Light (generic light block).** Inputs: on DP, optional brightness, colour-temperature, colour and work-mode DPs,
and a Lightbulb service (if none is given, it uses the accessory's Lightbulb, or adds one named "<accessory name>
Light", no subtype). The light type:

| Type | Condition (evaluated in this order) |
|---|---|
| RGBCW | on, brightness, temperature, colour with `h`,`s`,`v` properties, work mode whose range has both `colour` and `white` |
| RGBC | same but no temperature |
| RGB | on, no temperature, colour with h/s/v (brightness and mode not required) |
| CW | on, brightness, temperature |
| C | on, brightness, no temperature |
| Normal | on only |
| Unknown | otherwise (nothing configured) |

"White mode": always for C and CW; never for RGB; for RGBC/RGBCW iff work mode status is `white`. "Colour mode":
always for RGB; never for C/CW; for RGBC/RGBCW iff work mode is `colour`. Colour status is a JSON string
`{"h":…,"s":…,"v":…}`; empty, `{}` or missing reads as h = s = v = 0. Colour properties give min/max for each of
h, s, v (e.g. `colour_data_v2` h 0–360, s 0–1000, v 0–1000; legacy `colour_data` often s, v 0–255).

- Normal: On block on that service.
- On (all other types): On = status **(online check)**. Set: send `{on: value}`, and when turning **on** and a
  brightness DP exists, also resend the cached brightness value in the same batch; debounced.
- Brightness: in colour mode, round(100 × v / v.max) clamped 0…100; in white mode, round(100 × raw / max)
  clamped 0…100 (only `max` is used, not `min`); in any other mode (e.g. `scene`, `music`) it reads 100. Set: colour
  mode → v = clamp(round(value × v.max / 100), v.min, v.max), send the whole colour JSON (h, s unchanged), no
  mode change; white mode → clamp(round(value × max / 100), min, max) to the brightness DP; other mode → warning,
  nothing sent. Debounced.
- Colour temperature (CW, RGBC, RGBCW): props 140…500 mired, step 1. For RGBC the props are fixed to 154…154
  (1,000,000/6500 rounded) and the value is always 154. Mapping uses Kelvin linearly: DP min ↔ 2000 K (500 mired),
  DP max ↔ 7142.857 K (140 mired). Get: K = remap(raw, min, max, 2000, 7142.857), mired = round(1e6/K) clamped
  140…500. Set: send work mode `white` (if a work-mode DP exists) and, except for RGBC, DP =
  round(remap(1e6/mired, 2000, 7142.857, min, max)); debounced.
- Hue (RGB, RGBC, RGBCW): get in white mode → the hue of 6500 K (48; see Gaps), else round(360 × h / h.max)
  clamped 0…360. Set: h = clamp(round(value × h.max / 360), h.min, h.max), send colour JSON and work mode
  `colour` (if present); debounced.
- Saturation: get in white mode → the saturation of 6500 K (2), else round(100 × s / s.max) clamped 0…100. Set
  like hue with s.max/100; sends colour JSON + `colour`; debounced.
- Colour JSON is sent as a compact string with keys in the order `h`, `s`, `v`, integer values.
- Adaptive Lighting: only if the device's override has `adaptiveLighting: true` and both brightness and
  temperature DPs exist (else a warning). Uses HomeKit's Adaptive Lighting controller in automatic mode on that
  Lightbulb.
- The detected type is logged at info.

### 5.3 Light — `dj dsd xdd fwd dc dd gyd tyndj sxd`

Required: `switch_led`. Services:

- Lightbulb, **no subtype**, no explicit name (accessory name): generic light with on `switch_led`, brightness
  `bright_value`|`bright_value_v2`, temperature `temp_value`|`temp_value_v2`, colour
  `colour_data`|`colour_data_v2`, mode `work_mode`.
- If `switch_pir` exists: Switch, subtype `switch_pir` (On block).
- If `pir_state` exists: MotionSensor, no subtype (Enum `pir` → motion).
- If `switch` exists: Switch, subtype `switch` (an RGB controller's master power).

### 5.4 Dimmer — `tgq tgkg`

Required: one of `switch`, `switch_led`, `switch_1`, `switch_led_1`; and one of `bright_value`, `bright_value_1`.

Migration: if a Lightbulb without subtype exists in the cache it is removed.

Channels: every specification code starting with `bright_value` (raw list; e.g. `bright_value`,
`bright_value_1`, `bright_value_2`, …). Suffix = the code minus `bright_value`. Per channel: Lightbulb, subtype =
the brightness code, name = device name if exactly one channel, else the brightness code (name helper applied).

- On: block On with `switch<suffix>` or else `switch_led<suffix>`.
- Brightness: let R = DP max (the range used is 0…max, not min…max). Props 0…100 step 1, narrowed when statuses
  `brightness_min<suffix>` and `brightness_max<suffix>` both exist and max > min: minValue = max(0,
  ceil(100 × minStatus / R)), maxValue = min(100, floor(100 × maxStatus / R)). Get = clamp(round(100 × raw / R),
  minValue, maxValue). Set → clamp(round(value × R / 100), DP min, DP max), debounced.
- If a push carries `brightness_min…`/`brightness_max…` (and the message's status count differs from the
  cached count), log that a restart is needed for the new range; props are not updated live.

### 5.5 Switch — `dlq kg tdq qjdcz szjqr` and Outlet — `cz pc wkcz`

Required: `switch` or `switch_1`. Main service type: Switch (Switch handler) or Outlet (Outlet handler).

Migration: a cached main-type service without subtype is removed.

Channels: every specification code starting with `switch` whose type is `Boolean` (raw list, sorted by code —
e.g. `switch`, `switch_1`, `switch_2`, `switch_usb1`, `switch_backlight`, …). Per channel: one service of the main
type, subtype = code, name = device name if exactly one channel, else the code (name helper). On block.

- Energy characteristics (§5.2) on the channel whose code equals the first present of `switch`, `switch_1`.
- If `va_temperature` or `temp_current` exists: TemperatureSensor, no subtype.
- If `va_humidity` or `humidity_value` exists: HumiditySensor, no subtype.
- **Inching** (pulse timer): if `switch_inching` exists and is a `String` DP: Switch, subtype `switch_inching`,
  name `switch_inching`. Its status is base64 of 3 bytes; On = (decoded length is 3 and byte 0 is 1) **(online
  check)**. Set: take the decoded 3 bytes (or 3 zero bytes if the length is not 3), set byte 0 to 1/0, send
  re-encoded base64, debounced. (Bytes 1–2 are the pulse duration, preserved.)

### 5.6 Wireless switch — `wxkg`

Required: `switch_mode1` or `switch1_value`. Channels: every specification code matching `switch_mode<digits>`
or `switch<digits>_value`. Per channel: StatelessProgrammableSwitch, subtype = code, name = device name if one
channel else the code; ServiceLabelIndex = the digits as a number. ProgrammableSwitchEvent props/events per
§5.2, events from push only.

### 5.7 Scene switch — `cjkg`

No required DP. Channels: Boolean codes starting with `switch` (raw list). Per channel: Switch, subtype = code,
name rule as above. On = status (no online check). Set: if a `mode<suffix>` DP exists (suffix = code minus
`switch`) and its status starts with `scene`, send `false` for the switch (scene mode buttons do not stay on);
otherwise send the value. Immediate.

### 5.8 White-noise light — `bzyd`

Required: `switch_led` and `switch_music`.

- If `colour_data` exists: Lightbulb (no subtype, no name) with the generic light block using on `switch_led` and
  colour `colour_data` only (→ type RGB). If the colour property lacks h/s/v, assume h 0–360, s 0–1000, v 0–1000
  (all scale 0, step 1).
- Otherwise: Switch subtype `switch_led` (On block), and remove any cached Lightbulb.
- Switch subtype `switch_music` (On block).

### 5.9 Fan — `fs fsd fskg`

Required: one of `switch_fan`, `fan_switch`, `switch` (the "fan on" DP, first present).

Fan service type: **Fanv2** if `child_lock` exists or one of `switch_horizontal`/`switch_vertical` exists;
otherwise **Fan** (v1). The other type's cached service is removed. Neither has a subtype.

- Fan (v1): On block on the Fan service with the fan-on DP.
- Fanv2: Active block with the fan-on DP; LockPhysicalControls from `child_lock`; SwingMode from the first of
  `switch_horizontal`, `switch_vertical`.
- Speed: if `fan_speed` or `fan_speed_percent` (first present) is Integer → integer rotation speed; else if
  `fan_speed_enum` or `fan_speed` is Enum → level rotation speed; else on-only rotation speed.
- RotationDirection from `fan_direction`: CLOCKWISE (0) unless status is `reverse` (→ COUNTER_CLOCKWISE 1). Set:
  CLOCKWISE → `forward`, else `reverse`, immediate.
- Light:
  - Dual light: if `light`, `bright_value`, `switch_led` and `bright_value_1` all exist → Lightbulb subtype
    `warm_light` name "Warm Light" (on `light`, brightness `bright_value`, type C) and Lightbulb subtype
    `white_light` name "White Light" (on `switch_led`, brightness `bright_value_1`, type C).
  - Otherwise, if `light` or `switch_led` exists: if any of `bright_value`|`bright_value_v2`,
    `temp_value`|`temp_value_v2`, `colour_data`, `work_mode` exists → Lightbulb (no subtype, no name) with the
    generic light block (on `light`|`switch_led`, those DPs); otherwise → Switch with subtype = the light DP's
    code (On block) and any cached Lightbulb removed.

### 5.10 Air conditioner — `kt ktkzq`

Required: `switch`; `mode`; one of `work_status`, `mode`; `temp_current`. AC modes = `auto`, `cold`, `hot`.

Main: HeaterCooler, no subtype.

- Active = ACTIVE iff `switch` true **and** `mode` ∈ AC modes. Set: send `switch` = (ACTIVE); if the current mode
  is not an AC mode, also send the first of `auto`, `cold`, `hot` present in the mode range. Debounced.
- CurrentHeaterCoolerState from `work_status`|`mode`: `heating`/`hot` → HEATING(2), `cooling`/`cold` →
  COOLING(3), else INACTIVE(0).
- TargetHeaterCoolerState: validValues from the mode range (`auto` → AUTO 0, `hot` → HEAT 1, `cold` → COOL 2);
  none → warning, not configured. Get: `hot` → HEAT, `cold` → COOL, else AUTO if valid else the first valid. Set:
  HEAT → `hot`, COOL → `cold`, else `auto`; debounced.
- CurrentTemperature from `temp_current` (block).
- LockPhysicalControls from `lock`|`child_lock`.
- Rotation speed levels from `fan_speed_enum`|`windspeed`, ignoring `auto`.
- Cooling and Heating thresholds both from `temp_set`: props min/multiple, max/multiple, step max(0.1,
  step/multiple). Get clamp(raw/multiple). When mode is `auto`, Cooling reads its minValue and Heating its
  maxValue, and writes are rejected by re-publishing those values (nothing sent). Otherwise set → value ×
  multiple, debounced.
- TemperatureDisplayUnits from `temp_unit_convert`|`c_f`.
- Dehumidifier (only if the mode range contains `wet`): HumidifierDehumidifier named "<name> Dehumidifier", no
  subtype. Active iff `switch` true and mode `wet`; set → `switch` = value **and** `mode` = `wet` (even when
  turning off), debounced. CurrentHumidifierDehumidifierState fixed DEHUMIDIFYING (3);
  TargetHumidifierDehumidifierState fixed DEHUMIDIFIER (2), only valid value. CurrentRelativeHumidity from
  `humidity_current` if present, else fixed 0. Lock as above, speed levels as above,
  RelativeHumidityDehumidifierThreshold from `humidity_set`.
- Fan (only if the mode range contains `wind`): Fanv2 named "<name> Fan", no subtype. Active iff `switch` true
  and mode `wind`; set → `switch` = value and `mode` = `wind`, debounced. Lock and speed levels as above.
- Extra sensors: TemperatureSensor (no subtype) from `temp_current`; HumiditySensor (no subtype) from
  `humidity_current` if present.
- Swing DPs are listed but not used.

### 5.11 Heater — `qn`

Required: `switch`. HeaterCooler, no subtype.

- Active from `switch`.
- CurrentHeaterCoolerState from `work_state`: `heating` → HEATING(2), `warming` → IDLE(1), other → INACTIVE(0);
  without the DP → IDLE.
- TargetHeaterCoolerState: only AUTO (validValues [0]); reads AUTO; writes ignored.
- CurrentTemperature from `temp_current`; LockPhysicalControls from `lock`; SwingMode from `shake`.
- HeatingThresholdTemperature from `temp_set`: props min/multiple, max/multiple, step max(0.1, step/multiple);
  get clamp; set value × multiple, immediate.
- TemperatureDisplayUnits from `temp_unit_convert`|`c_f`.

### 5.12 Thermostat — `wk wkf`

Required: one of `temp_current`, `temp_set`; and `temp_set`. Thermostat, no subtype.

- CurrentHeatingCoolingState: if a `switch` status exists and is false → OFF(0). Else, from the first of
  `work_state`, `mode`: `hot`/`opened`/`heating` → HEAT(1); `cold`/`eco`/`idle`/`window_opened` → COOL(2); other →
  OFF. Without either DP: compare target and current temperature raw values: target > current → HEAT, < → COOL,
  equal → OFF.
- TargetHeatingCoolingState: validValues always include AUTO(3); OFF(0) if a `switch` status exists; HEAT(1) if
  the `mode` range has `hot`; COOL(2) if it has `cold` or `eco`. Get: switch false → OFF; no `mode` DP → AUTO;
  `hot` → HEAT; `cold`/`eco` → COOL; `auto`/`temp_auto` → AUTO; other → AUTO. Set (immediate, one batch): if a
  `switch` status exists, OFF sends `switch=false`, any other value sends `switch=true` when it is currently false;
  then with a `mode` DP: HEAT → `hot` (if in range); COOL → `eco` if in range, else `cold` if in range; AUTO →
  `auto` if in range. Nothing to send → nothing sent.
- CurrentTemperature from `temp_current`|`temp_set` (block).
- TargetTemperature from `temp_set`: props minValue = max(10, min/multiple), maxValue = min(38, max/multiple),
  minStep = max(0.1, step/multiple); if maxValue ≤ minValue, warn and use 10…38 step 1 with multiple 1. Get
  clamp(raw/multiple). Set → value × multiple (not rounded), immediate.
- TemperatureDisplayUnits from `temp_unit_convert`|`c_f`.

### 5.13 Scene (Smart Home) — category `scene`

Pseudo-devices from §2.6 scenes, kept only when `enabled` is true and `status` is `"1"`: id = uuid = `scene_id`,
name = scene name, owner = home id (string), product id `scene`, category `scene`, no DPs, always online.

Service: Switch, no subtype. On reads false. Set true → trigger the scene; 150 ms later On is pushed back to false;
if the trigger fails → warning and a communication error to HomeKit. Set false → nothing.

### 5.14 Garage door — `ckmkzq`

Required: `switch_1`. GarageDoorOpener, no subtype.

- TargetDoorState: `switch_1` true → OPEN(0), false → CLOSED(1). Set: OPEN → true, CLOSED → false, immediate.
- CurrentDoorState from `doorcontact_state` (true = door open) and `switch_1`: both true → OPEN(0); both false →
  CLOSED(1); contact false and switch true → OPENING(2); contact true and switch false → CLOSING(3). Without
  `doorcontact_state` → STOPPED(4) always.
- ObstructionDetected: default (false).

### 5.15 Window covering — `cl clkg`; Window — `mc`

Required: `control` or `mach_operate`. For `mc` the source intends a Window service but never uses it: it gets
exactly the WindowCovering services below.

Curtains: one, or two if a `control_2` DP exists. Curtain 1: service WindowCovering, name and subtype `control`;
current DP `percent_state`; target-percent DP `percent_control`|`position`; control DP `control`|`mach_operate`.
Curtain 2: name and subtype `control_2`; current `percent_state` (the same DP as curtain 1 — a source quirk);
target `percent_control_2`|`position`; control `control_2`|`mach_operate`.

- CurrentPosition: clamp(current DP, 0, 100) if it exists; else clamp(target-percent DP, 0, 100); else from the
  control DP: `close`/`FZ` → 0, `stop`/`STOP` → 50, `open`/`ZZ` → 100, other → 50 (warning).
- PositionState: needs both current and target-percent DPs, else STOPPED(2). Target 100 and current ≠ 100 →
  INCREASING(1); target 0 and current ≠ 0 → DECREASING(0); else STOPPED.
- TargetPosition, when a target-percent DP exists: clamp(value, 0, 100); set → the value as is, debounced.
- Otherwise TargetPosition from the control DP: reads as for CurrentPosition; props minStep 50; set 0 → close,
  100 → open, anything else → stop, where the words are `FZ`/`ZZ`/`STOP` if the DP's enum range does not contain
  `open` ("old schema"), else `close`/`open`/`stop`; debounced.

Percent values are taken as 0 = closed, 100 = open (users invert with overrides).

### 5.16 Lock — `ms jtmspro`

Required: one of `open_close`, `closed_opened`, `lock_motor_state`. LockMechanism, no subtype.

- LockCurrentState from the first present of those three: truthy status → UNSECURED(0), falsy → SECURED(1). (A
  string status, e.g. an enum, is truthy whenever non-empty — a quirk.)
- LockTargetState only if `lock_motor_state` exists: same mapping. Set: request a password ticket (§2.6); on
  failure stop silently (warning logged); else call door-operate with `open` = (target is UNSECURED). Not
  debounced; the DP cache is not updated locally (state arrives through push).
- A replacement in Homeswift must route this through the runtime's security-accessory rules (locks are written
  only through confirmed tools).

### 5.17 Security system — `mal`

Required: `master_mode` and `sos_state`. SecuritySystem, no subtype, name helper with the device name.

- Current: `sos_state` truthy → ALARM_TRIGGERED(4); else `master_mode` `home` → NIGHT_ARM(2) if the last target
  set from HomeKit was NIGHT, else STAY_ARM(0); `arm` → AWAY_ARM(1); `disarmed` → DISARMED(3); other values →
  no value (undefined behaviour; treat as keep previous).
- Target: same mapping without the alarm case.
- Set: if `sos_state` is truthy and the target is DISARM(3), first send `sos_state=false`. Remember
  "night" = (target is NIGHT). Send `master_mode`: STAY(0) → `home`, AWAY(1) → `arm`, NIGHT(2) → `home`,
  DISARM(3) → `disarmed`. Both debounced. The night flag lives only in memory (lost on restart).

### 5.18 Valve — `ggq sfkzq`

Required: `switch` or `switch_1`. Migration: a cached Valve without subtype is removed.

Channels: `switch` and `switch_1`, each if present and Boolean. Per channel: Valve, subtype = code, name = device
name if one channel else the code (name helper); ValveType IRRIGATION(1); InUse = status ? IN_USE(1) :
NOT_IN_USE(0); Active block on the same DP.

### 5.19 Humidifier — `jsq`

Required: `switch`. Main: HumidifierDehumidifier, no subtype.

- Active from `switch`. CurrentHumidifierDehumidifierState: `switch` true → HUMIDIFYING(2), else INACTIVE(0).
  TargetHumidifierDehumidifierState: fixed HUMIDIFIER(1), only valid value.
- CurrentRelativeHumidity from `humidity_current`.
- RelativeHumidityHumidifierThreshold from `humidity_set` (warning if absent): props 0…100 step max(1,
  step/multiple); get clamp(raw/multiple, 0, 100); set → clamp(value × multiple, min, max) sent immediately, then,
  if a `spray_mode` DP exists, a second immediate command `spray_mode=humidity`.
- RotationSpeed from `mode` (warning if absent; a cached Fan service is removed): status `small` → 1, `middle` →
  2, anything else → 3, reported as remap(level, 0, 3, 0, 100) (33.33…, 66.67…, 100). Set: level =
  round(value × 3 / 100); 2 → `middle`, 3 → `large`, otherwise (0 or 1) → `small`; immediate.
- TemperatureSensor (no subtype) from `temp_current`.
- Light: generic light block on a new/cached Lightbulb named "<name> Light" (no subtype) with on `switch_led`,
  brightness `bright_value`|`bright_value_v2`, colour `colour_data`|`colour_data_hsv`, mode `work_mode` (no
  temperature) — only if `switch_led` exists.

### 5.20 Dehumidifier — `cs`

Required: `switch`; `humidity_indoor`. Main: HumidifierDehumidifier, no subtype.

- Active from `switch`; Current state `switch` true → DEHUMIDIFYING(3) else INACTIVE(0); Target fixed
  DEHUMIDIFIER(2).
- CurrentRelativeHumidity from `humidity_indoor`.
- LockPhysicalControls `child_lock`; RelativeHumidityDehumidifierThreshold `dehumidify_set_value`; speed levels
  `fan_speed_enum`; SwingMode `swing`.
- TemperatureSensor (no subtype) from `temp_indoor`.

### 5.21 Diffuser — `xxj`

Required: `switch_spray`.

- If `switch` exists: Switch subtype `switch` (On block).
- AirPurifier, no subtype: Active from `switch_spray`; CurrentAirPurifierState `switch_spray` true →
  PURIFYING_AIR(2) else INACTIVE(0); TargetAirPurifierState left at default; rotation speed levels from `level`.
- Light: generic light block on a Lightbulb "<name> Light" (no subtype): on `switch_led`, brightness
  `bright_value`|`bright_value_v2`, colour `colour_data`|`colour_data_hsv`, mode `work_mode`.
- If `switch_sound` exists: Switch subtype `switch_sound`.

### 5.22 Air purifier — `kj`; Extraction hood — `yyj`

Required: `switch`. AirPurifier, no subtype.

- Active from `switch`; CurrentAirPurifierState `switch` true → PURIFYING_AIR(2) else INACTIVE(0).
- TargetAirPurifierState from `mode`: `auto` → AUTO(1), else MANUAL(0); set AUTO → `auto`, else `manual`,
  debounced.
- LockPhysicalControls from `lock`.
- Speed: `speed` as Integer → integer rotation speed; else `fan_speed_enum`|`speed` as Enum → levels.
- Purifier only: air quality (§5.2) on an AirQualitySensor (no subtype) from `air_quality`|`pm25`, PM2.5 from
  `pm25`, VOC from `tvoc`. (The hood lists the same codes but does not configure air quality.)
- Hood only: light exactly as the fan's non-dual case (§5.9: `light`|`switch_led`, `bright_value`|`bright_value_v2`,
  `temp_value`|`temp_value_v2`, `colour_data`, `work_mode`; Lightbulb without subtype, or Switch subtype = light
  code).

### 5.23 Sensors

| Category | Required | Service (no subtype) and mapping |
|---|---|---|
| `mcs` contact | `doorcontact_state` or `switch` | ContactSensor: status truthy (open) → CONTACT_NOT_DETECTED(1), else DETECTED(0). |
| `rqbj` `jwbj` `sj` leak/gas | one of `gas_sensor_status`, `gas_sensor_state`, `ch4_sensor_state`, `watersensor_state` | LeakSensor: LEAK_DETECTED(1) if `gas_sensor_status` (or else `gas_sensor_state`) is `alarm` or `1`, or `ch4_sensor_state` is `alarm`, or `watersensor_state` is `alarm`; else 0. |
| `cobj` `cocgq` CO | `co_status` or `co_state` | CarbonMonoxideSensor: `alarm`/`1` → ABNORMAL(1) else NORMAL(0). CarbonMonoxideLevel from `co_value`: clamp(raw/multiple, 0, 100). |
| `co2bj` `co2cgq` CO₂ | `co2_state` | CarbonDioxideSensor: `alarm` → ABNORMAL(1). CarbonDioxideLevel from `co2_value`: clamp(raw/multiple, 0, 100000). |
| `ywbj` smoke | `smoke_sensor_status` or `smoke_sensor_state` | SmokeSensor: `alarm`/`1` → DETECTED(1). |
| `wsdcg` temp/humidity | one of `va_temperature`, `va_humidity`, `humidity_value` | TemperatureSensor from `va_temperature`; HumiditySensor from `va_humidity`|`humidity_value`. |
| `ldcg` light | `bright_value` | LightSensor: CurrentAmbientLightLevel = clamp(raw/multiple, 0.0001, 100000). |
| `pir` motion | `pir` | MotionSensor (Enum `pir` → true). |
| `hps` presence | `presence_state` | OccupancySensor (`presence`). |
| `pm25` `pm2.5` `pm25cgq` `hjjcy` air quality | `pm25_value` | AirQualitySensor with quality from `pm25_value`, PM2.5 `pm25_value`, PM10 `pm10_value`|`pm10`, VOC `voc_value`; plus TemperatureSensor from `va_temperature`|`temp_indoor`|`temp_current` and HumiditySensor from `va_humidity`|`humidity_value`. |
| `zd` vibration | `shock_state` | MotionSensor, MotionDetected initially false. On push of `shock_state` = `vibration` or `drop`: MotionDetected true, back to false 3 s after the last such event (timer restarts). Never re-read from status. |
| `qxj` weather station | none | For each specification code containing `ToutCh` (in code order), TemperatureSensor named "Temperature Sensor N", subtype `temperature_sensor_N` (N from 1): value clamp(raw/10^scale, −100, 100), 0 if no status. For each containing `HoutCh`: HumiditySensor "Humidity Sensor N", subtype `humidity_sensor_N`: the raw status value (no scaling), 0 if none. |

### 5.24 Wireless doorbell — `wxml`

Required: `doorbell_call`. StatelessProgrammableSwitch, no subtype; props/events per §5.2 from `doorbell_call`
(push only). Startup logs explain that a HomeKit doorbell without a camera is not used.

### 5.25 Camera — `sp`

No required DP.

- Doorbell: only if `doorbell_ring_exist` exists and one of `doorbell_pic`, `alarm_message` exists: Doorbell
  service (no subtype); ProgrammableSwitchEvent props from that DP. On push, if `doorbell_pic` is in the message
  with a string longer than 1 character (filters a placeholder `$`), fire its event; else the same test for
  `alarm_message`. (Base64-decoded non-empty → SINGLE_PRESS.)
- Motion: if `motion_switch` exists, Switch subtype `motion_switch` (On block). Always a MotionSensor named
  "<name> Motion Detect" (no subtype), MotionDetected initially false. On push of `movement_detect_pic` whose
  base64 decodes to something non-empty: motion true, back to false 30 s after the last event.
- Floodlight: if `floodlight_switch` exists: Lightbulb "<name> Floodlight" (no subtype), generic light with on
  `floodlight_switch` and brightness `floodlight_lightness` (type C).
- Video: unless the device id starts with `vdevo` (virtual device), a HomeKit camera:
  - Streaming options: SRTP AES_CM_128_HMAC_SHA1_80; H.264 profiles Baseline, Main, High; levels 3.1, 3.2, 4.0;
    resolutions (w×h@fps) 320×180@30, 320×240@15, 320×240@30, 480×270@30, 480×360@30, 640×360@30,
    640×480@30, 1280×720@30, 1280×960@30, 1920×1080@30, 1600×1200@30; audio AAC-ELD 16 kHz, no two-way audio;
    no HomeKit Secure Video recording.
  - Each stream start and each snapshot asks the cloud for a fresh RTSP URL (`stream/actions/allocate` with
    `type` `rtsp`). The URL carries credentials: secret.
  - Stream: FFmpeg reads the RTSP URL and transcodes video to H.264 (libx264, ultrafast preset, zero-latency
    tune, yuv420p, the requested frame rate and maximum bitrate), packetised to SRTP for the controller (packet
    size 1316, payload type and SSRC from the session); audio to AAC-ELD (or Opus if requested) at the requested
    sample rate, bitrate and channels, also over SRTP (packet size 188). Reconfigure requests are acknowledged
    and ignored. If the controller sends no RTCP for 5 × the RTCP interval, the stream is stopped. (Homeswift's
    `HomeswiftFFmpeg` and camera controller provide this.)
  - Snapshot: offline → error; else FFmpeg grabs one frame from a fresh RTSP URL as a JPEG; empty output → error.

### 5.26 Pet feeder — `cwwsq`

Required: `switch`. Switch, no subtype.

The source attaches several write handlers to the same On characteristic, so only the **last** one present
takes effect, in this order of precedence (last wins): `meal_plan` (on → send `true`), else `manual_feed` (on →
send `1`), else `slow_feed` (on → `true`), else `quick_feed` (on → `true`), else `light` (send the boolean). Turning
off sends nothing in the feed cases. Before those, an Active characteristic is attached to the Switch from
`switch` (Active block). On has no read handler (it keeps the last written value). BatteryLevel on the Switch
service from `battery_percentage` (raw). The `feed_report`/`feed_state` handlers are overwritten by the generic
StatusActive (= online), so they have no effect. Missing optional DPs each log a warning.

### 5.27 Cat toilet — `msp`

Required: `switch`.

- Main: Switch, subtype `switch`, name = device name (name helper): On block on `switch`; StatusFault from
  `fault`: > 0 → GENERAL_FAULT(1) else NO_FAULT(0).
- Switches (each if present; subtype = code; name helper with the given name; On block): `auto_clean` "Auto
  Clean", `manual_clean` "Manual Clean", `deodorization` "Deodorization", `uv` "UV Sterilization".
- `light`: Lightbulb subtype `light`, name "Mood Light"; On = status **(online check)**, set debounced.
- `status`: OccupancySensor subtype `status`, name "Status": detected iff status is `cleaning`, `uv` or
  `deodorization`.
- `notification` (bitmap): FilterMaintenance subtype `notification`, name "Waste Box": CHANGE_FILTER(1) iff bit 0
  is set.

### 5.28 Sauna — `qtwk`

Required: one of `currtemp`, `settemp`; and `settemp`. Thermostat, no subtype.

- Current and Target HeatingCoolingState: `powerswitch` status false → OFF(0), else HEAT(1). Target validValues
  [OFF, HEAT]; set OFF → `powerswitch=false`, HEAT → `powerswitch=true`, immediate.
- CurrentTemperature from `currtemp`|`settemp` (block, so clamped to ≤ 100).
- TargetTemperature from `settemp`: props max(30, min/multiple)…min(90, max/multiple), step max(0.1,
  step/multiple), reset to 30…90 step 1 (multiple 1) if invalid; get clamp, or minValue when the status is not a
  number; set value × multiple, immediate.
- TemperatureDisplayUnits from `temp_unit_convert`|`c_f`.
- Two Lightbulbs **always created**: subtype `lightswitch` name "Sauna Main Light" and subtype `ledswitch` name
  "Sauna LED Light"; each gets the generic light block (type Normal → On block) only if `lightswitch` /
  `ledswitch` exists.

### 5.29 IR control hub — `wnykq hwktwkq wsdykq`

No required DP. TemperatureSensor (no subtype) from `va_temperature`; HumiditySensor (no subtype) from
`va_humidity`|`humidity_value`. When the hub's status changes by push, every IR remote accessory whose parent is
this hub is re-read too (their temperature/humidity come from the hub).

### 5.30 IR generic remote (TV, set-top box, fan, light, amplifier, projector, DIY, …)

One Switch per key of `key_list`, at most 99 (excess keys are skipped with a warning): subtype = `key` (the key's
string identifier, e.g. `power`, `volume_up`), initial name = `key`, then the name helper sets Name and
ConfiguredName to `key_name`. On reads false. Set true → send the key press (DIY: the learned `code` via the
learning-codes endpoint if the key has one; otherwise the raw command with the remote's `category_id`,
`remote_index`, the key's `key` and `key_id`), not awaited; 150 ms later On is pushed back to false. Set false →
nothing.

### 5.31 IR air conditioner (remote keys `category_id` 5)

State kept locally in the device's status entries `power` (0/1 or boolean), `mode`, `temp`, `wind` (numbers or
numeric strings; parsed as integers, missing → 0). Mode numbers: 0 cool, 1 heat, 2 auto, 3 fan, 4 dehumidify.
Wind: 0 auto, 1 low, 2 medium, 3 high. Supported modes = the `mode` values present in `key_range`.

Every change updates the local state and schedules one AC command (§2.6) 100 ms after the last change
(trailing debounce), carrying power, mode, temp, wind (only power when off).

- HeaterCooler (no subtype): Active = ACTIVE iff mode ∈ {cool, heat, auto} and power on. Set ACTIVE: show the
  dehumidifier and fan services as inactive, switch mode to auto if the current mode is not cool/heat/auto; set
  power accordingly. CurrentHeaterCoolerState fixed IDLE(1). TargetHeaterCoolerState validValues from supported
  modes (auto → AUTO 0, heat → HEAT 1, cool → COOL 2; none → warning, not configured); get by mode (others →
  AUTO); set → that mode. CurrentTemperature = the parent hub's temperature sensor reading if it has one, else
  the set temperature. HeatingThresholdTemperature (if heat supported): props = min/max of the heat mode's
  `temp_list[].temp`, step 1; reads minValue in auto mode, else `temp`; writes ignored in auto mode, else set
  `temp`. CoolingThresholdTemperature (if cool supported): props from the cool mode's temperatures; reads/writes
  `temp`. RotationSpeed: props 0…3 step 1 unit "speed"; reads 3 when wind is auto, else wind; a non-zero write
  sets wind.
- HumidifierDehumidifier "<name> Dehumidifier" (only if mode 4 supported): Active iff mode 4 and power on; set:
  show the others inactive, mode 4, power per value. Current state fixed DEHUMIDIFYING, target fixed DEHUMIDIFIER.
  CurrentRelativeHumidity from the parent hub's humidity sensor, else 0. RotationSpeed as above.
- Fanv2 "<name> Fan" (only if mode 3 supported): Active iff mode 3 and power on; set: show the others inactive,
  mode 3, power per value. TargetFanState: AUTO(1) iff wind 0; set AUTO → wind 0, MANUAL → wind 1. RotationSpeed
  as above.

---

## 6. Behaviour

### 6.1 Writes and coalescing

- Commands with an empty code or an undefined value are dropped first (after override conversion, §1.4).
- If the device is **offline**: log a warning, re-read all characteristics, and fail the write with a HAP
  communication error (-70402). Nothing is sent.
- Otherwise the local status cache is updated **immediately** with the new device-side values (so subsequent
  reads and writes — e.g. hue then saturation — see them).
- Immediate writes send one `commands` request with that batch right away.
- Debounced writes go into a per-accessory queue keyed by DP code (a later value for the same code replaces the
  earlier one, keeping its original position); a single timer fires **100 ms after the most recent queued
  write** (trailing debounce, restarted by each write) and sends all queued commands in one request, then
  clears the queue. (The source clears the queue only after the request returns, so writes queued while it is in
  flight are lost; a replacement should snapshot and clear before sending.)
- The HTTP result of a debounced write is not reported to HomeKit (the write has already succeeded from
  HomeKit's point of view). No local rollback on failure; the next push corrects the state.
- A HomeKit write for one DP often produces a batch with several DPs (e.g. colour temperature sends `work_mode`
  and `temp_value`; light-on resends brightness).

### 6.2 Reads

Reads come from the cache (no HTTP per read). The cache changes only from: the initial device list, local
writes, protocol-4 pushes, and the online flag from protocol-20 pushes. There is **no polling**; if MQTT is
down, states go stale.

### 6.3 Unreachable devices

- The device `online` flag drives StatusActive on every service.
- Reads of On/Active (and the inching switch and cat-toilet mood light) fail with "communication failure" while
  offline, so the Home app shows No Response for those.
- Writes fail as in §6.1.
- Scenes are always online.

### 6.4 Re-reads after an event

After any status or info event for a device, every characteristic of that accessory (except
ProgrammableSwitchEvent) is re-evaluated and its value published; characteristics whose read fails (offline)
are skipped. This is also done once right after the accessory is configured.

### 6.5 Edge cases worth reproducing (or deliberately fixing)

- Wireless/doorbell/vibration/camera events fire only for pushes received after the accessory is initialised,
  never for the start-up status.
- A light whose work mode is `scene`/`music` reports brightness 100 and ignores brightness writes.
- Thermostat and heater target writes send value × multiple without rounding (e.g. 20.1 × 10 = 201.00000000000003);
  Tuya integer DPs reject fractions — rounding to an integer is a safe fix.
- Integer rotation speed writes are not clamped or rounded either.
- `bindUser` devices skip the category override; `delete` removes only devices of loaded homes/assets.
- The Custom flow's device-ids query is sent in one request regardless of count.
- If the MQTT access-config call fails at start, push never starts (no retry); the reconnect timer is never
  armed.
- The token refresh path puts the refresh token in the URL.

---

## 7. Lifecycle summary

1. Validate config (§1). 2. Log in and obtain a token (§2.3/§2.4). 3. Start MQTT (§3). 4. Fetch homes/assets,
devices, specifications (and scenes) (§2.7). 5. Apply category and unbridged overrides; discover IR remotes.
6. Save the device list file (diagnostics). 7. Create or restore accessories (§4–§5); remove unclaimed cached
accessories. 8. Handle push events (§3.4–§3.5) for the rest of the run. Stopping the plugin closes MQTT and the
reconnect timer (the source never does this explicitly; Homebridge just exits).

---

## 8. Logging (paraphrased)

Info-level, normal operation:

- "Logging in to Tuya Cloud" / "Getting token", "Login to <endpoint>", "Logging in with an MD5 password" (when
  the password is already hashed).
- For Custom: searching for, creating, or finding the default user `homebridge`; fetching the asset list and each
  asset's id and name; authorising assets; logging in as that user.
- "Starting MQTT connection", "Fetching home list" and each home's id and name, with whether it is included or
  excluded by the whitelist; "Fetching device list", "Fetching scene list" and each scene's id and name.
- "Got N device(s) and scene(s)", and where the device-list file was saved.
- Per accessory: restored from cache, added, removed as unused, hidden; light type; Adaptive Lighting enabled or
  disabled; key press counts truncated for IR remotes; picture URLs of doorbell/alarm events; motion events.

Warnings: unsupported device; missing required DP lists (with the category and the existing specification);
category overridden from X to Y; device unbridged; device offline, command skipped; specification/IR/scene fetch
failures with code and message; HTTP non-200; MQTT access-config failure; push messages that fail to decrypt;
unhandled push messages; out-of-whitelist `bindUser`/`delete`; "brightness range updated, restart needed";
"curtain amount: N" (the source logs this at warning level; info is enough); thermostat schema reset to defaults.

Errors: login/token failures with code and message, and the explanation table of §2.2; API-not-subscribed
explanations; network errors before retry; MQTT client errors; FFmpeg failures.

Debug (with `debug`/`debugLevel`): every HTTP request (method, endpoint, path, query, headers, body) and response
body; every decrypted MQTT message (topic, protocol, message, t); out-of-order corrections; every override
applied (schema, status, command); every characteristic value change; props applied.

**Secrets — never log, mask in diagnostics**: `accessKey`; the app `password` and its MD5; the `sign` header;
`access_token` and `refresh_token` (including the refresh URL path); the token `uid`; the MQTT `client_id`,
`username`, `password` (the password is the decryption key) and the decrypted key; RTSP URLs; device `local_key`;
users' `lat`/`lon`/`ip`. The source's debug output prints request headers and full responses, which contain
tokens: a replacement must redact them.

---

## 9. Test vectors

All values below were computed from the algorithms in this spec (Swift CryptoKit/CommonCrypto, cross-checked
with OpenSSL for the HMAC and ECB cases). Inputs are made up.

Common inputs: `accessId` = `4h3dxjpwamt9gcrkqv8e`; `accessKey` = `a1b2c3d4e5f60718293a4b5c6d7e8f90`;
`t` = `1700000000000`; `nonce` = `6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b`. "\n" denotes a line feed.

### 9.1 Token grant (Custom), no access token

`GET /v1.0/token?grant_type=1`

- Body SHA-256: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- String to sign: `GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nclient_id:4h3dxjpwamt9gcrkqv8e\n\n/v1.0/token?grant_type=1`
- HMAC message: `4h3dxjpwamt9gcrkqv8e` + `1700000000000` + `6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b` + string to sign
- `sign` = `BBCEDB8CC771DF36B9E16982F15ECBE008FFA31026C0A8041E0000ABF894BA57`

### 9.2 Smart Home login

Password `Secr3t!pass` → MD5 `e4dac8847254e28266642c1bfe2ea3d2`.

`POST /v1.0/iot-01/associated-users/actions/authorized-login`, body (exact bytes):
`{"country_code":33,"username":"user@example.com","password":"e4dac8847254e28266642c1bfe2ea3d2","schema":"smartlife"}`

- Body SHA-256: `7f77ea3885dd00d20ebf40d005fc98d6c3998f5f29830d944c40aabb6d1e50f4`
- String to sign: `POST\n7f77ea3885dd00d20ebf40d005fc98d6c3998f5f29830d944c40aabb6d1e50f4\nclient_id:4h3dxjpwamt9gcrkqv8e\n\n/v1.0/iot-01/associated-users/actions/authorized-login`
- `sign` = `51464A1C46F10EFD15B3845A45C533975E0730391490D70EF6FF780D37E3359F`

### 9.3 Signed GET with token and query

Access token `c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4`. `GET /v1.0/devices` with `device_ids` =
`bf0123456789abcdefgh,bf9876543210zyxwvuts` (sent as `?device_ids=bf0123456789abcdefgh%2Cbf9876543210zyxwvuts`).

- String to sign: `GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nclient_id:4h3dxjpwamt9gcrkqv8e\n\n/v1.0/devices?device_ids=bf0123456789abcdefgh,bf9876543210zyxwvuts`
- HMAC message starts `4h3dxjpwamt9gcrkqv8ec8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e41700000000000…`
- `sign` = `D376AAB0F3BF8DDCBA697E337E3E35D5608E9F295A103F47EA6A536C07B4D592`

### 9.4 Commands POST with token

`POST /v1.0/devices/bf0123456789abcdefgh/commands`, body:
`{"commands":[{"code":"switch_led","value":true},{"code":"bright_value_v2","value":500}]}`

- Body SHA-256: `1d7e4c0d0f92331a844393b7e3f87cd8794efa411efd49dc900666f0ff826dd5`
- `sign` = `67B12C4036EFA91F434C4E129DFBDB6D2EFB31C4BB3D7D5AE575FA8EAB3252C1`

Also: SHA-256 hex of `homebridge` (Custom user password) =
`eb54078a2ac3e88954aa509df41065698b9f18606ae744920390556247074cda`.

### 9.5 MQTT access config (illustrative response)

```json
{"success":true,"t":1700000000123,"result":{
  "url":"ssl://m1.tuyaeu.com:8883",
  "client_id":"cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c",
  "username":"cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c",
  "password":"f3a9c1d2e4b5a6978877665544332211",
  "expire_time":7200,
  "source_topic":{"device":"cloud/token/in/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"},
  "sink_topic":{"device":"cloud/token/out/cloud_4h3dxjpwamt9gcrkqv8e_6f1e2d3c"}}}
```

Key = characters 8…23 of the password = `e4b5a69788776655` (bytes `65 34 62 35 61 36 39 37 38 38 37 37 36 36 35 35`).
Reconnect after 7140 s.

### 9.6 Push message

Plaintext (protocol 4):
`{"dataId":"0005f1a2b3c4d5e6","devId":"bf0123456789abcdefgh","productKey":"keyabc123","status":[{"code":"switch_led","t":1700000000123,"value":false,"1":false}]}`

Version 1.0 (AES-128-ECB, PKCS#7, key above) — `data`:
`8qixNmdvVT+TMqkJInoo3vQAgAFyqOItDMaFGNCvjmWtxTkXMPpekhOf6egmTwX2oQox0bCHEAywYuWN2lWUDJViw3Fwega4FzDCAOT5bT1ETZPpZzyBbTX7MMXBqI3SwYRTFbaZBM9UpqniXQcOcGKMn7JGu7U7ZD4Pk4SUpwIrkgs1A6rJcLmVUo7635GZhgM4/xXJitON6iajtwqWtbo9S3UQHulImCG0umcKaQg=`

Full MQTT payload: `{"protocol":4,"pv":"2.0","sign":"…","t":1700000000,"data":"<data above>"}`.

Version 2.0 (AES-128-GCM), same key and plaintext, envelope `t` = `1700000000`, IV = ASCII `0123456789ab`
(hex `303132333435363738396162`), AAD = 6-byte big-endian `t` = `00006553f100`, tag
`9b28df4605276aea7c1e8f38528d9566` — `data` (4-byte IV length `0000000c`, IV, ciphertext, tag):
`AAAADDAxMjM0NTY3ODlhYs6FQVWU/rqyjQiKtsFMaOU4yLadR5iBnNVPg9uW/EkV12dT2zEOaN0ZSpeHyNGmlSYLNLSct0bJsgTau/MZs8mz7c8UVhcFlUeHmf5hnFmVBkgKuq8igppGkA3gUSqk0q/Xbq1Jt/GqPKQYu5IcstYepmYw5LiIUFtEJ1zXLAS4VZdmOgYR/2rBXtkuhNCm6RykzC4L/Rvtj0L7ZLGqazCbKN9GBSdq6nwejzhSjZVm`

Protocol 20 examples (decrypted):
`{"bizCode":"offline","bizData":{"time":1700000001},"devId":"bf0123456789abcdefgh","productKey":"keyabc123","ts":1700000001000,"uid":"ay1700000000000abcd"}`
`{"bizCode":"nameUpdate","bizData":{"name":"Desk Lamp"},"devId":"bf0123456789abcdefgh"}`
`{"bizCode":"bindUser","bizData":{"ownerId":"12345678","uid":"ay1700000000000abcd","token":"…"},"devId":"bfnewdevice000000001"}`

### 9.7 Device list (Smart Home, `GET /v1.0/homes/12345678/devices`)

```json
{"success":true,"t":1700000000456,"tid":"x","result":[
 {"id":"bf0123456789abcdefgh","uuid":"a1b2c3d4e5f60718","name":"Desk Lamp","online":true,
  "category":"dj","product_id":"keyabc123","product_name":"Smart Bulb","owner_id":"12345678",
  "local_key":"<secret>","ip":"203.0.113.7","lat":"0","lon":"0","time_zone":"+01:00","sub":false,
  "create_time":1690000000,"active_time":1690000000,"update_time":1700000000,"icon":"smart/icon/bulb.png",
  "status":[{"code":"switch_led","value":true},{"code":"work_mode","value":"white"},
            {"code":"bright_value_v2","value":800},{"code":"temp_value_v2","value":300},
            {"code":"colour_data_v2","value":"{\"h\":0,\"s\":1000,\"v\":1000}"}]},
 {"id":"bf9876543210zyxwvuts","uuid":"0718a1b2c3d4e5f6","name":"Power Strip","online":false,
  "category":"pc","product_id":"keyxyz789","owner_id":"12345678","status":[
   {"code":"switch_1","value":true},{"code":"switch_2","value":false},{"code":"switch_usb1","value":true},
   {"code":"cur_current","value":312},{"code":"cur_power","value":684},{"code":"cur_voltage","value":2301},
   {"code":"add_ele","value":1250}]}]}
```

### 9.8 Specification (`GET /v1.0/devices/bf0123456789abcdefgh/specifications`)

```json
{"success":true,"result":{"category":"dj",
 "functions":[
  {"code":"switch_led","type":"Boolean","values":"{}"},
  {"code":"work_mode","type":"Enum","values":"{\"range\":[\"white\",\"colour\",\"scene\",\"music\"]}"},
  {"code":"bright_value_v2","type":"Integer","values":"{\"min\":10,\"max\":1000,\"scale\":0,\"step\":1}"},
  {"code":"temp_value_v2","type":"Integer","values":"{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}"},
  {"code":"colour_data_v2","type":"Json","values":"{\"h\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":360,\"step\":1},\"s\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1},\"v\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1}}"}],
 "status":[
  {"code":"switch_led","type":"Boolean","values":"{}"},
  {"code":"work_mode","type":"Enum","values":"{\"range\":[\"white\",\"colour\",\"scene\",\"music\"]}"},
  {"code":"bright_value_v2","type":"Integer","values":"{\"min\":10,\"max\":1000,\"scale\":0,\"step\":1}"},
  {"code":"temp_value_v2","type":"Integer","values":"{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}"},
  {"code":"colour_data_v2","type":"Json","values":"{\"h\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":360,\"step\":1},\"s\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1},\"v\":{\"min\":0,\"scale\":0,\"unit\":\"\",\"max\":1000,\"step\":1}}"}]}}
```

Merged: all five codes `rw`, sorted `bright_value_v2`, `colour_data_v2`, `switch_led`, `temp_value_v2`,
`work_mode`. Light type RGBCW.

Expected HomeKit values for §9.7's lamp: On true; mode `white` → Brightness round(100 × 800 / 1000) = 80;
ColorTemperature: K = 2000 + 300 × 5142.857 / 1000 = 3542.857 → mired round(282.26) = 282; Hue 48, Saturation 2
(white mode). Writing Brightness 50 sends (100 ms later) `bright_value_v2` = 500. Writing ColorTemperature 200
mired → K 5000 → DP round(1000 × 3000 / 5142.857) = round(583.33) = 583, batch `[work_mode=white,
temp_value_v2=583]`. Writing Hue 120 then Saturation 50 within 100 ms → one request with `colour_data_v2` =
`{"h":120,"s":500,"v":1000}` and `work_mode` = `colour` (queue order: `colour_data_v2` first, then `work_mode`).

Power strip (category `pc`): three Outlet services, subtypes `switch_1`, `switch_2`, `switch_usb1`, named by code;
the `switch_1` service carries Amperes 312/1000 = 0.312 (unit `mA`, scale 0), Consumption 684/10 = 68.4 (scale 1),
Volts 230.1 (scale 1), Total Consumption 1.25 (scale 3). Offline: StatusActive false; reading On fails; writing
fails with -70402.

### 9.9 Accessory id

Device id `bf0123456789abcdefgh` → Homebridge accessory UUID `B5E06B64-B214-5AD5-71BE-E42176F85847` (§4).

---

## 10. Gaps and hard parts

1. **onGet/onSet are JavaScript.** Users' configs may contain arbitrary JS; only a subset (§1.4) can be
   supported. Unsupported expressions must fail loudly per DP (log once, leave the DP unconverted or hidden) rather
   than silently misbehave. There is no way to know every expression in the wild.
2. **GCM authentication.** The source never verifies the GCM tag, so I could not confirm from the source that the
   AAD (6-byte big-endian envelope `t`) is what Tuya actually authenticates, nor whether `t` is in seconds or
   milliseconds for version 2.0. Tuya's public docs describe the same layout. Recommend: verify the tag; if it
   fails, retry the AAD with the other time unit, and as a last resort accept the CTR-decrypted plaintext if it
   parses as JSON (matching the source's tolerance), logging at debug.
3. **ECB plaintext form.** The ECB path accepts base64 ciphertext; CryptoJS would also accept OpenSSL "Salted__"
   framing, which Tuya is not known to send; supporting it is not needed.
4. **Hue/saturation of 6500 K.** Derived, not observed: kelvin-to-RGB (Tanner Helland approximation) gives about
   (255, 254, 250), whose HSV rounded to integers is hue 48, saturation 2. If the library rounds differently the
   hue could be 47–50; these values are only shown while in white mode.
5. **Device-ids limit.** Tuya documents up to 20 ids per `GET /v1.0/devices`; the Custom flow sends all at once.
   Chunking by 20 is a safe improvement but the source behaviour with more devices is unverified.
6. **Asset paging.** Only the first 100 top-level assets are read; sub-assets beyond that, and nested assets, are
   not enumerated (authorisation with children covers access, but devices are only listed for top-level assets).
7. **MQTT robustness.** The source never retries a failed access-config and relies on the MQTT library's
   reconnect; Tuya invalidates credentials after `expire_time`. A replacement should retry with back-off.
8. **Camera.** Only the cloud RTSP allocation is known; how long the allocated URL stays valid, and whether the
   camera stream needs special FFmpeg input flags (RTSP over TCP), is not specified by the source. Recording is not
   implemented.
9. **Lock semantics.** `closed_opened` is likely an enum (`closed`/`open`) on some locks, but the source treats any
   non-empty string as unlocked. The door-operate API semantics (`open` true = unlock) are taken from the call;
   whether the ticket must be encrypted with the access secret (some Tuya lock APIs require it) is not done by the
   source.
10. **`mc` (door/window controller)** is presented as a Window in the docs but actually becomes a WindowCovering;
    keep WindowCovering for cache/iid compatibility.
11. **Second curtain** reads curtain 1's `percent_state`; there is no `percent_state_2` support.
12. **Undefined reads.** Several mappings can yield no value (security system with an unknown `master_mode`,
    reads of DPs without status); the source throws. Choose a sensible previous/default value.
13. **Homebridge-only artefacts not needed in Homeswift:** the `TuyaDeviceList.<uid>.json` file, `-D` debug
    flag, `dev_lang`/`dev_channel`/`devVersion` header values (any value works as far as known).
14. **Setup.** The source has no discovery or pairing; credentials come from the config block. In Homeswift the
    account login belongs in Setup (`accountAuthorization`), and secrets (`accessKey`, `password`) in secret-named
    keys; tokens obtained at runtime are not persisted by the source (each start logs in again).
