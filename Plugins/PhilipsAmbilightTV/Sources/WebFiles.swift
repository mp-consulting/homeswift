// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Ambilight TV page: the TVs the plugin instance knows, refreshed every two seconds while the
// page is visible, a few remote keys, and the pairing flow that produces a TV's configuration entry.
(() => {
  "use strict";
  const { $, el, request, name, platform } = homeswift;

  $("#instance").textContent = name;
  const list = $("#tvs");
  const keys = [["Home", "Home"], ["Back", "Back"], ["PlayPause", "Play/Pause"], ["Mute", "Mute"], ["VolumeDown", "Vol −"], ["VolumeUp", "Vol +"], ["AmbilightOnOff", "Ambilight"], ["Standby", "Standby"]];

  async function act(button, work, report = alert) {
    button.disabled = true;
    try { await work(); } catch (e) { report(e.message); }
    button.disabled = false;
  }

  let shown = null;
  async function refresh() {
    try {
      const { tvs } = await request("tvs");
      const answer = JSON.stringify(tvs);
      if (answer === shown) return;
      shown = answer;
      if (tvs.length === 0) {
        list.replaceChildren(el("p", { class: "muted", text: "No TV configured yet. Pair one below, then add it to the configuration." }));
        return;
      }
      list.replaceChildren(...tvs.map((tv) => el("div", { class: "card" },
        el("div", { class: "item-head" },
          el("div", {}, el("strong", { text: tv.name }), el("div", { class: "muted", text: `${tv.ip} · ${tv.mac}` })),
          el("span", { class: `pill ${tv.on ? "on" : ""}`, text: tv.on ? "on" : tv.reachable ? "standby" : "no response" })),
        el("dl", {},
          el("dt", { text: "Input" }), el("dd", { text: tv.on ? `${tv.currentInput ?? "?"}${tv.currentApp ? ` (${tv.currentApp})` : ""}` : "—" }),
          el("dt", { text: "Ambilight" }), el("dd", { text: tv.on ? (tv.ambilight ? (tv.ambilightStyle ?? "on") : "off") : "—" }),
          el("dt", { text: "Sound" }), el("dd", { text: tv.on ? (tv.muted ? "muted" : "on") : "—" }),
          el("dt", { text: "Inputs" }), el("dd", { text: `${tv.inputs}` }),
          el("dt", { text: "Updates" }), el("dd", { text: tv.longPoll === "confirmed" ? "pushed by the TV" : tv.longPoll === "waiting" ? "polling, waiting for the TV's push" : "polling" }),
          el("dt", { text: "Certificate" }), el("dd", { text: tv.pinned ? "pinned" : "not pinned (pair again to pin it)" })),
        el("div", { class: "actions" },
          el("button", { text: "Wake", onclick: (event) => act(event.target, () => request(`wake?mac=${encodeURIComponent(tv.mac)}`, { method: "POST" })) }),
          ...keys.map(([key, label]) => el("button", { text: label, onclick: (event) => act(event.target, () => request("key", { method: "POST", body: { mac: tv.mac, key } })) }))))));
    } catch (e) {
      shown = null;
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // Pairing: discover → request (the TV shows a PIN) → grant → the device entry, added to the block or copied.
  const pairing = $("#pairing");
  const ip = el("input", { type: "text", placeholder: "192.168.1.20", autocomplete: "off", spellcheck: false });
  const tvName = el("input", { type: "text", placeholder: "Living Room TV", autocomplete: "off" });
  const pin = el("input", { type: "text", placeholder: "PIN shown on the TV", inputmode: "numeric", maxlength: 4, autocomplete: "one-time-code" });
  const mac = el("input", { type: "text", placeholder: "AA:BB:CC:DD:EE:FF", autocomplete: "off", spellcheck: false });
  const status = el("p", { class: "muted" });
  const say = (message, isError = false) => { status.textContent = message; status.className = isError ? "error" : "muted"; };
  const fail = (message) => say(message, true);
  const found = el("div", {});
  const result = el("pre", { class: "hidden" });
  let device = null;

  const step1 = el("div", {},
    el("div", { class: "field" }, el("label", { text: "TV address" }), ip),
    el("div", { class: "field" }, el("label", { text: "Name in HomeKit" }), tvName),
    el("div", { class: "actions" },
      el("button", { text: "Find TVs", onclick: (event) => act(event.target, discover, fail) }),
      el("button", { class: "primary", text: "Pair", onclick: (event) => act(event.target, pair, fail) })),
    found);
  const step2 = el("div", { class: "hidden" },
    el("div", { class: "field" }, el("label", { text: "PIN" }), pin),
    el("div", { class: "actions" }, el("button", { class: "primary", text: "Finish pairing", onclick: (event) => act(event.target, grant, fail) })));
  const step3 = el("div", { class: "hidden" },
    el("div", { class: "field" }, el("label", { text: "MAC address (for Wake-on-LAN; the TV's network settings show it)" }), mac),
    el("div", { class: "actions" },
      el("button", { class: "primary", text: "Add to the configuration", onclick: (event) => act(event.target, addToConfiguration, fail) }),
      el("button", { text: "Copy the entry", onclick: (event) => act(event.target, async () => { await navigator.clipboard.writeText(result.textContent); say("Copied."); }, fail) })),
    result);
  pairing.replaceChildren(step1, step2, step3, status);

  async function discover() {
    say("Looking for TVs for five seconds…");
    const { tvs } = await request("discover");
    say(tvs.length ? "" : "No TV announced itself. Make sure it is on; you can type its address.");
    found.replaceChildren(...tvs.map((tv) => el("div", { class: "item" },
      el("span", { text: `${tv.name} · ${tv.host}` }),
      el("button", { text: "Use", onclick: () => { ip.value = tv.host; if (!tvName.value) tvName.value = tv.name; } }))));
  }

  async function pair() {
    device = null;
    step2.classList.add("hidden");
    step3.classList.add("hidden");
    const answer = await request("pair", { method: "POST", body: { ip: ip.value.trim(), name: "Homeswift" } });
    say(answer.message + (answer.certificateSeen ? "" : " (The TV answered over plain HTTP: its certificate cannot be pinned.)"));
    step2.classList.remove("hidden");
    pin.value = "";
    pin.focus();
  }

  async function grant() {
    const answer = await request("pair/grant", { method: "POST", body: { ip: ip.value.trim(), pin: pin.value.trim() } });
    device = { name: tvName.value.trim() || "Philips TV", ...answer.device };
    mac.value = device.mac ?? "";
    step2.classList.add("hidden");
    step3.classList.remove("hidden");
    say(`Paired.${answer.certificatePinned ? " The certificate is pinned." : ""}${device.mac ? "" : " The TV did not say its MAC address: type it for Wake-on-LAN."}`);
    showEntry();
  }

  function showEntry() {
    if (!device) return;
    const entry = { ...device };
    if (mac.value.trim()) entry.mac = mac.value.trim().toUpperCase(); else delete entry.mac;
    result.textContent = JSON.stringify(entry, null, 2);
    result.classList.remove("hidden");
    return entry;
  }
  mac.addEventListener("input", showEntry);
  tvName.addEventListener("input", () => { if (device) { device.name = tvName.value.trim() || "Philips TV"; showEntry(); } });

  // The page runs inside the signed-in UI, so it can edit this instance's block like the settings form does.
  async function addToConfiguration() {
    const entry = showEntry();
    if (!entry) return;
    if (!/^([0-9A-F]{2}[:-]){5}[0-9A-F]{2}$/i.test(entry.mac ?? "")) throw new Error("A MAC address is needed: the TV's network settings show it.");
    const api = async (path, options = {}) => {
      const response = await fetch(path, { credentials: "same-origin", ...options });
      if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || `HTTP ${response.status}`);
      return response.json();
    };
    const plugins = await api("/api/plugins");
    const block = (plugins.blocks || []).find((b) => b.platform === platform && b.name === name);
    if (!block) throw new Error("This instance's block was not found in the configuration; copy the entry instead.");
    const config = await api("/api/config");
    const current = config.platforms[block.index];
    const devices = (current.devices || []).filter((d) => (d.mac || "").toUpperCase() !== entry.mac.toUpperCase());
    devices.push(entry);
    await api(`/api/config/platforms/${block.index}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...current, devices }) });
    say("Saved to config.json. Restart Homeswift (the Status page has a button), then add the TV in the Home app with the setup code shown there.");
  }

  let timer = null;
  function start() { if (timer) return; refresh(); timer = setInterval(refresh, 2000); }
  function stop() { clearInterval(timer); timer = null; }
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Philips Ambilight TV</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header>
  <a class="brand" href="/#plugins"><img src="/icon.svg" class="logo" alt="">Homeswift</a>
  <nav><a href="/#plugins">Plugins</a></nav>
  <span class="spacer"></span>
  <span id="instance" class="muted"></span>
</header>
<main>
  <h1>Philips Ambilight TV</h1>
  <p class="muted">The TVs this instance knows, as it sees them right now, and the pairing a new TV needs before it can be configured.</p>
  <div id="tvs" class="cards"></div>
  <h2>Pair a TV</h2>
  <p class="muted">Switch the TV on, enter its address (or find it below), then type the PIN the TV shows. The result is the TV's entry for this plugin's configuration.</p>
  <div id="pairing" class="card"></div>
</main>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
