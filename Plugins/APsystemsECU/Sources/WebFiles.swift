// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension APsystemsECUPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The APsystems ECU page: each ECU of this instance with its production as last read (power, today, lifetime, an
// ECU-C's grid and home power) and its inverters (power, channels, temperature, signal). It writes nothing: the ECUs'
// addresses are Plugin Settings, an ECU's or an inverter's own settings are its Accessory Settings.
(() => {
  "use strict";
  const { $, el, request, poll, fact, tile, renderKeyed } = homeswift;
  const { t } = HomeswiftI18n;

  $("#head-tile").replaceWith(tile("sun", "orange", true));

  const { locale } = HomeswiftI18n;
  const whole = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 });
  const energy = new Intl.NumberFormat(locale, { maximumFractionDigits: 2 });
  const clock = new Intl.DateTimeFormat(locale, { hour: "2-digit", minute: "2-digit" });
  const watts = (value) => `${whole.format(value)} W`;
  const kWh = (value) => `${energy.format(value)} kWh`;
  const time = (iso) => (iso ? clock.format(new Date(iso)) : "—");

  function settingsLink(accessoryID, name) {
    return accessoryID ? el("a", { class: "button small", href: homeswift.accessorySettings(accessoryID), actionIcon: "gear", text: t("Settings"),
      "aria-label": t("Settings of {name}", { name }) }) : null;
  }

  function inverterRow(inverter) {
    const name = t("Inverter {uid}", { uid: inverter.uid });
    const state = inverter.registeredOnly ? [t("Registered"), "standby"] : !inverter.current ? [t("No data"), "away"]
      : inverter.online ? [t("Online"), "on"] : [t("Offline"), "standby"];
    const facts = inverter.registeredOnly ? null : el("div", { class: "facts live" },
      fact(t("Power"), watts(inverter.power)),
      inverter.powers.length > 1 ? fact(t("Panels"), inverter.powers.map((value) => whole.format(value)).join(" · ") + " W") : null,
      inverter.voltages.length && inverter.online ? fact(t("Voltage"), inverter.voltages.join(" · ") + " V") : null,
      inverter.temperature !== undefined ? fact(t("Temperature"), homeswift.formatTemperature(inverter.temperature)) : null,
      inverter.frequency !== undefined ? fact(t("Frequency"), `${energy.format(inverter.frequency)} Hz`) : null,
      inverter.signal !== undefined && inverter.online ? fact(t("Signal"), `${inverter.signal} %`) : null);
    return el("div", { class: "inverter" },
      el("div", { class: "who" }, el("strong", { text: name }), el("div", { class: "muted", text: inverter.model })),
      el("span", { class: `pill status ${state[1]}`, text: state[0] }),
      settingsLink(inverter.accessoryID, name),
      facts);
  }

  function ecuCard(ecu) {
    const name = ecu.name ?? ecu.host;
    const answering = ecu.failures === 0 && ecu.ecuID;
    const facts = ecu.power === undefined ? null : el("div", { class: "facts live" },
      fact(t("Power"), watts(ecu.power)),
      fact(t("Today"), kWh(ecu.today)),
      fact(t("Lifetime"), kWh(ecu.lifetime)),
      fact(t("Inverters online"), t("{online} of {count}", { online: ecu.online, count: ecu.inverters })),
      ecu.grid !== undefined ? fact(ecu.grid < 0 ? t("Exporting") : t("Grid"), watts(Math.abs(ecu.grid))) : null,
      ecu.home !== undefined ? fact(t("Home"), watts(ecu.home)) : null,
      fact(t("Last reading"), time(ecu.updated)));
    const problems = [
      ecu.failures > 0 ? t("The ECU does not answer: the last values are kept. Check its address, or power-cycle it if it stays so.") : null,
      ecu.meterFailing ? t("The ECU-C's meter does not answer: its grid and home power are unknown.") : null,
    ].filter(Boolean).map((text) => el("p", { class: "ecu-problem", text }));
    const inverters = ecu.inverterList ?? [];
    return el("div", { class: "card ecu" },
      el("div", { class: "ecu-head" },
        tile("sun", answering ? "orange" : "grey"),
        el("div", { class: "who" }, el("strong", { text: name }),
          el("div", { class: "muted", text: [ecu.model, ecu.firmware, ecu.address].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${answering ? "on" : ecu.ecuID ? "away" : "standby"}`, text: answering ? t("Answering") : ecu.ecuID ? t("Not responding") : t("Not reached yet") }),
        settingsLink(ecu.accessoryID, name)),
      facts, ...problems,
      inverters.length ? el("div", { class: "inverters", role: "list", "aria-label": t("Inverters of {name}", { name }) }, ...inverters.map(inverterRow)) : null);
  }

  /// Draws what the plugin reports: an ECU's card again only when its own reading changed (once per poll).
  let empty = null;
  async function refresh() {
    let status;
    try { status = await request("status"); } catch { return; /* the instance is restarting */ }
    const ecus = status.ecus ?? [];
    $("#loading")?.remove();
    if (empty !== !ecus.length) {
      empty = !ecus.length;
      $("#empty").replaceChildren(ecus.length ? "" : el("div", { class: "card" },
      el("h2", { text: t("Add your ECU") }),
      el("p", { class: "muted", text: t("The ECU does not announce itself on the network: enter its address in this plugin's settings, under ECUs. Your router lists it, often as an Espressif device; give it a fixed address there.") }),
      el("a", { class: "button primary", href: homeswift.settingsAddress, actionIcon: "gear", text: t("Open the settings") })));
      $("#ecus-section").classList.toggle("hidden", !ecus.length);
    }
    const list = $("#ecus");
    renderKeyed(list, ecus, (ecu) => `${ecu.host}:${ecu.port}`, ecuCard);
    // Cards drawn after the first time appear as they are: only the page's first draw fades in.
    requestAnimationFrame(() => list.classList.add("drawn"));
  }

  poll(refresh, 15000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The APsystems ECU page's strings, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Reading the ECUs…": "Lecture des ECU…",
    "The production your ECUs report, read from them on the local network.": "La production que vos ECU indiquent, lue sur le réseau local.",
    "Your ECUs": "Vos ECU",
    "Settings": "Réglages",
    "Settings of {name}": "Réglages de {name}",
    "Inverter {uid}": "Micro-onduleur {uid}",
    "Registered": "Enregistré",
    "No data": "Pas de données",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Power": "Puissance",
    "Panels": "Panneaux",
    "Voltage": "Tension",
    "Temperature": "Température",
    "Frequency": "Fréquence",
    "Signal": "Signal",
    "Today": "Aujourd’hui",
    "Lifetime": "Depuis l’installation",
    "Inverters online": "Micro-onduleurs en ligne",
    "{online} of {count}": "{online} sur {count}",
    "Exporting": "Injection",
    "Grid": "Réseau",
    "Home": "Maison",
    "Last reading": "Dernière lecture",
    "The ECU does not answer: the last values are kept. Check its address, or power-cycle it if it stays so.": "L’ECU ne répond pas : les dernières valeurs sont conservées. Vérifiez son adresse, ou débranchez-le puis rebranchez-le si cela dure.",
    "The ECU-C's meter does not answer: its grid and home power are unknown.": "Le compteur de l’ECU-C ne répond pas : la puissance du réseau et de la maison est inconnue.",
    "Answering": "Répond",
    "Not responding": "Ne répond pas",
    "Not reached yet": "Pas encore joint",
    "Inverters of {name}": "Micro-onduleurs de {name}",
    "Add your ECU": "Ajoutez votre ECU",
    "The ECU does not announce itself on the network: enter its address in this plugin's settings, under ECUs. Your router lists it, often as an Espressif device; give it a fixed address there.": "L’ECU ne s’annonce pas sur le réseau : saisissez son adresse dans les réglages de ce plugin, sous ECU. Votre routeur le liste, souvent comme un appareil Espressif ; donnez-lui là une adresse fixe.",
    "Open the settings": "Ouvrir les réglages",
  },
  "es": {
    "Reading the ECUs…": "Leyendo las ECU…",
    "The production your ECUs report, read from them on the local network.": "La producción que indican tus ECU, leída en la red local.",
    "Your ECUs": "Tus ECU",
    "Settings": "Ajustes",
    "Settings of {name}": "Ajustes de {name}",
    "Inverter {uid}": "Microinversor {uid}",
    "Registered": "Registrado",
    "No data": "Sin datos",
    "Online": "En línea",
    "Offline": "Sin conexión",
    "Power": "Potencia",
    "Panels": "Paneles",
    "Voltage": "Tensión",
    "Temperature": "Temperatura",
    "Frequency": "Frecuencia",
    "Signal": "Señal",
    "Today": "Hoy",
    "Lifetime": "Desde la instalación",
    "Inverters online": "Microinversores en línea",
    "{online} of {count}": "{online} de {count}",
    "Exporting": "Exportando",
    "Grid": "Red",
    "Home": "Casa",
    "Last reading": "Última lectura",
    "The ECU does not answer: the last values are kept. Check its address, or power-cycle it if it stays so.": "La ECU no responde: se conservan los últimos valores. Comprueba su dirección, o desconéctala y vuelve a conectarla si sigue así.",
    "The ECU-C's meter does not answer: its grid and home power are unknown.": "El medidor de la ECU-C no responde: la potencia de la red y de la casa es desconocida.",
    "Answering": "Responde",
    "Not responding": "No responde",
    "Not reached yet": "Aún sin contacto",
    "Inverters of {name}": "Microinversores de {name}",
    "Add your ECU": "Añade tu ECU",
    "The ECU does not announce itself on the network: enter its address in this plugin's settings, under ECUs. Your router lists it, often as an Espressif device; give it a fixed address there.": "La ECU no se anuncia en la red: introduce su dirección en los ajustes de este plugin, en ECU. Tu router la muestra, a menudo como un dispositivo Espressif; asígnale allí una dirección fija.",
    "Open the settings": "Abrir los ajustes",
  },
  "pt": {
    "Reading the ECUs…": "A ler as ECU…",
    "The production your ECUs report, read from them on the local network.": "A produção que as suas ECU indicam, lida na rede local.",
    "Your ECUs": "As suas ECU",
    "Settings": "Definições",
    "Settings of {name}": "Definições de {name}",
    "Inverter {uid}": "Microinversor {uid}",
    "Registered": "Registado",
    "No data": "Sem dados",
    "Online": "Online",
    "Offline": "Offline",
    "Power": "Potência",
    "Panels": "Painéis",
    "Voltage": "Tensão",
    "Temperature": "Temperatura",
    "Frequency": "Frequência",
    "Signal": "Sinal",
    "Today": "Hoje",
    "Lifetime": "Desde a instalação",
    "Inverters online": "Microinversores online",
    "{online} of {count}": "{online} de {count}",
    "Exporting": "A exportar",
    "Grid": "Rede",
    "Home": "Casa",
    "Last reading": "Última leitura",
    "The ECU does not answer: the last values are kept. Check its address, or power-cycle it if it stays so.": "A ECU não responde: os últimos valores são mantidos. Verifique o seu endereço, ou desligue-a e volte a ligá-la se continuar assim.",
    "The ECU-C's meter does not answer: its grid and home power are unknown.": "O contador da ECU-C não responde: a potência da rede e da casa é desconhecida.",
    "Answering": "Responde",
    "Not responding": "Não responde",
    "Not reached yet": "Ainda sem contacto",
    "Inverters of {name}": "Microinversores de {name}",
    "Add your ECU": "Adicione a sua ECU",
    "The ECU does not announce itself on the network: enter its address in this plugin's settings, under ECUs. Your router lists it, often as an Espressif device; give it a fixed address there.": "A ECU não se anuncia na rede: introduza o seu endereço nas definições deste plugin, em ECU. O seu router lista-a, muitas vezes como um dispositivo Espressif; atribua-lhe lá um endereço fixo.",
    "Open the settings": "Abrir as definições",
  },
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>APsystems ECU</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The ECUs this instance reads, with their production and each inverter's last reading. Read only: the ECU's
     addresses are on the Settings page. */
  .page-head { align-items: center; }
  .ecus { display: grid; gap: 12px; }
  .ecu { margin: 0; display: grid; gap: 12px; min-width: 0; }
  .ecus:not(.drawn) .ecu { animation: materialize var(--normal) var(--ease-out); }
  .ecu-head, .inverter { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px; min-width: 0; }
  .ecu-head .who, .inverter .who { flex: 1; min-width: 0; }
  .ecu-head .muted, .inverter .muted { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .facts.live { grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); }
  .inverters { display: grid; gap: 8px; }
  .inverter { padding: 10px 12px; border-radius: var(--radius-md); background: var(--material-thin); border: 1px solid var(--line); }
  .inverter .facts { flex-basis: 100%; grid-template-columns: repeat(auto-fill, minmax(110px, 1fr)); }
  .ecu-problem { font-size: 0.8125rem; color: var(--warn); margin: 0; }
  .facts.live .fact b { font-variant-numeric: tabular-nums; }
  .inverter .fact { background: none; }
  @media (prefers-reduced-motion: reduce) { .ecus .ecu { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span id="head-tile"></span>
    <div class="who">
      <h1>APsystems ECU</h1>
      <p class="muted" data-i18n>The production your ECUs report, read from them on the local network.</p>
    </div>
  </div>
  <p id="loading" class="muted" data-i18n>Reading the ECUs…</p>
  <div id="empty"></div>
  <section id="ecus-section" class="hidden">
    <div class="section-head"><h2 data-i18n>Your ECUs</h2></div>
    <div id="ecus" class="ecus"></div>
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
