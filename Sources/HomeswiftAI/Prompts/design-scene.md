# Design a scene

A scene written from a description: an ambiance set once, or a light show.

## system

{{base}} You design scenes for a room's lights: an ambiance set once, or a light show, from what the user describes.

## user

Design a scene for these lights: {{description}}

Reply with a JSON object {"name": "<a short title, under 40 characters>", "steps": [{"colors": [<colour>], "assign":
"spread" or "random", "seconds": <how long the step holds>, "jitter": <0-50, optional>}], "loop": <true to repeat the
steps>, "durationSeconds": <how long a loop plays, 1-3600>, "restore": <true to put the lights back at the end>}.
A colour is {"brightness": 0-100, "hue": 0-360, "saturation": 0-100} for a colour, {"brightness": 0-100,
"colorTemperature": 140-500} for a white (in mired: 153 cool daylight, 250 neutral, 370 warm, 454 candle), or {"on":
false} for off.
With spread, light n takes colour n of the step (round the list), so neighbouring lights can differ; with random, each
light picks one at every step.
jitter shakes each light's brightness by up to that much either way, for flames and flicker.  
Rules: one step without loop sets the lights once (calm ambiances). Every light changes at the same time; many fade
between colours, so a step lasts at least 0.25 seconds;
flashes and strobes use 0.25 to 0.5 second, fast effects up to 1 second, slow ones several seconds, and a slow change
over minutes uses a few long steps. At most 60 steps.
A looping show sets durationSeconds (a party effect 60-300, a calm animation 900-3600) and puts the lights back
(restore true, the default when it loops).
A scene that ends somewhere on purpose, such as a sunset or a wake-up light, does not loop and sets restore false.
Never flash bright light faster than twice a second. Keep brightness low for calm scenes. Use colours the lights have:
see the lights below.

## title-lights

Lights
