// Retakes docs/ui.md's screenshots (docs/images/ui) from a throwaway bridge with headless Chrome: light mode, 2x.
//
//   node Scripts/ui-screenshots.mjs [<homeswift binary>] [<out dir>]
//
// The bridge runs from a temporary folder with a new identity, the web UI on 127.0.0.1 without sign-in, and plugin
// blocks with demonstration names, every one paused, so nothing reaches a device or a cloud. Two generated images are
// its user's own wallpapers. As the page loads, this machine's name and the temporary folder's paths are replaced in
// what the API answers, so no real name reaches an image. The folder goes when the script ends.
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { deflateSync } from "node:zlib";

/// A value as a JavaScript literal for code run in the page: JSON, with the characters that could end a script or a
/// line early (<, >, /, U+2028, U+2029) escaped.
const literal = (value) => JSON.stringify(value).replace(/[<>\/\u2028\u2029]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);

const root = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const binary = process.argv[2] || join(homedir(), "Library/Caches/homeswift-build/debug/homeswift");
const out = resolve(process.argv[3] || join(root, "docs/images/ui"));
const port = Number(process.env.UI_SHOTS_PORT || 18590);
const debugPort = Number(process.env.UI_SHOTS_DEBUG_PORT || 9334);
const base = `http://127.0.0.1:${port}`;
mkdirSync(out, { recursive: true });

// The bridge: paused demonstration blocks, the UI on this machine only.
const storage = mkdtempSync(join(tmpdir(), "homeswift-ui-shots-"));
writeFileSync(join(storage, "config.json"), JSON.stringify({
  // A demonstration Location (Coimbra), for the Location map under Settings.
  bridge: { name: "Homeswift", port: 51995, location: { latitude: 40.2033, longitude: -8.4103, name: "Home" } },
  platforms: [
    { platform: "HomeswiftUI", name: "Web UI", port, host: "127.0.0.1", auth: "none", checkForUpdates: false, scheduledBackupDisable: true },
    { platform: "ElgatoKeyLights", name: "Desk Lights", _paused: true },
    { platform: "PhilipsHue", name: "Philips Hue", host: "192.168.1.20", transitionMs: 400, _paused: true },
    // A demonstration key, for the Vault page's secrets still in config.json.
    { platform: "Govee", name: "Govee", apiKey: "demo-govee-api-key", _paused: true },
    { platform: "DysonPureCool", name: "Dyson", _paused: true },
    // Accessories that exist only on the bridge, for the History and the Logbook: nothing reaches a device.
    { platform: "HomebridgeDummy", name: "Demo", accessories: [
      { id: "thermostat", name: "Living Room", type: "Thermostat" },
      { id: "lamp", name: "Desk Lamp", type: "Lightbulb", isDimmer: true },
      { id: "door", name: "Front Door", type: "LockMechanism" },
      { id: "motion", name: "Hallway Motion", type: "MotionSensor" },
      // A remote and a blind, for the Remotes page.
      { id: "remote", name: "Living Room Remote", type: "StatelessProgrammableSwitch" },
      { id: "blind", name: "Living Room Blind", type: "WindowCovering" },
    ] },
  ],
}, null, 2));
writeHistory(join(storage, "history"));
/// A day of the demonstration accessories' History and Logbook (HistoryStore's files), and a week of hours: the room's
/// temperature, its target by the time of day, the lamp, the door and the motion sensor, with who changed what.
function writeHistory(directory) {
  const now = Date.now(), hour = 3_600_000, day = 24 * hour;
  const series = [
    ["thermostat", "4A", "11", "Living Room", "Current Temperature", "number", "celsius"],
    ["thermostat", "4A", "35", "Living Room", "Target Temperature", "number", "celsius"],
    ["thermostat", "4A", "F", "Living Room", "Current Heating Cooling State", "state", null, [0, 1, 2]],
    ["lamp", "43", "25", "Desk Lamp", "On", "state"],
    ["lamp", "43", "8", "Desk Lamp", "Brightness", "number", "percentage"],
    ["door", "45", "1D", "Front Door", "Lock Current State", "state", null, [0, 1, 2, 3]],
    ["door", "45", "1E", "Front Door", "Lock Target State", "state", null, [0, 1]],
    ["motion", "85", "22", "Hallway Motion", "Motion Detected", "state"],
  ].map(([id, service, type, name, characteristic, kind, unit, validValues], index) => ({ id: index + 1, key: `HomebridgeDummy:${id}|${service}||${type}`,
    accessory: `HomebridgeDummy:${id}`, accessoryName: name, service: "", characteristic, kind, ...(unit ? { unit } : {}), ...(validValues ? { validValues } : {}) }));
  const byName = (name) => series.find((one) => one.characteristic === name);
  const changes = new Map(), logbook = new Map(), hours = new Map();
  const dayOf = (time) => new Date(time).toISOString().slice(0, 10);
  const add = (map, file, line) => { if (!map.has(file)) map.set(file, []); map.get(file).push(line); };
  const change = (name, time, value) => {
    const one = byName(name);
    one.last = value;
    one.lastAt = time / 1000 - 978_307_200;
    add(changes, `changes/${dayOf(time)}.tsv`, `${Math.round(time)}\t${one.id}\t${JSON.stringify(value)}`);
  };
  const log = (name, time, value, kind, sourceName) => {
    const one = byName(name);
    add(logbook, `logbook/${dayOf(time)}.jsonl`, JSON.stringify({ t: Math.round(time), a: one.accessory, n: one.accessoryName, c: name, v: value,
      src: sourceName ? { kind, name: sourceName } : { kind }, ...(kind === "device" ? {} : { w: true }) }));
  };
  // The time `h` hours into the day before now, on the hour of the local clock.
  const start = new Date(now - day);
  start.setMinutes(0, 0, 0);
  const at = (h) => start.getTime() + h * hour;
  const target = (time) => { const h = new Date(time).getHours(); return h >= 7 && h < 23 ? 21 : 19; };
  const temperature = (time) => { const h = new Date(time).getHours() + new Date(time).getMinutes() / 60; return Math.round((19.6 + 1.6 * Math.max(0, Math.sin((h - 6) / 17 * Math.PI)) + 0.15 * Math.sin(time / 1e6)) * 10) / 10; };
  // A reading every ten minutes; a target held between its changes.
  for (let time = at(0); time <= now; time += 600_000) change("Current Temperature", time, temperature(time));
  let lastTarget = null;
  for (let time = at(0); time <= now; time += 600_000) {
    if (target(time) !== lastTarget) {
      lastTarget = target(time);
      change("Target Temperature", time, lastTarget);
      if (time > at(0)) log("Target Temperature", time, lastTarget, "automation", lastTarget === 21 ? "Morning" : "Night");
      change("Current Heating Cooling State", time + 60_000, lastTarget === 21 ? 1 : 0);
      if (time > at(0)) log("Current Heating Cooling State", time + 60_000, lastTarget === 21 ? 1 : 0, "device");
    }
  }
  const dated = (h) => { const next = new Date(start); next.setHours(next.getHours() + h); return next.getTime(); };
  const events = [];
  // The lamp: on in the morning from the Home app, in the evening by an automation, dimmed by a person.
  for (const [h, value, kind, who] of [[0, false, null], [7.2, true, "homeApp", "5C1F0A93"], [8.1, false, "homeApp", "5C1F0A93"], [18.5, true, "automation", "Evening"], [23.3, false, "scene", "Good Night"]]) {
    events.push([dated(0) + h * hour, "On", value, kind, who]);
  }
  events.push([dated(0) + 18.5 * hour + 2_000, "Brightness", 80, "automation", "Evening"], [dated(0) + 21 * hour, "Brightness", 40, "user", "alex"]);
  // The door: opened at the door, locked from the Home app.
  // The Home app writes the target; the lock reports its current state, the Device's.
  for (const [h, value, kind, who] of [[0, 1, null], [8.2, 0, "device"], [8.25, 1, "homeApp", "5C1F0A93"], [17.9, 0, "device"], [18, 1, "homeApp", "A2E77B10"]]) {
    if (kind === "homeApp") events.push([dated(0) + h * hour - 2000, "Lock Target State", value, kind, who]);
    events.push([dated(0) + h * hour, "Lock Current State", value, kind ? "device" : null, null]);
  }
  // Motion in the hallway now and then.
  events.push([dated(0), "Motion Detected", false, null]);
  for (const h of [7.1, 7.6, 8.15, 12.4, 17.95, 18.6, 19.3, 22.8]) events.push([dated(0) + h * hour, "Motion Detected", true, "device"], [dated(0) + h * hour + 120_000, "Motion Detected", false, "device"]);
  for (const [time, name, value, kind, who] of events.filter(([time]) => time <= now).sort((a, b) => a[0] - b[0])) {
    change(name, time, value);
    if (kind) log(name, time, value, kind, who);
  }
  // A week of hours of the numbers: their lowest, average and highest.
  for (let time = Math.floor((now - 8 * day) / hour) * hour; time < Math.floor(now / hour) * hour; time += hour) {
    const samples = [0, 1, 2, 3, 4, 5].map((step) => temperature(time + step * 600_000));
    add(hours, `hours/${byName("Current Temperature").id}/${new Date(time).getUTCFullYear()}.tsv`,
      `${time / 1000}\t${Math.min(...samples)}\t${Math.round(samples.reduce((a, b) => a + b, 0) / samples.length * 100) / 100}\t${Math.max(...samples)}`);
    add(hours, `hours/${byName("Target Temperature").id}/${new Date(time).getUTCFullYear()}.tsv`, `${time / 1000}\t${target(time)}\t${target(time)}\t${target(time)}`);
  }
  for (const [file, lines] of [...changes, ...logbook, ...hours]) {
    mkdirSync(join(directory, file, ".."), { recursive: true });
    writeFileSync(join(directory, file), lines.join("\n") + "\n");
  }
  writeFileSync(join(directory, "series.json"), JSON.stringify({ version: 1, series }));
}
const bridge = spawn(binary, ["-U", storage], { stdio: "ignore" });
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
/// Stops the bridge and, once it has exited (it writes on its way out), removes its folder.
const stop = async () => {
  const exited = new Promise((done) => bridge.once("exit", done));
  bridge.kill();
  await Promise.race([exited, sleep(5000)]);
  try { rmSync(storage, { recursive: true, force: true }); } catch {}
};
let up = false;
for (let i = 0; i < 80 && !up; i++) {
  try { up = (await fetch(`${base}/api/status`)).ok; } catch {}
  if (!up) await sleep(250);
}
if (!up) { await stop(); throw new Error(`the bridge did not start (${binary})`); }

// A soft diagonal gradient as a PNG, for the wallpapers of its own.
function gradient(width, height, from, to) {
  const rows = [];
  for (let y = 0; y < height; y++) {
    const row = Buffer.alloc(1 + width * 3);
    for (let x = 0; x < width; x++) {
      const t = (x / width + y / height) / 2;
      for (let c = 0; c < 3; c++) row[1 + x * 3 + c] = Math.round(from[c] + (to[c] - from[c]) * t);
    }
    rows.push(row);
  }
  const table = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
  const crc = (data) => { let c = -1; for (const b of data) c = table[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body));
    return Buffer.concat([length, body, sum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(rows))), chunk("IEND", Buffer.alloc(0))]);
}
const api = (path, method, body) => fetch(base + path, { method, headers: { "Content-Type": "application/json", Origin: base }, body: JSON.stringify(body) });
for (const [from, to] of [[[255, 170, 110], [196, 82, 140]], [[110, 190, 255], [60, 70, 170]]]) {
  await api("/api/preferences/wallpaper", "PUT", { data: gradient(320, 200, from, to).toString("base64") });
}
await api("/api/preferences", "PUT", { wallpaper: "none" });
// A kept backup, for the Backups page's list.
await api("/api/backups", "POST", {});

// What a plugin's discovery answers in the shots: demonstration lights, never what this network has.
const discovery = {
  platform: "ElgatoKeyLights", name: "Desk Lights", accountAuthorization: "none", accountSetUp: true,
  devices: [
    { deviceID: "3C:6A:9D:00:00:01", accessoryID: "ElgatoKeyLights:3C:6A:9D:00:00:01", name: "Key Light Left", model: "Elgato Key Light", address: "192.168.1.41", authorization: "none", status: "setUp", kind: "light", category: "lightbulb" },
    { deviceID: "3C:6A:9D:00:00:02", accessoryID: "ElgatoKeyLights:3C:6A:9D:00:00:02", name: "Key Light Right", model: "Elgato Key Light", address: "192.168.1.42", authorization: "none", status: "setUp", kind: "light", category: "lightbulb" },
    { deviceID: "3C:6A:9D:00:00:03", accessoryID: "ElgatoKeyLights:3C:6A:9D:00:00:03", name: "Ring Light", model: "Elgato Ring Light", address: "192.168.1.43", authorization: "none", status: "excluded", kind: "light" },
  ],
};
// Runs in the page before its own scripts: the machine's name and the folder's paths become demonstration ones.
const replacements = [[storage, "/Users/demo/.homeswift"], [hostname(), "homeswift-mac"], [hostname().replace(/\.local$/, ""), "homeswift-mac"]];
const pageScript = `(() => {
  const pairs = ${literal(replacements)};
  const clean = (text) => pairs.reduce((s, [real, shown]) => s.split(real).join(shown), text);
  const discovery = ${literal(discovery)};
  const original = window.fetch;
  window.fetch = async (input, init) => {
    if (String(input).includes("/api/setup/discover")) return new Response(JSON.stringify(discovery), { status: 200, headers: { "Content-Type": "application/json" } });
    const response = await original(input, init);
    const type = response.headers.get("content-type") || "";
    if (!type.includes("json") || !response.ok) return response;
    return new Response(clean(await response.clone().text()), { status: response.status, headers: response.headers });
  };
  const Source = window.EventSource;
  window.EventSource = class extends Source {
    addEventListener(name, listener, options) {
      super.addEventListener(name, (event) => listener.call(this, new MessageEvent(event.type, { data: clean(String(event.data)), lastEventId: event.lastEventId })), options);
    }
  };
})();`;

// Headless Chrome over the DevTools protocol.
const profile = mkdtempSync(join(tmpdir(), "homeswift-ui-chrome-"));
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ["--headless=new", `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`, "--hide-scrollbars", "--no-first-run", "about:blank"], { stdio: "ignore" });
let target;
for (let i = 0; i < 50 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).find((t) => t.type === "page"); } catch {}
  if (!target) await sleep(200);
}
if (!target) { chrome.kill(); await stop(); throw new Error("headless Chrome did not start"); }
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((done) => socket.addEventListener("open", done));
let sequence = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
});
const send = (method, params = {}) => new Promise((done) => {
  const id = ++sequence;
  pending.set(id, done);
  socket.send(JSON.stringify({ id, method, params }));
}).then((message) => { if (message.error) throw new Error(`${method}: ${message.error.message}`); return message.result; });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;

await send("Page.enable");
await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }, { name: "prefers-reduced-motion", value: "reduce" }] });
await send("Page.addScriptToEvaluateOnNewDocument", { source: pageScript });

/// Opens `path` at the size given, waits for `ready` (a selector), runs `prepare`, and saves the page down to `tall`
/// at most (the viewport's height when left out), or only `element` (a selector, its section, with a margin).
async function shot(name, path, { width = 1280, height = 900, mobile = false, ready = "main h1", prepare = "", tall, element } = {}) {
  if (process.env.UI_SHOTS_ONLY && !process.env.UI_SHOTS_ONLY.split(",").includes(name)) return;
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile });
  await send("Page.navigate", { url: base + path });
  for (let i = 0; i < 60; i++) {
    if (await evaluate(`!!document.querySelector(${literal(ready)})`)) break;
    await sleep(250);
  }
  await sleep(700);
  if (prepare) { await evaluate(`(async () => { ${prepare} })()`); await sleep(400); }
  let clip;
  if (element) {
    const box = await evaluate(`(() => { const r = document.querySelector(${literal(element)}).getBoundingClientRect();
      return { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height }; })()`);
    const margin = 12;
    clip = { x: Math.max(0, box.x - margin), y: Math.max(0, box.y - margin), width: box.width + margin * 2, height: box.height + margin * 2, scale: 1 };
  } else {
    const full = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
    clip = { x: 0, y: 0, width, height: Math.min(full, tall ?? height), scale: 1 };
  }
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, clip });
  writeFileSync(join(out, `${name}.png`), Buffer.from(data, "base64"));
  console.log(`${name}.png ${Math.round(clip.width)}×${Math.round(clip.height)}`);
}

try {
  await shot("location", "/settings", { ready: "details.location", prepare: 'document.querySelector("details.location").open = true;', element: "details.location" });
  await shot("scene-homekit", "/scenes/new", { ready: ".scene-editor .toggle", element: ".scene-editor .toggle" });
  await shot("scene-artwork", "/scenes/new", { ready: ".artwork-picker", prepare: 'document.querySelector(".artwork-picker").open = true;', tall: 1000 });
  // The bridge as the Home app pairs it: its setup code and QR code.
  await shot("status-bridge", "/status", { ready: ".card.server", element: "main .card.server" });
  await shot("plugins", "/plugins", { ready: ".plugins-row", tall: 1000 });
  await shot("plugins-inspector", "/plugins", { ready: ".plugins-row", prepare: 'document.querySelector(".plugins-name").click();' });
  await shot("plugins-phone", "/plugins", { width: 375, height: 812, mobile: true, ready: ".plugins-row" });
  await shot("plugins-drawer", "/plugins", { width: 375, height: 812, mobile: true, ready: ".plugins-row", prepare: 'document.querySelector(".plugins-name").click();' });
  await shot("plugins-accessories", "/plugins", { ready: ".plugins-row", prepare: 'document.querySelector("[data-plugin=demo] .plugins-name").click(); document.querySelector("#plugins-tab-1").click();' });
  await shot("plugins-events", "/plugins", { ready: ".plugins-row", prepare: 'document.querySelector("[data-plugin=demo] .plugins-name").click(); document.querySelector("#plugins-tab-3").click();' });
  await shot("plugins-catalog-sort", "/plugins", { ready: ".plugins-heading", prepare: 'document.querySelector(".plugins-heading > button").click(); document.querySelector("dialog select").dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0 }));' });
  await shot("plugins-actions", "/plugins", { ready: ".plugins-row", prepare: 'document.querySelector(".plugins-name").click(); document.querySelector("#plugins-tab-2").click();' });
  await shot("setup-accounts", "/setup", { ready: ".setup-account", tall: 1100 });
  await shot("automations-empty", "/automations", { ready: ".card.empty" });
  await shot("audit-filters", "/settings/audit?since=7d", { width: 839, height: 867, ready: ".audit-filter-footer" });
  await shot("plugin-settings", "/plugins/desk-lights/settings", { ready: ".settings-device", tall: 1400 });
  await shot("accessory-settings", "/plugins/desk-lights/settings", { ready: ".settings-device button.settings-open",
    prepare: 'document.querySelector(".settings-device button.settings-open").click(); for (let i = 0; i < 40 && !document.querySelector(".accessory-settings-sheet .settings-danger"); i++) await new Promise((r) => setTimeout(r, 100));' });
  await shot("config", "/settings/config", { ready: ".code-editor", tall: 900 });
  await shot("logs", "/logs?level=trace", { ready: ".log-filter-panel", tall: 900 });
  await shot("logs-medium", "/logs?level=trace", { width: 1145, height: 867, ready: ".log-filter-panel" });
  await shot("logs-phone", "/logs?level=trace", { width: 390, height: 844, mobile: true, ready: ".log-filter-panel" });
  await shot("appearance", "/appearance", { ready: ".wallpapers", tall: 2200 });
  await shot("backups-phone", "/settings/backups", { width: 375, height: 812, mobile: true, ready: ".drop-zone" });
  await shot("audit-phone", "/settings/audit?since=7d", { width: 375, height: 812, mobile: true, ready: ".audit-filter-footer" });
  await shot("backups", "/settings/backups", { ready: ".drop-zone", tall: 1000 });
  await shot("vault", "/settings/vault", { ready: ".vault-move", tall: 800 });
  // An accessory's History tab, and the Logbook (the demonstration's day, from writeHistory).
  await shot("history", "/accessories", { ready: ".widget", height: 1100, prepare: `
    const list = await fetch("/api/accessories").then((r) => r.json());
    HomeswiftAdmin.history(list.find((one) => one.name === "Living Room"));
    for (let i = 0; i < 40 && !document.querySelector(".history-full .chart-card"); i++) await new Promise((r) => setTimeout(r, 100));
    await new Promise((r) => setTimeout(r, 600));` });
  // The remote's Controls: its press toggles the lamp and the blind, held it dims the lamp.
  const remotes = await (await fetch(`${base}/api/remotes`)).json();
  const remote = remotes.remotes?.find((one) => one.id === "HomebridgeDummy:remote");
  if (remote) {
    const part = remote.parts[0].id, targets = ["HomebridgeDummy:lamp", "HomebridgeDummy:blind"];
    await api(`/api/settings/accessories/${encodeURIComponent(remote.id)}?instance=Demo`, "PATCH", {
      controls: [{ part, gesture: "press", action: "toggle", targets }, { part, gesture: "hold", action: "dim", targets: ["HomebridgeDummy:lamp"] }] });
  }
  await shot("remotes", "/remotes", { ready: ".remote-part", tall: 700 });
  await shot("logbook", "/logbook", { ready: ".logbook-entry", tall: 1000 });
  await shot("logbook-phone", "/logbook", { width: 390, height: 844, mobile: true, ready: ".logbook-entry" });
} finally {
  socket.close();
  const exited = new Promise((done) => chrome.once("exit", done));
  chrome.kill();
  await stop();
  await Promise.race([exited, sleep(3000)]);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
