# TP-Link Tapo

Puts TP-Link Tapo plugs and bulbs in HomeKit, reached on the local network, signed in with the Tapo account's email and
password. Each device is listed by its address; the plugin asks it for its state every few seconds and sends HomeKit's
changes to it.

**Status: experimental.** Nobody has run it against a real Tapo device yet: it is tested against a fake device that
speaks the protocols as the [functional spec](../../docs/clean-room/Tapo.md) describes them (see [Tests](#tests)).
Please report what works on yours.

**Maintainer:** Mickael Palma.

## In HomeKit

| `type` | Devices | HomeKit |
|---|---|---|
| `Plug` (the default, and any value it does not know) | P100, P105 | Outlet: On; Outlet In Use always on (the plug cannot tell) |
| `PowerPlug` | P110 | Outlet: On, Outlet In Use while it draws power; Eve's Current Consumption (W) and Total Consumption (kWh today); Eve history |
| `Light` | L510E | Lightbulb: On, Brightness |
| `WhiteLight` | L520E | Lightbulb: On, Brightness, Color Temperature (154 to 400 mireds), Adaptive Lighting |
| `Colorlight` | L530E | Lightbulb: On, Brightness, Color Temperature (140 to 400 mireds), Hue, Saturation, Adaptive Lighting; Eve's consumption characteristics and history |

`type` is matched in any case. Accessory Information has Manufacturer TP-Link, the model of the kind (`Tapo P110`), the
device's hardware id as the serial number and the version of its firmware.

- **Total Consumption is today's**: the devices count from midnight, so it starts again every day.
- **An L530's power is an average**: the bulb reports the watt-hours it used today and how long it has been on, so
  Current Consumption is the one divided by the other while it is on, and 0 while off. It is read every ten minutes.
- **A P110's power** is read with each poll and goes to the Status page's **Energy** section as a home use, under the
  plug's name, and to its graphs (`plugin:TapoP100:<Device Id>:power`). With a meter that already measures the whole home there, the
  plug's watts count a second time.
- **Brightness and colours of a bulb that is off** are not sent, as the Homebridge plugin does: the Home app's write is
  acknowledged and the bulb keeps its own. Turning it on and setting a brightness in one scene works: writes made within
  `waitTimeUpdate` go out together, on or off first. A Brightness of 0 is sent as 1, the lowest the bulbs take.
- **Adaptive Lighting** writes the white through the same path, so it waits while the bulb is off. A white or a colour
  set in the Tapo app turns it off, as one set in the Home app does.
- A device that does not answer shows **No Response**; the plugin asks it again after its `updateInterval`, then less and
  less often up to every five minutes, and as before once it answers.

### From Homebridge

The block is homebridge-tapo's, so it can be pasted unchanged, and the accessories keep their identity: the Device Id is
the device's `host` and `name` run together (`192.168.1.21Kitchen`, the host alone without a name), the seed the
Homebridge plugin made its accessory's UUID from. As there, changing a device's address or name in `devices` makes a new
accessory. A device no longer in `devices` leaves the bridge (the Homebridge plugin kept it until the cache was cleared).

**A `WhiteLight` device changes**: the Homebridge plugin meant it as a white lightbulb but compared the type in a way that
never matched, so an L520E was an Outlet there. Here it is a Lightbulb with Brightness and Color Temperature; HomeKit
sees a new service, so the automations and scenes that used it as an outlet need doing again.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "TapoP100",
      "name": "Tapo Smart Platform",
      "username": "me@example.com",
      "password": "…",
      "devices": [
        { "name": "Kitchen", "host": "192.168.1.21", "type": "Plug" },
        { "name": "Heater", "host": "192.168.1.22", "type": "PowerPlug", "updateInterval": 30 },
        { "name": "Sofa", "host": "192.168.1.23", "type": "Colorlight" }
      ]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `username` | | The Tapo account's email. Setup (Add accessories) can keep it in the vault instead |
| `password` | | The Tapo account's password: sealed in config.json, or a `vault:`, `env:` or `file:` reference (docs/plugins.md, "Secrets") |
| `waitTimeUpdate` | 100 | Milliseconds a change from HomeKit waits for the ones made with it (unused by the Homebridge plugin) |
| `devices[].name` | | The name in HomeKit, and part of the Device Id |
| `devices[].host` | | The device's IP address or host name; HTTP on port 80 |
| `devices[].type` | `Plug` | See [In HomeKit](#in-homekit) |
| `devices[].updateInterval` | 10 | Seconds between polls (0 is the default) |
| `devices[].timeout` | 2 | Seconds a securePassthrough request waits; KLAP waits 5 |

Numbers may be written as strings (`"10"`), as the Homebridge plugin's form wrote them. `pollingInterval`, `timeout` at
the top and `devices[].port` are read and unused, as there.

**Setup.** On Add accessories, the instance's account asks for the Tapo email and password, checks them on the first
device of `devices` when it answers, and keeps them in the vault (taking `username` and `password` out of the block).
Devices are added to `devices` by address: they announce nothing the plugin listens for. Each needs **Third-Party
Compatibility** turned on in the Tapo app on current firmware.

## How it talks to the devices

Plain HTTP to the device, one request at a time per device, with:

- **KLAP**, current firmware: two handshakes prove both sides know the account (SHA-256 over random seeds and a hash of
  the email and password), then each request is AES-128-CBC with a key, an IV prefix and a sequence number derived from
  them, signed with SHA-256. The session cookie's `TIMEOUT` is honoured (a new handshake a minute before it ends), and an
  HTTP 403 or 401, a response that does not decrypt, or a session timeout (9999) starts one new handshake and one retry.
  The response's signature is not checked.
- **securePassthrough**, older firmware, only when the device has no KLAP endpoint: an RSA-1024 key exchange gives an
  AES key and IV, `login_device` a token, and each request is wrapped in a `securePassthrough` envelope.

Every answer's `error_code` is checked, writes included, and read leniently (`-0301` is -301). The account's email,
password, the derived keys and the session cookie are never logged.

## Not done

- Discovery: the devices have to be listed by address.
- L900 light strips have no type of their own; as `Colorlight` they may work (untested), without their segments and
  effects.
- KLAP's newer variant used by some cameras and hubs, and accounts whose devices expect other credentials in the
  handshake, are not supported.
- Eve's Reset Total is not offered (the Homebridge plugin defines it but adds it nowhere), and the total is today's.

## Tests

`swift test --filter TapoTests` runs the plugin against a fake device, with no device, account or network: the spec's
KLAP and login vectors byte for byte (hashes, session keys, the first request's ciphertext and signature), the identity
seed against the Homebridge plugin's UUIDs, an RSA handshake, both protocols end to end (403 and a cookie timeout giving
one new handshake, a refused set, malformed error codes), each kind's services, writes grouped and dropped while off,
No Response and recovery, the P110 and L530 energy, Adaptive Lighting turned off by a colour set elsewhere, and Setup.

## Clean-room implementation

Compatible with the configuration of [homebridge-tapo](https://github.com/apatsufas/homebridge-tapo-p100) by apatsufas
(Apache License 2.0). Written from the functional spec in [docs/clean-room/Tapo.md](../../docs/clean-room/Tapo.md),
without reading or copying its code.
