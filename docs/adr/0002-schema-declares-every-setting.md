# A plugin's schema declares every setting, and plugin pages never write them

Settings were edited along about six paths: the Expert form, the raw config.json editor, each plugin's own page, Setup's
exclude and part routes, and MCP tools from `patch_config` to `put_list_entry`. Plugin pages wrote their Homebridge
shapes (`devices[]` by `mac`, exclude lists, typed arrays) and skipped schema checks, and Plugin Accessory Settings were
declared nowhere, so no form showed them and nothing checked them. A plugin's `config.schema.json` now declares every
setting it stores: its Plugin Settings and, in an accessory section, its Plugin Accessory Settings (fields may depend on
the Device Kind, and one may take a plugin-wide default from Plugin Settings). One generic editor draws them on the web
UI, Setup's last step draws the same fields, and MCP and the command line read and write them through `get_settings`
and `update_settings`, by plugin instance or Accessory Id. Every write is checked against the schema; only the raw
config.json editor's "Save anyway" and the raw-config MCP tools' `ignoreSchema` skip it. A plugin's page may show
views, diagnostics and actions, but writes no settings. `SetupField` is left to the questions Authorization asks, which
are answers, never stored settings.

## Considered Options

- Keep plugin pages as their settings editors: every plugin would need its own form for the same Core Accessory
  Settings, agents would reach fields the pages hid (or the reverse), and each page would keep its own shape and checks.
- Declare settings in Swift with `SetupField` grown to numbers, toggles and validation: a second declaration beside the
  schema Homebridge plugins already ship, which a pasted Homebridge config still needs.
