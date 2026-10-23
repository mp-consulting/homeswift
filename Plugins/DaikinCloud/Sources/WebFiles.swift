// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DaikinCloudPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Daikin Cloud page, after the Homebridge plugin's settings UI: the devices the account has; the plugin's
// settings (feature switches, polling, network, hidden devices), saved to this instance's block; logging in,
// with the Onecta app's email and password or the Developer Portal's OAuth flow and its HTTPS callback server;
// and help, with the quota the plugin saw on its last call.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, act, poll } = homeswift;

  const OPERATION_MODE_LABELS = { auto: "Auto", cooling: "Cooling", heating: "Heating", dry: "Dry", fanOnly: "Fan only" };
  const numberFormat = new Intl.NumberFormat();
  const formatNumber = (value) => (value !== null && value !== undefined && value !== "" && Number.isFinite(Number(value)) ? numberFormat.format(Number(value)) : String(value ?? ""));
  const plural = (count, singular, pluralForm = `${singular}s`) => `${formatNumber(count)} ${count === 1 ? singular : pluralForm}`;
  const operationModeLabel = (mode) => (mode ? OPERATION_MODE_LABELS[mode] || String(mode).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : "");
  const isValidPort = (port) => { const n = parseInt(port, 10); return !isNaN(n) && n >= 1 && n <= 65535; };
  const isValidNumber = (value, min, max) => { const n = parseInt(value, 10); return !isNaN(n) && n >= min && n <= max; };
  const isValidIPv4 = (ip) => !ip || /^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.){3}(25[0-5]|(2[0-4]|1\d|[1-9]|)\d)$/.test(ip);
  function formatTime(ms) {
    const days = Math.floor(ms / 86400000), hours = Math.floor((ms % 86400000) / 3600000);
    const minutes = Math.floor((ms % 3600000) / 60000), seconds = Math.floor((ms % 60000) / 1000);
    if (days > 0) return `${days}d ${hours}h ${minutes}m`;
    if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
    if (minutes > 0) return `${minutes}m ${seconds}s`;
    return `${seconds}s`;
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

  // MARK: Status: the header badge, the token countdown, the Authentication tab's facts.

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
      if (status.authenticated) {
        badge.className = `pill status ${status.isExpired ? "away" : ""}`;
        badge.textContent = status.isExpired ? "Expired" : "Connected";
        $("#auth-status").textContent = status.isExpired ? (status.canRefresh ? "Token expired (will auto-refresh)" : "Token expired") : "Authenticated and ready";
        this.expiresAt = status.expiresAt ? new Date(status.expiresAt) : null;
        $("#expires-row").classList.toggle("hidden", !this.expiresAt);
        $("#btn-authenticate").textContent = "Re-authenticate";
        $("#btn-revoke").classList.remove("hidden");
        $("#btn-test").disabled = false;
        this.startCountdown();
      } else {
        badge.className = "pill status away";
        badge.textContent = "Not connected";
        $("#auth-status").textContent = status.error || "Authentication required";
        this.expiresAt = null;
        $("#expires-row").classList.add("hidden");
        $("#token-expires").classList.add("hidden");
        $("#btn-authenticate").textContent = "Authenticate";
        $("#btn-revoke").classList.add("hidden");
        $("#btn-test").disabled = true;
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
        header.textContent = "Token expired";
        $("#auth-token-expires").textContent = "Expired";
        this.stopCountdown();
        this.load();
        return;
      }
      const text = formatTime(left);
      header.textContent = `Expires in ${text}`;
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
        result.textContent = answer.message;
        if (!answer.success) offerExplain($("#test-problem"), answer.message, "Test Connection on the plugin's page (reads the saved token and lists the gateway devices from the Daikin Onecta API) failed.");
      }, (message) => {
        result.className = "status-line error";
        result.textContent = `Test failed: ${message}`;
        offerExplain($("#test-problem"), result.textContent, "Test Connection on the plugin's page failed.");
      });
    },

    async revoke(button) {
      if (!confirm("Revoke access? The plugin stops until you authenticate again.")) return;
      await act(button, async () => {
        await request("auth/revoke", { method: "POST", body: { clientId: block?.clientId, clientSecret: block?.clientSecret } });
        await this.load();
        devices.load();
      });
    },
  };
  $("#btn-test").addEventListener("click", (event) => auth.test(event.currentTarget));
  $("#btn-revoke").addEventListener("click", (event) => auth.revoke(event.currentTarget));

  // MARK: Authentication method

  const authMode = {
    current: "developer_portal",
    DEFAULTS: {
      developer_portal: { updateIntervalInMinutes: 15, forceUpdateDelay: 60000, enableWebSocket: false },
      mobile_app: { updateIntervalInMinutes: 5, forceUpdateDelay: 10000, enableWebSocket: true },
    },

    render() {
      const mobile = this.current === "mobile_app";
      $("#authMode").value = this.current;
      $("#auth-mode-hint").textContent = mobile ? "Use your Daikin Onecta account (same as mobile app)" : "Requires API credentials from the Daikin Developer Portal";
      $("#btn-authenticate").classList.toggle("hidden", mobile);
      $("#btn-authenticate-mobile").classList.toggle("hidden", !mobile);
      $("#auth-mode-text").textContent = mobile ? "Mobile App" : "Developer Portal";
      const daily = formatNumber(mobile ? 3000 : 200);
      $("#rate-limit-display").textContent = `${daily} requests/day`;
      $("#rate-limit-info").textContent = `The Daikin API limits you to ${daily} requests per day.`;
      $("#websocket-setting-row").classList.toggle("hidden", !mobile);
      $("#updateIntervalInMinutes").placeholder = mobile ? "5 (recommended)" : "15 (recommended)";
      $("#forceUpdateDelay").placeholder = mobile ? "10 (recommended)" : "60 (recommended)";
    },

    /// A new method saves at once, with its recommended polling (as the Homebridge page does).
    async change(select) {
      const previous = this.current;
      this.current = select.value;
      this.render();
      if (previous === this.current) return;
      try {
        await saveBlock({ authMode: this.current, ...this.DEFAULTS[this.current] });
        settings.populate(block);
        devices.load();
        auth.load();
      } catch (e) {
        alert(`Could not save the authentication method: ${e.message}`);
      }
    },
  };
  $("#authMode").addEventListener("change", (event) => authMode.change(event.currentTarget));

  // MARK: Mobile App login

  const mobileAuth = {
    show() {
      $("#mobile-auth-form").classList.remove("hidden");
      $("#auth-status-card").classList.add("hidden");
      $("#mobile-auth-result").textContent = "";
      offerExplain($("#mobile-auth-problem"), null);
      $("#daikinEmail").value = block?.daikinEmail || "";
      $("#daikinPassword").value = block?.daikinPassword || "";
      breadcrumb("Mobile App credentials", () => this.hide());
    },
    hide() {
      $("#mobile-auth-form").classList.add("hidden");
      $("#auth-status-card").classList.remove("hidden");
      breadcrumb("Authentication", () => switchTab("devices"));
    },
    async test(button) {
      const email = $("#daikinEmail").value.trim();
      const password = $("#daikinPassword").value;
      const result = $("#mobile-auth-result");
      offerExplain($("#mobile-auth-problem"), null);
      if (!email || !password) {
        result.className = "status-line error";
        result.textContent = "Please enter email and password";
        return;
      }
      await act(button, async () => {
        result.className = "status-line muted";
        result.textContent = "Logging in to Daikin…";
        const answer = await request("auth/mobile-test", { method: "POST", body: { email, password } });
        if (!answer.success) {
          result.className = "status-line error";
          result.textContent = answer.message || "Authentication failed";
          offerExplain($("#mobile-auth-problem"), result.textContent, "Mobile App login (Onecta account, Gigya login at id.daikin.eu, then OIDC token exchange) from the plugin's page failed.");
          return;
        }
        await saveBlock({ authMode: "mobile_app", daikinEmail: email, daikinPassword: password });
        authMode.current = "mobile_app";
        authMode.render();
        const remaining = answer.rateLimit?.remainingDay;
        const limit = formatNumber(answer.rateLimit?.limitDay ?? 3000);
        const quota = remaining !== undefined && remaining !== null ? `${formatNumber(remaining)}/${limit}` : limit;
        result.className = "status-line ok";
        result.textContent = `Success! Found ${plural(Number(answer.deviceCount) || 0, "device")}. Rate limit: ${quota}/day. The plugin reloads with the credentials.`;
        setTimeout(() => { this.hide(); auth.load(); devices.load(); }, 2000);
      }, (message) => {
        result.className = "status-line error";
        result.textContent = `Failed: ${message}`;
        offerExplain($("#mobile-auth-problem"), result.textContent, "Mobile App login from the plugin's page failed.");
      });
    },
  };
  $("#btn-authenticate-mobile").addEventListener("click", () => mobileAuth.show());
  $("#btn-mobile-cancel").addEventListener("click", () => mobileAuth.hide());
  $("#btn-test-mobile-auth").addEventListener("click", (event) => mobileAuth.test(event.currentTarget));

  // MARK: Developer Portal login: configure, authorize (the callback server catches the redirect, or the URL is
  // pasted), complete.

  const wizard = {
    step: 1,
    authUrl: null,
    polling: null,

    async show() {
      $("#wizard").classList.remove("hidden");
      $("#auth-status-card").classList.add("hidden");
      breadcrumb("Developer Portal login", () => this.hide());
      for (const key of ["clientId", "clientSecret", "callbackServerExternalAddress"]) $(`#${key}`).value = block?.[key] || "";
      $("#callbackServerPort").value = block?.callbackServerPort || 8582;
      this.go(1);
      this.preview();
      if (!$("#callbackServerExternalAddress").value) {
        try {
          const { primaryIp } = await request("server/info");
          if (primaryIp && !$("#callbackServerExternalAddress").value) $("#callbackServerExternalAddress").value = primaryIp;
          $("#callbackServerExternalAddress").placeholder = primaryIp || "e.g. 192.168.1.100";
          this.preview();
        } catch { /* typed by hand */ }
      }
    },

    hide() {
      this.stopPolling();
      request("auth/stop-server", { method: "POST", body: {} }).catch(() => {});
      $("#wizard").classList.add("hidden");
      $("#auth-status-card").classList.remove("hidden");
      $("#callback-server-status").classList.add("hidden");
      breadcrumb("Authentication", () => switchTab("devices"));
    },

    go(step) {
      this.step = step;
      [1, 2, 3].forEach((i) => $(`#content-${i}`).classList.toggle("hidden", i !== step));
      [...$("#wizard-steps").children].forEach((item, i) => {
        item.classList.toggle("current", i + 1 === step && step < 3);
        item.classList.toggle("done", i + 1 < step || step === 3);
      });
    },

    form() {
      return {
        clientId: $("#clientId").value.trim(),
        clientSecret: $("#clientSecret").value.trim(),
        callbackServerExternalAddress: $("#callbackServerExternalAddress").value.trim(),
        callbackServerPort: $("#callbackServerPort").value.trim() || "8582",
      };
    },

    preview() {
      const { callbackServerExternalAddress: address, callbackServerPort: port } = this.form();
      $("#redirect-preview").textContent = `https://${address || "<address>"}:${port || "8582"}`;
    },

    async proceed(button) {
      const config = this.form();
      const errors = $("#validation-errors");
      offerExplain($("#wizard-start-problem"), null);
      const port = $("#callbackServerPort");
      if (!isValidPort(config.callbackServerPort)) {
        port.classList.add("invalid");
        errors.textContent = "Port must be between 1 and 65535";
        return;
      }
      port.classList.remove("invalid");
      await act(button, async () => {
        const validation = await request("config/validate", { method: "POST", body: config });
        if (!validation.valid) {
          errors.replaceChildren(...validation.errors.map((e) => el("div", { text: e })));
          return;
        }
        errors.replaceChildren();
        const result = await request("auth/start", { method: "POST", body: { ...config, oidcCallbackServerBindAddr: block?.oidcCallbackServerBindAddr } });
        this.authUrl = result.authUrl;
        $("#auth-url").textContent = result.authUrl;
        $("#auth-url-container").classList.remove("hidden");
        $("#callback-server-status").classList.toggle("hidden", !result.callbackServerRunning);
        $("#manual-callback").open = !result.callbackServerRunning;
        $("#wizard-auth-problem").replaceChildren(result.callbackServerRunning ? "" :
          el("p", { class: "status-line error", text: `${result.message}${result.callbackServerError ? ` (${result.callbackServerError})` : ""}` }));
        this.startPolling();
        this.go(2);
      }, (message) => {
        errors.replaceChildren(el("div", { text: message }));
        offerExplain($("#wizard-start-problem"), message, "Starting the Developer Portal OAuth login (temporary HTTPS callback server) from the plugin's page failed.");
      });
    },

    open() { if (this.authUrl) window.open(this.authUrl, "_blank", "noopener"); },

    startPolling() {
      this.stopPolling();
      const poll = async () => {
        if (!this.polling) return;
        try {
          const result = await request("auth/poll");
          if (!result.pending) {
            this.stopPolling();
            if (result.success) await this.succeeded(result.message || "Authentication successful!");
            else this.failed(`Authentication failed: ${result.error || "Unknown error"}`);
            return;
          }
        } catch { /* try again */ }
        if (this.polling) this.polling = setTimeout(poll, 1500);
      };
      this.polling = setTimeout(poll, 1500);
    },
    stopPolling() { clearTimeout(this.polling); this.polling = null; },

    async submitCallback(button) {
      const url = $("#callbackUrl").value.trim();
      offerExplain($("#wizard-auth-problem"), null);
      if (!url) return this.failed("Please paste the callback URL");
      if (!url.includes("code=")) return this.failed("Invalid URL - must contain code parameter");
      await act(button, async () => {
        const result = await request("auth/callback", { method: "POST", body: { callbackUrl: url } });
        if (result.success) await this.succeeded(result.message);
        else this.failed(`Authentication failed: ${result.message || "Unknown error"}`);
      }, (message) => this.failed(`Authentication failed: ${message}`));
    },

    failed(message) {
      const slot = $("#wizard-auth-problem");
      slot.replaceChildren(el("p", { class: "status-line error", text: message }),
        explain({ error: message, context: assistantContext("Completing the Developer Portal OAuth login (exchanging the authorization code from the Daikin redirect for tokens) failed.") }));
    },

    /// Saves the app's credentials and the callback address in the block, as the Homebridge page does; the
    /// plugin reloads with them and the token.
    async succeeded(message) {
      this.stopPolling();
      $("#success-message").textContent = message;
      this.go(3);
      const config = this.form();
      try {
        await saveBlock({
          authMode: "developer_portal", clientId: config.clientId, clientSecret: config.clientSecret,
          callbackServerExternalAddress: config.callbackServerExternalAddress, callbackServerPort: parseInt(config.callbackServerPort, 10) || 8582,
        });
      } catch (e) {
        $("#success-message").textContent = `${message} The settings could not be saved: ${e.message}`;
      }
      authMode.current = "developer_portal";
      authMode.render();
    },

    finish() {
      this.hide();
      auth.load();
      devices.load();
    },
  };
  $("#btn-authenticate").addEventListener("click", () => wizard.show());
  $("#btn-wizard-cancel").addEventListener("click", () => wizard.hide());
  $("#btn-wizard-continue").addEventListener("click", (event) => wizard.proceed(event.currentTarget));
  $("#btn-wizard-back").addEventListener("click", () => { wizard.stopPolling(); wizard.go(1); });
  $("#btn-open-auth").addEventListener("click", () => wizard.open());
  $("#btn-submit-callback").addEventListener("click", (event) => wizard.submitCallback(event.currentTarget));
  $("#btn-wizard-done").addEventListener("click", () => wizard.finish());
  for (const id of ["callbackServerExternalAddress", "callbackServerPort"]) $(`#${id}`).addEventListener("input", () => wizard.preview());

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
        line.textContent = "The plugin is not connected to Daikin yet: authenticate on the Authentication tab.";
        return;
      }
      const parts = [`${plural(session.devices ?? 0, "unit")} in HomeKit`];
      if (session.mode === "mobile_app") parts.push(session.webSocket ? "real-time updates over the WebSocket" : "no WebSocket");
      if (session.pollMinutes) parts.push(`polling every ${plural(session.pollMinutes, "minute")}`);
      line.textContent = parts.join(" · ");
    },

    async load({ refresh = false } = {}) {
      const list = $("#devices-list");
      offerExplain($("#devices-problem"), null);
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: "Loading devices…" })));
      let result;
      try {
        result = await deviceList.fetch({ refresh });
      } catch (e) {
        list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "error", text: `Failed to load: ${e.message}` })));
        offerExplain($("#devices-problem"), `Failed to load: ${e.message}`, "Loading the device list (GET /v1/gateway-devices on the Daikin Onecta API) on the plugin's page failed.");
        return;
      }
      $("#devices-fetched").textContent = result.fetchedAt ? `${result.cached ? "As of" : "Fetched"} ${new Date(result.fetchedAt).toLocaleTimeString()}` : "";
      if (!result.success) {
        if (result.message?.includes("Not authenticated")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { text: "Please authenticate first." }),
            el("p", { class: "muted" }, "Go to the ", el("button", { class: "link", text: "Authentication", onclick: () => switchTab("auth") }), " tab to connect.")));
        } else {
          list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "error", text: result.message })));
          offerExplain($("#devices-problem"), result.message, "Loading the device list (GET /v1/gateway-devices on the Daikin Onecta API) on the plugin's page failed.");
        }
        return;
      }
      this.items = result.devices;
      settings.devices = result.devices;
      settings.renderDevices();
      if (!result.devices.length) {
        list.replaceChildren(el("div", { class: "card empty" },
          el("p", { text: "No devices found" }),
          el("p", { class: "muted", text: "Make sure you're authenticated and your Daikin devices are set up in the Onecta app." })));
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
          el("span", { class: `power ${on ? "on" : ""}`, text: on ? "ON" : "OFF" }),
          el("div", { class: "who" }, el("strong", { text: device.name }), el("div", { class: "muted mono", text: device.id })),
          el("span", { class: `pill status ${device.online ? "" : "away"}`, text: device.online ? "Online" : "Offline" })),
        device.features?.length ? el("div", { class: "chips" }, device.features.map((f) => el("span", { class: "chip", text: f }))) : null,
        el("div", { class: "facts" },
          fact("Room", device.roomTemp), fact("Outdoor", device.outdoorTemp),
          fact("Mode", operationModeLabel(device.operationMode)), fact("Model", device.model)),
        hidden ? el("p", { class: "muted note", text: "Hidden from HomeKit. Settings › Devices shows it again." }) : null,
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
    ["showPowerfulMode", "Powerful Mode", "Boost heating/cooling performance"],
    ["showEconoMode", "Econo Mode", "Energy-saving operation"],
    ["showStreamerMode", "Streamer Mode", "Air purification"],
    ["showOutdoorSilentMode", "Outdoor Silent Mode", "Reduce outdoor unit noise"],
    ["showIndoorSilentMode", "Indoor Silent Mode", "Quiet fan operation"],
    ["showAutoFanMode", "Auto Fan Mode", "Automatic fan speed (switch)"],
    ["showOscillationSwitch", "Oscillation Switch", "Swing as a separate switch (stays visible when grouped into a single tile)"],
    ["showSeparateFanControl", "Separate Fan Tile", "Fan speed + oscillation as a standalone Fan tile (stays visible when grouped into a single tile)"],
    ["showDryMode", "Dry Mode", "Dehumidification"],
    ["showFanOnlyMode", "Fan Only Mode", "Fan without heating/cooling"],
    ["showHolidayMode", "Holiday Mode", "Holiday / away mode as a switch"],
    ["showFirmwareUpdateSwitch", "Firmware Update", "Install staged gateway firmware updates from HomeKit. Never enabled implicitly — the unit is unavailable while it updates"],
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
        box.replaceChildren(el("p", { class: "muted", text: "No devices found. Authenticate first to see your devices." }));
        return;
      }
      box.replaceChildren(...this.devices.map((device) => {
        const visible = !this.draft.excludedDevicesByDeviceId.includes(device.id);
        const state = el("span", { class: `state ${visible ? "" : "off"}`, text: visible ? "Visible" : "Hidden" });
        const row = this.toggle(device.name, null, visible, (on) => {
          const ids = this.draft.excludedDevicesByDeviceId.filter((id) => id !== device.id);
          if (!on) ids.push(device.id);
          this.draft.excludedDevicesByDeviceId = ids;
          state.textContent = on ? "Visible" : "Hidden";
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
      if (dirty) this.status("dirty", "Unsaved changes");
      else if ($("#settings-status").className !== "ok") this.status("muted", "Saving applies at once: the plugin reloads with the new settings.");
    },

    status(kind, text) {
      const line = $("#settings-status");
      line.className = kind;
      line.textContent = text;
    },

    async save(button) {
      if (!this.valid()) { this.status("error", "Check the highlighted fields."); return; }
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
        this.status("muted", "Saving…");
        const result = await saveBlock(changes);
        this.saved = JSON.stringify(this.draft);
        const pending = result.restartNeeded || [];
        this.status("ok", pending.length ? `Saved. Restart Homeswift to apply the rest (${pending.join("; ")}).` : "Saved. The plugin reloaded with the new settings.");
        this.changed();
        devices.load();
        setTimeout(() => auth.load(), 1500);
      }, (message) => this.status("error", `Failed: ${message}`));
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

  const MODE_LABELS = { developer_portal: "Developer Portal", mobile_app: "Mobile App" };
  async function checkRateLimit(button) {
    const display = $("#rate-limit-display");
    const updated = $("#rate-limit-updated");
    display.textContent = "Checking…";
    updated.classList.add("hidden");
    await act(button, async () => {
      const result = await request("rate-limit");
      if (!result.success || !result.rateLimit) { display.textContent = result.message || "No info"; return; }
      const { limitDay, remainingDay, limitMinute, remainingMinute } = result.rateLimit;
      let text = remainingDay !== undefined ? `${formatNumber(remainingDay)}/${formatNumber(limitDay)} daily` : "";
      if (remainingMinute !== undefined) {
        const perMinute = `${formatNumber(remainingMinute)}/${formatNumber(limitMinute)}/min`;
        text += text ? `, ${perMinute}` : perMinute;
      }
      display.textContent = text || "No rate limit headers in the last response";
      if (result.updatedAt) {
        const parts = [`as of ${new Date(result.updatedAt).toLocaleString()}`];
        if (typeof result.ageMs === "number") parts.push(`(${formatTime(result.ageMs)} ago)`);
        if (result.mode && result.mode !== authMode.current) parts.push(`— recorded in ${MODE_LABELS[result.mode] || result.mode} mode`);
        updated.textContent = parts.join(" ");
        updated.classList.remove("hidden");
      }
    }, (message) => { display.textContent = `Error: ${message}`; });
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
   a card per unit with its state as facts, the settings with a save bar, and the Developer Portal login as a
   three-step wizard with one step showing at a time. */

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
.actions.end { justify-content: flex-end; }
.actions { flex-wrap: wrap; }
.info-box, .warn-box { margin: 0 0 12px; padding: 12px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.875rem; }
.warn-box { border-color: rgba(201, 115, 26, 0.35); }
.info-box ol { margin: 6px 0 0; padding-left: 20px; }
.error-list:empty { display: none; }
.error-list { color: var(--error); font-size: 0.875rem; margin: 10px 0 0; }
.url-box { padding: 10px 12px; border-radius: 12px; background: var(--material-thin); border: 1px solid var(--line); overflow-wrap: anywhere; margin: 6px 0 4px; }
.waiting::before {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-right: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
.success { text-align: center; padding: 10px 0 16px; }
.success .check { display: inline-grid; place-items: center; width: 56px; height: 56px; border-radius: 50%; background: var(--ok); color: #fff; font-size: 28px; }
.success h3 { margin: 12px 0 4px; }
.steps { display: flex; gap: 6px; list-style: none; margin: 0 0 18px; padding: 0; flex-wrap: wrap; }
.steps li { display: inline-flex; align-items: center; gap: 8px; padding: 5px 12px 5px 5px; border-radius: 999px; color: var(--muted); font-weight: 500; }
.steps li::before {
  content: attr(data-n); width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-size: 0.8125rem;
  background: var(--material-thin); border: 1px solid var(--edge); font-variant-numeric: tabular-nums;
}
.steps li.current { color: var(--text); background: var(--material-thin); }
.steps li.current::before { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
.steps li.done::before { content: "✓"; color: var(--ok); }
.step { animation: fade var(--normal) var(--ease-out); }

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
  .tab-pane, .subtab, .unit, .step { animation: none; }
  .busy::after, .waiting::before { animation: none; border-right-color: currentColor; opacity: 0.5; }
}
@media (max-width: 640px) {
  .head-status { margin-left: 0; }
  .facts .wide-on-phone { grid-column: 1 / -1; }
}

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
<header><a class="brand" href="/"><img src="/icon.svg" class="logo" alt="">Homeswift</a></header>
<main>
  <div class="page-head">
    <span class="tile large daikin" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M3 8h11a3 3 0 1 0-3-3"/><path d="M3 12h16a3 3 0 1 1-3 3"/><path d="M3 16h7"/></svg></span>
    <div class="who">
      <h1>Daikin Cloud</h1>
      <p class="muted">Onecta integration for HomeKit: your air conditioners and Altherma heat pumps, from the Daikin cloud.</p>
    </div>
    <div class="tools head-status">
      <span id="token-expires" class="muted hidden"></span>
      <span id="status-badge" class="pill status standby">Checking…</span>
    </div>
  </div>

  <div class="group tabs" role="tablist" id="tabs">
    <button role="tab" data-tab="devices" class="on" aria-selected="true">Devices</button>
    <button role="tab" data-tab="settings" aria-selected="false">Settings</button>
    <button role="tab" data-tab="auth" aria-selected="false">Authentication</button>
    <button role="tab" data-tab="help" aria-selected="false">Help</button>
  </div>

  <!-- Devices -->
  <section class="tab-pane" id="tab-devices">
    <div class="section-head"><h2>Discovered devices</h2><span class="tools"><span id="devices-fetched" class="muted"></span><button id="btn-refresh-devices">Refresh</button></span></div>
    <p id="session-line" class="muted note hidden"></p>
    <div id="devices-list" class="grid"></div>
    <div id="devices-problem"></div>
  </section>

  <!-- Settings -->
  <section class="tab-pane hidden" id="tab-settings">
    <div class="section-head"><h2>Plugin settings</h2></div>
    <div class="card settings-card">
      <div class="group tabs subtabs" role="tablist" id="subtabs">
        <button role="tab" data-subtab="features" class="on" aria-selected="true">Features</button>
        <button role="tab" data-subtab="polling" aria-selected="false">Polling</button>
        <button role="tab" data-subtab="network" aria-selected="false">Network</button>
        <button role="tab" data-subtab="devices" aria-selected="false">Devices</button>
      </div>

      <div class="subtab" id="subtab-features">
        <p class="muted note">Switches for additional modes in HomeKit. A switch appears only when the unit supports the feature.</p>
        <div id="feature-toggles"></div>
      </div>

      <div class="subtab hidden" id="subtab-polling">
        <div class="fields">
          <label class="field"><span class="field-title">Update interval (minutes)</span>
            <input type="number" id="updateIntervalInMinutes" min="1" max="60" step="1" placeholder="15 (recommended)">
            <span class="help">Developer Portal: 15+ min · Mobile App: 1-5 min</span></label>
          <label class="field"><span class="field-title">Force update delay (seconds)</span>
            <input type="number" id="forceUpdateDelay" min="5" max="300" step="1" placeholder="60 (recommended)">
            <span class="help">Developer Portal: 60 s · Mobile App: 10 s</span></label>
        </div>
        <label class="toggle hidden" id="websocket-setting-row"><span class="switch"><input type="checkbox" id="enableWebSocket"><span></span></span>
          <span><span class="field-title">Enable WebSocket</span><span class="help">Real-time updates (Mobile App only)</span></span></label>
      </div>

      <div class="subtab hidden" id="subtab-network">
        <div class="fields">
          <label class="field"><span class="field-title">OIDC callback bind address</span>
            <input type="text" id="oidcCallbackServerBindAddr" placeholder="0.0.0.0" spellcheck="false" autocomplete="off">
            <span class="help">The IPv4 address of the OAuth callback server (0.0.0.0 for all interfaces). 127.0.0.1 only accepts connections from this host, so the login redirect cannot reach it.</span></label>
          <label class="field"><span class="field-title">HTTP transport</span>
            <select id="httpTransport"><option value="node">Built-in client (default)</option><option value="curl">curl subprocess (WAF fingerprint workaround)</option></select>
            <span class="help">Use "curl subprocess" only if authentication times out on your network while curl works: some WAFs drop a client's TLS fingerprint (issue #6). Requires the curl binary; the WebSocket still uses the built-in TLS.</span></label>
        </div>
      </div>

      <div class="subtab hidden" id="subtab-devices">
        <p class="muted note">Show or hide each device in HomeKit.</p>
        <div id="device-toggles"></div>
      </div>

      <div class="save-bar" id="settings-bar"><span id="settings-status" class="muted">Saving applies at once: the plugin reloads with the new settings.</span>
        <button id="btn-settings-discard" disabled>Discard</button><button id="btn-settings-save" class="primary" disabled>Save</button></div>
    </div>
  </section>

  <!-- Authentication -->
  <section class="tab-pane hidden" id="tab-auth">
    <div class="section-head"><h2>Authentication</h2></div>
    <div class="card">
      <label class="field"><span class="field-title">Authentication method</span>
        <select id="authMode">
          <option value="developer_portal">Developer Portal (200 API calls/day)</option>
          <option value="mobile_app">Mobile App (3,000 API calls/day + WebSocket)</option>
        </select>
        <span class="help" id="auth-mode-hint">Requires API credentials from the Daikin Developer Portal</span></label>
    </div>

    <div class="card" id="auth-status-card">
      <div class="facts">
        <div class="fact wide-on-phone"><span>Status</span><b id="auth-status">Loading…</b></div>
        <div class="fact"><span>Mode</span><b id="auth-mode-text">Developer Portal</b></div>
        <div class="fact hidden" id="expires-row"><span>Expires</span><b id="auth-token-expires">—</b></div>
      </div>
      <div class="actions">
        <button id="btn-test">Test connection</button>
        <button id="btn-authenticate" class="primary">Authenticate</button>
        <button id="btn-authenticate-mobile" class="primary hidden">Configure credentials</button>
        <button id="btn-revoke" class="danger hidden">Revoke access</button>
      </div>
      <p id="test-result" class="status-line"></p>
      <div id="test-problem"></div>
    </div>

    <div class="card hidden" id="mobile-auth-form">
      <div class="info-box"><strong>Mobile App authentication</strong><br>Use your Daikin Onecta account (the same as the mobile app).<br><span class="muted">3,000 API calls/day and real-time WebSocket updates.</span></div>
      <div class="fields">
        <label class="field"><span class="field-title">Daikin account email</span><input type="email" id="daikinEmail" placeholder="your@email.com" autocomplete="username"></label>
        <label class="field"><span class="field-title">Daikin account password</span><input type="password" id="daikinPassword" placeholder="Enter your password" autocomplete="current-password"></label>
      </div>
      <p id="mobile-auth-result" class="status-line"></p>
      <div id="mobile-auth-problem"></div>
      <div class="actions end"><button id="btn-mobile-cancel">Cancel</button><button id="btn-test-mobile-auth" class="primary">Test &amp; save credentials</button></div>
    </div>

    <div class="card hidden" id="wizard">
      <ol class="steps" id="wizard-steps">
        <li data-n="1">Configure</li><li data-n="2">Authorize</li><li data-n="3">Complete</li>
      </ol>

      <div class="step" id="content-1">
        <div class="info-box">Get your credentials from the <a href="https://developer.cloud.daikineurope.com/" target="_blank" rel="noopener noreferrer">Daikin Developer Portal</a>.
          <br><span class="muted"><strong>Redirect URI:</strong> <code id="redirect-preview">https://&lt;address&gt;:&lt;port&gt;</code></span></div>
        <div class="fields">
          <label class="field"><span class="field-title">Client ID</span><input type="text" id="clientId" placeholder="Enter your Client ID" spellcheck="false" autocomplete="off"></label>
          <label class="field"><span class="field-title">Client secret</span><input type="password" id="clientSecret" placeholder="Enter your Client Secret" autocomplete="off"></label>
          <label class="field"><span class="field-title">Callback server address</span><input type="text" id="callbackServerExternalAddress" placeholder="Auto-detecting…" spellcheck="false" autocomplete="off">
            <span class="help">This machine's address as your browser reaches it (detected).</span></label>
          <label class="field"><span class="field-title">Callback server port</span><input type="number" id="callbackServerPort" placeholder="8582" min="1" max="65535"></label>
        </div>
        <div id="validation-errors" class="error-list"></div>
        <div id="wizard-start-problem"></div>
        <div class="actions end"><button id="btn-wizard-cancel">Cancel</button><button id="btn-wizard-continue" class="primary">Continue</button></div>
      </div>

      <div class="step hidden" id="content-2">
        <p>Open the Daikin login page and sign in with your account. This page follows along.</p>
        <div id="auth-url-container" class="hidden">
          <span class="field-title">Authorization URL</span>
          <div class="url-box mono" id="auth-url"></div>
          <span class="help">If the button does not work, copy this URL into your browser.</span>
        </div>
        <div class="actions"><button id="btn-wizard-back">Back</button><button id="btn-open-auth" class="primary">Open Daikin login</button></div>
        <div id="wizard-auth-problem"></div>
        <p id="callback-server-status" class="status-line waiting hidden">Waiting for authentication… Complete the login in the new window. This page will update automatically.</p>
        <details id="manual-callback">
          <summary>Manual entry (if the automatic redirect fails)</summary>
          <p class="warn-box">If you see an error page after the login, copy the <strong>full URL</strong> from your browser's address bar and paste it below. Your browser also warns once about the callback server's self-signed certificate: that is expected.</p>
          <label class="field"><span class="field-title">Callback URL</span><input type="text" id="callbackUrl" placeholder="Paste the full URL from your browser (https://…?code=…)" spellcheck="false" autocomplete="off">
            <span class="help">The URL contains a <code>?code=</code> parameter.</span></label>
          <div class="actions"><button id="btn-submit-callback" class="primary">Complete authentication</button></div>
        </details>
      </div>

      <div class="step hidden" id="content-3">
        <div class="success"><span class="check" aria-hidden="true">✓</span><h3>Authentication successful</h3><p id="success-message" class="muted">Your Daikin Cloud account is now connected.</p></div>
        <div class="info-box"><strong>Next steps</strong>
          <ol><li>Your settings are saved, and the plugin reloads with them.</li><li>Your Daikin devices appear in HomeKit within a minute.</li></ol></div>
        <div class="actions end"><button id="btn-wizard-done" class="primary">Done</button></div>
      </div>
    </div>
  </section>

  <!-- Help -->
  <section class="tab-pane hidden" id="tab-help">
    <div class="section-head"><h2>Help &amp; information</h2></div>
    <div class="card">
      <div class="item-head"><strong>API rate limit</strong><button id="btn-rate-limit">Check</button></div>
      <p id="rate-limit-display" class="rate">200 requests/day</p>
      <p class="muted note" id="rate-limit-info">The Daikin API limits you to 200 requests per day.</p>
      <p class="muted note hidden" id="rate-limit-updated"></p>
      <p class="muted note">Check shows the quota reported on the plugin's most recent API call; it does not use an API request itself.</p>
    </div>
    <div class="card">
      <strong>Useful links</strong>
      <ul class="links">
        <li><a href="https://developer.cloud.daikineurope.com/" target="_blank" rel="noopener noreferrer">Daikin Developer Portal</a></li>
        <li><a href="https://github.com/mp-consulting/homebridge-daikin-cloud" target="_blank" rel="noopener noreferrer">The Homebridge plugin's repository</a></li>
        <li><a href="https://github.com/mp-consulting/homebridge-daikin-cloud/issues" target="_blank" rel="noopener noreferrer">Report an issue</a></li>
      </ul>
    </div>
    <div class="card">
      <strong>Troubleshooting</strong>
      <dl class="trouble">
        <dt>Token expired or invalid</dt><dd>Revoke access on the Authentication tab (or delete the token file in the plugin's folder), then authenticate again.</dd>
        <dt>Authentication flow issues</dt><dd>Check that the redirect URI in the portal matches exactly, bind the callback server to 0.0.0.0, check the firewall for the callback port.</dd>
        <dt>Device not appearing</dt><dd>Check the log, check the device in the Onecta app, check the hidden devices on Settings › Devices.</dd>
      </dl>
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
