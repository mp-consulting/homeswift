# Dolphin Pool Cleaner

Maytronics Dolphin pool robots in HomeKit through the MyDolphin Plus cloud: a switch that starts and stops
cleaning in the mode you choose, the water temperature, and the filter bag as a filter indicator. Siri
works with the switch ("Hey Siri, turn on the pool robot").

A port of [`@mp-consulting/homebridge-dolphin-pool-cleaner`](https://github.com/mp-consulting/homebridge-dolphin-pool-cleaner).
The platform block is the same, so a Homebridge configuration works unchanged, refresh token included.

Robots that use the **MyDolphin Plus** app and are connected to its cloud: M400, M600, M700, S200 to S400,
E50 to E70, Liberty 300 and 400, Sigma.

## Setting up

With the web UI on, the Plugins page has an **Open** button for this plugin. Its page is the Homebridge
plugin's setup wizard:

1. Enter your MyDolphin Plus email. Cognito sends a verification code (by email, SMS or an authenticator app,
   whichever your account uses).
2. Enter the code. The page shows the robot it found (picture, serial number, model, connection type).
3. Choose its name, default cleaning mode, polling interval, and whether the temperature sensor and the filter
   indicator appear, then **Save Configuration**. The block gets your email, the region and a **refresh token**
   (never your password), and the plugin reloads with it at once.

Afterwards the page lists the configured robots with their live state (cleaning or idle, filter, time left,
faults) and opens a robot's settings when you click its card; **Reconfigure** signs in again, for instance
after "Refresh token expired" in the log. With the Assistant on, **Explain** sits next to errors; it never
receives the email address, codes, tokens or serial numbers.

## Configuration

```json
{
  "platforms": [
    {
      "platform": "DolphinPoolCleaner",
      "name": "Dolphin Pool Cleaner",
      "email": "your@email.com",
      "refreshToken": "eyJjdHkiOiJKV1Qi…",
      "pollingInterval": 60,
      "devices": [
        {
          "serialNumber": "ABC123XYZ",
          "name": "Pool Robot",
          "cleaningMode": "all",
          "enableTemperature": true,
          "enableFilterStatus": true
        }
      ]
    }
  ]
}
```

| Option | Default | What it does |
|---|---|---|
| `email` | | MyDolphin Plus account email |
| `password` | | Used only without a `refreshToken`; the setup page never stores it |
| `refreshToken` | | Saved by the setup page; preferred over the password |
| `iotRegion` | `eu-west-1` | AWS IoT region of the robot (production robots are all in eu-west-1) |
| `pollingInterval` | `60` | Seconds between status polls, 30 at least (the schema allows up to 600) |

Either `refreshToken` or `email` and `password` is required; without them the plugin logs it and waits for
the setup page. Per robot, under `devices`:

| Option | Default | What it does |
|---|---|---|
| `serialNumber` | | The robot's serial number, on the power supply's label |
| `name` | the robot's name in the app | The name of the switch and sensors in HomeKit |
| `cleaningMode` | `all` | The mode a start from HomeKit uses (`regular` is an alias of `all`) |
| `enableTemperature` | `true` | The water temperature sensor |
| `enableFilterStatus` | `true` | The filter maintenance indicator |
| `deviceType`, `robotImageUrl` | | Saved by the setup page for display; the plugin reads both from the account |

Cleaning modes: `all` (all surfaces), `short` (fast), `floor`, `wall`, `water` (waterline), `ultra`, `cove`,
`spot`, and on robots that have them `tictac`, `pickup`, `custom`, `stairs`. The mode is sent only when the
robot does not already have it queued.

## In the Home app

| Service | What it shows |
|---|---|
| Switch | On while the robot cleans; on starts a cycle in the configured mode, off stops it |
| Temperature Sensor | The pool water, on models with a sensor, while the robot is in the water; the last reading is kept |
| Filter Maintenance | "Change filter" when the filter bag is over 80 % full |

As in the Homebridge plugin, the device catalog lists no model with a temperature sensor (not all M400/M600
have one), so the sensor does not appear today. A switch change shows at once; for 15 seconds after a
command, switch updates from the robot are ignored while it updates its shadow, and temperature and filter
updates still come through. A command the cloud does not accept puts the switch back.

## How it works

1. **Sign-in**: AWS Cognito (user pool client of the app, region us-west-2) as JSON over HTTPS with
   `X-Amz-Target`: `REFRESH_TOKEN_AUTH` with the stored token, else `USER_PASSWORD_AUTH`; the setup page uses
   `CUSTOM_AUTH` and `RespondToAuthChallenge`. No SRP: the app client allows these flows.
2. **Robot and credentials**: MyDolphin's `authenticate-user` returns the serial number, name and connection
   type; `getToken` returns temporary AWS credentials, renewed an hour before they expire.
3. **State and commands**: MQTT over a SigV4-presigned WebSocket to AWS IoT (client id `<serial[0..8]>_App_Token`),
   the robot's thing shadow: `shadow/get` to read it, `shadow/update` with a desired `systemState.pwsState`
   (`on`/`off`) or `cleaningMode.mode` to command it. Shadows the robot pushes update HomeKit at once; a poll
   runs only when nothing arrived for a whole interval.

The MyDolphin AWS account is shared by every user and throttles shadow requests (429): requests are spaced a
second apart, retried with backoff (three times for a poll, twice for a command), and throttling is logged at
most every ten minutes. Responses are matched to requests by `clientToken`, so the phone app's traffic on the
same robot is ignored. Discovery retries with backoff (30 s doubling to 10 min) when the cloud is unreachable
at startup, but not when the credentials are rejected. Sign-in and the MQTT connection are shared by
concurrent callers, since AWS IoT drops a connection when another opens with the same client id.

The accessory id is `DolphinPoolCleaner:<serial number>`. The plugin's own files, in its storage directory, are
`last-temperatures.json` and the robots' pictures (`robot-image-<serial>.json`), which the page shows because
the UI's pages load images from their own origin only.

## Differences from the Homebridge plugin

- A command the cloud refuses fails the HomeKit write (the Home app shows it) instead of being accepted and
  flipped back.
- The setup page keeps the Cognito session on the server and sends the browser only the refresh token; it
  includes the robot's model.
- The configured robots' cards show their live state.
- The `/ai/*` Assistant routes are the runtime's (`HomeswiftAiKit`), not the plugin's.
- MQTT, the WebSocket and SigV4 presigning are HomeswiftNetwork's (`MQTTClient`, `AWSSignatureV4`), shared with
  other plugins; `ShadowClient` uses them directly. A dropped connection is retried every 5 seconds, 5 times, as
  mqtt.js was configured, then the next request opens a new one.
- Redirects are followed as `fetch` follows them (MyDolphin answers the sign-in with a 307 at times):
  `HomeswiftNetwork`'s `HTTPClient` does not follow them, so the plugin does.
- Stopping the plugin during the sign-in (a configuration change restarts it) leaves no MQTT connection
  behind to fight the next instance for the client id: a sign-in in progress ends without connecting.
- A `pollingInterval` above 2147483 seconds (Node's longest timer, about 24.8 days) is that maximum; in
  Homebridge the timer then fires every millisecond.
- The Assistant (the web UI's chat, MCP clients) can read the robots and their state (`list_robots`). It does
  not run the page's sign-in, whose code is mailed to the user.
