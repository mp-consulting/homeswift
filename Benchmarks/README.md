# Benchmarks: Homeswift vs HAP-NodeJS

The same HomeKit controller drives two bridges that expose the same accessories, and measures each server
process: Homeswift's `HAPServer` and HAP-NodeJS, the library inside Homebridge.

| Piece | What it is |
|---|---|
| `Sources/hap-bench` | The controller: pair setup (SRP), pair verify, encrypted sessions, reads, writes, events, concurrent load. It carries its own copy of the pairing primitives so the server under test builds without `-enable-testing`. |
| `Sources/hap-bench-server` | A Homeswift bridge with `ACCESSORIES` lightbulbs (On, Brightness, Hue, Saturation), release build. |
| `hap-nodejs/server.js` | The same bridge on `@homebridge/hap-nodejs` 2.2.2, the version Homebridge 2.4.0 ships. |
| `run.sh` | Builds everything, runs the suite against both servers, prints the comparison. |
| `Sources/bridge-bench-server`, `bridge-bench.py` | A whole bridge as the CLI runs it (plugin runtime, web UI, MCP server) on a synthetic home, and the script that times every endpoint: see [The whole bridge](#the-whole-bridge-web-ui-and-mcp-server). |

```sh
./run.sh                                   # 30 accessories, the counts below
./run.sh --accessories 100 --requests 1000 # any hap-bench option
```

Results land in `results/<name>.json` (every sample of the fixed-count phases, percentiles of the load runs) and
`results/<name>.log` (the server's output); `hap-bench compare a.json b.json` prints the table again.

## What is measured

- **Startup**: from spawning the process until the port accepts a TCP connection.
- **Pair setup** ×21: a fresh controller pairs (M1→M6), verifies, removes its pairing, 21 times. Each step is
  timed from writing the request to the complete response, so the controller's own SRP work between steps is
  excluded; *round trips* is the sum of the three, *wall* includes the client side.
- **Pair verify** ×100: new connections of the paired controller (M1→M4).
- **Request latency**: 300 timed requests per operation on one verified connection after 20 warm-ups:
  the whole database, ten characteristics in one read, one write, ten writes in one request.
- **Event latency** ×50: a second verified connection subscribes to a brightness; the first writes a new value;
  the time from the write to the event arriving on the subscriber.
- **Throughput**: 1, 4 and 16 verified connections each sending requests back to back for 5 s; the server's
  CPU time over the run divided by the requests gives *CPU per request*.
- **Process**: resident size and CPU time from `ps`, physical footprint from `top` (what Activity Monitor
  shows), sampled between phases.

Both bridges advertise over mDNS: Homeswift through the system's mDNSResponder, HAP-NodeJS through
`@homebridge/ciao` in-process, Homebridge's default. Both have a no-op write handler on every characteristic,
as a plugin would. Everything runs on one machine over loopback, so network latency is absent and the client
competes with the server for cores during the load runs.

## Results, 30 accessories

Apple M1 (8 cores), macOS 27.0.1, 2026-10-21. Homeswift's `Sources/Homeswift` at commit `76ab1b0`
(`swift build -c release`, Swift 6.4). HAP-NodeJS 2.2.2 on Node 25.9.0 with default flags. `/accessories` is 44 KB on both. One run
each; p50 is stable from run to run, p99 less so. The ratio column is HAP-NodeJS ÷ Homeswift (the inverse
for throughput), so above 1 means Homeswift is faster or smaller.

| Metric | Homeswift | HAP-NodeJS | ratio |
|---|---:|---:|---:|
| Startup to listening (one launch, see below) | 59 ms | 399 ms | 6.8× |
| Memory idle, RSS | 8.6 MB | 76.1 MB | 8.8× |
| Memory idle, footprint | 3.9 MB | 43.0 MB | 11.0× |
| Memory after run, RSS | 9.4 MB | 76.5 MB | 8.2× |
| Memory after run, footprint | 5.7 MB | 87.0 MB | 15.2× |
| Threads (idle / after run) | 11 / 14 | 8 / 12 | |
| CPU time, pairing phase (21 setups + verifies) | 0.27 s | 2.89 s | 10.7× |
| CPU time, pair verify phase (100 verifies) | 0.04 s | 1.63 s | 40.7× |
| CPU time, latency phase (1 280 requests) | 0.26 s | 0.59 s | 2.3× |
| CPU time, events phase (50 writes) | 0.01 s | 0.12 s | 12.0× |
| Pair setup, M1→M2 p50 | 5.13 ms | 57.44 ms | 11.2× |
| Pair setup, M3→M4 (SRP proof) p50 | 5.21 ms | 52.02 ms | 10.0× |
| Pair setup, M5→M6 p50 | 1.55 ms | 10.01 ms | 6.5× |
| Pair setup, server round trips p50 | 12.06 ms | 120.02 ms | 10.0× |
| Pair setup, server round trips max | 16.50 ms | 303.39 ms | 18.4× |
| Pair setup, wall p50 | 25.70 ms | 135.86 ms | 5.3× |
| Pair verify, round trips p50 | 0.57 ms | 12.50 ms | 22.0× |
| Pair verify, round trips p99 | 2.71 ms | 27.89 ms | 10.3× |
| GET /accessories p50 | 0.892 ms | 1.513 ms | 1.7× |
| GET /accessories p99 | 1.925 ms | 2.971 ms | 1.5× |
| GET /characteristics ×10 p50 | 0.118 ms | 0.155 ms | 1.3× |
| GET /characteristics ×10 p99 | 0.214 ms | 0.390 ms | 1.8× |
| PUT /characteristics ×1 p50 | 0.101 ms | 0.114 ms | 1.1× |
| PUT /characteristics ×1 p99 | 0.207 ms | 0.387 ms | 1.9× |
| PUT /characteristics ×10 p50 | 0.139 ms | 0.147 ms | 1.1× |
| PUT /characteristics ×10 p99 | 0.214 ms | 0.578 ms | 2.7× |
| Event latency p50 | 0.30 ms | 252.39 ms | 834× |
| Event latency p99 | 11.99 ms | 256.14 ms | 21.4× |
| GET /characteristics ×10, 1 connection | 7 693 req/s | 6 592 req/s | 1.2× |
| CPU per request | 61 µs | 88 µs | 1.4× |
| GET /characteristics ×10, 4 connections | 19 956 req/s | 14 743 req/s | 1.4× |
| CPU per request | 85 µs | 63 µs | 0.7× |
| GET /characteristics ×10, 16 connections | 32 305 req/s | 15 654 req/s | 2.1× |
| CPU per request | 91 µs | 61 µs | 0.7× |
| latency p99 | 2.633 ms | 2.270 ms | 0.9× |
| GET /accessories, 4 connections | 2 770 req/s | 1 047 req/s | 2.6× |
| CPU per request | 743 µs | 945 µs | 1.3× |
| PUT /characteristics ×1, 4 connections | 18 989 req/s | 13 086 req/s | 1.5× |
| CPU per request | 79 µs | 62 µs | 0.8× |

## Results, 100 accessories

A shorter pass (`--accessories 100 --pairings 5 --verifies 20 --requests 200 --events 20 --duration 3`) to
see how the database size scales. `/accessories` is 145 KB.

| Metric | Homeswift | HAP-NodeJS | ratio |
|---|---:|---:|---:|
| Memory idle, RSS | 7.9 MB | 90.3 MB | 11.4× |
| Memory idle, footprint | 5.3 MB | 47.0 MB | 8.8× |
| Memory after run, RSS | 16.2 MB | 159.9 MB | 9.9× |
| Memory after run, footprint | 6.8 MB | 143.0 MB | 21.2× |
| Pair setup, server round trips p50 | 13.70 ms | 109.10 ms | 8.0× |
| Pair verify, round trips p50 | 0.61 ms | 11.62 ms | 19.0× |
| GET /accessories p50 | 2.551 ms | 4.097 ms | 1.6× |
| GET /accessories p99 | 3.278 ms | 10.460 ms | 3.2× |
| GET /characteristics ×10 p50 | 0.146 ms | 0.250 ms | 1.7× |
| GET /characteristics ×10 p99 | 0.205 ms | 0.983 ms | 4.8× |
| PUT /characteristics ×1 p50 | 0.101 ms | 0.154 ms | 1.5× |
| PUT /characteristics ×1 p99 | 0.167 ms | 0.910 ms | 5.5× |
| Event latency p50 | 0.21 ms | 252.31 ms | 1192× |
| GET /characteristics ×10, 1 connection | 8 434 req/s | 6 202 req/s | 1.4× |
| GET /characteristics ×10, 16 connections | 21 569 req/s | 15 551 req/s | 1.4× |
| CPU per request | 93 µs | 59 µs | 0.6× |
| latency p99 | 6.048 ms | 2.023 ms | 0.3× |
| GET /accessories, 4 connections | 461 req/s | 329 req/s | 1.4× |
| CPU per request | 3 300 µs | 3 003 µs | 0.9× |
| latency p99 | 48.976 ms | 20.709 ms | 0.4× |

The single-connection numbers hold their ratios; HAP-NodeJS's tails get longer as the database grows (its p99
for a ten-characteristic read goes from 0.39 to 0.98 ms, Homeswift's stays at 0.2 ms) and its heap grows to
143 MB under load. Under saturation with 16 connections, though, Homeswift's p99 is worse (6 ms against 2 ms,
49 ms against 21 ms on the 145 KB database) while it still serves more requests: it runs on every core, so on
one machine it competes with the controller for the same eight cores, while Node's single thread leaves the
rest to the client. Those two rows say more about the test setup than about the servers; the per-request CPU
at saturation (93 µs against 59 µs) is the real difference, and the same one as with 30 accessories.

## Startup and whole bridges

The suite times one launch, and a binary's first launch after it was built or installed costs extra on macOS
(the 315 ms Homeswift showed on the 100-accessory pass was that: the server had just been relinked). `hap-bench
idle` starts a bridge, times it to the first accepted connection and samples it at rest; three launches each:

| Process | Startup to listening | Footprint at rest | RSS at rest | Threads |
|---|---:|---:|---:|---:|
| Homeswift server, 30 accessories | 15–24 ms | 3.9 MB | 7 MB | 11 |
| Homeswift server, 100 accessories | 24–28 ms | 5.0 MB | 7–8 MB | 11 |
| Homeswift server, 300 accessories | 33–45 ms | 7.5 MB | 7–11 MB | 11 |
| HAP-NodeJS server, 30 accessories | 114–303 ms | 39–41 MB | 76–78 MB | 8 |
| `homeswift` CLI, no plugins (commit `76ab1b0`) | 22–39 ms | 4.7 MB | 11–12 MB | 10 |
| Homebridge 2.4.0, no plugins | 412–475 ms | 43–48 MB | 73–92 MB | 12 |

The last two rows are the bridges people actually run, each with an empty config: Homebridge is the library
plus its plugin loader and `@matter/main`; the CLI is the library plus the plugin runtime, the Assistant and the MCP server, which an empty config
leaves off (the web UI was not yet committed). Homebridge's first launch after `npm install` took
0.9–1.1 s. Homeswift's footprint grows by about 12 KB per accessory; HAP-NodeJS's by about 80 KB, before V8's
heap growth under load.

```sh
BIN=$(swift build -c release --scratch-path ~/Library/Caches/homeswift-bench --show-bin-path)
PORT=52000 ACCESSORIES=300 "$BIN/hap-bench" idle --name homeswift-300 --port 52000 --seconds 3 -- "$BIN/hap-bench-server"
"$BIN/hap-bench" idle --name homebridge --port 52002 --seconds 15 -- node .../homebridge/bin/homebridge -U <dir> -Q
```

## Found along the way

- `HAPServer.bind` tried the configured port and port 0 in the order of a `Set`, which is random per launch,
  so about every other launch the bridge came up on a random port (the `homeswift` CLI from commit `76ab1b0`
  did it once in three launches here, the bench server once in two). Bonjour re-advertises the new port, so
  the Home app recovers, but anything that pins the port does not. Fixed in `Sources/Homeswift/Server/HAPServer.swift`
  by trying the configured port first.
- Homeswift's CPU per request rises with the number of concurrent connections (61 µs on one, 85–93 µs on four
  or more) while HAP-NodeJS's falls (88 → 59 µs). The request path crosses from the NIO event loop into the
  connection's task and back, and takes the server's state lock several times. Profiled on 2026-10-23: a fifth of
  the inbound work was `HTTPRequest.parse` going through Foundation (byte by byte since `04ba6b8`, 2.7× fewer
  instructions a request), and the hops each way between the loop and the task. Each connection's task now runs on
  its channel's event loop (a `TaskExecutor` preference, macOS 15 and Linux). Back to back with `7c45fef`, twice,
  30 accessories, on a busy machine (the same caveats as above):

  | `hap-bench` | `7c45fef` | after | |
  |---|---:|---:|---:|
  | GET /characteristics ×10, 1 connection | 9 259 req/s, 59 µs CPU | 10 254 req/s, 50 µs CPU | 1.11× |
  | GET /characteristics ×10, 4 connections | 22 783 req/s, 91 µs CPU | 26 759 req/s, 69 µs CPU | 1.17× |
  | GET /characteristics ×10, 16 connections | 34 130 req/s, 115 µs CPU | 36 728 req/s, 111 µs CPU | 1.08× |
  | PUT /characteristics ×1, 4 connections | 21 232 req/s, 88 µs CPU | 26 478 req/s, 60 µs CPU | 1.25× |
  | GET /accessories, 4 connections | 3 683 req/s, 744 µs CPU | 3 712 req/s, 724 µs CPU | 1.0× |

  Single-request latencies, pairing, events and memory are unchanged. The task on the loop alone, against the same
  code without it: 58 → 50 µs on one connection, 89 → 69 µs on four, the same on sixteen.

## Reading the numbers

**Footprint and startup.** A Homeswift bridge with 30 accessories is a 4 MB process that listens 15–25 ms after
launch; the HAP-NodeJS one is 40 MB (87 MB after the load runs, V8's heap grows and keeps the room) and takes
115–300 ms to load its modules. Neither number includes Homebridge itself, which adds its plugin loader,
`@matter/main` and the rest on top of HAP-NodeJS.

**Pairing is 10–22× faster, which is where the libraries differ most.** Pair setup is 3072-bit SRP:
Homeswift does the modular exponentiation in C (`CHAPMath`, Montgomery multiplication), HAP-NodeJS in
pure-JavaScript `BigInt` through `fast-srp-hap`, so each of its SRP steps costs 50 ms of a single thread and the
whole exchange 120 ms (up to 300 ms) against 12 ms. Pair verify is Curve25519 and Ed25519: Homeswift uses
swift-crypto (CryptoKit on macOS, BoringSSL on Linux), HAP-NodeJS the pure-JavaScript `tweetnacl`, hence
12.5 ms against 0.6 ms and 1.6 s of CPU for a hundred verifies against 0.04 s. Every connection a Home hub or
an iPhone opens starts with a pair verify, so this is not a one-off cost.

**Encrypted requests are close.** Once the session is up, both sides use a native ChaCha20-Poly1305 (Node's
OpenSSL, swift-crypto) and native JSON, and a read or a write takes 0.1 ms on either. Homeswift is 1.3–1.7×
faster at p50 with tighter tails (its p99 is roughly half), and 1.7× faster on the 44 KB database, which it
writes with its own JSON writer. The one metric HAP-NodeJS wins is CPU per request under concurrent load,
61–63 µs against 85–91 µs: Homeswift's cost per request grows with the number of connections (61 µs on one),
which points at the hand-offs between NIO's event loops and each connection's task, and at lock traffic, as
something to look at. It does not show in latency: at 16 connections Homeswift serves twice the requests
because the work spreads over the cores while Node's single thread plateaus around 15 000 req/s, with a
similar p99.

**Events arrive in 0.3 ms instead of 250 ms.** HAP-NodeJS holds every event notification for
`EVENT_COALESCING_DELAY` (250 ms, `eventedhttp.ts`) to batch changes, except button events; Homeswift sends
each one as it happens. That is a design choice in HAP-NodeJS rather than a cost of the runtime, but it is a
quarter of a second added to every state change HomeKit learns through a Homebridge bridge, and to every
automation that reacts to one.

**Caveats.** The HAP-NodeJS script is the library alone, run the way Homebridge runs it (default advertiser,
default Node flags) on Node 25, one ahead of the versions its `engines` lists. The controller is Swift on NIO;
its own costs are the same for both servers and excluded from the per-step pairing times, but during the load
runs it shares the eight cores with the server. A Raspberry Pi would stretch every CPU-bound number, pairing
above all; it would not change the ratios much.

## The whole bridge: web UI and MCP server

`bridge-bench-server` runs what the `homeswift` CLI runs, the plugin runtime with the web UI (no sign-in, on
127.0.0.1) and the MCP server over one catalog, with a plugin of its own instead of devices: `ACCESSORIES`
(60 by default) lamps, plugs, thermostats, sensors, blinds, fans, purifiers and switches, a sensor that changes
every `TICK_MS` and logs a line, and `LOG_LINES` lines logged before it is ready. `bridge-bench.py` (standard
library only) starts it and times, on one keep-alive connection after warm-ups, every page and API route of the
web UI, every MCP method and read tool, a write through each, the latency from a write to its event on
`/api/events`, throughput and CPU per request on 1 to 8 connections, and the process's memory and idle CPU.

```sh
BIN=$(swift build -c release --scratch-path ~/Library/Caches/homeswift-bench --show-bin-path)
./bridge-bench.py --server "$BIN/bridge-bench-server" --name after
./bridge-bench.py compare results/before.json results/after.json
```

Apple M1, 2026-10-23, 5 000 log lines, `/api/accessories` 72 KB with 60 accessories and 355 KB with 300. Before is
commit `7c45fef`, after is `cbde386` (the changes below). The two ran interleaved, before then after, at 60 then 300
accessories, twice, while other sessions' builds kept the load average around 600: each figure is the better of its
two runs. Under that load a route under a millisecond measures scheduling more than the bridge (0.1 to 0.9 ms on
either side, from run to run), so those are left out; CPU per request is the steadier figure.

| Endpoint, p50 | before, 60 | after, 60 | before, 300 | after, 300 |
|---|---:|---:|---:|---:|
| MCP `search_logs` | 2 517 ms | 9.8 ms | 8 831 ms | 15 ms |
| MCP `get_recent_logs` (200 lines) | 106 ms | 1.8 ms | 521 ms | 2.4 ms |
| `GET /api/logs?accessory=` | 28 ms | 4.7 ms | 134 ms | 7.6 ms |
| `GET /api/logs` (2 000 lines, 238 KB) | 11 ms | 6.0 ms | 36 ms | 4.4 ms |
| `GET /api/logs?from=` (an hour from the archive, 600 KB) | 49 ms | 51 ms | 233 ms | 51 ms |
| `GET /api/accessories` | 5.9 ms | 4.3 ms | 134 ms | 31 ms |
| MCP `list_accessories` | 5.4 ms | 2.2 ms | 60 ms | 13 ms |
| MCP `resources/read accessories` | 4.7 ms | 2.0 ms | 44 ms | 14 ms |
| MCP `tools/list` (12 KB) | 1.3 ms | 0.7 ms | 1.9 ms | 0.7 ms |
| a write → its event on `/api/events` | 1.3 ms | 1.4 ms | 1.8 ms | 1.0 ms |

| Load, CPU per request | before, 60 | after, 60 | before, 300 | after, 300 |
|---|---:|---:|---:|---:|
| `GET /api/accessories`, 8 connections | 6 234 µs | 1 697 µs | 31 000 µs | 10 769 µs |
| `GET /api/logs`, 4 connections | 10 882 µs | 3 085 µs | 11 262 µs | 3 714 µs |
| MCP `list_accessories`, 4 connections | 4 216 µs | 1 383 µs | 20 000 µs | 8 622 µs |
| `GET /api/status`, 8 connections | 140 µs | 130 µs | 181 µs | 106 µs |
| `GET /app.js`, 8 connections | 113 µs | 105 µs | 106 µs | 79 µs |

| Process | before, 60 | after, 60 | before, 300 | after, 300 |
|---|---:|---:|---:|---:|
| Startup, CPU (to 2 s after ready) | 0.35 s | 0.18 s | 7.6 s | 3.1 s |
| Startup, wall, to ready (noisy: 29 to 112 s for the same baseline) | 0.9 s | 0.9 s | 29–112 s | 20–32 s |
| Idle RSS / footprint | 16 / 10 MB | 16 / 10 MB | 15 / 14 MB | 20 / 18 MB |
| Idle CPU | 0.0 % | 0.0 % | 0.2 % | 0.0 % |

The before `search_logs` on 300 accessories ran past the client's 30 s timeout in a first attempt; the script now
gives each endpoint a 15 s budget (at least five samples) and always stops the server it started.

`logs?from=` did not move with `cbde386`: its time went to reading the archive back. Commit `01c6cc3` walks a
segment from its end in place, reads each row's members without a dictionary (`JSONValue.members(of:)`), and writes
the log answers directly (`UIServer.logsJSON`, the same bytes). Measured the same way, interleaved with `7c45fef`
twice, the better run of each:

| Log route, p50 | before, 60 | after `01c6cc3`, 60 | before, 300 | after `01c6cc3`, 300 |
|---|---:|---:|---:|---:|
| `GET /api/logs?from=` (an hour from the archive, 600 KB) | 35 ms | 9.5 ms | 37 ms | 8.1 ms |
| `GET /api/logs` (2 000 lines) | 9.1 ms | 1.2 ms | 13 ms | 1.1 ms |
| `GET /api/logs?accessory=` | 22 ms | 3.2 ms | 23 ms | 3.1 ms |
| `GET /api/logs`, 4 connections, CPU per request | 10 538 µs | 2 849 µs | 11 176 µs | 2 198 µs |

Where the time went, from `sample`:

- **Foundation's JSON coders.** `JSONValue` went through `JSONEncoder` and `JSONDecoder`, whose generic paths
  (dynamic casts, a trial decode of every type at every value) took most of each request. It now writes and
  parses its JSON itself: the same bytes `JSONEncoder` wrote (sorted keys, its escapes and number forms, checked
  on random documents), 7–13× faster to write and 20–30× faster to parse. That also helps every plugin that
  decodes a cloud's answers through `JSONValue` (UniFi Protect's bootstrap is hundreds of KB).
- **The redaction regexes.** `Redaction.redactText`'s secret-pair expression backtracks through every word,
  and eight more scan each line: about 450 µs a log line. ASCII text now skips the expressions it cannot
  match, using byte searches (a keyword and a separator, `Bearer`, the exact digit groups of a setup code).
  Every log line starts with a date, so a looser test let the setup-code expressions run on all of them.
- **The log.** `LogBuffer` shifted its 5 000 lines on every line once full; it is a ring now. The archive
  encoded and decoded each line with the Codable coders; ISO 8601 times went through a format style.
- **Static files** carried `no-store`: a reload downloaded 230 KB of scripts and styles again. They carry an
  ETag and `no-cache` now and answer 304; pages and the API keep `no-store`.

### On a quiet machine, final

The tables above ran while other builds kept the load average between 40 and 600. Measured again once the machine was
quiet (load average 15 to 35): the whole bridge with 300 accessories, `7c45fef` against `0518b4b`, interleaved
twice, the better run of each.

| 300 accessories | `7c45fef` | `0518b4b` | |
|---|---:|---:|---:|
| MCP `search_logs`, p50 | 931 ms | 7.3 ms | 128× |
| MCP `get_recent_logs`, p50 | 61 ms | 0.83 ms | 74× |
| `GET /api/logs`, p50 | 8.3 ms | 0.80 ms | 10× |
| `GET /api/logs?accessory=`, p50 | 21 ms | 3.1 ms | 6.9× |
| `GET /api/logs?from=` (an hour), p50 | 34 ms | 7.3 ms | 4.6× |
| `GET /api/accessories` (365 KB), p50 | 22 ms | 5.9 ms | 3.7× |
| MCP `list_accessories`, p50 | 14 ms | 5.2 ms | 2.7× |
| MCP `resources/read accessories`, p50 | 8.5 ms | 3.9 ms | 2.2× |
| MCP `tools/list`, p50 | 0.51 ms | 0.18 ms | 2.9× |
| `PUT /api/accessories/<id>`, p50 | 0.35 ms | 0.16 ms | 2.1× |
| `GET /api/accessories`, 8 connections, CPU per request | 35.8 ms | 9.5 ms | 3.8× |
| `GET /api/logs`, 4 connections, CPU per request | 10.6 ms | 0.89 ms | 12× |
| MCP `list_accessories`, 4 connections, CPU per request | 17.0 ms | 6.0 ms | 2.8× |
| Startup to ready, with 5 000 log lines | 4.2 s | 0.41 s | 10× |
| Memory at rest, RSS / footprint | 28–31 / 14–16 MB | 30–31 / 12–19 MB | |

And the HAP server alone (`hap-bench`, the same two commits, interleaved twice at 30 and at 100 accessories; the
two sizes agree):

| `hap-bench`, 30 accessories | `7c45fef` | `0518b4b` | |
|---|---:|---:|---:|
| GET /characteristics ×10, 1 connection | 8 571 req/s, 62 µs CPU | 9 280 req/s, 52 µs CPU | 1.08× |
| GET /characteristics ×10, 4 connections | 22 868 req/s, 86 µs CPU | 25 138 req/s, 70 µs CPU | 1.10× |
| GET /characteristics ×10, 16 connections | 32 405 req/s, 110 µs CPU | 35 267 req/s, 106 µs CPU | 1.09× |
| PUT /characteristics ×1, 4 connections | 22 717 req/s, 81 µs CPU | 26 140 req/s, 59 µs CPU | 1.15× |
| GET /accessories, pair setup, pair verify, events, memory | | unchanged | |

What is left: `/api/accessories` spends a third of its 5.9 ms building the generic `JSONValue` tree and two thirds
writing it (sorted keys); a writer of its own would duplicate the accessory JSON the MCP tools share, for a page
that loads it once. HAP's `GET /accessories` (2.5 ms for 145 KB at 100 accessories) is the server's own JSON writer
and the session's encryption, fetched when the configuration number changes.

The Status page's history (`GET /api/metrics`, the last hour, and one accessory's), the Accessories page's layout
(`GET /api/layout`), a plugin's own web API (`/api/plugins/<platform>/<name>/…`, the bench plugin's device list) and
the status routes all answer within a millisecond, at 60 and at 300 accessories (quiet machine, `0518b4b`):

| p50 | 60 accessories | 300 accessories |
|---|---:|---:|
| `GET /api/metrics` / `?accessory=` | 0.11 / 0.12 ms | 0.09 / 0.17 ms |
| `GET /api/layout` | 0.10 ms | 0.11 ms |
| `GET /api/plugins/BenchHome/…/devices` (4 / 20 KB) | 0.19 ms | 0.53 ms |
| `GET /api/status`, MCP `get_server_status` | 0.12 / 0.11 ms | 0.20 / 0.40 ms |
| a write → its event on `/api/events` | 0.29 ms | 0.91 ms |

`bridge-bench-server` binds the web UI and the MCP server to free ports unless `UI_PORT` and `MCP_PORT` say
otherwise, and READY says which: two runs side by side (another session's, say) no longer collide, and a server that
cannot start exits with its error instead of leaving the script waiting for READY.

### Adding accessories

A plugin adds its accessories one at a time. Each add rewrote the whole accessory cache with `JSONEncoder`, and
on a running server rehashed the whole database, re-encoded the persisted state with its iid map and re-
advertised: N² for N accessories. Commit `6722697` saves the cache once per burst, skips the rehash when an
accessory replaces one of the same shape under the same ids (a plugin replacing its cached accessories at launch),
and looks for a free iid only when one is needed. With 300 accessories the bridge's startup CPU went from 7.6 to
3.1 s (the Process table above); the rest is the first launch's own work, adding 300 accessories and logging
5 000 lines.

That first launch was still N²: every accessory with new ids rehashed the database and re-encoded the persisted
state, its iid map included, with `JSONEncoder`. The ids are still saved with every such accessory; the state is
written with the server's own JSON writer, and the number goes up without a hash (new ids change the database
whatever it hashes to), the hash caught up a quarter of a second after the burst, or at `stop()`. Measured on a
quiet machine (load average 35), no warm-up log lines (`LOG_LINES=0`), CPU time to 0.6 s after ready:

| Startup, to ready | `7c45fef` | after | |
|---|---:|---:|---:|
| 300 accessories, a restart (cached accessories replaced by the plugin's) | 7 867 ms (7.8 s CPU) | 71 ms (0.12 s CPU) | 110× |
| 300 accessories, first launch | 4 020 ms (4.0 s CPU) | 298 ms (0.36 s CPU) | 13× |
| 60 accessories, a restart | 360 ms | 27 ms | 13× |
| 60 accessories, first launch | 218 ms | 51 ms | 4× |

The HAP side (`hap-bench`): see "Found along the way" above for its request path.

