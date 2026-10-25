import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const context = { window: {}, HomeswiftCommon: {}, HomeswiftI18n: { t: x => x } };
vm.runInNewContext(readFileSync('Sources/HomeswiftUI/Web/groups.js', 'utf8').replace('window.HomeswiftGroups = { mount };', 'window.HomeswiftGroups = { controls, shared, compatible };'), context);
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
console.log('Passed: common controls, incompatible devices, missing members, and ambiguous services.');

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
    HomeswiftCommon:{el,tile:()=>null,menuButton:()=>null}};
  vm.createContext(rendering);
  vm.runInContext(readFileSync(`Sources/HomeswiftUI/Web/i18n-${language}.js`,'utf8'),rendering);
  vm.runInContext(readFileSync('Sources/HomeswiftUI/Web/groups.js','utf8'),rendering);
  const devices=['one','two'].map(id=>({id,name:id,...accessory('Lightbulb',['On','Brightness','Color Temperature'])}));
  const group={id:'group:test',name:'Lights',members:['one','two']};
  rendering.window.HomeswiftGroups.mount({all:devices,layout:{groups:[group]},persist(){},refresh(){}}).card(group,false);
  for (const key of ['Brightness','Color Temperature']) {
    assert.notEqual(catalog[key],key);
    assert.ok(nodes.some(n=>n.tag==='span'&&n.attrs.text===catalog[key]),`${language} visible ${key}`);
    assert.ok(nodes.some(n=>n.tag==='input'&&n.attrs['aria-label']===catalog[key]),`${language} accessible ${key}`);
  }
}
console.log('Passed: French, Spanish and Portuguese group-control labels and accessible names.');
