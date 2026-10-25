// The Wingman page: the paired Wingmen (refreshed every two seconds while the page is visible, a card redrawn only
// when it changed), the Wingmen Bonjour finds, one added by its address, and pairing: the certificate this bridge
// sees, to compare with Wingman's Bridges tab, then the six-digit code its menu shows. Pairing writes the Wingman's
// entry in this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, act, updateDevices, poll, renderKeyed } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");
  const discoverBox = $("#discovered");
  const addBox = $("#add-wingman");

  /// AB:CD:… for people: the first `bytes` bytes, as Wingman's window shows them.
  const formatFingerprint = (hex, bytes) => (hex || "").replace(/[^0-9a-f]/gi, "").toUpperCase().slice(0, bytes * 2).replace(/(..)(?!$)/g, "$1:");

  // MARK: config.json: the block's `devices`, one entry per Wingman by its id (plugin.js keeps the list).

  const putEntry = (entry) => updateDevices((devices) => {
    const index = devices.findIndex((d) => d.id === entry.id);
    if (index >= 0) devices[index] = { ...devices[index], ...entry }; else devices.push(entry);
  });

  const removeEntry = (id) => updateDevices((devices) => {
    const index = devices.findIndex((d) => d.id === id);
    if (index >= 0) devices.splice(index, 1);
  });

  // MARK: The paired Wingmen

  function stateOf(wingman) {
    switch (wingman.state) {
      case "connected": return [t("Connected"), "on"];
      case "connecting": return [t("Connecting…"), "standby"];
      case "unpaired": return [t("Pair again"), "away"];
      default: return [t("Not reachable"), "away"];
    }
  }

  function wingmanCard(wingman) {
    const [state, kind] = stateOf(wingman);
    const homes = (wingman.homes || []).join(", ");
    const updated = wingman.lastContact ? t("updated {when}", { when: ago(wingman.lastContact) }) : null;
    const quiet = (wingman.notResponding ?? 0) > 0;
    return el("div", { class: "card wingman" },
      el("div", { class: "server-head" },
        tile("bridge", wingman.state === "connected" ? "blue" : "grey"),
        el("div", { class: "who" }, el("strong", { text: wingman.name }), el("div", { class: "muted", text: [homes || t("Apple Home"), updated].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts three" },
        fact(t("Accessories"), String(wingman.accessories ?? 0)),
        el("div", { class: `fact${quiet ? " warn" : ""}` }, el("span", { text: t("Not responding") }), el("b", { text: String(wingman.notResponding ?? 0) })),
        el("div", { class: "fact", title: t("Homeswift's own accessories, and those left out in the settings") }, el("span", { text: t("Left out") }), el("b", { text: String(wingman.leftOut ?? 0) }))),
      wingman.error ? el("p", { class: "error note", text: wingman.error }) : null,
      wingman.error ? explain({
        error: `Wingman ${wingman.name} at ${wingman.host}:${wingman.port}: ${wingman.error}`,
        context: "The Homeswift Wingman plugin reads GET /homes from Wingman over TLS (certificate pinned at pairing) and follows GET /events?since=&wait=25.",
        device: { state: wingman.state, pinned: wingman.pinned },
      }) : null,
      wingman.state === "unpaired" ? el("p", { class: "muted note", text: t("Wingman no longer knows this bridge. Find it on the network and pair it again.") }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [wingman.host && `${wingman.host}:${wingman.port}`, wingman.pinned ? t("Certificate pinned") : null].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: wingman.name }), () => [
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(homeswift.platform)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Wingman {name}: ", { name: wingman.name })) } : null,
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => forget(wingman) },
        ])));
  }

  async function forget(wingman) {
    if (!confirm(t("Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.", { name: wingman.name }))) return;
    await removeEntry(wingman.id);
    setTimeout(refresh, 600);
  }

  const shown = new Set();
  function card(wingman) {
    const node = wingmanCard(wingman);
    if (shown.has(wingman.id)) node.classList.add("redrawn");
    shown.add(wingman.id);
    return node;
  }

  async function refresh() {
    try {
      const { wingmen } = await request("wingmen");
      if (!wingmen.length) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then find it on the network here.") })));
        }
        if (discoverBox.classList.contains("hidden") && !discoveredOnce) openDiscovered();
        return;
      }
      renderKeyed(list, wingmen, (wingman) => wingman.id, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: On the network

  let discoveredOnce = false;

  function foundRow(wingman) {
    const [state, kind] = wingman.error ? [t("Not answering"), "away"] : wingman.paired ? [t("Paired"), "on"] : wingman.pairing ? [t("Pairing open"), "on"] : [t("Not paired"), "standby"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: wingman.name }),
        el("div", { class: "muted", text: [`${wingman.host}:${wingman.port}`, wingman.version && t("version {version}", { version: wingman.version })].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      wingman.error || !wingman.fingerprint ? null
        : el("button", { class: wingman.paired ? "" : "primary", text: wingman.paired ? t("Pair again") : t("Pair"), onclick: (event) => openPairing(wingman, event.currentTarget.closest(".found")) }));
  }

  async function renderDiscovered() {
    discoveredOnce = true;
    discoverBox.replaceChildren(el("p", { class: "muted", text: t("Looking for Wingman on the network…") }));
    try {
      const { wingmen } = await request("discover");
      discoverBox.replaceChildren(
        el("p", { class: "muted", text: t("The Wingman apps Bonjour finds on this network. Pairing needs the Mac at hand: Wingman shows the code.") }),
        ...(wingmen.length ? wingmen.map(foundRow)
          : [el("p", { class: "muted", text: t("No Wingman announces itself. Is Homeswift Wingman running, with Advertise over Bonjour on? Across networks or from a container, add it by its address.") })]),
        el("div", { class: "actions" }, el("button", { text: t("Look again"), onclick: (event) => act(event.currentTarget, renderDiscovered) })));
    } catch (e) {
      discoverBox.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  function openDiscovered() {
    discoverBox.classList.remove("hidden");
    $("#discover-toggle").setAttribute("aria-expanded", "true");
    renderDiscovered();
  }

  $("#discover-toggle").addEventListener("click", () => {
    if (discoverBox.classList.contains("hidden")) openDiscovered();
    else { discoverBox.classList.add("hidden"); $("#discover-toggle").setAttribute("aria-expanded", "false"); }
  });

  // MARK: Adding by address, for networks Bonjour does not cross

  const host = el("input", { type: "text", placeholder: "192.168.1.20", inputmode: "decimal", spellcheck: false, "aria-label": t("IP address or host name") });
  const port = el("input", { type: "number", value: 8619, min: 1, max: 65535, "aria-label": t("Port") });
  const addStatus = el("p", { class: "status-line muted" });
  addBox.replaceChildren(
    el("p", { class: "muted", text: t("For a Wingman Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then you pair it.") }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, probe, (message) => { addStatus.className = "status-line error"; addStatus.textContent = message; }); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("IP address or host name") }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: t("Port") }), port),
      el("button", { class: "primary", type: "submit", text: t("Find") })),
    addStatus);
  $("#add-toggle").addEventListener("click", () => {
    const open = addBox.classList.toggle("hidden") === false;
    $("#add-toggle").setAttribute("aria-expanded", String(open));
    if (open) host.focus();
  });

  async function probe() {
    const address = host.value.trim();
    if (!address) throw new Error(t("Enter the Mac's IP address or host name."));
    addStatus.className = "status-line muted";
    addStatus.textContent = t("Asking {host}:{port}…", { host: address, port: port.value });
    const { wingman } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    addStatus.textContent = "";
    openPairing(wingman, addStatus);
  }

  // MARK: Pairing: compare the certificate, then the code. The panel opens under the row whose Pair was pressed (or
  // the address form), so it reads as that Wingman's; one at a time.

  let pairing = null;

  function closePairing(panel) {
    panel.remove();
    if (pairing === panel) pairing = null;
  }

  function openPairing(wingman, anchor) {
    pairing?.remove();
    const code = el("input", { class: "code-input", type: "text", inputmode: "numeric", autocomplete: "one-time-code", enterkeyhint: "done", maxLength: 7, placeholder: "000 000", "aria-label": t("Pairing code") });
    const label = el("input", { type: "text", value: wingman.name, maxLength: 64, "aria-label": t("Name") });
    const status = el("p", { class: "status-line muted", "aria-live": "polite" });
    const submit = el("button", { class: "primary", type: "submit", text: t("Pair") });
    const panel = el("div", { class: "pair" });
    const close = () => closePairing(panel);
    const report = (message) => { status.className = "status-line error"; status.textContent = message; code.select(); };
    const form = el("form", { class: "pair-form", onsubmit: (event) => { event.preventDefault(); act(submit, () => pair(wingman, code.value, label.value, panel), report); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Name") }), label),
      el("div", { class: "code-row" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Pairing code") }), code),
        submit,
        el("button", { type: "button", text: t("Cancel"), onclick: close })));
    // The code as Wingman shows it, 482 913; the sixth digit pairs, as a one-time code does on a phone.
    code.addEventListener("input", () => {
      const digits = code.value.replace(/\D/g, "").slice(0, 6);
      code.value = digits.length > 3 ? `${digits.slice(0, 3)} ${digits.slice(3)}` : digits;
      status.textContent = "";
      if (digits.length === 6 && !submit.disabled) form.requestSubmit(submit);
    });
    panel.replaceChildren(
      el("h3", { text: t("Pair {name}", { name: wingman.name }) }),
      el("ol", { class: "muted pair-steps" },
        el("li", { text: t("In Wingman's menu, choose Pair a Homeswift Bridge. It shows a code for ten minutes.") }),
        el("li", { text: t("In Wingman's window, Bridges tab, check that the certificate starts as below.") }),
        el("li", { text: t("Type the code here.") })),
      el("div", { class: "fingerprint" },
        el("span", { class: "muted", text: t("Certificate SHA-256, as this bridge sees it") }),
        el("code", { text: `${formatFingerprint(wingman.fingerprint, 6)}…` })),
      form, status);
    anchor.after(panel);
    pairing = panel;
    panel.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "nearest" });
    code.focus();
  }

  async function pair(wingman, code, name, panel) {
    const digits = code.replace(/\D/g, "");
    if (digits.length !== 6) throw new Error(t("The code has six digits."));
    const { device } = await request("pair", { method: "POST", body: { host: wingman.host, port: wingman.port, code: digits, fingerprint: wingman.fingerprint, name: name.trim() } });
    await putEntry(device);
    panel.replaceChildren(el("p", { class: "status-line ok", text: t("Paired with {name}. Its Apple Home accessories appear on the Accessories page in a moment.", { name: device.name || wingman.name }) }));
    setTimeout(() => { closePairing(panel); if (!discoverBox.classList.contains("hidden")) renderDiscovered(); }, 4000);
    setTimeout(refresh, 800);
  }

  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  poll(refresh);
})();
