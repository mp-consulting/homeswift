# Contributing

Bug reports, fixes and new plugins are welcome. For anything larger than a fix, open an issue first so we can
agree on the approach before you spend time on it.

```bash
swift build
swift test
```

`Scripts/test.sh` (arguments as `swift build`'s; after `--`, the tests', such as `--filter Govee`) builds the tests
and runs every test target at once, where `swift test` on macOS runs them one after another: about 3 seconds rather
than 20. Tests wait for what they check rather than for a fixed time, and take timings from their plugin's
dependencies (a `timeScale`, a shorter delay) instead of waiting out real ones.

CI runs the tests on macOS and on Linux (`swift:6.2`); both must pass. On macOS, if `swift test` fails to code
sign the test bundle, build outside the repository with `--scratch-path ~/Library/Caches/homeswift-build`.
Changes that users notice get a line in the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

## Proposing a plugin

Swift cannot load code at runtime, so plugins are compiled into the `homeswift` binary: a new plugin is a pull
request that adds `Plugins/<Name>/` to this repository ([docs/plugins.md](docs/plugins.md#where-plugins-live)
says why).

1. **Open a [plugin proposal](https://github.com/mp-consulting/homeswift/issues/new?template=plugin-proposal.yml)**
   before writing code. A plugin is a good fit when:
   - the devices are not in HomeKit already (natively or through Matter), or the plugin adds what HomeKit lacks;
   - there is a Homebridge plugin to port, under a license compatible with MIT (MIT, ISC, BSD, Apache-2.0).
     Code under the GPL cannot be ported into this repository;
   - its transport fits `HomeswiftNetwork` (HTTP, MQTT, WebSocket, UDP, mDNS), or the proposal says what is missing
     there. Plugins add no package dependencies;
   - you have the hardware, or someone who has it will test the port.
2. **Create the skeleton** once the proposal is accepted:
   ```bash
   swift Scripts/new-plugin.swift <Name> <platform> "<Display Name>" --service lightbulb:brightness,colorTemperature --service battery
   ```
   `<Name>` names the directory and the targets, `<platform>` is the Homebridge plugin's `pluginAlias`. Each
   `--service` is a HAP service every device gets, with its required characteristics and the optional ones listed
   (`all` for every one); the first is the primary one. `--list` shows the services, `--list <service>` their
   characteristics. The script writes `Plugins/<Name>/`: the device state and the changes HomeKit can ask for, typed
   from those characteristics, a plugin that polls a fake API and shows them, and tests for a write and a device
   change. It adds the targets to `Package.swift` and registers the plugin in `Sources/HomeswiftCLI/Plugins.swift`.
3. **Port the plugin** following [docs/plugins.md](docs/plugins.md). `Plugins/ElgatoKeyLights` is the reference;
   `Plugins/PhilipsAmbilightTV` publishes a television on its own, `Plugins/UniFiProtect` has cameras.
4. **Open the pull request.** Its template lists what is checked below.

## What a plugin needs

- **The layout:** `README.md`, `config.schema.json`, `Sources` (target `Homeswift<Name>`), `Tests` (target
  `<Name>Tests`), and optionally `Web/` for its own page.
- **The same configuration as the Homebridge plugin:** its platform name and option names, so a user pastes their
  block unchanged. Every option is optional, with the defaults applied in code.
- **Stable accessory ids** prefixed with the platform name (`ElgatoKeyLights:<MAC>`). A changing id makes HomeKit
  forget the accessory's room, scenes and automations.
- **Adaptive Lighting on every light that can have it:** a Lightbulb with Brightness and Color Temperature gets an
  `AdaptiveLightingController` from `context.adaptiveLighting(for:accessoryID:)` before the accessory is added, and the
  plugin passes the device's reports of its colour to `disableIfChangedElsewhere(mireds:)`, which turns it off for a
  colour or a white set elsewhere (its app, a remote). `Scripts/new-plugin.swift` writes the controller; [docs/plugins.md](docs/plugins.md) has the details, and
  `Plugins/Dirigera` and `Plugins/PhilipsHue` are examples. The bridge's debug log names a light without one, which
  the skill's `check-on-bridge.sh` shows. A light mirrored from another controller (Wingman) keeps that controller's.
- **Tests without devices or accounts:** fake transports injected through a `PluginRegistry` closure; MQTT and
  WebSocket fakes are in `HomeswiftNetworkTestSupport`. Tests use `MemoryStorage` and `advertise: false`.
- **Linux:** Darwin-only APIs behind `#if canImport(...)`, `URLSession` with `#if canImport(FoundationNetworking)`.
- **No secrets in the log:** tokens, passwords, keys and setup codes are never logged, at any level.
- **Secrets in the vault:** secrets in the configuration under secret-named keys (`password`, `token`, `apiKey`…),
  so the bridge seals them and resolves `vault:` references; tokens the plugin stores in
  `context.secretFile(_:as:)`, never in a plain file ([docs/plugins.md](docs/plugins.md#secrets)).
- **Light on the bridge:** push before polling, one request per cycle where the API allows it, `Backoff` on
  failures, only changed characteristics set, slider writes coalesced with `LatestCallGuard`, nothing that grows
  with uptime. The `homeswift-plugin` skill's "Keep it light" has the full list; the Status page's memory and CPU
  stay flat with the plugin running.
- **A form that explains itself, in four languages:** every option in `config.schema.json` has a `description`,
  choices are a `oneOf` of titled enums, and the schema's `i18n` translates its words into French, Spanish and
  Portuguese ([translations.md](docs/translations.md#forms)).
- **Generated files current:** after editing `config.schema.json` or `Web/`, run
  `swift Scripts/embed-assets.swift plugin Plugins/<Name> <Name>Plugin` (and the `web` command for a page).
- **Credit:** the README names the plugin it ports, its authors and its license, and its copyright and permission
  notice goes in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). A translation into Swift is still a copy for
  copyright: the notice is owed even when no line is the same.
- **A maintainer:** the README names who maintains the plugin, and says how it was tested on real devices.

## Maintaining a plugin

The person named in a plugin's README reviews its changes and answers its issues. Contributors with write access
also get a line in [.github/CODEOWNERS](.github/CODEOWNERS), so GitHub asks for their review. A plugin nobody
has tested on real hardware is marked experimental in its README. A plugin that stays broken without a
maintainer may be removed in a later release; its accessories then leave HomeKit, so this is said in the
changelog first.

## With an AI assistant

[AGENTS.md](AGENTS.md) (the same file as [CLAUDE.md](CLAUDE.md)) gives coding agents the repository's rules. The
`homeswift-plugin` skill in [.claude/skills](.claude/skills/homeswift-plugin/SKILL.md) walks an agent through a
port: reading the Homebridge plugin, the skeleton, the tests, checking the result on a running bridge, the
pull request. Claude Code picks it up on its own; other agents can be pointed at the file. You remain
responsible for what you submit: read the code, and test it on your devices.

## License

Contributions are under the MIT license of this repository.
