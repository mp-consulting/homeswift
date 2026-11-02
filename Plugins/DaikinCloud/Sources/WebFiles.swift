// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DaikinCloudPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Daikin Cloud page, after the Homebridge plugin's settings UI: the devices the account has; the plugin's
// settings (feature switches, polling, network, hidden devices), saved to this instance's block; the sign-in's
// state, its connection test and signing out (signing in is Setup's, on Add accessories, which the page leads to);
// and help, with the quota the plugin saw on its last call.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, act, poll } = homeswift;
  const { t, tn } = HomeswiftI18n;
  /// Text from the plugin (a message in an answer), in the page's language when the catalog knows it.
  const said = (text) => HomeswiftI18n.message(text);

  const OPERATION_MODE_LABELS = { auto: t("Auto"), cooling: t("Cooling"), heating: t("Heating"), dry: t("Dry"), fanOnly: t("Fan only") };
  const numberFormat = new Intl.NumberFormat(HomeswiftI18n.locale);
  const formatNumber = (value) => (value !== null && value !== undefined && value !== "" && Number.isFinite(Number(value)) ? numberFormat.format(Number(value)) : String(value ?? ""));
  const operationModeLabel = (mode) => (mode ? OPERATION_MODE_LABELS[mode] || String(mode).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : "");
  const isValidNumber = (value, min, max) => { const n = parseInt(value, 10); return !isNaN(n) && n >= min && n <= max; };
  const isValidIPv4 = (ip) => !ip || /^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.){3}(25[0-5]|(2[0-4]|1\d|[1-9]|)\d)$/.test(ip);
  function formatTime(ms) {
    const days = Math.floor(ms / 86400000), hours = Math.floor((ms % 86400000) / 3600000);
    const minutes = Math.floor((ms % 3600000) / 60000), seconds = Math.floor((ms % 60000) / 1000);
    if (days > 0) return t("{days}d {hours}h {minutes}m", { days, hours, minutes });
    if (hours > 0) return t("{hours}h {minutes}m {seconds}s", { hours, minutes, seconds });
    if (minutes > 0) return t("{minutes}m {seconds}s", { minutes, seconds });
    return t("{seconds}s", { seconds });
  }

  // MARK: The Assistant: "Explain" next to an error. Nothing sent to it carries credentials or tokens; the server
  // masks e-mail and IP addresses.

  const assistantDevice = (d) => ({ name: d.name, id: d.id, model: d.model, type: d.type, online: !!d.online, features: Array.isArray(d.features) ? d.features : [] });
  function assistantContext(extra) {
    return [
      extra,
      `Authentication method: ${authMode.current}.`,
      block?.updateIntervalInMinutes ? `Update interval: ${block.updateIntervalInMinutes} minutes.` : "",
      authMode.current === "mobile_app" ? `WebSocket: ${block?.enableWebSocket !== false ? "on" : "off"}.` : "",
      `HTTP transport: ${block?.httpTransport === "curl" ? "curl subprocess" : "Homeswift's built-in HTTP client (NIO, BoringSSL)"}.`,
    ].filter(Boolean).join(" ");
  }
  /// Puts an Explain button in `slot` for `message`, or empties it.
  function offerExplain(slot, message, context, device) {
    slot.replaceChildren(message ? explain({ error: message, context: assistantContext(context), device }) : "");
  }

  // MARK: config.json: this instance's block, read and written through the signed-in UI, as Homebridge's
  // getPluginConfig/updatePluginConfig/savePluginConfig. A save reloads the plugin with the block.

  let block = null;   // this instance's block as last read or saved

  async function readBlock() {
    block = await homeswift.readBlock();
  }

  /// Merges `changes` into the block (undefined removes a key) and saves it.
  async function saveBlock(changes) {
    let next = null;
    const result = await homeswift.updateBlock((current) => {
      next = current;
      for (const [key, value] of Object.entries(changes)) { if (value === undefined) delete next[key]; else next[key] = value; }
    });
    block = next;
    return result;
  }

  // MARK: Tabs

  const tabs = $("#tabs");
  function switchTab(tab) {
    for (const button of tabs.querySelectorAll("button")) {
      const on = button.dataset.tab === tab;
      button.classList.toggle("on", on);
      button.setAttribute("aria-selected", String(on));
    }
    for (const pane of document.querySelectorAll(".tab-pane")) pane.classList.toggle("hidden", pane.id !== `tab-${tab}`);
    breadcrumb(tab === "devices" ? null : tabs.querySelector(`[data-tab="${tab}"]`).textContent, () => switchTab("devices"));
    if (tab === "settings") settings.load();
  }
  tabs.addEventListener("click", (event) => { const tab = event.target.closest("button")?.dataset.tab; if (tab) switchTab(tab); });

  // MARK: Status: the header badge, the token countdown, the Authentication tab's facts; signed out, a card to Setup.

  /// The card that leads to the account's Setup on Add accessories.
  const signInCard = () => homeswift.setupCard({
    title: t("Sign in to your Daikin account"),
    text: t("Homeswift signs in on Add accessories, with the Onecta app's account or an app of the Daikin Developer Portal. Your units appear here once it is done."),
    glyph: "key",
  });
  $("#btn-sign-in-again").href = homeswift.setupAddress({ start: true });

  const auth = {
    expiresAt: null,
    countdown: null,
    status: null,

    async load() {
      let status;
      try { status = await request("auth/status"); } catch (e) { status = { authenticated: false, error: e.message }; }
      this.status = status;
      this.render(status);
      devices.renderSession(status.session);
    },

    render(status) {
      const badge = $("#status-badge");
      $("#auth-status-card").classList.toggle("hidden", !status.authenticated);
      if (status.authenticated) {
        $("#auth-setup").replaceChildren();
        if (status.authMode && !block?.authMode) authMode.current = status.authMode;
        authMode.render();
        badge.className = `pill status ${status.isExpired ? "away" : ""}`;
        badge.textContent = status.isExpired ? t("Expired") : t("Connected");
        $("#auth-status").textContent = status.isExpired ? (status.canRefresh ? t("Token expired (will auto-refresh)") : t("Token expired")) : t("Authenticated and ready");
        this.expiresAt = status.expiresAt ? new Date(status.expiresAt) : null;
        $("#expires-row").classList.toggle("hidden", !this.expiresAt);
        this.startCountdown();
      } else {
        if (!$("#auth-setup").firstChild) $("#auth-setup").replaceChildren(signInCard());
        badge.className = "pill status away";
        badge.textContent = t("Not connected");
        this.expiresAt = null;
        $("#token-expires").classList.add("hidden");
        this.stopCountdown();
      }
    },

    startCountdown() {
      this.stopCountdown();
      this.tick();
      this.countdown = setInterval(() => this.tick(), 1000);
    },
    stopCountdown() { clearInterval(this.countdown); this.countdown = null; },
    tick() {
      if (!this.expiresAt) return;
      const left = this.expiresAt - Date.now();
      const header = $("#token-expires");
      header.classList.remove("hidden");
      if (left <= 0) {
        header.textContent = t("Token expired");
        $("#auth-token-expires").textContent = t("Expired");
        this.stopCountdown();
        this.load();
        return;
      }
      const text = formatTime(left);
      header.textContent = t("Expires in {time}", { time: text });
      $("#auth-token-expires").textContent = text;
      const colour = left < 300000 ? "var(--error)" : left < 1800000 ? "var(--warn)" : "";
      header.style.color = colour;
      $("#auth-token-expires").style.color = colour;
    },

    async test(button) {
      const result = $("#test-result");
      result.className = "status-line";
      result.textContent = "";
      offerExplain($("#test-problem"), null);
      await act(button, async () => {
        const answer = await request("auth/test", { method: "POST", body: {} });
        result.className = `status-line ${answer.success ? "ok" : "error"}`;
        result.textContent = said(answer.message);
        if (!answer.success) offerExplain($("#test-problem"), answer.message, "Test Connection on the plugin's page (reads the saved token and lists the gateway devices from the Daikin Onecta API) failed.");
      }, (message) => {
        result.className = "status-line error";
        result.textContent = t("Test failed: {error}", { error: message });
        offerExplain($("#test-problem"), result.textContent, "Test Connection on the plugin's page failed.");
      });
    },

    async revoke(button) {
      if (!await HomeswiftCommon.confirmDialog(t("Revoke access? The plugin stops until you sign in again on Add accessories."))) return;
      await act(button, async () => {
        await request("auth/revoke", { method: "POST", body: { clientId: block?.clientId, clientSecret: block?.clientSecret } });
        await this.load();
        devices.load();
      });
    },
  };
  $("#btn-test").addEventListener("click", (event) => auth.test(event.currentTarget));
  $("#btn-revoke").addEventListener("click", (event) => auth.revoke(event.currentTarget));

  // MARK: How the account signs in: the block's `authMode`, else the token's; Setup chooses it.

  const authMode = {
    current: "developer_portal",

    render() {
      const mobile = this.current === "mobile_app";
      $("#auth-mode-text").textContent = mobile ? t("Mobile App") : "Developer Portal";
      const daily = mobile ? 3000 : 200;
      $("#rate-limit-display").textContent = t("{n} requests/day", { n: daily });
      $("#rate-limit-info").textContent = t("The Daikin API limits you to {n} requests per day.", { n: daily });
      $("#websocket-setting-row").classList.toggle("hidden", !mobile);
      $("#updateIntervalInMinutes").placeholder = t("{n} (recommended)", { n: mobile ? 5 : 15 });
      $("#forceUpdateDelay").placeholder = t("{n} (recommended)", { n: mobile ? 10 : 60 });
    },
  };

  // MARK: Devices: one request shared by the Devices tab and the Settings tab's device list; Refresh skips the
  // plugin's five-minute cache.

  const deviceList = {
    inFlight: null,
    mode: null,
    fetch({ refresh = false } = {}) {
      const mode = authMode.current;
      if (!refresh && this.inFlight && this.mode === mode) return this.inFlight;
      const pending = request(`devices/list?mode=${encodeURIComponent(mode)}${refresh ? "&refresh=1" : ""}`).finally(() => {
        if (this.inFlight === pending) this.inFlight = null;
      });
      this.inFlight = pending;
      this.mode = mode;
      return pending;
    },
  };

  const devices = {
    items: [],

    renderSession(session) {
      const line = $("#session-line");
      if (!session) { line.classList.add("hidden"); return; }
      line.classList.remove("hidden");
      if (!session.running) {
        line.textContent = t("The plugin is not connected to Daikin yet.");
        return;
      }
      const parts = [tn("{n} unit in HomeKit", "{n} units in HomeKit", session.devices ?? 0)];
      if (session.mode === "mobile_app") parts.push(session.webSocket ? t("real-time updates over the WebSocket") : t("no WebSocket"));
      if (session.pollMinutes) parts.push(tn("polling every {n} minute", "polling every {n} minutes", session.pollMinutes));
      line.textContent = parts.join(" · ");
    },

    async load({ refresh = false } = {}) {
      const list = $("#devices-list");
      offerExplain($("#devices-problem"), null);
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Loading devices…") })));
      let result;
      try {
        result = await deviceList.fetch({ refresh });
      } catch (e) {
        list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "error", text: t("Failed to load: {error}", { error: e.message }) })));
        offerExplain($("#devices-problem"), `Failed to load: ${e.message}`, "Loading the device list (GET /v1/gateway-devices on the Daikin Onecta API) on the plugin's page failed.");
        return;
      }
      const fetchedAt = result.fetchedAt ? new Date(result.fetchedAt).toLocaleTimeString(HomeswiftI18n.locale) : "";
      $("#devices-fetched").textContent = fetchedAt ? (result.cached ? t("As of {time}", { time: fetchedAt }) : t("Fetched {time}", { time: fetchedAt })) : "";
      if (!result.success) {
        if (result.message?.includes("Not authenticated")) {
          list.replaceChildren(signInCard());
        } else {
          list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "error", text: said(result.message) })));
          offerExplain($("#devices-problem"), result.message, "Loading the device list (GET /v1/gateway-devices on the Daikin Onecta API) on the plugin's page failed.");
        }
        return;
      }
      this.items = result.devices;
      settings.devices = result.devices;
      settings.renderDevices();
      if (!result.devices.length) {
        list.replaceChildren(el("div", { class: "card empty" },
          el("p", { text: t("No devices found") }),
          el("p", { class: "muted", text: t("Make sure your Daikin devices are set up in the Onecta app.") })));
        return;
      }
      list.replaceChildren(...result.devices.map((device) => this.card(device)));
    },

    /// Why a unit needs attention, or null.
    problem(device) {
      if (!device.online) return "The Daikin Onecta cloud reports this unit as offline: its Wi-Fi adapter has no cloud connection (isCloudConnectionUp is false), so HomeKit cannot control it.";
      return null;
    },

    card(device) {
      const on = device.powerState === "on";
      const hidden = (block?.excludedDevicesByDeviceId || []).includes(device.id);
      const fact = (label, value) => homeswift.fact(label, value || "—", { title: value || "" });
      const problem = this.problem(device);
      return el("div", { class: `card unit ${hidden ? "is-hidden" : ""}` },
        el("div", { class: "server-head" },
          el("span", { class: `power ${on ? "on" : ""}`, text: on ? t("ON") : t("OFF") }),
          el("div", { class: "who" }, el("strong", { text: device.name }), el("div", { class: "muted mono", text: device.id })),
          el("span", { class: `pill status ${device.online ? "" : "away"}`, text: device.online ? t("Online") : t("Offline") })),
        device.features?.length ? el("div", { class: "chips" }, device.features.map((f) => el("span", { class: "chip", text: said(f) }))) : null,
        el("div", { class: "facts" },
          fact(t("Room"), device.roomTemp), fact(t("Outdoor"), device.outdoorTemp),
          fact(t("Mode"), operationModeLabel(device.operationMode)), fact(t("Model"), device.model)),
        hidden ? el("p", { class: "muted note", text: t("Hidden from HomeKit. Settings › Devices shows it again.") }) : null,
        problem ? explain({
          error: problem,
          context: assistantContext("The user is looking at the device list of the Daikin Cloud plugin's page."),
          device: assistantDevice(device),
        }) : null);
    },
  };
  $("#btn-refresh-devices").addEventListener("click", (event) => act(event.currentTarget, () => devices.load({ refresh: true })));

  // MARK: Settings: a draft of the block's settings; Save writes it and the plugin reloads.

  const FEATURES = [
    ["showPowerfulMode", t("Powerful Mode"), t("Boost heating/cooling performance")],
    ["showEconoMode", t("Econo Mode"), t("Energy-saving operation")],
    ["showStreamerMode", t("Streamer Mode"), t("Air purification")],
    ["showOutdoorSilentMode", t("Outdoor Silent Mode"), t("Reduce outdoor unit noise")],
    ["showIndoorSilentMode", t("Indoor Silent Mode"), t("Quiet fan operation")],
    ["showAutoFanMode", t("Auto Fan Mode"), t("Automatic fan speed (switch)")],
    ["showOscillationSwitch", t("Oscillation Switch"), t("Swing as a separate switch (stays visible when grouped into a single tile)")],
    ["showSeparateFanControl", t("Separate Fan Tile"), t("Fan speed + oscillation as a standalone Fan tile (stays visible when grouped into a single tile)")],
    ["showDryMode", t("Dry Mode"), t("Dehumidification")],
    ["showFanOnlyMode", t("Fan Only Mode"), t("Fan without heating/cooling")],
    ["showHolidayMode", t("Holiday Mode"), t("Holiday / away mode as a switch")],
    ["showFirmwareUpdateSwitch", t("Firmware Update"), t("Install staged gateway firmware updates from HomeKit. Never enabled implicitly — the unit is unavailable while it updates")],
  ];
  // Switches that follow the legacy "Show Extra Features" flag when their own key is not set.
  const FEATURE_KEYS = ["showPowerfulMode", "showEconoMode", "showStreamerMode", "showOutdoorSilentMode", "showIndoorSilentMode", "showAutoFanMode",
    "showOscillationSwitch", "showDryMode", "showFanOnlyMode", "showHolidayMode"];
  // Standalone toggles, off unless set.
  const STANDALONE_KEYS = ["showSeparateFanControl", "showFirmwareUpdateSwitch"];

  const settings = {
    draft: null,
    saved: "",
    devices: [],
    loaded: false,

    async load() {
      if (this.loaded && this.dirty()) return;
      try {
        await readBlock();
        this.populate(block);
        this.loaded = true;
      } catch (e) {
        this.status("error", e.message);
      }
    },

    /// The draft from the block, with the plugin's rule: only a boolean overrides; absent or null follows
    /// showExtraFeatures for extra features, and is off for standalone ones.
    populate(config) {
      const legacy = config?.showExtraFeatures === true;
      const draft = {};
      for (const key of FEATURE_KEYS) draft[key] = typeof config?.[key] === "boolean" ? config[key] : legacy;
      for (const key of STANDALONE_KEYS) draft[key] = config?.[key] === true;
      draft.updateIntervalInMinutes = String(config?.updateIntervalInMinutes || 15);
      draft.forceUpdateDelay = String(Math.round((config?.forceUpdateDelay || 60000) / 1000));
      draft.oidcCallbackServerBindAddr = config?.oidcCallbackServerBindAddr || "0.0.0.0";
      draft.httpTransport = config?.httpTransport === "curl" ? "curl" : "node";
      draft.enableWebSocket = config?.enableWebSocket !== false;
      draft.excludedDevicesByDeviceId = [...(config?.excludedDevicesByDeviceId || [])];
      this.draft = draft;
      this.saved = JSON.stringify(draft);
      this.render();
    },

    dirty() { return this.draft && JSON.stringify(this.draft) !== this.saved; },

    render() {
      const draft = this.draft;
      if (!draft) return;
      $("#feature-toggles").replaceChildren(...FEATURES.map(([key, title, help]) => this.toggle(title, help, draft[key], (on) => { draft[key] = on; this.changed(); })));
      $("#updateIntervalInMinutes").value = draft.updateIntervalInMinutes;
      $("#forceUpdateDelay").value = draft.forceUpdateDelay;
      $("#oidcCallbackServerBindAddr").value = draft.oidcCallbackServerBindAddr;
      $("#httpTransport").value = draft.httpTransport;
      $("#enableWebSocket").checked = draft.enableWebSocket;
      this.renderDevices();
      this.changed();
    },

    toggle(title, help, checked, onChange, side) {
      const input = el("input", { type: "checkbox", checked });
      input.addEventListener("change", () => onChange(input.checked, input));
      return el("label", { class: "row-toggle" },
        el("span", { class: "who" }, el("span", { class: "field-title", text: title }), help ? el("span", { class: "help", text: help }) : null),
        el("span", { class: "side" }, side || null, el("span", { class: "switch" }, input, el("span"))));
    },

    renderDevices() {
      const box = $("#device-toggles");
      if (!this.draft) return;
      if (!this.devices.length) {
        box.replaceChildren(el("p", { class: "muted", text: t("No devices found. Sign in on Add accessories to see your devices.") }));
        return;
      }
      box.replaceChildren(...this.devices.map((device) => {
        const visible = !this.draft.excludedDevicesByDeviceId.includes(device.id);
        const state = el("span", { class: `state ${visible ? "" : "off"}`, text: visible ? t("Visible") : t("Hidden") });
        const row = this.toggle(device.name, null, visible, (on) => {
          const ids = this.draft.excludedDevicesByDeviceId.filter((id) => id !== device.id);
          if (!on) ids.push(device.id);
          this.draft.excludedDevicesByDeviceId = ids;
          state.textContent = on ? t("Visible") : t("Hidden");
          state.className = `state ${on ? "" : "off"}`;
          this.changed();
        }, state);
        row.querySelector(".who").append(el("span", { class: "mono", text: device.id }));
        return row;
      }));
    },

    valid() {
      const checks = [
        ["oidcCallbackServerBindAddr", (v) => isValidIPv4(v.trim())],
        ["updateIntervalInMinutes", (v) => isValidNumber(v, 1, 60)],
        // Seconds here; the block keeps milliseconds (5000-300000).
        ["forceUpdateDelay", (v) => isValidNumber(v, 5, 300)],
      ];
      return checks.map(([id, check]) => {
        const input = $(`#${id}`);
        const ok = check(input.value);
        input.classList.toggle("invalid", !ok);
        return ok;
      }).every(Boolean);
    },

    changed() {
      const dirty = this.dirty();
      $("#btn-settings-save").disabled = !dirty;
      $("#btn-settings-discard").disabled = !dirty;
      if (dirty) this.status("dirty", t("Unsaved changes"));
      else if ($("#settings-status").className !== "ok") this.status("muted", t("Saving applies at once: the plugin reloads with the new settings."));
    },

    status(kind, text) {
      const line = $("#settings-status");
      line.className = kind;
      line.textContent = text;
    },

    async save(button) {
      if (!this.valid()) { this.status("error", t("Check the highlighted fields.")); return; }
      const draft = this.draft;
      const changes = {
        updateIntervalInMinutes: parseInt(draft.updateIntervalInMinutes, 10) || 15,
        forceUpdateDelay: (parseInt(draft.forceUpdateDelay, 10) || 60) * 1000,
        oidcCallbackServerBindAddr: draft.oidcCallbackServerBindAddr.trim() || "0.0.0.0",
        excludedDevicesByDeviceId: draft.excludedDevicesByDeviceId,
        enableWebSocket: draft.enableWebSocket,
        httpTransport: draft.httpTransport === "curl" ? "curl" : "node",
      };
      for (const key of [...FEATURE_KEYS, ...STANDALONE_KEYS]) changes[key] = draft[key];
      await act(button, async () => {
        this.status("muted", t("Saving…"));
        const result = await saveBlock(changes);
        this.saved = JSON.stringify(this.draft);
        const pending = result.restartNeeded || [];
        this.status("ok", pending.length ? t("Saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.join("; ") }) : t("Saved. The plugin reloaded with the new settings."));
        this.changed();
        devices.load();
        setTimeout(() => auth.load(), 1500);
      }, (message) => this.status("error", t("Failed: {error}", { error: message })));
    },
  };
  for (const [id, key] of [["updateIntervalInMinutes", "updateIntervalInMinutes"], ["forceUpdateDelay", "forceUpdateDelay"], ["oidcCallbackServerBindAddr", "oidcCallbackServerBindAddr"]]) {
    $(`#${id}`).addEventListener("input", (event) => { if (settings.draft) { settings.draft[key] = event.currentTarget.value; settings.valid(); settings.changed(); } });
  }
  $("#httpTransport").addEventListener("change", (event) => { settings.draft.httpTransport = event.currentTarget.value; settings.changed(); });
  $("#enableWebSocket").addEventListener("change", (event) => { settings.draft.enableWebSocket = event.currentTarget.checked; settings.changed(); });
  $("#btn-settings-save").addEventListener("click", (event) => settings.save(event.currentTarget));
  $("#btn-settings-discard").addEventListener("click", () => { settings.draft = JSON.parse(settings.saved); settings.render(); });
  $("#subtabs").addEventListener("click", (event) => {
    const subtab = event.target.closest("button")?.dataset.subtab;
    if (!subtab) return;
    for (const button of $("#subtabs").querySelectorAll("button")) {
      button.classList.toggle("on", button.dataset.subtab === subtab);
      button.setAttribute("aria-selected", String(button.dataset.subtab === subtab));
    }
    for (const pane of document.querySelectorAll(".subtab")) pane.classList.toggle("hidden", pane.id !== `subtab-${subtab}`);
  });
  window.addEventListener("beforeunload", (event) => { if (settings.dirty()) { event.preventDefault(); event.returnValue = ""; } });

  // MARK: Help: the quota the plugin recorded on its last call (no API call).

  const MODE_LABELS = { developer_portal: "Developer Portal", mobile_app: t("Mobile App") };
  async function checkRateLimit(button) {
    const display = $("#rate-limit-display");
    const updated = $("#rate-limit-updated");
    display.textContent = t("Checking…");
    updated.classList.add("hidden");
    await act(button, async () => {
      const result = await request("rate-limit");
      if (!result.success || !result.rateLimit) { display.textContent = said(result.message) || t("No info"); return; }
      const { limitDay, remainingDay, limitMinute, remainingMinute } = result.rateLimit;
      let text = remainingDay !== undefined ? t("{remaining}/{limit} daily", { remaining: formatNumber(remainingDay), limit: formatNumber(limitDay) }) : "";
      if (remainingMinute !== undefined) {
        const perMinute = t("{remaining}/{limit}/min", { remaining: formatNumber(remainingMinute), limit: formatNumber(limitMinute) });
        text += text ? `, ${perMinute}` : perMinute;
      }
      display.textContent = text || t("No rate limit headers in the last response");
      if (result.updatedAt) {
        const parts = [t("as of {time}", { time: new Date(result.updatedAt).toLocaleString(HomeswiftI18n.locale) })];
        if (typeof result.ageMs === "number") parts.push(t("({time} ago)", { time: formatTime(result.ageMs) }));
        if (result.mode && result.mode !== authMode.current) parts.push(t("— recorded in {mode} mode", { mode: MODE_LABELS[result.mode] || result.mode }));
        updated.textContent = parts.join(" ");
        updated.classList.remove("hidden");
      }
    }, (message) => { display.textContent = t("Error: {error}", { error: message }); });
  }
  $("#btn-rate-limit").addEventListener("click", (event) => checkRateLimit(event.currentTarget));

  // MARK: Start

  (async () => {
    try {
      await readBlock();
      if (block?.authMode) authMode.current = block.authMode === "mobile_app" ? "mobile_app" : "developer_portal";
      settings.populate(block);
      settings.loaded = true;
    } catch (e) {
      $("#session-line").classList.remove("hidden");
      $("#session-line").textContent = e.message;
    }
    authMode.render();
    // The token renews itself; the page follows.
    poll(() => auth.load(), 60000);
    devices.load();
  })();
})();

"""#),
        "daikin.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Daikin Cloud page's own pieces, on the UI's materials: tabs like the Homebridge plugin's settings page,
   a card per unit with its state as facts, the settings with a save bar, and the sign-in's state. */

.page-head { align-items: center; }
.tile.daikin { background: linear-gradient(160deg, #3fb6f0, #007dbb); }
.head-status { margin-left: auto; font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.tabs { margin: 0 0 6px; flex-wrap: wrap; }
.tab-pane { animation: fade var(--normal) var(--ease-out); }
.section-head .tools { display: inline-flex; align-items: baseline; gap: 12px; }

/* Devices */
.unit { display: grid; gap: 12px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
.unit .server-head .who { flex: 1; min-width: 0; }
.unit .chips { margin-top: -2px; }
.unit .facts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
.unit.is-hidden { opacity: 0.7; }
.power { font-size: 0.6875rem; font-weight: 700; letter-spacing: 0.04em; padding: 2px 8px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
.power.on { color: var(--ok); border-color: rgba(31, 157, 85, 0.4); }
#session-line { margin: -4px 0 12px; }

/* Settings */
.settings-card { display: grid; gap: 14px; }
.subtabs { justify-self: start; }
.subtab { min-height: 120px; animation: fade var(--normal) var(--ease-out); }
.subtab > .note { margin-bottom: 4px; }
.row-toggle { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 10px 0; border-bottom: 1px solid var(--line); cursor: pointer; }
.row-toggle:last-child { border-bottom: 0; }
@media (hover: hover) and (pointer: fine) { .row-toggle:hover .field-title { color: var(--accent); } }
.row-toggle .field-title { margin: 0 0 2px; }
.row-toggle .help { display: block; }
.row-toggle .side { display: inline-flex; align-items: center; gap: 10px; flex: none; }
.row-toggle .state { font-size: 0.8125rem; min-width: 52px; text-align: right; }
.row-toggle .state.off { color: var(--muted); }
.row-toggle .who { min-width: 0; }
.row-toggle .mono { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }
input:invalid, input.invalid { border-color: var(--error) !important; }
.save-bar > .dirty { flex: 1; font-size: 0.8125rem; color: var(--warn); font-weight: 500; }
.save-bar > .ok, .save-bar > .error { flex: 1; font-size: 0.8125rem; }

/* Authentication */
.actions { flex-wrap: wrap; }

/* Help */
.rate { font-size: 1.125rem; font-weight: 600; margin: 10px 0 4px; font-variant-numeric: tabular-nums; }
.links { margin: 8px 0 0; padding-left: 18px; }
.links li { margin: 4px 0; }
.links a { color: var(--accent); text-decoration: none; }
.trouble { margin: 8px 0 0; }
.trouble dt { font-weight: 600; margin-top: 10px; }
.trouble dd { margin: 2px 0 0; color: var(--muted); font-size: 0.875rem; }

.busy::after {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .tab-pane, .subtab, .unit { animation: none; }
  .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}
@media (max-width: 640px) {
  .head-status { margin-left: 0; }
  .facts .wide-on-phone { grid-column: 1 / -1; }
}

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Daikin Cloud page's strings and the text its plugin answers, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Onecta integration for HomeKit: your air conditioners and Altherma heat pumps, from the Daikin cloud.": "L'intégration Onecta pour HomeKit : vos climatiseurs et pompes à chaleur Altherma, depuis le cloud Daikin.",
    "Checking…": "Vérification…",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Authentication": "Authentification",
    "Help": "Aide",
    "Discovered devices": "Appareils découverts",
    "Refresh": "Actualiser",
    "Plugin settings": "Réglages du plugin",
    "Features": "Fonctions",
    "Polling": "Interrogation",
    "Network": "Réseau",
    "Switches for additional modes in HomeKit. A switch appears only when the unit supports the feature.": "Des interrupteurs pour des modes supplémentaires dans HomeKit. Un interrupteur n'apparaît que si l'unité prend en charge la fonction.",
    "Update interval (minutes)": "Intervalle de mise à jour (minutes)",
    "Developer Portal: 15+ min · Mobile App: 1-5 min": "Developer Portal : 15 min ou plus · App mobile : 1 à 5 min",
    "Force update delay (seconds)": "Délai de mise à jour forcée (secondes)",
    "Developer Portal: 60 s · Mobile App: 10 s": "Developer Portal : 60 s · App mobile : 10 s",
    "Enable WebSocket": "Activer le WebSocket",
    "Real-time updates (Mobile App only)": "Mises à jour en temps réel (App mobile uniquement)",
    "OIDC callback bind address": "Adresse d'écoute du rappel OIDC",
    "The IPv4 address of the OAuth callback server (0.0.0.0 for all interfaces). 127.0.0.1 only accepts connections from this host, so the login redirect cannot reach it.": "L'adresse IPv4 du serveur de rappel OAuth (0.0.0.0 pour toutes les interfaces). 127.0.0.1 n'accepte que les connexions de cette machine : la redirection de connexion ne peut alors pas l'atteindre.",
    "HTTP transport": "Transport HTTP",
    "Built-in client (default)": "Client intégré (par défaut)",
    "curl subprocess (WAF fingerprint workaround)": "Sous-processus curl (contourne l'empreinte WAF)",
    "Use \"curl subprocess\" only if authentication times out on your network while curl works: some WAFs drop a client's TLS fingerprint (issue #6). Requires the curl binary; the WebSocket still uses the built-in TLS.": "N'utilisez « Sous-processus curl » que si l'authentification expire sur votre réseau alors que curl fonctionne : certains WAF rejettent l'empreinte TLS d'un client (ticket n° 6). Nécessite l'exécutable curl ; le WebSocket utilise toujours le TLS intégré.",
    "Show or hide each device in HomeKit.": "Affichez ou masquez chaque appareil dans HomeKit.",
    "Saving applies at once: the plugin reloads with the new settings.": "L'enregistrement s'applique aussitôt : le plugin se recharge avec les nouveaux réglages.",
    "Discard": "Annuler les modifications",
    "Save": "Enregistrer",
    "Status": "État",
    "Loading…": "Chargement…",
    "Mode": "Mode",
    "Expires": "Expire",
    "Test connection": "Tester la connexion",
    "Revoke access": "Révoquer l'accès",
    "Help & information": "Aide et informations",
    "API rate limit": "Limite de requêtes de l'API",
    "Check": "Vérifier",
    "200 requests/day": "200 requêtes/jour",
    "The Daikin API limits you to 200 requests per day.": "L'API Daikin vous limite à 200 requêtes par jour.",
    "Check shows the quota reported on the plugin's most recent API call; it does not use an API request itself.": "Vérifier affiche le quota indiqué lors du dernier appel d'API du plugin ; cela ne consomme aucune requête.",
    "Useful links": "Liens utiles",
    "The Homebridge plugin's repository": "Le dépôt du plugin Homebridge",
    "Report an issue": "Signaler un problème",
    "Troubleshooting": "Dépannage",
    "Token expired or invalid": "Jeton expiré ou non valide",
    "Authentication flow issues": "Problèmes d'authentification",
    "Check that the redirect URI in the portal matches exactly, bind the callback server to 0.0.0.0, check the firewall for the callback port.": "Vérifiez que l'URI de redirection du portail correspond exactement, faites écouter le serveur de rappel sur 0.0.0.0 et vérifiez le pare-feu pour le port de rappel.",
    "Device not appearing": "Un appareil n'apparaît pas",
    "Check the log, check the device in the Onecta app, check the hidden devices on Settings › Devices.": "Consultez le journal, vérifiez l'appareil dans l'app Onecta et les appareils masqués dans Réglages › Appareils.",
    "Auto": "Auto",
    "Cooling": "Refroidissement",
    "Heating": "Chauffage",
    "Dry": "Déshumidification",
    "Fan only": "Ventilation seule",
    "{days}d {hours}h {minutes}m": "{days} j {hours} h {minutes} min",
    "{hours}h {minutes}m {seconds}s": "{hours} h {minutes} min {seconds} s",
    "{minutes}m {seconds}s": "{minutes} min {seconds} s",
    "{seconds}s": "{seconds} s",
    "Expired": "Expiré",
    "Connected": "Connecté",
    "Token expired (will auto-refresh)": "Jeton expiré (renouvellement automatique)",
    "Token expired": "Jeton expiré",
    "Authenticated and ready": "Authentifié et prêt",
    "Not connected": "Non connecté",
    "Expires in {time}": "Expire dans {time}",
    "Test failed: {error}": "Échec du test : {error}",
    "Mobile App": "App mobile",
    "{n} requests/day": "{n} requêtes/jour",
    "The Daikin API limits you to {n} requests per day.": "L'API Daikin vous limite à {n} requêtes par jour.",
    "{n} (recommended)": "{n} (recommandé)",
    "Failed: {error}": "Échec : {error}",
    "{n} unit in HomeKit": "{n} unité dans HomeKit",
    "{n} units in HomeKit": "{n} unités dans HomeKit",
    "real-time updates over the WebSocket": "mises à jour en temps réel par WebSocket",
    "no WebSocket": "pas de WebSocket",
    "polling every {n} minute": "interrogation toutes les {n} minute",
    "polling every {n} minutes": "interrogation toutes les {n} minutes",
    "Loading devices…": "Chargement des appareils…",
    "Failed to load: {error}": "Échec du chargement : {error}",
    "As of {time}": "Données de {time}",
    "Fetched {time}": "Récupéré à {time}",
    "No devices found": "Aucun appareil trouvé",
    "ON": "ALLUMÉ",
    "OFF": "ÉTEINT",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Room": "Pièce",
    "Outdoor": "Extérieur",
    "Model": "Modèle",
    "Hidden from HomeKit. Settings › Devices shows it again.": "Masqué dans HomeKit. Réglages › Appareils permet de l'afficher à nouveau.",
    "Powerful Mode": "Mode Powerful",
    "Boost heating/cooling performance": "Augmente la puissance de chauffage ou de refroidissement",
    "Econo Mode": "Mode Econo",
    "Energy-saving operation": "Fonctionnement économe en énergie",
    "Streamer Mode": "Mode Streamer",
    "Air purification": "Purification de l'air",
    "Outdoor Silent Mode": "Mode silencieux extérieur",
    "Reduce outdoor unit noise": "Réduit le bruit de l'unité extérieure",
    "Indoor Silent Mode": "Mode silencieux intérieur",
    "Quiet fan operation": "Ventilation silencieuse",
    "Auto Fan Mode": "Ventilation automatique",
    "Automatic fan speed (switch)": "Vitesse de ventilation automatique (interrupteur)",
    "Oscillation Switch": "Interrupteur d'oscillation",
    "Swing as a separate switch (stays visible when grouped into a single tile)": "L'oscillation comme interrupteur séparé (reste visible quand les éléments sont regroupés en une seule vignette)",
    "Separate Fan Tile": "Vignette Ventilateur séparée",
    "Fan speed + oscillation as a standalone Fan tile (stays visible when grouped into a single tile)": "Vitesse de ventilation et oscillation dans une vignette Ventilateur à part (reste visible quand les éléments sont regroupés en une seule vignette)",
    "Dry Mode": "Mode déshumidification",
    "Dehumidification": "Déshumidification",
    "Fan Only Mode": "Mode ventilation seule",
    "Fan without heating/cooling": "Ventilation sans chauffage ni refroidissement",
    "Holiday Mode": "Mode vacances",
    "Holiday / away mode as a switch": "Le mode vacances ou absence comme interrupteur",
    "Firmware Update": "Mise à jour du firmware",
    "Install staged gateway firmware updates from HomeKit. Never enabled implicitly — the unit is unavailable while it updates": "Installe depuis HomeKit les mises à jour du firmware de la passerelle en attente. Jamais activé implicitement : l'unité est indisponible pendant la mise à jour",
    "Visible": "Visible",
    "Hidden": "Masqué",
    "Unsaved changes": "Modifications non enregistrées",
    "Check the highlighted fields.": "Vérifiez les champs mis en évidence.",
    "Saving…": "Enregistrement…",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Enregistré. Redémarrez Homeswift pour appliquer le reste ({changes}).",
    "Saved. The plugin reloaded with the new settings.": "Enregistré. Le plugin s'est rechargé avec les nouveaux réglages.",
    "No info": "Aucune information",
    "{remaining}/{limit} daily": "{remaining}/{limit} par jour",
    "{remaining}/{limit}/min": "{remaining}/{limit}/min",
    "No rate limit headers in the last response": "Aucun en-tête de limite dans la dernière réponse",
    "as of {time}": "au {time}",
    "({time} ago)": "(il y a {time})",
    "— recorded in {mode} mode": "— relevé en mode {mode}",
    "Error: {error}": "Erreur : {error}",
    "Power": "Marche/arrêt",
    "Temperature": "Température",
    "Fan": "Ventilateur",
    "Sensors": "Capteurs",
    "Hot Water": "Eau chaude",
    "Water Temp": "Temp. de l'eau",
    "Not authenticated. Please authenticate first.": "Non authentifié. Authentifiez-vous d'abord.",
    "Connection successful! Found {0} device(s).": "Connexion réussie ! {0} appareil(s) trouvé(s).",
    "Connection failed: {0}": "Échec de la connexion : {0}",
    "Failed to fetch devices: {0}": "Impossible de récupérer les appareils : {0}",
    "Found {0} device(s).": "{0} appareil(s) trouvé(s).",
    "No data yet — the plugin records this after its next API call.": "Pas encore de données : le plugin les enregistre après son prochain appel d'API.",
    "Could not read rate limit status: invalid file contents": "Impossible de lire l'état de la limite : contenu du fichier non valide",
    "Rate limit exceeded": "Limite de requêtes dépassée",
    "Token expired and no refresh token available. Please re-authenticate.": "Jeton expiré et aucun jeton d'actualisation disponible. Authentifiez-vous à nouveau.",
    "Sign in to your Daikin account": "Connectez-vous à votre compte Daikin",
    "Homeswift signs in on Add accessories, with the Onecta app's account or an app of the Daikin Developer Portal. Your units appear here once it is done.": "Homeswift se connecte dans Ajouter des accessoires, avec le compte de l'app Onecta ou une app du Daikin Developer Portal. Vos unités apparaissent ici une fois la connexion faite.",
    "Revoke access? The plugin stops until you sign in again on Add accessories.": "Révoquer l'accès ? Le plugin s'arrête jusqu'à ce que vous vous reconnectiez dans Ajouter des accessoires.",
    "The plugin is not connected to Daikin yet.": "Le plugin n'est pas encore connecté à Daikin.",
    "Make sure your Daikin devices are set up in the Onecta app.": "Vérifiez que vos appareils Daikin sont configurés dans l'app Onecta.",
    "No devices found. Sign in on Add accessories to see your devices.": "Aucun appareil trouvé. Connectez-vous dans Ajouter des accessoires pour voir vos appareils.",
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Révoquez l'accès dans l'onglet Authentification, puis reconnectez-vous dans Ajouter des accessoires."
  },
  "es": {
    "Onecta integration for HomeKit: your air conditioners and Altherma heat pumps, from the Daikin cloud.": "Integración de Onecta con HomeKit: tus aires acondicionados y bombas de calor Altherma, desde la nube de Daikin.",
    "Checking…": "Comprobando…",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Authentication": "Autenticación",
    "Help": "Ayuda",
    "Discovered devices": "Dispositivos descubiertos",
    "Refresh": "Actualizar",
    "Plugin settings": "Ajustes del plugin",
    "Features": "Funciones",
    "Polling": "Consulta periódica",
    "Network": "Red",
    "Switches for additional modes in HomeKit. A switch appears only when the unit supports the feature.": "Interruptores para modos adicionales en HomeKit. Un interruptor solo aparece si la unidad admite la función.",
    "Update interval (minutes)": "Intervalo de actualización (minutos)",
    "Developer Portal: 15+ min · Mobile App: 1-5 min": "Developer Portal: 15 min o más · App móvil: 1-5 min",
    "Force update delay (seconds)": "Retardo de actualización forzada (segundos)",
    "Developer Portal: 60 s · Mobile App: 10 s": "Developer Portal: 60 s · App móvil: 10 s",
    "Enable WebSocket": "Activar WebSocket",
    "Real-time updates (Mobile App only)": "Actualizaciones en tiempo real (solo app móvil)",
    "OIDC callback bind address": "Dirección de escucha del retorno OIDC",
    "The IPv4 address of the OAuth callback server (0.0.0.0 for all interfaces). 127.0.0.1 only accepts connections from this host, so the login redirect cannot reach it.": "La dirección IPv4 del servidor de retorno OAuth (0.0.0.0 para todas las interfaces). 127.0.0.1 solo acepta conexiones desde este equipo, así que la redirección del inicio de sesión no puede llegar a él.",
    "HTTP transport": "Transporte HTTP",
    "Built-in client (default)": "Cliente integrado (predeterminado)",
    "curl subprocess (WAF fingerprint workaround)": "Subproceso curl (evita la huella del WAF)",
    "Use \"curl subprocess\" only if authentication times out on your network while curl works: some WAFs drop a client's TLS fingerprint (issue #6). Requires the curl binary; the WebSocket still uses the built-in TLS.": "Usa «Subproceso curl» solo si la autenticación agota el tiempo de espera en tu red mientras curl funciona: algunos WAF descartan la huella TLS de un cliente (incidencia n.º 6). Necesita el binario de curl; el WebSocket sigue usando el TLS integrado.",
    "Show or hide each device in HomeKit.": "Muestra u oculta cada dispositivo en HomeKit.",
    "Saving applies at once: the plugin reloads with the new settings.": "Al guardar se aplica enseguida: el plugin se recarga con los nuevos ajustes.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "Status": "Estado",
    "Loading…": "Cargando…",
    "Mode": "Modo",
    "Expires": "Caduca",
    "Test connection": "Probar la conexión",
    "Revoke access": "Revocar el acceso",
    "Help & information": "Ayuda e información",
    "API rate limit": "Límite de solicitudes de la API",
    "Check": "Comprobar",
    "200 requests/day": "200 solicitudes/día",
    "The Daikin API limits you to 200 requests per day.": "La API de Daikin te limita a 200 solicitudes al día.",
    "Check shows the quota reported on the plugin's most recent API call; it does not use an API request itself.": "Comprobar muestra la cuota indicada en la última llamada a la API del plugin; no gasta ninguna solicitud.",
    "Useful links": "Enlaces útiles",
    "The Homebridge plugin's repository": "El repositorio del plugin de Homebridge",
    "Report an issue": "Informar de un problema",
    "Troubleshooting": "Solución de problemas",
    "Token expired or invalid": "Token caducado o no válido",
    "Authentication flow issues": "Problemas con la autenticación",
    "Check that the redirect URI in the portal matches exactly, bind the callback server to 0.0.0.0, check the firewall for the callback port.": "Comprueba que la URI de redirección del portal coincide exactamente, haz que el servidor de retorno escuche en 0.0.0.0 y revisa el cortafuegos para el puerto de retorno.",
    "Device not appearing": "Un dispositivo no aparece",
    "Check the log, check the device in the Onecta app, check the hidden devices on Settings › Devices.": "Consulta el registro, revisa el dispositivo en la app Onecta y los dispositivos ocultos en Ajustes › Dispositivos.",
    "Auto": "Auto",
    "Cooling": "Refrigeración",
    "Heating": "Calefacción",
    "Dry": "Deshumidificación",
    "Fan only": "Solo ventilador",
    "{days}d {hours}h {minutes}m": "{days} d {hours} h {minutes} min",
    "{hours}h {minutes}m {seconds}s": "{hours} h {minutes} min {seconds} s",
    "{minutes}m {seconds}s": "{minutes} min {seconds} s",
    "{seconds}s": "{seconds} s",
    "Expired": "Caducado",
    "Connected": "Conectado",
    "Token expired (will auto-refresh)": "Token caducado (se renovará automáticamente)",
    "Token expired": "Token caducado",
    "Authenticated and ready": "Autenticado y listo",
    "Not connected": "No conectado",
    "Expires in {time}": "Caduca en {time}",
    "Test failed: {error}": "La prueba ha fallado: {error}",
    "Mobile App": "App móvil",
    "{n} requests/day": "{n} solicitudes/día",
    "The Daikin API limits you to {n} requests per day.": "La API de Daikin te limita a {n} solicitudes al día.",
    "{n} (recommended)": "{n} (recomendado)",
    "Failed: {error}": "Error: {error}",
    "{n} unit in HomeKit": "{n} unidad en HomeKit",
    "{n} units in HomeKit": "{n} unidades en HomeKit",
    "real-time updates over the WebSocket": "actualizaciones en tiempo real por WebSocket",
    "no WebSocket": "sin WebSocket",
    "polling every {n} minute": "consulta cada {n} minuto",
    "polling every {n} minutes": "consulta cada {n} minutos",
    "Loading devices…": "Cargando dispositivos…",
    "Failed to load: {error}": "Error al cargar: {error}",
    "As of {time}": "Datos de las {time}",
    "Fetched {time}": "Obtenido a las {time}",
    "No devices found": "No se han encontrado dispositivos",
    "ON": "ENCENDIDO",
    "OFF": "APAGADO",
    "Online": "En línea",
    "Offline": "Sin conexión",
    "Room": "Habitación",
    "Outdoor": "Exterior",
    "Model": "Modelo",
    "Hidden from HomeKit. Settings › Devices shows it again.": "Oculto en HomeKit. Ajustes › Dispositivos lo vuelve a mostrar.",
    "Powerful Mode": "Modo Powerful",
    "Boost heating/cooling performance": "Aumenta la potencia de calefacción o refrigeración",
    "Econo Mode": "Modo Econo",
    "Energy-saving operation": "Funcionamiento de ahorro de energía",
    "Streamer Mode": "Modo Streamer",
    "Air purification": "Purificación del aire",
    "Outdoor Silent Mode": "Modo silencioso exterior",
    "Reduce outdoor unit noise": "Reduce el ruido de la unidad exterior",
    "Indoor Silent Mode": "Modo silencioso interior",
    "Quiet fan operation": "Ventilador silencioso",
    "Auto Fan Mode": "Ventilador automático",
    "Automatic fan speed (switch)": "Velocidad automática del ventilador (interruptor)",
    "Oscillation Switch": "Interruptor de oscilación",
    "Swing as a separate switch (stays visible when grouped into a single tile)": "La oscilación como interruptor aparte (sigue visible al agruparse en un solo mosaico)",
    "Separate Fan Tile": "Mosaico de ventilador aparte",
    "Fan speed + oscillation as a standalone Fan tile (stays visible when grouped into a single tile)": "Velocidad del ventilador y oscilación en un mosaico de ventilador independiente (sigue visible al agruparse en un solo mosaico)",
    "Dry Mode": "Modo deshumidificación",
    "Dehumidification": "Deshumidificación",
    "Fan Only Mode": "Modo solo ventilador",
    "Fan without heating/cooling": "Ventilador sin calefacción ni refrigeración",
    "Holiday Mode": "Modo vacaciones",
    "Holiday / away mode as a switch": "El modo vacaciones o ausencia como interruptor",
    "Firmware Update": "Actualización del firmware",
    "Install staged gateway firmware updates from HomeKit. Never enabled implicitly — the unit is unavailable while it updates": "Instala desde HomeKit las actualizaciones pendientes del firmware de la pasarela. Nunca se activa de forma implícita: la unidad no está disponible mientras se actualiza",
    "Visible": "Visible",
    "Hidden": "Oculto",
    "Unsaved changes": "Cambios sin guardar",
    "Check the highlighted fields.": "Revisa los campos resaltados.",
    "Saving…": "Guardando…",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Guardado. Reinicia Homeswift para aplicar el resto ({changes}).",
    "Saved. The plugin reloaded with the new settings.": "Guardado. El plugin se ha recargado con los nuevos ajustes.",
    "No info": "Sin información",
    "{remaining}/{limit} daily": "{remaining}/{limit} al día",
    "{remaining}/{limit}/min": "{remaining}/{limit}/min",
    "No rate limit headers in the last response": "No hay cabeceras de límite en la última respuesta",
    "as of {time}": "datos del {time}",
    "({time} ago)": "(hace {time})",
    "— recorded in {mode} mode": "— registrado en modo {mode}",
    "Error: {error}": "Error: {error}",
    "Power": "Encendido",
    "Temperature": "Temperatura",
    "Fan": "Ventilador",
    "Sensors": "Sensores",
    "Hot Water": "Agua caliente",
    "Water Temp": "Temp. del agua",
    "Not authenticated. Please authenticate first.": "No autenticado. Primero debes autenticarte.",
    "Connection successful! Found {0} device(s).": "¡Conexión correcta! {0} dispositivo(s) encontrado(s).",
    "Connection failed: {0}": "Error de conexión: {0}",
    "Failed to fetch devices: {0}": "No se han podido obtener los dispositivos: {0}",
    "Found {0} device(s).": "{0} dispositivo(s) encontrado(s).",
    "No data yet — the plugin records this after its next API call.": "Aún no hay datos: el plugin los registra tras su próxima llamada a la API.",
    "Could not read rate limit status: invalid file contents": "No se ha podido leer el estado del límite: contenido del archivo no válido",
    "Rate limit exceeded": "Límite de solicitudes superado",
    "Token expired and no refresh token available. Please re-authenticate.": "Token caducado y sin token de renovación. Vuelve a autenticarte.",
    "Sign in to your Daikin account": "Inicia sesión en tu cuenta de Daikin",
    "Homeswift signs in on Add accessories, with the Onecta app's account or an app of the Daikin Developer Portal. Your units appear here once it is done.": "Homeswift inicia sesión en Añadir accesorios, con la cuenta de la app Onecta o una app del Daikin Developer Portal. Tus unidades aparecen aquí una vez hecho.",
    "Revoke access? The plugin stops until you sign in again on Add accessories.": "¿Revocar el acceso? El plugin se detiene hasta que vuelvas a iniciar sesión en Añadir accesorios.",
    "The plugin is not connected to Daikin yet.": "El plugin aún no está conectado a Daikin.",
    "Make sure your Daikin devices are set up in the Onecta app.": "Asegúrate de que tus dispositivos Daikin están configurados en la app Onecta.",
    "No devices found. Sign in on Add accessories to see your devices.": "No se encontraron dispositivos. Inicia sesión en Añadir accesorios para ver tus dispositivos.",
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Revoca el acceso en la pestaña Autenticación y vuelve a iniciar sesión en Añadir accesorios."
  },
  "pt": {
    "Onecta integration for HomeKit: your air conditioners and Altherma heat pumps, from the Daikin cloud.": "Integração Onecta para o HomeKit: os aparelhos de ar condicionado e as bombas de calor Altherma, a partir da nuvem Daikin.",
    "Checking…": "A verificar…",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Authentication": "Autenticação",
    "Help": "Ajuda",
    "Discovered devices": "Dispositivos descobertos",
    "Refresh": "Atualizar",
    "Plugin settings": "Definições do plugin",
    "Features": "Funcionalidades",
    "Polling": "Consulta",
    "Network": "Rede",
    "Switches for additional modes in HomeKit. A switch appears only when the unit supports the feature.": "Interruptores para modos adicionais no HomeKit. Um interruptor só aparece quando a unidade suporta a funcionalidade.",
    "Update interval (minutes)": "Intervalo de atualização (minutos)",
    "Developer Portal: 15+ min · Mobile App: 1-5 min": "Developer Portal: 15 min ou mais · App móvel: 1-5 min",
    "Force update delay (seconds)": "Atraso da atualização forçada (segundos)",
    "Developer Portal: 60 s · Mobile App: 10 s": "Developer Portal: 60 s · App móvel: 10 s",
    "Enable WebSocket": "Ativar o WebSocket",
    "Real-time updates (Mobile App only)": "Atualizações em tempo real (apenas App móvel)",
    "OIDC callback bind address": "Endereço de escuta do retorno OIDC",
    "The IPv4 address of the OAuth callback server (0.0.0.0 for all interfaces). 127.0.0.1 only accepts connections from this host, so the login redirect cannot reach it.": "O endereço IPv4 do servidor de retorno OAuth (0.0.0.0 para todas as interfaces). 127.0.0.1 só aceita ligações deste computador, pelo que o redirecionamento do início de sessão não o consegue alcançar.",
    "HTTP transport": "Transporte HTTP",
    "Built-in client (default)": "Cliente integrado (predefinição)",
    "curl subprocess (WAF fingerprint workaround)": "Subprocesso curl (contorna a impressão digital do WAF)",
    "Use \"curl subprocess\" only if authentication times out on your network while curl works: some WAFs drop a client's TLS fingerprint (issue #6). Requires the curl binary; the WebSocket still uses the built-in TLS.": "Use «Subprocesso curl» apenas se a autenticação esgotar o tempo na sua rede enquanto o curl funciona: alguns WAF rejeitam a impressão digital TLS de um cliente (issue n.º 6). Requer o binário curl; o WebSocket continua a usar o TLS integrado.",
    "Show or hide each device in HomeKit.": "Mostrar ou ocultar cada dispositivo no HomeKit.",
    "Saving applies at once: the plugin reloads with the new settings.": "Ao guardar, as alterações aplicam-se de imediato: o plugin recarrega com as novas definições.",
    "Discard": "Descartar",
    "Save": "Guardar",
    "Status": "Estado",
    "Loading…": "A carregar…",
    "Mode": "Modo",
    "Expires": "Expira",
    "Test connection": "Testar a ligação",
    "Revoke access": "Revogar o acesso",
    "Help & information": "Ajuda e informações",
    "API rate limit": "Limite de pedidos da API",
    "Check": "Verificar",
    "200 requests/day": "200 pedidos/dia",
    "The Daikin API limits you to 200 requests per day.": "A API da Daikin está limitada a 200 pedidos por dia.",
    "Check shows the quota reported on the plugin's most recent API call; it does not use an API request itself.": "Verificar mostra a quota indicada na chamada à API mais recente do plugin; não gasta nenhum pedido.",
    "Useful links": "Ligações úteis",
    "The Homebridge plugin's repository": "O repositório do plugin Homebridge",
    "Report an issue": "Comunicar um problema",
    "Troubleshooting": "Resolução de problemas",
    "Token expired or invalid": "Token expirado ou inválido",
    "Authentication flow issues": "Problemas na autenticação",
    "Check that the redirect URI in the portal matches exactly, bind the callback server to 0.0.0.0, check the firewall for the callback port.": "Verifique se o URI de redirecionamento no portal coincide exatamente, ponha o servidor de retorno à escuta em 0.0.0.0 e verifique a firewall para a porta de retorno.",
    "Device not appearing": "Um dispositivo não aparece",
    "Check the log, check the device in the Onecta app, check the hidden devices on Settings › Devices.": "Consulte o registo, verifique o dispositivo na app Onecta e os dispositivos ocultos em Definições › Dispositivos.",
    "Auto": "Auto",
    "Cooling": "Arrefecimento",
    "Heating": "Aquecimento",
    "Dry": "Desumidificação",
    "Fan only": "Só ventilação",
    "{days}d {hours}h {minutes}m": "{days} d {hours} h {minutes} min",
    "{hours}h {minutes}m {seconds}s": "{hours} h {minutes} min {seconds} s",
    "{minutes}m {seconds}s": "{minutes} min {seconds} s",
    "{seconds}s": "{seconds} s",
    "Expired": "Expirado",
    "Connected": "Ligado",
    "Token expired (will auto-refresh)": "Token expirado (será renovado automaticamente)",
    "Token expired": "Token expirado",
    "Authenticated and ready": "Autenticado e pronto",
    "Not connected": "Não ligado",
    "Expires in {time}": "Expira dentro de {time}",
    "Test failed: {error}": "O teste falhou: {error}",
    "Mobile App": "App móvel",
    "{n} requests/day": "{n} pedidos/dia",
    "The Daikin API limits you to {n} requests per day.": "A API da Daikin está limitada a {n} pedidos por dia.",
    "{n} (recommended)": "{n} (recomendado)",
    "Failed: {error}": "Falhou: {error}",
    "{n} unit in HomeKit": "{n} unidade no HomeKit",
    "{n} units in HomeKit": "{n} unidades no HomeKit",
    "real-time updates over the WebSocket": "atualizações em tempo real por WebSocket",
    "no WebSocket": "sem WebSocket",
    "polling every {n} minute": "consulta a cada {n} minuto",
    "polling every {n} minutes": "consulta a cada {n} minutos",
    "Loading devices…": "A carregar os dispositivos…",
    "Failed to load: {error}": "Falha ao carregar: {error}",
    "As of {time}": "Às {time}",
    "Fetched {time}": "Obtido às {time}",
    "No devices found": "Nenhum dispositivo encontrado",
    "ON": "LIGADO",
    "OFF": "DESLIGADO",
    "Online": "Online",
    "Offline": "Offline",
    "Room": "Divisão",
    "Outdoor": "Exterior",
    "Model": "Modelo",
    "Hidden from HomeKit. Settings › Devices shows it again.": "Oculto no HomeKit. Definições › Dispositivos volta a mostrá-lo.",
    "Powerful Mode": "Modo Powerful",
    "Boost heating/cooling performance": "Aumenta a potência de aquecimento ou arrefecimento",
    "Econo Mode": "Modo Econo",
    "Energy-saving operation": "Funcionamento com poupança de energia",
    "Streamer Mode": "Modo Streamer",
    "Air purification": "Purificação do ar",
    "Outdoor Silent Mode": "Modo silencioso exterior",
    "Reduce outdoor unit noise": "Reduz o ruído da unidade exterior",
    "Indoor Silent Mode": "Modo silencioso interior",
    "Quiet fan operation": "Ventilação silenciosa",
    "Auto Fan Mode": "Ventilação automática",
    "Automatic fan speed (switch)": "Velocidade automática da ventoinha (interruptor)",
    "Oscillation Switch": "Interruptor de oscilação",
    "Swing as a separate switch (stays visible when grouped into a single tile)": "A oscilação como interruptor separado (continua visível quando agrupado num único mosaico)",
    "Separate Fan Tile": "Mosaico de ventoinha separado",
    "Fan speed + oscillation as a standalone Fan tile (stays visible when grouped into a single tile)": "Velocidade da ventoinha e oscilação num mosaico de ventoinha independente (continua visível quando agrupado num único mosaico)",
    "Dry Mode": "Modo desumidificação",
    "Dehumidification": "Desumidificação",
    "Fan Only Mode": "Modo só ventilação",
    "Fan without heating/cooling": "Ventilação sem aquecimento nem arrefecimento",
    "Holiday Mode": "Modo férias",
    "Holiday / away mode as a switch": "O modo férias ou ausência como interruptor",
    "Firmware Update": "Atualização do firmware",
    "Install staged gateway firmware updates from HomeKit. Never enabled implicitly — the unit is unavailable while it updates": "Instala a partir do HomeKit as atualizações pendentes do firmware do gateway. Nunca é ativado implicitamente: a unidade fica indisponível durante a atualização",
    "Visible": "Visível",
    "Hidden": "Oculto",
    "Unsaved changes": "Alterações não guardadas",
    "Check the highlighted fields.": "Verifique os campos assinalados.",
    "Saving…": "A guardar…",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Guardado. Reinicie o Homeswift para aplicar o resto ({changes}).",
    "Saved. The plugin reloaded with the new settings.": "Guardado. O plugin recarregou com as novas definições.",
    "No info": "Sem informação",
    "{remaining}/{limit} daily": "{remaining}/{limit} por dia",
    "{remaining}/{limit}/min": "{remaining}/{limit}/min",
    "No rate limit headers in the last response": "Sem cabeçalhos de limite na última resposta",
    "as of {time}": "em {time}",
    "({time} ago)": "(há {time})",
    "— recorded in {mode} mode": "— registado no modo {mode}",
    "Error: {error}": "Erro: {error}",
    "Power": "Ligar/desligar",
    "Temperature": "Temperatura",
    "Fan": "Ventoinha",
    "Sensors": "Sensores",
    "Hot Water": "Água quente",
    "Water Temp": "Temp. da água",
    "Not authenticated. Please authenticate first.": "Não autenticado. Autentique-se primeiro.",
    "Connection successful! Found {0} device(s).": "Ligação bem-sucedida! {0} dispositivo(s) encontrado(s).",
    "Connection failed: {0}": "Falha na ligação: {0}",
    "Failed to fetch devices: {0}": "Não foi possível obter os dispositivos: {0}",
    "Found {0} device(s).": "{0} dispositivo(s) encontrado(s).",
    "No data yet — the plugin records this after its next API call.": "Ainda sem dados: o plugin regista-os após a próxima chamada à API.",
    "Could not read rate limit status: invalid file contents": "Não foi possível ler o estado do limite: conteúdo do ficheiro inválido",
    "Rate limit exceeded": "Limite de pedidos excedido",
    "Token expired and no refresh token available. Please re-authenticate.": "Token expirado e sem token de atualização disponível. Autentique-se novamente.",
    "Sign in to your Daikin account": "Inicie sessão na sua conta Daikin",
    "Homeswift signs in on Add accessories, with the Onecta app's account or an app of the Daikin Developer Portal. Your units appear here once it is done.": "O Homeswift inicia sessão em Adicionar acessórios, com a conta da app Onecta ou uma app do Daikin Developer Portal. As suas unidades aparecem aqui quando terminar.",
    "Revoke access? The plugin stops until you sign in again on Add accessories.": "Revogar o acesso? O plugin para até iniciar sessão de novo em Adicionar acessórios.",
    "The plugin is not connected to Daikin yet.": "O plugin ainda não está ligado à Daikin.",
    "Make sure your Daikin devices are set up in the Onecta app.": "Verifique se os seus dispositivos Daikin estão configurados na app Onecta.",
    "No devices found. Sign in on Add accessories to see your devices.": "Nenhum dispositivo encontrado. Inicie sessão em Adicionar acessórios para ver os seus dispositivos.",
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Revogue o acesso no separador Autenticação e inicie sessão de novo em Adicionar acessórios."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Daikin Cloud</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="daikin.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large daikin" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M3 8h11a3 3 0 1 0-3-3"/><path d="M3 12h16a3 3 0 1 1-3 3"/><path d="M3 16h7"/></svg></span>
    <div class="who">
      <h1>Daikin Cloud</h1>
      <p class="muted" data-i18n>Onecta integration for HomeKit: your air conditioners and Altherma heat pumps, from the Daikin cloud.</p>
    </div>
    <div class="tools head-status">
      <span id="token-expires" class="muted hidden"></span>
      <span id="status-badge" class="pill status standby" data-i18n>Checking…</span>
    </div>
  </div>

  <div class="group tabs" role="tablist" id="tabs">
    <button role="tab" aria-controls="tab-devices" data-tab="devices" class="on" aria-selected="true" data-i18n>Devices</button>
    <button role="tab" aria-controls="tab-settings" data-tab="settings" aria-selected="false" data-i18n data-action-icon="sliders">Settings</button>
    <button role="tab" aria-controls="tab-auth" data-tab="auth" aria-selected="false" data-i18n data-action-icon="key">Authentication</button>
    <button role="tab" aria-controls="tab-help" data-tab="help" aria-selected="false" data-i18n>Help</button>
  </div>

  <!-- Devices -->
  <section class="tab-pane" id="tab-devices" role="tabpanel">
    <div class="section-head"><h2 data-i18n>Discovered devices</h2><span class="tools"><span id="devices-fetched" class="muted"></span><button id="btn-refresh-devices" data-i18n data-action-icon="restore">Refresh</button></span></div>
    <p id="session-line" class="muted note hidden"></p>
    <div id="devices-list" class="grid"></div>
    <div id="devices-problem"></div>
  </section>

  <!-- Settings -->
  <section class="tab-pane hidden" id="tab-settings" role="tabpanel">
    <div class="section-head"><h2 data-i18n>Plugin settings</h2></div>
    <div class="card settings-card">
      <div class="group tabs subtabs" role="tablist" id="subtabs">
        <button role="tab" data-subtab="features" class="on" aria-selected="true" data-i18n>Features</button>
        <button role="tab" data-subtab="polling" aria-selected="false" data-i18n>Polling</button>
        <button role="tab" data-subtab="network" aria-selected="false" data-i18n>Network</button>
        <button role="tab" data-subtab="devices" aria-selected="false" data-i18n>Devices</button>
      </div>

      <div class="subtab" id="subtab-features">
        <p class="muted note" data-i18n>Switches for additional modes in HomeKit. A switch appears only when the unit supports the feature.</p>
        <div id="feature-toggles"></div>
      </div>

      <div class="subtab hidden" id="subtab-polling">
        <div class="fields">
          <label class="field"><span class="field-title" data-i18n>Update interval (minutes)</span>
            <input type="number" id="updateIntervalInMinutes" min="1" max="60" step="1" placeholder="15 (recommended)">
            <span class="help" data-i18n>Developer Portal: 15+ min · Mobile App: 1-5 min</span></label>
          <label class="field"><span class="field-title" data-i18n>Force update delay (seconds)</span>
            <input type="number" id="forceUpdateDelay" min="5" max="300" step="1" placeholder="60 (recommended)">
            <span class="help" data-i18n>Developer Portal: 60 s · Mobile App: 10 s</span></label>
        </div>
        <label class="toggle hidden" id="websocket-setting-row"><span class="switch"><input type="checkbox" id="enableWebSocket"><span></span></span>
          <span><span class="field-title" data-i18n>Enable WebSocket</span><span class="help" data-i18n>Real-time updates (Mobile App only)</span></span></label>
      </div>

      <div class="subtab hidden" id="subtab-network">
        <div class="fields">
          <label class="field"><span class="field-title" data-i18n>OIDC callback bind address</span>
            <input type="text" id="oidcCallbackServerBindAddr" placeholder="0.0.0.0" spellcheck="false" autocomplete="off">
            <span class="help" data-i18n>The IPv4 address of the OAuth callback server (0.0.0.0 for all interfaces). 127.0.0.1 only accepts connections from this host, so the login redirect cannot reach it.</span></label>
          <label class="field"><span class="field-title" data-i18n>HTTP transport</span>
            <select id="httpTransport"><option value="node" data-i18n>Built-in client (default)</option><option value="curl" data-i18n>curl subprocess (WAF fingerprint workaround)</option></select>
            <span class="help" data-i18n>Use "curl subprocess" only if authentication times out on your network while curl works: some WAFs drop a client's TLS fingerprint (issue #6). Requires the curl binary; the WebSocket still uses the built-in TLS.</span></label>
        </div>
      </div>

      <div class="subtab hidden" id="subtab-devices">
        <p class="muted note" data-i18n>Show or hide each device in HomeKit.</p>
        <div id="device-toggles"></div>
      </div>

      <div class="save-bar" id="settings-bar"><span id="settings-status" class="muted" role="status" aria-live="polite" data-i18n>Saving applies at once: the plugin reloads with the new settings.</span>
        <button id="btn-settings-discard" disabled data-i18n data-action-icon="close">Discard</button><button id="btn-settings-save" class="primary" disabled data-i18n data-action-icon="check">Save</button></div>
    </div>
  </section>

  <!-- Authentication -->
  <section class="tab-pane hidden" id="tab-auth" role="tabpanel">
    <div class="section-head"><h2 data-i18n>Authentication</h2></div>
    <div id="auth-setup"></div>
    <div class="card hidden" id="auth-status-card">
      <div class="facts">
        <div class="fact wide-on-phone"><span data-i18n>Status</span><b id="auth-status" data-i18n>Loading…</b></div>
        <div class="fact"><span data-i18n>Mode</span><b id="auth-mode-text">Developer Portal</b></div>
        <div class="fact hidden" id="expires-row"><span data-i18n>Expires</span><b id="auth-token-expires">—</b></div>
      </div>
      <div class="actions">
        <button id="btn-test" data-i18n data-action-icon="send">Test connection</button>
        <a id="btn-sign-in-again" class="button" href="/setup?start" data-i18n data-action-icon="key">Sign in again</a>
        <button id="btn-revoke" class="danger" data-i18n data-action-icon="logout">Revoke access</button>
      </div>
      <p id="test-result" class="status-line" role="status" aria-live="polite"></p>
      <div id="test-problem"></div>
    </div>
  </section>

  <!-- Help -->
  <section class="tab-pane hidden" id="tab-help" role="tabpanel">
    <div class="section-head"><h2 data-i18n>Help & information</h2></div>
    <div class="card">
      <div class="item-head"><strong data-i18n>API rate limit</strong><button id="btn-rate-limit" data-i18n data-action-icon="restore">Check</button></div>
      <p id="rate-limit-display" class="rate" data-i18n>200 requests/day</p>
      <p class="muted note" id="rate-limit-info" data-i18n>The Daikin API limits you to 200 requests per day.</p>
      <p class="muted note hidden" id="rate-limit-updated"></p>
      <p class="muted note" data-i18n>Check shows the quota reported on the plugin's most recent API call; it does not use an API request itself.</p>
    </div>
    <div class="card">
      <strong data-i18n>Useful links</strong>
      <ul class="links">
        <li><a href="https://developer.cloud.daikineurope.com/" target="_blank" rel="noopener noreferrer">Daikin Developer Portal</a></li>
        <li><a href="https://github.com/mp-consulting/homebridge-daikin-cloud" target="_blank" rel="noopener noreferrer" data-i18n>The Homebridge plugin's repository</a></li>
        <li><a href="https://github.com/mp-consulting/homebridge-daikin-cloud/issues" target="_blank" rel="noopener noreferrer" data-i18n>Report an issue</a></li>
      </ul>
    </div>
    <div class="card">
      <strong data-i18n>Troubleshooting</strong>
      <dl class="trouble">
        <dt data-i18n>Token expired or invalid</dt><dd data-i18n>Revoke access on the Authentication tab, then sign in again on Add accessories.</dd>
        <dt data-i18n>Authentication flow issues</dt><dd data-i18n>Check that the redirect URI in the portal matches exactly, bind the callback server to 0.0.0.0, check the firewall for the callback port.</dd>
        <dt data-i18n>Device not appearing</dt><dd data-i18n>Check the log, check the device in the Onecta app, check the hidden devices on Settings › Devices.</dd>
      </dl>
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
