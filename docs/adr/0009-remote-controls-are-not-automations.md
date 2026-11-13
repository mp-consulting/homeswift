# A Remote's Controls are not Automations

A Remote's Buttons and Wheels need to dim lights while held and step them as a Wheel turns, and do it the moment a
press comes. We made what a Remote does its own concept, its Controls, run by the bridge for any plugin's Remote,
rather than Automations with a press Trigger: an Automation is a Trigger, Conditions and Steps run in order, and a
press that brightens until it is let go, or a Wheel's notches coming twice a second, are not Steps. The press Trigger stays
for what needs a Condition, and the Remotes page lists the Automations a Button starts beside its Controls.

## Considered Options

- **Controls as Automations with new Steps** ("dim while held", "step per notch"): one place for everything a press
  does, with history and Conditions, but Steps that run until another event ends them, a run recorded per notch, and
  a cooldown and change detection the press would have to bypass.
- **Each plugin's own settings** (as Matter Devices first had): only the plugins that wrote it could dim, each its own
  way, with its own words.

## Consequences

- A plugin that knows more than HomeKit's three presses declares its Remote and reports its moments (press, double
  press, hold start and end, a Wheel turned by so much); it still sends HomeKit's presses itself, its device's own
  mapping (a Tap dial's turn, a wheel's count). For the other plugins the bridge reads the presses HomeKit gets, a long
  press holding for two seconds.
- A Control never drives a security control: a light, a shutter or a Power Switch whose characteristic its plugin marks
  so (a door's unlock shown as a switch) is refused when Controls are saved and skipped when they run. Superseded by
  [ADR 0012](0012-a-remote-drives-what-it-is-given.md): a remote drives what it is given, locks, garage doors and alarms
  included.
- A press with a Control still reaches Apple Home; Not in Home keeps the whole Remote out of it.
