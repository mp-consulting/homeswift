// Regression checks for consumption history and asynchronous loading, without devices or a server.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source = readFileSync('Sources/HomeswiftUI/Web/app.js', 'utf8');
const section = (from, to) => source.slice(source.indexOf(from), source.indexOf(to, source.indexOf(from)));
const element = (tag, attrs = {}) => ({ tag, attrs, children: [],
  setAttribute(key, value) { this.attrs[key] = value; },
  append(...nodes) { this.children.push(...nodes); },
  prepend(...nodes) { this.children.unshift(...nodes); },
});
const scope = vm.createContext({ el: element, document: { createElementNS: (_ns, tag) => element(tag) },
  roles: [{ id: 'solar', tone: 4 }, { id: 'home', tone: 1 }, { id: 'battery', tone: 3 }, { id: 'grid', tone: 7 }] });
vm.runInContext(section('    function consumerUnmeteredBars(', '    // Measure folded rows too.'), scope);
const result = scope.consumerUnmeteredBars([{ bars: [{ date: 'a', consumption: 10 }, { date: 'b', consumption: 5 }, { date: 'c', consumption: 1 }] }],
  [{ bars: [{ date: 'c', consumption: 2 }, { date: 'a', consumption: 3 }] }]);
assert.deepEqual(Array.from(result, bar => bar.consumption), [7, null, 0], 'align dates, preserve gaps, clamp negative residuals');
const chart = scope.consumerSparkline({ role: 'solar', bars: [{ returned: 0 }, { returned: null }, { returned: 3 }] }, 'returned');
assert.match(chart.attrs.style, /series-4/);
const paths = chart.children[0].children.filter(node => node.tag === 'path');
assert.equal((paths[2].attrs.d.match(/M/g) ?? []).length, 2, 'missing bucket breaks the trace');
assert.equal((paths[0].attrs.d.match(/Z/g) ?? []).length, 2, 'missing bucket breaks the filled area');
assert.equal(scope.consumerSparkline({ bars: [{ consumption: null }] }, 'consumption').children.length, 0);
assert.ok(!scope.consumerSparkline({ bars: [{ consumption: 0 }] }, 'consumption').children[0].children.some(node => /NaN|Infinity/.test(node.attrs.d ?? '')));
const requests = [], applied = [], loading = [];
const context = vm.createContext({ consumerIcons: new Map(), consumerIconsRequest: null, historyAsked: 1,
  setConsumersLoading: value => loading.push(value), view: 'week', anchor: null, timeZone: 'UTC', isoDay: () => '2026-11-10', URLSearchParams,
  api: url => url === '/api/accessories' ? Promise.reject(new Error('icons unavailable')) : new Promise((resolve, reject) => requests.push({ resolve, reject })),
  consumers: { detail: {} }, HomeswiftWidgets: { accessoryIcon: () => 'outlet' }, utilities: [],
  fillConsumers: report => applied.push(report), fillUtility() {}, showSection() {}, hasMeters: false,
});
vm.runInContext(section('    async function loadConsumers(', '    // Subtract matching dates only'), context);
const old = context.loadConsumers(1);
context.historyAsked = 2;
const current = context.loadConsumers(2);
requests[0].resolve({ meters: [{ name: 'stale' }] });
await old;
assert.equal(applied.length, 0, 'stale report is ignored');
assert.deepEqual(loading, [true, true], 'stale request cannot dismiss the current skeleton');
requests[1].resolve({ meters: [{ name: 'current' }] });
await current;
assert.equal(applied[0].meters[0].name, 'current', 'icon failure does not discard consumption');
assert.equal(loading.at(-1), false);
const failed = context.loadConsumers(2);
requests[2].reject(new Error('offline'));
await failed;
assert.equal(context.consumers.detail.textContent, 'offline');
assert.equal(loading.at(-1), false, 'failure clears the loading state');
console.log('Passed: date alignment, missing/zero data, filled gaps, role color, stale requests and loading failures.');
