# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Web UI: an API token set to expire Never was refused ("a token expires after 1 to 3650 days, or never"). In
  Swift, `JSONValue` takes `nil` literals, so `.flatMap { $0.isNull ? nil : $0 }` gave `.null` back rather than
  nil; `JSONValue.nonNull` replaces it everywhere: an MCP request with `"params": null` is no longer refused, a
  UniFi Access door without a name is "Unknown" again, and an eWeLink light reporting no brightness starts at its
  minimum.

## [0.5.1] - 2026-10-24

### Fixed

- Web UI: the Accessories wall fills its row again. 0.5.0 draws each page in a new `<main>`, and the wall's sizing
  watched only the first one, so after the first page the columns stayed at 160 points with a strip at the right.
  A wall is now sized as soon as it is added, before it is first drawn.

## [0.5.0] - 2026-10-24

### Security

- HAP: the mDNS responder answers only senders on the receiving interface's network and multicasts a record at most
  once a second (no reflection off the bridge); request bodies before pair verify are capped at 16 KB; past 16
  connections, those silent for an hour are closed; a data stream's hello frame is bounded.
- Web UI: event streams end when their user signs out, is removed or loses administrator rights; one password or
  code check per address at a time; body limits set from the request head (64 KiB before sign-in); idle connections
  and readers that stop reading are closed; a removed user's chats and preferences go with them; the chat is closed
  and forgotten at sign-out; notification links stay on the bridge; the self-signed certificate carries Name
  Constraints to its own names and addresses.
- MCP: the daily digest no longer carries one-time confirmation codes; browser notifications go only to the
  browsers' push services (FCM, Mozilla, Apple, Windows), at most five devices per user; a dropped stream no longer
  holds its session; the Elgato `probe` action needs the configure scope.
- Logs and the Assistant mask `Authorization`, cookies, session ids, signatures and one-time codes; passwords leave
  URL errors and FFmpeg command lines, an RTSP password holding a raw `@` included.
- Plugins: UniFi Protect's ONVIF and device routes and UniFi Access's status check connect only to an address they
  checked (no loopback, link-local or rebinding); eWeLink goes through the bounded HTTP client and an encrypted
  device stays encrypted; Dolphin never follows an HTTPS to HTTP redirect; Daikin's revoke is no longer undone by a
  refresh under way; LG ThinQ downloads models over http(s) only; plugin file names stay in their directory.
- Container: `PUID`/`PGID` must be numbers, `chown` no longer follows symlinks, files are created owner-only.

### Changed

- Web UI: the Accessories wall fills its row: as many columns of 160 points or more as fit, widened to end where the
  header ends, instead of a strip left empty at the right.
- Web UI: an account menu at the header's right end, your initial on the accent: who is signed in and as what, Your
  account, Appearance, Users and tokens (administrators) and Sign out; Users leaves the header's links, and the
  Assistant's button is its sparkle alone. On a phone the
  tab bar has a column per section, so Logs no longer wraps to a second row.
- Web UI: the scheduled restart is set as a time and the days it runs on (none: every day), or a cron expression
  under Custom (`x-schema-form.type: "schedule"`); the daily backup is "Turn on the daily backup", on while
  `scheduledBackupDisable` is false (`x-schema-form.invert`).
- MCP: turning the server on without a client token makes one and saves it in config.json (`mcp.http.token`)
  instead of not starting; `homeswift mcp --snippets` shows how to connect a client.

### Fixed

- FFmpeg: a process that ignores SIGTERM is killed even when a restart came in between; probes time out after 60 s.
- HTTP, WebSocket and MQTT timeouts no longer run twice (connect, then the answer); IPv6 `Host` headers carry their
  brackets; Digest authentication answers MD5-sess, SHA-256 and `auth-int` challenges.
- A plugin stuck in `start()` or `stop()` no longer blocks the web UI, the MCP server or a restart; its persisted
  stores are saved when it stops; pairings reset by device id when two servers share a name.
- Cron schedules read months and days on the Gregorian calendar whatever the system's calendar is.
- Plugins: UniFi devices back within `DelayDeviceRemoval` keep their HomeKit rooms and automations; Philips Ambilight
  colour writes are no longer dropped after an "off"; one LG model the CDN fails to serve no longer stops discovery;
  Govee stops asking for a verification e-mail every 10 minutes; LG ThinQ1 polls every 60 s by default, as the
  schema says.

- A cron schedule no longer spins a core forever in the day before a clock change: finding the next time stepped
  out of the hour that repeats in autumn back into its first occurrence. A daily backup or a scheduled restart
  set after that hour hit it, and the core stayed busy until the bridge restarted.
- Web UI: over HTTPS the page carries its home screen icon, which iOS could not fetch past a self-signed certificate,
  so Add to Home Screen showed a letter.
- The Synology package includes FFmpeg (ffmpeg-for-homeswift, as the container image): DSM's own FFmpeg 4.1 has no
  libx264, so every HomeKit Secure Video recording of a UniFi Protect camera failed. `videoProcessor` still picks
  another one.

## [0.4.0] - 2026-10-24

### Added

- **Rooms and hidden accessories** (Glass UI's accessory layout): the Accessories page groups by room, hides
  accessories, gives them display names and Quick Controls, kept for the bridge in `accessory-layout.json`;
  **Suggest rooms** shows the Assistant's rooms and names to review and apply. MCP: `get_accessory_layout`,
  `set_accessory_layout`, and `room` on `list_accessories` and `set_accessories`.
- **Quick controls**: favourite accessories by room and the scenes, on the Status page and at `/quick`.
- **Scenes and automations** (Glass UI's scenes): values set together by hand, at a time on chosen days, at
  sunrise or sunset with an offset (Glass UI's solar equation, from a location set on the page), on a
  characteristic change or a cron expression, with time and value conditions; `scenes.json`. Locks, doors and
  alarms are confirmed by a person: the page asks, `run_scene` refuses, automations skip them. MCP: `list_scenes`,
  `run_scene`, `save_scene`; the `scene-builder` prompt saves its scene.
- **Notifications** (Glass UI's notifications): webhook, ntfy, Pushover, Telegram and Web Push (VAPID keys made by
  the bridge, a service worker at `/sw.js`), for homeswift started or stopped, plugin errors, accessories not
  responding, failed automations, the scheduled backup and the Assistant's daily digest, with Glass UI's rate limits and a test per
  channel; `notifications.json`, secrets never shown back. MCP: `send_test_notification`.
- **Users, roles, two-factor authentication and API tokens** in the web UI, after Glass UI's: a **Users** page
  (administrators) lists, adds, edits (name, role, a new password) and removes users; the last administrator
  stays one. A user who is not an administrator sees Status and Accessories and controls accessories; config,
  plugins, the log, pairing codes, restarts and users are refused (403) on every route, and their Assistant chat
  has the read-only tools only. Two-factor authentication (TOTP, RFC 6238: SHA-1, 6 digits, 30 s) from
  **Account**: a QR code and the key for an authenticator app, a first code turns it on, the password turns it off;
  the login then asks for the code, each code works once. API tokens (`hst_…`, `read` or `admin`, optional
  expiry) for scripts as `Authorization: Bearer` on `/api/*`, shown once, kept as SHA-256 hashes in
  `ui-api-tokens.json`. Each user gets 20 Assistant requests a minute (429 past that), counted per user in the
  usage. An existing `ui-users.json` loads with its account as an administrator.
- **Settings in the web UI** (`/settings`), after Glass UI's settings, child bridges, config editor backups,
  restart and backup modules, for administrators: the bridge block as a form, the network and advertiser,
  each server's pairings with Reset pairings, cached accessories with remove and reset; a **Child bridges**
  page with health, restart, stop, start and the setup code of one not yet paired; **Backups**: a download
  of the whole instance (a tar of config.json, HomeKit identities and pairings, caches, plugin files, users),
  kept backups with a daily one (`scheduledBackupDisable`, `scheduledBackupPath`, `scheduledBackupDays`),
  restore from an upload (checked whole, staged, applied as homeswift restarts) and config.json backups
  compared as a diff and restored; the **Audit log** with filters, the web UI's own changes now in it as
  client `web UI`. Accessories with an Eve history get **History** charts.
- **`scheduledRestartCron`** and **`trustProxy`** in the HomeswiftUI block: a restart on a cron schedule, and
  the reverse proxies whose `X-Forwarded-For` and `X-Forwarded-Proto` count.
- **MCP tools** `list_backups`, `create_backup`, `get_audit_log` and `update_bridge_settings`; accessories with
  an Eve history say `"history": true`.
- **Log Doctor** on the Logs page: Diagnose sends the lines shown to the Assistant, which groups the issues with
  causes and fixes, streamed as it writes (`POST /api/assistant/diagnose`).
- **Daily digest widget** on the Status page: the Assistant's summary of the day, written on demand, streamed, and
  kept for the day in `ai-digest.json` (owner-only); `get_daily_digest` for MCP clients.
- **Assistant settings** (Settings › Assistant, and above the HomeswiftAiKit block's form): tests the connection
  (`POST /api/assistant/test`, `test_assistant_connection`), shows today's and this month's usage against the
  budgets, by model and by user (`GET /api/assistant/usage`, `get_assistant_usage`), and edits the budgets.
- **Streamed, cancellable Assistant requests** for pages: explain, ask (new, with the plugin's background),
  diagnose and the digest stream `chunk` events when the body has a `requestId`, and `POST /api/assistant/cancel`
  stops one, as homebridge-ai-kit's plugin routes; `homeswift.ask()` in plugin.js beside `explain()`, which now
  streams too. Glass UI's 20 requests a minute per user apply.
- **Chat history**: the chat's conversations are kept per user in `ui-chats.json` (owner-only), the open one and
  the ten before it; New chat files one away and Earlier chats opens it again. Cmd+K (Ctrl+K) opens the chat.
- **Appearance** (`/appearance`, from Account): light, dark or automatic theme, a wallpaper (five of the UI's or
  an image of your own) and °C or °F for temperatures on accessory cards and plugin pages, saved per user in
  `ui-preferences.json`.
- **Status page widgets**: Customise shows, hides and orders the overview, digest, activity, bridges and system,
  saved per user.
- **Installable web app**: a manifest, PNG icons and an apple-touch-icon, so the UI goes on a phone's home screen.
- **Log download and emptying** on the Logs page: the range shown or the whole log as a file
  (`GET /api/logs/download`), and Empty the log (`POST /api/logs/truncate`, `truncate_logs` for admin MCP clients).

- **Plugin backgrounds for the Assistant**: `HomeswiftPlugin.assistantBackground`, the troubleshooting notes
  each Homebridge plugin sent with its Assistant requests (`*_AI_CONTEXT`), goes with every Explain from a
  plugin's page and with `context.assistant`.
- **Describe your setup** on a plugin's settings form: the Assistant writes the block from a sentence and the
  plugin's `config.schema.json`, shown as a diff to use and save (`POST /api/assistant/config`), as each
  Homebridge plugin's page offered.
- **Schema conditions** in the settings form: fields with a `condition` (`functionBody` or an expression) show
  only when it holds, per list entry too, read without running the schema's code.
- **Assistant usage on disk, and budgets**: requests, tokens and cost per model, per local day and month and
  per user, kept in `ai-usage.json` (owner-only); `budget` in the HomeswiftAiKit block (`dailyTokens`,
  `monthlyTokens`, `dailyUsd`, `monthlyUsd`, homebridge-ai-kit's names) refuses requests with
  `BudgetExceededError` once one is used up. `UsageTracker.report()` gives today, this month, the budgets, by
  model and by user; `homeswift usage` prints it.
- **`SlidingWindowRateLimiter`**, homebridge-ai-kit's per-key limiter (Glass UI's 20 Assistant requests a minute
  per user), for the web UI.
- **Assistant connection test**: `AssistantService.testConnection(block:)` checks a block's provider, key and
  model with a one-word request and reports the latency and model, or the error; `homeswift test-ai`.
- **Daily digest**: `AssistantService.dailyDigest` summarises a day from log lines, accessory states and events;
  `homeswift digest` feeds it the log on disk and the cached accessories.
- **Organiser**: `AssistantService.suggestOrganization` suggests rooms, clearer names and orphans as
  schema-checked JSON, in batches, with aliased ids; `homeswift organize` runs it on the cached accessories.
- **Accessory widgets** on the Accessories page (`widgets.js`): each accessory drawn by the widget of its kind,
  from its primary service, on a wall of square units packed with no gaps, in a size chosen per accessory:
  small (1×1, a tile a tap acts on), medium (2×1, its main control) or large (2×2). Climate (a gauge with the
  band to the target, setpoints, modes, fan speed as bars), air purifier, fan, light (brightness, colour
  swatches, white temperature in kelvin), shutter, gate, lock, alarm (opening, unlocking and disarming are
  held, closing and locking a tap), valve (a run button counting down), switch groups, switches, sensors,
  television and cameras. A widget's menu sets its size or its kind's ("Medium for every light") and opens
  **All controls**, a sheet with every control: linked services as chips, readouts, meters and blocks, the
  rest under More. **Edit** sets sizes and drags widgets into place; the page shows one wall, or a wall per
  plugin. The bridge keeps the layout (`ui-layout.json`, `GET` and `PUT /api/layout`), the same for every user.
  Changes show at once and are put back with the reason when the device refuses. Plugin pages can use them:
  `HomeswiftWidgets.card(accessory, { size })`, `.open(accessory)` and `.listen()`.
- **Adaptive Lighting from the web UI**: a light's sun swatch turns it off, or on again by resuming the last schedule
  the Home app sent, moved by whole days (`AdaptiveLightingController.resumeAdaptiveLighting()`; the controller
  keeps that schedule, saved with its state). `PUT /api/accessories/<id>/adaptive-lighting`; lights with it say so
  in `/api/accessories`. The Elgato Key Lights and Philips Ambilight TV plugins now have Adaptive Lighting, which
  stops when the light is set elsewhere (the Control Center app, Ambilight following video again).
- **Update notices**: the Status page says when GitHub has a newer Homeswift, with its notes and how to upgrade
  this install (the NAS's `.spk`, the image tag, `brew upgrade`, the tag to check out). The bridge asks a minute
  after it starts, then twice a day (`ReleaseWatcher`); `"checkForUpdates": false` in the `HomeswiftUI` block
  turns it off. The Synology package and the container image say what they are (`HOMESWIFT_INSTALL`).
- The Synology install wizard asks for HTTPS or HTTP for the web UI, and DSM's link follows it.
- **Paused plugins on the Accessories page**: their accessories are drawn striped, "Paused · *plugin*", their
  controls out of reach, with **Resume** in their menu; `/api/accessories` marks them `paused`.
- A shutter's small tile slides to a position (a finger holds it a moment first, so a swipe still scrolls), and
  Edit drags widgets for real: the widget lifts and follows the pointer or finger, the others make room, the page
  scrolls near its edges.
- [docs/widgets.md](docs/widgets.md): the widgets, sizes and wall, with screenshots, and what a plugin does to get
  good widgets (examples in Swift and for a plugin's own page, `HomeswiftWidgets.register` and `.controls`). The
  README shows the web UI.

- **The Assistant's chat** in the web UI: a sparkle button in the header, on every page, opens a chat where
  the Assistant answers and acts through the MCP server's tools, plugin actions included. Each change shows
  a card with a dry run's list of what would change and waits for Allow; writes go to the MCP audit log.
  Streaming answers, tool steps as they run, a panel beside the page or a sheet on a phone, the Apple
  Intelligence glow while it works. The mic dictates (tap, or hold to talk) and answers to spoken messages
  are read out.
- **Plugin actions for the Assistant**: `HomeswiftPlugin.assistantActions` describes routes of a plugin's web
  API as tools (`<platform>_<name>`). Philips Ambilight TV: list, find and pair TVs, wake one, press a key;
  Elgato Key Lights: list lights, check an address, flash one.
- **`put_list_entry`**, an MCP tool that adds or replaces one entry of a block's list (`devices`, keyed by
  MAC), keeping the entry's secrets through a rename.
- **Secrets as handles**: an MCP session's `SecretVault` turns secrets in tool answers into `__SECRET_n__`
  handles and back in arguments, so a model can store a pairing's password without reading it.
- **HTTPS for the web UI** (`"https": true` in the HomeswiftUI block): with a configured certificate or a
  self-signed one the bridge makes and renews (this machine's names and addresses, a CA a phone can trust,
  downloadable at `/homeswift-ui.crt`); the session cookie carries `Secure`, the banner prints the
  fingerprint. Browsers need it for the microphone away from localhost.
- **The log on disk**, rotated (8 MB segments, a new one each day, 64 MB and 7 days kept, batched writes):
  the Logs page filters by time (the last hour, today, yesterday, a custom range…) and by accessory, and each
  accessory card's menu opens its log.
- Accessory cards have a menu of actions (identify, show the log, ask the Assistant, plugin settings).
- Settings pages show the form first and the block as JSON on demand; the Config page and the JSON views
  colour JSON as it is typed; certificate and key fields take a dropped PEM file; the HomeswiftAiKit block
  (the Assistant, the MCP server) has a form. The Logs page copies the lines shown. Selects look like the
  platform's pop-up buttons.
- The voice language of the Assistant's chat can be chosen.
- **Pause a plugin** (`"_paused": true` in its block, from its card's menu or its page): it stops calling its
  devices and their cloud, so an iOS app sharing the account is not signed out; its accessories stay in HomeKit
  answering No Response (`Accessory.isUnavailable`) until it resumes.
- Plugin cards have a menu at their bottom right (its page, Expert form or JSON, pause, remove) in place of
  their buttons.
- The Logs page can keep only the bridges' own lines (connections, pairings, controllers), every bridge's or one's
  (`?bridge=all` or `?bridge=<slug>`). Search fields have a grey fill and a magnifier, so they read on a white card.
- **Addresses are paths with readable names**: `/plugins/dyson-pure-cool`, `/plugins/dyson-pure-cool/expert/json`,
  `/logs/desk-lamp?since=24h&level=warning&q=text`; Back and Forward work, and the Logs view keeps its choices
  in its address. The `#…` addresses and `/plugins/<platform>/index.html?name=` are gone.
- A plugin's own page is its settings page: the Plugins list and accessory menus open it, and the block as a
  form or as JSON is its **Expert** part.
- **Add** on a plugin with its own page writes an empty block and opens the page; the Philips TV page opens
  its pairing wizard from an **Add a TV** button, and on its own while there is no TV.

- **Philips Ambilight TV** (`Plugins/PhilipsAmbilightTV`), a port of `homebridge-philips-ambilight-tv` with the
  same configuration: power with Wake-on-LAN, inputs (tuner, Home, HDMI, discovered or configured apps) with
  stable identifiers, the remote, volume and mute, Ambilight as a colour light, source switches, custom
  buttons, state sensors, the Ambilight+hue switch, the TV's `notifychange` push channel with polling as the
  fallback, selections parked while the TV wakes, the TV's certificate pinned (configured, or on first use). Its web page finds and pairs TVs and writes the entry into
  the configuration.
- **External accessories**: `PluginContext.publishExternal(_:)` puts an accessory on a HAP server of its own
  (its identity in `external/`, the main bridge's setup code), as Homebridge publishes televisions and
  cameras; the cache brings it back before the plugin starts, the banner, status page and MCP status list it.
- **Linked services**: `Service.linked` (`linked` in the accessory database), which televisions need for
  their inputs and speaker; `HAPServer.replace(primary:)` swaps a standalone accessory under its identity.
- **`HomeswiftNetwork`**, for plugins that reach devices on the LAN: an HTTP client on NIO and NIOSSL that
  trusts or pins a self-signed certificate (the same on macOS and Linux, where URLSession cannot), HTTP Digest
  authentication, Wake-on-LAN with the directed broadcast of the device's network, the MAC address of a LAN
  host from the system's ARP table.

- **Eight more Homebridge plugins**, each with the Homebridge plugin's platform name, config.json keys,
  `config.schema.json` and settings page (`Plugins/<Name>/Web`):
  - **Daikin Cloud**: the Onecta Developer Portal OAuth flow (a temporary HTTPS callback server) and the
    mobile-app login, rate limits, the WebSocket push; air conditioners and Altherma with the hot water tank.
  - **Dolphin Pool Cleaner**: the Maytronics sign-in (Cognito, with the e-mail/SMS/app code wizard), the
    robot's AWS IoT shadow over a SigV4-signed WebSocket.
  - **Dyson Pure Cool**: the Dyson account sign-in with its e-mailed code, mDNS discovery, the local MQTT
    protocol for 24 models (purifiers, heaters, humidifiers). Sensor readings are asked for on every poll:
    Link models send none otherwise, a bug the Homebridge plugin has.
  - **eWeLink**: the cloud API and WebSocket, LAN control (mDNS, AES-128-CBC, the UDP listener), every
    accessory type and simulation, 121 device UIIDs.
  - **Govee**: the account and AWS IoT (the account's PKCS#12 certificate), LAN control over UDP, Bluetooth
    on macOS, scenes, DIY effects and music mode, Adaptive Lighting, Eve history.
  - **LG ThinQ**: the ThinQ v1 and v2 APIs with both sign-ins, AWS IoT with a certificate from a CSR made in
    Swift, every appliance type (air conditioners to ovens), the monitor protocols.
  - **UniFi Access**: hubs, readers, intercoms and the UA Gate's gate cycle, door sensors, doorbells, access
    methods, feature options, MQTT, controller discovery.
  - **UniFi Protect**: cameras with live streaming, snapshots and HomeKit Secure Video through the
    livestream API and a timeshift buffer, doorbells, package cameras, chimes, lights, sensors, viewers,
    liveviews as security systems, feature options, MQTT.
- **Cameras** in the HAP library, after HAP-NodeJS's `CameraController`: RTP stream management with SRTP,
  snapshots over `/resource`, microphone and speaker, the doorbell, HomeKit Secure Video (recording
  management, the HomeKit Data Stream server, fragmented MP4 over `dataSend`). **`HomeswiftFFmpeg`** ports the
  FFmpeg library of homebridge-unifi-protect (encoder arguments per hardware accelerator, RTP ports and
  demuxing, live streams and recordings).
- **`AdaptiveLightingController`** after HAP-NodeJS's, automatic and manual, its schedule kept across launches
  through `PluginContext.configureController`.
- **`HomeswiftNetwork`** gains a WebSocket client, an MQTT 3.1.1 client (TCP, TLS with client certificates
  and ALPN, WebSocket), AWS Signature V4, `URLEncoding`, `Backoff`, `UDPSocket`, `TrustOnFirstUse` and
  shared TLS options; **`HomeswiftPlugin`** gains `EveHistory` (fakegato-history's byte layouts),
  `PersistedDictionary`, `TaskBag`, `LatestCallGuard`, `context.jsonFile` and
  `context.removeAccessories(keeping:)`; `HomeswiftNetworkTestSupport` has fake MQTT and WebSocket
  connections for plugin tests.
- **Security controls from plugins**: `Characteristic.isSecurityControl` (`.securityControl()`) puts a
  characteristic that unlocks, opens or disarms (a switch that unlocks a door) under the rules of locks: MCP
  writes it only through `set_security_accessory`, the web UI asks first (locks, doors and alarms too).
- **Confidential values**: `Characteristic.isConfidential`, on by default for Setup Endpoints (SRTP keys),
  Setup Data Stream Transport and Setup Transfer Transport, keeps a value for HomeKit only: MCP, the web UI,
  the accessory cache and the `HAP_DEBUG` trace never show it.
- **`Int(saturating:)`** (and `JSONValue.saturatingIntValue`, `.finite`) for numbers from devices, clouds and
  config files: no trap on NaN, infinity or out-of-range values. The HAP core, the HomeKit Data Stream
  decoder (also capped in depth), Adaptive Lighting and the Eve history no longer trap on hostile numbers.
- The `homeswift` binary embeds an Info.plist on macOS with `NSBluetoothAlwaysUsageDescription`, so the Govee
  plugin's Bluetooth works.
- The Daikin Cloud page's connection test refreshes an expired token first, as the plugin's own calls do.
- The Govee plugin turns Bluetooth off, with a warning naming the app, when macOS holds an app without a
  Bluetooth usage description responsible for homeswift (started from that app's shell); macOS aborted the
  whole bridge at the first Bluetooth call.
- **Govee Bluetooth on Linux**, as noble reached it for the Homebridge plugin: a raw HCI socket on `hci0` (or
  `NOBLE_HCI_DEVICE_ID`) scans for the thermo-hygrometers' advertisements, and commands go over the kernel's
  L2CAP socket on the ATT channel (characteristic discovery, write commands). Devices and readings are matched
  by MAC address there, as upstream; macOS keeps matching by advertised name, since CoreBluetooth hides MACs.
- The Govee plugin imports the Homebridge plugin's kept login (`govee_cache` and `persist/govee.pfx` of
  `homebridgeStoragePath`, else `~/.homebridge`) once, at a first start of the same account, so Govee does not
  email a verification code again.
- The Govee plugin logs `devNotRef` for a sensor whose data cannot be read, `storageWriteErr` when a
  thermo-hygrometer's temperature cannot be saved, and AWS IoT's `error event` when the connection drops, as
  the Homebridge plugin does; it gives the Assistant its background (`assistantBackground`).
- **Camera cards** on the Accessories page: a 16:9 live video with the camera's name, motion, the doorbell's
  last ring and HomeKit Secure Video recording over it, mute, refresh and full screen buttons, and the camera's
  own controls (its light, switches, whether it is on in the Home app) under it. The video plays muted through
  Media Source Extensions (ManagedMediaSource on iOS Safari) only while the card is on screen and the page is
  visible; a camera without a live feed, or a browser that cannot play it, shows a snapshot every 3 seconds.
  The UniFi Protect page shows the same view for the camera whose feature options are open.
- **`HomeswiftPlugin.liveFeed(accessoryID:)`** hands the web UI a camera's live video as a `CameraLiveFeed`
  (the MSE type, the fMP4 initialization segment, the fragments, cancellation); `CameraLiveFeed.mimeType(initSegment:)`
  names the codecs from the avcC, hvcC and esds boxes. UniFi Protect serves it from the livestream API on the
  camera's lowest-resolution channel, sharing the session with HomeKit's streams and recordings.
- **`GET /api/cameras/<id>/snapshot`** and **`/live`** in the web UI, for signed-in users: a JPEG, and a chunked
  `video/mp4` stream (`X-Camera-Mime-Type` carries its codecs) that stops when the browser disconnects, four
  viewers per camera at most. Both refuse while the camera is off in the Home app.
- **Activity on the Status page**: charts of the process's memory and CPU, of how long the bridge takes to answer
  the Home app's reads and writes, and of how long plugins take to reach their devices (average and longest),
  with the Logs page's time range and bridge or accessory menu, a crosshair and tooltip, and a table view. A
  record per minute is kept for 8 days under `metrics/` (`Metrics`, `GET /api/metrics`).
- **Log payloads**: JSON of 160 bytes or more in a log line becomes a marker (`{…} 1.4 KB`) in the terminal and
  the web UI, and the line's details: its **JSON** button on the Logs page shows them formatted, secrets
  masked (`LogDetails`). **Save payloads** on the Logs page writes them to the log on disk as well (off by
  default, kept in `logs/settings.json`). The Assistant's `get_recent_logs` and `search_logs` take
  `details: true`; `search_logs` looks inside payloads and, with `hours`, back through the log on disk.
- **`HAPServer.observeTimings`** and **`PluginHost.observeTimings`**: how long each controller request to
  `/characteristics` and each accessory read or write handler took, with the accessories it was about.
- **MCP: child bridges**: `list_child_bridges`, `get_child_bridge_health` (status, uptime, restarts, plugins
  that did not start), `restart_child_bridge`, `stop_child_bridge` and `start_child_bridge`, and the
  `homeswift://child-bridge/{id}` resource; `PluginHost.stopChildBridge`, `startChildBridge`, `restartChildBridge`.
- **MCP: accessory caches**: `get_cached_accessories` (with what its plugin has not added again, and the files of
  blocks no longer configured), `remove_cached_accessory` and `reset_cached_accessories`, which starts the plugins
  again on empty caches; `PluginHost.cachedAccessories`, `removeCachedAccessory`, `resetCachedAccessories`.
- **MCP: pairings**: `get_pairing_info` (paired or not and how many controllers, per bridge, child bridge and
  external accessory; never the setup code or URI) and `reset_pairings`, which calls `HAPServer.resetPairings`.
- **MCP: `get_accessory_history`**: the Eve history a plugin keeps for an accessory, per characteristic min, max,
  time-weighted average, last value and averaged points (`EveHistory.histories(of:)`, `entries(since:)`).
- **MCP: `search_logs` filters**: `since`/`until` (ISO or `1h`, `2d`; the archive on disk), minimum `level`,
  `plugin`, `caseSensitive`, `context` lines, and a 5-second limit on regular expressions; `pattern` is optional
  when a filter is given.
- **MCP: accessory filters**: `list_accessories` by `type`, `name`, `manufacturer` and `excludeManufacturer`, and
  `set_accessories` with one characteristic on the accessories `ids` or `filter` pick, refused beyond
  `maxTargets` (25). There is no `room` filter: HomeKit keeps the rooms.
- **MCP: `get_system_info`** adds the load average, the process's CPU and memory, and each network interface's
  throughput.
- **MCP: `outputSchema`** on the tools with structured answers (for clients on protocol 2025-06-18), and the
  `scene-builder` prompt, which has the user save the scene in the Home app.
- **MCP sessions**: at most `maxSessions` (32), the least recently used idle one making room, and
  `sessionIdleMinutes` (30); `homebridge-ai-kit`'s environment variables (`HOMEBRIDGE_AI_MCP_MAX_SESSIONS`,
  `…_SESSION_IDLE_MINUTES`, `HOMEBRIDGE_READ_ONLY`, `HOMEBRIDGE_AI_MCP_TOKENS`, `…_ALLOWED_ORIGINS`,
  `HOMEBRIDGE_AI_AUDIT_LOG`) and their `HOMESWIFT_` names override the block.
- **MQTT 5** in `HomeswiftNetwork`'s `MQTTClient` (`protocolVersion: .v5`, 3.1.1 stays the default): properties in
  CONNECT, CONNACK, PUBLISH, SUBSCRIBE and the acknowledgements, reason codes for refused connections,
  subscriptions and publishes (`MQTTError.publishRefused`), the broker's DISCONNECT (`disconnectedByBroker`) and
  its Server Keep Alive.
- **Cipher suites** for `HTTPClient` and `TLSOptions` (`cipherSuites`, an OpenSSL cipher list such as `DEFAULT`).
- **`MDNSQuery`**: one-shot mDNS queries answered by unicast, with the address of each responder (which dns_sd
  does not give).
- Dyson Pure Cool: the CONNECT ladder's MQTT 5 step is tried as in Homebridge.
- Dyson Pure Cool: a device whose mDNS records carry no local IPv4 address is reached at the private address that
  answered for it, as the Homebridge plugin's `referer` fallback.
- Daikin Cloud: `DAIKIN_TLS_CIPHERS`, and the built-in client and the WebSocket offer the `DEFAULT` cipher list as
  the Homebridge plugin does.
- eWeLink: the page's `GET accessories` request (the instance's accessories and their kept values), and the page
  fills its settings in again when the block changed elsewhere (Homebridge's `configChanged`).
- Dyson Pure Cool, Daikin Cloud and eWeLink give the Assistant their Homebridge background
  (`assistantBackground`), with Homeswift's files and the errors the ports log.
- **Contributing plugins:** `CONTRIBUTING.md` (proposing a plugin, what it needs), a plugin proposal issue form and
  a pull request template; `Scripts/new-plugin.swift` creates a plugin that builds and passes its tests and
  registers it, its device state, changes, write handlers and tests typed from the HAP services and
  characteristics given with `--service` (`--list` shows them); the `homeswift-plugin` skill for Claude Code and Codex ports a Homebridge plugin and checks it on a
  throwaway bridge over MCP; `AGENTS.md` for other coding agents.
- **THIRD-PARTY-NOTICES.md**: the copyright and permission notices of the projects Homeswift ports (HJD's UniFi
  plugins and homebridge-plugin-utils under ISC; the Elgato, Govee, eWeLink and Dyson plugins and noble under MIT;
  the LG ThinQ and Daikin Cloud plugins and HAP-NodeJS under Apache-2.0, in `LICENSES/Apache-2.0.txt`),
  with the parts of the repository each one became; every ported plugin's README names its original author.
  The container image (`/usr/share/doc/homeswift`) and the Synology package (`share/doc/homeswift`) carry it, with
  the licence and notice files of the Swift packages compiled in and, in the package, of the bundled Avahi and D-Bus
  libraries.

### Changed

- Dyson Pure Cool climbs the CONNECT ladder only on the refusals the Homebridge plugin does (identifier rejected,
  protocol version, user name or password, not authorized), not on "server unavailable".
- Daikin Cloud's page tells the Assistant the default transport is Homeswift's built-in HTTP client, not "node".
- The Dyson Pure Cool README says how `discoveryTimeout` is read (seconds up to 60, milliseconds above).
- **A container image**, `ghcr.io/mp-consulting/homeswift`, for `linux/amd64` and `linux/arm64`, pushed for each
  release tag: the bridge linked with the Swift runtime, Avahi (its own daemon, or the host's through a
  mounted D-Bus socket), FFmpeg, a `config.json` with the web UI on the first run, the bridge running as
  `PUID:PGID`. `docker-compose.yml` and [docs/synology.md](docs/synology.md) set it up on a Synology NAS
  with Container Manager.
- **A Synology package** (`homeswift-<arch>-<version>.spk`, x86_64 and aarch64, DSM 7.0 or later), Homeswift's
  homebridge-syno-spk: no Docker, a `homeswift` shared folder for the data, the bridge as a systemd unit of
  the package's own user, Homeswift in DSM's main menu, firewall entries for its ports. The install wizard
  creates the web UI's administrator account (a weak password is refused before anything is installed) in
  place of a default login. Over SSH, `sudo homeswift` runs any command on the package's data and adds
  `start`, `stop`, `restart` and `status`. `Synology/build.sh` builds it with Docker, without Synology's
  toolchain: the binary comes from Amazon Linux 2, whose glibc is DSM 7.0's; `.github/workflows/synology.yml`
  attaches both packages to each release.
- **A built-in mDNS responder**, HAP-NodeJS's ciao in Swift: probing, conflict renaming (`Homeswift (2)`),
  announcements, known-answer suppression, legacy unicast answers and goodbyes, on each IPv4 interface with
  its own addresses, under a host name of its own. The bridge falls back to it when dns_sd fails (Avahi not
  running or out of reach, as on a NAS), and uses it with `"advertiser": "ciao"` in the bridge block;
  `"bind"` keeps it to some interfaces, as in Homebridge.
- **`homeswift users`** lists the web UI's accounts, adds one and sets a forgotten password, reading
  passwords from standard input; **`homeswift logs [-n <lines>] [-f]`** prints the log on disk in the
  console's format and follows it.
- **Faster web UI and MCP server.** `JSONValue` writes and parses its JSON itself instead of through
  `JSONEncoder`/`JSONDecoder` (the same bytes, 7–30× faster), redaction skips the expressions a line cannot
  match, the log buffer is a ring and the archive's lines skip the Codable coders, and static files answer 304
  to a reload. `get_recent_logs` went from 89 to 3 ms, `/api/logs` from 17 to 4.5 ms, `/api/accessories` from
  10.7 to 2.9 ms. Adding accessories no longer costs N² (a bridge with 300 took over a minute to start): the
  accessory cache is saved once per burst, and an accessory that replaces one of the same shape is not followed
  by a rehash of the whole database. `Benchmarks/bridge-bench.py` times every endpoint of a whole bridge.

- The Accessories page shows a section per plugin rather than per server (a card's foot still names its
  server), and the Logs page's menu groups the accessories by plugin.
- The Logs page's Warnings and Errors buttons show those levels alone; Warnings no longer shows errors.
- A time range of the log loads several times faster: JSON strings full of escapes decode their plain runs at once
  (`JSONValue`), and the log on disk skips rows outside the range, or that cannot be about the chosen accessory or
  bridge, before parsing them (`LogArchive.lines(mayMatch:)`, `TextSearch.containsAny(_:asciiCaseless:)`). Six hours
  of one accessory went from 25 s to about 1 s on a debug build.
- The web UI shows a spinner, not "Loading…", while a page or a log range loads; the Status page's table groups its
  columns under homeswift, Home app requests and plugin device calls.
- A paused plugin's pill has a colour of its own, and its card's ⋯ button keeps its size beside the paused note.

- The accessory JSON (web UI, MCP) marks what only HomeKit uses as `"internal": true`: a camera's RTP stream,
  recording and data stream services, and the operating mode's snapshot settings. TLV8 and data values are
  null there with their size in `bytes`, and left out of `list_accessories`. The web UI leaves them off its
  cards, whose value cells now wrap, so a camera's stream configurations no longer push the page sideways.

- `Service(optional:)` and `Service(extra:)` with a characteristic the service already has replace it in
  place, so they set a required characteristic's props as HAP-NodeJS's `setProps` does (they used to be
  ignored).
- `OwnerOnlyFile.write` creates its temporary file 0600 from the start: no moment at umask permissions.
- `Redaction.scrubAddresses` also masks e-mail addresses before text reaches a provider.
- Signing in is quick in debug builds too: PBKDF2 runs on CommonCrypto on Apple platforms, and the button
  shows its progress.
- MCP sessions refuse a `__SECRET_…__` handle that is not under a secret's key or not their own, so a model
  cannot move a secret into a field that would show it.
- `get_config` gives secrets as session handles instead of `__REDACTED__`, so a rename keeps them. Every MCP
  client's confirmation now lists what a change would do (from a dry run), and a change that would fail is
  answered without a question. A step's read-only tool calls run at the same time in the chat. The Logs
  page's accessory filter runs on the server, before the line limit.

- **No restart to apply configuration.** `PluginHost.apply(_:)` applies a new config.json in place: a changed
  platform block gets a fresh plugin on the same accessories (aids, iids and pairings kept), a new block
  starts, a removed one leaves HomeKit, child bridges start and stop, the Assistant swaps. Saving from the
  web UI or the MCP tools applies at once; a changed `HomeswiftUI` or MCP block restarts that server inside
  the process, and only the `bridge` block (identity, port, setup code) restarts homeswift, by itself.
- The web UI's Status page: a summary that says whether everything is in the Home app, the numbers that
  matter, a card per bridge or accessory server with its setup code while unpaired, and the machine.
- The Philips Ambilight TV page has what the Homebridge plugin's settings page has: a card per TV with a
  remote; pairing in three steps (find, a box per PIN digit, confirm with the remote keys and automations),
  waking a known TV that does not answer; the inputs editor (drag and drop, hide, rename); an editor with
  General, Remote, Automations, Apps (**Detect from TV**) and Buttons; pairing again; removing a TV.
- The Elgato Key Lights page has the Homebridge plugin's settings: per light, in or out of HomeKit, its name
  and power-on behaviour, a connection test; adding a light by address (its MAC read from the light, or the
  ARP table); disabled lights listed.
- Every page of the web UI: a page head with tools, Home-app-like accessory cards (power in the header,
  readable controls, an input picker and remote for televisions, search), plugin cards with a catalog to
  add from and settings forms with switches, a config editor that checks JSON as you type (⌘S saves), and a
  log with level filters, search and a row per line. The header stays on one line on a phone.
- Plugin pages carry the UI's whole header and a breadcrumb (Plugins › the plugin › what is open on the page).
- A mini remote for televisions, after the Control Center remote (a round pad, round keys, a volume rocker),
  on the Philips TV page and on TV accessories in the Accessories page; keys on the keyboard too.
- The HomeswiftUI block has a settings form; a new port moves the page there.
- Each plugin's settings have a page of their own (`#settings/<platform>/<name>`): the form, a save bar that
  stays in view, a link to the plugin's page, Remove; leaving with unsaved changes asks first.
- **Account** (the user name in the header): change the password. The current one is checked (slowed down
  after mistakes, like a login), and the user's other sessions are signed out.
- **Passwords after the ANSSI** (guide PG-078: R21, R22, R23, R27): at least 12 characters and 85 bits, the
  guide's "moyen à fort" level, checked by the server for the first account and every change
  (`PasswordPolicy`); repeats, runs, common words and the username earn nothing. A gauge shows the guide's
  bands while typing.
- `HOMESWIFT_WEB_ROOT` serves the web pages from a checkout and reloads open pages when a file changes
  (a stylesheet in place), for working on them without a rebuild.
- The Assistant's answers look like Apple Intelligence: a sparkle button, a glow turning around the card while
  it thinks, then the answer typeset from its Markdown (never as HTML) in a card with a rainbow edge, long
  answers folded under "Show more"; an answer survives the page redrawing its card.
- **Explain**: with the Assistant on, plugin pages offer an explanation next to errors, with IP and MAC
  addresses and `.local` names masked before they reach the provider (`Redaction.scrubAddresses`)
  (`POST /api/assistant/explain`; `homeswift.explain` in `plugin.js`).
- `PluginContext.remove(id:)` is async: removing an external accessory stops its server.
- Every accessory a server publishes carries the Protocol Information service; bridges no longer add it themselves.
- Elgato Key Lights: the page lists configured lights that never answered as offline, with why (**Explain**),
  their settings and **Remove**, as the Homebridge plugin's page does.
- Elgato Key Lights: `powerOnTemperature: 0` keeps the light's own power-on colour temperature instead of 7000 K.
- Elgato Key Lights: the page's default brightness starts at 3 %, the light's minimum.
- Elgato Key Lights: `useIP` works as in Homebridge: off, the plugin connects to the light's `.local` host name,
  resolved through the ARP table and then the addresses Bonjour announced; on, to the announced address.
- Elgato Key Lights: **On the network** on the page lists the lights Bonjour announces (the Homebridge
  plugin's **Discover**) and adds one to config.json.
- Elgato Key Lights, Dolphin Pool Cleaner: without an Assistant, the page shows a tip on adding a
  `HomeswiftAiKit` block.
- Elgato Key Lights, Dolphin Pool Cleaner, UniFi Access: an `assistantBackground` after the Homebridge plugins'
  Assistant context, adapted to Homeswift.
- Dolphin Pool Cleaner: the robot's state keeps the legacy `mu_state` and `is_smart` (`muState`, `isSmartMode`).
- UniFi Access: `debugAll` logs the plugin's debug lines at the info level.
- UniFi Access: the Support screen has the Homebridge plugin's other links (about, installation, Discord, a
  support request) and Homeswift's issue tracker.

### Fixed

- MQTT: a broker counts as gone when it leaves a PINGREQ unanswered for an interval, not when nothing came in for two
  intervals, so a keep-alive tick a busy machine runs late no longer drops a healthy connection.
- Metrics: the first memory and CPU sample is taken when recording starts, so the Status page (and
  `MetricsAPITests.servesTheHistory` on a slow CI runner) has a value at once.
- Philips Ambilight TV: the mute and Ambilight state sensors follow a mute or Ambilight switched from HomeKit
  at once, as the Homebridge plugin's do, instead of waiting for a change the TV reports.
- Philips Ambilight TV: source switches only for the inputs shown in the Home app, as the Homebridge plugin
  builds them.
- Philips Ambilight TV: a `pollingInterval` out of 1000 to 60000 falls back to 10000 with a warning, as the
  Homebridge plugin does, instead of leaving the TV out.
- Philips Ambilight TV: standby clears the mute and Ambilight sensors and turns the Ambilight+hue switch off.
- Philips Ambilight TV: Adaptive Lighting on the Ambilight light (`AdaptiveLightingController`, its schedule
  kept across restarts); a schedule changes the colour only while Ambilight shows one.
- Philips Ambilight TV page: **Refresh from TV** in the inputs editor, **Get MAC** on the confirm and edit
  screens (the TV, else the ARP table), and Wake-on-LAN to any MAC address, so a TV being paired can be woken.
- Philips Ambilight TV: pairing errors in the Homebridge plugin's words; a 401 at the grant is a wrong PIN.
- Philips Ambilight TV: the Television service has Current Media State (interrupted), as the Homebridge
  plugin sets it.
- Philips Ambilight TV: `assistantBackground`, the Homebridge plugin's background for the Assistant, for the port.
- UniFi Protect: accessories show Protect's hardware revision (cameras, sensors and the other devices, the
  controller's system information and the liveview security system), as the Homebridge plugin sets it.
- UniFi Protect: with no `playlistAddress`, the M3U playlist listens on IPv6 as well as IPv4 (one dual-stack
  socket, IPv4 alone on hosts without IPv6), as Node's `server.listen(port)` does.
- UniFi Protect: `Debug.Video.HKSV.UseRtsp` works: HomeKit Secure Video's timeshift buffer reads the camera's
  RTSP stream through FFmpeg (`FfmpegLivestreamProcess`, fMP4 without transcoding) instead of the livestream
  API, restarted by the same watchdog; it used to log a warning and change nothing.
- LG ThinQ: `ac_mode` and `ac_swing_mode` are read in any case; the lower-case `both` and `vertical` of the
  Homebridge plugin's documentation were silently ignored.
- LG ThinQ: the settings page has the options of AeroTowers (`air_fast_mode`) and WashTower 2 (the washer's).
- UniFi Protect and LG ThinQ give the Assistant their background (`assistantBackground`): the errors they log,
  their files and the usual fixes, after the Homebridge plugins' `*_AI_CONTEXT`.
- Govee plugs shown as an audio receiver, set-top box or streaming stick are on the bridge, as in Homebridge,
  rather than accessories with a pairing of their own.
- A write the device refuses or never answers reads as a sentence ("Desk Lamp did not answer…", "eWeLink is
  paused: resume it…") in the web UI and to MCP clients, not as `HAPStatusError(…)`.
- Govee: a bridge restart no longer turns Adaptive Lighting off. The light's first colour report after launch was
  compared with an empty cache (0 K) and taken for a colour set elsewhere; it now only fills the cache.
- The Adaptive swatch's ring is no longer cut on its left in a medium light widget.
- The Assistant answered nothing but `HTTP 400` from Claude on a bridge with UniFi Protect or UniFi Access: their
  tools were named after a platform with a space (`UniFi Protect_discover`). A plugin action's tool name now
  keeps letters, digits, `_` and `-` (`UniFi_Protect_discover`).
- On a phone: the chat's field and voice picker are 16px, so Safari no longer zooms into the page, and the
  chat sheet sits on the on-screen keyboard instead of behind it; widget swatches and steps keep their shapes,
  the widgets' menus have a larger target, and All controls rises from the bottom edge.
- A shutter sent to a position from its widget (slid, tapped, its slider or buttons) shows that position until it
  gets there, "Opening…" or "Closing…" meanwhile, instead of jumping back and following each position the device
  reports on its way; stopped on the way, it shows where it stopped.
- A medium switch widget no longer reads "null" under its name: its empty body went to `append()` as `null`.

## [0.3.0] - 2026-10-21

### Added

- **Plugins** (`HomeswiftPlugin`): the `HomeswiftPlugin` protocol and `PluginContext`. `PluginHost` runs the
  plugins of a Homebridge-shaped `config.json` on one bridge, restores each platform's accessories from a
  cache before its plugin starts (aids and iids kept), and runs a block with `_bridge` on its own child
  bridge. `docs/plugins.md` explains how to write one and how to port a Homebridge plugin.
- **`homeswift`**, the bridge: reads `~/.homeswift/config.json` (created on the first run), runs the plugins
  compiled in, prints the setup codes; `-U`, `-D`, `--version` and `homeswift plugins`.
- **Elgato Key Lights** (`Plugins/ElgatoKeyLights`), a port of `@mp-consulting/homebridge-elgato-key-lights`
  with the same configuration: Bonjour discovery and configured lights, power, brightness and colour
  temperature, polling for changes made elsewhere, power-on settings, "No Response" while a light does not
  answer.
- `BonjourBrowser.browse(type:)`: service discovery through dns_sd on macOS and Avahi on Linux, with host,
  port, TXT record and addresses.
- `HAPServer.Options.deviceID` overrides the stored device ID (Homebridge's `username`).
- **The Assistant** (`HomeswiftAI`), a port of `homebridge-ai-kit`'s core: Claude, OpenAI (Responses and
  Chat Completions), Gemini and OpenAI-compatible providers over plain HTTP with retries and streaming,
  Apple's on-device model on macOS 26, secret redaction, prompts, schema-checked JSON with one repair,
  usage and Claude cost tracking. A `HomeswiftAiKit` block in config.json (the keys of homebridge-ai-kit)
  turns it on; plugins get it as `context.assistant`; `homeswift ask`, `explain` and `diagnose` use it from
  the command line, on the on-device model when there is no block. `docs/ai.md`.
- **The MCP server** (`HomeswiftMCP`): Model Context Protocol 2025-06-18 over Streamable HTTP inside the
  bridge, with tools over its accessories (list, get, set, set several with `dryRun`, locks and alarms
  behind a confirmation, identify), plugins, config.json (read with secrets redacted, replace, patch one
  block, backups and restore) and the log (recent, search), resources with subscriptions, prompts and
  completions. Bearer tokens with `read`, `control` and `admin` scopes, confirmations through elicitation
  or `confirmed: true`, an audit log, origin checks, slowed-down bad tokens, idle session expiry.
  `homeswift mcp` is the stdio front for Claude Desktop, Claude Code and Cursor; `--generate-token` and
  `--snippets` set a client up. `docs/mcp.md`.
- `Characteristic.write(_:)` writes a value the way a controller does; `HAPServer.observeChanges(_:)`
  reports every characteristic change; `LogBuffer` keeps the last log lines in memory.
- **The web UI** (`HomeswiftUI`): a `HomeswiftUI` block adds a web interface on port 8581, in the bridge's
  process. Status with pairing codes, accessories with live control (switches, sliders, menus), plugin
  settings as forms built from each plugin's `config.schema.json` (embedded by
  `Scripts/embed-assets.swift`; `HomeswiftPlugin.configurationSchemaJSON`), the raw config.json with
  backups, and the live log. A login created on the first visit with the set-up code the bridge prints
  (PBKDF2 hashes in `ui-users.json`, session cookies, origin and host checks with `allowedHosts`,
  slowed-down failed logins), or `auth: none`. The pages follow the system's light or dark appearance and
  its reduced-motion, reduced-transparency and increased-contrast settings. `docs/ui.md`.
- `get_plugin_config_schema` MCP tool; `list_plugins` says which plugins have a schema.
- Web UI: a **Restart** button (in the banner and on the Status page) that restarts homeswift in place,
  with logins kept in `ui-sessions.json`; the pairing QR code next to the setup code; plugin pages
  (`HomeswiftPlugin.webFiles` and `handleWebRequest`, served at `/plugins/<platform>/`, with
  `/plugin.js` to talk to the instance), the Elgato Key Lights page being the first. `restart_bridge`
  MCP tool.

### Fixed

- The configuration number no longer moves at every launch: the database was hashed with the bridge alone,
  then again for each accessory restored from the cache, so every restart made controllers download the
  accessories again. It is hashed once, when the bridge starts.

### Changed

- MCP: a destructive tool with a client that cannot ask the user needs a one-time code from the bridge's
  log instead of a self-declared `confirmed: true`; `dryRun` skips the question only for tools that honour
  it; `get_config` returns secrets only to an admin token and never the MCP tokens; log tools mask secrets
  and defuse data tags; `search_logs` matches plain text unless an admin asks for a regex. The log tools
  and notifications hide confirmation codes; three wrong codes lock a call until its code expires, and
  ten wrong codes in five minutes lock every call for that long.

- The config tools and the web UI refuse to edit a config.json they cannot read, instead of writing a new
  file over it; the bridge's state directory is created owner-only like every other file it keeps.

- swift-log 1.11 or later.

- JSON responses (the accessory database, reads, writes, events) are written directly instead of through
  `JSONEncoder`: `GET /accessories` for 100 accessories dropped from about 13 ms to 2.5 ms of server time. The
  configuration number may go up once after updating, and the Home app then reloads the accessories.

### Fixed

- Decrypting a large message copied the rest of the buffer after every 1 KB frame, which made it quadratic.
- `HAPServer` tried the configured port and port 0 in the order of a `Set`, so about every other launch the
  bridge listened on a random port instead of the configured one.

## [0.1.0] - 2026-10-21

### Added

- **HAP server over IP** (`HAPServer`): a single accessory, or a bridge with bridged accessories; SwiftNIO
  listener on IPv6 and IPv4; `start`, `stop` and `run`; accessories added and removed while running.
- **Pairing**: pair setup with SRP-6a (3072-bit group, SHA-512), pair verify with X25519 and Ed25519, and the
  pairings endpoint (add, remove, list; admin only, up to 16 controllers, removing the last admin unpairs).
  Failed setup attempts are counted, and a paired accessory refuses new pair setups.
- **Encrypted sessions**: ChaCha20-Poly1305 frames after pair verify; requests other than pairing and identify
  are refused until then.
- **Model**: `Accessory`, `Service`, `Characteristic` and `HAPValue`; the 73 services and 252 characteristics of
  HAP-NodeJS 2.2.2, generated by `Scripts/generate-definitions.js`, with their constants (`HAPConstants`).
- **Characteristics**: reads (with metadata, permissions and types), writes with value checks, events to
  subscribed controllers, timed writes, write responses, multi-status errors, `onRead`, `onWrite` (with
  `changesOnly`), `sendEvent`, and `HAPStatusError` for device failures.
- **Identify** for unpaired accessories and for each bridged accessory.
- **Storage**: device ID, keys, setup code, pairings, port, configuration number and stable aids and iids, in
  `~/.homeswift/<name>.json` (`FileStorage`) or in memory (`MemoryStorage`).
- **Bonjour**: `_hap._tcp` advertising through dns_sd on macOS and Avahi on Linux.
- **Setup code** (shown as the Home app shows it, `XXXX-XXXX`) and the `X-HM://` setup URI.
- `homeswift-demo`: a bridge with a lamp, a switch and a temperature sensor; `--help`; stops cleanly on
  SIGTERM; Homebrew formula `mp-consulting/tap/homeswift` with a `brew services` entry.
- CI on macOS and Linux for every push and pull request.

[Unreleased]: https://github.com/mp-consulting/homeswift/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/mp-consulting/homeswift/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/mp-consulting/homeswift/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mp-consulting/homeswift/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mp-consulting/homeswift/compare/v0.2.0...v0.3.0
[0.1.0]: https://github.com/mp-consulting/homeswift/releases/tag/v0.1.0
