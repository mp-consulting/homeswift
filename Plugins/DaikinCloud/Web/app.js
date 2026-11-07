// The Daikin Cloud page, after the Homebridge plugin's settings UI: the devices the account has; the sign-in's
// state, its connection test and signing out (signing in is Setup's, on Add accessories, which the page leads to);
// and help, with the quota the plugin saw on its last call. It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): the plugin's open its Settings page, and a device's its own there.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, act, poll } = homeswift;
  const { t, tn } = HomeswiftI18n;
  /// Text from the plugin (a message in an answer), in the page's language when the catalog knows it.
  const said = (text) => HomeswiftI18n.message(text);

  const OPERATION_MODE_LABELS = { auto: t("Auto"), cooling: t("Cooling"), heating: t("Heating"), dry: t("Dry"), fanOnly: t("Fan only") };
  const numberFormat = new Intl.NumberFormat(HomeswiftI18n.numberLocale);
  const formatNumber = (value) => (value !== null && value !== undefined && value !== "" && Number.isFinite(Number(value)) ? numberFormat.format(Number(value)) : String(value ?? ""));
  const operationModeLabel = (mode) => (mode ? OPERATION_MODE_LABELS[mode] || String(mode).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : "");
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
    const session = auth.status?.session;
    return [
      extra,
      `Authentication method: ${authMode.current}.`,
      session?.pollMinutes ? `Update interval: ${session.pollMinutes} minutes.` : "",
      authMode.current === "mobile_app" && session?.running ? `WebSocket: ${session.webSocket ? "connected" : "not connected"}.` : "",
    ].filter(Boolean).join(" ");
  }
  /// Puts an Explain button in `slot` for `message`, or empties it.
  function offerExplain(slot, message, context, device) {
    slot.replaceChildren(message ? explain({ error: message, context: assistantContext(context), device }) : "");
  }

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there (its Accessory Settings).

  const settingsOf = (deviceID) => homeswift.accessorySettings(`DaikinCloud:${deviceID}`);

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
        const mode = status.session?.mode ?? status.authMode;
        if (mode) authMode.current = mode;
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
        await request("auth/revoke", { method: "POST", body: {} });
        await this.load();
        devices.load();
      });
    },
  };
  $("#btn-test").addEventListener("click", (event) => auth.test(event.currentTarget));
  $("#btn-revoke").addEventListener("click", (event) => auth.revoke(event.currentTarget));

  // MARK: How the account signs in: the running instance's `authMode`, else the token's; Setup chooses it.

  const authMode = {
    current: "developer_portal",

    render() {
      const mobile = this.current === "mobile_app";
      $("#auth-mode-text").textContent = mobile ? t("Mobile App") : "Developer Portal";
      const daily = mobile ? 3000 : 200;
      $("#rate-limit-display").textContent = t("{n} requests/day", { n: daily });
      $("#rate-limit-info").textContent = t("The Daikin API limits you to {n} requests per day.", { n: daily });
    },
  };

  // MARK: Devices: one request at a time; Refresh skips the plugin's five-minute cache.

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
      const fetchedAt = result.fetchedAt ? HomeswiftI18n.formatDate(new Date(result.fetchedAt), { hour: "numeric", minute: "2-digit", second: "2-digit" }) : "";
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
      const hidden = device.excluded === true;
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
        hidden ? el("p", { class: "muted note", text: t("Excluded: not in HomeKit. Its settings bring it back.") }) : null,
        problem ? explain({
          error: problem,
          context: assistantContext("The user is looking at the device list of the Daikin Cloud plugin's page."),
          device: assistantDevice(device),
        }) : null,
        el("div", { class: "actions" }, el("a", { class: "button", href: settingsOf(device.id), actionIcon: "gear", text: t("Settings") })));
    },
  };
  $("#btn-refresh-devices").addEventListener("click", (event) => act(event.currentTarget, () => devices.load({ refresh: true })));

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
        const parts = [t("as of {time}", { time: HomeswiftI18n.formatDate(new Date(result.updatedAt), { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit" }) })];
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
    authMode.render();
    // The token renews itself; the page follows.
    poll(() => auth.load(), 60000);
    devices.load();
  })();
})();
