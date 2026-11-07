/* Personal photos remain photographs: markers only define animated energy routes. */
window.HomeswiftHouseEditor = function ({ preferences, api, scaledImage, saved }) {
  const { el, icon } = HomeswiftCommon, t = HomeswiftI18n.t;
  const existing = preferences.customHouse;
  let draft = existing ? structuredClone(existing) : { name: "", description: "", markers: {}, width: 0, height: 0 };
  let selected = "solar", data, ready = Boolean(existing), busy = false;
  const roles = [["solar", "Solar panels", "sun"], ["battery", "Battery", "battery"], ["grid", "Electrical board", "pylon"], ["home", "Home", "house"]];
  const status = el("p", { class: "status-line muted", role: "status" });
  const photo = el("img", { alt: t("Your house"), src: existing ? `/api/preferences/house/${encodeURIComponent(existing.version)}` : "" });
  photo.draggable = false;
  const stage = el("div", { class: "house-photo-editor", hidden: !ready }, photo);
  const name = el("input", { type: "text", value: draft.name, maxLength: 80 });
  const description = el("textarea", { value: draft.description, maxLength: 500, rows: 2 });
  const field = (label, input) => el("label", { class: "house-photo-field" }, el("span", { text: t(label) }), input);
  const controls = el("div", { class: "house-marker-choices", role: "group", "aria-label": t("Equipment markers") });
  const buttons = roles.map(([role, label, glyph]) => {
    const button = el("button", { type: "button", actionIcon: glyph, text: t(label), "aria-pressed": String(role === selected), onclick: () => { selected = role; update(); } });
    controls.append(button); return button;
  });
  const horizontal = el("input", { type: "range", min: 0, max: 100, step: 1, "aria-label": t("Horizontal position") });
  const vertical = el("input", { type: "range", min: 0, max: 100, step: 1, "aria-label": t("Vertical position") });
  const positions = el("div", { class: "house-marker-positions" }, field("Horizontal position", horizontal), field("Vertical position", vertical));
  const markerNodes = roles.map(([role, label, glyph]) => {
    const node = el("button", { type: "button", class: `house-photo-marker marker-${role}`, "aria-label": t(label), title: t(label), onclick: event => { event.stopPropagation(); selected = role; update(); } }, icon(glyph));
    let drag = null;
    node.addEventListener("pointerdown", event => {
      if (busy || !ready || !event.isPrimary || event.button !== 0) return;
      event.preventDefault();
      selected = role;
      const box = stage.getBoundingClientRect(), point = draft.markers[role];
      drag = { id: event.pointerId, x: event.clientX - box.left - point[0] * box.width, y: event.clientY - box.top - point[1] * box.height };
      node.setPointerCapture(event.pointerId);
      node.classList.add("dragging");
      node.focus({ preventScroll: true });
      update();
    });
    node.addEventListener("pointermove", event => {
      if (!drag || drag.id !== event.pointerId || busy) return;
      const box = stage.getBoundingClientRect();
      draft.markers[role] = [Math.max(0, Math.min(1, (event.clientX - box.left - drag.x) / box.width)),
        Math.max(0, Math.min(1, (event.clientY - box.top - drag.y) / box.height))];
      update();
    });
    const stopDrag = event => {
      if (!drag || drag.id !== event.pointerId) return;
      drag = null;
      node.classList.remove("dragging");
      if (node.hasPointerCapture(event.pointerId)) node.releasePointerCapture(event.pointerId);
    };
    node.addEventListener("pointerup", stopDrag);
    node.addEventListener("pointercancel", stopDrag);
    node.addEventListener("lostpointercapture", stopDrag);
    stage.append(node); return node;
  });
  const save = el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Save and use photo"), onclick: async () => {
    busy = true; update(); status.textContent = t("Saving…");
    try {
      const result = await api("/api/preferences/house", { method: "PUT", body: { ...draft, name: name.value.trim(), description: description.value.trim(), ...(data ? { data } : {}) } });
      saved(result);
    } catch (error) { status.textContent = error.message; status.className = "status-line error"; busy = false; update(); }
  } });
  const picker = el("input", { type: "file", class: "hidden", accept: "image/jpeg,image/png,image/webp", "aria-label": t("Upload your house photo") });
  const usePhoto = async file => {
    if (!file || busy) return;
    busy = true; update(); status.textContent = t("Preparing the image…");
    try {
      const next = await scaledImage(file);
      if (next.length > 3333336) throw new Error(t("Choose a smaller photo (under 2.5 MB)."));
      const image = new Image(); image.src = `data:image/jpeg;base64,${next}`; await image.decode();
      data = next; photo.src = image.src;
      draft.width = image.naturalWidth; draft.height = image.naturalHeight; draft.markers = {};
      ready = true; selected = "solar"; status.textContent = t("Choose a marker, then tap its position on your photo.");
    } catch (error) { status.textContent = error.message; }
    busy = false; picker.value = ""; update();
  };
  picker.addEventListener("change", () => usePhoto(picker.files?.[0]));
  const drop = el("div", { class: "drop-zone wallpaper-drop", role: "button", tabIndex: 0, "aria-label": t("Upload your house photo") },
    icon("image"), el("span", {}, t("Drop a house photo here, or "), el("strong", { text: t("choose a photo") })));
  drop.addEventListener("click", () => { if (!busy) picker.click(); });
  drop.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); if (!busy) picker.click(); } });
  drop.addEventListener("dragover", event => { event.preventDefault(); if (!busy) drop.classList.add("over"); });
  drop.addEventListener("dragleave", () => drop.classList.remove("over"));
  drop.addEventListener("drop", event => { event.preventDefault(); drop.classList.remove("over"); usePhoto(event.dataTransfer?.files?.[0]); });
  stage.addEventListener("dragstart", event => event.preventDefault());
  stage.addEventListener("click", event => {
    if (busy || !ready) return;
    const box = stage.getBoundingClientRect();
    draft.markers[selected] = [Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)), Math.max(0, Math.min(1, (event.clientY - box.top) / box.height))];
    update();
  });
  [horizontal, vertical].forEach((input, axis) => input.addEventListener("input", () => {
    const point = [...(draft.markers[selected] || [.5, .5])]; point[axis] = Number(input.value) / 100; draft.markers[selected] = point; update();
  }));
  function update() {
    stage.hidden = !ready;
    picker.disabled = busy; drop.setAttribute("aria-disabled", String(busy)); name.disabled = description.disabled = busy;
    save.disabled = busy || !ready || roles.some(([role]) => !draft.markers[role]);
    roles.forEach(([role, label], index) => {
      buttons[index].disabled = busy || !ready;
      buttons[index].setAttribute("aria-pressed", String(selected === role));
      buttons[index].classList.toggle("placed", Boolean(draft.markers[role]));
      const node = markerNodes[index], point = draft.markers[role]; node.hidden = !point; node.disabled = busy;
      if (point) { node.style.left = `${point[0] * 100}%`; node.style.top = `${point[1] * 100}%`; }
    });
    [horizontal, vertical].forEach((input, axis) => { input.disabled = busy || !ready; input.value = Math.round((draft.markers[selected]?.[axis] ?? .5) * 100); });
  }
  const remove = existing ? el("button", { type: "button", actionIcon: "trash", text: t("Remove photo"), onclick: async () => {
    if (!await HomeswiftAdmin.confirmAction({ title: t("Remove your house photo?"), confirmLabel: t("Remove photo"), confirmIcon: "trash" })) return;
    busy = true; remove.disabled = true; update();
    try { saved(await api("/api/preferences/house", { method: "DELETE", body: {} })); }
    catch (error) { status.textContent = error.message; busy = false; remove.disabled = false; update(); }
  } }) : null;
  const use = existing && preferences.energyHouseStyle !== "custom" ? el("button", { type: "button", actionIcon: "house", text: t("Use this photo"), onclick: async () => {
    busy = true; use.disabled = true; update();
    try { saved(await api("/api/preferences", { method: "PUT", body: { energyHouseStyle: "custom" } })); }
    catch (error) { status.textContent = error.message; busy = false; use.disabled = false; update(); }
  } }) : null;
  update();
  return el("section", { class: "card custom-house-card" },
    el("h2", { class: "appearance-card-title" }, icon("house"), el("span", { text: t("Your house") })),
    el("p", { class: "muted", text: t("Use your own photo and place the energy connections. Your photo stays private to your account.") }),
    drop, picker, field("House name", name), field("House details", description),
    el("p", { class: "muted", text: t("Choose a marker, then tap its position on your photo.") }), controls, stage, positions,
    el("p", { class: "muted", text: t("Mark Home where the energy paths should meet. Only connected energy sources appear in the live view.") }),
    el("div", { class: "house-photo-actions" }, save, use, remove), status);
};
