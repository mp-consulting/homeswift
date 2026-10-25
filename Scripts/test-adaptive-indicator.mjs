// Mirrored lights report temperature and offer Homeswift Natural Lighting only when writable.
// Run: node Scripts/test-adaptive-indicator.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source = readFileSync(new URL('../Sources/HomeswiftUI/Web/widgets.js', import.meta.url), 'utf8');
const start = source.indexOf('  function lightParts(');
const end = source.indexOf("  /// A light's whole body", start);
let writes = 0;
let request;
const scope = {
  t: s => s, num: n => String(n), numberOf: c => Number(c?.value ?? 0), canWrite: c => !!c?.writable,
  icon: () => null, serviceKey: () => 'light', api: async (url, options) => { writes++; request = {url, ...options}; return options.body.on ? {light:{enabled:true, paused:false}} : {}; },
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
for (const count of [undefined, null, 0, 1]) {
  const f = fixture({ count });
  assert.equal(f.parts.adaptive, null);
  assert.equal(f.parts.reportedTemperature(), '3333 K');
  assert.equal(writes, 0);
}
const f = fixture();
f.chars['Color Temperature'].value = 250;
assert.equal(f.parts.reportedTemperature(), '4000 K');
for (const value of [null, undefined, 0, -1, NaN, Infinity, '250']) {
  f.chars['Color Temperature'].value = value;
  assert.equal(f.parts.reportedTemperature(), '');
}
assert.equal(fixture({ mirrored: false }).parts.reportedTemperature(), '');
assert.equal(fixture({ temperature: false }).parts.reportedTemperature(), '');
const local = fixture({ mirrored: false, count: 0, controller: { resumable: true } });
await local.parts.adaptive().handlers.click();
assert.equal(writes, 1);
assert.equal(local.parts.adaptiveOn(), true);
const natural = fixture();
natural.chars['Color Temperature'].writable = true;
const naturalParts = scope.lightParts(natural.ctx, {});
assert.equal(naturalParts.adaptiveOn(), false);
await naturalParts.adaptive().handlers.click();
assert.ok(request.url.endsWith('/natural-lighting'));
assert.equal(request.body.on, true);
assert.equal(naturalParts.adaptiveOn(), true);
assert.equal(naturalParts.modeLabel(), 'Natural');
natural.ctx.accessory.naturalLighting.light.paused = true;
assert.equal(naturalParts.adaptiveOn(), false);
assert.equal(naturalParts.modeLabel(), 'Natural paused');
await naturalParts.adaptive().handlers.click();
assert.equal(request.body.on, true);
await naturalParts.adaptive().handlers.click();
assert.equal(request.body.on, false);
console.log('Passed: reported temperature, live updates, missing/invalid readings, read-only lights, native toggle, Natural Lighting enable/pause/resume/disable.');
