# Apple Home owns the Rooms, Zones and Groups; the bridge keeps a linked copy

Room Sync was a switch that kept two lists of rooms in step by name: the bridge's (`accessory-layout.json`, names
only) and every hub's, Apple Home's through Wingman. Matching by name merged "Cafe" and "Café", raced renames made in
the Home app against the moves they implied, and missed creates, deletes, the Default Room and anything that happened
while the bridge was down. There is now one definition. The Rooms, Zones and Groups are those of the Home, the one
Apple Home where Wingman finds the Homeswift bridge. The bridge keeps a copy in which each Room, Zone and Group is
linked to its HomeKit `uniqueIdentifier`, and matching by name happens only once, when an unlinked one first links.

- While the Home Link is up, creating, renaming or deleting a Room, Zone or Group, or moving or grouping an accessory,
  on either side does the same on the other.
- While it is down, the bridge keeps working on its copy and holds its changes as Pending Changes.
- When the link is up but not allowed to edit, Apple Home's changes still reach the bridge, and the bridge's own are
  refused.
- On connect Apple Home wins, except for Pending Changes. A bridge's first link shows a comparison that a person
  confirms.
- Names are unique within the Home, ignoring case and accents, so an accessory's `room` setting keeps naming its Room.
- No Room is Apple Home's Default Room, never one of the Rooms.
- The order of Rooms and Zones stays the bridge's own Arrangement.
- Room Sync, `bridge.roomSync` and the layout's `syncRoomNames`, is read once and dropped.

This replaces the Room Sync part of ADR 0003. It also corrects ADR 0003 on where the Rooms are listed: only
`accessory-layout.json`, never `ui-layout.json`.

## Considered Options

- **Keep Room Sync as a switch, matching by name:** two definitions that drift whenever it is off, and every bug above
  whenever it is on.
- **Make the bridge the owner and push to Apple Home:** Apple Home is where the household, Siri and automations already
  use rooms, and the Home app's edits would always be second-class.
- **Two-way last writer wins:** no answer for changes made while the bridge is down, and renames racing moves again.

## Consequences

- Hue, DIRIGERA and eWeLink rooms are not Rooms. They only follow a Room's renames, by name, and never add to the list.
  Hue's zones are not Zones.
- Wingman needs endpoints it lacks: creating and deleting rooms on their own, zones, and service groups. How the Home
  app shows a service group made through the API that breaks its own grouping rules needs checking on a real home.
- A Group follows the Home app's rules on every side: accessories of one kind, each with one Function, all in Apple
  Home. Wall groups that break them are listed in the first link's comparison. Separating Functions (ADR 0006) is how
  an accessory with others attached becomes groupable.
- Accessories are found in Apple Home by serial number, so the bridge gives every accessory it publishes a serial that
  is unique on the bridge. It only matches Home accessories that really are on a Homeswift bridge, or that Homeswift
  publishes on their own.
- Wingman mirrors only the Home's accessories, and its `homes` setting goes away. An accessory Homeswift publishes on
  its own but that sits in another home is outside the Home, and a warning says so.
- When several Wingmen are signed into the Home, one is the Home Link and the others take over when it goes down.
- Matter has no Rooms.
