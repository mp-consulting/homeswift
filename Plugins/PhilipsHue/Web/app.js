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

  // The end of the minute the link button can be pressed in: the bridge's own when it is pairing (from this page, another,
  // or the plugin at start without a key), else the one this page's Pair started. A second's tick redraws it meanwhile.
  let pairingUntil = 0;
  let asking = false;
  let ticker = 0;
  function followPairing() {
    if (status.pairing && status.pairingSecondsLeft != null) pairingUntil = Date.now() + status.pairingSecondsLeft * 1000;
    else if (!status.pairing && !asking) pairingUntil = 0;
    const on = status.pairing || Date.now() < pairingUntil;
    if (on && !ticker) ticker = setInterval(drawBridge, 1000);
    if (!on && ticker) { clearInterval(ticker); ticker = 0; }
  }

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

  /// The address form, made once so the card's redraws leave it open and keep what was typed; until a person types, it
  /// shows the address in config.json, else the bridge's.
  let addressBox = null;
  let addressInput = null;
  let addressTyped = false;
  function addressForm() {
    if (addressBox) {
      if (!addressTyped && document.activeElement !== addressInput) addressInput.value = block.host || status.host || "";
      return addressBox;
    }
    const input = addressInput = el("input", { type: "text", id: "bridge-address", value: block.host || status.host || "", placeholder: "192.168.1.20", inputmode: "url", autocomplete: "off" });
    input.addEventListener("input", () => { addressTyped = true; });
    const found = el("div", { class: "found" });
    return addressBox = el("details", { class: "address-box" },
      el("summary", { text: t("Bridge address") }),
      // The title, then the input with its buttons on one row (so they line up at any width), then the help.
      el("div", { class: "address" },
        el("label", { class: "field-title", htmlFor: "bridge-address", text: t("Address") }),
        el("div", { class: "address-row" }, input,
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          const { hosts } = await request("discover");
          found.replaceChildren(...(hosts.length ? hosts.map((host) => el("button", { actionIcon: "bridge", text: host, onclick: () => { input.value = host; addressTyped = true; } })) : [el("span", { class: "muted", text: t("No bridge answered on the network.") })]));
        }) }),
        el("button", { class: "primary", actionIcon: "check", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
          const host = input.value.trim();
          await updateBlock((draft) => { setKey(draft, "host", host, ""); });
          if (host) await request("host", { method: "POST", body: { host } });
          block = await readBlock();
          addressTyped = false;
          await refresh();
        }) })),
        el("span", { class: "help", text: t("Leave it empty to find the bridge on the network.") })),
      found);
  }

  async function pair(button) {
    pairingUntil = Date.now() + 60000;
    asking = true;
    followPairing();
    drawBridge();
    try {
      await act(button, () => request("pair", { method: "POST", body: {} }), null);
      pairingUntil = 0;
    } catch (e) {
      pairingUntil = 0;
      alert(e.message);
    } finally {
      asking = false;
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

  // MARK: Scene pictures

  // A picture a person gave a scene: dropped on its tile or chosen from its menu, shrunk here to 640 pixels and sent as
  // a JPEG data: URL (the bridge keeps JPEG, PNG and WebP, a megabyte at most). Fetched once per version.
  const pictureCache = new Map();
  async function pictureFor(scene) {
    if (!scene.picture) return null;
    const key = `${scene.id}@${scene.picture}`;
    if (!pictureCache.has(key)) {
      pictureCache.set(key, request(`scene-picture?id=${encodeURIComponent(scene.id)}`).then(({ data }) => data).catch(() => null));
    }
    return pictureCache.get(key);
  }

  async function shrink(file) {
    if (!/^image\//.test(file.type)) throw new Error(t("This file is not a picture."));
    const bitmap = await createImageBitmap(file).catch(() => { throw new Error(t("This file is not a picture.")); });
    const scale = Math.min(1, 640 / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close?.();
    return canvas.toDataURL("image/jpeg", 0.85);
  }

  async function setPicture(scene, file, tileNode) {
    tileNode.classList.add("busy");
    try {
      const data = await shrink(file);
      const { version } = await request("scene-picture", { method: "POST", body: { id: scene.id, data } });
      pictureCache.set(`${scene.id}@${version}`, Promise.resolve(data));
      await refresh();
    } catch (e) {
      alert(e.message);
    } finally {
      tileNode.classList.remove("busy");
    }
  }

  function choosePicture(scene, tileNode) {
    const input = el("input", { type: "file", accept: "image/jpeg,image/png,image/webp,image/heic" });
    input.addEventListener("change", () => { if (input.files?.[0]) setPicture(scene, input.files[0], tileNode); });
    input.click();
  }

  async function removePicture(scene) {
    try { await request("scene-picture-remove", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); }
  }

  /// The tile takes a dropped picture; the page takes none itself, so a picture dropped beside a tile does not open.
  function dropZone(tileNode, scene) {
    tileNode.addEventListener("dragover", (event) => {
      if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      tileNode.classList.add("drop");
    });
    tileNode.addEventListener("dragleave", () => tileNode.classList.remove("drop"));
    tileNode.addEventListener("drop", (event) => {
      event.preventDefault();
      tileNode.classList.remove("drop");
      const file = event.dataTransfer?.files?.[0];
      if (file) setPicture(scene, file, tileNode);
    });
  }
  for (const type of ["dragover", "drop"]) document.addEventListener(type, (event) => { if (event.dataTransfer?.types?.includes("Files")) event.preventDefault(); });

  /// The tile's menu: a picture for it, and whether the Home app shows it.
  function sceneMenu(scene, tileNode, hideKey) {
    const button = HomeswiftCommon.menuButton(t("Actions for {name}", { name: scene.name }), () => [
      { label: scene.picture ? t("Change the picture…") : t("Choose a picture…"), icon: "camera", onSelect: () => choosePicture(scene, tileNode) },
      scene.picture ? { label: t("Remove the picture"), icon: "trash", onSelect: () => removePicture(scene) } : null,
      { label: scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeScenes", hideKey) },
    ]);
    button.classList.add("eye");
    button.addEventListener("click", (event) => event.stopPropagation());
    button.addEventListener("keydown", (event) => event.stopPropagation());
    return button;
  }

  /// Paints the tile with its picture once loaded; the colours stay until then, and when there is none.
  function paintPicture(tileNode, scene) {
    pictureFor(scene).then((data) => {
      if (!data) return;
      tileNode.style.backgroundImage = `url("${data}")`;
      tileNode.classList.add("pictured");
    });
  }

  /// How a tile's name reads best on its palette: "light" (dark text) or "deep" (white on a darker scrim), else white on
  /// the usual scrim. The name spans about 35 to 70 % of the 135° gradient, so the colours there count (stops evenly
  /// spaced, mixed in sRGB as the browser does); white has the scrim under it (about a third black at the name). Each
  /// takes the contrast of its worst colour (WCAG's relative luminance) and the better one wins; when neither reaches
  /// 4.5, the darker scrim does.
  function textStyle(colours) {
    const rgb = colours.map((hex) => /^#([0-9a-f]{6})$/i.exec(hex.trim())).map((match) => match && [0, 2, 4].map((i) => parseInt(match[1].slice(i, i + 2), 16)));
    if (!rgb.length || rgb.includes(null)) return "";
    const at = (t) => {
      if (rgb.length === 1) return rgb[0];
      const position = t * (rgb.length - 1);
      const index = Math.min(Math.floor(position), rgb.length - 2);
      return rgb[index].map((c, i) => c + (rgb[index + 1][i] - c) * (position - index));
    };
    const luminance = (channels) => {
      const [r, g, b] = channels.map((c) => c / 255).map((c) => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    const under = [0.35, 0.5, 0.7].map((t) => luminance(at(t)));
    const white = Math.min(...under.map((l) => 1.05 / (l * 0.46 + 0.05)));
    const dark = Math.min(...under.map((l) => (l + 0.05) / 0.062));
    if (Math.max(white, dark) < 4.5) return "deep";
    return dark > white ? "light" : "";
  }

  function sceneTile(group, scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""} ${textStyle(colours)}`, role: "button", tabindex: 0, style: `background: ${background}`,
      "aria-label": t("Recall {name}", { name: scene.name }), "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      null,
      el("span", { class: "name", text: scene.name }),
      // A smart scene says so, unless its name already does.
      scene.smart && !/natural light/i.test(scene.name) ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const recall = async () => {
      button.classList.add("busy");
      try { await request("recall", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
    };
    button.addEventListener("click", recall);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); recall(); } });
    button.append(sceneMenu(scene, button, `${group.name}/${scene.name}`));
    dropZone(button, scene);
    paintPicture(button, scene);
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

  // The transition as a 12-step speed scale, slowest first; the block keeps its milliseconds (`transitionMs`), a value
  // between steps showing as the nearest. Step 9, 100 ms, is the default.
  const speedSteps = [2000, 1500, 1000, 800, 600, 400, 300, 200, 100, 60, 30, 0];
  const speedNames = [[2, t("Very slow")], [4, t("Slow")], [7, t("Medium")], [9, t("Fast")], [11, t("Very fast")], [12, t("Extreme")]];
  const speedName = (step) => speedNames.find(([last]) => step <= last)[1];
  const stepFor = (ms) => speedSteps.reduce((best, value, index) => Math.abs(value - ms) < Math.abs(speedSteps[best] - ms) ? index : best, 0) + 1;
  const speedText = (step) => {
    const ms = speedSteps[step - 1];
    return ms === 0 ? t("{speed} · at once", { speed: speedName(step) }) : t("{speed} · {ms} ms", { speed: speedName(step), ms });
  };

  function buildSettings() {
    const value = el("output");
    const slider = el("input", { type: "range", class: "speed", id: "transitionMs", min: 1, max: 12, step: 1, "aria-label": t("Transition") });
    const show = () => {
      value.textContent = speedText(Number(slider.value));
      slider.setAttribute("aria-valuetext", value.textContent);
    };
    slider.addEventListener("input", () => { show(); markDirty(); });
    // The names under the scale, each as wide as its steps.
    const scale = el("div", { class: "speed-scale", "aria-hidden": "true" }, speedNames.map(([last, name], index) =>
      el("span", { text: name, style: `grid-column: span ${last - (speedNames[index - 1]?.[0] ?? 0)}` })));
    const polling = el("input", { type: "number", id: "pollingInterval", min: 1, max: 300, step: 1, placeholder: "2", inputmode: "numeric" });
    polling.addEventListener("input", markDirty);
    $("#speed").append(
      el("label", { class: "field" }, el("span", { class: "range-head" }, el("span", { class: "field-title", text: t("Transition") }), value), slider, scale,
        el("span", { class: "help", text: t("How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes.") })),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling interval (s)") }), polling,
        el("span", { class: "help", text: t("How often the bridge is asked for changes made in the Hue app or with a switch.") })));
    $("#options").append(...toggles.map(([id, , label, help]) => {
      const input = el("input", { type: "checkbox", id: `option-${id}` });
      input.addEventListener("change", markDirty);
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: label }), el("span", { class: "help", text: help })));
    }));
    show();
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    $("#transitionMs").value = stepFor(block.transitionMs ?? 100);
    $("#transitionMs").dispatchEvent(new Event("input"));
    dirty = false;
    $("#save-state").textContent = t("Changes are kept once you save.");
    $("#pollingInterval").value = block.pollingInterval ?? "";
    for (const [id, fallback] of toggles) $(`#option-${id}`).checked = block[id] ?? fallback;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speedSteps[Number($("#transitionMs").value) - 1], 100);
      const polling = parseInt($("#pollingInterval").value, 10);
      setKey(draft, "pollingInterval", Number.isNaN(polling) ? undefined : Math.min(Math.max(polling, 1), 300), 2);
      for (const [id, fallback] of toggles) setKey(draft, id, $(`#option-${id}`).checked, fallback);
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
    followPairing();
    drawBridge();
    drawLights();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); drawBridge(); }).catch(() => {});
  poll(refresh, 2000);
})();
