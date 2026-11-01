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

Apple M1 (8 cores), macOS 27.0.1, 2026-11-01. Homeswift at commit `502b8b6` (`swift build -c release`, Swift 6.4).
HAP-NodeJS 2.2.2 on Node 26.12.1 with default flags. `/accessories` is 44 KB on both. One run each; p50 is stable
from run to run, p99 less so. The ratio column is HAP-NodeJS ÷ Homeswift (the inverse for throughput), so above 1
means Homeswift is faster or smaller. Startup is the median of three launches with `hap-bench idle` (below): the
suite's own launch is the first after a build, which macOS makes slow.

| Metric | Homeswift | HAP-NodeJS | ratio |
|---|---:|---:|---:|
| Startup to listening (three launches, see below) | 11 ms | 168 ms | 15.3× |
| Memory idle, RSS | 10.5 MB | 78.7 MB | 7.5× |
| Memory idle, footprint | 3.8 MB | 46.0 MB | 12.2× |
| Memory after run, RSS | 14.2 MB | 160.5 MB | 11.3× |
| Memory after run, footprint | 7.2 MB | 105.0 MB | 14.7× |
| Threads (idle / after run) | 11 / 10 | 8 / 12 |  |
| CPU time, pairing phase | 0.22 s | 2.16 s | 9.8× |
| CPU time, pair verify phase | 0.04 s | 1.23 s | 30.7× |
| CPU time, latency phase | 0.12 s | 0.42 s | 3.5× |
| CPU time, events phase | 0.03 s | 0.13 s | 4.3× |
| Pair setup, M1→M2 p50 | 4.72 ms | 39.99 ms | 8.5× |
| Pair setup, M3→M4 (SRP) p50 | 4.76 ms | 39.55 ms | 8.3× |
| Pair setup, M5→M6 p50 | 0.72 ms | 7.41 ms | 10.3× |
| Pair setup, server round trips p50 | 10.20 ms | 87.15 ms | 8.5× |
| Pair setup, server round trips max | 15.66 ms | 108.28 ms | 6.9× |
| Pair setup, wall p50 | 22.62 ms | 99.62 ms | 4.4× |
| Pair verify, round trips p50 | 0.49 ms | 9.56 ms | 19.6× |
| Pair verify, round trips p99 | 0.60 ms | 13.70 ms | 22.9× |
| GET /accessories p50 | 0.474 ms | 1.112 ms | 2.3× |
| GET /accessories p99 | 0.577 ms | 1.223 ms | 2.1× |
| GET /characteristics ×10 p50 | 0.115 ms | 0.133 ms | 1.2× |
| GET /characteristics ×10 p99 | 0.170 ms | 0.262 ms | 1.5× |
| PUT /characteristics ×1 p50 | 0.081 ms | 0.107 ms | 1.3× |
| PUT /characteristics ×1 p99 | 0.104 ms | 0.134 ms | 1.3× |
| PUT /characteristics ×10 p50 | 0.127 ms | 0.119 ms | 0.9× |
| PUT /characteristics ×10 p99 | 0.153 ms | 0.157 ms | 1.0× |
| Event latency p50 | 52.62 ms | 253.38 ms | 4.8× |
| Event latency p99 | 59.81 ms | 254.57 ms | 4.3× |
| GET /characteristics ×10 ×1 throughput | 9 710 req/s | 8 641 req/s | 1.1× |
| GET /characteristics ×10 ×1 CPU per request | 60 µs | 70 µs | 1.2× |
| GET /characteristics ×10 ×1 latency p99 | 0.128 ms | 0.154 ms | 1.2× |
| GET /characteristics ×10 ×4 throughput | 30 311 req/s | 21 834 req/s | 1.4× |
| GET /characteristics ×10 ×4 CPU per request | 72 µs | 46 µs | 0.6× |
| GET /characteristics ×10 ×4 latency p99 | 0.260 ms | 0.296 ms | 1.1× |
| GET /characteristics ×10 ×16 throughput | 42 741 req/s | 22 570 req/s | 1.9× |
| GET /characteristics ×10 ×16 CPU per request | 131 µs | 44 µs | 0.3× |
| GET /characteristics ×10 ×16 latency p99 | 1.135 ms | 0.901 ms | 0.8× |
| GET /accessories ×4 throughput | 8 286 req/s | 1 346 req/s | 6.2× |
| GET /accessories ×4 CPU per request | 217 µs | 764 µs | 3.5× |
| GET /accessories ×4 latency p99 | 0.787 ms | 3.315 ms | 4.2× |
| PUT /characteristics ×1 ×4 throughput | 37 550 req/s | 27 035 req/s | 1.4× |
| PUT /characteristics ×1 ×4 CPU per request | 43 µs | 37 µs | 0.9× |
| PUT /characteristics ×1 ×4 latency p99 | 0.193 ms | 0.216 ms | 1.1× |

## Results, 100 accessories

The same suite with `--accessories 100`, to see how the database size scales. `/accessories` is 145 KB.

| Metric | Homeswift | HAP-NodeJS | ratio |
|---|---:|---:|---:|
| Memory idle, RSS | 11.7 MB | 83.8 MB | 7.2× |
| Memory idle, footprint | 4.9 MB | 51.0 MB | 10.5× |
| Memory after run, RSS | 18.8 MB | 173.3 MB | 9.2× |
| Memory after run, footprint | 12.0 MB | 116.0 MB | 9.7× |
| Pair setup, server round trips p50 | 10.35 ms | 84.44 ms | 8.2× |
| Pair verify, round trips p50 | 0.47 ms | 9.60 ms | 20.2× |
| GET /accessories p50 | 1.240 ms | 2.905 ms | 2.3× |
| GET /accessories p99 | 1.288 ms | 3.152 ms | 2.4× |
| GET /characteristics ×10 p50 | 0.116 ms | 0.133 ms | 1.1× |
| GET /characteristics ×10 p99 | 0.170 ms | 0.247 ms | 1.4× |
| PUT /characteristics ×1 p50 | 0.084 ms | 0.112 ms | 1.3× |
| PUT /characteristics ×1 p99 | 0.103 ms | 0.154 ms | 1.5× |
| Event latency p50 | 52.67 ms | 253.45 ms | 4.8× |
| GET /characteristics ×10 ×1 throughput | 9 846 req/s | 8 665 req/s | 1.1× |
| GET /characteristics ×10 ×16 throughput | 42 680 req/s | 22 318 req/s | 1.9× |
| GET /characteristics ×10 ×16 CPU per request | 131 µs | 44 µs | 0.3× |
| GET /characteristics ×10 ×16 latency p99 | 1.069 ms | 1.005 ms | 0.9× |
| GET /accessories ×4 throughput | 2 865 req/s | 430 req/s | 6.7× |
| GET /accessories ×4 CPU per request | 639 µs | 2 371 µs | 3.7× |
| GET /accessories ×4 latency p99 | 2.313 ms | 10.113 ms | 4.4× |

The single-connection numbers hold their ratios as the database grows. `GET /accessories` is where size shows:
Homeswift builds its body once and fills in the values per request (a template since commit `502b8b6`), so with
four connections it serves 6.7× the requests at a quarter of the CPU each, where it was 1.4× and 0.9× before.
HAP-NodeJS's heap grows to 116 MB under load. Under saturation with 16 connections Homeswift serves twice the
requests at a similar p99, but spends 131 µs of CPU on each against Node's 44 µs: it runs on every core, and on
one machine competes with the controller for them, while Node's single thread leaves the rest to the client.
The per-request CPU at saturation is the real difference, the same one as with 30 accessories.

## Startup and whole bridges

The suite times one launch, and a binary's first launch after it was built or installed costs extra on macOS
(the 256 ms Homeswift showed on the 30-accessory pass was that: the server had just been built). `hap-bench
idle` starts a bridge, times it to the first accepted connection and samples it at rest; three launches each. The
30-accessory servers were measured on 2026-11-01, the other rows on 2026-10-21:

| Process | Startup to listening | Footprint at rest | RSS at rest | Threads |
|---|---:|---:|---:|---:|
| Homeswift server, 30 accessories | 11 ms | 3.7 MB | 10.3–10.4 MB | 11 |
| Homeswift server, 100 accessories | 24–28 ms | 5.0 MB | 7–8 MB | 11 |
| Homeswift server, 300 accessories | 33–45 ms | 7.5 MB | 7–11 MB | 11 |
| HAP-NodeJS server, 30 accessories | 167–176 ms | 46–47 MB | 79–80 MB | 8 |
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

**Footprint and startup.** A Homeswift bridge with 30 accessories is a 4 MB process that listens 11 ms after
launch; the HAP-NodeJS one is 46 MB (105 MB after the load runs, V8's heap grows and keeps the room) and takes
about 170 ms to load its modules. Neither number includes Homebridge itself, which adds its plugin loader,
`@matter/main` and the rest on top of HAP-NodeJS.

**Pairing is 8–20× faster, which is where the libraries differ most.** Pair setup is 3072-bit SRP:
Homeswift does the modular exponentiation in C (`CHAPMath`, Montgomery multiplication), HAP-NodeJS in
pure-JavaScript `BigInt` through `fast-srp-hap`, so each of its SRP steps costs 40 ms of a single thread and the
whole exchange 87 ms (up to 108 ms) against 10 ms. Pair verify is Curve25519 and Ed25519: Homeswift uses
swift-crypto (CryptoKit on macOS, BoringSSL on Linux), HAP-NodeJS the pure-JavaScript `tweetnacl`, hence
9.6 ms against 0.5 ms and 1.2 s of CPU for a hundred verifies against 0.04 s. Every connection a Home hub or
an iPhone opens starts with a pair verify, so this is not a one-off cost.

**Encrypted requests are close; the database is not.** Once the session is up, both sides use a native
ChaCha20-Poly1305 (Node's OpenSSL, swift-crypto) and native JSON, and a read or a write takes 0.1 ms on either.
Homeswift is 1.1–1.3× faster at p50 with tighter tails, and 2.3× faster on the 44 KB database, which it keeps as a
template and fills in. The one metric HAP-NodeJS wins is CPU per request under concurrent load, 37–46 µs against
43–131 µs: Homeswift's cost per request grows with the number of connections (60 µs on one). A profile at 16
connections (`sample`, 2026-11-01) finds about a third of that growth in the server's state lock, which a read
takes once per characteristic to find it (`HAPServer.accessory(aid:)`), and again for the request's context and its
timing: 14% of the busy samples were threads waiting on it (19% with taking and releasing it), none on one
connection; the rest is spread over allocation, reference counting and the hand-offs between NIO's event loops
and each connection's task. It does not show in latency: at 16 connections Homeswift serves twice the requests
because the work spreads over the cores while Node's single thread plateaus around 22 000 req/s, with a similar p99.

**Events arrive in 53 ms instead of 253 ms.** Both servers hold event notifications to send a burst as one
message, except button events, which go at once: HAP-NodeJS for `EVENT_COALESCING_DELAY` (250 ms,
`eventedhttp.ts`), Homeswift for `HAPServer.Options.eventCoalescingDelay` (50 ms). A burst (a plugin updating many
lights, a scene) arrives within a few milliseconds, so 50 ms still sends it as one message, without adding a
quarter of a second to every state change HomeKit learns, and to every automation that reacts to one.

**Caveats.** The HAP-NodeJS script is the library alone, run the way Homebridge runs it (default advertiser,
default Node flags) on Node 26, ahead of the versions its `engines` lists. The controller is Swift on NIO;
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

### Scenes

`bridge-bench.py` seeds `scenes.json` with `--scenes` scenes (40 by default, four lamps' On, Brightness, Hue and
Saturation each, one in two on a schedule) and times `GET /api/scenes`, a run and a stop, `list_scenes` and
`run_scene`. Apple M1, 2026-10-30, 60 accessories, `main` (`2c937ff`) against the unified scenes branch (`1cde340`),
interleaved twice while other sessions kept the load average around 45; the better run of each:

| Scenes, 40 | `main` | branch |
|---|---:|---:|
| `GET /api/scenes`, 4 connections, CPU per request | 56 250 µs | 7 854 µs |
| `GET /api/scenes`, 4 connections | 53 req/s | 501 req/s |
| MCP `list_scenes`, 4 connections, CPU per request | 45 595 µs | 8 914 µs |
| `GET /api/scenes` p50 | 35 ms | 5.4 ms |
| MCP `list_scenes` p50 | 37 ms | 6.3 ms |
| `POST /api/scenes/<id>/run` p50 | 39 ms | 3.9 ms |
| MCP `run_scene` p50 | 4.2 ms | 3.3 ms |

The other routes stayed within the noise of the two runs (`GET /api/accessories` ×8, 1 036 against 1 057 µs CPU per
request; idle RSS 23 MB on both).

Before its own fixes the branch was twice as slow as `main` here (122 ms and 214 ms p50 in a run under the same
load), from the hubs' scenes and pictures it lists. Where it went, from `sample`:

- **Looking accessories up.** `find(id:)` described every plugin instance (each one's accessory ids) and sorted each
  bridge's accessories to find one, and a scene list looks up each action's accessory four times. A bridge finds an
  accessory by its aid now (`HAPServer.accessory(id:)`), its instance by the bridge's claim
  (`PluginHost.platform(owning:on:)`), and a scene list indexes every accessory once (`withLookup`).
- **Characteristic names.** `normalized(_:)` read Unicode properties for every character of every candidate
  characteristic's name; ASCII names go by their bytes, and `name(_:normalizesTo:)` compares without a copy.
- **`JSONValue(encoding:)`** read its `JSONEncoder` output back through `JSONDecoder`'s generic path; it uses
  `JSONValue`'s own parser now (every scene and action goes through it).
- **The run route** built the whole scene list to read one scene's security flag (`savedScene(_:)` now).

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

Commit `dabf977` finds what the redaction expressions need in one pass over a line (it took sixteen searches) and
makes the date formatters of the log routes once. Back to back with the build before it, interleaved twice (load
average about 30), the better run of each:

| p50 | before, 60 | after, 60 | before, 300 | after, 300 |
|---|---:|---:|---:|---:|
| MCP `search_logs` | 6.9 ms | 3.5 ms | 7.0 ms | 3.5 ms |
| MCP `get_recent_logs` | 0.82 ms | 0.52 ms | 0.82 ms | 0.52 ms |
| `GET /api/logs?from=` (an hour) | 6.9 ms | 6.8 ms | 6.8 ms | 6.5 ms |

`/api/logs` and `?accessory=` do not redact and did not move.

Commit `bee55cc` reads an archive row's members through a closure (no array of them per row), parses short
decimals such as a row's time with one exact division instead of `strtod`, and puts a range's lines together in one
pass: `GET /api/logs?from=` (an hour) went from 6.3 to 4.8 ms at 60 and at 300 accessories, back to back. The same
run measured `search_logs` at 7.9 ms against 3.3 before: its new implementation (`HomeswiftCatalog.searchLogs`, with
payloads, filters and context lines) came in between the two builds, and made the shown text and the masked text of
every line in memory. It makes them now for the lines that need them: 3.4 ms at 60 and at 300 accessories, back to
back.

### Where it ends

The heaviest routes left, on the latest build (`87860ed`, quiet machine), and what they cost per item:

| Route, p50 | 60 accessories | 300 accessories | per item |
|---|---:|---:|---|
| `GET /api/accessories` | 0.62 ms (72 KB) | 2.7 ms (365 KB) | 9 µs an accessory |
| MCP `list_accessories` / `resources/read accessories` | 1.2 / 0.93 ms | 5.3 / 4.1 ms | 14–18 µs an accessory |
| `GET /api/logs?from=` (an hour, 5 000 lines, 600 KB) | 4.8 ms | 4.8 ms | 1 µs a line |
| MCP `search_logs` (5 000 lines) | 3.3 ms | 3.4 ms | 0.7 µs a line |
| `GET /api/logs?accessory=` (5 000 lines) | 3.0 ms | 3.0 ms | 0.6 µs a line |

These are where the work itself is: each log line is read, masked for secrets and written once, and each
accessory's characteristics are read and written once. What could still go is a constant factor, not a quadratic
or a repeated step: the MCP accessory tools still build the generic `JSONValue` tree that `/api/accessories` no
longer does, and an hour of log could be kept parsed in memory rather than read back from disk. Neither shows where
it is felt. The answers are larger than they are slow: the hour of log is 600 KB and the 300 accessories 365 KB,
which a phone on Wi-Fi takes 10–50 ms to receive, more than the bridge takes to make them, and the browser takes
longer still to lay them out. A home of 50 accessories gets its accessory list in about half a millisecond.

The MCP accessory tools were then profiled rather than set aside: building the accessories was a fifth of
`list_accessories`, writing the answer the rest, since MCP carries the JSON twice (as pretty text inside a string, and
as structured content) and that text, full of quotes and newlines, was escaped a byte at a time with an array per
escape. Commit `06f2526` copies the runs between escapes whole:
`list_accessories` 5.4 → 4.7 ms and `resources/read accessories` 4.5 → 3.4 ms with 300 accessories, 1.7 → 1.5 and
1.3 → 0.9 ms with 60, back to back. What is left there is that double carriage, which the protocol asks for.

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

