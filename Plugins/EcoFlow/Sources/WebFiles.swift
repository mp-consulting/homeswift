// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EcoFlowPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The EcoFlow page: each device the plugin reads, its battery, and its power as IN and OUT, laid out by kind as the
// app does. The page refreshes every few seconds while it is visible; it reads `GET power` from the plugin.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, request } = homeswift;

  const list = $("#devices");
  // Devices already on the page: a card animates in once, not again at every refresh.
  const shown = new Set();
  // Whole watts everywhere: the readings are never shown with decimals.
  const whole = (value) => Math.round(Math.abs(value)).toLocaleString(HomeswiftI18n.locale);
  // Figures are text nodes, never HTML: the number and its unit each in their own element.
  const figure = (number, unit) => el("span", {}, number, el("small", { text: ` ${unit}` }));
  // Power: whole watts below a kilowatt; from 1,000 W, kilowatts with two decimals (1.43 kW, or 1,43 kW in French).
  const power = (value) => {
    const magnitude = Math.abs(value);
    if (magnitude >= 1000) {
      return { number: (magnitude / 1000).toLocaleString(HomeswiftI18n.locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 }), unit: "kW" };
    }
    return { number: whole(value), unit: "W" };
  };
  const watts = (value) => {
    const formatted = power(value);
    return figure(formatted.number, formatted.unit);
  };

  // A flow's direction: power coming in or going out, by the device's sign convention (grid positive is import,
  // battery positive is charging). Zero is idle.
  function way(value, inWhenPositive) {
    if (Math.abs(value) < 1) return { label: t("Idle"), kind: "idle" };
    const coming = (value > 0) === inWhenPositive;
    return coming ? { label: t("IN"), kind: "in" } : { label: t("OUT"), kind: "out" };
  }

  // The direction arrow, as the app draws it: green up for power coming in, orange down for power going out.
  // Idle (or no direction) shows none.
  const arrow = (kind) => el("span", { class: `arrow ${kind}`, "aria-hidden": "true" });

  // The last hour of each reading, as the Status page records it: deviceID:key -> points. A reading not loaded yet
  // has no entry, and its sparkline shows a loader.
  const history = new Map();
  const historyOf = (id, key) => history.get(`${id}:${key}`) ?? null;

  // A sparkline of the readings' averages, in front of the value: its own scale, the line only (no axes). While the
  // points are loading (null), a shimmering line stands in for it. It has no tooltip of its own: its tile's says what
  // the tile shows, and two would open at once.
  function sparkline(points) {
    const node = el("span", { class: "spark", "aria-hidden": "true" });
    if (points === null) {
      node.classList.add("loading");
      node.append(el("span", { class: "spark-loader" }));
      return node;
    }
    const values = points.map((point) => point.average ?? point.high).filter((value) => value !== null);
    if (values.length < 2) return node;
    const low = Math.min(...values), high = Math.max(...values), span = high - low || 1;
    const step = 100 / (values.length - 1);
    const line = values.map((value, index) => `${(index * step).toFixed(2)},${(22 - ((value - low) / span) * 20).toFixed(2)}`).join(" ");
    node.innerHTML = `<svg viewBox="0 0 100 24" preserveAspectRatio="none"><polyline points="${line}"/></svg>`;
    return node;
  }

  // Each value's tooltip: what the number is, and what IN and OUT mean.
  const tipWay = (kind) => ({ in: t("Power coming in"), out: t("Power going out"), idle: t("No power flowing") })[kind];

  function flow(label, value, inWhenPositive, points, tip, wide = false) {
    const direction = way(value, inWhenPositive);
    const badge = el("span", { class: `way ${direction.kind}`, text: direction.label, "data-tip": tipWay(direction.kind) });
    const pointer = direction.kind === "idle" ? null : arrow(direction.kind);
    return el("div", { class: wide ? "flow wide" : "flow", "data-tip": tip },
      el("div", { class: "label" }, el("span", { text: label }), badge),
      el("div", { class: "value" }, sparkline(points), pointer, watts(value)));
  }

  // The battery's graphic beside its percentage, as on the Accessories tiles: the bars filled by the level.
  function batteryGraphic(level) {
    const node = el("span", { class: "battery-mini", "aria-hidden": "true" });
    const filled = level === null ? 0 : level >= 67 ? 3 : level >= 34 ? 2 : level >= 10 ? 1 : 0;
    const bars = [0, 1, 2].map((index) => `<rect class="bat-bar${index < filled ? " on" : ""}" x="${4.5 + index * 3.9}" y="8.8" width="2.6" height="6.4" rx="0.6"/>`).join("");
    node.innerHTML = `<svg viewBox="0 0 24 24"><rect class="bat-body" x="2" y="6.5" width="17" height="11" rx="2"/><path class="bat-terminal" d="M21.5 10.5v3"/>${bars}</svg>`;
    return node;
  }

  // Where a device's values come from: the developer API's MQTT pushes, its REST quota, or the EcoFlow app's stream.
  // Each device's values all come from one source, shown beside its name.
  const sourceLabel = (source) => ({ mqtt: "MQTT", rest: "REST", app: t("App") })[source] ?? source;
  const sourceTip = (source) => ({
    mqtt: t("Values from the developer API's MQTT pushes"),
    rest: t("Values from the developer API's REST quota"),
    app: t("Values from the EcoFlow app's stream"),
  })[source] ?? "";

  // Each reading's flow, as the app shows it: [label, IN when positive, tooltip, full width]. A device lists the
  // readings its model reports, in the app's order (`series`): a STREAM's solar, home, grid and battery, its sockets
  // and its grid connection port; another home system's flows; a portable station's totals, its solar, the AC input
  // and each output; a power bank's totals.
  const flows = {
    solar: ["Solar", true, "Power from the solar panels now"],
    home: ["Home", false, "Power the home uses now"],
    grid: ["Grid", true, "Power exchanged with the grid: IN is import, OUT is export"],
    battery: ["Battery", true, "Power into the battery while charging, out of it while discharging"],
    ac1: ["AC1", false, "Power this socket supplies to what is plugged in"],
    ac2: ["AC2", false, "Power this socket supplies to what is plugged in"],
    ac: ["Grid connection port", false, "Power through the AC port: OUT feeds the home, IN takes power in", true],
    input: ["Input", true, "Power coming into the station from all its inputs"],
    output: ["Output", false, "Power the station supplies on all its outputs"],
    acIn: ["AC input", true, "Power coming in through the AC input"],
    acOut: ["230V AC", false, "Power the AC sockets supply"],
    usbA: ["USB-A", false, "Power the USB-A ports supply"],
    usbC: ["USB-C", false, "Power the USB-C ports supply"],
  };

  // A model mapped from open-source projects and not yet checked on a real device: marked beside the source.
  const untested = () => el("span", { class: "way untested", text: t("Untested"),
    "data-tip": t("This model's readings come from open-source projects and have not been checked on a real device yet") });

  // The device's estimate of the time to full while charging, to empty otherwise, as the EcoFlow app shows it: days
  // and hours (rounded to the hour) from a day up, else hours and minutes, or minutes.
  function remaining(device) {
    if (device.minutesRemaining == null) return null;
    const total = Math.round(device.minutesRemaining);
    const hours = Math.floor(total / 60), minutes = total % 60;
    const roundedHours = Math.round(total / 60);
    const time = roundedHours >= 24 ? t("{d}d {h}h", { d: Math.floor(roundedHours / 24), h: roundedHours % 24 })
      : hours > 0 ? t("{h}h {m}m", { h: hours, m: minutes }) : t("{m}m", { m: minutes });
    return el("span", { class: "remaining",
      text: device.charging ? t("{time} to full", { time }) : t("{time} left", { time }),
      "data-tip": device.charging ? t("Time until the battery is full at the current power, as the device estimates it")
        : t("Time until the battery is empty at the current power, as the device estimates it") });
  }

  function card(device, enter) {
    const level = device.batteryLevel === null ? null : Math.round(device.batteryLevel);
    const battery = el("div", { class: "battery-line" },
      el("div", { class: "figure", "data-tip": t("The battery's state of charge") }, batteryGraphic(level), level === null ? "–" : figure(String(level), "%")),
      el("div", { class: "battery-state" }, remaining(device),
        el("span", { class: `pill ${device.charging ? "on" : ""}`, text: device.charging ? t("Charging") : t("Not charging"), "data-tip": t("Whether the battery is charging now") })));
    const shown = (device.series ?? []).filter((key) => flows[key]);
    const flowList = el("div", { class: "flows" }, shown.map((key) => {
      const [label, inWhenPositive, tip, wide] = flows[key];
      return flow(t(label), device[key], inWhenPositive, historyOf(device.id, key), t(tip), wide);
    }));
    const status = device.online ? null : el("p", { class: "note", text: t("Offline: showing the last readings") });
    const panels = (device.panels ?? []).length
      ? el("div", { class: "panels" }, el("p", { class: "caption", text: t("Solar by panel") }),
          el("div", { class: "panel-row" }, device.panels.map((value, index) =>
            el("div", { class: "pv-tile", "data-tip": t("Power from this solar panel input") }, el("span", { class: "label" }, `PV${index + 1}`, el("span", { class: "way in", text: t("IN") })),
              el("span", { class: "value" }, power(value).number, el("small", { text: ` ${power(value).unit}` }))))))
      : null;
    return el("article", { class: `card device${enter ? " enter" : ""}`, "aria-label": device.name },
      el("div", { class: "device-head" },
        el("div", { class: "title-line" }, el("h2", { text: device.name }),
          el("span", { class: "way source", text: sourceLabel(device.source), "data-tip": sourceTip(device.source) }),
          device.tested === false ? untested() : null),
        el("p", { class: "serial", text: device.model ? `${device.model} · ${device.id}` : device.id })),
      battery, flowList, panels, status);
  }

  // A device still on its way: its name, and shimmering lines where its battery and flows will be. Before the first
  // answer, one stands for whatever the plugin will report.
  function placeholder(device) {
    const bar = (cls) => el("span", { class: `placeholder-bar ${cls}`, "aria-hidden": "true" });
    return el("article", { class: "card device pending", "aria-busy": "true", "aria-label": device?.name ?? t("Loading") },
      el("div", { class: "device-head" },
        el("div", { class: "title-line" }, device ? el("h2", { text: device.name ?? device.model ?? device.id }) : bar("title")),
        el("p", { class: "serial", text: device ? t("Waiting for its first readings") : t("Loading the devices") })),
      bar("figure"),
      el("div", { class: "flows" }, [0, 1, 2, 3].map(() => el("div", { class: "flow" }, bar("label"), bar("value")))));
  }

  // Shown while the plugin has no readings: why, and when this page looks again.
  function waiting() {
    const glyph = el("span", { class: "empty-glyph", "aria-hidden": "true" });
    glyph.innerHTML = `<svg viewBox="0 0 24 24"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>`;
    return el("section", { class: "card empty", role: "status" },
      glyph,
      el("h2", { text: t("No devices yet") }),
      el("p", { class: "note", text: t("The plugin has not had readings from your devices yet. They usually arrive within a minute.") }),
      el("p", { class: "note", text: t("This page checks again every few seconds while it is open.") }));
  }

  // Each graphed reading's last hour, read from the Status page's history: the series the device's kind records
  // (the plugin lists them), all at once. `onlyMissing` reads just the readings with no history yet: a device that
  // arrives after the first answer (the app's stream reports a few seconds after the developer API) gets its
  // sparklines at once rather than at the next minute's reload.
  let known = [];
  const loading = new Set();
  async function loadHistory(onlyMissing = false) {
    const wanted = known.flatMap((device) => (device.series ?? []).map((key) => [device, key]))
      .filter(([device, key]) => !onlyMissing || !(history.has(`${device.id}:${key}`) || loading.has(`${device.id}:${key}`)));
    if (wanted.length === 0) return;
    wanted.forEach(([device, key]) => loading.add(`${device.id}:${key}`));
    // One request for them all: the history answers several series, separated by commas, by name.
    const names = wanted.map(([device, key]) => `plugin:EcoFlow:${device.id}:${key}`);
    let answer = null;
    try {
      const response = await fetch(`/api/metrics/values?series=${names.map(encodeURIComponent).join(",")}`, { credentials: "same-origin" });
      if (response.ok) {
        const body = await response.json();
        answer = body.series ?? { [names[0]]: body.points };
      }
    } catch (error) {
      // Keep the last points: the sparkline is a convenience, the values are the page.
    }
    wanted.forEach(([device, key], index) => {
      // A failed read keeps the last points, or shows an empty sparkline once rather than the loader forever.
      history.set(`${device.id}:${key}`, answer?.[names[index]] ?? history.get(`${device.id}:${key}`) ?? []);
      loading.delete(`${device.id}:${key}`);
    });
    render();
  }

  // The devices as the plugin reads them: the route in the plugin's settings decides each one's source.
  // `pending` is the configured devices with no readings yet; null until the plugin has answered once.
  let pending = null;
  function render() {
    if (pending === null) {
      list.replaceChildren(placeholder(null));
      return;
    }
    const cards = known.map((device) => {
      const enter = !shown.has(device.id);
      shown.add(device.id);
      return card(device, enter);
    });
    const placeholders = pending.map(placeholder);
    list.replaceChildren(...(cards.length + placeholders.length === 0 ? [waiting()] : [...cards, ...placeholders]));
  }

  // The cards are drawn again only when the readings changed: the plugin's values change at its own poll.
  let lastAnswer = "";
  async function refresh() {
    try {
      const body = await request("power");
      const devices = body.devices ?? [];
      const answer = JSON.stringify([devices, body.waiting ?? []]);
      if (answer === lastAnswer) return;
      lastAnswer = answer;
      known = devices;
      pending = body.waiting ?? [];
      loadHistory(true);
      render();
    } catch (error) {
      lastAnswer = "";
      list.replaceChildren(el("p", { class: "note", text: HomeswiftI18n.message(error.message) }));
    }
  }

  // A placeholder at once, while the first answer is on its way.
  render();
  homeswift.poll(refresh, 3000);
  setInterval(loadHistory, 60000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The EcoFlow page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Loading": "Chargement",
    "Waiting for its first readings": "En attente de ses premières valeurs",
    "Loading the devices": "Chargement des appareils",
    "{d}d {h}h": "{d} j {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} avant la charge complète",
    "{time} left": "{time} restantes",
    "Time until the battery is full at the current power, as the device estimates it": "Temps avant que la batterie soit pleine à la puissance actuelle, selon l'estimation de l'appareil",
    "Time until the battery is empty at the current power, as the device estimates it": "Temps avant que la batterie soit vide à la puissance actuelle, selon l'estimation de l'appareil",
    "Untested": "Non testé",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "Les valeurs de ce modèle viennent de projets open source et n'ont pas encore été vérifiées sur un vrai appareil",
    "Power from the solar panels now": "Puissance des panneaux solaires maintenant",
    "Power the home uses now": "Puissance consommée par la maison maintenant",
    "Power exchanged with the grid: IN is import, OUT is export": "Puissance échangée avec le réseau : ENTRÉE est l'import, SORTIE l'export",
    "Power into the battery while charging, out of it while discharging": "Puissance entrant dans la batterie en charge, sortant en décharge",
    "Power this socket supplies to what is plugged in": "Puissance fournie par cette prise à ce qui y est branché",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Puissance passant par le port AC : SORTIE alimente la maison, ENTRÉE prend de l'énergie",
    "The battery's state of charge": "Le niveau de charge de la batterie",
    "Whether the battery is charging now": "Si la batterie se charge maintenant",
    "Power from this solar panel input": "Puissance de cette entrée de panneau solaire",
    "Power coming in": "Puissance entrante",
    "Power going out": "Puissance sortante",
    "No power flowing": "Aucune puissance ne circule",
    "Grid connection port": "Port réseau",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solaire par panneau",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Puissance solaire, domestique, réseau et batterie, telle que les appareils la transmettent maintenant. ENTRÉE est la puissance qui entre, SORTIE celle qui sort.",
    "Solar": "Solaire",
    "Home": "Maison",
    "Grid": "Réseau",
    "Battery": "Batterie",
    "IN": "ENTRÉE",
    "OUT": "SORTIE",
    "Idle": "Au repos",
    "Charging": "En charge",
    "Not charging": "Pas en charge",
    "Offline: showing the last readings": "Hors ligne : dernières valeurs affichées",
    "No devices yet": "Aucun appareil pour l'instant",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "Le plugin n'a pas encore reçu de valeurs de vos appareils. Elles arrivent en général dans la minute.",
    "This page checks again every few seconds while it is open.": "Cette page vérifie à nouveau toutes les quelques secondes tant qu'elle est ouverte.",
    "App": "Application",
    "Values from the developer API's MQTT pushes": "Valeurs des envois MQTT de l'API développeur",
    "Values from the developer API's REST quota": "Valeurs du quota REST de l'API développeur",
    "Values from the EcoFlow app's stream": "Valeurs du flux de l'application EcoFlow",
    "Input": "Entrée",
    "Output": "Sortie",
    "AC input": "Entrée AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Puissance entrant dans la station par toutes ses entrées",
    "Power the station supplies on all its outputs": "Puissance que la station fournit sur toutes ses sorties",
    "Power coming in through the AC input": "Puissance entrant par l'entrée AC",
    "Power the AC sockets supply": "Puissance fournie par les prises AC",
    "Power the USB-A ports supply": "Puissance fournie par les ports USB-A",
    "Power the USB-C ports supply": "Puissance fournie par les ports USB-C"
  },
  "es": {
    "Loading": "Cargando",
    "Waiting for its first readings": "Esperando sus primeros valores",
    "Loading the devices": "Cargando los dispositivos",
    "{d}d {h}h": "{d} d {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} hasta la carga completa",
    "{time} left": "quedan {time}",
    "Time until the battery is full at the current power, as the device estimates it": "Tiempo hasta que la batería esté llena a la potencia actual, según la estimación del dispositivo",
    "Time until the battery is empty at the current power, as the device estimates it": "Tiempo hasta que la batería se agote a la potencia actual, según la estimación del dispositivo",
    "Untested": "Sin probar",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "Los valores de este modelo provienen de proyectos de código abierto y aún no se han comprobado en un dispositivo real",
    "Power from the solar panels now": "Potencia de los paneles solares ahora",
    "Power the home uses now": "Potencia que usa la casa ahora",
    "Power exchanged with the grid: IN is import, OUT is export": "Potencia intercambiada con la red: ENTRA es importación, SALE exportación",
    "Power into the battery while charging, out of it while discharging": "Potencia que entra en la batería al cargar, y sale al descargar",
    "Power this socket supplies to what is plugged in": "Potencia que esta toma entrega a lo que está conectado",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Potencia por el puerto AC: SALE alimenta la casa, ENTRA toma energía",
    "The battery's state of charge": "El nivel de carga de la batería",
    "Whether the battery is charging now": "Si la batería se está cargando ahora",
    "Power from this solar panel input": "Potencia de esta entrada de panel solar",
    "Power coming in": "Potencia que entra",
    "Power going out": "Potencia que sale",
    "No power flowing": "No fluye potencia",
    "Grid connection port": "Puerto de red",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solar por panel",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Potencia solar, de la casa, de la red y de la batería, tal como la informan los dispositivos ahora. ENTRA es la potencia que llega, SALE la que se va.",
    "Solar": "Solar",
    "Home": "Casa",
    "Grid": "Red",
    "Battery": "Batería",
    "IN": "ENTRA",
    "OUT": "SALE",
    "Idle": "En reposo",
    "Charging": "Cargando",
    "Not charging": "No se está cargando",
    "Offline: showing the last readings": "Sin conexión: se muestran las últimas lecturas",
    "No devices yet": "Aún no hay dispositivos",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "El plugin aún no ha recibido lecturas de tus dispositivos. Suelen llegar en menos de un minuto.",
    "This page checks again every few seconds while it is open.": "Esta página vuelve a comprobarlo cada pocos segundos mientras esté abierta.",
    "App": "App",
    "Values from the developer API's MQTT pushes": "Valores de los envíos MQTT de la API de desarrollador",
    "Values from the developer API's REST quota": "Valores de la cuota REST de la API de desarrollador",
    "Values from the EcoFlow app's stream": "Valores del flujo de la aplicación EcoFlow",
    "Input": "Entrada",
    "Output": "Salida",
    "AC input": "Entrada AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Potencia que entra en la estación por todas sus entradas",
    "Power the station supplies on all its outputs": "Potencia que la estación entrega por todas sus salidas",
    "Power coming in through the AC input": "Potencia que entra por la entrada AC",
    "Power the AC sockets supply": "Potencia que entregan las tomas AC",
    "Power the USB-A ports supply": "Potencia que entregan los puertos USB-A",
    "Power the USB-C ports supply": "Potencia que entregan los puertos USB-C"
  },
  "pt": {
    "Loading": "A carregar",
    "Waiting for its first readings": "À espera das primeiras leituras",
    "Loading the devices": "A carregar os dispositivos",
    "{d}d {h}h": "{d} d {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} até à carga completa",
    "{time} left": "faltam {time}",
    "Time until the battery is full at the current power, as the device estimates it": "Tempo até a bateria estar cheia à potência atual, segundo a estimativa do dispositivo",
    "Time until the battery is empty at the current power, as the device estimates it": "Tempo até a bateria se esgotar à potência atual, segundo a estimativa do dispositivo",
    "Untested": "Não testado",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "As leituras deste modelo vêm de projetos de código aberto e ainda não foram verificados num dispositivo real",
    "Power from the solar panels now": "Potência dos painéis solares agora",
    "Power the home uses now": "Potência que a casa consome agora",
    "Power exchanged with the grid: IN is import, OUT is export": "Potência trocada com a rede: ENTRA é importação, SAI é exportação",
    "Power into the battery while charging, out of it while discharging": "Potência que entra na bateria ao carregar, e sai ao descarregar",
    "Power this socket supplies to what is plugged in": "Potência que esta tomada fornece ao que está ligado",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Potência pela porta AC: SAI alimenta a casa, ENTRA recebe energia",
    "The battery's state of charge": "O nível de carga da bateria",
    "Whether the battery is charging now": "Se a bateria está a carregar agora",
    "Power from this solar panel input": "Potência desta entrada de painel solar",
    "Power coming in": "Potência que entra",
    "Power going out": "Potência que sai",
    "No power flowing": "Não há potência a circular",
    "Grid connection port": "Porta da rede",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solar por painel",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Potência solar, da casa, da rede e da bateria, tal como os dispositivos a comunicam agora. ENTRA é a potência que chega, SAI a que sai.",
    "Solar": "Solar",
    "Home": "Casa",
    "Grid": "Rede",
    "Battery": "Bateria",
    "IN": "ENTRA",
    "OUT": "SAI",
    "Idle": "Parado",
    "Charging": "A carregar",
    "Not charging": "Não está a carregar",
    "Offline: showing the last readings": "Offline: a mostrar as últimas leituras",
    "No devices yet": "Ainda não há dispositivos",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "O plugin ainda não recebeu leituras dos seus dispositivos. Costumam chegar em menos de um minuto.",
    "This page checks again every few seconds while it is open.": "Esta página volta a verificar a cada poucos segundos enquanto estiver aberta.",
    "App": "App",
    "Values from the developer API's MQTT pushes": "Valores dos envios MQTT da API de programador",
    "Values from the developer API's REST quota": "Valores da quota REST da API de programador",
    "Values from the EcoFlow app's stream": "Valores do fluxo da aplicação EcoFlow",
    "Input": "Entrada",
    "Output": "Saída",
    "AC input": "Entrada AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Potência que entra na estação por todas as suas entradas",
    "Power the station supplies on all its outputs": "Potência que a estação fornece em todas as suas saídas",
    "Power coming in through the AC input": "Potência que entra pela entrada AC",
    "Power the AC sockets supply": "Potência fornecida pelas tomadas AC",
    "Power the USB-A ports supply": "Potência fornecida pelas portas USB-A",
    "Power the USB-C ports supply": "Potência fornecida pelas portas USB-C"
  }
});

"""#),
        "icon.svg": WebFile(contentType: "image/svg+xml", body: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 150 150" role="img" aria-label="EcoFlow">
  <g fill="currentColor">
    <rect x="22" y="54" width="51" height="8.4"/>
    <rect x="22" y="71" width="51" height="8.4"/>
    <rect x="22" y="88" width="51" height="8.4"/>
    <rect x="78" y="54" width="50" height="8.4"/>
    <rect x="78" y="71" width="50" height="8.4"/>
    <rect x="78" y="71" width="8.4" height="25.4"/>
  </g>
</svg>

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>EcoFlow</title>
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* One card per device: its battery first, then the four flows as IN and OUT, then the solar by panel. */
  .devices { display: grid; gap: 14px; }
  .devices > .card { margin: 0; min-width: 0; }
  .device { display: grid; gap: 14px; align-content: start; }
  .device.enter { animation: materialize var(--normal) var(--ease-out); }

  .device-head h2 { margin: 0; }
  .title-line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .way.source { background: var(--material-thin); color: var(--muted); border: 1px solid var(--line); }
  /* A model not yet checked on a real device: the warning tint, beside the source. */
  .way.untested { background: color-mix(in srgb, var(--warn) 16%, transparent); color: var(--warn); }
  .serial { margin: 2px 0 0; font-size: 0.8125rem; color: var(--muted); font-variant-numeric: tabular-nums; }

  /* The battery leads: the largest figure on the card, its level beside the graphic and its state after it. */
  .battery-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .battery-line .figure { display: flex; align-items: center; gap: 12px; font-size: 2.5rem; font-weight: 650; line-height: 1; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
  .battery-line .figure small { font-size: 0.5em; font-weight: 500; opacity: 0.7; }
  /* The time to full or to empty, beside the charging state; its own line under it on a narrow card. */
  .battery-state { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: 6px 10px; }
  .remaining { font-size: 0.8125rem; color: var(--muted); font-variant-numeric: tabular-nums; }
  .flow.wide { grid-column: 1 / -1; }
  .value { display: flex; align-items: center; gap: 8px; }
  .spark { flex: 1; min-width: 0; height: 24px; }
  .spark svg { width: 100%; height: 100%; overflow: visible; }
  /* The sparkline's loader: a short line that shimmers across the slot until the reading's last hour arrives. */
  .spark-loader { display: block; width: 100%; height: 2px; margin-top: 11px; border-radius: 2px; opacity: 0.5;
    background: linear-gradient(90deg, transparent, var(--muted), transparent) 0 0 / 200% 100%; animation: spark-shimmer 1.4s linear infinite; }
  @keyframes spark-shimmer { from { background-position: 100% 0; } to { background-position: -100% 0; } }
  @media (prefers-reduced-motion: reduce) { .spark-loader { animation: none; } }
  .spark polyline { fill: none; stroke: var(--muted); stroke-width: 1.5; stroke-linejoin: round; stroke-linecap: round; opacity: 0.7; vector-effect: non-scaling-stroke; }
  .pv-tile { position: relative; }
  .pv-tile .way { position: absolute; top: 8px; right: 8px; }
  .arrow { display: inline-block; width: 0; height: 0; margin-right: 8px; vertical-align: middle; border-left: 6px solid transparent; border-right: 6px solid transparent; }
  .arrow.in { border-bottom: 9px solid var(--ok); }
  .arrow.out { border-top: 9px solid var(--warn); }
  .battery-mini { display: inline-flex; color: var(--ok); line-height: 0; }
  .battery-mini svg { width: 48px; height: 48px; overflow: visible; }
  .battery-mini rect.bat-body, .battery-mini path.bat-terminal { fill: none; stroke: currentColor; stroke-width: 1.6; }
  .battery-mini path.bat-terminal { stroke-linecap: round; }
  .battery-mini .bat-bar { fill: currentColor; opacity: 0.2; }
  .battery-mini .bat-bar.on { opacity: 1; }

  /* The flows: two columns at every phone width, so the card stays short. */
  .flows { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .flow { padding: 12px 14px; border-radius: 16px; background: var(--material-thin); border: 1px solid var(--line); min-width: 0; }
  .flow .label { font-size: 0.8125rem; color: var(--muted); display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .flow .value { font-size: 1.5rem; font-weight: 650; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; margin-top: 4px; }
  .flow .value small { font-size: 0.6em; font-weight: 500; opacity: 0.7; margin-left: 2px; }
  .way { font-size: 0.75rem; font-weight: 700; letter-spacing: 0.04em; padding: 2px 8px; border-radius: 999px; }
  .way.in { background: color-mix(in srgb, var(--ok) 16%, transparent); color: var(--ok); }
  .way.out { background: color-mix(in srgb, var(--warn) 16%, transparent); color: var(--warn); }
  .way.idle { background: var(--material-thin); color: var(--muted); }

  /* The panels: four tiles in a row; the label is a caption, not a sentence. */
  .panels { display: grid; gap: 8px; }
  .panels > .caption { margin: 0; font-size: 0.8125rem; color: var(--muted); }
  .panel-row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
  .pv-tile { padding: 10px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); min-width: 0; }
  .pv-tile .label { display: block; font-size: 0.75rem; color: var(--muted); }
  .pv-tile .value { display: block; font-size: 1.0625rem; font-weight: 650; font-variant-numeric: tabular-nums; margin-top: 2px; }
  .pv-tile .value small { font-size: 0.6em; font-weight: 500; opacity: 0.7; }
  @media (max-width: 359px) { .panel-row { grid-template-columns: repeat(2, minmax(0, 1fr)); } }

  .note { font-size: 0.8125rem; color: var(--muted); margin: 0; }

  /* No readings yet: the shared empty card, with a sentence on why and when the page looks again. */
  .card.empty { text-align: center; padding: 28px 20px; }
  .card.empty h2 { margin: 0 0 6px; }
  .card.empty p { margin: 0 auto; max-width: 34em; }
  .card.empty p + p { margin-top: 6px; }

  /* A device on its way: shimmering bars where its battery and flows will be, as the sparklines' loader shimmers. */
  .placeholder-bar { display: block; height: 12px; border-radius: 6px; opacity: 0.45;
    background: linear-gradient(90deg, var(--line), var(--muted), var(--line)) 0 0 / 200% 100%; animation: spark-shimmer 1.4s linear infinite; }
  .placeholder-bar.title { width: 40%; height: 18px; }
  .placeholder-bar.figure { width: 30%; height: 36px; border-radius: 10px; }
  .placeholder-bar.label { width: 45%; }
  .placeholder-bar.value { width: 60%; height: 22px; margin-top: 10px; }
  .device.pending .flows .flow { min-height: 72px; }
  @media (prefers-reduced-motion: reduce) { .placeholder-bar { animation: none; } }

  @media (prefers-reduced-motion: reduce) { .device.enter { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main class="page">
  <div class="page-head">
    <div class="who">
      <h1 data-i18n>EcoFlow</h1>
      <p class="note" data-i18n>Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.</p>
    </div>
  </div>
  <section id="devices" class="devices" aria-live="polite"></section>
</main>
<script src="/i18n.js"></script>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
