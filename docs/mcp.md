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
      "auditLogPath": "~/.homeswift/homeswift-mcp-audit.jsonl"
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
| `read` | `get_server_status`, `list_accessories`, `get_accessory`, `list_plugins`, `get_config`, `list_config_backups`, `get_recent_logs`, `search_logs`, `get_system_info` |
| `control` | Plus `set_accessory`, `set_accessories` (with `dryRun`), `set_security_accessory`, `identify_accessory` |
| `admin` | Plus `update_config`, `patch_config`, `restore_config`, `restart_bridge` |

A token sees only the tools its scope allows. Locks, garage doors and alarms (Lock Target State, Target
Door State, Security System Target State) change only through `set_security_accessory`; `set_accessory`
and `set_accessories` refuse them.

## Confirmations

`set_security_accessory`, `update_config`, `patch_config` and `restore_config` ask the user before
running. When the client supports MCP elicitation, the server asks through it, with the arguments shown
(secrets redacted), and a declined question means the tool does not run. When the client cannot ask, the
tool refuses and the bridge writes a six-digit confirmation code to its log (the terminal and the web UI's
Logs page; the MCP log tools and notifications hide it). The user passes the code to the assistant, which
calls again with `confirmationCode`. A code is for that tool and those arguments, lasts five minutes and
works once; three wrong codes lock the call until it expires, and ten wrong codes in five minutes, over
any calls, lock them all for that long. `dryRun` previews skip the question for the tools that offer one. `HOMESWIFT_ELICITATION=false` turns elicitation off.

## Resources and prompts

Resources: `homeswift://status`, `homeswift://accessories`, `homeswift://logs/recent`, and the templates
`homeswift://accessory/{id}` and `homeswift://plugin/{platform}` (with completion of `id` and
`platform`). A client that subscribes gets `notifications/resources/updated` when an accessory changes or
the log grows. Log lines also arrive as `notifications/message`, warnings and errors unless the client
asks for more with `logging/setLevel`.

Prompts: `diagnose-logs` (`focus?`), `troubleshoot-device` (`device`, `symptom?`), `audit-config` and
`nightly-health-check` (`hours?`).

## Security

- **A token is required** on every request, compared in constant time; three bad tokens from an address
  slow its next attempts. The server binds to `127.0.0.1` unless `host` says otherwise.
- **Origins** other than localhost and the server's own address are refused unless listed, so a web page
  cannot reach the server from the user's browser.
- **Secrets stay out.** `get_config` replaces passwords, tokens, keys and the pin with `__REDACTED__`, and
  `update_config` puts the real values back. `includeSecrets` exists only when the bridge runs with
  `HOMESWIFT_ALLOW_SECRETS=true`.
- **Log lines and accessory data are data.** They come back wrapped in `<untrusted-data>` tags, and the
  server's instructions tell the model never to follow instructions found in them.
- **An audit trail.** Every write tool call is appended to the audit log with its arguments (redacted),
  the session, the token's name and scope, `dryRun` and `notConfirmed`; the file rotates at 5 MB.
- **Sessions** belong to the token that opened them and expire after 30 idle minutes.

Configuration changes need a restart of homeswift to apply; the tools say so, and back up the previous
file under `backups/` next to config.json (the last 20 are kept).
