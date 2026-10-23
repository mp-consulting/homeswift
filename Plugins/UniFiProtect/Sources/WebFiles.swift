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
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, "▤"),
        el("div", { class: "who" }, el("strong", { text: controller.name || controller.address }), el("div", { class: "muted", text: controller.address })),
        badge,
        el("button", { class: "primary", text: "Options", onclick: () => openFeatureOptions(index) }),
        el("button", { text: "Edit", onclick: () => openEditController(index) }),
        el("button", { class: "danger", text: "Remove", onclick: (event) => act(event.currentTarget, async () => {
          if (!confirm(`Remove ${controller.name || controller.address}?`)) return;
          state.block.controllers.splice(index, 1);
          await saveBlock();
          await renderControllers();
          if (!controllers().length) showDiscovery(false);
        }) })),
      facts, slot);
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
    } else {
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
<header><a class="brand" href="/#status"><img src="/icon.svg" class="logo" alt="">Homeswift</a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10.5l5-3v9l-5-3z"/></svg></span>
    <div>
      <h1>UniFi Protect</h1>
      <p class="muted">Manage your UniFi Protect cameras and devices in HomeKit.</p>
    </div>
  </div>

  <!-- The controllers: the page opens here once one is configured. -->
  <section id="controllersScreen" class="screen hidden">
    <div class="section-head"><h2>Configured controllers</h2></div>
    <p id="noControllers" class="card muted hidden">No controllers configured yet. Add one to get started.</p>
    <div id="controllersList" class="controllers"></div>
    <div class="actions row-actions">
      <button id="addControllerBtn" class="primary">Add controller</button>
      <button id="supportBtn">Support</button>
    </div>
  </section>

  <!-- Discovery of UniFi consoles, or manual entry. -->
  <section id="discoveryScreen" class="screen hidden">
    <div class="section-head"><h2>Discover your controller</h2></div>
    <div class="card">
      <p class="muted">Scan your network for UniFi Protect controllers, or enter the address manually.</p>
      <p class="note">Make sure your UniFi console is powered on and connected to the same network.</p>
      <div class="actions row-actions">
        <button id="discoverBtn" class="primary">Discover controllers</button>
        <button id="manualEntryBtn">Manual entry</button>
        <button id="cancelDiscoveryBtn" class="link hidden">Cancel</button>
      </div>
      <div id="deviceList" class="found"></div>
    </div>
  </section>

  <!-- Add or edit a controller. -->
  <section id="setupScreen" class="screen hidden">
    <div class="section-head"><h2 id="setupTitle">Add UniFi Protect controller</h2></div>
    <form id="setupForm" class="card" novalidate>
      <p id="setupSubtitle" class="muted">Enter your UniFi Protect controller details and login credentials.</p>
      <div class="fields">
        <label class="field"><span class="field-title">Controller</span>
          <input id="inputAddress" type="text" placeholder="Hostname or IP (e.g. unvr.local)" autocomplete="off" spellcheck="false" required>
          <span class="help">The address of your UniFi Protect controller.</span></label>
        <label class="field"><span class="field-title">Username</span>
          <input id="inputUsername" type="text" autocomplete="username" placeholder="Local user account username" required></label>
        <label class="field"><span class="field-title">Password</span>
          <input id="inputPassword" type="password" autocomplete="current-password" placeholder="Local user account password" required></label>
      </div>
      <label class="toggle">
        <span class="switch"><input id="inputVerifyTls" type="checkbox"><span></span></span>
        <span><span class="field-title">Verify TLS</span>
          <span class="help">Validate the controller's TLS certificate. Leave this off unless your controller uses a certificate signed by a trusted certificate
          authority: UniFi controllers use self-signed certificates, which are pinned the first time instead.</span></span>
      </label>
      <div id="setupError" class="problem hidden"><p id="setupErrorText" class="error"></p><div id="setupAssistant"></div></div>
      <p class="note"><strong>Local account required.</strong> Ubiquiti.com/UI.com accounts are not supported. Create one in the <em>Admins &amp; Users</em> tab of your UniFi console.</p>
      <div class="save-bar">
        <span class="muted"></span>
        <button id="cancelSetupBtn" type="button">Cancel</button>
        <button id="saveControllerBtn" class="primary" type="submit">Save controller</button>
      </div>
    </form>
  </section>

  <!-- Feature options: scope on the side, options by category. -->
  <section id="featureOptionsScreen" class="screen hidden">
    <div class="section-head"><h2>Feature options</h2><button id="backFromOptionsBtn" class="link">Back</button></div>
    <div class="options-layout">
      <aside class="scope-side">
        <div class="card compact-card">
          <label class="field"><span class="field-title">Scope</span><select id="scopeSelect"></select></label>
        </div>
        <div class="card compact-card" id="scopeCascade">
          <div class="scope-level" data-scope="global"><span class="scope-dot">G</span><span><b>Global</b><span class="scope-hint muted">All devices</span></span></div>
          <div class="scope-connector" aria-hidden="true"></div>
          <div class="scope-level" data-scope="controller"><span class="scope-dot">C</span><span><b>Controller</b><span class="scope-hint muted">Overrides global</span></span></div>
          <div class="scope-connector" aria-hidden="true"></div>
          <div class="scope-level" data-scope="device"><span class="scope-dot">D</span><span><b>Device</b><span class="scope-hint muted">Final value</span></span></div>
        </div>
        <div id="deviceInfoPanel" class="card compact-card hidden">
          <div class="facts">
            <div class="fact"><span>Model</span><b id="infoModel"></b></div>
            <div class="fact"><span>MAC</span><b id="infoMac" class="mono"></b></div>
            <div class="fact"><span>IP</span><b id="infoIp" class="mono"></b></div>
            <div class="fact"><span>Status</span><b id="infoStatus"></b></div>
          </div>
        </div>
        <div class="card compact-card legend">
          <span class="muted">Legend</span>
          <span><i class="bar global"></i> Set at global</span>
          <span><i class="bar controller"></i> Set at controller</span>
          <span><i class="bar device"></i> Set at device</span>
        </div>
      </aside>
      <div class="options-main">
        <div class="toolbar">
          <input id="optionsSearch" class="search" type="search" placeholder="Search options…">
          <label class="toggle compact"><span class="switch"><input id="modifiedOnlyToggle" type="checkbox"><span></span></span><span>Modified <span id="modifiedSummary"></span></span></label>
        </div>
        <p id="optionsLoading" class="muted">Loading options…</p>
        <div id="infoAssistant" class="hidden"></div>
        <div id="thirdPartyOverridesPanel" class="card category hidden">
          <button id="thirdPartyOverridesHeader" class="category-head" type="button"><span class="category-icon" style="--category-color: #0d6efd">◉</span><span class="category-title">Third-party camera URLs</span><span class="chevron">⌄</span></button>
          <div id="thirdPartyOverridesBody" class="category-body">
            <p class="muted">The Protect controller often does not relay this camera's stream. Enter the camera's IP and credentials to discover its URLs automatically, or paste the URLs below.</p>
            <div class="fields">
              <label class="field"><span class="field-title">IP address</span><input id="thirdPartyOnvifHost" type="text" placeholder="e.g. 192.168.1.50" autocomplete="off" spellcheck="false"></label>
              <label class="field"><span class="field-title">ONVIF port <span class="muted">(optional)</span></span><input id="thirdPartyOnvifPort" type="number" placeholder="auto" min="1" max="65535"></label>
              <label class="field"><span class="field-title">Username</span><input id="thirdPartyOnvifUser" type="text" autocomplete="off" spellcheck="false"></label>
              <label class="field"><span class="field-title">Password</span><input id="thirdPartyOnvifPass" type="password" autocomplete="off"></label>
              <label class="field wide"><span class="field-title">Service path <span class="muted">(optional, /onvif/device_service by default)</span></span><input id="thirdPartyOnvifPath" type="text" placeholder="/onvif/device_service" autocomplete="off" spellcheck="false"></label>
            </div>
            <div class="row-actions"><span id="thirdPartyDiscoverStatus" class="status-line"></span><button id="thirdPartyDiscoverBtn" class="primary" type="button">Discover URLs</button></div>
            <div id="thirdPartyDiscoverAssistant"></div>
            <div id="thirdPartyProfileSelectorWrap" class="hidden profile-picker">
              <label class="field"><span class="field-title">Stream profile</span><select id="thirdPartyProfileSelect"></select></label>
              <div class="thumb"><img id="thirdPartyProfileThumb" alt="Stream preview" class="hidden"><span id="thirdPartyProfileThumbPlaceholder" class="muted">No preview</span></div>
              <p class="help">Pick the camera stream HomeKit should use. Higher resolutions look better but cost more bandwidth and CPU.</p>
            </div>
            <label class="field"><span class="field-title">Direct RTSP / RTSPS URL</span><input id="thirdPartyRtspUrl" type="text" placeholder="rtsp://user:pass@host:port/path" autocomplete="off" spellcheck="false"></label>
            <label class="field"><span class="field-title">Direct snapshot URL</span><input id="thirdPartySnapshotUrl" type="text" placeholder="http://host:port/snapshot" autocomplete="off" spellcheck="false"></label>
            <p class="help">Leave both URL fields blank to remove the override.</p>
          </div>
        </div>
        <div id="optionsProblem" class="hidden"></div>
        <div id="optionsContainer"></div>
        <div id="unsavedChanges" class="card save-bar hidden">
          <span class="dirty">You have unsaved changes. Saving applies them: the plugin restarts with them.</span>
          <button id="discardOptionsBtn">Discard</button>
          <button id="saveOptionsBtn" class="primary">Save</button>
        </div>
      </div>
    </div>
  </section>

  <!-- Support. -->
  <section id="supportScreen" class="screen hidden">
    <div class="section-head"><h2>Support</h2><button id="backFromSupportBtn" class="link">Back</button></div>
    <div class="card support">
      <h3>About this plugin</h3>
      <p>The Homeswift port of <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect">homebridge-unifi-protect</a>. Its documentation applies here: the options, feature options and MQTT topics are the same.</p>
      <h3>Getting started</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/getting-started.md"><b>Getting started</b></a><span class="muted">Install, configure and connect to HomeKit.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/feature-options.md"><b>Feature options</b></a><span class="muted">Options for a controller or a device.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/mqtt.md"><b>MQTT</b></a><span class="muted">How to configure MQTT support.</span></li>
      </ul>
      <h3>How-to guides</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/doorbell.md"><b>Doorbells</b></a><span class="muted">Two-way audio, ring events and LCD messages.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/homekit-secure-video.md"><b>HomeKit Secure Video</b></a><span class="muted">HKSV with Protect cameras.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/liveviews.md"><b>Liveview scenes</b></a><span class="muted">Motion detection scenes and the security system.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/troubleshooting.md"><b>Troubleshooting</b></a><span class="muted">Login, network and video problems.</span></li>
      </ul>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
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
    const parts = [profile.name || "Profile " + (index + 1)];
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

  function deviceProblem(device) {
    if (!device || device.modelKey === "nvr" || typeof device.state !== "string") return null;
    if (device.isUpdating) return "UniFi Protect reports this " + (device.modelKey || "device") + " as updating its firmware.";
    if (device.state !== "CONNECTED") return "UniFi Protect reports this " + (device.modelKey || "device") + " as " + device.state.toLowerCase() + " (not connected).";
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
  .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}
@media (max-width: 760px) {
  .options-layout { grid-template-columns: 1fr; }
  .scope-side { position: static; }
}

"""#),
    ]
}
