# APsystems ECU

Reads APsystems solar microinverters from their ECU, the gateway that talks to them over Zigbee, on the local network:
the system's production in HomeKit and in the Status page's Energy section, an ECU-C's current clamps (CT) for the grid
and the home, and each inverter's power and temperature. Its page shows every ECU and inverter as last read, channel by
channel. It is read only: nothing is ever written to the ECU.

**Status: experimental.** Nobody has run it against a real ECU yet: it is tested against a fake ECU that answers the
frames of the [functional spec](../../docs/clean-room/APsystemsECU.md) (see [Tests](#tests)), which were checked
against frames users posted from real ECU-C and ECU-R units. Please report what works on yours.

**Maintainer:** Mickael Palma.

## ECUs

| ECU id starts with | Model | |
|---|---|---|
| `215` | ECU-C | Production, inverters, and the CT clamps over HTTP (`meter`) |
| `2160` | ECU-R | Production, inverters |
| `2162` | ECU-R-Pro | Production, inverters |
| `2163` | ECU-B | Production, inverters |

Inverters: YC500, YC600, YC1000, DS3, QS1 and QT2, by the type code of their record (2-channel, 4-channel, QS1, and
three-phase QT2 and YC1000). ECU-3 units and ECU-C units built into APsystems storage systems are not covered, nor the
EZ1 microinverter's own API.

## In HomeKit

HomeKit has no service for power, so the production is shown as other plugins and Homebridge do:

| Accessory | Device Id | HomeKit |
|---|---|---|
| The ECU (`APsystemsECU:<ECU id>`), named after its model and id (`ECU-C 215000…`) | its 12-digit ECU id | A Light Sensor, **Solar power**: its lux is the system's power in W (0.0001 at night, HomeKit's lowest); Eve's Consumption (W) and Total Consumption (the lifetime energy in kWh) on the same service; Status Active off while the values are the last good ones, Status Fault once `connectRetries` polls in a row failed |
| Each inverter (`APsystemsECU:<UID>`), `Inverter <UID>` | its 12-digit UID | A Light Sensor, **Power** (its channels added up, in W), Status Active while it is online; a **Temperature** sensor, its last online value kept (an offline inverter's record reads −100 °C, which is never shown) |

Accessory Information: Manufacturer APsystems, the model (`ECU-C`, `DS3 series`), the id as the serial number, and the
first dotted number of the ECU's firmware as its Firmware Revision (`ECU-C-Z_C1.2.24D` gives 1.2.24; the page shows the
whole string). A registered inverter the ECU has no data for gets no accessory until it reports. An inverter that leaves
the ECU's answer keeps its accessory (the ECU sometimes drops records), not active, until you remove it.

**Energy.** Each poll records the production as `.solar` (0 W at night too, so the day's total stays honest), and an
ECU-C's meter: the grid clamps added up as `.grid` (positive while importing) and production + grid as `.home`. A
poll that failed records nothing. Each inverter's power, channel powers, voltages, frequency, temperature and signal
(percent) are kept in the Status page's history (`<UID>:power1`…), not in HomeKit.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "APsystemsECU",
      "name": "APsystems",
      "ecus": [{ "host": "192.168.1.60" }]
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `ecus[].host` | | The ECU's IP address or host name, for an ECU not added by address. Give it a fixed address on your router, where it often shows as an Espressif device |
| `ecus[].port` | 8899 | The local protocol's port |
| `ecus[].name` | | The ECU's name, moved into its Accessory Settings once its id is known |
| `pollInterval` | 300 | Seconds between polls, 60 to 3600 |
| `connectRetries` | 2 | Connection attempts per request (2 s apart), 1 to 10 |
| `inverters` | true | An accessory per inverter; off, only the ECU's |
| `meter` | true | An ECU-C's CT clamps over HTTP |

There is no Homebridge plugin for the ECU, so the platform name and the options are this plugin's own.

**Setup.** There is nothing to sign in to. The ECU announces nothing on the network, so it is added by address: add the
plugin from Add accessories, then **Add by address…** on its instance (`start_setup` with `addByAddress: true` through
MCP). It asks for the ECU's address and port (8899 when left empty), sends the system query there, refuses an address
where no ECU answers ("No ECU answered at 192.0.2.60:8899"), and keeps the address in the ECU's Accessory Settings
(`host`, and `port` when it is not 8899) under the ECU id it answered. Add accessories then lists the ECU by that id, and
its inverters; each can be Excluded there. The `ecus` list keeps working beside it (an address of it that does not
answer is listed as not responding); an ECU in both is read once, at the address Add by address gave.

## How it talks to the ECU

The ECU's binary protocol on TCP port 8899, no TLS and no authentication: each frame is `APS`, a command group, a
four-digit length, a command, the payload and `END`. A poll is three requests, each on a connection of its own (every
ECU model wants the socket closed between them): system info (ECU id, power, today's and lifetime energy, the
inverters online, firmware), real-time data (each inverter's record) and signal levels. The reader takes the bytes the
header announces, within 5 seconds and 64 KiB, rather than one read of 1024 bytes, so a large system or a frame TCP
splits still reads; a frame whose length, start or end does not check, or that answers another command, fails the
poll. A record of a type the plugin does not know stops the reading of that frame (the records before it are kept,
logged once). On an ECU-C the meter is `GET /index.php/meter/old_meter_power_graph`; recent ECU-C firmware (C1.2.24B)
removed or broke it, so a meter that does not answer leaves the grid and home unknown and never fails the poll.

- **Polling:** every `pollInterval` (300 s), one ECU at a time; every 15 minutes while no inverter is online (the ECU
  answers at night with zeros); after three failures in a row, twice the interval (at most 15 minutes, or the interval
  when it is longer), back to normal at the first answer. An instance without ECUs starts nothing.
- **Glitches the firmware is known for** keep the previous value: an inverter count of 0, a lifetime of 0 or one that
  drops, and a today's energy of 0 or one that drops while inverters are online on the same day (the ECU-C's evening
  maintenance). Today's energy drops only at the ECU's midnight reset: a new date in the real-time data, or no inverter
  online.
- **Failures** keep the last values in HomeKit with Status Active off, and record nothing. The first failure of a
  series is logged, then every tenth, and once more after an hour, with a hint to power-cycle the ECU; its recovery is
  logged too. The real-time data and the signal levels failing alone leave the production current and the inverters
  not active.
- **The log** shows the ECU id with its last six digits hidden, and at debug level every answer in hex, the ECU id and
  the MAC addresses masked.

## Not done

- **No writes:** turning inverters on or off, their maximum power, an ECU-C's zero export and the sources' reboot trick
  (rewriting the ECU's Wi-Fi settings, which needs the home's Wi-Fi password) are left out; the local pages they used
  are gone on recent ECU-C firmware.
- The day's power curve and the week, month and year energy queries, which could fill the Status page's history
  before the bridge ran (`importEnergy`).
- SunSpec over Modbus TCP, which ECU-R-Pro and ECU-C units also answer.

## Gaps

What the spec leaves open, and the choice made here:

- **Type code `05`** is 4-channel in one source and 2-channel in another, and no frame of it was seen: read as 4-channel
  (27 bytes); a record that runs past the frame's end stops the reading, logged.
- **System layout `02`** (no frame seen): read at the offsets the spec gives, without a time zone; any other model code
  is read as layout `01`, which every ECU-C and ECU-R frame seen uses.
- **The signal level's scale** is undocumented: shown as a percentage of 255, truncated.
- **The grid clamps' sign** is inferred (consumed = production + grid): positive is taken as importing. Check it against
  a real export.
- **A failed real-time or signal request** with a good system answer: the spec fails the whole poll on any error; here the
  system answer stands (the production stays current) and only the inverters go not active, as the spec asks the plugin
  to keep working on whatever subset answers.
- **The inverters' StatusActive while the ECU is down**: off for every inverter of that ECU.
- **Concurrent clients** (the EMA app beside the bridge): unknown whether the ECU minds; the plugin asks one ECU at a
  time, one request at a time.

To confirm on a real ECU: the grid sign, the signal scale, what an ECU-C on firmware after C1.2.24D still answers.

## Tests

`swift test --filter APsystemsECUTests` runs the plugin against a fake ECU, with no device or network: every frame of
the spec (system info of an ECU-C by day and by night and of an ECU-R, real-time data of DS3, YC600, QS1, QT2 and
YC1000 inverters, a night, no records, signal levels) decoded field by field; the negative cases (a missing line
feed, a split read, a bad signature, the answer to another command, an unknown type code, a count past the frame, a bad
status, a truncated system answer); the reader waiting for the announced length across reads, past an `END` inside the
payload, and refusing too much; the TCP client's timeout, retries and close; the meter's JSON. Through a `PluginHost`:
the accessories and their values, the Energy section's readings, the meter failing without failing the poll and asked
only of an ECU-C, three requests per poll and the interval between polls counted, an unreachable ECU keeping its values
not active and recovering, the night (no −100 °C), no records, the glitch filters, `inverters: false`, an Excluded ECU
left alone, Setup's discovery, the page's routes and the settings' canonical shape.

## Clean-room implementation

There is no Homebridge plugin for the ECU. The protocol and its behaviour come from the Home Assistant integrations
[homeassistant-apsystems_ecu_reader](https://github.com/HAEdwin/homeassistant-apsystems_ecu_reader) by HAEdwin (Apache
License 2.0) and [homeassistant-apsystems_ecur](https://github.com/ksheumaker/homeassistant-apsystems_ecur) by
ksheumaker (Apache License 2.0), the ioBroker adapter [ioBroker.apsystems-ecu](https://github.com/npeter/ioBroker.apsystems-ecu)
by npeter (MIT) and its protocol table, and frames users posted in those projects' issues. This plugin was written from
the functional spec in [docs/clean-room/APsystemsECU.md](../../docs/clean-room/APsystemsECU.md), without reading or
copying their code.
