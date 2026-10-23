# The web UI

A `HomeswiftUI` block gives the bridge a web interface, inside the same process: status and pairing
codes, accessories with live control, each plugin's settings as a form made from its `config.schema.json`,
the raw `config.json`, and the log as it happens. It is the Config UI of a Homebridge, in Swift, with a
liquid glass look that follows the system's light or dark appearance and its reduced-motion,
reduced-transparency and increased-contrast settings.

```json
{ "platform": "HomeswiftUI", "port": 8581, "host": "0.0.0.0", "auth": "form" }
```

| Key | Default | What it does |
|---|---|---|
| `port` | `8581` | Where the UI listens |
| `host` | `0.0.0.0` | Every interface, so phones on the network can open it; `127.0.0.1` keeps it on the machine |
| `allowedHosts` | `[]` | Names the UI answers to, besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host |
| `auth` | `form` | A username and password, created on the first visit with the set-up code from the bridge's output. `none` for a trusted network or localhost only |
| `sessionDays` | `7` | How long a login lasts without activity |

Restart the bridge; the banner prints the URL and, until an account exists, a set-up code. The first visit
asks for that code, a username and a password, and creates the administrator account (the users live in
`ui-users.json` next to config.json, as salted PBKDF2 hashes; delete the file and restart to start over,
with a new code).

## Pages

- **Status**: each bridge with its device ID, port, pairing state and platforms, and, for a bridge that is
  not paired yet, the setup code and its QR code for the Home app's camera; the Assistant's provider;
  version, uptime, machine; a **Restart homeswift** button. **Activity** charts the homeswift process's
  memory and CPU, how long the bridge takes to answer the Home app's reads and writes, and how long plugins
  take to reach their devices (average and longest), over the Logs page's time ranges (from the last hour
  to 7 days, or a custom range) and, for the durations, for every server, one bridge or one accessory. A
  range that ends now refreshes every minute; a gap is a time homeswift was not running; **Show as a table**
  lists the values. The bridge samples memory and CPU every 10 seconds and keeps a record per minute under
  `metrics/` next to config.json (a file per day, 8 days), so the charts survive a restart. The view is
  `/status?since=24h&bridge=<bridge>&accessory=<accessory>`.
- **Accessories**: a wall of widgets (`widgets.js`), each accessory drawn by the widget of its kind, chosen
  from its primary service, in one of three fixed sizes on a grid of square units packed with no gaps:
  **small** (1×1, a tile a tap acts on, lit while the accessory is on), **medium** (2×1, its main control) and
  **large** (2×2). An air conditioner or thermostat has a gauge, its setpoints and modes; a purifier its mode,
  speed and air readings; a light its brightness, colours and white temperature in kelvin; a shutter its
  position, with its closed part drawn on the small tile; a valve a run button that counts down; a gate, a
  lock or an alarm its state, with **Hold to open**, **Hold to unlock** or **Hold to turn off** (on a small
  tile, the tile itself is held), while closing, locking and arming are a tap. A few positions (a fan's speeds
  in steps of 20) are bars, two to four choices a segmented control. A widget's **⋯** menu (a right click on a
  tile) opens **All controls**: every control of the accessory in a sheet, its other services as chips,
  readouts, meters and blocks, and what no widget shows under **More**, as rows; an accessory no widget knows
  gets those rows. The same menu sets the widget's size, makes it the size of every accessory of that kind
  ("Medium for every light"), identifies the accessory, shows its log, asks the Assistant about it and opens
  its plugin's settings. **Edit** shows the sizes and arrows on every widget and lets them be dragged into
  place; the accessories share **One wall** until **By plugin** gives each plugin a wall of its own. The bridge keeps
  the layout in `ui-layout.json` next to config.json (`/api/layout`), the same for every user. A change shows
  at once and goes to the device; a refusal puts the value back and says why under the name. Values update
  live when a device changes elsewhere. A characteristic a plugin marked as a security control (a switch that
  unlocks a door) is held to turn on, or asks first in a row. Values that carry keys (a camera's Setup
  Endpoints) are not shown, nor what only HomeKit uses (a camera's stream and recording setup, Adaptive
  Lighting's bookkeeping).
- **Cameras** get a card of their own: the picture in 16:9 with the name, motion, the doorbell's last ring and
  recording over it, buttons to unmute, refresh and go full screen, and the camera's controls under it. While
  the card is on screen and the page visible, it plays the live feed muted (`GET /api/cameras/<id>/live`, fMP4
  through Media Source Extensions, ManagedMediaSource on iOS Safari), when the plugin has one; otherwise a
  snapshot every 3 seconds (`/api/cameras/<id>/snapshot?width=&height=`). Off screen it fetches nothing. A camera
  has four live viewers at most, and one turned off in the Home app, or whose plugin is paused, shows nothing.
  Plugin pages can show the same view: load `/camera.js` and call `HomeswiftCamera.view({ id, name })`.
- **Plugin pages** can draw an accessory as this page does: load `/remote.js`, `/camera.js` and `/widgets.js` after
  `/common.js`, take the accessory from `/api/accessories`, add `HomeswiftWidgets.card(accessory, { size })` (`small`,
  `medium` or `large`; the kind's own size when left out) to a `.wall`, open every control with
  `HomeswiftWidgets.open(accessory)`, and call `HomeswiftWidgets.listen()` once for live values.
- **Addresses** are paths: `/status`, `/accessories`, `/plugins`, `/plugins/<slug>` and its `/expert`,
  `/plugins/add/<platform>`, `/config`, `/account`, and `/logs/<accessory>?bridge=<bridge or all>&since=24h&level=warning&q=text`
  (the accessory by its name's slug; `since` is `1h`, `6h`, `24h`, `today`, `yesterday`, `7d` or `custom` with
  `from` and `to`). A link changes the view in place, Back and Forward work, and an address can be kept or
  shared; the Logs view writes its choices into its own.
- **Plugins**: every platform block of config.json, with whether it runs, is paused, and where. Each card's
  **⋯** menu, at its bottom right like every card's, opens the plugin's page, its Expert form or JSON, pauses
  or resumes it, and removes it; its name opens its page. **Pause** (also at the top right of a plugin's page)
  stops the plugin's calls to its devices, for when an app sharing the account would be signed out by them;
  its accessories stay in the Home app, showing No Response, and the page offers **Resume**. **Open** shows a
  plugin's own page (see below): a running plugin's settings are that page, at `/plugins/<slug>` (the
  block's name in lower case, dashes for spaces: `/plugins/dyson-pure-cool`), from the Plugins list or an
  accessory's menu. Its **Expert** part, last on the page and in the card's menu, opens the whole block as a
  form built from the plugin's schema (the same `config.schema.json` the Homebridge version ships) or as JSON
  (`/plugins/<slug>/expert` or `/expert/json`); a plugin that does not run, or has no page, shows the form at
  its address, and so do the runtime's own blocks. **Add a platform** lists the plugins compiled in. The JSON view is coloured as you
  type, like the Config page; Save takes the view on screen. A certificate or key field takes a
  dropped PEM file, which the bridge checks and keeps owner-only under `files/` next to config.json. The
  runtime's own blocks, `HomeswiftUI` and `HomeswiftAiKit` (the Assistant and the MCP server), have forms too.
  **Add** on a plugin with its own page (pairing a TV, finding lights) writes an empty
  block and opens that page, as Homebridge's custom UIs do. Saving validates, backs up the previous file,
  and applies the block at once.
- **Config**: the whole file in an editor. Saving validates it, keeps a backup under `backups/`, sorts
  the keys, and applies it.
- **Logs**: the live log, filtered by level (All; Info, info and above; Warnings or Errors alone), text, time
  and what the lines are about. That last is one menu:
  every line; the bridges' own lines (their servers' connections, pairings and controllers), every bridge's or
  one's; or an accessory's (those of its own server and those that name it, its id or its address), the
  accessories grouped by plugin. The time: the latest lines, the last hour, 6 or 24 hours, today,
  yesterday, the last 7 days, or a custom range. The bridge keeps its log on disk for that, under `logs/`
  next to config.json: segments of 8 MB at most, a new one each day, the oldest removed past 64 MB or 7
  days, written in batches once a second so logging never waits for the disk. **Copy** puts the lines shown
  on the clipboard as text.

  A line that carries JSON of 160 bytes or more (a device's state, a cloud's message) shows a marker such as
  `{…} 1.4 KB` instead, in the terminal too; its **JSON** button shows the payload under it, formatted. The
  payload is kept with the line with its secrets masked (values of keys such as `password`, `token` or
  `apiKey`, and bearer tokens, JWTs and setup codes anywhere), and the text filter and the accessory menu
  look inside it. The latest lines keep their payloads in memory; **Save payloads** also writes them to the
  log on disk, so they can be read, by you or the Assistant (`search_logs` with `hours`), after the lines
  moved on or the bridge restarted. It is off until turned on, and the choice is kept in `logs/settings.json`.

## The Assistant's chat

With a `HomeswiftAiKit` block that names a provider, a sparkle **Assistant** button in the header opens a
chat, on every page, plugin pages included. Ask it what the bridge runs or why an accessory does not
answer, or tell it what to do: "add the Elgato light at 192.168.1.50", "pair my Philips TV", "turn off
every light". It looks at the setup and acts through the MCP server's tools, the plugins' own actions
included (find TVs, pair one, check a light's address; `docs/plugins.md`).

- **Every change asks first.** A tool that changes configuration or unlocks something shows a card with
  what would change (a dry run's list of settings and their new values) and waits for **Allow**; **Don't
  allow** leaves everything as it was, and a change that would fail anyway is never put to you. Writes are
  in the MCP audit log (`homeswift-mcp-audit.jsonl`) as the client `web UI chat`.
- **Secrets stay home.** A password a device hands out while pairing reaches config.json as a handle
  (`__SECRET_1__`) the model passes on without reading it; configuration it reads has `__REDACTED__`
  values, which a write restores.
- **Voice.** The mic dictates a message (tap, or hold while speaking) and the answer to a spoken message is
  read out, in the language chosen under the field (the browser's, unless you pick one; each browser keeps
  its choice). Browsers allow the microphone only on `localhost` or over HTTPS: turn on `https` below to use
  it from a phone or another computer. Safari sends the audio to Apple and Chrome to Google for recognition.
- The conversation stays while the process runs, one per user; **New chat** starts afresh. Each answer's
  cost shows under the field for priced models.

On a wide window the chat is a panel beside the page; on a phone a sheet you drag down to close.

Saving a plugin's block applies it at once: the plugin stops and starts again with the new settings on
the same accessories (their aids, iids and pairings stay), a new block starts, and a removed one leaves
HomeKit. A few changes still need a restart: the `bridge` block, the runtime's own blocks (`HomeswiftUI`,
`HomeswiftAiKit`) and child bridges (`_bridge`). The page says which, and its **Restart now** button
does it. The process replaces itself with a fresh copy (same binary, arguments and PID), so
launchd, systemd and `brew services` see nothing happen, and the page reloads once the bridge is back.
Logins survive a restart: sessions are kept in `ui-sessions.json` next to config.json.

## Security

- Every API call needs the session cookie (`HttpOnly`, `SameSite=Strict`). Mutations must be JSON and come
  from the page: a request whose `Origin` names another site, or whose `Sec-Fetch-Site` is not the page's
  own, is refused. Pages carry a content security policy (scripts, styles and media from the UI itself; `blob:`
  for the camera cards' Media Source), no-store, no framing.
- The first account needs the set-up code, so nobody else on the network can claim the bridge before its
  owner does. The code is printed at startup, never logged: the MCP log tools cannot see it.
- Passwords are hashed with PBKDF2-HMAC-SHA256 (210,000 iterations, a random salt), and verified in
  constant time. Five failed logins or set-up codes from an address slow the next attempts down.
- Requests are answered only when their `Host` is an IP address, localhost, this machine's name or an
  `allowedHosts` entry (421 otherwise), so a page that rebinds its own name to this address gets nothing,
  with `auth: none` too.
- With `"https": true` the UI serves HTTPS and the cookie carries `Secure`. Name a certificate and its key
  (`certificate`, `privateKey`, PEM files), or let the bridge make a self-signed one, kept next to
  config.json (`ui-certificate.pem`, `ui-key.pem`, owner-only): it names this machine, its `.local` name,
  `localhost`, `allowedHosts` and the LAN addresses, lasts 397 days and is made again before it expires or
  when an address changes. The banner prints its SHA-256 fingerprint, which the browser's warning shows.
  To trust it once and for all, download `/homeswift-ui.crt` and add it to the keychain (macOS: Always
  Trust), or install it on an iPhone and turn it on under Settings › General › About › Certificate Trust
  Settings. Without `https`, keep the UI on the home network or behind a reverse proxy with TLS. With
  `auth: none`, set `host` to `127.0.0.1`.
- The account is an administrator: the Config page shows config.json as it is, secrets included, the way
  Config UI X does. The MCP server's redaction rules are for models, not for the person who owns the file.

## For plugin authors

**A settings form.** Ship a `config.schema.json` in the plugin's directory and run `swift
Scripts/embed-assets.swift plugin Plugins/<Name> <Type>` to embed it (a test checks it is current); the
Plugins page then shows a form. The
form understands the Homebridge dialect: `properties` in order, `required: true` on a property, `oneOf`
with `enum` and `title` for menus, `placeholder`, `default`, `description`, arrays of objects or of
values, nested objects, and the top-level `layout` with `fieldset` groups. Keys the schema does not know
(`_bridge` for one) are kept as they are.

**A page of its own.** A plugin that has more to show than settings (the devices it sees, a scan, a
diagnostic) ships a `Web/` directory with an `index.html` and whatever files it needs, embedded by `swift
Scripts/embed-assets.swift web Plugins/<Name>/Web Plugins/<Name>/Sources/WebFiles.swift <Type>` (a test
checks it is current). The UI serves each instance's page at `/plugins/<slug>` and its files beside it, to
signed-in users only (anyone else gets the sign-in page, then this one); the page gets a `<base>` for its
relative files and a `<meta name="homeswift-plugin">` naming its platform and instance, which `plugin.js`
reads. The page is a full document: link `/style.css` for the look of the rest of the UI, then `/common.js` and
`/plugin.js` for the helpers. The content security policy allows scripts and styles from files only, no
inline script.

The page talks to its instance through `homeswift.request(path, { method, body })`, which sends
`/api/plugins/<platform>/<name>/<path>` with the session cookie and parses the JSON answer; the plugin
answers in `handleWebRequest(_:)` with a `PluginWebResponse` (JSON and a status). `homeswift.el(tag,
attributes, ...children)` and `homeswift.$(selector)` build and find elements the way the UI's own pages
do, `homeswift.tile(icon, tone)` draws an icon on a colour and `homeswift.fact(label, value)` a labelled value of a
`.facts` grid; `homeswift.platform`, `homeswift.name` and `homeswift.home` (the Plugins page) are there too.
Mutations must be JSON, like the rest of the API. `homeswift.act(button, work, report)` runs `work` with the button
disabled and a spinner, and hands an error's message to `report` (`alert` by default); with `report` null the error
is thrown to the caller instead.

The instance's own block of config.json is `homeswift.readBlock()` and `homeswift.updateBlock(change)`
(`GET`/`PUT /api/config/block/<platform>/<name>`): a write applies at once, and the plugin reloads. For a
block with a `devices` list keyed by MAC address there are `updateDevices`, `updateDevice`, `putDevice` and
`findDevice`; `poll(refresh)` refreshes while the page is visible, and `renderKeyed` redraws only the cards
whose item changed. `Plugins/ElgatoKeyLights/Web` is the example: the lights the instance knows, their state,
and an Identify button.

The UI's own pages are plain HTML, CSS and JavaScript under `Sources/HomeswiftUI/Web`, embedded into the
binary by `swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift`,
so a Homebrew install carries them and no build step needs Node.

## Passwords

The first account and every password change follow the ANSSI's recommendations (*Recommandations relatives à
l'authentification multifacteur et aux mots de passe*, PG-078, 2021): at least 12 characters and about 85 bits of
estimated entropy, the guide's "moyen à fort" level for a 90-character set (table 3), with no maximum short of
1024 bytes. The estimate is the guide's length × log₂(character set); since the guide warns it only holds for
random characters, repeated or sequential characters, common words and the username earn nothing. The server
checks (`PasswordPolicy`); the pages show a gauge with the guide's bands (65, 85, 100 bits) while you type. A
passphrase of several random words is the easy way over the bar. **Account**, behind your name in the header,
changes the password; the other browsers signed in as you are then signed out.

## Working on the pages

The pages are compiled into the binary (`Sources/HomeswiftUI/WebAssets.swift` and each plugin's
`Sources/WebFiles.swift`, made by `Scripts/embed-assets.swift`). To work on them without a rebuild, point
`HOMESWIFT_WEB_ROOT` at the checkout:

```sh
HOMESWIFT_WEB_ROOT=$PWD swift run --scratch-path ~/Library/Caches/homeswift-build homeswift
```

The UI then reads `Sources/HomeswiftUI/Web` and `Plugins/<platform>/Web` from disk on every request, and open
pages follow the files: a saved stylesheet swaps in place (what is open on the page stays), a saved script or
page reloads it. Embed the files again before committing; a test fails while they differ.

