# UniFi Access

Ubiquiti's [UniFi Access](https://ui.com/door-access) door access system in HomeKit: every hub and reader of
one or more controllers, found automatically and followed in real time through the controller's events.

A port of [`@mp-consulting/homebridge-unifi-access`](https://github.com/mp-consulting/homebridge-unifi-access), the
fork of HJD's [`homebridge-unifi-access`](https://github.com/hjdhjd/homebridge-unifi-access), Copyright (c) 2017-2026
HJD, under the ISC license; its notice is in [THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
The platform name (`UniFi Access`) is the same and a Homebridge block loads unchanged, `controllers` and the `options`
array of feature options included; what the bridge writes is the canonical shape ([Settings](#settings)).

| Device | In HomeKit |
|---|---|
| UA Hub | A lock (or a garage door opener), a doorbell, contact sensors for the door position sensor (DPS), remote release (REL), request to enter (REN) and request to exit (REX) |
| UA Hub Door Mini | A lock, DPS and REX contact sensors |
| UA Ultra | A lock, a DPS or REX contact sensor (whichever input mode the hub uses, followed live), access method switches |
| UA Hub Enterprise | One accessory per door (`<MAC>-PORT1`, `<MAC>-PORT2`…), each like a UA Hub |
| UA Gate | The gate as a garage door opener (opening, open, closing animated over `Hub.GateDirectionDuration`, the DPS confirming closed) or a lock; the side door (pedestrian gate) as a second lock with its own DPS sensor; doors found from the hub's port settings, the doors bound to it, or their names |
| UA readers, UVC G6 Entry | A switch per access method: Face, Hand Wave, Mobile, NFC, PIN, QR, TouchPass |

Locks are `LockMechanism` services (and the gate a `GarageDoorOpener`), so the MCP server only opens them
through `set_security_accessory`. The optional `Hub.Lock.Trigger` and `Hub.SideDoor.Lock.Trigger` switches exist,
as in Homebridge, to let automations work around HomeKit's confirmation for locks: plain switches to HomeKit, off
by default; leave them off unless you want that. Homeswift's own surfaces treat them as the locks they open
(security controls): MCP clients and the Assistant turn them only through `set_security_accessory`, after the
user confirmed, and the web UI asks first.

Names follow the controller (`syncName`), including a UA Gate's door names. With `sensorsSeparateAccessory`,
`doorbellSeparateAccessory`, `sideDoorSeparateAccessory` (a UA Gate's side door) and `accessMethodsSeparateAccessory`
the sensors, the doorbell, the side door and the access method switches get tiles of their own (accessory ids
`UniFi Access:<MAC>.<group>`); turning the setting off brings them back to the hub.

A hub's Parts (the side door, the wired door sensors, the doorbell) each have a switch on Add accessories and in its
Settings: the choice goes in the hub's Accessory Settings (`parts`) and acts as that hub's `Hub.<part>` option.

## Settings

Controllers come through Setup ([below](#setup)); the rest is on the plugin's Settings page
(`/plugins/unifi-access/settings`) and each device's Settings sheet, or `get_settings` and `update_settings` over MCP.

```json
{
  "platform": "UniFi Access",
  "name": "UniFi Access",
  "lockTrigger": false,
  "_accessories": {
    "001122334455": { "address": "1.2.3.4", "mqttUrl": "mqtt://user:password@1.2.3.4", "publishTelemetry": true },
    "AABBCCDDEEFF": { "lockDelayInterval": 5, "parts": { "DPS": false } },
    "112233445566": { "excluded": true }
  }
}
```

Each controller (Device Kind `controller`, by its MAC without separators), hub (`hub`, by its MAC; a door of a UA Hub
Enterprise `<MAC>-PORT1`) and reader (`reader`) has its Accessory Settings in `_accessories`; the log lists every device
with its MAC at startup. A controller's login is in the vault, never in config.json.

| Plugin Setting | Description |
|---|---|
| `controllers[]` | Consoles by address, for those discovery does not find (`address`, and optionally `name`, `verifyTls`, `mqttUrl`, `mqttTopic`, `mqttVerifyTls` as below); each is signed in to through Setup |
| `ringDelay` | Seconds between doorbell rings passed on to HomeKit (default `0`) |
| `debugAll` | `true` logs the plugin's debug lines at the info level, so they show without `homeswift -D` (default `false`) |
| the device settings below, and the Parts' `doorbell`, `dps`, `rel`, `ren`, `rex`, `sideDoor`, `sideDoorDps` | The plugin-wide defaults: a device's own setting, or its Parts, overrule them |

| A controller's setting | Description |
|---|---|
| `address` | Hostname or IP address, optionally with a port. Loopback, link-local and unspecified addresses are refused |
| `mqttUrl` | MQTT broker URL, e.g. `mqtt://user:password@1.2.3.4` (`mqtt`, `mqtts`, `tcp`, `ssl`) |
| `mqttTopic` | MQTT base topic (default `unifi/access`) |
| `mqttVerifyTls` | Validate an `mqtts://` broker's certificate (default `true`) |
| `verifyTls` | Validate the controller's certificate against trusted authorities (default `false`). Off, the controller's self-signed certificate is pinned the first time Homeswift connects and a different one is refused, before credentials are sent. Pins are in `unifi-access-tls-pins.json` in the plugin's directory (`~/.homeswift/plugins/UniFi Access-<name>/`); remove a controller's entry to trust a regenerated certificate |
| `delayDeviceRemoval` | Seconds before removing devices that left the controller (default 60); 0 removes them at once |
| `publishTelemetry` | Publish the controller's realtime events to MQTT (`telemetry`) |

| A hub's or reader's setting | Feature option | Default | Description |
|---|---|---|---|
| Excluded | `Disable.Device` | — | Left out of HomeKit |
| `syncName` | `Device.SyncName` | on | Synchronise the UniFi Access name with HomeKit, one way |
| `useLock` | `Hub.Door.UseLock` | off | UA Gate: a lock instead of a garage door opener |
| `useGarageOpener` | `Hub.Door.UseGarageOpener` | off | A garage door opener instead of a lock (visual only) |
| `gateDirectionDuration` | `Hub.GateDirectionDuration` | 90 | UA Gate: seconds of the full gate cycle, split in three phases |
| `lockDelayInterval` | `Hub.LockDelayInterval` | none | Minutes before the relay locks again after HomeKit unlocks it; 0 keeps it unlocked. Without it the relay locks five seconds after unlocking, and HomeKit cannot relock |
| `lockTrigger` | `Hub.Lock.Trigger` | off | A switch for the door lock relay |
| Part `Doorbell` | `Hub.Doorbell` | on | A doorbell for ring events |
| `doorbellTrigger` | `Hub.Doorbell.Trigger` | off | A switch reflecting (not triggering) rings |
| `doorbellSeparateAccessory` | `Hub.Doorbell.SeparateAccessory` | off | The doorbell and its trigger on an accessory of their own |
| `sensorsSeparateAccessory` | `Hub.Sensors.SeparateAccessory` | on | Each door sensor on an accessory of its own |
| Parts `DPS`, `REL`, `REN`, `REX` | `Hub.DPS`, `Hub.REL`, `Hub.REN`, `Hub.REX` | on | Contact sensors for the terminal inputs (when wired) |
| Parts `SideDoor`, `SideDoor.DPS` | `Hub.SideDoor`, `Hub.SideDoor.DPS` | on | UA Gate: the side door lock and its position sensor |
| `sideDoorLockTrigger` | `Hub.SideDoor.Lock.Trigger` | off | UA Gate: a switch for the side door lock |
| `sideDoorSeparateAccessory` | `Hub.SideDoor.SeparateAccessory` | on | UA Gate: the side door, its sensor and trigger on an accessory of its own |
| `accessMethodsSeparateAccessory` | `AccessMethod.SeparateAccessory` | off | The access method switches on an accessory of their own |
| `accessMethodFace`, `…Hand`, `…Mobile`, `…Nfc`, `…Pin`, `…Qr`, `…TouchPass` | `AccessMethod.Face`… | on | A switch per access method the reader supports |
| `logDoorbell`, `logDps`, `logRel`, `logRen`, `logRex`, `logLock` | `Log.Doorbell`… | on | Log these events |

### A Homebridge block

A block with `controllers[].username` and `password` and an `options` array of feature options (`Enable.<option>` or
`Disable.<option>`, optionally scoped with `.<MAC>`, and for an option with a value followed by it:
`Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5`) runs as it did. At the next settings change the bridge writes it in the
canonical shape: a running controller's entry moves into its Accessory Settings and its login into the vault; an option
scoped to a device becomes that device's setting (`Disable.Device.<MAC>` Excluded, a Part its `parts`); one without a
scope the Plugin Setting; one scoped to a controller each of its devices' setting (a `Controller.*` option the
controller's own). What no setting says (a global `Disable.Device`, an option of a device the controller does not have
now) stays in `options`, read after the settings.

### MQTT

With `mqttUrl`, events are published under `<mqttTopic>/<MAC>/`: `doorbell` (`true` ringing, `false` when the
ring ends), `lock` (`true` locked), `dps`, `rel`, `ren`, `rex` (`true` open), for a UA Gate `sidedoor/lock` and
`sidedoor/dps`, and with `publishTelemetry` the controller's events on
`<mqttTopic>/<controller MAC>/telemetry` (event names and ids only). Publishing `true` to `<topic>/get`
(`doorbell`, `dps`, `lock`, `sidedoor/lock`, `sidedoor/dps`) publishes the current state; `true` or `false` on
`lock/set` and `sidedoor/lock/set` locks or unlocks. Anyone who can publish to the broker can therefore open the
doors: use a broker that requires a login (and `mqtts://` off the local network).

## Setup

The **Add accessories** page lists each controller as a device, by its MAC: the running ones, those of `controllers`,
and the UniFi consoles discovery finds on the network. A console not set up asks for an **Account Login**, a local
account of the console that can use UniFi Access (Ubiquiti cloud accounts with two-factor authentication cannot log
in); the login is checked before it is kept, in the vault under the controller's MAC, and its address goes in its
Accessory Settings. The controller's hubs and readers need nothing more. A `Disable.Device.<MAC>` in `options` shows as
left out by the plugin's own settings.

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin: each controller the plugin runs, whether it
answers on port 443, and its hubs and readers with their state, each with a **Settings** button for its Accessory
Settings; **Settings for every device** opens the plugin's Settings, and a card leads to Add accessories for another
controller. The page writes no settings. With the Assistant on, **Explain** sits next to a controller that does not
answer.

## The Assistant

With the Assistant on (the web UI's chat, MCP clients), the plugin's page routes are tools of its own:
`list_controllers` (the controllers, their hubs and readers, and whether each door is locked, open or closed,
and a reader's access methods), `discover` (UniFi consoles on the network) and `check_controller` (whether an address
answers). None of them unlocks anything. Settings are read and written with `get_settings` and `update_settings`, a
controller set up with `start_setup`.

## What differs from Homebridge

- Feature options are settings (Plugin Settings and each device's Accessory Settings), edited on the Settings pages;
  there is no controller scope between the two, so the bridge writes a controller's options as each of its devices'.
- A controller's login is kept in the vault, through Setup, not in config.json.
- Removing a controller from the block leaves its accessories in HomeKit until it is added again, as in
  Homebridge; which controller owns an accessory is kept in `accessory-owners.json` in the plugin's directory.
- A UA Gate's garage door starts with its target matching the gate's position instead of HAP's default.
- A UA Gate is driven through its doors' unlock endpoint, which toggles the motor. Homebridge sent it for a
  close, lock or off command too, so closing a closed gate (or locking a locked side door) from a Lock Trigger
  switch, MQTT or the Home app opened it. Such a command now does nothing when the gate is already closed (or
  closing) with its relay locked, or the side door locked.
- Trust on first use (`verifyTls` off): Homebridge pinned the certificate during the TLS handshake; the port
  pins it from the first response (the console's home page, which carries no credentials). The login waits
  until a certificate is pinned, so when that first request fails the password is not sent over an unchecked
  connection; the next attempt tries again.
- Not ported: the `homebridge-ai-core` Assistant routes (the runtime provides the Assistant).
- `debugAll` is read from the block; the Homebridge plugin always set it to `false`.
- The events WebSocket and MQTT run on `HomeswiftNetwork`'s `WebSocket` and `MQTTClient`. MQTT over WebSockets
  (`ws://`, `wss://`) stays refused, as in Homebridge.
