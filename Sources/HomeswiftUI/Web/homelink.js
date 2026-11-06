// The Home Link on the Accessories page (GLOSSARY.md, "Home Link"): whether the Rooms are Apple Home's, the first
// link's comparison for a person to confirm, and the Zones, Apple Home's sets of Rooms.
(() => {
  const { el, api } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;

  /// What the link says, in a sentence, and how it shows (`tone`: "", "warn" or "error").
  function status(link) {
    if (!link || link.state === "none") {
      return { text: t("These rooms are this bridge's own. Pair Homeswift Wingman to share them with Apple Home."), tone: "" };
    }
    if (link.waiting || link.comparison) return { text: t("Apple Home is ready to share its rooms with this bridge: review what linking changes."), tone: "warn" };
    if (link.state === "up") {
      return link.linked ? { text: t("In step with Apple Home's {home}.", { home: link.home ?? "" }), tone: "" }
        : { text: t("Linking with Apple Home…"), tone: "" };
    }
    if (link.state === "readOnly") return { text: t("Apple Home does not let the bridge change it: {reason}", { reason: link.reason ?? "" }), tone: "warn" };
    return {
      text: link.pending ? tn("Apple Home is not reachable: {n} change waits for it.", "Apple Home is not reachable: {n} changes wait for it.", link.pending)
        : t("Apple Home is not reachable: {reason}", { reason: link.reason ?? "" }),
      tone: "warn",
    };
  }

  function dialogShell(title, ...content) {
    const dialog = el("dialog", { class: "admin-dialog card home-link-dialog", "aria-label": title });
    const form = el("form", { method: "dialog" }, el("h2", { text: title }), ...content);
    dialog.append(form);
    document.body.append(dialog);
    dialog.addEventListener("close", () => dialog.remove(), { once: true });
    return { dialog, form };
  }

  function list(title, items) {
    if (!items?.length) return null;
    return el("section", { class: "home-link-list" }, el("h3", { text: title }), el("ul", {}, items.map((item) => el("li", { text: item }))));
  }

  /// The first link's comparison, to confirm: what linking the bridge to its home in Apple Home changes. `onLinked`
  /// runs once it is linked.
  async function review(onLinked) {
    let link;
    try { link = await api("/api/home-link"); } catch (e) { HomeswiftCommon.showAlert(e.message); return; }
    const comparison = link.comparison;
    if (!comparison) { onLinked?.(); return; }
    const message = el("p", { role: "status", class: "error" });
    const roomName = (room) => room || t("No room");
    const clashes = comparison.clashes ?? [];
    const confirm = el("button", { type: "submit", class: "primary", actionIcon: "link", text: t("Link"), disabled: clashes.length > 0 });
    const { dialog, form } = dialogShell(t("Link with Apple Home"),
      el("p", { text: t("From now on this bridge and Apple Home's {home} keep their rooms, zones and groups in one place. Linking changes this:", { home: comparison.home }) }),
      list(t("Rooms created in Apple Home"), comparison.roomsOnlyHere),
      list(t("Rooms taken from Apple Home"), comparison.roomsOnlyInHome),
      list(t("Accessories that move"), (comparison.accessories ?? []).filter((one) => one.result !== one.here)
        .map((one) => t("{name}: {from} → {to}", { name: one.name, from: roomName(one.here), to: roomName(one.result) }))),
      list(t("Accessories that keep their room and move in Apple Home"), (comparison.accessories ?? []).filter((one) => one.result === one.here)
        .map((one) => t("{name}: {room}", { name: one.name, room: roomName(one.here) }))),
      list(t("Groups created in Apple Home"), comparison.groupsCreated),
      list(t("Groups Apple Home cannot have, ungrouped"), comparison.groupsUngrouped),
      clashes.length ? el("p", { class: "error", text: t("Apple Home would take these rooms for one: rename one of each first. {rooms}", { rooms: clashes.map((names) => names.join(" / ")).join(", ") }) }) : null,
      message,
      el("div", { class: "actions" }, el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => dialog.close() }), confirm));
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      confirm.disabled = true;
      try {
        await api("/api/home-link/confirm", { method: "POST", body: {} });
        dialog.close();
        onLinked?.();
      } catch (e) {
        message.textContent = e.message;
        confirm.disabled = false;
      }
    });
    dialog.showModal();
  }

  /// The Zones: each with its name and Rooms, changed as they are edited; `onClose` runs once the dialog closes after
  /// a change.
  async function zones(rooms, onClose) {
    let current;
    try { current = (await api("/api/zones")).zones; } catch (e) { HomeswiftCommon.showAlert(e.message); return; }
    const message = el("p", { role: "status", class: "error" });
    const body = el("div", { class: "home-link-zones" });
    let changed = false;
    const change = async (request) => {
      message.textContent = "";
      try {
        const answer = await api("/api/zones", { method: "PUT", body: request });
        current = answer.zones;
        const refused = answer.appleHomeRefused ?? [];
        if (refused.length) message.textContent = refused.map((one) => t("Apple Home refused: {reason}", { reason: one.reason })).join("\n");
        changed = true;
        draw();
      } catch (e) { message.textContent = e.message; }
    };
    function draw() {
      body.replaceChildren(...(current.length ? current.map((zone) => {
        const name = el("input", { type: "text", value: zone.name, maxLength: 64, "aria-label": t("Name of {zone}", { zone: zone.name }) });
        name.addEventListener("change", () => { if (name.value.trim() && name.value.trim() !== zone.name) change({ zone: zone.id, name: name.value.trim() }); });
        const boxes = rooms.map((room) => {
          const box = el("input", { type: "checkbox", checked: zone.rooms.includes(room) });
          box.addEventListener("change", () => change({ zone: zone.id, rooms: boxes.filter((one) => one.box.checked).map((one) => one.room) }));
          return { room, box };
        });
        const remove = el("button", { type: "button", class: "icon-button", "aria-label": t("Remove {zone}", { zone: zone.name }), title: t("Remove {zone}", { zone: zone.name }),
          onclick: async () => { if (await HomeswiftCommon.confirmDialog(t("Remove the zone {zone}? Its rooms stay.", { zone: zone.name }))) change({ zone: zone.id, delete: true }); } },
        HomeswiftCommon.icon("trash"));
        return el("fieldset", { class: "home-link-zone" },
          el("legend", { class: "home-link-zone-head" }, name, remove),
          rooms.length ? el("div", { class: "choices" }, boxes.map(({ room, box }) => el("label", { class: "check" }, box, el("span", { text: room }))))
            : el("p", { class: "muted", text: t("No rooms yet.") }));
      }) : [el("p", { class: "muted", text: t("No zones yet. A zone gathers rooms, such as Upstairs; a room can be in several.") })]));
    }
    const add = el("button", { type: "button", actionIcon: "plus", text: t("New zone"), onclick: async () => {
      const name = (await HomeswiftCommon.promptDialog(t("A name for the new zone, such as Upstairs."), ""))?.trim();
      if (name) change({ create: { name, rooms: [] } });
    } });
    const { dialog } = dialogShell(t("Zones"),
      el("p", { class: "muted", text: t("Apple Home's sets of rooms. They change in the Home app too once this bridge is linked to it.") }),
      body, message,
      el("div", { class: "actions" }, add, el("button", { type: "submit", class: "primary", actionIcon: "check", text: t("Done") })));
    dialog.addEventListener("close", () => { if (changed) onClose?.(); }, { once: true });
    draw();
    dialog.showModal();
  }

  window.HomeswiftHomeLink = { status, review, zones };
})();
