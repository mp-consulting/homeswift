// The eWeLink page, after the Homebridge plugin's settings UI without its login: Setup signs in (a card leads to it
// while the account is not signed in), then the account's devices with their LAN and RF details (an mDNS scan runs
// while the cloud answers). It writes no settings (docs/adr/0002-schema-declares-every-setting.md): the plugin's are on
// its Settings page, and a device's row opens its own there. The session stays in the plugin: the browser never sees a
// token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const showDevices = (shown) => $("#step-devices").classList.toggle("hidden", !shown);

  let devices = [];
  let mode = null;    // the connection mode the plugin reports

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there.

  const deviceSettings = (deviceId) => homeswift.accessorySettings(`eWeLink:${deviceId}`);

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${mode || "auto"}.`].filter(Boolean).join(" ");

  function showProblem(container, message, context) {
    container.classList.remove("hidden");
    container.replaceChildren(el("p", { text: message }), explain({ error: message, context: assistantContext(context) }));
  }

  function clearProblem(container) {
    container.classList.add("hidden");
    container.replaceChildren();
  }

  /// Why a device needs attention, or null.
  function deviceProblem(device) {
    if (!device.online) return "The eWeLink cloud reports this device as offline.";
    if (device.lanEnabled && !device.lanIp) return "LAN control is enabled for this device, but it was not found on the local network (no IP address over mDNS).";
    return null;
  }

  // MARK: Devices

  function deviceRow(device) {
    const badges = [];
    if (device.isRfSubdevice) badges.push(el("span", { class: "pill rf", text: "RF" }));
    if (device.lanEnabled && device.lanIp) badges.push(el("span", { class: "pill lan", text: t("LAN: {address}", { address: device.lanIp }) }));
    else if (device.lanEnabled) badges.push(el("span", { class: "pill lan-warn", text: t("LAN: No IP") }));
    else badges.push(el("span", { class: "pill", text: t("Cloud") }));
    badges.push(el("span", { class: `pill status ${device.online ? "on" : "away"}`, text: device.online ? t("Online") : t("Offline") }));
    const problem = deviceProblem(device);
    return el("li", { class: `device ${device.isRfSubdevice ? "rf" : ""}` },
      el("div", { class: "info" },
        el("div", { class: "name", text: device.name }),
        el("div", { class: "meta" },
          el("span", { class: "mono", text: t("ID: {id}", { id: device.deviceId }) }),
          el("span", { text: t("{brand} — {model} (UIID: {uiid})", { brand: device.brand || t("Unknown"), model: device.model || t("Unknown"), uiid: device.uiid != null ? String(device.uiid) : t("N/A") }) })),
        device.buttons && device.buttons.length ? el("div", { class: "buttons" }, device.buttons.map((button) => el("span", { text: button }))) : null),
      el("div", { class: "badges" }, badges,
        el("a", { class: "button small", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Settings"), "aria-label": t("Settings of {name}", { name: device.name }) })),
      problem ? explain({
        error: problem,
        context: assistantContext("The user is looking at the device list of the eWeLink plugin settings."),
        device: {
          name: device.name, deviceId: device.deviceId, brand: device.brand, model: device.model, uiid: device.uiid, online: !!device.online,
          lanEnabled: !!device.lanEnabled, lanAddressFound: !!device.lanIp, rfSubdevice: !!device.isRfSubdevice, parentDeviceId: device.parentDeviceId,
        },
      }) : null);
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#devices").replaceChildren(...(devices.length ? devices.map(deviceRow)
      : [el("li", { class: "empty" }, el("p", { text: t("No devices found") }))]));
  }

  async function loadDevices() {
    const button = $("#refresh");
    await act(button, async () => {
      clearProblem($("#devices-problem"));
      try {
        const answer = await request("devices");
        devices = answer.devices || [];
        renderDevices();
      } catch (e) {
        showProblem($("#devices-problem"), e.message || t("Failed to load devices"),
          "Loading the device list from the eWeLink cloud (plus a 3 second mDNS LAN scan) failed in the plugin settings.");
      }
    });
    await loadStatus();
  }

  async function loadStatus() {
    try {
      const status = await request("status");
      // The plugin answers without its platform while it reloads: only a platform's answer says signed out.
      if ("mode" in status && !status.configured) { showSetup(); return; }
      if (status.mode) mode = status.mode;
      $("#status").replaceChildren(
        fact(t("Cloud"), status.websocket ? t("Connected") : status.retrying ? t("Retrying") : status.initialized ? t("Reconnecting") : t("Not connected")),
        fact(t("On the LAN"), tn("{n} device", "{n} devices", status.lanDevices ?? 0)),
        fact(t("In HomeKit"), tn("{n} accessory", "{n} accessories", status.accessories ?? 0)));
    } catch { $("#status").replaceChildren(); }
  }

  /// Not signed in: the card to Setup in place of the devices.
  function showSetup() {
    showDevices(false);
    $("#setup").replaceChildren(homeswift.setupCard({
      title: t("Sign in to your eWeLink account"),
      text: t("Add accessories signs in with your eWeLink email or phone number; the account's devices come with it."),
      glyph: "key",
    }));
  }

  // MARK: Events

  $("#refresh").addEventListener("click", loadDevices);

  // MARK: Start: the plugin's state: signed in, its devices; else the card to Setup.

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  (async () => {
    let status;
    try { status = await request("status"); } catch { /* the plugin is restarting: show the devices it can list */ }
    if (status && "mode" in status && !status.configured) { showSetup(); return; }
    if (status?.mode) mode = status.mode;
    showDevices(true);
    await loadDevices();
  })();
})();
