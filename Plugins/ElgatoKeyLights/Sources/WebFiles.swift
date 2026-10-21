// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension ElgatoKeyLightsPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: PluginWebFile] = [
        "app.js": PluginWebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Elgato Key Lights page: the lights the plugin instance knows, refreshed every two seconds.
(() => {
  "use strict";

  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

  document.getElementById("instance").textContent = homeswift.name;
  const list = document.getElementById("lights");

  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "?");

  async function identify(light, button) {
    button.disabled = true;
    try { await homeswift.request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }); } catch (e) { alert(e.message); }
    button.disabled = false;
  }

  async function refresh() {
    try {
      const { lights } = await homeswift.request("lights");
      if (lights.length === 0) {
        list.replaceChildren(el("p", { class: "muted", text: "No light found yet. Lights announce themselves over Bonjour; lights with an address in config.json are polled directly." }));
        return;
      }
      list.replaceChildren(...lights.map((light) => el("div", { class: "card" },
        el("div", { class: "item-head" },
          el("div", {}, el("strong", { text: light.name }), el("div", { class: "muted", text: `${light.model} · ${light.serial}` })),
          el("span", { class: `pill ${light.reachable ? "on" : ""}`, text: light.reachable ? light.status : "no response" })),
        el("dl", {},
          el("dt", { text: "Address" }), el("dd", { text: `${light.host}:${light.port}${light.pinned ? " (from config.json)" : ""}` }),
          el("dt", { text: "MAC" }), el("dd", { text: light.mac }),
          el("dt", { text: "Firmware" }), el("dd", { text: light.firmware }),
          el("dt", { text: "State" }), el("dd", { text: light.on ? `on, ${light.brightness}%, ${kelvin(light.temperature)}` : "off" })),
        el("div", { class: "actions" }, el("button", { text: "Identify", onclick: (event) => identify(light, event.target) })))));
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  refresh();
  setInterval(refresh, 2000);
})();

"""#),
        "index.html": PluginWebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Elgato Key Lights</title>
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
  <h1>Elgato Key Lights</h1>
  <p class="muted">The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.</p>
  <div id="lights" class="cards"></div>
</main>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
