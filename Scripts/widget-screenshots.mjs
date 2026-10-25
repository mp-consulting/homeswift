// Retakes docs/images/widgets using demonstration fixtures and the production widget scripts/styles.
// A throwaway localhost server and headless Chrome: no bridge or physical device is contacted.
// Usage: node Scripts/widget-screenshots.mjs [output directory]
import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve, join } from "node:path";

const root = fileURLToPath(new URL("..", import.meta.url)).replace(/\/$/, "");
const web = join(root, "Sources/HomeswiftUI/Web");
const out = resolve(process.argv[2] || join(root, "docs/images/widgets"));
const profile = mkdtempSync("/tmp/widget-chrome-");
mkdirSync(out, { recursive: true });
const html = `<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/style.css"><script src="/i18n.js"></script>
<style>body{padding:0}main{max-width:1200px;margin:auto;padding:24px 16px}
.accessory-walls{width:100%}.page-head{margin-bottom:20px}h2{font-size:20px;margin:28px 0 12px}.wall{margin-bottom:30px}</style>
<body><div id="app"><main id="view" class="accessory-walls"></main></div>
<script src="/common.js"></script><script src="/remote.js"></script>
<script src="/widgets.js"></script><script src="/preview.js"></script></body></html>`;
const writes = [];
const server = createServer((request, response) => {
  try {
    const path = new URL(request.url, "http://localhost").pathname;
    if (path.startsWith("/api/")) {
      response.setHeader("Content-Type", "application/json");
      if (request.method === "GET") { response.end("{}"); return; }
      let body = "";
      request.on("data", (data) => { body += data; });
      request.on("end", () => { writes.push({ path, body: JSON.parse(body) }); response.end("{}"); });
      return;
    }
    const file = path === "/preview.js" ? join(root, "Scripts/fixtures/widgets.js")
      : path.startsWith("/site/") ? root + path : web + path;
    const types = { html: "text/html; charset=utf-8", js: "text/javascript; charset=utf-8",
      css: "text/css; charset=utf-8", svg: "image/svg+xml", png: "image/png" };
    response.setHeader("Content-Type", types[path.split(".").pop()] || "text/html; charset=utf-8");
    response.end(path === "/" ? html : readFileSync(file));
  } catch { response.writeHead(404); response.end(); }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["--headless=new",
  "--remote-debugging-port=9351", `--user-data-dir=${profile}`, "--hide-scrollbars", "--no-first-run", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
let socket;
try {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    try { target = (await (await fetch("http://127.0.0.1:9351/json/list")).json()).find((tab) => tab.type === "page"); } catch {}
    if (!target) await sleep(200);
  }
  if (!target) throw new Error("Headless Chrome did not start");
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((done) => socket.addEventListener("open", done));
  let sequence = 0;
  const pending = new Map();
  const errors = [];
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) { pending.get(message.id)?.(message); pending.delete(message.id); }
    else if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails);
  });
  const send = (method, params = {}) => new Promise((done) => {
    const id = ++sequence;
    pending.set(id, done);
    socket.send(JSON.stringify({ id, method, params }));
  }).then((message) => {
    if (message.error) throw new Error(message.error.message);
    return message.result;
  });
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const appearance = (theme) => send("Emulation.setEmulatedMedia", { features: [
    { name: "prefers-color-scheme", value: theme }, { name: "prefers-reduced-motion", value: "reduce" },
  ] });
  const viewport = (width, height = 1500) => send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false });
  const navigate = async (path, selector) => {
    await send("Page.navigate", { url: base + path });
    for (let i = 0; i < 50; i++) {
      if (await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`)) { await sleep(200); return; }
      await sleep(100);
    }
    throw new Error(`Page did not render: ${path}`);
  };
  const open = async (mode, width = 1272) => {
    await viewport(width);
    await navigate(`/?mode=${mode}`, ".widget");
  };
  const shot = async (name, selector = "main") => {
    const clip = await evaluate(`(() => {
      const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
      return { x: Math.max(0, r.x + scrollX), y: Math.max(0, r.y + scrollY), width: r.width, height: r.height, scale: 1 };
    })()`);
    const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: selector !== ".menu", clip });
    // Extra visual checks stay temporary unless the caller requested a preview directory.
    const directory = !process.argv[2] && (name.startsWith("site-") || name === "phone-dark" || name === "menu-phone") ? profile : out;
    writeFileSync(join(directory, `${name}.png`), Buffer.from(data, "base64"));
    console.log(`shot ${name}: ${Math.round(clip.width)} × ${Math.round(clip.height)}`);
  };
  await send("Page.enable");
  await send("Runtime.enable");
  await appearance("light");
  await open("phone", 393);
  await shot("phone");
  const geometry = await evaluate(`[...document.querySelectorAll('.widget')].map(node => ({
    size: node.classList.contains('size-medium') ? 'medium' : node.classList.contains('size-small') ? 'small' : 'large',
    width: node.offsetWidth, height: node.offsetHeight,
  }))`);
  const small = geometry.find((one) => one.size === "small"), medium = geometry.find((one) => one.size === "medium");
  if (small.width !== medium.width || Math.abs(medium.height - (2 * small.height + 10)) > 1) throw new Error("Compact/tall alignment failed");
  await open("sizes");
  await shot("sizes");
  const natural = await evaluate("({rows:+document.querySelector('.size-xlarge').style.getPropertyValue('--card-rows'),height:document.querySelector('.size-xlarge').offsetHeight})");
  if (natural.rows >= 5) throw new Error('Sparse XL light still reserves five rows');
  await evaluate("(()=>{const extra=document.createElement('div');extra.id='optional-preview-control';extra.style.height='180px';document.querySelector('.size-xlarge .w-body').append(extra)})()");
  await sleep(150);
  if (await evaluate("document.querySelector('.size-xlarge').offsetHeight") <= natural.height) throw new Error('XL did not grow for optional controls');
  await evaluate("document.getElementById('optional-preview-control').remove()");
  await sleep(150);
  if (await evaluate("document.querySelector('.size-xlarge').offsetHeight") !== natural.height) throw new Error('XL did not shrink after optional controls disappeared');
  if (await evaluate("!!document.querySelector('.widget-measuring')")) throw new Error('Measurement copy was left on the page');
  console.log('PASS: XL fits its contents and grows/shrinks with optional controls');
  if (process.argv[2]) { await open("sizes", 1272); await shot("s-m-l-xl", ".wall"); }
  await open("wall");
  await shot("wall");

  // Check actual handlers against the fixture server, including the click emitted when a hold is released.
  await evaluate("document.querySelector('[data-id=pendant] .w-hit').click()");
  await sleep(50);
  if (writes.length !== 1 || writes[0].body.value !== false) throw new Error("Tall light toggle failed");
  await evaluate("document.querySelector('[data-id=gate]').scrollIntoView({block:'center'})");
  const point = await evaluate(`(() => {
    const r = document.querySelector('[data-id=gate] .w-hit').getBoundingClientRect();
    return { x: r.x + 20, y: r.y + 20 };
  })()`);
  const mouse = (type, at = point) => send("Input.dispatchMouseEvent", { type, ...at, button: "left", clickCount: 1 });
  await mouse("mousePressed"); await sleep(100); await mouse("mouseReleased");
  if (writes.length !== 1) throw new Error("Gate opened on a short tap");
  await mouse("mousePressed"); await sleep(1100); await mouse("mouseReleased"); await sleep(100);
  if (writes.length !== 2 || writes[1].body.value !== 0) throw new Error("Completed gate hold must send just one open command");
  await evaluate("document.querySelector('[data-id=sensor] .w-hit').click()");
  if (!await evaluate("!!document.querySelector('dialog[open] .widget-full')")) throw new Error("Full controls missing");
  console.log("PASS: tile alignment, light toggle, short tap, completed hold, full controls");

  for (const mode of ["sizes-more", "paused", "sheet", "edit", "adaptive"]) {
    await open(mode);
    await shot(mode, mode === "sheet" ? "dialog" : mode === "adaptive" ? ".widget" : "main");
  }
  await open("wall");
  await evaluate("document.querySelector('[data-id=pendant] .menu-button').click()");
  const badges = await evaluate("[...document.querySelectorAll('.menu-choice-badge')].map(node => ({label:node.textContent,checked:node.getAttribute('aria-checked'),width:node.offsetWidth,height:node.offsetHeight}))");
  if (badges.length !== 4 || badges.map(one => one.label).join(',') !== 'S,M,L,XL' || badges[1].checked !== 'true' || badges.some(one => one.width !== one.height)) throw new Error('Size badge menu failed');
  await evaluate("document.querySelector('.menu-choice-badge').focus()");
  await send("Input.dispatchKeyEvent", {type:"keyDown", key:"ArrowRight", code:"ArrowRight"});
  if (await evaluate("document.activeElement.textContent") !== 'M') throw new Error('Size badge keyboard navigation failed');
  await evaluate("document.querySelector('.menu-choice-badge[aria-label=\"Extra large\"]').click()");
  if (!await evaluate("!!document.querySelector('[data-id=pendant].size-xlarge')")) throw new Error('XL menu selection failed');
  console.log('PASS: four square size badges, selected state, keyboard navigation and XL selection');
  await sleep(250);
  await evaluate("document.querySelector('[data-id=pendant] .menu-button').click()");
  await evaluate("document.querySelector('.menu:not(.closing)').focus()");
  await shot("menu", ".menu");
  if (process.argv[2]) {
    await open("phone", 393);
    await evaluate("document.querySelector('[data-id=pendant] .menu-button').click()");
    await evaluate("document.querySelector('.menu:not(.closing)').focus()");
    const phoneBadges = await evaluate("[...document.querySelectorAll('.menu-choice-badge')].map(node => [node.offsetWidth,node.offsetHeight])");
    if (phoneBadges.length !== 4 || phoneBadges.some(([width,height]) => width !== height)) throw new Error('Phone size badges must be square');
    await shot("menu-phone", ".menu");
  }
  await open("slide");
  const cover = await evaluate(`(() => {
    const r = document.querySelector('[data-id=cover] .w-hit').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height * .7 };
  })()`);
  await mouse("mousePressed", cover);
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: cover.x, y: cover.y - 45, button: "left", buttons: 1 });
  await shot("slide", ".widget");
  await mouse("mouseReleased", { x: cover.x, y: cover.y - 45 });

  for (const width of [320, 768, 1280]) {
    await open("phone", width);
    if (await evaluate("document.documentElement.scrollWidth > innerWidth")) throw new Error(`Widgets overflow at ${width}px`);
  }
  await appearance("dark");
  await open("phone", 393);
  await shot("phone-dark");
  await appearance("light");
  for (const width of [393, 1280]) {
    await viewport(width);
    await navigate("/site/index.html", ".house .w");
    if (await evaluate("document.documentElement.scrollWidth > innerWidth")) throw new Error(`Website overflows at ${width}px`);
    await shot(`site-${width}`, ".house");
  }
  await navigate("/site/bridge.html", ".stage .wall .w");
  await shot("site-bridge", ".stage .wall");
  if (errors.length) throw new Error(JSON.stringify(errors));
} finally {
  socket?.close(); chrome.kill(); server.close();
  await new Promise((done) => chrome.exitCode !== null || chrome.signalCode !== null ? done() : chrome.once("exit", done));
  rmSync(profile, { recursive: true, force: true });
}
