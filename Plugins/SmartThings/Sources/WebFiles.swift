// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension SmartThingsPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The SmartThings page: how updates come (events or polling), each device with its kind, whether it answers, and the
// values HomeKit has no characteristic for (an appliance's state, cycle, time left), and the devices left out. It writes
// nothing: signing in is Setup's, a device's options are its Accessory Settings.
(() => {
  "use strict";
  const { $, el, request, poll, fact, tile, renderKeyed, setupCard } = homeswift;
  const { t } = HomeswiftI18n;

  $("#head-tile").replaceWith(tile("house", "blue", true));

  const KINDS = {
    light: t("Light"), switch: t("Switch"), outlet: t("Outlet"), fan: t("Fan"), thermostat: t("Thermostat"), airConditioner: t("Air conditioner"),
    airPurifier: t("Air purifier"), lock: t("Lock"), garageDoor: t("Garage door"), windowCovering: t("Window covering"), valve: t("Valve"),
    sensor: t("Sensor"), button: t("Button"), securitySystem: t("Security system"), television: t("Television"), washer: t("Washer"),
    dryer: t("Dryer"), dishwasher: t("Dishwasher"), oven: t("Oven"), refrigerator: t("Refrigerator"), robotVacuum: t("Robot vacuum"),
  };
  // The appliance values' labels, as the plugin names them.
  const LABELS = {
    "State": t("State"), "Job": t("Job"), "Remaining": t("Remaining"), "Finishes at": t("Finishes at"), "Progress": t("Progress"), "Mode": t("Mode"),
    "Cycle": t("Cycle"), "Setpoint": t("Setpoint"), "Operation time": t("Operation time"), "Rapid freezing": t("Rapid freezing"), "Ice maker": t("Ice maker"),
    "Movement": t("Movement"), "Cleaning mode": t("Cleaning mode"), "Turbo mode": t("Turbo mode"), "Remote control": t("Remote control"),
  };
  const VALUES = { "allowed": t("allowed"), "not allowed": t("not allowed") };
  const clock = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit" });

  function detail(item) {
    const [base, part] = item.label.split(" (");
    const label = (LABELS[base] ?? base) + (part ? ` (${part}` : "");
    const value = base === "Finishes at" ? clock.format(new Date(item.value)) : VALUES[item.value] ?? item.value;
    return fact(label, value);
  }

  function deviceCard(device) {
    const kind = KINDS[device.kind] ?? device.kind;
    const settings = el("a", { class: "button small", href: homeswift.accessorySettings(device.accessoryId), actionIcon: "gear", text: t("Settings"),
      "aria-label": t("Settings of {name}", { name: device.name }) });
    const details = device.details.length ? el("div", { class: "facts live" }, ...device.details.map(detail)) : null;
    const note = device.matter ? el("p", { class: "muted", text: t("This is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.") }) : null;
    return el("div", { class: "card device" },
      el("div", { class: "device-head" },
        el("div", { class: "who" }, el("strong", { text: device.name }), el("div", { class: "muted", text: [kind, device.room].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${device.online ? "on" : "away"}`, text: device.online ? t("Online") : t("Offline") }),
        settings),
      details, note);
  }

  function statusCard(status) {
    const updates = status.events ? t("Live, through SmartThings' event stream")
      : t("Every {seconds} s, one call for all devices", { seconds: Math.round(status.pollSeconds) });
    return [
      el("div", { class: "facts" },
        fact(t("Location"), status.location ?? "—"),
        fact(t("Updates"), updates),
        fact(t("Requests since start"), String(status.requests))),
      status.eventsNote ? el("p", { class: "muted", text: t("SmartThings refused the event stream: updates come by polling for now.") }) : null,
      !status.sseGranted && !status.personalToken ? el("p", { class: "muted", text: t("Your app has no sse scope: add it, then sign in again, for live updates and buttons.") }) : null,
      status.personalToken ? el("p", { class: "muted", text: t("Signed in with a personal access token, which expires within a day. Sign in with your own SmartThings app instead.") }) : null,
      status.lastError ? el("p", { class: "muted", text: t("SmartThings does not answer: the last values are kept.") }) : null,
    ].filter(Boolean);
  }

  function leftOut(diagnostics) {
    const rows = [
      ...diagnostics.unsupported.map((device) => el("p", { text: t("{name}: nothing HomeKit can show ({capabilities})", {
        name: device.name, capabilities: device.components.flatMap((component) => component.capabilities.map((capability) => capability.id)).join(", ") || "—",
      }) })),
      ...diagnostics.skippedCopies.map((device) => el("p", { text: t("{name}: Homeswift's own, through its Matter bridge", { name: device.name }) })),
    ];
    return rows;
  }

  let drawnSetup = null;
  async function refresh() {
    let status, devices, diagnostics;
    try {
      [status, devices, diagnostics] = await Promise.all([request("status"), request("devices"), request("diagnostics")]);
    } catch { return; /* the instance is restarting */ }
    $("#loading")?.remove();
    const needsSetup = !status.signedIn;
    if (drawnSetup !== needsSetup) {
      drawnSetup = needsSetup;
      $("#setup").replaceChildren(needsSetup ? setupCard({
        title: status.refusal ? t("Sign in to SmartThings again") : t("Sign in to SmartThings"),
        text: t("Add accessories signs in with your own SmartThings app (an OAuth-In app, which needs a SmartThings Developer plan); the location's devices come with it."),
      }) : "");
    }
    $("#status").classList.toggle("hidden", needsSetup);
    if (!needsSetup) $("#status").replaceChildren(...statusCard(status));
    const list = devices.devices ?? [];
    $("#devices-section").classList.toggle("hidden", !list.length);
    renderKeyed($("#devices"), list, (device) => `${device.deviceId}:${JSON.stringify(device)}`, deviceCard);
    requestAnimationFrame(() => $("#devices").classList.add("drawn"));
    const rows = leftOut(diagnostics);
    $("#left-out-section").classList.toggle("hidden", !rows.length);
    $("#left-out").replaceChildren(...rows);
  }

  poll(refresh, 15000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The SmartThings page's strings, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Add accessories signs in with your own SmartThings app (an OAuth-In app, which needs a SmartThings Developer plan); the location's devices come with it.": "Ajouter des accessoires vous connecte avec votre propre app SmartThings (une app OAuth-In, qui demande un abonnement SmartThings Developer) ; les appareils du lieu suivent.",
    "Air conditioner": "Climatiseur",
    "Air purifier": "Purificateur d'air",
    "Button": "Bouton",
    "Cleaning mode": "Mode de nettoyage",
    "Cycle": "Cycle",
    "Dishwasher": "Lave-vaisselle",
    "Dryer": "Sèche-linge",
    "Every {seconds} s, one call for all devices": "Toutes les {seconds} s, un appel pour tous les appareils",
    "Fan": "Ventilateur",
    "Finishes at": "Se termine à",
    "Garage door": "Porte de garage",
    "Ice maker": "Machine à glaçons",
    "Job": "Étape",
    "Left out": "Laissés de côté",
    "Light": "Lampe",
    "Live, through SmartThings' event stream": "En direct, par le flux d'événements de SmartThings",
    "Location": "Lieu",
    "Lock": "Serrure",
    "Mode": "Mode",
    "Movement": "Mouvement",
    "Offline": "Hors ligne",
    "Online": "En ligne",
    "Operation time": "Durée de fonctionnement",
    "Outlet": "Prise",
    "Oven": "Four",
    "Progress": "Avancement",
    "Rapid freezing": "Congélation rapide",
    "Reading SmartThings…": "Lecture de SmartThings…",
    "Refrigerator": "Réfrigérateur",
    "Remaining": "Restant",
    "Remote control": "Commande à distance",
    "Requests since start": "Requêtes depuis le démarrage",
    "Robot vacuum": "Aspirateur robot",
    "Security system": "Système de sécurité",
    "Sensor": "Capteur",
    "Setpoint": "Consigne",
    "Settings": "Réglages",
    "Settings of {name}": "Réglages de {name}",
    "Sign in to SmartThings": "Se connecter à SmartThings",
    "Sign in to SmartThings again": "Se reconnecter à SmartThings",
    "Signed in with a personal access token, which expires within a day. Sign in with your own SmartThings app instead.": "Connecté avec un jeton d'accès personnel, qui expire en moins d'un jour. Connectez-vous plutôt avec votre propre app SmartThings.",
    "SmartThings does not answer: the last values are kept.": "SmartThings ne répond pas : les dernières valeurs sont conservées.",
    "SmartThings refused the event stream: updates come by polling for now.": "SmartThings a refusé le flux d'événements : les mises à jour arrivent par lecture périodique pour l'instant.",
    "State": "État",
    "Switch": "Interrupteur",
    "Television": "Téléviseur",
    "The devices of your SmartThings location, through Samsung's cloud.": "Les appareils de votre lieu SmartThings, par le cloud de Samsung.",
    "Thermostat": "Thermostat",
    "This is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.": "C'est un appareil Matter : il est peut-être déjà dans Apple Home par son propre jumelage Matter. Si c'est le cas, réglez-le Hors de Maison.",
    "Turbo mode": "Mode turbo",
    "Updates": "Mises à jour",
    "Valve": "Vanne",
    "Washer": "Lave-linge",
    "Window covering": "Store",
    "Your app has no sse scope: add it, then sign in again, for live updates and buttons.": "Votre app n'a pas le droit sse : ajoutez-le puis reconnectez-vous, pour des mises à jour en direct et les boutons.",
    "Your devices": "Vos appareils",
    "allowed": "autorisée",
    "not allowed": "non autorisée",
    "{name}: Homeswift's own, through its Matter bridge": "{name} : un accessoire de Homeswift, revenu par son pont Matter",
    "{name}: nothing HomeKit can show ({capabilities})": "{name} : rien que HomeKit puisse afficher ({capabilities})",
  },
  "es": {
    "Add accessories signs in with your own SmartThings app (an OAuth-In app, which needs a SmartThings Developer plan); the location's devices come with it.": "Añadir accesorios inicia sesión con tu propia app de SmartThings (una app OAuth-In, que requiere un plan SmartThings Developer); los dispositivos de la ubicación vienen con ella.",
    "Air conditioner": "Aire acondicionado",
    "Air purifier": "Purificador de aire",
    "Button": "Botón",
    "Cleaning mode": "Modo de limpieza",
    "Cycle": "Ciclo",
    "Dishwasher": "Lavavajillas",
    "Dryer": "Secadora",
    "Every {seconds} s, one call for all devices": "Cada {seconds} s, una llamada para todos los dispositivos",
    "Fan": "Ventilador",
    "Finishes at": "Termina a las",
    "Garage door": "Puerta de garaje",
    "Ice maker": "Máquina de hielo",
    "Job": "Fase",
    "Left out": "Omitidos",
    "Light": "Luz",
    "Live, through SmartThings' event stream": "En directo, por el flujo de eventos de SmartThings",
    "Location": "Ubicación",
    "Lock": "Cerradura",
    "Mode": "Modo",
    "Movement": "Movimiento",
    "Offline": "Sin conexión",
    "Online": "En línea",
    "Operation time": "Tiempo de funcionamiento",
    "Outlet": "Enchufe",
    "Oven": "Horno",
    "Progress": "Progreso",
    "Rapid freezing": "Congelación rápida",
    "Reading SmartThings…": "Leyendo SmartThings…",
    "Refrigerator": "Frigorífico",
    "Remaining": "Restante",
    "Remote control": "Control remoto",
    "Requests since start": "Peticiones desde el inicio",
    "Robot vacuum": "Robot aspirador",
    "Security system": "Sistema de seguridad",
    "Sensor": "Sensor",
    "Setpoint": "Consigna",
    "Settings": "Ajustes",
    "Settings of {name}": "Ajustes de {name}",
    "Sign in to SmartThings": "Iniciar sesión en SmartThings",
    "Sign in to SmartThings again": "Volver a iniciar sesión en SmartThings",
    "Signed in with a personal access token, which expires within a day. Sign in with your own SmartThings app instead.": "Sesión iniciada con un token de acceso personal, que caduca en menos de un día. Inicia sesión mejor con tu propia app de SmartThings.",
    "SmartThings does not answer: the last values are kept.": "SmartThings no responde: se conservan los últimos valores.",
    "SmartThings refused the event stream: updates come by polling for now.": "SmartThings rechazó el flujo de eventos: por ahora las actualizaciones llegan por lectura periódica.",
    "State": "Estado",
    "Switch": "Interruptor",
    "Television": "Televisor",
    "The devices of your SmartThings location, through Samsung's cloud.": "Los dispositivos de tu ubicación de SmartThings, a través de la nube de Samsung.",
    "Thermostat": "Termostato",
    "This is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.": "Es un dispositivo Matter: puede que ya esté en Apple Home por su propio emparejamiento Matter. Si es así, ponlo Fuera de Casa.",
    "Turbo mode": "Modo turbo",
    "Updates": "Actualizaciones",
    "Valve": "Válvula",
    "Washer": "Lavadora",
    "Window covering": "Persiana",
    "Your app has no sse scope: add it, then sign in again, for live updates and buttons.": "Tu app no tiene el ámbito sse: añádelo y vuelve a iniciar sesión para tener actualizaciones en directo y botones.",
    "Your devices": "Tus dispositivos",
    "allowed": "permitido",
    "not allowed": "no permitido",
    "{name}: Homeswift's own, through its Matter bridge": "{name}: un accesorio de Homeswift, de vuelta por su puente Matter",
    "{name}: nothing HomeKit can show ({capabilities})": "{name}: nada que HomeKit pueda mostrar ({capabilities})",
  },
  "pt": {
    "Add accessories signs in with your own SmartThings app (an OAuth-In app, which needs a SmartThings Developer plan); the location's devices come with it.": "Adicionar acessórios inicia sessão com a sua própria app do SmartThings (uma app OAuth-In, que exige um plano SmartThings Developer); os dispositivos da localização vêm com ela.",
    "Air conditioner": "Ar condicionado",
    "Air purifier": "Purificador de ar",
    "Button": "Botão",
    "Cleaning mode": "Modo de limpeza",
    "Cycle": "Ciclo",
    "Dishwasher": "Máquina de lavar loiça",
    "Dryer": "Máquina de secar",
    "Every {seconds} s, one call for all devices": "A cada {seconds} s, uma chamada para todos os dispositivos",
    "Fan": "Ventoinha",
    "Finishes at": "Termina às",
    "Garage door": "Porta de garagem",
    "Ice maker": "Máquina de gelo",
    "Job": "Fase",
    "Left out": "Deixados de fora",
    "Light": "Luz",
    "Live, through SmartThings' event stream": "Em direto, pelo fluxo de eventos do SmartThings",
    "Location": "Localização",
    "Lock": "Fechadura",
    "Mode": "Modo",
    "Movement": "Movimento",
    "Offline": "Offline",
    "Online": "Online",
    "Operation time": "Tempo de funcionamento",
    "Outlet": "Tomada",
    "Oven": "Forno",
    "Progress": "Progresso",
    "Rapid freezing": "Congelação rápida",
    "Reading SmartThings…": "A ler o SmartThings…",
    "Refrigerator": "Frigorífico",
    "Remaining": "Restante",
    "Remote control": "Controlo remoto",
    "Requests since start": "Pedidos desde o arranque",
    "Robot vacuum": "Robô aspirador",
    "Security system": "Sistema de segurança",
    "Sensor": "Sensor",
    "Setpoint": "Temperatura definida",
    "Settings": "Definições",
    "Settings of {name}": "Definições de {name}",
    "Sign in to SmartThings": "Iniciar sessão no SmartThings",
    "Sign in to SmartThings again": "Iniciar sessão novamente no SmartThings",
    "Signed in with a personal access token, which expires within a day. Sign in with your own SmartThings app instead.": "Sessão iniciada com um token de acesso pessoal, que expira em menos de um dia. Inicie antes sessão com a sua própria app do SmartThings.",
    "SmartThings does not answer: the last values are kept.": "O SmartThings não responde: os últimos valores são mantidos.",
    "SmartThings refused the event stream: updates come by polling for now.": "O SmartThings recusou o fluxo de eventos: por agora as atualizações chegam por leitura periódica.",
    "State": "Estado",
    "Switch": "Interruptor",
    "Television": "Televisor",
    "The devices of your SmartThings location, through Samsung's cloud.": "Os dispositivos da sua localização do SmartThings, através da nuvem da Samsung.",
    "Thermostat": "Termóstato",
    "This is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.": "É um dispositivo Matter: pode já estar na Apple Home pelo seu próprio emparelhamento Matter. Se for o caso, defina-o Fora da Casa.",
    "Turbo mode": "Modo turbo",
    "Updates": "Atualizações",
    "Valve": "Válvula",
    "Washer": "Máquina de lavar roupa",
    "Window covering": "Estore",
    "Your app has no sse scope: add it, then sign in again, for live updates and buttons.": "A sua app não tem o âmbito sse: acrescente-o e inicie sessão novamente, para atualizações em direto e botões.",
    "Your devices": "Os seus dispositivos",
    "allowed": "permitido",
    "not allowed": "não permitido",
    "{name}: Homeswift's own, through its Matter bridge": "{name}: um acessório do Homeswift, de volta pela sua ponte Matter",
    "{name}: nothing HomeKit can show ({capabilities})": "{name}: nada que o HomeKit possa mostrar ({capabilities})",
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SmartThings</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The location's devices with what HomeKit cannot show (an appliance's cycle, its time left), how updates come, and
     what was left out. Read only: signing in is Setup's, each device's options are its settings. */
  .page-head { align-items: center; }
  .devices { display: grid; gap: 12px; }
  .device { margin: 0; display: grid; gap: 10px; min-width: 0; }
  .devices:not(.drawn) .device { animation: materialize var(--normal) var(--ease-out); }
  .device-head { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px; min-width: 0; }
  .device-head .who { flex: 1; min-width: 0; }
  .device-head .muted { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .facts.live { grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); }
  .left-out { display: grid; gap: 8px; }
  .left-out p { margin: 0; font-size: 0.875rem; overflow-wrap: anywhere; }
  @media (prefers-reduced-motion: reduce) { .devices .device { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span id="head-tile"></span>
    <div class="who">
      <h1>SmartThings</h1>
      <p class="muted" data-i18n>The devices of your SmartThings location, through Samsung's cloud.</p>
    </div>
  </div>
  <p id="loading" class="muted" data-i18n>Reading SmartThings…</p>
  <div id="setup"></div>
  <section id="status" class="card hidden"></section>
  <section id="devices-section" class="hidden">
    <div class="section-head"><h2 data-i18n>Your devices</h2></div>
    <div id="devices" class="devices"></div>
  </section>
  <section id="left-out-section" class="hidden">
    <div class="section-head"><h2 data-i18n>Left out</h2></div>
    <div id="left-out" class="card left-out"></div>
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
