// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DysonPureCoolPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dyson Pure Cool page, after the Homebridge plugin's setup wizard without its sign-in or its settings: the devices
// this instance runs with their live state and continuous monitoring, which is the device's own (not a setting). Setup
// adds devices and keeps their credentials (a card leads to it), and the page writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): a device's Settings opens its own on the plugin's Settings page.
(() => {
  "use strict";
  const { $, el, request, explain, assistant, poll, fact } = homeswift;
  const { t } = HomeswiftI18n;

  let productTypes = {};
  let assistantOn = false;

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors go to the status line.
  const act = (button, work) => homeswift.act(button, work, (message) => toast(message, "error"));

  // A line under the devices for what Homebridge showed as toasts.
  const statusLine = $("#status-line");
  let toastTimer = null;
  function toast(message, kind = "ok") {
    statusLine.textContent = message;
    statusLine.className = `status-line ${kind}`;
    clearTimeout(toastTimer);
    if (kind !== "error") toastTimer = setTimeout(() => { statusLine.textContent = ""; }, 4000);
  }

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there.

  const deviceSettings = (serial) => homeswift.accessorySettings(`DysonPureCool:${serial}`);

  // MARK: The Assistant (the runtime's): never the login, codes, credentials, serial numbers or addresses.

  /// Error text without Dyson serial numbers (the server masks e-mail and IP addresses).
  const scrub = (text) => String(text ?? "").replace(/\b[A-Z0-9]{3}-[A-Z]{2}-[A-Z0-9]{6,}\b/g, "<serial>");

  /// The device facts the Assistant may see.
  const assistantDevice = (d) => ({
    productType: d.productType, model: d.model || productTypes[d.productType] || undefined, connected: d.connected === true,
    retrying: d.retrying === true, ipAddressKnown: !!d.ipAddress, continuousMonitoring: d.continuousMonitoring === true,
  });

  function problem(slot, message, extra, device) {
    slot.replaceChildren(el("p", { class: "device-problem", text: message }),
      assistantOn ? explain({ error: scrub(message), context: extra, device: assistantDevice(device) }) : null);
  }

  // MARK: The devices this instance runs

  const list = $("#devices");
  const liveText = (d) => (d.connected ? t("Connected") : d.retrying ? t("Not responding") : t("Connecting"));

  function fanIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = '<path d="M12 12c-3-5 1-9 4-7s0 5-4 7zm0 0c5-3 9 1 7 4s-5 0-7-4zm0 0c3 5-1 9-4 7s0-5 4-7zm0 0c-5 3-9-1-7-4s5 0 7 4z"/>';
    return svg;
  }

  /// Turns continuous monitoring on or off on the device: its own state, not a setting.
  async function setMonitoring(device, checkbox, slot) {
    const enabled = checkbox.checked;
    checkbox.disabled = true;
    slot.replaceChildren();
    try {
      await request("set-continuous-monitoring", { method: "POST", body: { serial: device.serial, enabled } });
      device.continuousMonitoring = enabled;
      toast(enabled ? t("Continuous monitoring enabled") : t("Continuous monitoring disabled"));
    } catch (e) {
      checkbox.checked = !enabled;
      toast(e.message || t("Failed to set continuous monitoring"), "error");
      problem(slot, e.message, "Turning continuous monitoring on or off over the local network (MQTT on port 1883) failed.", device);
    } finally {
      checkbox.disabled = false;
    }
  }

  function deviceCard(device) {
    const typeName = productTypes[device.productType] || device.model || device.productType;
    const slot = el("div", {});
    const id = `cm-${device.serial.replace(/[^a-zA-Z0-9]/g, "-")}`;
    const monitoring = el("input", { type: "checkbox", id, checked: device.continuousMonitoring === true, disabled: !device.connected });
    monitoring.addEventListener("change", () => setMonitoring(device, monitoring, slot));
    const facts = device.connected ? el("div", { class: "facts live" },
      fact(t("Fan"), device.on ? (device.autoMode ? t("Auto") : t("Speed {n}", { n: device.fanSpeed > 0 ? device.fanSpeed : "—" })) : t("Off")),
      device.temperature !== undefined ? fact(t("Temperature"), homeswift.formatTemperature(device.temperature)) : null,
      device.humidity !== undefined ? fact(t("Humidity"), `${device.humidity} %`) : null,
      device.pm25 !== undefined ? fact("PM2.5", String(device.pm25)) : null,
      device.filterLife !== undefined ? fact(t("Filter"), `${device.filterLife} %`) : null) : null;
    return el("div", { class: "card device", "data-serial": device.serial },
      el("div", { class: "device-head" },
        el("span", { class: "tile dyson", "aria-hidden": "true" }, fanIcon()),
        el("div", { class: "who" }, el("strong", { text: device.name }),
          el("div", { class: "muted", text: typeName }),
          el("div", { class: "muted mono", text: [device.serial, device.ipAddress].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${device.connected ? "on" : device.retrying ? "away" : "standby"}`, text: liveText(device) }),
        el("a", { class: "button small", href: deviceSettings(device.serial), actionIcon: "gear", text: t("Settings"),
          "aria-label": t("Settings of {name}", { name: device.name }) })),
      facts,
      el("div", { class: "toggle-row" }, el("label", { class: "switch" }, monitoring, el("span", {})),
        el("label", { htmlFor: id }, t("Continuous monitoring"), el("small", { text: t("Keep sensors active when off (required for HomeKit control while off)") }))),
      slot);
  }

  /// Redraws the cards when what the plugin reports changed; a card's monitoring switch keeps its focus otherwise.
  let shown = "";
  async function refresh() {
    let devices;
    try { devices = (await request("devices")).devices || []; } catch { return; /* the instance is restarting */ }
    const next = JSON.stringify(devices);
    if (next === shown) return;
    shown = next;
    $("#setup").replaceChildren(devices.length ? "" : homeswift.setupCard({
      title: t("Add your Dyson devices"),
      text: t("Add accessories signs in to your Dyson account (it emails a code), reads each device's local credentials and keeps them in the bridge's vault. The devices then appear here."),
      glyph: "key",
    }));
    $("#devices-section").classList.toggle("hidden", !devices.length);
    list.replaceChildren(...devices.map(deviceCard));
  }

  // MARK: Start

  $("#add-devices").href = homeswift.setupAddress({ start: true });

  (async () => {
    assistant().then((s) => { assistantOn = !!s.enabled; });
    try {
      const response = await request("get-product-types");
      if (response.success) productTypes = response.productTypes;
    } catch (e) {
      console.warn("Failed to load product types:", e);
    }
    poll(refresh, 5000);
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dyson Pure Cool page's strings and the errors its plugin answers, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Your Dyson devices and their state. Each one's options are in its Settings.": "Vos appareils Dyson et leur état. Les options de chacun sont dans ses Réglages.",
    "Add devices": "Ajouter des appareils",
    "Add your Dyson devices": "Ajoutez vos appareils Dyson",
    "Add accessories signs in to your Dyson account (it emails a code), reads each device's local credentials and keeps them in the bridge's vault. The devices then appear here.": "Ajouter des accessoires se connecte à votre compte Dyson (qui envoie un code par e-mail), lit les identifiants locaux de chaque appareil et les garde dans le coffre du pont. Les appareils apparaissent ensuite ici.",
    "Your Dyson devices": "Vos appareils Dyson",
    "Name": "Nom",
    "Settings": "Réglages",
    "Continuous monitoring": "Surveillance continue",
    "Keep sensors active when off (required for HomeKit control while off)": "Garde les capteurs actifs à l'arrêt (nécessaire pour le contrôle par HomeKit à l'arrêt)",
    "Fan": "Ventilateur",
    "Auto": "Auto",
    "Speed {n}": "Vitesse {n}",
    "Off": "Éteint",
    "Temperature": "Température",
    "Humidity": "Humidité",
    "Filter": "Filtre",
    "Connected": "Connecté",
    "Not responding": "Ne répond pas",
    "Connecting": "Connexion…",
    "Continuous monitoring enabled": "Surveillance continue activée",
    "Continuous monitoring disabled": "Surveillance continue désactivée",
    "Failed to set continuous monitoring": "Impossible de régler la surveillance continue",
    "Invalid verification code": "Code de vérification non valide",
    "Missing device info (serial, productType, localCredentials)": "Informations sur l'appareil manquantes (serial, productType, localCredentials)",
    "Device {0} not found on network": "Appareil {0} introuvable sur le réseau",
    "Failed to get device state: {0}": "Impossible de lire l'état de l'appareil : {0}",
    "Failed to set continuous monitoring: {0}": "Impossible de régler la surveillance continue : {0}",
    "Account not active or not found": "Compte inactif ou introuvable",
    "Unexpected response from Dyson": "Réponse inattendue de Dyson",
    "Session expired": "Session expirée",
    "Network error: {0}": "Erreur réseau : {0}",
    "Request timed out": "La requête a expiré",
    "Invalid response from Dyson API": "Réponse non valide de l'API Dyson",
    "A valid email address is required": "Une adresse e-mail valide est requise",
    "Password is required": "Le mot de passe est requis",
    "Verification code must be 6 digits": "Le code de vérification doit comporter 6 chiffres",
    "Country code must be a 2-letter ISO code": "Le code pays doit être un code ISO à 2 lettres",
    "ipAddress must be a valid IPv4 address": "ipAddress doit être une adresse IPv4 valide"
  },
  "es": {
    "Your Dyson devices and their state. Each one's options are in its Settings.": "Tus dispositivos Dyson y su estado. Las opciones de cada uno están en sus Ajustes.",
    "Add devices": "Añadir dispositivos",
    "Add your Dyson devices": "Añade tus dispositivos Dyson",
    "Add accessories signs in to your Dyson account (it emails a code), reads each device's local credentials and keeps them in the bridge's vault. The devices then appear here.": "Añadir accesorios inicia sesión en tu cuenta de Dyson (que envía un código por correo), lee las credenciales locales de cada dispositivo y las guarda en la bóveda del puente. Después, los dispositivos aparecen aquí.",
    "Your Dyson devices": "Tus dispositivos Dyson",
    "Name": "Nombre",
    "Settings": "Ajustes",
    "Continuous monitoring": "Monitorización continua",
    "Keep sensors active when off (required for HomeKit control while off)": "Mantiene los sensores activos con el aparato apagado (necesario para controlarlo desde HomeKit apagado)",
    "Fan": "Ventilador",
    "Auto": "Auto",
    "Speed {n}": "Velocidad {n}",
    "Off": "Apagado",
    "Temperature": "Temperatura",
    "Humidity": "Humedad",
    "Filter": "Filtro",
    "Connected": "Conectado",
    "Not responding": "No responde",
    "Connecting": "Conectando",
    "Continuous monitoring enabled": "Monitorización continua activada",
    "Continuous monitoring disabled": "Monitorización continua desactivada",
    "Failed to set continuous monitoring": "No se ha podido ajustar la monitorización continua",
    "Invalid verification code": "Código de verificación no válido",
    "Missing device info (serial, productType, localCredentials)": "Falta información del dispositivo (serial, productType, localCredentials)",
    "Device {0} not found on network": "No se ha encontrado el dispositivo {0} en la red",
    "Failed to get device state: {0}": "No se ha podido obtener el estado del dispositivo: {0}",
    "Failed to set continuous monitoring: {0}": "No se ha podido ajustar la monitorización continua: {0}",
    "Account not active or not found": "Cuenta inactiva o no encontrada",
    "Unexpected response from Dyson": "Respuesta inesperada de Dyson",
    "Session expired": "La sesión ha caducado",
    "Network error: {0}": "Error de red: {0}",
    "Request timed out": "Se ha agotado el tiempo de espera de la solicitud",
    "Invalid response from Dyson API": "Respuesta no válida de la API de Dyson",
    "A valid email address is required": "Se necesita un correo electrónico válido",
    "Password is required": "La contraseña es obligatoria",
    "Verification code must be 6 digits": "El código de verificación debe tener 6 dígitos",
    "Country code must be a 2-letter ISO code": "El código de país debe ser un código ISO de 2 letras",
    "ipAddress must be a valid IPv4 address": "ipAddress debe ser una dirección IPv4 válida"
  },
  "pt": {
    "Your Dyson devices and their state. Each one's options are in its Settings.": "Os seus dispositivos Dyson e o seu estado. As opções de cada um estão nas suas Definições.",
    "Add devices": "Adicionar dispositivos",
    "Add your Dyson devices": "Adicione os seus dispositivos Dyson",
    "Add accessories signs in to your Dyson account (it emails a code), reads each device's local credentials and keeps them in the bridge's vault. The devices then appear here.": "Adicionar acessórios inicia sessão na sua conta Dyson (que envia um código por e-mail), lê as credenciais locais de cada dispositivo e guarda-as no cofre da ponte. Os dispositivos aparecem depois aqui.",
    "Your Dyson devices": "Os seus dispositivos Dyson",
    "Name": "Nome",
    "Settings": "Definições",
    "Continuous monitoring": "Monitorização contínua",
    "Keep sensors active when off (required for HomeKit control while off)": "Mantém os sensores ativos com o aparelho desligado (necessário para o controlo pelo HomeKit quando desligado)",
    "Fan": "Ventoinha",
    "Auto": "Auto",
    "Speed {n}": "Velocidade {n}",
    "Off": "Desligado",
    "Temperature": "Temperatura",
    "Humidity": "Humidade",
    "Filter": "Filtro",
    "Connected": "Ligado",
    "Not responding": "Não responde",
    "Connecting": "A ligar",
    "Continuous monitoring enabled": "Monitorização contínua ativada",
    "Continuous monitoring disabled": "Monitorização contínua desativada",
    "Failed to set continuous monitoring": "Não foi possível definir a monitorização contínua",
    "Invalid verification code": "Código de verificação inválido",
    "Missing device info (serial, productType, localCredentials)": "Faltam informações do dispositivo (serial, productType, localCredentials)",
    "Device {0} not found on network": "Dispositivo {0} não encontrado na rede",
    "Failed to get device state: {0}": "Não foi possível obter o estado do dispositivo: {0}",
    "Failed to set continuous monitoring: {0}": "Não foi possível definir a monitorização contínua: {0}",
    "Account not active or not found": "Conta inativa ou não encontrada",
    "Unexpected response from Dyson": "Resposta inesperada da Dyson",
    "Session expired": "A sessão expirou",
    "Network error: {0}": "Erro de rede: {0}",
    "Request timed out": "O pedido expirou",
    "Invalid response from Dyson API": "Resposta inválida da API da Dyson",
    "A valid email address is required": "É necessário um endereço de e-mail válido",
    "Password is required": "A palavra-passe é obrigatória",
    "Verification code must be 6 digits": "O código de verificação tem de ter 6 dígitos",
    "Country code must be a 2-letter ISO code": "O código do país tem de ser um código ISO de 2 letras",
    "ipAddress must be a valid IPv4 address": "ipAddress tem de ser um endereço IPv4 válido"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dyson Pure Cool</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's setup wizard on the UI's materials, without its sign-in (Setup's) or its settings (the
     Settings page's): the devices this instance runs, with their live state. */
  .page-head { align-items: center; }
  .tile.dyson { background: linear-gradient(160deg, #c3c9d6, #6f7a8f); }
  .status-line { margin: 14px 0 0; min-height: 1.2em; }
  .status-line.error { color: var(--error); }
  .status-line.ok { color: var(--ok); }

  .devices { display: grid; gap: 10px; }
  .device { margin: 0; display: grid; gap: 12px; animation: materialize var(--normal) var(--ease-out); }
  .device-head { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px; min-width: 0; }
  .device-head .who { flex: 1; min-width: 0; }
  .device-head .muted { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .toggle-row { display: flex; align-items: center; gap: 12px; }
  .toggle-row label:last-child { margin: 0; }
  .toggle-row small { display: block; color: var(--muted); font-size: 0.75rem; }
  .device-problem { font-size: 0.8125rem; color: var(--warn); }
  .facts.live { grid-template-columns: repeat(auto-fill, minmax(110px, 1fr)); }
  @media (prefers-reduced-motion: reduce) { .device { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large dyson" aria-hidden="true"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" opacity="0.35"/><circle cx="12" cy="12" r="6" opacity="0.6"/><circle cx="12" cy="12" r="3"/></svg></span>
    <div class="who">
      <h1>Dyson Pure Cool</h1>
      <p class="muted" data-i18n>Your Dyson devices and their state. Each one's options are in its Settings.</p>
    </div>
  </div>
  <div id="setup"></div>
  <section id="devices-section" class="hidden">
    <div class="section-head"><h2 data-i18n>Your Dyson devices</h2><div class="actions"><a id="add-devices" class="button" data-i18n data-action-icon="plus">Add devices</a></div></div>
    <div id="devices" class="devices"></div>
    <p id="status-line" class="status-line muted" role="status"></p>
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
