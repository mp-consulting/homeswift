# XiaomiMiot: functional specification (clean room)

## 0. Provenance

| Source | URL | Commit / date read | Version | Licence and copyright line |
|---|---|---|---|---|
| homebridge-miot (merdok) | https://github.com/merdok/homebridge-miot | `2186f61f2081ec1a51c0388e3072b79741aebb0a`, committed 2026-10-31 | package `homebridge-miot` 2.1.0 | MIT. LICENSE reads "Copyright (c) 2025 Marcin"; package author `merdok` |
| Xiaomi-cloud-tokens-extractor (PiotrMachowski) | https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor | `c4db715dace9806e905153c2977608873e8ab7c9`, committed 2025-10-26 | none published | MIT. "Copyright (c) 2020 Piotr Machowski" |
| OpenMiHome mihome-binary-protocol | https://github.com/OpenMiHome/mihome-binary-protocol (`doc/PROTOCOL.md`) | `7dd673d7d752c44bc8ff69d2c1753310fd26f1c1`, committed 2017-02-25 | none | The repository's LICENSE is **GPL-3.0**. Only interface facts (a packet layout) are taken from its document; no text is reproduced. |
| miot-spec.org, the MIoT spec registry | `https://miot-spec.org/miot-spec-v2/instances?status=released`, `…/instance?type=<urn>`, `…/spec/services`, `…/spec/properties` | fetched 2026-11-07 | released list: 16208 entries, 14950 models; `status=all`: 48191 entries | Xiaomi's public registry. The saved fixtures are its responses, unmodified. |

The spec writer wrote this document. It contains no source code from any of the above. JSON keys, URLs, header names,
method names, URNs, option names and file names are interface facts. Every source was cloned shallowly into an empty
directory outside the repository and read as data; no npm, node or repository script was run. python-miio and
XiaoMi/ha_xiaomi_home were not opened, cloned or searched.

The test vectors in section 12 were computed by the spec writer with `python3 -I` (hashlib, hmac, base64, an RC4 the
writer wrote from the textbook algorithm) and the `openssl enc -aes-128-cbc` command (OpenSSL 4.1.0). The RC4 was
checked against the well-known vector (key `Key`, plaintext `Plaintext` → `BBF316E8D940AF0AD3`) and, for the
1024-byte drop, against LibreSSL 3.3.6's `openssl enc -rc4` with a 16-byte key. Every vector was checked by decoding
it back.

Marks: **[homebridge-miot]**, **[extractor]**, **[OpenMiHome]**, **[miot-spec]** say where a fact comes from;
**[vector]** a value the spec writer computed; **[Homeswift]** a decision for this plugin that no source dictates;
**[unverified]** something no source establishes and that needs a real device or account to confirm.

Fixtures (section 13) were saved outside the repository by the spec writer: one `<model>.json` per model, exactly as
`…/instance?type=<urn>` served it, and `instances-sample.json`, an excerpt of the released instances list with every
entry of those models. The implementer copies them into the plugin's `Tests`.

---

## 1. Overview and scope

The plugin is `Plugins/XiaomiMiot`, target `HomeswiftXiaomiMiot`, platform name **`miot`** (homebridge-miot's
`pluginAlias`, `singular: true`), display name "Xiaomi". It controls Xiaomi Mi Home Wi-Fi devices that speak MIoT
over the miIO LAN protocol, and the older Mi-branded robot vacuums that speak only the miIO vacuum command set.

- **Device Id** = the Xiaomi device id (`did`), a decimal string for Wi-Fi devices (`"123456789"`). Accessory Id
  `miot:<did>`. [Homeswift]
- **Serial Number** = the MAC address from the cloud's device list (uppercase hex, no separators) when there is one,
  else the did. [Homeswift; CLAUDE.md rule] homebridge-miot uses the did. [homebridge-miot]
- **Transport.** Control and polling stay on the LAN (miIO over UDP 54321). The Xiaomi cloud is used for sign-in, the
  device list (tokens, IPs, MACs, models, names) and nothing at run time, unless a device's `micloud.forceMiCloud` is
  true (section 4.11, flagged).
- **Mapping.** Spec-driven: the device's MIoT instance spec is fetched from miot-spec.org once and kept on the bridge;
  services and properties map to HomeKit by their type URNs (section 7), with a short list of curated overrides
  (section 7.9).
- **Setup.** Three ways in (section 3): a QR code scanned with the Mi Home app (first), an account password with a
  two-factor code, or one 32-hex token pasted per device. Discovery is the miIO hello broadcast plus the cloud list.
- **Vacuums.** Every Mi Home robot vacuum belongs here: MIoT robots through their spec, older Roborock-family robots
  through the legacy miIO commands. Both take `Plugins/Roborock`'s HomeKit shape (section 8).
- **Out of scope for v1** (section 10): miIO-only devices other than vacuums, Bluetooth/BLE-mesh and Zigbee
  sub-devices behind a gateway, cloud-only devices, Matter options of homebridge-miot, cameras, IR remotes.

---

## 2. Configuration

### 2.1 Platform block (homebridge-miot shape, read as it is)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `platform` | string | — | Always `miot`. |
| `name` | string | — | Log name. |
| `devices` | array | required by homebridge-miot | The devices, 2.2. Homeswift also runs with none (Setup fills `_accessories`). |
| `micloud` | object | absent | Global cloud settings, below. Every key is also accepted per device (`devices[].micloud`), the device's own key winning over the global one key by key. [homebridge-miot] |
| `micloud.username` | string | absent | Account email, phone number or user id. |
| `micloud.password` | string | absent | Account password. **Secret** (secret-named key, sealed by the runtime). |
| `micloud.country` | enum `cn de sg tw us ru in i2` | `cn` | The cloud region (4.1). |
| `micloud.forceMiCloud` | boolean | false | Send every request for the device through the cloud instead of the LAN (4.11). |
| `micloud.timeout` | number, ms | 5000 | Cloud request timeout. Raised to 2000 when lower; lowered to the polling interval when higher. [homebridge-miot] |
| `micloud.useCachedSession` | boolean | false | Use the session saved by the Homebridge settings page (`.miot_micloud/cachedSession`, 3.6) instead of logging in. |
| `micloud.unencryptedRequests` | boolean | false | Not in the schema; read by the code. Sends the older unsigned-body request form (4.7). |
| `nameLanguage` | enum `auto zh-Hans zh-Hant de ru en` | absent | Language of generated service names, fetched from miot-spec.org's localisation endpoint. Read and ignored by Homeswift v1 (English names). |
| `fans` | any | — | A pre-`devices` name; homebridge-miot only checks it exists. Ignored. |

### 2.2 `devices[]` general keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | `"Miot device"` | The accessory's Name. Becomes the Core `name` in `_accessories`. |
| `ip` | string | required | The device's LAN address. |
| `token` | string, 32 hex | required | The device's miIO token. **Secret.** |
| `deviceId` | string | absent | The did. Learned from the hello reply when absent. |
| `stableId` | string | absent | homebridge-miot derives its HAP UUID from it (lowercased) instead of token+ip+deviceId. Homeswift's ids come from the did; read for migration only (11.3). |
| `model` | string | absent | The model; skips identification when given. |
| `micloud` | object | absent | Per-device cloud settings (2.1). |
| `pollingInterval` | number | 15 s in the code; the schema shows 10 and the README 15 | Values below 500 are seconds, others milliseconds; values under 1000 ms after that conversion are ignored. [homebridge-miot] |
| `propertyChunkSize` | number 1–14 | 14 (a model may lower it: `zhimi.airp.cpa4` uses 3) | Properties per `get_properties` request (5.9). |
| `deviceEnabled` | boolean | true | false: the accessory is published but never polled. |
| `prefsDir`, `deepDebugLog`, `silentLog`, `nameLanguage` | | | Read and ignored by Homeswift. |
| `matterEnabled`, `matterConnection`, `matterHomeKitDockSwitch`, `matterMode`, `matterRoomDiscovery`, `matterRoomDiscoveryMiCloud`, `matterRooms`, `matterRoomDiscoveryInterval` | | | homebridge-miot's Homebridge-2 Matter robot options. Read and ignored: Homeswift's Matter bridge maps the vacuum's Fan v2 (8.4). |
| `customAccessory` | boolean | false | An accessory with no automatic services, filled only by `actionButtons`, `propertyControl`, `propertyMonitor`. |
| `onlyMainService` | boolean | false | Only the primary service; the extra controls may still add services. |

### 2.3 Extra controls

Every flag below adds services beside the primary one. In homebridge-miot some default to true; **in Homeswift every
flag that adds a service defaults to false** [Homeswift, settled decision], and each becomes a Plugin Accessory
Setting (2.4) whose `x-kinds` are the device kinds listed. `childLockControl` and `showTemperature` gate parts of the
base mapping, not extra services, and keep homebridge-miot's default true [Homeswift; see 14.9].

| Flag | homebridge-miot default | Device kinds | What it adds (7.8 says how each control behaves) |
|---|---|---|---|
| `buzzerControl` | true | all | A Switch "Buzzer" on `alarm:alarm`. |
| `ledControl` | true | all | "Led" on the indicator light: `indicator-light:on` (Switch), else `indicator-light:brightness`, else `indicator-light:indicator-light` (a range → Lightbulb slider, a list → one switch per value). |
| `childLockControl` | true | fan, airPurifier, humidifier, dehumidifier, heater, airConditioner | Lock Physical Controls on the primary service, from `physical-controls-locked:physical-controls-locked`. false removes it. |
| `modeControl` | true | all | "Mode": one switch per value of the main service's `mode`, active only while the device is on. |
| `screenControl` | true | airPurifier, humidifier | "Screen" on `screen:on`, else `screen:brightness`. |
| `fanLevelControl` | false | fan, airPurifier, humidifier, dehumidifier, airConditioner, ceilingFan | "Fan Level": one switch per `fan-level` value (an air purifier's are active only in its Favorite mode). |
| `swingControl` | false | fan, airConditioner | "Horizontal Swing" / "Vertical Swing" switches. |
| `moveControl` | false | fan | Stateless "Move left/right" (and "up/down") switches writing `left`/`right`/`up`/`down` to the vendor `swing-step-move` (and `v-swing-step-move`) property. |
| `ioniserControl` | false | fan, airPurifier | "Ioniser" on `anion`, active only while on. |
| `offDelayControl` | false | fan, heater, outlet, ceilingFan | "Off delay" on the off-delay or countdown property: a Lightbulb whose brightness is the delay (a bool property: a Switch). |
| `heaterControl` | true | freshAirSystem (out of scope v1) | A heater switch. |
| `heatLevelControl` | false | freshAirSystem (out of scope v1) | Heat level switches. |
| `motorControl` | true | curtain | "Motor Control": one switch per `motor-control` value (stateless: the property is write-only). |
| `horizontalAngleButtons` | false | fan | `true` or an array of integers 1–360: stateful switches that set `horizontal-angle` to that value (and turn swing on). |
| `verticalAngleButtons` | false | fan | The same for `vertical-angle`. |
| `showTemperature` | true | outlet | Shows the outlet's temperature sensor when the spec has one. |
| `suppressAutoServiceCreation` | `[]` | all | Strings among `temperature`, `relativeHumidity`, `illumination`: leave out that automatic sensor. |
| `pm25Breakpoints` | `[7,15,30,55]` | airPurifier, airMonitor | Four strictly increasing integers: PM2.5 limits of Excellent, Good, Fair, Inferior; above the last is Poor. Invalid → default with a warning. |
| `co2AbnormalThreshold` | 1000 | airMonitor | ppm above which Carbon Dioxide Detected is abnormal. Not a number → default with a warning. |
| `foodAmount` | 7 | petFeeder | Out of scope v1. |

**`actionButtons`** (default false). `true`: one stateless switch per action of the spec. An array of strings: action
names or ids. An array of objects: `{"action": "<name or id>", "name": "<switch name>", "params": [ … ]}`, only
`action` required. Each switch, when turned on, runs the action (5.9 `action`) with `params`, then turns itself off
after 100 ms. An unknown action is skipped with a warning. Default name: the action's name after the colon, words
capitalised (`fan:toggle` → "Toggle"). [homebridge-miot]

`params` entries: a plain value goes to the action's n-th `in` piid; an object `{"piid": n, "value": v}` is sent as
it is; null values are dropped. The action is sent with `in` as a list of `{piid, value}` objects. Two models want the
values themselves (`ijai.vacuum.v3`, `ijai.vacuum.v18`). [homebridge-miot]

**`methodButtons`** (default `[]`). An array of strings or of `{"method": "<miIO method>", "name": …, "params": [ … ]}`.
Each is a stateless switch that sends the raw miIO method with `params` and logs the result at info. A reply that is
or contains `unknown_method` is an error (logged at warn). [homebridge-miot]

**`propertyControl`** (default `[]`). An array of property names/ids or of objects:

| Key | Meaning |
|---|---|
| `property` | Required. A property name (`fan:anion`, 6.3) or id `siid.piid` (`"2.7"`). |
| `name` | The service name. Default: a friendly name from the property name; a fixed value is appended as ` - <value>`. |
| `value` | A fixed value: the control becomes a switch that sets exactly this value (stateful: on while the property equals it; write-only properties: stateless). A string is converted to the property's format (`"true"` → true, `"2"` → 2). |
| `linkedProperty` | Another property: the control reads as off unless it is true (a bool) or equals `linkedPropertyValue`; turning the control on first sets a bool linked property to true. |
| `linkedPropertyValue` | The linked property's required value. |
| `config` | For a value-range property: `{"type": "fan"}` makes a Fan v2 with Rotation Speed instead of the default Lightbulb with Brightness. |

The kind of control follows the property: not writable → nothing (warning); a fixed `value` → switch; bool → Switch;
value range → Lightbulb (or Fan v2) whose percentage is the range position (a `[x,100,1]` range is used as a
percentage directly), on = value > 0, off writes the range minimum, on writes the value it had before off or the
range maximum; value list → one switch per value, named `<name> - <value description>`; write-only without a value →
nothing. [homebridge-miot]

**`propertyMonitor`** (default `[]`). An array of property names/ids or of objects with `property`, `name`, `value`,
`valueOperator`, `linkedProperty`, `linkedPropertyValue`. A `value` makes an Occupancy Sensor that detects when the
comparison holds; `valueOperator` is `equal` (default; also `=`, `==`), `less` (`below`, `<`), `greater` (`above`,
`>`), `lessOrEqual` (`belowOrEqual`, `<=`), `greaterOrEqual` (`aboveOrEqual`, `>=`) or `contains` (`[]`, `[]=`: the
value is a list that contains the property's value). Without a value: a Temperature Sensor for a property in
`celsius`, else a Light Sensor whose lux is the value (a bool as 0/1; bounds from the range, else 0–100000). String
properties are logged at info when they change. Every monitor carries Status Active (false while unreachable or the
linked property does not hold). [homebridge-miot]

### 2.4 Homeswift canonical shape

The bridge writes Accessory Settings in `_accessories` by Device Id (docs/adr/0001). `canonicalSettings` turns each
`devices[]` entry into `_accessories["<did>"]` and drops the list:

- `name` → Core `name`. `ip` → Plugin Accessory Setting `ip`. `model` → `model`. Every option of 2.2 and 2.3 that
  Homeswift reads → the key of the same name. Keys read and ignored are dropped.
- `token` → the device's credentials in the vault (`{"token": …}` under the Device Id), done in
  `context.whenSettingsWritten`; the answer drops `token` as if the vault already had it.
- An entry without `deviceId` stays in a remaining `devices[]` until the running instance has learned its did from the
  hello reply at that `ip`; then it moves.
- `micloud.username`/`password` → the account's credentials (vault) the same way; `micloud.country`, `timeout`,
  `forceMiCloud` stay as Plugin Settings. A per-device `micloud` with only `country`/`timeout`/`forceMiCloud` becomes
  that device's `micloud` Accessory Setting; a per-device `username`/`password` (another account) is not supported in
  v1: kept as it is, logged at warn once.

Plugin Settings (schema `schema`): `micloud` (`country`, `timeout`, `forceMiCloud`), `pollingInterval` (seconds, the
`x-default` of the device setting), `pm25Breakpoints`, `co2AbnormalThreshold`.

Plugin Accessory Settings (schema `accessorySchema`, all declared, `x-kinds` from 2.3): `ip`, `model`,
`pollingInterval`, `propertyChunkSize`, `deviceEnabled`, `micloud`, `customAccessory`, `onlyMainService`, every flag of
2.3, `actionButtons`, `methodButtons`, `propertyControl`, `propertyMonitor`. Device Kinds: `light`, `outlet`,
`switch`, `airPurifier`, `humidifier`, `dehumidifier`, `fan`, `ceilingFan`, `heater`, `airConditioner`, `curtain`,
`sensor`, `airMonitor`, `vacuum`, `other`. [Homeswift]

### 2.5 Example blocks (personal data replaced)

Homebridge shape, loaded as it is:

```json
{
  "platform": "miot",
  "micloud": { "username": "user@example.com", "password": "…", "country": "de" },
  "devices": [
    {
      "name": "Desk Lamp", "ip": "192.168.1.50", "token": "00112233445566778899aabbccddeeff",
      "deviceId": "123456789", "model": "yeelink.light.colorc", "pollingInterval": 10
    },
    {
      "name": "Bedroom Purifier", "ip": "192.168.1.51", "token": "ffeeddccbbaa99887766554433221100",
      "deviceId": "234567891", "ledControl": true, "fanLevelControl": true, "pm25Breakpoints": [10, 20, 35, 60],
      "actionButtons": [{ "action": "filter:reset-filter-life", "name": "Reset filter" }],
      "propertyControl": [{ "property": "2.5", "value": 1, "name": "Sleep mode" }],
      "propertyMonitor": [{ "property": "environment:pm2.5-density", "value": 50, "valueOperator": "greater", "name": "Dusty" }]
    },
    {
      "name": "Robot", "ip": "192.168.1.52", "token": "0123456789abcdef0123456789abcdef", "deviceId": "345678912",
      "model": "rockrobo.vacuum.v1", "methodButtons": [{ "method": "find_me", "name": "Find robot" }]
    }
  ]
}
```

What the bridge writes after the next settings write (tokens and password in the vault):

```json
{
  "platform": "miot",
  "micloud": { "country": "de" },
  "_accessories": {
    "123456789": { "name": "Desk Lamp", "ip": "192.168.1.50", "model": "yeelink.light.colorc", "pollingInterval": 10 },
    "234567891": {
      "name": "Bedroom Purifier", "ip": "192.168.1.51", "ledControl": true, "fanLevelControl": true,
      "pm25Breakpoints": [10, 20, 35, 60],
      "actionButtons": [{ "action": "filter:reset-filter-life", "name": "Reset filter" }],
      "propertyControl": [{ "property": "2.5", "value": 1, "name": "Sleep mode" }],
      "propertyMonitor": [{ "property": "environment:pm2.5-density", "value": 50, "valueOperator": "greater", "name": "Dusty" }]
    },
    "345678912": { "name": "Robot", "ip": "192.168.1.52", "model": "rockrobo.vacuum.v1",
      "methodButtons": [{ "method": "find_me", "name": "Find robot" }] }
  }
}
```

---

## 3. Setup (Homeswift)

### 3.1 Account

- `accountAuthorization = .deviceCode`, `accountRequirement = .optional(adds: "Finds your devices and their tokens in
  your Xiaomi account.")`: devices work with a pasted token alone. [Homeswift]
- First step: `SetupField.choice("method", …)` with **QR code** (value `qr`, first and default) and **Password**
  (`password`), and `SetupField.choice("country", …)` with the eight regions of 4.1 (current `micloud.country`, else
  `cn`, as `value`). Later steps return `.keeping` both.
- Done: `SetupOutcome.credentials` = the session (3.6) (and, for the password way, `username` and `password` for a
  later re-login); `settings` = `{"micloud": {"country": …}}`. The plugin reloads and lists the account's devices.
- A refused session (4.6) → `context.accountRefused("The Xiaomi session expired; sign in again.")`.

### 3.2 QR code steps

1. Create the login (4.3.1). Answer `.ask` with the message "Scan the QR code with the Mi Home app, then confirm on the
   phone.", `url` = the response's `loginUrl`, `waitSeconds` = the response's `timeout` (seconds; 120 when absent
   [Homeswift]), `retryAfter` = 2. `state` keeps `lp`, the client identity (4.2) and `qr`.
2. Each retry runs one long-poll request (4.3.2) of at most 10 s. Not scanned yet → the same `.ask` with the remaining
   wait. Scanned → finish (4.3.3) and answer `.done`.
3. Time up → `SetupError("The QR code expired. Start again to get a new one.")`.

The response's `qr` is an image of the code; `SetupPrompt` has no image field, so the web UI shows `url` (open
question 14.1).

### 3.3 Password steps

1. Ask `username` (text) and `password` (`secret`). Log in (4.4).
2. `captchaUrl` in the step-2 response → `SetupError("Xiaomi asks for a captcha. Use the QR code instead.")`.
3. `notificationUrl` → two-factor (4.5): send the ticket, then ask for `code` ("Enter the code Xiaomi sent to your
   email."). `state` keeps the identity cookies, `context`, the flag and the client identity.
4. Verify the code, follow the chain, answer `.done`.

### 3.4 Devices

- A device the account lists with a token: `authorization: .none`. Its token goes to the vault under its Device Id at
  the end of its Setup (`SetupOutcome.credentials = {"token": …}`, `settings = {"ip": …, "model": …}`).
- A device without a token from the account (no account, or a device the hello found that the account does not list):
  `authorization: .apiKey`. One field `token` (`secret`): 32 hexadecimal characters (case-insensitive, stored
  lowercase). The plugin proves it with a hello and `miIO.info` (5.8) at the device's address; a reply that fails the
  checksum or does not decrypt → `SetupError("That token does not open the device at {address}.")`.
- `newDevices = .byAddress`: Add by address asks `ip` and `token`; the hello reply gives the did, which is the Device
  Id. [Homeswift]

### 3.5 Discovery

`discover()` answers within a few seconds:

1. **Hello broadcast** (5.2): send the hello to `255.255.255.255:54321` and to the broadcast address of each local IPv4
   network (`localIPv4Networks`), collect replies for 2 s [Homeswift]. Each reply gives the did (header bytes 8–11) and
   the sender's address.
2. **Cloud list** (4.9), when the account is set up, for the configured region; kept for 5 minutes [Homeswift].
3. Merge by did. Skip what section 10 says is out of scope (logged at debug once per did).

Each `DiscoveredDevice`: `id` = did; name = the cloud's `name`, else `"Xiaomi <model>"`, else `"Xiaomi device <did>"`;
`kind` from the spec's device type when the spec is cached, else from the model's middle segment (`light`, `plug`/
`outlet` → outlet, `switch`, `airpurifier`/`airp` → airPurifier, `humidifier`, `derh` → dehumidifier, `fan`,
`heater`, `aircondition`/`airc` → airConditioner, `curtain`, `sensor_ht` → sensor, `airmonitor`/`airm` → airMonitor,
`vacuum` → vacuum, else `other`) [Homeswift]; `isReachable: false` for a set-up device that answered neither the hello
nor the last poll.

### 3.6 What is kept where

| What | Where |
|---|---|
| The account session | `context.secretFile("cachedSession", …)`, `legacyFile:` `<Homebridge storage>/.miot_micloud/cachedSession` (homebridge-miot's file). JSON: `{"ssecurity", "userId", "cUserId", "serviceToken", "passToken", "timestamp" (ms), "loggedInAt", "loginMethod" ("qr", "password", "password_2fa", "unknown"), "agentId", "clientId", "country"}`. homebridge-miot's file has all but `cUserId`, `passToken`, `country`. |
| Account username and password (password way only) | The account's vault credentials. |
| Each device's token | The device's vault credentials, `{"token": "<32 hex>"}`. |
| Each model's spec | `context.jsonFile("spec/<model>.json")`: the instance JSON as served, with `{"fetchedAt": …, "urn": …}` beside it [Homeswift]. Not a secret. |
| ip, model | `_accessories` (2.4). |

homebridge-miot also writes `info_<ip without dots>_<token>` (model, deviceId, firmware) in its prefs directory. A port
must not put a token in a file name; Homeswift keeps model and firmware in its accessory cache. [homebridge-miot]

---

## 4. Xiaomi cloud

### 4.1 Hosts and regions

- Regions: `cn`, `de`, `us`, `ru`, `tw`, `sg`, `in`, `i2`. [homebridge-miot, extractor] Labels [Homeswift]: Mainland
  China, Europe, United States, Russia, Taiwan, Singapore, India, `i2` (meaning not established, 14.6).
- API base: `https://<country>.api.io.mi.com/app`, and `https://api.io.mi.com/app` for `cn` (no prefix). [both]
- Account host: `https://account.xiaomi.com`. STS host: `https://sts.api.io.mi.com/sts`.
- Account responses may start with the literal `&&&START&&&`; strip it before parsing JSON. A JSONP wrapper
  `name(...)` is also unwrapped by homebridge-miot. [both]

### 4.2 Client identity, headers and cookies

- **Agent id**: 13 random characters from `A`–`E`. **Client id** (cookie `deviceId`): 6 random letters
  (homebridge-miot: uppercase; extractor: lowercase). Both are kept with the session and reused (homebridge-miot
  restores them after a restart). [homebridge-miot]
- **User-Agent** (homebridge-miot): `Android-7.1.1-1.0.0-ONEPLUS A3010-136-<agent id> APP/com.xiaomi.mihome APPV/10.5.201`.
  The extractor sends 18 random lowercase letters, `-`, the agent id, then ` APP/com.xiaomi.mihome APPV/10.5.201`.
  Either works [both]; Homeswift uses homebridge-miot's.
- Account requests carry cookies `sdkVersion=accountsdk-18.8.15` and `deviceId=<client id>`, plus every cookie the
  account host set during the flow (a cookie jar keyed by name). [both]
- API requests carry cookies `sdkVersion=accountsdk-18.8.15`, `deviceId=<client id>`, `userId=<userId>`,
  `yetAnotherServiceToken=<serviceToken>`, `serviceToken=<serviceToken>`, `locale=en`, `channel=MI_APP_STORE`
  [homebridge-miot]; the extractor sends `locale=en_GB`, `timezone=GMT+02:00`, `is_daylight=1`,
  `dst_offset=3600000` too. Headers: `User-Agent`, `x-xiaomi-protocal-flag-cli: PROTOCAL-HTTP2` (spelling as sent),
  `Content-Type: application/x-www-form-urlencoded`, and for signed requests `Accept-Encoding: identity`,
  `MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4`. [both]

### 4.3 QR code login

**4.3.1 Create.** `GET https://account.xiaomi.com/longPolling/loginUrl` with query `_qrsize=480`,
`qs=?sid=xiaomiio&_json=true` (URL-encoded on the wire), `callback=https://sts.api.io.mi.com/sts`, `_hasLogo=false`,
`sid=xiaomiio`, `serviceParam=` (empty), `_locale=en_GB` (homebridge-miot defaults to `zh_CN`), `_dc=<ms since
epoch>`, header User-Agent. [both] Response (after `&&&START&&&`), values illustrative [unverified]:

```json
{"qr":"https://account.xiaomi.com/…/qr.png?…","lp":"https://…/longPolling/…","loginUrl":"https://account.xiaomi.com/…",
 "timeout":300,"timeInterval":1000,"code":0}
```

`qr` (an image of the code), `lp` (the long-poll URL), `loginUrl` (what the code encodes), `timeout`,
`timeInterval` are read; a response without `qr` or `lp` is an error. [homebridge-miot]

**4.3.2 Long poll.** `GET <lp>` (homebridge-miot adds `_=<ms>`), header User-Agent. The server holds the request
until the code is scanned or its own limit. The extractor uses a 10 s client timeout and repeats on timeout until
`timeout` seconds have passed since the start; a non-200 status is a failure. A 200 body (after the prefix) with
`ssecurity`, `userId` and `location` means success: `{"userId": …, "ssecurity": "<base64>", "cUserId": "…",
"passToken": "…", "location": "https://sts.api.io.mi.com/sts?…", "code": 0, …}`. Any other body is still pending; its
`code` and `desc` (or `description`, `message`, `status`) say why. [both]

**4.3.3 Finish.** `GET <location>` with User-Agent and cookies `sdkVersion`, `deviceId`, `userId`, `cUserId`,
`passToken`. The `serviceToken` is the `Set-Cookie` of that response (a response without it fails). The session is
`{userId, cUserId, ssecurity, passToken, serviceToken}`, login method `qr`. [both]

### 4.4 Password login

1. `GET https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true` (extractor: with cookie
   `userId=<username>`). Body `{"_sign": "…", …}`. Without `_sign`, the extractor accepts a body that already
   carries `ssecurity`, `userId`, `cUserId`, `passToken`, `location` (an account the cookies already sign in).
   [both]
2. `POST https://account.xiaomi.com/pass/serviceLoginAuth2`, form fields `hash` = uppercase hex MD5 of the password's
   UTF-8 bytes, `_json=true`, `sid=xiaomiio`, `callback=https://sts.api.io.mi.com/sts`,
   `qs=%3Fsid%3Dxiaomiio%26_json%3Dtrue` (that string, form-encoded again on the wire), `_sign=<from step 1>`,
   `user=<username>`; cookies `sdkVersion`, `deviceId`. homebridge-miot sends the fields as the body; the extractor
   as query parameters with redirects off. [both] The body (after the prefix) carries:
   - success: `ssecurity` (longer than 4 characters), `userId`, `cUserId`, `passToken`, `location`, `code`;
   - two-factor: no `ssecurity`, a `notificationUrl` (4.5);
   - captcha: `captchaUrl` (relative URLs are under `https://account.xiaomi.com`); the extractor shows the image and
     retries with `captCode`; code 87001 is a wrong captcha. Homeswift v1 refuses (3.3).
3. `GET <location>` (homebridge-miot: when `_sign` itself starts with `http`, it follows `_sign` instead) with
   cookies; the `serviceToken` cookie of the response completes the session. Login method `password`. [both]

### 4.5 Two-factor (email or phone code)

homebridge-miot leaves sending the code to the person, who opens `notificationUrl` in a browser; the extractor sends
it itself. Homeswift follows the extractor for sending and homebridge-miot for the phone/email choice:

1. `GET <notificationUrl>` (an `…/fe/service/identity/authStart?…context=<context>…` URL). Keep cookies. [extractor]
2. `GET https://account.xiaomi.com/identity/list?sid=xiaomiio&context=<context>&_locale=en_US` (homebridge-miot
   instead replaces `fe/service/identity/authStart` with `identity/list` in the notification URL). It must set the
   `identity_session` cookie, else fail. Its JSON `flag` is 4 (phone) or 8 (email); absent means 4. [homebridge-miot]
3. Send the ticket: `POST https://account.xiaomi.com/identity/auth/sendEmailTicket?_dc=<ms>&sid=xiaomiio&context=<context>&mask=0&_locale=en_US`,
   form `retry=0`, `icode=` (empty), `_json=true`, `ick=<the ick cookie, empty if none>`. [extractor] For flag 4 the
   matching phone endpoint is not established by the sources (14.5).
4. Verify: `POST https://account.xiaomi.com/identity/auth/verifyEmail` (flag 8) or `…/verifyPhone` (flag 4).
   Extractor form: query `_flag=8&_json=true&sid=xiaomiio&context=<context>&mask=0&_locale=en_US`, body
   `_flag=8`, `ticket=<code>`, `trust=false`, `_json=true`, `ick=…`. homebridge-miot form: query `_dc=<ms>`, body
   `ticket=<code>`, `trust=true`, `_json=true`, `_flag=<flag>`, headers `Accept: application/json`,
   `x-requested-with: XMLHttpRequest`, cookies. Success: JSON `code` 0 and a `location`; else `desc` or `tips`
   explains. [both]
5. Follow the chain without automatic redirects (at most 10 hops), keeping every `Set-Cookie` and reading the
   `extension-pragma` header, JSON `{"ssecurity": "…", "psecurity": "…"}`, on each hop. The chain goes
   `identity/result/check` → `…/serviceLoginAuth2/end…` (whose `extension-pragma` has `ssecurity`; a 200 "Xiaomi
   Account - Tips" page is fetched once more) → the STS URL (`https://sts.api.io.mi.com/sts…`), which sets
   `serviceToken`. The extractor falls back, when verify gives no location, to the `Location` header, then to an
   `identity/result/check` URL found in the body, then to `GET /identity/result/check?sid=xiaomiio&context=…&_locale=en_US`.
   Done when `ssecurity`, `userId` (cookie) and `serviceToken` are known. Login method `password_2fa`. [both]

### 4.6 Session lifetime

- A session is `ssecurity`, `userId`, `serviceToken` (plus `cUserId`, `passToken`, the client identity). Its lifetime
  is not published [unverified].
- Expiry shows as a signed request that fails: a non-2xx HTTP status, or a body that does not decrypt to JSON.
  homebridge-miot then, when it has a username and password, logs in again once and retries; without them (a QR or
  cached session) it gives up. [homebridge-miot]
- Homeswift: password way → log in again silently (a new two-factor demand → `accountRefused`); QR way → try
  `serviceLogin` (4.4 step 1) with the session's `userId` and `passToken` cookies, which the extractor shows may
  answer directly with a fresh `ssecurity` and `location` [unverified]; otherwise `accountRefused`. The plugin never
  needs the cloud at run time (unless `forceMiCloud`), so an expired session costs only discovery.

### 4.7 Signed (RC4) requests

Every API call is `POST <API base><path>` with a form body. [both]

1. **Nonce**: 8 random bytes followed by the minutes since the Unix epoch (`floor(ms / 60000)`) as a 4-byte
   big-endian integer; base64 of the 12 bytes. [both]
2. **Signed nonce**: base64 of SHA-256 over the base64-decoded `ssecurity` followed by the 12 nonce bytes. [both]
3. **Path for signing**: the URL's text after the first `com`, with `/app/` replaced by `/` (`/home/device_list`).
   [both]
4. **Parameters**: `data` = the request object as compact JSON text.
   - `rc4_hash__` = base64(SHA-1(UTF-8 of `POST&<path>&data=<data>&<signed nonce>`)). With more parameters, each
     `k=v` appears sorted by key between the path and the signed nonce. [both]
   - Encrypt `data` and `rc4_hash__`, each separately with a fresh cipher: RC4 keyed with the base64-decoded signed
     nonce (32 bytes), the first 1024 keystream bytes discarded, applied to the UTF-8 text, base64 of the result.
   - `signature` = base64(SHA-1(`POST&<path>&data=<encrypted data>&rc4_hash__=<encrypted hash>&<signed nonce>`)).
   - Body fields: `data`, `rc4_hash__`, `signature`, `ssecurity` (the session's, as is), `_nonce` (the nonce),
     form-encoded. Both sources send `ssecurity` in the body. [both] homebridge-miot sends them as the body; the
     extractor as query parameters of an empty POST.
5. **Response**: the body is base64; decrypt it with RC4 keyed with the same signed nonce, drop 1024, as UTF-8 JSON.
   Its `code` 0 means success; `result` holds the answer; a `message` says why when `result` is missing. [both]

**Unsigned form (legacy, `unencryptedRequests`)**: body `_nonce`, `data` (plain JSON), `signature` = base64 of
HMAC-SHA-256 keyed with the decoded signed nonce over `<path>&<signed nonce>&<nonce>&data=<data>`, where
homebridge-miot's path has no `/app` (`/home/device_list`); the response is plain JSON. Not used by Homeswift.
[homebridge-miot]

### 4.8 Endpoints

| Path | `data` | Result | Used for |
|---|---|---|---|
| `/home/device_list` | `{"getVirtualModel":false,"getHuamiDevices":0}` | `result.list[]` (4.9) | The account's devices in the region. [homebridge-miot] |
| `/home/device_list` | `{"dids":["<did>"]}` | `result.list[0]` | One device (online state, firmware). [homebridge-miot] |
| `/v2/homeroom/gethome` | `{"fg":true,"fetch_share":true,"fetch_share_dev":true,"limit":300,"app_ver":7}` | `result.homelist[].id` | Homes (extractor's path). |
| `/v2/user/get_device_cnt` | `{"fetch_own":true,"fetch_share":true}` | `result.share.share_family[].{home_id,home_owner}` | Homes shared with the user. [extractor] |
| `/v2/home/home_device_list` | `{"home_owner":<owner>,"home_id":<id>,"limit":200,"get_split_device":true,"support_smart_home":true}` | `result.device_info[]` | Devices of one home (owner = the user's id for own homes). [extractor] |
| `/v2/device/blt_get_beaconkey` | `{"did":"<blt did>","pdid":1}` | `result.beaconkey` | BLE keys. Not used (out of scope). [extractor] |
| `/miotspec/prop/get` | `{"params":[{"did","siid","piid"}…]}` | `result[]` as 5.9 | Cloud transport (4.11). [homebridge-miot] |
| `/miotspec/prop/set` | `{"params":[{"did","siid","piid","value"}…]}` | `result[]` | Cloud transport. |
| `/miotspec/action` | `{"params":{"did","siid","aiid","in":[…]}}` | `result` | Cloud transport. |
| `/home/rpc/<did>` | `{"method":"<miIO method>","params":[…]}` | `result` | Raw miIO through the cloud. |

Homeswift v1 lists devices with `/home/device_list` (homebridge-miot's call). Whether it includes devices of homes
shared with the account is not established; the extractor's homes path does (14.4).

### 4.9 Device list entries

Fields read [homebridge-miot, extractor]: `did`, `token` (32 hex), `localip`, `mac`, `model`, `name`, `ssid`,
`isOnline`, `extra.fw_version`. Fields seen but whose meaning no source documents: `parent_id`, `parent_model`, `pid`,
`spec_type`, `show_mode`, `permitLevel`, `shareFlag` [unverified]. Example (all values invented):

```json
{"code":0,"message":"ok","result":{"list":[{"did":"123456789","token":"00112233445566778899aabbccddeeff",
 "name":"Desk Lamp","model":"yeelink.light.colorc","localip":"192.168.1.50","mac":"AA:BB:CC:DD:EE:01",
 "ssid":"HomeWiFi","bssid":"AA:BB:CC:00:00:01","rssi":-48,"isOnline":true,"pid":"0","parent_id":"",
 "parent_model":"","show_mode":1,"adminFlag":1,"shareFlag":0,"permitLevel":16,"uid":1000001,
 "extra":{"fw_version":"2.1.8_0042","isSetPincode":0}}],"has_more":false,"next_start_did":""}}
```

homebridge-miot's settings page lists every region in turn, drops a did already seen, and by default keeps only
entries with a non-empty `localip` and `ssid` ("most probably Bluetooth devices" otherwise). [homebridge-miot]

### 4.10 Cloud error codes

A MIoT result `code` of the form `-70<x><nnn>` (for example `-704042011`) is a cloud error whose last three digits say
which: `001` device does not exist, `002` service, `003` property, `004` event, `005` action does not exist, `006`
device description not found, `007` device cloud not found, `008` invalid id, `009` scene does not exist, `011` device
offline, `013` property not readable, `023` not writable, `033` not subscribed, `043` value wrong, `034` action return
value error, `015` action execution error, `025` wrong number of action parameters, `035` action parameter error, `036`
device operation timeout, `100` not possible in the current state, `101` infrared devices do not support it, `901`
token missing or expired, `902` token illegal, `903` authorization expired, `904` unauthorised voice device, `905`
device not bound, `999` feature not online. [homebridge-miot]

### 4.11 `forceMiCloud` (flagged)

homebridge-miot with `forceMiCloud` true (or a model it marks as requiring the cloud, 8.1) never talks to the device:
it logs in (or uses the cached session), looks the did up with `/home/device_list {"dids":[did]}` (absent → "device
not found in your account on the <country> server", no retry), warns when `isOnline` is false, and sends every
property read, write and action through `/miotspec/prop/get`, `/miotspec/prop/set`, `/miotspec/action` and raw
methods through `/home/rpc/<did>`, with the same polling. A did is required. A result `code` ending `011` is "device
offline": polling restarts after the reconnect delay without a warning. When a cached session fails and a password is
known, it logs in once more. [homebridge-miot]

Homeswift v1 reads `forceMiCloud` and, when true for a device, uses this cloud transport for it (the signed client of
4.7 is already there for discovery) [Homeswift, open question 14.2]. Never by default.

---

## 5. miIO LAN protocol

### 5.1 Packet

Every packet is a 32-byte header, then optional ciphertext. All integers big-endian. [OpenMiHome, homebridge-miot]

| Bytes | Field | Request | Reply |
|---|---|---|---|
| 0–1 | Magic | `0x2131` | `0x2131` |
| 2–3 | Length | 32 + ciphertext length | the same |
| 4–7 | Unknown / reserved | `0x00000000` (hello: `0xFFFFFFFF`) | `0x00000000` |
| 8–11 | Device id (did) | the device's did (hello: `0xFFFFFFFF`) | the device's did |
| 12–15 | Stamp | 5.3 | the device's stamp (a counter in seconds) |
| 16–31 | Checksum | MD5 (5.5) (hello: all `0xFF`) | MD5; in a hello reply, the token field (5.2) |
| 32– | Ciphertext | AES-128-CBC of the JSON payload | the same |

### 5.2 Hello, handshake and discovery

- **Hello**: `2131 0020` then 28 bytes `0xFF` (32 bytes). [OpenMiHome, homebridge-miot]
- **Reply**: a 32-byte header with no payload: did at 8–11, the device's stamp at 12–15, and 16 bytes in the checksum
  position. Uninitialised devices put their token there; since 2017 provisioned devices do not (the field is all
  `0xFF` or all `0x00`). homebridge-miot ignores the field. [OpenMiHome, homebridge-miot]
- **Handshake** (homebridge-miot): before a request, send the hello unless a packet came from the device less than
  120 s ago; wait for the reply up to 5 s (one handshake at a time per device). A packet with an empty payload is a
  handshake reply: it updates the did (if different) and the stamp.
- **Discovery** (Homeswift, 3.5): the same hello sent to broadcast addresses on UDP 54321; every device on the network
  answers to the sender's port. homebridge-miot does not broadcast (its socket binds no fixed port and only unicasts).

### 5.3 Stamp

When a reply carries a stamp > 0, keep it and the local time it arrived. A request's stamp is that stamp plus the
whole seconds elapsed since (`stamp + floor((now − arrival) / 1 s)`); with no stamp yet, `0xFFFFFFFF`.
[homebridge-miot]

### 5.4 Key, IV, cipher

- key = MD5(token) (16 bytes), IV = MD5(key ‖ token), where token is the 16 raw bytes of the 32-hex string.
  [homebridge-miot] OpenMiHome's document writes IV = MD5(MD5(Key) + Token); that formula does not match
  homebridge-miot, which works with real devices; use MD5(key ‖ token). Section 12.1 gives both values so a test can
  catch the mix-up.
- AES-128-CBC with PKCS#7 padding (a payload that is a multiple of 16 bytes gains a full block of `0x10`).
  [OpenMiHome, homebridge-miot]

### 5.5 Checksum

MD5 over header bytes 0–15, then the 16 token bytes, then the ciphertext; written at bytes 16–31. A received packet
with a payload is checked the same way and dropped (logged at debug) when it differs. [homebridge-miot] (OpenMiHome
describes a checksum over the packet with a zeroed field; the token-in-place form is the one homebridge-miot uses.)

### 5.6 Payload

- Request: compact JSON `{"id": <n>, "method": "<method>", "params": <array or object>}`, UTF-8. [homebridge-miot]
- Reply: `{"id": <n>, "result": …}` or `{"id": <n>, "error": {"code": <int>, "message": "…"}}`, sometimes with
  `"exe_time": <ms>`. A reply is matched to its request by `id` (and the sender's address); a reply with an unknown id
  is dropped. [homebridge-miot]
- After decryption, drop one trailing NUL byte if present, then remove control characters `0x00–0x09`, `0x0B–0x0C`,
  `0x0E–0x1F`, `0x7F–0x9F` before parsing (some devices send invalid JSON). [homebridge-miot]
- **ids**: per device, start at 1 and add 1 per request; a retry of the same request takes the last id + 100; an id
  reaching 10000 wraps to 1. [homebridge-miot]

### 5.7 Timeouts, retries, errors

- Request timeout 4 s; 2 retries (3 sends). Handshake timeout 5 s; a handshake timeout counts as one try.
  [homebridge-miot]
- Error codes −30001 and −9999 ("user ack timeout": the device is busy) are retried like a timeout; any other `error`
  fails the request at once with its code and message. [homebridge-miot]
- A result that is the string `unknown_method`, or contains it, means the device does not know the method (8.1).
  [homebridge-miot]
- After the last try: "Call to device timed out". [homebridge-miot]

### 5.8 `miIO.info`

Sent after the first handshake, timeout 5 s, 3 retries. homebridge-miot passes `{"timeout":5000,"retries":3}` as the
method's `params` by mistake (they were meant as options), so its request is
`{"id":…,"method":"miIO.info","params":{"timeout":5000,"retries":3}}` with the default 4 s/2 retries; send `[]`.
[homebridge-miot] The result object carries at least `model` and `fw_ver` [homebridge-miot]; devices typically also
return `hw_ver`, `mac`, `ap` and `netif` [unverified]. A model differing from the configured one is logged at debug
and the configured one is used for the spec.

### 5.9 MIoT methods

| Method | `params` | `result` |
|---|---|---|
| `get_properties` | `[{"did":"<did>","siid":s,"piid":p}, …]` | `[{"did","siid","piid","code":0,"value":v}, …]`, same order |
| `set_properties` | `[{"did","siid","piid","value":v}, …]` | `[{"did","siid","piid","code":0}, …]` |
| `action` | `{"did","siid","aiid","in":[{"piid":p,"value":v}, …]}` | `{"code":0,"out":[…]}` (fields beside `code` vary) |

- `did` is always a string (the cloud answers −8 "data type not valid" to a number). [homebridge-miot]
- A property result is valid when `code` is 0, or when `code` is absent and `value` present (some devices omit it).
  Per-item codes: 1 accepted but not finished, −4001 not readable, −4002 not writable, −4003 does not exist, −4004
  internal error, −4005 value error, −4006 action `in` error, −4007 did error; a cloud `-70…011` is offline (4.10).
  An invalid item leaves that property's value unchanged (logged at debug). [homebridge-miot]
- **Batching**: at most 14 properties per `get_properties` (devices were seen failing above 16); `propertyChunkSize`
  1–14 lowers it. homebridge-miot sends a poll's chunks concurrently; Homeswift sends them one after another [Homeswift]
  (a busy device answers −9999).
- `set_properties` and `action` send one item per call in homebridge-miot. [homebridge-miot]
- An empty or missing `get_properties` result fails the poll. A result that is not an array (`"unknown_method"`) marks
  the device as not polling MIoT locally (8.1).

---

## 6. Spec registry and device model

### 6.1 Fetching a model's spec

1. `GET https://miot-spec.org/miot-spec-v2/instances?status=released` → `{"instances":[{"model","version","type","ts"}, …]}`
   (with `status=all`, each entry also has `status`: `released`, `preview` or `debug`). [miot-spec]
2. Among the entries whose `model` equals the device's model, take the highest `version`; its `type` is the instance
   URN. List order is not reliable (three models are out of order). [miot-spec] homebridge-miot instead reads
   `status=all` and takes the *last* entry of the model in list order, which can be a `debug` or `preview` spec
   (its `zhimi.airpurifier.ma4` class names version 3, which is not released) [homebridge-miot]. Homeswift: released
   first; when a model has no released entry, the highest-version `preview` from `status=all`, then `debug`, logged at
   info ("using an unreleased spec") [Homeswift].
3. `GET https://miot-spec.org/miot-spec-v2/instance?type=<urn>` → the instance JSON (6.2).
4. Keep it on the bridge (3.6) and use the kept copy from then on, also while miot-spec.org is unreachable. Refresh it
   when the instances list (fetched at most once a day, while some device is being set up or its model changed) shows
   a higher released version [Homeswift]. A changed spec rebuilds the accessory; iids stay because subtypes are
   built from siid/piid (7.1).

The instances list is about 2 MB; fetch it only during Setup or when a cached spec is missing, never per poll.

### 6.2 Instance JSON

```json
{"type":"urn:miot-spec-v2:device:light:0000A001:yeelink-colorc:1:0000C814","description":"Lightctl Color Light",
 "services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:yeelink-colorc:1","description":"",
   "properties":[{"iid":3,"type":"urn:miot-spec-v2:property:color-temperature:0000000F:yeelink-colorc:1",
     "description":"","format":"uint32","access":["read","write","notify"],"unit":"kelvin","value-range":[2700,6500,1]}],
   "actions":[{"iid":1,"type":"urn:…:action:toggle:…","description":"","in":[],"out":[]}],
   "events":[{"iid":1,"type":"…","description":"…","arguments":[1]}]}]}
```

- `iid` of a service is the **siid**, of a property the **piid**, of an action the **aiid**. Services are not listed
  in iid order. [miot-spec]
- `format`: `bool`, `uint8`, `uint16`, `uint32`, `int8`, `int16`, `int32`, `int64`, `float`, `string`. `access`: a
  subset of `read`, `write`, `notify` (an empty list occurs). `unit`: `percentage`, `celsius`, `fahrenheit`, `kelvin`,
  `rgb`, `seconds`, `minutes`, `hours`, `days`, `watt`, `lux`, `ppm`, `μg/m3`, `mg/m3`, `arcdegree`, `none`, absent,
  and others. `value-range`: `[min, max, step]`. `value-list`: `[{"value": v, "description": "…"}, …]`. An action's
  `in`/`out` and an event's `arguments` are piid lists. [miot-spec]
- **URN anatomy**: `urn:<namespace>:<kind>:<name>:<8-hex type code>:<model with dashes>:<version>[:<extra>]`. Only
  namespace `miot-spec-v2` names standard types (listed by `…/spec/services`, 327 types, and `…/spec/properties`,
  1672 types). Vendor namespaces (`zhimi-spec`, `cuco-spec`, `dreame-spec`, `lumi-spec`, `xiaomi-spec`, …) reuse
  standard-looking names with other meanings: `cuco.plug.v3` has a standard `indicator-light` (siid 13) and a
  `cuco-spec` `indicator-light` (siid 3) with schedule fields. [miot-spec] **The mapping keys on namespace and name:
  only `urn:miot-spec-v2:` services and properties map generically.** homebridge-miot keys on the name alone
  (`type` split on `:`, fourth part), which ignores the namespace. [homebridge-miot]

### 6.3 Names and ids used in options

homebridge-miot names every property, action and event `<service name>:<item name>` from the URNs' name parts
(`air-purifier:fan-level`, `filter:reset-filter-life`). A second service of the same name is named `<name><siid>`
(`brush-cleaner10:brush-life-level`); a second item of the same name within a service gets its iid appended
(`vacuum:mode5`). The device-information service is skipped. Options accept those names or ids `siid.piid` /
`siid.aiid` (`"2.7"`). [homebridge-miot] Homeswift builds the same names (the namespace is not part of them) so
existing `propertyControl`, `propertyMonitor` and `actionButtons` entries keep working.

### 6.4 Values

- A write is clamped to the value range (out-of-range values are logged at debug) and skipped when the last known
  value already equals it. [homebridge-miot]
- Value-list entries are found **by description**, compared after removing whitespace and lowercasing ("Go Charging"
  = "gocharging"); a description may name several values, all of which count. Values are never assumed: curtains order
  `motor-control` differently (`leshi.curtain.v0001`: 0 Close, 1 Pause, 2 Open; `lumi.curtain.hagl08`: 0 Pause, 1
  Open, 2 Close), vacuums number `status` differently (dreame 1 Sweeping, rockrobo 2 Sweeping, xiaomi.b108gl 4
  Sweeping). [homebridge-miot, miot-spec]
- A property with a value list is an enumeration even when its unit says `percentage`
  (`zhimi.airpurifier.ma4` `indicator-light:brightness`: 0 brightest, 1 glimmer, 2 off). [miot-spec, Homeswift]
- Before the first poll a property's value is unknown; nothing is published to HomeKit for it until it is known.
  [Homeswift, as Roborock.md 5.6]

### 6.5 Device type and main service

- The device type is the name part of the instance URN (`air-purifier`). [miot-spec] Robot vacuums are device type
  `vacuum`; `vacuum-cleaner` is used by models named `*.cleaner.*` (`roidmi.cleaner.f8pro`, `xiaomi.cleaner.g40m`),
  handheld vacuums, which are not robots and are out of scope. [miot-spec]
- The main service: the `miot-spec-v2` service whose name equals the device type (`air-purifier`, `light`, `fan`,
  `heater`, `humidifier`, `vacuum`, `curtain`, `air-conditioner`, `temperature-humidity-sensor`); for `outlet` and
  `switch` devices the lowest-siid `switch` service; else the lowest-siid service other than `device-information`.
  [Homeswift] homebridge-miot looks for a service named like the spec's lowercased `description`, else takes the
  first listed non-device-information service. [homebridge-miot]

---

## 7. HomeKit mapping

### 7.1 The accessory

- Accessory id `miot:<did>`, Name from 2.2/3.5, category from the device type (lightbulb, outlet, switch, air purifier,
  humidifier, fan, heater, air conditioner, window covering, sensor; a vacuum: other, as Roborock). [Homeswift]
- Accessory Information: Manufacturer `Yeelight Technology` for `yeelink.*`; else the model's first segment with its
  first letter capitalised (`Zhimi`, `Dreame`, `Cuco`); `Xiaomi` when the model has no dot. Model = the model.
  Serial Number per section 1. Firmware Revision = `miIO.info` `fw_ver`, else the cloud's `extra.fw_version`, else
  `Unknown`. [homebridge-miot; serial: Homeswift]
- Service subtypes, for stable iids: the primary service none; every other mapped service `<service name>-<siid>`
  (`filter-4`), a sensor taken from one property adds the property name (`environment-3-temperature`); extra controls
  `ctl-<siid>-<piid>[-<value>]`, `action-<siid>-<aiid>-<index>`, `method-<index>`, `monitor-<siid>-<piid>[-<value>]`.
  [Homeswift]
- Every characteristic's bounds and steps come from the spec (`value-range`) where HAP allows them.
- While the device does not answer (5.7, 9.2), `accessory.isUnavailable` is true (No Response) [Homeswift];
  homebridge-miot instead returns zeros and "off".

### 7.2 Conversions

| Conversion | Rule |
|---|---|
| bool | as is; a write of HAP `Active` 1/0 → true/false. |
| Percentage of a range `[lo, hi, step]` | When `hi` = 100 and `step` = 1, the value is the percentage itself (clamped to `lo` on write). Else read `round((v − lo) × 100 / (hi − lo))`, write `lo + round(p × (hi − lo) / 100 / step) × step`. [homebridge-miot for the 100/1 test; Homeswift for the step rounding] |
| Levels ↔ Rotation Speed | Levels = the value list in order without entries described `Auto`, or `lo…hi` by `step` for a range. n levels; level at index i (0-based) reads `round((i + 1) × 100 / n)`; a write of p > 0 sets the level at index `clamp(round(p × n / 100), 1, n) − 1` (halves round up); p = 0 writes nothing (Active turns the device off). A device in the Auto level reads 0. [Homeswift] homebridge-miot computes `first + floor(p ÷ (100/n))` and reads `round(level × 100/n)`, which misreads lists not starting at 1. |
| Kelvin ↔ mireds | `mired = round(1 000 000 / K)`; the characteristic's `minValue` = `ceil(1 000 000 / Kmax)`, `maxValue` = `floor(1 000 000 / Kmin)`, both clamped to HomeKit's 140–500. Write `K = round(1 000 000 / mired)` clamped to the range. A `color-temperature` in `percentage`: mired = `500 − (pct − 1) × 360 / 99`, inverse `pct = 1 + (500 − mired) × 99 / 360`, rounded. [homebridge-miot for the percentage case] |
| RGB ↔ Hue/Saturation | The `color` value is `R × 65536 + G × 256 + B`. Read: HSV of (R, G, B), Hue 0–360 and Saturation 0–100, rounded. Write: wait up to 1 s for both Hue and Saturation (HomeKit sends them together), then RGB of HSV(Hue, Saturation, V = 100 %), each channel rounded. homebridge-miot uses the light's brightness as V; Homeswift uses 100 % so the colour and the brightness stay separate. |
| Temperature | `celsius` as is (0.1 steps); a `fahrenheit` property is converted to Celsius. Temperature Display Units fixed to Celsius on thermostats and heater-coolers. [homebridge-miot] |
| Densities | `mg/m3` × 1000 → µg/m3 for VOC Density (from `tvoc-density`, else `hcho-density`); range default 0–1000. [homebridge-miot] |
| Time | `hours` × 60, `seconds` ÷ 60 rounded up, to minutes, for the use-time log line only. [homebridge-miot] |
| Value list → switches | One switch per entry, named `<control name> - <description>` (or the value when the description is empty); duplicate names get ` <n>`. [homebridge-miot] |

### 7.3 Mapping table (standard `miot-spec-v2` types)

| MIoT service | Property / action | HomeKit | Notes |
|---|---|---|---|
| `light` | `on` | Lightbulb On | Primary for device type `light`; an additional Lightbulb named "<Name> Light" elsewhere (`ceiling-fan`, generic). |
| | `brightness` | Brightness | Range → percentage (7.2); a 0 write is clamped to the range minimum. |
| | `color-temperature` | Color Temperature | 7.2; an Adaptive Lighting controller (`context.adaptiveLighting`) when present. |
| | `color` | Hue, Saturation | 7.2. |
| | `mode` | — | `modeControl` switches only. |
| `ambient-light` | as `light` | Lightbulb "Ambient Light" | [homebridge-miot] |
| `switch` (outlet device) | `on` | Outlet On; Outlet In Use = On | First `switch` service primary; each further one an Outlet "Outlet <n>", or "USB" when its description contains `usb`. [homebridge-miot] |
| `switch` (switch device) | `on` | Switch On | Several: one Switch per service, named "<Name> <description>". [homebridge-miot] |
| `power-consumption`, or the `switch` service | `electric-power` (`watt`) | Eve Current Consumption on the outlet | The runtime makes it a Meter. [Homeswift] |
| | `power-consumption` | Eve Total Consumption only when its unit is `kWh` or `Wh` | Unit absent or `none` → not mapped (14.3). [Homeswift] |
| `air-purifier` | `on` | Air Purifier Active | Writing Active 1 to a device already on sends nothing. [homebridge-miot] |
| | `mode` | Target Air Purifier State | Mode described `Auto` or `Sleep` → AUTO (1), else MANUAL (0). Write AUTO → `Auto`; MANUAL → `Favorite` when listed, else `Manual`, else `None`. [homebridge-miot; fallbacks Homeswift] |
| | (state) | Current Air Purifier State | off → INACTIVE (0); on and (status `Idle` or motor speed 0) → IDLE (1); else PURIFYING_AIR (2). [homebridge-miot] |
| | `fan-level` | Rotation Speed | Levels (7.2). homebridge-miot's generic module uses only a writable `motor-speed:favorite-level` or `custom-service:favorite-speed` (and switches to Favorite first); see 7.9. |
| `humidifier` | `on` | Humidifier-Dehumidifier Active | Primary. |
| | (state) | Current state HUMIDIFYING (2) while on, else INACTIVE (0) | Valid values 0, 1, 2. [homebridge-miot] |
| | — | Target state HUMIDIFIER (1) only | A write turns the device on. |
| | `target-humidity` | Relative Humidity Humidifier Threshold | Bounds and step from the range (default 0–100). |
| | `fan-level` (else `speed-level`) | Rotation Speed | 7.2. homebridge-miot prefers `speed-level`. [Homeswift] |
| | `water-level` | Water Level | Range → percentage; a vendor `water-shortage-fault` reads 0/100. |
| `dehumidifier` | as humidifier | Target DEHUMIDIFIER (2), Relative Humidity Dehumidifier Threshold | [homebridge-miot module] |
| `fan` (fan device) | `on` | Fan v2 Active, Current Fan State (BLOWING_AIR 2 while on, INACTIVE 0 off) | Primary. |
| | `fan-level` (else `speed-level`) | Rotation Speed | 7.2. |
| | `horizontal-swing` | Swing Mode | homebridge-miot also maps Rotation Direction to the swing; not ported. |
| | `mode`, `anion`, `off-delay`, `horizontal-angle`, `vertical-swing` | — | Extra controls (2.3). |
| `fan` (heater device) | `on` | Switch "Fan", active only while the heater is on | [homebridge-miot] |
| `heater` | `on` | Heater-Cooler Active | Primary when `target-temperature` exists; else a Switch [Homeswift; homebridge-miot uses a Fan v2]. |
| | (state) | Current state HEATING (2) while on, else IDLE (1) | |
| | — | Target state HEAT (1) only | A write turns the device on. |
| | `target-temperature` | Heating Threshold Temperature | Bounds and step from the range (default 10–35, 1). |
| | `mode` `Fan swing` / `Fan not swing` | Swing Mode | Only when both are listed. |
| `air-conditioner` | `on` | Heater-Cooler Active | Primary. |
| | `mode` | Target Heater Cooler State | `Auto` ↔ AUTO (0), `Heat` ↔ HEAT (1), `Cool` ↔ COOL (2); valid values only those listed; `Dry`/`Fan` read as the last target. Current state: HEATING in Heat, COOLING in Cool, else IDLE. |
| | `target-temperature` | Heating and Cooling Threshold Temperature (both the same property) | |
| | `environment:temperature` | Current Temperature | Absent → the target temperature. [homebridge-miot] |
| `fan-control` | `fan-level` | Rotation Speed on the heater-cooler | [Homeswift] |
| | `vertical-swing` | Swing Mode | |
| `curtain` (also device types `window-opener`, `motor-controller` with positions) | `current-position` | Window Covering Current Position | Range → percentage. |
| | `target-position` | Target Position | |
| | `status` | Position State: `Opening` → INCREASING (1), `Closing` → DECREASING (0), else STOPPED (2) | Without `status`: compare target and current. [homebridge-miot] |
| | `motor-control` | Hold Position → the value described `Pause` or `Stop` | [Homeswift] |
| | `fault` | Obstruction Detected = fault ≠ 0 | homebridge-miot: always false. |
| | `on` | — | homebridge-miot adds a "Power" switch; extra control only. |
| `temperature-humidity-sensor` | `temperature` | Temperature Sensor (primary) | Bounds from the range. |
| | `relative-humidity` | Humidity Sensor | |
| | `battery-level` | Battery | |
| `environment` | `temperature` | Temperature Sensor "Temperature" | Unless the primary has Current Temperature; `suppressAutoServiceCreation`. |
| | `relative-humidity` | Humidity Sensor "Humidity" | Unless the primary has Current Relative Humidity. |
| | `pm2.5-density` | Air Quality Sensor "Air Quality": Air Quality from the breakpoints, PM2.5 Density; PM10 Density from `pm10-density`; VOC Density from `tvoc-density` or `hcho-density` | Air purifiers and air monitors. |
| | `co2-density` | Carbon Dioxide Sensor: Detected above `co2AbnormalThreshold`, Level | |
| | `illumination` | Light Sensor | |
| `battery` | `battery-level` | Battery Level | |
| | `charging-state` | Charging State: `Charging` → 1, `Not Charging`, `Go Charging` → 0, `Not Chargeable` → 2 | Else from `status` `Charging`; nothing known → 2. |
| | (level) | Status Low Battery = level ≤ 20 | homebridge-miot: normal only above 20. The sensors also carry it. |
| `filter` | `filter-life-level` | Filter Maintenance "Filter": Filter Life Level (capped at 100), Filter Change Indication = level ≤ 5 | |
| | `reset-filter-life` action | Reset Filter Indication | homebridge-miot never wires it (its lookup returns nothing); Homeswift does. |
| `brush-cleaner` | `brush-life-level`, `reset-brush-life` | Filter Maintenance named by the service description | Vacuums (8.2). |
| `physical-controls-locked` | `physical-controls-locked` | Lock Physical Controls on the primary | Fan, air purifier, humidifier, dehumidifier, heater, air conditioner; `childLockControl`. |
| `indicator-light`, `alarm`, `screen` | | — | Extra controls only (2.3). |
| `vacuum` | | Section 8 | |
| `device-information` | | Accessory Information | Never polled. |

Anything else (vendor namespaces, other standard services) is not mapped; `propertyControl`, `propertyMonitor` and
`actionButtons` reach it. A device type without a primary in this table becomes a **generic** accessory: a Switch
named after the device on the main service's `on`, a Lightbulb for a `light` service, the `environment`, `battery`,
`filter` services, and the extra controls; with none of these it is not published (logged at info: "no HomeKit
mapping for <model>; use propertyControl"). [homebridge-miot generic module, Homeswift]

### 7.4 Air quality breakpoints

PM2.5 ≤ b0 → EXCELLENT (1); ≤ b1 → GOOD (2); ≤ b2 → FAIR (3); ≤ b3 → INFERIOR (4); above → POOR (5); unknown → 0.
Default `[7, 15, 30, 55]`. [homebridge-miot]

### 7.5 Writes

- Sliders (Brightness, Rotation Speed, range controls) are debounced 500 ms: only the last value is sent.
  [homebridge-miot]
- After a successful `set_properties` (code 0), the property takes the written value at once and HomeKit is updated
  without waiting for the next poll. After a successful action, poll once. [homebridge-miot]
- A write while the device is unreachable fails with SERVICE_COMMUNICATION_FAILURE. [homebridge-miot]
- A failed write is logged at warn with the property name and the device's code; HomeKit gets the last known value back
  on the next poll. [Homeswift]

### 7.6 What is polled

The properties the mapping and the extra controls use, plus the ones `propertyMonitor`/`propertyControl` name, readable
ones only. homebridge-miot polls a per-type list plus a common list (child lock, alarm, indicator light, screen,
environment, battery, filter, use time), or every readable property for a type with no list. [homebridge-miot,
Homeswift]

### 7.7 Names

Service names are English defaults ("Temperature", "Humidity", "Air Quality", "Battery", "Filter", the brush's
service description, "Buzzer", "Led", "Mode - Auto"). HomeKit names keep letters, digits, spaces and apostrophes only,
trimmed of spaces and apostrophes at both ends, `Unnamed` when empty. [homebridge-miot] The runtime handles Configured
Name (docs/plugins.md).

### 7.8 Extra controls' behaviour

As 2.3 describes. Common rules [homebridge-miot]:

- Stateless switches turn themselves off after 100 ms; stateful value switches turned off are set back on after
  100 ms (a value is chosen by turning another on).
- A control with a linked property (mode switches link to the main `on`; an air purifier's fan level links to mode
  Favorite) reads off while the link does not hold, and turning it on first turns a bool link on.
- Off delay: unit taken from the spec, else guessed from the range maximum (hours, minutes or seconds; the thresholds
  are homebridge-miot's and not established here, 14.7); bool → Switch.

### 7.9 Curated overrides (the short list)

Places where the generic mapping is known to be wrong, with what replaces it. Each is keyed by model.

| Model(s) | Generic result | Override | Ground |
|---|---|---|---|
| `zhimi.airpurifier.ma4` | Rotation Speed from `fan-level` (3 levels), which the device applies in its manual mode `None` | Rotation Speed ↔ `urn:zhimi-spec` `motor-speed` service's `favorite-fan-level` (siid 10, piid 10, range 0–14); a write sets mode `Favorite` (2) first. Current state: IDLE when `motor1-speed` (10.8) is 0. | homebridge-miot's model class for ma4 (its favorite level and motor speed); fixture spec. |
| `zhimi.fan.za5` (homebridge-miot treats `za3`, `za4` alike) | Rotation Speed from `fan-level` (4 levels) | Rotation Speed ↔ `urn:zhimi-spec` `custom-service` `speed-level` (siid 6, piid 8, range 1–100, used as a percentage); idle when `speed-now` (6.4) is 0. | homebridge-miot's fan module reads `custom-service:speed-level` by name; the generic rule ignores vendor namespaces. |
| Legacy-local models that have a released MIoT spec (`rockrobo.vacuum.v1`, `roborock.vacuum.*`, and the non-vacuums homebridge-miot marks as needing the cloud, 8.1) | The spec would be used over the LAN, where the device answers `unknown_method` | Vacuums: the legacy miIO path (8.3). Others: out of scope (10). | homebridge-miot marks them MiCloud-required and falls back to `get_status` for vacuums. |

Candidates that need a device to confirm (not applied in v1): `cuco.plug.cp2` reports its power as `power` (`watt`) in
a vendor `indicator-light` service (siid 3, piid 2); `chuangmi.plug.212a01`'s `electric-power` range 0–6553500 W
suggests hundredths of a watt; `zhimi.heater.mc2`'s `indicator-light:brightness` is `percentage` with range 0–1
(an on/off in disguise). [miot-spec, 14.3]

---

## 8. Vacuums

### 8.1 Which robots, and which path

- Every robot vacuum in the Mi Home account (the Mi cloud list) belongs to this plugin. Robots in the Roborock app
  stay with the Roborock plugin: an account is either Mi Home or Roborock. [settled decision]
- **Legacy miIO path** when either holds:
  1. the model starts with `rockrobo.vacuum.` or `roborock.vacuum.` (the Roborock miIO family: the command set of
     Roborock.md section 5 over the miIO UDP transport of section 5 here); or
  2. the first local `get_properties` answers `unknown_method` (5.7) and `get_status` answers. [homebridge-miot falls
     back to `get_status` this way; Homeswift adds rule 1]
- **MIoT path** otherwise: the model's spec has a `vacuum` service.
- A model's spec existing on miot-spec.org does **not** mean the robot speaks MIoT locally: `rockrobo.vacuum.v1` has
  a released spec (fixture) and homebridge-miot still marks it MiCloud-required. [miot-spec, homebridge-miot]
- Models homebridge-miot knows, with its cloud flag [homebridge-miot]:
  - Roborock family, MiCloud-required: `rockrobo.vacuum.v1` (Mi Robot Vacuum), `roborock.vacuum.m1s`, `s5`, `s5e`,
    `s6`, `a01`. Local (MIoT tried, `get_status` fallback): `roborock.vacuum.a08`, `a10`, `a11`, `a15`, `a27`, `a29`,
    `a51`, `a62`, `a70`, `a75`. All take the legacy path in Homeswift (rule 1).
  - MIoT, local: `dreame.vacuum.mb1808`, `mc1808`, `p2008`, `p2009`, `p2027`, `p2028`, `p2029`, `p2036`, `p2041`,
    `p2041o`, `p2114a`, `p2140`, `p2148o`, `p2150o`, `p2157`, `p2187`, `p2259`, `r2205`, `r2228`, `r2228o`, `r2250`;
    `ijai.vacuum.v1`, `v2`; `mijia.vacuum.v2`; `roidmi.vacuum.v60`, `v66`; `viomi.vacuum.v18`, `v19`.
  - MiCloud-required, not Roborock: `ijai.vacuum.v3`, `v18`; `viomi.vacuum.v7`, `v8`, `v10` ("only work through
    MiCloud", CHANGELOG). Homeswift v1: MIoT path, and when local `get_properties` fails, out of scope unless
    `forceMiCloud` (4.11).
- Other robots (e.g. `xiaomi.vacuum.*`, newer dreame) take the MIoT path by rule.

### 8.2 MIoT vacuum mapping

| MIoT | HomeKit |
|---|---|
| `vacuum:status` described `Sweeping`, `Mopping` or `Sweeping and Mopping` | Fan v2 Active 1; any other status → 0. [homebridge-miot] (Roborock counts returning to the dock as cleaning; this plugin follows homebridge-miot.) |
| Active write 1 | action `vacuum:start-sweep` (`in` empty). |
| Active write 0 | action `battery:start-charge`, else `vacuum:start-charge` (stopping only pauses the robot). [homebridge-miot] |
| `vacuum:fault` > 0, or status `Error` | Status Fault 1, else 0. |
| reachability | Status Active (Roborock 6.1). |
| `battery:battery-level` | Battery Level; Status Low Battery ≤ 20. |
| `battery:charging-state` | Charging State per 7.3; without it, status `Charging` or `Charging Completed` → 1. |
| `filter` (`filter-life-level`, `reset-filter-life`) | Filter Maintenance, name from the service description ("Filter"). |
| each `brush-cleaner` (`brush-life-level`, `reset-brush-life`) | Filter Maintenance named by its description ("Main Cleaning Brush", "Side Cleaning Brush"). |
| `vacuum:mode` | `modeControl` switches only. |
| identify | action `identify:identify` or `device-information:identify`, else vendor `find-vacuum`/`audio:position`, else `alarm` set 1, else miIO `find_me`. [homebridge-miot] |

Filter Change Indication at ≤ 5 %. Services are created only for consumables the spec has.

### 8.3 Legacy miIO vacuum

The robot uses Roborock.md section 5's methods over this plugin's miIO transport (section 5), with the robot's own
token: `get_status` for state (5.2 there), `app_start` (Active 1), `app_stop` then `app_charge` (Active 0, as
Roborock 6.1), `get_consumable` for main brush, side brush and filter life (5.5 there: rated 300/200/150 h),
`find_me` for identify. State codes and the cleaning set are Roborock.md 5.3. Poll `get_status` every polling
interval and `get_consumable` every 10 polls [Homeswift]. No spec is used for HomeKit; `actionButtons` and
`propertyControl` do not apply; `methodButtons` do.

homebridge-miot's own fallback maps `get_status` onto MIoT names: state 5, 11, 17, 18 → Sweeping; 10 → Paused; 6 → Go
Charging; 8 → Charging (and charging state); 12 → Error; else Idle; `battery` → battery level; `fan_power` → mode and
speed level. [homebridge-miot] Homeswift uses Roborock.md's sets instead, so both plugins show the same robot alike.

### 8.4 HomeKit shape

As `Plugins/Roborock/Sources/RoborockAccessory.swift`: a Fan v2 primary (Name = the robot's name; Status Fault, Status
Active), `standsFor = .cleaningRobot`, linked to a Battery (Battery Level, Charging State, Status Low Battery) and one
Filter Maintenance per consumable (Filter Life Level, Filter Change Indication, Configured Name). No Rotation Speed, no
scene or dock-wash switches. homebridge-miot publishes a Switch and a "Dock" occupancy sensor instead; that shape is
not ported. Consumable subtypes: `filter`, `main-brush`, `side-brush` (legacy, as Roborock); for MIoT,
`<service name>-<siid>` (`brush-cleaner-9`). [Homeswift]

---

## 9. Polling and lifecycle

### 9.1 Start

Per device, from `_accessories` and the vault [Homeswift, after homebridge-miot]:

1. Model known (setting or cache) → load the cached spec, build the accessory, add it, then connect. Model unknown →
   connect first.
2. Connect: handshake (5.2), `miIO.info` (5.8). The did is taken from the reply header when not known.
3. Spec: cached, else fetched (6.1). No spec and not a legacy vacuum → not published (logged at warn once).
4. Initial poll of every polled property, then polling every interval.

### 9.2 Polling and reconnect

- Interval: the device's `pollingInterval`, else the plugin-wide one, else 15 s. [homebridge-miot]
- A poll that fails counts; 4 failures in a row → the device is marked unreachable, polling stops and a reconnect
  (handshake, `miIO.info`, poll) is tried after `max(4 × interval, 30 s)`. homebridge-miot computes that delay with
  the default interval, so it is always 60 s; Homeswift uses the device's interval. [homebridge-miot]
- A `user ack timeout` error doubles the interval once (homebridge-miot changes the number but its running timer keeps
  the old period; Homeswift applies it). [homebridge-miot]
- `deviceEnabled: false` → no polling at all. Excluded devices are never connected (`context.isExcluded`).
- An address change: when the hello broadcast or the cloud list shows the did at another IP, the plugin uses the new
  address and writes `ip` back to the device's Accessory Settings. [Homeswift]

---

## 10. Out of scope for v1 (recognise and skip)

| What | How to recognise | What the plugin does |
|---|---|---|
| BLE / BLE-mesh devices | did starting `blt.` (the extractor fetches their beacon keys); empty `localip` and `ssid` | Not listed. |
| Zigbee and other gateway sub-devices | a non-empty `parent_id` [unverified meaning]; did prefixes such as `lumi.` [unverified]; empty `localip`; no hello reply | Not listed. (homebridge-miot can reach them through their gateway's IP and token with the sub-device's did and model; not in v1.) |
| Cloud-only devices | listed with a token but no `localip`, or no hello reply at `localip` while `isOnline` is true; virtual models | Listed only with `forceMiCloud` (4.11); else skipped with a debug line. |
| miIO-only devices other than vacuums | `get_properties` answers `unknown_method`, or the model is one homebridge-miot marks MiCloud-required (e.g. `yeelink.light.color1`–`color5`, `philips.light.*`, `chuangmi.plug.m1`, `v1`, `v3`, `zhimi.airpurifier.m1`, `m2`, `ma2`, `v6`, `v7`, `zhimi.fan.v3`, `za3`, `za4`, `sa1`, `zhimi.humidifier.ca1`, `cb1`) | Not published; logged at info once: "<model> needs the Xiaomi cloud; set micloud.forceMiCloud to use it". |
| Cameras, doorbells, speakers, gateways, IR | spec device type `camera`, `video-doorbell`, `speaker`, `gateway`, models `*.ir.*`/`miir.*` | Not listed. |
| Pet feeder, kettle, cooker, oven, air fryer, coffee machine, airer, fresh-air system, bath heater | device type | Generic accessory only (7.3). |

---

## 11. Logging, secrets, migration

### 11.1 Log lines (paraphrased)

- **Info**: discovered N devices (hello / cloud); connected to <name> (<model>, firmware); spec <urn> fetched / from
  cache / unreleased; device published with its services; polling started; method button result; unsupported model
  and why (10); session saved; region used.
- **Warn**: token does not open the device; device unreachable after 4 polls (reconnecting in N s); write failed
  (property, code); unknown action/property in an option; invalid `pm25Breakpoints`/`co2AbnormalThreshold`; cloud
  login failed; per-device account not supported.
- **Error**: setup failures surfaced to the person; spec missing and no cache.
- **Debug**: packets sent/received by method and id (never payloads containing tokens), chunk counts, property
  values, cloud paths (never bodies).

### 11.2 Never log

Device tokens, keys and IVs; `micloud.password` and its MD5 hash; `ssecurity`, the signed nonce, `serviceToken`,
`passToken`, `cUserId`, cookies (`identity_session`, `ick`), the QR `lp` URL and `location` URLs, two-factor codes,
the decrypted cloud bodies of login and device-list calls (they contain tokens). homebridge-miot logs the QR poll
response and login steps' bodies at its deep-debug level and puts the token in a file name; a port must not.
Treat the did, MAC, IPs and device names as personal data in shared logs (did at debug, or abbreviated).

### 11.3 Migration from Homebridge

Homeswift ids are `miot:<did>`, so nothing depends on homebridge-miot's HAP UUIDs. For reference, its UUID seed is
`"stableId:" + lowercase(stableId) + "miot"` when `stableId` is set, else `token + ip + deviceId + "miot"` (HAP-NodeJS
UUID of that string). [homebridge-miot]

---

## 12. Test vectors

All hex lowercase. Token `00112233445566778899aabbccddeeff`, did 123456789 (`075bcd15`). [vector]

### 12.1 Key and IV

- key = MD5(token) = `6e8311168ee16d6aa1aa48c64145003c`
- IV = MD5(key ‖ token) = `6f434fa9acd75da73e5fb999f641cda2`
- (Wrong, OpenMiHome's written formula MD5(MD5(key) ‖ token) = `cfa739d89919d1f4a13de7c072d8e36f`; must not be used.)

### 12.2 Hello and its reply

- Hello: `21310020ffffffffffffffffffffffffffffffffffffffffffffffffffffffff`
- Reply (constructed; stamp `0x00001000`, token field all `ff`):
  `2131002000000000075bcd1500001000ffffffffffffffffffffffffffffffff` → did 123456789, stamp 4096.

### 12.3 Request

Five seconds after the reply, stamp = 4096 + 5 = `0x00001005`. Payload (83 bytes):
`{"id":1,"method":"get_properties","params":[{"did":"123456789","siid":2,"piid":1}]}`

- Padded plaintext (96 bytes, 13 × `0d`):
  `7b226964223a312c226d6574686f64223a226765745f70726f70657274696573222c22706172616d73223a5b7b22646964223a22313233343536373839222c2273696964223a322c2270696964223a317d5d7d0d0d0d0d0d0d0d0d0d0d0d0d0d`
- Header bytes 0–15: `2131008000000000075bcd1500001005` (length 0x80 = 128)
- Ciphertext (96 bytes):
  `a5516ec6151955dc2bb2d43e7c84c183d0323c1dc33c264cbefa960d6d193588641ac998505dd479255e702548fd599869680a3c70ec847294cb174a3135aec704a083c92ed16e52b3da8a53fda0fe302cde54023a2fbcc1787eb1535837b393`
- Checksum = MD5(header 0–15 ‖ token ‖ ciphertext) = `ef95276f1ee599a02c5a0646e3d24e67`
- Packet (128 bytes):
  `2131008000000000075bcd1500001005ef95276f1ee599a02c5a0646e3d24e67a5516ec6151955dc2bb2d43e7c84c183d0323c1dc33c264cbefa960d6d193588641ac998505dd479255e702548fd599869680a3c70ec847294cb174a3135aec704a083c92ed16e52b3da8a53fda0fe302cde54023a2fbcc1787eb1535837b393`

### 12.4 Reply with a trailing NUL

Packet (128 bytes, stamp `0x00001006`):
`2131008000000000075bcd1500001006c6b97f19ce62411d4c9bedf617cba8f995d444d970e45e453f755f0301fb09fd3e256b96dcd3c67443340bc16878fdbb030088d1193dd8eb9295fca5cab1735c55d630977b6b8f51afd000171c5912ec9cb2cd4fccc64f9074f8db79834116d07bf64079efcd5b77f665a0c69c940f87`

Checksum verifies; decrypts (padding removed) to 94 bytes ending in `00`:
`{"id":1,"result":[{"did":"123456789","siid":2,"piid":1,"code":0,"value":true}],"exe_time":40}` + NUL. Result: 2.1 =
true.

### 12.5 PKCS#7 edge case

Payload of exactly 48 bytes `{"id":12345678,"method":"miIO.info","params":[]}` → 64 bytes of ciphertext
`1a7a530a1db499d7f520ded08d61970e973c0f7e08a20197e2cdbed7fdfdb49000147cbc83ea6f209a7976d347f13603e08788ea53d71cc9b9f5fd3e59457141`;
its last block decrypted without unpadding is `10101010101010101010101010101010`. Packet (96 bytes, stamp
`0x00001007`):
`2131006000000000075bcd1500001007ed518c900d860e2953f3ba29c8dcdddb1a7a530a1db499d7f520ded08d61970e973c0f7e08a20197e2cdbed7fdfdb49000147cbc83ea6f209a7976d347f13603e08788ea53d71cc9b9f5fd3e59457141`

### 12.6 Error reply

`{"id":2,"error":{"code":-9999,"message":"user ack timeout"}}` at stamp `0x00001008`:
`2131006000000000075bcd15000010086ebdc810fc503c7f03bdd321c7f909b3afd853c24ba2f1a5692237c7f05ced081cdefc12f4a3151d5921205d65bb1a775b7c789741ac2feb6fbe8af1ff3aa4cfe7bbffa907cc035dabf3813c08db5e19`
→ a recoverable error (5.7): retried.

### 12.7 Cloud signing

- ssecurity = `AAECAwQFBgcICQoLDA0ODw==` (bytes 00…0f)
- Time 1700000000000 ms → 28333333 minutes = `01b05515`; random part `0102030405060708`
- nonce bytes `010203040506070801b05515`, nonce = `AQIDBAUGBwgBsFUV`
- signed nonce = base64(SHA-256(ssecurity bytes ‖ nonce bytes)) = `5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ=`
- URL `https://de.api.io.mi.com/app/home/device_list` → path `/home/device_list`
- data = `{"getVirtualModel":false,"getHuamiDevices":0}`
- rc4_hash__ input: `POST&/home/device_list&data={"getVirtualModel":false,"getHuamiDevices":0}&5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ=`
- rc4_hash__ = `8KEisSlWPUyqxLodoNEAWiatFh4=`
- encrypted data = `J+nVv/2+M4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL`
- encrypted rc4_hash__ = `ZID3s/q7Nq4+a1rlq1LsAsJYkZzbI0H/XND8JQ==`
- signature input: `POST&/home/device_list&data=J+nVv/2+M4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL&rc4_hash__=ZID3s/q7Nq4+a1rlq1LsAsJYkZzbI0H/XND8JQ==&5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ=`
- signature = `Epje01XuZn7xOMBsyOEOqVv9mT8=`
- form body: `data=J%2BnVv%2F2%2BM4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL&rc4_hash__=ZID3s%2Fq7Nq4%2Ba1rlq1LsAsJYkZzbI0H%2FXND8JQ%3D%3D&signature=Epje01XuZn7xOMBsyOEOqVv9mT8%3D&ssecurity=AAECAwQFBgcICQoLDA0ODw%3D%3D&_nonce=AQIDBAUGBwgBsFUV`
- Decrypting both encrypted parameters with the signed nonce gives back data and rc4_hash__.
- Same nonce, `https://de.api.io.mi.com/app/miotspec/prop/get` with data `{"params":[{"did":"123456789","siid":2,"piid":1}]}`:
  path `/miotspec/prop/get`, rc4_hash__ = `mmXIvfzVMA9wdD9LIqeFCdR+D3M=`.

### 12.8 Cloud response

This response body (encrypted with the signed nonce of 12.7):

`J+nRte2NeMNeEgH5tm3wB8pz9ueuJUupNpq6ffGl7+QO45IjCdaRyhXBSMDUbxg2OLyHUTY74ka9ksHigc8+Kw4DuFMB64W/ldtZcw+NlHA5jItJoLXeINtFvS4mscJFvbELpXGkiVhv1ffd09Sgwcq8EfxsfLlLlltEpTeQWBG12G3ruwLjLTeGcdFtOtmaEqCviRmMSReyKXhIrw/dwVbgXRGeBcsrnoiUQ8EM54FaTvMRH4HSmzRMSY3e7un0WwBQ+3AaAZN0gQdYUTRtVtUezdeq/EfL+br6ARd0mVPBwd+/EiIJ37oboU0hbKqWwaRFKMaWRuh5DSO72MsqBFVGwnG/c47b7gez0vqGeCQTkmCdu9M5z2wnvlpWhYMOTr9dWscacnuvOR9/XuR8/SZ2OhSrhZX8xqtM5r/SjMhl+3NbBLN6H6KKQG4+fysCrz3STbVKKcYcFqGP/f1bOiJ8l19gwQp1YhMeyLEZNUVUUyG13aRLo+OGWZRxT6ablLmisEDsMf8mBOPKDZgiR4MzO8HpMfy9QpwAteIqihtUpkCKR95BMGcxoW7Q4hHbpbQQiDShdG5TD5slIaDR19Q9MLyyMl8Z0TfSQHcSnB5NAdQSM5vUGwLETlI9cdbbLC6XWDtOyjYN2DoiK/oOdqy0fxiFgiy3VUCArbnqDgm9wESZTLEunE1JrZFzChtkc2OPMTU9buXAwg54fP2aZOkQY82Wl4W9AH0vtApQFQA9yocle9Kt5eJ/oEKf9iVbNU78YjLYl3HgdcYI22dAo7l+lC+jUUvIvdEu+tFjXRwqhdUEwT8MYmreOz1P32lwOll98eLgo0JSGDEEPwH30BHr`

decrypts to:

```json
{"code":0,"message":"ok","result":{"list":[{"did":"123456789","token":"00112233445566778899aabbccddeeff","longitude":"0.0","latitude":"0.0","name":"Desk Lamp","pid":"0","localip":"192.168.1.50","mac":"AA:BB:CC:DD:EE:01","ssid":"HomeWiFi","bssid":"AA:BB:CC:00:00:01","parent_id":"","parent_model":"","show_mode":1,"model":"yeelink.light.colorc","adminFlag":1,"shareFlag":0,"permitLevel":16,"isOnline":true,"desc":"","extra":{"isSetPincode":0,"fw_version":"2.1.8_0042","needVerifyCode":0,"isPasswordEncrypt":0},"uid":1000001,"pd_id":1234,"password":"","p2p_id":"","rssi":-48,"family_id":0,"reset_flag":0}],"has_more":false,"next_start_did":""}}
```

→ one Discovered Device: id `123456789`, name "Desk Lamp", model `yeelink.light.colorc`, ip 192.168.1.50, token in
the vault, Serial Number `AABBCCDDEE01`, firmware `2.1.8_0042`, kind `light`, authorization none.

### 12.9 Legacy unsigned signature (reference only)

With 12.7's values: input `/home/device_list&5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ=&AQIDBAUGBwgBsFUV&data={"getVirtualModel":false,"getHuamiDevices":0}`,
HMAC-SHA-256 keyed with the decoded signed nonce → `JbxFY1bUVgANhq7Ncm2kpKLkJUFoszxRc0Y4TO1X3CM=`.

### 12.10 Password hash

`hunter2` → `2AB96390C7DBE3439DE74D0C9B0B1767`; `p@ss w0rd` → `23DBDF3E325C805DD816B0700C11F831`.

### 12.11 RC4

Key `Key`, plaintext `Plaintext` → `bbf316e8d940af0ad3` (no drop). Key bytes 00…0f, 1024 bytes dropped, plaintext
`hello rc4 drop` → `e264c47a560e03fa95f0e2d11658`.

### 12.12 Conversions

| Input | Output |
|---|---|
| 6500 K, 2700 K, 4000 K, 1700 K | 154, 370, 250, 588 (→ 500 after HomeKit's clamp) mireds |
| range 2700–6500 K | Color Temperature min 154, max 370 |
| 154, 370, 250 mireds written | 6494, 2703, 4000 K |
| `color` 16744448 (`ff8000`) | Hue 30, Saturation 100 |
| Hue 240, Saturation 50 | `color` 8421631 (`8080ff`) |
| Hue 0, Saturation 0 | 16777215 |
| 4 levels 1–4 | read 25, 50, 75, 100; write 1→1, 37→1, 38→2, 63→3, 88→4, 100→4 |
| 3 levels (0 Auto excluded) 1–3 | read 33, 67, 100; write 1→1, 33→1, 50→2, 67→2, 84→3 |
| range 200–2000 step 10 | 1100 reads 50; 50 writes 1100 |
| range 1–100 step 1 | 50 reads 50 (used as a percentage) |
| PM2.5 5, 7, 8, 30, 56 with default breakpoints | Air Quality 1, 1, 2, 3, 5 |
| battery 20, 21 | Status Low Battery 1, 0 |
| filter life 5, 6 | Filter Change Indication 1, 0 |

---

## 13. Fixture expectations

Every fixture is the instance JSON of the URN in `instances-sample.json` with the highest released version. Property
references are siid.piid. "Extras" are only present with their flag on (2.3).

**`yeelink.light.colorc`** (`…:yeelink-colorc:1:0000C814`): category lightbulb. Primary Lightbulb: On (2.1),
Brightness (2.2, range 1–100: a write of 0 sends 1), Color Temperature (2.3, min 154, max 370), Hue and Saturation
(2.4); Adaptive Lighting. Extras: `modeControl` → "Mode - Color" (value 1), "Mode - Ct" (2), on only while 2.1 is true.
Polled: 2.1–2.5.

**`cuco.plug.v3`** (`…:cuco-v3:2`): category outlet. Primary Outlet: On (2.1), Outlet In Use (= 2.1), Eve Current
Consumption from 11.2 (`float`, watt). 11.1 `power-consumption` (unit none) not mapped. 7.1 physical-controls-locked:
not on an Outlet (propertyControl only). Extras: `ledControl` → Switch "Led" on 13.1 (the standard indicator light,
not the `cuco-spec` service at siid 3). No `buzzerControl` (no alarm). Vendor services 3–5, 8–10, 12, 14, 15
ignored.

**`zhimi.airpurifier.ma4`** (`…:zhimi-ma4:2`): category air purifier. Primary Air Purifier: Active (2.2), Current
State, Target State (2.5: 0 Auto, 1 Sleep → AUTO; 2 Favorite, 3 None → MANUAL; MANUAL writes 2), Rotation Speed
(override 7.9: 10.10, 0–14), Lock Physical Controls (7.1). Linked: Filter Maintenance "Filter" (4.3; reset 4.1);
Air Quality Sensor (3.6, default breakpoints; no PM10, no VOC); Temperature Sensor (3.8, −40–125, 0.1); Humidity
Sensor (3.7). Extras: Buzzer (5.1), Led (6.6 on; 6.1 is a value list, not a slider), Mode switches for 0–3,
Fan Level switches (2.4, linked to mode Favorite).

**`zhimi.humidifier.ca4`** (`…:zhimi-ca4:2`): category humidifier. Primary Humidifier-Dehumidifier: Active (2.1),
Current State (2 while on), Target State HUMIDIFIER only, Current Relative Humidity (3.9), Humidifier Threshold (2.6,
30–80, step 1), Rotation Speed (2.5 levels 1–3, Auto excluded: 33/67/100), Water Level (2.7, range 0–128 → percent),
Lock Physical Controls (6.1). Linked: Temperature Sensor (3.7). No separate Humidity Sensor (the primary has it).
Extras: Buzzer (4.1), Screen (5.2 list: three switches), Fan Level switches (2.5, four values including Auto).

**`zhimi.fan.za5`** (`…:zhimi-za5:4`): category fan. Primary Fan v2: Active (2.1), Current Fan State, Rotation Speed
(override 7.9: 6.8, 1–100), Swing Mode (2.3), Lock Physical Controls (3.1). Linked: Temperature Sensor (7.7, −30–100),
Humidity Sensor (7.1). Extras: Buzzer (5.1), Led (4.3, a Lightbulb slider 0–100), Mode (2.7: "Natural Wind",
"Straight Wind"), Ioniser (2.11), Off delay (2.10, range 0–36000, unit none), Fan Level (2.2), Swing (2.3),
horizontal angle buttons (2.5, 30–120), Move left/right (6.3, `zhimi-spec` `swing-step-move`, homebridge-miot's name
lookup).

**`zhimi.heater.mc2`** (`…:zhimi-mc2:1`): category heater. Primary Heater-Cooler: Active (2.1), Current State
(HEATING while on, else IDLE), Target State HEAT only, Current Temperature (4.7), Heating Threshold (2.5, 18–28,
step 1), Display Units Celsius, Lock Physical Controls (5.1). Extras: Buzzer (6.1), Led (7.3: range 0–1, see the 7.9
candidates), Off delay (3.1 `countdown-time`, hours 0–12).

**`lumi.curtain.hagl08`** (`…:lumi-hagl08:1`): category window covering. Primary Window Covering: Current Position
(2.3), Target Position (2.7), Position State (2.6: 0 Stopped → 2, 1 Opening → 1, 2 Closing → 0), Hold Position (2.2
value 0 "Pause"), Obstruction Detected (2.1 ≠ 0). Identify → action 6.1. Extras: Motor Control (2.2, write-only:
four stateless switches Pause, Open, Close, Toggle). `lumi-spec` services 4, 5, 7, 8 ignored.

**`dreame.vacuum.p2009`** (`…:dreame-p2009:2`): MIoT vacuum. Primary Fan v2 (`standsFor` cleaning robot): Active =
2.1 ∈ {1 Sweeping, 7 Mopping}; write 1 → action 2.1; write 0 → action 3.1. Status Fault = 2.2 > 0 or 2.1 = 4. Status
Active. Battery: Level 3.1, Charging State 3.2 (1 → 1; 2, 5 → 0), Low ≤ 20. Filter Maintenance "Main Cleaning Brush"
(9.2, reset 9.1, subtype `brush-cleaner-9`), "Side Cleaning Brush" (10.2, reset 10.1, `brush-cleaner-10`), "Filter"
(11.1, reset 11.1, `filter-11`). Extras: Mode (2.3: Silent, Basic, Strong, Full Speed). Polled: 2.1, 2.2, 2.3, 3.1,
3.2, 9.2, 10.2, 11.1.

**`cgllc.sensor_ht.qpg1`** (`…:cgllc-qpg1:1`): category sensor. Primary Temperature Sensor (2.1, −30–100, 0.1, Status
Low Battery), Humidity Sensor (2.2, 0–100, 0.1), Battery (2.3; Charging State 2 not chargeable). Whether this model is
Wi-Fi is [unverified]; its spec is the same as `cgllc.sensor_ht.dk2`'s.

**`rockrobo.vacuum.v1`** (`…:rockrobo-v1:1`): the spec is not used. Legacy path (8.3): Fan v2 primary, Battery,
Filter Maintenance `main-brush`, `side-brush`, `filter`; a fake that answers `unknown_method` to `get_properties` and
Roborock.md 11.10's `get_status` result gives Active 0, Battery 100, Charging State 1, Status Fault 0.

A test may also assert 6.1's choice on `instances-sample.json`: `zhimi.fan.za5` → version 4, `cuco.plug.v3` →
version 2, `dreame.vacuum.p2009` → version 2.

---

## 14. Gaps and open questions

1. **QR in the web UI.** `SetupPrompt` has `url` but no image. Either the web UI draws a QR code of `url` for a
   Device Code step, or the prompt's `url` is the `qr` image. Decide before building 3.2.
2. **`forceMiCloud` in v1.** The cloud transport is small given 4.7, but makes some devices depend on the cloud at run
   time; the settled decision allows it only behind the option. Confirm v1 ships it.
3. **Energy units.** `power-consumption` units are often missing (`none`) and some ranges suggest scaled values
   (`chuangmi.plug.212a01`). Total Consumption is only mapped with a unit; confirm on real plugs before adding
   per-model scales.
4. **Shared homes.** Whether `/home/device_list` returns devices of homes shared with the account is not established;
   the extractor's homes path (4.8) does.
5. **Two-factor by phone.** The send-ticket endpoint for flag 4 (phone) is not in the sources (homebridge-miot leaves
   sending to the browser). v1 can ask the person to open `notificationUrl` for a phone code, as homebridge-miot does.
6. **Region `i2`.** Accepted by both sources; what it is is not documented.
7. **Off-delay unit guessing.** The thresholds are not specified here; v1 may require a unit and skip the control
   without one.
8. **Session lifetime and refresh** (4.6): the passToken refresh is inferred from the extractor's step 1, not
   observed.
9. **Defaults kept true.** `childLockControl` and `showTemperature` keep homebridge-miot's true because they gate base
   mapping; every flag that adds a service is false. A migrated Homebridge user who relied on the old true defaults
   (buzzer, led, mode, screen, motor) loses those switches until they turn them on.
10. **Wi-Fi status of the sensor fixture** (`cgllc.sensor_ht.qpg1`) and of `lumi.curtain.hagl08` is not verified; the
    mapping does not depend on it.
11. **Not verified on devices**: everything about real replies (`miIO.info` fields beyond `model`/`fw_ver`, token
    field contents in hello replies, `exe_time`), the cloud's current behaviour (endpoints change), and the curated
    overrides' effect.

## 15. Decisions for v1 (settled after review)

These answer section 14 and bind the implementation. [Homeswift]

1. **QR in the web UI** (14.1): no web UI change. The QR step's `SetupPrompt.url` is the response's `qr` (the image of
   the code), so the sheet's link opens the code to scan with the Mi Home app; the message says so: "Open the QR code
   and scan it with the Mi Home app, then confirm on the phone." `loginUrl` stays in `state` only.
2. **`forceMiCloud`** (14.2): not shipped in v1. Control stays on the LAN. The option is read and kept in the block; a
   device with it set is still reached over the LAN, and the plugin logs once (warn) that the cloud transport is not
   supported yet. Section 4.11 is reference only. The cloud is used for sign-in and the device list, nothing else.
3. **Energy** (14.3): only current power (`electric-power`, W) is mapped; no Total Consumption in v1.
4. **Shared homes** (14.4): `/home/device_list` only.
5. **Two-factor by phone** (14.5): when the account offers no email identity, the step fails with
   `SetupError("Xiaomi sends this account's code by text message, which Homeswift cannot ask for. Use the QR code instead.")`.
6. **Region `i2`** (14.6): accepted and passed through as a region code.
7. **Off delay** (14.7): the control is made only for a property whose unit is `seconds`, `minutes` or `hours`;
   otherwise skipped (debug log).
8. **Defaults** (14.9): as written in 2.3: flags that add a service default to false; `childLockControl` and
   `showTemperature` default to true. The README and the CHANGELOG say that a block relying on homebridge-miot's
   implicit true defaults (buzzer, LED, mode, screen, motor switches) must now set them.
9. **What HomeKit cannot show** (rule of this plugin): every readable property and every action of a device's spec that
   the generic mapping does not put in HomeKit stays reachable on the web UI and over MCP, never as an extra switch
   unless a Plugin Accessory Setting of 2.3 turns one on. This is the plugin's own page (`Web/`, `handleWebRequest`):
   per device, its spec's services with each property's current value, a control for each writable one (a switch for a
   bool, a menu for a value list, a number for a range) and a button for each action without `in` parameters; and
   `assistantActions` over the same routes (`properties`: read a device's properties by name or `siid.piid`;
   `set_property` and `run_action`: write one / run one, both `confirm: true`). Writes are sent over the LAN as any
   HomeKit write.
