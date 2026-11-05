# Renault: functional specification (clean room)

## 0. Provenance

| | |
|---|---|
| Primary protocol source | https://github.com/hacf-fr/renault-api (Python package `renault-api`, by `epenet`) |
| Commit read | `d9645c933a1256acca34d3deef6267535bcacabb` (shallow clone of the default branch, 2026-11-04). The latest tag is `v0.6.3`; tag `v0.6.2` (`fec651abf4988aeaafcf11d74326922e05e75829`, 2026-10-26) was compared: the only difference in `src/` is the per-model endpoint table (a few more models), nothing about the Renault 5. |
| Licence | MIT, "Copyright © 2020 epenet" (`LICENSE.rst`) |
| Entity source | https://github.com/home-assistant/core, `homeassistant/components/renault` only (sparse checkout), commit `5be1efbb099aa4dd91bd251337dbb3180331fa9c` (2026-11-04). Its `manifest.json` pins `renault-api==0.6.2`, quality scale "platinum", codeowner `@epenet`. |
| Licence | Apache License 2.0 (Home Assistant core's `LICENSE.md`; no per-file copyright lines in the component) |
| Homebridge plugins | npm and GitHub were searched for `homebridge-renault`, `homebridge-myrenault`, `homebridge-zoe`. The only hit is `homebridge-zoe` 0.0.1 (https://github.com/brownad/homebridge-zoe, ISC, last pushed 2020-03-27, one version published 2020-01-29). It predates the current API (Gigya JWT + Kamereon car-adapter for the AmpR cars) and is unmaintained, so it was **not** used and its options are not kept. There is no maintained Homebridge plugin. |
| Proposed platform name | **`Renault`** |

This document was written by the spec writer; it contains no source code. Interface identifiers (URLs, header names,
JSON keys, enum values, error codes and the public app constants the library publishes) are quoted exactly because a
compatible implementation needs them. Everything else is paraphrase. Nothing from the repositories was installed or run.
Behaviour the sources show is described as such; choices for Homeswift are marked **Recommendation**.

Words used below: **Gigya** = SAP Customer Data Cloud, Renault's identity provider; **Kamereon** = Renault's
connected-car API ("wired" gateway); **kca** = the "car-adapter" family of vehicle endpoints; **kcm** = the newer
family of vehicle endpoints used by recent cars; **endpoint key** = the library's short name for an endpoint
(`battery-status`, `actions/hvac-start`), which a per-model table resolves to a URL path and a *mode*.

---

## 1. Scope

### 1.1 What the API covers

One MyRenault account (a Gigya identity) owns one or more Kamereon *accounts*; each Kamereon account links vehicles by
VIN. For each vehicle the API offers status reads (battery, cockpit, HVAC, location, lock, tyre pressure, remote engine
start state, charge mode, charging settings, state-of-charge limits) and actions (start/stop climate, start/stop/pause
charging, horn, lights, location refresh, charge mode, schedules, state-of-charge limits). Which of them work depends on
the **model code** (`vehicleDetails.model.code`, e.g. `R5E1VE`); many models reject endpoints with a forbidden or
not-found error, so the library keeps a per-model table (1.3). Brands: Renault, Dacia, Alpine (same backend).

### 1.2 Endpoint keys and their default resolution

All vehicle paths below are relative to `<kamereonRoot>/commerce/v1/accounts/<accountId>/kamereon` and contain `{vin}`.

| Endpoint key | Default path | Default mode |
|---|---|---|
| `battery-status` | `/kca/car-adapter/v2/cars/{vin}/battery-status` | default |
| `cockpit` | `/kca/car-adapter/v1/cars/{vin}/cockpit` | default |
| `hvac-status` | `/kca/car-adapter/v1/cars/{vin}/hvac-status` | default |
| `hvac-settings` | `/kca/car-adapter/v1/cars/{vin}/hvac-settings` | default |
| `location` | `/kca/car-adapter/v1/cars/{vin}/location` | default |
| `lock-status` | `/kca/car-adapter/v1/cars/{vin}/lock-status` | default |
| `pressure` | `/kca/car-adapter/v1/cars/{vin}/pressure` | default |
| `res-state` | `/kca/car-adapter/v1/cars/{vin}/res-state` | default |
| `charge-mode` | `/kca/car-adapter/v1/cars/{vin}/charge-mode` | default |
| `charging-settings` | `/kca/car-adapter/v1/cars/{vin}/charging-settings` | default |
| `charge-schedule` | `/kca/car-adapter/v1/cars/{vin}/charge-schedule` | default |
| `charge-history` | `/kca/car-adapter/v1/cars/{vin}/charge-history` | default |
| `charges` | `/kca/car-adapter/v1/cars/{vin}/charges` | default |
| `hvac-history` | `/kca/car-adapter/v1/cars/{vin}/hvac-history` | default |
| `hvac-sessions` | `/kca/car-adapter/v1/cars/{vin}/hvac-sessions` | default |
| `notification-settings` | `/kca/car-adapter/v1/cars/{vin}/notification-settings` | default |
| `soc-levels` | `/kcm/v1/vehicles/{vin}/ev/soc-levels` | default (note: a kcm path even by default) |
| `alerts` | `/vehicles/{vin}/alerts` | default |
| `actions/hvac-start` | `/kca/car-adapter/v1/cars/{vin}/actions/hvac-start` | default |
| `actions/hvac-stop` | `/kca/car-adapter/v1/cars/{vin}/actions/hvac-start` (same URL) | default |
| `actions/charge-start` | `/kca/car-adapter/v1/cars/{vin}/actions/charging-start` | default |
| `actions/charge-stop` | `/kca/car-adapter/v1/cars/{vin}/actions/charging-start` (same URL) | default |
| `actions/charge-set-mode` | `/kca/car-adapter/v1/cars/{vin}/actions/charge-mode` | default |
| `actions/charge-set-schedule` | `/kca/car-adapter/v2/cars/{vin}/actions/charge-schedule` | default |
| `actions/hvac-set-schedule` | `/kca/car-adapter/v2/cars/{vin}/actions/hvac-schedule` | default |
| `actions/horn-start` | `/kca/car-adapter/v1/cars/{vin}/actions/horn-lights` | default |
| `actions/lights-start` | `/kca/car-adapter/v1/cars/{vin}/actions/horn-lights` (same URL) | default |
| `actions/refresh-location` | `/kca/car-adapter/v1/cars/{vin}/actions/refresh-location` | default |

Alternative resolutions a model may use instead of the default:

| Name (spec writer's) | Path | Mode |
|---|---|---|
| hvac stop with "stop" | `/kca/car-adapter/v1/cars/{vin}/actions/hvac-start` | `kca-stop` |
| kcm charge start | `/kcm/v1/vehicles/{vin}/charge/start` | `kcm` |
| kcm charge schedule | `/kcm/v1/vehicles/{vin}/charge/schedule` | `kcm` |
| kcm pause/resume (start or stop) | `/kcm/v1/vehicles/{vin}/charge/pause-resume` | `kcm-pause-resume` |
| kcm settings (charge start, charge-schedule read) | `/kcm/v1/vehicles/{vin}/ev/settings` | `kcm-settings` |

The mode changes the request body (section 4.6).

### 1.3 The per-model table (resolution rules)

- The model code comes from the vehicle's details (`model.code`).
- **No model code**: every key resolves to its default (all "supported").
- **Model code not in the table**: every key resolves to its default; the library logs a warning once per model
  ("not documented, using default endpoints", pointing at issue hacf-fr/renault-api#1747).
- **Model in the table but the key not listed**: the default, with a once-per-(model, key) warning.
- **Key listed with "none"**: the endpoint is unsupported for that model; asking for it is an "endpoint not
  available" error and Home Assistant never creates the entity or poller.

**Renault 5 E-Tech, model code `R5E1VE`** (the target car; AmpR Small platform):

| Endpoint key | R5E1VE | Note from the source (reason it is off) |
|---|---|---|
| `battery-status` | default (kca v2) | |
| `cockpit` | default | |
| `hvac-status` | default | |
| `hvac-settings` | default | |
| `location` | default | |
| `soc-levels` | default (kcm) | |
| `alerts` | default | |
| `charges` | default | |
| `charge-schedule` | **kcm settings** (`/kcm/v1/vehicles/{vin}/ev/settings`, mode `kcm-settings`) | |
| `actions/hvac-start` | default | |
| `actions/hvac-stop` | **hvac stop with "stop"** (mode `kca-stop`) | |
| `actions/charge-start` | **kcm settings** (mode `kcm-settings`) | |
| `actions/charge-stop` | none | "not supported, use the charger to stop" |
| `actions/horn-start` | default | |
| `actions/lights-start` | default | |
| `actions/refresh-location` | default | |
| `actions/charge-set-mode` | none | `err.func.wired.forbidden` |
| `actions/charge-set-schedule` | none | `err.func.wired.forbidden` |
| `actions/hvac-set-schedule` | none | `err.func.wired.forbidden` |
| `charge-mode` | none | forbidden |
| `charging-settings` | none | forbidden |
| `charge-history` | none | not-found |
| `hvac-history`, `hvac-sessions` | none | not-found |
| `lock-status` | none | `err.func.wired.notFound` |
| `pressure` | none | notFound |
| `res-state` | none | forbidden |
| `notification-settings` | none | `err.func.vcps.users-helper.get-notification-settings.error` |

So for an R5 the useful set is: battery, cockpit (mileage), HVAC status (+ interior temperature), location, SoC limits
(read and write), climate start and stop, charge start (no stop), horn, lights, location refresh.

**Other AmpR / recent electric models in the table** (same family, useful for testing a generic implementation):

| Model code | Car | Differences from R5E1VE |
|---|---|---|
| `A4E1VE` | Renault 4 E-Tech | hvac-stop uses the **default** ("cancel"); no `actions/refresh-location` or `alerts` listed (defaults apply, with the warning); `hvac-settings` not listed; `charging-settings` not listed (default, with warning) |
| `A5E1AE` | Alpine A290 | like R5 but `hvac-settings` none (errorCode 502000 on every call), `alerts` none |
| `TWE1VE` | Renault Twingo E-Tech | reads only listed (battery, cockpit, hvac-status, location, soc-levels, charge-schedule via kcm settings); no actions listed, so every action falls back to the **default kca** path with a warning |
| `XBG2VE` | Dacia Spring MY25 | charge start via kcm settings, hvac stop "stop", horn/lights/refresh-location, no charge stop (forbidden on kcm pause-resume, invalid-body on default) |
| `XCB1SE` | Scenic E-Tech | charge start via kcm settings; no charge stop; hvac-stop not listed (default "cancel") |
| `XCB1VE` | Megane E-Tech | charge start via **kcm charge/start** (mode `kcm`, may carry a start time), charge schedule via kcm; hvac stop "stop"; `charging-settings` supported |
| `XDD1VE` | Master E-Tech | charge start via kcm settings; hvac stop default; `actions/charge-set-mode` default (supported) |

Older models (for contrast): `X101VE` ZOE phase 1 (no location; everything kca; reports power in watts and charge
session durations in minutes), `X102VE` ZOE phase 2 (charge start kca default, **charge stop via kcm pause-resume**,
`charging-settings` supported, `charge-mode` none), `XBG1VE` Dacia Spring (charge start *and* stop via kcm
pause-resume). Thermal/hybrid cars (`XJA1VP` Clio V, `XJB2SU` Captur II GPL, `XHN1SU` Austral, `DU31SU` Duster, ...)
generally only have `cockpit` and `location`, sometimes `lock-status` and horn/lights.

**kca vs kcm, in short**: older cars (ZOE, Spring, Megane IV, Captur II) are driven through the kca car-adapter for
both reads and actions. Recent cars keep kca for most reads and for climate, horn and lights, but charging control moved
to kcm: either `charge/start` (Megane E-Tech), `charge/pause-resume` (ZOE 2 stop, Spring), or rewriting the whole
`ev/settings` document (R4, R5, A290, Scenic, Spring MY25, Master). The SoC limits are kcm for every car that has them.

### 1.4 Energy type

The details carry `engineEnergyType` and `energy.code`. A vehicle "uses electricity" when either (the first, else the
second) is `ELEC`, `ELECX` or `PHEV`; it "uses fuel" when it is `OTHER`, `PHEV` or `HEV`. The R5 sample has energy
code `ELECX`. Home Assistant creates battery, charge-mode, charging-settings and SoC-limit pollers only for vehicles that
use electricity, and fuel sensors only for vehicles that use fuel.

---

## 2. Configuration interface

There is no Homebridge plugin to stay compatible with, so the block is Homeswift's own. Home Assistant's config entry
keeps `locale`, `username`, `password`, `kamereon_account_id`, `login_token` and `device_ids`; the block below covers the
same ground.

**Recommendation** (platform `Renault`, singular):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | | `"Renault"` |
| `name` | string | `"Renault"` | Log name only. |
| `locale` | string | `"fr_FR"` | One of the locales of 3.1 (`fr_FR`, `en_GB`, `pt_PT`, ...). Picks the Gigya and Kamereon servers and keys; its last two letters are the `country` query parameter. A choice in Setup. |
| `username` | string | | MyRenault e-mail. Personal data; masked in logs. |
| `password` | string | | MyRenault password. **Secret** (secret-named key, sealed by the runtime). Needed only for a new sign-in; see 3.4. |
| `kamereonAccountId` | string | auto | The Kamereon account to use when the person has several (3.6). Normally filled in by Setup. |
| `vins` | string[] | all | Only these VINs become accessories. **Recommendation:** read it, but Setup's canonical shape is `_accessories.<VIN>.excluded`; `canonicalSettings` turns `vins` into exclusions of the others. |
| `climateTemperature` | number (°C) | 21 | Target temperature sent with a climate start (Home Assistant's button uses 21). The API's accepted range is not documented in the sources; **Recommendation:** clamp to 16-27 and send as a number. |
| `maxCallsPerHour` | integer | 60 | The hourly request budget the poll interval is computed from (6.1). |
| `pollInterval` | integer (s) | computed | Override of the computed interval; never below the computed one unless the person insists (a lower value risks the quota). |
| `refreshLocation` | bool | false | Ask the car to report its position (`actions/refresh-location`) before a location read. Off by default: it is an action sent to the car. |

Accessory Settings (by Device Id = VIN): the Core ones, plus **Recommendation** Parts (GLOSSARY "Part") for the optional
services of 5.2: `Climate`, `Charging`, `PluggedIn`, `Horn`, `Lights`, `InteriorTemperature`, `ExteriorTemperature`,
`Doors` (only offered when the endpoint exists for the model).

Setup: `accountAuthorization = accountLogin` (e-mail, password, and a one-time code when Gigya asks for one), account
required. `discover()` lists the account's vehicles (Device Id = VIN, name = registration plate or model label).

---

## 3. Authentication

### 3.1 Servers and public app keys (constants of the MyRenault app, as the library publishes them)

| Constant | Value |
|---|---|
| Gigya EU root | `https://accounts.eu1.gigya.com` |
| Gigya US root | `https://accounts.us1.gigya.com` |
| Gigya AU root | `https://gigya-prod-au1.renaultgroup.com` |
| Gigya EU API key | `3_VgdkgtIRH3AdHvJm-cjV2ug2EFE0lxt0IJzMC4MFqZjFpn_GYFXVdNZ19L7wZX0N` |
| Kamereon API key (every locale) | `YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J` |
| Kamereon EU root | `https://api-wired-prod-1-euw1.wrd-aws.com` |
| Kamereon US root | `https://api-wired-prod-1-usw2.wrd-aws.com` |
| Kamereon AU root | `https://api-wired-prod-1-apn1.wrd-aws.com` |
| Locale configuration base (fallback) | `https://renault-wrd-prod-1-euw1-myrapp-one.s3-eu-west-1.amazonaws.com` |

Locales the library knows. Unless noted, Gigya root = EU, Gigya key = the EU key, Kamereon root = EU:

`bg_BG`, `cs_CZ`, `da_DK`, `de_DE`, `de_AT`, `de_CH`, `en_GB`, `en_IE`, `es_ES`, `fi_FI`, `fr_FR`, `fr_BE`, `fr_CH`,
`hr_HR`, `hu_HU`, `it_IT`, `it_CH`, `nl_NL`, `nl_BE`, `no_NO`, `pl_PL`, `pt_PT`, `ro_RO`, `ru_RU`, `sk_SK`, `sl_SI`,
`sv_SE`, and these exceptions:

| Locale | Gigya root | Gigya API key | Kamereon root |
|---|---|---|---|
| `en_AU` | AU | `4_GC9iGd3sH8sMJpz2x0q0CQ` | AU |
| `es_MX` | US | `4_yTFqPSsGxVyRXPZUM7t1Iw` | US |
| `fr_LU` | EU | `3_zt44Wl_wT9mnqn-BHrR19PvXj3wYRPQKLcPbGWawlatFR837KdxSZZStbBTDaqnb` | EU |

Fallback for a locale not in the list: GET `<locale configuration base>/configuration/android/config_<locale>.json`
(the server may answer with a wrong content type; parse the body as JSON regardless). Read `servers.gigyaProd.apikey`
(Gigya key), `servers.gigyaProd.target` (Gigya root), `servers.wiredProd.apikey` (Kamereon key),
`servers.wiredProd.target` (Kamereon root). An HTTP error means "locale not found". **Recommendation:** offer only the
listed locales in Setup; keep the fallback for a hand-written block.

`country` (sent with every Kamereon request) = the last two characters of the locale (`fr_FR` → `FR`), unless given.

### 3.2 Gigya calls

All Gigya calls answer JSON with `errorCode` (0 = success), `errorDetails`, often `errorMessage`, `statusCode`,
`statusReason`, `callId`, `time`. The library parses the body first and checks `errorCode` **before** the HTTP status
(Gigya answers errors with 403/400 statuses and a JSON body). A body that is not JSON is a Gigya error.

Never log Gigya request or response bodies (the library deliberately does not).

1. **Login**: POST `<gigyaRoot>/accounts.login`, form-encoded body (`application/x-www-form-urlencoded`) with
   `ApiKey` = Gigya key, `loginID` = e-mail, `password` = password. When remembered device ids exist (3.3), they are
   sent as cookies `gmid=<…>` and `ucid=<…>`. Success: `sessionInfo.cookieValue` is the **login token** (long-lived;
   `sessionInfo.cookieName` is present but unused). Missing `sessionInfo` or `cookieValue` is an error.
2. **Account info** (person id): POST `<gigyaRoot>/accounts.getAccountInfo`, form body `ApiKey`, `login_token` =
   login token. Read `data.personId` (missing is an error). Cached for the session.
3. **JWT**: POST `<gigyaRoot>/accounts.getJWT`, form body `ApiKey`, `login_token`, `fields` =
   `data.personId,data.gigyaDataCenter`, `expiration` = `900`. Read `id_token`: the JWT sent to Kamereon.

Gigya error codes the library names:

| `errorCode` | Meaning | Reaction |
|---|---|---|
| `403042` | invalid loginID or password | "invalid credentials" |
| `403101` | Pending Two-Factor Authentication; the body carries `regToken` | start the 2FA flow of 3.3 |
| `400006` | invalid parameter value; at the code step: wrong verification code | ask for the code again (same challenge) |
| `403005` (Unauthorized user), `403013` (Unverified user) | at getJWT | the login token is dead: forget login token, JWT and person id, report "authentication expired" |
| any other non-zero | generic Gigya error | at getJWT: "authentication expired" (keys kept); elsewhere: error |

### 3.3 Two-factor authentication (e-mail one-time code)

Gigya started enforcing 2FA for some accounts in 2026 (library issue #2132). The flow, all GETs with query parameters,
each also sending the device ids as cookies `gmid` and `ucid`:

1. Login (3.2.1) answers `403101` with `regToken`. Keep e-mail, password and `regToken` **in memory only**.
2. **Device ids**: if none are remembered, GET `<gigyaRoot>/accounts.webSdkBootstrap?APIKey=<key>`; the response's
   `Set-Cookie` headers carry `gmid` and `ucid`. Read them from this response (not from a shared cookie jar). Keep them.
3. **Init**: GET `<gigyaRoot>/accounts.tfa.initTFA` with `APIKey`, `regToken`, `provider` = `gigyaEmail`, `mode` =
   `verify`, and also `gmid` and `ucid` as query parameters. Read `gigyaAssertion`. (Done once per challenge, lazily.)
4. **E-mails**: GET `<gigyaRoot>/accounts.tfa.email.getEmails` with `APIKey`, `gigyaAssertion`. Read `emails[]`, each
   `id`, `obfuscated` (e.g. `e***@example.com`), sometimes `lastVerification`. Ignore entries without `id`. None means
   no address is registered (error). Several: the person picks one (show `obfuscated`).
5. **Send code**: GET `<gigyaRoot>/accounts.tfa.email.sendVerificationCode` with `APIKey`, `gigyaAssertion`,
   `emailID` = the chosen id, and `lang` = the locale's language part (`fr` for `fr_FR`) when known. Read `phvToken`.
6. **Verify**: GET `<gigyaRoot>/accounts.tfa.email.completeVerification` with `APIKey`, `gigyaAssertion`,
   `phvToken`, `code` = the code the person typed. Read `providerAssertion`. `400006` = wrong code: the challenge stays
   pending; the person may retry without a new code.
7. **Finalize**: GET `<gigyaRoot>/accounts.tfa.finalizeTFA` with `APIKey`, `gigyaAssertion`, `providerAssertion`,
   `regToken`, `tempDevice` = `false` to remember the device (about 30 days without a new code; the library's default),
   `true` otherwise. Answer has no token.
8. Log in again (3.2.1) with the same e-mail and password, sending the device ids as cookies: this now returns the login
   token.

Persist the device ids (`gmid`, `ucid`) next to the login token: a later password login with them skips 2FA while the
device is remembered.

**Setup mapping (Recommendation)**: step 1 asks locale (choice), e-mail, password (secret). On `403101`: if several
e-mails, step 2 asks which (choice of the obfuscated addresses); then send the code and ask for it (step 3, text field
"Code sent to e***@example.com"). Keep `regToken`, `gigyaAssertion`, `phvToken`, device ids and the chosen e-mail id in
the Setup `state`, never the password in clear outside the vault (the password itself arrives as a secret field and
may be needed again at step 8: keep it in `state`, which stays on the bridge). A wrong code throws `SetupError` and asks
again without resending. Outcome credentials: `loginToken`, `gmid`, `ucid`, and the password (so a dead token can be
replaced without the person); settings: `locale`, `username`, `kamereonAccountId`.

### 3.4 Session life

- The library keeps: login token (no expiry known), person id, JWT with its expiry, device ids.
- **JWT expiry**: decode the JWT payload (no signature check) and read `exp` (seconds since epoch). It counts as expired
  60 s before `exp` (clock skew margin). The library requests `expiration=900`, so a JWT lives about 15 minutes.
  An expired JWT is replaced on demand by a new getJWT call with the login token. One lock serialises getJWT and
  getAccountInfo so concurrent requests mint one JWT.
- A restored session: the library can be given a login token alone (Home Assistant stores it after the first
  successful login and uses it on every start instead of the password; it falls back to the password only when there is
  no token). Restoring a token clears person id and JWT.
- When getJWT fails the request fails with "authentication expired"; Home Assistant then starts re-authentication
  (password, maybe 2FA). The library does **not** retry a Kamereon call that answered `err.func.wired.unauthorized`
  (4.7); it is just an error.

**Recommendation for Homeswift**:
- Keep `loginToken`, `gmid`, `ucid` in the vault (Setup credentials or `context.secretFile("renault-session.json")`).
  Keep JWT and person id in memory only.
- On "authentication expired" (`403005`/`403013` at getJWT): try one password login with the stored device ids. If it
  gives a token, save it (`saveCredentials`) and go on. If it answers `403042` or `403101`, call
  `context.accountRefused(...)` ("The password was refused" / "Renault asks for a one-time code: set up the account
  again") and stop polling until Setup is redone.
- On a Kamereon `err.func.wired.unauthorized` or HTTP 401: drop the JWT, mint a new one, retry the request **once**.
- A Gigya or network failure that is not a refusal (timeouts, 5xx) is not a refusal: back off and retry later.

### 3.5 Kamereon person and accounts

GET `<kamereonRoot>/commerce/v1/persons/<personId>?country=<CC>` with the Kamereon headers (4.1). The answer is a
plain JSON object (no `data` wrapper). Fields used: `accounts[]`, each `accountId`, `accountType`, `accountStatus`.
Seen types: `MYRENAULT` and `SFDC`; status `ACTIVE`. Entries without `accountId` are skipped.

### 3.6 Choosing the account

Home Assistant asks for the vehicle list of every account (3.7) and keeps only accounts with at least one vehicle
whose details are known; with one such account it picks it, with several it asks the person. **Recommendation:**
the same, defaulting to the `MYRENAULT` account when several qualify; store it as `kamereonAccountId`. If the stored
account later answers `err.func.wired.forbidden` and is no longer among the person's accounts, the account was removed:
treat it as a refusal of the account (Needs Authorization) with that reason.

### 3.7 Vehicle list and details

- GET `<kamereonRoot>/commerce/v1/accounts/<accountId>/vehicles?country=<CC>`. Plain object: `accountId`, `country`,
  `vehicleLinks[]`. Each link: `vin`, `brand`, `status` (`ACTIVE`), `linkType` (`OWNER`), dates, `connectedDriver`,
  `preferredDealer`, and usually `vehicleDetails`.
- `vehicleDetails` fields used: `vin`, `registrationNumber` (plate), `radioCode` (sensitive), `brand.label`
  (`RENAULT`), `model.code` (`R5E1VE`), `model.label` (`RENAULT 5`), `energy.code` (`ELECX`), `engineEnergyType`,
  `assets[]` (pictures: `assetType` = `PICTURE`, `renditions[]` with `resolutionType` `ONE_MYRENAULT_SMALL` /
  `ONE_MYRENAULT_LARGE` and `url`). Other fields are present (battery code, family, tcu, gearbox, version, vcd ...).
- When a link has no `vehicleDetails`, GET `<kamereonRoot>/commerce/v1/accounts/<accountId>/vehicles/<vin>/details?country=<CC>`
  (plain object of the same shape). If that fails or is still missing (a new purchase, a server issue), the vehicle is
  skipped with a warning logged once per VIN (later times at debug).
- Home Assistant re-reads the vehicle list every **hour** to add new vehicles and remove gone ones; an empty list is
  treated as a server problem, not as "all vehicles removed".
- Optional (not used by Home Assistant): GET `<kamereonRoot>/commerce/v1/accounts/<accountId>/kamereon/kca/car-adapter/v2/cars/<vin>?country=<CC>`
  gives car-adapter data in `data.attributes`: `carGateway` (e.g. `GDC` for ZOE 1), `modelCodeDetail`, `energy`
  (`electric`, `gasoline`), `privacyMode`, `tcuCode`, ... A `carGateway` of `GDC` means charging power in watts.

---

## 4. Kamereon API

### 4.1 Request shape

- URL: `<kamereonRoot>` + path, query always includes `country=<CC>` (plus endpoint-specific parameters).
- Headers on **every** Kamereon request (GET and POST, kca and kcm alike):
  - `Content-type: application/vnd.api+json`
  - `apikey: <Kamereon API key>`
  - `x-gigya-id_token: <JWT>`
- POST bodies are JSON.
- No other headers are sent by the library (no User-Agent of its own beyond the HTTP client's).

### 4.2 Response handling (the order matters)

1. Read the body as text.
2. A body starting with `[` is wrapped as an object whose single key holds the array (`data` by default).
3. A body that does not start with `{`: if the HTTP status is an error, that HTTP error; otherwise "invalid JSON".
   (Kamereon sometimes answers an HTML 502 page.)
4. Parse the JSON. If it has a non-empty `errors` array, raise the error of the **first** entry (4.7), whatever the
   HTTP status.
5. Then, if the HTTP status is an error, raise it.
6. Otherwise succeed.

kca responses are JSON:API: `{"data": {"type": …, "id": <VIN or guid>, "attributes": {…}}}`. Missing `data` or
`attributes` reads as empty attributes (all fields absent), as in the "no data" sample of 8.10. kcm reads (`ev/settings`,
`ev/soc-levels`) answer **plain objects** without `data`.

All attribute fields can be missing; treat each as optional.

### 4.3 Reads (GET), fields, units, enums

**`battery-status`** (kca **v2**), `data.attributes`:

| Field | Type | Unit / meaning |
|---|---|---|
| `timestamp` | string | ISO 8601, last update from the car (may carry an offset) |
| `batteryLevel` | int | % state of charge |
| `batteryAutonomy` | int | km of range |
| `batteryTemperature` | int | °C (older cars only) |
| `batteryCapacity` | int | kWh, often 0 |
| `batteryAvailableEnergy` | int | kWh available (older cars; 0 when unknown) |
| `plugStatus` | int | see enum |
| `chargingStatus` | float | see enum |
| `chargingRemainingTime` | int | minutes |
| `chargingRemainingTimeLastUpdateDateTime` | string | ISO 8601 |
| `chargingInstantaneousPower` | float | **kW**, except ZOE phase 1 (`X101VE`, or `carGateway` `GDC`): **W** |
| `V2L_SystemStatusDisplay` | int | vehicle-to-load display state (0 seen); meaning undocumented |

`plugStatus` values: `0` unplugged, `1` plugged, `-1` plug error, `-2147483648` plug unknown.

`chargingStatus` values (floats; compare by value, not text):

| Value | Name |
|---|---|
| `0.0` | not in charge |
| `0.1` | waiting for a planned charge |
| `0.2` | charge ended |
| `0.3` | waiting for current charge |
| `0.4` | energy flap opened |
| `1.0` | charge in progress |
| `-1.0` | charge error (on ZE40 and earlier it means "not charging"; on ZE50 an error) |
| `-1.1` | unavailable |
| `-1.3` | V2G charging, waiting |
| `-1.4` | V2L connected |
| `-1.5` | V2G discharging |
| `-1.6` | V2G charging, normal |

An unknown value is logged once as a warning and read as "unknown" (not an error). **Recommendation:** compare with
a tolerance (round to one decimal) because JSON may give `0`, `0.0`, or `1`.

**`cockpit`** (kca v1): `totalMileage` (float, km; HA rounds to an integer), `fuelAutonomy` (km), `fuelQuantity`
(litres; `0.0` on an EV), sometimes `timestamp`.

**`hvac-status`** (kca v1): `hvacStatus` (string `on` / `off`), `externalTemperature` (float °C, older cars),
`internalTemperature` (float °C; present on one R5 sample, absent on another), `socThreshold` (float %: minimum battery
for remote climate), `nextHvacStartDate` (string), `lastUpdateTime` (ISO 8601).

**`location`** (kca v1): `gpsLatitude`, `gpsLongitude` (floats, degrees), `lastUpdateTime`.

**`lock-status`** (kca v1, not on R5): `lockStatus` (`locked` / `unlocked`), `doorStatusRearLeft`,
`doorStatusRearRight`, `doorStatusDriver`, `doorStatusPassenger`, `hatchStatus` (each `open` / `closed`),
`lastUpdateTime`. Some newer cars use other names; when the first set is missing, read respectively
`statusDoorRearLeft`, `statusDoorRearRight`, `statusDoorDriver`, `statusDoorPassenger`, `statusDoorTailGate`.

**`pressure`** (kca v1, not on R5): `flPressure`, `frPressure`, `rlPressure`, `rrPressure` (int, **mbar**), and
`flStatus` … `rrStatus` (int, meaning undocumented).

**`res-state`** (kca v1, remote engine start, thermal cars): `details` (text, e.g. "Stopped, ready for RES",
"Running"), `code` (string, e.g. `10`, `42`).

**`charge-mode`** (kca v1, not on R5): `chargeMode` string. Values the HA select offers: `always`, `always_charging`,
`schedule_mode`, `scheduled`.

**`charging-settings`** (kca v1, not on R5): `mode` (`always`, `delayed`, `delegated`, `scheduled`, case may vary; HA
lowercases), `schedules[]` (each `id`, `activated`, and per weekday `monday` … `sunday` an object `startTime` in the
form `Thh:mmZ` (UTC) and `duration` in minutes, or null), `startDateTime`, `dateTime`, `delay`.

**`soc-levels`** (kcm, plain object): `socMin` (int %), `socTarget` (int %), `lastEnergyUpdateTimestamp`.

**`charge-schedule` via `ev/settings`** (kcm, plain object; R5): `lastSettingsUpdateTimestamp`, `delegatedActivated`
(bool), `chargeModeRq` (`SCHEDULED`, `ALWAYS` seen), `chargeTimeStart` (`hh:mm`), `chargeDuration` (minutes),
`preconditioningTemperature` (number °C), `preconditioningHeatedStrgWheel`, `preconditioningHeatedRightSeat`,
`preconditioningHeatedLeftSeat` (bool), `programs[]` each: `programActivationStatus` (bool), `programType` (`CHARGE`,
`PRECONDITIONING`, `CHARGE_AND_PRECONDITIONING`), `programDepartureTime` (`hh:mm`), and `programActivationMonday` …
`programActivationSunday` (bool).

Not needed for HomeKit, present in the library: `hvac-settings` (`mode`, `schedules[]` with per-day `readyAtTime`),
`charges` and `hvac-sessions` (query `start`, `end` as `YYYYMMDD`), `charge-history` and `hvac-history` (query `type` =
`day` or `month`, `start`/`end` as `YYYYMMDD` or `YYYYMM`), `notification-settings`, `alerts`, and contracts (GET
`<kamereonRoot>/commerce/v1/accounts/<accountId>/vehicles/<vin>/contracts` with `country`, `locale`, `brand=RENAULT`,
`connectedServicesContracts=true`, `warranty=true`, `warrantyMaintenanceContracts=true`; answers an array, wrapped as
`contractList`).

### 4.4 Actions (POST): bodies

JSON:API shape `{"data": {"type": <Type>, "attributes": {…}}}` unless said otherwise. The answer echoes it with an
`id` (`guid`), e.g. `{"data": {"type": "HvacStart", "id": "…", "attributes": {"action": "start", "targetTemperature": 21.0}}}`.
A 200 with this echo only means the request was accepted by the backend; the car applies it later (or not).

| Action | Endpoint key | Body |
|---|---|---|
| Climate start | `actions/hvac-start` | type `HvacStart`, attributes `action` = `start`, `targetTemperature` = number; optional `startDateTime` = UTC `YYYY-MM-DDTHH:MM:SSZ` for a delayed start |
| Climate stop | `actions/hvac-stop` | type `HvacStart`, attributes `action` = `cancel`, **or `stop` when the model's mode is `kca-stop`** (R5, A290, Megane E-Tech, Spring, Spring MY25). On Spring MY25 "cancel" is accepted with 200 but does nothing. |
| Charge start (default kca) | `actions/charge-start` | type `ChargingStart`, attributes `action` = `start` |
| Charge start (mode `kcm`) | same key, kcm `charge/start` | type `ChargingStart`, attributes `action` = `start`, optional `startDateTime` (UTC, as above) |
| Charge start (mode `kcm-pause-resume`) | kcm `charge/pause-resume` | type `ChargePauseResume`, attributes `action` = `resume` |
| Charge start (mode `kcm-settings`, **R5**) | kcm `ev/settings` | see 4.6 |
| Charge stop (default kca) | `actions/charge-stop` | type `ChargingStart`, attributes `action` = `stop` |
| Charge stop (mode `kcm-pause-resume`) | kcm `charge/pause-resume` | type `ChargePauseResume`, attributes `action` = `pause` |
| Horn | `actions/horn-start` | type `HornLights`, attributes `action` = `start`, `target` = `horn` |
| Lights | `actions/lights-start` | type `HornLights`, attributes `action` = `start`, `target` = `lights` |
| Refresh location | `actions/refresh-location` | type `RefreshLocation`, **no** `attributes` |
| Charge mode | `actions/charge-set-mode` | type `ChargeMode`, attributes `action` = the mode string |
| Charge schedules | `actions/charge-set-schedule` | type `ChargeSchedule`, attributes `schedules` = list of `{id, activated, monday … sunday}` (each day `{startTime, duration}` or null) |
| Climate schedules | `actions/hvac-set-schedule` | type `HvacSchedule`, attributes `schedules` = list of `{id, activated, monday … sunday}` (each day `{readyAtTime}` or null) |
| SoC limits | `soc-levels` (POST to the kcm path) | **plain** object `{"socMin": <int>, "socTarget": <int>}`; answer is plain too: `commandId`, `type` = `SOC_SYNCH`, `status` = `CREATED` |

SoC limit rules (library and HA): `socMin` 15…45 in steps of 5, `socTarget` 55…100 in steps of 5; both must be sent
together, so changing one reads the other from the last `soc-levels` read. After a write HA shows the new values at once
(optimistic, marked assumed) because the server keeps returning the old values for a while.

### 4.5 Unsupported actions

An action whose endpoint key resolves to "none" for the model is refused locally ("endpoint not available for model
X") without a request. For the R5: charge stop, charge mode, charge and climate schedules.

### 4.6 Charge start on the R5 (mode `kcm-settings`)

What the MyRenault app does (library issue #1348), and the library copies:

1. GET `/kcm/v1/vehicles/{vin}/ev/settings` (plain object, 4.3).
2. In that object, set `programActivationStatus` to `false` in **every** entry of `programs` (when `programs` exists).
   Change nothing else (in particular `chargeModeRq` is sent back as it was read).
3. POST the whole modified object back to the same path (plain JSON, not JSON:API).

Disabling all scheduled programs makes the car charge at once when plugged. The server's answer seen in the fixtures
is a plain object such as `{"chargeModeRq": "ALWAYS", "programs": []}`. Side effect: the person's departure programs
are turned off and stay off; the library does not restore them. There is no matching "stop": the R5 cannot be told
to stop charging (unplug, or stop from the charger).

**Recommendation:** before step 3, remember the programs' activation flags (in memory, per VIN). Do not restore them
automatically (the source does not, and restoring could stop the charge); offer nothing more in HomeKit. Log at info
level that charging was started by turning the departure programs off.

### 4.7 Errors

An error entry has `errorCode` (string) and `errorMessage`; the body also has `type` (`FUNCTIONAL`/`TECHNICAL`),
`messages[]` with `code`/`message`, and sometimes `error_reference`. `errorMessage` may itself be a JSON text with an
`errors[]` array; the readable detail is, per inner error, its `title`, `source.pointer` and `detail` joined with spaces,
and the inner errors joined with ", "; when it is not JSON, `errorMessage` as is.

| `errorCode` | Library meaning | Home Assistant reaction |
|---|---|---|
| `err.func.400` | invalid input (e.g. "must be a future date" at `/data/attributes/startDateTime`) | error |
| `err.func.403` | access denied (inner codes like `security.access`, `403011` "Operation not supported for this can (C1A)") | first poll of an endpoint: drop that endpoint for good; later: temporary error |
| `err.tech.500` | invalid upstream response (e.g. the GDC 502) | error |
| `err.tech.501` | not supported by this gateway | drop the endpoint for good, at any time |
| `err.func.wired.notFound` | resource not found | error |
| `err.tech.wired.kamereon-proxy` | failed to forward to the remote service | error |
| `err.func.wired.overloaded` | **quota reached** ("You have reached your quota limit") | 15-minute cool-down of every poll (6.2) |
| `err.func.privacy.on` | the car's privacy mode is on | error |
| `err.func.wired.forbidden` | forbidden | error (an endpoint the model refuses; the per-model table should already exclude it) |
| `err.func.wired.unauthorized` | JWT expired or revoked | error (see 3.4 Recommendation: refresh and retry once) |
| `409001` | a remote charge-mode change is already in progress | error |
| `err.func.wired.low.battery.level` | battery too low for the action ("minimum required is 30%") | error |
| anything else | generic Kamereon error with the code and detail | error |

Other codes seen in the per-model notes: `err.func.wired.not-found`, `err.func.wired.invalid-body`,
`err.func.wired.invalid-body-format`, `err.func.wired.methodNotAllowed`, `err.func.wired.missingRequestParam`,
`err.func.vcps.ev.charge-mode.error`, `err.func.vcps.ev.charge-schedule.error`, `err.tech.vcps.ev.hvac-settings.error`,
`502000`, `400001` ("The vehicle does not have a GDC gateway"), HTTP 404 "There is no data for this vin and uid".

**Recommendation:** treat `err.tech.501`, `err.func.wired.forbidden`, `err.func.wired.notFound`,
`err.func.wired.not-found`, `400001` and HTTP 404 on the **first** read of an endpoint as "this car does not have it":
stop polling it and leave its service out (or mark the Part unavailable). Treat `err.func.403` the same on the first
read only (HA's rule). After an endpoint has worked once, any error is temporary.

### 4.8 Rate limits

There is no published quota. Home Assistant's working assumption: **60 calls per hour** for one account, which with
7 pollers for one car is one round every 7 minutes. The quota error is `err.func.wired.overloaded`. The library itself
does not retry or throttle; Home Assistant does (6.2).

---

## 5. HomeKit mapping

### 5.1 What Home Assistant exposes (per vehicle; device name = registration plate, manufacturer = brand label
capitalised, model = model label capitalised, model id = model code)

Binary sensors: plugged in (battery: `plugStatus == 1`; when `plugStatus` is absent, true if `chargingStatus` is one of
1.0, 0.3, 0.2, -1.6, -1.3, -1.5, 0.1); charging (`chargingStatus == 1.0`); HVAC on (`hvacStatus == "on"`); lock (on =
`lockStatus == "unlocked"`); hatch and four doors (on = `open`).

Sensors: battery level %, charge state (enum names of 4.3 in lower snake case), charging remaining time (min),
charging power (kW, or W for ZOE 1), plug state, battery autonomy (km), available energy (kWh), battery temperature
(°C), battery last activity (timestamp, hidden by default), mileage (km, rounded), fuel autonomy and quantity (fuel
cars only), outside temperature (°C), HVAC SoC threshold (%), HVAC and location last activity (hidden by default),
remote engine start state and code, charging-settings mode, four tyre pressures (mbar). It has no sensor for
`internalTemperature`.

Buttons: start air conditioner (always 21 °C), start charge, stop charge, sound horn, flash lights (each only when the
model supports the endpoint; charge buttons only for electric cars). Select: charge mode. Numbers: SoC minimum
(15-45 step 5) and target (55-100 step 5). Device tracker: location. Services: climate start with temperature and
optional time, climate cancel, climate and charge schedules, charge start (optional time).

### 5.2 Homeswift (Recommendation)

One accessory per vehicle (bridged), Device Id = VIN, Accessory Id `Renault:<VIN>`. Aids and iids follow the usual
stable keys. Name = the registration plate when present, else the model label ("Renault 5"). Accessory Information:
Manufacturer = brand label capitalised ("Renault"), Model = model label ("Renault 5"), SerialNumber = VIN,
Firmware = plugin version. Services are added only when the endpoint resolves for the model **and** has not been
dropped by 4.7's first-read rule, and the Part is included.

| Service (subtype) | From | Characteristics and behaviour |
|---|---|---|
| **Battery** (primary for EVs) | `battery-status` | BatteryLevel = `batteryLevel` (clamped 0-100). ChargingState: 1 (charging) when `chargingStatus` is 1.0 or -1.6; 0 otherwise; 2 (not chargeable) never. StatusLowBattery = 1 when `batteryLevel` < `socMin` if known, else < 20. |
| **Switch "Climate"** (`Climate`) | `hvac-status`, `actions/hvac-start`, `actions/hvac-stop` | On = `hvacStatus == "on"`. Write On: climate start with `climateTemperature`. Write Off: climate stop (with `stop` or `cancel` per mode). If hvac-stop is "none" for the model, Off is answered as success and only logged ("this car stops climate on its own"). |
| **Switch "Charging"** (`Charging`) | `battery-status`, `actions/charge-start`, `actions/charge-stop` | On = charging (as the Battery's ChargingState). Write On: charge start (4.4 / 4.6); refused with HAP "not allowed in current state" (-70412 / read-only error) when the car is not plugged in (`plugStatus` 0), without a request. Write Off: charge stop when the model has one; when it is "none" (R5), revert the characteristic to the read state and log that the car cannot be told to stop. Only for electric cars. |
| **Contact Sensor "Plugged in"** (`PluggedIn`) | `battery-status` | ContactSensorState 0 (contact detected) when plugged in by HA's rule of 5.1, 1 when unplugged; unknown/error leaves the last value and sets StatusFault = 1. |
| **Temperature Sensor "Interior"** (`InteriorTemperature`) | `hvac-status.internalTemperature` | Only once a value has been seen. |
| **Temperature Sensor "Exterior"** (`ExteriorTemperature`) | `hvac-status.externalTemperature` | Only once a value has been seen (not on R5). |
| **Stateless switch "Horn"** (`Horn`) and **"Lights"** (`Lights`) | `actions/horn-start`, `actions/lights-start` | A Switch that, written On, sends the action and turns itself Off after about 1 s. Horn off by default as a Part (it sounds in the street). |
| **Contact Sensors "Doors", "Hatch"** (`Doors`) | `lock-status` (not on R5) | Driver, passenger, rear left, rear right, hatch: ContactSensorState 1 when `open`. |
| **Lock Mechanism (read-only)** | `lock-status` (not on R5) | There is **no lock or unlock action** in the API the library knows; do not expose a writable Lock. If exposed at all, a read-only state through a Contact Sensor "Locked" is safer. Skip on cars without `lock-status`. |

Not in HomeKit (no fitting characteristic): range (km), mileage, remaining charge time, charge power, location, SoC
limits, charge mode. **Recommendation:** show them on the plugin's web page and in the accessory's details (Homeswift
widgets), and expose the SoC limits as Plugin Accessory Settings or plugin page controls rather than abusing a
Lightbulb's brightness. Charging power, when a car reports it, may be tagged for the Status page's Energy section with an
`EnergyRole` of consumption (kW → W); the R5 samples never report it.

Security: none of these services is a lock, garage door or alarm; horn, lights and climate are ordinary writes.
**Recommendation:** still mark Horn and Charging start as needing the MCP server's confirmation (they act on a real car
in public, and charging changes the person's programs on an R5).

---

## 6. Behaviour

### 6.1 Polling (what Home Assistant does)

- One poller per endpoint per vehicle, among: `cockpit`, `hvac-status`, `location`, `battery-status` (electric),
  `charge-mode` (electric), `charging-settings` (electric), `lock-status`, `res-state`, `pressure`, `soc-levels`
  (electric). A poller exists only if the model supports the endpoint (1.3). For an R5 that leaves **5**: cockpit,
  hvac-status, location, battery-status, soc-levels.
- **Interval** = 3600 × N / (maxCallsPerHour − 1) seconds, N = the number of pollers of **all** vehicles of the account
  (one call per hour is kept for the vehicle list). With the default 60: one R5 → 3600×5/59 ≈ 305 s (5 min 5 s); a
  first estimate uses all 10 pollers per vehicle until the first reads drop the unsupported ones, then it is recomputed.
- **One request at a time**: a single process-wide semaphore serialises every Kamereon request of every poller and the
  vehicle list.
- The vehicle list is refreshed every hour.
- Action calls are serialised too (HA allows one action in flight per entity platform: "renault servers are
  unreliable").

**Recommendation for Homeswift:** the same budget and formula, one serial request queue per account, the vehicle list
hourly. Poll `battery-status` more often while charging if the budget allows (e.g. give it a double share), never
`location` more than the base rate. After an action, read the related endpoint once after about 60 s and again after
about 3 minutes (the car takes time to wake and report), within the budget; until then keep the written value
(optimistic, as HA does for SoC limits).

### 6.2 Throttling

On `err.func.wired.overloaded` from any request: record the time; for the next **15 minutes** every poll is skipped and
answers its last data (marked as assumed state; a poller that never worked fails instead). The vehicle list is skipped
too. After 15 minutes polling resumes. **Recommendation:** the same; also stop sending actions during the cool-down
(answer HomeKit with "service communication failure").

### 6.3 First read and endpoint dropping

At start every poller does one read. A poller whose first read fails with "not supported" (`err.tech.501`) or
"access denied" (`err.func.403`) is removed for good with a warning ("Ignoring endpoint … as it is not supported / as it
is denied"), and the interval is recomputed. "Not supported" later also stops the poller. Access denied after it has
worked once is a temporary error. A failing first read of another kind leaves the poller in place (HA does not fail
the whole set-up for it). **Recommendation:** extend the drop rule as in 4.7, and remember dropped endpoints per VIN in
the plugin's storage (not secret) so a restart does not spend the budget rediscovering them; forget the list when the
model code changes or once a week.

### 6.4 Caching

- Vehicle details: read once with the list and cached per vehicle; the model code decides endpoints.
- Person id and JWT: cached in memory (3.4).
- Last data of each endpoint: kept and served to HomeKit GETs; no network access on a HomeKit read.
- A HomeKit read of data that has never been fetched answers "No Response" only if the vehicle has never been read at
  all; otherwise the last value.

### 6.5 Availability

Failures of a single endpoint do not make the accessory unreachable. **Recommendation:** mark the accessory Not
responding (StatusFault on its sensors, errors on switch writes) only when every endpoint has failed for more than three
intervals; authentication refusal is shown through Needs Authorization, not as an unreachable accessory.

### 6.6 Times

All timestamps are ISO 8601, usually UTC with `Z`, sometimes with an offset (`+01:00`), sometimes with fractional
seconds (`2025-12-30T17:03:18.644879Z`). Times inside kca schedules are `Thh:mmZ` (UTC); inside kcm settings `hh:mm`
(local time of the car, per the app). Durations are minutes (ZOE 1 charge history in minutes vs seconds is irrelevant
here).

---

## 7. Logging and secrets

- Secrets: the password, the Gigya login token, the JWT, `regToken`, `gigyaAssertion`, `phvToken`,
  `providerAssertion`, the one-time code, the device ids `gmid`/`ucid`. Never log them, never log Gigya bodies (the
  library logs none). The vault holds password, login token and device ids; JWT and the 2FA tokens live in memory /
  the Setup state only.
- Personal data (Home Assistant's diagnostics redact them): `username` (e-mail), `kamereonAccountId`, `vin`,
  `registrationNumber`, `radioCode`, `gpsLatitude`, `gpsLongitude`. **Recommendation:** never log coordinates or the
  radio code; log a VIN only shortened (first 3 and last 4 characters); the account id only at debug.
- The library logs every Kamereon request body and response text at **debug** level (this exposes VIN, plate and
  coordinates in a debug log). **Recommendation:** at debug, log the endpoint key, HTTP status and error code only;
  bodies only in the HAP-style trace mode, with the personal fields masked.
- Warnings worth logging once: unknown model code, undocumented endpoint for a model, unknown enum value, vehicle without
  details, endpoint dropped, throttled.
- The `password` key is secret-named (sealed by the runtime). The login token and device ids go through Setup
  credentials or `context.secretFile`, never `jsonFile`.

---

## 8. Test vectors (invented VINs, ids and tokens)

### 8.1 Locale resolution

`pt_PT` → Gigya `https://accounts.eu1.gigya.com`, key `3_VgdkgtIRH3AdHvJm-cjV2ug2EFE0lxt0IJzMC4MFqZjFpn_GYFXVdNZ19L7wZX0N`,
Kamereon `https://api-wired-prod-1-euw1.wrd-aws.com`, key `YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J`, country `PT`.
`en_AU` → Gigya `https://gigya-prod-au1.renaultgroup.com`, key `4_GC9iGd3sH8sMJpz2x0q0CQ`, Kamereon
`https://api-wired-prod-1-apn1.wrd-aws.com`, country `AU`.

### 8.2 Gigya login

Request: POST `https://accounts.eu1.gigya.com/accounts.login`, form body
`ApiKey=3_Vgdk…&loginID=driver%40example.com&password=…`.
Answer (trimmed): `{"callId":"c1","errorCode":0,"apiVersion":2,"statusCode":200,"statusReason":"OK","sessionInfo":{"cookieName":"glt_x","cookieValue":"LT-example-login-token"}}`
→ login token `LT-example-login-token`.

Wrong password: HTTP 403, `{"errorCode":403042,"errorDetails":"invalid loginID or password","errorMessage":"Invalid LoginID","statusCode":403}` → invalid credentials.

2FA needed: HTTP 403, `{"errorCode":403101,"errorDetails":"Pending Two-Factor Authentication","statusCode":403,"regToken":"RT-example"}`.

### 8.3 Account info and JWT

`accounts.getAccountInfo` answer: `{"errorCode":0,"data":{"personId":"person-0001","gigyaDataCenter":"eu1"}}` → person `person-0001`.
`accounts.getJWT` (form body `ApiKey=…&login_token=LT-example-login-token&fields=data.personId%2Cdata.gigyaDataCenter&expiration=900`)
answer: `{"errorCode":0,"id_token":"<JWT>"}`. A JWT whose payload is `{"exp": 1767225600}` (2026-01-01T00:00:00Z) counts
as expired from 2025-12-31T23:59:00Z.
Dead token: `{"errorCode":403005,"errorDetails":"Unauthorized user","statusCode":403}` → forget token, authentication expired.

### 8.4 2FA

`accounts.tfa.initTFA?APIKey=…&regToken=RT-example&provider=gigyaEmail&mode=verify&gmid=G1&ucid=U1` →
`{"errorCode":0,"gigyaAssertion":"GA-1"}`.
`accounts.tfa.email.getEmails?APIKey=…&gigyaAssertion=GA-1` → `{"errorCode":0,"emails":[{"id":"E-1","obfuscated":"d***@example.com"}]}`.
`accounts.tfa.email.sendVerificationCode?APIKey=…&gigyaAssertion=GA-1&emailID=E-1&lang=pt` → `{"errorCode":0,"phvToken":"PHV-1"}`.
`accounts.tfa.email.completeVerification?APIKey=…&gigyaAssertion=GA-1&phvToken=PHV-1&code=123456` →
`{"errorCode":0,"providerAssertion":"PA-1"}`; wrong code → `{"errorCode":400006,"errorDetails":"Wrong verification code","statusCode":400}`.
`accounts.tfa.finalizeTFA?APIKey=…&gigyaAssertion=GA-1&providerAssertion=PA-1&regToken=RT-example&tempDevice=false` →
`{"errorCode":0}`; then login again with cookies `gmid=G1; ucid=U1`.

### 8.5 Person and vehicles

GET `https://api-wired-prod-1-euw1.wrd-aws.com/commerce/v1/persons/person-0001?country=PT`, headers
`Content-type: application/vnd.api+json`, `apikey: YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J`, `x-gigya-id_token: <JWT>` →
`{"personId":"person-0001","accounts":[{"accountId":"acc-myr-1","accountType":"MYRENAULT","accountStatus":"ACTIVE"},{"accountId":"acc-sfdc-1","accountType":"SFDC","accountStatus":"ACTIVE"}]}`.

GET `…/commerce/v1/accounts/acc-myr-1/vehicles?country=PT` →

    {"accountId":"acc-myr-1","country":"PT","vehicleLinks":[{"brand":"RENAULT","vin":"VF1TEST0000000001","status":"ACTIVE","linkType":"OWNER",
      "vehicleDetails":{"vin":"VF1TEST0000000001","registrationNumber":"AA-00-AA","brand":{"label":"RENAULT"},
        "model":{"code":"R5E1VE","label":"RENAULT 5","group":"971"},"energy":{"code":"ELECX","label":"ELECTRICITY","group":"019"}}}]}

→ one vehicle, model R5E1VE, electric; accessory "AA-00-AA", Model "Renault 5", Device Id `VF1TEST0000000001`.

### 8.6 R5 reads

Battery: GET `…/commerce/v1/accounts/acc-myr-1/kamereon/kca/car-adapter/v2/cars/VF1TEST0000000001/battery-status?country=PT` →

    {"data":{"id":"VF1TEST0000000001","attributes":{"timestamp":"2026-05-01T06:07:54Z","batteryLevel":73,"batteryAutonomy":261,
      "V2L_SystemStatusDisplay":0,"plugStatus":0,"chargingStatus":0.0,"chargingRemainingTime":3,
      "chargingRemainingTimeLastUpdateDateTime":"2026-04-30T16:16:10Z"}}}

→ BatteryLevel 73, ChargingState 0, unplugged (Contact 1), range 261 km, Charging switch Off.

Charging sample (older car shape): `"batteryLevel":60,"batteryTemperature":20,"batteryAutonomy":141,"batteryAvailableEnergy":31,"plugStatus":1,"chargingStatus":1.0,"chargingRemainingTime":145,"chargingInstantaneousPower":27.0`
→ 60 %, charging, plugged, 145 min left, 27 kW (W only for ZOE 1).

Cockpit: `{"data":{"id":"VF1TEST0000000001","attributes":{"fuelQuantity":0.0,"totalMileage":1253,"timestamp":"2026-05-01T06:05:24Z"}}}` → 1253 km.

HVAC: `{"data":{"id":"VF1TEST0000000001","attributes":{"internalTemperature":15.0,"hvacStatus":"off","socThreshold":15.0,"lastUpdateTime":"2025-03-24T18:57:22Z"}}}`
→ Climate Off, interior 15 °C, climate needs ≥ 15 % battery.

Location: `{"data":{"id":"VF1TEST0000000001","attributes":{"lastUpdateTime":"2026-05-01T06:05:24Z","gpsLatitude":48.8584,"gpsLongitude":2.2945}}}`.

SoC levels: GET `…/kamereon/kcm/v1/vehicles/VF1TEST0000000001/ev/soc-levels?country=PT` → `{"lastEnergyUpdateTimestamp":"2025-04-18T06:51:09Z","socMin":20,"socTarget":80}` (plain object).

### 8.7 R5 actions

Climate start: POST `…/kamereon/kca/car-adapter/v1/cars/VF1TEST0000000001/actions/hvac-start?country=PT`, body
`{"data":{"type":"HvacStart","attributes":{"action":"start","targetTemperature":21}}}` → echo with `"id":"guid"`.

Climate start at a time: attributes also `"startDateTime":"2026-11-05T06:30:00Z"`. A past time answers
`err.func.400` with detail "Future /data/attributes/startDateTime must be a future date" (title absent, so: pointer and
detail joined).

Climate stop (R5, mode `kca-stop`): same URL, `{"data":{"type":"HvacStart","attributes":{"action":"stop"}}}`.
On a default-mode car (R4): `"action":"cancel"`.

Charge start (R5): GET `…/kamereon/kcm/v1/vehicles/VF1TEST0000000001/ev/settings?country=PT` →

    {"lastSettingsUpdateTimestamp":"2025-04-24T12:17:12.247Z","delegatedActivated":false,"chargeModeRq":"SCHEDULED",
     "chargeTimeStart":"00:00","chargeDuration":9000,"preconditioningTemperature":20.0,
     "preconditioningHeatedStrgWheel":false,"preconditioningHeatedRightSeat":false,"preconditioningHeatedLeftSeat":false,
     "programs":[{"programActivationStatus":true,"programType":"CHARGE_AND_PRECONDITIONING","programDepartureTime":"02:00",
       "programActivationMonday":true,"programActivationTuesday":true,"programActivationWednesday":true,
       "programActivationThursday":true,"programActivationFriday":true,"programActivationSaturday":true,
       "programActivationSunday":true}]}

then POST the same URL with the identical object except `"programActivationStatus":false`. With `"programs":[]` the
object is posted back unchanged. Server answer seen: `{"chargeModeRq":"ALWAYS","programs":[]}`.

Charge start on a `kcm` car (Megane E-Tech): POST `…/kcm/v1/vehicles/<vin>/charge/start`,
`{"data":{"type":"ChargingStart","attributes":{"action":"start"}}}` (optionally `"startDateTime":"2026-03-06T23:45:00Z"`).
Charge stop on a ZOE phase 2: POST `…/kcm/v1/vehicles/<vin>/charge/pause-resume`,
`{"data":{"type":"ChargePauseResume","attributes":{"action":"pause"}}}`.

Horn: POST `…/kca/car-adapter/v1/cars/VF1TEST0000000001/actions/horn-lights`,
`{"data":{"type":"HornLights","attributes":{"action":"start","target":"horn"}}}`; lights: same with `"target":"lights"`.

Refresh location: POST `…/kca/car-adapter/v1/cars/VF1TEST0000000001/actions/refresh-location`, `{"data":{"type":"RefreshLocation"}}`.

SoC limits: POST `…/kcm/v1/vehicles/VF1TEST0000000001/ev/soc-levels`, `{"socMin":20,"socTarget":85}` →
`{"commandId":"commandId-1234","type":"SOC_SYNCH","status":"CREATED"}`. `socMin` 10 or `socTarget` 82 are refused locally.

Charge stop on R5: refused locally, no request.

### 8.8 Errors

Quota: `{"type":"FUNCTIONAL","messages":[{"code":"err.func.wired.overloaded","message":"You have reached your quota limit"}],"errors":[{"errorCode":"err.func.wired.overloaded","errorMessage":"You have reached your quota limit","errorType":"functional"}]}`
→ 15-minute cool-down.

Not supported: `{"errors":[{"errorCode":"err.tech.501","errorMessage":"{\"errors\":[{\"status\":\"501\",\"code\":\"error.internal\",\"detail\":\"This feature is not technically supported by this gateway\"}]}"}]}`
→ detail "This feature is not technically supported by this gateway"; drop the endpoint.

Access denied with title: errorMessage inner error `{"status":"403","code":"403011","title":"Operation not supported","detail":"Operation not supported for this can (C1A)"}`
→ detail "Operation not supported Operation not supported for this can (C1A)".

Forbidden: `{"errors":[{"errorCode":"err.func.wired.forbidden","errorMessage":"The access is forbidden"}]}`.
Unauthorized: `{"errors":[{"errorCode":"err.func.wired.unauthorized","errorMessage":"The access is unauthorized"}]}` → refresh JWT, retry once.
Low battery: `{"errors":[{"errorCode":"err.func.wired.low.battery.level","errorMessage":"Insufficient Battery Level, the minimum required is 30%"}]}`.
Charge mode busy: `{"errors":[{"errorCode":"409001","errorMessage":"A remote CHARGE_MODE is already in progress"}]}`.
Privacy: `{"errors":[{"errorCode":"err.func.privacy.on","errorMessage":"Privacy mode currently ON"}]}`.
An HTML body with HTTP 502 → the HTTP error (not "invalid JSON").

### 8.9 Poll interval

One R5 (5 endpoints), 60 calls/hour → 305.08 s. Two R5s (10) → 610.17 s. One ZOE phase 2 with battery, cockpit,
hvac-status, location, charging-settings, pressure (6) → 366.10 s.

### 8.10 Empty data

`{"data":{"type":"ChargeMode","id":"VF1TEST"}}` (no `attributes`) → every field absent; not an error.

### 8.11 Lock-status aliases

`{"data":{"id":"VF1TEST0000000002","attributes":{"lockStatus":"locked","statusDoorDriver":"closed","statusDoorPassenger":"closed","statusDoorRearLeft":"closed","statusDoorRearRight":"open","statusDoorTailGate":"closed","lastUpdateTime":"2026-10-20T18:32:24Z"}}}`
→ locked, rear right door open (read from `statusDoorRearRight`), hatch closed.

---

## 9. Gaps and hard parts

1. **2FA through Setup.** The login may stop at `403101` and need an e-mailed code, with a multi-call Gigya dance whose
   tokens (regToken, gigyaAssertion, phvToken) and the device ids must survive between Setup steps (Setup `state`),
   ending with a second password login. A later token death at run time may need the code again, which only a person
   can give: the plugin must turn that into Needs Authorization, not a retry loop.
2. **Per-model endpoint table.** Behaviour depends on the model code, and new models appear (unknown codes fall back to
   kca defaults that may well fail). The table of 1.3 must be data in the plugin, plus the first-read drop rule, plus
   remembering dropped endpoints.
3. **R5 charge start rewrites the person's settings** (turns off every departure program) and there is **no charge
   stop**. The Charging switch is asymmetric; HomeKit users will expect Off to work. The settings change is
   persistent and not restored by the source.
4. **Quota.** No published limit; ~60 calls/hour assumed, shared across vehicles and across every client of the same
   account (the MyRenault app counts too). Serial requests, the computed interval and the 15-minute cool-down are
   required; post-action confirmation reads must fit in the same budget.
5. **Stale and slow data.** The backend echoes actions immediately but the car applies them later (or never, e.g.
   Spring MY25 accepting "cancel" without effect), and reads may return old values (HA's optimistic SoC display).
   Switches need optimistic state with a time-out.
6. Undocumented details: the accepted `targetTemperature` range, the meaning of `V2L_SystemStatusDisplay`,
   `pressure` statuses, whether `chargeModeRq` must become `ALWAYS` in the R5 POST (the source does not change it; the
   server's answer shows `ALWAYS`), Gigya login-token lifetime, and HTTP timeouts (the library uses the HTTP client's
   defaults; **Recommendation:** 30 s per request).
7. `plugStatus` options in HA list a `plugged_waiting_for_charge` state the enum does not have; ignore it.
8. Float enum for `chargingStatus` (compare numerically with tolerance; negative codes for V2G/V2L).
9. Older cars only: kW vs W for charging power (ZOE 1), tyre pressure, lock-status aliases; not needed for the R5 but
   cheap to support.
10. No Homebridge plugin exists, so there is no existing config block or accessory identity to stay compatible with;
    the platform name `Renault` and the VIN as Device Id are new decisions (record the identity in the README).
