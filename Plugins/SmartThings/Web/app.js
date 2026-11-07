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
      status.eventsNote ? el("p", { class: "muted", text: status.sseGranted ? t("SmartThings refused the event stream: updates come by polling for now.") : status.eventsNote }) : null,
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
