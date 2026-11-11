// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DaikinCloudPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Daikin Cloud page, after the Homebridge plugin's settings UI: the devices the account has; the sign-in's
// state, its connection test and signing out (signing in is Setup's, on Add accessories, which the page leads to);
// and help, with the quota the plugin saw on its last call. It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): device settings open in the shared settings drawer over this page.
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

  // MARK: Accessory Settings: the shared drawer, with a page address for opening in a new tab.

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
        el("div", { class: "actions" }, el("a", { class: "button", href: settingsOf(device.id), actionIcon: "gear", text: t("Settings"),
          onclick: (event) => {
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
            event.preventDefault();
            homeswift.openAccessorySettings({
              accessoryID: `DaikinCloud:${device.id}`, name: device.name, glyph: "thermo", trigger: event.currentTarget,
              after: (changed) => { if (changed) devices.load(); },
            });
          },
        })));
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

"""#),
        "daikin.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Daikin Cloud page's own pieces, on the UI's materials: tabs like the Homebridge plugin's settings page,
   a card per unit with its state as facts, and the sign-in's state. */

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
  .tab-pane, .unit { animation: none; }
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
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Révoquez l'accès dans l'onglet Authentification, puis reconnectez-vous dans Ajouter des accessoires.",
    "Excluded: not in HomeKit. Its settings bring it back.": "Exclu : absent de HomeKit. Ses réglages le font revenir.",
    "Check the log, check the device in the Onecta app, and check whether it is Excluded in its settings.": "Consultez le journal, vérifiez l'appareil dans l'app Onecta, et regardez s'il est exclu dans ses réglages."
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
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Revoca el acceso en la pestaña Autenticación y vuelve a iniciar sesión en Añadir accesorios.",
    "Excluded: not in HomeKit. Its settings bring it back.": "Excluido: no está en HomeKit. Sus ajustes lo recuperan.",
    "Check the log, check the device in the Onecta app, and check whether it is Excluded in its settings.": "Consulta el registro, revisa el dispositivo en la app Onecta y comprueba si está excluido en sus ajustes."
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
    "Revoke access on the Authentication tab, then sign in again on Add accessories.": "Revogue o acesso no separador Autenticação e inicie sessão de novo em Adicionar acessórios.",
    "Excluded: not in HomeKit. Its settings bring it back.": "Excluído: não está no HomeKit. As suas definições trazem-no de volta.",
    "Check the log, check the device in the Onecta app, and check whether it is Excluded in its settings.": "Consulte o registo, verifique o dispositivo na app Onecta e veja se está excluído nas suas definições."
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
        <dt data-i18n>Device not appearing</dt><dd data-i18n>Check the log, check the device in the Onecta app, and check whether it is Excluded in its settings.</dd>
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
