# Vault

One place for every credential the bridge holds: the Assistant's provider keys, plugins' cloud and device logins,
and the tokens plugins write at runtime. This note is the design agreed before the work started.

## Today

- **Config secrets** are sealed in config.json by `SecretBox` (`enc:v1:`, ChaCha20-Poly1305) under `secrets.key`
  beside it; every save seals the plain ones, and the MCP server shows them as `__SECRET_…__` handles.
- **Runtime tokens** are not sealed: each plugin writes its own owner-only JSON file (eWeLink's
  `ewelink-tokens.json`, DaikinCloud's tokens, LGThinQ's session, Dirigera's `hubs.json`, EcoFlow's client file).
- A credential two plugins share (one UniFi login for Protect and Access) is typed, and rotated, twice.

The vault is about organisation and sharing: seeing, adding, rotating and revoking credentials in one place, and
one entry used by several plugins. It does not move the key away from the data: a passphrase at start would break
unattended restarts on a Synology or in a container.

## References

config.json holds references in place of values; the scheme names the backend.

| Reference | Backend |
|---|---|
| `vault:unifi-home` | The local vault, always there, the default |
| `env:UNIFI_PASSWORD` | An environment variable |
| `file:/run/secrets/unifi` | A file (Docker secrets) |
| `op://Home/UniFi/password` | 1Password through a Connect server (REST, on the network); the syntax 1Password's "Copy secret reference" gives |
| `hcv://kv/homeswift#unifi` | HashiCorp Vault (KV v2; token or AppRole) |
| `keychain:unifi-home` | Later: the macOS login keychain, on a bridge running on a Mac (no iCloud sync) |

Each backend is a resolver behind a small protocol in the runtime. The order they land in: local, `env:`, `file:`,
then 1Password Connect, then HashiCorp Vault; the login keychain and 1Password's `op` CLI with service accounts later.
Backends talk plain HTTP through `HTTPClient`, no SDK.

- **Read-only outside.** External backends hold a person's static credentials; the bridge never writes to them.
  Runtime tokens always go to the local vault.
- **When they are read.** At start and when a config is applied. The runtime resolves references before a plugin
  reads its config.
- **When they do not answer.** The bridge starts with the last value it read, kept sealed in the local vault;
  `noCache` on a reference keeps nothing on disk (and that plugin waits for its backend).
- **Bootstrap.** The 1Password Connect and HashiCorp Vault tokens are `vault:`, `env:` or `file:` references, never
  held by another external backend.

## The local vault

`vault.json`, beside config.json, owner-only (`OwnerOnlyFile.write`), each value sealed by the existing
`secrets.key`, so instance backups and restores work unchanged.

An entry has:

- a name (`unifi-home`), a kind (`login` with a username and a password, `apiKey`, `token`) and its fields;
- created, last changed, last used, an optional expiry;
- who owns it: a person, or a plugin instance (its namespace, `EWeLink/<instance>/tokens`);
- **used by**: the plugin instances whose config references it, worked out from config.json, so deleting an
  entry something still needs warns first.

## Who reaches it

- **Plugins.** `context.vault` gives a plugin instance the references in its own config block and its own
  namespace for runtime entries, nothing else: no plugin reads another's login or the Assistant's key by name.
- **The web UI.** A Vault page, administrators only. Values are write-only: set, replace, rotate, delete; a saved
  value is never shown again. Each entry shows its health: resolves, cached copy in use, failing, expiring soon.
- **Plugin forms.** Every password field (`x-schema-form: password`, or a secret-named key) gets a picker: an
  entry, a new one, or a reference pasted (`op://…`). Plugins change nothing.
- **MCP and the Assistant.** Tools list entries' names, kinds, used by and health; none reads a value, and none
  writes one (values are set in the UI only). Migration is the one write (below). `HOMESWIFT_ALLOW_SECRETS` stays
  as it is for inline secrets.
- **Masking.** Every resolved value is given to `Redaction`, so the exact strings are masked in logs, MCP output
  and Assistant prompts, on top of today's key-name and shape rules.
- **Audit.** Creates, replaces, deletes and migrations go to the audit log with who made them; reads only update
  last used.
- **Health.** The daily digest and the Status page report failing and expiring entries.

## Migration

Existing configs move to the vault on request; nothing is rewritten without it.

- **Where.** The Vault page's "Move to the vault", `homeswift vault migrate` (`--dry-run`), and an MCP tool
  behind `ToolCall.confirm` (it moves sealed values, never shows them). One implementation in `HomeswiftCatalog`.
- **Plan first.** Every secret found (plugin, instance, field), the entry it becomes, the identical values merged,
  the reference that replaces it. Names are suggested from the platform and instance
  (`unifi-protect-home-password`, the platform alone for a single instance; a merged entry after what its users
  share) and editable; a merge can be split; fields and whole plugins can be left out.
- **What it moves.** Sealed `enc:v1:` values, plain-text secrets of older configs, fields a schema marks as
  passwords. `env:` and `file:` values and the Assistant's empty key (which reads the environment) stay.
- **Where to.** Always the local vault. Moving a credential to 1Password afterwards is replacing that entry with an
  `op://` reference; config.json, which names the entry, does not change.
- **Undo.** A config backup is taken before applying (`list_config_backups`, `restore_config`).
- **Runtime tokens.** A plugin's own token files move into its namespace the first time it starts on the new
  version, without asking.
- **After.** Once migrated, a plain secret arriving in a config save (the form, `patch_config`, an old backup
  restored) becomes a vault entry and config.json gets its reference. Installs that never migrate keep inline
  sealing.

## Not doing

- An "Export for Homebridge" with values inline: it would be a plain dump of every credential. A migrated
  config.json is no longer a drop-in for Homebridge; credentials are typed again there.
- Reading the Passwords app's or Safari's iCloud Keychain entries: third-party apps cannot.
- A key kept away from the data (a passphrase at start, a hardware key) for now.
