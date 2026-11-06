# The bridge records each Meter's Consumption itself, from counters, in one store; the Eve history is a view of it

Energy history was in three places: the Home Energy's roles (`EnergyTag`, hard-coded by each plugin, such as a
Shelly `em1:0` always being the grid), `EnergyArchive`'s hours of the Home Energy, and the Eve history, which some
plugins keep per accessory (4096 entries, about four weeks) and others, Shelly among them, never do. A plug's
Consumption over months was kept nowhere. Now every Meter has a long-term history kept by the bridge, whatever its
plugin: the bridge watches any accessory's Total Consumption (and Current Consumption) characteristics, and a plugin
declares a Meter itself only for readings with no such characteristic (an inverter's solar). A Meter's energy is the
difference between readings of its counter, Consumption and Returned apart, so a bridge restart loses nothing and a
counter that goes backwards is a reset. Power is integrated per minute only when there is no counter. The history is
hourly, kept for years, and keyed by Accessory Id and Meter. Only Forget removes it. A plugin may backfill hours from
the device or its cloud (`importEnergy` for one Device Id), but an hour the bridge recorded keeps its own figure.
The Eve app's energy history is a view beside it: an accessory that measures power and has no Eve history of its plugin's gets one from the runtime, fed by the same power readings at the ten-minute steps Eve graphs (an hourly store is too coarse for it); a plugin that keeps its own, as Tapo does, keeps it, so its users' graphs carry on. A Meter's Energy Role (grid, solar, home, battery or none)
is a Core Accessory Setting: its plugin suggests one and a person can change it, because the same clamp can be the
grid in one home and a heat pump in the next. A Tariff is a dated Bridge Setting, so changing the price starts a new
Tariff and never reprices the past.

## Considered Options

- **The Eve history as the standard.** Rejected: it is opt-in per plugin, capped at a few weeks, and shaped for the
  Eve app rather than for days, months and years.
- **Integrating power only, as `EnergyArchive` does today.** Rejected as the main path: every minute the bridge is
  down is lost, while a device's own counter keeps counting.
- **Each plugin recording its own Meters.** Rejected: every plugin would repeat the same code, and those that forget
  would leave gaps, as Shelly's plugs do.

## Consequences

- `recordValue(…, energy:)` and `EnergyTag` become a way of declaring a Meter and are deprecated. Battery level stays
  a plain recorded reading.
- Unmetered can be shown only when some Meter has the home or grid Energy Role. A wrong Energy Role usually shows up
  as Meters adding up to more than the home's use.
- A Meter's cost is its Consumption at each hour's grid price, whatever source supplied it. What solar saved shows
  only in the home's cost. The fixed charge of a supply contract is not counted.
- Gas and water are Meters too, of their own kind, declared by plugins only (HAP has no characteristics for them). They
  stay in m³ (the archive keeps litres where it keeps watt-hours), never turn into kWh, take no Energy Role and never
  count in the Home Energy. A Tariff has a kind as well: gas and water are priced per m³ by Tariffs of their own,
  dated apart from electricity's.
