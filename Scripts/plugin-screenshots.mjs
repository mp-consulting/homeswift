// Retakes the Philips Hue and IKEA DIRIGERA pages' screenshots (docs/images/plugins) with headless Chrome: light mode,
// 2x. A throwaway bridge talks to a fake Hue Bridge and a fake DIRIGERA hub on this machine (HTTPS with a certificate
// made for the run), which hold demonstration lights, sensors, remotes and scenes; no device is reached.
//
//   node Scripts/plugin-screenshots.mjs [<homeswift binary>] [<out dir>]
//
// The DIRIGERA hub answers on 8443, the port the plugin uses, so nothing else may listen there. As the page loads, the
// fakes' addresses become 192.168.1.20 and 192.168.1.30, and this machine's name and the folder's paths demonstration
// ones. Everything the run made goes when it ends.
import { execFileSync, spawn } from "node:child_process";
import { createServer } from "node:https";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const binary = process.argv[2] || join(homedir(), "Library/Caches/homeswift-build/debug/homeswift");
const out = resolve(process.argv[3] || join(root, "docs/images/plugins"));
const uiPort = 18591, huePort = 18592, dirigeraPort = 8443;
const base = `http://127.0.0.1:${uiPort}`;
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
mkdirSync(out, { recursive: true });
const scratch = mkdtempSync(join(tmpdir(), "homeswift-plugin-shots-"));

// A certificate for the fakes, RSA (LibreSSL's TLS refuses the plugin a P-256 one), good for a day.
execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-days", "1",
  "-keyout", join(scratch, "key.pem"), "-out", join(scratch, "cert.pem")], { stdio: "ignore" });
const tls = { key: readFileSync(join(scratch, "key.pem")), cert: readFileSync(join(scratch, "cert.pem")) };

// MARK: The fake Hue Bridge

const owner = (rid) => ({ rid, rtype: "device" });
const device = (id, name, model, product, services) => ({ id, type: "device", metadata: { name }, product_data: { model_id: model, manufacturer_name: "Signify Netherlands B.V.", product_name: product, software_version: "1.122.8" }, services });
const gamut = { red: { x: 0.6915, y: 0.3083 }, green: { x: 0.17, y: 0.7 }, blue: { x: 0.1532, y: 0.0475 } };
const colourLight = (id, dev, on, level, xy) => ({ id, type: "light", owner: owner(dev), on: { on }, dimming: { brightness: level, min_dim_level: 0.2 },
  color_temperature: { mirek: null, mirek_valid: false, mirek_schema: { mirek_minimum: 153, mirek_maximum: 500 } }, color: { xy, gamut_type: "C", gamut },
  effects_v2: { action: { effect_values: ["no_effect", "candle", "fire", "sparkle"] }, status: { effect: "no_effect" } }, signaling: { signal_values: ["no_signal", "on_off"] } });
const whiteLight = (id, dev, on, level, mirek) => ({ id, type: "light", owner: owner(dev), on: { on }, dimming: { brightness: level },
  color_temperature: { mirek, mirek_valid: true, mirek_schema: { mirek_minimum: 153, mirek_maximum: 454 } } });
const lights = [
  { name: "Bedside", model: "LCA001", product: "Hue color lamp", light: colourLight("l1", "d1", true, 35, { x: 0.38, y: 0.16 }), room: "bedroom" },
  { name: "Ceiling", model: "LCA001", product: "Hue color lamp", light: colourLight("l2", "d2", true, 90, { x: 0.45, y: 0.41 }), room: "living" },
  { name: "Floor Lamp", model: "LCA001", product: "Hue color lamp", light: colourLight("l3", "d3", true, 54, { x: 0.56, y: 0.4 }), room: "living" },
  { name: "Kitchen Pendant", model: "LTA001", product: "Hue white ambiance", light: whiteLight("l4", "d4", true, 100, 233), room: "kitchen" },
  { name: "Reading Lamp", model: "LTA001", product: "Hue white ambiance", light: whiteLight("l5", "d5", false, 100, 300), room: "living" },
  { name: "TV Lightstrip", model: "LCX004", product: "Hue gradient lightstrip", light: colourLight("l6", "d6", true, 72, { x: 0.2, y: 0.1 }), room: "living" },
];
const sensors = [
  // A motion sensor (motion, temperature, light level, battery), a dimmer switch and a smart button, a contact sensor.
  device("d7", "Hall Sensor", "SML003", "Hue motion sensor", [{ rid: "m7", rtype: "motion" }, { rid: "t7", rtype: "temperature" }, { rid: "ll7", rtype: "light_level" }, { rid: "p7", rtype: "device_power" }]),
  { id: "m7", type: "motion", owner: owner("d7"), enabled: true, motion: { motion: true, motion_report: { motion: true, changed: "2026-10-28T08:00:00.000Z" } } },
  { id: "t7", type: "temperature", owner: owner("d7"), enabled: true, temperature: { temperature: 21.4, temperature_report: { temperature: 21.4, changed: "2026-10-28T08:00:00.000Z" } } },
  { id: "ll7", type: "light_level", owner: owner("d7"), enabled: true, light: { light_level: 21761, light_level_report: { light_level: 21761, changed: "2026-10-28T08:00:00.000Z" } } },
  { id: "p7", type: "device_power", owner: owner("d7"), power_state: { battery_state: "normal", battery_level: 86 } },
  device("d8", "Bedroom Dimmer", "RWL022", "Hue dimmer switch", [1, 2, 3, 4].map((n) => ({ rid: `b8${n}`, rtype: "button" })).concat([{ rid: "p8", rtype: "device_power" }])),
  ...[1, 2, 3, 4].map((n) => ({ id: `b8${n}`, type: "button", owner: owner("d8"), metadata: { control_id: n }, button: { button_report: { updated: "2026-10-28T07:00:00.000Z", event: "short_release" } } })),
  { id: "p8", type: "device_power", owner: owner("d8"), power_state: { battery_state: "low", battery_level: 9 } },
  device("d9", "Front Door", "SOC001", "Hue secure contact sensor", [{ rid: "c9", rtype: "contact" }, { rid: "p9", rtype: "device_power" }]),
  { id: "c9", type: "contact", owner: owner("d9"), enabled: true, contact_report: { state: "contact", changed: "2026-10-28T08:00:00.000Z" } },
  { id: "p9", type: "device_power", owner: owner("d9"), power_state: { battery_state: "normal", battery_level: 100 } },
  device("d10", "Desk Button", "RDM003", "Hue smart button", [{ rid: "b10", rtype: "button" }, { rid: "p10", rtype: "device_power" }]),
  { id: "b10", type: "button", owner: owner("d10"), metadata: { control_id: 1 }, button: {} },
  { id: "p10", type: "device_power", owner: owner("d10"), power_state: { battery_state: "normal", battery_level: 64 } },
];
const room = (id, name, devices, group, on, level) => [
  { id, type: "room", metadata: { name }, children: devices.map((rid) => ({ rid, rtype: "device" })), services: [{ rid: group, rtype: "grouped_light" }] },
  { id: group, type: "grouped_light", on: { on }, dimming: { brightness: level } },
];
const roomDevices = (key) => lights.filter((entry) => entry.room === key).map((entry) => entry.light.owner.rid);
const scene = (id, name, group, colours, active = false) => ({ id, type: "scene", metadata: { name }, group: { rid: group, rtype: "room" },
  palette: { color: colours.map((xy) => ({ color: { xy }, dimming: { brightness: 80 } })), color_temperature: [] }, status: { active: active ? "static" : "inactive" }, auto_dynamic: false, speed: 0.6 });
const palettes = { sunset: [{ x: 0.6, y: 0.37 }, { x: 0.52, y: 0.28 }, { x: 0.45, y: 0.2 }], ocean: [{ x: 0.16, y: 0.2 }, { x: 0.2, y: 0.35 }, { x: 0.15, y: 0.08 }],
  forest: [{ x: 0.3, y: 0.55 }, { x: 0.38, y: 0.5 }, { x: 0.25, y: 0.45 }], tokyo: [{ x: 0.35, y: 0.15 }, { x: 0.18, y: 0.1 }, { x: 0.5, y: 0.25 }],
  read: [{ x: 0.45, y: 0.41 }], relax: [{ x: 0.52, y: 0.41 }], concentrate: [{ x: 0.36, y: 0.36 }] };
const hueResources = [
  { id: "bridge", type: "bridge", bridge_id: "001788fffe000001" },
  ...lights.flatMap(({ name, model, product, light }) => [device(light.owner.rid, name, model, product, [{ rid: light.id, rtype: "light" }]), light]),
  ...sensors,
  ...room("living", "Living Room", roomDevices("living"), "g1", true, 72),
  ...room("bedroom", "Bedroom", [...roomDevices("bedroom"), "d8"], "g2", true, 35),
  ...room("kitchen", "Kitchen", roomDevices("kitchen"), "g3", true, 100),
  ...room("hallway", "Hallway", ["d7", "d9"], "g4", false, 0),
  scene("s1", "Savanna Sunset", "living", palettes.sunset, true), scene("s2", "Tokyo", "living", palettes.tokyo), scene("s3", "Read", "living", palettes.read),
  scene("s4", "Relax", "living", palettes.relax), scene("s5", "Ocean Dawn", "bedroom", palettes.ocean), scene("s6", "Nightlight", "bedroom", palettes.relax),
  scene("s7", "Spring Blossom", "bedroom", palettes.forest), scene("s8", "Concentrate", "kitchen", palettes.concentrate), scene("s9", "Energize", "kitchen", palettes.read),
  { id: "smart1", type: "smart_scene", metadata: { name: "Natural light" }, group: { rid: "living", rtype: "room" }, state: "inactive" },
];
const hue = createServer(tls, (request, response) => {
  const json = (value, status = 200) => { response.writeHead(status, { "Content-Type": "application/json" }); response.end(JSON.stringify(value)); };
  if (request.url === "/api/config") return json({ bridgeid: "001788FFFE000001", name: "Hue Bridge" });
  if (request.headers["hue-application-key"] !== "demo-key") return json({ errors: [{ description: "unauthorized user" }] }, 403);
  if (request.url === "/clip/v2/resource") return json({ errors: [], data: hueResources });
  if (request.url === "/eventstream/clip/v2") { response.writeHead(200, { "Content-Type": "text/event-stream" }); response.write(": hi\n\n"); return; }
  json({ errors: [], data: [] });
}).listen(huePort, "127.0.0.1");

// MARK: The fake DIRIGERA hub

const ikea = (id, type, deviceType, name, model, attributes, extra = {}) => ({ id, type, deviceType, isReachable: true,
  attributes: { customName: name, model, manufacturer: "IKEA of Sweden", firmwareVersion: "1.0.29", serialNumber: id, ...attributes },
  capabilities: { canReceive: Object.keys(attributes) }, ...extra });
const at = (name) => ({ room: { id: name, name } });
const dirigeraDevices = [
  ikea("bulb-1", "light", "light", "Sofa Lamp", "TRADFRI bulb E27 CWS 806lm", { isOn: true, lightLevel: 60, colorHue: 30, colorSaturation: 0.6, colorTemperature: 2801, colorTemperatureMin: 4000, colorTemperatureMax: 2202 }, at("Living Room")),
  ikea("bulb-2", "light", "light", "Hallway", "TRADFRI bulb E14 W 470lm", { isOn: false, lightLevel: 100 }, at("Hallway")),
  ikea("plug-1", "outlet", "outlet", "Coffee Machine", "TRETAKT Smart plug", { isOn: false }, at("Kitchen")),
  ikea("door-1", "sensor", "openCloseSensor", "Front Door", "PARASOLL Door/Window Sensor", { isOpen: false, batteryPercentage: 80 }, at("Hallway")),
  ikea("motion-1", "sensor", "motionSensor", "Hall Motion", "VALLHORN Wireless Motion Sensor", { isDetected: true, isOn: true, batteryPercentage: 64 }, { relationId: "vallhorn-1", ...at("Hallway") }),
  ikea("lux-1", "unknown", "lightSensor", "Hall Motion", "VALLHORN Wireless Motion Sensor", { illuminance: 120 }, { relationId: "vallhorn-1", ...at("Hallway") }),
  ikea("air-1", "sensor", "environmentSensor", "Office Air", "VINDSTYRKA", { currentTemperature: 22.5, currentRH: 41, currentPM25: 18, vocIndex: 120 }, at("Office")),
  ikea("leak-1", "sensor", "waterSensor", "Sink", "BADRING Water Leakage Sensor", { waterLeakDetected: false, batteryPercentage: 90 }, at("Kitchen")),
  ikea("blind-1", "blinds", "blinds", "Bedroom Blind", "FYRTUR block-out roller blind", { blindsCurrentLevel: 30, blindsTargetLevel: 30, blindsState: "stopped", batteryPercentage: 55 }, at("Bedroom")),
  ikea("purifier-1", "airPurifier", "airPurifier", "Air Purifier", "STARKVIND Air purifier", { fanMode: "auto", motorState: 10, filterAlarmStatus: false, filterElapsedTime: 129600, filterLifetime: 259200, childLock: false, statusLight: true, currentPM25: 4 }, at("Bedroom")),
  ikea("remote-up", "controller", "lightController", "Kitchen Remote", "STYRBAR remote control", { batteryPercentage: 8 }, { relationId: "styrbar-1", ...at("Kitchen") }),
  ikea("remote-down", "controller", "lightController", "Kitchen Remote", "STYRBAR remote control", {}, { relationId: "styrbar-1", ...at("Kitchen") }),
];
const dirigeraScenes = [["Movie night", "scenes_tv"], ["Dinner", "scenes_dinner"], ["Good night", "scenes_moon"], ["Focus", "scenes_book"]]
  .map(([name, icon], index) => ({ id: `scene-${index}`, info: { name, icon }, type: "userScene", triggers: [], actions: [] }))
  .concat([{ id: "wake", info: { name: "Wake up", icon: "scenes_sun" }, type: "wakeUpScene" }]);
const dirigera = createServer(tls, (request, response) => {
  const json = (value) => { response.writeHead(200, { "Content-Type": "application/json" }); response.end(JSON.stringify(value)); };
  if (request.headers.authorization !== "Bearer demo-token") { response.writeHead(401); return response.end(); }
  if (request.url === "/v1/devices") return json(dirigeraDevices);
  if (request.url === "/v1/scenes") return json(dirigeraScenes);
  response.writeHead(202); response.end();
}).listen(dirigeraPort, "127.0.0.1");
// The hub's websocket is not faked: the plugin shows what it read and tries the events again later.
dirigera.on("upgrade", (_request, socket) => socket.destroy());

// MARK: The bridge

const storage = join(scratch, "storage");
const hueFolder = join(storage, "plugins", "PhilipsHue-Philips-Hue");
mkdirSync(hueFolder, { recursive: true });
writeFileSync(join(hueFolder, "bridge.json"), JSON.stringify({ host: `127.0.0.1:${huePort}`, bridgeID: "001788fffe000001", applicationKey: "demo-key" }));
writeFileSync(join(storage, "config.json"), JSON.stringify({
  bridge: { name: "Homeswift", port: 51996 },
  platforms: [
    { platform: "HomeswiftUI", name: "Web UI", port: uiPort, host: "127.0.0.1", auth: "none", checkForUpdates: false, scheduledBackupDisable: true },
    { platform: "PhilipsHue", name: "Philips Hue", host: `127.0.0.1:${huePort}`, transitionMs: 400 },
    { platform: "Dirigera", name: "IKEA DIRIGERA", hubs: [{ host: "127.0.0.1", token: "demo-token", name: "Home" }] },
  ],
}, null, 2));
const bridge = spawn(binary, ["-U", storage], { stdio: "ignore" });
/// Stops the bridge and the fake devices and removes the scratch folder, whatever stops the script.
async function stop() {
  const exited = new Promise((done) => bridge.exitCode !== null ? done() : bridge.once("exit", done));
  bridge.kill();
  hue.close();
  dirigera.close();
  await Promise.race([exited, sleep(5000)]);
  try { rmSync(scratch, { recursive: true, force: true }); } catch {}
}
let up = false;
for (let i = 0; i < 80 && !up; i++) {
  try { up = (await fetch(`${base}/api/status`)).ok; } catch {}
  if (!up) await sleep(250);
}
if (!up) { await stop(); throw new Error(`the bridge did not start (${binary})`); }

// MARK: Headless Chrome

const replacements = [[`127.0.0.1:${huePort}`, "192.168.1.20"], ["127.0.0.1", "192.168.1.30"], [storage, "/Users/demo/.homeswift"], [hostname(), "homeswift-mac"], [hostname().replace(/\.local$/, ""), "homeswift-mac"]];
const pageScript = `(() => {
  const pairs = ${JSON.stringify(replacements)};
  const clean = (text) => pairs.reduce((s, [real, shown]) => s.split(real).join(shown), text);
  const original = window.fetch;
  window.fetch = async (input, init) => {
    const response = await original(input, init);
    if (!(response.headers.get("content-type") || "").includes("json") || !response.ok) return response;
    return new Response(clean(await response.clone().text()), { status: response.status, headers: response.headers });
  };
  const Source = window.EventSource;
  window.EventSource = class extends Source {
    addEventListener(name, listener, options) {
      super.addEventListener(name, (event) => listener.call(this, new MessageEvent(event.type, { data: clean(String(event.data)), lastEventId: event.lastEventId })), options);
    }
  };
})();`;
const profile = mkdtempSync(join(tmpdir(), "homeswift-plugin-chrome-"));
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ["--headless=new", "--remote-debugging-port=9335", `--user-data-dir=${profile}`, "--hide-scrollbars", "--no-first-run", "about:blank"], { stdio: "ignore" });
let target;
for (let i = 0; i < 50 && !target; i++) {
  try { target = (await (await fetch("http://127.0.0.1:9335/json/list")).json()).find((t) => t.type === "page"); } catch {}
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

/// Opens a plugin page at the size given, chooses its tab, waits for `ready`, and saves the page down to `tall` at most.
async function shot(name, path, { tab, ready, width = 1280, height = 900, mobile = false, tall = 2800 }) {
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile });
  await send("Page.navigate", { url: base + path });
  const wait = async (selector) => {
    for (let i = 0; i < 80; i++) {
      if (await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`)) return;
      await sleep(250);
    }
    throw new Error(`${name}: ${selector} did not appear`);
  };
  // A click before the page's script has wired its tabs does nothing: click until the tab says it is chosen.
  const chosen = `button[data-tab="${tab}"][aria-selected="true"]`;
  for (let i = 0; i < 40 && !(await evaluate(`!!document.querySelector('${chosen}')`)); i++) {
    await evaluate(`document.querySelector('button[data-tab="${tab}"]')?.click()`);
    await sleep(250);
  }
  await wait(chosen);
  await wait(ready);
  await sleep(1200);
  const full = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: Math.min(full, tall), scale: 1 } });
  writeFileSync(join(out, `${name}.png`), Buffer.from(data, "base64"));
  console.log(`${name}.png ${width}×${Math.min(full, tall)}`);
}

try {
  await shot("hue-lights", "/plugins/philips-hue", { tab: "lights", ready: "#lights .widget" });
  await shot("hue-sensors", "/plugins/philips-hue", { tab: "sensors", ready: "#sensors .widget" });
  await shot("hue-scenes", "/plugins/philips-hue", { tab: "scenes", ready: "#scenes .scene" });
  await shot("hue-settings", "/plugins/philips-hue", { tab: "settings", ready: "#options .toggle" });
  await shot("hue-scenes-phone", "/plugins/philips-hue", { tab: "scenes", ready: "#scenes .scene", width: 390, height: 844, mobile: true, tall: 1530 });
  await shot("dirigera-devices", "/plugins/ikea-dirigera", { tab: "devices", ready: "#devices .widget" });
  await shot("dirigera-scenes", "/plugins/ikea-dirigera", { tab: "scenes", ready: "#scenes .scene" });
} finally {
  socket.close();
  const exited = new Promise((done) => chrome.once("exit", done));
  chrome.kill();
  await Promise.race([exited, sleep(5000)]);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
  await stop();
}
