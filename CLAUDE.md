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
| `Sources/Homeswift/Server` | `HAPServer`, `HAPConnection` (one task per connection), HTTP, sessions, endpoints, storage, Bonjour advertiser and `BonjourBrowser` |
| `Sources/Homeswift/Camera` | `CameraController`/`DoorbellController` (HAP-NodeJS's API), `RTPStreamManagement` (setup endpoints, SRTP, selected stream), `RecordingManagement` (HomeKit Secure Video, `dataSend` streams), `CameraTypes` (options, requests, delegates) |
| `Sources/Homeswift/DataStream` | HomeKit Data Stream: `HDSCodec` (HAP-NodeJS's DataStreamParser), `HDSFrame` (keys, ChaCha20 frames), `DataStreamServer`/`DataStreamConnection` (TCP on NIO), `DataStreamManagement` (the service) |
| `Sources/Homeswift/Controllers` | `AdaptiveLightingController`, `ColorUtils`, `SerializableController` (state saved by `PluginContext.configureController`) |
| `Sources/HomeswiftFFmpeg` | FFmpeg for camera plugins (port of homebridge-unifi-protect's `lib/ffmpeg`): codecs and hardware acceleration, encoder arguments, the process, RTP ports and demuxer, fMP4 recordings and livestreams |
| `Sources/HomeswiftPlugin` | `HomeswiftPlugin` protocol, `PluginContext` (`removeAccessories(keeping:)`, `jsonFile`), `PluginRegistry`, `HomeswiftConfiguration` (Homebridge-shaped config.json), `AccessoryCache`, `PluginHost` (bridges, child bridges, plugin lifecycle), `LogBuffer` and `LogArchive` (the log on disk, rotated), `ControllerStorage`, `EveHistory` (fakegato-history), `PersistedDictionary`, `TaskBag` and `LatestCallGuard` (`Tasks.swift`) |
| `Sources/HomeswiftCLI` | The `homeswift` binary: arguments, log format, `Plugins.swift` lists the plugins compiled in, `AssistantCommands.swift` the `ask`/`explain`/`diagnose` commands |
| `Sources/HomeswiftAI` | The Assistant: `Provider` adapters (`Providers/`), `AIConfiguration` (the `HomeswiftAiKit` block), `Redaction`, `Prompts`, `JSONGeneration`, `Pricing`/`UsageTracker`, `AssistantService` |
| `Sources/HomeswiftMCP` | The MCP server: `JSONRPC`, `MCPServer`/`MCPSession` (methods, elicitation), `Scopes` (`MCPConfiguration`, tokens), `AuditLog`, `HomeswiftCatalog` (the tools, resources and prompts over a `PluginHost`; also the web UI's control surface), `HTTPServer` (Streamable HTTP on NIO), `StdioProxy` (`homeswift mcp`), `ChatToolbox` (the tools for the web UI's chat, an in-process session), `HostName` and `FailureThrottle` (shared with the web UI) |
| `Sources/HomeswiftUI` | The web UI: `UIConfiguration` (the `HomeswiftUI` block), `Auth` (users, PBKDF2, sessions, login throttle), `UIServer` (NIO HTTP, the JSON API, the event stream), `AssistantChat` (the chat's conversations), `Certificate` (HTTPS, self-signed), `Web/` (the pages; `WebAssets.swift` is generated from it) |
| `Sources/HomeswiftNetwork` | For plugins reaching devices and clouds: `NetworkInterfaces`, `HTTPClient` (NIO and NIOSSL; trusts or pins a self-signed certificate, the same on Linux; `TrustOnFirstUse`), `DigestAuthentication`, `WakeOnLAN`, `UDPSocket` and `localIPv4Networks`, `WebSocket`, `MQTTClient` (`MQTTPacket`, `MQTTTransport`), `TLSOptions` (roots such as Amazon Root CA 1, client certificates, ALPN), `AWSSignatureV4`, `URLEncoding`, `Backoff` |
| `Scripts/embed-assets.swift` | Embeds a plugin's `config.schema.json` or the `Web/` directory into Swift source; tests fail when the generated files are stale |
| `Plugins/<Name>` | One plugin: `Sources` (target `Homeswift<Name>`), `Tests`, `README.md`, `config.schema.json`, optionally `Web/` (its own UI page; `Sources/WebFiles.swift` is generated). `ElgatoKeyLights` is the reference, `PhilipsAmbilightTV` the one with external accessories, a shared transport and pairing |
| `Sources/CHAPMath` | C Montgomery multiplication for SRP |
| `Sources/CDNSSD` | Avahi's dns_sd on Linux (macOS imports `dnssd`) |
| `Tests/HomeswiftTests` | Primitives (SRP vectors from fast-srp-hap) and a real controller (`TestController`) against the server |
| `Tests/HomeswiftPluginTests` | Config decoding, `PluginHost` with a recording plugin: cache, child bridges, id conflicts; controller storage, Eve history against fakegato's output |
| `docs/plugins.md` | How to write a plugin, the runtime's files, porting from Homebridge, where plugins live |
| `docs/ai.md` | The Assistant: configuration, providers, command line, use from a plugin, what reaches a provider |
| `docs/mcp.md` | The MCP server: configuration, scopes, confirmations, resources, prompts, security |
| `docs/ui.md` | The web UI: configuration, pages, security, what plugin authors ship |
| `Tests/HomeswiftUITests` | Users and sessions, embedded assets are current, the server end to end with a cookie-keeping client |
| `Tests/HomeswiftMCPTests` | The protocol on a direct session (scopes, elicitation, config tools, resources), the HTTP transport and the stdio proxy against a real server on port 0 |
| `Tests/HomeswiftAITests` | Providers against a fake transport (request shapes, parsing, streaming, retries), redaction, schema checks, the Assistant on a fake provider |
| `Tests/HomeswiftNetworkTests` | The HTTP client against a NIO server, plain and with a self-signed certificate (trust, pin, mismatch), the RFC 2617 Digest vector, Wake-on-LAN packets over UDP, WebSocket and MQTT against a NIO server (`TestSocketServer`), AWS Signature V4 vectors, URL encodings byte for byte, the fakes |
| `Tests/HomeswiftNetworkTestSupport` | A library target for plugin tests: `FakeMQTTConnection` and `FakeWebSocket`, in memory, no broker |
| `Tests/HomeswiftFFmpegTests` | FFmpeg options and codecs per host, the process wrapper against a shell, RTP, fMP4 parsing on fixtures |
| `Benchmarks` | A separate package: `hap-bench`, a HomeKit controller that measures a server (pairing, requests, events, load, memory), `hap-bench-server` (a Homeswift bridge with N lightbulbs) and the same bridge on HAP-NodeJS under `hap-nodejs/`; `run.sh` compares them, `README.md` has the numbers |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build and test outside the repo.
swift build --scratch-path ~/Library/Caches/homeswift-build
swift test  --scratch-path ~/Library/Caches/homeswift-build
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift -U /tmp/homeswift-dev   # a throwaway config dir
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift plugins
swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift   # after editing a page
swift Scripts/embed-assets.swift plugin Plugins/ElgatoKeyLights ElgatoKeyLightsPlugin          # after editing a schema
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
  canned replies; every input goes through `Redaction` before a request; prompts live in `Prompts.swift`;
  plugins never depend on a provider (`context.assistant` is optional). Claude requests send no `thinking`
  settings, prefills or forced tool choices. Darwin-only `FoundationModels` stays behind `#if canImport`.
- The MCP server: every tool declares its scope and whether it is destructive; destructive tools go through
  `ToolCall.confirm` (elicitation, else a one-time code from the bridge's log that `HomeswiftCatalog.safe` hides) and every write is audited; locks, garage doors
  and alarms are written only by `set_security_accessory`; tool text from logs or devices is wrapped in
  `<untrusted-data>`. The protocol is implemented directly (no SDK): `MCPServer.protocolVersion` is the
  version to bump. `homeswift mcp` logs to stderr because stdout carries the protocol.
- The web UI: pages are plain HTML, CSS and JavaScript without dependencies or a build step; they are
  embedded, so edit `Web/` and rerun the embed script (the tests say when it is stale). The API is the
  `HomeswiftCatalog` surface; mutations need JSON bodies and a same-origin `Origin`. `HomeswiftUI` and
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
under the new version, commit, then `gh release create vX.Y.Z --notes-file <section>` and push the tag. There
are no binaries to sign yet. The Homebrew formula (`mp-consulting/homebrew-tap`, `Formula/homeswift.rb`) builds
`homeswift-demo` from the release tarball; it needs `homeswift` added at the next release. The tap's workflow
moves it to the latest release within 6 hours.
