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
