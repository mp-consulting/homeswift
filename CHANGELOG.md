# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
  slowed-down failed logins), or `auth: none`. `docs/ui.md`.
- `get_plugin_config_schema` MCP tool; `list_plugins` says which plugins have a schema.

### Changed

- MCP: a destructive tool with a client that cannot ask the user needs a one-time code from the bridge's
  log instead of a self-declared `confirmed: true`; `dryRun` skips the question only for tools that honour
  it; `get_config` returns secrets only to an admin token and never the MCP tokens; log tools mask secrets
  and defuse data tags; `search_logs` matches plain text unless an admin asks for a regex. The log tools
  and notifications hide confirmation codes, and three wrong codes lock a call until its code expires.

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

[Unreleased]: https://github.com/mp-consulting/homeswift/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mp-consulting/homeswift/releases/tag/v0.1.0
