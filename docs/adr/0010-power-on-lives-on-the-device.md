# A light's Power On lives on its device, Natural Light on the bridge

What a light does when its power comes back is kept by the light itself (a Hue light's `powerup`, a Matter light's
StartUp attributes, a Zigbee light's power-on behaviour, a Key Light's settings), and its maker's app changes it too. We
made Power On a standard setting of every light read from and written to the device through its plugin, rather than an
Accessory Setting the bridge stores and applies: a stored copy either shows the wrong thing after the maker's app
changes it or undoes that change at the next start. Natural Light, which no device can do alone, is the one choice the
bridge keeps (the Core Accessory Setting `naturalLight`), and it is every light's that can have it unless given another.

## Considered Options

- **A stored Accessory Setting applied at start** (as the Elgato plugin had): one place for the value, but two truths,
  and a restart that quietly reverts what the maker's app set.
- **Natural Light by watching for the power coming back** (the light reappearing, then given the white): no writes
  through the day, but a wall switch flicked off and on again within a few seconds is never seen, and the light comes
  back in whatever white it last had.

## Consequences

- Natural Light writes each light's power-on white as the day goes, a write when it moved by 10 mired, about fifty a day
  for each light; the device then comes back in the right white by itself, however short the power cut.
- Natural Light being every light's that can have it, the bridge sets the lights' power-on behaviour the first time it
  runs with it: as they were, on or off (an Elgato Key Light always comes back on).
- The Elgato plugin's power-on settings (plugin-wide and per light) are legacy: the plugin no longer applies them and
  writes them out of its block.
