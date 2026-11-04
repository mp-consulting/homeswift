# Daikin Cloud

Daikin air conditioners and Altherma heat pumps in HomeKit through the Daikin Onecta cloud: the port of
[`@mp-consulting/homebridge-daikin-cloud`](https://github.com/mp-consulting/homebridge-daikin-cloud) to Homeswift, originally by
Jeroen Van den Berghe, under the Apache License 2.0 (notice and changes in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)).
Platform `DaikinCloud`; a Homebridge block works unchanged.

## What it does

- **Air conditioners** (any device with a climate control): a HeaterCooler with power, Cool / Heat / Auto (dry
  and fan only read as Auto), the room temperature, heating and cooling thresholds with the unit's ranges (the
  middle of the range is mirrored to Daikin's single auto setpoint), fan speed as a 0-100 % slider in steps of
  the unit's scale (5 levels: 20, 40, 60, 80, 100 %) and swing (both axes).
- **Altherma heat pumps**: the climate control as above (room temperature, or leaving water offset or temperature
  as the setpoint and control modes say), and the hot water tank as a Thermostat (on/off, tank temperature,
  setpoint 30-60 °C or the unit's range, modes the unit allows) with its own Powerful mode switch.
- **Feature switches**, each shown only when the unit supports it: Powerful, Econo, Streamer, Outdoor silent,
  Indoor silent (quiet fan), Auto fan, Oscillation, Dry, Fan only, Holiday (away) and Firmware Update (installs a
  firmware update Daikin staged; never implied by a Homebridge block's `showExtraFeatures`).
- **Separate Fan tile** (`showSeparateFanControl`): fan speed and oscillation stay reachable when the accessory
  is grouped into one tile in the Home app.
- **Real-time updates** over the Onecta WebSocket (Mobile App login): pushed changes reach HomeKit at once, with
  a ping every 30 s and reconnection with backoff.
- **The daily quota**: polling at `updateIntervalInMinutes`, stretched to an hour while the WebSocket pushes and
  when fewer than 20 calls are left, doubled per failed poll (up to four times); one debounced poll after changes
  from HomeKit (skipped while the WebSocket is connected); rapid writes to one setting coalesced into one request;
  requests blocked after a 429 until `Retry-After`; writes retried on 502/503/504, polls not.
- **The page** (Plugins › Daikin Cloud › Open): the Homebridge plugin's settings UI, without the settings. Devices
  (state, model, temperatures, features, offline and Excluded units with Explain, a unit's **Settings**);
  Authentication (the method, the token's status and expiry, Test connection, Sign in again, Revoke; signed out, a
  card that leads to Setup); Help (the quota of the last call, links, troubleshooting). It writes no settings:
  **Settings** at its top opens the plugin's Settings page.

## Logging in

Signing in is done on **Add accessories** (the Daikin Cloud row, then its account's Setup; the plugin's page leads
there), or by an AI agent through the MCP server's `start_setup` and `continue_setup`. Setup asks how to sign in first:

**Mobile App** (recommended: 3000 calls a day and the WebSocket): the Onecta app's email and password.

**Developer Portal** (200 calls a day): create an app at the [Daikin Developer Portal](https://developer.cloud.daikineurope.com/)
with the redirect URI `https://<this machine's address>:<callbackServerPort>` (8582 by default; Setup shows the one it
detected), then give Setup the Client ID and Secret (and the callback server's address or port when the detected ones
are not right), and sign in on Daikin's page. The plugin runs a temporary HTTPS server on that port for the redirect
(the browser warns once about its self-signed certificate) and stops it after ten minutes; when the redirect cannot
reach it, paste the URL the browser ends on. Once logged in, the instance connects without a restart. Choosing another
way of signing in than the block's also sets that way's recommended polling.

The login (email and password) and the Developer Portal app (Client ID and Secret) are the account's credentials:
Setup keeps them sealed in the bridge's vault, never in config.json. A Homebridge block's `daikinEmail`,
`daikinPassword` (or `email`, `password`), `clientId` and `clientSecret` still work; the first settings change written
through the bridge moves them into the vault and out of the block.

Tokens are kept sealed in the bridge's vault (`vault.json`, docs/vault-design.md), in entries named after the
Homebridge plugin's files `.daikin-controller-cloud-tokenset` (Developer Portal) and `.daikin-mobile-tokenset` (Mobile
App). A file copied from a Homebridge storage path into the plugin's folder (`~/.homeswift/plugins/DaikinCloud-<name>/`)
still works: the plugin moves it into the vault when it reads it, and removes it. The callback server's certificate is in
`daikin-cloud-certs/`, the last quota in `.daikin-rate-limit.json`.

The Assistant (the web UI's chat, MCP clients) can check the login, list the units, read the quota and test the
connection; signing out (`DaikinCloud_revoke`) asks first. It signs in only through Setup (`start_setup`), where the
secret and the password are entered by the person.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `authMode` | string | `developer_portal` | `developer_portal` or `mobile_app`, as Setup chose |
| `callbackServerExternalAddress` | string | - | The address your browser reaches this machine at, for the OAuth redirect (Setup detects it) |
| `callbackServerPort` | number | `8582` | Port of the OAuth callback server (1-65535) |
| `oidcCallbackServerBindAddr` | string | `0.0.0.0` | Interface the callback server listens on; `127.0.0.1` only when the browser runs on this machine (Setup refuses a loopback bind with a LAN address) |
| `updateIntervalInMinutes` | number | `15` | Polling interval, 1-60 (Developer Portal: 15+, Mobile App: 1-5), stretched as above |
| `forceUpdateDelay` | number | `60000` | Milliseconds (5000-300000) before the poll after a change from HomeKit |
| `enableWebSocket` | boolean | `true` | Real-time updates (Mobile App only) |
| `httpTransport` | string | `node` | `node` (the built-in client) or `curl` (the curl binary, for networks whose firewall drops the built-in client's TLS fingerprint). `DAIKIN_HTTP_TRANSPORT` overrides it |
| `showPowerfulMode` | boolean | `false` | Powerful mode switch (climate control and hot water tank) |
| `showEconoMode` | boolean | `false` | Econo mode switch |
| `showStreamerMode` | boolean | `false` | Streamer mode switch |
| `showOutdoorSilentMode` | boolean | `false` | Outdoor silent mode switch |
| `showIndoorSilentMode` | boolean | `false` | Indoor silent (quiet fan) switch |
| `showAutoFanMode` | boolean | `false` | Auto fan speed switch |
| `showOscillationSwitch` | boolean | `false` | Swing as its own switch |
| `showDryMode` | boolean | `false` | Dry mode switch |
| `showFanOnlyMode` | boolean | `false` | Fan only switch |
| `showHolidayMode` | boolean | `false` | Holiday (away) mode switch |
| `showSeparateFanControl` | boolean | `false` | A standalone Fan tile with fan speed and oscillation |
| `showFirmwareUpdateSwitch` | boolean | `false` | A switch that installs staged gateway firmware updates |

These are the Plugin Settings, edited on the plugin's **Settings** page in the web UI or with the MCP tools
`get_settings` and `update_settings`. Each unit has its Accessory Settings in the block's `_accessories`, by its Daikin
device id (the Device Id; the accessory is `DaikinCloud:<id>`): Excluded keeps it out of HomeKit, and each `show*`
switch above may be set for it alone, overruling the plugin's. A unit's Device Kind is `climateControl` (an air
conditioner), `domesticHotWaterTank` (an Altherma with its hot water tank) or `gateway` (neither, not an accessory).

A Homebridge block's `excludedDevicesByDeviceId` (device ids) and `showExtraFeatures` (the default of the ten extra
switches, from Powerful to Holiday) still load; the first settings change written through the bridge turns the ids into
Excluded units and `showExtraFeatures: true` into each extra switch it left unset.

The environment variables of the Homebridge plugin work too: `DAIKIN_HTTP_TRANSPORT`, `DAIKIN_USER_AGENT`, `DAIKIN_TLS_CIPHERS`,
`DAIKIN_WEBSOCKET_URL` and the Mobile App client's `DAIKIN_API_KEY`, `DAIKIN_CLIENT_ID`, `DAIKIN_CLIENT_SECRET`,
`DAIKIN_REDIRECT_URI`, `DAIKIN_GIGYA_BASE_URL`, `DAIKIN_IDP_TOKEN_ENDPOINT`, `DAIKIN_SCOPE`.

## What differs from Homebridge

- **Test connection** on the Authentication tab refreshes an expired token first, through the running instance;
  the Homebridge page sent the saved token as it was and reported "Token expired or invalid" once it had expired.
- No restart after logging in or saving: a settings change reloads the plugin, and a login through Setup connects an
  instance that was waiting for it. Each change is a reload, and the first poll of a reload costs a call.
- The page's device list comes from the running instance when it is connected (no API call); otherwise from one
  call, reused for five minutes, as in Homebridge.
- Revoke on the page also disconnects the running instance at once.
- The callback server's certificate is made by the plugin (P-256, the address as subject alternative name), not by
  the `openssl` binary, and is made again for another address or after 300 days.
- The `node` transport is Homeswift's built-in HTTP client (NIO and BoringSSL). It offers BoringSSL's `DEFAULT`
  cipher list, as the Homebridge plugin asks Node for OpenSSL's, and `DAIKIN_TLS_CIPHERS` overrides it for both the
  requests and the WebSocket; the ClientHello is BoringSSL's, so it is not byte for byte the same as Node's.
- The Assistant's Explain buttons are the web UI's (`HomeswiftAiKit`).
- Accessory ids are `DaikinCloud:<Daikin device id>`; feature switches always carry the management point in their
  subtype (`climateControl:powerful_mode`): there are no cached Homebridge switches to adopt.
- A unit whose operation mode changes whether it has a fixed fan speed has its accessory rebuilt (same aid and
  iids), where Homebridge added or removed RotationSpeed in place.
- Logging in is Setup's (Add accessories, or `start_setup`), not the settings page's: the page shows the login's state
  and leads to Setup. Setup's wait for a Developer Portal login does not report success at once when a token file
  already exists (re-authenticating).
- The callback server accepts TLS 1.2 and later only, and refuses a Callback Server Port outside 1–65535 when the
  login starts. The redirect arriving twice (a browser retry, or the URL also pasted) exchanges the code once.
