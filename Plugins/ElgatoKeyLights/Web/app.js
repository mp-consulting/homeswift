// The Elgato Key Lights page: the lights the plugin instance knows, refreshed every two seconds while the
// page is visible, and redrawn only when something changed.
(() => {
  "use strict";
  const { $, el, request, name } = homeswift;

  $("#instance").textContent = name;
  const list = $("#lights");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "?");

  async function identify(light, button) {
    button.disabled = true;
    try { await request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }); } catch (e) { alert(e.message); }
    button.disabled = false;
  }

  let shown = null;
  async function refresh() {
    try {
      const { lights } = await request("lights");
      const answer = JSON.stringify(lights);
      if (answer === shown) return;
      shown = answer;
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
      shown = null;
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  let timer = null;
  function start() { if (timer) return; refresh(); timer = setInterval(refresh, 2000); }
  function stop() { clearInterval(timer); timer = null; }
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();
