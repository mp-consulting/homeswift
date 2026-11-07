# SmartThings: functional specification (clean room)

## 0. Provenance

Written by the spec writer; contains no source code. Everything below is in the spec writer's own words. JSON keys,
endpoint paths, enum values, capability, attribute and command names are interface facts.

Sources read (all on 2026-11-07):

| Source | What | Commit / version | License, copyright line |
|---|---|---|---|
| https://github.com/aziz66/homebridge-smartthings | npm `homebridge-smartthings-oauth` 1.0.68 ("Final release"), a fork of the next one | `7984d5ffd8da34b13d18593829a6605ad69c8636` (2026-09-25) | Apache-2.0. The LICENSE file is the stock Apache text with no copyright line; `package.json` has no `author`. Owner: GitHub user aziz66. |
| https://github.com/iklein99/homebridge-smartthings | npm `homebridge-smartthings-ik` 1.5.22 | `ea914c9259b099caf9c6aa79c77b62fd34687fc8` (2024-11-29) | Apache-2.0, stock text, no copyright line, no `author`. Owner: GitHub user iklein99. |
| https://github.com/SmartThingsCommunity/smartthings-core-sdk | `@smartthings/core-sdk` 9.0.0, the official JavaScript SDK | `1784e2ba7af73498a0db8d42fce756fb4d7a0a78` (2026-11-04) | Apache-2.0, stock text. Read for endpoint paths and object shapes only. |
| developer.smartthings.com, blog.smartthings.com, community.smartthings.com | Official docs and announcements | as of 2026-11-07 | URLs cited inline |

Both Homebridge plugins use the `pluginAlias` **`HomeBridgeSmartThings`**, `pluginType: platform`, `singular: true`.

Tags on facts:
- **[official]** developer.smartthings.com, blog.smartthings.com or a SmartThings staff post (URL given at the section or the line).
- **[sdk]** the official SDK at the commit above (file named).
- **[aziz66]** / **[ik]** what that Homebridge plugin does (behaviour, described, not to be copied blindly).
- **[community]** a SmartThings community forum post by a user, not staff.
- **[Homeswift]** a requirement of this port, decided with the user or by the spec writer (the latter said so).
- **[unverified]** could not be confirmed from an official source; treat as a best guess and keep it easy to change.

Main official pages relied on:
- Plans: https://developer.smartthings.com/smartthingsapi
- Plan dates: https://blog.smartthings.com/smartthings-updates/smartthings-api-additional-details-for-developers-and-business-partners/ and https://community.smartthings.com/t/a-new-enhanced-smartthings-api-experience/309947
- App setup and scopes: https://developer.smartthings.com/docs/service-integrations/app-setup
- OAuth: https://developer.smartthings.com/docs/service-integrations/oauth
- Token management: https://developer.smartthings.com/docs/service-integrations/token-management
- SSE: https://developer.smartthings.com/docs/service-integrations/sse-subscriptions
- Webhook subscriptions: https://developer.smartthings.com/docs/service-integrations/subscribe-to-events and https://developer.smartthings.com/docs/service-integrations/webhook-events
- Devices: https://developer.smartthings.com/docs/service-integrations/query-and-list-devices and https://developer.smartthings.com/docs/service-integrations/control-devices
- Rate limits: https://developer.smartthings.com/docs/getting-started/rate-limits
- Capabilities: https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference (rendered by script; read in a browser)
- PAT change: https://community.smartthings.com/t/changes-to-personal-access-tokens-pat/292019 (official SmartThings account, 2024-12-13)

---

## 1. Overview

SmartThings is Samsung's cloud for smart-home devices (its own hubs' Zigbee, Z-Wave, Matter and LAN devices, Samsung
appliances and TVs, and cloud-to-cloud devices). The plugin reaches it only through the cloud REST API at
`https://api.smartthings.com/v1`, signed in with OAuth 2.0 on the person's own "API Access App" (OAuth-In app). There
is no local control in this port (aziz66's local Samsung TV WebSocket is out of scope, section 9.5).

Homeswift plugin: directory `Plugins/SmartThings`, target `HomeswiftSmartThings`, platform name
**`HomeBridgeSmartThings`**, display name **SmartThings**. **Device Id = SmartThings `deviceId`** (a UUID, kept as
SmartThings writes it, lower case with dashes). Accessory Id = `HomeBridgeSmartThings:<deviceId>`. Scenes are
Discovered Devices too, Device Id `scene:<sceneId>` (section 11).

What it exposes (section 7 onward):
- one accessory per SmartThings device, its services chosen from the capabilities of each of its components;
- Samsung appliances (washer, dryer, dishwasher, oven/range, refrigerator, robot vacuum, air purifier, air conditioner)
  with a power or start Switch, a "Running" Occupancy Sensor and compartment temperatures; extra values for the web UI;
- Samsung (and other) TVs as Television accessories published on their own (`context.publishExternal`);
- devices with the `securitySystem` capability as a Security System; SmartThings Home Monitor itself is not reachable
  (section 10);
- SmartThings scenes as momentary switches;
- nothing for devices that are copies of Homeswift's own accessories through Homeswift's Matter bridge (section 12).

Updates arrive through the official Server-Sent Events stream when the token has the `sse` scope, else by polling
one device list call that carries every device's status (section 5).

**Paid API.** Since 2026-11-04 the SmartThings API for individuals requires a SmartThings **Developer plan**
($4.99/month, 100,000 API calls a month); accounts without a plan lose API access from 2026-12-15 (section 13.1).

---

## 2. Configuration interface

### 2.1 aziz66 (`homebridge-smartthings-oauth`) block — the names Homeswift keeps

Defaults are the plugin's schema defaults **[aziz66]**; "Homeswift" says what the port does.

| Key | Type | Default | aziz66 meaning | Homeswift |
|---|---|---|---|---|
| `platform` | string | — | `HomeBridgeSmartThings` | required |
| `name` | string | `Smartthings Plug (IK)` | log name | honoured (instance name) |
| `BaseURL` | string | `https://api.smartthings.com/v1/` | API base (trailing slash) | honoured if it is an `https` URL on `api.smartthings.com` or `api.samsungiotcloud.cn` (the SDK's China base, **[sdk]** `endpoint-client.ts`); anything else is refused with a settings error. Paths below are relative to it. |
| `client_id` | string | — (required) | OAuth client id | honoured; moved to the vault by Setup (2.3) |
| `client_secret` | string | — (required, `format: password`) | OAuth client secret | honoured; secret (2.3) |
| `server_url` | string | — | public URL of the webhook server; also the OAuth redirect base (`<server_url>/oauth/callback`) when set | **loaded and ignored** for webhooks (13.4). Not used as a redirect base. |
| `oauth_access_token` | string | — | written by aziz66's wizard | read once as a starting access token, then moved to the vault (3.9) |
| `oauth_refresh_token` | string | — | written by the wizard | read once as a starting refresh token, then moved to the vault (3.9) |
| `oauth_expires_in` | integer | — (wizard writes 86400 when blank) | lifetime of `oauth_access_token`, seconds | read with the two above; dropped after the move |
| `webhook_port` | integer | 3000 | local port of the webhook server (also served `/oauth/callback`) | loaded and ignored |
| `verifyWebhookSignatures` | boolean | false | verify SmartThings HTTP signatures on webhook POSTs | loaded and ignored |
| `selectedCapabilities` | array of string, ≤ 20 | [] | capabilities to subscribe by webhook | loaded and ignored |
| `PollLocksSeconds` | integer | 10 | per-characteristic poll period, 0 = no poll | read (5.4) |
| `PollDoorsSeconds` | integer | 10 | | read (5.4) |
| `PollSensorsSeconds` | integer | 5 (code falls back to 10 when absent) | | read (5.4) |
| `PollSecuritySystemsSeconds` | integer | 15 | | read (5.4) |
| `PollSwitchesAndLightsSeconds` | integer | 10 | also used by appliances, buttons | read (5.4) |
| `PollTelevisionsSeconds` | integer | 15 | | read (5.4) |
| `PollWindowShadesSeconds` | integer | 20 | | read (5.4) |
| `PollEnergySeconds` | integer | 30 | | read (5.4) |
| `registerVolumeSlider` | boolean | false | add a Lightbulb "<name> Volume" to TVs | honoured (9.3) |
| `ExposeHumiditySensorForAirConditioners` | boolean | false | Humidity Sensor on ACs | honoured (7.3.10) |
| `ExposeACDisplayLight` | boolean | false | Lightbulb for `samsungce.airConditionerLighting` | honoured (7.3.10) |
| `ExposeContactSensorForWashers` / `…Dryers` / `…Dishwashers` | boolean | false | a Contact Sensor "<name> Activity" (open while running) for Home app notifications | loaded and ignored: the "Running" Occupancy Sensor replaces it (8.2) |
| `ExposeMultiZoneRefrigerator` | boolean | false | per-compartment temperatures from Samsung's OCF `driverState`, disabled compartments pruned | per-compartment temperatures always; the `driverState` fallback only when true (8.5) |
| `ExposeZigbangSmartDoorlock` | boolean | false | Lock for a Zigbang lock's custom capabilities | honoured (7.3.13) |
| `ExposeEnergyMonitoring` | boolean | false | Eve power/energy characteristics on switches and outlets | honoured for the Eve characteristics; energy is a Homeswift Meter regardless (7.3.14) |
| `ExposeEnergyAsOutlet` | boolean | false | energy-reporting switches become Outlets (needs the one above) | honoured |
| `ExposeRobotVacuum` | boolean | false | Switch for Samsung robot vacuums | **absent means true** in Homeswift (no legacy tiles to protect); `false` honoured (8.6) |
| `removeLegacySwitchForLaundry` | boolean | false | no power Switch on washers, dryers, dishwashers | honoured (8.2) |
| `OptionalModeForAirConditioners` | enum `None`, `Sleep`, `Speed`, `WindFree`, `WindFreeSleep`, `Speed and Windfree` | `None` | extra Switch(es) for `custom.airConditionerOptionalMode` | honoured (7.3.10) |
| `enableTelevisionService` | boolean | true | TVs as Television; false = plain switches | honoured |
| `removeLegacySwitchForTV` | boolean | false | drop the extra Switch aziz66 keeps on TVs | Homeswift never adds that Switch to the Television; the key is loaded and has nothing left to do |
| `publishTVsAsExternal` | boolean | true | publish TVs on their own HAP server | honoured; `false` keeps the TV on the bridge (9.1) |
| `IgnoreLocations` | array of string (location names) | — | drop devices in these locations, case-insensitive | honoured: Excluded (2.4) |
| `IgnoreDevices` | array of string (device labels) | — | drop these devices; names compared after normalising ’‘ to `'` and “” to `"`, case-insensitive, trimmed; ignored when `ShowOnlyDevices` has entries | honoured: Excluded (2.4) |
| `ShowOnlyDevices` | array of string | — | only these devices (same normalisation); takes precedence over `IgnoreDevices` | honoured: all others Excluded (2.4) |
| `tvApps` | array of app-id strings (enum of 19 Samsung app ids, `uniqueItems`) | [] | extra TV inputs that launch apps | honoured (9.2) |
| `frameTvDevices` | array of `{deviceName, ip, enableFullPowerOff = true, enableArtModeSwitch = true, infoButtonKey = "KEY_INFO", token}` | — | local WebSocket control of Samsung Tizen TVs (power off, Art Mode, D-pad) | **loaded and ignored** (9.5). `token` is secret-named. |
| `thermostatModeOverrides` | array of `{deviceName, heatMode = "heat", coolMode = "cool"}` | — | thermostatMode sent for HomeKit HEAT/COOL, by device name (case-insensitive) | honoured; canonical form is Plugin Accessory Settings `heatMode`/`coolMode` (2.4) |
| `UnregisterAll` | boolean (not in schema, read by code) | — | unregister every cached accessory at start | loaded and ignored |

`tvApps` enum (app id → name) **[aziz66]**: `3201907018807` Netflix, `3201910019365` Prime Video, `3201512006785`
Prime Video (older TVs), `111299001912` YouTube, `3201611010983` YouTube Kids, `3201606009684` Spotify,
`3201901017640` Disney+, `3201601007625` Hulu, `3201710014981` Paramount+, `3201807016597` Apple TV,
`3202006020991` Peacock TV, `3201710015037` Gallery, `3202301029760` HBO Max, `111477000821` Shahid,
`3201608010191` Deezer, `3201806016390` DAZN, `3201708014618` ESPN, `3202410037239` BeIN Sports,
`3201908019041` Apple Music.

### 2.2 ik (`homebridge-smartthings-ik`) block — loads too

Same `pluginAlias`. Keys not listed in 2.1:

| Key | Type | Default | ik meaning | Homeswift |
|---|---|---|---|---|
| `AccessToken` | string (required in ik) | "" | a SmartThings Personal Access Token, sent as the bearer on every call | accepted only as a **starting token** (3.10) |
| `WebhookToken` | string | "" | token for ik's own relay service `https://stwh.kleinstudios.net/api/` (long-poll `POST clientrequest`) | loaded and ignored; never contacted |
| `GarageDoorMaxPoll` | integer (required) | 40 | declared, never read by ik's code | loaded and ignored |

ik also has `name`, `BaseURL`, `PollLocksSeconds`, `PollDoorsSeconds`, `PollSensorsSeconds`, `PollSwitchesAndLightsSeconds`,
`PollWindowShadesSeconds`, `ExposeHumiditySensorForAirConditioners`, `OptionalModeForAirConditioners` (enum without
`None` and `Speed and Windfree`, default `None` anyway), `IgnoreLocations`, `IgnoreDevices` (compared lower-case, no
quote normalisation), and reads the undocumented `UnregisterAll`. Same meaning as 2.1.

A block may mix both plugins' keys (aziz66's schema still carries `BaseURL` and the ik defaults).

### 2.3 Secrets

`Redaction.secretKeyPattern` (Sources/HomeswiftAI/Redaction.swift) matches, case-insensitively, keys containing
`secret` or `token` (among others), unless `Redaction.notSecretKeyPattern` matches (`token_type` and token counts).
Applied to this plugin's keys:

| Key | Matches? | Consequence |
|---|---|---|
| `client_secret` | yes (`secret`) | sealed, resolved, masked by the runtime |
| `client_id` | **no** | a plain string in config.json; not masked by the key rule |
| `oauth_access_token`, `oauth_refresh_token` | yes (`token`) | sealed and masked |
| `oauth_expires_in` | no | harmless |
| `AccessToken`, `WebhookToken` | yes (`token`) | sealed and masked |
| `frameTvDevices[].token` | yes | sealed and masked |
| `server_url`, `webhook_port` | no | not secrets |

**[Homeswift]** The client id is not a secret by OAuth's standards but the user decided to keep both as secrets:
Setup stores `client_id` **and** `client_secret` in the vault through `SetupOutcome.credentials` (read back with
`context.credentials(for:as:)`), and `canonicalSettings` drops both keys from the block once the vault holds them
(the move itself in `context.whenSettingsWritten`). A pasted aziz66 block keeps working before that: its
`client_secret` is sealed by the key rule, its `client_id` sits in clear text until the first settings write; the
README says so. Tokens never stay in the block (3.7).

### 2.4 What Homeswift writes (canonical shape)

`canonicalSettings` turns the Homebridge shapes into Accessory Settings in `_accessories` by Device Id
(docs/adr/0001-canonical-accessory-settings.md):
- `IgnoreDevices` → `_accessories[<deviceId>].excluded = true` for each device whose label matches (normalisation of 2.1);
  `ShowOnlyDevices` (non-empty) → every other device Excluded, the listed ones not; `IgnoreLocations` → every device
  whose `locationId` is a location of that name Excluded. Names that match nothing now stay in the block (as
  `AccessoryEntries` does for an exclude list it cannot read). The legacy keys are then dropped.
- `thermostatModeOverrides[]` → `_accessories[<deviceId>].heatMode` / `.coolMode` (Plugin Accessory Settings, Device
  Kind `thermostat`), matched by device label, case-insensitive.
- `client_id`, `client_secret`, `oauth_*`, `AccessToken` → vault (3.7, 3.9, 3.10), dropped from the block.
- Everything else stays as it is (aziz66's option names are the Plugin Settings), and is declared in
  `config.schema.json` (docs/adr/0002-schema-declares-every-setting.md), the ignored ones described as "kept from
  homebridge-smartthings; has no effect in Homeswift".

New Plugin Settings Homeswift adds (Setup writes them): `callbackServerExternalAddress` (string, default: this
host's detected LAN address) and `callbackServerPort` (integer, default **8583**; DaikinCloud uses 8582), which make
the redirect URI `https://<address>:<port>/oauth/callback` (3.4); `locationId` (string, the location the
Authorization was granted for, 3.3).

Plugin Accessory Settings (in `accessorySchema`) the port declares, at least:

| Key | Kinds | Type | Default (`x-default`) | Meaning |
|---|---|---|---|---|
| `heatMode` | thermostat | string | `heat` | thermostatMode sent for HomeKit HEAT |
| `coolMode` | thermostat | string | `cool` | thermostatMode sent for HomeKit COOL |
| `optionalMode` | airConditioner | enum as `OptionalModeForAirConditioners` | `OptionalModeForAirConditioners` | 7.3.10 |
| `exposeHumidity` | airConditioner | boolean | `ExposeHumiditySensorForAirConditioners` | 7.3.10 |
| `displayLight` | airConditioner | boolean | `ExposeACDisplayLight` | 7.3.10 |
| `outlet` | switch | boolean | `ExposeEnergyAsOutlet` | Outlet instead of Switch |

### 2.5 Example blocks (fake values)

aziz66, as its wizard leaves it:

```json
{
  "platform": "HomeBridgeSmartThings",
  "name": "SmartThings",
  "BaseURL": "https://api.smartthings.com/v1/",
  "client_id": "7a850484-0000-4000-8000-000000000001",
  "client_secret": "3581f317-0000-4000-8000-000000000002",
  "oauth_access_token": "00000000-aaaa-4000-8000-000000000003",
  "oauth_refresh_token": "00000000-bbbb-4000-8000-000000000004",
  "oauth_expires_in": 86399,
  "PollSwitchesAndLightsSeconds": 10,
  "PollSensorsSeconds": 5,
  "ExposeHumiditySensorForAirConditioners": true,
  "OptionalModeForAirConditioners": "WindFree",
  "IgnoreDevices": ["Hallway Hub", "Kitchen Plug"],
  "thermostatModeOverrides": [{ "deviceName": "Floor Heating", "heatMode": "radiatingfloor" }],
  "tvApps": ["3201907018807", "111299001912"]
}
```

ik:

```json
{ "platform": "HomeBridgeSmartThings", "name": "Smartthings Plug (IK)", "BaseURL": "https://api.smartthings.com/v1/",
  "AccessToken": "00000000-cccc-4000-8000-000000000005", "WebhookToken": "", "GarageDoorMaxPoll": 40,
  "IgnoreLocations": ["Cabin"], "IgnoreDevices": ["Garage Light"] }
```

Canonical, after Setup (the tokens and client credentials in the vault):

```json
{ "platform": "HomeBridgeSmartThings", "name": "SmartThings", "BaseURL": "https://api.smartthings.com/v1/",
  "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "callbackServerPort": 8583,
  "PollSwitchesAndLightsSeconds": 10, "OptionalModeForAirConditioners": "WindFree",
  "_accessories": { "3e4f0d2c-0000-4000-8000-0000000000d7": { "excluded": true },
                    "9b1c2d3e-0000-4000-8000-0000000000d3": { "heatMode": "radiatingfloor" } } }
```

---

## 3. Authentication

### 3.1 Prerequisites **[official]**

- A Samsung account and a SmartThings **Developer plan** on it (https://developer.smartthings.com/smartthingsapi;
  plan management at `https://developer.smartthings.com/console/service-integrations/manage-plans`). From 2026-11-04 an
  account without a plan cannot create or edit API apps; from 2026-12-15 its "Active API keys will be deactivated"
  (blog URL in section 0). Details and open points in 13.1.
- An **API Access App** (the CLI calls it an "OAuth-In App") that the person creates for themselves. Its client id
  and secret are theirs; Homeswift ships no client.

### 3.2 Creating the app (steps for the README)

Two official ways **[official: app-setup]**: the Developer Center console (**Service Integrations → Get Started**) or the
SmartThings CLI. Registration asks for: App Display Name (public), **Redirect URIs**, Target URL (optional, webhooks
only), **OAuth scopes**, and a privacy policy (Business plan only). It gives an App ID, a **Client ID** and a
**Client Secret** (keep it confidential).

CLI path, as SmartThings Developer Support gives it **[community: staff reply,
https://community.smartthings.com/t/how-to-get-access-token-to-access-apis-2025/298670]** and aziz66's guide repeats it
**[aziz66: wiki-drafts/Installation-and-OAuth-Setup.md]**:

1. Install the SmartThings CLI (https://github.com/SmartThingsCommunity/smartthings-cli) and sign in.
2. Run `smartthings apps:create` **[unverified: the CLI's README now lists `smartapps:create`, `smartapps:oauth`,
   `smartapps:oauth:update` and `smartapps:oauth:generate`; the README should tell the person to run
   `smartthings --help` if `apps:create` is not found]**.
3. App type: **OAuth-In App**. Display name: e.g. `Homeswift`. Description: anything. Icon URL: skip.
   Target URL: leave empty if the CLI allows, else any https URL (it only serves webhooks, which Homeswift does not use).
4. Scopes: `r:devices:*`, `x:devices:*`, `r:locations:*`, `r:scenes:*`, `x:scenes:*`, and `sse` (13.3). The authorize
   request may only ask for scopes the app has, or it fails **[community: staff]**.
5. Redirect URI: the one Homeswift's Setup shows, `https://<this host's address>:8583/oauth/callback` (3.4). Adding
   `https://httpbin.org/get` as a second redirect URI is optional (paste fallback, 3.4).
6. Copy the **OAuth Client Id** and **OAuth Client Secret** at once: the CLI prints them once ("you will not be able to
   see the OAuth info again") **[aziz66 guide, reproducing the CLI's output; not stated on the official page]**.
   `smartapps:oauth:generate` makes a new pair **[CLI README]**.

### 3.3 Authorize request **[official: oauth]**

The person's browser opens:

`GET https://api.smartthings.com/v1/oauth/authorize?client_id=<clientId>&response_type=code&redirect_uri=<redirectUri>&scope=<scopes>&state=<state>`

- `scope`: space-separated, URL-encoded (`%20`): `r:devices:* x:devices:* r:locations:* r:scenes:* x:scenes:* sse`.
- `state`: random, unguessable (Homeswift: 32 random bytes as hex); kept in the Setup Session `state`, checked on return.
- `redirect_uri`: must match one registered with the app exactly.
- aziz66 and community posts use `https://api.smartthings.com/oauth/authorize` (no `/v1`); both are seen working
  **[aziz66, community]**. Homeswift uses the `/v1` form; on a 404 it may retry without `/v1` once.
- On the SmartThings page the person signs in, **picks one location** and approves **[aziz66 guide]**. Each authorized
  location is one installation (an `installed_app_id`), and the Developer plan allows up to 10 active installs
  **[official: blog]**. One Authorization therefore covers one location **[unverified that a single authorization can
  never span locations]**; Homeswift stores the location the devices come from as `locationId` (2.4).

Redirect back:
- success: `<redirectUri>?code=<code>&state=<state>` (the code is short-lived and single-use);
- refusal: `<redirectUri>?error=access_denied&state=<state>` → Setup says the person refused, asks again.
- A `state` that does not match → reject (error, no token request).

### 3.4 Catching the redirect (Browser Redirect) **[Homeswift]**

Authorization Method: `browserRedirect`, as DaikinCloud (`Plugins/DaikinCloud/Sources/DaikinSetup.swift`,
`CallbackServer.swift`):

1. First step asks for the client id, the client secret (field kind `secret`) and, optionally, the callback server's
   address and port; its message shows the redirect URI to register:
   `https://<callbackServerExternalAddress or detected address>:<callbackServerPort>/oauth/callback`.
2. Next step answers `.ask` with the authorize URL (3.3) as the prompt's `url`, a wait, and an optional field
   "Address the browser ended on" (kind `url`). Meanwhile a short-lived **HTTPS** callback server (self-signed
   certificate, TLS ≥ 1.2, like DaikinCloud's) listens on the port; a GET on `/oauth/callback` with `code` and `state`
   completes the Authorization and answers a small "You can close this page" page.
3. Fallback: the person pastes the final address (any URL whose query has `code` and `state`, e.g.
   `https://httpbin.org/get?code=…&state=…`). Parse its query; same checks.

Why HTTPS: SmartThings refuses `http://` redirect URIs (including `http://localhost`) at authorization time
(a 403), and only `https://` redirects work **[community: several threads incl. moderator,
https://community.smartthings.com/t/403-forbidden-when-using-oauth-authorize-endpoint-for-api-only-smartapp/309689;
not stated on an official page]**. The browser will warn about the self-signed certificate on the redirect; the
README says to accept it, or to use the paste fallback. Whether SmartThings accepts a redirect URI with a private IP
address or a `.local` name is **[unverified]**; the paste fallback covers it.

### 3.5 Token exchange **[official: oauth]**

`POST https://api.smartthings.com/v1/oauth/token`

Headers: `Content-Type: application/x-www-form-urlencoded`, `Accept: application/json`,
`Authorization: Basic <base64(clientId ":" clientSecret)>`.

Body: `grant_type=authorization_code&code=<code>&client_id=<clientId>&redirect_uri=<redirectUri>` (the same redirect URI
as the authorize request).

Response 200, `application/json;charset=UTF-8`:

| Field | Meaning |
|---|---|
| `access_token` | bearer for API calls (a UUID-looking string) |
| `token_type` | `bearer` |
| `refresh_token` | single-use refresh token |
| `expires_in` | seconds; "typically `86399`" (≈ 24 h); examples also show `86001` |
| `scope` | the scopes granted, space-separated; may differ from those asked |
| `access_tier` | integer (example 0); meaning not documented |
| `installed_app_id` | the installation (location) this token belongs to |
| `developer_account_id`, `iot_account_id`, `owner_account_id` | account ids |

Persist per Authorization: access token, refresh token, `installed_app_id`, expiry time (now + `expires_in`), granted
`scope` (to know whether `sse` was granted) **[official]**.

aziz66 sends the same request without `client_id` in the body (Basic header only) **[aziz66]**; both forms are seen
working. The official form includes it.

### 3.6 Refresh and rotation **[official: token-management]**

`POST https://api.smartthings.com/v1/oauth/token`, same headers, body
`grant_type=refresh_token&refresh_token=<latest refresh token>&client_id=<clientId>`. Response: same shape as 3.5,
**both tokens new**. "Once a refresh token is used, it is no longer valid." Refreshing also invalidates the old access
token. SmartThings asks that only one refresh be in flight per installed app and that both tokens be updated together.

Lifetimes: access token ≈ 24 h (`expires_in`); refresh token ≈ 30 days if unused (the app-setup page in search
results says 30 days; Developer Support says 29 **[community: staff]**). Homeswift refreshes at least daily, so the
refresh token only ages out if Homeswift is off for about a month.

Homeswift rules **[Homeswift]**:
- **Single flight**: one refresh at a time per Authorization; every caller waiting on a refresh shares its result.
- **Proactive**: refresh when 75 % of `expires_in` has elapsed (official recommendation), so ≈ every 18 h.
- **Reactive**: a 401 on an API call → if the token that call carried has already been replaced, retry with the new
  one; else refresh once and retry the call once. A second 401 → the error surfaces.
- **Save before use**: when a refresh answers, write the new pair (and expiry, `scope`, `installed_app_id`) to the
  vault (`context.secretFile`, 3.7) **before** the new access token is used for any call and before the new refresh
  token could ever be sent. If the write fails, keep the pair in memory, log an error, retry the write on every later
  call, and never refresh again until the pair is saved (a refresh with an unsaved token would leave the vault with a
  dead one). A crash between the response and the write loses the chain: the person signs in again (README says so).
- **Startup**: read the vault; if the access token is not expired (with 5 min margin) use it; else refresh.
- **Refused** (`400`/`401` with `error` `invalid_grant`, `invalid_client`, `unauthorized_client`, or any 4xx other than
  408 and 429 from the token endpoint): the chain is dead. Call `context.accountRefused("SmartThings refused the
  saved sign-in; sign in again")`, stop polling and SSE, keep the accessories (Not Responding). Network errors, 408,
  429 and 5xx are transient: keep the tokens, back off (6.2), try again.
- `invalid_grant` on the very first refresh of a CLI-created app is reported by users
  (https://community.smartthings.com/t/oauth-invalid-grant-on-refresh-token-api-only-oauth-in-app-via-cli/307142) with
  no answer **[community]**; Diagnostics must log the token endpoint's `error` and `error_description` (never tokens).

### 3.7 Persistence

`context.secretFile("smartthings_tokens.json", as: …)` (aziz66's file name, so a copied
`<storage>/smartthings_tokens.json` moves into the vault the first time it is read). Contents (aziz66's shape, which
Homeswift keeps reading and writing): `access_token`, `refresh_token`, `expires_in`, `expires_at` (epoch ms),
`refresh_token_expires_at` (epoch ms, now + 30 days at each new refresh token), `installed_app_id`, `location_id`, and
aziz66's `seeded_from_config_refresh_token_sha256` (hex SHA-256 of the config refresh token it was seeded from).
Homeswift adds `scope` (string). Never `jsonFile`.

aziz66 precedence, to reproduce when importing **[aziz66]**: the token file wins over the config's `oauth_*` keys,
except when the file was seeded from a config refresh token whose SHA-256 differs from the config's current
`oauth_refresh_token` (the wizard ran again since): then the config's tokens win.

The client id and secret are Setup credentials (2.3), not in this file.

### 3.8 Errors at sign-in

Token endpoint errors seen by aziz66 users **[aziz66 CHANGELOG]**: `invalid_grant` (code used twice, expired, or
redirect URI mismatch), `redirect_uri_mismatch`, `invalid_client` (wrong id/secret), `invalid_scope` (a scope the app
does not have), `unauthorized_client`. Setup throws `SetupError` with the OAuth `error` and `error_description` (and
asks again). A 403 on the authorize page with an `http://` redirect URI: see 3.4. A 403 from API calls after sign-in
because no Developer plan is active: see 6.3.

### 3.9 Importing aziz66's tokens

If the block holds `oauth_access_token` and `oauth_refresh_token` (and no vault entry exists), Homeswift takes them as
the starting pair (`expires_at` = now + `oauth_expires_in` or 86400 s), saves them to the vault, refreshes at once if
expired, and drops the three keys from the block (`whenSettingsWritten`). The plugin instance then counts as Authorized
(`accountAuthorized()` answers true while the vault holds a refresh token). A refused refresh → 3.6.

### 3.10 Personal Access Token (ik's `AccessToken`)

PATs created since 2024-12-30 expire after 24 hours, older ones were grandfathered, and the `/devices` limits for new
PATs are lower **[official: https://community.smartthings.com/t/changes-to-personal-access-tokens-pat/292019]**.
SmartThings now describes PATs as for "temporary, individual developer testing and lightweight scripts" **[official:
blog]**. **[Homeswift]**: `AccessToken` is used as the bearer until it fails; it cannot be refreshed. On its first 401
the instance Needs Authorization ("sign in with your own SmartThings app"). It is moved to the vault like the others.
Whether a PAT can open an SSE stream is **[unverified]**: treat it as polling-only.

---

## 4. REST API reference

### 4.1 Common

- Base: `https://api.smartthings.com/v1` (or `BaseURL`, 2.1). Paths below are relative to it.
- Headers on every call: `Authorization: Bearer <access_token>`, `Accept: application/json`,
  `User-Agent: Homeswift/<version> (SmartThings plugin)` (required by the SSE API, harmless elsewhere), and
  `Content-Type: application/json;charset=utf-8` with a JSON body.
- The SDK sends `Accept: application/vnd.smartthings+json;v=20170916` on `GET devices` and `GET devices/{id}`
  **[sdk: src/endpoint/devices.ts, `HEADER_OVERRIDES`]**; Homeswift sends the same on those two calls.
- Paging: list responses are `{ "items": [...], "_links": { "next": { "href": "<url>" }, "previous": {…} } }`;
  follow `_links.next.href` until absent **[sdk: src/pagination.ts]**. The href may be absolute or relative
  **[aziz66]**. Refuse a next link whose origin differs from the base URL's (the SDK does) **[sdk:
  src/endpoint-client.ts]**. Official docs only say "Pagination links (empty when all results fit in one page)".
- Timeouts: 15 s per call (aziz66 uses 15 s) **[Homeswift]**.

### 4.2 Locations

- `GET locations` → `{ "items": [ { "locationId": "<uuid>", "name": "Home", "parent": {…}? } ], "_links": {} }`
  **[sdk: src/endpoint/locations.ts]**. Used for `IgnoreLocations` names and the Setup step that shows which location
  was authorized. Scope `r:locations:*`. Rate: 100/min **[official: rate-limits]**.
- `GET locations/{locationId}` → also `countryCode`, `latitude`, `longitude`, `regionRadius`, `temperatureScale`
  (`F`|`C`), `timeZoneId`, `locale`, `created`, `lastModified` **[sdk]**. `temperatureScale` is a hint only;
  every temperature attribute carries its own unit.
- Rooms (optional, for a Room hint in Discovered Devices): `GET locations/{locationId}/rooms` → items
  `{ "roomId", "locationId", "name" }` **[sdk: src/endpoint/rooms.ts, unverified field list]**; 50 requests/hour
  **[official]**, so read at most once per discovery.

### 4.3 Devices

**List**: `GET devices` with query parameters **[sdk: DevicesEndpoint.list]**:
`locationId` (repeatable), `capability`, `capabilitiesMode` (`and`|`or`), `deviceId`, `includeRestricted`,
`accessLevel`, `installedAppId`, `includeHealth` (`true`), `includeStatus` (`true`), `max`, `page`, `type`. Official
docs document `capability`, `includeStatus`, `includeHealth`.

Homeswift's list call: `GET devices?locationId=<locationId>&includeStatus=true&includeHealth=true`, all pages.

Device object (fields Homeswift reads; **[sdk: `Device` interface]**, examples **[official]**):

| Field | Use |
|---|---|
| `deviceId` | Device Id |
| `label` | Name (the person's name for it); fallback `name`, then "SmartThings device" |
| `name` | integration's name |
| `manufacturerName` | Manufacturer (fallback "SmartThings") — **never** used for Homeswift-copy detection of bridged children (12) |
| `presentationId`, `deviceManufacturerCode` | Diagnostics; Model fallback |
| `locationId`, `roomId` | location filter; room hint |
| `type` | `DeviceIntegrationType`: `BLE`, `BLE_D2D`, `DTH`, `ENDPOINT_APP`, `GROUP`, `HUB`, `IR`, `IR_OCF`, `LAN`, `MATTER`, `MOBILE`, `MQTT`, `OCF`, `PENGYOU`, `SHP`, `VIDEO`, `VIPER`, `VIRTUAL`, `WATCH`, `ZIGBEE`, `ZWAVE`, `EDGE_CHILD` |
| `components[]` | `{ id, label?, capabilities: [{ id, version, status? }], categories: [{ name, categoryType: "manufacturer"|"user" }] }` |
| `parentDeviceId`, `childDevices[] { id }` | Matter bridge detection (12) |
| `matter` | `{ driverId, hubId, provisioningState, networkId, executingLocally, uniqueId, vendorId (int), productId (int), listeningType, supportedNetworkInterfaces, version { hardware, hardwareLabel, software, softwareLabel }, endpoints [{ endpointId, deviceTypes [{ deviceTypeId }] }] }` |
| `edgeChild` | `{ driverId, hubId, provisioningState, networkId, executingLocally, parentAssignedChildKey }` |
| `ocf` | `{ ocfDeviceType, manufacturerName, modelNumber, firmwareVersion, vendorId, … }` (Samsung appliances, TVs) |
| `viper` | `{ uniqueIdentifier, manufacturerName, modelName, swVersion, hwVersion }` |
| `hub` | a hub; never an accessory (Excluded, nothing to map) |
| `allowed[]` | `w:devices`, `w:devices:locationId`, `w:devices:roomId`, `x:devices`, `d:devices`; when present and without `x:devices`, the person may not control it: expose read-only |
| `healthState` | with `includeHealth=true`: `{ "state": "ONLINE"|"OFFLINE"|"UNKNOWN", "lastUpdatedDate": "<ISO 8601>" }` |

With `includeStatus=true` each capability reference carries `status` = that capability's attribute map
(`{ "<attribute>": { "value": …, "unit"?: "…", "data"?: {…}, "timestamp": "<ISO 8601>" } }`)
**[sdk: `CapabilityReference.status`]**. This is how one call returns the whole location's state. **[unverified]**: that
the embedded status is as fresh as `GET devices/{id}/status`, and how this call counts against the per-device limit.

**Get**: `GET devices/{deviceId}` (same object; `includeStatus`, `includeHealth` accepted) **[sdk]**.

**Status**: `GET devices/{deviceId}/status` → `{ "components": { "<componentId>": { "<capability>": { "<attribute>":
{ "value": …, "unit"?: "…", "timestamp": "…" } } } }, "healthState"?: {…} }` **[official, sdk]**. `unit` appears only on
some attributes (e.g. `level` `%`, `colorTemperature` `K`, temperatures `C`/`F`) **[official]**.
Component: `GET devices/{deviceId}/components/{componentId}/status`. Capability:
`GET devices/{deviceId}/components/{componentId}/capabilities/{capabilityId}/status` **[sdk, official]**.

**Health**: `GET devices/{deviceId}/health` → `{ "deviceId", "state": "ONLINE"|"OFFLINE"|"UNKNOWN", "lastUpdatedDate" }`
**[sdk]**. aziz66 avoids it ("unreliable for Edge drivers") and decides offline by failed status calls **[aziz66]**.

**Commands**: `POST devices/{deviceId}/commands` with
`{ "commands": [ { "component": "main", "capability": "switch", "command": "on", "arguments": [] } ] }`
**[official: control-devices]**. The official field table calls the field `componentId` but every example uses
`component`; the SDK sends `component` **[sdk]**; aziz66 omits it for `main` **[aziz66]**. Homeswift always sends
`component`. `arguments`: an array (empty when none); numbers, strings or objects.
Response 200: `{ "results": [ { "id": "<uuid>", "status": "ACCEPTED" } ] }` (`ACCEPTED`, `COMPLETED`, `FAILED`
**[sdk: CommandStatus]**; "ACCEPTED means the command was queued" **[official]**). An accepted command is not yet
done: the state change arrives later as an event or in the next status.
Limits: at most **10 commands per request** (guardrail, 422 beyond) and 12 requests/minute per device for status,
commands and events **[official: rate-limits]**. Several commands for one device go in one request (e.g. AC `switch on`
+ `setAirConditionerMode`).

### 4.4 Scenes

- `GET scenes?locationId=<locationId>` (paged) → items `{ "sceneId", "sceneName", "sceneIcon", "sceneColor",
  "locationId", "createdBy", "createdDate", "lastUpdatedDate", "lastExecutedDate", "editable", "apiVersion" }`
  **[sdk: src/endpoint/scenes.ts]**. Scope `r:scenes:*`. 50 list requests/minute **[official]**.
- `POST scenes/{sceneId}/execute` (no body) → 200 with a status object (`{"status":"success"}`
  **[unverified]**). Scope `x:scenes:*`. 50 requests/minute per scene **[official]**.

### 4.5 Not used

Subscriptions by webhook (`installedapps/{id}/subscriptions`, needs a public HTTPS target; aziz66 uses them with
`server_url`), modes (`locations/{id}/modes`, scope `x:locations:*`), rules, device events, device profiles,
installed apps. aziz66 also calls `GET installedapps` to find its `installedAppId` for webhooks; Homeswift has it from
the token response.

---

## 5. Updates

### 5.1 SSE (when the granted `scope` contains `sse`) **[official: sse-subscriptions]**

Prerequisites: a Developer or Business plan (else 403), the `sse` scope plus the resource scope of each event type
(`DEVICE_EVENT`, `DEVICE_LIFECYCLE_EVENT`, `DEVICE_HEALTH_EVENT` → `r:devices:*`; `MODE_EVENT`,
`LOCATION_LIFECYCLE_EVENT` → `r:locations:*`; `SCENE_LIFECYCLE_EVENT` → `r:scenes:*`; `INSTALLED_APP_LIFECYCLE_EVENT`
→ `r:installedapps:*`). Use the same access token to create and to activate.

**Create**: `POST sse/subscriptions` (`https://api.smartthings.com/v1/sse/subscriptions`), headers `User-Agent`
(required, human-readable, e.g. `Homeswift/<version> (SmartThings plugin; https://homeswift.dev)`),
`Content-Type: application/json`, `Authorization: Bearer …`. Body:

| Field | Value |
|---|---|
| `name` | `homeswift-<instance>` |
| `subscriptionFilters[]` | `{ "type": "LOCATIONIDS" \| "DEVICEIDS", "value": [ids…] (LOCATIONIDS also accepts ["ALL"]), "eventType": [types…] }`; an empty `eventType` means all types; always list them |

Homeswift subscribes with one filter: `LOCATIONIDS` = [`locationId`], `eventType` =
[`DEVICE_EVENT`, `DEVICE_HEALTH_EVENT`, `DEVICE_LIFECYCLE_EVENT`, `SCENE_LIFECYCLE_EVENT`] (the last two only to
trigger a re-discovery). There is **no SECURITY_ARM_STATE event type** in SSE (section 10). Device-id filters are
limited to 10 ids each, so location filters are the only workable choice.

Response 200: `{ "subscriptionId", "registrationUrl", "version": 1, "name", "subscriptionFilters" }`. The subscription
is inactive and is deleted if not activated within **1 minute**.

**Activate**: `GET <registrationUrl>` with `User-Agent`, `Authorization: Bearer …` (same token),
`Accept: text/event-stream`. 200 and an open stream. Use `ServerSentEvents` from `HomeswiftNetwork`
(`HTTPStreaming.swift`).

**Update**: `PUT sse/subscriptions/{subscriptionId}` with `{ "subscriptionFilters": [...] }` (active subscriptions
only; 409 on an inactive one). **Delete**: `DELETE sse/subscriptions/{subscriptionId}` → `{}`; Homeswift deletes its
subscription on shutdown and before creating a new one when it still knows the old id.

**Stream format**: standard SSE; each message has an `event:` line and one `data:` line of JSON on a single line.
- `event: CONTROL_EVENT` / `data: welcome`: the first message; the server **resends it periodically as a keepalive**
  (interval not documented).
- `goodbye`: sent before an expected close (TTL expiry or DELETE); on it, create a new subscription. Its exact form is
  **not documented**: Homeswift treats as goodbye a `CONTROL_EVENT` whose data is `goodbye` (case-insensitive) and any
  message whose event name or data is `goodbye` **[unverified]**.
- Device event: `event: DEVICE_EVENT`, data `{ "eventTime": <epoch ms integer>, "eventType": "DEVICE_EVENT",
  "deviceEvent": { "eventId", "locationId", "deviceId", "componentId", "capability", "attribute", "value",
  "valueType", "stateChange", "subscriptionName" } }`. `valueType` seen as `"string"`; `value` is any JSON (string,
  number, boolean, object, array). **No `unit`** is listed: keep the last unit known for that attribute from a status
  read (temperatures, 7.4). `stateChange` is true when the value differs from the previous one.
- Other events: every payload has `eventTime`, `eventType` and a type-specific object; only `DEVICE_EVENT` is
  documented. **[unverified]** shapes, by analogy with webhook payloads: `deviceHealthEvent` `{ eventId, locationId,
  deviceId, hubId, status: "ONLINE"|"OFFLINE"|"UNHEALTHY"?, reason }`; `deviceLifecycleEvent` `{ lifecycle:
  "CREATE"|"DELETE"|"UPDATE"|"MOVE_FROM"|"MOVE_TO"|"ROOM_MOVE"…, deviceId, locationId }`. Parse defensively: on a
  health event, read `status`/`state` if present else re-read that device's health; on any lifecycle event, schedule a
  re-discovery (debounced 30 s).
- Unknown event names and data that is not JSON: ignore (log at debug).

**Lifecycle**: TTL server-assigned and variable; after expiry PUT/DELETE answer 403. No resume, no `Last-Event-ID`;
events during a gap are lost; delivery is normally at-least-once and ordered but not guaranteed; events near a create
or update may be missed or duplicated.

**Limits**: 10 filters per subscription, 10 ids per filter, **2 active subscriptions per integration**, **1 active
connection per token**, **20 SSE API calls per minute**.

**Homeswift loop** **[Homeswift]**:
1. Create → activate within the minute (if activation fails with 403/404, create again; count it).
2. On the first `welcome` of a connection: **reconcile** (5.2), then apply events as they come.
3. Watchdog: no message at all (event or welcome) for 5 minutes → treat as a gap: close, delete, go to 1.
   **[unverified]** keepalive period; make the watchdog a constant that tests shorten.
4. On goodbye, on stream end, on a network error: go to 1 after a backoff (6.2). After every reconnect: reconcile.
5. A refresh of the access token does not drop the stream; a 401/403 on create or activate → refresh once, then retry;
   a 403 that persists → SSE unavailable (no plan, scope not granted): fall back to polling (5.3) and say so in the log
   and on the plugin's status, retry SSE every 30 minutes.
6. Two subscriptions per integration: never leave an old one active (delete first when its id is known); if create
   answers 429 or a limit error, wait and back off; never loop faster than the 20 calls/min budget.

Applying a device event: find the accessory by `deviceId`, the service by `componentId` + `capability`, set the
attribute in the cached status, recompute the characteristics that depend on it, and push changes. Do **not** drop
events whose `stateChange` is false for `button` (a second press of the same value has `stateChange` false); for
other capabilities a false `stateChange` can be skipped. Unknown `deviceId` → ignore (or schedule a re-discovery if it
is in the location and not Excluded).

### 5.2 Reconciliation **[Homeswift]**

One `GET devices?locationId=…&includeStatus=true&includeHealth=true` (all pages) refreshes every device's status and
health. Done: at start, after every SSE (re)connect, after a 429 back-off ends, and on the polling schedule (5.3). A
device present in the cache and missing from the list is gone: Not Responding until the next discovery confirms, then
removed. A new device: re-discovery.

### 5.3 Polling (no `sse`, or SSE unavailable) **[Homeswift]**

Every period, one reconciliation call (5.2). No per-device polling.

Period = the smallest non-zero value among the `Poll*Seconds` keys present in the block, floored at **60 s**; when none
is present, **300 s**. With SSE active: a safety reconciliation every 30 minutes.

Budget: the Developer plan allows 100,000 calls a month (≈ 3,300/day, ≈ 2.3/min) **[official]**. At 60 s polling
that is 43,200 list calls a month (one page) before commands and refreshes; at 300 s, 8,640. Homeswift logs, at start
and when the period changes, the projected monthly calls (`pages × 86400/period × 30`) and warns above 60,000. Whether
token refreshes and SSE calls count toward the quota is **[unverified]**.

### 5.4 The aziz66 / ik `Poll*Seconds` keys

aziz66 runs one timer **per characteristic** per accessory (every lock, door, sensor, light…), each calling
`GET devices/{id}/status` (cached 5 s per device), with up to 1 s random jitter, skipping while a command is in flight
or within 20 s after one **[aziz66]**. ik does the same, and its garage door reads `PollSensorsSeconds` instead of
`PollDoorsSeconds` (bug) **[ik]**. With dozens of devices this is far above 12/min/device budgets and the monthly quota;
Homeswift keeps only the smallest value as the period (5.3). `0` everywhere means "no polling": Homeswift then polls
only at reconciliation points (start, reconnects) and every 30 minutes.

### 5.5 After a command **[Homeswift]**

Characteristic writes answer as soon as SmartThings returns 200 `ACCEPTED`. Set the expected value in the cache
optimistically. If SSE is active and no matching `DEVICE_EVENT` arrives within 10 s, read that device's status once
(`GET devices/{id}/status`). Without SSE, read that device's status once 3 s after the command. Do not let a
reconciliation older than the command overwrite the optimistic value (compare the attribute `timestamp` with the
command time; keep the newer).

---

## 6. Rate limits and error handling

### 6.1 Limits that matter **[official: rate-limits]**

| Scope | Limit |
|---|---|
| Per device: get status, send commands, create events | 12 requests/minute each |
| Commands per request | 10 (guardrail → 422) |
| Locations get/list | 100/min |
| Rooms | 50/hour |
| Scenes: execute | 50/min per scene; list 50/min |
| Installed apps / apps APIs | 60/min |
| SSE API | 20 calls/min; 2 active subscriptions per integration; 1 connection per token |
| Developer plan | 100,000 API calls/month; 10 active installs |

Headers on responses: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` ("Time in seconds until the
current window expires"). `Retry-After` is not documented (aziz66 reads it anyway).

### 6.2 Status codes **[Homeswift]**, informed by official docs and aziz66

| Code | Meaning | Action |
|---|---|---|
| 200 | ok | |
| 400 | bad request (bad command arguments) | surface on the write (HAP: invalid value), log body, no retry |
| 401 | token expired or revoked | refresh once (3.6), retry once; still 401 → account refused |
| 403 | scope missing, resource not allowed, no paid plan, SSE subscription expired | API call: log once per path with the body, Not Responding for that device if it is a device call; SSE: 5.1 step 5. Never loops. If `GET devices` itself answers 403, the account Needs Authorization with the message "SmartThings refused access: check your Developer plan and the app's scopes" |
| 404 | device or scene gone | re-discovery |
| 409 | SSE PUT on inactive subscription | recreate |
| 418 | SSE client flagged | stop SSE, poll, log an error; retry SSE after 1 h |
| 422 | guardrail (body `error.code` e.g. `ConstraintViolationError`, `details[]`) | split command batches > 10; else surface |
| 429 | rate limited | back off for `X-RateLimit-Reset` seconds (else `Retry-After`, else exponential 5 s · 2ⁿ up to 10 min, ±20 % jitter); during the back-off serve cached values and send no reads; a **write** is retried once only if the wait is ≤ 5 s, else it fails (HomeKit has given up long before; a late command could land after a newer one) **[aziz66 rule]** |
| 5xx, network errors | transient | reads: exponential backoff with jitter, max 3 tries per call; writes: one retry after 1 s |

### 6.3 Paid plan errors

After 2026-12-15, calls from an account without a plan may be "limited, paused, or discontinued" at the gateway
**[official: blog]**. The exact status code is **[unverified]** (expect 403 or 429). Homeswift: when every API call
fails with 403 for 10 minutes, the instance Needs Authorization with the plan message above, and the README's
troubleshooting names the plan first.

### 6.4 Offline devices **[Homeswift]**

A device is Not Responding (HAP status `SERVICE_COMMUNICATION_FAILURE` on reads and writes; widgets show it) when:
`healthState.state` is `OFFLINE` (from the list, a health event, or a `healthCheck.healthStatus` /
`DeviceWatch-DeviceStatus` attribute of `offline`), or its status calls have failed for 60 s or more (aziz66: 5
failures spanning ≥ 60 s). `UNKNOWN` health does not by itself mark a device offline. Any successful status or event
for it clears the state. aziz66 notes health is unreliable for some Edge drivers: when health says OFFLINE but a fresh
event arrives for the device, trust the event.

---

## 7. Capability → HomeKit mapping

### 7.1 Model **[Homeswift]**, following aziz66's structure

- One accessory per device (Accessory Id `HomeBridgeSmartThings:<deviceId>`), except TVs published on their own (9).
- Services come from each **component** separately (`main` first, then the others in the device's order). A component's
  capability ids are the input; a capability used by one service is consumed and not used again in that component.
- Service subtype (stable iids): `<componentId>/<role>`, where `<role>` is the service role named in the tables below
  (`light`, `switch`, `fan`, `thermostat`, `temperature`, …), plus a suffix where one component yields several of the
  same role (`main/switch.speed`, `main/switch.windFree`). Every service gets a subtype, `main` ones included. Never
  change a subtype once released.
- Primary service: the first service created for `main`. Others are linked to it.
- Service names: `main` → the device's Name; other components → `<Name> <component label or id>` (aziz66 names every
  component's service with the device label, which gives duplicates; fixed). Fridge compartments: 8.5.
- Accessory Information: Manufacturer `manufacturerName` (else "SmartThings"); Model the first present of
  `ocf.modelNumber`, `viper.modelName`, `deviceManufacturerCode`, else "SmartThings device"; Serial Number: the
  `deviceId` (SmartThings exposes no MAC for ordinary devices; CLAUDE.md's rule falls back to the id); Firmware
  Revision the first present of `ocf.firmwareVersion`, `viper.swVersion`, `matter.version.softwareLabel`.
  aziz66 writes "Default-Model" / "Default-Serial" **[aziz66]**.
- Parts / Functions: every service but Battery and Accessory Information is a Function; a multi-component device's
  per-component services can be Separate Functions.
- Read-only devices (`allowed` without `x:devices`): characteristics keep their write permission but writes fail with
  HAP `INSUFFICIENT_PRIVILEGES`.

### 7.2 Assignment order (per component)

Evaluate in this order; each rule that matches consumes the capabilities it lists (required + matched optional).
aziz66 sorts its combination list by required-capability count, descending, with an unstable comparator for ties
(order among equal sizes is engine-dependent) **[aziz66]**; Homeswift fixes the order below.

1. Device-level rules first (section 8 appliances, 9 TV, 10 security system); they consume what they use on the
   components they cover.
2. Combinations:

| # | Required | Optional (consumed when present) | Service(s) | § |
|---|---|---|---|---|
| C1 | `switch`, `airConditionerMode`, `airConditionerFanMode`, `thermostatCoolingSetpoint`, `temperatureMeasurement` | `fanOscillationMode`, `relativeHumidityMeasurement`, `custom.airConditionerOptionalMode` | Thermostat + Fanv2 (+ Humidity, optional-mode Switches) | 7.3.10 |
| C2 | `switch`, `airConditionerFanMode` | `custom.filterState`, `custom.hepaFilter`, `filterState`, `airQualitySensor`, `dustSensor`, `fineDustSensor`, `veryFineDustSensor`, `odorSensor` | AirPurifier (+ FilterMaintenance, AirQualitySensor) | 8.7 |
| C2b | `switch`, `airPurifierFanMode` | as C2 | AirPurifier | 8.7 (Homeswift addition) |
| C3 | `switch`, `fanSpeed`, `switchLevel` | | Fan (speed = level) | 7.3.3 |
| C4 | `switch`, `fanSpeedPercent` | `fanSpeed` | Fan (speed = percent) | 7.3.3 (Homeswift addition) |
| C5 | `switch`, `fanSpeed` | | Fan (3 steps) | 7.3.3 |
| C6 | `switch` + at least one of `switchLevel`, `colorControl`, `colorTemperature` | the other two | Lightbulb | 7.3.2 |
| C7 | `switch`, `valve` | | Valve | 7.3.9 |
| C8 | `temperatureMeasurement`, `thermostatMode`, `thermostatHeatingSetpoint`, `thermostatCoolingSetpoint` | `thermostatOperatingState`, `thermostatFanMode` (humidity stays a separate sensor) | Thermostat | 7.3.4 |
| C9 | `temperatureMeasurement`, `thermostatHeatingSetpoint` | `thermostatMode`, `thermostatOperatingState` | Thermostat (heat only) | 7.3.4 |
| C10 | `temperatureMeasurement`, `thermostatMode`, `temperatureSetpoint` | `switch`, `thermostatOperatingState` | Thermostat (single setpoint) | 7.3.4 |
| C11 | `windowShade`, `windowShadeLevel` | `windowShadePreset` | WindowCovering | 7.3.6 |
| C12 | `windowShade`, `switchLevel` | `windowShadePreset` | WindowCovering | 7.3.6 |

3. Single capabilities, in this order (`battery` and the sensors last so a primary service claims first):
   `doorControl` → GarageDoorOpener; `lock` → LockMechanism; `switch` → Switch or Outlet; `windowShadeLevel` →
   WindowCovering; `windowShade` → WindowCovering; `valve` → Valve; `motionSensor` → MotionSensor; `waterSensor` →
   LeakSensor; `smokeDetector` → SmokeSensor; `carbonMonoxideDetector` → CarbonMonoxideSensor; `presenceSensor` →
   OccupancySensor; `occupancySensor` → OccupancySensor (Homeswift addition); `temperatureMeasurement` →
   TemperatureSensor; `relativeHumidityMeasurement` → HumiditySensor; `illuminanceMeasurement` → LightSensor;
   `contactSensor` → ContactSensor; `button` → StatelessProgrammableSwitch; `samsungce.airConditionerLighting` →
   Lightbulb (only with `ExposeACDisplayLight` / `displayLight`); Zigbang (`ExposeZigbangSmartDoorlock`);
   `battery` → Battery.
4. Energy (`powerMeter`, `energyMeter`, `powerConsumptionReport`, `voltageMeasurement`) after everything else
   (7.3.14).

A device with **no** service after all components: section 7.6.

### 7.3 Services

Notation: `cap.attr` is `components.<c>.<cap>.<attr>.value`. Writes are `POST devices/{id}/commands` with
`component` = the service's component. HAP enum numbers are HAP-NodeJS's.

#### 7.3.1 Switch / Outlet (`switch`)
- On ↔ `switch.switch` (`on` → true, `off` → false). Write: `switch.on` / `switch.off`, no arguments.
- Outlet instead of Switch when `outlet`/`ExposeEnergyAsOutlet` is true **and** the component has a metering capability
  (`powerMeter`, `energyMeter`, `powerConsumptionReport`), `main` only, not a TV or AC **[aziz66 rule]**. Outlet adds
  OutletInUse = (power > 0.5 W when known, else On) **[Homeswift]**.
- A component whose only capability is `switch` on a device whose main category is `Light` → Lightbulb (On only)
  **[Homeswift; category name `Light` from the official list example]**.

#### 7.3.2 Lightbulb (`switch` + `switchLevel` / `colorControl` / `colorTemperature`)
- On ↔ `switch.switch`. Write `switch.on`/`off`.
- Brightness (0–100, step 1) ↔ `switchLevel.level` (integer 0–100, unit `%`), clamped. Write
  `switchLevel.setLevel [level]` (the second argument `rate` is optional; omit). `setLevel` with a level > 0 turns the
  light on, 0 turns it off **[official]**: a Brightness write of 0 sends `switch.off` instead **[Homeswift]**.
- Hue (0–360) ↔ `colorControl.hue` (0–100 %): HomeKit = round(st × 3.6); SmartThings = round(hk ÷ 3.6) (aziz66 rounds
  hk/360×100, same result). Saturation (0–100) ↔ `colorControl.saturation` (0–100 %), unchanged.
- Colour writes: HomeKit sends Hue and Saturation together; collect both for 100 ms and send one
  `colorControl.setColor [{ "hue": h, "saturation": s }]` (object argument) **[official example]**, the missing one taken
  from the cache. aziz66 sends `setHue [h]` / `setSaturation [s]` and falls back to `setColor` for the rest of the
  session after one failure **[aziz66]**.
- ColorTemperature (mireds) ↔ `colorTemperature.colorTemperature` (integer kelvin 1–30000): mireds = round(1,000,000 ÷
  K), clamped to the characteristic's range; write `colorTemperature.setColorTemperature [round(1,000,000 ÷ mireds)]`
  clamped to `colorTemperatureRange.value.minimum`/`maximum` when present **[aziz66 reads that shape;
  unverified]**. Props: from `colorTemperatureRange` when present (min mireds = round(1e6 ÷ maxK), max = round(1e6 ÷
  minK)), else HAP 140–500.
- Characteristics present only for the capabilities the component has. A colour-temperature light gets an
  `AdaptiveLightingController` (CLAUDE.md).
- Events: `switch.switch`, `switchLevel.level`, `colorControl.hue`/`saturation`, `colorTemperature.colorTemperature`
  (ignore `colorTemperatureRange` and `levelRange` events except to update props).

#### 7.3.3 Fan
- C3: Fan (v1, as aziz66) — On ↔ `switch`; RotationSpeed (0–100) ↔ `switchLevel.level`; write `setLevel`.
  Homeswift may use Fanv2 (Active instead of On) for new accessories; choose one and keep it **[Homeswift: Fanv2]**.
- C4: RotationSpeed ↔ `fanSpeedPercent.percent` (0–100); write `fanSpeedPercent.setPercent [p]`.
- C5: RotationSpeed from `fanSpeed.fanSpeed` (integer ≥ 0): 0 → 0, 1 → 33, 2 → 66, ≥ 3 → 100; write
  `fanSpeed.setFanSpeed [n]` with 0 → 0, ≤ 33 → 1, ≤ 66 → 2, else 3 **[aziz66]**. Props keep step 1; the value
  snaps on write. Devices with 4 or 5 speeds are squeezed into 3 **[known limitation; fanSpeed has no max attribute]**.
- On/Active writes → `switch.on`/`off`.

#### 7.3.4 Thermostat (C8, C9, C10)
- CurrentTemperature ↔ `temperatureMeasurement.temperature` converted to °C (7.4). Props −50…100, step 0.1.
- TargetTemperature: C10 → `temperatureSetpoint.temperatureSetpoint`; C8/C9 → the cooling setpoint when the current
  target mode is COOL, else the heating setpoint. Write (°C → device unit, 7.4): `temperatureSetpoint.
  setTemperatureSetpoint [t]`, `thermostatCoolingSetpoint.setCoolingSetpoint [t]` or `thermostatHeatingSetpoint.
  setHeatingSetpoint [t]` accordingly. Props: min/max from `heatingSetpointRange` / `coolingSetpointRange` /
  `temperatureSetpointRange` when present (`value.minimum`, `value.maximum`, `value.step`, converted) **[unverified
  shape]**, else min 5 (aziz66 lowers HAP's 10 to 5 for frost protection), max 35, step 0.5.
- **[Homeswift addition]** C8 with both setpoints: HeatingThresholdTemperature ↔ heating setpoint and
  CoolingThresholdTemperature ↔ cooling setpoint, used by HomeKit in AUTO.
- TargetHeatingCoolingState ↔ `thermostatMode.thermostatMode`: `off` → 0; `heat`, `emergency heat`,
  `emergencyheat`, and any other mode → 1 (aziz66 maps unknown modes such as `radiatingfloor` to HEAT); `cool` → 2;
  `auto` → 3. Without `thermostatMode`: AUTO fixed (aziz66) — Homeswift: HEAT fixed for C9 without mode (a heater),
  validValues [1].
  validValues: the HomeKit values whose SmartThings mode is in `thermostatMode.supportedThermostatModes` (always keep
  the current one); when that attribute is absent, [0, 1, 2, 3] (C8) or [0, 1] (C9 with mode).
  Write: 0 → `off`; 1 → `heatMode` setting (default `heat`); 2 → `coolMode` (default `cool`); 3 → `auto`; sent as
  `thermostatMode.setThermostatMode [mode]`. With `switch` on the component (C10, e.g. Koolnova): send `switch.off`
  for OFF, else `switch.on` followed by `setThermostatMode` in the same request; while `switch` is `off` the target and
  current states read OFF (these devices keep the last mode while off) **[aziz66]**.
- CurrentHeatingCoolingState: from `thermostatOperatingState.thermostatOperatingState` when present: `heating` → 1,
  `cooling` → 2, `idle`, `pending heat`, `pending cool` → 0; `fan only`, `vent economizer`, unknown → fall through to
  the mode. From the mode: `cool` → 2, `off`/`idle` → 0, else 1 **[aziz66]**.
- TemperatureDisplayUnits: 1 (F) when the temperature unit is `F`, else 0; writes accepted and ignored.
- aziz66 bugs not to copy: CurrentTemperature read failures answer 0 °C; a TargetTemperature write after a
  HEAT→COOL change in the same second goes to the wrong setpoint (it uses the cached target mode).

#### 7.3.5 GarageDoorOpener (`doorControl`) — a security control (`isSecurityControl`)
- CurrentDoorState ↔ `doorControl.door`: `open` → 0, `closed` → 1, `opening` → 2, `closing` → 3, `unknown` and others →
  4 (STOPPED).
- TargetDoorState: `open`/`opening` → 0, `closed`/`closing` → 1; unknown keeps the last target. Write 0 →
  `doorControl.open`, 1 → `doorControl.close`. For 20 s after a write the target stays as written (aziz66 ignores
  status for the target during the transition).
- ObstructionDetected false. In Homeswift written only through `set_security_accessory` (MCP rule).

#### 7.3.6 WindowCovering (C11, C12, `windowShadeLevel` or `windowShade` alone)
- CurrentPosition ↔ `windowShadeLevel.shadeLevel` (C11, or alone) or `switchLevel.level` (C12); 0 = closed, 100 = open
  **[official]**. With `windowShade` only: `open` → 100, `closed` → 0, `partially open` → 50, others keep the last.
- PositionState ↔ `windowShade.windowShade`: `opening` → 1 (INCREASING), `closing` → 0 (DECREASING), anything else →
  2 (STOPPED). When stopped, TargetPosition is synced to CurrentPosition.
- TargetPosition write: 0 with `windowShade` → `windowShade.close`; 100 with `windowShade` → `windowShade.open`;
  otherwise `windowShadeLevel.setShadeLevel [p]` (C11/alone) or `switchLevel.setLevel [p]` (C12). With `windowShade`
  only, values 1–99 round to 0 or 100.
- HoldPosition (Homeswift addition): when `windowShade.supportedWindowShadeCommands` contains `pause` →
  `windowShade.pause`.
- `windowShadeTiltLevel` (`shadeTiltLevel` 0–100, `setShadeTiltLevel [level]`) → Current/TargetHorizontalTiltAngle:
  angle = round(level × 1.8 − 90) **[Homeswift addition; unverified orientation]**.

#### 7.3.7 LockMechanism (`lock`) — a security control
- LockCurrentState ↔ `lock.lock`: `locked` → 1 (SECURED); `unlocked`, `unlocked with timeout`, `unlatched` → 0;
  `not fully locked` → 2 (JAMMED); `unknown`/other → 3.
- LockTargetState: `locked` → 1; `unlocked`, `unlocked with timeout`, `unlatched` → 0; others keep. Write 1 →
  `lock.lock`, 0 → `lock.unlock`. Target held 10 s after a write (aziz66).
- Written only through `set_security_accessory`.
- Lock values are from the official reference (which adds `unlatched` and `unknown` to aziz66's list).

#### 7.3.8 Sensors

| Capability.attribute | Service.characteristic | Mapping |
|---|---|---|
| `motionSensor.motion` | MotionSensor.MotionDetected | `active` → true |
| `contactSensor.contact` | ContactSensor.ContactSensorState | `closed` → 0 (detected), `open` → 1 |
| `presenceSensor.presence` | OccupancySensor.OccupancyDetected | `present` → 1, `not present` → 0 |
| `occupancySensor.occupancy` | OccupancySensor.OccupancyDetected | `occupied` → 1 |
| `waterSensor.water` | LeakSensor.LeakDetected | `wet` → 1 |
| `smokeDetector.smoke` | SmokeSensor.SmokeDetected | `detected` → 1; `clear`, `tested` → 0 (`tested` logged) |
| `carbonMonoxideDetector.carbonMonoxide` | CarbonMonoxideSensor.CarbonMonoxideDetected | `detected` → 1; `clear`, `tested` → 0 |
| `temperatureMeasurement.temperature` | TemperatureSensor.CurrentTemperature | °C (7.4); props −100…200 |
| `relativeHumidityMeasurement.humidity` | HumiditySensor.CurrentRelativeHumidity | 0–100 |
| `illuminanceMeasurement.illuminance` | LightSensor.CurrentAmbientLightLevel | lux; values ≤ 0 → 0.0001 (HAP minimum) |

A null or missing value: keep the last value; aziz66 removes a sensor service after more than 5 bad reads in a row
**[aziz66]** — Homeswift instead removes a sensor service only when its attribute has never had a value since the
device was discovered (a declared-but-unreported capability) **[Homeswift]**.

#### 7.3.9 Valve (C7 or `valve` alone)
- Active and InUse ↔ `valve.valve` (`open` → 1). Write Active 1 → `valve.open`, 0 → `valve.close`.
- ValveType: 0 (GENERIC) **[Homeswift]**; aziz66 says 1 (IRRIGATION).
- IsConfigured 1.

#### 7.3.10 Air conditioner (C1) **[aziz66 structure]**
Services on the same accessory: Thermostat (`main/thermostat`), Fanv2 (`main/fan`), and optionally HumiditySensor,
optional-mode Switches, display-light Lightbulb.
- Temperature unit: from `temperatureMeasurement.temperature.unit` (else `C`).
- Thermostat:
  - CurrentTemperature ↔ temperature (°C).
  - TargetTemperature ↔ `thermostatCoolingSetpoint.coolingSetpoint` (Samsung ACs use this single setpoint in every
    mode). Props: from `coolingSetpointRange` when present, else 16–30 °C, step 1 **[aziz66]**. Write
    `thermostatCoolingSetpoint.setCoolingSetpoint [t]` (F: rounded whole degrees).
  - TargetHeatingCoolingState: `switch` `off` → 0; else by `airConditionerMode.airConditionerMode`: `cool`, `dry` → 2;
    `heat` → 1; `auto` (and `aIComfort`? **[unverified Samsung mode names]**) → 3; `wind`/`fan`/others → 0.
    validValues restricted to the HomeKit values whose mode appears in `supportedAcModes` (prefer
    `availableAcModes` when present).
  - Write: 0 → `switch.off`; 1/2/3 → `switch.on` + `airConditionerMode.setAirConditionerMode [heat|cool|auto]` in one
    request.
  - CurrentHeatingCoolingState: off → 0; `cool` → 2; `heat` → 1; `auto` → 2 if temperature > setpoint else 1; others → 0.
- Fanv2:
  - Active ↔ `switch.switch`. Write 1 → `switch.on` + `setAirConditionerMode [current HomeKit mode, or "wind" when the
    thermostat target is OFF]` **[aziz66]**; write 0 → `switch.off`, except when the fan mode is auto or within 1.5 s
    after RotationSpeed 0 was written (HomeKit sends Active 0 together with speed 0; aziz66 ignores that off)
    **[aziz66]**.
  - RotationSpeed ↔ `airConditionerFanMode.fanMode` (string). Mode list = `availableAcFanModes` if a non-empty array,
    else `supportedAcFanModes`, else `auto, low, medium, high, turbo`. "Auto" = the mode `auto` if listed. Manual modes
    = the others, sorted by rank (sleep 1, quiet 2, low 3, `1` 4, medium 5, mid 6, `2` 7, high 8, `3` 9, turbo 10, `4`
    11, max 12; unknown 99, ties keep device order). Read: auto → 0; manual index i of n → floor((i+1)/n × 100); with
    the default list: auto 0, low 25, medium 50, high 75, turbo 100. Write level L: L ≤ 0 → auto (else the lowest
    manual); else manual[min(n−1, ceil(L/100 × n) − 1)]; send `airConditionerFanMode.setFanMode [mode]` **[aziz66]**.
  - SwingMode (with `fanOscillationMode`) ↔ `fanOscillationMode.fanOscillationMode`: values starting with `fixed` (and
    `off`) → 0, others → 1. Write 1 → `setFanOscillationMode ["all"]`, 0 → `["fixed"]`. Prefer a value present in
    `availableFanOscillationModes` (e.g. `vertical` when `all` is absent) **[Homeswift]**.
- HumiditySensor (when `exposeHumidity` / `ExposeHumiditySensorForAirConditioners`) ↔
  `relativeHumidityMeasurement.humidity`. Without it, humidity is consumed and not shown (aziz66 behaviour).
- Optional modes (`custom.airConditionerOptionalMode.acOptionalMode`, `setAcOptionalMode [mode]`)
  **[aziz66; Samsung custom capability, unverified]**: `OptionalModeForAirConditioners` / `optionalMode` = `Sleep`,
  `Speed`, `WindFree`, `WindFreeSleep` → one Switch "<Name> <Mode>" (subtype `main/switch.<mode, lowercase>`), On ↔
  `acOptionalMode == <value>` with values `sleep`, `speed`, `windFree`, `windFreeSleep`; write On → that value, Off →
  `off`. `Speed and Windfree` → two Switches (Speed, WindFree). `None` → none.
- Display light (`samsungce.airConditionerLighting.lighting`, `on`/`off`; commands `on`/`off` without arguments
  **[aziz66; unverified]**) → Lightbulb "<Name> Display Light", when `displayLight`/`ExposeACDisplayLight`.
- aziz66 bug: a Lightbulb for `switchLevel` on ACs is coded but can never be created (the capability is never passed
  to the AC service). Not reproduced.

#### 7.3.11 StatelessProgrammableSwitch (`button`)
- ProgrammableSwitchEvent from `button.button` events: `pushed`, `down` → 0 (single) (`up` alone is a release:
  ignore); `double`, `pushed_2x`…`pushed_6x`, `down_2x`…`down_6x`, `up_2x`… → 1 (double; HomeKit has no triple);
  `held`, `down_hold`, `up_hold` → 2 (long); `swipe_*` → ignore. aziz66 maps `pushed`/`down` → single, `double` →
  double, `held` → long, any `*_hold` → long, `(pushed|down)_<n>x` → double **[aziz66]**.
- validValues from `button.supportedButtonValues` mapped with the table (always include 0).
- Multi-button devices: components `button1`…`buttonN` each with `button` → one service per component with
  ServiceLabelIndex = N and a ServiceLabel service on the accessory **[Homeswift]**; the `main` component's `button`,
  when the device has button components too, is ignored (it repeats the last press) **[unverified]**.
- Events only: presses come through SSE. Without SSE, aziz66 compares `button.button.timestamp` between polls and
  emits once when it changes (first poll is a baseline) **[aziz66]**; Homeswift does the same at each reconciliation
  (a press between two polls of the same value is lost; README says buttons need SSE).

#### 7.3.12 Battery (`battery`)
- BatteryLevel ↔ `battery.battery` (0–100). StatusLowBattery = 1 when ≤ 20 **[Homeswift]** (aziz66: ≤ 30).
  ChargingState 2 (not chargeable).

#### 7.3.13 Zigbang smart door lock (`ExposeZigbangSmartDoorlock`) **[aziz66]**
Custom namespace `absoluteweather46907`: state capability `absoluteweather46907.lockstaterelease` (attribute `lock`,
values like `locked.<lang>` / `unlocked.<lang>`, compare the part before the first `.`); language from
`absoluteweather46907.languageSupport.language`; command capability `absoluteweather46907.lock`, command `unlock` (no
lock command: a LockTargetState write of 1 is refused). LockMechanism, security control.

#### 7.3.14 Energy
`powerMeter.power` (W), `energyMeter.energy` (unit `kWh` default, `Wh` → ÷1000, `mWh` → ÷1,000,000),
`powerConsumptionReport.powerConsumption.value` (object; aziz66 reads `power` (W) and `energy` (Wh) from it),
`voltageMeasurement.voltage` (V) **[official names; aziz66 conversions]**.
- **[Homeswift]** a component with metering is a Homeswift Meter (`context.meter`, Energy Role suggested `none`)
  reading power and total energy, on the device's Switch/Outlet/Lightbulb.
- With `ExposeEnergyMonitoring`: Eve characteristics on that host service (Current Consumption W, Total Consumption
  kWh, Voltage V), `main` only, not TVs or ACs **[aziz66 rule]**.
- Energy never creates a service on its own.

### 7.4 Conversions summary

| Quantity | SmartThings | HomeKit | Rule |
|---|---|---|---|
| Temperature | number + `unit` `C`/`F` on the attribute | °C | F → (F − 32) × 5/9, unrounded; writes C → F = round(C × 9/5 + 32) (whole degrees; aziz66) or C unchanged; unit taken from the attribute's own `unit`, else the last seen, else the location's `temperatureScale`, else `C` |
| Level | 0–100 integer | Brightness / RotationSpeed / position 0–100 | clamp, round |
| Hue | 0–100 % | 0–360° | ×3.6 / ÷3.6, rounded |
| Saturation | 0–100 % | 0–100 % | same |
| Colour temperature | kelvin 1–30000 | mireds | 1,000,000 ÷ x, rounded, clamped |
| Illuminance | lux 0–100000 | lux ≥ 0.0001 | floor at 0.0001 |
| Battery | 0–100 | 0–100 | same |
| Booleans as strings | `remoteControlEnabled` `"true"`/`"false"` | | accept string or JSON boolean |

### 7.5 Multi-component devices

Each component is mapped on its own (7.2), on the same accessory, subtypes by component (7.1). Typical: power strips
(`main` + `outlet1`…`outletN`, each `switch`) → one Switch per component; multi-gang wall switches (`switch1`…);
multi-button remotes (7.3.11); fridges (8.5). A component that SmartThings reports in
`custom.disabledComponents.disabledComponents` (on `main`) gets no services (aziz66 does this for fridges only;
Homeswift for any device) **[aziz66, Samsung custom capability]**.

### 7.6 Nothing to map **[Homeswift]**

A device with no service after 7.2 (a hub, a bridge device, a device of capabilities this port does not know) is still
a **Discovered Device** (Device Kind `unsupported`), **Excluded by default** (`excludedBySettings: true`), never an
accessory while Excluded. Its capability list (per component, ids and versions) and `type` appear in Diagnostics, so a
person can ask for support. aziz66 drops such devices silently **[aziz66]**.

### 7.7 Device Kinds (for `DiscoveredDevice.kind`)

`light`, `switch`, `outlet`, `fan`, `thermostat`, `airConditioner`, `airPurifier`, `lock`, `garageDoor`,
`windowCovering`, `valve`, `sensor`, `button`, `securitySystem`, `television`, `washer`, `dryer`, `dishwasher`,
`oven`, `refrigerator`, `robotVacuum`, `scene`, `unsupported` — the kind of the primary service.

---

## 8. Samsung appliances

### 8.1 Detection

By capabilities on `main` (official standard capabilities first, Samsung `samsungce.*`/`custom.*` second):

| Kind | Rule |
|---|---|
| washer | `washerOperatingState` (or `samsungce.washerOperatingState`) |
| dryer | `dryerOperatingState` (or `samsungce.dryerOperatingState`) |
| dishwasher | `dishwasherOperatingState` (or `samsungce.dishwasherOperation` **[unverified name]**) |
| oven / range | `ovenOperatingState` (or `samsungce.ovenOperatingState`) |
| refrigerator | `refrigerationSetpoint` on any component, or a component id among `cooler`, `freezer`, `cvroom`, `onedoor`, `flexzone` with `temperatureMeasurement`, or `samsungce.driverState` with `custom.disabledComponents` **[aziz66 hints]** |
| robot vacuum | `robotCleanerOperatingState`, `samsungce.robotCleanerOperatingState`, or `robotCleanerMovement` |
| air purifier | C2/C2b (7.2) |
| air conditioner | C1 (7.2) |

The device's main component category (`Washer`, `Dryer`, `Dishwasher`, `Oven`, `Refrigerator`, `RobotCleaner`,
`AirPurifier`, `AirConditioner`, `Television`) may confirm a kind **[unverified category names]**; capabilities decide.

### 8.2 Washer, dryer, dishwasher

Standard capabilities **[official]**:
- `washerOperatingState`: `machineState` (`pause`, `run`, `stop`), `supportedMachineStates`, `washerJobState`
  (`airWash`, `aIRinse`, `aISpin`, `aIWash`, `cooling`, `delayWash`, `drying`, `finish`, `none`, `preWash`, `rinse`,
  `spin`, `wash`, `weightSensing`, `wrinklePrevent`, `freezeProtection`), `completionTime` (ISO 8601); command
  `setMachineState (state)` with `pause` | `run` | `stop`.
- `dryerOperatingState`: same plus `dryerJobState` (`cooling`, `delayWash`, `drying`, `finished`, `none`,
  `refreshing`, `weightSensing`, `wrinklePrevent`, `dehumidifying`, `aIDrying`, `sanitizing`, `internalCare`,
  `freezeProtection`, `continuousDehumidifying`, `thawingFrozenInside`).
- `dishwasherOperatingState`: `machineState`, `dishwasherJobState` (`airwash`, `cooling`, `drying`, `finish`,
  `preDrain`, `prewash`, `rinse`, `spin`, `unknown`, `wash`, `wrinklePrevent`), `progress` (0–100), `completionTime`.
- `washerMode.washerMode` (`regular`, `heavy`, `rinse`, `spinDry`), `dryerMode`, `dishwasherMode` (attributes named as
  the capability; values not listed here).
- `remoteControlStatus.remoteControlEnabled`: `true` (allowed) | `false` (not allowed), an enum of strings.

Samsung additions seen in the field **[aziz66, unverified]**: `samsungce.washerOperatingState.remainingTime` (minutes;
aziz66 uses it when `completionTime` is missing), likewise for dryers; Samsung washers also carry `switch` (power).

HomeKit **[Homeswift requirement]**:
- **Switch "Power"** (`main/switch`) ↔ `switch.switch` when the appliance has `switch`, unless
  `removeLegacySwitchForLaundry` is true. Write `switch.on`/`off`.
- **Start**: when the appliance has no `switch` but its operating state's `supportedMachineStates` includes `run` and it
  has `remoteControlStatus`, the Switch is "Start" (`main/switch.start`): On ↔ `machineState == run`; write On →
  `<kind>OperatingState.setMachineState ["run"]`, Off → `setMachineState ["pause"]` (pause, not stop: stop cancels the
  cycle). A write while `remoteControlEnabled` is not `true` fails with HAP `NOT_ALLOWED_IN_CURRENT_STATE` and logs
  "Remote control is off on <name>: turn on Smart Control on the appliance" **[Homeswift; whether SmartThings itself
  refuses the command when remote control is off is unverified]**. With both `switch` and remote start, only the
  Power switch is shown and Start is offered on the web page (8.9).
- **OccupancySensor "Running"** (`main/occupancy.running`, name "<Name> Running"): occupied while `machineState ==
  run` and the job state is not `finish`/`finished`/`none`/`delayWash` (a stale job state at the end of a cycle does
  not count). This replaces aziz66's optional "Activity" Contact Sensor, and lets Apple Home notify on start/finish.
- aziz66 exposes a Valve (GENERIC) with Active ↔ run/pause, InUse ↔ job in an "in use" list, and SetDuration/
  RemainingDuration seeded once per cycle from `completionTime` (Apple Home counts down itself; re-pushing resets the
  countdown); max 14400 s **[aziz66]**. Homeswift does not expose the Valve.
- Web UI / MCP only (8.9): `machineState`, job state, `completionTime` and remaining minutes (completionTime − now,
  floored at 0; else `samsungce.*.remainingTime`), `progress` (dishwasher), mode (`washerMode` etc.),
  `remoteControlEnabled`, Samsung cycle and course names when present (`samsungce.washerCycle`, `samsungce.dryerCycle`,
  `samsungce.dishwasherWashingCourse` **[unverified names]**).

### 8.3 Oven / range

Standard **[official]**: `ovenOperatingState` (`machineState` `ready`|`running`|`paused`, `ovenJobState` (cleaning,
cooking, cooling, draining, preheat, ready, rinsing, finished, scheduledStart, warming, defrosting, sensing, searing,
fastPreheat, scheduledEnd, stoneHeating, timeHoldPreheat), `completionTime`, `operationTime`, `progress`;
commands `setMachineState (state)`, `start (mode, time, setpoint)`, `stop`), `ovenMode.ovenMode` (heating, grill,
warming, defrosting, Conventional, Bake, BottomHeat, ConvectionBake, …; `setOvenMode`), `ovenSetpoint.ovenSetpoint`
(`setOvenSetpoint`), `temperatureMeasurement` (the cavity temperature).

HomeKit: **TemperatureSensor** "<Name> Oven" ↔ `temperatureMeasurement` on the oven's component(s) (a range with two
cavities has a component each **[unverified component ids]**); **OccupancySensor "Running"** ↔ `machineState ==
running`. No remote start from HomeKit (heat is a safety matter) **[Homeswift]**. Cooktop burners: nothing.
Web/MCP: mode, setpoint, job state, completion/remaining, progress, operation time.

### 8.4 Robot vacuum → 8.6

### 8.5 Refrigerator

Components seen on Samsung fridges: `main`, `cooler`, `freezer`, `cvroom`, `onedoor`, `flexzone`, `icemaker`, …
**[aziz66; unverified list]**. Standard capabilities on them: `temperatureMeasurement`, `contactSensor`,
`refrigerationSetpoint` (`setRefrigerationSetpoint`), `thermostatCoolingSetpoint`, `rapidCooling`.

HomeKit **[Homeswift requirement]**:
- **TemperatureSensor per compartment** that has `temperatureMeasurement` and is not disabled: names "<Name> Fridge"
  (`main`, `cooler`), "<Name> Freezer" (`freezer`), "<Name> FlexZone" (`cvroom`, `onedoor`, `flexzone`), else
  "<Name> <component id>" **[aziz66 names]**. When `main` and `cooler` both have it, keep only `cooler`'s
  (aziz66 strips the cooler's as a duplicate of main; same outcome either way, one Fridge sensor).
- **ContactSensor "<Name> Door"** ↔ `contactSensor.contact` on `main` (one per other component with its own
  `contactSensor`, named after the compartment) **[unverified which components report doors]**.
- Disabled compartments (`custom.disabledComponents.disabledComponents.value`, an array of component ids on `main`;
  some status payloads nest it under `custom` → `disabledComponents` → `disabledComponents`) get nothing **[aziz66]**.
- `ExposeMultiZoneRefrigerator` true: when a compartment's `temperatureMeasurement` is null, read Samsung's OCF
  `samsungce.driverState.driverState.value` (on `main`): an array of `{ href, rep }` items, or an object whose
  `device/0` key (else the first array value) is that array. Paths per component: `main`, `cooler` →
  `/temperature/current/cooler/0` then `/temperatures/vs/0`; `freezer` → `/temperature/current/freezer/0` then
  `/temperatures/vs/0`; `cvroom`, `onedoor`, `flexzone` → `/temperature/current/cooler/0`. Take `rep.temperature`
  (number) if present; else in `rep["x.com.samsung.da.items"]` the item whose `x.com.samsung.da.id` is `1` (fridge) or
  `0` (freezer), or whose `x.com.samsung.da.description` is `Fridge`/`Freezer`, and parse its
  `x.com.samsung.da.current`. These OCF values are Fahrenheit on US firmware; metric firmware may report Celsius
  **[aziz66 says so; unverified]** — Homeswift: if the value is below 15 treat as °C, else °F (fridges sit near
  37 °F / 3 °C, freezers near 0 °F / −18 °C, so the threshold separates them) **[Homeswift heuristic]**.
- Web/MCP: setpoints, rapid cooling/freezing, ice maker state when present.

### 8.6 Robot vacuum

Standard **[official]**: `robotCleanerOperatingState.operatingState` (stopped, running, paused, seekingCharger,
charging, docked, unableToStartOrResume, unableToCompleteOperation, commandInvalidInState, failedToFindChargingDock,
stuck, dustBinMissing, dustBinFull, waterTankEmpty, waterTankMissing, waterTankLidOpen, mopCleaningPadMissing),
`supportedOperatingStateCommands` / `supportedCommands` (`start`, `pause`, `goHome`), commands `start`, `pause`,
`goHome`; `robotCleanerMovement.robotCleanerMovement` (homing, idle, charging, alarm, powerOff, reserve, point, after,
cleaning, pause, washingMop; `setRobotCleanerMovement (mode)`), `robotCleanerCleaningMode`, `robotCleanerTurboMode`.

HomeKit:
- **Switch** "<Name>" (unless `ExposeRobotVacuum` is `false`): On ↔ cleaning: `operatingState == running` when the
  standard capability is present, else `robotCleanerMovement` in {cleaning, point} (`seekingCharger`/`homing` is going
  home, so Off; aziz66 counts `homing` and an undocumented `moving` as On).
  Write On → `robotCleanerOperatingState.start` when listed in supported commands, else
  `samsungce.robotCleanerOperatingState.start` **[aziz66]**, else `robotCleanerMovement.setRobotCleanerMovement
  ["cleaning"]` **[unverified]**; Off → `robotCleanerOperatingState.goHome`, else `samsungce.robotCleanerOperatingState.
  returnToHome` **[aziz66]**, else `setRobotCleanerMovement ["homing"]`.
- **OccupancySensor "Running"** ↔ same On rule.
- Battery from `battery`.
- Web/MCP: operating state (including the error states), movement, cleaning mode, turbo mode.
- aziz66 requires `samsungce.robotCleanerOperatingState` **and** `switch` for its vacuum service **[aziz66]**;
  Homeswift accepts the standard capability alone.

### 8.7 Air purifier (C2, C2b) **[aziz66, with C2b added]**

- AirPurifier: Active ↔ `switch.switch` (write `switch.on`/`off`; skip a redundant `on` when the characteristic is
  already 1 — Samsung purifiers beep on every command **[aziz66]**). CurrentAirPurifierState: on → 2 (purifying),
  off → 0. TargetAirPurifierState: 1 (auto) when the fan mode is the auto mode, else 0.
- Fan modes: from `airConditionerFanMode` (`supportedAcFanModes`, `availableAcFanModes`, `fanMode`, `setFanMode`) for
  C2, or `airPurifierFanMode` (`supportedAirPurifierFanModes`, `airPurifierFanMode`, `setAirPurifierFanMode`
  **[unverified command name]**) for C2b. Default list `auto, low, medium, high`. Auto mode = `auto` if listed, else
  `smart`. Manual ranks: sleep 1, silent 2, quiet 3, windfree 4, low 5, medium/mid 6, pet 7, high 8, max 9, turbo 10,
  unknown 99. RotationSpeed: auto → 0; manual index i of n → floor((i+1)/n × 100); write L → L ≤ 0 → lowest manual;
  else manual[min(n−1, ceil(L/100 × n) − 1)].
- Debounce **[aziz66]**: TargetAirPurifierState and RotationSpeed writes are collected for 500 ms, then one
  `setFanMode` is sent: target AUTO wins; else the RotationSpeed's mode; else (MANUAL alone) the lowest manual mode.
- FilterMaintenance "<Name> Filter" (subtype `main/filter`): FilterLifeLevel = `filterState.filterLifeRemaining` or
  `custom.filterState.filterLifeRemaining` (0–100), else 100 − `custom.hepaFilter.hepaFilterUsage`;
  FilterChangeIndication = 1 when life < 10, or `custom.hepaFilter.hepaFilterStatus` not `normal`, or usage ≥ 90.
- AirQualitySensor (subtype `main/airQuality`), linked: PM2_5Density ↔ `dustSensor.fineDustLevel` or
  `fineDustSensor.fineDustLevel` (µg/m³); PM10Density ↔ `dustSensor.dustLevel`; VOCDensity ↔ `odorSensor.odorLevel`
  **[aziz66]**; AirQuality from PM2.5 when known (≤ 15 → 1, ≤ 35 → 2, ≤ 55 → 3, ≤ 75 → 4, else 5), else from
  `airQualitySensor.airQuality` (aziz66 maps ≤1 → 1 … ≤4 → 4, else 5, treating it as a 1–5 scale; the official range is
  0–100 **[conflict: the official attribute is an integer 0–100; Homeswift keeps aziz66's mapping only for values
  ≤ 5 and otherwise maps 0–100 in five equal bands, 0–20 → 1 … 81–100 → 5, unverified direction]**).
- Humidity and temperature on purifiers stay separate sensors (7.3.8), removed when never reported.

### 8.8 Air conditioner → 7.3.10.

### 8.9 Values for the web UI and MCP

The appliance values listed above that have no HomeKit characteristic are kept per device and shown on the plugin's
own page (`Web/`, `handleWebRequest`) and in Diagnostics, and given to MCP/Assistant tools through whatever per-device
detail the host offers **[Homeswift; the exact host mechanism is for the implementer]**: a table of `label: value`
(e.g. "Cycle: Cotton", "Remaining: 42 min", "Finishes at 14:35", "Remote control: allowed"). The web page may offer
Start/Pause for appliances whose remote control is enabled.

---

## 9. Television

### 9.1 Detection and publishing

A device is a TV when its `main` category is `Television` **[unverified name]**, or at least two of these groups are
present on any component **[aziz66]**: `samsungvd.deviceCategory`; `samsungvd.mediaInputSource`; `audioVolume` or
`audioMute`; `tvChannel`. With `enableTelevisionService` false, TVs map by the ordinary rules (a Switch).

Published with `context.publishExternal` (its own HAP server, category Television; `Plugins/PhilipsAmbilightTV` is the
example) unless `publishTVsAsExternal` is `false` (then bridged). Accessory Id unchanged. The README explains adding it
(Home → Add Accessory → More options → the TV → the setup code). aziz66's notes: iOS does not deliver the Control
Center remote's power button as a HomeKit write; the D-pad and volume do work **[aziz66]**.

TV capabilities consumed by the Television (`main` only): `switch`, `samsungvd.deviceCategory`,
`samsungvd.mediaInputSource`, `mediaInputSource`, `custom.launchapp`, `audioVolume`, `audioMute`, `tvChannel`,
`mediaPlayback`, `mediaTrackControl`, `keypadInput`, `custom.picturemode`, `custom.soundmode`.

### 9.2 Television service

- Active ↔ `switch.switch`; write `switch.on`/`off`. **Power on**: SmartThings can only turn a TV on when the TV keeps
  its network connection in standby (Samsung's "Power On with Mobile"/network standby) **[unverified; aziz66 sends
  `switch.on` and has no wake fallback]**; a TV fully off reports OFFLINE health → Not Responding is wrong for a TV:
  **[Homeswift]** a TV whose health is OFFLINE reads Active 0, not an error.
- ConfiguredName = Name; SleepDiscoveryMode 1 (always discoverable) **[Homeswift]**; aziz66 reports 0 (not
  discoverable).
- Inputs (InputSource services, linked):
  - From `samsungvd.mediaInputSource.supportedInputSourcesMap.value`: an array of `{ "id": "HDMI1", "name": "PlayStation" }`
    (the TV's own names); duplicates by `id` keep the longer name; order as the TV gives **[aziz66; Samsung custom,
    unverified]**. Else from `mediaInputSource.supportedInputSources.value` (official enum values `AM`, `CD`, `FM`,
    `HDMI`, `HDMI1`…`HDMI6`, `digitalTv`, `USB`, `YouTube`, `aux`, `bluetooth`, `digital`, `melon`, `wifi`, `network`,
    `optical`, `coaxial`, `analog1`…`analog3`, `phono`), names = the ids. Else aziz66's fallback list (`dtv` Live TV,
    `HDMI1`…`HDMI4`).
  - Then one input per `tvApps` entry (InputSourceType APPLICATION, name from the table in 2.1).
  - InputSourceType: `dtv`/`digitalTv` → TUNER (2), `HDMI*` → HDMI (3), `USB` → USB (8), `COMPONENT` → COMPONENT_VIDEO
    (6), `COMPOSITE` → COMPOSITE_VIDEO (4), apps → APPLICATION (10), else OTHER (0).
  - Identifier: 1-based position; subtype `main/input.<id>` (stable by SmartThings id, not position) **[Homeswift]**.
  - IsConfigured 1, CurrentVisibilityState 0 (shown), TargetVisibilityState writable and kept in a Plugin Accessory
    Setting (`hiddenInputs`) **[Homeswift]**.
  - When the source list changes (compare id+name sets), rebuild the inputs (external accessory: republish).
- ActiveIdentifier ↔ the input whose id equals `samsungvd.mediaInputSource.inputSource` or
  `mediaInputSource.inputSource`; app inputs are active when `custom.launchapp` reports that app **[unverified
  attribute]**; unknown keeps the last.
  Write: an app → `custom.launchapp.launchApp [appId]` **[aziz66; Samsung custom]**; a source →
  `samsungvd.mediaInputSource.setInputSource [id]`, and if that fails `mediaInputSource.setInputSource [id]`.
- RemoteKey (write-only) **[Homeswift, from official capabilities]**:

| HomeKit key | Command (first that the TV has) |
|---|---|
| ARROW_UP/DOWN/LEFT/RIGHT (4–7) | `keypadInput.sendKey ["UP"|"DOWN"|"LEFT"|"RIGHT"]` |
| SELECT (8) | `keypadInput.sendKey ["SELECT"]` |
| BACK (9) | `keypadInput.sendKey ["BACK"]` |
| EXIT (10) | `keypadInput.sendKey ["EXIT"]` |
| INFORMATION (15) | `keypadInput.sendKey ["MENU"]` (or `SETTINGS`) |
| PLAY_PAUSE (11) | `mediaPlayback.pause` when `playbackStatus` is `playing`, else `mediaPlayback.play` |
| REWIND (0) / FAST_FORWARD (1) | `mediaPlayback.rewind` / `mediaPlayback.fastForward` |
| NEXT_TRACK (2) / PREVIOUS_TRACK (3) | `mediaTrackControl.nextTrack`/`previousTrack`, else `tvChannel.channelUp`/`channelDown` |

  Only keys whose capability is present (and, for `keypadInput`, listed in `supportedKeyCodes` when that attribute is
  present) do anything; others are ignored without error. aziz66 never uses `keypadInput`; it sends the D-pad only
  over its local WebSocket. Whether Samsung TVs report `keypadInput` is **[unverified]**; Samsung's own
  `samsungvd.remoteControl` capability is **[unverified]** and not used.
- PictureMode (with `custom.picturemode`, attribute `pictureMode`, command `setPictureMode [name]` **[aziz66]**): only
  STANDARD (4) ↔ `Standard` and VIVID (6) ↔ `Dynamic`; others read STANDARD. Optional; web UI shows the real name.

### 9.3 Speaker and volume

- TelevisionSpeaker (linked): Active 1; Mute ↔ `audioMute.mute` (`muted` → true); write `audioMute.setMute ["muted"|
  "unmuted"]`, falling back to `audioMute.mute`/`unmute` if that fails **[aziz66; official commands]**.
- With `audioVolume`: VolumeControlType 3 (ABSOLUTE), Volume ↔ `audioVolume.volume` (0–100 integer); write
  `audioVolume.setVolume [v]` (unmute first when muted and v > 0, as aziz66); VolumeSelector (0 up, 1 down) →
  `audioVolume.volumeUp` / `volumeDown`. Without it but with `audioMute`: VolumeControlType 1 (RELATIVE) and only
  VolumeSelector (no command target → ignored).
- `registerVolumeSlider`: a Lightbulb "<Name> Volume" on the TV accessory (subtype `main/volume`, aziz66's subtype was
  `VolumeSlider`): On ↔ not muted (write On false → mute, true → unmute), Brightness ↔ volume.

### 9.4 Not done

Channels list, sound modes as inputs, Art Mode, power off via long-press, local key presses (9.5).

### 9.5 aziz66's local Samsung TV control (`frameTvDevices`)

aziz66 opens a local WebSocket to the TV (Samsung's remote-control protocol, token saved after "Allow" on the TV) for
true power off (KEY_POWER held 3.5 s), Art Mode switch (separate accessory `<deviceId>-artmode`), D-pad and volume
keys. **[Homeswift]** Out of scope for this port: the block's `frameTvDevices` is loaded and ignored, and the README
points to it as a possible later addition. Its `token` field is secret-named and masked.

---

## 10. Security system and Home Monitor

### 10.1 Devices with `securitySystem` **[official capability; aziz66 mapping]**

Official: `securitySystem.securitySystemStatus` (`armedAway`, `armedStay`, `disarmed`), `sensorStatus` (`ready`,
`bypassedNotReady`), `supportedSecuritySystemCommands` (`armAway`, `armStay`, `disarm`),
`supportedSecuritySystemStatuses`; commands `armAway (bypassAll: boolean)`, `armStay (bypassAll)`, `disarm`. aziz66
also handles `armedNight` / `armNight` (not in the official list).

SecuritySystem service (security control, written only via `set_security_accessory`):
- CurrentState: `armedStay` → 0, `armedAway` → 1, `armedNight` → 2, `disarmed` → 3; any of `alarm.alarm` in
  {`siren`, `both`}, `panicAlarm.panicAlarm == panic`, `temperatureAlarm.temperatureAlarm` in {`heat`, `freeze`}
  (when those capabilities are on the component) → 4 (ALARM_TRIGGERED). Unknown statuses keep the last settled state.
- TargetState validValues from `supportedSecuritySystemCommands` (`armStay` → 0, `armAway` → 1, `armNight` → 2,
  `disarm` → 3, disarm always included); default [0, 1, 3]. Write 0 → `armStay [false]`, 1 → `armAway [false]`,
  2 → `armNight [false]` if supported else `armStay [false]`, 3 → `disarm`. Set CurrentState optimistically; on failure
  restore the last settled state and fail the write.
- SecuritySystemAlarmType 1 while an alarm capability is active (only when one of them exists).

### 10.2 SmartThings Home Monitor (STHM)

- The only official API surface is the **read** scope `r:security:locations:*:armstate` and the webhook subscription
  type `SECURITY_ARM_STATE` **[official: app-setup, subscribe-to-events; sdk: subscriptions.ts]**. SSE has **no**
  security event type **[official: sse-subscriptions]**. There is no documented REST endpoint to read or set the arm
  state; the Rules API's location action only sets a mode **[sdk: rules.ts `LocationAction`]**. Users report that the
  armstate scope cannot be granted to their apps and that undocumented security calls answer 403 **[community:
  https://community.smartthings.com/t/we-need-api-access-to-sthm/260339]**; one user reports a Rules API payload with
  `Disarmed`/`ArmedStay`/`ArmedAway` accepted **[community, unverified]**.
- aziz66 has no STHM support; its Security System is only for devices with `securitySystem` **[aziz66]**.
- **[Homeswift]** STHM is **not reachable** with the scopes and transports this port uses (no public webhook, SSE
  lacks the event, no REST call). The README says so and suggests SmartThings routines bridged to a virtual switch.
  If a later official API appears, add it as a Security System with Device Id `homeMonitor:<locationId>`.

---

## 11. Scenes **[Homeswift requirement]**

- `GET scenes?locationId=<locationId>` at discovery. Each scene is a Discovered Device: Device Id `scene:<sceneId>`,
  Name `sceneName`, Device Kind `scene`, model "SmartThings scene", `isSetUp: true` (the account covers it).
- **Excluded by default** **[Homeswift: spec writer's choice, open question 16]**; Included → an accessory
  `HomeBridgeSmartThings:scene:<sceneId>` with one Switch (subtype `main/scene`): On write → `POST scenes/{sceneId}/
  execute`; the switch returns to Off after 1 s (momentary); reads always Off. A failed execute fails the write.
- Also `scenes()` (Included scenes as `PluginScene(id: sceneId, name: sceneName)`) and `recallScene(id:)` (execute), so
  they appear on the web UI's Scenes page and to `list_scenes`/`run_scene` (docs/plugins.md, "Scenes").
- Scenes list refreshed at each discovery and on `SCENE_LIFECYCLE_EVENT`. A deleted scene → its accessory removed.
- 50 executions/minute per scene; one execute per write; no retry on 429 beyond 6.2.

---

## 12. Matter devices and copies of Homeswift's own accessories

### 12.1 What Homeswift's Matter bridge looks like (from this repository)

`Sources/HomeswiftMatter/HomeswiftMatterBridge.swift` and swift-matter (`mp-consulting/swift-matter`, checkout
`de5c46a1efe2834c2eb10242fbadb9e873da60a9`):
- The bridge node: Basic Information vendorName **"Homeswift"**, productName **"Homeswift Bridge"**, nodeLabel
  "Homeswift", vendorID **0xFFF1 (65521)**, productID **0x8000 (32768)** (swift-matter's defaults, the Matter test
  vendor), device type aggregator; its UniqueID is 32 random hex digits kept in its storage.
- Each bridged accessory is an endpoint with Bridged Device Basic Information: NodeLabel = accessory name,
  VendorName = the accessory's Manufacturer (pass-through), ProductName = its Model, SerialNumber = its serial, and
  **UniqueID = the Homeswift Accessory Id itself when it is ≤ 32 UTF-8 bytes, else the first 32 hex digits of its
  SHA-256** (swift-matter `BridgedDeviceInfo.uniqueID`).
- "A device of its own" (docs/matter.md): an accessory can be its own Matter node with Basic Information vendorName =
  its Manufacturer (or "Homeswift"), productName = its Model (or its name), and the same UniqueID rule; vendor/product
  ids again 0xFFF1/0x8000.
- 0xFFF1/0x8000 is also what other software bridges use by default (e.g. Matterbridge) **[spec writer's knowledge,
  unverified]**: vendor/product ids alone do not identify Homeswift.

### 12.2 What SmartThings shows **[sdk; mapping to Matter attributes unverified]**

A SmartThings Matter device has `type: "MATTER"` and a `matter` object with `vendorId`, `productId`, `uniqueId`,
`networkId`, `hubId`, `endpoints`, `version`; and may have `parentDeviceId` / `childDevices`. When a Matter bridge is
commissioned, SmartThings onboards every bridged device automatically **[official blog:
https://blog.smartthings.com/tag/matter-bridges]**. Whether bridged devices appear as children (`parentDeviceId` =
the bridge device), whether their `matter.vendorId`/`productId` are the bridge node's, whether `matter.uniqueId` is
the endpoint's UniqueID, and what `manufacturerName` the bridge device gets, are all **[unverified]**.

### 12.3 Detection rule **[Homeswift requirement]**

Let `H` = the set of Homeswift Accessory Ids of this bridge (all plugins; from the host, e.g. the values of
`context.publishedIndex()` or another host listing the implementer finds) and `U(H)` = for each, the id itself if ≤ 32
bytes else the first 32 lowercase hex digits of its SHA-256 (compare case-insensitively).

1. A device B is **Homeswift's bridge** when `B.matter.vendorId == 65521` and `B.matter.productId == 32768` and
   (`B.manufacturerName` is "Homeswift", case-insensitive, or `B.name`/`B.label`/`B.ocf.modelNumber` contains
   "Homeswift Bridge", or B has no manufacturer at all). The bridge device itself is never an accessory (nothing to
   map; Excluded).
2. A device D is a **copy** when any of:
   a. following `parentDeviceId` up to 4 levels reaches a Homeswift bridge (the child's own `manufacturerName` is
      ignored: it is the original device's, passed through);
   b. `D.type == "MATTER"` and `D.matter.networkId` equals a Homeswift bridge's `matter.networkId` (same Matter node)
      **[unverified that bridged endpoints share the node's networkId]**;
   c. `D.matter.vendorId == 65521`, `D.matter.productId == 32768` and `D.matter.uniqueId` ∈ `U(H)` (a device of its own,
      or a bridged endpoint if SmartThings reports the endpoint's UniqueID).
3. A copy is **skipped always**: not a Discovered Device, not polled, its SSE events ignored; logged once at info
   ("Skipping <label>: it is Homeswift's own accessory through Homeswift's Matter bridge"). Diagnostics lists skipped
   copies with the rule that matched and the device's `type`, `parentDeviceId`, `matter` object and
   `manufacturerName`, so the rule can be checked against real data.
4. A device that matches the vendor/product ids but no other condition is **not** a copy (another bridge on the test
   vendor id).

### 12.4 Other Matter devices **[Homeswift requirement]**

For a device with `type: "MATTER"` that is not a copy, Setup adds a note to its Discovered Device: "This is a Matter
device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home." Nothing automatic:
the person sets Not in Home (or Excluded).

---

## 13. Homeswift requirements

### 13.1 Paid API (README must say)

- SmartThings API access for individuals needs a **Developer plan**: $4.99/month (US price before tax), "up to 100,000
  cloud API calls per month", "up to 10 active app installs across locations", personal household locations only,
  SSE and webhooks included, available in "select countries" only **[official: https://developer.smartthings.com/
  smartthingsapi, blog URL in section 0]**.
- Timeline **[official blog]**: free access through 2026-11-03; plans launched 2026-11-04 (without one, no new or edited
  API apps); from 2026-12-15 access for accounts without a plan "may be limited, paused, or discontinued" and active
  API keys are deactivated.
- **Who pays**: the plan is "a flat monthly rate per developer account"; the plans page's ownership table lists an
  "API Access App (Developer)" as owned by the end user. Since every Homeswift user creates their own app (3.2), each
  user is a developer and needs their own plan **[spec writer's reading]**. Whether someone who only authorizes another
  person's app also needs a plan is **unclear** (not stated officially).
- Homeswift is not affiliated with Samsung and cannot provide API access.

### 13.2 Sign-in

Browser Redirect with the person's own OAuth-In app (3.2–3.4); local HTTPS callback server, paste fallback. Scopes
`r:devices:* x:devices:* r:locations:* r:scenes:* x:scenes:*` plus `sse` when the app has it (Setup asks the person
whether they added `sse`; if the token response's `scope` lacks it, SSE is off and the plugin says so).
Access tokens ≈ 24 h; refresh tokens single-use, ≈ 30 days; every new refresh token is saved before use; a lost one
means signing in again (3.6). `accountAuthorization = .browserRedirect`, `accountRequirement = .required`.

### 13.3 Updates

SSE when granted (5.1); otherwise one list call per period (5.3). No webhooks: `server_url`, `webhook_port`,
`verifyWebhookSignatures`, `selectedCapabilities` (and ik's `WebhookToken`) load and are ignored, because a webhook
needs a public HTTPS address; the README says so.

### 13.4 Scope of accessories

All standard capabilities of section 7 with their combinations; appliances (8), TVs (9), `securitySystem` devices (10),
scenes (11). Nothing-to-map devices are Excluded Discovered Devices (7.6). Homeswift copies skipped (12.3); other Matter
devices noted (12.4).

### 13.5 Setup

- `discover()`: needs the account; lists every device of the authorized location (Excluded ones with
  `excludedBySettings` from 2.4, nothing-to-map ones Excluded), the scenes (Excluded by default), Device Kind per 7.7,
  model per 7.1, room hint from SmartThings rooms when cheap. Answers from the last reconciliation when fresh (< 60 s),
  else one list call; within a few seconds.
- Steps: (1) client id, client secret, optional callback address/port, a choice "My app has the sse scope" (yes/no);
  (2) authorize URL + wait + paste field; (3) done: credentials (client id, client secret) to the vault, tokens to the
  secret file, settings `locationId`, `callbackServerExternalAddress`/`callbackServerPort` when typed. Errors as 3.8.
- After a Needs Authorization, the same Setup again keeps Accessory Ids and settings.

### 13.6 README contents

1. What it does; the Developer plan requirement and dates (13.1); not affiliated with Samsung.
2. Creating the app (3.2), the exact scopes, the redirect URI Homeswift shows, the client secret shown once.
3. Signing in; the browser's certificate warning on the redirect; the paste fallback (httpbin.org option).
4. One location per sign-in; several locations → several instances (if the host allows; open question).
5. SSE vs polling, the monthly call budget and how the poll period is chosen (5.3); buttons need SSE.
6. What each device becomes (summary of 7–11); Home Monitor not reachable (10.2); TVs added on their own.
7. Matter devices and Not in Home (12.4); Homeswift's own devices skipped (12.3).
8. Coming from homebridge-smartthings-oauth / -ik: the block loads as is; tokens are imported; `client_id` stays in
   clear text until the first settings write; ignored keys listed.
9. Troubleshooting: 403 (plan or scopes), `invalid_grant` (sign in again), "redirect_uri_mismatch", 429 (poll period).

---

## 14. Edge cases and bugs in the Homebridge plugins (described, not to be reproduced unless sensible)

1. **ik's Authorization header** is `Bearer: <token>` (with a colon) **[ik: platform.ts, multiServiceAccessory.ts]**.
   SmartThings apparently accepted it. Homeswift sends `Bearer <token>`.
2. **ik's garage door** reads `PollSensorsSeconds` when `PollDoorsSeconds` is set **[ik]**; `GarageDoorMaxPoll` is
   never read.
3. **ik's webhook relay**: device events through the author's own server `stwh.kleinstudios.net` with `WebhookToken`
   **[ik]**. Never contacted by Homeswift.
4. **Combination order**: aziz66 sorts combinations by size with a comparator that never returns 0, so ties (e.g. the
   three two-capability light rules vs the valve and fan rules) depend on the engine's sort **[aziz66]**. Fixed order
   in 7.2.
5. **Duplicate service names**: every component's services are named with the device label **[aziz66]**.
6. **Service lookup by type only**: on multi-component devices aziz66 has to work around HAP-NodeJS returning another
   component's service of the same type **[aziz66 comments]**. Subtypes by component (7.1) avoid it.
7. **AC switchLevel light** never created (7.3.10).
8. **Thermostat CurrentTemperature reads 0 °C** when status fails (to avoid a Homebridge crash) **[aziz66]**: HomeKit
   then shows 0 °C. Homeswift answers a communication failure.
9. **Thermostat setpoint by cached mode** (7.3.4).
10. **Light colour**: `setHue` and `setSaturation` sent separately, then `setColor` sends the cached pair (which may be
    stale) **[aziz66]**. Homeswift batches (7.3.2).
11. **Per-characteristic polling** blows through rate limits on larger homes (aziz66's CHANGELOG mentions hitting
    them) **[aziz66]**. Homeswift: one list call (5.2).
12. **Washer RemainingDuration** must be seeded once per cycle; re-pushing every poll resets Apple Home's countdown and
    leaves "Waiting" **[aziz66]**. Not applicable (no Valve) but keep in mind for any duration characteristic.
13. **Laundry job states are stale at cycle end**: a stopped machine may still report a job like `rinse`; InUse must
    require the machine to be running **[aziz66]** (8.2 does).
14. **Spelling variants**: dryers report `aIDrying` (official) and `aiDrying` (seen) **[aziz66]**; compare
    case-insensitively.
15. **Samsung purifier beeps** on every command: skip redundant `switch.on`, debounce fan mode writes (8.7).
16. **AC Active 0 together with speed 0**: HomeKit sends both when the slider goes to 0; aziz66 ignores the off for
    1.5 s or when the mode is auto (7.3.10).
17. **Rotating refresh token races**: concurrent refreshes burned the token (aziz66 issue #28); refresh tokens not
    saved after a refresh caused `invalid_grant` after 24 h (fixed in aziz66 later) **[aziz66 CHANGELOG]**. 3.6 rules.
18. **Token file wins over config** except when the wizard ran again (3.7).
19. **Device names with typographic quotes**: SmartThings labels use ’ and “”; name lists compare after normalising
    **[aziz66]** (2.1).
20. **Fridge**: `main` and `cooler` both report the fridge temperature; disabled compartments still listed as
    components **[aziz66]** (8.5).
21. **Empty label** → aziz66 names the device "Missing Name" **[aziz66]**; Homeswift uses `name`, then "SmartThings
    device".
22. **Button polling**: the first poll is a baseline; same-value presses between polls are invisible **[aziz66]**.
23. **429 handling**: plugin-wide back-off serving the cache; commands retried only for short waits **[aziz66]** (6.2).
24. **Offline**: 5 failures spanning ≥ 60 s; recovery probe once a minute, or 10 s when HomeKit reads **[aziz66]**.
25. **SSE events lack units** (5.1): temperatures from events must reuse the status unit (aziz66's webhook events carry
    `unit`; SSE's documented payload does not).
26. **`setLevel 0` turns lights off** (official): a Brightness 0 write is an off (7.3.2).
27. **TV power-on** is not possible when the TV is fully off without network standby (9.2) **[unverified]**.
28. **aziz66 ended** ("Final release" 1.0.68, 2026-09-25), likely with the paid API change **[aziz66 CHANGELOG]**.

---

## 15. Test fixtures (written by the spec writer from the documented shapes; ids fake)

Location `5f2a6c1e-0000-4000-8000-0000000000a1`.

### 15.1 Token response (3.5)

```json
{ "access_token": "11111111-1111-4111-8111-111111111111", "token_type": "bearer",
  "refresh_token": "22222222-2222-4222-8222-222222222222", "expires_in": 86399,
  "scope": "r:devices:* x:devices:* r:locations:* r:scenes:* x:scenes:* sse", "access_tier": 0,
  "installed_app_id": "33333333-3333-4333-8333-333333333333",
  "developer_account_id": "44444444-4444-4444-8444-444444444444",
  "iot_account_id": "44444444-4444-4444-8444-444444444444", "owner_account_id": "44444444-4444-4444-8444-444444444444" }
```

Refresh: `POST /v1/oauth/token` body
`grant_type=refresh_token&refresh_token=22222222-2222-4222-8222-222222222222&client_id=7a850484-0000-4000-8000-000000000001`
→ a new pair (`…5555`, `…6666`); the vault must hold `…6666` before any call uses `…5555`.
`400 {"error":"invalid_grant","error_description":"Invalid refresh token"}` → Needs Authorization.

### 15.2 Devices list, page 1 (`GET devices?locationId=…&includeStatus=true&includeHealth=true`)

```json
{
  "items": [
    {
      "deviceId": "0a1b2c3d-0000-4000-8000-0000000000d1", "name": "c2c-rgbw-color-bulb", "label": "Living Room Lamp",
      "manufacturerName": "SmartThingsCommunity", "presentationId": "c2c-rgbw-color-bulb",
      "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "roomId": "7c7c7c7c-0000-4000-8000-0000000000r1",
      "type": "ZIGBEE", "healthState": { "state": "ONLINE", "lastUpdatedDate": "2026-11-07T09:00:00.000Z" },
      "components": [ { "id": "main", "label": "main",
        "categories": [ { "name": "Light", "categoryType": "manufacturer" } ],
        "capabilities": [
          { "id": "switch", "version": 1, "status": { "switch": { "value": "on", "timestamp": "2026-11-07T08:59:00.000Z" } } },
          { "id": "switchLevel", "version": 1, "status": { "level": { "value": 72, "unit": "%", "timestamp": "2026-11-07T08:59:00.000Z" } } },
          { "id": "colorControl", "version": 1, "status": { "hue": { "value": 50 }, "saturation": { "value": 80 }, "color": { "value": null } } },
          { "id": "colorTemperature", "version": 1, "status": { "colorTemperature": { "value": 2700, "unit": "K" },
            "colorTemperatureRange": { "value": { "minimum": 2200, "maximum": 6500 }, "unit": "K" } } },
          { "id": "healthCheck", "version": 1 }, { "id": "refresh", "version": 1 } ] } ]
    },
    {
      "deviceId": "9b1c2d3e-0000-4000-8000-0000000000d3", "name": "Thermostat", "label": "Floor Heating",
      "manufacturerName": "Stelpro", "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "type": "ZIGBEE",
      "healthState": { "state": "ONLINE" },
      "components": [ { "id": "main", "categories": [ { "name": "Thermostat", "categoryType": "manufacturer" } ],
        "capabilities": [
          { "id": "temperatureMeasurement", "version": 1, "status": { "temperature": { "value": 68.5, "unit": "F" } } },
          { "id": "thermostatHeatingSetpoint", "version": 1, "status": { "heatingSetpoint": { "value": 70, "unit": "F" } } },
          { "id": "thermostatMode", "version": 1, "status": { "thermostatMode": { "value": "radiatingfloor" },
            "supportedThermostatModes": { "value": ["off", "heat", "radiatingfloor"] } } },
          { "id": "thermostatOperatingState", "version": 1, "status": { "thermostatOperatingState": { "value": "heating" } } } ] } ]
    },
    {
      "deviceId": "3e4f0d2c-0000-4000-8000-0000000000d7", "name": "SmartThings v3 Hub", "label": "Hallway Hub",
      "manufacturerName": "SmartThings", "type": "HUB", "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1",
      "components": [ { "id": "main", "categories": [ { "name": "Hub", "categoryType": "manufacturer" } ], "capabilities": [] } ]
    }
  ],
  "_links": { "next": { "href": "https://api.smartthings.com/v1/devices?locationId=5f2a6c1e-0000-4000-8000-0000000000a1&includeStatus=true&includeHealth=true&page=2" } }
}
```

Expected: lamp → Lightbulb On true, Brightness 72, Hue 180, Saturation 80, ColorTemperature 370, props 154–455
(1e6/6500 = 153.8 → 154; 1e6/2200 = 454.5 → 455), Adaptive Lighting. Thermostat (C9 + mode) → CurrentTemperature 20.28 °C,
TargetTemperature 21.11 °C, TargetHeatingCoolingState 1 (radiatingfloor → HEAT), validValues [0, 1], current 1
(heating), display units 1; a HEAT write sends `setThermostatMode ["radiatingfloor"]` when its `heatMode` is set, and
TargetTemperature 22 sends `setHeatingSetpoint [72]`. Hub → Excluded Discovered Device, kind `unsupported`.

### 15.3 Washer status (`GET devices/{id}/status`)

```json
{ "components": { "main": {
  "switch": { "switch": { "value": "on" } },
  "remoteControlStatus": { "remoteControlEnabled": { "value": "true" } },
  "washerOperatingState": {
    "machineState": { "value": "run" }, "washerJobState": { "value": "rinse" },
    "supportedMachineStates": { "value": ["stop", "run", "pause"] },
    "completionTime": { "value": "2026-11-07T10:42:00Z" } },
  "washerMode": { "washerMode": { "value": "regular" } },
  "samsungce.washerOperatingState": { "remainingTime": { "value": 42, "unit": "min" } }
} }, "healthState": { "state": "ONLINE" } }
```

Expected: Switch "Power" On; OccupancySensor "Running" occupied; web: "Remaining 42 min" (at 10:00 UTC), "Job:
rinse", "Remote control: allowed". With `machineState` `stop` and `washerJobState` still `rinse`: Running not occupied.

### 15.4 TV (`main` of a device list item)

```json
{ "deviceId": "6d6d6d6d-0000-4000-8000-0000000000d4", "label": "Living Room TV", "manufacturerName": "Samsung Electronics",
  "type": "OCF", "ocf": { "ocfDeviceType": "oic.d.tv", "modelNumber": "QE55Q80", "firmwareVersion": "T-PTMAKUC-1.0" },
  "healthState": { "state": "ONLINE" },
  "components": [ { "id": "main", "categories": [ { "name": "Television", "categoryType": "manufacturer" } ],
    "capabilities": [
      { "id": "switch", "version": 1, "status": { "switch": { "value": "on" } } },
      { "id": "audioVolume", "version": 1, "status": { "volume": { "value": 14, "unit": "%" } } },
      { "id": "audioMute", "version": 1, "status": { "mute": { "value": "unmuted" } } },
      { "id": "tvChannel", "version": 1, "status": { "tvChannel": { "value": "5" }, "tvChannelName": { "value": "" } } },
      { "id": "mediaPlayback", "version": 1, "status": { "playbackStatus": { "value": "playing" } } },
      { "id": "keypadInput", "version": 1, "status": { "supportedKeyCodes": { "value": ["UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK", "EXIT", "MENU", "HOME"] } } },
      { "id": "samsungvd.mediaInputSource", "version": 1, "status": {
        "inputSource": { "value": "HDMI2" },
        "supportedInputSourcesMap": { "value": [ { "id": "dtv", "name": "TV" }, { "id": "HDMI1", "name": "HDMI1" },
                                                 { "id": "HDMI2", "name": "PlayStation" }, { "id": "HDMI2", "name": "HDMI2" } ] } } },
      { "id": "custom.launchapp", "version": 1 }, { "id": "samsungvd.deviceCategory", "version": 1 } ] } ] }
```

Expected: Television (external) Active 1; inputs TV (TUNER), HDMI1 (HDMI), PlayStation (HDMI; the duplicate HDMI2 keeps
the longer name), then `tvApps`; ActiveIdentifier 3; Volume 14, Mute false; RemoteKey ARROW_UP →
`keypadInput.sendKey ["UP"]`; PLAY_PAUSE → `mediaPlayback.pause`. Model QE55Q80, firmware T-PTMAKUC-1.0.

### 15.5 Matter devices

```json
{ "items": [
  { "deviceId": "aaaa0000-0000-4000-8000-0000000000b0", "label": "Homeswift Bridge", "name": "Homeswift Bridge",
    "manufacturerName": "Homeswift", "type": "MATTER",
    "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000ABC",
                "uniqueId": "8f14e45fceea167a5a36dedd4bea2543", "hubId": "3e4f0d2c-0000-4000-8000-0000000000d7" },
    "childDevices": [ { "id": "aaaa0000-0000-4000-8000-0000000000b1" } ],
    "components": [ { "id": "main", "capabilities": [ { "id": "healthCheck", "version": 1 } ] } ] },
  { "deviceId": "aaaa0000-0000-4000-8000-0000000000b1", "label": "Desk Light", "manufacturerName": "Elgato",
    "type": "MATTER", "parentDeviceId": "aaaa0000-0000-4000-8000-0000000000b0",
    "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000ABC",
                "uniqueId": "ElgatoKeyLights:3C6A9D0011AA" },
    "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1 }, { "id": "switchLevel", "version": 1 } ] } ] },
  { "deviceId": "bbbb0000-0000-4000-8000-0000000000c1", "label": "Eve Energy", "manufacturerName": "Eve Systems",
    "type": "MATTER", "matter": { "vendorId": 4874, "productId": 80, "networkId": "0000000000000DEF" },
    "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1 }, { "id": "powerMeter", "version": 1 } ] } ] },
  { "deviceId": "cccc0000-0000-4000-8000-0000000000c2", "label": "Matterbridge Plug", "manufacturerName": "Matterbridge",
    "type": "MATTER", "matter": { "vendorId": 65521, "productId": 32768, "networkId": "0000000000000F00" },
    "components": [ { "id": "main", "capabilities": [ { "id": "switch", "version": 1 } ] } ] }
], "_links": {} }
```

Expected (with `ElgatoKeyLights:3C6A9D0011AA` in H): the bridge → Homeswift's bridge, skipped; Desk Light → copy
(rules a, b and c), skipped although its manufacturer is Elgato; Eve Energy → a Switch with a Meter and the "may already
be in Apple Home" note; Matterbridge Plug → not a copy (manufacturer is not Homeswift, no parent, uniqueId unknown) →
a Switch with the note. A uniqueId of 32 hex digits equal to the first 32 hex digits of SHA-256 of a long Homeswift
Accessory Id also matches rule c.

### 15.6 Scenes list

```json
{ "items": [
  { "sceneId": "dddd0000-0000-4000-8000-0000000000e1", "sceneName": "Good Night", "sceneIcon": "204", "sceneColor": null,
    "locationId": "5f2a6c1e-0000-4000-8000-0000000000a1", "createdBy": "44444444-4444-4444-8444-444444444444",
    "createdDate": "2026-01-02T20:00:00.000Z", "lastUpdatedDate": "2026-01-02T20:00:00.000Z",
    "lastExecutedDate": "2026-11-06T22:30:00.000Z", "editable": false, "apiVersion": "" } ],
  "_links": {} }
```

Expected: Discovered Device `scene:dddd0000-0000-4000-8000-0000000000e1` "Good Night", kind `scene`, Excluded by
default; Included → Switch; On → `POST scenes/dddd0000-0000-4000-8000-0000000000e1/execute`, Off after 1 s.

### 15.7 SSE

Create:

```
POST /v1/sse/subscriptions
User-Agent: Homeswift/0.9.0 (SmartThings plugin; https://homeswift.dev)
Authorization: Bearer 11111111-1111-4111-8111-111111111111
Content-Type: application/json

{"name":"homeswift-SmartThings","subscriptionFilters":[{"type":"LOCATIONIDS","value":["5f2a6c1e-0000-4000-8000-0000000000a1"],"eventType":["DEVICE_EVENT","DEVICE_HEALTH_EVENT","DEVICE_LIFECYCLE_EVENT","SCENE_LIFECYCLE_EVENT"]}]}
```

Response:

```json
{ "subscriptionId": "eeee0000-0000-4000-8000-0000000000f1",
  "registrationUrl": "https://sse.example.invalid/v1/sse/subscriptions/eeee0000-0000-4000-8000-0000000000f1/stream?token=REDACTED",
  "version": 1, "name": "homeswift-SmartThings",
  "subscriptionFilters": [ { "type": "LOCATIONIDS", "value": ["5f2a6c1e-0000-4000-8000-0000000000a1"],
                             "eventType": ["DEVICE_EVENT", "DEVICE_HEALTH_EVENT", "DEVICE_LIFECYCLE_EVENT", "SCENE_LIFECYCLE_EVENT"] } ] }
```

(The real `registrationUrl` host and form are not documented; treat it as opaque and never log it — it may carry a
credential.)

Stream transcript (blank line after each message):

```
event: CONTROL_EVENT
data: welcome

event: DEVICE_EVENT
data: {"eventTime":1794045600123,"eventType":"DEVICE_EVENT","deviceEvent":{"eventId":"f0f0f0f0-0000-4000-8000-000000000001","locationId":"5f2a6c1e-0000-4000-8000-0000000000a1","deviceId":"0a1b2c3d-0000-4000-8000-0000000000d1","componentId":"main","capability":"switch","attribute":"switch","value":"off","valueType":"string","stateChange":true,"subscriptionName":"homeswift-SmartThings"}}

event: DEVICE_EVENT
data: {"eventTime":1794045601456,"eventType":"DEVICE_EVENT","deviceEvent":{"eventId":"f0f0f0f0-0000-4000-8000-000000000002","locationId":"5f2a6c1e-0000-4000-8000-0000000000a1","deviceId":"9b1c2d3e-0000-4000-8000-0000000000d3","componentId":"main","capability":"temperatureMeasurement","attribute":"temperature","value":69.8,"valueType":"number","stateChange":true,"subscriptionName":"homeswift-SmartThings"}}

event: DEVICE_EVENT
data: {"eventTime":1794045602000,"eventType":"DEVICE_EVENT","deviceEvent":{"eventId":"f0f0f0f0-0000-4000-8000-000000000003","locationId":"5f2a6c1e-0000-4000-8000-0000000000a1","deviceId":"1e1e1e1e-0000-4000-8000-0000000000d8","componentId":"button1","capability":"button","attribute":"button","value":"pushed","valueType":"string","stateChange":false,"subscriptionName":"homeswift-SmartThings"}}

event: DEVICE_HEALTH_EVENT
data: {"eventTime":1794045610000,"eventType":"DEVICE_HEALTH_EVENT","deviceHealthEvent":{"eventId":"f0f0f0f0-0000-4000-8000-000000000004","locationId":"5f2a6c1e-0000-4000-8000-0000000000a1","deviceId":"0a1b2c3d-0000-4000-8000-0000000000d1","hubId":"3e4f0d2c-0000-4000-8000-0000000000d7","status":"OFFLINE","reason":"NONE"}}

event: CONTROL_EVENT
data: welcome

event: CONTROL_EVENT
data: goodbye
```

Expected: welcome → reconcile; lamp On false; thermostat CurrentTemperature 21.0 °C (unit F from the last status, not
the event); button1 single press although `stateChange` is false; lamp Not Responding (health payload shape
**[unverified]**); the second welcome is a keepalive (watchdog reset); goodbye → delete if possible, create a new
subscription, activate, reconcile.

### 15.8 Commands

| HomeKit write | Request body to `POST devices/{id}/commands` |
|---|---|
| Lamp Brightness 40 | `{"commands":[{"component":"main","capability":"switchLevel","command":"setLevel","arguments":[40]}]}` |
| Lamp Hue 120 + Saturation 50 | `{"commands":[{"component":"main","capability":"colorControl","command":"setColor","arguments":[{"hue":33,"saturation":50}]}]}` |
| Lamp ColorTemperature 250 | `{"commands":[{"component":"main","capability":"colorTemperature","command":"setColorTemperature","arguments":[4000]}]}` |
| AC target COOL | `{"commands":[{"component":"main","capability":"switch","command":"on","arguments":[]},{"component":"main","capability":"airConditionerMode","command":"setAirConditionerMode","arguments":["cool"]}]}` |
| AC TargetTemperature 23 (unit C) | `{"commands":[{"component":"main","capability":"thermostatCoolingSetpoint","command":"setCoolingSetpoint","arguments":[23]}]}` |
| Shade TargetPosition 100 (C11) | `{"commands":[{"component":"main","capability":"windowShade","command":"open","arguments":[]}]}` |
| Shade TargetPosition 35 (C11) | `{"commands":[{"component":"main","capability":"windowShadeLevel","command":"setShadeLevel","arguments":[35]}]}` |
| Lock target 1 | `{"commands":[{"component":"main","capability":"lock","command":"lock","arguments":[]}]}` |
| Security target 1 (away) | `{"commands":[{"component":"main","capability":"securitySystem","command":"armAway","arguments":[false]}]}` |
| Outlet 2 of a strip On | `{"commands":[{"component":"outlet2","capability":"switch","command":"on","arguments":[]}]}` |
| Washer Start (remote enabled, no `switch`) | `{"commands":[{"component":"main","capability":"washerOperatingState","command":"setMachineState","arguments":["run"]}]}` |

Response: `{"results":[{"id":"…","status":"ACCEPTED"}]}`.

---

## 16. Open questions and gaps

1. **Developer plan**: whether each end user needs a plan when using someone else's app (not our case, but asked);
   which countries; what status code accounts without a plan get after 2026-12-15; whether token refreshes and SSE
   calls count toward the 100,000 calls.
2. **Redirect URIs**: the https-only rule comes from community reports; whether a private IP / `.local` host is
   accepted is unknown; the CLI command name (`apps:create` vs `smartapps:create`) needs a check.
3. **Scopes**: whether `sse` is offered by `apps:create`'s scope picker and granted on authorize; whether a PAT can use
   SSE.
4. **SSE**: keepalive interval, TTL length, the goodbye message's exact form, payloads of `DEVICE_HEALTH_EVENT` and
   lifecycle events, the `registrationUrl` form.
5. **One location per authorization**: confirm; and whether Homeswift allows several instances of a
   `singular: true` platform for several locations.
6. **Matter**: how SmartThings represents bridged Matter devices (parent/child, shared `networkId`, `uniqueId` source,
   bridge `manufacturerName`); rule 12.3 must be validated against a real Homeswift bridge in SmartThings.
7. **Home Monitor**: no documented API to read or set its state with these scopes (10.2).
8. **Samsung custom capabilities** (`samsungce.*`, `samsungvd.*`, `custom.*`): not in the public reference; names and
   commands come from aziz66.
9. **Scenes default**: Excluded by default (spec writer's choice) vs included.
10. **Appliance Start vs Power**: one Switch (8.2) vs both; whether SmartThings refuses `setMachineState run` when remote
    control is off.
11. Category names (`Television`, `Washer`, `Light`…) are used only as hints; confirm against real devices.
12. `airQualitySensor.airQuality` scale (official 0–100 vs aziz66's 1–5 assumption).
