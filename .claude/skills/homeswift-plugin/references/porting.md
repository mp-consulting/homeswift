# Node.js to Swift, for plugin ports

`docs/plugins.md` has the HAP side (Homebridge API → Homeswift API). This file is the JavaScript side.

| Node.js | Swift in Homeswift |
|---|---|
| `setInterval(fn, ms)` | A loop in `tasks.add { … try? await Task.sleep(for: …) }`, cancelled by `tasks.cancelAll()` in `stop()` |
| `setTimeout` for a retry | `Backoff` (HomeswiftNetwork) for the delays, in a task of the bag |
| `EventEmitter` / `.on('data')` | An `AsyncStream` the plugin iterates in a task; `makeStream()` gives the continuation |
| A `Promise` | `async throws` |
| Debounced slider writes | `LatestCallGuard` (HomeswiftPlugin) |
| `Buffer` | `Data` / `[UInt8]`; `readUInt16BE` and friends by hand, with tests on bytes from the source |
| `crypto.createCipheriv('aes-…')` | swift-crypto (`AES.GCM`, `ChaChaPoly`); AES-CBC is `AES._CBC` from `_CryptoExtras` (see `Plugins/DysonPureCool`) |
| `crypto.createHash` / `createHmac` | `SHA256.hash`, `HMAC<SHA256>` |
| `JSON.parse` of loose device JSON | `JSONValue`, or `Decodable` with every field optional |
| `parseInt`, `Math.round` on device numbers | `Int(saturating:)`, `JSONValue.saturatingIntValue`, `x.finite`: `Int(x)` traps on NaN |
| `encodeURIComponent` in a signed request | `URLEncoding` (byte for byte like JavaScript) |
| `axios` with `rejectUnauthorized: false` | `HTTPClient` with `tls: .any` or `.pinned(fingerprint)`, `HTTPClient.TrustOnFirstUse` |
| `mqtt.connect(url)` | `MQTTClient(MQTTConfiguration(url:clientID:))` |
| `ws` | `WebSocket.connect(to:options:)` |
| `dgram` broadcast discovery | `UDPSocket`, `localIPv4Networks()` |
| `bonjour-service` / `mdns` | `BonjourBrowser.browse(type:)`, or `MDNSQuery` when the sender's address matters |
| `api.user.storagePath()` + a token file | `context.secretFile(_:as:)` (sealed in the vault, keeps the Homebridge file's name so a copied one moves in); `context.jsonFile(_:as:)` or `PersistedDictionary` for what is not a secret |
| `homebridge-ui/server.js` routes | `handleWebRequest(_:)`; its `public/` page goes in `Web/` (`docs/ui.md`) |
| `fakegato-history` | `EveHistory` |

## Things that differ

- **Ids.** Homebridge derives a UUID from a seed (`api.hap.uuid.generate(seed)`); Homeswift takes the id itself.
  Use the same seed after the platform prefix, so a user moving from Homebridge keeps one accessory per device.
- **The cache.** Homebridge hands cached accessories to `configureAccessory`; Homeswift restores them itself and
  `context.add` with the same id replaces one. Drop the port's cache bookkeeping.
- **Characteristic values.** Set `characteristic.value` from polling; register `onRead` only when the stored value
  can be stale. A handler that throws makes the Home app show No Response.
- **Concurrency.** The plugin is an actor. Handlers capture the device client, not the plugin. Swift 6 checks
  `Sendable` at compile time: a type crossing tasks is a struct of `Sendable` values, an actor, or locked.
- **Linux.** `URLSession` needs `import FoundationNetworking` behind `#if canImport(FoundationNetworking)`;
  CoreBluetooth, Network.framework and `dnssd`-only calls are Darwin-only.
