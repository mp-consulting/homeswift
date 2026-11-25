# One report decides Adaptive Lighting, for every plugin

Each lights plugin hands the `AdaptiveLightingController` what its device reported, as it came and before it is shown:
`lightReported(on:reachable:colour:)`, with whether the light is on and whether it answers (nil when the report does not
say), and its colour, a white in mireds or a colour (nil for the echo of the bridge's own write). The controller
remembers the last report and decides the same way for every light:

| Last report → this one | Adaptive Lighting |
|---|---|
| No Response → answering and on (the power came back) | stays, and the white for now is written at once |
| off → on, in a white | stays, and the white for now is written at once |
| off → on, in a colour (a scene from a switch) | off: a colour set elsewhere |
| on → on, a white within the tolerance (5 mired, or the device's step) | nothing |
| on → on, another white or a colour | off: set elsewhere |
| off, or No Response | nothing |

Until the white it has just sent reaches the light (Adaptive Lighting just turned on or resumed, or the light just came
on), what the light reports carries the white it had and counts for nothing.

Before this, each plugin compared the colour it was told with the one shown (`disableIfChangedElsewhere`). A light that
came on showed the white it came on in: its power-up white, its last one, or a colour for a colour bulb. That was taken
for a change made elsewhere, so Adaptive Lighting turned off just as the light came on. The bulbs behind wall switches
on one bridge lost it about a hundred times in a week.

## Considered Options

- **Each plugin tells a light that came on from one set elsewhere** (as the Philips Hue plugin first did). Every plugin
  repeats the same rules, and those that miss them keep the bug.
- **The controller watches the lightbulb's On and the accessory's No Response by itself.** Most plugins check the colour
  before they show On, so Adaptive Lighting was already off when On changed. A bulb behind a wall switch also comes back
  with its On never shown off.

## Consequences

- `disableIfChangedElsewhere` and `lightTurnedOn` are the controller's own. A plugin calls `lightReported`, and keeps only
  what is its device's: telling its own echo (`nil` colour) and the step its device rounds to (`tolerance`).
- A plugin whose device reports On and the colour in separate messages (MQTT topics, Z-Wave values, Shelly Gen1) follows
  the lightbulb's On with an observer and reports the colour as it comes.
- A light turned on in a white set elsewhere while it was off gets Adaptive Lighting's white. That is what the Home app's
  own lights do: Adaptive Lighting goes on until a colour is chosen.
