// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension UniFiAccessPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Access page: the controllers this instance runs, each with its status and its hubs and readers, and where
// to set up another (Add accessories, which signs in to it). It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): a controller's, a device's and the plugin's open the Settings pages.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, setupCard } = homeswift;
  const { t, tn } = HomeswiftI18n;

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

  // MARK: Where settings are edited: the plugin's Settings page, and each controller's or device's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const settingsOf = (deviceID) => `${pluginSettings}?accessory=${encodeURIComponent(`UniFi Access:${String(deviceID).toUpperCase()}`)}`;

  function show(id) {
    for (const screen of ["controllers-screen", "support-screen"]) $(`#${screen}`).classList.toggle("hidden", screen !== id);
    window.scrollTo({ top: 0, behavior: reducedMotion.matches ? "auto" : "smooth" });
  }

  // MARK: Controllers

  async function renderControllers() {
    const list = $("#controllers");
    let live = [];
    try {
      ({ controllers: live } = await request("controllers"));
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
      return;
    }
    const setup = setupCard({
      title: live.length ? t("Another controller") : t("No controller yet"),
      text: t("Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account."),
    });
    list.replaceChildren(...live.map(controllerCard), setup);
  }

  function controllerCard(ctrl) {
    const status = el("span", { class: "pill status standby", text: t("Checking…") });
    const slot = el("div");
    const devices = ctrl.devices ?? [];
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("inputs")),
        el("div", { class: "who" }, el("strong", { text: ctrl.name || ctrl.address }), el("div", { class: "muted", text: ctrl.address })),
        status),
      slot,
      devices.length ? el("div", { class: "found" }, devices.map(deviceRow)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: ctrl.connected ? tn("Connected · {n} device in HomeKit", "Connected · {n} devices in HomeKit", devices.length) : t("Not connected yet: see the log.") }),
        ctrl.mac ? el("a", { class: "button", href: settingsOf(ctrl.mac), actionIcon: "gear", text: t("Settings") }) : null));
    request("status", { method: "POST", body: { address: ctrl.address } }).then((result) => {
      status.className = `pill status ${result.online ? "on" : "away"}`;
      status.textContent = result.online ? t("Online") : t("Offline");
      if (!result.online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server), so it is shown as Offline.",
          context: "The user is looking at the UniFi Access controllers the plugin runs in its page.",
          device: { name: ctrl.name, connected: ctrl.connected },
        }));
      }
    }).catch(() => {
      status.className = "pill status standby";
      status.textContent = t("Unknown");
    });
    return card;
  }

  /// A hub or a reader of a controller: its state, and its Settings.
  function deviceRow(device) {
    const state = [device.model, device.online ? t("Online") : t("Disconnected")];
    if (device.locked !== undefined) state.push(device.locked ? t("Locked") : t("Unlocked"));
    return el("div", { class: "card item" },
      el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("lock")),
      el("div", {}, el("strong", { text: device.name }), el("div", { class: "muted", text: state.filter(Boolean).join(" · ") })),
      el("a", { class: "button", href: settingsOf(device.featureId), actionIcon: "gear", text: t("Settings") }));
  }

  $("#plugin-settings").href = pluginSettings;
  $("#open-support").addEventListener("click", () => { show("support-screen"); breadcrumb(t("Support"), backToControllers); });
  $("#back-from-support").addEventListener("click", backToControllers);

  function backToControllers() {
    breadcrumb(null);
    show("controllers-screen");
    renderControllers();
  }

  // MARK: Sentences of the page with elements in them (links, code): the translation's {0}, {1}… are the
  // element's children, in order. The links have data-i18n for their own text.

  function sentence(node, text) {
    const parts = [...node.children];
    node.replaceChildren(...text.split(/\{(\d+)\}/).map((part, i) => (i % 2 ? parts[Number(part)] : part)));
  }
  sentence($("#support-about"), t("A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub."));
  sentence($("#support-readme"), t("{0} in Homeswift, and what differs from Homebridge."));
  sentence($("#support-options"), t("{0}: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin."));
  sentence($("#support-mqtt"), t("{0}: the topics published and accepted."));
  sentence($("#support-changelog"), t("{0} of the Homebridge plugin this one follows."));
  sentence($("#support-discord"), t("{0} of the UniFi plugins."));
  sentence($("#support-issues"), t("{0} for the Homebridge plugin's behaviour, or {1} for this port."));

  // MARK: Start

  show("controllers-screen");
  renderControllers();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Access page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Gérez vos contrôleurs et appareils UniFi Access dans HomeKit.",
    "Support": "Assistance",
    "Feature options": "Options des fonctions",
    "Back": "Retour",
    "About this plugin": "À propos de ce plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Un portage de {0} vers {1}. S'il vous est utile, pensez à mettre une étoile aux projets sur GitHub.",
    "Getting started": "Premiers pas",
    "Installation and configuration": "Installation et configuration",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} dans Homeswift, et ce qui diffère de Homebridge.",
    "{0}: the topics published and accepted.": "{0} : les sujets publiés et acceptés.",
    "Changelog": "Historique des versions",
    "{0} of the Homebridge plugin this one follows.": "{0} du plugin Homebridge que celui-ci suit.",
    "Get help": "Obtenir de l'aide",
    "Discord support channel": "Canal d'assistance Discord",
    "{0} of the UniFi plugins.": "{0} des plugins UniFi.",
    "Create a developer support request": "Créez une demande d'assistance aux développeurs",
    "open an issue on Homeswift": "ouvrez un ticket sur Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} pour le comportement du plugin Homebridge, ou {1} pour ce portage.",
    "Checking…": "Vérification…",
    "Connected · {n} device in HomeKit": "Connecté · {n} appareil dans HomeKit",
    "Connected · {n} devices in HomeKit": "Connecté · {n} appareils dans HomeKit",
    "Not connected yet: see the log.": "Pas encore connecté : consultez le journal.",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Unknown": "Inconnu",
    "Disconnected": "Déconnecté",
    "Invalid controller address. Please provide a valid network address.": "Adresse du contrôleur non valide. Indiquez une adresse réseau valide.",
    "Controllers": "Contrôleurs",
    "Settings for every device": "Réglages de tous les appareils",
    "Another controller": "Un autre contrôleur",
    "No controller yet": "Aucun contrôleur pour l'instant",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Ajouter des accessoires trouve les consoles UniFi du réseau, ou l'une par son adresse, et s'y connecte avec un compte local.",
    "Settings": "Réglages",
    "Locked": "Verrouillée",
    "Unlocked": "Déverrouillée",
    "{0}: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin.": "{0} : ce qu'était chaque réglage du plugin et de ses appareils dans le plugin Homebridge."
  },
  "es": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Gestiona tus controladores y dispositivos UniFi Access en HomeKit.",
    "Support": "Soporte",
    "Feature options": "Opciones de funciones",
    "Back": "Volver",
    "About this plugin": "Acerca de este plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Una adaptación de {0} a {1}. Si te resulta útil, plantéate dar una estrella a los proyectos en GitHub.",
    "Getting started": "Primeros pasos",
    "Installation and configuration": "Instalación y configuración",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} en Homeswift y lo que cambia respecto a Homebridge.",
    "{0}: the topics published and accepted.": "{0}: los temas publicados y aceptados.",
    "Changelog": "Historial de cambios",
    "{0} of the Homebridge plugin this one follows.": "{0} del plugin de Homebridge que este sigue.",
    "Get help": "Obtener ayuda",
    "Discord support channel": "Canal de soporte en Discord",
    "{0} of the UniFi plugins.": "{0} de los plugins de UniFi.",
    "Create a developer support request": "Crea una solicitud de soporte a los desarrolladores",
    "open an issue on Homeswift": "abre una incidencia en Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} sobre el comportamiento del plugin de Homebridge, o {1} sobre esta adaptación.",
    "Checking…": "Comprobando…",
    "Connected · {n} device in HomeKit": "Conectado · {n} dispositivo en HomeKit",
    "Connected · {n} devices in HomeKit": "Conectado · {n} dispositivos en HomeKit",
    "Not connected yet: see the log.": "Aún sin conectar: consulta el registro.",
    "Online": "Conectado",
    "Offline": "Desconectado",
    "Unknown": "Desconocido",
    "Disconnected": "Desconectado",
    "Invalid controller address. Please provide a valid network address.": "La dirección del controlador no es válida. Indica una dirección de red válida.",
    "Controllers": "Controladores",
    "Settings for every device": "Ajustes de todos los dispositivos",
    "Another controller": "Otro controlador",
    "No controller yet": "Todavía no hay ningún controlador",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Añadir accesorios encuentra las consolas UniFi de la red, o una por su dirección, e inicia sesión en ella con una cuenta local.",
    "Settings": "Ajustes",
    "Locked": "Bloqueada",
    "Unlocked": "Desbloqueada",
    "{0}: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin.": "{0}: lo que era cada ajuste del plugin y de sus dispositivos en el plugin de Homebridge."
  },
  "pt": {
    "Manage your UniFi Access controllers and devices in HomeKit.": "Faça a gestão dos controladores e dispositivos UniFi Access no HomeKit.",
    "Support": "Suporte",
    "Feature options": "Opções de funcionalidades",
    "Back": "Voltar",
    "About this plugin": "Acerca deste plugin",
    "A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub.": "Uma adaptação de {0} para {1}. Se lhe for útil, considere dar uma estrela aos projetos no GitHub.",
    "Getting started": "Primeiros passos",
    "Installation and configuration": "Instalação e configuração",
    "{0} in Homeswift, and what differs from Homebridge.": "{0} no Homeswift e o que difere do Homebridge.",
    "{0}: the topics published and accepted.": "{0}: os tópicos publicados e aceites.",
    "Changelog": "Histórico de alterações",
    "{0} of the Homebridge plugin this one follows.": "{0} do plugin do Homebridge que este segue.",
    "Get help": "Obter ajuda",
    "Discord support channel": "Canal de suporte no Discord",
    "{0} of the UniFi plugins.": "{0} dos plugins UniFi.",
    "Create a developer support request": "Crie um pedido de suporte aos programadores",
    "open an issue on Homeswift": "abra um problema no Homeswift",
    "{0} for the Homebridge plugin's behaviour, or {1} for this port.": "{0} sobre o comportamento do plugin do Homebridge, ou {1} sobre esta adaptação.",
    "Checking…": "A verificar…",
    "Connected · {n} device in HomeKit": "Ligado · {n} dispositivo no HomeKit",
    "Connected · {n} devices in HomeKit": "Ligado · {n} dispositivos no HomeKit",
    "Not connected yet: see the log.": "Ainda não ligado: consulte o registo.",
    "Online": "Online",
    "Offline": "Offline",
    "Unknown": "Desconhecido",
    "Disconnected": "Desligado",
    "Invalid controller address. Please provide a valid network address.": "Endereço do controlador inválido. Indique um endereço de rede válido.",
    "Controllers": "Controladores",
    "Settings for every device": "Definições de todos os dispositivos",
    "Another controller": "Outro controlador",
    "No controller yet": "Ainda sem controlador",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Adicionar acessórios encontra as consolas UniFi da rede, ou uma pelo seu endereço, e inicia sessão nela com uma conta local.",
    "Settings": "Definições",
    "Locked": "Trancada",
    "Unlocked": "Destrancada",
    "{0}: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin.": "{0}: o que era cada definição do plugin e dos seus dispositivos no plugin do Homebridge."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UniFi Access</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The controllers with their hubs and readers, and the support links, one screen showing at a time. Settings are
     edited on the Settings pages, controllers set up in Add accessories. */

  .screen { animation: fade var(--normal) var(--ease-out); }
  .page-head { align-items: center; }
  .controllers { display: grid; gap: 10px; }
  .controller { margin: 0; display: grid; gap: 10px; }
  .controller-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .controller-head .who { flex: 1; min-width: 0; }
  .controller-head strong { display: block; font-size: 1.0625rem; letter-spacing: -0.01em; overflow-wrap: anywhere; }
  .controller-head .muted { font-size: 0.8125rem; overflow-wrap: anywhere; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  .found { display: grid; gap: 8px; margin: 14px 0 0; }
  .found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; cursor: pointer; width: 100%; text-align: left; font: inherit; color: inherit; }
  .found .item div { flex: 1; min-width: 0; }
  .found .item .muted { font-size: 0.8125rem; }
  .note-box { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.875rem; }
  .support a { color: var(--accent); }
  .support li { margin: 6px 0; }

  .found .item { cursor: default; }
  @media (prefers-reduced-motion: reduce) { .screen { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M5 21V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v17"/><path d="M3 21h18"/><circle cx="15" cy="12.5" r="1"/></svg></span>
    <div>
      <h1>UniFi Access</h1>
      <p class="muted" data-i18n>Manage your UniFi Access controllers and devices in HomeKit.</p>
    </div>
  </div>

  <!-- Controllers -->
  <section id="controllers-screen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Controllers</h2></div>
    <div id="controllers" class="controllers"></div>
    <div class="actions" style="margin-top: 14px">
      <a class="button" id="plugin-settings" data-i18n data-action-icon="gear">Settings for every device</a>
      <button id="open-support" data-i18n data-action-icon="link">Support</button>
    </div>
  </section>

  <!-- Support -->
  <section id="support-screen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Support</h2><button class="link" id="back-from-support" data-i18n data-action-icon="restore">Back</button></div>
    <div class="card support">
      <h2 style="margin-top: 0" data-i18n>About this plugin</h2>
      <p id="support-about">A port of <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access">homebridge-unifi-access</a> to <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift">Homeswift</a>. If you find it useful, consider starring the projects on GitHub.</p>
      <h2 data-i18n>Getting started</h2>
      <ul>
        <li id="support-readme"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/blob/main/Plugins/UniFiAccess/README.md" data-i18n>Installation and configuration</a> in Homeswift, and what differs from Homebridge.</li>
        <li id="support-options"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/FeatureOptions.md" data-i18n>Feature options</a>: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin.</li>
        <li id="support-mqtt"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/docs/MQTT.md">MQTT</a>: the topics published and accepted.</li>
        <li id="support-changelog"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/blob/main/CHANGELOG.md" data-i18n>Changelog</a> of the Homebridge plugin this one follows.</li>
      </ul>
      <h2 data-i18n>Get help</h2>
      <ul>
        <li id="support-discord"><a target="_blank" rel="noopener noreferrer" href="https://discord.gg/QXqfHEW" data-i18n>Discord support channel</a> of the UniFi plugins.</li>
        <li id="support-issues"><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-access/issues/new/choose" data-i18n>Create a developer support request</a> for the Homebridge plugin's behaviour, or <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homeswift/issues/new" data-i18n>open an issue on Homeswift</a> for this port.</li>
      </ul>
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
