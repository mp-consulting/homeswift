# JointSpace API — Philips Android TV (TPVision `org.droidtv.xtv`)

Reference for the TV-side API server, derived by decompiling `xtv.apk` pulled over ADB
from a **65OLED936/12** (Android 11, build `RTT2.211108.001`, `os_type` `MSAF_2019_P`,
API version **6.1.0**).

Source of truth: `org.droidtv.xtv.xtvRestlet.xtvRequestHandler` (router table),
`xtvHttpRequestHandler` (plain-HTTP router) and `xtvUtility.xtvConstants` (URI constants).
Everything below is read from the route table, not guessed from community docs.

## Transport

The server is [Restlet](https://restlet.talend.com/) running inside the `org.droidtv.xtv`
system app (flagged `PERSISTENT`). On non-`zh-CN` firmware **both connectors start**:

| Port | Protocol | Handler class | Routes | Auth |
|------|----------|---------------|--------|------|
| 1925 | HTTP  | `xtvHttpRequestHandler` | 3 | none |
| 1926 | HTTPS | `xtvRequestHandler`     | 59 | digest (5 exceptions) |

`zh-CN` firmware runs `restletServerInitForCN`, which starts **only** port 1925 with a
different handler (`xtvHttpRequestHandlerForCN`). mDNS advertises 1925 on CN sets and
1926 everywhere else.

The two ports do **not** serve the same API. Port 1925 is not a plaintext mirror of 1926 —
it exposes three endpoints and nothing else.

### TLS

Self-signed chain from the bundled BouncyCastle keystore (`assets/a.bks`, empty store
password; runtime copy at `/data/data/org.droidtv.xtv/sc.bks`):

- Leaf `CN=restfultv.tpvision.com`, 2048-bit RSA, **SHA1WITHRSA**
- Chain `ca.tpvision.com` → `www.tpvision.com`
- Valid 19 May 2015 → **4 Oct 2042** (not expired)

Certificate verification must be disabled client-side. TLS 1.2 and TLS 1.3 both negotiate
(verified: `TLS_AES_256_GCM_SHA384` and `ECDHE-RSA-AES128-GCM-SHA256`). ALPN is offered by
clients but the server agrees no protocol, so HTTP/1.1 is used. `SSLv2`/`SSLv3` disabled.

### Authentication

HTTP **digest**, realm `XTV`, server-nonce max age 2 h. Credentials come from the pairing
flow (`/6/pair/request` → `/6/pair/grant`); `pairing_type` is reported as
`digest_auth_pairing` in `/6/system`. Unauthenticated requests to protected routes return
`401` with a Restlet HTML status page, not JSON.

## Port 1925 — plain HTTP, no authentication

| Endpoint | Notes |
|----------|-------|
| `GET /6/system` | Device info. Verified: **HTTP 200 in 14 ms** |
| `POST /6/notifychange` | Long-poll state changes. Verified: returns e.g. `{"powerstate":{"powerstate":"On"}}` |
| `GET /6/system/serialnumber_encrypted` | Verified: HTTP 200 |

Each is also attached without the `/6` prefix (`/system`, `/notifychange`,
`/system/serialnumber_encrypted`).

Anything else on 1925 returns **404** — confirmed with `/6/powerstate`.

## Port 1926 — HTTPS

`Auth` = digest required. `Methods` lists the verbs the handler branches on explicitly in
the decompiled code. `any` means the handler performs no method check at all, so the verb
is not validated server-side — the correct verb follows from the endpoint's semantics
(`/6/input/key`, for example, is POST).

| Endpoint | Auth | Methods | Handler |
|----------|------|---------|---------|
| `/6/HueLamp/Config/{token}` | yes | GET,POST | `hueConfigHandler` |
| `/6/HueLamp/Identifier` | yes | GET | `hueDeviceInfoHandler` |
| `/6/HueLamp/Lock` | yes | POST | `hueLockHandler` |
| `/6/HueLamp/power` | yes | POST,GET | `huePowerHandler` |
| `/6/activities/current` | yes | any | `currRunAct` |
| `/6/activities/launch` | yes | any | `launchTvAct` |
| `/6/activities/tv` | yes | GET,POST | `currTvAct` |
| `/6/ambilight/cached` | yes | GET,POST | `xtvambmanagerrequesthandler.getAmbLgtCached` |
| `/6/ambilight/lounge` | yes | GET,POST | `xtvambmanagerrequesthandler.getAmbLgtLounge` |
| `/6/ambilight/measured` | yes | any | `xtvambmanagerrequesthandler.getAmbLgtMeasured` |
| `/6/ambilight/mode` | yes | GET,POST | `xtvambmanagerrequesthandler.getAmbLgtMode` |
| `/6/ambilight/processed` | yes | any | `xtvambmanagerrequesthandler.getAmbLgtProcessed` |
| `/6/ambilight/topology` | yes | any | `xtvambmanagerrequesthandler.getAmbLgtTopology` |
| `/6/api/version` | yes | any | `apiVersion` |
| `/6/applications` | yes | any | `sendApps` |
| `/6/applications/{id}/icon` | **no** | any | `sendIcon` |
| `/6/audio/volume` | yes | GET,POST | `volHandler` |
| `/6/channeldb/servermapping/{id}` | yes | any | `sendSerMapping` |
| `/6/channeldb/tv` | yes | any | `sendCompleteChInfo` |
| `/6/channeldb/tv/channelLists/{id}` | yes | any | `sendChList` |
| `/6/channeldb/tv/channelLists/{list_id}/{ccid}/logo` | **no** | any | `sendLogoImage` |
| `/6/channeldb/tv/favoriteLists/{id}` | yes | GET | `favouritesListHandler` |
| `/6/channeldb/tv/modifyfavourite/{id}` | yes | POST | `favouritesModifyHandler` |
| `/6/companionlauncher/launch_request_details` | yes | any | `csLaunchPTA` |
| `/6/companionlauncher/launch_response` | yes | any | `csResponsePTA` |
| `/6/companionlauncher/registration` | yes | any | `csRegisterPTA` |
| `/6/context` | yes | any | `getContextInfo` |
| `/6/input/key` | yes | any | `keyHandler` |
| `/6/input/onscreenkeyboard/visible` | yes | GET,POST | `getSetOSKB` |
| `/6/input/pointer` | yes | GET,POST | `inputPointer` |
| `/6/input/textentry` | yes | any | `getInputText` |
| `/6/network/devices` | yes | any | `getNetworkInfo` |
| `/6/notifychange` | yes | GET,POST | `notifyChange` |
| `/6/pair/grant` | yes | any | `grantReq` |
| `/6/pair/request` | **no** | any | `pairReq` |
| `/6/powerstate` | yes | GET,POST | `sysPowerState` |
| `/6/recordings/add` | yes | any | `recordingsHandler` |
| `/6/recordings/conflictcheck` | yes | any | `recordingsHandler` |
| `/6/recordings/groupaction` | yes | any | `recordingsHandler` |
| `/6/recordings/list` | yes | any | `recordingsHandler` |
| `/6/recordings/refresh` | yes | any | `recordingsHandler` |
| `/6/recordings/{rcid}` | yes | any | `recordingsHandler` |
| `/6/recordings/{rcid}/image` | **no** | any | `recordingsHandler` |
| `/6/recordings/{rcid}/update` | yes | any | `recordingsHandler` |
| `/6/screenstate` | yes | GET,POST | `sysScreenState` |
| `/6/system` | **no** | POST | `sendSysSetting` |
| `/6/system/country` | yes | any | `getCountryName` |
| `/6/system/deviceid_encrypted` | yes | any | `deviceID` |
| `/6/system/epgsource` | yes | GET,POST | `getPostEGP` |
| `/6/system/featuring` | yes | GET | `featureLister` |
| `/6/system/menulanguage` | yes | any | `getMenuLanguage` |
| `/6/system/model_encrypted` | yes | any | `modelVer` |
| `/6/system/name` | yes | any | `getSystemName` |
| `/6/system/nettvversion` | yes | any | `getNetTvVer` |
| `/6/system/serialnumber_encrypted` | yes | any | `serialNumber` |
| `/6/system/softwareversion_encrypted ` | yes | any | `softVer` |
| `/6/system/storage` | yes | any | `recordingsHandler` |
| `/6/system/timestamp` | yes | any | `sysTimestamp` |
| `/6/timestamp` | yes | GET | `sysTimeStamp` |

Every route above is additionally attached without the `/6` prefix (e.g. `/powerstate`
alongside `/6/powerstate`).

### Reachable without authentication on 1926

- `GET /6/system`
- `POST /6/pair/request`
- `GET /6/applications/{id}/icon`
- `GET /6/channeldb/tv/channelLists/{list_id}/{ccid}/logo`
- `GET /6/recordings/{rcid}/image`

## Connector tuning (from `xtvRestletServer`)

| Parameter | 1925 | 1926 |
|-----------|------|------|
| `maxThreads` / `minThreads` / `lowThreads` | 25 | 25 |
| `maxTotalConnections` | – | 25 |
| `socketNoDelay` | true | true |
| `controllerSleepTimeMs` | – | 1000 |
| `maxIoIdleTimeMs` | – | 120000 |
| `protocol` / `disabledProtocols` | – | `TLS` / `SSLv3 SSLv2` |
| `sslContextFactory` | – | `org.restlet.engine.ssl.DefaultSslContextFactory` |

## Known firmware defect on the HTTPS connector

TPVision ships a hand-patched `org.restlet.ext.nio.internal.channel.ReadableSslChannel`.
Its `onDrain()` TLS-unwrap loop can spin forever:

```java
if (sslResult.getStatus() != OK || final_size <= 0
    || (rem == applicationBuffer.remaining()
        && sslResult.getHandshakeStatus() != NEED_UNWRAP)) break;
```

`final_size` is measured cumulatively from `initialSize`, so once any byte is consumed it
stays `> 0`. If an `unwrap()` returns `OK` + `NEED_UNWRAP` while consuming and producing
nothing, no clause breaks and the thread spins at ~100% of a core permanently.

Observed on this set: one Restlet thread at **20 h 08 m CPU against 21 h 04 m uptime**, the
`:1926` accept queue saturated at **51**, and TLS `ClientHello` receiving no `ServerHello`.
Port 1925 stays fully responsive throughout — the defect is confined to the SSL read path.

The APK also ships the patch as readable source at
`org/restlet/ext/nio/internal/channel/ReadableSslChannel.java_patch_ok`. That file is a
slightly older revision than what was compiled: it contains a `System.exit(0)` in the
`catch` block which is **not** present in the shipped bytecode.

### Recovery

`am force-stop org.droidtv.xtv` is a no-op — the app is `PERSISTENT`. What works, without
root:

```
adb shell am crash org.droidtv.xtv
```

Android restarts it immediately; the accept queue drains and 1926 serves normally again.

## Verification notes

Captured against the TV on 2026-11-05. A healthy `org.droidtv.xtv` sits at **0% CPU** when
idle and serves sequential HTTPS requests, keep-alive reuse, digest-auth round trips and
abandoned handshakes without issue. The spin is intermittent and was not reproducible on demand across TLS 1.2/1.3, keep-alive,
digest and truncated-handshake probes.
