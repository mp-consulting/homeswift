# MQTTThing: functional specification

## 0. Provenance

| | |
|---|---|
| Source | https://github.com/arachnetech/homebridge-mqttthing (npm package `homebridge-mqttthing`) |
| Commit read | `31a0c46ec37640b80217c30a8e54ebdd322a0786` (package version 1.1.50) |
| Licence | Apache License 2.0 (`LICENSE` is the stock Apache text with the copyright placeholder unfilled; `package.json` names the author as David Miller). The bundled `codecs/shellyAMAX.js` carries its own notice: "(c) Ferme de Pommerieux, License: Apache 2.0", based on a codec by J.D. Smith. |
| Copyright holders | David Miller (arachnetech) and contributors; Ferme de Pommerieux for the ShellyAMAX codec |
| Also consulted, for facts only | `homebridge-lib` (https://github.com/ebaauw/homebridge-lib, commit `315077c2141e13412472f5f27eecc866daed7d3c`, Apache 2.0) for the UUIDs and properties of the Eve characteristics and services MQTTThing uses |
| Files read | `index.js`, `libs/mqttlib.js`, `codecs/json.js`, `codecs/shellyAMAX.js`, `config.schema.json`, `docs/Configuration.md`, `docs/Accessories.md`, `docs/Codecs.md`, `docs/ReleaseNotes.md`, `test/*.js` |

This document was written by the spec writer and contains no source code. Interface identifiers (JSON keys, type names, topic keys, property names, UUIDs) are reproduced because they are the interface; everything else is a description in my own words.

Behaviour that belongs to the Homebridge host or to HAP-NodeJS, not to the plugin, is marked **[host]**.

---

## 1. What it is

MQTTThing exposes devices that speak MQTT as HomeKit accessories. Each accessory is configured by hand: the user names, per HomeKit characteristic, the MQTT topic the device publishes its state on (a `get…` topic) and the topic the bridge publishes commands to (a `set…` topic), plus how values are encoded. There is no discovery, no cloud, no pairing with a device: the only network peer is an MQTT broker.

It is an **accessory plugin**, not a platform:

- It registers the accessory identifier `mqttthing` under the plugin name `homebridge-mqttthing`.
- Each device is one object in config.json's top-level **`accessories`** array, with `"accessory": "mqttthing"` (Homebridge also accepts the qualified form `"accessory": "homebridge-mqttthing.mqttthing"` **[host]**).
- `config.schema.json` declares `pluginAlias: "mqttthing"`, `pluginType: "accessory"`.
- Every accessory block opens **its own MQTT connection** (one client per block, even when several blocks point at the same broker).
- A block may contain several HomeKit services (`"type": "custom"` with a `services` array, section 5.33), but it is always one HomeKit accessory.

---

## 2. Identity (stable ids)

### 2.1 Accessory identity **[host]**

Homebridge derives a bridged accessory plugin's UUID from the string `<accessory>:<seed>` where `<accessory>` is the block's `accessory` value exactly as written (normally `mqttthing`) and `<seed>` is the block's `uuid_base` if present, otherwise its `name`. The UUID is HAP-NodeJS's `uuid.generate` of that string: the SHA-1 digest of the UTF-8 bytes, written as hex; the UUID template `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` is filled left to right, each `x` taking the next hex digit of the digest and each `y` taking the next digit `d` replaced by `(d AND 3) OR 8`; the literal `4` and the dashes consume nothing; the result is uppercase.

Vectors (computed by me under that rule):

| Seed string | SHA-1 hex | UUID |
|---|---|---|
| `mqttthing:Desk Lamp` | `fdd48a1590fd9262ce92d8b32f413a4c20192755` | `FDD48A15-90FD-4926-ACE9-2D8B32F413A4` |
| `mqttthing:Garden Sensor` | `88340eacad4a1fa889919ea18b3e71d4446026a1` | `88340EAC-AD4A-41FA-8899-19EA18B3E71D` |

Consequences an implementer must keep:

- The identity seed is the **name** (or `uuid_base`). `serialNumber`, topics, URL and type play no part. Renaming an accessory changes its identity unless `uuid_base` is set.
- Two blocks with the same `name` (and no `uuid_base`) collide **[host]**.

Homeswift's own ids are platform-prefixed strings rather than HAP UUIDs; the seed above (`accessory` + `uuid_base`-or-`name`) is the information available for a stable id. A migration from Homebridge is a new bridge pairing anyway, so what HomeKit rooms and automations depend on after migration is that the id, the service types and the service subtypes stay the same from one start to the next.

### 2.2 Service subtypes

Characteristics are found by service type plus subtype, so the subtypes are part of the identity. In a single (non-custom) block, the primary service's subtype is the block's `subtype` key, which is normally absent. The subtypes each type uses are listed in section 5. In summary:

| Service | Display name | Subtype |
|---|---|---|
| Primary service of every type | `name` (or a `serviceNames` override where noted) | `subtype` config key (normally none) |
| Secondary services of `weatherStation`, `airQualitySensor`, `doorbell` (motion), `airPurifier` (filter) | see type | same as primary (`subtype` key) |
| `statelessProgrammableSwitch` with an array of topics: ServiceLabel | `name` | none |
| … each button | `<name> <i>` (i counted from 0, a single space) | the number `i+1` |
| `television`: TelevisionSpeaker | `Volume` | `volumeService` |
| … each InputSource | input's `name`, or `Input <n>` | the number `n` (1-based) |
| `irrigationSystem`: ServiceLabel | none | none |
| … each zone Valve | zone's `name`, or empty | the number `n` (1-based) |
| Battery (added automatically, section 5.35) | `<name>-battery` | none |
| Eve history service (`history: true`) | handled by fakegato-history | see section 7 |
| Custom accessory's services | service's `name` | the service's `subtype`, defaulting to its `name` |

Numeric subtypes become their decimal string when used as a key **[host]**.

### 2.3 Accessory Information

| Characteristic | Value |
|---|---|
| Manufacturer | `manufacturer`, default `mqttthing` |
| Model | `model`, default the block's `type` string exactly as written (so `lightbulb-RGB`, or `custom`) |
| SerialNumber | `serialNumber`, default `<host name of the machine>-<name>` (a hyphen between) |
| FirmwareRevision | `firmwareRevision`, default the plugin version (`1.1.50` at this commit) |
| Name | the accessory `name` **[host]** |

The docs advise against `/` in these values because the Eve history file names are built from them.

---

## 3. Configuration interface

### 3.1 Block-level keys (all types)

All keys are optional unless marked. "Truthy" means present and not `false`, `0`, `""` or `null`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `accessory` | string | required | `mqttthing` |
| `type` | string | required | Accessory type (section 5). Everything from the first `-` on is ignored (`lightbulb-RGB` behaves as `lightbulb`), except for `irrigationSystem`, which must be written exactly. |
| `name` | string | required | Accessory and primary service name; identity seed; MQTT client id ingredient |
| `uuid_base` | string | none | **[host]** Identity seed instead of `name` |
| `_bridge` | object | none | **[host]** Child bridge; not read by the plugin |
| `caption` | string | none | Listed in the docs as a label; **not read by the plugin**. Accept and ignore. |
| `subtype` | string | none | Subtype of the primary service (also used by secondary services of the same block) |
| `serviceNames` | object | `{}` | Names for secondary services: keys `temperature`, `humidity`, `airPressure`, `ambientLightLevel`, `weather`, `motion`, `airQuality`, `filter` (which apply to which type is in section 5) |
| `nameOverride` | string | none | If set, the primary service gets a ConfiguredName characteristic with this value |
| `url` | string | env `MQTTTHING_URL`, else the MQTT library default (`mqtt://localhost:1883`) | Broker URL; schemes `mqtt`, `mqtts`, `tcp`, `tls`, `ws`, `wss`. If the string contains no `://`, `mqtt://` is put in front. |
| `username` | string | env `MQTTTHING_USERNAME` | Broker user. The config value wins when it is truthy. |
| `password` | string | env `MQTTTHING_PASSWORD` | Broker password. **Secret.** |
| `mqttOptions` | object | `{}` | Options for the MQTT client, merged with the defaults (section 4.1); a key given here wins. Also `cafile`, `certfile`, `keyfile` (paths read into the TLS CA, certificate and key) and `insecure` (true: skip the server name check). |
| `mqttPubOptions` | object | none | Options for every publish, e.g. `{ "retain": true, "qos": 1 }` |
| `logMqtt` | bool | false | Log the connection settings, every message received and published, and decoding steps |
| `debounceRecvms` | int (ms) | none | Delay each received message before it takes effect; a new message on the same subscription restarts the delay, so only the last one in a burst counts |
| `optimizePublishing` | bool | false | Do not publish a payload on a topic if it is identical to the last payload published on that topic |
| `topics` | object | required (see note) | The topic keys of section 5. Each value is a topic string, a topic object (section 3.3), or, for `getSwitch` only, an array of them. A missing `topics` object makes service creation fail for every type except `irrigationSystem`. |
| `integerValue` | bool | false | Booleans as `1`/`0` instead of `true`/`false` (section 3.4) |
| `onValue`, `offValue` | string (any JSON scalar accepted) | none | Explicit boolean encodings (section 3.4) |
| `otherValueOff` | bool | false | Treat any received value other than the on value as off |
| `onlineValue`, `offlineValue` | string | the boolean on/off values | Values on `getOnline` (section 6.5). The schema's UI default is `""`. |
| `chargingStateValues` | array | `["NOT_CHARGING","CHARGING","NOT_CHARGEABLE"]` | Battery ChargingState values |
| `startPub` | array of `{topic, message}`, or (old form) an object mapping topic to message | none | Published once at start-up (section 6.6) |
| `confirmationPeriodms` | int (ms) | none (off) | Turns on confirmation of `setOn` (section 6.1) |
| `retryLimit` | int | 3 | Republishes when unconfirmed |
| `confirmationIndicateOffline` | bool | unset | Whether an unconfirmed publish marks the accessory offline (section 6.1) |
| `validate` | bool | true | `false` turns off value validation (section 6.4) |
| `codec` | string | none | A codec (section 8) |
| `jsonCodec` | object | none | Configuration of the built-in `json` codec (section 8.3) |
| `history` | bool, or object (old form, treated as `historyOptions` with history on) | false | Eve history (section 7) |
| `historyOptions` | object | `{}` | `size` (default 4032), `noAutoTimer`, `noAutoRepeat`, `mergeInterval` (minutes, motion only), `persistencePath`; the old names `autoTimer: false` and `autoRepeat: false` mean `noAutoTimer: true` and `noAutoRepeat: true` |
| `manufacturer`, `model`, `serialNumber`, `firmwareRevision` | string | section 2.3 | Accessory Information |
| `turnOffAfterms` | int (ms) | none | Auto-off for On and Active; for `motionSensor` it is the reset delay instead (section 6.3) |
| `resetStateAfterms` | int (ms) | none | Reset a received "on" state to off after this delay (section 6.3) |
| `adaptiveLighting` | bool | true | `false` disables Adaptive Lighting on lightbulbs |
| `services` | array | none | Only with `type: "custom"` (section 5.33) |

Type-specific keys are listed with each type in section 5.

### 3.2 Topic keys

The full set of topic keys the plugin reads (case matters):

`getActive getActiveInput getAirPressure getAirQuality getAirQualityPPM getAltSensorState getAmperes getBatteryLevel getBrightness getCarbonDioxideDetected getCarbonDioxideLevel getCarbonDioxidePeakLevel getCarbonMonoxideDetected getCarbonMonoxideLevel getCarbonMonoxidePeakLevel getChargingState getColorTemperature getContactSensorState getCoolingThresholdTemperature getCurrentAirPurifierState getCurrentAmbientLightLevel getCurrentDoorState getCurrentFanState getCurrentHeaterCoolerState getCurrentHeatingCoolingState getCurrentHorizontalTiltAngle getCurrentHumidifierDehumidifierState getCurrentPosition getCurrentRelativeHumidity getCurrentState getCurrentTemperature getCurrentVerticalTiltAngle getDewPoint getDoorMoving getDuration getFilterChangeIndication getFilterLifeLevel getHSV getHeatingThresholdTemperature getHue getInUse getLeakDetected getLockCurrentState getLockPhysicalControls getLockTargetState getMotionDetected getMute getName getNitrogenDioxideDensity getObstructionDetected getOccupancyDetected getOn getOnline getOzoneDensity getPM10Density getPM2_5Density getPositionState getRGB getRGBW getRGBWW getRain1h getRain24h getRelativeHumidityDehumidifierThreshold getRemainingDuration getRotationDirection getRotationSpeed getSaturation getSmokeDetected getStatusActive getStatusFault getStatusLowBattery getStatusTampered getSulphurDioxideDensity getSwingMode getSwitch getTargetAirPurifierState getTargetDoorState getTargetFanState getTargetHeaterCoolerState getTargetHeatingCoolingState getTargetHorizontalTiltAngle getTargetHumidifierDehumidifierState getTargetPosition getTargetRelativeHumidity getTargetState getTargetTemperature getTargetVerticalTiltAngle getTemperatureDisplayUnits getTotalConsumption getUVIndex getVOCDensity getVisibility getVolts getVolume getWaterLevel getWatts getWeatherCondition getWhite getWindDirection getWindSpeed getmaxWind`

`setActive setActiveInput setBrightness setColorTemperature setCoolingThresholdTemperature setDuration setHSV setHeatingThresholdTemperature setHoldPosition setHue setLockPhysicalControls setLockTargetState setMute setOn setRGB setRGBW setRGBWW setRelativeHumidityDehumidifierThreshold setRemoteKey setResetFilterIndication setRotationDirection setRotationSpeed setSaturation setSwingMode setTargetAirPurifierState setTargetDoorState setTargetFanState setTargetHeaterCoolerState setTargetHeatingCoolingState setTargetHorizontalTiltAngle setTargetHumidifierDehumidifierState setTargetPosition setTargetRelativeHumidity setTargetState setTargetTemperature setTargetVerticalTiltAngle setTemperatureDisplayUnits setVolume setWaterLevel setWhite`

Note the irregular spellings `getmaxWind` (lower-case m) and, in the carbon monoxide sensor, `getcarbonMonoxideLevel` / `getcarbonMonoxidePeakLevel` (section 5.9). The docs also list `setRotationMode`/`getRotationMode` for the heater cooler; the plugin does not read them.

Topics are subscribed literally. MQTT wildcards (`+`, `#`) are subscribed as given, but a message arriving on a concrete topic matches no handler and only logs a warning, so wildcards do not work.

Several characteristics may share one topic (for example `getTargetDoorState` and `getCurrentDoorState`, or `getOn` and `getRGB` when a codec splits a JSON payload); each receives every message on it. The broker subscription is made once per distinct topic string.

### 3.3 Topic objects, `apply`, and JSONPath

Wherever a topic string is accepted, an object may be given instead:

| Key | Meaning |
|---|---|
| `topic` | The topic string |
| `apply` | A JavaScript function body (a string), run on every message on that topic |

**What `apply` does.** The text is the body of a function taking two arguments, `message` and `state`, and it must `return` a value.

- On a **get** topic, `message` is the received payload (the raw bytes, which JavaScript code treats as the UTF-8 string through implicit conversion; or the value already extracted by JSONPath or a codec, section 3.5). The returned value replaces the message for the rest of the processing. It may be any JavaScript value (string, number, boolean). If the function returns nothing (undefined), the message is dropped. If it throws, an error is logged (with the function's text, the topic and the message) and the message is dropped.
- On a **set** topic, `message` is the outgoing value before encoding (a boolean, number or string, section 3.4) and the returned value is published in its place, converted to a string. If it returns `null` or nothing, or throws, nothing is published.
- `state` is an object that persists between calls. There is one per **property name** (section 8.2) within the accessory block, shared between that property's get and set topics, and every one of them has a `global` member pointing at one object shared by all properties of the block. Users store counters, last values or flags in it.

The implementer cannot run JavaScript. Common shapes found in the docs (as data, to decide what to support):

| Purpose | Typical body |
|---|---|
| Extract a JSON field | parse the message as JSON and return one field, often with `toFixed(1)` |
| Scale 0–255 to 0–100 on receive | divide by 2.55 and round |
| Scale 0–100 to 0–255 on publish | multiply by 2.55 and round |
| Map strings | compare the message with a literal and return another literal, or a boolean |
| Build a JSON command | return a JSON string containing the message |

Options open to the implementer: refuse blocks that use `apply` (with a clear log line), run them in an embedded JavaScript engine where one exists (JavaScriptCore is not available on Linux), or recognise a fixed set of expressions. The source has no restriction on the code: it runs with the full privileges of the bridge, so `apply` is equivalent to arbitrary code execution from config.json.

**JSONPath.** If a get topic string (or a topic object's `topic`) contains `$` at any position after the first character, the part before the `$` is the topic subscribed to, and the part from `$` on is a JSONPath query (the `jsonpath` library's syntax, e.g. `$.DHT11.Temperature`, `$.sensors[0].value`). Each message on the topic is parsed as JSON, the query is run, and the **first** matching value (or nothing, if none matches) is passed on as the message. The extracted value keeps its JSON type (number, string, boolean, object). JSONPath applies to get topics only; a `$` in a set topic is published literally. A payload that is not valid JSON raises an error in the source's message handler; it should be treated as a dropped message.

### 3.4 Value encodings

**Booleans** (On, Mute, motion, contact, obstruction, status flags, Active, InUse, HoldPosition, ResetFilterIndication, …):

The on value and off value used for publishing and matching are:

| Configuration | On value | Off value |
|---|---|---|
| `onValue` truthy | `onValue` | `offValue` (absent means **no off value**) |
| else `integerValue: true` | number 1 (published `1`) | number 0 (published `0`) |
| else | boolean true (published `true`) | boolean false (published `false`) |

A falsy `onValue` (empty string, 0) counts as not configured, and then `offValue` is ignored too.

Publishing (HomeKit wrote the characteristic): truthy value publishes the on value, falsy value the off value. If there is no off value, **nothing is published** for "off".

Receiving: a message is "on" if it matches the on value; it is "off" if `otherValueOff` is set and it is not on, or if it matches the off value; any other message is **ignored** (state unchanged). With `onValue` set and `offValue` absent, every non-on message is therefore ignored unless `otherValueOff` is set. (The docs claim omitting `offValue` makes every other value "off"; the code does not do that.)

Matching rule ("matches", used throughout): the received value `m` matches configured value `c` if they are identical, or if `m` equals the decimal/text form of `c` under JavaScript loose equality. In practice:

- A raw payload is compared as its UTF-8 text with the text form of `c`, exactly: case-sensitive, no trimming. `"true"` matches boolean true; `"1"` matches number 1; `"ON"` does not match `"on"`.
- A number (from JSONPath, a codec or `apply`) is compared numerically with the text form of `c` converted to a number: 1 matches `"1"` and `1`; it does not match `"on"`.
- A boolean is identical to a configured boolean (the default on/off values are booleans, so in the default mode a JSON `true` is "on" and `false` is "off"). Against a configured text or number it is treated as 1 or 0: true matches `"1"` and number 1 (so with `integerValue` a JSON `true` is "on"), but true does not match the text `"true"` or `"ON"`.

HomeKit side: a boolean state maps to the characteristic's 1/0 (for the enumerated sensor characteristics, true is always the "detected/active/triggered" value 1, see each type).

**Integers** (Brightness, Hue/Saturation in separate-topic mode, ColorTemperature, positions, tilt angles, RotationSpeed, RotationDirection, BatteryLevel, WaterLevel, SetDuration, Rain1h/Rain24h/UVIndex/Visibility):
received text is parsed the way JavaScript's `parseInt` does: leading white space skipped, an optional sign, then digits up to the first non-digit (`"57.9"` → 57, `"40%"` → 40, `"0x1A"` → 26, `"abc"` → not a number). Published as the HomeKit value's decimal text.

**Floats** (temperatures, humidity, light level, air quality densities, CO/CO2 levels, Volume, energy readings, FilterLifeLevel, AirPressure, WindSpeed, DewPoint, thresholds, TargetRelativeHumidity, RelativeHumidityDehumidifierThreshold):
parsed the way `parseFloat` does (`"21.5 C"` → 21.5, `"-3"` → −3, `"x"` → not a number). Published as the HomeKit value's shortest decimal text (`21.5`, `20`).

**Strings** (Name, Eve weather Condition, Eve WindDirection): the payload text as is.

**Enumerations** (security system states, door states, lock states, heating/cooling modes, position state, air quality, …): a list of MQTT values, where the value at index *i* stands for HomeKit value *i*. Received text is looked up among the list's values (as text); an unknown value is ignored (and logged when `logMqtt` is on). HomeKit writes publish the list entry at the written index; a HomeKit boolean is taken as 1/0; an index outside the list publishes nothing (the state still changes). List entries may be numbers; they are compared and published as text.

### 3.5 Processing order

On receipt, for each subscription on the topic, in this order:

1. JSONPath extraction (if the topic has a `$` part).
2. Codec `decode` (if a codec is loaded; property-specific function first, else the codec's default).
3. `apply` (if the topic is an object with `apply`).
4. `debounceRecvms` delay.
5. The characteristic's own parsing and update.

On publishing:

1. `apply` (set topic object).
2. Codec `encode`.
3. `optimizePublishing` check.
4. Log (if `logMqtt`) and publish with `mqttPubOptions`. The payload is the value converted to text (`true`, `1`, `21.5`, `255,0,0`).

A value of `null` or a missing set topic publishes nothing.

---

## 4. MQTT connection

### 4.1 Client options

One client per accessory block, connected while the accessory is created. Defaults, each overridden by the same key in `mqttOptions`:

| Option | Default |
|---|---|
| keep-alive | 10 s |
| client id | `mqttthing_` + the name with every character outside the printable ASCII range (code points 0x20–0x7F) removed + `_` + 8 random lowercase hex digits |
| protocol | MQTT 3.1.1 (protocol id `MQTT`, level 4) |
| clean session | true |
| reconnect period | 1000 ms (reconnects forever; the MQTT library resubscribes on reconnect, so retained state is delivered again) |
| connect timeout | 30 s |
| will | topic `WillMsg`, payload `mqtt-thing [<name>] has stopped`, QoS 0, not retained |
| username / password | section 3.1 |
| TLS certificate verification | **off** by default (`rejectUnauthorized: false`); a user sets `"rejectUnauthorized": true` in `mqttOptions` to turn it on |

Subscriptions use the library default QoS 0. Publish options are `mqttPubOptions` (default: QoS 0, not retained). Retained messages on get topics give the accessory its state at start-up and after reconnects; there is no explicit state request.

Connection errors are logged and the library keeps reconnecting. There is no link between broker connectivity and HomeKit's "No Response" except through `getOnline` and confirmation (section 6).

If initialising MQTT throws (for example a `cafile` that cannot be read), the accessory exposes no services.

### 4.2 Message without handler

A message on a topic with no subscription handler logs a warning naming the topic.

---

## 5. Accessory types

Notation used below:

- **B** boolean (section 3.4), **I** integer, **F** float, **S** string, **E[list]** enumeration with its default list and the config key that replaces it.
- "init" is the internal starting value (what HomeKit reads before any message). Where the init value is 0 or false the characteristic keeps the HAP default; otherwise the characteristic is also set to it.
- `get`/`set` are topic keys. A characteristic is created only under the condition given; the HAP service's **required** characteristics exist regardless **[host]** (HAP-NodeJS creates them with their default values), so for example a LockMechanism with no topics still has LockCurrentState and LockTargetState.
- The `property` column is the property name a codec, `apply` state and the JSON codec use (section 8.2).
- Range changes apply to the characteristic's HomeKit min/max.
- Every type also gets the common characteristics of section 5.34 and the battery service of section 5.35.

The **optional sensor status set** ("+status") means: StatusActive (B, `getStatusActive`, init true, property `statusActive`), StatusFault (B, `getStatusFault`, `statusFault`), StatusTampered (B, `getStatusTampered`, `statusTampered`), StatusLowBattery (B, `getStatusLowBattery`, `statusLowBattery`), each created only if its topic is configured. All are get-only.

### 5.1 `airPressureSensor`

Service: Eve AirPressureSensor (`E863F00A-079E-48FF-8F27-9C2605A29F52`).

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| Eve AirPressure (`E863F10F-079E-48FF-8F27-9C2605A29F52`, float, hPa, 700–1100, step 0.1) | F | `getAirPressure` | 700 | `airPressure` |
| Eve Elevation (`E863F130-079E-48FF-8F27-9C2605A29F52`, int, m, −450–9000) | static | none | set to 100 | none |
| +status | | | | |

History: `weather` type, entries `{pressure}` (section 7).

### 5.2 `airPurifier`

Service AirPurifier.

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| Active | B (true ↔ 1) | `setActive`, `getActive`; auto-off by `turnOffAfterms` | false | `active` |
| CurrentAirPurifierState | E[`INACTIVE`,`IDLE`,`PURIFYING`] `currentAirPurifierStateValues` | `getCurrentAirPurifierState` | 0 | `currentAirPurifierState` |
| TargetAirPurifierState | E[`MANUAL`,`AUTO`] `targetAirPurifierStateValues` | `setTargetAirPurifierState`, `getTargetAirPurifierState` | 1 (AUTO) | `targetAirPurifierState` |
| RotationSpeed (if `getRotationSpeed` or `setRotationSpeed`) | I, range `minRotationSpeed`/`maxRotationSpeed` when integers | `setRotationSpeed`, `getRotationSpeed` | 0 | `rotationSpeed` |
| SwingMode (if get or set) | E[`DISABLED`,`ENABLED`] `swingModeValues` | `setSwingMode`, `getSwingMode` | 0 | `swingMode` |
| LockPhysicalControls (if get or set) | E[`DISABLED`,`ENABLED`] `lockPhysicalControlsValues` | `setLockPhysicalControls`, `getLockPhysicalControls` | 0 | `lockPhysicalControls` |

If any of `getFilterChangeIndication`, `getFilterLifeLevel`, `setResetFilterIndication` is configured, a FilterMaintenance service is added, named `serviceNames.filter` or `<name>-Filter`, subtype the block's `subtype`, linked from the AirPurifier service:

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| FilterChangeIndication (always, in this service) | B (true ↔ CHANGE_FILTER 1) | `getFilterChangeIndication` | false | `filterChangeIndication` |
| FilterLifeLevel (if get) | F | `getFilterLifeLevel` | 100 | `filterLifeLevel` |
| ResetFilterIndication (if set) | B, write-only (HomeKit's write of 1 publishes the on value) | `setResetFilterIndication` | false | `resetFilterIndication` |

The config-ui schema calls the state keys `currentAirPurifierValues`/`targetAirPurifierValues`, but the plugin reads `currentAirPurifierStateValues`/`targetAirPurifierStateValues`. A drop-in replacement must read the latter (and may also accept the former).

### 5.3 `airQualitySensor`

Primary service AirQualitySensor, named `serviceNames.airQuality` or `name`.

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| AirQuality | E[`UNKNOWN`,`EXCELLENT`,`GOOD`,`FAIR`,`INFERIOR`,`POOR`] `airQualityValues` | `getAirQuality` | 0 | `airQuality` |
| +status | | | | |
| CarbonDioxideLevel (if get) | F | `getCarbonDioxideLevel` | 0 | `carbonDioxideLevel` |
| PM10Density (if get) | F | `getPM10Density` | 0 | `pm10density` |
| PM2_5Density (if get) | F | `getPM2_5Density` | 0 | `pm2_5density` |
| OzoneDensity (if get) | F | `getOzoneDensity` | 0 | `ozoneDensity` |
| NitrogenDioxideDensity (if get) | F | `getNitrogenDioxideDensity` | 0 | `nitrogenDioxideDensity` |
| SulphurDioxideDensity (if get) | F | `getSulphurDioxideDensity` | 0 | `sulphurDioxideDensity` |
| VOCDensity (if get) | F | `getVOCDensity` | 0 | `VOCDensity` |
| CarbonMonoxideLevel (if get) | F | `getCarbonMonoxideLevel` | 0 | `carbonMonoxideLevel` |
| Eve AirParticulateDensity (`E863F10B-079E-48FF-8F27-9C2605A29F52`, float, ppm, 0–5000) — only when `history` is on, `room2` is off, and `getAirQualityPPM` is set | F | `getAirQualityPPM` | 0 | `airQualityPPM` |

Secondary services:

- If `getCurrentTemperature`: TemperatureSensor named `serviceNames.temperature` or `<name>-Temperature`, with CurrentTemperature (as in 5.29), TemperatureDisplayUnits (E[`CELSIUS`,`FAHRENHEIT`] `temperatureDisplayUnitsValues`, `setTemperatureDisplayUnits`/`getTemperatureDisplayUnits`, init 0, property `temperatureDisplayUnits`, always created here) and +status.
- If `getCurrentRelativeHumidity`: HumiditySensor named `serviceNames.humidity` or `<name>-Humidity`, CurrentRelativeHumidity (F, init 0, `currentRelativeHumidity`) and +status.

Type-specific keys: `room2` (bool). History: with `room2`, Eve `room2` type with entries `{voc}` (from `getVOCDensity`), `{temp}`, `{humidity}`; otherwise `room` type with `{ppm}` (from `getAirQualityPPM`), `{temp}`, `{humidity}`.

### 5.4 `carbonDioxideSensor`

Service CarbonDioxideSensor: CarbonDioxideDetected E[`NORMAL`,`ABNORMAL`] `carbonDioxideDetectedValues` (`getCarbonDioxideDetected`, init 0, `carbonDioxideDetected`); +status; CarbonDioxideLevel (F, if get, `carbonDioxideLevel`); CarbonDioxidePeakLevel (F, if `getCarbonDioxidePeakLevel`, `carbonDioxidePeakLevel`).

### 5.5 `carbonMonoxideSensor`

Service CarbonMonoxideSensor: CarbonMonoxideDetected E[`NORMAL`,`ABNORMAL`] `carbonMonoxideDetectedValues` (`getCarbonMonoxideDetected`, init 0, `carbonMonoxideDetected`); +status.

The source then checks the lower-case keys `getcarbonMonoxideLevel` and `getcarbonMonoxidePeakLevel`, and if either is present calls a routine that does not exist, which makes the whole accessory fail to create. The docs document `getCarbonMonoxideLevel`/`getCarbonMonoxidePeakLevel`. The intended behaviour is CarbonMonoxideLevel (F, `carbonMonoxideLevel`) and CarbonMonoxidePeakLevel (F, `carbonMonoxidePeakLevel`, init 0) when those topics are given; see Gaps.

### 5.6 `contactSensor`

Service ContactSensor: ContactSensorState B (`getContactSensorState`; true ↔ CONTACT_NOT_DETECTED 1 = open/triggered, false ↔ CONTACT_DETECTED 0; init false; reset by `resetStateAfterms`; property `contactSensorState`); +status. History: `door` type (section 7.4).

### 5.7 `dehumidifier`

Service HumidifierDehumidifier.

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| Active | B (true ↔ 1), `turnOffAfterms` | `setActive`, `getActive` | false | `active` |
| CurrentRelativeHumidity | F | `getCurrentRelativeHumidity` | 0 | `currentRelativeHumidity` |
| CurrentHumidifierDehumidifierState | E[`INACTIVE`,`IDLE`,`HUMIDIFYING`,`DEHUMIDIFYING`] key `currentHumidifierDehumidifierState` | `getCurrentHumidifierDehumidifierState` | 0 | same as key |
| TargetHumidifierDehumidifierState | E[`HUMIDIFIER_OR_DEHUMIDIFIER`,`HUMIDIFIER`,`DEHUMIDIFIER`] key `targetHumidifierDehumidifierState` | `setTargetHumidifierDehumidifierState`, `getTargetHumidifierDehumidifierState` | 2 (DEHUMIDIFIER) | same as key |
| RelativeHumidityDehumidifierThreshold (only if `setRelativeHumidityDehumidifierThreshold`) | F | that set topic and `getRelativeHumidityDehumidifierThreshold` | 0 | `relativeHumidityDehumidifierThreshold` |
| WaterLevel (only if `getWaterLevel`) | I, 0–100 | `setWaterLevel`, `getWaterLevel` | 0 | `waterLevel` |

`restrictDehumidifierState` (array of allowed target values): in the source it refers to a characteristic that does not exist and makes creation fail. Intended: the allowed values of TargetHumidifierDehumidifierState. See Gaps.

### 5.8 `door`, `window`

Service Door or Window.

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| CurrentPosition | I, range `minPosition`/`maxPosition` when integers | `getCurrentPosition` | `minPosition` or 0 | `currentPosition` |
| TargetPosition | I, same range | `setTargetPosition`, `getTargetPosition` | `minPosition` or 0 | `targetPosition` |
| PositionState | E[`DECREASING`,`INCREASING`,`STOPPED`] `positionStateValues` | `getPositionState` | 2 (STOPPED) | `positionState` |
| HoldPosition (if set) | B write-only | `setHoldPosition` | false | `holdPosition` |
| ObstructionDetected (if get) | B | `getObstructionDetected` | false | `obstructionDetected` |

### 5.9 `doorbell`

Service Doorbell.

| Characteristic | Kind | Topics | Property |
|---|---|---|---|
| ProgrammableSwitchEvent | event enumeration (section 6.7) E[`1`,`2`,`L`] `switchValues`; `restrictSwitchValues` = allowed values (0 single, 1 double, 2 long) | `getSwitch` | `switch` |
| Brightness (if `setBrightness` or `getBrightness`) | as the lightbulb's Brightness (5.17.5), including the "brightness 0 means off" variant when there is no `setOn`, which adds On to the Doorbell service | `setBrightness`, `getBrightness` | `brightness` |
| Volume (if get or set) | F (format uint8, so validation wants integers) | `setVolume`, `getVolume`, init 0 | `volume` |

If `getMotionDetected`: a MotionSensor service named `serviceNames.motion` or `<name>-motion` (hyphen), subtype the block's `subtype`, with MotionDetected as in 5.20 (no status set, no history).

### 5.10 `fan`

Service Fan.

- On (5.17.1 rules: B, `setOn`/`getOn`, confirmation, `turnOffAfterms`, `resetStateAfterms`, property `on`): created if `setOn` is configured or `setRotationSpeed` is not.
- RotationDirection (I, `setRotationDirection`/`getRotationDirection`, 0 clockwise / 1 counter-clockwise, property `rotationDirection`): if either topic.
- RotationSpeed (if either topic):
  - with `setOn`: plain I with range `minRotationSpeed`/`maxRotationSpeed` (when integers), property `rotationSpeed`;
  - without `setOn`: the "speed 0 means off" variant, identical to the lightbulb's brightness-only mode (5.17.5) with RotationSpeed in place of Brightness and `setRotationSpeed`/`getRotationSpeed` as topics; the min/max keys are not applied in this variant.

### 5.11 `fanv2`

Service Fanv2.

| Characteristic | Condition | Kind / topics | Property |
|---|---|---|---|
| Active | always | B, `setActive`/`getActive`, `turnOffAfterms` | `active` |
| CurrentFanState | only if the **block-level** key `getCurrentFanState` is truthy (a source bug: the topic it then subscribes to is `topics.getCurrentFanState`) | E[`INACTIVE`,`IDLE`,`BLOWING_AIR`] `currentFanValues`, init 0 | `currentFanState` |
| TargetFanState | `setTargetFanState` or `getTargetFanState` | E[`MANUAL`,`AUTO`] `targetFanStateValues`, init 1 | `targetFanState` |
| LockPhysicalControls | either topic | as 5.2 | `lockPhysicalControls` |
| RotationDirection | either topic | I | `rotationDirection` |
| RotationSpeed | either topic | plain I with `minRotationSpeed`/`maxRotationSpeed` | `rotationSpeed` |
| SwingMode | either topic | as 5.2 | `swingMode` |

The docs name the value keys `targetFanValues` and `currentFanStateValues`; the code reads `targetFanStateValues` and `currentFanValues` (the schema has `currentFanValues` and `targetFanValues`). Accepting all spellings is harmless.

### 5.12 `garageDoorOpener`

Service GarageDoorOpener.

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| TargetDoorState | E[`O`,`C`] from `doorTargetValues`, else `doorValues`, else default | `setTargetDoorState`, `getTargetDoorState` | 0 (OPEN) | `targetDoorState` |
| CurrentDoorState, normal | E[`O`,`C`,`o`,`c`,`S`] (OPEN, CLOSED, OPENING, CLOSING, STOPPED) from `doorCurrentValues`, else `doorValues`, else default | `getCurrentDoorState` | 1 (CLOSED) | `currentDoorState` |
| CurrentDoorState, derived (when `getDoorMoving` is set; replaces the normal one) | see below | `getDoorMoving` (B) | moving false | `doorMoving` |
| ObstructionDetected | B | `getObstructionDetected` | false | `obstructionDetected` |
| LockTargetState (only if `setLockTargetState`) | E[`U`,`S`] from `lockValues` (first two entries) | `setLockTargetState`, `getLockTargetState` | 0 | `lockTargetState` |
| LockCurrentState (only if `getLockCurrentState`) | E[`U`,`S`,`J`,`?`] (UNSECURED, SECURED, JAMMED, UNKNOWN) `lockValues` | `getLockCurrentState` | 0 | `lockCurrentState` |

Derived current state: if moving, OPENING (2) when the target is OPEN, else CLOSING (3); if not moving, OPEN (0) when the target is OPEN, else CLOSED (1). It is recomputed and pushed to HomeKit **1 second after** the moving flag changes and 1 second after any change of TargetDoorState (a HomeKit write or a received target). A HomeKit read returns the value computed at that moment. At start-up the derived state is pushed after 1 s (moving false, target OPEN, so OPEN).

### 5.13 `heaterCooler`

Service HeaterCooler.

| Characteristic | Condition | Kind / topics | Init | Property |
|---|---|---|---|---|
| Active | always | B, `setActive`/`getActive`, `turnOffAfterms` | false | `active` |
| CurrentHeaterCoolerState | always | E[`INACTIVE`,`IDLE`,`HEATING`,`COOLING`] `currentHeaterCoolerValues`, `getCurrentHeaterCoolerState` | 0 | `currentHeaterCoolerState` |
| TargetHeaterCoolerState | always | E[`AUTO`,`HEAT`,`COOL`] `targetHeaterCoolerValues`, set/get; `restrictHeaterCoolerState` = allowed values | 0 | `targetHeaterCoolerState` |
| CurrentTemperature | always | as 5.29 | 0 | `currentTemperature` |
| LockPhysicalControls | either topic | as 5.2 | 0 | `lockPhysicalControls` |
| SwingMode | either topic | as 5.2 | 0 | `swingMode` |
| CoolingThresholdTemperature | either topic | F, set/get, range `minTemperature`/`maxTemperature` | 25 | `coolingThresholdTemperature` |
| HeatingThresholdTemperature | either topic | F, set/get, same range | 20 | `heatingThresholdTemperature` |
| TemperatureDisplayUnits | either topic | E[`CELSIUS`,`FAHRENHEIT`] `temperatureDisplayUnitsValues` | 0 | `temperatureDisplayUnits` |
| RotationSpeed | either topic | plain I with min/max keys | 0 | `rotationSpeed` |
| StatusFault | `getStatusFault` | B | false | `statusFault` |

### 5.14 `humiditySensor`

Service HumiditySensor: CurrentRelativeHumidity (F, `getCurrentRelativeHumidity`, init 0, `currentRelativeHumidity`); +status. History `weather` with `{humidity}`.

### 5.15 `irrigationSystem`

Matched only when `type` is exactly `irrigationSystem`. A missing `topics` object is allowed here (treated as empty).

Primary service IrrigationSystem (marked primary):

| Characteristic | Kind / topics | Property |
|---|---|---|
| Active | B, `setActive`/`getActive`, `turnOffAfterms` | `active` |
| InUse | B (true ↔ IN_USE 1), `getInUse` | `inUse` |
| ProgramMode | static NO_PROGRAM_SCHEDULED (0) | none |
| StatusFault (if `getStatusFault`) | B | `statusFault` |

If `zones` (array of `{ name, topics }`) is given: a ServiceLabel service (no name, no subtype) with ServiceLabelNamespace ARABIC_NUMERALS (1), and for each zone *n* (1-based) a Valve service named the zone's `name` (or empty), subtype *n*, linked from the IrrigationSystem service, with:

| Characteristic | Kind / topics | Property |
|---|---|---|
| ValveType | static IRRIGATION (1) | none |
| ServiceLabelIndex | static *n* | none |
| Active | B, zone `setActive`/`getActive`, block `turnOffAfterms` | `active-<n>` |
| InUse | B, zone `getInUse` | `inUse-<n>` |
| SetDuration | section 6.8; topics: zone `setDuration`/`getDuration`, each falling back to the block's | `setDuration-<n>` |
| RemainingDuration | section 6.8; zone `getRemainingDuration` | `remainingDuration` |
| IsConfigured | static CONFIGURED (1) | none |
| StatusFault | created when the **zone** has `getStatusFault`, but it subscribes to the **block's** `getStatusFault` (source bug) | `statusFault` |

Coupling between the system and its zones (triggered by any change of value, whatever its origin):

- A zone's Active becoming ACTIVE while the system is inactive makes the system's Active ACTIVE, which publishes the system's `setActive` on value if configured.
- A zone's Active becoming INACTIVE, unless `noAutoInactive` is true: if no zone is active any more and the system is active, the system's Active becomes INACTIVE (published).
- The system's Active becoming INACTIVE makes each active zone INACTIVE (each published on its zone's `setActive`).
- A zone's InUse becoming IN_USE makes the system's InUse IN_USE; when no zone is in use any more, the system's InUse becomes NOT_IN_USE. These are HomeKit updates only (InUse has no set topic).

Keys: `zones`, `durationTimer`, `minDuration`, `maxDuration`, `noAutoInactive`.

### 5.16 `leakSensor`

Service LeakSensor: LeakDetected (B, `getLeakDetected`, true ↔ LEAK_DETECTED 1, `resetStateAfterms`, `leakDetected`); WaterLevel (I 0–100, if `setWaterLevel` or `getWaterLevel`, `waterLevel`); +status.

### 5.17 `lightbulb`

Service Lightbulb. The **mode** is chosen from the topics, first match wins:

1. `setHSV` present → HSV mode (5.17.2).
2. `setRGB`, `setRGBW` or `setRGBWW` present → RGB family (5.17.3): RGBWW if `setRGBWW`, else RGBW if `setRGBW`, else RGB (with a separate white channel if `setWhite` is also present).
3. `setWhite` present → white mode (5.17.4).
4. Otherwise separate-topic mode (5.17.5).

In modes 1–3 the separate `setBrightness`/`setHue`/`setSaturation`/`setColorTemperature` topics are ignored. In mode 4 a characteristic is created only when its **set** topic exists (a `getHue` without `setHue` creates nothing).

Common keys: `hex` (bool), `hexPrefix` (string, truthy implies hex), `warmWhite`, `coldWhite` (strings `r,g,b`), `noWhiteMix`, `whiteMix`, `redThreshold`, `greenThreshold`, `blueThreshold` (default 15 each), `switchWhites`, `minColorTemperature`, `maxColorTemperature`, `adaptiveLighting`, `turnOffAfterms`, `resetStateAfterms`.

#### 5.17.1 On (where a mode uses `setOn`)

B on `setOn`/`getOn`, init false, property `on`, with confirmation (6.1), `turnOffAfterms` and `resetStateAfterms` (6.3). The same rules apply to the On of `switch`, `outlet` and `fan`.

#### 5.17.2 HSV mode

Characteristics: On, Hue (init 0), Saturation (init 0), Brightness (init 100), plus an internal ColorTemperature for Adaptive Lighting (5.17.6). Hue, Saturation and Brightness have no topics of their own here; the combined topic's property is `HSV`.

- On: if `setOn` exists, it is the 5.17.1 On and is published on `setOn` only. Otherwise On is internal and folded into the HSV value.
- Coupling of HomeKit writes (internal On only): writing On=true while brightness is 0 sets brightness to 100. In both variants, writing Brightness > 0 while off turns On on internally.
- Every HomeKit write of Hue, Saturation, Brightness (and of internal On) schedules a publish **20 ms** later; another write within the window restarts it, so a scene that writes several characteristics produces one message.
- Payload on `setHSV`: `H,S,V` (decimal, comma-separated, no spaces), H 0–360, S 0–100, V = brightness, except that V is 0 when there is no `setOn` and the light is off. The payload is not published if it equals the last one published on `setHSV` by this light.
- Receiving on `getHSV`: the text is split on commas; anything but exactly three parts is ignored; each part is parsed as an integer. Without `setOn`, On becomes (V > 0). Each of hue, saturation and brightness that differs from the current state updates its characteristic; a received hue or saturation change turns Adaptive Lighting off if it is active.

#### 5.17.3 RGB family

Characteristics as HSV mode (On, Hue, Saturation, Brightness, internal ColorTemperature). Combined property `RGB`, `RGBW` or `RGBWW`; the separate white channel's property is `white`.

**HomeKit → MQTT** (same 20 ms coalescing, same On/Brightness coupling and V=0-when-off rule as HSV):

1. Convert (H, S, V) with V = brightness (or 0 when off without `setOn`) to RGB with the standard hexcone formula: h = H/360, s = S/100, v = V/100; i = ⌊6h⌋, f = 6h − i, p = v(1−s), q = v(1−fs), t = v(1−(1−f)s); by i mod 6: 0 → (v,t,p), 1 → (q,v,p), 2 → (p,v,t), 3 → (p,q,v), 4 → (t,p,v), 5 → (v,p,q); each component ×255 rounded half up.
2. **RGB**: publish `r,g,b`.
3. **RGB with separate white** (`setWhite` present): w = min(r,g,b); subtract w from r, g, b; publish `r,g,b` on `setRGB` and w (decimal) on `setWhite`. The white value is published on every publish, even when the RGB payload is unchanged and skipped.
4. **RGBW**: same extraction; publish `r,g,b,w`.
5. **RGBWW**: warm white colour W = `warmWhite` or (255,158,61); cold white colour C = `coldWhite` or (204,219,255) (a string that is not exactly three comma-separated parts falls back to the default).
   - White factor of colour (r,g,b) against a white X, a number in [0,1]: the smallest of (a) r/X.r, g/X.g, b/X.b, each taken as 1 when the X component is 0, and (b) a "shape" factor: if max(r,g,b) < 1 it is 0; otherwise scale the colour so its largest component is 255 (scale k = 255/max), let xmin = min(X) and cmin = min of the scaled colour; for each channel where X's component is greater than xmin, the channel factor is (scaled channel − cmin)/(X channel − xmin)/k, otherwise 1; the shape factor is the smallest channel factor clamped to [0,1]. The overall factor is clamped to [0,1].
   - fw = factor against W, fc = factor against C. If fw + fc > 1, divide both by their sum.
   - ww = ⌊255·fw⌋, cw = ⌊255·fc⌋; each of r, g, b becomes max(0, ⌊channel − fw·W.channel − fc·C.channel⌋).
   - m = min(r, g, b, 255 − ww, 255 − cw); ww and cw each grow by ⌊m/2⌋; r, g, b each drop by m.
   - If `whiteMix` is false or `noWhiteMix` is true, and both a white (ww or cw > 0) and a colour (r, g or b > 0) remain: if r > `redThreshold` or g > `greenThreshold` or b > `blueThreshold`, publish the original RGB of step 1 with ww = cw = 0; otherwise set r = g = b = 0 and keep the whites.
   - Publish `r,g,b,ww,cw`, or `r,g,b,cw,ww` with `switchWhites`.
6. Hex form (`hex: true` or a `hexPrefix`): the prefix (empty for `hex`) followed by two **lowercase** hex digits per component in the same order, no separators (`ff0000`, `#7f000080`).
7. The combined payload is skipped when it equals the last one published by this light.

**MQTT → HomeKit** on the matching get topic (`getRGB`, `getRGBW`, `getRGBWW`):

1. Decimal form: split on commas; the number of parts must be 3 (RGB), 4 (RGBW) or 5 (RGBWW), else ignore; parse each as an integer. Hex form: the payload length must be prefix length + 2 × the component count and it must start with the prefix, else ignore; then each pair of characters after the prefix is a hex byte. With `switchWhites` the 4th and 5th components are swapped (they arrive as cold, warm).
2. RGBWW: add the whites back: each channel += ⌊W.channel·ww/255⌋ + ⌊C.channel·cw/255⌋. RGBW: white = 4th component. RGB with separate white: white = the last value received on `getWhite` (0 until one arrives). Plain RGB: white = 0. Then each channel = min(channel + white, 255).
3. Convert to HSV: max, min, d = max − min; S = d/max (0 when max is 0); V = max/255; hue: 0 if max = min; else if max is red, ((g − b) + 6d when g < b, else (g − b)) / 6d; else if max is green, ((b − r) + 2d)/6d; else ((r − g) + 4d)/6d (ties are resolved in the order red, green, blue). Hue = ⌊360·h⌋, Sat = ⌊100·S⌋, Bri = ⌊100·V⌋.
4. Without `setOn`, On becomes (Bri > 0). Each of Hue, Saturation, Brightness that differs from the state updates its characteristic; hue or saturation changes turn Adaptive Lighting off.
5. A message on `getWhite` (RGB with separate white) stores the integer white value and recomputes from the last RGB received.

Round trips are lossy (the received value replaces the HomeKit one), see the vectors in section 10.

#### 5.17.4 White mode (`setWhite` without any RGB topic)

Characteristics: On (internal, `setOn` is not used, init false) and Brightness (init 100), neither with a topic of its own. Property of the `setWhite`/`getWhite` topic: `white`.

- Writes: On=true while brightness is 0 sets brightness 100; Brightness > 0 while off turns On on.
- Each HomeKit write publishes **immediately** (no 20 ms coalescing, no duplicate suppression) on `setWhite`: level = min(⌈2.55 · brightness⌉, 255), or 0 when off; decimal, or prefix + two lowercase hex digits.
- `getWhite`: decimal must be a single value (no comma); hex must be prefix + 2 characters. Brightness = min(⌊level / 2.55⌋, 100), On = Brightness > 0; each characteristic updated if it differs.

#### 5.17.5 Separate-topic mode

- On (5.17.1): created when `setOn` exists **or** `setBrightness` does not.
- Brightness (when `setBrightness` exists):
  - with `setOn`: plain I on `setBrightness`/`getBrightness`, property `brightness`;
  - without `setOn` ("brightness 0 means off"): On and Brightness (init 0) are both internal; HomeKit writes follow the coupling rules (On=true with brightness 0 → 100; Brightness > 0 → On); each write schedules a 20 ms coalesced publish on `setBrightness` of the brightness, or 0 when off (no duplicate suppression). Receiving on `getBrightness` an integer n: if n or the derived on-state (n ≠ 0) differs from the state, Brightness is updated to n only when n ≠ 0 (so the last non-zero brightness is kept), and On is set to n ≠ 0.
- Hue (when `setHue`): plain I, `setHue`/`getHue`, property `hue`. A received change turns Adaptive Lighting off.
- Saturation (when `setSaturation`): plain I, `saturation`. Same.
- ColorTemperature (when `setColorTemperature`): plain I on `setColorTemperature`/`getColorTemperature`, range `minColorTemperature`/`maxColorTemperature` when integers (HAP default 140–500 mired), init `minColorTemperature` or 140, property `colorTemperature`. A received change turns Adaptive Lighting off. With Adaptive Lighting supported, an automatic-mode Adaptive Lighting controller is attached to the service, so its writes are published on `setColorTemperature`.
- Otherwise, when Adaptive Lighting is supported and both `setHue` and `setSaturation` exist: the internal ColorTemperature of 5.17.6, whose computed hue and saturation are published on `setHue`/`setSaturation`.

#### 5.17.6 Internal ColorTemperature and Adaptive Lighting

"Supported" means `adaptiveLighting` is not false (the source also requires Homebridge 1.3.0 or later, which can be taken as always true).

In HSV mode, the RGB family, and separate mode with hue+saturation but no colour temperature topic, the Lightbulb gets a ColorTemperature characteristic with no topics (init 140, property `colorTemperature`) and an automatic-mode Adaptive Lighting controller. Whenever ColorTemperature is written (by HomeKit or the controller), hue and saturation are computed from it with HAP-NodeJS's colour-temperature-to-hue-and-saturation conversion; the Hue and Saturation characteristics are updated (as value notifications), and the values are handled as if HomeKit had written them (HSV/RGB modes: state updated and the combined value published after 20 ms; separate mode: published on `setHue`/`setSaturation`). Received hue or saturation changes disable Adaptive Lighting when it is active (logged as "external control"). With `adaptiveLighting: false` no internal ColorTemperature and no controller are created.

### 5.18 `lightSensor`

Service LightSensor: CurrentAmbientLightLevel (F, `getCurrentAmbientLightLevel`, init 0.0001, `currentAmbientLightLevel`); +status.

### 5.19 `lockMechanism`

Service LockMechanism: LockTargetState only if `setLockTargetState` (with `getLockTargetState`); LockCurrentState only if `getLockCurrentState`; both as in 5.12 (`lockValues`, defaults `U`,`S` and `U`,`S`,`J`,`?`, init 0).

### 5.20 `motionSensor`

Service MotionSensor: MotionDetected (B, `getMotionDetected`, property `motionDetected`; `turnOffAfterms` here means: after a received "on", reset to not-detected after that many ms, without publishing); +status. History `motion` (7.3).

### 5.21 `microphone`, `speaker`

Service Microphone or Speaker: Mute (B, `setMute`/`getMute`, init false, no confirmation, `mute`); Volume (F, if either topic, init 0, `volume`; HAP format uint8, so validation rejects fractions).

### 5.22 `occupancySensor`

Service OccupancySensor: OccupancyDetected (B, `getOccupancyDetected`, true ↔ OCCUPANCY_DETECTED 1, `occupancyDetected`); +status.

### 5.23 `outlet`

Service Outlet:

| Characteristic | Condition | Kind / topics | Property |
|---|---|---|---|
| On | always | 5.17.1 | `on` |
| OutletInUse | `getInUse` | B | `outletInUse` |
| Eve CurrentConsumption (`E863F10D-079E-48FF-8F27-9C2605A29F52`, float, W, 0–12000) | `getWatts` | F, init 0 | `currentConsumption` |
| Eve Voltage (`E863F10A-…`, float, V, 0–380) | `getVolts` | F; range `minVolts`/`maxVolts`; init 0 clamped into the range | `voltage` |
| Eve ElectricCurrent (`E863F126-…`, float, A, 0–48) | `getAmperes` | F, init 0 | `electricCurrent` |
| Eve TotalConsumption (`E863F10C-…`, float, kWh, 0–1000000) | `getTotalConsumption` | F, init 0 | `totalConsumption` |

(`…` = `-079E-48FF-8F27-9C2605A29F52`.) History: `energy` (7.5).

### 5.24 `securitySystem`

Service SecuritySystem:

| Characteristic | Kind | Topics | Init | Property |
|---|---|---|---|---|
| SecuritySystemTargetState | E[`SA`,`AA`,`NA`,`D`] (STAY_ARM, AWAY_ARM, NIGHT_ARM, DISARM) `targetStateValues`; `restrictTargetState` = allowed values | `setTargetState`, `getTargetState` | 3 | `targetState` |
| SecuritySystemCurrentState | E[`SA`,`AA`,`NA`,`D`,`T`] (… DISARMED, ALARM_TRIGGERED) `currentStateValues` | `getCurrentState` | 3 | `currentState` |
| StatusFault | if get | B | false | `statusFault` |
| StatusTampered | if get | B | false | `statusTampered` |

`getAltSensorState`: subscribed with property `AltSensorState`; a boolean is decoded and only a warning is logged. It exists for the ShellyAMAX codec (8.4); it changes no characteristic.

### 5.25 `smokeSensor`

Service SmokeSensor: SmokeDetected (B, true ↔ SMOKE_DETECTED 1, `getSmokeDetected`, `resetStateAfterms`, `smokeDetected`); +status.

### 5.26 `statelessProgrammableSwitch`

- `topics.getSwitch` a single topic: one StatelessProgrammableSwitch service (name, block subtype) with ProgrammableSwitchEvent, E[`1`,`2`,`L`] `switchValues`, `restrictSwitchValues`, property `switch`.
- `topics.getSwitch` an array of N topics: a ServiceLabel service (named `name`, no subtype) with ServiceLabelNamespace DOTS (0), or ARABIC_NUMERALS (1) when `labelType` is `numerals`; then for each button i = 0…N−1 a StatelessProgrammableSwitch service named `<name> <i>`, subtype i+1, with ServiceLabelIndex i+1 and ProgrammableSwitchEvent on topic i, property `switch<i>` (`switch0`, `switch1`, …).
  - `switchValues`: if its first element is itself an array, button i uses `switchValues[i]` (or `switchValues[0]` when the array is shorter); otherwise the one list applies to all buttons. `restrictSwitchValues` works the same way.

### 5.27 `switch`

Service Switch: On (5.17.1). History `switch` (7.6).

### 5.28 `television`

Primary service Television (name, block subtype, marked primary):

| Characteristic | Kind / topics | Property |
|---|---|---|
| Active | B, `setActive`/`getActive`, `turnOffAfterms` | `active` |
| ActiveIdentifier | static 0; with `inputs`, the enumeration below | `activeIdentifier` |
| ConfiguredName | static `name` | none |
| SleepDiscoveryMode | static ALWAYS_DISCOVERABLE (1) | none |
| RemoteKey | event-only enumeration, published on `setRemoteKey`; values `remoteKeyValues`, default by HomeKit key code 0…15: `VOLUME_UP`, `VOLUME_DOWN`, `NEXT_TRACK`, `PREVIOUS_TRACK`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `SELECT`, `BACK`, `EXIT`, `PLAY_PAUSE`, `12`, `13`, `14`, `INFO` (HAP's codes 0 and 1 are rewind and fast-forward; the plugin labels them VOLUME_UP/DOWN) | `remoteKey` |
| DisplayOrder | with `inputs`, see below | none |

TelevisionSpeaker service, name `Volume`, subtype `volumeService`: Active static ACTIVE (1), VolumeControlType static ABSOLUTE (3), VolumeSelector as an event-only enumeration with the same value list on the same `setRemoteKey` topic (HomeKit's INCREMENT 0 publishes the first entry, `VOLUME_UP`; DECREMENT 1 the second). Both services are returned; the speaker is not linked.

`inputs` (array of `{ name, value }`): for each input n (1-based) an InputSource service named `name` or `Input <n>`, subtype n, flagged hidden, linked from the Television service, with Identifier = n, ConfiguredName = the name, IsConfigured = CONFIGURED (1), InputDeviceType = OTHER (0), InputSourceType = OTHER (0), TargetVisibilityState (internal, init SHOWN 0; a HomeKit write copies the value to CurrentVisibilityState), property `input<n>-visible`. ActiveIdentifier becomes an enumeration on `setActiveInput`/`getActiveInput`, init 0, whose list is `NONE` followed by each input's `value` (or n when absent), so HomeKit identifier n ↔ input n's value and 0 ↔ `NONE`. DisplayOrder is the base64 of the bytes `01 01 n` repeated for n = 1…N, with no separator items between entries.

Without `inputs`, `setActiveInput`/`getActiveInput` do nothing.

### 5.29 `temperatureSensor`

Service TemperatureSensor: CurrentTemperature (F, `getCurrentTemperature`, init 0, `currentTemperature`). Range: if `minTemperature` or `maxTemperature` is given, they replace the HAP min/max; otherwise the minimum is lowered to −100 (maximum stays HAP's 100). +status. History `weather` with `{temp}`.

### 5.30 `thermostat`

Service Thermostat:

| Characteristic | Condition | Kind / topics | Init | Property |
|---|---|---|---|---|
| Active | always (added even without topics, although not part of HAP's Thermostat definition) | B, `setActive`/`getActive`, `turnOffAfterms` | false | `active` |
| CurrentHeatingCoolingState | always | E[`OFF`,`HEAT`,`COOL`] `heatingCoolingStateValues`, `getCurrentHeatingCoolingState` | 0 | `currentHeatingCoolingState` |
| TargetHeatingCoolingState | always | E[`OFF`,`HEAT`,`COOL`,`AUTO`] **also** `heatingCoolingStateValues`; `restrictHeatingCoolingState` = allowed values | 0 | `targetHeatingCoolingState` |
| CurrentTemperature | always | as 5.29 | 0 | `currentTemperature` |
| TargetTemperature | always | F, `setTargetTemperature`/`getTargetTemperature`; range `minTemperature`/`maxTemperature` if given (HAP default 10–38) | 10 | `targetTemperature` |
| TemperatureDisplayUnits | always | E[`CELSIUS`,`FAHRENHEIT`] `temperatureDisplayUnitsValues`, set/get | 0 | `temperatureDisplayUnits` |
| CurrentRelativeHumidity | `getCurrentRelativeHumidity` | F | 0 | `currentRelativeHumidity` |
| TargetRelativeHumidity | get or set | F | 0 | `targetRelativeHumidity` |
| CoolingThresholdTemperature | get or set | F, range as TargetTemperature | 25 | `coolingThresholdTemperature` |
| HeatingThresholdTemperature | get or set | F, range as TargetTemperature | 20 | `heatingThresholdTemperature` |
| StatusFault | get | B | false | `statusFault` |

One `heatingCoolingStateValues` list serves both the current (3 states) and the target (4 states) characteristic; a 4-entry list gives the current state a 4th value that validation rejects (current's maximum is 2).

### 5.31 `valve`

Service Valve: ValveType static from `valveType` (`sprinkler` → IRRIGATION 1, `shower` → SHOWER_HEAD 2, `faucet` → WATER_FAUCET 3, anything else → GENERIC_VALVE 0); Active (B, `setActive`/`getActive`, `turnOffAfterms`, `active`); InUse (B, `getInUse`, `inUse`); then:

- if `setDuration` or `durationTimer`: SetDuration and RemainingDuration (6.8);
- else if `getRemainingDuration` or `turnOffAfterms`: RemainingDuration only;

plus +status. Keys: `valveType`, `durationTimer`, `minDuration`, `maxDuration`, `turnOffAfterms`.

### 5.32 `weatherStation`

All services use the block's `subtype`.

- TemperatureSensor named `serviceNames.temperature` or `<name> Temperature` (space): CurrentTemperature (5.29) and +status.
- If `getCurrentRelativeHumidity`: HumiditySensor `serviceNames.humidity` or `<name> Humidity`, with CurrentRelativeHumidity and +status.
- If `getAirPressure`: Eve AirPressureSensor `serviceNames.airPressure` or `<name> AirPressure`, as 5.1, with +status.
- If `getCurrentAmbientLightLevel`: LightSensor `serviceNames.ambientLightLevel` or `<name> Light Level`, as 5.18, with +status.
- A custom weather service (UUID `D92D5391-92AF-4824-AF4A-356F25F25EA1`), named `serviceNames.weather` or `<name> Weather`, added only if at least one of these is configured:

| Characteristic (Eve, from homebridge-lib) | UUID | Format | Topic | Init | Property |
|---|---|---|---|---|---|
| Condition | `CD65A9AB-85AD-494A-B2BD-2F380084134D` | string | `getWeatherCondition` | `-` | `weatherCondition` |
| Rain1h | `10C88F40-7EC4-478C-8D5A-BD0C3CCE14B7` | uint16 mm 0–200 | `getRain1h` | 0 | `rain1h` |
| Rain24h | `CCC04890-565B-4376-B39A-3113341D9E0F` | uint16 mm 0–2000 | `getRain24h` | 0 | `rain24h` |
| UvIndex | `05BA0FE0-B848-4226-906D-5B64272E05CE` | uint8 0–10 | `getUVIndex` | 0 | `uvIndex` |
| Visibility | `D24ECC1E-6FAD-4FB5-8137-5AF88BD5E857` | uint8 km 0–100 | `getVisibility` | 0 | `visibility` |
| WindDirection | `46F1284C-1912-421B-82F5-EB75008B167E` | string | `getWindDirection` | `-` | `windDirection` |
| WindSpeed | `49C8AE5A-A3A5-41AB-BF1F-12D5654F9F41` | float m/s 0–150 | `getWindSpeed` | 0 | `windSpeed` |
| MaximumWindSpeed | `6B8861E5-D6F3-425C-83B6-069945FFD1F1` | float m/s 0–150 | `getmaxWind` | 0 | `maxWind` |
| DewPoint | `095C46E2-278E-4E3C-B9E7-364622A0F501` | float °C −40–100 | `getDewPoint` | 0 | `DewPoint` |

Rain, UV and visibility are parsed as integers; wind and dew point as floats; condition and direction as text. History: `weather` with `{temp}`, `{humidity}`, `{pressure}`. (The docs give wind in km/h; homebridge-lib declares m/s; the plugin passes the number through.)

### 5.33 `custom`

`"type": "custom"` with a `services` array groups several of the types above into one accessory. For each entry, the effective configuration is the block's keys overlaid by the entry's keys (a shallow merge: an entry's `topics` replaces the block's `topics` entirely, it is not merged key by key). If the entry has no `subtype`, its subtype is its effective `name`. The services of all entries are concatenated, then one Accessory Information service is added from the block-level keys.

Some settings are always taken from the **block**, never from an entry: the MQTT connection (`url`, `username`, `password`, `mqttOptions`), `mqttPubOptions`, `logMqtt`, `debounceRecvms`, `optimizePublishing`, `codec`, `startPub`, `confirmationPeriodms`, `retryLimit`, `confirmationIndicateOffline`, and the `topics.getOnline` consulted by confirmation (a block without a `topics` object makes the source fail at the first confirmation timeout; treat that as "no getOnline"). Each entry has its own online state (from its own `getOnline`).

The docs say custom accessories are meant for simple services, not for multi-service types such as `weatherStation`. Two entries that both create a Battery service (no subtype) or two history services would collide **[host]** and the accessory fails.

### 5.34 Common to every type (after the type's own services)

On the primary service:

- `getName`: a Name characteristic fed from that topic (string, init `name`, property `name`). The docs note HomeKit does not show renames live.
- `getOnline`: the online state (6.5), property `online`.
- `nameOverride`: ConfiguredName characteristic set to that string (since 1.1.47; earlier versions sent service names to HomeKit, which overrode names users had changed, and was reverted).

### 5.35 Battery

- `"type": "battery"`: a Battery service (name, no subtype) with BatteryLevel (I, `getBatteryLevel`, `batteryLevel`), ChargingState (E `chargingStateValues`, `getChargingState`, init 0, `chargingState`) and StatusLowBattery (B, `getStatusLowBattery`, `statusLowBattery`), each only if its topic is set.
- Any other type: if `getBatteryLevel` or `getChargingState` is set, or `getStatusLowBattery` is set and the primary service does not already have StatusLowBattery, a Battery service named `<name>-battery` (no subtype) with the same three characteristics (each if its topic is set) is added. A sensor with +status and a battery level topic therefore has StatusLowBattery on both services, fed by the same topic.

Version 1.1.48 changed the service from BatteryService to Battery (same HAP UUID `00000096`; only the HAP-NodeJS class name changed).

---

## 6. Behaviour

### 6.1 Confirmation and retries (On only)

Confirmation applies **only to the On characteristic** of `lightbulb` (where On uses `setOn`), `switch`, `outlet` and `fan`, and only when `confirmationPeriodms` is truthy and a `getOn` topic exists. The docs describe it as a device-side echo: the device must republish on `getOn` whatever it received on `setOn`.

- When On is published (by a HomeKit write or an auto-off), any pending confirmation is cancelled, the retry counter is set to `retryLimit` (default 3), the expected value is the boolean on/off value before encoding (section 3.4), and a timer of `confirmationPeriodms` starts.
- Every message on `getOn` (after its decode chain) that matches the expected value while the timer runs cancels it.
- When the timer expires: unless `confirmationIndicateOffline` is false, and provided either no `getOnline` topic exists or `confirmationIndicateOffline` is true, the accessory is marked **offline** (once; logged "setting accessory state to offline"). Then, if retries remain, one is used and the value is published again with a fresh timer; otherwise "unresponsive, no confirmation on <topic>, expecting <value>" is logged and nothing more happens.
- A marked-offline accessory comes back online on the next message on `getOn` received while no confirmation timer is running (including the confirming message itself), logged "setting accessory state to online".
- The usual On state handling of `getOn` runs as well; the confirmation listener is in addition.

So at most 1 + `retryLimit` publishes are made per write. If there is no off value, an "off" write publishes nothing but still starts the timer (and can mark the accessory offline).

### 6.2 HomeKit reads while offline

While the accessory (or, for `custom`, the entry) is offline — from `getOnline` or from confirmation — every characteristic read that the plugin serves fails with an error, which HomeKit shows as **No Response** **[host]** (HAP status −70402, "service communication failure"). Event notifications continue. The docs note this is a workaround: the Home app only shows it after it reads again (reopening the app or the room).

### 6.3 Auto-off and reset

- `turnOffAfterms` on On (switch, outlet, light with `setOn`, fan) and on Active (every type with Active, including zones): whenever the characteristic is set to a truthy value — by HomeKit **or** by a received "on" (the source runs the same routine for both) — a timer starts (restarting any running one); when it fires, the state becomes off, the off value is published on the set topic (through confirmation for On), and HomeKit is updated. This needs a set topic: without one, nothing happens.
- `resetStateAfterms` on On, ContactSensorState, SmokeDetected, LeakDetected, and `turnOffAfterms` on MotionDetected: each received "on" (even when the state was already on) starts or restarts a timer; when it fires the state becomes off and HomeKit is updated; nothing is published.

### 6.4 Validation

Unless `validate` is false, a value is checked against the characteristic before it is pushed to HomeKit:

| HAP format | Rule |
|---|---|
| int, uint8, uint16, uint32 | must be an integer number, within min and max where they are set |
| float | must be a number, not NaN, within min/max |
| bool | must be exactly true or false |
| string | must be a string |
| anything else | accepted, with a log line "unable to validate <name>, format <f>" |

A rejected value is logged as "ignoring invalid value [v] for <characteristic> - <reason>" and not pushed. `validValues` restrictions are not checked here.

For the integer, float, string, boolean and enumeration characteristics, the plugin's **internal state is updated before validation**, so a HomeKit read afterwards returns the rejected value (for example NaN after a non-numeric payload); HAP-NodeJS then complains **[host]**. Internal characteristics of the light, fan and history (5.17.2–5.17.5, 7) return their default instead when the stored value fails validation. A replacement may reasonably serve the last valid value; this is the one place where copying the source exactly is not useful.

A received value is applied only when it differs from the current state (loosely: `1` and `true` count as equal), except for event-only characteristics.

### 6.5 Online state (`getOnline`)

Online starts true. A message matching the online value sets it true, one matching the offline value sets it false, anything else is ignored. Values: `onlineValue`/`offlineValue` when defined (an empty string counts as defined), otherwise the boolean on/off values of section 3.4 (with `onValue` but no `offValue`, the offline value is "nothing", which in the source matches only the literal text `null`). Typical use is a device's MQTT Last Will on that topic.

### 6.6 Start-up publishing

After the services are created, each `startPub` entry with a truthy `topic` is published with its `message` (an absent or falsy message publishes an empty payload). In the old object form, each key is a topic and its value the message. These go through the codec (property `startPub`) and `optimizePublishing`, not through `apply`. They are queued until the broker connection is up.

There is no other start-up activity: no state request, no published availability. State comes from retained messages.

### 6.7 Event-only enumerations

ProgrammableSwitchEvent (doorbell, stateless switch), RemoteKey and VolumeSelector have no read handler. For ProgrammableSwitchEvent every received value found in the list fires an event to HomeKit, even when equal to the previous one (that is how a second single press is delivered). RemoteKey and VolumeSelector are HomeKit-to-MQTT only.

### 6.8 Durations (valve and irrigation zones)

- **SetDuration**: init 1200 s, raised to `minDuration` if 1200 is below it, else lowered to `maxDuration` if above it. With a set topic it is a plain integer on the set topic and get topic; without one it is internal (HomeKit writes are kept and debug-logged). `minDuration`/`maxDuration` replace the characteristic's min/max (HAP default 0–3600).
- **RemainingDuration** keeps an end time, initially now. Reading it gives max(0, end − now) in whole seconds when the valve's InUse is true, else 0. Its value is pushed to HomeKit at each event below.
  - When the service has SetDuration: when InUse becomes IN_USE, end = now + SetDuration; with `durationTimer`, a timer of SetDuration seconds also starts, and when it fires the valve's Active is set INACTIVE (which publishes the off value on `setActive`). When InUse leaves IN_USE the timer is cancelled. So the timer only works if the device reports InUse on `getInUse`.
  - Without SetDuration but with `turnOffAfterms`: when Active becomes ACTIVE, end = now + `turnOffAfterms` (rounded down to whole seconds); the Active auto-off does the switching off.
  - A SetDuration change while running: new end = old end + (new − old), but no later than now + new; a running timer is restarted for the new remaining time.
  - A message on `getRemainingDuration` (integer r seconds): end = now + r, the value r is pushed as is, and a running timer is restarted for r seconds.

### 6.9 Debounce, duplicates, optimisation

- `debounceRecvms` is per subscription (per characteristic per topic). Codec and `apply` run on every message; only the final effect is delayed.
- Combined light payloads (HSV and the RGB family) are never republished when identical to the light's previous one; separate-topic writes are always published unless `optimizePublishing` is on.
- `optimizePublishing` compares the final payload text with the last one published on the same topic by this accessory block (any characteristic, including codec direct publishes).

### 6.10 Value translation tables (defaults)

| Characteristic | Default MQTT values by HomeKit index | Config key |
|---|---|---|
| SecuritySystemTargetState | `SA` `AA` `NA` `D` | `targetStateValues` |
| SecuritySystemCurrentState | `SA` `AA` `NA` `D` `T` | `currentStateValues` |
| TargetDoorState | `O` `C` | `doorTargetValues`, then `doorValues` |
| CurrentDoorState | `O` `C` `o` `c` `S` | `doorCurrentValues`, then `doorValues` |
| LockCurrentState | `U` `S` `J` `?` | `lockValues` |
| LockTargetState | `U` `S` | `lockValues` |
| PositionState | `DECREASING` `INCREASING` `STOPPED` | `positionStateValues` |
| ProgrammableSwitchEvent | `1` `2` `L` | `switchValues` |
| AirQuality | `UNKNOWN` `EXCELLENT` `GOOD` `FAIR` `INFERIOR` `POOR` | `airQualityValues` |
| CarbonDioxideDetected | `NORMAL` `ABNORMAL` | `carbonDioxideDetectedValues` |
| CarbonMonoxideDetected | `NORMAL` `ABNORMAL` | `carbonMonoxideDetectedValues` |
| ChargingState | `NOT_CHARGING` `CHARGING` `NOT_CHARGEABLE` | `chargingStateValues` |
| CurrentHeatingCoolingState | `OFF` `HEAT` `COOL` | `heatingCoolingStateValues` |
| TargetHeatingCoolingState | `OFF` `HEAT` `COOL` `AUTO` | `heatingCoolingStateValues` |
| CurrentHeaterCoolerState | `INACTIVE` `IDLE` `HEATING` `COOLING` | `currentHeaterCoolerValues` |
| TargetHeaterCoolerState | `AUTO` `HEAT` `COOL` | `targetHeaterCoolerValues` |
| CurrentHumidifierDehumidifierState | `INACTIVE` `IDLE` `HUMIDIFYING` `DEHUMIDIFYING` | `currentHumidifierDehumidifierState` |
| TargetHumidifierDehumidifierState | `HUMIDIFIER_OR_DEHUMIDIFIER` `HUMIDIFIER` `DEHUMIDIFIER` | `targetHumidifierDehumidifierState` |
| CurrentAirPurifierState | `INACTIVE` `IDLE` `PURIFYING` | `currentAirPurifierStateValues` |
| TargetAirPurifierState | `MANUAL` `AUTO` | `targetAirPurifierStateValues` |
| CurrentFanState | `INACTIVE` `IDLE` `BLOWING_AIR` | `currentFanValues` |
| TargetFanState | `MANUAL` `AUTO` | `targetFanStateValues` |
| LockPhysicalControls | `DISABLED` `ENABLED` | `lockPhysicalControlsValues` |
| SwingMode | `DISABLED` `ENABLED` | `swingModeValues` |
| TemperatureDisplayUnits | `CELSIUS` `FAHRENHEIT` | `temperatureDisplayUnitsValues` |
| RemoteKey / VolumeSelector | section 5.28 | `remoteKeyValues` |
| ActiveIdentifier (TV) | `NONE`, then each input's `value` or its number | `inputs` |

The `restrict…` keys (`restrictTargetState`, `restrictHeatingCoolingState`, `restrictHeaterCoolerState`, `restrictSwitchValues`, `restrictDehumidifierState`) are arrays of HomeKit indices that become the characteristic's valid values.

---

## 7. Eve history (fakegato-history)

History is the Eve app's log (Apple Home ignores it). Homeswift already has an Eve history implementation (`EveHistory`); this section says which entries the plugin records, not how fakegato stores them.

### 7.1 Which types, which Eve type

| MQTTThing type | Eve history type | Entries recorded |
|---|---|---|
| `switch` | `switch` | `{status: 1/0}` on every change of On |
| `outlet` | `energy` | `{power}` per `getWatts` message |
| `motionSensor` | `motion` | `{status: 1/0}`, section 7.3 |
| `contactSensor` | `door` | `{status}`, section 7.4 |
| `temperatureSensor` | `weather` | `{temp}` per message |
| `humiditySensor` | `weather` | `{humidity}` per message |
| `airPressureSensor` | `weather` | `{pressure}` per message |
| `weatherStation` | `weather` | `{temp}`, `{humidity}`, `{pressure}`, each from its own topic as a separate entry |
| `airQualitySensor` | `room`, or `room2` with `room2: true` | `room`: `{ppm}`, `{temp}`, `{humidity}`; `room2`: `{voc}`, `{temp}`, `{humidity}` |

Entry times are whole seconds since 1970 (UTC). Readings are taken from their own subscriptions (with the full decode chain) and parsed as floats; fakegato averages them over its 10-minute interval. `history: true` on any other type is ignored.

The history service is returned as one more service of the accessory, created with the accessory `name` as its display name.

### 7.2 Options

| `historyOptions` key | Effect |
|---|---|
| `size` | Maximum stored entries, default 4032 |
| `noAutoTimer: true`, or any `mergeInterval` | The 10-minute averaging and repeating timer is off |
| `noAutoRepeat: true` | For `motion` and `door`: the timer is off. For the others: the last value is not repeated when an interval had no data |
| `mergeInterval` | Minutes; motion only (7.3) |
| `persistencePath` | Directory of the history and counter files; absolute, or relative to the Homebridge storage directory; default that directory |

### 7.3 Motion

On every change of MotionDetected: Eve LastActivation (`E863F11A-079E-48FF-8F27-9C2605A29F52`, uint32 seconds) on the MotionSensor service becomes (now − the history's initial time). A "detected" entry is added at once and cancels any pending "clear" entry. A "clear" entry is added at once when `mergeInterval` is 0, otherwise it is held for `mergeInterval` minutes and added (with its original time) only if no new detection came in the meantime.

Five seconds after start-up, if the history holds entries, LastActivation is set from the most recent entry's time minus the initial time (the same applies to `switch` and `contactSensor`).

### 7.4 Contact sensor

On the ContactSensor service: LastActivation (as above), Eve TimesOpened (`E863F129-…`, uint32), OpenDuration (`E863F118-…`, uint32, always 0) and ClosedDuration (`E863F119-…`, uint32, always 0); on the history service: Eve ResetTotal (`E863F112-…`, uint32 seconds since 2001-01-01, writable). Each change records `{status}` with the HomeKit value (1 = open) and updates LastActivation; a change to open also increments TimesOpened and saves the counter file. An Eve write of ResetTotal sets TimesOpened to 0, saves, and logs "reset TimesOpened to 0".

### 7.5 Outlet energy

If `getTotalConsumption` is **not** configured, the plugin counts energy itself: TotalConsumption is added to the Outlet service (initial value from the counter file) and ResetTotal to the history service. For each `getWatts` message at whole-second time t with power P: if a previous reading (t₀, P₀) exists, total += P₀ · (t − t₀) / 3 600 000 kWh (the previous power held over the interval); then (t, P) becomes the previous reading, TotalConsumption is updated, the counter file saved, and `{power: P}` recorded. A ResetTotal write zeroes the total, saves, and logs "reset TotalConsumption to 0". With `getTotalConsumption`, the device's value is used and only `{power}` entries are recorded.

### 7.6 Switch

LastActivation on the Switch service, updated on each change of On, and `{status}` entries.

### 7.7 Counter file

`<persistence directory>/<first label of the host name>_<name>_cnt_persist.json`, JSON with `timesOpened` and `resetTotal` (contact) or `totalConsumption` and `resetTotal` (outlet). When missing, the counter starts at 0 and `resetTotal` at (now in seconds − 978307200), i.e. seconds since 2001-01-01 UTC. A write failure is logged ("cannot write file to save …"). fakegato's own history file lives in the same directory under its own naming (by fakegato convention the host name's first label, the accessory name and `_persist.json`; check against Homeswift's `EveHistory`).

---

## 8. Codecs

### 8.1 What a codec is

`codec` names a JavaScript module loaded into the bridge. Resolution: a value starting with `/` is an absolute path; a value not ending in `.js` names a built-in codec in the plugin's `codecs/` directory (`json`, `shellyAMAX`); any other value is a path relative to the Homebridge storage directory (where config.json is). A missing file logs "codec file … does not exist" and the accessory continues without a codec; a module without an init function logs an error and continues without a codec.

At start-up the module's init function is called once per accessory block with the logger, the block's configuration (which it may modify, including `topics`, before the services are built), a `publish(topic, message)` function that publishes directly (no `apply`, no encode, but `optimizePublishing` and logging do apply) and a `notify(property, value)` function. It returns `encode` and/or `decode` functions, either global or per property (a `properties` map of property name → `{encode, decode}`; the global function is used for properties without their own).

- `decode(message, info, output)` runs on every received message of every get topic (after JSONPath, before `apply`); `info` has `topic` (without any JSONPath part), `property` and `extendedTopic` (the topic object, or null). Its return value replaces the message; returning nothing drops it; it may instead call `output(value)` later, any number of times.
- `encode(message, info, output)` runs before each publish (after `apply`); same `info`; the return value is published; returning nothing publishes nothing unless it calls `output(value)` (now or later).
- `notify(property, value)` feeds `value` to every handler subscribed under that property name, bypassing JSONPath, decode, `apply` **and** debounce. It only reaches properties that have a get topic configured.

Codecs are arbitrary code; they can also run timers and publish on their own (the docs show a keep-alive publisher). The implementer cannot run them. The built-in `json` codec is declarative and can be reproduced (8.3).

### 8.2 Property names

The names under which characteristics subscribe and publish (used by codecs, `apply` state, and `jsonCodec.properties`): every "Property" entry in section 5, plus `startPub`, `online`, `watts` (outlet history subscription) and `AltSensorState`. The docs' list differs in places from the code (`ozonedensity` vs the code's `ozoneDensity`, `maxwindSpeed`/`Dewpoint` vs `maxWind`/`DewPoint`, television `input`XX vs `activeIdentifier`); the code's names are the ones that work. Light properties: `on`, `brightness`, `hue`, `saturation`, `colorTemperature` (separate mode), `HSV`, `RGB`, `RGBW`, `RGBWW`, `white`. Note that in HSV and RGB modes the internal hue/saturation/brightness carry no topic of their own.

### 8.3 Built-in `json` codec

Configured by `jsonCodec`:

| Key | Meaning |
|---|---|
| `properties` | Map of property name → dotted path into the JSON object (`state.power`). Only plain dot-separated keys; no arrays or JSONPath. |
| `fixed` | Object copied into every published message |
| `fixedByTopic` | Map of topic → object, used instead of `fixed` for that topic |
| `retain` | bool; keep each topic's message object between publishes so unchanged properties are re-sent |
| `diag` | bool; log every encode/decode call |

Encode, for a property with a path: take the pending object for the topic, or start one from a deep copy of `fixedByTopic[topic]`, else of `fixed`, else `{}`; set the value at the path, creating intermediate objects; (re)start a **50 ms** timer for the topic. When it fires, the object is serialised as compact JSON (keys in insertion order: fixed keys first, then properties in the order first set) and published on the topic; without `retain` the pending object is then discarded. Values keep their type: booleans as JSON booleans, numbers as numbers, the RGB string as a string. Several properties sharing a topic within 50 ms thus produce one message.

Decode, for a property with a path: parse the payload as JSON and walk the path; the value found (with its JSON type) is passed on; a missing key drops the message. A payload that is not JSON raises an error in the source (treat as dropped).

A property without a path, or a block without `jsonCodec` (which logs a warning "add jsonCodec object to configuration"), logs a diagnostic line on every call and drops the message (decode) or publishes nothing (encode).

### 8.4 Built-in `shellyAMAX` codec

A contributed codec for a Bosch AMAX alarm panel driven through Shelly relays and inputs, used with `securitySystem`. It reads `ShellyGen` (1 or 2) and an `AMAX` block (`setState.Armed`/`Disarmed` and `getState.Armed`/`Triggered`/`AltTriggered`, each with `name` (a Shelly topic prefix), `id`, `ACTIVE`; also `AMAX.ArmingDelay`), **replaces** `topics` with ones built from those (generation 1: `<name>/input/<id>` for the inputs and `<name>/relay/<id>/command` for the relay; generation 2: `<name>/status/input:<id>` and a fixed `/rcp`), and maps relay pulses and input states to the target and current security states. The code refers to variables and configuration keys that do not exist (for example a `Switch` topic for generation 2 and property names read from the configuration), so its behaviour is not well defined beyond generation 1's basic arming. Recommendation: do not port; log that the codec is unsupported.

---

## 9. Logging

The plugin logs through the accessory's logger (prefixed with the accessory name). Paraphrased:

- Always: MQTT client errors; codec load messages and failures; "enabling adaptive lighting"; "external control (…) disabling adaptive lighting"; offline/online changes from confirmation; "unresponsive, no confirmation"; validation rejections; "no MQTT dispatch handler for topic"; `apply` failures (they include the function text, topic and message); "unrecognized type"; "no services created"; exceptions while creating services (with a stack); counter resets and write failures; the AltSensorState warning.
- With `logMqtt`: the broker URL; the effective client options as JSON with `password` removed; every message received ("received MQTT: topic = payload"); every publish ("publishing MQTT: topic = payload"); `apply`, codec and JSONPath results; enumeration values received and unknown values.
- Debug: history loading, duration writes.

Secrets, which Homeswift must not log:

- `password` (also `MQTTTHING_PASSWORD`). The source removes only this key from the options dump.
- The source's options dump **does** include `username`, any key, certificate, passphrase or token placed in `mqttOptions` (including the file contents read from `keyfile`), and the URL, which may embed `user:password@`. A replacement should mask all of these: `password`, `username`, `mqttOptions.key`/`passphrase`/`password`/`cert`/`ca` contents, and credentials in `url`.
- Payloads may carry tokens for some devices; they are only logged under `logMqtt`.

Secret-named keys in the block: `password` (and any `password`/`passphrase`/`key` inside `mqttOptions`).

---

## 10. Test vectors

All examples assume `"accessory": "mqttthing"` and `"url": "mqtt://broker.local"`. "Publish X on T" means the bridge publishes payload X on topic T. Times are relative.

### 10.1 Switch, default booleans

```json
{ "accessory": "mqttthing", "type": "switch", "name": "Desk Lamp",
  "url": "mqtt://broker.local",
  "topics": { "getOn": "desk/lamp/state", "setOn": "desk/lamp/set" } }
```

| Event | Result |
|---|---|
| receive `true` on `desk/lamp/state` | On = true |
| receive `false` | On = false |
| receive `1`, `ON`, `True` | ignored |
| HomeKit writes On = true | publish `true` on `desk/lamp/set` |
| HomeKit writes On = false | publish `false` |
| Accessory UUID **[host]** | `FDD48A15-90FD-4926-ACE9-2D8B32F413A4`; Model `switch`; Manufacturer `mqttthing`; SerialNumber `<hostname>-Desk Lamp` |

### 10.2 Boolean encodings

| Config | HomeKit on → publish | off → publish | receive → state |
|---|---|---|---|
| `integerValue: true` | `1` | `0` | `1` on, `0` off, `true` ignored |
| `onValue: "ON", offValue: "OFF"` | `ON` | `OFF` | `ON` on, `OFF` off, `on` ignored |
| `onValue: "ON"` only | `ON` | nothing | `ON` on, everything else ignored |
| `onValue: "ON", otherValueOff: true` | `ON` | nothing | `ON` on, `xyz` off |
| default, codec/JSONPath yields JSON `true` | | | on |
| `integerValue: true`, JSONPath yields JSON `1` | | | on |
| `integerValue: true`, JSONPath yields JSON `true` | | | on (true counts as 1) |

### 10.3 Confirmation

```json
{ "accessory": "mqttthing", "type": "outlet", "name": "Heater Plug",
  "topics": { "getOn": "plug/heater/stat", "setOn": "plug/heater/cmnd" },
  "integerValue": true, "confirmationPeriodms": 1000, "retryLimit": 2 }
```

| Time | Event | Result |
|---|---|---|
| 0 | HomeKit On = true | publish `1` on `plug/heater/cmnd` |
| 1000 | no echo | accessory offline; publish `1` again (1 retry left) |
| 2000 | no echo | publish `1` again (0 left) |
| 2500 | HomeKit reads On | error, No Response |
| 3000 | no echo | log "unresponsive … expecting [1]"; nothing published |
| 5000 | receive `1` on `plug/heater/stat` | online again; On stays true |

With an echo at 300 ms instead, the timer is cancelled and nothing else happens.

### 10.4 Auto-off and reset

| Config | Event | Result |
|---|---|---|
| switch with `setOn`, `turnOffAfterms: 2000` | HomeKit On = true at 0 | publish `true`; at 2000 publish `false` and On = false |
| same | receive `true` on getOn at 0 | On = true; at 2000 publish `false` on setOn, On = false |
| motionSensor, `turnOffAfterms: 5000` | receive `true` at 0 and 3000 | MotionDetected 1 from 0; 0 at 8000; nothing published |
| contactSensor, `resetStateAfterms: 1000` | receive `true` | ContactSensorState 1 (open), 0 after 1 s |

### 10.5 Sensors and parsing

```json
{ "accessory": "mqttthing", "type": "temperatureSensor", "name": "Garden Sensor",
  "topics": { "getCurrentTemperature": "tele/garden/SENSOR$.AM2301.Temperature",
              "getStatusLowBattery": "tele/garden/battery_low" } }
```

| Received | Result |
|---|---|
| `{"Time":"2026-01-01T00:00:00","AM2301":{"Temperature":-3.5,"Humidity":80}}` on `tele/garden/SENSOR` | CurrentTemperature −3.5 (minimum −100 since no min/max keys) |
| `{"AM2301":{}}` | nothing usable: value missing, parsed NaN, rejected by validation |
| `true` on `tele/garden/battery_low` | StatusLowBattery 1 on the TemperatureSensor; a Battery service `Garden Sensor-battery` is **not** added (the primary already has StatusLowBattery) |
| Accessory UUID **[host]** | `88340EAC-AD4A-41FA-8899-19EA18B3E71D` |

With `"minTemperature": -20, "maxTemperature": 50`: `60` is rejected ("above maximum (50)"); `-25` rejected.

Parsing: Brightness `57.9` → 57; `40%` → 40; `abc` → rejected. Humidity `45.5` → 45.5. AirPressure `1013.2` → 1013.2; `650` → rejected (min 700).

### 10.6 Lightbulb, separate topics

```json
{ "accessory": "mqttthing", "type": "lightbulb-Dimmable", "name": "Hall Light",
  "topics": { "getBrightness": "hall/bri", "setBrightness": "hall/bri/set" } }
```

No `setOn`: "brightness 0 means off".

| Event | Result |
|---|---|
| receive `40` | On true, Brightness 40 |
| receive `0` | On false, Brightness stays 40 |
| HomeKit On = true | 20 ms later publish `40` on `hall/bri/set` |
| HomeKit On = false | publish `0` |
| HomeKit Brightness 70 while off | On true; publish `70` |
| HomeKit On = true after brightness 0 was set from HomeKit | brightness becomes 100; publish `100` |

### 10.7 Lightbulb, HSV

```json
{ "accessory": "mqttthing", "type": "lightbulb-HSV", "name": "Strip",
  "topics": { "getHSV": "strip/hsv", "setHSV": "strip/hsv/set" } }
```

| Event | Result |
|---|---|
| HomeKit writes Hue 120, Saturation 100, Brightness 50 within 20 ms | one publish `120,100,50` on `strip/hsv/set` |
| then HomeKit On = false | publish `120,100,0` |
| then HomeKit On = true | publish `120,100,50` |
| the same values again | nothing (duplicate) |
| receive `240,100,30` | Hue 240, Saturation 100, Brightness 30, On on (see Gaps about On) |
| receive `240,100` | ignored |

### 10.8 Lightbulb, RGB family

HomeKit (H, S, B) → payloads (all with the light on):

| H, S, B | RGB | `hex: true` | `hexPrefix: "#"` | RGBW | RGB + `setWhite` |
|---|---|---|---|---|---|
| 0, 100, 100 | `255,0,0` | `ff0000` | `#ff0000` | `255,0,0,0` | `255,0,0` and `0` |
| 120, 100, 50 | `0,128,0` | `008000` | `#008000` | `0,128,0,0` | `0,128,0` and `0` |
| 240, 50, 100 | `128,128,255` | `8080ff` | `#8080ff` | `0,0,127,128` | `0,0,127` and `128` |
| 30, 60, 80 | `204,143,82` | `cc8f52` | `#cc8f52` | `122,61,0,82` | `122,61,0` and `82` |
| 0, 50, 100 | `255,128,128` | `ff8080` | `#ff8080` | `127,0,0,128` | `127,0,0` and `128` |
| any, light off, no `setOn` | `0,0,0` | `000000` | `#000000` | `0,0,0,0` | `0,0,0` and `0` |

Received → HomeKit:

| Mode | Received | Hue, Sat, Bri |
|---|---|---|
| RGB | `255,0,0` | 0, 100, 100 |
| RGB | `0,0,255` | 240, 100, 100 |
| RGB | `255,165,0` | 38, 100, 100 |
| RGB, `hexPrefix: "#"` | `#0000ff` | 240, 100, 100 |
| RGB, `hexPrefix: "#"` | `0000ff` | ignored (prefix missing) |
| RGBW | `127,0,0,128` | 0, 49, 100 (not 50: the round trip is lossy) |
| RGBW | `255,0,0` | ignored (3 parts) |

RGBWW with default warm/cold whites:

| HomeKit H, S, B | Publish (`r,g,b,ww,cw`) | with `switchWhites` | with `noWhiteMix` |
|---|---|---|---|
| 0, 0, 100 (white) | `0,0,0,127,127` | `0,0,0,127,127` | `0,0,0,127,127` |
| 240, 100, 100 (blue) | `0,0,255,0,0` | `0,0,255,0,0` | `0,0,255,0,0` |
| 30, 60, 100 (warm) | `0,1,0,227,26` | `0,1,0,26,227` | `0,0,0,227,26` |

| Received | Hue, Sat, Bri |
|---|---|
| `0,0,0,127,127` | 25, 31, 89 |
| `0,0,0,255,0` | 30, 76, 100 |

### 10.9 Lightbulb, white only

```json
{ "accessory": "mqttthing", "type": "lightbulb-White", "name": "Shelf",
  "topics": { "getWhite": "shelf/w", "setWhite": "shelf/w/set" } }
```

| HomeKit Brightness (on) | Publish | with `hexPrefix: "#"` |
|---|---|---|
| 1 | `3` | `#03` |
| 50 | `128` | `#80` |
| 99 | `253` | `#fd` |
| 100 | `255` | `#ff` |
| any, On = false | `0` | `#00` |

| Received | Brightness, On |
|---|---|
| `0` | 0, false |
| `1` | 0, false |
| `3` | 1, true |
| `128` | 50, true |
| `254` | 99, true |
| `255` | 100, true |
| `12,13` | ignored |

### 10.10 Garage door

```json
{ "accessory": "mqttthing", "type": "garageDoorOpener", "name": "Garage",
  "topics": { "setTargetDoorState": "garage/target/set", "getTargetDoorState": "garage/target",
              "getCurrentDoorState": "garage/current", "getObstructionDetected": "garage/obstruction" } }
```

| Event | Result |
|---|---|
| start | TargetDoorState 0 (open), CurrentDoorState 1 (closed) |
| HomeKit TargetDoorState = 1 | publish `C` on `garage/target/set` |
| receive `c` on `garage/current` | CurrentDoorState 3 (closing) |
| receive `C` | CurrentDoorState 1 |
| receive `X` | ignored |

With `getDoorMoving: "garage/moving"` in place of `getCurrentDoorState`: target 1, receive `true` → after 1 s CurrentDoorState 3 (closing); receive `false` → after 1 s 1 (closed); HomeKit target 0 while not moving → after 1 s 0 (open).

### 10.11 Security system

```json
{ "accessory": "mqttthing", "type": "securitySystem", "name": "Alarm",
  "topics": { "setTargetState": "alarm/set", "getTargetState": "alarm/target", "getCurrentState": "alarm/state" },
  "restrictTargetState": [1, 3] }
```

| Event | Result |
|---|---|
| start | target 3, current 3 |
| HomeKit target = 1 | publish `AA` on `alarm/set` |
| receive `AA` on `alarm/state` | current 1 |
| receive `T` | current 4 (triggered) |
| receive `D` on `alarm/target` | target 3 |

### 10.12 Thermostat

```json
{ "accessory": "mqttthing", "type": "thermostat", "name": "Living Thermostat",
  "topics": { "getCurrentHeatingCoolingState": "th/mode", "setTargetHeatingCoolingState": "th/target/set",
              "getCurrentTemperature": "th/temp", "setTargetTemperature": "th/setpoint/set",
              "getTargetTemperature": "th/setpoint" },
  "minTemperature": 5, "maxTemperature": 30, "restrictHeatingCoolingState": [0, 1] }
```

| Event | Result |
|---|---|
| HomeKit TargetHeatingCoolingState = 1 | publish `HEAT` on `th/target/set` |
| HomeKit TargetTemperature = 21.5 | publish `21.5` on `th/setpoint/set` |
| receive `HEAT` on `th/mode` | CurrentHeatingCoolingState 1 |
| receive `19.25` on `th/temp` | CurrentTemperature 19.25 |
| receive `35` on `th/setpoint` | rejected (above 30) |
| characteristics present | Active (always), the two modes, CurrentTemperature, TargetTemperature, TemperatureDisplayUnits |

### 10.13 Stateless switch with buttons

```json
{ "accessory": "mqttthing", "type": "statelessProgrammableSwitch", "name": "Hall Remote",
  "topics": { "getSwitch": ["remote/b1", "remote/b2"] },
  "switchValues": [["s", "d", "l"]], "labelType": "numerals" }
```

| Item | Result |
|---|---|
| services | ServiceLabel `Hall Remote` (numerals); `Hall Remote 0` subtype 1, index 1; `Hall Remote 1` subtype 2, index 2 |
| value lists | both buttons use `s`,`d`,`l` (the outer array has one element, so button 2 falls back to it) |
| receive `d` on `remote/b2` | button 2 DOUBLE_PRESS event; again `d` → another event |
| receive `1` on `remote/b1` | ignored |

### 10.14 Television

```json
{ "accessory": "mqttthing", "type": "television", "name": "Lounge TV",
  "topics": { "setActive": "tv/power/set", "getActive": "tv/power",
              "setActiveInput": "tv/input/set", "getActiveInput": "tv/input", "setRemoteKey": "tv/key" },
  "inputs": [ { "name": "HDMI 1", "value": "hdmi1" }, { "name": "Antenna" } ] }
```

| Event | Result |
|---|---|
| services | Television; TelevisionSpeaker `Volume`/`volumeService`; InputSource `HDMI 1` subtype 1; InputSource `Antenna` subtype 2 |
| DisplayOrder | `AQEBAQEC` (bytes 01 01 01 01 01 02); three inputs would give `AQEBAQECAQED` |
| HomeKit ActiveIdentifier = 1 | publish `hdmi1` on `tv/input/set` |
| HomeKit ActiveIdentifier = 2 | publish `2` |
| receive `hdmi1` on `tv/input` | ActiveIdentifier 1 |
| HomeKit RemoteKey = 4 (arrow up) | publish `UP` on `tv/key` |
| HomeKit RemoteKey = 15 | publish `INFO` |
| HomeKit VolumeSelector = 1 | publish `VOLUME_DOWN` on `tv/key` |
| HomeKit Active = 1 | publish `true` on `tv/power/set` |

### 10.15 Valve with duration timer

```json
{ "accessory": "mqttthing", "type": "valve", "valveType": "sprinkler", "name": "Lawn",
  "topics": { "setActive": "lawn/set", "getActive": "lawn/active", "getInUse": "lawn/inuse" },
  "durationTimer": true, "minDuration": 60, "maxDuration": 600 }
```

| Time | Event | Result |
|---|---|---|
| start | | SetDuration 600 (1200 clamped down to the maximum), range 60–600; RemainingDuration 0 |
| 0 | HomeKit Active = 1 | publish `true` on `lawn/set` |
| 2 s | receive `true` on `lawn/inuse` | InUse 1; RemainingDuration 600; timer 600 s |
| 102 s | HomeKit reads RemainingDuration | 500 |
| 602 s | timer | Active 0, publish `false` on `lawn/set` |

### 10.16 Outlet energy counter

`history: true`, `getWatts: "plug/power"`, no `getTotalConsumption`, counter file absent:

| Time (s) | Received | TotalConsumption (kWh) | History entry |
|---|---|---|---|
| 0 | `100` | 0 | `{power: 100}` |
| 36 | `200` | 0.001 | `{power: 200}` |
| 72 | `0` | 0.003 | `{power: 0}` |

### 10.17 Publishing options and start-up

- `optimizePublishing: true`: HomeKit On true, false, false → publishes `true`, `false` (the second `false` is suppressed).
- `"startPub": [ { "topic": "dev/reset", "message": "1" }, { "topic": "dev/hello" } ]` → at start-up publish `1` on `dev/reset` and an empty payload on `dev/hello`.
- `"mqttPubOptions": { "retain": true }` → every publish has the retain flag.

### 10.18 Online topic

`"getOnline": "dev/lwt"`, `"onlineValue": "Online"`, `"offlineValue": "Offline"`: receive `Offline` → reads fail (No Response); receive `Online` → reads succeed; receive `online` → ignored.

### 10.19 Custom accessory

```json
{ "accessory": "mqttthing", "type": "custom", "name": "Porch", "integerValue": true,
  "services": [
    { "type": "switch", "name": "Porch Light", "topics": { "getOn": "porch/light", "setOn": "porch/light/set" } },
    { "type": "motionSensor", "name": "Porch PIR", "topics": { "getMotionDetected": "porch/pir" } } ] }
```

Result: one accessory `Porch` (Model `custom`) with a Switch named `Porch Light`, subtype `Porch Light`, and a MotionSensor `Porch PIR`, subtype `Porch PIR`. Both use `1`/`0` (inherited `integerValue`).

### 10.20 `apply` (for reference)

| Topic object | Received / written | Result |
|---|---|---|
| get Brightness, body divides by 2.55 and rounds | receive `128` | Brightness 50 |
| set Brightness, body multiplies by 2.55 and rounds | HomeKit 50 | publish `128` |
| get CurrentTemperature, body parses JSON and returns `temperature` with one decimal | receive `{"temperature":21.46}` | 21.5 |
| any get, body returns nothing | any | dropped |

### 10.21 JSON codec

```json
{ "accessory": "mqttthing", "type": "lightbulb", "name": "Desk RGB",
  "topics": { "getOn": "desk/rgb/state", "setOn": "desk/rgb/cmd",
              "getRGB": "desk/rgb/state", "setRGB": "desk/rgb/cmd" },
  "codec": "json",
  "jsonCodec": { "properties": { "on": "light.on", "RGB": "light.colour" }, "fixed": { "v": 2 } } }
```

| Event | Result |
|---|---|
| HomeKit On = true, then Hue 0 / Sat 100 / Brightness 100 within 50 ms | one publish on `desk/rgb/cmd`: `{"v":2,"light":{"on":true,"colour":"255,0,0"}}` |
| receive `{"light":{"on":false,"colour":"0,0,255"}}` on `desk/rgb/state` | On false; Hue 240, Sat 100, Brightness 100 |
| receive `{"other":1}` | both handlers drop it |

---

## 11. Gaps, quirks and open points

1. **`apply` and external codecs** run user JavaScript (section 3.3, 8.1). They cannot be run as is. A decision is needed: refuse with a log line, a small expression subset, or an embedded engine (none available on Linux in the standard toolchain). Only the `json` codec is reproducible natively.
2. **On in HSV/RGB modes without `setOn`**: the source sets On to the number 1 or 0 from received colour values, which its own validation rejects (On must be a boolean); the internal state becomes 1/0 and a HomeKit read then returns the default (false). In practice, with validation on, MQTT never turns such a light on in HomeKit (and can make it read as off). Intended behaviour: On = (brightness > 0) as a boolean. Recommend the intended behaviour.
3. **`carbonMonoxideSensor`** with `getcarbonMonoxideLevel` or `getcarbonMonoxidePeakLevel` crashes accessory creation in the source; the documented keys `getCarbonMonoxideLevel`/`getCarbonMonoxidePeakLevel` are ignored for this type. Recommend supporting the documented keys.
4. **`restrictDehumidifierState`** makes the dehumidifier fail to create in the source. Recommend applying it to TargetHumidifierDehumidifierState.
5. **`fanv2` CurrentFanState** is only created when a block-level `getCurrentFanState` key exists. Recommend `topics.getCurrentFanState` (accepting the block-level key too).
6. **Irrigation zone StatusFault** subscribes to the system's `getStatusFault` instead of the zone's.
7. **Value key spellings** differ between code, schema and docs (air purifier, fanv2, codec property names). Section 5 gives what the code reads.
8. **Booleans with only `onValue`**: the docs say other values mean off; the code ignores them unless `otherValueOff`. Section 3.4 describes the code.
9. **Loose equality**: matching follows JavaScript `==` (section 3.4). Edge cases beyond those listed (e.g. numbers against texts with surrounding spaces, which JavaScript treats as numerically equal) are unlikely in practice.
10. **Invalid values in the state** (section 6.4): reads may return values HomeKit rejects. Serving the last valid value is recommended.
11. **JSONPath and JSON codec on non-JSON payloads** raise uncaught errors in the source; treat as dropped messages.
12. **Garage initial state**: target OPEN and current CLOSED at start-up (Home may show "Opening…" until the first retained message).
13. **Thermostat `Active`** is always added although HAP's Thermostat does not list it; keep it for parity (and so that identifiers stay the same) or drop it as a deliberate change.
14. **Hidden InputSource** services, the TV's DisplayOrder without item separators, and RemoteKey codes 0/1 labelled VOLUME_UP/DOWN are as the source does them.
15. **Eve history file naming and the history service's subtype** come from fakegato-history, which I did not read; align with Homeswift's existing `EveHistory`.
16. **HAP-NodeJS colour-temperature conversion** (internal ColorTemperature, 5.17.6) is HAP-NodeJS's function; Homeswift has `ColorUtils`. I did not check its exact numbers.
17. **Precise float formatting** of published values follows JavaScript's number-to-text (shortest round-trip form). HomeKit's values are normally already rounded to the characteristic's step.
18. **Homebridge 1.3.0 check** for Adaptive Lighting is treated as always satisfied.
19. **No availability topic is published** by the bridge itself apart from the MQTT will (`WillMsg`), which is sent when the client drops without disconnecting; there is no "online" counterpart.
20. **`caption`** is documented but unused.
