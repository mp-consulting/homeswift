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
  `/status?since=24h&bridge=<bridge>&accessory=<accessory>`. With the Assistant on, a **Daily digest** says
  what needs attention today, from the day's warnings and errors and the accessories: **Write today's
  digest** streams it, the bridge keeps it for the day (`ai-digest.json`, owner-only), and the card's **⋯**
  writes it again. **Customise this page**, at the bottom, shows or hides each part (overview, digest,
  activity, bridges, system) and orders them; the layout is each user's own, on every browser.
- **Accessories**: every accessory with its services, a section per plugin. Switches for on/off, sliders for brightness, colour
  temperature and the like, menus for lock, door and alarm targets, text for everything else. Values
  update live when a device changes elsewhere. Locks, garage doors and alarms can be operated here, as in
  the Home app, since the user signed in; a change to one of them, or to a characteristic a plugin marked as a
  security control (a switch that unlocks a door), asks first. Values that carry keys (a camera's Setup
  Endpoints) are not shown. Each card's **⋯** menu identifies the accessory, shows its log,
  asks the Assistant about it, and opens its plugin's settings. What only HomeKit uses (a camera's stream and
  recording setup) stays off the cards.
- **Cameras** get a card of their own: the picture in 16:9 with the name, motion, the doorbell's last ring and
  recording over it, buttons to unmute, refresh and go full screen, and the camera's controls under it. While
  the card is on screen and the page visible, it plays the live feed muted (`GET /api/cameras/<id>/live`, fMP4
  through Media Source Extensions, ManagedMediaSource on iOS Safari), when the plugin has one; otherwise a
  snapshot every 3 seconds (`/api/cameras/<id>/snapshot?width=&height=`). Off screen it fetches nothing. A camera
  has four live viewers at most, and one turned off in the Home app, or whose plugin is paused, shows nothing.
  Plugin pages can show the same view: load `/camera.js` and call `HomeswiftCamera.view({ id, name })`.
- **Addresses** are paths: `/status`, `/accessories`, `/plugins`, `/plugins/<slug>` and its `/expert`,
  `/plugins/add/<platform>`, `/config`, `/account`, `/appearance`, and `/logs/<accessory>?bridge=<bridge or all>&since=24h&level=warning&q=text`
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
  type, like the Config page; Save takes the view on screen. The form follows the schema's `condition`s
  (`functionBody` or an expression, as Homebridge's form reads them): a field shows only when its condition
  holds for the block or, in a list, for its entry (`arrayIndices`). The page runs no code from the schema: it
  reads the part of JavaScript conditions use (`model.a.b`, `[arrayIndices]`, literals, `.includes()`, `!`,
  comparisons, `&&`, `||`), and shows a field whose condition it cannot read. With the Assistant on, **Describe
  your setup** above the form writes the block from a sentence and the plugin's schema; the change shows as a
  diff, and **Use it** puts it in the form to review and save (passwords and tokens never reach the provider). A certificate or key field takes a
  dropped PEM file, which the bridge checks and keeps owner-only under `files/` next to config.json. The
  runtime's own blocks, `HomeswiftUI` and `HomeswiftAiKit` (the Assistant and the MCP server), have forms too.
  **Add** on a plugin with its own page (pairing a TV, finding lights) writes an empty
  block and opens that page, as Homebridge's custom UIs do. Saving validates, backs up the previous file,
  and applies the block at once.
- **Config**: the whole file in an editor. Saving validates it, keeps a backup under `backups/`, sorts
  the keys, and applies it.
- **Logs**: the live log, filtered by level, text, time and what the lines are about. That last is one menu:
  every line; the bridges' own lines (their servers' connections, pairings and controllers), every bridge's or
  one's; or an accessory's (those of its own server and those that name it, its id or its address), the
  accessories grouped by plugin. The time: the latest lines, the last hour, 6 or 24 hours, today,
  yesterday, the last 7 days, or a custom range. The bridge keeps its log on disk for that, under `logs/`
  next to config.json: segments of 8 MB at most, a new one each day, the oldest removed past 64 MB or 7
  days, written in batches once a second so logging never waits for the disk. **Copy** puts the lines shown
  on the clipboard as text. **Diagnose** (Log Doctor, with the Assistant on) sends the lines shown, the latest
  3,000, to the Assistant, which groups the issues with their causes and fixes as it writes; secrets and
  addresses are masked first. The **⋯** menu downloads the range shown, or the whole log for the latest lines,
  as a text file, and **Empty the log** removes every line, in memory and on disk, after asking (the MCP
  server's `truncate_logs`, admin-only, does the same).
- **Appearance** (`/appearance`, from Account): the theme (automatic, light or dark), a wallpaper behind the
  glass (one of the UI's or an image of your own, scaled down and kept under `ui-wallpapers/`) and whether
  temperatures show in °C or °F, on accessory cards and plugin pages. Each user's own, kept in
  `ui-preferences.json` (owner-only) and applied on every browser they sign in to; a browser remembers the
  last ones it saw so a page opens in them at once.
- **The Assistant's settings**: the HomeswiftAiKit block's page has, above its form, **Test connection**
  (a one-word request with the form's settings, saved or not), what the Assistant used today and this month
  against its budgets, by model and by user, and **Edit the budgets**, saved with the block.

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
- **Conversations are kept**, per user, in `ui-chats.json` (owner-only): the open one, which a reload, another
  browser or a restart finds, and the ten before it. **New chat** files the open one away; **Earlier chats**
  (the clock) lists them and opens one again where it was, the Assistant remembering it, or forgets one. Each
  answer's cost shows under the field for priced models.
- **Cmd+K** (Ctrl+K elsewhere) opens and closes the chat from any page.

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
  own, is refused. Pages carry a content security policy (scripts, styles, media and the web app manifest from
  the UI itself; `blob:` for the camera cards' Media Source), no-store, no framing.
- The Assistant's requests from pages are limited to 20 a minute per user (Glass UI's limit, then 429 with
  `Retry-After`), stop at the HomeswiftAiKit block's budget, and count in its usage for the signed-in user.
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

## On a phone's home screen

The UI is an installable web app: `manifest.webmanifest` (standalone, starting on Status), PNG icons (192, 512
and a maskable 512) and an `apple-touch-icon.png`, all served without a session like the other static files.
In Safari, Share › Add to Home Screen; in Chrome, Install app. It opens full screen with the tab bar at the
bottom. There is no service worker: the bridge must be reachable to use it.

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

**The Assistant from a page.** `homeswift.assistant()` says whether it is on. `homeswift.explain({ error,
context, device })` is an Explain button whose answer streams into a card; `homeswift.ask(prompt, { context,
onChunk, signal })` asks a question and resolves to `{ text, model }`, with `onChunk(text)` for each piece as it
is written and an `AbortController`'s signal to stop it. Both carry the plugin's `assistantBackground`
(`POST /api/assistant/explain` and `/ask`; with a `requestId` in the body the answer comes as server-sent
events, `start`, `chunk`, then `done` or `error`, and `POST /api/assistant/cancel` with that `requestId` stops
it, homebridge-ai-kit's `/ai/*` routes and `ai:chunk` events). `homeswift.formatTemperature(celsius)` shows a
temperature in the user's unit (`homeswift.temperature(celsius)` gives `{ value, unit }`).

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

