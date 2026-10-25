import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// Exercise the actual shared reset control, with browser event semantics.
const source = readFileSync('Sources/HomeswiftUI/Web/common.js', 'utf8');
const begin = source.indexOf('  function clearFilters(');
const end = source.indexOf('  // Native disabled buttons', begin);
const context = { Event, t: value => value, el: (_tag, attributes) => Object.assign(new EventTarget(), attributes) };
vm.createContext(context);
vm.runInContext(source.slice(begin, end), context);
const search = Object.assign(new EventTarget(), { type: 'search', value: '' });
const status = Object.assign(new EventTarget(), { type: 'checkbox', checked: false });
const room = Object.assign(new EventTarget(), { value: '' });
const state = () => [search.value, status.checked, room.value];
let snapshots = [];
for (const [control, event] of [[search, 'input'], [status, 'change'], [room, 'change']]) {
  control.addEventListener(event, () => snapshots.push(state()));
}
const button = context.clearFilters([[search, ''], [status, false], [room, '']]);
assert.equal(button.disabled, true);
search.value = 'lamp'; search.dispatchEvent(new Event('input'));
assert.equal(button.disabled, false);
status.checked = true; room.value = 'Kitchen';
snapshots = [];
button.onclick();
assert.equal(button.disabled, true);
assert.deepEqual(state(), ['', false, '']);
assert.equal(snapshots.length, 3);
for (const snapshot of snapshots) assert.deepEqual(snapshot, ['', false, ''], 'all filters reset before any listener runs');
let custom = true;
const tabs = new EventTarget();
const customButton = context.clearFilters([], { active: () => custom, reset: () => { custom = false; }, events: [[tabs, 'click']] });
assert.equal(customButton.disabled, false);
customButton.onclick();
assert.equal(customButton.disabled, true);
custom = true; tabs.dispatchEvent(new Event('click'));
assert.equal(customButton.disabled, false);
console.log('Passed: filter reset, disabled state, event ordering, and custom filter state.');
