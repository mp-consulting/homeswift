// The eWeLink page, after the Homebridge plugin's settings UI without its login: Setup signs in (a card leads to it
// while the account is not signed in), then the account's devices with their LAN and RF details (an mDNS scan runs
// while the cloud answers), the connection settings, and saving them into this instance's block, which reloads the
// plugin. The session stays in the plugin: the browser never sees a token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, name, explain, api, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const steps = { devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  let devices = [];
  let config = {};

  // MARK: config.json: this instance's block, read and written through the signed-in UI.

  async function readBlock() {
    config = (await homeswift.readBlock()) || {};
    return config;
  }

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${config.mode || "auto"}.`,
    config.countryCode ? `Account country code: ${config.countryCode}.` : ""].filter(Boolean).join(" ");

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
      el("div", { class: "badges" }, badges),
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
      $("#status").replaceChildren(
        fact(t("Cloud"), status.websocket ? t("Connected") : status.retrying ? t("Retrying") : status.initialized ? t("Reconnecting") : t("Not connected")),
        fact(t("On the LAN"), tn("{n} device", "{n} devices", status.lanDevices ?? 0)),
        fact(t("In HomeKit"), tn("{n} accessory", "{n} accessories", status.accessories ?? 0)));
    } catch { $("#status").replaceChildren(); }
  }

  // MARK: Settings

  function prefillSettings() {
    $("#mode").value = config.mode || "auto";
    $("#debug").checked = !!config.debug;
    $("#offline-as-off").checked = !!config.offlineAsOff;
  }

  /// The account Setup signed in to, with Sign in again.
  function showAccount() {
    $("#account-text").textContent = config.username ? t("Signed in as {account}.", { account: config.username }) : t("Signed in.");
  }

  /// Not signed in: the card to Setup in place of the devices.
  function showSetup() {
    showStep(null);
    $("#setup").replaceChildren(homeswift.setupCard({
      title: t("Sign in to your eWeLink account"),
      text: t("Add accessories signs in with your eWeLink email or phone number; the account's devices come with it."),
      glyph: "key",
    }));
  }

  async function saveConfiguration(button) {
    await act(button, async () => {
      clearProblem($("#save-problem"));
      try {
        let block;
        const result = await homeswift.updateBlock((current) => {
          block = { ...current, platform: "eWeLink", name: current.name || name || "eWeLink", mode: $("#mode").value };
          if ($("#debug").checked) block.debug = true; else delete block.debug;
          if ($("#offline-as-off").checked) block.offlineAsOff = true; else delete block.offlineAsOff;
          return block;
        });
        config = block;
        const pending = result.restartNeeded || [];
        $("#restart").classList.toggle("hidden", pending.length === 0);
        $("#complete-text").replaceChildren(el("strong", { text: t("All done!") }), " ", pending.length
          ? t("The configuration is saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.map((change) => HomeswiftI18n.message(change)).join("; ") })
          : t("The configuration is saved and the plugin reloaded with it."));
        $("#restart-status").textContent = "";
        showStep("complete");
      } catch (e) {
        showProblem($("#save-problem"), e.message || t("Failed to save configuration"), "Saving this instance's block of config.json from the eWeLink plugin settings failed.");
      }
    });
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    $("#restart-status").textContent = t("Restarting…");
    let back = false;
    for (let tries = 0; tries < 60 && !back; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("status"); back = true; } catch { /* not back yet */ }
    }
    $("#restart-status").textContent = back ? t("Homeswift restarted.") : t("Homeswift has not answered for a minute: check its log, then reload this page.");
    $("#restart").classList.toggle("hidden", back);
  }

  // MARK: Events

  const tabs = [["#tab-devices", "#pane-devices"], ["#tab-settings", "#pane-settings"]];
  for (const [tab, pane] of tabs) {
    $(tab).addEventListener("click", () => {
      for (const [otherTab, otherPane] of tabs) {
        const selected = otherTab === tab;
        $(otherTab).classList.toggle("on", selected);
        $(otherTab).setAttribute("aria-selected", String(selected));
        $(otherPane).classList.toggle("hidden", !selected);
      }
    });
  }

  $("#refresh").addEventListener("click", loadDevices);
  $("#save-settings").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#back").addEventListener("click", () => { showStep("devices"); loadDevices(); });
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, restart).catch((e) => HomeswiftCommon.showAlert(e.message)));

  // MARK: Config changes made elsewhere (the Expert editor, another tab, the Assistant), as the Homebridge page's
  // configChanged: the web UI sends no such event, so the block is read again whenever the page comes back into
  // view, and the settings are filled in again only when it changed. Unsaved choices stay otherwise.

  /// JSON with the keys sorted, so the same block written in another order compares equal.
  const canonical = (value) => JSON.stringify(value, (_, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : v);

  async function followConfigChanges() {
    if (document.hidden) return;
    const before = canonical(config);
    let fresh;
    try { fresh = (await homeswift.readBlock()) || {}; } catch { return; }
    if (canonical(fresh) === before) return;
    config = fresh;
    prefillSettings();
    showAccount();
  }
  document.addEventListener("visibilitychange", followConfigChanges);
  window.addEventListener("focus", followConfigChanges);

  // MARK: Start: the block, then the plugin's state: signed in, its devices; else the card to Setup.

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  (async () => {
    try { await readBlock(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
    prefillSettings();
    showAccount();
    let status;
    try { status = await request("status"); } catch { /* the plugin is restarting: show what the block says */ }
    if (status && "mode" in status ? !status.configured : !config.username) { showSetup(); return; }
    showStep("devices");
    await loadDevices();
  })();
})();
