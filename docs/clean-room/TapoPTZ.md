# Tapo camera pan/tilt (control API, port 443): functional specification

## 0. Provenance

- [src1] https://github.com/JurajNyiri/pytapo (Python library), commit `088d14fc9873351ab0e1bb86267b57d51451ecb2`
  (2026-10-23). Files read: `pytapo/__init__.py` (constructor and transport choice, `executeFunction`,
  `performRequest`, the motor, preset, patrol, privacy, channel and dual-lens methods, `getMost`), `pytapo/const.py`
  (error table, retry constants), `pytapo/transport/pytapo/pytapo.py` and `const.py` (the encrypt_type 3 login and
  `securePassthrough`), `pytapo/transport/pytapo/TlsAdapter.py`, `pytapo/transport/tpap/tpap.py` and `spake2p.py`
  (the SPAKE2+ "TPAP" login and the CCM channel), `pytapo/media_stream/_utils.py` (nonce helper only),
  `test_pytapo.py` (live-camera tests of the motor and presets), `test_tpap.py` (header only), `README.md`
  (authentication). MIT, "Copyright (c) 2020 Juraj Nyíri".
- [src2] https://github.com/JurajNyiri/HomeAssistant-Tapo-Control (Home Assistant's `tapo_control`), commit
  `6d2c8adb81f3551070ec62fd9590f26254df145a` (2026-10-23). Files read: `custom_components/tapo_control/button.py`
  (move and calibrate buttons), `number.py` (movement angle), `select.py` (patrol mode, move to preset), `switch.py`
  (preset patrol), `camera.py` (preset services, lens channels), `utils.py` (battery detection, capability checks,
  polling of battery cameras), `__init__.py` (battery update interval, `getAllChnInfo`), `const.py`, `services.yaml`,
  `README.md`. Apache-2.0.
- [src3] https://github.com/AlexxIT/go2rtc, `pkg/tapo/`, commit `990f4de3cc21d1cca917d02d0bc40f2fabe75a49`
  (2026-11-05): searched for any pan/tilt use. **None**; go2rtc only speaks port 8800 (see TapoCamera.md). MIT.
- [src4] The Tapo iOS app, `/Applications/Tapo.app` (bundle `com.tplink.tapo`, version 3.22.501, build 32510).
  **Static inspection only**: `strings` of the unencrypted (`cryptid 0`) frameworks `TPCameraNetwork`,
  `TPIoTCloudClient`, `TPLocalAccessHTTPClient`, `TPLocalAccessClientBase`, `TPSpake2Plus`; the resource package
  `TPResourcePackage/.../tapo_device_adaption_res_camera/Localization/en/strings.strings`;
  `tapo_device_adaption_config.json`. The main executable was not read. Only names (request method names, JSON keys,
  Objective-C selector and class names) are used; where I group a key with a method, that is **inferred** from the
  order of the strings in the binary, not seen on the wire. The app was not run; no traffic was captured; no camera
  was contacted. Proprietary (TP-Link).
- [src5] This repository: `docs/clean-room/TapoCamera.md` (sections 1–3, 8, 9, 12: port 8800, the cloud password
  hashes `P_MD5`/`P_SHA256`, standby and deep sleep on the C675D) and `docs/clean-room/TapoCloudEvents.md` section 7
  (which cloud calls wake the camera).
- Downloads were shallow clones into the scratchpad, only read; no reference code was executed. The test vectors in
  section 10 were computed with my own script (Python standard library hashes and HMAC, the `openssl` CLI for AES);
  my HKDF and CCM were first checked against RFC 5869 case 1 and NIST SP 800-38C example 1.
- Written by the spec writer; **contains no source code** from any source. Labels: **[srcN]** shows which source
  says it; **inferred** = my reading, not seen working; **Recommendation** = advice beyond the sources. Every
  credential is a placeholder (`ExamplePassw0rd!`, the same as TapoCamera.md section 13).

## 1. Scope and the short answer

The C675D has two lenses: the **PT Lens** (telephoto, on a pan/tilt motor) and the **Fixed Lens** (wide). The app's
strings describe the two lenses watching at different angles, and the PT lens following a target the fixed lens
detected [src4 strings]. Pan/tilt is commanded over the camera's **control API**, not over Streamd (8800):

- **HTTPS on TCP 443**, self-signed certificate, JSON `POST`s. Log in once (one of two logins, section 3), get a
  `stok` session token, then post to `/stok=<stok>/ds`, every request wrapped as a `multipleRequest`, and encrypted
  (`securePassthrough` AES-CBC for the older login, raw AES-CCM frames for the newer one).
- The user is the literal `admin` and the secret is the **TP-Link cloud password** (battery models have no camera
  account) [src1 README; src5 TapoCamera.md §1]. The same `P_MD5`/`P_SHA256` hashes as port 8800 are used.
- Moves: `motor.move` (relative, x/y), `motor.movestep` (one step towards an angle), `motor.cruise` /
  `motor.cruise_stop` (continuous sweep along one axis), `motor.manual_cali` (calibrate). Presets: `preset.goto_preset`,
  `preset.set_preset`, `preset.remove_preset`, read with `preset.name ["preset"]`. Patrol of presets:
  `patrol.set_patrol_status`. **No request carries a lens or channel**: the motor is the PT lens's.
- Battery cameras answer the control API **only while awake**. Every request keeps (or makes) the camera awake;
  how a sleeping camera reacts to a TCP connect is unknown (it may accept and stay silent). The control API is a
  separate connection from the 8800 live view; sending moves **while a live view is open** is the reliable window
  (the camera is awake, and the user sees the result).
- **No source has driven a battery PT camera's motor.** pytapo's motor tests and tapo_control's buttons are
  written for mains-powered PT cameras (C200 family). Everything below for the C675D is to be confirmed on the camera.

## 2. Transport

- URL base: `https://<host>:443` (pytapo's `controlPort`, default 443) [src1].
- TLS: the camera's certificate is self-signed; pytapo does not verify it and lowers OpenSSL's security level to
  allow every cipher ("ALL" at security level 0) [src1 TlsAdapter]. **Recommendation:** trust on first use (pin the
  certificate seen at Setup, as `HTTPClient`/`TrustOnFirstUse` allow) and allow legacy ciphers only if the handshake
  fails without them.
- Keep-alive: pytapo reuses one HTTP session (connection) for the login and all requests. Request timeout 10 s
  (`CONNECTION_TIMEOUT`) [src1].
- Headers on every request of the encrypt_type 3 path [src1]:

  | Header | Value |
  |---|---|
  | `Host` | `<host>:443` |
  | `Referer` | `https://<host>:443` |
  | `Accept` | `application/json` |
  | `Accept-Encoding` | `gzip, deflate` |
  | `User-Agent` | `Tapo CameraClient Android` |
  | `Connection` | `keep-alive` |
  | `requestByApp` | `true` |
  | `Content-Type` | `application/json; charset=UTF-8` |
  | `Seq` | after login only: the current sequence number, decimal |
  | `Tapo_tag` | after login only: section 3.2 step 5 |

  The TPAP path sends `requestByApp: true`, `Referer`, `User-Agent` as above, and `Content-Type`/`Accept` of
  `application/json` for the login and `application/octet-stream` for `/ds` [src1 tpap].
- The app builds the same URL form, `https://<host>:<port>/stok=<stok>/ds` (also an `http://` variant) [src4
  strings of `IPCTSHTTPTransport`].

## 3. Login

### 3.1 Which login

Both logins are `POST https://<host>:443/` with body `{"method":"login","params":{…}}`. pytapo picks one like this
[src1 `__init__`, `tpap.py`]:

1. **Discover**: `params` = `{"sub_method":"discover"}`.
   - If the reply's `result.tpap.pake` list contains `2` → **TPAP** (3.4). `result.tpap` also carries
     `user_hash_type` (used in 3.4).
   - If the reply has `error_code` `-40413` and `result.data.encrypt_type` contains `"3"` → the **encrypt_type 3**
     login (3.2) is offered.
2. If discover offered neither: send the encrypt_type 3 probe (`{"encrypt_type":"3","username":"admin","cnonce":
   <16 hex>}`). `error_code` `-40211` → TPAP; otherwise encrypt_type 3. pytapo skips this probe when discover
   already offered encrypt_type 3, because **every login-phase request counts towards the camera's lockout**, even
   one without a password [src1 comments].
3. A third path ("KLAP", `http://<host>:443` answering `200 OK`) is for Tapo chimes and hubs, not cameras [src1
   `_isKLAP` and the chime branch]. Not needed.

Which of 3.2/3.4 a C675D on firmware 1.1.7 uses is **unknown**; the app contains both (`loginByTPAP`,
`reAuthenticateForTPAP`, `pake_register`, `pake_share`, `encrypt_type`, `digest_passwd`, `device_confirm`,
`start_seq`, `securePassthrough`, `tapo_tag`) [src4]. TapoCamera.md §9 says tapo-onvif called `getBasicInfo` on
443 against the C675D, so one of them works there. **Recommendation:** implement both, chosen by discover as above.

### 3.2 encrypt_type 3 login ("secure connection") [src1 `pytapo.py`]

Notation: `SHA(x)` = uppercase hex of SHA-256 of the UTF-8 text `x`; `+` = text concatenation. `P` = the password
hash, `P_SHA256` or `P_MD5` (uppercase hex of the cloud password's SHA-256 / MD5, TapoCamera.md §3).

1. Client nonce `cnonce` = 8 random bytes as **16 uppercase hex characters**.
2. Request `params`: `{"cnonce":<cnonce>,"encrypt_type":"3","username":"admin"}`.
3. Reply: `error_code` `-40413` with `result.data.nonce` (camera nonce, text) and `result.data.device_confirm`.
   Check it: `device_confirm` must equal `SHA(cnonce + P + nonce) + nonce + cnonce`. Try `P_SHA256` first, then
   `P_MD5`; the one that matches is the hash for this session. Neither matches → wrong password (pytapo retries the
   whole login once on `-40413`, then gives up).
4. Second request `params`: `{"cnonce":<cnonce>,"encrypt_type":"3","digest_passwd":<D>,"username":"admin"}` with
   `D = SHA(P + cnonce + nonce) + cnonce + nonce`.
   Reply `result`: `stok` (text), `start_seq` (integer), `user_group`. If `user_group` is not `"root"`, pytapo
   refuses the session: its comment says encrypted control through a shared (non-owner) account appears unsupported [src1].
5. Session keys (raw bytes): `K = SHA(cnonce + P + nonce)` (the 64-character text), then
   `lsk = first 16 bytes of SHA-256(bytes of "lsk" + cnonce + nonce + K)`,
   `ivb = first 16 bytes of SHA-256(bytes of "ivb" + cnonce + nonce + K)`.
6. Each request afterwards:
   - Inner JSON: the request (always a `multipleRequest`, section 4).
   - Encrypt the inner JSON's bytes with **AES-128-CBC, key `lsk`, IV `ivb`, PKCS#7**; the IV is **the same for
     every message** (no chaining between messages). Base64 the ciphertext.
   - Body: `{"method":"securePassthrough","params":{"request":"<base64>"}}`.
   - Header `Seq` = the current sequence (first request: `start_seq`); then add 1 for the next request.
   - Header `Tapo_tag` = `SHA( SHA(P + cnonce) + <the exact body text> + <Seq as decimal text> )`. The tag covers the
     exact bytes sent, so serialise the body once and hash and send that same text. (pytapo serialises with spaces
     after `,` and `:`; the TPAP path below uses compact JSON; the camera parses either, **inferred**.)
   - POST to `https://<host>:443/stok=<stok>/ds`.
   - Reply: `{"result":{"response":"<base64>"},"error_code":0}` (other top-level fields possible). Decrypt with the
     same `lsk`/`ivb`; the plaintext is the JSON reply of section 4. A PKCS#7 failure means the session is no longer
     valid: log in again. An HTTP `500` on this path can mean the session is expiring; read the body anyway [src1].
7. Without encrypt_type 3 (older non-battery firmware), pytapo logs in with
   `{"hashed":true,"password":<P_MD5>,"username":<user>}` and sends plain JSON to `/stok=<stok>/ds`. Not expected
   on battery models.

### 3.3 Lockout

- A lockout shows as `result.data` with `time`, `max_time` and `sec_left` > 0, or `data.code` `-40404`
  (DEVICE_BLOCKED) with `data.sec_left` > 0, or (TPAP) `sec_left` under `error_info`, `data` or `result.data`
  [src1]. TapoCamera.md §3 records 10 attempts on the C675D's 443 API.
- `-40411` in an HTTP 401 reply's `result.data.code`: invalid authentication data, stop [src1].
- **Recommendation:** at most one login attempt per hash per minute; on a lockout stop until `sec_left` has passed
  and report a credential problem; never retry a known-bad hash.

### 3.4 TPAP login (SPAKE2+, newer firmware) [src1 `tpap.py`, `spake2p.py`; names confirmed in src4]

Passcodes, in the app's order: `md5hex(cloud password)` (**lowercase** hex, unlike `P_MD5`), then `P_SHA256`
(uppercase). Username: `md5hex("admin")` (lowercase), or `SHA("admin")` if discover's `user_hash_type` is `1`.
All binary fields are standard base64.

1. `pake_register`: `params` = `{"sub_method":"pake_register","username":<u>,"user_random":<base64 of 32 random
   bytes>,"cipher_suites":[1],"encryption":["aes_128_ccm"],"passcode_type":"userpw"}`.
   Reply `result`: `dev_random`, `dev_salt`, `dev_share` (an uncompressed or compressed P-256 point), `iterations`,
   optional `extra_crypt`.
2. Credential from the passcode, by `extra_crypt`:
   - absent: the passcode itself;
   - `type` `password_shadow`, `params.passwd_id` `5`: the SHA-256-crypt string (`$5$`, Drepper's algorithm) of the
     passcode with the salt taken from `params.passwd_prefix` (salt cut to 16 characters; `rounds=N$` honoured,
     clamped to 1000…999999999, default 5000 and then not written in the output); the whole `$5$…$…` text is the
     credential. Seen on a C200 v5, firmware 1.4.6 [src1];
   - `passwd_id` `2`: lowercase hex of SHA-1 of the passcode;
   - anything else: unsupported.
3. SPAKE2+ on P-256 with RFC 9383's M and N points (prover side, empty prover and verifier identities):
   - `PBKDF2-HMAC-SHA256(credential, dev_salt, iterations, 80 bytes)`; `w0` = first 40 bytes as a big-endian
     integer mod n; `w1` = last 40 bytes mod n.
   - Random scalar `x` in 1…n−1; `X = x·G + w0·M`; `Y` = `dev_share`; `Z = x·(Y − w0·N)`; `V = w1·(Y − w0·N)`.
   - `Context = SHA-256("PAKE V1" + raw user_random + raw dev_random)` (bytes).
   - Transcript: each of `Context`, empty, empty, `M`, `N`, `X`, `Y`, `Z`, `V` (points uncompressed, 65 bytes),
     `w0` (32 bytes big-endian), each preceded by its length as 8-byte **little-endian**; `K = SHA-256(transcript)`.
   - `HKDF-SHA256(K, salt = 32 zero bytes, info "ConfirmationKeys", 64)`: first 32 bytes `KcA`, last 32 `KcB`.
     `user_confirm = HMAC-SHA256(KcA, Y uncompressed)`; expected device confirm `= HMAC-SHA256(KcB, X uncompressed)`.
   - `shared = HKDF-SHA256(K, 32 zero bytes, "SharedKey", 32)`.
4. `pake_share`: `params` = `{"sub_method":"pake_share","user_share":<base64 of X uncompressed>,"user_confirm":
   <base64>}`. Reply `result`: `dev_confirm` (compare in constant time), `stok`, `start_seq`, `expired` (seconds;
   3600 when absent, as both pytapo and the app's log text say [src4]).
5. Channel keys: `key = first 16 bytes of HKDF-SHA256(shared, salt "tp-kdf-salt-aes128-key", info
   "tp-kdf-info-aes128-key", 32)`; `base = first 12 bytes of HKDF-SHA256(shared, "tp-kdf-salt-aes128-iv",
   "tp-kdf-info-aes128-iv", 32)`.
6. Each request: `POST https://<host>:443/stok=<stok>/ds`, `Content-Type: application/octet-stream`. Body =
   `seq` as 4-byte big-endian ‖ AES-128-CCM ciphertext ‖ 16-byte tag, with nonce `base[0..7] ‖ seq (4 bytes
   big-endian)`, no associated data; plaintext = the compact JSON `multipleRequest`. `seq` starts at `start_seq` and
   goes up by one per request. The reply has the same layout with its own `seq` (use it for the nonce). A reply
   starting with `{` is a plain-JSON refusal carrying `error_code`. Replies shorter than 20 bytes are errors.
   **Only `multipleRequest` is accepted on this channel** [src1].
7. Session: valid until `expired`; `-40401` or `-40421` (TPAP_SESSION_TOKEN_INVALID) means log in again and resend
   once. A C200 refused the first `pake_share` after a session ended (`-40401`) and accepted the same passcode about
   2 s later, so pytapo retries the passcode that worked before once after 2 s, never the other one [src1].

### 3.5 Session lifetime (both logins)

- encrypt_type 3: no expiry is sent; the session ends when a request gets `-40401` (invalid stok), a retryable code
  (`-1`, `-1001`, `9999`, `-40413`, `-40210`, `-40421`, `1002`, `1112`) or a decryption failure. pytapo then logs in
  again and resends **once**, after 1 s [src1 `const.py`, `MAX_LOGIN_RETRIES = 1`].
- Auth errors that clear the session without a retry: `-1501`, `1111`, `-1005`, `1100`, `1003`, `-40412` [src1].
- **Recommendation:** keep one session per camera while it is awake; drop it when the camera goes to sleep (a
  request times out) and log in afresh on the next wake. A login costs two requests (encrypt_type 3) or two plus a
  discover (TPAP); for a single move on a freshly woken camera that is three round trips before the move.

## 4. Request envelope

Every control call is a `multipleRequest` [src1 `executeFunction`]:

    {"method":"multipleRequest","params":{"requests":[{"method":"<name>","params":{<module>:{<action>:{…}}}}]}}

Reply (decrypted):

    {"result":{"responses":[{"method":"<name>","result":{…},"error_code":0}]},"error_code":0}

- Several calls may go in one `requests` list. Replies may come **in another order** (seen on hubs), so match them
  by `method`, not position [src1 `getMost`].
- Success = top-level `error_code` 0 **and** the entry's `error_code` 0 (absent counts as 0). A failed entry has a
  non-zero `error_code` and possibly `err_msg`.
- The `method` names are echoed back. pytapo names the same body differently from the app (`motorMove` vs the
  app's `relativeMove`, section 5.2) and still gets `error_code` 0 in its live tests, so the camera most likely
  dispatches on the `params` body (**inferred**). **Recommendation:** use the app's names (section 5 tables).
- One legacy shape outside `multipleRequest`: `{"method":"get","motor":{"name":["capability"]}}` (`getMotorCapability`)
  [src1]; its reply carries `motor.capability` (fields not recorded). On TPAP firmware only `multipleRequest`
  works, so wrap it as `{"method":"getMotorCapability","params":{"motor":{"name":["capability"]}}}` (**inferred**).
- Hub children wrap requests in `controlChild` (`childControl.device_id`, `request_data`) [src1]. Not needed for a
  C675D on its own Wi-Fi.

## 5. Pan/tilt methods

### 5.1 Capability: does the camera have a motor?

- tapo_control creates its move and calibrate buttons only when `getPresetConfig` succeeds [src2 `button.py`,
  `check_and_create(…, "getPresets")`]. pytapo calls `getPresetConfig` at start and treats a failure as "no presets".
- Other reads in the app (names only, shapes unknown) [src4]: `getMotorAngleRange` (`get_angle_range` →
  `x_angle_range`, `y_angle_range`), `getMotorFov` (`get_fov` → `h_fov`, `v_fov`, `d_fov`), `getPtzInfo`
  (`get_ptz_info` → `x_curpos`, `y_curpos`, `x_start_angle`, `x_end_angle`, `y_start_angle`, `y_end_angle`),
  `getPtzStatus` (`get_ptz_status` → `status_pan`, `status_tilt`), selectors `isSupportGetPtzLocation`,
  `getPantiltCruiseXNeedTime`, `getPantiltCruiseYNeedTime`, `getPantiltResetNeedTime`. The module key these sit
  under (probably `motor`) is not visible.
- **Recommendation:** at Setup (camera awake), request `getPresetConfig` and `getMotorCapability` in one
  `multipleRequest`; the camera supports pan/tilt if either succeeds. Store the answer; never probe again on a
  battery camera.

### 5.2 Moves

| Purpose | App method name [src4] | pytapo name [src1] | `params` |
|---|---|---|---|
| Relative move | `relativeMove` | `motorMove` | `{"motor":{"move":{"x_coord":"<int>","y_coord":"<int>"}}}` |
| One step towards an angle | `singalMove` (sic) | `relativeMove` | `{"motor":{"movestep":{"direction":"<0…359>"}}}` |
| Continuous sweep on one axis | `cruiseMove` | `cruiseMove` | `{"motor":{"cruise":{"coord":"x"}}}` or `"y"` |
| Stop the sweep | `cruiseStop` | `cruiseStop` | `{"motor":{"cruise_stop":{}}}` |
| Calibrate | `manualCalibrate` | `manualCalibrate` | `{"motor":{"manual_cali":""}}` |
| Absolute move | `absoluteMove` | — | keys `absolute_move`, `position_pan`, `position_tilt` (shape and units unknown) |
| Stop a move | `stopMove` | — | unknown body (the app's strings do not show which keys) |

Notes:

- **Numbers are sent as strings** (`"15"`, `"-15"`, `"90"`) in every pytapo call.
- `move` units and signs: tapo_control's "Movement Angle" (5 to 120, step 5, default 15) feeds its buttons as Up
  `(0, +a)`, Down `(0, −a)`, Right `(+a, 0)`, Left `(−a, 0)` [src2]. So `x_coord` is pan, positive = right;
  `y_coord` is tilt, positive = up; the unit is presented as **degrees** of relative movement. That the camera
  really moves by degrees (and not by its own steps) is not measured. `move` with `0,0` succeeds [src1 test].
  A move beyond the mechanical end answers `-64304` (MOTOR_LOCKED_ROTOR, "maximum pan/tilt range reached")
  [src1 table].
- `movestep` direction: an integer angle `0 <= a < 360`, checked by pytapo before sending (the camera's reaction to
  other values is unknown). pytapo labels 0 "clockwise", 180 "counter-clockwise", 90 "vertical", 270 "horizontal";
  **inferred** meaning: the direction of the step in the image, 0 = right (pan clockwise seen from above), 90 = up,
  180 = left, 270 = down. Step size is the camera's; pytapo's tests wait 5 s after each step.
- `move` and `movestep` are **step moves**: one request, one bounded movement, then the motor stops by itself. There
  is no continuous "move while held" in any source; the nearest is `cruise` (sweeps the whole axis until
  `cruise_stop`; the app tracks `cruiseXNeedTime`/`cruiseYNeedTime` for how long a full sweep takes). tapo_control
  shows cruise as "Patrol Mode: Horizontal / Vertical / off" [src2].
- Motor busy: `-64303` MOTOR_BUSY. pytapo's answer: send `cruise_stop` and retry the original request once [src1
  `executeFunction`]. A move while a previous step is still running is likely to get it too (**inferred**).
- `-40109` ONE_SECOND_REPEAT_REQUEST exists in the table [src1]: **Recommendation:** at most one motor request per
  second; coalesce a burst of moves into one `move` with the summed x/y.
- Calibration: the camera sweeps both axes and returns. The app has the keys `cal_to_resume` and `cali` next to
  `manual_cali` [src4], **inferred** to mean "return to the previous position after calibrating"; pytapo sends an
  empty string. tapo_control marks calibrate (and moves) unavailable while privacy mode is on [src2].
- "Go home" / reset: **no source has a request for it.** The app tracks `getPantiltResetNeedTime`/`pantiltResetEndDate`
  (a reset takes time, so it exists), but no request body is visible. Calibration ends at a reference position.
  **Recommendation:** offer "home" as a user preset (5.3).
- Other motor-related features in the app, names only [src4]: `goto_position` (`gotoPanoramicPosition`, a point on a
  stitched panorama), `start_ptz_follow_pointing`/`modify_ptz_follow_pointing_setting`/`dual_linkage_ptz`/
  `ptzFollowPointingResetTime` (the PT lens follows a point or a target from the fixed lens, then returns after a
  reset time), and the keys `x_destpos`, `y_destpos`, `move_time`, `movetime`, `continous_time` whose method is not
  identifiable. Not needed.

### 5.3 Presets

| Purpose | Method name | `params` | Reply |
|---|---|---|---|
| List | `getPresetConfig` | `{"preset":{"name":["preset"]}}` | `result.preset.preset.id` and `.name`: two parallel lists of strings |
| Go to | `motorMoveToPreset` | `{"preset":{"goto_preset":{"id":"<id>"}}}` | `error_code` |
| Save the current position | `addMotorPostion` (sic, both sources) | `{"preset":{"set_preset":{"name":"<name>","save_ptz":"1"}}}` | `error_code`; re-list to learn the new id |
| Delete | `deletePreset` | `{"preset":{"remove_preset":{"id":["<id>", …]}}}` | `error_code` |

- Ids are strings of digits; position `i` of `id` names position `i` of `name` [src1, src2]. Other fields may exist
  in `preset.preset` (not recorded).
- tapo_control refuses an empty or all-digit preset name (it would be mistaken for an id) [src2 services].
- The app's selector `addMotorPositionWithPresetName:andPresetId:` suggests an optional id when saving (**inferred**).
- Errors: `-64302` preset id not found, `-64321` preset was deleted, `-64305` PRESET_ADD_MOVING (saving while the
  motor moves), `-64306` PRESET_SATURATED (no free slot; the maximum is not recorded) [src1].

### 5.4 Patrol (preset tour)

- `getPatrolAction` `{"patrol":{"get_patrol_action":{}}}` → `result.patrol.patrol.action` [src1, src2].
- `getPatrolSchedule` `{"patrol":{"get_patrol_schedule":{}}}` → `result.patrol.patrol` [src1].
- `setPatrolStatus` `{"patrol":{"set_patrol_status":{"value":"on"}}}` (or `"off"`) [src1]; tapo_control's
  "Preset Patrol Mode" switch [src2].
- The app also has (names only) `addPatrol`/`add_patrol` (`index`, `wait_time`), `editPatrol`/`edit_patrol`,
  `deletePatrol`/`delete_patrol`, `gotoPatrolPoint`/`goto_patrol_point`, `setPatrolSequence`/`set_patrol_sequence`,
  `setPatrolAttr`/`set_patrol_attr`, `get_patrol_attr`, `get_patrol_info`, `get_patrol_status`, `patrolling`,
  `minPatrolStayTime`/`maxPatrolStayTime` [src4].
- **Recommendation:** not for a battery camera: a patrol keeps the motor and the camera running.

### 5.5 Two lenses: selecting the PT lens

- **No motor, preset or patrol request in any source carries a channel, lens or `chn_id`**; pytapo's and the app's
  motor selectors take no channel argument (`motorRelativeMove:`, `motorStepMove:`, `motorCruiseMove:`,
  `moveToPreset:`, `addMotorPositionWithPresetName:andPresetId:`) [src1, src4]. The motor belongs to the PT lens
  only, so requests address it implicitly.
- Per-lens settings (night vision, detection, image) do use channels: a `<section>_chn` object keyed by channel id
  plus a `chn_id` list (e.g. `switch_chn`, `motion_det_chn`) [src1 per-channel helpers; src4 `%@_chn`, `chn_id`,
  selector `initWithMultiRequest:addChnIdAtKey:changeToArrayAtKey:chnCount:`].
- Lens list: `getAllChnInfo` `{"system":{"table":"chn_info"}}` → `result.system.chn_info`, a list of objects with at
  least `chn_id` and `chn_alias` [src1, src2]. The app keeps `ptLensChnInfo` and `fixedLensChnInfo` and the flags
  `isBatteryDualLensCam`, `isMultiLensCam` [src4]. Which `chn_id` is the PT lens on a C675D is not recorded.
- Dual-lens linkage (the PT lens tracking what the fixed lens sees) also moves the motor on its own: `getDualCamLinkage`
  `{"dual_cam_linkage":{"name":"linkage_state"}}`, `setDualCamLinkage` `{"dual_cam_linkage":{"linkage_state":
  {"enabled":"on"|"off","linkage_type":<int>}}}` [src1]. Auto tracking: `setTargetTrackConfig`
  `{"target_track":{"target_track_info":{"enabled":"on"|"off"}}}` [src1]. While either moves the motor, manual moves
  may get `-64303` (**inferred**).
- In the 8800 stream, the PT (tele) lens is the second HEVC video stream in `HD` and the only one in `VGA`
  (TapoCamera.md §7). So the lens that moves is the one the user watches in the tele view.

### 5.6 Privacy mode

`getLensMaskConfig` `{"lens_mask":{"name":["lens_mask_info"]}}` → `lens_mask.lens_mask_info.enabled` `"on"`/`"off"`;
set with `setLensMaskConfig` `{"lens_mask":{"lens_mask_info":{"enabled":"on"}}}` [src1]. While it is on, motor and
preset requests answer `-64324` ("Privacy mode is ON") [src1 table and its live test of `set_preset`].
`-64336` MOTOR_PRIVATE_AREA (a move into a configured private area) also exists [src1].

## 6. Battery cameras

### 6.1 Do they accept local control requests?

- tapo_control treats battery and solar cameras (`basic_info.power` or `power_mode` = `BATTERY` or `SOLAR`) as
  normal control-API devices, polled at most every **600 s** by default (mains: much more often) [src2
  `isBatteryPowered`, `UPDATE_INTERVAL_BATTERY_DEFAULT`]. So battery cameras answer the 443 API. Its supported list
  names C425 and C4xx models, not the C675D; no source shows pan/tilt on a battery model.
- tapo-onvif reached the C675D's 443 API at start (TapoCamera.md §9) and saw a TCP connection to 443 established
  and silent for ~9 min while the camera was in deep sleep and did not answer ping (TapoCamera.md §8).
- **Conclusion:** requests work **while the camera is awake**. Asleep, a request may not be refused but hang.
  **Recommendation:** connect timeout 3 s, request timeout 10 s; treat a timeout as "asleep", not as a credential
  error, and do not count it towards any retry budget that could trigger a login.

### 6.2 Does a request wake a sleeping camera?

- tapo_control's authors avoid requests to battery cameras to let them sleep: bulk thumbnail downloads are skipped
  because they "keep a sleeping camera awake for minutes", and failed media scans are backed off so they do not
  wake the camera on every update [src2 `utils.py` comments]. So each local exchange keeps the camera awake (and
  reaching it implies it was awake or woke up).
- Whether a TCP SYN on Wi-Fi wakes the main processor: **unknown** (same gap as TapoCamera.md §12.2).
- The cloud can wake it: the cloud passthrough/relay calls hold the request while the camera wakes
  (TapoCloudEvents.md §7), and the app has an IoT cloud service `preWakeUp` (`-[ICTCPThing preWakeUp]`,
  `preWakeUpWithDeviceIds:`) next to cloud service names `motorMoveToPreset` and `patrol` [src4 `TPIoTCloudClient`]:
  the app can pre-wake a battery camera, and possibly move it to a preset, through the cloud. Request shapes are
  not visible. **Not recommended** (cloud, battery cost).
- **Recommendation:** send pan/tilt only while a live view is open (section 6.3), so it never wakes the camera on
  its own; reject it otherwise ("camera asleep, open the live view").

### 6.3 Control while a live view (8800) is open

- The control API and Streamd are separate TCP connections on separate ports; pytapo opens them independently and
  tapo_control's move buttons and direct streams coexist [src1, src2]. No source reports a conflict.
- Limits that could bite: `-52419` TOO_MANY_HTTPS_CLIENT, `-52405` TOO_MANY_REQUEST [src1 table]; the app has an
  "operation conflict" middleware in its transport (`IPCTSOperationConflictTransportMiddleware`) [src4], meaning
  some operations are serialised; which, unknown.
- The stream keeps the camera awake, and standby every ~10 min (TapoCamera.md §8) ends both; after a standby
  reconnect, the control session's `stok` may have to be renewed (**inferred**: treat `-40401` as usual).
- **Recommendation:** open the control session lazily on the first move after a live view starts (or right after
  Setup), keep it for the life of the live view, and close it with the stream.

## 7. Errors

| Code | Meaning [src1 table unless noted] | Action |
|---|---|---|
| `0` | success | — |
| `-40401` | invalid stok (session expired) | log in again, resend once |
| `-40421` | TPAP session token invalid | same |
| `-40413` | INVALID_NONCE; also the normal first reply of the encrypt_type 3 login | login step / retry once |
| `-40211` | MISSING_NECESSARY_PARAMS; the encrypt_type 3 login refused → firmware wants TPAP | switch to TPAP |
| `-40209` | invalid login credentials | stop; credential error |
| `-40411` | (in a 401 body) invalid authentication data | stop |
| `-40404` | DEVICE_BLOCKED (lockout, with `sec_left`) | wait `sec_left` |
| `-40412` | HOMEKIT_LOGIN_FAIL | clear session |
| `-40105`, `-40210`, `-40106` | method does not exist / METHOD_DO_NOT_EXIST / UNSUPPORTED_METHOD | feature unsupported: hide it |
| `-40101` | parameter to set does not exist | feature unsupported |
| `-40109` | ONE_SECOND_REPEAT_REQUEST | slow down (≥ 1 s) |
| `-64302` | preset id not found | re-list presets |
| `-64321` | preset was deleted | re-list presets |
| `-64303` | MOTOR_BUSY | `cruise_stop`, retry once [src1] |
| `-64304` | MOTOR_LOCKED_ROTOR: end of the pan/tilt range | report "limit reached", not a failure |
| `-64305` | PRESET_ADD_MOVING | retry after the move |
| `-64306` | PRESET_SATURATED | report "no free preset" |
| `-64324` | privacy mode on | report; do not turn privacy off unasked |
| `-64336` | MOTOR_PRIVATE_AREA | report |
| `-52405`, `-52419` | too many requests / HTTPS clients | back off |
| `-1`, `-1001`, `9999`, `1002`, `1112` | generic / session timeout / transport | retry once after a new login |
| `-90404` | CAMERA_UPDATE_LOW_ENERGY | (firmware update refused on low battery; not PTZ) |

"Out of range" for `movestep` is checked locally by pytapo (0…359); the camera's own code for it is unknown.

## 8. What the sources do not cover for the C675D

- The `chn_id` of each lens, and confirmation that motor requests need none.
- Which login firmware 1.1.7 uses (encrypt_type 3 or TPAP).
- The move unit (degrees vs motor steps), the step size of `movestep`, the pan/tilt ranges, and how long a move
  keeps the camera awake.
- Absolute position read-back (`get_ptz_info`, `get_ptz_status`) and absolute moves: names only.

## 9. HomeKit mapping (Recommendation)

HomeKit has no pan/tilt characteristic for cameras. Options, all optional:

- One stateless **Switch** per preset ("Tele: Gate"), turning itself off after `goto_preset` answers; the
  simplest and most useful.
- Four stateless switches for left/right/up/down `move` by a configured angle (tapo_control's default 15°).
- Expose them only on the tele lens's accessory (the C675D's `-tele` part, CLAUDE.md's serial rule) and only when
  5.1 found a motor. While the camera is asleep (no live view), answer the switch with an error (`-70402`
  communication failure) rather than waking it.

## 10. Test vectors (computed by me; inputs invented)

Cloud password `ExamplePassw0rd!`; `P_SHA256 = D23E8AD06AA8C81F7A6FC25A66922E4CFE2D3BDF6AC227C166F1EEC354E41767`,
`P_MD5 = FD344607B3AAFF7BB5FE20B9B04149FD` (as in TapoCamera.md §13).

### 10.1 encrypt_type 3 login (SHA-256 hash)

Inputs: `cnonce = 0A1B2C3D4E5F6071`, camera `nonce = 9F8E7D6C5B4A39281706F5E4D3C2B1A0`.

- Expected `device_confirm`:
  `CC07490418AB3419BC8992A916C1F7E9180C80AAEC9BFB974988A0EAEF4FD3B09F8E7D6C5B4A39281706F5E4D3C2B1A00A1B2C3D4E5F6071`
- `digest_passwd`:
  `4A8969D3F6F04C8138348CD24ED0DE214DF3A6CA841F851A5A1B93742299C69A0A1B2C3D4E5F60719F8E7D6C5B4A39281706F5E4D3C2B1A0`
- `lsk = f40098bd0c28266869060621fabe3245`, `ivb = f5eee14d9ff746f8158d655aeefaef92`
- `SHA(P + cnonce) = 422619D87FEC17F74A87F5162C04C504EA9F1C3B3DD274CC2F9B44F104AB53EF`

Request: inner JSON (129 bytes, compact, no trailing newline)

    {"method":"multipleRequest","params":{"requests":[{"method":"relativeMove","params":{"motor":{"movestep":{"direction":"90"}}}}]}}

AES-128-CBC(`lsk`, `ivb`, PKCS#7), base64 →
`+bNQfuzri7odbg9ELj5lqf/AxG7lNM2FQsP6mbZ5vKmqbT5X1+ROuzae8KBTh0ncNSz7NHNQF7FyGESKFMcptIcGQW14iRjotC1xJODBd403f7IBsSn7Oxt7oluog//YUDtADhmfjNyeNISNYx6vkhAKG3fR+0hOoYDfkkA/zRGshmHQ6O65A48K0D6DYbla`

Body (exact text): `{"method":"securePassthrough","params":{"request":"<the base64 above>"}}`; with `Seq: 1234`,
`Tapo_tag: 7EBE9D5E8C2A129CEAE3DEDEA0120CD5B3A147857C61219DA655C515E48A7A4D`.

Reply: plaintext `{"result":{"responses":[{"method":"relativeMove","result":{},"error_code":0}]},"error_code":0}`
encrypts (same key, same IV) to base64
`QUZT0A9a+UgKGef57O+LdN6g/YHHwZCNxKygwtheEa7FhaUmboQlWD0nU48/xkHuRvbBbFhwDROWaEUU7GNnp3zjoHEnPHWxD8JWVpi04ad1ZqIZz8ixzzaGsp99/lVF`;
a client given `{"result":{"response":"<that>"},"error_code":0}` must decode the move's success.

### 10.2 TPAP

- Usernames: `md5hex("admin") = 21232f297a57a5a743894a0e4a801fc3`,
  `SHA("admin") = 8C6976E5B5410415BDE908BD4DEE15DFB167A9C873FC4BB8A81F6F2AB448A918`.
- Passcodes: `fd344607b3aaff7bb5fe20b9b04149fd` (lowercase MD5), then `P_SHA256`.
- Channel keys from `shared = 000102…1f` (32 bytes 0x00 to 0x1f): `key = 1f477a8c3d031511dcfd57aa01895887`,
  `base = 4240c38bb08a77faaae56105`.
- `seq = 7` → nonce `4240c38bb08a77fa00000007`. Plaintext (121 bytes)
  `{"method":"multipleRequest","params":{"requests":[{"method":"getPresetConfig","params":{"preset":{"name":["preset"]}}}]}}`
  → body (141 bytes, hex):
  `0000000785af1fe952689a2387b5adbfd7633834eb6e18c2ce28dc7498d267743ccb061014be4705dd475b7ed612d8ec39fd3dbb5d89e2a63d87dd4567e12da47057730e94816a76ab5e4f97ba9c0f148f873e95d915bdc43a0a11f29cb0e338098a58c517d9ad41d142441ed6fe2bd5db3688986c78abfb8349deed87b42b02ca8dd3e2dbae583f01661e2698`
  (4 bytes seq, 121 ciphertext, 16 tag). Changing any ciphertext byte must fail authentication.
- SHA-256-crypt: use the published test vectors of Drepper's specification (e.g. key `Hello world!`, salt
  `saltstring`, default rounds), with the `$5$` prefix handling of 3.4 step 2.
- The SPAKE2+ exchange itself: test against a fake camera playing the verifier side (pytapo does the same in its
  offline tests [src1 `test_tpap.py` header]); the P-256 arithmetic can be checked against RFC 9383's vectors with
  their identities and context swapped for this protocol's (empty identities, `"PAKE V1"` context hash).

### 10.3 Request bodies (data)

- Up by 15: `{"method":"relativeMove","params":{"motor":{"move":{"x_coord":"0","y_coord":"15"}}}}`
- Left by 30: `{"method":"relativeMove","params":{"motor":{"move":{"x_coord":"-30","y_coord":"0"}}}}`
- Go to preset 2: `{"method":"motorMoveToPreset","params":{"preset":{"goto_preset":{"id":"2"}}}}`
- Save "Gate": `{"method":"addMotorPostion","params":{"preset":{"set_preset":{"name":"Gate","save_ptz":"1"}}}}`
- Presets reply example (invented values): `{"preset":{"preset":{"id":["1","2"],"name":["Gate","Drive"]}}}` →
  `{1: Gate, 2: Drive}`.

## 11. Gaps

1. No source has moved a **battery** PT camera, and none mentions the C675D's PT lens over the local API.
2. Which login the C675D (firmware 1.1.7) offers; whether its encrypt_type 3 login, if any, accepts `admin` + cloud
   password with `user_group` `root`.
3. Lens `chn_id`s; confirmation that motor requests need no channel on a two-lens camera.
4. Units of `move` (degrees per tapo_control's labels, unmeasured), `movestep`'s step size and angle convention,
   ranges (`get_angle_range` shape unknown), whether `move` is clamped or refused at the end (`-64304`).
5. Bodies of stop (`stopMove`), absolute move (`absolute_move`), position read (`get_ptz_info`, `get_ptz_status`),
   home/reset: names only.
6. Whether a TCP connection to 443 wakes a sleeping camera; how long a move keeps it awake; the battery cost.
7. Whether the `method` name matters (pytapo's names differ from the app's and work on mains cameras).
8. Whether the control session survives the stream's ~10 min standby.
9. The preset limit, and whether `set_preset` accepts an explicit id.

## 12. Recommendations (summary)

- Implement the control client once for all Tapo cameras: discover → encrypt_type 3 or TPAP; `multipleRequest`
  only; one session per awake camera; one relogin-and-resend on session errors; stop on lockout.
- Pan/tilt for battery cameras only while a live view is open; never wake a camera for a move; short timeouts,
  timeouts mean "asleep".
- Use step moves (`move` with a configurable angle, default 15) and presets (`goto_preset`); skip cruise and patrol
  on battery cameras. At most one motor request per second; on `-64303` stop cruise and retry once.
- Detect the motor once at Setup (`getPresetConfig` / `getMotorCapability`), store it, and expose controls only on
  the tele lens's accessory.
- Never log the cloud password, either hash, `cnonce`, the camera `nonce`, `device_confirm`, `digest_passwd`,
  `stok`, `lsk`/`ivb`, `Tapo_tag`, the SPAKE2+ values or the TPAP key and nonce (CLAUDE.md: sizes only).
- First check on the user's C675D (awake, during a live view): discover reply, login type, `getAllChnInfo`,
  `getPresetConfig`, `getMotorCapability`, then one `move` of `x=15` and back.
