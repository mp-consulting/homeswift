// Dashboard groups retain original accessories and send controls to their shared capabilities.
(() => {
  const { el, api, menuButton } = HomeswiftCommon;
  const { t } = HomeswiftI18n;
  const allowed = new Set(['Lightbulb', 'Switch', 'Outlet', 'Fan', 'Fanv2', 'WindowCovering']);
  const deviceTypes = [
    ['Lightbulb', 'bulb', t('Lights')], ['Switch', 'switch', t('Switches')],
    ['Outlet', 'outlet', t('Outlets')], ['Fan', 'fan', t('Fans')], ['WindowCovering', 'accessory', t('Blinds')]
  ];
  const deviceType = (a) => deviceTypes.find(([type]) => a.services.some((s) => s.type === type || (type === 'Fan' && s.type === 'Fanv2'))) || ['', 'accessory', t('Accessories')];
  const types = ['On', 'Active', 'Brightness', 'Color Temperature', 'Hue', 'Saturation', 'Rotation Speed', 'Target Position'];
  const controls = (a) => {
    const result = new Map();
    for (const s of a?.services || []) if (allowed.has(s.type)) {
      for (const c of s.characteristics) if (types.includes(c.type) && c.permissions.includes('pw')) {
        // Ambiguous multi-service accessories are not grouped.
        if (result.has(c.type)) return new Map();
        result.set(c.type, { service: s.subtype || s.type, c });
      }
    }
    return result;
  };
  const shared = (members) => types.filter((type) => members.length && members.every((a) => controls(a).has(type)));
  const compatible = (members) => shared(members).some((type) => ['On', 'Active', 'Target Position'].includes(type));
  function mount({ all, layout, persist, refresh }) {
    layout.groups ||= [];
    const byID = new Map(all.map((a) => [a.id, a]));
    const members = (id) => layout.groups.find((g) => g.id === id)?.members || [id];
    const canJoin = (a, b) => a !== b && compatible([...new Set([...members(a), ...members(b)])].map((id) => byID.get(id)));
    async function edit(ids = [], existing = null) {
      const selected = new Set(existing?.members || ids);
      const name = el('input', { value: existing?.name || t('Accessory group'), maxLength: 64, required: true });
      const message = el('p', { role: 'status', class: 'error' });
      const occupied = new Set(layout.groups.filter((g) => g !== existing && !ids.includes(g.id)).flatMap((g) => g.members));
      const choices = all.filter((a) => selected.has(a.id) || (!occupied.has(a.id) && controls(a).size));
      const list = el('div', { class: 'group-member-list', 'aria-label': t('Available') });
      const selectedList = el('div', { class: 'group-member-list', 'aria-label': t('Selected') });
      const selectedCount = el('span', { class: 'pill status on' });
      const selectedEmpty = el('p', { class: 'muted', text: t('Choose at least two accessories with shared controls.') });
      const rows = choices.map((a) => {
        const button = el('button', { type: 'button', class: 'group-transfer' });
        const row = el('div', { class: 'group-member-row', 'data-search': (a.displayName || a.name).toLowerCase(), 'data-type': deviceType(a)[0] },
          el('span', { class: 'group-device-icon', title: deviceType(a)[2], 'aria-hidden': 'true' }, HomeswiftCommon.icon(deviceType(a)[1])),
          el('span', { class: 'group-member-name', text: a.displayName || a.name }), button);
        const update = () => {
          const chosen = selected.has(a.id);
          button.textContent = chosen ? '−' : '+';
          button.setAttribute('aria-label', `${chosen ? t('Remove') : t('Add')}: ${a.displayName || a.name}`);
          (chosen ? selectedList : list).append(row);
          row.hidden = false;
          selectedCount.textContent = String(selected.size);
          selectedEmpty.hidden = selected.size > 0;
        };
        button.addEventListener('click', () => {
          if (selected.has(a.id)) selected.delete(a.id); else selected.add(a.id);
          update(); applyFilter(); button.focus();
        });
        update(); return row;
      });
      const save = el('button', { type: 'submit', class: 'primary', text: t('Save') });
      const dialog = el('dialog', { class: 'admin-dialog accessory-group-dialog', 'aria-label': t('Accessory group') });
      const search = el('input', { type: 'search', class: 'search', placeholder: t('Search accessories'), 'aria-label': t('Search accessories') });
      let activeType = '';
      const empty = el('p', { class: 'muted', hidden: true, text: t('No accessory matches.') });
      const applyFilter = () => {
        for (const row of list.children) row.hidden = (activeType && row.dataset.type !== activeType) || !row.dataset.search.includes(search.value.trim().toLowerCase());
        empty.hidden = [...list.children].some((row) => !row.hidden);
      };
      const typeFilter = el('div', { class: 'group-type-filter', role: 'group', 'aria-label': t('Device type') },
        [['', 'grid', t('All')], ...deviceTypes.filter(([type]) => choices.some((a) => deviceType(a)[0] === type))].map(([type, glyph, label]) =>
          el('button', { type: 'button', 'aria-pressed': String(type === activeType), onclick: (event) => {
            activeType = type;
            for (const button of typeFilter.children) button.setAttribute('aria-pressed', String(button === event.currentTarget));
            applyFilter();
          } }, HomeswiftCommon.icon(glyph), el('span', { text: label }))));
      search.addEventListener('input', applyFilter);
      const form = el('form', {}, el('div', { class: 'group-dialog-head' }, HomeswiftCommon.tile('grid', 'blue'), el('h2', { text: t('Accessory group') })), el('label', { class: 'group-name-field' }, el('span', { text: t('Name') }), name),
        el('div', { class: 'group-picker-columns' },
          el('section', {}, el('h3', { text: t('Available') }), search, typeFilter, list, empty),
          el('section', {}, el('div', { class: 'group-selected-heading' }, el('h3', { text: t('Selected') }), selectedCount), selectedList, selectedEmpty)), message,
        el('div', { class: 'actions' }, el('button', { type: 'button', text: t('Cancel'), onclick: () => dialog.close() }), save));
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        if (selected.size < 2 || !compatible([...selected].map((id) => byID.get(id)))) { message.textContent = t('Choose at least two accessories with shared controls.'); return; }
        save.disabled = true;
        const before = layout.groups;
        layout.groups = before.filter((g) => g !== existing && !g.members.some((id) => selected.has(id)));
        layout.groups.push({ id: existing?.id || `group:${crypto.randomUUID()}`, name: name.value.trim(), members: [...selected] });
        try { await persist(); dialog.close(); refresh(); } catch (error) { layout.groups = before; message.textContent = error.message; save.disabled = false; }
      });
      dialog.append(form); document.body.append(dialog); dialog.addEventListener('close', () => dialog.remove(), { once: true }); dialog.showModal();
    }
    const cards = new Set();
    function card(group, editing) {
      const people = group.members.map((id) => byID.get(id));
      const result = el('p', { class: 'group-feedback', role: 'status' });
      const body = el('div', { class: 'group-controls' });
      const draw = () => {
        if (body.contains(document.activeElement)) return;
        body.replaceChildren(...shared(people).map((type) => {
          const targets = people.map((a) => controls(a).get(type));
          const values = targets.map(({ c }) => c.value);
          const mixed = values.some((v) => v !== values[0]);
          const isBool = type === 'On' || type === 'Active';
          const low = Math.max(...targets.map(({ c }) => c.minValue ?? 0));
          const high = Math.min(...targets.map(({ c }) => c.maxValue ?? (type === 'Hue' ? 360 : 100)));
          if (!isBool && low > high) return null;
          const input = el('input', isBool ? { type: 'checkbox', checked: Boolean(values[0]), disabled: editing } : { type: 'range', min: low, max: high, step: Math.max(...targets.map(({ c }) => c.minStep || 1)), value: values[0] ?? low, disabled: editing });
          input.setAttribute('aria-label', type); if (isBool) input.indeterminate = mixed;
          const state = el('span', { class: 'muted', text: mixed ? t('Mixed') : String(values[0] ?? '—') });
          input.addEventListener('change', async () => {
            input.disabled = true;
            const value = isBool ? (type === 'Active' ? Number(input.checked) : input.checked) : Number(input.value);
            const outcomes = await Promise.allSettled(people.map((a, i) => api(`/api/accessories/${encodeURIComponent(a.id)}`, { method: 'PUT', body: { service: targets[i].service, characteristic: type, value } })));
            outcomes.forEach((outcome, i) => { if (outcome.status === 'fulfilled') targets[i].c.value = value; });
            const failed = outcomes.flatMap((outcome, i) => outcome.status === 'rejected' ? [people[i].displayName || people[i].name] : []);
            result.textContent = failed.length ? t('Could not update: {names}', { names: failed.join(', ') }) : '';
            input.disabled = editing; input.blur(); draw();
          });
          return el('label', {}, el('span', { text: type }), input, state);
        }).filter(Boolean));
        if (people.some((a) => !a)) result.textContent = t('Some group members are unavailable.');
      };
      const node = el('div', { class: 'widget size-large accessory-group', 'data-id': group.id, 'data-search': [group.name, ...people.map((a) => a?.name || '')].join(' ').toLowerCase() },
        el('div', { class: 'server-head' }, HomeswiftCommon.tile('grid', 'blue'), el('div', { class: 'who' }, el('strong', { text: group.name }), el('div', { class: 'muted', text: people.map((a) => a?.displayName || a?.name || '—').join(', ') })),
          menuButton(t('Actions for {name}', { name: group.name }), () => [
            { label: t('Edit group'), icon: 'edit', onSelect: () => edit([], group) },
            { label: t('Ungroup'), icon: 'grid', onSelect: async () => {
              const before = layout.groups; layout.groups = before.filter((g) => g !== group);
              try { await persist(); refresh(); } catch (error) { layout.groups = before; result.textContent = error.message; }
            } }
          ])), body, result);
      draw(); cards.add({ node, draw }); return node;
    }
    return { card, edit, canJoin, join: (a, b) => {
      const target = layout.groups.find((g) => g.id === b) || layout.groups.find((g) => g.id === a);
      const ids = [...new Set([...members(a), ...members(b)])];
      return edit(ids, target ? { ...target, members: ids } : null);
    }, event: (event) => {
      const a = byID.get(event.id); if (!a) return;
      for (const s of a.services) if ((s.subtype || s.type) === (event.subtype || event.service)) for (const c of s.characteristics) if (c.type === event.characteristic) c.value = event.value;
      for (const item of cards) { if (!item.node.isConnected) cards.delete(item); else item.draw(); }
    } };
  }
  window.HomeswiftGroups = { mount };
})();
