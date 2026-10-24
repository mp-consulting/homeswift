// Accessory widgets, for the Accessories page and plugin pages: each accessory drawn by the widget of its kind,
// chosen from its primary service (an air conditioner's gauge and modes, a light's brightness and colours, a
// shutter's tile, a gate held to open), all built from the same few controls. The services an accessory links
// to its main one become the widget's facets (chips, readouts, meters), and what no widget shows stays
// reachable under More, as rows. On the wall a widget is a fixed box: small (1×1, a tile a tap acts on), medium
// (2×1, its main control) or large (2×2); its ⋯ menu opens every control in a sheet. Loaded after common.js,
// remote.js and camera.js.
//
//   HomeswiftWidgets.card(accessory, { size, actions })   an accessory of /api/accessories at a size
//   HomeswiftWidgets.open(accessory, { actions })         every control of it, in a sheet
//   HomeswiftWidgets.kindOf(accessory)                    { kind, size }: its kind of widget and that kind's size
//   HomeswiftWidgets.event(event)                         an "accessory" event of /api/events, for the cards shown
//   HomeswiftWidgets.listen()                             a plugin page's own event stream, for its cards
(() => {
  "use strict";

  const { el, menuButton, api } = HomeswiftCommon;

  // ---- Values -------------------------------------------------------------------------------------------

  const enumLabels = {
    "Lock Target State": ["Unsecured", "Secured"], "Lock Current State": ["Unsecured", "Secured", "Jammed", "Unknown"],
    "Target Door State": ["Open", "Closed"], "Current Door State": ["Open", "Closed", "Opening", "Closing", "Stopped"],
    "Security System Target State": ["Home", "Away", "Night", "Off"], "Security System Current State": ["Home", "Away", "Night", "Off", "Alarm"],
    "Active": ["Inactive", "Active"], "Target Heating Cooling State": ["Off", "Heat", "Cool", "Auto"], "Current Heating Cooling State": ["Off", "Heating", "Cooling"],
    "Target Heater-Cooler State": ["Auto", "Heat", "Cool"], "Current Heater-Cooler State": ["Inactive", "Idle", "Heating", "Cooling"],
    "Target Fan State": ["Manual", "Auto"], "Current Fan State": ["Inactive", "Idle", "Blowing"], "Rotation Direction": ["Clockwise", "Counter-clockwise"],
    "Swing Mode": ["Disabled", "Enabled"], "Programmable Switch Event": ["Single press", "Double press", "Long press"],
    "Contact Sensor State": ["Contact", "No contact"], "Temperature Display Units": ["Celsius", "Fahrenheit"],
    "Air Quality": ["Unknown", "Excellent", "Good", "Fair", "Inferior", "Poor"], "Charging State": ["Not charging", "Charging", "Not chargeable"],
    "Status Low Battery": ["Normal", "Low"], "Leak Detected": ["Dry", "Leak"], "Smoke Detected": ["Clear", "Smoke"], "Carbon Monoxide Detected": ["Normal", "Abnormal"],
    "Carbon Dioxide Detected": ["Normal", "Abnormal"], "Target Air Purifier State": ["Manual", "Auto"], "Current Air Purifier State": ["Inactive", "Idle", "Purifying"],
    "Motion Detected": ["No motion", "Motion"], "Occupancy Detected": ["Not occupied", "Occupied"], "Mute": ["Off", "On"],
    "Position State": ["Closing", "Opening", "Stopped"], "Filter Change Indication": ["OK", "Replace"], "In Use": ["Not in use", "In use"],
    "Lock Physical Controls": ["Unlocked", "Locked"], "Valve Type": ["Valve", "Irrigation", "Shower head", "Faucet"],
  };
  // What HomeKit needs to describe an accessory rather than a state a person reads or changes: kept off the page.
  const plumbing = new Set([
    "Name", "Configured Name", "Identifier", "Is Configured", "Current Visibility State", "Target Visibility State", "Input Source Type",
    "Input Device Type", "Sleep Discovery Mode", "Display Order", "Closed Captions", "Picture Mode", "Power Mode Selection",
    "Volume Control Type", "Current Media State", "Target Media State", "Version",
    // Adaptive Lighting's bookkeeping.
    "Characteristic Value Active Transition Count", "Characteristic Value Transition Control", "Supported Characteristic Value Transition Configuration",
  ]);
  // Inputs are chosen with the Input picker; the protocol version is HomeKit's business.
  const quietServices = new Set(["InputSource", "ProtocolInformation"]);
  // On and off as 1 and 0.
  const numericSwitches = new Set(["HomeKit Camera Active"]);
  const rowLabels = {
    "Active Identifier": "Input", "Remote Key": "Remote", "Volume Selector": "Volume",
    "HomeKit Camera Active": "On in the Home app", "Camera Operating Mode Indicator": "Status light",
  };

  const serviceKey = (service) => service.subtype || service.type;
  /// "Color Temperature" reads "Color temperature".
  const sentence = (type) => type.charAt(0) + type.slice(1).toLowerCase();
  /// The text for an enumerated value, or the value itself.
  function labelFor(type, value) {
    const labels = enumLabels[type];
    // Motion Detected and the like are booleans whose labels are listed for 0 and 1.
    const index = typeof value === "boolean" ? Number(value) : value;
    return labels && labels[index] !== undefined ? labels[index] : String(value);
  }
  const units = { percentage: " %", lux: " lx", seconds: " s", arcdegrees: "°" };
  // Temperatures in the unit the user chose (Appearance); HomeKit's values stay in °C.
  const unit = (characteristic) => characteristic.unit === "celsius" ? ` ${HomeswiftCommon.temperature(0).unit}` : units[characteristic.unit] || "";
  /// A value with its characteristic's unit, a temperature converted to the user's unit.
  const withUnit = (value, characteristic) =>
    characteristic.unit === "celsius" && typeof value === "number" ? HomeswiftCommon.formatTemperature(value) : `${value}${unit(characteristic)}`;
  function formatValue(characteristic) {
    if (characteristic.format === "bool") return characteristic.value ? "On" : "Off";
    if (characteristic.value === null || characteristic.value === undefined) return "";
    return withUnit(characteristic.value, characteristic);
  }
  const canWrite = (characteristic) => !!characteristic && characteristic.permissions.includes("pw");
  const canRead = (characteristic) => !!characteristic && characteristic.permissions.includes("pr");
  const isOn = (characteristic) => characteristic?.value === true || characteristic?.value === 1;
  const numberOf = (characteristic, fallback = 0) => typeof characteristic?.value === "number" ? characteristic.value : fallback;
  /// On and off in the characteristic's own format: a bool, or 1 and 0 (Active).
  const onValue = (characteristic, on) => characteristic.format === "bool" ? on : on ? 1 : 0;
  /// The positions of a range when there are only a few (a fan's speeds in steps of 20), else Infinity.
  function positions(characteristic) {
    const { minValue: min, maxValue: max, minStep: step } = characteristic;
    return min === undefined || max === undefined || !step ? Infinity : Math.round((max - min) / step);
  }
  /// A temperature (HomeKit's °C) in the user's unit, as the dials show it: "21.5°".
  const degrees = (celsius) => { const { value } = HomeswiftCommon.temperature(celsius); return `${Number.isInteger(value) ? value : value.toFixed(1)}°`; };
  const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(Math.max(0, Math.round(seconds % 60))).padStart(2, "0")}`;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  /// A colour temperature in mireds (what HomeKit sends) in kelvin, to the nearest 50.
  const kelvin = (mireds) => Math.round(1e6 / mireds / 50) * 50;
  /// About the colour of white light at `k` kelvin, for a tile and the temperature track.
  function whiteColor(k, lightness = 70) {
    const t = clamp((k - 2700) / (6500 - 2700), 0, 1);
    return `hsl(${Math.round(32 + t * 178)} ${Math.round(90 - t * 70)}% ${lightness}%)`;
  }

  function describeModel(accessory) {
    const manufacturer = accessory.manufacturer || "";
    const model = accessory.model || "";
    return model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : `${manufacturer} ${model}`.trim();
  }

  /// A service's name inside its accessory's card: "Living Room TV HDMI 1" reads "HDMI 1" in the Living Room TV's
  /// card; a service named like its accessory reads as its subtype ("climateControl:indoor_silent_mode" is "Indoor
  /// silent mode"), else as its type.
  function shortName(accessory, service) {
    const name = service.name;
    if (name && name !== accessory.name) return name.startsWith(`${accessory.name} `) ? name.slice(accessory.name.length + 1) : name;
    const words = (text) => text.replace(/([a-z])([A-Z0-9])/g, "$1 $2").replace(/[_-]+/g, " ").trim();
    if (service.subtype) {
      const parts = service.subtype.split(/[.:/]/).filter((part) => part && !/^[0-9a-f]{12,}$/i.test(part));
      const last = parts[parts.length - 1];
      if (last) return sentence(words(last));
    }
    return words(service.type);
  }

  // ---- An accessory on the page: its values, writes and painters --------------------------------------

  const cards = new Set();

  function context(accessory, options = {}) {
    const services = accessory.services.filter((service) => !service.internal);
    const ctx = {
      accessory, services, options,
      used: new Set(),       // the characteristics a widget shows; the rest go under More
      painters: [],
      born: Date.now(), node: null,
    };
    ctx.find = (type) => services.find((service) => service.type === type);
    ctx.all = (type) => services.filter((service) => service.type === type);
    ctx.char = (service, type) => service?.characteristics.find((characteristic) => characteristic.type === type);
    /// Marks characteristics as shown; answers the first.
    ctx.use = (...characteristics) => { for (const c of characteristics) if (c) ctx.used.add(c); return characteristics[0]; };
    ctx.take = (service, type) => ctx.use(ctx.char(service, type));
    ctx.useAll = (service) => service.characteristics.forEach((c) => ctx.used.add(c));
    /// Runs `paint` now and after every change of a value of this accessory.
    ctx.watch = (paint) => { ctx.painters.push(paint); paint(); };
    ctx.paint = () => { for (const paint of ctx.painters) paint(); };
    /// Writes at once on the page (the controls and the status follow), then to the device; a refusal puts the
    /// value back and says why in the status line. A security control (a lock, a door, an alarm, what a plugin
    /// marked) asks first unless the control was held to confirm (`held`).
    ctx.write = async (service, characteristic, value, { held = false } = {}) => {
      // A paused plugin's accessory answers nothing: say so rather than ask.
      if (accessory.paused) { ctx.flash(`${accessory.platformName ?? "Its plugin"} is paused: resume it to control ${accessory.name}`); return; }
      if (characteristic.security && !held) {
        const label = characteristic.format === "bool" ? (value ? "On" : "Off") : labelFor(characteristic.type, value);
        if (!confirm(`Set ${sentence(characteristic.type).toLowerCase()} of ${accessory.name} to ${label}?`)) { ctx.paint(); return; }
      }
      const before = characteristic.value;
      characteristic.value = value;
      ctx.paint();
      try {
        await put(service, characteristic, value);
      } catch (e) {
        if (e.message === "signed out") return;
        characteristic.value = before;
        ctx.flash(e.message);
      }
    };
    /// A write with no value to keep (a remote's key): its failure is the caller's to show.
    ctx.send = (service, characteristic, value) => put(service, characteristic, value);
    const put = (service, characteristic, value) => api(`/api/accessories/${encodeURIComponent(accessory.id)}`, {
      method: "PUT", body: { service: serviceKey(service), characteristic: characteristic.type, value } });
    ctx.flashing = null;
    ctx.flash = (text) => {
      clearTimeout(ctx.flashTimer);
      ctx.flashing = text;
      ctx.paint();
      ctx.flashTimer = setTimeout(() => { ctx.flashing = null; ctx.paint(); }, 5000);
    };
    return ctx;
  }

  /// Lets go of the cards no longer on the page (the view changed, the wall was drawn again); a new one may not be
  /// attached yet. Run as cards are made too, so a quiet home, with no events, does not keep every wall drawn.
  let swept = 0;
  function sweep(now = Date.now()) {
    swept = now;
    for (const ctx of cards) if (!ctx.node?.isConnected && now - ctx.born > 2000) cards.delete(ctx);
  }

  /// An accessory event from the page's event stream: the new value, painted on the cards of that accessory.
  function event({ id, service, subtype, characteristic, value }) {
    if (Date.now() - swept > 1000) sweep();
    for (const ctx of cards) {
      if (!ctx.node?.isConnected) continue;
      if (ctx.accessory.id !== id) continue;
      const key = subtype || service;
      const owner = ctx.accessory.services.find((s) => (!key || serviceKey(s) === key) && s.characteristics.some((c) => c.type === characteristic));
      const target = owner && owner.characteristics.find((c) => c.type === characteristic);
      if (!target) continue;
      target.value = value;
      ctx.paint();
    }
  }

  /// For a plugin page: the bridge's events, so the cards it shows follow the devices.
  let stream = null;
  function listen() {
    if (stream) return;
    stream = new EventSource("/api/events");
    stream.addEventListener("accessory", (message) => {
      const data = JSON.parse(message.data);
      window.HomeswiftCamera?.event(data);
      event(data);
    });
  }

  // ---- Controls -----------------------------------------------------------------------------------------
  // Each answers its node and set(), which shows a value without calling back; a control being changed by
  // the pointer keeps what the pointer says until it is let go.

  function toggle(label, onChange) {
    const input = el("input", { type: "checkbox", "aria-label": label });
    input.addEventListener("change", () => onChange(input.checked));
    return { node: el("label", { class: "switch" }, input, el("span")), set: (on) => { input.checked = on; } };
  }

  /// Two to four choices side by side, a thumb sliding to the one chosen; the arrow keys move it.
  function segmented(options, label, onChange) {
    const thumb = el("span", { class: "seg-thumb", "aria-hidden": "true" });
    const node = el("div", { class: "seg", role: "radiogroup", "aria-label": label }, thumb);
    node.style.setProperty("--n", options.length);
    const buttons = options.map((option, index) => {
      const button = el("button", { type: "button", role: "radio", text: option.label, onclick: () => choose(index) });
      button.addEventListener("keydown", (event) => {
        const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        const next = (index + step + options.length) % options.length;
        choose(next);
        buttons[next].focus();
      });
      return button;
    });
    node.append(...buttons);
    let current = -1;
    function show(index) {
      current = index;
      node.classList.toggle("unset", index < 0);
      node.style.setProperty("--i", Math.max(0, index));
      buttons.forEach((button, i) => { button.setAttribute("aria-checked", String(i === index)); button.tabIndex = i === Math.max(0, index) ? 0 : -1; });
    }
    function choose(index) { if (index === current) return; show(index); onChange(options[index].value); }
    show(-1);
    return { node, set: (value) => show(options.findIndex((option) => option.value === value)) };
  }

  /// A level: a pill whose fill (or, with `gradient`, a mark on the gradient) follows the pointer one to one;
  /// `onCommit` runs when it is let go, and after a pause in the arrow keys. `vertical`: a tall one, filled from
  /// the bottom, as the Home app's brightness.
  function level({ label, min, max, step = 1, format, gradient, fill, thin = false, showLabel = true, vertical = false }, onCommit) {
    const node = el("div", { class: `level${gradient ? " track" : ""}${thin ? " thin" : ""}${vertical ? " vertical" : ""}`, role: "slider", tabIndex: 0,
      "aria-label": label, "aria-valuemin": min, "aria-valuemax": max, "aria-orientation": vertical ? "vertical" : null });
    if (gradient) node.style.setProperty("--track", gradient);
    if (fill) node.style.setProperty("--fill", fill);
    const bar = gradient ? el("span", { class: "level-mark" }) : el("span", { class: "level-fill" });
    const text = el("span", { class: "level-text" });
    // append() writes a null as the text "null": "" when there is no label.
    node.append(bar, showLabel ? el("span", { class: "level-label", text: label }) : "", text);
    let value = min, dragging = false, keyTimer = null;
    function show(next) {
      value = clamp(Math.round((next - min) / step) * step + min, min, max);
      const share = max > min ? (value - min) / (max - min) : 0;
      if (gradient && vertical) bar.style.top = `calc(100% - 10px - ${share} * (100% - 20px))`;
      else if (gradient) bar.style.left = `calc(10px + ${share} * (100% - 20px))`;
      else bar.style.transform = vertical ? `scaleY(${share})` : `scaleX(${share})`;
      text.textContent = format(value);
      node.setAttribute("aria-valuenow", value);
      node.setAttribute("aria-valuetext", format(value));
    }
    const at = (event) => {
      const box = node.getBoundingClientRect();
      const share = vertical ? 1 - (event.clientY - box.top) / box.height : (event.clientX - box.left) / box.width;
      return min + clamp(share, 0, 1) * (max - min);
    };
    node.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      dragging = true;
      node.setPointerCapture(event.pointerId);
      node.classList.add("dragging");
      show(at(event));
    });
    node.addEventListener("pointermove", (event) => { if (dragging) show(at(event)); });
    const end = () => { if (!dragging) return; dragging = false; node.classList.remove("dragging"); onCommit(value); };
    node.addEventListener("pointerup", end);
    node.addEventListener("pointercancel", end);
    node.addEventListener("keydown", (event) => {
      const big = Math.max(step, (max - min) / 10);
      const delta = { ArrowRight: step, ArrowUp: step, ArrowLeft: -step, ArrowDown: -step, PageUp: big, PageDown: -big }[event.key];
      if (delta === undefined && event.key !== "Home" && event.key !== "End") return;
      event.preventDefault();
      show(delta === undefined ? (event.key === "Home" ? min : max) : value + delta);
      clearTimeout(keyTimer);
      keyTimer = setTimeout(() => { keyTimer = null; onCommit(value); }, 350);
    });
    show(min);
    return { node, set: (next) => { if (!dragging && !keyTimer) show(next); } };
  }

  /// A few positions as rising bars, as a fan's speeds read: the bar pressed and those under it lit.
  function steps({ label, count }, onChange) {
    const node = el("div", { class: "steps", role: "radiogroup", "aria-label": label });
    const bars = Array.from({ length: count }, (_, index) => {
      const bar = el("button", { type: "button", role: "radio", "aria-label": `${label} ${index + 1} of ${count}`, onclick: () => { show(index + 1); onChange(index + 1); } });
      bar.style.height = `${Math.round(38 + (62 * (index + 1)) / count)}%`;
      return bar;
    });
    node.append(...bars);
    function show(n) {
      bars.forEach((bar, index) => {
        bar.classList.toggle("lit", index < n);
        bar.setAttribute("aria-checked", String(index + 1 === n));
        bar.tabIndex = index + 1 === Math.max(1, n) ? 0 : -1;
      });
    }
    node.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const current = bars.filter((bar) => bar.classList.contains("lit")).length;
      const next = clamp(current + step, 1, count);
      show(next); bars[next - 1].focus(); onChange(next);
    });
    return { node, set: show };
  }

  /// A temperature to reach: − the value +, written after a pause so a few presses make one write.
  function setpoint({ label, min, max, step }, onChange) {
    let value = min, timer = null;
    const number = el("b");
    const caption = el("span", { text: label });
    const show = (next) => { value = clamp(Math.round(next / step) * step, min, max); number.textContent = degrees(+value.toFixed(2)); };
    const bump = (delta) => {
      show(value + delta);
      clearTimeout(timer);
      timer = setTimeout(() => { timer = null; onChange(value); }, 600);
    };
    const round = (glyph, text, delta) => el("button", { type: "button", class: "round", "aria-label": `${text} ${label.toLowerCase()}`, onclick: () => bump(delta) }, icon(glyph));
    const node = el("div", { class: "setpoint" }, round("minus", "Lower", -step), el("div", { class: "sp-value", "aria-live": "polite" }, number, caption), round("plus", "Raise", step));
    return { node, set: (next) => { if (!timer) show(next); } };
  }

  /// A 240° arc from `min` to `max`: the reading as a dot, a target as a tick, the band between them in the mode's colour.
  function gauge({ min, max }) {
    const cx = 100, cy = 96, r = 80, start = 150, sweep = 240;
    const angle = (value) => start + sweep * clamp((value - min) / (max - min), 0, 1);
    const point = (deg, radius = r) => [cx + radius * Math.cos((deg * Math.PI) / 180), cy + radius * Math.sin((deg * Math.PI) / 180)];
    const arc = (a, b) => {
      const [x1, y1] = point(a), [x2, y2] = point(b);
      return `M${x1.toFixed(2)} ${y1.toFixed(2)} A${r} ${r} 0 ${b - a > 180 ? 1 : 0} 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`;
    };
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 200 172");
    svg.setAttribute("class", "gauge");
    svg.setAttribute("role", "img");
    const [left] = point(start), [right] = point(start + sweep);
    svg.innerHTML = `<path class="gauge-track" d="${arc(start, start + sweep)}"/><path class="gauge-band"/><line class="gauge-target"/><circle class="gauge-dot" r="7"/>`
      + `<text class="gauge-value" x="100" y="104" text-anchor="middle"></text><text class="gauge-caption" x="100" y="128" text-anchor="middle"></text>`
      + `<text class="gauge-end" x="${left.toFixed(0)}" y="168" text-anchor="middle">${degrees(min)}</text><text class="gauge-end" x="${right.toFixed(0)}" y="168" text-anchor="middle">${degrees(max)}</text>`;
    const band = svg.querySelector(".gauge-band"), tick = svg.querySelector(".gauge-target"), dot = svg.querySelector(".gauge-dot");
    const [valueText, captionText] = svg.querySelectorAll("text");
    function update({ value, from, to, color, caption }) {
      const known = typeof value === "number";
      dot.style.display = known ? "" : "none";
      if (known) { const [x, y] = point(angle(value)); dot.setAttribute("cx", x.toFixed(2)); dot.setAttribute("cy", y.toFixed(2)); }
      valueText.textContent = known ? degrees(+value.toFixed(1)) : "–";
      captionText.textContent = caption;
      const banded = typeof from === "number" && typeof to === "number";
      const a = banded ? angle(Math.min(from, to)) : 0, b = banded ? angle(Math.max(from, to)) : 0;
      band.setAttribute("d", banded && b - a >= 0.5 ? arc(a, b) : "");
      band.style.stroke = color || "";
      tick.style.display = typeof to === "number" ? "" : "none";
      if (typeof to === "number") {
        const [x1, y1] = point(angle(to), r - 13), [x2, y2] = point(angle(to), r + 13);
        tick.setAttribute("x1", x1.toFixed(2)); tick.setAttribute("y1", y1.toFixed(2)); tick.setAttribute("x2", x2.toFixed(2)); tick.setAttribute("y2", y2.toFixed(2));
      }
      svg.setAttribute("aria-label", known ? `${caption}: ${degrees(+value.toFixed(1))}` : caption);
    }
    return { node: svg, update };
  }

  /// A value read, not changed: big, its unit small, its label under it.
  function readout(label) {
    const number = el("b"), small = el("small"), extra = el("span", { class: "readout-extra" });
    const node = el("div", { class: "readout" }, el("span", { class: "readout-value" }, number, small), el("span", { class: "readout-label", text: label }), extra);
    return {
      node,
      set(text, unitText = "", tone = "", scale = null) {
        number.textContent = text;
        small.textContent = unitText;
        node.dataset.tone = tone;
        // A level out of five (air quality) as five short bars.
        extra.replaceChildren(...(scale ? Array.from({ length: 5 }, (_, i) => el("i", { class: i < scale ? "lit" : "" })) : []));
      },
    };
  }

  /// A level that wears down: a filter's life, a battery. Amber under 10 %.
  function meter(label) {
    const amount = el("b"), fillBar = el("i");
    const node = el("div", { class: "meter", role: "meter", "aria-label": label, "aria-valuemin": 0, "aria-valuemax": 100 },
      el("div", { class: "meter-row" }, el("span", { text: label }), amount), el("div", { class: "meter-bar" }, fillBar));
    return {
      node,
      set(percent) {
        amount.textContent = `${percent} %`;
        fillBar.style.transform = `scaleX(${clamp(percent, 0, 100) / 100})`;
        node.classList.toggle("low", percent < 10);
        node.setAttribute("aria-valuenow", percent);
      },
    };
  }

  /// A secondary on/off service, pressed or not.
  function chip(label, onChange) {
    const node = el("button", { type: "button", class: "chip", text: label, "aria-pressed": "false" });
    node.addEventListener("click", () => {
      const on = node.getAttribute("aria-pressed") !== "true";
      node.setAttribute("aria-pressed", String(on));
      onChange(on);
    });
    return { node, set: (on) => node.setAttribute("aria-pressed", String(on)) };
  }

  /// A security write (unlock, open, disarm): held for a moment, the fill running across; let go early and
  /// nothing happens. Space and Enter hold it from the keyboard. The fill's transition in style.css lasts as long.
  const HOLD_MS = 900;
  function hold(label, onConfirm) {
    const text = el("span", { text: label });
    const fillText = el("span", { class: "hold-fill", "aria-hidden": "true", text: label });
    const node = el("button", { type: "button", class: "hold" }, text, fillText);
    // A timer decides, the fill only shows it: a transition does not run in a hidden tab.
    let timer = null;
    const start = () => {
      if (timer) return;
      node.classList.add("holding");
      timer = setTimeout(() => { cancel(); onConfirm(); }, HOLD_MS);
    };
    const cancel = () => { clearTimeout(timer); timer = null; node.classList.remove("holding"); };
    node.addEventListener("pointerdown", (event) => { if (event.button === 0) { node.setPointerCapture(event.pointerId); start(); } });
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) node.addEventListener(type, cancel);
    node.addEventListener("keydown", (event) => { if ((event.key === " " || event.key === "Enter") && !event.repeat) { event.preventDefault(); start(); } });
    node.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") cancel(); });
    node.addEventListener("click", (event) => event.preventDefault());
    const name = (next) => { text.textContent = next; fillText.textContent = next; node.setAttribute("aria-label", `${next} (press and hold)`); };
    name(label);
    return { node, label: name };
  }

  const pill = (text = "", tone = "") => el("span", { class: `pill ${tone}`.trim(), text });

  const glyphs = {
    minus: '<path d="M6 12h12"/>', plus: '<path d="M12 6v12M6 12h12"/>',
    blind: '<rect x="4" y="3" width="16" height="18" rx="1.5"/><path d="M4 8h16M4 12h16M12 12v5"/>',
    drop: '<path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z"/>',
    gate: '<path d="M3 21V9l9-5 9 5v12M7 21v-8h10v8M7 17h10"/>',
    wind: '<path d="M3 8h11a3 3 0 1 0-3-3M3 12h16a3 3 0 1 1-3 3M3 16h8"/>',
    shield: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/>',
    tv: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    up: '<path d="m6 15 6-6 6 6"/>', down: '<path d="m6 9 6 6 6-6"/>', stop: '<rect x="7" y="7" width="10" height="10" rx="2"/>',
    power: '<path d="M12 3v9"/><path d="M6.3 7.2a8 8 0 1 0 11.4 0"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>', mute: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m16 9 5 6M21 9l-5 6"/>',
  };
  /// One of these glyphs, else one of common.js's icons.
  function icon(name) {
    if (!glyphs[name]) return HomeswiftCommon.icon(name);
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = glyphs[name];
    return svg;
  }

  // ---- Rows: a characteristic as a labelled control, for what no widget draws --------------------------

  const remoteKeys = [["←", 6, "Left"], ["↑", 4, "Up"], ["↓", 5, "Down"], ["→", 7, "Right"], ["Select", 8], ["Back", 9], ["Play/Pause", 11], ["Info", 15]];

  function controlFor(ctx, service, characteristic) {
    const writable = canWrite(characteristic), readable = canRead(characteristic);
    const labels = enumLabels[characteristic.type];
    const write = (value) => ctx.write(service, characteristic, value);
    if (writable && (characteristic.format === "bool" || numericSwitches.has(characteristic.type))) {
      const control = toggle(`${ctx.accessory.name}: ${sentence(characteristic.type)}`, (on) => write(onValue(characteristic, on)));
      ctx.watch(() => control.set(isOn(characteristic)));
      return control.node;
    }
    if (writable && characteristic.type === "Active Identifier") return inputPicker(ctx, service, characteristic);
    if (writable && !readable && characteristic.type === "Remote Key") {
      return el("div", { class: "keys" }, remoteKeys.map(([text, value, label]) => el("button", { text, "aria-label": label || text, onclick: () => ctx.send(service, characteristic, value).catch((e) => ctx.flash(e.message)) })));
    }
    if (writable && !readable && characteristic.type === "Volume Selector") {
      const send = (value) => ctx.send(service, characteristic, value).catch((e) => ctx.flash(e.message));
      return el("div", { class: "group" }, el("button", { text: "−", "aria-label": "Volume down", onclick: () => send(1) }), el("button", { text: "+", "aria-label": "Volume up", onclick: () => send(0) }));
    }
    if (writable && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      const select = el("select", { "aria-label": sentence(characteristic.type) }, values.map((value) => el("option", { value, text: labelFor(characteristic.type, value) })));
      select.addEventListener("change", () => write(Number(select.value)));
      ctx.watch(() => { if (document.activeElement !== select) select.value = String(characteristic.value); });
      return select;
    }
    if (writable && ["int", "uint8", "uint16", "uint32", "uint64", "float"].includes(characteristic.format) && characteristic.minValue !== undefined && characteristic.maxValue !== undefined) {
      const input = el("input", { type: "range", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || 1, "aria-label": sentence(characteristic.type) });
      const value = el("span", { class: "value" });
      let timer = null;
      input.addEventListener("input", () => {
        value.textContent = withUnit(Number(input.value), characteristic);
        clearTimeout(timer);
        timer = setTimeout(() => { timer = null; write(Number(input.value)); }, 250);
      });
      ctx.watch(() => { if (!timer) { input.value = characteristic.value ?? 0; value.textContent = formatValue(characteristic); } });
      return el("span", { class: "range" }, input, value);
    }
    if (writable && characteristic.format === "string") {
      const input = el("input", { type: "text", "aria-label": sentence(characteristic.type) });
      input.addEventListener("change", () => write(input.value));
      ctx.watch(() => { if (document.activeElement !== input) input.value = characteristic.value ?? ""; });
      return input;
    }
    if (!readable) return null;
    const text = el("span", { class: "value" });
    ctx.watch(() => { text.textContent = labels ? labelFor(characteristic.type, characteristic.value) : formatValue(characteristic); });
    return text;
  }

  /// The TV's input picker: the input services' identifiers under their names.
  function inputPicker(ctx, service, characteristic) {
    const inputs = ctx.accessory.services.filter((s) => s.type === "InputSource").map((s) => {
      const value = (type) => s.characteristics.find((c) => c.type === type)?.value;
      return { identifier: value("Identifier"), name: value("Configured Name") || s.name, hidden: value("Current Visibility State") === 1 };
    }).filter((input) => input.identifier !== undefined && !input.hidden);
    const select = el("select", { "aria-label": "Input" }, inputs.map((input) => el("option", { value: input.identifier, text: input.name })));
    select.addEventListener("change", () => ctx.write(service, characteristic, Number(select.value)));
    ctx.watch(() => { if (document.activeElement !== select) select.value = String(characteristic.value); });
    return select;
  }

  /// Rows for the characteristics of `service` no widget took, each marked as shown.
  function rows(ctx, service) {
    return service.characteristics.filter((c) => !ctx.used.has(c) && !plumbing.has(c.type) && !c.internal).map((characteristic) => {
      const control = controlFor(ctx, service, characteristic);
      ctx.use(characteristic);
      if (!control) return null;
      return el("div", { class: "control" }, el("span", { text: rowLabels[characteristic.type] || sentence(characteristic.type) }), control);
    }).filter(Boolean);
  }

  /// What no widget showed, a service at a time: one row under the service's name, or several under a heading.
  function leftovers(ctx, services = ctx.services) {
    return services.filter((service) => !quietServices.has(service.type))
      .map((service) => ({ service, rows: rows(ctx, service) })).filter((group) => group.rows.length)
      .map(({ service, rows: list }) => list.length === 1
        ? el("div", { class: "control" }, el("span", { text: shortName(ctx.accessory, service) }), list[0].lastChild)
        : el("div", { class: "controls" }, el("div", { class: "service-name", text: shortName(ctx.accessory, service) }), list));
  }

  // ---- Shared pieces of widgets -----------------------------------------------------------------------

  /// A speed: bars when it has a few positions, else a level.
  function speedControl(ctx, service, characteristic, color) {
    const min = characteristic.minValue ?? 0, max = characteristic.maxValue ?? 100, count = positions(characteristic);
    if (count <= 6 && count >= 2) {
      const stepSize = (max - min) / count;
      const control = steps({ label: "Speed", count }, (n) => ctx.write(service, characteristic, min + n * stepSize));
      if (color) control.node.style.setProperty("--steps", color);
      ctx.watch(() => control.set(Math.round((numberOf(characteristic) - min) / stepSize)));
      return el("div", { class: "w-row" }, el("span", { class: "w-label", text: "Speed" }), control.node);
    }
    const control = level({ label: "Speed", min, max, step: characteristic.minStep || 1, format: (v) => `${v}${unit(characteristic)}`, fill: color }, (v) => ctx.write(service, characteristic, v));
    ctx.watch(() => control.set(numberOf(characteristic)));
    return control.node;
  }

  /// A writable bool or 0/1 of a service as a chip (Swing, Child lock).
  function chipFor(ctx, service, characteristic, label) {
    if (!canWrite(characteristic)) return null;
    ctx.use(characteristic);
    const control = chip(label, (on) => ctx.write(service, characteristic, onValue(characteristic, on)));
    ctx.watch(() => control.set(isOn(characteristic)));
    return control.node;
  }

  const presets = [
    ["Warm white", 30, 55], ["Amber", 26, 85], ["Red", 2, 90], ["Pink", 330, 70], ["Violet", 275, 70], ["Blue", 220, 85], ["Cyan", 185, 75], ["Green", 125, 75],
  ];

  /// A light's controls, each a function that builds it (null when the light has none): `brightness` (a level,
  /// tall with `vertical`), `swatches` (colours, in a grid with `grid`), `white` (the temperature in kelvin);
  /// `color()`, the colour it shows now, for the tile.
  function lightParts(ctx, service) {
    const brightness = ctx.take(service, "Brightness"), hue = ctx.take(service, "Hue"), saturation = ctx.take(service, "Saturation");
    const temperature = ctx.take(service, "Color Temperature");
    // Adaptive Lighting (a controller on the bridge): on while a schedule runs, which its transition count says.
    const transitions = ctx.char(service, "Characteristic Value Active Transition Count");
    const adaptive = service.adaptiveLighting ? { resumable: !!service.adaptiveLighting.resumable } : null;
    const adaptiveOn = () => !!adaptive && numberOf(transitions) > 0;
    const setAdaptive = async (on) => {
      const before = transitions?.value;
      if (transitions) transitions.value = on ? 1 : 0;
      ctx.paint();
      try {
        await api(`/api/accessories/${encodeURIComponent(ctx.accessory.id)}/adaptive-lighting`, { method: "PUT", body: { service: serviceKey(service), on } });
        adaptive.resumable = true;
      } catch (e) {
        if (e.message === "signed out") return;
        if (transitions) transitions.value = before;
        ctx.flash(e.message);
      }
    };
    /// The Adaptive control: a swatch among the colours, a round button beside a white slider, or a chip.
    const adaptiveControl = (kind) => {
      const label = "Adaptive Lighting";
      const node = kind === "chip"
        ? el("button", { type: "button", class: "chip adaptive-chip", "aria-pressed": "false" }, icon("sun"), el("span", { text: "Adaptive" }))
        : el("button", { type: "button", class: kind === "swatch" ? "swatch adaptive" : "round adaptive", role: kind === "swatch" ? "radio" : null, "aria-label": label, title: label }, icon("sun"));
      node.addEventListener("click", () => setAdaptive(!adaptiveOn()));
      ctx.watch(() => {
        node.setAttribute(kind === "swatch" ? "aria-checked" : "aria-pressed", String(adaptiveOn()));
        node.classList.toggle("unset", !adaptive.resumable && !adaptiveOn());
        node.title = adaptiveOn() ? "Adaptive Lighting: on" : adaptive.resumable ? "Adaptive Lighting: resume the Home app's schedule" : "Adaptive Lighting: turn it on once in the Home app";
      });
      return node;
    };
    const color = () => {
      if (adaptiveOn() && temperature) return { k: kelvin(numberOf(temperature, 300)) };
      if (hue && saturation && numberOf(saturation) > 4) return { h: numberOf(hue), s: numberOf(saturation) };
      if (temperature) return { k: kelvin(numberOf(temperature, 300)) };
      return null;
    };
    const css = (c, lightness) => c.k ? whiteColor(c.k, lightness) : `hsl(${Math.round(c.h)} ${Math.round(c.s)}% ${lightness}%)`;
    return {
      brightness: canWrite(brightness) ? ({ vertical = false } = {}) => {
        const control = level({ label: "Brightness", min: brightness.minValue ?? 0, max: brightness.maxValue ?? 100, step: brightness.minStep || 1, format: (v) => `${v} %`, vertical },
          (v) => ctx.write(service, brightness, v));
        ctx.watch(() => {
          control.set(numberOf(brightness));
          const c = color();
          control.node.style.setProperty("--fill", c ? `linear-gradient(${vertical ? "0deg" : "90deg"}, ${css(c, 64)}, ${css(c, 86)})` : "");
        });
        return control.node;
      } : null,
      swatches: canWrite(hue) && canWrite(saturation) ? ({ grid = false } = {}) => {
        const swatches = presets.map(([name, h, s]) => {
          const swatch = el("button", { type: "button", class: "swatch", role: "radio", "aria-label": name, title: name, onclick: () => {
            ctx.write(service, hue, h);
            ctx.write(service, saturation, s);
          } });
          swatch.style.setProperty("--swatch", `hsl(${h} ${s}% 60%)`);
          return { swatch, h, s };
        });
        ctx.watch(() => {
          const h = numberOf(hue), s = numberOf(saturation);
          const near = (a, b) => Math.min(Math.abs(a - b), 360 - Math.abs(a - b)) <= 6;
          for (const one of swatches) one.swatch.setAttribute("aria-checked", String(!adaptiveOn() && s > 4 && near(one.h, h) && Math.abs(one.s - s) <= 12));
        });
        return el("div", { class: `swatches${grid ? " grid" : ""}`, role: "radiogroup", "aria-label": "Colour" }, adaptive ? adaptiveControl("swatch") : null, swatches.map((one) => one.swatch));
      } : null,
      white: canWrite(temperature) ? ({ vertical = false, thin = false } = {}) => {
        // Mireds run the other way: the track goes from warm (few kelvin, many mireds) to cool.
        const low = kelvin(temperature.maxValue ?? 500), high = kelvin(temperature.minValue ?? 140);
        const control = level({ label: "White", min: low, max: high, step: 50, format: (k) => `${k} K`, vertical, thin,
          gradient: `linear-gradient(${vertical ? "0deg" : "90deg"}, ${whiteColor(low, 72)}, ${whiteColor((low + high) / 2, 88)}, ${whiteColor(high, 84)})` },
        (k) => {
          const mireds = clamp(Math.round(1e6 / k), temperature.minValue ?? 0, temperature.maxValue ?? 1000);
          if (saturation && canWrite(saturation) && numberOf(saturation) > 0) ctx.write(service, saturation, 0);
          ctx.write(service, temperature, mireds);
        });
        ctx.watch(() => control.set(kelvin(numberOf(temperature, 300))));
        return control.node;
      } : null,
      // For a light without colours: the Adaptive control on its own ("round" beside the white, or a "chip").
      adaptive: adaptive ? (kind = "chip") => adaptiveControl(kind) : null,
      adaptiveOn,
      color: () => { const c = color(); return c && { tile: `linear-gradient(160deg, ${css(c, 74)}, ${css(c, 52)})`, glow: css(c, 55) }; },
    };
  }

  /// A light's whole body: its brightness, its colours, its white temperature, whichever it has.
  function lightBody(ctx, service) {
    const parts = lightParts(ctx, service);
    const chip = !parts.swatches && parts.adaptive ? el("div", { class: "chips" }, parts.adaptive("chip")) : null;
    return { nodes: [parts.brightness?.(), parts.swatches?.(), parts.white?.(), chip].filter(Boolean), color: parts.color };
  }

  /// A sensor service's reading: its value, its unit, a tone, and its glyph.
  const readings = {
    TemperatureSensor: ["Current Temperature", "thermo"], HumiditySensor: ["Current Relative Humidity", "sensor"], LightSensor: ["Current Ambient Light Level", "sensor"],
    AirQualitySensor: ["Air Quality", "wind"], MotionSensor: ["Motion Detected", "sensor"], OccupancySensor: ["Occupancy Detected", "sensor"],
    ContactSensor: ["Contact Sensor State", "door"], LeakSensor: ["Leak Detected", "drop"], SmokeSensor: ["Smoke Detected", "sensor"],
    CarbonMonoxideSensor: ["Carbon Monoxide Detected", "sensor"], CarbonDioxideSensor: ["Carbon Dioxide Level", "sensor"],
  };
  function reading(ctx, service) {
    const [type, glyph] = readings[service.type] ?? [];
    const main = type && ctx.char(service, type);
    if (!main) return null;
    ctx.use(main, ctx.char(service, "Status Active"));
    const extra = ["PM2.5 Density", "PM10 Density", "VOC Density", "Carbon Dioxide Detected"].map((t) => ctx.take(service, t)).filter(Boolean);
    const active = ctx.char(service, "Status Active");
    const value = () => {
      const v = main.value;
      const inactive = active && active.value === false;
      switch (service.type) {
        case "TemperatureSensor": return { text: typeof v === "number" ? HomeswiftCommon.temperature(v).value.toFixed(1) : "–", unit: HomeswiftCommon.temperature(0).unit, tone: inactive ? "muted" : "" };
        case "HumiditySensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "%", tone: inactive ? "muted" : "" };
        case "LightSensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "lx" };
        case "CarbonDioxideSensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "ppm" };
        case "AirQualitySensor": return { text: labelFor(main.type, v), tone: v >= 4 ? "warn" : v >= 1 ? "ok" : "muted", scale: v >= 1 ? 6 - v : 0 };
        case "ContactSensor": return { text: v === 0 ? "Closed" : "Open", tone: v === 0 ? "" : "warn" };
        default: return { text: labelFor(main.type, v), tone: isOn(main) ? "warn" : "" };
      }
    };
    return { main, glyph, extra, value };
  }

  /// The services `widget` left: chips (switches and other on/off services), readouts (sensors), meters (a
  /// filter, a battery), blocks (a light, a fan, a thermostat, a lock). Each one's characteristics marked shown.
  function facets(ctx, handled = []) {
    const out = { chips: [], readouts: [], meters: [], blocks: [] };
    for (const service of ctx.services) {
      if (handled.includes(service) || quietServices.has(service.type) || service.characteristics.every((c) => ctx.used.has(c))) continue;
      const name = shortName(ctx.accessory, service);
      const on = ctx.char(service, "On");
      if ((service.type === "Switch" || service.type === "Outlet") && canWrite(on) && !on.security) {
        out.chips.push(chipFor(ctx, service, on, name));
      } else if (readings[service.type]) {
        const one = reading(ctx, service);
        if (!one) continue;
        const control = readout(name);
        ctx.watch(() => { const v = one.value(); control.set(v.text, v.unit, v.tone, v.scale); });
        out.readouts.push(control.node);
        for (const extra of one.extra) {
          const more = readout(extra.type.replace(" Density", "").replace("Carbon Dioxide Detected", "CO₂"));
          ctx.watch(() => more.set(extra.format === "bool" || enumLabels[extra.type] ? labelFor(extra.type, extra.value) : String(Math.round(numberOf(extra))), extra.type.endsWith("Density") ? "µg/m³" : ""));
          out.readouts.push(more.node);
        }
      } else if (service.type === "FilterMaintenance" || service.type === "Battery") {
        const life = ctx.take(service, service.type === "Battery" ? "Battery Level" : "Filter Life Level");
        const flag = ctx.take(service, service.type === "Battery" ? "Status Low Battery" : "Filter Change Indication");
        const label = service.type === "Battery" ? "Battery" : "Filter";
        if (life) {
          const control = meter(label === "Filter" ? "Filter life" : label);
          ctx.watch(() => control.set(Math.round(numberOf(life))));
          out.meters.push(control.node);
        } else if (flag) {
          const state = pill();
          ctx.watch(() => { state.textContent = labelFor(flag.type, flag.value); state.className = `pill ${isOn(flag) ? "warn" : "ok"}`; });
          out.blocks.push(el("div", { class: "w-row" }, el("span", { class: "w-label", text: label }), state));
        }
        if (service.type === "Battery") ctx.take(service, "Charging State");
      } else if (service.type === "Lightbulb" && canWrite(on)) {
        out.blocks.push(lightBlock(ctx, service, name));
      } else if ((service.type === "Fanv2" || service.type === "Fan") && (canWrite(ctx.char(service, "Active")) || canWrite(on))) {
        out.blocks.push(fanBlock(ctx, service, name));
      } else if ((service.type === "Thermostat" || service.type === "HeaterCooler") && ctx.char(service, "Current Temperature")) {
        out.blocks.push(climateBlock(ctx, service, name));
      } else if (service.type === "LockMechanism" && ctx.char(service, "Lock Current State")) {
        out.blocks.push(lockRow(ctx, service, name));
      }
    }
    return out;
  }
  const hasFacets = (f) => f.chips.length + f.readouts.length + f.meters.length + f.blocks.length > 0;
  function facetNodes(f) {
    return [
      f.readouts.length ? el("div", { class: "readouts" }, f.readouts) : null,
      ...f.meters, ...f.blocks,
      f.chips.length ? el("div", { class: "chips" }, f.chips) : null,
    ].filter(Boolean);
  }

  /// A secondary light (a TV's Ambilight, a camera's flashlight): its name and switch, then its body.
  function lightBlock(ctx, service, name) {
    const on = ctx.take(service, "On");
    const power = toggle(`${name}: on`, (v) => ctx.write(service, on, onValue(on, v)));
    ctx.watch(() => power.set(isOn(on)));
    const body = el("div", { class: "w-block-body" }, lightBody(ctx, service).nodes);
    ctx.watch(() => { body.hidden = !isOn(on); });
    return el("div", { class: "w-block" }, el("div", { class: "w-row" }, el("span", { class: "w-label", text: name }), power.node), body);
  }

  function fanBlock(ctx, service, name) {
    const power = ctx.take(service, "Active") || ctx.take(service, "On");
    const control = toggle(`${name}: on`, (v) => ctx.write(service, power, onValue(power, v)));
    ctx.watch(() => control.set(isOn(power)));
    const speed = ctx.take(service, "Rotation Speed");
    const target = ctx.take(service, "Target Fan State");
    ctx.take(service, "Current Fan State");
    // Its speed and modes show while it runs: a fan beside an air conditioner's own speed reads as one row when off.
    const body = el("div", { class: "w-block-body" },
      canWrite(speed) ? speedControl(ctx, service, speed) : null,
      canWrite(target) ? modeControl(ctx, service, target) : null,
      el("div", { class: "chips" }, chipFor(ctx, service, ctx.char(service, "Swing Mode"), "Swing"), chipFor(ctx, service, ctx.char(service, "Lock Physical Controls"), "Child lock")));
    ctx.watch(() => { body.hidden = !isOn(power); });
    return el("div", { class: "w-block" }, el("div", { class: "w-row" }, el("span", { class: "w-label", text: name }), control.node), body);
  }

  /// A writable enumeration of two to four values as a segmented control (more stay a menu, under More).
  function modeControl(ctx, service, characteristic, label = sentence(characteristic.type)) {
    const values = characteristic.validValues || (enumLabels[characteristic.type] || []).map((_, i) => i);
    if (values.length < 2 || values.length > 4) return null;
    ctx.use(characteristic);
    const control = segmented(values.map((value) => ({ value, label: labelFor(characteristic.type, value) })), label, (v) => ctx.write(service, characteristic, v));
    ctx.watch(() => control.set(characteristic.value));
    return control.node;
  }

  // ---- Climate: a heater-cooler or a thermostat ---------------------------------------------------------

  /// The parts of a climate service, read the same way for both kinds: its modes as "off", "auto", "heat"
  /// and "cool", the setpoint each mode uses, its state now.
  function climateParts(ctx, service) {
    const heaterCooler = service.type === "HeaterCooler";
    const part = (type) => ctx.take(service, type);
    const parts = {
      service, heaterCooler,
      active: heaterCooler ? part("Active") : null,
      target: part(heaterCooler ? "Target Heater-Cooler State" : "Target Heating Cooling State"),
      state: part(heaterCooler ? "Current Heater-Cooler State" : "Current Heating Cooling State"),
      current: part("Current Temperature"),
      heat: part("Heating Threshold Temperature"), cool: part("Cooling Threshold Temperature"),
      single: heaterCooler ? null : part("Target Temperature"),
      humidity: part("Current Relative Humidity"),
    };
    const modeNames = heaterCooler ? ["auto", "heat", "cool"] : ["off", "heat", "cool", "auto"];
    parts.mode = () => {
      if (parts.active && !isOn(parts.active)) return "off";
      return modeNames[numberOf(parts.target)] ?? "auto";
    };
    /// The setpoints a mode shows: both thresholds in auto, else the one it heats or cools to.
    parts.setpoints = (mode) => {
      if (mode === "auto") return parts.heat && parts.cool ? [parts.heat, parts.cool] : [parts.single].filter(Boolean);
      if (mode === "heat") return [parts.single || parts.heat].filter(Boolean);
      if (mode === "cool") return [parts.single || parts.cool].filter(Boolean);
      return [];
    };
    /// "heating", "cooling" or "idle", from the current state.
    parts.working = () => {
      const state = numberOf(parts.state);
      if (heaterCooler) return state === 2 ? "heating" : state === 3 ? "cooling" : "idle";
      return state === 1 ? "heating" : state === 2 ? "cooling" : "idle";
    };
    /// The mode as it shows when off: the one it would come back in.
    parts.lastMode = () => modeNames[numberOf(parts.target)] ?? "auto";
    return parts;
  }

  /// A setpoint control per temperature a service has; `show(list)` shows those a mode uses.
  function setpointControls(ctx, parts) {
    const labels = new Map([[parts.heat, "Heat to"], [parts.cool, "Cool to"], [parts.single, "Set to"]]);
    const controls = [...labels.keys()].filter((c) => canWrite(c)).map((characteristic) => {
      const control = setpoint({ label: labels.get(characteristic), min: characteristic.minValue ?? 10, max: characteristic.maxValue ?? 35, step: characteristic.minStep || 0.5 },
        (v) => ctx.write(parts.service, characteristic, v));
      ctx.watch(() => control.set(numberOf(characteristic)));
      return { characteristic, control };
    });
    return {
      nodes: controls.map(({ control }) => control.node),
      show(list) {
        for (const { characteristic, control } of controls) control.node.hidden = !list.includes(characteristic);
        // One setpoint per mode with a single target: "Heat to" or "Cool to" rather than "Set to".
        const single = controls.find((one) => one.characteristic === parts.single);
        if (single) single.control.node.querySelector(".sp-value span").textContent = { heat: "Heat to", cool: "Cool to" }[parts.mode()] ?? "Set to";
      },
    };
  }

  /// The modes a climate service offers, as a segmented control (Auto, Heat, Cool; Off for a thermostat).
  function climateModes(ctx, parts) {
    if (!canWrite(parts.target)) return null;
    const values = parts.target.validValues || enumLabels[parts.target.type].map((_, i) => i);
    const order = parts.heaterCooler ? [0, 1, 2] : [0, 3, 1, 2];
    const options = order.filter((v) => values.includes(v)).map((value) => ({ value, label: labelFor(parts.target.type, value) }));
    if (options.length < 2) return null;
    const control = segmented(options, "Mode", (v) => ctx.write(parts.service, parts.target, v));
    ctx.watch(() => control.set(parts.target.value));
    return control.node;
  }

  /// A thermostat inside another accessory's card (a purifier's heater): its modes and setpoint.
  function climateBlock(ctx, service, name) {
    const parts = climateParts(ctx, service);
    const points = setpointControls(ctx, parts);
    const now = el("span", { class: "muted" });
    ctx.watch(() => {
      points.show(parts.setpoints(parts.mode() === "off" ? parts.lastMode() : parts.mode()));
      now.textContent = typeof parts.current?.value === "number" && parts.current.value > -40 ? `${degrees(+parts.current.value.toFixed(1))} now` : "";
    });
    const power = parts.active ? toggle(`${name}: on`, (v) => ctx.write(service, parts.active, v ? 1 : 0)) : null;
    if (power) ctx.watch(() => power.set(isOn(parts.active)));
    return el("div", { class: "w-block" },
      el("div", { class: "w-row" }, el("span", { class: "w-label" }, name, " ", now), power?.node ?? null),
      climateModes(ctx, parts), el("div", { class: "setpoints row-setpoints" }, points.nodes));
  }

  // ---- Locks and doors ---------------------------------------------------------------------------------

  /// A lock: its state, a hold to unlock, a tap to lock.
  function lockRow(ctx, service, name) {
    const current = ctx.take(service, "Lock Current State"), target = ctx.take(service, "Lock Target State");
    const state = pill();
    const unlock = canWrite(target) ? hold("Hold to unlock", () => ctx.write(service, target, 0, { held: true })) : null;
    const lock = canWrite(target) ? el("button", { type: "button", class: "w-button", text: "Lock", onclick: () => ctx.write(service, target, 1, { held: true }) }) : null;
    ctx.watch(() => {
      const value = numberOf(current, numberOf(target, 3));
      state.textContent = labelFor(current.type, value);
      state.className = `pill ${value === 1 ? "ok" : value === 2 ? "bad" : "warn"}`;
      if (unlock) unlock.node.hidden = numberOf(target) === 0;
      if (lock) lock.hidden = numberOf(target) !== 0;
    });
    return el("div", { class: "lock-row" }, el("div", { class: "lock-name" }, el("strong", { text: name }), state), unlock?.node ?? null, lock);
  }

  // ---- The widgets ------------------------------------------------------------------------------------
  // Each: its `name` (the kind a default size is kept for), the service types it draws, its default `size`
  // (or a function of the accessory), and build(ctx, primary, size). The size is "small", "medium" or "large",
  // the fixed boxes of the wall, or "full", every control, in the sheet. build answers
  //   body        the nodes under the header (medium, large, full); side, in full, the nodes beside them
  //   facets      in full, the other services, as facets() makes them
  //   power       { service, characteristic, big }: the switch in the header
  //   status()    [text, tone]: the line under the name
  //   on()        whether the tile is lit; color() a light's colour for it; tone the tile's colour
  //   hero()      a small tile's figure (its temperature, its brightness)
  //   tap()       a small tile's action, tapLabel() what it does; without, a tap opens the full view
  //   hold        { armed(), confirm(), tap(), verb() }: a small tile held to confirm (opening a gate)
  //   shade()     a shutter's closed share, drawn on its small tile

  const widgets = [];
  const register = (widget) => widgets.push(widget);
  const sizes = ["small", "medium", "large"];

  // Which service an accessory is drawn by, when none says it is primary: the first of these.
  const rank = ["Television", "HeaterCooler", "Thermostat", "AirPurifier", "SecuritySystem", "GarageDoorOpener", "LockMechanism", "WindowCovering",
    "Door", "Window", "Valve", "Fanv2", "Fan", "Lightbulb", "Outlet", "Switch", ...Object.keys(readings)];
  function primaryOf(ctx) {
    const candidates = ctx.services.filter((service) => !quietServices.has(service.type));
    const flagged = candidates.find((service) => service.primary);
    if (flagged) return flagged;
    const order = (service) => { const index = rank.indexOf(service.type); return index < 0 ? rank.length : index; };
    return [...candidates].sort((a, b) => order(a) - order(b))[0];
  }

  /// Chips for the bools of a service a widget offers as options (Swing, Child lock).
  const optionChips = (ctx, service) => [chipFor(ctx, service, ctx.char(service, "Swing Mode"), "Swing"), chipFor(ctx, service, ctx.char(service, "Lock Physical Controls"), "Child lock")].filter(Boolean);
  const chipRow = (nodes) => nodes.length ? el("div", { class: "chips" }, nodes) : null;
  const row = (label, ...nodes) => el("div", { class: "w-row" }, label ? el("span", { class: "w-label", text: label }) : null, ...nodes);

  /// A switch of a group as a tile of its own: its name and state; a tap toggles it.
  function miniToggle(ctx, service, characteristic, name) {
    ctx.use(characteristic);
    const state = el("span");
    const node = el("button", { type: "button", class: "mini-toggle", onclick: () => ctx.write(service, characteristic, onValue(characteristic, !isOn(characteristic))) }, el("b", { text: name }), state);
    ctx.watch(() => { node.setAttribute("aria-pressed", String(isOn(characteristic))); state.textContent = isOn(characteristic) ? "On" : "Off"; });
    return node;
  }

  /// The readings of an accessory's sensors as one line ("21.4 °C · 48 % · air good").
  function readingLine(ctx, handled = []) {
    const list = ctx.services.filter((s) => readings[s.type] && !handled.includes(s)).map((s) => reading(ctx, s)).filter(Boolean);
    const filter = ctx.char(ctx.find("FilterMaintenance"), "Filter Life Level");
    const node = el("div", { class: "w-line" });
    ctx.watch(() => {
      const parts = list.map((one) => { const v = one.value(); return `${v.text}${v.unit ? ` ${v.unit}` : ""}`; });
      if (filter) parts.push(`filter ${Math.round(numberOf(filter))} %`);
      node.textContent = parts.join(" · ");
    });
    return list.length || filter ? node : null;
  }

  register({
    name: "switch-group", types: ["Switch", "Outlet"], icon: "switch", tone: "green", size: "medium",
    // An accessory of switches only (a chime's speakers, a remote's buttons): chips, or a tile each.
    match: (ctx) => {
      const shown = ctx.services.filter((s) => !quietServices.has(s.type));
      return shown.length >= 2 && shown.every((s) => (s.type === "Switch" || s.type === "Outlet") && canWrite(ctx.char(s, "On")) && !ctx.char(s, "On").security);
    },
    build(ctx, primary, size) {
      const switches = ctx.services.filter((s) => !quietServices.has(s.type));
      const ons = switches.map((s) => ctx.char(s, "On"));
      const count = () => ons.filter(isOn).length;
      const body = size === "large" || size === "full"
        ? [el("div", { class: "toggles" }, switches.map((s, i) => miniToggle(ctx, s, ons[i], shortName(ctx.accessory, s))))]
        : [chipRow(switches.map((s, i) => chipFor(ctx, s, ons[i], shortName(ctx.accessory, s))))];
      return {
        body, hero: () => `${count()}/${ons.length}`,
        status: () => [count() ? `${count()} of ${ons.length} on` : "All off"],
        on: () => count() > 0,
      };
    },
  });

  register({
    name: "television", types: ["Television"], icon: "tv", tone: "blue", size: "large",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active");
      const remoteKey = ctx.take(primary, "Remote Key");
      const input = ctx.take(primary, "Active Identifier");
      const speaker = ctx.find("TelevisionSpeaker");
      const volume = ctx.char(speaker, "Volume Selector"), mute = ctx.char(speaker, "Mute");
      if (speaker) ctx.useAll(speaker);
      const remote = () => {
        if (!canWrite(remoteKey) || !window.HomeswiftRemote) return null;
        const homeKitKeys = { up: 4, down: 5, left: 6, right: 7, select: 8, back: 9, playPause: 11, info: 15 };
        const actions = [...Object.keys(homeKitKeys), ...(canWrite(volume) ? ["volumeUp", "volumeDown"] : []), ...(canWrite(mute) ? ["mute"] : [])];
        return el("div", { class: "card-remote" }, HomeswiftRemote.build({
          actions, label: `Remote for ${ctx.accessory.name}`,
          send: (action) => {
            if (action in homeKitKeys) return ctx.send(primary, remoteKey, homeKitKeys[action]);
            if (action === "volumeUp" || action === "volumeDown") return ctx.send(speaker, volume, action === "volumeUp" ? 0 : 1);
            return ctx.write(speaker, mute, !isOn(mute));
          },
        }));
      };
      const picker = () => canWrite(input) ? inputPicker(ctx, primary, input) : null;
      const inputName = () => {
        const chosen = ctx.accessory.services.find((s) => s.type === "InputSource" && ctx.char(s, "Identifier")?.value === input?.value);
        return chosen ? ctx.char(chosen, "Configured Name")?.value || chosen.name : null;
      };
      const volumeKeys = () => canWrite(volume) ? ["minus", "plus"].map((glyph, i) => el("button", { type: "button", class: "round", "aria-label": i ? "Volume up" : "Volume down",
        onclick: () => ctx.send(speaker, volume, i ? 0 : 1).catch((e) => ctx.flash(e.message)) }, icon(glyph))) : [];
      const parts = {
        power: canWrite(active) ? { service: primary, characteristic: active } : null,
        status: () => isOn(active) ? [inputName() ? `On · ${inputName()}` : "On"] : ["Off"],
        on: () => isOn(active),
        tap: canWrite(active) ? () => ctx.write(primary, active, isOn(active) ? 0 : 1) : null,
      };
      if (size === "medium") parts.body = [el("div", { class: "w-row" }, picker(), el("div", { class: "w-keys" }, volumeKeys(), canWrite(mute) ? chipFor(ctx, speaker, mute, "Mute") : null))];
      if (size === "large") parts.body = [remote(), input ? row("Input", picker()) : null].filter(Boolean);
      if (size === "full") Object.assign(parts, { body: [remote()].filter(Boolean), side: input ? [row("Input", picker())] : [], facets: facets(ctx, [primary, speaker]) });
      return parts;
    },
  });

  register({
    name: "climate", types: ["HeaterCooler", "Thermostat"], icon: "thermo", size: "large",
    build(ctx, primary, size) {
      const parts = climateParts(ctx, primary);
      const now = () => typeof parts.current?.value === "number" ? parts.current.value : null;
      const mode = () => parts.mode();
      const shownMode = () => mode() === "off" ? parts.lastMode() : mode();
      const built = {
        power: canWrite(parts.active) ? { service: primary, characteristic: parts.active } : null,
        tone: () => ({ heat: "heat", cool: "blue", auto: "green" })[shownMode()] ?? "teal",
        on: () => mode() !== "off",
        hero: () => now() === null ? "" : el("span", {}, degrees(+now().toFixed(1)), el("small", { text: mode() })),
        tap: canWrite(parts.active) ? () => ctx.write(primary, parts.active, isOn(parts.active) ? 0 : 1) : null,
        status() {
          const inside = now() === null ? "" : `${degrees(+now().toFixed(1))} inside`;
          if (mode() === "off") return [inside ? `Off · ${inside}` : "Off"];
          const shown = parts.setpoints(mode());
          const working = parts.working();
          if (shown.length === 2) {
            if (working === "heating") return [`Heating to ${degrees(numberOf(shown[0]))}`, "heat"];
            if (working === "cooling") return [`Cooling to ${degrees(numberOf(shown[1]))}`, "cool"];
            return [`Keeping ${degrees(numberOf(shown[0]))}–${degrees(numberOf(shown[1]))}`, "auto"];
          }
          const target = shown[0] ? degrees(numberOf(shown[0])) : "";
          if (working === "heating") return [`Heating to ${target}`, "heat"];
          if (working === "cooling") return [`Cooling to ${target}`, "cool"];
          return [`Idle · ${mode()} to ${target}`];
        },
      };
      if (size === "small") return built;
      const points = setpointControls(ctx, parts);
      if (size === "medium") {
        // The temperature inside and one setpoint: the mode's own (Cool to in auto).
        const big = el("b", { class: "w-big" });
        ctx.watch(() => {
          const shown = parts.setpoints(shownMode());
          points.show(shown.slice(-1));
          big.textContent = now() === null ? "–" : degrees(+now().toFixed(1));
        });
        built.body = [el("div", { class: "w-row" }, el("div", { class: "w-figure" }, big, el("span", { text: "Inside" })), el("div", { class: "setpoints" }, points.nodes))];
        return built;
      }
      const temps = [parts.heat, parts.cool, parts.single].filter(Boolean);
      const min = Math.min(...temps.map((c) => c.minValue ?? 10), 10), max = Math.max(...temps.map((c) => c.maxValue ?? 35), 30);
      const dial = gauge({ min, max });
      const colors = { heat: "var(--heat)", cool: "var(--cool)", auto: "var(--auto)" };
      ctx.watch(() => {
        const shown = parts.setpoints(shownMode());
        points.show(shown);
        const caption = typeof parts.humidity?.value === "number" ? `Inside · ${Math.round(parts.humidity.value)} %` : "Inside";
        if (mode() === "off" || !shown.length) dial.update({ value: now(), caption });
        else if (shown.length === 2) dial.update({ value: now(), from: numberOf(shown[0]), to: numberOf(shown[1]), color: colors.auto, caption });
        else dial.update({ value: now(), from: now() ?? numberOf(shown[0]), to: numberOf(shown[0]), color: colors[mode()], caption });
      });
      const speed = ctx.take(primary, "Rotation Speed");
      const chips = optionChips(ctx, primary);
      built.body = [
        el("div", { class: "climate-hero" }, dial.node, el("div", { class: "setpoints" }, points.nodes)),
        climateModes(ctx, parts),
        canWrite(speed) ? speedControl(ctx, primary, speed) : null,
        chipRow(chips),
      ].filter(Boolean);
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "air-purifier", types: ["AirPurifier"], icon: "wind", tone: "teal", size: "large",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active"), state = ctx.take(primary, "Current Air Purifier State");
      const target = ctx.char(primary, "Target Air Purifier State"), speed = ctx.take(primary, "Rotation Speed");
      const quality = ctx.char(ctx.find("AirQualitySensor"), "Air Quality");
      const built = {
        power: canWrite(active) ? { service: primary, characteristic: active } : null,
        on: () => isOn(active),
        tap: canWrite(active) ? () => ctx.write(primary, active, isOn(active) ? 0 : 1) : null,
        hero: () => quality ? el("span", { class: "w-hero-word" }, labelFor(quality.type, quality.value)) : speed && isOn(active) ? `${numberOf(speed)}%` : "",
        status() {
          if (!isOn(active)) return [quality ? `Off · air ${labelFor(quality.type, quality.value).toLowerCase()}` : "Off"];
          const how = target && numberOf(target) === 1 ? "auto" : speed ? `${numberOf(speed)} %` : "";
          return numberOf(state) === 2 ? [how ? `Purifying · ${how}` : "Purifying", "ok"] : ["Idle"];
        },
      };
      if (size === "small") return built;
      const speedNode = canWrite(speed) ? speedControl(ctx, primary, speed, "linear-gradient(90deg, #8fe3da, #1c9c91)") : null;
      if (size === "medium") { built.body = [speedNode ?? modeControl(ctx, primary, target, "Mode"), readingLine(ctx)].filter(Boolean); return built; }
      const mode = modeControl(ctx, primary, target, "Mode");
      const chips = optionChips(ctx, primary);
      if (size === "large") {
        const f = facets(ctx, [primary]);
        built.body = [mode, speedNode, f.readouts.length ? el("div", { class: "readouts four" }, f.readouts.slice(0, 4)) : null, f.meters[0] ?? null, chipRow([...chips, ...f.chips])].filter(Boolean);
        return built;
      }
      built.body = [mode, speedNode, chipRow(chips)].filter(Boolean);
      built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "fan", types: ["Fanv2", "Fan"], icon: "fan", tone: "teal", size: "medium",
    build(ctx, primary, size) {
      const power = ctx.take(primary, "Active") || ctx.take(primary, "On");
      const speed = ctx.take(primary, "Rotation Speed");
      ctx.take(primary, "Current Fan State");
      const built = {
        power: canWrite(power) ? { service: primary, characteristic: power } : null,
        on: () => isOn(power), hero: () => speed && isOn(power) ? `${numberOf(speed)}%` : "",
        tap: canWrite(power) ? () => ctx.write(primary, power, onValue(power, !isOn(power))) : null,
        status: () => isOn(power) ? [speed ? `On · ${numberOf(speed)} %` : "On"] : ["Off"],
      };
      const speedNode = canWrite(speed) ? speedControl(ctx, primary, speed) : null;
      if (size === "medium") built.body = [speedNode ?? chipRow(optionChips(ctx, primary))].filter(Boolean);
      if (size === "large" || size === "full") {
        built.body = [speedNode, modeControl(ctx, primary, ctx.char(primary, "Target Fan State"), "Mode"),
          modeControl(ctx, primary, ctx.char(primary, "Rotation Direction"), "Direction"), chipRow(optionChips(ctx, primary))].filter(Boolean);
      }
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "light", types: ["Lightbulb"], icon: "bulb", tone: "light",
    size: (ctx, primary) => canWrite(ctx.char(primary, "Brightness")) || canWrite(ctx.char(primary, "Hue")) || canWrite(ctx.char(primary, "Color Temperature")) ? "medium" : "small",
    match: (ctx, primary) => canWrite(ctx.char(primary, "On")),
    build(ctx, primary, size) {
      const on = ctx.take(primary, "On");
      const brightness = ctx.char(primary, "Brightness");
      const light = lightParts(ctx, primary);
      const built = {
        power: { service: primary, characteristic: on },
        tap: () => ctx.write(primary, on, onValue(on, !isOn(on))),
        on: () => isOn(on), color: light.color,
        hero: () => brightness && isOn(on) ? `${numberOf(brightness)}%` : "",
        status: () => isOn(on) ? [[brightness ? `On · ${numberOf(brightness)} %` : "On", light.adaptiveOn() ? "Adaptive" : ""].filter(Boolean).join(" · ")] : ["Off"],
      };
      // A white-only light's Adaptive control sits beside its white slider.
      const whiteRow = (options) => light.white ? (light.adaptive ? el("div", { class: "w-row" }, el("div", { class: "w-grow" }, light.white(options)), light.adaptive("round")) : light.white(options)) : null;
      if (size === "medium") built.body = [light.brightness?.(), light.swatches?.() ?? whiteRow({ thin: true })].filter(Boolean);
      if (size === "large") {
        // A tall brightness beside the colours, or beside a tall white (and the Adaptive chip under it).
        const tall = light.brightness?.({ vertical: true });
        const side = light.swatches ? [light.swatches({ grid: true }), light.white?.({ thin: true })] : [light.white?.({ vertical: true }), light.adaptive?.("chip")];
        built.body = [el("div", { class: "light-large" }, tall, el("div", { class: light.swatches ? "light-colours" : "light-tall" }, side.filter(Boolean)))];
      }
      if (size === "full") Object.assign(built, { body: lightBody(ctx, primary).nodes, facets: facets(ctx, [primary]) });
      return built;
    },
  });

  register({
    name: "cover", types: ["WindowCovering", "Door", "Window"], icon: "blind", tone: "blue", size: "small",
    match: (ctx, primary) => canWrite(ctx.char(primary, "Target Position")),
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Current Position"), target = ctx.take(primary, "Target Position");
      const state = ctx.take(primary, "Position State"), obstruction = ctx.take(primary, "Obstruction Detected");
      const hold = ctx.take(primary, "Hold Position");
      const min = target.minValue ?? 0, max = target.maxValue ?? 100, step = target.minStep || 1;
      const position = () => numberOf(current, numberOf(target));
      // Where this page sent the shutter: shown until it gets there, stops on the way, is sent elsewhere or two
      // minutes pass, as the Home app does, rather than each position it reports on its way.
      let goal = null;
      const go = async (value) => {
        goal = { value, since: Date.now(), moved: false };
        await ctx.write(primary, target, value);
        // Refused: the write put the target back.
        if (goal?.value === value && numberOf(target) !== value) { goal = null; ctx.paint(); }
      };
      const shown = () => {
        if (goal) {
          const moving = numberOf(state, 2) !== 2;
          if (moving) goal.moved = true;
          if (Math.abs(position() - goal.value) <= step || (goal.moved && !moving) || numberOf(target, goal.value) !== goal.value
            || Date.now() - goal.since > 120_000) goal = null;
        }
        return goal ? goal.value : position();
      };
      const built = {
        tap: () => go(shown() > min ? min : max),
        tapLabel: () => shown() > min ? "close" : "open",
        on: () => shown() > min, hero: () => `${shown()}%`, shade: () => 100 - (shown() - min) / (max - min) * 100,
        // The small tile slides: dragged down it closes, up it opens, written when let go.
        slide: { min, max, step, value: shown, commit: go },
        status() {
          if (isOn(obstruction)) return ["Obstructed", "warn"];
          const moving = numberOf(state, 2);
          const p = shown();
          if (moving === 1 || (moving === 2 && goal && goal.value > position())) return ["Opening…", "cool"];
          if (moving === 0 || (moving === 2 && goal && goal.value < position())) return ["Closing…", "cool"];
          return [p <= min ? "Closed" : p >= max ? "Open" : `Open · ${p} %`];
        },
      };
      if (size === "small") return built;
      // Stop: Hold Position where it has one, else the position it is at as the target.
      const buttons = [["up", "Open", () => go(max)],
        ["stop", "Stop", () => { goal = null; return canWrite(hold) ? ctx.write(primary, hold, true) : go(position()); }],
        ["down", "Close", () => go(min)]].map(([glyph, label, act]) => el("button", { type: "button", class: "round", "aria-label": label, title: label, onclick: act }, icon(glyph)));
      const slider = (vertical) => {
        const control = level({ label: "Position", min, max, step, format: (v) => `${v} %`, vertical,
          fill: `linear-gradient(${vertical ? "0deg" : "90deg"}, #4aa3ff, #a8dbff)` }, go);
        ctx.watch(() => control.set(numberOf(target, position())));
        return control.node;
      };
      const tilts = ["Target Horizontal Tilt Angle", "Target Vertical Tilt Angle"].map((type) => ctx.take(primary, type)).filter(canWrite).map((tilt) => {
        const one = level({ label: "Tilt", min: tilt.minValue ?? -90, max: tilt.maxValue ?? 90, step: tilt.minStep || 1, format: (v) => `${v}°`, thin: true }, (v) => ctx.write(primary, tilt, v));
        ctx.watch(() => one.set(numberOf(tilt)));
        return one.node;
      });
      for (const type of ["Current Horizontal Tilt Angle", "Current Vertical Tilt Angle"]) ctx.take(primary, type);
      if (size === "medium") built.body = [el("div", { class: "w-row" }, el("div", { class: "w-grow" }, slider(false)), ...buttons)];
      if (size === "large") built.body = [el("div", { class: "cover-large" }, slider(true), el("div", { class: "cover-buttons" }, buttons, tilts))];
      if (size === "full") Object.assign(built, { body: [slider(false), el("div", { class: "w-keys" }, buttons), ...tilts], facets: facets(ctx, [primary]) });
      return built;
    },
  });

  /// A small tile held to confirm, for what opens or unlocks; tapped, it does the safe thing.
  register({
    name: "garage-door", types: ["GarageDoorOpener"], icon: "gate", tone: "violet", size: "medium",
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Current Door State"), target = ctx.take(primary, "Target Door State");
      const obstruction = ctx.take(primary, "Obstruction Detected");
      const doorState = () => numberOf(current, numberOf(target, 1));
      const asked = () => numberOf(target, 1);
      const locks = ctx.all("LockMechanism").filter((s) => ctx.char(s, "Lock Current State"));
      const unlocked = () => locks.filter((s) => numberOf(ctx.char(s, "Lock Current State"), 1) !== 1);
      const openIt = () => ctx.write(primary, target, 0, { held: true }), closeIt = () => ctx.write(primary, target, 1, { held: true });
      const built = {
        on: () => doorState() !== 1 || unlocked().length > 0,
        hero: () => icon("lock"),
        hold: canWrite(target) ? { armed: () => asked() === 1, confirm: openIt, tap: () => { if (asked() === 0) closeIt(); }, verb: () => asked() === 1 ? "hold to open" : "close" } : null,
        status() {
          const now = doorState();
          const door = asked() !== now && now <= 1 ? (asked() === 0 ? "Opening" : "Closing") : labelFor(current.type, now);
          if (isOn(obstruction)) return ["Obstructed", "warn"];
          if (door === "Opening" || door === "Closing") return [`${door}…`, "warn"];
          const names = unlocked().map((s) => shortName(ctx.accessory, s).toLowerCase());
          if (now === 1 && !names.length) return [locks.length ? "Closed and locked" : "Closed", "ok"];
          return [names.length ? `${door} · ${names.join(", ")} unlocked` : door, "warn"];
        },
      };
      if (size === "small") return built;
      const big = el("b", { class: "w-state" });
      const warning = pill("Obstructed", "bad");
      const open = canWrite(target) ? hold("Hold to open", openIt) : null;
      const close = canWrite(target) ? el("button", { type: "button", class: "w-button", text: "Close", onclick: closeIt }) : null;
      ctx.watch(() => {
        big.textContent = labelFor(current.type, doorState());
        warning.hidden = !isOn(obstruction);
        if (open) open.node.hidden = asked() === 0;
        if (close) close.hidden = asked() !== 0;
      });
      const actions = el("div", { class: "w-actions" }, open?.node ?? null, close);
      if (size === "medium") { built.body = [el("div", { class: "w-row" }, el("div", { class: "big-state" }, big, warning), actions)]; return built; }
      const lockRows = locks.map((s) => lockRow(ctx, s, shortName(ctx.accessory, s)));
      built.body = [el("div", { class: "big-state" }, big, warning), actions, ...lockRows];
      const f = facets(ctx, [primary, ...locks]);
      if (size === "large") built.body.push(...(f.readouts.length ? [el("div", { class: "readouts" }, f.readouts.slice(0, 2))] : []));
      else built.facets = f;
      return built;
    },
  });

  register({
    name: "lock", types: ["LockMechanism"], icon: "lock", tone: "violet", size: "medium",
    match: (ctx, primary) => !!ctx.char(primary, "Lock Current State"),
    build(ctx, primary, size) {
      const current = ctx.char(primary, "Lock Current State"), target = ctx.char(primary, "Lock Target State");
      const built = {
        on: () => numberOf(current, 1) !== 1,
        hold: canWrite(target) ? { armed: () => numberOf(target, 1) === 1, confirm: () => ctx.write(primary, target, 0, { held: true }),
          tap: () => { if (numberOf(target, 1) === 0) ctx.write(primary, target, 1, { held: true }); }, verb: () => numberOf(target, 1) === 1 ? "hold to unlock" : "lock" } : null,
        status: () => { const v = numberOf(current, 3); return [labelFor(current.type, v), v === 1 ? "ok" : "warn"]; },
      };
      ctx.use(current, target);
      if (size === "small") return built;
      const lockNode = lockRow(ctx, primary, "");
      lockNode.querySelector(".lock-name strong")?.remove();
      built.body = [lockNode];
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "security-system", types: ["SecuritySystem"], icon: "shield", tone: "violet", size: "medium",
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Security System Current State"), target = ctx.take(primary, "Security System Target State");
      const values = target?.validValues || [0, 1, 2, 3];
      const disarm = () => ctx.write(primary, target, 3, { held: true });
      const built = {
        on: () => numberOf(current, 3) !== 3,
        hold: canWrite(target) && values.includes(3) ? { armed: () => numberOf(target, 3) !== 3, confirm: disarm, tap: () => ctx.openFull(), verb: () => numberOf(target, 3) !== 3 ? "hold to turn off" : "open" } : null,
        status: () => { const v = numberOf(current, 3); return [v === 4 ? "Alarm" : v === 3 ? "Off" : `Armed · ${labelFor(current.type, v)}`, v === 4 ? "bad" : v === 3 ? "" : "ok"]; },
      };
      if (size === "small") return built;
      const big = el("b", { class: "w-state" });
      const arm = canWrite(target) ? el("div", { class: "chips" }, values.filter((v) => v !== 3).map((value) =>
        el("button", { type: "button", class: "chip", text: labelFor(target.type, value), onclick: () => ctx.write(primary, target, value, { held: true }) }))) : null;
      const off = built.hold ? hold("Hold to turn off", disarm) : null;
      ctx.watch(() => {
        big.textContent = labelFor(current.type, numberOf(current, 3));
        if (arm) for (const [i, button] of [...arm.children].entries()) button.setAttribute("aria-pressed", String(values.filter((v) => v !== 3)[i] === numberOf(target)));
        if (off) off.node.hidden = numberOf(target, 3) === 3;
      });
      built.body = size === "medium" ? [el("div", { class: "w-row" }, big, arm), off?.node].filter(Boolean) : [el("div", { class: "big-state" }, big), arm, off?.node].filter(Boolean);
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "valve", types: ["Valve"], icon: "drop", tone: "blue", size: "medium",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active"), inUse = ctx.take(primary, "In Use");
      const set = ctx.take(primary, "Set Duration"), remaining = ctx.take(primary, "Remaining Duration");
      ctx.take(primary, "Valve Type");
      // Remaining Duration is sent when the valve opens; the page counts down from there.
      let endsAt = null, lastRemaining;
      const running = () => isOn(inUse) || (isOn(active) && !inUse);
      const left = () => endsAt ? Math.max(0, Math.round((endsAt - Date.now()) / 1000)) : numberOf(remaining);
      ctx.watch(() => {
        if (remaining && remaining.value !== lastRemaining) { lastRemaining = remaining.value; endsAt = running() ? Date.now() + numberOf(remaining) * 1000 : null; }
        if (!running()) endsAt = null;
      });
      const toggleRun = () => ctx.write(primary, active, isOn(active) ? 0 : 1);
      const built = {
        on: () => running(), tap: toggleRun, tapLabel: () => isOn(active) ? "stop" : "run",
        hero: () => running() ? clock(left()) : "",
        status: () => running() ? [`Running · ${clock(left())} left`, "cool"] : isOn(active) ? ["Starting…"] : ["Off"],
      };
      // The figures move each second while it runs.
      const ticker = setInterval(() => {
        if (ctx.node && !ctx.node.isConnected && Date.now() - ctx.born > 2000) { clearInterval(ticker); return; }
        if (running()) ctx.paint();
      }, 1000);
      if (size === "small") return built;
      const px = size === "medium" ? 84 : 140, radius = px / 2 - 6, circumference = 2 * Math.PI * radius;
      const ring = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      ring.setAttribute("viewBox", `0 0 ${px} ${px}`);
      ring.setAttribute("aria-hidden", "true");
      ring.innerHTML = `<circle class="ring-track" cx="${px / 2}" cy="${px / 2}" r="${radius}"/><circle class="ring" cx="${px / 2}" cy="${px / 2}" r="${radius}" stroke-dasharray="${circumference.toFixed(1)}"/>`;
      const title = el("b"), detail = el("span");
      const button = el("button", { type: "button", class: "valve-button", onclick: toggleRun }, ring, el("span", { class: "valve-text" }, title, detail));
      button.style.width = button.style.height = `${px}px`;
      const total = () => numberOf(set, numberOf(remaining, 0)) || 1;
      ctx.watch(() => {
        const on = running();
        title.textContent = isOn(active) ? "Stop" : "Run";
        detail.textContent = on ? `${clock(left())} left` : `for ${clock(numberOf(set, 0))}`;
        ring.querySelector(".ring").style.strokeDashoffset = String(on ? circumference * (1 - clamp(left() / total(), 0, 1)) : circumference);
        button.setAttribute("aria-label", `${isOn(active) ? "Stop" : "Run"} ${ctx.accessory.name}`);
      });
      let durations = null;
      if (canWrite(set)) {
        const choices = [60, 120, 300, 600, 900, 1800].filter((s) => s >= (set.minValue ?? 0) && s <= (set.maxValue ?? 3600));
        if (!choices.includes(numberOf(set)) && numberOf(set) > 0) choices.push(numberOf(set));
        choices.sort((a, b) => a - b);
        const shown = choices.slice(0, 4).includes(numberOf(set)) ? choices.slice(0, 4) : [...choices.slice(0, 3), numberOf(set)];
        const control = segmented(shown.map((s) => ({ value: s, label: s % 60 ? clock(s) : `${s / 60} min` })), "Duration", (v) => ctx.write(primary, set, v));
        ctx.watch(() => control.set(numberOf(set)));
        durations = control.node;
      }
      built.body = size === "medium" ? [el("div", { class: "w-row" }, button, el("div", { class: "w-grow" }, durations))] : [el("div", { class: "valve" }, button, durations)];
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "toggle", types: ["Switch", "Outlet"],
    match: (ctx, primary) => canWrite(ctx.char(primary, "On")),
    icon: (ctx, primary) => primary.type === "Outlet" ? "outlet" : "switch", tone: "green", size: "small",
    build(ctx, primary, size) {
      const on = ctx.take(primary, "On"), inUse = ctx.take(primary, "Outlet In Use");
      const status = () => isOn(on) ? [isOn(inUse) ? "On · in use" : "On"] : ["Off"];
      const turn = (value) => ctx.write(primary, on, onValue(on, value), { held: true });
      if (on.security) {
        // A plugin's security switch (one that unlocks a door): held to turn on, a tap to turn off.
        const built = { on: () => isOn(on), status, hold: { armed: () => !isOn(on), confirm: () => turn(true), tap: () => { if (isOn(on)) turn(false); }, verb: () => isOn(on) ? "turn off" : "hold to turn on" } };
        if (size === "small") return built;
        const turnOn = hold("Hold to turn on", () => turn(true));
        const turnOff = el("button", { type: "button", class: "w-button", text: "Turn off", onclick: () => turn(false) });
        ctx.watch(() => { turnOn.node.hidden = isOn(on); turnOff.hidden = !isOn(on); });
        built.body = [turnOn.node, turnOff];
        if (size === "full") built.facets = facets(ctx, [primary]);
        return built;
      }
      const built = {
        power: { service: primary, characteristic: on, big: size === "medium" },
        tap: () => ctx.write(primary, on, onValue(on, !isOn(on))),
        on: () => isOn(on), status,
      };
      if (size === "large") {
        const button = el("button", { type: "button", class: "power-button", "aria-label": `${ctx.accessory.name}: power`, onclick: built.tap }, icon("power"));
        ctx.watch(() => button.setAttribute("aria-pressed", String(isOn(on))));
        built.power = null;
        const f = facets(ctx, [primary]);
        built.body = [button, f.readouts.length ? el("div", { class: "readouts" }, f.readouts.slice(0, 3)) : null, f.meters[0] ?? null, ...f.blocks.slice(0, 2), chipRow(f.chips)].filter(Boolean);
      }
      if (size === "medium") built.body = [];
      if (size === "full") Object.assign(built, { body: [], facets: facets(ctx, [primary]) });
      return built;
    },
  });

  register({
    name: "sensor", types: Object.keys(readings), icon: (ctx, primary) => readings[primary.type][1], tone: "teal", size: "small",
    build(ctx, primary, size) {
      const one = reading(ctx, primary);
      const value = () => one?.value() ?? { text: "–" };
      const built = {
        on: () => false,
        hero: () => { const v = value(); return el("span", { class: v.text.length > 6 ? "w-hero-word" : "" }, v.text, v.unit ? el("small", { text: v.unit }) : null); },
        status: () => {
          const others = ctx.services.filter((s) => s !== primary && readings[s.type]).map((s) => reading(ctx, s)?.value()).filter(Boolean);
          const v = value();
          return others.length ? [others.map((o) => `${o.text}${o.unit ? ` ${o.unit}` : ""}`).join(" · ")] : [labelFor(one?.main.type ?? "", one?.main.value ?? ""), v.tone === "warn" ? "warn" : ""];
        },
      };
      if (size === "small") return built;
      const f = facets(ctx, []);
      built.body = [el("div", { class: `readouts${size === "medium" ? " three" : ""}` }, size === "medium" ? f.readouts.slice(0, 3) : f.readouts.slice(0, 6)), size !== "medium" ? f.meters[0] : null].filter(Boolean);
      if (size === "full") built.facets = { chips: f.chips, readouts: [], meters: f.meters.slice(1), blocks: f.blocks };
      return built;
    },
  });

  // ---- Frames -----------------------------------------------------------------------------------------

  const categoryIcons = {
    lightbulb: ["bulb", "yellow"], television: ["tv", "blue"], tvSetTopBox: ["tv", "blue"], tvStreamingStick: ["tv", "blue"],
    appleTV: ["tv", "blue"], switch: ["switch", "green"], programmableSwitch: ["switch", "green"], outlet: ["outlet", "green"],
    sensor: ["sensor", "teal"], fan: ["fan", "teal"], airPurifier: ["wind", "teal"], speaker: ["speaker", "blue"], homePod: ["speaker", "blue"],
    audioReceiver: ["speaker", "blue"], doorLock: ["lock", "violet"], thermostat: ["thermo", "yellow"], heater: ["thermo", "yellow"], airConditioner: ["thermo", "teal"],
    garageDoorOpener: ["gate", "violet"], door: ["door", "violet"], window: ["door", "violet"], windowCovering: ["blind", "violet"],
    ipCamera: ["camera", "grey"], videoDoorbell: ["camera", "grey"], faucet: ["drop", "blue"], sprinkler: ["drop", "blue"], securitySystem: ["shield", "violet"],
  };

  /// What no widget claims: the power in the header and the primary service's rows; in full, the rest under More.
  const inspector = {
    name: "inspector", size: "medium",
    build(ctx, primary, size) {
      const power = primary && primary.characteristics.find((c) => (c.type === "On" || c.type === "Active") && canWrite(c));
      if (power) ctx.use(power);
      const list = primary ? rows(ctx, primary) : [];
      const shown = size === "medium" ? list.slice(0, 2) : size === "large" ? list.slice(0, 6) : list;
      return {
        body: shown.length ? [el("div", { class: "controls" }, shown)] : [],
        power: power ? { service: primary, characteristic: power } : null,
        tap: power ? () => ctx.write(primary, power, onValue(power, !isOn(power))) : null,
        on: () => power ? isOn(power) : false,
        status: () => [describeModel(ctx.accessory)],
      };
    },
  };

  function resolve(ctx) {
    const primary = primaryOf(ctx);
    const widget = primary && widgets.find((w) => w.types.includes(primary.type) && (!w.match || w.match(ctx, primary))) || inspector;
    return { widget, primary };
  }
  const defaultOf = (widget, ctx, primary) => typeof widget.size === "function" ? widget.size(ctx, primary) : widget.size;

  /// The kind of widget an accessory gets, and its default size there: what the page keeps defaults by.
  function kindOf(accessory) {
    if (accessory.camera && window.HomeswiftCamera) return { kind: "camera", size: "medium" };
    const ctx = context(accessory);
    const { widget, primary } = resolve(ctx);
    return { kind: widget.name, size: defaultOf(widget, ctx, primary) };
  }

  /// The ⋯ menu: All controls (the full view), then what the page offers for the accessory, else Identify.
  function actionsButton(ctx, full) {
    const items = () => [
      full ? null : { label: "All controls", icon: "edit", onSelect: () => open(ctx.accessory, ctx.options) },
      full ? null : { separator: true },
      ...(ctx.options.actions ? ctx.options.actions(ctx.accessory)
        : [{ label: "Identify", icon: "identify", onSelect: () => api(`/api/accessories/${encodeURIComponent(ctx.accessory.id)}/identify`, { method: "POST" }).catch((e) => alert(e.message)) }]),
    ];
    return menuButton(`Actions for ${ctx.accessory.name}`, items);
  }
  /// What the search box looks in: the names, the room, the plugin and the model.
  const searchText = (accessory) => [accessory.name, accessory.displayName, accessory.room, accessory.platformName, accessory.model].filter(Boolean).join(" ").toLowerCase();

  /// The widget for `accessory` at `size` ("small", "medium", "large"; the kind's default when left out), a box
  /// of the wall's grid: 1×1, 2×1, 2×2.
  function card(accessory, options = {}) {
    const ctx = context(accessory, options);
    ctx.openFull = () => open(accessory, options);
    let node;
    if (accessory.camera && window.HomeswiftCamera) node = cameraTile(ctx, sizes.includes(options.size) ? options.size : "medium");
    else {
      const { widget, primary } = resolve(ctx);
      const size = sizes.includes(options.size) ? options.size : defaultOf(widget, ctx, primary);
      node = frame(ctx, ...built(ctx, widget, primary, size), primary, size);
    }
    ctx.node = node;
    if (Date.now() - swept > 5000) sweep();
    cards.add(ctx);
    return node;
  }

  /// A widget's parts at `size`; a widget that cannot draw this accessory leaves it to the rows rather than off the page.
  function built(ctx, widget, primary, size) {
    try { return [widget, widget.build(ctx, primary, size)]; } catch (e) {
      console.error(`Widget ${widget.name} failed for ${ctx.accessory.name}`, e);
      ctx.used.clear(); ctx.painters.length = 0;
      return [inspector, inspector.build(ctx, primary, size)];
    }
  }

  /// Every control of `accessory`, in a sheet over the page: its widget's, its facets, the rest under More.
  function open(accessory, options = {}) {
    const ctx = context(accessory, options);
    let node;
    if (accessory.camera && window.HomeswiftCamera) node = cameraCard(ctx);
    else {
      const { widget, primary } = resolve(ctx);
      node = fullFrame(ctx, ...built(ctx, widget, primary, "full"), primary);
    }
    ctx.node = node;
    cards.add(ctx);
    const done = el("button", { type: "button", class: "link", text: "Done" });
    const dialog = el("dialog", { class: "widget-sheet", "aria-label": accessory.name }, el("div", { class: "sheet-bar" }, done), node);
    done.addEventListener("click", () => dialog.close());
    // On a phone a swipe down from the grabber or the name puts the sheet away, from where the finger left it.
    if (matchMedia("(max-width: 640px)").matches) {
      node.prepend(el("div", { class: "sheet-grabber", "aria-hidden": "true" }));
      const dismiss = () => {
        const from = getComputedStyle(dialog).transform;
        const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
        const motion = reduce ? [{ opacity: 1 }, { opacity: 0 }] : [{ transform: from === "none" ? "none" : from }, { transform: "translateY(calc(100% + 12px))" }];
        const close = () => dialog.close();
        try { dialog.animate(motion, { duration: reduce ? 140 : 220, easing: "cubic-bezier(0.4, 0, 1, 1)", fill: "forwards" }).finished.then(close, close); } catch { close(); }
      };
      HomeswiftCommon.dragToDismiss(dialog, { vertical: () => true, dismiss, handle: ".sheet-grabber, .widget-full > .w-head" });
    }
    dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); });
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
    return dialog;
  }

  /// The tile's glyph, and a painter for its colour and state.
  function glyphFor(ctx, widget, built, primary) {
    const [fallbackIcon, fallbackTone] = categoryIcons[ctx.accessory.category] || ["generic", "grey"];
    const pick = (value, fallback) => typeof value === "function" ? value(ctx, primary) : value ?? fallback;
    const glyph = el("span", { class: "tile", "aria-hidden": "true" }, icon(pick(widget.icon, fallbackIcon)));
    return [glyph, () => {
      const on = built.on ? built.on() : true;
      const color = on && built.color ? built.color() : null;
      glyph.className = `tile tone-${color ? "light" : pick(built.tone, pick(widget.tone, fallbackTone))}${on ? "" : " is-off"}`;
      glyph.style.setProperty("--light", color?.tile ?? "");
      glyph.style.setProperty("--glow", color?.glow ?? "");
    }];
  }
  function statusPainter(ctx, built, status) {
    return () => {
      const paused = ctx.accessory.paused ? [`Paused · ${ctx.accessory.platformName ?? "its plugin"}`, "warn"] : null;
      const [text, tone] = ctx.flashing ? [ctx.flashing, "bad"] : paused ?? (built.status ? built.status() : [""]);
      status.textContent = text;
      if (tone) status.dataset.tone = tone; else delete status.dataset.tone;
    };
  }
  function powerToggle(ctx, built) {
    if (!built.power) return null;
    const { service, characteristic, big } = built.power;
    const control = toggle(`${ctx.accessory.name}: power`, (on) => ctx.write(service, characteristic, onValue(characteristic, on)));
    if (big) control.node.classList.add("big");
    ctx.watch(() => control.set(isOn(characteristic)));
    return control.node;
  }

  /// A fixed box of the wall: a small tile (a tap acts, or a hold confirms), or a medium or large card with its
  /// header and body; the ⋯ menu at the bottom right.
  function frame(ctx, widget, built, primary, size) {
    const { accessory } = ctx;
    const [glyph, paintGlyph] = glyphFor(ctx, widget, built, primary);
    const status = el("span", { class: "status" });
    const who = el("div", { class: "who" }, el("strong", { text: accessory.displayName || accessory.name, title: accessory.displayName ? `${accessory.name} in the Home app` : null }), status);
    const menu = actionsButton(ctx, false);
    const node = el("article", { class: `card widget size-${size} widget-${widget.name}`, "data-search": searchText(accessory), "data-id": accessory.id });
    if (size === "small") {
      const hero = el("span", { class: "w-hero" });
      const hit = el("button", { type: "button", class: "w-hit" });
      const shade = built.shade ? el("span", { class: "w-shade", "aria-hidden": "true" }) : null;
      if (built.hold) {
        // Held to confirm: the tile fills; let go early and nothing happens. Tapped, the safe action.
        let timer = null;
        const cancel = () => { clearTimeout(timer); timer = null; node.classList.remove("holding"); };
        hit.addEventListener("pointerdown", (event) => {
          if (event.button !== 0 || !built.hold.armed()) return;
          hit.setPointerCapture(event.pointerId);
          node.classList.add("holding");
          timer = setTimeout(() => { cancel(); built.hold.confirm(); }, HOLD_MS);
        });
        for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) hit.addEventListener(type, cancel);
        hit.addEventListener("keydown", (event) => {
          if ((event.key === " " || event.key === "Enter") && !event.repeat && built.hold.armed()) {
            event.preventDefault();
            node.classList.add("holding");
            timer = setTimeout(() => { cancel(); built.hold.confirm(); }, HOLD_MS);
          }
        });
        hit.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") cancel(); });
        hit.addEventListener("click", () => { if (!built.hold.armed()) built.hold.tap(); });
        node.append(el("span", { class: "w-veil", "aria-hidden": "true" }));
      } else hit.addEventListener("click", () => {
        if (slid) { slid = false; return; }
        built.tap ? built.tap() : ctx.openFull();
      });
      hit.addEventListener("contextmenu", (event) => { event.preventDefault(); menu.click(); });
      // A shutter's tile slides: the shade follows the pointer, the position is written when it is let go. A
      // mouse drags at once; a finger holds still a moment first, so a swipe still scrolls the page.
      let sliding = null, slid = false;
      if (built.slide) {
        const { min, max, step } = built.slide;
        let start = null, armed = false, holdTimer = null;
        const at = (event) => {
          const box = node.getBoundingClientRect();
          const share = clamp((event.clientY - box.top) / box.height, 0, 1);
          return clamp(Math.round((min + (1 - share) * (max - min)) / step) * step, min, max);
        };
        hit.addEventListener("pointerdown", (event) => {
          if (event.button !== 0) return;
          start = { x: event.clientX, y: event.clientY, id: event.pointerId };
          armed = event.pointerType === "mouse";
          clearTimeout(holdTimer);
          if (!armed) holdTimer = setTimeout(() => { armed = true; node.classList.add("slide-ready"); }, 350);
        });
        hit.addEventListener("pointermove", (event) => {
          if (!start) return;
          const moved = Math.abs(event.clientY - start.y);
          if (!armed) { if (moved > 6) { clearTimeout(holdTimer); start = null; } return; }
          if (sliding === null && moved < 4) return;
          if (sliding === null) { hit.setPointerCapture(start.id); node.classList.add("sliding"); }
          sliding = at(event);
          ctx.paint();
        });
        const finish = () => {
          clearTimeout(holdTimer);
          node.classList.remove("slide-ready", "sliding");
          if (sliding !== null) { const value = sliding; sliding = null; slid = true; built.slide.commit(value); }
          start = null; armed = false;
        };
        hit.addEventListener("pointerup", finish);
        hit.addEventListener("pointercancel", () => { sliding = null; finish(); slid = false; ctx.paint(); });
        // Once a finger has held still, the page does not scroll under it.
        hit.addEventListener("touchmove", (event) => { if (armed) event.preventDefault(); }, { passive: false });
      }
      node.append(shade ?? "", hit, el("div", { class: "w-top" }, glyph, hero), el("div", { class: "w-bottom" }, who, menu));
      ctx.watch(() => {
        const on = built.on ? built.on() : false;
        node.classList.toggle("on", on);
        const value = sliding !== null ? `${sliding}%` : built.hero ? built.hero() : "";
        hero.replaceChildren(...(value ? [value] : []));
        if (shade) {
          const { min, max } = built.slide ?? { min: 0, max: 100 };
          shade.style.setProperty("--closed", `${sliding !== null ? 100 - (sliding - min) / (max - min) * 100 : built.shade()}%`);
        }
        const verb = built.hold ? built.hold.verb() : built.tap ? (built.tapLabel ? built.tapLabel() : on ? "turn off" : "turn on") : "show all controls";
        hit.setAttribute("aria-label", `${accessory.name}: ${verb}`);
        hit.setAttribute("aria-pressed", String(on));
      });
    } else {
      const body = (built.body || []).filter(Boolean);
      node.append(el("div", { class: "w-head" }, glyph, who, powerToggle(ctx, built)),
        body.length ? el("div", { class: "w-body" }, body) : "", el("span", { class: "w-corner" }, menu));
      node.classList.toggle("head-only", !body.length);
      ctx.watch(() => node.classList.toggle("powered-off", !!built.power && !built.power.big && !isOn(built.power.characteristic)));
    }
    ctx.watch(paintGlyph);
    ctx.watch(statusPainter(ctx, built, status));
    paused(node, ctx);
    return node;
  }

  /// A paused plugin's accessory: drawn quiet, its controls out of reach (inert: no pointer, no focus), its menu
  /// still there to resume the plugin or change the widget.
  function paused(node, ctx) {
    if (!ctx.accessory.paused) return;
    node.classList.add("paused");
    for (const part of node.querySelectorAll(":scope > .w-hit, :scope > .w-body, :scope > .w-head .switch, :scope > .w-main, :scope > .w-split, :scope > details, :scope > .camera-view, :scope > .controls")) part.inert = true;
  }

  /// Every control: the widget's body (beside its facets when there are any), what is left under More, the foot.
  function fullFrame(ctx, widget, built, primary) {
    const { accessory } = ctx;
    const [glyph, paintGlyph] = glyphFor(ctx, widget, built, primary);
    const facetList = built.facets ? facetNodes(built.facets) : [];
    const rest = leftovers(ctx);
    const status = el("span", { class: "status" });
    const body = (built.body || []).filter(Boolean), side = (built.side || []).filter(Boolean);
    const names = rest.map((group) => group.querySelector(".service-name, .control > span")?.textContent).filter(Boolean);
    const split = facetList.length + side.length > 0 && body.length > 0;
    const node = el("article", { class: `card accessory-card widget widget-full widget-${widget.name}`, "data-id": accessory.id },
      el("div", { class: "w-head" }, glyph, el("div", { class: "who" }, el("strong", { text: accessory.name }), status), powerToggle(ctx, built)),
      split ? el("div", { class: "w-split" }, el("div", { class: "w-main" }, body), el("div", { class: "w-side" }, side, facetList))
        : body.length + side.length + facetList.length ? el("div", { class: "w-main" }, body, side, facetList) : null,
      rest.length ? el("details", { class: "more", open: rest.length <= 2 },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, rest)) : null,
      el("div", { class: "card-foot" }, el("span", { class: "muted", text: [describeModel(accessory), accessory.bridge].filter(Boolean).join(" · ") }), actionsButton(ctx, true)));
    if (built.power && !built.power.big) ctx.watch(() => node.classList.toggle("powered-off", !isOn(built.power.characteristic)));
    ctx.watch(paintGlyph);
    ctx.watch(statusPainter(ctx, built, status));
    paused(node, ctx);
    return node;
  }

  // Under a camera's video: its light (a package camera's flashlight), switches and HomeKit camera setting;
  // sensors and the rest under "More".
  const cameraFirst = new Set(["Lightbulb", "Switch", "Outlet", "CameraOperatingMode"]);
  const cameraServiceNames = { CameraOperatingMode: "Camera", Microphone: "Microphone", Speaker: "Speaker" };

  function cameraView(ctx) {
    const { accessory } = ctx;
    const find = (type, characteristic) => accessory.services.find((s) => s.type === type)?.characteristics.find((c) => c.type === characteristic);
    return HomeswiftCamera.view({
      id: accessory.id, name: accessory.name, doorbell: !!accessory.doorbell, lastRing: accessory.lastRing,
      motion: find("MotionSensor", "Motion Detected")?.value === true, recording: find("CameraRecordingManagement", "Active")?.value === 1,
    });
  }

  /// A camera on the wall: its picture fills the box, its name and state over it; a small one opens the full
  /// card when tapped.
  function cameraTile(ctx, size) {
    const view = cameraView(ctx);
    const node = el("article", { class: `card widget size-${size} widget-camera camera-tile`, "data-search": searchText(ctx.accessory), "data-id": ctx.accessory.id },
      view.element, el("span", { class: "w-corner" }, actionsButton(ctx, false)));
    if (size === "small") node.append(el("button", { type: "button", class: "w-hit", "aria-label": `${ctx.accessory.name}: show all controls`, onclick: () => ctx.openFull() }));
    paused(node, ctx);
    return node;
  }

  /// A camera's card: its live video or snapshots on top (camera.js), with its name and state over it, then
  /// its controls. A doorbell's ring shows on the video rather than as a row.
  function cameraCard(ctx) {
    const { accessory } = ctx;
    const view = cameraView(ctx);
    for (const service of accessory.services) for (const c of service.characteristics) if (c.type === "Programmable Switch Event") ctx.use(c);
    // A camera's sensors carry its own name: they read as what they are.
    const named = (service) => {
      const own = !service.name || service.name === accessory.name;
      return own ? { ...service, name: cameraServiceNames[service.type] || service.type.replace(/([a-z])([A-Z])/g, "$1 $2") } : service;
    };
    const first = leftovers(ctx, ctx.services.filter((s) => cameraFirst.has(s.type)).map(named));
    const more = leftovers(ctx, ctx.services.filter((s) => !cameraFirst.has(s.type)).map(named));
    const names = more.map((group) => group.querySelector(".service-name, .control > span")?.textContent).filter(Boolean);
    const subtitle = describeModel(accessory);
    return el("div", { class: "card accessory-card camera-card widget widget-full widget-camera", "data-id": accessory.id },
      view.element,
      subtitle ? el("div", { class: "camera-meta muted", text: subtitle }) : null,
      first.length ? el("div", { class: "controls" }, first) : null,
      more.length ? el("details", { class: "more" },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, more)) : null,
      el("div", { class: "card-foot" }, el("span", { class: "muted", text: accessory.bridge }), actionsButton(ctx, true)));
  }

  // ---- The wall's unit -------------------------------------------------------------------------------------------
  // The wall's columns are squares of 160 px at least (two on a phone, which fill it): as many as fit, widened so the
  // row ends at the wall's right edge instead of leaving a strip. CSS cannot size a square track to a share of the
  // width, so each wall gets its --unit from its width, when it appears and when it resizes.
  const unitMinimum = 160;
  const fitted = new WeakMap();
  function fitWall(wall) {
    const width = wall.clientWidth;
    if (!width || fitted.get(wall) === width) return;
    fitted.set(wall, width);
    const gap = parseFloat(getComputedStyle(wall).columnGap) || 12;
    const columns = width <= 520 ? 2 : Math.max(2, Math.floor((width + gap) / (unitMinimum + gap)));
    wall.style.setProperty("--unit", `${Math.floor(((width - gap * (columns - 1)) / columns) * 100) / 100}px`);
  }
  const resized = new ResizeObserver((entries) => { for (const entry of entries) fitWall(entry.target); });
  // A new wall is sized at once, before it is first drawn at the default unit, then again whenever its width changes.
  const watch = (wall) => { fitWall(wall); resized.observe(wall); };
  // The walls an added or removed node is or holds: a node without children (a log line, a chat word) costs a check.
  const walls = (node) => {
    if (node.nodeType !== 1) return [];
    if (node.classList.contains("wall")) return [node];
    return node.firstElementChild ? [...node.getElementsByClassName("wall")] : [];
  };
  // Walls are in the page's view (the Accessories page, Status's Quick section), a new <main id="view"> for each page:
  // its parent stays, so it is what is watched, and what the chat or a sheet adds to the body is not looked at.
  const view = document.getElementById("view")?.parentElement ?? document.documentElement;
  new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) for (const wall of walls(node)) watch(wall);
      for (const node of record.removedNodes) for (const wall of walls(node)) resized.unobserve(wall);
    }
  }).observe(view, { childList: true, subtree: true });
  for (const wall of walls(view)) watch(wall);

  window.HomeswiftWidgets = {
    card, open, kindOf, sizes, event, listen, describeModel, labelFor, enumLabels,
    /// A page's own widget, tried before the built-in ones: { name, types, match?, icon, tone, size, build }.
    register: (widget) => widgets.unshift(widget),
    /// The controls the widgets are made of, for a page's own widget.
    controls: { toggle, segmented, level, steps, setpoint, gauge, readout, meter, chip, hold, pill, icon },
  };
})();
