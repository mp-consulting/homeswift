# The MCP server

Homeswift speaks the [Model Context Protocol](https://modelcontextprotocol.io), so Claude Desktop, Claude
Code, Cursor and other MCP clients can read and control the bridge: list and set accessories, read and
change `config.json`, read the log, with the scopes, confirmations and audit log of
[`homebridge-ai-kit`](https://github.com/mp-consulting/homebridge-ai-kit).

There is one server, over Streamable HTTP, inside the running bridge; `homeswift mcp` is a stdio
front for clients that only speak stdio, forwarding every message to it.

## Turning it on

In the `HomeswiftAiKit` block of config.json (the Assistant's provider settings are optional here):

```json
{
  "platform": "HomeswiftAiKit",
  "mcp": {
    "http": {
      "enabled": true,
      "host": "127.0.0.1",
      "port": 8582,
      "token": "<homeswift mcp --generate-token>",
      "readOnly": false,
      "clients": [{ "name": "Dashboard", "token": "<another token>", "scope": "read" }],
      "allowedOrigins": [],
      "auditLog": true,
      "auditLogPath": "~/.homeswift/homeswift-mcp-audit.jsonl",
      "maxSessions": 32,
      "sessionIdleMinutes": 30
    }
  }
}
```

| Key | Default | What it does |
|---|---|---|
| `enabled` | `false` | Run the server with the bridge |
| `host`, `port` | `127.0.0.1`, `8582` | Where it listens; it serves `/mcp` |
| `token` | | The main client token (`admin`). Required; `homeswift mcp --generate-token` makes one |
| `clients` | `[]` | More tokens, each with a `scope`: `read`, `control` or `admin` |
| `readOnly` | `false` | Caps every token at `read` |
| `allowedOrigins` | `[]` | Browser origins allowed besides localhost and the server's own address (`*` for any) |
| `auditLog`, `auditLogPath` | `true`, next to config.json | Every write tool call, one JSON line each |
| `maxSessions` | `32` | Sessions at once: a new one ends the least recently used idle session, or gets 503 when all are busy |
| `sessionIdleMinutes` | `30` | A session idle this long ends |

The environment overrides the block, under `homebridge-ai-kit`'s names or Homeswift's (which win):

| Variable | What it sets |
|---|---|
| `HOMESWIFT_MCP_MAX_SESSIONS`, `HOMEBRIDGE_AI_MCP_MAX_SESSIONS` | `maxSessions` |
| `HOMESWIFT_MCP_SESSION_IDLE_MINUTES`, `HOMEBRIDGE_AI_MCP_SESSION_IDLE_MINUTES` | `sessionIdleMinutes` |
| `HOMESWIFT_READ_ONLY`, `HOMEBRIDGE_READ_ONLY` | `readOnly` (`true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`); the web UI's chat follows it |
| `HOMESWIFT_MCP_TOKENS`, `HOMEBRIDGE_AI_MCP_TOKENS` | More tokens as `scope:token` pairs separated by commas (`read:abc,control:def`), added to `clients` |
| `HOMESWIFT_MCP_ALLOWED_ORIGINS`, `HOMEBRIDGE_AI_MCP_ALLOWED_ORIGINS` | `allowedOrigins`, separated by commas |
| `HOMESWIFT_MCP_AUDIT_LOG`, `HOMEBRIDGE_AI_AUDIT_LOG` | `auditLogPath` (and turns the audit log on) |

Restart the bridge; it prints the URL. Then connect a client:

```bash
homeswift mcp --snippets        # ready-to-paste configs for Claude Desktop, Claude Code and Cursor
```

A stdio client runs `homeswift mcp`, which needs the URL and the token: from config.json when it runs on
the same machine with the same `-U` directory, or from `HOMESWIFT_MCP_URL` and `HOMESWIFT_MCP_TOKEN`
(or `--url` and `--token`). A client that speaks Streamable HTTP connects to `http://127.0.0.1:8582/mcp`
with `Authorization: Bearer <token>`.

## Scopes

| Scope | Tools |
|---|---|
| `read` | `get_server_status`, `list_accessories`, `get_accessory`, `get_accessory_history`, `list_plugins`, `get_config`, `list_config_backups`, `get_recent_logs`, `search_logs`, `get_system_info`, `list_child_bridges`, `get_child_bridge_health`, `get_cached_accessories`, `get_pairing_info`, `get_assistant_usage`, `get_daily_digest` |
| `control` | Plus `set_accessory`, `set_accessories` (with `dryRun`), `set_security_accessory`, `identify_accessory` |
| `admin` | Plus `update_config`, `patch_config`, `restore_config`, `put_list_entry`, `restart_bridge`, `restart_child_bridge`, `stop_child_bridge`, `start_child_bridge`, `remove_cached_accessory`, `reset_cached_accessories`, `reset_pairings`, `truncate_logs`, `test_assistant_connection` |

A token sees only the tools its scope allows. Locks, garage doors and alarms (Lock Target State, Target
Door State, Security System Target State, Lock Control Point) change only through `set_security_accessory`;
`set_accessory` and `set_accessories` refuse them. So do the characteristics a plugin marks as security
controls (`isSecurityControl`, such as UniFi Access's Lock Trigger switches, whose On unlocks a door):
`get_accessory` lists them with `"security": true`. Values that carry keys (Setup Endpoints holds a live
stream's SRTP keys) are listed as null with `"confidential": true`, and left out of `list_accessories`.
What only HomeKit uses is `"internal": true`: a camera's RTP stream, recording and data stream services and
its snapshot settings. TLV8 and data values mean nothing as text: they are null with their size in `bytes`.

### What the tools do

- **Accessories.** `list_accessories` takes filters, all of which must match: `platform`, `type` (a category
  such as `lightbulb`, or a service type such as `Switch`), `name` (part of the accessory's or a service's
  name), `manufacturer` and `excludeManufacturer`. Homeswift has no rooms (HomeKit keeps them and a bridge
  never learns them), so there is no `room` filter: names often carry the room. `set_accessories` takes a
  list of `changes`, or one `characteristic` and `value` for the accessories that `ids` or `filter` (the same
  filters) pick; it refuses when more than `maxTargets` (25 by default, at most 200) would change, and skips
  and reports accessories without the characteristic and security controls.
- **History.** `get_accessory_history` reads the Eve history a plugin keeps for an accessory (`EveHistory`:
  temperature, humidity, air quality, power, light level, contact, motion; ten-minute averages for four
  weeks): per characteristic the min and max with when, the time-weighted average, the last value and the
  points averaged down to `maxPoints`, over `hours` (24 by default). Accessories without such a history
  answer with a note.
- **The log.** `search_logs` filters by `since` and `until` (an ISO time, local without a zone, or `30m`,
  `1h`, `2d` back from now; with either, the log archive on disk is searched, else the lines kept in memory),
  minimum `level`, `plugin` (part of a line's label: the plugin instance or bridge) and `pattern` (plain
  text, `caseSensitive` or not, or a regular expression for an admin token, stopped after 5 seconds), with
  `context` lines around each match. `pattern` may be left out when a filter is given.
- **Child bridges.** `list_child_bridges` and `get_child_bridge_health` show each child bridge's status (`ok`,
  `degraded` when a plugin on it did not start, `stopped`), uptime, restarts and the plugins that failed
  with why. Child bridges run inside the homeswift process, so there are no crashes to count.
  `stop_child_bridge` stops the bridge, its plugins and their external accessories until `start_child_bridge`
  (a configuration save leaves it stopped; a restart of homeswift starts it); `restart_child_bridge` starts
  its plugins afresh on the same accessories and pairings.
- **Accessory caches.** `get_cached_accessories` lists what each instance's cache file holds:
  `restoredOnly` marks an accessory back from the cache that its plugin has not added again (a device it
  has not reached, or no longer has), `orphaned` the file of a block no longer configured.
  `remove_cached_accessory` takes one out of the cache and HomeKit (a plugin that still has the device adds
  it again); `reset_cached_accessories` empties every cache and starts the plugins again, which add the
  devices they reach with the aids and iids they had.
- **Pairings.** `get_pairing_info` tells, for the bridge, each child bridge and each external accessory,
  whether it is paired and with how many controllers. It never gives the setup code or the setup URI (which
  encodes the code): the user reads them where homeswift prints them, or in the web UI. `reset_pairings`
  forgets every controller of one of them (the main bridge by default); the Home app must add it again.
- **The Assistant.** The bridge's own Assistant (its HomeswiftAiKit block): `get_assistant_usage` gives its
  requests, tokens and cost today, this month and in total, by model and by user, and the budgets;
  `test_assistant_connection` sends a one-word request with the saved block (it counts as one);
  `get_daily_digest` answers the day's digest, written once a day and kept in `ai-digest.json` (the web UI's
  Status page shows the same), `refresh` writing it again for a control or admin token. The digest is text
  the model wrote from log lines and device names, so it comes as `<untrusted-data>`.
- **Emptying the log.** `truncate_logs` removes the lines in memory and the files under `logs/`, then logs who
  did it; it asks first.
- **The machine.** `get_system_info` adds the load average (`cpuLoadPercent` is the last minute's over the
  CPUs), this process's CPU and memory from the Status page's samples, and each interface's bytes and
  throughput, since the previous call or over a second.

Tools whose answers have a fixed shape declare it as `outputSchema` (MCP 2025-06-18), and every answer of
theirs carries `structuredContent`; a client on an older protocol version gets the tools without it.

## Confirmations

`set_security_accessory`, `update_config`, `patch_config`, `restore_config`, `put_list_entry`,
`restart_bridge`, `restart_child_bridge`, `stop_child_bridge`, `remove_cached_accessory`,
`reset_cached_accessories`, `reset_pairings` and `truncate_logs` ask the user before running, as do plugin actions marked
to confirm. When the client supports MCP elicitation, the server asks
through it. A tool with a dry run is run as one first: the question lists what would change, each setting
with its new value, and carries the dry run's answer in `_meta` (`homeswift/preview`) for a client that
shows it; a call the dry run says would fail comes back with that error, not as a question. Other tools show
their arguments (secrets redacted). A declined question means the tool does not run. When the client cannot ask, the
tool refuses and the bridge writes a six-digit confirmation code to its log (the terminal and the web UI's
Logs page; the MCP log tools and notifications hide it). The user passes the code to the assistant, which
calls again with `confirmationCode`. A code is for that tool and those arguments, lasts five minutes and
works once; three wrong codes lock the call until it expires, and ten wrong codes in five minutes, over
any calls, lock them all for that long. `dryRun` previews skip the question for the tools that offer one. `HOMESWIFT_ELICITATION=false` turns elicitation off.

## Resources and prompts

Resources: `homeswift://status`, `homeswift://accessories`, `homeswift://logs/recent`, and the templates
`homeswift://accessory/{id}`, `homeswift://child-bridge/{id}` (a child bridge by device ID or name, with
its health) and `homeswift://plugin/{platform}` (with completion of their variables). A client that subscribes gets `notifications/resources/updated` when an accessory changes or
the log grows. Log lines also arrive as `notifications/message`, warnings and errors unless the client
asks for more with `logging/setLevel`.

Prompts: `diagnose-logs` (`focus?`), `troubleshoot-device` (`device`, `symptom?`), `audit-config`,
`nightly-health-check` (`hours?`) and `scene-builder` (`description`, `area?`). Homeswift keeps no scenes:
`scene-builder` finds the accessories, proposes values, sets them with `set_accessories` (a dry run first)
and has the user save the scene in the Home app, which records the accessories' current state.
`homebridge-ai-kit`'s `plan-upgrade` is not ported: it plans npm upgrades of plugins, and Homeswift's
plugins are compiled into the binary.

## Security

- **A token is required** on every request, compared in constant time; three bad tokens from an address
  slow its next attempts. The server binds to `127.0.0.1` unless `host` says otherwise.
- **Origins** other than localhost and the server's own address are refused unless listed, so a web page
  cannot reach the server from the user's browser.
- **Secrets stay out.** `get_config` and the plugin actions (a TV's password after pairing) give each secret
  as a handle of the session's vault, `__SECRET_…__`, which becomes the secret again when the same session
  passes it back under a secret's key (password, token, key, pin); a handle anywhere else, or from another
  session, is refused. A client can so move a secret into config.json without reading it. MCP tokens and
  dry-run previews show `__REDACTED__`, which `update_config` also restores. `includeSecrets` exists only
  when the bridge runs with `HOMESWIFT_ALLOW_SECRETS=true`.
- **Log lines, accessory data and what devices answer are data.** They come back wrapped in `<untrusted-data>` tags, and the
  server's instructions tell the model never to follow instructions found in them.
- **An audit trail.** Every write tool call is appended to the audit log with its arguments (redacted),
  the session, the token's name and scope, `dryRun` and `notConfirmed`; the file rotates at 5 MB.
- **Sessions** belong to the token that opened them and expire after `sessionIdleMinutes` (30) idle
  minutes; there are at most `maxSessions` (32), the least recently used idle one making room for a new one.

Configuration changes apply at once, plugin blocks reloading in place; the answer lists what still needs a
restart (the bridge block, the runtime's own blocks, child bridges). The tools back up the previous
file under `backups/` next to config.json (the last 20 are kept).
