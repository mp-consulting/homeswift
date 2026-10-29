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
  const { t, tn } = HomeswiftI18n;
  /// Text from the plugin (a message in an answer), in the page's language when the catalog knows it.
  const said = (text) => HomeswiftI18n.message(text);

  const OPERATION_MODE_LABELS = { auto: t("Auto"), cooling: t("Cooling"), heating: t("Heating"), dry: t("Dry"), fanOnly: t("Fan only") };
  const numberFormat = new Intl.NumberFormat(HomeswiftI18n.locale);
  const formatNumber = (value) => (value !== null && value !== undefined && value !== "" && Number.isFinite(Number(value)) ? numberFormat.format(Number(value)) : String(value ?? ""));
  const operationModeLabel = (mode) => (mode ? OPERATION_MODE_LABELS[mode] || String(mode).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : "");
  /// `text` with an element where its `{name}` placeholder is: a sentence keeps its words in the language's order.
  const around = (text, name, element) => {
    const [before, after = ""] = text.split(`{${name}}`);
    return [before, element, after];
  };
  const isValidPort = (port) => { const n = parseInt(port, 10); return !isNaN(n) && n >= 1 && n <= 65535; };
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
        badge.textContent = status.isExpired ? t("Expired") : t("Connected");
        $("#auth-status").textContent = status.isExpired ? (status.canRefresh ? t("Token expired (will auto-refresh)") : t("Token expired")) : t("Authenticated and ready");
        this.expiresAt = status.expiresAt ? new Date(status.expiresAt) : null;
        $("#expires-row").classList.toggle("hidden", !this.expiresAt);
        $("#btn-authenticate").textContent = t("Re-authenticate");
        $("#btn-revoke").classList.remove("hidden");
        $("#btn-test").disabled = false;
        this.startCountdown();
      } else {
        badge.className = "pill status away";
        badge.textContent = t("Not connected");
        $("#auth-status").textContent = status.error || t("Authentication required");
        this.expiresAt = null;
        $("#expires-row").classList.add("hidden");
        $("#token-expires").classList.add("hidden");
        $("#btn-authenticate").textContent = t("Authenticate");
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
      if (!await HomeswiftCommon.confirmDialog(t("Revoke access? The plugin stops until you authenticate again."))) return;
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
      $("#auth-mode-hint").textContent = mobile ? t("Use your Daikin Onecta account (same as mobile app)") : t("Requires API credentials from the Daikin Developer Portal");
      $("#btn-authenticate").classList.toggle("hidden", mobile);
      $("#btn-authenticate-mobile").classList.toggle("hidden", !mobile);
      $("#auth-mode-text").textContent = mobile ? t("Mobile App") : "Developer Portal";
      const daily = mobile ? 3000 : 200;
      $("#rate-limit-display").textContent = t("{n} requests/day", { n: daily });
      $("#rate-limit-info").textContent = t("The Daikin API limits you to {n} requests per day.", { n: daily });
      $("#websocket-setting-row").classList.toggle("hidden", !mobile);
      $("#updateIntervalInMinutes").placeholder = t("{n} (recommended)", { n: mobile ? 5 : 15 });
      $("#forceUpdateDelay").placeholder = t("{n} (recommended)", { n: mobile ? 10 : 60 });
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
        HomeswiftCommon.showAlert(t("Could not save the authentication method: {error}", { error: e.message }));
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
      breadcrumb(t("Mobile App credentials"), () => this.hide());
    },
    hide() {
      $("#mobile-auth-form").classList.add("hidden");
      $("#auth-status-card").classList.remove("hidden");
      breadcrumb(t("Authentication"), () => switchTab("devices"));
    },
    async test(button) {
      const email = $("#daikinEmail").value.trim();
      const password = $("#daikinPassword").value;
      const result = $("#mobile-auth-result");
      offerExplain($("#mobile-auth-problem"), null);
      if (!email || !password) {
        result.className = "status-line error";
        result.textContent = t("Please enter email and password");
        return;
      }
      await act(button, async () => {
        result.className = "status-line muted";
        result.textContent = t("Logging in to Daikin…");
        const answer = await request("auth/mobile-test", { method: "POST", body: { email, password } });
        if (!answer.success) {
          result.className = "status-line error";
          result.textContent = said(answer.message) || t("Authentication failed");
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
        result.textContent = tn("Success! Found {n} device. Rate limit: {quota}/day. The plugin reloads with the credentials.",
          "Success! Found {n} devices. Rate limit: {quota}/day. The plugin reloads with the credentials.", Number(answer.deviceCount) || 0, { quota });
        setTimeout(() => { this.hide(); auth.load(); devices.load(); }, 2000);
      }, (message) => {
        result.className = "status-line error";
        result.textContent = t("Failed: {error}", { error: message });
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
      breadcrumb(t("Developer Portal login"), () => this.hide());
      for (const key of ["clientId", "clientSecret", "callbackServerExternalAddress"]) $(`#${key}`).value = block?.[key] || "";
      $("#callbackServerPort").value = block?.callbackServerPort || 8582;
      this.go(1);
      this.preview();
      if (!$("#callbackServerExternalAddress").value) {
        try {
          const { primaryIp } = await request("server/info");
          if (primaryIp && !$("#callbackServerExternalAddress").value) $("#callbackServerExternalAddress").value = primaryIp;
          $("#callbackServerExternalAddress").placeholder = primaryIp || t("e.g. 192.168.1.100");
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
      breadcrumb(t("Authentication"), () => switchTab("devices"));
    },

    go(step) {
      this.step = step;
      [1, 2, 3].forEach((i) => $(`#content-${i}`).classList.toggle("hidden", i !== step));
      [...$("#wizard-steps").children].forEach((item, i) => {
        item.classList.toggle("current", i + 1 === step && step < 3);
        item.classList.toggle("done", i + 1 < step || step === 3);
        if (i + 1 === step && step < 3) item.setAttribute("aria-current", "step"); else item.removeAttribute("aria-current");
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
      $("#redirect-preview").textContent = `https://${address || t("<address>")}:${port || "8582"}`;
    },

    async proceed(button) {
      const config = this.form();
      const errors = $("#validation-errors");
      offerExplain($("#wizard-start-problem"), null);
      const port = $("#callbackServerPort");
      if (!isValidPort(config.callbackServerPort)) {
        port.classList.add("invalid");
        errors.textContent = t("Port must be between 1 and 65535");
        return;
      }
      port.classList.remove("invalid");
      await act(button, async () => {
        const validation = await request("config/validate", { method: "POST", body: config });
        if (!validation.valid) {
          errors.replaceChildren(...validation.errors.map((e) => el("div", { text: said(e) })));
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
          el("p", { class: "status-line error", text: `${said(result.message)}${result.callbackServerError ? ` (${said(result.callbackServerError)})` : ""}` }));
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
            if (result.success) await this.succeeded(said(result.message) || t("Authentication successful!"));
            else this.failed(t("Authentication failed: {error}", { error: said(result.error) || t("Unknown error") }));
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
      if (!url) return this.failed(t("Please paste the callback URL"));
      if (!url.includes("code=")) return this.failed(t("Invalid URL - must contain code parameter"));
      await act(button, async () => {
        const result = await request("auth/callback", { method: "POST", body: { callbackUrl: url } });
        if (result.success) await this.succeeded(said(result.message));
        else this.failed(t("Authentication failed: {error}", { error: said(result.message) || t("Unknown error") }));
      }, (message) => this.failed(t("Authentication failed: {error}", { error: message })));
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
        $("#success-message").textContent = t("{message} The settings could not be saved: {error}", { message, error: e.message });
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
        line.textContent = t("The plugin is not connected to Daikin yet: authenticate on the Authentication tab.");
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
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { text: t("Please authenticate first.") }),
            el("p", { class: "muted" }, ...around(t("Go to the {tab} tab to connect."), "tab", el("button", { actionIcon: "key", class: "link", text: t("Authentication"), onclick: () => switchTab("auth") })))));
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
          el("p", { class: "muted", text: t("Make sure you're authenticated and your Daikin devices are set up in the Onecta app.") })));
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
        box.replaceChildren(el("p", { class: "muted", text: t("No devices found. Authenticate first to see your devices.") }));
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
    "Authentication method": "Méthode d'authentification",
    "Developer Portal (200 API calls/day)": "Developer Portal (200 appels d'API/jour)",
    "Mobile App (3,000 API calls/day + WebSocket)": "App mobile (3 000 appels d'API/jour + WebSocket)",
    "Requires API credentials from the Daikin Developer Portal": "Nécessite des identifiants d'API du Daikin Developer Portal",
    "Use your Daikin Onecta account (same as mobile app)": "Utilisez votre compte Daikin Onecta (le même que l'app mobile)",
    "Status": "État",
    "Loading…": "Chargement…",
    "Mode": "Mode",
    "Expires": "Expire",
    "Test connection": "Tester la connexion",
    "Authenticate": "S'authentifier",
    "Configure credentials": "Configurer les identifiants",
    "Revoke access": "Révoquer l'accès",
    "Mobile App authentication": "Authentification App mobile",
    "Use your Daikin Onecta account (the same as the mobile app).": "Utilisez votre compte Daikin Onecta (le même que l'app mobile).",
    "3,000 API calls/day and real-time WebSocket updates.": "3 000 appels d'API par jour et des mises à jour en temps réel par WebSocket.",
    "Daikin account email": "E-mail du compte Daikin",
    "your@email.com": "vous@exemple.com",
    "Daikin account password": "Mot de passe du compte Daikin",
    "Enter your password": "Saisissez votre mot de passe",
    "Cancel": "Annuler",
    "Test & save credentials": "Tester et enregistrer les identifiants",
    "Configure": "Configurer",
    "Authorize": "Autoriser",
    "Complete": "Terminer",
    "Get your credentials from the": "Obtenez vos identifiants sur le",
    "Redirect URI:": "URI de redirection :",
    "Client ID": "Client ID",
    "Enter your Client ID": "Saisissez votre Client ID",
    "Client secret": "Client secret",
    "Enter your Client Secret": "Saisissez votre Client Secret",
    "Callback server address": "Adresse du serveur de rappel",
    "Auto-detecting…": "Détection…",
    "This machine's address as your browser reaches it (detected).": "L'adresse de cette machine telle que votre navigateur l'atteint (détectée).",
    "Callback server port": "Port du serveur de rappel",
    "Continue": "Continuer",
    "Open the Daikin login page and sign in with your account. This page follows along.": "Ouvrez la page de connexion Daikin et connectez-vous avec votre compte. Cette page suit le déroulement.",
    "Authorization URL": "URL d'autorisation",
    "If the button does not work, copy this URL into your browser.": "Si le bouton ne fonctionne pas, copiez cette URL dans votre navigateur.",
    "Back": "Retour",
    "Open Daikin login": "Ouvrir la connexion Daikin",
    "Waiting for authentication… Complete the login in the new window. This page will update automatically.": "En attente de l'authentification… Terminez la connexion dans la nouvelle fenêtre. Cette page se mettra à jour automatiquement.",
    "Manual entry (if the automatic redirect fails)": "Saisie manuelle (si la redirection automatique échoue)",
    "If you see an error page after the login, copy the full URL from your browser's address bar and paste it below.": "Si une page d'erreur s'affiche après la connexion, copiez l'URL complète depuis la barre d'adresse du navigateur et collez-la ci-dessous.",
    "Your browser also warns once about the callback server's self-signed certificate: that is expected.": "Votre navigateur avertit aussi une fois au sujet du certificat autosigné du serveur de rappel : c'est normal.",
    "Callback URL": "URL de rappel",
    "Paste the full URL from your browser (https://…?code=…)": "Collez l'URL complète depuis votre navigateur (https://…?code=…)",
    "The URL contains the parameter": "L'URL contient le paramètre",
    "Complete authentication": "Terminer l'authentification",
    "Authentication successful": "Authentification réussie",
    "Your Daikin Cloud account is now connected.": "Votre compte Daikin Cloud est maintenant connecté.",
    "Next steps": "Étapes suivantes",
    "Your settings are saved, and the plugin reloads with them.": "Vos réglages sont enregistrés et le plugin se recharge avec eux.",
    "Your Daikin devices appear in HomeKit within a minute.": "Vos appareils Daikin apparaissent dans HomeKit en moins d'une minute.",
    "Done": "Terminé",
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
    "Revoke access on the Authentication tab (or delete the token file in the plugin's folder), then authenticate again.": "Révoquez l'accès dans l'onglet Authentification (ou supprimez le fichier du jeton dans le dossier du plugin), puis authentifiez-vous à nouveau.",
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
    "Re-authenticate": "S'authentifier à nouveau",
    "Not connected": "Non connecté",
    "Authentication required": "Authentification requise",
    "Expires in {time}": "Expire dans {time}",
    "Test failed: {error}": "Échec du test : {error}",
    "Revoke access? The plugin stops until you authenticate again.": "Révoquer l'accès ? Le plugin s'arrête jusqu'à ce que vous vous authentifiiez à nouveau.",
    "Mobile App": "App mobile",
    "{n} requests/day": "{n} requêtes/jour",
    "The Daikin API limits you to {n} requests per day.": "L'API Daikin vous limite à {n} requêtes par jour.",
    "{n} (recommended)": "{n} (recommandé)",
    "Could not save the authentication method: {error}": "Impossible d'enregistrer la méthode d'authentification : {error}",
    "Mobile App credentials": "Identifiants App mobile",
    "Please enter email and password": "Saisissez l'adresse e-mail et le mot de passe",
    "Logging in to Daikin…": "Connexion à Daikin…",
    "Authentication failed": "Échec de l'authentification",
    "Success! Found {n} device. Rate limit: {quota}/day. The plugin reloads with the credentials.": "C'est fait ! {n} appareil trouvé. Limite : {quota}/jour. Le plugin se recharge avec les identifiants.",
    "Success! Found {n} devices. Rate limit: {quota}/day. The plugin reloads with the credentials.": "C'est fait ! {n} appareils trouvés. Limite : {quota}/jour. Le plugin se recharge avec les identifiants.",
    "Failed: {error}": "Échec : {error}",
    "Developer Portal login": "Connexion Developer Portal",
    "e.g. 192.168.1.100": "p. ex. 192.168.1.100",
    "<address>": "<adresse>",
    "Port must be between 1 and 65535": "Le port doit être compris entre 1 et 65535",
    "Authentication successful!": "Authentification réussie !",
    "Authentication failed: {error}": "Échec de l'authentification : {error}",
    "Unknown error": "Erreur inconnue",
    "Please paste the callback URL": "Collez l'URL de rappel",
    "Invalid URL - must contain code parameter": "URL non valide : elle doit contenir le paramètre code",
    "{message} The settings could not be saved: {error}": "{message} Les réglages n'ont pas pu être enregistrés : {error}",
    "The plugin is not connected to Daikin yet: authenticate on the Authentication tab.": "Le plugin n'est pas encore connecté à Daikin : authentifiez-vous dans l'onglet Authentification.",
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
    "Please authenticate first.": "Authentifiez-vous d'abord.",
    "Go to the {tab} tab to connect.": "Allez dans l'onglet {tab} pour vous connecter.",
    "No devices found": "Aucun appareil trouvé",
    "Make sure you're authenticated and your Daikin devices are set up in the Onecta app.": "Vérifiez que vous êtes authentifié et que vos appareils Daikin sont configurés dans l'app Onecta.",
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
    "No devices found. Authenticate first to see your devices.": "Aucun appareil trouvé. Authentifiez-vous d'abord pour voir vos appareils.",
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
    "Client ID and Client Secret are required": "Le Client ID et le Client Secret sont requis",
    "Callback Server Address is required": "L'adresse du serveur de rappel est requise",
    "The callback server bind address is {0} (this machine only), but the callback address is {1}, so Daikin's redirect could never reach it. Set \"Callback Server Bind Address\" to 0.0.0.0 (or this host's LAN IP) in Settings > Network, then start authentication again.": "Le serveur de rappel écoute sur {0} (cette machine uniquement), mais l'adresse de rappel est {1} : la redirection de Daikin ne pourrait jamais l'atteindre. Réglez « Adresse d'écoute du rappel OIDC » sur 0.0.0.0 (ou l'IP locale de cette machine) dans Réglages > Réseau, puis relancez l'authentification.",
    "Callback Server Port must be between 1 and 65535": "Le port du serveur de rappel doit être compris entre 1 et 65535",
    "Callback server is running. Authentication will complete automatically.": "Le serveur de rappel est en marche. L'authentification se terminera automatiquement.",
    "Could not start callback server. After authenticating, copy the full callback URL and paste it below.": "Impossible de démarrer le serveur de rappel. Après l'authentification, copiez l'URL de rappel complète et collez-la ci-dessous.",
    "Authorization request expired. Please try again.": "La demande d'autorisation a expiré. Réessayez.",
    "Missing code parameter": "Paramètre code manquant",
    "Invalid callback URL format": "Format d'URL de rappel non valide",
    "Authorization code is required": "Le code d'autorisation est requis",
    "No pending authorization. Please start the auth flow again.": "Aucune autorisation en cours. Relancez l'authentification.",
    "Invalid or missing state parameter. Please paste the full callback URL or start again.": "Paramètre state manquant ou non valide. Collez l'URL de rappel complète ou recommencez.",
    "Authentication successful! Save the settings to apply.": "Authentification réussie ! Enregistrez les réglages pour l'appliquer.",
    "Token exchange failed: {0}": "Échec de l'échange du jeton : {0}",
    "Email and password are required": "L'adresse e-mail et le mot de passe sont requis",
    "Not authenticated. Please authenticate first.": "Non authentifié. Authentifiez-vous d'abord.",
    "Connection successful! Found {0} device(s).": "Connexion réussie ! {0} appareil(s) trouvé(s).",
    "Connection failed: {0}": "Échec de la connexion : {0}",
    "Failed to fetch devices: {0}": "Impossible de récupérer les appareils : {0}",
    "Found {0} device(s).": "{0} appareil(s) trouvé(s).",
    "No data yet — the plugin records this after its next API call.": "Pas encore de données : le plugin les enregistre après son prochain appel d'API.",
    "Could not read rate limit status: invalid file contents": "Impossible de lire l'état de la limite : contenu du fichier non valide",
    "Client ID is required for Developer Portal mode": "Le Client ID est requis pour le mode Developer Portal",
    "Client Secret is required for Developer Portal mode": "Le Client Secret est requis pour le mode Developer Portal",
    "Callback Server Address is required for Developer Portal mode": "L'adresse du serveur de rappel est requise pour le mode Developer Portal",
    "Callback address cannot be localhost. Use your external IP or domain.": "L'adresse de rappel ne peut pas être localhost. Utilisez votre IP externe ou votre domaine.",
    "Invalid port number: {0}. Must be between 1 and 65535.": "Numéro de port non valide : {0}. Il doit être compris entre 1 et 65535.",
    "Rate limit exceeded": "Limite de requêtes dépassée",
    "Token expired and no refresh token available. Please re-authenticate.": "Jeton expiré et aucun jeton d'actualisation disponible. Authentifiez-vous à nouveau."
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
    "Authentication method": "Método de autenticación",
    "Developer Portal (200 API calls/day)": "Developer Portal (200 llamadas a la API/día)",
    "Mobile App (3,000 API calls/day + WebSocket)": "App móvil (3000 llamadas a la API/día + WebSocket)",
    "Requires API credentials from the Daikin Developer Portal": "Necesita credenciales de API del Daikin Developer Portal",
    "Use your Daikin Onecta account (same as mobile app)": "Usa tu cuenta de Daikin Onecta (la misma que la app móvil)",
    "Status": "Estado",
    "Loading…": "Cargando…",
    "Mode": "Modo",
    "Expires": "Caduca",
    "Test connection": "Probar la conexión",
    "Authenticate": "Autenticar",
    "Configure credentials": "Configurar credenciales",
    "Revoke access": "Revocar el acceso",
    "Mobile App authentication": "Autenticación de la app móvil",
    "Use your Daikin Onecta account (the same as the mobile app).": "Usa tu cuenta de Daikin Onecta (la misma que la app móvil).",
    "3,000 API calls/day and real-time WebSocket updates.": "3000 llamadas a la API al día y actualizaciones en tiempo real por WebSocket.",
    "Daikin account email": "Correo de la cuenta de Daikin",
    "your@email.com": "tu@email.com",
    "Daikin account password": "Contraseña de la cuenta de Daikin",
    "Enter your password": "Introduce tu contraseña",
    "Cancel": "Cancelar",
    "Test & save credentials": "Probar y guardar las credenciales",
    "Configure": "Configurar",
    "Authorize": "Autorizar",
    "Complete": "Completar",
    "Get your credentials from the": "Obtén tus credenciales en el",
    "Redirect URI:": "URI de redirección:",
    "Client ID": "Client ID",
    "Enter your Client ID": "Introduce tu Client ID",
    "Client secret": "Client secret",
    "Enter your Client Secret": "Introduce tu Client Secret",
    "Callback server address": "Dirección del servidor de retorno",
    "Auto-detecting…": "Detectando…",
    "This machine's address as your browser reaches it (detected).": "La dirección de este equipo tal como la alcanza tu navegador (detectada).",
    "Callback server port": "Puerto del servidor de retorno",
    "Continue": "Continuar",
    "Open the Daikin login page and sign in with your account. This page follows along.": "Abre la página de inicio de sesión de Daikin e inicia sesión con tu cuenta. Esta página sigue el proceso.",
    "Authorization URL": "URL de autorización",
    "If the button does not work, copy this URL into your browser.": "Si el botón no funciona, copia esta URL en tu navegador.",
    "Back": "Atrás",
    "Open Daikin login": "Abrir el inicio de sesión de Daikin",
    "Waiting for authentication… Complete the login in the new window. This page will update automatically.": "Esperando la autenticación… Completa el inicio de sesión en la nueva ventana. Esta página se actualizará automáticamente.",
    "Manual entry (if the automatic redirect fails)": "Entrada manual (si falla la redirección automática)",
    "If you see an error page after the login, copy the full URL from your browser's address bar and paste it below.": "Si ves una página de error tras iniciar sesión, copia la URL completa de la barra de direcciones del navegador y pégala abajo.",
    "Your browser also warns once about the callback server's self-signed certificate: that is expected.": "Tu navegador también avisará una vez del certificado autofirmado del servidor de retorno: es lo esperado.",
    "Callback URL": "URL de retorno",
    "Paste the full URL from your browser (https://…?code=…)": "Pega la URL completa de tu navegador (https://…?code=…)",
    "The URL contains the parameter": "La URL contiene el parámetro",
    "Complete authentication": "Completar la autenticación",
    "Authentication successful": "Autenticación correcta",
    "Your Daikin Cloud account is now connected.": "Tu cuenta de Daikin Cloud ya está conectada.",
    "Next steps": "Próximos pasos",
    "Your settings are saved, and the plugin reloads with them.": "Tus ajustes se han guardado y el plugin se recarga con ellos.",
    "Your Daikin devices appear in HomeKit within a minute.": "Tus dispositivos Daikin aparecen en HomeKit en menos de un minuto.",
    "Done": "Hecho",
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
    "Revoke access on the Authentication tab (or delete the token file in the plugin's folder), then authenticate again.": "Revoca el acceso en la pestaña Autenticación (o elimina el archivo del token en la carpeta del plugin) y vuelve a autenticarte.",
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
    "Re-authenticate": "Volver a autenticar",
    "Not connected": "No conectado",
    "Authentication required": "Autenticación necesaria",
    "Expires in {time}": "Caduca en {time}",
    "Test failed: {error}": "La prueba ha fallado: {error}",
    "Revoke access? The plugin stops until you authenticate again.": "¿Revocar el acceso? El plugin se detiene hasta que vuelvas a autenticarte.",
    "Mobile App": "App móvil",
    "{n} requests/day": "{n} solicitudes/día",
    "The Daikin API limits you to {n} requests per day.": "La API de Daikin te limita a {n} solicitudes al día.",
    "{n} (recommended)": "{n} (recomendado)",
    "Could not save the authentication method: {error}": "No se ha podido guardar el método de autenticación: {error}",
    "Mobile App credentials": "Credenciales de la app móvil",
    "Please enter email and password": "Introduce el correo y la contraseña",
    "Logging in to Daikin…": "Iniciando sesión en Daikin…",
    "Authentication failed": "Error de autenticación",
    "Success! Found {n} device. Rate limit: {quota}/day. The plugin reloads with the credentials.": "¡Listo! {n} dispositivo encontrado. Límite: {quota}/día. El plugin se recarga con las credenciales.",
    "Success! Found {n} devices. Rate limit: {quota}/day. The plugin reloads with the credentials.": "¡Listo! {n} dispositivos encontrados. Límite: {quota}/día. El plugin se recarga con las credenciales.",
    "Failed: {error}": "Error: {error}",
    "Developer Portal login": "Inicio de sesión en Developer Portal",
    "e.g. 192.168.1.100": "p. ej., 192.168.1.100",
    "<address>": "<dirección>",
    "Port must be between 1 and 65535": "El puerto debe estar entre 1 y 65535",
    "Authentication successful!": "¡Autenticación correcta!",
    "Authentication failed: {error}": "Error de autenticación: {error}",
    "Unknown error": "Error desconocido",
    "Please paste the callback URL": "Pega la URL de retorno",
    "Invalid URL - must contain code parameter": "URL no válida: debe contener el parámetro code",
    "{message} The settings could not be saved: {error}": "{message} No se han podido guardar los ajustes: {error}",
    "The plugin is not connected to Daikin yet: authenticate on the Authentication tab.": "El plugin aún no está conectado a Daikin: autentícate en la pestaña Autenticación.",
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
    "Please authenticate first.": "Primero debes autenticarte.",
    "Go to the {tab} tab to connect.": "Ve a la pestaña {tab} para conectarte.",
    "No devices found": "No se han encontrado dispositivos",
    "Make sure you're authenticated and your Daikin devices are set up in the Onecta app.": "Asegúrate de estar autenticado y de que tus dispositivos Daikin estén configurados en la app Onecta.",
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
    "No devices found. Authenticate first to see your devices.": "No se han encontrado dispositivos. Autentícate primero para ver tus dispositivos.",
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
    "Client ID and Client Secret are required": "El Client ID y el Client Secret son obligatorios",
    "Callback Server Address is required": "La dirección del servidor de retorno es obligatoria",
    "The callback server bind address is {0} (this machine only), but the callback address is {1}, so Daikin's redirect could never reach it. Set \"Callback Server Bind Address\" to 0.0.0.0 (or this host's LAN IP) in Settings > Network, then start authentication again.": "El servidor de retorno escucha en {0} (solo este equipo), pero la dirección de retorno es {1}, así que la redirección de Daikin nunca podría llegar a él. Pon «Dirección de escucha del retorno OIDC» en 0.0.0.0 (o la IP local de este equipo) en Ajustes > Red y vuelve a iniciar la autenticación.",
    "Callback Server Port must be between 1 and 65535": "El puerto del servidor de retorno debe estar entre 1 y 65535",
    "Callback server is running. Authentication will complete automatically.": "El servidor de retorno está en marcha. La autenticación se completará automáticamente.",
    "Could not start callback server. After authenticating, copy the full callback URL and paste it below.": "No se ha podido iniciar el servidor de retorno. Tras autenticarte, copia la URL de retorno completa y pégala abajo.",
    "Authorization request expired. Please try again.": "La solicitud de autorización ha caducado. Vuelve a intentarlo.",
    "Missing code parameter": "Falta el parámetro code",
    "Invalid callback URL format": "Formato de URL de retorno no válido",
    "Authorization code is required": "El código de autorización es obligatorio",
    "No pending authorization. Please start the auth flow again.": "No hay ninguna autorización pendiente. Vuelve a iniciar la autenticación.",
    "Invalid or missing state parameter. Please paste the full callback URL or start again.": "Parámetro state ausente o no válido. Pega la URL de retorno completa o vuelve a empezar.",
    "Authentication successful! Save the settings to apply.": "¡Autenticación correcta! Guarda los ajustes para aplicarla.",
    "Token exchange failed: {0}": "Error al intercambiar el token: {0}",
    "Email and password are required": "El correo y la contraseña son obligatorios",
    "Not authenticated. Please authenticate first.": "No autenticado. Primero debes autenticarte.",
    "Connection successful! Found {0} device(s).": "¡Conexión correcta! {0} dispositivo(s) encontrado(s).",
    "Connection failed: {0}": "Error de conexión: {0}",
    "Failed to fetch devices: {0}": "No se han podido obtener los dispositivos: {0}",
    "Found {0} device(s).": "{0} dispositivo(s) encontrado(s).",
    "No data yet — the plugin records this after its next API call.": "Aún no hay datos: el plugin los registra tras su próxima llamada a la API.",
    "Could not read rate limit status: invalid file contents": "No se ha podido leer el estado del límite: contenido del archivo no válido",
    "Client ID is required for Developer Portal mode": "El Client ID es obligatorio en el modo Developer Portal",
    "Client Secret is required for Developer Portal mode": "El Client Secret es obligatorio en el modo Developer Portal",
    "Callback Server Address is required for Developer Portal mode": "La dirección del servidor de retorno es obligatoria en el modo Developer Portal",
    "Callback address cannot be localhost. Use your external IP or domain.": "La dirección de retorno no puede ser localhost. Usa tu IP externa o tu dominio.",
    "Invalid port number: {0}. Must be between 1 and 65535.": "Número de puerto no válido: {0}. Debe estar entre 1 y 65535.",
    "Rate limit exceeded": "Límite de solicitudes superado",
    "Token expired and no refresh token available. Please re-authenticate.": "Token caducado y sin token de renovación. Vuelve a autenticarte."
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
    "Authentication method": "Método de autenticação",
    "Developer Portal (200 API calls/day)": "Developer Portal (200 chamadas à API/dia)",
    "Mobile App (3,000 API calls/day + WebSocket)": "App móvel (3000 chamadas à API/dia + WebSocket)",
    "Requires API credentials from the Daikin Developer Portal": "Requer credenciais de API do Daikin Developer Portal",
    "Use your Daikin Onecta account (same as mobile app)": "Use a conta Daikin Onecta (a mesma da app móvel)",
    "Status": "Estado",
    "Loading…": "A carregar…",
    "Mode": "Modo",
    "Expires": "Expira",
    "Test connection": "Testar a ligação",
    "Authenticate": "Autenticar",
    "Configure credentials": "Configurar credenciais",
    "Revoke access": "Revogar o acesso",
    "Mobile App authentication": "Autenticação da App móvel",
    "Use your Daikin Onecta account (the same as the mobile app).": "Use a conta Daikin Onecta (a mesma da app móvel).",
    "3,000 API calls/day and real-time WebSocket updates.": "3000 chamadas à API por dia e atualizações em tempo real por WebSocket.",
    "Daikin account email": "E-mail da conta Daikin",
    "your@email.com": "nome@email.com",
    "Daikin account password": "Palavra-passe da conta Daikin",
    "Enter your password": "Introduza a palavra-passe",
    "Cancel": "Cancelar",
    "Test & save credentials": "Testar e guardar as credenciais",
    "Configure": "Configurar",
    "Authorize": "Autorizar",
    "Complete": "Concluir",
    "Get your credentials from the": "Obtenha as credenciais no",
    "Redirect URI:": "URI de redirecionamento:",
    "Client ID": "Client ID",
    "Enter your Client ID": "Introduza o Client ID",
    "Client secret": "Client secret",
    "Enter your Client Secret": "Introduza o Client Secret",
    "Callback server address": "Endereço do servidor de retorno",
    "Auto-detecting…": "A detetar…",
    "This machine's address as your browser reaches it (detected).": "O endereço deste computador tal como o navegador o alcança (detetado).",
    "Callback server port": "Porta do servidor de retorno",
    "Continue": "Continuar",
    "Open the Daikin login page and sign in with your account. This page follows along.": "Abra a página de início de sessão da Daikin e inicie sessão com a conta. Esta página acompanha o processo.",
    "Authorization URL": "URL de autorização",
    "If the button does not work, copy this URL into your browser.": "Se o botão não funcionar, copie este URL para o navegador.",
    "Back": "Voltar",
    "Open Daikin login": "Abrir o início de sessão da Daikin",
    "Waiting for authentication… Complete the login in the new window. This page will update automatically.": "A aguardar a autenticação… Conclua o início de sessão na nova janela. Esta página será atualizada automaticamente.",
    "Manual entry (if the automatic redirect fails)": "Introdução manual (se o redirecionamento automático falhar)",
    "If you see an error page after the login, copy the full URL from your browser's address bar and paste it below.": "Se aparecer uma página de erro depois do início de sessão, copie o URL completo da barra de endereço do navegador e cole-o abaixo.",
    "Your browser also warns once about the callback server's self-signed certificate: that is expected.": "O navegador também avisa uma vez sobre o certificado autoassinado do servidor de retorno: é o esperado.",
    "Callback URL": "URL de retorno",
    "Paste the full URL from your browser (https://…?code=…)": "Cole o URL completo do navegador (https://…?code=…)",
    "The URL contains the parameter": "O URL contém o parâmetro",
    "Complete authentication": "Concluir a autenticação",
    "Authentication successful": "Autenticação concluída",
    "Your Daikin Cloud account is now connected.": "A conta Daikin Cloud está agora ligada.",
    "Next steps": "Próximos passos",
    "Your settings are saved, and the plugin reloads with them.": "As definições foram guardadas e o plugin recarrega com elas.",
    "Your Daikin devices appear in HomeKit within a minute.": "Os dispositivos Daikin aparecem no HomeKit em menos de um minuto.",
    "Done": "Concluído",
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
    "Revoke access on the Authentication tab (or delete the token file in the plugin's folder), then authenticate again.": "Revogue o acesso no separador Autenticação (ou apague o ficheiro do token na pasta do plugin) e autentique-se novamente.",
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
    "Re-authenticate": "Autenticar novamente",
    "Not connected": "Não ligado",
    "Authentication required": "Autenticação necessária",
    "Expires in {time}": "Expira dentro de {time}",
    "Test failed: {error}": "O teste falhou: {error}",
    "Revoke access? The plugin stops until you authenticate again.": "Revogar o acesso? O plugin para até nova autenticação.",
    "Mobile App": "App móvel",
    "{n} requests/day": "{n} pedidos/dia",
    "The Daikin API limits you to {n} requests per day.": "A API da Daikin está limitada a {n} pedidos por dia.",
    "{n} (recommended)": "{n} (recomendado)",
    "Could not save the authentication method: {error}": "Não foi possível guardar o método de autenticação: {error}",
    "Mobile App credentials": "Credenciais da App móvel",
    "Please enter email and password": "Introduza o e-mail e a palavra-passe",
    "Logging in to Daikin…": "A iniciar sessão na Daikin…",
    "Authentication failed": "Falha na autenticação",
    "Success! Found {n} device. Rate limit: {quota}/day. The plugin reloads with the credentials.": "Concluído! {n} dispositivo encontrado. Limite: {quota}/dia. O plugin recarrega com as credenciais.",
    "Success! Found {n} devices. Rate limit: {quota}/day. The plugin reloads with the credentials.": "Concluído! {n} dispositivos encontrados. Limite: {quota}/dia. O plugin recarrega com as credenciais.",
    "Failed: {error}": "Falhou: {error}",
    "Developer Portal login": "Início de sessão no Developer Portal",
    "e.g. 192.168.1.100": "p. ex. 192.168.1.100",
    "<address>": "<endereço>",
    "Port must be between 1 and 65535": "A porta tem de estar entre 1 e 65535",
    "Authentication successful!": "Autenticação concluída!",
    "Authentication failed: {error}": "Falha na autenticação: {error}",
    "Unknown error": "Erro desconhecido",
    "Please paste the callback URL": "Cole o URL de retorno",
    "Invalid URL - must contain code parameter": "URL inválido: tem de conter o parâmetro code",
    "{message} The settings could not be saved: {error}": "{message} Não foi possível guardar as definições: {error}",
    "The plugin is not connected to Daikin yet: authenticate on the Authentication tab.": "O plugin ainda não está ligado à Daikin: autentique-se no separador Autenticação.",
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
    "Please authenticate first.": "Autentique-se primeiro.",
    "Go to the {tab} tab to connect.": "Aceda ao separador {tab} para ligar.",
    "No devices found": "Nenhum dispositivo encontrado",
    "Make sure you're authenticated and your Daikin devices are set up in the Onecta app.": "Confirme que está autenticado e que os dispositivos Daikin estão configurados na app Onecta.",
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
    "No devices found. Authenticate first to see your devices.": "Nenhum dispositivo encontrado. Autentique-se primeiro para ver os dispositivos.",
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
    "Client ID and Client Secret are required": "O Client ID e o Client Secret são obrigatórios",
    "Callback Server Address is required": "O endereço do servidor de retorno é obrigatório",
    "The callback server bind address is {0} (this machine only), but the callback address is {1}, so Daikin's redirect could never reach it. Set \"Callback Server Bind Address\" to 0.0.0.0 (or this host's LAN IP) in Settings > Network, then start authentication again.": "O servidor de retorno está à escuta em {0} (apenas este computador), mas o endereço de retorno é {1}, pelo que o redirecionamento da Daikin nunca o conseguiria alcançar. Defina «Endereço de escuta do retorno OIDC» como 0.0.0.0 (ou o IP local deste computador) em Definições > Rede e inicie novamente a autenticação.",
    "Callback Server Port must be between 1 and 65535": "A porta do servidor de retorno tem de estar entre 1 e 65535",
    "Callback server is running. Authentication will complete automatically.": "O servidor de retorno está em execução. A autenticação será concluída automaticamente.",
    "Could not start callback server. After authenticating, copy the full callback URL and paste it below.": "Não foi possível iniciar o servidor de retorno. Depois de autenticar, copie o URL de retorno completo e cole-o abaixo.",
    "Authorization request expired. Please try again.": "O pedido de autorização expirou. Tente novamente.",
    "Missing code parameter": "Falta o parâmetro code",
    "Invalid callback URL format": "Formato de URL de retorno inválido",
    "Authorization code is required": "O código de autorização é obrigatório",
    "No pending authorization. Please start the auth flow again.": "Nenhuma autorização pendente. Inicie novamente a autenticação.",
    "Invalid or missing state parameter. Please paste the full callback URL or start again.": "Parâmetro state em falta ou inválido. Cole o URL de retorno completo ou recomece.",
    "Authentication successful! Save the settings to apply.": "Autenticação concluída! Guarde as definições para as aplicar.",
    "Token exchange failed: {0}": "Falha na troca do token: {0}",
    "Email and password are required": "O e-mail e a palavra-passe são obrigatórios",
    "Not authenticated. Please authenticate first.": "Não autenticado. Autentique-se primeiro.",
    "Connection successful! Found {0} device(s).": "Ligação bem-sucedida! {0} dispositivo(s) encontrado(s).",
    "Connection failed: {0}": "Falha na ligação: {0}",
    "Failed to fetch devices: {0}": "Não foi possível obter os dispositivos: {0}",
    "Found {0} device(s).": "{0} dispositivo(s) encontrado(s).",
    "No data yet — the plugin records this after its next API call.": "Ainda sem dados: o plugin regista-os após a próxima chamada à API.",
    "Could not read rate limit status: invalid file contents": "Não foi possível ler o estado do limite: conteúdo do ficheiro inválido",
    "Client ID is required for Developer Portal mode": "O Client ID é obrigatório no modo Developer Portal",
    "Client Secret is required for Developer Portal mode": "O Client Secret é obrigatório no modo Developer Portal",
    "Callback Server Address is required for Developer Portal mode": "O endereço do servidor de retorno é obrigatório no modo Developer Portal",
    "Callback address cannot be localhost. Use your external IP or domain.": "O endereço de retorno não pode ser localhost. Use o IP externo ou o domínio.",
    "Invalid port number: {0}. Must be between 1 and 65535.": "Número de porta inválido: {0}. Tem de estar entre 1 e 65535.",
    "Rate limit exceeded": "Limite de pedidos excedido",
    "Token expired and no refresh token available. Please re-authenticate.": "Token expirado e sem token de atualização disponível. Autentique-se novamente."
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
    <div class="card">
      <label class="field"><span class="field-title" data-i18n>Authentication method</span>
        <select id="authMode">
          <option value="developer_portal" data-i18n>Developer Portal (200 API calls/day)</option>
          <option value="mobile_app" data-i18n>Mobile App (3,000 API calls/day + WebSocket)</option>
        </select>
        <span class="help" id="auth-mode-hint" data-i18n>Requires API credentials from the Daikin Developer Portal</span></label>
    </div>

    <div class="card" id="auth-status-card">
      <div class="facts">
        <div class="fact wide-on-phone"><span data-i18n>Status</span><b id="auth-status" data-i18n>Loading…</b></div>
        <div class="fact"><span data-i18n>Mode</span><b id="auth-mode-text">Developer Portal</b></div>
        <div class="fact hidden" id="expires-row"><span data-i18n>Expires</span><b id="auth-token-expires">—</b></div>
      </div>
      <div class="actions">
        <button id="btn-test" data-i18n data-action-icon="send">Test connection</button>
        <button id="btn-authenticate" class="primary" data-i18n>Authenticate</button>
        <button id="btn-authenticate-mobile" class="primary hidden" data-i18n data-action-icon="sliders">Configure credentials</button>
        <button id="btn-revoke" class="danger hidden" data-i18n>Revoke access</button>
      </div>
      <p id="test-result" class="status-line" role="status" aria-live="polite"></p>
      <div id="test-problem"></div>
    </div>

    <div class="card hidden" id="mobile-auth-form">
      <div class="info-box"><strong data-i18n>Mobile App authentication</strong><br><span data-i18n>Use your Daikin Onecta account (the same as the mobile app).</span><br><span class="muted" data-i18n>3,000 API calls/day and real-time WebSocket updates.</span></div>
      <div class="fields">
        <label class="field"><span class="field-title" data-i18n>Daikin account email</span><input type="email" id="daikinEmail" placeholder="your@email.com" autocomplete="username" data-i18n></label>
        <label class="field"><span class="field-title" data-i18n>Daikin account password</span><input type="password" id="daikinPassword" placeholder="Enter your password" autocomplete="current-password" data-i18n></label>
      </div>
      <p id="mobile-auth-result" class="status-line" role="status" aria-live="polite"></p>
      <div id="mobile-auth-problem"></div>
      <div class="actions end"><button id="btn-mobile-cancel" data-i18n data-action-icon="close">Cancel</button><button id="btn-test-mobile-auth" class="primary" data-i18n>Test & save credentials</button></div>
    </div>

    <div class="card hidden" id="wizard">
      <ol class="steps" id="wizard-steps">
        <li data-n="1" data-i18n>Configure</li><li data-n="2" data-i18n>Authorize</li><li data-n="3" data-i18n>Complete</li>
      </ol>

      <div class="step" id="content-1">
        <div class="info-box"><span data-i18n>Get your credentials from the</span> <a href="https://developer.cloud.daikineurope.com/" target="_blank" rel="noopener noreferrer">Daikin Developer Portal</a>.
          <br><span class="muted"><strong data-i18n>Redirect URI:</strong> <code id="redirect-preview">https://&lt;address&gt;:&lt;port&gt;</code></span></div>
        <div class="fields">
          <label class="field"><span class="field-title" data-i18n>Client ID</span><input type="text" id="clientId" placeholder="Enter your Client ID" spellcheck="false" autocomplete="off" data-i18n></label>
          <label class="field"><span class="field-title" data-i18n>Client secret</span><input type="password" id="clientSecret" placeholder="Enter your Client Secret" autocomplete="off" data-i18n></label>
          <label class="field"><span class="field-title" data-i18n>Callback server address</span><input type="text" id="callbackServerExternalAddress" placeholder="Auto-detecting…" spellcheck="false" autocomplete="off" data-i18n>
            <span class="help" data-i18n>This machine's address as your browser reaches it (detected).</span></label>
          <label class="field"><span class="field-title" data-i18n>Callback server port</span><input type="number" id="callbackServerPort" placeholder="8582" min="1" max="65535"></label>
        </div>
        <div id="validation-errors" class="error-list"></div>
        <div id="wizard-start-problem"></div>
        <div class="actions end"><button id="btn-wizard-cancel" data-i18n data-action-icon="close">Cancel</button><button id="btn-wizard-continue" class="primary" data-i18n data-action-icon="check">Continue</button></div>
      </div>

      <div class="step hidden" id="content-2">
        <p data-i18n>Open the Daikin login page and sign in with your account. This page follows along.</p>
        <div id="auth-url-container" class="hidden">
          <span class="field-title" data-i18n>Authorization URL</span>
          <div class="url-box mono" id="auth-url"></div>
          <span class="help" data-i18n>If the button does not work, copy this URL into your browser.</span>
        </div>
        <div class="actions"><button id="btn-wizard-back" data-i18n data-action-icon="restore">Back</button><button id="btn-open-auth" class="primary" data-i18n>Open Daikin login</button></div>
        <div id="wizard-auth-problem"></div>
        <p id="callback-server-status" class="status-line waiting hidden" role="status" aria-live="polite" data-i18n>Waiting for authentication… Complete the login in the new window. This page will update automatically.</p>
        <details id="manual-callback">
          <summary data-i18n>Manual entry (if the automatic redirect fails)</summary>
          <p class="warn-box"><span data-i18n>If you see an error page after the login, copy the full URL from your browser's address bar and paste it below.</span> <span data-i18n>Your browser also warns once about the callback server's self-signed certificate: that is expected.</span></p>
          <label class="field"><span class="field-title" data-i18n>Callback URL</span><input type="text" id="callbackUrl" placeholder="Paste the full URL from your browser (https://…?code=…)" spellcheck="false" autocomplete="off" data-i18n>
            <span class="help"><span data-i18n>The URL contains the parameter</span> <code>?code=</code></span></label>
          <div class="actions"><button id="btn-submit-callback" class="primary" data-i18n>Complete authentication</button></div>
        </details>
      </div>

      <div class="step hidden" id="content-3">
        <div class="success"><span class="check" aria-hidden="true">✓</span><h3 data-i18n>Authentication successful</h3><p id="success-message" class="muted" data-i18n>Your Daikin Cloud account is now connected.</p></div>
        <div class="info-box"><strong data-i18n>Next steps</strong>
          <ol><li data-i18n>Your settings are saved, and the plugin reloads with them.</li><li data-i18n>Your Daikin devices appear in HomeKit within a minute.</li></ol></div>
        <div class="actions end"><button id="btn-wizard-done" class="primary" data-i18n data-action-icon="check">Done</button></div>
      </div>
    </div>
  </section>

  <!-- Help -->
  <section class="tab-pane hidden" id="tab-help" role="tabpanel">
    <div class="section-head"><h2 data-i18n>Help & information</h2></div>
    <div class="card">
      <div class="item-head"><strong data-i18n>API rate limit</strong><button id="btn-rate-limit" data-i18n>Check</button></div>
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
        <dt data-i18n>Token expired or invalid</dt><dd data-i18n>Revoke access on the Authentication tab (or delete the token file in the plugin's folder), then authenticate again.</dd>
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
