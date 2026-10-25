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
  const { t, tn } = HomeswiftI18n;

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
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No controllers configured yet. Add one to get started.") })));
      return;
    }
    let live = [];
    try { ({ controllers: live } = await request("controllers")); } catch { /* the plugin is not running */ }
    list.replaceChildren(...all.map((ctrl, index) => controllerCard(ctrl, index, live.find((c) => c.address === ctrl.address))));
  }

  function controllerCard(ctrl, index, live) {
    const status = el("span", { class: "pill status standby", text: t("Checking…") });
    const slot = el("div");
    const liveText = live
      ? (live.connected ? tn("Connected · {n} device in HomeKit", "Connected · {n} devices in HomeKit", live.devices.length) : t("Not connected yet: see the log."))
      : "";
    // The card's actions in its menu, bottom right, as on the other pages' cards.
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("inputs")),
        el("div", { class: "who" }, el("strong", { text: ctrl.name || ctrl.address }), el("div", { class: "muted", text: ctrl.address })),
        status),
      slot,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: liveText || t("Not running") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: ctrl.name || ctrl.address }), () => [
          { label: t("Feature options"), icon: "sliders", onSelect: () => openOptions(index) },
          { label: t("Edit"), icon: "edit", onSelect: () => openSetup(index) },
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => removeController(index) },
        ])));
    request("status", { method: "POST", body: { address: ctrl.address } }).then((result) => {
      status.className = `pill status ${result.online ? "on" : "away"}`;
      status.textContent = result.online ? t("Online") : t("Offline");
      if (!result.online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server), so it is shown as Offline.",
          context: "The user is looking at the list of configured UniFi Access controllers in the plugin's page.",
          device: assistantController(ctrl),
        }));
      }
    }).catch(() => {
      status.className = "pill status standby";
      status.textContent = t("Unknown");
    });
    return card;
  }

  async function removeController(index) {
    const ctrl = controllers()[index];
    if (!confirm(t("Remove {name}? Its devices leave HomeKit.", { name: ctrl.name || ctrl.address }))) return;
    try {
      await writeBlock((current) => { (current.controllers || []).splice(index, 1); });
    } catch (e) { alert(t("Unable to remove the controller: {message}", { message: e.message })); }
    renderControllers();
  }

  $("#add-controller").addEventListener("click", () => {
    $("#cancel-discovery").classList.toggle("hidden", !controllers().length);
    $("#discovered").replaceChildren();
    show("discovery-screen");
    breadcrumb(t("Add a controller"), backToControllers);
  });
  $("#open-support").addEventListener("click", () => { show("support-screen"); breadcrumb(t("Support"), backToControllers); });
  $("#back-from-support").addEventListener("click", backToControllers);

  function backToControllers() {
    if (!leaveOptions()) return;
    breadcrumb(null);
    show("controllers-screen");
    renderControllers();
  }

  // MARK: Discovery

  const discoveryContext = "Discovering UniFi consoles from the plugin's page with the Ubiquiti discovery protocol (UDP port 10001 broadcast on the local subnets plus a unicast scan of nearby /24 subnets, 5 seconds).";

  $("#discover").addEventListener("click", (event) => act(event.currentTarget, t("Searching…"), async () => {
    const container = $("#discovered");
    container.replaceChildren();
    try {
      const { devices } = await request("discover");
      const configured = controllers().map((c) => c.address);
      const available = devices.filter((d) => !configured.includes(d.ip));
      if (!available.length) {
        const message = devices.length ? t("All discovered devices are already configured.") : t("No devices found. Make sure your UniFi console is on and connected.");
        container.replaceChildren(el("p", { class: `status-line ${devices.length ? "ok" : "error"}`, text: message }),
          devices.length ? null : explain({ error: message, context: discoveryContext }));
        return;
      }
      container.replaceChildren(el("h2", { text: t("Found devices") }), el("div", { class: "found" }, available.map((device) =>
        el("button", { type: "button", class: "card item", onclick: () => openSetup(null, device.ip) },
          el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("inputs")),
          el("div", {}, el("strong", { text: device.name }),
            el("div", { class: "muted", text: [device.ip, device.model, device.mac].filter(Boolean).join(" · ") })),
          el("span", { class: "pill", text: t("Select") })))));
    } catch (e) {
      container.replaceChildren(el("p", { class: "status-line error", text: t("Discovery error: {message}", { message: e.message }) }),
        explain({ error: scrub(`Discovery error: ${e.message}`), context: discoveryContext }));
    }
  }));
  $("#manual-entry").addEventListener("click", () => openSetup(null));
  $("#cancel-discovery").addEventListener("click", backToControllers);

  // MARK: Adding or editing a controller

  function openSetup(index, prefill) {
    editingIndex = index;
    const ctrl = index === null ? {} : controllers()[index];
    $("#setup-title").textContent = index === null ? t("Add a UniFi Access controller") : t("Edit controller");
    $("#setup-subtitle").textContent = index === null ? t("Enter your UniFi Access controller details and login credentials.") : t("Editing {name}", { name: ctrl.name || ctrl.address });
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
    breadcrumb(index === null ? t("Add a controller") : t("Edit {name}", { name: ctrl.name || ctrl.address }), backToControllers);
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
      say(t("Please fill in all fields."));
      return;
    }
    const explainError = (message) => $("#setup-explain").replaceChildren(explain({
      error: scrub(message, [address]),
      context: "Logging in to the UniFi Access controller and loading its devices (bootstrap) from the plugin's page failed.",
      device: assistantController({ mqttUrl: $("#mqtt-url").value.trim(), mqttVerifyTls: $("#mqtt-verify-tls").checked, verifyTls: $("#verify-tls").checked }),
    }));
    act($("#save-controller"), t("Validating…"), async () => {
      say("");
      $("#setup-explain").replaceChildren();
      try {
        const answer = await request("devices", { method: "POST", body: { address, username, password, verifyTls: $("#verify-tls").checked } });
        if (!answer.devices?.length) {
          const message = t("Unable to connect. {reason}", { reason: answer.error ? HomeswiftI18n.message(answer.error) : t("Check your address and credentials.") });
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
        $("#controllers-note").textContent = adding ? t("Controller added.") : t("Controller updated.");
        renderControllers();
      } catch (e) {
        say(t("Error: {message}", { message: e.message }));
        explainError(t("Error: {message}", { message: e.message }));
      }
    });
  });
  $("#cancel-setup").addEventListener("click", () => (controllers().length ? backToControllers() : show("discovery-screen")));

  // MARK: Feature options

  const options = {
    categories: [], definitions: {}, devices: [], controllerIndex: null, controllerId: null,
    working: [], saved: "[]", open: new Set(),
  };

  /// A scope's name on the badge of an option set at that scope.
  const scopeNames = { global: t("global"), controller: t("controller"), device: t("device") };
  const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const optionKey = (category, opt) => category.name + (opt.name ? `.${opt.name}` : "");

  async function openOptions(index) {
    options.controllerIndex = index;
    const ctrl = controllers()[index];
    options.working = [...(block.options || [])];
    options.saved = JSON.stringify(options.working);
    show("options-screen");
    breadcrumb(t("Feature options of {name}", { name: ctrl.name || ctrl.address }), backToControllers);
    $("#options-title").textContent = t("Feature options · {name}", { name: ctrl.name || ctrl.address });
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
        showOptionsProblem(ctrl, t("Unable to load the devices of this controller. {reason}", { reason: answer.error ? HomeswiftI18n.message(answer.error) : t("Check its address and credentials.") }));
      }
      buildScopes(ctrl);
      renderOptions();
    } catch (e) {
      showOptionsProblem(ctrl, t("Failed to load: {message}", { message: e.message }));
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
    select.replaceChildren(el("option", { value: "global", text: t("Global options") }));
    if (options.controllerId) select.append(el("option", { value: `controller:${options.controllerId}`, text: t("Controller: {name}", { name: ctrl.name || ctrl.address }) }));
    const hubs = options.devices.filter((d) => d.capabilities?.includes("is_hub"));
    // A device that is a hub and a reader is listed once, with the hubs.
    const readers = options.devices.filter((d) => d.capabilities?.includes("is_reader") && !d.capabilities.includes("is_hub"));
    for (const [label, items] of [[t("Hubs"), hubs], [t("Readers"), readers]]) {
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
      global: [t("Editing this scope"), t("Inherits global"), t("Inherits global")],
      controller: [t("Base values"), t("Editing this scope"), t("Inherits controller")],
      device: [t("Base values"), t("Intermediate"), t("Editing this scope")],
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
        el("span", { class: "count", text: t("{enabled}/{total} on", { enabled, total: list.length }) }),
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
      cards.push(el("p", { class: "muted", text: modifiedOnly ? t("No modified options") : search ? t("No options match your search") : t("No options available") }));
    }
    container.replaceChildren(...cards);
    $("#modified-only").disabled = totalModified === 0 && !$("#modified-only").checked;
    $("#modified-only").closest("label").title = $("#modified-only").disabled ? t("No modified options match the current search.") : "";
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
      el("div", { class: "fact" }, el("span", { text: t("Model") }), el("b", { text: device.model || device.display_model || "—" })),
      el("div", { class: "fact" }, el("span", { text: t("Serial") }), el("b", { text: device.serialNumber })),
      el("div", { class: "fact" }, el("span", { text: "IP" }), el("b", { text: device.ip || t("N/A") })),
      el("div", { class: "fact" }, el("span", { text: t("Status") }), el("b", { class: device.is_online ? "ok" : "error", text: device.is_online ? t("Connected") : t("Disconnected") }))));
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
      ? el("span", { class: "badge scope", text: scopeNames[scope.type] ?? scope.type })
      : state.scope === "controller" ? el("span", { class: "badge inherited", text: t("↓ controller") })
        : state.scope === "global" && scope.type !== "global" ? el("span", { class: "badge inherited", text: t("↓ global") }) : null;
    let valueRow = null;
    if (opt.defaultValue !== undefined && state.enabled) {
      const unit = (opt.description.match(/\bin (seconds?|minutes?|hours?)\b/i) || [])[1] || "";
      const units = { second: t("second"), seconds: t("seconds"), minute: t("minute"), minutes: t("minutes"), hour: t("hour"), hours: t("hours") };
      const input = el("input", { type: "number", min: "0", step: "1", value: String(state.value ?? opt.defaultValue), "aria-label": t("{key} value", { key }) });
      input.addEventListener("change", () => {
        const value = parseInt(input.value, 10);
        if (!isNaN(value) && value >= 0) { setOption(key, true, scope, opt, value); renderOptions(); }
      });
      valueRow = el("div", { class: "value-row" }, input, unit ? el("span", { class: "muted", text: units[unit.toLowerCase()] ?? unit }) : null,
        el("span", { class: "muted", text: t("(default: {value})", { value: opt.defaultValue }) }));
    }
    const row = el("div", { class: `option ${scopeClass} ${grouped ? "grouped" : ""}` },
      el("label", { class: "switch" }, checkbox, el("span")),
      el("div", { class: "text" },
        el("div", { class: "name" }, el("span", { text: label }),
          el("span", { class: `badge ${opt.default ? "default-on" : ""}`, text: opt.default ? t("default: on") : t("default: off") }), badge),
        el("div", { class: "description", text: opt.description }),
        valueRow),
      state.explicit ? el("button", { actionIcon: "restore", class: "reset", text: t("Reset"), title: t("Reset to the inherited value"), onclick: () => { removeOption(key, scope); renderOptions(); } }) : null);
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
    if (!confirm(t("Discard the changes to the feature options?"))) return false;
    options.working = JSON.parse(options.saved);
    updateSaveBar();
    return true;
  }

  $("#search").parentElement.append(HomeswiftCommon.clearFilters([[$("#search"), ""], [$("#modified-only"), false]]));
  let searchTimer = null;
  $("#search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderOptions, 300); });
  $("#scope").addEventListener("change", renderOptions);
  $("#modified-only").addEventListener("change", renderOptions);
  $("#back-from-options").addEventListener("click", backToControllers);
  $("#discard-options").addEventListener("click", () => { options.working = JSON.parse(options.saved); updateSaveBar(); renderOptions(); });
  $("#save-options").addEventListener("click", (event) => act(event.currentTarget, t("Saving…"), async () => {
    try {
      const working = [...options.working];
      await writeBlock((current) => { if (working.length) current.options = working; else delete current.options; });
      options.saved = JSON.stringify(working);
      updateSaveBar();
    } catch (e) { alert(t("Unable to save the feature options: {message}", { message: e.message })); }
  }));
  addEventListener("beforeunload", (event) => { if (!$("#options-screen").classList.contains("hidden") && optionsDirty()) event.preventDefault(); });

  // MARK: Sentences of the page with elements in them (links, code): the translation's {0}, {1}… are the
  // element's children, in order. The links have data-i18n for their own text.

  function sentence(node, text) {
    const parts = [...node.children];
    node.replaceChildren(...text.split(/\{(\d+)\}/).map((part, i) => (i % 2 ? parts[Number(part)] : part)));
  }
  sentence($("#local-account"), t("{0} Ubiquiti.com and UI.com accounts are not supported. Create one in the {1} tab of your UniFi console."));
  sentence($("#support-about"), t("A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub."));
  sentence($("#support-readme"), t("{0} in Homeswift, and what differs from Homebridge."));
  sentence($("#support-options"), t("{0}: options to set per controller or device."));
  sentence($("#support-mqtt"), t("{0}: the topics published and accepted."));
  sentence($("#support-changelog"), t("{0} of the Homebridge plugin this one follows."));
  sentence($("#support-discord"), t("{0} of the UniFi plugins."));
  sentence($("#support-issues"), t("{0} for the Homebridge plugin's behaviour, or {1} for this port."));
  sentence($("#support-log"), t("The Homeswift log (the Logs page) shows what the plugin sees; feature option {0} entries turn event logging on and off."));

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
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Access page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Gérez vos contrôleurs et appareils UniFi Access dans HomeKit.",
    "Configured controllers": "Contrôleurs configurés",
    "Add controller": "Ajouter un contrôleur",
    "Support": "Assistance",
    "Discover your controller": "Trouvez votre contrôleur",
    "Scan your network for UniFi Access controllers, or enter the address manually.": "Recherchez les contrôleurs UniFi Access sur votre réseau, ou saisissez l'adresse manuellement.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Vérifiez que votre console UniFi est allumée et connectée au même réseau.",
    "Discover controllers": "Rechercher des contrôleurs",
    "Manual entry": "Saisie manuelle",
    "Cancel": "Annuler",
    "Add a UniFi Access controller": "Ajouter un contrôleur UniFi Access",
    "Enter your UniFi Access controller details and login credentials.": "Saisissez les informations de votre contrôleur UniFi Access et vos identifiants de connexion.",
    "Controller": "Contrôleur",
    "Hostname or IP (e.g. unvr.local)": "Nom d'hôte ou IP (p. ex. unvr.local)",
    "The address of your UniFi Access controller.": "L'adresse de votre contrôleur UniFi Access.",
    "Username": "Nom d'utilisateur",
    "Local user account username": "Nom d'utilisateur du compte local",
    "Password": "Mot de passe",
    "Local user account password": "Mot de passe du compte local",
    "Advanced settings": "Réglages avancés",
    "Name": "Nom",
    "Defaults to the controller's name": "Par défaut, le nom du contrôleur",
    "Used to identify this controller in the log.": "Sert à reconnaître ce contrôleur dans le journal.",
    "Verify the controller's TLS certificate against trusted certificate authorities": "Vérifier le certificat TLS du contrôleur auprès des autorités de certification de confiance",
    "Leave this off unless your controller uses a CA-signed certificate. When off, the controller's self-signed certificate is pinned the first time Homeswift connects, and any later change is refused.": "Laissez cette option désactivée sauf si votre contrôleur utilise un certificat signé par une autorité. Désactivée, le certificat autosigné du contrôleur est épinglé à la première connexion de Homeswift, et tout changement ultérieur est refusé.",
    "MQTT broker": "Broker MQTT",
    "e.g. mqtt://user:password@1.2.3.4": "p. ex. mqtt://user:password@1.2.3.4",
    "MQTT support is enabled only when a broker URL is provided.": "La prise en charge de MQTT n'est activée que si une URL de broker est indiquée.",
    "MQTT topic": "Sujet MQTT",
    "Verify the MQTT broker's TLS certificate": "Vérifier le certificat TLS du broker MQTT",
    "Only turn this off if your mqtts:// broker uses a self-signed certificate.": "Ne désactivez cette option que si votre broker mqtts:// utilise un certificat autosigné.",
    "Local account required.": "Compte local requis.",
    "{0} Ubiquiti.com and UI.com accounts are not supported. Create one in the {1} tab of your UniFi console.": "{0} Les comptes Ubiquiti.com et UI.com ne sont pas pris en charge. Créez-en un dans l'onglet {1} de votre console UniFi.",
    "Homeswift logs in to check the details before saving them.": "Homeswift se connecte pour vérifier ces informations avant de les enregistrer.",
    "Save controller": "Enregistrer le contrôleur",
    "Feature options": "Options des fonctions",
    "Back": "Retour",
    "Scope": "Portée",
    "Global": "Global",
    "All devices": "Tous les appareils",
    "Overrides global": "Remplace le réglage global",
    "Device": "Appareil",
    "Final value": "Valeur finale",
    "Legend": "Légende",
    "Set at global": "Défini au niveau global",
    "Set at controller": "Défini au niveau du contrôleur",
    "Set at device": "Défini au niveau de l'appareil",
    "Search options…": "Rechercher des options…",
    "Search options": "Rechercher des options",
    "Modified": "Modifiées",
    "Loading options…": "Chargement des options…",
    "Unsaved changes to the feature options.": "Modifications des options non enregistrées.",
    "Discard": "Annuler les modifications",
    "Save": "Enregistrer",
    "About this plugin": "À propos de ce plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Un portage de {0} vers {1}. S'il vous est utile, pensez à mettre une étoile aux projets sur GitHub.",
    "Getting started": "Premiers pas",
    "Installation and configuration": "Installation et configuration",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} dans Homeswift, et ce qui diffère de Homebridge.",
    "{0}: options to set per controller or device.": "{0} : options à régler par contrôleur ou par appareil.",
    "{0}: the topics published and accepted.": "{0} : les sujets publiés et acceptés.",
    "Changelog": "Historique des versions",
    "{0} of the Homebridge plugin this one follows.": "{0} du plugin Homebridge que celui-ci suit.",
    "Get help": "Obtenir de l'aide",
    "Discord support channel": "Canal d'assistance Discord",
    "{0} of the UniFi plugins.": "{0} des plugins UniFi.",
    "Create a developer support request": "Créez une demande d'assistance aux développeurs",
    "open an issue on Homeswift": "ouvrez un ticket sur Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} pour le comportement du plugin Homebridge, ou {1} pour ce portage.",
    "The Homeswift log (the Logs page) shows what the plugin sees; feature option {0} entries turn event logging on and off.": "Le journal de Homeswift (la page Journaux) montre ce que voit le plugin ; les entrées d'option {0} activent et désactivent la journalisation des événements.",
    "No controllers configured yet. Add one to get started.": "Aucun contrôleur configuré pour l'instant. Ajoutez-en un pour commencer.",
    "Checking…": "Vérification…",
    "Connected · {n} device in HomeKit": "Connecté · {n} appareil dans HomeKit",
    "Connected · {n} devices in HomeKit": "Connecté · {n} appareils dans HomeKit",
    "Not connected yet: see the log.": "Pas encore connecté : consultez le journal.",
    "Not running": "Arrêté",
    "Actions for {name}": "Actions pour {name}",
    "Edit": "Modifier",
    "Remove": "Supprimer",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Unknown": "Inconnu",
    "Remove {name}? Its devices leave HomeKit.": "Supprimer {name} ? Ses appareils quittent HomeKit.",
    "Unable to remove the controller: {message}": "Impossible de supprimer le contrôleur : {message}",
    "Add a controller": "Ajouter un contrôleur",
    "Searching…": "Recherche…",
    "All discovered devices are already configured.": "Tous les appareils trouvés sont déjà configurés.",
    "No devices found. Make sure your UniFi console is on and connected.": "Aucun appareil trouvé. Vérifiez que votre console UniFi est allumée et connectée.",
    "Found devices": "Appareils trouvés",
    "Select": "Choisir",
    "Discovery error: {message}": "Erreur de recherche : {message}",
    "Edit controller": "Modifier le contrôleur",
    "Editing {name}": "Modification de {name}",
    "Edit {name}": "Modifier {name}",
    "Please fill in all fields.": "Remplissez tous les champs.",
    "Validating…": "Vérification…",
    "Unable to connect. {reason}": "Connexion impossible. {reason}",
    "Check your address and credentials.": "Vérifiez votre adresse et vos identifiants.",
    "Controller added.": "Contrôleur ajouté.",
    "Controller updated.": "Contrôleur mis à jour.",
    "Error: {message}": "Erreur : {message}",
    "global": "global",
    "controller": "contrôleur",
    "device": "appareil",
    "Feature options of {name}": "Options des fonctions de {name}",
    "Feature options · {name}": "Options des fonctions · {name}",
    "Unable to load the devices of this controller. {reason}": "Impossible de charger les appareils de ce contrôleur. {reason}",
    "Check its address and credentials.": "Vérifiez son adresse et ses identifiants.",
    "Failed to load: {message}": "Échec du chargement : {message}",
    "Global options": "Options globales",
    "Controller: {name}": "Contrôleur : {name}",
    "Hubs": "Hubs",
    "Readers": "Lecteurs",
    "Editing this scope": "Portée en cours de modification",
    "Inherits global": "Hérite du réglage global",
    "Base values": "Valeurs de base",
    "Inherits controller": "Hérite du contrôleur",
    "Intermediate": "Intermédiaire",
    "{enabled}/{total} on": "{enabled}/{total} activées",
    "No modified options": "Aucune option modifiée",
    "No options match your search": "Aucune option ne correspond à votre recherche",
    "No options available": "Aucune option disponible",
    "Model": "Modèle",
    "Serial": "N° de série",
    "N/A": "N/D",
    "Status": "État",
    "Connected": "Connecté",
    "Disconnected": "Déconnecté",
    "↓ controller": "↓ contrôleur",
    "↓ global": "↓ global",
    "second": "seconde",
    "seconds": "secondes",
    "minute": "minute",
    "minutes": "minutes",
    "hour": "heure",
    "hours": "heures",
    "{key} value": "Valeur de {key}",
    "(default: {value})": "(par défaut : {value})",
    "default: on": "par défaut : activée",
    "default: off": "par défaut : désactivée",
    "Reset": "Rétablir",
    "Reset to the inherited value": "Rétablir la valeur héritée",
    "Discard the changes to the feature options?": "Annuler les modifications des options ?",
    "Saving…": "Enregistrement…",
    "Unable to save the feature options: {message}": "Impossible d'enregistrer les options : {message}",
    "Invalid controller address. Please provide a valid network address.": "Adresse du contrôleur non valide. Indiquez une adresse réseau valide."
  },
  "es": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Gestiona tus controladores y dispositivos UniFi Access en HomeKit.",
    "Configured controllers": "Controladores configurados",
    "Add controller": "Añadir controlador",
    "Support": "Soporte",
    "Discover your controller": "Descubre tu controlador",
    "Scan your network for UniFi Access controllers, or enter the address manually.": "Busca controladores UniFi Access en tu red o introduce la dirección manualmente.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Comprueba que tu consola UniFi está encendida y conectada a la misma red.",
    "Discover controllers": "Buscar controladores",
    "Manual entry": "Introducción manual",
    "Cancel": "Cancelar",
    "Add a UniFi Access controller": "Añadir un controlador UniFi Access",
    "Enter your UniFi Access controller details and login credentials.": "Introduce los datos de tu controlador UniFi Access y las credenciales de acceso.",
    "Controller": "Controlador",
    "Hostname or IP (e.g. unvr.local)": "Nombre de host o IP (p. ej., unvr.local)",
    "The address of your UniFi Access controller.": "La dirección de tu controlador UniFi Access.",
    "Username": "Nombre de usuario",
    "Local user account username": "Nombre de usuario de la cuenta local",
    "Password": "Contraseña",
    "Local user account password": "Contraseña de la cuenta local",
    "Advanced settings": "Ajustes avanzados",
    "Name": "Nombre",
    "Defaults to the controller's name": "De forma predeterminada, el nombre del controlador",
    "Used to identify this controller in the log.": "Sirve para identificar este controlador en el registro.",
    "Verify the controller's TLS certificate against trusted certificate authorities": "Verificar el certificado TLS del controlador con autoridades de certificación de confianza",
    "Leave this off unless your controller uses a CA-signed certificate. When off, the controller's self-signed certificate is pinned the first time Homeswift connects, and any later change is refused.": "Déjalo desactivado salvo que tu controlador use un certificado firmado por una autoridad. Si está desactivado, el certificado autofirmado del controlador se fija la primera vez que Homeswift se conecta y se rechaza cualquier cambio posterior.",
    "MQTT broker": "Bróker MQTT",
    "e.g. mqtt://user:password@1.2.3.4": "p. ej., mqtt://user:password@1.2.3.4",
    "MQTT support is enabled only when a broker URL is provided.": "MQTT solo se activa si se indica la URL de un bróker.",
    "MQTT topic": "Tema MQTT",
    "Verify the MQTT broker's TLS certificate": "Verificar el certificado TLS del bróker MQTT",
    "Only turn this off if your mqtts:// broker uses a self-signed certificate.": "Desactívalo solo si tu bróker mqtts:// usa un certificado autofirmado.",
    "Local account required.": "Se necesita una cuenta local.",
    "{0} Ubiquiti.com and UI.com accounts are not supported. Create one in the {1} tab of your UniFi console.": "{0} Las cuentas de Ubiquiti.com y UI.com no son compatibles. Crea una en la pestaña {1} de tu consola UniFi.",
    "Homeswift logs in to check the details before saving them.": "Homeswift inicia sesión para comprobar los datos antes de guardarlos.",
    "Save controller": "Guardar controlador",
    "Feature options": "Opciones de funciones",
    "Back": "Volver",
    "Scope": "Ámbito",
    "Global": "Global",
    "All devices": "Todos los dispositivos",
    "Overrides global": "Sustituye al global",
    "Device": "Dispositivo",
    "Final value": "Valor final",
    "Legend": "Leyenda",
    "Set at global": "Definido en global",
    "Set at controller": "Definido en el controlador",
    "Set at device": "Definido en el dispositivo",
    "Search options…": "Buscar opciones…",
    "Search options": "Buscar opciones",
    "Modified": "Modificadas",
    "Loading options…": "Cargando opciones…",
    "Unsaved changes to the feature options.": "Cambios sin guardar en las opciones.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca de este plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Una adaptación de {0} a {1}. Si te resulta útil, plantéate dar una estrella a los proyectos en GitHub.",
    "Getting started": "Primeros pasos",
    "Installation and configuration": "Instalación y configuración",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} en Homeswift y lo que cambia respecto a Homebridge.",
    "{0}: options to set per controller or device.": "{0}: opciones que ajustar por controlador o dispositivo.",
    "{0}: the topics published and accepted.": "{0}: los temas publicados y aceptados.",
    "Changelog": "Historial de cambios",
    "{0} of the Homebridge plugin this one follows.": "{0} del plugin de Homebridge que este sigue.",
    "Get help": "Obtener ayuda",
    "Discord support channel": "Canal de soporte en Discord",
    "{0} of the UniFi plugins.": "{0} de los plugins de UniFi.",
    "Create a developer support request": "Crea una solicitud de soporte a los desarrolladores",
    "open an issue on Homeswift": "abre una incidencia en Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} sobre el comportamiento del plugin de Homebridge, o {1} sobre esta adaptación.",
    "The Homeswift log (the Logs page) shows what the plugin sees; feature option {0} entries turn event logging on and off.": "El registro de Homeswift (la página Registros) muestra lo que ve el plugin; las entradas de opción {0} activan y desactivan el registro de eventos.",
    "No controllers configured yet. Add one to get started.": "Aún no hay controladores configurados. Añade uno para empezar.",
    "Checking…": "Comprobando…",
    "Connected · {n} device in HomeKit": "Conectado · {n} dispositivo en HomeKit",
    "Connected · {n} devices in HomeKit": "Conectado · {n} dispositivos en HomeKit",
    "Not connected yet: see the log.": "Aún sin conectar: consulta el registro.",
    "Not running": "Detenido",
    "Actions for {name}": "Acciones de {name}",
    "Edit": "Editar",
    "Remove": "Eliminar",
    "Online": "Conectado",
    "Offline": "Desconectado",
    "Unknown": "Desconocido",
    "Remove {name}? Its devices leave HomeKit.": "¿Eliminar {name}? Sus dispositivos saldrán de HomeKit.",
    "Unable to remove the controller: {message}": "No se ha podido eliminar el controlador: {message}",
    "Add a controller": "Añadir un controlador",
    "Searching…": "Buscando…",
    "All discovered devices are already configured.": "Todos los dispositivos encontrados ya están configurados.",
    "No devices found. Make sure your UniFi console is on and connected.": "No se han encontrado dispositivos. Comprueba que tu consola UniFi está encendida y conectada.",
    "Found devices": "Dispositivos encontrados",
    "Select": "Elegir",
    "Discovery error: {message}": "Error de búsqueda: {message}",
    "Edit controller": "Editar controlador",
    "Editing {name}": "Editando {name}",
    "Edit {name}": "Editar {name}",
    "Please fill in all fields.": "Rellena todos los campos.",
    "Validating…": "Validando…",
    "Unable to connect. {reason}": "No se ha podido conectar. {reason}",
    "Check your address and credentials.": "Comprueba la dirección y las credenciales.",
    "Controller added.": "Controlador añadido.",
    "Controller updated.": "Controlador actualizado.",
    "Error: {message}": "Error: {message}",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "Feature options of {name}": "Opciones de funciones de {name}",
    "Feature options · {name}": "Opciones de funciones · {name}",
    "Unable to load the devices of this controller. {reason}": "No se han podido cargar los dispositivos de este controlador. {reason}",
    "Check its address and credentials.": "Comprueba su dirección y sus credenciales.",
    "Failed to load: {message}": "Error al cargar: {message}",
    "Global options": "Opciones globales",
    "Controller: {name}": "Controlador: {name}",
    "Hubs": "Hubs",
    "Readers": "Lectores",
    "Editing this scope": "Ámbito en edición",
    "Inherits global": "Hereda del global",
    "Base values": "Valores base",
    "Inherits controller": "Hereda del controlador",
    "Intermediate": "Intermedio",
    "{enabled}/{total} on": "{enabled}/{total} activadas",
    "No modified options": "No hay opciones modificadas",
    "No options match your search": "Ninguna opción coincide con tu búsqueda",
    "No options available": "No hay opciones disponibles",
    "Model": "Modelo",
    "Serial": "N.º de serie",
    "N/A": "N/D",
    "Status": "Estado",
    "Connected": "Conectado",
    "Disconnected": "Desconectado",
    "↓ controller": "↓ controlador",
    "↓ global": "↓ global",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "{key} value": "Valor de {key}",
    "(default: {value})": "(predeterminado: {value})",
    "default: on": "predeterminado: activada",
    "default: off": "predeterminado: desactivada",
    "Reset": "Restablecer",
    "Reset to the inherited value": "Restablecer el valor heredado",
    "Discard the changes to the feature options?": "¿Descartar los cambios de las opciones?",
    "Saving…": "Guardando…",
    "Unable to save the feature options: {message}": "No se han podido guardar las opciones: {message}",
    "Invalid controller address. Please provide a valid network address.": "La dirección del controlador no es válida. Indica una dirección de red válida."
  },
  "pt": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Faça a gestão dos controladores e dispositivos UniFi Access no HomeKit.",
    "Configured controllers": "Controladores configurados",
    "Add controller": "Adicionar controlador",
    "Support": "Suporte",
    "Discover your controller": "Descubra o seu controlador",
    "Scan your network for UniFi Access controllers, or enter the address manually.": "Procure controladores UniFi Access na sua rede ou introduza o endereço manualmente.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Verifique se a consola UniFi está ligada e na mesma rede.",
    "Discover controllers": "Procurar controladores",
    "Manual entry": "Introdução manual",
    "Cancel": "Cancelar",
    "Add a UniFi Access controller": "Adicionar um controlador UniFi Access",
    "Enter your UniFi Access controller details and login credentials.": "Introduza os dados do controlador UniFi Access e as credenciais de acesso.",
    "Controller": "Controlador",
    "Hostname or IP (e.g. unvr.local)": "Nome do anfitrião ou IP (p. ex. unvr.local)",
    "The address of your UniFi Access controller.": "O endereço do controlador UniFi Access.",
    "Username": "Nome de utilizador",
    "Local user account username": "Nome de utilizador da conta local",
    "Password": "Palavra-passe",
    "Local user account password": "Palavra-passe da conta local",
    "Advanced settings": "Definições avançadas",
    "Name": "Nome",
    "Defaults to the controller's name": "Por predefinição, o nome do controlador",
    "Used to identify this controller in the log.": "Serve para identificar este controlador no registo.",
    "Verify the controller's TLS certificate against trusted certificate authorities": "Verificar o certificado TLS do controlador junto de autoridades de certificação fidedignas",
    "Leave this off unless your controller uses a CA-signed certificate. When off, the controller's self-signed certificate is pinned the first time Homeswift connects, and any later change is refused.": "Deixe desativado, a menos que o controlador use um certificado assinado por uma autoridade. Se estiver desativado, o certificado autoassinado do controlador é fixado na primeira ligação do Homeswift e qualquer alteração posterior é recusada.",
    "MQTT broker": "Broker MQTT",
    "e.g. mqtt://user:password@1.2.3.4": "p. ex. mqtt://user:password@1.2.3.4",
    "MQTT support is enabled only when a broker URL is provided.": "O MQTT só é ativado quando é indicado o URL de um broker.",
    "MQTT topic": "Tópico MQTT",
    "Verify the MQTT broker's TLS certificate": "Verificar o certificado TLS do broker MQTT",
    "Only turn this off if your mqtts:// broker uses a self-signed certificate.": "Desative apenas se o broker mqtts:// usar um certificado autoassinado.",
    "Local account required.": "É necessária uma conta local.",
    "{0} Ubiquiti.com and UI.com accounts are not supported. Create one in the {1} tab of your UniFi console.": "{0} As contas Ubiquiti.com e UI.com não são suportadas. Crie uma no separador {1} da consola UniFi.",
    "Homeswift logs in to check the details before saving them.": "O Homeswift inicia sessão para verificar os dados antes de os guardar.",
    "Save controller": "Guardar controlador",
    "Feature options": "Opções de funcionalidades",
    "Back": "Voltar",
    "Scope": "Âmbito",
    "Global": "Global",
    "All devices": "Todos os dispositivos",
    "Overrides global": "Substitui o global",
    "Device": "Dispositivo",
    "Final value": "Valor final",
    "Legend": "Legenda",
    "Set at global": "Definido no global",
    "Set at controller": "Definido no controlador",
    "Set at device": "Definido no dispositivo",
    "Search options…": "Procurar opções…",
    "Search options": "Procurar opções",
    "Modified": "Modificadas",
    "Loading options…": "A carregar as opções…",
    "Unsaved changes to the feature options.": "Alterações às opções não guardadas.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca deste plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Uma adaptação de {0} para {1}. Se lhe for útil, considere dar uma estrela aos projetos no GitHub.",
    "Getting started": "Primeiros passos",
    "Installation and configuration": "Instalação e configuração",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} no Homeswift e o que difere do Homebridge.",
    "{0}: options to set per controller or device.": "{0}: opções a definir por controlador ou dispositivo.",
    "{0}: the topics published and accepted.": "{0}: os tópicos publicados e aceites.",
    "Changelog": "Histórico de alterações",
    "{0} of the Homebridge plugin this one follows.": "{0} do plugin do Homebridge que este segue.",
    "Get help": "Obter ajuda",
    "Discord support channel": "Canal de suporte no Discord",
    "{0} of the UniFi plugins.": "{0} dos plugins UniFi.",
    "Create a developer support request": "Crie um pedido de suporte aos programadores",
    "open an issue on Homeswift": "abra um problema no Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} sobre o comportamento do plugin do Homebridge, ou {1} sobre esta adaptação.",
    "The Homeswift log (the Logs page) shows what the plugin sees; feature option {0} entries turn event logging on and off.": "O registo do Homeswift (a página Registos) mostra o que o plugin vê; as entradas de opção {0} ativam e desativam o registo de eventos.",
    "No controllers configured yet. Add one to get started.": "Ainda não há controladores configurados. Adicione um para começar.",
    "Checking…": "A verificar…",
    "Connected · {n} device in HomeKit": "Ligado · {n} dispositivo no HomeKit",
    "Connected · {n} devices in HomeKit": "Ligado · {n} dispositivos no HomeKit",
    "Not connected yet: see the log.": "Ainda não ligado: consulte o registo.",
    "Not running": "Parado",
    "Actions for {name}": "Ações de {name}",
    "Edit": "Editar",
    "Remove": "Remover",
    "Online": "Online",
    "Offline": "Offline",
    "Unknown": "Desconhecido",
    "Remove {name}? Its devices leave HomeKit.": "Remover {name}? Os seus dispositivos saem do HomeKit.",
    "Unable to remove the controller: {message}": "Não foi possível remover o controlador: {message}",
    "Add a controller": "Adicionar um controlador",
    "Searching…": "A procurar…",
    "All discovered devices are already configured.": "Todos os dispositivos encontrados já estão configurados.",
    "No devices found. Make sure your UniFi console is on and connected.": "Nenhum dispositivo encontrado. Verifique se a consola UniFi está ligada e na rede.",
    "Found devices": "Dispositivos encontrados",
    "Select": "Escolher",
    "Discovery error: {message}": "Erro de procura: {message}",
    "Edit controller": "Editar controlador",
    "Editing {name}": "A editar {name}",
    "Edit {name}": "Editar {name}",
    "Please fill in all fields.": "Preencha todos os campos.",
    "Validating…": "A validar…",
    "Unable to connect. {reason}": "Não foi possível ligar. {reason}",
    "Check your address and credentials.": "Verifique o endereço e as credenciais.",
    "Controller added.": "Controlador adicionado.",
    "Controller updated.": "Controlador atualizado.",
    "Error: {message}": "Erro: {message}",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "Feature options of {name}": "Opções de funcionalidades de {name}",
    "Feature options · {name}": "Opções de funcionalidades · {name}",
    "Unable to load the devices of this controller. {reason}": "Não foi possível carregar os dispositivos deste controlador. {reason}",
    "Check its address and credentials.": "Verifique o endereço e as credenciais.",
    "Failed to load: {message}": "Falha ao carregar: {message}",
    "Global options": "Opções globais",
    "Controller: {name}": "Controlador: {name}",
    "Hubs": "Hubs",
    "Readers": "Leitores",
    "Editing this scope": "Âmbito em edição",
    "Inherits global": "Herda do global",
    "Base values": "Valores base",
    "Inherits controller": "Herda do controlador",
    "Intermediate": "Intermédio",
    "{enabled}/{total} on": "{enabled}/{total} ativadas",
    "No modified options": "Nenhuma opção modificada",
    "No options match your search": "Nenhuma opção corresponde à procura",
    "No options available": "Nenhuma opção disponível",
    "Model": "Modelo",
    "Serial": "N.º de série",
    "N/A": "N/D",
    "Status": "Estado",
    "Connected": "Ligado",
    "Disconnected": "Desligado",
    "↓ controller": "↓ controlador",
    "↓ global": "↓ global",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "{key} value": "Valor de {key}",
    "(default: {value})": "(predefinição: {value})",
    "default: on": "predefinição: ativada",
    "default: off": "predefinição: desativada",
    "Reset": "Repor",
    "Reset to the inherited value": "Repor o valor herdado",
    "Discard the changes to the feature options?": "Descartar as alterações às opções?",
    "Saving…": "A guardar…",
    "Unable to save the feature options: {message}": "Não foi possível guardar as opções: {message}",
    "Invalid controller address. Please provide a valid network address.": "Endereço do controlador inválido. Indique um endereço de rede válido."
  }
});

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
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  .found { display: grid; gap: 8px; margin: 14px 0 0; }
  .found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; cursor: pointer; width: 100%; text-align: left; font: inherit; color: inherit; }
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
  .category-head:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  @media (hover: hover) and (pointer: fine) { .category-head:hover { background: var(--material-thin); } }
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
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 21V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v17"/><path d="M3 21h18"/><circle cx="15" cy="12.5" r="1"/></svg></span>
    <div>
      <h1>UniFi Access</h1>
      <p class="muted" data-i18n>Manage your UniFi Access controllers and devices in HomeKit.</p>
    </div>
  </div>

  <!-- Controllers -->
  <section id="controllers-screen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Configured controllers</h2><span class="muted" id="controllers-note"></span></div>
    <div id="controllers" class="controllers"></div>
    <div class="actions" style="margin-top: 14px">
      <button class="primary" id="add-controller" data-i18n data-action-icon="plus">Add controller</button>
      <button id="open-support" data-i18n>Support</button>
    </div>
  </section>

  <!-- Discovery -->
  <section id="discovery-screen" class="screen hidden">
    <div class="card">
      <h2 style="margin-top: 0" data-i18n>Discover your controller</h2>
      <p class="muted" data-i18n>Scan your network for UniFi Access controllers, or enter the address manually.</p>
      <p class="note-box" data-i18n>Make sure your UniFi console is powered on and connected to the same network.</p>
      <div class="actions" style="margin-top: 14px">
        <button class="primary" id="discover" data-i18n data-action-icon="search">Discover controllers</button>
        <button id="manual-entry" data-i18n>Manual entry</button>
        <button class="link" id="cancel-discovery" data-i18n data-action-icon="close">Cancel</button>
      </div>
      <div id="discovered"></div>
    </div>
  </section>

  <!-- Add or edit a controller -->
  <section id="setup-screen" class="screen hidden">
    <form class="card" id="setup-form" novalidate>
      <h2 style="margin-top: 0" id="setup-title" data-i18n>Add a UniFi Access controller</h2>
      <p class="muted" id="setup-subtitle" data-i18n>Enter your UniFi Access controller details and login credentials.</p>
      <div class="form">
        <label class="wide" data-i18n>Controller<input id="address" data-i18n placeholder="Hostname or IP (e.g. unvr.local)" autocomplete="off" spellcheck="false"><span class="help" data-i18n>The address of your UniFi Access controller.</span></label>
        <label data-i18n>Username<input id="username" autocomplete="username" data-i18n placeholder="Local user account username"></label>
        <label data-i18n>Password<input id="password" type="password" autocomplete="current-password" data-i18n placeholder="Local user account password"></label>
      </div>
      <details class="advanced" id="advanced">
        <summary data-i18n>Advanced settings</summary>
        <div class="form">
          <label class="wide" data-i18n>Name<input id="ctrl-name" data-i18n placeholder="Defaults to the controller's name"><span class="help" data-i18n>Used to identify this controller in the log.</span></label>
        </div>
        <div class="check">
          <input type="checkbox" id="verify-tls">
          <label for="verify-tls" data-i18n>Verify the controller's TLS certificate against trusted certificate authorities<span class="help" data-i18n>Leave this off unless your controller uses a CA-signed certificate. When off, the controller's self-signed certificate is pinned the first time Homeswift connects, and any later change is refused.</span></label>
        </div>
        <div class="form">
          <label data-i18n>MQTT broker<input id="mqtt-url" data-i18n placeholder="e.g. mqtt://user:password@1.2.3.4" spellcheck="false"><span class="help" data-i18n>MQTT support is enabled only when a broker URL is provided.</span></label>
          <label data-i18n>MQTT topic<input id="mqtt-topic" placeholder="unifi/access" spellcheck="false"></label>
        </div>
        <div class="check">
          <input type="checkbox" id="mqtt-verify-tls" checked>
          <label for="mqtt-verify-tls" data-i18n>Verify the MQTT broker's TLS certificate<span class="help" data-i18n>Only turn this off if your mqtts:// broker uses a self-signed certificate.</span></label>
        </div>
      </details>
      <p class="note-box" id="local-account"><strong data-i18n>Local account required.</strong> Ubiquiti.com and UI.com accounts are not supported. Create one in the <em>Admins &amp; Users</em> tab of your UniFi console.</p>
      <p class="status-line" id="setup-status"></p>
      <div id="setup-explain"></div>
      <div class="save-bar">
        <span class="muted" data-i18n>Homeswift logs in to check the details before saving them.</span>
        <button type="button" id="cancel-setup" data-i18n data-action-icon="close">Cancel</button>
        <button type="submit" class="primary" id="save-controller" data-i18n data-action-icon="check">Save controller</button>
      </div>
    </form>
  </section>

  <!-- Feature options -->
  <section id="options-screen" class="screen hidden">
    <div class="section-head"><h2 id="options-title" data-i18n>Feature options</h2><button class="link" id="back-from-options" data-i18n data-action-icon="restore">Back</button></div>
    <div class="options-layout">
      <aside class="scope-side">
        <div class="card"><label for="scope" data-i18n>Scope</label><select id="scope"></select></div>
        <div class="card cascade" id="cascade">
          <div class="level" data-scope="global"><span class="dot">G</span><div><div class="label" data-i18n>Global</div><div class="hint" data-i18n>All devices</div></div></div>
          <div class="connector"></div>
          <div class="level" data-scope="controller"><span class="dot">C</span><div><div class="label" data-i18n>Controller</div><div class="hint" data-i18n>Overrides global</div></div></div>
          <div class="connector"></div>
          <div class="level" data-scope="device"><span class="dot">D</span><div><div class="label" data-i18n>Device</div><div class="hint" data-i18n>Final value</div></div></div>
        </div>
        <div class="card hidden" id="device-info"></div>
        <div class="card legend">
          <strong data-i18n>Legend</strong>
          <span data-i18n><i class="bar global"></i>Set at global</span>
          <span data-i18n><i class="bar controller"></i>Set at controller</span>
          <span data-i18n><i class="bar device"></i>Set at device</span>
        </div>
      </aside>
      <div>
        <div class="option-tools">
          <input type="search" id="search" data-i18n placeholder="Search options…" aria-label="Search options">
          <label class="toggle compact"><span class="switch"><input type="checkbox" id="modified-only"><span></span></span><span class="muted" data-i18n>Modified <span id="modified-count"></span></span></label>
        </div>
        <p class="muted" id="options-loading" data-i18n>Loading options…</p>
        <div id="options-problem"></div>
        <div id="device-problem"></div>
        <div id="options"></div>
        <div class="card save-bar hidden" id="options-save">
          <span class="dirty" data-i18n>Unsaved changes to the feature options.</span>
          <button id="discard-options" data-i18n data-action-icon="close">Discard</button>
          <button class="primary" id="save-options" data-i18n data-action-icon="check">Save</button>
        </div>
      </div>
    </div>
  </section>

  <!-- Support -->
  <section id="support-screen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Support</h2><button class="link" id="back-from-support" data-i18n data-action-icon="restore">Back</button></div>
    <div class="card support">
      <h2 style="margin-top: 0" data-i18n>About this plugin</h2>
      <p id="support-about">A port of <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access">homebridge-unifi-access</a> to <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift">Homeswift</a>. If you find it useful, consider starring the projects on GitHub.</p>
      <h2 data-i18n>Getting started</h2>
      <ul>
        <li id="support-readme"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/blob/main/Plugins/UniFiAccess/README.md" data-i18n>Installation and configuration</a> in Homeswift, and what differs from Homebridge.</li>
        <li id="support-options"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/FeatureOptions.md" data-i18n>Feature options</a>: options to set per controller or device.</li>
        <li id="support-mqtt"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/MQTT.md">MQTT</a>: the topics published and accepted.</li>
        <li id="support-changelog"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/CHANGELOG.md" data-i18n>Changelog</a> of the Homebridge plugin this one follows.</li>
      </ul>
      <h2 data-i18n>Get help</h2>
      <ul>
        <li id="support-discord"><a target="_blank" rel="noopener noreferrer" href="https://discord.gg/QXqfHEW" data-i18n>Discord support channel</a> of the UniFi plugins.</li>
        <li id="support-issues"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/issues/new/choose" data-i18n>Create a developer support request</a> for the Homebridge plugin's behaviour, or <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/issues/new" data-i18n>open an issue on Homeswift</a> for this port.</li>
        <li id="support-log">The Homeswift log (the Logs page) shows what the plugin sees; feature option <code>Log.*</code> entries turn event logging on and off.</li>
      </ul>
    </div>
  </section>
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
