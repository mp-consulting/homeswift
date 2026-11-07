# Rules are written in Home Time, and the pages show it by default

Tariff periods, Cron schedules and "at 7:00" triggers are rules about the home, so they are written, stored and shown
in Home Time (the bridge's time zone: the host's, unless a Bridge Setting names an IANA zone) with the zone named
beside them. That holds even for someone whose Preferences show other timestamps in their device's time zone. The
pages also default to Home Time, the opposite of Home Assistant, whose profile defaults to the browser's zone. So a
person travelling abroad sees "Off-peak from 22:00" and the log as the home lives them, not shifted by the time
difference. The JSON API, MCP tools and exports write ISO 8601 with Home Time's offset and never a person's Regional
Formats.

## Considered Options

- The device's time zone by default (Home Assistant's choice): a schedule entered abroad would mean a different
  hour at home, and twice a year, whenever the two zones change for daylight saving on different dates, every rule
  would shift by an hour.
- Home Time derived from the Location's coordinates: needs a time-zone boundary dataset of several megabytes, which
  goes against the bridge's no-dependencies rule.
  The host's zone with an explicit override covers it, since a container in UTC is the case that goes wrong.

## Consequences

The Status page flags a host in UTC with no Home Time set: every rule would otherwise run hours off without warning.
