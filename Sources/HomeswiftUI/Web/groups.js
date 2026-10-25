// Dashboard groups retain original accessories and send controls to their shared capabilities.
(() => {
  const { el, api, menuButton } = HomeswiftCommon;
  const { t } = HomeswiftI18n;
  const allowed = new Set(['Lightbulb', 'Switch', 'Outlet', 'Fan', 'Fanv2', 'WindowCovering']);
  const deviceTypes = [
    ['Lightbulb', 'bulb', t('Lights')], ['Switch', 'switch', t('Switches')],
    ['Outlet', 'outlet', t('Outlets')], ['Fan', 'fan', t('Fans')], ['WindowCovering', 'blind', t('Blinds')]
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
  // Follow the first visible member in saved member order, not the first wall on the page.
  // This also gives mixed-room/plugin groups a stable home without moving any accessories.
  function sectionIndex(group, sections) {
    for (const id of group.members) {
      const index = sections.findIndex(([, accessories]) => accessories.some((a) => a.id === id));
      if (index !== -1) return index;
    }
    return -1;
  }
  function mount({ all, layout, persist, refresh, moveToRoom, rooms = [], setGroupRoom }) {
    layout.groups ||= [];
    const byID = new Map(all.map((a) => [a.id, a]));
    const members = (id) => layout.groups.find((g) => g.id === id)?.members || [id];
    const canJoin = (a, b) => a !== b && compatible([...new Set([...members(a), ...members(b)])].map((id) => byID.get(id)));
    async function edit(ids = [], existing = null) {
      const selected = new Set(existing?.members || ids);
      const name = el('input', { value: existing?.name || t('Accessory group'), maxLength: 64, required: true });
      const initialRooms = [...selected].map((id) => byID.get(id)?.room || '');
      const initialRoom = initialRooms.length && initialRooms.every((room) => room === initialRooms[0]) ? initialRooms[0] : '__keep__';
      const roomSelect = el('select', {},
        el('option', { value: '__keep__', text: t('Keep current rooms') }),
        el('option', { value: '', text: t('No room') }),
        [...new Set([...rooms, ...all.map((a) => a.room).filter(Boolean)])].map((room) => el('option', { value: room, text: room })));
      roomSelect.value = initialRoom;
      const message = el('p', { role: 'status', class: 'error' });
      const occupied = new Set(layout.groups.filter((g) => g !== existing && !ids.includes(g.id)).flatMap((g) => g.members));
      const choices = all.filter((a) => selected.has(a.id) || (!occupied.has(a.id) && controls(a).size));
      const roomLabels = new Map([...roomSelect.options].map((option) => [option.value, option.textContent]));
      const list = el('div', { class: 'group-member-list', 'aria-label': t('Available') });
      const selectedList = el('div', { class: 'group-member-list', 'aria-label': t('Selected') });
      const selectedCount = el('span', { class: 'pill status on' });
      const selectedEmpty = el('p', { class: 'muted', text: t('Choose at least two accessories with shared controls.') });
      const rows = choices.map((a) => {
        const button = el('button', { type: 'button', class: 'group-transfer' });
        const row = el('div', { class: 'group-member-row', 'data-search': (a.displayName || a.name).toLowerCase(), 'data-type': deviceType(a)[0], 'data-room': a.room || '' },
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
      const clearFilters = el('button', { type: 'button', class: 'clear-filters group-clear-filters', actionIcon: 'restore', text: t('Clear filters'), onclick: () => {
        search.value = '';
        activeType = '';
        roomSelect.value = '__keep__';
        for (const [index, button] of [...typeFilter.children].entries()) button.setAttribute('aria-pressed', String(index === 0));
        applyFilter();
      } });
      const empty = el('p', { class: 'muted', hidden: true, text: t('No accessory matches.') });
      const applyFilter = () => {
        clearFilters.disabled = !search.value && !activeType && roomSelect.value === '__keep__';
        const query = search.value.trim().toLowerCase();
        for (const button of typeFilter.children) {
          const count = [...list.children].filter((row) => (!button.dataset.type || row.dataset.type === button.dataset.type) && (roomSelect.value === '__keep__' || row.dataset.room === roomSelect.value) && row.dataset.search.includes(query)).length;
          button.querySelector('.filter-count').textContent = String(count);
          button.disabled = count === 0 && Boolean(button.dataset.type) && button.dataset.type !== activeType;
          button.title = button.disabled ? t("No accessories match the current search.") : "";
        }
        const matching = [...list.children].filter((row) => (!activeType || row.dataset.type === activeType) && row.dataset.search.includes(query));
        const matches = new Set(matching);
        for (const row of list.children) row.hidden = !matches.has(row) || (roomSelect.value !== '__keep__' && row.dataset.room !== roomSelect.value);
        for (const option of roomSelect.options) {
          const count = matching.filter((row) => option.value === '__keep__' || row.dataset.room === option.value).length;
          option.textContent = `${roomLabels.get(option.value)} (${count})`;
          option.disabled = option.value !== '__keep__' && option.value !== roomSelect.value && count === 0;
          option.title = option.disabled ? t("No accessories match the current search.") : "";
        }
        empty.hidden = [...list.children].some((row) => !row.hidden);
      };
      const typeFilter = el('div', { class: 'group-type-filter', role: 'group', 'aria-label': t('Device type') },
        [['', 'grid', t('All')], ...deviceTypes.filter(([type]) => choices.some((a) => deviceType(a)[0] === type))].map(([type, glyph, label]) =>
          el('button', { type: 'button', 'data-type': type, 'aria-pressed': String(type === activeType), onclick: (event) => {
            activeType = type;
            for (const button of typeFilter.children) button.setAttribute('aria-pressed', String(button === event.currentTarget));
            applyFilter();
          } }, HomeswiftCommon.icon(glyph), el('span', { text: label }), el('span', { class: 'filter-count' }))));
      search.addEventListener('input', applyFilter);
      roomSelect.addEventListener('change', applyFilter);
      applyFilter();
      const form = el('form', {}, el('div', { class: 'group-dialog-head' }, HomeswiftCommon.tile('group', 'blue'), el('h2', { text: t('Accessory group') })), el('label', { class: 'group-name-field' }, el('span', { text: t('Name') }), name),
        setGroupRoom ? el('label', { class: 'group-room-field' }, el('span', { text: t('Room') }), roomSelect, el('span', { class: 'help', text: t('Moves the selected accessories in Homeswift only. HomeKit rooms stay unchanged.') })) : null,
        el('div', { class: 'group-picker-columns' },
          el('section', {}, el('h3', { text: t('Available') }), search, typeFilter, clearFilters, list, empty),
          el('section', {}, el('div', { class: 'group-selected-heading' }, el('h3', { text: t('Selected') }), selectedCount), selectedList, selectedEmpty)), message,
        el('div', { class: 'actions' }, el('button', { type: 'button', text: t('Cancel'), onclick: () => dialog.close() }), save));
      const content = el('div', { class: 'group-dialog-content' });
      while (form.children.length > 1) content.append(form.firstElementChild);
      form.prepend(content);
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        if (selected.size < 2 || !compatible([...selected].map((id) => byID.get(id)))) { message.textContent = t('Choose at least two accessories with shared controls.'); return; }
        save.disabled = true;
        const before = layout.groups;
        layout.groups = before.filter((g) => g !== existing && !g.members.some((id) => selected.has(id)));
        layout.groups.push({ id: existing?.id || `group:${crypto.randomUUID()}`, name: name.value.trim(), members: [...selected] });
        let saved = false;
        try {
          await persist(); saved = true;
          if (setGroupRoom && roomSelect.value !== '__keep__') await setGroupRoom([...selected], roomSelect.value);
          dialog.close(); refresh();
        } catch (error) {
          if (!saved) layout.groups = before;
          message.textContent = error.message; save.disabled = false;
        }
      });
      dialog.append(form); document.body.append(dialog); dialog.addEventListener('close', () => dialog.remove(), { once: true }); dialog.showModal();
    }
    const cards = new Set();
    function card(group, editing) {
      const people = group.members.map((id) => byID.get(id));
      const memberTypes = people.map((accessory) => accessory ? deviceType(accessory) : null);
      const matchingType = memberTypes[0]?.[0] && memberTypes.every((type) => type?.[0] === memberTypes[0][0]);
      const groupIcon = matchingType ? memberTypes[0][1] : 'group';
      const groupTone = matchingType ? ({ Lightbulb: 'orange', Switch: 'green', Outlet: 'green', Fan: 'teal' }[memberTypes[0][0]] || 'blue') : 'blue';
      const glyph = HomeswiftCommon.tile(groupIcon, groupTone);
      const result = el('p', { class: 'group-feedback', role: 'status' });
      const body = el('div', { class: 'group-controls' });
      const draw = () => {
        const states = people.flatMap((accessory) => (accessory?.services || []).filter((service) => allowed.has(service.type)).flatMap((service) => {
          const state = service.characteristics.find((c) => c.type === 'On')
            || service.characteristics.find((c) => c.type === 'Active')
            || service.characteristics.find((c) => c.type === 'Current Position');
          return state && state.value != null ? [Number(state.value) > 0] : [];
        }));
        glyph.classList.toggle('is-off', states.length > 0 && !states.some(Boolean));
        if (body.contains(document.activeElement)) return;
        body.replaceChildren(...shared(people).map((type) => {
          const targets = people.map((a) => controls(a).get(type));
          const values = targets.map(({ c }) => c.value);
          const mixed = values.some((v) => v !== values[0]);
          const isBool = type === 'On' || type === 'Active';
          const temperature = type === 'Color Temperature';
          const low = Math.max(...targets.map(({ c }) => c.minValue ?? (temperature ? 140 : 0)));
          const high = Math.min(...targets.map(({ c }) => c.maxValue ?? (temperature ? 500 : type === 'Hue' ? 360 : 100)));
          if (!isBool && low > high) return null;
          let input, busy = false;
          const commit = async (value) => {
            if (editing || busy) return;
            busy = true; input.inert = true; input.setAttribute('aria-disabled', 'true');
            const outcomes = await Promise.allSettled(people.map((a, i) => api(`/api/accessories/${encodeURIComponent(a.id)}`, { method: 'PUT', body: { service: targets[i].service, characteristic: type, value } })));
            outcomes.forEach((outcome, i) => { if (outcome.status === 'fulfilled') targets[i].c.value = value; });
            const failed = outcomes.flatMap((outcome, i) => outcome.status === 'rejected' ? [people[i].displayName || people[i].name] : []);
            result.textContent = failed.length ? t('Could not update: {names}', { names: failed.join(', ') }) : '';
            busy = false; input.inert = editing; input.blur(); draw();
          };
          if (isBool) {
            input = el('input', { type: 'checkbox', checked: Boolean(values[0]), disabled: editing });
            input.setAttribute('aria-label', HomeswiftI18n.message(type)); input.indeterminate = mixed;
            input.addEventListener('change', () => commit(type === 'Active' ? Number(input.checked) : input.checked));
            return el('label', {}, el('span', { text: HomeswiftI18n.message(type) }), input,
              mixed ? el('span', { class: 'muted', text: t('Mixed') }) : null);
          }
          const { level, kelvin, whiteColor } = HomeswiftWidgets.controls;
          const min = temperature ? kelvin(high) : low, max = temperature ? kelvin(low) : high;
          const step = Math.max(...targets.map(({ c }) => c.minStep || 1));
          const control = level({ label: HomeswiftI18n.message(type), min, max, step: temperature ? 50 : step,
            format: (value) => temperature ? `${value} K` : type === 'Hue' ? `${value}°` : `${value} %`,
            gradient: temperature ? `linear-gradient(90deg, ${whiteColor(min, 72)}, ${whiteColor((min + max) / 2, 88)}, ${whiteColor(max, 84)})` : undefined },
          (value) => commit(temperature ? Math.min(high, Math.max(low, Math.round((1e6 / value - low) / step) * step + low)) : value));
          input = control.node;
          input.inert = editing;
          input.setAttribute('aria-disabled', String(editing));
          control.set(temperature ? kelvin(values[0] || high) : values[0] ?? low);
          if (mixed) {
            input.querySelector('.level-text').textContent = t('Mixed');
            input.setAttribute('aria-valuetext', t('Mixed'));
          }
          return input;
        }).filter(Boolean));
        if (people.some((a) => !a)) result.textContent = t('Some group members are unavailable.');
      };
      const node = el('div', { class: `widget size-${layout.sizes?.[group.id] || 'large'} accessory-group`, 'data-id': group.id, 'data-search': [group.name, ...people.map((a) => a?.name || '')].join(' ').toLowerCase() },
        el('div', { class: 'server-head' }, glyph, el('div', { class: 'who' }, el('strong', { text: group.name }), el('div', { class: 'muted', text: people.map((a) => a?.displayName || a?.name || '—').join(', ') })),
          menuButton(t('Actions for {name}', { name: group.name }), () => [
            ...(moveToRoom ? [{ label: t('Move to room…'), icon: 'room', onSelect: async () => {
              try { await moveToRoom(group); } catch (error) { result.textContent = error.message; }
            } }] : []),
            { label: t('Edit group'), icon: 'edit', onSelect: () => edit([], group) },
            { label: t('Ungroup'), icon: 'ungroup', onSelect: async () => {
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
    }, snapshot: (accessories) => {
      const latest = new Map(accessories.map(a => [a.id, a]));
      for (const [id, accessory] of byID) HomeswiftWidgets.reconcileAccessory(accessory, latest.get(id));
      for (const item of cards) { if (!item.node.isConnected) cards.delete(item); else item.draw(); }
    }, event: (event) => {
      const a = byID.get(event.id); if (!a) return;
      for (const s of a.services) if ((s.subtype || s.type) === (event.subtype || event.service)) for (const c of s.characteristics) if (c.type === event.characteristic) c.value = event.value;
      for (const item of cards) { if (!item.node.isConnected) cards.delete(item); else item.draw(); }
    } };
  }
  window.HomeswiftGroups = { mount, sectionIndex };
})();
