// The Govee page, after the Homebridge plugin's settings page: Devices (the account's and the LAN's devices by type,
// how the plugin reaches each, and a light's Scene Library to browse) and Tools (clear the cache). It writes no
// settings (docs/adr/0002-schema-declares-every-setting.md): signing in is Setup's, and the plugin's settings and each
// device's (its Name, Show As, a light's scenes…) are on the Settings page, which a device's row opens.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, breadcrumb, api, poll, setupAddress } = homeswift;

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there.

  const deviceSettings = (deviceId) => homeswift.accessorySettings(`Govee:${deviceId}`);

  // MARK: Device types, as the Homebridge page lists them

  // `count` says how many there are.
  const typeNames = {
    lightDevices: { count: (n) => tn("{n} light", "{n} lights", n), fresh: t("New light"), title: t("Light Devices"), add: t("Add Light Device"), badge: t("Light") },
    switchDevices: { count: (n) => tn("{n} switch/outlet", "{n} switches/outlets", n), fresh: t("New switch/outlet"), title: t("Switch/Outlet Devices"), add: t("Add Switch Device"), badge: t("Switch/Outlet") },
    thermoDevices: { count: (n) => tn("{n} temperature/humidity sensor", "{n} temperature/humidity sensors", n), fresh: t("New temperature/humidity sensor"), title: t("Temperature/Humidity Sensors"), add: t("Add Sensor"), badge: t("Temp/Humidity Sensor") },
    leakDevices: { count: (n) => tn("{n} leak sensor", "{n} leak sensors", n), fresh: t("New leak sensor"), title: t("Leak Sensors"), add: t("Add Leak Sensor"), badge: t("Leak Sensor") },
    fanDevices: { count: (n) => tn("{n} fan", "{n} fans", n), fresh: t("New fan"), title: t("Fan Devices"), add: t("Add Fan"), badge: t("Fan") },
    heaterDevices: { count: (n) => tn("{n} heater", "{n} heaters", n), fresh: t("New heater"), title: t("Heater Devices"), add: t("Add Heater"), badge: t("Heater") },
    humidifierDevices: { count: (n) => tn("{n} humidifier", "{n} humidifiers", n), fresh: t("New humidifier"), title: t("Humidifier Devices"), add: t("Add Humidifier"), badge: t("Humidifier") },
    purifierDevices: { count: (n) => tn("{n} air purifier", "{n} air purifiers", n), fresh: t("New air purifier"), title: t("Air Purifier Devices"), add: t("Add Purifier"), badge: t("Air Purifier") },
    dehumidifierDevices: { count: (n) => tn("{n} dehumidifier", "{n} dehumidifiers", n), fresh: t("New dehumidifier"), title: t("Dehumidifier Devices"), add: t("Add Dehumidifier"), badge: t("Dehumidifier") },
    diffuserDevices: { count: (n) => tn("{n} diffuser", "{n} diffusers", n), fresh: t("New diffuser"), title: t("Diffuser Devices"), add: t("Add Diffuser"), badge: t("Diffuser") },
    kettleDevices: { count: (n) => tn("{n} kettle", "{n} kettles", n), fresh: t("New kettle"), title: t("Kettle Devices"), add: t("Add Kettle"), badge: t("Kettle") },
    iceMakerDevices: { count: (n) => tn("{n} ice maker", "{n} ice makers", n), fresh: t("New ice maker"), title: t("Ice Maker Devices"), add: t("Add Ice Maker"), badge: t("Ice Maker") },
  };

  // MARK: State

  let found = [];                     // the devices the plugin found at its start (account and LAN)
  let live = {};                      // the running devices by id: name, transports, a light's scenes
  let signedIn = true;
  const sceneLibraries = {};          // cloud scene libraries by device id
  const iconCache = new Map();
  const openTypes = new Set();
  let browsing = null;                // the light whose Scene Library shows

  /// The type list a model goes in; unknown models are lights.
  const typeFor = (model, given) => (given && typeNames[given] ? given : "lightDevices");

  // MARK: Problems, with the Assistant's Explain when there is one

  /// Error text for the Assistant: Govee's device ids (six to eight bytes) masked; the server masks e-mail and IP
  /// addresses.
  const scrub = (text) => String(text ?? "").replace(/\b[0-9a-f]{2}(?::[0-9a-f]{2}){5,7}\b/gi, "<device id>");

  function problem(container, message, context, device, kind = "error") {
    container.replaceChildren(el("div", { class: "problem" }, el("p", { class: kind, text: message }), explain({ error: scrub(message), context, device })));
  }

  // MARK: Devices tab

  function transportsOf(device) {
    const running = live[device.deviceId];
    if (!running) return null;
    const states = { enabled: t("enabled"), disabled: t("disabled") };
    const pill = (label, state) => (state === "unsupported" ? null : el("span", { class: `pill ${state === "enabled" ? "on" : ""}`, text: label, title: t("{transport}: {state}", { transport: label, state: states[state] ?? state }) }));
    return el("span", { class: "transports" }, pill("LAN", running.lan), pill("AWS", running.aws), pill("BLE", running.ble));
  }

  /// The devices to list: those found at the start, and those running that were not.
  function listed() {
    const all = [...found];
    for (const [deviceId, running] of Object.entries(live)) {
      if (!all.some((device) => device.deviceId === deviceId)) all.push({ deviceId, deviceName: running.name, model: running.model, deviceType: running.list, onBridge: true });
    }
    return all;
  }

  function drawTypes() {
    const devices = listed();
    const container = $("#device-types");
    if (!devices.length) {
      container.replaceChildren(el("p", { class: "muted note", text: t("No devices yet: the plugin lists those of your Govee account and of the LAN once it has started.") }));
      return;
    }
    container.replaceChildren(...Object.keys(typeNames).map((type) => {
      const ofType = devices.filter((device) => typeFor(device.model, device.deviceType) === type);
      if (!ofType.length) return null;
      const names = typeNames[type];
      const section = el("details", { class: "entry type", open: openTypes.has(type) },
        el("summary", {}, el("span", { class: "pill count on", text: String(ofType.length) }), el("span", { class: "entry-name", text: names.title })),
        el("div", { class: "type-body" },
          el("div", { class: "rows" }, ofType.map((device) => {
            const label = live[device.deviceId]?.name || device.deviceName || device.deviceId;
            const state = device.excluded ? el("span", { class: "pill", text: t("Excluded") })
              : device.onBridge || live[device.deviceId] ? null : el("span", { class: "pill", text: t("Not on the bridge") });
            return el("div", { class: `row-device ${device.excluded ? "ignored" : ""}` },
              el("div", { class: "who" },
                el("strong", {}, label, state, transportsOf(device)),
                el("span", { class: "mono", text: [device.deviceId, device.model].filter(Boolean).join(" · ") })),
              el("span", { class: "links" },
                type === "lightDevices" && device.model ? el("button", { actionIcon: "sparkle", class: "link", text: t("Scenes"), "aria-label": t("Scene Library of {name}", { name: label }), onclick: () => browse(device, label) }) : null,
                el("a", { class: "button link", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Settings"), "aria-label": t("Settings of {name}", { name: label }) })));
          })),
          browsing && typeFor(browsing.device.model, browsing.device.deviceType) === type ? library : null));
      section.addEventListener("toggle", () => { if (section.open) openTypes.add(type); else openTypes.delete(type); });
      return section;
    }).filter(Boolean));
  }

  /// Redraws the lists; the Scene Library keeps its place and scroll.
  function renderTypes() {
    drawTypes();
    $("#signed-out").classList.toggle("hidden", signedIn);
  }

  // MARK: The Scene Library, to browse: a light's scenes are its settings

  const library = $("#library");

  function browse(device, label) {
    browsing = { device, label };
    openTypes.add(typeFor(device.model, device.deviceType));
    library.classList.remove("hidden");
    library.replaceChildren(
      el("div", { class: "editor-head" },
        el("div", {}, el("h2", { text: label }), el("p", { class: "muted note", text: t("Scene Library · {model}", { model: device.model }) })),
        el("button", { actionIcon: "restore", class: "link", text: t("Back"), onclick: closeLibrary })),
      el("p", { class: "muted", text: t("The scenes Govee offers for this light and your own DIY effects. Those with a tick are the light's switches in HomeKit. A scene becomes one in the light's settings (Scenes), with the name and the code a tile shows here; the Assistant can add it for you.") }),
      el("div", { id: "picker-status" }),
      el("div", { id: "picker-body" }, el("p", { class: "muted", text: t("Loading scenes…") })),
      el("div", { id: "scene-detail" }),
      el("div", { class: "picker-foot" }, el("span", { id: "picker-count", class: "muted" }),
        el("a", { class: "button", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Open the light's settings") })));
    renderTypes();
    breadcrumb(t("Scenes of {name}", { name: label }), closeLibrary);
    library.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    loadPicker(device);
  }

  function closeLibrary() {
    browsing = null;
    library.classList.add("hidden");
    library.replaceChildren();
    breadcrumb(null);
    renderTypes();
  }

  function iconFor(scene, large = false) {
    const url = scene.iconUrl || scene.iconUrlDark;
    const className = `scene-icon ${large ? "large" : ""}`;
    if (!url) return el("span", { class: `${className} empty`, "aria-hidden": "true" });
    const cached = iconCache.get(url);
    const image = el("img", { class: className, alt: "" });
    if (cached) image.src = cached; else image.dataset.iconUrl = url;
    return image;
  }

  function devicePayload(device) {
    return { deviceId: device.deviceId, model: device.model || "", goodsType: device.goodsType, pactType: device.pactType, pactCode: device.pactCode, versionSoft: device.versionSoft, versionHard: device.versionHard };
  }

  async function loadPicker(device) {
    const body = $("#picker-body");
    if (!body) return;
    try {
      let scenes = sceneLibraries[device.deviceId];
      if (!scenes) {
        scenes = await request("scenes", { method: "POST", body: devicePayload(device) });
        // The bundled fallback is never kept: a sign-in later must reach the device's own list.
        if (scenes?.source !== "offline") sceneLibraries[device.deviceId] = scenes;
      }
      let diys = [];
      try { diys = (await request("diys", { method: "POST", body: devicePayload(device) }))?.diys || []; } catch { diys = []; }
      if (!$("#picker-body") || browsing?.device !== device) return;
      renderPicker(scenes, diys);
    } catch (e) {
      problem(body, e.message || t("Could not load scenes"),
        "Loading the Govee scene library and DIY effects for one light on the plugin's page failed (the bundled catalogue had no entry for this model either).",
        { model: device.model });
    }
  }

  let pickerItems = {};
  let pickerCategory = null;

  function renderPicker(scenes, diys) {
    const body = $("#picker-body");
    const notes = [];
    if (scenes.source === "offline") notes.push(t("Showing the scene list bundled with the plugin. Sign in to your Govee account for the full, device-specific list."));
    if (scenes.warning) notes.push(HomeswiftI18n.message(scenes.warning));
    $("#picker-status").replaceChildren(...notes.map((note) => el("p", { class: "notice", text: note })));

    const groups = scenes.categories.map((category) => ({
      id: `cat-${category.id}`, name: category.name,
      items: category.scenes.map((scene) => ({ key: `scene:${scene.sceneId}`, name: scene.name, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, variants: scene.variants, code: scene.code, sceneId: scene.sceneId, kind: "scene" })),
    }));
    if (diys.length) {
      groups.push({ id: "cat-diy", name: t("My DIY"), items: diys.map((diy) => ({ key: `diy:${diy.diyId}`, name: diy.name, iconUrl: diy.iconUrl, variants: [], code: diy.code, sceneId: diy.diyId, kind: "diy" })) });
    }
    if (!groups.length) {
      body.replaceChildren(el("p", { class: "notice", text: t("Govee returned no scenes for this device.") }));
      return;
    }
    pickerItems = {};
    for (const group of groups) for (const item of group.items) pickerItems[item.key] = item;
    if (!groups.some((g) => g.id === pickerCategory)) pickerCategory = groups[0].id;

    const grid = el("div", { class: "picker-grid" });
    const showCategory = (group) => {
      pickerCategory = group.id;
      for (const button of cats.children) button.classList.toggle("on", button.dataset.id === group.id);
      grid.replaceChildren(...group.items.map((item) => el("button", { class: "tile-scene", "data-key": item.key, "aria-pressed": "false", title: item.name, onclick: () => showScene(item.key) },
        iconFor(item, true), el("span", { class: "name", text: item.name }),
        item.variants.length > 1 ? el("span", { class: "pill variants", text: String(item.variants.length) }) : null)));
      refreshPicker();
      hydrateIcons(grid);
    };
    // Categories down the side: their names are long and a strip across the top had to scroll.
    const cats = el("div", { class: "picker-cats", role: "tablist" }, groups.map((group) => el("button", {
      "data-id": group.id, role: "tab", onclick: () => showCategory(group),
    }, el("span", { text: group.name }), el("span", { class: "count", text: String(group.items.length) }))));
    body.replaceChildren(el("div", { class: "picker" }, cats, grid));
    showCategory(groups.find((g) => g.id === pickerCategory));
  }

  /// A scene's name, id and code, to copy into the light's settings.
  function showScene(key) {
    const item = pickerItems[key];
    const detail = $("#scene-detail");
    if (!item || !detail) return;
    for (const tile of document.querySelectorAll("#picker-body .tile-scene")) tile.setAttribute("aria-pressed", String(tile.dataset.key === key));
    const copy = (text) => el("button", { actionIcon: "copy", class: "link", text: t("Copy"), onclick: async (event) => {
      try { await navigator.clipboard.writeText(text); event.currentTarget.textContent = t("Copied"); } catch { /* the code stays selectable */ }
    } });
    const row = (label, value) => el("div", { class: "scene-field" }, el("span", { class: "muted", text: label }), el("span", { class: "mono", text: String(value) }), copy(String(value)));
    detail.replaceChildren(el("div", { class: "scene-panel" },
      el("div", { class: "scene-panel-head" }, el("div", {}, el("strong", { text: item.name }), el("p", { class: "muted", text: item.kind === "diy" ? t("DIY Effect") : t("Scene") }))),
      el("div", { class: "scene-panel-body" }, row(t("Name"), item.name), row(t("Scene Code"), item.code || ""), row(t("Govee Scene ID"), item.sceneId), row(t("Kind"), item.kind))));
  }

  /// Ticks the scenes the light's settings have.
  function refreshPicker() {
    const selected = new Set(live[browsing?.device.deviceId]?.scenes || []);
    for (const tile of document.querySelectorAll("#picker-body .tile-scene")) tile.classList.toggle("selected", selected.has(tile.dataset.key));
    const count = $("#picker-count");
    if (count) count.textContent = tn("{n} scene in HomeKit", "{n} scenes in HomeKit", selected.size);
  }

  // MARK: Scene icons, proxied by the plugin in batches as their tiles come into view

  const iconQueue = new Map();
  let iconTimer = null;

  async function flushIcons() {
    iconTimer = null;
    const pending = [...iconQueue];
    iconQueue.clear();
    for (let start = 0; start < pending.length; start += 60) {
      const batch = pending.slice(start, start + 60);
      try {
        const icons = (await request("scene-icons", { method: "POST", body: { urls: batch.map(([url]) => url) } }))?.icons || {};
        for (const [url, images] of batch) {
          if (icons[url]) iconCache.set(url, icons[url]);
          for (const image of images) { if (icons[url]) image.src = icons[url]; else image.classList.add("empty"); }
        }
      } catch {
        for (const [, images] of batch) images.forEach((image) => image.classList.add("empty"));
      }
    }
  }

  function queueIcon(image) {
    const url = image.dataset.iconUrl;
    if (!url) return;
    delete image.dataset.iconUrl;
    if (iconCache.has(url)) { image.src = iconCache.get(url); return; }
    if (iconQueue.has(url)) { iconQueue.get(url).push(image); return; }
    iconQueue.set(url, [image]);
    if (!iconTimer) iconTimer = setTimeout(flushIcons, 60);
  }

  function hydrateIcons(root) {
    const pending = root.querySelectorAll("img[data-icon-url]");
    if (!pending.length) return;
    if (typeof IntersectionObserver !== "function") { pending.forEach(queueIcon); return; }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { observer.unobserve(entry.target); queueIcon(entry.target); }
    }, { rootMargin: "200px" });
    pending.forEach((image) => observer.observe(image));
  }

  const hydrateObserver = new MutationObserver(() => hydrateIcons(library));
  hydrateObserver.observe(library, { childList: true, subtree: true });

  // MARK: Discovery

  /// Asks Govee for the account's devices now: what it answers, beside the devices the plugin found at its start.
  async function discover(button) {
    const result = $("#discover-result");
    result.replaceChildren();
    await act(button, async () => {
      try {
        const devices = (await request("discover", { method: "POST", body: {} })).devices || [];
        if (!devices.length) { result.replaceChildren(el("p", { class: "summary", text: t("No devices found.") })); return; }
        const fresh = devices.filter((device) => device.deviceId && !found.some((known) => known.deviceId === device.deviceId));
        result.replaceChildren(
          el("p", { class: "summary", text: fresh.length
            ? tn("{n} device is new since the plugin started: it is added when the plugin starts again.", "{n} devices are new since the plugin started: they are added when the plugin starts again.", fresh.length)
            : t("The plugin already has every device of the account.") }),
          el("ul", { class: "found" }, devices.map((device) => el("li", {},
            el("div", {}, el("strong", { text: device.deviceName || t("Unknown") }), " ",
              el("span", { class: "pill", text: typeNames[typeFor(device.model, device.deviceType)].badge }),
              el("div", { class: "muted note", text: t("Model: {model}", { model: device.model || t("Unknown") }) })),
            el("span", { class: "mono", text: device.deviceId || "" })))));
      } catch (e) {
        problem(result, t("Error: {error}", { error: e.message || t("Unknown error") }), "Discover Devices asked the Govee cloud for the account's device list with the plugin's login, and it failed.");
      }
    });
  }

  // MARK: Tools

  async function clearCache(button) {
    if (!await HomeswiftCommon.confirmDialog(t("Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards."))) return;
    const result = $("#clear-result");
    await act(button, async () => {
      try {
        const answer = await request("clear-cache", { method: "POST", body: {} });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: HomeswiftI18n.message(answer.message) }));
          $("#restart").classList.remove("hidden");
        } else {
          problem(result, HomeswiftI18n.message(answer.message) || t("Cache partially cleared"), "Clear Cache deletes the plugin's saved login, IoT certificate and device data; some could not be removed.", undefined, "error");
        }
      } catch (e) {
        problem(result, e.message || t("Failed to clear cache"), "Clear Cache (the plugin's saved login, IoT certificate and device data) failed.");
      }
    });
  }

  async function restart(button) {
    await act(button, async () => {
      await api("/api/restart", { method: "POST", body: {} });
      $("#clear-result").replaceChildren(el("p", { class: "status-line", text: t("Restarting…") }));
      for (let tries = 0; tries < 60; tries++) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        try { await request("devices"); break; } catch { /* not back yet */ }
      }
      location.reload();
    });
  }

  // MARK: Start

  for (const button of document.querySelectorAll(".main-tabs button")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs button")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
    });
  }
  $("#discover").addEventListener("click", (event) => discover(event.currentTarget));
  $("#sign-in").href = setupAddress({ start: true });
  $("#clear-cache").addEventListener("click", (event) => clearCache(event.currentTarget));
  $("#restart").addEventListener("click", (event) => restart(event.currentTarget));

  async function refreshLive() {
    try {
      const answer = await request("devices");
      // Only what the rows show: lastUpdate changes with every report, and a redraw every five seconds would
      // take the focus off a row's button and flicker the lists.
      const next = {};
      for (const device of answer.devices || []) next[device.deviceId] = { name: device.name, model: device.model, list: device.list, lan: device.lan, aws: device.aws, ble: device.ble, scenes: device.scenes };
      const changed = JSON.stringify(next) !== JSON.stringify(live) || answer.signedIn !== signedIn;
      live = next;
      signedIn = answer.signedIn !== false;
      if (changed) { renderTypes(); refreshPicker(); }
    } catch { /* the plugin may be restarting */ }
  }

  (async () => {
    try { found = (await request("cached-devices")).devices || []; } catch { /* the plugin may be restarting */ }
    for (const device of found) openTypes.add(typeFor(device.model, device.deviceType));
    renderTypes();
    poll(refreshLive, 5000);
  })();
})();
