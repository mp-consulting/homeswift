# HomeSwift

The HomeKit Accessory Protocol (accessory side, over IP) in Swift: the base for a Homebridge in Swift. Library
`HomeSwift`, demo `homeswift-demo`. macOS 14+ and Linux. The plugin model is not designed yet.

## Layout

| Path | What it is |
|---|---|
| `Sources/HomeSwift/Model` | `Accessory`, `Service`, `Characteristic`, `HAPValue`, `CharacteristicType`; `Definitions.swift` is generated |
| `Sources/HomeSwift/Crypto` | TLV8, `ModularField` (Montgomery arithmetic), SRP-6a, HKDF/ChaCha20 helpers |
| `Sources/HomeSwift/Pairing` | Setup code and URI, pair setup, pair verify, pairings |
| `Sources/HomeSwift/Server` | `HAPServer`, `HAPConnection` (one task per connection), HTTP, sessions, endpoints, storage, Bonjour |
| `Sources/CHAPMath` | C Montgomery multiplication for SRP |
| `Sources/CDNSSD` | Avahi's dns_sd on Linux (macOS imports `dnssd`) |
| `Tests/HomeSwiftTests` | Primitives (SRP vectors from fast-srp-hap) and a real controller (`TestController`) against the server |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build and test outside the repo.
swift build --scratch-path ~/Library/Caches/homeswift-build
swift test  --scratch-path ~/Library/Caches/homeswift-build
swift run   --scratch-path ~/Library/Caches/homeswift-build homeswift-demo   # HAP_DEBUG=1 logs every request

# After a HAP-NodeJS update (needs a built checkout of homebridge/HAP-NodeJS):
node Scripts/generate-definitions.js <hap-nodejs> > Sources/HomeSwift/Model/Definitions.swift 2>/dev/null
```

## Rules

- **No Claude attribution in git.** Commit messages and pull request descriptions carry no `Co-Authored-By: Claude`
  trailer and no "Generated with Claude Code" line.
- Apple does not publish the HAP spec outside MFi. Follow HAP-NodeJS's behaviour and check crypto against known
  vectors; never guess byte layouts.
- SRP stays on `CHAPMath`: a pure Swift big-integer library took minutes per pair setup in debug builds, which
  made the server tests time out.
- Never log setup codes, keys or pair-setup/pair-verify bodies (the trace log prints only their size).
- Aids and iids must stay stable for an accessory `id` (keys `aid/serviceUUID/subtype[/charUUID]`), or HomeKit
  loses rooms, scenes and automations.
- Run one demo at a time: two processes advertising the same device ID make the Home app drop pairings.
- Tests use `MemoryStorage` and `advertise: false`; they never touch `~/.homeswift`.
- Keep Linux building: Darwin-only APIs go behind `#if canImport(...)`. CI runs the tests on Linux.

## Releases

A release is a tag: SwiftPM resolves versions from `vX.Y.Z` tags. Move the `[Unreleased]` section of
CHANGELOG.md under the new version, commit, then `gh release create vX.Y.Z --notes-file <section>` and push the
tag. There are no binaries to sign yet.
