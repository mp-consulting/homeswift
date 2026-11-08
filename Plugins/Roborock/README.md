# Roborock

Roborock robot vacuums in HomeKit. Each robot is an accessory with:

- a **Fan** (the primary service) whose Active starts a clean, and stops it and sends the robot to its dock when turned
  off; it is on while the robot cleans, returns or washes its mop, with Status Fault on a robot error and Status Active
  while the robot answers. It stands for a cleaning robot, so the bridge's Matter bridge shows it as a Robotic Vacuum
  Cleaner (start, stop, pause and go home; its battery from the Battery). Its **Rotation Speed** is the suction: the
  robot's levels, weakest first (Gentle where the robot has it, Quiet, Balanced, Turbo, Max, Max+), spread over 0–100 %;
  Custom and Smart show as the level they were last, until the robot reports a level again;
- **Mop**, a switch, on robots with a water box: on mops with the robot's usual water flow (Medium, or the middle of a
  water slide), off vacuums only;
- its **Battery**: level, low below 20 %, charging (an off-peak robot waiting on its dock is not charging);
- **Start Mop Washing**, a switch, on docks that wash the mop: on while the dock washes, also for washes started
  elsewhere;
- a switch for each **scene** of the Roborock app that uses the robot: momentary, it runs the scene on the LAN when every
  step can, else asks the cloud to;
- **Filter**, **Main brush** and **Side brush** as Filter Maintenance: the life left (from the robot's work times and
  the rated 150, 300 and 200 hours), and Change Filter at 5 % or less.

**Identify** (in the Home app's accessory settings) makes the robot say where it is. The names of the mop-washing and
mop switches and of the brushes and filter follow `language`.

## Clean modes, rooms and errors

HomeKit has no service for a room or a mop route, so these are actions of the plugin, for the MCP server, the Assistant
and the web UI's chat (`list_robots`, `list_rooms`, `clean_rooms`, `set_clean_mode`, `find_robot`, `clear_error`):

- **Suction, water and route** by name or code, from those the robot offers: its family (the model) and its feature
  flags decide (Max+, mopping without suction, Smart, a water slide, the deep and fast routes), as the Roborock app does.
- **Rooms** of the current map: the robot's segments, named from the Roborock app's rooms (a room without a name is
  "Room 17"); `clean_rooms` cleans them by name, one to three passes.
- **Errors** with their meaning, the robot's and the dock's; `clear_error` clears the dock's first, then the robot's,
  once the cause is fixed (some dock errors, an empty water tank, stay until cleared).

These follow [RoborockModes.md](../../docs/clean-room/RoborockModes.md), a clean-room specification written from
homebridge-roborock-vacuum (MIT) and python-roborock (Apache-2.0); no code was copied. Renaming a switch in the Home app
keeps the name; a scene renamed in the Roborock app renames its switch unless you renamed it.

## How it reaches the robots

The account signs in to the Roborock cloud, which gives the robots, their local keys, rooms and scenes (every 3
minutes). Each robot is then reached on the LAN, TCP port 58867, found by its UDP announcements (port 58866), the cloud's
`get_network_info` or its last address; protocols 1.0 and L01 (with its handshake, and the probe for robots that report
1.0 and answer L01). When the LAN does not answer, the request goes through the account's MQTT broker. A robot shared
with the account by another one is reached through the cloud only. The robots push their state through the cloud;
the plugin also asks each robot for its status every 3 minutes, every 15 seconds while it cleans, and for its
consumables every 3 minutes. A method that times out three times in a row rests for 30 minutes, a robot that does not
answer on the LAN three times is asked through the cloud for 5 minutes, and a connection that fails waits from one
minute up to ten between attempts.

Without the cloud at start (no internet), the plugin starts from the home data it kept and works on the LAN; it comes
back to the cloud on its own.

## Setting it up

Add the plugin, then sign in from **Add accessories**: the email of your Roborock app account and, optionally, its
password. Without a password Roborock emails a code; with one, an account that asks for two-factor authentication gets
the emailed code as the next step. The session goes in the bridge's vault, the password (when given) in the instance's
credentials; the block keeps only the email (and the region found, as `baseURL`).

```json
{
  "platform": "RoborockVacuumPlatform",
  "name": "Roborock Vacuum",
  "email": "user@example.com",
  "language": "en"
}
```

| Option | Default | |
|---|---|---|
| `email` | required | Your Roborock app account. |
| `password` | none | Read from a Homebridge block (and sealed in the vault by the bridge); Setup keeps it in the vault. Optional once signed in. |
| `encryptedToken` | none | The Homebridge settings page's sealed session. It opens only with that plugin's `roborock.token.key`: copy that file into the plugin's folder (`plugins/RoborockVacuumPlatform-<name>/`), or sign in again from Add accessories. |
| `baseURL` | found from the email | `https://usiot.roborock.com`, `https://euiot.roborock.com`, `https://cniot.roborock.com` or `https://api.roborock.com`. |
| `language` | `en` | `en de es fr it nl pl pt ru uk zh-cn zh-tw`: the names of the switch and the consumables. |
| `skipDevices` | none | Robots (by duid) to leave out: moved into their Accessory Settings as Excluded on the next settings write. |
| `matterDevices` | none | Published over HomeKit here; the bridge's Matter bridge shows them to other ecosystems. `matterSceneDevices` is ignored. |
| `debugMode` | `false` | Debug lines (requests, transports); never a key, a token or a session. |
| `currentRoomMqtt` | off | Read, not implemented yet (see Gaps). |
| `ignoredDevices` | none | Legacy: robots (by duid or serial number) shown but not polled. |

The files the Homebridge plugin keeps (`roborock.clientID`, `roborock.UserData`, `roborock.HomeData`, `roborock.HomeId`,
`roborock.LocalDevices`, `roborock.Scenes`) are read under the same names in the plugin's folder; the session and the
home data (which holds the local keys) move into the vault the first time they are read.

## Experimental

Untested on hardware: written and tested against fakes only. Known gaps:

- **A01 and B01 robots** get the framing and the ciphers as described, but no status polling (as the Homebridge plugin);
  their state comes from the home data and the cloud's pushes. Untested.
- **Shared robots** (`receivedDevices`) are controlled through the cloud with the owner's local key; the Homebridge
  plugin shows them without controlling them. Whether the cloud accepts it is not known.
- **The current room to MQTT** (`currentRoomMqtt`) is not implemented; the block's option is read and ignored.
- The Homebridge plugin's optional polls (carpet, dust collection, dryer settings) change nothing HomeKit shows and are
  not sent.
- **Rooms over Matter** (the ServiceArea cluster) and **switching floors** (`load_multi_map`) are not done: the Matter
  bridge has no ServiceArea server yet, and rooms are cleaned on the map the robot has loaded. Floors' rooms are listed
  only for the loaded map.
- Older robots' percentage suction codes (38, 60, 75…) are shown as "Level n" and never written: no source says which
  robots use them. There the fan's Active is the robot's state: it shows running while the robot returns or
  washes its mop, and Pause, like Stop, sends it to its dock.
- An L01 robot reached through the cloud needs the nonces of a LAN handshake; without a LAN connection its cloud
  requests fail.

## Maintainer

Mickael Palma. Tested with the plugin's own tests (fakes for the cloud, the robots' local port and the MQTT broker, and
the specification's byte vectors for every frame, cipher and signature) and on a throwaway bridge without robots. Not
yet tested with a real robot: reports are welcome.

## Clean-room implementation

Compatible with the configuration of [homebridge-roborock-vacuum](https://github.com/tasict/homebridge-roborock-vacuum)
by tasict and Nico Hartung (MIT), itself adapted from ioBroker.roborock by copystring. Written from the functional
specification in [docs/clean-room/Roborock.md](../../docs/clean-room/Roborock.md), without reading or copying its code.
