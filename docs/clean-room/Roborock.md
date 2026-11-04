# Roborock: functional specification

## 0. Provenance

| | |
|---|---|
| Source | https://github.com/tasict/homebridge-roborock-vacuum |
| Commit | `c16594fdd004e3d7b8fef9142d7f62ff02f0a006` (committed 2026-10-21) |
| Package | `homebridge-roborock-vacuum`, version 2.4.0 |
| Licence | MIT |
| Copyright | "Copyright (c) 2018-2019 Nico Hartung" in LICENSE. The README credits ioBroker.roborock by copystring as the project it was adapted from. The current maintainer/publisher is the GitHub user `tasict`, who is not named in LICENSE. |

The spec writer wrote this document and it contains no source code. It describes behaviour, wire formats and interface names (JSON keys, endpoint paths, method names, topic patterns, file names). It does not reproduce the source's structure. The test vectors in section 11 were computed independently from the algorithms described here, with Python and OpenSSL. None of the plugin's code was run.

Scope note: the original publishes each vacuum over HAP (the default) or over Homebridge 2's Matter API. Homeswift has its own Matter bridge that maps HAP services, so this spec covers the HAP behaviour in full. It covers the Matter-only behaviour (scene buttons and the dock-wash switch as bridged Matter accessories, ServiceArea rooms, multi-floor maps) only as far as it affects shared state and configuration (section 9).

---

## 1. Configuration

The platform name (`platform` in config.json) is **`RoborockVacuumPlatform`**. It is a singular platform: one block per bridge.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Always `RoborockVacuumPlatform`. |
| `name` | string | `"Roborock Vacuum"` | Log prefix only. |
| `email` | string | **required** | Roborock app account email. Also used as the login username, in the client-id header and as the account tag on cached files. Without it the plugin logs an error and stays idle. |
| `password` | string | absent | Account password. Used for a password login when no valid session is available. It is optional when a session exists (`encryptedToken`). If both `password` and `encryptedToken` are missing, the plugin logs an error and stays idle. **Secret.** |
| `encryptedToken` | string | absent | The cloud session (the login response's `data` object, section 2.4) sealed by the Homebridge settings page. Format: section 2.9. **Secret.** |
| `baseURL` | string | absent → region auto-detect | The login API host. It may be given with or without `https://` and with trailing slashes, all of which are stripped. Documented values: `https://usiot.roborock.com` (US), `https://euiot.roborock.com` (EU), `https://cniot.roborock.com` (CN), `https://api.roborock.com` (Asia). An explicit value always wins over discovery. |
| `language` | string | `"en"` | One of `en de es fr it nl pl pt ru uk zh-cn zh-tw`. Any other value becomes `en`. It selects the catalogue for names the plugin gives services (the dock-wash switch and the consumable services, section 6.5). It is also sent as the `header_clientlang` HTTP header on the login API. Changing it renames services only; ids never change. |
| `skipDevices` | string or array of strings | none | Device ids (duid) to leave out of HomeKit entirely. A string is split on commas and newlines, and entries are trimmed with empties dropped. |
| `matterDevices` | string or array | none | duids to publish over Matter instead of HAP. When Matter is unavailable they fall back to HAP with a warning (section 9). |
| `matterSceneDevices` | string or array | absent | duids of Matter-published vacuums whose scenes become Matter buttons. When absent, all Matter vacuums get them. Matter only. |
| `debugMode` | boolean | `false` | When false, debug log lines are dropped. |
| `currentRoomMqtt` | object | absent/disabled | Optional telemetry to a local MQTT broker (section 7.6). |
| `currentRoomMqtt.enabled` | boolean | `false` | Turns the feature on. |
| `currentRoomMqtt.brokerUrl` | string | `"mqtt://127.0.0.1:1883"` | Broker URL. |
| `currentRoomMqtt.topic` | string | `"homebridge/roborock/{duid}/current_room"` | Topic template with `{duid}` and `{name}` tokens. |
| `currentRoomMqtt.cleaningPollSeconds` | integer ≥ 5 | `10` | Status poll period while cleaning. |

Legacy key (not in the schema, still read): `ignoredDevices` is an array of strings matched against a device's `sn` or its `duid`. It only affects the library layer's polling lists, not which accessories exist (see 3.6).

Hard-coded timings that cannot be configured: home data refresh and per-device poll every **180 s**, active-status poll every **15 s**, request timeout **10 s**, MQTT forced reconnect every **3 h**.

Example block, as written by the original's settings page:

```json
{
  "platform": "RoborockVacuumPlatform",
  "name": "Roborock Vacuum",
  "email": "user@example.com",
  "password": "…",
  "encryptedToken": "eyJpdiI6Ij…",
  "language": "en",
  "skipDevices": ["1a2B3c4D5e6F7g8H9i0J"],
  "matterDevices": [],
  "debugMode": false
}
```

Protocol selection per duid: in `skipDevices` → skip. Otherwise in `matterDevices` → Matter if Matter is available, else HAP. Otherwise HAP. Skip takes precedence over Matter, and Matter over HAP.

---

## 2. Cloud API: authentication

### 2.1 Persistent client id

On first start the plugin generates a random UUID string (standard 8-4-4-4-12, lowercase, as from a v4 UUID generator) and stores it as the **client id**. The original keeps it in `roborock.clientID` in the storage directory as `{"val":"<uuid>","ack":true}`. It is reused forever and also shared with the settings page. It is part of the login identity: a new client id on the same account behaves like a new phone.

### 2.2 Region discovery

This runs only when `baseURL` is not configured.

- Probe these hosts in order: `usiot.roborock.com`, `euiot.roborock.com`, `cniot.roborock.com`, `ruiot.roborock.com`.
- For each host: `POST https://<host>/api/v1/getUrlByEmail?email=<email>&needtwostepauth=false` with no body and a 10 s timeout. No special headers are needed (the original sends none of the login headers here).
- Response body: `{"code":200,"msg":"success","data":{"url":"https://euiot.roborock.com","country":"FR","countrycode":"33"}}`. A non-200 code, missing `data`, missing `data.url` or a network error → try the next host.
- **Security check:** after stripping the scheme, path and trailing slashes from `data.url`, the host must be `roborock.com` or end in `.roborock.com`. Otherwise log a warning and abandon discovery: return "not found" without trying further hosts.
- Result: base host = the normalised `data.url`, plus `country` and `countrycode` (as a string, or absent when empty or null).
- If nothing is found, log a warning and use `usiot.roborock.com`.

Region to country fallback, used when discovery gave no country. The host's lowercase form is checked for a substring:

| host contains | country | countryCode |
|---|---|---|
| `euiot` | DE | 49 |
| `usiot` | US | 1 |
| `cniot` | CN | 86 |
| `api.roborock.com` | SG | 65 |
| anything else | US | 1 |

### 2.3 Login API client

Base: `https://<base host>`, timeout 20 s. Default headers on every request:

| Header | Value |
|---|---|
| `header_clientid` | Base64 (standard, padded) of the raw 16-byte MD5 of the UTF-8 string *email* immediately followed by *client id* (no separator). |
| `header_clientlang` | the sanitised `language` (e.g. `en`, `zh-cn`) |
| `header_appversion` | `4.54.02` |
| `header_phonemodel` | `Pixel 7` |
| `header_phonesystem` | `Android` |

Requests with a string body are sent as `application/x-www-form-urlencoded`. Responses are parsed as JSON when possible, otherwise kept as text. An HTTP status outside 2xx is an error that carries the status, headers and body.

### 2.4 Endpoints

All paths are relative to the login API base.

**Signature nonce** (needed before any login)
- Generate `s`: 12 random bytes, standard Base64, keep the first 16 characters, then replace **every** `+` with `X` and **every** `/` with `Y`.
- `POST api/v3/key/sign?s=<s>` with no body.
- Response: `{"code":200,"data":{"k":"<string>"}}`. If `data.k` is missing, the login fails ("Failed to obtain login signature").
- The pair (`k`, `s`) is kept and reused for later login attempts in the same process until a login succeeds, at which point it is discarded.

**User agreement version** (looked up for each login)
- `GET api/v3/app/agreement/latest?country=<country>` with the header `header_clientlang: en` overriding the default.
- Response: `{"code":200,"data":{"majorVersion":<int>,"minorVersion":<int>, …}}`. If the code is not 200, the values are not integers, or the request fails, use major **14**, minor **0**.
- The login endpoint answers code **3006** when the version is stale.

**Request an email code**
- `POST api/v4/email/code/send`, form body `type=login&email=<email>&platform=` (platform present but empty).
- Success: `code == 200`. Any other code is an error that carries `msg` and `code`.

**Login with email code**
- `POST api/v4/auth/email/login/code` with extra headers `x-mercy-k: <k>` and `x-mercy-ks: <s>`.
- Form fields, in this order: `country`, `countryCode`, `email`, `code`, `majorVersion`, `minorVersion` (the versions as decimal strings).
- On HTTP errors, the error response's body is used as the result.

**Login with password**
- `POST api/v4/auth/email/login/pwd` with the same `x-mercy-k`/`x-mercy-ks` headers.
- Form fields: `email`, `password` (encrypted, see below), `majorVersion`, `minorVersion`. No country fields are sent. The country is used only for the agreement lookup.
- Password encryption: AES-128-ECB with PKCS#7 padding. The key is the UTF-8 bytes of `k` rotated left by 4 characters (characters 4..end followed by characters 0..3; `k` is 16 characters). The output is standard Base64.

**Login results**
- `code == 200` with `data` → success. `data` is the **session** (called *userData* below).
- `code == 2031` → two-factor authentication required. Do not retry automatically. The user must request an email code and log in with it.
- Anything else → login failed. Log it with the JSON body (paraphrased, never the password).

Session (`data`) shape, with values replaced:

```json
{
  "uid": 1234567,
  "tokentype": "",
  "token": "rr6xxxxxxxxxxxxxxxxx:xxxxxxxxxxxxxxxxxxxxxx==",
  "rruid": "rr6xxxxxxxxxxxxx",
  "region": "eu",
  "countrycode": "33",
  "country": "FR",
  "nickname": "Someone",
  "rriot": {
    "u": "<user id string>",
    "s": "<session secret>",
    "h": "<HMAC key>",
    "k": "<MQTT key>",
    "r": {
      "r": "EU",
      "a": "https://api-eu.roborock.com",
      "m": "ssl://mqtt-eu-3.roborock.com:8883",
      "l": "https://wood-eu.roborock.com"
    }
  }
}
```

A session is **valid** when it has a non-empty `token` and an `rriot` object. Only `token`, `rriot.u/s/h/k`, `rriot.r.a` and `rriot.r.m` are used. **The whole object is secret.**

**Home detail** (needs the session token)
- `GET api/v1/getHomeDetail` with the header `Authorization: <token>` (the raw token, no scheme).
- Response: `{"code":200,"data":{"id":…,"name":"…","rrHomeId":1234567, …}}`. The **home id** is `data.rrHomeId`.
- A body with a numeric `code` other than 200 is an **explicit session rejection**. An empty or non-JSON 200 body is not a rejection.

### 2.5 Choosing a session at startup

Try each in order:
1. The session decrypted from `encryptedToken`, if valid.
2. The session cached on disk from an earlier password login (`roborock.UserData`: `{"val":"<JSON string of the session>","ack":true}`), if valid.
3. A password login, when `password` is set. On success, write the session to disk.
4. Otherwise there is no session (local-only start, section 8.2).

On a failed password login the original deletes the cached session file. It also tries to delete the cached home data, but that file deliberately survives (only the session and client-id files are ever removed). A failure counts as **retryable** only when no HTTP answer came back or the HTTP status was ≥ 500. A rejected login, a 2FA requirement or a missing password is not retryable.

### 2.6 Signed ("Hawk") API

Base: `rriot.r.a` (e.g. `https://api-eu.roborock.com`), timeout 20 s. Each request carries one `Authorization` header computed per request:

- `ts` = the current Unix time in whole seconds.
- `nonce` = 6 random bytes, standard Base64 (8 characters), keep the first 6 characters, then replace **only the first** `+` with `X` and **only the first** `/` with `Y`. (The asymmetry with 2.4 is how the original behaves. Either variant is presumably accepted by the server, but match it to be safe.)
- `prestr` = the colon-joined string `u : s : nonce : ts : md5hex(path) : "" : ""`. Here *path* is the URL path only, with its leading slash and **without** the query string. md5hex is lowercase hex. The last two fields (query hash and body hash) are empty, so the string ends in `::`.
- `mac` = standard Base64 of HMAC-SHA256 with the key `rriot.h` (UTF-8) over `prestr`.
- Header: `Authorization: Hawk id="<u>", s="<s>", ts="<ts>", nonce="<nonce>", mac="<mac>"`, with exactly that order, spacing and quoting.

Because the signature embeds the local clock, a host clock that is off makes every request fail with 401 (section 8.4).

### 2.7 Signed endpoints

| Call | Method and path | Response |
|---|---|---|
| Home data (startup) | `GET v2/user/homes/<homeId>` | `{"api":…,"result":{…home data…},"status":"ok","success":true}` |
| Home data (periodic refresh) | `GET user/homes/<homeId>` (no `v2/`) | same shape, `result` |
| Scenes | `GET user/scene/home/<homeId>` | `{"result":[scene,…], …}` |
| Run a scene in the cloud | `POST user/scene/<sceneId>/execute` with no body | ignored |
| Rooms of a shared device | `GET user/deviceshare/query/<duid>/rooms` | `{"result":[{"id":…,"name":"…"}…]}`. The id may appear as `id` or `roomId`. |

Home data (`result`) shape, with values replaced. Only the listed fields matter:

```json
{
  "id": 1234567,
  "name": "My Home",
  "products": [
    {
      "id": "4aBcDeFgHiJkLmNoPqRsTu",
      "name": "Roborock S7",
      "model": "roborock.vacuum.a15",
      "category": "robot.vacuum.cleaner",
      "schema": [
        {"id": "120", "code": "error_code"},
        {"id": "121", "code": "state"},
        {"id": "122", "code": "battery"},
        {"id": "123", "code": "fan_power"},
        {"id": "124", "code": "water_box_mode"},
        {"id": "125", "code": "main_brush_life"},
        {"id": "126", "code": "side_brush_life"},
        {"id": "127", "code": "filter_life"},
        {"id": "133", "code": "charge_status"}
      ]
    }
  ],
  "devices": [
    {
      "duid": "1a2B3c4D5e6F7g8H9i0J",
      "name": "Roborock S7",
      "localKey": "AbCdEfGhIjKlMnOp",
      "productId": "4aBcDeFgHiJkLmNoPqRsTu",
      "fv": "02.29.02",
      "pv": "1.0",
      "online": true,
      "sn": "R0000000000000",
      "featureSet": "2234201184108543",
      "newFeatureSet": "0000000000002041",
      "deviceStatus": {"120": 0, "121": 8, "122": 100, "123": 102, "124": 202,
                        "125": 87, "126": 80, "127": 72, "133": 1}
    }
  ],
  "receivedDevices": [ /* same shape: devices shared from another account */ ],
  "rooms": [ {"id": 11100845, "name": "Kitchen"}, {"id": 11100849, "name": "Living room"} ]
}
```

- `pv` is the protocol version: `"1.0"`, `"A01"`, `"B01"` (also seen as the 3 bytes 0x81 0x53 0x19) or `"L01"`.
- `localKey` is a 16-character string used as the AES key material. **Secret.** A device without one is logged as uncontrollable (with the list of field names it does have) and gets no local key. The original still shows its accessory, and its status comes only from home data.
- `featureSet` may be a number or a numeric string. It is used as a 64-bit-ish number (section 5.4). `newFeatureSet` is a hex string.
- `deviceStatus` maps schema id (string) to a number.
- `products[].schema[].id` may be a number or a string. Matching against `deviceStatus` keys is loose (the string form).

Scene shape:

```json
{
  "id": 1234567,
  "name": "After dinner",
  "enabled": true,
  "type": "WORKFLOW",
  "param": "{\"triggers\":[],\"action\":{\"type\":\"S\",\"items\":[{\"id\":1,\"type\":\"CMD\",\"name\":\"\",\"entityId\":\"1a2B3c4D5e6F7g8H9i0J\",\"param\":\"{\\\"id\\\":1,\\\"method\\\":\\\"do_scenes_segments\\\",\\\"params\\\":{…}}\",\"finishDpIds\":[130]}]}}"
}
```

`param` is a JSON **string**. Its `action.items[]` each have `type` (`"CMD"` for a device RPC; other types exist, e.g. `"DELAY"`), `entityId` (a duid) and `param` (another JSON string: `{id, method, params}`).

A scene **belongs to a device** when any of its items has `entityId == duid`. A scene whose `param` does not parse is skipped with a warning.

### 2.8 Session invalidation

See section 8.4 (401 handling) and 8.3 (the explicit rejection on getHomeDetail).

### 2.9 The `encryptedToken` format (compatibility)

- The value is standard Base64 of the UTF-8 JSON `{"iv":"<b64>","tag":"<b64>","data":"<b64>"}`.
- Cipher: AES-256-GCM with a 12-byte IV, a 16-byte tag and no AAD. The plaintext is the UTF-8 JSON of the session object (2.4).
- Key: 32 raw bytes in the file `roborock.token.key` in the Homebridge storage directory, created with random bytes and mode 0600 when absent. A key file of any other length is replaced with a new random key.
- Any decode, parse or authentication failure → treated as "no token".

A user moving to Homeswift brings the config block but usually not this key file, so the token cannot be decrypted. Homeswift must then fall back to the password, or to its own Setup flow (email code), and must not crash. If the user also copies `roborock.token.key`, the token can be decrypted as described.

---

## 3. Device discovery and identity

### 3.1 What becomes an accessory

Candidates are all `devices` and `receivedDevices` of the home data. Each candidate goes through these checks in order:

- Skipped by configuration (section 1) → no accessory. Log at info.
- The product `model` (via `productId` → `products[].id`, loose equality) does not start with `roborock.vacuum.` → no accessory ("not supported", info).
- A device configured for Matter while Matter is unavailable → warn, then publish over HAP.
- Otherwise there is one HAP accessory per device.

Shared devices (`receivedDevices`) **do** get an HAP accessory. However, the original creates no controller for them, so every command to a shared device is logged as "unknown device" and does nothing (section 8.6). Their state comes only from the home data snapshot.

### 3.2 Identity

- **Identity seed: the device's `duid`** (the Roborock device id, about 20 alphanumeric characters, stable across renames and Wi-Fi changes).
- In Homebridge the accessory UUID is HAP-NodeJS's name-based UUID of the duid string. That is SHA-1 over the UTF-8 duid, laid out in the pattern `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`, where each `x` takes the next hex digit of the digest in order, the literal `4` consumes no digit, and `y` takes the next digit d and writes `(d & 3) | 8`. Digits are lowercase. The accessory's context is the duid string itself. (This UUID algorithm is HAP-NodeJS's, not this plugin's. It is recorded so a migration tool could match old cache entries. Vector: section 11.7.)
- The accessory's display name is the device `name` at first creation.
- Service identities within the accessory (type and subtype). These must stay fixed:

| Service | HAP type | Subtype | Present when |
|---|---|---|---|
| Accessory Information | 3E | — | always |
| Fan v2 | B7 | none | always |
| Battery | 96 | none | always |
| Switch (dock mop wash) | 49 | `dock-wash` | dock can wash the mop (5.4) |
| Switch (scene) | 49 | `scene-<sceneId>` (decimal scene id) | one per enabled scene targeting the device |
| Filter Maintenance (filter) | BA | `filter` | status has `filter_life` |
| Filter Maintenance (main brush) | BA | `main-brush` | status has `main_brush_life` |
| Filter Maintenance (side brush) | BA | `side-brush` | status has `side_brush_life` |

### 3.3 Accessory Information

| Characteristic | Value |
|---|---|
| Manufacturer | `Roborock` |
| Model | product `model` (e.g. `roborock.vacuum.a15`), else `Unknown` |
| SerialNumber | device `sn`, else `Unknown` |
| FirmwareRevision | device `fv`, else `Unknown`. Refreshed on every state update (it can change after an OTA, and it can be missing from the first snapshot). |

### 3.4 Removal of stale accessories

This runs after a successful start only. If the service did not initialise (no home data at all), no cached accessory is removed.

- A cached accessory whose duid is now skipped or Matter-published is removed.
- A cached accessory whose duid is no longer in the home data (owned or shared) is removed.
- Duplicate cached accessories with the same UUID are removed.

### 3.5 Account / home

Only the account's single home (`rrHomeId` from getHomeDetail) is used. Multiple homes are not supported.

### 3.6 Library-level device lists (behavioural detail)

The lower layer builds its own lists. It decodes local keys for every owned and shared device that has one, but it creates controllers, polling and local connections only for **owned** devices whose model starts with `roborock.vacuum.`. The `skipDevices` value is **not** passed to that layer in the original, so skipped devices are still polled; only the legacy `ignoredDevices` filters them out there. A port may simply not poll skipped devices. The HomeKit-visible result is the same.

---

## 4. Messaging: frames, encryption, transports

### 4.1 Frame layout (cloud MQTT payloads and local TCP frames)

All integers are big-endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 3 | version, ASCII (`1.0`, `A01`, `B01`, `L01`, or bytes 0x81 0x53 0x19) |
| 3 | 4 | seq (uint32) |
| 7 | 4 | random (uint32) |
| 11 | 4 | timestamp (uint32, Unix seconds) |
| 15 | 2 | protocol (uint16) |
| 17 | 2 | payload length N (uint16) |
| 19 | N | encrypted payload |
| 19+N | 4 | CRC32 of bytes 0 … 18+N |

The CRC32 is the standard IEEE/zlib CRC-32 (reflected polynomial 0xEDB88320, init and xorout 0xFFFFFFFF).

**Header-only frames** (protocols 0, 1, 2 and 3: HELLO request, HELLO response, PING and PONG) have **no length field and no payload**: version(3) seq(4) random(4) timestamp(4) protocol(2) CRC32(4) = **21 bytes**, with the CRC over the first 17. A local stream segment whose length is 17 or 21 is treated as a header-only frame.

Sender counters: one process-wide `seq` starting at **1** and one `random` starting at **4711**. Both increase by 1 after every data frame built. Header-only frames built with explicit seq/random values do not advance them. The values are taken modulo 2^32.

Validation on receive: the version must be one of the known values (else log an error and drop), and the CRC must match (else log an error and drop). There must be a local key for the duid. Without one, log one warning per duid ("skipping, no local key") and drop silently afterwards. On a decrypt failure, log an error with the frame length and a hex preview of the first 12 bytes, and drop.

### 4.2 Payload encryption per version

*encTs(ts)*: write ts as 8 lowercase hex digits (zero-padded) h0…h7 and reorder them as **h5 h6 h3 h7 h1 h2 h0 h4**. Example: 1700000000 = `6553f100` → `1030556f`.

Salt `S1` = the 16-character ASCII string `TXdfu$jyZ#TZHsg4`.

- **1.0**: key = MD5( encTs(ts) ‖ localKey ‖ S1 ) as 16 raw bytes, all inputs as ASCII strings concatenated. Cipher: AES-128-ECB with PKCS#7 padding. The ts is the frame's timestamp field. **This is the main path for the supported models.**
- **A01**: AES-128-CBC with PKCS#7. Key = the localKey's 16 ASCII bytes. IV = the 16 ASCII characters at positions 8 … 23 of lowercase-hex MD5( hex8(random) ‖ `726f626f726f636b2d67a6d6da` ), where hex8 is lowercase and zero-padded.
- **B01** (and the 0x81 0x53 0x19 variant): AES-128-CBC with PKCS#7. Key = the localKey bytes. IV = the 16 ASCII characters at positions 9 … 24 of lowercase-hex MD5( hex8(random) ‖ `5wwh9ikChRjASpMU8cxg7o1d2E` ).
- **L01**: AES-256-GCM.
  - Key = SHA-256( encTs(ts) ‖ localKey ‖ S1 ), using the same string as for 1.0.
  - IV = the first 12 bytes of SHA-256( seq(4 BE) ‖ random(4 BE) ‖ ts(4 BE) ).
  - AAD (20 bytes) = seq ‖ connectNonce ‖ ackNonce ‖ random ‖ ts, each a 4-byte BE value.
  - Payload on the wire = ciphertext ‖ 16-byte tag.
  - It needs the per-connection nonces from the HELLO handshake (4.5). Without them, building or decoding fails.

### 4.3 Inner payload (RPC)

The request body before encryption is UTF-8 JSON with no extra whitespace.

- **1.0 / A01 / L01**:
  - The body is `{"dps":{"<P>":"<inner JSON as a string>"},"t":<ts>}`, where P is the frame's protocol number (`101` for the cloud, `4` for local).
  - The inner object is `{"id":<requestId>,"method":"<method>","params":<params>}`.
  - Param conventions: commands without arguments send `[]`; a number is wrapped as `[n]`; some methods take an object.
- **B01**: `{"dps":{"10000":{inner object}},"t":ts}`. The inner object is not stringified and also carries `"msgId":"<id as string>"`. A `get_prop` request becomes method `prop.get` with params `{"property": <original params>}`.

The original adds `security` blocks for map and photo requests (secure/photo). These are unused by the HAP features; skip them.

**Request id**: a process-wide counter shared by all devices and both transports. Each new request takes the current value and then increments it. When the counter has reached 9999, the request is given 0 and the counter is set to 0, so the first request after the wrap reuses 0. The sequence is therefore 0, 1, …, 9998, 0, 0, 1, … (an off-by-one in the original; it is harmless).

### 4.4 Cloud transport: MQTT

Derivations, with MD5 hex in lowercase:

- **username** = characters 2 … 9 (8 chars) of md5hex( `u` ‖ `:` ‖ `k` )
- **password** = characters 16 … 31 (16 chars) of md5hex( `s` ‖ `:` ‖ `k` )
- **client id** = username
- **endpoint** = standard Base64 of bytes 8 … 13 (6 bytes) of the raw MD5( `k` ), which gives 8 characters. It is used only in secure (map) requests.

Connection:

- Broker URL = `rriot.r.m` (e.g. `ssl://mqtt-eu-3.roborock.com:8883`, i.e. MQTT over TLS with the public CA).
- MQTT 3.1.1, keepalive 30 s, clean session, the client library's automatic reconnect.

Topics:

- Subscribe to `rr/m/o/<u>/<username>/#`.
- Publish requests to `rr/m/i/<u>/<username>/<duid>` at QoS 1.
- Device messages arrive on `rr/m/o/<u>/<username>/<duid>`.

Connection health:

- The connection counts as up only once the subscription is **granted**. A granted QoS of 128 (0x80) is a refusal: log an error and stay "down".
- If not up within 30 s, log a warning once. Retries continue anyway.
- On `error`, `close` or `offline` the connection becomes down. On `reconnect`, subscribe again.
- The client is closed and recreated every **3 hours** (forced reconnect).

Resolving the duid of an incoming message:

1. If the last non-empty topic segment is a known duid (one with a local key, or one in the device list), use it.
2. Otherwise scan the segments from the end for a known duid.
3. If no devices are known at all, use the last segment.
4. Otherwise ignore the message (debug log).

Every received message, whatever its content, counts as "cloud traffic seen" (8.5).

Incoming protocols:

- **102**: the decrypted payload is JSON `{"dps":{"102":"<JSON string>"},"t":…}`. B01 devices use `dps["10001"]` instead, as a string or an object. If neither key exists, the whole `dps` object is the message.
  - With an `id`: it is an RPC response `{id, result}`. Find the pending request with that id and complete it with `result`. Exception: if the request was secure or photo and the result is `"ok"` or `["ok"]`, it is only an acknowledgement, and the request stays pending. Responses for unknown ids are ignored. The result is also delivered as a status update for that duid (section 7.2).
  - Without an `id`: it is a **status broadcast**, a map of schema id to value. Translate ids 120 `error_code`, 121 `state`, 122 `battery`, 123 `fan_power`, 124 `water_box_mode`, 133 `charge_status`, record them as live status, and deliver the update for that duid.
- **300 / 301**: map and photo chunks (gzip or AES-CBC with the session nonce). Not needed for HAP.
- **500**: plain JSON, not encrypted beyond the frame. `{"online":false}` → log at info that the device is offline. `{"online":true}` → nothing. `{"mqttOtaData":{"mqttOtaStatus":{"status":"…"},"mqttOtaProgress":{"progress":n}}}` → log the firmware update status and progress at info. Anything else → warn "unrecognised".
- Anything else → debug.

### 4.5 Local transport: TCP port 58867

The local channel is used for every RPC except `get_network_info`/`service.get_net_info` (those always go through the cloud) and for shared devices.

- One TCP client per device IP, on port **58867**.
- Every frame in either direction is prefixed with a **4-byte big-endian length**. The receive side buffers until all visible length-prefixed segments are complete, then processes every segment in the buffer and clears it.
- Sanity limits: any length prefix over **8 MiB**, or more than **16 MiB** buffered → log a warning ("corrupt frame"), drop the buffer and destroy the connection.
- Local requests use protocol **4**, with the body as in 4.3 and `dps` key `"4"`. Local responses are protocol **4** frames whose payload is `{"dps":{"102":"<JSON string {id,result}>"},"t":…}`. Match the response by `id`, complete the pending request and deliver the result as a status update for that duid (7.2). Other protocols on the local channel are ignored.
- Before sending a local request: if no local connection exists, the request fails at once (no send). If the device is offline and has no local connection, it also fails.

Connection lifecycle:

- On connect: if the device had been demoted to the cloud, promote it back and log at info. Start the L01 handshake if the device is L01, and start keepalive for L01.
- On a connect error: if the device is online (cloud flag), demote it to **remote** (cloud only) and log at info. Either way, schedule a reconnect.
- On close: reject any pending handshake, forget the L01 nonces and schedule a reconnect.
- Reconnect: one timer per device, **60 s**. When it fires, refresh the IP first (UDP discovery; else `get_network_info` over the cloud, at most once per 60 s per device; else the last known IP), then reconnect.
- All of this stops on shutdown.

**L01 version probe**. This runs before each connect, only if the device's home-data `pv` is `1.0` and no override is known yet:

- Open a throwaway TCP connection and send a length-prefixed header-only L01 HELLO: protocol 0, seq 1, random = a random nonce in [10000, 32767], current timestamp.
- If any reply arrives within **3 s** whose bytes 4 … 6 (just after the 4-byte length) read `L01`, use L01 for all local traffic from then on. Log at info that the device reports 1.0 but answers L01 locally.
- Only a positive result is remembered.

**L01 handshake** (on connect, and before each local request when the nonces are missing):

- Pick connectNonce in [10000, 32767] and store it.
- Send a HELLO: protocol 0, seq 1, random = connectNonce, current ts, 21 bytes, length-prefixed.
- The device replies with protocol 1 and seq 1. Its `random` field is the **ackNonce**.
- Timeout 3 s. A failure is logged at debug, and the request proceeds and will most likely fail.

**L01 keepalive**: every **30 s**, send a header-only PING (protocol 2) with seq starting at 0x10000 and incrementing, and a random nonce in [10000, 32767]. The device closes idle L01 connections after about 60 s. The protocol 3 replies are ignored. 1.0 devices get no ping.

### 4.6 UDP discovery: port 58866

- Bind UDP **58866** (all interfaces) and listen for **5 s**. Each run uses a fresh socket, and concurrent requests share one run.
- Packet layout: version(3) seq(4) protocol(2) length(2) payload(length) CRC32(4). The payload starts at offset 11, and the packet must be at least 15+length bytes. The CRC is not checked.
- Decrypt the payload with AES-128-ECB, key = ASCII `qWKYcdQWrbm9hPqe`, without automatic padding. The payload length must be a non-zero multiple of 16, else ignore the packet. Then strip PKCS#7 padding only when it is valid (pad byte 1..16 and all pad bytes equal); otherwise keep the bytes as they are.
- The result is JSON with at least `duid` and `ip`. Accept it only when the duid has a known local key. The first IP per duid wins.
- If binding fails (another integration holds the port): warn the first time, debug afterwards, and continue with what is known.

### 4.7 Choosing the transport per request

For a request (duid, method, params):

1. Use the **cloud** if the device is remote (a shared device, or demoted after a TCP failure), or if the method is `get_network_info` / `service.get_net_info`.
2. Otherwise, if no local connection exists and MQTT is up → cloud. Log "falling back" at info once per (duid, method), then debug.
3. Otherwise, if the device is in **local-unresponsive cooldown** (8.5) and MQTT is up → cloud (same logging).
4. Otherwise **local**. If the local attempt fails with a real error (a timeout or a socket write error) and MQTT is up, send it **once** more over the cloud (logged once). A request that was refused before sending (offline, no connection) is not retried.

A successful local response clears that device's "logged once" set.

Before sending on either path:

- The device must be **reachable**: a live local connection, or the home-data `online` flag (owned or shared) is true. Otherwise refuse and log at debug.
- The cloud needs MQTT up, and local needs a connected socket. Otherwise refuse.

Timeout: **10 s** per request. On timeout, the pending entry is removed, the local receive buffer for the duid is cleared, and the method-timeout, local-timeout or cloud-timeout bookkeeping is updated (8.5). The request then fails with "… timed out after 10 seconds".

Scene items run locally (6.4) use only the local path with no cloud retry, so that a lost reply cannot start the same item twice.

---

## 5. Device model

### 5.1 RPC methods used

| Method | Params | Answer | Used for |
|---|---|---|---|
| `get_status` | `[]` | `[ {status object} ]` (or an object) | live status; V1 (`pv` 1.0) only |
| `get_prop` | `["get_status"]` | `[ {status} ]` | current-room telemetry poll |
| `get_consumable` | `[]` | `[ {main_brush_work_time, side_brush_work_time, filter_work_time, …} ]` (seconds) | consumable life |
| `get_room_mapping` | `[]` | `[[segmentId, roomId(, …)], …]` | segment → room name |
| `get_network_info` | `[]` | `{ip, ssid, mac, bssid, rssi}` or `[ {…} ]`; for B01 use `service.get_net_info`, where the ip may be under `ip`, `ipAddress` or `ipAdress` | local IP |
| `get_fw_features` | `[]` | `[111, 112, …]` | informational |
| `get_multi_maps_list` | `[]` | `[ {"map_info":[{"mapFlag":0,"name":"…"}…], …} ]` | multi-floor (Matter) |
| `load_multi_map` | `[mapFlag]` | `["ok"]` | multi-floor (Matter) |
| `app_start` | `[]` | `["ok"]` | start a clean |
| `app_stop` | `[]` | `["ok"]` | stop |
| `app_pause` | `[]` | `["ok"]` | pause (exposed by the API, not by HAP) |
| `app_charge` | `[]` | `["ok"]` | return to dock |
| `app_start_wash` | `[]` | `["ok"]` | dock: start a mop wash |
| `app_stop_wash` | `[]` | `["ok"]` | dock: stop a mop wash |
| `find_me` | `[]` | `["ok"]` | locate sound (Matter Identify) |
| `app_segment_clean` | `[{"segments":[16,17],"repeat":1}]` | `["ok"]` | room clean (Matter) |
| `resume_segment_clean` | `[]` | `["ok"]` | resume a room clean (Matter) |
| `set_custom_mode` | `[fanPower]` | `["ok"]` | suction (Matter clean modes) |
| `set_water_box_custom_mode` | `[mode]` | `["ok"]` | water flow (Matter clean modes) |
| `resolve_error` | `{"error_code": n}` (an object; arrays are rejected by the firmware) | `["ok"]` | clear a latched error |
| optional polls | `get_carpet_mode`, `get_carpet_clean_mode`, `get_water_box_custom_mode` (default models); `get_carpet_mode` (s6); `get_dust_collection_switch_status`, `get_wash_towel_mode`, `get_smart_wash_params` (params `{}`), `app_get_dryer_setting` (a27) | | polled but with no HAP-visible effect |

Models with **no** optional polls: `roborock.vacuum.s4 s5 s5e a08 a10 a40 a140 a95 a159 ss07`.

A command with a numeric value that goes through the generic path (e.g. `set_custom_mode`) is followed by a read of the matching `get_…` method: "set" replaced by "get" in the method name.

### 5.2 Status object (get_status), example

Values are replaced. The plugin records every **numeric** field as live status and reads `state`, `battery`, `error_code`, `charge_status`, `in_cleaning`, `map_status`, `dock_error_status`, `fan_power` and `water_box_mode`. `cleaning_info` is used by the telemetry only.

```json
[{"msg_ver":2,"msg_seq":1234,"state":8,"battery":100,"clean_time":1800,"clean_area":25000000,
  "error_code":0,"map_present":1,"in_cleaning":0,"in_returning":0,"in_fresh_state":1,
  "lab_status":1,"water_box_status":1,"fan_power":102,"dnd_enabled":0,"map_status":3,
  "is_locating":0,"lock_status":0,"water_box_mode":202,"water_box_carriage_status":0,
  "mop_forbidden_enable":0,"dock_type":3,"dust_collection_status":0,"auto_dust_collection":1,
  "mop_mode":300,"switch_map_mode":0,"dock_error_status":0,"charge_status":1,
  "cleaning_info":{"segment_id":16,"target_segment_id":-1}}]
```

`map_status >> 2` is the loaded map's **mapFlag**. The value 63 means none or unknown.

### 5.3 State codes

| Code | Meaning | Counts as **cleaning** |
|---|---|---|
| 0 | Unknown | |
| 1 | Initiating | |
| 2 | Sleeping | |
| 3 | Idle | |
| 4 | Remote control | yes |
| 5 | Cleaning | yes |
| 6 | Returning to dock | yes |
| 7 | Manual mode | yes |
| 8 | Charging | (docked) |
| 9 | Charging error | |
| 10 | Paused | |
| 11 | Spot cleaning | yes |
| 12 | In error | |
| 13 | Shutting down | |
| 14 | Updating | |
| 15 | Docking | yes |
| 16 | Go to | yes |
| 17 | Zone clean | yes |
| 18 | Room (segment) clean | yes |
| 22 | Emptying dust bin | (dock busy) |
| 23 | Washing the mop | yes (wash) |
| 25 | Washing the mop (alias) | yes (wash) |
| 26 | Going to wash the mop | yes (wash) |
| 28 | In call | |
| 29 | Mapping | |
| 30 | Egg attack | |
| 32 | Patrol | |
| 33 | Attaching the mop | yes |
| 34 | Detaching the mop | yes |
| 100 | Fully charged | (docked) |
| 101 | Device offline | |
| 103 | Locked | |
| 202 | Air drying stopping | |
| 6301 | Mopping | yes |
| 6302 / 6303 | Clean + mop (vacuum / mop phase) | yes |
| 6304 | Segment mopping | yes |
| 6305 / 6306 | Segment clean + mop | yes |
| 6307 | Zoned mopping | yes |
| 6308 / 6309 | Zoned clean + mop | yes |
| 6310 | Washing the duster at the dock | yes (wash) |

- **Cleaning set**: 4, 5, 6, 7, 11, 15, 16, 17, 18, 23, 25, 26, 33, 34, 6301–6310. Note that 8 (charging) and 10 (paused) are **not** in the set.
- **Mop-washing set** (dock-wash switch on): 23, 25, 26, 6310.
- **Docked set**: 8, 100.
- **Dock-busy set**: 22, 23, 25, 26.

Robot `error_code` labels (0 = none): 1 laser sensor fault, 2 collision sensor fault, 3 wheel floating, 4 cliff sensor fault, 5 main brush blocked, 6 side brush blocked, 7 wheel blocked, 8 device stuck, 9 dust bin missing, 10 filter blocked, 11 magnetic field detected, 12 low battery, 13 charging problem, 14 battery failure, 15 wall sensor fault, 16 uneven surface, 17 side brush failure, 18 suction fan failure, 19 unpowered charging station, 21 laser pressure sensor problem, 22 charge sensor problem, 23 dock problem, 24 no-go zone or invisible wall detected, 254 bin full, 255 internal error.

Dock `dock_error_status` labels (0 = none): 32 no dock dustbin or filter, 33 auto-empty fan error, 34 auto-empty jammed, 35 auto-empty voltage error, 38 clean water tank empty, 39 dirty water tank full or missing, 42 maintenance brush jammed, 44 water filter blocked, 46 dustbin not installed, 53 cleaning tank full or blocked.

Suction (`fan_power`) values in the V1 protocol: 101 quiet, 102 balanced (the plugin's default "on"), 103 turbo, 104 max, **105 off** (mop only), 106 custom, 108 max+.

Water (`water_box_mode`) values: **200 off**, 201 low, 202 medium (the default), 203 high. Water-slide models (feature bit, or model `roborock.vacuum.a298`) use 200 for off and 220 + position (1–30) otherwise, with default 233. The HAP accessory does not use either of these; the Matter clean modes do.

### 5.4 Capabilities from `featureSet` / `newFeatureSet`

Let F = featureSet as a number, and Fhi = floor(F / 2^32), the upper bits.

- **Dock washes the mop** (the dock-wash switch): bit 5 of Fhi. The original also has a fallback through a polled `dock_type` (not in {0, 1, 5} → washes), but nothing in the current code ever stores that value, so in practice **only the featureSet bit decides**. A port may add the fallback from live `dock_type` (from get_status): dock types 0, 1 and 5 do not wash, and every other value does.
- **Off-peak ("valley electricity") charging**: bit 13 of Fhi. It affects ChargingState (6.2).
- Water-slide mode: bit 106 of newFeatureSet. Bit n is bit (n mod 4) of the hex digit floor(n/4) counted from the **end** of the string.
- The water box exists (mop modes, Matter only) for a fixed model list: `s5e s6 a08 a10 a15 a27 a38 a40 a51 a62 a65 a70 a72 a73 a75 a87 a101 a97 a104 a135 a117 a21 a144 a147 a140 a95 a159 ss07`, all prefixed `roborock.vacuum.`.

Precision: F can exceed 2^53 in theory. Real values fit, and the original uses floating-point division followed by a 32-bit shift. Treat F as an unsigned 64-bit integer and take bits 32+5 and 32+13 directly.

### 5.5 Consumables

- **Rated life** in hours: main brush 300, side brush 200, filter 150 (the same for every model).
- From `get_consumable` (`*_work_time` in seconds): life% = max(0, round(100 − workTime / (hours × 3600) × 100)). The result is stored as the live fields `main_brush_life`, `side_brush_life` and `filter_life`, and pushed to the accessory.
- Otherwise the home data `deviceStatus` values for schema codes `main_brush_life`/`side_brush_life`/`filter_life` (typically ids 125/126/127) are used.
- Rounding is JavaScript round: halves go up.

### 5.6 Reading a status field

The value of a field (e.g. `state`) is looked up in order:

1. The **live** value: the latest numeric value from a get_status result, a status broadcast (translated ids) or a computed consumable life. It is used only if recorded less than **3 × 180 s = 540 s** ago.
2. Otherwise the home-data snapshot: find the product schema entry with `code == field`, then `deviceStatus[<its id>]`.
3. Otherwise **unknown**. Unknown values are never published to HomeKit, so that, for example, an unknown battery does not read as 0 %.

---

## 6. HomeKit behaviour (HAP)

### 6.1 Fan v2 (the vacuum)

- **Name**: the device name (default `Roborock Vacuum` if empty).
- **Active**:
  - Read → refresh state, then ACTIVE if the state is in the cleaning set, else INACTIVE.
  - Write ACTIVE → send `app_start`.
  - Write INACTIVE → cancel any local scene run on the robot, send `app_stop`, then cancel again and send `app_charge` (two commands in sequence).
  - After the write, the characteristic is set to the written value.
  - Errors are logged, not thrown, and HomeKit sees success.
  - `app_start` is refused while a multi-floor map switch is running. It throws and is logged ("switching floor maps, try again in a minute").
- Updates from pushes and polls: `state` present → Active from the cleaning set. **`in_cleaning` present → Active = (in_cleaning ≠ 0)**, applied after state in the same update, so it wins.
- **StatusFault** (an optional characteristic): GENERAL_FAULT (1) when `error_code` is a finite non-zero number, else NO_FAULT (0). The dock error is **not** reflected here.
- **StatusActive** (optional): true if a local connection is up, or if the home-data `online` is anything other than an explicit `false`. Unknown counts as true.
- The original adds no RotationSpeed, no TargetFanState and no other characteristics.

### 6.2 Battery

- **BatteryLevel** = `battery` (0–100), published only when known and finite.
- **StatusLowBattery** = LOW (1) when battery < **20**, else NORMAL (0).
- **ChargingState**: published only when `charge_status` is known.
  - CHARGING (1) when `charge_status ≠ 0`.
  - Otherwise CHARGING when `state == 8` and the device does **not** have the off-peak feature. On off-peak robots, 0 on the dock means waiting for cheap power.
  - Otherwise NOT_CHARGING (0).
  - When a push carries `charge_status` without `state`, the stored state is used.
  - Shared devices have no feature info, so they count as "no off-peak".

### 6.3 Dock mop-wash switch (`Switch`, subtype `dock-wash`)

- Present only when 5.4 says the dock washes the mop. It is re-evaluated on every home-data refresh: added when support appears, **removed** when it disappears.
- Default name: the `app_start_wash` text in the chosen language:

| Language | Name |
|---|---|
| en | Start Mop Washing |
| de | Beginnen Sie mit dem Moppwaschen |
| es | Comenzar a lavar el trapeador |
| fr | Démarrer le lavage à la vadrouille |
| it | Avvia il lavaggio del panno |
| nl | Start dweilwassen |
| pl | Rozpocznij mycie mopa |
| pt | Comece a lavar o esfregão |
| ru | Начать мытье шваброй |
| uk | Розпочати прання шваброю |
| zh-cn | 开始拖把清洗 |
| zh-tw | 開始拖布清洗 |

- **On**:
  - Read → state in the mop-washing set (23, 25, 26, 6310).
  - Write true → `app_start_wash`. Write false → `app_stop_wash`.
  - On error, put On back to the actual washing state.
  - It is updated whenever `state` changes. It is **stateful**: it also turns on for washes started elsewhere, including during a cleaning run.
- Naming rule (6.6) applies.

### 6.4 Scene switches (`Switch`, subtype `scene-<id>`)

- One per scene **belonging to the device** (2.7) with `enabled == true`. The default name is the scene `name` trimmed, or `Scene <id>` when empty.
- The set is reconciled on construction and on every home-data refresh. A refresh runs every 180 s, and scenes are fetched as part of it.
  - The reconciliation runs only when the **set of scene ids** changed (count or sorted ids).
  - New enabled scenes get a switch.
  - A switch whose scene id is **no longer in the device's scene list** is removed. (A scene that became disabled but is still listed keeps an existing switch: this is how the original behaves.)
- **On** behaves as a momentary switch:
  - Read → always false.
  - Write true → start the scene in the background (not awaited), then set On back to false after **1 s**.
  - Write false → nothing.
- Running a scene, given the scene id:
  1. Look the scene up in the cached list. If any target robot is in a multi-floor map switch, warn and do nothing.
  2. Cancel any local run on each target robot.
  3. If **every** item can run locally (all are `type == "CMD"`; `param` parses to an object with a non-empty string `method`; each target is an owned, controlled, locally connected, not-cooldown robot with `pv == "1.0"`), run it locally as described below.
  4. Otherwise, or if the local run's first item did not start, `POST user/scene/<id>/execute`. Without a cloud session, warn that the scene needs the cloud.
- **Local run**:
  - Items run in order. Each item sends `method` with `params` (`[]` if absent) over the local path.
  - An item has **started** when the reply is `"ok"` or `["ok"]`. Otherwise, poll get_status: the item counts as started only if the poll succeeded, the robot was **not** busy before sending and **is** busy now.
  - *Busy* means `in_cleaning > 0`, or the state is in the cleaning set, or the state is in the dock-busy set.
  - If the first item does not start, fall back to the cloud (as above).
  - After an item has started, poll status every **15 s**:
    - A fresh status with non-zero `error_code` → stop with "the robot reported error N".
    - Busy seen, then not busy and in the docked set → the item is done.
    - Busy never seen within **5 min** → stop ("did not start").
    - Running for more than **4 h** → stop.
  - A later item that does not start → stop.
  - On stop, log the items that were not run (index and method) at info.
  - Starting another scene on the robot, or `app_stop`/`app_charge` from HomeKit, cancels the remaining items. The item currently running is left alone.
  - Shutdown cancels all runs.

### 6.5 Filter Maintenance (consumables)

- For each of `filter_life` (subtype `filter`), `main_brush_life` (`main-brush`) and `side_brush_life` (`side-brush`): the service is created the first time its value is known (5.6). Models without the value never get the service. Services are never removed.
- On creation: Name and ConfiguredName are set to the label, and FilterLifeLevel is added.
  - Labels in `en`: "Filter", "Main brush", "Side brush".
  - Quirk: in every other language the original's catalogue lacks these keys and returns the **key itself**, so the services are named `reset_filter_work_time`, `reset_main_brush_work_time` and `reset_side_brush_work_time`. A port should use the English labels, or proper translations, instead. That changes only the names, not the ids.
- **FilterLifeLevel** = value clamped to 0–100.
- **FilterChangeIndication** = CHANGE_FILTER (1) when ≤ **5**, else FILTER_OK (0).
- They are updated on every state refresh and on every computed consumable push.

### 6.6 Naming rule for the switches (dock-wash and scenes)

- Each switch has Name and the optional ConfiguredName. HomeKit writes renames into ConfiguredName.
- On (re)configuration with a new default name D:
  - Let P be the previous Name value and C the current ConfiguredName.
  - Always set Name = D.
  - If C is empty or C == P, set ConfiguredName = D: the user had not renamed it, so it follows language and scene renames.
  - Otherwise keep C: the user renamed it.
- A controller write to ConfiguredName is persisted right away.

### 6.7 When things update

- **Home-data refresh** (every 180 s, after a successful fetch) → for every accessory: full state refresh (Active, dock-wash On, battery, charging, firmware revision, fault, StatusActive, consumables), scene switch reconciliation and dock-wash presence.
- **Per-device update** (a cloud RPC response, a cloud status broadcast, a local RPC response, a computed consumable push):
  - The payload is delivered **only** to that duid's accessory.
  - If it is an array, its first element is used, and it must be an object.
  - Schema-id keys under `dps` are translated (120 → `error_code`, 121 → `state`, 122 → `battery`, 123 → `fan_power`, 124 → `water_box_mode`, 133 → `charge_status`).
  - Only the fields present are applied: state, battery, charge_status, in_cleaning, error_code, consumables.
  - This also means any RPC answer that happens to contain such fields (e.g. a get_status reply) updates HomeKit immediately.

---

## 7. Polling and background work

### 7.1 Startup sequence

1. Load or create the client id. Without `email` → error, stop. Without `password` and without a valid session → error, stop.
2. Region discovery (2.2) unless `baseURL` is set.
3. Choose a session (2.5).
4. With a session: getHomeDetail → home id, then `v2/user/homes/<id>` → home data. Persist both (8.1). On failure, log the error and fall through to the cache.
5. Without home data: load the cached home data and home id. If none exist, or they belong to another account, log an error ("needs one successful online start") and stay idle: no accessories are touched or removed. With a cache, start in **local-only mode** (8.2).
6. Initialise from the home data:
   1. Collect local keys.
   2. Start MQTT when there is a session.
   3. Build the room-id → name map from `rooms`, then add rooms of shared devices (2.7).
   4. Schedule the 3 h MQTT reconnect and the 180 s home-data refresh.
   5. Load the cached scenes.
   6. When online, run one refresh now (home data via `user/homes/<id>` plus scenes).
   7. UDP discovery (5 s).
   8. Create the controllers for owned supported devices.
   9. Run `get_network_info` for each, over the cloud.
   10. Merge the IPs, in priority order: get_network_info, then UDP discovery, then cached IPs (only for devices with a local key).
   11. Persist the IPs and connect locally to each.
   12. For each controlled device that is reachable, start its intervals (7.3). Run `get_fw_features` once, then one full data poll (7.2).
7. Log a "started" line (a distinct line for local-only mode), then create or restore accessories (section 3).

### 7.2 Full data poll (every 180 s per reachable device, plus once at start)

The steps run in order. Each one logs its own errors and the next still runs.

1. `get_status` (pv 1.0 only; skipped during method backoff). Records live status.
2. `get_room_mapping`. Builds segment → room name using the `rooms` map. An empty answer warns "name your rooms in the app". While a map switch is running, the answer is ignored.
3. Multi-floor refresh (pv 1.0; Matter use; see 9).
4. `get_consumable` → consumable life (5.5).
5. Model-specific optional polls (5.1), each subject to method backoff (8.5).

### 7.3 Per-device intervals

- These are started when the device is reachable and stopped when it is not. The check runs after every home-data refresh, with fresh `online` flags, and starting is idempotent.
- **Full poll**: every 180 s.
- **Active status poll**: every **15 s**. It sends `get_status` only when a local connection is up **and** either MQTT is down or the current state is in the cleaning set. It is skipped while the previous poll is still running.
- **1 Hz tick** for the current-room telemetry, only when that feature is enabled (7.6).

### 7.4 Home-data refresh (every 180 s)

1. Without a signed API (no session yet): try to log in again. This is allowed only with a password and a retryable last failure. On success, set up the APIs and MQTT and log at info. Otherwise return.
2. Without a home id: getHomeDetail. On failure, log at debug and return. On success, persist the home id.
3. `GET user/homes/<id>`.
   - A result → persist it as home data, mark the cloud reachable (log the recovery once), fetch the scenes (persist them), notify the accessories, and re-check per-device intervals.
   - An empty result → warn.
   - An error → 401 handling (8.4), or "cloud failure" logging (8.3).

### 7.5 Room names

The segment → room name map comes from `get_room_mapping` answers `[segmentId, roomId]` and home-data `rooms` (`id` → `name`). Unnamed segments are omitted. HAP uses it only for the telemetry; Matter uses it for areas.

### 7.6 Current room to MQTT (optional)

- A separate client connected to `brokerUrl` (reconnect every 5 s, connect timeout 10 s). It only publishes. Its errors are logged at debug.
- The 1 Hz tick per device fires a poll when the current wall-clock second is divisible by the interval. The interval is min(`cleaningPollSeconds`, 180) while the last poll saw cleaning, else 180. One poll runs at a time.
- The poll sends `get_prop ["get_status"]` and takes `cleaning_info.segment_id`, `cleaning_info.target_segment_id`, `state` and `in_cleaning`.
- Payload, retained, QoS 0:
  `{"segment_id":n|-1,"room":"Kitchen"|null,"state":n|null,"target_segment_id":n|-1,"target_room":…|null,"in_cleaning":n|null,"ts":<ms epoch>}`.
  A missing or non-numeric segment id gives −1, and −1 gives room null.
- Publish only when the tuple (segment id, room, state, target id, target room, in_cleaning) changed. Clear the dedupe memory after a broker reconnect and after a failed publish.
- Topic: the template, with `{duid}` and `{name}` substituted. `{name}` is the device name lowercased, with each run of non-`[a-z0-9]` characters replaced by `_` and leading and trailing `_` trimmed; if that leaves nothing, the duid is used. If the template contains neither token, `/<duid>` is appended after trimming trailing slashes.

---

## 8. Resilience and edge cases

### 8.1 Files kept (original names, in the storage directory, mode 0600)

These matter for behaviour, not for compatibility. Homeswift keeps its own state. Secrets belong in the vault, not in plain JSON.

| Content | Original file | Secret |
|---|---|---|
| client id | `roborock.clientID` `{val, ack}` | no (but identity-bearing) |
| session from a password login | `roborock.UserData` `{val: JSON string}` | **yes** |
| home data | `roborock.HomeData` `{val: JSON string, ack, account: email}` | **yes** (local keys) |
| home id | `roborock.HomeId` `{val}` | no |
| last LAN IPs | `roborock.LocalDevices` `{val: {duid: ip}}`; never overwritten with an empty map | no |
| scenes | `roborock.Scenes` `{val: {result:[…]}, account: email}` | no |
| multi-floor rooms | `roborock.multimap.<duid>.json` `{maps:[{mapFlag,name}], rooms:{mapFlag:{segmentId:name}}}` | no |
| token key | `roborock.token.key` (32 bytes) | **yes** |
| device errors for the settings page | `roborock.deviceErrors.json` | no |

The cached home data and scenes are tagged with the account email. A cache from another account is ignored with a warning. If the storage directory is not writable, the original falls back to a temporary directory.

### 8.2 Local-only mode (cloud down at start)

- Accessories are built from the cached home data. Commands and scenes work over the LAN.
- Devices are found by UDP discovery, or dialled at their cached IP.
- MQTT is still started from the cached session and keeps retrying.
- The 180 s refresh brings cloud features back without a restart. Without a session, it logs in again automatically, but only with a password and after a network-level failure, never after a rejection or a 2FA requirement.
- Shared devices work only through the cloud.

### 8.3 Cloud-failure logging

- The first cloud failure in an outage is logged at **error** level, with the note that further failures go to debug. Later failures are logged at debug.
- The first success afterwards logs "reachable again" at info.
- An explicit session rejection at getHomeDetail during startup warns, clears the session (memory and disk) and fails that fetch, so the next start logs in again.

### 8.4 HTTP 401 from the signed API

1. If the response has a `Date` header and the skew from the local clock exceeds **60 s**: log an error about the clock (NTP), at most once every 10 min. Keep everything and keep polling.
2. Otherwise, if the session was already invalidated, do nothing.
3. Otherwise, ask getHomeDetail.
   - If it still accepts the token (or cannot be reached): log as a cloud failure, keep the session and retry next time.
   - If it explicitly rejects the token: mark the session invalid, warn ("re-authenticate in settings and restart"), delete the session and **stop the home-data refresh**.

### 8.5 Back-off bookkeeping

- **Method back-off**: 3 consecutive timeouts of the same (duid, method) → that method is skipped by optional polls, get_status and the multi-map list for **30 min** (logged at info). Any success clears it.
- **Local-unresponsive cooldown**: 3 consecutive *local* timeouts for a duid → prefer the cloud for that duid for **5 min** (logged at info). A local success clears it. This exists for models (e.g. `roborock.vacuum.a185`) that keep the socket open but never answer.
- **Silent MQTT session restart**: a cloud timeout counts only while MQTT claims to be connected and the cloud is not marked unreachable.
  - 3 counted timeouts with no MQTT message in between → close and reopen the MQTT client (logged at info).
  - The minimum time between restarts is 30 min × 2^(n−1), capped at 6 h, where n = restarts since traffic was last seen.
  - Any received MQTT message, or any successful cloud request, resets both the counter and n.
- **Transient error throttle**: error texts containing "retry", "locating" or "timed out after 10 seconds" are logged as a warning at most once per (duid, method) every **10 min**, with a count of suppressed repeats. Other errors are logged at error level with the method, duid and model.

### 8.6 Other edge cases

- **Commands before the service is ready** → warn "not initialised", do nothing.
- **Commands to a duid without a controller** (shared device, unsupported model) → warn "unknown device", do nothing. In HAP the write still appears to succeed.
- **Unsupported model** (not `roborock.vacuum.*`) → warn, no controller and no polling.
- **B01/A01/L01 home-data versions**: `get_status`, `resolve_error` and the multi-map features are 1.0-only. For B01, `get_network_info` becomes `service.get_net_info`. Commands still go out with the correct framing.
- **A device reported offline** (`online:false`, no local connection) → intervals stop and requests are refused locally. StatusActive becomes false.
- **Corrupt local framing** → reset the connection (4.5).
- **A pending request when its answer comes late** → ignored.
- **Clearing latched errors** (the original's settings page; Homeswift could offer it as an action):
  - With no explicit code: poll status, then resolve the dock error (`dock_error_status`) if it is non-zero, else the robot `error_code`. If both are 0 → "nothing to resolve".
  - Send `resolve_error {"error_code": n}`, then poll status again.
  - Allowed for pv 1.0 only.
- **Shutdown**: clear all timers, cancel scene runs, close local sockets and timers, close MQTT (both clients) and fail pending requests' timers.

---

## 9. Matter-related behaviour (reference only)

The original can publish a vacuum as a Homebridge-2 Matter accessory. In Homeswift the Matter bridge works from HAP services, so a drop-in port should do the following:

- Treat `matterDevices` duids as **HAP** (the original's own fallback when Matter is unavailable) and warn once that they are published over HAP. Their accessory then is the HAP one described above, with the same duid seed.
- Ignore `matterSceneDevices`.

For completeness, here is what the original does on Matter that HAP does not:

- Separate bridged accessories with ids derived from `<duid>-scene-<sceneId>` and `<duid>-dock-wash`. When the same scene name appears on several Matter vacuums, the vacuum name is appended in parentheses. When more than one Matter vacuum has a washing dock, the dock-wash name gets the vacuum name in parentheses.
- Room cleaning through `app_segment_clean`. Rooms come from get_room_mapping. Multi-floor maps come from `get_multi_maps_list` and `load_multi_map`:
  - **Discovery** runs once, only while docked. It loads each map whose rooms are not known, waits up to about 12 s (4 polls 3 s apart) for `map_status >> 2` to match, reads the rooms (once more after 7 s if empty), restores the original map and caches the result.
  - **While a switch is running**, cleaning commands and scenes are refused.
- Clean modes: vacuum = water 200 (off), mop = fan 105 (off), vacuum and mop, written with `set_custom_mode`/`set_water_box_custom_mode`.
- `find_me` for Identify.

---

## 10. Logging (paraphrased)

**Info**
- Starting, which may take a few minutes.
- Region auto-detected (the host).
- Using the session from config / from disk.
- MQTT initialised.
- MQTT connection closed or reconnecting.
- Starting finished (online) / finished in local-only mode.
- Per accessory: loading from cache, adding, restoring, removing (with a reason).
- Skipping a device / device not supported.
- Scene running locally / finished / stopped (with reason and unrun items).
- Falling back to the cloud for a method (once per method).
- A device marked remote / local connection restored.
- A device answers L01 locally despite 1.0.
- Pausing polling of a method / preferring the cloud for a device / restarting a silent MQTT session.
- A device is offline (protocol 500).
- Firmware update status and progress.
- The cloud is reachable again.

**Warn**
- Could not auto-detect the region (using the default).
- Region discovery returned a non-Roborock host.
- MQTT not connected within 30 s.
- A device has no local key.
- Skipping MQTT messages for a device without a local key (once).
- UDP discovery unavailable (first time).
- Corrupt local frame.
- Unknown device for a command.
- Unsupported model.
- Name your rooms in the app.
- Stored session rejected / API rejected the session (re-authenticate).
- Cached data belongs to another account.
- Starting in local-only mode.
- Scene could not start locally (asking the cloud) / scene needs the cloud.
- Unrecognised protocol-500 message.
- Throttled transient request failures.

**Error**
- Email missing / password or token missing.
- Login failed or needs 2FA (complete it in settings; trying local-only).
- Two-factor authentication required.
- Failed to fetch home data.
- No cached device data (cannot start offline).
- Clock skew (with the number of seconds).
- MQTT error / offline / subscription refused.
- Frame decode failures (with length and a 12-byte hex preview).
- First cloud failure of an outage.
- Request failures with method, duid and model.

**Debug**
- Payloads sent and received, region probe results, queue size, handshake details, per-request transport choice.

**Never log** these secrets: `password`, `encryptedToken` and its key, the session `token`, `rriot.u/s/h/k` and anything derived from them (the MQTT username and password, the Hawk MAC), the login signature `k`/`s`, the 2FA email code, any device `localKey`, L01 nonces, the decrypted session JSON, and the login request body.

The original logs the local key at debug during UDP discovery and full home-data and payload JSON at debug. A port must not.

Treat as personal data, and redact in shared logs: the email, device `sn`, `duid` (it is the identity, so keep it in logs at most at debug, or abbreviated), the home id, IPs and MACs, room and scene names, and the login response fields `uid`/`rruid`/`nickname`.

---

## 11. Test vectors

The spec writer computed these independently from the algorithms above (Python hashlib/zlib and OpenSSL). All hex is lowercase.

### 11.1 Timestamp encoding

ts = 1700000000 = `6553f100` → encTs = `1030556f`.

### 11.2 Version 1.0 cloud request frame

- localKey = `0123456789abcdef`, ts = 1700000000, seq = 1, random = 4711 (0x1267), protocol = 101 (0x65).
- Key input string: `1030556f0123456789abcdefTXdfu$jyZ#TZHsg4`
- AES key = MD5(that) = `636322e9ad7f7117a110699a5f24b854`
- Plaintext (85 bytes): `{"dps":{"101":"{\"id\":1234,\"method\":\"get_status\",\"params\":[]}"},"t":1700000000}`
- Ciphertext (AES-128-ECB, PKCS#7, 96 bytes):
  `cd75d0cc7be588661f01a212fcb60d6b83c361cbb01cfac73f5d2ad6c7a0a2cc6d8ceb598d8c9ecca27be1612424a861e3412afa8e985f18be3593aefb78dfcb9d4f60bd55eecdfe9cb19f6d9db92c6fe72d9f5af7f916109a6e504183e2f012`
- Header (19 bytes): `312e30 00000001 00001267 6553f100 0065 0060`
- CRC32 over header + ciphertext = `d5e82875`
- Full frame (119 bytes):
  `312e3000000001000012676553f10000650060cd75d0cc7be588661f01a212fcb60d6b83c361cbb01cfac73f5d2ad6c7a0a2cc6d8ceb598d8c9ecca27be1612424a861e3412afa8e985f18be3593aefb78dfcb9d4f60bd55eecdfe9cb19f6d9db92c6fe72d9f5af7f916109a6e504183e2f012d5e82875`

The same frame with protocol 4 and dps key `"4"`, prefixed with its 4-byte length, is the local form.

### 11.3 L01 HELLO (header-only)

seq 1, random (connectNonce) 12345 = 0x3039, ts 1700000000, protocol 0:
`4c3031 00000001 00003039 6553f100 0000` + CRC `e51df5ce` = 21 bytes `4c303100000001000030396553f1000000e51df5ce`; length-prefixed: `00000015` followed by the 21 bytes.

### 11.4 MQTT credentials

With rriot u = `u_example`, s = `s_example`, k = `k_example`:

- username (and client id) = `bb7e313c`
- password = `fc7fb84ae37f586d`
- endpoint = `fuqUBDD+`
- publish topic `rr/m/i/u_example/bb7e313c/<duid>`, subscription `rr/m/o/u_example/bb7e313c/#`

### 11.5 Hawk header

- u = `u_example`, s = `s_example`, h = `h_example`, nonce = `abcdef`, ts = 1700000000, path = `/v2/user/homes/123456`
- md5hex(path) = `9ecb378a3e28c3ddbcb2263794ef4743`
- prestr = `u_example:s_example:abcdef:1700000000:9ecb378a3e28c3ddbcb2263794ef4743::`
- mac = `xpdN3y4vrLL0IIvP8VFVgRWw4btPIDcmP42jAuaK54M=`
- Header: `Hawk id="u_example", s="s_example", ts="1700000000", nonce="abcdef", mac="xpdN3y4vrLL0IIvP8VFVgRWw4btPIDcmP42jAuaK54M="`

### 11.6 Login helpers

- Password encryption: k = `ABCDEFGHIJKLMNOP` → AES key `EFGHIJKLMNOPABCD`. Password `hunter2` → `LvL/DG4BURyfwhsOQkg4Qw==`.
- `header_clientid` for email `user@example.com` and client id `00000000-0000-0000-0000-000000000000` → `G+x9MCsEIMzp23ArH/Xywg==`.

### 11.7 Homebridge UUID of a duid (HAP-NodeJS algorithm, for migration only)

duid `EXAMPLEDUID123`: SHA-1 = `20df4a1b203571b76f119b314a44e8f1720eead7` → UUID `20df4a1b-2035-471b-b6f1-19b314a44e8f`.

### 11.8 UDP discovery packet (synthetic: header values invented)

- Plaintext `{"duid":"EXAMPLEDUID123","ip":"192.168.1.50"}`, key `qWKYcdQWrbm9hPqe`, AES-128-ECB with PKCS#7 → 48 bytes.
- Packet: version `312e30`, seq `00000001`, protocol `0002`, length `0030`, the 48 bytes, CRC.
  `312e3000000001000200309376423da61d4e3028fa115101790414afeddf22f9f5ffbb7f1d34a334bd6a1210196e18a41dad9d99720190a83ce6c4f2aadf90`
- A decoder takes the length at offset 9 and the payload at offset 11.

### 11.9 Status broadcast (decrypted protocol-102 payload, no id)

`{"dps":{"121":5,"122":87},"t":1700000000}` → live state 5 (cleaning → Active = 1) and battery 87 (BatteryLevel 87, StatusLowBattery 0) for the duid from the topic.

### 11.10 RPC response (decrypted)

- Cloud: `{"dps":{"102":"{\"id\":1234,\"result\":[{\"state\":8,\"battery\":100,\"charge_status\":1,\"error_code\":0,\"in_cleaning\":0}]}"},"t":1700000005}`. This completes request 1234 with that array. HomeKit: Active 0, Battery 100, ChargingState 1, StatusFault 0.
- Local: the same JSON in a protocol-4 frame.

### 11.11 Consumables

`get_consumable` → `[{"main_brush_work_time":324000,"side_brush_work_time":360000,"filter_work_time":513000}]`:

| Consumable | Work time | Rated | Life | Filter Maintenance |
|---|---|---|---|---|
| main brush | 90 h | 300 h | 70 % | FILTER_OK |
| side brush | 100 h | 200 h | 50 % | FILTER_OK |
| filter | 142.5 h | 150 h | round(5.0) = 5 % | CHANGE_FILTER |

---

## 12. Gaps and hard parts

1. **Login and 2FA flow in Homeswift.** The original relies on its own settings page for the email-code path and stores the result in `encryptedToken`. Homeswift must offer this through Setup (`accountAuthorization`/`authorize`):
   - region discovery → `key/sign` → `email/code/send` → `login/code`, or password → `login/pwd`, where code 2031 leads to the email code.
   - The session then goes in the vault.
   - An imported `encryptedToken` is unusable without the Homebridge key file (2.9).
2. **Server-side behaviour not visible in the source.** These are unknown: whether the `rriot.r.m` broker accepts MQTT 5, the exact TLS server names, whether the Hawk nonce variant matters, rate limits, and what the cloud returns for accounts with several homes. The Date-header skew check implies the server enforces timestamp freshness, but the tolerance is unknown.
3. **Firmware variance in the local protocol.** 1.0 is well covered. L01 requires the handshake, the AAD built from both nonces, and the probe for 1.0-reporting devices. A01 and B01 framing is described, but the plugin barely exercises them (no status polling for them), and B01 status semantics (the `prop.get` shape, `dps` 10000/10001) are not specified here beyond the framing. The IV substring offsets (8..23 for A01, 9..24 for B01) were taken as stated and not verified against a device.
4. **The local response only uses `dps["102"]`.** Local protocol-4 frames carrying a status broadcast (no id) are ignored by the original. It is unknown whether devices send any.
5. **The dock-wash fallback is dead.** The `dock_type` fallback never fires in the current code (5.4). Devices whose featureSet lacks bit 37 get no switch even with a washing dock. A port may use the live `dock_type`, at the cost of the switch appearing a few seconds after start.
6. **Untranslated consumable names.** In non-English languages, the consumable services get raw catalogue keys as names (6.5). A port should not copy that.
7. **Request-id wrap.** The ids wrap at 9999, with 0 issued twice in a row (4.3). The ids are shared between both transports and all devices, and with many in-flight requests a late reply could resolve the wrong request. This is unlikely, but a port could use per-transport ids.
8. **`receivedDevices` (shared devices)** appear in HomeKit but cannot be controlled at all in the original (8.6). It is unclear whether this is intentional. A port could control them over the cloud: same framing with the owner's local key, which is present in home data.
9. **`get_status` for ChargingState on old products.** Some older products' schemas lack `charge_status`. Then ChargingState stays unpublished until the first live get_status.
10. **Not determined:** the exact `result` envelope fields of the signed API besides `result` (the plugin reads only `result`); the full schema id list beyond 120–127 and 133; and whether `getUrlByEmail` needs any header. The original sends none; a plain HTTP client with default headers is assumed.
