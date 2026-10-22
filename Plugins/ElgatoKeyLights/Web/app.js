// The Elgato Key Lights page, after the Homebridge plugin's: the lights the plugin instance knows (refreshed
// every two seconds while the page is visible, redrawn only when something changed) and the disabled ones from
// config.json; a light's settings (enabled, name, what it does when switched on, a connection test); adding a
// light by its address. Saving writes this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { $, el, request, name, platform, explain, breadcrumb } = homeswift;

  const list = $("#lights");
  const panel = $("#light-settings");
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "—");
  // The light's colour on its dot: warm at 2900 K, cool at 7000 K.
  const tint = (mirek) => (mirek ? `hsl(${mirek > 250 ? 35 : 210}, 90%, ${55 + Math.abs(mirek - 250) / 10}%)` : "var(--muted)");
  const behaviours = [[0, "Use the platform's setting"], [1, "Restore the last settings"], [2, "Use the defaults below"]];

  /// Runs `work` with the button disabled; errors go to `report`.
  async function act(button, work, report = alert) {
    button.disabled = true;
    try { await work(); } catch (e) { report(e.message); }
    button.disabled = false;
  }

  function bulb() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/>';
    return svg;
  }

  // MARK: config.json: this instance's block, read and written through the signed-in UI.

  const api = async (path, options = {}) => {
    const response = await fetch(path, { credentials: "same-origin", ...options });
    if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || `HTTP ${response.status}`);
    return response.json();
  };
  const canonical = (mac) => (mac || "").toUpperCase().replace(/[^0-9A-F]/g, "").replace(/(..)(?!$)/g, "$1:");

  async function readBlock() {
    const plugins = await api("/api/plugins");
    const block = (plugins.blocks || []).find((b) => b.platform === platform && b.name === name);
    if (!block) throw new Error("This instance's block is not in the configuration.");
    const config = await api("/api/config");
    return { index: block.index, current: config.platforms[block.index] };
  }

  /// Changes the per-light entries and saves the block: the plugin reloads with them.
  async function updateDevices(change) {
    const { index, current } = await readBlock();
    const devices = current.devices || [];
    change(devices);
    const block = { ...current, devices };
    if (!devices.length) delete block.devices;
    await api(`/api/config/platforms/${index}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(block) });
    configured = devices;
  }

  // MARK: The lights

  let lights = [];
  let configured = [];   // the block's per-light entries
  let shown = null;

  const entryFor = (mac) => configured.find((d) => canonical(d.mac) === canonical(mac));

  function lightCard(light) {
    const disabled = light.disabled === true;
    const [state, kind] = disabled ? ["Disabled", "standby"] : !light.reachable ? ["Not responding", "away"] : light.on ? ["On", "on"] : ["Off", "standby"];
    const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));
    return el("div", { class: `card light ${disabled ? "is-disabled" : ""}` },
      el("div", { class: "server-head" },
        el("span", { class: `tile ${light.on && !disabled ? "light" : "system"}`, "aria-hidden": "true" }, bulb()),
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
        el("span", { class: "foot-actions" },
          disabled ? null : el("button", { class: "link", text: "Identify", disabled: !light.reachable, onclick: (event) => identify(light, event.currentTarget) }),
          el("button", { class: "link", text: "Settings", onclick: () => openSettings(light) }))));
  }

  async function identify(light, button) {
    await act(button, async () => {
      await request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" });
      button.textContent = "Flashing…";
      setTimeout(() => { button.textContent = "Identify"; }, 1500);
    });
  }

  /// The lights the plugin runs, then the disabled ones from config.json, which the plugin leaves out.
  function allLights() {
    const running = new Set(lights.map((light) => canonical(light.mac)));
    const disabled = configured.filter((d) => d.enabled === false && !running.has(canonical(d.mac))).map((d) => ({
      mac: canonical(d.mac), name: d.displayName || d.name || canonical(d.mac), model: d.model || "Key Light", host: d.ip || d.host, port: d.port || 9123, disabled: true,
    }));
    return [...lights, ...disabled];
  }

  async function refresh() {
    try {
      ({ lights } = await request("lights"));
      const all = allLights();
      const answer = JSON.stringify(all);
      if (answer === shown) return;
      shown = answer;
      if (all.length === 0) {
        list.replaceChildren(el("div", { class: "card empty", style: "grid-column:1/-1" },
          el("p", { class: "muted", text: "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach can be added by its address." })));
        return;
      }
      list.replaceChildren(...all.map(lightCard));
    } catch (e) {
      shown = null;
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
    const set = (key, value, fallback) => { if (value === undefined || value === "" || value === fallback) delete draft[key]; else draft[key] = value; changed(); };
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
      const input = el("input", { type: "range", min, max, step, value: draft[key] ?? fallback, "aria-label": key });
      const value = el("span", { class: "value", text: format(draft[key] ?? fallback) });
      input.addEventListener("input", () => { value.textContent = format(Number(input.value)); set(key, Number(input.value)); });
      return el("span", { class: "range" }, input, value);
    };
    const defaults = el("div", { class: "defaults" },
      el("label", { class: "field" }, el("span", { class: "field-title", text: "Default brightness" }), slider("powerOnBrightness", 0, 100, 1, 50, (v) => `${v} %`)),
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
    await updateDevices((devices) => {
      const index = devices.findIndex((d) => canonical(d.mac) === canonical(draft.mac));
      if (index >= 0) devices[index] = draft; else devices.push(draft);
    });
    editing.saved = JSON.stringify(draft);
    editing.exists = true;
    renderSettings();
    shown = null;
    setTimeout(refresh, 600);
  }

  /// Takes the light's entry out of the block. A light Bonjour finds comes back with the platform's settings.
  async function removeEntry() {
    const { light } = editing;
    if (!confirm(`Remove the settings of ${light.name} from config.json? ${light.pinned ? "It is only reached through its address there, so it leaves the Home app." : "Bonjour still finds it, with the platform's settings."}`)) return;
    await updateDevices((devices) => {
      const index = devices.findIndex((d) => canonical(d.mac) === canonical(light.mac));
      if (index >= 0) devices.splice(index, 1);
    });
    editing.draft = JSON.parse(editing.saved);
    closeSettings();
    shown = null;
    setTimeout(refresh, 600);
  }

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
    await updateDevices((devices) => {
      const index = devices.findIndex((d) => canonical(d.mac) === canonical(light.mac));
      if (index >= 0) devices[index] = { ...devices[index], ...entry }; else devices.push(entry);
    });
    addStatus.className = "status-line ok";
    addStatus.textContent = `Added ${light.name}. It appears in the Home app under the bridge.`;
    host.value = "";
    shown = null;
    setTimeout(refresh, 800);
  }

  readBlock().then(({ current }) => { configured = current.devices || []; shown = null; refresh(); }).catch(() => {});
  let timer = null;
  function start() { if (timer) return; refresh(); timer = setInterval(refresh, 2000); }
  function stop() { clearInterval(timer); timer = null; }
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();
