#!/usr/bin/env python3
"""Times every endpoint of a whole Homeswift bridge: the web UI's pages and JSON API, its event stream, and the
MCP server's methods and tools, on bridge-bench-server (a synthetic home, no devices).

    BIN=$(swift build -c release --scratch-path ~/Library/Caches/homeswift-bench --show-bin-path)
    ./bridge-bench.py --server "$BIN/bridge-bench-server" --name baseline
    ./bridge-bench.py compare results/baseline.json results/after.json

Standard library only. Each endpoint gets warm-up requests, then timed ones on one keep-alive connection; the
throughput runs open several connections and divide the server's CPU time by the requests served.
"""
import argparse
import atexit
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

TOKEN = "bench-token-0123456789abcdef0123456789abcdef"


def percentile(samples, p):
    ordered = sorted(samples)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, max(0, round(p / 100 * (len(ordered) - 1))))
    return ordered[index]


def process_stats(pid):
    """RSS in MB, CPU seconds, threads."""
    out = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    rss = int(out[0]) / 1024
    minutes, seconds = out[1].split(":")
    cpu = int(minutes) * 60 + float(seconds)
    threads = len(subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()) - 1
    return rss, cpu, threads


def footprint(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "Footprint:" in line:
            value, unit = line.split("Footprint:")[1].split()[:2]
            return float(value) / (1024 if unit.startswith("K") else 1)
    return None


class Client:
    def __init__(self, port):
        self.port = port
        self.connection = http.client.HTTPConnection("127.0.0.1", port, timeout=120)

    def request(self, method, path, body=None, headers=None):
        headers = dict(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        start = time.perf_counter()
        self.connection.request(method, path, body=data, headers=headers)
        response = self.connection.getresponse()
        payload = response.read()
        elapsed = time.perf_counter() - start
        return response.status, response, payload, elapsed


class MCP:
    def __init__(self, port):
        self.client = Client(port)
        self.session = None
        self.next_id = 1
        status, response, payload, _ = self.call("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bridge-bench", "version": "1"}})
        assert status == 200, payload
        self.session = response.getheader("Mcp-Session-Id")
        self.client.request("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, self.headers())

    def headers(self):
        headers = {"Authorization": "Bearer " + TOKEN, "Accept": "application/json"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        return headers

    def call(self, method, params=None):
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.next_id += 1
        return self.client.request("POST", "/mcp", message, self.headers())


# Seconds one endpoint may take: a slow one (the log tools before they were fast, on 300 accessories) gets
# fewer samples, at least five, instead of holding the run for an hour.
BUDGET = 15.0


def time_endpoint(results, name, send, requests, warmup):
    sizes = []
    samples = []
    status = None
    start = time.perf_counter()
    index = 0
    while index < warmup and time.perf_counter() - start < BUDGET / 3:
        status, _, _, _ = send(index)
        index += 1
    start = time.perf_counter()
    while len(samples) < requests and (len(samples) < 5 or time.perf_counter() - start < BUDGET):
        status, _, payload, elapsed = send(index)
        index += 1
        samples.append(elapsed * 1000)
        sizes.append(len(payload))
    results[name] = {
        "p50": percentile(samples, 50), "p90": percentile(samples, 90), "p99": percentile(samples, 99),
        "max": max(samples), "bytes": int(sum(sizes) / len(sizes)), "status": status, "samples": len(samples)}
    print(f"  {name:<44} p50 {results[name]['p50']:8.3f} ms  p99 {results[name]['p99']:8.3f} ms  {results[name]['bytes']:>8} B  {status}", flush=True)


def throughput(pid, make_send, connections, seconds):
    counts = [0] * connections
    stop = time.perf_counter() + seconds
    latencies = [[] for _ in range(connections)]

    def worker(slot):
        send = make_send()
        while time.perf_counter() < stop:
            _, _, _, elapsed = send(0)
            counts[slot] += 1
            latencies[slot].append(elapsed * 1000)

    _, cpu_before, _ = process_stats(pid)
    threads = [threading.Thread(target=worker, args=(slot,)) for slot in range(connections)]
    start = time.perf_counter()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.perf_counter() - start
    _, cpu_after, _ = process_stats(pid)
    total = sum(counts)
    merged = [value for slot in latencies for value in slot]
    return {"rps": total / wall, "cpu_us": (cpu_after - cpu_before) / max(1, total) * 1e6, "p99": percentile(merged, 99), "requests": total}


def event_latency(port, ui, accessory_id, rounds):
    """The time from a characteristic write through the API to its event on /api/events."""
    sock = socket.create_connection(("127.0.0.1", port))
    sock.sendall(f"GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: text/event-stream\r\n\r\n".encode())
    reader = sock.makefile("rb")
    seen = {}
    ready = threading.Event()

    def read():
        event = None
        for raw in reader:
            line = raw.decode(errors="replace").rstrip("\r\n")
            if line.startswith("event: "):
                event = line[7:]
                if event == "hello":
                    ready.set()
            elif line.startswith("data: ") and event == "accessory":
                payload = json.loads(line[6:])
                if payload.get("id") == accessory_id and payload.get("characteristic") == "Brightness":
                    seen[payload["value"]] = time.perf_counter()

    thread = threading.Thread(target=read, daemon=True)
    thread.start()
    ready.wait(5)
    samples = []
    path = "/api/accessories/" + urllib.parse.quote(accessory_id, safe="")
    for index in range(rounds):
        value = 10 + index % 80
        start = time.perf_counter()
        ui.request("PUT", path, {"characteristic": "Brightness", "value": value}, {"Origin": f"http://127.0.0.1:{port}"})
        deadline = time.perf_counter() + 2
        while value not in seen and time.perf_counter() < deadline:
            time.sleep(0.0001)
        if value in seen:
            samples.append((seen.pop(value) - start) * 1000)
        time.sleep(0.01)
    sock.close()
    return {"p50": percentile(samples, 50), "p99": percentile(samples, 99), "received": len(samples)}


def seed_scenes(storage, accessories, count):
    """scenes.json with `count` scenes, each setting four lamps' On, Brightness, Hue and Saturation, one in two on a
    schedule: what the Scenes page and list_scenes read."""
    lamps = [f"BenchHome:{index:04d}" for index in range(0, accessories, 8)]
    scenes = []
    for number in range(count):
        chosen = [lamps[(number + offset) % len(lamps)] for offset in range(min(4, len(lamps)))]
        actions = [{"id": lamp, "characteristic": name, "value": value}
                   for lamp in chosen for name, value in (("On", True), ("Brightness", 20 + number % 80), ("Hue", number * 7 % 360), ("Saturation", 60))]
        triggers = [{"type": "schedule", "time": "07:30", "days": [1, 2, 3, 4, 5], "enabled": True}] if number % 2 else []
        scenes.append({"id": f"scene{number:04d}", "name": f"Scene {number}", "actions": actions, "triggers": triggers, "conditions": []})
    with open(os.path.join(storage, "scenes.json"), "w") as file:
        json.dump({"version": 1, "scenes": scenes}, file)


def run(arguments):
    storage = tempfile.mkdtemp(prefix="bridge-bench-")
    seed_scenes(storage, arguments.accessories, arguments.scenes)
    env = dict(os.environ, STORAGE=storage, ACCESSORIES=str(arguments.accessories), UI_PORT=str(arguments.ui_port),
               MCP_PORT=str(arguments.mcp_port), MCP_TOKEN=TOKEN, TICK_MS=str(arguments.tick_ms), LOG_LINES=str(arguments.log_lines))
    started = time.perf_counter()
    errors = open(os.path.join(storage, "stderr.txt"), "w+")
    process = subprocess.Popen([arguments.server], env=env, stdout=subprocess.PIPE, stderr=errors, text=True)
    # Never left running, holding the ports, when the script stops early.
    atexit.register(process.kill)
    ready = None
    for line in process.stdout:
        if line.startswith("READY"):
            ready = dict(part.split("=") for part in line.split()[1:])
            break
    startup = (time.perf_counter() - started) * 1000
    if ready is None:
        errors.seek(0)
        sys.exit("bridge-bench-server did not start: " + errors.read().strip())
    pid = process.pid
    ui_port, mcp_port = int(ready["ui"]), int(ready["mcp"])
    results = {"name": arguments.name, "accessories": arguments.accessories, "startup_ms": startup, "endpoints": {}, "throughput": {}}
    print(f"started in {startup:.0f} ms (pid {pid}, {arguments.accessories} accessories)", flush=True)
    time.sleep(2)
    rss, cpu, threads = process_stats(pid)
    results["idle"] = {"rss_mb": rss, "footprint_mb": footprint(pid), "cpu_s": cpu, "threads": threads}

    endpoints = results["endpoints"]
    requests, warmup = arguments.requests, max(5, arguments.requests // 10)
    ui = Client(ui_port)
    origin = {"Origin": f"http://127.0.0.1:{ui_port}"}
    lamp = "BenchHome:0000"
    lamp_path = "/api/accessories/" + urllib.parse.quote(lamp, safe="")
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))

    print("web UI")
    gets = [
        ("GET /", "/"), ("GET /accessories (a view)", "/accessories"), ("GET /app.js", "/app.js"), ("GET /common.js", "/common.js"),
        ("GET /style.css", "/style.css"), ("GET /chat.js", "/chat.js"),
        ("GET /api/auth/state", "/api/auth/state"), ("GET /api/status", "/api/status"), ("GET /api/accessories", "/api/accessories"),
        ("GET /api/plugins", "/api/plugins"), ("GET /api/config", "/api/config"),
        ("GET /api/config/block/…", "/api/config/block/BenchHome/" + urllib.parse.quote("Bench Home")),
        ("GET /api/plugins/HomeswiftUI/schema", "/api/plugins/HomeswiftUI/schema"),
        ("GET /api/logs", "/api/logs"), ("GET /api/logs?accessory=", "/api/logs?accessory=" + urllib.parse.quote(lamp, safe="")),
        ("GET /api/logs?bridge=all", "/api/logs?bridge=all"), ("GET /api/logs?from=1h", "/api/logs?from=" + since),
        ("GET /api/qr/0.svg", "/api/qr/0.svg"), ("GET /api/assistant", "/api/assistant"),
        ("GET /api/metrics", "/api/metrics"), ("GET /api/metrics?accessory=", "/api/metrics?accessory=" + urllib.parse.quote(lamp, safe="")),
        ("GET /api/layout", "/api/layout"), ("GET /api/plugins/…/devices (a plugin's API)", "/api/plugins/BenchHome/" + urllib.parse.quote("Bench Home") + "/devices"),
    ]
    for name, path in gets:
        time_endpoint(endpoints, name, lambda _, path=path: ui.request("GET", path), requests, warmup)
    time_endpoint(endpoints, "PUT /api/accessories/<id> (write)",
                  lambda index: ui.request("PUT", lamp_path, {"characteristic": "On", "value": index % 2 == 0}, origin), requests, warmup)
    time_endpoint(endpoints, "POST /api/auth/password-strength",
                  lambda _: ui.request("POST", "/api/auth/password-strength", {"password": "correct horse battery staple"}, origin), requests, warmup)

    print("scenes")
    for name, path in [("GET /api/scenes", "/api/scenes"), ("GET /api/scenes/templates", "/api/scenes/templates")]:
        time_endpoint(endpoints, name, lambda _, path=path: ui.request("GET", path), requests, warmup)
    scene_count = max(1, arguments.scenes)
    time_endpoint(endpoints, "POST /api/scenes/<id>/run",
                  lambda index: ui.request("POST", f"/api/scenes/scene{index % scene_count:04d}/run", {}, origin), requests, warmup)
    time_endpoint(endpoints, "POST /api/scenes/<id>/stop",
                  lambda index: ui.request("POST", f"/api/scenes/scene{index % scene_count:04d}/stop", {}, origin), requests, warmup)

    print("MCP")
    mcp = MCP(mcp_port)
    calls = [
        ("ping", "ping", None), ("tools/list", "tools/list", {}), ("resources/list", "resources/list", {}), ("prompts/list", "prompts/list", {}),
        ("resources/read accessories", "resources/read", {"uri": "homeswift://accessories"}),
        ("resources/read status", "resources/read", {"uri": "homeswift://status"}),
        ("tools/call get_server_status", "tools/call", {"name": "get_server_status", "arguments": {}}),
        ("tools/call list_accessories", "tools/call", {"name": "list_accessories", "arguments": {}}),
        ("tools/call get_accessory", "tools/call", {"name": "get_accessory", "arguments": {"id": lamp}}),
        ("tools/call list_plugins", "tools/call", {"name": "list_plugins", "arguments": {}}),
        ("tools/call get_config", "tools/call", {"name": "get_config", "arguments": {}}),
        ("tools/call get_recent_logs", "tools/call", {"name": "get_recent_logs", "arguments": {}}),
        ("tools/call search_logs", "tools/call", {"name": "search_logs", "arguments": {"pattern": "Lamp 7"}}),
        ("tools/call get_system_info", "tools/call", {"name": "get_system_info", "arguments": {}}),
        ("tools/call set_accessory", "tools/call", {"name": "set_accessory", "arguments": {"id": lamp, "characteristic": "On", "value": True}}),
        ("tools/call list_scenes", "tools/call", {"name": "list_scenes", "arguments": {}}),
        ("tools/call run_scene", "tools/call", {"name": "run_scene", "arguments": {"scene": "scene0000"}}),
    ]
    for name, method, params in calls:
        time_endpoint(endpoints, "MCP " + name, lambda _, method=method, params=params: mcp.call(method, params), requests, warmup)
    def initialize(_):
        start = time.perf_counter()
        session = MCP(mcp_port)
        return 200, None, session.session.encode(), time.perf_counter() - start
    time_endpoint(endpoints, "MCP initialize (new session)", initialize, max(20, requests // 5), 5)

    print("events")
    results["events"] = event_latency(ui_port, ui, lamp, arguments.events)
    print(f"  write → /api/events  p50 {results['events']['p50']:.3f} ms  p99 {results['events']['p99']:.3f} ms  ({results['events']['received']} received)")

    print("throughput")
    def ui_get(path):
        def make():
            client = Client(ui_port)
            return lambda _: client.request("GET", path)
        return make

    def mcp_tool(name):
        def make():
            session = MCP(mcp_port)
            return lambda _: session.call("tools/call", {"name": name, "arguments": {}})
        return make

    for label, make, connections in [
        ("GET /api/status", ui_get("/api/status"), 1), ("GET /api/status", ui_get("/api/status"), 8),
        ("GET /api/accessories", ui_get("/api/accessories"), 1), ("GET /api/accessories", ui_get("/api/accessories"), 8),
        ("GET /app.js", ui_get("/app.js"), 8), ("GET /api/logs", ui_get("/api/logs"), 4),
        ("MCP list_accessories", mcp_tool("list_accessories"), 4),
        ("GET /api/scenes", ui_get("/api/scenes"), 4), ("MCP list_scenes", mcp_tool("list_scenes"), 4),
    ]:
        key = f"{label} ×{connections}"
        results["throughput"][key] = throughput(pid, make, connections, arguments.duration)
        row = results["throughput"][key]
        print(f"  {key:<34} {row['rps']:9.0f} req/s  {row['cpu_us']:8.0f} µs CPU/req  p99 {row['p99']:.2f} ms", flush=True)

    rss, cpu, threads = process_stats(pid)
    results["after"] = {"rss_mb": rss, "footprint_mb": footprint(pid), "cpu_s": cpu, "threads": threads}
    # Idle cost: CPU over a quiet stretch, the ticker running.
    _, before, _ = process_stats(pid)
    time.sleep(arguments.idle_seconds)
    _, after, _ = process_stats(pid)
    results["idle"]["cpu_percent"] = (after - before) / arguments.idle_seconds * 100
    print(f"idle {results['idle']}\nafter {results['after']}")
    process.terminate()
    process.wait(10)
    os.makedirs(arguments.output, exist_ok=True)
    with open(os.path.join(arguments.output, arguments.name + ".json"), "w") as file:
        json.dump(results, file, indent=1)


def compare(paths):
    runs = [json.load(open(path)) for path in paths]
    names = [run["name"] for run in runs]
    print("| Metric | " + " | ".join(names) + (" | change |" if len(runs) == 2 else " |"))
    print("|---|" + "---:|" * (len(runs) + (1 if len(runs) == 2 else 0)))

    def row(label, values, unit, lower_is_better=True):
        cells = [f"{value:,.3f} {unit}" if value < 10 else f"{value:,.0f} {unit}" for value in values]
        change = ""
        if len(values) == 2 and values[0] and values[1]:
            ratio = values[0] / values[1] if lower_is_better else values[1] / values[0]
            change = f" | {ratio:.2f}×"
        print(f"| {label} | " + " | ".join(cells) + change + " |")

    row("Startup to ready", [run["startup_ms"] for run in runs], "ms")
    row("Idle RSS", [run["idle"]["rss_mb"] for run in runs], "MB")
    row("Idle footprint", [run["idle"]["footprint_mb"] or 0 for run in runs], "MB")
    row("Idle CPU", [run["idle"]["cpu_percent"] for run in runs], "%")
    row("RSS after the run", [run["after"]["rss_mb"] for run in runs], "MB")
    for name in runs[0]["endpoints"]:
        if all(name in run["endpoints"] for run in runs):
            row(name + " p50", [run["endpoints"][name]["p50"] for run in runs], "ms")
    row("write → event p50", [run["events"]["p50"] for run in runs], "ms")
    for name in runs[0]["throughput"]:
        if all(name in run["throughput"] for run in runs):
            row(name, [run["throughput"][name]["rps"] for run in runs], "req/s", lower_is_better=False)
            row(name + " CPU/req", [run["throughput"][name]["cpu_us"] for run in runs], "µs")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "compare":
        return compare(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", required=True, help="the bridge-bench-server binary")
    parser.add_argument("--name", default="run")
    parser.add_argument("--accessories", type=int, default=60)
    parser.add_argument("--requests", type=int, default=200)
    parser.add_argument("--events", type=int, default=100)
    parser.add_argument("--duration", type=float, default=3)
    parser.add_argument("--idle-seconds", type=float, default=10)
    parser.add_argument("--tick-ms", type=int, default=1000)
    parser.add_argument("--log-lines", type=int, default=5000)
    parser.add_argument("--scenes", type=int, default=40, help="scenes in scenes.json, four lamps each")
    parser.add_argument("--ui-port", type=int, default=0, help="0: any free port")
    parser.add_argument("--mcp-port", type=int, default=0, help="0: any free port")
    parser.add_argument("--output", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "results"))
    run(parser.parse_args())


if __name__ == "__main__":
    main()
