# Ring

**Experimental**: written from a functional specification and tested against fakes only, not yet on Ring hardware.

Ring's devices in HomeKit, from Ring's cloud:

- **Alarm** (base station, keypad, contact, motion, flood/freeze, smoke and CO sensors, locks, thermostats, Z-Wave
  switches, outlets, dimmers, fans, water valves) over each location's WebSocket, live. The Security System arms Away,
  Home and, with `nightModeBypassFor`, Night (bypassing open contact sensors). Optional Panic Buttons dispatch real
  burglar and fire alarms to Ring's monitoring.
- **Smart Lighting** lights, dimmers, transformers, light groups and their motion sensors, through the lighting bridge.
- **Cameras and doorbells**, each an accessory of its own (add it in the Home app like a bridge, with the bridge's
  setup code): snapshots, motion and rings (by push), the camera's light, siren and the doorbell's in-home chime switch,
  its battery. **Live video is not available**: Ring streams only over WebRTC, which Homeswift does not have yet, so a
  live view in the Home app shows No Response. Snapshots and notifications with their picture work.
- **Chimes** (snooze, volume, play ding or motion, nightlight), **intercoms** (unlock, ding) and, for locations with
  cameras but no alarm, the **Location Mode** (Ring Modes) as a Security System.

Dings and motion arrive by push: the plugin registers as an FCM web-push client of Ring's Android app project
(`HomeswiftNetwork`'s `FCMReceiver`) and keeps a connection to `mtalk.google.com` on TCP port 5228 open; a firewall or a
DNS ad blocker that stops it stops the events. Cameras and chimes are read every `cameraStatusPollingSeconds`.

## Setup

On **Add accessories**, pick Ring and sign in with the Ring account's email and password, then the code Ring sends
(or your authenticator app's). The email and password are not kept; the vault keeps the refresh token Ring answers
(Ring rotates it on each use, and each new one is stored at once) and the hardware id Ring lists this bridge under in
its Control Center. A Homebridge block's `refreshToken` works as it is: it is read once, moved into the vault, and
removed from the block with the next settings write. Push credentials are kept in the vault too (`ring-push.json`).

## Configuration

The block of [homebridge-ring](https://github.com/dgreif/ring) works unchanged:

```json
{
  "platform": "Ring",
  "nightModeBypassFor": "all",
  "showPanicButtons": false,
  "cameraStatusPollingSeconds": 20,
  "hideDeviceIds": []
}
```

| Option | Default | Meaning |
|---|---|---|
| `refreshToken` | | The Homebridge plugin's token: moved into the vault (Setup replaces it) |
| `alarmOnEntryDelay` | false | The entry delay counts as triggered |
| `nightModeBypassFor` | | `all` or `some`: Night arms Away or Home, bypassing open contact sensors |
| `showPanicButtons` | false | Burglar Alarm and Fire Alarm switches that dispatch real emergencies |
| `hideAlarmSirenSwitch`, `hideLightGroups`, `hideDoorbellSwitch`, `hideInHomeDoorbellSwitch`, `hideCameraLight`, `hideCameraMotionSensor`, `hideCameraSirenSwitch` | false | Leave those out |
| `beamDurationSeconds` | | How long a Smart Lighting light stays on (1…32767); groups use 60 |
| `avoidSnapshotBatteryDrain` | false | A battery camera's snapshot is kept 10 minutes, not 10 seconds |
| `cameraStatusPollingSeconds` | 20 | Cameras, chimes, intercoms; 0 turns polling off |
| `locationModePollingSeconds` | 20 | Location Mode; 0 hides it |
| `hideDeviceIds` | [] | Homebridge UUIDs of accessories to leave out (Excluded in each accessory's settings from the next settings write) |
| `locationIds`, `onlyDeviceTypes` | all | Only these locations, these device types |
| `controlCenterDisplayName` | `homebridge-ring` | The name Ring's Control Center shows |

`ffmpegPath`, `debug` and `disableLogs` are read and unused. Accessory ids are `Ring:` and the Homebridge plugin's
identity seeds (`<camera id>camera`, the chime's or intercom's id, a hub device's zid, `<panel zid>panic`,
`<location id>mode`).

The panic switches, the Security System's target and the locks are security controls: the MCP server and the
Assistant change them only after you confirm.

## Not done

- Live video and two-way audio (WebRTC with trickle ICE, DTLS-SRTP, Opus): the cameras advertise streams so the Home app
  shows them, but a stream request is refused. `HomeswiftWebRTC` now has ICE, DTLS-SRTP and SRTP; the plugin's
  signalling to Ring is what is left.
- Hub devices that appear after start-up show at the next restart.

## How it was tested

Tests with fakes only (`Tests/`): the specification's identity vectors (Homebridge UUIDs, the hardware id, the token
wrapper), OAuth with 2FA and rotation, the lazy session, the location socket's frames (lists, updates, the alarm mode
with bypass, a dimmer's debounced level), pushes (ding, motion and their snapshots, an intercom unlock), snapshots, Setup
and the settings. `HomeswiftNetworkTests/FCMReceiverTests` checks the FCM receiver against the vectors of
docs/clean-room/FCMReceiver.md (check-in, login frame, framing split at every byte, aesgcm decryption).

## Clean-room implementation

Compatible with the configuration of [homebridge-ring](https://github.com/dgreif/ring) by Dusty Greif (MIT), and of the
push behaviour of [@eneris/push-receiver](https://github.com/Eneris/push-receiver) by Eneris and Matthieu Lemoine (MIT).
Written from the functional specifications in [docs/clean-room/Ring.md](../../docs/clean-room/Ring.md) and
[docs/clean-room/FCMReceiver.md](../../docs/clean-room/FCMReceiver.md), without reading or copying their code. The web
push decryption follows the public IETF drafts (draft-ietf-webpush-encryption-03,
draft-ietf-httpbis-encryption-encoding-03). Ring's Firebase identifiers in `RingPush.swift` are the public ones of
Ring's Android app.

Maintainer: Mickael Palma.
