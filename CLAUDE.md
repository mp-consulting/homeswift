# Homeswift

The HomeKit Accessory Protocol (accessory side, over IP) in Swift, and a Homebridge in Swift on top of it.
Library `Homeswift`, plugin API and runtime `HomeswiftPlugin`, the `homeswift` bridge (target
`HomeswiftCLI`), plugins under `Plugins/`, demo `homeswift-demo`. macOS 14+ and Linux.

## Layout

| Path | What it is |
|---|---|
| `Sources/Homeswift/Model` | `Accessory`, `Service`, `Characteristic`, `HAPValue`, `CharacteristicType`; `Definitions.swift` is generated |
| `Sources/Homeswift/Crypto` | TLV8, `ModularField` (Montgomery arithmetic), SRP-6a, HKDF/ChaCha20 helpers |
| `Sources/Homeswift/Pairing` | Setup code and URI, pair setup, pair verify, pairings |
| `Sources/Homeswift/Server` | `HAPServer`, `HAPConnection` (one task per connection), HTTP, sessions, endpoints, storage, Bonjour advertiser and `BonjourBrowser` |
| `Sources/HomeswiftPlugin` | `HomeswiftPlugin` protocol, `PluginContext`, `PluginRegistry`, `HomeswiftConfiguration` (Homebridge-shaped config.json), `AccessoryCache`, `PluginHost` (bridges, child bridges, plugin lifecycle) |
| `Sources/HomeswiftCLI` | The `homeswift` binary: arguments, log format, `Plugins.swift` lists the plugins compiled in, `AssistantCommands.swift` the `ask`/`explain`/`diagnose` commands |
| `Sources/HomeswiftAI` | The Assistant: `Provider` adapters (`Providers/`), `AIConfiguration` (the `HomeswiftAiKit` block), `Redaction`, `Prompts`, `JSONGeneration`, `Pricing`/`UsageTracker`, `AssistantService` |
| `Plugins/<Name>` | One plugin: `Sources` (target `Homeswift<Name>`), `Tests`, `README.md`, `config.schema.json`. `ElgatoKeyLights` is the reference |
| `Sources/CHAPMath` | C Montgomery multiplication for SRP |
| `Sources/CDNSSD` | Avahi's dns_sd on Linux (macOS imports `dnssd`) |
| `Tests/HomeswiftTests` | Primitives (SRP vectors from fast-srp-hap) and a real controller (`TestController`) against the server |
| `Tests/HomeswiftPluginTests` | Config decoding, `PluginHost` with a recording plugin: cache, child bridges, id conflicts |
| `docs/plugins.md` | How to write a plugin, the runtime's files, porting from Homebridge, where plugins live |
| `docs/ai.md` | The Assistant: configuration, providers, command line, use from a plugin, what reaches a provider |
| `Tests/HomeswiftAITests` | Providers against a fake transport (request shapes, parsing, streaming, retries), redaction, schema checks, the Assistant on a fake provider |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build and test outside the repo.
swift build --scratch-path ~/Library/Caches/homeswift-build
swift test  --scratch-path ~/Library/Caches/homeswift-build
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift -U /tmp/homeswift-dev   # a throwaway config dir
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift plugins
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift-demo   # HAP_DEBUG=1 logs every request

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
  transports through a `PluginRegistry` closure (see `Plugins/ElgatoKeyLights/Tests`).
- Keep Linux building: Darwin-only APIs go behind `#if canImport(...)`; `URLSession` needs
  `#if canImport(FoundationNetworking)`. CI runs the tests on Linux. dns_sd code must work with Avahi's
  compatibility layer (no `DNSServiceSetDispatchQueue`, shared connections or `DNSServiceGetAddrInfo`).
- Plugins live in `Plugins/<Name>/` with the layout of a standalone package, keep the platform name and
  option names of the Homebridge plugin they port, and are registered in `Sources/HomeswiftCLI/Plugins.swift`.
  Plugins depend on `Homeswift` and `HomeswiftPlugin` only; shared transports become targets of this package.
- The executable target is `HomeswiftCLI`, not `homeswift`: that name is `Homeswift` on a case-insensitive
  file system.
- The Assistant: providers talk to the APIs over plain HTTP (no SDKs), through `HTTPTransport` so tests use
  canned replies; every input goes through `Redaction` before a request; prompts live in `Prompts.swift`;
  plugins never depend on a provider (`context.assistant` is optional). Claude requests send no `thinking`
  settings, prefills or forced tool choices. Darwin-only `FoundationModels` stays behind `#if canImport`.

## Releases

A release is a tag: SwiftPM resolves versions from `vX.Y.Z` tags. Bump `PluginHost.version` (shown by
`homeswift --version` and as the bridge's firmware revision), move the `[Unreleased]` section of CHANGELOG.md
under the new version, commit, then `gh release create vX.Y.Z --notes-file <section>` and push the tag. There
are no binaries to sign yet. The Homebrew formula (`mp-consulting/homebrew-tap`, `Formula/homeswift.rb`) builds
`homeswift-demo` from the release tarball; it needs `homeswift` added at the next release. The tap's workflow
moves it to the latest release within 6 hours.
