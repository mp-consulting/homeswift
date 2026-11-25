# Mirrors keep their Device Id when Apple Home gives them new ids

A mirrored accessory's Device Id is the HomeKit id it had when the Wingman plugin first saw it, and it keeps that Device
Id when Apple Home later gives the same accessory a new HomeKit id. HomeKit's ids (`uniqueIdentifier`) belong to the Mac
that reads them, not to the home, and they can all change at once: on 2026-11-24 a Mac running Wingman moved to another
network and HomeKit gave all 11 mirrored accessories new ids. The plugin took them for 11 new accessories and removed
the old ones. Two Automations that turned a lamp on now named an accessory that no longer existed, and a Group in them
was gone too.

The plugin remembers each accessory it may mirror, per Wingman, in `accessory-ids.json`: its current HomeKit id, name,
room, home, manufacturer, model and Serial Number. After each read of the homes, an accessory that went and one that
came are taken for the same one when each is the only one of that identity on its side: first by Serial Number with
manufacturer and model, then by home, room, name, manufacturer and model. Two different Serial Numbers are never the
same device. A tie keeps the new id, as before. An accessory that went can be known again for 30 days. Homeswift's ids
(`Wingman:<Device Id>`), Accessory Settings, Excluded and the Discovered Devices go by the Device Id. What goes to
Wingman (writes, scenes, automations, the Home Link's edits) uses the current HomeKit id. The conversions are
`AccessoryIDs` (AccessoryIDs.swift), used by `Mirror` and `Structure`.

The Home Link does the same for Apple Home's Rooms, Zones and Groups. A linked one whose id the Home no longer has is
taken to be the one the Home has under another id and that nothing else is linked to: by name for a Room or a Zone, by
name and members for a Group. A Group's Homeswift id (`group:…`) and a Zone's (`zone:…`) stay, so the Automations that
use them keep working.

## Considered Options

- Rewriting every reference to the old id (Automations, wall layout, Groups, Remote Controls, Accessory Settings,
  history, the Matter bridge) when an accessory changes id. That needs a host-wide "accessory id changed" facility,
  touches every store that holds ids, and still breaks clients that saved an id (an MCP client's notes, a URL).
- Stable ids made by Wingman on the Mac. Wingman would face the same matching problem with less context, since it does
  not know which accessories a bridge mirrors. It also helps only bridges running an updated Wingman.
- Keeping HomeKit's ids as they are (before). Every re-issue silently breaks what refers to the mirrors.

## Consequences

- A Device Id can differ from the id Wingman gives the accessory. Never build `Wingman:<id>` from a HomeKit id
  directly: go through `AccessoryIDs`.
- An accessory removed in the Home app and replaced within 30 days by one of the same name, room and model (and no
  conflicting Serial Number) takes the old one's Device Id, its Automations and settings with it. That is what someone
  replacing a broken lamp expects.
- Accessories that changed id before this decision are not recovered: what referred to them has to be pointed at the
  new ids once.
