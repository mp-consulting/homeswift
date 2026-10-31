# Accessory Settings live in one canonical map keyed by Device Id

Plugins ported from Homebridge kept their option shapes, so per-device settings were keyed by `mac`, `serial`,
`serialNumber`, `id`, `deviceId`, `host` or `address`, spread over `devices[]`, typed arrays (eWeLink's 7, Govee's 11)
or feature-option strings (UniFi), with about six spellings of exclusion. Each plugin block now holds its Accessory
Settings in one `_accessories` map keyed by Device Id (underscored like the runtime's other keys, `_bridge` and
`_paused`, and so never confused with Homebridge's top-level `accessories`), with Excluded as a core setting; a plugin declares its Plugin
Accessory Settings in its schema. Homebridge shapes are accepted on read only: each plugin migrates its legacy shape
into the map, and the bridge always writes the canonical one. This narrows the rule that plugins keep their
Homebridge option names to "a pasted Homebridge config.json still loads".

## Considered Options

- Keep each plugin's Homebridge shape: one shared Setup flow, settings form and MCP surface could not address a
  device without per-plugin knowledge of its key and list.
- Write both shapes: two sources of truth that drift.
