// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension ElgatoKeyLightsPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Elgato Key Lights page, after the Homebridge plugin's: the lights the plugin instance knows (refreshed
// every two seconds while the page is visible, redrawn only when something changed), the configured ones that
// did not answer, and the disabled ones from config.json; a light's settings (enabled, name, what it does when
// switched on, a connection test); the lights Bonjour finds on the network; adding a light by its address.
// Saving writes this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, request, explain, assistant, breadcrumb, act, readBlock, updateDevices, setKey, poll, renderKeyed, canonicalMAC, sameMAC } = homeswift;

  const list = $("#lights");
  const panel = $("#light-settings");
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "—");
  // The light's colour on its dot: warm at 2900 K, cool at 7000 K.
  const tint = (mirek) => (mirek ? `hsl(${mirek > 250 ? 35 : 210}, 90%, ${55 + Math.abs(mirek - 250) / 10}%)` : "var(--muted)");
  const behaviours = [[0, t("Use the platform's setting")], [1, t("Restore the last settings")], [2, t("Use the defaults below")]];

  // MARK: config.json: this instance's block, through plugin.js.

  /// Changes the per-light entries and saves the block (the plugin reloads with them); the page keeps what was saved.
  async function updateEntries(change) {
    let devices = [];
    await updateDevices((list) => { change(list); devices = list; });
    configured = devices;
  }

  /// Adds a light's entry, or changes the one it has: `change` gets the entry there was, if any.
  const putEntry = (mac, change) => updateEntries((devices) => {
    const index = devices.findIndex((d) => sameMAC(d.mac, mac));
    if (index >= 0) devices[index] = change(devices[index]); else devices.push(change(undefined));
  });

  // MARK: The lights

  let lights = [];
  let pending = [];      // lights the plugin tried that are not running: connecting, or they did not answer
  let discovered = [];   // the lights Bonjour announces
  let configured = [];   // the block's per-light entries

  const entryFor = (mac) => configured.find((d) => sameMAC(d.mac, mac));

  /// Why a configured light is not running, for its card and Explain.
  function offlineProblem(light) {
    if (light.status === "initializing") return null;
    if (light.error) return `The Elgato light ${light.name} did not answer at ${light.host}:${light.port}: ${light.error}`;
    return light.host
      ? `The Elgato light ${light.name} is configured at ${light.host}:${light.port} but has not answered.`
      : `The Elgato light ${light.name} is in config.json without an address, and Bonjour has not announced it.`;
  }

  function lightCard(light) {
    if (light.offline) return offlineCard(light);
    const disabled = light.disabled === true;
    const [state, kind] = disabled ? [t("Disabled"), "standby"] : !light.reachable ? [t("Not responding"), "away"] : light.on ? [t("On"), "on"] : [t("Off"), "standby"];
    const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));
    return el("div", { class: `card light ${disabled ? "is-disabled" : ""}` },
      el("div", { class: "server-head" },
        tile("bulb", light.on && !disabled ? "yellow" : "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: [light.model, light.serial].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      disabled
        ? el("p", { class: "muted note", text: t("Kept out of the Home app. Its settings can enable it again.") })
        : el("div", { class: "facts" },
          fact(t("Brightness"), light.on ? `${light.brightness} %` : "—"),
          el("div", { class: "fact" }, el("span", { text: t("Colour") }),
            el("b", { class: "colour" }, el("span", { class: "glow", style: `background:${light.on ? tint(light.temperature) : "var(--line)"}` }), kelvin(light.temperature))),
          fact(t("Firmware"), light.firmware || "—")),
      !disabled && !light.reachable ? explain({
        error: `The Elgato light ${light.name} does not answer at ${light.host}:${light.port}.`,
        context: "The Homeswift plugin polls the light's HTTP API (/elgato/lights) every second; a light that misses its polls shows as not responding.",
        device: { model: light.model, firmware: light.firmware, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, light.pinned ? t("from config.json") : null, light.mac].filter(Boolean).join(" · ") }),
        // The same menu as the Accessories page's cards, with what this page adds.
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          !disabled && light.reachable ? { label: t("Identify"), icon: "identify", onSelect: () => request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
          { label: t("Settings"), icon: "gear", onSelect: () => openSettings(light) },
          disabled ? null : { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(`ElgatoKeyLights:${canonicalMAC(light.mac)}`)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my light {name}: ", { name: light.name })) } : null,
        ])));
  }

  /// A configured light that is not running, as the Homebridge plugin lists one that did not answer: offline,
  /// with Explain, its settings and Remove.
  function offlineCard(light) {
    const connecting = light.status === "initializing";
    const [state, kind] = connecting ? [t("Connecting…"), "standby"] : light.host ? [t("Not responding"), "away"] : [t("Not found yet"), "away"];
    const problem = offlineProblem(light);
    return el("div", { class: "card light is-offline" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.model || "Key Light" })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("p", { class: "muted note", text: connecting ? t("Homeswift is asking the light who it is.") : light.host
        ? t("It keeps its place in the Home app and is tried again when Bonjour announces it.")
        : t("Bonjour finds it once it is on the network; an address in its settings reaches it without Bonjour.") }),
      problem ? explain({
        error: problem,
        context: "The Homeswift plugin connects to a configured light at start (GET /elgato/accessory-info, /elgato/lights and /elgato/lights/settings, 5 second timeout) and retries when Bonjour announces it.",
        device: { model: light.model, fromConfig: true, hasAddress: Boolean(light.host) },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, t("from config.json"), light.mac].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          { label: t("Settings"), icon: "gear", onSelect: () => openSettings(light) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(`ElgatoKeyLights:${canonicalMAC(light.mac)}`)}` },
          { label: t("Remove from config.json"), icon: "trash", danger: true, onSelect: () => removeLight(light) },
        ])));
  }

  /// The lights the plugin runs, then the configured ones it does not (offline), then the disabled ones.
  function allLights() {
    const running = new Set(lights.map((light) => canonicalMAC(light.mac)));
    const tried = new Map(pending.map((light) => [canonicalMAC(light.mac), light]));
    const entries = configured.filter((d) => d.mac && !running.has(canonicalMAC(d.mac)));
    const fromEntry = (d) => ({
      mac: canonicalMAC(d.mac), name: d.displayName || d.name || canonicalMAC(d.mac), model: d.model || "Key Light", host: d.ip || d.host, port: d.port || 9123,
    });
    const offline = entries.filter((d) => d.enabled !== false).map((d) => {
      const light = { ...fromEntry(d), offline: true, pinned: Boolean(d.ip || d.host) };
      const attempt = tried.get(light.mac);
      if (attempt) Object.assign(light, { host: attempt.host, port: attempt.port, status: attempt.status, error: attempt.error ?? undefined });
      return light;
    });
    const disabled = entries.filter((d) => d.enabled === false).map((d) => ({ ...fromEntry(d), disabled: true }));
    return [...lights, ...offline, ...disabled];
  }

  // A card drawn again because its light changed (every brightness step) stays still: only a light new to the
  // page arrives with the material's animation.
  const shown = new Set();
  function card(light) {
    const node = lightCard(light);
    const key = canonicalMAC(light.mac);
    if (shown.has(key)) node.classList.add("redrawn");
    shown.add(key);
    return node;
  }

  async function refresh() {
    try {
      ({ lights, pending = [], discovered = [] } = await request("lights"));
      renderDiscovered();
      const all = allLights();
      if (all.length === 0) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address.") })));
        }
        return;
      }
      renderKeyed(list, all, (light) => canonicalMAC(light.mac), card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: A light's settings: the Homebridge plugin's Status, Settings and Info, in one panel.

  let editing = null;   // { light, draft, saved }

  async function openSettings(light) {
    if (!(await closeSettings())) return;
    const entry = entryFor(light.mac) || { mac: light.mac, name: light.name };
    editing = { light, draft: structuredClone(entry), saved: JSON.stringify(entry), exists: Boolean(entryFor(light.mac)) };
    panel.classList.remove("hidden");
    breadcrumb(light.name, closeSettings);
    renderSettings();
    panel.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
  }

  async function closeSettings() {
    if (editing && JSON.stringify(editing.draft) !== editing.saved && !await HomeswiftCommon.confirmDialog(t("Discard the changes to this light?"))) return false;
    if (editing) breadcrumb(null);
    editing = null;
    panel.classList.add("hidden");
    panel.replaceChildren();
    return true;
  }

  function renderSettings() {
    const { light, draft } = editing;
    const set = (key, value, fallback) => { setKey(draft, key, value, fallback); changed(); };
    const message = el("span", { class: "muted" });
    const save = el("button", { actionIcon: "check", class: "primary", text: t("Save"), onclick: (event) => act(event.currentTarget, saveSettings, (text) => { message.className = "error"; message.textContent = text; }) });
    const changed = () => {
      const dirty = JSON.stringify(editing.draft) !== editing.saved;
      save.disabled = !dirty;
      message.className = dirty ? "dirty" : "muted";
      message.textContent = dirty ? t("Unsaved changes") : t("Saved");
      defaults.classList.toggle("inactive", Number(draft.powerOnBehavior ?? 0) !== 2);
    };

    const enabled = el("input", { type: "checkbox", checked: draft.enabled !== false });
    enabled.addEventListener("change", () => set("enabled", enabled.checked, true));
    const displayName = el("input", { type: "text", value: draft.displayName ?? "", placeholder: light.name, maxLength: 64 });
    displayName.addEventListener("input", () => set("displayName", displayName.value.trim()));
    const behaviour = el("select", {}, behaviours.map(([value, text]) => el("option", { value, text, selected: value === Number(draft.powerOnBehavior ?? 0) })));
    behaviour.addEventListener("change", () => set("powerOnBehavior", Number(behaviour.value), 0));

    const slider = (key, min, max, step, fallback, format) => {
      // Inside its field's label, which names it.
      const input = el("input", { type: "range", min, max, step, value: draft[key] ?? fallback });
      const value = el("span", { class: "value", text: format(draft[key] ?? fallback) });
      input.addEventListener("input", () => { value.textContent = format(Number(input.value)); set(key, Number(input.value)); });
      return el("span", { class: "range" }, input, value);
    };
    const defaults = el("div", { class: "defaults" },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Default brightness") }), slider("powerOnBrightness", 3, 100, 1, 50, (v) => `${v} %`)),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Default colour temperature") }), slider("powerOnTemperature", 2900, 7000, 50, 4500, (v) => `${v} K`)));

    const test = el("p", { class: "status-line muted" });
    const testButton = el("button", { actionIcon: "send", text: t("Test connection"), onclick: (event) => act(event.currentTarget, async () => {
      test.className = "status-line muted";
      test.textContent = t("Asking {host}:{port}…", { host: light.host, port: String(light.port) });
      try {
        const { light: answer } = await request(`probe?host=${encodeURIComponent(light.host)}&port=${light.port}`);
        test.className = "status-line ok";
        test.textContent = t("{name} answered in {ms} ms ({model}, firmware {firmware}).", { name: answer.name, ms: answer.milliseconds, model: answer.model, firmware: answer.firmware ?? "?" });
      } catch (e) {
        test.className = "status-line error";
        test.replaceChildren(e.message, explain({ error: e.message, context: "Testing the connection to an Elgato light from the Homeswift plugin page: GET /elgato/accessory-info, 5 second timeout.", device: { model: light.model } }));
      }
    }) });

    panel.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", { text: light.name }), el("p", { class: "muted", text: t("Saving applies at once: the light keeps its place in the Home app.") })),
        el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closeSettings })),
      el("div", { class: "panel-columns" },
        el("div", {},
          el("label", { class: "toggle" }, el("span", { class: "switch" }, enabled, el("span")),
            el("span", {}, el("span", { class: "field-title", text: t("In the Home app") }), el("span", { class: "help", text: t("Off keeps this light out of HomeKit, and removes it if it was there.") }))),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("Name in the Home app") }), displayName, el("span", { class: "help", text: t("Empty uses the name the light reports.") })),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("When switched on") }), behaviour),
          defaults),
        el("div", {},
          el("div", { class: "facts info" },
            ...[[t("Product"), light.model], [t("Serial number"), light.serial], [t("Firmware"), light.firmware], [t("MAC address"), light.mac], [t("Address"), light.host], [t("Port"), light.port]]
              .filter(([, value]) => value !== undefined && value !== "").map(([label, value]) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: String(value), title: String(value) })))),
          light.host ? el("div", { class: "actions" }, testButton) : null, test)),
      el("div", { class: "save-bar" }, message,
        editing.exists ? el("button", { actionIcon: "trash", class: "link danger", text: t("Remove from config.json"), onclick: (event) => act(event.currentTarget, removeEntry) }) : null,
        el("button", { actionIcon: "close", text: t("Cancel"), onclick: () => { editing.draft = JSON.parse(editing.saved); closeSettings(); } }), save));
    changed();
  }

  async function saveSettings() {
    const { draft } = editing;
    await putEntry(draft.mac, () => draft);
    editing.saved = JSON.stringify(draft);
    editing.exists = true;
    renderSettings();
    setTimeout(refresh, 600);
  }

  /// Takes the light's entry out of the block. A light Bonjour finds comes back with the platform's settings.
  async function removeEntry() {
    const { light } = editing;
    if (!(await removeLight(light))) return;
    editing.draft = JSON.parse(editing.saved);
    await closeSettings();
  }

  async function removeLight(light) {
    if (!await HomeswiftCommon.confirmDialog(light.pinned
      ? t("Remove the settings of {name} from config.json? It is only reached through its address there, so it leaves the Home app.", { name: light.name })
      : t("Remove the settings of {name} from config.json? Bonjour still finds it, with the platform's settings.", { name: light.name }))) return false;
    try {
      await updateEntries((devices) => {
        const index = devices.findIndex((d) => sameMAC(d.mac, light.mac));
        if (index >= 0) devices.splice(index, 1);
      });
    } catch (e) {
      HomeswiftCommon.showAlert(e.message);
      return false;
    }
    setTimeout(refresh, 600);
    return true;
  }

  // MARK: On the network: what Bonjour announces (Homeswift browses all the time; the Homebridge plugin's
  // Discover button scanned for 5 seconds). A light found here is in the Home app already when it answered;
  // adding it to config.json gives it settings of its own.

  const discoverBox = $("#discovered");

  function discoveredRow(light) {
    const entry = entryFor(light.mac);
    const [state, kind] = entry ? [t("In config.json"), "on"] : light.running ? [t("In the Home app"), "standby"] : [t("Not answering"), "away"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: light.name }),
        el("div", { class: "muted", text: [light.model, light.address || light.host, light.mac].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      entry ? null : el("button", { actionIcon: "plus", text: t("Add to config.json"), onclick: (event) => act(event.currentTarget, () => addDiscovered(light)) }));
  }

  function renderDiscovered() {
    if (discoverBox.classList.contains("hidden")) return;
    const rows = discovered.length
      ? discovered.map(discoveredRow)
      : [el("p", { class: "muted", text: t("No light announces itself over Bonjour right now. A light on another network or behind a container without multicast can be added by its address.") })];
    const key = JSON.stringify([discovered, discovered.map((light) => Boolean(entryFor(light.mac)))]);
    if (discoverBox.dataset.json === key) return;
    discoverBox.dataset.json = key;
    discoverBox.replaceChildren(
      el("p", { class: "muted", text: t("The lights Bonjour finds on the network, kept up to date while Homeswift runs. Adding one to config.json lets you name it and set what it does when switched on; Bonjour keeps finding it at its address.") }),
      ...rows);
  }

  /// An entry for a light Bonjour found, without an address: announcements keep moving it when its address changes.
  async function addDiscovered(light) {
    const entry = { mac: canonicalMAC(light.mac), name: light.name };
    if (light.model) entry.model = light.model;
    await putEntry(entry.mac, (old) => ({ ...old, ...entry }));
    delete discoverBox.dataset.json;
    renderDiscovered();
    setTimeout(refresh, 600);
  }

  $("#discover-toggle").addEventListener("click", () => {
    const open = discoverBox.classList.toggle("hidden") === false;
    $("#discover-toggle").setAttribute("aria-expanded", String(open));
    delete discoverBox.dataset.json;
    renderDiscovered();
  });

  // MARK: Adding a light by its address, for networks Bonjour does not cross.

  const addBox = $("#add-light");
  const host = el("input", { type: "text", placeholder: "192.168.1.50", inputmode: "decimal", spellcheck: false, "aria-label": t("IP address or host name") });
  const port = el("input", { type: "number", value: 9123, min: 1, max: 65535, "aria-label": t("Port") });
  const addStatus = el("p", { class: "status-line muted" });
  addBox.replaceChildren(
    el("p", { class: "muted", text: t("For a light Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then adds it to config.json.") }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, addByAddress, addFailed); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("IP address or host name") }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: t("Port") }), port),
      el("button", { actionIcon: "plus", class: "primary", type: "submit", text: t("Add light") })),
    addStatus);
  $("#add-toggle").addEventListener("click", () => {
    const open = addBox.classList.toggle("hidden") === false;
    $("#add-toggle").setAttribute("aria-expanded", String(open));
    if (open) host.focus();
  });

  function addFailed(message) {
    addStatus.className = "status-line error";
    addStatus.replaceChildren(message, explain({ error: message, context: "Adding an Elgato light by address from the Homeswift plugin page: GET /elgato/accessory-info on the address and port given.", device: { model: "Elgato Key Light" } }));
  }

  async function addByAddress() {
    const address = host.value.trim();
    if (!address) throw new Error(t("Enter the light's IP address or host name."));
    addStatus.className = "status-line muted";
    addStatus.textContent = t("Asking {host}:{port}…", { host: address, port: port.value });
    const { light } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    if (!light.mac) throw new Error(t("{name} answered but did not give its MAC address, which Homeswift keys lights by. Its Elgato Control Center app shows it.", { name: light.name }));
    if (entryFor(light.mac)?.ip === address) throw new Error(t("{name} is already in config.json at this address.", { name: light.name }));
    const entry = { mac: light.mac, name: light.name, ip: address, model: light.model };
    if (Number(port.value) !== 9123) entry.port = Number(port.value);
    await putEntry(light.mac, (old) => ({ ...old, ...entry }));
    addStatus.className = "status-line ok";
    addStatus.textContent = t("Added {name}. It appears in the Home app under the bridge.", { name: light.name });
    host.value = "";
    setTimeout(refresh, 800);
  }

  // Without an Assistant, a tip on how to get one (Explain on errors), as the Homebridge plugin shows: one sentence
  // to translate, the block's name in bold where the language puts it.
  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  readBlock().then((block) => { configured = block.devices || []; refresh(); }).catch(() => {});
  poll(refresh);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Elgato Key Lights page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "Les lampes que connaît cette instance, telles qu'elle les voit en ce moment. Identifier fait clignoter une lampe pour savoir laquelle est laquelle.",
    "Your lights": "Vos lampes",
    "On the network": "Sur le réseau",
    "Add by address": "Ajouter par adresse",
    "Use the platform's setting": "Utiliser le réglage de la plateforme",
    "Restore the last settings": "Rétablir les derniers réglages",
    "Use the defaults below": "Utiliser les valeurs ci-dessous",
    "Disabled": "Désactivée",
    "Not responding": "Ne répond pas",
    "On": "Allumée",
    "Off": "Éteinte",
    "Kept out of the Home app. Its settings can enable it again.": "Tenue hors de l'app Maison. Ses réglages permettent de la réactiver.",
    "Brightness": "Luminosité",
    "Colour": "Couleur",
    "Firmware": "Firmware",
    "from config.json": "depuis config.json",
    "Actions for {name}": "Actions pour {name}",
    "Identify": "Identifier",
    "Settings": "Réglages",
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my light {name}: ": "À propos de ma lampe {name} : ",
    "Connecting…": "Connexion…",
    "Not found yet": "Pas encore trouvée",
    "Homeswift is asking the light who it is.": "Homeswift demande à la lampe qui elle est.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Elle garde sa place dans l'app Maison ; Homeswift réessaiera dès que Bonjour l'annoncera.",
    "Bonjour finds it once it is on the network; an address in its settings reaches it without Bonjour.": "Bonjour la trouve dès qu'elle est sur le réseau ; une adresse dans ses réglages permet de la joindre sans Bonjour.",
    "Remove from config.json": "Retirer de config.json",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address.": "Aucune lampe trouvée pour l'instant. Les lampes s'annoncent par Bonjour ; une lampe que Bonjour n'atteint pas peut être ajoutée par son adresse.",
    "Discard the changes to this light?": "Annuler les modifications de cette lampe ?",
    "Save": "Enregistrer",
    "Unsaved changes": "Modifications non enregistrées",
    "Saved": "Enregistré",
    "Default brightness": "Luminosité par défaut",
    "Default colour temperature": "Température de couleur par défaut",
    "Test connection": "Tester la connexion",
    "Asking {host}:{port}…": "Interrogation de {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} a répondu en {ms} ms ({model}, firmware {firmware}).",
    "Saving applies at once: the light keeps its place in the Home app.": "L'enregistrement s'applique aussitôt : la lampe garde sa place dans l'app Maison.",
    "Close": "Fermer",
    "In the Home app": "Dans l'app Maison",
    "Off keeps this light out of HomeKit, and removes it if it was there.": "Désactivé : la lampe reste hors de HomeKit, et en est retirée si elle y était.",
    "Name in the Home app": "Nom dans l'app Maison",
    "Empty uses the name the light reports.": "Vide, le nom donné par la lampe est utilisé.",
    "When switched on": "À l'allumage",
    "Product": "Produit",
    "Serial number": "Numéro de série",
    "MAC address": "Adresse MAC",
    "Address": "Adresse",
    "Port": "Port",
    "Cancel": "Annuler",
    "Remove the settings of {name} from config.json? It is only reached through its address there, so it leaves the Home app.": "Retirer les réglages de {name} de config.json ? Elle n'est jointe que par l'adresse qui s'y trouve, elle quittera donc l'app Maison.",
    "Remove the settings of {name} from config.json? Bonjour still finds it, with the platform's settings.": "Retirer les réglages de {name} de config.json ? Bonjour la trouve toujours, avec les réglages de la plateforme.",
    "In config.json": "Dans config.json",
    "Not answering": "Ne répond pas",
    "Add to config.json": "Ajouter à config.json",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast can be added by its address.": "Aucune lampe ne s'annonce par Bonjour en ce moment. Une lampe sur un autre réseau ou derrière un conteneur sans multicast peut être ajoutée par son adresse.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Adding one to config.json lets you name it and set what it does when switched on; Bonjour keeps finding it at its address.": "Les lampes que Bonjour trouve sur le réseau, tenues à jour tant que Homeswift fonctionne. En ajouter une à config.json permet de la nommer et de choisir ce qu'elle fait à l'allumage ; Bonjour continue de la trouver à son adresse.",
    "IP address or host name": "Adresse IP ou nom d'hôte",
    "For a light Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then adds it to config.json.": "Pour une lampe que Bonjour n'atteint pas, par exemple sur un autre réseau ou depuis un conteneur. Homeswift lui demande qui elle est, puis l'ajoute à config.json.",
    "Add light": "Ajouter la lampe",
    "Enter the light's IP address or host name.": "Saisissez l'adresse IP ou le nom d'hôte de la lampe.",
    "{name} answered but did not give its MAC address, which Homeswift keys lights by. Its Elgato Control Center app shows it.": "{name} a répondu sans donner son adresse MAC, par laquelle Homeswift identifie les lampes. Son app Elgato Control Center l'affiche.",
    "{name} is already in config.json at this address.": "{name} est déjà dans config.json à cette adresse.",
    "Added {name}. It appears in the Home app under the bridge.": "{name} ajoutée. Elle apparaît dans l'app Maison sous le pont.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Astuce : ajoutez un bloc {block} à config.json pour activer l'Assistant, qui explique ici les problèmes de découverte et de connexion.",
    "a host name or IP address is required": "un nom d'hôte ou une adresse IP est requis",
    "the port must be between 1 and 65535": "le port doit être compris entre 1 et 65535",
    "No light answered at {0}:{1}: {2}": "Aucune lampe n'a répondu à {0}:{1} : {2}",
    "no light with that MAC": "aucune lampe avec cette adresse MAC",
    "nothing at {0} {1}": "rien à {0} {1}"
  },
  "es": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "Las luces que conoce esta instancia, tal como las ve ahora. Identificar hace parpadear una luz para que sepas cuál es cuál.",
    "Your lights": "Tus luces",
    "On the network": "En la red",
    "Add by address": "Añadir por dirección",
    "Use the platform's setting": "Usar el ajuste de la plataforma",
    "Restore the last settings": "Restaurar los últimos ajustes",
    "Use the defaults below": "Usar los valores de abajo",
    "Disabled": "Desactivada",
    "Not responding": "No responde",
    "On": "Encendida",
    "Off": "Apagada",
    "Kept out of the Home app. Its settings can enable it again.": "Fuera de la app Casa. Puedes volver a activarla en sus ajustes.",
    "Brightness": "Brillo",
    "Colour": "Color",
    "Firmware": "Firmware",
    "from config.json": "desde config.json",
    "Actions for {name}": "Acciones para {name}",
    "Identify": "Identificar",
    "Settings": "Ajustes",
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my light {name}: ": "Sobre mi luz {name}: ",
    "Connecting…": "Conectando…",
    "Not found yet": "Aún no encontrada",
    "Homeswift is asking the light who it is.": "Homeswift le pregunta a la luz quién es.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Mantiene su lugar en la app Casa y se vuelve a intentar cuando Bonjour la anuncia.",
    "Bonjour finds it once it is on the network; an address in its settings reaches it without Bonjour.": "Bonjour la encuentra en cuanto está en la red; una dirección en sus ajustes la alcanza sin Bonjour.",
    "Remove from config.json": "Quitar de config.json",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address.": "Aún no se ha encontrado ninguna luz. Las luces se anuncian por Bonjour; una luz a la que Bonjour no llega se puede añadir por su dirección.",
    "Discard the changes to this light?": "¿Descartar los cambios de esta luz?",
    "Save": "Guardar",
    "Unsaved changes": "Cambios sin guardar",
    "Saved": "Guardado",
    "Default brightness": "Brillo predeterminado",
    "Default colour temperature": "Temperatura de color predeterminada",
    "Test connection": "Probar la conexión",
    "Asking {host}:{port}…": "Preguntando a {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} ha respondido en {ms} ms ({model}, firmware {firmware}).",
    "Saving applies at once: the light keeps its place in the Home app.": "Al guardar se aplica al instante: la luz mantiene su lugar en la app Casa.",
    "Close": "Cerrar",
    "In the Home app": "En la app Casa",
    "Off keeps this light out of HomeKit, and removes it if it was there.": "Si se desactiva, esta luz queda fuera de HomeKit y se quita si ya estaba.",
    "Name in the Home app": "Nombre en la app Casa",
    "Empty uses the name the light reports.": "Si está vacío, se usa el nombre que da la luz.",
    "When switched on": "Al encenderse",
    "Product": "Producto",
    "Serial number": "Número de serie",
    "MAC address": "Dirección MAC",
    "Address": "Dirección",
    "Port": "Puerto",
    "Cancel": "Cancelar",
    "Remove the settings of {name} from config.json? It is only reached through its address there, so it leaves the Home app.": "¿Quitar los ajustes de {name} de config.json? Solo se alcanza por la dirección que figura ahí, así que saldrá de la app Casa.",
    "Remove the settings of {name} from config.json? Bonjour still finds it, with the platform's settings.": "¿Quitar los ajustes de {name} de config.json? Bonjour la sigue encontrando, con los ajustes de la plataforma.",
    "In config.json": "En config.json",
    "Not answering": "No responde",
    "Add to config.json": "Añadir a config.json",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast can be added by its address.": "Ahora mismo ninguna luz se anuncia por Bonjour. Una luz en otra red o tras un contenedor sin multicast se puede añadir por su dirección.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Adding one to config.json lets you name it and set what it does when switched on; Bonjour keeps finding it at its address.": "Las luces que Bonjour encuentra en la red, actualizadas mientras Homeswift funciona. Añadir una a config.json te permite ponerle nombre y elegir qué hace al encenderse; Bonjour la sigue encontrando en su dirección.",
    "IP address or host name": "Dirección IP o nombre de host",
    "For a light Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then adds it to config.json.": "Para una luz a la que Bonjour no llega, por ejemplo en otra red o desde un contenedor. Homeswift le pregunta quién es y la añade a config.json.",
    "Add light": "Añadir luz",
    "Enter the light's IP address or host name.": "Introduce la dirección IP o el nombre de host de la luz.",
    "{name} answered but did not give its MAC address, which Homeswift keys lights by. Its Elgato Control Center app shows it.": "{name} ha respondido pero no ha dado su dirección MAC, con la que Homeswift identifica las luces. Su app Elgato Control Center la muestra.",
    "{name} is already in config.json at this address.": "{name} ya está en config.json con esta dirección.",
    "Added {name}. It appears in the Home app under the bridge.": "{name} añadida. Aparece en la app Casa bajo el puente.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que aquí explica los problemas de detección y conexión.",
    "a host name or IP address is required": "se necesita un nombre de host o una dirección IP",
    "the port must be between 1 and 65535": "el puerto debe estar entre 1 y 65535",
    "No light answered at {0}:{1}: {2}": "Ninguna luz ha respondido en {0}:{1}: {2}",
    "no light with that MAC": "no hay ninguna luz con esa MAC",
    "nothing at {0} {1}": "no hay nada en {0} {1}"
  },
  "pt": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "As luzes que esta instância conhece, tal como as vê agora. Identificar faz piscar uma luz para saber qual é qual.",
    "Your lights": "As suas luzes",
    "On the network": "Na rede",
    "Add by address": "Adicionar por endereço",
    "Use the platform's setting": "Usar a definição da plataforma",
    "Restore the last settings": "Restaurar as últimas definições",
    "Use the defaults below": "Usar as predefinições abaixo",
    "Disabled": "Desativada",
    "Not responding": "Não responde",
    "On": "Ligada",
    "Off": "Desligada",
    "Kept out of the Home app. Its settings can enable it again.": "Fora da app Casa. As suas definições permitem ativá-la de novo.",
    "Brightness": "Brilho",
    "Colour": "Cor",
    "Firmware": "Firmware",
    "from config.json": "do config.json",
    "Actions for {name}": "Ações de {name}",
    "Identify": "Identificar",
    "Settings": "Definições",
    "Show its log": "Mostrar o registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my light {name}: ": "Sobre a minha luz {name}: ",
    "Connecting…": "A ligar…",
    "Not found yet": "Ainda não encontrada",
    "Homeswift is asking the light who it is.": "O Homeswift está a perguntar à luz quem é.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Mantém o seu lugar na app Casa e é tentada de novo quando o Bonjour a anunciar.",
    "Bonjour finds it once it is on the network; an address in its settings reaches it without Bonjour.": "O Bonjour encontra-a assim que estiver na rede; um endereço nas suas definições permite alcançá-la sem Bonjour.",
    "Remove from config.json": "Remover do config.json",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address.": "Ainda não foi encontrada nenhuma luz. As luzes anunciam-se por Bonjour; uma luz que o Bonjour não alcança pode ser adicionada pelo endereço.",
    "Discard the changes to this light?": "Descartar as alterações desta luz?",
    "Save": "Guardar",
    "Unsaved changes": "Alterações não guardadas",
    "Saved": "Guardado",
    "Default brightness": "Brilho predefinido",
    "Default colour temperature": "Temperatura de cor predefinida",
    "Test connection": "Testar a ligação",
    "Asking {host}:{port}…": "A perguntar a {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} respondeu em {ms} ms ({model}, firmware {firmware}).",
    "Saving applies at once: the light keeps its place in the Home app.": "Ao guardar, as alterações aplicam-se de imediato: a luz mantém o seu lugar na app Casa.",
    "Close": "Fechar",
    "In the Home app": "Na app Casa",
    "Off keeps this light out of HomeKit, and removes it if it was there.": "Desativado: esta luz fica fora do HomeKit e é removida se já lá estava.",
    "Name in the Home app": "Nome na app Casa",
    "Empty uses the name the light reports.": "Se ficar vazio, é usado o nome que a luz indica.",
    "When switched on": "Ao ligar",
    "Product": "Produto",
    "Serial number": "Número de série",
    "MAC address": "Endereço MAC",
    "Address": "Endereço",
    "Port": "Porta",
    "Cancel": "Cancelar",
    "Remove the settings of {name} from config.json? It is only reached through its address there, so it leaves the Home app.": "Remover as definições de {name} do config.json? Só é alcançada pelo endereço que lá está, por isso sai da app Casa.",
    "Remove the settings of {name} from config.json? Bonjour still finds it, with the platform's settings.": "Remover as definições de {name} do config.json? O Bonjour continua a encontrá-la, com as definições da plataforma.",
    "In config.json": "No config.json",
    "Not answering": "Não responde",
    "Add to config.json": "Adicionar ao config.json",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast can be added by its address.": "Neste momento nenhuma luz se anuncia por Bonjour. Uma luz noutra rede ou atrás de um contentor sem multicast pode ser adicionada pelo endereço.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Adding one to config.json lets you name it and set what it does when switched on; Bonjour keeps finding it at its address.": "As luzes que o Bonjour encontra na rede, atualizadas enquanto o Homeswift funciona. Adicionar uma ao config.json permite dar-lhe um nome e escolher o que faz ao ligar; o Bonjour continua a encontrá-la no seu endereço.",
    "IP address or host name": "Endereço IP ou nome de anfitrião",
    "For a light Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then adds it to config.json.": "Para uma luz que o Bonjour não alcança, por exemplo noutra rede ou a partir de um contentor. O Homeswift pergunta-lhe quem é e adiciona-a ao config.json.",
    "Add light": "Adicionar luz",
    "Enter the light's IP address or host name.": "Introduza o endereço IP ou o nome de anfitrião da luz.",
    "{name} answered but did not give its MAC address, which Homeswift keys lights by. Its Elgato Control Center app shows it.": "{name} respondeu mas não indicou o endereço MAC, pelo qual o Homeswift identifica as luzes. A app Elgato Control Center mostra-o.",
    "{name} is already in config.json at this address.": "{name} já está no config.json com este endereço.",
    "Added {name}. It appears in the Home app under the bridge.": "{name} adicionada. Aparece na app Casa sob a ponte.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Sugestão: adicione um bloco {block} ao config.json para ter o Assistente, que aqui explica os problemas de deteção e ligação.",
    "a host name or IP address is required": "é necessário um nome de anfitrião ou um endereço IP",
    "the port must be between 1 and 65535": "a porta tem de estar entre 1 e 65535",
    "No light answered at {0}:{1}: {2}": "Nenhuma luz respondeu em {0}:{1}: {2}",
    "no light with that MAC": "não há nenhuma luz com esse MAC",
    "nothing at {0} {1}": "nada em {0} {1}"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Elgato Key Lights</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* A card per light on the UI's materials: its state as facts, where it is, and Identify. */
  .light { display: grid; gap: 14px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
  .light .actions { margin-top: 0; }
  .light.redrawn { animation: none; }
  .glow { width: 10px; height: 10px; border-radius: 50%; flex: none; box-shadow: 0 0 0 3px var(--material-thin); }
  .fact b.colour { display: flex; align-items: center; gap: 8px; }
  .light.is-disabled, .light.is-offline { opacity: 0.7; }
  .section-head .actions { margin-top: 0; }
  .found { display: flex; align-items: center; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .found .who { flex: 1; min-width: 180px; }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  .facts.info { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .defaults { transition: opacity var(--normal) var(--ease-out); }
  .defaults.inactive { opacity: 0.45; pointer-events: none; }
  .range { display: flex; align-items: center; gap: 12px; }
  .range input { flex: 1; width: auto; }
  .range .value { min-width: 64px; text-align: right; font-variant-numeric: tabular-nums; }
  .add-box { margin-bottom: 14px; animation: materialize var(--normal) var(--ease-out); }
  .add-box > p:first-child { margin-top: 0; font-size: 0.875rem; }
  .add-form { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; }
  .add-form .field { flex: 1; min-width: 200px; margin: 0; }
  .add-form .field.port { flex: 0 0 110px; min-width: 0; }
  @media (prefers-reduced-motion: reduce) { .light, .add-box { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-yellow" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>Elgato Key Lights</h1>
      <p class="muted" data-i18n>The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.</p>
    </div>
  </div>
  <div class="section-head"><h2 data-i18n>Your lights</h2><div class="actions"><button id="discover-toggle" aria-expanded="false" aria-controls="discovered" data-i18n>On the network</button><button id="add-toggle" aria-expanded="false" aria-controls="add-light" data-i18n data-action-icon="plus">Add by address</button></div></div>
  <div id="discovered" class="card add-box hidden"></div>
  <div id="add-light" class="card add-box hidden"></div>
  <div id="lights" class="grid"></div>
  <div id="light-settings" class="card panel hidden"></div>
  <p id="assistant-hint" class="hint hidden">Tip: add a <strong>HomeswiftAiKit</strong> block to config.json to get the Assistant, which explains discovery and connection problems here.</p>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
