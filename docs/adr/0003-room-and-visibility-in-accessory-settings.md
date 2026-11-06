---
status: accepted; its Room Sync part superseded by ADR-0005
---

# Room, Hidden and Not in Home are Accessory Settings; the layout files keep only the Arrangement

An accessory's room and whether it is Hidden lived in `accessory-layout.json` with its favourites, its name in three places
(`_accessories.<id>.name`, the layout's display name, legacy `devices[].name`), and Not in Home in a block-level
`_hiddenFromHomeKit` map keyed by Accessory Id. They are now Core Accessory Settings in `_accessories` beside Excluded
and Parts, with one Name, keyed as names already were: by Device Id, or for a device's other accessories by their
Accessory Id without the platform (`<deviceID>:<more>`), so two accessories of one device can sit in different Rooms, so the editor, Setup and `update_settings` reach every Accessory Setting in one place; they
apply live, without reloading the plugin. The layout files (`accessory-layout.json`, `ui-layout.json`) keep only the
Arrangement: the wall's order and sizes, favourites, and the list of Rooms with their order. Room Sync, which was the layout's `syncRoomNames`, is a Bridge Setting, still
switched from the Accessories page's Rooms menu. The old places are read and migrated, never written.

## Consequences

- With Room Sync on, an accessory's room is also its room in Apple Home (through Wingman), so a move made in the Home
  app writes the accessory's settings. A Wingman accessory always moves in Apple Home, Room Sync or not, and its Name
  stays read-only until Wingman can rename an accessory.
