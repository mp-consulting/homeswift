# Weather

The weather where the home is, from [Open-Meteo](https://open-meteo.com): free, with no account and no key. It reads
the **Location**, a Bridge Setting set under Settings, Bridge (GLOSSARY.md), and asks every 15 minutes, which is how
often Open-Meteo's current conditions change. When the Location moves it asks again at once.

Homeswift wrote it; it is not a port. homebridge-weather-plus does more (forecasts, several weather services) and its
blocks don't load here.

**Status:** experimental.

## In HomeKit

One accessory, **Weather** (`Weather:home`), with:

- **Temperature sensor** (primary): Current Temperature, plus Eve's weather characteristics: Air Pressure (hPa, at sea
  level), Condition (Open-Meteo's weather code in words: "Partly cloudy", "Rain showers"), Wind Speed (km/h), Rain
  Last Hour (mm) and UV Index. The Home app shows the temperature; Eve shows all of them.
- **Humidity sensor**: Current Relative Humidity.
- **Is raining**, an occupancy sensor. It is detected while rain or showers are falling, or while the weather code is
  drizzle, rain or a thunderstorm (snow does not count), so an automation can close the skylight or skip the
  sprinklers.

On the web UI's Accessories wall it is a **Weather** widget, large by default. A compact tile shows the temperature
and the condition, and a tall one shows the temperature big with the sky's icon. A large tile adds the humidity and
the wind; an extra large one adds the last hour's rain, the pressure and the UV index.

Without a Location the accessory answers No Response and the log says so once. When Open-Meteo or the network is down
the accessory also answers No Response, and the plugin asks again 5 minutes later.

## Setting it up

On **Add accessories**, add Weather. Its one device, the weather at home, is set up once there is a Location. Until
then it **Needs setup** (a Bridge Setting): its step links to the Location under Settings, Bridge, in a tab of its
own, and goes on by itself as soon as the Location is set.

```json
{
  "platforms": [
    {
      "platform": "Weather",
      "name": "Weather"
    }
  ]
}
```

| Option | Default | |
|---|---|---|
| `server` | open-meteo.com | A self-hosted [Open-Meteo](https://github.com/open-meteo/open-meteo), such as `http://192.168.1.5:8080` |

Its Name, room and Excluded are its Accessory Settings, as for any accessory.

## Privacy

Every 15 minutes the request to `api.open-meteo.com` (or the `server` set) carries the Location's coordinates, rounded to two decimals
(about a kilometre), and nothing else. The Location's name never leaves the bridge. Weather data comes from
Open-Meteo.com under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Tests

`WeatherTests` runs the plugin against a fake Open-Meteo, with no network. The transport is tested on Open-Meteo's
answer format, covering rain, showers, thunderstorms, snow and refusals.
