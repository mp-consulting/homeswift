// Browser verification of the public explorer against its production runtime.
// node Scripts/design-system-check.mjs [screenshot directory]
import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve, join, extname } from "node:path";
const root = fileURLToPath(new URL("..", import.meta.url));
const out = resolve(process.argv[2] || "/tmp/homeswift-design-shots");
mkdirSync(out,{recursive:true});
const profile=mkdtempSync("/tmp/design-chrome-");
const requests=[];
const server=createServer((req,res)=>{
  const pathname=decodeURIComponent(new URL(req.url,"http://localhost").pathname);
  requests.push(pathname);
  const path=resolve(root,"site", "."+pathname+(pathname.endsWith("/")?"index.html":""));
  if(!path.startsWith(join(root,"site")+"/")){res.writeHead(403);res.end();return;}
  try{res.setHeader("Content-Type",({".html":"text/html",".js":"text/javascript",".css":"text/css",".svg":"image/svg+xml",".png":"image/png"})[extname(path)]||"application/octet-stream");res.end(readFileSync(path));}
  catch{res.writeHead(404);res.end();}
});
await new Promise(done=>server.listen(0,"127.0.0.1",done));
const base=`http://127.0.0.1:${server.address().port}`;
const chrome=spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",["--headless=new","--remote-debugging-port=9357",`--user-data-dir=${profile}`,"--hide-scrollbars","--no-first-run","about:blank"],{stdio:"ignore"});
const sleep=ms=>new Promise(done=>setTimeout(done,ms));
let socket;
try{
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    try { target = (await (await fetch("http://127.0.0.1:9357/json/list")).json()).find((tab) => tab.type === "page"); } catch {}
    if (!target) await sleep(200);
  }
  if (!target) throw new Error("Headless Chrome did not start");
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((done) => socket.addEventListener("open", done));
  let sequence = 0;
  const pending = new Map();
  const errors = [];
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) { pending.get(message.id)?.(message); pending.delete(message.id); }
    else if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails);
    else if(message.method === "Log.entryAdded" && message.params.entry.level === "error") errors.push(message.params.entry);
  });
  const send = (method, params = {}) => new Promise((done) => {
    const id = ++sequence;
    pending.set(id, done);
    socket.send(JSON.stringify({ id, method, params }));
  }).then((message) => {
    if (message.error) throw new Error(message.error.message);
    return message.result;
  });
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const appearance = (theme) => send("Emulation.setEmulatedMedia", { features: [
    { name: "prefers-color-scheme", value: theme }, { name: "prefers-reduced-motion", value: "reduce" },
  ] });
  const viewport = (width, height = 1500) => send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false });
  const navigate = async (path, selector) => {
    await send("Page.navigate", { url: base + path });
    for (let i = 0; i < 50; i++) {
      if (await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`)) { await sleep(200); return; }
      await sleep(100);
    }
    throw new Error(`Page did not render: ${path}`);
  };
  const shot = async (name, selector = "main") => {
    const clip = await evaluate(`(() => {
      const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
      return { x: Math.max(0, r.x + scrollX), y: Math.max(0, r.y + scrollY), width: r.width, height: r.height, scale: 1 };
    })()`);
    if (["explorer", "characteristic", "dark"].includes(name)) clip.height = Math.min(clip.height, 1100);
    const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: selector !== ".menu", clip });
    writeFileSync(join(out, `${name}.png`), Buffer.from(data, "base64"));
    console.log(`shot ${name}: ${Math.round(clip.width)} × ${Math.round(clip.height)}`);
  };
  await send("Page.enable"); await send("Runtime.enable"); await send("Log.enable");
  await viewport(1440,1100);await appearance("light");
  await navigate("/design/", "#story-title");
  const waitFor = async expression => {for(let i=0;i<100;i++){if(await evaluate(expression))return;await sleep(25);}throw Error("Timed out: "+expression+"\n"+JSON.stringify(errors,null,2));};
  const frame = expression => evaluate(`(()=>{const f=document.querySelector('#preview').contentWindow;return (${expression})})()`);
  await waitFor("!!document.querySelector('#preview').contentDocument?.querySelector('.widget')");
  await shot("explorer", "body");
  if(await evaluate("document.querySelectorAll('.story-link').length")!==267)throw Error("Incomplete story navigation");
  const expected={gate:"garage-door",alarm:"security-system",switch:"toggle"};
  for(const story of await evaluate("HomeswiftDesignStories.widgets.map(w=>w.id)")){
    await evaluate(`location.hash=${JSON.stringify(story)}`);await sleep(90);
    if(!await frame("!!f.document.querySelector('.widget')"))throw Error("Missing widget "+story);
    const kind = await frame(`f.HomeswiftWidgets.kindOf(f.HomeswiftDesignStories.widgets.find(w=>w.id===${JSON.stringify(story)}).build()).kind`);
    const id = story.split("/")[1];
    if(kind!==(expected[id]||id))throw Error(`Wrong renderer ${story}: ${kind}`);
    for(const size of ["small","medium","large","xlarge"]){
      await evaluate(`document.querySelector('#size-picker [data-size=${size}]').click()`);await sleep(40);
      if(!await frame(`!!f.document.querySelector('.widget.size-${size}')`))throw Error(`Missing ${size} for ${story}`);
    }
    if(story==='widget/camera')await waitFor("document.querySelector('#preview').contentDocument.querySelector('.camera-still')?.naturalWidth > 0");
  }
  console.log("PASS: all 14 widget renderers in all four sizes");
  await evaluate("location.hash='characteristic/brightness'");await sleep(150);
  await shot("characteristic", "body");
  const ids=await evaluate("HomeswiftDesignCatalog.characteristics.map(c=>c.id)");
  for(const id of ids){
    await evaluate(`location.hash=${JSON.stringify("characteristic/"+id)}`);await sleep(125);
    await waitFor(`document.querySelector('#fixture').textContent.includes('Design:${id}')`);
    await waitFor(`document.querySelector('#preview').contentDocument?.querySelector('.characteristic-demo')!==null`);
  }
  console.log("PASS: all "+ids.length+" characteristic stories render");
  await evaluate("location.hash='widget/light'");await sleep(150);
  await frame("f.document.querySelector('.widget input[type=checkbox]').click()");await sleep(80);
  if(await evaluate("document.querySelector('#knobs input[aria-label=On]').checked"))throw Error("Production toggle did not update controls");
  if(!await evaluate("document.querySelector('#events').textContent.includes('On = false')"))throw Error("Write event missing");
  await evaluate("(()=>{const n=document.querySelector('#knobs input[aria-label=Brightness]');n.value=43;n.dispatchEvent(new Event('change'));})()");await sleep(70);
  if(!await evaluate("document.querySelector('#fixture').textContent.includes('43')"))throw Error("Knob did not update");
  await evaluate("document.querySelector('#reset').click()");await sleep(70);
  if(await evaluate("document.querySelector('#knobs input[aria-label=Brightness]').value")!=="75")throw Error("Reset failed");
  const state = async value => {await evaluate(`document.querySelector('#state').value=${JSON.stringify(value)};document.querySelector('#state').dispatchEvent(new Event('change'))`);await sleep(80);};
  await state("readonly");
  if(await frame("!!f.document.querySelector('.widget input[type=checkbox]')"))throw Error("Read-only power is writable");
  await state("paused");
  if(!await frame("!!f.document.querySelector('.widget.paused [inert]')"))throw Error("Paused controls not inert");
  await state("unavailable");
  await frame("f.document.querySelector('.widget input[type=checkbox]').click()");await sleep(80);
  if(!await evaluate("document.querySelector('#events').textContent.includes('Rejected')"))throw Error("Failure missing from event log");
  if(!await frame("f.document.querySelector('.widget input[type=checkbox]').checked"))throw Error("Failed write did not roll back");
  await state("normal");
  await frame("f.document.querySelector('.menu-button').click()");await sleep(30);
  if(await frame("f.document.querySelectorAll('.menu-choice-badge').length")!==4)throw Error("Missing size menu badges");
  await frame("f.document.querySelector('.menu-choice-badge').click()");await sleep(80);
  if(await evaluate("document.querySelector('#size-picker [aria-pressed=true]').dataset.size")!=="small")throw Error("Size menu not connected");
  await evaluate("document.querySelector('#size-picker [data-size=xlarge]').click()");
  await evaluate("location.hash='characteristic/pairSetup'");await sleep(90);
  if(!await frame("!!f.document.querySelector('.protocol-note')"))throw Error("Opaque protocol has an everyday control");
  await evaluate("document.querySelector('#search').value='nothingshouldmatchthis';document.querySelector('#search').dispatchEvent(new Event('input'))");
  if(await evaluate("document.querySelectorAll('.story-link').length")!==0)throw Error("Search filter failed");
  await evaluate("document.querySelector('#search').value='';document.querySelector('#search').dispatchEvent(new Event('input'))");
  console.log("PASS: read-only, paused, failed write rollback, inline size menu, protocol fields and search");
  await evaluate("location.hash='foundations'");await sleep(70);await shot("foundations","body");
  await evaluate("location.hash='widget/climate';document.querySelector('#theme').click()");await sleep(150);await shot("dark","body");
  await viewport(393,1000);await evaluate("document.querySelector('#viewport').value='fit';document.querySelector('#viewport').dispatchEvent(new Event('change'))");await sleep(100);await shot("phone","body");
  if(await evaluate("document.documentElement.scrollWidth>innerWidth"))throw Error("Phone overflow");
  for(const width of [320,768,1120]) {
    await viewport(width,1000);await sleep(50);
    if(await evaluate("document.documentElement.scrollWidth>innerWidth"))throw Error(`Layout overflow at ${width}`);
  }
  for(const lang of ["fr","es","pt"]){
    await navigate(`/design/?lang=${lang}#characteristic/brightness`,"#story-title");await sleep(150);
    const label=await evaluate("document.querySelector('#story-description').textContent");
    if(label.startsWith("The production"))throw Error("Missing translation "+lang);
    if((await frame("f.document.documentElement.lang")).split("-")[0]!==lang)throw Error("Frame language "+lang);
    await evaluate("document.querySelector('#search').value=document.querySelector('#story-title').textContent;document.querySelector('#search').dispatchEvent(new Event('input'))");
    if(!await evaluate("!!document.querySelector('.story-link[aria-current=page]')"))throw Error("Translated search failed "+lang);
  }
  if(requests.some(path=>path.startsWith('/api/')))throw Error("Demo contacted a real API");
  if(errors.length)throw Error(JSON.stringify(errors,null,2));
  console.log("PASS: controls, reset, themes, mobile, languages, isolated transport, no browser errors");
}finally{socket?.close();chrome.kill();await new Promise(done=>server.close(done));await sleep(250);rmSync(profile,{recursive:true,force:true});}
