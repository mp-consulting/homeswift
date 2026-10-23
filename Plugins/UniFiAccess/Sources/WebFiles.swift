// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension UniFiAccessPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Access page, after the Homebridge plugin's settings UI: the configured controllers with their
// status, discovery of UniFi consoles on the network, adding or editing a controller (checked by logging in
// first), and the feature options editor (global, controller and device scopes, with the cascade, search,
// modified-only filter, values and reset). Saving writes this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, readBlock, updateBlock } = homeswift;

  const screens = ["controllers-screen", "discovery-screen", "setup-screen", "options-screen", "support-screen"];
  const categoryColors = { AccessMethod: "#fd7e14", Controller: "#6f42c1", Device: "#0d6efd", Hub: "#20c997", Log: "#6c757d" };
  const categoryLetters = { AccessMethod: "AM", Controller: "C", Device: "D", Hub: "H", Log: "L" };
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

  let block = null;          // this instance's block of config.json
  let editingIndex = null;   // the controller being edited, null when adding

  function show(id) {
    for (const screen of screens) $(`#${screen}`).classList.toggle("hidden", screen !== id);
    window.scrollTo({ top: 0, behavior: reducedMotion.matches ? "auto" : "smooth" });
  }

  /// Runs `work` with the button disabled and, when it takes a moment, its label changed (`homeswift.act` shows a
  /// spinner instead).
  async function act(button, busyText, work) {
    const label = button.textContent;
    button.disabled = true;
    const busy = setTimeout(() => { button.textContent = busyText; }, 150);
    try { return await work(); } finally {
      clearTimeout(busy);
      button.textContent = label;
      button.disabled = false;
    }
  }

  // MARK: The block in config.json

  /// Changes this instance's block and saves it: the plugin reloads with it.
  async function writeBlock(change) {
    let changed;
    const result = await updateBlock((current) => { change(current); changed = current; });
    block = changed;
    return result;
  }

  const controllers = () => (block && block.controllers) || [];

  // MARK: What the Assistant may see: no address, credentials, broker URL, IP or MAC address. The server masks
  // IP and MAC addresses in what it sends; a controller's host name is the page's to take out.

  function scrub(text, addresses = []) {
    let result = String(text ?? "");
    for (const address of addresses) if (typeof address === "string" && address.trim()) result = result.split(address.trim()).join("[address]");
    return result;
  }

  const assistantController = (ctrl) => ({
    mqttConfigured: !!ctrl?.mqttUrl, mqttVerifyTls: ctrl?.mqttVerifyTls !== false, name: ctrl?.name, verifyTls: ctrl?.verifyTls === true,
  });

  const assistantDevice = (device) => ({
    adopted: device?.is_adopted, connected: device?.is_connected, displayModel: device?.display_model, firmware: device?.firmware, model: device?.model,
    name: device?.name, online: !!device?.is_online, rebooting: device?.is_rebooting,
    capabilities: Array.isArray(device?.capabilities) ? device.capabilities.filter((c) => typeof c === "string").slice(0, 20) : undefined,
  });

  function deviceProblem(device) {
    if (!device || device.display_model === "controller") return null;
    if (device.is_rebooting) return "UniFi Access reports this device as rebooting.";
    if (!device.is_online) return "UniFi Access reports this device as disconnected.";
    return null;
  }

  // MARK: Controllers

  async function renderControllers() {
    const list = $("#controllers");
    const all = controllers();
    if (!all.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: "No controllers configured yet. Add one to get started." })));
      return;
    }
    let live = [];
    try { ({ controllers: live } = await request("controllers")); } catch { /* the plugin is not running */ }
    list.replaceChildren(...all.map((ctrl, index) => controllerCard(ctrl, index, live.find((c) => c.address === ctrl.address))));
  }

  function controllerCard(ctrl, index, live) {
    const status = el("span", { class: "pill status standby", text: "Checking…" });
    const slot = el("div");
    const liveText = live
      ? (live.connected ? `Connected · ${live.devices.length} device${live.devices.length === 1 ? "" : "s"} in HomeKit` : "Not connected yet: see the log.")
      : "";
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, icon()),
        el("div", { class: "who" }, el("strong", { text: ctrl.name || ctrl.address }), el("div", { class: "muted", text: ctrl.address })),
        status),
      liveText ? el("div", { class: "muted controller-live", text: liveText }) : null,
      el("div", { class: "controller-actions" },
        el("button", { class: "primary", text: "Feature options", onclick: () => openOptions(index) }),
        el("button", { text: "Edit", onclick: () => openSetup(index) }),
        el("button", { class: "danger", text: "Remove", onclick: (event) => removeController(event.currentTarget, index) })),
      slot);
    request("status", { method: "POST", body: { address: ctrl.address } }).then((result) => {
      status.className = `pill status ${result.online ? "on" : "away"}`;
      status.textContent = result.online ? "Online" : "Offline";
      if (!result.online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server), so it is shown as Offline.",
          context: "The user is looking at the list of configured UniFi Access controllers in the plugin's page.",
          device: assistantController(ctrl),
        }));
      }
    }).catch(() => {
      status.className = "pill status standby";
      status.textContent = "Unknown";
    });
    return card;
  }

  function icon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M7 20h10M12 16v4"/>';
    return svg;
  }

  async function removeController(button, index) {
    const ctrl = controllers()[index];
    if (!confirm(`Remove ${ctrl.name || ctrl.address}? Its devices leave HomeKit.`)) return;
    await act(button, "Removing…", async () => {
      try {
        await writeBlock((current) => { (current.controllers || []).splice(index, 1); });
      } catch (e) { alert(`Unable to remove the controller: ${e.message}`); }
    });
    renderControllers();
  }

  $("#add-controller").addEventListener("click", () => {
    $("#cancel-discovery").classList.toggle("hidden", !controllers().length);
    $("#discovered").replaceChildren();
    show("discovery-screen");
    breadcrumb("Add a controller", backToControllers);
  });
  $("#open-support").addEventListener("click", () => { show("support-screen"); breadcrumb("Support", backToControllers); });
  $("#back-from-support").addEventListener("click", backToControllers);

  function backToControllers() {
    if (!leaveOptions()) return;
    breadcrumb(null);
    show("controllers-screen");
    renderControllers();
  }

  // MARK: Discovery

  const discoveryContext = "Discovering UniFi consoles from the plugin's page with the Ubiquiti discovery protocol (UDP port 10001 broadcast on the local subnets plus a unicast scan of nearby /24 subnets, 5 seconds).";

  $("#discover").addEventListener("click", (event) => act(event.currentTarget, "Searching…", async () => {
    const container = $("#discovered");
    container.replaceChildren();
    try {
      const { devices } = await request("discover");
      const configured = controllers().map((c) => c.address);
      const available = devices.filter((d) => !configured.includes(d.ip));
      if (!available.length) {
        const message = devices.length ? "All discovered devices are already configured." : "No devices found. Make sure your UniFi console is on and connected.";
        container.replaceChildren(el("p", { class: `status-line ${devices.length ? "ok" : "error"}`, text: message }),
          devices.length ? null : explain({ error: message, context: discoveryContext }));
        return;
      }
      container.replaceChildren(el("h2", { text: "Found devices" }), el("div", { class: "found" }, available.map((device) =>
        el("div", { class: "card item", role: "button", tabIndex: 0, onclick: () => openSetup(null, device.ip), onkeydown: (e) => { if (e.key === "Enter") openSetup(null, device.ip); } },
          el("span", { class: "tile accessory", "aria-hidden": "true" }, icon()),
          el("div", {}, el("strong", { text: device.name }),
            el("div", { class: "muted", text: [device.ip, device.model, device.mac].filter(Boolean).join(" · ") })),
          el("span", { class: "pill", text: "Select" })))));
    } catch (e) {
      container.replaceChildren(el("p", { class: "status-line error", text: `Discovery error: ${e.message}` }),
        explain({ error: scrub(`Discovery error: ${e.message}`), context: discoveryContext }));
    }
  }));
  $("#manual-entry").addEventListener("click", () => openSetup(null));
  $("#cancel-discovery").addEventListener("click", backToControllers);

  // MARK: Adding or editing a controller

  function openSetup(index, prefill) {
    editingIndex = index;
    const ctrl = index === null ? {} : controllers()[index];
    $("#setup-title").textContent = index === null ? "Add a UniFi Access controller" : "Edit controller";
    $("#setup-subtitle").textContent = index === null ? "Enter your UniFi Access controller details and login credentials." : `Editing ${ctrl.name || ctrl.address}`;
    $("#address").value = prefill || ctrl.address || "";
    $("#username").value = ctrl.username || "";
    $("#password").value = ctrl.password || "";
    $("#ctrl-name").value = ctrl.name || "";
    $("#verify-tls").checked = ctrl.verifyTls === true;
    $("#mqtt-url").value = ctrl.mqttUrl || "";
    $("#mqtt-topic").value = ctrl.mqttTopic || "";
    $("#mqtt-verify-tls").checked = ctrl.mqttVerifyTls !== false;
    $("#advanced").open = !!(ctrl.name || ctrl.verifyTls || ctrl.mqttUrl || ctrl.mqttTopic || ctrl.mqttVerifyTls === false);
    say("");
    $("#setup-explain").replaceChildren();
    $("#cancel-setup").classList.toggle("hidden", index === null && !controllers().length);
    show("setup-screen");
    breadcrumb(index === null ? "Add a controller" : `Edit ${ctrl.name || ctrl.address}`, backToControllers);
    (prefill ? $("#username") : $("#address")).focus();
  }

  function say(text, kind = "error") {
    const line = $("#setup-status");
    line.textContent = text;
    line.className = `status-line ${text ? kind : ""}`;
  }

  /// The advanced settings into the entry, leaving out those at their default so the block stays tidy.
  function applyAdvanced(entry, hostname) {
    const settings = {
      mqttTopic: $("#mqtt-topic").value.trim(),
      mqttUrl: $("#mqtt-url").value.trim(),
      mqttVerifyTls: $("#mqtt-verify-tls").checked ? undefined : false,
      // The controller's hostname when no name is chosen.
      name: $("#ctrl-name").value.trim() || hostname,
      verifyTls: $("#verify-tls").checked ? true : undefined,
    };
    for (const [key, value] of Object.entries(settings)) {
      if (value === undefined || value === "") delete entry[key]; else entry[key] = value;
    }
    return entry;
  }

  $("#setup-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const address = $("#address").value.trim();
    const username = $("#username").value.trim();
    // Passwords may begin or end with spaces.
    const password = $("#password").value;
    if (!address || !username || !password) {
      say("Please fill in all fields.");
      return;
    }
    const explainError = (message) => $("#setup-explain").replaceChildren(explain({
      error: scrub(message, [address]),
      context: "Logging in to the UniFi Access controller and loading its devices (bootstrap) from the plugin's page failed.",
      device: assistantController({ mqttUrl: $("#mqtt-url").value.trim(), mqttVerifyTls: $("#mqtt-verify-tls").checked, verifyTls: $("#verify-tls").checked }),
    }));
    act($("#save-controller"), "Validating…", async () => {
      say("");
      $("#setup-explain").replaceChildren();
      try {
        const answer = await request("devices", { method: "POST", body: { address, username, password, verifyTls: $("#verify-tls").checked } });
        if (!answer.devices?.length) {
          const message = `Unable to connect. ${answer.error || "Check your address and credentials."}`;
          say(message);
          explainError(message);
          return;
        }
        const adding = editingIndex === null;
        const index = editingIndex;
        await writeBlock((current) => {
          current.controllers = current.controllers || [];
          const existing = adding ? {} : current.controllers[index] || {};
          const entry = applyAdvanced({ ...existing, address, username, password }, answer.devices[0]?.host?.hostname);
          if (adding) current.controllers.push(entry); else current.controllers[index] = entry;
        });
        breadcrumb(null);
        show("controllers-screen");
        $("#controllers-note").textContent = adding ? "Controller added." : "Controller updated.";
        renderControllers();
      } catch (e) {
        say(`Error: ${e.message}`);
        explainError(`Error: ${e.message}`);
      }
    });
  });
  $("#cancel-setup").addEventListener("click", () => (controllers().length ? backToControllers() : show("discovery-screen")));

  // MARK: Feature options

  const options = {
    categories: [], definitions: {}, devices: [], controllerIndex: null, controllerId: null,
    working: [], saved: "[]", open: new Set(),
  };

  const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const optionKey = (category, opt) => category.name + (opt.name ? `.${opt.name}` : "");

  async function openOptions(index) {
    options.controllerIndex = index;
    const ctrl = controllers()[index];
    options.working = [...(block.options || [])];
    options.saved = JSON.stringify(options.working);
    show("options-screen");
    breadcrumb(`Feature options of ${ctrl.name || ctrl.address}`, backToControllers);
    $("#options-title").textContent = `Feature options · ${ctrl.name || ctrl.address}`;
    $("#options-loading").classList.remove("hidden");
    $("#options").replaceChildren();
    $("#options-problem").replaceChildren();
    $("#device-problem").replaceChildren();
    $("#device-info").classList.add("hidden");
    $("#search").value = "";
    updateSaveBar();
    try {
      const [definitions, answer] = await Promise.all([
        request("options"),
        request("devices", { method: "POST", body: { address: ctrl.address, username: ctrl.username, password: ctrl.password, verifyTls: ctrl.verifyTls } }),
      ]);
      options.categories = definitions.categories;
      options.definitions = definitions.options;
      options.devices = [];
      options.controllerId = null;
      const devices = answer.devices || [];
      if (devices.length) {
        const controller = devices[0] || {};
        const host = controller.host || {};
        options.controllerId = (host.mac || "").replaceAll(":", "").toUpperCase() || null;
        options.controllerDevice = { display_model: "controller", ip: host.ip, is_online: true, mac: host.mac, model: host.device_type, name: ctrl.name || host.hostname || ctrl.address };
        for (const device of devices.slice(1)) {
          device.name ||= device.alias || device.display_model;
          device.serialNumber = (device.featureId ?? (device.mac || "").replaceAll(":", "")).toUpperCase();
          if (device.capabilities?.includes("is_hub") || device.capabilities?.includes("is_reader")) options.devices.push(device);
        }
      } else {
        showOptionsProblem(ctrl, `Unable to load the devices of this controller. ${answer.error || "Check its address and credentials."}`);
      }
      buildScopes(ctrl);
      renderOptions();
    } catch (e) {
      showOptionsProblem(ctrl, `Failed to load: ${e.message}`);
    } finally {
      $("#options-loading").classList.add("hidden");
    }
  }

  function showOptionsProblem(ctrl, message) {
    $("#options-problem").replaceChildren(el("div", { class: "card notice" }, el("p", { text: message }),
      explain({
        error: scrub(message, [ctrl?.address]),
        context: "Loading the devices of a configured UniFi Access controller for the feature options screen of the plugin's page failed.",
        device: assistantController(ctrl),
      })));
  }

  function buildScopes(ctrl) {
    const select = $("#scope");
    const previous = select.value;
    select.replaceChildren(el("option", { value: "global", text: "Global options" }));
    if (options.controllerId) select.append(el("option", { value: `controller:${options.controllerId}`, text: `Controller: ${ctrl.name || ctrl.address}` }));
    const hubs = options.devices.filter((d) => d.capabilities?.includes("is_hub"));
    // A device that is a hub and a reader is listed once, with the hubs.
    const readers = options.devices.filter((d) => d.capabilities?.includes("is_reader") && !d.capabilities.includes("is_hub"));
    for (const [label, items] of [["Hubs", hubs], ["Readers", readers]]) {
      if (!items.length) continue;
      select.append(el("optgroup", { label }, items.map((d) => el("option", { value: `device:${d.serialNumber}`, text: d.name }))));
    }
    if ([...select.options].some((o) => o.value === previous)) select.value = previous;
  }

  function currentScope() {
    const value = $("#scope").value || "global";
    if (value === "global") return { type: "global", id: null, device: null };
    const colon = value.indexOf(":");
    const type = value.slice(0, colon);
    const id = value.slice(colon + 1);
    if (type === "controller") return { type, id, device: null };
    return { type: "device", id, device: options.devices.find((d) => d.serialNumber === id) };
  }

  function updateCascade(type) {
    const order = ["global", "controller", "device"];
    const active = order.indexOf(type);
    const hints = {
      global: ["Editing this scope", "Inherits global", "Inherits global"],
      controller: ["Base values", "Editing this scope", "Inherits controller"],
      device: ["Base values", "Intermediate", "Editing this scope"],
    };
    document.querySelectorAll("#cascade .level").forEach((level, i) => {
      level.classList.toggle("active", i === active);
      level.classList.toggle("inherited", i < active);
      level.querySelector(".hint").textContent = hints[type][i];
    });
    document.querySelectorAll("#cascade .connector").forEach((connector, i) => connector.classList.toggle("active", i < active));
  }

  /// Whether the option has an entry at this scope.
  function isModified(key, scopeId) {
    const pattern = scopeId
      ? new RegExp(`^(Enable|Disable)\\.${escapeRegex(key)}\\.${escapeRegex(scopeId)}(\\..*)?$`, "i")
      : new RegExp(`^(Enable|Disable)\\.${escapeRegex(key)}(?:\\.\\d+)?$`, "i");
    return options.working.some((entry) => pattern.test(entry));
  }

  /// The option's state at a scope: its own entry, else the controller's (for a device), the global one, the default.
  function optionState(key, opt, scope) {
    const find = (id, scopeName, explicit) => {
      const pattern = new RegExp(`^(Enable|Disable)\\.${escapeRegex(key)}${id ? `\\.${escapeRegex(id)}` : ""}(?:\\.(\\d+))?$`, "i");
      for (const entry of options.working) {
        const match = pattern.exec(entry);
        if (match) return { enabled: match[1].toLowerCase() === "enable", explicit, scope: scopeName, value: match[2] };
      }
      return null;
    };
    if (scope.id) {
      const own = find(scope.id, scope.type, true);
      if (own) return own;
    }
    if (scope.type === "device" && options.controllerId) {
      const inherited = find(options.controllerId, "controller", false);
      if (inherited) return inherited;
    }
    return find(null, "global", scope.type === "global") ?? { enabled: opt.default, explicit: false, scope: "default" };
  }

  /// The options of a category that apply to the scope's device and match the search; null when the category does not apply.
  function categoryOptions(category, scope, search) {
    const device = scope.device;
    const has = (required) => !required || (!!device?.capabilities && required.some((c) => device.capabilities.includes(c)));
    if (device && (!(category.modelKey || []).some((m) => ["all", device.display_model].includes(m)) || !has(category.hasCapability))) return null;
    return (options.definitions[category.name] || []).filter((opt) => {
      if (device && (!has(opt.hasCapability) || (opt.modelKey && opt.modelKey !== "all" && !opt.modelKey.includes(device.display_model)))) return false;
      return !search || `${opt.name} ${opt.description}`.toLowerCase().includes(search);
    });
  }

  function renderOptions() {
    const container = $("#options");
    const scope = currentScope();
    updateCascade(scope.type);
    const search = $("#search").value.toLowerCase();
    const modifiedOnly = $("#modified-only").checked;
    renderDeviceInfo(scope);

    let totalModified = 0;
    const cards = [];
    for (const category of options.categories) {
      let list = categoryOptions(category, scope, search);
      if (!list?.length) continue;
      const enabled = list.filter((opt) => optionState(optionKey(category, opt), opt, scope).enabled).length;
      const modified = list.filter((opt) => isModified(optionKey(category, opt), scope.id)).length;
      totalModified += modified;
      if (modifiedOnly) {
        list = list.filter((opt) => isModified(optionKey(category, opt), scope.id));
        if (!list.length) continue;
      }
      const isOpen = options.open.has(category.name) || (modified > 0 && !options.open.size) || !!search;
      const card = el("div", { class: `card category ${isOpen ? "open" : ""}` });
      card.style.setProperty("--category", categoryColors[category.name] || "#6c757d");
      const head = el("div", { class: "category-head", role: "button", tabIndex: 0, "aria-expanded": String(isOpen) },
        el("span", { class: "category-icon", text: categoryLetters[category.name] || "•" }),
        el("span", { class: "title", text: category.description.replace(/ feature options\.?/i, "") }),
        el("span", { class: "count", text: `${enabled}/${list.length} on` }),
        el("span", { class: "progress" }, el("span", {})),
        modified ? el("span", { class: "pill", text: String(modified) }) : null,
        el("span", { class: "chevron", text: "›" }));
      head.querySelector(".progress span").style.setProperty("--progress", String(list.length ? enabled / list.length : 0));
      const toggle = () => {
        card.classList.toggle("open");
        head.setAttribute("aria-expanded", String(card.classList.contains("open")));
        if (card.classList.contains("open")) options.open.add(category.name); else options.open.delete(category.name);
      };
      head.addEventListener("click", toggle);
      head.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); } });
      card.append(head, el("div", { class: "category-body" }, list.map((opt) => optionRow(category, opt, scope))));
      cards.push(card);
    }
    if (!cards.length) {
      cards.push(el("p", { class: "muted", text: modifiedOnly ? "No modified options" : search ? "No options match your search" : "No options available" }));
    }
    container.replaceChildren(...cards);
    $("#modified-count").textContent = totalModified ? `(${totalModified})` : "";
    $("#modified-count").className = totalModified ? "modified" : "";
  }

  function renderDeviceInfo(scope) {
    const panel = $("#device-info");
    const device = scope.device;
    if (!device) {
      panel.classList.add("hidden");
      $("#device-problem").replaceChildren();
      return;
    }
    panel.classList.remove("hidden");
    panel.replaceChildren(el("div", { class: "facts info" },
      el("div", { class: "fact" }, el("span", { text: "Model" }), el("b", { text: device.model || device.display_model || "—" })),
      el("div", { class: "fact" }, el("span", { text: "Serial" }), el("b", { text: device.serialNumber })),
      el("div", { class: "fact" }, el("span", { text: "IP" }), el("b", { text: device.ip || "N/A" })),
      el("div", { class: "fact" }, el("span", { text: "Status" }), el("b", { class: device.is_online ? "ok" : "error", text: device.is_online ? "Connected" : "Disconnected" }))));
    const problem = deviceProblem(device);
    $("#device-problem").replaceChildren(...(problem ? [explain({
      error: problem,
      context: "The user is looking at the feature options of a UniFi Access device in the plugin's page.",
      device: assistantDevice(device),
    })] : []));
  }

  function optionRow(category, opt, scope) {
    const key = optionKey(category, opt);
    const state = optionState(key, opt, scope);
    const grouped = opt.group && opt.name !== opt.group;
    let scopeClass = "";
    if (state.explicit) scopeClass = `scope-${scope.type}`;
    else if (state.scope === "controller") scopeClass = "scope-controller";
    else if (state.scope === "global" && scope.type !== "global") scopeClass = "scope-global";
    const label = opt.name || category.description.replace(/ feature options\.?/i, "");
    const checkbox = el("input", { type: "checkbox", checked: state.enabled, "aria-label": key });
    checkbox.addEventListener("change", () => { setOption(key, checkbox.checked, scope, opt); renderOptions(); });
    const badge = state.explicit
      ? el("span", { class: "badge scope", text: scope.type })
      : state.scope === "controller" ? el("span", { class: "badge inherited", text: "↓ controller" })
        : state.scope === "global" && scope.type !== "global" ? el("span", { class: "badge inherited", text: "↓ global" }) : null;
    let valueRow = null;
    if (opt.defaultValue !== undefined && state.enabled) {
      const unit = (opt.description.match(/\bin (seconds?|minutes?|hours?)\b/i) || [])[1] || "";
      const input = el("input", { type: "number", min: "0", step: "1", value: String(state.value ?? opt.defaultValue), "aria-label": `${key} value` });
      input.addEventListener("change", () => {
        const value = parseInt(input.value, 10);
        if (!isNaN(value) && value >= 0) { setOption(key, true, scope, opt, value); renderOptions(); }
      });
      valueRow = el("div", { class: "value-row" }, input, unit ? el("span", { class: "muted", text: unit }) : null,
        el("span", { class: "muted", text: `(default: ${opt.defaultValue})` }));
    }
    const row = el("div", { class: `option ${scopeClass} ${grouped ? "grouped" : ""}` },
      el("label", { class: "switch" }, checkbox, el("span")),
      el("div", { class: "text" },
        el("div", { class: "name" }, el("span", { text: label }),
          el("span", { class: `badge ${opt.default ? "default-on" : ""}`, text: `default: ${opt.default ? "on" : "off"}` }), badge),
        el("div", { class: "description", text: opt.description }),
        valueRow),
      state.explicit ? el("button", { class: "reset", text: "Reset", title: "Reset to the inherited value", onclick: () => { removeOption(key, scope); renderOptions(); } }) : null);
    return row;
  }

  function setOption(key, enabled, scope, opt, value) {
    const suffix = scope.id ? `.${scope.id}` : "";
    const remove = new RegExp(`^(Enable|Disable)\\.${escapeRegex(key)}${scope.id ? `\\.${escapeRegex(scope.id)}` : ""}(?:\\.\\d+)?$`, "i");
    options.working = options.working.filter((entry) => !remove.test(entry));
    // An entry only when it differs from what the scope inherits.
    const inherited = optionState(key, opt, scope);
    const valueDiffers = value !== undefined && value !== opt.defaultValue;
    if (inherited.enabled !== enabled || valueDiffers) {
      options.working.push(`${enabled ? "Enable" : "Disable"}.${key}${suffix}${enabled && valueDiffers ? `.${value}` : ""}`);
    }
    updateSaveBar();
  }

  function removeOption(key, scope) {
    const remove = new RegExp(`^(Enable|Disable)\\.${escapeRegex(key)}${scope.id ? `\\.${escapeRegex(scope.id)}` : ""}(?:\\.\\d+)?$`, "i");
    options.working = options.working.filter((entry) => !remove.test(entry));
    updateSaveBar();
  }

  const optionsDirty = () => JSON.stringify(options.working) !== options.saved;
  function updateSaveBar() { $("#options-save").classList.toggle("hidden", !optionsDirty()); }

  /// Leaving the options screen: false when the person keeps unsaved changes.
  function leaveOptions() {
    if ($("#options-screen").classList.contains("hidden") || !optionsDirty()) return true;
    if (!confirm("Discard the changes to the feature options?")) return false;
    options.working = JSON.parse(options.saved);
    updateSaveBar();
    return true;
  }

  let searchTimer = null;
  $("#search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderOptions, 300); });
  $("#scope").addEventListener("change", renderOptions);
  $("#modified-only").addEventListener("change", renderOptions);
  $("#back-from-options").addEventListener("click", backToControllers);
  $("#discard-options").addEventListener("click", () => { options.working = JSON.parse(options.saved); updateSaveBar(); renderOptions(); });
  $("#save-options").addEventListener("click", (event) => act(event.currentTarget, "Saving…", async () => {
    try {
      const working = [...options.working];
      await writeBlock((current) => { if (working.length) current.options = working; else delete current.options; });
      options.saved = JSON.stringify(working);
      updateSaveBar();
    } catch (e) { alert(`Unable to save the feature options: ${e.message}`); }
  }));
  addEventListener("beforeunload", (event) => { if (!$("#options-screen").classList.contains("hidden") && optionsDirty()) event.preventDefault(); });

  // MARK: Start

  (async () => {
    try {
      block = await readBlock();
    } catch (e) {
      $("#controllers").replaceChildren(el("p", { class: "error", text: e.message }));
      show("controllers-screen");
      return;
    }
    if (controllers().length) {
      show("controllers-screen");
      renderControllers();
    } else {
      $("#cancel-discovery").classList.add("hidden");
      show("discovery-screen");
    }
  })();
})();

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UniFi Access</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's screens on the UI's materials: the controllers, discovery, adding or editing a
     controller, and the feature options editor with its scope cascade, one screen showing at a time. */

  .screen { animation: fade var(--normal) var(--ease-out); }
  .page-head { align-items: center; }
  .controllers { display: grid; gap: 10px; }
  .controller { margin: 0; display: grid; gap: 10px; }
  .controller-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .controller-head .who { flex: 1; min-width: 0; }
  .controller-head strong { display: block; font-size: 1.0625rem; letter-spacing: -0.01em; overflow-wrap: anywhere; }
  .controller-head .muted { font-size: 0.8125rem; overflow-wrap: anywhere; }
  .controller-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
  .controller-live { font-size: 0.8125rem; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  .found { display: grid; gap: 8px; margin: 14px 0 0; }
  .found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; cursor: pointer; }
  .found .item div { flex: 1; min-width: 0; }
  .found .item .muted { font-size: 0.8125rem; }
  .note-box { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.875rem; }
  .form { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px 16px; }
  .form .wide { grid-column: 1 / -1; }
  .check { display: flex; align-items: flex-start; gap: 12px; margin: 14px 0 0; }
  .check label { margin: 0; }
  details.advanced { margin-top: 16px; }
  details.advanced > summary { color: var(--accent); font-weight: 500; cursor: pointer; }
  .status-line.error { color: var(--error); }
  .status-line.ok { color: var(--ok); }

  /* Feature options: the scope on the left, the options on the right. */
  .options-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 2.2fr); gap: 16px; align-items: start; }
  .scope-side { position: sticky; top: 12px; display: grid; gap: 12px; }
  .scope-side .card { margin: 0; padding: 14px 16px; }
  .scope-side label { margin: 0 0 6px; font-size: 0.8125rem; color: var(--muted); }
  .cascade { display: grid; gap: 0; }
  .level { display: flex; align-items: center; gap: 10px; padding: 6px 0; opacity: 0.35; transition: opacity var(--normal) var(--ease-out); }
  .level.active, .level.inherited { opacity: 1; }
  .level .dot { width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-size: 0.75rem; font-weight: 700; background: var(--material-thin); border: 1px solid var(--edge); }
  .level.active .dot { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
  .level .label { font-weight: 600; font-size: 0.875rem; }
  .level .hint { font-size: 0.75rem; color: var(--muted); }
  .connector { width: 2px; height: 10px; margin-left: 13px; background: var(--line); }
  .connector.active { background: var(--accent); }
  .facts.info { grid-template-columns: 1fr; }
  .legend { display: grid; gap: 4px; font-size: 0.75rem; }
  .legend span { display: inline-flex; align-items: center; gap: 8px; }
  .bar { display: inline-block; width: 14px; height: 4px; border-radius: 2px; }
  .bar.global, .option.scope-global { --scope: #e0a800; }
  .bar.controller, .option.scope-controller { --scope: #198754; }
  .bar.device, .option.scope-device { --scope: #0aa2c0; }
  .bar { background: var(--scope); }
  .option-tools { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; flex-wrap: wrap; }
  .option-tools input[type=search] { flex: 1; min-width: 180px; }
  .category { margin: 0 0 12px; padding: 0; overflow: hidden; }
  .category-head { display: flex; align-items: center; gap: 10px; padding: 12px 16px; cursor: pointer; user-select: none; }
  .category-head .title { flex: 1; font-weight: 600; }
  .category-icon { width: 26px; height: 26px; border-radius: 8px; display: grid; place-items: center; color: #fff; font-size: 0.75rem; font-weight: 700; background: var(--category); }
  .progress { width: 60px; height: 5px; border-radius: 3px; background: var(--material-thin); border: 1px solid var(--line); overflow: hidden; }
  .progress span { display: block; height: 100%; width: calc(var(--progress, 0) * 100%); background: var(--category); }
  .count { font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }
  .chevron { transition: transform var(--normal) var(--ease-out); color: var(--muted); }
  .category.open .chevron { transform: rotate(90deg); }
  .category-body { display: none; border-top: 1px solid var(--line); }
  .category.open .category-body { display: block; }
  .option { display: flex; gap: 12px; align-items: flex-start; padding: 12px 16px; border-top: 1px solid var(--line); border-left: 3px solid var(--scope, transparent); }
  .option:first-child { border-top: 0; }
  .option.grouped { padding-left: 34px; }
  .option .text { flex: 1; min-width: 0; }
  .option .name { font-weight: 600; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .option .description { font-size: 0.8125rem; color: var(--muted); margin-top: 2px; }
  .option .value-row { display: flex; align-items: center; gap: 8px; margin-top: 8px; font-size: 0.8125rem; }
  .option .value-row input { width: 110px; }
  .badge { font-size: 0.6875rem; font-weight: 600; padding: 1px 8px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
  .badge.default-on { color: var(--ok); }
  .badge.scope { color: #fff; border-color: transparent; background: var(--scope, var(--muted)); }
  .badge.inherited { color: var(--scope, var(--muted)); border-color: var(--scope, var(--line)); background: none; }
  .reset { padding: 4px 10px; font-size: 0.8125rem; }
  .modified { color: var(--warn); font-weight: 600; }
  .support a { color: var(--accent); }
  .support li { margin: 6px 0; }

  @media (prefers-reduced-motion: reduce) { .screen { animation: none; } .level, .chevron { transition: none; } }
  @media (max-width: 760px) {
    .options-layout { grid-template-columns: 1fr; }
    .scope-side { position: static; }
    .form { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/"><img src="/icon.svg" class="logo" alt="">Homeswift</a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 21V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v17"/><path d="M3 21h18"/><circle cx="15" cy="12.5" r="1"/></svg></span>
    <div>
      <h1>UniFi Access</h1>
      <p class="muted">Manage your UniFi Access controllers and devices in HomeKit.</p>
    </div>
  </div>

  <!-- Controllers -->
  <section id="controllers-screen" class="screen hidden">
    <div class="section-head"><h2>Configured controllers</h2><span class="muted" id="controllers-note"></span></div>
    <div id="controllers" class="controllers"></div>
    <div class="actions" style="margin-top: 14px">
      <button class="primary" id="add-controller">Add controller</button>
      <button id="open-support">Support</button>
    </div>
  </section>

  <!-- Discovery -->
  <section id="discovery-screen" class="screen hidden">
    <div class="card">
      <h2 style="margin-top: 0">Discover your controller</h2>
      <p class="muted">Scan your network for UniFi Access controllers, or enter the address manually.</p>
      <p class="note-box">Make sure your UniFi console is powered on and connected to the same network.</p>
      <div class="actions" style="margin-top: 14px">
        <button class="primary" id="discover">Discover controllers</button>
        <button id="manual-entry">Manual entry</button>
        <button class="link" id="cancel-discovery">Cancel</button>
      </div>
      <div id="discovered"></div>
    </div>
  </section>

  <!-- Add or edit a controller -->
  <section id="setup-screen" class="screen hidden">
    <form class="card" id="setup-form" novalidate>
      <h2 style="margin-top: 0" id="setup-title">Add a UniFi Access controller</h2>
      <p class="muted" id="setup-subtitle">Enter your UniFi Access controller details and login credentials.</p>
      <div class="form">
        <label class="wide">Controller<input id="address" placeholder="Hostname or IP (e.g. unvr.local)" autocomplete="off" spellcheck="false"><span class="help">The address of your UniFi Access controller.</span></label>
        <label>Username<input id="username" autocomplete="username" placeholder="Local user account username"></label>
        <label>Password<input id="password" type="password" autocomplete="current-password" placeholder="Local user account password"></label>
      </div>
      <details class="advanced" id="advanced">
        <summary>Advanced settings</summary>
        <div class="form">
          <label class="wide">Name<input id="ctrl-name" placeholder="Defaults to the controller's name"><span class="help">Used to identify this controller in the log.</span></label>
        </div>
        <div class="check">
          <input type="checkbox" id="verify-tls">
          <label for="verify-tls">Verify the controller's TLS certificate against trusted certificate authorities<span class="help">Leave this off unless your controller uses a CA-signed certificate. When off, the controller's self-signed certificate is pinned the first time Homeswift connects, and any later change is refused.</span></label>
        </div>
        <div class="form">
          <label>MQTT broker<input id="mqtt-url" placeholder="e.g. mqtt://user:password@1.2.3.4" spellcheck="false"><span class="help">MQTT support is enabled only when a broker URL is provided.</span></label>
          <label>MQTT topic<input id="mqtt-topic" placeholder="unifi/access" spellcheck="false"></label>
        </div>
        <div class="check">
          <input type="checkbox" id="mqtt-verify-tls" checked>
          <label for="mqtt-verify-tls">Verify the MQTT broker's TLS certificate<span class="help">Only turn this off if your mqtts:// broker uses a self-signed certificate.</span></label>
        </div>
      </details>
      <p class="note-box"><strong>Local account required.</strong> Ubiquiti.com and UI.com accounts are not supported. Create one in the <em>Admins &amp; Users</em> tab of your UniFi console.</p>
      <p class="status-line" id="setup-status"></p>
      <div id="setup-explain"></div>
      <div class="save-bar">
        <span class="muted">Homeswift logs in to check the details before saving them.</span>
        <button type="button" id="cancel-setup">Cancel</button>
        <button type="submit" class="primary" id="save-controller">Save controller</button>
      </div>
    </form>
  </section>

  <!-- Feature options -->
  <section id="options-screen" class="screen hidden">
    <div class="section-head"><h2 id="options-title">Feature options</h2><button class="link" id="back-from-options">Back</button></div>
    <div class="options-layout">
      <aside class="scope-side">
        <div class="card"><label for="scope">Scope</label><select id="scope"></select></div>
        <div class="card cascade" id="cascade">
          <div class="level" data-scope="global"><span class="dot">G</span><div><div class="label">Global</div><div class="hint">All devices</div></div></div>
          <div class="connector"></div>
          <div class="level" data-scope="controller"><span class="dot">C</span><div><div class="label">Controller</div><div class="hint">Overrides global</div></div></div>
          <div class="connector"></div>
          <div class="level" data-scope="device"><span class="dot">D</span><div><div class="label">Device</div><div class="hint">Final value</div></div></div>
        </div>
        <div class="card hidden" id="device-info"></div>
        <div class="card legend">
          <strong>Legend</strong>
          <span><i class="bar global"></i>Set at global</span>
          <span><i class="bar controller"></i>Set at controller</span>
          <span><i class="bar device"></i>Set at device</span>
        </div>
      </aside>
      <div>
        <div class="option-tools">
          <input type="search" id="search" placeholder="Search options…" aria-label="Search options">
          <label class="toggle compact"><span class="switch"><input type="checkbox" id="modified-only"><span></span></span><span class="muted">Modified <span id="modified-count"></span></span></label>
        </div>
        <p class="muted" id="options-loading">Loading options…</p>
        <div id="options-problem"></div>
        <div id="device-problem"></div>
        <div id="options"></div>
        <div class="card save-bar hidden" id="options-save">
          <span class="dirty">Unsaved changes to the feature options.</span>
          <button id="discard-options">Discard</button>
          <button class="primary" id="save-options">Save</button>
        </div>
      </div>
    </div>
  </section>

  <!-- Support -->
  <section id="support-screen" class="screen hidden">
    <div class="section-head"><h2>Support</h2><button class="link" id="back-from-support">Back</button></div>
    <div class="card support">
      <h2 style="margin-top: 0">About this plugin</h2>
      <p>A port of <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access">homebridge-unifi-access</a> to <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift">Homeswift</a>. If you find it useful, consider starring the projects on GitHub.</p>
      <h2>Getting started</h2>
      <ul>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/blob/main/Plugins/UniFiAccess/README.md">Installation and configuration</a> in Homeswift, and what differs from Homebridge.</li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/FeatureOptions.md">Feature options</a>: options to set per controller or device.</li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/MQTT.md">MQTT</a>: the topics published and accepted.</li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/CHANGELOG.md">Changelog</a> of the Homebridge plugin this one follows.</li>
      </ul>
      <h2>Get help</h2>
      <ul>
        <li><a target="_blank" rel="noopener noreferrer" href="https://discord.gg/QXqfHEW">Discord support channel</a> of the UniFi plugins.</li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/issues/new/choose">Create a developer support request</a> for the Homebridge plugin's behaviour, or <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/issues/new">open an issue on Homeswift</a> for this port.</li>
        <li>The Homeswift log (the Logs page) shows what the plugin sees; feature option <code>Log.*</code> entries turn event logging on and off.</li>
      </ul>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
