// The Elgato Key Lights page, after the Homebridge plugin's: the lights the plugin instance knows (refreshed
// every two seconds while the page is visible, redrawn only when something changed), the ones it tried that did not
// answer, and the Excluded ones; the lights Bonjour finds on the network; checking a light at an address. It writes no
// settings (docs/adr/0002-schema-declares-every-setting.md): a light's settings and the plugin's open the Settings pages.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, request, explain, assistant, act, poll, renderKeyed, canonicalMAC } = homeswift;

  const list = $("#lights");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "—");
  // The light's colour on its dot: warm at 2900 K, cool at 7000 K.
  const tint = (mirek) => (mirek ? `hsl(${mirek > 250 ? 35 : 210}, 90%, ${55 + Math.abs(mirek - 250) / 10}%)` : "var(--muted)");

  // MARK: Where settings are edited: the plugin's Settings page, and each light's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const accessoryID = (mac) => `ElgatoKeyLights:${canonicalMAC(mac)}`;
  const lightSettings = (mac) => `${pluginSettings}?accessory=${encodeURIComponent(accessoryID(mac))}`;

  // MARK: The lights

  let lights = [];
  let pending = [];      // lights the plugin tried that are not running: connecting, or they did not answer
  let discovered = [];   // the lights Bonjour announces
  let excluded = [];     // the lights left out of the bridge

  /// Why a light is not running, for its card and Explain.
  function offlineProblem(light) {
    if (light.status === "initializing") return null;
    if (light.error) return `The Elgato light ${light.name} did not answer at ${light.host}:${light.port}: ${light.error}`;
    return `The Elgato light ${light.name} is configured at ${light.host}:${light.port} but has not answered.`;
  }

  /// Tests the connection to a light at its address, the answer in a dialog.
  async function testConnection(light) {
    try {
      const { light: answer } = await request(`probe?host=${encodeURIComponent(light.host)}&port=${light.port}`);
      HomeswiftCommon.showAlert(t("{name} answered in {ms} ms ({model}, firmware {firmware}).", { name: answer.name, ms: answer.milliseconds, model: answer.model, firmware: answer.firmware ?? "?" }));
    } catch (e) {
      HomeswiftCommon.showAlert(e.message);
    }
  }

  const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));

  function lightCard(light) {
    if (light.excluded) return excludedCard(light);
    if (light.offline) return offlineCard(light);
    const [state, kind] = !light.reachable ? [t("Not responding"), "away"] : light.on ? [t("On"), "on"] : [t("Off"), "standby"];
    return el("div", { class: "card light" },
      el("div", { class: "server-head" },
        tile("bulb", light.on ? "yellow" : "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: [light.model, light.serial].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts" },
        fact(t("Brightness"), light.on ? `${light.brightness} %` : "—"),
        el("div", { class: "fact" }, el("span", { text: t("Colour") }),
          el("b", { class: "colour" }, el("span", { class: "glow", style: `background:${light.on ? tint(light.temperature) : "var(--line)"}` }), kelvin(light.temperature))),
        fact(t("Firmware"), light.firmware || "—")),
      !light.reachable ? explain({
        error: `The Elgato light ${light.name} does not answer at ${light.host}:${light.port}.`,
        context: "The Homeswift plugin polls the light's HTTP API (/elgato/lights) every second; a light that misses its polls shows as not responding.",
        device: { model: light.model, firmware: light.firmware, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, light.pinned ? t("from config.json") : null, light.mac].filter(Boolean).join(" · ") }),
        // The same menu as the Accessories page's cards, with what this page adds.
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          light.reachable ? { label: t("Identify"), icon: "identify", onSelect: () => request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
          { label: t("Test connection"), icon: "send", onSelect: () => testConnection(light) },
          { label: t("Settings"), icon: "gear", href: lightSettings(light.mac) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessoryID(light.mac))}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my light {name}: ", { name: light.name })) } : null,
        ])));
  }

  /// A light the plugin tried that is not running, as the Homebridge plugin lists one that did not answer: offline,
  /// with Explain and where its address is set.
  function offlineCard(light) {
    const connecting = light.status === "initializing";
    const [state, kind] = connecting ? [t("Connecting…"), "standby"] : [t("Not responding"), "away"];
    const problem = offlineProblem(light);
    return el("div", { class: "card light is-offline" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.model || "Key Light" })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("p", { class: "muted note", text: connecting ? t("Homeswift is asking the light who it is.") : t("It keeps its place in the Home app and is tried again when Bonjour announces it.") }),
      problem ? explain({
        error: problem,
        context: "The Homeswift plugin connects to a light at start (GET /elgato/accessory-info, /elgato/lights and /elgato/lights/settings, 5 second timeout) and retries when Bonjour announces it.",
        device: { model: light.model, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [`${light.host}:${light.port}`, light.pinned ? t("from config.json") : null, light.mac].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          { label: t("Test connection"), icon: "send", onSelect: () => testConnection(light) },
          light.pinned ? { label: t("Lights by address"), icon: "gear", href: pluginSettings } : null,
          { label: t("Settings"), icon: "gear", href: lightSettings(light.mac) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessoryID(light.mac))}` },
        ])));
  }

  /// A light left out of the bridge: its settings bring it back.
  function excludedCard(light) {
    return el("div", { class: "card light is-disabled" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.mac })),
        el("span", { class: "pill status standby", text: t("Excluded") })),
      el("p", { class: "muted note", text: t("Not on the bridge, nor in the Home app. Its settings bring it back.") }),
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: light.mac }),
        el("a", { class: "button", href: lightSettings(light.mac), actionIcon: "gear", text: t("Settings") })));
  }

  /// The lights the plugin runs, then the ones it tried that are not running (offline), then the Excluded ones.
  function allLights() {
    const running = new Set(lights.map((light) => canonicalMAC(light.mac)));
    const offline = pending.filter((light) => !running.has(canonicalMAC(light.mac))).map((light) => ({ ...light, offline: true }));
    return [...lights, ...offline, ...excluded.map((light) => ({ ...light, excluded: true }))];
  }

  // A card drawn again because its light changed (every brightness step) stays still: only a light new to the
  // page arrives with the material's animation.
  const shown = new Set();
  function card(light) {
    const node = lightCard(light);
    const key = canonicalMAC(light.mac);
    if (shown.has(key)) node.classList.add("redrawn");
    shown.add(key);
    return node;
  }

  async function refresh() {
    try {
      ({ lights, pending = [], discovered = [], excluded = [] } = await request("lights"));
      renderDiscovered();
      const all = allLights();
      if (all.length === 0) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach goes in Lights by address, in the plugin's Settings.") })));
        }
        return;
      }
      renderKeyed(list, all, (light) => canonicalMAC(light.mac), card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: On the network: what Bonjour announces (Homeswift browses all the time; the Homebridge plugin's
  // Discover button scanned for 5 seconds). A light found here is in the Home app once it answered.

  const discoverBox = $("#discovered");

  function discoveredRow(light) {
    const [state, kind] = light.running ? [t("In the Home app"), "on"] : [t("Not answering"), "away"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: light.name }),
        el("div", { class: "muted", text: [light.model, light.address || light.host, light.mac].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      el("a", { class: "button", href: lightSettings(light.mac), actionIcon: "gear", text: t("Settings") }));
  }

  function renderDiscovered() {
    if (discoverBox.classList.contains("hidden")) return;
    const rows = discovered.length
      ? discovered.map(discoveredRow)
      : [el("p", { class: "muted", text: t("No light announces itself over Bonjour right now. A light on another network or behind a container without multicast goes in Lights by address, in the plugin's Settings.") })];
    const key = JSON.stringify(discovered);
    if (discoverBox.dataset.json === key) return;
    discoverBox.dataset.json = key;
    discoverBox.replaceChildren(
      el("p", { class: "muted", text: t("The lights Bonjour finds on the network, kept up to date while Homeswift runs. Each is in the Home app once it answers; its settings name it and set what it does when switched on.") }),
      ...rows);
  }

  $("#discover-toggle").addEventListener("click", () => {
    const open = discoverBox.classList.toggle("hidden") === false;
    $("#discover-toggle").setAttribute("aria-expanded", String(open));
    delete discoverBox.dataset.json;
    renderDiscovered();
  });

  // MARK: Checking a light at its address, for networks Bonjour does not cross: who answers there, and where to keep it.

  const checkBox = $("#check-light");
  const host = el("input", { type: "text", placeholder: "192.168.1.50", inputmode: "decimal", spellcheck: false, "aria-label": t("IP address or host name") });
  const port = el("input", { type: "number", value: 9123, min: 1, max: 65535, "aria-label": t("Port") });
  const checkStatus = el("p", { class: "status-line muted" });
  checkBox.replaceChildren(
    el("p", { class: "muted", text: t("For a light Bonjour does not reach, e.g. on another network or from a container: Homeswift asks it who it is. To keep it, add its address to Lights by address in the plugin's Settings.") }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, checkAddress, checkFailed); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("IP address or host name") }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: t("Port") }), port),
      el("button", { actionIcon: "send", class: "primary", type: "submit", text: t("Check") })),
    checkStatus);
  $("#check-toggle").addEventListener("click", () => {
    const open = checkBox.classList.toggle("hidden") === false;
    $("#check-toggle").setAttribute("aria-expanded", String(open));
    if (open) host.focus();
  });

  function checkFailed(message) {
    checkStatus.className = "status-line error";
    checkStatus.replaceChildren(message, explain({ error: message, context: "Checking an Elgato light by address from the Homeswift plugin page: GET /elgato/accessory-info on the address and port given.", device: { model: "Elgato Key Light" } }));
  }

  async function checkAddress() {
    const address = host.value.trim();
    if (!address) throw new Error(t("Enter the light's IP address or host name."));
    checkStatus.className = "status-line muted";
    checkStatus.textContent = t("Asking {host}:{port}…", { host: address, port: port.value });
    const { light } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    checkStatus.className = "status-line ok";
    checkStatus.replaceChildren(
      t("{name} answered in {ms} ms ({model}, firmware {firmware}).", { name: light.name, ms: light.milliseconds, model: light.model, firmware: light.firmware ?? "?" }), " ",
      light.mac ? t("Its MAC address is {mac}.", { mac: light.mac }) : t("It did not give its MAC address; its Elgato Control Center app shows it."), " ",
      el("a", { href: pluginSettings, text: t("Add it to Lights by address") }));
  }

  // Without an Assistant, a tip on how to get one (Explain on errors), as the Homebridge plugin shows: one sentence
  // to translate, the block's name in bold where the language puts it.
  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  poll(refresh);
})();
