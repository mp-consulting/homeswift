// Focused widget regression: mirrored indicators must never send schedule writes or invent active state.
// Run: node Scripts/test-adaptive-indicator.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source = readFileSync(new URL('../Sources/HomeswiftUI/Web/widgets.js', import.meta.url), 'utf8');
const start = source.indexOf('  function lightParts(');
const end = source.indexOf("  /// A light's whole body", start);
let writes = 0;
const scope = {
  t: s => s, numberOf: c => Number(c?.value ?? 0), canWrite: () => false,
  icon: () => null, serviceKey: () => 'light', api: async () => { writes++; },
  el: (_tag, attrs) => ({
    attrs: { ...attrs }, classes: new Set(), handlers: {},
    setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; },
    addEventListener(k, fn) { this.handlers[k] = fn; },
    get classList() { return { toggle: (k, on) => on ? this.classes.add(k) : this.classes.delete(k) }; },
  }),
};
vm.createContext(scope);
vm.runInContext(source.slice(start, end), scope);
function fixture({ mirrored = true, count, controller, temperature = true } = {}) {
  const chars = { Brightness: { value: 70 } };
  if (temperature) chars['Color Temperature'] = { value: 300 };
  if (count !== undefined) chars['Characteristic Value Active Transition Count'] = { value: count };
  const painters = [], messages = [];
  const ctx = { accessory: { id: 'test', mirroredFrom: mirrored ? 'Apple Home' : undefined },
    take: (_, key) => chars[key], char: (_, key) => chars[key],
    watch: fn => { painters.push(fn); fn(); }, paint: () => painters.forEach(fn => fn()), flash: text => messages.push(text) };
  const parts = scope.lightParts(ctx, { adaptiveLighting: controller });
  return { parts, ctx, chars, messages };
}
for (const [count, expected] of [[undefined, 'status unavailable'], [null, 'status unavailable'], [0, 'off;'], [1, 'on;']]) {
  const f = fixture({ count });
  const button = f.parts.adaptive('swatch');
  assert.match(button.title, new RegExp(expected));
  assert.equal(f.parts.adaptiveOn(), count === 1);
  assert.equal(button.attrs['aria-checked'], undefined);
  button.handlers.click();
  assert.match(f.messages[0], new RegExp(expected));
  assert.equal(writes, 0);
}
const f = fixture({ count: 0 });
const button = f.parts.adaptive('round');
f.chars['Characteristic Value Active Transition Count'].value = 1;
f.ctx.paint();
assert.equal(button.classes.has('external-active'), true);
assert.match(button.title, /on; managed/);
assert.equal(fixture({ mirrored: false }).parts.adaptive, null);
assert.equal(fixture({ temperature: false }).parts.adaptive, null);
const local = fixture({ mirrored: false, count: 0, controller: { resumable: true } });
await local.parts.adaptive().handlers.click();
assert.equal(writes, 1);
assert.equal(local.parts.adaptiveOn(), true);
for (const language of ['fr', 'es', 'pt']) {
  const catalogs = {};
  vm.runInNewContext(readFileSync(new URL(`../Sources/HomeswiftUI/Web/i18n-${language}.js`, import.meta.url), 'utf8'),
    { HomeswiftI18n: { add: (name, entries) => { catalogs[name] = entries; } } });
  for (const key of source.matchAll(/t\("(Adaptive Lighting: [^"]*(?:managed in Apple Home|check in Apple Home))"\)/g))
    assert.ok(catalogs[language][key[1]], `${language}: ${key[1]}`);
}
console.log('Adaptive indicator: unknown/on/off, live updates, no mirrored writes, native toggle, translations passed.');
