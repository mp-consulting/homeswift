# Homeswift

A HomeKit bridge: plugins expose devices as accessories to Apple Home (and Matter), and people configure the bridge,
its plugins and their accessories from the web UI, the command line and AI agents.

## Settings

**Bridge Settings**:
What a person sets for the bridge itself: its name, port, setup code and identity.
_Avoid_: Global settings, server settings

**Location**:
A Bridge Setting: where the home is, for the times of the sun and the weather.
_Avoid_: Coordinates, position, scene location

**Home Time**:
A Bridge Setting: the time zone the home is in, the host's unless a person sets one. Tariffs, energy by the hour,
Automations and the log all run on it, and their times are always written in it; other timestamps on the pages show
in it too unless a person chooses their device's own.
_Avoid_: Server time, local time, bridge timezone

**Home Language**:
A Bridge Setting: the language for what the bridge writes with no one reader, such as notifications on shared
channels and the daily digest. Someone who is known to be reading gets their own Language instead.
_Avoid_: Default language, server language, system locale

**Preferences**:
What one person chooses for how the pages look to them, the same on all their devices: theme, wallpaper,
temperature unit, Language and Regional Formats. They change nothing for anyone else.
_Avoid_: Profile, user settings

**Language**:
A Preference: the language a person reads the pages, the Assistant's answers and their own notifications in.
_Avoid_: Locale, localization

**Regional Formats**:
A Preference: how a person's dates, times, numbers and weeks are written (12- or 24-hour, day/month order,
decimal separator, first day of the week). Each follows the Language and the device's region unless the person picks one.
_Avoid_: Locale, localization, number format settings

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
or Not in Home, which of its Parts are included, whether its Functions are Separate, the Energy Role of each of its
Meters, and a Remote's Controls.
_Avoid_: Layout, common settings

**Arrangement**:
Where accessories sit on the wall, which are favourites, and the order Rooms and Zones are shown in. It is how a
page is laid out, not an Accessory Setting, and it stays the bridge's own: Apple Home's order is not followed.
_Avoid_: Layout, settings

**Plugin Accessory Settings**:
The Accessory Settings one plugin declares for its accessories, such as a sensor's offset, a camera's motion
duration or the type a switch shows as. A plugin may declare some for one Device Kind only, and give one a
plugin-wide default in its Plugin Settings, which an accessory's own value overrules.
_Avoid_: Device config, per-device options, feature options

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
_Avoid_: Feature, sub-device, service, component, Function

**Function**:
One thing an accessory does that Apple Home shows on its own, such as a light, a motion sensor or an outlet. An
accessory's battery and identity are not Functions; they belong to every accessory made from the device.
_Avoid_: Service, feature, sub-accessory, attached accessory

**Separate Functions**:
A Core Accessory Setting that makes each of an accessory's Functions an accessory of its own, so that it can have its
own Name, room and Group. The main Function stays on the device's own accessory. A plugin can say that some Functions
must stay together, such as a camera and the motion sensor its recordings need.
_Avoid_: Split, unbundle, separate tiles

**Not in Home**:
An accessory the bridge has and shows on the wall, but leaves out of Apple Home.
_Avoid_: Excluded, hidden from HomeKit

**Hidden**:
An accessory that is published to HomeKit but left off the web UI's wall.
_Avoid_: Excluded, invisible

**Return Audio**:
The audio HomeKit sends back to a camera while someone talks in the Home app, for the camera's speaker.
_Avoid_: Talkback, backchannel (a camera's own way in for it)

**Talk**:
One continuous period of Return Audio on a live stream, from its first packet to a silence; a plugin sends each to
its camera's speaker.
_Avoid_: Intercom session, talk session

**Helper**:
An accessory whose state the bridge derives from other accessories, such as a sensor crossing a threshold or the
average of several. It has no device behind it.
_Avoid_: Virtual sensor, template, derived accessory, Dummy

## Home

**Home**:
The one Apple Home the bridge's accessories are in. Its Rooms, Zones and Groups are the bridge's; another home the
same people have is not the bridge's concern.
_Avoid_: House, HomeKit home, homes

**Room**:
One of the Home's rooms, its name its own: no two Rooms' names differ only by case or accents. Apple Home keeps the
list and the bridge keeps a copy, so a person can still put accessories in Rooms while the Home Link is down. An
accessory's room is a Core Accessory Setting naming one, and it is the same room the accessory is in in Apple Home:
moving it on either side moves it on the other. A hub's own rooms (Hue, DIRIGERA, eWeLink) are not Rooms; they only
follow a Room's renames.
_Avoid_: Zone, area, group, hub room

**No Room**:
Where an accessory in none of the Rooms is, which Apple Home calls its Default Room. It is never one of the Rooms.
_Avoid_: Default Room, unassigned, unknown room

**Zone**:
One of the Home's sets of Rooms, such as Upstairs, kept like Rooms: Apple Home keeps the list and the bridge a copy.
A Room can be in several Zones. A hub's own zones (Hue's) are not Zones.
_Avoid_: Floor, area, group, Hue zone

**Group**:
Accessories shown and controlled as one, as Apple Home groups them: the Home keeps the list and the bridge a copy, as
for Rooms, and grouping or ungrouping on either side does it on the other. Its members are accessories in Apple Home
of one kind, each with one grouping Function: its only Function, or its explicitly primary light. Associated
Functions, such as light effects, remain independent and accessible. Apple Home may require **Show as Separate Tiles**
for a device with associated Functions to display the Group. One with fewer than two members is no Group. A Group
gathers accessories; a Zone gathers Rooms.
_Avoid_: Wall group, service group, accessory group, Zone

**Home Link**:
The bridge's way to the Home, through a Wingman: while it is up, the bridge's Rooms, Zones and Groups and its
accessories' rooms are Apple Home's, and a change on either side reaches the other. It can be up, down, or up but not
allowed to edit, when only Apple Home's changes reach the bridge.
_Avoid_: Room Sync, sync room names, hub rooms

**Pending Change**:
A change to the Rooms, the Zones, the Groups or an accessory's room made while the Home Link is down, which reaches
Apple Home when it is back up. A change Apple Home does not allow is refused, never kept pending.
_Avoid_: Queued move, offline change

## Setup

**Setup**:
The journey that takes a device from Discovered to an accessory with its Accessory Settings: finding it, authorizing
it and publishing it.
_Avoid_: Onboarding, pairing, adding a device

**Discovered Device**:
A device a plugin has found and can tell apart by its Device Id, whether or not it is set up yet. A scene a hub
keeps is one too, Excluded like any other.
_Avoid_: Candidate, scan result, found device

**Add by address**:
A Setup that starts from a device the person names by its address (a host, perhaps a port, a user and password) rather
than from a Discovered Device: the plugin probes it and says its Device Id, and the device is then set up like a
discovered one. For devices discovery cannot find; with or without an account. A plugin whose devices are made rather
than found (a Helper, a Person) adds them through the same Setup, under its own words ("Add a Helper…").
_Avoid_: Manual device, add manually, static device

**Join**:
A Setup that brings a new device into a plugin's own radio network (Zigbee, Z-Wave): the plugin opens the network,
the person wakes the device (a reset, a button pressed three times), and it comes in as a device of the plugin, under the
plugin's own words ("Add a Zigbee device…"). Forgetting it here leaves it in the network.
_Avoid_: Pairing (HomeKit's), inclusion, permit join (the protocols' own words)

**Device Kind**:
What sort of device a plugin says a Discovered Device is, such as a camera or a sensor, which decides the Plugin
Accessory Settings it has.
_Avoid_: Model, category, accessory type

**Authorization**:
What a device or an account asks before the bridge may talk to it. A plugin instance may need one for its account,
and each device may need its own.
_Avoid_: Pairing, login, linking

**Authorization Method**:
One of the kinds of Authorization the bridge knows how to ask a person or an agent for: None, Button Press, Device
Code, Account Login, Browser Redirect, API Key, or Bridge Setting (one the bridge needs first, such as the Location).
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

## Energy

**Home Energy**:
Where the home's energy comes from and goes: solar production, the home's use, the grid's import and export, and the
batteries' charge and discharge.
_Avoid_: Energy flows, home consumption

**Meter**:
Something in an accessory that measures electricity, gas or water, such as a plug, one channel of a two-channel
relay, one clamp of an energy meter, or a gas or water meter's reader. Phases that add up to one figure are one Meter.
Each Meter has its own Consumption, and an electricity Meter its Energy Role.
_Avoid_: Channel, clamp, power meter, sensor

**Energy Role**:
What a meter measures in the Home Energy: the grid connection, solar production, the home's use, a battery, or
none (a single device's use). Its plugin suggests one; a person may change it.
_Avoid_: Meter type, energy tag, energy kind

**Consumption**:
What one Meter measured being drawn over a span (an hour, a day, a month), in kWh for electricity and m³ for gas and
water, whether or not it counts in the Home Energy.
_Avoid_: Usage, total consumption, energy counter

**Returned**:
The energy one Meter measured flowing the other way over a span: a grid connection's export, or what solar produced.
Only some Meters measure it.
_Avoid_: Export counter, reverse energy, injection

**Unmetered**:
The part of the home's use no Meter accounts for: the home's use less the Consumption of every Meter without an
Energy Role.
_Avoid_: Other, remainder, unknown

**Tariff**:
A Bridge Setting: what the home pays per kWh of electricity, or per m³ of gas or water, from a start date, by period of the day and week, and optionally what
it is paid for the energy it sends back. Changing it starts a new Tariff; past ones keep their prices.
_Avoid_: Price, rate, contract, cost settings

## Presence

**Person**:
Someone who lives in the home, known to the bridge by the devices they carry. A Person is home while one of those
devices is on the network, and away after a grace period without any.
_Avoid_: User, member, occupant, host

**Anyone Home**:
Whether at least one Person is home.
_Avoid_: Occupancy, somebody home, home mode

## Automations

**Scene**:
A set of values for accessories, applied together by hand, from the Home app or by an Automation. A Scene has no
trigger of its own.
_Avoid_: Preset, mood, routine

**Automation**:
What the bridge does on its own: a Trigger, Conditions, and Steps run in order.
_Avoid_: Rule, routine, scene trigger, script

**Trigger**:
What starts an Automation: a time, the sun, a schedule, an accessory's change, or a Person arriving or leaving.
_Avoid_: Event, when

**Condition**:
What must hold when a Trigger fires for its Automation to run: a time window or an accessory's value.
_Avoid_: Filter, guard, if

**Step**:
One thing an Automation does: apply a Scene, set a value, wait, wait until, notify, or call a plugin's action. Steps
run one after the other; an Automation in parallel starts the Steps between two waits together.
_Avoid_: Action, task

## Remotes

**Remote**:
An accessory whose job is to send presses rather than show a state, with at least one Button, whatever plugin it
comes from, Apple Home's mirrored through Wingman included. A doorbell is not a Remote, nor a wall switch whose relay
switches its light.
_Avoid_: Controller, switch, clicker, keypad

**Button**:
One thing on a Remote a person presses: it can be pressed once or twice, held, and let go.
_Avoid_: Key, input, Stateless Programmable Switch (HomeKit's word for its accessory)

**Wheel**:
A part of a Remote a person turns, which reports how far it turned up or down, such as BILRESA's scroll wheel or the
ring of a Hue Tap dial.
_Avoid_: Dial, rotary, ring, scroll

**Channel**:
One of the sets of Buttons and Wheels a Remote switches between on itself, such as BILRESA's three; a Remote without
them has none.
_Avoid_: Mode, page, bank

**Control**:
What one gesture of a Remote's Button or Wheel does, run by the bridge the moment it comes: toggle its targets, turn
them on or off, run a Scene, stop shutters, dim or move them while held, or step them as the Wheel turns. It is not an
Automation: it has no Conditions and no history of its own.
_Avoid_: Binding, mapping, shortcut, button action

**Power Switch**:
A switch or outlet that powers a Control's lights, switched on before they brighten and off once they are dimmed past
their lowest level.
_Avoid_: Relay, master switch

## Lights

**Power On**:
What a light does when its power comes back, from a wall switch or after a power cut: come on in its default white,
come on as it last was, stay as it was before the power went, stay off, come on at a chosen brightness and white, or
Natural Light. The device keeps it, so a change made in its maker's app shows on the bridge too; each light offers only
what its device can do.
_Avoid_: Startup behaviour, power-up, power-on state

**Natural Light**:
The bridge's Power On: the light comes back as it was, on or off, in the white for the time of day, warm at night and
coolest at midday by the sun at the Location. It is every light's that can have it until the light is given one of its
device's own; the bridge keeps the white the device comes back in up to date through the day.
_Avoid_: Adaptive Lighting (the Home app's, which changes a light that is on), circadian light

## History

**History**:
The values an accessory's characteristics took over time: each change for recent days, hourly figures for years.
_Avoid_: Recorder, log, statistics

**Logbook**:
The list of what changed in the home, each entry with its Change Source.
_Avoid_: Activity, events, audit log

**Change Source**:
Who or what made a change: the Home app, a Homeswift user, an MCP client, an Automation or Scene, a Remote's
Control, or the Device itself.
_Avoid_: Origin, actor, context, initiator

## Support

**Diagnostics**:
One file a person downloads for a plugin instance or an accessory, to review and attach to an issue: the versions, the
settings with their secrets masked, the accessories' values and the plugin's recent log, redacted. Names stay in it.
_Avoid_: Debug dump, support bundle, report
