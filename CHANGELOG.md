# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Rename an accessory, in the Home app too: **Rename** in a widget's ⋯ menu on the Accessories page, and the MCP tool
  `rename_accessory`. The name goes in its plugin's block (`_accessories`, by Device Id) and the bridge puts it on the
  accessory's Name and Configured Name, without reloading the plugin and with its aids and iids, so its room, scenes and
  automations stay. The Home app follows Configured Name; a rename made there is kept in config.json the same way.
- UniFi Access: a UA Gate's side door (its lock, position sensor and trigger) and each door sensor get an accessory of
  their own, with their own tile, by default (`Hub.SideDoor.SeparateAccessory`, `Hub.Sensors.SeparateAccessory`; the
  Homebridge plugin groups them on the hub's, and disabling the options does too).
- Setup, one way to get a device into the bridge whatever its plugin: the web UI's **Add accessories** page (`/setup`)
  lists what each plugin finds and where each device stands, adds plugins, and sets up accounts and devices in one
  sheet (a hub's link button, a TV's PIN, a sign-in with its one-time code, a sign-in page's redirect, developer keys;
  Daikin, LG ThinQ and EcoFlow ask which way to sign in; Dyson, LG ThinQ and eWeLink offer their countries and
  languages in a menu). Plugins to add are cards with a search; the sheet shows where the Setup stands and, for a new
  account, or a UniFi console just signed in, lets you pick the devices that go into the Home app (the others are
  excluded). Removing a plugin offers to delete the vault entries it kept. A device's parts (a UA Gate's side door,
  its door sensors, a doorbell; a Protect camera's occupancy sensor, motion switch, status light switch, doorbell mute
  or package camera flashlight) each have a switch, kept in its Accessory Settings' `parts`. The Accessories page's
  toolbar leads to it. The Assistant sets accessories up too (**Ask the Assistant**): it starts the Setup,
  and a step with a password, a sign-in page or a button to press continues in the Setup sheet from a card in the chat.
  MCP clients get
  `discover_devices`, `start_setup`, `continue_setup`, `cancel_setup`, `set_device_excluded` and `set_device_part`; a secret field takes only a `vault:` reference.
  What an Authorization gives goes in the vault, never config.json. See GLOSSARY.md and docs/plugins.md, "Setup".
- Accessory Settings in a block's `_accessories`, by Device Id: **Exclude** a device from its row (it never becomes an
  accessory, in the Home app or Matter), and plugins' own settings per device. Homebridge-shaped blocks still load
  (docs/adr/0001-canonical-accessory-settings.md).

### Changed

- Every plugin sets up through Setup, and what it pairs or signs in with is kept in the vault: Philips Hue's bridge key
  (`bridge.json` moves there), Philips Ambilight TV's and Wingman's keys (out of `devices`), IKEA DIRIGERA's hub token,
  MyDolphin's, LG ThinQ's refresh tokens, Govee's login and certificate (`credentials.json` and `govee.pfx` move there),
  eWeLink's password, Dyson's local credentials, EcoFlow's developer keys and the UniFi consoles' logins Setup adds;
  Daikin's sign-ins run through it. A block's own secret keys still work, the vault's winning.
- Each plugin lists its devices for Setup and skips an Excluded one, eWeLink's channels and UniFi's child accessories
  with it.

### Fixed

- UniFi Access and Protect: Add accessories leaves out the consoles that do not run the app (asked without signing in,
  they answer with their web page), and signing in to one says so, rather than "Unable to parse response".
- UniFi Access and Protect: Add accessories lists only the UniFi OS consoles (gateways, Cloud Keys, recorders) to
  sign in to, not every access point, chime or hub that answers the discovery probe, and a console with several
  networks once.
- Govee: commands reach lights through the cloud while another bridge (or Homebridge) is signed in to the same
  account. Both used the same AWS IoT client id, so each knocked the other off every second; each run now has its own.
- Web UI: behind Cloudflare or another reverse proxy, installing an update showed the proxy's 502 page, its HTML, in an
  alert: the bridge was restarting and the proxy answered for it. A 502, 503 or 504 that is not the bridge's JSON now
  reads as the bridge not answering, as a dropped connection does: the page waits for the restart, and other requests
  say Homeswift did not answer, never with the proxy's page.
- Web UI: in the graph (and its groups and lists), a camera whose first service is a motion sensor showed the sensor's
  icon, as UniFi Protect's do: a camera now shows a camera, a video doorbell a bell, whatever its first service.
- HAP: a bridge serves HomeKit at most 149 accessories, besides itself, as the specification requires ("A bridge must
  not expose more than 150 HAP accessory objects") and HAP-NodeJS and Apple's ADK do. Past that, the accessories added
  last stay out of HomeKit, as hidden ones do (they keep their ids and come in as others leave), and the log says which
  and to move a plugin to a child bridge. Before, nothing stopped a bridge from growing past what HomeKit accepts.
- HAP: an admin controller made a user by another admin could still add, remove and list pairings until it
  reconnected: `/pairings` used the permission its session started with. It now reads the pairings as they are, as
  characteristic handlers already did.
- HAP: a pair setup left unfinished after its first step kept the bridge answering "busy" to every other controller
  until its connection closed, which could be an hour or never. It now gives way after 30 seconds, as in Apple's ADK
  (`HAPServer.Options.pairSetupTimeout`), and its later steps are refused.
- HAP: a pair verify on a connection already verified is refused (400), as HAP-NodeJS 2.2.4 does: it would have
  swapped the session's keys in the middle of it.
- HAP: a connection gets at most one event message a second, button presses aside, as the specification asks
  (notifications coalesced over at least a second) and Apple's ADK does. The first change after a quiet second still
  goes after 50ms; a characteristic changing all the time is reported once a second.
  `HAPServer.Options.minimumEventInterval` sets the interval.
- HAP: values keep within the specification's bounds, as HAP-NodeJS 2.2.4 checks them. A string's `maxLen` is never
  more than 256 (in the database and in writes). A data value is at most 2 MiB of base64, or its type's new
  `maxDataLength` (`maxDataLen` in the database). A number is rounded to its `minStep` from its minimum value: a
  plugin setting 21.43 on a temperature with a step of 0.1 stores 21.4, and Eve's Voltage (a step of 1, from
  homebridge-ewelink) shows whole volts, as on Homebridge. A timed write's `PUT /prepare` needs a pid and
  a TTL from 1 ms to 2^31 − 1 ms, otherwise it gets 400.
- HAP: the count of failed pair setups, which stops them at 100 as the specification asks, is saved with the
  pairings, as Apple's ADK keeps it: a restart reset it, so the limit did not hold. A pair setup that succeeds clears
  it.

## [0.18.1] - 2026-11-01

### Changed

- HAP: the reads of one `GET /characteristics` run at the same time, as HAP-NodeJS's: the Home app asks for every tile
  on screen in one request, and one slow device no longer holds up the others' values (or shows them all as Not
  Responding). The same characteristic twice in one read is refused (422), as in a write.
- HAP: characteristic events are held 50ms and sent as one message, as HAP-NodeJS's are (it waits 250ms): a plugin
  updating 30 lights sends a few events to each controller, not 30. The same value twice in a row goes once; button
  presses go at once and take the waiting events with them. `HAPServer.Options.eventCoalescingDelay` sets the delay.
- HAP: `GET /accessories`, which every controller asks for when it reconnects or the configuration number moves, comes
  from a template built once, with the values filled in: each characteristic's permissions, type and metadata were
  built again for every request. The template is built again when an accessory is added, removed or hidden, or a
  service's structure changes.
- HAP: removing accessories no longer hashes the whole database for each, under the lock every request takes: each
  removal HomeKit sees bumps the configuration number at once, and the hash, the save and the advertisement follow
  once for the burst, as for added accessories. A plugin removing its stale accessories cost N² before.
- HAP: a request finds the characteristics it names in a lookup built once and kept apart from the server's state
  lock, which it took for every characteristic: with 16 controllers' connections busy, 14% of the server's time went
  to waiting on that lock. Timing observers have a lock of their own too.
- Setup, one way to get a device into the bridge whatever its plugin: the web UI's **Add accessories** page (`/setup`)
  lists what each plugin finds and where each device stands, and sets up accounts and devices in one sheet (a hub's
  link button, a TV's PIN, a sign-in with its one-time code, a sign-in page's redirect, developer keys). MCP clients get
  `discover_devices`, `start_setup`, `continue_setup`, `cancel_setup`, `set_device_excluded` and `set_device_part`; a secret field takes only a `vault:` reference.
  What an Authorization gives goes in the vault, never config.json. See GLOSSARY.md and docs/plugins.md, "Setup".
- Accessory Settings in a block's `_accessories`, by Device Id: **Exclude** a device from its row (it never becomes an
  accessory, in the Home app or Matter), and plugins' own settings per device. Homebridge-shaped blocks still load
  (docs/adr/0001-canonical-accessory-settings.md).
- Philips Hue keeps its bridge's key in the vault (`bridge.json` moves there), Philips Ambilight TV its TVs' keys,
  MyDolphin its refresh token and EcoFlow its developer keys (the block's `accessKey` and `secretKey` go once they are
  kept); Daikin's sign-ins run through Setup.

### Changed

- Every plugin sets up through Setup, and what it pairs or signs in with is kept in the vault: Philips Hue's bridge key
  (`bridge.json` moves there), Philips Ambilight TV's and Wingman's keys (out of `devices`), IKEA DIRIGERA's hub token,
  MyDolphin's, LG ThinQ's refresh tokens, Govee's login and certificate (`credentials.json` and `govee.pfx` move there),
  eWeLink's password, Dyson's local credentials, EcoFlow's developer keys and the UniFi consoles' logins Setup adds;
  Daikin's sign-ins run through it. A block's own secret keys still work, the vault's winning.
- Each plugin lists its devices for Setup and skips an Excluded one, eWeLink's channels and UniFi's child accessories
  with it.

### Fixed

- Web UI: a menu opened in a sheet (the full screens' Filters, in the wall's and the graph's panel) showed off screen: a
  glass sheet is the box its fixed children are placed in, not the window. Menus and the date range's popover are now
  placed where they land, and kept inside the sheet they opened in.
- Web UI: the graph's full-screen zoom buttons had their glyph off centre, pushed up by the hidden label's line.
- Web UI: the graph in full screen stopped 72px short of each side, cut off on a phone: it now fills the window, under
  its zoom and options buttons.
- Web UI: on a phone, the header's Assistant button was 36px wide and 40px tall, an oval off centre in the bar: it is
  round again, 40px both ways.
- Web UI: the Accessories page's rooms are spaced as the Home app's: 36px between one room's tiles and the next room's
  name, the name a bold 22px title. The widget screenshots draw rooms with the page's own markup.

## [0.18.0] - 2026-10-31

### Added

- The Accessories graph in full screen (`/accessories/graph?full=1`, or its toolbar's button), as the wall's: the graph
  alone, its zoom in the corner as a map's, the search and filters behind one button. An accessory's card in the graph
  holds its widget, live (a tap toggles it), then All controls and Identify.
- Updates in place on a Synology package too, and with their progress: the bridge downloads the release (the .spk for
  this NAS, Homebrew's upgrade on a Mac), says how far it has got, checks the new binary, puts it in place and restarts;
  the Status page's card (a new dark hero with the version) and the footer's button show the download's share as it
  goes. Package Center keeps showing the version it installed.
- Full screen for the Accessories wall (`/accessories?full=1`, the toolbar's Full screen): the widgets alone, for a
  wall tablet; grouped by room or plugin, one group a page, swiped left and right (arrow keys, dots, side arrows with a
  mouse); the toolbar waits in a panel from the right edge, Esc leaves.
- Visible in Home app, in an accessory's menu (and `set_homekit_visibility` over MCP): off, the accessory leaves the
  Home app while Homeswift, its tools and Matter keep it, so a Matter device of its own can be in Apple Home through
  Matter only. Kept in its plugin's block as `_hiddenFromHomeKit`; the plugin is not reloaded.

### Changed

- Web UI: the Status page's dark footer is gone. In a wide window its contents are Homeswift's section at the foot of the side menu, folded
  under its version; it unfolds into the health, the machine, the update button, Send feedback and Restart homeswift….
  The account button is gone there, its entries listed under You. In a narrower window the account menu holds the same,
  and on a phone the ☰ panel, under Account. Customise this page… floats at the Status page's bottom right. Plugin pages have the same side menu.
- Icons and names on the Plugins page: the Dolphin plugin is a pool robot (on its page, card, widget and Matter row), the
  Matter block reads Homeswift Matter with Matter's mark and the web UI's block a browser window; under its name in Add a plugin,
  each plugin says what it brings (`HomeswiftPlugin.summary`, translated), which the search also reads.
- The account at the foot of the wide window's side menu is a row of its own: under a hairline, the name with the
  account's role under it (or No sign-in) and a selector glyph saying it opens a menu, rather than an avatar left alone.

### Fixed

- A Matter device of its own that does not start (a host with IPv6 off, such as a Synology) is no longer silent: its
  Status row says Not started and why, its accessory menu leads there and can take it off Matter, and Make a Matter
  device no longer lands on a row that is not there. Only a port in use is retried on another port.
- The Status page explains what Matter needs of the network, folded under each pairing code and under a device that
  did not start: IPv6 on, a firewall that lets UDP in from IPv6 addresses (the Matter ports and 5353), and a home hub.
- A plugin's own page (`/plugins/<slug>`) sits in the app's frame again in a wide window, with the side menu's brand,
  Home's sections and You's pages, rather than a full-width menu above a page pushed to the bottom.

## [0.17.0] - 2026-10-31

### Changed

- The web UI's look is Apricot frost (docs/ui.md, "The look"): frosted glass over an apricot-to-stone backdrop, and
  Ember, a warm charcoal, in dark mode. In a wide window the app sits in one frame of glass with a menu down its left
  (Home's sections, then Account and Appearance under You); the current section, tab or choice is a white pill rather
  than an orange one; a page's title is set large and light; the Vault's entries that need attention, and the Status
  page's Vault summary while one does, are a dark card. A light that is on takes its colour, pale, as its widget's
  background (docs/widgets.md). The account menu has Restart homeswift…, apart and in orange; the plugin
  catalogue's Add buttons are plain, the Status page's memory and CPU charts are in the
  accent, a phone's header shows the name beside the icon, and in a wide window the Logs page's filters are a column
  beside the log, and the Assistant's sparkle floats at the bottom right with its chat opening above it. The chat's head
  groups its tools with a cog whose menu has the provider's settings and the voice's language, its field sits at the
  very bottom, and with a mouse its head drags it anywhere in the window.

### Fixed

- Wingman: an accessory Apple Home says is not reachable still takes writes, as the Home app still tries it. HomeKit's
  reachability lags for Matter devices on a Mac, which left a Nuki lock showing No Response and refusing every change
  before it reached Wingman; a write HomeKit takes ends No Response. `Accessory.isUnreachable` is the new state for a
  mirror (docs/plugins.md). Locks also need **Let bridges operate locks and doors** on in Wingman.

## [0.16.0] - 2026-10-30

### Added

- More HomeKit services on Matter (docs/matter.md): a Heater Cooler is a thermostat with heat, cool and auto between
  its thresholds; windows, and doors with `exposeSecurity` on, move as coverings; a Garage Door Opener is a
  garage door Closure with `exposeSecurity` on; a faucet is a water valve; an Air Purifier is one, with its Filter Maintenance's life and reset;
  a Carbon Dioxide Sensor, and an Air Quality Sensor's PM2.5, PM10 and VOC densities, report their concentrations;
  fans rock and reverse their airflow both ways.
- A HomeKit Thermostat with heating and cooling thresholds offers auto on Matter, its thresholds being the two
  setpoints; one without them still shows its auto as heat. Such a thermostat is made again on Matter once, with the
  new mode, so an ecosystem may ask to place it again. A cooling setpoint no longer moves a thermostat's heat target,
  and a setpoint past HAP's range is the nearest one it takes.
- A Matter bridge: with a `HomeswiftMatter` block, the plugins' accessories are Matter bridged devices too, both
  ways, for Google Home, Alexa, SmartThings and Home Assistant (docs/matter.md). Lights, plugs, sensors, blinds,
  fans, thermostats, buttons, and locks when `exposeSecurity` is on. The Status page's Matter card shows the
  pairing code and QR code to administrators, adds the bridge to another ecosystem and removes one; the MCP tools
  `get_matter_status`, `open_matter_commissioning_window` and `remove_matter_fabric` do the same.
  `homeswift-demo --matter` bridges the demo's accessories over Matter too.
- An accessory can be a Matter device of its own, with its own pairing code, which Apple Home, Google Home or Alexa
  add as that device rather than through the bridge: **Make a Matter device** in its ⋯ menu, `set_matter_device`
  over MCP, or the `HomeswiftMatter` block's `devices` (docs/matter.md). Changes to which accessories are on Matter
  apply without restarting it.
- A plugin can say what a service stands for when HomeKit has no type for it (`Service.standsFor`): the Dolphin pool
  robot's switch is a cleaning robot, a Robotic Vacuum Cleaner over Matter. Apple Home pairs a device of its own
  (it sends AddNOC's intermediate certificate empty, which swift-matter now takes as none).
- A Matter device's card on the Status page shows its device type's icon, and each ecosystem by its vendor: Apple
  Home's unnamed system fabric is a muted chip with a house, to keep. The Accessories graph shows the Matter block's
  devices (its devices of their own and its bridged ones) under it, with a neutral Matter mark: the Matter logo is for
  certified products only.
- Widgets placed freely on the Accessories wall: in Edit, a widget dropped on any cell stays there, gaps included, and
  the others make way; the wall's menu's **Pack the widgets together** lets them flow again. The cells are kept by
  grouping (`positions` in `ui-layout.json`), and `get_wall_layout`/`set_wall_layout` read and write them
  (`positions`, `clearPositions`) with the grid described for the Assistant, which can now compose a layout with them.

- Room names synced to the hubs, opt-in: with **Rename on the hubs too** on (the Accessories page's **Rooms** menu in
  Edit, which now renames rooms too, as do the room headings, editable in place in Edit, where a tile dragged to another room's wall moves the accessory there; `set_accessory_layout`'s `syncRoomNames`), a room renamed in Homeswift renames the
  rooms of the same name, case and accents aside, on Philips Hue Bridges, IKEA DIRIGERA hubs and eWeLink homes. Govee's
  API has no rooms. Plugins list and rename rooms through `rooms()` and `renameRoom(id:name:)` (`PluginRoom`);
  DIRIGERA's from lpgera/dirigera.

- Updates from the web UI: Settings › Updates (this version, the last check, a switch for the automatic checks,
  **Check now**, **Restart homeswift…**)
  and, on a Homebrew install, **Install and relaunch** in the update card, on that page and in the Status page
  footer's sheet: `brew upgrade homeswift`, then a restart into the new binary. The footer says **Relaunch to update**
  once a newer version is on disk.

### Changed

- Wingman: an accessory added or removed in the Home app, a room or a name changed, or a change of reachability
  reaches Homeswift within a couple of seconds (with a Wingman that sends `homes` events), not at the next
  `refreshMinutes` read. A burst of such changes reads the homes at most once every 10 seconds.
- config.json's editor is a tab of Settings (`/settings/config`), out of the header; `/config` leads there.
- The Status page's figures have their icon on a coloured tile at the left; the vault has an icon of its own, a safe.
- The Status page shows its Vault section once there is something in the vault or to move into it; a page's row of tabs
  (Settings) fades at the edges where tabs are scrolled out of sight, and opens with the current tab in view.

### Fixed

- Dyson Pure Cool: power on/off and Jet Focus did nothing on models newer than the Link series, such as the HP09
  (homebridge-dyson-pure-cool 1.4.8). As in the MyDyson app, they now get `fpwr` for power, `auto`/`fnsp` for mode and
  speed and `fdir` for the airflow direction, and their state is read from those fields; only the HP02, TP02 and DP01
  keep `fmod` and `ffoc`. The TP02 and DP01 move from `fpwr` to `fmod`.
- Dyson Pure Cool: the Dyson account sign-in failed with HTTP 429 (homebridge-dyson-pure-cool 1.4.7). Dyson's
  Cloudflare rule rejects the `android client` User-Agent; the sign-in now sends `okhttp/4.12.0`, as the MyDyson app.
- Settings › Bridge showed a sealed setup code (`enc:v1:…`) instead of the code: it now shows the code the bridge runs
  with, a copy button and the pairing QR code, and saving the form leaves a sealed or vault code as it is.
- Copy buttons copy in a browser that refuses the Clipboard API, through a hidden field as on plain HTTP.
- Settings › Child bridges without a plugin drew an empty list and pointed "above" at nothing: it now says so once, with
  **Add a plugin**.

- After an update the web UI kept the scripts and styles of the version before until refreshed, a web app on a phone
  for longer: the page asks for each file at an address of its bytes (`/app.js?v=…`, kept for good), and reloads by
  itself when the bridge's files change (after a restart, back in view, or when its event stream reconnects), unless it
  holds unsaved changes.

## [0.15.0] - 2026-10-29

### Added

- Homeswift's scenes in the Home app: a scene can be a switch (the editor's **A switch in the Home app**, `homeKit`) of
  one Homeswift Scenes accessory; on runs it without its security actions, off puts the lights back.
- eWeLink plays animated scenes natively on a SONOFF L2 strip with its own scenes (candle, sunrise, sunset, rainbow,
  ocean, moonlight, sunshine, dream, music), as homebridge-ewelink lists them.
- Scenes written to the hubs: a new scene of lights only can be saved to the Hue room or zone, or the IKEA hub, that
  has them all (`save_scene`'s `hub`, the editor's save bar); a hub's scene can be renamed, keep its lights as they are,
  or be deleted from its hub (`update_hub_scene`, `delete_hub_scene`, which asks first; the Scenes page's ⋯ menu).
  Plugins write scenes through `sceneTarget`, `createScene`, `updateScene` and `deleteScene` (`PluginSceneLight`);
  DIRIGERA's from lpgera/dirigera.
- Scene pictures of your own on the Scenes page: a scene's or a hub scene's ⋯ menu chooses a picture or removes it
  (`/api/scenes/<id>/picture`). The bridge keeps every scene's picture in `scene-pictures/`; the Hue and IKEA pages
  show and change the same ones (`PluginContext.scenePictures()`), and the pictures they kept before move there once.
- Scene templates and scenes the Assistant writes: the mood collection and the scene gallery are templates
  (`list_scene_templates`), which `run_scene` tries and `save_scene` keeps for a room's lights, as values set once, an
  effect each brand plays its own way, or a timed sequence; a `description` does the same through the bridge's
  Assistant. On the Scenes page, Templates replaces Moods: a tap tries one with Stop or Undo, Save as a scene keeps it,
  and Describe a scene asks the Assistant.
- Animated scenes: a scene or a plan can make lights move after its actions (`animation`: a style such as candle,
  fire, sparkle, prism, underwater, sunrise, moving colours or music, with a colour, speed and brightness, or timed
  steps). Plugins play their own lights natively (`HomeswiftPlugin.animate`): Hue with `effects_v2` and `timed_effects`,
  Govee with the library scene of the style's name, DIRIGERA a sunrise or sunset as one long fade, the Ambilight TV
  following the music; Homeswift's player plays the rest. The scene editor has an Animation step.
- The vault, its first step (docs/vault-design.md): a secret in config.json can be a reference instead of a value,
  `vault:<name>` (`#field` for another field than the main one), `env:<VARIABLE>` or `file:/path` (Docker's secrets),
  under any secret-named key. `homeswift vault list | set | remove` keeps the local vault's entries in `vault.json`,
  each value sealed by `secrets.key`, read from standard input. References are resolved at start and on each save,
  which a reference that does not resolve stops; they are kept as they are by the sealing and shown by `get_config`.
  Every secret the bridge opens or resolves is masked by its exact text in logs, MCP replies and the Assistant's
  prompts.
- What a reference reaches is limited: a plugin's own vault entry only from its own block, `file:` only below the
  folders `HOMESWIFT_SECRET_FILES` lists (`/run/secrets` by default), `env:` only the variables `HOMESWIFT_SECRET_ENV`
  lists when it is set. MCP clients and the web UI's chat cannot add `env:` or `file:` references and, like dry runs,
  learn only that a reference does not resolve. The Assistant's connection test sends a saved key only to the saved
  provider and address.
- The Vault page (Settings › Vault, administrators): the secrets still in config.json with the entry each would become,
  to move them in one step; the entries with their kind, fields, users and expiry, added and replaced with values that
  are never shown again, kept from deletion while config.json names them. A secret's field in a settings form gets
  a key button whose menu searches the vault and puts `vault:<name>`. Menus can carry a search field (`search`). The
  vault's routes keep their bodies out of the audit log.
- Moving config.json into the vault: `homeswift vault migrate` (`--dry-run`, `--exclude`, `--separate`, `--name
  <id>=<entry>`) and the MCP tool `migrate_to_vault` (confirmed, with `dryRun`) list every secret of the plugin blocks
  and the Assistant's block with the entry it becomes, merge identical values into one entry, back up config.json and
  write it with `vault:` references. From then on a new plain secret in a save goes to the vault too. The Assistant's
  connection test opens sealed keys and references before it sends them.
- The vault's health: each entry keeps when it was last used (a reference resolved, or the plugin read its token; once
  an hour at most), and `VaultHealth` finds what needs attention: references to entries that are gone or that cannot
  read their entry, and entries expired or expiring within 30 days. The Vault page lists them on top with the step that
  fixes each, a new Status widget shows the vault's figures and its problems to administrators, and the daily digest
  hears of them. The MCP tool `list_vault` (read, administrators only) lists entries, their users, dates and health,
  never a value.
- Plugins' tokens in the vault: `context.secretFile(_:as:)` keeps a token or a key like `jsonFile`, sealed in the
  instance's namespace of the vault, and moves the plain file of that name into it the first time it reads it. eWeLink's
  session (`ewelink-tokens.json`), DaikinCloud's token sets (`.daikin-*-tokenset`, so one copied from Homebridge still
  works), LGThinQ's MQTT client key and certificate request, and DIRIGERA's hub tokens (`hubs.json`) move there.
- Scenes composed on the fly and undone: `run_scene` takes a `plan` (values to set and hubs' scenes to recall) that
  runs at once without being saved, and `save_scene` keeps one. `stop_scene` puts back what any run changed in the last
  12 hours: a saved scene, a hub's scene or a plan. A scene can recall a hub's scene among its values (`{"recall": id}`):
  the Scenes page's **Automate** makes one for a hub scene, to give it triggers, and the editor adds them. Hub scenes
  get **Stop** on the page.
- Scenes from plugins' hubs: a plugin lists its hub's scenes with `scenes()` and recalls one with `recallScene(id:)`
  (`PluginScene`). Philips Hue (rooms and zones), IKEA DIRIGERA (user scenes) and Govee (the library scenes picked for
  a light) do. The Scenes page shows them under Homeswift's own, by room, with a source filter; `list_scenes` lists them
  as `pluginScenes` and `run_scene` recalls them, holding the lights they change so `stop_scene` puts them back.
  Homeswift's scenes now say their room and whether they are active. The first step of unifying moods and scenes
  (docs/scenes-design.md).
- The Assistant arranges the Accessories wall: `get_wall_layout` and `set_wall_layout` (MCP, and the web UI's chat)
  read and change its order, each accessory's size, the default size of each kind of widget and the grouping. An
  `order` of some ids puts them in the places they hold together, so one room is sorted without moving the others.
  It groups accessories that go together (a room's lights, its blinds) into one widget, changes and dissolves groups.
  An open Accessories page draws the wall again when it or the rooms change, from the chat, an MCP client or another
  page (a `layout` event on `/api/events`).
- `publicURL` in the HomeswiftUI block: the MCP connector on a path of a host name other servers share behind one
  tunnel (`https://mcp.example.com/homeswift`). Requests for that host name under that path, and the OAuth discovery
  documents for it, are answered as `/mcp`, `/oauth` and the sign-in page, whose files and API calls stay under the
  path. Off without it.
- Adaptive Lighting on every IKEA DIRIGERA, Philips Hue and eWeLink light with brightness and white temperature. A colour
  or a white set elsewhere (the vendor's app, a remote, a scene) turns it off, as the Home app does. eWeLink's
  `adaptiveLightingShift` now applies: mireds warmer, or -1 for none.
- Plugin contributors check Adaptive Lighting: `Scripts/new-plugin.swift` gives a light with Brightness and Color
  Temperature a controller, the bridge's debug log (and `check-on-bridge.sh`) names a light without one, and
  CONTRIBUTING.md and the pull request template list it.
- `Scripts/test.sh` builds the tests and runs every test target at once: the whole suite in about 3 seconds on macOS,
  where `swift test` runs the targets one after another (about 20 seconds, down from two and a half minutes).
- EcoFlow: the plugin's page shows the devices two to a row on a wide screen, and a device's card can be dragged by
  its grip (or moved with the arrow keys) to another place; the plugin keeps the order.
- Plugin forms: `"x-schema-form": { "requiredWhen": <condition> }` marks a field required only while its condition holds
  and the field is shown. EcoFlow's form groups its settings by route (EcoFlow account, Developer API, Devices) and marks
  the email and password, or the keys, required on the route that needs them.
- EcoFlow: the energy history import brings the STREAM system's battery charge and discharge and grid import and
  export too, from the charts of the app's Battery and Grid pages: the Status page splits imported days' home use by
  source, and the Power chart draws their battery and grid.
- EcoFlow: the energy history's answers are checked against the shapes the import reads, and a change, or a battery
  or grid chart the cloud stops answering, is logged once, as the live APIs' changes are.
- Status: the energy history card leads with the period's home use and a strip of the share solar, the batteries and
  the grid covered, then lists the battery's charge and discharge with the grid's import and export; large figures
  drop their decimals and the axis writes its unit once.
- Status: every chart writes its unit once, on the top tick, without decimals every tick has as zeros (`40 MB`, then
  `30`, `20`…); the request charts' quarter-millisecond ticks read 0.25 and 0.75 rather than 0.3 and 0.8; the Battery
  level chart writes each device's level in its legend.
- Status: the Energy section's Power chart draws an imported history's hours (a device cloud's solar and home use)
  where the bridge recorded nothing, each at its average, and says so under the chart.

### Changed

- Adaptive Lighting resumes as the Home app turns it on: the last schedule's transition id, a start time of now, and its
  day's curve rotated to begin at the white for this time of day, so it covers a whole day again
  (`AdaptiveLightingController.resumeAdaptiveLighting()`). It moved the schedule by whole days before, which could end
  it early or refuse a time of day. The Home app shows a resumed schedule as on. `homeswift-demo`'s lamp has Adaptive
  Lighting, and `SIGUSR1` resumes it.

### Removed

- **Breaking:** moods. Scenes do what they did: the collection and the gallery are scene templates, the Assistant
  writes scenes from a description, and animated scenes play light shows. The MCP tools `list_moods`, `start_mood` and
  `stop_mood` are gone (use `list_scene_templates`, `run_scene` with a `template`, `description` or `plan`, and
  `stop_scene`), as are `/api/moods/*` and the Scenes page's Moods section (now By room: each room's scenes, then the
  templates). `held-moods.json` gives way to `held-lights.json`; runs a restart interrupted are not undone after the
  upgrade. A plugin action that changes lights now answers a run for `stop_scene`.

- Homeswift Natural Lighting, the bridge's own daily white schedule for lights without Adaptive Lighting: its sun
  toggle, `PUT /api/accessories/<id>/natural-lighting` and `naturalLighting` in `/api/accessories` and the event
  stream. A `natural-lighting.json` left in the configuration directory is no longer read.

### Fixed

- An accessory group's failed change is a callout: the members that did not change, each one's reason, Try again for
  those members and a close button, over the whole group widget. It was a line of plain text without the reason, letter
  by letter on a medium group.
- A link in an accessory's sheet (Show its log, Plugin settings) closes the sheet: the next page opened under it,
  behind the sheet and its blur.
- A menu opened from an accessory's sheet (its ⋯) shows over the sheet; it opened behind it.
- An accessory group no longer takes a security control (a switch that unlocks a door), so a tap on the group
  cannot open a door.
- Accessories › Graph: a node's tooltip sits over its node; inside the page's glass card it showed some 200 px off.
- Accessories › Graph: an accessory, and a group of them, shows the icon its tile shows (a battery for a power station
  filed as Other), not a generic square.
- EcoFlow: without `devices`, the EcoFlow app route reads the account's devices from the app's device list instead
  of the wildcard subscription EcoFlow's broker refuses, so it no longer needs serial numbers; its failure is no longer
  logged as a failed sign-in. The energy history import finds the account's STREAM in the device list when none has
  reported, and the plugin's page offers to add the devices it reads to `devices` (**Add to the configuration**).
- EcoFlow: a month of the energy history the cloud refuses ("Server error") is asked for again, and a failed import is
  tried again after 10 minutes instead of 6 hours. A device the EcoFlow app lists offline (a RAPID Pro X) is shown
  offline rather than left out.
- EcoFlow: a STREAM read from the developer API's REST values no longer shows the system's battery level (or 0, on
  an AC Pro) as its own: REST has no unit's level, so it is unknown there, and with Both the EcoFlow app's reading,
  which has it, is used instead.
- EcoFlow: each bridge connects to the developer API's MQTT with a client id of its own, kept across restarts, rather
  than the account alone: two bridges with the same developer keys no longer cut each other's live readings off.
- Quick controls groups its heading and scene shortcuts in one card; photographic scene tiles replace cramped
  thumbnail pills and scroll horizontally on phones.
- Philips TV: a colour picked just as the configured Ambilight mode was re-applied after power-on could be replaced
  by that mode.
- UniFi Access: a gate's open phase that ran late, after its closing phase had begun, put the gate back to open, and
  the position sensor's close was then ignored: the gate stayed open in HomeKit.
- eWeLink: two requests refused with an expired token at once could refresh it twice, the second time with a
  refresh token the first had just replaced.
- A configuration save checked a platform block that moved in the file against nothing: its unchanged settings
  were checked as new.
- UniFi Access: a gate whose position sensor reported open only once closing had begun stayed Closing in HomeKit after
  the sensor reported it closed.
- A value put back by a plugin's revert while HomeKit's write was still being handled was replaced by the written value.

## [0.14.0] - 2026-10-28

### Added

- Scene gallery: 143 original photographic palettes in 28 theme categories, search, theme filtering and
  alphabetical sorting; saved scenes retain their selected artwork. Dedicated photographs cover the built-in moods.
- Saved scenes capture restoration state for **Stop**, including light colour mode and Adaptive Lighting.
  Restoration survives bridge restarts for 12 hours and requires confirmation for locks, doors and alarms.
- A visual workflow editor with triggers, conditions and device-specific controls, including a combined light
  colour picker, brightness and temperature sliders, switches and mode menus.
- Sunrise/sunset location selection on an OpenStreetMap map, with address suggestions from Photon and a search loader.
- Photographic and abstract wallpapers, appearance heading icons and language icons.

- **EcoFlow** plugin (`EcoFlow`, new, experimental): each STREAM, RIVER, DELTA, RAPID, GLACIER, PowerStream,
  PowerOcean and Smart Home Panel device is a battery on its own accessory, with its state of charge and whether it is
  charging. A model is known by its serial number's first characters; the STREAM Ultra and AC Pro, RIVER 3, RIVER 3
  Plus and RAPID Pro X were checked on real devices, the others are mapped from open-source projects and marked
  untested on the page, and a model the plugin does not read is left out and logged once. It reads the developer API
  (a developer access key and secret key; MQTT pushes, the REST quota until they arrive) and the EcoFlow app's own
  sign-in (an email and password, unofficial; its live stream, decrypted, with the app's read request so the devices
  answer without the app open), both by default or one as the **Route** setting says; each device comes from one of
  them, shown on its card. Its page shows each device's power as the app lays it out (STREAM: solar, home, grid,
  battery, sockets and panels; RIVER: input, output, AC input, 230V AC, USB-A, USB-C; RAPID: input and output; a home
  system's solar, home, grid and battery), live, with the last hour of each reading. A home system's solar, home, grid
  and battery and every device's level feed the Status page's Energy section, and with the app's sign-in the cloud's
  hourly solar and home use since the system was set up fills its history (`importHistory`, on by default). A change
  in the shape of an API's answer, or an API that fails, is logged once.
- `/api/metrics/values` answers several plugin readings at once (`series` separated by commas), in one pass over the
  minutes: a plugin page that graphs many readings asks for their history in one request instead of one per reading.
- IKEA DIRIGERA: motion, light, air quality and water leak sensors, blinds, the STARKVIND air purifier and remotes.
  VALLHORN and MYGGSPRAY are motion sensors (with VALLHORN's light sensor on the same accessory), VINDSTYRKA, ALPSTUGA
  and TIMMERFLOTTE temperature, humidity, air quality and CO₂ sensors as they measure, BADRING and KLIPPBOK leak
  sensors, FYRTUR, KADRILJ, PRAKTLYSING and TREDANSEN window coverings, STARKVIND an air purifier with its filter, and
  each button of a STYRBAR, RODRET, SOMRIG or BILRESA a programmable switch fired by the hub's press events. Parts of
  one product share an accessory; batteries are shown.
- Philips Hue: sensors and switches. Each Hue device with sensors or buttons is an accessory: motion, temperature,
  light level and contact sensors, its battery, and a programmable switch per button of a dimmer, Tap, Tap dial or
  smart button (single, double and long press). The plugin follows the bridge's event stream, so presses reach the Home
  app at once and a change made in the Hue app shows without waiting for the poll. The page has a **Sensors** tab;
  `sensors` and `excludeSensors` choose what the Home app shows.
- `HomeswiftNetwork`: `HTTPClient.stream(_:)` hands back a response once its head arrives, its body following as it
  comes (`HTTPStreamingResponse.body`), and `ServerSentEvents` reads a `text/event-stream`; leaving the loop closes the
  connection. `HTTPStreaming` is the protocol for fakes in tests.
- Plugins record readings for the Status page's history (`PluginContext.recordValue`, series
  `plugin:<platform>:<series>`): each minute keeps the count, sum, lowest and highest, for 8 days, and
  `/api/metrics/values` answers a series over a range.
- The Status page's **Energy** section, fed by readings plugins tag with a role (`recordValue(_:series:energy:)`,
  `EnergyTag`: solar, home, grid, battery power, battery level; a figure several devices report alike counts once):
  the power of each role added up across devices (the grid's export and the batteries' discharge below zero), each
  device's battery level, and each day's energy in kWh for today and the 7 days before as stacked bars (where the
  home's energy came from above the line, where the rest went below it), with today's figures above and tables on demand. Its own time range; `/api/metrics/energy` answers it in one request. Line charts draw values below zero, with a zero line; `HomeswiftChart.stackedBars` draws stacked bars.
- A long-term energy history (`EnergyArchive`, `metrics/energy-hours.json`, kept for years): each hour's watt-hours of
  solar, home use, grid import and export and battery charge and discharge, from the bridge's own minutes as they close
  and from plugins' imports (`PluginContext.importEnergy`); an hour the bridge recorded most of keeps its own figures.
  The Energy section's history shows a **Week**, **Month** or **Year** at a time, with the periods before and after and
  their totals; an imported hour's home use without a grid or battery split shows as **Not split**.
  `/api/metrics/energy/history` answers it.
- A plugin's energy import reports its progress (`PluginContext.reportEnergyImport`): the Energy history
  shows it running, with the bars filling in, then what it covers and when it last ran, or why it failed.
- A battery on its own accessory (a power station) has its own widget on the Accessories page: the battery graphic
  (bars for the level, a bolt while charging) and its level at every size.
- The Assistant's chat copies the whole conversation from a button in its header, as Markdown (the messages, the
  steps it took, the changes it asked for), to paste in a report; the tools' arguments and answers stay out.
- A plugin action the Assistant or an MCP client runs that changes lights (a Hue or IKEA scene recalled on its own
  bridge) can be undone like a mood: the lights it changed are held, and `stop_mood` puts them back for 12 hours.
- A mood or plugin scene that can still be undone survives a restart: what its lights were is kept in
  `held-moods.json`, and `stop_mood` puts them back for what is left of the 12 hours.
- The IKEA DIRIGERA page shows the hub's wake-up scenes, greyed and dashed with a Wake-up badge: they run on the
  hub's schedule, so they cannot be run there and stay out of HomeKit.

### Changed

- Scene and mood tiles share photographic styling. On phones, gallery categories, built-in mood categories,
  and Hue and IKEA scene collections scroll horizontally in a single row.
- Scene card actions are collapsed by default; Details exposes every action. Active moods have a centred Stop icon.
- The workflow editor uses full-width panels and expandable action summaries on phones, with accessible save
  controls, stacked trigger/condition fields and an in-app scene deletion confirmation.
- Documentation screenshots and all four website languages reflect the scene gallery and mood artwork.

- Every time range is one control, `HomeswiftCommon.rangeControl` (the Status page's Activity and Energy, the Logs
  page): presets in a segmented control, then **Custom…**, a pop-over in the app's material with a month to pick the
  first and last day and the From and To times, in place of a menu and the browser's date picker. The design explorer
  shows it under Foundations.
- The web UI's stylesheet has shape, spacing, type, weight and layer tokens (`--radius-sm`, `--space-12`,
  `--text-sm`, `--weight-figure`, `--layer-menu`…), and accent tints are `color-mix()` of `--accent`. About 1,500
  literal values moved onto them. Corners now keep to one scale of 6, 10, 14, 18, 22 and 26 px: segmented controls,
  readouts, menus and panels round by up to 2 px more or less, a capsule is a capsule at any height, and a
  segmented control's thumb follows its track's curve. homeswift.dev uses the same scale. The design explorer's
  Foundations shows the shapes, the type ramp and the weights live; docs/design-system.md lists every token family,
  and a test keeps the stylesheet on them.
- A widget's ⋯ menu is grouped as a context menu: All controls, then History, Identify and the Assistant, then how
  it sits on the wall (its size as one segmented control across the menu, the size for every accessory of the kind,
  room, name, Quick Controls, Hide), then its log and plugin settings. The ⋯ button is an ellipsis in a tinted
  circle, so it shows on any tile, light or dark.

- The JSON editors (Config, a plugin's JSON) fold a block that spans lines from a chevron beside it.
- The JSON editors mark each key that holds a secret (the bridge's redaction rule) with a lock, in gold.
- Config's **Secrets only** folds everything but the secrets and the way to them; a gold button and a strip say while it holds.
- A plugin declares its web UI icon in Swift (`HomeswiftPlugin.icon`, a name from common.js's icons such as
  `"logo-elgato"` or `"bulb"`), which `/api/plugins` reports for each plugin and each block; the web UI no longer lists
  them itself. A Homebridge block the import renames takes its new plugin's icon (AI Kit, the Assistant's sparkle).
- A doorbell's category icon is a bell everywhere, not a camera.
- A camera that sends no picture shows television snow behind its message.
- The graph of bridges, plugins and accessories moves from Settings › Overview to a **Graph** tab of the Accessories
  page (`/accessories/graph`, for every signed-in user). Settings › Overview goes, and `/settings` opens Bridge. Every value of a
  node's card has a tooltip saying what it is; an accessory's readings are grouped by service and worded as on the
  Accessories page, a camera's alike streams as one group with their count, and doorbells have a bell icon. A camera's
  card opens with its picture, live while it is open as on the Accessories page. The legend keeps the states alone.
- The graph colours each plugin's branch (the plugin, its device types, accessories and links) on its own; bridges
  are neutral.
- Each plugin has its own icon on the Plugins page and the graph: its brand's logo where Simple Icons has one
  (Philips Hue, LG, Ubiquiti, Elgato, IKEA), else what it controls (a bulb for Govee, a thermostat for Daikin…).
- Plugins: your plugins have the catalog's search and sort (by name, needing attention first, or by accessories),
  under a **Your plugins** heading.
- Plugins: a running plugin shows a quiet green dot (the other states keep their words), a card no longer repeats its
  name as its platform, the notice about blocks no plugin runs names them as the cards do, and on a phone the search
  takes its own row.
- The graph: bridges, plugins and device types are icons alone (their names are in the tooltip and the
  card), and the icons on each ring are spaced so that they never overlap, the rings growing when they need room.
- The graph: a search field and a Filters menu (unavailable, bridges, device types, each with its count) redraw
  the graph and its table with only what matches, on smaller rings (a few results as a fan, zoomed to fit). A bridge's, plugin's or device type's card lists its accessories with
  their icons and status, each opening its own card (with a way back); facts sit in inset groups; categories have names
  in every language; the centre shows the app's icon alone, smaller.

### Fixed

- Failed or skipped actions on a repeated scene run retain still-valid restoration snapshots from the earlier run.
- Failed light writes no longer take ownership away from an existing mood or register a held scene for that light.
- Small-screen workflow fields no longer overflow horizontally.

- The Assistant's mic listens on every press: a press while an answer ran, while a change waited for Allow, or
  while the last dictation was finishing did nothing. During an answer the words wait in the field.

## [0.13.0] - 2026-10-27

### Added

- Appearance keeps several wallpapers of your own (up to 12, in `ui-wallpapers/<user>/`): a tile each with its
  thumbnail, a tap to show it and a ✕ on its corner to remove it. They come from a drop zone with an image icon in place
  of the button, which takes several files at once. The preferences list them (`wallpaperImages`, `wallpaperImage` the
  one shown); `GET` and `DELETE /api/preferences/wallpaper/<id>` serve and remove one. The image an earlier version kept
  moves into the folder.
- **Settings › Overview**, the default Settings page: headline counts, then a radial graph of homeswift at the centre,
  each bridge a pill on the first ring, its plugins on the second, each device type as a node, and each accessory a
  disc with its device-type icon on the outer ring. Click a bridge or plugin to zoom into its branch (Ctrl-scroll,
  pinch, drag and zoom buttons too). Click any node for its facts, status and readings; a table gives the same rows.
- **Philips Hue** plugin (`PhilipsHue`): lights, scenes and effects through a Hue Bridge's local API v2, no cloud.
  Each light with brightness, colour and white, a switch per effect (candle, fireplace, prism…), each room's and
  zone's scenes as switches (smart scenes too), optional Flash switches and gradient points. A light's changes go in
  one command with a chosen transition (`transitionMs`, 0 for instant flashes). Pairing with the link button from
  the plugin's page, which shows the lights as the Accessories page's widgets and the scenes as palette tiles.
- Philips Hue: **room lights** (`roomLights`, off by default), a lightbulb per room and zone driving its
  `grouped_light`: on, off and brightness for all its lights in one command, as the Hue app's room controls.
- **IKEA DIRIGERA** plugin (`Dirigera`, homebridge-dirigera's block): lights, outlets, PARASOLL door and window
  sensors with their battery, and scenes (On triggers, Off within 30 seconds undoes), followed through the hub's
  websocket. Pairing with the hub's action button (OAuth with PKCE) from the plugin's page.
- Scene pictures for Philips Hue and IKEA DIRIGERA: drop a picture on a scene's tile (or choose one from its menu) and
  the tile shows it; the page shrinks it, the bridge keeps it in the plugin's folder (`PluginPictures`, JPEG, PNG or
  WebP checked by their bytes, 1 MB at most).
- The Assistant picks Philips Hue and IKEA DIRIGERA scenes: `list_scenes` describes each scene's look in words (warm or
  cool, its colours), `recall_scene` and `run_scene` set the one that fits what was asked.
- Govee: **Scenes over LAN** (`lanScenes`, per light, off by default) sends scenes, DIY effects and music mode
  straight to the light as `ptReal`, faster and without the cloud. The light does not confirm LAN commands, so one
  that ignores them gets no cloud or Bluetooth fallback.

### Changed

- On a phone the Logs filters take three short rows instead of six: the four levels in one row with the count under
  each name, the search with Clear filters as an icon (shown when there is something to clear), the two menus side by
  side; the action bar fits on one row, Copy as an icon. Elsewhere a level's count is a lighter number after its name.
- On a phone the settings bar fits on one row beside the menu button (Revert as an icon), and Appearance's choices fill
  the card's width, a row of languages never ragged and a button never narrower than its text.
- Settings: the Bridge page moves to `/settings/bridge`; `/settings` opens the Overview.
- Philips Hue and IKEA DIRIGERA: a moved bridge loses its key until it is paired again from the plugin's page (a bridge
  ID is public, so it proves nothing), and a fresh pairing starts from no pinned certificate.
- Philips Hue: a scene's writes go in one group per step, colours first and then On; the search filters once typing
  pauses; the page redraws only when the bridge's answer changes.
- The logs route refuses a `bridge` and a `plugin` filter together (400), rather than silently dropping one.
- Accessories: a group whose members differ shows it plainly rather than "Mixed" beside a switch that moved: the
  switch half lit with its thumb between and "2 of 5 on" under its name (a tap turns them all on), and each slider
  the spread of its members, "40–80 %", solid to the lowest and lighter to the highest.
- The Assistant's prompts are Markdown files in `Sources/HomeswiftAI/Prompts/`, one per feature, embedded into the
  binary by `Scripts/embed-assets.swift prompts`; the prompts themselves are unchanged.
- The writes of one HomeKit request run at the same time, as in HAP-NodeJS: a light's brightness and colour reach the
  plugin together, so colour changes from the Home app are faster. A request naming one characteristic twice is
  refused (422), as HAP-NodeJS does.
- Moods change every light of a step at once, and steps can be as short as 0.25 s for fast flashes. A step's time now
  includes its writes, and the lights are put back all at once.

### Fixed

- A restart from the web UI came back in 25 to 30 seconds: the new process kept the browser's open connections,
  which nothing read, and the page's checks waited out their timeouts. Descriptors are close-on-exec before the
  restart; the page is back in under two seconds.
- `?section=proxy` (the "Schedules and proxy" card's link) opens and scrolls to the web UI's reverse proxy settings.
- A list's Add button says "Add trusted reverse proxy", not "proxie" (-ies, -es and -us titles).
- Removing your own wallpaper image takes its tile away too: the page kept the removed image's version.
- A password in a URL is masked up to its last `@`, also when the user name holds an `@` or the password a `/`; a
  structured URL with such a password counts as a credential.
- Passcode, `pwd`, `pw` and `auth` fields count as secrets; an `adminTokens` key no longer passes as a token count.
- The first use of the secret key is serialised, so two saves at once cannot each write a key.
- A new scene picture is written before the other formats are removed, so a failed upload keeps the old picture.
- Restored files are owner-only (0600), whatever mode the archive gave them.
- Restore replaces an existing file by removing it and moving the staged copy in, which works on Linux too.

- Moods write saturation before hue, so a plugin that sends the colour when the hue arrives no longer uses the
  previous saturation.

## [0.12.0] - 2026-10-26

### Added

- Move to room for accessory groups (administrators): every member moves in Homeswift, HomeKit rooms stay unchanged.
  The group editor filters the available accessories by room and device type.
- Identify through Wingman for the devices Apple Home can identify; the action is hidden on accessories without one.
- A compact Status footer with a manual update check and status icons.
- Filter counts that follow the search, explanations on disabled filters, and the same Clear filters control across
  the UI.

### Changed

- Accessory and group editing: room ordering, resize handles, move arrows and clearer drag-to-group targets.
- Accessory groups use the light widgets' pill sliders, with a warm-to-cool kelvin track for colour temperature, and
  stay in their members' room or plugin section instead of moving to the first section.
- Group-editor actions stay visible on small screens. Plugin pages share the same action icons, and Wingman shows its
  winged-house icon on its plugin page, plugin cards and the website.

### Fixed

- A failed Wingman write or Identify says why (Apple Home's "Missing entitlement for API", a lost pairing) instead of
  "did not answer: the device may be off or out of reach". MCP clients receive those words as untrusted data.
- Natural Lighting no longer pauses itself when a lamp rounds the temperature it was sent to its own kelvin steps. A
  manual change that fails leaves the schedule running, and turning it on applies the light even while the minute
  update is writing other lamps.
- Webhook error messages keep short header values and usernames readable: only secrets of four characters or more
  are masked.
- The port check accepts the web UI's own port when only its address changes.
- An accessory group keeps controlling its remaining members when one of them is missing.
- Daikin's curl transport watches for the process to end before launching it and drains both output pipes at once,
  preventing the macOS CI hang and full-pipe deadlocks.
- A cancelled UniFi Protect timeout no longer overrides a completed operation, which could drop RTSP recording
  initialisation and intermittently fail Linux CI.

## [0.11.0] - 2026-10-25

### Added

- Dashboard accessory groups: create a group with an available/selected device picker and type filters, or drag
  compatible tiles together in Edit mode. Shared controls update the members; ungrouping returns individual tiles.
  Groups stay in Homeswift and do not create HomeKit accessories.
- A No Response filter on Accessories, including unavailable group members.
- Port availability checks in Settings and the HomeswiftUI form, including keyboard and stepper changes.
- A public design-system explorer with production widgets, characteristic controls and demonstration fixtures.

- Notification webhooks support Bearer and Basic authentication and custom headers, with masked credentials and header validation.

- Accessory grid editing guides, corner drag-to-resize handles and animated layout changes, with keyboard resizing.

- Opt-in Homeswift Natural Lighting for lights with writable colour temperature: a saved daily schedule in the
  user's time zone, paused by manual colour writes or external white-temperature changes. Leaves power and brightness alone.
- Apple Home source filter with the Home app icon, accessory count and an accessible switch.

### Changed

- Mobile navigation uses a bottom-right menu with Settings and Account. Its floating hamburger button has a subtle glass effect, with an opaque fallback for accessibility preferences. Save bars leave room for it when they overlap.
- Status customisation keeps switches and drag handles in its menu and applies layout changes without reloading.
- Scenes use a visual builder with clearer removal actions, localised weekdays, and coloured brightness and
  colour-temperature sliders. The empty state offers New scene directly.
- Plugin cards have a denser layout and sorting. Notifications, logs, backups, audit history, Assistant setup and
  HomeswiftUI settings have updated layouts and controls.
- Restart uses an in-page confirmation and blocking overlay, then reconnects without a full-page reload.
  Shutdown now logs its stages and has a 30-second fallback that replaces a stalled process.
- Cached-accessory removal explains the effect on native and mirrored accessories before confirming.

### Fixed

- Restart recovery retries get a fresh deadline. Reconnected pages refresh accessory values in place and preserve
  newer live events, without losing layout, scroll position or unsaved forms.
- Group-control labels and accessible names follow the selected language.
- Button-shaped links in card footers keep their button appearance on hover and have an explicit keyboard focus ring.
- Wingman lights show the latest reported colour temperature in kelvin instead of an information-only Adaptive
  Lighting sun button. Missing readings are not shown as a fabricated temperature; Apple Home keeps the schedule.

## [0.10.0] - 2026-10-25

### Added

- A calm mood (candlelight, focus…) can be undone for 12 hours: **Undo** on the Scenes page, or `stop_mood`, puts
  every light back as it was, its colour temperature as well as its hue and saturation. A mood started on some of its
  lights takes only those; the rest stay to undo.
- The **Wingman** plugin: the Home app's accessories in Homeswift, Matter ones included, through Homeswift Wingman,
  a menu bar app on a Mac (github.com/mp-consulting/homeswift-wingman). Its page finds Wingman over Bonjour and pairs
  with the 6-digit code Wingman shows, the certificate compared and pinned; changes arrive at once (long-poll) and
  writes go through Wingman. The accessories join the Accessories page in Apple Home's rooms, moods, scenes and the MCP
  tools, and are never published to HomeKit again; Homeswift's own accessories are left out.
- Mirrored accessories (`Accessory.mirroredFrom`, `suggestedRoom`): kept out of HomeKit's database, marked with a house
  badge on the Accessories page, which filters on them (**Only from Apple Home**). `CharacteristicType.known(uuid:)` and
  `ServiceType.known(uuid:)` find Homeswift's types by UUID.
- The Accessories page shows No Response for an accessory whose device does not answer, and follows it as it changes.
- `PluginContext.publishedSerialNumbers`: the serial numbers of every accessory Homeswift publishes, for a plugin that
  reads another controller's view of the home.

### Changed

- Moods are drawn with small illustrations instead of gradients, on the Scenes page and on homeswift.dev.

### Fixed

- A WebSocket the peer resets (with frames still in flight) ends as a dropped connection, as one closed without a close
  frame does, instead of with the raw I/O error: the plugins on it (Daikin Cloud and others) reconnect the same way
  whichever of the two happens.

## [0.9.0] - 2026-10-25

### Added

- Moods for a room's lights: calm ambiances set once (candlelight, cinema, focus), slow animations (candle
  flicker, fireplace, ocean, northern lights, sunset, sunrise), party effects (disco, police siren, rainbow wave,
  lightning storm, Halloween, Christmas) and signals (an alert flash, bedtime). Animated ones play in the
  background and put the lights back as they were when they end or are stopped; a new mood takes the lights over
  without a flash back. The Assistant writes one from a description ("a jazz bar"), knowing only how many lights
  there are and what they take. On the Scenes page (the rooms as chips, the moods by kind, rows that swipe on a
  phone, Stop for what plays, a calm mood saved as a scene) and over MCP (`list_moods`, `start_mood` with a mood,
  a description or a plan of the client's own, `stop_mood`).

### Changed

- homeswift.dev: the home page starts with the chat demo, the bridge's own page moves to bridge.html, and each
  language is a page of its own (`fr/`, `es/`, `pt/`); stylesheet and script addresses carry the commit, so a cache
  never pairs new pages with old files. The home page shows moods, and its demo plays Halloween or a jazz bar on its
  lights.

## [0.8.0] - 2026-10-24

### Added

- The web UI in French, Spanish (Spain) and Portuguese (Portugal), as well as English: every page, plugins' own
  pages and the server's error messages. The language follows the browser, or each user picks theirs under
  Appearance or from the flags in the account menu; it is saved with their other preferences. The Assistant
  answers in it. homeswift.dev has French, Spanish and Portuguese pages too. docs/translations.md explains the
  `t()` strings, the catalogs, and how a plugin's page translates its own.

### Changed

- Web UI on a phone: a card's ⋯ menu opens as a sheet from the bottom of the screen, never cut off at the top,
  and it and an accessory's sheet go away with a swipe down from their grabber, as the Users panel does;
  Settings is in the account menu (the tab bar has no room for it) and its pages are a row of glyphs that fits the
  width; the Status page's four figures share one row; the Accessories page's grouping and the Assistant's
  buttons show their glyphs; the Logs toolbar is two rows shorter and each line keeps its source above the text;
  notes beside a button, removal and a card head's button stack instead of squeezing the text. Search fields have
  a Search key that puts the keyboard away, without capitals or corrections, and a username no longer starts with
  a capital the phone added. On every window: Done over an accessory's sheet sits on a glass pill (white words
  were lost over a light page), Administrator in a user's form is a switch,
  the Status figures carry a glyph (Accessories and Plugins open their page), plugin cards say their accessories
  and bridge on one line, Settings' pages and the grouping have glyphs, empty pages a picture, and Sign in is the
  primary button.

### Fixed

- Plugins' own pages (UniFi Protect and Access, Govee, Elgato…) showed only their Form and JSON since 0.6.1: the
  web UI's Content-Security-Policy said `base-uri 'none'`, so browsers ignored the page's `<base>` and its scripts
  were not found. It is `base-uri 'self'` now.
- Web UI: the Status page's sections took the accessory widgets' padding and clipping, which left an empty band
  under the figures and cut the digest card's shadow; a plugin form's list (an Elgato's devices) ran off a phone's
  screen, its Remove out of reach; a page's title and line were squeezed to a word a line beside its tools on a
  window between a phone's and a laptop's (a phone in landscape, an iPad); Safari drew the open Assistant
  button's ring as a square.

- Web UI and MCP server behind Cloudflare or nginx: live log lines, accessory values and the Assistant's streamed
  answers came late. The event streams now say `Cache-Control: no-store, no-transform`, which keeps Cloudflare from
  compressing them (its Brotli held events until it had enough to compress), and `X-Accel-Buffering: no`, which
  keeps nginx and DSM's reverse proxy from buffering them. On the home network nothing changes: a line reached the
  page in under 10 ms before too.

## [0.7.0] - 2026-10-24

### Added

- Config validation against the plugins' schemas. Saving from the Config page, a plugin's Expert view or the MCP
  config tools (`update_config`, `patch_config`, `put_list_entry`) checks what the save changes in a plugin block
  against its `config.schema.json`, and the runtime's own blocks against theirs: types, bounds, the choices of a
  select, required settings (Homebridge's `required: true` too, unless the setting has a default or a condition).
  Settings left as they were are not checked, so an old mistake never stops another change. The web UI answers
  each problem with its path; **Save anyway** (`ignoreSchema` for the tools) keeps a value the plugin accepts that
  its schema does not list. A plugin's own page, pausing and restoring a backup write without the check.
- Web UI JSON editors: the line of a syntax error is marked as you type, with a message that says what is wrong
  and the same in every browser; a schema problem marks its line after a save, and **Line 12** puts the caret
  there. The plugin's JSON view checks as you type, as the Config page did, and Save waits for valid JSON.

### Changed

- Web UI: logs and JSON are on a dark surface in light mode too: the log list, JSON payloads, the Config and
  Expert JSON editors and config diffs, with the dark theme's text and colours.
- The Assistant's schema checks name a missing setting at its own place (`risk is required`, was `(root) must have
  required property 'risk'`), an extra one too (`extra is not allowed here`), and a select's allowed values.

## [0.6.1] - 2026-10-24

### Security

- Web UI: a `Permissions-Policy` that leaves pages the microphone (the Assistant's dictation) and full screen (a
  camera) and nothing else; `base-uri 'none'` and `form-action 'self'` in the content security policy;
  `X-Robots-Tag: noindex, nofollow` and a `/robots.txt` that disallows everything, for a UI published through a
  tunnel; and `Strict-Transport-Security` for a year when a trusted proxy (`trustProxy`) says the browser came over
  HTTPS. Never for the UI's own HTTPS, whose self-signed certificate a browser under HSTS would not let anyone past.

### Changed

- Web UI: text held to WCAG AA contrast (4.5:1) in light and dark. Orange words on light glass (links, the
  Administrator badge) take a deeper orange, and orange surfaces under white words (buttons, the current tab, the
  avatar) a deeper fill; the amber of "Not paired", the green of "Saved" and JSON numbers are darker in light
  mode, and dark mode gets the brighter green it lacked. The bright orange stays for borders, rings and switches.

### Fixed

- Web UI accounts: the first account is an administrator however it is added. `homeswift users add`, which the
  Synology installer runs for the first account, made an ordinary user, so a new install had no administrator and
  nobody could open Plugins, Config, Settings or Users. A bridge whose accounts have no administrator promotes the
  first one when it starts, which mends the installs made so far. `homeswift users add <name> --admin` makes a
  later account an administrator.
- Synology package and container image: the bridge runs with `MALLOC_ARENA_MAX=2`. With cameras recording to
  HomeKit Secure Video, the livestreams spread over glibc's per-thread heaps (up to eight per core), which keep
  what is freed. They also run with `MALLOC_MMAP_THRESHOLD_=131072`: glibc otherwise raises that threshold to
  the largest block freed, so once a recording has joined a camera's buffer into one block, every snapshot and
  fMP4 fragment came from a heap that kept the room between them; blocks of 128 KB and more are now mapped on
  their own and given back. On a DS1522+ with four camera feeds, the heap went from about 117 MB to 97 MB and
  the reserved address space from 2.1 GB to 390 MB. An environment that sets either keeps its own value.

## [0.6.0] - 2026-10-24

### Added

- MCP for claude.ai and the Claude apps: the web UI serves the MCP server at `/mcp` and signs clients in with
  OAuth 2.1 and the UI's accounts. Discovery (RFC 9728 and RFC 8414), open dynamic client registration
  (RFC 7591), the authorization code grant with PKCE S256, refresh tokens rotated at each use, revocation
  (RFC 7009). The sign-in page (`/oauth/authorize`) takes the UI's login and two-factor code and lets the user
  choose `read`, `control` or `admin` up to their role, which caps the app at every request. **Account ›
  Connected apps** lists and disconnects them; a new password, a two-factor change or removing the user ends
  them too. An app of a user who is not an administrator sees, as in the UI, neither the log, config.json, the
  pairings nor the child bridges' health. Only these OAuth tokens are taken at the UI's `/mcp`: the HomeswiftAiKit
  block's tokens stay on the MCP server's own listener. Tokens are kept hashed in `ui-oauth.json`. See
  docs/mcp.md, "claude.ai and the Claude apps", for the configuration and the sign-in step by step.

### Security

- MCP: a principal can hide tools, resources and prompts its scope allows, and the server refuses them as for any
  client. The web UI's chat now hides the administrator's reads from other users there too, not only from the
  list the model is shown.

### Changed

- Web UI, Users: adding or editing a user and making an API token happen in a side panel at the right, the page
  dimmed behind it (a sheet from the bottom on a phone, with a grabber); it leaves the way it came, a touch can
  swipe it away, and focus goes back to what opened it, or to the card just added or changed, lit for a moment.
  A small + beside the Users and API tokens headings opens it. The cards show the role as a badge and dates that
  fit ("24 Oct 2026", the time in the tooltip); the password gauge unfolds once there is a password; Copy says
  "Copied", or selects the token when the browser refuses.
- Web UI: on a wallpaper, a page's title, a section's heading and the text outside the cards sit on a plate of the
  header's material, readable on a light wallpaper (Sunset) as on a dark one.

### Fixed

- Web UI: an API token set to expire Never was refused ("a token expires after 1 to 3650 days, or never"). In
  Swift, `JSONValue` takes `nil` literals, so `.flatMap { $0.isNull ? nil : $0 }` gave `.null` back rather than
  nil; `JSONValue.nonNull` replaces it everywhere: an MCP request with `"params": null` is no longer refused, a
  UniFi Access door without a name is "Unknown" again, and an eWeLink light reporting no brightness starts at its
  minimum.
- Web UI: query strings are form-decoded, so a `+` written by `URLSearchParams` is a space (the Settings ›
  Audit log search with spaces in it). A script that sends a literal `+` (a time zone in `from=`) writes `%2B`.

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

[Unreleased]: https://github.com/mp-consulting/homeswift/compare/v0.18.1...HEAD
[0.18.1]: https://github.com/mp-consulting/homeswift/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/mp-consulting/homeswift/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/mp-consulting/homeswift/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/mp-consulting/homeswift/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/mp-consulting/homeswift/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/mp-consulting/homeswift/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/mp-consulting/homeswift/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/mp-consulting/homeswift/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/mp-consulting/homeswift/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mp-consulting/homeswift/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mp-consulting/homeswift/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mp-consulting/homeswift/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/mp-consulting/homeswift/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/mp-consulting/homeswift/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/mp-consulting/homeswift/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/mp-consulting/homeswift/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/mp-consulting/homeswift/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mp-consulting/homeswift/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mp-consulting/homeswift/compare/v0.2.0...v0.3.0
[0.1.0]: https://github.com/mp-consulting/homeswift/releases/tag/v0.1.0
