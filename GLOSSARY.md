# Homeswift

A HomeKit bridge: plugins expose devices as accessories to Apple Home (and Matter), and people configure the bridge,
its plugins and their accessories from the web UI, the command line and AI agents.

## Settings

**Bridge Settings**:
What a person sets for the bridge itself: its name, port, setup code and identity.
_Avoid_: Global settings, server settings

**Plugin Settings**:
What a person sets for one plugin instance as a whole, such as an account, a host or a polling interval.
_Avoid_: Plugin config, platform options

**Accessory Settings**:
What a person sets for one accessory a plugin instance exposes. Some are the same for every accessory (Core
Accessory Settings); the rest a plugin declares for its own accessories (Plugin Accessory Settings).
_Avoid_: Device settings, device options, overrides, feature options

**Core Accessory Settings**:
The Accessory Settings every accessory has whatever its plugin, such as its room or whether it is Excluded.
_Avoid_: Layout, common settings

**Plugin Accessory Settings**:
The Accessory Settings one plugin declares for its accessories, such as a sensor's offset or a camera's motion
duration.
_Avoid_: Device config, per-device options

## Accessories

**Device Id**:
The identifier a plugin knows one device by, unique within that plugin, such as a light's MAC or a robot's serial
number. Each plugin picks one kind and keeps it.
_Avoid_: MAC, serial, serialNumber, deviceId, host, address

**Accessory Id**:
The one name an accessory goes by in settings: its plugin's platform name and its Device Id
(`ElgatoKeyLights:<MAC>`). Display names are not addresses.
_Avoid_: MAC, serial, aid

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
A device a plugin has found and can tell apart by its Device Id, whether or not it is set up yet.
_Avoid_: Candidate, scan result, found device

**Authorization**:
What a device or an account asks before the bridge may talk to it. A plugin instance may need one for its account,
and each device may need its own.
_Avoid_: Pairing, login, linking

**Authorization Method**:
One of the kinds of Authorization the bridge knows how to ask a person or an agent for: None, Button Press, Device
Code, Account Login, Browser Redirect or API Key.
_Avoid_: Pairing type, auth mode

**Setup Session**:
One Setup in progress, held by the bridge rather than the plugin, so a plugin reloading does not lose it.
_Avoid_: Pairing session, wizard

**Needs Authorization**:
A Discovered Device or an accessory whose Authorization is missing or no longer works. Setting it up again keeps its
Accessory Id and Accessory Settings.
_Avoid_: Unpaired, broken, offline

**Forget**:
To drop a device's Authorization and Accessory Settings, so that it is only a Discovered Device again if it is still
reachable.
_Avoid_: Remove, delete, unpair, Excluded
