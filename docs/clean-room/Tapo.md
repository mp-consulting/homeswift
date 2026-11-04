# Tapo plugin: functional specification

## 0. Provenance

- Source: https://github.com/apatsufas/homebridge-tapo-p100 (npm package `homebridge-tapo`, display name "Tapo P100 Plugin", version 1.5.4).
- Commit read: `9a8a83a90a22408e180b515c1ffc29f3d5c46f06` (shallow clone, branch head).
- License: Apache License 2.0 (full text in `LICENSE`, no NOTICE file). No copyright line appears in the repository; the copyright holder is the repository's author, GitHub user `apatsufas`. The README credits the Python library fishbigger/TapoP100 as the origin of the port.
- Written by the spec writer; contains no source code. Everything below is a description in my own words of observed behaviour. Recommendations where the source is buggy are labelled **Recommendation**; the rest describes the source.
- The repository's own example script (a standalone P110 check against a real device) was not run; nothing from the repository was executed.

## 1. Scope and supported devices

The plugin is a Homebridge *dynamic platform*. It has no discovery: the user lists each device by IP address. Five device kinds exist, picked by the `type` string:

| `type` value (case-insensitive) | Product | HomeKit category | Behaviour class |
|---|---|---|---|
| `Plug` (also the default, and any unrecognised value) | P100 / P105 | Outlet | plain plug |
| `PowerPlug` | P110 | Outlet | plug with energy |
| `Light` | L510E | Lightbulb | dimmable |
| `WhiteLight` | L520E | (see 3.1: in practice Outlet) | tunable white |
| `Colorlight` | L530E | Lightbulb | colour + tunable white + adaptive lighting + energy |

There is **no L900 (light strip) type** in the source. An L900 configured as `Colorlight` would talk the same protocol and the same `set_device_info` keys (hue, saturation, color_temp, brightness), but the source has never been tested with it (README lists P100, L510E, L530E as tested). See Gaps.

## 2. Configuration interface

Platform name (the `platform` value in config.json): **`TapoP100`**. Plugin type platform, singular (one block).

Top-level keys of the block:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | - | Always `TapoP100`. |
| `name` | string | `"Tapo Smart Platform"` | Platform name for the log. Not used for any id. |
| `username` | string | `""` | Tapo cloud account e-mail address. **Secret** (personal data). |
| `password` | string | `""` | Tapo account password. **Secret.** |
| `devices` | array of objects | absent | The devices. If absent or empty, nothing is created. |
| `pollingInterval` | number (seconds) | 10 | Parsed but **unused**. |
| `timeout` | number (seconds) | 15 | Parsed (converted to ms) but **unused**. |
| `waitTimeUpdate` | number (ms) | 100 | Parsed but **unused**. |

Each element of `devices`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | none (schema says required) | Display name; part of the identity seed (section 3.2). |
| `host` | string | required | IPv4 address or host name of the device; HTTP on port 80. |
| `type` | string | `Plug` behaviour | One of `Plug`, `PowerPlug`, `Light`, `WhiteLight`, `Colorlight`, matched case-insensitively (the schema's default is written lowercase `plug`). |
| `updateInterval` | number (seconds) | 10 | Poll period for the device state. A value of 0 or absent means 10. |
| `timeout` | number (seconds) | 2 | Request timeout used by the legacy (securePassthrough) protocol's login and data requests only. A value of 0 or absent means 2. KLAP requests and both handshakes ignore it (fixed 5 s). |
| `port` | number | - | Accepted in the typed config but **unused** (always port 80). |

The schema declares `updateInterval` and `timeout` defaults as strings (`"10"`, `"2"`); the runtime multiplies them by 1000, so numeric strings work as numbers. **Recommendation:** accept both numbers and numeric strings.

Credentials are shared by every device of the block (one Tapo account). Per-device credentials do not exist.

Example block (unchanged user input the replacement must accept):

    { "platform": "TapoP100", "name": "Tapo Smart Platform",
      "username": "me@example.com", "password": "...",
      "devices": [ { "name": "Kitchen", "host": "192.168.1.21", "type": "Plug", "updateInterval": 10, "timeout": 2 } ] }

README advice (paraphrased): the username is the account e-mail; the author advises a password of at most 8 alphanumeric characters (a workaround for old firmware); on current firmware "Third-Party Compatibility" must be switched on in the Tapo app for local control to work.

## 3. Device model

### 3.1 Type selection quirk

The type is lowercased and compared with `colorlight`, `light`, `powerplug`, and with the mixed-case literal `whiteLight`. Because a lowercased string can never equal `whiteLight`, **`WhiteLight` never selects the L520E behaviour**: such a device falls through to the plain plug behaviour (Outlet service, model "Tapo P100", category Outlet). The L520E behaviour exists but is unreachable. **Recommendation / decision for the implementer:** for a drop-in replacement, an existing `WhiteLight` user currently has an Outlet in HomeKit; switching to a Lightbulb changes the service type (HomeKit treats it as a new service, automations on it are lost). Either keep the outlet for compatibility, or implement the intended L520E lightbulb and accept the one-time change. The L520E behaviour is still specified below.

### 3.2 Identity (the stable id seed)

The accessory identity is **not** the device's `device_id` or MAC. It is derived only from configuration:

- seed string = `host` concatenated directly with `name` (no separator); if `name` is absent or empty, the seed is `host` alone.
- Homebridge UUID = SHA-1 of the seed's UTF-8 bytes, written as lowercase hex, first 32 hex digits grouped 8-4-4-4-12 with dashes (HAP-NodeJS's `uuid.generate`).

Consequences: renaming a device in config, or changing its IP, makes a new accessory. Two entries with the same host and name collide. `device_id`, `mac`, `hw_id` are read from the device but `hw_id` is only used as SerialNumber.

Vectors (computed by the spec writer):

| Seed | UUID |
|---|---|
| `192.168.1.21Kitchen` (host 192.168.1.21, name Kitchen) | `009b9a12-f6ba-1713-a87a-6ac8637c17f0` |
| `192.168.1.21` (no name) | `0d12ca59-9dc0-316b-eec6-436bb3beb04e` |

Accessory display name = `name`, or `host` when no name. The primary service's Name characteristic is set to `name` (which may be absent).

An accessory restored from cache whose seed matches is reused; cached accessories whose seed no longer appears in config are **not** removed (they remain until the user clears the cache).

### 3.3 Accessory Information

Set only after the first successful `get_device_info` (section 5):

- Manufacturer: `TP-Link`
- Model: a fixed string per behaviour, not the device's `model` field: `Tapo P100`, `Tapo P110`, `Tapo L510E`, `Tapo L520E`, `Tapo L530`.
- SerialNumber: the device's `hw_id`.
- Firmware revision is not set (the device's `fw_ver` is read but not exposed).

### 3.4 Services per behaviour

All characteristic writes and reads below are on one primary service.

**Plug (P100/P105)** - service Outlet:
- On (read/write): `device_on`.
- OutletInUse (read): always reports true (the device does not tell).

**PowerPlug (P110)** - service Outlet, plus a Eve energy history (fakegato type `energy`, 4096 entries, file storage):
- On (read/write): `device_on`.
- OutletInUse: no handler; stays at its default (false).
- Eve Current Consumption, UUID `E863F10D-079E-48FF-8F27-9C2605A29F52`: float, unit watts, min 0, max 65535, step 1, permissions paired read + notify.
- Eve Total Consumption, UUID `E863F10C-079E-48FF-8F27-9C2605A29F52`: float, unit kWh, min 0, max 4294967295, step 0.001, paired read + notify.
- A third Eve characteristic, Reset Total (`E863F112-079E-48FF-8F27-9C2605A29F52`, uint32, seconds, read/notify/write; when written, it would store "now minus 2001-01-01T00:00:00Z" in seconds and set Total to 0) is defined but **never added to any service** in this version.
- The Eve history service itself (fakegato's, UUID `E863F007-079E-48FF-8F27-9C2605A29F52`) is added by the history library.

**Light (L510E)** - service Lightbulb:
- On, Brightness (0-100 in HomeKit, the device's `brightness` 1-100 passed through unchanged).

**WhiteLight (L520E, intended)** - service Lightbulb:
- On, Brightness, ColorTemperature with props min 154, max 400, step 1 (mireds).

**Colorlight (L530E)** - service Lightbulb, plus Eve energy history (same parameters as P110):
- On, Brightness.
- ColorTemperature with props min **140**, max 400, step 1.
- Hue (0-360), Saturation (0-100).
- Eve Current Consumption and Eve Total Consumption (same definitions as P110), on the Lightbulb service.
- Adaptive Lighting controller in automatic mode (the bridge computes and writes ColorTemperature itself).

### 3.5 Value conversions

- Power: `device_on` boolean <-> On.
- Brightness: identity mapping in both directions; HomeKit 0 would be sent as 0 (device range is 1-100; behaviour of the device on 0 not determined).
- Colour temperature, write (HomeKit mireds to device kelvin): kelvin = floor(1 000 000 / mireds), then clamped to [2500, 6500]. Sent with hue 0 and saturation 0 in the same request. Examples: 140 -> 7142 -> 6500; 154 -> 6493; 200 -> 5000; 370 -> 2702; 400 -> 2500.
- Colour temperature, read (device kelvin to HomeKit): mireds = floor(1 000 000 / kelvin), clamped to [154, 400]. Examples: 2500 -> 400; 2700 -> 370; 4000 -> 250; 6500 -> 153 -> 154. A device value of 0 (bulb in colour mode) gives infinity -> 400 in the read handler; the poller skips a 0 value (see 5.3).
- Hue and saturation: HomeKit values are rounded to integers and sent unchanged (device hue 0-360, saturation 0-100). A colour write sends hue, saturation and `color_temp` 0 together; the component not being written is taken from the cached state (absent -> 0).
- P110 power: `current_power` from `get_energy_usage` is in milliwatts. The value pushed to Current Consumption is `current_power / 1000` (watts, not rounded). The value returned to a GET (and logged to history) is ceil(`current_power` / 1000).
- P110 total: Total Consumption = `today_energy / 1000` (`today_energy` in Wh, so kWh **for today only**; the "total" resets every day on the device).
- L530 energy (from `get_device_usage`): total = `power_usage.today / 1000` (kWh today); current = `power_usage.today / (time_usage.today / 60)`, i.e. today's Wh divided by today's on-hours: an average watts figure, not instantaneous. If the bulb's cached `device_on` is false, current reads 0. `time_usage.today` of 0 gives a division by zero (infinity/NaN) in the source. **Recommendation:** report 0 in that case.
- Nickname: the device returns `nickname` (and `ssid`) base64-encoded UTF-8. The source can decode it but never uses it (display names come from config).

## 4. Protocol

All traffic is plain HTTP to `http://<host>/` (port 80). The source contains both protocols but, as section 4.3 explains, **the working path in this version is KLAP**; the legacy securePassthrough path is attempted first at start-up and is only usable in a narrow case.

### 4.1 Legacy protocol: securePassthrough

Session set-up:

1. The client generates an RSA key pair, 1024-bit modulus, once per device object (at start-up). The public key is exported as an SPKI PEM text (the usual "BEGIN PUBLIC KEY" armour with line breaks).
2. Handshake: POST `/app`, JSON body: an object with `method` = `handshake` and `params` = { `key`: the PEM text, `requestTimeMils`: a number }. Header `Connection: Keep-Alive`. Timeout 5 s.
3. Response JSON: `error_code` (0 on success) and `result.key`, a base64 string. Base64-decode it and RSA-decrypt with the private key using PKCS#1 v1.5 padding. The plaintext's bytes 0-15 are the AES key and bytes 16-31 the AES IV.
4. The first `Set-Cookie` response header is kept up to its first `;` (for example `TP_SESSIONID=<value>`) and sent back as `Cookie` on later requests.
5. Login: build the inner JSON text with `method` = `login_device`, `params` = { `username`: U, `password`: P } and a top-level `requestTimeMils`. U = base64 of the ASCII text of the lowercase hex SHA-1 digest of the e-mail (the 40 hex characters are what gets base64-encoded, not the 20 raw bytes). P = base64 of the password's UTF-8 bytes. No Unicode normalisation in this protocol.
6. Encrypt the inner text with AES-128-CBC, the handshake key and IV, PKCS#7 padding; the ciphertext is base64-encoded. The same fixed IV is used for every message of the session.
7. POST `/app` with JSON body { `method`: `securePassthrough`, `params`: { `request`: <base64 ciphertext> } }, headers `Cookie` and `Connection: Keep-Alive`, timeout = the device's `timeout` setting (default 2 s).
8. Response JSON: outer `error_code` and `result.response` (base64). Decode and decrypt with the same key/IV; the inner JSON's `result.token` is the session token.
9. Every later request: POST `/app?token=<token>`, same securePassthrough wrapping, `Cookie` header.

The inner JSON texts the source sends are built by hand and end with a stray `;` after the closing brace (for example a get request is the text of an object with `method` and `requestTimeMils`, followed by `;`). Devices accept it. `requestTimeMils` is the current time in milliseconds multiplied by 1000 and rounded (so in fact microseconds). Neither detail appears to matter; a well-formed JSON object without the semicolon is expected to work too (unverified).

### 4.2 KLAP protocol

Credentials hash: auth_hash = SHA-256( SHA-1(username bytes) || SHA-1(password bytes) ), where each SHA-1 is the 20 raw digest bytes, the username and password are first NFKC-normalised and encoded as UTF-8. 32 bytes.

Common request headers for all three KLAP endpoints: `Connection: Keep-Alive`, `Host: <host>`, `Accept: */*`, `Content-Type: application/octet-stream`, and `Cookie: <saved cookie>` whenever a cookie has been saved. Timeout 5 s. Bodies are raw bytes.

Handshake 1:
1. local_seed = 16 cryptographically random bytes.
2. POST `/app/handshake1` with body local_seed.
3. The response body is 48 bytes: remote_seed = bytes 0-15, server_hash = bytes 16-47.
4. The response sets the session cookie: the first `Set-Cookie` header, kept up to its first `;`, which is `TP_SESSIONID=<hex>`. The rest of the header is a `TIMEOUT=<seconds>` attribute (typically 86400, from knowledge of the protocol, not from the source). The source tries to read that timeout but parses it wrongly (it gets NaN) and never uses it. **Recommendation:** honour it by re-handshaking before it expires, or rely on the 403 path below.
5. Check: SHA-256(local_seed || remote_seed || auth_hash) must equal server_hash. If it does not, the credentials are wrong (or the device was set up with another account); the source then fails the handshake (it has no fallback to other credential sets).

Handshake 2:
6. POST `/app/handshake2` with body SHA-256(remote_seed || local_seed || auth_hash) (32 bytes), with the cookie. A 200 response (body expected empty; the source reads it as text and logs it) completes the session.

Session keys (all from the concatenation of an ASCII prefix, local_seed, remote_seed and auth_hash):
- key = first 16 bytes of SHA-256("lsk" || local_seed || remote_seed || auth_hash).
- iv-hash = SHA-256("iv" || local_seed || remote_seed || auth_hash): iv_prefix = its first 12 bytes; initial seq = its last 4 bytes read as a **signed** 32-bit big-endian integer.
- sig = first 28 bytes of SHA-256("ldk" || local_seed || remote_seed || auth_hash).

Request (one per command):
1. seq = seq + 1 (incremented before use; the first request uses initial seq + 1).
2. IV = iv_prefix (12 bytes) || seq as signed 32-bit big-endian (4 bytes).
3. ciphertext = AES-128-CBC(key, IV, PKCS#7 padding) of the UTF-8 JSON text.
4. signature = SHA-256(sig (28 bytes) || seq as 4 bytes signed big-endian || ciphertext).
5. POST `/app/request?seq=<seq>` (seq written in decimal, so it may be negative), body = signature (32 bytes) || ciphertext, with the cookie.
6. Response body: 32-byte signature followed by ciphertext. The source discards the first 32 bytes **without verifying them** and decrypts the rest with the same key and the same IV as the request (same seq). **Recommendation:** verify the signature as SHA-256(sig || seq || ciphertext) and treat a mismatch as a failed request.
7. If a response carries a new `Set-Cookie`, it replaces the saved cookie.

The source would throw if seq passed 2^31 - 1 (it writes it as signed 32-bit). **Recommendation:** wrap within signed 32-bit, or re-handshake.

Concurrency: seq is shared by all requests of a session and requests are not serialised in the source; concurrent requests can reach the device out of order. **Recommendation:** serialise requests per device (one in flight), which also matches how the device's session behaves.

Malformed responses: the source notes that devices sometimes return a decrypted text whose `error_code` is not valid JSON (an example is a value with a leading zero such as `-0301`, or a stray character after the number). It rewrites the text so that `error_code` becomes a quoted string before parsing. Side effect: a bare `{"error_code":0}` (the usual answer to a set request) becomes the string "0". **Recommendation:** parse `error_code` leniently as an integer (accept a leading zero and a string form), and treat 0 as success.

### 4.3 Start-up sequence actually performed by the source

For each device, at start-up:
1. Legacy handshake (4.1 steps 2-4). Its failures are swallowed: an HTTP error or a non-zero `error_code` is logged and the step still "succeeds". On KLAP firmware the device answers `error_code` 1003; the source logs (info) that it will try KLAP.
2. 100 ms later, KLAP handshake (4.2), regardless of the result of step 1 (a "use KLAP" flag starts true and is only cleared when KLAP fails).
3. On KLAP success: the first forced `get_device_info`; on its success the accessory information is set, the characteristic handlers are attached and polling starts (section 5).
4. On KLAP failure: the accessory is marked unreachable, "KLAP Handshake failed" is logged at error level, the KLAP flag is cleared, and **nothing else happens**: no legacy login, no retry, handlers never attached. The accessory stays dead until restart.

Consequently, a device that only speaks securePassthrough fails at step 4 (the KLAP endpoints answer an HTTP error), so in this version the legacy login path is effectively never reached from start-up. If both handshakes had succeeded, the get path would prefer the legacy cipher while the token is still unset (requests to `/app?token=undefined`). **Recommendation:** try KLAP first; fall back to securePassthrough (handshake + `login_device` + token) only when KLAP's handshake1 endpoint is absent (HTTP 404/other error), and retry start-up with backoff instead of giving up.

### 4.4 Methods and JSON shapes

All methods are JSON objects with `method`, optional `params`, and the `requestTimeMils` number described in 4.1. `set_device_info` also carries a `terminalUUID` (a random version-4 UUID generated once per device per process run) **only** for on/off writes; brightness, colour-temperature and colour writes omit it.

| Purpose | method | params |
|---|---|---|
| Read state | `get_device_info` | none |
| On/off | `set_device_info` | `device_on`: true/false (+ top-level `terminalUUID`) |
| Brightness | `set_device_info` | `brightness`: integer |
| Colour temperature | `set_device_info` | `hue`: 0, `saturation`: 0, `color_temp`: kelvin |
| Colour | `set_device_info` | `hue`: integer, `color_temp`: 0, `saturation`: integer |
| P110 energy | `get_energy_usage` | none |
| L530 energy | `get_device_usage` | none |
| Legacy only | `handshake`, `login_device`, `securePassthrough` | see 4.1 |

Response: an object with `error_code` (0 = success) and `result`.

`get_device_info` result fields used: `device_on` (bool), `hw_id` (SerialNumber), `brightness`, `color_temp` (kelvin, 0 in colour mode), `hue`, `saturation` (absent until a colour has been set). Also present and read but unused: `device_id`, `model`, `fw_ver`, `hw_ver`, `mac`, `nickname` (base64), `type` (`SMART.TAPOPLUG` for plugs, `SMART.TAPOBULB` for bulbs).

`get_energy_usage` result fields used: `current_power` (mW), `today_energy` (Wh). Others typically present: `today_runtime`, `month_runtime` (minutes), `month_energy`, `local_time`.

`get_device_usage` result fields used: `power_usage.today` (Wh), `time_usage.today` (minutes). Each of `time_usage`, `power_usage`, `saved_power` has `today`, `past7`, `past30`.

### 4.5 Error codes

The source's table of codes and meanings: 0 success; -1010 invalid public key length; -1012 invalid terminalUUID; -1501 invalid request or credentials; 1002 incorrect request; -1003 JSON formatting error; 9999 session timeout; -1301 device error; 1100 handshake failed; 1111 login failed; 1112 HTTP transport failed; 1200 multiple requests failed; -1004 JSON encode failed; -1005 AES decode failed; -1006 request length error; -2101 account error; -1 common failure; 1000 null transport; 1001 command cancelled; -1001 unspecific; -1002 unknown method; -1007 cloud failed; -1008 bad parameters; -1101 session parameter; -1201 quick setup; -1302 device next event; -1401 firmware; -1402 firmware version; -1601/-1602/-1603 time / system time / time save; -1701 wireless; -1702 wireless unsupported; -1801..-1805 schedule (general, full, conflict, save, index); -1901..-1903 countdown (general, conflict, save); -2001..-2003 anti-theft (general, conflict, save); -2201/-2202 statistics / save; -2301/-2302 daylight saving / save; 1003 "KLAP" (the device wants KLAP).

Handling:
- 1003 (legacy handshake): switch to KLAP, logged at info level, not as an error.
- Any other non-zero code: logged at error level with the code, its meaning and the host; the operation reports failure.
- 9999 on the legacy protocol's get: up to 3 reconnections (legacy handshake then login), then the cached state is returned. The reconnect counter only resets after a different error. (On KLAP, 9999 handling is effectively unreachable.)
- HTTP 403 on KLAP (session expired): the get path starts a background re-handshake and fails this poll; the command path re-handshakes, re-encrypts and retries **once**, and fails if the retry fails. In some paths both a background and a foreground re-handshake run at once. **Recommendation:** one re-handshake per expiry, then one retry, for gets and sets alike.
- KLAP set requests (on/off, brightness, colour) are considered successful when the HTTP exchange and decryption succeed; the inner `error_code` is **not** checked. **Recommendation:** check it.
- KLAP get: a non-zero inner `error_code` makes the get fail.

## 5. Behaviour

### 5.1 State cache and reads

The last `get_device_info` result is cached per device. HomeKit GETs never touch the network: they answer from the cache (On, Brightness, Hue, Saturation, ColorTemperature through the conversion of 3.5). Hue and Saturation read as 0 when absent. A GET with no cached value (or the field undefined) answers with an "unreachable" error. Before the first successful get, no handlers are attached, so HomeKit sees the bridge's stored values.

### 5.2 Writes

- On: sends `set_device_info`; on success the cached `device_on` is updated and HomeKit gets success; on failure HomeKit gets an "unreachable" error.
- Brightness, ColorTemperature, Hue, Saturation: **only sent when the cached state says the device is on**. When it is off, the write is acknowledged as success and nothing is sent (the value is lost). On success the cache is updated. Note: after a colour-temperature write the source stores the HomeKit mireds value into the cached `color_temp` (which normally holds kelvin), so a GET before the next poll reads floor(10^6 / mireds) clamped, which is 400 for normal values. **Recommendation:** store the kelvin value sent.
- Hue and Saturation writes are independent requests, each sending the other component from the cache; HomeKit usually writes both in one go, so two requests go out back to back.
- No debouncing or coalescing of writes exists (the `waitTimeUpdate` option is unused).

### 5.3 Polling

- First poll `updateInterval` seconds (default 10) after the successful start-up get, then every `updateInterval`.
- Each poll does a forced `get_device_info` and pushes On; lights also push Brightness, and the L530 pushes Saturation, Hue, ColorTemperature (converted). A field is pushed only if truthy, so hue 0, saturation 0 and colour temperature 0 are never pushed.
- On failure the On characteristic is set to an error, which HomeKit shows as "No Response". There is no explicit "back online" step: the next successful push of On clears it.
- Backoff in the source: after a failed poll the interval grows by 300 seconds and **never shrinks back**, even after the device recovers; for the plug behaviours a failure yields a period of interval + 5 min from then on, and further failures add 5 min each. The L510E and L520E pollers schedule two follow-up polls per run, so their poll count grows without bound. **Recommendation:** poll every `updateInterval` while reachable; on failure back off (for example up to 5 minutes) and return to `updateInterval` on the first success.
- P110 energy: a `get_energy_usage` at start-up, then every 10 minutes, and additionally on every state poll (the source re-arms a 10-minute timer each time, so timers accumulate; in effect energy is read every poll). On a response with non-zero `current_power`, Current Consumption is pushed and a history entry (time in seconds, power = ceil watts) is added. Total Consumption is never pushed, only served on GET. **Recommendation:** read energy on a separate period (the source's intent is 10 minutes, but per-poll reads work), push both values, and add a history entry each time.
- L530 energy: `get_device_usage` at start-up and every 10 minutes (not on state polls). A history entry is added on each response that has `power_usage`; neither consumption characteristic is pushed, only served on GET from the last values.
- Adaptive Lighting writes arrive as ordinary ColorTemperature writes (subject to the "only when on" rule).

### 5.4 Unreachable and edge cases

- A device that fails the KLAP handshake at start-up stays unreachable for the life of the process (4.3).
- A write handler with no cached state at all would fail (the source dereferences the empty cache). **Recommendation:** treat as unreachable.
- The legacy RSA key pair is generated per device at start-up even when KLAP is used (costly but harmless).
- On re-handshake the source sends the old cookie with handshake1. **Recommendation:** drop the cookie before a new handshake1.
- Cached accessories for removed devices are kept.

## 6. Logging

Paraphrased log lines:
- Info: loading an accessory from cache; restoring an existing accessory; adding a new accessory (with host); "trying KLAP" on code 1003; KLAP re-authentication succeeded; got 403, re-authenticating and retrying.
- Error: KLAP handshake failed; legacy handshake or login failed; the first device-info read failed; non-zero error codes (code, meaning, host); HTTP failures with their message and host; failure to set power, brightness, colour temperature, hue or saturation; failure to read L530 energy.
- Debug: the raw platform config (the source logs the whole block, **password included**, which must not be reproduced), the parsed config (also with the password), each decrypted device response (it contains the MAC, IP, SSID and location of the device), handshake results, each characteristic get/set value, energy readings.

Secrets and sensitive data: `username` (e-mail address), `password`, auth_hash, local/remote seeds, the derived key, IV and sig, the RSA private key, the legacy AES key/IV and token, the `TP_SESSIONID` cookie. Personal data in responses: `mac`, `ip`, `ssid`, `nickname`, `latitude`/`longitude`, `region`. **Recommendation:** never log the config's password, the keys or the cookie; mask the account e-mail.

## 7. Test vectors and fixtures

### 7.1 KLAP derivation (computed by the spec writer from the algorithm above)

Inputs: username `user@example.com`, password `password123`, local_seed = bytes 0x00..0x0f, remote_seed = bytes 0x10..0x1f.

| Value | Hex |
|---|---|
| SHA-1(username) | `63a710569261a24b3766275b7000ce8d7b32e2f7` |
| SHA-1(password) | `cbfdac6008f9cab4083784cbd1874f76618d2a97` |
| auth_hash | `35365bf4467b1b0fa6569d60a5fa0b11ebc3010dc9b6c9018da3c00d9969e404` |
| server_hash expected in handshake1 response (bytes 16-47) | `21f27ccace7cf984d6ed402aa09db27fb98f16573f83e0e71b37e84b8f35d3d5` |
| handshake2 body | `5f307e5b07fa7157e8bf0d9ec5cb2e9fa08c8aca433df2d199b5962ed9859ce6` |
| key | `7ca1d32e916ce872becb13f83af7daa1` |
| full iv-hash | `491492ea81c693c9fde7cb057d6f9b61033c07b3e150e72e9c8ec3a86bc2617d` |
| iv_prefix (12 bytes) | `491492ea81c693c9fde7cb05` |
| initial seq (last 4 bytes, signed) | `1807901053` (0x6bc2617d) |
| sig (28 bytes) | first 28 bytes of SHA-256("ldk" || seeds || auth_hash); verify through the request signature below |

So a handshake1 response fixture is remote_seed followed by that server_hash (48 bytes).

First request: seq = 1807901054, IV = `491492ea81c693c9fde7cb056bc2617e`. Plaintext (66 bytes, the source's style with the trailing semicolon): `{"method": "get_device_info","requestTimeMils": 1700000000000000};`

- ciphertext (80 bytes): `e5fb36aed11b86f799c10cb5d55d2d145248f2438075184783487c9fdd8acc4c488c1c30fce28e17791187cb962e424c22b678d2649afc6682442f4b2e5a1eb8e395ec9dd641276d71d7f756428627d3`
- signature: `f016df10e98536e688bc649677dac545c5ff375cbc875dd4f909d158f117c3c6`
- URL: `/app/request?seq=1807901054`, body = signature || ciphertext (112 bytes).

A fake device for tests can be built from the same algorithm: it verifies handshake2, and answers each request with SHA-256(sig || seq || ct) || ct where ct encrypts the response JSON under the same key and IV.

### 7.2 Legacy encodings

For the same credentials: `login_device` username = `NjNhNzEwNTY5MjYxYTI0YjM3NjYyNzViNzAwMGNlOGQ3YjMyZTJmNw==` (base64 of the 40-character hex digest), password = `cGFzc3dvcmQxMjM=`. RSA and its padding cannot be given as a fixed vector (random key); a fake device encrypts 32 known bytes with the client's public key (PKCS#1 v1.5) and checks that the client then uses bytes 0-15 as key and 16-31 as IV.

### 7.3 Example responses (as data)

`get_device_info` for a plug, inner `result` (values illustrative): `device_id` a 40-hex-character id, `fw_ver` "1.2.1 Build 20200616 Rel. 31218", `hw_ver` "1.20.0", `model` "P100", `type` "SMART.TAPOPLUG", `mac` "AA-BB-CC-DD-EE-FF", `hw_id` 32 hex characters, `fw_id`, `oem_id`, `specs` "EU", `device_on` false, `on_time` 0, `overheated` false, `nickname` base64 (for example `S2l0Y2hlbiBMYW1w` = "Kitchen Lamp"), `location`, `avatar`, `time_usage_today`, `time_usage_past7`, `time_usage_past30`, `longitude`, `latitude`, `has_set_location_info`, `ip`, `ssid` (base64), `signal_level` 2, `rssi` -61, `region` "Europe/Athens", `time_diff` 120, `lang` "en_US".

Bulb (L530) additions: `brightness` 1-100, `color_temp` kelvin (2500-6500, or 0 in colour mode), `hue` 0-360 and `saturation` 0-100 (only after a colour was set), `type` "SMART.TAPOBULB".

`get_energy_usage` (P110): `{"error_code":0,"result":{"today_runtime":120,"month_runtime":3000,"today_energy":250,"month_energy":6000,"current_power":15300}}` gives Current Consumption pushed 15.3, GET 16; Total 0.25 kWh.

`get_device_usage` (L530): `time_usage.today` 120, `power_usage.today` 18 gives total 0.018 kWh and current 18 / 2 = 9 W while on, 0 while off.

Set response: `{"error_code":0}`. Credentials mismatch shows up as a handshake1 server_hash that does not match (KLAP) or `-1501` (legacy login).

### 7.4 Behaviour checks worth testing

- Type selection: `plug`, `PLUG`, absent, unknown -> Outlet; `PowerPlug` -> Outlet with Eve characteristics; `light` -> Lightbulb with Brightness; `colorlight` -> full colour bulb; `WhiteLight` -> per the decision in 3.1.
- Identity: the UUID vectors of 3.2.
- Writes while the cached state is off are acknowledged and not sent.
- Colour-temperature conversions and clamps of 3.5 both ways.
- 403 on a request: one re-handshake, one retry, success.
- Poll failure marks On unreachable; recovery restores the value (and, per the recommendation, the normal interval).

## 8. Gaps and hard parts

- L900 strips (and L520 behaviour) have no reachable code path in the source; L900 support via `Colorlight` is plausible but unverified. Strip-specific features (segments, lighting effects) are absent.
- The `WhiteLight` mapping bug (3.1) forces a compatibility decision.
- The legacy protocol is effectively unreachable at start-up; its correct ordering (KLAP first, fallback) is a recommendation, not observed behaviour. Whether current legacy firmware accepts the trailing semicolon and the microsecond `requestTimeMils` was not verified.
- The KLAP response signature check, the cookie `TIMEOUT` value (86400 s) and the device's tolerance for out-of-order seq come from knowledge of the protocol, not from this source.
- Some firmware (per other Tapo clients) requires a different auth hash for handshake1 (for example blank or default credentials, or the newer "KLAP v2" variant used by some cameras/hubs); the source only supports the one described here.
- The device's response to Brightness 0 is unknown.
- The fakegato history file name and format are the history library's, not this plugin's; the Homeswift implementation should use its own Eve history support with the `energy` type.
- Polling backoff and timer accumulation in the source are bugs; the recommended behaviour differs from what the source literally does.
