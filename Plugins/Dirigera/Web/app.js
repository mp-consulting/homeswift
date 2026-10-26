// The IKEA DIRIGERA page: the hubs (from config.json and found on the network), each paired with its action button;
// the lights, outlets and sensors as the Accessories page draws them (its widgets); the hubs' scenes as tiles (a tap
// runs one, the eye leaves it out of the Home app); and the settings. Refreshed every two seconds while visible;
// saving writes this instance's block. The tabs, scene pictures, speed scale and tile text come from plugin.js.
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

  homeswift.tabs("dirigera-tab");

  // MARK: Hubs

  /// The countdown texts of the hubs waiting for their button, by host: the second's tick updates them.
  const countdowns = new Map();

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
      waiting ? el("div", { class: "pair-prompt pairing" },
        el("span", { class: "link-button", "aria-hidden": "true" }, icon("power")),
        el("div", {},
          el("p", {}, el("strong", { text: t("Press the action button under the hub.") })),
          countdown(hub.host, seconds))) : null,
      hub.error && hub.paired ? explain({
        error: `The DIRIGERA hub at ${hub.host} did not answer: ${hub.error}`,
        context: "The Homeswift DIRIGERA plugin reads GET https://<hub>:8443/v1/devices and /v1/scenes with its token, and follows the hub's websocket for changes.",
        device: { host: hub.host },
      }) : null);
  }

  function countdown(host, seconds) {
    const text = el("p", { class: "muted", text: t("Waiting for the button… {seconds} s left.", { seconds }) });
    countdowns.set(host, text);
    return text;
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

  /// The hub rows, and the hubs found on the network that are not paired yet; the address form stays as typed. They
  /// are drawn again only when what they show changed; while a hub pairs, the second's tick only counts down.
  let hubsKey = "";
  function drawHubs() {
    const known = new Set(hubs.map((hub) => hub.host));
    const extra = found.filter((host) => !known.has(host));
    const now = Date.now();
    const key = JSON.stringify([hubs.map((hub) => ({ ...hub, pairingSecondsLeft: null, waiting: now < (pairing.get(hub.host) ?? 0) })), extra]);
    if (key === hubsKey) {
      for (const [host, text] of countdowns) {
        const seconds = Math.max(0, Math.ceil(((pairing.get(host) ?? 0) - now) / 1000));
        text.textContent = t("Waiting for the button… {seconds} s left.", { seconds });
      }
      return;
    }
    hubsKey = key;
    countdowns.clear();
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

  /// The devices left out of the Home app, as buttons that bring one back; drawn again only when they change.
  function drawHidden(names) {
    const hidden = $("#hidden-devices");
    const key = JSON.stringify(names);
    if (hidden.dataset.json === key) return;
    hidden.dataset.json = key;
    hidden.replaceChildren(...(names.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...names.map((name) => el("button", { actionIcon: "eye", text: name, title: t("Show in the Home app"), onclick: () => toggleList("excludeDevices", name) }))] : []));
  }

  let listening = false;
  async function drawDevices() {
    const list = $("#devices");
    if (!hubs.some((hub) => hub.paired)) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair a hub to see its lights and outlets.") })));
      drawHidden([]);
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
    drawHidden(devices.filter((item) => item.hidden).map((item) => item.name));
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
    return { glyph: glyphs[key ?? "home"], gradient: `linear-gradient(135deg, ${tone})`, text: homeswift.textStyle(tone.split(",")) };
  }

  // A scene's picture: dropped on its tile or chosen from its menu (plugin.js); its ⋯ menu also leaves it out of the
  // Home app, by name.
  const pictures = homeswift.scenePictures({ refresh: () => refresh(), toggleHidden: (name) => toggleList("excludeScenes", name) });

  function sceneTile(scene) {
    const { glyph, gradient, text } = sceneStyle(scene);
    const art = document.createElement("span");
    art.className = "glyph";
    art.innerHTML = `<svg viewBox="0 0 24 24">${glyph}</svg>`;
    const tileNode = el("div", { class: `scene ${scene.hidden ? "hidden-scene" : ""} ${text}`, role: "button", tabindex: 0, style: `background: ${gradient}`, "aria-label": t("Run {name}", { name: scene.name }) },
      art,
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
    return pictures.decorate(tileNode, scene, scene.name);
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

  const speed = homeswift.speedScale({
    help: t("How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods."),
    onInput: markDirty,
  });
  const scenesToggle = el("input", { type: "checkbox", id: "scenes-toggle" });

  function buildSettings() {
    $("#speed").append(speed.element);
    scenesToggle.addEventListener("change", markDirty);
    $("#options").append(el("label", { class: "toggle" }, el("span", { class: "switch" }, scenesToggle, el("span")),
      el("span", {}, el("span", { class: "field-title", text: t("Scenes") }), el("span", { class: "help", text: t("A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.") }))));
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    speed.set(block.transitionMs);
    $("#save-state").textContent = t("Changes are kept once you save.");
    scenesToggle.checked = block.scenes ?? true;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speed.value(), 100);
      setKey(draft, "scenes", scenesToggle.checked, true);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeDevices`, `excludeScenes`), saved at once.
  async function toggleList(key, name) {
    const written = await homeswift.toggleList(key, name);
    if (!written) return;
    block = written;
    setTimeout(refresh, 1500);
  }

  // MARK: Refresh

  /// The hubs and the lists together; the lists count only once a hub is paired.
  async function refresh() {
    const settle = (promise) => promise.then((value) => ({ value }), (error) => ({ error }));
    try {
      const [answer, deviceList, sceneList] = await Promise.all([request("hubs"), settle(request("devices")), settle(request("scenes"))]);
      if (answer.hubs.some((hub) => hub.paired)) {
        const failed = deviceList.error ?? sceneList.error;
        if (failed) throw failed;
        ({ devices } = deviceList.value);
        ({ scenes } = sceneList.value);
      } else {
        devices = [];
        scenes = [];
      }
      ({ hubs } = answer);
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
