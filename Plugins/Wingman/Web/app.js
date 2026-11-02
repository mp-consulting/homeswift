// The Wingman page: the paired Wingmen, refreshed every two seconds while the page is visible, a card redrawn only
// when it changed. A Wingman is found and paired on Add accessories (Setup: the certificate to compare, then the
// six-digit code its menu shows): the page leads there.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, api, platform, name: instance, updateBlock, poll, renderKeyed, setupCard, setupAddress } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");

  // MARK: config.json: a Wingman paired before Setup has an entry in the block's `devices`, by its id; one Setup paired
  // has its Accessory Settings (`_accessories`, by its id), and leaves as Add accessories excludes it.

  async function removeEntry(id) {
    let listed = false;
    await updateBlock((block) => {
      const devices = block.devices || [];
      listed = devices.some((d) => d.id === id);
      if (!listed) return;
      block.devices = devices.filter((d) => d.id !== id);
      if (!block.devices.length) delete block.devices;
    });
    if (!listed) await api("/api/setup/exclude", { method: "POST", body: { platform, name: instance, deviceID: id, excluded: true } });
  }

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
      wingman.state === "unpaired" ? el("p", { class: "muted note", text: t("Wingman no longer knows this bridge. Pair it again on Add accessories.") }) : null,
      wingman.state === "unpaired" ? el("div", { class: "actions" }, el("a", { class: "button primary", href: setupAddress(), actionIcon: "pair", text: t("Pair again") })) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [wingman.host && `${wingman.host}:${wingman.port}`, wingman.pinned ? t("Certificate pinned") : null].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: wingman.name }), () => [
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(homeswift.platform)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Wingman {name}: ", { name: wingman.name })) } : null,
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => forget(wingman) },
        ])));
  }

  async function forget(wingman) {
    if (!await HomeswiftCommon.confirmDialog(t("Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.", { name: wingman.name }))) return;
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
            el("p", { class: "muted", text: t("No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then pair it on Add accessories.") })));
        }
        return;
      }
      renderKeyed(list, wingmen, (wingman) => wingman.id, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: Pairing a Wingman: Add accessories finds it (or takes the address in the plugin's settings) and pairs it.

  $("#setup").replaceChildren(setupCard({
    title: t("Pair a Wingman"),
    text: t("Add accessories finds Homeswift Wingman on this network: compare its certificate, then type the code its menu shows. For a Mac Bonjour does not reach, add its address to this plugin's settings first."),
    glyph: "pair", tone: "orange", start: false,
  }));

  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  poll(refresh);
})();
