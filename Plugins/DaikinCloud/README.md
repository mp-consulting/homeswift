# Daikin Cloud

Daikin air conditioners and Altherma heat pumps in HomeKit through the Daikin Onecta cloud: the port of
[`@mp-consulting/homebridge-daikin-cloud`](https://github.com/mp-consulting/homebridge-daikin-cloud) to Homeswift.
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
  firmware update Daikin staged; never implied by `showExtraFeatures`).
- **Separate Fan tile** (`showSeparateFanControl`): fan speed and oscillation stay reachable when the accessory
  is grouped into one tile in the Home app.
- **Real-time updates** over the Onecta WebSocket (Mobile App login): pushed changes reach HomeKit at once, with
  a ping every 30 s and reconnection with backoff.
- **The daily quota**: polling at `updateIntervalInMinutes`, stretched to an hour while the WebSocket pushes and
  when fewer than 20 calls are left, doubled per failed poll (up to four times); one debounced poll after changes
  from HomeKit (skipped while the WebSocket is connected); rapid writes to one setting coalesced into one request;
  requests blocked after a 429 until `Retry-After`; writes retried on 502/503/504, polls not.
- **The page** (Plugins › Daikin Cloud › Open): the Homebridge plugin's settings UI. Devices (state, model,
  temperatures, features, offline units with Explain); Settings (feature switches, polling, network, hidden
  devices); Authentication (the method, the token's status and expiry, Test connection, Revoke, the Mobile App
  credentials, the Developer Portal wizard: configure, authorize through the HTTPS callback server or a pasted
  URL, complete); Help (the quota of the last call, links, troubleshooting).

## Logging in

**Mobile App** (recommended: 3000 calls a day and the WebSocket): on the page, Authentication › Mobile App ›
Configure credentials, then Test & save. Or in config.json:

```json
{ "platform": "DaikinCloud", "name": "Daikin Cloud", "authMode": "mobile_app", "daikinEmail": "<email>", "daikinPassword": "<password>" }
```

**Developer Portal** (200 calls a day): create an app at the [Daikin Developer Portal](https://developer.cloud.daikineurope.com/)
with the redirect URI `https://<this machine's address>:<callbackServerPort>` (8582 by default), then on the page:
Authentication › Authenticate, the Client ID and Secret, Continue, Open Daikin login. The plugin runs a temporary
HTTPS server on that port for the redirect (the browser warns once about its self-signed certificate) and stops it
after ten minutes; when the redirect cannot reach it, paste the URL the browser ends on. Once logged in, the
instance connects without a restart.

Tokens are kept in the plugin's folder (`~/.homeswift/plugins/DaikinCloud-<name>/`), owner-only:
`.daikin-controller-cloud-tokenset` (Developer Portal) and `.daikin-mobile-tokenset` (Mobile App), the Homebridge
plugin's files, so one copied from a Homebridge storage path works. The callback server's certificate is in
`daikin-cloud-certs/`, the last quota in `.daikin-rate-limit.json`.

The Assistant (the web UI's chat, MCP clients) can check the login, list the units, read the quota, test the
connection and show this host's addresses for the callback; signing out (`DaikinCloud_revoke`) asks first. It never
logs in: the secret, the password and the one-time code are entered on the page.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `authMode` | string | `developer_portal` | `developer_portal` or `mobile_app` |
| `daikinEmail` | string | - | Daikin account email (Mobile App; `email` is accepted, with a warning) |
| `daikinPassword` | string | - | Daikin account password (Mobile App; `password` is accepted, with a warning) |
| `clientId` | string | - | Developer Portal app's Client ID |
| `clientSecret` | string | - | Developer Portal app's Client Secret |
| `callbackServerExternalAddress` | string | - | The address your browser reaches this machine at, for the OAuth redirect (the page suggests it) |
| `callbackServerPort` | number | `8582` | Port of the OAuth callback server (1-65535) |
| `oidcCallbackServerBindAddr` | string | `0.0.0.0` | Interface the callback server listens on; `127.0.0.1` only when the browser runs on this machine (the page refuses a loopback bind with a LAN address) |
| `updateIntervalInMinutes` | number | `15` | Polling interval, 1-60 (Developer Portal: 15+, Mobile App: 1-5), stretched as above |
| `forceUpdateDelay` | number | `60000` | Milliseconds (5000-300000) before the poll after a change from HomeKit |
| `enableWebSocket` | boolean | `true` | Real-time updates (Mobile App only) |
| `httpTransport` | string | `node` | `node` (the built-in client) or `curl` (the curl binary, for networks whose firewall drops the built-in client's TLS fingerprint). `DAIKIN_HTTP_TRANSPORT` overrides it |
| `excludedDevicesByDeviceId` | string[] | `[]` | Daikin device ids to keep out of HomeKit (the log and the page show them) |
| `showExtraFeatures` | boolean | `false` | Default of every switch below marked *follows* |
| `showPowerfulMode` | boolean | follows | Powerful mode switch (climate control and hot water tank) |
| `showEconoMode` | boolean | follows | Econo mode switch |
| `showStreamerMode` | boolean | follows | Streamer mode switch |
| `showOutdoorSilentMode` | boolean | follows | Outdoor silent mode switch |
| `showIndoorSilentMode` | boolean | follows | Indoor silent (quiet fan) switch |
| `showAutoFanMode` | boolean | follows | Auto fan speed switch |
| `showOscillationSwitch` | boolean | follows | Swing as its own switch |
| `showDryMode` | boolean | follows | Dry mode switch |
| `showFanOnlyMode` | boolean | follows | Fan only switch |
| `showHolidayMode` | boolean | follows | Holiday (away) mode switch |
| `showSeparateFanControl` | boolean | `false` | A standalone Fan tile with fan speed and oscillation |
| `showFirmwareUpdateSwitch` | boolean | `false` | A switch that installs staged gateway firmware updates |

The environment variables of the Homebridge plugin work too: `DAIKIN_HTTP_TRANSPORT`, `DAIKIN_USER_AGENT`,
`DAIKIN_WEBSOCKET_URL` and the Mobile App client's `DAIKIN_API_KEY`, `DAIKIN_CLIENT_ID`, `DAIKIN_CLIENT_SECRET`,
`DAIKIN_REDIRECT_URI`, `DAIKIN_GIGYA_BASE_URL`, `DAIKIN_IDP_TOKEN_ENDPOINT`, `DAIKIN_SCOPE`.

## What differs from Homebridge

- **Test connection** on the Authentication tab refreshes an expired token first, through the running instance;
  the Homebridge page sent the saved token as it was and reported "Token expired or invalid" once it had expired.
- No restart after logging in or saving: saving the block on the page reloads the plugin, and a login on the page
  connects an instance that was waiting for it. The Settings tab therefore saves with a Save button instead of on
  every change, since each save is a reload and the first poll of a reload costs a call.
- The page's device list comes from the running instance when it is connected (no API call); otherwise from one
  call, reused for five minutes, as in Homebridge.
- Revoke on the page also disconnects the running instance at once.
- The callback server's certificate is made by the plugin (P-256, the address as subject alternative name), not by
  the `openssl` binary, and is made again for another address or after 300 days.
- The `node` transport is Homeswift's NIO client (BoringSSL); `DAIKIN_TLS_CIPHERS` has no equivalent.
- The Assistant's Explain buttons are the web UI's (`HomeswiftAiKit`); the "Describe your setup" card is the
  runtime's config copilot on the Settings page.
- Accessory ids are `DaikinCloud:<Daikin device id>`; feature switches always carry the management point in their
  subtype (`climateControl:powerful_mode`): there are no cached Homebridge switches to adopt.
- A unit whose operation mode changes whether it has a fixed fan speed has its accessory rebuilt (same aid and
  iids), where Homebridge added or removed RotationSpeed in place.
- The settings page's polling of a Developer Portal login no longer reports success at once when a token file
  already exists (re-authenticating).
- The callback server accepts TLS 1.2 and later only, and refuses a Callback Server Port outside 1–65535 when the
  login starts. The redirect arriving twice (a browser retry, or the URL also pasted) exchanges the code once.
