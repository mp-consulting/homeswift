import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const context = { window: {}, HomeswiftCommon: {}, HomeswiftI18n: { t: x => x } };
vm.runInNewContext(readFileSync('Sources/HomeswiftUI/Web/groups.js', 'utf8').replace('window.HomeswiftGroups = { mount, sectionIndex };', 'window.HomeswiftGroups = { controls, shared, compatible, sectionIndex };'), context);
const { shared, compatible } = context.window.HomeswiftGroups;
// The bridge marks what a group drives (`group`, HomeswiftCatalog.groupTargets: the primary service, never a security
// control, nothing when two services share a control); the page groups by those marks.
const accessory = (type, chars, group = true) => ({ services: [{ type, characteristics: chars.map(type => ({ type, permissions: ['pr', 'pw'], group })) }] });
const light = accessory('Lightbulb', ['On', 'Brightness', 'Hue']);
const outlet = accessory('Outlet', ['On']);
assert.equal(compatible([light, outlet]), true);
assert.deepEqual(Array.from(shared([light, outlet])), ['On']);
assert.equal(compatible([light, accessory('LockMechanism', ['On'], false)]), false);
assert.equal(compatible([light, undefined]), false);
assert.equal(compatible([light, accessory('WindowCovering', ['Target Position'])]), false);
// A light with extra services (Hue: effect and Flash switches, gradient points as lightbulbs) joins through the one marked.
const { controls } = context.window.HomeswiftGroups;
const service = (type, chars, extra = {}, group = false) => ({ type, ...extra, characteristics: chars.map(type => ({ type, permissions: ['pr', 'pw'], group })) });
const hue = { services: [service('Lightbulb', ['On', 'Brightness', 'Hue'], { primary: true }, true), service('Switch', ['On'], { subtype: 'effect:candle' }),
  service('Switch', ['On'], { subtype: 'flash' }), service('Lightbulb', ['On', 'Hue'], { subtype: 'point:0' })] };
assert.equal(compatible([light, hue]), true);
assert.deepEqual(Array.from(shared([light, hue])), ['On', 'Brightness', 'Hue']);
assert.equal(controls(hue).get('On').service, 'Lightbulb');
console.log('Passed: common controls, incompatible devices, missing members, and the service the bridge marks among several.');

// Render real group controls using each shipping catalog; check visible and accessible labels.
for (const language of ['fr', 'es', 'pt']) {
  let catalog;
  const nodes=[];
  const el=(tag,attrs={},...children)=>{
    const node={tag,attrs,children:children.flat(Infinity),isConnected:true,
      contains:()=>false,replaceChildren(...next){this.children=next.flat(Infinity)},
      setAttribute(k,v){this.attrs[k]=v},addEventListener(){}};
    nodes.push(node);return node;
  };
  const i18n={add:(_lang,values)=>catalog=values,t:key=>catalog?.[key]||key,message:key=>catalog?.[key]||key};
  const rendering={window:{},document:{activeElement:null},HomeswiftI18n:i18n,
    HomeswiftCommon:{el,tile:()=>({classList:{toggle(){}}}),menuButton:()=>null},
    HomeswiftWidgets:{whiteTrack:()=>'white', controls:{
      kelvin:m=>Math.round(1e6/m/50)*50,
      level:options=>({node:el('div',{'role':'slider','aria-label':options.label},el('span',{text:options.label})),set(){}})
    }}};
  vm.createContext(rendering);
  vm.runInContext(readFileSync(`Sources/HomeswiftUI/Web/i18n-${language}.js`,'utf8'),rendering);
  vm.runInContext(readFileSync('Sources/HomeswiftUI/Web/groups.js','utf8'),rendering);
  // Members of two kinds keep the group's own form (alike ones are drawn as one of them, below).
  const devices=[['one','Lightbulb'],['two','Switch']].map(([id,type])=>({id,name:id,...accessory(type,['On','Brightness','Color Temperature'])}));
  const group={id:'group:test',name:'Lights',members:['one','two']};
  rendering.window.HomeswiftGroups.mount({all:devices,layout:{groups:[group]},persist(){},refresh(){}}).card(group,false);
  for (const key of ['Brightness','Color Temperature']) {
    assert.notEqual(catalog[key],key);
    assert.ok(nodes.some(n=>n.tag==='span'&&n.attrs.text===catalog[key]),`${language} visible ${key}`);
    assert.ok(nodes.some(n=>n.attrs.role==='slider'&&n.attrs['aria-label']===catalog[key]),`${language} accessible ${key}`);
  }
}
console.log('Passed: French, Spanish and Portuguese group-control labels and accessible names.');

// Alike members (two lights) are drawn as one light by the widgets: the controls they share, within the range they
// all take, on when one is, and a change sent to each.
{
  const requests = [];
  let drawn;
  const merging = { window: {}, document: { activeElement: null }, HomeswiftI18n: { t: (key, values) => key.replace('{names}', values?.names ?? ''), message: (key) => key },
    HomeswiftCommon: { el: () => ({}), tile: () => ({}), menuButton: () => null,
      api: async (path, options) => { requests.push({ path, ...options }); if (path.includes('two') && options.body.characteristic === 'Hue') throw new Error('offline'); } },
    HomeswiftWidgets: { card: (merged, options) => { drawn = { merged, options }; return { classList: { add() {} }, dataset: {} }; } } };
  vm.runInNewContext(readFileSync('Sources/HomeswiftUI/Web/groups.js', 'utf8'), merging);
  const lamp = (id, on, hue, max) => ({ id, name: id, category: 5, services: [{ type: 'Lightbulb', characteristics: [
    { type: 'On', format: 'bool', value: on, permissions: ['pr', 'pw'], group: true },
    { type: 'Brightness', value: 50, minValue: 0, maxValue: max, permissions: ['pr', 'pw'], group: true },
    { type: 'Hue', value: hue, minValue: 0, maxValue: 360, permissions: ['pr', 'pw'], group: true }] }] });
  const lamps = [lamp('one', false, 10, 100), lamp('two', true, 200, 80)];
  const group = { id: 'group:lamps', name: 'Lamps', members: ['one', 'two'] };
  merging.window.HomeswiftGroups.mount({ all: lamps, layout: { groups: [group] }, persist() {}, refresh() {} }).card(group, false);
  const [service] = drawn.merged.services;
  assert.equal(service.type, 'Lightbulb');
  const char = (type) => service.characteristics.find((c) => c.type === type);
  assert.equal(char('On').value, true);
  assert.equal(char('Hue').value, 200, 'the first member that is on');
  assert.equal(char('Brightness').maxValue, 80, 'the range every member takes');
  await drawn.options.group.write(service, char('Brightness'), 30);
  assert.deepEqual(requests.map((r) => [r.path, r.body.characteristic, r.body.value]), [['/api/accessories/one', 'Brightness', 30], ['/api/accessories/two', 'Brightness', 30]]);
  await assert.rejects(drawn.options.group.write(service, char('Hue'), 90), /two/);
  assert.equal(lamps[0].services[0].characteristics[2].value, 90);
}
console.log('Passed: alike members drawn as one accessory, their shared range, and writes sent to each.');

// Groups must follow their lights rather than jump to the first room/plugin wall.
const { sectionIndex } = context.window.HomeswiftGroups;
const kitchen = { id: 'kitchen', room: 'Kitchen' };
// A plugin's accessories (`platform`): only they have Accessory Settings to move.
const lights = [{ id: 'a', room: 'Living room', platform: 'Demo' }, { id: 'b', room: 'Living room', platform: 'Demo' }];
const sections = [['Kitchen', [kitchen]], ['Living room', lights]];
const group = { members: ['a', 'b'] };
assert.equal(sectionIndex(group, sections), 1);
assert.equal(sectionIndex(group, sections.toReversed()), 0);
assert.equal(sectionIndex(group, [['One wall', [kitchen, ...lights]]]), 0);
assert.equal(sectionIndex(group, [['Plugin A', [kitchen]], ['Plugin B', lights]]), 1);
assert.equal(sectionIndex({ members: ['missing', 'b'] }, sections), 1);
assert.equal(sectionIndex(group, [['Kitchen', [kitchen]]]), -1);
assert.equal(sectionIndex({ members: ['b', 'kitchen'] }, sections), 1);
assert.deepEqual(lights.map(a => a.room), ['Living room', 'Living room']);
console.log('Passed: group room/plugin placement, reordered walls, filtered and missing members.');

// Exercise the production room action: one Accessory Settings write for every member, never a device write.
let answer = ' Bedroom ', prompted, routes = 0, failure = false;
const roomRequests = [];
const roomContext = { window: {},
  HomeswiftCommon: { promptDialog: async (message, value) => { prompted = { message, value }; return answer; } },
  // What home.js reads from i18n.js as it loads: its formatters and the week's first day.
  HomeswiftI18n: { locale: 'en', numberLocale: 'en', firstWeekday: 1, t: key => key, dateTimeFormat: (options) => new Intl.DateTimeFormat('en', options) } };
vm.runInNewContext(readFileSync('Sources/HomeswiftUI/Web/home.js', 'utf8'), roomContext);
roomContext.window.HomeswiftHome.install({ views: {}, route: () => { routes++; },
  api: async (path, options) => {
    roomRequests.push({ path, options });
    if (options && failure) throw new Error('Room update failed');
    return { rooms: [{ name: 'Living room' }, { name: 'Bedroom' }] };
  } });
const moveGroup = () => roomContext.window.HomeswiftHome.moveGroupToRoom(group, lights);
await moveGroup();
assert.equal(prompted.value, 'Living room');
// Rooms are Apple Home's (docs/adr/0005): the move reaches the Home app once the bridge is linked.
assert.ok(prompted.message.includes('in the Home app too once this bridge is linked to Apple Home'));
assert.equal(routes, 1);
assert.deepEqual(JSON.parse(JSON.stringify(roomRequests)), [
  { path: '/api/rooms' },
  { path: '/api/settings/accessories', options: { method: 'PATCH', body: { a: { room: 'Bedroom' }, b: { room: 'Bedroom' } } } }
]);
roomRequests.length = 0; answer = null;
await moveGroup();
assert.equal(roomRequests.length, 1);
assert.equal(routes, 1);
answer = ''; await moveGroup();
assert.equal(roomRequests.at(-1).options.body.a.room, null);
assert.equal(roomRequests.at(-1).options.body.b.room, null);
failure = true; answer = 'Bedroom';
await assert.rejects(moveGroup(), /Room update failed/);
assert.equal(routes, 2);
assert.deepEqual(lights.map(a => a.room), ['Living room', 'Living room']);
console.log('Passed: group room move is metadata-only, cancellation, clearing and failed saves.');
