# A remote drives what it is given, locks, garage doors and alarms included

Homeswift's rule is that a person confirms every change to a lock, a garage door or an alarm: the MCP server's
`set_security_accessory` asks, an Automation never sets one, a notification's button never does. A remote's Controls
followed it (ADR 0009). But a remote is a person pressing a button, as a garage door's own remote is, and a person
wiring one wants it to open the garage. We let a Control drive whatever it is given: a garage door opens and closes, a
lock unlocks and locks, an alarm arms Away and disarms, a door or a window moves as a shutter does, and a switch its
plugin marks a security control (a door strike) turns on and off. "On" is what Apple Home lights a tile for: open,
unlocked, armed.

## Considered Options

- **Keep them out**: the house stays as safe as before, but a remote cannot do what the person bought it for, and Apple
  Home itself lets a button press open the garage.
- **Garage doors only, with a box to tick and a notification on each opening**: safer by a step, but more to set and to
  explain for a choice the person already made by attaching the door to the remote.

## Consequences

- Anyone holding the remote can open what is attached to it; the sheet says so where targets are chosen.
- The Assistant still never changes a lock, a garage door or an alarm on its own: `set_remote_controls` and
  `update_settings` ask the user before Controls that add one as a target or a Power Switch are saved, and before they
  add one that is not on the bridge now, which could become one. What the Remote names already is not asked again.
  `update_settings` also asks before it joins the Functions of a device a Remote names (Separate Functions off) when the
  whole device holds one: a Control confirmed for one Function would then drive all of it. The web UI, signed in as an
  administrator, saves them as any other Control.
- Automations keep the rule: a press Trigger starts an Automation, whose Steps still never set a lock, a garage door or an
  alarm. Only a Control does.
