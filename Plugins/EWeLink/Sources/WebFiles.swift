// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page, after the Homebridge plugin's settings UI without its login: Setup signs in (a card leads to it
// while the account is not signed in), then the account's devices with their LAN and RF details (an mDNS scan runs
// while the cloud answers), the connection settings, and saving them into this instance's block, which reloads the
// plugin. The session stays in the plugin: the browser never sees a token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, name, explain, api, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const steps = { devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  let devices = [];
  let config = {};

  // MARK: config.json: this instance's block, read and written through the signed-in UI.

  async function readBlock() {
    config = (await homeswift.readBlock()) || {};
    return config;
  }

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${config.mode || "auto"}.`,
    config.countryCode ? `Account country code: ${config.countryCode}.` : ""].filter(Boolean).join(" ");

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

  /// The account Setup signed in to, with Sign in again.
  function showAccount() {
    $("#account-text").textContent = config.username ? t("Signed in as {account}.", { account: config.username }) : t("Signed in.");
  }

  /// Not signed in: the card to Setup in place of the devices.
  function showSetup() {
    showStep(null);
    $("#setup").replaceChildren(homeswift.setupCard({
      title: t("Sign in to your eWeLink account"),
      text: t("Add accessories signs in with your eWeLink email or phone number; the account's devices come with it."),
      glyph: "key",
    }));
  }

  async function saveConfiguration(button) {
    await act(button, async () => {
      clearProblem($("#save-problem"));
      try {
        let block;
        const result = await homeswift.updateBlock((current) => {
          block = { ...current, platform: "eWeLink", name: current.name || name || "eWeLink", mode: $("#mode").value };
          if ($("#debug").checked) block.debug = true; else delete block.debug;
          if ($("#offline-as-off").checked) block.offlineAsOff = true; else delete block.offlineAsOff;
          return block;
        });
        config = block;
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
  $("#save-settings").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#back").addEventListener("click", () => { showStep("devices"); loadDevices(); });
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, restart).catch((e) => HomeswiftCommon.showAlert(e.message)));

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
    showAccount();
  }
  document.addEventListener("visibilitychange", followConfigChanges);
  window.addEventListener("focus", followConfigChanges);

  // MARK: Start: the block, then the plugin's state: signed in, its devices; else the card to Setup.

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  (async () => {
    try { await readBlock(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
    prefillSettings();
    showAccount();
    let status;
    try { status = await request("status"); } catch { /* the plugin is restarting: show what the block says */ }
    if (status && "mode" in status ? !status.configured : !config.username) { showSetup(); return; }
    showStep("devices");
    await loadDevices();
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Connectez votre compte eWeLink pour gérer vos appareils dans HomeKit.",
    "Connect your eWeLink account": "Connectez votre compte eWeLink",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Discovered devices": "Appareils découverts",
    "Refresh": "Actualiser",
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
    "Signed in as {account}.": "Connecté en tant que {account}.",
    "Signed in.": "Connecté.",
    "Sign in to your eWeLink account": "Connectez-vous à votre compte eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Ajouter des accessoires vous connecte avec l'e-mail ou le numéro de téléphone de votre compte eWeLink ; les appareils du compte suivent.",
    "Not signed in to eWeLink: set up the account in Add accessories": "Non connecté à eWeLink : configurez le compte dans Ajouter des accessoires",
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
    "Missing required fields: {0}": "Champs requis manquants : {0}",
    "Failed to get homes: {0}": "Impossible d'obtenir les maisons : {0}",
    "Failed to get family list": "Impossible d'obtenir la liste des maisons",
    "Failed to get devices: {0}": "Impossible d'obtenir les appareils : {0}",
    "Failed to refresh token [{0}]": "Impossible de renouveler le jeton [{0}]",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "nothing at {0} {1}": "rien à {0} {1}",
  },
  "es": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Conecta tu cuenta de eWeLink para gestionar los dispositivos en HomeKit.",
    "Connect your eWeLink account": "Conecta tu cuenta de eWeLink",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Discovered devices": "Dispositivos detectados",
    "Refresh": "Actualizar",
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
    "Signed in as {account}.": "Sesión iniciada como {account}.",
    "Signed in.": "Sesión iniciada.",
    "Sign in to your eWeLink account": "Inicia sesión en tu cuenta de eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Añadir accesorios inicia sesión con el correo o el teléfono de tu cuenta de eWeLink; los dispositivos de la cuenta vienen con ella.",
    "Not signed in to eWeLink: set up the account in Add accessories": "No has iniciado sesión en eWeLink: configura la cuenta en Añadir accesorios",
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
    "Missing required fields: {0}": "Faltan campos obligatorios: {0}",
    "Failed to get homes: {0}": "No se han podido obtener las casas: {0}",
    "Failed to get family list": "No se ha podido obtener la lista de casas",
    "Failed to get devices: {0}": "No se han podido obtener los dispositivos: {0}",
    "Failed to refresh token [{0}]": "No se ha podido renovar el token [{0}]",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "nothing at {0} {1}": "no hay nada en {0} {1}",
  },
  "pt": {
    "Connect your eWeLink account to manage devices in HomeKit.": "Ligue a sua conta eWeLink para gerir os dispositivos no HomeKit.",
    "Connect your eWeLink account": "Ligue a sua conta eWeLink",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Discovered devices": "Dispositivos detetados",
    "Refresh": "Atualizar",
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
    "Signed in as {account}.": "Sessão iniciada como {account}.",
    "Signed in.": "Sessão iniciada.",
    "Sign in to your eWeLink account": "Inicie sessão na sua conta eWeLink",
    "Add accessories signs in with your eWeLink email or phone number; the account's devices come with it.": "Adicionar acessórios inicia sessão com o e-mail ou o telefone da sua conta eWeLink; os dispositivos da conta vêm com ela.",
    "Not signed in to eWeLink: set up the account in Add accessories": "Sem sessão iniciada no eWeLink: configure a conta em Adicionar acessórios",
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
    "Missing required fields: {0}": "Faltam campos obrigatórios: {0}",
    "Failed to get homes: {0}": "Não foi possível obter as casas: {0}",
    "Failed to get family list": "Não foi possível obter a lista de casas",
    "Failed to get devices: {0}": "Não foi possível obter os dispositivos: {0}",
    "Failed to refresh token [{0}]": "Não foi possível renovar o token [{0}]",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "nothing at {0} {1}": "nada em {0} {1}",
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
  /* The Homebridge plugin's settings page on the UI's materials, without its login (Setup signs in): the account,
     the devices and settings, then done once saved. One step shows at a time. */
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

  <div id="setup"></div>

  <section id="step-devices" class="step hidden">
    <div id="account" class="card session">
      <div><strong data-i18n>Your account</strong><p id="account-text" class="muted"></p></div>
      <a id="sign-in-again" class="button" data-i18n data-action-icon="key">Sign in again</a>
    </div>
    <div class="group tabs" role="tablist">
      <button id="tab-devices" role="tab" class="on" aria-selected="true" aria-controls="pane-devices" data-i18n>Devices</button>
      <button id="tab-settings" role="tab" aria-selected="false" aria-controls="pane-settings" data-i18n data-action-icon="sliders">Settings</button>
    </div>
    <div id="save-problem" class="problem hidden" role="alert"></div>
    <div id="pane-devices" class="card" role="tabpanel">
      <div id="status" class="facts status-facts"></div>
      <div class="list-head">
        <h3 data-i18n>Discovered devices <span id="device-count" class="count">0</span></h3>
        <button id="refresh" data-i18n data-action-icon="restore">Refresh</button>
      </div>
      <div id="devices-problem" class="problem hidden"></div>
      <ul id="devices" class="devices"></ul>
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
        <button id="save-settings" class="primary" data-i18n data-action-icon="check">Save configuration</button></div>
    </div>
  </section>

  <section id="step-complete" class="step hidden">
    <div class="step-head"><span class="step-number done">✓</span><h2 data-i18n>Configuration complete</h2></div>
    <div class="card">
      <p id="complete-text"><strong>All done!</strong> The plugin reloaded with the new configuration.</p>
      <div class="actions">
        <button id="back" data-i18n data-action-icon="restore">Back to the devices</button>
        <button id="restart" class="hidden" data-i18n data-action-icon="power">Restart Homeswift</button>
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
