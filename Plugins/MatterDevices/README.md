# Matter Devices

Matter devices another app already has (Apple Home, Google Home, Amazon Alexa, SmartThings, a maker's app), controlled by
Homeswift too: Homeswift becomes one more Matter controller of theirs, on a fabric of its own (multi-admin, Matter Core
§5.5). The other apps keep the device; Homeswift shows it in HomeKit through the bridge, on the web UI, to the MCP server
and the Assistant, and a remote's wheel can dim any light of the bridge.

No Homebridge plugin does this. Home Assistant's Matter integration (python-matter-server, on connectedhomeip) is what
people would otherwise run; [What differs](#what-differs) lists what it does that this does not.

## Adding a device

1. In the app that has the device, turn on its pairing mode for another app. In Apple Home: the accessory's settings,
   **Turn On Pairing Mode**; it shows a pairing code (11 digits, or a QR code) and keeps the window open for about
   15 minutes.
2. In Homeswift, **Add accessories**, Matter Devices, **Add a Matter device…**, and enter that code. A pairing window
   found on the network is listed there too.

Homeswift finds the device whose window matches the code (DNS-SD `_matterc._udp`, Core §4.3.1), opens a PASE session with
the code, checks its attestation against the Matter registry, gives it an operational certificate on Homeswift's fabric
and ends commissioning over CASE.

A certified device is added straight away. One whose certification does not check out (a development board, a homemade
device, a product newer than Homeswift's copy of the registry) gets a question first, saying why: **Add it anyway** goes
on with its own signatures still checked, as the specification lets a commissioner do with the person's consent (Core
§5.5, step 10). A device whose signatures or certificate chain are wrong is never added. The device must already be on the network (Wi-Fi, Ethernet, or Thread through a border router):
Homeswift does not commission over Bluetooth, so a brand new device goes into one app first.

**Forget** in the device's settings removes Homeswift from the device (Operational Credentials' RemoveFabric) and keeps
every other controller. Adding it again needs a new pairing code.

## What it shows

| Matter (Application Clusters, Device Library) | HomeKit |
|---|---|
| On/Off on a light (On/Off, Dimmable, Color Temperature, Extended Color Light), with Level Control | Lightbulb (On, Brightness: CurrentLevel 1–254 as 1–100 %; writes MoveToLevelWithOnOff) |
| On/Off on a plug-in unit | Outlet |
| On/Off elsewhere | Switch |
| Boolean State (a contact sensor's StateValue, true in contact) | Contact Sensor |
| Occupancy Sensing | Occupancy Sensor |
| Temperature Measurement, Relative Humidity Measurement | Temperature and Humidity Sensors |
| Switch (a button or a remote's part) | a Stateless Programmable Switch per endpoint, numbered under a Service Label: MultiPressComplete counts single and double presses, LongPress a long press; a rotary part (no long press, MultiPressMax above 3) gives one single press per turn |
| Power Source with a battery (its BAT feature: BatPercentRemaining, BatChargeLevel) | Battery |
| Identify | Identify blinks or beeps it for 5 seconds |

A bridge (an Aggregator with Bridged Nodes) gives an accessory per bridged device, named by its NodeLabel, with id
`MatterDevices:<Device Id>:<endpoint>`; a device on its own is `MatterDevices:<Device Id>`. The Device Id is the node id
Homeswift gave it on its fabric, 16 hexadecimal digits.

## A remote's wheel

A remote whose Switch endpoints come in pairs of rotary parts, with a button after them (IKEA BILRESA's scroll wheel: three
channels, endpoints 1/2/3, 4/5/6, 7/8/9), is a Remote with a Wheel and a Button per Channel (GLOSSARY.md). What each does
is set on the Remotes page (Automations › Remotes), as for any plugin's remote: the plugin reports each moment
(`MatterRemote`), and the bridge runs its Controls. A turn reports MultiPressOngoing with the notches counted so far,
about twice a second; each new notch is one more step of the Wheel. The button's single and double presses come once the
remote's multi-press window closes (MultiPressComplete); LongPress starts a hold and LongRelease ends it.

The plugin page names each channel's Home app buttons ("Button 1 up, 2 down, 3 press"), the Home app numbering a
remote's buttons without names, and opens its Wheel on the Remotes page. Any button's press can also start an Automation
(**When a button is pressed**).

## Power On

A light keeps what it does when its power comes back in its StartUp attributes (Application Clusters §1.5.6.6,
§1.6.6.15, §3.2.7.23), on its settings sheet as its Power On (or `set_power_on`): Last on (StartUpOnOff 1, the level
and white null), Power loss recovery (null), Off (0) and Custom (1 at a level and, with Color Control, a white). A light
with Color Control also has the bridge's Natural Light: as it was, at the StartUpColorTemperatureMireds the bridge keeps
the time of day's. Homeswift's fabric is an administrator's, so it may write them (they need Manage).

## Network

Homeswift reaches its nodes by DNS-SD (`_matter._tcp`, the instance named by its compressed fabric id and the node id) and
keeps the last address for when no record answers. A Thread device answers through a Thread border router (a HomePod, an
Apple TV, a hub), so the bridge's host needs IPv6 routes to the Thread network, which border routers announce in their
Router Advertisements as Route Information Options (`netstat -rn -f inet6` shows them on macOS, `ip -6 route` on Linux).
A battery device sleeps:
Homeswift retransmits to it from its idle interval (Matter Core §4.12.8), so a command or a first connection can take
several seconds. Each node keeps one subscription (minimum interval 0, urgent Switch events, a maximum interval of 60
seconds that the device may raise to its idle time); a subscription that goes quiet for longer than it promised is opened
again from the event after the last one delivered, so presses are never replayed.

A Linux kernel built without Route Information Options (`CONFIG_IPV6_ROUTE_INFO`; a Synology NAS's has none, and
`/proc/sys/net/ipv6/conf/*/accept_ra_rt_info_max_plen` is then missing) never learns the Thread network's route: the
device's address goes to the default route, and nothing answers. Setup then says the server has no route to the Thread
network and names its prefix. Add the route by hand, through the border routers, as root (the interface is the one on
the border routers' network; `append` adds the others as fallbacks):

```sh
ip -6 route add fd12:3456:789a::/64 via fe80::1c2b:3a4d:5e6f:7081 dev eth0
ip -6 route append fd12:3456:789a::/64 via fe80::9a8b:7c6d:5e4f:3a2b dev eth0
```

A Mac on the same network shows the prefix and a border router's link-local address (`netstat -rn -f inet6 | grep fd`);
`dns-sd -B _meshcop._udp` lists the border routers. A route added by hand is gone after a restart: run the commands at
boot (on a Synology NAS, a Triggered Task at Boot-up, run by root, in Control Panel > Task Scheduler). The prefix only
changes when the Thread network is made anew.

## Storage

The fabric's keys (its root and operational private keys, its IPK epoch key) are in the bridge's vault
(`plugin.<instance>.matter-fabric.json`); each node's credentials (its node id) are its Authorization. The plugin keeps a
file per node (`node-<Device Id>.json`: its name, vendor, product and last address) in its folder.

## Against the specification

What the plugin and swift-matter's controller side do, where Matter 1.6.1 says so, and how each was checked. Each row
was read against the specification documents themselves (Core 23-27349-012, Application Clusters 23-27350-011, Device
Library 23-27351-011; swift-matter's docs/specifications.md says where to get them), and checked against
connectedhomeip, Matter's reference implementation, or a real device.

| Behaviour | Where | Checked |
|---|---|---|
| Commissioning: PASE, ArmFailSafe within 60 s, SetRegulatoryConfig with the device's fixed LocationCapability (else Indoor/Outdoor), attestation and CSR signatures, AddTrustedRootCertificate, AddNOC, UpdateFabricLabel "Homeswift" (the next free label on a LabelConflict), CASE, CommissioningComplete | Core §5.5 steps 6-13 and the setup phase, §6.2.3, §11.10.7.4, §11.18.6.11 | An IKEA BILRESA (firmware 1.9.15) commissioned over Thread; swift-matter's own node in the tests |
| Certificates in X.509: a time of 0 is 99991231235959Z, notBefore as notAfter | Core §6.5 | Byte for byte against connectedhomeip's conversion (`pychip_ConvertChipCertToX509Cert`); a start of 0 made the BILRESA refuse the root certificate, a real start date made it take it |
| Attestation: the PAA in the trusted roots (the 74 the Distributed Compliance Ledger approved, swift-matter's `AttestationTrustStore.registry`), DAC ← PAI ← PAA each valid at the DAC's notBefore, vendor and product ids in either encoding, the attestation signature and nonce; the Certification Declaration signed by one of the CSA's keys (the test key only for development declarations), its vendor and products against Basic Information and the certificates, its DAC origin and authorized PAAs | Core §6.2.2.2, §6.2.3.1, §6.3.1 | The BILRESA's chain (IKEA's PAA G1) and declaration verified live over CASE (`matter-probe attest`); tests of each refusal; the order of checks is connectedhomeip's `DefaultDACVerifier` |
| A device that fails its certification: the person told why (its root, its declaration's signer, the products it covers) and asked; added on their yes with its signatures checked; the fail-safe expired at once when commissioning stops, so the same window takes it | Core §5.5 step 10, §11.10.7.2 | Tests: an uncertified node asks, is not added on a no, is added on a yes |
| Pairing codes: manual (11 and 21 digits) and QR | Core §5.1.3, §5.1.4 | Five codes connectedhomeip generated (`SetupPayload`), across vendors, discriminators and flows |
| Commissionable and operational DNS-SD records: D, CM (1 and 2 only: 3 is Joint Fabric commissioning), VP, DT, DN, PH, PI; SII, SAI, SAT and T, an invalid value meaning the default; `<compressed fabric id>-<node id>` | Core §4.3.1.5-§4.3.1.12, §4.3.2.1, §4.3.4 | The BILRESA's and the demo device's records over real Bonjour; the instance name is the specification's own example |
| MRP: a new exchange's first message from the peer's idle interval unless PeerActiveMode (heard from within its active threshold); an unsecured session, which keeps no ActiveTimestamp, from idle; the record's intervals for the session's establishment; the 1.1 margin | Core §4.12.2.1, §4.13.2.1, §4.13.2.3 | Tests of the rule; the BILRESA (idle 9.5 s polls) commissioned and reached over CASE |
| Subscriptions: urgent Switch events (IsUrgent), KeepSubscriptions false, an EventFilterIB from the event after the last delivered, a new subscription when no report came within the max interval (plus the node's retransmission time, as connectedhomeip) | Core §8.5, §8.5.2.3, §10.6.6, §10.6.8 | Tests on swift-matter's node; the BILRESA's subscription (max interval 900 s) kept alive by its keep-alives for an hour |
| A list sent as appends put back together | Core §10.6.4.3.1 | Tests |
| RemoveFabric (Forget) and its NOCResponse | Core §11.18.6.10, §11.18.6.12 | On the BILRESA: the probe's fabric removed; tests on swift-matter's node |
| Switch events to HomeKit presses: MultiPressComplete counts (0, an aborted sequence, is no press), LongPress, ShortRelease and InitialPress for switches without multi-press; a turn's MultiPressOngoing counts from 2 | Application Clusters §1.13.4, §1.13.5.3, §1.13.6, §1.13.7, §1.13.8 | The BILRESA's live events (running counts about twice a second); tests |
| Level: CurrentLevel 1–254 (MinLevel 1 and MaxLevel 254 for lights) as 1–100 %, MoveToLevelWithOnOff with a null TransitionTime | Application Clusters §1.6.6.2, §1.6.6.4, §1.6.6.5, §1.6.7.1, §1.6.7.6 | The demo device's lights; the Matter bridge's conversion is the same function |
| Power Source: a Battery only with the BAT feature; BatPercentRemaining in half percents (0–200, null unknown); BatChargeLevel OK, Warning, Critical | Core §11.7.4, §11.7.6.6, §11.7.7.13, §11.7.7.15 | The BILRESA (FeatureMap 10: BAT and REPLC) |
| Sensors: a contact sensor's StateValue true when closed (in contact); Occupancy bit 0; temperature in hundredths of a degree, null unknown; humidity as 100 × % (0–10000) | Application Clusters §1.7.5.1, §2.7.6.1, §2.3.4.1, §2.6.4.1; Device Library §7.1 | Tests; the demo device |

The documents are not in this repository: the CSA's terms keep them to their own site.

## What differs

Against Home Assistant's Matter integration (python-matter-server), as its documentation described it in November 2026:

- **Attestation**: checked against a copy of the Distributed Compliance Ledger's PAA roots built into Homeswift (updated
  with swift-matter), where Home Assistant fetches them from the ledger; a PAA approved since then is unknown until the
  next update, and the person is asked. Revocation (Core §6.2.4) is not checked.
- **Commissioning**: over the network only, with a pairing window another controller opened; no Bluetooth, no Wi-Fi or
  Thread credentials handed to a new device, no Terms and Conditions acknowledgement, no Joint Fabric (CM 3), and no
  time set on a device with Time Synchronization (a SHOULD after commissioning).
- **AdminVendorId**: AddNOC's SHALL be a vendor in the Ledger's vendor schema; Homeswift has no CSA vendor id and sends
  the test vendor 0xFFF1, as open-source controllers do.
- **Clusters**: the table above. No colour (Color Control), covers, locks, thermostats, fans, air quality, energy,
  media or OTA updates yet; those show nothing in HomeKit.
- **ICD**: a Long Idle Time device that needs Check-In registration is not registered; short idle devices (BILRESA) work.
- **Groups and bindings**: not written; the wheel's dimming runs on the bridge.
