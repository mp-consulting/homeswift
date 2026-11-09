# The runtime runs every plugin's energy history import; a plugin only reads its past

A device's or a cloud's past goes onto Meters by the hour (`PluginMeter.importHours`, docs/adr/0004-meters-and-consumption-history.md),
but each plugin that imported one wrote the rest itself: EcoFlow kept `energy-history.json` (where it got to, its version,
its STREAM, a checkpoint), read again every six hours and ten minutes after a failure; Shelly kept `shelly-ng-history.json`
and `shelly-cloud-history.json` with spans and resume points of its own; Daikin Cloud kept the days it had in detail. Each
said its progress on the Status page its own way, and each had its own answer to a new way of reading (drop the old hours,
read again from the start) and to a history that moves to another device's Meters.

Now the runtime runs the import (`EnergyHistoryImport`, made by `context.energyHistory(name, version:)`). A plugin gives one
function that reads its past for a pass (`EnergyHistoryPass`): from `since` (nil for the history's start), handing each
Meter's hours to `add`, saying how far it is with `progress`, and, for a first pass that may stop part way, where it goes
on from with `checkpoint`. The runtime keeps the state (`energy-history-<name>.json` in the plugin's storage: version,
identity, first hour, last whole pass, checkpoint, the Meters it filled, and the plugin's own notes), starts each pass
`overlap` before the last one ended (a cloud fills hours in late), passes again every `interval` and `retry` after a
failure, and says on the Status page that it runs, is done (from and through) or failed (the error). A new `version`
drops the hours it put on its Meters and reads from the start; `identify` with another device (a system now read
through another unit) does the same, at once. A plugin whose hours come with its own poll calls `pass` itself.

## Considered Options

- **Each plugin keeping its own loop and files.** Rejected: three copies already disagreed (how a failure shows,
  whether a restart resumes, whether a new version drops the old hours), and every new history (LG ThinQ's, a Tapo
  plug's) would add one more.
- **The runtime fetching the history itself, the plugin giving only a request per range.** Rejected: the readings
  differ too much: EcoFlow's months whose charts may be refused, Shelly's device pages and newest-first cloud days
  that stop where the cloud's history does, Daikin's two weeks with each device list. The plugin keeps its
  traversal; the runtime keeps everything around it.

## Consequences

- A plugin moving onto it gives `migrate`, which turns its former file into the runtime's state once, so nothing is
  read again; EcoFlow, Shelly and Daikin Cloud did.
- What a plugin must remember beyond where the import stands (EcoFlow's charts that refuse, Shelly's spans by meter,
  Daikin's days in detail) is a note in the same state (`EnergyHistoryPass.note`), dropped with it on a new version.
- A pass that finds nothing ever (an account without the device the history comes from) says nothing on the Status
  page and stays a first pass.
- Hours the bridge measured keep their own figures, as before: the runtime only decides when to read and where from.
