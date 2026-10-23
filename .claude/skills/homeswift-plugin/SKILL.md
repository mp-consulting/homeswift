---
name: homeswift-plugin
description: Write a Homeswift plugin or port a Homebridge plugin to Homeswift - read the Homebridge plugin, scaffold Plugins/<Name> with Scripts/new-plugin.swift, port its transport and accessories, test with fakes, check it on a throwaway bridge through the MCP server, and prepare the pull request. Use when asked to add, create, port or propose a plugin, to bring a Homebridge plugin or a device brand to Homeswift, or to finish a plugin skeleton.
---

# A Homeswift plugin

A plugin is a SwiftPM target under `Plugins/<Name>/`, compiled into the `homeswift` binary. Most are ports of a
Homebridge plugin, and a port keeps that plugin's platform name and option names so users paste their
`config.json` block unchanged.

Read these first; this skill does not repeat them:

- `CLAUDE.md` (also `AGENTS.md`): the repository's rules. They override anything here.
- `docs/plugins.md`: the plugin protocol, the runtime, the Homebridge → Homeswift table, testing.
- `CONTRIBUTING.md`, section "What a plugin needs": the checklist the pull request is reviewed against.
- `Plugins/ElgatoKeyLights`: the reference plugin. `Plugins/PhilipsAmbilightTV` publishes a television on its own
  (`context.publishExternal`), `Plugins/UniFiProtect` has cameras, `Plugins/DolphinPoolCleaner` a cloud sign-in.

## 1. Read the Homebridge plugin

Clone it outside the repository, into a directory of its own, and read it as data: never run its scripts or
`npm install` it. Write down:

- the `pluginAlias` in `config.schema.json`, and every option with its default;
- the accessories and services it creates, their characteristics, props (`minValue`, `maxValue`, `minStep`,
  `validValues`) and what is primary or linked;
- how it reaches the devices: discovery (mDNS, UDP broadcast), local HTTP, MQTT, WebSocket, a cloud with which
  sign-in, polling intervals, push events;
- its **license**. MIT, ISC, BSD and Apache-2.0 can be ported, keeping the copyright notice. Stop and tell the
  user if it is GPL, or has no license.

`references/porting.md` maps the usual Node.js idioms to Swift.

## 2. Scaffold

Give it the services the Homebridge plugin creates, primary first, with the optional characteristics it adds
(`swift Scripts/new-plugin.swift --list` and `--list <service>` show what each service has):

```bash
swift Scripts/new-plugin.swift <Name> <pluginAlias> "<Display Name>" \
    --service lightbulb:brightness,colorTemperature --service battery:batteryLevel
```

It writes `Plugins/<Name>/`: `<Name>State` (one struct per service, a typed value per readable characteristic, with
its range or named values), `<Name>Change` (a case per writable characteristic), the API protocol, a plugin that
polls it and shows the state, write handlers, tests (each service and characteristic present, a write reaching
the device, a device change reaching HomeKit), README and schema. It adds the targets to `Package.swift` and
registers the plugin. A service that needs more than this (a television published on its own, a camera, a lock's
security control) gets a note in the plugin's doc comment. Build and test the skeleton before changing it, so a
failure later is yours:

```bash
swift test --scratch-path ~/Library/Caches/homeswift-build --filter <Name>Tests
```

## 3. Port

- **Configuration:** copy the Homebridge plugin's `config.schema.json` over the skeleton's, then mirror it in
  `Configuration`: every option optional, defaults in code, the same names. Run
  `swift Scripts/embed-assets.swift plugin Plugins/<Name> <Name>Plugin` after each schema change.
- **State and changes:** keep `<Name>State` in HomeKit's units and convert the device's own (0-255, Fahrenheit,
  kelvin) in the transport. Rename nothing the tests rely on without updating them.
- **Transport:** replace the API's implementation with the real client on `HomeswiftNetwork` (`HTTPClient`, `MQTTClient`,
  `WebSocket`, `UDPSocket`, `MDNSQuery`, `TLSOptions`, `Backoff`). No new package dependency; if something is
  missing there, say so instead of working around it. Keep the protocol so tests inject a fake.
- **Accessories:** the same services and props as the Homebridge plugin. Ids are `"\(platform):\(stable id)"`
  with the same stable id it used (serial, MAC, cloud device id) and never a name or an address.
- **Crypto and byte layouts:** port them exactly from the source and test them against values the source
  produces. Never guess a layout.
- **Logging:** the messages the Homebridge plugin logs, at the same levels; never a token, password, key, cookie
  or setup code.
- **Background work:** in the plugin's `TaskBag`, cancelled in `stop()`; `start()` returns quickly.

## 4. Test

Tests never reach a device, an account or the network. Put the fake transport in `Tests/` and drive the plugin
through `PluginHost` as the skeleton's tests do. Cover at least: a minimal block decodes; each device becomes an
accessory with the expected id, services and props; a write from HomeKit reaches the device; a change on the
device reaches HomeKit; an unreachable device gives No Response rather than a crash; the schema is current.
Fixtures recorded from a real device or the Homebridge plugin go in `Tests/Fixtures` (then
`exclude: ["Fixtures"]` on the test target), with tokens and serial numbers replaced.

Run the plugin's tests, then the whole suite once: `swift test --scratch-path ~/Library/Caches/homeswift-build`.

## 5. Check it on a bridge

Build `homeswift`, write the platform block to a file, and run it on a throwaway bridge:

```bash
swift build --scratch-path ~/Library/Caches/homeswift-build --product homeswift
echo '{"platform": "<pluginAlias>", "name": "<Display Name>"}' > /tmp/block.json
.claude/skills/homeswift-plugin/scripts/check-on-bridge.sh /tmp/block.json ~/Library/Caches/homeswift-build/debug/homeswift
```

It starts the bridge in a temporary directory with its MCP server on, prints `list_accessories` and the plugin's
log lines, and stops it. Without devices, expect the plugin's own "cannot reach" messages and no crash; with the
user's devices (ask for the block, never for credentials in chat), the accessories should match what the
Homebridge plugin shows. Do not leave a bridge running: two bridges with the same identity make the Home app
drop pairings.

## 6. Finish

- `THIRD-PARTY-NOTICES.md`: the ported plugin's copyright and permission notice, and the paths ported from it. A
  translation into Swift still owes the notice.
- `README.md`: what it does, the configuration, the ported plugin with its authors and license, the
  maintainer, and how it was tested. "Experimental" until someone tested it on the devices.
- A line in `CHANGELOG.md` under `[Unreleased]`, section `Added`.
- Go through `CONTRIBUTING.md`'s "What a plugin needs" and the pull request template, and tell the user which
  items are not done (the hardware test, usually) rather than ticking them.
- Commit only when the user asks.
