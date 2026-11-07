// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension XiaomiMiotPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Xiaomi page: the devices this instance runs (refreshed every few seconds while the page is visible), and for one
// device its MIoT spec read now: every property with its value and a control for the writable ones (a switch for a
// bool, a menu for a value list, a number for a range), and a button for each action without parameters
// (docs/clean-room/XiaomiMiot.md section 15.9). Signing in is Setup's (Add accessories); settings are the Settings page's.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, poll, renderKeyed, setupCard, drawHidden } = homeswift;

  const list = $("#devices");
  const panel = $("#spec-panel");
  $("#settings-link").href = homeswift.settingsAddress;
  const settingsOf = (accessoryID) => homeswift.accessorySettings(accessoryID);
  const kindIcons = { light: "bulb", outlet: "outlet", switch: "switch", airPurifier: "wind", humidifier: "drop", dehumidifier: "drop", fan: "fan",
    ceilingFan: "fan", heater: "flame", airConditioner: "thermo", curtain: "blind", sensor: "sensor", airMonitor: "sensor", vacuum: "vacuum" };

  function deviceCard(device) {
    const [state, kind] = device.problem ? [t("Not published"), "away"] : device.reachable ? [t("Responding"), "on"] : [t("Not responding"), "away"];
    return el("div", { class: `card device${device.reachable ? "" : " is-offline"}` },
      el("div", { class: "server-head" },
        tile(kindIcons[device.kind] || "generic", device.reachable ? "orange" : "grey"),
        el("div", { class: "who" }, el("strong", { class: "device-name", text: device.name, title: device.name }), el("div", { class: "muted", text: [device.model, device.deviceId].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts" },
        fact(t("Address"), device.ip || "—"),
        fact(t("Firmware"), device.firmware || "—"),
        fact(t("Commands"), device.path === "legacy" ? t("miIO vacuum") : "MIoT")),
      device.problem ? el("p", { class: "muted note", text: HomeswiftI18n.message(device.problem) }) : null,
      !device.reachable && !device.problem ? explain({
        error: `The Xiaomi device ${device.name} does not answer at ${device.ip}.`,
        context: "The Homeswift plugin reaches each device over miIO on UDP port 54321 with its token, polls it, and retries a device that missed 4 polls.",
        device: { model: device.model, path: device.path },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted urn", text: device.spec || "" }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: device.name }), () => [
          device.spec && device.reachable ? { label: t("Properties"), icon: "sliders", onSelect: () => openSpec(device) } : null,
          { label: t("Settings"), icon: "gear", href: settingsOf(device.accessoryId) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(device.accessoryId)}` },
        ])));
  }

  const shown = new Set();
  function card(device) {
    const node = deviceCard(device);
    if (shown.has(device.deviceId)) node.classList.add("redrawn");
    shown.add(device.deviceId);
    return node;
  }

  // The account's card, drawn again only when that changes.
  let accountShown;

  async function refresh() {
    try {
      const { devices, excluded = [], accountSetUp } = await request("devices");
      if (accountSetUp !== accountShown) {
        accountShown = accountSetUp;
        $("#account").replaceChildren(accountSetUp ? "" : setupCard({
          title: t("Your Xiaomi account"),
          text: t("Optional: signing in finds your devices and their tokens. Devices added with a token work without it."),
        }));
      }
      drawHidden($("#excluded"), excluded.map((device) => device.name), (name) => {
        const device = excluded.find((entry) => entry.name === name);
        if (device) location.href = settingsOf(device.accessoryId);
      });
      if (devices.length === 0) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No device yet. Add one from Add accessories: from your Xiaomi account, found on the network, or by its address and token.") })));
        }
        return;
      }
      // The last poll's time changes every poll: left out, a card is drawn again only when what it shows changed.
      renderKeyed(list, devices.map(({ lastPoll, ...device }) => device), (device) => device.deviceId, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: A device's spec

  // The spec's units as people write them; a unit not here is shown as the spec names it.
  const units = { percentage: "%", celsius: "°C", fahrenheit: "°F", kelvin: "K", seconds: "s", minutes: "min", hours: "h", days: "d",
    lux: "lx", ppm: "ppm", ppb: "ppb", "μg/m3": "µg/m³", "mg/m3": "mg/m³", watt: "W", kWh: "kWh", pascal: "Pa", metre: "m", arcdegrees: "°" };
  const hex = (rgb) => `#${Math.max(0, Math.min(0xffffff, Number(rgb) || 0)).toString(16).padStart(6, "0").toUpperCase()}`;

  function describeValue(property, value) {
    if (value === null || value === undefined) return "—";
    if (property.format === "bool") return value ? t("On") : t("Off");
    if (property.unit === "rgb") return hex(value);
    const entry = (property.values || []).find((item) => item.value === value);
    const text = entry && entry.description ? `${entry.description} (${value})` : typeof value === "number" ? value.toLocaleString(HomeswiftI18n.locale) : String(value);
    if (!property.unit || property.unit === "none") return text;
    const unit = units[property.unit] || property.unit;
    return unit === "%" ? `${text} %` : `${text} ${unit}`;
  }

  async function write(device, property, value, row) {
    try {
      await request("set_property", { method: "POST", body: { did: device.deviceId, property: property.id, value } });
      row.querySelector(".value").textContent = describeValue(property, value);
    } catch (e) {
      HomeswiftCommon.showAlert(e.message);
    }
  }

  function control(device, property, row) {
    if (!property.access.includes("write")) return null;
    const label = t("Change {name}", { name: property.description || property.name });
    if (property.format === "bool") {
      const box = el("input", { type: "checkbox", "aria-label": label });
      box.checked = property.value === true;
      box.addEventListener("change", () => write(device, property, box.checked, row));
      return el("label", { class: "switch" }, box, el("span", {}));
    }
    if (property.unit === "rgb") {
      const picker = el("input", { type: "color", value: hex(property.value).toLowerCase(), "aria-label": label });
      picker.addEventListener("change", () => write(device, property, parseInt(picker.value.slice(1), 16), row));
      return picker;
    }
    if (property.values && property.values.length) {
      const select = el("select", { "aria-label": label },
        ...property.values.map((item) => el("option", { value: JSON.stringify(item.value), text: item.description || String(item.value) })));
      select.value = JSON.stringify(property.value);
      select.addEventListener("change", () => write(device, property, JSON.parse(select.value), row));
      return select;
    }
    if (property.range) {
      const [min, max, step] = property.range;
      const input = el("input", { type: "number", min, max, step: step || 1, value: property.value ?? "", "aria-label": label });
      input.addEventListener("change", () => write(device, property, Number(input.value), row));
      return input;
    }
    return null;
  }

  function propertyRow(device, property) {
    const row = el("div", { class: "prop" },
      el("div", { class: "who" }, el("div", { text: property.description || property.name }), el("code", { class: "muted", text: `${property.name} · ${property.id}` })),
      el("span", { class: "value", text: property.access.includes("read") ? describeValue(property, property.value) : t("Write only") }));
    const input = control(device, property, row);
    if (input) row.append(input);
    return row;
  }

  function actionRow(device, action) {
    const button = el("button", { actionIcon: "play", text: t("Run") });
    button.addEventListener("click", () => HomeswiftCommon.busyButton(button, () => request("run_action", { method: "POST", body: { did: device.deviceId, action: action.id } })));
    return el("div", { class: "prop" },
      el("div", { class: "who" }, el("div", { text: action.description || action.name }), el("code", { class: "muted", text: `${action.name} · ${action.id}` })),
      action.in.length === 0 ? button : el("span", { class: "muted", text: t("Takes parameters: use actionButtons in its settings") }));
  }

  // Specs often describe a service in lower case ("light").
  const capitalized = (text) => text ? text.charAt(0).toUpperCase() + text.slice(1) : text;

  async function openSpec(device) {
    panel.classList.remove("hidden");
    panel.replaceChildren(el("p", { class: "muted", text: t("Reading {name}…", { name: device.name }) }));
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
    try {
      const { services } = await request(`properties?did=${encodeURIComponent(device.deviceId)}`);
      panel.replaceChildren(
        el("div", { class: "section-head" }, el("h2", { text: device.name }),
          el("div", { class: "actions" },
            el("button", { actionIcon: "restore", text: t("Refresh"), onclick: () => openSpec(device) }),
            el("button", { actionIcon: "close", text: t("Close"), onclick: () => panel.classList.add("hidden") }))),
        el("div", { class: "spec" }, ...services.map((service) => el("div", {},
          el("h3", {}, capitalized(service.description || service.name), service.standard ? "" : el("span", { class: "muted vendor", text: ` · ${t("vendor")}` })),
          ...service.properties.map((property) => propertyRow(device, property)),
          ...service.actions.map((action) => actionRow(device, action))))));
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  poll(refresh, 5000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Xiaomi page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "On": "Allumé",
    "Off": "Éteint",
    "property is required, as text": "la propriété est requise, sous forme de texte",
    "The device did not say its model: set its model in its settings.": "L’appareil n’a pas indiqué son modèle : renseignez son modèle dans ses réglages.",
    "miot-spec.org did not give the spec of {0}, and none is kept: Homeswift tries again at the next connection.": "miot-spec.org n’a pas donné la spécification de {0}, et aucune n’est conservée : Homeswift réessaie à la prochaine connexion.",
    "{0} does not answer MIoT on the local network: it needs the Xiaomi cloud, which this plugin does not use yet.": "{0} ne répond pas en MIoT sur le réseau local : il a besoin du cloud Xiaomi, que ce plugin n’utilise pas encore.",
    "{0} devices are not supported.": "Les appareils {0} ne sont pas pris en charge.",
    "Nothing of this device maps to HomeKit: add what you want with propertyControl in its settings.": "Rien de cet appareil ne correspond à HomeKit : ajoutez ce que vous voulez avec propertyControl dans ses réglages.",
    "Your Mi Home devices on the local network. Properties shows everything a device's spec has, including what HomeKit does not show, and lets you change it.": "Vos appareils Mi Home sur le réseau local. Propriétés affiche tout ce que la spécification d’un appareil contient, y compris ce que HomeKit n’affiche pas, et permet de le modifier.",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Extra switches (buzzer, LED, modes, fan levels) are off by default: turn them on in a device's settings.": "Les interrupteurs supplémentaires (bip, voyant, modes, vitesses) sont désactivés par défaut : activez-les dans les réglages d’un appareil.",
    "Not published": "Non publié",
    "Responding": "Répond",
    "Not responding": "Ne répond pas",
    "Address": "Adresse",
    "Firmware": "Firmware",
    "Commands": "Commandes",
    "miIO vacuum": "Aspirateur miIO",
    "Actions for {name}": "Actions pour {name}",
    "Properties": "Propriétés",
    "Show its log": "Afficher son journal",
    "Your Xiaomi account": "Votre compte Xiaomi",
    "Optional: signing in finds your devices and their tokens. Devices added with a token work without it.": "Facultatif : la connexion trouve vos appareils et leurs jetons. Les appareils ajoutés avec un jeton fonctionnent sans elle.",
    "No device yet. Add one from Add accessories: from your Xiaomi account, found on the network, or by its address and token.": "Aucun appareil pour l’instant. Ajoutez-en un depuis Ajouter des accessoires : depuis votre compte Xiaomi, trouvé sur le réseau, ou par son adresse et son jeton.",
    "Change {name}": "Modifier {name}",
    "Write only": "Écriture seule",
    "Run": "Lancer",
    "Takes parameters: use actionButtons in its settings": "Prend des paramètres : utilisez actionButtons dans ses réglages",
    "Reading {name}…": "Lecture de {name}…",
    "Refresh": "Actualiser",
    "Close": "Fermer",
    "vendor": "fabricant",
    "property is required": "la propriété est requise",
    "value is required": "la valeur est requise",
    "action is required": "l’action est requise",
    "did is required": "le did est requis",
    "Not found": "Introuvable",
    "No running device has the did {0}": "Aucun appareil en marche n’a le did {0}",
    "{0} has no MIoT spec": "{0} n’a pas de spécification MIoT",
    "{0} is not responding": "{0} ne répond pas",
    "{0} has no property {1}": "{0} n’a pas de propriété {1}",
    "{0} has no action {1}": "{0} n’a pas d’action {1}",
    "{0} cannot be written": "{0} ne peut pas être modifiée",
    "{0} did not take {1}": "{0} n’a pas accepté {1}",
    "{0} did not run {1}": "{0} n’a pas lancé {1}",
  },
  "es": {
    "On": "Encendido",
    "Off": "Apagado",
    "property is required, as text": "la propiedad es obligatoria, como texto",
    "The device did not say its model: set its model in its settings.": "El dispositivo no indicó su modelo: indica su modelo en sus ajustes.",
    "miot-spec.org did not give the spec of {0}, and none is kept: Homeswift tries again at the next connection.": "miot-spec.org no dio la especificación de {0}, y no se guarda ninguna: Homeswift lo vuelve a intentar en la próxima conexión.",
    "{0} does not answer MIoT on the local network: it needs the Xiaomi cloud, which this plugin does not use yet.": "{0} no responde a MIoT en la red local: necesita la nube de Xiaomi, que este plugin aún no usa.",
    "{0} devices are not supported.": "Los dispositivos {0} no son compatibles.",
    "Nothing of this device maps to HomeKit: add what you want with propertyControl in its settings.": "Nada de este dispositivo corresponde a HomeKit: añade lo que quieras con propertyControl en sus ajustes.",
    "Your Mi Home devices on the local network. Properties shows everything a device's spec has, including what HomeKit does not show, and lets you change it.": "Tus dispositivos Mi Home en la red local. Propiedades muestra todo lo que tiene la especificación de un dispositivo, también lo que HomeKit no muestra, y te deja cambiarlo.",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Extra switches (buzzer, LED, modes, fan levels) are off by default: turn them on in a device's settings.": "Los interruptores adicionales (pitido, LED, modos, niveles de ventilador) están desactivados por defecto: actívalos en los ajustes de un dispositivo.",
    "Not published": "No publicado",
    "Responding": "Responde",
    "Not responding": "No responde",
    "Address": "Dirección",
    "Firmware": "Firmware",
    "Commands": "Órdenes",
    "miIO vacuum": "Aspirador miIO",
    "Actions for {name}": "Acciones de {name}",
    "Properties": "Propiedades",
    "Show its log": "Ver su registro",
    "Your Xiaomi account": "Tu cuenta de Xiaomi",
    "Optional: signing in finds your devices and their tokens. Devices added with a token work without it.": "Opcional: al iniciar sesión se encuentran tus dispositivos y sus tokens. Los dispositivos añadidos con un token funcionan sin ella.",
    "No device yet. Add one from Add accessories: from your Xiaomi account, found on the network, or by its address and token.": "Aún no hay dispositivos. Añade uno desde Añadir accesorios: desde tu cuenta de Xiaomi, encontrado en la red, o por su dirección y su token.",
    "Change {name}": "Cambiar {name}",
    "Write only": "Solo escritura",
    "Run": "Ejecutar",
    "Takes parameters: use actionButtons in its settings": "Necesita parámetros: usa actionButtons en sus ajustes",
    "Reading {name}…": "Leyendo {name}…",
    "Refresh": "Actualizar",
    "Close": "Cerrar",
    "vendor": "fabricante",
    "property is required": "la propiedad es obligatoria",
    "value is required": "el valor es obligatorio",
    "action is required": "la acción es obligatoria",
    "did is required": "el did es obligatorio",
    "Not found": "No encontrado",
    "No running device has the did {0}": "Ningún dispositivo en marcha tiene el did {0}",
    "{0} has no MIoT spec": "{0} no tiene especificación MIoT",
    "{0} is not responding": "{0} no responde",
    "{0} has no property {1}": "{0} no tiene la propiedad {1}",
    "{0} has no action {1}": "{0} no tiene la acción {1}",
    "{0} cannot be written": "{0} no se puede cambiar",
    "{0} did not take {1}": "{0} no aceptó {1}",
    "{0} did not run {1}": "{0} no ejecutó {1}",
  },
  "pt": {
    "On": "Ligado",
    "Off": "Desligado",
    "property is required, as text": "a propriedade é obrigatória, como texto",
    "The device did not say its model: set its model in its settings.": "O dispositivo não indicou o modelo: indique o modelo nas definições.",
    "miot-spec.org did not give the spec of {0}, and none is kept: Homeswift tries again at the next connection.": "O miot-spec.org não deu a especificação de {0}, e nenhuma está guardada: o Homeswift tenta de novo na próxima ligação.",
    "{0} does not answer MIoT on the local network: it needs the Xiaomi cloud, which this plugin does not use yet.": "{0} não responde a MIoT na rede local: precisa da nuvem Xiaomi, que este plugin ainda não usa.",
    "{0} devices are not supported.": "Os dispositivos {0} não são suportados.",
    "Nothing of this device maps to HomeKit: add what you want with propertyControl in its settings.": "Nada deste dispositivo corresponde ao HomeKit: adicione o que quiser com propertyControl nas definições.",
    "Your Mi Home devices on the local network. Properties shows everything a device's spec has, including what HomeKit does not show, and lets you change it.": "Os seus dispositivos Mi Home na rede local. Propriedades mostra tudo o que a especificação de um dispositivo tem, incluindo o que o HomeKit não mostra, e permite alterá-lo.",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Extra switches (buzzer, LED, modes, fan levels) are off by default: turn them on in a device's settings.": "Os interruptores adicionais (sinal sonoro, LED, modos, níveis de ventilação) estão desativados por omissão: ative-os nas definições de um dispositivo.",
    "Not published": "Não publicado",
    "Responding": "Responde",
    "Not responding": "Não responde",
    "Address": "Endereço",
    "Firmware": "Firmware",
    "Commands": "Comandos",
    "miIO vacuum": "Aspirador miIO",
    "Actions for {name}": "Ações de {name}",
    "Properties": "Propriedades",
    "Show its log": "Ver o registo",
    "Your Xiaomi account": "A sua conta Xiaomi",
    "Optional: signing in finds your devices and their tokens. Devices added with a token work without it.": "Opcional: iniciar sessão encontra os seus dispositivos e os respetivos tokens. Os dispositivos adicionados com um token funcionam sem ela.",
    "No device yet. Add one from Add accessories: from your Xiaomi account, found on the network, or by its address and token.": "Ainda não há dispositivos. Adicione um em Adicionar acessórios: a partir da sua conta Xiaomi, encontrado na rede, ou pelo endereço e token.",
    "Change {name}": "Alterar {name}",
    "Write only": "Só escrita",
    "Run": "Executar",
    "Takes parameters: use actionButtons in its settings": "Precisa de parâmetros: use actionButtons nas definições",
    "Reading {name}…": "A ler {name}…",
    "Refresh": "Atualizar",
    "Close": "Fechar",
    "vendor": "fabricante",
    "property is required": "a propriedade é obrigatória",
    "value is required": "o valor é obrigatório",
    "action is required": "a ação é obrigatória",
    "did is required": "o did é obrigatório",
    "Not found": "Não encontrado",
    "No running device has the did {0}": "Nenhum dispositivo em funcionamento tem o did {0}",
    "{0} has no MIoT spec": "{0} não tem especificação MIoT",
    "{0} is not responding": "{0} não responde",
    "{0} has no property {1}": "{0} não tem a propriedade {1}",
    "{0} has no action {1}": "{0} não tem a ação {1}",
    "{0} cannot be written": "{0} não pode ser alterada",
    "{0} did not take {1}": "{0} não aceitou {1}",
    "{0} did not run {1}": "{0} não executou {1}",
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Xiaomi</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* A card per device; under it, on demand, its spec: every property with its value and a control, every action. */
  .device { display: grid; gap: 12px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
  .device.redrawn { animation: none; }
  .device.is-offline { opacity: 0.75; }
  .spec { margin-top: 16px; display: grid; gap: 14px; }
  .spec h3 { margin: 0 0 6px; font-size: 0.9375rem; }
  .spec .vendor { font-weight: normal; }
  .prop { display: flex; align-items: center; gap: 10px; padding: 8px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .prop .who { flex: 1; min-width: 200px; }
  .prop .who code { font-size: 0.75rem; }
  .prop .value { font-variant-numeric: tabular-nums; min-width: 80px; text-align: right; overflow-wrap: anywhere; }
  .prop select, .prop input[type="number"] { max-width: 160px; }
  /* A device's name is how a person tells it apart: on two lines rather than one cut short (the whole name in its title
     and the Properties panel's heading). The spec's URN has no spaces to break at. */
  .device .who .device-name { white-space: normal; overflow-wrap: anywhere; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; line-clamp: 2; }
  .device .urn { min-width: 0; overflow-wrap: anywhere; font-size: 0.75rem; }
  .prop input[type="color"] { width: 48px; height: 32px; padding: 0; border: 1px solid var(--line); border-radius: 8px; background: none; }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  @media (prefers-reduced-motion: reduce) { .device { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-orange" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="4"/><path d="M9 15V9h4a2 2 0 0 1 2 2v4M12 12v3"/></svg></span>
    <div class="who">
      <h1>Xiaomi</h1>
      <p class="muted" data-i18n>Your Mi Home devices on the local network. Properties shows everything a device's spec has, including what HomeKit does not show, and lets you change it.</p>
    </div>
  </div>
  <div id="account"></div>
  <div class="section-head"><h2 data-i18n>Devices</h2><div class="actions"><a class="button" id="settings-link" data-i18n data-action-icon="gear">Settings</a></div></div>
  <div id="devices" class="grid"></div>
  <div id="excluded" class="actions"></div>
  <section id="spec-panel" class="card hidden" aria-live="polite"></section>
  <p class="hint" data-i18n>Extra switches (buzzer, LED, modes, fan levels) are off by default: turn them on in a device's settings.</p>
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
