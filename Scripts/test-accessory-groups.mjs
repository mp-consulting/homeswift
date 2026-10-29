import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const context = { window: {}, HomeswiftCommon: {}, HomeswiftI18n: { t: x => x } };
vm.runInNewContext(readFileSync('Sources/HomeswiftUI/Web/groups.js', 'utf8').replace('window.HomeswiftGroups = { mount, sectionIndex };', 'window.HomeswiftGroups = { controls, shared, compatible, sectionIndex };'), context);
const { shared, compatible } = context.window.HomeswiftGroups;
const accessory = (type, chars) => ({ services: [{ type, characteristics: chars.map(type => ({ type, permissions: ['pr', 'pw'] })) }] });
const light = accessory('Lightbulb', ['On', 'Brightness', 'Hue']);
const outlet = accessory('Outlet', ['On']);
assert.equal(compatible([light, outlet]), true);
assert.deepEqual(Array.from(shared([light, outlet])), ['On']);
assert.equal(compatible([light, accessory('LockMechanism', ['On'])]), false);
assert.equal(compatible([light, undefined]), false);
assert.equal(compatible([light, { services: [...light.services, ...light.services] }]), false);
assert.equal(compatible([light, accessory('WindowCovering', ['Target Position'])]), false);
// A light with extra services (Hue: effect and Flash switches, gradient points as lightbulbs) joins through its primary one.
const { controls } = context.window.HomeswiftGroups;
const service = (type, chars, extra = {}) => ({ type, ...extra, characteristics: chars.map(type => ({ type, permissions: ['pr', 'pw'] })) });
const hue = { services: [service('Lightbulb', ['On', 'Brightness', 'Hue'], { primary: true }), service('Switch', ['On'], { subtype: 'effect:candle' }),
  service('Switch', ['On'], { subtype: 'flash' }), service('Lightbulb', ['On', 'Hue'], { subtype: 'point:0' })] };
assert.equal(compatible([light, hue]), true);
assert.deepEqual(Array.from(shared([light, hue])), ['On', 'Brightness', 'Hue']);
assert.equal(controls(hue).get('On').service, 'Lightbulb');
assert.equal(compatible([light, { services: hue.services.map(({ primary, ...rest }) => rest) }]), false);
console.log('Passed: common controls, incompatible devices, missing members, ambiguous services, and a primary service among several.');

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
    HomeswiftWidgets:{controls:{
      kelvin:m=>Math.round(1e6/m/50)*50, whiteColor:()=> 'white',
      level:options=>({node:el('div',{'role':'slider','aria-label':options.label},el('span',{text:options.label})),set(){}})
    }}};
  vm.createContext(rendering);
  vm.runInContext(readFileSync(`Sources/HomeswiftUI/Web/i18n-${language}.js`,'utf8'),rendering);
  vm.runInContext(readFileSync('Sources/HomeswiftUI/Web/groups.js','utf8'),rendering);
  const devices=['one','two'].map(id=>({id,name:id,...accessory('Lightbulb',['On','Brightness','Color Temperature'])}));
  const group={id:'group:test',name:'Lights',members:['one','two']};
  rendering.window.HomeswiftGroups.mount({all:devices,layout:{groups:[group]},persist(){},refresh(){}}).card(group,false);
  for (const key of ['Brightness','Color Temperature']) {
    assert.notEqual(catalog[key],key);
    assert.ok(nodes.some(n=>n.tag==='span'&&n.attrs.text===catalog[key]),`${language} visible ${key}`);
    assert.ok(nodes.some(n=>n.attrs.role==='slider'&&n.attrs['aria-label']===catalog[key]),`${language} accessible ${key}`);
  }
}
console.log('Passed: French, Spanish and Portuguese group-control labels and accessible names.');

// Groups must follow their lights rather than jump to the first room/plugin wall.
const { sectionIndex } = context.window.HomeswiftGroups;
const kitchen = { id: 'kitchen', room: 'Kitchen' };
const lights = [{ id: 'a', room: 'Living room' }, { id: 'b', room: 'Living room' }];
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

// Exercise the production room action: one metadata request, never a device write.
let answer = ' Bedroom ', prompted, routes = 0, failure = false;
const roomRequests = [];
const roomContext = { window: {},
  HomeswiftCommon: { promptDialog: async (message, value) => { prompted = { message, value }; return answer; } },
  HomeswiftI18n: { locale: 'en', t: key => key } };
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
assert.ok(prompted.message.includes('HomeKit rooms stay unchanged.'));
assert.equal(routes, 1);
assert.deepEqual(JSON.parse(JSON.stringify(roomRequests)), [
  { path: '/api/rooms' },
  { path: '/api/rooms', options: { method: 'PUT', body: { accessories: { a: { room: 'Bedroom' }, b: { room: 'Bedroom' } } } } }
]);
roomRequests.length = 0; answer = null;
await moveGroup();
assert.equal(roomRequests.length, 1);
assert.equal(routes, 1);
answer = ''; await moveGroup();
assert.equal(roomRequests.at(-1).options.body.accessories.a.room, null);
assert.equal(roomRequests.at(-1).options.body.accessories.b.room, null);
failure = true; answer = 'Bedroom';
await assert.rejects(moveGroup(), /Room update failed/);
assert.equal(routes, 2);
assert.deepEqual(lights.map(a => a.room), ['Living room', 'Living room']);
console.log('Passed: group room move is metadata-only, cancellation, clearing and failed saves.');
