// The Assistant's chat, on every page of the web UI (plugin pages load it through plugin.js): a sparkle button
// in the header opens a panel where the Assistant answers and acts through the bridge's tools. Each change it
// wants to make shows a card with what would change, and waits for Allow. The mic dictates a message (the
// browser's speech recognition, which needs HTTPS away from localhost); an answer to a spoken message is read
// out.
//
// Motion after Apple's fluid interfaces: the panel comes from its button and goes back to it on one spring
// that any tap or drag can retarget; on a phone it is a sheet that follows the finger, resists past the top
// and closes when a flick would carry it past half its height. Reduced motion cross-fades instead.
(() => {
  "use strict";
  const { $, el, icon, markdown, sparkle, api, jsonView } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const phone = matchMedia("(max-width: 640px)");
  const touch = matchMedia("(pointer: coarse)");
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  // ---- A spring, after Apple's damping ratio and response (no mass, stiffness, damping to tune) ----------

  /// Moves `state.value` to `target` frame by frame from where it is and as fast as it goes, so a new target
  /// mid-flight bends the motion instead of restarting it. `onFrame` draws each value.
  function spring(state, target, { damping = 1, response = 0.35, velocity, onFrame, onRest } = {}) {
    cancelAnimationFrame(state.frame);
    if (velocity !== undefined) state.velocity = velocity;
    if (reducedMotion.matches) {
      state.value = target;
      state.velocity = 0;
      onFrame(target);
      onRest?.();
      return;
    }
    const stiffness = (2 * Math.PI / response) ** 2;
    const friction = 4 * Math.PI * damping / response;
    let last = performance.now();
    const step = (now) => {
      const dt = Math.min((now - last) / 1000, 1 / 30);
      last = now;
      const force = -stiffness * (state.value - target) - friction * state.velocity;
      state.velocity += force * dt;
      state.value += state.velocity * dt;
      if (Math.abs(state.value - target) < 0.001 && Math.abs(state.velocity) < 0.01) {
        state.value = target;
        state.velocity = 0;
        onFrame(target);
        onRest?.();
        return;
      }
      onFrame(state.value);
      state.frame = requestAnimationFrame(step);
    };
    state.frame = requestAnimationFrame(step);
  }

  /// Where a flick comes to rest, as a scroll view decelerates.
  const project = (velocity, rate = 0.998) => (velocity / 1000) * rate / (1 - rate);
  /// The further past the edge, the less the sheet follows.
  const rubberband = (over, size, constant = 0.55) => (over * size * constant) / (size + constant * Math.abs(over));

  // ---- The panel -------------------------------------------------------------------------------------------

  let info = null;      // what /api/assistant answered
  let panel = null;     // the parts, once built
  const openness = { value: 0, velocity: 0, frame: 0 };
  let items = [];
  let nodes = [];
  let running = false;
  let usage = null;
  let spoken = false;   // the running turn started from the mic: read its answer out
  let trigger = null;
  let session = 0;      // a sign-out moves it on: a stream read before it stops drawing

  function build() {
    const log = el("div", { class: "chat-log", "aria-live": "polite", "aria-relevant": "additions" });
    const input = el("textarea", { rows: 1, placeholder: t("Ask, or tell it what to set up…"), "aria-label": t("Message to the Assistant"), maxLength: 4000 });
    const mic = el("button", { type: "button", class: "chat-mic", "aria-label": t("Dictate"), title: t("Dictate: tap, or hold while you speak") });
    mic.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/></svg>';
    const send = el("button", { type: "submit", class: "chat-send", "aria-label": t("Send") });
    send.innerHTML = '<svg class="send-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5M6 11l6-6 6 6"/></svg>'
      + '<svg class="stop-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>';
    const foot = el("p", { class: "chat-foot" });
    // The language spoken to the mic and in which answers are read out; this browser remembers it.
    const languages = [["", t("Browser's language")], ["en-US", "English (US)"], ["en-GB", "English (UK)"], ["fr-FR", "Français"], ["de-DE", "Deutsch"],
      ["es-ES", "Español"], ["it-IT", "Italiano"], ["nl-NL", "Nederlands"], ["pt-PT", "Português"], ["pt-BR", "Português (Brasil)"],
      ["sv-SE", "Svenska"], ["da-DK", "Dansk"], ["nb-NO", "Norsk"], ["fi-FI", "Suomi"], ["pl-PL", "Polski"], ["ja-JP", "日本語"], ["zh-CN", "中文"]];
    let stored = "";
    try { stored = localStorage.getItem("homeswift.voiceLanguage") || ""; } catch {}
    const languagePicker = el("select", { class: "popup", "aria-label": t("Voice language") },
      languages.map(([value, text]) => el("option", { value, text, selected: value === stored })));
    languagePicker.addEventListener("change", () => { try { localStorage.setItem("homeswift.voiceLanguage", languagePicker.value); } catch {} });
    const voice = Recognition ? el("div", { class: "chat-voice" }, el("span", { text: t("Voice") }), languagePicker) : null;
    const form = el("form", { class: "chat-composer", onsubmit: (event) => { event.preventDefault(); running ? stop() : submit(); } },
      input, Recognition ? mic : null, send);
    const close = el("button", { type: "button", class: "chat-icon", "aria-label": t("Close"), title: t("Close (Esc)"), text: "×", onclick: () => toggle(false) });
    const fresh = el("button", { type: "button", class: "chat-icon", "aria-label": t("New chat"), title: t("New chat"), onclick: reset });
    fresh.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>';
    const earlier = el("button", { type: "button", class: "chat-icon", "aria-label": t("Earlier chats"), title: t("Earlier chats"), "aria-expanded": "false", onclick: () => showHistory() }, icon("history"));
    const head = el("div", { class: "chat-head" },
      el("span", { class: "chat-grabber", "aria-hidden": "true" }),
      sparkle(), el("strong", { id: "chat-title", text: t("Assistant") }), el("span", { class: "chat-model", text: info.model || "" }),
      el("span", { class: "spacer" }), earlier, fresh, close);
    const sheet = el("section", { class: "chat", role: "dialog", "aria-labelledby": "chat-title", hidden: true },
      el("div", { class: "chat-glow", "aria-hidden": "true" }),
      el("div", { class: "chat-surface" }, head, log, form, voice, foot));
    const scrim = el("div", { class: "chat-scrim", hidden: true, onclick: () => toggle(false) });
    document.body.append(scrim, sheet);
    panel = { sheet, scrim, log, input, mic, send, foot, head, languagePicker, earlier };

    input.addEventListener("input", grow);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); form.requestSubmit(); }
    });
    sheet.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); listening ? stopListening(true) : toggle(false); }
    });
    if (Recognition) setUpMic();
    setUpDrag();
    setUpKeyboard();
    renderControls();
  }

  /// Safari keeps the layout viewport, and so a fixed sheet's bottom, under the on-screen keyboard: the phone
  /// sheet sits on the keyboard instead (`--keyboard`, what it covers) and fits in what is left above it.
  function setUpKeyboard() {
    const view = window.visualViewport;
    if (!view) return;
    const fit = () => {
      const covered = phone.matches ? Math.max(0, Math.round(window.innerHeight - view.height - view.offsetTop)) : 0;
      panel.sheet.style.setProperty("--keyboard", `${covered}px`);
      panel.sheet.style.setProperty("--visible", `${Math.round(view.height)}px`);
      panel.sheet.classList.toggle("keyboard", covered > 80);
    };
    view.addEventListener("resize", fit);
    view.addEventListener("scroll", fit);
    fit();
  }

  /// The text field grows with what is typed, up to a few lines.
  function grow() {
    panel.input.style.height = "auto";
    panel.input.style.height = `${Math.min(panel.input.scrollHeight, 140)}px`;
  }

  const isOpen = () => panel && !panel.sheet.hidden && openness.target === 1;

  /// The panel at `value` (0 closed, 1 open). It fades through `--open` on its surface, never through its own
  /// opacity: an ancestor with opacity would keep the surface's backdrop blur from seeing the page.
  function draw(value) {
    const { sheet, scrim } = panel;
    const fade = (amount) => sheet.style.setProperty("--open", String(Math.max(0, Math.min(1, amount))));
    if (reducedMotion.matches) {
      sheet.style.transform = "";
      fade(value);
    } else if (phone.matches) {
      sheet.style.transform = `translateY(${(1 - value) * 100}%)`;
      fade(1);
    } else {
      // Out of the button and back into it: a small move toward it, a slight scale, the material arriving.
      sheet.style.transform = `translate(${(1 - value) * 24}px, ${(1 - value) * -12}px) scale(${0.94 + 0.06 * value})`;
      fade(value * 1.4);
    }
    scrim.style.opacity = String(Math.max(0, Math.min(1, value)) * (phone.matches ? 1 : 0));
  }

  async function toggle(open = !isOpen(), velocity) {
    if (!panel) build();
    openness.target = open ? 1 : 0;
    const { sheet, scrim } = panel;
    trigger?.setAttribute("aria-expanded", String(open));
    if (open) {
      sheet.hidden = false;
      scrim.hidden = !phone.matches;
      if (openness.value === 0) draw(0);
      load();
      // A touch screen keeps its keyboard down until the field is tapped: up at once, it would cover the sheet.
      if (!touch.matches) setTimeout(() => panel.input.focus({ preventScroll: true }), 50);
    } else if (listening) {
      stopListening(true);
    }
    spring(openness, openness.target, {
      damping: velocity ? 0.8 : 1, response: phone.matches ? 0.32 : 0.3, velocity, onFrame: draw,
      onRest: () => {
        if (openness.target === 0) {
          sheet.hidden = true;
          scrim.hidden = true;
          trigger?.focus({ preventScroll: true });
        }
      },
    });
  }

  /// The phone sheet follows a drag on its head: 1:1, softer past the top, and a flick decides.
  function setUpDrag() {
    const { head, sheet } = panel;
    head.addEventListener("pointerdown", (event) => {
      if (!phone.matches || event.target.closest("button")) return;
      head.setPointerCapture(event.pointerId);
      cancelAnimationFrame(openness.frame);
      const height = sheet.getBoundingClientRect().height;
      const startY = event.clientY;
      const startValue = openness.value;
      let samples = [{ y: event.clientY, t: event.timeStamp }];
      const move = (moveEvent) => {
        let value = startValue - (moveEvent.clientY - startY) / height;
        if (value > 1) value = 1 + rubberband(value - 1, 1);
        openness.value = value;
        draw(value);
        samples = [...samples.slice(-4), { y: moveEvent.clientY, t: moveEvent.timeStamp }];
      };
      const end = () => {
        head.removeEventListener("pointermove", move);
        head.removeEventListener("pointerup", end);
        head.removeEventListener("pointercancel", end);
        const first = samples[0], last = samples[samples.length - 1];
        const pxPerSecond = last.t > first.t ? ((last.y - first.y) / (last.t - first.t)) * 1000 : 0;
        const velocity = -pxPerSecond / height;   // openness per second
        const projected = openness.value + project(-pxPerSecond) / height;
        toggle(projected > 0.5, velocity);
      };
      head.addEventListener("pointermove", move);
      head.addEventListener("pointerup", end);
      head.addEventListener("pointercancel", end);
    });
  }

  // ---- The conversation ---------------------------------------------------------------------------------

  let loaded = false;
  async function load() {
    if (loaded) return;
    loaded = true;
    try {
      // The conversation so far, then the run going on, if any.
      await follow(await api("/api/assistant/chat", { stream: true }));
    } catch (e) {
      loaded = false;
      showError(e.message);
    }
    renderControls();
  }

  function page() {
    const path = location.pathname.split("/").filter(Boolean);
    if (path[0] === "plugins" && path.length === 2 && document.querySelector('meta[name="homeswift-plugin"]')) return `plugin page of ${decodeURIComponent(path[1])}`;
    return path[0] || "status";
  }

  async function submit(text = panel.input.value.trim(), byVoice = false) {
    if (!text || running) return;
    panel.input.value = "";
    grow();
    spoken = byVoice;
    window.speechSynthesis?.cancel();
    running = true;
    renderControls();
    try {
      follow(await api("/api/assistant/chat", { method: "POST", body: { text, page: page() }, stream: true }));
    } catch (e) {
      running = false;
      renderControls();
      showError(e.message);
    }
  }

  async function stop() {
    try { await api("/api/assistant/chat/stop", { method: "POST", body: {} }); } catch (e) { showError(e.message); }
  }

  async function reset() {
    if (running) await stop();
    try { await api("/api/assistant/chat", { method: "DELETE" }); } catch (e) { showError(e.message); return; }
    closeHistory();
    setItems([], false);
    usage = null;
    renderControls();
    panel.input.focus();
  }

  /// Reads a run's event stream: a snapshot, then items, text and the end.
  async function follow(response) {
    const own = session;
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    running = true;
    renderControls();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        // Signed out meanwhile: what is left of the run is not drawn.
        if (own !== session) { reader.cancel().catch(() => {}); return; }
        buffer += decoder.decode(value, { stream: true });
        let end;
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const event = frame.match(/^event: (.*)$/m)?.[1];
          const data = frame.match(/^data: (.*)$/m)?.[1];
          if (event && data) handle(event, JSON.parse(data));
        }
      }
    } catch (e) {
      if (own === session) showError(t("The connection dropped: {error}", { error: e.message }));
    }
    if (own !== session) return;
    running = false;
    renderControls();
  }

  function handle(event, data) {
    if (historyOpen && event !== "snapshot") closeHistory();
    switch (event) {
    case "snapshot": setItems(data.items, data.running); if (data.usage) usage = data.usage; break;
    case "item": items[data.index] = data.item; renderItem(data.index); break;
    case "delta": {
      const item = items[data.index];
      if (item) { item.text += data.text; scheduleText(data.index); }
      break;
    }
    case "done":
      usage = data.usage;
      if (spoken) speak(items.findLast((item) => item.kind === "assistant")?.text);
      spoken = false;
      break;
    }
  }

  // ---- Earlier conversations ----------------------------------------------------------------------------------
  // The bridge keeps each user's conversations (the open one and the 10 before it): New chat files the open one
  // away, and one picked here opens again where it was, the Assistant remembering it.

  let historyOpen = false;
  async function showHistory() {
    if (historyOpen) { closeHistory(); return; }
    historyOpen = true;
    panel.earlier.setAttribute("aria-expanded", "true");
    const list = el("div", { class: "chat-history", role: "region", "aria-label": t("Earlier chats") }, el("p", { class: "muted", text: t("Loading…") }));
    panel.log.replaceChildren(list);
    let chats;
    try { chats = await api("/api/assistant/chats"); } catch (e) { list.replaceChildren(el("p", { class: "chat-error", text: e.message })); return; }
    if (!historyOpen) return;
    const when = new Intl.DateTimeFormat(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" });
    const rows = chats.map((chat) => {
      const row = el("div", { class: `chat-history-row${chat.current ? " current" : ""}` },
        el("button", { type: "button", class: "chat-history-open", onclick: () => openChat(chat) },
          el("strong", { text: chat.title }),
          el("span", { class: "muted", text: [when.format(new Date(chat.updated)), tn("{n} message", "{n} messages", chat.messages), chat.current ? t("open [chat]") : null].filter(Boolean).join(" · ") })),
        el("button", { type: "button", class: "chat-icon", "aria-label": t("Forget “{title}”", { title: chat.title }), title: t("Forget this chat"), text: "×", onclick: async () => {
          try { await api(`/api/assistant/chats/${encodeURIComponent(chat.id)}`, { method: "DELETE" }); } catch (e) { showError(e.message); return; }
          row.remove();
          if (chat.current) { setItems([], false); historyOpen = false; showHistory(); }
        } }));
      return row;
    });
    list.replaceChildren(el("h2", { text: t("Earlier chats") }),
      rows.length ? el("div", { class: "chat-history-list" }, rows) : el("p", { class: "muted", text: t("No chat yet. Each one you start is kept here, the last ten.") }),
      el("button", { actionIcon: "restore", type: "button", class: "link", text: t("Back to the chat"), onclick: closeHistory }));
  }

  async function openChat(chat) {
    if (running) await stop();
    if (!chat.current) {
      try { await api(`/api/assistant/chats/${encodeURIComponent(chat.id)}/open`, { method: "POST", body: {} }); } catch (e) { showError(e.message); return; }
    }
    closeHistory(false);
    loaded = false;
    usage = null;
    await load();
    panel.input.focus();
  }

  /// Back to the conversation; `redraw` false when another one is about to load.
  function closeHistory(redraw = true) {
    if (!historyOpen) return;
    historyOpen = false;
    panel.earlier.setAttribute("aria-expanded", "false");
    if (redraw) setItems(items, running);
  }

  // ---- Drawing the conversation --------------------------------------------------------------------------

  function setItems(next, isRunning) {
    items = next.slice();
    running = isRunning;
    nodes = [];
    panel.log.replaceChildren();
    if (!items.length) panel.log.append(welcome());
    items.forEach((_, index) => renderItem(index, false));
    renderControls();
    scrollToEnd(true);
  }

  /// Suggestions for an empty conversation.
  function welcome() {
    const suggestions = [t("Add a device for me"), t("What does my bridge run?"), t("Why is an accessory not responding?"), t("Turn off every light")];
    return el("div", { class: "chat-welcome" },
      sparkle(),
      el("h2", { text: t("What can I do for you?") }),
      el("p", { class: "muted", text: t("I can look at your bridge, set up a device with its plugin, or change a setting. I ask before I change anything.") }),
      el("div", { class: "chat-suggestions" }, suggestions.map((text) => el("button", { type: "button", text, onclick: () => submit(text) }))));
  }

  function renderItem(index, scroll = true) {
    const item = items[index];
    if (!item) return;
    panel.log.querySelector(".chat-welcome")?.remove();
    const node = itemNode(item);
    const old = nodes[index];
    if (old) old.replaceWith(node); else panel.log.append(node);
    nodes[index] = node;
    renderControls();
    if (scroll) scrollToEnd();
  }

  // Streaming text is drawn once per frame, however many pieces arrive.
  const pendingText = new Set();
  function scheduleText(index) {
    if (!pendingText.size) requestAnimationFrame(() => {
      for (const i of pendingText) {
        const body = nodes[i]?.querySelector(".chat-text");
        if (body) body.replaceChildren(...markdown(items[i].text).childNodes);
      }
      pendingText.clear();
      scrollToEnd();
    });
    pendingText.add(index);
  }

  function itemNode(item) {
    switch (item.kind) {
    case "user":
      return el("div", { class: "chat-user" }, el("p", { text: item.text }));
    case "assistant":
      return el("div", { class: "chat-answer" }, el("div", { class: "chat-text md" }, ...markdown(item.text).childNodes));
    case "tool":
      return el("div", { class: `chat-step ${item.state}`, title: item.name },
        el("span", { class: "chat-step-mark", "aria-hidden": "true" }),
        el("span", {}, el("span", { class: "chat-step-title", text: item.title }), item.summary ? el("span", { class: "chat-step-summary", text: ` · ${item.summary}` }) : null),
        el("span", { class: "visually-hidden", text: ` ${{ running: t("(running)"), failed: t("(failed)"), declined: t("(not allowed)") }[item.state] ?? t("(done)")}` }));
    case "confirm":
      return confirmCard(item);
    default:
      return el("p", { class: "chat-error", role: "alert", text: HomeswiftI18n.message(item.text) });
    }
  }

  /// A change the Assistant wants to make: what it is in words, the details on demand, and the choice.
  function confirmCard(item) {
    const pending = item.state === "pending";
    const answer = (allow) => async (event) => {
      event.currentTarget.closest(".chat-confirm").querySelectorAll("button").forEach((button) => { button.disabled = true; });
      try { await api("/api/assistant/chat/confirm", { method: "POST", body: { id: item.id, allow } }); } catch (e) { showError(e.message); }
    };
    const changes = changeList(item.preview);
    const details = el("details", {},
      el("summary", { text: changes ? t("The whole request") : item.preview !== undefined ? t("What would change") : t("Details") }),
      jsonView(changes ? item.arguments : item.preview ?? item.arguments));
    return el("div", { class: `chat-confirm ${item.state}` },
      el("div", { class: "chat-confirm-head" }, el("strong", { text: describe(item) }),
        pending ? null : el("span", { class: `pill status ${item.state === "allowed" ? "on" : "standby"}`, text: item.state === "allowed" ? t("Allowed") : t("Not allowed") })),
      el("p", { text: pending ? t("{title}. Nothing changes until you allow it.", { title: item.title }) : item.title }),
      changes,
      details,
      pending ? el("div", { class: "chat-confirm-actions" },
        el("button", { actionIcon: "close", type: "button", text: t("Don't allow"), onclick: answer(false) }),
        el("button", { actionIcon: "check", type: "button", class: "primary", text: t("Allow"), onclick: answer(true) })) : null);
  }

  /// What a config dry run would change, a line per setting with its new value; null for other previews.
  function changeList(preview) {
    if (!preview || !Array.isArray(preview.changes) || !preview.config) return null;
    const valueAt = (path) => path.match(/[^.[\]]+/g).reduce((value, key) => value?.[/^\d+$/.test(key) ? Number(key) : key], preview.config);
    const shown = (value) => value === undefined ? t("removed") : value === "__REDACTED__" ? t("(secret, kept)") : JSON.stringify(value);
    const lines = preview.changes.slice(0, 8).map((path) => el("li", {},
      el("code", { text: path.replace(/^platforms\[\d+\]\./, "") }), " ", el("span", { text: `→ ${shown(valueAt(path))}`.slice(0, 120) })));
    if (preview.changes.length > 8) lines.push(el("li", { class: "muted", text: tn("and {n} more", "and {n} more", preview.changes.length - 8) }));
    return lines.length ? el("ul", { class: "chat-changes" }, lines) : el("p", { class: "muted", text: t("Nothing would change.") });
  }

  /// A change in a sentence, from the tool and its arguments.
  function describe({ tool, arguments: args = {} }) {
    const entry = args.entry || {};
    const settings = Object.keys(args.settings || {});
    switch (tool) {
    case "put_list_entry":
      return entry.name || entry.mac
        ? t("Save “{entry}” in {block}?", { entry: entry.name || entry.mac, block: args.name || args.platform })
        : t("Save this entry in {block}?", { block: args.name || args.platform });
    case "patch_config":
      return settings.length
        ? t("Change {settings} of {block}?", { settings: settings.join(", "), block: args.name || args.platform })
        : t("Change the settings of {block}?", { block: args.name || args.platform });
    case "update_config": return t("Replace the whole config.json? A backup is kept.");
    case "restore_config": return t("Restore config.json from {backup}?", { backup: args.backup });
    case "restart_bridge": return t("Restart homeswift? Connections drop for a few seconds.");
    case "set_security_accessory": return t("Set {characteristic} to {value} on {id}?", { characteristic: args.characteristic, value: JSON.stringify(args.value), id: args.id });
    default: return t("Allow {tool}?", { tool });
    }
  }

  function showError(text) {
    if (!panel) return;
    panel.log.append(el("p", { class: "chat-error", role: "alert", text }));
    scrollToEnd();
  }

  /// Keeps the newest line in view, unless the person scrolled up to read.
  function scrollToEnd(force = false) {
    const { log } = panel;
    if (force || log.scrollHeight - log.scrollTop - log.clientHeight < 120) log.scrollTop = log.scrollHeight;
  }

  /// The send button turns into stop while the Assistant works; the glow turns around the panel meanwhile.
  function renderControls() {
    if (!panel) return;
    const { sheet, send, foot, log } = panel;
    sheet.classList.toggle("working", running);
    log.setAttribute("aria-busy", String(running));
    send.classList.toggle("stop", running);
    send.setAttribute("aria-label", running ? t("Stop") : t("Send"));
    send.title = running ? t("Stop") : t("Send (Enter)");
    const waiting = running && !items.some((item) => item.kind === "confirm" && item.state === "pending") && items[items.length - 1]?.kind !== "assistant";
    let thinking = log.querySelector(".chat-thinking");
    if (waiting && !thinking) log.append(thinking = el("p", { class: "chat-thinking", text: t("Thinking…") }));
    if (waiting) log.append(thinking);   // stays last
    if (!waiting) thinking?.remove();
    const provider = info.provider || t("Assistant");
    const cost = usage && usage.cost != null && usage.cost > 0
      ? new Intl.NumberFormat(HomeswiftI18n.locale, { style: "currency", currency: "USD", minimumFractionDigits: usage.cost < 0.01 ? 4 : 2, maximumFractionDigits: usage.cost < 0.01 ? 4 : 2 }).format(usage.cost) : null;
    foot.textContent = listening ? t("Listening… tap the mic again when you are done.") : voiceNote
      || (cost ? t("{provider} · {cost} so far. Changes always ask first.", { provider, cost }) : t("{provider}. Changes always ask first.", { provider }));
  }

  // ---- Voice ------------------------------------------------------------------------------------------------

  let recognition = null;
  let listening = false;
  let voiceNote = "";

  function setUpMic() {
    const { mic } = panel;
    if (!window.isSecureContext) {
      mic.classList.add("unavailable");
      mic.title = t("Voice needs HTTPS: turn on https in the HomeswiftUI settings, or open this page on localhost.");
    }
    let pressedAt = 0;
    mic.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      pressedAt = event.timeStamp;
      if (!listening) startListening();
      else stopListening(false);
    });
    // Held down and let go: push to talk. A tap keeps listening until the next tap or a pause.
    mic.addEventListener("pointerup", (event) => {
      if (listening && event.timeStamp - pressedAt > 400) stopListening(false);
    });
    mic.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); listening ? stopListening(false) : startListening(); }
    });
  }

  function startListening() {
    if (!window.isSecureContext) {
      voiceNote = t("Voice needs HTTPS here: turn on https in Plugins › HomeswiftUI › Settings (or open the page on localhost).");
      renderControls();
      return;
    }
    // A press while an answer runs still listens: the words wait in the field until the answer is done.
    if (recognition) return;   // the last one is still finishing
    voiceNote = "";
    window.speechSynthesis?.cancel();
    const current = new Recognition();
    recognition = current;
    current.lang = voiceLanguage();
    current.interimResults = true;
    current.continuous = false;
    const before = panel.input.value ? `${panel.input.value} ` : "";
    let finalText = "";
    current.onresult = (event) => {
      let interim = "";
      finalText = "";
      for (const result of event.results) {
        if (result.isFinal) finalText += result[0].transcript; else interim += result[0].transcript;
      }
      panel.input.value = before + finalText + interim;
      grow();
    };
    current.onerror = (event) => {
      voiceNote = event.error === "not-allowed" || event.error === "service-not-allowed"
        ? t("The browser did not allow the microphone for this page.")
        : event.error === "no-speech" ? t("Nothing was heard. Tap the mic and speak.") : t("Voice stopped: {error}.", { error: event.error });
    };
    current.onend = () => {
      if (recognition !== current) return;
      const send = current.sendWhenDone !== false;
      listening = false;
      recognition = null;
      panel.sheet.classList.remove("listening");
      if (send && finalText.trim() && running) voiceNote = t("Your words are in the field: send them once the answer is done.");
      renderControls();
      const text = panel.input.value.trim();
      if (send && finalText.trim() && text && !running) submit(text, true);
    };
    try {
      current.start();
    } catch (e) {
      recognition = null;
      voiceNote = t("Voice did not start: {error}", { error: e.message });
      renderControls();
      return;
    }
    listening = true;
    panel.sheet.classList.add("listening");
    renderControls();
  }

  /// `cancel` keeps the words in the field without sending them.
  function stopListening(cancel) {
    if (!recognition) return;
    recognition.sendWhenDone = !cancel;
    recognition.stop();
  }

  /// An answer to a spoken message, read out: plain text, without Markdown's marks.
  function speak(text) {
    if (!text || !window.speechSynthesis) return;
    // Tables: the delimiter rows go, cells are read as a list.
    const plain = text.replace(/```[\s\S]*?```/g, "").replace(/^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/gm, "").replace(/\s*\|\s*/g, ", ")
      .replace(/[*_`#>~]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
    const utterance = new SpeechSynthesisUtterance(plain);
    utterance.lang = voiceLanguage();
    speechSynthesis.speak(utterance);
  }

  // ---- The button in the header -----------------------------------------------------------------------------

  async function mount() {
    try {
      info = await api("/api/assistant");
    } catch { return; }
    if (!info.enabled) return;
    const header = $("header");
    if (!header || header.querySelector(".chat-open")) return;
    const shortcut = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘K" : "Ctrl+K";
    trigger = el("button", {
      type: "button", class: "chat-open", "aria-expanded": "false", "aria-haspopup": "dialog", "aria-label": t("Assistant"), title: t("Ask the Assistant ({shortcut})", { shortcut }),
      "aria-keyshortcuts": "Meta+K Control+K", onclick: () => toggle(),
    }, sparkle());
    header.insertBefore(trigger, header.querySelector("#user"));
    // Cmd+K (Ctrl+K elsewhere) opens the chat from anywhere, and closes it, as Glass UI's palette.
    document.addEventListener("keydown", (event) => {
      // Not from the sign-in screen: the button is in the hidden app then.
      if (!trigger?.isConnected || trigger.closest(".hidden")) return;
      if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "k" && !event.isComposing) {
        event.preventDefault();
        toggle();
      }
    });
    phone.addEventListener("change", () => { if (isOpen()) { panel.scrim.hidden = !phone.matches; draw(openness.value); } });
  }

  /// Opens the chat with `text` typed in, for the person to finish and send.
  function ask(text) {
    toggle(true);
    panel.input.value = text;
    grow();
    setTimeout(() => { panel.input.focus(); panel.input.setSelectionRange(text.length, text.length); }, 60);
  }

  /// Signed out (app.js): the panel closes at once and forgets the conversation it shows, so whoever signs in next
  /// on this browser starts from their own.
  function signedOut() {
    session++;
    if (!panel) return;
    if (listening) stopListening(true);
    window.speechSynthesis?.cancel();
    cancelAnimationFrame(openness.frame);
    openness.value = 0;
    openness.velocity = 0;
    openness.target = 0;
    panel.sheet.hidden = true;
    panel.scrim.hidden = true;
    trigger?.setAttribute("aria-expanded", "false");
    closeHistory(false);
    items = [];
    nodes = [];
    running = false;
    usage = null;
    spoken = false;
    loaded = false;
    panel.input.value = "";
    panel.log.replaceChildren();
    renderControls();
  }

  /// The language chosen for voice, else the page's.
  const voiceLanguage = () => panel?.languagePicker.value || HomeswiftI18n.locale || "en-US";

  window.HomeswiftChat = { mount, ask, signedOut, open: () => toggle(true), available: () => Boolean(info?.enabled) };
  // The UI's own page mounts it once signed in; a plugin page is signed in already.
  if (document.querySelector('meta[name="homeswift-plugin"]')) mount();
})();
