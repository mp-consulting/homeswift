# Dummy Accessories

Accessories that exist only in HomeKit: switches, outlets, lights, buttons, locks, doors, windows, coverings, garage
doors, valves, humidifiers, thermostats and sensors, to build automations with. They keep their state across restarts
and can change by themselves: on a delay, an interval, a cron schedule or a time of the sun, back after an auto-reset,
within a time limit, when other dummies change, on a line of the bridge's log, when a host comes or goes, and through
webhooks. Nothing is reached on the network except the hosts of reachability conditions and the push services of
notifications.

**Maintainer:** Mickael Palma. **Status:** experimental: tested against the specification's vectors and with fakes, not
yet by someone moving from homebridge-dummy.

## Configuration

The block of [homebridge-dummy](https://github.com/mpatfield/homebridge-dummy) 2.x loads unchanged: the same platform
(`HomebridgeDummy`), the same `accessories` entries and options, the deprecated ones included (`webhookPort`,
`enableWebook`, `defaultOn`, `defaultBrightness`, a boolean `fadeOut`, `sensor.timerControlled`, a schedule's `delay`,
`pingInterval`/`pingUnits`, `limiter.id`). The bridge writes them in their current form with its next settings write.

```json
{
  "platform": "HomebridgeDummy",
  "name": "Homebridge Dummy",
  "webhookConfig": { "port": 63743, "disableSSL": true },
  "accessories": [
    { "id": "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", "name": "Desk Lamp", "type": "Lightbulb", "isDimmer": true, "enableWebhook": true },
    { "name": "Porch", "type": "Switch",
      "schedule": { "type": "SUNSET", "offset": -15, "latitude": 48.8566, "longitude": 2.3522 },
      "autoReset": { "type": "TIMEOUT", "time": 4, "units": "HOURS" } },
    { "name": "Alarm", "type": "Switch", "conditions": { "operator": "and", "operands": [
      { "type": "ACCESSORY", "accessoryId": "door", "accessoryState": "open" },
      { "type": "LOG", "pattern": "Doorbell rang" } ] } }
  ]
}
```

- **Identity.** An accessory's id is `HomebridgeDummy:` followed by its `id`, or, without one,
  `<type>:<name without whitespace>`: the identifier homebridge-dummy derives, so the same entries keep the same
  accessories, rooms and automations here from then on. A group (`groupName`) is one accessory,
  `HomebridgeDummy:Group:<group name without whitespace>)}`, with a service per member. Conditions and webhooks name
  accessories by that identifier (`id`, or `HomebridgeDummy:<type>:<name>`).
- **Types:** `Switch`, `Outlet`, `Lightbulb` (`isDimmer`, `fadeOut`), `StatelessProgrammableSwitch`, `LockMechanism`,
  `Door`, `Window`, `WindowCovering`, `GarageDoorOpener` (`simulation`), `Valve` (Set Duration and Remaining Duration with
  a timeout auto-reset), `HumidifierDehumidifier`, `Thermostat` (`temperatureUnits`, `validStates`…), `TemperatureSensor`,
  `HumiditySensor` and the seven binary sensors (`MotionSensor`, `ContactSensor`…), each also an attached `sensor`.
- **Schedules** (`schedule` triggers, `autoReset` resets): `TIMEOUT`, `INTERVAL`, `CRON` (a preset such as `@weekdays`,
  or `CRON_CUSTOM` with `cronCustom`, five fields or six with seconds), `SUNRISE`, `SUNSET`, `DAWN`, `DUSK`,
  `GOLDEN_HOUR`, `NIGHT` with `offset` minutes and the `latitude` and `longitude` of the place. A running timeout is
  stored and resumes after a restart, or fires 100 ms after it when it should have fired meanwhile.
- **Limiter**, **conditions**, **notifications** (Notify! or Pushover), **Eve history** (`enableHistory`) and
  `resetOnRestart`, `disableLogging`, `verbose` work as in homebridge-dummy.
- **Matter** (`"protocol": "Matter"`, for a switch, an outlet or a light): the accessory is on the bridge like the
  others, so Homeswift's Matter bridge (docs/matter.md) shows it, and the next settings write marks it Not in Home so
  it stays out of the Home app.

### Webhooks

With `enableWebhook` on an accessory, the server (`webhookConfig.port`, 63743 by default) answers
`GET /?id=<identifier>&get=<Characteristic>`, `…&set=<Characteristic>&value=<value>`, `…&sync=…` (the same, as a
sync) and the older `command=`, and `GET /` lists them. POST bodies may be a form or JSON. Values are checked strictly
(`true`/`false` for On, numbers in a range elsewhere), and the answers are homebridge-dummy's, word for word.

- **HTTPS** with `webhookConfig.key` and `cert`, paths of PEM files; `disableSSL` keeps plain HTTP. `pfx` is not
  supported (give the key and the certificate instead), and outside Homebridge there is no Config UI X to take
  certificates from.
- **A passphrase.** homebridge-dummy's webhooks have no authentication. Here `webhookConfig.passphrase`, when set, is
  required on every request, as a `passphrase` parameter or `Authorization: Bearer <passphrase>`, compared in constant
  time. It is a secret-named key: the bridge seals it in config.json, or it can be a `vault:` reference. Set it, or
  `bindAddress: "127.0.0.1"`, whenever the bridge's network is not yours alone: anyone who reaches the port can
  otherwise switch the accessories, the locks and doors included.
- Request bodies are limited to 64 KB and idle connections closed after 30 seconds.

### Secrets

`notification.token` (the Notify! token, or the Pushover user key) and `webhookConfig.passphrase` sit under
secret-named keys: the bridge seals them, resolves `vault:`, `env:` and `file:` references, and masks them in logs.
They are not in the settings form: put them in config.json or the vault. Pushover's application token is
`notification.id`, which is not a secret-named key and stays in plain text; Pushover needs your own application's
token there, as the bridge has none of its own.

## What differs from homebridge-dummy

- **No shell commands.** `commandOn`, `commandOff`, `commandSync` and the other `command…` options are not run (the
  configuration can be edited from the web UI and over MCP, so running them would let those run any program on the
  machine). An accessory that has them says so once at launch; `syncSchedule` does nothing without `commandSync`.
- **Log conditions** read the bridge's own log, as it is written, rather than a `homebridge.log` file; lines this
  plugin logs itself are left out, so a pattern cannot trigger itself in a loop.
- **Reachability conditions** check a host by opening a TCP connection to its web ports (80 and 443, or a URL's port):
  a host that accepts or refuses answers, so it is reachable. There is no ICMP ping (it needs privileges the bridge
  does not have) and no ARP scan, so a `pingHost` that is a MAC address is never checked and its condition never holds.
- **Sun times** come from the configured `latitude` and `longitude` only, as in homebridge-dummy; a day without the
  event (polar day or night) tries again the next day.
- **History** is kept for accessories on their own; group members keep none. History files are in the plugin's
  folder, not in Homebridge's `persist/`.
- **State** is kept in the plugin's folder (`HomebridgeDummy.json`, the same pairs of identifier and property);
  Homebridge's node-persist store is not read, so the first launch starts from the default states.
- Re-triggering an accessory with a limiter keeps one limiter timer, where homebridge-dummy starts another.

## Tests

`swift test --filter DummyTests` runs the specification's vectors (identities, the auto-reset across restarts, the
webhooks of TV2, the group of TV3, conditions, the limiter of TV5, sun and cron schedules, fades, the thermostat of
TV12) on a clock the tests move, and the webhook server end to end on a local port. No device, account or network.

## Clean-room implementation

Compatible with the configuration of [homebridge-dummy](https://github.com/mpatfield/homebridge-dummy) by mpatfield
(originally by nfarina), under the Apache License 2.0. This plugin was written from the functional specification in
[docs/clean-room/Dummy.md](../../docs/clean-room/Dummy.md), without reading or copying homebridge-dummy's code. The
sun's times follow the formulas of Astronomy Answers' "Position of the Sun" (the ones SunCalc uses), and the Eve
history is Homeswift's own `EveHistory`.
