# MQTT Thing

**Experimental**: written and tested against fakes, not yet against real devices.

Devices that speak MQTT, in HomeKit, each described by hand: per characteristic, the topic the device publishes its
state on (`get…`) and the topic the bridge sends commands to (`set…`), and how values are written. It is a
clean-room implementation compatible with the configuration of
[homebridge-mqttthing](https://github.com/arachnetech/homebridge-mqttthing), so its accessory blocks run unchanged.

Maintainer: Mickael Palma.

## Configuration

homebridge-mqttthing is an *accessory* plugin: each device is a block in config.json's top-level `accessories`, and
Homeswift runs those blocks here (docs/plugins.md, "Accessory plugins"):

```json
{
  "accessories": [
    { "accessory": "mqttthing", "type": "switch", "name": "Desk Lamp", "url": "mqtt://broker.local",
      "topics": { "getOn": "desk/lamp/state", "setOn": "desk/lamp/set" } },
    { "accessory": "mqttthing", "type": "temperatureSensor", "name": "Garden Sensor", "url": "mqtt://broker.local",
      "topics": { "getCurrentTemperature": "tele/garden/SENSOR$.AM2301.Temperature" } }
  ]
}
```

`"accessory": "homebridge-mqttthing.mqttthing"` works too, and so does a platform block that lists them:
`{ "platform": "mqttthing", "accessories": [ … ] }`. Every option of homebridge-mqttthing is read with its name: the
types (`airPressureSensor`, `airPurifier`, `airQualitySensor`, `battery`, `carbonDioxideSensor`, `carbonMonoxideSensor`,
`contactSensor`, `custom`, `dehumidifier`, `door`, `doorbell`, `fan`, `fanv2`, `garageDoorOpener`, `heaterCooler`,
`humiditySensor`, `irrigationSystem`, `leakSensor`, `lightbulb` and its `-RGB`, `-HSV`, `-White`… forms, `lightSensor`,
`lockMechanism`, `microphone`, `motionSensor`, `occupancySensor`, `outlet`, `securitySystem`, `smokeSensor`, `speaker`,
`statelessProgrammableSwitch`, `switch`, `television`, `temperatureSensor`, `thermostat`, `valve`, `weatherStation`,
`window`), the topics, `integerValue`/`onValue`/`offValue`/`otherValueOff`, the value lists (`…Values`), `restrict…`,
`turnOffAfterms`, `resetStateAfterms`, `confirmationPeriodms`/`retryLimit`, `getOnline`, `startPub`, `mqttPubOptions`,
`optimizePublishing`, `debounceRecvms`, JSONPath in get topics, the built-in `json` codec (`jsonCodec`), `history`
(Eve), Adaptive Lighting (`adaptiveLighting: false` turns it off) and the light options (`hex`, `hexPrefix`,
`warmWhite`, `coldWhite`, `noWhiteMix`, `switchWhites`, thresholds).

- **Identity.** An accessory's id is `mqttthing:<uuid_base or name>`, so renaming one without a `uuid_base` makes a new
  accessory, as in Homebridge. Two blocks with the same name: the second is left out, with a line in the log.
- **One connection per broker.** The blocks with the same `url`, user name, password and `mqttOptions` share one MQTT
  connection (homebridge-mqttthing opens one per block). It reconnects by itself with a backoff and resubscribes, so
  retained messages give the accessories their state again.
- **The broker's password** stays out of the schema: put it in the block's `password` (the runtime seals and masks it,
  and takes `vault:`, `env:` and `file:` references there), set `MQTTTHING_PASSWORD`, or run Setup (Add accessories, or the
  MCP `start_setup`), which asks for the broker's user name and password and keeps them in the vault for every block on
  that broker without its own.
- **A television** is published on a HAP server of its own (add it in the Home app like a second bridge).
- **TLS.** `mqtts://`, `tls://` and `wss://` check the broker's certificate against the system's roots, or `cafile`
  (or `ca`); `certfile`/`keyfile` give a client certificate.

## Differences

- **TLS certificates are checked by default.** homebridge-mqttthing checks none unless `rejectUnauthorized: true`;
  here a broker with a self-signed certificate needs its `cafile`, or `"rejectUnauthorized": false` (or
  `"insecure": true`) in `mqttOptions` to turn the check off.
- **One MQTT connection per broker** rather than one per accessory block (above).
- **A value that fails validation is not stored**, so a read answers the last valid one.

## What is left out

- **`apply` functions and JavaScript codecs.** They are JavaScript, which Homeswift does not run. A topic with an
  `apply` is left out (logged once per accessory, naming the topics); a `codec` other than `json` is ignored, with a
  line in the log, and the accessory runs without it. The built-in `shellyAMAX` codec is not ported. Most `apply` uses
  have a declarative replacement: JSONPath in the topic (`tele/sensor/SENSOR$.AM2301.Temperature`), the `json` codec,
  or value lists.
- `historyOptions.persistencePath`: histories and counters are kept in the plugin's own directory.
- `caption` is read and ignored, as homebridge-mqttthing does.
- MQTT wildcards in topics are subscribed as given, but their messages reach no characteristic (as in
  homebridge-mqttthing).

Where homebridge-mqttthing has a bug the specification lists, this plugin does what was meant: On follows the
brightness of HSV and RGB lights without `setOn`; `carbonMonoxideSensor` reads `getCarbonMonoxideLevel` and
`getCarbonMonoxidePeakLevel`; `restrictDehumidifierState` restricts the target state; `fanv2` has CurrentFanState when
`topics.getCurrentFanState` is set; an irrigation zone's StatusFault follows the zone's own topic.

## How it was tested

The plugin's tests (`Plugins/MQTTThing/Tests`) run every vector of the specification on a host with a fake broker
(`FakeMQTTConnection`): the encodings, JSONPath, the colour conversions (HSV, RGB, RGBW, RGBWW, white), confirmation and
retries, auto-off, the garage door's derived state, the valve's timer, the energy counter, the json codec, a custom
accessory, the television on its own server, Setup. It has not been run against real devices or a real broker yet.

## Clean-room implementation

Compatible with the configuration of homebridge-mqttthing by David Miller (arachnetech) and contributors (Apache
License 2.0). Written from the functional specification in
[docs/clean-room/MQTTThing.md](../../docs/clean-room/MQTTThing.md), without reading or copying its code. The Eve
characteristics' UUIDs and properties are those the specification gives (from homebridge-lib by Erik Baauw, Apache 2.0).
