(() => {
  const { t } = HomeswiftI18n;
  const { characteristics, services } = HomeswiftDesignCatalog;
  const { widgets, rowStory } = HomeswiftDesignStories;
  const $ = (id) => document.getElementById(id);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "text") node.textContent = value;
      else if (key.startsWith("aria-") || key.startsWith("data-")) node.setAttribute(key, value);
      else node[key] = value;
    }
    for (const child of children.flat()) if (child) node.append(child);
    return node;
  };
  const foundations = { id: "foundations", kind: "foundation", name: "Foundations", description: "Colour, spacing, type and interaction rules shared by every component." };
  const stories = [foundations, ...widgets, ...characteristics.map((c) => ({ id: `characteristic/${c.id}`, kind: "characteristic", name: c.type, characteristic: c, description: "The production inspector control and the exact HomeKit contract." }))];
  const params = new URLSearchParams(location.search);
  const sizes = ["small", "medium", "large", "xlarge"];
  const sizeNames = { small: t("Small"), medium: t("Medium"), large: t("Large"), xlarge: t("Extra large") };
  let current, accessory, size = sizes.includes(params.get("size")) ? params.get("size") : "xlarge", filter = "all";
  let theme = document.documentElement.dataset.theme;
  const inputs = new Map();
  const language = HomeswiftI18n.language;
  const frame = $("preview");
  frame.src = `frame.html?lang=${language}&theme=${theme}`;
  $("viewport").value = ["fit", "393", "768", "1120"].includes(params.get("viewport")) ? params.get("viewport") : innerWidth < 700 ? "fit" : "393";
  $("state").value = ["normal", "paused", "unavailable", "readonly"].includes(params.get("state")) ? params.get("state") : "normal";
  $("language").value = language;
  document.title = `${t("Design system")} · Homeswift`;
  HomeswiftI18n.translate();
  const short = (one) => ({small: "S", medium: "M", large: "L", xlarge: "XL"})[one];
  function updateURL() {
    const url = new URL(location.href);
    url.searchParams.set("lang", language); url.searchParams.set("size", size);
    url.searchParams.set("viewport", $("viewport").value); url.searchParams.set("state", $("state").value);
    url.hash = current.id; history.replaceState(null, "", url);
  }
  function navigation() {
    const needle = $("search").value.trim().toLocaleLowerCase();
    const matches = stories.filter((story) => (filter === "all" || story.kind === filter) && (!needle || `${HomeswiftI18n.message(story.name)} ${story.name} ${story.id} ${story.characteristic?.uuid || ""} ${story.characteristic?.services.join(" ") || ""}`.toLocaleLowerCase().includes(needle)));
    $("result-count").textContent = `${matches.length} / ${stories.length}`;
    const nav = $("stories"); nav.replaceChildren();
    for (const [kind, label] of [["foundation", t("Foundations")], ["widget", t("Widgets")], ["characteristic", t("Characteristics")]]) {
      const group = matches.filter((one) => one.kind === kind); if (!group.length) continue;
      nav.append(el("h2", { className: "story-group", text: `${label} · ${group.length}` }));
      for (const story of group) nav.append(el("a", { href: `#${story.id}`, className: "story-link", "data-kind": story.kind, "aria-current": current?.id === story.id ? "page" : "false", text: story.kind === "characteristic" ? HomeswiftI18n.message(story.name) : t(story.name) }));
    }
    if (!matches.length) nav.append(el("p", { className: "panel-help", text: t("No matching stories.") }));
  }
  for (const [key, label] of [["all", "All"], ["widget", "Widgets"], ["characteristic", "Characteristics"], ["foundation", "Foundations"]]) {
    const button = el("button", { type: "button", text: t(label), "aria-pressed": String(key === filter) });
    button.onclick = () => { filter = key; for (const node of $("filters").children) node.setAttribute("aria-pressed", String(node === button)); navigation(); };
    $("filters").append(button);
  }
  function event(text) {
    const list = $("events");
    if (list.dataset.empty) { list.replaceChildren(); delete list.dataset.empty; }
    list.prepend(el("li", { text: `${new Date().toLocaleTimeString(HomeswiftI18n.locale)}  ${text}` }));
    while (list.children.length > 30) list.lastElementChild.remove();
  }
  function clearEvents() { $("events").replaceChildren(el("li", { text: t("Interact with the preview to see events.") })); $("events").dataset.empty = "true"; }
  function fixture() { $("fixture").textContent = JSON.stringify(accessory, null, 2); }
  function fitCanvas() {
    const viewport = $("viewport").value;
    const host = frame.parentElement, style = getComputedStyle(host);
    const available = host.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    frame.style.width = `${viewport === "fit" ? Math.max(240, available) : viewport}px`;
  }
  new ResizeObserver(fitCanvas).observe(frame.parentElement);
  function send() {
    if (!accessory) return;
    fitCanvas();
    frame.contentWindow?.postMessage({ type: "design-render", accessory, kind: current.kind, size, state: $("state").value, theme }, location.origin);
    fixture(); updateURL();
  }
  function setSize(one) {
    size = one;
    for (const node of $("size-picker").children) node.setAttribute("aria-pressed", String(node.dataset.size === one));
    send();
  }
  for (const one of sizes) {
    const button = el("button", { type: "button", className: "size-picker-button", "data-size": one, "aria-label": sizeNames[one], title: sizeNames[one], text: short(one), "aria-pressed": String(one === size) });
    button.onclick = () => setSize(one); $("size-picker").append(button);
  }
  function knobs() {
    inputs.clear(); $("knobs").replaceChildren();
    for (const service of accessory.services) for (const c of service.characteristics) {
      if (["tlv8", "data"].includes(c.format)) continue;
      const key = `${service.subtype || service.type}/${c.type}`;
      const label = el("label", { className: "knob" }, el("span", {}, el("span", { text: HomeswiftI18n.message(c.type) }), el("small", { text: `${service.name || service.type} · ${c.format}${c.unit ? ` · ${c.unit}` : ""}` })));
      let input;
      if (c.format === "bool") input = el("input", { type: "checkbox", checked: !!c.value });
      else if (c.validValues) input = el("select", {}, c.validValues.map((value) => el("option", { value: String(value), text: String(value), selected: value === c.value })));
      else input = el("input", { type: c.format === "string" ? "text" : "number", value: c.value ?? "", ...(c.minValue !== undefined ? { min: c.minValue } : {}), ...(c.maxValue !== undefined ? { max: c.maxValue } : {}), ...(c.maxLength !== undefined && c.format === "string" ? { maxLength: c.maxLength } : {}), step: c.minStep || "any" });
      input.setAttribute("aria-label", c.type);
      input.onchange = () => {
        if (!input.reportValidity()) return;
        const value = c.format === "bool" ? input.checked : c.format === "string" ? input.value : Number(input.value);
        c.value = value;
        const change = { service: service.subtype || service.type, characteristic: c.type, value };
        frame.contentWindow.postMessage({ type: "design-value", change }, location.origin);
        fixture(); event(`${t("Simulated reading")}: ${c.type} = ${JSON.stringify(value)}`);
      };
      inputs.set(key, { input, characteristic: c }); label.append(input); $("knobs").append(label);
    }
    if (!inputs.size) $("knobs").append(el("p", { className: "panel-help", text: t("Opaque protocol data has no editable demo value.") }));
  }
  function metadata() {
    const rules = $("rules"), dl = $("metadata"); rules.replaceChildren(); dl.replaceChildren();
    const note = (text) => rules.append(el("p", { className: "rule", text: t(text) }));
    const pair = (key, value) => { dl.append(el("dt", { text: t(key) }), el("dd", { text: String(value) })); };
    if (current.kind === "widget") {
      note("S and M show state and the primary action. L shows the main controls. XL shows expanded controls and fits its content.");
      note("Opening, unlocking and disarming require a deliberate hold. Closing, locking and arming are direct actions.");
      note("An active tile uses a bright surface; unavailable and paused states remain explicit.");
      pair("Primary service", accessory.services[0].type); pair("Characteristics", accessory.services.reduce((n,s) => n + s.characteristics.length, 0));
      pair("Renderer", "HomeswiftWidgets.card");
    } else {
      const c = current.characteristic;
      if (c.protocolOnly) note("Protocol bookkeeping and opaque payloads stay out of everyday controls. No protocol bytes are invented in this preview.");
      else if (!c.permissions.includes("pw")) note("Read-only characteristics show a value with its unit or a named state. The controls panel simulates incoming readings.");
      else if (c.format === "bool") note("Writable booleans use an accessible on/off switch.");
      else if (c.validValues) note("Enumerated values use named choices when available. Unsupported values are not offered.");
      else if (c.minValue !== undefined && c.maxValue !== undefined) note("Bounded numbers use a range input in the inspector. Widgets can promote them to sliders, steps or setpoints.");
      else if (c.format === "string") note("Writable text uses a text field. Changes commit when editing finishes.");
      else note("The inspector shows readable values; write-only commands use a dedicated control when one is available.");
      if (c.unit === "celsius") note("HomeKit stores Celsius. Display values follow the temperature preference.");
      if (c.id === "colorTemperature") note("HomeKit stores mireds. The light widget presents Kelvin.");
      if (["lockTargetState","targetDoorState","securitySystemTargetState"].includes(c.id)) note("The generic inspector confirms security writes. Dedicated widgets use a hold for opening, unlocking and disarming.");
      pair("Identifier", c.id); pair("UUID", c.uuid); pair("Format", c.format); pair("Permissions", c.permissions.join(" · "));
      pair("Range", c.minValue !== undefined || c.maxValue !== undefined ? `${c.minValue ?? "—"} … ${c.maxValue ?? "—"}` : "—");
      pair("Step", c.minStep ?? "—"); if (c.maxLength !== undefined) pair("Maximum length", c.maxLength); pair("Unit", c.unit ?? "—"); pair("Values", c.validValues?.join(", ") ?? "—");
      pair("Services", c.services.map((id) => services.find((one) => one.id === id)?.name).join(", ") || "—");
      pair("Renderer", "HomeswiftWidgets.characteristicRow");
    }
  }
  function tokens() {
    const host = $("foundations"); host.replaceChildren();
    const panel = el("section", { className: "story-panel" }, el("h2", { text: t("Colour & materials") }));
    const grid = el("div", { className: "token-grid" });
    for (const [name, token] of [["Accent","--accent"],["Text","--text"],["Secondary text","--muted"],["Surface","--material"],["Success","--ok"],["Warning","--warn"],["Error","--error"],["Active tile","--tile-on"]]) {
      const swatch = el("div", { className: "token-swatch" }); swatch.style.background = `var(${token})`;
      grid.append(el("div", { className: "token-card" }, swatch, el("strong", { text: t(name) }), el("code", { text: token })));
    }
    panel.append(grid);host.append(panel);
    for (const [name,text] of [["Layout","Columns start at 176 px; phones keep two columns. Compact rows are at least 64 px with a 10 px gap. L and XL fit whole rows to their controls."],["Type & shape","System type, a 22 px accessory radius, 40 px summary icons, and a clear name/status hierarchy."],["Interaction","Keyboard focus, named controls, deliberate security actions and reduced-motion support are part of the component contract."]]) host.append(el("section",{className:"story-panel"},el("h2",{text:t(name)}),el("p",{className:"rule",text:t(text)})));
  }
  function select() {
    let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch { id = ""; }
    current = stories.find((one) => one.id === id) || widgets[0];
    $("eyebrow").textContent = t(current.kind === "widget" ? "Widgets" : current.kind === "characteristic" ? "Characteristics" : "Foundations");
    $("story-title").textContent = current.kind === "characteristic" ? HomeswiftI18n.message(current.name) : t(current.name);
    $("story-description").textContent = t(current.description);
    $("foundations").classList.toggle("hidden", current.kind !== "foundation");
    $("component-story").classList.toggle("hidden", current.kind === "foundation");
    $("size-picker").classList.toggle("hidden", current.kind !== "widget");
    clearEvents(); navigation();
    if (current.kind === "foundation") { accessory = null; tokens(); updateURL(); return; }
    accessory = current.kind === "widget" ? current.build() : rowStory(current.characteristic.id);
    knobs(); metadata(); send();
  }
  addEventListener("message", (eventMessage) => {
    if (eventMessage.origin !== location.origin || eventMessage.source !== frame.contentWindow) return;
    const data = eventMessage.data;
    if (data?.type === "design-ready") send();
    if (data?.type === "design-height") frame.style.height = `${Math.min(1000, Math.max(220, data.height))}px`;
    if (data?.type === "design-size" && sizes.includes(data.size)) setSize(data.size);
    if (data?.type === "design-action") {
      if (data.error) { event(`${t("Rejected")}: ${t(data.error)}`); return; }
      for (const change of data.changes || []) {
        const target = inputs.get(`${change.service}/${change.characteristic}`);
        if (target) { target.characteristic.value = change.value; if (target.input.type === "checkbox") target.input.checked = !!change.value; else target.input.value = String(change.value); }
        event(`${change.characteristic} = ${JSON.stringify(change.value)}`);
      }
      fixture();
    }
  });
  frame.onload = send;
  $("search").oninput = navigation;
  $("viewport").onchange = send; $("state").onchange = send;
  $("reset").onclick = select; $("clear-events").onclick = clearEvents;
  $("copy-link").onclick = async () => { updateURL(); try { await navigator.clipboard.writeText(location.href); $("copy-link").textContent = t("Copied"); } catch { event(location.href); } };
  $("theme").onclick = () => { theme = theme === "dark" ? "light" : "dark"; document.documentElement.dataset.theme = theme; localStorage.setItem("homeswift.design.theme",theme); $("theme").textContent = t(theme === "dark" ? "Light mode" : "Dark mode"); frame.contentWindow.postMessage({type:"design-theme",theme},location.origin); if(current.kind === "foundation")tokens(); };
  $("theme").textContent = t(theme === "dark" ? "Light mode" : "Dark mode");
  $("language").onchange = () => { const url = new URL(location.href); url.searchParams.set("lang",$("language").value); localStorage.setItem("homeswift.design.language",$("language").value); location.href=url; };
  addEventListener("hashchange", select);
  select();
})();
