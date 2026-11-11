// The Wingman page: the paired Wingmen, refreshed every two seconds while the page is visible, a card redrawn only
// when it changed. A Wingman is found and paired on Add accessories (Setup: the certificate to compare, then the
// six-digit code its menu shows): the page leads there. It writes no settings (docs/adr/0002-schema-declares-every-setting.md):
// a Wingman's Settings sheet Excludes or Forgets it, and the plugin's Settings list the mirrored accessories and bridges.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, platform, poll, renderKeyed, setupCard, setupAddress } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");

  // MARK: Where settings are edited: the plugin's Settings page (its devices: the Wingmen, the mirrored accessories and
  // the bridges), and each Wingman's Settings sheet there.

  const settingsOf = (id) => homeswift.accessorySettings(`${platform}:${id}`);

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
          { label: t("Settings"), icon: "gear", href: settingsOf(wingman.id) },
        ])));
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

  // MARK: Apple Home's hidden groups: those of fewer than two accessories, which the Home app does not show. An
  // interrupted creation can leave one: it keeps its name (a group of that name is refused) and counts towards HomeKit's
  // limit. Each can be removed, or all of them, once confirmed.

  const hidden = $("#hidden-groups");

  async function loadHiddenGroups() {
    let answer;
    try { answer = await request("empty-groups"); } catch (e) {
      hidden.replaceChildren(el("div", { class: "card hidden-groups" }, el("p", { class: "muted note", text: e.status === 409 ? t("Link this bridge to its home in Apple Home to see its hidden groups.") : e.message })));
      return;
    }
    const groups = answer.groups || [];
    const show = (...children) => hidden.replaceChildren(el("div", { class: "card hidden-groups" }, ...children));
    const why = el("p", { class: "muted note", text: t("Groups of fewer than two accessories, which the Home app does not show. An interrupted group creation can leave one: it keeps the name, so a new group of that name is refused, and it counts towards Apple Home's limit.") });
    if (!groups.length) {
      show(why, el("p", { class: "note", text: t("No hidden groups in {home}.", { home: answer.home }) }));
      return;
    }
    show(why,
      el("div", { class: "rows" }, groups.map((group) => el("div", { class: "row" },
        el("div", { class: "who" }, el("strong", { text: group.name }),
          el("span", { class: "muted", text: group.accessories ? t("1 accessory") : t("No accessories") })),
        el("button", { type: "button", class: "icon-button danger", "aria-label": t("Remove {name}", { name: group.name }), title: t("Remove {name}", { name: group.name }),
          onclick: (event) => removeGroups(event.currentTarget, [group], answer.home) }, HomeswiftCommon.icon("trash"))))),
      el("div", { class: "actions" }, el("button", { type: "button", class: "danger", actionIcon: "trash", text: t("Remove all"),
        onclick: (event) => removeGroups(event.currentTarget, groups, answer.home) })));
  }

  async function removeGroups(button, groups, home) {
    const one = groups.length === 1;
    const confirmed = await HomeswiftCommon.confirmAction({
      title: one ? t("Remove the group {name}?", { name: groups[0].name }) : tn("Remove {n} hidden group?", "Remove {n} hidden groups?", groups.length),
      text: one ? t("It is removed from {home} in Apple Home. Its accessories stay as they are.", { home })
        : t("They are removed from {home} in Apple Home. Their accessories stay as they are.", { home }),
      confirmLabel: t("Remove"), confirmIcon: "trash" });
    if (!confirmed) return;
    // Disabled while it runs, so a second click does not remove them again.
    await HomeswiftCommon.busyButton(button, async () => {
      const result = await request("empty-groups/remove", { method: "POST", body: { ids: groups.map((group) => group.id) } });
      const failed = (result.failed || []).map((group) => t("{name}: {error}", { name: group.name, error: group.error }));
      if (failed.length) HomeswiftCommon.showAlert(failed.join("\n"));
    });
    loadHiddenGroups();
  }

  loadHiddenGroups();

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
