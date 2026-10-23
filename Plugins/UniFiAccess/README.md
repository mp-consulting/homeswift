# UniFi Access

Ubiquiti's [UniFi Access](https://ui.com/door-access) door access system in HomeKit: every hub and reader of
one or more controllers, found automatically and followed in real time through the controller's events.

A port of [`@mp-consulting/homebridge-unifi-access`](https://github.com/mp-consulting/homebridge-unifi-access).
The platform name (`UniFi Access`), the block and the feature options are the same, so a Homebridge
configuration works unchanged, `options` array included.

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

Names follow the controller (`Device.SyncName`), including a UA Gate's door names. With
`Hub.Sensors.SeparateAccessory`, `Hub.Doorbell.SeparateAccessory` and `AccessMethod.SeparateAccessory` the
sensors, the doorbell and the access method switches get tiles of their own (accessory ids
`UniFi Access:<MAC>.<group>`); turning the option off brings them back to the hub.

## Configuration

```json
{
  "platform": "UniFi Access",
  "name": "UniFi Access",
  "controllers": [
    { "address": "1.2.3.4", "username": "homeswift", "password": "your-password-here" }
  ]
}
```

Use a local user of the UniFi console with an Access role; Ubiquiti cloud accounts with two-factor
authentication cannot log in.

| Setting | Description |
|---|---|
| `controllers[].address` | Hostname or IP address of the controller, optionally with a port. Loopback, link-local and unspecified addresses are refused |
| `controllers[].username`, `controllers[].password` | The local user |
| `controllers[].name` | Name for the log (default: the controller's own) |
| `controllers[].mqttUrl` | MQTT broker URL, e.g. `mqtt://user:password@1.2.3.4` (`mqtt`, `mqtts`, `tcp`, `ssl`) |
| `controllers[].mqttTopic` | MQTT base topic (default `unifi/access`) |
| `controllers[].mqttVerifyTls` | Validate an `mqtts://` broker's certificate (default `true`) |
| `controllers[].verifyTls` | Validate the controller's certificate against trusted authorities (default `false`). Off, the controller's self-signed certificate is pinned the first time Homeswift connects and a different one is refused, before credentials are sent. Pins are in `unifi-access-tls-pins.json` in the plugin's directory (`~/.homeswift/plugins/UniFi Access-<name>/`); remove a controller's entry to trust a regenerated certificate |
| `options` | [Feature options](#feature-options) |
| `ringDelay` | Seconds between doorbell rings passed on to HomeKit (default `0`) |

### Feature options

`Enable.<option>` or `Disable.<option>`, optionally scoped to a controller or a device with `.<MAC>` (no
separators; a door of a UA Hub Enterprise is `<MAC>-PORT1`), and for options with a value followed by it:
`Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5`. A device entry beats a controller entry beats a global one. The
log lists every device with its MAC at startup.

| Option | Default | Description |
|---|---|---|
| `Device` | on | Make this device (or, scoped to a controller, all its devices) available in HomeKit |
| `Device.SyncName` | on | Synchronise the UniFi Access name with HomeKit, one way |
| `Controller.DelayDeviceRemoval.<seconds>` | 60 | Delay before removing devices that left the controller; 0 removes them at once |
| `Controller.Publish.Telemetry` | off | Publish the controller's realtime events to MQTT (`telemetry`) |
| `Hub.Door.UseLock` | off | UA Gate: a lock instead of a garage door opener |
| `Hub.Door.UseGarageOpener` | off | A garage door opener instead of a lock (visual only) |
| `Hub.GateDirectionDuration.<seconds>` | 90 | UA Gate: the full gate cycle, split in three phases |
| `Hub.LockDelayInterval.<minutes>` | off | Minutes before the relay locks again after HomeKit unlocks it; 0 keeps it unlocked. Without it the relay locks five seconds after unlocking, and HomeKit cannot relock |
| `Hub.Lock.Trigger` | off | A switch for the door lock relay |
| `Hub.Doorbell` | on | A doorbell for ring events |
| `Hub.Doorbell.Trigger` | off | A switch reflecting (not triggering) rings |
| `Hub.Doorbell.SeparateAccessory` | off | The doorbell and its trigger on an accessory of their own |
| `Hub.Sensors.SeparateAccessory` | off | Each door sensor on an accessory of its own |
| `Hub.DPS`, `Hub.REL`, `Hub.REN`, `Hub.REX` | on | Contact sensors for the terminal inputs (when wired) |
| `Hub.SideDoor`, `Hub.SideDoor.DPS` | on | UA Gate: the side door lock and its position sensor |
| `Hub.SideDoor.Lock.Trigger` | off | UA Gate: a switch for the side door lock |
| `AccessMethod.SeparateAccessory` | off | The access method switches on an accessory of their own |
| `AccessMethod.Face`, `.Hand`, `.Mobile`, `.NFC`, `.PIN`, `.QR`, `.TouchPass` | on | A switch per access method the reader supports |
| `Log.Doorbell`, `Log.DPS`, `Log.REL`, `Log.REN`, `Log.REX`, `Log.Lock` | on | Log these events |

### MQTT

With `mqttUrl`, events are published under `<mqttTopic>/<MAC>/`: `doorbell` (`true` ringing, `false` when the
ring ends), `lock` (`true` locked), `dps`, `rel`, `ren`, `rex` (`true` open), for a UA Gate `sidedoor/lock` and
`sidedoor/dps`, and with `Controller.Publish.Telemetry` the controller's events on
`<mqttTopic>/<controller MAC>/telemetry` (event names and ids only). Publishing `true` to `<topic>/get`
(`doorbell`, `dps`, `lock`, `sidedoor/lock`, `sidedoor/dps`) publishes the current state; `true` or `false` on
`lock/set` and `sidedoor/lock/set` locks or unlocks.

## The web page

With the web UI on, the Plugins page has an **Open** button for this plugin, with the screens of the
Homebridge plugin's settings page:

- **Controllers**: each configured controller, whether it answers on port 443 and what the running plugin
  sees of it, with **Feature options**, **Edit** and **Remove**.
- **Add a controller**: discovery of UniFi consoles on the network (Ubiquiti's discovery protocol, broadcast on
  the local subnets and sent to the /24 subnets around them), or an address typed in; then the address,
  username and password, and the advanced settings (name, TLS verification, MQTT). Saving logs in first and
  shows the controller's error when it fails.
- **Feature options**: the options by category for the whole block, the controller, or one hub or reader
  (only the options that apply to it), with the scope cascade, where each value comes from, search, a
  modified-only filter, values for the options that take one, and reset. Changes are saved with **Save**.

With the Assistant on, **Explain** sits next to a controller that does not answer, a failed connection, an
empty discovery and a disconnected device; addresses, credentials, IP and MAC addresses are left out.

## The Assistant

With the Assistant on (the web UI's chat, MCP clients), the plugin's page routes are tools of its own:
`list_controllers` (the controllers, their hubs and readers, and whether each door is locked, open or closed,
and a reader's access methods), `list_options` (the feature options), `discover` (UniFi consoles on the network)
and `check_controller` (whether an address answers). None of them unlocks anything, and the page's sign-in to a
controller, which takes its password, is not one of them.

## What differs from Homebridge

- The controller scope of the feature options page is the controller's MAC address, which the plugin
  matches; the Homebridge page wrote the controller's address, which the plugin never matched.
- The page's feature option changes are kept until **Save** (Homebridge kept them until its own Save button).
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
- Not ported: the `homebridge-ai-core` Assistant routes (the runtime provides the Assistant), the Homebridge
  UI's Support links beyond the documentation, and `debugAll`.
- The events WebSocket and MQTT run on `HomeswiftNetwork`'s `WebSocket` and `MQTTClient`. MQTT over WebSockets
  (`ws://`, `wss://`) stays refused, as in Homebridge.
