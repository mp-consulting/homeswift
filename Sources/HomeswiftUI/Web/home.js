// Rooms and hidden accessories, the Quick Controls, scenes and their automations, and notifications: the views
// ported from Glass UI. app.js hands its helpers over with install() before the first view is drawn.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, fact } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  let app = null;

  // Stable Sunday-based ids for storage, localized labels and display order for people.
  const weekdayFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", timeZone: "UTC" });
  const weekdayFullFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "long", timeZone: "UTC" });
  const weekdays = Array.from({ length: 7 }, (_, day) => weekdayFormat.format(new Date(Date.UTC(2024, 0, 7 + day))));
  const weekdayNames = Array.from({ length: 7 }, (_, day) => weekdayFullFormat.format(new Date(Date.UTC(2024, 0, 7 + day))));
  const weekLocale = new Intl.Locale(HomeswiftI18n.locale);
  const firstWeekday = (weekLocale.getWeekInfo?.() ?? weekLocale.weekInfo)?.firstDay ?? 1;
  const weekdayOrder = Array.from({ length: 7 }, (_, offset) => (firstWeekday + offset) % 7);
  const operators = [["eq", t("is")], ["neq", t("is not")], ["gt", t("is above")], ["gte", t("is at least")], ["lt", t("is below")], ["lte", t("is at most")]];
  const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
  const displayName = (accessory) => accessory.displayName || accessory.name;
  const statusLine = () => el("p", { class: "status-line muted", role: "status" });
  const say = (line, text, kind = "muted") => { line.className = `status-line ${kind}`; line.textContent = text; };

  // ---- Rooms, hidden accessories, display names ------------------------------------------------------

  async function changeLayout(body) {
    return app.api("/api/rooms", { method: "PUT", body });
  }

  /// What an accessory card's menu adds: its room, a name for these pages, Quick Controls, hiding.
  function layoutActions(accessory) {
    const change = (fields) => changeLayout({ accessories: { [accessory.id]: fields } }).then(() => app.route()).catch((e) => HomeswiftCommon.showAlert(e.message));
    return [
      { label: accessory.room ? t("Room: {room}…", { room: accessory.room }) : t("Put in a room…"), icon: "room", onSelect: () => chooseRoom(accessory, change) },
      { label: t("Name on these pages…"), icon: "edit", onSelect: async () => {
        const name = await HomeswiftCommon.promptDialog(t("A name for {name} on these pages (the Home app keeps its own). Empty goes back to {name}.", { name: accessory.name }), accessory.displayName || "");
        if (name !== null) change({ name: name.trim() || null });
      } },
      { label: accessory.favourite ? t("Remove from Quick Controls") : t("Add to Quick Controls"), icon: "star", onSelect: () => change({ favourite: !accessory.favourite }) },
      { label: accessory.hidden ? t("Show it again") : t("Hide"), icon: "eye", onSelect: () => change({ hidden: !accessory.hidden }) },
    ];
  }

  async function chooseRoom(accessory, change, note = "") {
    let rooms = [];
    try { rooms = (await app.api("/api/rooms")).rooms.map((room) => room.name); } catch {}
    const room = await HomeswiftCommon.promptDialog((rooms.length
      ? t("The room of {name}. Rooms: {rooms}. A new name adds the room; empty takes it out of its room.", { name: displayName(accessory), rooms: rooms.join(", ") })
      : t("The room of {name}. A new name adds the room; empty takes it out of its room.", { name: displayName(accessory) })) + (note ? `\n\n${note}` : ""), accessory.room || "");
    if (room !== null) await change({ room: room.trim() || null });
  }

  async function moveGroupToRoom(group, accessories) {
    const members = group.members.map((id) => accessories.find((a) => a.id === id));
    const room = members.every((a) => a && a.room === members[0]?.room) ? members[0]?.room : "";
    await chooseRoom({ name: group.name, room }, async (fields) => {
      // One metadata-only update for every member; no device or HomeKit writes.
      await changeLayout({ accessories: Object.fromEntries(group.members.map((id) => [id, fields])) });
      await app.route();
    }, t("Moves every member of this group in Homeswift only. HomeKit rooms stay unchanged."));
  }

  /// The Accessories page's accessories by room, in the layout's order; those in no room last.
  function groupByRoom(accessories, rooms) {
    const byName = (a, b) => displayName(a).localeCompare(displayName(b));
    const groups = rooms.map((room) => [room, accessories.filter((a) => a.room === room).sort(byName)]).filter(([, list]) => list.length);
    const rest = accessories.filter((a) => !a.room || !rooms.includes(a.room)).sort(byName);
    return rest.length ? [...groups, [groups.length ? t("No room") : t("Accessories"), rest]] : groups;
  }

  /// The Assistant's rooms and names, to review: each suggestion can be kept or left; Apply saves what is kept.
  /// Names go to these pages only; HomeKit and the Home app keep theirs.
  async function suggestRooms(host, accessories) {
    host.querySelector(".suggest")?.remove();
    const panel = el("div", { class: "card panel suggest" },
      el("div", { class: "panel-head" }, el("div", {}, el("h2", {}, sparkle(), " ", t("Suggested rooms")), el("p", { class: "muted", text: t("The Assistant is sorting your accessories into rooms…") }))));
    host.prepend(panel);
    panel.classList.add("ai-busy");
    let result;
    try {
      result = await app.api("/api/rooms/suggest", { method: "POST", body: {} });
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }), el("div", { class: "actions" }, el("button", { actionIcon: "close", text: t("Close"), onclick: () => panel.remove() })));
      return;
    } finally { panel.classList.remove("ai-busy"); }
    const byID = new Map(accessories.map((a) => [a.id, a]));
    const checks = [];
    const check = (data, label, detail) => {
      const input = el("input", { type: "checkbox", checked: true });
      checks.push({ input, data });
      return el("label", { class: "toggle compact" }, input, el("span", {}, el("span", { text: label }), detail ? el("span", { class: "help", text: detail }) : null));
    };
    const rooms = result.rooms.filter((room) => room.accessories.length).map((room) => el("div", { class: "suggest-room" },
      el("div", { class: "service-name", text: room.name }),
      room.accessories.map((id) => {
        const accessory = byID.get(id);
        const moved = accessory?.room && accessory.room !== room.name ? t("now in {room}", { room: accessory.room }) : accessory?.room === room.name ? t("already there") : null;
        return check({ id, room: room.name }, accessory ? displayName(accessory) : id, moved);
      })));
    const renames = result.renames.map((rename) => check({ id: rename.id, name: rename.name }, `${rename.current} → ${rename.name}`, rename.reason));
    const orphans = result.orphans.map((orphan) => el("li", {}, el("strong", { text: orphan.name }), ` ${orphan.reason}`));
    const line = statusLine();
    const apply = el("button", { actionIcon: "check", class: "primary", text: t("Apply what is ticked"), onclick: async () => {
      const changes = {};
      for (const { input, data } of checks) {
        if (!input.checked) continue;
        changes[data.id] = { ...changes[data.id], ...(data.room ? { room: data.room } : { name: data.name }) };
      }
      apply.disabled = true;
      try { await changeLayout({ accessories: changes }); app.route(); } catch (e) { say(line, e.message, "error"); apply.disabled = false; }
    } });
    panel.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", {}, sparkle(), " ", t("Suggested rooms")),
          el("p", { class: "muted", text: t("From {model}. Untick what you do not want; nothing changes until you apply. Names show on these pages only: the Home app keeps its own.", { model: result.model }) })),
        el("button", { actionIcon: "close", class: "link", text: t("Dismiss"), onclick: () => panel.remove() })),
      rooms.length ? el("div", { class: "suggest-rooms" }, rooms) : el("p", { class: "muted", text: t("No room to suggest.") }),
      renames.length ? el("div", {}, el("div", { class: "service-name", text: t("Clearer names") }), renames) : null,
      orphans.length ? el("div", {}, el("div", { class: "service-name", text: t("Worth a look") }), el("ul", { class: "help" }, orphans)) : null,
      el("div", { class: "actions" }, apply), line);
  }

  // ---- Quick Controls --------------------------------------------------------------------------------

  /// The favourite accessories by room, and the scenes to run: a section of the Status page, and the whole of
  /// /quick (a page for a phone's home screen). Draws once its data is there.
  function quickSection(accessories, { standalone = false } = {}) {
    const section = el("section", { class: "quick" });
    (async () => {
      const [list, scenes] = await Promise.all([
        accessories ? Promise.resolve(accessories) : app.api("/api/accessories").then((all) => app.withSlugs(all, "accessory")),
        app.api("/api/scenes").then((answer) => answer.scenes).catch(() => []),
      ]);
      const favourites = list.filter((a) => a.favourite && !a.hidden);
      if (!favourites.length && !scenes.length) {
        if (standalone) section.append(el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("star")), el("p", { class: "muted", text: t("Nothing here yet. On the Accessories page, a card's menu adds it to the Quick Controls; scenes you make show here too.") })));
        return;
      }
      section.classList.add("card");
      const rooms = [...new Set(favourites.map((a) => a.room).filter(Boolean))];
      // `append` is the DOM's: it writes null and arrays as text, so the parts go in flat and without the empty ones.
      section.append(...[
        standalone ? null : el("div", { class: "section-head" }, el("h2", { text: t("Quick controls") }), el("a", { href: "/quick", class: "muted", text: t("Open on its own") })),
        scenes.length ? el("div", { class: "quick-scenes" }, scenes.map((scene) => sceneButton(scene))) : null,
        groupByRoom(favourites, rooms).map(([room, members]) => [
          rooms.length ? el("div", { class: "service-name", text: room }) : null,
          // The accessories' widgets, as the Accessories page draws them.
          el("div", { class: "wall" }, members.map((accessory) => app.accessoryCard(accessory))),
        ]),
      ].flat(2).filter(Boolean));
    })().catch((e) => section.append(el("p", { class: "error", text: e.message })));
    return section;
  }

  // Artwork ids come from the server catalogue; never accept an arbitrary image URL.
  function artworkImage(id, className = "scene-artwork") {
    return typeof id === "string" && /^[a-z0-9-]+$/.test(id)
      ? el("img", { class: className, src: `/artwork-${id}.webp`, alt: "", loading: "lazy", decoding: "async" }) : null;
  }

  /// A scene's picture: the one a person gave it (by version, so the browser keeps it until it changes), else its
  /// catalogue artwork.
  function sceneImage(scene, className = "scene-artwork") {
    if (typeof scene.picture === "string" && /^[a-z0-9]+$/.test(scene.picture)) {
      return el("img", { class: className, src: `/api/scenes/${encodeURIComponent(scene.id)}/picture?v=${scene.picture}`, alt: "", loading: "lazy", decoding: "async" });
    }
    return artworkImage(scene.artworkId, className);
  }

  /// The menu entries that give a scene, Homeswift's or a hub's, a picture of the person's own or take it away.
  /// `tileNode` shows busy while the picture is shrunk and sent.
  function pictureMenu(scene, tileNode) {
    const path = `/api/scenes/${encodeURIComponent(scene.id)}/picture`;
    return [
      { label: scene.picture ? t("Change the picture…") : t("Choose a picture…"), icon: "camera", onSelect: () => HomeswiftCommon.choosePictureFile(async (file) => {
        tileNode?.classList.add("busy");
        try {
          await app.api(path, { method: "PUT", body: { data: await HomeswiftCommon.pictureDataURL(file) } });
          app.route();
        } catch (e) { HomeswiftCommon.showAlert(e.message); tileNode?.classList.remove("busy"); }
      }) },
      scene.picture ? { label: t("Remove the picture"), icon: "trash", onSelect: async () => {
        try { await app.api(path, { method: "DELETE" }); app.route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
      } } : null,
    ].filter(Boolean);
  }

  const artworkThemeNames = {
    "Essentials": t("Essentials"),
    "Get cozy": t("Get cozy"),
    "Movie night": t("Movie night"),
    "Reading": t("Reading"),
    "Wanderlust": t("Wanderlust"),
    "Vibrant": t("Vibrant"),
    "Party vibes": t("Party vibes"),
    "Daily": t("Daily"),
    "Dreamy": t("Dreamy"),
    "Cozy": t("Cozy"),
    "Peaceful": t("Peaceful"),
    "Serenity": t("Serenity"),
    "Lush": t("Lush"),
    "Pure": t("Pure"),
    "Refreshing": t("Refreshing"),
    "Luxurious": t("Luxurious"),
    "Romantic": t("Romantic"),
    "Sunrise": t("Sunrise"),
    "Futuristic": t("Futuristic"),
    "Race day": t("Race day"),
    "Spring breeze": t("Spring breeze"),
    "Summer glow": t("Summer glow"),
    "Harvest hues": t("Harvest hues"),
    "Winter whisper": t("Winter whisper"),
    "Winter holidays": t("Winter holidays"),
    "Christmas": t("Christmas"),
    "Halloween": t("Halloween"),
    "More themes": t("More themes"),
  };
  let artworkThemesRequest;
  const loadArtworkThemes = () => artworkThemesRequest ||= app.api("/scene-artwork-themes.json").catch((error) => { artworkThemesRequest = null; throw error; });

  // A scene can belong to several themes; each row keeps the catalogue's order.
  function themedArtwork(items, themes, makeButton) {
    const byId = new Map(items.map((item) => [item.artworkId || item.id, item]));
    const search = el("input", { type: "search", placeholder: t("Search images…"), "aria-label": t("Search images…") });
    const select = el("select", { "aria-label": t("Theme") }, el("option", { value: "", text: t("All themes") }),
      [...themes].sort((a, b) => (artworkThemeNames[a.name] || a.name).localeCompare(artworkThemeNames[b.name] || b.name, HomeswiftI18n.locale)).map((theme) => el("option", { value: theme.name, text: artworkThemeNames[theme.name] || theme.name })));
    const sort = el("select", { "aria-label": t("Sort images") },
      el("option", { value: "gallery", text: t("Gallery order") }), el("option", { value: "asc", text: t("Name: A–Z") }), el("option", { value: "desc", text: t("Name: Z–A") }));
    const empty = el("p", { class: "muted", text: t("No images match your search."), hidden: true });
    const groups = themes.map((theme) => {
      const buttons = theme.artworkIds.filter((id) => byId.has(id)).map((id) => {
        const item = byId.get(id), button = makeButton(item);
        return { item, button };
      });
      const node = el("section", { class: "artwork-theme" }, el("h3", { class: "service-name", text: artworkThemeNames[theme.name] || theme.name }),
        el("div", { class: "artwork-theme-row" }, buttons.map(({ button }) => button)));
      return { theme, node, buttons };
    });
    const filter = () => {
      const query = search.value.trim().toLocaleLowerCase();
      for (const group of groups) {
        const matchesTheme = (artworkThemeNames[group.theme.name] || group.theme.name).toLocaleLowerCase().includes(query);
        for (const { item, button } of group.buttons) button.hidden = !(matchesTheme || item.name.toLocaleLowerCase().includes(query));
        group.node.hidden = (select.value && group.theme.name !== select.value) || !group.buttons.some(({ button }) => !button.hidden);
      }
      empty.hidden = groups.some(({ node }) => !node.hidden);
    };
    sort.addEventListener("change", () => {
      for (const group of groups) {
        const ordered = [...group.buttons];
        if (sort.value !== "gallery") ordered.sort((a, b) => a.item.name.localeCompare(b.item.name, HomeswiftI18n.locale) * (sort.value === "desc" ? -1 : 1));
        group.node.querySelector(".artwork-theme-row").replaceChildren(...ordered.map(({ button }) => button));
      }
    });
    search.addEventListener("input", filter); select.addEventListener("change", filter);
    return el("div", { class: "artwork-themes" }, el("div", { class: "artwork-filters" }, search, select, sort), empty, groups.map(({ node }) => node));
  }

  /// The animation styles, by id, in the order the editor lists them.
  const effectStyleNames = {
    candle: t("Candle"), fire: t("Fire"), sparkle: t("Sparkle"), prism: t("Prism"), opal: t("Opal"), glisten: t("Glisten"),
    underwater: t("Underwater"), cosmos: t("Cosmos"), sunbeam: t("Sunbeam"), enchant: t("Enchant"), palette: t("Moving colours"),
    sunrise: t("Sunrise"), sunset: t("Sunset"), music: t("Follow the music"),
  };

  function sceneButton(scene) {
    const picture = sceneImage(scene, "quick-scene-image");
    const button = el("button", { type: "button", class: `scene-run${picture ? " pictured" : ""}`, title: t("Run {name}", { name: scene.name }) }, picture, el("span", { class: "quick-scene-label" }, HomeswiftCommon.icon("play"), el("span", { text: scene.name })));
    button.addEventListener("click", () => runScene(scene, button));
    return button;
  }

  /// A scene a plugin's hub keeps (Hue, IKEA, Govee): its picture or its colours, its source, whether the hub says it
  /// is on now. Running it recalls it on the hub.
  function hubSceneButton(scene) {
    const picture = sceneImage(scene, "quick-scene-image");
    const colours = (scene.colours || []).filter((colour) => /^#[0-9a-f]{3,8}$/i.test(colour));
    // A scene its hub runs on its own (an IKEA wake-up) is shown, not run.
    const runnable = (scene.capabilities || []).includes("recall");
    const button = el("button", { type: "button", disabled: !runnable, class: `scene-run hub-scene${picture ? " pictured" : colours.length ? " coloured" : ""}${scene.active ? " active" : ""}`, title: runnable ? t("Run {name}", { name: scene.name }) : scene.name },
      picture,
      el("span", { class: "quick-scene-label" }, HomeswiftCommon.icon("play"),
        el("span", {}, el("span", { text: scene.name }), el("span", { class: "scene-source", text: scene.source.pluginName }))),
      scene.active ? el("span", { class: "pill scene-active", text: t("Scene active") }) : null);
    if (!picture && colours.length) button.style.background = colours.length > 1 ? `linear-gradient(135deg, ${colours.join(", ")})` : colours[0];
    button.addEventListener("click", async () => { if (await runScene(scene, button)) app.route(); });
    // Its actions sit on the tile, round over its top corner: Stop while it can be, then the menu (Automate and the rest).
    const stop = scene.stoppable ? el("button", { type: "button", actionIcon: "stop", "aria-label": t("Stop"), title: t("Stop"), onclick: () => stopScene(scene, stop) }) : null;
    // A Homeswift scene that recalls it, to give it triggers and conditions.
    const automate = async () => {
      try {
        const saved = await app.api("/api/scenes", { method: "POST", body: { name: scene.name.slice(0, 64), artworkId: scene.artworkId || null, actions: [{ recall: scene.id }] } });
        app.navigate(`/scenes/${encodeURIComponent(saved.id)}`);
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    // Everything in it changes scenes or pictures: an administrator's.
    const menu = !app.isAdmin() ? null : menuButton(t("Actions for {name}", { name: scene.name }), () => [
      runnable ? { label: t("Automate"), icon: "workflow", onSelect: automate } : null,
      ...hubSceneMenu(scene), ...pictureMenu(scene, button),
    ].filter(Boolean));
    return el("div", { class: "hub-scene-tile" }, button, el("div", { class: "hub-scene-actions" }, stop, menu));
  }

  /// What a hub's scene lets Homeswift change on its hub (its `capabilities`): its name, its lights' values as they are
  /// now, or the scene itself, which goes from the hub's own app too.
  function hubSceneMenu(scene) {
    const can = new Set(scene.capabilities || []);
    const path = `/api/scenes/${encodeURIComponent(scene.id)}`;
    const change = async (body) => {
      try { await app.api(`${path}/hub`, { method: "PUT", body }); app.route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    return [
      can.has("rename") ? { label: t("Rename…"), icon: "edit", onSelect: async () => {
        const name = (await HomeswiftCommon.promptDialog(t("A new name for {name} on {hub}.", { name: scene.name, hub: scene.source.name }), scene.name))?.trim();
        if (name && name !== scene.name) await change({ name });
      } } : null,
      can.has("update") && scene.accessoryIds?.length ? { label: t("Keep the lights as they are"), icon: "check", onSelect: async () => {
        if (await HomeswiftAdmin.confirmAction({ title: t("Update {name}?", { name: scene.name }), text: t("{name} on {hub} will set its lights as they are now.", { name: scene.name, hub: scene.source.name }), confirmLabel: t("Update"), danger: false })) await change({ fromCurrent: true });
      } } : null,
      can.has("delete") ? { label: t("Delete from {hub}", { hub: scene.source.name }), icon: "trash", danger: true, onSelect: async () => {
        if (!(await HomeswiftAdmin.confirmAction({ title: t("Delete the scene {name}?", { name: scene.name }), text: t("This removes it from {hub} and its own app too. This cannot be undone.", { hub: scene.source.name }), confirmLabel: t("Delete"), confirmIcon: "trash" }))) return;
        try { await app.api(path, { method: "DELETE" }); app.route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
      } } : null,
    ].filter(Boolean);
  }

  /// The scenes of the plugins' hubs, by room, with a source filter when there are several. `filter(query)` hides
  /// those whose name does not match; answers how many show.
  function hubScenesSection(scenes) {
    if (!scenes.length) return { node: null, filter: () => 0 };
    const other = t("Other");
    const rooms = [...new Set(scenes.map((scene) => scene.room || other))].sort((a, b) => a === other ? 1 : b === other ? -1 : a.localeCompare(b, HomeswiftI18n.locale));
    const sourceKey = (scene) => `${scene.source.platform}:${scene.source.name}`;
    const sources = [...new Map(scenes.map((scene) => [sourceKey(scene), scene.source.name])).entries()];
    const source = sources.length > 1 ? el("select", { "aria-label": t("Source") }, el("option", { value: "", text: t("All sources") }),
      sources.map(([key, name]) => el("option", { value: key, text: name }))) : null;
    const tiles = scenes.map((scene) => ({ scene, node: hubSceneButton(scene) }));
    const groups = rooms.map((room) => {
      const members = tiles.filter(({ scene }) => (scene.room || other) === room);
      return { members, node: el("div", { class: "hub-scene-room" }, el("div", { class: "service-name", text: room }), el("div", { class: "quick-scenes" }, members.map(({ node }) => node))) };
    });
    const count = el("span", { class: "pill", text: String(scenes.length) });
    let query = "";
    const filter = (text = query) => {
      query = text;
      let shown = 0;
      for (const { scene, node } of tiles) {
        node.hidden = !scene.name.toLocaleLowerCase().includes(query) || (source?.value && sourceKey(scene) !== source.value);
        if (!node.hidden) shown += 1;
      }
      for (const group of groups) group.node.hidden = group.members.every(({ node }) => node.hidden);
      count.textContent = String(shown);
      return shown;
    };
    source?.addEventListener("change", () => filter());
    const node = el("section", { class: "hub-scenes" },
      el("div", { class: "section-head hub-scenes-head" }, el("h2", { text: t("Scenes from your hubs") }), count, source),
      el("p", { class: "muted", text: t("Kept by the hubs of your plugins, such as a Hue Bridge, an IKEA hub or Govee lights. Run them here; rename, update or delete a Hue or IKEA scene from its ⋯ menu.") }),
      groups.map(({ node }) => node));
    return { node, filter };
  }

  /// Runs a scene; one that changes a lock, a door or an alarm asks first, as the cards' own controls do.
  /// Puts back what a scene's last run changed (a saved scene's locks, doors and alarms once the person agrees), then
  /// redraws the page.
  async function stopScene(scene, button) {
    const confirmSecurity = Boolean(scene.security || scene.stopSecurity);
    if (confirmSecurity && !await HomeswiftCommon.confirmDialog(t("Restore the previous state of this scene’s locks, doors or alarms?"))) return;
    button.disabled = true;
    try {
      const result = await app.api(`/api/scenes/${encodeURIComponent(scene.id)}/stop`, { method: "POST", body: { confirmSecurity } });
      if (!result.ok) HomeswiftCommon.showAlert(result.failed.map((f) => HomeswiftI18n.message(f.error)).join("\n"));
      app.route();
    } catch (e) { HomeswiftCommon.showAlert(e.message); button.disabled = false; }
  }

  async function runScene(scene, button) {
    let confirmSecurity = false;
    if (scene.security) {
      const which = scene.actions.filter((a) => a.security).map((a) => `${a.name || a.id}: ${a.characteristic}`).join(", ");
      if (!await HomeswiftCommon.confirmDialog(t("{scene} changes a lock, a door or an alarm ({which}). Run it?", { scene: scene.name, which }))) return;
      confirmSecurity = true;
    }
    button?.classList.add("busy");
    if (button) button.disabled = true;
    try {
      const result = await app.api(`/api/scenes/${encodeURIComponent(scene.id)}/run`, { method: "POST", body: { confirmSecurity } });
      if (!result.ok && result.results) {
        const failures = result.results.filter((r) => !r.ok).map((r) => `${r.name || r.id} ${r.characteristic}: ${HomeswiftI18n.message(r.error || r.skipped)}`);
        HomeswiftCommon.showAlert(t("{scene} ran, but not everything worked:\n{failures}", { scene: scene.name, failures: failures.join("\n") }));
      }
      return result;
    } catch (e) { HomeswiftCommon.showAlert(e.message); } finally {
      button?.classList.remove("busy");
      if (button) button.disabled = false;
    }
  }

  // ---- Templates -------------------------------------------------------------------------------------

  /// The collection's names and descriptions, by id: translated here, the server's being English for MCP clients.
  const templateTexts = {
    "candlelight": [t("Candlelight"), t("Very warm, dim light for dinner.")],
    "relax": [t("Relax"), t("Soft warm white for the evening.")],
    "golden-hour": [t("Golden hour"), t("Amber and soft orange, a little different on each light.")],
    "cinema": [t("Cinema"), t("Almost dark, with a touch of blue behind the screen.")],
    "romantic": [t("Romantic"), t("Deep pink and soft red, dimmed.")],
    "focus": [t("Focus"), t("Bright, cool white for work.")],
    "night-light": [t("Night light"), t("A faint amber glow to find your way.")],
    "candle-flicker": [t("Candle flicker"), t("Warm amber, each light flickering on its own.")],
    "fireplace": [t("Fireplace"), t("Reds, oranges and amber dancing unevenly.")],
    "ocean": [t("Ocean"), t("Blues and teals rolling from light to light like waves.")],
    "northern-lights": [t("Northern lights"), t("Green, teal and violet drifting slowly.")],
    "breathing": [t("Breathing"), t("Soft light rising and falling in a six-second rhythm, to calm down.")],
    "sunset": [t("Sunset"), t("Ten minutes from golden yellow through orange and pink to a dim red.")],
    "sunrise": [t("Sunrise"), t("Fifteen minutes from a dim red glow to bright warm white, to wake up.")],
    "disco": [t("Disco"), t("Every light jumps to a vivid colour on each beat.")],
    "police": [t("Police siren"), t("Red and blue swapping from light to light.")],
    "rainbow-wave": [t("Rainbow wave"), t("The colour wheel passing from light to light.")],
    "lightning": [t("Lightning storm"), t("Dim stormy blue, with sudden white flashes.")],
    "halloween": [t("Halloween"), t("Purple and orange with an eerie flicker.")],
    "christmas": [t("Christmas"), t("Red and green taking turns, with a warm white twinkle now and then.")],
    "alert": [t("Alert flash"), t("Two red pulses, then the lights go back to how they were.")],
    "bedtime": [t("Bedtime"), t("A slow fade to a dim red over fifteen minutes.")],
  };
  const templateCategories = [["gallery", t("Scene gallery")], ["calm", t("Calm")], ["animated", t("Slow animations")], ["party", t("Party")], ["signal", t("Signals")]];
  const templateName = (id, name) => templateTexts[id]?.[0] ?? name;
  const templateRoomKey = "homeswift.templates.room";

  /// The rooms with a light in them, for the templates.
  function lightRooms(accessories) {
    const rooms = accessories.filter((a) => !a.hidden && a.room && a.services.some((s) => s.type === "Lightbulb")).map((a) => a.room);
    return [...new Set(rooms)].sort((a, b) => a.localeCompare(b, HomeswiftI18n.locale));
  }

  /// Templates for a room's lights: the rooms as chips, what was tried there and can still be stopped or undone, a box
  /// where the Assistant writes a scene from a description, and the collection by kind. A tap tries one at once without
  /// saving it (the pill lights up while it plays); Save keeps it as a scene. On a phone each kind is a row that swipes
  /// sideways, so the whole card fits on a screen.
  function templatesSection(accessories, scenes = { scenes: [], pluginScenes: [] }) {
    const section = el("section", { class: "templates" });
    const head = el("div", { class: "section-head" }, el("div", {}, el("h2", { text: t("By room") }), el("span", { class: "muted", text: t("A room's scenes, then templates to try on its lights; save one as a scene when you like it.") })));
    const rooms = lightRooms(accessories);
    if (!rooms.length) {
      section.append(head, el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Put your lights in rooms (a card's menu on the Accessories page) to try templates on them.") })));
      return section;
    }
    let room = rooms[0];
    try { const remembered = localStorage.getItem(templateRoomKey); if (rooms.includes(remembered)) room = remembered; } catch {}
    const roomChips = el("div", { class: "template-rooms", role: "group", "aria-label": t("Room") }, rooms.map((name) => {
      const chip = el("button", { type: "button", class: "template-room", text: name, "aria-pressed": String(name === room) });
      chip.addEventListener("click", () => {
        room = name;
        try { localStorage.setItem(templateRoomKey, name); } catch {}
        for (const other of roomChips.children) other.setAttribute("aria-pressed", String(other === chip));
        drawStrip();
        drawTries();
        markPlaying();
      });
      return chip;
    }));
    const line = statusLine();
    const running = el("div", { class: "template-running" });
    const collection = el("div", { class: "template-collection" });
    const describe = el("input", { type: "text", maxLength: 500, enterKeyHint: "go", placeholder: t("Describe a scene…"), title: t("Describe one: a jazz bar, a rainy afternoon…"), "aria-label": t("Describe a scene") });
    const create = el("button", { type: "submit", class: "primary template-create" }, sparkle(), el("span", { text: t("Create") }));
    const designer = el("form", { class: "template-describe hidden" }, describe, create);
    // The chosen room's own scenes and its hubs' scenes, to run in a tap.
    const strip = el("div", { class: "quick-scenes room-scenes" });
    const stripHead = el("div", { class: "service-name" });
    const templatesHead = el("div", { class: "service-name", text: t("From a template") });
    function drawStrip() {
      const own = scenes.scenes.filter((scene) => scene.room === room).map((scene) => sceneButton(scene));
      const hubs = (scenes.pluginScenes || []).filter((scene) => scene.room === room).map((scene) => hubSceneButton(scene));
      strip.replaceChildren(...own, ...hubs);
      stripHead.textContent = t("Scenes in {room}", { room });
      strip.hidden = stripHead.hidden = !own.length && !hubs.length;
    }
    drawStrip();
    section.append(head, el("div", { class: "card template-card" }, roomChips, stripHead, strip, running, line, designer, templatesHead, collection));

    let data = { templates: [], tries: [] };
    const buttons = [];
    const name = (run) => run.template ? templateName(run.template, run.name) : run.name;

    /// The pills of the templates playing in the chosen room light up.
    function markPlaying() {
      const playing = new Set(data.tries.filter((run) => run.room === room && run.template).map((run) => run.template));
      for (const [id, button] of buttons) {
        button.classList.toggle("playing", playing.has(id));
        button.setAttribute("aria-pressed", String(playing.has(id)));
        let badge = button.querySelector(".template-stop-badge");
        if (playing.has(id) && !badge) { badge = el("span", { class: "template-stop-badge", "aria-hidden": "true" }); button.append(badge); }
        if (!playing.has(id)) badge?.remove();
        const label = button.querySelector(".name")?.textContent || templateName(id, id);
        button.setAttribute("aria-label", playing.has(id) ? `${t("Stop")} ${label}` : label);
      }
    }

    async function refresh() {
      data = await app.api("/api/scenes/templates");
      drawTries();
      markPlaying();
    }

    async function stopTry(run) {
      await app.api(`/api/scenes/${encodeURIComponent(run.run)}/stop`, { method: "POST", body: {} });
      say(line, run.playing ? t("{scene} stopped: the lights are back as they were.", { scene: name(run) }) : t("{scene} undone: the lights are back as they were.", { scene: name(run) }));
    }

    function drawTries() {
      running.replaceChildren(...data.tries.map((run) => {
        // One that plays is stopped; one that set the lights once is undone. Either way the lights go back.
        const stop = el("button", { type: "button", class: "template-stop", actionIcon: "stop", text: run.playing ? t("Stop") : t("Undo") });
        stop.addEventListener("click", async () => {
          stop.classList.add("busy");
          stop.disabled = true;
          try { await stopTry(run); await refresh(); } catch (e) { say(line, e.message, "error"); stop.disabled = false; stop.classList.remove("busy"); }
        });
        const save = el("button", { type: "button", class: "link", actionIcon: "check", text: t("Save as a scene"), onclick: () => saveAsScene(run) });
        // The room shows only when it is not the one chosen above.
        const time = timeFormat.format(new Date(run.startedAt));
        const where = run.room && run.room !== room ? t("{room}, {time}", { room: run.room, time }) : time;
        return el("div", { class: "template-run" }, swatch(run.template, run.plan?.artworkId),
          el("div", { class: "template-run-text" }, el("strong", { text: name(run) }), el("span", { class: "muted", text: where })),
          save, stop);
      }));
    }

    function swatch(id, artworkId) {
      return artworkImage(artworkId || data.templates.find((template) => template.id === id)?.artworkId || "tyrell", "template-swatch");
    }

    async function start(body, label, button) {
      if (button?.classList.contains("busy")) return;
      button?.classList.add("busy");
      say(line, body.description ? t("The Assistant is writing a scene…") : t("Trying {template}…", { template: label }));
      try {
        const result = await app.api("/api/scenes/try", { method: "POST", body: { ...body, room } });
        if (result.ok) say(line, "");
        else {
          const failures = (result.results || []).filter((r) => !r.ok).map((r) => `${r.name || r.id || r.recall}: ${HomeswiftI18n.message(r.error || r.skipped)}`).join("; ");
          say(line, t("{scene} is set, but not on every light: {failures}", { scene: body.template ? label : result.name, failures }), "error");
        }
        if (body.description) describe.value = "";
        await refresh();
      } catch (e) { say(line, e.message, "error"); } finally { button?.classList.remove("busy"); }
    }

    async function saveAsScene(run) {
      try {
        const scene = await app.api("/api/scenes", { method: "POST", body: { ...run.plan, name: t("{scene} in {room}", { scene: name(run), room: run.room || room }).slice(0, 64) } });
        say(line, t("Saved as the scene {name}.", { name: scene.name }));
        setTimeout(() => { if (section.isConnected) app.route(); }, 1200);
      } catch (e) { say(line, e.message, "error"); }
    }

    designer.addEventListener("submit", (event) => {
      event.preventDefault();
      const text = describe.value.trim();
      if (text) start({ description: text }, text, create);
    });

    (async () => {
      await refresh();
      const themes = await loadArtworkThemes();
      designer.classList.toggle("hidden", !data.assistant);
      collection.replaceChildren(...templateCategories.map(([category, label]) => {
        const templates = data.templates.filter((template) => template.category === category);
        if (!templates.length) return null;
        const makeButton = (template) => {
          const label = templateName(template.id, template.name);
          const button = el("button", { type: "button", class: "template-button scene pictured artwork-choice", title: category === "gallery" ? label : templateTexts[template.id]?.[1] ?? template.description ?? "", "aria-pressed": "false" },
            swatch(template.id), el("span", { class: "name", text: label }));
          button.addEventListener("click", async () => {
            if (button.classList.contains("busy")) return;
            const active = data.tries.filter((run) => run.room === room && run.template === template.id);
            if (!active.length) return start({ template: template.id }, label, button);
            button.classList.add("busy");
            try {
              for (const run of active) await stopTry(run);
              await refresh();
            } catch (e) { say(line, e.message, "error"); }
            finally { button.classList.remove("busy"); }
          });
          buttons.push([template.id, button]);
          return button;
        };
        return el("div", { class: "template-group" }, el("div", { class: "service-name", text: label }),
          category === "gallery" ? themedArtwork(templates, themes, makeButton) : el("div", { class: "template-buttons" }, templates.map(makeButton)));
      }).filter(Boolean));
      markPlaying();
    })().catch((e) => say(line, e.message, "error"));
    return section;
  }

  // ---- Scenes ----------------------------------------------------------------------------------------

  const timeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit" });
  const dateTimeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" });

  function describeDays(days) {
    if (!days || !days.length || days.length === 7) return t("every day");
    const key = [...days].sort().join();
    if (key === "1,2,3,4,5") return t("on weekdays");
    if (key === "0,6") return t("at weekends");
    return t("on {days}", { days: days.map((d) => weekdays[d]).join(", ") });
  }
  /// "Sunset every day", "10 min before sunrise on weekdays".
  function describeSun(event, minutes, days) {
    const sunrise = event === "sunrise";
    const vars = { minutes: Math.abs(minutes || 0), days };
    if (!minutes) return sunrise ? t("Sunrise {days}", vars) : t("Sunset {days}", vars);
    if (minutes < 0) return sunrise ? t("{minutes} min before sunrise {days}", vars) : t("{minutes} min before sunset {days}", vars);
    return sunrise ? t("{minutes} min after sunrise {days}", vars) : t("{minutes} min after sunset {days}", vars);
  }
  function describeTrigger(trigger, names) {
    const text = (() => {
      switch (trigger.type) {
        case "time": return t("At {time} {days}", { time: trigger.at, days: describeDays(trigger.days) });
        case "sun": return describeSun(trigger.event, trigger.offsetMinutes, describeDays(trigger.days));
        case "cron": return t("Cron {expression}", { expression: trigger.cron });
        case "characteristic": {
          const vars = { who: names.get(trigger.id) || trigger.id, characteristic: trigger.characteristic };
          if (trigger.operator === "changes") return t("When {who} {characteristic} changes", vars);
          const comparison = operators.find(([o]) => o === trigger.operator)?.[1] ?? trigger.operator;
          return t("When {who} {characteristic} {comparison} {value}", { ...vars, comparison, value: String(trigger.value) });
        }
        default: return trigger.type;
      }
    })();
    return trigger.enabled === false ? t("{trigger} (off)", { trigger: text }) : text;
  }

  async function scenesView(main) {
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const names = new Map(accessories.map((a) => [a.id, displayName(a)]));
    const card = (scene) => {
      const actions = scene.actions.map((action) => action.recall ? el("div", { class: "control" },
        el("span", { text: action.missing ? t("{name} (gone)", { name: action.name || action.recall }) : action.name || action.recall }),
        el("span", { class: "value", text: t("Hub scene") })) : el("div", { class: "control" },
        el("span", { text: action.missing ? t("{name} (gone)", { name: action.name || action.id }) : action.name || action.id }),
        el("span", { class: "value", text: `${action.characteristic} → ${typeof action.value === "boolean" && !app.enumLabels[action.characteristic] ? (action.value ? t("On") : t("Off")) : app.labelFor(action.characteristic, action.value)}` })));
      const lastVars = scene.lastRun ? { date: dateTimeFormat.format(new Date(scene.lastRun.at)), trigger: scene.lastRun.trigger } : null;
      const last = scene.lastRun ? (scene.lastRun.ok ? t("Last run {date} ({trigger})", lastVars) : t("Last run {date} ({trigger}), with errors", lastVars)) : t("Never run");
      const run = el("button", { actionIcon: "play", class: "primary", text: t("Run") });
      run.addEventListener("click", async () => { if (await runScene(scene, run)) app.route(); });
      const stop = scene.stoppable ? el("button", { type: "button", actionIcon: "stop", text: t("Stop"), onclick: () => stopScene(scene, stop) }) : null;
      return el("div", { class: "card server scene-card" },
        sceneImage(scene),
        el("div", { class: "server-head" }, tile("play", scene.security ? "violet" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: `/scenes/${encodeURIComponent(scene.id)}` }, el("strong", { text: scene.name }),
              scene.active ? el("span", { class: "pill scene-active", text: t("Scene active") }) : null),
            el("div", { class: "muted", text: [scene.room, scene.homeKit ? t("In the Home app") : null, scene.animation ? t("Animated: {style}", { style: scene.animation.effect ? effectStyleNames[scene.animation.effect.style] || scene.animation.effect.style : t("Timed sequence") }) : null, scene.triggers.length ? scene.triggers.map((trigger) => describeTrigger(trigger, names)).join(" · ") : t("Run by hand")].filter(Boolean).join(" · ") })),
          el("div", { class: "scene-run-actions" }, run, stop)),
        el("details", { class: "scene-card-details" }, el("summary", { text: t("Details") }), el("div", { class: "controls" }, actions)),
        scene.security ? el("p", { class: "muted note", text: t("It changes a lock, a door or an alarm: the page asks before running it, and automations leave those actions out.") }) : null,
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: scene.lastSkipped && (!scene.lastRun || scene.lastSkipped.at > scene.lastRun.at) ? t("Skipped {date}: {reason}", { date: dateTimeFormat.format(new Date(scene.lastSkipped.at)), reason: HomeswiftI18n.message(scene.lastSkipped.reason) }) : last }),
          menuButton(t("Actions for {name}", { name: scene.name }), () => [
            { label: t("Run"), icon: "play", onSelect: () => runScene(scene) },
            { label: t("Edit"), icon: "edit", href: `/scenes/${encodeURIComponent(scene.id)}` },
            ...pictureMenu(scene),
            { label: t("Delete"), icon: "trash", danger: true, onSelect: async () => {
              if (!(await HomeswiftAdmin.confirmAction({ title: t("Delete the scene {name}?", { name: scene.name }), text: t("This removes the scene and its automatic triggers. This cannot be undone."), confirmLabel: t("Delete"), confirmIcon: "trash" }))) return;
              try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
            } },
          ])));
    };
    const sceneCount = el("span", { class: "pill", text: String(data.scenes.length) });
    const sceneCards = data.scenes.map((scene) => ({ scene, node: card(scene) }));
    const hubScenes = hubScenesSection(data.pluginScenes || []);
    const search = el("input", { type: "search", class: "search", placeholder: t("Filter text"), "aria-label": t("Your scenes") });
    const noMatches = el("p", { class: "card empty", hidden: true, text: t("Nothing in this range matches.") });
    search.addEventListener("input", () => {
      const query = search.value.trim().toLocaleLowerCase();
      for (const { scene, node } of sceneCards) node.hidden = !scene.name.toLocaleLowerCase().includes(query);
      sceneCount.textContent = String(sceneCards.filter(({ node }) => !node.hidden).length);
      const hubShown = hubScenes.filter(query);
      noMatches.hidden = sceneCards.some(({ node }) => !node.hidden) || hubShown > 0;
    });
    app.show(main,
      app.pageHead(t("Scenes"), t("Accessory values set together, by hand or on a schedule, at sunrise or sunset, or when an accessory changes. Homeswift keeps them; one you choose is also a switch in the Home app."),
        data.scenes.length ? el("a", { class: "button primary", href: "/scenes/new", text: t("New scene") }) : null),
      el("div", { class: "section-head" }, el("h2", { text: t("Your scenes") }), sceneCount, data.scenes.length || hubScenes.node ? [search, HomeswiftCommon.clearFilters([[search, ""]])] : null),
      data.scenes.length ? el("div", { class: "grid scene-grid" }, sceneCards.map(({ node }) => node))
        // Short when the hubs' scenes follow: they are what there is to run.
        : el("div", { class: `card empty scenes-empty${hubScenes.node ? " compact" : ""}` }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("play")), el("p", { class: "muted", text: t("No scene yet. A scene sets several accessories at once, such as every light of a room for the evening.") }), el("a", { class: "button primary", href: "/scenes/new", text: t("New scene") })),
      noMatches, hubScenes.node, templatesSection(accessories, data), locationCard(data));
  }

  /// Where sunrise and sunset are computed for: Glass UI took its weather widget's city; here it is typed, or
  /// this device's position.
  // Small raster map with no third-party scripts. Only visible tiles are requested.
  function locationMap(initial, changed) {
    let latitude = initial?.lat ?? 0, longitude = initial?.lon ?? 0, zoom = initial ? 12 : 2;
    let selected = !!initial, drag = null;
    const clampLat = (value) => Math.max(-85.0511, Math.min(85.0511, value));
    const wrapLon = (value) => ((value + 180) % 360 + 360) % 360 - 180;
    const project = (lat, lon) => {
      const size = 256 * 2 ** zoom, sine = Math.sin(clampLat(lat) * Math.PI / 180);
      return [(lon + 180) / 360 * size, (0.5 - Math.log((1 + sine) / (1 - sine)) / (4 * Math.PI)) * size];
    };
    const unproject = (x, y) => {
      const size = 256 * 2 ** zoom;
      return [clampLat(Math.atan(Math.sinh(Math.PI * (1 - 2 * y / size))) * 180 / Math.PI), wrapLon(x / size * 360 - 180)];
    };
    const tiles = el("div", { class: "location-map-tiles", "aria-hidden": "true" });
    const pin = el("span", { class: "location-map-pin", "aria-hidden": "true" }, HomeswiftCommon.icon("location"));
    const map = el("div", { class: "location-map", tabIndex: 0, role: "group", "aria-label": t("Location map. Drag to move, click to place the pin, or use the arrow keys.") }, tiles, pin);
    const warning = el("p", { class: "muted", hidden: true, text: t("Map unavailable. You can still enter coordinates or use this device's location.") });
    const tileNodes = new Map();
    function draw() {
      const width = map.clientWidth, height = map.clientHeight;
      if (!width || !map.isConnected) return;
      const [x, y] = project(latitude, longitude), left = x - width / 2, top = y - height / 2, count = 2 ** zoom;
      const keep = new Set();
      for (let tx = Math.floor(left / 256); tx <= Math.floor((left + width) / 256); tx++) {
        for (let ty = Math.max(0, Math.floor(top / 256)); ty <= Math.min(count - 1, Math.floor((top + height) / 256)); ty++) {
          const key = `${zoom}/${tx}/${ty}`; keep.add(key);
          let image = tileNodes.get(key);
          if (!image) {
            image = el("img", { alt: "", draggable: false, referrerPolicy: "origin", src: `https://tile.openstreetmap.org/${zoom}/${((tx % count) + count) % count}/${ty}.png` });
            image.addEventListener("error", () => { warning.hidden = false; });
            tileNodes.set(key, image); tiles.append(image);
          }
          image.style.left = `${tx * 256 - left}px`; image.style.top = `${ty * 256 - top}px`;
        }
      }
      for (const [key, image] of tileNodes) if (!keep.has(key)) { image.remove(); tileNodes.delete(key); }
      pin.hidden = !selected;
    }
    const choose = (lat, lon, persist = false) => { latitude = clampLat(lat); longitude = wrapLon(lon); selected = true; changed(latitude, longitude, persist); draw(); };
    const move = (dx, dy, persist = false) => { const [x, y] = project(latitude, longitude); choose(...unproject(x + dx, y + dy), persist); };
    map.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || event.target.closest("button, a")) return;
      drag = { x: event.clientX, y: event.clientY, center: project(latitude, longitude), selected, moved: false };
      map.setPointerCapture(event.pointerId); map.focus({ preventScroll: true });
    });
    map.addEventListener("pointermove", (event) => {
      if (!drag) return;
      const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
      if (Math.hypot(dx, dy) > 4) drag.moved = true;
      if (drag.moved) { [latitude, longitude] = unproject(drag.center[0] - dx, drag.center[1] - dy); selected = true; pin.hidden = false; tiles.style.transform = `translate(${dx}px, ${dy}px)`; }
    });
    map.addEventListener("pointerup", (event) => {
      if (!drag) return;
      const wasDragged = drag.moved; drag = null; tiles.style.transform = "";
      if (map.hasPointerCapture(event.pointerId)) map.releasePointerCapture(event.pointerId);
      if (wasDragged) choose(latitude, longitude, true);
      else { const rect = map.getBoundingClientRect(); move(event.clientX - rect.left - rect.width / 2, event.clientY - rect.top - rect.height / 2, true); }
    });
    map.addEventListener("pointercancel", () => { if (drag) { [latitude, longitude] = unproject(...drag.center); selected = drag.selected; } drag = null; tiles.style.transform = ""; draw(); });
    map.addEventListener("keydown", (event) => {
      const delta = { ArrowLeft: [-64, 0], ArrowRight: [64, 0], ArrowUp: [0, -64], ArrowDown: [0, 64] }[event.key];
      if (delta) { event.preventDefault(); move(...delta); }
    });
    const controls = el("div", { class: "location-map-controls" },
      el("button", { type: "button", actionIcon: "plus", text: t("Zoom in"), onclick: () => { zoom = Math.min(18, zoom + 1); draw(); } }),
      el("button", { type: "button", actionIcon: "minus", text: t("Zoom out"), onclick: () => { zoom = Math.max(1, zoom - 1); draw(); } }));
    const attribution = el("a", { class: "location-map-credit", href: "https://www.openstreetmap.org/copyright", target: "_blank", rel: "noopener", text: "© OpenStreetMap contributors" });
    map.append(controls, attribution);
    const node = el("div", {}, el("p", { class: "muted", text: t("Click the map or finish dragging to save your coordinates. Map tiles load from OpenStreetMap.") }), map, warning);
    let frame;
    const resize = new ResizeObserver(() => { cancelAnimationFrame(frame); frame = requestAnimationFrame(draw); });
    resize.observe(map);
    const lifecycle = new MutationObserver(() => {
      if (!node.isConnected) { resize.disconnect(); lifecycle.disconnect(); cancelAnimationFrame(frame); }
    });
    lifecycle.observe(document.getElementById("view"), { childList: true });
    return { node, draw, set(lat, lon) { latitude = lat; longitude = lon; selected = true; zoom = 12; draw(); } };
  }

  function locationCard(data) {
    const location = data.location;
    const lat = el("input", { type: "number", step: "any", min: -90, max: 90, value: location?.lat ?? "", "aria-label": t("Latitude") });
    const lon = el("input", { type: "number", step: "any", min: -180, max: 180, value: location?.lon ?? "", "aria-label": t("Longitude") });
    const name = el("input", { type: "text", value: location?.name ?? "", placeholder: t("My home"), maxLength: 64 });
    const line = statusLine();
    let saves = Promise.resolve();
    const save = (body, keepMap = false) => {
      saves = saves.then(async () => {
        try {
          const saved = await app.api("/api/scenes/location", { method: "PUT", body });
          if (!keepMap) { app.route(); return; }
          summaryValue.textContent = ` · ${saved.location.name || `${saved.location.lat}, ${saved.location.lon}`}`;
          nextInfo.textContent = t("Next sunrise {sunrise}, sunset {sunset}.", {
            sunrise: saved.nextSunrise ? timeFormat.format(new Date(saved.nextSunrise)) : "—",
            sunset: saved.nextSunset ? timeFormat.format(new Date(saved.nextSunset)) : "—",
          });
          forget.hidden = false;
          say(line, t("Coordinates saved."), "ok");
        } catch (e) { say(line, e.message, "error"); }
      });
      return saves;
    };
    const map = locationMap(location, (latitude, longitude, persist) => {
      lat.value = latitude.toFixed(4); lon.value = longitude.toFixed(4);
      if (persist) { say(line, t("Saving coordinates…")); save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value }, true); }
      else say(line, t("Found: save to keep it."));
    });
    const query = el("input", { id: "location-address", type: "search", enterKeyHint: "search", autocomplete: "off", maxLength: 200, required: true, placeholder: t("Street, city or postcode"), "aria-label": t("Search address") });
    const results = el("div", { class: "location-search-results" });
    const searchStatus = statusLine();
    const loader = el("span", { class: "spinner", hidden: true, "aria-hidden": "true" });
    const setSearching = (busy) => { loader.hidden = !busy; query.setAttribute("aria-busy", String(busy)); };
    const cache = new Map();
    let searchController, searchTimer, searchVersion = 0;
    const searchButton = el("button", { type: "submit", actionIcon: "search", text: t("Search") });
    const searchForm = el("form", { class: "location-search", onsubmit: async (event) => {
      event.preventDefault();
      clearTimeout(searchTimer);
      const term = query.value.trim();
      if (term.length < 3) return;
      searchController?.abort();
      searchController = new AbortController();
      const version = ++searchVersion;
      const timeout = setTimeout(() => searchController.abort(), 10000);
      searchButton.disabled = true; setSearching(true); results.replaceChildren();
      say(searchStatus, t("Searching addresses…"));
      try {
        let features = cache.get(term);
        if (!features) {
          const response = await fetch(`https://photon.komoot.io/api/?q=${encodeURIComponent(term)}&limit=5`, { credentials: "omit", referrerPolicy: "no-referrer", signal: searchController.signal });
          if (!response.ok) throw new Error();
          const payload = await response.json();
          features = (payload.features || []).filter((feature) => {
            const [longitude, latitude] = feature.geometry?.coordinates || [];
            return Number.isFinite(latitude) && Number.isFinite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180;
          }).slice(0, 5);
          if (cache.size >= 30) cache.delete(cache.keys().next().value);
          cache.set(term, features);
        }
        if (version !== searchVersion || query.value.trim() !== term || !searchForm.isConnected) return;
        say(searchStatus, features.length ? t("Select an address to save its coordinates.") : t("No addresses found. Try a city or postcode."));
        for (const feature of features) {
          const p = feature.properties || {};
          const address = [...new Set([p.name, [p.housenumber, p.street].filter(Boolean).join(" "), p.postcode, p.city || p.town || p.village, p.district || p.county, p.state, p.country].filter(Boolean))].join(", ");
          const [longitude, latitude] = feature.geometry.coordinates;
          results.append(el("button", { type: "button", actionIcon: "location", onclick: async () => {
            lat.value = latitude.toFixed(6); lon.value = longitude.toFixed(6);
            map.set(latitude, longitude);
            results.replaceChildren(); query.value = address; query.focus();
            say(searchStatus, ""); say(line, t("Saving coordinates…"));
            await save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value }, true);
          } }, el("span", { class: "location-result-copy" }, el("strong", { text: p.name || p.street || address || `${latitude}, ${longitude}` }), el("span", { class: "muted", text: address }))));
        }
      } catch { if (version === searchVersion) say(searchStatus, t("Address search is unavailable. Try again or choose a point on the map."), "error"); }
      finally { clearTimeout(timeout); if (version === searchVersion) { searchButton.disabled = false; setSearching(false); } }
    } }, el("label", { for: "location-address", class: "field-title", text: t("Search address") }),
      el("div", { class: "location-search-bar" }, el("div", { class: "location-search-input" }, query, loader), searchButton),
      el("p", { class: "muted", text: t("Search sends your query to Photon. Results use OpenStreetMap data.") }), searchStatus, results);
    query.addEventListener("input", () => {
      clearTimeout(searchTimer); ++searchVersion; searchController?.abort();
      searchButton.disabled = false; setSearching(false); results.replaceChildren(); say(searchStatus, "");
      if (query.value.trim().length >= 3) searchTimer = setTimeout(() => searchForm.requestSubmit(), 400);
    });
    query.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown" && results.firstElementChild) { event.preventDefault(); results.firstElementChild.focus(); }
      if (event.key === "Escape") { clearTimeout(searchTimer); ++searchVersion; searchController?.abort(); results.replaceChildren(); say(searchStatus, ""); searchButton.disabled = false; setSearching(false); }
    });
    results.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") { event.preventDefault(); event.target.nextElementSibling?.focus(); }
      if (event.key === "ArrowUp") { event.preventDefault(); (event.target.previousElementSibling || query).focus(); }
      if (event.key === "Escape") { results.replaceChildren(); say(searchStatus, ""); query.focus(); }
    });
    const updateMap = () => { if (lat.value !== "" && lon.value !== "" && lat.checkValidity() && lon.checkValidity()) map.set(Number(lat.value), Number(lon.value)); };
    lat.addEventListener("change", updateMap); lon.addEventListener("change", updateMap);
    const here = el("button", { actionIcon: "location", text: t("Use this device's location"), onclick: () => {
      if (!navigator.geolocation) return say(line, t("This browser cannot tell its location."), "error");
      say(line, t("Asking the browser…"));
      navigator.geolocation.getCurrentPosition(
        (position) => { lat.value = position.coords.latitude.toFixed(4); lon.value = position.coords.longitude.toFixed(4); updateMap(); say(line, t("Found: save to keep it.")); },
        (error) => say(line, error.message || t("The browser did not give its location (it needs HTTPS away from localhost)."), "error"));
    } });
    const next = location ? t("Next sunrise {sunrise}, sunset {sunset}.", { sunrise: data.nextSunrise ? timeFormat.format(new Date(data.nextSunrise)) : "—", sunset: data.nextSunset ? timeFormat.format(new Date(data.nextSunset)) : "—" }) : t("No location yet: sunrise and sunset triggers wait for one.");
    const summaryValue = el("span", { class: "muted", text: ` · ${location ? (location.name || `${location.lat}, ${location.lon}`) : t("not set")}` });
    const nextInfo = el("p", { class: "muted", text: next });
    const forget = el("button", { actionIcon: "trash", class: "link", text: t("Forget it"), hidden: !location, onclick: () => save(null) });
    return el("details", { class: "card location", ontoggle: () => map.draw(), open: !location && data.scenes.some((s) => s.triggers.some((trigger) => trigger.type === "sun")) },
      el("summary", {}, el("strong", { text: t("Location for sunrise and sunset") }), summaryValue),
      nextInfo, searchForm, map.node,
      el("div", { class: "fields" }, field(t("Latitude"), lat), field(t("Longitude"), lon), field(t("Name"), name, t("Only for you to recognise it."))),
      el("div", { class: "actions" },
        el("button", { actionIcon: "check", class: "primary", text: t("Save"), onclick: () => {
          if (lat.value === "" || lon.value === "" || !lat.reportValidity() || !lon.reportValidity()) return say(line, t("Choose a location on the map or enter valid coordinates."), "error");
          save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value });
        } }),
        here, forget),
      line);
  }

  /// The characteristics of an accessory a scene can set: writable, not HomeKit's plumbing.
  function writable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pw") && c.permissions.includes("pr") && !c.internal && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }
  function readable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pr") && !c.internal && !c.confidential && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }

  /// An input for a characteristic's value: a menu for booleans and enumerations, a number within its range,
  /// else text. `.read()` gives the value to save.
  function valueInput(characteristic, value) {
    if (characteristic?.type === "Light color") return colorInput(value);
    if (["Brightness", "Color Temperature", "Hue", "Saturation", "Rotation Speed", "Target Position", "Volume", "Target Temperature", "Heating Threshold Temperature", "Cooling Threshold Temperature"].includes(characteristic?.type)) {
      const temperature = characteristic.type === "Color Temperature";
      const min = characteristic.minValue ?? (temperature ? 140 : 0);
      const max = characteristic.maxValue ?? (temperature ? 500 : characteristic.type === "Hue" ? 360 : 100);
      const slider = el("input", { type: "range", min, max, step: characteristic.minStep || 1,
        value: value ?? characteristic.value ?? min, "aria-label": t(characteristic.type) });
      const output = el("output", { class: "scene-slider-value" });
      const format = new Intl.NumberFormat(HomeswiftI18n.locale, { maximumFractionDigits: 0 });
      const paint = () => {
        const raw = Number(slider.value);
        const unit = characteristic.unit === "celsius" ? " °C" : characteristic.type === "Hue" ? "°" : characteristic.unit === "percentage" || ["Brightness", "Saturation", "Rotation Speed", "Target Position", "Volume"].includes(characteristic.type) ? " %" : "";
        const text = temperature ? `${format.format(Math.round(1000000 / raw))} K` : characteristic.unit === "celsius" ? HomeswiftCommon.formatTemperature(raw) : `${raw}${unit}`;
        output.textContent = text;
        slider.setAttribute("aria-valuetext", text);
      };
      slider.addEventListener("input", paint); paint();
      const wrap = el("span", { class: `scene-value-slider${temperature ? " temperature" : " brightness"}` }, output, slider);
      wrap.read = () => Number(slider.value);
      return wrap;
    }
    const labels = app.enumLabels[characteristic?.type];
    let input;
    if (characteristic?.format === "bool") {
      input = el("input", { type: "checkbox", role: "switch", checked: Boolean(value ?? characteristic.value), "aria-label": t(characteristic.type) });
      input.read = () => input.checked;
    } else if (characteristic && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      input = el("select", {}, values.map((v) => el("option", { value: v, text: app.labelFor(characteristic.type, v) })));
      input.value = String(value ?? values[0]);
      input.read = () => Number(input.value);
    } else if (characteristic && characteristic.format !== "string") {
      input = el("input", { type: "number", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || "any", value: value ?? characteristic.value ?? 0 });
      input.read = () => Number(input.value);
    } else {
      input = el("input", { type: "text", value: value ?? "", maxLength: 256 });
      // An accessory that is gone keeps its value as it was saved.
      input.read = () => !characteristic && input.value === String(value ?? "") && value !== undefined ? value : input.value;
    }
    input.setAttribute("aria-label", t("Value"));
    return input;
  }

  function colorControls(accessory) {
    const chars = writable(accessory);
    return [...chars, ...chars.filter((c) => c.type === "Hue" && chars.some((s) => s.type === "Saturation" && s.service === c.service))
      .map((c) => ({ ...c, type: "Light color", value: { hue: c.value, saturation: chars.find((s) => s.type === "Saturation" && s.service === c.service).value } }))];
  }

  function colorInput(value = {}) {
    const h = Number(value.hue || 0), sat = Number(value.saturation ?? 100) / 100;
    const channel = (n) => { const k = (n + h / 60) % 6; return Math.round(255 * (1 - sat * Math.max(0, Math.min(k, 4 - k, 1)))).toString(16).padStart(2, "0"); };
    const input = el("input", { type: "color", value: `#${channel(5)}${channel(3)}${channel(1)}`, "aria-label": t("Light color"), class: "scene-color-input" });
    let selected = { hue: h, saturation: sat * 100 };
    input.addEventListener("input", () => {
      const [r, g, b] = [1, 3, 5].map((i) => parseInt(input.value.slice(i, i + 2), 16) / 255);
      const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
      const hue = d === 0 ? 0 : max === r ? ((g - b) / d + 6) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
      selected = { hue: Math.round(hue * 60), saturation: Math.round(max === 0 ? 0 : d / max * 100) };
    });
    input.read = () => selected;
    return input;
  }

  /// An accessory and one of its characteristics, with a value input after them when `withValue`.
  function characteristicPicker(accessories, pick, { id, service, characteristic, value, withValue = true, list = writable }) {
    const options = accessories.filter((a) => list(a).length);
    const accessory = el("select", { "aria-label": t("Accessory") }, options.map((a) => el("option", { value: a.id, text: displayName(a) })));
    const kind = el("select", { "aria-label": t("Characteristic") });
    const holder = el("span", { class: "value-slot" });
    let current = null;
    const fill = (keepType, keepValue) => {
      const found = options.find((a) => a.id === accessory.value);
      const chars = found ? list(found) : [];
      const controlName = (type) => type === "On" ? t("Power") : type;
      kind.replaceChildren(...chars.map((c, index) => el("option", { value: index, text: chars.filter((x) => x.type === c.type).length > 1 ? `${controlName(c.type)} (${c.serviceName})` : controlName(c.type) })));
      // An accessory that is gone keeps the characteristic it was saved with.
      if (!chars.length && (keepType ?? characteristic)) kind.append(el("option", { value: 0, text: controlName(keepType ?? characteristic) }));
      const index = Math.max(0, chars.findIndex((c) => c.type === keepType && (!service || c.service === service)));
      kind.value = String(index);
      current = chars[index] || null;
      if (withValue) { holder.replaceChildren(pick.value = valueInput(current, keepValue ?? current?.value)); }
    };
    if (id && options.some((a) => a.id === id)) accessory.value = id;
    else if (id) accessory.prepend(el("option", { value: id, text: t("{name} (gone)", { name: id }), selected: true }));
    fill(characteristic, value);
    accessory.addEventListener("change", () => fill());
    kind.addEventListener("change", () => {
      const found = options.find((a) => a.id === accessory.value);
      current = found ? list(found)[Number(kind.value)] : null;
      if (withValue) holder.replaceChildren(pick.value = valueInput(current, current?.value));
    });
    pick.read = () => {
      const found = options.find((a) => a.id === accessory.value);
      if (!found || !current) return { id: accessory.value, characteristic: characteristic || "", ...(service ? { service } : {}) };
      const several = list(found).filter((c) => c.type === current.type).length > 1;
      return { id: found.id, characteristic: current.type, ...(several ? { service: current.service } : {}) };
    };
    pick.current = () => current;
    return [accessory, kind, holder];
  }

  const rowShell = (...children) => el("div", { class: "editor-row" }, ...children);
  const removeButton = (row, list) => el("button", { class: "icon-button", type: "button", title: t("Remove"), "aria-label": t("Remove"), onclick: () => { list.delete(row); row.remove(); } }, HomeswiftCommon.icon("trash"));

  function daysPicker(days) {
    const chosen = new Set(days && days.length ? days : [0, 1, 2, 3, 4, 5, 6]);
    const node = el("span", { class: "days", role: "group", "aria-label": t("Days") }, weekdayOrder.map((day) => {
      const name = weekdayNames[day];
      const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
      box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
      return el("label", { class: "day", title: name }, box, el("span", { text: weekdays[day] }));
    }));
    node.read = () => chosen.size === 7 || chosen.size === 0 ? undefined : [...chosen].sort();
    return node;
  }

  function timeOfDay(value) {
    const sun = ["sunrise", "sunset"].includes(value);
    const kind = el("select", { "aria-label": t("When") }, el("option", { value: "time", text: t("At") }), el("option", { value: "sunrise", text: t("Sunrise") }), el("option", { value: "sunset", text: t("Sunset") }));
    kind.value = sun ? value : "time";
    const time = el("input", { type: "time", value: sun ? "00:00" : value || "18:00", "aria-label": t("Time") });
    time.classList.toggle("hidden", sun);
    kind.addEventListener("change", () => time.classList.toggle("hidden", kind.value !== "time"));
    const node = el("span", { class: "group-inline" }, kind, time);
    node.read = () => kind.value === "time" ? time.value : kind.value;
    return node;
  }

  async function sceneEditor(main, id) {
    const isNew = id === "new";
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const scene = isNew ? { name: "", actions: [], triggers: [], conditions: [] } : data.scenes.find((s) => s.id === id);
    if (!scene) { app.show(main, el("p", { class: "error", text: t("No such scene.") })); return; }
    const choices = accessories.filter((a) => !a.hidden || scene.actions.some((x) => x.id === a.id));

    const name = el("input", { type: "text", value: scene.name, maxLength: 64, required: true, placeholder: t("Evening") });
    const homeKit = el("input", { type: "checkbox", checked: Boolean(scene.homeKit) });
    // The settings pages' toggle: a switch, then its title over its help.
    const homeKitRow = el("label", { class: "toggle" }, el("span", { class: "switch" }, homeKit, el("span")), el("span", {},
      el("span", { class: "field-title", text: t("A switch in the Home app") }),
      el("p", { class: "help", text: t("On the Homeswift Scenes accessory: turning it on runs the scene (without its locks, doors and alarms), turning it off puts the lights back.") })));
    let artworkId = scene.artworkId || null;
    const themes = await loadArtworkThemes();
    const artworkPreview = el("div", { class: "artwork-preview" }, artworkImage(artworkId));
    const artworkButtons = [];
    const selectArtwork = (id) => {
      artworkId = id;
      artworkPreview.replaceChildren(...[artworkImage(id)].filter(Boolean));
      for (const [value, button] of artworkButtons) button.setAttribute("aria-pressed", String(value === id));
    };
    const makeArtworkButton = (item) => {
      const button = el("button", { type: "button", class: "scene pictured artwork-choice", "aria-pressed": String(item.id === artworkId), onclick: () => selectArtwork(item.id) },
        artworkImage(item.id), el("span", { class: "name", text: item.name }));
      artworkButtons.push([item.id, button]); return button;
    };
    const clearArtwork = el("button", { type: "button", actionIcon: "close", text: t("No image"), onclick: () => selectArtwork(null) });
    const artworkPicker = el("details", { class: "artwork-picker" }, el("summary", { text: t("Scene image") }), clearArtwork,
      themedArtwork(data.artworks || [], themes, makeArtworkButton));
    const actions = new Set(), triggers = new Set(), conditions = new Set();
    const actionList = el("div", { class: "editor-list" }), triggerList = el("div", { class: "editor-list" }), conditionList = el("div", { class: "editor-list" });

    // A labelled remove button for an action, trigger or condition.
    const deleteButton = (row, list, label) => {
      const remove = removeButton(row, list);
      remove.className = "danger scene-condition-remove";
      remove.append(el("span", { text: label }));
      remove.title = label;
      remove.setAttribute("aria-label", label);
      return remove;
    };
    const hubScenes = data.pluginScenes || [];
    /// A hub's scene to recall: its name and source, not editable; removed and added again to change it.
    const addRecall = (id) => {
      const known = hubScenes.find((scene) => scene.id === id);
      const action = scene.actions.find((a) => a.recall === id);
      const name = known?.name || action?.name || id;
      const fields = rowShell(el("p", { class: "muted", text: known ? t("Recalled on {source}.", { source: known.source.name }) : t("This hub's scene is gone: the run skips it.") }));
      const summary = el("summary", { class: "scene-action-summary" }, HomeswiftCommon.icon("play"),
        el("span", {}, el("strong", { text: name }), el("small", { text: t("Hub scene") })), HomeswiftCommon.icon("down"));
      const row = el("details", { class: "scene-action" }, summary, fields);
      row.read = () => [{ recall: id }];
      fields.append(deleteButton(row, actions, t("Delete action")));
      actions.add(row);
      actionList.append(row);
    };
    const recallPicker = hubScenes.length ? (() => {
      const select = el("select", { "aria-label": t("Hub scene") }, el("option", { value: "", text: t("Add a hub scene…") }),
        hubScenes.map((hub) => el("option", { value: hub.id, text: `${hub.name} · ${hub.source.name}` })));
      select.addEventListener("change", () => { if (select.value) addRecall(select.value); select.value = ""; });
      return select;
    })() : null;
    const addAction = (action = {}) => {
      if (action.recall) return addRecall(action.recall);
      const pick = {};
      const [accessory, control, value] = characteristicPicker(choices, pick, { id: action.id, service: action.service, characteristic: action.characteristic, value: action.value, list: colorControls });
      control.setAttribute("aria-label", t("Control"));
      const fields = rowShell(field(t("Accessory"), accessory), field(t("Control"), control), field(t("Value"), value));
      const summary = el("summary", { class: "scene-action-summary" });
      const row = el("details", { class: "scene-action", open: !action.id || actions.size === 0 }, summary, fields);
      const describe = () => summary.replaceChildren(
        HomeswiftCommon.icon("sliders"),
        el("span", {}, el("strong", { text: accessory.selectedOptions[0]?.textContent || action.id || "" }),
          el("small", { text: control.selectedOptions[0]?.textContent || action.characteristic || "" })),
        HomeswiftCommon.icon("down"));
      fields.addEventListener("change", describe);
      describe();
      row.read = () => {
        const target = pick.read(), value = pick.value.read();
        return target.characteristic === "Light color"
          ? [{ ...target, service: pick.current().service, characteristic: "Hue", value: value.hue }, { ...target, service: pick.current().service, characteristic: "Saturation", value: value.saturation }]
          : [{ ...target, value }];
      };
      fields.append(deleteButton(row, actions, t("Delete action")));
      actions.add(row);
      actionList.append(row);
    };
    const addTrigger = (trigger = { type: "time", at: "18:00" }) => {
      const type = el("select", { "aria-label": t("Trigger") },
        el("option", { value: "time", text: t("At a time") }), el("option", { value: "sun", text: t("Sunrise or sunset") }),
        el("option", { value: "characteristic", text: t("When an accessory changes") }), el("option", { value: "cron", text: t("Cron") }));
      type.value = trigger.type;
      const enabled = el("input", { type: "checkbox", checked: trigger.enabled !== false, "aria-label": t("On [setting]") });
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body, el("label", { class: "toggle compact" }, enabled, el("span", { text: t("On [setting]") })));
      const draw = (shown) => {
        if (shown.type === "time") {
          const at = el("input", { type: "time", value: shown.at || "18:00", "aria-label": t("Time") });
          const days = daysPicker(shown.days);
          body.replaceChildren(at, days);
          row.readBody = () => ({ at: at.value, days: days.read() });
        } else if (shown.type === "sun") {
          const event = el("select", { "aria-label": t("Event") }, el("option", { value: "sunrise", text: t("Sunrise") }), el("option", { value: "sunset", text: t("Sunset") }));
          event.value = shown.event || "sunset";
          const offset = el("input", { type: "number", min: -720, max: 720, step: 1, value: shown.offsetMinutes ?? 0, "aria-label": t("Minutes after (negative: before)"), title: t("Minutes after; negative for before") });
          const days = daysPicker(shown.days);
          body.replaceChildren(event, offset, el("span", { class: "muted", text: "min" }), days);
          row.readBody = () => ({ event: event.value, offsetMinutes: Number(offset.value) || 0, days: days.read() });
        } else if (shown.type === "characteristic") {
          const pick = {};
          const operator = el("select", { "aria-label": t("Condition") }, el("option", { value: "changes", text: t("changes") }), operators.map(([value, text]) => el("option", { value, text })));
          operator.value = shown.operator || "changes";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: shown.id, characteristic: shown.characteristic, value: shown.value, list: readable });
          holder.classList.toggle("hidden", operator.value === "changes");
          operator.addEventListener("change", () => holder.classList.toggle("hidden", operator.value === "changes"));
          body.replaceChildren(field(t("Accessory"), accessory), field(t("Control"), kind), field(t("Comparison"), operator), field(t("Value"), holder));
          row.readBody = () => ({ ...pick.read(), operator: operator.value, ...(operator.value === "changes" ? {} : { value: pick.value.read() }) });
        } else {
          const cron = el("input", { type: "text", value: shown.cron || "0 7 * * 1-5", placeholder: "0 7 * * 1-5", "aria-label": t("Cron expression"), class: "mono" });
          body.replaceChildren(cron);
          row.readBody = () => ({ cron: cron.value });
        }
      };
      draw(trigger);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...(enabled.checked ? {} : { enabled: false }), ...row.readBody() });
      row.append(deleteButton(row, triggers, t("Delete trigger")));
      triggers.add(row);
      triggerList.append(row);
    };
    const addCondition = (condition = { type: "time", after: "sunset", before: "23:00" }) => {
      const type = el("select", { "aria-label": t("Condition") }, el("option", { value: "time", text: t("Between") }), el("option", { value: "characteristic", text: t("Only if") }));
      type.value = condition.type;
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(field(t("Condition"), type), body);
      body.classList.add("scene-condition-fields");
      const draw = (c) => {
        if (c.type === "time") {
          const after = timeOfDay(c.after || "sunset"), before = timeOfDay(c.before || "23:00");
          body.replaceChildren(
            el("div", { class: "condition-time-point", role: "group", "aria-label": t("Start time") }, el("span", { class: "field-title", text: t("Start time") }), after),
            el("div", { class: "condition-time-point", role: "group", "aria-label": t("End time") }, el("span", { class: "field-title", text: t("End time") }), before));
          row.readBody = () => ({ after: after.read(), before: before.read() });
        } else {
          const pick = {};
          const operator = el("select", { "aria-label": t("Comparison") }, operators.map(([value, text]) => el("option", { value, text })));
          operator.value = c.operator || "eq";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: c.id, characteristic: c.characteristic, value: c.value, list: readable });
          body.replaceChildren(field(t("Accessory"), accessory), field(t("Control"), kind), field(t("Comparison"), operator), field(t("Value"), holder));
          row.readBody = () => ({ ...pick.read(), operator: operator.value, value: pick.value.read() });
        }
      };
      draw(condition);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...row.readBody() });
      row.append(deleteButton(row, conditions, t("Delete condition")));
      conditions.add(row);
      conditionList.append(row);
    };
    const paired = new Set();
    scene.actions.forEach((action, index) => {
      if (paired.has(index)) return;
      const other = scene.actions.findIndex((a, j) => j > index && a.id === action.id && a.service === action.service && a.characteristic === (action.characteristic === "Hue" ? "Saturation" : "Hue"));
      if (["Hue", "Saturation"].includes(action.characteristic) && other === index + 1 && scene.actions.filter((a) => a.id === action.id && a.service === action.service && ["Hue", "Saturation"].includes(a.characteristic)).length === 2 && choices.some((a) => a.id === action.id && colorControls(a).some((c) => c.type === "Light color" && (!action.service || c.service === action.service)))) {
        paired.add(other);
        addAction({ ...action, characteristic: "Light color", value: { hue: action.characteristic === "Hue" ? action.value : scene.actions[other].value, saturation: action.characteristic === "Saturation" ? action.value : scene.actions[other].value } });
      } else addAction(action);
    });
    scene.triggers.forEach(addTrigger);
    scene.conditions.forEach(addCondition);
    if (isNew && choices.length) addAction();

    // A whole accessory's current state at once, as save_scene captures it.
    const capture = el("select", { "aria-label": t("Add the current state of an accessory") }, el("option", { value: "", text: t("Add an accessory as it is now…") }),
      choices.filter((a) => writable(a).length).map((a) => el("option", { value: a.id, text: displayName(a) })));
    capture.addEventListener("change", () => {
      const accessory = choices.find((a) => a.id === capture.value);
      capture.value = "";
      if (!accessory) return;
      for (const c of writable(accessory)) if (!c.security && c.value !== null && c.value !== undefined) addAction({ id: accessory.id, characteristic: c.type, value: c.value });
    });

    const canvas = el("div", { class: "scene-flow-canvas" });
    const viewport = el("div", { class: "scene-flow-viewport", tabIndex: 0, "aria-label": t("Workflow canvas") }, canvas);
    const inspector = el("aside", { class: "scene-flow-inspector", hidden: true, "aria-label": t("Edit step") });
    const navigation = el("nav", { class: "scene-flow-navigation", "aria-label": t("Steps") });
    const stepEntries = [];
    let selectedStep = null;
    const closeEditor = () => {
      inspector.hidden = true;
      flow.classList.remove("editing");
      for (const step of stepEntries) { step.node.setAttribute("aria-expanded", "false"); step.nav.classList.remove("on"); step.nav.setAttribute("aria-pressed", "false"); }
      selectedStep?.node.focus({ preventScroll: true });
    };
    inspector.addEventListener("keydown", (event) => { if (event.key === "Escape") { event.stopPropagation(); closeEditor(); } });
    const openStep = (step) => {
      selectedStep = step;
      for (const entry of stepEntries) { entry.panel.hidden = entry !== step; entry.node.setAttribute("aria-expanded", String(entry === step)); entry.nav.classList.toggle("on", entry === step); entry.nav.setAttribute("aria-pressed", String(entry === step)); }
      inspector.hidden = false;
      flow.classList.add("editing");
      step.panel.querySelector("button").focus({ preventScroll: true });
    };
    canvas.append(el("div", { class: "scene-flow-terminal" }, HomeswiftCommon.icon("play"), el("span", { text: t("Start") })));
    // The animation: an effect (each brand's own where its lights have it, Homeswift's elsewhere) on chosen lights,
    // after the actions. A timed sequence (from a template) is kept as it is.
    const animationRows = new Set();
    const animation = (() => {
      const current = scene.animation, effect = current?.effect || {};
      const style = el("select", { "aria-label": t("Animation") }, el("option", { value: "", text: t("No animation") }),
        current?.steps ? el("option", { value: "sequence", text: t("Timed sequence") }) : null,
        Object.entries(effectStyleNames).map(([value, label]) => el("option", { value, text: label })));
      style.value = current?.steps ? "sequence" : effect.style || "";
      const speed = el("input", { type: "range", min: 0, max: 100, value: Math.round((effect.speed ?? 0.5) * 100) });
      const brightness = el("input", { type: "range", min: 1, max: 100, value: effect.brightness ?? 80 });
      const minutes = el("input", { type: "number", min: 1, max: 60, value: Math.round((effect.durationSeconds ?? 900) / 60) });
      const tint = el("input", { type: "checkbox", checked: !!effect.colors?.length });
      const first = colorInput(effect.colors?.[0] || { hue: 30, saturation: 100 }), second = colorInput(effect.colors?.[1] || { hue: 280, saturation: 80 });
      const lights = choices.filter((a) => a.services.some((s) => s.type === "Lightbulb")).map((a) => {
        const input = el("input", { type: "checkbox", value: a.id, checked: !!current?.lights?.includes(a.id) });
        return { input, node: el("label", { class: "toggle compact" }, input, el("span", { text: displayName(a) })) };
      });
      const speedField = field(t("Speed"), speed), brightnessField = field(t("Brightness"), brightness), minutesField = field(t("Minutes"), minutes);
      const tintField = el("label", { class: "toggle compact" }, tint, el("span", { text: t("Its own colour") }));
      const colours = el("div", { class: "animation-colours" }, first, second);
      const settings = el("div", { class: "animation-settings" }, speedField, brightnessField, minutesField, tintField, colours,
        el("div", { class: "field-title", text: t("Lights") }), lights.length ? el("div", { class: "animation-lights" }, lights.map(({ node }) => node)) : el("p", { class: "muted", text: t("No light to animate.") }));
      const sync = () => {
        const value = style.value, timed = value === "sunrise" || value === "sunset", palette = value === "palette";
        const effect = value && value !== "sequence" && value !== "music";
        settings.hidden = !value;
        speedField.hidden = !effect || timed;
        brightnessField.hidden = !effect;
        minutesField.hidden = !timed;
        tintField.hidden = !effect || timed || palette;
        colours.hidden = !(palette || (tint.checked && !tintField.hidden));
        second.hidden = !palette;
        animationRows.clear();
        if (value) animationRows.add(style);
      };
      style.addEventListener("change", sync); tint.addEventListener("change", sync);
      sync();
      const read = () => {
        const value = style.value;
        // Lights the page cannot list now (a paused plugin's) stay in the animation.
        const unlisted = (current?.lights || []).filter((id) => !lights.some(({ input }) => input.value === id));
        const chosen = [...lights.filter(({ input }) => input.checked).map(({ input }) => input.value), ...unlisted];
        if (!value) return null;
        if (value === "sequence") return { ...current, lights: chosen };
        const result = { style: value };
        if (!speedField.hidden) result.speed = Number(speed.value) / 100;
        if (!brightnessField.hidden) result.brightness = Number(brightness.value);
        if (!minutesField.hidden) result.durationSeconds = Number(minutes.value) * 60;
        if (!colours.hidden) result.colors = value === "palette" ? [first.read(), second.read()] : [first.read()];
        return { lights: chosen, effect: result };
      };
      return { content: el("div", {}, field(t("Animation"), style), settings), read };
    })();
    const node = (title, glyph, tone, description, rows, content) => {
      const count = el("span", { class: "scene-flow-count", text: String(rows.size) });
      const summary = el("span", { class: "scene-flow-summary" });
      const card = el("button", { type: "button", class: `scene-flow-step ${tone}`, "aria-expanded": "false", onclick: () => openStep(entry) },
        el("span", { class: "scene-flow-step-icon", "aria-hidden": "true" }, HomeswiftCommon.icon(glyph)),
        el("span", { class: "scene-flow-step-label" }, el("strong", { text: title }), summary), HomeswiftCommon.icon("edit"));
      const nav = el("button", { type: "button", class: "scene-flow-nav", actionIcon: glyph, "aria-pressed": "false", onclick: () => openStep(entry) }, el("span", { text: title }), count);
      const panel = el("section", { class: "scene-flow-panel", hidden: true },
        el("div", { class: "scene-flow-inspector-head" }, HomeswiftCommon.icon(glyph), el("h3", { text: title }),
          el("button", { type: "button", actionIcon: "close", "aria-label": t("Close editor"), onclick: closeEditor })),
        el("div", { class: "scene-flow-body" }, el("p", { class: "muted", text: description }), content));
      const entry = { node: card, nav, panel };
      const update = () => { count.textContent = String(rows.size); summary.textContent = t("{count} configured", { count: rows.size }); };
      update();
      const observer = new MutationObserver(update);
      // Observe the editor's rows; adding or deleting one updates its compact canvas summary.
      observer.observe(panel.querySelector(".scene-flow-body"), { childList: true, subtree: true });
      entry.disconnect = () => observer.disconnect();
      stepEntries.push(entry); navigation.append(nav); inspector.append(panel);
      canvas.append(el("div", { class: "scene-flow-connector", "aria-hidden": "true" }, HomeswiftCommon.icon("down")), card);
    };
    node(t("Triggers"), "play", "trigger", data.location ? t("Run it automatically. Sunrise and sunset are for {place}.", { place: data.location.name || `${data.location.lat}, ${data.location.lon}` }) : t("Run it automatically. Sunrise and sunset need a location: set it on the Scenes page."), triggers,
      [triggerList, el("button", { actionIcon: "plus", type: "button", text: t("Add a trigger"), onclick: () => addTrigger() })]);
    node(t("Conditions"), "shield", "condition", t("An automatic run goes ahead only when all of these hold. Running it by hand ignores them."), conditions,
      [conditionList, el("button", { actionIcon: "plus", type: "button", text: t("Add a condition"), onclick: () => addCondition() })]);
    node(t("Actions"), "bulb", "action", t("The values to set, in this order."), actions,
      [actionList, el("button", { actionIcon: "plus", type: "button", text: t("Add an action"), onclick: () => addAction() }), recallPicker, capture]);
    node(t("Animation"), "sparkle", "action", t("Plays on the chosen lights after the actions: each brand's own effect where its lights have it (Hue, Govee, IKEA, Ambilight), Homeswift's elsewhere. Stopping the scene puts the lights back."), animationRows,
      animation.content);
    canvas.append(el("div", { class: "scene-flow-connector", "aria-hidden": "true" }, HomeswiftCommon.icon("down")),
      el("div", { class: "scene-flow-terminal finish" }, HomeswiftCommon.icon("check"), el("span", { text: t("Finish") })));
    let zoom = 1;
    const zoomLabel = el("span", { class: "scene-flow-zoom", text: "100%" });
    const changeZoom = (value) => { zoom = Math.max(.6, Math.min(1.5, value)); canvas.style.zoom = zoom; zoomLabel.textContent = `${Math.round(zoom * 100)}%`; };
    const flow = el("div", { class: "scene-flow" }, el("div", { class: "scene-flow-toolbar" },
      el("strong", { class: "scene-flow-title" }, HomeswiftCommon.icon("sliders"), el("span", { text: t("Workflow") })),
      el("button", { type: "button", actionIcon: "minus", "aria-label": t("Zoom out"), onclick: () => changeZoom(zoom - .1) }), zoomLabel,
      el("button", { type: "button", actionIcon: "plus", "aria-label": t("Zoom in"), onclick: () => changeZoom(zoom + .1) }),
      el("button", { type: "button", actionIcon: "history", text: t("Reset view"), onclick: () => { changeZoom(1); viewport.scrollTo({ top: 0, left: 0 }); } })),
      el("div", { class: "scene-flow-workspace" }, el("aside", { class: "scene-flow-sidebar" },
        el("h3", { text: t("Steps") }), navigation, el("p", { class: "muted", text: t("Select a step to edit its settings.") })), viewport, inspector));
    const lifecycle = new MutationObserver(() => { if (!flow.isConnected) { stepEntries.forEach((entry) => entry.disconnect()); lifecycle.disconnect(); } });
    lifecycle.observe(main, { childList: true });

    const line = statusLine();
    const save = el("button", { class: "primary", actionIcon: "check", type: "submit", text: isNew ? t("Create the scene") : t("Save") });
    // A new scene of lights only, without triggers or an animation, can be kept on the hub that has them all instead.
    const hubLight = new Set(["on", "brightness", "hue", "saturation", "colortemperature"]);
    const keepOn = el("select", { "aria-label": t("Keep it on"), hidden: true });
    let targetsAsked = "";
    const refreshTargets = async () => {
      if (!isNew) return;
      let read;
      // A row still being filled in has nothing to read yet.
      try { read = [...actions].flatMap((row) => row.read()); } catch { return; }
      const fits = read.length && !read.some((a) => a.recall || !hubLight.has(String(a.characteristic).toLowerCase().replace(/\s/g, "")))
        && ![...triggers].length && !animation.read() && !homeKit.checked;
      const ids = fits ? [...new Set(read.map((a) => a.id))].sort() : [];
      const key = ids.join("|");
      if (key === targetsAsked) return;
      targetsAsked = key;
      const targets = ids.length ? (await app.api("/api/scenes/targets", { method: "POST", body: { ids } }).catch(() => ({ targets: [] }))).targets : [];
      if (key !== targetsAsked) return;
      const kept = keepOn.value;
      keepOn.replaceChildren(el("option", { value: "", text: t("Keep it in Homeswift") }),
        ...targets.map((target) => el("option", { value: target.hub, text: t("Save to {hub} ({place})", { hub: target.name, place: target.label }) })));
      keepOn.value = targets.some((target) => target.hub === kept) ? kept : "";
      keepOn.hidden = !targets.length;
    };
    const form = el("form", { class: "card scene-editor", onsubmit: async (event) => {
      event.preventDefault();
      const body = { name: name.value.trim(), artworkId, homeKit: homeKit.checked, actions: [...actions].flatMap((row) => row.read()), triggers: [...triggers].map((row) => row.read()), conditions: [...conditions].map((row) => row.read()), animation: animation.read() };
      save.disabled = true;
      if (isNew && keepOn.value && !keepOn.hidden) {
        try {
          await app.api("/api/scenes/hub", { method: "POST", body: { hub: keepOn.value, name: body.name, actions: body.actions } });
          app.navigate("/scenes");
        } catch (e) { say(line, e.message, "error"); save.disabled = false; }
        return;
      }
      try {
        const saved = await app.api(isNew ? "/api/scenes" : `/api/scenes/${encodeURIComponent(scene.id)}`, { method: isNew ? "POST" : "PUT", body });
        const security = saved.actions.some((a) => a.security);
        if (security && body.triggers.some((trigger) => trigger.enabled !== false)) {
          say(line, t("Saved. Its lock, door or alarm actions run only when you run it here: automations leave them out."), "ok");
          if (isNew) setTimeout(() => app.navigate(`/scenes/${encodeURIComponent(saved.id)}`, { replace: true }), 1500);
        } else {
          app.navigate("/scenes");
        }
      } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    } },
      field(t("Name"), name), homeKitRow, artworkPreview, artworkPicker,
      flow,
      el("div", { class: "save-bar" }, save, keepOn, el("a", { class: "button", actionIcon: "close", href: "/scenes", text: t("Cancel") }),
        isNew ? null : el("span", { class: "spacer" }),
        isNew ? null : el("button", { actionIcon: "trash", type: "button", class: "danger", text: t("Delete"), onclick: async () => {
          if (!(await HomeswiftAdmin.confirmAction({ title: t("Delete the scene {name}?", { name: scene.name }), text: t("This removes the scene and its automatic triggers. This cannot be undone."), confirmLabel: t("Delete"), confirmIcon: "trash" }))) return;
          try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.navigate("/scenes"); } catch (e) { say(line, e.message, "error"); }
        } })),
      line);
    form.addEventListener("change", refreshTargets);
    form.addEventListener("click", () => setTimeout(refreshTargets));
    app.show(main, app.breadcrumb([t("Scenes"), "/scenes"], [isNew ? t("New scene") : scene.name]), form);
    refreshTargets();
  }

  // ---- Notifications ---------------------------------------------------------------------------------

  const channelInfo = {
    webhook: [t("Webhook"), t("A JSON POST to a URL of yours: event, title, message, instance, timestamp."), [["url", t("URL"), "https://…", true]]],
    ntfy: ["ntfy", t("A topic on ntfy.sh or your own ntfy server; the app shows it on a phone."), [["server", t("Server"), "https://ntfy.sh"], ["topic", t("Topic"), "homeswift-…"], ["token", t("Access token"), t("for a protected topic"), true]]],
    pushover: ["Pushover", t("Your user key and an application token from pushover.net."), [["userKey", t("User key"), "", true], ["appToken", t("Application token"), "", true]]],
    telegram: ["Telegram", t("A bot's token from @BotFather, and the chat it writes to."), [["botToken", t("Bot token"), "123456:ABC…", true], ["chatId", t("Chat id"), t("-100… or @channel")]]],
    browser: [t("This browser and others"), t("Web Push to the browsers that turned it on below. It needs HTTPS (or localhost)."), []],
  };

  /// A short name for this browser: "Safari on macOS".
  function browserLabel() {
    const ua = navigator.userAgent;
    const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    return os ? `${browser} on ${os}` : browser;
  }
  const keyBytes = (base64url) => Uint8Array.from(atob(base64url.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((base64url.length + 3) % 4)), (c) => c.charCodeAt(0));
  const pushSupported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

  async function currentSubscription() {
    if (!pushSupported()) return null;
    const registration = await navigator.serviceWorker.getRegistration("/");
    return registration ? registration.pushManager.getSubscription() : null;
  }

  async function notificationsView(main) {
    const settings = await app.api("/api/notifications");
    const line = statusLine();
    const inputs = {};
    const test = async (channel) => {
      say(line, t("Sending…"));
      try {
        const answer = await app.api("/api/notifications/test", { method: "POST", body: channel ? { channel } : {} });
        const failed = answer.results.filter((r) => !r.ok);
        say(line, failed.length ? failed.map((r) => `${r.channel}: ${HomeswiftI18n.message(r.error)}`).join("; ") : t("Sent through {channels}.", { channels: answer.results.map((r) => r.channel).join(", ") }), failed.length ? "error" : "ok");
      } catch (e) { say(line, e.message, "error"); }
    };
    const cards = Object.entries(channelInfo).sort(([a], [b]) => Number(b === "browser") - Number(a === "browser")).map(([channel, [title, help, fields]]) => {
      const values = settings.channels[channel];
      const enabled = el("input", { type: "checkbox", checked: values.enabled, "aria-label": t("{channel} on", { channel: title }) });
      inputs[channel] = { enabled };
      const rows = fields.map(([key, label, placeholder, secret]) => {
        const input = el("input", { type: secret ? "password" : "text", value: values[key] ?? "", placeholder, autocomplete: "off", spellcheck: false });
        inputs[channel][key] = input;
        return field(label, input);
      });
      if (channel === "webhook") {
        const authOptions = [["none", t("No authentication")], ["bearer", t("Bearer token")], ["basic", t("Basic authentication")]];
        const auth = { value: values.auth || "none" };
        const authText = el("span", { text: authOptions.find(([value]) => value === auth.value)?.[1] || t("No authentication") });
        const authButton = el("button", { type: "button", class: "webhook-auth-picker", "aria-label": t("Authentication"), "aria-haspopup": "menu", "aria-expanded": "false",
          onclick: (event) => HomeswiftCommon.menu(authButton, authOptions.map(([value, label]) => ({ label, checked: auth.value === value,
            onSelect: () => { auth.value = value; authText.textContent = label; showAuth(); }
          })), { keyboard: event.detail === 0 }) }, authText, HomeswiftCommon.icon("down"));
        inputs[channel].auth = auth;
        const credential = (key, label) => {
          const input = el("input", { type: "password", value: values[key] || "", autocomplete: "off", "aria-label": label });
          inputs[channel][key] = input;
          return field(label, input);
        };
        const bearer = credential("token", t("Bearer token"));
        const basic = el("div", {}, credential("username", t("Username")), credential("password", t("Password")));
        const showAuth = () => { bearer.hidden = auth.value !== "bearer"; basic.hidden = auth.value !== "basic"; };
        showAuth();
        const headerRows = el("div", { class: "webhook-header-rows" });
        const addHeader = (name = "", value = "") => {
          const key = el("input", { value: name, placeholder: t("Header name"), "aria-label": t("Header name"), autocomplete: "off", spellcheck: false });
          const secret = el("input", { type: "password", value, placeholder: t("Header value"), "aria-label": t("Header value"), autocomplete: "off" });
          const row = el("div", { class: "webhook-header-row" }, key, secret,
            el("button", { type: "button", title: t("Remove header"), "aria-label": t("Remove header"), onclick: () => row.remove() }, HomeswiftCommon.icon("trash")));
          headerRows.append(row);
        };
        Object.entries(values.headers || {}).forEach(([name, value]) => addHeader(name, value));
        inputs[channel].headers = { type: "headers", get value() {
          const result = {}, names = new Set();
          for (const row of headerRows.children) {
            const [key, secret] = row.querySelectorAll("input");
            const name = key.value.trim();
            if (!name && !secret.value) continue;
            if (!name || names.has(name.toLowerCase())) throw new Error(t("Each header needs a unique name."));
            names.add(name.toLowerCase());
            Object.defineProperty(result, name, { value: secret.value, enumerable: true });
          }
          return result;
        } };
        rows.push(field(t("Authentication"), authButton), bearer, basic,
          el("div", { class: "webhook-headers" }, el("strong", { text: t("Custom headers") }), headerRows,
            el("button", { actionIcon: "plus", type: "button", class: "link", text: t("Add header"), onclick: () => addHeader() }),
            el("p", { class: "help", text: t("Saved credentials and header values are masked. Leave the mask unchanged to keep them.") })));
      }
      const state = el("span", { class: `notification-state${values.enabled ? " active" : ""}`, text: values.enabled ? t("On [setting]") : t("Off [setting]") });
      enabled.addEventListener("change", () => {
        state.textContent = enabled.checked ? t("On [setting]") : t("Off [setting]");
        state.classList.toggle("active", enabled.checked);
      });
      enabled.setAttribute("role", "switch");
      return el("div", { class: `card server notification-channel${channel === "browser" ? " notification-browser" : ""}` },
        el("div", { class: "server-head" }, tile(channel === "browser" ? "accessory" : "bell", channel === "browser" ? "blue" : "orange"),
          el("div", { class: "who" }, el("strong", { text: title })),
          el("label", { class: "switch" }, enabled, el("span"))),
        el("p", { class: "muted note", text: help }),
        rows.length ? el("details", { class: "notification-setup", open: values.enabled },
          el("summary", { text: t("Settings") }), el("div", { class: "notification-fields" }, rows)) : browserPanel(settings),
        el("div", { class: "card-foot" }, state,
          menuButton(t("Actions for {name}", { name: title }), () => [{ label: t("Send a test"), icon: "bell", onSelect: () => test(channel) }])));
    });
    const events = settings.events.map((event) => {
      const label = HomeswiftI18n.message(event.label);
      const box = el("input", { type: "checkbox", role: "switch", checked: event.enabled, "aria-label": label });
      box.dataset.event = event.name;
      return el("label", { class: "notification-event" },
        el("span", { class: "who" }, el("span", { text: label }),
          event.name === "dailyDigest" && !settings.assistant ? el("span", { class: "help", text: t("Needs the Assistant (a HomeswiftAiKit block).") }) : null),
        el("span", { class: "switch" }, box, el("span")));

    });
    const digestTime = el("input", { type: "time", value: settings.dailyDigestTime, "aria-label": t("Daily digest time") });
    const save = el("button", { actionIcon: "check", class: "primary", text: t("Save") });
    save.addEventListener("click", async () => {
      const channels = {};
      try {
        for (const [channel, fields] of Object.entries(inputs)) {
          channels[channel] = {};
          for (const [key, input] of Object.entries(fields)) channels[channel][key] = input.type === "checkbox" ? input.checked : input.value;
        }
      } catch (error) { say(line, error.message, "error"); return; }
      const body = { channels, events: Object.fromEntries([...main.querySelectorAll("[data-event]")].map((box) => [box.dataset.event, box.checked])), dailyDigestTime: digestTime.value };
      save.disabled = true;
      try { await app.api("/api/notifications", { method: "PUT", body }); say(line, t("Saved."), "ok"); } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    });
    app.show(main,
      app.pageHead(t("Notifications"), t("Choose where alerts arrive and which events matter to you.")),
      el("div", { class: "notification-layout" },
        el("section", { class: "notification-delivery", "aria-label": t("Delivery channels") },
          el("div", { class: "section-head" }, el("h2", { text: t("Delivery channels") })),
          el("div", { class: "notification-channels" }, cards)),
        el("section", { class: "card notification-events", "aria-label": t("Events") },
          el("h2", { text: t("Events") }),
          el("p", { class: "muted", text: t("Choose what you want to hear about.") }),
          el("div", { class: "notification-event-list" }, events),
          el("div", { class: "notification-digest" }, field(t("Daily digest at"), digestTime)),
          el("p", { class: "muted notification-limit", text: t("The same event about the same thing goes out once per 15 minutes at most, and 12 notifications an hour at most.") }))),
      el("div", { class: "save-bar notification-save" }, line,
        el("button", { actionIcon: "send", text: t("Send a test to every channel that is on"), onclick: () => test() }), save));
  }

  /// This browser's subscription and the others'.
  function browserPanel(settings) {
    const box = el("div", { class: "push" });
    const line = statusLine();
    const others = el("div", {}, settings.subscriptions.map((sub) => el("div", { class: "control" },
      el("span", { text: `${sub.label}${sub.username ? ` · ${sub.username}` : ""}` }),
      el("button", { actionIcon: "trash", class: "link", text: t("Remove"), onclick: async () => {
        try { await app.api(`/api/notifications/push/subscriptions/${encodeURIComponent(sub.id)}`, { method: "DELETE" }); app.route(); } catch (e) { say(line, e.message, "error"); }
      } }))));
    if (!pushSupported()) {
      box.append(el("p", { class: "muted note", text: window.isSecureContext ? t("This browser cannot receive push notifications.") : t("Open this page over HTTPS (the HomeswiftUI block's https) or on localhost to turn them on here.") }), others);
      return box;
    }
    const toggle = el("button", { actionIcon: "restore", text: t("Checking…"), disabled: true });
    const draw = (subscription) => {
      toggle.disabled = false;
      toggle.textContent = subscription ? t("Turn off on this browser") : t("Turn on for this browser");
      toggle.onclick = async () => {
        toggle.disabled = true;
        try {
          if (subscription) {
            await app.api("/api/notifications/push/unsubscribe", { method: "POST", body: { endpoint: subscription.endpoint } });
            await subscription.unsubscribe();
          } else {
            if (await Notification.requestPermission() !== "granted") throw new Error(t("The browser's notifications are blocked for this site."));
            const registration = await navigator.serviceWorker.register("/sw.js");
            await navigator.serviceWorker.ready;
            const { publicKey } = await app.api("/api/notifications/push");
            const created = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(publicKey) });
            await app.api("/api/notifications/push/subscribe", { method: "POST", body: { ...created.toJSON(), label: browserLabel() } });
          }
          app.route();
        } catch (e) { say(line, e.message, "error"); toggle.disabled = false; }
      };
    };
    currentSubscription().then(draw).catch(() => draw(null));
    const testHere = el("button", { actionIcon: "send", class: "link", text: t("Send a test here"), onclick: async () => {
      const subscription = await currentSubscription();
      if (!subscription) return say(line, t("This browser is not subscribed."), "error");
      try {
        const answer = await app.api("/api/notifications/push/test", { method: "POST", body: { endpoint: subscription.endpoint } });
        const result = answer.results[0];
        say(line, result.ok ? t("Sent.") : HomeswiftI18n.message(result.error), result.ok ? "ok" : "error");
      } catch (e) { say(line, e.message, "error"); }
    } });
    box.append(el("div", { class: "actions" }, toggle, testHere), others, line);
    return box;
  }

  // ---- Installing ------------------------------------------------------------------------------------

  window.HomeswiftHome = {
    install(context) {
      app = context;
      app.views.scenes = (main, [id]) => id ? sceneEditor(main, id) : scenesView(main);
      app.views.notifications = notificationsView;
      app.views.quick = async (main) => app.show(main, app.pageHead(t("Quick controls"), t("Your favourite accessories and the scenes, at hand.")), quickSection(null, { standalone: true }));
    },
    layoutActions, moveGroupToRoom, groupByRoom, suggestRooms, quickSection, displayName,
  };
})();
