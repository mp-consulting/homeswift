// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the
// lights as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the
// scenes of each room as tiles painted with their palette (a tap recalls one, the eye leaves it out of the Home app),
// and the settings: the transition and what the Home app shows. Refreshed every two seconds while visible; saving
// writes this instance's block. The tabs, scene pictures, speed scale and tile text come from plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let groups = [];
  let block = {};

  homeswift.tabs("hue-tab");

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

  /// The address form, made once and kept at the end of the card, so it stays open and keeps what was typed; until a
  /// person types, it shows the address in config.json, else the bridge's.
  let addressTyped = false;
  const addressInput = el("input", { type: "text", id: "bridge-address", placeholder: "192.168.1.20", inputmode: "url", autocomplete: "off" });
  addressInput.addEventListener("input", () => { addressTyped = true; });
  const foundList = el("div", { class: "found" });
  const addressBox = el("details", { class: "address-box" },
    el("summary", { text: t("Bridge address") }),
    // The title, then the input with its buttons on one row (so they line up at any width), then the help.
    el("div", { class: "address" },
      el("label", { class: "field-title", htmlFor: "bridge-address", text: t("Address") }),
      el("div", { class: "address-row" }, addressInput,
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          const { hosts } = await request("discover");
          foundList.replaceChildren(...(hosts.length ? hosts.map((host) => el("button", { actionIcon: "bridge", text: host, onclick: () => { addressInput.value = host; addressTyped = true; } })) : [el("span", { class: "muted", text: t("No bridge answered on the network.") })]));
        }) }),
        el("button", { class: "primary", actionIcon: "check", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
          const host = addressInput.value.trim();
          await updateBlock((draft) => { setKey(draft, "host", host, ""); });
          if (host) await request("host", { method: "POST", body: { host } });
          block = await readBlock();
          addressTyped = false;
          await refresh();
        }) })),
      el("span", { class: "help", text: t("Leave it empty to find the bridge on the network.") })),
    foundList);
  $("#bridge").append(addressBox);

  /// The card above the address form, drawn again only when what it shows changed; while pairing, the second's tick
  /// only counts down.
  let bridgeKey = "";
  let countdown = null;
  function drawBridge() {
    if (!addressTyped && document.activeElement !== addressInput) addressInput.value = block.host || status.host || "";
    const paired = status.paired;
    const pairing = status.pairing || Date.now() < pairingUntil;
    const seconds = Math.max(0, Math.ceil((pairingUntil - Date.now()) / 1000));
    const waiting = () => t("Waiting for the button… {seconds} s left.", { seconds });
    const key = JSON.stringify([{ ...status, pairingSecondsLeft: null }, pairing]);
    if (key === bridgeKey) {
      if (countdown) countdown.textContent = waiting();
      return;
    }
    bridgeKey = key;
    const [state, kind] = !status.host ? [t("Not found"), "away"] : !paired ? [pairing ? t("Pairing…") : t("Not paired"), pairing ? "standby" : "away"]
      : status.error ? [t("Not responding"), "away"] : [t("Connected"), "on"];
    const facts = paired && status.host
      ? el("div", { class: "facts" },
        homeswift.fact(t("Address"), status.host), homeswift.fact(t("Lights"), String(status.lights ?? 0)), homeswift.fact(t("Scenes"), String(status.scenes ?? 0)))
      : null;
    const note = el("p", { class: "muted", text: pairing ? waiting() : t("Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.") });
    countdown = pairing ? note : null;
    const pairBox = status.host && !paired ? el("div", { class: `pair-prompt ${pairing ? "pairing" : ""}` },
      el("span", { class: "link-button", "aria-hidden": "true" }, icon("link")),
      el("div", {},
        el("p", {}, el("strong", { text: pairing ? t("Press the round link button on top of the bridge.") : t("Pair Homeswift with the bridge.") })),
        note,
        pairing ? null : el("div", { class: "actions" }, el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget) })))) : null;
    const card = $("#bridge");
    for (const node of [...card.children]) if (node !== addressBox) node.remove();
    addressBox.before(...[
      el("div", { class: "server-head" },
        tile("bridge", paired && !status.error ? "violet" : "grey"),
        el("div", { class: "who" }, el("strong", { text: t("Hue Bridge") }), el("div", { class: "muted", text: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") || t("Looking on the network…") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      facts, pairBox,
      status.error && paired ? explain({
        error: `The Hue Bridge at ${status.host} did not answer: ${status.error}`,
        context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
        device: { host: status.host },
      }) : null].filter(Boolean));
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

  /// The lights left out of the Home app, as buttons that bring one back; drawn again only when they change.
  function drawHidden(names) {
    const hidden = $("#hidden-devices");
    const key = JSON.stringify(names);
    if (hidden.dataset.json === key) return;
    hidden.dataset.json = key;
    hidden.replaceChildren(...(names.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...names.map((name) => el("button", { actionIcon: "eye", text: name, title: t("Show in the Home app"), onclick: () => toggleList("excludeLights", name) }))] : []));
  }

  let listening = false;
  async function drawLights() {
    const list = $("#lights");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its lights.") })));
      drawHidden([]);
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
    drawHidden(lights.filter((item) => item.hidden).map((item) => item.name));
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

  // A scene's picture: dropped on its tile or chosen from its menu (plugin.js); its ⋯ menu also leaves it out of the
  // Home app, by "<room>/<scene>".
  const pictures = homeswift.scenePictures({ refresh: () => refresh(), toggleHidden: (key) => toggleList("excludeScenes", key) });

  function sceneTile(scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""} ${homeswift.textStyle(colours)}`, role: "button", tabindex: 0, style: `background: ${background}`,
      "aria-label": t("Recall {name}", { name: scene.name }), "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      el("span", { class: "name", text: scene.name }),
      // A smart scene says so, unless its name already does.
      scene.smart && !/natural light/i.test(scene.name) ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const recall = async () => {
      button.classList.add("busy");
      try { await request("recall", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
    };
    button.addEventListener("click", recall);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); recall(); } });
    return pictures.decorate(button, scene, `${scene.room}/${scene.name}`);
  }

  /// A section per room, its head drawn again when the room changes and a tile per scene drawn again only when its own
  /// scene changes, so a recall does not repaint every picture of the room.
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
    renderKeyed(list, groups.map((group) => ({ id: group.id })), (group) => group.id,
      () => el("section", { class: "room" }, el("div", { class: "room-head" }), el("div", { class: "scene-tiles" })));
    groups.forEach((group, index) => {
      const [head, tiles] = list.children[index].children;
      const headKey = JSON.stringify([group.name, group.kind, group.on]);
      if (head.dataset.json !== headKey) {
        head.dataset.json = headKey;
        head.replaceChildren(el("h2", { text: group.name }),
          el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) }));
      }
      renderKeyed(tiles, group.scenes.map((scene) => ({ ...scene, room: group.name })), (scene) => scene.id, sceneTile);
    });
  }

  // MARK: Settings

  const toggles = [
    ["scenes", true, t("Scenes"), t("A switch for each scene, on one accessory per room or zone. Off switches the room off.")],
    ["dynamicScenes", false, t("Play scenes dynamically"), t("Recall scenes with their colours slowly moving, as the Hue app's play button does.")],
    ["effects", true, t("Effects"), t("A switch for each effect a light has: candle, fireplace, sparkle, prism…")],
    ["flashSwitch", false, t("Flash switch"), t("A switch on each light that makes it flash for five seconds.")],
    ["gradientPoints", false, t("Gradient points"), t("On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.")],
  ];
  /// The toggles' checkboxes, by key.
  const toggleInputs = new Map();

  let dirty = false;
  const markDirty = () => { dirty = true; $("#save-state").textContent = t("Unsaved changes."); };

  const speed = homeswift.speedScale({
    help: t("How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes."),
    onInput: markDirty,
  });
  const polling = el("input", { type: "number", id: "pollingInterval", min: 1, max: 300, step: 1, placeholder: "2", inputmode: "numeric" });

  function buildSettings() {
    polling.addEventListener("input", markDirty);
    $("#speed").append(speed.element,
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling interval (s)") }), polling,
        el("span", { class: "help", text: t("How often the bridge is asked for changes made in the Hue app or with a switch.") })));
    $("#options").append(...toggles.map(([id, , label, help]) => {
      const input = el("input", { type: "checkbox", id: `option-${id}` });
      input.addEventListener("change", markDirty);
      toggleInputs.set(id, input);
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: label }), el("span", { class: "help", text: help })));
    }));
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    speed.set(block.transitionMs);
    $("#save-state").textContent = t("Changes are kept once you save.");
    polling.value = block.pollingInterval ?? "";
    for (const [id, fallback] of toggles) toggleInputs.get(id).checked = block[id] ?? fallback;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speed.value(), 100);
      const seconds = parseInt(polling.value, 10);
      setKey(draft, "pollingInterval", Number.isNaN(seconds) ? undefined : Math.min(Math.max(seconds, 1), 300), 2);
      for (const [id, fallback] of toggles) setKey(draft, id, toggleInputs.get(id).checked, fallback);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeLights`, `excludeScenes`), saved at once.
  async function toggleList(key, name) {
    const written = await homeswift.toggleList(key, name);
    if (!written) return;
    block = written;
    setTimeout(refresh, 1500);
  }

  // MARK: Refresh

  /// The status and the lists together; the lists count only once the bridge is paired.
  async function refresh() {
    const settle = (promise) => promise.then((value) => ({ value }), (error) => ({ error }));
    try {
      const [answer, lightList, sceneList] = await Promise.all([request("status"), settle(request("lights")), settle(request("scenes"))]);
      if (answer.paired) {
        const failed = lightList.error ?? sceneList.error;
        if (failed) throw failed;
        ({ lights } = lightList.value);
        ({ groups } = sceneList.value);
      } else {
        lights = [];
        groups = [];
      }
      status = answer;
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
