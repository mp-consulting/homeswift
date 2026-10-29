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
    if (!await HomeswiftCommon.confirmDialog(t("Remove {name}? Its devices leave HomeKit.", { name: ctrl.name || ctrl.address }))) return;
    try {
      await writeBlock((current) => { (current.controllers || []).splice(index, 1); });
    } catch (e) { HomeswiftCommon.showAlert(t("Unable to remove the controller: {message}", { message: e.message })); }
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

  async function backToControllers() {
    if (!(await leaveOptions())) return;
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
  async function leaveOptions() {
    if ($("#options-screen").classList.contains("hidden") || !optionsDirty()) return true;
    if (!await HomeswiftCommon.confirmDialog(t("Discard the changes to the feature options?"))) return false;
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
    } catch (e) { HomeswiftCommon.showAlert(t("Unable to save the feature options: {message}", { message: e.message })); }
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
