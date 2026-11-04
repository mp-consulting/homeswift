# Google Nest

Puts the Nest devices you share with your own Google Device Access project in HomeKit, through Google's Smart Device
Management (SDM) API: thermostats (and their fan), cameras, doorbells and the Nest Hub Max. Changes come from the
project's Cloud Pub/Sub subscription as they happen; nothing is polled.

**Status: experimental.** Written against Google's documentation and tested with fakes of Google's APIs only: it has not
run against a real Nest account yet.

## What it does

| Device | HomeKit |
|---|---|
| Thermostat | A Thermostat on the bridge: mode (Off, Heat, Cool, Auto as the thermostat offers them), current and target temperature, heating and cooling thresholds in Auto, humidity, display units, and the Homebridge plugin's **Eco** characteristic (Eve shows it) |
| Thermostat, with `showFan` | A Fan on the bridge as well, named "… Fan", which runs the fan timer for `fanDuration` seconds (900 by default) |
| Camera, Doorbell, Nest Hub Max (RTSP) | An accessory of its own: live view through FFmpeg, a snapshot of the latest event image (a neutral placeholder otherwise), a motion sensor (motion and person events, 20 seconds), the doorbell's ring, HomeKit Secure Video with audio |
| Camera, Doorbell (WebRTC, 2021 and later) | An accessory of its own: motion, the doorbell's ring, and a snapshot of the latest clip preview. **No live view nor HomeKit Secure Video** (see Gaps) |

Each accessory is named after its room ("Hallway Thermostat", "Front Door Doorbell"). Its id is
`homebridge-google-nest-sdm:<the device's resource name>` (`enterprises/<project>/devices/<id>`), the fan's the same
followed by ` Fan`, so a new Device Access project makes new accessories.

The thermostat follows Google's rules: the target temperature is set in Heat or Cool, the thresholds in Auto, nothing
with eco on (the Home app is refused rather than shown a value the thermostat does not have). Ranges follow the
thermostat's scale (10 to 32.2 °C in Fahrenheit, 9 to 32 °C in Celsius, from 4.5 °C in eco), and a change of scale, eco
or modes builds the accessory again under the same ids. A command Google refuses is "No Response" in the Home app.

## Setting up

You need what Google's [Device Access "Get started"](https://developers.google.com/nest/device-access/get-started)
guide makes:

1. Register for Device Access (a one-time fee) and create a project: its **project ID**.
2. In a Google Cloud project, enable the Smart Device Management and Cloud Pub/Sub APIs, and create an OAuth client of
   type **Web application** with `https://www.google.com` as an authorized redirect URI: its **client ID** and
   **client secret**. Publish the OAuth consent screen: in "Testing", Google's refresh tokens expire after 7 days.
3. Link the client to the Device Access project and turn on events with a Pub/Sub topic.
4. Create a **pull** subscription on that topic: its full name, `projects/<project>/subscriptions/<id>`, is the
   **subscription**.

Then, in the web UI, **Add accessories** → Google Nest asks for these, opens Google's Partner Connections Manager page
(with the `sdm.service` and `pubsub` scopes, as the Homebridge plugin's README describes), where you pick the homes and
devices to share, and asks for the address Google ends on (`https://www.google.com?code=…`). The bridge exchanges the code
for a refresh token and lists the devices once (Google starts sending events after a list). A device shared later needs
Setup again.

## Configuration

The block is homebridge-google-nest-sdm's, so a Homebridge block works as it is:

| Key | Meaning |
|---|---|
| `projectId`, `clientId`, `subscriptionId` | Written by Setup |
| `clientSecret`, `refreshToken` | Read from a Homebridge block, then moved into the bridge's vault (the client secret as the account's credentials, the refresh token in the plugin's sealed token file); Setup never writes them in config.json |
| `gcpProjectId` | The Google Cloud project, read but not needed: the subscription's name says it |
| `showFan`, `fanDuration` | The fan accessory and its timer (1 to 43200 seconds, 900 by default) |
| `vEncoder` | FFmpeg's video encoder and options for live views (`libx264 -preset ultrafast -tune zerolatency`); `copy` sends the camera's H.264 as it is. Recordings always use libx264 |
| `analyzeDuration`, `probeSize` | FFmpeg's `-analyzeduration` and `-probesize` for the camera streams |

`"true"` and numbers written as strings are read too.

Cameras need `ffmpeg` on the PATH. Live audio is AAC-ELD, from libfdk_aac (or AudioToolbox on macOS); without either the
live view has no sound. Recordings take AAC-LC, which FFmpeg's own encoder makes.

## Compared with the Homebridge plugin

Ids, names and options are the same. These differ, on purpose:

- Live views and recordings are extended (`ExtendRtspStream`) before Google's five minutes run out, and stopped when they
  end.
- Recordings keep their audio track (the Homebridge plugin's `-an` drops it).
- The fan timer sends a duration with ON only, 900 seconds when `fanDuration` is not set.
- A failed command reports No Response; it does not report success.
- Accessory Information has real values: Google Nest, the device type, the device id.
- The device list is retried with a back-off when it fails, the Pub/Sub subscription too; a rate limit (HTTP 429) is
  waited out; nothing logs the configuration, a token, a stream URL or an SRTP key.
- Trait events are merged field by field, so an event that carries one setpoint keeps the other.
- A device no longer shared leaves the bridge.

## Gaps

- **WebRTC cameras and doorbells** (the 2021 and later Nest Cam and Nest Doorbell) have no live view nor HomeKit Secure
  Video: it needs a WebRTC stack (ICE, DTLS-SRTP, SCTP), which Homeswift does not have. Their motion, doorbell and
  clip-preview snapshots work.
- Snapshots are the latest event image (less than 10 seconds old) or a placeholder: SDM has no snapshot, and a stream for
  one would spend the quota.
- Two-way audio.

## Quotas

Google allows 10 commands a minute per project and 5 a minute per thermostat. Thermostat sliders send one command per
drag; each live view and each recording costs a stream and its stop.

## How it was tested

`swift test --filter GoogleNestSDMTests` drives the plugin through a `PluginHost` against a fake of Google's OAuth, SDM and
Pub/Sub endpoints, with the specification's test vectors: the accessories of a device list, the thermostat's values and
ranges, the commands' bodies, trait and device events, image fetches, Setup's steps, and FFmpeg's command lines.

## References

- Google's [Device Access documentation](https://developers.google.com/nest/device-access): traits, commands, events,
  [Authorize an account](https://developers.google.com/nest/device-access/authorize),
  [Project limits](https://developers.google.com/nest/device-access/project/limits),
  [CameraLiveStream](https://developers.google.com/nest/device-access/traits/device/camera-live-stream),
  [CameraClipPreview](https://developers.google.com/nest/device-access/traits/device/camera-clip-preview).
- Google's [Cloud Pub/Sub REST API](https://cloud.google.com/pubsub/docs/reference/rest): `subscriptions.pull` and
  `subscriptions.acknowledge`.

## Clean-room implementation

Compatible with the configuration of [homebridge-google-nest-sdm](https://github.com/potmat/homebridge-google-nest-sdm)
by Ted Potma (its LICENSE names Andreas Bauer, the author of the template it started from; ISC). Written from the functional
specification in [docs/clean-room/GoogleNestSDM.md](../../docs/clean-room/GoogleNestSDM.md), without reading or copying its
code. The placeholder image is the plugin's own.

## Maintainer

Mickael Palma.
