(() => {
  const $ = (id) => document.getElementById(id);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const wire = $('wire');
  const send = (aid, iid, value) => { wire.textContent = `/characteristics {"aid":${aid},"iid":${iid},"value":${JSON.stringify(value)}}`; };

  // The texts this script writes, in the page's language: fr/, es/ and pt/ hold translated copies of the page,
  // told apart by <html lang>. Numbers follow the same locale (21,5° in French). The lock's "· hold" hint is English
  // only: no translation of it fits a small tile, and the stage note says to hold the door.
  const locale = document.documentElement.lang || 'en';
  const nnbsp = '\u202f';
  const T = {
    en: {
      on: 'On', off: 'Off', closed: 'Closed', open: (p) => `Open · ${p}`, locked: 'Locked · hold', unlocked: 'Unlocked · hold',
      heating: (t) => `Heating to ${t}°`, idle: (t) => `Idle · ${t}° inside`, pct: (n) => `${n} %`, bigPct: (n) => `${n}%`,
      copy: 'Copy', copied: 'Copied', selected: 'Selected', less: 'less', faster: 'faster',
      rows: [['Memory at idle', 'Resident size'], ['Startup', 'Launch to listening'], ['Pair verify', 'Round trips, median'], ['Event latency', 'Write to notification, median']],
    },
    fr: {
      on: 'Allumé', off: 'Éteint', closed: 'Fermé', open: (p) => `Ouvert · ${p}`, locked: 'Verrouillée', unlocked: 'Déverrouillée',
      heating: (t) => `Chauffage à ${t}°`, idle: (t) => `Au repos · ${t}° à l'intérieur`, pct: (n) => `${n}${nnbsp}%`, bigPct: (n) => `${n}${nnbsp}%`,
      copy: 'Copier', copied: 'Copié', selected: 'Sélectionné', less: 'de moins', faster: 'plus rapide',
      rows: [['Mémoire au repos', 'Taille résidente'], ['Démarrage', "Du lancement à l'écoute"], ['Vérification du jumelage', 'Allers-retours, médiane'], ['Latence des événements', "De l'écriture à la notification, médiane"]],
    },
    es: {
      on: 'Encendido', off: 'Apagado', closed: 'Cerrada', open: (p) => `Abierta · ${p}`, locked: 'Bloqueada · mantén', unlocked: 'Desbloqueada · mantén',
      heating: (t) => `Calentando a ${t}°`, idle: (t) => `En reposo · ${t}° dentro`, pct: (n) => `${n}${nnbsp}%`, bigPct: (n) => `${n}${nnbsp}%`,
      copy: 'Copiar', copied: 'Copiado', selected: 'Seleccionado', less: 'menos', faster: 'más rápido',
      rows: [['Memoria en reposo', 'Tamaño residente'], ['Arranque', 'Del inicio a la escucha'], ['Verificación del emparejamiento', 'Idas y vueltas, mediana'], ['Latencia de eventos', 'De la escritura a la notificación, mediana']],
    },
    pt: {
      on: 'Ligado', off: 'Desligado', closed: 'Fechado', open: (p) => `Aberto · ${p}`, locked: 'Trancada', unlocked: 'Destrancada',
      heating: (t) => `A aquecer até ${t}°`, idle: (t) => `Em repouso · ${t}° no interior`, pct: (n) => `${n}${nnbsp}%`, bigPct: (n) => `${n}${nnbsp}%`,
      copy: 'Copiar', copied: 'Copiado', selected: 'Selecionado', less: 'menos', faster: 'mais rápido',
      rows: [['Memória em repouso', 'Tamanho residente'], ['Arranque', 'Do início à escuta'], ['Verificação do emparelhamento', 'Idas e voltas, mediana'], ['Latência de eventos', 'Da escrita à notificação, mediana']],
    },
  };
  const L = T[locale.split('-')[0]] || T.en;
  const num = (value, digits) => value.toLocaleString(locale, digits == null ? undefined : { minimumFractionDigits: digits, maximumFractionDigits: digits });

  // A critically damped spring (damping 1, response 0.4 s), started from the current value and velocity.
  function spring(from, to, velocity, onFrame, response = 0.4) {
    if (reduce) { onFrame(to); return () => {}; }
    const w = (2 * Math.PI) / response;
    let x = from, v = velocity, last = performance.now(), raf;
    const step = (now) => {
      const dt = Math.min(0.032, (now - last) / 1000); last = now;
      v += (-w * w * (x - to) - 2 * w * v) * dt; x += v * dt;
      if (Math.abs(x - to) < 0.05 && Math.abs(v) < 0.5) { onFrame(to); return; }
      onFrame(x); raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }

  // Desk Light: switch and a slider that follows the finger from where it was grabbed.
  const desk = $('desk'), deskSwitch = $('desk-switch'), slider = $('desk-slider');
  let deskOn = true, bright = 70;
  const renderDesk = () => {
    desk.classList.toggle('on', deskOn); desk.classList.toggle('off', !deskOn);
    deskSwitch.setAttribute('aria-checked', deskOn);
    slider.style.setProperty('--v', bright / 100); slider.setAttribute('aria-valuenow', Math.round(bright));
    $('desk-pct').textContent = L.pct(Math.round(bright));
    $('desk-status').textContent = deskOn ? `${L.on} · ${L.pct(Math.round(bright))}` : L.off;
  };
  deskSwitch.addEventListener('click', () => { deskOn = !deskOn; renderDesk(); send(2, 10, deskOn); });
  let drag = null;
  slider.addEventListener('pointerdown', (e) => { slider.setPointerCapture(e.pointerId); drag = { x: e.clientX, start: bright, w: slider.clientWidth }; });
  slider.addEventListener('pointermove', (e) => {
    if (!drag) return;
    bright = Math.max(1, Math.min(100, drag.start + ((e.clientX - drag.x) / drag.w) * 100));
    if (!deskOn) deskOn = true;
    renderDesk();
  });
  const endSlide = () => { if (drag && Math.round(bright) !== Math.round(drag.start)) send(2, 11, Math.round(bright)); drag = null; };
  slider.addEventListener('pointerup', endSlide); slider.addEventListener('pointercancel', endSlide);
  slider.addEventListener('keydown', (e) => {
    const d = { ArrowRight: 5, ArrowUp: 5, ArrowLeft: -5, ArrowDown: -5 }[e.key];
    if (!d) return; e.preventDefault(); bright = Math.max(1, Math.min(100, bright + d)); deskOn = true; renderDesk(); send(2, 11, Math.round(bright));
  });

  // Thermostat
  let target = 21.5; const inside = 19.5;
  const renderThermo = () => {
    $('t-target').textContent = `${num(target, 1)}°`;
    const s = $('thermo-status');
    s.className = 'status ' + (target > inside ? 'heat' : 'ok');
    s.textContent = target > inside ? L.heating(num(target, 1)) : L.idle(num(inside, 1));
  };
  const nudge = (d) => { target = Math.max(10, Math.min(30, target + d)); renderThermo(); send(3, 14, target); };
  $('t-down').addEventListener('click', () => nudge(-0.5));
  $('t-up').addEventListener('click', () => nudge(0.5));

  // Shutter: 0 closed, 100 open. Dragging down closes it; past either end it rubber-bands, then springs back.
  const shutter = $('shutter');
  let pos = 60, stop = null, sd = null;
  const rubber = (over, dim, c = 0.55) => (over * dim * c) / (dim + c * Math.abs(over));
  const renderShutter = (p) => {
    const shown = Math.max(0, Math.min(100, p));
    shutter.style.setProperty('--closed', (100 - shown) / 100);
    $('shutter-pct').textContent = L.bigPct(Math.round(shown));
    $('shutter-status').textContent = shown <= 0 ? L.closed : L.open(L.pct(Math.round(shown)));
    shutter.setAttribute('aria-valuenow', Math.round(shown));
    const over = p > 100 ? p - 100 : p < 0 ? p : 0;
    shutter.style.transform = over ? `translateY(${-rubber(over, 100) * 0.5}px)` : '';
  };
  shutter.addEventListener('pointerdown', (e) => {
    if (stop) stop();
    shutter.setPointerCapture(e.pointerId);
    sd = { y: e.clientY, start: pos, h: shutter.clientHeight, hist: [[e.clientY, e.timeStamp]], moved: false };
    shutter.classList.add('pressed');
  });
  shutter.addEventListener('pointermove', (e) => {
    if (!sd) return;
    const dy = e.clientY - sd.y;
    if (Math.abs(dy) > 6) sd.moved = true;
    sd.hist.push([e.clientY, e.timeStamp]); if (sd.hist.length > 5) sd.hist.shift();
    let p = sd.start - (dy / sd.h) * 100;
    if (p > 100) p = 100 + rubber(p - 100, 60); else if (p < 0) p = rubber(p, 60);
    pos = p; renderShutter(pos);
  });
  const endShutter = () => {
    if (!sd) return;
    shutter.classList.remove('pressed');
    const [y0, t0] = sd.hist[0], [y1, t1] = sd.hist[sd.hist.length - 1];
    const v = t1 > t0 ? (-(y1 - y0) / (t1 - t0)) * 1000 / sd.h * 100 : 0; // %/s, up is open
    let to;
    if (!sd.moved) to = pos > 0 ? 0 : 100;                            // a tap opens or closes
    else to = Math.max(0, Math.min(100, Math.round(pos + (v / 1000) * 0.99 / (1 - 0.99)))); // project the flick
    stop = spring(pos, to, sd.moved ? v : 0, (x) => { pos = x; renderShutter(x); });
    send(4, 9, to);
    sd = null;
  };
  shutter.addEventListener('pointerup', endShutter); shutter.addEventListener('pointercancel', endShutter);
  shutter.addEventListener('keydown', (e) => {
    const d = { ArrowUp: 10, ArrowDown: -10 }[e.key]; if (!d) return; e.preventDefault();
    if (stop) stop(); const to = Math.max(0, Math.min(100, Math.round(pos) + d));
    stop = spring(pos, to, 0, (x) => { pos = x; renderShutter(x); }); send(4, 9, to);
  });

  // Tiles that toggle on press.
  const tile = (id, aid, iid) => {
    const el = $(id);
    const flip = () => {
      const on = !el.classList.contains('on');
      el.classList.toggle('on', on); el.setAttribute('aria-pressed', on);
      el.querySelector('.status').textContent = on ? L.on : L.off;
      send(aid, iid, on);
    };
    el.addEventListener('click', flip);   // highlighted on press by :active, committed on release
    el.addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); flip(); } });
  };
  tile('porch', 5, 10); tile('kitchen', 6, 10);

  // Front Door: a hold of 650 ms confirms; letting go early cancels.
  const lock = $('lock'); let locked = true, timer = null;
  const setLock = () => {
    lock.classList.toggle('unlocked', !locked);
    $('lock-glyph').setAttribute('href', locked ? '#i-lock' : '#i-unlock');
    $('lock-status').textContent = locked ? L.locked : L.unlocked;
  };
  const startHold = () => {
    lock.classList.add('holding', 'pressed');
    timer = setTimeout(() => { locked = !locked; setLock(); send(7, 12, locked ? 1 : 0); release(); }, 650);
  };
  const release = () => { clearTimeout(timer); timer = null; lock.classList.remove('holding', 'pressed'); };
  lock.addEventListener('pointerdown', (e) => { lock.setPointerCapture(e.pointerId); startHold(); });
  lock.addEventListener('pointerup', release); lock.addEventListener('pointercancel', release);
  lock.addEventListener('keydown', (e) => { if ((e.key === ' ' || e.key === 'Enter') && !timer && !e.repeat) { e.preventDefault(); startHold(); } });
  lock.addEventListener('keyup', release);

  renderDesk(); renderThermo(); renderShutter(pos);

  // Benchmarks, each row on its own scale: the longer bar fills the track.
  // The numbers come from Benchmarks/README.md; the labels are L.rows, in the same order.
  const rows = [
    [8.6, 76.1, 'MB', 8.8, L.less],
    [59, 399, 'ms', 6.8, L.faster],
    [0.57, 12.5, 'ms', 22, L.faster],
    [0.30, 252.39, 'ms', 834, L.faster],
  ];
  const bench = $('bench');
  for (const [i, [us, them, unit, ratio, word]] of rows.entries()) {
    const [name, sub] = L.rows[i];
    const max = Math.max(us, them);
    const row = document.createElement('div'); row.className = 'row';
    row.innerHTML = `<div class="row-label"><strong>${name}</strong><span>${sub}</span></div>
      <div class="bars">
        <div class="bar us"><i></i>${num(us)} ${unit}</div>
        <div class="bar them"><i></i>${num(them)} ${unit}</div>
      </div>
      <div class="ratio">${num(ratio)}×<small>${word}</small></div>`;
    const [barUs, barThem] = row.querySelectorAll('.bar i');
    barUs.style.width = `calc((100% - 5.5rem) * ${us / max})`;
    barThem.style.width = `calc((100% - 5.5rem) * ${them / max})`;
    bench.appendChild(row);
  }

  // Install tabs and copy buttons.
  const tabs = document.querySelectorAll('.seg button');
  tabs.forEach((b) => b.addEventListener('click', () => {
    tabs.forEach((t) => t.setAttribute('aria-selected', t === b));
    document.querySelectorAll('#install .term').forEach((p) => { p.hidden = p.dataset.pane !== b.dataset.pane; });
  }));
  document.querySelectorAll('.copy').forEach((btn) => btn.addEventListener('click', () => {
    const text = btn.parentElement.querySelector('pre').innerText;
    const done = () => { btn.textContent = L.copied; setTimeout(() => { btn.textContent = L.copy; }, 1400); };
    navigator.clipboard?.writeText(text).then(done, () => {
      const r = document.createRange(); r.selectNodeContents(btn.parentElement.querySelector('pre'));
      const s = getSelection(); s.removeAllRanges(); s.addRange(r); btn.textContent = L.selected;
    });
  }));
})();
