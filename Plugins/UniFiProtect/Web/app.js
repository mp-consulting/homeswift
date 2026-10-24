// The UniFi Protect page: the Homebridge plugin's settings page (homebridge-ui/public) on Homeswift. The
// controllers of this instance's block with their state; discovery of UniFi consoles; adding and editing a
// controller, checked by logging in; the feature options editor with its scopes (global, controller,
// device) and the third-party camera URLs found over ONVIF; and the support links. The page edits this
// instance's block of config.json the way the settings form does; saving applies it.
(() => {
  "use strict";
  const { $, el, request, explain, readBlock, updateBlock } = homeswift;
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
    const badge = el("span", { class: "pill status standby", text: "Checking" });
    const slot = el("div", {});
    const live = runtime[controller.address];
    const facts = live ? el("div", { class: "facts" },
      el("div", { class: "fact" }, el("span", { text: "Devices" }), el("b", { text: String(live.devices.length) })),
      el("div", { class: "fact" }, el("span", { text: "Events" }), el("b", { text: live.events ? "Live" : live.connected ? "Every 2 minutes" : "—" })),
      el("div", { class: "fact" }, el("span", { text: "Certificate" }), el("b", { text: controller.verifyTls ? "Verified" : live.tlsFingerprint ? "Pinned" : "Not yet seen" }))) : null;
    const remove = async () => {
      if (!confirm(`Remove ${controller.name || controller.address}?`)) return;
      state.block.controllers.splice(index, 1);
      try { await saveBlock(); } catch (e) { alert(`Unable to remove the controller: ${e.message}`); }
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
        el("span", { class: "muted", text: live ? (live.connected ? "Connected" : "Not connected yet: see the log.") : "Not running" }),
        HomeswiftCommon.menuButton(`Actions for ${controller.name || controller.address}`, () => [
          { label: "Feature options", icon: "sliders", onSelect: () => openFeatureOptions(index) },
          { label: "Edit", icon: "edit", onSelect: () => openEditController(index) },
          { label: "Remove", icon: "trash", danger: true, onSelect: remove },
        ])));
    request("check-status", { method: "POST", body: { address: controller.address } }).then(({ online }) => {
      badge.className = `pill status ${online ? "on" : "away"}`;
      badge.textContent = online ? "Online" : "Offline";
      if (!online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server; loopback and link-local addresses are refused), so it is shown as Offline.",
          context: "The user is looking at the list of configured UniFi Protect controllers in the plugin's page.",
          device: P.assistantController(controller),
        }));
      }
    }).catch(() => { badge.textContent = "Unknown"; });
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
    list.replaceChildren(el("p", { class: "muted", text: "Searching…" }));
    try {
      const { devices } = await act(button, () => request("discover"));
      const configured = controllers().map((c) => c.address);
      const available = devices.filter((d) => !configured.includes(d.ip));
      if (!available.length) {
        const message = devices.length ? "All discovered devices are already configured." : "No devices found. Make sure your UniFi console is on and connected.";
        list.replaceChildren(el("p", { class: devices.length ? "ok" : "warn", text: message }),
          devices.length ? null : explain({ error: message, context: discoveryContext }));
        return;
      }
      list.replaceChildren(el("p", { class: "muted", text: "Found devices:" }), ...available.map((device) => el("button", {
        class: "card item", type: "button", onclick: () => openAddController(device.ip),
      }, el("div", {}, el("strong", { text: device.name }), el("div", { class: "muted", text: [device.ip, device.model, device.mac].filter(Boolean).join(" · ") })),
      el("span", { class: "pill", text: "Select" }))));
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: "Discovery error: " + e.message }),
        explain({ error: P.scrubText("Discovery error: " + e.message), context: discoveryContext }));
    }
  }

  // MARK: Add or edit a controller

  function openAddController(address) {
    state.editingIndex = null;
    $("#setupTitle").textContent = "Add UniFi Protect controller";
    $("#setupSubtitle").textContent = "Enter your UniFi Protect controller details and login credentials.";
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
    $("#setupTitle").textContent = "Edit controller";
    $("#setupSubtitle").textContent = "Editing " + (controller.name || controller.address);
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
      $("#setupErrorText").textContent = "Please fill in all fields.";
      $("#setupError").classList.remove("hidden");
      return;
    }
    $("#setupError").classList.add("hidden");
    const button = $("#saveControllerBtn");
    button.textContent = "Validating…";
    try {
      await act(button, async () => {
        const { devices, error } = await request("devices", { method: "POST", body: { address, username, password, verifyTls } });
        if (!devices?.length) {
          setupError("Unable to connect. " + (error || "Check your address and credentials."), verifyTls, address);
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
      setupError("Error: " + e.message, verifyTls, address);
    } finally {
      button.textContent = "Save controller";
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
      if (!state.devices.length) showOptionsProblem(controller, "Unable to load the devices of this controller. " + (answer.error || "Check its address and credentials."));
      buildScopeSelector(controller);
      renderOptions();
    } catch (e) {
      showOptionsProblem(controller, "Failed to load: " + e.message);
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
    box.replaceChildren(el("p", { text: (device.name || "This device") + ": " + problem }), explain({
      error: problem, context: "The user is looking at the feature options of a UniFi Protect device in the plugin's page.", device: P.assistantDevice(device),
    }));
  }

  const modelLabels = { cameras: "Cameras", chimes: "Chimes", lights: "Lights", sensors: "Sensors", viewers: "Viewers" };

  function buildScopeSelector(controller) {
    const select = $("#scopeSelect");
    select.replaceChildren(el("option", { value: "global", text: "Global options" }),
      el("option", { value: "controller:" + controller.address, text: "Controller: " + (controller.name || controller.address) }));
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
    preview = HomeswiftCamera.view({ id, name: device.name || device.marketName || "Camera", doorbell: device.featureFlags?.isDoorbell === true });
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
      global: ["Editing this scope", "Inherits global", "Inherits global"],
      controller: ["Base values", "Editing this scope", "Inherits controller"],
      device: ["Base values", "Intermediate", "Editing this scope"],
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
      return !search || (option.name + " " + option.description).toLowerCase().includes(search);
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
      $("#infoIp").textContent = scope.device.host || (scope.device.modelKey === "sensor" ? (scope.device.connectionType === "lora" ? "SuperLink" : "Bluetooth") + " Device" : "N/A");
      const status = $("#infoStatus");
      if (typeof scope.device.state === "string") {
        status.textContent = scope.device.state.charAt(0).toUpperCase() + scope.device.state.slice(1).toLowerCase();
        status.className = scope.device.state === "CONNECTED" ? "ok" : "error";
      } else {
        status.textContent = "Connected";
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
    if (!cards.length) cards.push(el("p", { class: "muted", text: view.modifiedOnly ? "No modified options" : view.search ? "No options match your search" : "No options available" }));
    container.replaceChildren(...cards);
    updateModifiedSummary(modified);
  }

  function updateModifiedSummary(count) {
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
      el("span", { class: "category-title", text: category.description.replace(/ feature options\.?/i, "") }),
      count, el("span", { class: "category-progress" }, fill), badge, el("span", { class: "chevron", text: "⌄" }));
    const card = el("div", { class: `card category${isOpen ? " open" : ""}`, "data-category": category.name });
    card.style.setProperty("--category-color", color);
    const fillHeader = (s) => {
      count.textContent = `${s.enabled}/${s.total} on`;
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

  function optionRow(category, option, scope, changed) {
    const key = P.optionKey(category, option);
    const checkbox = el("input", { type: "checkbox", "aria-label": key });
    const badge = el("span", {});
    const valueInput = option.defaultValue !== undefined ? el("input", { type: option.inputSize ? "text" : "number", min: "0", step: "1", "aria-label": key + " value" }) : null;
    const unit = option.description.match(/\bin (seconds?|minutes?|hours?|milliseconds?|decibels?|Hertz|kilobits per second|percentage)\b/i)?.[1];
    const valueRow = valueInput ? el("div", { class: "option-value" }, valueInput, unit ? el("span", { class: "muted", text: unit }) : null,
      el("span", { class: "muted", text: `(default: ${option.defaultValue === "" ? "none" : option.defaultValue})` })) : null;
    const reset = el("button", { class: "reset-option", type: "button", title: "Reset to inherited value", "aria-label": "Reset to inherited value", text: "↺" });
    const row = el("div", { class: "option" },
      el("label", { class: "switch" }, checkbox, el("span", {})),
      el("div", { class: "option-text" },
        el("div", {}, el("span", { class: "option-name", text: option.name || category.description }),
          el("span", { class: "default-indicator", text: `default: ${option.default ? "on" : "off"}` }), badge),
        el("div", { class: "option-description", text: option.description }), valueRow),
      reset);
    const sync = () => {
      const s = P.getOptionState(configuredOptions(), key, option, scope, currentController()?.address);
      let scopeClass = "";
      if (s.explicit) scopeClass = "scope-" + scope.type;
      else if (s.scope === "controller") scopeClass = "scope-controller";
      else if (s.scope === "global" && scope.type !== "global") scopeClass = "scope-global";
      else if (s.enabled !== option.default) scopeClass = "non-default";
      row.className = `option ${scopeClass}${option.group && option.name !== option.group ? " grouped" : ""}`;
      if (s.explicit) { badge.className = `scope-badge ${scope.type}`; badge.textContent = scope.type; }
      else if (s.scope === "controller" || (s.scope === "global" && scope.type !== "global")) { badge.className = `scope-badge inherited ${s.scope}`; badge.textContent = "↓ " + s.scope; }
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
    if (!host || !username) { say("IP address and username are required.", "error"); return; }
    // What was entered or prefilled is remembered before talking to the camera.
    P.updateCameraOverride(controller, mac, "onvifPort", port);
    P.updateCameraOverride(controller, mac, "onvifUsername", username);
    P.updateCameraOverride(controller, mac, "onvifPassword", password);
    P.updateCameraOverride(controller, mac, "onvifServicePath", servicePath);
    markDirty();
    say("Discovering…");
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
        say("Discovery failed: " + (result?.error || "unknown error"), "error");
        explainFailure("Discovery failed: " + (result?.error || "unknown error"));
        return;
      }
      const raw = (result.profiles || []).filter((p) => p.rtspUrl || p.snapshotUrl);
      if (!raw.length) { say("Camera did not return any URLs.", "warn"); return; }
      discoveries.set(P.normalizeMac(mac), { collapsedFrom: raw.length, host, port: result.port, profiles: P.dedupeProfilesByUrl(raw), thumbnails: new Map(), warnings: result.warnings || [], queue: Promise.resolve() });
      renderProfileSelector(mac);
    } catch (e) {
      say("Discovery failed: " + e.message, "error");
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
    let text = entry.profiles.length > 1 ? `Found ${entry.profiles.length} profiles on port ${entry.port}. Pick the one to use.`
      : entry.collapsedFrom > 1 ? `Camera reports ${entry.collapsedFrom} profiles but they all map to the same stream. Discovered URLs on port ${entry.port}.`
        : `Discovered URLs on port ${entry.port}.`;
    if (entry.warnings.length) { text += " " + entry.warnings.join(" "); say(text, "warn"); } else { say(text, "ok"); }
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
        if (pending.length) alert(`Saved. Restart Homeswift to apply: ${pending.join("; ")}.`);
      } catch (e) { alert(e.message); }
    });
  }

  async function discardOptions() {
    if (!confirm("Discard the changes?")) return;
    state.block = JSON.parse(state.savedOptions);
    markDirty();
    renderOptions();
  }

  function leaveOptions() {
    if (isOptionsDirty() && !confirm("Leave without saving the changes?")) return;
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
