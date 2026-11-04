# Homeswift

A HomeKit bridge: plugins expose devices as accessories to Apple Home (and Matter), and people configure the bridge,
its plugins and their accessories from the web UI, the command line and AI agents.

## Settings

**Bridge Settings**:
What a person sets for the bridge itself: its name, port, setup code and identity.
_Avoid_: Global settings, server settings

**Plugin Settings**:
What a person sets for one plugin instance as a whole, such as a host or a polling interval. Its account's
credentials are not Plugin Settings: they come from Authorization, and change only by setting it up again.
_Avoid_: Plugin config, platform options

**Accessory Settings**:
What a person sets for one accessory a plugin instance exposes. Some are the same for every accessory (Core
Accessory Settings); the rest a plugin declares for its own accessories (Plugin Accessory Settings).
_Avoid_: Device settings, device options, overrides, feature options

**Core Accessory Settings**:
The Accessory Settings every accessory has whatever its plugin: its Name, its room, whether it is Excluded, Hidden
or Not in Home, and which of its Parts are included.
_Avoid_: Layout, common settings

**Arrangement**:
Where accessories sit on the wall and which are favourites. It is how a page is laid out, not an Accessory Setting.
_Avoid_: Layout, settings

**Plugin Accessory Settings**:
The Accessory Settings one plugin declares for its accessories, such as a sensor's offset, a camera's motion
duration or the type a switch shows as. A plugin may declare some for one Device Kind only, and give one a
plugin-wide default in its Plugin Settings, which an accessory's own value overrules.
_Avoid_: Device config, per-device options, feature options

**Room Sync**:
A Bridge Setting that keeps Homeswift's Rooms in step with the hubs' rooms of the same name: renaming a Room
renames theirs, and moving an accessory moves it in Apple Home, in both directions.
_Avoid_: Sync room names, hub rooms

## Accessories

**Device Id**:
The identifier a plugin knows one device by, unique within that plugin, such as a light's MAC or a robot's serial
number. Each plugin picks one kind and keeps it.
_Avoid_: MAC, serial, serialNumber, deviceId, host, address

**Accessory Id**:
The one name an accessory goes by in settings: its plugin's platform name and its Device Id
(`ElgatoKeyLights:<MAC>`). Display names are not addresses.
_Avoid_: MAC, serial, aid

**Name**:
The one name an accessory goes by, on the bridge's pages and in Apple Home alike.
_Avoid_: Display name, label, HomeKit name, displayName

**Excluded**:
A device its plugin does not make into an accessory at all: not polled, not on the wall, not in Apple Home or Matter.
_Avoid_: Ignored, disabled, removed, enabled: false

**Part**:
Something a device brings that a person can leave out while keeping the device, such as a gate's side door, a door's
position sensor or a doorbell. A Core Accessory Setting keeps which parts are included.
_Avoid_: Feature, sub-device, service, component

**Not in Home**:
An accessory the bridge has and shows on the wall, but leaves out of Apple Home.
_Avoid_: Excluded, hidden from HomeKit

**Hidden**:
An accessory that is published to HomeKit but left off the web UI's wall.
_Avoid_: Excluded, invisible

## Setup

**Setup**:
The journey that takes a device from Discovered to an accessory with its Accessory Settings: finding it, authorizing
it and publishing it.
_Avoid_: Onboarding, pairing, adding a device

**Discovered Device**:
A device a plugin has found and can tell apart by its Device Id, whether or not it is set up yet. A scene a hub
keeps is one too, Excluded like any other.
_Avoid_: Candidate, scan result, found device

**Device Kind**:
What sort of device a plugin says a Discovered Device is, such as a camera or a sensor, which decides the Plugin
Accessory Settings it has.
_Avoid_: Model, category, accessory type

**Room**:
One of the bridge's places that accessories are in. An accessory's room is a Core Accessory Setting naming one;
with Room Sync on it is also the accessory's room in Apple Home.
_Avoid_: Zone, area, group

**Authorization**:
What a device or an account asks before the bridge may talk to it. A plugin instance may need one for its account,
and each device may need its own.
_Avoid_: Pairing, login, linking

**Authorization Method**:
One of the kinds of Authorization the bridge knows how to ask a person or an agent for: None, Button Press, Device
Code, Account Login, Browser Redirect or API Key.
_Avoid_: Pairing type, auth mode

**Optional Account**:
A plugin instance's account that its devices work without, which adds something (a password on a webhook server). Left
alone, it does not Need Authorization.
_Avoid_: Optional login, optional sign-in

**Setup Session**:
One Setup in progress, held by the bridge rather than the plugin, so a plugin reloading does not lose it.
_Avoid_: Pairing session, wizard

**Needs Authorization**:
A Discovered Device, an accessory or a plugin instance's account whose Authorization is missing or no longer works
(refused). Setting it up again keeps its Accessory Id and Accessory Settings. A plugin instance whose account Needs
Authorization is not shown as running: its card says what it needs (Needs sign-in, Needs pairing, Needs keys).
_Avoid_: Unpaired, broken, offline

**Forget**:
To drop a device's Authorization and Accessory Settings, so that it is only a Discovered Device again if it is still
reachable.
_Avoid_: Remove, delete, unpair, Excluded
