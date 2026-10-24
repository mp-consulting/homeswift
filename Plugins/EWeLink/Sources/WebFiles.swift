// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page, after the Homebridge plugin's settings UI: connect the account (or reuse the plugin's
// session), the account's devices with their LAN and RF details (an mDNS scan runs while the cloud answers),
// the connection settings, and saving them into this instance's block, which reloads the plugin. The session
// stays in the plugin: the browser never sees a token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, name, explain, api, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const steps = { login: $("#step-login"), devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  let devices = [];
  let region = null;
  let config = {};
  // Account fields typed in this page, saved with the settings.
  let pendingAccount = null;

  // MARK: config.json: this instance's block, read and written through the signed-in UI.

  async function readBlock() {
    config = (await homeswift.readBlock()) || {};
    return config;
  }

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${config.mode || "auto"}.`,
    config.countryCode ? `Account country code: ${config.countryCode}.` : "", region ? `API region: ${region}.` : ""].filter(Boolean).join(" ");

  function showProblem(container, message, context) {
    container.classList.remove("hidden");
    container.replaceChildren(el("p", { text: message }), explain({ error: message, context: assistantContext(context) }));
  }

  function clearProblem(container) {
    container.classList.add("hidden");
    container.replaceChildren();
  }

  /// Why a device needs attention, or null.
  function deviceProblem(device) {
    if (!device.online) return "The eWeLink cloud reports this device as offline.";
    if (device.lanEnabled && !device.lanIp) return "LAN control is enabled for this device, but it was not found on the local network (no IP address over mDNS).";
    return null;
  }

  // MARK: Devices

  function deviceRow(device) {
    const badges = [];
    if (device.isRfSubdevice) badges.push(el("span", { class: "pill rf", text: "RF" }));
    if (device.lanEnabled && device.lanIp) badges.push(el("span", { class: "pill lan", text: t("LAN: {address}", { address: device.lanIp }) }));
    else if (device.lanEnabled) badges.push(el("span", { class: "pill lan-warn", text: t("LAN: No IP") }));
    else badges.push(el("span", { class: "pill", text: t("Cloud") }));
    badges.push(el("span", { class: `pill status ${device.online ? "on" : "away"}`, text: device.online ? t("Online") : t("Offline") }));
    const problem = deviceProblem(device);
    return el("li", { class: `device ${device.isRfSubdevice ? "rf" : ""}` },
      el("div", { class: "info" },
        el("div", { class: "name", text: device.name }),
        el("div", { class: "meta" },
          el("span", { class: "mono", text: t("ID: {id}", { id: device.deviceId }) }),
          el("span", { text: t("{brand} — {model} (UIID: {uiid})", { brand: device.brand || t("Unknown"), model: device.model || t("Unknown"), uiid: device.uiid != null ? String(device.uiid) : t("N/A") }) })),
        device.buttons && device.buttons.length ? el("div", { class: "buttons" }, device.buttons.map((button) => el("span", { text: button }))) : null),
      el("div", { class: "badges" }, badges),
      problem ? explain({
        error: problem,
        context: assistantContext("The user is looking at the device list of the eWeLink plugin settings."),
        device: {
          name: device.name, deviceId: device.deviceId, brand: device.brand, model: device.model, uiid: device.uiid, online: !!device.online,
          lanEnabled: !!device.lanEnabled, lanAddressFound: !!device.lanIp, rfSubdevice: !!device.isRfSubdevice, parentDeviceId: device.parentDeviceId,
        },
      }) : null);
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#devices").replaceChildren(...(devices.length ? devices.map(deviceRow)
      : [el("li", { class: "empty" }, el("p", { text: t("No devices found") }), el("p", { class: "muted", text: t("Connect your eWeLink account and click Refresh.") }))]));
  }

  async function loadDevices() {
    const button = $("#refresh");
    await act(button, async () => {
      clearProblem($("#devices-problem"));
      try {
        const answer = await request("devices");
        devices = answer.devices || [];
        renderDevices();
      } catch (e) {
        showProblem($("#devices-problem"), e.message || t("Failed to load devices"),
          "Loading the device list from the eWeLink cloud (plus a 3 second mDNS LAN scan) failed in the plugin settings.");
      }
    });
    await loadStatus();
  }

  async function loadStatus() {
    try {
      const status = await request("status");
      $("#status").replaceChildren(
        fact(t("Cloud"), status.websocket ? t("Connected") : status.retrying ? t("Retrying") : status.initialized ? t("Reconnecting") : t("Not connected")),
        fact(t("On the LAN"), tn("{n} device", "{n} devices", status.lanDevices ?? 0)),
        fact(t("In HomeKit"), tn("{n} accessory", "{n} accessories", status.accessories ?? 0)));
    } catch { $("#status").replaceChildren(); }
  }

  // MARK: Settings

  function prefillSettings() {
    $("#mode").value = config.mode || "auto";
    $("#debug").checked = !!config.debug;
    $("#offline-as-off").checked = !!config.offlineAsOff;
  }

  function prefillLogin() {
    if (config.username) $("#username").value = config.username;
    if (config.password) $("#password").value = config.password;
    if (config.countryCode) $("#countryCode").value = config.countryCode;
  }

  async function saveConfiguration(button) {
    await act(button, async () => {
      clearProblem($("#save-problem"));
      try {
        let block;
        const result = await homeswift.updateBlock((current) => {
          block = { ...current, ...(pendingAccount || {}), platform: "eWeLink", name: current.name || name || "eWeLink", mode: $("#mode").value };
          if ($("#debug").checked) block.debug = true; else delete block.debug;
          if ($("#offline-as-off").checked) block.offlineAsOff = true; else delete block.offlineAsOff;
          return block;
        });
        config = block;
        pendingAccount = null;
        const pending = result.restartNeeded || [];
        $("#restart").classList.toggle("hidden", pending.length === 0);
        $("#complete-text").replaceChildren(el("strong", { text: t("All done!") }), " ", pending.length
          ? t("The configuration is saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.map((change) => HomeswiftI18n.message(change)).join("; ") })
          : t("The configuration is saved and the plugin reloaded with it."));
        $("#restart-status").textContent = "";
        showStep("complete");
      } catch (e) {
        showProblem($("#save-problem"), e.message || t("Failed to save configuration"), "Saving this instance's block of config.json from the eWeLink plugin settings failed.");
      }
    });
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    $("#restart-status").textContent = t("Restarting…");
    let back = false;
    for (let tries = 0; tries < 60 && !back; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("status"); back = true; } catch { /* not back yet */ }
    }
    $("#restart-status").textContent = back ? t("Homeswift restarted.") : t("Homeswift has not answered for a minute: check its log, then reload this page.");
    $("#restart").classList.toggle("hidden", back);
  }

  // MARK: Events

  $("#login").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("#connect");
    if (button.disabled) return;
    const username = $("#username").value.trim();
    const password = $("#password").value;
    const countryCode = $("#countryCode").value;
    if (!username || !password) {
      showProblem($("#login-problem"), t("Please enter your username and password"), "The login form of the eWeLink plugin settings was submitted empty.");
      return;
    }
    await act(button, async () => {
      clearProblem($("#login-problem"));
      try {
        const answer = await request("login", { method: "POST", body: { username, password, countryCode } });
        region = answer.region;
        pendingAccount = { username, password, countryCode };
        showStep("devices");
        await loadDevices();
      } catch (e) {
        showProblem($("#login-problem"), e.message || t("Login failed"),
          `Logging in to the eWeLink cloud from the plugin settings failed. Selected country code: ${countryCode}.`);
      }
    });
  });

  $("#new-login").addEventListener("click", () => {
    $("#session").classList.add("hidden");
    showStep("login");
  });

  const tabs = [["#tab-devices", "#pane-devices"], ["#tab-settings", "#pane-settings"]];
  for (const [tab, pane] of tabs) {
    $(tab).addEventListener("click", () => {
      for (const [otherTab, otherPane] of tabs) {
        const selected = otherTab === tab;
        $(otherTab).classList.toggle("on", selected);
        $(otherTab).setAttribute("aria-selected", String(selected));
        $(otherPane).classList.toggle("hidden", !selected);
      }
    });
  }

  $("#refresh").addEventListener("click", loadDevices);
  $("#save").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#save-settings").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#back").addEventListener("click", () => { showStep("devices"); loadDevices(); });
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, restart).catch((e) => alert(e.message)));

  // MARK: Config changes made elsewhere (the Expert editor, another tab, the Assistant), as the Homebridge page's
  // configChanged: the web UI sends no such event, so the block is read again whenever the page comes back into
  // view, and the settings are filled in again only when it changed. Unsaved choices stay otherwise.

  /// JSON with the keys sorted, so the same block written in another order compares equal.
  const canonical = (value) => JSON.stringify(value, (_, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : v);

  async function followConfigChanges() {
    if (document.hidden) return;
    const before = canonical(config);
    let fresh;
    try { fresh = (await homeswift.readBlock()) || {}; } catch { return; }
    if (canonical(fresh) === before) return;
    config = fresh;
    prefillSettings();
  }
  document.addEventListener("visibilitychange", followConfigChanges);
  window.addEventListener("focus", followConfigChanges);

  // The country picker's regions in the page's language (the countries' own names have data-i18n).
  const regions = { Americas: t("Americas"), Europe: t("Europe"), "Asia Pacific": t("Asia Pacific"), "Middle East": t("Middle East"), Africa: t("Africa") };
  for (const group of document.querySelectorAll("#countryCode optgroup")) group.label = regions[group.label] ?? group.label;

  // MARK: Start: the block, then the plugin's session if it has one.

  (async () => {
    try { await readBlock(); } catch (e) { alert(e.message); }
    prefillLogin();
    prefillSettings();
    try {
      const session = await request("session");
      if (session.success) {
        region = session.region;
        $("#session").classList.remove("hidden");
        showStep("devices");
        await loadDevices();
        return;
      }
    } catch { /* no session: log in */ }
    showStep("login");
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Connectez votre compte eWeLink pour gérer vos appareils dans HomeKit.",
    "Connect your eWeLink account": "Connectez votre compte eWeLink",
    "Email or phone number": "E-mail ou numéro de téléphone",
    "your@email.com": "vous@exemple.com",
    "Your eWeLink account's email or phone number.": "L'e-mail ou le numéro de téléphone de votre compte eWeLink.",
    "Password": "Mot de passe",
    "Country code": "Indicatif du pays",
    "Connect account": "Connecter le compte",
    "Your devices": "Vos appareils",
    "Active session detected": "Session active détectée",
    "Using the session the plugin logged in with.": "La session ouverte par le plugin est utilisée.",
    "Log in with another account": "Se connecter avec un autre compte",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Discovered devices": "Appareils découverts",
    "Refresh": "Actualiser",
    "Saving writes the account and settings to this instance's block; the plugin reloads with them.": "L'enregistrement écrit le compte et les réglages dans le bloc de cette instance ; le plugin se recharge avec eux.",
    "Save configuration": "Enregistrer la configuration",
    "Connection mode": "Mode de connexion",
    "Auto (LAN + Cloud)": "Auto (LAN + cloud)",
    "LAN Only": "LAN uniquement",
    "Cloud Only": "Cloud uniquement",
    "Auto mode tries LAN first, then falls back to cloud.": "Le mode auto essaie d'abord le LAN, puis se rabat sur le cloud.",
    "Enable debug logging": "Activer le journal de débogage",
    "Accessories log their debug lines (run homeswift with -D to see them).": "Les accessoires journalisent leurs lignes de débogage (lancez homeswift avec -D pour les voir).",
    "Show offline devices as off": "Afficher les appareils hors ligne comme éteints",
    "Instead of \"No Response\" in the Home app.": "Au lieu de « Pas de réponse » dans l'app Maison.",
    "The other options (per-device settings, simulations, RF sub-devices) are in Settings.": "Les autres options (réglages par appareil, simulations, sous-appareils RF) sont dans Réglages.",
    "Configuration complete": "Configuration terminée",
    "Back to the devices": "Retour aux appareils",
    "Restart Homeswift": "Redémarrer Homeswift",
    "Americas": "Amériques",
    "Europe": "Europe",
    "Asia Pacific": "Asie-Pacifique",
    "Middle East": "Moyen-Orient",
    "Africa": "Afrique",
    "LAN: {address}": "LAN : {address}",
    "LAN: No IP": "LAN : pas d'IP",
    "Cloud": "Cloud",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "ID: {id}": "ID : {id}",
    "{brand} — {model} (UIID: {uiid})": "{brand} — {model} (UIID : {uiid})",
    "Unknown": "Inconnu",
    "N/A": "N/D",
    "No devices found": "Aucun appareil trouvé",
    "Connect your eWeLink account and click Refresh.": "Connectez votre compte eWeLink et cliquez sur Actualiser.",
    "Failed to load devices": "Impossible de charger les appareils",
    "Connected": "Connecté",
    "Retrying": "Nouvelle tentative",
    "Reconnecting": "Reconnexion",
    "Not connected": "Non connecté",
    "On the LAN": "Sur le LAN",
    "In HomeKit": "Dans HomeKit",
    "{n} device": "{n} appareil",
    "{n} devices": "{n} appareils",
    "{n} accessory": "{n} accessoire",
    "{n} accessories": "{n} accessoires",
    "All done!": "C'est fait !",
    "The configuration is saved. Restart Homeswift to apply the rest ({changes}).": "La configuration est enregistrée. Redémarrez Homeswift pour appliquer le reste ({changes}).",
    "The configuration is saved and the plugin reloaded with it.": "La configuration est enregistrée et le plugin s'est rechargé avec elle.",
    "Failed to save configuration": "Impossible d'enregistrer la configuration",
    "Restarting…": "Redémarrage…",
    "Homeswift restarted.": "Homeswift a redémarré.",
    "Homeswift has not answered for a minute: check its log, then reload this page.": "Homeswift ne répond plus depuis une minute : consultez son journal, puis rechargez cette page.",
    "Please enter your username and password": "Saisissez votre nom d'utilisateur et votre mot de passe",
    "Login failed": "Échec de la connexion",
    "Missing required fields: {0}": "Champs requis manquants : {0}",
    "Not logged in to eWeLink: connect your account first": "Non connecté à eWeLink : connectez d'abord votre compte",
    "Username and password are required": "Le nom d'utilisateur et le mot de passe sont requis",
    "Login failed: too many region redirects [{0}]": "Échec de la connexion : trop de redirections de région [{0}]",
    "Login failed: unexpected response [{0}]": "Échec de la connexion : réponse inattendue [{0}]",
    "Login failed: {0}": "Échec de la connexion : {0}",
    "Failed to get homes: {0}": "Impossible d'obtenir les maisons : {0}",
    "Failed to get family list": "Impossible d'obtenir la liste des maisons",
    "Failed to get devices: {0}": "Impossible d'obtenir les appareils : {0}",
    "Failed to refresh token [{0}]": "Impossible de renouveler le jeton [{0}]",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "Unknown region received: {0}": "Région inconnue reçue : {0}",
    "nothing at {0} {1}": "rien à {0} {1}",
    "Argentina (+54)": "Argentine (+54)",
    "Brazil (+55)": "Brésil (+55)",
    "Chile (+56)": "Chili (+56)",
    "Colombia (+57)": "Colombie (+57)",
    "Mexico (+52)": "Mexique (+52)",
    "Peru (+51)": "Pérou (+51)",
    "United States / Canada (+1)": "États-Unis / Canada (+1)",
    "Venezuela (+58)": "Venezuela (+58)",
    "Austria (+43)": "Autriche (+43)",
    "Belgium (+32)": "Belgique (+32)",
    "Bulgaria (+359)": "Bulgarie (+359)",
    "Czech Republic (+420)": "Tchéquie (+420)",
    "Denmark (+45)": "Danemark (+45)",
    "Finland (+358)": "Finlande (+358)",
    "France (+33)": "France (+33)",
    "Germany (+49)": "Allemagne (+49)",
    "Greece (+30)": "Grèce (+30)",
    "Hungary (+36)": "Hongrie (+36)",
    "Ireland (+353)": "Irlande (+353)",
    "Italy (+39)": "Italie (+39)",
    "Netherlands (+31)": "Pays-Bas (+31)",
    "Norway (+47)": "Norvège (+47)",
    "Poland (+48)": "Pologne (+48)",
    "Portugal (+351)": "Portugal (+351)",
    "Romania (+40)": "Roumanie (+40)",
    "Russia (+7)": "Russie (+7)",
    "Slovakia (+421)": "Slovaquie (+421)",
    "Spain (+34)": "Espagne (+34)",
    "Sweden (+46)": "Suède (+46)",
    "Switzerland (+41)": "Suisse (+41)",
    "Turkey (+90)": "Turquie (+90)",
    "Ukraine (+380)": "Ukraine (+380)",
    "United Kingdom (+44)": "Royaume-Uni (+44)",
    "Australia (+61)": "Australie (+61)",
    "China (+86)": "Chine (+86)",
    "Hong Kong (+852)": "Hong Kong (+852)",
    "India (+91)": "Inde (+91)",
    "Indonesia (+62)": "Indonésie (+62)",
    "Japan (+81)": "Japon (+81)",
    "Macau (+853)": "Macao (+853)",
    "Malaysia (+60)": "Malaisie (+60)",
    "New Zealand (+64)": "Nouvelle-Zélande (+64)",
    "Philippines (+63)": "Philippines (+63)",
    "Singapore (+65)": "Singapour (+65)",
    "South Korea (+82)": "Corée du Sud (+82)",
    "Taiwan (+886)": "Taïwan (+886)",
    "Thailand (+66)": "Thaïlande (+66)",
    "Vietnam (+84)": "Viêt Nam (+84)",
    "Israel (+972)": "Israël (+972)",
    "Kuwait (+965)": "Koweït (+965)",
    "Qatar (+974)": "Qatar (+974)",
    "Saudi Arabia (+966)": "Arabie saoudite (+966)",
    "UAE (+971)": "Émirats arabes unis (+971)",
    "Egypt (+20)": "Égypte (+20)",
    "Morocco (+212)": "Maroc (+212)",
    "Nigeria (+234)": "Nigeria (+234)",
    "South Africa (+27)": "Afrique du Sud (+27)"
  },
  "es": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Conecta tu cuenta de eWeLink para gestionar los dispositivos en HomeKit.",
    "Connect your eWeLink account": "Conecta tu cuenta de eWeLink",
    "Email or phone number": "Correo o número de teléfono",
    "your@email.com": "tu@email.com",
    "Your eWeLink account's email or phone number.": "El correo o el número de teléfono de tu cuenta de eWeLink.",
    "Password": "Contraseña",
    "Country code": "Prefijo del país",
    "Connect account": "Conectar la cuenta",
    "Your devices": "Tus dispositivos",
    "Active session detected": "Sesión activa detectada",
    "Using the session the plugin logged in with.": "Se usa la sesión con la que el plugin inició sesión.",
    "Log in with another account": "Iniciar sesión con otra cuenta",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Discovered devices": "Dispositivos detectados",
    "Refresh": "Actualizar",
    "Saving writes the account and settings to this instance's block; the plugin reloads with them.": "Al guardar, la cuenta y los ajustes se escriben en el bloque de esta instancia; el plugin se recarga con ellos.",
    "Save configuration": "Guardar la configuración",
    "Connection mode": "Modo de conexión",
    "Auto (LAN + Cloud)": "Automático (LAN + nube)",
    "LAN Only": "Solo LAN",
    "Cloud Only": "Solo nube",
    "Auto mode tries LAN first, then falls back to cloud.": "El modo automático prueba primero la LAN y, si no, recurre a la nube.",
    "Enable debug logging": "Activar el registro de depuración",
    "Accessories log their debug lines (run homeswift with -D to see them).": "Los accesorios registran sus líneas de depuración (ejecuta homeswift con -D para verlas).",
    "Show offline devices as off": "Mostrar los dispositivos sin conexión como apagados",
    "Instead of \"No Response\" in the Home app.": "En lugar de «Sin respuesta» en la app Casa.",
    "The other options (per-device settings, simulations, RF sub-devices) are in Settings.": "Las demás opciones (ajustes por dispositivo, simulaciones, subdispositivos RF) están en Ajustes.",
    "Configuration complete": "Configuración completada",
    "Back to the devices": "Volver a los dispositivos",
    "Restart Homeswift": "Reiniciar Homeswift",
    "Americas": "América",
    "Europe": "Europa",
    "Asia Pacific": "Asia-Pacífico",
    "Middle East": "Oriente Próximo",
    "Africa": "África",
    "LAN: {address}": "LAN: {address}",
    "LAN: No IP": "LAN: sin IP",
    "Cloud": "Nube",
    "Online": "Conectado",
    "Offline": "Sin conexión",
    "ID: {id}": "ID: {id}",
    "{brand} — {model} (UIID: {uiid})": "{brand} — {model} (UIID: {uiid})",
    "Unknown": "Desconocido",
    "N/A": "N/D",
    "No devices found": "No se han encontrado dispositivos",
    "Connect your eWeLink account and click Refresh.": "Conecta tu cuenta de eWeLink y haz clic en Actualizar.",
    "Failed to load devices": "No se han podido cargar los dispositivos",
    "Connected": "Conectado",
    "Retrying": "Reintentando",
    "Reconnecting": "Reconectando",
    "Not connected": "No conectado",
    "On the LAN": "En la LAN",
    "In HomeKit": "En HomeKit",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} accessory": "{n} accesorio",
    "{n} accessories": "{n} accesorios",
    "All done!": "¡Listo!",
    "The configuration is saved. Restart Homeswift to apply the rest ({changes}).": "La configuración está guardada. Reinicia Homeswift para aplicar el resto ({changes}).",
    "The configuration is saved and the plugin reloaded with it.": "La configuración está guardada y el plugin se ha recargado con ella.",
    "Failed to save configuration": "No se ha podido guardar la configuración",
    "Restarting…": "Reiniciando…",
    "Homeswift restarted.": "Homeswift se ha reiniciado.",
    "Homeswift has not answered for a minute: check its log, then reload this page.": "Homeswift lleva un minuto sin responder: revisa su registro y vuelve a cargar esta página.",
    "Please enter your username and password": "Introduce tu nombre de usuario y tu contraseña",
    "Login failed": "No se ha podido iniciar sesión",
    "Missing required fields: {0}": "Faltan campos obligatorios: {0}",
    "Not logged in to eWeLink: connect your account first": "No has iniciado sesión en eWeLink: conecta primero tu cuenta",
    "Username and password are required": "Se necesitan el nombre de usuario y la contraseña",
    "Login failed: too many region redirects [{0}]": "No se ha podido iniciar sesión: demasiadas redirecciones de región [{0}]",
    "Login failed: unexpected response [{0}]": "No se ha podido iniciar sesión: respuesta inesperada [{0}]",
    "Login failed: {0}": "No se ha podido iniciar sesión: {0}",
    "Failed to get homes: {0}": "No se han podido obtener las casas: {0}",
    "Failed to get family list": "No se ha podido obtener la lista de casas",
    "Failed to get devices: {0}": "No se han podido obtener los dispositivos: {0}",
    "Failed to refresh token [{0}]": "No se ha podido renovar el token [{0}]",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "Unknown region received: {0}": "Se ha recibido una región desconocida: {0}",
    "nothing at {0} {1}": "no hay nada en {0} {1}",
    "Argentina (+54)": "Argentina (+54)",
    "Brazil (+55)": "Brasil (+55)",
    "Chile (+56)": "Chile (+56)",
    "Colombia (+57)": "Colombia (+57)",
    "Mexico (+52)": "México (+52)",
    "Peru (+51)": "Perú (+51)",
    "United States / Canada (+1)": "Estados Unidos / Canadá (+1)",
    "Venezuela (+58)": "Venezuela (+58)",
    "Austria (+43)": "Austria (+43)",
    "Belgium (+32)": "Bélgica (+32)",
    "Bulgaria (+359)": "Bulgaria (+359)",
    "Czech Republic (+420)": "Chequia (+420)",
    "Denmark (+45)": "Dinamarca (+45)",
    "Finland (+358)": "Finlandia (+358)",
    "France (+33)": "Francia (+33)",
    "Germany (+49)": "Alemania (+49)",
    "Greece (+30)": "Grecia (+30)",
    "Hungary (+36)": "Hungría (+36)",
    "Ireland (+353)": "Irlanda (+353)",
    "Italy (+39)": "Italia (+39)",
    "Netherlands (+31)": "Países Bajos (+31)",
    "Norway (+47)": "Noruega (+47)",
    "Poland (+48)": "Polonia (+48)",
    "Portugal (+351)": "Portugal (+351)",
    "Romania (+40)": "Rumanía (+40)",
    "Russia (+7)": "Rusia (+7)",
    "Slovakia (+421)": "Eslovaquia (+421)",
    "Spain (+34)": "España (+34)",
    "Sweden (+46)": "Suecia (+46)",
    "Switzerland (+41)": "Suiza (+41)",
    "Turkey (+90)": "Turquía (+90)",
    "Ukraine (+380)": "Ucrania (+380)",
    "United Kingdom (+44)": "Reino Unido (+44)",
    "Australia (+61)": "Australia (+61)",
    "China (+86)": "China (+86)",
    "Hong Kong (+852)": "Hong Kong (+852)",
    "India (+91)": "India (+91)",
    "Indonesia (+62)": "Indonesia (+62)",
    "Japan (+81)": "Japón (+81)",
    "Macau (+853)": "Macao (+853)",
    "Malaysia (+60)": "Malasia (+60)",
    "New Zealand (+64)": "Nueva Zelanda (+64)",
    "Philippines (+63)": "Filipinas (+63)",
    "Singapore (+65)": "Singapur (+65)",
    "South Korea (+82)": "Corea del Sur (+82)",
    "Taiwan (+886)": "Taiwán (+886)",
    "Thailand (+66)": "Tailandia (+66)",
    "Vietnam (+84)": "Vietnam (+84)",
    "Israel (+972)": "Israel (+972)",
    "Kuwait (+965)": "Kuwait (+965)",
    "Qatar (+974)": "Catar (+974)",
    "Saudi Arabia (+966)": "Arabia Saudí (+966)",
    "UAE (+971)": "Emiratos Árabes Unidos (+971)",
    "Egypt (+20)": "Egipto (+20)",
    "Morocco (+212)": "Marruecos (+212)",
    "Nigeria (+234)": "Nigeria (+234)",
    "South Africa (+27)": "Sudáfrica (+27)"
  },
  "pt": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Ligue a sua conta eWeLink para gerir os dispositivos no HomeKit.",
    "Connect your eWeLink account": "Ligue a sua conta eWeLink",
    "Email or phone number": "E-mail ou número de telemóvel",
    "your@email.com": "nome@email.com",
    "Your eWeLink account's email or phone number.": "O e-mail ou o número de telemóvel da sua conta eWeLink.",
    "Password": "Palavra-passe",
    "Country code": "Indicativo do país",
    "Connect account": "Ligar a conta",
    "Your devices": "Os seus dispositivos",
    "Active session detected": "Sessão ativa detetada",
    "Using the session the plugin logged in with.": "É usada a sessão com que o plugin iniciou sessão.",
    "Log in with another account": "Iniciar sessão com outra conta",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Discovered devices": "Dispositivos detetados",
    "Refresh": "Atualizar",
    "Saving writes the account and settings to this instance's block; the plugin reloads with them.": "Ao guardar, a conta e as definições são escritas no bloco desta instância; o plugin recarrega com elas.",
    "Save configuration": "Guardar a configuração",
    "Connection mode": "Modo de ligação",
    "Auto (LAN + Cloud)": "Automático (LAN + nuvem)",
    "LAN Only": "Só LAN",
    "Cloud Only": "Só nuvem",
    "Auto mode tries LAN first, then falls back to cloud.": "O modo automático tenta primeiro a LAN e, se falhar, recorre à nuvem.",
    "Enable debug logging": "Ativar o registo de depuração",
    "Accessories log their debug lines (run homeswift with -D to see them).": "Os acessórios registam as suas linhas de depuração (execute o homeswift com -D para as ver).",
    "Show offline devices as off": "Mostrar os dispositivos offline como desligados",
    "Instead of \"No Response\" in the Home app.": "Em vez de «Sem resposta» na app Casa.",
    "The other options (per-device settings, simulations, RF sub-devices) are in Settings.": "As outras opções (definições por dispositivo, simulações, subdispositivos RF) estão em Definições.",
    "Configuration complete": "Configuração concluída",
    "Back to the devices": "Voltar aos dispositivos",
    "Restart Homeswift": "Reiniciar o Homeswift",
    "Americas": "Américas",
    "Europe": "Europa",
    "Asia Pacific": "Ásia-Pacífico",
    "Middle East": "Médio Oriente",
    "Africa": "África",
    "LAN: {address}": "LAN: {address}",
    "LAN: No IP": "LAN: sem IP",
    "Cloud": "Nuvem",
    "Online": "Online",
    "Offline": "Offline",
    "ID: {id}": "ID: {id}",
    "{brand} — {model} (UIID: {uiid})": "{brand} — {model} (UIID: {uiid})",
    "Unknown": "Desconhecido",
    "N/A": "N/D",
    "No devices found": "Nenhum dispositivo encontrado",
    "Connect your eWeLink account and click Refresh.": "Ligue a sua conta eWeLink e clique em Atualizar.",
    "Failed to load devices": "Não foi possível carregar os dispositivos",
    "Connected": "Ligado",
    "Retrying": "A tentar novamente",
    "Reconnecting": "A restabelecer a ligação",
    "Not connected": "Não ligado",
    "On the LAN": "Na LAN",
    "In HomeKit": "No HomeKit",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} accessory": "{n} acessório",
    "{n} accessories": "{n} acessórios",
    "All done!": "Concluído!",
    "The configuration is saved. Restart Homeswift to apply the rest ({changes}).": "A configuração está guardada. Reinicie o Homeswift para aplicar o resto ({changes}).",
    "The configuration is saved and the plugin reloaded with it.": "A configuração está guardada e o plugin recarregou com ela.",
    "Failed to save configuration": "Não foi possível guardar a configuração",
    "Restarting…": "A reiniciar…",
    "Homeswift restarted.": "O Homeswift reiniciou.",
    "Homeswift has not answered for a minute: check its log, then reload this page.": "O Homeswift não responde há um minuto: consulte o registo e volte a carregar esta página.",
    "Please enter your username and password": "Introduza o nome de utilizador e a palavra-passe",
    "Login failed": "Não foi possível iniciar sessão",
    "Missing required fields: {0}": "Faltam campos obrigatórios: {0}",
    "Not logged in to eWeLink: connect your account first": "Sem sessão iniciada no eWeLink: ligue primeiro a sua conta",
    "Username and password are required": "São necessários o nome de utilizador e a palavra-passe",
    "Login failed: too many region redirects [{0}]": "Não foi possível iniciar sessão: demasiados redirecionamentos de região [{0}]",
    "Login failed: unexpected response [{0}]": "Não foi possível iniciar sessão: resposta inesperada [{0}]",
    "Login failed: {0}": "Não foi possível iniciar sessão: {0}",
    "Failed to get homes: {0}": "Não foi possível obter as casas: {0}",
    "Failed to get family list": "Não foi possível obter a lista de casas",
    "Failed to get devices: {0}": "Não foi possível obter os dispositivos: {0}",
    "Failed to refresh token [{0}]": "Não foi possível renovar o token [{0}]",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "Unknown region received: {0}": "Foi recebida uma região desconhecida: {0}",
    "nothing at {0} {1}": "nada em {0} {1}",
    "Argentina (+54)": "Argentina (+54)",
    "Brazil (+55)": "Brasil (+55)",
    "Chile (+56)": "Chile (+56)",
    "Colombia (+57)": "Colômbia (+57)",
    "Mexico (+52)": "México (+52)",
    "Peru (+51)": "Peru (+51)",
    "United States / Canada (+1)": "Estados Unidos / Canadá (+1)",
    "Venezuela (+58)": "Venezuela (+58)",
    "Austria (+43)": "Áustria (+43)",
    "Belgium (+32)": "Bélgica (+32)",
    "Bulgaria (+359)": "Bulgária (+359)",
    "Czech Republic (+420)": "Chéquia (+420)",
    "Denmark (+45)": "Dinamarca (+45)",
    "Finland (+358)": "Finlândia (+358)",
    "France (+33)": "França (+33)",
    "Germany (+49)": "Alemanha (+49)",
    "Greece (+30)": "Grécia (+30)",
    "Hungary (+36)": "Hungria (+36)",
    "Ireland (+353)": "Irlanda (+353)",
    "Italy (+39)": "Itália (+39)",
    "Netherlands (+31)": "Países Baixos (+31)",
    "Norway (+47)": "Noruega (+47)",
    "Poland (+48)": "Polónia (+48)",
    "Portugal (+351)": "Portugal (+351)",
    "Romania (+40)": "Roménia (+40)",
    "Russia (+7)": "Rússia (+7)",
    "Slovakia (+421)": "Eslováquia (+421)",
    "Spain (+34)": "Espanha (+34)",
    "Sweden (+46)": "Suécia (+46)",
    "Switzerland (+41)": "Suíça (+41)",
    "Turkey (+90)": "Turquia (+90)",
    "Ukraine (+380)": "Ucrânia (+380)",
    "United Kingdom (+44)": "Reino Unido (+44)",
    "Australia (+61)": "Austrália (+61)",
    "China (+86)": "China (+86)",
    "Hong Kong (+852)": "Hong Kong (+852)",
    "India (+91)": "Índia (+91)",
    "Indonesia (+62)": "Indonésia (+62)",
    "Japan (+81)": "Japão (+81)",
    "Macau (+853)": "Macau (+853)",
    "Malaysia (+60)": "Malásia (+60)",
    "New Zealand (+64)": "Nova Zelândia (+64)",
    "Philippines (+63)": "Filipinas (+63)",
    "Singapore (+65)": "Singapura (+65)",
    "South Korea (+82)": "Coreia do Sul (+82)",
    "Taiwan (+886)": "Taiwan (+886)",
    "Thailand (+66)": "Tailândia (+66)",
    "Vietnam (+84)": "Vietname (+84)",
    "Israel (+972)": "Israel (+972)",
    "Kuwait (+965)": "Koweit (+965)",
    "Qatar (+974)": "Catar (+974)",
    "Saudi Arabia (+966)": "Arábia Saudita (+966)",
    "UAE (+971)": "Emirados Árabes Unidos (+971)",
    "Egypt (+20)": "Egito (+20)",
    "Morocco (+212)": "Marrocos (+212)",
    "Nigeria (+234)": "Nigéria (+234)",
    "South Africa (+27)": "África do Sul (+27)"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>eWeLink</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's settings page on the UI's materials: a numbered wizard (connect the account, the
     devices and settings, done) with one step showing at a time. */
  .page-head { align-items: center; }
  .tile.ewelink { background: linear-gradient(160deg, #ff7b6b, #e74c3c); }
  /* RF and LAN hues, lighter on dark backgrounds so their small text stays readable. */
  :root { --rf: #9c27b0; --rf-line: rgba(156, 39, 176, 0.35); --rf-fill: rgba(156, 39, 176, 0.1); --lan: #1f6fe0; --lan-line: rgba(31, 111, 224, 0.35); }
  @media (prefers-color-scheme: dark) {
    :root:not(:where([data-theme="light"])) { --rf: #d58cf0; --rf-line: rgba(213, 140, 240, 0.4); --rf-fill: rgba(213, 140, 240, 0.14); --lan: #6aa8ff; --lan-line: rgba(106, 168, 255, 0.4); }
  }
  :root:where([data-theme="dark"]) { --rf: #d58cf0; --rf-line: rgba(213, 140, 240, 0.4); --rf-fill: rgba(213, 140, 240, 0.14); --lan: #6aa8ff; --lan-line: rgba(106, 168, 255, 0.4); }
  .step { margin-bottom: 22px; animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin: 22px 0 12px; }
  .step-head h2 { margin: 0; }
  .step-number {
    width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; flex: none; font-weight: 600;
    background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text);
  }
  .step-number.done { background: linear-gradient(160deg, #6ee7a0, #23a55a); color: #fff; }
  .session { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .session p { margin: 2px 0 0; font-size: 0.8125rem; }
  .login { max-width: 520px; }
  .login .actions { margin-top: 16px; }
  .tabs { margin-bottom: 14px; }
  .list-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-bottom: 12px; border-bottom: 1px solid var(--line); }
  .list-head h3 { margin: 0; display: flex; align-items: center; gap: 8px; }
  .count { font-size: 0.75rem; font-weight: 600; padding: 1px 8px; border-radius: 999px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }
  .devices { list-style: none; margin: 0; padding: 0; }
  .device { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-start; gap: 6px 14px; padding: 12px 2px; border-bottom: 1px solid var(--line); }
  .device:last-child { border-bottom: 0; }
  .device .info { flex: 1 1 0; min-width: 0; }
  .device .name { font-weight: 500; }
  .device .meta { font-size: 0.8125rem; color: var(--muted); overflow-wrap: anywhere; }
  .device .meta .mono { margin-right: 8px; }
  .device .badges { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; flex: none; }
  .device .explain { flex: 0 0 100%; min-width: 0; }
  .device.rf { margin-left: 22px; padding-left: 12px; border-left: 3px solid var(--rf); }
  .pill.lan { color: var(--lan); border-color: var(--lan-line); }
  .pill.lan-warn { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }
  .pill.rf { color: var(--rf); border-color: var(--rf-line); }
  .buttons { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
  .buttons span { font-size: 0.75rem; font-weight: 500; padding: 1px 8px; border-radius: 6px; color: var(--rf); background: var(--rf-fill); }
  .problem { margin-bottom: 12px; padding: 12px 14px; border-radius: 14px; border: 1px solid rgba(208, 56, 59, 0.35); background: rgba(208, 56, 59, 0.06); }
  .problem p { margin: 0; color: var(--error); }
  .problem .explain { margin-top: 6px; }
  .empty { text-align: center; padding: 26px 12px; }
  .empty p { margin: 4px 0; }
  .status-facts { margin-bottom: 14px; }
  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (max-width: 520px) { .device.rf { margin-left: 8px; } }
  @media (prefers-reduced-motion: reduce) {
    .step { animation: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large ewelink" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 2v6M15 2v6"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v5"/></svg></span>
    <div class="who">
      <h1>eWeLink</h1>
      <p class="muted" data-i18n>Connect your eWeLink account to manage devices in HomeKit.</p>
    </div>
  </div>

  <section id="step-login" class="step hidden">
    <div class="step-head"><span class="step-number">1</span><h2 data-i18n>Connect your eWeLink account</h2></div>
    <form id="login" class="card login" novalidate>
      <label class="field"><span class="field-title" data-i18n>Email or phone number</span>
        <input id="username" type="text" data-i18n placeholder="your@email.com" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false">
        <span class="help" data-i18n>Your eWeLink account's email or phone number.</span></label>
      <label class="field"><span class="field-title" data-i18n>Password</span>
        <input id="password" type="password" placeholder="••••••••" autocomplete="current-password" enterkeyhint="go"></label>
      <label class="field"><span class="field-title" data-i18n>Country code</span>
        <select id="countryCode">
          <optgroup label="Americas">
            <option data-i18n value="+54">Argentina (+54)</option><option data-i18n value="+55">Brazil (+55)</option><option data-i18n value="+56">Chile (+56)</option>
            <option data-i18n value="+57">Colombia (+57)</option><option data-i18n value="+52">Mexico (+52)</option><option data-i18n value="+51">Peru (+51)</option>
            <option data-i18n value="+1">United States / Canada (+1)</option><option data-i18n value="+58">Venezuela (+58)</option>
          </optgroup>
          <optgroup label="Europe">
            <option data-i18n value="+43">Austria (+43)</option><option data-i18n value="+32">Belgium (+32)</option><option data-i18n value="+359">Bulgaria (+359)</option>
            <option data-i18n value="+420">Czech Republic (+420)</option><option data-i18n value="+45">Denmark (+45)</option><option data-i18n value="+358">Finland (+358)</option>
            <option data-i18n value="+33">France (+33)</option><option data-i18n value="+49">Germany (+49)</option><option data-i18n value="+30">Greece (+30)</option>
            <option data-i18n value="+36">Hungary (+36)</option><option data-i18n value="+353">Ireland (+353)</option><option data-i18n value="+39">Italy (+39)</option>
            <option data-i18n value="+31">Netherlands (+31)</option><option data-i18n value="+47">Norway (+47)</option><option data-i18n value="+48">Poland (+48)</option>
            <option data-i18n value="+351">Portugal (+351)</option><option data-i18n value="+40">Romania (+40)</option><option data-i18n value="+7">Russia (+7)</option>
            <option data-i18n value="+421">Slovakia (+421)</option><option data-i18n value="+34">Spain (+34)</option><option data-i18n value="+46">Sweden (+46)</option>
            <option data-i18n value="+41">Switzerland (+41)</option><option data-i18n value="+90">Turkey (+90)</option><option data-i18n value="+380">Ukraine (+380)</option>
            <option data-i18n value="+44">United Kingdom (+44)</option>
          </optgroup>
          <optgroup label="Asia Pacific">
            <option data-i18n value="+61">Australia (+61)</option><option data-i18n value="+86">China (+86)</option><option data-i18n value="+852">Hong Kong (+852)</option>
            <option data-i18n value="+91">India (+91)</option><option data-i18n value="+62">Indonesia (+62)</option><option data-i18n value="+81">Japan (+81)</option>
            <option data-i18n value="+853">Macau (+853)</option><option data-i18n value="+60">Malaysia (+60)</option><option data-i18n value="+64">New Zealand (+64)</option>
            <option data-i18n value="+63">Philippines (+63)</option><option data-i18n value="+65">Singapore (+65)</option><option data-i18n value="+82">South Korea (+82)</option>
            <option data-i18n value="+886">Taiwan (+886)</option><option data-i18n value="+66">Thailand (+66)</option><option data-i18n value="+84">Vietnam (+84)</option>
          </optgroup>
          <optgroup label="Middle East">
            <option data-i18n value="+972">Israel (+972)</option><option data-i18n value="+965">Kuwait (+965)</option><option data-i18n value="+974">Qatar (+974)</option>
            <option data-i18n value="+966">Saudi Arabia (+966)</option><option data-i18n value="+971">UAE (+971)</option>
          </optgroup>
          <optgroup label="Africa">
            <option data-i18n value="+20">Egypt (+20)</option><option data-i18n value="+212">Morocco (+212)</option><option data-i18n value="+234">Nigeria (+234)</option>
            <option data-i18n value="+27">South Africa (+27)</option>
          </optgroup>
        </select></label>
      <div class="actions"><button id="connect" class="primary" type="submit" data-i18n>Connect account</button></div>
    </form>
    <div id="login-problem" class="problem hidden" role="alert"></div>
  </section>

  <section id="step-devices" class="step hidden">
    <div class="step-head"><span class="step-number">2</span><h2 data-i18n>Your devices</h2></div>
    <div id="session" class="card session hidden">
      <div><strong data-i18n>Active session detected</strong><p class="muted" data-i18n>Using the session the plugin logged in with.</p></div>
      <button id="new-login" data-i18n>Log in with another account</button>
    </div>
    <div class="group tabs" role="tablist">
      <button id="tab-devices" role="tab" class="on" aria-selected="true" aria-controls="pane-devices" data-i18n>Devices</button>
      <button id="tab-settings" role="tab" aria-selected="false" aria-controls="pane-settings" data-i18n>Settings</button>
    </div>
    <div id="save-problem" class="problem hidden" role="alert"></div>
    <div id="pane-devices" class="card" role="tabpanel">
      <div id="status" class="facts status-facts"></div>
      <div class="list-head">
        <h3 data-i18n>Discovered devices <span id="device-count" class="count">0</span></h3>
        <button id="refresh" data-i18n>Refresh</button>
      </div>
      <div id="devices-problem" class="problem hidden"></div>
      <ul id="devices" class="devices"></ul>
      <div class="save-bar"><span class="muted" data-i18n>Saving writes the account and settings to this instance's block; the plugin reloads with them.</span>
        <button id="save" class="primary" data-i18n>Save configuration</button></div>
    </div>
    <div id="pane-settings" class="card hidden" role="tabpanel">
      <label class="field"><span class="field-title" data-i18n>Connection mode</span>
        <select id="mode"><option value="auto" data-i18n>Auto (LAN + Cloud)</option><option value="lan" data-i18n>LAN Only</option><option value="wan" data-i18n>Cloud Only</option></select>
        <span class="help" data-i18n>Auto mode tries LAN first, then falls back to cloud.</span></label>
      <label class="toggle"><span class="switch"><input id="debug" type="checkbox"><span></span></span>
        <span><span class="field-title" data-i18n>Enable debug logging</span><span class="help" data-i18n>Accessories log their debug lines (run homeswift with -D to see them).</span></span></label>
      <label class="toggle"><span class="switch"><input id="offline-as-off" type="checkbox"><span></span></span>
        <span><span class="field-title" data-i18n>Show offline devices as off</span><span class="help" data-i18n>Instead of "No Response" in the Home app.</span></span></label>
      <div class="save-bar"><span class="muted" data-i18n>The other options (per-device settings, simulations, RF sub-devices) are in Settings.</span>
        <button id="save-settings" class="primary" data-i18n>Save configuration</button></div>
    </div>
  </section>

  <section id="step-complete" class="step hidden">
    <div class="step-head"><span class="step-number done">✓</span><h2 data-i18n>Configuration complete</h2></div>
    <div class="card">
      <p id="complete-text"><strong>All done!</strong> The plugin reloaded with the new configuration.</p>
      <div class="actions">
        <button id="back" data-i18n>Back to the devices</button>
        <button id="restart" class="hidden" data-i18n>Restart Homeswift</button>
      </div>
      <p id="restart-status" class="status-line"></p>
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
