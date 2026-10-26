# Accessory widgets

The web UI's Accessories page draws every accessory with the widget of its kind: an air conditioner gets a
gauge, its setpoints and modes; a light its brightness, colours and white temperature; a shutter a tile you
slide; a gate a button you hold. Widgets sit on a wall of compact rows, packed with no gaps, in the size you
choose for each one. They are built from what HomeKit already knows about an accessory (its services, their
characteristics, formats and ranges), so a plugin gets them without writing a line of web code.

![The Accessories page: a wall of widgets](images/widgets/wall.png)

The page is `Sources/HomeswiftUI/Web/widgets.js` (the widgets) and `app.js` (the wall). The screenshots on this
page use demonstration names; [Screenshots](#screenshots) says how they are taken.

Explore the real widgets and every characteristic in the [interactive design system](https://homeswift.dev/design/).
Its [maintainer guide](design-system.md) explains the catalog, isolated demo transport and sync checks.

## On the page

### Four sizes

Small and Medium use fixed boxes; Large and Extra large fit their controls to the grid:

| Size | Box | What it shows |
|---|---|---|
| **Small** | 1×1 | A compact horizontal tile: icon, name and status. A tap acts (on and off, open and close, run and stop); opening or unlocking requires a hold. |
| **Medium** | 1×2 | A taller tile: icon and main figure above the name and status, with the same tap and hold actions. Two compact tiles fit beside it. |
| **Large** | 2×automatic | The main controls: a brightness slider and colours, a setpoint, or a position and its buttons. |
| **Extra large** | 2×automatic | Expanded controls: the gauge and modes of a climate, a purifier's readings, a TV's remote. |

![One accessory in its four sizes](images/widgets/sizes.png)

Every kind has the four sizes, and a default: extra large for climate, purifiers and televisions, medium for lights
with colour, valves, gates and groups of switches, small for switches, shutters and sensors. Columns are at
least 176 CSS pixels, widened to fill each row; a phone always has two columns. Compact rows are 36% of a column's width, at least 64 pixels, with a 10-pixel gap.
At a 393-pixel phone width and 16-pixel page margins, a compact tile is about 176×64 pixels and a medium tile
176×138 pixels. Large and Extra large span both phone columns. Their heights follow the controls, rounded up to whole grid rows
(two to eight for Large, three to eight for Extra large), so sparse cards do not reserve empty space. The full controls remain available through **All controls**.

![A purifier, a valve and a gate in their four sizes](images/widgets/sizes-more.png)

### Choosing sizes and places

A widget's **⋯** menu (revealed on hover or keyboard focus on a compact tile; also a right click) offers S, M, L and XL as square badges in one row,
makes its size the one of every accessory
of the kind ("Medium for every light"), and opens **All controls**. **Edit** shows the sizes and ‹ › arrows on
every widget, and lets them be dragged: the widget lifts and follows the pointer or the finger, the others make
room as it passes, and it lands where it is let go. A subtle background grid shows the actual cell spacing and
empty space. Drag the bottom-right corner to snap between Small, Medium, Large and Extra large; neighbouring
widgets slide into their new places. Focus the corner handle and use arrow keys to resize with a keyboard. Near the window's top or bottom the page scrolls. **One wall**
(the default) puts every accessory on one wall; **By plugin** gives each plugin a wall of its own.

![Grid guides and a corner resize handle in Edit mode](images/widgets/grid-editing.png)

![The ⋯ menu of a light](images/widgets/menu.png)

![Edit: the size and position controls over each widget](images/widgets/edit.png)

The bridge keeps the layout in `ui-layout.json` next to config.json, the same for every user of the web UI: the
order, the size of each accessory you sized, the size of each kind, and the grouping. An accessory the layout
does not list yet goes at the end, by plugin and name.

### All controls

A compact box shows what fits; Large and Extra large adjust their heights to the controls. **All controls** opens every control of the accessory in a sheet: the widget's
own, the services linked to it as chips, readouts, meters and blocks, and under **More**, as rows, whatever no
widget shows. An accessory no widget knows gets those rows, so nothing a plugin exposes is out of reach.

![All controls of an air conditioner](images/widgets/sheet.png)

### Shutters, lights, locks

- **A shutter's small tile slides.** With a mouse, drag it up to open, down to close; with a finger, hold it a
  moment first, so a swipe still scrolls the page. The shade follows, and the position is written when you let
  go. A tap opens or closes it fully.

  ![A shutter slid halfway](images/widgets/slide.png)

- **Adaptive Lighting.** A light with Adaptive Lighting has a sun swatch first among its colours (a round button
  beside the white slider for a light without colours). HomeKit starts Adaptive Lighting: when you turn it on in
  the Home app, the Home app sends a day's schedule of whites, which a home hub renews. The bridge keeps the last
  schedule; the swatch turns it off, and on again by resuming that schedule, moved by whole days so it keeps its
  times of day. A light whose Adaptive Lighting was never turned on in the Home app says so when the swatch is
  pressed. Picking a colour or a white turns it off, as in the Home app.

  Apple Home lights mirrored through Wingman show their latest reported colour temperature in kelvin in the
  status line, when available. Their Apple Adaptive Lighting schedule stays in Apple Home. Lights with writable
  colour temperature and no bridge Adaptive Lighting controller offer a separate **Homeswift Natural Lighting**
  sun toggle. It saves an opt-in per light and uses the browser's time zone: 2200 K at night, 4000 K at 09:00,
  5000 K at midday–15:00, 3500 K at 18:00, and 2200 K at 21:00, interpolating between these points and clamping
  to the lamp's range. It checks once per minute while Homeswift runs, without changing power or brightness.
  Manual colour writes through Homeswift pause it; a different white temperature reported by another controller
  also pauses it on the next check. Press the sun to resume. Pauses and opt-ins survive restarts.
  This is a clock-based schedule, not a sunrise/location calculation or Apple's Adaptive Lighting.

  The Apple Home source filter uses the Home app icon, a count badge and an accessible switch.

  ![An Apple Home light showing its reported colour temperature](images/widgets/wingman-adaptive.png)

  ![A light with Adaptive Lighting on](images/widgets/adaptive.png)

- **Security.** Opening a gate or a garage door, unlocking a lock, turning an alarm off, and turning on a switch a
  plugin marked as a security control are held for a moment, the fill running across; let go early and nothing
  is sent. Closing, locking and arming are a tap. On a small tile the tile itself is held.

### Paused plugins

A paused plugin's accessories answer HomeKit with No Response. Their widgets are drawn striped and grey with
"Paused · *the plugin*" under their name, and their controls are out of reach; the ⋯ menu stays, with **Resume
*the plugin***. A write that reaches the bridge anyway is refused in words ("eWeLink is paused: resume it on
the Plugins page…"), as is one to a device that does not answer.

![A paused plugin's accessories](images/widgets/paused.png)

## The widgets

The widget is chosen from the accessory's primary service (the one marked `isPrimary`, else the first of the
list below that it has):

| Primary service | Widget | Small | Medium | Large | Extra large |
|---|---|---|---|---|---|
| Television | Television | power | power, status | input, volume, mute | remote, input |
| HeaterCooler, Thermostat | Climate | temperature, mode by colour | temperature, setpoint status | inside and setpoint | gauge, setpoints, modes, fan speed, swing |
| AirPurifier | Air purifier | air quality | air quality, status | speed and readings | mode, speed, four readings, filter, switches |
| SecuritySystem | Alarm | hold to turn off | state, hold to turn off | state and arm controls | the same, larger |
| GarageDoorOpener | Gate | hold to open | state, hold to open | state, hold to open or close | with its locks and sensors |
| LockMechanism | Lock | hold to unlock | state, hold to unlock | state, hold to unlock or lock | the same |
| WindowCovering, Door, Window | Shutter | slide, tap | position, slide to set | position, open, stop, close | a window to slide, tilt |
| Valve | Valve | run or stop, time left | run or stop, time left | ring and duration | larger ring |
| Fanv2, Fan | Fan | speed | speed, on and off | speed | speed, modes, direction, swing |
| Lightbulb | Light | on and off, brightness | brightness, on and off | brightness, colours or white | tall brightness, colours, white |
| Switch, Outlet (one) | Switch | on and off | on and off | a big switch | a power button, its facets |
| Switch, Outlet (several) | Group of switches | how many are on | how many are on | chips | a tile each |
| Sensors | Sensor | the reading | the main reading | the readings | the readings, battery |
| (a camera) | Camera | the picture | the picture | the picture | the picture with its buttons |
| anything else | Rows | power | power, status | its first rows | more rows |

What a widget does not show of the primary service, and the accessory's other services, become **facets**:
switches as chips, sensors as readouts, a filter or a battery as a meter, a secondary light, fan, thermostat or
lock as a block.

The controls follow the characteristics:

- A writable value with two to four choices (`validValues`, or a known enumeration) is a segmented control.
- A range of six positions or fewer (`(maxValue − minValue) / minStep ≤ 6`, such as a fan's speed in steps of
  20) is a row of bars; a larger one a level, which moves with the pointer and writes when let go.
- A colour temperature in mireds shows and is set in kelvin, on a track of its own whites.
- A change shows at once and goes to the device; a refusal puts the value back and says why under the name.
  Values follow the device live (the page's event stream).

## For plugin developers

Nothing in a plugin is specific to the web UI: shape your accessories for HomeKit, and the widgets follow. A
few choices make them better.

### Mark the primary service, link the rest

The primary service picks the widget; the others become its facets, named after their `Name` (minus the
accessory's name), else their subtype ("climateControl:indoor_silent_mode" reads "Indoor silent mode").

```swift
// An air conditioner: the climate widget, its fan speed as five bars, a swing chip, the room's humidity as a
// readout and the filter as a meter.
let climate = Service(
    .heaterCooler, name: "Living Room",
    optional: [.rotationSpeed.with(minStep: 20), .swingMode, .coolingThresholdTemperature.with(minValue: 18, maxValue: 32, minStep: 0.5)],
    isPrimary: true)
let humidity = Service(.humiditySensor, name: "Living Room Humidity", subtype: "humidity")
let filter = Service(.filterMaintenance, name: "Filter", subtype: "filter", optional: [.filterLifeLevel])
let quiet = Service(.switch, name: "Quiet", subtype: "quiet")
climate.linked = [humidity, filter, quiet]

climate.characteristic(.active).onWrite { value in try await device.setPower(value.intValue == 1) }
climate.characteristic(.targetHeaterCoolerState).onWrite { value in try await device.setMode(value.intValue ?? 0) }
climate.characteristic(.coolingThresholdTemperature).onWrite { value in try await device.setTarget(value.doubleValue ?? 24) }
climate.characteristic(.rotationSpeed).onWrite { value in try await device.setFan(Int(value.doubleValue ?? 0) / 20) }

try context.add(Accessory(
    id: "\(Self.platform):\(device.id)", name: "Living Room", manufacturer: "Acme", model: "AC-1",
    category: .airConditioner, services: [climate, humidity, filter, quiet]))
```

### Give ranges their real steps and bounds

A `minStep` that leaves six positions or fewer turns a slider into bars; `minValue` and `maxValue` give the
gauge and the setpoints their range. Restrict `validValues` to the modes the device has: a thermostat with only
Off and Heat gets a two-choice control.

```swift
// A heater: Off and Heat only, 5 to 30 °C in half degrees.
let thermostat = Service(
    .thermostat, name: "Studio",
    optional: [],
    extra: [
        Characteristic(.targetHeatingCoolingState.with(validValues: [0, 1])),
        Characteristic(.targetTemperature.with(minValue: 5, maxValue: 30, minStep: 0.5), value: .double(20)),
    ],
    isPrimary: true)
```

### Shutters: report where they are, and how to stop

The shutter widget reads Current Position and Position State and writes Target Position; with Hold Position, its
Stop button sends it, else it writes the current position as the target.

```swift
let shutter = Service(.windowCovering, name: "Kitchen Shutter", optional: [.holdPosition], isPrimary: true)
shutter.characteristic(.targetPosition).onWrite { value in try await motor.move(to: value.intValue ?? 0) }
shutter.characteristic(.holdPosition).onWrite { _ in try await motor.stop() }
// As the motor reports: 0 closing, 1 opening, 2 stopped.
await motor.onProgress { position, moving in
    shutter.characteristic(.currentPosition).value = .int(position)
    shutter.characteristic(.positionState).value = .int(moving)
}
```

### Mark what opens or unlocks

Lock Target State, Target Door State and Security System Target State are security controls already: their
widgets hold to confirm. A characteristic of your own that unlocks or opens something gets the same:

```swift
// A switch that releases the gate's latch: held to turn on in the web UI, confirmed by MCP clients.
let release = Service(.switch, name: "Release Latch", subtype: "latch", isPrimary: true)
release.characteristic(.on).isSecurityControl = true
```

### Adaptive Lighting

A light with Brightness and Color Temperature can have Adaptive Lighting: make an `AdaptiveLightingController`
for its lightbulb before the accessory is added, keep it (the lightbulb holds it weakly), and pass it to
`context.configureController` so its schedule survives restarts. In automatic mode the controller sets the
temperature through your Color Temperature write handler; turn it off when the light's colour changes outside
HomeKit.

```swift
let lightbulb = Service(.lightbulb, name: name, optional: [.brightness],
    extra: [Characteristic(.colorTemperature.with(minValue: 143, maxValue: 344), value: .int(250))], isPrimary: true)
lightbulb.characteristic(.colorTemperature).onWrite(changesOnly: true) { value in
    try await device.setTemperature(value.intValue ?? 250)
}
let adaptiveLighting = AdaptiveLightingController(lightbulb, mode: .automatic, logger: context.logger)
let accessory = Accessory(id: "\(Self.platform):\(device.id)", name: name, category: .lightbulb, services: [lightbulb])
context.configureController(adaptiveLighting, accessoryID: accessory.id)
self.adaptiveLighting[device.id] = adaptiveLighting   // kept as long as the light is on the bridge
try context.add(accessory)

// The light was set from its own app: Adaptive Lighting stops, as when the Home app sets a white.
await device.onTemperatureChange { mireds in
    if adaptiveLighting.isAdaptiveLightingActive { adaptiveLighting.disableAdaptiveLighting() }
    lightbulb.characteristic(.colorTemperature).value = .int(mireds)
}
```

The web UI's sun swatch then appears on the light, and `PUT /api/accessories/<id>/adaptive-lighting` turns it off
or resumes the Home app's last schedule (`resumeAdaptiveLighting()`). The Govee, Elgato Key Lights and Philips
Ambilight TV plugins do this.

### Widgets on your plugin's own page

A plugin page (see [ui.md](ui.md)) can draw accessories as the Accessories page does:

```html
<link rel="stylesheet" href="/style.css">
<div class="accessory-walls"><div class="wall" id="lights"></div></div>
<script src="/common.js"></script>
<script src="/remote.js"></script>
<script src="/camera.js"></script>
<script src="/widgets.js"></script>
<script src="/plugin.js"></script>
<script>
  (async () => {
    const all = await homeswift.api("/api/accessories");
    const mine = all.filter((accessory) => accessory.platform === "ElgatoKeyLights");
    const wall = document.getElementById("lights");
    for (const accessory of mine) wall.append(HomeswiftWidgets.card(accessory, { size: "medium" }));
    HomeswiftWidgets.listen();   // live values from the bridge's event stream
  })();
</script>
```

`HomeswiftWidgets.card(accessory, { size, actions })` answers the widget (`small`, `medium`, `large` or `xlarge`; the kind's
own size when left out; `actions(accessory)` the items of its ⋯ menu after All controls).
`HomeswiftWidgets.open(accessory)` opens All controls in a sheet. `HomeswiftWidgets.kindOf(accessory)` answers
`{ kind, size }`, its kind of widget and that kind's size.

### A widget of your own

For an accessory the built-in widgets draw poorly, a page can register its own, tried before them. `build`
answers the parts the frame draws. Compact and tall tiles both use `small` parts (their icon, figure, status
and tap/hold actions). A large tile uses `medium` parts (main controls), extra large uses `large` parts
(expanded controls), and `full` draws the sheet:

```js
const { level, chip } = HomeswiftWidgets.controls;
HomeswiftWidgets.register({
  name: "aquarium", types: ["Lightbulb"], icon: "bulb", tone: "blue", size: "medium",
  match: (ctx, primary) => ctx.accessory.model === "Reef LED",
  build(ctx, primary, size) {
    const on = ctx.take(primary, "On"), brightness = ctx.take(primary, "Brightness");
    const dim = level({ label: "Daylight", min: 0, max: 100, format: (v) => `${v} %` }, (v) => ctx.write(primary, brightness, v));
    ctx.watch(() => dim.set(brightness.value));
    return {
      body: size === "small" ? [] : [dim.node],
      power: { service: primary, characteristic: on },
      tap: () => ctx.write(primary, on, !on.value),
      on: () => on.value === true,
      status: () => [on.value ? `Daylight ${brightness.value} %` : "Night"],
    };
  },
});
```

`ctx.char(service, type)` finds a characteristic, `ctx.take` finds it and marks it shown (the rest goes under
More in the sheet), `ctx.write(service, characteristic, value)` writes it (at once on the page, back with the
reason when the device refuses), `ctx.watch(paint)` repaints after every change of the accessory.

## Screenshots

The checked-in images use demonstration accessories and the production widget code. Retake them with:

```bash
node Scripts/widget-screenshots.mjs
```

This starts a throwaway localhost fixture server and headless Chrome in light mode at 2x, captures the wall,
phone, sizes, paused state, menus, Edit, Adaptive Lighting, shutter slide and full sheet, and checks the tile
alignment and tap/hold actions. It also captures the group picker, mobile menu, Wingman temperature, grid guides
and notification settings (saved as `docs/images/notifications.png` by default). It does not connect to devices or read any real names. The demonstration data
is in `Scripts/fixtures/widgets.js`.

To take screenshots against a running throwaway bridge instead, `wall.png`, `phone.png` and `paused.png` can use `Scripts/docs-screenshots.mjs`, run against a throwaway bridge with real
accessories: a copy of a configuration directory with a new identity (no `username` or `pin` in `bridge`, another port,
no `homeswift.json`, no `external/`), every plugin block `_paused` so nothing reaches a device or a cloud, the web UI on
`127.0.0.1` with `auth: none`, and its `accessories/` cache, which brings the accessories back with their last values.
Blocks whose accessories are published on their own (televisions, cameras) are left out: they would advertise new
identities. Then:

```bash
node Scripts/docs-screenshots.mjs http://127.0.0.1:18582 ~/names.json
```

`names.json`, kept out of the repository, maps each real name to a demonstration name (`"names"`) and overrides values
that would look broken (`"values"`, by demonstration name and characteristic type, such as a sensor that was off). The
script renders in light mode at 2x and rewrites the page's accessory data as it loads, never the page itself. The fixture script above also captures sizes, menus, the sheet, a slide, Adaptive Lighting and Edit without live devices.

## The HTTP API

| Request | What it does |
|---|---|
| `GET /api/layout` | The wall: `{ order, sizes, defaults, grouping, groups }`. |
| `PUT /api/layout` | Keeps it, checked: ids in `order` and `sizes`, sizes `small`, `medium`, `large` or `xlarge`, `defaults` by kind (`climate`, `light`…), `grouping` `none`, `plugin` or `room` (the rooms of `/api/rooms`), and `groups` containing `{ id, name, members }`. |
| `PUT /api/accessories/<id>/adaptive-lighting` | `{ "on": true }` resumes the Home app's last schedule, `false` turns it off; `service` picks the lightbulb when there are several. 409 with what to do when there is no schedule. |

`PUT /api/accessories/<id>/natural-lighting` takes `{ "on": true, "timeZone": "Europe/Lisbon" }`,
with an optional `service` to choose a lightbulb service. Use `on: false` to remove its schedule. This is
Homeswift's schedule, not an API for enabling Apple Adaptive Lighting.

In `/api/accessories`, a light with Adaptive Lighting has `adaptiveLighting: { active, resumable }` on its
service, and an accessory of a paused plugin `paused: true`.

### Accessory groups

Use **Create group** on Accessories, or in Edit mode drag a compatible accessory onto the highlighted center of another tile and drop. Confirm the group name and members before saving. A group's menu lets you edit its members or ungroup them. Administrators can also use **Move to room…** to move every member together in Homeswift; Apple Home/HomeKit room assignments stay unchanged. Enter a new room name to create it, or leave it empty to remove the members from their Homeswift rooms. Groups are dashboard controls, not new HomeKit accessories; member tiles return when ungrouped.

When the wall is split by room or plugin, a group appears in the section of its first visible member in saved selection order. By default, grouping keeps the members’ room assignments. Choosing a room in the group editor moves the selected members in Homeswift only. The room selector and device-type filters show available counts that follow the search. Clear filters restores all rooms and device types; selected members stay selected. On small screens, Cancel and Save remain visible while the picker scrolls.

Groups offer only shared writable controls for lights, switches/outlets, fans and window coverings. A member with several such services joins through its primary one (a Philips Hue light's lightbulb, not its effect, Flash or gradient-point services); one without a primary service, whose services share a control, stays out. When the members differ, the switch is half lit with its thumb between, "2 of 5 on" under its name, and a tap turns them all on; a slider shows the spread, solid to the lowest member and lighter to the highest ("40–80 %"; a band between the two on colour temperature), until it is moved. Partial failures identify the devices that could not be updated. Locks and alarm controls are excluded. Membership is saved in `ui-layout.json`. The **No Response** filter shows individual unavailable or paused accessories, including group members.

Group brightness and colour-temperature controls use the same pill sliders as individual lights, with temperature shown in kelvin and differing values marked **Mixed**.

![Grouped light controls](images/widgets/group-controls.png)

![Accessory group picker with available and selected devices](images/widgets/group-picker.png)

When grouped by room, Edit shows **Reorder rooms**. Drag the handles in its menu to arrange rooms, just like the Status page’s customisation menu. **Reset room order** restores alphabetical order. The order is saved in Homeswift; HomeKit rooms are unchanged.
