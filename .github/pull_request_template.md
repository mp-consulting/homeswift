<!-- What changes, and why. Link the issue: "Closes #…". -->

## Checklist

- [ ] `swift test` passes on macOS; nothing Darwin-only outside `#if canImport(...)` (CI runs Linux)
- [ ] User-visible changes have a line in `CHANGELOG.md` under `[Unreleased]`
- [ ] Generated files are current (`Scripts/embed-assets.swift` after editing a schema or a `Web/` page)

### A new plugin

Delete this section if the pull request adds no plugin. CONTRIBUTING.md explains each line.

- [ ] Proposal issue: #
- [ ] Created with `Scripts/new-plugin.swift`, or has the same layout and registration
- [ ] Same platform name and option names as the Homebridge plugin; a Homebridge block works unchanged
- [ ] Accessory ids are `<platform>:<stable device id>`
- [ ] Every light with Brightness and Color Temperature has Adaptive Lighting, turned off by colour changes made outside HomeKit; `check-on-bridge.sh` names none without it
- [ ] Tests use fake transports: no device, account or network
- [ ] No token, password, key or setup code is logged
- [ ] No new package dependency
- [ ] Light on the bridge: push or a bounded poll, backoff on failures, only changes set, writes coalesced; memory and CPU flat on the Status page
- [ ] README: what it does, the configuration, the ported plugin and its license, the maintainer
- [ ] The ported plugin's copyright and permission notice is in `THIRD-PARTY-NOTICES.md`
- [ ] Tested on real devices (which, and how), or marked experimental in the README
