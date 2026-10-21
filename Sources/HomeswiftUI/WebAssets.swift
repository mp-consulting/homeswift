// THIS FILE IS GENERATED from Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

struct WebAsset: Sendable {
    let contentType: String
    let body: String
}

enum WebAssets {
    static let files: [String: WebAsset] = [
        "app.js": WebAsset(contentType: "text/javascript; charset=utf-8", body: #"""
// Homeswift web UI: one page, plain JavaScript, no dependencies. Talks to /api/* with the session cookie.
(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (key.startsWith("data-")) node.setAttribute(key, value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

  const show = (main, ...nodes) => main.replaceChildren(...nodes.flat().filter(Boolean));

  class ApiError extends Error { constructor(status, message) { super(message); this.status = status; } }

  async function api(path, { method = "GET", body, raw = false } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = typeof body === "string" ? body : JSON.stringify(body); }
    const response = await fetch(path, options);
    if (response.status === 401 && !path.startsWith("/api/auth/")) { showAuth(); throw new ApiError(401, "signed out"); }
    const text = await response.text();
    if (!response.ok) {
      let message = text;
      try { message = JSON.parse(text).error || text; } catch {}
      throw new ApiError(response.status, message || `HTTP ${response.status}`);
    }
    return raw ? text : (text ? JSON.parse(text) : null);
  }

  // ---- Authentication ------------------------------------------------------

  let auth = null;

  async function loadAuth() {
    auth = await api("/api/auth/state");
    if (auth.authenticated) showApp(); else showAuth();
  }

  function showAuth() {
    $("#app").classList.add("hidden");
    $("#auth").classList.remove("hidden");
    closeEvents();
    const setup = auth && auth.setupNeeded;
    $("#auth-text").textContent = setup
      ? "Create the administrator account for this bridge. The set-up code is in the bridge's output, next to the web UI address."
      : "Sign in to manage the bridge.";
    $("#auth-submit").textContent = setup ? "Create account" : "Sign in";
    $("input[name=password]", $("#auth-form")).autocomplete = setup ? "new-password" : "current-password";
    $("#auth-setup-code").classList.toggle("hidden", !setup);
    $("input[name=setupCode]", $("#auth-form")).required = !!setup;
  }

  $("#auth-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.target;
    const error = $("#auth-error");
    error.textContent = "";
    $("#auth-submit").disabled = true;
    try {
      const body = { username: form.username.value, password: form.password.value };
      if (auth && auth.setupNeeded) body.setupCode = form.setupCode.value;
      await api(auth && auth.setupNeeded ? "/api/auth/setup" : "/api/auth/login", { method: "POST", body });
      form.password.value = "";
      await loadAuth();
    } catch (e) {
      error.textContent = e.message;
    } finally {
      $("#auth-submit").disabled = false;
    }
  });

  $("#logout").addEventListener("click", async () => { try { await api("/api/auth/logout", { method: "POST" }); } catch {} await loadAuth(); });

  function showApp() {
    $("#auth").classList.add("hidden");
    $("#app").classList.remove("hidden");
    $("#user").textContent = auth.username || "";
    $("#logout").classList.toggle("hidden", auth.mode !== "form");
    openEvents();
    route();
  }

  // ---- Routing -------------------------------------------------------------

  const views = {};
  function route() {
    const name = (location.hash || "#status").slice(1);
    for (const link of document.querySelectorAll("nav a")) link.classList.toggle("active", link.getAttribute("href") === `#${name}`);
    const view = views[name] || views.status;
    const main = $("#view");
    main.replaceChildren(el("p", { class: "muted", text: "Loading…" }));
    view(main).catch((e) => { if (e.status !== 401) main.replaceChildren(el("p", { class: "error", text: e.message })); });
  }
  window.addEventListener("hashchange", () => { if (auth && auth.authenticated) route(); });

  // ---- Live events ---------------------------------------------------------

  let events = null;
  function openEvents() {
    if (events) return;
    events = new EventSource("/api/events");
    events.addEventListener("accessory", (event) => applyAccessoryEvent(JSON.parse(event.data)));
    events.addEventListener("log", (event) => appendLogLine(JSON.parse(event.data)));
  }
  function closeEvents() { if (events) { events.close(); events = null; } }

  // ---- Status --------------------------------------------------------------

  views.status = async (main) => {
    const status = await api("/api/status");
    $("#banner").classList.toggle("hidden", !status.restartNeeded);
    const bridges = status.bridges.map((bridge) => el("div", { class: "card" },
      el("h2", { text: bridge.name }, " ", el("span", { class: `pill ${bridge.paired ? "on" : ""}`, text: bridge.paired ? `paired, ${bridge.controllers} controller(s)` : "not paired" }),
        bridge.childBridge ? el("span", { class: "pill", text: "child bridge" }) : null),
      el("dl", {},
        el("dt", { text: "Device ID" }), el("dd", { text: bridge.deviceId }),
        el("dt", { text: "Port" }), el("dd", { text: bridge.port ?? "?" }),
        el("dt", { text: "Accessories" }), el("dd", { text: bridge.accessories }),
        el("dt", { text: "Platforms" }), el("dd", { text: bridge.platforms.join(", ") || "none" })),
      bridge.setupCode ? el("div", {}, el("p", { class: "muted", text: "In the Home app: Add Accessory, More options, then enter this code." }),
        el("div", { class: "code", text: bridge.setupCode }), el("p", { class: "muted", text: bridge.setupUri })) : null));
    show(main,
      el("h1", { text: "Status" }),
      el("div", { class: "cards" }, ...bridges),
      el("div", { class: "card" }, el("h2", { text: "Bridge" }), el("dl", {},
        el("dt", { text: "Version" }), el("dd", { text: status.version }),
        el("dt", { text: "Uptime" }), el("dd", { text: formatDuration(status.uptimeSeconds) }),
        el("dt", { text: "Config" }), el("dd", { text: status.configPath }),
        el("dt", { text: "Assistant" }), el("dd", { text: status.assistant ? `${status.assistant.provider} (${status.assistant.model})` : "off" }),
        el("dt", { text: "System" }), el("dd", { text: `${status.system.hostname}, ${status.system.platform} ${status.system.os}, ${status.system.cpus} CPUs` }))));
  };

  function formatDuration(seconds) {
    const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
  }

  // ---- Accessories ---------------------------------------------------------

  const enumLabels = {
    "Lock Target State": ["Unsecured", "Secured"], "Lock Current State": ["Unsecured", "Secured", "Jammed", "Unknown"],
    "Target Door State": ["Open", "Closed"], "Current Door State": ["Open", "Closed", "Opening", "Closing", "Stopped"],
    "Security System Target State": ["Home", "Away", "Night", "Off"], "Security System Current State": ["Home", "Away", "Night", "Off", "Alarm"],
    "Active": ["Inactive", "Active"], "Target Heating Cooling State": ["Off", "Heat", "Cool", "Auto"], "Current Heating Cooling State": ["Off", "Heating", "Cooling"],
    "Target Fan State": ["Manual", "Auto"], "Current Fan State": ["Inactive", "Idle", "Blowing"], "Rotation Direction": ["Clockwise", "Counter-clockwise"],
    "Swing Mode": ["Disabled", "Enabled"], "Programmable Switch Event": ["Single press", "Double press", "Long press"],
    "Contact Sensor State": ["Contact", "No contact"], "Temperature Display Units": ["Celsius", "Fahrenheit"],
    "Air Quality": ["Unknown", "Excellent", "Good", "Fair", "Inferior", "Poor"], "Charging State": ["Not charging", "Charging", "Not chargeable"],
    "Status Low Battery": ["Normal", "Low"], "Leak Detected": ["Dry", "Leak"], "Smoke Detected": ["Clear", "Smoke"], "Carbon Monoxide Detected": ["Normal", "Abnormal"],
    "Target Air Purifier State": ["Manual", "Auto"], "Current Air Purifier State": ["Inactive", "Idle", "Purifying"],
  };

  function serviceKey(service) { return service.subtype || service.type; }

  function controlFor(accessory, service, characteristic) {
    const writable = characteristic.permissions.includes("pw");
    const readable = characteristic.permissions.includes("pr");
    const attrs = { "data-id": accessory.id, "data-service": serviceKey(service), "data-char": characteristic.type };
    const write = async (value, onError) => {
      try {
        await api(`/api/accessories/${encodeURIComponent(accessory.id)}`, { method: "PUT", body: { service: serviceKey(service), characteristic: characteristic.type, value } });
      } catch (e) { onError(e); }
    };
    const labels = enumLabels[characteristic.type];
    if (writable && characteristic.format === "bool") {
      const input = el("input", { type: "checkbox", checked: characteristic.value === true });
      const label = el("label", { class: "switch", ...attrs }, input, el("span"));
      input.addEventListener("change", () => write(input.checked, () => { input.checked = !input.checked; }));
      return label;
    }
    if (writable && (characteristic.validValues || labels) && characteristic.format !== "bool") {
      const values = characteristic.validValues || labels.map((_, index) => index);
      const select = el("select", attrs, ...values.map((value) => el("option", { value, text: labels && labels[value] !== undefined ? labels[value] : String(value), selected: value === characteristic.value })));
      select.addEventListener("change", () => write(Number(select.value), () => {}));
      return select;
    }
    if (writable && ["int", "uint8", "uint16", "uint32", "uint64", "float"].includes(characteristic.format) && characteristic.minValue !== undefined && characteristic.maxValue !== undefined) {
      const input = el("input", { type: "range", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || 1, value: characteristic.value ?? 0 });
      const value = el("span", { class: "value", text: formatValue(characteristic) });
      let timer;
      input.addEventListener("input", () => { value.textContent = `${input.value}${unit(characteristic)}`; clearTimeout(timer); timer = setTimeout(() => write(Number(input.value), () => {}), 250); });
      return el("span", { class: "range", ...attrs }, input, value);
    }
    if (writable && characteristic.format === "string") {
      const input = el("input", { type: "text", value: characteristic.value ?? "", ...attrs });
      input.addEventListener("change", () => write(input.value, () => {}));
      return input;
    }
    if (!readable) return el("span", { class: "muted", text: "write-only" });
    const text = labels && labels[characteristic.value] !== undefined ? labels[characteristic.value] : formatValue(characteristic);
    return el("span", { class: "value", text, ...attrs });
  }

  function unit(characteristic) {
    return { celsius: " °C", percentage: " %", lux: " lx", seconds: " s", arcdegrees: "°" }[characteristic.unit] || "";
  }
  function formatValue(characteristic) {
    if (characteristic.format === "bool") return characteristic.value ? "On" : "Off";
    if (characteristic.value === null || characteristic.value === undefined) return "";
    return `${characteristic.value}${unit(characteristic)}`;
  }

  views.accessories = async (main) => {
    const accessories = await api("/api/accessories");
    const byBridge = new Map();
    for (const accessory of accessories) {
      if (!byBridge.has(accessory.bridge)) byBridge.set(accessory.bridge, []);
      byBridge.get(accessory.bridge).push(accessory);
    }
    const sections = [];
    for (const [bridge, list] of byBridge) {
      sections.push(el("h2", { text: bridge }));
      sections.push(el("div", { class: "cards" }, ...list.map((accessory) => el("div", { class: "card" },
        el("div", { class: "item-head" },
          el("div", {}, el("strong", { text: accessory.name }), el("div", { class: "muted", text: `${describeModel(accessory)} · ${accessory.platformName || accessory.platform || ""}` })),
          el("button", { class: "link", text: "Identify", onclick: () => api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).catch(() => {}) })),
        ...accessory.services.map((service) => el("div", {},
          accessory.services.length > 1 ? el("div", { class: "muted", text: service.name || service.type }) : null,
          ...service.characteristics.filter((c) => c.type !== "Name").map((characteristic) => el("div", { class: "row" },
            el("span", { class: "name", text: characteristic.type }), controlFor(accessory, service, characteristic)))))))));
    }
    show(main, el("h1", { text: "Accessories" }), accessories.length ? el("div", {}, ...sections) : el("p", { class: "muted", text: "No accessories yet. Plugins add them once they reach their devices." }));
  };

  function describeModel(accessory) {
    const manufacturer = accessory.manufacturer || "";
    const model = accessory.model || "";
    return model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : `${manufacturer} ${model}`.trim();
  }

  function applyAccessoryEvent(event) {
    const selector = `[data-id="${CSS.escape(event.id)}"][data-char="${CSS.escape(event.characteristic)}"]`;
    for (const node of document.querySelectorAll(selector)) {
      if (event.subtype && node.dataset.service !== event.subtype) continue;
      if (node.classList.contains("switch")) $("input", node).checked = event.value === true;
      else if (node.classList.contains("range")) { $("input", node).value = event.value; $(".value", node).textContent = `${event.value}${unitOf(node)}`; }
      else if (node.tagName === "SELECT") node.value = String(event.value);
      else if (node.tagName === "INPUT") node.value = event.value;
      else {
        const labels = enumLabels[event.characteristic];
        node.textContent = typeof event.value === "boolean" ? (event.value ? "On" : "Off") : (labels && labels[event.value] !== undefined ? labels[event.value] : String(event.value));
      }
    }
  }
  function unitOf(node) { const value = $(".value", node); const match = value && value.textContent.match(/[^\d.-]+$/); return match ? match[0] : ""; }

  // ---- Plugins and settings forms -----------------------------------------

  views.plugins = async (main) => {
    const plugins = await api("/api/plugins");
    const byPlatform = new Map(plugins.plugins.map((plugin) => [plugin.platform, plugin]));
    const running = (block) => plugins.platforms.find((p) => p.platform === block.platform && p.name === block.name);
    const cards = plugins.blocks.map((block) => {
      const plugin = byPlatform.get(block.platform);
      const instance = running(block);
      const status = block.system ? "system" : instance ? `running on ${instance.bridge}, ${instance.accessories} accessories` : plugin ? "not running" : "no plugin provides this platform";
      const card = el("div", { class: "card" });
      const show = () => card.replaceChildren(
        el("div", { class: "item-head" }, el("div", {}, el("strong", { text: block.name }), el("div", { class: "muted", text: `${block.platform}${block.childBridge ? " · child bridge" : ""} · ${status}` })),
          el("span", {}, el("button", { text: "Settings", onclick: () => openEditor(card, block, plugin, show) }), " ",
            el("button", { class: "link", text: "Remove", onclick: async () => {
              if (!confirm(`Remove the block "${block.name}" from config.json?`)) return;
              try { await api(`/api/config/platforms/${block.index}`, { method: "DELETE" }); $("#banner").classList.remove("hidden"); route(); } catch (e) { alert(e.message); }
            } }))));
      show();
      return card;
    });
    const addable = plugins.plugins.filter((plugin) => !plugins.blocks.some((block) => block.platform === plugin.platform));
    const select = el("select", {}, ...plugins.plugins.map((plugin) => el("option", { value: plugin.platform, text: `${plugin.name} (${plugin.platform})` })));
    const add = el("div", { class: "card" }, el("h2", { text: "Add a platform" }),
      el("div", { class: "toolbar" }, select, el("button", { class: "primary", text: "Add", onclick: () => {
        const plugin = byPlatform.get(select.value);
        const card = el("div", { class: "card" });
        add.after(card);
        openEditor(card, { index: plugins.blocks.length, platform: plugin.platform, name: plugin.name, system: false }, plugin, () => card.remove(), true);
      } })),
      addable.length === 0 ? el("p", { class: "muted", text: "Every compiled-in plugin already has a block; a second block of the same platform is allowed." }) : null);
    show(main, el("h1", { text: "Plugins" }), ...cards, add,
      plugins.unknownPlatforms.length ? el("p", { class: "muted", text: `Platforms in config.json that no plugin provides: ${plugins.unknownPlatforms.join(", ")}` }) : null);
  };

  async function openEditor(card, block, plugin, close, isNew = false) {
    card.replaceChildren(el("p", { class: "muted", text: "Loading…" }));
    let current = { platform: block.platform, name: block.name };
    if (!isNew) {
      const config = JSON.parse(await api("/api/config", { raw: true }));
      current = (config.platforms || [])[block.index] || current;
    }
    let schema = null;
    if (plugin && plugin.hasSchema && !block.system) {
      try { schema = JSON.parse(await api(`/api/plugins/${encodeURIComponent(block.platform)}/schema`, { raw: true })); } catch {}
    }
    const error = el("p", { class: "error" });
    let getValue;
    let body;
    if (schema) {
      const form = buildForm(schema, current);
      body = form.element;
      getValue = form.getValue;
    } else {
      const textarea = el("textarea", { value: JSON.stringify(current, null, 2) });
      body = el("div", {}, el("p", { class: "muted", text: "This plugin has no settings schema; edit the block as JSON." }), textarea);
      getValue = () => JSON.parse(textarea.value);
    }
    card.replaceChildren(
      el("div", { class: "item-head" }, el("strong", { text: `${block.name} · ${block.platform}` })),
      body, error,
      el("div", { class: "actions" },
        el("button", { class: "primary", text: "Save", onclick: async (event) => {
          event.target.disabled = true;
          error.textContent = "";
          try {
            const value = getValue();
            value.platform = block.platform;
            const result = await api(`/api/config/platforms/${block.index}`, { method: "PUT", body: value });
            $("#banner").classList.remove("hidden");
            error.className = "ok";
            error.textContent = `Saved (backup ${result.backup}). Restart homeswift to apply.`;
            setTimeout(route, 800);
          } catch (e) { error.className = "error"; error.textContent = e.message; event.target.disabled = false; }
        } }),
        el("button", { text: "Cancel", onclick: close })));
  }

  /// A form from a Homebridge-style config.schema.json; key order follows the schema (and its layout).
  function buildForm(root, value) {
    const schema = root.schema || root;
    const properties = schema.properties || {};
    const requiredTop = new Set(Array.isArray(schema.required) ? schema.required : []);
    const fields = new Map();
    const container = el("div", {});

    const field = (key, property, current, required) => {
      const title = property.title || key;
      const wrap = (control) => el("label", {}, title, required ? el("span", { class: "muted", text: " (required)" }) : null, control,
        property.description ? el("div", { class: "help", text: property.description }) : null);
      const type = property.type;
      const options = property.oneOf && property.oneOf.every((o) => Array.isArray(o.enum)) ? property.oneOf.map((o) => ({ value: o.enum[0], title: o.title ?? String(o.enum[0]) })) : property.enum ? property.enum.map((v) => ({ value: v, title: String(v) })) : null;
      if (options) {
        const select = el("select", {}, el("option", { value: "", text: "—" }), ...options.map((o) => el("option", { value: JSON.stringify(o.value), text: o.title, selected: current !== undefined ? JSON.stringify(o.value) === JSON.stringify(current) : JSON.stringify(o.value) === JSON.stringify(property.default) })));
        return { element: wrap(select), get: () => (select.value === "" ? undefined : JSON.parse(select.value)) };
      }
      if (type === "boolean") {
        const input = el("input", { type: "checkbox", checked: current !== undefined ? current === true : property.default === true });
        const present = current !== undefined;
        return { element: el("label", {}, input, " ", title, property.description ? el("div", { class: "help", text: property.description }) : null), get: () => (input.checked || present ? input.checked : undefined) };
      }
      if (type === "integer" || type === "number") {
        const input = el("input", { type: "number", value: current ?? "", placeholder: property.placeholder ?? property.default ?? "", min: property.minimum, max: property.maximum, step: property.step ?? (type === "integer" ? 1 : "any"), required });
        return { element: wrap(input), get: () => (input.value === "" ? undefined : Number(input.value)) };
      }
      if (type === "object" && property.properties) {
        const nested = buildObject(property, current || {});
        return { element: el("fieldset", {}, el("legend", { text: title }), nested.element), get: () => { const v = nested.getValue(); return Object.keys(v).length ? v : undefined; } };
      }
      if (type === "array") {
        const items = property.items || { type: "string" };
        const list = el("div", {});
        const rows = [];
        const addRow = (itemValue) => {
          const row = el("div", { class: "item" });
          let get;
          if (items.type === "object" && items.properties) {
            const nested = buildObject(items, itemValue || {});
            row.append(el("div", { class: "item-head" }, el("span", { class: "muted", text: `${title} ${rows.length + 1}` }), el("button", { class: "link", text: "Remove", onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); } })), nested.element);
            get = nested.getValue;
          } else {
            const f = field("", items, itemValue, false);
            row.append(el("div", { class: "item-head" }, f.element, el("button", { class: "link", text: "Remove", onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); } })));
            get = f.get;
          }
          const entry = { get };
          rows.push(entry);
          list.append(row);
        };
        for (const item of Array.isArray(current) ? current : []) addRow(item);
        const element = el("fieldset", {}, el("legend", { text: title }), property.description ? el("div", { class: "help", text: property.description }) : null, list,
          el("button", { text: `Add ${title.replace(/s$/, "")}`, onclick: () => addRow(undefined) }));
        return { element, get: () => { const v = rows.map((r) => r.get()).filter((x) => x !== undefined); return v.length ? v : undefined; } };
      }
      const input = el("input", { type: property["x-schema-form"] && property["x-schema-form"].type === "password" ? "password" : "text", value: current ?? "", placeholder: property.placeholder ?? property.default ?? "", required });
      return { element: wrap(input), get: () => (input.value === "" ? undefined : input.value) };
    };

    function buildObject(objectSchema, current) {
      const props = objectSchema.properties || {};
      const required = new Set(Array.isArray(objectSchema.required) ? objectSchema.required : []);
      const parts = new Map();
      const element = el("div", {});
      for (const [key, property] of Object.entries(props)) {
        const f = field(key, property, current[key], required.has(key) || property.required === true);
        parts.set(key, f);
        element.append(f.element);
      }
      return { element, getValue: () => {
        const out = {};
        for (const [key, value] of Object.entries(current)) if (!props[key]) out[key] = value;
        for (const [key, f] of parts) { const v = f.get(); if (v !== undefined) out[key] = v; }
        return out;
      } };
    }

    const render = (key) => {
      const property = properties[key];
      if (!property || fields.has(key)) return null;
      const f = field(key, property, value[key], requiredTop.has(key) || property.required === true);
      fields.set(key, f);
      return f.element;
    };
    const layoutItem = (item) => {
      if (typeof item === "string") return item === "*" ? Object.keys(properties).map(render) : render(item);
      if (item && item.key) return render(item.key);
      if (item && Array.isArray(item.items)) {
        const inner = item.items.map(layoutItem).flat().filter(Boolean);
        if (!inner.length) return null;
        if (item.type === "fieldset" || item.title) {
          const details = el("details", { open: !item.expandable || item.expanded !== false }, el("summary", { text: item.title || "More" }), ...inner);
          return details;
        }
        return el("div", {}, ...inner);
      }
      return null;
    };
    if (Array.isArray(root.layout)) for (const item of root.layout) { const node = layoutItem(item); if (node) container.append(...[node].flat()); }
    for (const key of Object.keys(properties)) { const node = render(key); if (node) container.append(node); }

    return { element: container, getValue: () => {
      const out = {};
      for (const [key, v] of Object.entries(value)) if (!properties[key]) out[key] = v;
      for (const [key, f] of fields) { const v = f.get(); if (v !== undefined) out[key] = v; }
      return out;
    } };
  }

  // ---- Config --------------------------------------------------------------

  views.config = async (main) => {
    const text = await api("/api/config", { raw: true });
    const textarea = el("textarea", { value: text, spellcheck: false });
    const message = el("p", { class: "muted" });
    show(main, el("h1", { text: "config.json" }),
      el("p", { class: "muted", text: "The whole file. Saving validates it, keeps a backup, and sorts the keys. Restart homeswift to apply." }),
      textarea, message,
      el("div", { class: "actions" }, el("button", { class: "primary", text: "Save", onclick: async (event) => {
        let parsed;
        try { parsed = JSON.parse(textarea.value); } catch (e) { message.className = "error"; message.textContent = `Not valid JSON: ${e.message}`; return; }
        event.target.disabled = true;
        try {
          const result = await api("/api/config", { method: "PUT", body: parsed });
          message.className = "ok";
          message.textContent = `Saved; backup ${result.backup}; changed: ${result.changes.join(", ") || "nothing"}. Restart homeswift to apply.`;
          $("#banner").classList.remove("hidden");
          textarea.value = await api("/api/config", { raw: true });
        } catch (e) { message.className = "error"; message.textContent = e.message; }
        event.target.disabled = false;
      } })));
  };

  // ---- Logs ----------------------------------------------------------------

  const levelRank = { trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 };
  let logState = null;

  views.logs = async (main) => {
    const lines = await api("/api/logs");
    const output = el("div", { class: "log" });
    const level = el("select", {}, ...["trace", "debug", "info", "warning", "error"].map((name) => el("option", { value: name, text: name, selected: name === "info" })));
    const filter = el("input", { type: "search", placeholder: "Filter text" });
    const follow = el("input", { type: "checkbox", checked: true });
    logState = { output, level, filter, follow, lines: [] };
    const render = () => {
      output.replaceChildren(...logState.lines.filter(visible).map(lineNode));
      if (follow.checked) output.scrollTop = output.scrollHeight;
    };
    level.addEventListener("change", render);
    filter.addEventListener("input", render);
    logState.lines = lines;
    show(main, el("h1", { text: "Logs" }),
      el("div", { class: "toolbar" }, el("label", { text: "From level " }, level), filter, el("label", {}, follow, " Follow")),
      output);
    render();
  };

  function visible(line) {
    const minimum = levelRank[logState.level.value] ?? 0;
    const text = logState.filter.value.toLowerCase();
    return (levelRank[line.level] ?? 0) >= minimum && (!text || `${line.label} ${line.text}`.toLowerCase().includes(text));
  }
  function lineNode(line) {
    const time = line.time.replace("T", " ").replace(/\.\d+Z?$/, "").replace("Z", "");
    return el("div", { class: line.level }, `${time} [${line.label}] ${line.text}`);
  }
  function appendLogLine(line) {
    if (!logState || !document.body.contains(logState.output)) return;
    logState.lines.push(line);
    if (logState.lines.length > 2000) logState.lines.shift();
    if (visible(line)) { logState.output.append(lineNode(line)); if (logState.follow.checked) logState.output.scrollTop = logState.output.scrollHeight; }
  }

  loadAuth().catch((e) => { $("#auth").classList.remove("hidden"); $("#auth-error").textContent = e.message; });
})();

"""#),
        "icon.svg": WebAsset(contentType: "image/svg+xml", body: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Homeswift</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFA01C"/>
      <stop offset="1" stop-color="#F0442E"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="228" fill="url(#bg)"/>
  <!-- House -->
  <path d="M232 470 L512 236 L792 470 M300 420 V776 Q300 800 324 800 H700 Q724 800 724 776 V420"
        fill="none" stroke="#fff" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>
  <!-- The Swift logo bird (swift.org), a trademark of Apple Inc. -->
  <path fill="#fff" transform="translate(512 588) scale(6.4) translate(-29.06 -29.05)" d="m47.06 36.66-.004-.004c.066-.224.134-.446.191-.675 2.465-9.821-3.55-21.432-13.731-27.546 4.461 6.048 6.434 13.374 4.681 19.78-.156.571-.344 1.12-.552 1.653-.225-.148-.51-.316-.89-.527 0 0-10.127-6.252-21.103-17.312-.288-.29 5.852 8.777 12.822 16.14-3.284-1.843-12.434-8.5-18.227-13.802.712 1.187 1.558 2.33 2.489 3.43C17.573 23.932 23.882 31.5 31.44 37.314c-5.31 3.25-12.814 3.502-20.285.003a30.646 30.646 0 0 1-5.193-3.098c3.162 5.058 8.033 9.423 13.96 11.97 7.07 3.039 14.1 2.833 19.336.05l-.004.007c.024-.016.055-.032.08-.047.214-.116.428-.234.636-.358 2.516-1.306 7.485-2.63 10.152 2.559.654 1.27 2.041-5.46-3.061-11.74z"/>
</svg>

"""#),
        "index.html": WebAsset(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Homeswift</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div id="auth" class="auth hidden">
  <form id="auth-form" class="card">
    <img src="/icon.svg" class="logo large" alt="">
    <h1>Homeswift</h1>
    <p id="auth-text"></p>
    <label>Username <input name="username" autocomplete="username" required></label>
    <label>Password <input name="password" type="password" autocomplete="current-password" required minlength="8"></label>
    <label id="auth-setup-code" class="hidden">Set-up code <input name="setupCode" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX"></label>
    <p class="error" id="auth-error"></p>
    <button type="submit" id="auth-submit">Sign in</button>
  </form>
</div>
<div id="app" class="hidden">
  <header>
    <a class="brand" href="#status"><img src="/icon.svg" class="logo" alt="">Homeswift</a>
    <nav>
      <a href="#status">Status</a>
      <a href="#accessories">Accessories</a>
      <a href="#plugins">Plugins</a>
      <a href="#config">Config</a>
      <a href="#logs">Logs</a>
    </nav>
    <span class="spacer"></span>
    <span id="user"></span>
    <button id="logout" class="link">Sign out</button>
  </header>
  <div id="banner" class="banner hidden">Configuration changed. Restart homeswift to apply it.</div>
  <main id="view"></main>
</div>
<script src="/app.js"></script>
</body>
</html>

"""#),
        "style.css": WebAsset(contentType: "text/css; charset=utf-8", body: #"""
/* Liquid glass: translucent panels with blur and edge light over a soft, colourful backdrop. */
:root {
  --bg: #e9edf6; --bg-warm: #ffe9d6; --bg-cool: #dcefff; --bg-mint: #e2f7ee;
  --glass: rgba(255, 255, 255, 0.52); --glass-strong: rgba(255, 255, 255, 0.72); --glass-edge: rgba(255, 255, 255, 0.85);
  --glass-shadow: 0 12px 36px rgba(25, 34, 56, 0.14); --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.45), rgba(255, 255, 255, 0) 45%);
  --text: #15171c; --muted: #5d6572; --line: rgba(20, 30, 50, 0.09);
  --accent: #ff7a1a; --accent-2: #ffb15c; --accent-text: #ffffff; --ok: #1f9d55; --warn: #d9821f; --error: #d0383b;
  --mono: ui-monospace, SFMono-Regular, Menlo, monospace;
  --radius: 22px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1218; --bg-warm: #3a2a1e; --bg-cool: #15243a; --bg-mint: #14302a;
    --glass: rgba(34, 38, 48, 0.52); --glass-strong: rgba(40, 44, 56, 0.7); --glass-edge: rgba(255, 255, 255, 0.16);
    --glass-shadow: 0 14px 40px rgba(0, 0, 0, 0.45); --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.10), rgba(255, 255, 255, 0) 45%);
    --text: #f3f4f7; --muted: #9ba2ae; --line: rgba(255, 255, 255, 0.09);
  }
}
* { box-sizing: border-box; }
html { min-height: 100%; }
body {
  margin: 0; font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif; color: var(--text);
  background:
    radial-gradient(55% 45% at 8% 6%, var(--bg-warm) 0%, transparent 62%),
    radial-gradient(50% 42% at 92% 16%, var(--bg-cool) 0%, transparent 60%),
    radial-gradient(60% 55% at 50% 100%, var(--bg-mint) 0%, transparent 65%),
    var(--bg);
  background-attachment: fixed;
}
.hidden { display: none !important; }

/* Glass surfaces */
.card, header, .banner, .log, .toolbar, .auth .card {
  background-color: var(--glass); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(28px) saturate(180%); backdrop-filter: blur(28px) saturate(180%);
  border: 1px solid var(--glass-edge); box-shadow: var(--glass-shadow), inset 0 1px 0 rgba(255, 255, 255, 0.55);
  border-radius: var(--radius);
}
header {
  position: sticky; top: 12px; z-index: 2; margin: 12px auto 0; max-width: 1100px; width: calc(100% - 24px);
  display: flex; align-items: center; gap: 14px; padding: 8px 10px 8px 20px; border-radius: 999px;
}
.brand { display: inline-flex; align-items: center; gap: 9px; font-weight: 700; letter-spacing: -0.01em; color: var(--text); text-decoration: none; }
.logo { width: 28px; height: 28px; border-radius: 8px; box-shadow: 0 2px 8px rgba(255, 122, 26, 0.35); }
.logo.large { width: 56px; height: 56px; border-radius: 14px; margin-bottom: 4px; }
nav { display: flex; gap: 2px; }
nav a { color: var(--text); text-decoration: none; padding: 7px 14px; border-radius: 999px; transition: background .15s; }
nav a:hover { background: rgba(255, 255, 255, 0.35); }
nav a.active { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); box-shadow: 0 6px 16px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
.spacer { flex: 1; }
#user { color: var(--muted); }
main { max-width: 1100px; margin: 0 auto; padding: 22px 12px 40px; }
h1 { font-size: 26px; letter-spacing: -0.02em; margin: 6px 0 16px; }
h2 { font-size: 17px; margin: 24px 0 10px; }
.card { padding: 18px 20px; margin-bottom: 14px; }
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 14px; }
.cards .card { margin: 0; }
.muted { color: var(--muted); }
.row { display: flex; align-items: center; gap: 12px; justify-content: space-between; padding: 8px 0; border-top: 1px solid var(--line); }
.row:first-of-type { border-top: 0; }
.row .name { flex: 1; }
.value { font-variant-numeric: tabular-nums; color: var(--muted); min-width: 52px; text-align: right; }

/* Controls */
button {
  font: inherit; padding: 8px 16px; border-radius: 999px; cursor: pointer; color: var(--text);
  background: var(--glass-strong); border: 1px solid var(--glass-edge); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.6), 0 2px 8px rgba(25, 34, 56, 0.08);
  -webkit-backdrop-filter: blur(16px); backdrop-filter: blur(16px); transition: transform .1s, box-shadow .15s;
}
button:hover { transform: translateY(-1px); }
button:active { transform: translateY(0); }
button.primary { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: rgba(255, 255, 255, 0.4); box-shadow: 0 8px 20px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
button.link { border: 0; background: none; box-shadow: none; backdrop-filter: none; color: var(--accent); padding: 4px 6px; }
button:disabled { opacity: .5; cursor: default; transform: none; }
input, select, textarea {
  font: inherit; color: var(--text); width: 100%; padding: 8px 12px; border-radius: 14px;
  background: rgba(255, 255, 255, 0.45); border: 1px solid var(--glass-edge); box-shadow: inset 0 1px 2px rgba(25, 34, 56, 0.08);
}
@media (prefers-color-scheme: dark) { input, select, textarea { background: rgba(0, 0, 0, 0.25); } }
input:focus, select:focus, textarea:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 4px rgba(255, 122, 26, 0.18); }
input[type=checkbox] { width: auto; box-shadow: none; }
input[type=range] { padding: 0; width: 160px; background: none; border: 0; box-shadow: none; accent-color: var(--accent); }
textarea { font-family: var(--mono); font-size: 13px; min-height: 420px; white-space: pre; border-radius: var(--radius); }
label { display: block; margin: 10px 0 6px; }
label > input, label > select { margin-top: 5px; }
.help { font-size: 13px; color: var(--muted); margin: 3px 0 0; }
.error { color: var(--error); min-height: 1.2em; }
.ok { color: var(--ok); }
.pill { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12px; border: 1px solid var(--glass-edge); background: rgba(255, 255, 255, 0.35); color: var(--muted); vertical-align: middle; }
.pill.on { color: var(--ok); border-color: rgba(31, 157, 85, 0.4); }
.banner { margin: 14px auto 0; max-width: 1100px; width: calc(100% - 24px); padding: 10px 20px; text-align: center; color: var(--warn); font-weight: 600; }
.auth { min-height: 100vh; display: grid; place-items: center; padding: 20px; }
.auth .card { width: min(400px, 100%); padding: 26px 26px 22px; }
.auth h1 { margin-top: 6px; }
.auth button { width: 100%; margin-top: 10px; }
.code { font-family: var(--mono); font-size: 30px; letter-spacing: 3px; margin: 10px 0; padding: 10px 16px; border-radius: 16px; display: inline-block; background: rgba(255, 255, 255, 0.4); border: 1px solid var(--glass-edge); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.6); }

/* Switch */
.switch { position: relative; width: 48px; height: 28px; margin: 0; flex: none; }
.switch input { opacity: 0; width: 0; height: 0; }
.switch span { position: absolute; inset: 0; border-radius: 14px; background: rgba(120, 128, 142, 0.35); border: 1px solid var(--glass-edge); transition: .18s; box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.15); }
.switch span::before { content: ""; position: absolute; width: 22px; height: 22px; left: 2px; top: 2px; border-radius: 50%; background: linear-gradient(180deg, #fff, #eef0f4); box-shadow: 0 2px 6px rgba(0, 0, 0, 0.25); transition: .18s; }
.switch input:checked + span { background: linear-gradient(180deg, var(--accent-2), var(--accent)); box-shadow: 0 4px 12px rgba(255, 122, 26, 0.4); }
.switch input:checked + span::before { transform: translateX(20px); }
.range { display: inline-flex; align-items: center; gap: 10px; }

/* Log */
.log { font-family: var(--mono); font-size: 12.5px; white-space: pre-wrap; word-break: break-all; padding: 14px 16px; max-height: 70vh; overflow: auto; }
.log .warning { color: var(--warn); }
.log .error, .log .critical { color: var(--error); }
.log .debug, .log .trace { color: var(--muted); }
.toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 14px; padding: 10px 14px; border-radius: 999px; }
.toolbar input, .toolbar select { width: auto; }
.toolbar label { margin: 0; display: inline-flex; align-items: center; gap: 6px; }

/* Forms */
fieldset { border: 1px solid var(--line); border-radius: 18px; padding: 8px 16px 14px; margin: 14px 0; background: rgba(255, 255, 255, 0.18); }
legend { color: var(--muted); padding: 0 8px; }
.item { border: 1px solid var(--line); border-radius: 16px; padding: 6px 14px 12px; margin: 10px 0; background: rgba(255, 255, 255, 0.2); }
.item-head { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
.actions { display: flex; gap: 10px; margin-top: 16px; align-items: center; }
details > summary { cursor: pointer; color: var(--muted); padding: 8px 0; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: 5px 16px; margin: 0; }
dt { color: var(--muted); }
dd { margin: 0; }
@media (prefers-reduced-transparency: reduce) { .card, header, .banner, .log, .toolbar, button { backdrop-filter: none; -webkit-backdrop-filter: none; background-image: none; background-color: var(--glass-strong); } }
@media (max-width: 640px) { header { gap: 8px; padding: 8px 10px; flex-wrap: wrap; border-radius: 24px; } nav a { padding: 6px 10px; } main { padding: 14px 10px 30px; } input[type=range] { width: 110px; } }

"""#),
    ]
}
