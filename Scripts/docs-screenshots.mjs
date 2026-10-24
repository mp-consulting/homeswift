// Retakes the web UI screenshots of docs/images/widgets (wall.png, phone.png, paused.png) from a running bridge, with
// headless Chrome over the DevTools protocol: light mode, 2x, the Accessories page as the docs show it.
//
//   node Scripts/docs-screenshots.mjs <bridge UI url> <names.json> [<out dir>]
//
// The bridge is a throwaway copy of one with real accessories (docs/widgets.md, "Screenshots"): a new identity, every
// plugin block paused so nothing reaches a device or a cloud, its accessories restored from the cache. <names.json>
// stays out of the repository: { "names": { "<real name>": "<demonstration name>" }, "values": { "<demonstration name>":
// { "<characteristic type>": value } } }. The page's accessory data is rewritten as it loads: names replaced, the paused
// flag dropped (kept for paused.png), values overridden where a cached one would look broken (a sensor that was off).
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base, mapFile, out = "docs/images/widgets"] = process.argv.slice(2);
if (!base || !mapFile) {
  console.error("usage: node Scripts/docs-screenshots.mjs <bridge UI url> <names.json> [<out dir>]");
  process.exit(2);
}
const { names = {}, values = {} } = JSON.parse(readFileSync(mapFile, "utf8"));

// Runs in the page before its own scripts.
const pageScript = (keepPaused) => `(() => {
  const names = ${JSON.stringify(names)}, values = ${JSON.stringify(values)};
  const keys = Object.keys(names).sort((a, b) => b.length - a.length);
  const rename = (s) => { if (names[s]) return names[s]; for (const k of keys) if (s.includes(k)) s = s.split(k).join(names[k]); return s; };
  const walk = (v) => Array.isArray(v) ? v.map(walk) : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)])) : typeof v === "string" ? rename(v) : v;
  const unpause = (v) => { if (Array.isArray(v)) v.forEach(unpause); else if (v && typeof v === "object") { ${keepPaused ? "" : "delete v.paused;"} Object.values(v).forEach(unpause); } return v; };
  const override = (list) => { for (const a of Array.isArray(list) ? list : []) for (const s of a.services || []) for (const c of s.characteristics || []) {
    if (values[a.name] && c.type in values[a.name]) c.value = values[a.name][c.type];
  } return list; };
  const original = window.fetch;
  window.fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input.url;
    const response = await original(input, init);
    if (!/\\/api\\/(accessories|layout|status)/.test(url) || !response.ok) return response;
    const data = override(unpause(walk(await response.clone().json())));
    return new Response(JSON.stringify(data), { status: response.status, headers: response.headers });
  };
})();`;

const profile = mkdtempSync(join(tmpdir(), "homeswift-shots-"));
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ["--headless=new", "--remote-debugging-port=9333", `--user-data-dir=${profile}`, "--hide-scrollbars", "--no-first-run", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  try { target = (await (await fetch("http://127.0.0.1:9333/json/list")).json()).find((t) => t.type === "page"); } catch {}
  if (!target) await sleep(200);
}
if (!target) { chrome.kill(); throw new Error("headless Chrome did not start"); }
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve) => socket.addEventListener("open", resolve));
let sequence = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
});
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++sequence;
  pending.set(id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
}).then((message) => { if (message.error) throw new Error(`${method}: ${message.error.message}`); return message.result; });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }, { name: "prefers-reduced-motion", value: "reduce" }] });
let script;
async function open(path, { width, height, mobile = false, keepPaused = false }) {
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile });
  if (script) await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: script });
  script = (await send("Page.addScriptToEvaluateOnNewDocument", { source: pageScript(keepPaused) })).identifier;
  await send("Page.navigate", { url: base + path });
  for (let i = 0; i < 60; i++) {
    if (await evaluate("document.querySelectorAll('.wall > .widget').length > 10")) break;
    await sleep(250);
  }
  await sleep(1500);
}
async function shoot(file, clip) {
  const { data } = await send("Page.captureScreenshot", { format: "png", ...(clip ? { clip: { ...clip, scale: 1 } } : {}) });
  writeFileSync(join(out, file), Buffer.from(data, "base64"));
  console.log(`wrote ${join(out, file)}`);
}

try {
  // The page as the README and widgets.md open with it: the header and the wall's first rows.
  await open("/accessories", { width: 1272, height: 1652 });
  await shoot("wall.png");
  // A phone: the header, the tools, the first widgets and the tab bar.
  await open("/accessories", { width: 422, height: 1432, mobile: true });
  await shoot("phone.png");
  // Paused plugins: three rows of the wall from the valve.
  await open("/accessories", { width: 1272, height: 2400, keepPaused: true });
  const box = await evaluate(`(() => {
    const wall = document.querySelector('.wall'), w = wall.getBoundingClientRect();
    const tap = [...wall.children].find((card) => card.querySelector('.widget-valve, [class*="valve"]')) || wall.children[0];
    const t = tap.getBoundingClientRect(), unit = parseFloat(getComputedStyle(wall).getPropertyValue('--unit')) || 160;
    return { x: w.left - 16, y: t.top + scrollY - 16, width: w.width + 32, height: unit * 3 + 24 + 32 };
  })()`);
  await shoot("paused.png", box);
} finally {
  socket.close();
  // Chrome writes its profile until it has exited.
  await new Promise((resolve) => { chrome.once("exit", resolve); chrome.kill(); });
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
