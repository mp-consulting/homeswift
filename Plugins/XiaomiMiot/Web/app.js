// The Xiaomi page: the devices this instance runs (refreshed every few seconds while the page is visible), and for one
// device its MIoT spec read now: every property with its value and a control for the writable ones (a switch for a
// bool, a menu for a value list, a number for a range), and a button for each action without parameters
// (docs/clean-room/XiaomiMiot.md section 15.9). Signing in is Setup's (Add accessories); settings are the Settings page's.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, request, explain, poll, renderKeyed, setupCard, drawHidden } = homeswift;

  const list = $("#devices");
  const panel = $("#spec-panel");
  $("#settings-link").href = homeswift.settingsAddress;
  const settingsOf = (accessoryID) => homeswift.accessorySettings(accessoryID);
  const kindIcons = { light: "bulb", outlet: "outlet", switch: "switch", airPurifier: "wind", humidifier: "drop", dehumidifier: "drop", fan: "fan",
    ceilingFan: "fan", heater: "flame", airConditioner: "thermo", curtain: "blind", sensor: "sensor", airMonitor: "sensor", vacuum: "vacuum" };

  const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));

  function deviceCard(device) {
    const [state, kind] = device.problem ? [t("Not published"), "away"] : device.reachable ? [t("Responding"), "on"] : [t("Not responding"), "away"];
    return el("div", { class: `card device${device.reachable ? "" : " is-offline"}` },
      el("div", { class: "server-head" },
        tile(kindIcons[device.kind] || "generic", device.reachable ? "orange" : "grey"),
        el("div", { class: "who" }, el("strong", { text: device.name }), el("div", { class: "muted", text: [device.model, device.deviceId].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts" },
        fact(t("Address"), device.ip),
        fact(t("Firmware"), device.firmware || "—"),
        fact(t("Commands"), device.path === "legacy" ? t("miIO vacuum") : "MIoT")),
      device.problem ? el("p", { class: "muted note", text: HomeswiftI18n.message(device.problem) }) : null,
      !device.reachable && !device.problem ? explain({
        error: `The Xiaomi device ${device.name} does not answer at ${device.ip}.`,
        context: "The Homeswift plugin reaches each device over miIO on UDP port 54321 with its token, polls it, and retries a device that missed 4 polls.",
        device: { model: device.model, path: device.path },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: device.spec || "" }),
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

  async function refresh() {
    try {
      const { devices, excluded = [], accountSetUp } = await request("devices");
      $("#account").replaceChildren(accountSetUp ? "" : setupCard({
        title: t("Your Xiaomi account"),
        text: t("Optional: signing in finds your devices and their tokens. Devices added with a token work without it."),
      }));
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
      renderKeyed(list, devices, (device) => device.deviceId, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: A device's spec

  function describeValue(property, value) {
    if (value === null || value === undefined) return "—";
    const entry = (property.values || []).find((item) => item.value === value);
    const text = entry && entry.description ? `${entry.description} (${value})` : String(value);
    return property.unit && property.unit !== "none" ? `${text} ${property.unit}` : text;
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
    if (property.format === "bool") {
      const box = el("input", { type: "checkbox", "aria-label": t("Change {name}", { name: property.name }) });
      box.checked = property.value === true;
      box.addEventListener("change", () => write(device, property, box.checked, row));
      return box;
    }
    if (property.values && property.values.length) {
      const select = el("select", { "aria-label": t("Change {name}", { name: property.name }) },
        ...property.values.map((item) => el("option", { value: JSON.stringify(item.value), text: item.description || String(item.value) })));
      select.value = JSON.stringify(property.value);
      select.addEventListener("change", () => write(device, property, JSON.parse(select.value), row));
      return select;
    }
    if (property.range) {
      const [min, max, step] = property.range;
      const input = el("input", { type: "number", min, max, step: step || 1, value: property.value ?? "", "aria-label": t("Change {name}", { name: property.name }) });
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

  async function openSpec(device) {
    panel.classList.remove("hidden");
    panel.replaceChildren(el("p", { class: "muted", text: t("Reading {name}…", { name: device.name }) }));
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
    try {
      const { services } = await request(`properties?did=${encodeURIComponent(device.deviceId)}`);
      panel.replaceChildren(
        el("div", { class: "section-head" }, el("h2", { text: device.name }),
          el("div", { class: "actions" },
            el("button", { actionIcon: "update", text: t("Refresh"), onclick: () => openSpec(device) }),
            el("button", { actionIcon: "close", text: t("Close"), onclick: () => panel.classList.add("hidden") }))),
        el("div", { class: "spec" }, ...services.map((service) => el("div", {},
          el("h3", {}, service.description || service.name, service.standard ? "" : el("span", { class: "muted vendor", text: ` · ${t("vendor")}` })),
          ...service.properties.map((property) => propertyRow(device, property)),
          ...service.actions.map((action) => actionRow(device, action))))));
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  poll(refresh, 5000);
})();
