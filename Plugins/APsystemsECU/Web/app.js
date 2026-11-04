// The APsystems ECU page: each ECU of this instance with its production as last read (power, today, lifetime, an
// ECU-C's grid and home power) and its inverters (power, channels, temperature, signal). It writes nothing: the ECUs'
// addresses are Plugin Settings, an ECU's or an inverter's own settings are its Accessory Settings.
(() => {
  "use strict";
  const { $, el, request, poll, fact, tile } = homeswift;
  const { t } = HomeswiftI18n;

  $("#head-tile").replaceWith(tile("sun", "orange", true));

  const watts = (value) => `${Math.round(value).toLocaleString()} W`;
  const kWh = (value) => `${Number(value).toLocaleString(undefined, { maximumFractionDigits: 2 })} kWh`;
  const time = (iso) => (iso ? new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—");

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
      inverter.powers.length > 1 ? fact(t("Panels"), inverter.powers.map((value) => Math.round(value)).join(" · ") + " W") : null,
      inverter.voltages.length && inverter.online ? fact(t("Voltage"), inverter.voltages.join(" · ") + " V") : null,
      inverter.temperature !== undefined ? fact(t("Temperature"), homeswift.formatTemperature(inverter.temperature)) : null,
      inverter.frequency !== undefined ? fact(t("Frequency"), `${inverter.frequency.toFixed(1)} Hz`) : null,
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
          el("div", { class: "muted", text: [ecu.model, ecu.firmware, ecu.port === 8899 ? ecu.host : `${ecu.host}:${ecu.port}`].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${answering ? "on" : ecu.ecuID ? "away" : "standby"}`, text: answering ? t("Answering") : ecu.ecuID ? t("Not responding") : t("Not reached yet") }),
        settingsLink(ecu.accessoryID, name)),
      facts, ...problems,
      inverters.length ? el("div", { class: "inverters", role: "list", "aria-label": t("Inverters of {name}", { name }) }, ...inverters.map(inverterRow)) : null);
  }

  /// Redraws when what the plugin reports changed.
  let shown = "";
  async function refresh() {
    let status;
    try { status = await request("status"); } catch { return; /* the instance is restarting */ }
    const next = JSON.stringify(status);
    if (next === shown) return;
    shown = next;
    const ecus = status.ecus ?? [];
    $("#empty").replaceChildren(ecus.length ? "" : el("div", { class: "card" },
      el("h2", { text: t("Add your ECU") }),
      el("p", { class: "muted", text: t("The ECU does not announce itself on the network: enter its address in this plugin's settings, under ECUs. Your router lists it, often as an Espressif device; give it a fixed address there.") }),
      el("a", { class: "button primary", href: homeswift.settingsAddress, actionIcon: "gear", text: t("Open the settings") })));
    $("#ecus-section").classList.toggle("hidden", !ecus.length);
    $("#ecus").replaceChildren(...ecus.map(ecuCard));
  }

  poll(refresh, 15000);
})();
