# Scenes and Automations are separate

A Scene used to carry its own triggers and conditions, so "when motion, turn the hall on, wait five minutes, turn it
off" could not be written: a Scene is a set of values, not a sequence. We split it the way Apple Home does. A Scene is
only a set of values. An Automation is a Trigger, Conditions and Steps run in order (apply a Scene, set a value, wait,
wait until, notify, call a plugin's action). The triggers and conditions in `scenes.json` move into Automations, one
per Scene that had them, whose single Step applies that Scene.

## Considered Options

- **Steps inside a Scene:** one object would be both what the home looks like and what the bridge does over time, and
  a Scene recalled from the Home app or a hub would carry waits and notifications nobody expects from a Scene.

## Consequences

- A Scene's switch in the Home app still applies it; an Automation's switch turns it on or off.
- Locks, garage doors and alarms keep the rule that a person confirms them: an Automation leaves them out and says so
  in its last run, as Scenes run by a trigger did.
