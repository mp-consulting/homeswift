// Demonstration accessories for widget screenshots. No accounts, device connections or personal data.
const C=(type,value,format='uint8',extra={})=>({type,value,format,permissions:['pr','pw','ev'],...extra});
const S=(type,characteristics,extra={})=>({type,characteristics,primary:true,...extra});
const A=(id,name,category,services,extra={})=>({id,name,category,services,manufacturer:'Homeswift Demo',model:'Demo',bridge:'Demo Bridge',platform:'Demo',platformName:'Demo',...extra});
const light=(id,name,on=true)=>A(id,name,'lightbulb',[S('Lightbulb',[C('On',on,'bool'),C('Brightness',75,'int',{minValue:0,maxValue:100,minStep:1}),C('Hue',35,'float',{minValue:0,maxValue:360,minStep:1}),C('Saturation',65,'float',{minValue:0,maxValue:100,minStep:1}),C('Color Temperature',250,'uint32',{minValue:140,maxValue:500,minStep:1})])]);
const gate=A('gate','Garden Gate','garageDoorOpener',[S('GarageDoorOpener',[C('Current Door State',1),C('Target Door State',1,'uint8',{security:true}),C('Obstruction Detected',false,'bool')])]);
const lock=A('lock','Front Door','doorLock',[S('LockMechanism',[C('Lock Current State',0),C('Lock Target State',0,'uint8',{security:true})])]);
const plug=A('plug','Reading Lamp','outlet',[S('Outlet',[C('On',false,'bool'),C('Outlet In Use',false,'bool')])]);
const cover=A('cover','Bedroom Shutter','windowCovering',[S('WindowCovering',[C('Current Position',60),C('Target Position',60,'uint8',{minValue:0,maxValue:100,minStep:1}),C('Position State',2),C('Hold Position',false,'bool')])]);
const climate=A('climate','Living Room','airConditioner',[S('HeaterCooler',[C('Active',1),C('Current Heater-Cooler State',2),C('Target Heater-Cooler State',1,'uint8',{validValues:[0,1,2]}),C('Current Temperature',19.5,'float',{unit:'celsius'}),C('Heating Threshold Temperature',21.5,'float',{minValue:16,maxValue:30,minStep:0.5,unit:'celsius'}),C('Cooling Threshold Temperature',24,'float',{minValue:16,maxValue:30,minStep:0.5,unit:'celsius'}),C('Rotation Speed',40,'float',{minValue:0,maxValue:100,minStep:1}),C('Swing Mode',0)])]);
const purifier=A('purifier','Studio Air','airPurifier',[S('AirPurifier',[C('Active',1),C('Current Air Purifier State',2),C('Target Air Purifier State',1),C('Rotation Speed',35,'float',{minValue:0,maxValue:100,minStep:1})]),S('AirQualitySensor',[C('Air Quality',1)],{primary:false}),S('HumiditySensor',[C('Current Relative Humidity',48,'float',{unit:'percentage'})],{primary:false})]);
const valve=A('valve','Garden Water','sprinkler',[S('Valve',[C('Active',0),C('In Use',0),C('Valve Type',1),C('Set Duration',600,'uint32',{minValue:0,maxValue:3600,minStep:60}),C('Remaining Duration',0,'uint32')])]);
const sensor=A('sensor','Hall Temperature','sensor',[S('TemperatureSensor',[C('Current Temperature',22,'float',{unit:'celsius'})])]);
// A battery on its own accessory, as a battery pack reports it: the level, charging (0 not, 1 charging) and low.
const battery=A('battery','Garage Battery','other',[S('Battery',[C('Battery Level',72,'uint8',{minValue:0,maxValue:100,minStep:1,unit:'percentage'}),C('Charging State',1,'uint8',{validValues:[0,1,2]}),C('Status Low Battery',0,'uint8',{validValues:[0,1]})])]);
// Sensors and a remote, as the Hue and IKEA plugins publish them: a motion sensor with its light level and battery,
// a leak sensor, an air sensor, and a four-button remote (a Stateless Programmable Switch per button, numbered).
const bat=(level,low=0)=>S('Battery',[C('Battery Level',level,'uint8',{minValue:0,maxValue:100,minStep:1,unit:'percentage'}),C('Charging State',2),C('Status Low Battery',low)],{primary:false});
const motion=A('motion','Hall Sensor','sensor',[S('MotionSensor',[C('Motion Detected',true,'bool')]),S('LightSensor',[C('Current Ambient Light Level',120,'float',{unit:'lux'})],{primary:false}),bat(84)]);
const leak=A('leak','Sink','sensor',[S('LeakSensor',[C('Leak Detected',0)]),bat(90)]);
const air=A('air','Office Air','sensor',[S('AirQualitySensor',[C('Air Quality',3),C('PM2.5 Density',18,'float')]),S('TemperatureSensor',[C('Current Temperature',22.5,'float',{unit:'celsius'})],{primary:false}),S('HumiditySensor',[C('Current Relative Humidity',41,'float',{unit:'percentage'})],{primary:false})]);
const button=(n,primary)=>S('StatelessProgrammableSwitch',[C('Programmable Switch Event',0,'uint8',{permissions:['pr','ev'],validValues:[0,1,2]}),C('Service Label Index',n)],{name:`Button ${n}`,subtype:`button:${n}`,primary});
const remote=A('remote','Bedroom Dimmer','programmableSwitch',[button(1,true),button(2,false),button(3,false),button(4,false),bat(9,1)]);
const accessories=[gate,lock,light('spots','Ceiling Spots',false),light('hall','Hallway Spots',false),plug,light('pendant','Dining Pendant'),cover,sensor,climate,purifier,valve,battery];
window.previewAccessories=accessories;
window.previewSensors=[motion,leak,air,remote];
const e=HomeswiftCommon.el,main=document.querySelector('main');
const add=(a,size,wall)=>{
 // The Accessories page's menu for an administrator (app.js accessoryActions): use, arrange, manage.
 const none=()=>{};
 const options={size,actions:()=>[
  {label:'History',icon:'chart',onSelect:none},
  {separator:true},
  {label:'Size',choices:HomeswiftWidgets.sizes.map(one=>({
   label:one==='xlarge'?'Extra large':one[0].toUpperCase()+one.slice(1),badge:one==='xlarge'?'XL':one[0].toUpperCase(),checked:one===size,
   onSelect:()=>{const next=add(a,one,wall);node.replaceWith(next);}
  }))},
  {label:`${size==='xlarge'?'Extra large':size[0].toUpperCase()+size.slice(1)} for every light`,icon:'grid',onSelect:none},
  {label:'Room: Living Room…',icon:'room',onSelect:none},
  {label:'Name on these pages…',icon:'edit',onSelect:none},
  {label:'Add to Quick Controls',icon:'star',onSelect:none},
  {label:'Hide',icon:'eye',onSelect:none},
  {separator:true},
  {label:'Show its log',icon:'logs',onSelect:none},
  {label:'Plugin settings',icon:'gear',onSelect:none},
 ]};
 const node=HomeswiftWidgets.card(structuredClone(a),options);
 wall.append(node);
 return node;
};
window.preview=(mode='wall')=>{
 main.replaceChildren();
 const head=e('div',{class:'page-head'},e('h1',{text:mode==='sizes'?'Four sizes':mode==='sizes-more'?'More accessories':'Accessories'}));main.append(head);
 if(mode==='adaptive'||mode==='slide'){
 const wall=e('div',{class:'wall'});main.append(wall);
 if(mode==='adaptive'){const a=structuredClone(accessories[5]);a.services[0].adaptiveLighting={resumable:true};a.services[0].characteristics.push(C('Characteristic Value Active Transition Count',1));add(a,'xlarge',wall);}
 else add(cover,'medium',wall);
 }else if(mode==='sensors'){
  // Each at its default size, then the remote at each size; ?press= presses a button (its number) for the shot.
  const wall=e('div',{class:'wall sensors'});main.append(wall);for(const a of [motion,leak,air,remote])add(a,undefined,wall);
  const sizes=e('div',{class:'wall remote-sizes'});main.append(sizes);for(const size of ['small','medium','large'])add(remote,size,sizes);
 }else if(mode==='battery'){
  for(const size of HomeswiftWidgets.sizes){const wall=e('div',{class:`wall battery-${size}`});main.append(wall);add(battery,size,wall);}
 }else if(mode==='sizes'||mode==='sizes-more'){
  for(const a of mode==='sizes'?[accessories[5],climate,cover]:[purifier,valve,gate]){
   main.append(e('h2',{text:a.name}));const wall=e('div',{class:'wall'});main.append(wall);for(const size of HomeswiftWidgets.sizes)add(a,size,wall);
  }
 }else{
  const groups=mode==='phone'?[['Garden',[[gate,'medium'],[{...lock,id:'locked',name:'Side Gate',services:[S('LockMechanism',[C('Lock Current State',1),C('Lock Target State',1,'uint8',{security:true})])]},'medium']]],['Entrance',[[lock,'medium'],[accessories[2],'small'],[accessories[3],'small'],[plug,'small'],[accessories[5],'small'],[cover,'small'],[sensor,'small']]],['Living Room',[[climate,'xlarge'],[purifier,'large']]]]:[['Living Room',[[accessories[5],'medium'],[plug,'small'],[sensor,'small'],[climate,'xlarge'],[purifier,'large'],[cover,'medium'],[gate,'medium'],[valve,'large'],[accessories[2],'small'],[accessories[3],'small'],[lock,'medium']]]];
  for(const [name,items]of groups){main.append(e('h2',{text:name}));const wall=e('div',{class:'wall'});main.append(wall);for(const [a,size]of items)add(mode==='paused'?{...a,paused:true}:a,size,wall);}
 }
 if(mode==='edit')for(const wall of document.querySelectorAll('.wall')){
  wall.classList.add('editing');
  for(const node of wall.children)node.append(e('div',{class:'edit-bar'},['‹','S','M','L','XL','›'].map(label=>e('button',{type:'button',text:label,'aria-pressed':label==='S'?node.classList.contains('size-small'):label==='M'?node.classList.contains('size-medium'):label==='L'?node.classList.contains('size-large'):label==='XL'?node.classList.contains('size-xlarge'):null}))));
 }
 if(mode==='sheet')HomeswiftWidgets.open(climate,{actions:()=>[]});
};
preview(new URLSearchParams(location.search).get('mode')||'wall');
