# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Log Doctor** on the Logs page: Diagnose sends the lines shown to the Assistant, which groups the issues with
  causes and fixes, streamed as it writes (`POST /api/assistant/diagnose`).
- **Daily digest widget** on the Status page: the Assistant's summary of the day, written on demand, streamed, and
  kept for the day in `ai-digest.json` (owner-only); `get_daily_digest` for MCP clients.
- **Assistant settings**: the HomeswiftAiKit block's page tests the connection with the form's settings
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

### Changed

- The Accessories page shows a section per plugin rather than per server (a card's foot still names its
  server), and the Logs page's menu groups the accessories by plugin.
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

### Fixed

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

[Unreleased]: https://github.com/mp-consulting/homeswift/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mp-consulting/homeswift/compare/v0.2.0...v0.3.0
[0.1.0]: https://github.com/mp-consulting/homeswift/releases/tag/v0.1.0
