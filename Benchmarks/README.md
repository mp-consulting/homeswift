# Benchmarks: Homeswift vs HAP-NodeJS

The same HomeKit controller drives two bridges that expose the same accessories, and measures each server
process: Homeswift's `HAPServer` and HAP-NodeJS, the library inside Homebridge.

| Piece | What it is |
|---|---|
| `Sources/hap-bench` | The controller: pair setup (SRP), pair verify, encrypted sessions, reads, writes, events, concurrent load. It carries its own copy of the pairing primitives so the server under test builds without `-enable-testing`. |
| `Sources/hap-bench-server` | A Homeswift bridge with `ACCESSORIES` lightbulbs (On, Brightness, Hue, Saturation), release build. |
| `hap-nodejs/server.js` | The same bridge on `@homebridge/hap-nodejs` 2.2.2, the version Homebridge 2.4.0 ships. |
| `run.sh` | Builds everything, runs the suite against both servers, prints the comparison. |

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
  connection's task and back, and takes the server's state lock several times; worth a profile.

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
