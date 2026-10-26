// The IKEA DIRIGERA page: the hubs (from config.json and found on the network), each paired with its action button;
// the lights, outlets and sensors as the Accessories page draws them (its widgets); the hubs' scenes as tiles (a tap
// runs one, the eye leaves it out of the Home app); and the settings. Refreshed every two seconds while visible;
// saving writes this instance's block.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let hubs = [];
  let devices = [];
  let scenes = [];
  let found = [];
  let block = {};
  // The end of each hub's minute to press its action button, by host: the hub's own while it pairs (this page or another
  // started it), else the one this page's Pair started. A second's tick redraws the rows meanwhile.
  const pairing = new Map();
  const asking = new Set();
  let ticker = 0;
  function followPairing() {
    for (const hub of hubs) {
      if (hub.pairing && hub.pairingSecondsLeft != null) pairing.set(hub.host, Date.now() + hub.pairingSecondsLeft * 1000);
      else if (!hub.pairing && !asking.has(hub.host)) pairing.delete(hub.host);
    }
    const on = hubs.some((hub) => hub.pairing) || [...pairing.values()].some((until) => Date.now() < until);
    if (on && !ticker) ticker = setInterval(drawHubs, 1000);
    if (!on && ticker) { clearInterval(ticker); ticker = 0; }
  }

  // MARK: Tabs

  for (const button of document.querySelectorAll(".main-tabs [data-tab]")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs [data-tab]")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
      try { localStorage.setItem("dirigera-tab", button.dataset.tab); } catch {}
    });
  }
  try {
    const saved = localStorage.getItem("dirigera-tab");
    if (saved) document.querySelector(`.main-tabs [data-tab="${saved}"]`)?.click();
  } catch {}

  // MARK: Hubs

  function hubRow(hub) {
    const until = pairing.get(hub.host) ?? 0;
    const waiting = Date.now() < until || hub.pairing;
    const [state, kind] = waiting ? [t("Pairing…"), "standby"] : !hub.paired ? [t("Not paired"), "away"]
      : hub.error ? [t("Not responding"), "away"] : hub.connected ? [t("Connected"), "on"] : [t("Connecting…"), "standby"];
    const seconds = Math.max(0, Math.ceil((until - Date.now()) / 1000));
    const actions = [
      hub.paired ? { label: t("Pair again"), icon: "key", onSelect: () => pair(null, hub.host) } : null,
      hub.inConfig ? { label: t("Remove from config.json"), icon: "trash", danger: true, onSelect: () => removeHub(hub.host) } : null,
    ].filter(Boolean);
    return el("div", { class: "hub" },
      el("div", { class: "hub-row" },
        tile("bridge", hub.paired && !hub.error ? "blue" : "grey"),
        el("div", { class: "who" }, el("strong", { text: hub.name || t("DIRIGERA hub") }),
          el("div", { class: "muted", text: hub.paired ? [hub.host, tn("{n} device", "{n} devices", hub.devices), tn("{n} scene", "{n} scenes", hub.scenes)].join(" · ") : hub.host })),
        el("span", { class: `pill status ${kind}`, text: state }),
        hub.paired || waiting ? null : el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget, hub.host) }),
        // The ⋯ menu only when it has something: a hub found on the network and pairing for the first time has nothing.
        actions.length ? HomeswiftCommon.menuButton(t("Actions for {name}", { name: hub.name || hub.host }), () => actions) : null),
      waiting ? el("div", { class: "pair-steps pairing" },
        el("span", { class: "link-button", "aria-hidden": "true" }, icon("power")),
        el("div", {},
          el("p", {}, el("strong", { text: t("Press the action button under the hub.") })),
          el("p", { class: "muted", text: t("Waiting for the button… {seconds} s left.", { seconds }) }))) : null,
      hub.error && hub.paired ? explain({
        error: `The DIRIGERA hub at ${hub.host} did not answer: ${hub.error}`,
        context: "The Homeswift DIRIGERA plugin reads GET https://<hub>:8443/v1/devices and /v1/scenes with its token, and follows the hub's websocket for changes.",
        device: { host: hub.host },
      }) : null);
  }

  const hubList = el("div");
  const foundList = el("div", { class: "found" });
  const addressInput = el("input", { type: "text", id: "hub-address", placeholder: "192.168.1.30", inputmode: "url", autocomplete: "off" });
  $("#hubs").append(hubList, foundList,
    el("details", { class: "address-box" },
      el("summary", { text: t("Add a hub") }),
      // The title, then the input with its buttons on one row, so they line up at any width.
      el("div", { class: "address" },
        el("label", { class: "field-title", htmlFor: "hub-address", text: t("Address") }),
        el("div", { class: "address-row" }, addressInput,
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          ({ hosts: found } = await request("discover"));
          if (!found.length) alert(t("No hub answered on the network."));
          drawHubs();
        }) }),
        el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => { const host = addressInput.value.trim(); if (host) pair(event.currentTarget, host); } })))));

  /// The hub rows, and the hubs found on the network that are not paired yet; the address form stays as typed.
  function drawHubs() {
    const known = new Set(hubs.map((hub) => hub.host));
    const extra = found.filter((host) => !known.has(host));
    hubList.replaceChildren(...(hubs.length ? hubs.map(hubRow) : [el("p", { class: "muted", text: t("No hub yet. Find one on the network or type its address.") })]));
    foundList.replaceChildren(...extra.map((host) => el("button", { actionIcon: "key", text: t("Pair {host}", { host }), onclick: (event) => pair(event.currentTarget, host) })));
  }

  async function pair(button, host) {
    pairing.set(host, Date.now() + 60000);
    asking.add(host);
    followPairing();
    drawHubs();
    try {
      await request("pair", { method: "POST", body: { host } });
      // The hub goes in config.json, as homebridge-dirigera keeps it; its token stays in the plugin's folder.
      await updateBlock((draft) => {
        const list = draft.hubs || [];
        if (!list.some((hub) => hub.host === host)) list.push({ host });
        draft.hubs = list;
      });
      block = await readBlock();
    } catch (e) {
      alert(e.message);
    } finally {
      pairing.delete(host);
      asking.delete(host);
      await refresh();
    }
  }

  async function removeHub(host) {
    if (!confirm(t("Remove the hub at {host} from config.json?", { host }))) return;
    await request("unpair", { method: "POST", body: { host } }).catch(() => {});
    await updateBlock((draft) => {
      const list = (draft.hubs || []).filter((hub) => hub.host !== host);
      if (list.length) draft.hubs = list; else delete draft.hubs;
    }).catch((e) => alert(e.message));
    block = await readBlock();
    await refresh();
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's accessories (not its scene switches), read again when the set of devices changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "Dirigera" && accessory.platformName === homeswift.name && !accessory.id.startsWith("Dirigera:scenes:"));
  }

  let listening = false;
  async function drawDevices() {
    const list = $("#devices");
    const hidden = $("#hidden-devices");
    if (!hubs.some((hub) => hub.paired)) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair a hub to see its lights and outlets.") })));
      hidden.replaceChildren();
      return;
    }
    const key = devices.filter((item) => !item.hidden).map((item) => item.id).sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      await loadAccessories().catch(() => {});
    }
    if (!accessories.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The hub has no lights or outlets yet: add them in the IKEA Home smart app.") })));
    } else {
      if (list.querySelector(".card.empty")) list.replaceChildren();
      // A widget per accessory, drawn once: its values follow the bridge's event stream.
      renderKeyed(list, accessories.map((accessory) => ({ id: accessory.id, name: accessory.name, services: accessory.services.length })), (item) => item.id,
        (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { size: "large", actions: actionsFor }));
      if (!listening) { HomeswiftWidgets.listen(); listening = true; }
    }
    const left = devices.filter((item) => item.hidden);
    hidden.replaceChildren(...(left.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...left.map((item) => el("button", { actionIcon: "eye", text: item.name, title: t("Show in the Home app"), onclick: () => toggleList("excludeDevices", item.name) }))] : []));
  }

  /// The widget's ⋯ menu, after All controls: what this page adds.
  function actionsFor(accessory) {
    const id = accessory.id.slice("Dirigera:".length);
    const item = devices.find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { host: item?.host, id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeDevices", item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  }

  // MARK: Scenes

  // The hub's scene icons, as line drawings; others take the generic one.
  const glyphs = {
    tv: '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
    book: '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/><path d="M4 19V5"/>',
    party: '<path d="M4 20l5-14 9 9z"/><path d="M14 4l1 2M19 7l2-1M18 3l-1 2"/>',
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/>',
    off: '<path d="M12 3v9M6.3 5.8a8 8 0 1 0 11.4 0"/>',
  };
  const tones = ["#0058a3, #3d8bd8", "#f2b705, #ffd85c", "#5b4fd6, #9a8cff", "#0a7a5a, #36c08f", "#c2410c, #f59e5b", "#334155, #64748b"];
  function sceneStyle(scene) {
    const name = (scene.icon || "").replace(/^scenes_/, "");
    const key = Object.keys(glyphs).find((k) => name.includes(k) || (k === "moon" && /night|sleep/.test(name)) || (k === "sun" && /morning|wake|bright/.test(name))
      || (k === "off" && /off|away|leave/.test(name)) || (k === "book" && /read/.test(name)) || (k === "party" && /party|dinner|cozy/.test(name)));
    let hash = 0;
    for (const c of scene.name) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
    const tone = tones[hash % tones.length];
    return { glyph: glyphs[key ?? "home"], gradient: `linear-gradient(135deg, ${tone})`, text: textStyle(tone.split(",")) };
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

  function sceneTile(scene) {
    const { glyph, gradient, text } = sceneStyle(scene);
    const art = document.createElement("span");
    art.className = "glyph";
    art.innerHTML = `<svg viewBox="0 0 24 24">${glyph}</svg>`;
    const tileNode = el("div", { class: `scene ${scene.hidden ? "hidden-scene" : ""} ${text}`, role: "button", tabindex: 0, style: `background: ${gradient}`, "aria-label": t("Run {name}", { name: scene.name }) },
      art,
      null,
      el("span", { class: "name", text: scene.name }));
    const run = async () => {
      tileNode.classList.add("busy");
      try {
        await request("trigger", { method: "POST", body: { host: scene.host, id: scene.id } });
        tileNode.classList.remove("fired");
        void tileNode.offsetWidth;
        tileNode.classList.add("fired");
      } catch (e) { alert(e.message); } finally { tileNode.classList.remove("busy"); }
    };
    tileNode.addEventListener("click", run);
    tileNode.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); run(); } });
    tileNode.append(sceneMenu(scene, tileNode, scene.name));
    dropZone(tileNode, scene);
    paintPicture(tileNode, scene);
    return tileNode;
  }

  function drawScenes() {
    const list = $("#scenes");
    if (!scenes.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: hubs.some((hub) => hub.paired) ? t("No scenes yet: make some in the IKEA Home smart app.") : t("Pair a hub to see its scenes.") })));
      return;
    }
    renderKeyed(list, scenes, (scene) => `${scene.host}/${scene.id}`, sceneTile);
  }

  // MARK: Settings

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
    $("#speed").append(
      el("label", { class: "field" }, el("span", { class: "range-head" }, el("span", { class: "field-title", text: t("Transition") }), value), slider, scale,
        el("span", { class: "help", text: t("How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods.") })));
    const input = el("input", { type: "checkbox", id: "scenes-toggle" });
    input.addEventListener("change", markDirty);
    $("#options").append(el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: t("Scenes") }), el("span", { class: "help", text: t("A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.") }))));
    show();
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    $("#transitionMs").value = stepFor(block.transitionMs ?? 100);
    $("#transitionMs").dispatchEvent(new Event("input"));
    dirty = false;
    $("#save-state").textContent = t("Changes are kept once you save.");
    $("#scenes-toggle").checked = block.scenes ?? true;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speedSteps[Number($("#transitionMs").value) - 1], 100);
      setKey(draft, "scenes", $("#scenes-toggle").checked, true);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

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
      ({ hubs } = await request("hubs"));
      if (hubs.some((hub) => hub.paired)) {
        [{ devices }, { scenes }] = await Promise.all([request("devices"), request("scenes")]);
      } else {
        devices = [];
        scenes = [];
      }
    } catch (e) {
      hubs = [];
    }
    followPairing();
    drawHubs();
    drawDevices();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); }).catch(() => {});
  poll(refresh, 2000);
  // Hubs announce themselves: look once when the page opens.
  request("discover").then(({ hosts }) => { found = hosts; drawHubs(); }).catch(() => {});
})();
