# GoogleNestSDM — functional specification

## 0. Provenance

- Source: https://github.com/potmat/homebridge-google-nest-sdm (npm package `homebridge-google-nest-sdm`, version 1.1.25).
- Commit read: `2529dedf8acc01af4e322bfdb3c9f108d0ecee64` (2026-10-29, Ted Potma).
- License: ISC. The LICENSE file's copyright line names "Andreas Bauer" (2020), the author of the Homebridge plugin template the project started from; the repository and the npm package belong to Ted Potma (GitHub `potmat`). A port should credit both in its notices.
- Public references: Google Device Access documentation (developers.google.com/nest/device-access): "Project limits", "CameraLiveStream trait", "Events", "Authorize an account", "Subscribe to events".
- This spec was written by the spec writer and contains no source code. The repository's two placeholder JPEGs (a Nest logo and a Google logo, both 1920x1080) are brand marks: do not reuse them. Ship your own neutral placeholder image.

Where this spec says "the source does X" and X is a bug, the bug is flagged as **[source bug]**, with what a drop-in replacement should do instead. Where a replacement has to match the source exactly (ids, names, config keys), it says so.

---

## 1. Configuration interface

### 1.1 Platform

- Platform name, i.e. the `platform` value in config.json: **`homebridge-google-nest-sdm`**. It is the same as the npm package name. A Homeswift port keeps this platform name, so a user's block loads as it is.
- Type: dynamic platform, singular (one instance only).
- The config UI's header points users at the README's setup section and tells them to read the warning about the authorization URL (section 2.2).

### 1.2 Options

| JSON key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `clientId` | string | yes | – | OAuth 2.0 client ID of the user's Google Cloud project (looks like `NNNN-xxxx.apps.googleusercontent.com`). |
| `clientSecret` | string | yes | – | OAuth 2.0 client secret. **Secret.** |
| `projectId` | string | yes | – | Device Access project ID (a UUID from the Device Access Console). Used in `enterprises/{projectId}` and, when `gcpProjectId` is absent, as the Pub/Sub client's project. |
| `refreshToken` | string | yes | – | OAuth refresh token the user got by hand (section 2). **Secret.** |
| `subscriptionId` | string | yes | – | Fully qualified Pub/Sub subscription name: `projects/<gcp-project-id>/subscriptions/<subscription-id>`. |
| `gcpProjectId` | string | no | falls back to `projectId` | The Google Cloud project ID. Only used as the Pub/Sub client's project. The README suggests filling it in when subscribing to events fails. Because `subscriptionId` is fully qualified, it has little effect in practice. |
| `vEncoder` | string | no | `libx264 -preset ultrafast -tune zerolatency` | The FFmpeg video encoder **and its options** for live streams, spliced verbatim into the argument list and split on whitespace. The exact value `copy` turns transcoding off (section 6.4). README suggestions: `copy`, `h264_v4l2m2m` on a Raspberry Pi 4. Not used for HKSV recordings, which always use libx264. |
| `showFan` | boolean | no | false (absent) | When true, each thermostat gets a second accessory: a Fan (section 5.2). |
| `fanDuration` | integer | no | schema UI default 900; at runtime **absent means unset** | How many seconds the fan timer runs when the fan is turned on. Valid range is 1 to 43200. The UI shows it only when `showFan` is true. |
| `analyzeDuration` | integer | no | 15000000 | FFmpeg `-analyzeduration` (microseconds) for live and recording inputs. |
| `probeSize` | integer | no | 100000000 | FFmpeg `-probesize` (bytes) for live and recording inputs. |

The schema marks the required fields as required. The README's example shows the optional values as strings (`"showFan": "<optional>"`), so a tolerant reader should accept `"true"`/`"false"` strings and numeric strings for these.

Startup validation: if any of `projectId`, `clientId`, `clientSecret`, `refreshToken` or `subscriptionId` is missing or empty, the platform logs a configuration error and does nothing else: no accessories are created and none are removed. **[source bug]** That error line includes the whole configuration block as JSON, secrets included. A replacement must not do this. It should name the missing keys instead.

Debug mode: the source turns on extra FFmpeg verbosity when Homebridge runs with `-D`/`--debug`. The Homeswift equivalent is the bridge's debug log level.

---

## 2. Authentication

### 2.1 What the user has to set up (outside the plugin)

This follows Google's Device Access "Get started" guide:

1. Pay the one-time Device Access registration fee and create a Device Access project. That gives the `projectId`.
2. Create a Google Cloud project with an OAuth client of type "Web application" whose authorized redirect URI includes `https://www.google.com`. That gives `clientId` and `clientSecret`. Enable the Smart Device Management API and the Cloud Pub/Sub API.
3. Link the OAuth client ID to the Device Access project, and turn events on for the project with a Pub/Sub topic.
4. Create a **pull** subscription on that topic. Its full name is the `subscriptionId`.
5. Authorize the account through the Partner Connections Manager (PCM), section 2.2, then exchange the code for tokens. That gives the `refreshToken`.

### 2.2 The authorization URL (PCM), the README's "important difference"

The user opens this in a browser, after substituting the project ID and client ID:

`https://nestservices.google.com/partnerconnections/{projectId}/auth?redirect_uri=https://www.google.com&access_type=offline&prompt=consent&client_id={clientId}&response_type=code&scope=https://www.googleapis.com/auth/sdm.service+https://www.googleapis.com/auth/pubsub`

- Scopes: `https://www.googleapis.com/auth/sdm.service` **and** `https://www.googleapis.com/auth/pubsub`, separated by a space (encoded as `+`). Google's own guide shows only `sdm.service`. The pubsub scope is required because the plugin reads the Pub/Sub subscription with the user's own OAuth credentials, not with a service account.
- On the PCM pages the user chooses which homes and devices to share. A device added later appears only after the user goes through PCM again and gets a new refresh token (README FAQ).
- After consent, Google redirects to `https://www.google.com?code=<authorization-code>&scope=...`. The user copies the `code`.

### 2.3 Code exchange (done by the user, documented by Google)

`POST https://www.googleapis.com/oauth2/v4/token` (Google's guide; `https://oauth2.googleapis.com/token` is equivalent) with form fields `client_id`, `client_secret`, `code`, `grant_type=authorization_code` and `redirect_uri=https://www.google.com`. The response JSON has `access_token`, `expires_in` (3599), `refresh_token`, `scope` and `token_type` (`Bearer`). The user pastes `refresh_token` into the config. The plugin itself never performs this step.

### 2.4 Token refresh (done by the plugin)

- Access tokens are got with the refresh-token grant: `POST https://oauth2.googleapis.com/token`, form-encoded, with `grant_type=refresh_token`, `client_id`, `client_secret` and `refresh_token`. The response has `access_token`, `expires_in` (about 3600 s), `scope` and `token_type`. Normally no new refresh token is returned. If one ever is, it should replace the stored one.
- The source leaves this to Google's client library. That library caches the access token and refreshes it shortly before it expires (about 5 minutes early), or on demand when a call finds it expired. It uses the same token for SDM REST calls (`Authorization: Bearer <token>`) and, through a separate client with the same credentials, for Pub/Sub.
- Errors: an invalid or revoked refresh token gives HTTP 400 `{"error":"invalid_grant", ...}`. A wrong client gives `invalid_client` (401). The source has no special handling: every SDM call fails and logs "could not execute ... request" with an HTTP status and message, and the Pub/Sub stream reports a subscription error (section 4.3). Nothing retries. Google notes that an authorization goes stale if it isn't used for about six months, and that a refresh token in a "Testing" OAuth consent screen expires after 7 days (a well-known pitfall, not handled by the source).

---

## 3. SDM REST API

Base: `https://smartdevicemanagement.googleapis.com/v1/`. Every call sends `Authorization: Bearer <access token>`.

### 3.1 Calls used

| Call | HTTP | When |
|---|---|---|
| List devices | `GET /v1/enterprises/{projectId}/devices` | Once, at startup. Only the first page is read: no `pageToken` follow-up. SDM projects rarely page. |
| Get device | `GET /v1/{device.name}` (that is, `enterprises/{projectId}/devices/{deviceId}`) | Lazily, when a trait is read and the device's cached state is more than **24 hours** old (section 7.2). |
| Execute command | `POST /v1/{device.name}:executeCommand` with body `{"command": "<name>", "params": {...}}` | Writes, streams, event images. The response is `{"results": {...}}`; the plugin reads `results`. |
| Structures, rooms | – | Not used. |

When a command has no parameters (GenerateRtspStream), the source sends no `params` key at all. Google documents `"params": {}`, and either is accepted.

### 3.2 Commands and parameters

| Command | params | results used |
|---|---|---|
| `sdm.devices.commands.ThermostatMode.SetMode` | `{"mode": "HEAT" \| "COOL" \| "HEATCOOL" \| "OFF"}` | – |
| `sdm.devices.commands.ThermostatEco.SetMode` | `{"mode": "MANUAL_ECO" \| "OFF"}` | – |
| `sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat` | `{"heatCelsius": <number>}` | – |
| `sdm.devices.commands.ThermostatTemperatureSetpoint.SetCool` | `{"coolCelsius": <number>}` | – |
| `sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange` | `{"heatCelsius": <number>, "coolCelsius": <number>}` | – |
| `sdm.devices.commands.Fan.SetTimer` | `{"timerMode": "ON" \| "OFF", "duration": "<seconds>s"}` | – |
| `sdm.devices.commands.CameraLiveStream.GenerateRtspStream` | none / `{}` | `streamUrls.rtspUrl`, `streamExtensionToken`, `streamToken`, `expiresAt` |
| `sdm.devices.commands.CameraLiveStream.StopRtspStream` | `{"streamExtensionToken": "<token>"}` | – |
| `sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream` | `{"offerSdp": "<SDP>"}` | `answerSdp`, `mediaSessionId`, `expiresAt` |
| `sdm.devices.commands.CameraLiveStream.StopWebRtcStream` | `{"mediaSessionId": "<id>"}` | – |
| `sdm.devices.commands.CameraEventImage.GenerateImage` | `{"eventId": "<event id from a Pub/Sub event>"}` | `url`, `token` |

Not used by the source, though documented by Google:
- `CameraLiveStream.ExtendRtspStream` (`{"streamExtensionToken"}` returns a new `streamExtensionToken`, `streamToken` and `expiresAt`).
- `CameraLiveStream.ExtendWebRtcStream` (`{"mediaSessionId"}` returns `mediaSessionId` and `expiresAt`). This only works on wired cameras: battery cameras accept it only while charging, and battery doorbells reject it.

Because the source never extends, every live view and every recording ends when the stream expires, after about 5 minutes (section 6.7).

**[source bug]** in Fan.SetTimer: the source always sends `duration` as the configured `fanDuration` followed by `s`. When `fanDuration` is absent it sends the literal string `"undefineds"`, and it sends a duration with `OFF` too. A replacement should send `"<fanDuration or 900>s"` with `ON` and leave `duration` out with `OFF`. Google documents `duration` as optional, defaulting to 15 minutes, with a maximum of 43200 s.

### 3.3 Event image fetch

After `GenerateImage`, `GET <url>` with header `Authorization: Basic <token>`. Note that the token is used as is, not base64 of a user:password pair. The body is a JPEG. The source fetches it as text with base64 response encoding, which amounts to reading the raw bytes. Google adds that `url` accepts optional `width`/`height` query parameters, and that event images can only be fetched within 30 seconds of the event. The source doesn't resize.

### 3.4 Device types and traits read

`type` values handled:
- `sdm.devices.types.THERMOSTAT`
- `sdm.devices.types.CAMERA`
- `sdm.devices.types.DOORBELL`
- `sdm.devices.types.DISPLAY` (Nest Hub Max)

Any other type, such as a `LOCK` or a future type, is recognized but gets no accessory. Devices whose `name` is null are dropped.

Traits read (the full trait key is `sdm.devices.traits.<Name>`):

| Trait | Fields used | Used by |
|---|---|---|
| `ThermostatMode` | `mode`, `availableModes` | thermostat |
| `ThermostatEco` | `mode`, `availableModes` (not used), `heatCelsius`, `coolCelsius` | thermostat |
| `ThermostatHvac` | `status` (`OFF`, `HEATING`, `COOLING`) | thermostat |
| `ThermostatTemperatureSetpoint` | `heatCelsius`, `coolCelsius` (each present only in the modes that use it) | thermostat |
| `Temperature` | `ambientTemperatureCelsius` | thermostat |
| `Humidity` | `ambientHumidityPercent` | thermostat |
| `Settings` | `temperatureScale` (`CELSIUS`/`FAHRENHEIT`) | thermostat (display units, ranges) |
| `Fan` | `timerMode` (`ON`/`OFF`); `timerTimeout` not used | fan accessory |
| `CameraLiveStream` | `supportedProtocols` (`RTSP`, `WEB_RTC`) | cameras, doorbells, displays |
| `Connectivity` | – | **not used**: offline devices are not marked as such (section 7.4) |
| `Info` | – | **not used**: the device's `customName` is ignored for naming (section 5.0) |

Protocol choice, per camera-type device, made each time it matters: if `CameraLiveStream.supportedProtocols` contains `WEB_RTC`, the device is a WebRTC device. Otherwise, including when the trait is missing, it is an RTSP device. In practice, the legacy Nest Cams, Nest Hello and the Nest Hub Max are RTSP, and the 2021-and-later battery and wired Nest Cams and Nest Doorbells are WebRTC.

---

## 4. Events (Cloud Pub/Sub)

### 4.1 Transport

- The source subscribes with Google's Pub/Sub client library: streaming pull over gRPC, credentials of type "authorized_user" built from `clientId`, `clientSecret` and `refreshToken`, on the subscription named by `subscriptionId`, with the project set to `gcpProjectId` or else `projectId`. It is a **pull** subscription. There is no push endpoint and no inbound HTTP.
- An equivalent without gRPC is the Pub/Sub REST API, with the same bearer token (scope `pubsub`):
  - Pull: `POST https://pubsub.googleapis.com/v1/{subscriptionId}:pull` with body `{"maxMessages": <n>}`. The response is `{"receivedMessages": [{"ackId": "...", "message": {"data": "<base64 JSON>", "messageId": "...", "publishTime": "...", "attributes": {...}}}]}`, or `{}` when there is nothing. Loop on it. A pull with nothing to return can wait up to the server's timeout.
  - Acknowledge: `POST https://pubsub.googleapis.com/v1/{subscriptionId}:acknowledge` with `{"ackIds": [...]}`.
  - Optionally, `:modifyAckDeadline`.
- Ack policy: **every message is acknowledged as soon as it is received, before it is parsed**. A message that fails to parse is still acked and is lost. That's deliberate, so a poison message can't loop.
- Google says events start flowing only after one `devices.list` call has been made after the subscription was created. The plugin makes that call at startup anyway.
- Delivery is unordered and messages can be batched. The source treats each Pub/Sub message as one event object.

### 4.2 Message handling

1. Base64-decode `message.data` and parse it as JSON. If parsing throws, log "could not handle event" with the error message and drop it.
2. Messages that arrive before the device list has loaded are dropped (after the ack).
3. If there is no `resourceUpdate` (relation events: `relationUpdate`, a device added, removed or moved), log at debug level that it is ignored and stop. Relation events don't change the accessories. A new or removed device needs a restart.
4. If `resourceUpdate.events` is present, it is a **device event**. If `resourceUpdate.traits` is present, it is a **trait event**. Find the device whose `name` equals `resourceUpdate.name` exactly. If none matches, ignore the message.
5. Trait event: for each trait key in `resourceUpdate.traits`, **if the device's cached trait map already has that key, replace the cached value with the event's value wholesale**. Unknown trait keys are not added. Then the per-type callbacks run (section 5).
   - The replacement is wholesale, not field by field. Google's example trait events carry only the changed trait, and some carry only the changed fields (for example a setpoint change in HEAT mode carries only `heatCelsius`). A field-level merge would be safer. The behaviour HomeKit sees is the same unless a partial trait arrives. **[possible source bug]**
6. Device event (cameras, doorbells, displays): see section 5.3.

### 4.3 Subscription errors

- If the subscription can't be created, or the stream reports an error (the library retries transient errors internally and reports only those it can't recover from, such as PERMISSION_DENIED when the pubsub scope is missing, or NOT_FOUND when the subscription is wrong), the plugin logs an error. Paraphrased: "Plugin initialization failed: event subscription failure; see the readme's config section." Then it sets an internal flag.
- Effect of the flag: a later device list call returns the previously loaded list (or nothing) without calling the API. In practice the list call happens once at startup, so if the error arrives before discovery runs, **no accessories are set up at all**. If it arrives after, the accessories keep working, but without events.
- There is no resubscribe and no backoff.

### 4.4 Polling fallback

There is no periodic polling. The only refresh is the lazy GET of a device when a HomeKit read touches a trait and the device's last refresh was more than 24 hours ago (section 7.2). So without events, state stays frozen at what the startup list returned, for up to 24 hours.

---

## 5. Device model and HomeKit mapping

### 5.0 Identity, names, categories and lifecycle

- **Display name.** Take the first entry in the device's `parentRelations` that has a non-empty `displayName`. That is the room name, or for some devices a custom name. Append a type suffix:
  - `" Thermostat"`, `" Camera"`, `" Doorbell"` or `" Display"`.
  - If there is no such relation, the name is exactly `Unknown`, with no suffix. The README mentions Google sometimes returning a null or empty room name, which can give names like " Camera".
  - The fan accessory's name is the thermostat's display name followed by `" Fan"`.
- **Accessory UUID** (HomeKit identity; the replacement must use exactly these seeds):
  - Thermostat, camera, doorbell, display: HAP-NodeJS `uuid.generate(device.name)`, where `device.name` is the full resource name `enterprises/{projectId}/devices/{deviceId}`.
  - Fan: `uuid.generate(device.name + " Fan")`, the same resource name followed by a space and `Fan`.
  - HAP-NodeJS `uuid.generate(s)` takes the SHA-1 hex digest of the UTF-8 string and lays its hex characters, in order, into the template `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`. Each `x` takes the next hex character. The literal `4` takes none. `y` takes the next hex character `c` and writes `(c & 0x3) | 0x8`. The result is lowercase.
  - Because the seed contains the Device Access `projectId`, a new Device Access project gives new identities.
- **Category:** doorbell is VIDEO_DOORBELL (18), camera and display are CAMERA (17), thermostat is THERMOSTAT (9), fan is FAN (3). Unknown types are skipped.
- **Accessory Information:** the source tries to set Manufacturer to `Nest` but writes it to a service that is never attached, so the accessories show the Homebridge defaults: Name is the display name, Manufacturer `Default-Manufacturer`, Model `Default-Model`, Serial `Default-SerialNumber`. A replacement can fill in real values (Manufacturer `Google Nest`, Model from the device type, Serial from the device id) without breaking ids. Accessory Information fields don't affect the aid or iids.
- **Cache:** a restored cached accessory keeps its cached display name. Names are only set on first creation. Cached accessories whose device is gone are **never removed**: they stay, inert. Only devices returned by the startup list get handlers.
- **Identify:** logs "<name> identified!" ("fan identified!" for the fan). Nothing else.

### 5.1 Thermostat (`sdm.devices.types.THERMOSTAT`)

Services: **Thermostat** (`0000004A`), plus a custom characteristic added to it:

- **Eco**: UUID `f66de49d-792e-44a6-99c8-5e3576328ba1`, display name `Eco`, format bool, perms paired read, paired write and notify, initial value false. The UUID must be reused exactly so the iid stays stable. The Home app doesn't show it; Eve-style apps do.

No separate Humidity or Fan service: CurrentRelativeHumidity is an optional characteristic on the Thermostat service.

Characteristics:

| Characteristic | Read | Write | Event updates |
|---|---|---|---|
| CurrentHeatingCoolingState | `ThermostatHvac.status`: `HEATING` gives HEAT (1), `COOLING` gives COOL (2), `OFF` gives OFF (0), otherwise null | – | on a `ThermostatHvac` trait event, same mapping (null means no update) |
| TargetHeatingCoolingState | if eco mode is anything other than `OFF`: OFF (0). Otherwise `ThermostatMode.mode`: `HEAT` gives 1, `COOL` gives 2, `HEATCOOL` gives AUTO (3), `OFF` gives 0 | 1 is `HEAT`, 2 is `COOL`, 3 is `HEATCOOL`, anything else is `OFF`. Rejected with an error if the mode isn't in `availableModes`, else sends ThermostatMode.SetMode. It doesn't turn eco off first. | on a `ThermostatMode` trait event: re-runs "configure" (below), then updates with the mapped mode |
| CurrentTemperature | `Temperature.ambientTemperatureCelsius` (null if absent or **0**) | – | on a `Temperature` trait event |
| TemperatureDisplayUnits | `Settings.temperatureScale`: CELSIUS gives 0, FAHRENHEIT gives 1, else null | no handler: a write is accepted and stored but has no effect on the device | on a `Settings` trait event |
| CurrentRelativeHumidity | `Humidity.ambientHumidityPercent` (null if absent or 0) | – | on a `Humidity` trait event |
| TargetTemperature | handled only in HEAT/COOL mode with eco OFF: HEAT gives `heatCelsius`, COOL gives `coolCelsius` | same condition: HEAT sends SetHeat, COOL sends SetCool. Errors in eco, OFF and HEATCOOL. | from a setpoint event in HEAT/COOL (below) |
| HeatingThresholdTemperature | see "thresholds" | only in HEATCOOL with eco OFF | setpoint event in HEATCOOL; eco event |
| CoolingThresholdTemperature | see "thresholds" | only in HEATCOOL with eco OFF | same |
| Eco (custom) | `ThermostatEco.mode == MANUAL_ECO` (false reads as null) | true sends ThermostatEco.SetMode `MANUAL_ECO`; false sends `OFF` | on a `ThermostatEco` trait event |

"Null" means the read answers with no value. In HAP-NodeJS a null from a read handler is reported as a warning and HomeKit gets the last value. The replacement should answer with the last known value.

**"Configure" step.** It runs at accessory setup, and again after every ThermostatMode or ThermostatEco trait event. It decides which of TargetTemperature, Heating/CoolingThresholdTemperature have read and write handlers, and sets the ranges:

1. Remove the read and write handlers from TargetTemperature, HeatingThresholdTemperature and CoolingThresholdTemperature. A characteristic without a handler serves its cached value, and a write is stored locally without reaching the device.
2. Ranges, all in °C, because HomeKit always works in Celsius:
   - Scale FAHRENHEIT: settable min = (50−32)/1.8 = 10.0, settable max = (90−32)/1.8 ≈ 32.222, readable min = (0−32)/1.8 ≈ −17.778, readable max = (160−32)/1.8 ≈ 71.111.
   - Otherwise (Celsius or unknown): settable 9 to 32, readable −20 to 60.
3. If eco mode is not `OFF` (eco on, or the eco trait missing):
   - the settable min becomes (40−32)/1.8 ≈ 4.444 for Fahrenheit, or 4.5 for Celsius;
   - give both threshold characteristics **read** handlers only;
   - apply the ranges (step 5) and stop. The TargetHeatingCoolingState valid values are not changed in this branch.
4. Otherwise, set TargetHeatingCoolingState's valid values to exactly the mapped `availableModes`. For example `["HEAT","COOL","HEATCOOL","OFF"]` gives [1,2,3,0], and a heat-only unit gives [1,0]. Then by mode:
   - `HEATCOOL`: both thresholds get read and write handlers. TargetTemperature has none.
   - `HEAT` or `COOL`: both thresholds get read handlers only. TargetTemperature gets read and write.
   - `OFF`: nothing.
5. Apply the ranges: CurrentTemperature min and max are the readable range. TargetTemperature, HeatingThresholdTemperature and CoolingThresholdTemperature min and max are the settable range. Steps are left at the HAP defaults: 0.1 for temperatures. The HAP defaults otherwise would be TargetTemperature 10–38, Heating 0–25, Cooling 10–35, Current 0–100 (0–100 in HAP-NodeJS's newer definitions, −270–100 older).

**Thresholds (reads):**
- First get the "range":
  - If eco is not `OFF`: heat = `ThermostatEco.heatCelsius`, cool = `ThermostatEco.coolCelsius`.
  - Otherwise, in HEAT, COOL or HEATCOOL: the setpoint trait's `heatCelsius` and `coolCelsius`.
  - In OFF the read fails.
- Cooling threshold: in COOL or HEATCOOL it is range.cool. In HEAT it is range.heat − 0.5. In any other mode the read fails ("cannot read when off").
- Heating threshold: in HEAT or HEATCOOL it is range.heat. In COOL it is range.cool + 0.5. Otherwise the read fails.
- The mode used is the raw `ThermostatMode.mode`, even while eco is on.

**Threshold writes (HEATCOOL, eco OFF):**
- A heating write of `h` sends SetRange with `heatCelsius = h` and `coolCelsius` = the current cached cool setpoint.
- A cooling write of `c` sends SetRange with the current cached heat and `coolCelsius = c`.
- An error if eco is on, or if neither value is given.
- **[source bug]** The source's range setter also has HEAT and COOL branches that send `SetRange` with only one field and then fall through into errors. They can't be reached, because thresholds aren't writable in HEAT/COOL. Ignore them.

**Setpoint trait event** (`ThermostatTemperatureSetpoint`):
- Ignored if the event's value has neither `heatCelsius` nor `coolCelsius`, or both are 0.
- Otherwise, read the cached mode:
  - `HEATCOOL`: compute the range as above and update HeatingThresholdTemperature (if heat is non-zero) and CoolingThresholdTemperature (if cool is non-zero).
  - `HEAT`/`COOL`: compute the target temperature and update TargetTemperature. In the source this throws, unhandled, when eco is on, so nothing is updated then.

**Eco trait event:**
- Run "configure".
- If the new mode is `MANUAL_ECO`: update HeatingThresholdTemperature to `heatCelsius`, CoolingThresholdTemperature to `coolCelsius` and TargetHeatingCoolingState to OFF.
- In all cases, update Eco to (mode == `MANUAL_ECO`).

**Fan trait event:** goes to the fan accessory, if there is one. **[source bug]** The source falls through into the HVAC handler with no status, which changes nothing.

**Read errors:** "cannot get target temperature in eco/off/auto" and similar are thrown from read and write handlers, and HAP-NodeJS turns them into a SERVICE_COMMUNICATION_FAILURE (−70402) status for that characteristic.

### 5.2 Fan (only when `showFan` is true; one per thermostat)

- Service: **Fan** (`00000040`, the original Fan service, not Fanv2), characteristic **On**.
- Read: true when the `Fan` trait's `timerMode` is `ON`, else false.
- Write: the value must be a boolean, otherwise an error. If `fanDuration` is set and outside 1–43200, an error. Otherwise send `Fan.SetTimer` with `timerMode` `ON` or `OFF` (duration: see the bug note in 3.2).
- Event: a `Fan` trait event updates On to (`timerMode == ON`).
- A thermostat without a Fan trait still gets the fan accessory when `showFan` is true. Its On reads false, and writes fail at the SDM API.

### 5.3 Cameras, doorbells, displays

**Common to all three (types CAMERA, DOORBELL, DISPLAY):**

- **MotionSensor** service (`00000085`), MotionDetected, no subtype. It is added by the plugin.
  - Read: true if a motion signal came less than 20 s ago (≤ 20000 ms), else false.
  - On a motion signal: record the time, push MotionDetected = true, and 20 s later push false if no newer signal arrived in that window.
  - Note: the clear check is "strictly more than 20000 ms since the last signal", made by a timer that fires at about 20000 ms. When the timer fires slightly early, the pushed value stays true even though reads say false. A replacement should push false at 20 s after the last signal.
- **Camera controller** (HAP-NodeJS CameraController, or DoorbellController for doorbells) with:
  - **Live streaming:** `cameraStreamCount` equals the number of advertised resolutions (11 for cameras and doorbells, 3 for displays). That gives this many CameraRTPStreamManagement services.
    - SRTP suite AES_CM_128_HMAC_SHA1_80.
    - Video H.264, profile Main, level 3.1.
    - Resolutions for cameras and doorbells, as [width, height, fps]: [320,180,30], [320,240,15], [320,240,30], [480,270,30], [480,360,30], [640,360,30], [640,480,30], [1280,720,30], [1280,960,30], [1920,1080,30], [1600,1200,30]. Displays: [1280,720,15], [1920,1080,15], [1600,1200,15].
    - Audio AAC-ELD, 16 kHz, mono. Two-way audio off, so a Microphone service but no Speaker.
  - **Recording (HKSV):** CameraRecordingManagement, CameraOperatingMode and DataStreamTransportManagement services, as HAP-NodeJS creates them.
    - Prebuffer length 4000 ms. Fragmented MP4 with 4000 ms fragments.
    - Video H.264 profile High, level 4.0, with the 11-entry resolution list above, for every type, displays included.
    - Audio AAC-ELD, mono, 48 kHz, variable bitrate.
  - Doorbells add the Doorbell service (`00000121`) with ProgrammableSwitchEvent, as DoorbellController does.
  - The iids of these services follow HAP-NodeJS's controller layout. A replacement keeps service UUIDs and subtypes equal to HAP-NodeJS's, so the iids keyed by service UUID and subtype stay stable.

**Device event handling** (section 4.2, step 6), for each key in `resourceUpdate.events`:

- **Staleness:** if the event's top-level `timestamp` is more than 30 s before now, ignore the whole event. A missing or unparseable timestamp counts as fresh.
- **Thread state:** if `eventThreadState` is present and isn't `STARTED`, ignore that event key. `UPDATED` and `ENDED` never trigger anything. Events with no thread state are handled.
- `sdm.devices.events.CameraMotion.Motion` and `sdm.devices.events.CameraPerson.Person`:
  - WebRTC device: motion signal right away.
  - RTSP device: first try to fetch the event image (section 6.6) with the event's `eventId` (the one inside the event value, not the envelope's), then send the motion signal whether or not the fetch worked.
- `sdm.devices.events.CameraSound.Sound`: RTSP devices only. Fetch the event image and do nothing else: **no motion signal**. Ignored on WebRTC devices.
- `sdm.devices.events.DoorbellChime.Chime` (doorbells only): WebRTC devices ring right away. RTSP devices fetch the image first, then ring. Ringing means the Doorbell service's ProgrammableSwitchEvent = SINGLE_PRESS (0).
- `sdm.devices.events.CameraClipPreview.ClipPreview`: ignored.
- For a doorbell, a single Chime event can carry both Motion/Person and Chime keys. Both are handled.

---

## 6. Streaming

### 6.1 Live streams: overview

The HomeKit side is standard HAP camera RTP streaming: HomeKit's "prepare stream" and "start/stop/reconfigure stream". For each start, the plugin starts a new SDM stream (RTSP or WebRTC, by protocol) and runs one FFmpeg process. That process reads the SDM stream, sends SRTP video to the HomeKit controller's video port, and sends SRTP audio to its audio port. Each HomeKit session gets its own SDM stream. Google: one RTSP URL serves one client.

### 6.2 Prepare

- Pick two free local UDP ports: a "video return" port and an "audio return" port. Bind to `::` for IPv6 sessions or `0.0.0.0` otherwise. Reserve them briefly.
- Generate two random SSRCs, one for video and one for audio.
- Local address: the first non-internal address of the preferred family (IPv6 when HomeKit's request is IPv6, else IPv4) on the host's **default network interface**. Fall back to that interface's first non-internal address. Error if none.
- If the `CameraLiveStream` trait is missing, fail prepare ("camera info was not received").
- Response: the local address; for video, the return port, the video SSRC and the **same SRTP key and salt HomeKit sent**; the same for audio. Remember the controller's address, its video and audio ports, and the key‖salt for each, for the start step.

### 6.3 Start

1. Create the SDM stream (6.5) and get the FFmpeg input arguments, plus, for WebRTC, an SDP to feed on stdin. If that fails, report an error to HomeKit.
2. Build the FFmpeg arguments (6.4) and spawn FFmpeg. Binary: a bundled build if there is one, else `ffmpeg` on PATH. It needs `libfdk_aac` for AAC-ELD.
3. Bind a UDP socket (udp4 or udp6) on the video return port at the local address. That is where HomeKit's RTCP arrives.
   - On each datagram, restart an inactivity timer of `rtcp_interval × 2` seconds, with `rtcp_interval` from HomeKit's start request (typically 0.5, so 1 s).
   - If the timer fires: log at debug level that the device appears inactive, force-stop the HomeKit session and stop the stream.
   - The timer starts only after the first datagram arrives.
   - A socket error also stops the stream.
4. HomeKit's start callback is answered with success **when FFmpeg writes anything to stderr for the first time**. That is the "started" signal.
5. FFmpeg process events:
   - Spawn error: callback with an error ("FFmpeg process creation failed"), then stop the stream.
   - Exit with code null or 255: expected if we killed it (debug log), otherwise logged as an unexpected error, and nothing else is done.
   - Any other exit code: log it as an error, stop the stream, then answer the start callback with an error if it hadn't started, or force-stop the HomeKit session if it had.
6. RECONFIGURE requests are acknowledged and ignored. STOP stops the stream and acknowledges.
7. Stopping a stream: clear the timer, close the socket, SIGKILL FFmpeg, and tear down the SDM stream (StopRtspStream with the extension token, or StopWebRtcStream with the media session id, then close the peer connection and the forwarding socket). Errors are logged and ignored. On bridge shutdown, every live session is stopped.

### 6.4 FFmpeg arguments, live (an interface to an external program; give it exactly)

The source builds one string and splits it on runs of whitespace into argv. No shell is involved. Tokens appear below in order, and `<...>` marks substitutions.

**Input, RTSP device:**
```
-analyzeduration <analyzeDuration|15000000> -probesize <probeSize|100000000> -i <rtspUrl>
```

**Input, WebRTC device** (the SDP is written to FFmpeg's stdin, then stdin is closed):
```
-protocol_whitelist pipe,crypto,udp,rtp,fd -analyzeduration <analyzeDuration|15000000> -probesize <probeSize|100000000> -fpsprobesize 0 -i -
```

**Video output:**
```
-an -sn -dn -codec:v <vEncoder tokens> -f rawvideo -pix_fmt yuv420p -color_range mpeg
```
Then, only when `vEncoder` is not exactly `copy`:
```
-bf 0 -r <fps> -b:v <B>k -bufsize <B>k -maxrate <2B>k -filter:v <filter>
```
Then:
```
-payload_type <video pt> -ssrc <video SSRC> -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params <base64(video key‖salt)> srtp://<controller address>:<controller video port>?rtcpport=<controller video port>&pkt_size=<video mtu>
```

**Audio output:**
```
-vn -sn -dn -codec:a libfdk_aac -profile:a aac_eld -flags +global_header -ar <audio sample_rate>k -b:a <audio max_bit_rate>k -ac <audio channel> -payload_type <audio pt> -ssrc <audio SSRC> -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params <base64(audio key‖salt)> srtp://<controller address>:<controller audio port>?rtcpport=<controller audio port>&pkt_size=188
```

**Debug only**, appended:
```
-loglevel level+verbose
```

Substitutions:
- `fps`, `pt`, `mtu`, the audio `sample_rate` (a number in kHz, such as 16), `max_bit_rate` and `channel` come from HomeKit's start request.
- `B` = HomeKit's video `max_bit_rate` (kbps) × 4. `2B` is twice that.
- `filter`: when the requested width or height is non-zero, it is two filters joined by a comma:
  - `scale='min(<W>,iw)':'min(<H>,ih)':force_original_aspect_ratio=decrease` (single quotes included literally; `iw` in place of the min expression when W is 0, `ih` when H is 0);
  - `scale=trunc(iw/2)*2:trunc(ih/2)*2`.
  
  When both are 0 the filter is empty. **[source bug]** `-filter:v` then swallows the next token. HomeKit always sends non-zero sizes.
- The `-f rawvideo` is overridden by the later `-f rtp` of the same output, so it has no effect. Keep it for exactness or drop it.
- With `copy`, the camera's H.264 goes out as it is: High profile at the camera's resolution. HomeKit generally accepts that.
- For WebRTC, the input audio is Opus at 48 kHz and is transcoded to AAC-ELD. For RTSP the input audio is AAC.

**The SDP fed to FFmpeg's stdin (WebRTC)** declares two local plain-RTP streams that the plugin feeds (6.5.2). It is these lines joined with `\n`, with no trailing newline:

```
v=0
o=- 0 0 IN IP4 127.0.0.1
s=-
c=IN IP4 127.0.0.1
t=0 0
m=audio <audioPort> UDP 96
a=rtpmap:96 opus/48000/2
a=fmtp:96 minptime=10;useinbandfec=1
a=rtcp-fb:96 transport-cc
a=sendrecv
m=video <videoPort> UDP 97
a=rtpmap:97 H264/90000
a=rtcp-fb:97 ccm fir
a=rtcp-fb:97 nack
a=rtcp-fb:97 nack pli
a=rtcp-fb:97 goog-remb
a=fmtp:97 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=sendrecv
```

`<audioPort>` and `<videoPort>` are two free local UDP ports, picked by the plugin on 0.0.0.0. FFmpeg listens on them and the plugin sends to 127.0.0.1 on them.

In debug mode the source echoes FFmpeg's stderr line by line, leaving out lines containing "Empty H.264 RTP packet", which are WebRTC bandwidth probes. It also logs timing milestones: the first matches of "Reinit context", "Input #0", "Output #0" and "frame=".

### 6.5 Getting the SDM stream

#### 6.5.1 RTSP devices

- Execute `GenerateRtspStream`. If there is no result (rate limit or error), fail the start with "unable to start stream: no response from the Nest API (usually rate limiting)".
- The input is `results.streamUrls.rtspUrl`, an `rtsps://` URL carrying the stream token as an `auth=` query parameter. FFmpeg reads it directly, over RTSP on TLS. Keep `streamExtensionToken` for the stop.
- Tokens are valid until `expiresAt`, which is now + 5 minutes. The source doesn't extend.

#### 6.5.2 WebRTC devices — THE HARD PART

The plugin acts as a WebRTC client, the source using the `werift` library. It terminates ICE, DTLS-SRTP and RTCP itself, and forwards the decrypted RTP to FFmpeg as plain RTP on localhost. Observable behaviour:

1. **Peer connection configuration.** Bundle policy max-bundle. The source passes no ICE servers, so the library's defaults apply (not determined; Google's side provides reachable candidates in its answer, and connectivity works from host and peer-reflexive candidates).
2. **Codecs offered.**
   - Audio: only Opus, `opus/48000/2`.
   - Video: only H.264, `H264/90000`, with fmtp `level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f` and RTCP feedback `transport-cc`, `ccm fir`, `nack`, `nack pli` and `goog-remb`.
   - The dynamic payload types assigned are 96 for Opus and 97 for H.264 (werift numbers from 96 in order). The forwarded packets keep the payload type of the negotiated session, and FFmpeg's SDP assumes 96 and 97, so **the offer must use PT 96 for Opus and PT 97 for H.264**.
3. **Transceivers, in this order.**
   - An audio transceiver, direction recvonly.
   - A video transceiver, direction recvonly.
   - Then a data channel labelled `dataSendChannel`, negotiated id 1, which creates the `m=application` (SCTP) section.
   - Google requires: Unified Plan; media sections in the order audio, video, application; Opus only; audio `a=recvonly`; the SDP ending with a newline; trickle ICE optional.
4. Create the offer and set it as the local description. Send the offer's SDP text in `GenerateWebRtcStream` as `offerSdp`. The source sends the SDP returned by offer creation, not a later local description with gathered candidates (non-trickle as far as the source goes; whether candidates are in it depends on the library).
5. If there is no result, fail the same way as RTSP. Otherwise keep `mediaSessionId` and set `answerSdp` as the remote description (type answer). Google: the answer must be used within 30 s.
6. **Forwarding.** One UDP socket (IPv4) sends:
   - each received audio RTP packet, decrypted and re-serialized with its header intact, to `127.0.0.1:<audioPort>`;
   - each received video RTP packet the same way to `127.0.0.1:<videoPort>`.
   
   RTCP from the camera isn't forwarded. Nothing is sent back from FFmpeg.
7. **Bandwidth hint (REMB).** As soon as the video track arrives, and again with every keyframe request, send RTCP PSFB (PT 206) FMT 15 "REMB" on the DTLS-SRTP transport:
   - sender SSRC = the receiver's own RTCP SSRC;
   - media SSRC = 0;
   - number of SSRCs = 1;
   - bitrate 4,000,000 bps, encoded with an 18-bit mantissa and a 6-bit exponent: halve the mantissa, rounding down, and add one to the exponent until the mantissa is ≤ 0x3FFFF. That gives exponent 4 and mantissa 250000;
   - SSRC feedback list = [the video track's SSRC].
   
   Without it, the camera's sender starts conservatively, at about 375 kbps, and the first keyframe takes 1.3 to 2.3 s to arrive.
8. **Keyframe requests.** On the first video RTP packet, and then **every 2 seconds for the life of the stream**:
   - a REMB as above;
   - an RTCP PLI (PSFB FMT 1) for the video SSRC;
   - an RTCP FIR (PSFB FMT 4, RFC 5104). Its 16-byte body, after the common header, is: the sender SSRC (receiver's RTCP SSRC), 4 bytes; the "media source SSRC" set to **the video SSRC** (RFC 5104 says 0, but the source sends the SSRC), 4 bytes; then one FCI entry: the video SSRC, 4 bytes, then a sequence number, 1 byte, then 3 zero bytes. The length field is 4 (32-bit words − 1, counting the 4-word body).
   - The FIR sequence number starts at 0 for each new video track and goes up by 1 with each request, wrapping at 255.
   
   Reason, from the source's own diagnostics, paraphrased: these cameras answer PLI with an IDR that has no SPS/PPS, but answer FIR with an IDR that carries the SPS/PPS. Without the parameter sets FFmpeg can't learn the dimensions, and the stream fails with "dimensions not set" or starts many seconds late.
9. **FFmpeg probing.** `-fpsprobesize 0` stops FFmpeg from spending the analyze window estimating the frame rate of a roughly 7.5 fps stream. The large analyzeduration and probesize stay as an upper bound, for cameras whose first keyframe is late.
10. **Keyframe detection** is for diagnostics only: an H.264 payload counts as a keyframe if its NAL type is 5, or FU-A (28) with the start bit set and an inner type of 5, or STAP-A (24) containing a type-5 NAL.
11. **Teardown:** stop the 2 s timer, send StopWebRtcStream with `mediaSessionId`, close the peer connection and close the forwarding socket.
12. A debug-only capture option, driven by an environment variable, writes the forwarded video RTP to a file, each packet prefixed with its 2-byte big-endian length. It is not needed.

Why it's hard:
- A WebRTC stack has to be available from Swift on macOS and Linux: ICE (at least a controlling or controlled agent that answers STUN connectivity checks), DTLS 1.2 with the SRTP extension, SRTP decryption with keys exported from DTLS, SCTP over DTLS (the data channel has to be negotiated even though it's never used), RTCP feedback packets and SDP generation in Google's required shape.
- Then come Google's peculiarities: the PT numbering FFmpeg relies on, the FIR-not-PLI keyframes and the 5-minute lifetime.

### 6.6 Snapshots

- The SDM API has no on-demand snapshot. The source never starts a stream to make one, to avoid the stream-creation rate limits.
- A snapshot request returns, in this order:
  1. the most recent event image, if one was fetched less than 10 s ago;
  2. otherwise a fixed placeholder JPEG (1920x1080): a "Nest" image for RTSP devices, a "Google" image for WebRTC devices. A replacement uses its own neutral placeholder.
- The requested snapshot dimensions are ignored. No resizing.
- Event image fetch (RTSP devices only: WebRTC devices don't support CameraEventImage):
  - If the event's timestamp is more than 30 s old, skip it.
  - Otherwise execute `CameraEventImage.GenerateImage` with the event's `eventId`, GET the URL with `Authorization: Basic <token>`, and keep the bytes for 10 s.
  - On failure, log "could not fetch event image" with the HTTP status and message only.

### 6.7 HomeKit Secure Video recording

- The source keeps the recording configuration HomeKit selects. "Recording active" changes are logged and ignored. There is no prebuffer, despite the 4000 ms advertised.
- When the hub opens a recording stream (after the motion signal):
  - If there is no recording configuration, or the codec isn't H.264, fail.
  - Create a **new SDM stream** (6.5) to use as the input.
  - Start a local TCP listener on 127.0.0.1 on an ephemeral port, then run FFmpeg (arguments below), which connects to it and writes fragmented MP4.
- **Reading the MP4.** Read the output as ISO BMFF boxes: an 8-byte header (32-bit big-endian size including the header, then a 4-character type), then size − 8 bytes. Collect header and body bytes. Each time a `moov` or an `mdat` box completes, send everything collected so far as one recording packet: the first packet is `ftyp` and `moov`, and each later one is `moof` and `mdat`. `isLast` is always false: the stream runs until the hub closes it, or the input ends (the SDM stream expires after about 5 minutes, or FFmpeg exits). An end of stream or a read error ends the packet sequence; the error is logged.
- **Close and acknowledge.** When the hub closes or acknowledges the stream, close it only if the stream id matches the current recording. A late close for an old session is ignored. Closing kills FFmpeg and tears down the SDM stream.
- **A new recording replacing an old one.** If a new recording request arrives while one is running, the old FFmpeg and SDM stream are torn down first. If FFmpeg exits before connecting, the listener closes and the packet sequence fails at once rather than hanging.

**FFmpeg arguments, recording.** These are argv in this order. The input part is the live input string (6.4) split on single spaces, and for WebRTC the same SDP is fed on stdin.

```
<input tokens>
-acodec libfdk_aac -profile:a <aac_low if HomeKit chose AAC-LC, else aac_eld> -ar <S>k -b:a <audio bitrate>k -ac <audio channels>
-f mp4
-an -sn -dn -codec:v libx264 -pix_fmt yuv420p -profile:v <high|main|baseline> -level:v <4.0|3.2|3.1> -b:v <video bitRate>k -force_key_frames expr:eq(t,n_forced*<iFrameInterval/1000>) -r <fps>
-fflags +genpts -reset_timestamps 1 -movflags frag_keyframe+empty_moov+default_base_moof
tcp://127.0.0.1:<port>
```

Values:
- Profile: HomeKit's High gives `high`, Main gives `main`, anything else `baseline`.
- Level: 4.0 gives `4.0`, 3.2 gives `3.2`, anything else `3.1`.
- `S` is the selected recording sample rate: 8, 16, 24, 32, 44.1 or 48. Anything else is an error.
- `fps` is the third element of the selected resolution.
- `iFrameInterval` is in ms, so 4000 gives `4`.
- The audio group is always included in practice. The source includes it whenever the RecordingAudioActive characteristic exists, which it always does.
- Observable consequence: `-an` sits among the same output's options, so FFmpeg writes **no audio track**, whatever audio options come before it. A replacement can match this, or drop `-an` and include audio, which is a behaviour change in HomeKit's favour.
- Recordings always transcode with libx264 and ignore `vEncoder`. This is CPU heavy: the README says one busy camera can saturate a Raspberry Pi 4.

---

## 7. Behaviour

### 7.1 Startup sequence

1. Validate the config (1.2).
2. Set up the OAuth client and the Pub/Sub subscription. Messages are acked from now on, but dropped until the devices are loaded.
3. When the bridge has finished launching, list the devices once:
   - On failure, log "could not execute device LIST request: HTTP <status>: <message>". There are no accessories and no retry: the bridge has to be restarted.
4. Build the device objects. For each device, create or restore its accessory, plus the fans, and bind the handlers.

### 7.2 State cache

- Each device keeps the JSON last returned by list or get. Reads are answered from it, and trait events update it (4.2).
- Before any trait read, if more than 24 h have passed since the last list or get for that device, do a `GET` of the device and replace the cache.
  - If the GET fails with a 429 or RESOURCE_EXHAUSTED, log "rate-limited the GetDevice API; using cached state". Otherwise log "could not execute device GET request". Either way, keep the cache, and leave the refresh time unchanged, so the next read retries.

### 7.3 Rate limits (SDM quota, Sandbox, from Google's "Project limits" page)

- Per project and user:
  - `devices.executeCommand` 10 queries per minute;
  - `devices.get` 10 per minute;
  - `devices.list` 5 per minute;
  - `structures.*` and `rooms.*` 5 per minute.
- Per device, trait commands: 5 per minute.
- Per device instance, across all projects, for executeCommand only:
  - THERMOSTAT 5 per minute or 100 per hour;
  - CAMERA and DOORBELL 30 per minute or 100 per hour.
- When a limit is hit: HTTP 429, status `RESOURCE_EXHAUSTED`, message "Rate limited."
- How the source reacts: it recognizes a rate limit by HTTP status 429, or by "rate limit" or "RESOURCE_EXHAUSTED" in the message, ignoring case.
  - For a command, it logs that Google rate-limited the `<command>` command and to wait about a minute. The command result is "nothing", so a stream start fails with "no response from the Nest API".
  - There is no retry, queueing or debouncing.
- HomeKit setting a thermostat slider fast can exhaust the thermostat's 5 per minute limit. A replacement may debounce writes, but the source doesn't.
- Every live view and every HKSV recording costs a Generate and a Stop. WebRTC keyframe requests are RTCP, not API calls.

### 7.4 Unreachable devices

- The `Connectivity` trait is ignored. An offline device keeps serving cached values.
- A failed command:
  - for a characteristic write: the source logs the error and **returns success to HomeKit**. The command wrapper swallows API errors and returns nothing. Only the plugin's own precondition checks (mode not available, eco on, and so on) reach HomeKit as errors.
  - for a stream: the stream fails.
- Google's error for an offline camera: "The camera is not available for streaming." (FAILED_PRECONDITION). Google's "Permission denied." means the device wasn't shared in PCM, or that the WebRTC offer's audio section is wrong.

### 7.5 Edge cases

- A temperature, humidity or setpoint value of exactly 0 is treated as missing (null read / no update).
- If `ThermostatEco` is missing on a thermostat, eco counts as **on**:
  - TargetHeatingCoolingState reads OFF;
  - TargetTemperature and the setpoints can't be set;
  - the threshold range comes from the missing eco trait (nothing).
  
  This is source behaviour. Every Nest thermostat has the eco trait.
- `ThermostatMode` events with an unchanged mode still run "configure".
- In `HEATCOOL` the TargetTemperature characteristic has no handler and keeps its last value.
- Several HomeKit viewers on one camera each start their own SDM stream.
- Two-way audio isn't supported.
- Cached accessories for devices that were removed are never deleted. Relation events are ignored.
- The device list is read once: new devices need a restart, plus re-consent in PCM if the device wasn't shared.

---

## 8. Logging (paraphrased) and secrets

Info:
- "Loading accessory from cache: <name>"
- "Restoring existing accessory from cache: <name>"
- "Adding new accessory: <name>"
- "<name> identified!"

Errors:
- Configuration invalid. **[source bug]** The source dumps the whole config.
- Event subscription failed; read the README's config section.
- Could not handle event: <message>.
- Could not execute device LIST request / device GET request / device command: "HTTP <status>: <API message, at most 300 characters>".
- Google rate-limited the GetDevice API, or the <command> command; wait about a minute.
- Could not fetch the event image: <status/message>.
- Unable to start stream: camera info not received / no response from the Nest API.
- Failed to start stream: <spawn error>. (The README calls out "spawn ffmpeg ENOENT", meaning FFmpeg isn't installed.)
- FFmpeg exited with code X and signal Y: (Expected) at debug, (Unexpected) or (Error) at error level.
- Socket error.
- Errors closing the socket, killing FFmpeg, or tearing down the SDM, peer or UDP streams.
- Encountered an unexpected error on the recording generator.

Debug:
- Each received event payload in full.
- The device list.
- Each command with its parameters and its results.
- The FFmpeg command line.
- "Motion detected!" and "Doorbell ring!"
- The "Update <Characteristic>: <value>" and "Triggered GET/SET <Characteristic>" lines.
- "Video stream requested: W x H, fps, kbps".
- "Reconfigure (ignored)".
- "Device appears to be inactive. Stopping stream."
- "Stopped video stream."
- The WebRTC startup milestones ("[startup +N ms] ..."): ICE and connection states, video track received, first RTP, first keyframe, keyframe fully received in N packets, the frames after the keyframe, first REMB sent.
- The FFmpeg milestones.
- MP4 box types and lengths.
- "Camera event is too old (N sec), ignoring."

Secrets, never to be logged. The source's error formatter takes care to log only the HTTP status and Google's message, never the request with its Authorization header. Its debug lines still print several of these, and a replacement must mask them:
- `clientSecret`, `refreshToken` and OAuth access tokens: the Bearer header and the token endpoint's responses.
- `streamUrls.rtspUrl`: it embeds the stream token as `auth=`. Also `streamToken`, `streamExtensionToken` and `mediaSessionId`. All of these appear in the command-results debug line and in the FFmpeg command line.
- The `token` and `url` from GenerateImage. The token is sent as `Authorization: Basic`.
- The SRTP key and salt: the base64 `-srtp_out_params` on the FFmpeg command line.
- `offerSdp` and `answerSdp`: they carry ICE credentials and DTLS fingerprints.
- `userId` in events, and `subscriptionId`/`projectId`, are identifiers rather than secrets. Device resource names and room names are personal data.

---

## 9. Test vectors (made-up data; ids and names are placeholders)

### 9.1 Device list response (`GET /v1/enterprises/PROJECT-UUID/devices`)

```json
{
  "devices": [
    {
      "name": "enterprises/PROJECT-UUID/devices/THERMOSTAT-ID",
      "type": "sdm.devices.types.THERMOSTAT",
      "assignee": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-1",
      "traits": {
        "sdm.devices.traits.Info": { "customName": "" },
        "sdm.devices.traits.Humidity": { "ambientHumidityPercent": 42 },
        "sdm.devices.traits.Connectivity": { "status": "ONLINE" },
        "sdm.devices.traits.Fan": { "timerMode": "OFF" },
        "sdm.devices.traits.ThermostatMode": { "mode": "HEAT", "availableModes": ["HEAT", "COOL", "HEATCOOL", "OFF"] },
        "sdm.devices.traits.ThermostatEco": { "availableModes": ["OFF", "MANUAL_ECO"], "mode": "OFF", "heatCelsius": 9.7, "coolCelsius": 29.4 },
        "sdm.devices.traits.ThermostatHvac": { "status": "HEATING" },
        "sdm.devices.traits.Settings": { "temperatureScale": "FAHRENHEIT" },
        "sdm.devices.traits.ThermostatTemperatureSetpoint": { "heatCelsius": 20.5 },
        "sdm.devices.traits.Temperature": { "ambientTemperatureCelsius": 19.8 }
      },
      "parentRelations": [
        { "parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-1", "displayName": "Hallway" }
      ]
    },
    {
      "name": "enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID",
      "type": "sdm.devices.types.CAMERA",
      "traits": {
        "sdm.devices.traits.Info": { "customName": "" },
        "sdm.devices.traits.CameraLiveStream": {
          "maxVideoResolution": { "width": 1920, "height": 1080 },
          "videoCodecs": ["H264"], "audioCodecs": ["AAC"], "supportedProtocols": ["RTSP"]
        },
        "sdm.devices.traits.CameraImage": { "maxImageResolution": { "width": 1920, "height": 1200 } },
        "sdm.devices.traits.CameraPerson": {},
        "sdm.devices.traits.CameraSound": {},
        "sdm.devices.traits.CameraMotion": {},
        "sdm.devices.traits.CameraEventImage": {}
      },
      "parentRelations": [
        { "parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-2", "displayName": "Garage" }
      ]
    },
    {
      "name": "enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID",
      "type": "sdm.devices.types.DOORBELL",
      "traits": {
        "sdm.devices.traits.Info": { "customName": "" },
        "sdm.devices.traits.CameraLiveStream": {
          "videoCodecs": ["H264"], "audioCodecs": ["OPUS"], "supportedProtocols": ["WEB_RTC"]
        },
        "sdm.devices.traits.CameraImage": { "maxImageResolution": { "width": 1920, "height": 1200 } },
        "sdm.devices.traits.CameraPerson": {},
        "sdm.devices.traits.CameraMotion": {},
        "sdm.devices.traits.DoorbellChime": {},
        "sdm.devices.traits.CameraClipPreview": {}
      },
      "parentRelations": [
        { "parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-3", "displayName": "Front Door" }
      ]
    },
    {
      "name": "enterprises/PROJECT-UUID/devices/DISPLAY-ID",
      "type": "sdm.devices.types.DISPLAY",
      "traits": {
        "sdm.devices.traits.CameraLiveStream": {
          "maxVideoResolution": { "width": 1280, "height": 720 },
          "videoCodecs": ["H264"], "audioCodecs": ["AAC"], "supportedProtocols": ["RTSP"]
        },
        "sdm.devices.traits.CameraMotion": {},
        "sdm.devices.traits.CameraEventImage": {}
      },
      "parentRelations": [
        { "parent": "enterprises/PROJECT-UUID/structures/STRUCT-ID/rooms/ROOM-4", "displayName": "Kitchen" }
      ]
    },
    {
      "name": "enterprises/PROJECT-UUID/devices/OTHER-ID",
      "type": "sdm.devices.types.LOCK",
      "traits": {},
      "parentRelations": []
    }
  ]
}
```

Expected result, with `showFan: true`:

| Accessory | Name | Category | UUID seed | Notes |
|---|---|---|---|---|
| thermostat | "Hallway Thermostat" | THERMOSTAT | `enterprises/PROJECT-UUID/devices/THERMOSTAT-ID` | |
| fan | "Hallway Thermostat Fan" | FAN | `enterprises/PROJECT-UUID/devices/THERMOSTAT-ID Fan` | |
| camera | "Garage Camera" | CAMERA | its name | RTSP, 11 stream services |
| doorbell | "Front Door Doorbell" | VIDEO_DOORBELL | its name | WebRTC |
| display | "Kitchen Display" | CAMERA | its name | RTSP, 3 stream services |
| lock | – | – | – | skipped |

Thermostat checks:
- Fahrenheit, so: settable range 10.0–32.222, readable range −17.778–71.111.
- TargetHeatingCoolingState valid values [1, 2, 3, 0] and value 1. CurrentHeatingCoolingState 1.
- TargetTemperature 20.5 (read and write). HeatingThreshold reads 20.5 and CoolingThreshold reads 20.0 (heat − 0.5); both are read only.
- Eco false. TemperatureDisplayUnits 1. Humidity 42. Fan On false.

UUID check: `uuid.generate("enterprises/PROJECT-UUID/devices/THERMOSTAT-ID")` must equal what HAP-NodeJS yields for the same string. Compute both and compare in a test.

### 9.2 Commands (request bodies)

| Action | Request body |
|---|---|
| Heat to 21 °C | `{"command":"sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat","params":{"heatCelsius":21}}` |
| Auto range, after a heating-threshold write of 19 with a cached cool of 24 | `{"command":"sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange","params":{"heatCelsius":19,"coolCelsius":24}}` |
| Mode AUTO | `{"command":"sdm.devices.commands.ThermostatMode.SetMode","params":{"mode":"HEATCOOL"}}` |
| Eco on | `{"command":"sdm.devices.commands.ThermostatEco.SetMode","params":{"mode":"MANUAL_ECO"}}` |
| Fan on, `fanDuration` 900 | `{"command":"sdm.devices.commands.Fan.SetTimer","params":{"timerMode":"ON","duration":"900s"}}` |
| RTSP | `{"command":"sdm.devices.commands.CameraLiveStream.GenerateRtspStream","params":{}}` |

RTSP response:
```json
{"results":{"streamUrls":{"rtspUrl":"rtsps://stream-xx.sdm.example/v1/CjZ…?auth=STREAM-TOKEN"},"streamExtensionToken":"EXT-TOKEN","streamToken":"STREAM-TOKEN","expiresAt":"2026-01-01T12:05:00.000Z"}}
```

RTSP stop:
```json
{"command":"sdm.devices.commands.CameraLiveStream.StopRtspStream","params":{"streamExtensionToken":"EXT-TOKEN"}}
```

WebRTC:
```json
{"command":"sdm.devices.commands.CameraLiveStream.GenerateWebRtcStream","params":{"offerSdp":"v=0\r\no=- … \r\nm=audio 9 UDP/TLS/RTP/SAVPF 96\r\n…a=recvonly\r\n…m=video 9 UDP/TLS/RTP/SAVPF 97\r\n…m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n…\r\n"}}
```

WebRTC response:
```json
{"results":{"answerSdp":"v=0\r\n…","expiresAt":"2026-01-01T12:05:00.000Z","mediaSessionId":"MEDIA-SESSION-ID"}}
```

Event image request:
```json
{"command":"sdm.devices.commands.CameraEventImage.GenerateImage","params":{"eventId":"EVENT-ID-INNER"}}
```

Event image response:
```json
{"results":{"url":"https://domain/sdm_event_snapshot/dGNUlTU2CjY5Y3VKaTZwR3o4Y1…","token":"IMAGE-TOKEN"}}
```

The image is then fetched with `GET <url>` and header `Authorization: Basic IMAGE-TOKEN`.

### 9.3 Pub/Sub (pull REST shape; `data` is base64 of the JSON events below)

```json
{"receivedMessages":[{"ackId":"ACK-1","message":{"data":"eyJldmVudElkIjoi…","messageId":"1234567890","publishTime":"2026-01-01T12:00:01.123Z"}}]}
```

**Trait events.**

Mode change:
```json
{"eventId":"E1","timestamp":"2026-01-01T12:00:01Z","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/THERMOSTAT-ID","traits":{"sdm.devices.traits.ThermostatMode":{"mode":"COOL","availableModes":["HEAT","COOL","HEATCOOL","OFF"]}}},"userId":"USER-ID","resourceGroup":["enterprises/PROJECT-UUID/devices/THERMOSTAT-ID"]}
```
Expected: "configure" runs again and TargetHeatingCoolingState becomes 2.

Partial setpoint:
```json
{"eventId":"E2","timestamp":"2026-01-01T12:00:02Z","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/THERMOSTAT-ID","traits":{"sdm.devices.traits.ThermostatTemperatureSetpoint":{"coolCelsius":24.5}}},"userId":"USER-ID"}
```
Expected in COOL: TargetTemperature becomes 24.5.

Eco on:
```json
{"eventId":"E3","timestamp":"2026-01-01T12:00:03Z","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/THERMOSTAT-ID","traits":{"sdm.devices.traits.ThermostatEco":{"availableModes":["OFF","MANUAL_ECO"],"mode":"MANUAL_ECO","heatCelsius":9.7,"coolCelsius":29.4}}},"userId":"USER-ID"}
```
Expected: "configure" runs (eco branch). Heating threshold 9.7, cooling 29.4, target state 0, Eco true.

Other trait events:
- `{"sdm.devices.traits.Temperature":{"ambientTemperatureCelsius":21.3}}` sets CurrentTemperature to 21.3.
- `{"sdm.devices.traits.Humidity":{"ambientHumidityPercent":47}}` sets humidity to 47.
- `{"sdm.devices.traits.ThermostatHvac":{"status":"COOLING"}}` sets CurrentHeatingCoolingState to 2.
- `{"sdm.devices.traits.Fan":{"timerMode":"ON","timerTimeout":"2026-01-01T12:15:00Z"}}` sets Fan On to true.
- `{"sdm.devices.traits.Settings":{"temperatureScale":"CELSIUS"}}` sets display units to 0. The ranges are recomputed only at the next "configure".

**Device events.**

Motion on an RTSP camera:
```json
{"eventId":"E10","timestamp":"<now>","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID","events":{"sdm.devices.events.CameraMotion.Motion":{"eventSessionId":"SESSION-1","eventId":"EVENT-ID-INNER"}}},"userId":"USER-ID","resourceGroup":["enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID"]}
```
Expected: GenerateImage with `EVENT-ID-INNER`, the image fetched, MotionDetected true, then false after 20 s.

Chime on a WebRTC doorbell:
```json
{"eventId":"E11","timestamp":"<now>","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID","events":{"sdm.devices.events.DoorbellChime.Chime":{"eventSessionId":"SESSION-2","eventId":"EVENT-ID-2"}}},"userId":"USER-ID","eventThreadId":"THREAD-1","eventThreadState":"STARTED","resourceGroup":["enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID"]}
```
Expected: ProgrammableSwitchEvent 0. No image fetch.

Cases that must do nothing:
- The same chime with `"eventThreadState":"UPDATED"` or `"ENDED"`.
- Any device event whose `timestamp` is more than 30 s old.
- Person on a WebRTC camera, `{"sdm.devices.events.CameraPerson.Person":{"eventSessionId":"S","eventId":"I"}}`, gives the motion signal with no image fetch.
- Sound on a WebRTC camera does nothing. On an RTSP camera it fetches the image only.
- A relation event:
  ```json
  {"eventId":"E20","timestamp":"…","relationUpdate":{"type":"CREATED","subject":"enterprises/PROJECT-UUID/structures/STRUCT-ID","object":"enterprises/PROJECT-UUID/devices/NEW-ID"},"userId":"USER-ID"}
  ```
  is acked and ignored.
- `data` that isn't JSON is acked, logged and ignored.

### 9.4 REMB and FIR bytes

REMB for 4 Mbps, target SSRC `0x11223344`, sender SSRC `0xAABBCCDD`:
- Common header `8F CE 00 05`: V=2, P=0, FMT=15, PT=206, length 5.
- Sender SSRC `AA BB CC DD`, media SSRC `00 00 00 00`, then `52 45 4D 42` ("REMB").
- Then `01`, the SSRC count, followed by a 6-bit exponent (4) and an 18-bit mantissa (250000 = 0x3D090): the 3 bytes are `13 D0 90`.
- Then the target SSRC `11 22 33 44`.

FIR, sequence 0: header `84 CE 00 04`, then `AA BB CC DD 11 22 33 44 11 22 33 44 00 00 00 00`.

---

## 10. Gaps and open points

1. **WebRTC stack (hard).**
   - ICE, DTLS-SRTP, SCTP data channel negotiation and RTCP feedback, from Swift on macOS and Linux, without a new package dependency.
   - Not determined from the source: the ICE servers used (the library's defaults), whether the offer carries candidates, and which DTLS role and cipher suites Google accepts.
   - Google's documented offer requirements and the PT 96/97 assumption are fixed points.
   - Expect to test against a real 2021+ Nest Cam or Doorbell.
2. **Stream lifetime.**
   - The source never extends streams, so live views and recordings stop at about 5 minutes (README FAQ).
   - Using ExtendRtspStream: RTSP needs a reconnect only if the token in the URL changes; Google's docs give a new `streamToken`, and whether the running RTSP session survives isn't determined.
   - Using ExtendWebRtcStream works only on wired cameras: battery cameras accept it only while charging, and battery doorbells reject it.
   - Either would be an improvement, not a behavioural match.
3. **Snapshots** are placeholders or recent event images. That's by design, to save quota. WebRTC devices only ever show the placeholder.
4. **Trait event merge** is wholesale (4.2, step 5). It's unclear how often Google sends partial traits beyond setpoints.
5. **The Pub/Sub transport.**
   - The source uses gRPC streaming pull with OAuth user credentials. REST pull plus acknowledge is the practical equivalent; its flow-control and back-off details aren't specified by the source.
   - Google is retiring Google-hosted topics. By 2026-11-30 projects must use a topic in their own Cloud project. That doesn't change the subscription interface.
6. **No reconnect paths.** After a list failure at startup, a subscription error or a revoked token, the plugin never recovers without a restart.
7. **Source bugs a replacement should not copy:**
   - the full config with its secrets in the startup error log;
   - Fan `duration` "undefineds" and a duration sent with OFF;
   - the Fan trait event falling through into the HVAC handler;
   - the motion-clear timer race;
   - an empty `-filter:v`;
   - `-an` in the HKSV output, which drops recording audio;
   - characteristic writes reporting success when the SDM command failed;
   - the unhandled exception on a setpoint event in eco while the mode is HEAT/COOL;
   - the Accessory Information Manufacturer never being applied.
   
   Whether to fix the behaviour HomeKit sees (writes failing visibly, recordings with audio) is the implementer's call. Ids and names are unaffected.
8. **Placeholder images:** a replacement must supply its own 1920x1080 JPEGs, without Google or Nest marks.
9. **Not determined:**
   - the exact HAP-NodeJS iids that Homebridge gave the CameraController's services, which is irrelevant if Homeswift keys iids by service UUID and subtype;
   - whether Google ever returns more than one page of devices;
   - how displays (Nest Hub Max) behave with WebRTC: their trait advertises RTSP.
