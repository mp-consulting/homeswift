// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page, after the Homebridge plugin's settings UI without its login: Setup signs in (a card leads to it
// while the account is not signed in), then the account's devices with their LAN and RF details (an mDNS scan runs
// while the cloud answers). It writes no settings (docs/adr/0002-schema-declares-every-setting.md): the plugin's are on
// its Settings page, and a device's row opens its own there. The session stays in the plugin: the browser never sees a
// token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const showDevices = (shown) => $("#step-devices").classList.toggle("hidden", !shown);

  let devices = [];
  let mode = null;    // the connection mode the plugin reports

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there.

  const deviceSettings = (deviceId) => homeswift.accessorySettings(`eWeLink:${deviceId}`);

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${mode || "auto"}.`].filter(Boolean).join(" ");

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
      el("div", { class: "badges" }, badges,
        el("a", { class: "button small", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Settings"), "aria-label": t("Settings of {name}", { name: device.name }) })),
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
      : [el("li", { class: "empty" }, el("p", { text: t("No devices found") }))]));
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
      // The plugin answers without its platform while it reloads: only a platform's answer says signed out.
      if ("mode" in status && !status.configured) { showSetup(); return; }
      if (status.mode) mode = status.mode;
      $("#status").replaceChildren(
        fact(t("Cloud"), status.websocket ? t("Connected") : status.retrying ? t("Retrying") : status.initialized ? t("Reconnecting") : t("Not connected")),
        fact(t("On the LAN"), tn("{n} device", "{n} devices", status.lanDevices ?? 0)),
        fact(t("In HomeKit"), tn("{n} accessory", "{n} accessories", status.accessories ?? 0)));
    } catch { $("#status").replaceChildren(); }
  }

  /// Not signed in: the card to Setup in place of the devices.
  function showSetup() {
    showDevices(false);
    $("#setup").replaceChildren(homeswift.setupCard({
      title: t("Sign in to your eWeLink account"),
      text: t("Add accessories signs in with your eWeLink email or phone number; the account's devices come with it."),
      glyph: "key",
    }));
  }

  // MARK: Events

  $("#refresh").addEventListener("click", loadDevices);

  // MARK: Start: the plugin's state: signed in, its devices; else the card to Setup.

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  (async () => {
    let status;
    try { status = await request("status"); } catch { /* the plugin is restarting: show the devices it can list */ }
    if (status && "mode" in status && !status.configured) { showSetup(); return; }
    if (status?.mode) mode = status.mode;
    showDevices(true);
    await loadDevices();
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Signed in. The connection mode, the other options and each device's settings are on the Settings page.": "Connecté. Le mode de connexion, les autres options et les réglages de chaque appareil sont sur la page Réglages.",
    "The devices of your eWeLink account, how the plugin reaches each one on the LAN or through the cloud, and their settings.": "Les appareils de votre compte eWeLink, comment le plugin joint chacun sur le réseau local ou par le cloud, et leurs réglages.",
    "Settings": "Réglages",
    "Discovered devices": "Appareils découverts",
    "Refresh": "Actualiser",
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
    "Sign in to your eWeLink account": "Connectez-vous à votre compte eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Ajouter des accessoires vous connecte avec l'e-mail ou le numéro de téléphone de votre compte eWeLink ; les appareils du compte suivent.",
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
    "Not signed in to eWeLink: set up the account in Add accessories": "Non connecté à eWeLink : configurez le compte dans Ajouter des accessoires",
    "Missing required fields: {0}": "Champs requis manquants : {0}",
    "Failed to get homes: {0}": "Impossible d'obtenir les maisons : {0}",
    "Failed to get family list": "Impossible d'obtenir la liste des maisons",
    "Failed to get devices: {0}": "Impossible d'obtenir les appareils : {0}",
    "Failed to refresh token [{0}]": "Impossible de renouveler le jeton [{0}]",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "nothing at {0} {1}": "rien à {0} {1}"
  },
  "es": {
    "Signed in. The connection mode, the other options and each device's settings are on the Settings page.": "Sesión iniciada. El modo de conexión, las demás opciones y los ajustes de cada dispositivo están en la página Ajustes.",
    "The devices of your eWeLink account, how the plugin reaches each one on the LAN or through the cloud, and their settings.": "Los dispositivos de tu cuenta de eWeLink, cómo llega el plugin a cada uno por la red local o por la nube, y sus ajustes.",
    "Settings": "Ajustes",
    "Discovered devices": "Dispositivos detectados",
    "Refresh": "Actualizar",
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
    "Sign in to your eWeLink account": "Inicia sesión en tu cuenta de eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Añadir accesorios inicia sesión con el correo o el teléfono de tu cuenta de eWeLink; los dispositivos de la cuenta vienen con ella.",
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
    "Not signed in to eWeLink: set up the account in Add accessories": "No has iniciado sesión en eWeLink: configura la cuenta en Añadir accesorios",
    "Missing required fields: {0}": "Faltan campos obligatorios: {0}",
    "Failed to get homes: {0}": "No se han podido obtener las casas: {0}",
    "Failed to get family list": "No se ha podido obtener la lista de casas",
    "Failed to get devices: {0}": "No se han podido obtener los dispositivos: {0}",
    "Failed to refresh token [{0}]": "No se ha podido renovar el token [{0}]",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "nothing at {0} {1}": "no hay nada en {0} {1}"
  },
  "pt": {
    "Signed in. The connection mode, the other options and each device's settings are on the Settings page.": "Sessão iniciada. O modo de ligação, as outras opções e as definições de cada dispositivo estão na página Definições.",
    "The devices of your eWeLink account, how the plugin reaches each one on the LAN or through the cloud, and their settings.": "Os dispositivos da sua conta eWeLink, como o plugin chega a cada um pela rede local ou pela nuvem, e as suas definições.",
    "Settings": "Definições",
    "Discovered devices": "Dispositivos detetados",
    "Refresh": "Atualizar",
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
    "Sign in to your eWeLink account": "Inicie sessão na sua conta eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Adicionar acessórios inicia sessão com o e-mail ou o telefone da sua conta eWeLink; os dispositivos da conta vêm com ela.",
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
    "Not signed in to eWeLink: set up the account in Add accessories": "Sem sessão iniciada no eWeLink: configure a conta em Adicionar acessórios",
    "Missing required fields: {0}": "Faltam campos obrigatórios: {0}",
    "Failed to get homes: {0}": "Não foi possível obter as casas: {0}",
    "Failed to get family list": "Não foi possível obter a lista de casas",
    "Failed to get devices: {0}": "Não foi possível obter os dispositivos: {0}",
    "Failed to refresh token [{0}]": "Não foi possível renovar o token [{0}]",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "nothing at {0} {1}": "nada em {0} {1}"
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
  /* The Homebridge plugin's settings page on the UI's materials, without its login (Setup signs in) or its settings
     (the Settings page has them): the account and its devices. */
  .page-head { align-items: center; }
  .tile.ewelink { background: linear-gradient(160deg, #ff7b6b, #e74c3c); }
  /* RF and LAN hues, lighter on dark backgrounds so their small text stays readable. */
  :root { --rf: #9c27b0; --rf-line: rgba(156, 39, 176, 0.35); --rf-fill: rgba(156, 39, 176, 0.1); --lan: #1f6fe0; --lan-line: rgba(31, 111, 224, 0.35); }
  @media (prefers-color-scheme: dark) {
    :root:not(:where([data-theme="light"])) { --rf: #d58cf0; --rf-line: rgba(213, 140, 240, 0.4); --rf-fill: rgba(213, 140, 240, 0.14); --lan: #6aa8ff; --lan-line: rgba(106, 168, 255, 0.4); }
  }
  :root:where([data-theme="dark"]) { --rf: #d58cf0; --rf-line: rgba(213, 140, 240, 0.4); --rf-fill: rgba(213, 140, 240, 0.14); --lan: #6aa8ff; --lan-line: rgba(106, 168, 255, 0.4); }
  .step { margin-bottom: 22px; animation: materialize var(--normal) var(--ease-out); }
  .session { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .session p { margin: 2px 0 0; font-size: 0.8125rem; }
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
      <p class="muted" data-i18n>The devices of your eWeLink account, how the plugin reaches each one on the LAN or through the cloud, and their settings.</p>
    </div>
  </div>

  <div id="setup"></div>

  <section id="step-devices" class="step hidden">
    <div id="account" class="card session">
      <div><strong data-i18n>Your account</strong><p class="muted" data-i18n>Signed in. The connection mode, the other options and each device's settings are on the Settings page.</p></div>
      <a id="sign-in-again" class="button" data-i18n data-action-icon="key">Sign in again</a>
    </div>
    <div id="pane-devices" class="card">
      <div id="status" class="facts status-facts"></div>
      <div class="list-head">
        <h3 data-i18n>Discovered devices <span id="device-count" class="count">0</span></h3>
        <button id="refresh" data-i18n data-action-icon="restore">Refresh</button>
      </div>
      <div id="devices-problem" class="problem hidden"></div>
      <ul id="devices" class="devices"></ul>
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
