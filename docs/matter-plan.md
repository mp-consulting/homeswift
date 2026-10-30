# Matter in Homeswift: implementation plan

Draft, from the Matter 1.6.1 specifications (Core `23-27349-012`, Application Clusters `23-27350-011`, Device Library
`23-27351-011`, Standard Namespaces `23-31936-009`). Section numbers below are the Core specification's unless said
otherwise.

## Goal

Make Homeswift a **Matter bridge** (Core §9.12) beside the HAP bridge: the accessories plugins already publish
appear in Google Home, Amazon Alexa, SmartThings, Home Assistant and Apple Home through Matter, with no change to the
plugins. Homeswift is to Matterbridge what it is to Homebridge.

Out of scope for the first releases: Thread, Bluetooth (BTP §4.19), Wi-Fi PAF and NFC commissioning (the bridge is
already on the network, so it is commissioned over IP), being a controller, OTA, ICD (sleepy devices), cameras
(Device Library §16), Joint Fabric (§12.2), TLS clusters (§14).

## What the specification asks of a bridge

**Node layout** (§9.12.2, Device Library §2.1, §2.5, §11.2)

| Endpoint | Device types | Clusters |
|---|---|---|
| 0 | Root Node `0x0016` | Descriptor, Basic Information, Access Control, General Commissioning, Network Commissioning (Ethernet/Wi-Fi feature), General Diagnostics, Administrator Commissioning, Operational Credentials, Group Key Management, Localization/Time Format/Unit Localization (optional) |
| 1 | Aggregator `0x000E` | Descriptor (`PartsList` = every bridged endpoint), Actions (optional: rooms as `EndpointLists`, §9.12.2.1) |
| 2… | e.g. Extended Color Light `0x010D` + Bridged Node `0x0013` | Descriptor, Bridged Device Basic Information (`0x0039`: NodeLabel, Reachable, UniqueID), the device type's clusters, Power Source when the device has a battery |

- **Dynamic endpoints** (§9.2.10): a new bridged device gets the next endpoint number above the highest ever used,
  never a reused one; an existing device keeps its number across restarts. This is Matter's version of our aid/iid
  rule: persist `accessory id + service key → endpoint` the way `aid/serviceUUID/subtype` is persisted today.
- Adding or removing a device updates the Aggregator's `PartsList`; controllers subscribe to it.
- `Reachable` in Bridged Device Basic Information follows the plugin's "not responding" state.
- Lights need Identify, Groups, On/Off, Scenes Management (Device Library §4.1). Groups stays mandatory during the
  Groups→Groupcast migration (§2.12); group *messaging* (§4.16, multicast, group keys) can come after unicast.

**Stack minimums** (§2.11): at least 5 fabrics in practice (4 ACL entries per fabric), 3 subscriptions per fabric,
a Read of 9 paths per fabric, subscription max interval ceiling of 60 minutes, one group key per fabric (the IPK).

**Network** (§4.2): IPv6 is mandatory. A link-local address is enough on one Ethernet/Wi-Fi link. Transport is UDP
(with the Message Reliability Protocol, §4.12); TCP (§4.15) is optional.

## The protocol stack, bottom up

| Layer | Spec | Work |
|---|---|---|
| TLV | Appendix A–C | Matter TLV (not HAP's TLV8): context/profile tags, structs, arrays, lists, signed/unsigned ints, floats, UTF-8/octet strings, null. Encoder, decoder, a `TLVValue` enum |
| Crypto primitives | §3 | SHA-256, HMAC, HKDF (swift-crypto). **AES-128-CCM** (§3.6, 16-byte MIC, 13-byte nonce): not in swift-crypto, built on `CryptoExtras.AES.permute` (public block function). **Privacy** AES-CTR (§3.7). ECDSA/ECDH P-256 (swift-crypto). PBKDF2-SHA256, 1,000–100,000 iterations (§3.9) |
| SPAKE2+ | §3.10 | P-256, SHA-256, **draft-02** M and N points, context "CHIP PAKE V1 Commissioning". Needs arbitrary-point scalar multiplication and point addition, which swift-crypto keeps internal (`ECToolbox` is not public). A C target `CP256` (fiat-crypto's P-256 field, the way `CHAPMath` does SRP) with a Swift wrapper; checked against the draft-02 vectors and connectedhomeip's |
| Messages | §4.4–4.9 | Message header (flags, session id, counter, source/destination node ids), protocol header (exchange id, protocol id/opcode, ack). Counters and duplicate detection windows (§4.6), encryption with the session keys (§4.8), privacy obfuscation (§4.9) |
| Exchanges and MRP | §4.10, §4.12 | Exchange manager (initiator/responder, timeouts), MRP: piggybacked and standalone acks, retransmissions with backoff and jitter, idle/active intervals advertised in DNS-SD |
| Secure Channel | §4.11, Appendix D | Status Report, MsgCounterSyncReq/Rsp (§4.18) later |
| PASE | §4.14.1 | PBKDFParamRequest/Response, Pake1/2/3 → session keys I2R/R2I/attestation challenge |
| CASE | §4.14.2 | Sigma1/2/3 with ECDH + NOC signatures, destination id from the IPK, Sigma2_Resume (session resumption) |
| Certificates | §6.1, §6.4, §6.5 | Matter TLV certificates ↔ X.509 DER: signatures are over the DER TBS, so a minimal DER encoder is needed (Root CA RCAC, ICAC, NOC). A small DER writer here; no new package |
| Attestation | §6.2, §6.3 | DAC, PAI, Certification Declaration (CMS signed). `AttestationRequest`, `CertificateChainRequest`, `CSRRequest` (PKCS#10 CSR, DER again) |
| Access control | §6.6, §9.10 | ACL entries per fabric (privilege View/Operate/Manage/Administer, subjects, targets); every IM action is checked |
| Data model | §7, §9 | Endpoints, clusters, attributes, commands, events, `DataVersion`, global attributes (`ClusterRevision`, `FeatureMap`, `AttributeList`, `AcceptedCommandList`, `GeneratedCommandList`), fabric-scoped and fabric-sensitive data |
| Interaction Model | §8, §10 | Read, Subscribe (+ ReportData with chunking to the MTU, keep-alive at MaxInterval), Write (timed writes, list chunking), Invoke (timed invoke), status codes (§8.10). Events with event numbers |
| Discovery | §4.3, §5.4 | `_matterc._udp` while commissionable (instance = random 64-bit hex, subtypes `_S<short discriminator>`, `_L<long>`, `_V<vendor>`, `_T<device type>`, `_CM`; TXT `D`, `CM`, `VP`, `DT`, `DN`, `SII`, `SAI`, `SAT`, `PH`, `PI`), `_matter._tcp` once operational (instance `<compressed fabric id>-<node id>`, one per fabric, subtype `_I<compressed fabric id>`) |
| Onboarding | §5.1 | Setup passcode (excluding 0, 11111111…99999999, 12345678, 87654321), 12-bit discriminator, 11-digit manual pairing code with Verhoeff check digit, `MT:` QR payload in Base38 |
| Commissioning | §5.5, §11.10, §11.18, §11.19 | Respond to: ArmFailSafe, SetRegulatoryConfig, attestation, CSR, AddTrustedRootCertificate, AddNOC, CommissioningComplete; fail-safe rollback; multi-admin through Administrator Commissioning's `OpenCommissioningWindow` (Enhanced Commissioning Method: a new verifier sent by the existing admin) |
| Fabrics | §2.5, §11.18 | Fabric table: root public key, fabric id, node id, NOC/ICAC, IPK epoch key, label, vendor id; RemoveFabric; factory reset when the last fabric goes |

## Reusing what Homeswift has

| Need | Homeswift today | Gap |
|---|---|---|
| Networking | SwiftNIO everywhere | UDP over IPv6 (`DatagramBootstrap` on `::`), link-local scope ids |
| mDNS | `BonjourAdvertiser` (dns_sd / Avahi) and the built-in `MDNSResponder` | The built-in responder is **IPv4 only** (no AAAA, no `ff02::fb`): Matter needs AAAA records and IPv6 multicast. dns_sd handles IPv6 itself, but subtypes (`_matterc._udp,_L840,_CM`) need checking on Avahi's compatibility layer |
| Crypto | swift-crypto (P-256, HKDF, SHA, HMAC), `Secrets` for constant-time compares, a C target pattern (`CHAPMath`) | AES-CCM, SPAKE2+ point arithmetic, DER |
| Persistence | `Storage`/`MemoryStorage`, `OwnerOnlyFile.write`, `PersistedDictionary` | A `MatterStorage` (fabrics, ACLs, counters, endpoint map, setup data) over the same storage |
| Device model | `Accessory`/`Service`/`Characteristic` with change events | A translation layer, below |
| Runtime | `PluginHost`, system platforms (`HomeswiftUI`, `HomeswiftAiKit` are started by the CLI) | A `HomeswiftMatter` system platform |
| UI and MCP | Pairing page with the HAP QR code; `HomeswiftCatalog` | A Matter card (QR code, manual code, fabrics with remove), MCP tools |

## Mapping HAP to Matter

The bridge reads each published `Accessory` and turns its services into Matter endpoints. Writes from Matter go
through the same characteristic setters as writes from Apple Home; plugins see no difference.

| HAP service | Matter device type | Conversions |
|---|---|---|
| Lightbulb (On) | On/Off Light `0x0100` | On ↔ OnOff |
| + Brightness | Dimmable Light `0x0101` | 0–100 % ↔ CurrentLevel 1–254 |
| + ColorTemperature | Color Temperature Light `0x010C` | mireds both sides (HAP 140–500) |
| + Hue/Saturation | Extended Color Light `0x010D` | Hue 0–360 ↔ 0–254, Saturation 0–100 ↔ 0–254 (Enhanced Hue for precision) |
| Outlet / Switch | On/Off Plug-in Unit `0x010A` | On ↔ OnOff |
| ContactSensor | Contact Sensor `0x0015` | Boolean State: **inverted** (HAP 0 = detected = contact) |
| MotionSensor / OccupancySensor | Occupancy Sensor `0x0107` | bitmap |
| TemperatureSensor | Temperature Sensor `0x0302` | °C float ↔ int16 in 0.01 °C |
| HumiditySensor | Humidity Sensor `0x0307` | % ↔ uint16 in 0.01 % |
| LightSensor | Light Sensor `0x0106` | lux ↔ 10000·log10(lux)+1 |
| AirQualitySensor | Air Quality Sensor `0x002C` | index + concentration clusters |
| LeakSensor | Water Leak Detector `0x0043` | Boolean State |
| SmokeSensor / CO | Smoke CO Alarm `0x0076` | |
| WindowCovering | Window Covering `0x0202` | Position 0–100 % open ↔ Percent100ths **closed** (inverted, ×100) |
| Thermostat / HeaterCooler | Thermostat `0x0301` | modes, setpoints in 0.01 °C |
| Fanv2 | Fan `0x002B` | Active, RotationSpeed ↔ PercentSetting/SpeedSetting |
| AirPurifier | Air Purifier `0x002D` | Fan + filter monitoring |
| LockMechanism | Door Lock `0x000A` | see Security |
| StatelessProgrammableSwitch | Generic Switch `0x000F` | events: InitialPress, ShortRelease, MultiPressComplete, LongPress |
| Valve | Water Valve `0x0042` | |
| Battery (alongside) | + Power Source `0x0011` on the same endpoint | percent ↔ BatPercentRemaining (×2) |
| Television, cameras, others | not bridged at first | |

One HAP accessory with several application services (a fan with a light) becomes a compound bridged device: the
Bridged Node endpoint at the top, one endpoint per function in its `PartsList`, with Descriptor `TagList` from the
Standard Namespaces to name each part (§9.12.2.1).

Rooms: Homeswift's accessory layout (rooms in `ui-layout.json`) can fill the Actions cluster's `EndpointLists`.

## Identity and certification

Commissioners verify the device attestation chain (§6.2): DAC → PAI → a PAA in the Distributed Compliance Ledger,
plus a Certification Declaration signed by the CSA.

- Homeswift is not a certified product, so it uses the **test Vendor ID `0xFFF1`** (§6.2 lists the test VIDs) with
  a test PAA, a PAI and DAC generated per installation, and a CD signed with the published test CD signing key, as
  Matterbridge and matter.js do with connectedhomeip's test credentials (Apache 2.0, credited in
  `THIRD-PARTY-NOTICES.md`).
- Consequence to verify per ecosystem before promising it: Apple Home commissions test devices with an "uncertified
  accessory" warning; Google Home needs a developer project with the VID/PID; others vary. A spike against each is
  Phase 1's exit test.
- A real VID and certification (CSA membership, testing) is a business decision outside this plan.

## Architecture in the package

```
Sources/CP256              C: P-256 field and point arithmetic (fiat-crypto), for SPAKE2+
Sources/Matter             The protocol (no Homeswift types): TLV, Crypto (CCM, SPAKE2+, DER, certificates),
                           Messages (codec, counters, MRP, exchanges), SecureChannel (PASE, CASE, sessions),
                           DataModel (generated cluster definitions, endpoints), InteractionModel (read, write,
                           subscribe, invoke, ACL), Commissioning (fabrics, attestation, fail-safe),
                           Discovery (DNS-SD records), Onboarding (QR, manual code), MatterServer, MatterStorage
Sources/HomeswiftMatter    The bridge: HAP → Matter mapping, endpoint allocation, the `HomeswiftMatter` config
                           block, a system platform started by the CLI like HomeswiftUI
Scripts/generate-matter-definitions.*   Cluster/attribute/command/event ids and types from connectedhomeip's
                           data_model XML (itself generated from this spec): MatterDefinitions.swift, like
                           Definitions.swift for HAP. Never hand-typed ids
Tests/MatterTests          Vectors and a Swift controller (`MatterTestController`, the counterpart of TestController)
Tests/HomeswiftMatterTests The bridge with a recording plugin
```

Configuration, Homebridge-shaped:

```json
{ "platform": "HomeswiftMatter", "port": 5540, "passcode": 20202021, "discriminator": 3840,
  "include": ["PhilipsHue", "ElgatoKeyLights"], "exclude": ["Lock*"] }
```

Port 5540 is Matter's default. Passcode and discriminator are generated on first start and stored, never logged.

## Phases

Each phase ends green on macOS and Linux (CI runs the tests on Linux) and is a slice of one branch.

1. **Foundations.** TLV with Appendix A/C examples as tests; AES-CCM (NIST SP 800-38C vectors and the spec's message
   examples); `CP256` + SPAKE2+ (draft-02 vectors); PBKDF2; DER writer and Matter↔X.509 certificate conversion (the
   §6.5 examples); onboarding payloads (§5.1 examples: Verhoeff, Base38). Pure functions, no networking.
2. **Messages and sessions.** Message codec, counters, unsecured and secure sessions, exchanges, MRP with an injectable
   clock and `timeScale` (no fixed sleeps in tests), UDP on IPv6 over NIO. PASE end to end against
   `MatterTestController`.
3. **Commissioning.** Root endpoint clusters, fail-safe, attestation with the test credentials, CSR, NOC/RCAC/ICAC,
   fabrics, CASE (Sigma1/2/3, resumption), ACL enforcement, `_matterc` and `_matter` advertising (IPv6 in the
   built-in responder). Exit test: **chip-tool** `pairing onnetwork` and `onoff toggle` against a demo endpoint, then
   Apple Home and Google Home by hand.
4. **Interaction Model.** Read, Write, Invoke, Subscribe with chunking, events, timed interactions, DataVersion
   filters; the generated definitions; stack minimums of §2.11.
5. **The bridge.** `HomeswiftMatter`: endpoint allocation with persistence, Aggregator and `PartsList` updates, the
   mapping table, reachability, compound devices, rooms via Actions; `homeswift-demo` gets a Matter mode.
6. **Product.** UI card (QR code, manual code, fabrics, open a commissioning window for another ecosystem), MCP tools
   (`get_matter_status`, `open_matter_commissioning_window`, `remove_matter_fabric` as destructive), translations,
   docs/matter.md, Docker/Synology notes (host networking with IPv6), the site's feature list.
7. **Later.** Groups messaging and Groupcast, TCP, more device types (energy, closures, RVC), OTA Provider for a real
   VID, session resumption tuning, benchmarks against Matterbridge in `Benchmarks/`.

## Testing

- Every crypto piece against published vectors; nothing compared only against itself.
- `MatterTestController` drives the server in-process (PASE, commissioning, CASE, IM), as `TestController` does for HAP.
- Interop in CI on Linux: connectedhomeip's `chip-tool` (or python-matter-server) in a job against `homeswift-demo`.
- Manual matrix per release: Apple Home, Google Home, Alexa, SmartThings, Home Assistant.

## Security

- Never log the passcode, the verifier, keys, NOCs' private keys, or PASE/CASE bodies (sizes only), as for HAP.
- Door locks, garage doors and alarms: exposed only when the user includes them in `HomeswiftMatter`'s config, off by
  default, because a Matter controller bypasses the MCP's `set_security_accessory` confirmation.
- Fabric-scoped ACLs checked on every path; the commissioning window closes after 15 minutes at most (the spec's maximum).
- Operational private key and fabric data written with `OwnerOnlyFile.write`.

## Risks and open questions

- **Duplicates in Apple Home**: the same devices through HAP and Matter. The docs should say to pair Apple Home over
  one of them, and the config's `include`/`exclude` makes it per plugin.
- **IPv6 on the host**: Docker without IPv6 or host networking, Synology with IPv6 off. Detect and log at start.
- **Ecosystem acceptance of test credentials** changes over time; Phase 3's manual checks decide what docs promise.
- **SPAKE2+ C code** is new attack surface; keep it small and vector-tested, or reuse an audited field implementation.
- **Size**: a Matter server is several times HAP's code. matter.js (Apache 2.0) is the closest structural reference for
  a port, as HAP-NodeJS was for HAP; connectedhomeip is the reference for behaviour.
