# Wingman

The Home app's accessories in Homeswift, through [Homeswift Wingman](https://github.com/mp-consulting/homeswift-wingman):
a menu bar app on a Mac that reads Apple Home with HomeKit (which exists on the Mac only for Mac Catalyst apps) and
serves it over TLS to the bridges paired with it. Homeswift can run anywhere, a Synology or a Linux container
included: it reaches Wingman over the network.

The accessories join the web UI's Accessories page (in Apple Home's rooms, with a house badge, and the **Apple Home icon switch**
to see them alone), scenes, automations and the MCP tools. Matter accessories that Homeswift cannot
reach itself (Hue, IKEA) come too. They are **never published to HomeKit again**: the Home app has them already
(`Accessory.mirroredFrom`, docs/plugins.md). Homeswift's own accessories, which Apple Home lists as well, are left out.

## Pairing

On the plugin's page in the web UI:

1. **On the network** lists the Wingman apps Bonjour finds (`_homeswift-wingman._tcp`), or **Add by address** asks
   one by its address when Bonjour does not cross (another network, a container without multicast).
2. **Pair** opens under the Wingman's row. In Wingman's menu, choose **Pair a Homeswift Bridge**: it shows a 6-digit
   code for ten minutes. Check that the certificate the page shows starts as the one in Wingman's window (Bridges tab),
   then type the code: the sixth digit pairs.
3. The page writes the Wingman's entry in `devices` and the plugin reloads with it.

The certificate is pinned from the pairing on; the token is Wingman's to revoke (its Paired Bridges). Pairing trusts
the network for those ten minutes, as a first connection does: the fingerprint check is what guards it.

## Configuration

```json
{
  "platform": "Wingman",
  "name": "Wingman",
  "devices": [
    { "id": "…", "name": "Mac mini", "host": "192.168.1.20", "token": "…", "fingerprint": "…" }
  ],
  "homes": ["Home"],
  "exclude": ["Christmas Lights"],
  "excludeBridges": ["Old Hub"],
  "refreshMinutes": 10
}
```

| Key | What it does |
|---|---|
| `devices` | The paired Wingmen, written by the page: `id` (Wingman's), `host` and `port` (Bonjour moves them), `token`, `fingerprint` (pinned) |
| `homes` | Only these homes, by name; all of them without it |
| `exclude` | Accessories left out, by name or HomeKit id |
| `excludeBridges` | Bridges whose accessories are left out, by name; Homeswift's own are always left out |
| `refreshMinutes` | How often the whole home is read again (names, rooms, new accessories); value changes arrive at once |

## How it works

`GET /homes` gives the homes, rooms, accessories, services and characteristics with their ids and HomeKit's ranges;
each accessory becomes `Wingman:<HomeKit id>` with Homeswift's own types (`ServiceType.known(uuid:)`), so the widgets
and scenes recognise it. `GET /events?since=&wait=25` is a long-poll: a value change reaches Homeswift as HomeKit
pushes it; events Wingman no longer keeps (it keeps 500) make the plugin read the homes again. Homeswift's own
accessories are recognised by their serial numbers, so a TV or a camera Homeswift publishes on its own is left out too,
and an entry without a pinned certificate is never sent its token. A write goes to `POST /write` by characteristic id; locks, garage doors and alarms are security controls
(the web UI and the MCP server ask first) and Wingman refuses them anyway. An accessory Apple Home says is not
reachable shows No Response until it reports again. A Wingman that forgot the bridge shows **Pair again**.

The MCP tools are `Wingman_list_wingmen`, `Wingman_discover` and `Wingman_pair`.

## Dashboard controls

Wingman accessories can join [dashboard groups](../../docs/widgets.md#accessory-groups) with compatible native
accessories. Only controls shared by every member appear; a group does not create another HomeKit accessory.
Use No Response to find unavailable members. Removing a mirrored cached entry does not delete its device from
Apple Home: the next Wingman discovery can bring it back. Use `exclude` to keep it out of Homeswift.

## Limits

- Apple Adaptive Lighting remains managed in Apple Home. A light's status
  displays the latest colour temperature reported by Wingman, in kelvin, when available. This is a cached reading,
  not confirmation that Adaptive Lighting is active. Manual colour changes may disable Apple's schedule.
- Wingman runs only on Macs registered in its developer's team (HomeKit is not available to Developer ID apps).
- HomeKit cannot read Matter accessories' values (error 74): theirs come from the changes they report, and the value
  last written.

Maintained by @mp-consulting. Tested against a fake Wingman (`Tests/FakeWingman.swift`) and, end to end, against a
stand-in of Wingman's API over TLS and Bonjour. Local signed-build testing is environment-specific; the automated tests do not require an Apple Home account.

### Identify

The accessory menu offers Identify when HomeKit reports support. It invokes HomeKit’s native identify
action through Wingman’s authenticated `/write` route (`characteristic: "Identify"`, `value: true`).
Older Wingman versions use a writable Identify characteristic when available; “Let bridges change accessories” must
be enabled. The physical response depends on the device. No room assignments are changed.
