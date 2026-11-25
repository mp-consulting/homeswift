# A climate accessory's modes and setpoints are mapped once, by the bridge

Twenty plugins made thermostats and heater-coolers, each mapping HomeKit's modes and thresholds its own way: an air
conditioner in auto showed as Auto in one plugin and as Heat or Cool in another, dry showed as Auto, Cool or nothing, a
setpoint written while the unit was off was sent, held, refused or dropped, and a single-setpoint unit's two thresholds
each meant something different. Apple Home, the web UI and the Matter bridge all read the same two services, so the same
room looked different by brand. We made `ClimateController` (`HomeswiftPlugin`) the one place that maps them: a plugin
says what its device can do (its Climate Modes and its Setpoint Kind), turns a `ClimateCommand` into the device's request
and the device's state into a `ClimateReport`; the controller owns every climate characteristic.

## The rules it keeps

1. Target state is the device's Climate Mode: a unit in auto stays Auto in Apple Home, never Heat or Cool.
2. Current state is what the unit does (its Action) when it says, else what its mode, setpoints and room make likely;
   only the current state is guessed, never the target.
3. An Other Mode (dry, fan only, eco) leaves the target as it was and the current state idle: a plugin that wants to
   offer it adds a switch or a fan of its own.
4. A Heater Cooler's power is Active alone: a mode or setpoint write never turns the unit on (iOS sends Active=1 with
   every mode change, and a mode that also switched the unit on would race a "turn off" scene). A Thermostat's power
   is its Off mode, so choosing Heat turns it on.
5. A setpoint written while the unit is off is sent, or held for the next turn-on when the device refuses it then
   (`ClimateCapabilities.whileOff`); it is never dropped.
6. Both thresholds always say something true: a Single setpoint in auto shows its Auto Band around the target, the one
   remembered from the last range written when its middle is still the target.
7. The service type an accessory has never changes, a Thermostat staying a Thermostat: another type changes its iids,
   and Apple Home loses its scenes and automations.

## Considered Options

- **Rules in CONTRIBUTING.md and a shared test suite each plugin runs**: no new code, but twenty mappings to keep in
  step, and the tests would check the plugins' translations through HomeKit's numbers rather than the device's.
- **The bridge keeps a single-setpoint unit inside the range itself** (switching it between heat and cool): a true
  Auto for every unit, but it fights the unit's own regulation and wears its compressor.
- **Hiding auto from single-setpoint units**: honest, but takes away a mode the unit has.

## Consequences

- A plugin's climate code is its device's vocabulary only: its modes, its temperatures, its requests. HomeKit's state
  numbers, threshold props and coalescing are the controller's, tested once in `ClimateControllerTests`.
- Writes of one change (Active, mode and both thresholds arrive together) reach the plugin as one `ClimateCommand`
  after 30 ms; a failed command puts the characteristics back as the device last reported them and fails the writes.
- Plugins that pass characteristics through to the person's own topics or URLs without knowing a device (MQTT Thing,
  HTTP Webhooks, Dummy) keep their own mapping: they have no device whose modes the controller could know. Nor are
  an appliance's temperatures (a fridge, an oven) or a sensor shown as a read-only thermostat climate devices.
