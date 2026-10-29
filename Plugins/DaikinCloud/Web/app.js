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
