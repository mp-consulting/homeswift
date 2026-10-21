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
  version, uptime, machine; a **Restart homeswift** button.
- **Accessories**: every accessory with its services. Switches for on/off, sliders for brightness, colour
  temperature and the like, menus for lock, door and alarm targets, text for everything else. Values
  update live when a device changes elsewhere. Locks, garage doors and alarms can be operated here, as in
  the Home app, since the user signed in.
- **Plugins**: every platform block of config.json, with whether it runs and where. **Open** shows a
  plugin's own page when it has one (see below). **Settings** opens a
  form built from the plugin's schema (the same `config.schema.json` the Homebridge version ships), or a
  JSON editor for plugins without one and for the runtime's own blocks. **Add a platform** lists the
  plugins compiled in. Saving validates, backs up the previous file, and asks for a restart.
- **Config**: the whole file in an editor. Saving validates it, keeps a backup under `backups/`, sorts
  the keys, and asks for a restart.
- **Logs**: the last lines and the live log, filtered by level and text.

Configuration changes need a restart of homeswift to apply: the page says so, and its **Restart now**
button does it. The process replaces itself with a fresh copy (same binary, arguments and PID), so
launchd, systemd and `brew services` see nothing happen, and the page reloads once the bridge is back.
Logins survive a restart: sessions are kept in `ui-sessions.json` next to config.json.

## Security

- Every API call needs the session cookie (`HttpOnly`, `SameSite=Strict`). Mutations must be JSON and come
  from the page: a request whose `Origin` names another site, or whose `Sec-Fetch-Site` is not the page's
  own, is refused. Pages carry a content security policy, no-store, no framing.
- The first account needs the set-up code, so nobody else on the network can claim the bridge before its
  owner does. The code is printed at startup, never logged: the MCP log tools cannot see it.
- Passwords are hashed with PBKDF2-HMAC-SHA256 (210,000 iterations, a random salt), and verified in
  constant time. Five failed logins or set-up codes from an address slow the next attempts down.
- Requests are answered only when their `Host` is an IP address, localhost, this machine's name or an
  `allowedHosts` entry (421 otherwise), so a page that rebinds its own name to this address gets nothing,
  with `auth: none` too.
- The UI is plain HTTP. Keep it on the home network, or put it behind a reverse proxy with TLS; the
  cookie cannot carry `Secure` without one. With `auth: none`, set `host` to `127.0.0.1`.
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
checks it is current). The UI serves them at `/plugins/<platform>/`, to signed-in users only, and the
Plugins page shows **Open** for every running instance, linking to `index.html?name=<block name>`. The
page is a full document: link `/style.css` for the look of the rest of the UI, and `/plugin.js` for the
helper. The content security policy allows scripts and styles from files only, no inline script.

The page talks to its instance through `homeswift.request(path, { method, body })`, which sends
`/api/plugins/<platform>/<name>/<path>` with the session cookie and parses the JSON answer; the plugin
answers in `handleWebRequest(_:)` with a `PluginWebResponse` (JSON and a status). `homeswift.el(tag,
attributes, ...children)` and `homeswift.$(selector)` build and find elements the way the UI's own pages
do; `homeswift.platform`, `homeswift.name` and `homeswift.home` (the Plugins page) are there too. Mutations must be JSON, like the
rest of the API. `Plugins/ElgatoKeyLights/Web` is the example: the lights the instance knows, their state,
and an Identify button.

The UI's own pages are plain HTML, CSS and JavaScript under `Sources/HomeswiftUI/Web`, embedded into the
binary by `swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift`,
so a Homebrew install carries them and no build step needs Node.
