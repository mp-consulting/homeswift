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
| `trustProxy` | none | Reverse proxies (addresses, CIDR ranges, or `loopback`, `linklocal`, `uniquelocal`) whose `X-Forwarded-For` and `X-Forwarded-Proto` count |
| `scheduledRestartCron` | none | Restart homeswift on a schedule: a cron expression of five fields, `0 4 * * 1` for Mondays at 4:00; the settings form sets it as a time and days |
| `scheduledBackupDisable` | `false` | Turns off the daily backup of the instance |
| `scheduledBackupPath` | `instance-backups` next to config.json | Where backups are kept: a folder that exists, a network share for a copy off the machine |
| `scheduledBackupDays` | `7` | How many days daily backups are kept |

Restart the bridge; the banner prints the URL and, until an account exists, a set-up code. The first visit
asks for that code, a username and a password, and creates the administrator account (the users live in
`ui-users.json` next to config.json, as salted PBKDF2 hashes; delete the file and restart to start over,
with a new code). More users are added on the **Users** page (see below).

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
  writes it again; any user reads today's digest, an administrator writes it. **Customise this page**, at the bottom, opens the same pop-up menu as accessory actions, with switches to show or hide each part (overview, digest,
  activity, bridges, system) and drag handles on the left to reorder them. Changes apply immediately without a page reload; the layout is each user's own, on every browser.
  When GitHub has a newer release, a card under the summary says
  so, with its notes and how to upgrade this install: the `.spk` to download on a Synology NAS, the image tag
  to pull in Docker, `brew upgrade` or the tag to check out. The bridge asks GitHub's API a minute after it
  starts and then twice a day, sending only its version (`ReleaseWatcher`); `"checkForUpdates": false` in the
  `HomeswiftUI` block turns it off. It never upgrades itself.
- **Accessories**: a wall of widgets (`widgets.js`), each accessory drawn by the widget of its kind, in a fixed
  box of the size chosen for it: small (1×1, a tile a tap acts on), medium (2×1) or large (2×2). A widget's
  **⋯** menu (a right click on a tile) sets its size or its kind's, opens **All controls** (every control in a
  sheet, the rest under More), identifies the accessory, shows its log, asks the Assistant about it, opens its
  plugin's settings (administrators), resumes a paused plugin, puts the accessory in a room, names it for these
  pages, adds it to the Quick Controls or hides it, and, for an accessory whose plugin records an Eve history
  (temperature, humidity, power…), charts it over a day, a week or four weeks (**History**). **Edit** shows grid guides, size controls and corner resize handles, and lets tiles be
  dragged into place; **One wall** (the default), **By room** (once there are rooms) or **By plugin**. The bridge keeps the layout in
  `ui-layout.json` next to config.json (`/api/layout`), the same for every user. Opening, unlocking and disarming
  are held; a shutter's tile slides; a light with Adaptive Lighting has a sun swatch that turns it off or resumes
  the Home app's schedule. A paused plugin's accessories are drawn striped, their controls out of reach; an accessory whose device does not
  answer says No Response. A change
  shows at once and goes to the device; a refusal puts the value back and says why. Values that carry keys (a
  camera's Setup Endpoints) are not shown, nor what only HomeKit uses. Temperatures show in the unit chosen on
  the Appearance page. [widgets.md](widgets.md) has it all, with
  screenshots and what a plugin does to get good widgets.
- **Accessories › Graph** (`/accessories/graph`; the page's tabs are **Wall** and **Graph**): a radial
  graph of homeswift at the centre,
  each bridge an icon on the first ring, its plugins on the second, each device type on the third, and each accessory
  a disc on the outer ring with its icon, each plugin's branch in a colour of its own (the legend lists them); names are in the tooltips and cards, and the icons
  of a ring are spaced so that they never overlap. Click a bridge or plugin to zoom into its branch;
  Ctrl-scroll, a trackpad pinch, a touch pinch, drag and the zoom buttons move the view. Click any node for a card
  with its facts and readings (grouped by service, each with a tooltip saying what it is), and its accessories, each a click from its own card (on a phone the card sits
  under the graph). A search field and a Filters menu (unavailable, bridges, device types) redraw the graph with what
  matches. A table shows the same rows.
- **Accessory groups**: **Create group** opens a two-column picker: available accessories on the left, selected
  members on the right, with search and device-type filters. In Edit mode, hold a compatible tile over another
  tile's centre and drop to start a group. Groups expose shared writable controls; they are not HomeKit accessories.
  Their menu edits membership or ungroups the devices. **No Response** reveals unavailable individual members.
  [The grouping guide](widgets.md#accessory-groups) describes supported devices and storage.
- **Natural Lighting**: a light with writable colour temperature and no bridge Adaptive Lighting controller can
  follow Homeswift's own daily schedule. It leaves power and brightness alone and pauses on manual colour changes.
  Wingman reports the current white temperature in kelvin; it cannot confirm or enable Apple's Adaptive Lighting.
- **Cameras** get a card of their own: the picture in 16:9 with the name, motion, the doorbell's last ring and
  recording over it, buttons to unmute, refresh and go full screen, and the camera's controls under it. While
  the card is on screen and the page visible, it plays the live feed muted (`GET /api/cameras/<id>/live`, fMP4
  through Media Source Extensions, ManagedMediaSource on iOS Safari), when the plugin has one; otherwise a
  snapshot every 3 seconds (`/api/cameras/<id>/snapshot?width=&height=`). Off screen it fetches nothing. A camera
  has four live viewers at most, and one turned off in the Home app, or whose plugin is paused, shows nothing; one
  that sends no picture shows television snow behind its message (a still frame under reduced motion).
  Plugin pages can show the same view: load `/camera.js` and call `HomeswiftCamera.view({ id, name })`.
- **Rooms** (Glass UI's accessory layout): a card's **⋯** menu puts the accessory in a room (a new name adds
  the room), gives it a name for these pages (the Home app keeps its own), adds it to the Quick Controls, or
  hides it. The wall then groups by room (**By room**, kept with the wall's layout);
  hidden accessories stay out unless **Show hidden** (`?hidden=1`). Accessories mirrored from another controller (the
  Home app's, through the Wingman plugin) carry a small house badge, sit in the room that controller gives them until
  they are given one here, and get a filter of their own: the **Apple Home icon switch** (`?from=Apple%20Home`), with a count and explanatory tooltip. The layout is the bridge's, shared by every
  user, in `accessory-layout.json` next to config.json (owner-only; `/api/rooms`); the Home app never sees it, but the MCP
  tools do: `list_accessories` and `set_accessories` filter by these rooms. With the Assistant on, **Suggest
  rooms** asks it for rooms and clearer names for every accessory (`AssistantService.suggestOrganization`; the ids
  reach the model as aliases) and shows them to review: untick what you do not want, then **Apply** saves the
  rooms and the names as display names. Accessories it finds odd are listed as advice.
- **Quick controls**: the favourite accessories, by room, and a button per scene, at the top of the Status page
  and on their own at `/quick` (a page to keep on a phone's home screen).
- **Moods** (on the Scenes page): the rooms that have lights as chips, and the collection of moods by kind, each
  drawn with its colours; a tap plays one on the room's lights, and the pill stays lit while it plays, with the mood
  and a **Stop** under the rooms; a calm mood shows there with **Undo** for 12 hours, which puts the lights back as they
  were. With the Assistant on, a box writes a mood from a description ("a jazz bar"). A
  mood that sets the lights once can be saved as a scene (an administrator's). On a phone each kind is a row that
  swipes sideways, so the whole card fits a screen. Playing and stopping moods is controlling accessories, as
  running a scene is. `MoodLibrary` is the collection; MCP clients use `list_moods`, `start_mood` and `stop_mood`.
- **Scenes** (`/scenes`, Glass UI's scenes): accessory values set together, by hand or by triggers: a time of day
  on chosen days, sunrise or sunset with an offset (from -12 to +12 hours), a characteristic change (the motion
  sensor turns on), or a cron expression (`30 7 * * 1-5`; five fields, or six with seconds, which are ignored).
  Conditions hold an automatic run back: a time window (`sunset` to `23:00`, across midnight too) or a
  characteristic's value; a run by hand ignores them. Sunrise and sunset come from Glass UI's equation for the
  location set on the page (typed, or this device's position). **Add an accessory as it is now** fills the actions
  from its current values. Automations run on the minute; a characteristic trigger runs a scene at most once per 5
  seconds. Kept in `scenes.json` next to config.json (owner-only), with each scene's last run. **Locks, garage
  doors and alarms** keep Homeswift's rule: a person confirms them. Glass UI sets them like any value, by hand and
  from automations; here the page asks before running a scene that has them, the MCP server's `run_scene` refuses
  such a scene (as homebridge-mcp-server's does), and automations, with nobody to ask, leave those actions out and
  say so in the scene's last run.
- Webhook delivery supports **Bearer token** or **Basic authentication**, plus custom HTTP headers. Header values and
  credentials are masked when read back; leave `********` unchanged to preserve them. Remove a header row to delete it.
  The payload remains a JSON POST; transport headers and conflicting Authorization headers are rejected.

- **Notifications** groups delivery channels in cards, with setup fields under **Settings**, event switches, and a persistent Save bar.
  ![Notification delivery channels and event switches](images/notifications.png)

  Notifications (`/notifications`, from the Status page; Glass UI's notifications): a webhook (a JSON POST
  with event, title, message, instance and timestamp), ntfy (ntfy.sh or your own server, with an access token),
  Pushover, Telegram, and Web Push to the browsers that turn it on. Events: homeswift started (not after a restart
  it made itself) and stopped, a plugin logged an error, an accessory answered No Response for 5 minutes while its
  plugin is not paused, an automation failed, the daily backup failed or (off until turned on) was saved, and the
  Assistant's daily digest at a time of your choice (off until turned on: it uses the provider's quota). Glass UI's
  update and rollback events have no Homeswift counterpart: plugins are compiled in. The same event about the same thing
  goes once per 15 minutes, 12 notifications an hour at most, 5 tests a minute. Each channel's card sends a test.
  The settings live in `notifications.json` next to config.json (owner-only), not in config.json: tokens, keys and
  the webhook URL come back to the page as `********` (sent back unchanged, they keep the stored value), and
  neither `get_config` nor the Assistant ever reads them. Web Push: the bridge makes its VAPID key pair the first
  time a browser asks and keeps it in that file; the page registers `/sw.js`, a service worker that only shows
  the notifications and opens the page one is about (the content security policy allows it: same origin).
  Browsers allow it over HTTPS or on localhost only; iOS needs the page added to the home screen.
- **Plugin pages** can draw an accessory as this page does: load `/remote.js`, `/camera.js` and `/widgets.js` after
  `/common.js`, take the accessory from `/api/accessories`, add `HomeswiftWidgets.card(accessory, { size })` (`small`,
  `medium` or `large`; the kind's own size when left out) to a `.wall`, open every control with
  `HomeswiftWidgets.open(accessory)`, and call `HomeswiftWidgets.listen()` once for live values.
- **Addresses** are paths: `/status`, `/accessories` (and `/accessories/graph`), `/quick`, `/scenes` (and `/scenes/<id>`, `/scenes/new`),
  `/notifications`, `/plugins`, `/plugins/<slug>` and its `/expert`,
  `/plugins/add/<platform>`, `/config`, `/account`, `/appearance`, `/users`, `/settings` (which opens `/settings/bridge`) and its `/bridge`, `/child-bridges`, `/backups`, `/assistant` and
  `/audit?since=7d&outcome=failed&tool=…&client=…`, and `/logs/<accessory>?bridge=<bridge or all>&plugin=<plugin>&since=24h&level=warning&q=text` (`bridge` and `plugin` are not both given: 400)
  (the accessory by its name's slug, or its id; the plugin by its slug, and `/logs/<platform>` from a plugin's page; `since` is `1h`, `6h`, `24h`, `today`, `yesterday`, `7d` or `custom` with
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
  comparisons, `&&`, `||`), and shows a field whose condition it cannot read. A boolean with
  `"x-schema-form": { "invert": true }` shows its switch on while the value is false, for a key that turns
  something off under a title that turns it on (the web UI's daily backup). With the Assistant on, **Describe
  your setup** above the form writes the block from a sentence and the plugin's schema; the change shows as a
  diff, and **Use it** puts it in the form to review and save (passwords and tokens never reach the provider). A certificate or key field takes a
  dropped PEM file, which the bridge checks and keeps owner-only under `files/` next to config.json. The
  runtime's own blocks, `HomeswiftUI` and `HomeswiftAiKit` (the Assistant and the MCP server), have forms too.
  **Add** on a plugin with its own page (pairing a TV, finding lights) writes an empty
  block and opens that page, as Homebridge's custom UIs do. Saving validates, backs up the previous file,
  and applies the block at once. The JSON view marks the line of a syntax error as you type, and Save waits
  until it is fixed. A save also checks what it changes against the plugin's schema (a type, a bound, a choice
  outside the list, a required setting): the problems show under the editor with their lines marked, **Line
  12** puts the caret there, and **Save anyway** keeps a value the plugin accepts that its schema does not
  list. Settings left as they were are not checked, so an old mistake never stops another change; a plugin's
  own page and **Pause** write without the check.
- **Config**: the whole file in an editor. Saving validates it, checks each plugin block's changes against
  its schema as the Expert view does, keeps a backup under `backups/`, sorts the keys, and applies it. A
  syntax error's line is marked as you type. A block that spans lines folds from the chevron beside its first line
  (Option-click folds or opens every block at that indentation; ⌘⌥[ and ⌘⌥] at the caret), and a click on its ⋯
  opens it; what is saved, copied or formatted is always the whole text. A plugin's JSON block folds the same way.
- **Settings**, for administrators, after the Homebridge UI's settings, child bridges, config backups and
  restart pages:
  - **Bridge** (`/settings/bridge`, where `/settings` opens): config.json's `bridge` block as a form (name, port, setup code, manufacturer, model, firmware;
    saving restarts homeswift; the device ID stays), the network (the addresses, the advertiser), each
    server's HomeKit pairing with **Reset pairings…** in its ⋯ menu, the cached accessories (stale ones
    first) with **Remove from the cache…** and **Reset every cache…**, and a link to the schedules and proxy
    settings of the HomeswiftUI block. Homeswift listens and advertises on every interface with the system's
    mDNS (Bonjour, or Avahi on Linux): there is no interface to bind or advertiser to choose, as Homebridge's
    `bind` and `advertiser` settings do, and no Node-specific setting (environment, debug mode, keep orphans).
  - **Child bridges**: each with its status, uptime, restarts, the plugins that did not start and why, and,
    until the Home app has it, its setup code and QR code; its ⋯ menu restarts, stops or starts it, shows
    its log, and resets its pairings.
  - **Backups**: **Download a backup** makes an archive of the instance (a tar: config.json, each bridge's
    HomeKit identity and pairings, the accessory caches, the plugins' files under `plugins/`, `files/`, the
    web UI's users and certificate, the MCP audit log); left out, at any depth, as upstream does: the
    backups, `logs/`, `metrics/`, the web UI's sessions and what other systems put there (`node_modules`,
    `.git`, `@eaDir`…), and files over 10 MB. **Back up now** keeps one in the backup folder, as the daily
    backup does at a random time before 7:00 (unless `scheduledBackupDisable`), removing this bridge's
    older than `scheduledBackupDays`. Each kept one downloads, restores or goes. **Restore a backup** takes
    one (dropped or chosen, 64 MB at most): the bridge checks it whole (its `info.json`, a config.json that
    runs, only plain files under relative paths: links, devices, absolute paths and `..` are refused), stages
    it in `.restore-pending/` and restarts; the new process puts the files in place before it reads anything,
    keeping this machine's bridge and web UI ports. Files the backup does not have stay. The config.json
    backups each save keeps (the last 20) are listed too, each compared with the file as it is (a diff) or
    restored.
  - **Audit log**: the MCP audit log (`homeswift-mcp-audit.jsonl`): every write of MCP clients and of the
    Assistant's chat, and every change made in this UI (client `web UI`, the user, the route, a small body
    with its secrets masked), newest first, filtered by time, outcome, tool and client. `auditLog: false` in
    the MCP block turns it off.
- **Logs**: the live log, filtered by level (All; Info, info and above; Warnings or Errors alone), text, time
  and what the lines are about. That last is one menu:
  every line; the bridges' own lines (their servers' connections, pairings and controllers), every bridge's or
  one's; a plugin's own lines (its pairing, devices, clouds and errors: the lines it writes); or an accessory's
  (those of its own server and those that name it, its id or its address), the accessories grouped by plugin. The time: the latest lines, the last hour, 6 or 24 hours, today,
  yesterday, the last 7 days, or a custom range. The bridge keeps its log on disk for that, under `logs/`
  next to config.json: segments of 8 MB at most, a new one each day, the oldest removed past 64 MB or 7
  days, written in batches once a second so logging never waits for the disk. **Copy** puts the lines shown
  on the clipboard as text. **Diagnose** (Log Doctor, with the Assistant on) sends the lines shown, the latest
  3,000, to the Assistant, which groups the issues with their causes and fixes as it writes; secrets and
  addresses are masked first. The **⋯** menu downloads the range shown, or the whole log for the latest lines,
  as a text file, and **Empty the log** removes every line, in memory and on disk, after asking (the MCP
  server's `truncate_logs`, admin-only, does the same).
- **Appearance** (`/appearance`, from Account): the theme (automatic, light or dark), a wallpaper behind the
  glass (one of the UI's or an image of your own, scaled down and kept under `ui-wallpapers/`), whether
  temperatures show in °C or °F, on accessory cards and plugin pages, and the language: English, French,
  Spanish or Portuguese, or Automatic, the browser's ([translations.md](translations.md)). The Assistant answers
  in it. Each user's own, kept in
  `ui-preferences.json` (owner-only) and applied on every browser they sign in to; a browser remembers the
  last ones it saw so a page opens in them at once.
- **Settings › Assistant** (`/settings/assistant`): **Test connection** (a one-word request with the saved
  HomeswiftAiKit block), what the Assistant used today and this month against its budgets, by model and by
  user, and **Edit the budgets**, written to the block. The block's own page has the same card above its form,
  where the test takes the form's settings, saved or not, and the budgets are saved with the form.

## Users, roles and API tokens

As in Glass UI, a user is an **administrator** or not. An administrator does everything. Any other user sees
**Status** (without the pairing codes and the restart button) and **Accessories**, controls accessories
(locks, garage doors and alarms included, asking first as for everyone), uses the Assistant's chat with its
read-only tools, and changes their own password and two-factor authentication; the plugins, their pages and
settings, config.json, the log, pairing codes, restarts, users and tokens are refused with a 403, whatever the
page shows. The role is read at every request, so a change applies at once. The first account is an
administrator, and so is the account of a `ui-users.json` from before roles.

**Users** (`/users`, in the account menu for administrators, and from **Account**) shows a card per user: their name,
username, role, whether two-factor authentication is on, and a **⋯** menu to edit them (the name shown, the
role, a new password, which signs them out everywhere) or remove them (signed out at once). **Add user** asks
for a username, a name and a password (the same rules as everyone's). The last administrator can be neither
removed nor demoted.

**Two-factor authentication**, under **Account**: **Set up** shows a QR code and the key for an authenticator
app (Passwords on iPhone and Mac, Google Authenticator, 1Password…; TOTP after RFC 6238: SHA-1, 6 digits,
30 seconds), and the app's first code turns it on; the user's other browsers are then signed out. Signing in
then asks for the app's code after the password; each code works once, and one step of clock drift either way
is allowed. **Turn off** takes the password. The secret is kept with the user in `ui-users.json`
(owner-only) and never logged. As in Glass UI, only its user turns it off: someone who lost the app is removed
and added again by an administrator, and the last administrator deletes `ui-users.json` and restarts.

**API tokens**, on the Users page, are for scripts: a name, a scope and an expiry (never, 30 or 90 days, a
year). The token (`hst_…`) is shown once; the bridge keeps its SHA-256 in `ui-api-tokens.json` (owner-only),
with when it was made, by whom and when it was last used. Send it as `Authorization: Bearer hst_…` to `/api/*`:

```sh
curl -H "Authorization: Bearer $HOMESWIFT_TOKEN" http://bridge.local:8581/api/accessories
```

A `read` token reads what any user may (status, accessories, plugins list, metrics, cameras, events); an
`admin` token does what an administrator does, except managing accounts: a token names no account, so it
cannot change passwords, two-factor authentication, users or tokens. Requests with a token need no `Origin`
(no cookie rides along, so no other site can make them), but bodies are still JSON. **⋯ › Revoke** refuses
the token at once.

The Assistant (Explain, Describe your setup, the chat) takes 20 requests a minute per user, as Glass UI's
limit; past that the bridge answers 429 with a `Retry-After`. Its usage (`ai-usage.json`, `homeswift usage`)
is counted per user.

User management is not an MCP tool: a model never creates accounts or tokens.

**Connected apps**, under **Account**: with the MCP server on, the UI also serves it at `/mcp` for clients that
sign in with OAuth, claude.ai and the Claude apps first (see [docs/mcp.md](mcp.md#claudeai-and-the-claude-apps)).
They send the user to `/oauth/authorize`, which signs in with the UI's login (two-factor code included) and asks
what the app may do, up to the user's role. The card gives the address to add as a custom connector, lists
the apps the user allowed, what each may do and when it last came, and its **⋯ › Disconnect** ends one at once.

  A line that carries JSON of 160 bytes or more (a device's state, a cloud's message) shows a marker such as
  `{…} 1.4 KB` instead, in the terminal too; its **JSON** button shows the payload under it, formatted. The
  payload is kept with the line with its secrets masked (values of keys such as `password`, `token` or
  `apiKey`, and bearer tokens, JWTs and setup codes anywhere), and the text filter and the accessory menu
  look inside it. The latest lines keep their payloads in memory; **Save payloads** also writes them to the
  log on disk, so they can be read, by you or the Assistant (`search_logs` with `hours`), after the lines
  moved on or the bridge restarted. It is off until turned on, and the choice is kept in `logs/settings.json`.

## The Assistant's chat

With a `HomeswiftAiKit` block that names a provider, a sparkle button in the header, beside the account menu, opens a
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
The restart button opens an in-page confirmation. While the bridge restarts, a modal with a blurred backdrop
blocks controls. The browser polls `/api/status`, then fades the overlay and reconnects the event stream without
reloading the page. A failed recovery offers Try again. The CLI normally shuts down and uses `execv` to replace
itself with the same arguments; a 30-second watchdog forces replacement if shutdown stalls. This fallback is not
evidence that the underlying shutdown problem has been resolved. A failed `execv` exits with status 1, so recovery
in that case depends on an external service manager.

Settings checks a candidate HomeKit port before saving; an empty field selects an automatic port. The HomeswiftUI
form also checks its listening address and port. These checks describe availability at the time of the probe;
another process can claim the port before restart.

Logins survive a restart: sessions are kept in `ui-sessions.json` next to config.json.

## Security

- Every API call needs the session cookie (`HttpOnly`, `SameSite=Strict`) or an API token. Mutations must be
  JSON and, with the cookie, come from the page: a request whose `Origin` names another site, or whose
  `Sec-Fetch-Site` is not the page's own, is refused. Pages carry a content security policy (scripts, styles, media and the web app manifest
  from the UI itself; `blob:` for the camera cards' Media Source; no `<base>`, forms posting only to the UI),
  no-store, no framing, `nosniff`, no referrer, and a permissions policy that leaves the UI the microphone (the
  Assistant's dictation) and full screen (a camera) and nothing else: no camera, location, payment, USB or sensors.
- The UI asks search engines to keep away: `X-Robots-Tag: noindex, nofollow` on every reply and a `/robots.txt`
  that disallows everything, for a UI published through a tunnel or a proxy.
- The Assistant's requests from pages are limited to 20 a minute per user (Glass UI's limit, then 429 with
  `Retry-After`), stop at the HomeswiftAiKit block's budget, and count in its usage for the signed-in user.
- The first account needs the set-up code, so nobody else on the network can claim the bridge before its
  owner does. The code is printed at startup, never logged: the MCP log tools cannot see it.
- Passwords are hashed with PBKDF2-HMAC-SHA256 (210,000 iterations, a random salt), and verified in
  constant time. Five failed logins, two-factor codes, current passwords or set-up codes from an address slow
  the next attempts down; being asked for the code is not a failure.
- Requests are answered only when their `Host` is an IP address, localhost, this machine's name or an
  `allowedHosts` entry (421 otherwise), so a page that rebinds its own name to this address gets nothing,
  with `auth: none` too.
- Behind a reverse proxy, `trustProxy` names it: only a request from one of those addresses may say who the
  client is (`X-Forwarded-For`, the right-most address that is not a trusted proxy: for the login throttle and
  the log) and that the browser came over HTTPS (`X-Forwarded-Proto`, for a `Secure` cookie, and
  `Strict-Transport-Security` for a year: the proxy holds a real certificate). Never every
  address: a client could pick its own and step around the throttle. Add the proxy's host name to
  `allowedHosts`. The event streams (the live log, accessory values, the Assistant's answers, `/mcp`) say
  `Cache-Control: no-store, no-transform` and `X-Accel-Buffering: no`, so a proxy that compresses
  (Cloudflare) or buffers (nginx, DSM's reverse proxy) passes each event on as it comes instead of holding it.
- `/mcp`, `/oauth/*` and `/.well-known/oauth-*` answer only with the MCP server on. Their tokens reach `/mcp`
  and nothing else, an API token cannot approve an app, and the sign-in page cannot be framed and never
  approves on the keypress that signed in.
- The Settings pages' changes that cannot be undone (pairings, caches, a restore) ask first, some with a word
  to type; the pairing and cache resets refuse without `"confirm": true` in their body. They are an
  administrator's (see Users, roles and API tokens); an accessory's History is anyone's to read.
- With `"https": true` the UI serves HTTPS and the cookie carries `Secure`. Name a certificate and its key
  (`certificate`, `privateKey`, PEM files), or let the bridge make a self-signed one, kept next to
  config.json (`ui-certificate.pem`, `ui-key.pem`, owner-only): it names this machine, its `.local` name,
  `localhost`, `allowedHosts` and the LAN addresses, lasts 397 days and is made again before it expires or
  when an address changes. The banner prints its SHA-256 fingerprint, which the browser's warning shows.
  To trust it once and for all, download `/homeswift-ui.crt` and add it to the keychain (macOS: Always
  Trust), or install it on an iPhone and turn it on under Settings › General › About › Certificate Trust
  Settings. The UI's own HTTPS never sends `Strict-Transport-Security`: under it a browser offers no way past
  a certificate warning, which a self-signed certificate always gets until it is trusted. Without `https`, keep
  the UI on the home network or behind a reverse proxy with TLS. With
  `auth: none`, set `host` to `127.0.0.1`.
- An administrator's Config page shows config.json as it is, secrets included, the way Config UI X does. The
  MCP server's redaction rules are for models, not for the person who owns the file. Other users never get it.

## On a phone's home screen

The UI is an installable web app: `manifest.webmanifest` (standalone, starting on Status), PNG icons (192, 512
and a maskable 512) and an `apple-touch-icon.png`, all served without a session like the other static files.
Over HTTPS the page carries the touch icon inline: iOS fetches a home screen icon without the exception accepted for a
self-signed certificate, and would show a letter instead.
On a phone a floating menu button at the bottom right opens the sections, including Settings and Account.
The current section has a highlighted background. Save bars leave space for the button when they overlap;
a card's ⋯ menu opens as a sheet from the bottom of the screen (a swipe down puts it away, as an accessory's
sheet), and toolbars keep their glyphs (the Accessories page's
grouping, the Assistant's sparkle) where a wide window also shows the words.

In Safari, Share › Add to Home Screen; in Chrome, Install app. It opens full screen with the navigation menu within reach; `/quick` makes a good first page to keep there (a manifest shortcut opens it). The service worker (`/sw.js`)
only shows notifications, nothing is kept offline: the bridge must be reachable to use it.

![Mobile navigation with Settings and Account](images/widgets/mobile-navigation.png)

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
passphrase of several random words is the easy way over the bar. **Account**, in the menu behind your initial at the header's right end (with Appearance, Users and Sign out),
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

