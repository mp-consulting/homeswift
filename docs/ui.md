# The web UI

A `HomeswiftUI` block gives the bridge a web interface, inside the same process: status and pairing
codes, accessories with live control, each plugin's settings as a form made from its `config.schema.json`,
the raw `config.json`, and the log as it happens. It is the Config UI of a Homebridge, in Swift, with a
liquid glass look.

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

- **Status**: each bridge with its device ID, port, pairing state and platforms, and the setup code of a
  bridge that is not paired yet; the Assistant's provider; version, uptime, machine.
- **Accessories**: every accessory with its services. Switches for on/off, sliders for brightness, colour
  temperature and the like, menus for lock, door and alarm targets, text for everything else. Values
  update live when a device changes elsewhere. Locks, garage doors and alarms can be operated here, as in
  the Home app, since the user signed in.
- **Plugins**: every platform block of config.json, with whether it runs and where. **Settings** opens a
  form built from the plugin's schema (the same `config.schema.json` the Homebridge version ships), or a
  JSON editor for plugins without one and for the runtime's own blocks. **Add a platform** lists the
  plugins compiled in. Saving validates, backs up the previous file, and asks for a restart.
- **Config**: the whole file in an editor. Saving validates it, keeps a backup under `backups/`, sorts
  the keys, and asks for a restart.
- **Logs**: the last lines and the live log, filtered by level and text.

Configuration changes need a restart of homeswift to apply: the page says so, and launchd or systemd
owns the process.

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

Ship a `config.schema.json` in the plugin's directory and run `swift Scripts/embed-assets.swift plugin
Plugins/<Name> <Type>` to embed it (a test checks it is current); the Plugins page then shows a form. The
form understands the Homebridge dialect: `properties` in order, `required: true` on a property, `oneOf`
with `enum` and `title` for menus, `placeholder`, `default`, `description`, arrays of objects or of
values, nested objects, and the top-level `layout` with `fieldset` groups. Keys the schema does not know
(`_bridge` for one) are kept as they are.

The pages are plain HTML, CSS and JavaScript under `Sources/HomeswiftUI/Web`, embedded into the binary by
`swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift`, so a
Homebrew install carries them and no build step needs Node.
