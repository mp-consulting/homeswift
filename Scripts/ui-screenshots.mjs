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
  bridge: { name: "Homeswift", port: 51995 },
  platforms: [
    { platform: "HomeswiftUI", name: "Web UI", port, host: "127.0.0.1", auth: "none", checkForUpdates: false, scheduledBackupDisable: true },
    { platform: "ElgatoKeyLights", name: "Desk Lights", _paused: true },
    { platform: "PhilipsHue", name: "Philips Hue", host: "192.168.1.20", transitionMs: 400, _paused: true },
    // A demonstration key, for the Vault page's secrets still in config.json.
    { platform: "Govee", name: "Govee", apiKey: "demo-govee-api-key", _paused: true },
    { platform: "DysonPureCool", name: "Dyson", _paused: true },
  ],
}, null, 2));
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

// Runs in the page before its own scripts: the machine's name and the folder's paths become demonstration ones.
const replacements = [[storage, "/Users/demo/.homeswift"], [hostname(), "homeswift-mac"], [hostname().replace(/\.local$/, ""), "homeswift-mac"]];
const pageScript = `(() => {
  const pairs = ${literal(replacements)};
  const clean = (text) => pairs.reduce((s, [real, shown]) => s.split(real).join(shown), text);
  const original = window.fetch;
  window.fetch = async (input, init) => {
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
  await shot("scene-location", "/scenes", { ready: "details.location", prepare: 'document.querySelector("details.location").open = true;', element: "details.location" });
  await shot("scene-homekit", "/scenes/new", { ready: ".scene-editor .toggle", element: ".scene-editor .toggle" });
  await shot("scene-artwork", "/scenes/new", { ready: ".artwork-picker", prepare: 'document.querySelector(".artwork-picker").open = true;', tall: 1000 });
  // The bridge as the Home app pairs it: its setup code and QR code.
  await shot("status-bridge", "/status", { ready: ".card.server", element: "main .card.server" });
  await shot("plugins", "/plugins", { ready: ".card", tall: 1000 });
  await shot("plugin-form", "/plugins/desk-lights/expert", { ready: "form, .group-box, .field", tall: 1000 });
  await shot("config", "/settings/config", { ready: ".code-editor", tall: 900 });
  await shot("logs", "/logs?level=trace", { ready: ".log-filter-panel", tall: 900 });
  await shot("logs-phone", "/logs?level=trace", { width: 390, height: 844, mobile: true, ready: ".log-filter-panel" });
  await shot("appearance", "/appearance", { ready: ".wallpapers", tall: 1300 });
  await shot("backups", "/settings/backups", { ready: ".drop-zone", tall: 1000 });
  await shot("vault", "/settings/vault", { ready: ".vault-move", tall: 800 });
} finally {
  socket.close();
  const exited = new Promise((done) => chrome.once("exit", done));
  chrome.kill();
  await stop();
  await Promise.race([exited, sleep(3000)]);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
