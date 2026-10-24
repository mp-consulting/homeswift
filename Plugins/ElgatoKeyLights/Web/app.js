// The Elgato Key Lights page, after the Homebridge plugin's: the lights the plugin instance knows (refreshed
// every two seconds while the page is visible, redrawn only when something changed), the configured ones that
// did not answer, and the disabled ones from config.json; a light's settings (enabled, name, what it does when
// switched on, a connection test); the lights Bonjour finds on the network; adding a light by its address.
// Saving writes this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { $, el, tile, request, explain, assistant, breadcrumb, act, readBlock, updateDevices, setKey, poll, renderKeyed, canonicalMAC, sameMAC } = homeswift;

  const list = $("#lights");
  const panel = $("#light-settings");
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "—");
  // The light's colour on its dot: warm at 2900 K, cool at 7000 K.
  const tint = (mirek) => (mirek ? `hsl(${mirek > 250 ? 35 : 210}, 90%, ${55 + Math.abs(mirek - 250) / 10}%)` : "var(--muted)");
  const behaviours = [[0, "Use the platform's setting"], [1, "Restore the last settings"], [2, "Use the defaults below"]];

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
    const [state, kind] = disabled ? ["Disabled", "standby"] : !light.reachable ? ["Not responding", "away"] : light.on ? ["On", "on"] : ["Off", "standby"];
    const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));
    return el("div", { class: `card light ${disabled ? "is-disabled" : ""}` },
      el("div", { class: "server-head" },
        tile("bulb", light.on && !disabled ? "yellow" : "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: [light.model, light.serial].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      disabled
        ? el("p", { class: "muted note", text: "Kept out of the Home app. Its settings can enable it again." })
        : el("div", { class: "facts" },
          fact("Brightness", light.on ? `${light.brightness} %` : "—"),
          el("div", { class: "fact" }, el("span", { text: "Colour" }),
            el("b", { class: "colour" }, el("span", { class: "glow", style: `background:${light.on ? tint(light.temperature) : "var(--line)"}` }), kelvin(light.temperature))),
          fact("Firmware", light.firmware || "—")),
      !disabled && !light.reachable ? explain({
        error: `The Elgato light ${light.name} does not answer at ${light.host}:${light.port}.`,
        context: "The Homeswift plugin polls the light's HTTP API (/elgato/lights) every second; a light that misses its polls shows as not responding.",
        device: { model: light.model, firmware: light.firmware, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, light.pinned ? "from config.json" : null, light.mac].filter(Boolean).join(" · ") }),
        // The same menu as the Accessories page's cards, with what this page adds.
        HomeswiftCommon.menuButton(`Actions for ${light.name}`, () => [
          !disabled && light.reachable ? { label: "Identify", icon: "identify", onSelect: () => request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }).catch((e) => alert(e.message)) } : null,
          { label: "Settings", icon: "gear", onSelect: () => openSettings(light) },
          disabled ? null : { label: "Show its log", icon: "logs", href: `/logs/${encodeURIComponent(`ElgatoKeyLights:${canonicalMAC(light.mac)}`)}` },
          window.HomeswiftChat?.available() ? { label: "Ask the Assistant", icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(`About my light ${light.name}: `) } : null,
        ])));
  }

  /// A configured light that is not running, as the Homebridge plugin lists one that did not answer: offline,
  /// with Explain, its settings and Remove.
  function offlineCard(light) {
    const connecting = light.status === "initializing";
    const [state, kind] = connecting ? ["Connecting…", "standby"] : light.host ? ["Not responding", "away"] : ["Not found yet", "away"];
    const problem = offlineProblem(light);
    return el("div", { class: "card light is-offline" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.model || "Key Light" })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("p", { class: "muted note", text: connecting ? "Homeswift is asking the light who it is." : light.host
        ? "It keeps its place in the Home app and is tried again when Bonjour announces it."
        : "Bonjour finds it once it is on the network; an address in its settings reaches it without Bonjour." }),
      problem ? explain({
        error: problem,
        context: "The Homeswift plugin connects to a configured light at start (GET /elgato/accessory-info, /elgato/lights and /elgato/lights/settings, 5 second timeout) and retries when Bonjour announces it.",
        device: { model: light.model, fromConfig: true, hasAddress: Boolean(light.host) },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, "from config.json", light.mac].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(`Actions for ${light.name}`, () => [
          { label: "Settings", icon: "gear", onSelect: () => openSettings(light) },
          { label: "Show its log", icon: "logs", href: `/logs/${encodeURIComponent(`ElgatoKeyLights:${canonicalMAC(light.mac)}`)}` },
          { label: "Remove from config.json", icon: "trash", danger: true, onSelect: () => removeLight(light) },
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
            el("p", { class: "muted", text: "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address." })));
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

  function openSettings(light) {
    if (!closeSettings()) return;
    const entry = entryFor(light.mac) || { mac: light.mac, name: light.name };
    editing = { light, draft: structuredClone(entry), saved: JSON.stringify(entry), exists: Boolean(entryFor(light.mac)) };
    panel.classList.remove("hidden");
    breadcrumb(light.name, closeSettings);
    renderSettings();
    panel.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
  }

  function closeSettings() {
    if (editing && JSON.stringify(editing.draft) !== editing.saved && !confirm("Discard the changes to this light?")) return false;
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
    const save = el("button", { class: "primary", text: "Save", onclick: (event) => act(event.currentTarget, saveSettings, (text) => { message.className = "error"; message.textContent = text; }) });
    const changed = () => {
      const dirty = JSON.stringify(editing.draft) !== editing.saved;
      save.disabled = !dirty;
      message.className = dirty ? "dirty" : "muted";
      message.textContent = dirty ? "Unsaved changes" : "Saved";
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
      el("label", { class: "field" }, el("span", { class: "field-title", text: "Default brightness" }), slider("powerOnBrightness", 3, 100, 1, 50, (v) => `${v} %`)),
      el("label", { class: "field" }, el("span", { class: "field-title", text: "Default colour temperature" }), slider("powerOnTemperature", 2900, 7000, 50, 4500, (v) => `${v} K`)));

    const test = el("p", { class: "status-line muted" });
    const testButton = el("button", { text: "Test connection", onclick: (event) => act(event.currentTarget, async () => {
      test.className = "status-line muted";
      test.textContent = `Asking ${light.host}:${light.port}…`;
      try {
        const { light: answer } = await request(`probe?host=${encodeURIComponent(light.host)}&port=${light.port}`);
        test.className = "status-line ok";
        test.textContent = `${answer.name} answered in ${answer.milliseconds} ms (${answer.model}, firmware ${answer.firmware ?? "?"}).`;
      } catch (e) {
        test.className = "status-line error";
        test.replaceChildren(e.message, explain({ error: e.message, context: "Testing the connection to an Elgato light from the Homeswift plugin page: GET /elgato/accessory-info, 5 second timeout.", device: { model: light.model } }));
      }
    }) });

    panel.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", { text: light.name }), el("p", { class: "muted", text: "Saving applies at once: the light keeps its place in the Home app." })),
        el("button", { class: "link", text: "Close", onclick: closeSettings })),
      el("div", { class: "panel-columns" },
        el("div", {},
          el("label", { class: "toggle" }, el("span", { class: "switch" }, enabled, el("span")),
            el("span", {}, el("span", { class: "field-title", text: "In the Home app" }), el("span", { class: "help", text: "Off keeps this light out of HomeKit, and removes it if it was there." }))),
          el("label", { class: "field" }, el("span", { class: "field-title", text: "Name in the Home app" }), displayName, el("span", { class: "help", text: "Empty uses the name the light reports." })),
          el("label", { class: "field" }, el("span", { class: "field-title", text: "When switched on" }), behaviour),
          defaults),
        el("div", {},
          el("div", { class: "facts info" },
            ...[["Product", light.model], ["Serial number", light.serial], ["Firmware", light.firmware], ["MAC address", light.mac], ["Address", light.host], ["Port", light.port]]
              .filter(([, value]) => value !== undefined && value !== "").map(([label, value]) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: String(value), title: String(value) })))),
          light.host ? el("div", { class: "actions" }, testButton) : null, test)),
      el("div", { class: "save-bar" }, message,
        editing.exists ? el("button", { class: "link danger", text: "Remove from config.json", onclick: (event) => act(event.currentTarget, removeEntry) }) : null,
        el("button", { text: "Cancel", onclick: () => { editing.draft = JSON.parse(editing.saved); closeSettings(); } }), save));
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
    closeSettings();
  }

  async function removeLight(light) {
    if (!confirm(`Remove the settings of ${light.name} from config.json? ${light.pinned ? "It is only reached through its address there, so it leaves the Home app." : "Bonjour still finds it, with the platform's settings."}`)) return false;
    try {
      await updateEntries((devices) => {
        const index = devices.findIndex((d) => sameMAC(d.mac, light.mac));
        if (index >= 0) devices.splice(index, 1);
      });
    } catch (e) {
      alert(e.message);
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
    const [state, kind] = entry ? ["In config.json", "on"] : light.running ? ["In the Home app", "standby"] : ["Not answering", "away"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: light.name }),
        el("div", { class: "muted", text: [light.model, light.address || light.host, light.mac].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      entry ? null : el("button", { text: "Add to config.json", onclick: (event) => act(event.currentTarget, () => addDiscovered(light)) }));
  }

  function renderDiscovered() {
    if (discoverBox.classList.contains("hidden")) return;
    const rows = discovered.length
      ? discovered.map(discoveredRow)
      : [el("p", { class: "muted", text: "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast can be added by its address." })];
    const key = JSON.stringify([discovered, discovered.map((light) => Boolean(entryFor(light.mac)))]);
    if (discoverBox.dataset.json === key) return;
    discoverBox.dataset.json = key;
    discoverBox.replaceChildren(
      el("p", { class: "muted", text: "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Adding one to config.json lets you name it and set what it does when switched on; Bonjour keeps finding it at its address." }),
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
  const host = el("input", { type: "text", placeholder: "192.168.1.50", inputmode: "decimal", spellcheck: false, "aria-label": "IP address or host name" });
  const port = el("input", { type: "number", value: 9123, min: 1, max: 65535, "aria-label": "Port" });
  const addStatus = el("p", { class: "status-line muted" });
  addBox.replaceChildren(
    el("p", { class: "muted", text: "For a light Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then adds it to config.json." }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, addByAddress, addFailed); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: "IP address or host name" }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: "Port" }), port),
      el("button", { class: "primary", type: "submit", text: "Add light" })),
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
    if (!address) throw new Error("Enter the light's IP address or host name.");
    addStatus.className = "status-line muted";
    addStatus.textContent = `Asking ${address}:${port.value}…`;
    const { light } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    if (!light.mac) throw new Error(`${light.name} answered but did not give its MAC address, which Homeswift keys lights by. Its Elgato Control Center app shows it.`);
    if (entryFor(light.mac)?.ip === address) throw new Error(`${light.name} is already in config.json at this address.`);
    const entry = { mac: light.mac, name: light.name, ip: address, model: light.model };
    if (Number(port.value) !== 9123) entry.port = Number(port.value);
    await putEntry(light.mac, (old) => ({ ...old, ...entry }));
    addStatus.className = "status-line ok";
    addStatus.textContent = `Added ${light.name}. It appears in the Home app under the bridge.`;
    host.value = "";
    setTimeout(refresh, 800);
  }

  // Without an Assistant, a tip on how to get one (Explain on errors), as the Homebridge plugin shows.
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  readBlock().then((block) => { configured = block.devices || []; refresh(); }).catch(() => {});
  poll(refresh);
})();
