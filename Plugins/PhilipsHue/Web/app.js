// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the
// lights as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the
// scenes of each room as tiles painted with their palette (a tap recalls one, the eye leaves it out of the Home app),
// and the settings: the transition and what the Home app shows. Refreshed every two seconds while visible; saving
// writes this instance's block.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let groups = [];
  let block = {};

  // MARK: Tabs

  for (const button of document.querySelectorAll(".main-tabs [data-tab]")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs [data-tab]")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
      try { localStorage.setItem("hue-tab", button.dataset.tab); } catch {}
    });
  }
  try {
    const saved = localStorage.getItem("hue-tab");
    if (saved) document.querySelector(`.main-tabs [data-tab="${saved}"]`)?.click();
  } catch {}

  // MARK: The bridge

  let pairingUntil = 0;
  function drawBridge() {
    const card = $("#bridge");
    const paired = status.paired;
    const pairing = status.pairing || Date.now() < pairingUntil;
    const [state, kind] = !status.host ? [t("Not found"), "away"] : !paired ? [pairing ? t("Pairing…") : t("Not paired"), pairing ? "standby" : "away"]
      : status.error ? [t("Not responding"), "away"] : [t("Connected"), "on"];
    const facts = paired && status.host
      ? el("div", { class: "facts" },
        homeswift.fact(t("Address"), status.host), homeswift.fact(t("Lights"), String(status.lights ?? 0)), homeswift.fact(t("Scenes"), String(status.scenes ?? 0)))
      : null;
    const seconds = Math.max(0, Math.ceil((pairingUntil - Date.now()) / 1000));
    const pairBox = status.host && !paired ? el("div", { class: `pair-steps ${pairing ? "pairing" : ""}` },
      el("span", { class: "link-button", "aria-hidden": "true" }, linkGlyph()),
      el("div", {},
        el("p", {}, el("strong", { text: pairing ? t("Press the round link button on top of the bridge.") : t("Pair Homeswift with the bridge.") })),
        el("p", { class: "muted", text: pairing ? t("Waiting for the button… {seconds} s left.", { seconds }) : t("Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.") }),
        pairing ? null : el("div", { class: "actions" }, el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget) })))) : null;
    card.replaceChildren(...[
      el("div", { class: "server-head" },
        tile("bridge", paired && !status.error ? "violet" : "grey"),
        el("div", { class: "who" }, el("strong", { text: t("Hue Bridge") }), el("div", { class: "muted", text: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") || t("Looking on the network…") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      facts, pairBox,
      status.error && paired ? explain({
        error: `The Hue Bridge at ${status.host} did not answer: ${status.error}`,
        context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
        device: { host: status.host },
      }) : null,
      addressForm()].filter(Boolean));
  }

  function linkGlyph() {
    const span = document.createElement("span");
    span.innerHTML = '<svg viewBox="0 0 24 24"><path d="M9.5 14.5l5-5M8 11l-2 2a3.5 3.5 0 0 0 5 5l2-2M16 13l2-2a3.5 3.5 0 0 0-5-5l-2 2"/></svg>';
    return span.firstChild;
  }

  function addressForm() {
    const input = el("input", { type: "text", value: block.host || status.host || "", placeholder: "192.168.1.20", inputmode: "url", autocomplete: "off" });
    const found = el("div", { class: "found" });
    return el("details", { class: "address-box" },
      el("summary", { text: t("Bridge address") }),
      el("div", { class: "address" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Address") }), input,
          el("span", { class: "help", text: t("Leave it empty to find the bridge on the network.") })),
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          const { hosts } = await request("discover");
          found.replaceChildren(...(hosts.length ? hosts.map((host) => el("button", { text: host, onclick: () => { input.value = host; } })) : [el("span", { class: "muted", text: t("No bridge answered on the network.") })]));
        }) }),
        el("button", { class: "primary", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
          const host = input.value.trim();
          await updateBlock((draft) => { setKey(draft, "host", host, ""); });
          if (host) await request("host", { method: "POST", body: { host } });
          await refresh();
        }) })),
      found);
  }

  async function pair(button) {
    pairingUntil = Date.now() + 60000;
    drawBridge();
    const timer = setInterval(drawBridge, 1000);
    try {
      await act(button, () => request("pair", { method: "POST", body: {} }), null);
      pairingUntil = 0;
    } catch (e) {
      pairingUntil = 0;
      alert(e.message);
    } finally {
      clearInterval(timer);
      await refresh();
    }
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's accessories (not its scene switches), read again when the set of lights changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "PhilipsHue" && accessory.platformName === homeswift.name && !accessory.id.startsWith("PhilipsHue:scenes:"));
  }

  let listening = false;
  async function drawLights() {
    const list = $("#lights");
    const hidden = $("#hidden-devices");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its lights.") })));
      hidden.replaceChildren();
      return;
    }
    const key = lights.filter((item) => !item.hidden).map((item) => item.id).sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      await loadAccessories().catch(() => {});
    }
    if (!accessories.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The bridge has no lights yet: add them in the Hue app.") })));
    } else {
      if (list.querySelector(".card.empty")) list.replaceChildren();
      // A widget per accessory, drawn once: its values follow the bridge's event stream.
      renderKeyed(list, accessories.map((accessory) => ({ id: accessory.id, name: accessory.name, services: accessory.services.length })), (item) => item.id,
        (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { size: "large", actions: actionsFor }));
      if (!listening) { HomeswiftWidgets.listen(); listening = true; }
    }
    const left = lights.filter((item) => item.hidden);
    hidden.replaceChildren(...(left.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...left.map((item) => el("button", { actionIcon: "eye", text: item.name, title: t("Show in the Home app"), onclick: () => toggleList("excludeLights", item.name) }))] : []));
  }

  /// The widget's ⋯ menu, after All controls: what this page adds.
  function actionsFor(accessory) {
    const id = accessory.id.slice("PhilipsHue:".length);
    const item = lights.find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeLights", item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  }

  // MARK: Scenes

  function sceneTile(group, scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""}`, role: "button", tabindex: 0, style: `background: ${background}`,
      "aria-label": t("Recall {name}", { name: scene.name }), "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      el("button", {
        type: "button", class: "eye", title: scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        "aria-label": scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        onclick: (event) => { event.stopPropagation(); toggleList("excludeScenes", `${group.name}/${scene.name}`); },
      }, icon("eye")),
      el("span", { class: "name", text: scene.name }),
      scene.smart ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const recall = async () => {
      button.classList.add("busy");
      try { await request("recall", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
    };
    button.addEventListener("click", recall);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); recall(); } });
    return button;
  }

  function drawScenes() {
    const list = $("#scenes");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its scenes.") })));
      return;
    }
    if (!groups.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No scenes yet: make some in the Hue app.") })));
      return;
    }
    renderKeyed(list, groups, (group) => group.id, (group) => el("section", { class: "room" },
      el("div", { class: "room-head" },
        el("h2", { text: group.name }),
        el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) })),
      el("div", { class: "scene-grid" }, group.scenes.map((scene) => sceneTile(group, scene)))));
  }

  // MARK: Settings

  const toggles = [
    ["scenes", true, t("Scenes"), t("A switch for each scene, on one accessory per room or zone. Off switches the room off.")],
    ["dynamicScenes", false, t("Play scenes dynamically"), t("Recall scenes with their colours slowly moving, as the Hue app's play button does.")],
    ["effects", true, t("Effects"), t("A switch for each effect a light has: candle, fireplace, sparkle, prism…")],
    ["flashSwitch", false, t("Flash switch"), t("A switch on each light that makes it flash for five seconds.")],
    ["gradientPoints", false, t("Gradient points"), t("On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.")],
  ];

  let dirty = false;
  const markDirty = () => { dirty = true; $("#save-state").textContent = t("Unsaved changes."); };

  function buildSettings() {
    const value = el("output");
    const slider = el("input", { type: "range", id: "transitionMs", min: 0, max: 2000, step: 50, "aria-label": t("Transition") });
    const show = () => { value.textContent = Number(slider.value) === 0 ? t("Instant") : `${slider.value} ms`; };
    slider.addEventListener("input", () => { show(); markDirty(); });
    const presets = [[0, t("Instant: flashes and fast moods")], [100, t("Quick (default)")], [400, t("Soft, as the Hue app")]].map(([ms, label]) =>
      el("button", { type: "button", text: label, onclick: () => { slider.value = ms; show(); markDirty(); } }));
    const polling = el("input", { type: "number", id: "pollingInterval", min: 1, max: 300, step: 1, placeholder: "2", inputmode: "numeric" });
    polling.addEventListener("input", markDirty);
    $("#speed").append(
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Transition") }), el("div", { class: "range" }, slider, value),
        el("span", { class: "help", text: t("How long a light takes to reach a new colour or brightness. Shorter is snappier for moods and flashes.") })),
      el("div", { class: "presets" }, presets),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling interval (s)") }), polling,
        el("span", { class: "help", text: t("How often the bridge is asked for changes made in the Hue app or with a switch.") })));
    $("#options").append(...toggles.map(([id, , label, help]) => {
      const input = el("input", { type: "checkbox", id });
      input.addEventListener("change", markDirty);
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: label }), el("span", { class: "help", text: help })));
    }));
    show.call();
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    $("#transitionMs").value = block.transitionMs ?? 100;
    $("#transitionMs").dispatchEvent(new Event("input"));
    dirty = false;
    $("#save-state").textContent = t("Changes are kept once you save.");
    $("#pollingInterval").value = block.pollingInterval ?? "";
    for (const [id, fallback] of toggles) $(`#${id}`).checked = block[id] ?? fallback;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", Number($("#transitionMs").value), 100);
      const polling = parseInt($("#pollingInterval").value, 10);
      setKey(draft, "pollingInterval", Number.isNaN(polling) ? undefined : Math.min(Math.max(polling, 1), 300), 2);
      for (const [id, fallback] of toggles) setKey(draft, id, $(`#${id}`).checked, fallback);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeLights`, `excludeScenes`) and saves at once.
  async function toggleList(key, name) {
    try {
      await updateBlock((draft) => {
        const list = draft[key] || [];
        const index = list.findIndex((item) => item.toLowerCase() === name.toLowerCase());
        if (index >= 0) list.splice(index, 1); else list.push(name);
        if (list.length) draft[key] = list; else delete draft[key];
      });
      block = await readBlock();
      setTimeout(refresh, 1500);
    } catch (e) {
      alert(e.message);
    }
  }

  // MARK: Refresh

  async function refresh() {
    try {
      status = await request("status");
      if (status.paired) {
        [{ lights }, { groups }] = await Promise.all([request("lights"), request("scenes")]);
      } else {
        lights = [];
        groups = [];
      }
    } catch (e) {
      status = { error: e.message };
    }
    drawBridge();
    drawLights();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); drawBridge(); }).catch(() => {});
  poll(refresh, 2000);
})();
