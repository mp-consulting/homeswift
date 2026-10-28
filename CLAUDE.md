# Homeswift

The HomeKit Accessory Protocol (accessory side, over IP) in Swift, and a Homebridge in Swift on top of it.
Library `Homeswift`, plugin API and runtime `HomeswiftPlugin`, the `homeswift` bridge (target
`HomeswiftCLI`), plugins under `Plugins/`, demo `homeswift-demo`. macOS 14+ and Linux.

## Layout

| Path | What it is |
|---|---|
| `Sources/Homeswift/Model` | `Accessory`, `Service`, `Characteristic`, `HAPValue`, `CharacteristicType`; `Definitions.swift` is generated |
| `Sources/Homeswift/Crypto` | TLV8, `ModularField` (Montgomery arithmetic), SRP-6a, HKDF/ChaCha20 helpers, `Secrets` (random tokens, constant-time compares) |
| `Sources/Homeswift/Pairing` | Setup code and URI, pair setup, pair verify, pairings |
| `Sources/Homeswift/Server` | `HAPServer`, `HAPConnection` (one task per connection), HTTP, sessions, endpoints, storage, Bonjour advertiser and `BonjourBrowser`, `MDNSResponder` (the built-in responder, ciao's counterpart; `MDNSMessage` is the wire format) |
| `Sources/Homeswift/Camera` | `CameraController`/`DoorbellController` (HAP-NodeJS's API), `RTPStreamManagement` (setup endpoints, SRTP, selected stream), `RecordingManagement` (HomeKit Secure Video, `dataSend` streams), `CameraTypes` (options, requests, delegates) |
| `Sources/Homeswift/DataStream` | HomeKit Data Stream: `HDSCodec` (HAP-NodeJS's DataStreamParser), `HDSFrame` (keys, ChaCha20 frames), `DataStreamServer`/`DataStreamConnection` (TCP on NIO), `DataStreamManagement` (the service) |
| `Sources/Homeswift/Controllers` | `AdaptiveLightingController`, `ColorUtils`, `SerializableController` (state saved by `PluginContext.configureController`) |
| `Sources/HomeswiftFFmpeg` | FFmpeg for camera plugins (port of homebridge-unifi-protect's `lib/ffmpeg`): codecs and hardware acceleration, encoder arguments, the process, RTP ports and demuxer, fMP4 recordings and livestreams |
| `Sources/HomeswiftPlugin` | `HomeswiftPlugin` protocol, `PluginContext` (`removeAccessories(keeping:)`, `jsonFile`), `PluginRegistry`, `HomeswiftConfiguration` (Homebridge-shaped config.json), `AccessoryCache`, `PluginHost` (bridges, child bridges, plugin lifecycle), `LogBuffer` and `LogArchive` (the log on disk, rotated), `LogDetails` (JSON payloads taken out of log lines, secrets masked), `Metrics` (the Status page's memory, CPU and latency history, a record per minute under `metrics/`), `Energy` (`EnergyRole`, `EnergyTag`: readings plugins tag for the Status page's Energy section; the kWh per day), `EnergyArchive` (each hour's energy for years: the bridge's minutes and plugins' imports, `importEnergy`), `ControllerStorage`, `EveHistory` (fakegato-history), `PersistedDictionary`, `TaskBag` and `LatestCallGuard` (`Tasks.swift`) |
| `Sources/HomeswiftCLI` | The `homeswift` binary: arguments, log format, `Plugins.swift` lists the plugins compiled in, `AssistantCommands.swift` the `ask`/`explain`/`diagnose`/`digest`/`organize`/`usage`/`test-ai` commands |
| `Sources/HomeswiftAI` | The Assistant: `Provider` adapters (`Providers/`), `AIConfiguration` (the `HomeswiftAiKit` block), `Redaction`, `Prompts` (the words in `Prompts/*.md`, embedded as `PromptFiles.swift`), `JSONGeneration`, `Pricing`/`UsageTracker` (usage on disk, budgets), `RateLimit`, `Features` (digest, organiser, connection test), `AssistantService` |
| `Sources/HomeswiftMCP` | The MCP server: `JSONRPC`, `MCPServer`/`MCPSession` (methods, elicitation), `Scopes` (`MCPConfiguration`, tokens), `AuditLog`, `HomeswiftCatalog` (the tools, resources and prompts over a `PluginHost`; also the web UI's control surface; `AssistantTools`: usage, connection test, the daily digest, log export and truncation), `HTTPServer` (Streamable HTTP on NIO), `StdioProxy` (`homeswift mcp`), `ChatToolbox` (the tools for the web UI's chat, an in-process session), `HostName` and `FailureThrottle` (shared with the web UI) |
| `Sources/HomeswiftUI` | The web UI: `UIConfiguration` (the `HomeswiftUI` block), `Auth` (users, PBKDF2, sessions, login throttle), `UIServer` (NIO HTTP, the JSON API, the event stream), `Cameras` (camera snapshots and live fMP4 streams), `AssistantChat` (the chat's conversations, kept in `ui-chats.json`), `AccessoryLayout` (the Accessories wall's order and sizes, `ui-layout.json`), `AssistantRoutes` (the pages' streamed, cancellable Assistant requests), `Preferences` (each user's appearance and Status layout), `Certificate` (HTTPS, self-signed), `OAuth`/`OAuthRoutes` (the MCP server at the UI's `/mcp` for claude.ai: discovery, client registration, PKCE codes and rotated refresh tokens in `ui-oauth.json`, the `/oauth/authorize` sign-in page, Account's connected apps), `Web/` (the pages, `widgets.js` the accessory widgets; `WebAssets.swift` is generated from it) |
| `Sources/HomeswiftNetwork` | For plugins reaching devices and clouds: `NetworkInterfaces`, `HTTPClient` (NIO and NIOSSL; trusts or pins a self-signed certificate, the same on Linux; `TrustOnFirstUse`; `stream` for a body that keeps coming, `ServerSentEvents` for an event stream, in `HTTPStreaming.swift`), `DigestAuthentication`, `WakeOnLAN`, `UDPSocket` and `localIPv4Networks`, `WebSocket`, `MQTTClient` (`MQTTPacket`, `MQTTTransport`; MQTT 3.1.1 and 5), `TLSOptions` (roots such as Amazon Root CA 1, client certificates, ALPN, cipher lists), `MDNSQuery` (a one-shot mDNS query whose answers carry the sender's address), `AWSSignatureV4`, `URLEncoding`, `Backoff` |
| `Scripts/embed-assets.swift` | Embeds a plugin's `config.schema.json`, a `Web/` directory or the Assistant's `Prompts/` into Swift source; tests fail when the generated files are stale |
| `Scripts/docs-screenshots.mjs` | Retakes the docs' web UI screenshots from a throwaway bridge with headless Chrome (docs/widgets.md, "Screenshots") |
| `Scripts/ui-screenshots.mjs` | Retakes docs/ui.md's page screenshots (`docs/images/ui`) from a throwaway bridge of paused demonstration blocks, made and removed by the script (docs/ui.md, "Screenshots") |
| `Scripts/site-languages.mjs` | Writes `site/fr/`, `es/` and `pt/index.html` from `site/index.html` (its `data-i18n` and `data-i18n-html` text) and the site's catalogs; fails on a missing translation, `--check` on a stale page |
| `Scripts/new-plugin.swift` | Creates `Plugins/<Name>/` (a skeleton on a fake API that builds and passes its tests; `--service` picks the HAP services and characteristics from `Definitions.swift`, `--list` shows them), its targets in `Package.swift` and its registration in `Plugins.swift` |
| `CONTRIBUTING.md`, `.github/` | How to propose a plugin and what it needs (the checklist), the plugin proposal issue form, the pull request template, `CODEOWNERS` |
| `THIRD-PARTY-NOTICES.md` | The copyright and permission notices of the projects code was ported from, and which paths come from each; a new port adds its own. `Scripts/collect-licenses.sh` puts it, `LICENSES/` and the compiled-in packages' licence files in the container image and the Synology package |
| `.claude/skills/homeswift-plugin` | The skill for writing or porting a plugin (`references/porting.md`: Node.js to Swift; `scripts/check-on-bridge.sh`: a throwaway bridge queried over MCP). `.agents/skills` links it for Codex; `AGENTS.md` links this file |
| `Plugins/<Name>` | One plugin: `Sources` (target `Homeswift<Name>`), `Tests`, `README.md`, `config.schema.json`, optionally `Web/` (its own UI page; `Sources/WebFiles.swift` is generated). `ElgatoKeyLights` is the reference, `PhilipsAmbilightTV` the one with external accessories, a shared transport and pairing |
| `Sources/CHAPMath` | C Montgomery multiplication for SRP |
| `Sources/CDNSSD` | Avahi's dns_sd on Linux (macOS imports `dnssd`) |
| `Tests/HomeswiftTests` | Primitives (SRP vectors from fast-srp-hap) and a real controller (`TestController`) against the server |
| `Tests/HomeswiftPluginTests` | Config decoding, `PluginHost` with a recording plugin: cache, child bridges, id conflicts; controller storage, Eve history against fakegato's output |
| `docs/plugins.md` | How to write a plugin, the runtime's files, porting from Homebridge, where plugins live |
| `docs/ai.md` | The Assistant: configuration, providers, command line, use from a plugin, what reaches a provider |
| `docs/mcp.md` | The MCP server: configuration, claude.ai over OAuth, scopes, confirmations, resources, prompts, security |
| `docs/ui.md` | The web UI: configuration, pages, security, what plugin authors ship |
| `docs/translations.md` | The web UI's languages (English, French, Spanish, Portuguese): `i18n.js`, the catalogs `i18n-<lang>.js`, `t()`/`tn()`, plugins' `Web/i18n.js`, the style and the glossary |
| `docs/widgets.md` | The Accessories page's widgets: sizes, the wall, Adaptive Lighting, paused plugins, what a plugin does to get good widgets; screenshots in `docs/images/widgets` |
| `Tests/HomeswiftUITests` | Users and sessions, embedded assets are current, the server end to end with a cookie-keeping client |
| `Tests/HomeswiftMCPTests` | The protocol on a direct session (scopes, elicitation, config tools, resources), the HTTP transport and the stdio proxy against a real server on port 0 |
| `Tests/HomeswiftAITests` | Providers against a fake transport (request shapes, parsing, streaming, retries), redaction, schema checks, the Assistant on a fake provider |
| `Tests/HomeswiftNetworkTests` | The HTTP client against a NIO server, plain and with a self-signed certificate (trust, pin, mismatch), the RFC 2617 Digest vector, Wake-on-LAN packets over UDP, WebSocket and MQTT against a NIO server (`TestSocketServer`), AWS Signature V4 vectors, URL encodings byte for byte, the fakes |
| `Tests/HomeswiftNetworkTestSupport` | A library target for plugin tests: `FakeMQTTConnection` and `FakeWebSocket`, in memory, no broker |
| `Tests/HomeswiftFFmpegTests` | FFmpeg options and codecs per host, the process wrapper against a shell, RTP, fMP4 parsing on fixtures |
| `Dockerfile`, `docker-compose.yml` | The container image (bridge, Avahi, FFmpeg; `Scripts/docker-entrypoint.sh` starts Avahi, seeds config.json, drops to `PUID:PGID`), published to GHCR by `.github/workflows/docker.yml`; `docs/synology.md` |
| `Synology` | The Synology package: `build.sh` makes an `.spk` per architecture with Docker (`Dockerfile`: the binary on Amazon Linux 2, glibc 2.26 as on DSM 7.0; `bundle-libraries.sh` puts Avahi's dns_sd beside it), `conf/` (privilege, resources, the systemd unit), `scripts/`, the install wizard, `package/` (the `homeswift` command, `start.sh`); `.github/workflows/synology.yml` attaches them to releases |
| `site` | The homeswift.dev website, plain HTML, CSS and JavaScript (no build step, no dependencies), its icons and `CNAME`: `index.html` the home page (AI agents and the Assistant, a live demo in `home.js`), `bridge.html` the bridge (benchmarks, features, plugins, install), `privacy.html`. `fr/`, `es/` and `pt/` hold them translated: `index.html` generated by `Scripts/site-languages.mjs` from the English page and the catalogs `i18n-<lang>.js` (which `i18n.js` also loads for the demo's `t()` strings), `bridge.html` and `privacy.html` translated by hand. `.github/workflows/pages.yml` publishes it to GitHub Pages when it changes on main, every `.css` and `.js` address versioned by commit for Cloudflare's cache. Its benchmark numbers come from `Benchmarks/README.md` and its plugin list from `Plugins/`: update them together |
| `Benchmarks` | A separate package: `hap-bench`, a HomeKit controller that measures a server (pairing, requests, events, load, memory), `hap-bench-server` (a Homeswift bridge with N lightbulbs) and the same bridge on HAP-NodeJS under `hap-nodejs/`; `run.sh` compares them, `README.md` has the numbers |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build and test outside the repo.
swift build --scratch-path ~/Library/Caches/homeswift-build
swift test  --scratch-path ~/Library/Caches/homeswift-build
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift -U /tmp/homeswift-dev   # a throwaway config dir
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift plugins
swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift   # after editing a page
swift Scripts/embed-assets.swift prompts Sources/HomeswiftAI/Prompts Sources/HomeswiftAI/PromptFiles.swift   # after editing a prompt
node Scripts/site-languages.mjs   # after editing site/index.html or its catalogs (--check says when the copies are stale)
swift Scripts/embed-assets.swift plugin Plugins/ElgatoKeyLights ElgatoKeyLightsPlugin          # after editing a schema
swift Scripts/new-plugin.swift Lights Lights "Lights" --service lightbulb:brightness --service battery   # a new plugin; --list shows the services
swift Scripts/embed-assets.swift web Plugins/ElgatoKeyLights/Web Plugins/ElgatoKeyLights/Sources/WebFiles.swift ElgatoKeyLightsPlugin   # after editing a plugin page
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift-demo   # HAP_DEBUG=1 logs every request
# Working on the web pages: serve them from the checkout; a CSS save swaps in place, a JS or HTML save reloads.
HOMESWIFT_WEB_ROOT=$PWD swift run --scratch-path ~/Library/Caches/homeswift-build homeswift -U ~/.homeswift-tvtest
# Then, before committing, embed them again (UITests.webFilesAreCurrent checks):
swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift

# After a HAP-NodeJS update (needs a built checkout of homebridge/HAP-NodeJS):
node Scripts/generate-definitions.js <hap-nodejs> > Sources/Homeswift/Model/Definitions.swift 2>/dev/null
```

## Rules

- **No Claude attribution in git.** Commit messages and pull request descriptions carry no `Co-Authored-By: Claude`
  trailer and no "Generated with Claude Code" line.
- Apple does not publish the HAP spec outside MFi. Follow HAP-NodeJS's behaviour and check crypto against known
  vectors; never guess byte layouts.
- SRP stays on `CHAPMath`: a pure Swift big-integer library took minutes per pair setup in debug builds, which
  made the server tests time out.
- Never log setup codes, keys, tokens or pair-setup/pair-verify bodies (the trace log prints only their size).
- Aids and iids must stay stable for an accessory `id` (keys `aid/serviceUUID/subtype[/charUUID]`), or HomeKit
  loses rooms, scenes and automations. Plugins prefix ids with their platform name (`ElgatoKeyLights:<MAC>`).
- Run one demo or bridge per identity at a time: two processes advertising the same device ID make the Home
  app drop pairings.
- Tests use `MemoryStorage` and `advertise: false`; they never touch `~/.homeswift`. Plugin tests inject fake
  transports through a `PluginRegistry` closure (see `Plugins/ElgatoKeyLights/Tests`); MQTT and WebSocket fakes are in
  `HomeswiftNetworkTestSupport`.
- Keep Linux building: Darwin-only APIs go behind `#if canImport(...)`; `URLSession` needs
  `#if canImport(FoundationNetworking)`. CI runs the tests on Linux. dns_sd code must work with Avahi's
  compatibility layer (no `DNSServiceSetDispatchQueue`, shared connections or `DNSServiceGetAddrInfo`).
- Plugins live in `Plugins/<Name>/` with the layout of a standalone package, keep the platform name and
  option names of the Homebridge plugin they port, and are registered in `Sources/HomeswiftCLI/Plugins.swift`.
  Plugins depend on `Homeswift`, `HomeswiftPlugin` and shared transport targets of this package (`HomeswiftNetwork`), never
  on a new package. An accessory HomeKit wants on its own (a television, a camera) goes through
  `context.publishExternal`, which gives it a HAP server of its own under `external/`.
- The executable target is `HomeswiftCLI`, not `homeswift`: that name is `Homeswift` on a case-insensitive
  file system.
- The Assistant: providers talk to the APIs over plain HTTP (no SDKs), through `HTTPTransport` so tests use
  canned replies; every input goes through `Redaction` before a request; the prompts' words live in Markdown in
  `Sources/HomeswiftAI/Prompts/` (one file per feature, `## name` per text, `{{value}}` placeholders; its README says how
  a file reads), embedded into `PromptFiles.swift` by `Scripts/embed-assets.swift prompts` (`PromptTests` fails when it
  is stale), and `Prompts.swift` fills in the values and wraps data in `<untrusted-data>`;
  plugins never depend on a provider (`context.assistant` is optional). Claude requests send no `thinking`
  settings, prefills or forced tool choices. Darwin-only `FoundationModels` stays behind `#if canImport`.
- The MCP server: every tool declares its scope and whether it is destructive; destructive tools go through
  `ToolCall.confirm` (elicitation, else a one-time code from the bridge's log that `HomeswiftCatalog.safe` hides) and every write is audited; locks, garage doors
  and alarms are written only by `set_security_accessory`; tool text from logs or devices is wrapped in
  `<untrusted-data>`. The protocol is implemented directly (no SDK): `MCPServer.protocolVersion` is the
  version to bump. `homeswift mcp` logs to stderr because stdout carries the protocol.
- Translations: every text a person reads on a page goes through `t()`/`tn()` (or `data-i18n` in HTML), with its
  French, Spanish and Portuguese in `Web/i18n-<lang>.js`, or a plugin's `Web/i18n.js` (`TranslationTests` fails
  otherwise); follow docs/translations.md's style and glossary. A change to homeswift.dev's text is made in its
  `fr/`, `es/` and `pt/` pages too.
- Screenshots follow the UI: a change to how the web UI looks retakes, in the same change, the screenshots that show
  it (`docs/images`, the README) and brings `site/` (homeswift.dev, which draws widgets in its own HTML) in step.
  `Scripts/docs-screenshots.mjs` retakes the wall, phone and paused shots (docs/widgets.md, "Screenshots": a
  throwaway bridge, plugins paused, light mode, 2x); names are demonstration names, never the user's real ones,
  and the name map stays out of the repository.
- Every button carries an icon beside its text: `actionIcon` in `el()`, `data-action-icon` in HTML (the names are
  common.js's `icons`), tabs and plugin pages included; a button with only an icon has an `aria-label`.
- The web UI: pages are plain HTML, CSS and JavaScript without dependencies or a build step; they are
  embedded, so edit `Web/` and rerun the embed script (the tests say when it is stale). The API is the
  `HomeswiftCatalog` surface; mutations need JSON bodies and a same-origin `Origin`. The OAuth endpoints outside
  `/api` (`/oauth/token`, `/oauth/register`, `/oauth/revoke`) are the exception the protocol requires: form bodies
  from claude.ai's servers, no `Origin`, no cookie; their tokens reach `/mcp` only. An app a user who is not an
  administrator connects gets `HomeswiftCatalog.administratorOnly` hidden, as the UI's chat does. `HomeswiftUI` and
  `HomeswiftAiKit` are system platforms: the CLI starts them, `PluginHost` skips them. The first account
  needs the set-up code the banner prints (`UIServer.setupCode`), never logged; requests are answered only
  for the server's own `Host` names (`allowedHosts`). The UI's views are paths (`/plugins/<slug>/expert`,
  `/logs/<slug>?since=24h`; `Slug` and common.js's `slug` agree); a plugin instance's page is served at
  `/plugins/<slug>` with a `<base>` and a `<meta name="homeswift-plugin">`, and talks to its instance through `/api/plugins/<platform>/<name>/…` (`HomeswiftPlugin.webFiles`,
  `handleWebRequest`). A restart goes through `HomeswiftCatalog.scheduleRestart`, whose hook the CLI sets to
  stop everything and `execv` itself (`Restart.swift`); libraries and tests have none. Files the bridge
  keeps are written with `OwnerOnlyFile.write`.

## Releases

A release is a tag: SwiftPM resolves versions from `vX.Y.Z` tags. Bump `PluginHost.version` (shown by
`homeswift --version` and as the bridge's firmware revision), move the `[Unreleased]` section of CHANGELOG.md
under the new version, commit, then `gh release create vX.Y.Z --title X.Y.Z --notes-file <section>` (the title is the bare version) and push the tag. There
are no binaries to sign yet. The Homebrew formula (`mp-consulting/homebrew-tap`, `Formula/homeswift.rb`) builds
`homeswift` and `homeswift-demo` from the release tarball and installs `THIRD-PARTY-NOTICES.md` and `LICENSES`.
The tap's workflow moves it to the latest release within 6 hours. Pushing the tag runs `.github/workflows/docker.yml`, which pushes
`ghcr.io/mp-consulting/homeswift:X.Y.Z`, `X.Y` and `latest` for amd64 and arm64 (each on a native runner); a
new GHCR package is private until its visibility is set to public in the package's settings.
