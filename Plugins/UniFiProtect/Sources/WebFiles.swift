// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension UniFiProtectPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Protect page: the Homebridge plugin's settings page (homebridge-ui/public) on Homeswift. The
// controllers of this instance's block with their state; discovery of UniFi consoles; adding and editing a
// controller, checked by logging in; the feature options editor with its scopes (global, controller,
// device) and the third-party camera URLs found over ONVIF; and the support links. The page edits this
// instance's block of config.json the way the settings form does; saving applies it.
(() => {
  "use strict";
  const { $, el, request, explain, readBlock, updateBlock } = homeswift;
  const { t } = HomeswiftI18n;
  /// Text from the plugin (an error in an answer, a feature option's description), in the page's language when
  /// the catalog knows it.
  const said = (text) => HomeswiftI18n.message(text);
  const P = window.ProtectOptions;
  const pluginName = "UniFi Protect";

  const categoryIcons = {
    Audio: "♪", Device: "▣", Doorbell: "◎", Log: "≡", Motion: "↯", Nvr: "▤", SecuritySystem: "⛨", Sensor: "◐", "UniFi.Access": "⚿", Video: "▶", "Video.HKSV": "⏺",
  };
  const categoryColors = {
    Audio: "#fd7e14", Device: "#0d6efd", Doorbell: "#e83e8c", Log: "#6c757d", Motion: "#20c997", Nvr: "#6f42c1", SecuritySystem: "#dc3545",
    Sensor: "#17a2b8", "UniFi.Access": "#ffc107", Video: "#198754", "Video.HKSV": "#495057",
  };

  const state = {
    block: null,          // this instance's block of config.json
    catalog: { categories: [], options: {} },
    controllerIndex: null,
    devices: [],
    editingIndex: null,
    openCategories: new Set(),
    savedOptions: "",     // the block as saved, to know what is unsaved on the options screen
    thirdPartyPanelOpen: false,
  };

  const controllers = () => state.block?.controllers || [];
  const currentController = () => controllers()[state.controllerIndex];

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const screens = ["controllersScreen", "discoveryScreen", "setupScreen", "featureOptionsScreen", "supportScreen"];
  function showScreen(id) {
    for (const screen of screens) $("#" + screen).classList.toggle("hidden", screen !== id);
    window.scrollTo({ top: 0 });
  }

  // MARK: The block in config.json

  async function loadBlock() {
    state.block = await readBlock();
    state.block.name ||= pluginName;
    state.savedOptions = JSON.stringify(state.block);
  }

  /// Saves the block: the plugin reloads with it.
  async function saveBlock() {
    const result = await updateBlock(() => state.block);
    state.savedOptions = JSON.stringify(state.block);
    return result;
  }

  // MARK: Controllers

  let runtime = {};   // address → what the running instance knows of it

  async function renderControllers() {
    const list = $("#controllersList");
    const configured = controllers();
    $("#noControllers").classList.toggle("hidden", configured.length > 0);
    try {
      const answer = await request("controllers");
      runtime = Object.fromEntries((answer.controllers || []).map((c) => [c.address, c]));
    } catch { runtime = {}; }
    list.replaceChildren(...configured.map((controller, index) => controllerCard(controller, index)));
  }

  function controllerCard(controller, index) {
    const badge = el("span", { class: "pill status standby", text: t("Checking") });
    const slot = el("div", {});
    const live = runtime[controller.address];
    const facts = live ? el("div", { class: "facts" },
      el("div", { class: "fact" }, el("span", { text: t("Devices") }), el("b", { text: String(live.devices.length) })),
      el("div", { class: "fact" }, el("span", { text: t("Events") }), el("b", { text: live.events ? t("Live") : live.connected ? t("Every 2 minutes") : "—" })),
      el("div", { class: "fact" }, el("span", { text: t("Certificate") }), el("b", { text: controller.verifyTls ? t("Verified") : live.tlsFingerprint ? t("Pinned") : t("Not yet seen") }))) : null;
    const remove = async () => {
      if (!await HomeswiftCommon.confirmDialog(t("Remove {name}?", { name: controller.name || controller.address }))) return;
      state.block.controllers.splice(index, 1);
      try { await saveBlock(); } catch (e) { HomeswiftCommon.showAlert(t("Unable to remove the controller: {error}", { error: e.message })); }
      await renderControllers();
      if (!controllers().length) showDiscovery(false);
    };
    // The card's actions in its menu, bottom right, as on the other pages' cards.
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("system")),
        el("div", { class: "who" }, el("strong", { text: controller.name || controller.address }), el("div", { class: "muted", text: controller.address })),
        badge),
      facts, slot,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: live ? (live.connected ? t("Connected") : t("Not connected yet: see the log.")) : t("Not running") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: controller.name || controller.address }), () => [
          { label: t("Feature options"), icon: "sliders", onSelect: () => openFeatureOptions(index) },
          { label: t("Edit"), icon: "edit", onSelect: () => openEditController(index) },
          { label: t("Remove"), icon: "trash", danger: true, onSelect: remove },
        ])));
    request("check-status", { method: "POST", body: { address: controller.address } }).then(({ online }) => {
      badge.className = `pill status ${online ? "on" : "away"}`;
      badge.textContent = online ? t("Online") : t("Offline");
      if (!online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server; loopback and link-local addresses are refused), so it is shown as Offline.",
          context: "The user is looking at the list of configured UniFi Protect controllers in the plugin's page.",
          device: P.assistantController(controller),
        }));
      }
    }).catch(() => { badge.textContent = t("Unknown"); });
    return card;
  }

  // MARK: Discovery

  function showDiscovery(cancellable) {
    $("#deviceList").replaceChildren();
    $("#cancelDiscoveryBtn").classList.toggle("hidden", !cancellable);
    showScreen("discoveryScreen");
  }

  const discoveryContext = "Discovering UniFi consoles from the plugin's page with the Ubiquiti discovery protocol (UDP port 10001 broadcast on the local subnets plus a unicast scan of nearby /24 subnets, 5 seconds).";

  async function discover(button) {
    const list = $("#deviceList");
    list.replaceChildren(el("p", { class: "muted", text: t("Searching…") }));
    try {
      const { devices } = await act(button, () => request("discover"));
      const configured = controllers().map((c) => c.address);
      const available = devices.filter((d) => !configured.includes(d.ip));
      if (!available.length) {
        const message = devices.length ? t("All discovered devices are already configured.") : t("No devices found. Make sure your UniFi console is on and connected.");
        list.replaceChildren(el("p", { class: devices.length ? "ok" : "warn", text: message }),
          devices.length ? null : explain({ error: message, context: discoveryContext }));
        return;
      }
      list.replaceChildren(el("p", { class: "muted", text: t("Found devices:") }), ...available.map((device) => el("button", {
        class: "card item", type: "button", onclick: () => openAddController(device.ip),
      }, el("div", {}, el("strong", { text: device.name }), el("div", { class: "muted", text: [device.ip, device.model, device.mac].filter(Boolean).join(" · ") })),
      el("span", { class: "pill", text: t("Select") }))));
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: t("Discovery error: {error}", { error: e.message }) }),
        explain({ error: P.scrubText("Discovery error: " + e.message), context: discoveryContext }));
    }
  }

  // MARK: Add or edit a controller

  function openAddController(address) {
    state.editingIndex = null;
    $("#setupTitle").textContent = t("Add UniFi Protect controller");
    $("#setupSubtitle").textContent = t("Enter your UniFi Protect controller details and login credentials.");
    $("#inputAddress").value = address || "";
    $("#inputUsername").value = "";
    $("#inputPassword").value = "";
    $("#inputVerifyTls").checked = false;
    $("#setupError").classList.add("hidden");
    $("#cancelSetupBtn").classList.toggle("hidden", !controllers().length && !address);
    showScreen("setupScreen");
    (address ? $("#inputUsername") : $("#inputAddress")).focus();
  }

  function openEditController(index) {
    state.editingIndex = index;
    const controller = controllers()[index];
    $("#setupTitle").textContent = t("Edit controller");
    $("#setupSubtitle").textContent = t("Editing {name}", { name: controller.name || controller.address });
    $("#inputAddress").value = controller.address || "";
    $("#inputUsername").value = controller.username || "";
    $("#inputPassword").value = controller.password || "";
    $("#inputVerifyTls").checked = controller.verifyTls === true;
    $("#setupError").classList.add("hidden");
    $("#cancelSetupBtn").classList.remove("hidden");
    showScreen("setupScreen");
  }

  function setupError(message, verifyTls, address) {
    $("#setupErrorText").textContent = message;
    $("#setupError").classList.remove("hidden");
    $("#setupAssistant").replaceChildren(explain({
      error: P.scrubText(message, [address]),
      context: "Logging in to the UniFi Protect controller and loading its devices (bootstrap, 20 second limit) from the plugin's page failed.",
      device: P.assistantController({ verifyTls }),
    }));
  }

  async function submitSetup(event) {
    event.preventDefault();
    const address = $("#inputAddress").value.trim();
    const username = $("#inputUsername").value.trim();
    const password = $("#inputPassword").value.trim();
    const verifyTls = $("#inputVerifyTls").checked;
    if (!address || !username || !password) {
      $("#setupErrorText").textContent = t("Please fill in all fields.");
      $("#setupError").classList.remove("hidden");
      return;
    }
    $("#setupError").classList.add("hidden");
    const button = $("#saveControllerBtn");
    button.textContent = t("Validating…");
    try {
      await act(button, async () => {
        const { devices, error } = await request("devices", { method: "POST", body: { address, username, password, verifyTls } });
        if (!devices?.length) {
          setupError(t("Unable to connect. {error}", { error: error ? said(error) : t("Check your address and credentials.") }), verifyTls, address);
          return;
        }
        state.block.controllers ||= [];
        // verifyTls is always written, so unchecking it overrides a saved value.
        const entry = { address, password, username, verifyTls };
        if (devices[0]?.name) entry.name = devices[0].name;
        if (state.editingIndex !== null) {
          state.block.controllers[state.editingIndex] = { ...state.block.controllers[state.editingIndex], ...entry };
        } else {
          state.block.controllers.push(entry);
        }
        await saveBlock();
        showScreen("controllersScreen");
        await renderControllers();
      });
    } catch (e) {
      setupError(t("Error: {error}", { error: e.message }), verifyTls, address);
    } finally {
      button.textContent = t("Save controller");
    }
  }

  // MARK: Feature options

  const isOptionsDirty = () => JSON.stringify(state.block) !== state.savedOptions;
  const configuredOptions = () => state.block.options || [];

  function markDirty() {
    $("#unsavedChanges").classList.toggle("hidden", !isOptionsDirty());
  }

  async function openFeatureOptions(index) {
    state.controllerIndex = index;
    const controller = currentController();
    showScreen("featureOptionsScreen");
    $("#optionsLoading").classList.remove("hidden");
    $("#optionsContainer").replaceChildren();
    $("#deviceInfoPanel").classList.add("hidden");
    $("#thirdPartyOverridesPanel").classList.add("hidden");
    $("#optionsSearch").value = "";
    $("#optionsProblem").classList.add("hidden");
    showDeviceProblem(null, null);
    markDirty();
    try {
      const [catalog, answer] = await Promise.all([
        request("options"),
        request("devices", { method: "POST", body: { address: controller.address, username: controller.username, password: controller.password, verifyTls: controller.verifyTls === true } }),
      ]);
      state.catalog = catalog;
      state.devices = (answer.devices || []).map((device) => ({ ...device, name: device.name ?? device.marketName }));
      if (!state.devices.length) showOptionsProblem(controller, t("Unable to load the devices of this controller. {error}", { error: answer.error ? said(answer.error) : t("Check its address and credentials.") }));
      buildScopeSelector(controller);
      renderOptions();
    } catch (e) {
      showOptionsProblem(controller, t("Failed to load: {error}", { error: e.message }));
    } finally {
      $("#optionsLoading").classList.add("hidden");
    }
  }

  function showOptionsProblem(controller, message) {
    const box = $("#optionsProblem");
    box.className = "problem";
    box.replaceChildren(el("p", { class: "error", text: message }), explain({
      error: P.scrubText(message, [controller?.address]),
      context: "Loading the devices of a configured UniFi Protect controller for the feature options screen of the plugin's page failed.",
      device: P.assistantController(controller),
    }));
  }

  function showDeviceProblem(device, problem) {
    const box = $("#infoAssistant");
    if (!problem) { box.classList.add("hidden"); box.replaceChildren(); return; }
    box.className = "problem warn";
    box.replaceChildren(el("p", { text: t("{device}: {problem}", { device: device.name || t("This device"), problem }) }), explain({
      error: problem, context: "The user is looking at the feature options of a UniFi Protect device in the plugin's page.", device: P.assistantDevice(device),
    }));
  }

  const modelLabels = { cameras: t("Cameras"), chimes: t("Chimes"), lights: t("Lights"), sensors: t("Sensors"), viewers: t("Viewers") };

  function buildScopeSelector(controller) {
    const select = $("#scopeSelect");
    select.replaceChildren(el("option", { value: "global", text: t("Global options") }),
      el("option", { value: "controller:" + controller.address, text: t("Controller: {name}", { name: controller.name || controller.address }) }));
    const groups = {};
    for (const device of state.devices) {
      if (device.modelKey === "nvr") continue;
      (groups[device.modelKey + "s"] ||= []).push(device);
    }
    for (const [key, items] of Object.entries(groups)) {
      select.append(el("optgroup", { label: modelLabels[key] || key }, items.map((device) => el("option", { value: "device:" + device.mac, text: device.name || device.marketName || device.type }))));
    }
  }

  // The camera of the scope, live while it is on screen (the UI's camera.js and /api/cameras), when it is one of
  // the accessories this bridge runs.
  let preview = null;
  let cameraIDs = null;
  async function showPreview(device) {
    const panel = $("#infoPreview");
    const id = device && device.modelKey === "camera" ? `UniFi Protect:${device.mac}` : null;
    if (preview && preview.camera.id === id) return;
    preview?.destroy();
    preview = null;
    panel.replaceChildren();
    panel.classList.add("hidden");
    if (!id || !window.HomeswiftCamera) return;
    try {
      cameraIDs ||= new Set((await HomeswiftCommon.api("/api/accessories")).filter((a) => a.camera).map((a) => a.id));
    } catch { return; }
    if (!cameraIDs.has(id) || currentScope().device !== device) return;
    preview = HomeswiftCamera.view({ id, name: device.name || device.marketName || t("Camera"), doorbell: device.featureFlags?.isDoorbell === true });
    panel.append(preview.element);
    panel.classList.remove("hidden");
  }

  function currentScope() {
    const value = $("#scopeSelect").value || "global";
    if (value === "global") return { device: null, id: null, type: "global" };
    const colon = value.indexOf(":");
    const type = value.slice(0, colon), id = value.slice(colon + 1);
    if (type === "controller") return { device: null, id, type };
    return { device: state.devices.find((d) => d.mac === id), id, type: "device" };
  }

  function updateCascade(type) {
    const order = ["global", "controller", "device"];
    const active = order.indexOf(type);
    const hints = {
      global: [t("Editing this scope"), t("Inherits global"), t("Inherits global")],
      controller: [t("Base values"), t("Editing this scope"), t("Inherits controller")],
      device: [t("Base values"), t("Intermediate"), t("Editing this scope")],
    };
    document.querySelectorAll("#scopeCascade .scope-level").forEach((level, index) => {
      level.classList.toggle("active", index === active);
      level.classList.toggle("inherited", index < active);
      level.querySelector(".scope-hint").textContent = hints[type][index];
    });
    document.querySelectorAll("#scopeCascade .scope-connector").forEach((connector, index) => connector.classList.toggle("active", index < active));
  }

  const view = { modifiedOnly: false, search: "" };

  function categoryOptions(category, scope, search) {
    if (!P.validOptionCategory(scope.device, category)) return null;
    return (state.catalog.options[category.name] || []).filter((option) => {
      if (scope.device && scope.device.modelKey !== "nvr" && !P.validOption(scope.device, option)) return false;
      return !search || (option.name + " " + option.description + " " + said(option.description)).toLowerCase().includes(search);
    });
  }

  function renderOptions() {
    const container = $("#optionsContainer");
    const scope = currentScope();
    updateCascade(scope.type);
    view.search = ($("#optionsSearch").value || "").toLowerCase();
    view.modifiedOnly = $("#modifiedOnlyToggle").checked;
    if (scope.device && scope.device.modelKey !== "nvr") {
      $("#deviceInfoPanel").classList.remove("hidden");
      $("#infoModel").textContent = scope.device.marketName || scope.device.type;
      $("#infoMac").textContent = scope.device.mac;
      $("#infoIp").textContent = scope.device.host || (scope.device.modelKey === "sensor" ? t("{connection} device", { connection: scope.device.connectionType === "lora" ? "SuperLink" : "Bluetooth" }) : t("N/A"));
      const status = $("#infoStatus");
      if (typeof scope.device.state === "string") {
        status.textContent = scope.device.state.charAt(0).toUpperCase() + scope.device.state.slice(1).toLowerCase();
        status.className = scope.device.state === "CONNECTED" ? "ok" : "error";
      } else {
        status.textContent = t("Connected");
        status.className = "ok";
      }
      showDeviceProblem(scope.device, P.deviceProblem(scope.device));
      showPreview(scope.device);
    } else {
      showPreview(null);
      $("#deviceInfoPanel").classList.add("hidden");
      showDeviceProblem(null, null);
    }
    renderThirdPartyPanel(scope);
    const cards = [];
    let modified = 0;
    for (const category of state.catalog.categories) {
      let options = categoryOptions(category, scope, view.search);
      if (!options?.length) continue;
      const stats = P.categoryStats(configuredOptions(), category, options, scope, currentController()?.address);
      modified += stats.modified;
      if (view.modifiedOnly) {
        options = options.filter((option) => P.isOptionModified(configuredOptions(), P.optionKey(category, option), scope.id));
        if (!options.length) continue;
      }
      cards.push(categoryCard(category, options, stats, scope));
    }
    if (!cards.length) cards.push(el("p", { class: "muted", text: view.modifiedOnly ? t("No modified options") : view.search ? t("No options match your search") : t("No options available") }));
    container.replaceChildren(...cards);
    updateModifiedSummary(modified);
  }

  function updateModifiedSummary(count) {
    $("#modifiedOnlyToggle").disabled = count === 0 && !$("#modifiedOnlyToggle").checked;
    $("#modifiedOnlyToggle").closest("label").title = $("#modifiedOnlyToggle").disabled ? t("No modified options match the current search.") : "";
    const summary = $("#modifiedSummary");
    summary.textContent = count ? `(${count})` : "";
    summary.className = count ? "warn" : "";
  }

  function categoryCard(category, options, stats, scope) {
    const color = categoryColors[category.name] || "#6c757d";
    const isOpen = state.openCategories.has(category.name) || (stats.modified > 0 && !state.openCategories.size) || !!view.search;
    const count = el("span", { class: "category-count" });
    const fill = el("span", { class: "category-progress-fill" });
    const badge = el("span", { class: "modified-badge" });
    const head = el("button", { class: "category-head", type: "button", "aria-expanded": String(isOpen) },
      el("span", { class: "category-icon", text: categoryIcons[category.name] || "•" }),
      el("span", { class: "category-title", text: said(category.description.replace(/ feature options\.?/i, "")) }),
      count, el("span", { class: "category-progress" }, fill), badge, el("span", { class: "chevron", text: "⌄" }));
    const card = el("div", { class: `card category${isOpen ? " open" : ""}`, "data-category": category.name });
    card.style.setProperty("--category-color", color);
    const fillHeader = (s) => {
      count.textContent = t("{enabled}/{total} on", { enabled: s.enabled, total: s.total });
      fill.style.setProperty("--progress", String(s.fraction));
      badge.textContent = String(s.modified);
      badge.classList.toggle("hidden", !s.modified);
    };
    fillHeader(stats);
    head.addEventListener("click", () => {
      const open = card.classList.toggle("open");
      head.setAttribute("aria-expanded", String(open));
      if (open) state.openCategories.add(category.name); else state.openCategories.delete(category.name);
    });
    const body = el("div", { class: "category-body" }, options.map((option) => optionRow(category, option, scope, () => {
      if (view.modifiedOnly && !P.isOptionModified(configuredOptions(), P.optionKey(category, option), scope.id)) { renderOptions(); return; }
      fillHeader(P.categoryStats(configuredOptions(), category, categoryOptions(category, scope, view.search) || [], scope, currentController()?.address));
      let total = 0;
      for (const other of state.catalog.categories) {
        const entries = categoryOptions(other, scope, view.search);
        if (entries) total += P.categoryStats(configuredOptions(), other, entries, scope, currentController()?.address).modified;
      }
      updateModifiedSummary(total);
    })));
    card.append(head, body);
    return card;
  }

  /// The units the options' descriptions name ("in seconds"), and the scopes, in the page's language.
  const unitLabels = {
    second: t("second"), seconds: t("seconds"), minute: t("minute"), minutes: t("minutes"), hour: t("hour"), hours: t("hours"),
    millisecond: t("millisecond"), milliseconds: t("milliseconds"), decibel: t("decibel"), decibels: t("decibels"), hertz: t("Hertz"),
    "kilobits per second": t("kilobits per second"), percentage: t("percentage"),
  };
  const scopeLabels = { global: t("global"), controller: t("controller"), device: t("device") };

  function optionRow(category, option, scope, changed) {
    const key = P.optionKey(category, option);
    const checkbox = el("input", { type: "checkbox", "aria-label": key });
    const badge = el("span", {});
    const valueInput = option.defaultValue !== undefined ? el("input", { type: option.inputSize ? "text" : "number", min: "0", step: "1", "aria-label": t("{option} value", { option: key }) }) : null;
    const unit = option.description.match(/\bin (seconds?|minutes?|hours?|milliseconds?|decibels?|Hertz|kilobits per second|percentage)\b/i)?.[1];
    const valueRow = valueInput ? el("div", { class: "option-value" }, valueInput, unit ? el("span", { class: "muted", text: unitLabels[unit.toLowerCase()] || unit }) : null,
      el("span", { class: "muted", text: t("(default: {value})", { value: option.defaultValue === "" ? t("none") : String(option.defaultValue) }) })) : null;
    const reset = el("button", { class: "reset-option", type: "button", title: t("Reset to inherited value"), "aria-label": t("Reset to inherited value"), text: "↺" });
    const row = el("div", { class: "option" },
      el("label", { class: "switch" }, checkbox, el("span", {})),
      el("div", { class: "option-text" },
        el("div", {}, el("span", { class: "option-name", text: option.name || said(category.description) }),
          el("span", { class: "default-indicator", text: option.default ? t("default: on") : t("default: off") }), badge),
        el("div", { class: "option-description", text: said(option.description) }), valueRow),
      reset);
    const sync = () => {
      const s = P.getOptionState(configuredOptions(), key, option, scope, currentController()?.address);
      let scopeClass = "";
      if (s.explicit) scopeClass = "scope-" + scope.type;
      else if (s.scope === "controller") scopeClass = "scope-controller";
      else if (s.scope === "global" && scope.type !== "global") scopeClass = "scope-global";
      else if (s.enabled !== option.default) scopeClass = "non-default";
      row.className = `option ${scopeClass}${option.group && option.name !== option.group ? " grouped" : ""}`;
      if (s.explicit) { badge.className = `scope-badge ${scope.type}`; badge.textContent = scopeLabels[scope.type] || scope.type; }
      else if (s.scope === "controller" || (s.scope === "global" && scope.type !== "global")) { badge.className = `scope-badge inherited ${s.scope}`; badge.textContent = "↓ " + (scopeLabels[s.scope] || s.scope); }
      else { badge.className = ""; badge.textContent = ""; }
      checkbox.checked = s.enabled;
      if (!s.explicit && document.activeElement === reset) checkbox.focus();
      reset.classList.toggle("hidden", !s.explicit);
      if (valueRow) {
        valueRow.classList.toggle("hidden", !s.enabled);
        const current = String(s.value ?? option.defaultValue);
        if (valueInput.value !== current) valueInput.value = current;
      }
    };
    checkbox.addEventListener("change", () => {
      state.block.options = P.setOption(configuredOptions(), key, checkbox.checked, scope, option, currentController()?.address);
      sync(); changed(); markDirty();
    });
    valueInput?.addEventListener("change", () => {
      const text = valueInput.value.trim();
      const parsed = option.inputSize ? text : parseInt(text, 10);
      if (option.inputSize ? text.includes(".") : (isNaN(parsed) || parsed < 0)) return;
      state.block.options = P.setOption(configuredOptions(), key, true, scope, option, currentController()?.address, parsed);
      sync(); changed(); markDirty();
    });
    reset.addEventListener("click", (event) => {
      event.stopPropagation();
      state.block.options = P.removeOption(configuredOptions(), key, scope);
      sync(); changed(); markDirty();
    });
    sync();
    return row;
  }

  // MARK: Third-party camera URLs

  const discoveries = new Map();   // normalized MAC → { host, port, profiles, thumbnails, warnings, collapsedFrom, queue }

  function renderThirdPartyPanel(scope) {
    const panel = $("#thirdPartyOverridesPanel");
    const controller = currentController();
    if (!scope.device || scope.device.modelKey !== "camera" || !scope.device.isThirdPartyCamera || !controller) { panel.classList.add("hidden"); return; }
    if (P.dedupeCameraOverrides(controller)) markDirty();
    const mac = scope.device.mac;
    const existing = (controller.cameraOverrides || []).find((entry) => P.normalizeMac(entry.mac) === P.normalizeMac(mac));
    $("#thirdPartyRtspUrl").value = existing?.rtspUrl || "";
    $("#thirdPartySnapshotUrl").value = existing?.snapshotUrl || "";
    // The camera's address is the controller's to know; the rest is remembered in the override.
    $("#thirdPartyOnvifHost").value = scope.device.host || "";
    $("#thirdPartyOnvifPort").value = existing?.onvifPort != null ? String(existing.onvifPort) : "";
    $("#thirdPartyOnvifUser").value = existing?.onvifUsername || "";
    $("#thirdPartyOnvifPass").value = existing?.onvifPassword || "";
    $("#thirdPartyOnvifPath").value = existing?.onvifServicePath || "";
    say("");
    $("#thirdPartyProfileSelectorWrap").classList.add("hidden");
    $("#thirdPartyDiscoverAssistant").replaceChildren();
    if (discoveries.has(P.normalizeMac(mac))) renderProfileSelector(mac);
    panel.classList.remove("hidden");
    panel.classList.toggle("open", state.thirdPartyPanelOpen);
    $("#thirdPartyOverridesHeader").onclick = () => { state.thirdPartyPanelOpen = !state.thirdPartyPanelOpen; panel.classList.toggle("open", state.thirdPartyPanelOpen); };
    const bind = (id, field) => { $(id).oninput = () => { P.updateCameraOverride(controller, mac, field, $(id).value); markDirty(); }; };
    bind("#thirdPartyRtspUrl", "rtspUrl");
    bind("#thirdPartySnapshotUrl", "snapshotUrl");
    bind("#thirdPartyOnvifPort", "onvifPort");
    bind("#thirdPartyOnvifUser", "onvifUsername");
    bind("#thirdPartyOnvifPass", "onvifPassword");
    bind("#thirdPartyOnvifPath", "onvifServicePath");
    $("#thirdPartyDiscoverBtn").onclick = (event) => act(event.currentTarget, () => discoverOnvif(mac));
    $("#thirdPartyProfileSelect").onchange = () => applyProfile(mac, parseInt($("#thirdPartyProfileSelect").value, 10));
  }

  function say(text, kind = "") {
    const status = $("#thirdPartyDiscoverStatus");
    status.textContent = text;
    status.className = `status-line ${kind}`;
  }

  async function discoverOnvif(mac) {
    const controller = currentController();
    const host = $("#thirdPartyOnvifHost").value.trim();
    const username = $("#thirdPartyOnvifUser").value.trim();
    const password = $("#thirdPartyOnvifPass").value;
    const servicePath = $("#thirdPartyOnvifPath").value.trim();
    const port = $("#thirdPartyOnvifPort").value;
    if (!host || !username) { say(t("IP address and username are required."), "error"); return; }
    // What was entered or prefilled is remembered before talking to the camera.
    P.updateCameraOverride(controller, mac, "onvifPort", port);
    P.updateCameraOverride(controller, mac, "onvifUsername", username);
    P.updateCameraOverride(controller, mac, "onvifPassword", password);
    P.updateCameraOverride(controller, mac, "onvifServicePath", servicePath);
    markDirty();
    say(t("Discovering…"));
    const assistantSlot = $("#thirdPartyDiscoverAssistant");
    assistantSlot.replaceChildren();
    const explainFailure = (message) => assistantSlot.replaceChildren(explain({
      error: P.scrubText(message, [host]),
      context: "Discovering the RTSP and snapshot URLs of a third-party camera over ONVIF from the plugin's page failed. Service path: "
        + (servicePath ? "custom" : "default (/onvif/device_service)") + ". Port: " + (port ? "set by the user" : "automatic") + ".",
    }));
    try {
      const result = await request("onvif", { method: "POST", body: { host, password, port: port ? parseInt(port, 10) : undefined, servicePath: servicePath || undefined, username } });
      if (!result?.ok) {
        say(t("Discovery failed: {error}", { error: result?.error ? said(result.error) : t("unknown error") }), "error");
        explainFailure("Discovery failed: " + (result?.error || "unknown error"));
        return;
      }
      const raw = (result.profiles || []).filter((p) => p.rtspUrl || p.snapshotUrl);
      if (!raw.length) { say(t("Camera did not return any URLs."), "warn"); return; }
      discoveries.set(P.normalizeMac(mac), { collapsedFrom: raw.length, host, port: result.port, profiles: P.dedupeProfilesByUrl(raw), thumbnails: new Map(), warnings: result.warnings || [], queue: Promise.resolve() });
      renderProfileSelector(mac);
    } catch (e) {
      say(t("Discovery failed: {error}", { error: e.message }), "error");
      explainFailure("Discovery failed: " + e.message);
    }
  }

  function renderProfileSelector(mac) {
    const entry = discoveries.get(P.normalizeMac(mac));
    if (!entry?.profiles?.length) return;
    const select = $("#thirdPartyProfileSelect");
    let selected = entry.profiles.findIndex((p) => p.rtspUrl && p.rtspUrl === $("#thirdPartyRtspUrl").value);
    if (selected < 0) selected = 0;
    select.replaceChildren(...entry.profiles.map((profile, index) => el("option", { value: String(index), text: P.formatProfileLabel(profile, index) })));
    select.value = String(selected);
    select.disabled = entry.profiles.length <= 1;
    $("#thirdPartyProfileSelectorWrap").classList.remove("hidden");
    applyProfile(mac, selected);
    // The other thumbnails, one at a time: cheap cameras drop parallel snapshot requests.
    entry.profiles.forEach((_, index) => { if (index !== selected) loadThumbnail(mac, index); });
    const port = String(entry.port);
    let text = entry.profiles.length > 1 ? t("Found {n} profiles on port {port}. Pick the one to use.", { n: entry.profiles.length, port })
      : entry.collapsedFrom > 1 ? t("Camera reports {n} profiles but they all map to the same stream. Discovered URLs on port {port}.", { n: entry.collapsedFrom, port })
        : t("Discovered URLs on port {port}.", { port });
    if (entry.warnings.length) { text += " " + entry.warnings.map(said).join(" "); say(text, "warn"); } else { say(text, "ok"); }
  }

  function showThumbnail(mac, index) {
    const cached = discoveries.get(P.normalizeMac(mac))?.thumbnails.get(index);
    const image = $("#thirdPartyProfileThumb");
    image.classList.toggle("hidden", !cached);
    $("#thirdPartyProfileThumbPlaceholder").classList.toggle("hidden", !!cached);
    if (cached) image.src = cached; else image.removeAttribute("src");
  }

  function loadThumbnail(mac, index) {
    const entry = discoveries.get(P.normalizeMac(mac));
    const profile = entry?.profiles[index];
    if (!entry || entry.thumbnails.has(index)) return entry?.queue;
    if (!profile?.snapshotUrl) { entry.thumbnails.set(index, null); return entry.queue; }
    entry.queue = entry.queue.then(async () => {
      if (entry.thumbnails.has(index)) return;
      try {
        const result = await request("snapshot", { method: "POST", body: { host: entry.host, url: profile.snapshotUrl } });
        entry.thumbnails.set(index, result?.ok && result.data ? `data:${result.contentType || "image/jpeg"};base64,${result.data}` : null);
      } catch { entry.thumbnails.set(index, null); }
      if (parseInt($("#thirdPartyProfileSelect").value, 10) === index) showThumbnail(mac, index);
    }).catch(() => {});
    return entry.queue;
  }

  function applyProfile(mac, index) {
    const controller = currentController();
    const profile = discoveries.get(P.normalizeMac(mac))?.profiles[index];
    if (!profile || !controller) return;
    $("#thirdPartyRtspUrl").value = profile.rtspUrl || "";
    $("#thirdPartySnapshotUrl").value = profile.snapshotUrl || "";
    P.updateCameraOverride(controller, mac, "rtspUrl", profile.rtspUrl || "");
    P.updateCameraOverride(controller, mac, "snapshotUrl", profile.snapshotUrl || "");
    markDirty();
    showThumbnail(mac, index);
    loadThumbnail(mac, index);
  }

  async function saveOptions(button) {
    await act(button, async () => {
      try {
        const result = await saveBlock();
        markDirty();
        const pending = result?.restartNeeded || [];
        if (pending.length) HomeswiftCommon.showAlert(t("Saved. Restart Homeswift to apply: {changes}.", { changes: pending.join("; ") }));
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    });
  }

  async function discardOptions() {
    if (!await HomeswiftCommon.confirmDialog(t("Discard the changes?"))) return;
    state.block = JSON.parse(state.savedOptions);
    markDirty();
    renderOptions();
  }

  async function leaveOptions() {
    if (isOptionsDirty() && !await HomeswiftCommon.confirmDialog(t("Leave without saving the changes?"))) return;
    if (isOptionsDirty()) state.block = JSON.parse(state.savedOptions);
    markDirty();
    showScreen("controllersScreen");
    renderControllers();
  }

  // MARK: Start

  function bind() {
    $("#discoverBtn").addEventListener("click", (event) => discover(event.currentTarget));
    $("#manualEntryBtn").addEventListener("click", () => openAddController());
    $("#cancelDiscoveryBtn").addEventListener("click", () => { showScreen("controllersScreen"); renderControllers(); });
    $("#setupForm").addEventListener("submit", submitSetup);
    $("#cancelSetupBtn").addEventListener("click", () => {
      if (controllers().length) { showScreen("controllersScreen"); renderControllers(); } else { showDiscovery(false); }
    });
    $("#addControllerBtn").addEventListener("click", () => showDiscovery(controllers().length > 0));
    $("#supportBtn").addEventListener("click", () => showScreen("supportScreen"));
    $("#backFromSupportBtn").addEventListener("click", () => { showScreen("controllersScreen"); renderControllers(); });
    $("#optionsSearch").parentElement.append(HomeswiftCommon.clearFilters([[$("#optionsSearch"), ""], [$("#modifiedOnlyToggle"), false]]));
    let searchTimer = null;
    $("#optionsSearch").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(renderOptions, 300); });
    $("#scopeSelect").addEventListener("change", renderOptions);
    $("#modifiedOnlyToggle").addEventListener("change", renderOptions);
    $("#backFromOptionsBtn").addEventListener("click", leaveOptions);
    $("#saveOptionsBtn").addEventListener("click", (event) => saveOptions(event.currentTarget));
    $("#discardOptionsBtn").addEventListener("click", discardOptions);
    window.addEventListener("beforeunload", (event) => { if (state.block && isOptionsDirty()) event.preventDefault(); });
  }

  async function start() {
    bind();
    try {
      await loadBlock();
    } catch (e) {
      $("main").append(el("p", { class: "card error", text: e.message }));
      return;
    }
    // Duplicate camera overrides from older versions or hand edits collapse into one entry per camera.
    let deduped = false;
    for (const controller of controllers()) deduped = P.dedupeCameraOverrides(controller) || deduped;
    if (deduped) { try { await saveBlock(); } catch { /* kept unsaved */ } }
    if (controllers().length) {
      showScreen("controllersScreen");
      renderControllers();
    } else {
      showDiscovery(false);
    }
  }

  start();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Protect page's strings, its feature options' descriptions and the text its plugin answers, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Gérez vos caméras et appareils UniFi Protect dans HomeKit.",
    "Configured controllers": "Contrôleurs configurés",
    "No controllers configured yet. Add one to get started.": "Aucun contrôleur configuré. Ajoutez-en un pour commencer.",
    "Add controller": "Ajouter un contrôleur",
    "Support": "Assistance",
    "Discover your controller": "Trouvez votre contrôleur",
    "Scan your network for UniFi Protect controllers, or enter the address manually.": "Recherchez les contrôleurs UniFi Protect sur votre réseau ou saisissez l'adresse manuellement.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Vérifiez que votre console UniFi est allumée et connectée au même réseau.",
    "Discover controllers": "Rechercher des contrôleurs",
    "Manual entry": "Saisie manuelle",
    "Cancel": "Annuler",
    "Add UniFi Protect controller": "Ajouter un contrôleur UniFi Protect",
    "Enter your UniFi Protect controller details and login credentials.": "Saisissez les informations de votre contrôleur UniFi Protect et vos identifiants de connexion.",
    "Controller": "Contrôleur",
    "Hostname or IP (e.g. unvr.local)": "Nom d'hôte ou IP (p. ex. unvr.local)",
    "The address of your UniFi Protect controller.": "L'adresse de votre contrôleur UniFi Protect.",
    "Username": "Nom d'utilisateur",
    "Local user account username": "Nom d'utilisateur du compte local",
    "Password": "Mot de passe",
    "Local user account password": "Mot de passe du compte local",
    "Verify TLS": "Vérifier le TLS",
    "Validate the controller's TLS certificate. Leave this off unless your controller uses a certificate signed by a trusted certificate authority: UniFi controllers use self-signed certificates, which are pinned the first time instead.": "Valide le certificat TLS du contrôleur. Laissez cette option désactivée, sauf si votre contrôleur utilise un certificat signé par une autorité de certification de confiance : les contrôleurs UniFi utilisent des certificats autosignés, qui sont plutôt épinglés la première fois.",
    "Local account required.": "Compte local requis.",
    "Ubiquiti.com/UI.com accounts are not supported.": "Les comptes Ubiquiti.com/UI.com ne sont pas pris en charge.",
    "Create one in the": "Créez-en un dans l'onglet",
    "tab of your UniFi console.": "de votre console UniFi.",
    "Save controller": "Enregistrer le contrôleur",
    "Feature options": "Options des fonctions",
    "Back": "Retour",
    "Scope": "Portée",
    "Global": "Global",
    "All devices": "Tous les appareils",
    "Overrides global": "Remplace le réglage global",
    "Device": "Appareil",
    "Final value": "Valeur finale",
    "Model": "Modèle",
    "Status": "État",
    "Legend": "Légende",
    "Set at global": "Défini au niveau global",
    "Set at controller": "Défini au niveau du contrôleur",
    "Set at device": "Défini au niveau de l'appareil",
    "Search options…": "Rechercher des options…",
    "Modified": "Modifiées",
    "Loading options…": "Chargement des options…",
    "Third-party camera URLs": "URL de la caméra tierce",
    "The Protect controller often does not relay this camera's stream. Enter the camera's IP and credentials to discover its URLs automatically, or paste the URLs below.": "Le contrôleur Protect ne relaie souvent pas le flux de cette caméra. Saisissez l'IP et les identifiants de la caméra pour découvrir ses URL automatiquement, ou collez les URL ci-dessous.",
    "IP address": "Adresse IP",
    "e.g. 192.168.1.50": "p. ex. 192.168.1.50",
    "ONVIF port": "Port ONVIF",
    "(optional)": "(facultatif)",
    "auto": "auto",
    "Service path": "Chemin du service",
    "(optional, /onvif/device_service by default)": "(facultatif, /onvif/device_service par défaut)",
    "Discover URLs": "Découvrir les URL",
    "Stream profile": "Profil de flux",
    "Stream preview": "Aperçu du flux",
    "No preview": "Aucun aperçu",
    "Pick the camera stream HomeKit should use. Higher resolutions look better but cost more bandwidth and CPU.": "Choisissez le flux de la caméra que HomeKit doit utiliser. Une résolution plus élevée donne une meilleure image mais consomme plus de bande passante et de processeur.",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directe",
    "Direct snapshot URL": "URL d'instantané directe",
    "Leave both URL fields blank to remove the override.": "Laissez les deux champs d'URL vides pour supprimer le remplacement.",
    "You have unsaved changes. Saving applies them: the plugin restarts with them.": "Vous avez des modifications non enregistrées. Les enregistrer les applique : le plugin redémarre avec elles.",
    "Discard": "Annuler les modifications",
    "Save": "Enregistrer",
    "About this plugin": "À propos de ce plugin",
    "The Homeswift port of": "Le portage pour Homeswift de",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "Sa documentation s'applique ici : les options, les options des fonctions et les sujets MQTT sont les mêmes.",
    "Getting started": "Premiers pas",
    "Install, configure and connect to HomeKit.": "Installer, configurer et connecter à HomeKit.",
    "Options for a controller or a device.": "Les options d'un contrôleur ou d'un appareil.",
    "How to configure MQTT support.": "Comment configurer la prise en charge de MQTT.",
    "How-to guides": "Guides pratiques",
    "Doorbells": "Sonnettes",
    "Two-way audio, ring events and LCD messages.": "Audio bidirectionnel, événements de sonnerie et messages LCD.",
    "HKSV with Protect cameras.": "HKSV avec les caméras Protect.",
    "Liveview scenes": "Scènes Liveview",
    "Motion detection scenes and the security system.": "Les scènes de détection de mouvement et le système de sécurité.",
    "Troubleshooting": "Dépannage",
    "Login, network and video problems.": "Problèmes de connexion, de réseau et de vidéo.",
    "Checking": "Vérification",
    "Devices": "Appareils",
    "Events": "Événements",
    "Live": "En direct",
    "Every 2 minutes": "Toutes les 2 minutes",
    "Certificate": "Certificat",
    "Verified": "Vérifié",
    "Pinned": "Épinglé",
    "Not yet seen": "Pas encore vu",
    "Remove {name}?": "Supprimer {name} ?",
    "Unable to remove the controller: {error}": "Impossible de supprimer le contrôleur : {error}",
    "Connected": "Connecté",
    "Not connected yet: see the log.": "Pas encore connecté : consultez le journal.",
    "Not running": "Arrêté",
    "Actions for {name}": "Actions pour {name}",
    "Edit": "Modifier",
    "Remove": "Supprimer",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Unknown": "Inconnu",
    "Searching…": "Recherche…",
    "All discovered devices are already configured.": "Tous les appareils trouvés sont déjà configurés.",
    "No devices found. Make sure your UniFi console is on and connected.": "Aucun appareil trouvé. Vérifiez que votre console UniFi est allumée et connectée.",
    "Found devices:": "Appareils trouvés :",
    "Select": "Choisir",
    "Discovery error: {error}": "Erreur de recherche : {error}",
    "Edit controller": "Modifier le contrôleur",
    "Editing {name}": "Modification de {name}",
    "Please fill in all fields.": "Remplissez tous les champs.",
    "Validating…": "Validation…",
    "Unable to connect. {error}": "Connexion impossible. {error}",
    "Check your address and credentials.": "Vérifiez l'adresse et les identifiants.",
    "Error: {error}": "Erreur : {error}",
    "Unable to load the devices of this controller. {error}": "Impossible de charger les appareils de ce contrôleur. {error}",
    "Check its address and credentials.": "Vérifiez son adresse et ses identifiants.",
    "Failed to load: {error}": "Échec du chargement : {error}",
    "{device}: {problem}": "{device} : {problem}",
    "This device": "Cet appareil",
    "Cameras": "Caméras",
    "Chimes": "Carillons",
    "Lights": "Lampes",
    "Sensors": "Capteurs",
    "Viewers": "Écrans",
    "Global options": "Options globales",
    "Controller: {name}": "Contrôleur : {name}",
    "Camera": "Caméra",
    "Editing this scope": "Portée en cours de modification",
    "Inherits global": "Hérite du réglage global",
    "Base values": "Valeurs de base",
    "Inherits controller": "Hérite du contrôleur",
    "Intermediate": "Intermédiaire",
    "{connection} device": "Appareil {connection}",
    "N/A": "N/D",
    "No modified options": "Aucune option modifiée",
    "No options match your search": "Aucune option ne correspond à votre recherche",
    "No options available": "Aucune option disponible",
    "{enabled}/{total} on": "{enabled}/{total} activées",
    "second": "seconde",
    "seconds": "secondes",
    "minute": "minute",
    "minutes": "minutes",
    "hour": "heure",
    "hours": "heures",
    "millisecond": "milliseconde",
    "milliseconds": "millisecondes",
    "decibel": "décibel",
    "decibels": "décibels",
    "Hertz": "hertz",
    "kilobits per second": "kilobits par seconde",
    "percentage": "pourcentage",
    "global": "global",
    "controller": "contrôleur",
    "device": "appareil",
    "{option} value": "Valeur de {option}",
    "(default: {value})": "(par défaut : {value})",
    "none": "aucune",
    "Reset to inherited value": "Rétablir la valeur héritée",
    "default: on": "par défaut : activée",
    "default: off": "par défaut : désactivée",
    "IP address and username are required.": "L'adresse IP et le nom d'utilisateur sont requis.",
    "Discovering…": "Découverte…",
    "Discovery failed: {error}": "Échec de la découverte : {error}",
    "unknown error": "erreur inconnue",
    "Camera did not return any URLs.": "La caméra n'a renvoyé aucune URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "{n} profils trouvés sur le port {port}. Choisissez celui à utiliser.",
    "Camera reports {n} profiles but they all map to the same stream. Discovered URLs on port {port}.": "La caméra annonce {n} profils, mais ils correspondent tous au même flux. URL découvertes sur le port {port}.",
    "Discovered URLs on port {port}.": "URL découvertes sur le port {port}.",
    "Saved. Restart Homeswift to apply: {changes}.": "Enregistré. Redémarrez Homeswift pour appliquer : {changes}.",
    "Discard the changes?": "Annuler les modifications ?",
    "Leave without saving the changes?": "Quitter sans enregistrer les modifications ?",
    "Profile {n}": "Profil {n}",
    "this camera": "cette caméra",
    "this chime": "ce carillon",
    "this light": "cette lampe",
    "this sensor": "ce capteur",
    "this viewer": "cet écran",
    "this device": "cet appareil",
    "this {model}": "cet appareil ({model})",
    "UniFi Protect reports {device} as updating its firmware.": "UniFi Protect indique que {device} met à jour son firmware.",
    "UniFi Protect reports {device} as {state} (not connected).": "UniFi Protect indique l'état « {state} » pour {device} (non connecté).",
    "Enter the password: this controller's certificate is not pinned yet.": "Saisissez le mot de passe : le certificat de ce contrôleur n'est pas encore épinglé.",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Délai dépassé après {0} s d'attente d'une réponse de {1}. Vérifiez que l'adresse et les identifiants sont corrects et que le contrôleur est joignable depuis cette machine Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0} : erreur d'API : identifiants de connexion non valides. Vérifiez votre nom d'utilisateur et votre mot de passe.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0} : erreur d'API : privilèges insuffisants pour cet utilisateur. Vérifiez les rôles attribués à cet utilisateur et assurez-vous qu'il dispose des privilèges nécessaires.",
    "{0}: API error: Connection refused.": "{0} : erreur d'API : connexion refusée.",
    "{0}: API error: Connection timed out.": "{0} : erreur d'API : la connexion a expiré.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0} : erreur d'API : nom d'hôte ou adresse IP introuvable : {1}. Vérifiez que l'adresse configurée pour ce contrôleur UniFi Protect est correcte.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0} : erreur d'API : impossible de se connecter au contrôleur Protect. C'est temporaire et peut arriver pendant le redémarrage des appareils.",
    "Invalid address.": "Adresse non valide.",
    "Unable to resolve {0}.": "Impossible de résoudre {0}.",
    "Connections to {0} are not permitted.": "Les connexions à {0} ne sont pas autorisées.",
    "ONVIF request timed out": "La requête ONVIF a expiré",
    "host and username are required.": "l'hôte et le nom d'utilisateur sont requis.",
    "No reachable ONVIF service on {0} ({1}).": "Aucun service ONVIF joignable sur {0} ({1}).",
    "Camera did not return a Media service capability.": "La caméra n'a pas indiqué de service Media.",
    "Camera did not return a Media service XAddr.": "La caméra n'a pas renvoyé de XAddr pour le service Media.",
    "Camera returned no media profiles.": "La caméra n'a renvoyé aucun profil média.",
    "The camera advertised its media service on a different host. Using {0} instead.": "La caméra annonce son service média sur un autre hôte. {0} est utilisé à la place.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "La caméra a renvoyé des URL de flux ou d'instantané sur un autre hôte que {0}. Les identifiants n'ont pas été ajoutés à ces URL.",
    "Audio": "Audio",
    "Doorbell": "Sonnette",
    "Logging": "Journalisation",
    "Motion": "Mouvement",
    "Security System": "Système de sécurité",
    "Sensor": "Capteur",
    "Video": "Vidéo",
    "Audio support.": "Prise en charge de l'audio.",
    "Audio filter for ambient noise suppression.": "Filtre audio de suppression du bruit ambiant.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Niveau de réduction du bruit, en décibels, pour le filtre afftdn de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Fréquence, en hertz, pour le filtre highpass de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Fréquence, en hertz, pour le filtre lowpass de FFmpeg.",
    "Two-way audio support on supported cameras.": "Audio bidirectionnel sur les caméras compatibles.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Envoyer l'audio bidirectionnel directement aux caméras compatibles, sans passer par le contrôleur. Utile pour contourner des bugs de certaines versions du firmware des contrôleurs Protect.",
    "Make this device available in HomeKit.": "Rendre cet appareil disponible dans HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Activer le voyant d'état de cet appareil dans HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Ajouter un accessoire interrupteur pour contrôler le voyant d'état dans HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Activer le voyant de vision nocturne de cet appareil dans HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Ajouter un accessoire variateur pour contrôler la vision nocturne dans HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Faire de cet appareil un accessoire autonome dans HomeKit, à ajouter séparément depuis l'app Maison.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tenter de redémarrer les appareils qui fonctionnent mal. Cela se fait toujours avec une grande prudence, et seulement après des problèmes prolongés propres à l'appareil.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Synchroniser le nom UniFi Protect de cet appareil avec HomeKit. La synchronisation est à sens unique : le nom va d'UniFi Protect vers HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Ajouter un capteur de contact qui s'active quand une empreinte digitale ou un badge NFC est authentifié sur une sonnette Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Ajouter un accessoire interrupteur pour choisir si HomeKit sonne quand on appuie sur la sonnette.",
    "Enable the doorbell messages feature.": "Activer la fonction des messages de la sonnette.",
    "Use messages saved to the Protect NVR as message switches.": "Utiliser les messages enregistrés sur le NVR Protect comme interrupteurs de message.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Ajouter un accessoire variateur pour contrôler le volume du carillon Protect dans HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Ajouter des accessoires interrupteurs pour contrôler les carillons physiques reliés à une sonnette Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Durée de la sonnerie, en millisecondes, d'un carillon physique numérique relié à une sonnette Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Ajouter un accessoire lampe pour contrôler la lampe de la caméra à colis d'une sonnette Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Ajouter un accessoire interrupteur pour déclencher des événements de sonnerie sur une caméra ou une sonnette Protect.",
    "Log doorbell ring events in Homebridge.": "Consigner les événements de sonnerie dans Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Consigner les événements d'enregistrement HomeKit Secure Video dans Homebridge.",
    "Log motion events in Homebridge.": "Consigner les événements de mouvement dans Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Durée, en secondes, d'un événement de mouvement avant d'en autoriser un nouveau.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Ajouter un accessoire capteur de présence qui déduit la présence de l'activité du détecteur de mouvement. Par défaut, tout mouvement déclenche la présence. Si l'option détection intelligente est activée, elle est utilisée à la place.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Durée, en secondes, à attendre sans événement de mouvement avant de considérer que la présence n'est plus détectée.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des animaux de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des visages de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des plaques d'immatriculation de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des colis de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des personnes de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des véhicules de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des pleurs de bébé de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des aboiements de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes de voiture de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des klaxons de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes CO de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des bris de glace de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des sirènes de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes de fumée de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio de la parole de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes CO et fumée de UniFi Protect pour déclencher la présence.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Utiliser la détection intelligente de UniFi Protect pour les événements de mouvement HomeKit sur un appareil compatible.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Ajouter des capteurs de contact pour chaque type d'objet de la détection intelligente que UniFi Protect prend en charge.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Ajouter un accessoire capteur de contact qui correspond à une plaque d'immatriculation précise détectée par UniFi Protect. Vous pouvez indiquer plusieurs plaques en les séparant par des tirets (p. ex. PLAQUE1-PLAQUE2-PLAQUE3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Ajouter un accessoire interrupteur pour activer ou désactiver la détection de mouvement dans HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Ajouter un accessoire interrupteur pour déclencher manuellement un événement de détection de mouvement dans HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publier une playlist M3U des caméras Protect sur le port indiqué de ce serveur Homebridge, utilisable dans des apps (p. ex. Channels DVR) capables de diffuser les flux en direct des caméras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Délai, en secondes, avant de supprimer les appareils qui ne sont plus détectés sur le contrôleur Protect. Si l'option est désactivée, les appareils sont supprimés en temps réel, en même temps que sur le contrôleur Protect.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publier sur MQTT toute la télémétrie en temps réel reçue du contrôleur Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Ajouter des accessoires interrupteurs pour contrôler l'enregistrement natif du NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Ajouter des accessoires capteurs pour afficher les informations système du contrôleur Protect (pour l'instant, seulement la température).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Ajouter un accessoire interrupteur pour déclencher l'accessoire système de sécurité, avec l'option liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Présenter le capteur de fuite Protect comme un capteur de contact plutôt qu'un capteur de fuite. Utile pour les automatisations, car les capteurs de contact HomeKit offrent plus d'options d'automatisation que les capteurs de fuite, conçus surtout pour les alertes.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Ajouter un accessoire serrure pour déverrouiller. Pour l'instant, Protect ne permet de déverrouiller que les lecteurs Access dotés d'une caméra, sur le même contrôleur que Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Utiliser le transcodage accéléré par le matériel quand il est disponible (Mac Apple, processeurs Intel avec Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Utiliser l'API de diffusion en direct native de Protect pour afficher les flux en direct.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Pour les clients à faible latence (p. ex. à la maison), transcoder les flux en direct au lieu de les remultiplexer.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à faible latence (p. ex. à la maison), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Pour les clients à latence élevée (p. ex. connexions cellulaires), transcoder les flux en direct au lieu de les remultiplexer.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à latence élevée (p. ex. cellulaires), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de haute qualité du contrôleur Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de basse qualité du contrôleur Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recadrer le flux vidéo de la caméra. Activer cette option force aussi le transcodage des flux en direct.",
    "Left offset of the crop window, as a percentage of the original image width.": "Décalage gauche de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
    "Top offset of the crop window, as a percentage of the original image height.": "Décalage haut de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
    "Width of the crop window, as a percentage of original image width.": "Largeur de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
    "Height of the crop window, as a percentage of original image height.": "Hauteur de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
    "Enable higher quality snapshots.": "Activer des instantanés de meilleure qualité.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Utiliser le voyant d'état de la caméra pour signaler l'enregistrement d'un événement HKSV.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Ajouter un accessoire interrupteur pour activer ou désactiver l'enregistrement des événements HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de haute qualité du contrôleur Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de basse qualité du contrôleur Protect."
  },
  "es": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Gestiona tus cámaras y dispositivos UniFi Protect en HomeKit.",
    "Configured controllers": "Controladores configurados",
    "No controllers configured yet. Add one to get started.": "Aún no hay controladores configurados. Añade uno para empezar.",
    "Add controller": "Añadir controlador",
    "Support": "Soporte",
    "Discover your controller": "Descubre tu controlador",
    "Scan your network for UniFi Protect controllers, or enter the address manually.": "Busca controladores UniFi Protect en tu red o introduce la dirección manualmente.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Asegúrate de que tu consola UniFi está encendida y conectada a la misma red.",
    "Discover controllers": "Descubrir controladores",
    "Manual entry": "Entrada manual",
    "Cancel": "Cancelar",
    "Add UniFi Protect controller": "Añadir controlador UniFi Protect",
    "Enter your UniFi Protect controller details and login credentials.": "Introduce los datos de tu controlador UniFi Protect y tus credenciales de acceso.",
    "Controller": "Controlador",
    "Hostname or IP (e.g. unvr.local)": "Nombre de host o IP (p. ej., unvr.local)",
    "The address of your UniFi Protect controller.": "La dirección de tu controlador UniFi Protect.",
    "Username": "Nombre de usuario",
    "Local user account username": "Nombre de usuario de la cuenta local",
    "Password": "Contraseña",
    "Local user account password": "Contraseña de la cuenta local",
    "Verify TLS": "Verificar TLS",
    "Validate the controller's TLS certificate. Leave this off unless your controller uses a certificate signed by a trusted certificate authority: UniFi controllers use self-signed certificates, which are pinned the first time instead.": "Valida el certificado TLS del controlador. Déjalo desactivado salvo que tu controlador use un certificado firmado por una autoridad de certificación de confianza: los controladores UniFi usan certificados autofirmados, que se fijan la primera vez.",
    "Local account required.": "Se necesita una cuenta local.",
    "Ubiquiti.com/UI.com accounts are not supported.": "Las cuentas de Ubiquiti.com/UI.com no son compatibles.",
    "Create one in the": "Crea una en la pestaña",
    "tab of your UniFi console.": "de tu consola UniFi.",
    "Save controller": "Guardar controlador",
    "Feature options": "Opciones de funciones",
    "Back": "Atrás",
    "Scope": "Ámbito",
    "Global": "Global",
    "All devices": "Todos los dispositivos",
    "Overrides global": "Sustituye al global",
    "Device": "Dispositivo",
    "Final value": "Valor final",
    "Model": "Modelo",
    "Status": "Estado",
    "Legend": "Leyenda",
    "Set at global": "Definido en global",
    "Set at controller": "Definido en el controlador",
    "Set at device": "Definido en el dispositivo",
    "Search options…": "Buscar opciones…",
    "Modified": "Modificadas",
    "Loading options…": "Cargando opciones…",
    "Third-party camera URLs": "URL de cámara de terceros",
    "The Protect controller often does not relay this camera's stream. Enter the camera's IP and credentials to discover its URLs automatically, or paste the URLs below.": "El controlador Protect a menudo no retransmite el flujo de esta cámara. Introduce la IP y las credenciales de la cámara para descubrir sus URL automáticamente, o pega las URL abajo.",
    "IP address": "Dirección IP",
    "e.g. 192.168.1.50": "p. ej., 192.168.1.50",
    "ONVIF port": "Puerto ONVIF",
    "(optional)": "(opcional)",
    "auto": "auto",
    "Service path": "Ruta del servicio",
    "(optional, /onvif/device_service by default)": "(opcional, /onvif/device_service de forma predeterminada)",
    "Discover URLs": "Descubrir las URL",
    "Stream profile": "Perfil de flujo",
    "Stream preview": "Vista previa del flujo",
    "No preview": "Sin vista previa",
    "Pick the camera stream HomeKit should use. Higher resolutions look better but cost more bandwidth and CPU.": "Elige el flujo de la cámara que debe usar HomeKit. Las resoluciones más altas se ven mejor, pero consumen más ancho de banda y CPU.",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directa",
    "Direct snapshot URL": "URL directa de instantánea",
    "Leave both URL fields blank to remove the override.": "Deja vacíos los dos campos de URL para quitar la sustitución.",
    "You have unsaved changes. Saving applies them: the plugin restarts with them.": "Tienes cambios sin guardar. Al guardarlos se aplican: el plugin se reinicia con ellos.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca de este plugin",
    "The Homeswift port of": "La adaptación para Homeswift de",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "Su documentación sirve aquí: las opciones, las opciones de funciones y los temas MQTT son los mismos.",
    "Getting started": "Primeros pasos",
    "Install, configure and connect to HomeKit.": "Instalar, configurar y conectar a HomeKit.",
    "Options for a controller or a device.": "Opciones para un controlador o un dispositivo.",
    "How to configure MQTT support.": "Cómo configurar la compatibilidad con MQTT.",
    "How-to guides": "Guías prácticas",
    "Doorbells": "Timbres",
    "Two-way audio, ring events and LCD messages.": "Audio bidireccional, eventos de llamada y mensajes LCD.",
    "HKSV with Protect cameras.": "HKSV con cámaras Protect.",
    "Liveview scenes": "Escenas Liveview",
    "Motion detection scenes and the security system.": "Escenas de detección de movimiento y el sistema de seguridad.",
    "Troubleshooting": "Solución de problemas",
    "Login, network and video problems.": "Problemas de inicio de sesión, red y vídeo.",
    "Checking": "Comprobando",
    "Devices": "Dispositivos",
    "Events": "Eventos",
    "Live": "En directo",
    "Every 2 minutes": "Cada 2 minutos",
    "Certificate": "Certificado",
    "Verified": "Verificado",
    "Pinned": "Fijado",
    "Not yet seen": "Aún no visto",
    "Remove {name}?": "¿Eliminar {name}?",
    "Unable to remove the controller: {error}": "No se ha podido eliminar el controlador: {error}",
    "Connected": "Conectado",
    "Not connected yet: see the log.": "Aún no conectado: consulta el registro.",
    "Not running": "Detenido",
    "Actions for {name}": "Acciones de {name}",
    "Edit": "Editar",
    "Remove": "Eliminar",
    "Online": "En línea",
    "Offline": "Sin conexión",
    "Unknown": "Desconocido",
    "Searching…": "Buscando…",
    "All discovered devices are already configured.": "Todos los dispositivos descubiertos ya están configurados.",
    "No devices found. Make sure your UniFi console is on and connected.": "No se han encontrado dispositivos. Asegúrate de que tu consola UniFi está encendida y conectada.",
    "Found devices:": "Dispositivos encontrados:",
    "Select": "Elegir",
    "Discovery error: {error}": "Error de descubrimiento: {error}",
    "Edit controller": "Editar controlador",
    "Editing {name}": "Editando {name}",
    "Please fill in all fields.": "Rellena todos los campos.",
    "Validating…": "Validando…",
    "Unable to connect. {error}": "No se ha podido conectar. {error}",
    "Check your address and credentials.": "Revisa la dirección y las credenciales.",
    "Error: {error}": "Error: {error}",
    "Unable to load the devices of this controller. {error}": "No se han podido cargar los dispositivos de este controlador. {error}",
    "Check its address and credentials.": "Revisa su dirección y sus credenciales.",
    "Failed to load: {error}": "Error al cargar: {error}",
    "{device}: {problem}": "{device}: {problem}",
    "This device": "Este dispositivo",
    "Cameras": "Cámaras",
    "Chimes": "Carillones",
    "Lights": "Luces",
    "Sensors": "Sensores",
    "Viewers": "Visores",
    "Global options": "Opciones globales",
    "Controller: {name}": "Controlador: {name}",
    "Camera": "Cámara",
    "Editing this scope": "Ámbito en edición",
    "Inherits global": "Hereda del global",
    "Base values": "Valores base",
    "Inherits controller": "Hereda del controlador",
    "Intermediate": "Intermedio",
    "{connection} device": "Dispositivo {connection}",
    "N/A": "N/D",
    "No modified options": "No hay opciones modificadas",
    "No options match your search": "Ninguna opción coincide con tu búsqueda",
    "No options available": "No hay opciones disponibles",
    "{enabled}/{total} on": "{enabled}/{total} activadas",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "millisecond": "milisegundo",
    "milliseconds": "milisegundos",
    "decibel": "decibelio",
    "decibels": "decibelios",
    "Hertz": "hercios",
    "kilobits per second": "kilobits por segundo",
    "percentage": "porcentaje",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "{option} value": "Valor de {option}",
    "(default: {value})": "(predeterminado: {value})",
    "none": "ninguno",
    "Reset to inherited value": "Restablecer el valor heredado",
    "default: on": "predeterminado: activada",
    "default: off": "predeterminado: desactivada",
    "IP address and username are required.": "La dirección IP y el nombre de usuario son obligatorios.",
    "Discovering…": "Descubriendo…",
    "Discovery failed: {error}": "Error en el descubrimiento: {error}",
    "unknown error": "error desconocido",
    "Camera did not return any URLs.": "La cámara no ha devuelto ninguna URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "Se han encontrado {n} perfiles en el puerto {port}. Elige el que quieras usar.",
    "Camera reports {n} profiles but they all map to the same stream. Discovered URLs on port {port}.": "La cámara indica {n} perfiles, pero todos corresponden al mismo flujo. URL descubiertas en el puerto {port}.",
    "Discovered URLs on port {port}.": "URL descubiertas en el puerto {port}.",
    "Saved. Restart Homeswift to apply: {changes}.": "Guardado. Reinicia Homeswift para aplicar: {changes}.",
    "Discard the changes?": "¿Descartar los cambios?",
    "Leave without saving the changes?": "¿Salir sin guardar los cambios?",
    "Profile {n}": "Perfil {n}",
    "this camera": "esta cámara",
    "this chime": "este carillón",
    "this light": "esta luz",
    "this sensor": "este sensor",
    "this viewer": "este visor",
    "this device": "este dispositivo",
    "this {model}": "este dispositivo ({model})",
    "UniFi Protect reports {device} as updating its firmware.": "UniFi Protect indica que {device} está actualizando su firmware.",
    "UniFi Protect reports {device} as {state} (not connected).": "UniFi Protect indica el estado «{state}» para {device} (no conectado).",
    "Enter the password: this controller's certificate is not pinned yet.": "Introduce la contraseña: el certificado de este controlador aún no está fijado.",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Se ha agotado el tiempo tras {0} s esperando la respuesta de {1}. Comprueba que la dirección y las credenciales son correctas y que el controlador es accesible desde este equipo de Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0}: error de la API: credenciales de acceso no válidas. Revisa tu usuario y tu contraseña.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0}: error de la API: privilegios insuficientes para este usuario. Revisa los roles asignados a este usuario y asegúrate de que tiene privilegios suficientes.",
    "{0}: API error: Connection refused.": "{0}: error de la API: conexión rechazada.",
    "{0}: API error: Connection timed out.": "{0}: error de la API: se ha agotado el tiempo de conexión.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0}: error de la API: no se ha encontrado el nombre de host o la dirección IP: {1}. Comprueba que la dirección configurada para este controlador UniFi Protect es correcta.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0}: error de la API: no se puede conectar con el controlador Protect. Es temporal y puede ocurrir mientras se reinician los dispositivos.",
    "Invalid address.": "Dirección no válida.",
    "Unable to resolve {0}.": "No se puede resolver {0}.",
    "Connections to {0} are not permitted.": "No se permiten conexiones a {0}.",
    "ONVIF request timed out": "Se ha agotado el tiempo de espera de la solicitud ONVIF",
    "host and username are required.": "el host y el nombre de usuario son obligatorios.",
    "No reachable ONVIF service on {0} ({1}).": "No hay ningún servicio ONVIF accesible en {0} ({1}).",
    "Camera did not return a Media service capability.": "La cámara no ha devuelto ningún servicio Media.",
    "Camera did not return a Media service XAddr.": "La cámara no ha devuelto el XAddr del servicio Media.",
    "Camera returned no media profiles.": "La cámara no ha devuelto ningún perfil multimedia.",
    "The camera advertised its media service on a different host. Using {0} instead.": "La cámara anuncia su servicio multimedia en otro host. Se usa {0} en su lugar.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "La cámara ha devuelto URL de flujo o de instantánea en un host distinto de {0}. No se han añadido las credenciales a esas URL.",
    "Audio": "Audio",
    "Doorbell": "Timbre",
    "Logging": "Registro",
    "Motion": "Movimiento",
    "Security System": "Sistema de seguridad",
    "Sensor": "Sensor",
    "Video": "Vídeo",
    "Audio support.": "Compatibilidad con audio.",
    "Audio filter for ambient noise suppression.": "Filtro de audio para suprimir el ruido ambiente.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nivel de reducción de ruido, en decibelios, para el filtro afftdn de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frecuencia, en hercios, para el filtro highpass de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frecuencia, en hercios, para el filtro lowpass de FFmpeg.",
    "Two-way audio support on supported cameras.": "Audio bidireccional en las cámaras compatibles.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar el audio bidireccional directamente a las cámaras compatibles, sin pasar por el controlador. Útil para sortear errores de algunas versiones del firmware de los controladores Protect.",
    "Make this device available in HomeKit.": "Hacer que este dispositivo esté disponible en HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Activar la luz indicadora de estado de este dispositivo en HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Añadir un accesorio interruptor para controlar la luz indicadora de estado en HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Activar la luz indicadora de visión nocturna de este dispositivo en HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Añadir un accesorio regulador para controlar la visión nocturna en HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Convertir este dispositivo en un dispositivo independiente en HomeKit, que habrá que añadir a HomeKit desde la app Casa.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Intentar reiniciar los dispositivos que fallan. Siempre se hace con mucha prudencia y solo tras periodos prolongados de problemas propios del dispositivo.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar el nombre de UniFi Protect de este dispositivo con HomeKit. La sincronización es solo en un sentido: el nombre pasa de UniFi Protect a HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Añadir un sensor de contacto que se activa cuando una huella dactilar o un NFC se autentica en un timbre Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Añadir un accesorio interruptor para elegir si HomeKit suena cuando se pulsa el timbre.",
    "Enable the doorbell messages feature.": "Activar la función de mensajes del timbre.",
    "Use messages saved to the Protect NVR as message switches.": "Usar los mensajes guardados en el NVR Protect como interruptores de mensaje.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Añadir un accesorio regulador para controlar el volumen del carillón Protect en HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Añadir accesorios interruptores para controlar los carillones físicos conectados a un timbre Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duración del sonido, en milisegundos, de un carillón físico digital conectado a un timbre Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Añadir un accesorio de luz para controlar la linterna de la cámara de paquetes de un timbre Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Añadir un accesorio interruptor para activar eventos de llamada en una cámara o un timbre Protect.",
    "Log doorbell ring events in Homebridge.": "Registrar los eventos de llamada del timbre en Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Registrar los eventos de grabación de HomeKit Secure Video en Homebridge.",
    "Log motion events in Homebridge.": "Registrar los eventos de movimiento en Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Duración, en segundos, de un evento de movimiento antes de permitir uno nuevo.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Añadir un accesorio sensor de ocupación que usa la actividad del sensor de movimiento para determinar la ocupación. De forma predeterminada, cualquier movimiento activa la ocupación. Si la opción de detección inteligente está activada, se usa en su lugar.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duración, en segundos, que se espera sin recibir eventos de movimiento para considerar que ya no hay ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de animales de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de caras de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de matrículas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de paquetes de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de personas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de vehículos de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de llanto de bebé de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de ladridos de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de coche de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de cláxones de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de CO de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de rotura de cristales de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de sirenas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de humo de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de voz de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de CO y humo de UniFi Protect para activar la ocupación.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar la detección inteligente de UniFi Protect para los eventos de movimiento de HomeKit en un dispositivo compatible.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Añadir sensores de contacto para cada tipo de objeto de detección inteligente que admite UniFi Protect.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Añadir un accesorio sensor de contacto que corresponde a una matrícula concreta detectada por UniFi Protect. Puedes indicar varias matrículas separándolas con guiones (p. ej., MATRICULA1-MATRICULA2-MATRICULA3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Añadir un accesorio interruptor para activar o desactivar la detección de movimiento en HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Añadir un accesorio interruptor para activar manualmente un evento de detección de movimiento en HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publicar una lista M3U de las cámaras Protect en el puerto indicado de este servidor Homebridge, apta para apps (p. ej., Channels DVR) que pueden ofrecer las transmisiones en directo de las cámaras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Retardo, en segundos, antes de eliminar los dispositivos que ya no se detectan en el controlador Protect. Si está desactivado, los dispositivos se eliminan en tiempo real cuando lo hace el controlador Protect.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar en MQTT toda la telemetría en tiempo real recibida del controlador Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Añadir accesorios interruptores para controlar la grabación nativa del NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Añadir accesorios sensores para mostrar la información del sistema del controlador Protect (por ahora, solo la temperatura).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Añadir un accesorio interruptor para activar el accesorio sistema de seguridad, al usar la opción liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Mostrar el sensor de fugas Protect como sensor de contacto en lugar de sensor de fugas. Es útil para las automatizaciones, ya que los sensores de contacto de HomeKit ofrecen más opciones de automatización que los sensores de fugas, pensados sobre todo para alertas.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Añadir un accesorio cerradura para desbloquear. Por ahora, Protect solo permite desbloquear lectores Access con cámara en el mismo controlador que Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar la transcodificación acelerada por hardware cuando esté disponible (Mac de Apple, CPU Intel con Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Usar la API nativa de transmisión en directo de Protect para ver las transmisiones en directo.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Al transmitir a clientes de baja latencia (p. ej., en casa), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de baja latencia (p. ej., en casa), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Al transmitir a clientes de alta latencia (p. ej., conexiones móviles), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de alta latencia (p. ej., móviles), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de alta calidad del controlador Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de media calidad del controlador Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de baja calidad del controlador Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar el flujo de vídeo de la cámara. Activar esta opción también fuerza la transcodificación de las transmisiones en directo.",
    "Left offset of the crop window, as a percentage of the original image width.": "Desplazamiento izquierdo del recorte, como porcentaje del ancho de la imagen original.",
    "Top offset of the crop window, as a percentage of the original image height.": "Desplazamiento superior del recorte, como porcentaje del alto de la imagen original.",
    "Width of the crop window, as a percentage of original image width.": "Ancho del recorte, como porcentaje del ancho de la imagen original.",
    "Height of the crop window, as a percentage of original image height.": "Alto del recorte, como porcentaje del alto de la imagen original.",
    "Enable higher quality snapshots.": "Activar instantáneas de mayor calidad.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar la luz indicadora de estado de la cámara para mostrar cuándo se graba un evento HKSV.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Añadir un accesorio interruptor para activar o desactivar la grabación de eventos HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de alta calidad del controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de media calidad del controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de baja calidad del controlador Protect."
  },
  "pt": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Faça a gestão das câmaras e dispositivos UniFi Protect no HomeKit.",
    "Configured controllers": "Controladores configurados",
    "No controllers configured yet. Add one to get started.": "Ainda não há controladores configurados. Adicione um para começar.",
    "Add controller": "Adicionar controlador",
    "Support": "Suporte",
    "Discover your controller": "Descobrir o controlador",
    "Scan your network for UniFi Protect controllers, or enter the address manually.": "Procure controladores UniFi Protect na rede ou introduza o endereço manualmente.",
    "Make sure your UniFi console is powered on and connected to the same network.": "Confirme que a consola UniFi está ligada e na mesma rede.",
    "Discover controllers": "Descobrir controladores",
    "Manual entry": "Introdução manual",
    "Cancel": "Cancelar",
    "Add UniFi Protect controller": "Adicionar controlador UniFi Protect",
    "Enter your UniFi Protect controller details and login credentials.": "Introduza os dados do controlador UniFi Protect e as credenciais de acesso.",
    "Controller": "Controlador",
    "Hostname or IP (e.g. unvr.local)": "Nome do anfitrião ou IP (p. ex. unvr.local)",
    "The address of your UniFi Protect controller.": "O endereço do controlador UniFi Protect.",
    "Username": "Nome de utilizador",
    "Local user account username": "Nome de utilizador da conta local",
    "Password": "Palavra-passe",
    "Local user account password": "Palavra-passe da conta local",
    "Verify TLS": "Verificar o TLS",
    "Validate the controller's TLS certificate. Leave this off unless your controller uses a certificate signed by a trusted certificate authority: UniFi controllers use self-signed certificates, which are pinned the first time instead.": "Valida o certificado TLS do controlador. Deixe desativado, a menos que o controlador use um certificado assinado por uma autoridade de certificação de confiança: os controladores UniFi usam certificados autoassinados, que são fixados na primeira ligação.",
    "Local account required.": "É necessária uma conta local.",
    "Ubiquiti.com/UI.com accounts are not supported.": "As contas Ubiquiti.com/UI.com não são suportadas.",
    "Create one in the": "Crie uma no separador",
    "tab of your UniFi console.": "da consola UniFi.",
    "Save controller": "Guardar controlador",
    "Feature options": "Opções de funcionalidades",
    "Back": "Voltar",
    "Scope": "Âmbito",
    "Global": "Global",
    "All devices": "Todos os dispositivos",
    "Overrides global": "Substitui o global",
    "Device": "Dispositivo",
    "Final value": "Valor final",
    "Model": "Modelo",
    "Status": "Estado",
    "Legend": "Legenda",
    "Set at global": "Definido no global",
    "Set at controller": "Definido no controlador",
    "Set at device": "Definido no dispositivo",
    "Search options…": "Procurar opções…",
    "Modified": "Modificadas",
    "Loading options…": "A carregar as opções…",
    "Third-party camera URLs": "URL de câmaras de terceiros",
    "The Protect controller often does not relay this camera's stream. Enter the camera's IP and credentials to discover its URLs automatically, or paste the URLs below.": "O controlador Protect muitas vezes não retransmite o fluxo desta câmara. Introduza o IP e as credenciais da câmara para descobrir os URL automaticamente, ou cole os URL abaixo.",
    "IP address": "Endereço IP",
    "e.g. 192.168.1.50": "p. ex. 192.168.1.50",
    "ONVIF port": "Porta ONVIF",
    "(optional)": "(opcional)",
    "auto": "auto",
    "Service path": "Caminho do serviço",
    "(optional, /onvif/device_service by default)": "(opcional, /onvif/device_service por predefinição)",
    "Discover URLs": "Descobrir os URL",
    "Stream profile": "Perfil de fluxo",
    "Stream preview": "Pré-visualização do fluxo",
    "No preview": "Sem pré-visualização",
    "Pick the camera stream HomeKit should use. Higher resolutions look better but cost more bandwidth and CPU.": "Escolha o fluxo da câmara que o HomeKit deve usar. Resoluções mais altas têm melhor imagem, mas gastam mais largura de banda e CPU.",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS direto",
    "Direct snapshot URL": "URL direto de instantâneo",
    "Leave both URL fields blank to remove the override.": "Deixe os dois campos de URL vazios para remover a substituição.",
    "You have unsaved changes. Saving applies them: the plugin restarts with them.": "Há alterações não guardadas. Ao guardar, são aplicadas e o plugin reinicia com elas.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca deste plugin",
    "The Homeswift port of": "A adaptação para Homeswift do",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "A sua documentação aplica-se aqui: as opções, as opções de funcionalidades e os tópicos MQTT são os mesmos.",
    "Getting started": "Primeiros passos",
    "Install, configure and connect to HomeKit.": "Instalar, configurar e ligar ao HomeKit.",
    "Options for a controller or a device.": "Opções para um controlador ou um dispositivo.",
    "How to configure MQTT support.": "Como configurar o suporte de MQTT.",
    "How-to guides": "Guias práticos",
    "Doorbells": "Campainhas",
    "Two-way audio, ring events and LCD messages.": "Áudio bidirecional, eventos de toque e mensagens LCD.",
    "HKSV with Protect cameras.": "HKSV com câmaras Protect.",
    "Liveview scenes": "Cenas Liveview",
    "Motion detection scenes and the security system.": "Cenas de deteção de movimento e o sistema de segurança.",
    "Troubleshooting": "Resolução de problemas",
    "Login, network and video problems.": "Problemas de início de sessão, rede e vídeo.",
    "Checking": "A verificar",
    "Devices": "Dispositivos",
    "Events": "Eventos",
    "Live": "Em direto",
    "Every 2 minutes": "A cada 2 minutos",
    "Certificate": "Certificado",
    "Verified": "Verificado",
    "Pinned": "Fixado",
    "Not yet seen": "Ainda não visto",
    "Remove {name}?": "Remover {name}?",
    "Unable to remove the controller: {error}": "Não foi possível remover o controlador: {error}",
    "Connected": "Ligado",
    "Not connected yet: see the log.": "Ainda não ligado: consulte o registo.",
    "Not running": "Parado",
    "Actions for {name}": "Ações de {name}",
    "Edit": "Editar",
    "Remove": "Remover",
    "Online": "Online",
    "Offline": "Offline",
    "Unknown": "Desconhecido",
    "Searching…": "A procurar…",
    "All discovered devices are already configured.": "Todos os dispositivos descobertos já estão configurados.",
    "No devices found. Make sure your UniFi console is on and connected.": "Nenhum dispositivo encontrado. Confirme que a consola UniFi está ligada e na rede.",
    "Found devices:": "Dispositivos encontrados:",
    "Select": "Escolher",
    "Discovery error: {error}": "Erro na descoberta: {error}",
    "Edit controller": "Editar controlador",
    "Editing {name}": "A editar {name}",
    "Please fill in all fields.": "Preencha todos os campos.",
    "Validating…": "A validar…",
    "Unable to connect. {error}": "Não foi possível ligar. {error}",
    "Check your address and credentials.": "Verifique o endereço e as credenciais.",
    "Error: {error}": "Erro: {error}",
    "Unable to load the devices of this controller. {error}": "Não foi possível carregar os dispositivos deste controlador. {error}",
    "Check its address and credentials.": "Verifique o endereço e as credenciais.",
    "Failed to load: {error}": "Falha ao carregar: {error}",
    "{device}: {problem}": "{device}: {problem}",
    "This device": "Este dispositivo",
    "Cameras": "Câmaras",
    "Chimes": "Carrilhões",
    "Lights": "Luzes",
    "Sensors": "Sensores",
    "Viewers": "Visores",
    "Global options": "Opções globais",
    "Controller: {name}": "Controlador: {name}",
    "Camera": "Câmara",
    "Editing this scope": "Âmbito em edição",
    "Inherits global": "Herda do global",
    "Base values": "Valores base",
    "Inherits controller": "Herda do controlador",
    "Intermediate": "Intermédio",
    "{connection} device": "Dispositivo {connection}",
    "N/A": "N/D",
    "No modified options": "Nenhuma opção modificada",
    "No options match your search": "Nenhuma opção corresponde à pesquisa",
    "No options available": "Nenhuma opção disponível",
    "{enabled}/{total} on": "{enabled}/{total} ativadas",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "millisecond": "milissegundo",
    "milliseconds": "milissegundos",
    "decibel": "decibel",
    "decibels": "decibéis",
    "Hertz": "hertz",
    "kilobits per second": "kilobits por segundo",
    "percentage": "percentagem",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "{option} value": "Valor de {option}",
    "(default: {value})": "(predefinição: {value})",
    "none": "nenhum",
    "Reset to inherited value": "Repor o valor herdado",
    "default: on": "predefinição: ativada",
    "default: off": "predefinição: desativada",
    "IP address and username are required.": "O endereço IP e o nome de utilizador são obrigatórios.",
    "Discovering…": "A descobrir…",
    "Discovery failed: {error}": "A descoberta falhou: {error}",
    "unknown error": "erro desconhecido",
    "Camera did not return any URLs.": "A câmara não devolveu nenhum URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "Foram encontrados {n} perfis na porta {port}. Escolha o que pretende usar.",
    "Camera reports {n} profiles but they all map to the same stream. Discovered URLs on port {port}.": "A câmara indica {n} perfis, mas todos correspondem ao mesmo fluxo. URL descobertos na porta {port}.",
    "Discovered URLs on port {port}.": "URL descobertos na porta {port}.",
    "Saved. Restart Homeswift to apply: {changes}.": "Guardado. Reinicie o Homeswift para aplicar: {changes}.",
    "Discard the changes?": "Descartar as alterações?",
    "Leave without saving the changes?": "Sair sem guardar as alterações?",
    "Profile {n}": "Perfil {n}",
    "this camera": "esta câmara",
    "this chime": "este carrilhão",
    "this light": "esta luz",
    "this sensor": "este sensor",
    "this viewer": "este visor",
    "this device": "este dispositivo",
    "this {model}": "este dispositivo ({model})",
    "UniFi Protect reports {device} as updating its firmware.": "O UniFi Protect indica que {device} está a atualizar o firmware.",
    "UniFi Protect reports {device} as {state} (not connected).": "O UniFi Protect indica o estado «{state}» para {device} (não ligado).",
    "Enter the password: this controller's certificate is not pinned yet.": "Introduza a palavra-passe: o certificado deste controlador ainda não está fixado.",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Tempo esgotado após {0} s à espera de resposta de {1}. Verifique se o endereço e as credenciais estão corretos e se o controlador está acessível a partir deste computador Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0}: erro da API: credenciais de acesso inválidas. Verifique o nome de utilizador e a palavra-passe.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0}: erro da API: privilégios insuficientes para este utilizador. Verifique as funções atribuídas a este utilizador e confirme que tem privilégios suficientes.",
    "{0}: API error: Connection refused.": "{0}: erro da API: ligação recusada.",
    "{0}: API error: Connection timed out.": "{0}: erro da API: a ligação expirou.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0}: erro da API: nome do anfitrião ou endereço IP não encontrado: {1}. Confirme que o endereço configurado para este controlador UniFi Protect está correto.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0}: erro da API: não é possível ligar ao controlador Protect. É temporário e pode acontecer durante o reinício dos dispositivos.",
    "Invalid address.": "Endereço inválido.",
    "Unable to resolve {0}.": "Não é possível resolver {0}.",
    "Connections to {0} are not permitted.": "Não são permitidas ligações a {0}.",
    "ONVIF request timed out": "O pedido ONVIF expirou",
    "host and username are required.": "o anfitrião e o nome de utilizador são obrigatórios.",
    "No reachable ONVIF service on {0} ({1}).": "Nenhum serviço ONVIF acessível em {0} ({1}).",
    "Camera did not return a Media service capability.": "A câmara não devolveu nenhum serviço Media.",
    "Camera did not return a Media service XAddr.": "A câmara não devolveu o XAddr do serviço Media.",
    "Camera returned no media profiles.": "A câmara não devolveu nenhum perfil multimédia.",
    "The camera advertised its media service on a different host. Using {0} instead.": "A câmara anuncia o serviço multimédia noutro anfitrião. É usado {0} em vez disso.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "A câmara devolveu URL de fluxo ou de instantâneo num anfitrião diferente de {0}. As credenciais não foram adicionadas a esses URL.",
    "Audio": "Áudio",
    "Doorbell": "Campainha",
    "Logging": "Registo",
    "Motion": "Movimento",
    "Security System": "Sistema de segurança",
    "Sensor": "Sensor",
    "Video": "Vídeo",
    "Audio support.": "Suporte de áudio.",
    "Audio filter for ambient noise suppression.": "Filtro de áudio para suprimir o ruído ambiente.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nível de redução de ruído, em decibéis, para o filtro afftdn do FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frequência, em hertz, para o filtro highpass do FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frequência, em hertz, para o filtro lowpass do FFmpeg.",
    "Two-way audio support on supported cameras.": "Áudio bidirecional nas câmaras compatíveis.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar o áudio bidirecional diretamente para as câmaras compatíveis, sem passar pelo controlador. Útil para contornar erros de algumas versões do firmware dos controladores Protect.",
    "Make this device available in HomeKit.": "Disponibilizar este dispositivo no HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Ativar a luz indicadora de estado deste dispositivo no HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Adicionar um acessório interruptor para controlar a luz indicadora de estado no HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Ativar a luz indicadora de visão noturna deste dispositivo no HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Adicionar um acessório regulador para controlar a visão noturna no HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Tornar este dispositivo independente no HomeKit, sendo necessário adicioná-lo ao HomeKit através da app Casa.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tentar reiniciar os dispositivos com falhas. Isto é sempre feito com muita prudência e apenas após períodos prolongados de problemas específicos do dispositivo.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar o nome UniFi Protect deste dispositivo com o HomeKit. A sincronização é apenas num sentido: o nome passa do UniFi Protect para o HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Adicionar um sensor de contacto que é ativado quando uma impressão digital ou um NFC é autenticado numa campainha Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Adicionar um acessório interruptor para escolher se o HomeKit toca quando a campainha é premida.",
    "Enable the doorbell messages feature.": "Ativar a funcionalidade de mensagens da campainha.",
    "Use messages saved to the Protect NVR as message switches.": "Usar as mensagens guardadas no NVR Protect como interruptores de mensagem.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Adicionar um acessório regulador para controlar o volume do carrilhão Protect no HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Adicionar acessórios interruptores para controlar os carrilhões físicos ligados a uma campainha Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duração do toque, em milissegundos, de um carrilhão físico digital ligado a uma campainha Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Adicionar um acessório de luz para controlar a lanterna da câmara de encomendas de uma campainha Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Adicionar um acessório interruptor para acionar eventos de toque numa câmara ou campainha Protect.",
    "Log doorbell ring events in Homebridge.": "Registar os eventos de toque da campainha no Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Registar os eventos de gravação do HomeKit Secure Video no Homebridge.",
    "Log motion events in Homebridge.": "Registar os eventos de movimento no Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Duração, em segundos, de um evento de movimento antes de permitir um novo.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Adicionar um acessório sensor de ocupação que usa a atividade do sensor de movimento para determinar a ocupação. Por predefinição, qualquer movimento ativa a ocupação. Se a opção de deteção inteligente estiver ativada, é usada em vez disso.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duração, em segundos, a aguardar sem receber eventos de movimento para considerar que a ocupação deixou de ser detetada.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de animais do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de rostos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de matrículas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de encomendas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de pessoas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de veículos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de choro de bebé do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de latidos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de carro do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de buzinas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de CO do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de quebra de vidros do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de sirenes do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de fumo do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de fala do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de CO e fumo do UniFi Protect para ativar a ocupação.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar a deteção inteligente do UniFi Protect para os eventos de movimento do HomeKit num dispositivo compatível.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Adicionar sensores de contacto para cada tipo de objeto da deteção inteligente suportado pelo UniFi Protect.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Adicionar um acessório sensor de contacto que corresponde a uma matrícula específica detetada pelo UniFi Protect. É possível indicar várias matrículas separando-as com hífenes (p. ex. MATRICULA1-MATRICULA2-MATRICULA3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Adicionar um acessório interruptor para ativar ou desativar a deteção de movimento no HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Adicionar um acessório interruptor para acionar manualmente um evento de deteção de movimento no HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publicar uma lista M3U das câmaras Protect na porta indicada deste servidor Homebridge, adequada para apps (p. ex. Channels DVR) que conseguem disponibilizar as transmissões em direto das câmaras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Atraso, em segundos, antes de remover os dispositivos que deixaram de ser detetados no controlador Protect. Se estiver desativado, os dispositivos são removidos em tempo real quando o controlador Protect o faz.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar no MQTT toda a telemetria em tempo real recebida do controlador Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Adicionar acessórios interruptores para controlar a gravação nativa do NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Adicionar acessórios sensores para mostrar as informações do sistema do controlador Protect (por agora, apenas a temperatura).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Adicionar um acessório interruptor para acionar o acessório sistema de segurança, ao usar a opção liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Apresentar o sensor de fugas Protect como sensor de contacto em vez de sensor de fugas. É útil para automatizações, porque os sensores de contacto do HomeKit oferecem mais opções de automatização do que os sensores de fugas, pensados sobretudo para alertas.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Adicionar um acessório fechadura para destrancar. Por agora, o Protect só permite destrancar leitores Access com câmara no mesmo controlador que o Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar a transcodificação acelerada por hardware quando disponível (Mac da Apple, CPU Intel com Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Usar a API nativa de transmissão em direto do Protect para ver as transmissões em direto.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Ao transmitir para clientes de baixa latência (p. ex. em casa), transcodificar as transmissões em direto em vez de as remultiplexar.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de baixa latência (p. ex. em casa), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Ao transmitir para clientes de alta latência (p. ex. ligações móveis), transcodificar as transmissões em direto em vez de as remultiplexar.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de alta latência (p. ex. móveis), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de baixa qualidade do controlador Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar o fluxo de vídeo da câmara. Ativar esta opção também força a transcodificação das transmissões em direto.",
    "Left offset of the crop window, as a percentage of the original image width.": "Deslocamento esquerdo da área de recorte, em percentagem da largura da imagem original.",
    "Top offset of the crop window, as a percentage of the original image height.": "Deslocamento superior da área de recorte, em percentagem da altura da imagem original.",
    "Width of the crop window, as a percentage of original image width.": "Largura da área de recorte, em percentagem da largura da imagem original.",
    "Height of the crop window, as a percentage of original image height.": "Altura da área de recorte, em percentagem da altura da imagem original.",
    "Enable higher quality snapshots.": "Ativar instantâneos de maior qualidade.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar a luz indicadora de estado da câmara para mostrar quando um evento HKSV está a ser gravado.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Adicionar um acessório interruptor para ativar ou desativar a gravação de eventos HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de baixa qualidade do controlador Protect."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UniFi Protect</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="protect.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10.5l5-3v9l-5-3z"/></svg></span>
    <div>
      <h1>UniFi Protect</h1>
      <p class="muted" data-i18n>Manage your UniFi Protect cameras and devices in HomeKit.</p>
    </div>
  </div>

  <!-- The controllers: the page opens here once one is configured. -->
  <section id="controllersScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Configured controllers</h2></div>
    <p id="noControllers" class="card muted hidden" data-i18n>No controllers configured yet. Add one to get started.</p>
    <div id="controllersList" class="controllers"></div>
    <div class="actions row-actions">
      <button id="addControllerBtn" class="primary" data-i18n data-action-icon="plus">Add controller</button>
      <button id="supportBtn" data-i18n>Support</button>
    </div>
  </section>

  <!-- Discovery of UniFi consoles, or manual entry. -->
  <section id="discoveryScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Discover your controller</h2></div>
    <div class="card">
      <p class="muted" data-i18n>Scan your network for UniFi Protect controllers, or enter the address manually.</p>
      <p class="note" data-i18n>Make sure your UniFi console is powered on and connected to the same network.</p>
      <div class="actions row-actions">
        <button id="discoverBtn" class="primary" data-i18n data-action-icon="search">Discover controllers</button>
        <button id="manualEntryBtn" data-i18n>Manual entry</button>
        <button id="cancelDiscoveryBtn" class="link hidden" data-i18n data-action-icon="close">Cancel</button>
      </div>
      <div id="deviceList" class="found"></div>
    </div>
  </section>

  <!-- Add or edit a controller. -->
  <section id="setupScreen" class="screen hidden">
    <div class="section-head"><h2 id="setupTitle" data-i18n>Add UniFi Protect controller</h2></div>
    <form id="setupForm" class="card" novalidate>
      <p id="setupSubtitle" class="muted" data-i18n>Enter your UniFi Protect controller details and login credentials.</p>
      <div class="fields">
        <label class="field"><span class="field-title" data-i18n>Controller</span>
          <input id="inputAddress" type="text" placeholder="Hostname or IP (e.g. unvr.local)" autocomplete="off" spellcheck="false" required data-i18n>
          <span class="help" data-i18n>The address of your UniFi Protect controller.</span></label>
        <label class="field"><span class="field-title" data-i18n>Username</span>
          <input id="inputUsername" type="text" autocomplete="username" placeholder="Local user account username" required data-i18n></label>
        <label class="field"><span class="field-title" data-i18n>Password</span>
          <input id="inputPassword" type="password" autocomplete="current-password" placeholder="Local user account password" required data-i18n></label>
      </div>
      <label class="toggle">
        <span class="switch"><input id="inputVerifyTls" type="checkbox"><span></span></span>
        <span><span class="field-title" data-i18n>Verify TLS</span>
          <span class="help" data-i18n>Validate the controller's TLS certificate. Leave this off unless your controller uses a certificate signed by a trusted certificate
          authority: UniFi controllers use self-signed certificates, which are pinned the first time instead.</span></span>
      </label>
      <div id="setupError" class="problem hidden"><p id="setupErrorText" class="error"></p><div id="setupAssistant"></div></div>
      <p class="note"><strong data-i18n>Local account required.</strong> <span data-i18n>Ubiquiti.com/UI.com accounts are not supported.</span> <span data-i18n>Create one in the</span> <em>Admins &amp; Users</em> <span data-i18n>tab of your UniFi console.</span></p>
      <div class="save-bar">
        <span class="muted"></span>
        <button id="cancelSetupBtn" type="button" data-i18n data-action-icon="close">Cancel</button>
        <button id="saveControllerBtn" class="primary" type="submit" data-i18n data-action-icon="check">Save controller</button>
      </div>
    </form>
  </section>

  <!-- Feature options: scope on the side, options by category. -->
  <section id="featureOptionsScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Feature options</h2><button id="backFromOptionsBtn" class="link" data-i18n data-action-icon="restore">Back</button></div>
    <div class="options-layout">
      <aside class="scope-side">
        <div class="card compact-card">
          <label class="field"><span class="field-title" data-i18n>Scope</span><select id="scopeSelect"></select></label>
        </div>
        <div class="card compact-card" id="scopeCascade">
          <div class="scope-level" data-scope="global"><span class="scope-dot">G</span><span><b data-i18n>Global</b><span class="scope-hint muted" data-i18n>All devices</span></span></div>
          <div class="scope-connector" aria-hidden="true"></div>
          <div class="scope-level" data-scope="controller"><span class="scope-dot">C</span><span><b data-i18n>Controller</b><span class="scope-hint muted" data-i18n>Overrides global</span></span></div>
          <div class="scope-connector" aria-hidden="true"></div>
          <div class="scope-level" data-scope="device"><span class="scope-dot">D</span><span><b data-i18n>Device</b><span class="scope-hint muted" data-i18n>Final value</span></span></div>
        </div>
        <div id="deviceInfoPanel" class="card compact-card hidden">
          <div id="infoPreview" class="info-preview hidden"></div>
          <div class="facts">
            <div class="fact"><span data-i18n>Model</span><b id="infoModel"></b></div>
            <div class="fact"><span>MAC</span><b id="infoMac" class="mono"></b></div>
            <div class="fact"><span>IP</span><b id="infoIp" class="mono"></b></div>
            <div class="fact"><span data-i18n>Status</span><b id="infoStatus"></b></div>
          </div>
        </div>
        <div class="card compact-card legend">
          <span class="muted" data-i18n>Legend</span>
          <span><i class="bar global"></i> <span data-i18n>Set at global</span></span>
          <span><i class="bar controller"></i> <span data-i18n>Set at controller</span></span>
          <span><i class="bar device"></i> <span data-i18n>Set at device</span></span>
        </div>
      </aside>
      <div class="options-main">
        <div class="toolbar">
          <input id="optionsSearch" class="search" type="search" placeholder="Search options…" data-i18n>
          <label class="toggle compact"><span class="switch"><input id="modifiedOnlyToggle" type="checkbox"><span></span></span><span><span data-i18n>Modified</span> <span id="modifiedSummary"></span></span></label>
        </div>
        <p id="optionsLoading" class="muted" data-i18n>Loading options…</p>
        <div id="infoAssistant" class="hidden"></div>
        <div id="thirdPartyOverridesPanel" class="card category hidden">
          <button id="thirdPartyOverridesHeader" class="category-head" type="button"><span class="category-icon" style="--category-color: #0d6efd">◉</span><span class="category-title" data-i18n>Third-party camera URLs</span><span class="chevron">⌄</span></button>
          <div id="thirdPartyOverridesBody" class="category-body">
            <p class="muted" data-i18n>The Protect controller often does not relay this camera's stream. Enter the camera's IP and credentials to discover its URLs automatically, or paste the URLs below.</p>
            <div class="fields">
              <label class="field"><span class="field-title" data-i18n>IP address</span><input id="thirdPartyOnvifHost" type="text" placeholder="e.g. 192.168.1.50" autocomplete="off" spellcheck="false" data-i18n></label>
              <label class="field"><span class="field-title" data-i18n>ONVIF port <span class="muted" data-i18n>(optional)</span></span><input id="thirdPartyOnvifPort" type="number" placeholder="auto" min="1" max="65535" data-i18n></label>
              <label class="field"><span class="field-title" data-i18n>Username</span><input id="thirdPartyOnvifUser" type="text" autocomplete="off" spellcheck="false"></label>
              <label class="field"><span class="field-title" data-i18n>Password</span><input id="thirdPartyOnvifPass" type="password" autocomplete="off"></label>
              <label class="field wide"><span class="field-title" data-i18n>Service path <span class="muted" data-i18n>(optional, /onvif/device_service by default)</span></span><input id="thirdPartyOnvifPath" type="text" placeholder="/onvif/device_service" autocomplete="off" spellcheck="false"></label>
            </div>
            <div class="row-actions"><span id="thirdPartyDiscoverStatus" class="status-line"></span><button id="thirdPartyDiscoverBtn" class="primary" type="button" data-i18n data-action-icon="search">Discover URLs</button></div>
            <div id="thirdPartyDiscoverAssistant"></div>
            <div id="thirdPartyProfileSelectorWrap" class="hidden profile-picker">
              <label class="field"><span class="field-title" data-i18n>Stream profile</span><select id="thirdPartyProfileSelect"></select></label>
              <div class="thumb"><img id="thirdPartyProfileThumb" alt="Stream preview" class="hidden" data-i18n><span id="thirdPartyProfileThumbPlaceholder" class="muted" data-i18n>No preview</span></div>
              <p class="help" data-i18n>Pick the camera stream HomeKit should use. Higher resolutions look better but cost more bandwidth and CPU.</p>
            </div>
            <label class="field"><span class="field-title" data-i18n>Direct RTSP / RTSPS URL</span><input id="thirdPartyRtspUrl" type="text" placeholder="rtsp://user:pass@host:port/path" autocomplete="off" spellcheck="false"></label>
            <label class="field"><span class="field-title" data-i18n>Direct snapshot URL</span><input id="thirdPartySnapshotUrl" type="text" placeholder="http://host:port/snapshot" autocomplete="off" spellcheck="false"></label>
            <p class="help" data-i18n>Leave both URL fields blank to remove the override.</p>
          </div>
        </div>
        <div id="optionsProblem" class="hidden"></div>
        <div id="optionsContainer"></div>
        <div id="unsavedChanges" class="card save-bar hidden">
          <span class="dirty" data-i18n>You have unsaved changes. Saving applies them: the plugin restarts with them.</span>
          <button id="discardOptionsBtn" data-i18n data-action-icon="close">Discard</button>
          <button id="saveOptionsBtn" class="primary" data-i18n data-action-icon="check">Save</button>
        </div>
      </div>
    </div>
  </section>

  <!-- Support. -->
  <section id="supportScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Support</h2><button id="backFromSupportBtn" class="link" data-i18n data-action-icon="restore">Back</button></div>
    <div class="card support">
      <h3 data-i18n>About this plugin</h3>
      <p><span data-i18n>The Homeswift port of</span> <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect">homebridge-unifi-protect</a>. <span data-i18n>Its documentation applies here: the options, feature options and MQTT topics are the same.</span></p>
      <h3 data-i18n>Getting started</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/getting-started.md"><b data-i18n>Getting started</b></a><span class="muted" data-i18n>Install, configure and connect to HomeKit.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/feature-options.md"><b data-i18n>Feature options</b></a><span class="muted" data-i18n>Options for a controller or a device.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/mqtt.md"><b>MQTT</b></a><span class="muted" data-i18n>How to configure MQTT support.</span></li>
      </ul>
      <h3 data-i18n>How-to guides</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/doorbell.md"><b data-i18n>Doorbells</b></a><span class="muted" data-i18n>Two-way audio, ring events and LCD messages.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/homekit-secure-video.md"><b>HomeKit Secure Video</b></a><span class="muted" data-i18n>HKSV with Protect cameras.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/liveviews.md"><b data-i18n>Liveview scenes</b></a><span class="muted" data-i18n>Motion detection scenes and the security system.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/troubleshooting.md"><b data-i18n>Troubleshooting</b></a><span class="muted" data-i18n>Login, network and video problems.</span></li>
      </ul>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="/camera.js"></script>
<script src="options.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
        "options.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The logic of the Homebridge plugin's settings page that touches no element (option-state.js, the validity
// tests of renderer.js, the camera override bookkeeping of third-party-overrides.js, and the Assistant's
// whitelists), as window.ProtectOptions. Option entries keep the Homebridge format: Enable|Disable.<Option>
// [.<scope id>][.<value>], the controller's scope id being its address, as that page wrote it.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;

  const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  /// Whether the categories of options apply to a device (all of them at the global and controller scopes).
  function validOptionCategory(device, category) {
    if (!device || device.modelKey === "nvr") return true;
    if (!category.modelKey?.some((model) => ["all", device.modelKey].includes(model))) return false;
    if (category.isNotProperty?.some((property) => device[property] === true)) return false;
    const key = "has" + device.modelKey.charAt(0).toUpperCase() + device.modelKey.slice(1) + "Feature";
    if (category[key]?.some((flag) => !device.featureFlags?.[flag])) return false;
    return true;
  }

  /// Whether an option applies to what the device can do.
  function validOption(device, option) {
    if (device && device.modelKey !== "nvr" && (
      (option.hasAccessFeature && (!device.accessDeviceMetadata?.featureFlags || !option.hasAccessFeature.some((flag) => device.accessDeviceMetadata.featureFlags[flag])))
      || (option.hasFeature && (!device.featureFlags || !option.hasFeature.some((flag) => device.featureFlags[flag])))
      || (option.hasProperty && !option.hasProperty.some((property) => property in device))
      || (option.modelKey && option.modelKey !== "all" && !option.modelKey.includes(device.modelKey))
      || (option.hasSmartObjectType && device.featureFlags?.smartDetectTypes && !option.hasSmartObjectType.some((type) => device.featureFlags.smartDetectTypes.includes(type))))) {
      return false;
    }
    if (device && option.isNotProperty?.some((property) => device[property] === true)) return false;
    switch (device?.modelKey) {
    case "camera": if (option.hasCameraFeature && !option.hasCameraFeature.some((flag) => device.featureFlags[flag])) return false; break;
    case "light": if (option.hasLightProperty && !option.hasLightProperty.some((property) => property in device)) return false; break;
    case "sensor": if (option.hasSensorProperty && !option.hasSensorProperty.some((property) => property in device)) return false; break;
    default: break;
    }
    return true;
  }

  const optionKey = (category, option) => category.name + (option.name ? "." + option.name : "");

  /// Whether the option has an entry at this scope.
  function isOptionModified(options, key, scopeId) {
    const pattern = scopeId
      ? new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(scopeId) + "(\\..*)?$", "i")
      : new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "(?:\\.\\d+)?$", "i");
    return options.some((entry) => pattern.test(entry));
  }

  /// The option at a scope: on or off, where that comes from, and its value.
  function getOptionState(options, key, option, scope, controllerAddress) {
    if (scope.id) {
      const pattern = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(scope.id) + "(?:\\.(\\d+))?$", "i");
      for (const entry of options) {
        const match = pattern.exec(entry);
        if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: true, scope: scope.type, value: match[2] };
      }
    }
    if (scope.type === "device" && controllerAddress) {
      const pattern = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(controllerAddress) + "(?:\\.(\\d+))?$", "i");
      for (const entry of options) {
        const match = pattern.exec(entry);
        if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: false, scope: "controller", value: match[2] };
      }
    }
    const global = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "(?:\\.(\\d+))?$", "i");
    for (const entry of options) {
      const match = global.exec(entry);
      if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: scope.type === "global", scope: "global", value: match[2] };
    }
    return { enabled: option.default, explicit: false, scope: "default" };
  }

  /// The options after turning one on or off (with a value) at a scope: the entry goes only when it differs
  /// from what the scope inherits.
  function setOption(options, key, enabled, scope, option, controllerAddress, value) {
    const remove = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + (scope.id ? "\\." + escapeRegex(scope.id) : "") + "(?:\\.\\d+)?$", "i");
    const result = options.filter((entry) => !remove.test(entry));
    const inherited = option ? getOptionState(result, key, option, scope, controllerAddress) : null;
    const valueDiffers = value !== undefined && value !== option?.defaultValue;
    if (!inherited || inherited.enabled !== enabled || valueDiffers) {
      result.push((enabled ? "Enable" : "Disable") + "." + key + (scope.id ? "." + scope.id : "") + (enabled && valueDiffers ? "." + value : ""));
    }
    return result;
  }

  function removeOption(options, key, scope) {
    const remove = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + (scope.id ? "\\." + escapeRegex(scope.id) : "") + "(?:\\.\\d+)?$", "i");
    return options.filter((entry) => !remove.test(entry));
  }

  function categoryStats(options, category, entries, scope, controllerAddress) {
    let enabled = 0;
    let modified = 0;
    for (const entry of entries) {
      const key = optionKey(category, entry);
      if (getOptionState(options, key, entry, scope, controllerAddress).enabled) enabled++;
      if (isOptionModified(options, key, scope.id)) modified++;
    }
    return { enabled, modified, total: entries.length, fraction: entries.length ? enabled / entries.length : 0 };
  }

  // MARK: Camera overrides

  const normalizeMac = (mac) => (mac || "").replace(/[^0-9a-fA-F]/g, "").toLowerCase();
  const overrideFields = ["rtspUrl", "snapshotUrl", "onvifPort", "onvifUsername", "onvifPassword", "onvifServicePath"];

  /// Merges the entries of one camera into one; later non-empty values win. True when it changed anything.
  function dedupeCameraOverrides(controller) {
    if (!controller?.cameraOverrides?.length) return false;
    const merged = new Map();
    const original = controller.cameraOverrides;
    for (const entry of original) {
      const key = normalizeMac(entry?.mac || "");
      if (!key) continue;
      const existing = merged.get(key);
      if (!existing) { merged.set(key, { ...entry }); continue; }
      for (const field of overrideFields) {
        const value = entry[field];
        if (value !== undefined && value !== "") existing[field] = value;
      }
    }
    const cleaned = [...merged.values()].filter((entry) => overrideFields.some((field) => entry[field] !== undefined));
    const changed = cleaned.length !== original.length || cleaned.some((entry, index) => JSON.stringify(entry) !== JSON.stringify(original[index]));
    if (!changed) return false;
    if (cleaned.length) controller.cameraOverrides = cleaned;
    else delete controller.cameraOverrides;
    return true;
  }

  /// Sets one field of a camera's override, creating or dropping the entry.
  function updateCameraOverride(controller, mac, field, raw) {
    dedupeCameraOverrides(controller);
    const trimmed = (raw == null ? "" : String(raw)).trim();
    let value = trimmed;
    if (field === "onvifPort") {
      const parsed = trimmed === "" ? NaN : Number(trimmed);
      value = Number.isFinite(parsed) ? parsed : "";
    }
    controller.cameraOverrides ||= [];
    let entry = controller.cameraOverrides.find((candidate) => normalizeMac(candidate.mac) === normalizeMac(mac));
    if (!entry) {
      if (value === "") { if (!controller.cameraOverrides.length) delete controller.cameraOverrides; return; }
      entry = { mac };
      controller.cameraOverrides.push(entry);
    }
    if (value === "") delete entry[field];
    else entry[field] = value;
    if (!overrideFields.some((name) => entry[name] !== undefined)) controller.cameraOverrides = controller.cameraOverrides.filter((candidate) => candidate !== entry);
    if (!controller.cameraOverrides.length) delete controller.cameraOverrides;
  }

  /// Profiles with the same URLs are one stream: the one with the largest resolution stays.
  function dedupeProfilesByUrl(profiles) {
    const byKey = new Map();
    for (const profile of profiles) {
      const key = (profile.rtspUrl || "") + "|" + (profile.snapshotUrl || "");
      const existing = byKey.get(key);
      const pixels = (p) => (p?.resolution?.width ?? 0) * (p?.resolution?.height ?? 0);
      if (!existing || pixels(profile) > pixels(existing)) byKey.set(key, profile);
    }
    return [...byKey.values()];
  }

  function formatProfileLabel(profile, index) {
    const parts = [profile.name || t("Profile {n}", { n: index + 1 })];
    if (profile.resolution?.width && profile.resolution?.height) parts.push(profile.resolution.width + "×" + profile.resolution.height);
    if (profile.encoding) parts.push(profile.encoding);
    return parts.join(" — ");
  }

  // MARK: The Assistant: what may leave the page

  const ipv4 = /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b/g;
  const macPattern = /\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b/g;

  function scrubText(text, addresses = []) {
    let result = String(text ?? "");
    for (const address of addresses) {
      if (typeof address === "string" && address.trim()) result = result.split(address.trim()).join("[address]");
    }
    return result.replace(macPattern, "[MAC address]").replace(ipv4, "[IP address]");
  }

  const assistantDevice = (device) => ({
    adopted: device?.isAdopted, connectionType: device?.connectionType, firmware: device?.firmwareVersion, marketName: device?.marketName,
    modelKey: device?.modelKey, name: device?.name, rebooting: device?.isRebooting, state: device?.state, thirdPartyCamera: device?.isThirdPartyCamera,
    type: device?.type, updating: device?.isUpdating,
  });

  const assistantController = (controller) => ({ name: controller?.name, verifyTls: controller?.verifyTls === true });

  /// "this camera", "this light"… in the page's language.
  function thisDevice(modelKey) {
    switch (modelKey) {
    case "camera": return t("this camera");
    case "chime": return t("this chime");
    case "light": return t("this light");
    case "sensor": return t("this sensor");
    case "viewer": return t("this viewer");
    case undefined: case null: case "": return t("this device");
    default: return t("this {model}", { model: modelKey });
    }
  }

  function deviceProblem(device) {
    if (!device || device.modelKey === "nvr" || typeof device.state !== "string") return null;
    if (device.isUpdating) return t("UniFi Protect reports {device} as updating its firmware.", { device: thisDevice(device.modelKey) });
    if (device.state !== "CONNECTED") return t("UniFi Protect reports {device} as {state} (not connected).", { device: thisDevice(device.modelKey), state: device.state.toLowerCase() });
    return null;
  }

  window.ProtectOptions = {
    validOptionCategory, validOption, optionKey, isOptionModified, getOptionState, setOption, removeOption, categoryStats, normalizeMac,
    dedupeCameraOverrides, updateCameraOverride, dedupeProfilesByUrl, formatProfileLabel, scrubText, assistantDevice, assistantController, deviceProblem,
  };
})();

"""#),
        "protect.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The UniFi Protect page on the UI's materials: the Homebridge plugin's screens (controllers, discovery, the
   controller form, feature options with their scope cascade, third-party camera URLs, support), one at a time. */

.screen { animation: fade var(--normal) var(--ease-out); }
.row-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 14px; }
.row-actions .status-line { flex: 1; margin: 0; }
.note { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.875rem; }
.problem { margin-top: 14px; padding: 10px 14px; border-radius: 14px; border: 1px solid rgba(208, 56, 59, 0.35); background: rgba(208, 56, 59, 0.06); }
.problem p { margin: 0; }
.problem.warn { border-color: rgba(201, 115, 26, 0.35); background: rgba(201, 115, 26, 0.06); }
.help { display: block; font-size: 0.8125rem; color: var(--muted); margin-top: 4px; }
.field.wide { grid-column: 1 / -1; }
.status-line.error { color: var(--error); }
.status-line.ok { color: var(--ok); }
.status-line.warn { color: var(--warn); }

.controllers { display: grid; gap: 12px; }
.controller { margin: 0; display: grid; gap: 10px; animation: materialize var(--normal) var(--ease-out); }
.controller-head { display: flex; align-items: center; gap: 12px; min-width: 0; flex-wrap: wrap; }
.controller-head .who { flex: 1; min-width: 0; }
.controller-head strong { display: block; font-size: 1.0625rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.controller-head .muted { font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.controller .facts { font-size: 0.8125rem; }

.found { display: grid; gap: 8px; margin-top: 14px; }
.found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; cursor: pointer; text-align: left; width: 100%; }
.found .item div { flex: 1; min-width: 0; }

.options-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 2.2fr); gap: 16px; align-items: start; }
.scope-side { display: grid; gap: 12px; position: sticky; top: 80px; }
.compact-card { margin: 0; padding: 14px 16px; }
.compact-card .field { margin: 0; }
.scope-level { display: flex; align-items: center; gap: 10px; opacity: 0.55; transition: opacity var(--normal) var(--ease-out); }
.scope-level > span:last-child { display: grid; }
.scope-hint { font-size: 0.75rem; }
.scope-level.inherited { opacity: 0.8; }
.scope-level.active { opacity: 1; }
.scope-dot { width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-size: 0.75rem; font-weight: 600; background: var(--material-thin); border: 1px solid var(--edge); }
.scope-level[data-scope=global] .scope-dot { color: #c99a06; }
.scope-level[data-scope=controller] .scope-dot { color: #198754; }
.scope-level[data-scope=device] .scope-dot { color: #0aa2c0; }
.scope-level.active .scope-dot { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
.scope-connector { width: 2px; height: 14px; margin: 3px 13px; background: var(--line); }
.scope-connector.active { background: var(--accent); }
.legend { display: grid; gap: 4px; font-size: 0.75rem; }
.bar { display: inline-block; width: 14px; height: 4px; border-radius: 2px; vertical-align: middle; margin-right: 6px; }
.bar.global { background: #ffc107; }
.bar.controller { background: #198754; }
.bar.device { background: #0dcaf0; }

.category { padding: 0; overflow: hidden; margin: 0 0 12px; }
.category-head { width: 100%; display: flex; align-items: center; gap: 10px; padding: 14px 16px; border: 0; background: none; box-shadow: none; border-radius: 0; text-align: left; font-weight: 500; }
/* A section header, not a pressable card: no lift or squeeze, a tint on hover, the focus ring inside the clipped card. */
.category-head:hover, .category-head:active:not(:disabled) { transform: none; }
.category-head:focus-visible { outline-offset: -2px; }
@media (hover: hover) and (pointer: fine) { .category-head:hover { background: var(--material-thin); } }
.category-title { flex: 1; }
.category-icon { width: 26px; height: 26px; border-radius: 8px; display: grid; place-items: center; color: #fff; background: var(--category-color, #6c757d); font-size: 0.75rem; }
.category-count { font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }
.category-progress { width: 60px; height: 4px; border-radius: 2px; background: var(--line); overflow: hidden; }
.category-progress-fill { display: block; height: 100%; width: calc(var(--progress, 0) * 100%); background: var(--category-color, var(--accent)); }
.chevron { transition: transform var(--normal) var(--ease-out); color: var(--muted); }
.category.open .chevron { transform: rotate(180deg); }
.category-body { display: none; padding: 0 16px 14px; }
.category.open .category-body { display: block; }

.option { display: flex; gap: 12px; align-items: flex-start; padding: 10px 0 10px 10px; border-top: 1px solid var(--line); border-left: 3px solid transparent; }
.option.grouped { margin-left: 22px; }
.option.scope-global { border-left-color: #ffc107; }
.option.scope-controller { border-left-color: #198754; }
.option.scope-device { border-left-color: #0dcaf0; }
.option.non-default .option-name { font-weight: 600; }
.option-text { flex: 1; min-width: 0; }
.option-name { font-weight: 500; overflow-wrap: anywhere; }
.option-description { font-size: 0.8125rem; color: var(--muted); margin-top: 2px; }
.option-value { display: flex; align-items: center; gap: 8px; margin-top: 6px; font-size: 0.8125rem; }
.option-value input { width: 120px; }
.default-indicator { font-size: 0.6875rem; color: var(--muted); margin-left: 6px; }
.scope-badge { font-size: 0.6875rem; padding: 1px 8px; border-radius: 999px; margin-left: 6px; border: 1px solid var(--line); }
.scope-badge.device { color: #0aa2c0; border-color: rgba(13, 202, 240, 0.4); }
.scope-badge.controller { color: #198754; border-color: rgba(25, 135, 84, 0.4); }
.scope-badge.global { color: #c99a06; border-color: rgba(255, 193, 7, 0.45); }
.scope-badge.inherited { opacity: 0.7; }
.reset-option { flex: none; width: 30px; height: 30px; padding: 0; display: grid; place-items: center; }
.modified-badge { font-size: 0.6875rem; padding: 1px 8px; border-radius: 999px; background: rgba(201, 115, 26, 0.15); color: var(--warn); }

.profile-picker { display: grid; grid-template-columns: minmax(0, 1fr) 96px; gap: 4px 12px; align-items: end; margin: 10px 0; }
.profile-picker .help { grid-column: 1 / -1; }
.thumb { width: 96px; height: 54px; border-radius: 10px; overflow: hidden; display: grid; place-items: center; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.6875rem; }
.thumb img { width: 100%; height: 100%; object-fit: cover; }

.support h3 { margin: 18px 0 8px; }
.support h3:first-child { margin-top: 0; }
.links { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.links li { display: grid; padding: 8px 12px; border-radius: 12px; background: var(--material-thin); }
.links a { color: var(--accent); text-decoration: none; }

.busy::after {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .screen, .controller { animation: none; }
  .chevron { transition: none; }
  .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}
@media (max-width: 760px) {
  .options-layout { grid-template-columns: 1fr; }
  .scope-side { position: static; }
}

/* The scope's camera, live, over its facts. */
.info-preview { margin: -4px -6px 12px; }
.info-preview .camera-view { margin: 0; border-radius: 12px; }

"""#),
    ]
}
