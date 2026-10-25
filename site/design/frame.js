(() => {
  const { el } = HomeswiftCommon;
  const { t } = HomeswiftI18n;
  let accessory;
  window.designApplyWrite = (body) => {
    const owner = accessory.services.find((one) => (one.subtype || one.type) === body.service);
    if (!owner) return;
    const changes = [{ service: body.service, characteristic: body.characteristic, value: body.value }];
    const pair = { "Target Door State": "Current Door State", "Lock Target State": "Lock Current State", "Target Position": "Current Position" }[body.characteristic];
    if (pair && owner.characteristics.some((one) => one.type === pair)) changes.push({ service: body.service, characteristic: pair, value: body.value });
    for (const change of changes) HomeswiftWidgets.event({ id: accessory.id, ...change });
    parent.postMessage({ type: "design-action", changes }, location.origin);
  };
  const sizeNames = { small: t("Small"), medium: t("Medium"), large: t("Large"), xlarge: t("Extra large") };
  function render(message) {
    document.documentElement.dataset.theme = message.theme;
    window.designDemoState = message.state;
    accessory = structuredClone(message.accessory);
    if (message.state === "paused") accessory.paused = true;
    if (message.state === "unavailable") accessory.unavailable = true;
    if (message.state === "readonly") for (const s of accessory.services) for (const c of s.characteristics) c.permissions = c.permissions.filter((one) => one !== "pw");
    const view = document.getElementById("view");
    view.replaceChildren();
    if (message.kind === "widget") {
      const wall = el("div", { class: "wall" }); view.append(wall);
      const actions = () => [{ label: t("Size"), choices: HomeswiftWidgets.sizes.map((size) => ({ label: sizeNames[size], badge: ({small: "S", medium: "M", large: "L", xlarge: "XL"})[size], checked: size === message.size,
        onSelect: () => parent.postMessage({ type: "design-size", size }, location.origin) })) }];
      wall.append(HomeswiftWidgets.card(accessory, { size: message.size, actions }));
    } else {
      const card = el("div", { class: "card characteristic-demo" }); view.append(card);
      const service = accessory.services[0], characteristic = service.characteristics[0];
      const row = characteristic.protocolOnly ? el("div") : HomeswiftWidgets.characteristicRow(accessory, service, characteristic);
      if (row.childElementCount) { row.inert = !!accessory.paused; card.append(row); }
      else card.append(el("p", { class: "protocol-note", text: t(characteristic.protocolOnly ? "This protocol field has no standalone control. It stays out of everyday accessory controls." : "This characteristic has no standalone control in this state.") }));
    }
    parent.postMessage({ type: "design-rendered" }, location.origin);
  }
  addEventListener("message", (event) => {
    if (event.source !== parent || event.origin !== location.origin) return;
    if (event.data?.type === "design-render") render(event.data);
    if (event.data?.type === "design-value" && accessory) {
      HomeswiftWidgets.event({ id: accessory.id, ...event.data.change });
    }
    if (event.data?.type === "design-theme") document.documentElement.dataset.theme = event.data.theme;
  });
  new ResizeObserver(() => parent.postMessage({ type: "design-height", height: Math.ceil(document.body.getBoundingClientRect().height) }, location.origin)).observe(document.body);
  parent.postMessage({ type: "design-ready" }, location.origin);
})();
