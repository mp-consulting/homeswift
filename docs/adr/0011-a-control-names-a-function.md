# A Control names one Function of an accessory, by its Separate Functions key

A person wiring a Remote wants one channel of a two-channel relay, one outlet of a power strip, or the light of a fan
with a light, while their Control's targets were whole accessories. We let a Control's targets and Power Switches name
one Function of an accessory, `<accessory id>#<key>`, the key being the one Separate Functions gives that Function (its
subtype, else its type), rather than asking the person to separate the accessory's Functions first: separating them
changes Apple Home (the tile splits, its scenes and automations lose the moved Functions) only to wire a button.

## Considered Options

- **Separate Functions as the way to reach one Function**: no new form of target, but Apple Home reshaped for a
  setting of the bridge's own, and a person who wants one tile in the Home app cannot have both.
- **A key of the Control's own** (the service's subtype, its name, or its iid): each reads one Function too, but a
  Function would then go by two names on the bridge, and moving between the two forms would be a lookup rather than
  the same key with `#` or `:` before it.

## Consequences

- A whole accessory stays a target: it drives its primary Function, or all of its switches and outlets when it is
  made only of them; a light or a shutter stays one, whatever else it has.
- Turning Separate Functions on or off rewrites the Remotes' Controls, `<id>#<key>` and `<id>:<key>` one into the other.
  A Control the rewrite missed (Separate Functions turned off in config.json, by `update_config` or a restore) still
  works: a separated Function's id `<id>:<key>` names that Function of the joined accessory.
- A Function no longer there (a plugin starting, a device gone) is skipped when its Control runs and shown missing on
  the Remotes page, never dropped from the saved Control, so it works again once it is back.
- The Function is read after the last `#`, and only when the accessory before it is on the bridge with a Function of
  that key: an id with a `#` of its own (Shelly's CoIoT names have some) still names the whole accessory.
