// Recovery deadline, snapshot ordering and in-place widget reconciliation. No server or devices.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const app = readFileSync('Sources/HomeswiftUI/Web/app.js', 'utf8');
const widgets = readFileSync('Sources/HomeswiftUI/Web/widgets.js', 'utf8');
let now = 0, finished = 0;
let healthy = false;
const timers = [], buttons = [];
const overlay = {querySelector:()=>({remove(){},textContent:''}),append:b=>buttons.push(b),close(){},remove(){}};
const polling = {Date:{now:()=>now}, AbortSignal, restartPolling:false,restartOverlay:null,
  closeEvents(){}, reloadIfUpdated:()=>false, showRestartOverlay:()=>overlay, closeRestartOverlay(){}, t:x=>x, el:(_tag,attrs)=>attrs,
  setTimeout:(fn,ms)=>{timers.push({fn,ms});return 1},clearTimeout(){},
  fetch:async()=>({ok:healthy,status:healthy?200:503,json:async()=>({uptimeSeconds:1})}),
  finishRestart:async()=>{finished++}};
vm.createContext(polling);
vm.runInContext(app.slice(app.indexOf('  function waitForRestart('),app.indexOf('  $("#restart").addEventListener')),polling);
const run = async ms => { const i=timers.findIndex(t=>t.ms===ms);assert.notEqual(i,-1);await timers.splice(i,1)[0].fn(); };
polling.waitForRestart(0);
now=90001; await run(1500);
assert.equal(buttons.length,1);
buttons[0].onclick();
await run(1500);
assert.equal(buttons.length,1,'retry has its own deadline');
assert.ok(timers.some(t=>t.ms===1000));
healthy=true;now+=1000;await run(1000);
assert.equal(finished,1,'recovered process dismisses overlay');

let handlers, resolveSnapshot, rejectSnapshot;
const applied=[];
const scope={events:null, console, location:{pathname:'/accessories'},window:{homeswiftGroupSnapshot:a=>applied.push(['groups',a])},
  EventSource:class {constructor(){handlers={}} addEventListener(name,fn){handlers[name]=fn}},
  api:()=>new Promise((resolve,reject)=>{resolveSnapshot=resolve;rejectSnapshot=reject}),
  HomeswiftWidgets:{snapshot:a=>applied.push(['snapshot',a])},
  applyAccessoryEvent:e=>applied.push(['event',e]),appendLogLine(){},applyAsset(){}};
vm.createContext(scope);
vm.runInContext(app.slice(app.indexOf('  function openEvents()'),app.indexOf('  /// Live web files')),scope);
scope.openEvents();
const first=handlers.hello();
handlers.accessory({data:JSON.stringify({id:'lamp',value:75})});
assert.equal(applied.length,0);
resolveSnapshot([{id:'lamp',value:50,services:[]}]);await first;
assert.deepEqual(applied.map(x=>x[0]),['snapshot','groups','event']);
assert.equal(applied.at(-1)[1].value,75,'new event wins over older snapshot');
const failed=handlers.hello();handlers.accessory({data:'{"value":80}'});
const originalError=console.error;console.error=()=>{};rejectSnapshot(new Error('offline'));await failed;console.error=originalError;
assert.equal(applied.at(-1)[1].value,80,'failed snapshot does not discard live events');
const abandoned=handlers.hello();scope.events=null;resolveSnapshot([{id:'stale'}]);await abandoned;
assert.equal(applied.length,4,'closed stream cannot apply its snapshot');

const characteristic={type:'Brightness',value:10};
const accessory={id:'lamp',paused:true,services:[{type:'Lightbulb',characteristics:[characteristic]}]};
let paints=0;
const context={cards:new Set([{node:{isConnected:true},accessory,paint:()=>paints++}]),sweep(){},serviceKey:s=>s.subtype||s.type};
vm.createContext(context);
vm.runInContext(widgets.slice(widgets.indexOf('  function reconcileAccessory('),widgets.indexOf('  /// For a plugin page:')),context);
context.snapshot([{id:'lamp',services:[{type:'Lightbulb',characteristics:[{type:'Brightness',value:90}]}]}]);
assert.equal(characteristic.value,90);assert.equal(accessory.paused,false);assert.equal(paints,1);
assert.strictEqual(accessory.services[0].characteristics[0],characteristic,'control references survive reconciliation');
context.snapshot([]);assert.equal(accessory.unavailable,true);
console.log('Passed: restart retry, recovery, snapshot/live-event ordering, failed/stale requests and in-place values.');
