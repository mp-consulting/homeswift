import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const t = (text, values = {}) => text.replace(/\{(\w+)\}/g, (_, k) => values[k] ?? '');
const context = { window: {}, HomeswiftCommon: {}, HomeswiftI18n: { t, tn: (one, many, n) => t(n === 1 ? one : many, { n }) } };
vm.runInNewContext(fs.readFileSync('Sources/HomeswiftUI/Web/homelink.js', 'utf8'), context);
const {status} = context.window.HomeswiftHomeLink;
assert.match(status({state:'up',linked:true,home:'Demo'}).text,/In step/);
for (const state of ['up','readOnly','down','none']) {
 const result = status({state,linked:true,pending:2,reason:'edits off'});
 assert.match(result.text,/2 changes are pending/);
 assert.doesNotMatch(result.text,/In step/);
 assert.equal(result.tone,'warn');
}
const failed=status({state:'up',linked:true,refused:[{reason:'Group deleted'}]});
assert.match(failed.text,/Apple Home refused: Group deleted/);
assert.doesNotMatch(failed.text,/In step/);
assert.equal(failed.tone,'error');
console.log('Home Link pending and refusal states passed');
