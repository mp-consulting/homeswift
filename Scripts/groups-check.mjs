// Grouped Adaptive Lighting uses real member endpoints and reconciles partial failures.
// Run with: node --test Scripts/groups-check.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

function fixture({ fail, unsupported } = {}) {
  let rendered;
  const calls = [];
  const context = { window: {}, HomeswiftI18n: { t: (s, values) => values?.names ? s.replace('{names}', values.names) : s },
    HomeswiftCommon: { api: async (url, options) => {
      calls.push(url);
      if (url.includes(fail || 'never-match')) throw Error('Offline');
      return { adaptiveLighting: { active: options.body.on, resumable: true } };
    } },
    HomeswiftWidgets: { card: (accessory, options) => {
      rendered = { accessory, options };
      return { classList: { add() {} }, dataset: {}, isConnected: true };
    } } };
  vm.runInNewContext(readFileSync(new URL('../Sources/HomeswiftUI/Web/groups.js', import.meta.url), 'utf8'), context);
  const all = ['first', 'second'].map(id => ({ id, name: id, category: 5, services: [{ type: 'Lightbulb',
    ...(id === unsupported ? {} : { adaptiveLighting: { active: true, resumable: true } }),
    characteristics: [{ type: 'On', group: true, value: true, format: 'bool', permissions: ['pr', 'pw'] }]
  }] }));
  const group = { id: 'group', name: 'Lights', members: all.map(a => a.id) };
  context.window.HomeswiftGroups.mount({ all, layout: { groups: [group] }, persist: async () => {}, refresh() {} }).card(group, false);
  return { calls, all, ...rendered };
}

test('adaptive lighting writes members and follows their state', async () => {
  const f = fixture();
  const service = f.accessory.services[0];
  assert.equal(service.characteristics.at(-1).value, 1);
  await f.options.group.setAdaptive(false);
  assert.deepEqual(f.calls, ['/api/accessories/first/adaptive-lighting', '/api/accessories/second/adaptive-lighting']);
  assert.equal(service.characteristics.at(-1).value, 0);
});

test('partial failure retains successful member updates and identifies failures', async () => {
  const f = fixture({ fail: 'second' });
  await assert.rejects(f.options.group.setAdaptive(false), /second/);
  assert.equal(f.all[0].services[0].adaptiveLighting.active, false);
  assert.equal(f.all[1].services[0].adaptiveLighting.active, true);
  assert.equal(f.accessory.services[0].characteristics.at(-1).value, 0);
});

test('mixed capability groups do not advertise adaptive lighting', () => {
  assert.equal(fixture({ unsupported: 'second' }).accessory.services[0].adaptiveLighting, undefined);
});
