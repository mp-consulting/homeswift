// Retakes the Philips Hue and IKEA DIRIGERA pages' screenshots, and the Scenes page with their scenes, (docs/images/plugins),
// the scene editor's and the Quick controls' (docs/images/ui) and the Status page's Energy section (docs/images/status,
// on demonstration energy figures the page is given) with headless Chrome: light mode,
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
import { mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";

/// A value as a JavaScript literal for code run in the page: JSON, with the characters that could end a script or a
/// line early (<, >, /, U+2028, U+2029) escaped.
const literal = (value) => JSON.stringify(value).replace(/[<>\/\u2028\u2029]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);

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
  // A pairing: the link button is never pressed, so a bridge set up on the Add accessories page waits for it.
  if (request.method === "POST" && request.url === "/api") return json([{ error: { type: 101, description: "link button not pressed" } }]);
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
    // A second bridge not paired yet, for the Add accessories page's Pair row.
    { platform: "PhilipsHue", name: "Upstairs Hue", host: `127.0.0.1:${huePort}` },
    { platform: "Dirigera", name: "IKEA DIRIGERA", hubs: [{ host: "127.0.0.1", token: "demo-token", name: "Home" }] },
    // An Assistant that reaches no provider: the chat shows the conversation below, and nothing is asked again.
    { platform: "HomeswiftAiKit", name: "Assistant", provider: "openai-compatible", baseUrl: "http://127.0.0.1:9/v1", model: "demo" },
  ],
}, null, 2));
// Two saved scenes on the living room's lights, for the Scenes page's cards.
// Each light's own lightbulb by name: its effects' switches and a strip's points have On too.
const lightNames = { l2: "Ceiling", l3: "Floor Lamp", l6: "TV Lightstrip" };
const action = (light, characteristic, value) => ({ id: `PhilipsHue:${light}`, service: lightNames[light], characteristic, value });
writeFileSync(join(storage, "scenes.json"), JSON.stringify({ version: 1, scenes: [
  { id: "5ce0e0000000a001", name: "Movie night", artworkId: "mood-cinema", homeKit: true, triggers: [], conditions: [],
    actions: [action("l2", "On", false), action("l3", "On", true), action("l3", "Brightness", 20), action("l6", "On", true), action("l6", "Hue", 230), action("l6", "Saturation", 80)] },
  { id: "5ce0e0000000a002", name: "Evening", artworkId: "rolling-hills", conditions: [{ type: "time", after: "sunset", before: "23:00" }],
    triggers: [{ type: "schedule", time: "19:30", days: [1, 2, 3, 4, 5], enabled: true }],
    actions: [action("l2", "On", true), action("l2", "Brightness", 60), action("l3", "On", true), action("l3", "Brightness", 45)] },
] }));
// A conversation where the Assistant started pairing the second bridge and handed the button press to the Setup sheet.
const now = new Date().toISOString();
writeFileSync(join(storage, "ui-chats.json"), JSON.stringify({ local: { current: { id: "c0ffee0000000001", created: now, updated: now, messages: [], items: [
  { kind: "user", text: "Add my Hue Bridge upstairs" },
  { kind: "tool", id: "t1", name: "discover_devices", title: "Find devices", summary: "Philips Hue · Upstairs Hue", state: "done" },
  { kind: "tool", id: "t2", name: "start_setup", title: "Set up a device", summary: "Upstairs Hue", state: "done" },
  { kind: "setup", session: "5e7up0000000001", platform: "PhilipsHue", name: "Upstairs Hue", message: "Press the link button on the Hue Bridge." },
  { kind: "assistant", text: "I found the Hue Bridge at 192.168.1.20. Press its link button, then continue in the Setup sheet: it pairs the bridge and adds its lights." },
] } } }));
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

// The Energy section's demonstration figures: the page asks /api/metrics/energy and its history, and is answered with a
// day of fifteen-minute power (solar following the sun, the home's evening peak, the batteries charging on the surplus
// and covering the evening, the grid the rest), two batteries' charge, and a week of days, all consistent.
const energyDemo = `(() => {
  const solarAt = (t) => { const d = new Date(t), h = d.getHours() + d.getMinutes() / 60; return Math.max(0, Math.sin((h - 6.5) / 13 * Math.PI)) * 2800; };
  const homeAt = (t) => { const d = new Date(t), h = d.getHours() + d.getMinutes() / 60; return 420 + (h >= 18 && h < 22.5 ? 1100 : 0) + (h >= 6.5 && h < 8 ? 700 : 0) + 160 * Math.sin(t / 2.7e6) + (h >= 12 && h < 13 ? 900 : 0); };
  const day = (date) => date.toLocaleDateString("en-CA");
  const report = (from, to) => {
    const step = 900, power = [], garage = [], office = [];
    let level = 34;
    for (let t = Math.floor(from / 9e5) * 9e5; t <= to; t += 9e5) {
      const solar = solarAt(t), home = homeAt(t), surplus = solar - home, h = new Date(t).getHours();
      let battery = surplus > 0 ? Math.min(surplus, level < 100 ? 1400 : 0) : (h >= 17 || h < 1) && level > 15 ? -Math.min(-surplus, 650) : 0;
      level = Math.max(10, Math.min(100, level + battery * 0.25 / 2560 * 100));
      const grid = home - solar + battery;
      power.push({ t: t / 1000, solar: Math.round(solar), home: Math.round(home), battery: Math.round(battery), grid: Math.round(grid) });
      garage.push([t / 1000, Math.round(level * 10) / 10]);
      office.push([t / 1000, Math.round(Math.min(100, level * 0.8 + 18) * 10) / 10]);
    }
    const days = [];
    for (let back = 7; back >= 0; back--) {
      const start = new Date(); start.setHours(0, 0, 0, 0); start.setDate(start.getDate() - back);
      const k = back === 0 ? Math.min(1, (Date.now() - start) / 864e5) : 1, wave = 1 + 0.18 * Math.sin(back * 1.7);
      const solar = 13.2 * wave * k, home = 15.4 * (2 - wave) * 0.55 * k + 6.8 * k, fromSolar = Math.min(solar * 0.62, home), charge = solar * 0.24, discharge = charge * 0.9;
      const gridImport = Math.max(0, home - fromSolar - discharge), gridExport = Math.max(0, solar - fromSolar - charge);
      days.push({ date: day(start), minutes: Math.round(1440 * k), solar, home, gridImport, gridExport, batteryCharge: charge, batteryDischarge: discharge, homeFromSolar: fromSolar, solarShare: fromSolar / home });
    }
    return { roles: ["solar", "home", "battery", "grid"], step, power,
      levels: [{ series: "energy:garage", device: "Garage battery", points: garage }, { series: "energy:office", device: "Office battery", points: office }], days };
  };
  const history = () => {
    const bars = [];
    for (let back = 7; back >= 0; back--) {
      const start = new Date(); start.setHours(0, 0, 0, 0); start.setDate(start.getDate() - back);
      const k = back === 0 ? Math.min(1, (Date.now() - start) / 864e5) : 1, wave = 1 + 0.18 * Math.sin(back * 1.7);
      const solar = 13.2 * wave * k, home = 15.4 * (2 - wave) * 0.55 * k + 6.8 * k, fromSolar = Math.min(solar * 0.62, home), charge = solar * 0.24, discharge = charge * 0.9;
      const fromGrid = Math.max(0, home - fromSolar - discharge), exported = Math.max(0, solar - fromSolar - charge), round = (x) => Math.round(x * 100) / 100;
      bars.push({ date: day(start), solar: round(solar), home: round(home), homeFromSolar: round(fromSolar), homeFromBattery: round(discharge), homeFromGrid: round(fromGrid), homeNotSplit: 0,
        gridImport: round(fromGrid), gridExport: round(exported), batteryCharge: round(charge), batteryDischarge: round(discharge), solarShare: Math.round(fromSolar / home * 1000) / 1000,
        recordedHours: Math.round(24 * k), importedHours: 0 });
    }
    return { period: "week", earliest: bars[0].date, imports: [], bars };
  };
  const original = window.fetch;
  window.fetch = (input, init) => {
    const url = new URL(String(input), location.href);
    const answer = (body) => Promise.resolve(new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } }));
    if (url.pathname === "/api/metrics/energy") return answer(report(Date.parse(url.searchParams.get("from")) || Date.now() - 864e5, Date.parse(url.searchParams.get("to")) || Date.now()));
    if (url.pathname === "/api/metrics/energy/history") return answer(history());
    return original(input, init);
  };
})();`;

// MARK: Headless Chrome

const replacements = [[`127.0.0.1:${huePort}`, "192.168.1.20"], ["127.0.0.1", "192.168.1.30"], [storage, "/Users/demo/.homeswift"], [hostname(), "homeswift-mac"], [hostname().replace(/\.local$/, ""), "homeswift-mac"]];
const pageScript = `(() => {
  const pairs = ${literal(replacements)};
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
/// `before` runs in the page ahead of its own scripts (demonstration answers for the Energy section).
async function shot(name, path, { tab, ready, width = 1280, height = 900, mobile = false, tall = 2800, prepare = "", element, before, viewport = false }) {
  if (process.env.PLUGIN_SHOTS_ONLY && !process.env.PLUGIN_SHOTS_ONLY.split(",").includes(name)) return;
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile });
  const early = before ? (await send("Page.addScriptToEvaluateOnNewDocument", { source: before })).identifier : null;
  await send("Page.navigate", { url: base + path });
  const wait = async (selector) => {
    for (let i = 0; i < 80; i++) {
      if (await evaluate(`!!document.querySelector(${literal(selector)})`)) return;
      await sleep(250);
    }
    throw new Error(`${name}: ${selector} did not appear`);
  };
  // A click before the page's script has wired its tabs does nothing: click until the tab says it is chosen. A page
  // without tabs (the Scenes page) has none to choose.
  if (tab) {
    const chosen = `button[data-tab="${tab}"][aria-selected="true"]`;
    for (let i = 0; i < 40 && !(await evaluate(`!!document.querySelector(${literal(chosen)})`)); i++) {
      await evaluate(`document.querySelector(${literal(`button[data-tab="${tab}"]`)})?.click()`);
      await sleep(250);
    }
    await wait(chosen);
  }
  try { await wait(ready); } finally { if (early) await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: early }); }
  await sleep(1200);
  // `prepare` acts on the page first (a template tried); `element` saves only that part of the page, with a margin.
  if (prepare) { await evaluate(`(async () => { ${prepare} })()`); await sleep(1500); }
  let clip;
  if (viewport) {
    // What the screen shows where the page is scrolled to (a dialog over it).
    const top = await evaluate("scrollY");
    clip = { x: 0, y: top, width, height, scale: 1 };
  } else if (element) {
    const box = await evaluate(`(() => { const r = document.querySelector(${literal(element)}).getBoundingClientRect();
      return { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height }; })()`);
    clip = { x: Math.max(0, box.x - 12), y: Math.max(0, box.y - 12), width: box.width + 24, height: Math.min(box.height + 24, tall), scale: 1 };
  } else {
    const full = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
    clip = { x: 0, y: 0, width, height: Math.min(full, tall), scale: 1 };
  }
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, clip });
  writeFileSync(join(out, `${name}.png`), Buffer.from(data, "base64"));
  console.log(`${name}.png ${Math.round(clip.width)}×${Math.round(clip.height)}`);
}

try {
  await shot("hue-lights", "/plugins/philips-hue", { tab: "lights", ready: "#lights .widget" });
  await shot("hue-sensors", "/plugins/philips-hue", { tab: "sensors", ready: "#sensors .widget" });
  await shot("hue-scenes", "/plugins/philips-hue", { tab: "scenes", ready: "#scenes .scene" });
  await shot("hue-settings", "/plugins/philips-hue", { tab: "settings", ready: "#options .toggle" });
  await shot("hue-scenes-phone", "/plugins/philips-hue", { tab: "scenes", ready: "#scenes .scene", width: 390, height: 844, mobile: true, tall: 1530 });
  await shot("dirigera-devices", "/plugins/ikea-dirigera", { tab: "devices", ready: "#devices .widget" });
  await shot("dirigera-scenes", "/plugins/ikea-dirigera", { tab: "scenes", ready: "#scenes .scene" });
  // Homeswift's Scenes page: the bridge's and the hub's scenes, by room, with their pictures, colours and menus.
  await shot("scenes-from-hubs", "/scenes", { ready: ".hub-scene", tall: 1400 });
  // The templates for a room's lights (docs/ui.md, docs/images/ui): the first kinds, one tried and playing, on a phone.
  const templates = join(root, "docs/images/ui");
  const shotUI = (name, options) => shot(name, "/scenes", { ready: ".templates .template-button", ...options }).then(() => {
    if (!process.env.PLUGIN_SHOTS_ONLY || process.env.PLUGIN_SHOTS_ONLY.split(",").includes(name)) renameSync(join(out, `${name}.png`), join(templates, `${name}.png`));
  });
  // The first kind of templates after the gallery (Calm), and the gallery's shelves.
  const kind = ".templates .template-group:has(> .template-buttons)";
  await shotUI("template-photographs", { element: kind, tall: 900 });
  await shotUI("template-row-phone", { width: 390, height: 844, mobile: true, element: kind, tall: 700 });
  await shotUI("template-playing", { element: kind, prepare: `document.querySelector(${literal(`${kind} .template-button`)})?.click();`, tall: 900 });
  await shotUI("scene-gallery-phone", { width: 390, height: 844, mobile: true, element: ".templates .template-group:has(.artwork-themes)", tall: 900 });
  // A saved scene's card, its actions open; and once it ran, with Stop.
  await shotUI("scene-card-details", { ready: ".scene-card", element: ".scene-card", prepare: 'document.querySelector(".scene-card details").open = true;' });
  await shotUI("scene-stop", { ready: ".scene-card", element: ".scene-card",
    prepare: 'document.querySelector(".scene-card .scene-run-actions button.primary").click(); await new Promise((done) => setTimeout(done, 1500)); history.go(0);' });

  // The scene editor (docs/ui.md, "Scenes"): its workflow on Movie night's actions; Evening's weekday trigger and its
  // time window; on a phone, the workflow, the condition and deleting the scene.
  const into = (folder) => (name) => {
    if (!process.env.PLUGIN_SHOTS_ONLY || process.env.PLUGIN_SHOTS_ONLY.split(",").includes(name)) {
      mkdirSync(folder, { recursive: true });
      renameSync(join(out, `${name}.png`), join(folder, `${name}.png`));
    }
  };
  const toUI = into(templates), toStatus = into(join(root, "docs/images/status"));
  // The Add accessories page (docs/ui.md), and its sheet pairing the second bridge.
  await shot("setup", "/setup", { ready: ".setup-account", tall: 1700 }).then(() => toUI("setup"));
  await shot("setup-pair", "/setup", { ready: ".setup-account button.primary", viewport: true, height: 720,
    prepare: `document.querySelector(".setup-account button.primary").click(); await new Promise((done) => setTimeout(done, 1500));` }).then(() => toUI("setup-pair"));
  // The Assistant's chat handing a Setup to the sheet (docs/ui.md, "Add accessories").
  await shot("setup-assistant", "/setup", { ready: ".setup-account", viewport: true, height: 760,
    prepare: `HomeswiftChat.open(); await new Promise((done) => setTimeout(done, 1500));` }).then(() => toUI("setup-assistant"));
  const step = (title) => `[...document.querySelectorAll(".scene-flow-nav")].find((b) => b.textContent.includes(${literal(title)}))?.click();`;
  // A phone's fixed save bar and menu button would land mid-picture in a capture taller than the screen.
  const unpinned = `const style = document.createElement("style"); style.textContent = ".save-bar, nav.tabbar { display: none !important; }"; document.head.append(style);`;
  const movie = "/scenes/5ce0e0000000a001", evening = "/scenes/5ce0e0000000a002";
  await shot("scene-controls", movie, { ready: ".scene-flow-nav", height: 720, element: ".scene-flow", prepare: step("Actions") }).then(() => toUI("scene-controls"));
  await shot("scene-trigger-controls", evening, { ready: ".scene-flow-nav", element: ".scene-flow-panel:not([hidden]) .editor-row", prepare: step("Triggers") })
    .then(() => toUI("scene-trigger-controls"));
  await shot("scene-workflow-phone", movie, { ready: ".scene-flow-nav", width: 390, height: 844, mobile: true, element: ".scene-flow", tall: 844, prepare: unpinned + step("Actions") })
    .then(() => toUI("scene-workflow-phone"));
  await shot("scene-condition-phone", evening, { ready: ".scene-flow-nav", width: 390, height: 844, mobile: true, element: ".scene-flow-panel:not([hidden])", tall: 900, prepare: unpinned + step("Conditions") })
    .then(() => toUI("scene-condition-phone"));
  await shot("scene-delete", movie, { ready: ".scene-flow-nav", width: 390, height: 844, mobile: true, viewport: true,
    prepare: '[...document.querySelectorAll(".scene-editor button")].find((b) => b.textContent.trim() === "Delete")?.click();' }).then(() => toUI("scene-delete"));
  // The Scenes page's location: an address search, its answers the page is given (no request leaves for Photon).
  await shot("scene-address-search", "/scenes", { ready: "details.location", element: "#shot-address", width: 560,
    prepare: `
      const answers = [["Coimbra", "Portugal", 40.2033, -8.4103], ["Coimbra", "Minas Gerais, Brazil", -20.8556, -42.8017], ["Coimbra-B", "3000-312 Coimbra, Portugal", 40.2226, -8.4436]];
      const fetched = window.fetch;
      window.fetch = (input, init) => String(input).startsWith("https://photon.komoot.io/") ? Promise.resolve(new Response(JSON.stringify({ features: answers.map(([name, place, lat, lon]) => ({
        geometry: { coordinates: [lon, lat] }, properties: { name, city: name === "Coimbra-B" ? "Coimbra" : undefined, state: place.split(", ").slice(-2, -1)[0], country: place.split(", ").at(-1) } })) }), { headers: { "Content-Type": "application/json" } })) : fetched(input, init);
      document.querySelector("details.location").open = true;
      const form = document.querySelector(".location-search");
      form.id = "shot-address";
      form.querySelector("input").value = "Coimbra";
      form.requestSubmit();` }).then(() => toUI("scene-address-search"));
  // The Status page on a phone: the overview and the Quick controls with the scenes.
  await shot("quick-controls-phone", "/status", { ready: ".quick .scene-button, .quick-scenes", width: 390, height: 844, mobile: true, tall: 430 }).then(() => toUI("quick-controls-phone"));
  // The Energy section, on a day and a week of demonstration figures.
  await shot("energy", "/status", { ready: '[data-widget="energy"] .chart-card svg', width: 1100, height: 900, element: '[data-widget="energy"]', before: energyDemo })
    .then(() => toStatus("energy"));
} finally {
  socket.close();
  const exited = new Promise((done) => chrome.once("exit", done));
  chrome.kill();
  await Promise.race([exited, sleep(5000)]);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
  await stop();
}
