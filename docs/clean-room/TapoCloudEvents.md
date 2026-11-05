# Tapo cloud: motion and person events for battery cameras: functional specification

## 0. Provenance

- Source 1: the Tapo iOS app installed on the coordinator's Mac, `/Applications/Tapo.app` (bundle `com.tplink.tapo`,
  version 3.22.501, build 32510). **Static inspection only**: `Info.plist`, `GoogleService-Info.plist`, `json/`,
  `sdk_config*.json`, `en.lproj/*.strings`, the entitlements, and `strings` on the embedded frameworks
  (`TPAppCloudNetwork`, `TPIoTCloudClient`, `TPCareCloudClient`, `TPAPPServiceURL`, `TPCVMClient`, `TPMQTTClient`,
  `TPIPCNotificationCenter`, `IotSwiftSDK`) and the app extensions (`TapoNotificationService`, the widgets). The main
  executable and the notification-service extension are FairPlay encrypted (`cryptid 1`), so their code and most of
  their strings are not visible; the frameworks are not encrypted. The app was not run, attached to or modified; no
  user data, container, keychain or cache was read. Proprietary (TP-Link); only names, paths and constants are used.
- Source 2: https://github.com/dimme/tapo-cli, `tapo-cli.py` and `README.md`, commit
  `8bb5f6d2f231cec55d43465f3169ac58f3d4c219` (2026-08-29). **No licence file**; header line "Copyright Dimme 2023".
  Read for facts only.
- Source 3: https://github.com/piekstra/tplink-cloud-api, `tplinkcloud/signing.py`, `client.py`, commit
  `ca49b19f003cab8e09c071e791d4d4eb7edbcfb4` (2026-11-04). GPL-3.0-only; author "Dev Piekstra" (`pyproject.toml`).
- Source 4: https://github.com/piekstra/tplink-cloud-cli, `docs/api.md`, commit
  `d09505cc256964bfc242083a26e34118f1197054` (2026-11-04). GPL-3.0; same author.
- Source 5: https://github.com/TA2k/ioBroker.tapo, `src/main.ts`, `src/lib/utils/camera/doorbellMonitor.ts`,
  `README.md`, commit `5e67c5a43557b07500a6b742bde8e8c55497617b` (2026-10-03). MIT, "Copyright (c) 2024-2030 TA2k".
- Source 6: https://github.com/igoriok/tapo-tools, `tapo/tapo-care-client.go`, `tapo/tapo-care-data.go`,
  `cmd/download.go`, commit `8d62e018d1010f97d197d23d7c2c92399dcd7d5e` (2024-04-22). **No licence file.**
- Source 7: https://github.com/kandotrun/tapo-care-backup, `src/tapo_care_backup/{api,region,monitor}.py`, `README.md`,
  commit `e815b8d63fe72085e31a9f25017d5f7fc058ac8f` (2026-07-05). MIT, "Copyright (c) 2026 Kan Ninomiya".
- Source 8: https://github.com/stoyanov-x/tapo-things-api-hub-research, `docs/cloud-thing-api.md`, commit
  `a91bf5aa03f508667b89c62e2640259b2557d045` (2026-08-13). **No licence file.**
- Source 9: https://github.com/FlyzDev/tapo-s200b-h200-homeassistant, `custom_components/tapo_s200b_cloud/cloud.py`,
  `const.py`, `README.md`, commit `9b6be9bc3c276356ac6d35f5328e7017c2712924` (2026-10-20). MIT,
  "Copyright (c) 2026 FlyzDev".
- Source 10: `docs/clean-room/TapoCamera.md` sections 9 and 12 (this repository), and Homeswift's own
  `Sources/HomeswiftNetwork/FCMReceiver.swift` doc comments (what the receiver needs).
- Source 11: https://github.com/python-kasa/python-kasa, `kasa/discover.py` and `kasa/transports/aestransport.py`,
  commit `9478ed25ac9fc72ddafcbdf6bd1f9328e8632df4`. GPL-3.0. Read for the UDP discovery (TDP) wire shape only.
- Source 12: https://github.com/JurajNyiri/HomeAssistant-Tapo-Control, `custom_components/tapo_control/manifest.json`,
  commit `6d2c8adb81f3551070ec62fd9590f26254df145a`. Apache-2.0. Read for how it finds cameras (DHCP host names).
- Section 4.4 also used, from Source 1: the Objective-C class metadata (class and instance-variable **names** only,
  `otool -oV`) and `strings` of `TPIoTCloudClient`, `TPCameraNetwork`, `TPTDPNetwork`, `IotSwiftSDK` (all
  `cryptid 0`), and the app's entitlements (`com.apple.developer.networking.multicast`). No code was disassembled.
- Downloads were fetched as tarballs into the scratchpad and only read; nothing was executed. No request was sent to
  any TP-Link server while writing this. Every account value below is a placeholder (`owner@example.com`,
  `ExamplePassw0rd!`, `00000000-…`).
- Written by the spec writer; **contains no source code** from any source. Wire shapes and constants are described in
  my own words. Labels: **[app]** seen in the iOS app's strings; **[srcN]** shown by source N; **inferred** = my
  reading of string adjacency, not seen working; **Recommendation** = advice beyond the sources.

## 1. Scope and the short answer

A Tapo battery camera (C675D) sleeps; its PIR (and, on some models, radar) wakes it, it records, and it reports the
detection to TP-Link's cloud, which (a) pushes a notification to the owner's phones and (b) stores an entry in two
cloud lists: the **message centre** (the app's notification inbox) and the **Activity** list of the camera. Reading
either list is a cloud call and never reaches the camera.

There are three cloud routes, in order of confidence:

| Route | What | Confidence | Latency |
|---|---|---|---|
| A. Message centre poll | `POST {regional}/api/v2/common/getAppNotificationByPage` (signed) | Seen working in [src2]; method name in [app] | poll interval + cloud lag (seconds) |
| B. Activity list poll | `POST {care}/v2/activities/listActivities` (or `/v1/activities/listActivitiesByDate`) | `listActivitiesByDate` seen working in [src6]; v2 fields in [app] | same |
| C. Push | register an FCM token with `postPushInfo` (Android form) and receive with Homeswift's `FCMReceiver` | Registration method and fields in [app]; **no source shows a third party doing it** | ~1–3 s (typical push) |

A fourth, local and unverified, is in section 9 (UDP 20005).

## 2. Hosts and region

| Purpose | Host | Notes |
|---|---|---|
| Global entry, signed v2 account/common API (Tapo) | `https://n-wap-gw.i.tplinkcloud.com` [app], `https://n-wap-gw.tplinkcloud.com` [src2, src5, src7], `https://n-wap.i.tplinkcloud.com` [src3] | The entry redirects to a **regional** host. |
| Regional v2 host | `appServerUrl` from the login / account-status answer, e.g. `https://n-euw1-wap-gw.tplinkcloud.com`, `https://n-use1-wap-gw.tplinkcloud.com` | Region codes seen: `euw1`, `use1`, `aps1`. |
| Legacy (v1) login | `https://eu-wap.tplinkcloud.com/`, `https://wap.tplinkcloud.com/` | JSON-RPC body, **no signature** [src7, src8, src9]. |
| NBU app server ("things") | service `nbu.iot-app-server.app-v2` → e.g. `https://use1-app-server.iot.i.tplinknbu.com` (also seen on `…iot.i.tplinkcloud.com`) | Resolved per account (section 3.5). |
| NBU cloud gateway (MQTT over WebSocket) | service `nbu.iot-cloud-gateway.app-v2` → e.g. `wss://use1-app-cloudgateway.iot.i.tplinkcloud.com` [src8] | Section 6.3. |
| NBU security (JWT) | service `nbu.iot-security.appdevice-v2` → e.g. `https://use1-security.iot.i.tplinkcloud.com` [src8] | |
| Tapo Care / activities / cloud videos | `https://{region}-app-tapo-care.i.tplinknbu.com` [src2, src6, src7] | Region taken from `appServerUrl`; [src2] parses `n-<region>-wap` from it; default `euw1` (EU) or `aps1` (APAC) in those tools. |
| Other service ids in the app [app] | `nbu.cvm-server-v2`, `nbu.config-service-v2`, `nbu.data-report-tp`, `nbu.payment-center-v2.i.prd`, `cipc.api.cloud`, `cipc.stun`, `nbu.ai-assistant-api-v2` | Not needed here. The Tapo Care host's own service id was not found in the visible strings. |

TLS: [src2, src5, src6, src7] disable certificate verification ("expired certs"); [src4] pins a TP-Link chain as an
extra root. The app bundles TP-Link root CAs (`tp-link-root-CA.der`, `tp-link-root-CA-new.der`, …) [app].
**Recommendation:** use the system trust store, and on failure add the TP-Link roots as extra anchors (Homeswift's
`TLSOptions`); never disable verification.

## 3. Login

### 3.1 Request signing (v2 API on the `n-wap…` hosts)

Every POST to `/api/v2/account/*` and `/api/v2/common/*` carries:

- `Content-MD5`: Base64 of the MD5 digest of the **exact body bytes**.
- `X-Authorization`: `Timestamp=<ts>, Nonce=<nonce>, AccessKey=<ak>, Signature=<sig>` (format string also in [app]).
  - `<sig>` = lowercase hex of HMAC-SHA1, key = the app's secret (ASCII bytes of the 32-hex string), message =
    `<Content-MD5 value>` LF `<ts>` LF `<nonce>` LF `<URL path without query>` (e.g. `/api/v2/account/login`).
  - `<ts>`: the app's literal `9999999999` (present beside the format string in [app]; used by [src3, src4, src5]);
    the current Unix time in seconds also works [src2, src9].
  - `<nonce>`: any UUID string.
- `Content-Type: application/json;charset=UTF-8`.

App-level key pairs (they identify the app build, not the user):

| Pair | AccessKey | Secret | Where |
|---|---|---|---|
| Tapo Android | `4d11b6b9d5ea4d19a829adbb9714b057` | `6ed7d97f3e73467f8a5bab90b577ba4c` | [src2, src3, src5, src9]; [src5] uses it with `appName=TP-Link_Tapo_iOS` too |
| Tapo iOS (candidate) | `ea2097d4baf448238040d50cc02da4e4` / `ec4872cff3e84ab9accd4a3580513cb2` | (which is which unverified) | [app] the two 32-hex constants listed beside `n-wap-gw.i.tplinkcloud.com`, `account-api.i.tplinkcloud.com` and the `nbu.*` service ids in the widget extensions' strings |

Errors for a wrong pair: `-10301` / `-10304` [src8]. **Recommendation:** use the Android pair (documented by four
independent projects); keep both as constants and fall back on `-1030x`.

Query string sent with every v2 request (names in [app]: `appName`, `termID`, `ospf`, `appVer`, `netType`, `brand`,
`model`, `termName`, `termMeta`, and `token` once logged in, as `?token=<t>&…`):
`appName=TP-Link_Tapo_Android&appVer=3.20.753&netType=wifi&termID=<terminal UUID>&ospf=Android%2014&brand=TPLINK&locale=en_US&model=<any>&termName=<any>&termMeta=<any>`.
[src2] sends only `token`; [src5] sends all.

### 3.2 Step 1 (optional): account region

`POST {entry}/api/v2/account/getAccountStatusAndUrl` body `{"appType":"TP-Link_Tapo_Android","cloudUserName":"owner@example.com"}`
→ `result.appServerUrl` [src3, src4]. Name also in [app] (with a `…WithCaptcha` variant). Alternative [src2]: log in at
the entry; error `-20212` ("Incorrect service entry address") carries `appServerUrl`, retry there.

### 3.3 Step 2: login

`POST {regional}/api/v2/account/login`, signed:

```json
{"appType":"TP-Link_Tapo_Android","appVersion":"3.20.753","cloudUserName":"owner@example.com",
 "cloudPassword":"ExamplePassw0rd!","terminalUUID":"0123456789ABCDEF0123456789ABCDEF",
 "terminalName":"Homeswift","terminalMeta":"1","platform":"Android 14","refreshTokenNeeded":true}
```

- `terminalUUID`: generated once per installation and **kept**: trusted-terminal binding and MFA codes are tied to it
  [src4]. Upper-case hex without dashes [src2, src7] or a UUID [src3, src5] both accepted.
- Answer: envelope `{"error_code":0,"result":{…}}`; `result` has `token`, `refreshToken` (when asked), `accountId`,
  `regionCode`, `appServerUrl`, `nickname`, `email`. **Trap:** `error_code` 0 with the failure inside `result` as
  `errorCode` (string or int) and a localised `errorMsg` [src2, src4]: check both levels, never the message text.

### 3.4 MFA

- Login answers (inside `result`) `MFAProcessId`, `supportedMFATypes` (1 = push to an already trusted app, 2 = email)
  [src2]; or `error_code -20677` with `mfaType` [src3, src4].
- Ask for the code: `POST {regional}/api/v2/account/getEmailVC4TerminalMFA` (type 2) or `getPushVC4TerminalMFA`
  (type 1), body `{"appType","cloudUserName","cloudPassword","terminalUUID","locale":"en_US"}` [src2, src5; names in app].
  A new terminal is trusted by nothing, so use email (2).
- Finish: `POST {regional}/api/v2/account/checkMFACodeAndLogin` body
  `{"appType","cloudUserName","code":"123456","MFAProcessId":"<from login>","MFAType":2,"terminalBindEnabled":true}`
  → same token result [src2, src5]. `terminalBindEnabled: true` makes this terminal trusted, so later logins with the
  same `terminalUUID` skip MFA (inferred from the field name and [app]'s `trustCandidateTerminalList`,
  `getTerminalInfoListByPage`).
- **Recommendation:** model it as Homeswift Setup's `accountAuthorization` with a code prompt; persist
  `terminalUUID`, `token`, `refreshToken` with `context.secretFile`.

### 3.5 Token lifetime, refresh, lockout

| Code | Meaning [src3, src4] |
|---|---|
| `-20601` | wrong e-mail or password |
| `-20675` | account locked (too many attempts); [app] has `lockedMinutes`, `remainAttempts`, `failedAttempts`, `riskDetected` fields |
| `-20677` | MFA required |
| `-20651` | token expired |
| `-20655` | refresh token expired: full login |
| `-20104` | malformed request |
| `-20212` | wrong regional entry; use `appServerUrl` |

- Refresh: `POST {regional}/api/v2/account/refreshToken` body `{"appType","refreshToken","terminalUUID"}` → new
  `token` (maybe a new `refreshToken`) [src3, src4]. The token's lifetime is not stated by any source; refresh on
  `-20651` (v2) or HTTP 401/403 (NBU / Care hosts), once, then retry.
- The NBU security JWT (`POST {security}/v2/auth/app` body `{"appType","terminalUUID","token":"ut|<token>"}`) lives
  `jwtExpiresIn: 86400` s [src8]; not needed for the routes below.
- No source states a request rate limit. **Recommendation:** never retry a rejected login automatically (`-20601`,
  `-20675`, `-20677` stop and surface a Setup prompt, as [src9] does); back off exponentially on HTTP 429/5xx.

### 3.6 Legacy login (fallback)

`POST https://eu-wap.tplinkcloud.com/` body `{"method":"login","params":{"appType":"Tapo_Android","cloudUserName":…,
"cloudPassword":…,"terminalUUID":…}}`, unsigned → `result.token` [src7, src8, src9]. Such a token is accepted by the
NBU hosts as `ut|<token>` [src8, src9]. Whether it works for an MFA-protected account is not shown. Prefer 3.3.

## 4. Devices

### 4.1 v2 list (signed)

`POST {regional}/api/v2/common/getDeviceListByPage?token=<t>` body
`{"deviceTypeList":["SMART.IPCAMERA"],"index":0,"limit":20}` → `result.deviceList[]`, each with at least `deviceId`
(40 hex, the cloud id), `alias` (**Base64** of the name for Tapo devices [src4]), `deviceModel` (e.g. `C675D`),
`deviceType` (`SMART.IPCAMERA`; doorbells `SMART.TAPODOORBELL`), `deviceMac`, `status` (1 = online in the cloud's
registry), `appServerUrl`, `fwVer`, `deviceHwVer`, `role` [src2, src4, src5]. Page with `index`/`limit` until fewer
than `limit` come back. Method names `getDeviceList`, `getDeviceListByPage`, `getDeviceInfo` in [app].

### 4.2 NBU list

`GET {appServer}/v2/things?page=0&pageSize=100&includePcDevice=true&includeMatterDevice=true` with the NBU headers
(section 5.1) → `{"page","pageSize","total","data":[{thingName (= deviceId), nickname (Base64), model, deviceType,
category, status, mac, appServerUrlV2, isSubThing, …}]}` [src4, src8, src9].

### 4.3 Finding the camera

- By **MAC**: compare `deviceMac` / `mac` after stripping separators and upper-casing (seen as `105A952FAD17`
  [src4]); the camera's MAC comes from Homeswift's `ARPTable` after a Streamd connection or from Setup.
- By **device id**: `deviceId` = `thingName`.
- By **IP**: the cloud **lists** hold no LAN IP; the per-device details call does (4.4). [src5] asks the device for it
  through passthrough, which **wakes the camera** (section 7). Do not.
- **Recommendation:** at Setup, list `SMART.IPCAMERA` devices, match the MAC (or let the user pick by decoded alias
  and model), and store `deviceId` in the Accessory Settings.

### 4.4 The camera's LAN address

Where the app's Device Info page can get the "IP Address" of a C675D from. The page's own code is in the encrypted
main executable, so which route it takes is not visible; what is visible is every route the frameworks offer.

**Route 1: cloud device details (no wake).** `GET {appServerUrlV2}/v1/things/{thingName}/details` (the device's
`appServerUrlV2` from the `/v2/things` list (4.2), on the user's account `https://n-euw1-wap-gw.i.tplinkcloud.com`; the
v1 `appServerUrl` host answers 404 for this path [coordinator, live account]; NBU headers of 5.1; `thingName` =
`deviceId`) [app: path string and the method name `getDeviceDetail` in
`TPIoTCloudClient`]. Its response model is the **only** cloud model in the app with an IP: its fields are `ip`, `mac`,
`ssid`, `model`, `deviceType`, `category`, `role`, `fwVer`, `fwId`, `hwId`, `hwVersion`, `oemId`, `onboardingTime`,
`position`, `shellColor`, `slotNumber`, plus Matter fields (`matterIoTNodeId`, `matterNodeLabel`, `matterProductName`,
`matterVendorName`) [app: instance-variable names]. The JSON key is **inferred** to be `ip` (the app's JSON mappers
use the property name unless mapped; not seen on the wire). Expected value: the address the camera reported to the
cloud when it last connected (dotted IPv4 string), so it can be stale after a DHCP change while the camera keeps its
cloud session. The call reads the cloud registry and does **not** reach the camera (section 7). Whether it is filled
for battery cameras: **unverified**. Confidence: medium (endpoint and field name from the app; no source shows a
third party using it).

**TLS for the `*.i.tplinkcloud.com` hosts.** Their chain is leaf `*.i.tplinkcloud.com` <- "TP-Link Cloud Server CA"
(O=TP-Link Systems Inc., valid 2025-02-25 to 2040-02-22) <- "TP-Link Cloud Root CA". The server does not send the
root, it is in no system store, and its AIA names only a CRL [coordinator, live account]. The root is bundled in the
app as `tp-link-root-CA-new.der` (main bundle and each widget/intent extension) and, the same certificate in PEM, as
`Frameworks/IotSwiftSDK.framework/tp-link-root-CA.pem` [app]. Checked: `openssl verify -CAfile <this root>
<the intermediate>` answers OK (OpenSSL 4.1.0, no partial chain). Add it as an extra trust anchor for these hosts
(Homeswift's `TLSOptions`), next to the system store.
- Subject = Issuer: `CN=TP-Link Cloud Root CA, O=TP-Link Systems Inc., L=Irvine, ST=California, C=US`
- Serial `5D91E844A22F85E282C492F8B36AD9FDA95F1063`; ECDSA P-256 key, signed ecdsa-with-SHA384; CA:TRUE
- Valid 2025-02-25 03:47:11 UTC to 2055-02-18 03:47:11 UTC
- SHA-256 fingerprint `8D:27:22:4D:AC:20:C2:DB:8A:38:0E:31:03:B4:E3:83:C4:81:EE:41:B6:81:90:85:79:AE:E4:16:76:1D:A2:89`

```
-----BEGIN CERTIFICATE-----
MIICKTCCAdCgAwIBAgIUXZHoRKIvheKCxJL4s2rZ/alfEGMwCgYIKoZIzj0EAwMw
cjEeMBwGA1UEAwwVVFAtTGluayBDbG91ZCBSb290IENBMR0wGwYDVQQKDBRUUC1M
aW5rIFN5c3RlbXMgSW5jLjEPMA0GA1UEBwwGSXJ2aW5lMRMwEQYDVQQIDApDYWxp
Zm9ybmlhMQswCQYDVQQGEwJVUzAgFw0yNTAyMjUwMzQ3MTFaGA8yMDU1MDIxODAz
NDcxMVowcjEeMBwGA1UEAwwVVFAtTGluayBDbG91ZCBSb290IENBMR0wGwYDVQQK
DBRUUC1MaW5rIFN5c3RlbXMgSW5jLjEPMA0GA1UEBwwGSXJ2aW5lMRMwEQYDVQQI
DApDYWxpZm9ybmlhMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABAHpyZzXk1E4VWyIB+9VMci2Sw5OdeQ+kyFc2/R/f/OiHt6hk4PfMcCKKgS6
hkVVYyVlobJNn052z+s9DJKJgfajQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P
AQH/BAQDAgGGMB0GA1UdDgQWBBQLV0PTee1jvnJMcUCEtQgJSg/oyTAKBggqhkjO
PQQDAwNHADBEAiAURU4PvHXUrVViDF+rCky3RD9BeUpe91kYoNWe0oKVUwIgY0C5
MsDHbQrwLHs1I7+f2MvZDGBHhNjnl0n4MF9q0L0=
-----END CERTIFICATE-----
```

(The older `tp-link-root-CA.der`, `CN=tp-link-CA`, is a different root; the device roots `tp-link-device-root-CA.der`
and `tp-link-device-beta-root-CA.der` are for devices, not cloud hosts [app].)

**Not in the lists.** The response models of `getDeviceListByPage` (4.1, `TPAppCloudNetwork`: no IP-named field at
all) and `/v2/things` (4.2) carry no IP [app: class metadata; src2, src4, src8 show none]. `getDeviceInfo` (v2 API)
neither. No "running info" or shadow-style cloud endpoint returning an IP was found. The only other IP-named cloud
fields are a voice-sign-URL response (`ipAddress`, unrelated) and the camera's **public** IP (`getPubIP` /
`CameraGetPublicIPRequest`, the WAN address, through the device).

**Route 2: ask the camera (wakes it).** `TPCameraNetwork` has a device request `getDeviceIpAddress` (response field
`ip`), next to `getPubIP`, and the system module keeps an `ipAddress` [app]. Device requests go over the local
transport or the cloud passthrough/relay (`IPCTSTransportManager` retries the IoT-cloud transport after HTTP);
either way the camera must be awake to answer. The request body (likely a `network` section with `ipaddr`) is
**inferred** from adjacent strings. Hub child devices report a `local_ip` in the hub's child list, which is the hub's
data, not the camera's. **Wakes the camera.** Do not use.

**Route 3: UDP discovery, TDP (may or may not reach a sleeping camera).** The app has a TP-Link Discovery Protocol
stack (`TPTDPNetwork`: broadcast and unicast scans, "send unicast to known ip address", a multicast group
`239.255.255.250` it joins; `TDPCamera` in `TPCameraNetwork`) and holds the multicast entitlement; `Info.plist`
declares only Matter Bonjour types (`_matter._tcp`, `_matterc._udp`, `_matterd._udp`), so cameras are **not** found
by mDNS [app]. Wire shape [src11]:
- Request to UDP **20002** (broadcast `255.255.255.255`, or unicast to a known address): a 16-byte header, all
  big-endian: version 2 (1 byte), message type 0 (1), op code 1 = probe (2), payload length (2), flags 17 (1), a
  zero byte (1), a random 4-byte serial, then a CRC32 (4); followed by the JSON payload
  `{"params":{"rsa_key":"<PEM of a fresh RSA-2048 public key>"}}`. The CRC is computed over the whole packet with the
  CRC field first set to `0x5A6B7C8D`, then written into bytes 12–15.
- Reply from the device's port 20002 to the sender: the same 16-byte header, then JSON whose `result` has
  `device_id`, `device_type` (`SMART.IPCAMERA`), `device_model`, **`ip`**, `mac` (with dashes), `owner` (an MD5 of the
  owner), `factory_default`, `is_support_iot_cloud`, `obd_src`, `isResetWiFi`, `mgt_encrypt_schm`
  (`is_support_https`, `encrypt_type`, `http_port`, `lv`) and, for cameras, `encrypt_info` {`sym_schm`, `key`, `data`}.
  `key` is Base64 of RSA-OAEP(SHA-1) ciphertext of 32 bytes: AES-128 key (16) then IV (16); `data` is Base64 of
  AES-128-CBC/PKCS7 ciphertext of a JSON object with more device data [src11]. The app's camera parser reads
  `device_id`, `device_model`, `device_type`, `http_port`, `connect_type`, `connect_ssid`, `encrypt_info`,
  `sym_schm`, `is_support_https`, `isResetWiFi`, `owner`, `factory_default` and logs "TDP reply after decrypt" [app].
  The UDP source address is the device's address as well.
- Wake: a broadcast probe is handled by the camera's main processor. A sleeping battery camera keeps only a Wi-Fi
  keep-alive with the cloud; that it does **not** answer TDP while asleep is **inferred** (the app models "TDP and IoT
  both offline", `hasTdpAndIotOffline`, and validity flags for TDP info before local play [app]), not shown. If it
  does answer, it has woken for it. Confidence: wire shape high (src11, matching app strings); sleeping behaviour
  unknown.

**Route 4: passive LAN signals (no wake).**
- **ARP**: with the MAC from the cloud list (`deviceMac`, 4.1), look up the address in the host's ARP table
  (Homeswift's `ARPTable`). Entries exist only after traffic with the camera; Wi-Fi chips often answer ARP for a
  sleeping host (ARP offload), which does not wake the main processor; **unverified** for the C675D.
- **DHCP**: Home Assistant's integration discovers cameras by their DHCP host names (patterns like a model prefix,
  `c###*_*`, `d###*_*`, `tc##*_*`) [src12]; seeing them needs the DHCP broadcast (join or reboot), not renewals.

**Recommendation.**
1. At Setup and on each start: call `/v1/things/{thingName}/details` and take `ip`; check it against the MAC
   (`mac` there, or `deviceMac`) through `ARPTable` when an entry exists. Store it as a hint, never as the identity.
2. When a live-view connection to the hint fails, refresh it from the same cloud call (cheap, no wake) before giving up.
3. Never use `getDeviceIpAddress` or passthrough for this. Do not run periodic TDP scans aimed at battery cameras;
   a single unicast TDP probe is acceptable only right after a detection (camera already awake, section 8).
4. Test with the user's C675D: whether `details.ip` is present and fresh, and whether TDP is answered while asleep.

## 5. Event history

### 5.1 Headers for the Care and NBU hosts (no HMAC)

```
Authorization:  ut|<token>                       (literal "ut|")
app-cid:        app:TP-Link_Tapo_Android:<terminalUUID>
x-app-name:     TP-Link_Tapo_Android
x-app-version:  3.20.753
x-term-id:      <terminalUUID>
x-ospf:         Android 14
x-net-type:     wifi
x-locale:       en_US
Content-Type:   application/json;charset=UTF-8
User-Agent:     TP-Link_Tapo_Android/3.20.753(Homeswift/;Android 14)
```

[src4, src5, src6]; the same header names appear in `TPCareCloudClient` [app], plus `appTimeZone`, `x-tp-shared-type`,
`x-request-data-brand`, `x-cipher-suite` (optional, unknown use). `app-cid` must have the `app:<appName>:<uuid>` form
("missing appCid or invalid" otherwise) [src8]. [src2, src7] get by with only `Authorization` and `X-App-Name` on
`/v2/videos/list`. Answers are bare JSON; failures are HTTP statuses (`401 token invalid`) [src4, src7].

### 5.2 Route B: activities (the app's "Activity" page)

**v1, seen working** [src6]: `POST {care}/v1/activities/listActivitiesByDate`

```json
{"deviceId":"<deviceId>","startTime":"2026-11-05 00:00:00","endTime":"2026-11-06 00:00:00",
 "source":"1","eventTypeFilters":[],"page":0,"pageSize":100}
```

Times are the **account's local time** as `yyyy-MM-dd HH:mm:ss` [src2]. Answer
`{"listing":[Activity…],"page","pageSize","total"}`.

**v2, the iOS app's** [app] (`TPCareCloudClient`, field names listed next to the path; values inferred):
`POST {care}/v2/activities/listActivities` with `startTime`, `endTime`, `from`/`offset`, `pageSize`,
`timestampOrder` (`desc`), `deviceIds` [array], `eventTypes` [array], `levelGte`, `channelIds`, `identityIds`,
`homeId`, `filter`, `isRead`; answer `listing` and `hasBundleActivities`. Related paths [app]:
`/v2/activities/listActivitiesByDate` (`channelIdFilters`), `/v2/activities/listNotReadTimestamps` (`timeZoneId`),
`/v2/activities/retrieveActivityCount`, `/v2/activities/retrieveActivity`, `/v2/activities/updateReadStatus`,
`/v1/activities/listTimestamps`.

An **Activity** ([src6] types, extended by the names in [app]):

```json
{"id":"<activityId>","level":1,"source":1,"createdOn":1762340000000,"updatedOn":1762340005000,
 "accountId":"<accountId>","searchTags":["person"],"read":false,
 "device":{"deviceId":"<deviceId>","deviceAlias":"<base64>","deviceModel":"C675D",
           "deviceType":"SMART.IPCAMERA","deviceCategory":"camera"},
 "event":{"id":"<eventId>","type":"PD","name":"PersonDetected","timestamp":1762340000000,
          "eventLocalTime":"2026-11-05 11:53:20",
          "data":{"cloudStorageEnabled":false,"cloudStorage":{"enabled":false,"richNotificationsFeature":false},
                  "snapshot":{"url":"https://…","size":45678,"status":"ready","encryptionMethod":"AES-128-CBC",
                              "decryptionInfo":{"key":"<base64>","iv":"<…>"}},
                  "video":{"streamUrl":"https://…m3u8?…","duration":20,"resolution":"…","status":"in_progress"}}},
 "eventTypeInfos":[{"eventTypeName":"PersonDetected","eventTimestamp":1762340000000,"channelId":0,"aiTag":"…"}]}
```

- Timestamps: milliseconds (inferred from [src6]'s `int64` and typical values; check the magnitude).
- Event types: `MOTION` and `PD` (person) seen [src6, src7]; the app's event names [app]/[src2]: `Motion`, `Audio`,
  `BabyCry`, `PersonDetected`, `PersonEnhanced`, `VehicleDetected`, `PetDetected`, `animalDetected`,
  `deliverPackageDetected`, `pickUpPackageDetected`, `tapoCameraLinecrossingDetection`,
  `tapoCameraAreaIntrusionDetection`, `tapoCameraCameraTampering`, `tapoLoiteringDetected`, `tapoGlassBreakingDetected`,
  `tapoBarkDetected`, `tapoMeowDetected`, `familiarFaceDetected`, `unfamiliarFaceDetected`, `ringEvent`. The short
  codes for vehicle/pet etc. in the activity list are not known. **Recommendation:** treat any activity of the camera
  as motion; map `PD`/`PersonDetected` (and other AI types, by name) to an optional Occupancy-style sensor only if
  wanted.
- `status` values in [app]: `ready`, `in_progress`, `finished`, plus `transcodeFinished`: an activity exists while its
  video is still uploading, which suggests it is listed early in the event.
- Media URLs: the snapshot/clip is AES-128-CBC with the given key [src2]; [src6] appends `&token=<t>` to `streamUrl`.
  Not needed for a motion sensor.

**Subscription.** Everything in [src2, src6, src7] is about Tapo Care recordings ("Only Tapo Care cloud recordings can
be listed here" [src2]). The app's strings say Snapshot Notifications are a Tapo Care feature, and that motion/sound
detections never carry snapshots [app: `RichNotificationsTips`, `TapoCarePageDetail`]; the device list shows
"Activity detected %d days ago" / "No activity in past 30 days" [app], so some activity record exists per camera
for everyone, but **no source shows `listActivities` returning entries for an account without Tapo Care**.

### 5.3 Route A: the message centre (notification inbox)

`POST {regional}/api/v2/common/getAppNotificationByPage?token=<t>`, signed [src2]; method name and fields in [app]:

```json
{"appType":"TP-Link_Tapo_Android","contentVersion":2,"deviceToken":"","direction":"asc","index":0,
 "indexTime":1762340000,"limit":50,"locale":"en_US","mobileType":"ANDROID",
 "msgTypes":["Motion","PersonDetected","PersonEnhanced","VehicleDetected","PetDetected","Audio","BabyCry",
             "tapoCameraLinecrossingDetection","tapoCameraAreaIntrusionDetection","tapoCameraCameraTampering",
             "deliverPackageDetected","pickUpPackageDetected","ringEvent","CameraLowBattery","BatteryEmpty"],
 "terminalUUID":"<terminalUUID>"}
```

- `indexTime` (Unix seconds) and `direction` page in time: `asc` from `indexTime` forward (inferred). [src2] notes the
  server accepts an empty `deviceToken`.
- Answer fields [app]: `notifications`/`msgList`, `hasNextPage`, and per message `msgId`, `msgType`, `msgCategory`,
  `title`, `content`, `time`, `localTime`, `eventType`, `deviceId`, `attachments`, `imgUrl`, `relatedEventId`
  (links to the activity), `smartId`. Delete: `delAppNotificationById` (`msgIdList`), `delAppNotification`.
- This inbox is what the app's Notifications page shows; entries exist only when the camera's **Activity
  Notifications** are on (the camera's `msg_push` switch, [TapoCamera.md 12.3]) and probably only for event types
  enabled for notification; the per-user cooldown ([app]: "Notification preferences (on/off, type, and cooldown) are
  managed … by each user") may thin them out. Inferred, not tested.
- Works without Tapo Care: plain (non-snapshot) activity notifications are free in the app's strings; inferred.

### 5.4 Other event endpoints in the app (not needed)

- NBU device event log: `GET {appServerUrlV2}/v1/things/{thingName}/events?fetchSize=50&order=DESC&fetchType=normal`
  → `{"events":[…]}`; [src9] polls it **every 1 s** for S200B buttons without reported throttling. Whether cameras
  log detections there is unknown. [app] also has `/v1/things/{thingName}/events/push-settings`, `/events/mute`,
  `/v1/things/events/push-settings/batch-query`.
- `/v2/videos/list` (GET, query `deviceId,startTime,endTime,order,page,pageSize`; answer `index[]` with
  `eventLocalTime`, `eventTypeList`, `video[]`, `image[]`) and `/v2/videos/devices` [src2, src6, src7]: Tapo Care clips.

### 5.5 Latency and polling interval

- No source measures detection-to-listing delay. The camera must wake, connect Wi-Fi (already associated in its
  low-power state), classify (PIR then AI for person), and report. Typical cloud-camera practice is 1–5 s to the push;
  the listing is written by the same pipeline. **Expect 2–10 s** from motion to an entry; measure (section 10).
- Rate: [src9] 1 s per device on the NBU host; [src7] advises a one-minute cron. No 429 reported by any.
  **Recommendation:** poll route A every **5 s** (one request covers all cameras of the account), with jittered
  exponential back-off on errors up to 5 min and a hard floor of 2 s; poll only while the HomeKit bridge is running.

## 6. Push

### 6.1 How the iOS app registers

- iOS app: APNs (`aps-environment` entitlement, `UIBackgroundModes` `remote-notification`, `voip`); **no
  FirebaseMessaging** framework is embedded, so its pushes come through APNs from TP-Link, not FCM.
  `GoogleService-Info.plist` (project `tapo-ios`, sender `266476751486`) serves Crashlytics/sign-in, not pushes.
- Registration: method `postPushInfo` on the signed v2 API (path inferred: `/api/v2/common/postPushInfo`, as its
  neighbours `getAppNotificationByPage`, `setBadge`, `subscribeMsg`, `getSubscribeMsgType`, `unsubscribeNotification`
  are on `/api/v2/common` [src2 for the neighbour]). Field names beside it [app]: `appType`, `mobileType` (`ANDROID` is
  a literal in the framework; iOS inferred `IOS`), `appVersion`, `appBundleName`, `deviceToken` (the APNs token on iOS;
  log label `un_device_token`), `pushKitDeviceToken` (VoIP, for doorbell calls), `videoCallLiveActivityToken`,
  `pushMetadata`, `locale`, `terminalUUID`. Also NBU `/v1/events/notification-method-subscriptions`
  (`notificationType`, `enableVoip`, `enableVideoCallLiveActivityToken`) and `/v1/terminals/events`.
- Payload keys the notification extension reads [app]: `msgId`, `msgType` (e.g. `PersonDetected`, `ringEvent`),
  `deviceId`, `deviceType`, `imgUrl`, `urlNeedToken`, `relatedEventId`, and the receive time.

### 6.2 Could a non-app client receive pushes?

- APNs: no (needs TP-Link's APNs certificate and the app's bundle).
- FCM: the Android app registers an FCM token with `mobileType: "ANDROID"`. Homeswift's `FCMReceiver` can create a
  web-push FCM token for **a given Firebase project** (API key, project id, app id), as Ring's plugins do. For Tapo that
  needs the **Android** app's Firebase configuration (its `google_app_id`, API key, project id/sender), which is not in
  the iOS app and not in any source read. Whether TP-Link's sender accepts and delivers to a web-push token of its
  project is also unknown. **Plausible, unproven**; it would also add a "terminal" to the account and maybe e-mail
  the owner about a new login.

### 6.3 MQTT gateway (exploratory)

[app] `TPIoTCloudClient` keeps an MQTT session (`MQTTClient` over WebSocket to `nbu.iot-cloud-gateway.app-v2`) and
subscribes to `<prefix>/things/<thingName>/events/accepted` and `<prefix>/things/<thingName>/shadow/update/accepted`
(handlers `handleEventTopicMessage`, `handleShadowUpdateTopicMessage`). That is a cloud push of device events while the
app is open. Connect parameters (client id, username/password or JWT, topic prefix: `retrieveMQTTTopicPrefix`) are not
visible. Whether battery cameras publish detections there is unknown. Not specified further.

## 7. Does any of this wake the camera?

| Call | Reaches the camera? |
|---|---|
| Login, refresh, account status, service URLs | No |
| `getDeviceListByPage`, `/v2/things`, `/v1/things/{id}/details` | No (cloud registry; `status` is the cloud's last view) |
| `getAppNotificationByPage`, activities, `/v2/videos/*`, snapshot/clip downloads | No (cloud storage) |
| `postPushInfo`, push reception | No |
| **`/api/v2/common/passthrough`**, **`/v1/things/{id}/services-sync`**, `/services`, `/proxy`, relay/SFU requests | **Yes**: the cloud relays the request to the device and holds it while it wakes (up to 600 s [src4]); a sleeping camera may answer `-20571` offline [src8]. Never call these. |

## 8. HomeKit Motion Sensor design

**Recommendation (battery-safe):**

1. Setup: cloud login (3.3–3.4) with a persistent `terminalUUID`, find the camera's `deviceId` (4.3). Secrets in the
   vault (`context.secretFile`).
2. One poller per account: route A (5.3) every 5 s, `msgTypes` = the detection types, `indexTime` = the newest `time`
   seen (minus a small overlap), dedupe by `msgId`. For each message whose `deviceId` matches a camera: set
   `MotionDetected` true, and back to false after a hold time (e.g. 30 s, or 10 s after the last message). Optionally
   route B in parallel when the account has Tapo Care (gives `PD` vs `MOTION` and the clip).
3. Ignore messages older than the start of polling (first page sets the cursor, no back-fill).
4. Route C (FCM) later, behind a feature flag, if the Android Firebase config is obtained and it is shown to work;
   keep A as the fallback.
5. Never touch port 8800 or 443 on the camera for motion.

**Pre-starting the live view on a detection:** the camera is awake right after a detection (it records for its clip
length), so a Streamd connection then would not add a wake-up, but it would **lengthen** the awake time; the user's
rule allows connecting only while someone watches. **Recommendation:** do not pre-start. Connect on HomeKit's stream
request only. Beware of **HomeKit Secure Video**: a motion sensor on a recording camera makes the home hub request a
recording stream on every detection, which would open 8800 each time. Expose the camera without HKSV recording, or
make recording an explicit opt-in that states the battery cost. A detection may at most warm what costs nothing on the
camera (resolve the address, prepare ffmpeg), so that a viewer arriving within seconds starts faster.

Expected latency of the sensor: detection-to-cloud (unknown, est. 2–10 s) + half the poll interval (~2.5 s).

## 9. A local signal to test (no cloud)

Tapo **doorbells** (also battery ones, via their hub) send a UDP packet to **port 20005** (broadcast) on a ring; any
packet from the device's or hub's address counts, the payload is not parsed [src5, citing Home Assistant's
tapo_control]. No source says battery **cameras** send anything on motion. Listening is passive and cannot wake the
camera. **Recommendation:** during a test, bind UDP 20005 (and capture the camera's other traffic) while walking past
the camera; if a packet appears, it beats the cloud on latency.

## 10. Gaps

1. No source shows a non-app client polling camera **motion** events; route A is shown for listing notifications in
   general [src2], route B only for Tapo Care accounts [src6, src7]. Test with the user's account: with and without
   Care, which `msgType` a C675D produces (`Motion`, `PersonDetected`, …), and the delay.
2. Whether the message centre records messages when no phone push token is registered for this terminal, or only per
   account (likely per account: the app reads it on any phone).
3. The iOS app's own request bodies (main binary encrypted): field names are from adjacency, values are inferred.
   The Tapo Care host's service id; the exact `listActivities` v2 body.
4. Token lifetime; rate limits; whether a new terminal triggers an e-mail to the owner.
5. Which of the two iOS constants is the AccessKey (Android pair is the documented one).
6. FCM: the Android Firebase configuration; whether a web-push token receives TP-Link pushes.
7. MQTT gateway: connect parameters and whether cameras publish events.
8. Units of `createdOn`/`timestamp` (ms assumed) and the time zone of `startTime`/`endTime` (account local time [src2]).
9. Shared (non-owner) accounts: battery cameras authenticate only the owner on 8800 (TapoCamera.md 1); [src7] says
   shared accounts generally cannot read Tapo Care. Use the owner's account.

## 11. Recommendations (summary)

- **Motion source:** poll the cloud message centre (`getAppNotificationByPage`) every 5 s per account; optional
  activities list when Tapo Care is active; FCM push only after a proof. None of it wakes the camera.
- **Auth:** signed v2 login with the Android key pair, persistent `terminalUUID`, e-mail MFA with
  `terminalBindEnabled`, refresh on `-20651`/401, no automatic retry of rejected logins.
- **Never** call passthrough / services-sync / relay endpoints for a battery camera.
- **No pre-start**, and no HKSV recording by default, so 8800 is opened only for a live viewer.
- **Try UDP 20005** passively once; it would be the only local, instant signal.
